// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

// Corrected IUiPoolDataProviderV3 interface for Aave v3.2.
//
// The aave-v3 npm package ships a v3.0/v3.1 struct that is missing the two
// fields added in v3.2. Using the package interface causes the Solidity ABI
// decoder to revert when decoding the return value of getReservesData().
//
// Correct struct confirmed from UiPoolDataProviderV3.sol source:
//   reserveData.deficit = uint128(pool.getReserveDeficit(...));
//   reserveData.virtualUnderlyingBalance = pool.getVirtualUnderlyingBalance(...);
// Both are appended after borrowableInIsolation. No virtualAccActive field exists.
//
// Usage: place in src/imports/ and import from there instead of aave-v3 package:
//   import {IUiPoolDataProviderV3} from "./imports/IUiPoolDataProviderV3.sol";
//   import {IPoolAddressesProvider} from "./imports/IUiPoolDataProviderV3.sol";

interface IPoolAddressesProvider {
    function getPool() external view returns (address);
    function getPriceOracle() external view returns (address);
    function getPoolDataProvider() external view returns (address);
}

interface IUiPoolDataProviderV3 {
    struct AggregatedReserveData {
        address underlyingAsset;
        string  name;
        string  symbol;
        uint256 decimals;
        uint256 baseLTVasCollateral;
        uint256 reserveLiquidationThreshold;
        uint256 reserveLiquidationBonus;
        uint256 reserveFactor;
        bool    usageAsCollateralEnabled;
        bool    borrowingEnabled;
        bool    isActive;
        bool    isFrozen;
        // v3 state
        uint128 liquidityIndex;
        uint128 variableBorrowIndex;
        uint128 liquidityRate;
        uint128 variableBorrowRate;
        uint40  lastUpdateTimestamp;
        address aTokenAddress;
        address variableDebtTokenAddress;
        address interestRateStrategyAddress;
        uint256 availableLiquidity;
        uint256 totalScaledVariableDebt;
        uint256 priceInMarketReferenceCurrency;
        address priceOracle;
        uint256 variableRateSlope1;
        uint256 variableRateSlope2;
        uint256 baseVariableBorrowRate;
        uint256 optimalUsageRatio;
        // v3 flags
        bool    isPaused;
        bool    isSiloedBorrowing;
        uint128 accruedToTreasury;
        uint128 unbacked;
        uint128 isolationModeTotalDebt;
        bool    flashLoanEnabled;
        uint256 debtCeiling;
        uint256 debtCeilingDecimals;
        uint256 borrowCap;
        uint256 supplyCap;
        bool    borrowableInIsolation;
        // v3.2 additions (confirmed from UiPoolDataProviderV3.sol source)
        uint128 virtualUnderlyingBalance;
        uint128 deficit;
    }

    struct UserReserveData {
        address underlyingAsset;
        uint256 scaledATokenBalance;
        bool    usageAsCollateralEnabledOnUser;
        uint256 scaledVariableDebt;
    }

    struct BaseCurrencyInfo {
        uint256 marketReferenceCurrencyUnit;
        int256  marketReferenceCurrencyPriceInUsd;
        int256  networkBaseTokenPriceInUsd;
        uint8   networkBaseTokenPriceDecimals;
    }

    function getReservesData(IPoolAddressesProvider provider)
        external view
        returns (AggregatedReserveData[] memory, BaseCurrencyInfo memory);

    function getUserReservesData(IPoolAddressesProvider provider, address user)
        external view
        returns (UserReserveData[] memory, uint8);
}
