
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

library Types {
    /// @notice Vogue
    /// self-managed LP
    struct SelfManaged {
        uint created;
        address owner;
        int24 lower;
        int24 upper;
        int liq;
    }

    /// @notice Amp AAVE
    /// leveraged position
    struct viaAAVE {
        uint breakeven;
        uint supplied;
        uint borrowed;
        uint buffer;
        int price;
    }

    /// @notice Vogue LP deposit...
    /// MasterChef-style fee tracking
    struct Deposit { uint pooled_eth;
        uint usd_owed;
        uint fees_eth;
        uint fees_usd;
    }

    /// @notice routing
    struct AuxContext {
        address v3Pool;
        address v3Router;
        address weth;
        address usdc;
        address vault;
        address v4;
        address core;
        address rover;
        uint24 v3Fee;
        address hub;
        uint vaultType;
        bool nativeWETH;
    }

    struct PositionEntry {
        uint    capital;
        uint    tokens;
        bytes32 commitmentHash;
        uint    timestamp;
        uint    revealedConfidence; // max 10000 bps, 0 = not yet revealed
    }

    struct Position {
        address user;
        uint8   side;
        uint    totalCapital;
        uint    totalTokens;
        bytes32 commitmentHash;
        bool    revealed;
        bool    autoRollover;
        bool    paidOut;
        uint    weight;              // final weight (confidence × time decay)
        uint    entryBlock;          // block of last entry — flash loan guard
        uint    entryTimestamp;      // when capital entered this round
        uint    revealedConfidence;  // max 10000 bps
        uint    lastRound;           // round this position is active in
        address delegate; // our keeper so user doesnt need to manually reveal their commit
    }

    /// @dev Forensic evidence submitted by CRE workflow.
    /// Advisory only — DVM vote is sole source of truth.
    struct ForensicEvidence {
        uint8 claimedSide;
        uint8 recommendedSide;
        uint maxDeviationBps;
        uint8 confidence; // 0-100
        bytes32 evidenceHash;
        // keccak256 of data
        uint timestamp;
    }

    enum Phase { Trading, Asserting,
    Disputed, Resolved, Arbitrating }

    struct Market {
        uint8   numSides;       // stables.length + 1
        uint    startTime;      // initial creation
        uint    roundStartTime; // beginning of current round
        int128  b;              // LSMR liquidity parameter
        Phase   phase;
        bool    resolved;

        uint    resolutionTimestamp;
        uint8    claimedSide;  // what the asserter claims
        uint8    winningSide;  // confirmed outcome
        uint8    consecutiveRejections; // escalates bond after griefing
        bytes32  assertionId;
        address  asserter;
        uint     revealDeadline;
        uint     requestTimestamp; // when requestResolution was called

        int128[12] q;
        // LSMR quantities per side
        uint[12] capitalPerSide;
        uint    totalCapital;
        uint    positionsTotal;
        uint    positionsRevealed;

        uint    totalWinnerCapital;
        uint    totalLoserCapital;
        uint    totalWinnerWeight;
        uint    totalLoserWeight;
        bool    weightsComplete;
        bool    payoutsComplete;
        bool    assertionPending;   // blocks new buys during OOV3 liveness
        uint    positionsPaidOut;   // tracks payout progress for safe restart
        uint    positionsWeighed;   // tracks weight computation for safe weightsComplete
        uint    roundNumber;
    }

    struct RouteParams {
        uint160 sqrtPriceX96;
        bool    zeroForOne;
        address token;
        uint    amount;
        uint    pooled;
        uint    v4Price;
        uint    v3Price;
        address recipient;
    }

    struct DepegStats {
        uint   capOnSide;
        uint   capNone;
        uint   capTotal;
        bool   depegged;
        uint8  side;
        uint   avgConf;      // Bayesian prior: last round's avg confidence on this side
        uint   severityBps;  // depeg severity when resolved; 0 if not depegged
    }

    /// @dev Matches JamOrderLib.sol exactly for ABI compatibility with the
    ///      deployed JamSettlement at 0xbeb0b0623f66bE8cE162EbDfA2ec543A522F4ea6.
    ///      EIP-712 ORDER_TYPE (from JamOrderLib):
    ///        JamOrder(address taker,address receiver,uint256 expiry,
    ///        uint256 exclusivityDeadline,uint256 nonce,address executor,
    ///        uint256 partnerInfo,address[] sellTokens,address[] buyTokens,
    ///        uint256[] sellAmounts,uint256[] buyAmounts,bytes32 hooksHash)
    ///      Note: usingPermit2 is in the struct but excluded from ORDER_TYPE.
    ///      Note: hooksHash is passed as a parameter to hash(), not a struct field.
    struct JamOrder {
        address   taker;                 // order creator (EOA that signed)
        address   receiver;              // where buy tokens are sent
        uint256   expiry;                // block.timestamp deadline
        uint256   exclusivityDeadline;   // until this timestamp only executor can fill; 0 = open
        uint256   nonce;                 // unique per taker, prevents replay
        address   executor;              // solver address, or address(0) for open
        uint256   partnerInfo;           // packed [partnerAddress, partnerFee, protocolFee]
        address[] sellTokens;            // tokens taker is selling
        address[] buyTokens;             // tokens taker wants to receive
        uint256[] sellAmounts;           // amounts of each sell token
        uint256[] buyAmounts;            // minimum amounts of each buy token
        bool      usingPermit2;          // true if taker approved via Permit2 (excluded from ORDER_TYPE)
    }

    /// @notice A single external call for JamSettlement to execute.
    /// @dev Matches Bebop's JamInteraction.Data exactly.
    /// Used for settlement interactions (executed by JamSettlement)
    /// and for repay swaps (executed directly by the Solver contract).
    struct Interaction {
        bool result; // if true, runInteractions checks call returns true
        address to; // target contract to call
        uint256 value; // ETH value to forward
        bytes data; // calldata for the external call
    }
}
