
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Amp} from "../Amp.sol";
import {Rover} from "../Rover.sol";
import {Basket} from "../Basket.sol";
import {VogueCore} from "../VogueCore.sol";
import {Types} from "../imports/Types.sol";

import {VogueUni as Vogue} from "./VogueUni.sol";
import {BasketLib} from "../imports/BasketLib.sol";
import {FeeLib} from "../imports/FeeLib.sol";
import {IPool} from "aave-v3/interfaces/IPool.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";
import {WETH as WETH9} from "solmate/src/tokens/WETH.sol";
import {IUniswapV3Pool} from "../imports/v3/IUniswapV3Pool.sol";
import {ReentrancyGuard} from "solmate/src/utils/ReentrancyGuard.sol";
import {ISwapRouter} from "../imports/v3/ISwapRouter.sol";

interface ILink {
    function getDepegSeverityBps()
        external view returns (uint);

    function isDepegged(address token)
        external view returns (bool);

    function depegPending()
        external view returns (bool);

    function getDepegStats(address stablecoin)
        external view returns (Types.DepegStats memory);
}

/// @title AuxPolygon
/// @notice Polygon: 6 stables [USDC, USDT, DAI, FRAX, CRVUSD, SFRAX]
/// USDC/USDT -> Morpho vaults, DAI -> AAVE, FRAX/CRVUSD/SFRAX -> direct
/// Has Rover (V3) and AAVE
interface IFlashBorrower {
    function onFlashLoan(address initiator,
        address token, uint amount,
        uint shareBps, bytes calldata data)
        external returns (bytes32);
}

