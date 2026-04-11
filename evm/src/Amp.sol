
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Rover} from "./Rover.sol";
import {Types} from "./imports/Types.sol";
import {stdMath} from "forge-std/StdMath.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IPool} from "aave-v3/interfaces/IPool.sol";

import {IUiPoolDataProviderV3 as IUiData,
        IPoolAddressesProvider as PoolAddr} from "./imports/IUiPoolDataProviderV3.sol";
import {IV3SwapRouter as ISwapRouter} from "./imports/v3/IV3SwapRouter.sol";
import {BasketLib, AAVEv4, IHub, IAaveOracle} from "./imports/BasketLib.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IUniswapV3Pool} from "./imports/v3/IUniswapV3Pool.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {WETH as WETH9} from "solmate/src/tokens/WETH.sol";

interface IAux { // collects yield amplified...
    function deposit(address from, address token,
         uint amount) external returns (uint usd);

    function getTWAP(uint32 secondsAgo)
        external view returns (uint);
}

// Minimal interface to get pool data...
// provider address — used only in setup()...
// PoolAddressesProvider.getPoolDataProvider()
// is stable across v3.x versions...
interface IAaveProtocolDataProvider {
    function getReserveTokensAddresses(address asset)
        external view returns (address aTokenAddress,
                address stableDebtTokenAddress,
            address variableDebtTokenAddress);
}

