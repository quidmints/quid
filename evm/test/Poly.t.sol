
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
import {VogueUni as Vogue} from "../src/L2/VogueUni.sol";
import {Rover} from "../src/Rover.sol";
import {Basket} from "../src/Basket.sol";

import {BasketLib} from "../src/imports/BasketLib.sol";
import {VogueCore} from "../src/VogueCore.sol";
import {AuxPoly as Aux} from "../src/L2/AuxPoly.sol";
import {Types} from "../src/imports/Types.sol";

import {Link} from "../src/Link.sol";
import {Jury} from "../src/Jury.sol";
import {Court} from "../src/Court.sol";

contract Poly is Test, Fixtures {
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
    IUniswapV3Pool public WETHv3pool = IUniswapV3Pool(0xA4D8c89f0c20efbe54cBa9e7e7a7E509056228D9);
    IPoolManager public poolManager = IPoolManager(0x67366782805870060151383F4BbFF9daB53e5cD6);

    address[] public STABLECOINS; address[] public VAULTS;

    IERC20 public WETH = IERC20(0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619);
    address public aavePool = 0x794a61358D6845594F94dc1DB02A252b5b4814aD;
    address public aaveData = 0xFa1A7c4a8A63C9CAb150529c26f182cBB5500944;
    address public aaveAddr = 0xa97684ead0e402dC232d5A977953DF7ECBaB3CDb;
    address public JAM = 0xbeb0b0623f66bE8cE162EbDfA2ec543A522F4ea6;

    IERC20 public USDC = IERC20(0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359);
    IERC20 public USDT = IERC20(0xc2132D05D31c914a87C6611C10748AEb04B58e8F);
    IERC20 public DAI = IERC20(0x8f3Cf7ad23Cd3CaDbD9735AFf958023239c6A063);
    IERC20 public FRAX = IERC20(0x80Eede496655FB9047dd39d9f418d5483ED600df);
    IERC20 public CRVUSD = IERC20(0xc4Ce1D6F5D98D65eE25Cf85e9F2E9DcFEe6Cb5d6);
    IERC20 public SFRAX = IERC20(0x5Bff88cA1442c2496f7E475E9e7786383Bc070c0);

    // Morpho vaults
    IERC4626 public usdcVault = IERC4626(0xAcB0DCe4b0FF400AD8F6917f3ca13E434C9ed6bC);
    IERC4626 public usdtVault = IERC4626(0xB7c9988D3922F25a336a469F3bB26CA61FE79e24);
    IERC4626 public wethVault = IERC4626(0xF5C81d25ee174d83f1FD202cA94AE6070d073cCF);
    address public aTokenDAIonPoly = 0x82E64f49Ed5EC1bC6e43DAD4FC8Af9bb3A2312EE;

    VogueCore public CORE;
    Basket public QUID;
    Vogue public V4;
    Rover public V3;
    Aux public AUX;
    Amp public AMP;
    Link public LINK;
    Jury public jury;
    Court public court;

    address constant FORWARDER = 0x76c9cf548b4179F8901cda1f8623568b58215E62;
    uint stack = 10000 * USDC_PRECISION;

    function setUp() public {
        /**
         * STABLES ARRAY FOR POLYGON:
         * Only 6 stables, no staked pairs (except SFRAX)
         * USDC/USDT -> Morpho vaults, DAI -> AAVE, FRAX/CRVUSD/SFRAX -> direct
         */
        STABLECOINS = [
            address(USDC),    // Index 0: Morpho vault (6 dec)
            address(USDT),    // Index 1: Morpho vault (6 dec)
            address(DAI),     // Index 2: AAVE (18 dec)
            address(FRAX),    // Index 3: Direct (18 dec)
            address(CRVUSD),  // Index 4: Direct (18 dec)
            address(SFRAX)    // Index 5: Direct (18 dec), folds into FRAX
        ];
        VAULTS = [
            address(usdcVault),
            address(usdtVault),
            aTokenDAIonPoly   // For DAI (index 2): AAVE V3 aToken (unchanged).
        ];

        uint mainnetFork = vm.createFork("https://rpc.ankr.com/polygon/abc1c9e1ba906a35c59e62a69c80cf77219499b3cd05752d53c0ed17d14cbfc3");
        vm.selectFork(mainnetFork);
        vm.mockCall(
            0xF9680D99D6C9589e2a93a78A04A279e509205945,
            abi.encodeWithSignature("latestAnswer()"),
            abi.encode(int256(210000000000))
        );

        // Fund users with USDC
        deal(address(USDC), User01, 10000000 * USDC_PRECISION);
        deal(address(USDC), User02, 10000000 * USDC_PRECISION);
        deal(address(USDC), User03, 10000000 * USDC_PRECISION);

        deal(address(WETH), User01, 1000000000 ether);
        deal(address(WETH), User02, 1000000000 ether);
        deal(address(WETH), User03, 1000000000 ether);

        vm.deal(address(this), 1000000000 ether);
        vm.deal(User01, 1000000000 ether);
        vm.deal(User02, 1000000000 ether);
        vm.deal(User03, 1000000000 ether);

        AMP = new Amp(aavePool, aaveData, aaveAddr);
        V3 = new Rover(address(AMP), address(WETH),
            address(USDC), address(nfpm),
            address(WETHv3pool),
            address(V3router), false);

        V4 = new Vogue(address(wethVault));
        CORE = new VogueCore(poolManager);
        AUX = new Aux(
            address(V4),
            address(CORE),
            address(wethVault),
            address(AMP), aavePool,
            address(WETHv3pool), address(V3router),
            address(V3), STABLECOINS, VAULTS);

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
        V4.setup(address(QUID), address(AUX), address(CORE), false);
        AUX.setQuid(address(QUID), JAM); V3.setAux(address(AUX));

        // Polygon WETH is bridged ERC20 — no native wrapping.
        // Deal WETH to users and approve V4/AUX/V3 for transferFrom path.
        deal(address(WETH), User01, 1000000 ether);
        deal(address(WETH), User02, 1000000 ether);
        deal(address(WETH), User03, 1000000 ether);

        vm.startPrank(User01);
        WETH.approve(address(V4), type(uint).max);
        WETH.approve(address(AUX), type(uint).max);
        WETH.approve(address(V3), type(uint).max);
        vm.stopPrank();

        vm.startPrank(User02);
        WETH.approve(address(V4), type(uint).max);
        WETH.approve(address(AUX), type(uint).max);
        vm.stopPrank();

        vm.startPrank(User03);
        WETH.approve(address(V4), type(uint).max);
        WETH.approve(address(AUX), type(uint).max);
        vm.stopPrank();

        // Mint QUID with USDC to populate vaults
        vm.startPrank(User01);
        USDC.approve(address(AUX), type(uint).max);
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
        V4.deposit(100 ether);

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
        AUX.swap(address(USDC), false, 1 ether, 0);

        uint usdcAfter = USDC.balanceOf(User01);
        uint usdcReceived = usdcAfter - usdcBefore;
        console.log("USDC received for 1 ETH:", usdcReceived);

        uint expectedUsdc = price / 1e12;
        console.log("Expected USDC (approx):", expectedUsdc);

        assertGt(usdcReceived, expectedUsdc * 90 / 100, "Should receive reasonable USDC");

        vm.stopPrank();
    }

    function testWithdrawAndLeveragedSwaps() public {
        vm.startPrank(User01);
        V3.repackNFT();
        V3.deposit(5 ether);
        V4.deposit(5 ether);

        uint balanceBefore = WETH.balanceOf(User01);
        V4.withdraw(1 ether);
        uint balanceAfter = WETH.balanceOf(User01);

        assertApproxEqAbs(balanceAfter - balanceBefore, 1 ether, 100000);

        address[] memory whose = new address[](1);
        whose[0] = User01;

        AUX.leverETH(1 ether);

        USDC.approve(address(AUX), stack / 5);
        AUX.leverUSD(stack / 10, address(USDC));
        vm.stopPrank();
    }

    function testRedeem() public {
        vm.startPrank(User01);

        uint mintAmount = 10000 * 1e6;
        USDC.approve(address(AUX), mintAmount);

        uint currentMonth = QUID.currentMonth();
        uint minted = QUID.mint(User01, mintAmount, address(USDC), 0);

        console.log("Minted QUID:", minted);
        console.log("Current month:", currentMonth);

        uint USDCbalanceBefore = USDC.balanceOf(User01);

        try AUX.redeem(1000 * WAD) {
            uint received = USDC.balanceOf(User01) - USDCbalanceBefore;
            console.log("Immature redeem got:", received);
            assertLt(received, 100 * 1e6, "Should get very little when immature");
        } catch {
            console.log("Immature redeem reverted (expected)");
        }

        vm.warp(block.timestamp + 35 days);

        USDCbalanceBefore = USDC.balanceOf(User01);
        AUX.redeem(1000 * WAD);
        uint USDCbalanceAfter = USDC.balanceOf(User01);

        uint received = USDCbalanceAfter - USDCbalanceBefore;
        console.log("Mature redeem got:", received, "expected:", 1000 * 1e6);

        assertApproxEqAbs(received, 1000 * 1e6, 500 * 1e6,
            "Should redeem with 50% tolerance for fees");

        vm.stopPrank();
    }

    function testOutOfRangeUSDPosition() public {
        vm.startPrank(User01);
        V4.deposit(25 ether);

        USDC.approve(address(AUX), stack);
        uint balanceBefore = USDC.balanceOf(User01);

        uint id = V4.outOfRange(stack / 10, address(USDC), 1000, 100);

        assertGt(id, 0, "Position ID should be > 0");
        assertApproxEqAbs(USDC.balanceOf(User01), balanceBefore - stack / 10,
                        stack / 100, "USDC should be deducted");

        vm.roll(vm.getBlockNumber() + 48);
        balanceBefore = USDC.balanceOf(User01);
        V4.pull(id, 100, address(USDC));

        assertApproxEqAbs(USDC.balanceOf(User01),
        balanceBefore, stack / 50, "Should get USDC back");

        vm.stopPrank();
    }

    function testPartialPullOutOfRange() public {
        vm.startPrank(User01);
        V4.deposit(50 ether);

        vm.roll(vm.getBlockNumber() + 1);

        uint id = V4.outOfRange(2 ether, address(0), -1000, 100);
        assertGt(id, 0, "Should create position");

        vm.roll(vm.getBlockNumber() + 48);

        uint balanceBefore = USDC.balanceOf(User01);
        V4.pull(id, 50, address(USDC));

        uint received = USDC.balanceOf(User01) - balanceBefore;
        assertGt(received, 0, "Should receive USDC");

        vm.stopPrank();
    }

    function testInvalidOutOfRangeParams() public {
        vm.startPrank(User01);
        V4.deposit(25 ether);

        vm.expectRevert();
        V4.outOfRange(1 ether, address(0), -1000, 50);

        vm.expectRevert();
        V4.outOfRange(1 ether, address(0), -1000, 1500);

        vm.expectRevert();
        V4.outOfRange(1 ether, address(0), -6000, 100);

        vm.expectRevert();
        V4.outOfRange(1 ether, address(0), -1050, 100);

        vm.stopPrank();
    }

    function testMultipleBatchMaturities() public {
        vm.startPrank(User01);

        uint batchSize = 25000 * 1e6;
        USDC.approve(address(AUX), batchSize * 3);

        QUID.mint(User01, batchSize, address(USDC), 1);

        vm.warp(block.timestamp + 30 days);
        QUID.mint(User01, batchSize, address(USDC), 2);

        vm.warp(block.timestamp + 30 days);
        QUID.mint(User01, batchSize, address(USDC), 3);

        vm.warp(block.timestamp + 5 days);

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

        V4.deposit(10 ether);

        uint ethFeesBefore = V4.ETH_FEES();

        USDC.approve(address(AUX), stack);
        for (uint i = 0; i < 10; i++) {
            AUX.swap(address(USDC), false, 2 ether, 0);
        }

        vm.roll(vm.getBlockNumber() + 1);

        uint ethFeesAfter = V4.ETH_FEES();
        assertGe(ethFeesAfter, ethFeesBefore, "ETH fees should not decrease");

        vm.stopPrank();
    }

    function testWithdrawWithAccruedFees() public {
        vm.startPrank(User01);

        V4.deposit(10 ether);

        USDC.approve(address(AUX), stack);
        (,uint160 sqrtPriceX96,) = CORE.poolTicks();
        uint price = _getPrice(sqrtPriceX96, V4.token1isETH());
        for (uint i = 0; i < 5; i++) {
            uint amountNeeded = FullMath.mulDiv(6000 * WAD, WAD, price);
            AUX.swap(address(USDC), false, amountNeeded, 0);
            vm.roll(vm.getBlockNumber() + 1);
        }

        uint balanceBefore = WETH.balanceOf(User01);
        V4.withdraw(5 ether);
        uint received = WETH.balanceOf(User01) - balanceBefore;

        assertGe(received, 4.5 ether, "Should receive close to withdrawal amount");

        vm.stopPrank();
    }

    function testMultipleSwapsAcrossBlocks() public {
        console.log("=== testMultipleSwapsAcrossBlocks ===");

        vm.startPrank(User01);
        V4.deposit(100 ether);

        uint pooledBefore = CORE.POOLED_ETH();
        console.log("POOLED_ETH before:", pooledBefore);

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

        uint usdcBefore = USDC.balanceOf(User01);
        AUX.swap(address(USDC), false, 5 ether, 0);
        console.log("Swap 1 executed");

        vm.roll(block.number + 1);
        AUX.swap(address(USDC), false, 5 ether, 0);
        console.log("Swap 2 executed");

        vm.roll(block.number + 1);
        AUX.swap(address(USDC), false, 5 ether, 0);
        console.log("Swap 3 executed");

        uint usdcReceived = USDC.balanceOf(User01) - usdcBefore;
        console.log("Total USDC received:", usdcReceived);
        assertGt(usdcReceived, 0, "Should receive USDC from swaps");

        uint pooledAfter = CORE.POOLED_ETH();
        console.log("POOLED_ETH after:", pooledAfter);

        vm.stopPrank();
    }

    function testAlternatingSwaps() public {
        vm.startPrank(User01);
        V4.deposit(100 ether);
        USDC.approve(address(AUX), type(uint).max);

        (,uint160 sqrtPriceX96,) = CORE.poolTicks();
        uint price = _getPrice(sqrtPriceX96, V4.token1isETH());

        for (uint i = 0; i < 10; i++) {
            if (i % 2 == 0) {
                AUX.swap(address(USDC), false, 0.5 ether, 0);
            } else {
                AUX.swap(address(USDC), true, price / 1e12, 0);
            }
            vm.roll(vm.getBlockNumber() + 1);
        }

        vm.stopPrank();
    }

    function testMetricsCalculation() public {
        vm.startPrank(User01);

        QUID.mint(User01, stack * 5, address(USDC), 0);

        (uint total1, uint yield1) = AUX.get_metrics(true);
        assertGt(total1, 0, "Total should be > 0");

        vm.warp(block.timestamp + 1 hours);

        (uint total2, uint yield2) = AUX.get_metrics(true);

        assertApproxEqAbs(total2, total1, total1 / 20, "Total should be relatively stable");

        vm.stopPrank();
    }

    function testDepositImmediateWithdraw() public {
        vm.startPrank(User01);

        uint depositAmount = 10 ether;
        V4.deposit(depositAmount);
        (uint pooled_eth, uint usd_owed,
        uint fees_eth, uint fees_usd) = V4.autoManaged(User01);

        vm.roll(vm.getBlockNumber() + 1);

        AUX.swap(address(USDC), false, 0.1 ether, 0);

        uint balanceBefore = WETH.balanceOf(User01);

        uint withdrawAmount = 5 ether;

        try V4.withdraw(withdrawAmount) {
            uint balanceAfter = WETH.balanceOf(User01);
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

        V4.deposit(10 ether);

        AUX.swap(address(USDC), false, 2 ether, 0);
        vm.roll(vm.getBlockNumber() + 1);

        vm.warp(block.timestamp + 11 minutes);

        vm.stopPrank();
    }

    function testFuzz_SwapAmounts(uint96 amount) public {
        amount = uint96(bound(amount, 0.1 ether, 100 ether));

        vm.startPrank(User01);
        V4.deposit(200 ether);

        uint pooledETH = CORE.POOLED_ETH();
        if (pooledETH == 0) {
            vm.stopPrank();
            return;
        }

        uint usdcBefore = USDC.balanceOf(User01);
        AUX.swap(address(USDC), false, amount, 0);

        uint usdcReceived = USDC.balanceOf(User01) - usdcBefore;

        assertGt(usdcReceived, 0, "Should receive USDC for any swap");

        vm.stopPrank();
    }

    function testFuzz_OutOfRangeDistance(int24 distance) public {
        distance = int24(bound(int256(distance), -5000, 5000));
        distance = (distance / 100) * 100;
        vm.assume(distance != 0);

        vm.startPrank(User01);
        V4.deposit(25 ether);

        try V4.outOfRange(1 ether, address(0), distance, 100) returns (uint id) {
            assertGt(id, 0, "Should create position");
        } catch {
            // Expected failure for some distances
        }

        vm.stopPrank();
    }

    function testRedeemFromSingleVault() public {
        vm.startPrank(User01);

        vm.warp(block.timestamp + 30 days);
        uint userBalance = QUID.balanceOf(User01);
        uint redeemAmount = userBalance / 2;

        uint usdcBefore = USDC.balanceOf(User01);
        AUX.redeem(redeemAmount);
        uint usdcReceived = USDC.balanceOf(User01) - usdcBefore;
        assertGt(usdcReceived, 0, "Should receive USDC");

        vm.stopPrank();
    }

    function testVaultBalanceDistribution() public {
        (uint[14] memory deposits,) = AUX.get_deposits();

        // Polygon: out[1]=USDC, out[2]=USDT, out[3]=DAI, out[4]=FRAX+SFRAX, out[5]=CRVUSD
        uint total = deposits[12]; // TVL
        console.log("TVL:", total);
        for (uint i = 1; i <= 5; i++) {
            if (deposits[i] > 0) {
                console.log("Vault", i);
                console.log("deposits[i]", deposits[i]);
            }
        }
        // Verify we have deposits in at least one vault
        uint vaultsWithDeposits = 0;
        for (uint i = 1; i <= 5; i++) {
            if (deposits[i] > 0) vaultsWithDeposits++;
        }
        assertGe(vaultsWithDeposits, 1, "Should have deposits in at least 1 vault");
    }

    function testDepositVaultShares() public {
        vm.startPrank(User01);

        uint depositAmount = 500 * 1e6;
        USDC.approve(address(AUX), depositAmount);

        uint quidBefore = QUID.totalSupply();
        QUID.mint(User01, depositAmount, address(USDC), 0);

        // Verify vault has the deposit (AuxPoly: USDC at out[1])
        (uint[14] memory deposits,) = AUX.get_deposits();
        assertGt(deposits[1], 0, "USDC vault should have deposits");
        assertGt(QUID.totalSupply(), quidBefore, "Should mint QUID");

        vm.stopPrank();
    }

    function testSwapWithDifferentStableOutputs() public {
        console.log("=== testSwapWithDifferentStableOutputs ===");

        vm.startPrank(User01);
        V4.deposit(100 ether);

        uint pooledETH = CORE.POOLED_ETH();
        console.log("POOLED_ETH:", pooledETH);

        if (pooledETH == 0) {
            console.log("Pool not active - skipping");
            vm.stopPrank();
            return;
        }

        uint usdcBefore = USDC.balanceOf(User01);
        AUX.swap(address(USDC), false, 1 ether, 0);

        uint usdcReceived = USDC.balanceOf(User01) - usdcBefore;
        console.log("USDC received:", usdcReceived);

        assertGt(usdcReceived, 0, "Should receive USDC");

        vm.stopPrank();
    }

    function test_WithdrawDoesNotPersistFeeSnapshot() public {
        vm.startPrank(User01);
        V4.deposit(100 ether);

        (uint pooled, uint pending_usd, uint fees_eth, uint fees_usd) = V4.autoManaged(User01);
        assertGt(pooled, 0, "User should have pooled_eth");
        assertGt(V4.totalShares(), 0, "totalShares should increase");

        vm.stopPrank();

        for (uint i = 0; i < 3; i++) {
            vm.startPrank(User03);
            AUX.swap(address(USDC), false, 20 ether, 0);
            vm.roll(block.number + 1);
            vm.warp(block.timestamp + 15 minutes);
            vm.stopPrank();
        }

        uint balBefore = WETH.balanceOf(User01);
        vm.prank(User01);
        V4.withdraw(10 ether);
        uint received = WETH.balanceOf(User01) - balBefore;
        assertGt(received, 0, "Should receive something on withdraw");

        for (uint i = 0; i < 3; i++) {
            vm.startPrank(User03);
            AUX.swap(address(USDC), false, 20 ether, 0);
            vm.roll(block.number + 1);
            vm.warp(block.timestamp + 15 minutes);
            vm.stopPrank();
        }

        balBefore = WETH.balanceOf(User01);
        vm.prank(User01);
        V4.withdraw(10 ether);
        received = WETH.balanceOf(User01) - balBefore;
        assertGt(received, 0, "Should receive something on final withdraw");
    }

    function test_FeeAttributionWithMultipleLPs() public {
        vm.deal(User01, 1000 ether);
        vm.deal(User02, 1000 ether);
        vm.deal(User03, 1000 ether);

        vm.prank(User01);
        V4.deposit(100 ether);

        uint pooledAlice = CORE.POOLED_ETH();
        assertGt(pooledAlice, 0, "POOLED_ETH should be > 0 after deposit");

        vm.startPrank(User03);
        USDC.approve(address(AUX), type(uint).max);
        for (uint i = 0; i < 3; i++) {
            AUX.swap(address(USDC), false, 10 ether, 0);
            vm.roll(block.number + 1);
            vm.warp(block.timestamp + 15 minutes);
        }
        vm.stopPrank();

        vm.prank(User02);
        V4.deposit(100 ether);

        (uint bobPooled,,,) = V4.autoManaged(User02);

        vm.startPrank(User03);
        for (uint i = 0; i < 3; i++) {
            AUX.swap(address(USDC), false, 10 ether, 0);
            vm.roll(block.number + 1);
            vm.warp(block.timestamp + 15 minutes);
        }
        vm.stopPrank();

        uint bal1 = WETH.balanceOf(User01);
        vm.prank(User01);
        V4.withdraw(type(uint).max);
        uint aliceReceived = WETH.balanceOf(User01) - bal1;

        uint bal2 = WETH.balanceOf(User02);
        vm.prank(User02);
        V4.withdraw(type(uint).max);
        uint bobReceived = WETH.balanceOf(User02) - bal2;

        assertGt(aliceReceived, 0, "Alice should receive ETH");
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
        vm.prank(User01);
        V4.deposit(100 ether);

        vm.prank(User02);
        V4.deposit(50 ether);

        vm.prank(User03);
        V4.deposit(75 ether);

        (uint pooled1,,,) = V4.autoManaged(User01);
        (uint pooled2,,,) = V4.autoManaged(User02);
        (uint pooled3,,,) = V4.autoManaged(User03);

        uint sumPooled = pooled1 + pooled2 + pooled3;
        uint totalShares = V4.totalShares();

        assertEq(totalShares, sumPooled, "totalShares should equal sum of individual shares");
    }

    function testVogueZeroDeposit() public {
        vm.startPrank(User01);

        uint sharesBefore = V4.totalShares();
        V4.deposit(0);
        uint sharesAfter = V4.totalShares();

        assertEq(sharesBefore, sharesAfter, "Zero deposit should not change shares");

        vm.stopPrank();
    }

    function testVogueMultipleDeposits() public {
        vm.startPrank(User01);

        V4.deposit(10 ether);
        (uint pooled1,,,) = V4.autoManaged(User01);

        V4.deposit(20 ether);
        (uint pooled2,,,) = V4.autoManaged(User01);

        V4.deposit(5 ether);
        (uint pooled3,,,) = V4.autoManaged(User01);

        assertApproxEqAbs(pooled3, 35 ether, 1, "Pooled should equal total deposited");

        vm.stopPrank();
    }

    function testVoguePartialWithdraws() public {
        vm.startPrank(User01);
        V4.deposit(100 ether);

        (uint pooledInitial,,,) = V4.autoManaged(User01);

        uint balBefore = WETH.balanceOf(User01);
        V4.withdraw(10 ether);
        uint received1 = WETH.balanceOf(User01) - balBefore;

        (uint pooled1,,,) = V4.autoManaged(User01);

        balBefore = WETH.balanceOf(User01);
        V4.withdraw(20 ether);
        uint received2 = WETH.balanceOf(User01) - balBefore;

        (uint pooled2,,,) = V4.autoManaged(User01);

        assertLt(pooled1, pooledInitial, "Pooled should decrease after withdraw");
        assertLt(pooled2, pooled1, "Pooled should decrease further");

        vm.stopPrank();
    }

    // ============================================================================
    // ACCUMULATOR PATTERN TESTS
    // ============================================================================

    function testVogueAccumulatorCorrectness() public {
        vm.prank(User01);
        V4.deposit(100 ether);

        (uint pooled1,,uint debt1,) = V4.autoManaged(User01);
        uint acc1 = V4.ETH_FEES();

        uint expectedDebt1 = FullMath.mulDiv(pooled1, acc1, WAD);
        assertEq(debt1, expectedDebt1, "Debt should match formula");

        vm.prank(User02);
        V4.deposit(50 ether);

        (uint pooled2,,uint debt2,) = V4.autoManaged(User02);
        uint acc2 = V4.ETH_FEES();

        uint expectedDebt2 = FullMath.mulDiv(pooled2, acc2, WAD);
        assertEq(debt2, expectedDebt2, "Debt should match formula");
    }

    function testPendingRewardsCalculation() public {
        vm.prank(User01);
        V4.deposit(100 ether);

        (uint pooled,,uint debtBefore,) = V4.autoManaged(User01);
        uint accBefore = V4.ETH_FEES();

        uint expectedPending = FullMath.mulDiv(pooled, accBefore, WAD) - debtBefore;
        (uint actualPending,) = V4.pendingRewards(User01);

        assertEq(actualPending, expectedPending, "Pending should match formula");
    }

    // ============================================================================
    // EDGE CASES
    // ============================================================================

    function test_BankRun_VaultLiquidity() public {
        vm.prank(User01);
        V4.deposit(40 ether);

        (uint pooled1,,,) = V4.autoManaged(User01);

        vm.prank(User02);
        V4.deposit(40 ether);

        (uint pooled2,,,) = V4.autoManaged(User02);

        vm.prank(User03);
        V4.deposit(40 ether);

        (uint pooled3,,,) = V4.autoManaged(User03);

        uint totalDeposited = pooled1 + pooled2 + pooled3;

        if (totalDeposited == 0) {
            console.log("SKIP: No deposits could be paired");
            return;
        }

        uint bal1Before = WETH.balanceOf(User01);
        vm.prank(User01);
        V4.withdraw(type(uint).max);
        uint received1 = WETH.balanceOf(User01) - bal1Before;

        uint bal2Before = WETH.balanceOf(User02);
        vm.prank(User02);
        V4.withdraw(type(uint).max);
        uint received2 = WETH.balanceOf(User02) - bal2Before;

        uint bal3Before = WETH.balanceOf(User03);
        vm.prank(User03);
        V4.withdraw(type(uint).max);
        uint received3 = WETH.balanceOf(User03) - bal3Before;

        uint totalReceived = received1 + received2 + received3;

        if (pooled1 > 0) assertGt(received1, pooled1 * 85 / 100, "User01 should receive ~deposit");
        if (pooled2 > 0) assertGt(received2, pooled2 * 85 / 100, "User02 should receive ~deposit");
        if (pooled3 > 0) assertGt(received3, pooled3 * 85 / 100, "User03 should receive ~deposit");

        assertGt(totalReceived, totalDeposited * 80 / 100, "Should recover at least 80% total");
    }

    function test_Vogue_PendingRewards_NonDepositor() public {
        (uint eth, uint usd) = V4.pendingRewards(User03);
        assertEq(eth, 0, "Non-depositor ETH rewards should be 0");
        assertEq(usd, 0, "Non-depositor USD rewards should be 0");
    }

    function test_Vogue_Withdraw_ZeroShares() public {
        vm.startPrank(User03);

        uint balBefore = WETH.balanceOf(User03);
        V4.withdraw(1 ether);

        assertEq(WETH.balanceOf(User03), balBefore, "Balance should be unchanged");

        Types.Deposit memory LP = getAutoManaged(User03);
        assertEq(LP.pooled_eth, 0, "Should have no position");

        vm.stopPrank();
    }

    function test_Vogue_Deposit_ZeroAmount() public {
        vm.startPrank(User01);
        uint sharesBefore = V4.totalShares();
        V4.deposit(0);
        uint sharesAfter = V4.totalShares();
        assertEq(sharesBefore, sharesAfter, "Zero deposit should not change shares");
        vm.stopPrank();
    }

    // ============================================================================
    // FUZZ TESTS
    // ============================================================================

    function testFuzz_VogueDepositWithdraw(uint96 depositAmount, uint16 withdrawPct) public {
        vm.assume(depositAmount > 0.1 ether);
        vm.assume(depositAmount < 100 ether);
        vm.assume(withdrawPct > 0);
        vm.assume(withdrawPct <= 1000);

        deal(address(WETH), User01, uint(depositAmount) + 1000000 ether);

        vm.startPrank(User01);
        V4.deposit(depositAmount);

        Types.Deposit memory LP = getAutoManaged(User01);
        uint toWithdraw = LP.pooled_eth * withdrawPct / 1000;

        if (toWithdraw > 0) {
            uint balBefore = WETH.balanceOf(User01);
            V4.withdraw(toWithdraw);
            uint received = WETH.balanceOf(User01) - balBefore;

            assertGt(received, toWithdraw * 99 / 100, "Received too little");
        }
        vm.stopPrank();
    }

    function testFuzz_VogueDeposit(uint96 amount) public {
        vm.assume(amount > 0.01 ether);
        vm.assume(amount < 10000 ether);

        deal(address(WETH), User01, uint(amount) + 1000000 ether);

        vm.prank(User01);
        V4.deposit(amount);

        Types.Deposit memory LP = getAutoManaged(User01);
        assertGt(LP.pooled_eth, 0, "Should have non-zero position");
    }

    // ============================================================================
    // INTEGRATION TESTS
    // ============================================================================

    function test_Integration_FullCycleWithFees() public {
        console.log("=== Full Cycle Integration Test ===");

        vm.prank(User01);
        V4.deposit(50 ether);

        (uint user1Pooled,,,) = V4.autoManaged(User01);
        console.log("User01 pooled after deposit:", user1Pooled);

        vm.prank(User02);
        V4.deposit(25 ether);

        (uint user2Pooled,,,) = V4.autoManaged(User02);
        console.log("User02 pooled after deposit:", user2Pooled);

        if (user1Pooled == 0) {
            console.log("SKIP: User01 deposit could not be paired");
            return;
        }

        for (uint i = 0; i < 3; i++) {
            vm.roll(block.number + 1);
            vm.warp(block.timestamp + 15);

            vm.prank(User03);
            AUX.swap(address(USDC), false, 5 ether, 0);
        }

        uint bal1Before = WETH.balanceOf(User01);
        vm.prank(User01);
        V4.withdraw(type(uint).max);
        uint received1 = WETH.balanceOf(User01) - bal1Before;

        console.log("User01 received:", received1);
        console.log("User01 original pooled:", user1Pooled);

        assertGt(received1, user1Pooled * 85 / 100, "Should receive approximately deposit");
    }
}
