
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {Types} from "./Types.sol";

interface IHook {
    function stablecoinToSide(address) external view returns (uint8);
    function getDepegStats(address) external view
        returns (Types.DepegStats memory);
    function getDepegSeverityBps() external view returns (uint);
    function isDepegged(address) external view returns (bool);
}

interface IChainlinkOracle {
    function latestRoundData() external view
    returns (uint80, int, uint, uint, uint80);
}

interface IDSRRate {
    function getRate() external view returns (uint);
}

interface ISCRVOracle {
    function pricePerShare() external view returns (uint);
}

// IntegralMath and AnalyticMath borrowed from here
// https://github.com/barakman/solidity-math-utils/
library FeeLib {
    uint public constant WAD = 1e18;
    uint public constant MONTH = 2420000;
    uint public constant BASE = 4; // Fixed base fee (bps)
    uint private constant MIN_MARKET_CAPITAL = 10_000e18;

    uint8 internal constant MAX_SIDES = 12;
    uint public constant MAX_FEE = 5000;
    uint constant E_NUM = 2718281828;
    uint constant E_DEN = 1000000000;

    uint public constant DECAY_FLOOR = 1000;
    uint public constant LAMBDA = 127;

    /// @dev b is capped at 6× INITIAL_B → max market-maker loss = 6×INITIAL_B×ln(12) ≈ 14.91×INITIAL_B
    int128 public constant INITIAL_B = 10_000e18;
    int128 public constant MAX_B = 60_000e18; // 6× cap

    // Oracle type flags
    uint8 public constant ORACLE_CHAINLINK = 3;
    uint8 public constant ORACLE_CRV = 2;
    uint8 public constant ORACLE_DSR_RATE = 1;
    error StaleOracle();
    error BadPrice();

    function depositFee(uint amount, uint bps)
        public pure returns (uint) {
        return FullMath.mulDiv(
            amount, bps, 10000);
    }

    /// @dev fee(X) = max(0, totalExposure - riskX)
    ///      where totalExposure = Σ(share_i × risk_i) across all tokens
    ///      Withdrawing the depegged token → fee = 0 (heals basket)
    ///      Withdrawing a healthy token    → fee = basket's depeg exposure
    ///      Equal risk across all tokens   → fee = BASE (no selective advantage)
    /// @param thisRisk calcRisk score for the token being withdrawn (bps)
    function calcFee(uint thisRisk,
        uint totalExposure) public pure returns (uint) {
        if (totalExposure <= thisRisk) return BASE;
        uint fee = totalExposure - thisRisk;
        if (fee < BASE) return BASE;
        return fee > MAX_FEE ? MAX_FEE : fee;
    }

    /// @notice risk score from prediction market data
    /// @dev Simple capital-ratio model matching Hook's Types.DepegStats
    /// @param s Depeg stats from prediction market hook
    /// @return Risk score in basis points
    /// (0 = safe, 10000 = definitely depegging)
    function calcRisk(Types.DepegStats memory s)
        internal pure returns (uint) {
        if (s.depegged) return 10000;

        bool hasPrior = s.avgConf > 0;
        uint prior = hasPrior ? uint(s.avgConf) : 6500;
        if (s.capTotal == 0) return prior;

        uint capitalSignal = (uint(s.capOnSide) * 10000) / uint(s.capTotal);
        uint n = uint(s.capTotal) / MIN_MARKET_CAPITAL;
        if (n == 0) return prior;  // thin market → prior only
        // Thick market with no prior → pure capital signal
        if (!hasPrior) return capitalSignal;

        // Thick market with prior → Bayesian blend
        return (prior + n * capitalSignal) / (1 + n);
    }

    function calcFeeL1(address token, uint idx,
        uint[14] memory deps, address[] memory stables,
        address hook) public view returns (uint) {
        uint totalDeposits = deps[12];
        if (totalDeposits == 0) return BASE;
        // Token without prediction market → no M1 signal, base fee only
        if (IHook(hook).stablecoinToSide(token) == 0) return BASE;
        // Get this token's risk score
        uint thisRisk; uint totalExposure;
        { Types.DepegStats memory stats = IHook(hook).getDepegStats(token);
          thisRisk = stats.side > 0 ? calcRisk(stats) : 0; }
        // Compute basket-wide totalExposure = Σ(share_i × risk_i)
        // Each term: (deps[i+1] / totalDeposits) × risk_i  →  in bps
        for (uint i = 0; i < stables.length; i++) {
            if (deps[i + 1] < 100 * WAD) continue;
            uint8 side = IHook(hook).stablecoinToSide(stables[i]);

            if (side == 0) continue;
            Types.DepegStats memory s = IHook(hook).getDepegStats(stables[i]);
            if (s.side > 0) {
                uint risk = calcRisk(s);
                totalExposure += (deps[i + 1] * risk) / totalDeposits;
            }
        } return calcFee(thisRisk, totalExposure);
    }

    /// @notice Calculate fee with automatic index lookup
    /// @dev Wrapper around calcFeeL1 that finds index internally
    function calcFeeL1WithLookup(address token,
        uint[14] memory deps, address[] memory stables,
        address hook) public view returns (uint) {
        uint len = stables.length;
        for (uint i; i < len;) {
            if (stables[i] == token)
                return calcFeeL1(token,
                i, deps, stables, hook);
            unchecked { ++i; }
        } return 0;
    }

    /// @notice Check if token is depegged via Hook
    function isDepegged(address token, address hook)
        external view returns (bool) {
        return IHook(hook).getDepegStats(token).depegged;
    }

    /// @notice Single-token fee + haircut → adjusted needed amount
    function calcNeeded(address token, uint amount,
        uint[14] memory deps, address[] memory stables,
        address hook) external view
        returns (uint needed) {
        uint fee = (calcFeeL1WithLookup(token,
            deps, stables, hook) * WAD) / 10000;

        needed = (fee > 0 && fee < WAD / 10) ?
            FullMath.mulDiv(amount, WAD - fee, WAD) : amount;

        Types.DepegStats memory ds = IHook(hook).getDepegStats(token);
        if (ds.depegged && ds.severityBps > 0 && ds.severityBps < 10000)
            needed = FullMath.mulDiv(needed, 10000, 10000 - ds.severityBps);
    }

    /// @notice Apply pieralberto fee + depeg haircut in one call.
    /// @dev Moves fee+haircut logic from Aux._take into FeeLib,
    ///      saving ~100 bytes of Aux bytecode.
    function applyFeeAndHaircut(address token, uint idx,
        uint amount, uint[14] memory deps,
        address[] memory stables, address hook) external view returns (uint) {
        uint feeBps = calcFeeL1(token,
            idx, deps, stables, hook);

        if (feeBps > 0) amount -= FullMath.mulDiv(
                            amount, feeBps, 10000);

        Types.DepegStats memory ds2 = IHook(hook).getDepegStats(token);
        if (ds2.depegged && ds2.severityBps > 0 && ds2.severityBps < 10000)
            amount = FullMath.mulDiv(amount, 10000, 10000 - ds2.severityBps);
        return amount;
    }

    /// @notice Pro-rata allocation + fee + haircut in one call.
    /// Computes each slot's share of `totalAmount` proportional to
    /// deps[idx+1]/deps[12], then applies fee and haircut.
    /// Replaces the inline mulDiv + applyFeeAndHaircut two-step in _take.
    function allocate(address token, uint idx, uint totalAmount, uint slotDep,
        uint totalDep, uint[14] memory deps, address[] memory stables,
        address hook) external view returns (uint amount) {
        if (totalDep == 0 || slotDep == 0) return 0;
        amount = FullMath.mulDiv(totalAmount,
            FullMath.mulDiv(WAD, slotDep, totalDep), WAD);

        if (amount == 0) return 0;
        uint feeBps = calcFeeL1(token,
            idx, deps, stables, hook);

        if (feeBps > 0) amount -= FullMath.mulDiv(
                            amount, feeBps, 10000);

        Types.DepegStats memory ds3 = IHook(hook).getDepegStats(token);
        if (ds3.depegged && ds3.severityBps > 0 && ds3.severityBps < 10000)
            amount = FullMath.mulDiv(amount, 10000, 10000 - ds3.severityBps);
    }

    /// @notice Find token with highest imbalance score (fee)
    /// @dev Higher fee = more overweight + risky = priority to reduce
    /// @return idx Index of most imbalanced token
    /// @return fee Imbalance score (higher = reduce first)
    /// @return excess Amount over equal weight (18 dec)
    function getMostImbalanced(uint[14] memory deps,
        address[] memory stables, address hook) external
        view returns (uint idx, uint fee, uint excess) {
        uint len = stables.length; uint high;
        uint total = deps[12];
        if (total == 0)
            return (0, 0, 0);
        for (uint i; i < len;) {
            if (deps[i + 1] > 100 * WAD) {
                uint f = calcFeeL1(stables[i],
                        i, deps, stables, hook);
                if (f > high) { high = f; idx = i; }
            } unchecked { ++i; }
        } fee = high;
        uint eq = total / len;
        if (deps[idx + 1] > eq)
            excess = deps[idx + 1] - eq;
    }

    function price(int128[MAX_SIDES] memory q,
        uint8 n, int128 b, uint8 side) public
        pure returns (uint p) {
        int256 maxQ = _max(q, n);
        uint eSide; uint eSum;
        for (uint8 j; j < n; j++) {
            uint ej = _expNorm(q[j], maxQ, b);
            eSum += ej;
            if (j == side) eSide = ej;
        }
        if (eSum == 0) return WAD / n;
        p = (eSide * WAD) / eSum;
    }

    /// @notice Cost of buying `delta` tokens on `side`
    /// @return c Unsigned cost in WAD
    function cost(int128[MAX_SIDES] memory q, uint8 n,
        int128 b, uint8 side, int128 delta) public
        pure returns (uint c) { int128[MAX_SIDES] memory qA;
        uint lseBefore = _logSumExp(q, n, b);
        for (uint8 j; j < n; j++) qA[j] = q[j];
        qA[side] += delta;
        uint lseAfter = _logSumExp(qA, n, b);
        uint bAbs = uint(int256(b));
        c = lseAfter >= lseBefore
            ? (bAbs * (lseAfter - lseBefore)) / WAD
            : (bAbs * (lseBefore - lseAfter)) / WAD;
    }

    /// @dev exp((q_j − maxQ) / b),
    /// result WAD-scaled. arg ≤ 0.
    function _expNorm(int128 qj,
        int256 maxQ, int128 b)
        internal pure returns (uint) {
        int256 d = int256(qj) - maxQ; // ≤ 0
        if (d == 0) return WAD;
        uint absD = uint(-d);
        uint absB = uint(int256(b));
        // exp(-x) < 1 wei (WAD) when x > ~41.4
        // (18 × ln(10)). findPosition limit ~56, so clamp at 41.
        if (absD / absB > 41) return 0;
        (uint pN, uint pD) =
            _amPow(E_NUM,
             E_DEN, absD, absB);
        if (pN == 0) return 0;
        return (pD * WAD) / pN;
         // 1 / exp(|d|/b)
    }

    /// @dev max/b + ln(Σ exp((q_j−max)/b))  in WAD
    function _logSumExp(int128[MAX_SIDES] memory q,
      uint8 n, int128 b) internal pure returns (uint) {
        int256 maxQ = _max(q, n); uint sum; uint lnWad;
        for (uint8 j; j < n; j++)
            sum += _expNorm(q[j], maxQ, b);
        // ln(sum) where sum is WAD-scaled
        if (sum > WAD) { (uint lnN, uint lnD) =
                   _amLog(sum, WAD);
                    lnWad = (lnN * WAD) / lnD;
        } // else ln(≤1) ≤ 0, clamp to 0
        // add back maxQ / b
        uint bAbs = uint(int256(b));
        if (maxQ >= 0)
            lnWad += (uint(maxQ) * WAD) / bAbs;
        else {
            uint sub = (uint(-maxQ) * WAD) / bAbs;
            lnWad = lnWad > sub ? lnWad - sub : 0;
        } return lnWad;
    }

    // ── Inlined math (pow/log + IntegralMath + Uint) ──────────────────

    uint8  private constant _MIN_PREC = 32;
    uint8  private constant _MAX_PREC = 127;
    uint256 private constant _FIXED_1 = 1 << 127;
    uint256 private constant _FIXED_2 = 2 << 127;
    uint256 private constant _LN2_NUM = 0x3f80fe03f80fe03f80fe03f80fe03f8;
    uint256 private constant _LN2_DEN = 0x5b9de1d10bf4103d647b0955897ba80;
    uint256 private constant _OPT_LOG_MAX = 0x15bf0a8b1457695355fb8ac404e7a79e4;
    uint256 private constant _OPT_EXP_MAX = 0x800000000000000000000000000000000;

    function _amPow(uint256 a, uint256 b, uint256 c, uint256 d)
        private pure returns (uint256, uint256) { unchecked {
        if (a >= b) return _mulDivExp(_mulDivLog(_FIXED_1, a, b), c, d);
        (uint256 q, uint256 p) = _mulDivExp(_mulDivLog(_FIXED_1, b, a), c, d);
        return (p, q);
    }}

    function _amLog(uint256 a, uint256 b)
        private pure returns (uint256, uint256) { unchecked {
        require(a >= b, "log: a < b");
        return (_mulDivLog(_FIXED_1, a, b), _FIXED_1);
    }}

    function _mulDivLog(uint256 x, uint256 y, uint256 z)
        private pure returns (uint256) {
        return _fixedLog(_mulDivF(x, y, z));
    }

    function _mulDivExp(uint256 x, uint256 y, uint256 z)
        private pure returns (uint256, uint256) {
        return _fixedExp(_mulDivF(x, y, z));
    }

    function _fixedLog(uint256 x) private pure returns (uint256) { unchecked {
        return x < _OPT_LOG_MAX ? _optimalLog(x) : _generalLog(x);
    }}

    function _fixedExp(uint256 x) private pure returns (uint256, uint256) { unchecked {
        if (x < _OPT_EXP_MAX) return (_optimalExp(x), 1 << 127);
        uint8 precision = _findPosition(x);
        return (_generalExp(x >> (127 - precision), precision), 1 << precision);
    }}

    function _findPosition(uint256 x) private pure returns (uint8) { unchecked {
        uint8 lo = _MIN_PREC; uint8 hi = _MAX_PREC;
        while (lo + 1 < hi) {
            uint8 mid = (lo + hi) / 2;
            if (_maxExpArray(mid) >= x) lo = mid; else hi = mid;
        }
        if (_maxExpArray(hi) >= x) return hi;
        if (_maxExpArray(lo) >= x) return lo;
        revert("findPosition: x > max");
    }}

    function _generalLog(uint256 x) private pure returns (uint256) { unchecked {
        uint256 res = 0;
        if (x >= _FIXED_2) {
            uint8 count = _floorLog2(x / _FIXED_1);
            x >>= count; res = count * _FIXED_1;
        }
        if (x > _FIXED_1) {
            for (uint8 i = 127; i > 0; --i) {
                x = (x * x) / _FIXED_1;
                if (x >= _FIXED_2) { x >>= 1; res += 1 << (i - 1); }
            }
        }
        return res * _LN2_NUM / _LN2_DEN;
    }}

    function _generalExp(uint256 x, uint8 precision) private pure returns (uint256) { unchecked {
        uint256 xi = x; uint256 res = 0;
        xi = (xi * x) >> precision; res += xi * 0x3442c4e6074a82f1797f72ac0000000;
        xi = (xi * x) >> precision; res += xi * 0x116b96f757c380fb287fd0e40000000;
        xi = (xi * x) >> precision; res += xi * 0x045ae5bdd5f0e03eca1ff4390000000;
        xi = (xi * x) >> precision; res += xi * 0x00defabf91302cd95b9ffda50000000;
        xi = (xi * x) >> precision; res += xi * 0x002529ca9832b22439efff9b8000000;
        xi = (xi * x) >> precision; res += xi * 0x00054f1cf12bd04e516b6da88000000;
        xi = (xi * x) >> precision; res += xi * 0x0000a9e39e257a09ca2d6db51000000;
        xi = (xi * x) >> precision; res += xi * 0x000012e066e7b839fa050c309000000;
        xi = (xi * x) >> precision; res += xi * 0x000001e33d7d926c329a1ad1a800000;
        xi = (xi * x) >> precision; res += xi * 0x0000002bee513bdb4a6b19b5f800000;
        xi = (xi * x) >> precision; res += xi * 0x00000003a9316fa79b88eccf2a00000;
        xi = (xi * x) >> precision; res += xi * 0x0000000048177ebe1fa812375200000;
        xi = (xi * x) >> precision; res += xi * 0x0000000005263fe90242dcbacf00000;
        xi = (xi * x) >> precision; res += xi * 0x000000000057e22099c030d94100000;
        xi = (xi * x) >> precision; res += xi * 0x0000000000057e22099c030d9410000;
        xi = (xi * x) >> precision; res += xi * 0x00000000000052b6b54569976310000;
        xi = (xi * x) >> precision; res += xi * 0x00000000000004985f67696bf748000;
        xi = (xi * x) >> precision; res += xi * 0x000000000000003dea12ea99e498000;
        xi = (xi * x) >> precision; res += xi * 0x00000000000000031880f2214b6e000;
        xi = (xi * x) >> precision; res += xi * 0x000000000000000025bcff56eb36000;
        xi = (xi * x) >> precision; res += xi * 0x000000000000000001b722e10ab1000;
        xi = (xi * x) >> precision; res += xi * 0x0000000000000000001317c70077000;
        xi = (xi * x) >> precision; res += xi * 0x00000000000000000000cba84aafa00;
        xi = (xi * x) >> precision; res += xi * 0x00000000000000000000082573a0a00;
        xi = (xi * x) >> precision; res += xi * 0x00000000000000000000005035ad900;
        xi = (xi * x) >> precision; res += xi * 0x000000000000000000000002f881b00;
        xi = (xi * x) >> precision; res += xi * 0x0000000000000000000000001b29340;
        xi = (xi * x) >> precision; res += xi * 0x00000000000000000000000000efc40;
        xi = (xi * x) >> precision; res += xi * 0x0000000000000000000000000007fe0;
        xi = (xi * x) >> precision; res += xi * 0x0000000000000000000000000000420;
        xi = (xi * x) >> precision; res += xi * 0x0000000000000000000000000000021;
        xi = (xi * x) >> precision; res += xi * 0x0000000000000000000000000000001;
        return res / 0x688589cc0e9505e2f2fee5580000000 + x + (1 << precision);
    }}

    function _optimalLog(uint256 x) private pure returns (uint256) { unchecked {
        uint256 res = 0; uint256 y; uint256 z; uint256 w;
        if (x >= 0xd3094c70f034de4b96ff7d5b6f99fcd9) {res += 0x40000000000000000000000000000000; x = x * _FIXED_1 / 0xd3094c70f034de4b96ff7d5b6f99fcd9;}
        if (x >= 0xa45af1e1f40c333b3de1db4dd55f29a8) {res += 0x20000000000000000000000000000000; x = x * _FIXED_1 / 0xa45af1e1f40c333b3de1db4dd55f29a8;}
        if (x >= 0x910b022db7ae67ce76b441c27035c6a2) {res += 0x10000000000000000000000000000000; x = x * _FIXED_1 / 0x910b022db7ae67ce76b441c27035c6a2;}
        if (x >= 0x88415abbe9a76bead8d00cf112e4d4a9) {res += 0x08000000000000000000000000000000; x = x * _FIXED_1 / 0x88415abbe9a76bead8d00cf112e4d4a9;}
        if (x >= 0x84102b00893f64c705e841d5d4064bd4) {res += 0x04000000000000000000000000000000; x = x * _FIXED_1 / 0x84102b00893f64c705e841d5d4064bd4;}
        if (x >= 0x8204055aaef1c8bd5c3259f4822735a3) {res += 0x02000000000000000000000000000000; x = x * _FIXED_1 / 0x8204055aaef1c8bd5c3259f4822735a3;}
        if (x >= 0x810100ab00222d861931c15e39b44e9a) {res += 0x01000000000000000000000000000000; x = x * _FIXED_1 / 0x810100ab00222d861931c15e39b44e9a;}
        if (x >= 0x808040155aabbbe9451521693554f734) {res += 0x00800000000000000000000000000000; x = x * _FIXED_1 / 0x808040155aabbbe9451521693554f734;}
        z = y = x - _FIXED_1; w = y * y / _FIXED_1;
        res += z * (0x100000000000000000000000000000000 - y) / 0x100000000000000000000000000000000; z = z * w / _FIXED_1;
        res += z * (0x0aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa - y) / 0x200000000000000000000000000000000; z = z * w / _FIXED_1;
        res += z * (0x099999999999999999999999999999999 - y) / 0x300000000000000000000000000000000; z = z * w / _FIXED_1;
        res += z * (0x092492492492492492492492492492492 - y) / 0x400000000000000000000000000000000; z = z * w / _FIXED_1;
        res += z * (0x08e38e38e38e38e38e38e38e38e38e38e - y) / 0x500000000000000000000000000000000; z = z * w / _FIXED_1;
        res += z * (0x08ba2e8ba2e8ba2e8ba2e8ba2e8ba2e8b - y) / 0x600000000000000000000000000000000; z = z * w / _FIXED_1;
        res += z * (0x089d89d89d89d89d89d89d89d89d89d89 - y) / 0x700000000000000000000000000000000; z = z * w / _FIXED_1;
        res += z * (0x088888888888888888888888888888888 - y) / 0x800000000000000000000000000000000;
        return res;
    }}

    function _optimalExp(uint256 x) private pure returns (uint256) { unchecked {
        uint256 res = 0; uint256 y; uint256 z;
        z = y = x % 0x10000000000000000000000000000000;
        z = z * y / _FIXED_1; res += z * 0x10e1b3be415a0000;
        z = z * y / _FIXED_1; res += z * 0x05a0913f6b1e0000;
        z = z * y / _FIXED_1; res += z * 0x0168244fdac78000;
        z = z * y / _FIXED_1; res += z * 0x004807432bc18000;
        z = z * y / _FIXED_1; res += z * 0x000c0135dca04000;
        z = z * y / _FIXED_1; res += z * 0x0001b707b1cdc000;
        z = z * y / _FIXED_1; res += z * 0x000036e0f639b800;
        z = z * y / _FIXED_1; res += z * 0x00000618fee9f800;
        z = z * y / _FIXED_1; res += z * 0x0000009c197dcc00;
        z = z * y / _FIXED_1; res += z * 0x0000000e30dce400;
        z = z * y / _FIXED_1; res += z * 0x000000012ebd1300;
        z = z * y / _FIXED_1; res += z * 0x0000000017499f00;
        z = z * y / _FIXED_1; res += z * 0x0000000001a9d480;
        z = z * y / _FIXED_1; res += z * 0x00000000001c6380;
        z = z * y / _FIXED_1; res += z * 0x000000000001c638;
        z = z * y / _FIXED_1; res += z * 0x0000000000001ab8;
        z = z * y / _FIXED_1; res += z * 0x000000000000017c;
        z = z * y / _FIXED_1; res += z * 0x0000000000000014;
        z = z * y / _FIXED_1; res += z * 0x0000000000000001;
        res = res / 0x21c3677c82b40000 + y + _FIXED_1;
        if ((x & 0x010000000000000000000000000000000) != 0) res = res * 0x1c3d6a24ed82218787d624d3e5eba95f9 / 0x18ebef9eac820ae8682b9793ac6d1e776;
        if ((x & 0x020000000000000000000000000000000) != 0) res = res * 0x18ebef9eac820ae8682b9793ac6d1e778 / 0x1368b2fc6f9609fe7aceb46aa619baed4;
        if ((x & 0x040000000000000000000000000000000) != 0) res = res * 0x1368b2fc6f9609fe7aceb46aa619baed5 / 0x0bc5ab1b16779be3575bd8f0520a9f21f;
        if ((x & 0x080000000000000000000000000000000) != 0) res = res * 0x0bc5ab1b16779be3575bd8f0520a9f21e / 0x0454aaa8efe072e7f6ddbab84b40a55c9;
        if ((x & 0x100000000000000000000000000000000) != 0) res = res * 0x0454aaa8efe072e7f6ddbab84b40a55c5 / 0x00960aadc109e7a3bf4578099615711ea;
        if ((x & 0x200000000000000000000000000000000) != 0) res = res * 0x00960aadc109e7a3bf4578099615711d7 / 0x0002bf84208204f5977f9a8cf01fdce3d;
        if ((x & 0x400000000000000000000000000000000) != 0) res = res * 0x0002bf84208204f5977f9a8cf01fdc307 / 0x0000003c6ab775dd0b95b4cbee7e65d11;
        return res;
    }}

    // IntegralMath.floorLog2
    function _floorLog2(uint256 n) private pure returns (uint8) { unchecked {
        uint8 res = 0;
        if (n < 256) { while (n > 1) { n >>= 1; res += 1; } }
        else { for (uint8 s = 128; s > 0; s >>= 1) { if (n >= 1 << s) { n >>= s; res |= s; } } }
        return res;
    }}

    // IntegralMath.mulDivF
    function _mulDivF(uint256 x, uint256 y, uint256 z) private pure returns (uint256) { unchecked {
        (uint256 xyh, uint256 xyl) = _mul512(x, y);
        if (xyh == 0) return xyl / z;
        if (xyh < z) {
            uint256 m = mulmod(x, y, z);
            (uint256 nh, uint256 nl) = _sub512(xyh, xyl, m);
            if (nh == 0) return nl / z;
            uint256 p = (~z + 1) & z;
            uint256 q = _div512(nh, nl, p);
            uint256 r = _inv256(z / p);
            return q * r;
        }
        revert();
    }}

    function _mul512(uint256 x, uint256 y) private pure returns (uint256, uint256) { unchecked {
        uint256 p = mulmod(x, y, type(uint256).max);
        uint256 q = x * y;
        if (p >= q) return (p - q, q);
        return (p - q - 1, q); // underflow intentional
    }}

    function _sub512(uint256 xh, uint256 xl, uint256 y) private pure returns (uint256, uint256) { unchecked {
        if (xl >= y) return (xh, xl - y);
        return (xh - 1, xl - y); // underflow intentional
    }}

    function _div512(uint256 xh, uint256 xl, uint256 pow2n) private pure returns (uint256) { unchecked {
        uint256 pow2nInv = (~pow2n + 1) / pow2n + 1;
        return xh * pow2nInv | (xl / pow2n);
    }}

    function _inv256(uint256 d) private pure returns (uint256) { unchecked {
        uint256 x = 1;
        for (uint256 i = 0; i < 8; ++i) x = x * (2 - x * d);
        return x;
    }}

    // maxExpArray[32..127] as a pure lookup (replaces contract storage)
    function _maxExpArray(uint8 i) private pure returns (uint256) { unchecked {
        if (i == 32)  return 0x1c35fedd14ffffffffffffffffffffffff;
        if (i == 33)  return 0x1b0ce43b323fffffffffffffffffffffff;
        if (i == 34)  return 0x19f0028ec1ffffffffffffffffffffffff;
        if (i == 35)  return 0x18ded91f0e7fffffffffffffffffffffff;
        if (i == 36)  return 0x17d8ec7f0417ffffffffffffffffffffff;
        if (i == 37)  return 0x16ddc6556cdbffffffffffffffffffffff;
        if (i == 38)  return 0x15ecf52776a1ffffffffffffffffffffff;
        if (i == 39)  return 0x15060c256cb2ffffffffffffffffffffff;
        if (i == 40)  return 0x1428a2f98d72ffffffffffffffffffffff;
        if (i == 41)  return 0x13545598e5c23fffffffffffffffffffff;
        if (i == 42)  return 0x1288c4161ce1dfffffffffffffffffffff;
        if (i == 43)  return 0x11c592761c666fffffffffffffffffffff;
        if (i == 44)  return 0x110a688680a757ffffffffffffffffffff;
        if (i == 45)  return 0x1056f1b5bedf77ffffffffffffffffffff;
        if (i == 46)  return 0x0faadceceeff8bffffffffffffffffffff;
        if (i == 47)  return 0x0f05dc6b27edadffffffffffffffffffff;
        if (i == 48)  return 0x0e67a5a25da4107fffffffffffffffffff;
        if (i == 49)  return 0x0dcff115b14eedffffffffffffffffffff;
        if (i == 50)  return 0x0d3e7a392431239fffffffffffffffffff;
        if (i == 51)  return 0x0cb2ff529eb71e4fffffffffffffffffff;
        if (i == 52)  return 0x0c2d415c3db974afffffffffffffffffff;
        if (i == 53)  return 0x0bad03e7d883f69bffffffffffffffffff;
        if (i == 54)  return 0x0b320d03b2c343d5ffffffffffffffffff;
        if (i == 55)  return 0x0abc25204e02828dffffffffffffffffff;
        if (i == 56)  return 0x0a4b16f74ee4bb207fffffffffffffffff;
        if (i == 57)  return 0x09deaf736ac1f569ffffffffffffffffff;
        if (i == 58)  return 0x0976bd9952c7aa957fffffffffffffffff;
        if (i == 59)  return 0x09131271922eaa606fffffffffffffffff;
        if (i == 60)  return 0x08b380f3558668c46fffffffffffffffff;
        if (i == 61)  return 0x0857ddf0117efa215bffffffffffffffff;
        if (i == 62)  return 0x07ffffffffffffffffffffffffffffffff;
        if (i == 63)  return 0x07abbf6f6abb9d087fffffffffffffffff;
        if (i == 64)  return 0x075af62cbac95f7dfa7fffffffffffffff;
        if (i == 65)  return 0x070d7fb7452e187ac13fffffffffffffff;
        if (i == 66)  return 0x06c3390ecc8af379295fffffffffffffff;
        if (i == 67)  return 0x067c00a3b07ffc01fd6fffffffffffffff;
        if (i == 68)  return 0x0637b647c39cbb9d3d27ffffffffffffff;
        if (i == 69)  return 0x05f63b1fc104dbd39587ffffffffffffff;
        if (i == 70)  return 0x05b771955b36e12f7235ffffffffffffff;
        if (i == 71)  return 0x057b3d49dda84556d6f6ffffffffffffff;
        if (i == 72)  return 0x054183095b2c8ececf30ffffffffffffff;
        if (i == 73)  return 0x050a28be635ca2b888f77fffffffffffff;
        if (i == 74)  return 0x04d5156639708c9db33c3fffffffffffff;
        if (i == 75)  return 0x04a23105873875bd52dfdfffffffffffff;
        if (i == 76)  return 0x0471649d87199aa990756fffffffffffff;
        if (i == 77)  return 0x04429a21a029d4c1457cfbffffffffffff;
        if (i == 78)  return 0x0415bc6d6fb7dd71af2cb3ffffffffffff;
        if (i == 79)  return 0x03eab73b3bbfe282243ce1ffffffffffff;
        if (i == 80)  return 0x03c1771ac9fb6b4c18e229ffffffffffff;
        if (i == 81)  return 0x0399e96897690418f785257fffffffffff;
        if (i == 82)  return 0x0373fc456c53bb779bf0ea9fffffffffff;
        if (i == 83)  return 0x034f9e8e490c48e67e6ab8bfffffffffff;
        if (i == 84)  return 0x032cbfd4a7adc790560b3337ffffffffff;
        if (i == 85)  return 0x030b50570f6e5d2acca94613ffffffffff;
        if (i == 86)  return 0x02eb40f9f620fda6b56c2861ffffffffff;
        if (i == 87)  return 0x02cc8340ecb0d0f520a6af58ffffffffff;
        if (i == 88)  return 0x02af09481380a0a35cf1ba02ffffffffff;
        if (i == 89)  return 0x0292c5bdd3b92ec810287b1b3fffffffff;
        if (i == 90)  return 0x0277abdcdab07d5a77ac6d6b9fffffffff;
        if (i == 91)  return 0x025daf6654b1eaa55fd64df5efffffffff;
        if (i == 92)  return 0x0244c49c648baa98192dce88b7ffffffff;
        if (i == 93)  return 0x022ce03cd5619a311b2471268bffffffff;
        if (i == 94)  return 0x0215f77c045fbe885654a44a0fffffffff;
        if (i == 95)  return 0x01ffffffffffffffffffffffffffffffff;
        if (i == 96)  return 0x01eaefdbdaaee7421fc4d3ede5ffffffff;
        if (i == 97)  return 0x01d6bd8b2eb257df7e8ca57b09bfffffff;
        if (i == 98)  return 0x01c35fedd14b861eb0443f7f133fffffff;
        if (i == 99)  return 0x01b0ce43b322bcde4a56e8ada5afffffff;
        if (i == 100) return 0x019f0028ec1fff007f5a195a39dfffffff;
        if (i == 101) return 0x018ded91f0e72ee74f49b15ba527ffffff;
        if (i == 102) return 0x017d8ec7f04136f4e5615fd41a63ffffff;
        if (i == 103) return 0x016ddc6556cdb84bdc8d12d22e6fffffff;
        if (i == 104) return 0x015ecf52776a1155b5bd8395814f7fffff;
        if (i == 105) return 0x015060c256cb23b3b3cc3754cf40ffffff;
        if (i == 106) return 0x01428a2f98d728ae223ddab715be3fffff;
        if (i == 107) return 0x013545598e5c23276ccf0ede68034fffff;
        if (i == 108) return 0x01288c4161ce1d6f54b7f61081194fffff;
        if (i == 109) return 0x011c592761c666aa641d5a01a40f17ffff;
        if (i == 110) return 0x0110a688680a7530515f3e6e6cfdcdffff;
        if (i == 111) return 0x01056f1b5bedf75c6bcb2ce8aed428ffff;
        if (i == 112) return 0x00faadceceeff8a0890f3875f008277fff;
        if (i == 113) return 0x00f05dc6b27edad306388a600f6ba0bfff;
        if (i == 114) return 0x00e67a5a25da41063de1495d5b18cdbfff;
        if (i == 115) return 0x00dcff115b14eedde6fc3aa5353f2e4fff;
        if (i == 116) return 0x00d3e7a3924312399f9aae2e0f868f8fff;
        if (i == 117) return 0x00cb2ff529eb71e41582cccd5a1ee26fff;
        if (i == 118) return 0x00c2d415c3db974ab32a51840c0b67edff;
        if (i == 119) return 0x00bad03e7d883f69ad5b0a186184e06bff;
        if (i == 120) return 0x00b320d03b2c343d4829abd6075f0cc5ff;
        if (i == 121) return 0x00abc25204e02828d73c6e80bcdb1a95bf;
        if (i == 122) return 0x00a4b16f74ee4bb2040a1ec6c15fbbf2df;
        if (i == 123) return 0x009deaf736ac1f569deb1b5ae3f36c130f;
        if (i == 124) return 0x00976bd9952c7aa957f5937d790ef65037;
        if (i == 125) return 0x009131271922eaa6064b73a22d0bd4f2bf;
        if (i == 126) return 0x008b380f3558668c46c91c49a2f8e967b9;
        if (i == 127) return 0x00857ddf0117efa215952912839f6473e6;
        revert("maxExpArray: out of range");
    }}

    function _max(int128[MAX_SIDES] memory q, uint8 n)
        internal pure returns (int256 m) {
        m = int256(q[0]);
        for (uint8 j = 1; j < n; j++)
            if (int256(q[j]) > m) m = int256(q[j]);
    }

    struct StakedPairs {
        uint8[4] base; // Base token indices
        uint8[4] staked;  // Corresponding staked token indices
    }

    function getStakedPrice(address oracle, uint8 oracleType)
        public view returns (uint price) {
        if (oracleType == ORACLE_DSR_RATE) {
            price = IDSRRate(oracle).getRate();
        } else if (oracleType == ORACLE_CRV) {
            price = ISCRVOracle(oracle).pricePerShare();
        } else if (oracleType == ORACLE_CHAINLINK) {
            (, int answer,, uint ts,) = IChainlinkOracle(oracle).latestRoundData();
            price = uint(answer);
            if (ts == 0 || ts > block.timestamp) revert StaleOracle();
        }
        if (price < WAD) revert BadPrice();
    }

    function getBaseIndex(uint idx,
        StakedPairs memory pairs)
        internal pure returns (uint) {
        for (uint i = 0; i < 4; i++)
            if (pairs.staked[i] == idx)
                return pairs.base[i];

        return idx;
    }

    function getCombinedDeposits(uint base, uint[14] memory deps,
        StakedPairs memory pairs) internal pure returns (uint) {
        uint combined = deps[base + 2];
        for (uint i = 0; i < 4; i++)
            if (pairs.base[i] == base) {
                combined += deps[pairs.staked[i] + 2];
                break;
            }
        return combined;
    }

    function isStakedToken(uint idx,
        StakedPairs memory pairs)
        internal pure returns (bool) {
        for (uint i = 0; i < 4; i++)
            if (pairs.staked[i] == idx)
                return true;

        return false;
    }

    function calcFeeWithPairs(uint idx, uint[14] memory deps,
        StakedPairs memory pairs, address[] memory stables,
        address hook) external view returns (uint) {
        uint base = getBaseIndex(idx, pairs);
        if (IHook(hook).stablecoinToSide(stables[base]) == 0) return BASE;

        Types.DepegStats memory stats = IHook(hook).getDepegStats(stables[base]);
        if (stats.side == 0) return BASE;

        uint totalDeposits = deps[1];
        if (totalDeposits == 0) return BASE;

        uint thisRisk = calcRisk(stats);
        uint totalExposure;
        for (uint i = 0; i < stables.length; i++) {
            if (isStakedToken(i, pairs)) continue;
            uint combined = getCombinedDeposits(i, deps, pairs);
            if (combined < 100 * WAD) continue;
            uint8 side = IHook(hook).stablecoinToSide(stables[i]);
            if (side == 0) continue;
            Types.DepegStats memory s = IHook(hook).getDepegStats(stables[i]);
            if (s.side > 0) {
                uint risk = calcRisk(s);
                totalExposure += (combined * risk) / totalDeposits;
            }
        } return calcFee(thisRisk, totalExposure);
    }

    function calcFeePoly(uint idx, uint[8] memory deps,
        address[] memory stables, address hook) external view returns (uint) {
        if (IHook(hook).stablecoinToSide(stables[idx]) == 0) return BASE;
        Types.DepegStats memory stats = IHook(hook).getDepegStats(stables[idx]);
        if (stats.side == 0 || deps[1] == 0) return BASE;
        uint thisRisk = calcRisk(stats); uint totalExposure;
        for (uint i = 0; i < 6; i++) {
            if (deps[i + 2] < 100 * WAD) continue;
            uint8 side = IHook(hook).stablecoinToSide(stables[i]);
            if (side == 0) continue;
            Types.DepegStats memory s = IHook(hook).getDepegStats(stables[i]);
            if (s.side > 0) { uint risk = calcRisk(s);
                totalExposure += (deps[i + 2] * risk) / deps[1];
            }
        } return calcFee(thisRisk, totalExposure);
    }

    function calcWithdrawAmounts(uint amount,
        uint[14] memory deposits, int indexToSkip,
        bool strict, uint[3] memory prices,
        uint8[3] memory priceIndices,
        uint16 sixDecMask) public pure
        returns (uint[12] memory w) {
        uint totalDeposits = deposits[1];
        if (totalDeposits == 0) return w;
        for (uint i = 0; i < 12; i++) {
            if (int(i) == indexToSkip) continue;

            w[i] = _calcOne(amount, totalDeposits,
                deposits[i + 2], i, strict, prices,
                priceIndices, sixDecMask);
        }
    }

    function _calcOne(uint amount, uint total, uint dep,
        uint i, bool strict, uint[3] memory prices,
        uint8[3] memory priceIndices, uint16 sixDecMask)
        internal pure returns (uint out) { uint p;
        if (dep == 0) return 0;
        uint share = FullMath.mulDiv(amount, dep, total);
        // Apply staked price conversion if index has a price
        if (priceIndices[0] == i) p = prices[0];
        else if (priceIndices[1] == i) p = prices[1];
        else if (priceIndices[2] == i) p = prices[2];
        if (p > 0 && p != WAD)
            share = FullMath.mulDiv(share, WAD, p);

        // Apply 6-decimal divisor if bit is set
        bool isSixDec = (sixDecMask >> i) & 1 == 1;
        if (isSixDec) {
            share = share / 1e12;
            if (strict && share * 1e12 > dep)
                share = dep / 1e12;
        } else if (strict && share > dep)
            share = dep;

        out = share;
    }

    /// @notice Entropy-weighted adaptive liquidity parameter.
    /// @dev b grows only when capital is uniformly distributed across sides.
    ///      A whale concentrating capital on one side produces low entropy →
    ///      b barely moves → thin sides stay protected.
    ///      A healthy market with genuine multi-side participation earns deeper
    ///      liquidity, making late-round manipulation progressively more expensive.
    ///
    ///      Formula (from simulation):
    ///        H            = -Σ p_i × ln(p_i)   (Shannon entropy of capital dist.)
    ///        entropy_ratio = H / ln(n)           (0=fully concentrated, 1=uniform)
    ///        total_scale  = (totalCap / (INITIAL_B × n)) ^ 0.25   capped at 6
    ///        b_target     = INITIAL_B × (1 + (total_scale − 1) × entropy_ratio)
    ///
    ///      The ^0.25 exponent keeps growth conservative — b only compounds when
    ///      entropy stays high across multiple rounds.
    ///
    ///      Optional EMA smoothing (alpha=0.3) damps round-to-round variance:
    ///        b_new = 0.3 × b_target + 0.7 × b_prev
    ///      Pass b_prev = 0 to skip EMA (first round, or if caller tracks state).
    ///
    /// @param capitalPerSide  Capital deposited per outcome this round (WAD)
    /// @param n               Number of active sides
    /// @param b_prev          Previous round's b (pass 0 to skip EMA)
    /// @return b_new          Adaptive b for this round (WAD, int128)
    function adaptiveB(uint[MAX_SIDES] memory capitalPerSide,
        uint8 n, int128 b_prev) public pure returns (int128 b_new) {
        require(n >= 2 && n <= MAX_SIDES, "adaptiveB: n out of range");

        uint totalCap; uint H_WAD;
        for (uint8 i; i < n; i++) totalCap += capitalPerSide[i];
        if (totalCap == 0) return INITIAL_B;

        // ── 2. Shannon entropy of capital distribution ────────────────
        // H = -Σ (p_i × ln(p_i))  computed in fixed-point WAD arithmetic.
        // We use the AnalyticMath log inlined as _amLog.
        // Entropy is accumulated in WAD units; H_max = ln(n) × WAD.
        for (uint8 i; i < n; i++) {
            if (capitalPerSide[i] == 0) continue;
            // p_i = capitalPerSide[i] / totalCap  (WAD fraction)
            // ln(p_i) = _amLog(capitalPerSide[i], totalCap) → (num, den)
            // term = p_i × |ln(p_i)|   (entropy term, always positive since p_i ≤ 1)
            uint pWAD = FullMath.mulDiv(capitalPerSide[i], WAD, totalCap);
            (uint lnN, uint lnD) = _amLog(totalCap, capitalPerSide[i]); // ln(1/p_i) = -ln(p_i)
            uint lnTerm = FullMath.mulDiv(lnN, WAD, lnD);               // |ln(p_i)| in WAD
            H_WAD += FullMath.mulDiv(pWAD, lnTerm, WAD);                // p_i × |ln(p_i)|
        }
        // H_max = ln(n) × WAD
        // Use _amLog(n, 1) but we need integer log — use _amLog scaled.
        // ln(n): pass (n × WAD, WAD) → gives ln(n) as (num/den) pair.
        (uint lnNnum, uint lnNden) = _amLog(uint(n) * WAD, WAD);
        uint H_max_WAD = FullMath.mulDiv(lnNnum, WAD, lnNden);
        if (H_max_WAD == 0) return INITIAL_B; // n==1 guard (already blocked above)

        // entropy_ratio in WAD: 0 → concentrated, WAD → uniform
        uint entropyRatioWAD = FullMath.mulDiv(H_WAD, WAD, H_max_WAD);
        // clamp to [0, WAD]
        if (entropyRatioWAD > WAD) entropyRatioWAD = WAD;

        // ── 3. Total-capital scale factor (^0.25, conservative growth) ───────
        // total_scale = (totalCap / (INITIAL_B × n)) ^ 0.25
        // Compute ratio = totalCap / (INITIAL_B × n) in WAD.
        uint denom = uint(uint128(INITIAL_B)) * uint(n); // INITIAL_B is WAD
        uint ratioWAD = FullMath.mulDiv(totalCap, WAD, denom);
        if (ratioWAD < WAD) ratioWAD = WAD; // floor at 1.0 — never shrink b

        // ^0.25 via two successive sqrt (integer Newton's method).
        uint scaleWAD = _sqrtWAD(_sqrtWAD(ratioWAD));

        // cap scale at 6× → b capped at MAX_B
        uint sixWAD = 6 * WAD;
        if (scaleWAD > sixWAD) scaleWAD = sixWAD;

        // 4. b_target = INITIAL_B × (1 + (scale − 1) × entropy_ratio)
        // excess = (scale − 1) × entropy_ratio   (both in WAD)
        uint excessWAD = FullMath.mulDiv(scaleWAD - WAD, entropyRatioWAD, WAD);
        uint b_target_WAD = uint(uint128(INITIAL_B)) + FullMath.mulDiv(
                              uint(uint128(INITIAL_B)), excessWAD, WAD);
        // ── 5. Optional EMA smoothing (alpha = 0.3 = 3/10) ──────────
        uint b_new_WAD;
        if (b_prev > 0) {
            // b_new = 0.3 × b_target + 0.7 × b_prev
            uint bp = uint(uint128(b_prev));
            b_new_WAD = (3 * b_target_WAD + 7 * bp) / 10;
        } else {
            b_new_WAD = b_target_WAD;
        }
        // floor at INITIAL_B, ceil at MAX_B
        if (b_new_WAD < uint(uint128(INITIAL_B))) b_new_WAD = uint(uint128(INITIAL_B));
        if (b_new_WAD > uint(uint128(MAX_B)))      b_new_WAD = uint(uint128(MAX_B));

        b_new = int128(int256(b_new_WAD));
    }

    /// @dev Integer sqrt on WAD-scaled values. Returns floor(sqrt(x)) in WAD.
    ///      Input x is a WAD ratio (e.g. 2e18 = 2.0).
    ///      Output is also WAD (e.g. sqrt(2e18) ≈ 1.414e18).
    function _sqrtWAD(uint x) private pure returns (uint) { unchecked {
        // Newton's method on x × WAD (to keep WAD scaling through sqrt)
        if (x == 0) return 0;
        uint y = x * WAD;
        uint z = (y + WAD) / 2;
        while (z < y) { y = z; z = (y + x * WAD / y) / 2; }
        return y / 1e9; // sqrt(x × WAD) / sqrt(WAD) = sqrt(x) in WAD (1e9 = sqrt(1e18))
    }}

    // ═══════════════════════════════════════════════════════════════
    //  LMSR helpers — public so Link uses DELEGATECALL, keeping
    //  these bytes off Link's 24 576-byte budget.
    // ═══════════════════════════════════════════════════════════════

    function buyTokens(int128[12] memory q, 
        uint8 numSides, int128 b, uint8 side, uint netCap)
        public pure returns (uint tokens, int128 deltaQ) {
        int128 capWAD = int128(int256(netCap));
        int128 lo; int128 hi = capWAD * 
        int128(int256(uint256(numSides))) * 2;
        for (uint i; i < 64; i++) {
            int128 mid = (lo + hi) / 2;
            uint c = cost(q, numSides, b, side, mid);
            if (c <= uint(uint128(capWAD))) 
                lo = mid; 
            else hi = mid;
            if (hi - lo <= 1) break;
        } tokens = uint(uint128(lo)); deltaQ = lo;
    }

    function sellTokens(int128[12] memory q, uint8 numSides, 
                        int128 b, uint8 side, uint tokSell)
        public pure returns (uint returned, int128 deltaQ) {
        int128 tokWAD = int128(int256(tokSell));
        returned = cost(q, numSides, b, side, -tokWAD);
        deltaQ = tokWAD;
    }

    function _entryEffectiveCap(uint capital,
        uint decay, uint priceAtEntry,
        uint confidence) internal pure returns (uint) {
        uint pae = priceAtEntry < 10_000 ? priceAtEntry : 9_999;
        uint joint = (10_000 - pae) * confidence / 10_000;
        return capital * decay / 10_000 * joint / 10_000;
    }

    function _computeDecay(uint timestamp,
        uint roundStart, uint resTs,
        uint lambda, uint floor) 
        internal pure returns (uint decay) {
        if (resTs <= roundStart) return 10_000;

        uint mktD = resTs - roundStart;
        uint posD = timestamp >= resTs ? 0 : 
                    timestamp >= roundStart ? 
                    resTs - timestamp : mktD;

        uint p = posD * 10_000 / mktD;
        if (p > 10_000) p = 10_000;
        if (lambda <= 100) {
            decay = p;
        } else if (lambda <= 200) {
            uint t = lambda - 100;
            uint qd = p * p / 10_000;
            decay = (p * (100 - t) + qd * t) / 100;
        } else {
            uint qd = p * p / 10_000;
            decay = qd * p / 10_000;
        }
        if (decay < floor) decay = floor;
    }

    function computeWeight(uint[] memory capitals,
        uint[] memory timestamps, uint[] memory pricesAtEntry,
        uint roundStart, uint resTs, uint confidence, 
        bool isWinner) public pure returns (uint weight) {
        uint timeWeightedCap; bool usePAE = !isWinner && 
        pricesAtEntry.length == capitals.length;
        for (uint j; j < capitals.length; j++) {
            uint decay = _computeDecay(timestamps[j], 
            roundStart, resTs, LAMBDA, DECAY_FLOOR);

            timeWeightedCap += usePAE
                ? _entryEffectiveCap(capitals[j], 
                decay, pricesAtEntry[j], confidence)
                : capitals[j] * decay / 10_000;
        }
        uint twcWAD = timeWeightedCap * 1e18 / 10_000;
        weight = isWinner ? FullMath.mulDiv(confidence * 1e18 / 10_000, twcWAD, 1e18): twcWAD;
    }

    function computePayout(uint capital, uint weight, uint totalWinWeight,
        uint totalLoseWeight, uint totalLoserCap, uint consolBps, bool isWinner)
        public pure returns (uint payout) { uint winnerPool; uint consolPool;
        if (totalWinWeight == 0) {
            if (!isWinner && totalLoseWeight > 0) {
                consolPool = FullMath.mulDiv(totalLoserCap, consolBps, 10000);
                return capital + FullMath.mulDiv(consolPool, weight, totalLoseWeight);
            } return capital; // winner capital returned as-is
        } else {
            winnerPool = FullMath.mulDiv(totalLoserCap, 
                10000 - consolBps, 10000);

            consolPool = totalLoserCap - winnerPool;
        } if (isWinner) {
            uint bonus = totalWinWeight > 0 ? FullMath.mulDiv(
                            winnerPool, weight, totalWinWeight) : 0;
            
            payout = capital + bonus;
        } else {
            payout = totalLoseWeight > 0 ? FullMath.mulDiv(
                        consolPool, weight, totalLoseWeight) : 0;
        }
    }

    function reduceEntries(uint[] memory capitals,
        uint[] memory tokens, uint tokensToSell, uint totalTokens) public pure
        returns (uint[] memory newCaps, uint[] memory newAlloc, uint totalCapReduced) {
        uint len = capitals.length; newCaps = new uint[](len); newAlloc = new uint[](len);
        for (uint i; i < len; i++) {
          newCaps[i] = capitals[i];
          newAlloc[i] = tokens[i];
        }
        uint take;

        uint remaining = tokensToSell;
        for (uint i; i < len; i++) {
            if (newAlloc[i] == 0) continue;
            if (remaining >= newAlloc[i]) take = newAlloc[i];
            else if (i == len - 1 || _isLastActive(newAlloc, i + 1, len)) take = remaining;
            else { take = (newAlloc[i] * tokensToSell) / totalTokens;
               if (take > remaining) take = remaining;
            }
            if (take >= newAlloc[i]) {
                totalCapReduced += newCaps[i];
                newCaps[i] = 0; newAlloc[i] = 0;
            } else {
                uint cap = (newCaps[i] * take) / newAlloc[i];
                newAlloc[i] -= take; newCaps[i] -= cap;
                totalCapReduced += cap;
            }
            remaining -= take;
            if (remaining == 0) break;
        }
    }

    function _isLastActive(uint[] memory tokens,
        uint start, uint end) private pure returns (bool) {
        for (uint j = start; j < end; j++)
            if (tokens[j] > 0) return false;
        return true;
    }
}
