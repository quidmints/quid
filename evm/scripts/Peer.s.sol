
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {Basket} from "../src/Basket.sol";

/// @title WirePeers — L1 Basket ↔ Solana only
/// @notice L2 Baskets are separate ERC20s. They do NOT peer with L1.
///         L2 QD arrives on L1 via native bridges (Arb/Base/Poly canonical),
///         not via OFT. OFT peering is exclusively L1 ↔ Solana.
///
/// Usage (run on L1 only):
///   DEPLOYER_KEY=0x... BASKET_L1=0x... SOLANA_PEER=0x... \
///   forge script script/WirePeers.s.sol --rpc-url $L1_RPC --broadcast

contract Peer is Script {
    uint32 constant SOL_EID = 30168;

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_KEY");
        Basket basket = Basket(vm.envAddress("BASKET_L1"));
        bytes32 solPeer = vm.envBytes32("SOLANA_PEER");

        vm.startBroadcast(pk);
        basket.setPeer(SOL_EID, solPeer);
        console.log("L1 Basket peered with Solana");
        vm.stopBroadcast();
    }
}
