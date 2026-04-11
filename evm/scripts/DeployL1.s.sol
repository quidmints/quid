
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/console.sol";

import {IUniswapV3Pool} from "../src/imports/v3/IUniswapV3Pool.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IV3SwapRouter as ISwapRouter} from "../src/imports/v3/IV3SwapRouter.sol";
import {INonfungiblePositionManager} from "../src/imports/v3/INonfungiblePositionManager.sol";

import {Jury} from "../src/Jury.sol";
import {Court} from "../src/Court.sol";
import {Vogue} from "../src/Vogue.sol";
import {Rover} from "../src/Rover.sol";

import {Basket} from "../src/Basket.sol";
import {VogueCore} from "../src/VogueCore.sol";
import {Types} from "../src/imports/Types.sol";
import {BasketLib} from "../src/imports/BasketLib.sol";

import {Script} from "forge-std/Script.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";

import {Aux} from "../src/Aux.sol";
import {Amp} from "../src/Amp.sol";
import {Link} from "../src/Link.sol";

contract Deploy is Script {

    ISwapRouter public V3router = ISwapRouter(0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45);
    IPoolManager public poolManager = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    IUniswapV3Pool public WETHv3pool = IUniswapV3Pool(0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640);
    INonfungiblePositionManager public nfpm = INonfungiblePositionManager(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);

    address public JAM = 0xbeb0b0623f66bE8cE162EbDfA2ec543A522F4ea6;
    address public aavePool  = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address public aaveData  = 0x56b7A1012765C285afAC8b8F25C69Bf10ccfE978;
    address public aaveAddr  = 0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e;
    address public aaveHub   = 0xCca852Bc40e560adC3b1Cc58CA5b55638ce826c9;
    address public aaveSpoke = 0x94e7A5dCbE816e498b89aB752661904E2F56c485;
    address public stabilityPool = 0x5721cbbd64fc7Ae3Ef44A0A3F9a790A9264Cf9BF;

    address constant FORWARDER = 0x0b93082D9b3C7C97fAcd250082899BAcf3af3885;

    IERC20 public WETH = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20 public GHO = IERC20(0x40D16FC0246aD3160Ccc09B8D0D3A2cD28aE6C2f);
    IERC20 public DAI = IERC20(0x6B175474E89094C44Da98b954EedeAC495271d0F);
    IERC20 public USDT = IERC20(0xdAC17F958D2ee523a2206206994597C13D831ec7);
    IERC20 public USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);

    IERC20 public PYUSD = IERC20(0x6c3ea9036406852006290770BEdFcAbA0e23A0e8);
    IERC20 public USDS = IERC20(0xdC035D45d973E3EC169d2276DDab16f1e407384F);
    IERC20 public USDE = IERC20(0x4c9EDD5852cd905f086C759E8383e09bff1E68B3);
    IERC20 public CRVUSD = IERC20(0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E);
    IERC20 public FRAX = IERC20(0xCAcd6fd266aF91b8AeD52aCCc382b4e165586E29);
    IERC20 public BOLD = IERC20(0x6440f144b7e50D6a8439336510312d2F54beB01D);
    IERC20 public USYC = IERC20(0x136471a34f6ef19fE571EFFC1CA711fdb8E49f2b);

    address public pyusdMorpho = 0xb576765fB15505433aF24FEe2c0325895C559FB2;
    IERC4626 public hashnote = IERC4626(0xeE35F963BFC71b51eC95147f26c030D674ea30e6);
    IERC4626 public SDAI = IERC4626(0x83F20F44975D03b1b09e64809B757c47f942BEeA);
    IERC4626 public SFRAX = IERC4626(0xcf62F905562626CfcDD2261162a51fd02Fc9c5b6);
    IERC4626 public SUSDS = IERC4626(0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD);
    IERC4626 public SUSDE = IERC4626(0x9D39A5DE30e57443BfF2A8307A4256c8797A3497);
    IERC4626 public SCRVUSD = IERC4626(0x0655977FEb2f289A4aB78af67BAB0d17aAb84367);

    address[] public STABLECOINS;
    address[] public VAULTS;

    Basket public QUID;
    VogueCore public CORE;
    Vogue public V4;
    Rover public V3;
    Aux public AUX;
    Amp public AMP;
    Link public LINK;
    Jury public jury;
    Court public court;

    function run() public {
        string memory privateKeyStr = vm.envString("PRIVATE_KEY");
        uint deployerPrivateKey;
        if (bytes(privateKeyStr).length > 2 &&
            bytes(privateKeyStr)[0] == 0x30 &&
            bytes(privateKeyStr)[1] == 0x78) {
            deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        } else {
            deployerPrivateKey = vm.parseUint(
                string(abi.encodePacked("0x", privateKeyStr)));
        }

        address deployer = vm.addr(deployerPrivateKey);
        console.log("=== Pre-broadcast ===");
        console.log("Deployer:", deployer);

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

        vm.startBroadcast(deployerPrivateKey);

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

        QUID.setup(address(LINK),
        address(court), address(jury));

        CORE.setup(address(V4), address(AUX), address(WETHv3pool));
        V4.setup(address(QUID), address(AUX), address(CORE));
        AUX.setQuid(address(QUID), JAM, aaveHub, aaveSpoke);
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