/// @notice Handles AAVE APR/APY
/// @dev Integrates V3 for swaps
contract Amp is Ownable {
    bool public token1isWETH;
    uint constant WAD = 1e18;
    uint constant RAY = 1e27;
    uint USDCsharesSnapshot;
    uint wethSharesSnapshot;
    IERC20 USDC; WETH9 weth;

    IUniswapV3Pool v3Pool;
    Rover V3; IPool AAVE;
    ISwapRouter v3Router;
    AAVEv4 internal SPOKE;

    IHub internal HUB; address public AUX;
    IERC20 aWETHToken; IERC20 aUSDCToken;
    IERC20 vWETHToken; IERC20 vUSDCToken;

    mapping(address => Types.viaAAVE) public pledgesOneForZero;
    mapping(address => Types.viaAAVE) public pledgesZeroForOne;
    mapping(address => uint) totalBorrowed;
    PoolAddr ADDR; IUiData DATA;

    modifier onlyUs {
        require(msg.sender == address(this)
             || msg.sender == address(V3)
             || msg.sender == AUX, "403"); _;
    }

    constructor(address _aave, address _data,
        address _addr) Ownable(msg.sender) {
        DATA = IUiData(_data);
        ADDR = PoolAddr(_addr);
        AAVE = IPool(_aave);
    }

    event LeveragedPositionOpened(
        address indexed user,
        bool indexed isLong,
        uint supplied,
        uint borrowed,
        uint buffer,
        int256 entryPrice,
        uint breakeven,
        uint blockNumber
    );

    event PositionUnwound(
        address indexed user,
        bool indexed isLong,
        int256 exitPrice,
        int256 priceDelta,
        uint blockNumber
    );

    function setup(address payable _rover,
        address _aux) external onlyOwner {
        require(address(Rover(_rover).AMP())
             == address(this)); AUX = _aux;

        renounceOwnership();
        V3 = Rover(_rover);
        USDC = IERC20(V3.USDC());
        weth = WETH9(payable(
          address(V3.weth())));

        v3Pool = IUniswapV3Pool(V3.POOL());
        v3Router = ISwapRouter(V3.ROUTER());
        USDC.approve(AUX, type(uint).max);

        USDC.approve(address(AAVE), type(uint).max);
        USDC.approve(address(v3Router), type(uint).max);
        token1isWETH = v3Pool.token0() == address(USDC);
        weth.approve(address(v3Router), type(uint).max);
        weth.approve(address(AAVE), type(uint).max);

        { address pdp = PoolAddr(address(ADDR)).getPoolDataProvider();
            (address aw,, address vw) = IAaveProtocolDataProvider(pdp)
                            .getReserveTokensAddresses(address(weth));

            (address au,, address vu) = IAaveProtocolDataProvider(pdp)
                            .getReserveTokensAddresses(address(USDC));

            aWETHToken = IERC20(aw); aUSDCToken = IERC20(au);
            vWETHToken = IERC20(vw); vUSDCToken = IERC20(vu);
        }
    }

    function setV4(address _hub,
        address _spoke) external {
        require(msg.sender == AUX
            && address(SPOKE) == address(0));

        (,, uint wethCollat,
            uint usdcCollat) = _readV3Positions();

        if (wethCollat > 0) AAVE.withdraw(address(weth),
                            wethCollat, address(this));

        if (usdcCollat > 0) AAVE.withdraw(address(USDC),
                            usdcCollat, address(this));

        _setupV4(_hub, _spoke);
        uint wethBal = weth.balanceOf(address(this));
        uint usdcBal = USDC.balanceOf(address(this));

        if (wethBal > 0) SPOKE.supply(
             _reserveId(address(weth)),
               wethBal, address(this));

        if (usdcBal > 0) SPOKE.supply(
             _reserveId(address(USDC)),
               usdcBal, address(this));
    }

    function hasOpenDebt() external view returns (bool) {
        // Use internal totalBorrowed mapping — avoids external call to
        // UiPoolDataProvider which can revert on certain fork states.
        // DUST = 1000: AAVE ceiling-division at borrow time can leave 1 wei
        // in totalBorrowed after full repayment. A 1000-unit threshold (≈0.001
        // USDC / ≈0.000000001 WETH) is negligible and prevents false positives
        // without masking any real open position.
        uint DUST = 1000;
        return totalBorrowed[address(weth)] > DUST
            || totalBorrowed[address(USDC)] > DUST;
    }

    function _setupV4(address _hub,
        address _spoke) internal {
        SPOKE = AAVEv4(_spoke); HUB = IHub(_hub);
        weth.approve(_hub, type(uint).max);
        USDC.approve(_hub, type(uint).max);
    }

    /// @dev Read actual v3 debt and collateral
    function _readV3Positions() internal view
        returns (uint wethDebt, uint usdcDebt,
                 uint wethCollat, uint usdcCollat) {

        (IUiData.UserReserveData[]
          memory ud,) = DATA.getUserReservesData(
                             ADDR, address(this));

         wethDebt = (ud[0].scaledVariableDebt
            * AAVE.getReserveNormalizedVariableDebt(
                                      address(weth))) / RAY;
            wethCollat = aWETHToken.balanceOf(address(this));

        usdcDebt = (ud[3].scaledVariableDebt
            * AAVE.getReserveNormalizedVariableDebt(
                                      address(USDC))) / RAY;

        usdcCollat = aUSDCToken.balanceOf(address(this));
    }

    function _reserveId(address asset)
        internal returns (uint) {
        return SPOKE.getReserveId(address(HUB),
                        HUB.getAssetId(asset));
    }

    /// @notice leveraged long (borrow weth against USDC)
    /// @dev 70% LTV, excess USDC locked as collateral
    /// @param amount weth amount to deposit
    function leverETH(address who, uint amount,
        uint fromV4) payable external onlyUs {
        uint price =  IAux(AUX).getTWAP(0);
        if (fromV4 > 0) {
            weth.transferFrom(msg.sender,
                    address(this), amount);

            USDC.transferFrom(msg.sender,
                address(this), fromV4);
        } else amount = _deposit(amount);
        uint borrowing = amount * 7 / 10;
        uint buffer = amount - borrowing;
        uint totalValue = FullMath.mulDiv(
                        amount, price, WAD);

        require(totalValue >= 50e18); // min $50...
        // borrow full value of collateral to go long
        // selling the amount borrowed for USDC and
        // depositing the USDC for a future step in
        // unwind which is a basketball crossover
        uint usdcNeeded = totalValue / 1e12;
        uint took = 0;
        if (fromV4 < usdcNeeded) {
            took = usdcNeeded - fromV4;
            if (took > 0) {
                uint got = V3.withdrawUSDC(took);
                require(stdMath.delta(took, got) <= 1e6,
                                        "withdrawUSDC");
                                            took = got;
            }
        } _putUSDC(fromV4 + took);
        uint aWETHBefore = aWETHToken.balanceOf(address(this));
        _put(amount); // Capture actual aWETH
        if (borrowing > 0) { // received (liquidityIndex floor amount-1)
            uint vDebtBefore = vWETHToken.balanceOf(address(this));
            if (address(SPOKE) != address(0))
                SPOKE.borrow(_reserveId(address(weth)),
                             borrowing, address(this));

            else AAVE.borrow(address(weth), borrowing,
                                  2, 0, address(this));
            uint actualBorrowed = vWETHToken.balanceOf(
                                        address(this)) - vDebtBefore;

            totalBorrowed[address(weth)] += actualBorrowed;
            amount = FullMath.mulDiv(borrowing,
                            price, 1e12 * WAD);
            amount = _buyUSDC(borrowing, price);
            // ^ sell borrowed WETH to add lever
            _putUSDC(amount);
            Types.viaAAVE memory order = Types.viaAAVE({
                breakeven: totalValue, // < "supplied" gets
                // reset; need to remember original value
                // in order to calculate gains eventually
                supplied: took, borrowed: actualBorrowed,
                buffer: aWETHToken.balanceOf(address(this)) -
                aWETHBefore - actualBorrowed, price: int(price)});
            if (token1isWETH) { // check for pre-existing order
                require(pledgesOneForZero[who].price == 0);
                        pledgesOneForZero[who] = order;
            } else {
                require(pledgesZeroForOne[who].price == 0);
                        pledgesZeroForOne[who] = order;
            }
            emit LeveragedPositionOpened(
                msg.sender, true, took,
                borrowing, buffer, int(price),
                totalValue,block.number);
        }
    }

    /// @notice Open leveraged short position (USDC against weth)
    /// @dev 70% LTV on AAVE, deposited stablecoins as collateral
    /// @param amount Stablecoin amount to deposit
    function leverUSD(address who, uint amount,
        uint fromV4) payable external onlyUs {
        uint price = IAux(AUX).getTWAP(0);
        if (fromV4 > 0)
            weth.transferFrom(msg.sender,
                    address(this), fromV4);

        USDC.transferFrom(msg.sender,
            address(this), amount);

        uint deposited = amount;
        require(deposited * 1e12 + FullMath.mulDiv(
                    fromV4, price, WAD) >= 50e18);

        _putUSDC(amount);
        uint inWETH = FullMath.mulDiv(WAD,
                    amount * 1e12, price);
        // ^ convert USDC to 18 decimals

        uint neededFromV3 = 0;
        if (inWETH > fromV4)
            neededFromV3 = V3.take(inWETH - fromV4);
        // borrow WETH from V3, use in AAVE
        // as collateral to borrow dollars
        _put(fromV4 + neededFromV3); // collat
        uint totalWETH = fromV4 + neededFromV3;
        amount = FullMath.mulDiv(totalWETH * 7 / 10,
                                 price, WAD * 1e12);
        // borrow 70% of the WETH value in USDC
        if (amount > 0) {
            uint vUSDBefore = vUSDCToken.balanceOf(address(this));
            if (address(SPOKE) != address(0))
                SPOKE.borrow(_reserveId(address(USDC)),
                                    amount, address(this));
            else AAVE.borrow(address(USDC), amount, 2, 0,
                                             address(this));
            uint actualBorrowedUSD = vUSDCToken.balanceOf(address(this)) - vUSDBefore;
            // Borrow sends exactly `amount` USDC to AMP; vUSDC minted is amount+1
            // due to ceil rounding on the borrow index. Supply only what we received.
            _putUSDC(amount);

            totalBorrowed[address(USDC)] += actualBorrowedUSD;
            Types.viaAAVE memory order = Types.viaAAVE({
                breakeven: deposited * 1e12, // supplied
                // reset; need to remember original value
                // in order to calculate gains eventually
                supplied: neededFromV3, borrowed: actualBorrowedUSD,
                buffer: 0, price: int(price) });

            if (token1isWETH) { // check for pre-existing order
                require(pledgesZeroForOne[who].price == 0);
                pledgesZeroForOne[who] = order;
            }
            else {
                require(pledgesOneForZero[who].price == 0);
                pledgesOneForZero[who] = order;
            }
            emit LeveragedPositionOpened(
                msg.sender, false, neededFromV3,
                amount, 0, int(price),
                deposited, block.number);
        }
    }

    function _repayWETHGap(uint gap, uint spotPrice)
        internal returns (uint spent) {
        spent = FullMath.mulDiv(gap * 102 / 100,
                    uint(spotPrice), WAD * 1e12);

        if (spent > aUSDCToken.balanceOf(address(this))) return 0;
        uint got = _getUSDC(spent);
        if (_buy(got, spotPrice) >= gap) {
            if (address(SPOKE) != address(0))
                SPOKE.repay(_reserveId(address(weth)), gap, address(this));
            else AAVE.repay(address(weth), gap, 2, address(this));

            uint tracked = totalBorrowed[address(weth)];
            totalBorrowed[address(weth)] = gap > tracked ? 0
                                               : tracked - gap;
        } else spent = 0;
    }

    function _getUSDC(uint howMuch) internal
        returns (uint withdrawn) {
        uint amount = Math.min(
        USDCsharesSnapshot, howMuch);
        if (amount == 0) return 0;
        if (address(SPOKE) != address(0))
            (, withdrawn) = SPOKE.withdraw(
                  _reserveId(address(USDC)),
                     amount, address(this));

        else withdrawn = AAVE.withdraw(address(USDC),
                              amount, address(this));
    }

    function _get(uint howMuch) internal
        returns (uint withdrawn) {
        uint amount = Math.min(
        wethSharesSnapshot, howMuch);
        if (amount == 0) return 0;
        if (address(SPOKE) != address(0))
            (, withdrawn) = SPOKE.withdraw(
                  _reserveId(address(weth)),
                     amount, address(this));

        else withdrawn = AAVE.withdraw(address(weth),
                              amount, address(this));
    }

    function _put(uint amount) internal {
        if (amount == 0) return;
        if (address(SPOKE) != address(0))
            SPOKE.supply(_reserveId(address(weth)),
                                amount, address(this));
        else { AAVE.supply(address(weth), amount, address(this), 0);
               AAVE.setUserUseReserveAsCollateral(address(weth), true); }
    }

    function _putUSDC(uint amount) internal {
        if (amount == 0) return;
        if (address(SPOKE) != address(0))
            SPOKE.supply(_reserveId(address(USDC)),
                            amount, address(this));
        else { AAVE.supply(address(USDC), amount, address(this), 0);
               AAVE.setUserUseReserveAsCollateral(address(USDC), true); }
    }

    function _buyUSDC(uint howMuch,
        uint price) internal returns (uint) {
        Types.AuxContext memory ctx;
        ctx.v3Pool = address(v3Pool);
        ctx.v3Router = address(v3Router);
        ctx.weth = address(weth);
        ctx.usdc = address(USDC);
        ctx.v3Fee = V3.POOL_FEE();

        return BasketLib.swapWETHtoUSDC(
                    ctx, howMuch, price);
    }

    function _buy(uint howMuch,
        uint price) internal returns (uint) {
        Types.AuxContext memory ctx;
        ctx.v3Pool = address(v3Pool);
        ctx.v3Router = address(v3Router);
        ctx.weth = address(weth);
        ctx.usdc = address(USDC);
        ctx.v3Fee = V3.POOL_FEE();

        return BasketLib.swapUSDCtoWETH(
                    ctx, howMuch, price);
    }

    function _deposit(uint amount) internal returns (uint) {
        if (amount > 0) { weth.transferFrom(msg.sender,
                            address(this), amount);
        } if (msg.value > 0) { weth.deposit{
                            value: msg.value}();
                         amount += msg.value;
        }         return amount;
    } /// @param out token to withdraw
    /// @param borrowed Amount borrowed
    /// @param supplied Amount supplied
    function _unwind(address repay, address out,
        uint borrowed, uint supplied) internal {
        if (borrowed > 0) {
            if (address(SPOKE) != address(0))
                SPOKE.repay(_reserveId(repay),
                        borrowed, address(this));
            else AAVE.repay(repay, borrowed,
                          2, address(this));

            uint tracked = totalBorrowed[repay];
            totalBorrowed[repay] = borrowed >
            tracked ? 0 : tracked - borrowed;
        }
        if (supplied > 0 && out != address(0)) {
            uint withdrawn;
            if (address(SPOKE) != address(0))
                (, withdrawn) = SPOKE.withdraw(
                    _reserveId(out), supplied,
                                  address(this));
            else withdrawn = AAVE.withdraw(out,
                        supplied, address(this));

            require(withdrawn >= supplied - 5,
                    "withdraw slippage");
        }
    }

    /// @notice Calculate APR on AAVE positions
    /// @return repay Interest owed weth borrows
    /// @return repayUSDC owed on USDC borrows
    function _howMuchInterest() internal
        returns (uint repay, uint repayUSDC) {
        if (address(SPOKE) != address(0)) {
            uint id = _reserveId(address(weth));
            wethSharesSnapshot = SPOKE.getUserSuppliedAssets(
                                            id, address(this));
            id = _reserveId(address(USDC));
            USDCsharesSnapshot = SPOKE.getUserSuppliedAssets(
                                            id, address(this));

            AAVEv4.UserAccountData memory acct =
                SPOKE.getUserAccountData(address(this));
            if (acct.totalDebtValue == 0) return (0, 0);

            IAaveOracle oracle = IAaveOracle(SPOKE.ORACLE());
            // repay/repayUSDC reused as price, unit, prinVal
            repay = oracle.getReservePrice(
                  _reserveId(address(weth)));

            repayUSDC = oracle.getReservePrice(
                      _reserveId(address(USDC)));

            // wethPrinVal in `id`, usdcPrinVal...
            // in `acct.totalCollateralValue` (reuse)
            { uint wethUnit = 10 ** SPOKE.getReserve(
                            _reserveId(address(weth))).decimals;

              uint usdcUnit = 10 ** SPOKE.getReserve(
                            _reserveId(address(USDC))).decimals;

              uint wethPrinVal = repay > 0
                  ? (totalBorrowed[address(weth)] * repay)
                                              / wethUnit : 0;

              uint usdcPrinVal = repayUSDC > 0
                  ? (totalBorrowed[address(USDC)] * repayUSDC)
                                              / usdcUnit : 0;
              id = wethPrinVal + usdcPrinVal; // totalPrinVal
              if (acct.totalDebtValue > id && id > 0) {
                  uint interest = acct.totalDebtValue - id;
                  wethPrinVal = (interest * wethPrinVal) / id;
                  usdcPrinVal = interest - wethPrinVal;
                  // Convert back: repay still holds wethPrice
                  repay = repay > 0
                      ? (wethPrinVal * wethUnit) / repay : 0;

                  repayUSDC = repayUSDC > 0
                      ? (usdcPrinVal * usdcUnit) / repayUSDC : 0;

              } else { repay = 0; repayUSDC = 0; }
            }
        }  else {
            ( IUiData.UserReserveData[] memory userData,
            ) = DATA.getUserReservesData(ADDR, address(this));
            { uint borrowIndex = AAVE.getReserveNormalizedVariableDebt(address(weth));
              uint actualDebt = (userData[0].scaledVariableDebt * borrowIndex) / RAY;
              wethSharesSnapshot = aWETHToken.balanceOf(address(this));
              // Clamp dust: borrowIndex/RAY is the minimum actual tokens that
              // represent 1 scaled unit. Anything less rounds to 0 scaled on
              // repay and causes AAVE INVALID_AMOUNT (0x2075cc10) revert.
              uint minWeth = borrowIndex / RAY + 1;
              uint rawRepay = actualDebt > totalBorrowed[address(weth)]
              // index 0 on L1 and Base, 4 on Arbi and Poly...
                  ? actualDebt - totalBorrowed[address(weth)] : 0;
              repay = rawRepay >= minWeth ? rawRepay : 0;
            }
            { uint borrowIndex = AAVE.getReserveNormalizedVariableDebt(address(USDC));
              uint actualDebt = (userData[3].scaledVariableDebt * borrowIndex) / RAY;
              // index 3 on L1, 4 on Base, 12 on Arb, 20 on Polygon
              USDCsharesSnapshot = aUSDCToken.balanceOf(address(this));
              uint minUsdc = borrowIndex / RAY + 1;
              uint rawRepayUSDC = actualDebt > totalBorrowed[address(USDC)]
                        ? actualDebt - totalBorrowed[address(USDC)] : 0;
              repayUSDC = rawRepayUSDC >= minUsdc ? rawRepayUSDC : 0;
            }
        }
    }

    /// @dev Profit split at position close. Repays USDC interest from profit,
    /// transfers user's share, deposits protocol share via Aux.
    /// @return repayUSDC remainder after consuming interest from profit
    function _splitAndClose(uint pivot, uint pledgeBreakeven,
        uint repayUSDC, address who) private returns (uint) {
        uint breakeven = pledgeBreakeven / 1e12;
        if (pivot <= breakeven)
            USDC.transfer(who, pivot);
        else { uint profit = pivot - breakeven;
            if (repayUSDC > 0) {
                uint take = Math.min(profit, repayUSDC);
                profit -= take; repayUSDC -= take;
                _unwind(address(USDC), address(0), take, 0);
            } USDC.transfer(who, breakeven + profit / 2);
            IAux(AUX).deposit(address(this),
                 address(USDC), profit / 2);
        } return repayUSDC;
    }

    function unwindZeroForOne(
        address[] calldata whose) external {
        uint spot = IAux(AUX).getTWAP(0);
        int price = int(IAux(AUX).getTWAP(1800));
        Types.viaAAVE memory pledge;

        uint i; uint buffer; uint pivot;
        (uint repay, uint repayUSDC) = _howMuchInterest();
        while (i < 30 && i < whose.length) {
            address who = whose[i];
            pledge = token1isWETH ? pledgesOneForZero[who]:
                                    pledgesZeroForOne[who];

            if (pledge.price == 0) { i++; continue; }
            int delta = (price - pledge.price) * 1000 / pledge.price;

            if (delta <= -25 || delta >= 24) {
                if (pledge.borrowed > 0) {
                    uint wethInterest = totalBorrowed[address(weth)] > 0
                        ? FullMath.mulDiv(repay, pledge.borrowed,
                            totalBorrowed[address(weth)]) : 0;

                    repay -= wethInterest;
                    pivot = _get(pledge.borrowed + wethInterest);

                    require(pivot > 0);
                    uint gap = (pledge.borrowed + wethInterest) > pivot
                             ? (pledge.borrowed + wethInterest) - pivot : 0;
                    _unwind(address(weth), address(USDC),
                                 pivot, pledge.supplied);
                    if (gap > 0) {
                        uint spent = _repayWETHGap(gap, spot);
                        if (spent > 0) pledge.supplied -= spent;
                    } // AAVE caps withdrawal to available:
                    // pledge.buffer - 1e9; no require needed
                    uint bufLeft = pledge.buffer > 1e9
                                 ? pledge.buffer - 1e9 : 0;
                    // Refresh: _unwind stripped pledge.supplied from aUSDC.
                    // USDC liquidityIndex rounding means actual aUSDC < open-time
                    // snapshot by a few units; without this _getUSDC(buffer) reverts.
                    USDCsharesSnapshot = aUSDCToken.balanceOf(address(this));
                    if (delta <= -25) { // buy the dip - convert USDC to WETH
                        buffer = FullMath.mulDiv(pledge.borrowed,
                                uint(pledge.price), WAD * 1e12);

                        pivot = _getUSDC(buffer);
                        require(stdMath.delta(pivot, buffer) <= 5);

                        buffer = pivot + pledge.supplied;
                        pivot = FullMath.mulDiv(WAD,
                            buffer * 1e12, uint(price));

                        buffer = _buy(buffer, spot); // buy ETH
                        // Repay outstanding WETH interest
                        if (repay > 0) { //  before buffer withdrawal
                            uint toRepay = Math.min(buffer, repay);
                            buffer -= toRepay; repay -= toRepay;

                            _unwind(address(weth),
                            address(0), toRepay, 0);
                        }
                        buffer += _get(bufLeft); _put(buffer);

                        pledge.supplied = buffer;
                        pledge.price = price;
                        pledge.buffer = 0;
                    } else { // Price up...
                        // sell buffer WETH for USDC
                        buffer = _get(bufLeft);
                        require(stdMath.delta(buffer + 1e9, pledge.buffer) <= 5);
                        pivot = FullMath.mulDiv(buffer, uint(price), WAD * 1e12);
                        pivot = _buyUSDC(buffer, spot) + pledge.supplied;

                        pledge.buffer = pivot + FullMath.mulDiv(pledge.borrowed,
                                                uint(pledge.price), WAD * 1e12);
                        pledge.supplied = 0;
                        _putUSDC(pivot);
                    }   pledge.borrowed = 0;

                    if (token1isWETH) pledgesOneForZero[who] = pledge;
                    else pledgesZeroForOne[who] = pledge;
                } else if (delta <= -25 && pledge.buffer > 0) {
                    // Second pivot down - buffer is USDC, buy WETH
                    buffer = _getUSDC(pledge.buffer);
                    require(stdMath.delta(buffer, pledge.buffer) <= 5);
                    pivot = FullMath.mulDiv(WAD, buffer * 1e12, uint(price));
                    buffer = _buy(buffer, uint(price)); // buy ETH

                    pledge.supplied = buffer; _put(buffer);
                    pledge.buffer = 0; pledge.price = price;

                    if (token1isWETH) pledgesOneForZero[who] = pledge;
                    else pledgesZeroForOne[who] = pledge;
                }
                else if (delta >= 25 && pledge.supplied > 0) {
                    // Final exit: supplied is WETH, sell for $
                    buffer = _get(pledge.supplied);

                    // Pay  global
                    // WETH interest
                    if (repay > 0) {
                        pivot = Math.min(
                            buffer, repay);
                        buffer -= pivot;
                        repay -= pivot;
                        _unwind(address(weth),
                        address(0), pivot, 0);
                    }
                    pivot = FullMath.mulDiv(uint(price), buffer, 1e12 * WAD);
                    pivot = _buyUSDC(buffer, spot);
                    repayUSDC = _splitAndClose(pivot, pledge.breakeven, repayUSDC, who);
                    if (token1isWETH)
                         delete pledgesOneForZero[who];
                    else delete pledgesZeroForOne[who];
                } emit PositionUnwound(who, true, price,
                                    delta, block.number);
            } i++;
        }
    }

    function unwindOneForZero(
        address[] calldata whose) external {
        uint spot = IAux(AUX).getTWAP(0);
        int price = int(IAux(AUX).getTWAP(1800));
        Types.viaAAVE memory pledge;

        uint i; uint buffer; uint pivot;
        (uint repay, uint repayUSDC) = _howMuchInterest();
        while (i < 30 && i < whose.length) {
            address who = whose[i];
            pledge = token1isWETH ? pledgesZeroForOne[who]:
                                    pledgesOneForZero[who];

            if (pledge.price == 0) { i++; continue; }
            int delta = (price - pledge.price) * 1000 / pledge.price;
            if (delta <= -25 || delta >= 24) {
                if (pledge.borrowed > 0) {
                    uint usdcInterest = totalBorrowed[address(USDC)] > 0
                        ? FullMath.mulDiv(repayUSDC,
                            pledge.borrowed,
                            totalBorrowed[address(USDC)])
                        : 0;
                    repayUSDC -= usdcInterest;
                    pivot = _getUSDC(pledge.borrowed + usdcInterest);
                    require(pivot > 0);
                    uint gap = (pledge.borrowed + usdcInterest) > pivot
                             ? (pledge.borrowed + usdcInterest) - pivot : 0;
                    _unwind(address(USDC), address(weth), pivot, pledge.supplied);
                    if (gap > 0) {
                        // reuse buffer/pivot as temporaries (free at this scope)
                        buffer = FullMath.mulDiv(gap * 102 / 100, WAD * 1e12, uint(spot));
                        if (buffer <= pledge.supplied) { pivot = _buyUSDC(buffer, spot);
                            if (pivot >= gap) {
                                if (address(SPOKE) != address(0))
                                    SPOKE.repay(_reserveId(address(USDC)),
                                                      gap, address(this));
                                else AAVE.repay(address(USDC),
                                        gap, 2, address(this));

                                uint tracked = totalBorrowed[address(USDC)];
                                totalBorrowed[address(USDC)] = gap > tracked ? 0 : tracked - gap;
                                pledge.supplied -= buffer;
                            }
                        } buffer = 0; pivot = 0; // reset reused vars
                    }
                    if (delta >= 25) { // Price up (bad for short) - sell WETH for USDC
                        pivot = FullMath.mulDiv(pledge.supplied, uint(price), WAD * 1e12);
                        pledge.supplied = _buyUSDC(pledge.supplied, spot);
                        _putUSDC(pledge.supplied);
                    } else { // Price down (good for short)
                        if (repayUSDC > 0) {
                            uint toRepay = _getUSDC(repayUSDC);
                            if (toRepay > 0) {
                                repayUSDC -= toRepay;
                                _unwind(address(USDC), address(0), toRepay, 0);
                            }
                        } pledge.buffer = pledge.supplied;
                        _put(pledge.supplied);
                        pledge.supplied = 0;
                    }   pledge.borrowed = 0;
                        pledge.price = price;

                    if (token1isWETH) pledgesZeroForOne[who] = pledge;
                    else pledgesOneForZero[who] = pledge;
                } else if (delta <= -25 && pledge.supplied > 0) {
                    // Second pivot - supplied is USDC, buy WETH
                    pivot = _getUSDC(pledge.supplied);
                    require(stdMath.delta(pledge.supplied, pivot) <= 5);
                    pivot = FullMath.mulDiv(WAD, pledge.supplied * 1e12, uint(price));
                    pledge.buffer = _buy(pledge.supplied, spot);

                    _put(pledge.buffer);
                    pledge.supplied = 0;
                    pledge.price = price;

                    if (token1isWETH) pledgesZeroForOne[who] = pledge;
                    else pledgesOneForZero[who] = pledge;
                } else if (delta >= 25 && pledge.buffer > 0) {
                    // Final exit - buffer is WETH, sell for USDC
                    buffer = _get(pledge.buffer);
                    // Pay down global WETH interest first
                    if (repay > 0) {
                        pivot = Math.min(buffer, repay);
                        buffer -= pivot; repay -= pivot;
                        _unwind(address(weth),
                        address(0), pivot, 0);
                    }
                    pivot = FullMath.mulDiv(uint(price),
                                    buffer, 1e12 * WAD);

                    pivot = _buyUSDC(buffer, spot);
                    repayUSDC = _splitAndClose(pivot, pledge.breakeven, repayUSDC, who);
                    if (token1isWETH)
                         delete pledgesZeroForOne[who];
                    else delete pledgesOneForZero[who];
                } emit PositionUnwound(who, false, price,
                                    delta, block.number);
            } i++;
        }
    }
}
