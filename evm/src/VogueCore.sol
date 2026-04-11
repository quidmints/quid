
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Aux} from "./Aux.sol";
import {mock} from "./mock.sol";
import {Vogue} from "./Vogue.sol";
import {Types} from "./imports/Types.sol";
import {BasketLib} from "./imports/BasketLib.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IUniswapV3Pool} from "./imports/v3/IUniswapV3Pool.sol";
import {SafeCallback} from "v4-periphery/src/base/SafeCallback.sol";

import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";

import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {CurrencySettler} from "v4-core/test/utils/CurrencySettler.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

contract VogueCore is SafeCallback {
    using TransientStateLibrary for IPoolManager;
    using BalanceDeltaLibrary for BalanceDelta;
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;
    using PoolIdLibrary for PoolKey;

    int24 public initialTick;
    int24 public lastTick;
    struct Observation {
        uint32 blockTimestamp;
        int56 tickCumulative;
        bool initialized;
    }   PoolKey VANILLA;
    Observation[65535] public observations;
    uint16 public observationCardinality;
    uint16 public observationIndex;

    uint public MAX_POOLED_USD;
    uint public POOLED_ETH;
    uint public POOLED_USD;
    mock internal mockETH;
    mock internal mockUSD;

    uint constant WAD = 1e18;
    bool public token1isETH;
    Aux AUX; Vogue VOGUE;
    enum Action { Swap,
        Repack, ModLP,
        OutsideRange } // 4 actions...
    modifier onlyUs { // 2 contracts...
        require(msg.sender == address(AUX)
             || msg.sender == address(VOGUE), "403"); _;
    } bytes internal constant ZERO_BYTES = bytes("");

    constructor(IPoolManager _manager) SafeCallback(_manager) {}
    function setup(address _vogue, // vanilla pool (hookless)
        address _aux, address _poolETH) external {
        require(address(VOGUE) == address(0), "!");
        mockETH = new mock(address(this), 18);
        mockUSD = new mock(address(this), 6);
        address token0; address token1;

        // requires address currency0 < currency1
        if (address(mockETH) > address(mockUSD)) {
            token1isETH = true;
            token0 = address(mockUSD);
            token1 = address(mockETH);
        } else {
            token0 = address(mockETH);
            token1 = address(mockUSD);
        }
        VOGUE = Vogue(payable(_vogue));
        AUX = Aux(payable(_aux));
        VANILLA = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 420, tickSpacing: 10,
            hooks: IHooks(address(0))});

        (,int24 tickETH,,,,,) = IUniswapV3Pool(_poolETH).slot0();
        mockUSD.approve(address(poolManager), type(uint).max);
        mockETH.approve(address(poolManager), type(uint).max);

        // Adjust tick if
        // V4 and V3 have
        // different order
        if (token1isETH)
            tickETH *= AUX.token1isWETH()
                    ? int24(1) : int24(-1);
        else
            tickETH *= AUX.token1isWETH()
                    ? int24(-1) : int24(1);

        poolManager.initialize(VANILLA,
        TickMath.getSqrtPriceAtTick(tickETH));
        // Initialize the oracle observations...
        initialTick = tickETH; lastTick = tickETH;
        observations[0] = Observation({
            blockTimestamp: uint32(block.timestamp),
            tickCumulative: 0, initialized: true });
                         observationCardinality = 1;
    }

    function modLP(uint160 sqrtPriceX96, uint deltaETH,
        uint deltaUSD, int24 tickLower, int24 tickUpper,
        address sender) public onlyUs returns (uint ethSent) {
        BalanceDelta delta = abi.decode(poolManager.unlock(abi.encode(
                Action.ModLP, sqrtPriceX96, deltaETH, deltaUSD,
                tickLower, tickUpper, sender)), (BalanceDelta));
        int128 ethDelta = token1isETH ? delta.amount1() : delta.amount0();
        ethSent = ethDelta > 0 ? uint(int(ethDelta)) : 0;
    }

    function outOfRange(address sender, int liquidity,
        int24 tickLower, int24 tickUpper, address token)
        public onlyUs {
        abi.decode(poolManager.unlock(abi.encode(
            Action.OutsideRange, sender, liquidity,
            tickLower, tickUpper, token)), (BalanceDelta));
    }

    function swap(uint160 sqrtPriceX96, address sender,
        bool forOne, address token, uint amount)
        onlyUs public returns (uint out) {
        BalanceDelta delta = abi.decode(poolManager.unlock(
          abi.encode(Action.Swap, sqrtPriceX96, sender,
            forOne, token, amount)), (BalanceDelta));

        // zeroForOne=true: input token0, output token1
        // zeroForOne=false: input token1, output token0
        out = uint(int(forOne ? delta.amount1():
                                delta.amount0()));

        uint totalShares = VOGUE.totalShares();
        if (POOLED_ETH < totalShares) {
            uint shortfall = totalShares - POOLED_ETH;
            // Arb if shortfall >= 1% of total LP claims
            if (shortfall * 100 >= totalShares)
                AUX.arbETH(shortfall);
        }
    }

    function _unlockCallback(bytes calldata data)
        internal override returns (bytes memory) {
        uint8 firstByte;
        assembly {
            let word := calldataload(data.offset)
            firstByte := and(word, 0xFF)
        }
        Action discriminator = Action(firstByte);
        if (discriminator == Action.Swap)
            return _handleSwap(data[32:]);
        else if (discriminator == Action.Repack)
            return _handleRepack(data[32:]);
        else if (discriminator == Action.OutsideRange)
            return _handleOutsideRange(data[32:]);
        else if (discriminator == Action.ModLP)
            return _handleMod(data[32:]);

        return "";
    }

    function _handleSwap(bytes calldata data)
        internal returns (bytes memory) {
        (uint160 sqrtPriceX96, address sender, bool forOne,
            address token, uint amount) = abi.decode(data,
             (uint160, address, bool, address, uint));

        BalanceDelta delta = poolManager.swap(VANILLA,
            IPoolManager.SwapParams({ zeroForOne: forOne,
                amountSpecified: -int(amount), sqrtPriceLimitX96:
                    VOGUE.paddedSqrtPrice(sqrtPriceX96,
                        !forOne, 300) }), ZERO_BYTES);

        (, int24 currentTick,,) = poolManager.getSlot0(VANILLA.toId());
        _writeObservation(currentTick); _handleDelta(delta, true,
                                            false, sender, token);
        return abi.encode(delta);
    }

    function _handleRepack(bytes calldata data)
        internal returns (bytes memory) {
        POOLED_USD = 0; POOLED_ETH = 0;
        (uint128 myLiquidity, uint160 sqrtPriceX96,
        int24 oldTickLower, int24 oldTickUpper,
        int24 newTickLower, int24 newTickUpper) = abi.decode(data,
                  (uint128, uint160, int24, int24, int24, int24));

        (BalanceDelta delta,
         BalanceDelta fees) = _modifyLiquidity(-int(uint(myLiquidity)),
                                            oldTickLower, oldTickUpper);

        (uint delta0, uint delta1) = _handleDelta(delta, false, true,
                                            address(0), address(0));
        BalanceDelta addDelta;
        uint price = BasketLib.getPrice(
              sqrtPriceX96, token1isETH);

        if (token1isETH) {
            (delta0, delta1) = VOGUE.addLiquidityHelper(delta1, price);
            if (delta0 > 0 && delta1 > 0) {
                addDelta = _modLP(delta0, delta1, newTickLower,
                                    newTickUpper, sqrtPriceX96);

                _handleDelta(addDelta, true, false,
                            address(0), address(0));
            }
        } else {
            (delta1, delta0) = VOGUE.addLiquidityHelper(delta0, price);
            if (delta1 > 0 && delta0 > 0) {
                addDelta = _modLP(delta1, delta0, newTickLower,
                                    newTickUpper, sqrtPriceX96);

                _handleDelta(addDelta, true, false,
                            address(0), address(0));
            }
        } (, int24 currentTick,,) = poolManager.getSlot0(VANILLA.toId());
                                          _writeObservation(currentTick);

        return abi.encode(price, uint(int(fees.amount0())), uint(int(fees.amount1())),
                        uint(int(addDelta.amount0())), uint(int(addDelta.amount1())));
    }

    function _handleOutsideRange(bytes calldata data)
        internal returns (bytes memory) { (address sender, int liquidity,
        int24 tickLower, int24 tickUpper, address token) = abi.decode(data,
                                      (address, int, int24, int24, address));

        (BalanceDelta delta, ) = _modifyLiquidity(liquidity, tickLower, tickUpper);
        _handleDelta(delta, false, false, sender, token); return abi.encode(delta);
    }

    function _handleMod(bytes calldata data)
        internal returns (bytes memory) {
        (uint160 sqrtPriceX96, uint deltaETH, uint deltaUSD,
        int24 tickLower, int24 tickUpper, address sender) = abi.decode(
                    data, (uint160, uint, uint, int24, int24, address));

        BalanceDelta delta = _modLP(deltaUSD, deltaETH,
                    tickLower, tickUpper, sqrtPriceX96);

        bool keep = deltaUSD == 0;
        _handleDelta(delta, true,
        keep, sender, address(0));
        return abi.encode(delta);
    }

    function _handleDelta(BalanceDelta delta, bool inRange, bool keep,
        address who, address token) internal returns (uint, uint) {
        Currency usdCurrency; Currency ethCurrency;
        int128 usdDelta; int128 ethDelta;
        uint usdAmount; uint ethAmount;
        if (token1isETH) {
            usdDelta = delta.amount0();
            ethDelta = delta.amount1();
            usdCurrency = VANILLA.currency0;
            ethCurrency = VANILLA.currency1;
        } else {
            ethDelta = delta.amount0();
            usdDelta = delta.amount1();
            usdCurrency = VANILLA.currency1;
            ethCurrency = VANILLA.currency0;
        }
        if (usdDelta > 0) {
            usdAmount = uint(int(usdDelta));
            usdCurrency.take(poolManager,
            address(this), usdAmount, false);
            mockUSD.burn(usdAmount);
            if (inRange) POOLED_USD -= Math.min(
                          usdAmount, POOLED_USD);

            if (!keep && token != address(0))
            AUX.take(who, usdAmount, token, 0);
        }
        else if (usdDelta < 0) {
            usdAmount = uint(int(-usdDelta));
            mockUSD.mint(usdAmount);
            usdCurrency.settle(poolManager,
            address(this), usdAmount, false);
            if (inRange) { POOLED_USD += usdAmount;
                if (POOLED_USD > MAX_POOLED_USD)
                    MAX_POOLED_USD = POOLED_USD;
            }
        } if (ethDelta > 0) {
            ethAmount = uint(int(ethDelta));
            ethCurrency.take(poolManager,
            address(this), ethAmount, false);
            mockETH.burn(ethAmount);
            if (inRange) POOLED_ETH -= Math.min(
                          ethAmount, POOLED_ETH);

            if (who != address(0)) VOGUE.takeETH(
                                  ethAmount, who);
        } else if (ethDelta < 0) {
            ethAmount = uint(int(-ethDelta));
            mockETH.mint(ethAmount);
            ethCurrency.settle(poolManager,
            address(this), ethAmount, false);
            if (inRange) POOLED_ETH += ethAmount;
        } if (token1isETH)
            return (usdAmount, ethAmount);
        else return (ethAmount, usdAmount);
    }

    function _modifyLiquidity(int delta, int24 lowerTick, int24 upperTick)
        internal returns (BalanceDelta totalDelta, BalanceDelta feesAccrued) {
        (totalDelta, feesAccrued) = poolManager.modifyLiquidity(
            VANILLA, IPoolManager.ModifyLiquidityParams({
            tickLower: lowerTick, tickUpper: upperTick,
            liquidityDelta: delta, salt: bytes32(0) }), ZERO_BYTES);
    }

    function _modLP(uint deltaUSD, uint deltaETH,
        int24 tickLower, int24 tickUpper, uint160 sqrtPriceX96)
        internal returns (BalanceDelta totalDelta) {
        int flip = deltaUSD > 0 ? int(1) : int(-1);
        uint128 liquidity = token1isETH ? LiquidityAmounts.getLiquidityForAmount1(
                   TickMath.getSqrtPriceAtTick(tickLower), sqrtPriceX96, deltaETH):
                            LiquidityAmounts.getLiquidityForAmount0(sqrtPriceX96,
                                TickMath.getSqrtPriceAtTick(tickUpper), deltaETH);
        if (flip < 0) {
            (,, uint128 posLiquidity) = poolStats(tickLower, tickUpper);
            if (posLiquidity == 0) return BalanceDeltaLibrary.ZERO_DELTA;
            if (liquidity > posLiquidity) liquidity = posLiquidity;
        }
        (totalDelta, ) = _modifyLiquidity(flip *
        int(uint(liquidity)), tickLower, tickUpper);
    }

    function poolStats(int24 tickLower, int24 tickUpper) public view returns
        (uint160 sqrtPriceX96, int24 currentTick, uint128 liquidity) { PoolId pool;
        (pool, sqrtPriceX96, currentTick) = poolTicks();
        (liquidity,,) = poolManager.getPositionInfo(pool,
            address(this), tickLower, tickUpper, bytes32(0));
    }

    function poolTicks() public view
        returns(PoolId, uint160, int24) {
        PoolId pool = VANILLA.toId();
        (uint160 sqrtPriceX96,
         int24 currentTick,,) = poolManager.getSlot0(pool);
         return (pool, sqrtPriceX96, currentTick);
    }

    /// @notice Write a new observation to the oracle
    /// @dev Called on each swap/repack to track tick history
    /// @param tick The current tick AFTER the action
    function _writeObservation(int24 tick) internal {
        uint32 blockTimestamp = uint32(block.timestamp);
        Observation memory last = observations[observationIndex];
        // Only write if time has passed since last observation
        if (last.blockTimestamp == blockTimestamp) {
            lastTick = tick; return;
        }
        // cumulative: accumulate lastTick over the elapsed time
        uint32 delta = blockTimestamp - last.blockTimestamp;
        int56 tickCumulative = last.tickCumulative
            + int56(lastTick) * int56(uint56(delta));

        // Write to next slot (ring buffer)
        uint16 indexNext = (observationIndex + 1) % 65535;
        // Grow cardinality if needed (up to 65535 max)
        if (indexNext >= observationCardinality &&
            observationCardinality < 65535) {
            observationCardinality = indexNext + 1;
        }
        observations[indexNext] = Observation({
            blockTimestamp: blockTimestamp,
            tickCumulative: tickCumulative,
            initialized: true });

        observationIndex = indexNext;
        lastTick = tick;
    }

    /// @notice Observe tick cumulatives at given seconds ago
    /// @param secondsAgos Array of seconds ago to observe
    /// @return tickCumulatives Array of tick cumulatives at each time
    function observe(uint32[] calldata secondsAgos)
        external view returns (int56[] memory tickCumulatives) {
        tickCumulatives = new int56[](secondsAgos.length);
        uint32 time = uint32(block.timestamp);
        Observation memory latest = observations[observationIndex];
        Observation memory oldest = _getOldestObservation();
        for (uint i = 0; i < secondsAgos.length; i++) {
            uint32 target = time - secondsAgos[i];
            // Current: extrapolate forward from latest
            if (secondsAgos[i] == 0) {
                uint32 delta = time - latest.blockTimestamp;
                tickCumulatives[i] = latest.tickCumulative
                    + int56(lastTick) * int56(uint56(delta));
            }
            else if (target <= oldest.blockTimestamp) {
                // before/at oldest observation - extrapolate BACKWARDS
                // This handles "not enough history", case by the way
                uint32 beforeDelta = oldest.blockTimestamp - target;
                // Use initialTick for backward extrapolation
                // (assume tick was constant before init)...
                tickCumulatives[i] = oldest.tickCumulative -
                int56(initialTick) * int56(uint56(beforeDelta));
            } // Target is at or after latest - extrapolate forward
            else if (target >= latest.blockTimestamp) {
                uint32 delta = target - latest.blockTimestamp;
                tickCumulatives[i] = latest.tickCumulative
                    + int56(lastTick) * int56(uint56(delta));
            } else { // Target is between oldest and latest - interpolate
                tickCumulatives[i] = _interpolate(target, oldest, latest);
            }
        }
    }

    function _getOldestObservation()
        internal view returns (Observation memory) {
        // In a ring buffer, oldest is at
        // (observationIndex + 1) % cardinality
        // But only if that slot is initialized
        if (observationCardinality == 1)
            return observations[0];

        uint16 oldestIndex = (observationIndex + 1) % observationCardinality;
        Observation memory oldest = observations[oldestIndex];
        // If not initialized (ring buffer not full), oldest 0
        if (!oldest.initialized)
            return observations[0];
            return oldest;
    }

    /// @notice Interpolate between
    /// observations to find the
    /// tickCumulative at target time
    function _interpolate(uint32 target, Observation memory oldest,
        Observation memory latest) internal view returns (int56) {
        // If only 2 observations (oldest and latest), interpolate directly
        if (observationCardinality <= 2) {
          uint32 totalDelta = latest.blockTimestamp - oldest.blockTimestamp;
          uint32 targetDelta = target - oldest.blockTimestamp;
          if (totalDelta == 0) return oldest.tickCumulative;

          int56 cumulativeDelta = latest.tickCumulative - oldest.tickCumulative;
          return oldest.tickCumulative + (cumulativeDelta *
              int56(uint56(targetDelta))) / int56(uint56(totalDelta));
        } // Binary search for the bracketing pair of observations...
        // so that TWAP reflects actual price history, not just
        // a straight line between oldest and latest
        uint16 card = observationCardinality;
        uint16 oldestIdx = (observationIndex + 1) % card;
        if (!observations[oldestIdx].initialized) oldestIdx = 0;
        // Search space: offsets [0, card-1] from oldestIdx
        // Find largest offset where timestamp <= target
        uint16 lo = 0; uint16 hi = card - 1;
        while (lo < hi) {
            uint16 mid = lo + (hi - lo + 1) / 2;
            uint16 idx = (oldestIdx + mid) % card;
            if (observations[idx].blockTimestamp <= target)
                lo = mid;
            else
                hi = mid - 1;
        }
        // lo is now the offset of the observation at or just before target
        Observation memory before = observations[(oldestIdx + lo) % card];
        Observation memory later  = observations[(oldestIdx + lo + 1) % card];
        uint32 totalDelta = later.blockTimestamp - before.blockTimestamp;

        if (totalDelta == 0) return before.tickCumulative;
        uint32 targetDelta = target - before.blockTimestamp;
        int56 cumulativeDelta = later.tickCumulative - before.tickCumulative;

        return before.tickCumulative +
            (cumulativeDelta * int56(uint56(targetDelta))) /
                                int56(uint56(totalDelta));
    }

    function repack(uint128 myLiquidity,
        uint160 sqrtPriceX96, int24 oldTickLower,
        int24 oldTickUpper, int24 newTickLower, int24 newTickUpper) public onlyUs
        returns (uint price, uint fees0, uint fees1, uint delta0, uint delta1) {
        (price, fees0, fees1, delta0, delta1) = abi.decode(poolManager.unlock(
            abi.encode(Action.Repack, myLiquidity, sqrtPriceX96, oldTickLower,
                oldTickUpper, newTickLower, newTickUpper)),
                            (uint, uint, uint, uint, uint));
    }
}
