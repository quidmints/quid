// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {ILayerZeroEndpointV2} from "../src/imports/oapp/interfaces/ILayerZeroEndpointV2.sol";
import {SetConfigParam} from "../src/imports/oapp/interfaces/IMessageLibManager.sol";
import {Basket} from "../src/Basket.sol";

contract LZconfig is Script {
    // LZ endpoint (same address all EVMs)
    address constant LZ_ENDPOINT = 0x1a44076050125825900e736c501f859c50fE728c;

    // Deploy-time addresses, read from the environment rather than pasted in:
    // a placeholder that does not compile is a script nobody can run, and one
    // that does compile is worse.
    address BASKET;   // deployed Basket
    address HOOK;     // Link
    address COURT;    // Court
    address JURY;     // Jury

    // Solana peer — the OApp Store PDA, 32 bytes, not the program id.
    bytes32 SOL_PEER;

    // L2s — parallel arrays
    uint32[]  l2Eids;
    bytes32[] l2Peers;

    // Ethereum Mainnet (EID 30101)
    // SendUln302
    address constant SEND_LIB =
        0xbB2Ea70C9E858123480642Cf96acbcCE1372dCe1;

    // ReceiveUln302
    address constant RECEIVE_LIB =
        0xc02Ab410f0734EFa3F14628780e6e695156024C2;

    // LayerZero Labs DVN
    address constant DVN_A =
        0x589dEDbD617e0CBcB916A9223F4d1300c294236b;

    // Google Cloud DVN
    address constant DVN_B =
        0x8FafAE7Dd957044088b3d0F67359C327c6200d18;
    uint32 constant SOL_EID = 30168;

    /// Block confirmations a DVN waits for before attesting. Explicit rather
    /// than 0: zero means "whatever the library default is", which is a value
    /// somebody else can change.
    uint64 constant CONFIRMATIONS = 15;

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PK");
        BASKET   = vm.envAddress("BASKET");
        HOOK     = vm.envAddress("HOOK");
        COURT    = vm.envAddress("COURT");
        JURY     = vm.envAddress("JURY");
        SOL_PEER = vm.envBytes32("SOL_PEER");
        vm.startBroadcast(pk);

        Basket basket = Basket(payable(BASKET));
        ILayerZeroEndpointV2 endpoint = ILayerZeroEndpointV2(LZ_ENDPOINT);

        // ── 1. Wire up internal contracts + create market ──────────────
        basket.setup(HOOK, COURT, JURY);

        // ── 2. Register Solana peer ────────────────────────────────────
        basket.setPeer(SOL_EID, SOL_PEER);

        // ── 3. Register every peer ─────────────────────────────────────
        _populateL2Arrays();
        for (uint i; i < l2Eids.length; i++) {
            basket.setPeer(l2Eids[i], l2Peers[i]);
        }

        // ── 4. Bind the message libraries for each pathway ─────────────
        // Without this the pathway runs on the endpoint's defaults, and a
        // config set on a library that was never selected changes nothing.
        // This is the step whose absence leaves an OApp on 1-of-1 while
        // looking configured.
        endpoint.setSendLibrary(BASKET, SOL_EID, SEND_LIB);
        endpoint.setReceiveLibrary(BASKET, SOL_EID, RECEIVE_LIB, 0);

        // ── 5. DVN config — send direction (EVM → Solana) ──────────────
        bytes memory ulnCfg = _encodeUlnConfig();

        SetConfigParam[] memory sendCfg =
            new SetConfigParam[](1);
        sendCfg[0] = SetConfigParam({
            eid:        SOL_EID,
            configType: 2,        // ULN_CONFIG_TYPE
            config:     ulnCfg
        });
        endpoint.setConfig(BASKET, SEND_LIB, sendCfg);

        // ── 6. DVN config — receive direction (Solana → EVM) ───────────
        SetConfigParam[] memory recvCfg =
            new SetConfigParam[](1);
        recvCfg[0] = SetConfigParam({
            eid:        SOL_EID,
            configType: 2,
            config:     ulnCfg
        });
        endpoint.setConfig(BASKET, RECEIVE_LIB, recvCfg);

        // ── 7. Same libraries and same DVN set for every L2 ────────────
        for (uint i; i < l2Eids.length; i++) {
            endpoint.setSendLibrary(BASKET, l2Eids[i], SEND_LIB);
            endpoint.setReceiveLibrary(BASKET, l2Eids[i], RECEIVE_LIB, 0);

            SetConfigParam[] memory l2Cfg =
                new SetConfigParam[](1);
            l2Cfg[0] = SetConfigParam({
                eid: l2Eids[i], configType: 2, config: ulnCfg
            });
            endpoint.setConfig(BASKET, SEND_LIB, l2Cfg);
            endpoint.setConfig(BASKET, RECEIVE_LIB, l2Cfg);
        }

        // ── 8. Lock — no further owner calls possible after this ────────
        basket.renounceOwnership();

        vm.stopBroadcast();
    }

    function _encodeUlnConfig() internal view returns (bytes memory) {
        address[] memory required = new address[](2);
        required[0] = DVN_A;
        required[1] = DVN_B;
        address[] memory optional = new address[](0);

        return abi.encode(
            CONFIRMATIONS,
            uint8(2),    // requiredDVNCount
            uint8(0),    // optionalDVNCount
            uint8(0),    // optionalDVNThreshold
            required,
            optional
        );
    }

    function _populateL2Arrays() internal {
        // e.g. Base, Arbitrum, Optimism
        l2Eids  = [30184, 30110, 30109];   // Base, Arbitrum, Polygon
        l2Peers = [vm.envBytes32("BASE_PEER"),
                   vm.envBytes32("ARBI_PEER"),
                   vm.envBytes32("POLY_PEER")];
    }
}