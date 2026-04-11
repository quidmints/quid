// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/console.sol";

import {IUniswapV3Pool} from "../src/imports/v3/IUniswapV3Pool.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IV3SwapRouter as ISwapRouter} from "../src/imports/v3/IV3SwapRouter.sol";
import {INonfungiblePositionManager} from "../src/imports/v3/INonfungiblePositionManager.sol";

import {AuxBase as Aux} from "../src/L2/AuxBase.sol";
import {VogueUni as Vogue} from "../src/L2/VogueUni.sol";
import {BasketLib} from "../src/imports/BasketLib.sol";
import {VogueCore} from "../src/VogueCore.sol";
import {Types} from "../src/imports/Types.sol";

import {Amp} from "../src/Amp.sol";
import {Link} from "../src/Link.sol";
import {Jury} from "../src/Jury.sol";
import {Court} from "../src/Court.sol";
import {Rover} from "../src/Rover.sol";
import {Basket} from "../src/Basket.sol";

import {Script} from "forge-std/Script.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";

// forge script scripts/DeployL1.s.sol:Deploy --rpc-url mainnet --broadcast --verify
// If verification fails during deployment (network issues, etc.), you can retry later:
// forge script scripts/DeployL1.s.sol:Deploy --rpc-url mainnet --resume --verify

contract Deploy is Script {
    IERC20 public WETH = IERC20(0x4200000000000000000000000000000000000006);
    address public aavePool = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;
    address public aaveData = 0xb84A20e848baE3e13897934bB4e74E2225f4546B;
    address public aaveAddr = 0xe20fCBdBfFC4Dd138cE8b2E6FBb6CB49777ad64D;

    INonfungiblePositionManager public nfpm = INonfungiblePositionManager(0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1);
    ISwapRouter public V3router = ISwapRouter(0x2626664c2603336E57B271c5C0b26F421741e481);
    IUniswapV3Pool public WETHv3pool = IUniswapV3Pool(0xd0b53D9277642d899DF5C87A3966A349A798F224);
    IPoolManager public poolManager = IPoolManager(0x498581fF718922c3f8e6A244956aF099B2652b2b);

    IERC20 public GHO = IERC20(0x6Bb7a212910682DCFdbd5BCBb3e28FB4E8da10Ee);
    IERC20 public USDC = IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    IERC20 public USDT = IERC20(0xfde4C96c8593536E31F229EA8f37b2ADa2699bb2);
    IERC20 public DAI = IERC20(0x50c5725949A6F0c72E6C4a641F24049A917DB0Cb);
    IERC20 public USDS = IERC20(0x820C137fa70C8691f0e44Dc420a5e53c168921Dc);
    IERC20 public USDE = IERC20(0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34);
    IERC20 public CRVUSD = IERC20(0x417Ac0e078398C154EdFadD9Ef675d30Be60Af93);
    IERC20 public FRAX = IERC20(0xe5020A6d073a794B6E7f05678707dE47986Fb0b6);

    // Morpho vaults
    IERC4626 public sUSDSvault = IERC4626(0x0FE5b4aF0337Fd5b2E1675D5f5E8c9101E4D3c7e);
    IERC4626 public gauntletWETHvault = IERC4626(0x27D8c7273fd3fcC6956a0B370cE5Fd4A7fc65c18);
    IERC4626 public smokehouseUSDCvault = IERC4626(0xeE8F4eC5672F09119b96Ab6fB59C27E1b7e44b61);
    address public aTokenGHOonBase = 0x067ae75628177FD257c2B1e500993e1a0baBcBd1;

    IERC20 public SFRAX = IERC20(0x91A3f8a8d7a881fBDfcfEcd7A2Dc92a46DCfa14e);
    IERC20 public SUSDS = IERC20(0x5875eEE11Cf8398102FdAd704C9E96607675467a);
    IERC20 public SUSDE = IERC20(0x211Cc4DD073734dA055fbF44a2b4667d5E5fE5d2);
    IERC20 public SCRVUSD = IERC20(0x646A737B9B6024e49f5908762B3fF73e65B5160c);

    address public JAM = 0xbeb0b0623f66bE8cE162EbDfA2ec543A522F4ea6;
    address constant FORWARDER = 0xF8344CFd5c43616a4366C34E3EEE75af79a74482;

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

        STABLECOINS = [ // do not change
            address(USDC), address(SUSDS),
            address(GHO), address(USDT),
            address(DAI), address(FRAX),
            address(USDE), address(USDS),
            address(CRVUSD), address(SFRAX),
            address(SUSDE), address(SCRVUSD)
        ]; // the order here is essential...
        VAULTS = [
            address(smokehouseUSDCvault),
            address(sUSDSvault),
            aTokenGHOonBase
        ];

        vm.startBroadcast(deployerPrivateKey);
        AMP = new Amp(aavePool, aaveData, aaveAddr);
        V3 = new Rover(address(AMP), address(WETH),
            address(USDC), address(nfpm),
            address(WETHv3pool),
            address(V3router), true);

        V4 = new Vogue(address(gauntletWETHvault));
        CORE = new VogueCore(poolManager);
        AUX = new Aux(
            address(V4), address(CORE),
            address(gauntletWETHvault),
            address(AMP), address(aavePool),
            address(WETHv3pool), address(V3router),
            address(V3), STABLECOINS, VAULTS);

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
        V4.setup(address(QUID), address(AUX), address(CORE), true);
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
