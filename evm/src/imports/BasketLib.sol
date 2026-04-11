
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IV3SwapRouter as ISwapRouter} from "./v3/IV3SwapRouter.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";
import {WETH as WETH9} from "solmate/src/tokens/WETH.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IUniswapV3Pool} from "./v3/IUniswapV3Pool.sol";
import {Types} from "./Types.sol";

interface IAux {
    function vaults(address) external returns (address);
    function untouchables(address) external returns (uint);
    function take(address who,
        uint amount, address token,
        uint seed) external returns (uint);
}

interface IRover {
    function take(uint amount) external returns (uint);
    function withdrawUSDC(uint amount) external returns (uint);
    function deposit(uint amount) external;
    function depositUSDC(uint amount, uint price) external;
}

interface AAVEv3 {
    function getReserveAToken(address asset)
            external view returns (address);

    function getReserveNormalizedIncome(address asset)
                        external view returns (uint);


    function supply(address asset, uint amount,
    address onBehalfOf, uint16 referralCode) external;

    function withdraw(address asset, uint amount,
            address to) external returns (uint);
}

interface IHub {
    function getAssetId(address underlying)
            external view returns (uint256);
}

interface IAaveOracle {
    function getReservePrice(uint reserveId)
        external view returns (uint);
}

interface AAVEv4 {
    struct UserAccountData {
        uint totalCollateralValue;
        uint totalDebtValue;
        uint avgCollateralFactor;
    }
    struct ReserveData {
        uint8   decimals;
        address aTokenAddress;
        address variableDebtTokenAddress;
    }

    function getReserveId(address hub,
    uint assetId) external returns (uint);

    function withdraw(uint reserveId,
    uint amount, address onBehalfOf)
    external returns (uint, uint);

    function supply(uint reserveId,
    uint amount, address onBehalfOf)
    external returns (uint256, uint256);

    function borrow(uint reserveId,
    uint amount, address onBehalfOf)
    external returns (uint256);

    function repay(uint reserveId,
    uint amount, address onBehalfOf)
    external returns (uint256);

    function getUserSuppliedAssets(uint reserveId,
        address user) external view returns (uint);

    function getUserSuppliedShares(uint reserveId,
        address user) external view returns (uint);

    function getUserAccountData(address user)
        external view returns (UserAccountData memory);

    function getReserve(uint reserveId)
        external view returns (ReserveData memory);

    function ORACLE() external view returns (address);
}

interface IVogueCore {
    function POOLED_ETH() external view returns (uint);
    function POOLED_USD() external view returns (uint);
    function MAX_POOLED_USD() external view returns (uint);
    function token1isETH() external view returns (bool);
    function swap(uint160 sqrtPriceX96, address sender,
        bool forOne, address token, uint amount) external returns (uint);
}

/// @notice Minimal interface for Liquity V2 StabilityPool
/// @dev 0x5721cbbd64fc7Ae3Ef44A0A3F9a790A9264Cf9BF (WETH)
interface IStabilityPool {
    function provideToSP(uint _topUp, bool _doClaim) external;
    function withdrawFromSP(uint _amount, bool _doClaim) external;
    function getCompoundedBoldDeposit(address _depositor) external view returns (uint);
    function getDepositorYieldGainWithPending(address _depositor) external view returns (uint);
}

interface ITeller { // RWA vault for >10% APY on USDC
    function share() external view returns (address);
    function asset() external view returns (address);
    function todayTimestamp() external view returns (uint);
    function convertToAssets(uint shares) external view returns (uint);
    function convertToShares(uint assets) external view returns (uint);
    function deposit(uint assets, address receiver) external returns (uint shares);
    function redeem(uint shares, address receiver, address owner) external returns (uint assets);
    function redemptionLimitRemaining(address account, uint day) external view returns (uint);
    function limit(address) external view returns (uint56 depositLimit, uint56 redeemLimit);
}

