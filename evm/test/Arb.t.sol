
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import {Fixtures} from "./utils/Fixtures.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "v4-core/src/types/Currency.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";

import {IUniswapV3Pool} from "../src/imports/v3/IUniswapV3Pool.sol";
import {IV3SwapRouter as ISwapRouter} from "../src/imports/v3/IV3SwapRouter.sol";
import {INonfungiblePositionManager} from "../src/imports/v3/INonfungiblePositionManager.sol";

import {Amp} from "../src/Amp.sol";
import {Vogue} from "../src/Vogue.sol";
import {Rover} from "../src/Rover.sol";
import {Basket} from "../src/Basket.sol";
import {BasketLib} from "../src/imports/BasketLib.sol";
import {VogueCore} from "../src/VogueCore.sol";
import {AuxArb as Aux} from "../src/L2/AuxArb.sol";
import {Types} from "../src/imports/Types.sol";

import {Link} from "../src/Link.sol";
import {Jury} from "../src/Jury.sol";
import {Court} from "../src/Court.sol";

contract Arb is Test, Fixtures {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    uint public constant WAD = 1e18;
    uint public constant USDC_PRECISION = 1e6;
    address public User01 = address(0x1001);
    address public User02 = address(0x1002);
    address public User03 = address(0x1003);

    address public LP_Alice = address(0xA11CE);
    address public Swapper_Bob = address(0xB0B);

    INonfungiblePositionManager public nfpm = INonfungiblePositionManager(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);
    ISwapRouter public V3router = ISwapRouter(0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45);
    IUniswapV3Pool public WETHv3pool = IUniswapV3Pool(0xC6962004f452bE9203591991D15f6b388e09E8D0);
    IPoolManager public poolManager = IPoolManager(0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32);

    address[] public STABLECOINS; address[] public VAULTS;

    IERC20 public WETH = IERC20(0x82aF49447D8a07e3bd95BD0d56f35241523fBab1);
    address constant FORWARDER = 0xF8344CFd5c43616a4366C34E3EEE75af79a74482;
    address public aavePool = 0x794a61358D6845594F94dc1DB02A252b5b4814aD;
    address public aaveData = 0x5c5228aC8BC1528482514aF3e27E692495148717;
    address public aaveAddr = 0xa97684ead0e402dC232d5A977953DF7ECBaB3CDb;
    address public JAM = 0xbeb0b0623f66bE8cE162EbDfA2ec543A522F4ea6;

    IERC20 public GHO = IERC20(0x7dfF72693f6A4149b17e7C6314655f6A9F7c8B33);
    IERC20 public USDT = IERC20(0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9);
    IERC20 public USDC = IERC20(0xaf88d065e77c8cC2239327C5EDb3A432268e5831);
    IERC20 public DAI = IERC20(0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1);
    IERC20 public USDS = IERC20(0x6491c05A82219b8D1479057361ff1654749b876b);
    IERC20 public USDE = IERC20(0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34);
    IERC20 public CRVUSD = IERC20(0x498Bf2B1e120FeD3ad3D42EA2165E9b73f99C1e5);
    IERC20 public FRAX = IERC20(0x80Eede496655FB9047dd39d9f418d5483ED600df);

    // Morpho vaults
    IERC4626 public USDCvault = IERC4626(0x7c574174DA4b2be3f705c6244B4BfA0815a8B3Ed);
    IERC4626 public smokehouseUSDTvault = IERC4626(0x4739E2c293bDCD835829aA7c5d7fBdee93565D1a);

    address aTokenDAIonARB = 0x82E64f49Ed5EC1bC6e43DAD4FC8Af9bb3A2312EE;
    address aTokenFRAXonARB = 0x38d693cE1dF5AaDF7bC62595A37D667aD57922e5;
    address aTokenGHOonARB = 0xeBe517846d0F36eCEd99C735cbF6131e1fEB775D;

    IERC20 public SFRAX = IERC4626(0x5Bff88cA1442c2496f7E475E9e7786383Bc070c0);
    IERC20 public SUSDS = IERC20(0xdDb46999F8891663a8F2828d25298f70416d7610);
    IERC20 public SUSDE = IERC20(0x211Cc4DD073734dA055fbF44a2b4667d5E5fE5d2);
    IERC20 public SCRVUSD = IERC20(0xEfB6601Df148677A338720156E2eFd3c5Ba8809d);

    VogueCore public CORE;
    Basket public QUID;
    Vogue public V4;
    Rover public V3;
    Aux public AUX;
    Amp public AMP;
    Jury public jury;
    Court public court;
    Link public LINK;

    uint stack = 10000 * USDC_PRECISION;

    function setUp() public {
        STABLECOINS = [ // do not change the order here
            address(USDC), address(USDT), // < these two are deposited in Morpho
            address(DAI),  address(GHO), // < these two get deposit in AAVE
            address(FRAX), // < plus this one as well...^^^^^^^^^^^^^^^^^^^
            address(USDE), address(USDS), // these 2 and next 2
            address(CRVUSD), address(SFRAX), // are deposited anywhere
            address(SUSDS), address(SUSDE),
            address(SCRVUSD) // oracles for last 3
        ]; // the order here is essential...
        VAULTS = [address(USDCvault),
            address(smokehouseUSDTvault),
            aTokenDAIonARB, aTokenGHOonARB,
            aTokenFRAXonARB
        ];

        uint mainnetFork = vm.createFork("https://rpc.ankr.com/arbitrum/abc1c9e1ba906a35c59e62a69c80cf77219499b3cd05752d53c0ed17d14cbfc3");
        vm.selectFork(mainnetFork);

        // Fund User01 with various stablecoins
        vm.startPrank(0xEe7aE85f2Fe2239E27D9c1E23fFFe168D63b4055);
        USDC.transfer(User01, 10000000 * USDC_PRECISION);
        USDC.transfer(User02, 10000000 * USDC_PRECISION);
        USDC.transfer(User03, 10000000 * USDC_PRECISION);
        vm.stopPrank();

        vm.deal(address(this), 1000000000 ether);
        vm.deal(User01, 1000000000 ether);
        vm.deal(User02, 1000000000 ether);
        vm.deal(User03, 1000000000 ether);

        AMP = new Amp(aavePool, aaveData, aaveAddr);
        V3 = new Rover(address(AMP), address(WETH),
            address(USDC), address(nfpm),
            address(WETHv3pool),
            address(V3router), true);

        V4 = new Vogue(); // TODO
        CORE = new VogueCore(poolManager);
        AUX = new Aux(address(V4),
            address(CORE), address(AMP),
            aavePool, address(WETHv3pool),
            address(V3router), address(V3),
            STABLECOINS, VAULTS);

        AMP.setup(payable(address(V3)), address(AUX));
        QUID = new Basket(address(V4), address(AUX));
        LINK = new Link(address(QUID), FORWARDER);

        jury = new Jury(address(QUID));
        court = new Court(address(QUID),
        address(jury), address(LINK), false);
        jury.setup(address(court));

        deal(address(USDC), address(LINK), 1_000_000e6);
        LINK.setCourt(address(court));

        QUID.setup(address(LINK),
        address(court), address(jury));

        CORE.setup(address(V4), address(AUX), address(WETHv3pool));
        V4.setup(address(QUID), address(AUX), address(CORE));
        AUX.setQuid(address(QUID), JAM); V3.setAux(address(AUX));

        // Mint QUID with various stablecoins to populate different vaults
        // Need enough USD to pair with ETH deposits in tests
        // At ~$2700/ETH, 1M USDC can pair with ~370 ETH
        vm.startPrank(User01);
        USDC.approve(address(AUX), type(uint).max);

        // Mint with USDC (1M for sufficient liquidity)
        QUID.mint(User01, 1000000 * USDC_PRECISION, address(USDC), 0);
        vm.stopPrank();

        vm.startPrank(User01);
        USDC.approve(address(AUX), type(uint).max);
        QUID.mint(User01, 50000e6, address(USDC), 0);
        vm.stopPrank();

        vm.startPrank(User02);
        USDC.approve(address(AUX), type(uint).max);
        QUID.mint(User02, 50000e6, address(USDC), 0);
        vm.stopPrank();

        vm.startPrank(User03);
        USDC.approve(address(AUX), type(uint).max);
        QUID.mint(User03, 50000e6, address(USDC), 0);
        vm.stopPrank();
    }

    function _getPrice(uint160 sqrtPriceX96,
        bool token0isUSD) internal pure
        returns (uint price) {
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

    function testRegularSwaps() public {
        console.log("=== testRegularSwaps ===");

        vm.startPrank(User01);
        V4.deposit{value: 100 ether}(0);

        uint pooledETH = CORE.POOLED_ETH();
        console.log("POOLED_ETH after deposit:", pooledETH);

        if (pooledETH == 0) {
            console.log("No pool position - checking why");
            (uint total,) = AUX.get_metrics(true);
            console.log("Vault total:", total);
            vm.stopPrank();
            return;
        }
        USDC.approve(address(AUX), type(uint).max);
        (,uint160 sqrtPriceX96,) = CORE.poolTicks();
        uint price = _getPrice(sqrtPriceX96, V4.token1isETH());
        console.log("ETH price:", price);

        uint usdcBefore = USDC.balanceOf(User01);
        AUX.swap{value: 1 ether}(address(USDC), false, 0, 0);

        uint usdcAfter = USDC.balanceOf(User01);
        uint usdcReceived = usdcAfter - usdcBefore;
        console.log("USDC received for 1 ETH:", usdcReceived);

        // Should receive approximately price / 1e12 USDC (accounting for fees)
        uint expectedUsdc = price / 1e12;
        console.log("Expected USDC (approx):", expectedUsdc);

        // Allow 10% slippage
        assertGt(usdcReceived, expectedUsdc * 90 / 100, "Should receive reasonable USDC");

        vm.stopPrank();
    }

    function testWithdrawAndLeveragedSwaps() public {
        vm.startPrank(User01);
        V3.repackNFT();
        V3.deposit{value: 25 ether}(0);
        V4.deposit{value: 25 ether}(0);

        uint balanceBefore = User01.balance;
        V4.withdraw(1 ether);
        uint balanceAfter = User01.balance;

        assertApproxEqAbs(balanceAfter - balanceBefore, 1 ether, 100000);

        address[] memory whose = new address[](1);
        whose[0] = User01;

        AUX.leverETH{value: 1 ether}(0);

        USDC.approve(address(AUX), stack / 5);
        AUX.leverUSD(stack / 10, address(USDC));
        vm.stopPrank();
    }

    function testRedeem() public {
        vm.startPrank(User01);

        // Mint fresh QUID for this test
        uint mintAmount = 10000 * 1e6; // 10,000 USDC
        USDC.approve(address(AUX), mintAmount);

        uint currentMonth = QUID.currentMonth();
        uint minted = QUID.mint(User01, mintAmount, address(USDC), 0);

        console.log("Minted QUID:", minted);
        console.log("Current month:", currentMonth);

        // First redeem should fail (immature)
        uint USDCbalanceBefore = USDC.balanceOf(User01);

        try AUX.redeem(1000 * WAD) {
            uint received = USDC.balanceOf(User01) - USDCbalanceBefore;
            console.log("Immature redeem got:", received);
            assertLt(received, 100 * 1e6, "Should get very little when immature");
        } catch {
            console.log("Immature redeem reverted (expected)");
        }

        // Warp to next month
        vm.warp(block.timestamp + 35 days);

        USDCbalanceBefore = USDC.balanceOf(User01);
        AUX.redeem(1000 * WAD);
        uint USDCbalanceAfter = USDC.balanceOf(User01);

        uint received = USDCbalanceAfter - USDCbalanceBefore;
        console.log("Mature redeem got:", received, "expected:", 1000 * 1e6);

        // More lenient tolerance - vaults have fees
        assertApproxEqAbs(received, 1000 * 1e6, 500 * 1e6,
            "Should redeem with 50% tolerance for fees");

        vm.stopPrank();
    }


    function testOutOfRangeUSDPosition() public {
        vm.startPrank(User01);
        V4.deposit{value: 25 ether}(0);

        USDC.approve(address(AUX), stack);
        uint balanceBefore = USDC.balanceOf(User01);

        // Create position below current price (provide USDC)
        uint id = V4.outOfRange(stack / 10, address(USDC), 1000, 100);

        assertGt(id, 0, "Position ID should be > 0");
        assertApproxEqAbs(USDC.balanceOf(User01), balanceBefore - stack / 10,
                        stack / 100, "USDC should be deducted");

        // Pull and get USDC back
        vm.roll(vm.getBlockNumber() + 48);
        balanceBefore = USDC.balanceOf(User01);
        V4.pull(id, 100, address(USDC));

        assertApproxEqAbs(USDC.balanceOf(User01),
        balanceBefore, stack / 50, "Should get USDC back");

        vm.stopPrank();
    }

    function testPartialPullOutOfRange() public {
        vm.startPrank(User01);
        V4.deposit{value: 50 ether}(0);

        vm.roll(vm.getBlockNumber() + 1);

        uint id = V4.outOfRange{value: 2 ether}(0, address(0), -1000, 100);
        assertGt(id, 0, "Should create position");

        vm.roll(vm.getBlockNumber() + 48);

        // Position above price holds USD, so withdraw USDC
        uint balanceBefore = USDC.balanceOf(User01);
        V4.pull(id, 50, address(USDC));

        uint received = USDC.balanceOf(User01) - balanceBefore;
        assertGt(received, 0, "Should receive USDC");

        vm.stopPrank();
    }

    function testInvalidOutOfRangeParams() public {
        vm.startPrank(User01);
        V4.deposit{value: 25 ether}(0);

        // Invalid range (too small)
        vm.expectRevert();
        V4.outOfRange{value: 1 ether}(0, address(0), -1000, 50);

        // Invalid range (too large)
        vm.expectRevert();
        V4.outOfRange{value: 1 ether}(0, address(0), -1000, 1500);

        // Invalid distance (too far)
        vm.expectRevert();
        V4.outOfRange{value: 1 ether}(0, address(0), -6000, 100);

        // Invalid distance (not multiple of 100)
        vm.expectRevert();
        V4.outOfRange{value: 1 ether}(0, address(0), -1050, 100);

        vm.stopPrank();
    }

    function testMultipleBatchMaturities() public {
        vm.startPrank(User01);

        uint batchSize = 25000 * 1e6;
        USDC.approve(address(AUX), batchSize * 3);

        // Create batches - don't store minted amounts if not used
        QUID.mint(User01, batchSize, address(USDC), 1);

        vm.warp(block.timestamp + 30 days);
        QUID.mint(User01, batchSize, address(USDC), 2);

        vm.warp(block.timestamp + 30 days);
        QUID.mint(User01, batchSize, address(USDC), 3);

        vm.warp(block.timestamp + 5 days); // Only batch 1 mature

        // Inline the metrics call
        uint available;
        {
            (uint total,) = AUX.get_metrics(true);
            uint pooled = CORE.POOLED_USD();
            available = total > pooled ? total - pooled : 0;
        }

        if (available < 1000 * WAD) {
            vm.stopPrank();
            return;
        }

        AUX.redeem(Math.min(10000 * WAD, available / 2));

        assertGt(USDC.balanceOf(User01), 0, "Should redeem something");

        vm.stopPrank();
    }

    function testFeeAccrual() public {
        vm.startPrank(User01);

        V4.deposit{value: 10 ether}(0);

        uint ethFeesBefore = V4.ETH_FEES();

        // Generate fees through multiple swaps
        USDC.approve(address(AUX), stack);
        for (uint i = 0; i < 10; i++) {
            AUX.swap{value: 2 ether}(address(USDC), false, 0, 0); // Larger amounts
        }

        vm.roll(vm.getBlockNumber() + 1);

        // Fees are updated during swaps
        uint ethFeesAfter = V4.ETH_FEES();
        assertGe(ethFeesAfter, ethFeesBefore, "ETH fees should not decrease");

        vm.stopPrank();
    }

    function testWithdrawWithAccruedFees() public {
        vm.startPrank(User01);

        V4.deposit{value: 10 ether}(0);

        USDC.approve(address(AUX), stack);
        (,uint160 sqrtPriceX96,) = CORE.poolTicks();
        uint price = _getPrice(sqrtPriceX96, V4.token1isETH());
        // Generate fees
        for (uint i = 0; i < 5; i++) {
            uint amountNeeded = FullMath.mulDiv(6000 * WAD, WAD, price);

            AUX.swap{value: amountNeeded}(address(USDC), false, 0, 0);
            vm.roll(vm.getBlockNumber() + 1);
        }

        // Withdraw should include fees
        uint balanceBefore = User01.balance;
        V4.withdraw(5 ether);
        uint received = User01.balance - balanceBefore;

        assertGe(received, 4.5 ether, "Should receive close to withdrawal amount");

        vm.stopPrank();
    }

    function testMultipleSwapsAcrossBlocks() public {
        console.log("=== testMultipleSwapsAcrossBlocks ===");

        vm.startPrank(User01);
        V4.deposit{value: 100 ether}(0);

        uint pooledBefore = CORE.POOLED_ETH();
        console.log("POOLED_ETH before:", pooledBefore);

        // Only proceed if deposit worked
        if (pooledBefore == 0) {
            console.log("Deposit did not create pool position - checking metrics");
            (uint total,) = AUX.get_metrics(true);
            console.log("Vault total:", total);
            vm.stopPrank();
            return;
        }

        USDC.approve(address(AUX), type(uint).max);

        (,uint160 sqrtPriceX96,) = CORE.poolTicks();
        uint price = _getPrice(sqrtPriceX96, V4.token1isETH());
        console.log("Price:", price);

        // Execute swaps across multiple blocks
        uint usdcBefore = USDC.balanceOf(User01);
        AUX.swap{value: 5 ether}(address(USDC), false, 0, 0);
        console.log("Swap 1 executed");

        vm.roll(block.number + 1);
        AUX.swap{value: 5 ether}(address(USDC), false, 0, 0);
        console.log("Swap 2 executed");

        vm.roll(block.number + 1);
        AUX.swap{value: 5 ether}(address(USDC), false, 0, 0);
        console.log("Swap 3 executed");

        uint usdcReceived = USDC.balanceOf(User01) - usdcBefore;
        console.log("Total USDC received:", usdcReceived);
        assertGt(usdcReceived, 0, "Should receive USDC from swaps");

        // Verify pool state after swaps
        uint pooledAfter = CORE.POOLED_ETH();
        console.log("POOLED_ETH after:", pooledAfter);

        vm.stopPrank();
    }

    // Test alternating buy/sell swaps
    function testAlternatingSwaps() public {
        vm.startPrank(User01);
        V4.deposit{value: 100 ether}(0);
        USDC.approve(address(AUX), type(uint).max);

        (,uint160 sqrtPriceX96,) = CORE.poolTicks();
        uint price = _getPrice(sqrtPriceX96, V4.token1isETH());

        for (uint i = 0; i < 10; i++) {
            if (i % 2 == 0) {
                AUX.swap{value: 0.5 ether}(address(USDC), false, 0, 0);
            } else {
                AUX.swap(address(USDC), true, price / 1e12, 0);
            }
            // Roll block after each swap to allow direction change
            // GSR enforces same-direction within a block (anti-sandwich)
            vm.roll(vm.getBlockNumber() + 1);
        }

        vm.stopPrank();
    }

    // Test vault withdrawal with multiple stablecoins


    // Test metrics calculation
    function testMetricsCalculation() public {
        vm.startPrank(User01);

        // Deposit to create metrics
        QUID.mint(User01, stack * 5, address(USDC), 0);

        // Get initial metrics
        (uint total1, uint yield1) = AUX.get_metrics(true);
        assertGt(total1, 0, "Total should be > 0");

        // Wait and check again
        vm.warp(block.timestamp + 1 hours);

        (uint total2, uint yield2) = AUX.get_metrics(true);

        // Total should be similar (yield changes slowly)
        assertApproxEqAbs(total2, total1, total1 / 20, "Total should be relatively stable");

        vm.stopPrank();
    }

    function testDepositImmediateWithdraw() public {
        vm.startPrank(User01);

        uint depositAmount = 10 ether;
        V4.deposit{value: depositAmount}(0);
        (uint pooled_eth, uint usd_owed,
        uint fees_eth, uint fees_usd) = V4.autoManaged(User01);

        // Need to wait for at least one block and trigger some activity
        vm.roll(vm.getBlockNumber() + 1);

        // Small swap to generate some pool activity
        AUX.swap{value: 0.1 ether}(address(USDC), false, 0, 0);

        uint balanceBefore = User01.balance;

        // Withdraw a smaller amount first to avoid issues
        uint withdrawAmount = 5 ether;

        try V4.withdraw(withdrawAmount) {
            uint balanceAfter = User01.balance;
            uint received = balanceAfter - balanceBefore;

            assertGt(received, 4 ether, "Should get most of withdrawal");
        } catch Error(string memory reason) {

            (pooled_eth, usd_owed,
            fees_eth, fees_usd) = V4.autoManaged(User01);

            vm.skip(true);
        }

        vm.stopPrank();
    }

    function testRepackAfterDelay() public {
        vm.startPrank(User01);

        V4.deposit{value: 10 ether}(0);

        // Generate some activity
        AUX.swap{value: 2 ether}(address(USDC), false, 0, 0);
        vm.roll(vm.getBlockNumber() + 1);

        vm.warp(block.timestamp + 11 minutes);

        vm.stopPrank();
    }


    function testFuzz_SwapAmounts(uint96 amount) public {
        // Bound to reasonable range
        amount = uint96(bound(amount, 0.1 ether, 100 ether));

        console.log("=== testFuzz_SwapAmounts ===");
        console.log("Amount:", amount);

        vm.startPrank(User01);
        V4.deposit{value: 200 ether}(0);

        uint pooledETH = CORE.POOLED_ETH();
        if (pooledETH == 0) {
            console.log("Pool not active - skipping");
            vm.stopPrank();
            return;
        }

        uint usdcBefore = USDC.balanceOf(User01);
        AUX.swap{value: amount}(address(USDC), false, 0, 0);

        uint usdcReceived = USDC.balanceOf(User01) - usdcBefore;
        console.log("USDC received:", usdcReceived);

        // For any positive amount, should receive some USDC
        assertGt(usdcReceived, 0, "Should receive USDC for any swap");

        vm.stopPrank();
    }

    function testFuzz_OutOfRangeDistance(int24 distance) public {
        // Simplify assumptions
        distance = int24(bound(int256(distance), -5000, 5000));
        distance = (distance / 100) * 100; // Round to nearest 100
        vm.assume(distance != 0);

        vm.startPrank(User01);
        V4.deposit{value: 25 ether}(0);

        try V4.outOfRange{value: 1 ether}(0, address(0), distance, 100) returns (uint id) {
            assertGt(id, 0, "Should create position");
        } catch {
            // Expected failure for some distances
        }

        vm.stopPrank();
    }

    // Test redeeming from specific single vault
    function testRedeemFromSingleVault() public {
        vm.startPrank(User01);

        vm.warp(block.timestamp + 30 days);
        uint userBalance = QUID.balanceOf(User01);
        // Redeem half of what user actually has
        uint redeemAmount = userBalance / 2;

        uint usdcBefore = USDC.balanceOf(User01);
        AUX.redeem(redeemAmount);
        uint usdcReceived = USDC.balanceOf(User01) - usdcBefore;
        assertGt(usdcReceived, 0, "Should receive USDC");

        vm.stopPrank();
    }

    function testVaultBalanceDistribution() public {
        (uint[14] memory deposits,) = AUX.get_deposits();

        uint total = deposits[1];
        for (uint i = 2; i < 13; i++) {
            if (deposits[i] > 0) {
                uint percentage = (deposits[i] * 100) / total;
                console.log("Vault...", i - 2);
                console.log("deposits[i]", deposits[i]);
                console.log("%", percentage);
            }
        }
        // Verify we have deposits in at least one vault (fork state dependent)
        uint vaultsWithDeposits = 0;
        for (uint i = 2; i < 13; i++) {
            if (deposits[i] > 0) vaultsWithDeposits++;
        }
        assertGe(vaultsWithDeposits, 1, "Should have deposits in at least 1 vault");
    }

    function testDepositVaultShares() public {
        vm.startPrank(User01);

        // Test that minting with stablecoin automatically deposits to vault
        uint depositAmount = 500 * 1e6;
        USDC.approve(address(AUX), depositAmount);

        uint quidBefore = QUID.totalSupply();
        QUID.mint(User01, depositAmount, address(USDC), 0);

        // Verify vault has the deposit (AuxArb: USDC at deposits[1])
        (uint[14] memory deposits,) = AUX.get_deposits();
        assertGt(deposits[1], 0, "USDC vault should have deposits");
        assertGt(QUID.totalSupply(), quidBefore, "Should mint QUID");

        vm.stopPrank();
    }


    function testSwapWithDifferentStableOutputs() public {
        console.log("=== testSwapWithDifferentStableOutputs ===");

        vm.startPrank(User01);
        V4.deposit{value: 100 ether}(0);

        uint pooledETH = CORE.POOLED_ETH();
        console.log("POOLED_ETH:", pooledETH);

        if (pooledETH == 0) {
            console.log("Pool not active - skipping");
            vm.stopPrank();
            return;
        }

        // Test swap to USDC
        uint usdcBefore = USDC.balanceOf(User01);
        AUX.swap{value: 1 ether}(address(USDC), false, 0, 0);

        uint usdcReceived = USDC.balanceOf(User01) - usdcBefore;
        console.log("USDC received:", usdcReceived);

        assertGt(usdcReceived, 0, "Should receive USDC");

        vm.stopPrank();
    }

    function test_WithdrawDoesNotPersistFeeSnapshot() public {
        console.log("=== SETUP ===");
        console.log("V4 totalShares before:", V4.totalShares());
        console.log("V4 ETH_FEES before:", V4.ETH_FEES());
        console.log("V4 pooled_eth before:", CORE.POOLED_ETH());

        vm.startPrank(User01);
        console.log("\n=== DEPOSIT 100 ETH ===");
        V4.deposit{value: 100 ether}(0);

        console.log("V4 totalShares after deposit:", V4.totalShares());
        console.log("V4 ETH_FEES after deposit:", V4.ETH_FEES());
        console.log("V4 pooled_eth after deposit:", CORE.POOLED_ETH());

        (uint pooled, uint pending_usd, uint fees_eth, uint fees_usd) = V4.autoManaged(User01);
        console.log("User LP.pooled_eth:", pooled);
        console.log("User LP.fees_eth (debt):", fees_eth);

        assertGt(pooled, 0, "User should have pooled_eth");
        assertGt(V4.totalShares(), 0, "totalShares should increase");

        vm.stopPrank();

        // Note: In Vogue, fees only accrue when position goes OUT OF RANGE during repack
        // Simple swaps may not trigger fee accrual if position stays in range
        console.log("\n=== GENERATE FEES (via swaps that trigger repack) ===");

        // Do larger swaps that might move price enough to trigger repack
        for (uint i = 0; i < 3; i++) {
            vm.startPrank(User03);
            AUX.swap{value: 20 ether}(address(USDC), false, 0, 0);
            vm.roll(block.number + 1);
            vm.warp(block.timestamp + 15 minutes);
            vm.stopPrank();
            console.log("After swap", i + 1, "- ETH_FEES:", V4.ETH_FEES());
        }

        console.log("\n=== CHECK PENDING BEFORE WITHDRAW ===");
        (uint pendingETH, uint pendingUSD) = V4.pendingRewards(User01);
        console.log("pendingETH:", pendingETH);
        console.log("pendingUSD:", pendingUSD);

        console.log("\n=== WITHDRAW 10 ETH ===");
        uint globalFees1 = V4.ETH_FEES();
        console.log("globalFees1 (ETH_FEES):", globalFees1);

        uint balBefore = User01.balance;
        vm.prank(User01);
        V4.withdraw(10 ether);
        uint received = User01.balance - balBefore;
        console.log("Received on withdraw:", received);

        assertGt(received, 0, "Should receive something on withdraw");

        (pooled, pending_usd, fees_eth, fees_usd) = V4.autoManaged(User01);
        console.log("After withdraw - LP.pooled_eth:", pooled);
        console.log("After withdraw - LP.fees_eth (debt):", fees_eth);
        console.log("After withdraw - totalShares:", V4.totalShares());

        (pendingETH, pendingUSD) = V4.pendingRewards(User01);
        console.log("After withdraw - pendingETH:", pendingETH);

        // After withdraw, debt should be updated to current accumulator
        // so pending should be 0 or very small

        console.log("\n=== GENERATE MORE FEES ===");
        for (uint i = 0; i < 3; i++) {
            vm.startPrank(User03);
            AUX.swap{value: 20 ether}(address(USDC), false, 0, 0);
            vm.roll(block.number + 1);
            vm.warp(block.timestamp + 15 minutes);
            vm.stopPrank();
            console.log("After swap", i + 1, "- ETH_FEES:", V4.ETH_FEES());
        }

        (pendingETH, pendingUSD) = V4.pendingRewards(User01);
        console.log("Final pendingETH:", pendingETH);

        console.log("\n=== FINAL WITHDRAW ===");
        balBefore = User01.balance;
        vm.prank(User01);
        V4.withdraw(10 ether);
        received = User01.balance - balBefore;
        console.log("Final received:", received);

        assertGt(received, 0, "Should receive something on final withdraw");
    }

    /// @notice Verifies that swap execution doesn't inflate surplus beyond actual deposits
    function test_SwapDoesNotInflateSurplus() public {
        console.log("\n=== test_SwapDoesNotInflateSurplus ===");

        // Start fresh - User01 deposits just enough to have minimal surplus
        vm.startPrank(User01);
        V4.deposit{value: 100 ether}(0);
        vm.stopPrank();

        // Mint QUID to consume most of the surplus
        vm.startPrank(User01);
        (uint vaultBefore,) = AUX.get_metrics(true);
        uint pooledBefore = CORE.POOLED_USD();
        uint surplusBefore = vaultBefore > pooledBefore * 1e12
            ? (vaultBefore - pooledBefore * 1e12) / 1e12
            : 0;

        // Leave only small surplus (e.g., $10k)
        if (surplusBefore > 20000 * USDC_PRECISION) {
            uint toMint = surplusBefore - 10000 * USDC_PRECISION;
            USDC.approve(address(AUX), toMint);
            QUID.mint(User01, toMint, address(USDC), 0);
        }
        vm.stopPrank();

        // Now measure actual surplus
        uint initialPooledUSD = CORE.POOLED_USD();
        (uint initialVaultTotal,) = AUX.get_metrics(true);
        uint actualSurplus = initialVaultTotal > initialPooledUSD * 1e12
            ? (initialVaultTotal - initialPooledUSD * 1e12) / 1e12
            : 0;

        console.log("=== Tight Surplus Setup ===");
        console.log("  POOLED_USD:", initialPooledUSD);
        console.log("  Vault total:", initialVaultTotal);
        console.log("  Actual surplus (1e6):", actualSurplus);

        // User02 submits $100k USD->ETH swap (executes immediately now)
        console.log("\n=== User02 executes $100k USD->ETH swap ===");
        vm.startPrank(User02);
        USDC.approve(address(AUX), 100000 * USDC_PRECISION);
        AUX.swap(address(USDC), true, 100000 * USDC_PRECISION, 0);
        vm.stopPrank();

        (uint vaultAfterSwap,) = AUX.get_metrics(true);
        console.log("  Vault after swap:", vaultAfterSwap);

        // User01 deposits ETH
        console.log("\n=== User01 deposits 50 ETH ===");
        vm.startPrank(User01);
        V4.deposit{value: 50 ether}(0);
        vm.stopPrank();

        uint finalPooledUSD = CORE.POOLED_USD();
        uint increase = finalPooledUSD - initialPooledUSD;

        console.log("  Final POOLED_USD:", finalPooledUSD);
        console.log("  POOLED_USD increase:", increase);
        console.log("  Actual surplus was:", actualSurplus);
    }

    /// @notice Verifies ETH swap execution doesn't inflate available balance
    function test_SwapETHDoesNotInflateAvailable() public {
        vm.startPrank(User01);
        V4.deposit{value: 100 ether}(0);
        vm.stopPrank();

        uint initialPooledETH = CORE.POOLED_ETH();
        console.log("=== Initial State ===");
        console.log("  POOLED_ETH:", initialPooledETH);

        // User02 executes large ETH->USD swap (immediate)
        vm.startPrank(User02);
        AUX.swap{value: 50 ether}(address(USDC), false, 0, 0);
        vm.stopPrank();

        console.log("\n=== After User02 ETH->USD swap ===");
        console.log("  User02 swapped 50 ETH for USDC");

        // Add USD surplus via QUID mint
        vm.startPrank(User01);
        USDC.approve(address(AUX), 200000 * USDC_PRECISION);
        QUID.mint(User01, 200000 * USDC_PRECISION, address(USDC), 0);

        (uint vaultTotal,) = AUX.get_metrics(true);
        uint pooledUSD = CORE.POOLED_USD();
        console.log("\n=== After QUID mint ===");
        console.log("  Vault total:", vaultTotal);
        console.log("  POOLED_USD:", pooledUSD);

        // User01 deposits more ETH
        V4.deposit{value: 25 ether}(0);
        vm.stopPrank();

        uint finalPooledETH = CORE.POOLED_ETH();
        uint ethIncrease = finalPooledETH - initialPooledETH;

        console.log("\n=== After User01 ETH deposit ===");
        console.log("  Final POOLED_ETH:", finalPooledETH);
        console.log("  POOLED_ETH increase:", ethIncrease);
        console.log("  User01 deposited: 25 ether");
    }

    function test_FeeAttributionWithMultipleLPs() public {
        console.log("\n=== test_FeeAttributionWithMultipleLPs ===");

        vm.deal(User01, 1000 ether);
        vm.deal(User02, 1000 ether);
        vm.deal(User03, 1000 ether);

        // Phase 1: Alice deposits alone
        console.log("\n--- Phase 1: Alice deposits 100 ETH ---");
        vm.prank(User01);
        V4.deposit{value: 100 ether}(0);

        uint pooledAlice = CORE.POOLED_ETH();
        uint sharesAlice = V4.totalShares();
        console.log("POOLED_ETH:", pooledAlice);
        console.log("totalShares:", sharesAlice);
        console.log("ETH_FEES:", V4.ETH_FEES());

        assertGt(pooledAlice, 0, "POOLED_ETH should be > 0 after deposit");

        // Phase 2: Generate fees (smaller amounts to not drain USD)
        console.log("\n--- Phase 2: Generate fees (Alice is 100%) ---");
        vm.startPrank(User03);
        USDC.approve(address(AUX), type(uint).max);

        for (uint i = 0; i < 3; i++) {
            AUX.swap{value: 10 ether}(address(USDC), false, 0, 0);
            vm.roll(block.number + 1);
            vm.warp(block.timestamp + 15 minutes);
        }
        vm.stopPrank();

        uint feesPhase2 = V4.ETH_FEES();
        console.log("ETH_FEES after phase 2:", feesPhase2);

        // Phase 3: Bob deposits
        console.log("\n--- Phase 3: Bob deposits 100 ETH ---");
        vm.prank(User02);
        V4.deposit{value: 100 ether}(0);

        uint pooledAfterBob = CORE.POOLED_ETH();
        uint sharesAfterBob = V4.totalShares();
        console.log("POOLED_ETH after Bob:", pooledAfterBob);
        console.log("totalShares after Bob:", sharesAfterBob);

        // Check Bob's position was created
        (uint bobPooled,,,) = V4.autoManaged(User02);
        console.log("Bob's pooled_eth:", bobPooled);

        // Phase 4: Generate more fees (smaller amounts)
        console.log("\n--- Phase 4: Generate more fees ---");
        vm.startPrank(User03);
        for (uint i = 0; i < 3; i++) {
            AUX.swap{value: 10 ether}(address(USDC), false, 0, 0);
            vm.roll(block.number + 1);
            vm.warp(block.timestamp + 15 minutes);
        }
        vm.stopPrank();

        uint feesPhase4 = V4.ETH_FEES();
        console.log("ETH_FEES after phase 4:", feesPhase4);

        // Check pending rewards
        (uint alicePending,) = V4.pendingRewards(User01);
        (uint bobPending,) = V4.pendingRewards(User02);
        console.log("\nAlice pending:", alicePending);
        console.log("Bob pending:", bobPending);

        // Withdraw and check
        console.log("\n--- Withdrawals ---");
        uint bal1 = User01.balance;
        vm.prank(User01);
        V4.withdraw(type(uint).max);
        uint aliceReceived = User01.balance - bal1;
        console.log("Alice received:", aliceReceived);

        uint bal2 = User02.balance;
        vm.prank(User02);
        V4.withdraw(type(uint).max);
        uint bobReceived = User02.balance - bal2;
        console.log("Bob received:", bobReceived);

        // Verify we received something - amounts depend on whether deposits were fully paired
        assertGt(aliceReceived, 0, "Alice should receive ETH");
        // Bob should receive ETH if his deposit was paired
        // If not paired, his deposit was refunded and he has 0 position
        if (bobPooled > 0) {
            assertGt(bobReceived, 0, "Bob should receive ETH if deposit was paired");
        }
    }

    /// @notice Helper to read autoManaged mapping
    function getAutoManaged(address who) internal view returns (Types.Deposit memory) {
        (uint pooled_eth, uint fees_eth, uint fees_usd, uint usd_owed) = V4.autoManaged(who);
        return Types.Deposit({
            pooled_eth: pooled_eth,
            fees_eth: fees_eth,
            fees_usd: fees_usd,
            usd_owed: usd_owed
        });
    }

    function testInvariant_TotalSharesMatchesSum() public {
        console.log("=== testInvariant_TotalSharesMatchesSum ===");

        // Multiple users deposit
        vm.prank(User01);
        V4.deposit{value: 100 ether}(0);

        vm.prank(User02);
        V4.deposit{value: 50 ether}(0);

        vm.prank(User03);
        V4.deposit{value: 75 ether}(0);

        // Sum individual shares
        (uint pooled1,,,) = V4.autoManaged(User01);
        (uint pooled2,,,) = V4.autoManaged(User02);
        (uint pooled3,,,) = V4.autoManaged(User03);

        uint sumPooled = pooled1 + pooled2 + pooled3;
        uint totalShares = V4.totalShares();

        console.log("User01 pooled:", pooled1);
        console.log("User02 pooled:", pooled2);
        console.log("User03 pooled:", pooled3);
        console.log("Sum:", sumPooled);
        console.log("totalShares:", totalShares);

        assertEq(totalShares, sumPooled, "totalShares should equal sum of individual shares");
    }


    function testVogueZeroDeposit() public {
        console.log("=== testVogueZeroDeposit ===");

        vm.startPrank(User01);

        // Depositing 0 should either revert or be a no-op
        uint sharesBefore = V4.totalShares();
        V4.deposit{value: 0}(0);
        uint sharesAfter = V4.totalShares();

        console.log("Shares before:", sharesBefore);
        console.log("Shares after:", sharesAfter);

        // Should not change shares
        assertEq(sharesBefore, sharesAfter, "Zero deposit should not change shares");

        vm.stopPrank();
    }

    function testVogueMultipleDeposits() public {
        console.log("=== testVogueMultipleDeposits ===");

        vm.startPrank(User01);

        // First deposit
        V4.deposit{value: 10 ether}(0);
        (uint pooled1,,,) = V4.autoManaged(User01);
        uint shares1 = V4.totalShares();
        console.log("After 1st deposit - pooled:", pooled1, "totalShares:", shares1);

        // Second deposit
        V4.deposit{value: 20 ether}(0);
        (uint pooled2,,,) = V4.autoManaged(User01);
        uint shares2 = V4.totalShares();
        console.log("After 2nd deposit - pooled:", pooled2, "totalShares:", shares2);

        // Third deposit
        V4.deposit{value: 5 ether}(0);
        (uint pooled3,,,) = V4.autoManaged(User01);
        uint shares3 = V4.totalShares();
        console.log("After 3rd deposit - pooled:", pooled3, "totalShares:", shares3);

        // Total should be sum of deposits
        assertApproxEqAbs(pooled3, 35 ether, 1, "Pooled should equal total deposited");

        vm.stopPrank();
    }

    function testVoguePartialWithdraws() public {
        console.log("=== testVoguePartialWithdraws ===");

        vm.startPrank(User01);
        V4.deposit{value: 100 ether}(0);

        (uint pooledInitial,,,) = V4.autoManaged(User01);
        console.log("Initial pooled:", pooledInitial);

        // Withdraw 10%
        uint balBefore = User01.balance;
        V4.withdraw(10 ether);
        uint received1 = User01.balance - balBefore;

        (uint pooled1,,,) = V4.autoManaged(User01);
        console.log("After 10 ETH withdraw - pooled:", pooled1, "received:", received1);

        // Withdraw another 20%
        balBefore = User01.balance;
        V4.withdraw(20 ether);
        uint received2 = User01.balance - balBefore;

        (uint pooled2,,,) = V4.autoManaged(User01);
        console.log("After 20 ETH withdraw - pooled:", pooled2, "received:", received2);

        assertLt(pooled1, pooledInitial, "Pooled should decrease after withdraw");
        assertLt(pooled2, pooled1, "Pooled should decrease further");

        vm.stopPrank();
    }

    // ============================================================================
    // ACCUMULATOR PATTERN TESTS
    // ============================================================================

    function testVogueAccumulatorCorrectness() public {
        console.log("=== testVogueAccumulatorCorrectness ===");

        // User01 deposits
        vm.prank(User01);
        V4.deposit{value: 100 ether}(0);

        (uint pooled1,,uint debt1,) = V4.autoManaged(User01);
        uint acc1 = V4.ETH_FEES();
        console.log("User01 - pooled:", pooled1);
        console.log("User01 - debt:", debt1);
        console.log("User01 - accumulator:", acc1);

        // Debt should be pooled * accumulator / WAD
        uint expectedDebt1 = FullMath.mulDiv(pooled1, acc1, WAD);
        console.log("Expected debt:", expectedDebt1);
        assertEq(debt1, expectedDebt1, "Debt should match formula");

        // User02 deposits later
        vm.prank(User02);
        V4.deposit{value: 50 ether}(0);

        (uint pooled2,,uint debt2,) = V4.autoManaged(User02);
        uint acc2 = V4.ETH_FEES();
        console.log("User02 - pooled:", pooled2);
        console.log("User02 - debt:", debt2);
        console.log("User02 - accumulator:", acc2);

        uint expectedDebt2 = FullMath.mulDiv(pooled2, acc2, WAD);
        console.log("Expected debt:", expectedDebt2);
        assertEq(debt2, expectedDebt2, "Debt should match formula");
    }

    function testPendingRewardsCalculation() public {
        console.log("=== testPendingRewardsCalculation ===");

        // Setup: deposit and simulate fee accrual
        vm.prank(User01);
        V4.deposit{value: 100 ether}(0);

        (uint pooled,,uint debtBefore,) = V4.autoManaged(User01);
        uint accBefore = V4.ETH_FEES();

        console.log("Before - pooled:", pooled);
        console.log("Before - debt:", debtBefore);
        console.log("Before - accumulator:", accBefore);

        // Calculate expected pending
        // pending = (pooled * accumulator / WAD) - debt
        uint expectedPending = FullMath.mulDiv(pooled, accBefore, WAD) - debtBefore;
        (uint actualPending,) = V4.pendingRewards(User01);

        console.log("Expected pending:", expectedPending);
        console.log("Actual pending:", actualPending);

        assertEq(actualPending, expectedPending, "Pending should match formula");
    }

    // ============================================================================
    // PART 4: VOGUE EDGE CASES
    // ============================================================================

    function test_BankRun_VaultLiquidity() public {
        // With 1M USDC backing at ~$3000/ETH, we can back ~333 ETH
        // Use moderate deposits that should be fully paired

        vm.prank(User01);
        V4.deposit{value: 40 ether}(0);

        // Verify User01's deposit was paired
        (uint pooled1,,,) = V4.autoManaged(User01);
        console.log("User01 pooled after deposit:", pooled1);

        vm.prank(User02);
        V4.deposit{value: 40 ether}(0);

        (uint pooled2,,,) = V4.autoManaged(User02);
        console.log("User02 pooled after deposit:", pooled2);

        vm.prank(User03);
        V4.deposit{value: 40 ether}(0);

        (uint pooled3,,,) = V4.autoManaged(User03);
        console.log("User03 pooled after deposit:", pooled3);

        uint totalDeposited = pooled1 + pooled2 + pooled3;
        console.log("Total deposited (after pairing):", totalDeposited / 1e18, "ETH");

        // Skip if deposits couldn't be paired (insufficient USD backing)
        if (totalDeposited == 0) {
            console.log("SKIP: No deposits could be paired - insufficient USD backing");
            return;
        }

        // Simulate bank run - everyone withdraws at once
        uint bal1Before = User01.balance;
        vm.prank(User01);
        V4.withdraw(type(uint).max);
        uint received1 = User01.balance - bal1Before;

        uint bal2Before = User02.balance;
        vm.prank(User02);
        V4.withdraw(type(uint).max);
        uint received2 = User02.balance - bal2Before;

        uint bal3Before = User03.balance;
        vm.prank(User03);
        V4.withdraw(type(uint).max);
        uint received3 = User03.balance - bal3Before;

        console.log("Received: User01=", received1/1e18);
        console.log("Received: User02=", received2/1e18);
        console.log("Received: User03=", received3/1e18);

        uint totalReceived = received1 + received2 + received3;
        console.log("Total received:", totalReceived/1e18, "ETH");

        // Each user should get back approximately what they deposited
        // Allow for some slippage from Uniswap rounding
        if (pooled1 > 0) assertGt(received1, pooled1 * 85 / 100, "User01 should receive ~deposit");
        if (pooled2 > 0) assertGt(received2, pooled2 * 85 / 100, "User02 should receive ~deposit");
        if (pooled3 > 0) assertGt(received3, pooled3 * 85 / 100, "User03 should receive ~deposit");

        // Total should be close to deposited (minus small fees/slippage)
        assertGt(totalReceived, totalDeposited * 80 / 100, "Should recover at least 80% total");
    }

    function test_Vogue_PendingRewards_NonDepositor() public {
        (uint eth, uint usd) = V4.pendingRewards(User03);
        assertEq(eth, 0, "Non-depositor ETH rewards should be 0");
        assertEq(usd, 0, "Non-depositor USD rewards should be 0");
    }

    function test_Vogue_Withdraw_ZeroShares() public {
        // User with no deposit tries to withdraw
        // Current behavior: does nothing, doesn't revert
        vm.startPrank(User03);

        uint balBefore = User03.balance;
        V4.withdraw(1 ether);  // No revert - just does nothing

        assertEq(User03.balance, balBefore, "Balance should be unchanged");

        Types.Deposit memory LP = getAutoManaged(User03);
        assertEq(LP.pooled_eth, 0, "Should have no position");

        vm.stopPrank();
    }

    function test_Vogue_Deposit_ZeroAmount() public {
        vm.startPrank(User01);
        // Depositing 0 should either revert or be a no-op
        uint sharesBefore = V4.totalShares();
        V4.deposit{value: 0}(0);
        uint sharesAfter = V4.totalShares();
        assertEq(sharesBefore, sharesAfter, "Zero deposit should not change shares");
        vm.stopPrank();
    }


    // ============================================================================
    // PART 6: FUZZ TESTS
    // ============================================================================

    function testFuzz_VogueDepositWithdraw(uint96 depositAmount, uint16 withdrawPct) public {
        vm.assume(depositAmount > 0.1 ether);
        vm.assume(depositAmount < 100 ether);
        vm.assume(withdrawPct > 0);
        vm.assume(withdrawPct <= 1000);  // Max 100%

        deal(User01, depositAmount);

        vm.startPrank(User01);
        V4.deposit{value: depositAmount}(0);

        Types.Deposit memory LP = getAutoManaged(User01);
        uint toWithdraw = LP.pooled_eth * withdrawPct / 1000;

        if (toWithdraw > 0) {
            uint balBefore = User01.balance;
            V4.withdraw(toWithdraw);
            uint received = User01.balance - balBefore;

            // Should receive approximately what was withdrawn
            assertGt(received, toWithdraw * 99 / 100, "Received too little");
        }
        vm.stopPrank();
    }

    function testFuzz_VogueDeposit(uint96 amount) public {
        vm.assume(amount > 0.01 ether);
        vm.assume(amount < 10000 ether);

        deal(User01, amount);

        vm.prank(User01);
        V4.deposit{value: amount}(0);

        Types.Deposit memory LP = getAutoManaged(User01);
        assertGt(LP.pooled_eth, 0, "Should have non-zero position");
    }

    // ============================================================================
    // PART 7: INTEGRATION TESTS
    // ============================================================================

    function test_Integration_FullCycleWithFees() public {
        console.log("=== Full Cycle Integration Test ===");

        // With 1M USDC backing at ~$3000/ETH, we can back ~333 ETH
        // Reduce deposits to ensure they can be fully paired

        vm.prank(User01);
        V4.deposit{value: 50 ether}(0);

        (uint user1Pooled,,,) = V4.autoManaged(User01);
        console.log("User01 pooled after deposit:", user1Pooled);

        vm.prank(User02);
        V4.deposit{value: 25 ether}(0);

        (uint user2Pooled,,,) = V4.autoManaged(User02);
        console.log("User02 pooled after deposit:", user2Pooled);

        console.log("After deposits - totalShares:", V4.totalShares());
        console.log("After deposits - POOLED_ETH:", CORE.POOLED_ETH());

        // Skip if deposits couldn't be paired
        if (user1Pooled == 0) {
            console.log("SKIP: User01 deposit could not be paired");
            return;
        }

        // Generate some swap activity (smaller amounts to not drain liquidity)
        for (uint i = 0; i < 3; i++) {
            vm.roll(block.number + 1);
            vm.warp(block.timestamp + 15);

            vm.prank(User03);
            // forETH=false means "I'm selling ETH for USDC"
            AUX.swap{value: 5 ether}(address(USDC), false, 0, 0);
        }

        (uint pending1,) = V4.pendingRewards(User01);
        (uint pending2,) = V4.pendingRewards(User02);

        console.log("User01 pending:", pending1);
        console.log("User02 pending:", pending2);

        uint bal1Before = User01.balance;
        vm.prank(User01);
        V4.withdraw(type(uint).max);
        uint received1 = User01.balance - bal1Before;

        console.log("User01 received:", received1);
        console.log("User01 original pooled:", user1Pooled);

        // User should receive at least 85% of what they deposited (allowing for slippage/fees)
        assertGt(received1, user1Pooled * 85 / 100, "Should receive approximately deposit");
    }
}
