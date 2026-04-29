// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {ILayerZeroEndpointV2} from "./imports/oapp/interfaces/ILayerZeroEndpointV2.sol";
import {Basket} from "../src/Basket.sol";

contract LZconfig is Script {
    // LZ endpoint (same address all EVMs)
    address constant LZ_ENDPOINT = 0x1a44076050125825900e736c501f859c50fE728c;

    // Fill these before running
    address constant BASKET       = 0x...; // deployed Basket
    address constant HOOK         = 0x...; // Link
    address constant COURT        = 0x...; // Court
    address constant JURY         = 0x...; // Jury

    // Solana peer — 32-byte program ID as bytes32
    bytes32 constant SOL_PEER     = bytes32(0x...);

    // L2s — parallel arrays
    uint32[]  l2Eids;
    bytes32[] l2Peers;
    address[] l2BasketAddrs;

    // LZ send/receive lib addresses for this chain (look up per-chain in LZ docs)
    address constant SEND_LIB    = 0x...;
    address constant RECEIVE_LIB = 0x...;

    // DVNs to require (e.g. LZ DVN + Google Cloud DVN)
    address constant DVN_A = 0x...;
    address constant DVN_B = 0x...;

    uint32 constant SOL_EID = 30168;

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PK");
        vm.startBroadcast(pk);

        Basket basket = Basket(payable(BASKET));
        ILayerZeroEndpointV2 endpoint = ILayerZeroEndpointV2(LZ_ENDPOINT);

        // ── 1. Wire up internal contracts + create market ──────────────
        basket.setup(HOOK, COURT, JURY);

        // ── 2. Register Solana peer ────────────────────────────────────
        basket.setPeer(SOL_EID, SOL_PEER);

        // ── 3. Register all L2 baskets + their peers in one pass ───────
        _populateL2Arrays();
        for (uint i; i < l2Eids.length; i++) {
            basket.setPeer(l2Eids[i], l2Peers[i]);
            basket.registerL2Basket(l2BasketAddrs[i]);
        }

        // ── 4. DVN config — send direction (EVM → Solana) ──────────────
        bytes memory ulnCfg = _encodeUlnConfig();

        ILayerZeroEndpointV2.SetConfigParam[] memory sendCfg =
            new ILayerZeroEndpointV2.SetConfigParam[](1);
        sendCfg[0] = ILayerZeroEndpointV2.SetConfigParam({
            eid:        SOL_EID,
            configType: 2,        // ULN_CONFIG_TYPE
            config:     ulnCfg
        });
        endpoint.setConfig(BASKET, SEND_LIB, sendCfg);

        // ── 5. DVN config — receive direction (Solana → EVM) ───────────
        ILayerZeroEndpointV2.SetConfigParam[] memory recvCfg =
            new ILayerZeroEndpointV2.SetConfigParam[](1);
        recvCfg[0] = ILayerZeroEndpointV2.SetConfigParam({
            eid:        SOL_EID,
            configType: 2,
            config:     ulnCfg
        });
        endpoint.setConfig(BASKET, RECEIVE_LIB, recvCfg);

        // ── 6. Repeat DVN config for each L2 eid ───────────────────────
        for (uint i; i < l2Eids.length; i++) {
            ILayerZeroEndpointV2.SetConfigParam[] memory l2Send =
                new ILayerZeroEndpointV2.SetConfigParam[](1);
            l2Send[0] = ILayerZeroEndpointV2.SetConfigParam({
                eid: l2Eids[i], configType: 2, config: ulnCfg
            });
            endpoint.setConfig(BASKET, SEND_LIB, l2Send);
            endpoint.setConfig(BASKET, RECEIVE_LIB, l2Send);
        }

        // ── 7. Lock — no further owner calls possible after this ────────
        basket.renounceOwnership();

        vm.stopBroadcast();
    }

    function _encodeUlnConfig() internal view returns (bytes memory) {
        address[] memory required = new address[](2);
        required[0] = DVN_A;
        required[1] = DVN_B;
        address[] memory optional = new address[](0);

        return abi.encode(
            uint64(0),   // confirmations — 0 = use library default
            uint8(2),    // requiredDVNCount
            uint8(0),    // optionalDVNCount
            uint8(0),    // optionalDVNThreshold
            required,
            optional
        );
    }

    function _populateL2Arrays() internal {
        // e.g. Base, Arbitrum, Optimism
        l2Eids        = [30184,    30110,    30111];
        l2Peers       = [bytes32(0x...), bytes32(0x...), bytes32(0x...)];
        l2BasketAddrs = [0x...,    0x...,    0x...];
    }
}