library BasketLib {
    uint public constant RAY = 1e27;
    uint public constant WAD = 1e18;
    uint public constant WEEK = 604800;
    uint public constant MONTH = 2420000;
    uint128 public constant GAS_FINAL_RULING = 200_000;

    error UnknownMsgType();

    struct Metrics {
        uint total;
        uint last;
        uint yield;
        uint trackingStart;
        uint yieldAccum;
    }

    function computeMetrics(Metrics memory stats,
        uint elapsed, uint raw, uint yieldWeighted,
        uint tvl) internal view returns (Metrics memory) {

        if (stats.trackingStart > 0 && stats.last > 0)
            stats.yieldAccum += stats.yield * elapsed;

        else if (stats.trackingStart == 0)
            stats.trackingStart = block.timestamp;

        stats.yield = (raw > 0 && yieldWeighted >= raw) ?
            FullMath.mulDiv(WAD, yieldWeighted, raw) - WAD
                                           : stats.yield;
        stats.total = tvl; stats.last = block.timestamp;

        return stats;
    }

    /// @notice Extract composeMsg from send() calldata
    /// @dev Uses assembly to efficiently parse SendParam struct
    /// @return payload The extracted compose message bytes
    /* ---------------------------------------------------------------*
     * extracts SendParam.composeMsg from calldata...
     * assumes send(SendParam, MessagingFee, address)
     * [0] = dstEid(uint32), [1] = to(bytes32), [2] = amountLD(uint),
     * [3] = minAmountLD(uint), [4] = extraOptions(bytes),
     * [5] = composeMsg(bytes),    [6] = oftCmd(bytes)
     * ---------------------------------------------------------------*/
    function extract(bytes calldata original)
        external pure returns (bytes memory payload) {
        assembly { let base := original.offset
            let off0 := calldataload(add(base, 4))
            let structStart := add(add(base, 4), off0)
            let composeHeadPos := add(structStart, 0xA0)
            let composeOffset := calldataload(composeHeadPos)
            let composePos := add(structStart, composeOffset)
            let len := calldataload(composePos)

            let ptr := mload(0x40)
            mstore(ptr, len)
            calldatacopy(add(ptr, 0x20), add(composePos, 0x20), len)
            let size := add(0x20, and(add(len, 0x1f), not(0x1f)))
            mstore(0x40, add(ptr, size))
            payload := ptr
        }
    }

    /// @notice Build LayerZero Type 3 options for cross-chain messages
    /// @param msgType Message type (FINAL_RULING)
    /// @return options Encoded LZ options bytes
    function buildOptions(uint8 msgType) external
        pure returns (bytes memory) { uint128 gas;
        if (msgType == 6) gas = GAS_FINAL_RULING;
        else revert UnknownMsgType();

        // LayerZero V2 Type 3 Options Format:
        // [type(uint16)][workerID(uint8)][optionLength(uint16)][optionType(uint8)][gas(uint128)][value(uint128)]
        // See: https://docs.layerzero.network/v2/developers/evm/configuration/options
        // OPTION_TYPE_LZRECEIVE contains (uint128 _gas, uint128 _value)

        uint128 value = 10_000_000; // 0.01 SOL in lamports
        // Total size: 2 + 1 + 2 + 1 + 16 + 16 = 38 bytes
        bytes memory options = new bytes(38);

        // Type 3 header (uint16 big-endian)
        options[0] = 0x00;
        options[1] = 0x03;

        // Worker ID: Executor (uint8)
        options[2] = 0x01;

        // Option length: 33 bytes = 1 (option type) + 16 (gas) + 16 (value)
        options[3] = 0x00;
        options[4] = 0x21; // 0x21 = 33

        // Option type: LZRECEIVE (uint8)
        options[5] = 0x01;

        // Gas (uint128 = 16 bytes, big-endian)
        for (uint i = 0; i < 16; i++) {
            options[6 + i] = bytes1(uint8(gas >> (120 - i * 8)));
        }
        // Value (uint128 = 16 bytes, big-endian)
        for (uint i = 0; i < 16; i++) {
            options[22 + i] = bytes1(uint8(value >> (120 - i * 8)));
        }
        return options;
    }

    function get_deposits(address aux, address pool,
        address hub, address[] memory stables) external
        returns (uint[14] memory amounts) { uint i;
        // amounts[0]     = yield-weighted sum across ALL sources
        // amounts[1..11] = per-token deposit values (18 dec)
        // amounts[12]    = raw TVL total (all sources, + L2 QD)
        // amounts[13]    = L2 basket deposits (set by Aux, not BasketLib)
        address vault; uint balance; address stable;
        for (i = 0; i < 4; i++) { stable = stables[i];
            uint yieldWeighted;
            if (hub == address(0)) {
                vault = AAVEv3(pool).getReserveAToken(stable);
                 // Some aTokens (e.g. USDT) can overflow in getReserveNormalizedIncome
                // at certain fork blocks. Wrap in try/catch so one bad token
                // doesn't brick the whole get_deposits call.
                try IERC20(vault).balanceOf(address(this))
                    returns (uint bal) { balance = bal; }
                catch { balance = 0; }
                uint yieldFactor;
                try AAVEv3(pool).getReserveNormalizedIncome(stable)
                    returns (uint yf) { yieldFactor = yf; }
                catch { yieldFactor = RAY; } // 1:1 fallback
                yieldWeighted = FullMath.mulDiv(balance, yieldFactor, RAY);
            } else {
                address vlt = IAux(aux).vaults(stable);
                if (vlt == pool) { // AAVE V4
                    uint reserveId = AAVEv4(pool).getReserveId(hub,
                                      IHub(hub).getAssetId(stable));
                    balance = AAVEv4(pool).getUserSuppliedAssets(
                                        reserveId, address(this));
                    uint shares = AAVEv4(pool).getUserSuppliedShares(
                                            reserveId, address(this));
                    yieldWeighted = (shares > 0) ? FullMath.mulDiv(balance,
                                                balance, shares) : balance;
                }
                else if (vlt != address(0)) { // ERC4626 (e.g. Morpho)
                    uint sh = IERC4626(vlt).balanceOf(address(this));
                    balance = sh > 0 ? IERC4626(vlt).convertToAssets(sh) : 0;
                    yieldWeighted = balance;
                }
            }
            if (balance > 0) { balance *= i < 3 ? 1e12 : 1;
                         yieldWeighted *= i < 3 ? 1e12 : 1;
                uint reserved = IAux(aux).untouchables(stable);
                if (reserved > 0) { uint cap = Math.min(balance, reserved);
                    balance -= cap; yieldWeighted -= Math.min(yieldWeighted, cap);
                } amounts[i + 1] = balance; amounts[12] += balance;
                amounts[0] += yieldWeighted;
            }
        } for (i = 4; i < 9; i++) {
            stable = stables[i]; vault = IAux(aux).vaults(stable);
            uint shares = IERC4626(vault).balanceOf(address(this));
            uint reserved = IAux(aux).untouchables(stable);
            if (reserved > 0) shares -= Math.min(shares,
                IERC4626(vault).convertToShares(reserved));
            if (shares > 0) {
                balance = IERC4626(vault).convertToAssets(shares);
                amounts[i + 1] = balance;  // raw position value
                amounts[12] += balance;    // raw TVL total
                // yield-weighted: balance × sharePrice
                uint supply = IERC4626(vault).totalSupply();
                if (supply > 0) {
                    amounts[0] += FullMath.mulDiv(balance,
                    IERC4626(vault).totalAssets(), supply);
                } else amounts[0] += balance;
            }
        } stable = stables[10];
        vault = IAux(aux).vaults(stable);
        (uint usycValue, ) = getUSYCValue(
                     vault, address(this));

        if (usycValue > 0) {
            uint usycReserved = IAux(aux).untouchables(stable);
            usycValue -= Math.min(usycValue, usycReserved);
            amounts[11] = usycValue; amounts[12] += usycValue;
            // Yield-weighted: usycValue × teller growth rate.
            // growth = convertToAssets(shares) / shares (teller-wide, pre-reserve).
            // So yieldWeighted = usycValue × totalValue / parValue.
            address usyc = ITeller(vault).share();
            uint shares = IERC20(usyc).balanceOf(address(this));
            if (shares > 0) {
                uint totalValue = ITeller(vault).convertToAssets(shares) * 1e12;
                uint parValue = shares * 1e12;
                amounts[0] += FullMath.mulDiv(usycValue, totalValue, parValue);
            } else amounts[0] += usycValue;
        }
    }

    function getAverageYield(Metrics memory stats)
        external view returns (uint) {
        if (stats.trackingStart == 0) return 0;
        uint totalTime = block.timestamp - stats.trackingStart;
        uint timeSinceUpdate = block.timestamp - stats.last;
        uint currentAccum = stats.yieldAccum
            + stats.yield * timeSinceUpdate;
        return currentAccum / (totalTime + 1);
    }

    // sqrt(deficit) × avgYield / 4
    function seedFee(uint usd,
        uint untouchable, uint target,
        uint avgYield) internal pure returns (uint) {
        if (target == 0 || untouchable >= target) return 0;
        uint deficit = FullMath.mulDiv(
        target - untouchable, WAD, target);
        uint sqrtDef = Math.sqrt(deficit * WAD);
        if (sqrtDef == 0 || avgYield == 0) return 0;
        uint fee = Math.min(FullMath.mulDiv(FullMath.mulDiv(
            usd, sqrtDef, WAD), avgYield, WAD * 4),
            target - untouchable);
        return Math.min(fee,
            FullMath.mulDiv(usd, avgYield, WAD * 12));
    }

    /// @notice Calculate SP position
    //  & yield contribution in get_deposits
    /// @param sp StabilityPool address...
    /// @param depositor Address to check
    /// @param reserved Untouchable amount
    /// @param state Current SP tracking state
    /// @return totalValue Position value (compounded + yield - reserved)
    /// @return yieldContrib Contribution to amounts[12] for weighted average
    function calcSPValue(address sp, address depositor,
        uint reserved, SPState memory state) external view returns
        (uint totalValue, uint yieldContrib) { if (sp == address(0)) return (0, 0);
        uint compounded = IStabilityPool(sp).getCompoundedBoldDeposit(depositor);
        uint yieldGain = IStabilityPool(sp).getDepositorYieldGainWithPending(depositor);
        totalValue = compounded + yieldGain; totalValue -= Math.min(totalValue, reserved);

        if (totalValue == 0) return (0, 0);
        // Calculate time-weighted APY for yield contribution
        uint currentPrincipalTime = state.spPrincipalTime +
        state.spValue * (block.timestamp - state.spLastUpdate);
        if (currentPrincipalTime > 0 && state.spTotalYield > 0) {
            uint rate = FullMath.mulDiv(state.spTotalYield,
                    WAD * 365 days, currentPrincipalTime);

            yieldContrib = FullMath.mulDiv(
               totalValue, WAD + rate, WAD);
        } else
            yieldContrib = totalValue;
            // no yield history, 1:1

    }

    struct SPState {
        uint spValue;         // original principal tracking (not compounded yield)
        uint spTotalYield;    // cumulative harvested yield (USD value, WAD)
        uint spPrincipalTime; // cumulative (principal * seconds)
        uint spLastUpdate;    // last update timestamp
    }

    /// @notice Result from SP withdraw operation
    struct SPWithdrawResult {
        uint sent;            // BOLD amount being sent out
        uint toRedeposit;     // BOLD amount to redeposit (already done)
        uint wethGain;        // ETH collateral gained (caller handles swap)
        uint boldReceived;    // Total BOLD received from SP
        // Updated state values - caller must write these
        uint newSpValue;
        uint newSpTotalYield;
        uint newSpPrincipalTime;
        uint newSpLastUpdate;
    }

    /// @notice Execute SP withdrawal and return results with updated state
    /// @dev Performs withdrawFromSP and provideToSP, caller handles WETH swap
    /// @param sp StabilityPool address
    /// @param bold BOLD token address
    /// @param weth WETH token address
    /// @param amount Requested withdrawal amount
    /// @param ethPrice Current ETH price (WAD) for yield calculation
    /// @param state Current SP tracking state
    /// @return r Result with amounts and updated state values
    function withdrawFromSP(address sp, address bold,
        address weth, uint amount, uint ethPrice,
        SPState memory state) external returns (SPWithdrawResult memory r) {
        uint compounded = IStabilityPool(sp).getCompoundedBoldDeposit(address(this));
        uint yieldGain = IStabilityPool(sp).getDepositorYieldGainWithPending(address(this));
        uint totalBold = compounded + yieldGain;
        if (totalBold == 0) return r;

        // Only from principal, not yield...
        amount = Math.min(amount, compounded);
        uint wethBefore = WETH9(payable(weth)).balanceOf(address(this));
        uint boldBefore = IERC20(bold).balanceOf(address(this));
        IStabilityPool(sp).withdrawFromSP(compounded, true);

        r.boldReceived = IERC20(bold).balanceOf(address(this)) - boldBefore;
        r.wethGain = WETH9(payable(weth)).balanceOf(address(this)) - wethBefore;

        // Send only from principal
        r.sent = Math.min(amount, r.boldReceived);
        // Redeposit everything else (includes all yield)
        r.toRedeposit = r.boldReceived - r.sent;

        r.newSpPrincipalTime = state.spPrincipalTime +
           state.spValue * (block.timestamp - state.spLastUpdate);
        r.newSpLastUpdate = block.timestamp;

        // Only ETH gains count as harvested (BOLD yield compounds)
        uint wethValueUSD = FullMath.mulDiv(r.wethGain, ethPrice, WAD);
        r.newSpTotalYield = state.spTotalYield + wethValueUSD;

        // Sent is all principal
        r.newSpValue = state.spValue > r.sent ? state.spValue - r.sent : 0;
        if (r.toRedeposit > 0) IStabilityPool(sp).provideToSP(r.toRedeposit, false);

    }

    /// @notice Deposit BOLD to StabilityPool and return updated state
    /// @param sp StabilityPool address
    /// @param amount Amount to deposit
    /// @param state Current SP tracking state
    /// @return newSpValue Updated spValue
    /// @return newSpPrincipalTime Updated spPrincipalTime
    /// @return newSpLastUpdate Updated spLastUpdate
    function depositToSP(address sp,
        uint amount, SPState memory state) external
        returns (uint newSpValue, uint newSpPrincipalTime, uint newSpLastUpdate) {
        newSpPrincipalTime = state.spPrincipalTime + state.spValue * (
                                 block.timestamp - state.spLastUpdate);

        newSpValue = state.spValue + amount;
        newSpLastUpdate = block.timestamp;
        IStabilityPool(sp).provideToSP(amount, false);
    }

    /// @param amount Amount being deposited
    /// @return cut Fee amount to deduct from deposit
    /// @notice Deposit fee driven by weighted median vote (K).
    ///         Symmetric with withdrawal: stressed (high haircut)
    ///         → higher fee → reserves build faster.
    ///         K=0 → 900bps (9%), K=32 → 100bps (1%)

    /// @notice ETH price from sqrtPriceX96
    /// @param sqrtPriceX96 Square root price
    /// @param token0isUSD Whether token0 is USD
    /// @return price ETH price in USD 1e18
    function getPrice(uint160 sqrtPriceX96, bool token0isUSD)
        public pure returns (uint price) {
        uint casted = uint(sqrtPriceX96);
        uint ratioX128 = FullMath.mulDiv(
               casted, casted, 1 << 64);

        if (token0isUSD) {
          price = FullMath.mulDiv(1 << 128,
              WAD * 1e12, ratioX128);
        } else {
          price = FullMath.mulDiv(ratioX128,
              WAD * 1e12, 1 << 128);
        }
    }

    function getUSYCRedeemable(address teller) public view returns
        (uint) { address usycToken = ITeller(teller).share();
        uint usycBalance = ITeller(teller).convertToAssets(
                           IERC20(usycToken).balanceOf(msg.sender));
        uint dailyLimit = ITeller(teller).redemptionLimitRemaining(
                      msg.sender, ITeller(teller).todayTimestamp());
        return Math.min(usycBalance, dailyLimit) * 1e12; // Scale to 1e18
    }

    function supplyAAVE(address aave,
        address asset, uint amount,
        address to, address hub) // 6909
        public returns (uint deposited) {
        if (hub == address(0)) { deposited = amount;
                            AAVEv3(aave).supply(asset,
                                        amount, to, 0);
        } else { uint reserveId = AAVEv4(aave).getReserveId(hub,
                                    IHub(hub).getAssetId(asset));
            (, deposited) = AAVEv4(aave).supply(reserveId,
                                amount, address(this));
        }
    }

    function withdrawAAVE(address aave, address asset,
        uint amount, address to, address hub)
        public returns (uint drawn) {
        if (hub == address(0)) {
            amount = Math.min(amount, aaveAvailableV3(
                                        aave, asset));
            if (amount == 0) return 0;
            drawn = AAVEv3(aave).withdraw(asset, amount, to);
        } else {
            uint reserveId = AAVEv4(aave).getReserveId(hub,
                              IHub(hub).getAssetId(asset));
            uint max = AAVEv4(aave).getUserSuppliedAssets(
                                 reserveId, address(this));

            amount = amount > 0 ? Math.min(amount, max) : max;
            if (amount == 0) return 0;
            (, drawn) = AAVEv4(aave).withdraw(reserveId,
                                amount, address(this));

            if (to != address(this))
                IERC20(asset).transfer(to, drawn);
        }
    }

    function getUSYCValue(// time value of money
        address teller, address holder) public
        view returns (uint value, uint yield) {
        if (teller == address(0)) return (0, 0);
        address usyc = ITeller(teller).share();
        uint shares = IERC20(usyc).balanceOf(holder);
        uint assets = ITeller(teller).convertToAssets(shares); // USDC 6 dec
        value = assets * 1e12; // Scale to 18 dec
        // Yield = value above par (1 USYC started at $1)
        uint parValue = shares * 1e12; // par = 1:1 with USDC
        yield = value > parValue ? value - parValue : 0;
    }

    function withdrawUSYC(address teller,
        address recipient, uint amount)
        external returns (uint sent,
        uint sharesUsed) { address usyc = ITeller(teller).share();
        uint shares = IERC20(usyc).balanceOf(address(this));
        shares = Math.min(ITeller(teller).convertToShares(amount), shares);

        uint today = ITeller(teller).todayTimestamp();
        uint remaining = ITeller(teller).redemptionLimitRemaining(
                                             address(this), today);
        sharesUsed = Math.min(shares,
        ITeller(teller).convertToShares(remaining));
        if (sharesUsed > 0) sent = ITeller(teller).redeem(sharesUsed,
                                            recipient, address(this));
    }

    function depositUSYC(address teller, address aave,
        address usdc, uint amount, address hub) public returns
        (uint pulled, uint deposited) { if (amount == 0) return (0, 0);
        (uint56 depositLimit,) = ITeller(teller).limit(address(this));
        if (depositLimit == 0) return (0, amount);
        // reuse `deposited` as maxToUSYC, `pulled` as capacity
        try ITeller(teller).redemptionLimitRemaining(
            address(this), ITeller(teller).todayTimestamp())
            returns (uint redeemable) {
            address usycToken = ITeller(teller).share();
            deposited = ITeller(teller).convertToAssets(
             IERC20(usycToken).balanceOf(address(this)));
            deposited = redeemable > deposited ?
                        redeemable - deposited : 0;
        } catch { return (0, amount); }
        pulled = Math.min(uint(depositLimit), deposited);
        // pulled = capacity, deposited = 0 from here
        deposited = Math.min(amount, pulled);
        uint fromAAVE; // ^ fromIncoming
        if (pulled > deposited) {
            uint aaveBal = hub == address(0)
                ? aaveAvailableV3(aave, usdc)
                : AAVEv4(aave).getUserSuppliedAssets(
                        AAVEv4(aave).getReserveId(hub,
                            IHub(hub).getAssetId(usdc)),
                                         address(this));

            fromAAVE = Math.min(pulled - deposited, aaveBal);
            if (fromAAVE > 0)
                withdrawAAVE(aave, usdc, fromAAVE,
                              address(this), hub);
        }
        // toTeller = deposited + fromAAVE (reuse `pulled`)
        pulled = deposited + fromAAVE;
        if (pulled > 0) {
            deposited = IERC20(usdc).balanceOf(address(this));
            try ITeller(teller).deposit(pulled, address(this))
                returns (uint) { pulled = deposited -
                    IERC20(usdc).balanceOf(address(this));
            } catch {
                if (fromAAVE > 0) {
                    supplyAAVE(aave, usdc, fromAAVE,
                                 address(this), hub);
                  fromAAVE = 0;
                } pulled = 0;
            }
        } else pulled = 0;
        // pulled = actual USDC consumed by teller
        // deposited = remainder for caller to send to AAVE
        deposited = amount - (pulled > fromAAVE
                            ? pulled - fromAAVE : 0);
    }

    function ticksToPrice(int56 tickCum0,
        int56 tickCum1, uint32 period, bool token0isUSD) external
        pure returns (uint price) { int56 delta = tickCum1 - tickCum0;
        int24 averageTick = int24(delta / int56(uint56(period)));
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(averageTick);
        price = getPrice(sqrtPriceX96, token0isUSD);
    }

    /// @notice Find index of last mature batch
    function matureBatches(uint[] memory batches,
        uint currentTimestamp, uint deployedTime)
        external pure returns (int i) {
        if (batches.length == 0) return -1;
        uint currentMonth = (currentTimestamp - deployedTime) / MONTH;
        int start = int(batches.length - 1);
        for (i = start; i >= 0; i--)
            if (batches[uint(i)] <= currentMonth) return i;

        return -1;
    }

    /// @param thresholdPercent Max deviation
    function isManipulated(uint spot, uint twap,
        uint thresholdPercent) public pure returns (bool) {
        uint dev = spot > twap ? spot - twap : twap - spot;
        return dev * 100 > twap * thresholdPercent;
    }

    /// fetch V3 spot, check against twap
    function isV3Manipulated(address pool,
        bool token1isWETH, uint twapPrice)
        public view returns (bool) {
        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3Pool(pool).slot0();
        return isManipulated(getPrice(sqrtPriceX96, token1isWETH), twapPrice, 2);
    }

    function calculateVaultWithdrawal(address vault, uint amount)
        external view returns (uint sharesNeeded, uint assetsReceived) {
        uint vaultBalance = IERC4626(vault).balanceOf(address(this));
        sharesNeeded = IERC4626(vault).convertToShares(amount);
        sharesNeeded = Math.min(vaultBalance, sharesNeeded);
        assetsReceived = IERC4626(vault).convertToAssets(sharesNeeded);
        return (sharesNeeded, assetsReceived);
    }

    /// @notice Scale token amounts between precisions...
    function scaleTokenAmount(uint amount, address token,
        bool scaleUp) external view returns (uint scaled) {
        uint decimals = IERC20(token).decimals();
        uint scale = decimals < 18 ? 18 - decimals : 0;
        scaled = scale > 0 ? (scaleUp ? amount * (10 ** scale):
              amount / (10 ** scale)) : amount; return scaled;
    }

    function arbETH(Types.AuxContext memory ctx, uint shortfall,
        uint price) external returns (uint got, bool failed) {
        uint usdNeeded = convert(shortfall, price, false);
        uint took = IAux(address(this)).take(address(this),
                                   usdNeeded, ctx.usdc, 0);
        if (took == 0)
            return (0, false);

         got = swapUSDCtoWETH(ctx,
               took / 1e12, price);

        if (got == 0) {
            // V3 failed — USDC was pulled but never converted.
            // Re-deposit so it earns yield and stays visible...
            uint stranded = IERC20(ctx.usdc).balanceOf(address(this));
            if (stranded > 0) {
                if (ctx.isAAVE) supplyAAVE(ctx.vault, ctx.usdc,
                             stranded, address(this), ctx.hub);
                // !isAAVE: leave USDC in contract (no USDC vault in ctx)
            } return (0, false);
        }
        if (ctx.isAAVE) supplyAAVE(ctx.vault, ctx.weth,
                           got, address(this), ctx.hub);

        else got = IERC4626(ctx.vault).convertToAssets(
               IERC4626(ctx.vault).deposit(got, ctx.v4));
    }

    function swapWETHtoUSDC(Types.AuxContext memory ctx,
        uint amountIn, uint price) public returns (uint amountOut) {
        uint poolUSDC = IERC20(ctx.usdc).balanceOf(ctx.v3Pool);
        uint max = convert(poolUSDC, price, true);
        if (amountIn > max) amountIn = max;
        if (amountIn > 0) {
            uint minOut = convert(amountIn, price, false) * 99500 / 100000;
            (bool ok, bytes memory ret) = ctx.v3Router.call(abi.encodeWithSelector(
                    ISwapRouter.exactInput.selector, ISwapRouter.ExactInputParams(
                        abi.encodePacked(ctx.weth, ctx.v3Fee, ctx.usdc),
                        address(this), amountIn, minOut)));

            if (ok && ret.length >= 32) amountOut = abi.decode(ret, (uint));
        }
    }

    function sourceExternalUSD(Types.AuxContext memory ctx,
        uint wethIn, uint price) public returns (uint usdcOut) {
        uint wethBefore = IERC20(ctx.weth).balanceOf(address(this));
        if (ctx.rover != address(0)) {
            uint targetUSDC = convert(
                 wethIn, price, false);

            uint fromRover = IRover(ctx.rover).withdrawUSDC(targetUSDC);
            if (fromRover > 0) {
                uint wethForRover = convert(
                     fromRover, price, true);

                try IRover(ctx.rover).deposit(wethForRover) {}
                catch { /* tokens stay in Rover for next repack */ }

                usdcOut = fromRover;
                wethIn = wethIn > wethForRover ?
                         wethIn - wethForRover : 0;
            }
        } if (wethIn > 0) usdcOut += swapWETHtoUSDC(ctx, wethIn, price);
        // Only sweep WETH that accumulated during THIS call
        // (i.e., was pulled for swapping but V3 failed)...
        uint wethAfter = IERC20(ctx.weth).balanceOf(address(this));
        if (wethAfter > wethBefore) {
            uint stranded = wethAfter - wethBefore;
            if (ctx.isAAVE) supplyAAVE(ctx.vault, ctx.weth,
                         stranded, address(this), ctx.hub);

            else IERC4626(ctx.vault).deposit(
                      stranded, address(this));
        }
    }

    function sourceExternalWETH(Types.AuxContext memory ctx,
        uint usdcIn, uint price) public returns (uint wethOut) {
        uint usdcBefore = IERC20(ctx.usdc).balanceOf(address(this));
        if (ctx.rover != address(0)) {
            uint targetWETH = convert(usdcIn, price, true);
            uint fromRover = IRover(ctx.rover).take(targetWETH);
            if (fromRover > 0) { uint usdcForRover = convert(fromRover, price, false);
                // Cap to available: price divergence can make usdcForRover > usdcIn
                usdcForRover = Math.min(usdcForRover, usdcIn);
                try IRover(ctx.rover).depositUSDC(usdcForRover, price) {}
                catch { /* tokens stay in Rover for next repack */ }

                wethOut = fromRover;
                usdcIn = usdcIn > usdcForRover ?
                         usdcIn - usdcForRover : 0;
            }
        } if (usdcIn > 0) wethOut += swapUSDCtoWETH(ctx, usdcIn, price);
        // Sweep USDC that arrived during this call but wasn't consumed
        uint usdcAfter = IERC20(ctx.usdc).balanceOf(address(this));
        if (usdcAfter > usdcBefore) {
            uint stranded = usdcAfter - usdcBefore;
            if (ctx.isAAVE) supplyAAVE(ctx.vault, ctx.usdc,
                         stranded, address(this), ctx.hub);
            // !isAAVE: USDC stays in contract, visible via get_deposits
        }
    }

    /// @notice Unified token sourcing via Rover → V3
    /// @param target Amount of output token needed
    /// @param input Available input token to swap
    /// @param price Current price for external swaps
    /// @param forUSD true = WETH→USDC, false = USDC→WETH
    function source(Types.AuxContext memory ctx,
        uint target, uint input, uint price,
        bool forUSD) external returns
        (uint got, uint used) {
        if (forUSD) { // USDC from WETH...
            if (target > 0 && input > 0) {
                uint selling = Math.min(convert(target,
                                    price, true), input);
                if (selling > 0) {
                    got = sourceExternalUSD(
                        ctx, selling, price);
                      used = selling;
                }
            }
        } else { // Want WETH from USDC...
            if (target > 0 && input > 0) {
                used = Math.min(convert(target,
                          price, false), input);

                if (used > 0)
                    got = sourceExternalWETH(
                            ctx, used, price);
            }
        }
    }

    function routeSwap(Types.AuxContext memory ctx,
        Types.RouteParams memory p) external returns
        (uint out, uint poolSupplied) { uint remainder;
        if (!isManipulated(getPrice(p.sqrtPriceX96,
                IVogueCore(ctx.core).token1isETH()), p.v4Price, 2)) {
            uint pooled = Math.min(p.amount, convert(p.pooled,
                            p.v4Price, p.token != address(0)));
            if (pooled > 0) {
                if (p.token != address(0)) {
                    if (ctx.isAAVE) supplyAAVE(ctx.vault, ctx.weth,
                                   pooled, address(this), ctx.hub);

                    else pooled = IERC4626(ctx.vault).convertToAssets(
                           IERC4626(ctx.vault).deposit(pooled, ctx.v4));

                    poolSupplied = pooled;
                }
                out = IVogueCore(ctx.core).swap(p.sqrtPriceX96,
                    p.recipient, p.zeroForOne, p.token, pooled);
            }
            remainder = p.amount - pooled;
        } else remainder = p.amount;
        if (remainder > 0) {
            // Derive token ordering from the actual V3 pool, not the V4 mock pool.
            // IVogueCore.token1isETH() reflects the V4 pool's layout; passing it to
            // isV3Manipulated for the V3 pool inverts getPrice() when layouts differ,
            // making spot appear ~4,000,000% off TWAP → isManipulated always true →
            // require(!true) → empty revert (Foundry annotates as "unrecognized selector").
            bool _v3token1isWETH = IUniswapV3Pool(ctx.v3Pool).token1() == ctx.weth;
            require(!isV3Manipulated(ctx.v3Pool,
                _v3token1isWETH, p.v3Price));

            if (p.token == address(0)) {
                remainder = IAux(address(this)).take(address(this),
                                           remainder, ctx.usdc, 0);
                if (remainder > 0) {
                    remainder = sourceExternalWETH(ctx,
                              remainder, p.v3Price);

                    if (ctx.nativeWETH) {
                        WETH9(payable(ctx.weth)).withdraw(remainder);
                        { (bool ok,) = p.recipient.call{
                                       value: remainder}("");
                        require(ok); }
                    } else {
                        IERC20(ctx.weth).transfer(
                            p.recipient, remainder);
                    } out += remainder;
                }
            } else { remainder = sourceExternalUSD(ctx,
                            remainder, p.v3Price);

                IERC20(ctx.usdc).transfer(
                     p.recipient, remainder);
                          out += remainder;
            }
        }
    }

    /// @notice Swap USDC→WETH via V3, capped at pool liquidity
    function swapUSDCtoWETH(Types.AuxContext memory ctx,
        uint amountIn, uint price) public returns (uint amountOut) {
        uint poolWETH = IERC20(ctx.weth).balanceOf(ctx.v3Pool);
        uint max = convert(poolWETH, price, false);
        if (amountIn > max) amountIn = max;
        if (amountIn > 0) {
            uint minOut = convert(amountIn, price, true) * 99500 / 100000; // TODO slippage?
            (bool ok, bytes memory ret) = ctx.v3Router.call(abi.encodeWithSelector(
                ISwapRouter.exactInput.selector, ISwapRouter.ExactInputParams(
                    abi.encodePacked(ctx.usdc, ctx.v3Fee, ctx.weth),
                    address(this), amountIn, minOut)));

            if (ok && ret.length >= 32) amountOut = abi.decode(ret, (uint));
        }
    }

    /// @notice Get available AAVE liquidity
    /// (min of aToken balance and reserve)
    function aaveAvailableV3(address aave,
        address asset) public view returns (uint) {
        address aToken = AAVEv3(aave).getReserveAToken(asset);
        uint balance = IERC20(aToken).balanceOf(address(this));
        uint reserve = IERC20(asset).balanceOf(aToken);
        return Math.min(balance, reserve);
    }

    function aaveAvailableV4(address spoke, address hub,
        address asset, address user) public returns (uint) {
        uint reserveId = AAVEv4(spoke).getReserveId(hub,
                             IHub(hub).getAssetId(asset));
        return AAVEv4(spoke).getUserSuppliedAssets(reserveId, user);
    }

    /// @notice Convert amount between
    // ETH (18 dec) & USD (6 dec) using price
    function convert(uint amount, uint price,
        bool toETH) public pure returns (uint) {
        return toETH ? FullMath.mulDiv(amount * 1e12, WAD, price)  // USD to ETH
                     : FullMath.mulDiv(amount, price, WAD) / 1e12; // ETH to USD
    }

    /// @notice Distribute proportional L2 basket tokens.
    /// @dev Called via DELEGATECALL — transfers from caller's balance.
    function distributeL2(address[] memory baskets,
        address to, uint burned, uint total)
        external returns (uint totalOut) {
        if (total == 0) return 0;
        for (uint i; i < baskets.length; ++i) {
            uint bal = IERC20(baskets[i]).balanceOf(
                                        address(this));
            if (bal == 0) continue;
            uint share = FullMath.mulDiv(burned, bal, total);
            if (share > 0) {
                IERC20(baskets[i]).transfer(to, share);
                totalOut += share;
            }
        }
    }

    /// @notice Yield-enhanced mint amount calculation.
    function calcMintYield(uint deposited, uint decimals,
        uint when, uint nextMonth, uint seeded,
        uint avgYield, bool isSeed) external pure
        returns (uint normalized, uint month) {
        normalized = decimals < 18 ? deposited
            * (10 ** (18 - decimals)) : deposited;
        month = isSeed ? nextMonth + 1 : nextMonth;
        if (when > month) month = when;
        uint yield = isSeed ? avgYield * 2 : avgYield;
        normalized += FullMath.mulDiv(normalized * yield,
                        month - (nextMonth - 1), WAD * 12);
    }

    /// @notice Compute USD/ETH split for QD redemption.
    /// @param total Total basket TVL (18-dec)
    /// @param pooledUSD CORE.POOLED_USD() in 18-dec (already *1e12)
    /// @param ethAvail _availableETH()
    /// @param vogueETH vogueETH state var
    /// @param price getTWAP(1800)
    /// @param amount requested redemption amount
    /// @return reserved clipped redemption amount
    /// @return usdPart amount to draw from stablecoin basket
    /// @return ethExcess free ETH above Vogue watermark
    function redeemSplit(uint total, uint pooledUSD,
        uint ethAvail, uint vogueETH, uint price, uint amount)
        external pure returns (uint reserved, uint usdPart, uint ethExcess) {
        uint usdAvailable = total > pooledUSD ? total - pooledUSD : 0;
        ethExcess = ethAvail > vogueETH ? ethAvail - vogueETH : 0;
        uint ethValue = FullMath.mulDiv(ethExcess, price, 1e18);
        reserved = Math.min(amount, usdAvailable + ethValue);
        usdPart = Math.min(reserved, usdAvailable);
    }
}
