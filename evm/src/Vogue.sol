
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {ReentrancyGuard} from "solmate/src/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {WETH as WETH9} from "solmate/src/tokens/WETH.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {BasketLib} from "./imports/BasketLib.sol";
import {stdMath} from "forge-std/StdMath.sol";
import {Types} from "./imports/Types.sol";
import {VogueCore} from "./VogueCore.sol";
import {Basket} from "./Basket.sol";
import {Aux} from "./Aux.sol";

contract Vogue is
    Ownable, ReentrancyGuard {
    uint constant RAY = 1e27;
    uint constant WAD = 1e18;
    VogueCore V4; WETH9 WETH;
    bool public token1isETH;
    // range = between ticks
    int24 public UPPER_TICK;
    int24 public LOWER_TICK;
    uint internal lastVogueETH; // for yield delta
    uint public LAST_REPACK;
    // ^ timestamp allows us
    // to measure APY% for
    uint public USD_FEES;
    uint public ETH_FEES;
    Basket QUID; Aux AUX;
    uint public YIELD;

    // V4.POOLED_ETH() = principal + ALL compounded fees (even unclaimed)
    // totalShares = sum of all LP.pooled_eth = principal + claimed fees
    // that got added to positions; gap represents fees that compounded
    // into the pool but haven't been attributed to any depositor yet...
    // swap fees accumulating in the V4 pool aren't added to `POOLED_ETH`
    // until collection via _modifyLiquidity during repack or withdrawal
    uint public totalShares;

    mapping(address => Types.Deposit) public autoManaged;
    mapping(uint => Types.SelfManaged) public selfManaged;
    // ^ key is tokenId of ID++ for that position
    uint internal ID;
    // ^ always grows

    mapping(address => uint[]) public positions;
    // ^ allows several selfManaged positions...
    constructor()
        Ownable(msg.sender) {
    }   fallback() external payable {}

     modifier onlyUs {
        require(msg.sender == address(AUX)
             || msg.sender == address(V4)
             || msg.sender == address(this), "403"); _;
    }

    function setup(address _quid,
        address _aux, address _core) external {
        require(address(AUX) == address(0), "!");
        AUX = Aux(payable(_aux)); V4 = VogueCore(_core);
        QUID = Basket(_quid); renounceOwnership();
        require(QUID.V4() == address(this), "?");
        WETH = WETH9(payable(address(AUX.WETH())));
        WETH.approve(address(AUX), type(uint).max);
        (uint160 sqrtPriceX96,,) = V4.poolStats(0, 0);
        token1isETH = V4.token1isETH();
        (LOWER_TICK,, UPPER_TICK,) = _updateTicks(
                                sqrtPriceX96, 200);
    }

    function _outOfRangeTicks(uint160 currentSqrtPrice,
        int24 width, int24 range, int24 distance) internal
        returns (int24 newLowerTick, int24 newUpperTick) {
        int24 targetTick = TickMath.getTickAtSqrtPrice(
                           currentSqrtPrice) - distance;
        if (distance < 0) { // above the current price
            newLowerTick = _alignTick(targetTick, width);
            newUpperTick = _alignTick(targetTick + range, width);
        } else {
            newUpperTick = _alignTick(targetTick, width);
            newLowerTick = _alignTick(targetTick - range, width);
        }
    }

    /// @notice Create a single-sided liquidity position outside the current price range
    /// @dev Automatically adjusts for token ordering to ensure valid positions
    /// @param amount Amount of tokens to deposit (0 if sending ETH as msg.value)
    /// @param token Token address (address(0) for ETH, or stablecoin address for USD)
    /// @param distance Distance from current price in ticks
    /// positive = subtract (below), negative = add (above)
    /// @param range Width of the position in ticks
    /// @return next The ID of the newly created position
    function outOfRange(uint amount, address token,
        int24 distance, int24 range) public nonReentrant
        payable returns (uint next) { int24 width = int24(10);
        require(range >= 100 && range <= 1000 && range % 50 == 0,
                "Range must be 100-1000 in increments of 50");

        require(distance % 100 == 0 && distance != 0 &&
                distance >= -5000 && distance <= 5000,
            "must be -5000 to 5000 in increments of 100");

        (uint160 currentSqrtPrice,
         int24 currentLowerTick,
         int24 currentUpperTick,) = _repack();
        if (!token1isETH) distance = -distance;

        (int24 newLowerTick,
         int24 newUpperTick) = _outOfRangeTicks(
        currentSqrtPrice, width, range, distance);

        uint128 liquidity;
        if (token == address(0)) { amount = _depositETH(
                                     msg.sender, amount);
            if (token1isETH) {
                require(newLowerTick > currentUpperTick);
                liquidity = LiquidityAmounts.getLiquidityForAmount1(
                            TickMath.getSqrtPriceAtTick(newLowerTick),
                            TickMath.getSqrtPriceAtTick(newUpperTick), amount);
            } else {
                require(newUpperTick < currentLowerTick);
                liquidity = LiquidityAmounts.getLiquidityForAmount0(
                            TickMath.getSqrtPriceAtTick(newLowerTick),
                            TickMath.getSqrtPriceAtTick(newUpperTick), amount);
            }
        } else { amount = AUX.deposit(
            msg.sender, token, amount);
            // Normalize to 6 decimals for USD side
            uint8 decimals = IERC20(token).decimals();
            if (decimals != 6) amount = decimals > 6 ?
                               amount / 10 ** (decimals - 6):
                               amount * 10 ** (6 - decimals);
            if (token1isETH) {
                require(newUpperTick < currentLowerTick);
                // Above current = buy ETH with USD (provide $)
                // Below current = sell ETH for USD (provide ETH)
                liquidity = LiquidityAmounts.getLiquidityForAmount0(
                           TickMath.getSqrtPriceAtTick(newLowerTick),
                           TickMath.getSqrtPriceAtTick(newUpperTick), amount);
            } else {
                require(newLowerTick > currentUpperTick);
                liquidity = LiquidityAmounts.getLiquidityForAmount1(
                           TickMath.getSqrtPriceAtTick(newLowerTick),
                           TickMath.getSqrtPriceAtTick(newUpperTick), amount);
            }
        } Types.SelfManaged memory newPosition = Types.SelfManaged({
              created: block.number, owner: msg.sender,
              lower: newLowerTick, upper: newUpperTick,
              liq: int(uint(liquidity)) }); next = ++ID;

        require(liquidity > 0, "dust");
        selfManaged[next] = newPosition;
        positions[msg.sender].push(next);
        V4.outOfRange(msg.sender, int(uint(liquidity)),
                newLowerTick, newUpperTick, address(0));
    }

    function pendingRewards(address user) public
        view returns (uint ethReward, uint usdReward) {
        Types.Deposit memory LP = autoManaged[user];
        if (LP.pooled_eth == 0) return (0, 0);

        uint ethOwed = FullMath.mulDiv(LP.pooled_eth, ETH_FEES, WAD);
        uint usdOwed = FullMath.mulDiv(LP.pooled_eth, USD_FEES, WAD);

        // Saturating subtraction to prevent underflow
        ethReward = ethOwed > LP.fees_eth ? ethOwed - LP.fees_eth : 0;
        usdReward = usdOwed > LP.fees_usd ? usdOwed - LP.fees_usd : 0;
    }

    // withdrawal by LP of ETH specifically, depositor may
    // not know exactly how much they have accumulated in
    // fees, so it's alright to pass in a huge number...
    function withdraw(uint amount)
        external nonReentrant {
        (uint160 sqrtPriceX96,
         int24 tickLower, int24 tickUpper,) = _repack();
        Types.Deposit storage LP = autoManaged[msg.sender];
        uint pooled_eth = V4.POOLED_ETH();
        uint fees_eth; uint fees_usd;
        if (LP.pooled_eth > 0)
            (fees_eth,
             fees_usd) = pendingRewards(msg.sender);
        if (fees_eth > 0) { // rewards
            LP.pooled_eth += fees_eth;
            totalShares += fees_eth;
        } // Handle USD rewards
        fees_usd += LP.usd_owed;
        if (fees_usd > 0) {
            LP.usd_owed = 0;
            QUID.mint(msg.sender,
            fees_usd, address(QUID), 0);
        } // Cap withdrawal user's total balance
        // (i.e. principal + compounded rewards)
        amount = Math.min(amount, LP.pooled_eth);
        if (amount > 0) { uint sent;
            uint pulled = Math.min(
                amount, pooled_eth);
            if (pulled > 0) {
                // Only pull from V4 pool if position actually exists at these ticks.
                // After a depleted repack, ticks point to an empty position —
                // calling modLP would revert (CannotUpdateEmptyPosition).
                // Skip and let shortfall path (vault excess + arbETH) handle
                (,, uint128 posLiquidity) = V4.poolStats(tickLower, tickUpper);
                if (posLiquidity > 0) {
                    sent = V4.modLP(sqrtPriceX96, pulled, 0,
                            tickLower, tickUpper, msg.sender);
                }
            } // Arb flows naturally balance over time...
            // The V4/V3 spread keeps the pool in equilibrium
            // Any temporary imbalance self-corrects before LP withdrawals,
            // arbETH is mainly emergency code that should never execute...
            if (amount > sent) { uint shortfall = amount - sent;
                // Cap to this LP's pro-rata share of vogueETH.
                // AUX.vogueETH() covers all LPs; without the cap the first
                // withdrawer drains the entire vault leaving others with
                // shares but no ETH backing them
                { uint vaultShare = totalShares > 0 ? FullMath.mulDiv(AUX.vogueETH(),
                                                  amount, totalShares) : AUX.vogueETH();
                  uint inPool = V4.POOLED_ETH();
                  uint excess = Math.min(shortfall, vaultShare > inPool ?
                                                    vaultShare - inPool : 0);
                  if (excess > 0) {
                      excess = _sendETH(excess, msg.sender);
                      sent += excess; shortfall -= excess;
                  } }
                if (shortfall > 0) { uint arbed = AUX.arbETH(shortfall);
                    if (arbed > 0) { uint arbSent = _sendETH(
                        Math.min(arbed, shortfall), msg.sender);
                        sent += arbSent;
                    }
                } // Only burn shares equal to actual delivered amount
                // unrecovered shortfall is socialized across all LPs
                amount = Math.min(sent, amount);
                LP.pooled_eth -= amount;
                totalShares -= amount;
                // _sendETH / arbETH reduced vogueETH but lastVogueETH
                // is stale-high → next _syncYield sees current < last → skips.
                // Re-sync bookmark so gap yield isn't lost.
                lastVogueETH = AUX.vogueETH();
            } else { // Pool delivered enough
                // (or more) - burn full amount
                LP.pooled_eth -= amount;
                totalShares -= amount;
            }
        } if (LP.pooled_eth == 0) delete autoManaged[msg.sender];
        else {
            LP.fees_eth = FullMath.mulDiv(LP.pooled_eth, ETH_FEES, WAD);
            LP.fees_usd = FullMath.mulDiv(LP.pooled_eth, USD_FEES, WAD);
        }
    }

    // this is for single-sided liquidity (ETH deposit)
    // if you want to deposit dollars, mint with Basket
    function deposit(uint amount)
        external payable nonReentrant {
        uint price = AUX.getTWAP(1800);
        require(price > 0, "TWAP");
        uint deltaETH; uint deltaUSD;
        if (amount == 0 && msg.value == 0) return;

        // _repack MUST run before _depositETH so that _syncYield
        // reads the AAVE balance *before* the new deposit lands.
        // Otherwise the deposit is misattributed as AAVE yield,
        // inflating ETH_FEES and double-counting into pooled_eth.
        Types.Deposit storage LP = autoManaged[msg.sender];
        (uint160 sqrtPriceX96, int24 tickLower,
         int24 tickUpper,) = _repack();

        amount = _depositETH(msg.sender, amount);
        // Advance the yield bookmark past the deposit so the
        // *next* _syncYield doesn't mistake it for yield either.
        lastVogueETH += amount;

        uint eth_fees = ETH_FEES;
        uint usd_fees = USD_FEES;
        if (LP.pooled_eth > 0) {
            (uint ethReward, uint usdReward) = pendingRewards(msg.sender);
            LP.pooled_eth += ethReward; LP.usd_owed += usdReward;
            totalShares += ethReward;
        }
        (deltaUSD, // how much can be paired
         deltaETH) = this.addLiquidityHelper(
                               amount, price);
        if (deltaETH > 0) {
            LP.pooled_eth += deltaETH; totalShares += deltaETH;
            LP.fees_eth = FullMath.mulDiv(LP.pooled_eth, eth_fees, WAD);
            LP.fees_usd = FullMath.mulDiv(LP.pooled_eth, usd_fees, WAD);

            V4.modLP(sqrtPriceX96, deltaETH, deltaUSD,
                    tickLower, tickUpper, msg.sender);
        }
        uint unpaired = amount - deltaETH;
        if (unpaired > 0) {
            if (deltaETH == 0) {
                // No USD available to pair: ETH stays in AAVE earning yield.
                // Record LP shares so the deposit is not silently discarded
                // and the LP can withdraw + earn fees proportionally.
                LP.pooled_eth += unpaired; totalShares += unpaired;
                LP.fees_eth = FullMath.mulDiv(LP.pooled_eth, eth_fees, WAD);
                LP.fees_usd = FullMath.mulDiv(LP.pooled_eth, usd_fees, WAD);
            } else {
                // Partial pairing: only refund the unmatched excess.
                _sendETH(unpaired, msg.sender);
            }
            // Re-sync bookmark so _syncYield doesn't misattribute
            // the refunded or retained portion as yield.
            lastVogueETH = AUX.vogueETH();
        }
    }

    function addLiquidityHelper(
        uint deltaETH, uint price) public
        onlyUs returns (uint, uint) {
        (uint[14] memory deposits,) = AUX.get_deposits();
        uint liquidTotal = deposits[12] - deposits[11]
                            + AUX.getUSYCRedeemable();

        uint committed = V4.POOLED_USD() * 1e12;
        if (committed >= liquidTotal) return (0, 0);
        uint surplus = liquidTotal - committed;
        uint aaveAvail = AUX.vogueETH();

        uint pooledETH = V4.POOLED_ETH();
        uint availableETH = aaveAvail > pooledETH
                          ? aaveAvail - pooledETH : 0;

        uint targetUSD = FullMath.mulDiv(
                    deltaETH, price, WAD);

        if (targetUSD > surplus) {
            targetUSD = surplus;
            deltaETH = FullMath.mulDiv(
                   surplus, WAD, price);
        }
        if (deltaETH > availableETH) {
            deltaETH = availableETH;
            targetUSD = FullMath.mulDiv(
                   deltaETH, price, WAD);
        }
        uint usdOut = targetUSD / 1e12;
        if (usdOut == 0) return (0, 0);
        return (usdOut, deltaETH);
    }

     // pull liquidity from. . .
    function pull(uint id, // existing self-managed position
        int percent, address token) external nonReentrant {
        Types.SelfManaged storage position = selfManaged[id];
        require(position.owner == msg.sender, "403");

        require(block.number >=
        position.created + 47, "too soon");
        require(percent > 0 && percent < 101, "%");

        int liquidity = position.liq * percent / 100;
        require(liquidity > 0, "dust");
        int24 lower = position.lower;
        int24 upper = position.upper;

        uint[] storage myIds = positions[msg.sender];
        uint lastIndex = myIds.length > 0 ?
                         myIds.length - 1 : 0;

        if (percent == 100) { delete selfManaged[id];
            for (uint i = 0; i <= lastIndex; i++) {
                if (myIds[i] == id) {
                    if (i < lastIndex) {
                        myIds[i] = myIds[lastIndex];
                    }   myIds.pop(); break;
                }
            }
        } else {    position.liq -= liquidity;
            require(position.liq > 0, "pull");
        }
        V4.outOfRange(msg.sender, -liquidity,
                        lower, upper, token);
    }

    function _calculateYield(uint fees0, uint fees1, uint delta0,
        uint delta1, uint price) internal returns (uint yield) {
        uint last_repack = LAST_REPACK;
        uint deltaUSD; uint delta;
        uint usd_fees; uint fees;
        if (token1isETH) {
            (delta, deltaUSD) = (delta1, delta0);
            (fees, usd_fees) = (fees1, fees0);
        } else {
            (delta, deltaUSD) = (delta0, delta1);
            (fees, usd_fees) = (fees0, fees1);
        }
        if (totalShares > 0) {
            ETH_FEES += FullMath.mulDiv(fees, WAD, totalShares);
            USD_FEES += FullMath.mulDiv(usd_fees, WAD, totalShares);
        }
        if (last_repack > 0) {
            uint elapsed = block.timestamp - last_repack;
            uint denom = (deltaUSD * 1e12 + FullMath.mulDiv(
                            price, delta, WAD)) * elapsed;
            if (denom > 0) {
                yield = FullMath.mulDiv((usd_fees * 1e12 +
                    FullMath.mulDiv(price, fees, WAD)) * 365 days,
                      WAD, denom) / WAD;
            }
        } LAST_REPACK = block.timestamp;
    }

    function _depositETH(address sender,
        uint amount) internal returns (uint sent) {
        if (msg.value > 0) {
            WETH.deposit{value: msg.value}();
            sent = msg.value; amount -= Math.min(
                              amount, msg.value);
        }
        if (amount > 0) { uint available = Math.min(
                WETH.allowance(sender, address(this)),
                WETH.balanceOf(sender));

            uint took = Math.min(amount, available);
            if (took > 0) { WETH.transferFrom(sender,
                                address(this), took);
                                        sent += took;
            }
        } if (sent > 0) {
            // Sweep ALL WETH to AAVE — captures sent + any residual.
            // Only `sent` is returned for LP accounting; any extra
            // goes to vogueETH and _syncYield distributes it as yield.
            uint toDeposit = WETH.balanceOf(address(this));
            AUX.vogueETHOp(toDeposit, 0);
        }
    }

    function takeETH(uint howMuch, address recipient)
       external onlyUs returns (uint sent) {
       sent = _sendETH(howMuch, recipient);
    }

    /// @notice Sync AAVE yield into ETH_FEES...
    /// @dev Reads Vogue's entitled ETH from Aux
    function _syncYield() internal {
        uint current = AUX.vogueETHOp(0, 2);
        if (lastVogueETH > 0 && current > lastVogueETH) {
            uint yield = current - lastVogueETH;
            if (totalShares > 0)
                ETH_FEES += FullMath.mulDiv(
                    yield, WAD, totalShares);
        } lastVogueETH = current;
    }

    function _sendETH(uint howMuch,
       address toWhom) internal returns (uint sent) {
        uint alreadyInETH = address(this).balance;
        if (alreadyInETH >= howMuch) sent = howMuch;
        else { uint needed = howMuch - alreadyInETH;
            uint inWETH = WETH.balanceOf(address(this));
            if (needed > inWETH) {
                AUX.vogueETHOp(needed - inWETH, 1);
                // Aux sends ETH directly; recheck balances
                alreadyInETH = address(this).balance;
                inWETH = WETH.balanceOf(address(this));
            }
            if (inWETH > 0) WETH.withdraw(inWETH);
            sent = inWETH + alreadyInETH;
        }
        (bool success, ) = payable(toWhom).call{
                                   value: sent }("");
        if (!success) sent = 0;
    }

    function _repack() internal returns (uint160 sqrtPriceX96,
        int24 tickLower, int24 tickUpper, uint128 myLiquidity) {
        _syncYield(); // capture vault yield before anything else
        int24 currentTick; tickUpper = UPPER_TICK; tickLower = LOWER_TICK;
        (sqrtPriceX96, currentTick, myLiquidity) = V4.poolStats(
                                            tickLower, tickUpper);

        uint price; uint fees0; uint fees1; uint delta0; uint delta1;
        if (currentTick > tickUpper || currentTick < tickLower) {
            // Don't repack if deviating significantly from TWAP
            delta1 = AUX.getTWAP(1800);
            delta0 = BasketLib.getPrice(
              sqrtPriceX96, token1isETH);

            if (BasketLib.isManipulated(delta0, delta1, 3))
                return (sqrtPriceX96, tickLower,
                        tickUpper, myLiquidity);

            (int24 newTickLower,,
             int24 newTickUpper,) = _updateTicks(
                               sqrtPriceX96, 200);

            if (myLiquidity > 0) {
                (price, fees0, fees1,
                 delta0, delta1) = V4.repack(myLiquidity, sqrtPriceX96,
                        tickLower, tickUpper, newTickLower, newTickUpper);
                YIELD = _calculateYield(fees0, fees1, delta0, delta1, price);
            } LOWER_TICK = newTickLower; UPPER_TICK = newTickUpper;
            tickLower = newTickLower; tickUpper = newTickUpper;
        }
    }

    function repack() public onlyUs returns (uint160 sqrtPriceX96,
        int24 tickLower, int24 tickUpper, uint128 myLiquidity) {
        (sqrtPriceX96, tickLower, tickUpper, myLiquidity) = _repack();
    }

    function paddedSqrtPrice(uint160 sqrtPriceX96,
        bool up, uint delta) public view returns (uint160) {
        uint factor = up ? FixedPointMathLib.sqrt((10000 + delta) * 1e18 / 10000)
                         : FixedPointMathLib.sqrt((10000 - delta) * 1e18 / 10000);
        return uint160(FixedPointMathLib.mulDivDown(sqrtPriceX96, factor, 1e9));
    }

    function _alignTick(int24 tick, int24 width)
        internal pure returns (int24) {
        if (tick < 0 && tick % width != 0) {
            return ((tick - width + 1) / width) * width;
        }   return (tick / width) * width;
    }

    function _updateTicks(uint160 sqrtPriceX96, uint delta)
        internal view returns (int24 tickLower, uint160 lower,
                             int24 tickUpper, uint160 upper) {

        lower = paddedSqrtPrice(sqrtPriceX96, false, delta);
        upper = paddedSqrtPrice(sqrtPriceX96, true, delta);

        require(lower >= TickMath.MIN_SQRT_PRICE + 1, "minPrice");
        require(upper <= TickMath.MAX_SQRT_PRICE - 1, "maxPrice");

        tickLower = _alignTick(TickMath.getTickAtSqrtPrice(lower), int24(10));
        tickUpper = _alignTick(TickMath.getTickAtSqrtPrice(upper), int24(10));
    }
}
