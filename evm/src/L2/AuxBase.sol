
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Amp} from "../Amp.sol";
import {Rover} from "../Rover.sol";
import {Basket} from "../Basket.sol";
import {VogueCore} from "../VogueCore.sol";
import {Types} from "../imports/Types.sol";

import {FeeLib} from "../imports/FeeLib.sol";
import {VogueUni as Vogue} from "./VogueUni.sol";
import {BasketLib} from "../imports/BasketLib.sol";
import {IPool} from "aave-v3/interfaces/IPool.sol";

import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {WETH as WETH9} from "solmate/src/tokens/WETH.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";
import {IUniswapV3Pool} from "../imports/v3/IUniswapV3Pool.sol";
import {ReentrancyGuard} from "solmate/src/utils/ReentrancyGuard.sol";
import {IV3SwapRouter as ISwapRouter} from "../imports/v3/IV3SwapRouter.sol";

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

interface IFlashBorrower {
    function onFlashLoan(address initiator, address token,
        uint amount, uint shareBps, bytes calldata data)
        external returns (bytes32);
}

contract AuxBase is // Auxiliary
    Ownable, ReentrancyGuard {
    bool public token1isWETH;
    VogueCore internal CORE;
    address internal jury;
    address internal LINK;

    IERC20 internal USDC;
    Basket internal QUID;
    address internal DSR;
    address internal CRV;
    // address internal JAM;

    address[] public stables;
    WETH9 public WETH; Rover V3;

    mapping(address => uint) internal untouchables;
    /*
    bytes32 constant CALLBACK_SUCCESS = keccak256(
               "ERC3156FlashBorrower.onFlashLoan");
    */
    mapping(address => address) internal vaults;
    mapping(address => uint) internal deposits;
    mapping(address => uint) internal toIndex;

    IUniswapV3Pool internal v3PoolWETH;
    BasketLib.Metrics internal metrics;

    IERC4626 internal wethVault;
    uint internal untouchable;
    address internal v3Router;

    uint constant WAD = 1e18;
    uint internal lastBlock;
    uint24 internal v3Fee;
    Vogue internal V4;

    error DepegInProgress();
    error NotInitialized();
    error TokenDepegged();
    error InvalidToken();
    error Unauthorized();
    error Untouchable();
    error NoDeposit();

    IPool internal AAVE;
    Amp internal AMP;
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

    /// @notice init (plug) Aux with addresses
    /// @dev optional: V3 rover & AAVE amp...
    /// @param _vogue UniV4 rover  address...
    /// @param _wethVault Morpho for WETH deposits
    /// @param _v3poolWETH V3 pool
    /// @param _v3router V3 router for swaps
    /// @param _v3 our wrapper around UniV3
    /// @param _amp AAVE yield-amplifier...
    constructor(address _vogue, address _core,
        address _wethVault, address _amp,
        address _aave, address _v3poolWETH,
        address _v3router, address _v3,
        address[] memory _stables,
        address[] memory _vaults)
        Ownable(msg.sender) {

        stables = _stables; uint i;
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
        }   AAVE = IPool(_aave);

        V4 = Vogue(payable(_vogue));
        CORE = VogueCore(_core);
        if (_amp != address(0))
            AMP = Amp(payable(_amp));
        if (_v3 != address(0))
            V3 = Rover(payable(_v3));

        for (; i < 2;) {
            vaults[stables[i]] = _vaults[i];
            IERC20(stables[i]).approve(
            _vaults[i], type(uint).max);
            toIndex[stables[i]] = i + 1;
            unchecked { ++i; }
        }
        // GHO uses AAVE, store aToken
        // address for balance queries
        vaults[stables[i]] = _vaults[i];
        IERC20(stables[i]).approve(
        address(AAVE), type(uint).max);
        toIndex[stables[i]] = i + 1;
        unchecked { ++i; }
        while (i < stables.length) {
            toIndex[stables[i]] = i + 1;
            unchecked { ++i; }
        }
        DSR = 0x49aF4eE75Ae62C2229bb2486a59Aa1a999f050f0;
        CRV = 0x3d8EADb739D1Ef95dd53D718e4810721837c69c1;
    } receive() external payable {}
    function get_metrics(bool force)
        public returns (uint, uint) {
        BasketLib.Metrics memory stats = metrics;
        uint elapsed = block.timestamp - stats.last;
        if (force || elapsed > 10 minutes) {
            uint[14] memory amounts = _fee_deposits();
            stats = BasketLib.computeMetrics(stats,
                elapsed, amounts[0], amounts[1], amounts[1]);
            metrics = stats;
        } return (stats.total,
                  stats.yield);
    }

    function getAverageYield() public view returns (uint) {
        return BasketLib.getAverageYield(metrics);
    }

    function _getPrice(uint index) internal
        view returns (uint price) {
        if (index == 10) {
            price = FeeLib.getStakedPrice(
                0xdEd37FC1400B8022968441356f771639ad1B23aA,
                FeeLib.ORACLE_CHAINLINK);
        } else if (index == 11) {
            price = FeeLib.getStakedPrice(
                   CRV, FeeLib.ORACLE_CRV);
        } else if (index == 1) {
            price = FeeLib.getStakedPrice(
              DSR, FeeLib.ORACLE_DSR_RATE);
        }
    }

    function setQuid(address _quid,
        address _jam) external onlyOwner {
        renounceOwnership(); QUID = Basket(_quid);
        LINK = address(QUID.LINK()); // JAM = _jam;
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
        // Return only base stables (not staked wrappers)
        // (indices 1,9,10,11) share sides with their base.
        address[] memory bases = new address[](8);
        bases[0] = stables[0]; // USDC
        bases[1] = stables[2]; // GHO
        bases[2] = stables[3]; // USDT
        bases[3] = stables[4]; // DAI
        bases[4] = stables[5]; // FRAX
        bases[5] = stables[6]; // USDE
        bases[6] = stables[7]; // USDS
        bases[7] = stables[8]; // CRVUSD
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
        public payable nonReentrant returns (uint max) { bool zeroForOne;
        Types.AuxContext memory ctx = _buildContext();
        (uint160 sqrtPriceX96,,,) = V4.repack();
        bool stable = toIndex[token] > 0;
        if (forETH && // selling dollars...
            stable && token != address(QUID)) {
            if (ILink(LINK).isDepegged(
                    _depegLookup(token)))
                    revert TokenDepegged();
        }
        if (!forETH) {
            if (token != address(QUID)) require(stable);
            amount = _depositETH(msg.sender, amount);
            zeroForOne = !V4.token1isETH();
            max = CORE.POOLED_USD();
        }
        else { max = CORE.POOLED_ETH();
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
        }
        (max,) = BasketLib.routeSwap(ctx,
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
            hub: address(0), vaultType: 0, nativeWETH: true });
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
            require(v3Fair(twapPrice));
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
            CORE.swap(sqrtPriceX96, address(this),
            V4.token1isETH(), token, depositedAmount);
            uint ethReceived = address(this).balance;

            WETH.deposit{value: ethReceived}();
            AAVE.supply(address(WETH),
            ethReceived, address(V4), 0);

            uint usdcBefore = USDC.balanceOf(address(this));
            CORE.swap(sqrtPriceX96, address(this),
            !V4.token1isETH(), address(USDC), ethReceived);

            usdcAmount = USDC.balanceOf(
            address(this)) - usdcBefore;
        }   uint twapPrice = getTWAP(0);

        require(v3Fair(twapPrice));
        uint targetETH = BasketLib.convert(
           usdcAmount, getTWAP(1800), true);

        (uint inETH, uint spent) = BasketLib.source(
            _buildContext(), targetETH, usdcAmount, twapPrice, false);

        usdcAmount -= spent;
        require(inETH >= targetETH * 99 / 100);
        USDC.approve(address(AMP), usdcAmount);
        AMP.leverUSD(msg.sender, usdcAmount, inETH);
    }

    /// @notice Convert Basket tokens into dollars
    /// @param amount of tokens to redeem, 1e18
    function redeem(uint amount) external {
        require(!ILink(LINK).depegPending());
        uint price = getTWAP(1800);
        (uint total,) = get_metrics(false);
        (uint reserved, uint usdPart, uint ethExcess) = BasketLib.redeemSplit(
            total, CORE.POOLED_USD() * 1e12, wethVault.maxWithdraw(address(this)),
                                                CORE.POOLED_ETH(), price, amount);

        (uint burned, uint seedBurned) = QUID.turn(msg.sender, usdPart);

        if (burned == 0) return;
        uint taken = _take(msg.sender,
        burned, address(QUID), seedBurned);
        if (taken < reserved) {
            uint ethToUse = Math.min(FullMath.mulDiv(
              reserved - taken, WAD, price), ethExcess);

            if (ethToUse > 0) { price = getTWAP(0);
                uint received = V4.takeETH(ethToUse, address(this));
                WETH.deposit{value: received}(); require(v3Fair(price));
                received = BasketLib.sourceExternalUSD(_buildContext(),
                                                      received, price);

                if (received > 0) IERC20(stables[0]).transfer(
                                         msg.sender, received);
            }
        }
    }

    // amounts[1] represents the total
    // in terms of final $ melt value
    // amounts[0] assumes 1 sUSDS or 1 sUSDE = $1 regardless
    function _fee_deposits() internal view
        returns (uint[14] memory amounts) {
        uint balance; uint i; uint reserved;
        // stables[0]=USDC (ERC4626, 6-dec vault; reserved & deposits in 18-dec)
        reserved = untouchables[stables[0]];
        balance = IERC4626(vaults[stables[0]]).maxWithdraw(address(this));
        { uint res6 = reserved / 1e12;
          amounts[2] = (balance > res6 ? balance - res6 : 0) * 1e12; }
        balance = deposits[stables[0]];
        amounts[0] += (balance > reserved ? balance - reserved : 0);

        // stables[1]=sUSDS (ERC4626, 18-dec, price-weighted)
        reserved = untouchables[stables[1]];
        balance = IERC4626(vaults[stables[1]]).maxWithdraw(address(this));
        amounts[3] = balance > reserved ? balance - reserved : 0;
        balance = deposits[stables[1]];
        amounts[0] += (balance > reserved ? balance - reserved : 0);
        amounts[1] += amounts[2] + (amounts[3] > 0
                    ? FullMath.mulDiv(_getPrice(1), amounts[3], WAD) : 0);

        // stables[2]=GHO (aToken, 18-dec)
        { address stable = stables[2];
          reserved = untouchables[stable];
          balance = IERC20(vaults[stable]).balanceOf(address(this));
          amounts[4] = balance > reserved ? balance - reserved : 0;
          amounts[0] += IERC20(stable).balanceOf(address(this));
          amounts[1] += amounts[4]; }

        // we have only one token that is deposited on AAVE (GHO)
        uint len = stables.length;
        for (i = 3; i < 10;) { // USDT, DAI, FRAX, USDE, USDS, CRVUSD, SFRAX
            address stable = stables[i];
            reserved = BasketLib.scaleTokenAmount(
                untouchables[stable], stable, false); // native dec
            balance = IERC20(stable).balanceOf(address(this));
            balance = balance > reserved ? balance - reserved : 0;
            amounts[i + 2] = i == 3 ? balance * 1e12 : balance; // scale USDT
            amounts[0] += amounts[i + 2]; // these tokens aren't deposited
            amounts[1] += amounts[i + 2]; // anywhere to earn extra yield
            unchecked { ++i; }
        }
        for (i = 10; i < len;) {
            address stable = stables[i];
            reserved = untouchables[stable];
            balance = IERC20(stable).balanceOf(
                                     address(this));
            balance = balance > reserved
                    ? balance - reserved : 0;
            amounts[0] += balance;
            if (balance > 0) {
                balance = FullMath.mulDiv(
                _getPrice(i), balance, WAD);
            }
            amounts[1] += balance;
            amounts[i + 2] = balance;
            unchecked { ++i; }
        }
        // amounts[1] should be higher than
    } // amounts[0] so their ratio gives us
    // the total APY % of the whole basket;

    /// @notice Vogue/Basket-compatible: uint[14] with staked folded into base
    /// Matches getStables() order: USDC, GHO, USDT, DAI, FRAX, USDE, USDS, CRVUSD
    function get_deposits() public view
        returns (uint[14] memory out, uint avgYield) {
        uint[14] memory full = _fee_deposits();
        out[0] = full[0]; // yield-weighted
        out[1] = full[2];  // USDC (stables[0])
        out[2] = full[4];  // GHO  (stables[2])
        out[3] = full[5];  // USDT (stables[3])
        out[4] = full[6];  // DAI  (stables[4])
        out[5] = full[7] + full[11]; // FRAX + SFRAX
        out[6] = full[8] + full[12]; // USDE + SUSDE
        out[7] = full[9] + full[3];  // USDS + SUSDS
        out[8] = full[10] + full[13]; // CRVUSD + SCRVUSD
        // [9..11] = 0 (no BOLD SP, no USYC on Base)
        out[12] = full[1]; // TVL
        avgYield = getAverageYield();
    }

    // calculations differ in Basket.sol...

    function getFee(address token)
        public view returns (uint) {
        uint idx = type(uint).max;
        uint len = stables.length;
        for (uint i; i < len;) {
            if (stables[i] == token)
              { idx = i; break; }
              unchecked { ++i; }
        }
        if (idx == type(uint).max) return 0;
        uint[14] memory deps = _fee_deposits();
        return FeeLib.calcFeeWithPairs(idx, deps,
            FeeLib.StakedPairs({ base: [5, 6, 7, 8],
                    staked: [9, 10, 1, 11] }), stables,
                    LINK);
    }

    /// @dev Resolve staked token → base token for depeg lookup.
    /// SFRAX→FRAX, SUSDE→USDE, SUSDS→USDS, SCRVUSD→CRVUSD.
    function _depegLookup(address token) internal view
        returns (address) { return stables[FeeLib.getBaseIndex(
            toIndex[token] > 0 ? toIndex[token] - 1 :
            0, FeeLib.StakedPairs({ base: [5, 6, 7, 8],
                           staked: [9, 10, 1, 11] }))];
    }

    // you let me in to a conversation, conversation only we could make
    // breaking into my imagination; whatever's in there: yours to take
    function _take(address who, uint amount, address token,
        uint seed) internal returns (uint sent) {
        int indexToSkip = -1; uint i;
        uint withdrawn; uint reserved;
        if (token != address(QUID)) {
            uint index = toIndex[token]; uint max;
            if (index == 0 || index >= 13) revert InvalidToken();
            if (index < 3) {
                max = IERC4626(vaults[token]).maxWithdraw(address(this));
            }
            else if (index == 3) {
                max = IERC20(vaults[token]).balanceOf(address(this));
            } else {
                max = IERC20(token).balanceOf(address(this));
            }
            reserved = BasketLib.scaleTokenAmount(
                untouchables[token], token, false); // native dec
            max = max > reserved ? max - reserved : 0;
            i = max > 0 ? (getFee(token) * WAD) / 10000 : 0;

            uint needed = (i > 0 && i < WAD / 10) ?
                FullMath.mulDiv(amount, WAD - i, WAD) : amount;

            // Haircut applies to ALL redeemers during depeg, not just seed
            { Types.DepegStats memory ds = ILink(LINK).getDepegStats(
                                                  _depegLookup(token));

                if (ds.depegged && ds.severityBps > 0) {
                    uint retained = FullMath.mulDiv(needed,
                                    ds.severityBps, 10000);
                                         needed -= retained;
                }
            } indexToSkip = int(index - 1);
            if (seed > 0) { _tip(seed, token, -1);
                sent = _withdraw(who, index, needed);
                { uint scaled = BasketLib.scaleTokenAmount(sent, token, true);
                  deposits[token] -= Math.min(deposits[token], scaled); }
                return BasketLib.scaleTokenAmount(sent, token, true);
            }
            if (max >= needed) {
                withdrawn = _withdraw(who, index, needed);
                if (i > 0) withdrawn = FullMath.mulDiv(
                               withdrawn, WAD - i, WAD);

                { uint scaled = BasketLib.scaleTokenAmount(withdrawn, token, true);
                  deposits[token] -= Math.min(deposits[token], scaled); }
                return BasketLib.scaleTokenAmount(withdrawn, token, true);
            } else {
                withdrawn = _withdraw(who, index, max);
                if (i > 0) sent = FullMath.mulDiv(
                          withdrawn, WAD - i, WAD);
                else sent = withdrawn;

                amount -= sent;
                { uint scaled = BasketLib.scaleTokenAmount(sent, token, true);
                  deposits[token] -= Math.min(deposits[token], scaled); }
                sent = BasketLib.scaleTokenAmount(sent, token, true);
            }
        } amount = BasketLib.scaleTokenAmount(
                          amount, token, true);
        if (amount > 0) {
            uint[14] memory amounts = _fee_deposits();
            amount = seed == 0 ? Math.min(amounts[1], amount) : amount;
            if (amounts[1] == 0 || amount == 0) return sent;
            sent += _executeProRata(who, amount,
                    amounts, indexToSkip, seed);
        }
    }

    /// @dev Separated to reduce stack depth in _take
    function _executeProRata(address who, uint amount,
        uint[14] memory amounts, int indexToSkip,
        uint seed) private returns (uint sent) {
        // skip _getPrice when staked token balance is 0
        // amounts[3]=sUSDS, amounts[12]=SUSDE, amounts[13]=SCRVUSD
        uint[12] memory w = FeeLib.calcWithdrawAmounts(amount, amounts,
            indexToSkip, seed > 0, [amounts[3] > 0 ? _getPrice(1) : WAD,
                                  amounts[12] > 0 ? _getPrice(10) : WAD,
                                  amounts[13] > 0 ? _getPrice(11) : WAD],
        [uint8(1), uint8(10), uint8(11)], 9); // 0b1001 = USDC(0), USDT(3)
        for (uint i; i < 12; ++i) if (w[i] > 0) {
            if (seed > 0) _tip(FullMath.mulDiv(w[i],
                seed, amount), stables[i], -1);

            Types.DepegStats memory dsPR = ILink(LINK).getDepegStats(
                                          _depegLookup(stables[i]));

            if (dsPR.depegged && dsPR.severityBps > 0 && dsPR.severityBps < 10000)
                w[i] -= FullMath.mulDiv(w[i], dsPR.severityBps, 10000);

            sent += _executeWithdraw(who, i, w[i]);
        }
    }

    /// @dev Execute single withdrawal, separated to reduce stack depth
    function _executeWithdraw(address who, uint i, uint amt)
        private returns (uint out) {
        uint div = (i == 0 || i == 3) ? 1e12 : 1;
        address s = stables[i]; out = amt * div;
        deposits[s] -= Math.min(deposits[s], out);
        if (i < 2) out = _withdraw(
            who, i + 1, amt) * div;
        else if (i == 2) {
          out = AAVE.withdraw(s,
            amt, address(this));
          IERC20(s).transfer(who, out);
        }
        else IERC20(s).transfer(who, amt);
    }

    // Base stables: [USDC, SUSDS, GHO, USDT, DAI,
    // FRAX, USDE, USDS, CRVUSD, SFRAX, SUSDE, SCRVUSD]
    function take(address who, uint amount,
        address token, uint seed) public
        onlyUs returns (uint) { return _take(
                  who, amount, token, seed);
    }

    function _withdraw(address to, // 1e18 for sUSDS, 1e6 for USDC
        uint toIndex, uint amount) internal returns (uint sent) {
        if (amount == 0) return 0; // Early return for 0 amounts
        if (toIndex < 3)  {
            address vault = vaults[stables[toIndex - 1]];
            (uint shares,) = BasketLib.calculateVaultWithdrawal(
                                                vault, amount);
            if (shares == 0) return 0;  // Skip if no shares to redeem
            sent = IERC4626(vault).redeem(shares, to, address(this));
        }
        else if (toIndex == 3) {
            sent = AAVE.withdraw(stables[2], amount, to);
        }
        else { sent = amount;
            IERC20(stables[toIndex - 1]).transfer(to, amount);
        }
    }

    // there's never an incentive
    // for EOAs to call this since
    // mint() is the only way to
    // get yield for a deposit...
    // so it's assumed only our
    // contracts will call this
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

        // deposit into external yield-bearing vaults
        // normalise the precision for compatibility
        amount = BasketLib.scaleTokenAmount(
                            usd, token, true);

        deposits[token] += amount;
        if (index < 3) { // USDT, USDC for Arb , and for
        // Base it's just USDC (no USDT) and sUSDS...
            IERC4626(vaults[token]).deposit(usd,
                                    address(this));
        } // GHO only for Base (+ DAI, FRAX for Arb)
        else if (index == 3)
            AAVE.supply(token, usd,
                address(this), 0);

        if (msg.sender == address(QUID)) {
            uint _target = QUID.target();
            if (untouchable < _target) {
                uint fee = BasketLib.seedFee(usd, untouchable,
                                    _target, getAverageYield());
                if (fee > 0)
                    _tip(fee,
                    token, 1);
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
        if (msg.value > 0) { sent = msg.value;
            WETH.deposit{value: msg.value}();
        }
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
    /*
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
        // idx==0 or higher: direct-held token, no re-supply needed
        return true; // builders don't introspect...
    } */ // they see priority fees, explicit bribes, not
    // internal profit splits. Bebop's orchestrator
    // could score solvers by committed shareBps,
    // routing more flow to generous solvers...
}
