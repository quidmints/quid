
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";

import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {ReentrancyGuard} from "solmate/src/utils/ReentrancyGuard.sol";

import {IERC4626} from "forge-std/interfaces/IERC4626.sol";
import {WETH as WETH9} from "solmate/src/tokens/WETH.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {BasketLib} from "../imports/BasketLib.sol";

import {stdMath} from "forge-std/StdMath.sol";
import {Types} from "../imports/Types.sol";
import {VogueCore} from "../VogueCore.sol";
import {Basket} from "../Basket.sol";
import {Aux} from "../Aux.sol";

contract VogueUni is
    Ownable, ReentrancyGuard {
    IERC4626 public wethVault;
    uint constant WAD = 1e18;
    VogueCore V4; WETH9 WETH;
    bool public nativeWETH;
    bool public token1isETH;
    Basket QUID; Aux AUX;

    // range = between ticks
    int24 public UPPER_TICK;
    int24 public LOWER_TICK;
    uint public LAST_REPACK;
    // ^ timestamp allows us
    // to measure APY% for
    uint public USD_FEES;
    uint public ETH_FEES;
    uint public YIELD;

    // V4.POOLED_ETH() = principal + ALL compounded fees (even unclaimed)
    // totalShares = sum of all LP.pooled_eth = principal + claimed fees
    // that got added to positions; gap represents fees that compounded
    // into the pool but haven't been attributed to any depositor yet...
    // swap fees accumulating in the V4 pool aren't added to `POOLED_ETH`
    // until collection via _modifyLiquidity during repack or withdrawal
    uint public totalShares;
    uint public lastShareBalance;
    uint public lastAssetsPerShare;

    // ^ price range is managed by our contracts
    mapping(address => uint[]) public positions;
    // ^ allows several selfManaged positions
    mapping(address => Types.Deposit) public autoManaged;
    mapping(uint => Types.SelfManaged) public selfManaged;
    // ^ key is tokenId of ID++ for that position
    uint internal ID;
    // ^ always grows

    constructor(address _vault)
        Ownable(msg.sender) {
        wethVault = IERC4626(_vault);
    }   fallback() external payable {}

    modifier onlyAux {
        require(msg.sender == address(AUX)
             || msg.sender == address(V4)
             || msg.sender == address(this), "403"); _;
    }

    function setup(address _quid, // < Basket...
        address _aux, address _core,
        bool _nativeWETH) external {
        require(address(AUX) == address(0), "!");
        nativeWETH = _nativeWETH;

        V4 = VogueCore(_core);
        QUID = Basket(_quid);
        AUX = Aux(payable(_aux));
        renounceOwnership();

        token1isETH = V4.token1isETH();
        require(QUID.V4() == address(this), "?");
        WETH = WETH9(payable(address(AUX.WETH())));
        WETH.approve(address(wethVault), type(uint).max);
        WETH.approve(address(AUX), type(uint).max);
        (uint160 sqrtPriceX96,,) = V4.poolStats(0, 0);
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

    /// distance represents the current price in ticks...
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
            "Distance must be -5000 to 5000 in increments of 100");

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
        if (fees_eth > 0) {
            LP.pooled_eth += fees_eth;
            totalShares += fees_eth;
        }
        // Handle USD rewards...
        fees_usd += LP.usd_owed;
        if (fees_usd > 0) {
            LP.usd_owed = 0;
            QUID.mint(msg.sender,
            fees_usd, address(QUID), 0);
        }
        // Cap withdrawal at user's total balance
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
            }
            // Arb flows naturally balance over time...
            // The V4/V3 spread keeps the pool in equilibrium
            // Any temporary imbalance self-corrects before LP withdrawals,
            // arbETH is mainly emergency code that should never execute...
            if (amount > sent) { uint shortfall = amount - sent;
                { uint currentPooledETH = V4.POOLED_ETH();
                  uint vaultShare = totalShares > 0
                      ? FullMath.mulDiv(wethVault.maxWithdraw(address(this)), amount, totalShares)
                      : wethVault.maxWithdraw(address(this));
                  uint excess = Math.min(shortfall, vaultShare > currentPooledETH ? vaultShare - currentPooledETH : 0);
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
            } else { // Pool delivered enough
                // (or more) - burn full amount
                LP.pooled_eth -= amount;
                totalShares -= amount;
            }
        }
        if (LP.pooled_eth == 0) delete autoManaged[msg.sender];
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
        uint deltaETH; uint deltaUSD;
        if (amount == 0 && msg.value == 0) return;
        amount = _depositETH(msg.sender, amount);

        Types.Deposit storage LP = autoManaged[msg.sender];
        (uint160 sqrtPriceX96, int24 tickLower,
        int24 tickUpper,) = _repack();
        uint eth_fees = ETH_FEES;
        uint usd_fees = USD_FEES;
        if (LP.pooled_eth > 0) {
            (uint ethReward, uint usdReward) = pendingRewards(msg.sender);
            LP.pooled_eth += ethReward; LP.usd_owed += usdReward;
            totalShares += ethReward;
        }
        (deltaUSD,
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
                // No USD available to pair: keep ETH in vault, record LP shares.
                LP.pooled_eth += unpaired; totalShares += unpaired;
                LP.fees_eth = FullMath.mulDiv(LP.pooled_eth, eth_fees, WAD);
                LP.fees_usd = FullMath.mulDiv(LP.pooled_eth, usd_fees, WAD);
            } else {
                _sendETH(unpaired, msg.sender);
            }
        }
    }

    function addLiquidityHelper(
        uint deltaETH, uint price) public
        onlyAux returns (uint, uint) {
        (uint total, ) = AUX.get_metrics(false);
        uint committed = V4.POOLED_USD() * 1e12;
        if (committed >= total) return (0, 0);
        uint surplus = total - committed;

        uint max = wethVault.maxWithdraw(address(this));
        uint pooledETH = V4.POOLED_ETH();
        uint availableETH = max > pooledETH ?
                            max - pooledETH : 0;

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

     // pull liquidity from self-managed position
    function pull(uint id, int percent, address token)
        external nonReentrant {
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
        }
        LAST_REPACK = block.timestamp;
    }

    function takeETH(uint howMuch, address recipient)
       external onlyAux returns (uint sent) {
       sent = _sendETH(howMuch, recipient);
    }

   /// @notice Deposit WETH returned from flash loan
   /// @dev Called by Aux after flash loan callback
   function depositFlashReturn() external onlyAux {
       uint amount = WETH.balanceOf(address(this));
       wethVault.deposit(amount, address(this));
   }

    /// @notice Sync ERC4626 vault yield into ETH_FEES unconditionally
    /// @dev Called at top of _repack so yield is always current
    /// before any deposit/withdraw snapshot is set
    function _syncYield() internal {
        uint currentShares = wethVault.balanceOf(address(this));
        uint currentAPS = wethVault.convertToAssets(WAD);
        if (lastShareBalance > 0 && currentAPS > lastAssetsPerShare) {
            uint vaultYield = FullMath.mulDiv(lastShareBalance,
                        currentAPS - lastAssetsPerShare, WAD);
            if (totalShares > 0)
                ETH_FEES += FullMath.mulDiv(
                vaultYield, WAD, totalShares);
        }
        lastShareBalance = currentShares;
        lastAssetsPerShare = currentAPS;
    }

   /// @notice Deposit yield from external source
   /// @dev Called by Aux to attribute yield to LPs
   function depositYield(uint amount) external onlyAux {
       if (amount == 0) return;
       _syncYield(); // Capture pending yield first
       WETH.transferFrom(msg.sender,
               address(this), amount);
       wethVault.deposit(amount, address(this));
       lastShareBalance = wethVault.balanceOf(address(this));
       // Attribute yield to all LPs pro rata
       if (totalShares > 0)
           ETH_FEES += FullMath.mulDiv(
               amount, WAD, totalShares);
   }

   function _depositETH(address sender,
       uint amount) internal returns (uint sent) {
       if (msg.value > 0) {
           require(nativeWETH, "no native wrap");
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
       } if (sent > 0) wethVault.deposit(
                      sent, address(this));
   }

   function _takeWETH(uint howMuch)
       internal returns (uint withdrawn) {
       uint max = wethVault.maxWithdraw(address(this));
       withdrawn = Math.min(howMuch, max);
       if (withdrawn == 0) return 0;
       wethVault.withdraw(withdrawn,
        address(this), address(this));
   }

   function _sendETH(uint howMuch,
        address toWhom) internal returns (uint sent) {
        if (!nativeWETH) {
            // Polygon: WETH is bridged ERC20, transfer directly
            sent = _takeWETH(howMuch);
            if (sent > 0) WETH.transfer(toWhom, sent);
            return sent;
        }
        // Arb/Base: unwrap WETH to native and send
        uint alreadyInETH = address(this).balance;
        if (alreadyInETH >= howMuch) {
            sent = howMuch;
        } else {
            uint needed = howMuch - alreadyInETH;
            uint withdrawn = _takeWETH(needed);
            WETH.withdraw(withdrawn);
            sent = withdrawn + alreadyInETH;
        }
        (bool success, ) = payable(toWhom).call{
                                   value: sent }("");
        if (!success) sent = 0;
    }

    function _repack() internal returns (uint160 sqrtPriceX96,
        int24 tickLower, int24 tickUpper, uint128 myLiquidity) {
        int24 currentTick; _syncYield();
        tickUpper = UPPER_TICK; tickLower = LOWER_TICK;
        (sqrtPriceX96, currentTick,
         myLiquidity) = V4.poolStats(tickLower, tickUpper);
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
            }
            LOWER_TICK = newTickLower; UPPER_TICK = newTickUpper;
            tickLower = newTickLower; tickUpper = newTickUpper;
        }
    }

    function repack() public onlyAux returns (uint160 sqrtPriceX96,
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
