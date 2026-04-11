
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

library MessageCodec { // always plead the 5th...
    uint8 public constant RESOLUTION_REQUEST = 5;
    // A life is like a book. A book is like
    uint8 public constant FINAL_RULING = 6;
    // a box...a box has six sides. Inspite &
    // outside, so, how do you get to what's
    // insight? do you get what's inside, out?
    uint8 public constant JURY_COMPENSATION = 7;

    error InvalidMessageType();
    error InvalidMessageLength();
    error InvalidMarketId();
    error InvalidSideCount();
    error InvalidAmount();
    error ResolutionTimeInPast();
    error InvalidWinnerCount();
    error InvalidSplits();

    /// @notice Resolution request data from Solana
    /// @dev Using struct to avoid stack too deep errors
    struct ResolutionRequestData { uint64 marketId;
        uint8 numSides; uint8 numWinners;
        bool requiresUnanimous;
        uint256 appealCost; bytes32 requester;
    }

    function encodeUint64LE(uint64 value) internal pure returns (bytes memory) {
        bytes memory result = new bytes(8);
        result[0] = bytes1(uint8(value));
        result[1] = bytes1(uint8(value >> 8));
        result[2] = bytes1(uint8(value >> 16));
        result[3] = bytes1(uint8(value >> 24));
        result[4] = bytes1(uint8(value >> 32));
        result[5] = bytes1(uint8(value >> 40));
        result[6] = bytes1(uint8(value >> 48));
        result[7] = bytes1(uint8(value >> 56));
        return result;
    }

    function decodeUint64LE(bytes memory data, uint256 offset)
        internal pure returns (uint64 result) {
        require(data.length >= offset + 8,
            "Insufficient data for uint64");

        result = uint64(uint8(data[offset]))
            | (uint64(uint8(data[offset + 1])) << 8)
            | (uint64(uint8(data[offset + 2])) << 16)
            | (uint64(uint8(data[offset + 3])) << 24)
            | (uint64(uint8(data[offset + 4])) << 32)
            | (uint64(uint8(data[offset + 5])) << 40)
            | (uint64(uint8(data[offset + 6])) << 48)
            | (uint64(uint8(data[offset + 7])) << 56);
    }

    function decodeUint64LECalldata(bytes calldata data, uint256 offset)
        internal pure returns (uint64) {
        require(data.length >= offset + 8,
            "Insufficient data for uint64");

        return uint64(uint8(data[offset]))
            | (uint64(uint8(data[offset + 1])) << 8)
            | (uint64(uint8(data[offset + 2])) << 16)
            | (uint64(uint8(data[offset + 3])) << 24)
            | (uint64(uint8(data[offset + 4])) << 32)
            | (uint64(uint8(data[offset + 5])) << 40)
            | (uint64(uint8(data[offset + 6])) << 48)
            | (uint64(uint8(data[offset + 7])) << 56);
    }

    // ============================================================================
    // ENCODING FUNCTIONS - Ethereum → Better call Sol...ana
    // ============================================================================

    /**
     * @notice Encode final ruling message with multi-winner support
     * @dev Message format (variable length):
     *      [0] = FINAL_RULING
     *      [1-8] = marketId (LE)
     *      [9] = numWinners (0 = force majeure, 1+ = winners)
     *      For each winner:
     *        [offset] = winningSide (1 byte)
     *
     *      INTERPRETATION:
     *      - Empty winners (length=0) = Force majeure (market cancelled)
     *      - Otherwise = Normal resolution, Solana calculates equal splits
     */
     function encodeFinalRuling(uint64 marketId,
         uint8[] memory winningSides) internal pure returns (bytes memory) {
         if (marketId == 0) revert InvalidMarketId();

         bytes memory message = abi.encodePacked(FINAL_RULING,
             encodeUint64LE(marketId), uint8(winningSides.length));

         for (uint i = 0; i < winningSides.length; i++) {
             message = abi.encodePacked(message, winningSides[i]);
         }
         return message;
    }

   /**
    * @notice Decode resolution request from Solana
    * @dev Message format (52 bytes):
    *      [0] = RESOLUTION_REQUEST (5)
    *      [1-8] = marketId (uint64, little-endian)
    *      [9] = numSides (uint8)
    *      [10] = numWinners (uint8)
    *      [11] = requiresUnanimous (0 or 1)
    *      [12-19] = appealCost (uint64, little-endian)
    *      [20-51] = requester (32 bytes, Solana pubkey)
    */
    function decodeResolutionRequest(bytes calldata message) internal pure
        returns (ResolutionRequestData memory data) {
        uint256 offset = 1;
        data.marketId = decodeUint64LECalldata(message, offset);

        offset += 8;
        data.numSides = uint8(message[offset]);
        offset += 1;

        data.numWinners = uint8(message[offset]);
        offset += 1;

        data.requiresUnanimous = uint8(message[offset]) == 1;
        offset += 1;

        data.appealCost = uint256(decodeUint64LECalldata(message, offset));
        offset += 8;

        data.requester = bytes32(message[offset:offset+32]);
    }

    /**
     * @notice Decode jury compensation from Solana
     * @dev Format (17 bytes):
     *      [0] = JURY_COMPENSATION (7)
     *      [1-8] = marketId (LE)
     *      [9-16] = amount (LE, in Solana decimals - 6)
     */
    function decodeJuryCompensation(bytes memory data)
        internal pure returns (uint64 marketId, uint64 amount) {
        if (data.length < 17) revert InvalidMessageLength();
        if (uint8(data[0]) != JURY_COMPENSATION) revert InvalidMessageType();

        marketId = decodeUint64LE(data, 1);
        amount = decodeUint64LE(data, 9);

        if (marketId == 0) revert InvalidMarketId();
        if (amount == 0) revert InvalidAmount();
        require(amount <= 1_000_000 * 1e6,
          "Compensation exceeds maximum");
    }

    function getMessageType(bytes memory data) internal pure returns (uint8) {
        if (data.length == 0) revert InvalidMessageLength();
        return uint8(data[0]);
    }

    function toEthereumAmount(uint64 solanaAmount) internal pure returns (uint256) {
        return uint256(solanaAmount) * 1e12;
    }

    function isForceMajeure(uint8[] memory verdict) internal pure returns (bool) {
        return verdict.length == 0;
    }
}