contract AuxPoly is // Auxiliary
    Ownable, ReentrancyGuard {
    address[] public stables;
    bool public token1isWETH;
    VogueCore internal CORE;

    IERC20 internal USDC;
    Basket internal QUID;
    address internal LINK;
    address internal JAM;
    IPool internal AAVE;
    Vogue internal V4;
    WETH9 public WETH;
    Rover internal V3;

    mapping(address => address) internal vaults;
    mapping(address => uint) internal deposits;
    mapping(address => uint) internal toIndex;

    mapping(address => uint) internal untouchables;
    bytes32 constant CALLBACK_SUCCESS = keccak256(
               "ERC3156FlashBorrower.onFlashLoan");

    IUniswapV3Pool internal v3PoolWETH;
    BasketLib.Metrics internal metrics;

    IERC4626 internal wethVault;
    uint internal untouchable;
    address internal v3Router;
    uint constant WAD = 1e18;
    uint24 internal v3Fee;
    Amp public AMP;

    error NotInitialized();
    error Unauthorized();
    error Untouchable();
    error InvalidToken();
    error NoDeposit();
    error TokenDepegged();
    error DepegInProgress();

    modifier onlyUs {
        if (msg.sender != address(V4)
         && msg.sender != address(CORE)
         && msg.sender != address(QUID)
         && msg.sender != address(this))
                revert Unauthorized(); _;
    }
    modifier onlyAmped {
        if (address(AMP) == address(0))
            revert NotInitialized(); _;
    }

    /// @param _vaults [usdcVault, usdtVault, aDAI_aToken]
    constructor(address _vogue, address _core,
        address _wethVault, address _amp,
        address _aave, address _v3poolWETH,
        address _v3router, address _v3,
        address[] memory _stables,
        address[] memory _vaults)
        Ownable(msg.sender) {
        stables = _stables;

        wethVault = IERC4626(_wethVault);
        v3PoolWETH = IUniswapV3Pool(_v3poolWETH);
        address token0 = v3PoolWETH.token0();
        address token1 = v3PoolWETH.token1();
        v3Fee = v3PoolWETH.fee();
        v3Router = _v3router;

        if (IERC20(token1).decimals() >
            IERC20(token0).decimals()) {
            WETH = WETH9(payable(token1));
            USDC = IERC20(token0);
            token1isWETH = true;
        } else { token1isWETH = false;
            WETH = WETH9(payable(token0));
            USDC = IERC20(token1);
        }
        AAVE = IPool(_aave);
        V4 = Vogue(payable(_vogue));
        CORE = VogueCore(_core);
        if (_amp != address(0))
            AMP = Amp(payable(_amp));
        if (_v3 != address(0))
            V3 = Rover(payable(_v3));

        // USDC, USDT -> Morpho vaults
        for (uint i = 0; i < 2; i++) {
            vaults[stables[i]] = _vaults[i];
            IERC20(stables[i]).approve(
            _vaults[i], type(uint).max);
            toIndex[stables[i]] = i + 1;
        } // DAI -> AAVE, store aToken
        // address for balance queries
        vaults[stables[2]] = _vaults[2];
        IERC20(stables[2]).approve(address(AAVE),
                                 type(uint).max);
        toIndex[stables[2]] = 3;
        // FRAX, CRVUSD, SFRAX -> direct
        for (uint i = 3; i < stables.length; i++)
            toIndex[stables[i]] = i + 1;

    } receive() external payable {}
    function get_metrics(bool force)
        public returns (uint, uint) {
        BasketLib.Metrics memory stats = metrics;
        uint elapsed = block.timestamp - stats.last;
        if (force || elapsed > 10 minutes) {
            uint[8] memory amounts = _fee_deposits();
            stats = BasketLib.computeMetrics(stats, elapsed,
                        amounts[0], amounts[1], amounts[1]);

            metrics = stats;
        } return (stats.total,
                  stats.yield);
    }

    function getAverageYield() public view returns (uint) {
        return BasketLib.getAverageYield(metrics);
    }

    function setQuid(address _quid,
        address _jam) external onlyOwner {
        renounceOwnership(); QUID = Basket(_quid);
        LINK = address(QUID.LINK()); JAM = _jam;
        USDC.approve(address(v3Router), type(uint).max);
        WETH.approve(address(v3Router), type(uint).max);
        WETH.approve(address(wethVault), type(uint).max);
        WETH.approve(address(AAVE), type(uint).max);
        WETH.approve(address(AMP), type(uint).max);
        USDC.approve(address(AMP), type(uint).max);
        WETH.approve(address(V3), type(uint).max);
        USDC.approve(address(V3), type(uint).max);
    }
    function getStables() external view
        returns (address[] memory) {
        // SFRAX (index 5) shares a side with FRAX.
        address[] memory bases = new address[](5);
        for (uint i; i < 5; i++) bases[i] = stables[i];
        return bases;
    }

    function getTWAP(uint32 period)
        public view returns (uint price) {
        uint32[] memory secondsAgos = new uint32[](2);
        int56[] memory tickCumulatives; bool token0isUSD;
        if (period == 0) { secondsAgos[0] = 1800; secondsAgos[1] = 0;
            (tickCumulatives, ) = v3PoolWETH.observe(secondsAgos);
            period = 1800; token0isUSD = token1isWETH;
        } else {
            secondsAgos[0] = period; secondsAgos[1] = 0;
            tickCumulatives = CORE.observe(secondsAgos);
            token0isUSD = V4.token1isETH();
        }
        price = BasketLib.ticksToPrice(tickCumulatives[0],
                 tickCumulatives[1], period, token0isUSD);
    }

    function v3Fair(uint twapPrice) public view returns (bool) {
        return !BasketLib.isV3Manipulated(address(v3PoolWETH),
                                      token1isWETH, twapPrice);
    }

    /// @param token either token we are paying or want to get
    /// @param forETH ^ for $ --> ETH, opposite for ETH --> $
    /// @param amount Amount to swap (either ETH, QD, or $)
    /// @param minOut Minimum output (slippage protection)
    function swap(address token, bool forETH, uint amount, uint minOut)
        public payable nonReentrant returns (uint max) { bool stable;
        bool zeroForOne; Types.AuxContext memory ctx = _buildContext();
        (uint160 sqrtPriceX96,,,) = V4.repack();

        stable = toIndex[token] > 0;
        if (forETH && stable && token != address(QUID)) {
            if (ILink(LINK).isDepegged(_depegLookup(token)))
                revert TokenDepegged();
        } if (!forETH) {
            if (token != address(QUID)) require(stable);
            amount = _depositETH(msg.sender, amount);
            zeroForOne = !V4.token1isETH();
                 max = CORE.POOLED_USD();
        } else { max = CORE.POOLED_ETH();
            zeroForOne = V4.token1isETH();
            if (token == address(QUID)) {
                (uint burned, uint seedBurned) = QUID.turn(
                                        msg.sender, amount);
                amount = burned;
                if (seedBurned > 0) {
                    for (uint i = 0; i < stables.length; i++) {
                        uint share = FullMath.mulDiv(
                            untouchables[stables[i]],
                            seedBurned, burned);
                        _tip(share, stables[i], -1);
                    }
                }
            } else amount = deposit(msg.sender,
                                token, amount);
                                token = address(0);

        } (max,) = BasketLib.routeSwap(ctx,
            Types.RouteParams({ sqrtPriceX96: sqrtPriceX96,
                zeroForOne: zeroForOne, token: token,
                recipient: msg.sender, amount: amount,
                pooled: max, v4Price: getTWAP(1800),
                v3Price: getTWAP(0) }));
                 require(max >= minOut);
    }

    function _buildContext() internal view returns (Types.AuxContext memory) {
        return Types.AuxContext({ v3Pool: address(v3PoolWETH), v3Router: v3Router,
            weth: address(WETH), usdc: address(USDC), vault: address(wethVault),
            v4: address(V4), core: address(CORE), rover: address(V3), v3Fee: v3Fee,
            hub: address(0), vaultType: 0, nativeWETH: false });
    }

    function arbETH(uint shortfall)
        public onlyUs returns (uint got) {
        (got,) = BasketLib.arbETH(_buildContext(),
                            shortfall, getTWAP(0));
    }

    /// @notice leveraged long (borrow WETH against USDC)
    /// @dev 70% LTV on AAVE, excess USDC as collateral
    /// @param amount WETH amount to deposit in AAVE
    function leverETH(uint amount) payable
        external { uint twapPrice = getTWAP(0);
        amount = _depositETH(msg.sender, amount);
        uint usdcNeeded = BasketLib.convert(amount, twapPrice, false);
        uint took = _take(address(this), usdcNeeded, address(USDC), 0);
        if (took <= usdcNeeded) {
            require(!BasketLib.isV3Manipulated(address(v3PoolWETH),
                                         token1isWETH, twapPrice));

            (uint more, uint used) = BasketLib.source(_buildContext(),
                usdcNeeded - took, amount, twapPrice, true);

            took += more; amount -= used;
        } require(took >= usdcNeeded * 99 / 100);
        AMP.leverETH(msg.sender, amount, took / 1e12);
    }

    function leverUSD(uint amount, address token)
        external returns (uint usdcAmount) {
        usdcAmount = amount; uint160 sqrtPriceX96;
        if (token == address(USDC)) {
            USDC.transferFrom(msg.sender,
                address(this), usdcAmount);
        } else {
            (sqrtPriceX96,,,) = V4.repack();
            uint depositedAmount = deposit(
             msg.sender, token, usdcAmount);
            uint scale = IERC20(token).decimals() - 6;
            depositedAmount /= scale > 0 ? 10 ** scale : 1;

            // Swap stable → ETH → USDC through V4 pool
            uint wethBefore = WETH.balanceOf(address(this));
            CORE.swap(sqrtPriceX96, address(this),
            V4.token1isETH(), token, depositedAmount);
            uint ethReceived = WETH.balanceOf(address(this)) - wethBefore;

            // On Polygon, VogueUni uses wethVault (Morpho ERC4626), not AAVE.
            // Deposit WETH into the vault on behalf of V4, consistent
            // with how routeSwap and arbETH route Vogue-attributed ETH.
            wethVault.deposit(ethReceived, address(V4));

            uint usdcBefore = USDC.balanceOf(address(this));
            CORE.swap(sqrtPriceX96, address(this),
            !V4.token1isETH(), address(USDC), ethReceived);

            usdcAmount = USDC.balanceOf(
            address(this)) - usdcBefore;
        }   uint twapPrice = getTWAP(0);

        require(!BasketLib.isV3Manipulated(address(v3PoolWETH),
                                     token1isWETH, twapPrice));

        uint targetETH = BasketLib.convert(
           usdcAmount, getTWAP(1800), true);

        (uint inETH, uint spent) = BasketLib.source(_buildContext(),
                            targetETH, usdcAmount, twapPrice, false);
        usdcAmount -= spent;
        require(inETH >= targetETH * 99 / 100);
        USDC.approve(address(AMP), usdcAmount);
        AMP.leverUSD(msg.sender, usdcAmount, inETH);
    }

    function redeem(uint amount) external {
        if (ILink(LINK).depegPending()) revert DepegInProgress();
        uint price = getTWAP(1800); (uint total,) = get_metrics(false);
        (uint reserved, uint usdPart, uint ethExcess) = BasketLib.redeemSplit(total,
            CORE.POOLED_USD() * 1e12, wethVault.maxWithdraw(address(this)),
            CORE.POOLED_ETH(), price, amount);

        (uint burned,
         uint seedBurned) = QUID.turn(
                  msg.sender, usdPart);

        if (burned == 0) return;
        uint taken = _take(msg.sender,
        burned, address(QUID), seedBurned);
        if (taken < reserved) {
            uint ethToUse = Math.min(FullMath.mulDiv(
               reserved - taken, WAD, price), ethExcess);

            if (ethToUse > 0) { price = getTWAP(0);
                uint received = V4.takeETH(ethToUse, address(this));
                require(v3Fair(price));
                received = BasketLib.sourceExternalUSD(_buildContext(),
                                                      received, price);

                if (received > 0) IERC20(stables[0]).transfer(
                                         msg.sender, received);
            }
        }
    }

    /// @notice [raw, total, USDC, USDT, DAI, FRAX, CRVUSD, SFRAX]
    function _fee_deposits() internal view
        returns (uint[8] memory amounts) {
        uint balance; uint reserved;
        // USDC + USDT: Morpho vaults, 6-dec → scale to 18
        for (uint i; i < 2;) {
            address stable = stables[i];
            reserved = untouchables[stable];
            balance = IERC4626(vaults[stable]).maxWithdraw(address(this));
            uint res6 = reserved / 1e12;
            amounts[i + 2] = (balance > res6 ? balance - res6 : 0) * 1e12;
            balance = deposits[stable];
            amounts[0] += (balance > reserved ? balance - reserved : 0);
            unchecked { ++i; }
        }
        amounts[1] = amounts[2] + amounts[3];
        // DAI - AAVE aToken (18 dec)
        { address stable = stables[2];
          reserved = untouchables[stable];
          balance = IERC20(vaults[stable]).balanceOf(address(this));
          amounts[4] = balance > reserved ? balance - reserved : 0;
          amounts[0] += IERC20(stable).balanceOf(address(this));
          amounts[1] += amounts[4]; }

        // FRAX + CRVUSD: direct balances (18 dec)
        for (uint i = 3; i < 5;) {
            address stable = stables[i];
            reserved = untouchables[stable];
            balance = IERC20(stable).balanceOf(address(this));
            balance = balance > reserved ? balance - reserved : 0;
            amounts[i + 2] = balance;
            amounts[0] += balance;
            amounts[1] += balance;
            unchecked { ++i; }
        }
        // SFRAX - ERC4626 vault, price via share conversion (18 dec)
        { address stable = stables[5];
          reserved = untouchables[stable];
          balance = IERC20(stable).balanceOf(address(this));
          uint net = balance > reserved ? balance - reserved : 0;
          amounts[0] += net;
          if (net > 0) net = FullMath.mulDiv(
              IERC4626(stable).convertToAssets(WAD), net, WAD);
          amounts[7] = net;
          amounts[1] += net;
        }
    }

    /// @notice Basket-compatible: uint[14] with staked folded into base
    /// Matches getStables() order: USDC, USDT, DAI, FRAX, CRVUSD
    function get_deposits() public view
        returns (uint[14] memory out, uint avgYield) {
        uint[8] memory full = _fee_deposits();
        out[0] = full[0];              // yield-weighted
        out[1] = full[2];              // USDC
        out[2] = full[3];              // USDT
        out[3] = full[4];              // DAI
        out[4] = full[5] + full[7];    // FRAX + SFRAX
        out[5] = full[6];              // CRVUSD
        // [6..11] = 0 (fewer stables on Polygon)
        out[12] = full[1];             // TVL
        avgYield = getAverageYield();
    }

    function getFee(address token)
        public view returns (uint) {
        uint idx = type(uint).max;
        for (uint i = 0; i < stables.length; i++)
        if (stables[i] == token) { idx = i; break; }
        if (idx == type(uint).max) return 0;
        uint[8] memory deps = _fee_deposits();
        // Fold SFRAX (idx 5, deps[7]) into FRAX (idx 3, deps[5])
        // so calcFeePoly sees combined exposure on FRAX's side.
        deps[5] += deps[7]; deps[7] = 0;
        if (idx == 5) idx = 3; // SFRAX → FRAX
        return FeeLib.calcFeePoly(idx, deps,
                            stables, LINK);
    }

    /// @dev Resolve staked token → base for depeg lookup.
    /// SFRAX (toIndex 6, array idx 5) → FRAX (array idx 3).
    function _depegLookup(address token)
        internal view returns (address) {
        return toIndex[token] == 6 ?
                stables[3] : token;
    }

    // you let me in to a conversation, conversation only we could make
    // breaking into my imagination; whatever's in there: yours to take
    function _take(address who, uint amount, address token, uint seed)
        internal returns (uint sent) { uint withdrawn; uint reserved;
        int indexToSkip = -1;
        if (token != address(QUID)) {
            uint index = toIndex[token]; uint max;
            if (index == 0 || index > 6) revert InvalidToken();
            if (index < 3)
                max = IERC4626(vaults[token]).maxWithdraw(address(this));
            else if (index == 3)
                max = IERC20(vaults[token]).balanceOf(address(this));
            else max = IERC20(token).balanceOf(address(this));
            reserved = BasketLib.scaleTokenAmount(
                untouchables[token], token, false);

            max = max > reserved ? max - reserved : 0;
            uint fee = max > 0 ? (getFee(token) * WAD) / 10000 : 0;
            uint needed = (fee > 0 && fee < WAD / 10) ? FullMath.mulDiv(
                              amount, WAD - fee, WAD) : amount;

            // Haircut applies to ALL redeemers during depeg, not just seed
            Types.DepegStats memory ds = ILink(LINK).getDepegStats(_depegLookup(token));
            if (ds.depegged && ds.severityBps > 0) {
                uint retained = FullMath.mulDiv(
                  needed, ds.severityBps, 10000);
                needed -= retained;
            }

            indexToSkip = int(index - 1);
            if (seed > 0) { _tip(seed, token, -1);
                sent = _withdraw(who, index, needed);
                { uint scaled = BasketLib.scaleTokenAmount(sent, token, true);
                  deposits[token] -= Math.min(deposits[token], scaled); }
                return BasketLib.scaleTokenAmount(sent, token, true);
            }
            if (max >= needed) {
                withdrawn = _withdraw(who, index, needed);
                if (fee > 0) withdrawn = FullMath.mulDiv(
                                withdrawn, WAD - fee, WAD);

                { uint scaled = BasketLib.scaleTokenAmount(withdrawn, token, true);
                  deposits[token] -= Math.min(deposits[token], scaled); }
                return BasketLib.scaleTokenAmount(withdrawn, token, true);
            } else {
                withdrawn = _withdraw(who, index, max);
                if (fee > 0) sent = FullMath.mulDiv(
                          withdrawn, WAD - fee, WAD);
                else sent = withdrawn;

                amount -= sent;
                { uint scaled = BasketLib.scaleTokenAmount(sent, token, true);
                  deposits[token] -= Math.min(deposits[token], scaled); }
                sent = BasketLib.scaleTokenAmount(sent, token, true);
            }
        } amount = BasketLib.scaleTokenAmount(
                          amount, token, true);
        if (amount > 0) {
            uint[8] memory amounts = _fee_deposits();
            amount = seed == 0 ? Math.min(amounts[1], amount) : amount;
            if (amounts[1] == 0 || amount == 0) return sent;
            sent += _executeProRata(who, amount,
                    amounts, indexToSkip, seed);
        }
    }

    function _executeProRata(address who, uint amount,
        uint[8] memory amounts, int indexToSkip,
        uint seed) private returns (uint sent) {
        if (amounts[1] == 0 || amount == 0) return 0;
        for (uint i = 0; i < 6; i++) {
            if (int(i) == indexToSkip
             || amounts[i + 2] == 0) continue;

            uint dep = amounts[i + 2];
            uint share = FullMath.mulDiv(amount,
                FullMath.mulDiv(WAD, dep, amounts[1]), WAD);

            if (seed == 0 && share > dep) share = dep;
            if (seed > 0) _tip(FullMath.mulDiv(share,
                seed, amount), stables[i], -1);

            Types.DepegStats memory dsPR = ILink(LINK).getDepegStats(
                                            _depegLookup(stables[i]));

            if (dsPR.depegged && dsPR.severityBps > 0 && dsPR.severityBps < 10000)
                share -= FullMath.mulDiv(share, dsPR.severityBps, 10000);

            if (i < 2) share /= 1e12;
            if (share > 0) sent += _executeWithdraw(
                                      who, i, share);
        }
    }

    function _executeWithdraw(address who, uint i,
        uint amt) private returns (uint out) {
        uint divisor = (i < 2) ? 1e12 : 1;
        address stable = stables[i]; out = amt * divisor;
        deposits[stable] -= Math.min(deposits[stable], out);
        if (i < 2) {
            out = _withdraw(who, i + 1, amt) * divisor;
        } else if (i == 2) {
            out = AAVE.withdraw(stable, amt, address(this));
            IERC20(stable).transfer(who, out);
        } else {
            IERC20(stable).transfer(who, amt);
        }
    }

    function take(address who, uint amount, address token,
        uint seed) public onlyUs returns (uint) {
            return _take(who, amount, token, seed);
    }

    function _withdraw(address to,
        uint toIndex, uint amount)
        internal returns (uint sent) {
        if (amount == 0) return 0;
        if (toIndex < 3)  {
            address vault = vaults[stables[toIndex - 1]];
            (uint shares,
             uint assets) = BasketLib.calculateVaultWithdrawal(
                                                 vault, amount);
            if (shares == 0) return 0;
            sent = IERC4626(vault).redeem(
                shares, to, address(this));
        }
        else if (toIndex == 3) {
            sent = AAVE.withdraw(
            stables[2], amount, to);
        }
        else { sent = amount;
            IERC20(stables[toIndex - 1]).transfer(
                                        to, amount);
        }
    }

    function deposit(address from,
        address token, uint amount)
        public returns (uint usd) {
        uint index = toIndex[token];
        if (index == 0) revert InvalidToken();
        usd = Math.min(amount,
        IERC20(token).allowance(from,
                    address(this)));

        IERC20(token).transferFrom(from,
                    address(this), usd);
        if (usd == 0) revert NoDeposit();

        if (ILink(LINK).isDepegged(
                _depegLookup(token))) revert TokenDepegged();

        amount = BasketLib.scaleTokenAmount(
                           usd, token, true);

        deposits[token] += amount;
        if (index < 3)
            IERC4626(vaults[token]).deposit(usd,
                                 address(this));
        else if (index == 3)
            AAVE.supply(token, usd,
                address(this), 0);

        if (msg.sender == address(QUID)) {
            uint _target = QUID.target();
            if (untouchable < _target) {
                uint fee = BasketLib.seedFee(usd, untouchable,
                                    _target, getAverageYield());
                if (fee > 0) {
                    _tip(fee, token, 1);
                }
            }
        }
    } function _tip(uint cut, address token, int sign) internal {
        cut = BasketLib.scaleTokenAmount(cut, token, true);
        if (sign > 0) {
            untouchables[token] += cut; untouchable += cut;
        } else {
            cut = Math.min(cut, untouchables[token]);
            untouchables[token] -= cut;
            untouchable -= Math.min(untouchable, cut);
        }
    }

    function _depositETH(address sender,
        uint amount) internal returns (uint sent) {
        if (amount > 0) { uint available = Math.min(
                WETH.allowance(sender, address(this)),
                WETH.balanceOf(sender));

            uint took = Math.min(amount, available);
            if (took > 0) { WETH.transferFrom(sender,
                                address(this), took);
                                        sent += took;
            }
        } require(sent > 0);
    }

    function flashLoan(address borrower,
        address token, uint amount, uint shareBps,
        bytes calldata data) external nonReentrant
        returns (bool) { require(msg.sender == JAM);
        if (ILink(LINK).depegPending()) revert DepegInProgress();
        uint bal = IERC20(token).balanceOf(address(this));
        uint sent = take(borrower, amount, token, 0);
        bytes32 result = IFlashBorrower(borrower).onFlashLoan(
                        borrower, token, sent, shareBps, data);
        uint repaid = IERC20(token).balanceOf(address(this)) - bal;
        require(result == CALLBACK_SUCCESS &&
            repaid >= (toIndex[token] > 0 &&
                       toIndex[token] < 4 ?
                       sent / 1e12 : sent));

        uint idx = toIndex[token];
        if (idx > 0 && idx < 3)
            IERC4626(vaults[token]).deposit(
                      repaid, address(this));
        else if (idx == 3)
            AAVE.supply(token, repaid,
                    address(this), 0);

        return true;
    }
}
