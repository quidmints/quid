// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/console.sol";
import "forge-std/Script.sol";

import {VogueUni as Vogue} from "../src/L2/VogueUni.sol";
import {AuxPoly as Aux} from "../src/L2/AuxPoly.sol";
import {VogueCore} from "../src/VogueCore.sol";
import {Basket} from "../src/Basket.sol";
import {Rover} from "../src/Rover.sol";
import {Amp} from "../src/Amp.sol";
import {Link} from "../src/Link.sol";
import {Jury} from "../src/Jury.sol";
import {Court} from "../src/Court.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

import {INonfungiblePositionManager} from "../src/imports/v3/INonfungiblePositionManager.sol";
import {IV3SwapRouter as ISwapRouter} from "../src/imports/v3/IV3SwapRouter.sol";
import {IUniswapV3Pool} from "../src/imports/v3/IUniswapV3Pool.sol";

/**
 * @dev Key differences from other chains:
 *      - Only 4 stables: USDC, USDT, FRAX, CRVUSD
 *      - 2 Morpho vaults (USDC, USDT) + 2 direct holdings (FRAX, CRVUSD)
 *      - NO staked pairs (no SFRAX, SUSDS, etc on Polygon)
 *      - WETH is bridged ERC20 (no native wrap/unwrap)
 *      - nativeWETH = false on Vogue
 */
