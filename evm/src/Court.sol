
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Jury} from "./Jury.sol";
import {Basket} from "./Basket.sol";
import {MessageCodec} from "./imports/MessageCodec.sol";
import {ReentrancyGuard} from "solmate/src/utils/ReentrancyGuard.sol";

/// @dev Link callback — delivers jury ruling if CRE unavailable.
/// @dev Solana prediction markets can use court as well (provided)
/// enough jurors have opted in through their basket deposit to serve
interface ILink {
    function receiveRuling(uint8 winningSide, uint16 severityBps) external;
}

contract Court is ReentrancyGuard {
    Jury public immutable jury;
    Basket public immutable QUID;

    /// @dev authorized to request arbitration.
    address public oracle;

    /// Ruling routed to Link.receiveRuling instead of Basket.sendToSolana.
    mapping(uint64 => bool) public isArbitration;

    /// @dev Auto-incrementing counter for arbitration IDs.
    /// Starts at 2^63 to avoid collision with Solana marketIds (small sequential).
    uint64 public arbitrationCounter = 2**63;

    uint constant APPEAL_WINDOW = 7 days;

    uint constant MAX_APPEALS = 3;
    uint constant MAX_HUNG_JURIES = 3;
    uint constant MAX_TOTAL_ROUNDS = 10;

    uint constant COMMIT_PERIOD = 4 days;
    uint constant REVEAL_WINDOW = 12 hours;
    uint constant FINALIZE_BLOCK_WINDOW = 50;
    uint constant ARBITRATION_APPEAL_COST = 1000e18;

    enum AppealGround {
        HUNG_JURY, INCORRECT_VERDICT,
        NEW_EVIDENCE, FABRICATION,
        BIAS, EXCLUSIONARY
    }

    struct Appeal {
        address appellant;
        AppealGround ground;
        string reasoning;
        uint timestamp;
        bool sustained;
        uint cost;
    }

    struct Resolution {
        uint8 numSides;
        uint8 numWinners;
        bool requiresUnanimous;
        uint8 currentRound;
        uint8 hungJuryCount;
        uint8 appealCount;
        uint appealCost;
        uint8[] verdict;
        bytes32 resolutionRequester;
    }

    mapping(uint64 => bytes) public rulingData;
    mapping(uint64 => Resolution) public resolutions;
    mapping(uint64 => uint) public roundStartTime;
    mapping(uint64 => uint) public verdictTimestamp;
    mapping(uint64 => uint) public finalizeEligibleBlock;
    mapping(uint64 => mapping(uint8 => Appeal)) public appeals;

    /// @dev assertionId associated with each arbitration marketId.
    mapping(uint64 => bytes32) public arbitrationAssertionId;

    /// @dev asserter's maxDeviationBps — severity floor when CRE unavailable.
    mapping(uint64 => uint16) public arbitrationSeverityBps;

    event VerdictReached(uint64 indexed marketId, uint8 round, uint8[] verdict);
    event HungJury(uint64 indexed marketId, uint8 round, uint8 count);
    event JurySelectionFailed(uint64 indexed marketId, uint8 round);
    event JurySelectionComplete(uint64 indexed marketId, uint8 round);
    event AppealFiled(uint64 indexed marketId, uint8 round, address appellant,
             AppealGround ground, uint8 appealCount);

    event MarketDataEvicted(uint64 indexed marketId, uint gasRefund);
    event AppealResult(uint64 indexed marketId, uint8 round, bool sustained);
    event ResolutionFinalized(uint64 indexed marketId, uint8[] verdict);
    event ForceMajeure(uint64 indexed marketId);

    /// @notice Emitted when UMA requests arbitration for a DVM/CRE conflict.
    event ArbitrationReceived(uint64 indexed marketId, bytes32 assertionId,
                              uint8 claimedSide, uint8 recommendedSide);
    /// @notice Emitted when a Solana market requests Court resolution.
    event ResolutionReceived(uint64 indexed marketId, uint8 numSides);

    error ResolutionActive();
    error NoVerdictToAppeal();
    error AlreadyFinalized();
    error MaxRoundsExceeded();
    error MaxAppealsReached();
    error Unauthorized();
    error OutsideFinalizeWindow();
    error AppealWindowActive();
    error NoVerdictToExecute();
    error AlreadyExecuted();
    error ZeroAddress();

    error WrongRound();
    error RoundNotStarted();
    error JuryNotSelected();
    error JuryAlreadySelected();
    error NoVerdictStored();
    error AppealLate();
    error TooEarly();
    error NotMarket();
    error InvalidSideCount();
    error InvalidWinnerCount();

    bool public immutable l1;

    /// @param _l1 True for mainnet deployment (Solana LZ bridge active);
    ///            false for L2 deployments where only UMA arbitration is used.
    constructor(address _basket, address _jury,
        address _link, bool _l1) { oracle = _link;
        QUID = Basket(_basket);
        jury = Jury(_jury);
        l1 = _l1;
    }

    receive() external payable {}

    function receiveResolutionRequest(bytes calldata lzMessage) external {
        if (!l1) revert Unauthorized(); // L2 courts handle only UMA arbitration, no Solana bridge
        if (msg.sender != address(QUID)) revert Unauthorized();
        if (lzMessage.length == 0 || uint8(lzMessage[0]) != MessageCodec.RESOLUTION_REQUEST) revert NotMarket();
        MessageCodec.ResolutionRequestData memory req = MessageCodec.decodeResolutionRequest(lzMessage);
        Resolution storage res = resolutions[req.marketId];
        if (res.numSides != 0) revert ResolutionActive();

        if (req.numSides < 2) revert InvalidSideCount();
        if (req.numWinners == 0 || req.numWinners >= req.numSides) revert InvalidWinnerCount();
        res.requiresUnanimous = req.requiresUnanimous;
        res.numWinners = req.numWinners;
        res.resolutionRequester = req.requester;
        res.appealCost = req.appealCost;
        res.numSides = req.numSides;

        roundStartTime[req.marketId] = block.timestamp;
        emit ResolutionReceived(req.marketId, req.numSides);
    }

    // ═══════════════════════════════════════════════════════════════
    //  UMA arbitration entry point
    //
    //  Called by UMA.assertionResolvedCallback when DVM and CRE
    //  disagree. Creates a Resolution for the jury to decide
    //  which oracle malfunctioned. Single-winner, 2/3 majority.
    //
    //  No affidavits (evidence is on-chain as ForensicEvidence).
    //  Ruling delivered directly to UMA.receiveRuling().
    //  Court's MAX_APPEALS guarantees termination.
    //
    //  Jury compensation: no Solana funds expected. After appeal
    //  window + timeout, jurors are compensated from slashed appeal
    //  costs only. If no appeals, jurors serve for stake return
    //  (no bonus). Acceptable for a rare conflict edge case.
    // ═══════════════════════════════════════════════════════════════

    /// @notice Called by UMA when DVM/CRE conflict detected.
    /// @param assertionId For jurors to look up ForensicEvidence on UMA
    /// @param numSides From UMA's market (stables + 1)
    /// @param claimedSide What the DVM confirmed
    /// @param recommendedSide What CRE's evidence recommends
    function requestArbitration(bytes32 assertionId, uint8 numSides,
        uint8 claimedSide, uint8 recommendedSide,
        uint16 asserterSeverityBps) external {
        if (msg.sender != oracle) revert Unauthorized();
        if (numSides < 2) revert InvalidSideCount();
        uint64 marketId = arbitrationCounter++;
        Resolution storage res = resolutions[marketId];
        res.numSides = numSides; res.numWinners = 1;

        res.requiresUnanimous = false;
        res.appealCost = ARBITRATION_APPEAL_COST;
        res.resolutionRequester = bytes32(uint256(uint160(oracle)));

        isArbitration[marketId] = true;
        arbitrationAssertionId[marketId] = assertionId;
        arbitrationSeverityBps[marketId] = asserterSeverityBps;
        roundStartTime[marketId] = block.timestamp;

        emit ArbitrationReceived(
            marketId, assertionId, claimedSide, recommendedSide);
    }

    function progressToJurySelection(uint64 marketId, uint8 round,
        bytes[] calldata headers) external nonReentrant {
        Resolution storage res = resolutions[marketId];
        if (res.currentRound != round) revert WrongRound();
        if (roundStartTime[marketId] == 0) revert RoundNotStarted();
        // Prevent re-selection if jury already selected for this round
        if (finalizeEligibleBlock[marketId] != 0) revert JuryAlreadySelected();

        bool success = jury.voirDire(marketId, round, roundStartTime[marketId],
            Jury.JuryConfig(res.numSides, res.numWinners, res.requiresUnanimous),
            headers);
        if (!success) { res.hungJuryCount++;
            if (res.hungJuryCount >= MAX_HUNG_JURIES) {
                res.verdict = new uint8[](0);
                _sendRuling(marketId);
                emit ForceMajeure(marketId);
                return;
            }
            emit JurySelectionFailed(marketId, round);
            return;
        }
        uint blocksUntilRevealEnd = (COMMIT_PERIOD + REVEAL_WINDOW) / 12;
        finalizeEligibleBlock[marketId] = block.number + blocksUntilRevealEnd;
        emit JurySelectionComplete(marketId, round);
    }

    function finalizeRound(uint64 marketId,
        bytes[] calldata headers) external nonReentrant {
        uint eligible = finalizeEligibleBlock[marketId];
        if (eligible == 0) revert JuryNotSelected();
        if (block.number < eligible) {
            revert OutsideFinalizeWindow();
        }
        // No upper bound: RANDAO header freshness (within 256 blocks) is enforced
        // by RandaoLib itself. A hard upper bound created a permanent-stuck DoS —
        // if no keeper called within 50 blocks, finalizeEligibleBlock stayed nonzero
        // blocking re-selection, with no escape path and all juror stakes locked.
        Resolution storage res = resolutions[marketId];
        if (verdictTimestamp[marketId] != 0 &&
            block.timestamp <= verdictTimestamp[marketId] + APPEAL_WINDOW)
            revert AlreadyFinalized();

        (uint8[] memory verdict, bool unanimous, bool meetsThreshold) =
            jury.finalizeRound(marketId, res.currentRound, headers);

        if (!meetsThreshold || (res.requiresUnanimous && !unanimous)) {
            _handleHungJury(marketId);
            return;
        }
        address appellant = jury.getAppellant(marketId, res.currentRound);
        if (appellant != address(0)) {
            bool sustained = !_verdictMatches(res.verdict, verdict);
            appeals[marketId][res.currentRound].sustained = sustained;
            if (sustained) {
                uint cost = appeals[marketId][res.currentRound].cost;
                jury.refundAppellant(marketId, cost, appellant);
            } else if (unanimous) {
                // Failed frivolous appeal with unanimous verdict - finalize immediately
                // Appellant penalty: appeal cost already burned (not refunded)
                _finalize(marketId);
                emit AppealResult(marketId, res.currentRound, false);
                return;
            }
            emit AppealResult(marketId, res.currentRound, sustained);
        }
        res.verdict = verdict;
        verdictTimestamp[marketId] = block.timestamp;
        emit VerdictReached(marketId, res.currentRound, verdict);
    }

    error AppealRoundInProgress();

    function executeVerdict(uint64 marketId) external nonReentrant {
        Resolution storage res = resolutions[marketId];
        if (verdictTimestamp[marketId] == 0) revert NoVerdictToExecute();
        if (block.timestamp <= verdictTimestamp[marketId] + APPEAL_WINDOW) revert AppealWindowActive();
        // Prevent execution during active appeal round
        // If roundStartTime > verdictTimestamp, an appeal was filed and new round started
        if (roundStartTime[marketId] > verdictTimestamp[marketId]) revert AppealRoundInProgress();
        if (rulingData[marketId].length > 0) revert AlreadyExecuted();
        if (res.verdict.length == 0) revert NoVerdictStored();
        jury.tryDistribute(marketId);
        _finalize(marketId);
    }

    function fileAppeal(uint64 marketId, AppealGround ground,
        string calldata reasoning)
        external nonReentrant returns (uint8) {
        require(bytes(reasoning).length <= 1024, "reasoning too long");
        Resolution storage res = resolutions[marketId];
        if (verdictTimestamp[marketId] == 0) revert NoVerdictToAppeal();
        if (block.timestamp > verdictTimestamp[marketId] + APPEAL_WINDOW) revert AppealLate();
        if (rulingData[marketId].length > 0) revert AlreadyExecuted();
        if (roundStartTime[marketId] > verdictTimestamp[marketId]) revert AppealRoundInProgress();
        if (res.appealCount >= MAX_APPEALS) revert MaxAppealsReached();

        uint cost = _appealCost(marketId, res.appealCount);
        QUID.transferFrom(msg.sender, address(jury), cost);
        jury.addAppealCost(marketId, cost);

        res.appealCount++;
        if (res.currentRound + 1 >= MAX_TOTAL_ROUNDS) revert MaxRoundsExceeded();
        res.currentRound++;

        appeals[marketId][res.currentRound] = Appeal({
            appellant: msg.sender,
            ground: ground,
            reasoning: reasoning,
            timestamp: block.timestamp,
            cost: cost,
            sustained: false
        });
        delete finalizeEligibleBlock[marketId];
        roundStartTime[marketId] = block.timestamp;
        jury.setAppellant(marketId, res.currentRound, msg.sender);

        emit AppealFiled(marketId, res.currentRound,
        msg.sender, ground, res.appealCount);
        return res.currentRound;
    }

    function _finalize(uint64 marketId) internal {
        _sendRuling(marketId); _evictMarketData(marketId);
        emit ResolutionFinalized(marketId, resolutions[marketId].verdict);
    }

    function _evictMarketData(uint64 marketId) internal {
        Resolution storage res = resolutions[marketId];
        uint8 maxRound = res.currentRound;

        res.numSides = 0;
        res.currentRound = 0;
        res.numWinners = 0;
        res.requiresUnanimous = false;
        res.hungJuryCount = 0;
        res.appealCost = 0;
        res.appealCount = 0;
        res.resolutionRequester = bytes32(0);
        delete res.verdict;

        for (uint8 i = 0; i <= maxRound; i++) {
            delete appeals[marketId][i].reasoning;
        }

        delete roundStartTime[marketId];
        delete finalizeEligibleBlock[marketId];
        delete verdictTimestamp[marketId];
        delete isArbitration[marketId];
        delete arbitrationAssertionId[marketId];
        delete arbitrationSeverityBps[marketId];
        jury.resetCompensation(marketId);
        uint slotsCleared = 10 + maxRound * 5;
        emit MarketDataEvicted(marketId, slotsCleared * 15000);
    }

    function _handleHungJury(uint64 marketId) internal {
        Resolution storage res = resolutions[marketId]; res.hungJuryCount++;
        emit HungJury(marketId, res.currentRound, res.hungJuryCount);

        if (res.hungJuryCount < MAX_HUNG_JURIES
         && res.currentRound + 1 < MAX_TOTAL_ROUNDS) {
            // Copy appellant to next round if this was an appeal round
            uint currentAppealCost = appeals[marketId][res.currentRound].cost;
            uint8 prevRound = res.currentRound;
            res.currentRound++;
            // carryAppellant does getAppellant + setAppellant in one external call
            address currentAppellant = jury.carryAppellant(marketId, prevRound, res.currentRound);
            if (currentAppellant != address(0)) {
                appeals[marketId][res.currentRound].appellant = currentAppellant;
                appeals[marketId][res.currentRound].cost = currentAppealCost;
            }
            delete finalizeEligibleBlock[marketId];
            roundStartTime[marketId] = block.timestamp;
        } else {
            // ── Hung juries exhausted ──
            // Arbitration: resolve as side 0 via UMA.receiveRuling().
            // Non-arbitration: force majeure (cancel + pro-rata refund).
            if (isArbitration[marketId]) {
                res.verdict = new uint8[](1);
                res.verdict[0] = 0; // conservative default
                _sendRuling(marketId);
                emit ForceMajeure(marketId);
            } else {
                delete res.verdict;
                _sendRuling(marketId);
                emit ForceMajeure(marketId);
            }
        }
    }

    function _sendRuling(uint64 marketId) internal {
        // Set verdictTimestamp if not already set (for force majeure paths)
        // This ensures _tryDistribute in Jury can proceed after appeal window
        if (verdictTimestamp[marketId] == 0) {
            verdictTimestamp[marketId] = block.timestamp;
        }
        Resolution storage res = resolutions[marketId];
        // ── Arbitration: deliver ruling directly to UMA ──
        // Same chain, no cross-chain messaging needed.
        // Jury compensation uses the timeout path (no Solana funds).
        if (isArbitration[marketId]) {
            uint8 winningSide = (res.verdict.length > 0)
                              ? res.verdict[0] : 0;
            // Read CRE evidence severity — zero if CRE was unavailable
            // (escalateToCourt path) or if jury found no depeg.
            // Jury confirms side only — severity is always the asserter's
            // original maxDeviationBps. Jury latency makes live price data
            // unreliable; asserter's bond-backed claim is the best anchor.
            uint16 severityBps = winningSide > 0
                ? arbitrationSeverityBps[marketId] : 0;
            // Call UMA first, then mark as sent.
            // If receiveRuling reverts the ruling is retryable via _sendRuling.
            // reentrancy is safe: rulingData written after external call,
            // and nonReentrant guards all Court entry points.
            ILink(oracle).receiveRuling(winningSide, severityBps);
            rulingData[marketId] = hex"01";
            // No Solana compensation will ever arrive for arbitration markets
            // (L2 depeg disputes or L1 UMA conflicts). Mark immediately so
            // _tryDistribute can proceed from appealPool alone after appeal window,
            // without requiring a manual timeoutJuryCompensation call.
            jury.markCompensationTimedOut(marketId);
            return;
        }
        // ── Standard: encode and send cross-chain to Solana
        bytes memory message = MessageCodec.encodeFinalRuling(
                                        marketId, res.verdict);

        rulingData[marketId] = message;
        QUID.sendToSolana{value: 0.05 ether}(message);
    }

    function _verdictMatches(uint8[] memory a,
        uint8[] memory b) internal pure returns (bool) {
        if (a.length != b.length) return false;
        for (uint i = 0; i < a.length; i++) {
            if (a[i] != b[i]) return false;
        }
        return true;
    }

    function _appealCost(uint64 marketId,
        uint8 appealIndex) internal view returns (uint) {
        uint base = resolutions[marketId].appealCost;
        for (uint i = 0; i < appealIndex; i++) {
            base = (base * 15000) / 10000;
        }
        return base;
    }

    error RulingNotSent();

    /// @notice Timeout if jury compensation never arrives from Solana
    /// @param marketId The market ID
    function timeoutJuryCompensation(uint64 marketId) external nonReentrant {
        if (verdictTimestamp[marketId] == 0) revert NoVerdictToExecute();
        if (block.timestamp <= verdictTimestamp[marketId] + APPEAL_WINDOW) revert TooEarly();
        // Ruling must have been sent before we can timeout waiting for compensation
        if (rulingData[marketId].length == 0) revert RulingNotSent();
        // If ruling not sent, prevent timeout during active appeal round
        // (But if rulingData exists, resolution is final regardless of roundStartTime)
        jury.markCompensationTimedOut(marketId);
        jury.tryDistribute(marketId);
    }

    function isInResolutionPhase(uint64 marketId) external view returns (bool) {
        return roundStartTime[marketId] > 0 && verdictTimestamp[marketId] == 0;
    }

    function getMarketConfig(uint64 marketId) external
        view returns (uint8 numSides, uint8 numWinners,
        bool requiresUnanimous, uint appealCost) {
        Resolution storage res = resolutions[marketId];
        return (res.numSides, res.numWinners,
            res.requiresUnanimous,
            res.appealCost);
    }

    function getRoundStartTime(uint64 marketId)
        external view returns (uint) {
        return roundStartTime[marketId];
    }

    function getCurrentRound(uint64 marketId)
        external view returns (uint8) {
        return resolutions[marketId].currentRound;
    }

    function getVerdictTimestamp(uint64 marketId)
        external view returns (uint) {
        return verdictTimestamp[marketId];
    }

    function getFinalVerdict(uint64 marketId)
        external view returns (uint8[] memory) {
        return resolutions[marketId].verdict;
    }

    /// @dev Batch getter used by Jury._tryDistribute to reduce cross-contract calls.
    function getDistributionData(uint64 marketId) external view
        returns (uint verdictTs, uint8[] memory finalVerdict, uint8 currentRound, uint8 numSides) {
        Resolution storage res = resolutions[marketId];
        return (verdictTimestamp[marketId], res.verdict, res.currentRound, res.numSides);
    }

    function getAppeal(uint64 marketId, uint8 round) external view returns (
        address appellant, AppealGround ground,
        string memory reasoning, uint timestamp, uint cost, bool sustained) {
        Appeal storage appeal = appeals[marketId][round];
        return (appeal.appellant, appeal.ground,
                appeal.reasoning, appeal.timestamp, appeal.cost, appeal.sustained);
    }

    function getFinalizeWindow(uint64 marketId) external
        view returns (uint eligibleBlock) {
        eligibleBlock = finalizeEligibleBlock[marketId];
        // No upper bound enforced on-chain; RANDAO header freshness (256-block
        // EVM limit) is the only constraint on when finalizeRound can be called.
    }

    function isReadyForExecution(uint64 marketId)
        external view returns (bool ready, string memory reason) {
        if (verdictTimestamp[marketId] == 0) return (false, "No verdict yet");
        if (block.timestamp <= verdictTimestamp[marketId] + APPEAL_WINDOW) return (false, "Appeal window active");
        if (rulingData[marketId].length > 0) return (false, "Already executed");
        if (resolutions[marketId].verdict.length == 0) return (false, "No verdict stored");
        return (true, "");
    }

}
