// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/console.sol";

import {IUniswapV3Pool} from "../src/imports/v3/IUniswapV3Pool.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IV3SwapRouter as ISwapRouter} from "../src/imports/v3/IV3SwapRouter.sol";
import {INonfungiblePositionManager} from "../src/imports/v3/INonfungiblePositionManager.sol";

import {Amp} from "../src/Amp.sol";
import {Link} from "../src/Link.sol";
import {Jury} from "../src/Jury.sol";
import {Court} from "../src/Court.sol";
import {Vogue} from "../src/Vogue.sol";
import {Rover} from "../src/Rover.sol";
import {Basket} from "../src/Basket.sol";

import {VogueCore} from "../src/VogueCore.sol";
import {Types} from "../src/imports/Types.sol";
import {BasketLib} from "../src/imports/BasketLib.sol";

import {Script} from "forge-std/Script.sol";
import {AuxArb as Aux} from "../src/L2/AuxArb.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";

contract Deploy is Script {
    IERC20 public WETH = IERC20(0x82aF49447D8a07e3bd95BD0d56f35241523fBab1);
    address public aavePool = 0x794a61358D6845594F94dc1DB02A252b5b4814aD;
    address public aaveData = 0x13c833256BD767da2320d727a3691BAff3770E39;
    address public aaveAddr = 0xa97684ead0e402dC232d5A977953DF7ECBaB3CDb;
    address constant UMA_OOV3 = 0xa6147867264374F324524E30C02C331cF28aa879;
    address constant FORWARDER = 0xF8344CFd5c43616a4366C34E3EEE75af79a74482;
    address public JAM = 0xbeb0b0623f66bE8cE162EbDfA2ec543A522F4ea6;

    INonfungiblePositionManager public nfpm = INonfungiblePositionManager(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);
    ISwapRouter public V3router = ISwapRouter(0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45);
    IUniswapV3Pool public WETHv3pool = IUniswapV3Pool(0xC6962004f452bE9203591991D15f6b388e09E8D0);
    IPoolManager public poolManager = IPoolManager(0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32);

    IERC20 public GHO = IERC20(0x7dfF72693f6A4149b17e7C6314655f6A9F7c8B33);
    IERC20 public USDT = IERC20(0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9);
    IERC20 public USDC = IERC20(0xaf88d065e77c8cC2239327C5EDb3A432268e5831);
    IERC20 public DAI = IERC20(0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1);
    IERC20 public USDS = IERC20(0x6491c05A82219b8D1479057361ff1654749b876b);
    IERC20 public USDE = IERC20(0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34);
    IERC20 public CRVUSD = IERC20(0x498Bf2B1e120FeD3ad3D42EA2165E9b73f99C1e5);
    IERC20 public FRAX = IERC20(0x80Eede496655FB9047dd39d9f418d5483ED600df);

    IERC4626 public USDCvault = IERC4626(0xbeeff1D5dE8F79ff37a151681100B039661da518);
    IERC4626 public smokehouseUSDTvault = IERC4626(0xbeeff77CE5C059445714E6A3490E273fE7F2492F);
    address aTokenDAIonARB = 0x82E64f49Ed5EC1bC6e43DAD4FC8Af9bb3A2312EE;
    address aTokenFRAXonARB = 0x38d693cE1dF5AaDF7bC62595A37D667aD57922e5;
    address aTokenGHOonARB = 0xeBe517846d0F36eCEd99C735cbF6131e1fEB775D;

    IERC20 public SFRAX = IERC20(0x5Bff88cA1442c2496f7E475E9e7786383Bc070c0);
    IERC20 public SUSDS = IERC20(0xdDb46999F8891663a8F2828d25298f70416d7610);
    IERC20 public SUSDE = IERC20(0x211Cc4DD073734dA055fbF44a2b4667d5E5fE5d2);
    IERC20 public SCRVUSD = IERC20(0xEfB6601Df148677A338720156E2eFd3c5Ba8809d);

    address[] public STABLECOINS;
    address[] public VAULTS;
    Basket public QUID;

    VogueCore public CORE;
    Vogue public V4;
    Rover public V3;
    Aux public AUX;
    Amp public AMP;
    Jury public jury;
    Court public court;
    Link public LINK;

    function run() public { // handle private key...
        string memory privateKeyStr = vm.envString(
                                     "PRIVATE_KEY");
        uint256 deployerPrivateKey;
        if (bytes(privateKeyStr).length > 2 &&
            bytes(privateKeyStr)[0] == 0x30 &&
            bytes(privateKeyStr)[1] == 0x78) {
            deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        } else {
            deployerPrivateKey = vm.parseUint(
                string(abi.encodePacked("0x",
                          privateKeyStr)));
        }
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
        vm.startBroadcast(deployerPrivateKey);
        AMP = new Amp(aavePool, aaveData, aaveAddr);
        V3 = new Rover(address(AMP), address(WETH),
            address(USDC), address(nfpm),
            address(WETHv3pool),
            address(V3router), true);

        V4 = new Vogue();
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

        QUID.setup(address(LINK),
        address(court), address(jury));

        CORE.setup(address(V4), address(AUX), address(WETHv3pool));
        V4.setup(address(QUID), address(AUX), address(CORE));

        AUX.setQuid(address(QUID), JAM);
        V3.setAux(address(AUX));

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