contract Deploy is Script {
    address[] public STABLES;
    address[] public VAULTS;

    IERC20 public WETH = IERC20(0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619);
    address public aavePool = 0x794a61358D6845594F94dc1DB02A252b5b4814aD;
    address public aaveData = 0xFa1A7c4a8A63C9CAb150529c26f182cBB5500944;
    address public aaveAddr = 0xa97684ead0e402dC232d5A977953DF7ECBaB3CDb;

    address public FORWARDER = 0x76c9cf548b4179F8901cda1f8623568b58215E62;
    address public JAM = 0xbeb0b0623f66bE8cE162EbDfA2ec543A522F4ea6;
    address public DAIaToken = 0x82E64f49Ed5EC1bC6e43DAD4FC8Af9bb3A2312EE;

    // ═══════════════════════════════════════════════════════════════
    //                      POLYGON ADDRESSES
    // ═══════════════════════════════════════════════════════════════

    // Uniswap V4 PoolManager
    IPoolManager public poolManager = IPoolManager(0x67366782805870060151383F4BbFF9daB53e5cD6);

    // Uniswap V3 Router
    ISwapRouter public v3Router = ISwapRouter(0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45);

    INonfungiblePositionManager public nfpm = INonfungiblePositionManager(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);

    // Uniswap V3 WETH/USDC Pool (for TWAP)
    IUniswapV3Pool public wethV3Pool = IUniswapV3Pool(0xA4D8c89f0c20efbe54cBa9e7e7a7E509056228D9);

    // ═══════════════════════════════════════════════════════════════
    //                        STABLECOINS
    // ═══════════════════════════════════════════════════════════════


    IERC20 public USDC = IERC20(0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359);   // 6 decimal
    IERC20 public USDT = IERC20(0xc2132D05D31c914a87C6611C10748AEb04B58e8F);   // 6 decimals
    IERC20 public DAI = IERC20(0x8f3Cf7ad23Cd3CaDbD9735AFf958023239c6A063);    // 18 decimals
    IERC20 public FRAX = IERC20(0x80Eede496655FB9047dd39d9f418d5483ED600df);   // 18 decimals
    IERC20 public CRVUSD = IERC20(0xc4Ce1D6F5D98D65eE25Cf85e9F2E9DcFEe6Cb5d6); // 18 decimals
    IERC20 public SFRAX = IERC20(0x5Bff88cA1442c2496f7E475E9e7786383Bc070c0);

    // ═══════════════════════════════════════════════════════════════
    //                          VAULTS
    // ═══════════════════════════════════════════════════════════════

    // Gauntlet WETH Vault (for Vogue ETH deposits).
    IERC4626 public wethVault = IERC4626(0xF5C81d25ee174d83f1FD202cA94AE6070d073cCF);

    // Morpho USDC Vault
    IERC4626 public usdcVault = IERC4626(0xB7c9988D3922F25a336a469F3bB26CA61FE79e24);

    // Morpho USDT Vault
    IERC4626 public usdtVault = IERC4626(0xfD06859A671C21497a2EB8C5E3fEA48De924D6c8);

    // ═══════════════════════════════════════════════════════════════
    //                    NOT AVAILABLE ON POLYGON
    // ═══════════════════════════════════════════════════════════════
    // - Staked tokens (SFRAX, SUSDS, SUSDE, SCRVUSD)
    // - GHO, DAI, USDS, USDE
    // - AMP/Rover (no leverage)

    Basket public QUID;
    VogueCore public CORE;
    Vogue public V4;
    Aux public AUX;
    Amp public AMP;
    Rover public V3;
    Jury public jury;
    Court public court;
    Link public LINK;

    function run() public {
        // Handle private key (supports both hex and raw formats)
        string memory privateKeyStr = vm.envString("PRIVATE_KEY");
        uint256 deployerPrivateKey;
        if (bytes(privateKeyStr).length > 2 &&
            bytes(privateKeyStr)[0] == 0x30 &&
            bytes(privateKeyStr)[1] == 0x78) {
            deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        } else {
            deployerPrivateKey = vm.parseUint(
                string(abi.encodePacked("0x", privateKeyStr)));
        }

        /**
         * STABLES ARRAY STRUCTURE FOR POLYGON:
         */
        STABLES = [
            address(USDC),   // Index 0: goes into Morpho vault (6 dec)
            address(USDT),   // Index 1: goes into Morpho vault (6 dec)
            address(DAI),   // Index 2: goes into AAVE (18 dec)
            address(FRAX),   // Index 3: Direct holding (18 dec)
            address(CRVUSD),  // Index 4: Direct holding (18 dec)
            address(SFRAX)
        ];
        VAULTS = [
            address(usdcVault),  // For USDC (index 0)
            address(usdtVault),   // For USDT (index 1)
            DAIaToken
        ];

        vm.startBroadcast(deployerPrivateKey);
        address deployer = vm.addr(deployerPrivateKey);
        AMP = new Amp(aavePool, aaveData, aaveAddr);
        V3 = new Rover(address(AMP), address(WETH),
            address(USDC), address(nfpm),
            address(wethV3Pool),
            address(v3Router), false);

        V4 = new Vogue(address(wethVault));
        CORE = new VogueCore(poolManager);
        AUX = new Aux(
            address(V4),
            address(CORE),
            address(wethVault),
            address(AMP),
            address(aavePool),
            address(wethV3Pool),     // _v3poolWETH: For TWAP
            address(v3Router),       // _v3router: For swaps
            address(V3),
            STABLES,
            VAULTS
        );

        AMP.setup(payable(address(V3)), address(AUX));
        QUID = new Basket(address(V4), address(AUX));
        LINK = new Link(address(QUID), FORWARDER);
        jury = new Jury(address(QUID));
        court = new Court(address(QUID),
        address(jury), address(LINK), false);
        jury.setup(address(court));

        QUID.setup(address(LINK),
        address(court), address(jury));

        CORE.setup(address(V4), address(AUX), address(wethV3Pool));
        V4.setup(address(QUID), address(AUX), address(CORE), false);
        AUX.setQuid(address(QUID), JAM); V3.setAux(address(AUX));

        console.log("=== Deployed Addresses ===");
        console.log("AMP:", address(AMP));
        console.log("V3 (Rover):", address(V3));
        console.log("V4 (Vogue):", address(V4));
        console.log("CORE (VogueCore):", address(CORE));
        console.log("AUX:", address(AUX));
        console.log("QUID (Basket):", address(QUID));
        console.log("LINK:", address(LINK));
        console.log("Court:", address(court));
        console.log("Jury:", address(jury));

        vm.stopBroadcast();
    }
}
