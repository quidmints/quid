#!/usr/bin/env node
/**
 * encodeHeader.js - Fetch and RLP-encode an Ethereum block header
 * 
 * Usage: node encodeHeader.js <blockNumber>
 * Output: 0x-prefixed hex string of RLP-encoded header to stdout
 * 
 * IMPORTANT: This script outputs ONLY the hex string to stdout.
 * All errors/debug info go to stderr (which Foundry FFI ignores).
 * 
 * For Foundry FFI usage:
 *   bytes memory result = vm.ffi(["node", "encodeHeader.js", "21479000"]);
 *   bytes memory header = vm.parseBytes(string(result));
 */

const RLP = require('rlp');
const { ethers } = require("ethers");

// Manually convert bytes to hex string - bulletproof implementation
function bytesToHex(bytes) {
    const hexChars = '0123456789abcdef';
    let hex = '0x';
    for (let i = 0; i < bytes.length; i++) {
        const b = bytes[i];
        hex += hexChars[(b >> 4) & 0xf];
        hex += hexChars[b & 0xf];
    }
    return hex;
}

// Convert hex string to Buffer for RLP encoding
function hexToBuffer(hex) {
    if (!hex || hex === '0x' || hex === '0x0') {
        return Buffer.alloc(0);
    }
    let cleaned = hex.slice(2);
    if (cleaned.length % 2 !== 0) {
        cleaned = '0' + cleaned;
    }
    return Buffer.from(cleaned, 'hex');
}

async function main() {
    const blockNumber = parseInt(process.argv[2]);
    
    if (isNaN(blockNumber)) {
        console.error("Usage: node encodeHeader.js <blockNumber>");
        process.stdout.write("0x"); // Always output valid hex for FFI
        process.exit(1);
    }
    
    const provider = new ethers.JsonRpcProvider("https://ethereum-rpc.publicnode.com");
    
    let rawBlock;
    try {
        rawBlock = await provider.send("eth_getBlockByNumber", [
            "0x" + blockNumber.toString(16),
            false
        ]);
    } catch (e) {
        console.error("RPC Error:", e.message);
        process.stdout.write("0x");
        process.exit(1);
    }
    
    if (!rawBlock) {
        console.error("Block not found:", blockNumber);
        process.stdout.write("0x");
        process.exit(1);
    }

    // Post-Cancun (Dencun) block header - 20 fields
    const blockHeader = [
        hexToBuffer(rawBlock.parentHash),
        hexToBuffer(rawBlock.sha3Uncles),
        hexToBuffer(rawBlock.miner),
        hexToBuffer(rawBlock.stateRoot),
        hexToBuffer(rawBlock.transactionsRoot),
        hexToBuffer(rawBlock.receiptsRoot),
        hexToBuffer(rawBlock.logsBloom),
        hexToBuffer(rawBlock.difficulty),
        hexToBuffer(rawBlock.number),
        hexToBuffer(rawBlock.gasLimit),
        hexToBuffer(rawBlock.gasUsed),
        hexToBuffer(rawBlock.timestamp),
        hexToBuffer(rawBlock.extraData),
        hexToBuffer(rawBlock.mixHash),
        hexToBuffer(rawBlock.nonce),
        hexToBuffer(rawBlock.baseFeePerGas),
        hexToBuffer(rawBlock.withdrawalsRoot),
        hexToBuffer(rawBlock.blobGasUsed),
        hexToBuffer(rawBlock.excessBlobGas),
        hexToBuffer(rawBlock.parentBeaconBlockRoot)
    ];

    const encoded = RLP.encode(blockHeader);
    
    // CRITICAL: Use manual hex conversion to guarantee ASCII output
    // This avoids any potential issues with Buffer.toString('hex')
    const encodedHex = bytesToHex(Buffer.from(encoded));

    // Verify hash matches
    const recreatedHash = ethers.keccak256(encodedHex);
    if (recreatedHash !== rawBlock.hash) {
        console.error("Hash mismatch!");
        console.error("Expected:", rawBlock.hash);
        console.error("Got:", recreatedHash);
        process.stdout.write("0x");
        process.exit(1);
    }

    // Output ONLY the hex string - this is what Foundry FFI captures
    process.stdout.write(encodedHex);
}

main().catch(err => { 
    console.error("Fatal error:", err.message);
    process.stdout.write("0x"); 
    process.exit(1); 
});