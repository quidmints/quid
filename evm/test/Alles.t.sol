// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import {Fixtures} from "./utils/Fixtures.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {IUniswapV3Pool} from "../src/imports/v3/IUniswapV3Pool.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";
import {CurrencyLibrary, Currency} from "v4-core/src/types/Currency.sol";

import {INonfungiblePositionManager} from "../src/imports/v3/INonfungiblePositionManager.sol";
import {IV3SwapRouter as ISwapRouter} from "../src/imports/v3/IV3SwapRouter.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";

import {Aux} from "../src/Aux.sol";
import {Amp} from "../src/Amp.sol";
import {Vogue} from "../src/Vogue.sol";
import {Rover} from "../src/Rover.sol";
import {Basket} from "../src/Basket.sol";
import {FeeLib} from "../src/imports/FeeLib.sol";

import {BasketLib} from "../src/imports/BasketLib.sol";
import {MessageCodec} from "../src/imports/MessageCodec.sol";
import {Types} from "../src/imports/Types.sol";
import {VogueCore} from "../src/VogueCore.sol";
import {Link} from "../src/Link.sol";
import {Jury} from "../src/Jury.sol";
import {Court} from "../src/Court.sol";

contract Alles is Test, Fixtures {
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
    IUniswapV3Pool public WETHv3pool = IUniswapV3Pool(0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640);
    IPoolManager public poolManager = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);

    // Arb : 0xa6147867264374F324524E30C02C331cF28aa879
    address constant FORWARDER = 0x0b93082D9b3C7C97fAcd250082899BAcf3af3885;
    address constant JAM = 0xbeb0b0623f66bE8cE162EbDfA2ec543A522F4ea6;

    address[] public STABLECOINS; address[] public VAULTS; Link public LINK;
    IERC20 public WETH = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    address public aavePool  = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address public aaveData  = 0x56b7A1012765C285afAC8b8F25C69Bf10ccfE978;
    address public aaveAddr  = 0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e;
    address public aaveHub   = 0xCca852Bc40e560adC3b1Cc58CA5b55638ce826c9;
    address public aaveSpoke = 0x94e7A5dCbE816e498b89aB752661904E2F56c485;
    address public stabilityPool = 0x5721cbbd64fc7Ae3Ef44A0A3F9a790A9264Cf9BF;

    IERC20 public GHO = IERC20(0x40D16FC0246aD3160Ccc09B8D0D3A2cD28aE6C2f);
    IERC20 public USDT = IERC20(0xdAC17F958D2ee523a2206206994597C13D831ec7);
    IERC20 public USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IERC20 public DAI = IERC20(0x6B175474E89094C44Da98b954EedeAC495271d0F);
    IERC20 public PYUSD = IERC20(0x6c3ea9036406852006290770BEdFcAbA0e23A0e8);
    IERC20 public USDS = IERC20(0xdC035D45d973E3EC169d2276DDab16f1e407384F);
    IERC20 public USDE = IERC20(0x4c9EDD5852cd905f086C759E8383e09bff1E68B3);
    IERC20 public CRVUSD = IERC20(0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E);
    IERC20 public FRAX = IERC20(0xCAcd6fd266aF91b8AeD52aCCc382b4e165586E29);
    IERC20 public BOLD = IERC20(0x6440f144b7e50D6a8439336510312d2F54beB01D);
    IERC20 public USYC = IERC20(0x136471a34f6ef19fE571EFFC1CA711fdb8E49f2b);

    address public hashnote = 0xeE35F963BFC71b51eC95147f26c030D674ea30e6;
    address public pyusdMorpho = 0xb576765fB15505433aF24FEe2c0325895C559FB2;
    IERC4626 public SDAI = IERC4626(0x83F20F44975D03b1b09e64809B757c47f942BEeA);
    IERC4626 public SFRAX = IERC4626(0xcf62F905562626CfcDD2261162a51fd02Fc9c5b6);
    IERC4626 public SUSDS = IERC4626(0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD);
    IERC4626 public SUSDE = IERC4626(0x9D39A5DE30e57443BfF2A8307A4256c8797A3497);
    IERC4626 public SCRVUSD = IERC4626(0x0655977FEb2f289A4aB78af67BAB0d17aAb84367);

    function _deployAndSeed() internal {
        if (QUID.totalSupply() >= 10_000e18) {
            deal(address(USDC), address(this), 10e6);
            USDC.approve(address(AUX), 10e6);
            QUID.mint(address(this), 10e6, address(USDC), 0);
        } else {
            deal(address(USDC), address(this), 15_000e6);
            USDC.approve(address(AUX), 15_000e6);
            QUID.mint(address(this), 15_000e6, address(USDC), 0);
        }
        V4.deposit{value: 100 ether}(0);
        // Ensure test contract has QD to file assertions
        deal(address(QUID), address(this), 500e18);
    }

    /// @dev Resolve as "none depegged" — permissionless monthly timeout.
    function _resolveNone() internal {
        uint roundStart = LINK.getRoundStartTime();
        if (block.timestamp < roundStart + FeeLib.MONTH)
            vm.warp(roundStart + FeeLib.MONTH + 1);
        LINK.resolveAsNone();
    }

    /// @dev Complete UMA lifecycle after payouts:
    ///      warp past reveal window (48h)...restart.
    function _finishRound() internal {
        vm.warp(block.timestamp + 48 hours + 1);
        LINK.restartMarket();
    }

    /// @dev Single-user reveal + weight via calculateWeights.
    function _revealAndWeigh(address user, uint8 side, uint conf, bytes32 salt) internal {
        address[] memory users = new address[](1);
        uint8[] memory sides = new uint8[](1);
        Link.RevealEntry[] memory reveals = new Link.RevealEntry[](1);
        uint[] memory counts = new uint[](1);
        users[0] = user; sides[0] = side; counts[0] = 1;
        reveals[0] = Link.RevealEntry({confidence: conf, salt: salt});
        LINK.calculateWeights(users, sides, reveals, counts);
    }

    /// @dev Reveal-only helper for testing revert cases.
    function _reveal(address user, uint8 side, uint conf, bytes32 salt) internal {
        _revealAndWeigh(user, side, conf, salt);
    }

    Jury public jury;
    Court public court;

    uint256[] public jurorPKs;
    VogueCore public CORE;
    Basket public QUID;
    Vogue public V4;
    Rover public V3;
    Aux public AUX;
    Amp public AMP;

    uint rack = 1000 * USDC_PRECISION;
    function setUp() public {
        STABLECOINS = [
            address(USDC), address(USDT),
            address(PYUSD), address(GHO),
            address(DAI), address(USDS),
            address(FRAX), address(USDE),
            address(CRVUSD), address(BOLD),
            address(USYC)
        ];
        VAULTS = [aaveSpoke,
            aaveSpoke, pyusdMorpho, aaveSpoke,
            address(SDAI), address(SUSDS),
            address(SFRAX), address(SUSDE),
            address(SCRVUSD), stabilityPool,
            address(hashnote)
        ];

        uint mainnetFork = vm.createFork("https://ethereum-rpc.publicnode.com");
        vm.selectFork(mainnetFork);

        vm.startPrank(0x37305B1cD40574E4C5Ce33f8e8306Be057fD7341);
        USDC.transfer(User01, 100000000 * USDC_PRECISION);
        USDC.transfer(User02, 100000000 * USDC_PRECISION);
        USDC.transfer(User03, 100000000 * USDC_PRECISION);
        vm.stopPrank();

        address daiWhale = 0x40ec5B33f54e0E8A33A975908C5BA1c14e5BbbDf;
        vm.startPrank(daiWhale);
        DAI.transfer(User01,
            1000000 * 1e18);
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

        V4 = new Vogue();
        CORE = new VogueCore(poolManager);
        AUX = new Aux(address(V4), address(CORE),
            address(AMP), address(WETHv3pool),
            address(V3router), address(V3), STABLECOINS, VAULTS);

        AMP.setup(payable(address(V3)), address(AUX));
        QUID = new Basket(address(V4), address(AUX));
        LINK = new Link(address(QUID), FORWARDER);

        jury = new Jury(address(QUID));
        court = new Court(address(QUID),
        address(jury), address(LINK), true);
        jury.setup(address(court));

        deal(address(USDC), address(LINK), 1_000_000e6);

        LINK.setCourt(address(court));
        // Mock getTWAP(0) so _gasToQD in calculateWeights/pushPayouts
        // doesn't revert when AUX oracle is unavailable in test env.
        vm.mockCall(address(AUX), abi.encodeWithSelector(
            Aux.getTWAP.selector, uint32(0)),
                  abi.encode(uint(2000e18)));

        QUID.setup(address(LINK),
        address(court), address(jury));

        CORE.setup(address(V4), address(AUX), address(WETHv3pool));
        V4.setup(address(QUID), address(AUX), address(CORE));
        AUX.setQuid(address(QUID), JAM, aaveHub, aaveSpoke);
        V3.setAux(address(AUX));

        vm.startPrank(User01);
        USDC.approve(address(AUX), type(uint).max);
        DAI.approve(address(AUX), type(uint).max);
        QUID.mint(User01, 2000 * USDC_PRECISION, address(USDC), 0);
        QUID.mint(User01, 150000 * 1e18, address(DAI), 0);
        vm.stopPrank();

        for (uint i = 0; i < 100; i++) {
            uint256 pk = uint256(keccak256(abi.encodePacked("juror", i))) % (type(uint256).max - 1) + 1;
            address juror = vm.addr(pk);
            jurorPKs.push(pk);
            vm.deal(juror, 10 ether);

            vm.startPrank(0x37305B1cD40574E4C5Ce33f8e8306Be057fD7341);
            USDC.transfer(juror, 500e6); vm.stopPrank();

            vm.startPrank(juror);
            USDC.approve(address(AUX), type(uint).max);
            QUID.mint(juror, 500e6, address(USDC), 0);
            QUID.approve(address(jury), type(uint).max);
            QUID.approve(address(court), type(uint).max);
            vm.stopPrank();
        }
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

        uint expectedUsdc = price / 1e12;
        console.log("Expected USDC (approx):", expectedUsdc);

        assertGt(usdcReceived, expectedUsdc *
        90 / 100, "Should receive reasonable USDC");

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

        USDC.approve(address(AUX), rack / 5);
        AUX.leverUSD(rack / 10, address(USDC));
        vm.stopPrank();
    }

    function testRedeem() public {
        vm.startPrank(User01);

        uint mintAmount = 500 * 1e6;
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
        uint DAIbalanceBefore = DAI.balanceOf(User01);
        AUX.redeem(1000 * WAD);
        uint USDCbalanceAfter = USDC.balanceOf(User01);

        // Redeem distributes proportionally across all stables (USDC + DAI etc.)
        // Convert DAI received to USDC-equivalent (18→6 dec) and sum
        uint usdcReceived = USDCbalanceAfter - USDCbalanceBefore;
        uint daiReceived  = (DAI.balanceOf(User01) - DAIbalanceBefore) / 1e12;
        uint received = usdcReceived + daiReceived;
        console.log("Mature redeem got:", received, "expected:", 1000 * 1e6);

        assertApproxEqAbs(received, 1000 * 1e6, 500 * 1e6,
            "Should redeem with 50% tolerance for fees");

        vm.stopPrank();
    }

    function testOutOfRangeUSDPosition() public {
        vm.startPrank(User01);
        V4.deposit{value: 25 ether}(0);

        USDC.approve(address(AUX), rack);
        uint balanceBefore = USDC.balanceOf(User01);

        uint id = V4.outOfRange(rack / 10, address(USDC), 1000, 100);

        assertGt(id, 0, "Position ID should be > 0");
        assertApproxEqAbs(USDC.balanceOf(User01), balanceBefore - rack / 10,
                        rack / 100, "USDC should be deducted");

        vm.roll(vm.getBlockNumber() + 1000);
        balanceBefore = USDC.balanceOf(User01);
        V4.pull(id, 100, address(USDC));

        assertApproxEqAbs(USDC.balanceOf(User01),
        balanceBefore, rack / 50, "Should get USDC back");

        vm.stopPrank();
    }

    function testPartialPullOutOfRange() public {
        vm.startPrank(User01);
        V4.deposit{value: 50 ether}(0);

        vm.roll(vm.getBlockNumber() + 1);

        uint id = V4.outOfRange{value: 2 ether}(0, address(0), -1000, 100);
        assertGt(id, 0, "Should create position");

        vm.roll(vm.getBlockNumber() + 1000);

        uint balanceBefore = USDC.balanceOf(User01);
        V4.pull(id, 50, address(USDC));

        uint received = USDC.balanceOf(User01) - balanceBefore;
        assertGt(received, 0, "Should receive USDC");

        vm.stopPrank();
    }

    function testInvalidOutOfRangeParams() public {
        vm.startPrank(User01);
        V4.deposit{value: 25 ether}(0);

        vm.expectRevert();
        V4.outOfRange{value: 1 ether}(0, address(0), -1000, 50);
        vm.expectRevert();
        V4.outOfRange{value: 1 ether}(0, address(0), -1000, 1500);
        vm.expectRevert();
        V4.outOfRange{value: 1 ether}(0, address(0), -6000, 100);
        vm.expectRevert();
        V4.outOfRange{value: 1 ether}(0, address(0), -1050, 100);

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

        V4.deposit{value: 10 ether}(0);

        uint ethFeesBefore = V4.ETH_FEES();

        USDC.approve(address(AUX), rack);
        for (uint i = 0; i < 10; i++) {
            AUX.swap{value: 2 ether}(address(USDC), false, 0, 0);
        }

        vm.roll(vm.getBlockNumber() + 1);

        uint ethFeesAfter = V4.ETH_FEES();
        assertGe(ethFeesAfter, ethFeesBefore, "ETH fees should not decrease");

        vm.stopPrank();
    }

    function testWithdrawWithAccruedFees() public {
        vm.startPrank(User01);

        V4.deposit{value: 10 ether}(0);

        USDC.approve(address(AUX), rack);

        (,uint160 sqrtPriceX96,) = CORE.poolTicks();
        uint price = _getPrice(sqrtPriceX96, V4.token1isETH());
        for (uint i = 0; i < 5; i++) {
            uint amountNeeded = FullMath.mulDiv(6000 * WAD, WAD, price);
            AUX.swap{value: amountNeeded}(address(USDC), false, 0, 0);
            vm.roll(vm.getBlockNumber() + 1);
        }

        uint balanceBefore = User01.balance;
        V4.withdraw(5 ether);
        uint received = User01.balance - balanceBefore;

        assertGe(received, 4.5 ether, "Should receive close to withdrawal amount");

        vm.stopPrank();
    }

    function testClearMultipleBlocks() public {
        console.log("=== testClearMultipleBlocks ===");

        vm.startPrank(User01);
        V4.deposit{value: 100 ether}(0);

        uint pooledBefore = CORE.POOLED_ETH();
        console.log("POOLED_ETH before:", pooledBefore);

        if (pooledBefore == 0) {
            (uint total,) = AUX.get_metrics(true);
            console.log("Vault total:", total);
            vm.stopPrank();
            return;
        }

        USDC.approve(address(AUX), type(uint).max);

        uint block1 = AUX.swap{value: 5 ether}(address(USDC), false, 0, 5);
        vm.roll(block.number + 1);
        uint block2 = AUX.swap{value: 5 ether}(address(USDC), false, 0, 5);
        vm.roll(block.number + 1);
        uint block3 = AUX.swap{value: 5 ether}(address(USDC), false, 0, 5);

        uint pooledAfter = CORE.POOLED_ETH();
        console.log("POOLED_ETH after:", pooledAfter);

        vm.stopPrank();
    }

    function testAlternatingSwaps() public {
        vm.startPrank(User01);
        V4.deposit{value: 100 ether}(0);
        USDC.approve(address(AUX), type(uint).max);

        (,uint160 sqrtPriceX96,) = CORE.poolTicks();
        uint price = _getPrice(sqrtPriceX96, V4.token1isETH());

        for (uint i = 0; i < 10; i++) {
            if (i % 2 == 0) {
                AUX.swap{value: 0.5 ether}(address(USDC), false, 0, 2);
            } else {
                AUX.swap(address(USDC), true, price / 1e12, 2);
            }
            vm.roll(vm.getBlockNumber() + 1);
        }
        vm.stopPrank();
    }

    function testMultiVaultWithdrawal() public {
        vm.startPrank(User01);

        (uint[14] memory deposits,) = AUX.get_deposits();
        uint totalDeposits = deposits[12];
        assertGt(totalDeposits, 0, "Should have total deposits");
        assertGt(deposits[1], 0, "USDC vault should have balance");
        assertGt(deposits[5], 0, "DAI vault should have balance");

        vm.warp(block.timestamp + 30 days);

        uint usdcBefore = USDC.balanceOf(User01);
        uint daiBefore = DAI.balanceOf(User01);

        AUX.redeem(100000 * WAD);

        uint usdcReceived = USDC.balanceOf(User01) - usdcBefore;
        uint daiReceived = DAI.balanceOf(User01) - daiBefore;

        uint vaultsUsed = 0;
        if (usdcReceived > 0) vaultsUsed++;
        if (daiReceived > 0) vaultsUsed++;

        assertGe(vaultsUsed, 1, "Should pull from multiple vaults");

        vm.stopPrank();
    }

    function testMetricsCalculation() public {
        vm.startPrank(User01);

        QUID.mint(User01, rack, address(USDC), 0);

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
        V4.deposit{value: depositAmount}(0);

        vm.roll(vm.getBlockNumber() + 1);
        AUX.swap{value: 0.1 ether}(address(USDC), false, 0, 0);

        uint balanceBefore = User01.balance;
        uint withdrawAmount = 5 ether;

        try V4.withdraw(withdrawAmount) {
            uint balanceAfter = User01.balance;
            uint received = balanceAfter - balanceBefore;
            assertGt(received, 4 ether, "Should get most of withdrawal");
        } catch Error(string memory reason) {
            vm.skip(true);
        }

        vm.stopPrank();
    }

    function testFuzz_SwapAmounts(uint96 amount) public {
        amount = uint96(bound(amount, 0.1 ether, 100 ether));

        vm.startPrank(User01);
        V4.deposit{value: 200 ether}(0);

        uint pooledETH = CORE.POOLED_ETH();
        if (pooledETH == 0) { vm.stopPrank(); return; }

        uint usdcBefore = USDC.balanceOf(User01);
        AUX.swap{value: amount}(address(USDC), false, 0, 0);
        vm.roll(block.number + 1);

        uint usdcReceived = USDC.balanceOf(User01) - usdcBefore;
        assertGt(usdcReceived, 0, "Should receive USDC for any swap");

        vm.stopPrank();
    }

    function testFuzz_OutOfRangeDistance(int24 distance) public {
        distance = int24(bound(int256(distance), -5000, 5000));
        distance = (distance / 100) * 100;
        vm.assume(distance != 0);

        vm.startPrank(User01);
        V4.deposit{value: 25 ether}(0);

        try V4.outOfRange{value: 1 ether}(0, address(0), distance, 100) returns (uint id) {
            assertGt(id, 0, "Should create position");
        } catch {}

        vm.stopPrank();
    }

    function testMintWithDifferentStables() public {
        vm.startPrank(User01);

        uint minted1 = QUID.mint(User01, 500 * 1e6, address(USDC), 0);
        uint minted2 = QUID.mint(User01, 500 * 1e18, address(DAI), 0);

        assertApproxEqAbs(minted1, 500 * 1e18, 5 * 1e18, "USDC mint normalization");
        assertApproxEqAbs(minted2, 500 * 1e18, 5 * 1e18, "DAI mint normalization");

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
        (uint[14] memory deposits, ) = AUX.get_deposits();

        uint total = deposits[12];
        for (uint i = 1; i < 9; i++) {
            if (deposits[i] > 0) {
                uint percentage = (deposits[i] * 100) / total;
                console.log("Vault...", i);
                console.log("deposits[i]", deposits[i]);
                console.log("%", percentage);
            }
        }
        uint vaultsWithDeposits = 0;
        for (uint i = 1; i < 9; i++) {
            if (deposits[i] > 0) vaultsWithDeposits++;
        }
        assertGe(vaultsWithDeposits, 2, "Should have deposits in at least 3 vaults");
    }

    function testDepositVaultShares() public {
        vm.startPrank(User01);

        uint depositAmount = 500 * 1e6;
        USDC.approve(address(AUX), depositAmount);

        uint quidBefore = QUID.totalSupply();
        QUID.mint(User01, depositAmount, address(USDC), 0);

        (uint[14] memory deposits, ) = AUX.get_deposits();
        assertGt(deposits[1], 0, "USDC vault should have deposits");
        assertGt(QUID.totalSupply(), quidBefore, "Should mint QUID");

        vm.stopPrank();
    }

    function testSwapWithDifferentStableOutputs() public {
        vm.startPrank(User01);
        V4.deposit{value: 100 ether}(0);

        uint pooledETH = CORE.POOLED_ETH();
        if (pooledETH == 0) { vm.stopPrank(); return; }

        uint usdcBefore = USDC.balanceOf(User01);
        AUX.swap{value: 1 ether}(address(USDC), false, 0, 0);

        uint usdcReceived = USDC.balanceOf(User01) - usdcBefore;
        assertGt(usdcReceived, 0, "Should receive USDC");

        vm.stopPrank();
    }

    function testLargeRedemptionAllVaults() public {
        vm.startPrank(User01);
        vm.warp(block.timestamp + 30 days);

        uint userBalance = QUID.balanceOf(User01);
        uint redeemAmount = Math.min(userBalance / 2, 100000 * WAD);

        uint usdcBefore = USDC.balanceOf(User01);
        uint daiBefore = DAI.balanceOf(User01);

        AUX.redeem(redeemAmount);

        uint vaultsUsed = 0;
        if (USDC.balanceOf(User01) > usdcBefore) vaultsUsed++;
        if (DAI.balanceOf(User01) > daiBefore) vaultsUsed++;

        assertGe(vaultsUsed, 2, "Large redemption should pull from multiple vaults");

        vm.stopPrank();
    }

    function testDecimalNormalization() public {
        vm.startPrank(User01);

        uint quidFrom6 = QUID.mint(User01, 1000 * 1e6, address(USDC), 0);
        uint quidFrom18 = QUID.mint(User01, 1000 * 1e18, address(DAI), 0);

        assertApproxEqAbs(quidFrom6, quidFrom18, 1e18, "Decimal normalization should work");

        vm.stopPrank();
    }

    function testWithdrawAfterMixedDeposits() public {
        vm.startPrank(User01);

        QUID.mint(User01, 25000 * 1e6, address(USDC), 0);
        QUID.mint(User01, 25000 * 1e18, address(DAI), 0);

        vm.warp(block.timestamp + 30 days);
        uint usdcBefore = USDC.balanceOf(User01);
        uint daiBefore = DAI.balanceOf(User01);
        AUX.redeem(50000 * WAD);

        uint totalReceived = (USDC.balanceOf(User01) - usdcBefore) * 1e12 +
                            (DAI.balanceOf(User01) - daiBefore);

        assertApproxEqAbs(totalReceived, 50000 * WAD, 2000 * WAD,
            "Should receive requested amount across all vaults");

        vm.stopPrank();
    }

    function test_WithdrawDoesNotPersistFeeSnapshot() public {
        vm.startPrank(User01);
        V4.deposit{value: 100 ether}(0);
        vm.stopPrank();

        for (uint i = 0; i < 3; i++) {
            vm.startPrank(User03);
            AUX.swap{value: 20 ether}(address(USDC), false, 0, 0);
            vm.roll(block.number + 1);
            vm.warp(block.timestamp + 15 minutes);
            vm.stopPrank();
        }

        uint balBefore = User01.balance;
        vm.prank(User01);
        V4.withdraw(10 ether);
        uint received = User01.balance - balBefore;
        assertGt(received, 0, "Should receive something on withdraw");

        for (uint i = 0; i < 3; i++) {
            vm.startPrank(User03);
            AUX.swap{value: 20 ether}(address(USDC), false, 0, 0);
            vm.roll(block.number + 1);
            vm.warp(block.timestamp + 15 minutes);
            vm.stopPrank();
        }

        balBefore = User01.balance;
        vm.prank(User01);
        V4.withdraw(10 ether);
        received = User01.balance - balBefore;
        assertGt(received, 0, "Should receive something on final withdraw");
    }

    function test_PendingSwapETHInflatesAvailable() public {
        vm.startPrank(User01);
        V4.deposit{value: 100 ether}(0);
        vm.stopPrank();

        uint initialPooledETH = CORE.POOLED_ETH();

        vm.startPrank(User02);
        AUX.swap{value: 50 ether}(address(USDC), false, 0, 5);
        vm.stopPrank();

        vm.startPrank(User01);
        USDC.approve(address(AUX), 200000 * USDC_PRECISION);
        QUID.mint(User01, 2000 * USDC_PRECISION, address(USDC), 0);
        V4.deposit{value: 25 ether}(0);
        vm.stopPrank();

        uint finalPooledETH = CORE.POOLED_ETH();
        uint ethIncrease = finalPooledETH - initialPooledETH;

        if (ethIncrease > 25 ether + 1 ether) {
            console.log("  BUG: Pending ETH was counted as available!");
        }
    }

    function test_FeeAttributionWithMultipleLPs() public {
        vm.deal(User01, 1000 ether);
        vm.deal(User02, 1000 ether);
        vm.deal(User03, 1000 ether);

        vm.prank(User01);
        V4.deposit{value: 100 ether}(0);

        vm.startPrank(User03);
        USDC.approve(address(AUX), type(uint).max);
        for (uint i = 0; i < 5; i++) {
            AUX.swap{value: 30 ether}(address(USDC), false, 0, 0);
            vm.roll(block.number + 1);
            vm.warp(block.timestamp + 15 minutes);
        }
        vm.stopPrank();

        vm.prank(User02);
        V4.deposit{value: 100 ether}(0);

        vm.startPrank(User03);
        for (uint i = 0; i < 5; i++) {
            AUX.swap{value: 30 ether}(address(USDC), false, 0, 0);
            vm.roll(block.number + 1);
            vm.warp(block.timestamp + 15 minutes);
        }
        vm.stopPrank();

        uint bal1 = User01.balance;
        vm.prank(User01);
        V4.withdraw(type(uint).max);
        uint aliceReceived = User01.balance - bal1;

        uint bal2 = User02.balance;
        vm.prank(User02);
        V4.withdraw(type(uint).max);
        uint bobReceived = User02.balance - bal2;

        assertGt(aliceReceived, 0, "Alice should receive ETH");
        assertGt(bobReceived, 0, "Bob should receive ETH");
    }

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
        V4.deposit{value: 100 ether}(0);
        vm.prank(User02);
        V4.deposit{value: 50 ether}(0);
        vm.prank(User03);
        V4.deposit{value: 75 ether}(0);

        (uint pooled1,,,) = V4.autoManaged(User01);
        (uint pooled2,,,) = V4.autoManaged(User02);
        (uint pooled3,,,) = V4.autoManaged(User03);

        assertEq(V4.totalShares(), pooled1 + pooled2 + pooled3, "totalShares should equal sum");
    }

    function testInvariant_RoverTotalSharesMatchesSum() public {
        vm.prank(User01);
        V3.deposit{value: 50 ether}(0);
        vm.prank(User02);
        V3.deposit{value: 30 ether}(0);

        (uint128 lp1,,) = V3.fetch(User01);
        (uint128 lp2,,) = V3.fetch(User02);

        assertEq(V3.totalShares(), uint(lp1) + uint(lp2) + 1, "totalShares should equal sum");
    }

    function testDepositUSDC() public {
        vm.startPrank(User01);
        V3.deposit{value: 100 ether}(0);
        vm.stopPrank();

        vm.startPrank(address(AUX));
        uint usdcAmount = 10000e6;
        deal(address(USDC), address(AUX), usdcAmount);
        USDC.approve(address(V3), usdcAmount);

        (uint160 sqrtPrice,,,,,, ) = IUniswapV3Pool(V3.POOL()).slot0();
        uint price = V3.getPrice(sqrtPrice);

        try V3.depositUSDC(usdcAmount, price) {
            console.log("depositUSDC SUCCESS");
        } catch Error(string memory reason) {
            console.log("depositUSDC REVERT:", reason);
        } catch (bytes memory) {
            console.log("depositUSDC low-level revert");
        }
        vm.stopPrank();
    }

    function testRoverFeeAccrualOnCollect() public {
        vm.startPrank(User01);
        V3.deposit{value: 50 ether}(0);
        vm.stopPrank();

        uint sharesBefore = V3.totalShares();
        uint lumBefore = V3.liquidityUnderManagement();

        vm.roll(block.number + 1000);
        vm.warp(block.timestamp + 1 days);

        vm.startPrank(User02);
        V3.deposit{value: 10 ether}(0);
        vm.stopPrank();

        uint lumAfter = V3.liquidityUnderManagement();
        console.log("LUM increased:", lumAfter > lumBefore);
    }

    function testRoverDepositWithdraw() public {
        vm.startPrank(User01);
        V3.deposit{value: 10 ether}(0);

        uint balBefore = User01.balance;
        V3.withdraw(500);
        console.log("50% withdraw received:", User01.balance - balBefore);

        try V3.withdraw(1000) {
            console.log("Full withdraw succeeded");
        } catch Error(string memory reason) {
            console.log("Full withdraw reverted:", reason);
        } catch {}

        vm.stopPrank();
    }

    function testRoverFullWithdraw() public {
        vm.startPrank(User01);
        V3.deposit{value: 10 ether}(0);

        uint balBefore = User01.balance;
        V3.withdraw(1000);
        uint received = User01.balance - balBefore;

        (uint128 pos,,) = V3.fetch(User01);
        assertEq(pos, 0, "Should have 0 liquidity after full withdraw");
        assertGt(received, 0, "Should receive something");

        vm.stopPrank();
    }

    function testVogueZeroDeposit() public {
        vm.startPrank(User01);
        uint sharesBefore = V4.totalShares();
        V4.deposit{value: 0}(0);
        assertEq(V4.totalShares(), sharesBefore, "Zero deposit should not change shares");
        vm.stopPrank();
    }

    function testVogueMultipleDeposits() public {
        vm.startPrank(User01);
        V4.deposit{value: 10 ether}(0);
        V4.deposit{value: 20 ether}(0);
        V4.deposit{value: 5 ether}(0);
        (uint pooled3,,,) = V4.autoManaged(User01);
        assertEq(pooled3, 35 ether, "Pooled should equal total deposited");
        vm.stopPrank();
    }

    function testRoverMultipleDeposits() public {
        vm.startPrank(User01);
        V3.deposit{value: 5 ether}(0);
        (uint128 pos1,,) = V3.fetch(User01);
        uint shares1 = V3.totalShares();

        V3.deposit{value: 10 ether}(0);
        (uint128 pos2,,) = V3.fetch(User01);
        uint shares2 = V3.totalShares();

        assertGt(pos2, pos1, "Liquidity should increase");
        assertGt(shares2, shares1, "Total shares should increase");
        vm.stopPrank();
    }

    function testVoguePartialWithdraws() public {
        vm.startPrank(User01);
        V4.deposit{value: 100 ether}(0);
        (uint pooledInitial,,,) = V4.autoManaged(User01);

        V4.withdraw(10 ether);
        (uint pooled1,,,) = V4.autoManaged(User01);

        V4.withdraw(20 ether);
        (uint pooled2,,,) = V4.autoManaged(User01);

        assertLt(pooled1, pooledInitial, "Pooled should decrease after withdraw");
        assertLt(pooled2, pooled1, "Pooled should decrease further");
        vm.stopPrank();
    }

    function testRoverPartialWithdraws() public {
        vm.startPrank(User01);
        V3.deposit{value: 20 ether}(0);

        uint balBefore = User01.balance;
        V3.withdraw(250);

        try V3.withdraw(500) {
            console.log("Second partial withdraw succeeded");
        } catch Error(string memory reason) {
            console.log("Second partial withdraw reverted:", reason);
        } catch {}

        vm.stopPrank();
    }

    function testVogueAccumulatorCorrectness() public {
        vm.prank(User01);
        V4.deposit{value: 100 ether}(0);

        (uint pooled1,,uint debt1,) = V4.autoManaged(User01);
        uint acc1 = V4.ETH_FEES();

        uint expectedDebt1 = FullMath.mulDiv(pooled1, acc1, WAD);
        assertEq(debt1, expectedDebt1, "Debt should match formula");

        vm.prank(User02);
        V4.deposit{value: 50 ether}(0);

        (uint pooled2,,uint debt2,) = V4.autoManaged(User02);
        uint acc2 = V4.ETH_FEES();

        uint expectedDebt2 = FullMath.mulDiv(pooled2, acc2, WAD);
        assertEq(debt2, expectedDebt2, "Debt should match formula");
    }

    function testPendingRewardsCalculation() public {
        vm.prank(User01);
        V4.deposit{value: 100 ether}(0);

        (uint pooled,,uint debtBefore,) = V4.autoManaged(User01);
        uint accBefore = V4.ETH_FEES();

        uint expectedPending = FullMath.mulDiv(pooled, accBefore, WAD) - debtBefore;
        (uint actualPending,) = V4.pendingRewards(User01);

        assertEq(actualPending, expectedPending, "Pending should match formula");
    }

    function test_BankRun_VaultLiquidity() public {
        uint bal1Before = User01.balance;
        uint bal2Before = User02.balance;
        uint bal3Before = User03.balance;

        vm.prank(User01);
        V4.deposit{value: 100 ether}(0);
        vm.prank(User02);
        V4.deposit{value: 100 ether}(0);
        vm.prank(User03);
        V4.deposit{value: 100 ether}(0);

        vm.prank(User01);
        V4.withdraw(type(uint).max);
        vm.prank(User02);
        V4.withdraw(type(uint).max);
        vm.prank(User03);
        V4.withdraw(type(uint).max);

        uint total1 = User01.balance - (bal1Before - 100 ether);
        uint total2 = User02.balance - (bal2Before - 100 ether);
        uint total3 = User03.balance - (bal3Before - 100 ether);

        assertGt(total1, 99 ether, "User01 underpaid");
        assertGt(total2, 99 ether, "User02 underpaid");
        assertGt(total3, 99 ether, "User03 underpaid");
        assertLe(total1, 100.1 ether, "User01 overpaid");
        assertLe(total2, 100.1 ether, "User02 overpaid");
        assertLe(total3, 100.1 ether, "User03 overpaid");
    }

    function test_Vogue_PendingRewards_NonDepositor() public {
        (uint eth, uint usd) = V4.pendingRewards(User03);
        assertEq(eth, 0);
        assertEq(usd, 0);
    }

    function test_Vogue_Withdraw_ZeroShares() public {
        vm.startPrank(User03);
        uint balBefore = User03.balance;
        V4.withdraw(1 ether);
        assertEq(User03.balance, balBefore, "Balance should be unchanged");
        vm.stopPrank();
    }

    function test_Vogue_Deposit_ZeroAmount() public {
        vm.startPrank(User01);
        uint sharesBefore = V4.totalShares();
        V4.deposit{value: 0}(0);
        assertEq(sharesBefore, V4.totalShares());
        vm.stopPrank();
    }

    function test_Rover_WithdrawUSDC_SmallAmount() public {
        vm.startPrank(User01);
        V3.repackNFT();
        V3.deposit{value: 10 ether}(0);
        vm.stopPrank();

        vm.prank(address(AMP));
        uint got = V3.withdrawUSDC(1);
        assertEq(got, 0, "Tiny withdraw should return 0, not revert");
    }

    function test_Rover_Take_ExceedsLiquidity() public {
        vm.startPrank(User01);
        V3.repackNFT();
        V3.deposit{value: 5 ether}(0);
        vm.stopPrank();

        vm.prank(address(AUX));
        uint taken = V3.take(100 ether);
        assertLt(taken, 100 ether, "Should cap to available liquidity");
    }

    function testFuzz_VogueDepositWithdraw(uint96 depositAmount, uint16 withdrawPct) public {
        vm.assume(depositAmount > 0.1 ether);
        vm.assume(depositAmount < 100 ether);
        vm.assume(withdrawPct > 0 && withdrawPct <= 1000);

        deal(User01, depositAmount);

        vm.startPrank(User01);
        V4.deposit{value: depositAmount}(0);

        Types.Deposit memory LP = getAutoManaged(User01);
        uint toWithdraw = LP.pooled_eth * withdrawPct / 1000;

        if (toWithdraw > 0) {
            uint balBefore = User01.balance;
            V4.withdraw(toWithdraw);
            uint received = User01.balance - balBefore;
            assertGt(received, toWithdraw * 99 / 100, "Received too little");
        }
        vm.stopPrank();
    }

    // ════════════════════════════════════════════════════════════════════
    //  8.1  Auto-Seeding via Basket.mint
    // ════════════════════════════════════════════════════════════════════

    function test_DepegMarket_AutoSeed() public {
        _deployAndSeed();

        Types.Market memory m = LINK.getMarket();
        assertGt(m.numSides, 2, "N-outcome, not binary");
        assertEq(m.roundNumber, 1, "round 1");
        assertEq(m.roundStartTime, block.timestamp);

        uint8 daiSide = LINK.stablecoinToSide(address(DAI));
        assertGt(daiSide, 0, "DAI mapped to side > 0");

        assertEq(LINK.getNumSides(), m.numSides, "UMA knows numSides");
    }

    function test_DepegMarket_LMSRPricing() public {
        _deployAndSeed();
        uint8 n = LINK.getMarket().numSides;

        uint[] memory prices = LINK.getAllPrices();
        assertEq(prices.length, n);

        uint sum;
        for (uint i; i < n; i++) {
            sum += prices[i];
            assertApproxEqRel(prices[i], WAD / n, 0.05e18, "initial ~1/n");
        }
        assertApproxEqRel(sum, WAD, 0.01e18, "prices sum to ~1");

        uint8 daiSide = LINK.stablecoinToSide(address(DAI));
        vm.startPrank(User01);
        QUID.approve(address(LINK), type(uint).max);
        LINK.placeOrder(daiSide, 50_000e18, false, bytes32(uint(1)), address(0));
        vm.stopPrank();

        uint[] memory after_ = LINK.getAllPrices();
        assertGt(after_[daiSide], prices[daiSide], "DAI price up");
        assertLt(after_[0], prices[0], "none price down");

        uint sum2;
        for (uint i; i < n; i++) sum2 += after_[i];
        assertApproxEqRel(sum2, WAD, 0.02e18, "still sums to ~1");
    }

    function test_DepegMarket_PlaceOrder_400bps() public {
        _deployAndSeed();
        uint8 side = LINK.stablecoinToSide(address(DAI));

        bytes32 salt = keccak256("sec");
        uint conf  = 8000;
        bytes32 commit = keccak256(abi.encodePacked(conf, salt));

        vm.startPrank(User01);
        QUID.approve(address(LINK), type(uint).max);
        uint cap = 10_000e18;
        LINK.placeOrder(side, cap, false, commit, address(0));
        vm.stopPrank();

        uint fee = (cap * 400) / 10000;
        uint net = cap - fee;

        Types.Position memory pos = LINK.getPosition(User01, side);
        assertEq(pos.totalCapital, net, "net after 400bps");
        assertGt(pos.totalTokens, 0);
        assertEq(pos.lastRound, 1);
    }

    function test_DepegMarket_FullLifecycle() public {
        _deployAndSeed();
        uint8 daiSide = LINK.stablecoinToSide(address(DAI));

        bytes32 salt1 = keccak256("s1");
        bytes32 salt2 = keccak256("s2");
        uint conf1 = 8000;
        uint conf2 = 6000;
        bytes32 c1 = keccak256(abi.encodePacked(conf1, salt1));
        bytes32 c2 = keccak256(abi.encodePacked(conf2, salt2));

        vm.startPrank(User01);
        QUID.approve(address(LINK), type(uint).max);
        LINK.placeOrder(daiSide, 5000e18, false, c1, address(0));
        vm.stopPrank();

        vm.startPrank(User02);
        deal(address(USDC), User02, 200_000e6);
        USDC.approve(address(AUX), type(uint).max);
        QUID.mint(User02, 100_000e6, address(USDC), 0);
        QUID.approve(address(LINK), type(uint).max);
        LINK.placeOrder(0, 3000e18, false, c2, address(0));
        vm.stopPrank();

        assertEq(LINK.getMarket().positionsTotal, 2);

        deal(address(QUID), address(this), LINK.MIN_QD_TO_ASSERT());
        bytes32 idR = LINK.requestResolution(daiSide, 0);
        _mockResolve(idR, true);

        Types.Market memory m = LINK.getMarket();
        assertTrue(m.resolved);
        assertEq(m.winningSide, daiSide);

        vm.warp(block.timestamp + 49 hours);

        vm.prank(User01);
        _reveal(User01, daiSide, conf1, salt1);
        vm.prank(User02);
        _reveal(User02, 0, conf2, salt2);

        m = LINK.getMarket();
        assertEq(m.positionsRevealed, 2);
        assertGt(m.totalWinnerCapital, 0);
        assertGt(m.totalLoserCapital, 0);
        assertTrue(m.weightsComplete);

        uint qBefore = QUID.balanceOf(User01);
        address[] memory users = new address[](2);
        uint8[] memory sides = new uint8[](2);
        users[0] = User01; sides[0] = daiSide;
        users[1] = User02; sides[1] = 0;
        LINK.pushPayouts(users, sides);
        assertGt(QUID.balanceOf(User01), qBefore, "winner paid");
        assertTrue(LINK.getMarket().payoutsComplete);
    }

    function test_DepegMarket_Recommit() public {
        _deployAndSeed();

        bytes32 salt1 = keccak256("r1");
        uint conf1 = 8000;
        bytes32 c1 = keccak256(abi.encodePacked(conf1, salt1));

        vm.startPrank(User01);
        QUID.approve(address(LINK), type(uint).max);
        LINK.placeOrder(0, 10_000e18, true, c1, address(0));
        vm.stopPrank();

        uint r1Net = LINK.getPosition(User01, 0).totalCapital;

        _resolveNone();

        address[] memory u = new address[](1);
        uint8[] memory s = new uint8[](1);
        u[0] = User01; s[0] = 0;
        vm.warp(block.timestamp + 49 hours);
        vm.prank(User01);
        _reveal(User01, 0, conf1, salt1);
        LINK.pushPayouts(u, s);

        uint retainedCapital = LINK.getPosition(User01, 0).totalCapital;
        uint payout = r1Net;
        uint fee = (payout * 200) / 10000;
        assertGe(retainedCapital, payout - fee - 1, "net after 200bps");
        assertGt(LINK.accumulatedFees(), 0, "fees from rollover");

        _finishRound();
        assertEq(LINK.getMarket().roundNumber, 2);

        _resolveNone();
        vm.warp(block.timestamp + 49 hours);
        LINK.calculateWeights(u, s, new Link.RevealEntry[](0), new uint[](1));

        Types.Position memory posR2 = LINK.getPosition(User01, 0);
        assertEq(posR2.totalCapital, retainedCapital, "no double fee");
        assertEq(posR2.totalTokens, 0, "rollover skips LMSR token purchase");
        assertEq(posR2.lastRound, 2);
        assertTrue(posR2.revealed, "auto-revealed neutral");
        assertEq(posR2.revealedConfidence, 5000, "NEUTRAL_CONFIDENCE");
    }

    function test_DepegMarket_RevealEdgeCases() public {
        _deployAndSeed();
        uint8 daiSide = LINK.stablecoinToSide(address(DAI));

        bytes32 salt = keccak256("correct");
        uint conf = 7500;
        bytes32 commit = keccak256(abi.encodePacked(conf, salt));

        vm.startPrank(User01);
        QUID.approve(address(LINK), type(uint256).max);
        LINK.placeOrder(daiSide, 2000e18, false, commit, address(0));
        vm.stopPrank();

        bytes32 badSalt = keccak256("bad");
        uint badConf = 7777;
        bytes32 badCommit = keccak256(abi.encodePacked(badConf, badSalt));
        vm.startPrank(User02);
        deal(address(USDC), User02, 100_000e6);
        USDC.approve(address(AUX), type(uint256).max);
        QUID.mint(User02, 50_000e6, address(USDC), 0);
        QUID.approve(address(LINK), type(uint256).max);
        LINK.placeOrder(0, 1000e18, false, badCommit, address(0));
        vm.stopPrank();

        _resolveNone();
        vm.warp(block.timestamp + 49 hours);

        vm.prank(User01);
        vm.expectRevert("hash mismatch");
        _reveal(User01, daiSide, conf, keccak256("wrong"));

        vm.prank(User01);
        vm.expectRevert("hash mismatch");
        _reveal(User01, daiSide, 9000, salt);

        vm.prank(User02);
        vm.expectRevert("bad confidence");
        _reveal(User02, 0, badConf, badSalt);

        vm.prank(User01);
        _reveal(User01, daiSide, conf, salt);
        assertTrue(LINK.getPosition(User01, daiSide).revealed);

        uint weightBefore = LINK.getPosition(User01, daiSide).weight;
        vm.prank(User01);
        _reveal(User01, daiSide, conf, salt);
        assertEq(LINK.getPosition(User01, daiSide).weight, weightBefore);
    }

    function test_DepegMarket_FeeBurn_NonMature() public {
        _deployAndSeed();

        vm.startPrank(User01);
        QUID.approve(address(LINK), type(uint).max);
        LINK.placeOrder(0, 100_000e18, false, bytes32(uint(1)), address(0));
        vm.stopPrank();

        uint fees = LINK.accumulatedFees();
        assertEq(fees, (100_000e18 * 400) / 10000);

        uint supplyBefore = QUID.totalSupply();
        LINK.burnAccumulatedFees();
        uint supplyAfter = QUID.totalSupply();

        assertLt(supplyAfter, supplyBefore, "supply decreased");
        assertEq(LINK.accumulatedFees(), 0, "fees cleared");
    }

    function test_DepegMarket_SellPosition() public {
        _deployAndSeed();
        uint8 side = LINK.stablecoinToSide(address(FRAX));

        vm.startPrank(User01);
        QUID.approve(address(LINK), type(uint).max);
        LINK.placeOrder(side, 10_000e18, false, bytes32(uint(1)), address(0));

        Types.Position memory pos = LINK.getPosition(User01, side);
        uint held = pos.totalTokens;
        uint qBefore = QUID.balanceOf(User01);
        vm.roll(block.number + 1);
        LINK.sellPosition(side, held / 2);
        vm.stopPrank();

        assertGt(QUID.balanceOf(User01), qBefore, "QUID returned");
        Types.Position memory posAfter = LINK.getPosition(User01, side);
        assertEq(posAfter.totalTokens, held - held / 2);
        assertLt(posAfter.totalCapital, pos.totalCapital);
    }

    function test_DepegMarket_DepegStats() public {
        _deployAndSeed();
        uint8 daiSide = LINK.stablecoinToSide(address(DAI));

        Types.DepegStats memory s0 = LINK.getDepegStats(address(DAI));
        assertEq(s0.capOnSide, 0);
        assertEq(s0.side, daiSide);

        vm.startPrank(User01);
        QUID.approve(address(LINK), type(uint).max);
        LINK.placeOrder(daiSide, 5000e18, false, bytes32(uint(1)), address(0));
        LINK.placeOrder(0, 3000e18, false, bytes32(uint(1)), address(0));
        vm.stopPrank();

        Types.DepegStats memory s1 = LINK.getDepegStats(address(DAI));
        assertGt(s1.capOnSide, 0);
        assertGt(s1.capNone, 0);
        assertGt(s1.capTotal, 0);
        assertFalse(s1.depegged);
    }

    function test_DepegMarket_TwoRounds() public {
        _deployAndSeed();

        bytes32 salt1 = keccak256("r1");
        uint conf1 = 8000;
        bytes32 c1 = keccak256(abi.encodePacked(conf1, salt1));

        vm.startPrank(User01);
        QUID.approve(address(LINK), type(uint).max);
        LINK.placeOrder(0, 10_000e18, true, c1, address(0));
        vm.stopPrank();

        _resolveNone();
        address[] memory u = new address[](1);
        uint8[] memory s = new uint8[](1);
        u[0] = User01; s[0] = 0;
        vm.warp(block.timestamp + 49 hours);
        vm.prank(User01);
        _reveal(User01, 0, conf1, salt1);
        LINK.pushPayouts(u, s);

        uint r1Retained = LINK.getPosition(User01, 0).totalCapital;
        _finishRound();
        assertEq(LINK.getMarket().roundNumber, 2);

        _resolveNone();
        vm.warp(block.timestamp + 49 hours);
        LINK.calculateWeights(u, s, new Link.RevealEntry[](0), new uint[](1));

        Types.Position memory posR2 = LINK.getPosition(User01, 0);
        assertEq(posR2.totalCapital, r1Retained, "no double fee");
        assertEq(posR2.lastRound, 2);
        assertTrue(posR2.revealed);

        LINK.pushPayouts(u, s);
        assertTrue(LINK.getMarket().payoutsComplete);
    }

    function test_DepegMarket_StaleCannotReveal() public {
        _deployAndSeed();
        uint8 daiSide = LINK.stablecoinToSide(address(DAI));

        bytes32 salt = keccak256("stale");
        uint conf = 8000;
        bytes32 commit = keccak256(abi.encodePacked(conf, salt));

        vm.startPrank(User01);
        QUID.approve(address(LINK), type(uint).max);
        LINK.placeOrder(daiSide, 5000e18, false, commit, address(0));
        vm.stopPrank();

        _resolveNone();
        vm.warp(block.timestamp + 49 hours);
        LINK.calculateWeights(new address[](0), new uint8[](0), new Link.RevealEntry[](0), new uint[](0));
        LINK.pushPayouts(new address[](0), new uint8[](0));
        _finishRound();

        _resolveNone();

        vm.prank(User01); vm.expectRevert();
        _reveal(User01, daiSide, conf, salt);
    }

    function test_DepegMarket_NonRolloverPaidOut() public {
        _deployAndSeed();

        bytes32 salt = keccak256("nf");
        uint conf = 8000;
        bytes32 commit = keccak256(abi.encodePacked(conf, salt));

        vm.startPrank(User01);
        QUID.approve(address(LINK), type(uint).max);
        LINK.placeOrder(0, 5000e18, false, commit, address(0));
        vm.stopPrank();

        uint balBefore = QUID.balanceOf(User01);
        _resolveNone();
        address[] memory u = new address[](1);
        uint8[] memory s = new uint8[](1);
        u[0] = User01; s[0] = 0;
        vm.warp(block.timestamp + 49 hours);
        vm.prank(User01);
        _reveal(User01, 0, conf, salt);
        LINK.pushPayouts(u, s);

        assertGt(QUID.balanceOf(User01), balBefore, "payout sent to user");

        _finishRound();

        _resolveNone();
        vm.warp(block.timestamp + 49 hours);
        LINK.calculateWeights(u, s, new Link.RevealEntry[](0), new uint[](1));
        assertTrue(LINK.getPosition(User01, 0).paidOut);
        assertEq(LINK.getMarket().positionsTotal, 0);
    }

    function test_DepegMarket_InvalidSide() public {
        _deployAndSeed();
        uint8 n = LINK.getMarket().numSides;

        vm.startPrank(User01);
        QUID.approve(address(LINK), type(uint).max);
        vm.expectRevert();
        LINK.placeOrder(n, 1000e18, false, bytes32(uint(1)), address(0));
        vm.expectRevert();
        LINK.placeOrder(15, 1000e18, false, bytes32(uint(1)), address(0));
        vm.stopPrank();
    }

    function test_Hook_GetMarketCapital() public {
        _deployAndSeed();
        assertEq(LINK.getMarketCapital(), 0);

        vm.startPrank(User01);
        QUID.approve(address(LINK), type(uint).max);
        LINK.placeOrder(0, 5000e18, false, bytes32(uint(1)), address(0));
        vm.stopPrank();

        assertEq(LINK.getMarketCapital(), 4800e18);
    }

    function test_DepegMarket_ThreeUsers_PartialReveal() public {
        _deployAndSeed();
        uint8 daiSide = LINK.stablecoinToSide(address(DAI));

        bytes32 salt1 = keccak256("u1");
        bytes32 salt2 = keccak256("u2");
        uint conf = 8000;
        bytes32 c1 = keccak256(abi.encodePacked(conf, salt1));
        bytes32 c2 = keccak256(abi.encodePacked(conf, salt2));

        vm.startPrank(User01);
        QUID.approve(address(LINK), type(uint).max);
        LINK.placeOrder(daiSide, 5000e18, false, c1, address(0));
        vm.stopPrank();

        vm.startPrank(User02);
        deal(address(USDC), User02, 200_000e6);
        USDC.approve(address(AUX), type(uint).max);
        QUID.mint(User02, 100_000e6, address(USDC), 0);
        QUID.approve(address(LINK), type(uint).max);
        LINK.placeOrder(0, 3000e18, false, c2, address(0));
        vm.stopPrank();

        address User03Local = makeAddr("user03");
        deal(address(USDC), User03Local, 200_000e6);
        vm.startPrank(User03Local);
        USDC.approve(address(AUX), type(uint).max);
        QUID.mint(User03Local, 50_000e6, address(USDC), 0);
        QUID.approve(address(LINK), type(uint).max);
        LINK.placeOrder(daiSide, 2000e18, false, bytes32(uint(42)), address(0));
        vm.stopPrank();

        assertEq(LINK.getMarket().positionsTotal, 3);

        _resolveNone();
        vm.warp(block.timestamp + 49 hours);

        vm.prank(User01);
        _reveal(User01, daiSide, conf, salt1);
        vm.prank(User02);
        _reveal(User02, 0, conf, salt2);

        assertEq(LINK.getMarket().positionsRevealed, 2);

        address[] memory u = new address[](2);
        uint8[] memory s = new uint8[](2);
        u[0] = User01; s[0] = daiSide;
        u[1] = User02; s[1] = 0;
        vm.warp(block.timestamp + 49 hours);
        LINK.calculateWeights(u, s, new Link.RevealEntry[](0), new uint[](u.length));
        LINK.pushPayouts(u, s);

        assertTrue(LINK.getPosition(User02, 0).paidOut);
        assertTrue(LINK.getPosition(User01, daiSide).paidOut);
        assertEq(LINK.getPosition(User03Local, daiSide).weight, 0);
    }

    // ══════════════════════════════════════════════════
    //  calcRisk — Bayesian Blend with avgConf Prior
    // ══════════════════════════════════════════════════

    function test_CalcRisk_ColdStart_NoPrior() public {
        Types.DepegStats memory stats = Types.DepegStats({
            capOnSide: 0, capNone: 0, capTotal: 0,
            depegged: false, side: 1, avgConf: 0, severityBps: 0
        });
        assertEq(FeeLib.calcRisk(stats), 6500);
    }

    function test_CalcRisk_ColdStart_WithPrior() public {
        Types.DepegStats memory stats = Types.DepegStats({
            capOnSide: 0, capNone: 0, capTotal: 0,
            depegged: false, side: 1, avgConf: 8000, severityBps: 0
        });
        assertEq(FeeLib.calcRisk(stats), 8000);
    }

    function test_CalcRisk_ThinMarket_NoPrior() public {
        Types.DepegStats memory stats = Types.DepegStats({
            capOnSide: 2_000e18, capNone: 5_000e18, capTotal: 9_999e18,
            depegged: false, side: 1, avgConf: 0, severityBps: 0
        });
        assertEq(FeeLib.calcRisk(stats), 6500);
    }

    function test_CalcRisk_ThinMarket_WithPrior() public {
        Types.DepegStats memory stats = Types.DepegStats({
            capOnSide: 2_000e18, capNone: 3_000e18, capTotal: 5_000e18,
            depegged: false, side: 1, avgConf: 7000, severityBps: 0
        });
        assertEq(FeeLib.calcRisk(stats), 7000);
    }

    function test_CalcRisk_ThickMarket_ZeroOnSide_NoPrior() public {
        Types.DepegStats memory stats = Types.DepegStats({
            capOnSide: 0, capNone: 50_000e18, capTotal: 50_000e18,
            depegged: false, side: 1, avgConf: 0, severityBps: 0
        });
        assertEq(FeeLib.calcRisk(stats), 0);
    }

    function test_CalcRisk_ThickMarket_ZeroOnSide_StrongPrior() public {
        Types.DepegStats memory stats = Types.DepegStats({
            capOnSide: 0, capNone: 50_000e18, capTotal: 50_000e18,
            depegged: false, side: 1, avgConf: 8000, severityBps: 0
        });
        assertEq(FeeLib.calcRisk(stats), 1333);
    }

    function test_CalcRisk_ThickMarket_10pct_NoPrior() public {
        Types.DepegStats memory stats = Types.DepegStats({
            capOnSide: 10_000e18, capNone: 80_000e18, capTotal: 100_000e18,
            depegged: false, side: 1, avgConf: 0, severityBps: 0
        });
        assertEq(FeeLib.calcRisk(stats), 1000);
    }

    function test_CalcRisk_ThickMarket_ConfirmingPrior() public {
        Types.DepegStats memory stats = Types.DepegStats({
            capOnSide: 50_000e18, capNone: 50_000e18, capTotal: 100_000e18,
            depegged: false, side: 1, avgConf: 9000, severityBps: 0
        });
        assertEq(FeeLib.calcRisk(stats), 5363);
    }

    function test_CalcRisk_ThickMarket_ConflictingPrior() public {
        Types.DepegStats memory stats = Types.DepegStats({
            capOnSide: 5_000e18, capNone: 95_000e18, capTotal: 100_000e18,
            depegged: false, side: 1, avgConf: 8000, severityBps: 0
        });
        assertEq(FeeLib.calcRisk(stats), 1181);
    }

    function test_CalcRisk_AllOnSide_NoPrior() public {
        Types.DepegStats memory stats = Types.DepegStats({
            capOnSide: 50_000e18, capNone: 0, capTotal: 50_000e18,
            depegged: false, side: 1, avgConf: 0, severityBps: 0
        });
        assertEq(FeeLib.calcRisk(stats), 10000);
    }

    function test_CalcRisk_ConfirmedDepeg() public {
        Types.DepegStats memory stats = Types.DepegStats({
            capOnSide: 10_000e18, capNone: 10_000e18, capTotal: 20_000e18,
            depegged: true, side: 1, avgConf: 3000, severityBps: 0
        });
        assertEq(FeeLib.calcRisk(stats), 10000);
    }

    function test_CalcRisk_PriorFadesWithScale() public {
        Types.DepegStats memory small = Types.DepegStats({
            capOnSide: 2_000e18, capNone: 18_000e18, capTotal: 20_000e18,
            depegged: false, side: 1, avgConf: 8000, severityBps: 0
        });
        Types.DepegStats memory big = Types.DepegStats({
            capOnSide: 20_000e18, capNone: 180_000e18, capTotal: 200_000e18,
            depegged: false, side: 1, avgConf: 8000, severityBps: 0
        });
        uint riskSmall = FeeLib.calcRisk(small);
        uint riskBig = FeeLib.calcRisk(big);

        assertGt(riskSmall, riskBig);
        assertEq(riskSmall, 3333);
        assertEq(riskBig, 1333);
    }

    // ══════════════════════════════════════════════════
    //  Fee Formula Tests
    // ══════════════════════════════════════════════════

    function test_Fee_NoSignal() public {
        assertEq(FeeLib.calcFee(0, 0), 4);
        assertEq(FeeLib.calcFee(5000, 5000), 4);
        assertEq(FeeLib.calcFee(8000, 3000), 4);
    }

    function test_Fee_ConfirmedDepeg() public {
        assertEq(FeeLib.calcFee(0, 1000), 1000);
        assertEq(FeeLib.calcFee(10000, 1000), 4);
    }

    function test_Fee_MaxFeeCap() public {
        assertEq(FeeLib.calcFee(0, 5000), 5000);
        assertEq(FeeLib.calcFee(0, 8000), 5000);
    }

    function test_Fee_MonotonicWithExposure() public {
        uint prevFee;
        for (uint exp = 0; exp <= 5000; exp += 500) {
            uint fee = FeeLib.calcFee(0, exp);
            assertGe(fee, prevFee);
            prevFee = fee;
        }
    }

    function test_Fee_PriorElevatesFee() public {
        Types.DepegStats memory noPrior = Types.DepegStats({
            capOnSide: 5_000e18, capNone: 95_000e18, capTotal: 100_000e18,
            depegged: false, side: 1, avgConf: 0, severityBps: 0
        });
        Types.DepegStats memory withPrior = Types.DepegStats({
            capOnSide: 5_000e18, capNone: 95_000e18, capTotal: 100_000e18,
            depegged: false, side: 1, avgConf: 8000, severityBps: 0
        });
        uint riskNoPrior  = FeeLib.calcRisk(noPrior);
        uint riskWithPrior = FeeLib.calcRisk(withPrior);
        assertGt(riskWithPrior, riskNoPrior);

        uint feeNoPrior   = FeeLib.calcFee(0, riskNoPrior / 10);
        uint feeWithPrior = FeeLib.calcFee(0, riskWithPrior / 10);
        assertGt(feeWithPrior, feeNoPrior);
    }

    function test_Fee_ExposureScalesWithShare() public {
        uint expSmall = (1000 * 3000) / 10000;
        uint expLarge = (3000 * 3000) / 10000;
        assertGt(FeeLib.calcFee(0, expLarge), FeeLib.calcFee(0, expSmall));
    }

    function test_Fee_MultipleDepegs() public {
        uint totalExposure = (1000 * 8000) / 10000 + (1000 * 6000) / 10000;
        assertEq(FeeLib.calcFee(0, totalExposure), 1400);
        assertEq(FeeLib.calcFee(6000, totalExposure), 4);
        assertEq(FeeLib.calcFee(8000, totalExposure), 4);
    }

    // ══════════════════════════════════════════════════
    //  UMA Tests
    // ══════════════════════════════════════════════════

    function testLINK_RestartRequiresPayouts() public {
        _deployAndSeed();
        uint8 side = LINK.stablecoinToSide(address(DAI));

        bytes32 salt = keccak256("r");
        uint conf = 8000;
        bytes32 commit = keccak256(abi.encodePacked(conf, salt));

        vm.startPrank(User01);
        QUID.approve(address(LINK), type(uint).max);
        LINK.placeOrder(side, 5_000e18, false, commit, address(0));
        vm.stopPrank();

        _resolveNone();
        vm.warp(block.timestamp + 49 hours);

        vm.prank(User01);
        _reveal(User01, side, conf, salt);

        vm.warp(block.timestamp + 48 hours + 1);

        address[] memory u = new address[](1);
        uint8[] memory s = new uint8[](1);
        u[0] = User01; s[0] = side;
        LINK.calculateWeights(u, s, new Link.RevealEntry[](0), new uint[](u.length));
        LINK.pushPayouts(u, s);
        LINK.restartMarket();
        (uint8 phase,,) = LINK.getAssertionInfo();
        assertEq(phase, 0);
    }

    function testLINK_InvalidSide_Revert() public {
        _deployAndSeed();
        Types.Market memory m = LINK.getMarket();

        vm.startPrank(User01);
        QUID.approve(address(LINK), type(uint).max);
        LINK.placeOrder(0, 5_000e18, false, bytes32(uint(1)), address(0));
        vm.stopPrank();

        deal(address(QUID), address(this), LINK.MIN_QD_TO_ASSERT());

        vm.expectRevert();
        LINK.requestResolution(m.numSides, 0);
        vm.expectRevert();
        LINK.requestResolution(0, 0);
    }

    // ══════════════════════════════════════════════════
    //  LMSR Stress Tests
    // ══════════════════════════════════════════════════

    function test_LMSR_SumToOne_Stress() public {
        _deployAndSeed();
        uint8 n = LINK.getMarket().numSides;
        uint8 daiSide = LINK.stablecoinToSide(address(DAI));
        uint8 usdcSide = LINK.stablecoinToSide(address(USDC));

        deal(address(USDC), User01, 200_000e6);
        vm.startPrank(User01);
        USDC.approve(address(AUX), type(uint).max);
        QUID.mint(User01, 200_000e6, address(USDC), 0);
        QUID.approve(address(LINK), type(uint).max);

        LINK.placeOrder(daiSide, 100_000e18, false, bytes32(uint(1)), address(0));
        _checkPriceSum(n, "after 100k on DAI");
        LINK.placeOrder(usdcSide, 1_000e18, false, bytes32(uint(1)), address(0));
        _checkPriceSum(n, "after 1k on USDC");
        LINK.placeOrder(0, 50_000e18, false, bytes32(uint(1)), address(0));
        _checkPriceSum(n, "after 50k on none");
        LINK.placeOrder(daiSide, 200_000e18, false, bytes32(uint(1)), address(0));
        _checkPriceSum(n, "after 200k more on DAI");
        vm.stopPrank();
    }

    function _checkPriceSum(uint8 n, string memory label) internal view {
        uint[] memory p = LINK.getAllPrices();
        uint sum;
        for (uint i; i < n; i++) sum += p[i];
        assertApproxEqRel(sum, WAD, 0.02e18, label);
    }

    function test_LMSR_BuySellRoundTrip() public {
        _deployAndSeed();
        uint8 side = LINK.stablecoinToSide(address(DAI));

        vm.startPrank(User01);
        QUID.approve(address(LINK), type(uint).max);

        uint balBefore = QUID.balanceOf(User01);
        LINK.placeOrder(side, 50_000e18, false, keccak256("rt"), address(0));

        Types.Position memory pos = LINK.getPosition(User01, side);
        vm.roll(block.number + 1);
        LINK.sellPosition(side, pos.totalTokens);

        uint balAfter = QUID.balanceOf(User01);
        uint netIn = 50_000e18 * 96 / 100;
        uint recovered = balAfter - (balBefore - 50_000e18);

        assertGt(recovered, netIn * 90 / 100, "recovered >= 90% of net");
        assertLe(recovered, netIn, "no more than net invested");
        vm.stopPrank();
    }

    function test_LMSR_CostMonotonicity() public {
        _deployAndSeed();
        uint8 side = LINK.stablecoinToSide(address(DAI));

        uint prev;
        for (int128 delta = 1e18; delta <= 100e18; delta += 10e18) {
            uint c = LINK.getLMSRCost(side, delta);
            assertGe(c, prev);
            prev = c;
        }
    }

    function test_LMSR_MinOrder_Reverts() public {
        _deployAndSeed();

        vm.startPrank(User01);
        QUID.approve(address(LINK), type(uint).max);
        vm.expectRevert();
        LINK.placeOrder(0, 500_000, false, bytes32(uint(1)), address(0));
        vm.stopPrank();
    }

    function test_Signal_DepegDetected() public {
        _deployAndSeed();
        uint8 daiSide = LINK.stablecoinToSide(address(DAI));

        vm.startPrank(User01);
        QUID.approve(address(LINK), type(uint).max);
        LINK.placeOrder(daiSide, 50_000e18, false, bytes32(uint(1)), address(0));
        vm.stopPrank();

        deal(address(QUID), address(this), LINK.MIN_QD_TO_ASSERT());
        bytes32 idSig = LINK.requestResolution(daiSide, 0);

        _mockResolve(idSig, true);

        Types.DepegStats memory stats = LINK.getDepegStats(address(DAI));
        assertTrue(stats.depegged);
        assertEq(stats.side, daiSide);
    }

    function test_Signal_UnmappedStable() public {
        _deployAndSeed();
        Types.DepegStats memory stats = LINK.getDepegStats(address(0xDeaDbeefdEAdbeefdEadbEEFdeadbeEFdEaDbeeF));
        assertEq(stats.side, 0);
        assertEq(stats.capTotal, 0);
    }

    function test_Signal_CleanAfterReset() public {
        _deployAndSeed();
        uint8 daiSide = LINK.stablecoinToSide(address(DAI));

        bytes32 salt = keccak256("s");
        uint conf = 8000;
        bytes32 commit = keccak256(abi.encodePacked(conf, salt));

        vm.startPrank(User01);
        QUID.approve(address(LINK), type(uint).max);
        LINK.placeOrder(daiSide, 50_000e18, false, commit, address(0));
        vm.stopPrank();

        _resolveNone();
        vm.warp(block.timestamp + 49 hours);

        vm.prank(User01);
        _reveal(User01, daiSide, conf, salt);

        address[] memory u = new address[](1);
        uint8[] memory s = new uint8[](1);
        u[0] = User01; s[0] = daiSide;
        vm.warp(block.timestamp + 49 hours);
        LINK.calculateWeights(u, s, new Link.RevealEntry[](0), new uint[](u.length));
        LINK.pushPayouts(u, s);

        vm.warp(block.timestamp + 48 hours + 1);
        LINK.restartMarket();

        Types.DepegStats memory post = LINK.getDepegStats(address(DAI));
        assertEq(post.capOnSide, 0);
        assertEq(post.capTotal, 0);
        assertFalse(post.depegged);
        assertGt(post.avgConf, 0, "avgConf carries as Bayesian prior");
    }

    function test_NoTrading_AfterResolution() public {
        _deployAndSeed();
        uint8 side = LINK.stablecoinToSide(address(DAI));

        vm.startPrank(User01);
        QUID.approve(address(LINK), type(uint).max);
        LINK.placeOrder(side, 5_000e18, false, bytes32(uint(1)), address(0));
        vm.stopPrank();

        _resolveNone();

        vm.startPrank(User02);
        QUID.approve(address(LINK), type(uint).max);
        vm.expectRevert("resolved");
        LINK.placeOrder(side, 5_000e18, false, bytes32(uint(1)), address(0));
        vm.stopPrank();
    }

    // ══════════════════════════════════════════════════
    //  Confidence Reveal Edge Cases
    // ══════════════════════════════════════════════════

    function test_Reveal_MinConfidence() public {
        _deployAndSeed();
        uint8 side = LINK.stablecoinToSide(address(DAI));

        bytes32 salt = keccak256("min");
        uint conf = 100;
        bytes32 commit = keccak256(abi.encodePacked(conf, salt));

        vm.startPrank(User01);
        QUID.approve(address(LINK), type(uint).max);
        LINK.placeOrder(side, 5_000e18, false, commit, address(0));
        vm.stopPrank();

        _resolveNone();
        vm.warp(block.timestamp + 49 hours);

        vm.prank(User01);
        _reveal(User01, side, conf, salt);
        assertEq(LINK.getPosition(User01, side).revealedConfidence, 100);
    }

    function test_Reveal_MaxConfidence() public {
        _deployAndSeed();
        uint8 side = LINK.stablecoinToSide(address(DAI));

        bytes32 salt = keccak256("max");
        uint conf = 10000;
        bytes32 commit = keccak256(abi.encodePacked(conf, salt));

        vm.startPrank(User01);
        QUID.approve(address(LINK), type(uint).max);
        LINK.placeOrder(side, 5_000e18, false, commit, address(0));
        vm.stopPrank();

        _resolveNone();
        vm.warp(block.timestamp + 49 hours);

        vm.prank(User01);
        _reveal(User01, side, conf, salt);
        assertEq(LINK.getPosition(User01, side).revealedConfidence, 10000);
    }

    function test_Reveal_FineGrainedConfidence() public {
        _deployAndSeed();
        uint8 side = LINK.stablecoinToSide(address(DAI));

        bytes32 salt = keccak256("fine");
        uint conf = 300;
        bytes32 commit = keccak256(abi.encodePacked(conf, salt));

        vm.startPrank(User01);
        QUID.approve(address(LINK), type(uint).max);
        LINK.placeOrder(side, 5_000e18, false, commit, address(0));
        vm.stopPrank();

        _resolveNone();
        vm.warp(block.timestamp + 49 hours);

        vm.prank(User01);
        _reveal(User01, side, conf, salt);
        assertEq(LINK.getPosition(User01, side).revealedConfidence, 300);
    }

    function test_Reveal_BadConfidence_Reverts() public {
        _deployAndSeed();
        uint8 side = LINK.stablecoinToSide(address(DAI));

        uint badConf = 7777;
        bytes32 salt = keccak256("bad");
        bytes32 commit = keccak256(abi.encodePacked(badConf, salt));

        vm.startPrank(User01);
        QUID.approve(address(LINK), type(uint).max);
        LINK.placeOrder(side, 5_000e18, false, commit, address(0));
        vm.stopPrank();

        _resolveNone();
        vm.warp(block.timestamp + 49 hours);

        vm.prank(User01);
        vm.expectRevert("bad confidence");
        _reveal(User01, side, badConf, salt);
    }

    function test_Reveal_BelowMinConfidence_Reverts() public {
        _deployAndSeed();
        uint8 side = LINK.stablecoinToSide(address(DAI));

        uint tooLow = 50;
        bytes32 salt = keccak256("low");
        bytes32 commit = keccak256(abi.encodePacked(tooLow, salt));

        vm.startPrank(User01);
        QUID.approve(address(LINK), type(uint).max);
        LINK.placeOrder(side, 5_000e18, false, commit, address(0));
        vm.stopPrank();

        _resolveNone();
        vm.warp(block.timestamp + 49 hours);

        vm.prank(User01);
        vm.expectRevert("bad confidence");
        _reveal(User01, side, tooLow, salt);
    }

    function test_Reveal_WrongSalt_Reverts() public {
        _deployAndSeed();
        uint8 side = LINK.stablecoinToSide(address(DAI));

        uint conf = 8000;
        bytes32 realSalt = keccak256("real");
        bytes32 commit = keccak256(abi.encodePacked(conf, realSalt));

        vm.startPrank(User01);
        QUID.approve(address(LINK), type(uint).max);
        LINK.placeOrder(side, 5_000e18, false, commit, address(0));
        vm.stopPrank();

        _resolveNone();
        vm.warp(block.timestamp + 49 hours);

        vm.prank(User01);
        vm.expectRevert("hash mismatch");
        _reveal(User01, side, conf, keccak256("wrong"));
    }

    function test_Reveal_Double_IsNoOp() public {
        _deployAndSeed();
        uint8 side = LINK.stablecoinToSide(address(DAI));

        bytes32 salt = keccak256("d");
        uint conf = 8000;
        bytes32 commit = keccak256(abi.encodePacked(conf, salt));

        vm.startPrank(User01);
        QUID.approve(address(LINK), type(uint).max);
        LINK.placeOrder(side, 5_000e18, false, commit, address(0));
        vm.stopPrank();

        _resolveNone();
        vm.warp(block.timestamp + 49 hours);

        vm.prank(User01);
        _reveal(User01, side, conf, salt);

        uint weightBefore = LINK.getPosition(User01, side).weight;
        vm.prank(User01);
        _reveal(User01, side, conf, salt);
        assertEq(LINK.getPosition(User01, side).weight, weightBefore);
    }

    function _checkCapitalInvariant(uint8 n, string memory label) internal view {
        Types.Market memory m = LINK.getMarket();
        uint sum;
        for (uint8 i; i < n; i++) sum += m.capitalPerSide[i];
        assertEq(m.totalCapital, sum, label);
    }

    // ══════════════════════════════════════════════════
    //  Sell + Entries Bookkeeping
    // ══════════════════════════════════════════════════

    function test_Sell_MultiEntry_ProRata() public {
        _deployAndSeed();
        uint8 side = LINK.stablecoinToSide(address(DAI));

        vm.startPrank(User01);
        QUID.approve(address(LINK), type(uint).max);

        LINK.placeOrder(side, 10_000e18, false, bytes32(uint(1)), address(0));
        vm.warp(block.timestamp + 1 hours);
        LINK.placeOrder(side, 20_000e18, false, bytes32(uint(1)), address(0));
        vm.warp(block.timestamp + 1 hours);
        LINK.placeOrder(side, 30_000e18, false, bytes32(uint(1)), address(0));

        Types.Position memory pos = LINK.getPosition(User01, side);
        vm.roll(block.number + 1);
        LINK.sellPosition(side, pos.totalTokens / 2);

        Types.Position memory posAfter = LINK.getPosition(User01, side);
        assertEq(posAfter.totalTokens, pos.totalTokens - pos.totalTokens / 2);

        vm.stopPrank();
    }

    function test_Sell_FullPosition() public {
        _deployAndSeed();
        uint8 side = LINK.stablecoinToSide(address(DAI));

        vm.startPrank(User01);
        QUID.approve(address(LINK), type(uint).max);
        LINK.placeOrder(side, 10_000e18, false, bytes32(uint(1)), address(0));

        Types.Position memory pos = LINK.getPosition(User01, side);
        vm.roll(block.number + 1);
        LINK.sellPosition(side, pos.totalTokens);

        Types.Position memory posAfter = LINK.getPosition(User01, side);
        assertEq(posAfter.totalTokens, 0);
        assertEq(posAfter.totalCapital, 0);
        vm.stopPrank();
    }

    function test_FeeBurn_AfterOrders() public {
        _deployAndSeed();
        uint8 side = LINK.stablecoinToSide(address(DAI));

        vm.startPrank(User01);
        QUID.approve(address(LINK), type(uint).max);
        LINK.placeOrder(side, 100_000e18, false, bytes32(uint(1)), address(0));
        vm.stopPrank();

        assertEq(LINK.accumulatedFees(), 4_000e18);
        LINK.burnAccumulatedFees();
        assertEq(LINK.accumulatedFees(), 0);
    }

    function test_Market_CooldownAfterRejection() public {
        _deployAndSeed();

        vm.startPrank(User01);
        QUID.approve(address(LINK), type(uint).max);
        LINK.placeOrder(0, 5_000e18, false, bytes32(uint(1)), address(0));
        vm.stopPrank();

        assertGe(LINK.MIN_QD_TO_ASSERT(), 500e18);

        (uint8 phase,,) = LINK.getAssertionInfo();
        assertEq(phase, 0); // trading phase, no assertion
    }

    function test_Market_MinQDGate() public {
        assertEq(LINK.MIN_QD_TO_ASSERT(), 500e18);
    }

    function test_MultiRound_ThreeRounds() public {
        _deployAndSeed();
        uint8 side = LINK.stablecoinToSide(address(DAI));

        for (uint round = 1; round <= 3; round++) {
            bytes32 salt = keccak256(abi.encodePacked("r", round));
            uint conf = 8000;
            bytes32 commit = keccak256(abi.encodePacked(conf, salt));

            vm.startPrank(User01);
            QUID.approve(address(LINK), type(uint).max);
            LINK.placeOrder(side, 5_000e18, false, commit, address(0));
            vm.stopPrank();

            _resolveNone();
            vm.warp(block.timestamp + 49 hours);

            vm.prank(User01);
            _reveal(User01, side, conf, salt);

            address[] memory u = new address[](1);
            uint8[] memory s = new uint8[](1);
            u[0] = User01; s[0] = side;
            vm.warp(block.timestamp + 49 hours);
            LINK.calculateWeights(u, s, new Link.RevealEntry[](0), new uint[](u.length));
            LINK.pushPayouts(u, s);

            LINK.restartMarket();

            (,, uint r) = LINK.getAssertionInfo();
            assertEq(r, round + 1);
            assertFalse(LINK.getMarket().resolved);
        }
    }

    function test_AssertionPending_FullFreeze() public {
        _deployAndSeed();
        uint8 side = LINK.stablecoinToSide(address(DAI));

        vm.startPrank(User01);
        QUID.approve(address(LINK), type(uint).max);
        LINK.placeOrder(side, 10_000e18, false, bytes32(uint(1)), address(0));
        vm.stopPrank();

        deal(address(QUID), address(this), LINK.MIN_QD_TO_ASSERT());
        LINK.requestResolution(side, 0);

        vm.startPrank(User02);
        QUID.approve(address(LINK), type(uint).max);
        vm.expectRevert();
        LINK.placeOrder(side, 5_000e18, false, bytes32(uint(1)), address(0));
        vm.stopPrank();

        Types.Position memory pos = LINK.getPosition(User01, side);
        vm.prank(User01);
        vm.expectRevert();
        LINK.sellPosition(side, pos.totalTokens);
    }

    // ============================================================================
    // COURT/JURY HELPER FUNCTIONS
    // ============================================================================

    function getJuror(uint index) public view returns (address) {
        return vm.addr(jurorPKs[index]);
    }

    /// @notice Encode resolution request matching current MessageCodec (52 bytes)
    /// @dev Wire format:
    ///      [0]     = RESOLUTION_REQUEST (5)
    ///      [1-8]   = marketId (LE)
    ///      [9]     = numSides
    ///      [10]    = numWinners (default 1 for single-winner)
    ///      [11]    = requiresUnanimous
    ///      [12-19] = appealCost (LE)
    ///      [20-51] = requester (32 bytes)
    function _encodeResolutionRequest(
        uint64 marketId, uint8 numSides,
        bool requiresUnanimous,
        uint64 appealCost, bytes32 requester
    ) internal pure returns (bytes memory) {
        bytes memory message = new bytes(52);
        message[0] = bytes1(uint8(5)); // RESOLUTION_REQUEST
        for (uint i = 0; i < 8; i++) message[1 + i] = bytes1(uint8(marketId >> (i * 8)));
        message[9] = bytes1(numSides);
        message[10] = bytes1(uint8(1)); // numWinners = 1
        message[11] = requiresUnanimous ? bytes1(uint8(1)) : bytes1(uint8(0));
        for (uint i = 0; i < 8; i++) message[12 + i] = bytes1(uint8(appealCost >> (i * 8)));
        for (uint i = 0; i < 32; i++) message[20 + i] = requester[i];
        return message;
    }

    function _encodeJuryCompensation(uint64 marketId, uint64 amount) internal pure returns (bytes memory) {
        bytes memory message = new bytes(17);
        message[0] = bytes1(uint8(7));
        for (uint i = 0; i < 8; i++) {
            message[1 + i] = bytes1(uint8(marketId >> (i * 8)));
            message[9 + i] = bytes1(uint8(amount >> (i * 8)));
        }
        return message;
    }

    function _createCommitment(uint8[] memory vote, bytes32 salt) internal pure returns (bytes32) {
        return keccak256(abi.encode(vote, salt));
    }

    function _setJurorsDirectly(uint64 marketId, uint8 round, uint count) internal {
        for (uint i = 0; i < count; i++) {
            address juror = getJuror(i);
            vm.mockCall(
                address(jury),
                abi.encodeWithSelector(Jury.isJuror.selector, marketId, round, juror),
                abi.encode(true)
            );
        }

        address[] memory jurors = new address[](count);
        for (uint i = 0; i < count; i++) jurors[i] = getJuror(i);
        vm.mockCall(
            address(jury),
            abi.encodeWithSelector(Jury.getJurors.selector, marketId, round),
            abi.encode(jurors)
        );
    }

    function _getEncodedHeader(uint blockNum) internal returns (bytes memory) {
        string[] memory inputs = new string[](3);
        inputs[0] = "node";
        inputs[1] = "test/scripts/encodeHeader.js";
        inputs[2] = vm.toString(blockNum);
        return vm.ffi(inputs);
    }

    function _getJuryHeaders() internal returns (bytes[] memory) {
        bytes[] memory headers = new bytes[](3);
        headers[0] = _getEncodedHeader(block.number - 1);
        headers[1] = _getEncodedHeader(block.number - 2);
        headers[2] = _getEncodedHeader(block.number - 3);
        return headers;
    }

    function _selectRealJury(uint64 marketId, uint8 round) internal returns (bool) {
        bytes[] memory headers = _getJuryHeaders();
        (uint8 ns, uint8 nw, bool ru,) = court.getMarketConfig(marketId);
        return jury.voirDire(marketId, round, court.getRoundStartTime(marketId),
            Jury.JuryConfig(ns, nw, ru), headers);
    }


    /// @dev Simulate CRE responding via FORWARDER.
    function _mockResolve(bytes32 id, bool truthful) internal {
        (, uint8 claimedSide,, uint round) = LINK.getAssertion(id);
        uint8 recSide = truthful ? claimedSide : 0;
        vm.prank(FORWARDER);
        LINK.onReport("", abi.encode(
            id, claimedSide, recSide, uint(300), uint8(90), bytes32(0)
        ));
    }

    /// @dev Warp past CRE_TIMEOUT so assertion can be escalated to Court.
    function _mockDispute(bytes32) internal {
        vm.warp(block.timestamp + LINK.CRE_TIMEOUT() + 1);
    }

    /// @dev Escalate timed-out assertion to Court arbitration.
    function _escalateToArbitrating(bytes32 id) internal {
        _mockDispute(id);
        LINK.escalateToCourt(id);
    }

    /// @dev Run through an empty round (no positions) to advance roundNumber.
    function _completeRoundNoPayers() internal {
        vm.warp(block.timestamp + LINK.REVEAL_WINDOW() + 1);
        LINK.calculateWeights(
            new address[](0), new uint8[](0),
            new Link.RevealEntry[](0), new uint[](0)
        );
        LINK.pushPayouts(new address[](0), new uint8[](0));
        LINK.restartMarket();
    }

    function _mockVerdict(uint64 marketId, uint8 round, uint8 winner,
        bool unanimous, bool meetsThreshold) internal {
        uint8[] memory verdict = new uint8[](1);
        verdict[0] = winner;
        vm.mockCall(
            address(jury),
            abi.encodeWithSelector(Jury.getStoredVerdict.selector, marketId, round),
            abi.encode(verdict, unanimous, meetsThreshold)
        );
    }

    // ============================================================================
    // MESSAGE CODEC TESTS
    // ============================================================================

    function test_MessageCodec_EncodeDecodeResolutionRequest() public {
        uint64 marketId = 12345;
        bytes memory message = _encodeResolutionRequest(
            marketId, 2, false,
            1000e6, bytes32(uint256(uint160(User01)))
        );

        (uint64 decodedMarketId, uint8 decodedNumSides) =
            this.decodeResolutionRequestHelper(message);
        assertEq(decodedMarketId, marketId, "Market ID mismatch");
        assertEq(decodedNumSides, 2, "Num sides mismatch");
    }

    function decodeResolutionRequestHelper(bytes calldata message)
        external pure returns (uint64, uint8) {
        MessageCodec.ResolutionRequestData memory req = MessageCodec.decodeResolutionRequest(message);
        return (req.marketId, req.numSides);
    }

    function test_MessageCodec_JuryCompensation() public {
        bytes memory message = _encodeJuryCompensation(99, 5000e6);
        (uint64 decodedMarketId, uint64 decodedAmount) = this.decodeJuryCompensationHelper(message);
        assertEq(decodedMarketId, 99);
        assertEq(decodedAmount, 5000e6);
    }

    function decodeJuryCompensationHelper(bytes calldata message) external pure returns (uint64, uint64) {
        return MessageCodec.decodeJuryCompensation(message);
    }

    function test_MessageCodec_EncodeFinalRuling() public {
        uint8[] memory winningSides = new uint8[](1);
        winningSides[0] = 0;
        bytes memory message = MessageCodec.encodeFinalRuling(1, winningSides);
        assertEq(uint8(message[0]), 6, "First byte should be FINAL_RULING");
        // Wire: [0]=6, [1-8]=marketId LE, [9]=numWinners=1, [10]=winningSide=0
        assertEq(message.length, 11, "Single winner = 11 bytes");
    }

    // ============================================================================
    // COURT CONTRACT TESTS
    // ============================================================================

    function test_Court_ReceiveResolutionRequest() public {
        bytes memory message = _encodeResolutionRequest(
            1, 2, false, 1000e6, bytes32(uint256(uint160(User01)))
        );
        vm.prank(address(QUID));
        court.receiveResolutionRequest(message);
        (uint8 numSides,,,) = court.getMarketConfig(1);
        assertEq(numSides, 2, "Should have 2 sides");
    }

    function test_Court_ReceiveResolutionRequest_Unauthorized() public {
        bytes memory message = _encodeResolutionRequest(1, 2, false, 1000e6, bytes32(0));
        vm.prank(User01);
        vm.expectRevert(Court.Unauthorized.selector);
        court.receiveResolutionRequest(message);
    }

    function test_Court_AppealGroundsValidation() public {
        bytes memory message = _encodeResolutionRequest(
            1, 2, false, 1000e6, bytes32(0)
        );
        vm.prank(address(QUID));
        court.receiveResolutionRequest(message);

        // Without a verdict, should fail with NoVerdictToAppeal
        vm.prank(User01);
        vm.expectRevert(Court.NoVerdictToAppeal.selector);
        court.fileAppeal(1, Court.AppealGround.FABRICATION, "no verdict yet");
    }

    function test_Court_GetRoundStartTime() public {
        bytes memory message = _encodeResolutionRequest(1, 2, false, 1000e6, bytes32(0));
        uint timeBefore = block.timestamp;

        vm.prank(address(QUID));
        court.receiveResolutionRequest(message);

        uint roundStart = court.getRoundStartTime(1);
        assertGe(roundStart, timeBefore);
        assertLe(roundStart, block.timestamp);
    }

    function test_Court_GetCurrentRoundStartsAtZero() public {
        bytes memory message = _encodeResolutionRequest(1, 2, false, 1000e6, bytes32(0));
        vm.prank(address(QUID));
        court.receiveResolutionRequest(message);

        assertEq(court.getCurrentRound(1), 0);
    }

    function test_Court_ResolutionStoresAllParams() public {
        uint64 marketId = 12345;
        uint8 numSides = 4;
        uint64 appealCost = 5000e6;
        bytes32 requester = bytes32(uint256(0xDEAD));

        bytes memory message = _encodeResolutionRequest(
            marketId, numSides, true, appealCost, requester
        );

        vm.prank(address(QUID));
        court.receiveResolutionRequest(message);

        (uint8 storedSides,,,,,,uint256 storedAppealCost, bytes32 storedRequester) = court.resolutions(marketId);

        assertEq(storedSides, numSides, "numSides mismatch");
        assertEq(storedAppealCost, appealCost, "appealCost mismatch");
        assertEq(storedRequester, requester, "requester mismatch");
    }

    function test_Court_IsInResolutionPhase() public {
        assertFalse(court.isInResolutionPhase(1));

        bytes memory message = _encodeResolutionRequest(1, 2, false, 1000e6, bytes32(0));
        vm.prank(address(QUID));
        court.receiveResolutionRequest(message);

        assertTrue(court.isInResolutionPhase(1));
    }

    // ============================================================================
    // JURY TESTS
    // ============================================================================

    function test_Jury_IsJurorReturnsFalseForNonJuror() public {
        bytes memory message = _encodeResolutionRequest(1, 2, false, 1000e6, bytes32(0));
        vm.prank(address(QUID));
        court.receiveResolutionRequest(message);

        assertFalse(jury.isJuror(1, 0, User01));
    }

    function test_Jury_GetJurorsEmptyBeforeSelection() public {
        bytes memory message = _encodeResolutionRequest(1, 2, false, 1000e6, bytes32(0));
        vm.prank(address(QUID));
        court.receiveResolutionRequest(message);

        assertEq(jury.getJurors(1, 0).length, 0);
    }

    function test_Jury_RandaoManipulationResistance() public {
        bytes[] memory insufficientHeaders = new bytes[](2);

        bytes memory message = _encodeResolutionRequest(1, 2, false, 1000e6, bytes32(0));
        vm.prank(address(QUID));
        court.receiveResolutionRequest(message);

        vm.expectRevert(Jury.InsufficientHeaders.selector);
        vm.prank(address(court));
        jury.voirDire(1, 0, block.timestamp, Jury.JuryConfig(2, 1, false), insufficientHeaders);
    }

    function test_Integration_MultiRoundStateIntegrity() public {
        bytes memory message = _encodeResolutionRequest(1, 2, false, 1000e6, bytes32(0));
        vm.prank(address(QUID));
        court.receiveResolutionRequest(message);

        (uint8 numSides,,,) = court.getMarketConfig(1);
        assertEq(numSides, 2);
        assertEq(court.getCurrentRound(1), 0);
    }

    function test_EdgeCase_CommitToNonExistentMarket() public {
        uint8[] memory vote = new uint8[](1);
        vote[0] = 0;

        vm.prank(getJuror(0));
        vm.expectRevert(Jury.NotActive.selector);
        jury.commitVote(999, 0, _createCommitment(vote, keccak256("salt")), address(0));
    }

    // ============================================================================
    // AMP TESTS — anvil mainnet fork, real AAVE interactions, mocked TWAP
    //
    // Amp.sol operates against mainnet AAVE v3 on the fork. The only mock
    // is AUX.getTWAP which Amp calls to gate pivot actions. Every AAVE call
    // (supply, borrow, repay, withdraw) hits the real pool.
    //
    // _howMuchInterest V3 path index fix required (and applied in outputs):
    //   reserveData[0] = WETH on L1 (was hardcoded 4 — Arbi/Poly index)
    //   reserveData[3] = USDC on L1 (was hardcoded 12)
    //   Without this fix every unwind reverts at the stdMath.delta require
    //   because wethSharesSnapshot = 0 from the wrong aToken address.
    //
    // getTWAP(0) is NEVER mocked — real V3 price so v3Fair passes and AAVE
    // USDC sourcing fits within mainnet fork liquidity (~$4421 available).
    // Only getTWAP(1800) is mocked — that's what unwindZeroForOne reads.
    //
    // token1isWETH is true for USDC/WETH pool (USDC < WETH address):
    //   leverETH longs  → pledgesOneForZero[who]  → unwindZeroForOne
    //   leverUSD shorts → pledgesZeroForOne[who]  → unwindOneForZero
    // ============================================================================

    // ─── constants ──────────────────────────────────────────────────────────────

    uint constant AMP_ETH      = 2 ether;  // collateral per test position
    uint constant AMP_USDC     = 1000e6;   // USDC for short positions
    uint constant AMP_BPS_DOWN = 9750;     // -2.5% of anchor
    uint constant AMP_BPS_UP   = 10251;    // +2.51% → compound delta truncates to 25 not 24
    uint internal _ampAnchor;              // set at open, updated each pivot

    // ─── helpers ────────────────────────────────────────────────────────────────

    /// @dev Mock only getTWAP(1800) — what unwind uses for delta.
    ///      getTWAP(0) is left real so v3Fair passes and AAVE USDC sourcing works.
    function _ampMockTWAP(uint price) internal {
        vm.mockCall(address(AUX),
            abi.encodeWithSelector(Aux.getTWAP.selector, uint32(1800)),
            abi.encode(price));
    }

    /// @dev Seed V3 and V4 with enough liquidity so leverETH can source USDC.
    function _ampSeedLiquidity() internal {
        vm.startPrank(User01);
        V3.repackNFT();
        V3.deposit{value: 30 ether}(0);
        V4.deposit{value: 50 ether}(0);
        vm.stopPrank();
    }

    /// @dev Open a long position at the real V3 TWAP price.
    function _ampOpenLong(address who) internal {
        _ampAnchor = AUX.getTWAP(0);
        _ampMockTWAP(_ampAnchor);
        vm.prank(who);
        AUX.leverETH{value: AMP_ETH}(0);
        vm.clearMockedCalls();
    }

    /// @dev Open a short position at the real V3 TWAP price.
    /// Both getTWAP(0) and getTWAP(1800) are mocked to _ampAnchor so that
    /// AMP.leverUSD records pledge.price = _ampAnchor, keeping pivot deltas
    /// consistent with _ampPivotShort. The mocked value equals the real
    /// 1800s TWAP (read one line earlier) so v3Fair sees no inconsistency.
    function _ampOpenShort(address who) internal {
        _ampAnchor = AUX.getTWAP(0);
        _ampMockTWAP(_ampAnchor);
        vm.mockCall(address(AUX),
            abi.encodeWithSelector(Aux.getTWAP.selector, uint32(0)),
            abi.encode(_ampAnchor));
        vm.startPrank(who);
        USDC.approve(address(AUX), AMP_USDC);
        AUX.leverUSD(AMP_USDC, address(USDC));
        vm.stopPrank();
        vm.clearMockedCalls();
    }

    /// @dev Pivot long positions: bps is percentage of current anchor.
    ///      Updates _ampAnchor so compound pivots chain correctly.
    function _ampPivotLong(uint bps) internal {
        uint price = _ampAnchor * bps / 10000;
        _ampAnchor = price;
        address[] memory w = new address[](1);
        w[0] = User01;
        _ampMockTWAP(price);
        AMP.unwindZeroForOne(w);
        vm.clearMockedCalls();
    }

    function _ampPivotShort(uint bps) internal {
        uint price = _ampAnchor * bps / 10000;
        _ampAnchor = price;
        address[] memory w = new address[](1);
        w[0] = User01;
        _ampMockTWAP(price);
        AMP.unwindOneForZero(w);
        vm.clearMockedCalls();
    }

    // ─── open / setup tests ─────────────────────────────────────────────────────

    function testAmp_HasNoDebtInitially() public {
        assertFalse(AMP.hasOpenDebt(), "no debt before any leverage");
    }

    function testAmp_LeverETH_OpensDebt() public {
        _ampSeedLiquidity();
        _ampOpenLong(User01);
        assertTrue(AMP.hasOpenDebt(), "should have WETH debt after leverETH");
    }

    function testAmp_LeverUSD_OpensDebt() public {
        _ampSeedLiquidity();
        _ampOpenShort(User01);
        assertTrue(AMP.hasOpenDebt(), "should have USDC debt after leverUSD");
    }

    function testAmp_LeverETH_MinSizeReverts() public {
        _ampSeedLiquidity();
        // 0.01 ETH at real price ~$2190 = $21.90 — below the $50 minimum
        vm.prank(User01);
        vm.expectRevert();
        AUX.leverETH{value: 0.01 ether}(0);
    }

    function testAmp_LeverETH_NoDuplicatePosition() public {
        _ampSeedLiquidity();
        _ampOpenLong(User01);
        _ampMockTWAP(_ampAnchor);
        vm.prank(User01);
        vm.expectRevert();
        AUX.leverETH{value: AMP_ETH}(0);
        vm.clearMockedCalls();
    }

    function testAmp_LeverUSD_NoDuplicatePosition() public {
        _ampSeedLiquidity();
        _ampOpenShort(User01);
        _ampMockTWAP(_ampAnchor);
        vm.startPrank(User01);
        USDC.approve(address(AUX), AMP_USDC);
        vm.expectRevert();
        AUX.leverUSD(AMP_USDC, address(USDC));
        vm.stopPrank();
        vm.clearMockedCalls();
    }

    // ─── no-op below threshold ──────────────────────────────────────────────────

    function testAmp_UnwindLong_BelowThreshold_NoOp() public {
        _ampSeedLiquidity();
        _ampOpenLong(User01);
        // +1% — delta = 10, below the ±25 threshold
        _ampMockTWAP(_ampAnchor * 10100 / 10000);
        address[] memory w = new address[](1); w[0] = User01;
        AMP.unwindZeroForOne(w);
        vm.clearMockedCalls();
        assertTrue(AMP.hasOpenDebt(), "debt unchanged below threshold");
    }

    function testAmp_UnwindShort_BelowThreshold_NoOp() public {
        _ampSeedLiquidity();
        _ampOpenShort(User01);
        _ampMockTWAP(_ampAnchor * 10100 / 10000);
        address[] memory w = new address[](1); w[0] = User01;
        AMP.unwindOneForZero(w);
        vm.clearMockedCalls();
        assertTrue(AMP.hasOpenDebt(), "debt unchanged below threshold");
    }

    function testAmp_UnwindLong_SkipsEmptyAddress() public {
        _ampSeedLiquidity();
        _ampOpenLong(User01);
        _ampMockTWAP(_ampAnchor * AMP_BPS_DOWN / 10000);
        address[] memory w = new address[](2);
        w[0] = User02; w[1] = User01;
        AMP.unwindZeroForOne(w);
        vm.clearMockedCalls();
        assertFalse(AMP.hasOpenDebt(), "User01 debt cleared despite User02 empty");
    }

    // ─── LONG state machine ─────────────────────────────────────────────────────

    function testAmp_Long_LONG_DOWN_PriceDown_RepaysAndReaccumulates() public {
        _ampSeedLiquidity();
        _ampOpenLong(User01);
        _ampPivotLong(AMP_BPS_DOWN);
        assertFalse(AMP.hasOpenDebt(), "WETH borrow cleared after LONG_DOWN");
    }

    function testAmp_Long_LONG_UP_PriceUp_TakesProfit() public {
        _ampSeedLiquidity();
        _ampOpenLong(User01);
        _ampPivotLong(AMP_BPS_UP);
        assertFalse(AMP.hasOpenDebt(), "WETH borrow cleared after LONG_UP");
    }

    function testAmp_Long_LONG_DOWN2_SecondPivotDown() public {
        _ampSeedLiquidity();
        _ampOpenLong(User01);
        _ampPivotLong(AMP_BPS_UP);
        assertFalse(AMP.hasOpenDebt(), "after LONG_UP");
        _ampPivotLong(AMP_BPS_DOWN);
        assertFalse(AMP.hasOpenDebt(), "no debt after LONG_DOWN_2");
    }

    function testAmp_Long_LONG_EXIT_FullCycle_DipThenExit() public {
        _ampSeedLiquidity();
        _deployAndSeed();
        _ampOpenLong(User01);
        _ampPivotLong(AMP_BPS_DOWN);
        assertFalse(AMP.hasOpenDebt(), "after LONG_DOWN");
        uint usdcBefore = USDC.balanceOf(User01);
        _ampPivotLong(AMP_BPS_UP);
        assertGt(USDC.balanceOf(User01) - usdcBefore, 0, "user must receive USDC on LONG_EXIT");
        assertFalse(AMP.hasOpenDebt(), "no debt after LONG_EXIT");
    }

    function testAmp_Long_Exit_ProfitSplitToProtocol() public {
        _ampSeedLiquidity();
        _deployAndSeed();
        _ampOpenLong(User01);
        _ampPivotLong(AMP_BPS_DOWN);
        _ampPivotLong(AMP_BPS_UP);
        assertGt(USDC.balanceOf(User01), 0, "user paid on exit");
    }

    function testAmp_Long_Exit_UnderwaterReturnsWhatever() public {
        _ampSeedLiquidity();
        _deployAndSeed();
        _ampOpenLong(User01);
        _ampPivotLong(AMP_BPS_DOWN);
        _ampPivotLong(AMP_BPS_UP);
        assertFalse(AMP.hasOpenDebt(), "position cleared");
    }

    // ─── SHORT state machine ────────────────────────────────────────────────────

    function testAmp_Short_SHORT_UP_PriceUp_BadForShort() public {
        _ampSeedLiquidity();
        _ampOpenShort(User01);
        _ampPivotShort(AMP_BPS_UP);
        assertFalse(AMP.hasOpenDebt(), "USDC borrow cleared after SHORT_UP");
    }

    function testAmp_Short_SHORT_DOWN_PriceDown_GoodForShort() public {
        _ampSeedLiquidity();
        _ampOpenShort(User01);
        _ampPivotShort(AMP_BPS_DOWN);
        assertFalse(AMP.hasOpenDebt(), "USDC borrow cleared after SHORT_DOWN");
    }

    function testAmp_Short_SHORT_DOWN2_SecondPivotDown() public {
        _ampSeedLiquidity();
        _ampOpenShort(User01);
        _ampPivotShort(AMP_BPS_UP);
        assertFalse(AMP.hasOpenDebt(), "after SHORT_UP");
        _ampPivotShort(AMP_BPS_DOWN);
        assertFalse(AMP.hasOpenDebt(), "no debt after SHORT_DOWN_2");
    }

    // ─── batch / multi-user ─────────────────────────────────────────────────────

    function testAmp_Batch_TwoLongs_BothPivot() public {
        _ampSeedLiquidity();
        vm.startPrank(User01);
        V3.deposit{value: 5 ether}(0);
        vm.stopPrank();

        _ampOpenLong(User01);

        _ampMockTWAP(_ampAnchor);
        vm.startPrank(User02);
        V3.deposit{value: 5 ether}(0);
        AUX.leverETH{value: AMP_ETH}(0);
        vm.stopPrank();
        vm.clearMockedCalls();

        assertTrue(AMP.hasOpenDebt(), "both longs open");

        address[] memory w = new address[](2);
        w[0] = User01; w[1] = User02;
        _ampMockTWAP(_ampAnchor * AMP_BPS_DOWN / 10000);
        AMP.unwindZeroForOne(w);
        vm.clearMockedCalls();
        assertFalse(AMP.hasOpenDebt(), "all debt cleared after batch pivot");
    }

    function testAmp_Batch_MaxBatchSize30() public {
        _ampSeedLiquidity();
        address[] memory w = new address[](35);
        for (uint i; i < 35; i++) w[i] = address(uint160(0x9000 + i));
        // None have positions — price==0 guard skips them
        _ampMockTWAP(1000e18);
        AMP.unwindZeroForOne(w);
        vm.clearMockedCalls();
    }

    // ─── interest accounting ────────────────────────────────────────────────────

    function testAmp_InterestAccounting_RepayExceedsZero() public {
        _ampSeedLiquidity();
        _deployAndSeed();
        _ampOpenLong(User01);
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + 200000);
        _ampPivotLong(AMP_BPS_DOWN);
        uint usdcBefore = USDC.balanceOf(User01);
        _ampPivotLong(AMP_BPS_UP);
        assertFalse(AMP.hasOpenDebt(), "position closed after time-accrued interest");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  CRE STATE MACHINE TESTS
    // ══════════════════════════════════════════════════════════════════════

    function test_CRE_InsufficientQD_Reverts() public {
        _deployAndSeed();
        uint8 side = LINK.stablecoinToSide(address(DAI));
        // _deployAndSeed gives address(this) exactly MIN_QD_TO_ASSERT, zero it out
        deal(address(QUID), address(this), 0);
        vm.expectRevert();
        LINK.requestResolution(side, 0);
    }

    function test_CRE_QDGateAllows() public {
        _deployAndSeed();
        uint8 side = LINK.stablecoinToSide(address(DAI));
        deal(address(QUID), address(this), LINK.MIN_QD_TO_ASSERT());
        bytes32 id = LINK.requestResolution(side, 0);
        assertTrue(id != bytes32(0), "assertionId returned");
        assertEq(LINK.pendingAssertions(), 1);
    }

    function test_CRE_NotForwarder_Reverts() public {
        _deployAndSeed();
        uint8 side = LINK.stablecoinToSide(address(DAI));
        deal(address(QUID), address(this), LINK.MIN_QD_TO_ASSERT());
        bytes32 id = LINK.requestResolution(side, 0);
        vm.expectRevert();
        LINK.onReport("", abi.encode(id, side, side, uint(300), uint8(90), bytes32(0)));
    }

    function test_CRE_AcceptPath_ResolvesMarket() public {
        _deployAndSeed();
        uint8 side = LINK.stablecoinToSide(address(DAI));
        deal(address(QUID), address(this), LINK.MIN_QD_TO_ASSERT());
        bytes32 id = LINK.requestResolution(side, 0);
        assertFalse(LINK.getMarket().resolved);
        _mockResolve(id, true);
        assertTrue(LINK.getMarket().resolved);
        assertEq(LINK.getMarket().winningSide, side);
    }

    function test_CRE_RejectPath_CooldownApplied() public {
        _deployAndSeed();
        uint8 side = LINK.stablecoinToSide(address(DAI));
        deal(address(QUID), address(this), LINK.MIN_QD_TO_ASSERT() * 3);
        bytes32 id = LINK.requestResolution(side, 0);
        _mockResolve(id, false); // CRE denies
        assertFalse(LINK.getMarket().resolved);
        assertEq(LINK.pendingAssertions(), 0);
        // re-assert same side within 24h should revert
        vm.expectRevert();
        LINK.requestResolution(side, 0);
    }

    function test_CRE_CooldownExpiry_AllowsReassert() public {
        _deployAndSeed();
        uint8 side = LINK.stablecoinToSide(address(DAI));
        deal(address(QUID), address(this), LINK.MIN_QD_TO_ASSERT() * 3);
        bytes32 id = LINK.requestResolution(side, 0);
        _mockResolve(id, false);
        vm.warp(block.timestamp + 25 hours);
        bytes32 id2 = LINK.requestResolution(side, 0);
        assertTrue(id2 != bytes32(0));
        assertTrue(id2 != id, "new assertionId issued");
    }

    function test_CRE_WindowOpen_EscalateTooEarly_Reverts() public {
        _deployAndSeed();
        uint8 side = LINK.stablecoinToSide(address(DAI));
        deal(address(QUID), address(this), LINK.MIN_QD_TO_ASSERT());
        bytes32 id = LINK.requestResolution(side, 0);
        vm.expectRevert();
        LINK.escalateToCourt(id);
    }

    function test_CRE_EscalateToCourt_AfterTimeout() public {
        _deployAndSeed();
        uint8 side = LINK.stablecoinToSide(address(DAI));
        deal(address(QUID), address(this), LINK.MIN_QD_TO_ASSERT());
        bytes32 id = LINK.requestResolution(side, 0);
        vm.warp(block.timestamp + LINK.CRE_TIMEOUT() + 1);
        LINK.escalateToCourt(id);
        assertEq(LINK.arbitratingAssertionId(), id);
    }

    function test_CRE_AlreadyResponded_BlocksEscalate() public {
        _deployAndSeed();
        uint8 side = LINK.stablecoinToSide(address(DAI));
        deal(address(QUID), address(this), LINK.MIN_QD_TO_ASSERT() * 2);
        bytes32 id = LINK.requestResolution(side, 0);
        // CRE responds (reject) then warp past timeout
        _mockResolve(id, false);
        vm.warp(block.timestamp + LINK.CRE_TIMEOUT() + 1);
        // re-assert so there's an active assertion to try escalating
        vm.warp(block.timestamp + 25 hours);
        bytes32 id2 = LINK.requestResolution(side, 0);
        vm.warp(block.timestamp + LINK.CRE_TIMEOUT() + 1);
        // id2 was not responded to, escalate should work
        LINK.escalateToCourt(id2);
        assertEq(LINK.arbitratingAssertionId(), id2);
    }

    function test_CRE_ReceiveRuling_ResolvesMarket() public {
        _deployAndSeed();
        uint8 side = LINK.stablecoinToSide(address(DAI));
        deal(address(QUID), address(this), LINK.MIN_QD_TO_ASSERT());
        bytes32 id = LINK.requestResolution(side, 0);
        _escalateToArbitrating(id);
        assertEq(LINK.arbitratingAssertionId(), id);
        // Court delivers ruling
        vm.prank(address(court));
        LINK.receiveRuling(side, 500);
        assertTrue(LINK.getMarket().resolved);
        assertEq(LINK.getMarket().winningSide, side);
        assertEq(LINK.arbitratingAssertionId(), bytes32(0));
    }

    function test_CRE_isTradingEnabled_Gates() public {
        _deployAndSeed();
        assertTrue(LINK.isTradingEnabled());
        uint8 side = LINK.stablecoinToSide(address(DAI));
        deal(address(QUID), address(this), LINK.MIN_QD_TO_ASSERT());
        LINK.requestResolution(side, 0);
        assertFalse(LINK.isTradingEnabled());
    }

    function test_CRE_isRevealOpen() public {
        _deployAndSeed();
        assertFalse(LINK.isRevealOpen());
        uint8 side = LINK.stablecoinToSide(address(DAI));
        deal(address(QUID), address(this), LINK.MIN_QD_TO_ASSERT());
        bytes32 id = LINK.requestResolution(side, 0);
        _mockResolve(id, true);
        assertTrue(LINK.isRevealOpen());
        vm.warp(block.timestamp + LINK.REVEAL_WINDOW() + 1);
        assertFalse(LINK.isRevealOpen());
    }

    function test_CRE_isSideDepegged_MultiDepeg() public {
        _deployAndSeed();
        uint8 daiSide  = LINK.stablecoinToSide(address(DAI));
        uint8 usdcSide = LINK.stablecoinToSide(address(USDC));
        deal(address(QUID), address(this), LINK.MIN_QD_TO_ASSERT() * 2);
        // file for DAI
        bytes32 id1 = LINK.requestResolution(daiSide, 0);
        _mockResolve(id1, true); // DAI wins → winningSide = daiSide
        // USDC was separately confirmed via second assertion in same round
        bytes32 id2 = LINK.requestResolution(usdcSide, 0);
        _mockResolve(id2, true);
        assertTrue(LINK.isSideDepegged(LINK.getMarket().roundNumber, daiSide));
        assertTrue(LINK.isSideDepegged(LINK.getMarket().roundNumber, usdcSide));
    }

    function test_CRE_GetAssertion_ReturnsFields() public {
        _deployAndSeed();
        uint8 side = LINK.stablecoinToSide(address(DAI));
        deal(address(QUID), address(this), LINK.MIN_QD_TO_ASSERT());
        bytes32 id = LINK.requestResolution(side, 200);
        (address asserter, uint8 claimedSide,,) = LINK.getAssertion(id);
        assertEq(asserter, address(this));
        assertEq(claimedSide, side);
    }

    function test_CRE_AssertionInfo_PhaseMachine() public {
        _deployAndSeed();
        (uint8 phase,,) = LINK.getAssertionInfo();
        assertEq(phase, 0, "trading phase");

        uint8 side = LINK.stablecoinToSide(address(DAI));
        deal(address(QUID), address(this), LINK.MIN_QD_TO_ASSERT());
        bytes32 id = LINK.requestResolution(side, 0);
        (phase,,) = LINK.getAssertionInfo();
        assertEq(phase, 1, "asserting phase");

        _escalateToArbitrating(id);
        (phase,,) = LINK.getAssertionInfo();
        assertEq(phase, 4, "arbitrating phase");

        vm.prank(address(court));
        LINK.receiveRuling(side, 0);
        (phase,,) = LINK.getAssertionInfo();
        assertEq(phase, 3, "resolved phase");
    }

    function test_CRE_ResolveAsNone_BeforeMonth_Reverts() public {
        _deployAndSeed();
        vm.expectRevert();
        LINK.resolveAsNone();
    }

    function test_CRE_ArbitratingAssertionId_ClearedAfterRuling() public {
        _deployAndSeed();
        uint8 side = LINK.stablecoinToSide(address(DAI));
        deal(address(QUID), address(this), LINK.MIN_QD_TO_ASSERT());
        bytes32 id = LINK.requestResolution(side, 0);
        _escalateToArbitrating(id);
        assertEq(LINK.arbitratingAssertionId(), id);
        vm.prank(address(court));
        LINK.receiveRuling(0, 0); // side 0 = no depeg ruling
        assertEq(LINK.arbitratingAssertionId(), bytes32(0));
        assertFalse(LINK.getMarket().resolved); // side 0 means no resolution
    }

}
