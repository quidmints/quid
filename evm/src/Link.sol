// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Basket} from "./Basket.sol";
import {Types} from "./imports/Types.sol";
import {FeeLib} from "./imports/FeeLib.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "solmate/src/utils/ReentrancyGuard.sol";

interface ICourt {
    function requestArbitration(
      bytes32 assertionId, uint8 numSides, uint8 claimedSide,
      uint8 recommendedSide, uint16 asserterSeverityBps
    ) external;
}

/// @title Link + Market — LMSR prediction market and CRE-primary depeg resolver.
/// @notice Single contract. No external oracle dependency (OO removed).
///   CRE resolves depeg claims in minutes. Jury fallback if CRE silent.
///   Griefing limited by 500 QD gate + 24h per-side rejection cooldown.
///   LMSR pure math lives in Court (external pure calls).
contract Link is ReentrancyGuard {
    address public owner;
    modifier onlyOwner() { if (msg.sender != owner) revert("not owner"); _; }
    function transferOwnership(address n) external onlyOwner { owner = n; }

    uint public constant FEE_BPS           = 400;
    uint public constant ROLLOVER_FEE_BPS  = 200;
    uint public constant MIN_ORDER         = 1e18;
    uint public constant CONSOLATION_BPS   = 2000;
    uint public constant REVEAL_WINDOW     = 48 hours;
    int128 public constant INITIAL_B       = 10_000e18;
    uint constant NEUTRAL_CONFIDENCE       = 5000;
    uint constant WAD                      = 1e18;
    uint public constant MIN_QD_TO_ASSERT  = 500e18;
    uint public constant REJECTION_COOLDOWN = 24 hours;
    uint8 constant MAX_SIDES               = 12;

    Basket public immutable QUID;

    // Admin-settable
    address public FORWARDER;
    address public COURT;
    uint public CRE_TIMEOUT = 4 hours;
    uint8 public minConfidence = 80;

    Types.Market internal _market;
    
    mapping(address => uint8) public stablecoinToSide;
    mapping(address => mapping(uint8 => Types.Position))    internal _positions;
    mapping(address => mapping(uint8 => Types.PositionEntry[])) internal _entries;
    mapping(uint8 => uint) internal _depegSeverityBps;

    uint[12] internal _confCapAccum;
    uint[12] internal _revealedCapPerSide;
    uint[12] internal _lastRoundAvgConf;
    
    uint public pendingAssertions;
    uint public accumulatedFees;
    struct AssertionContext {
        address asserter;
        uint8   claimedSide;
        uint    filedAt;
        uint    round;
        uint16  maxDeviationBps;
    }
    mapping(bytes32 => AssertionContext)       public assertions;
    mapping(uint => mapping(uint8 => bytes32)) public sideAssertionId;
    mapping(uint => mapping(uint8 => bool))    public sideDepegged;
    mapping(uint => mapping(uint8 => uint))    public sideRejectedAt;
    mapping(bytes32 => bool)                   public creResponded;
    bytes32 public arbitratingAssertionId;
    uint internal _assertionNonce;

    event OrderPlaced(address indexed user, uint8 side, uint capital, uint tokens);
    event PositionSold(address indexed user, uint8 side, uint tokens, uint returned);
    event ConfidenceRevealed(address indexed user, uint8 side, uint confidence);
    event PayoutPushed(address indexed user, uint8 side, uint amount);
    event Recommitted(address indexed user, uint8 side, uint tokens);
    event WeightsCalculated();

    event ResolutionRequested(bytes32 indexed assertionId, uint8 claimedSide);
    event AssertionConfirmed(bytes32 indexed assertionId, uint8 winningSide);
    event AssertionRejected(bytes32 indexed assertionId, uint8 claimedSide, uint cooldownUntil);
    event MarketRestarted(uint round);
    event ArbitrationRequested(bytes32 indexed assertionId, uint8 claimedSide);
    event ArbitrationResolved(uint8 winningSide);
    event CRESkipped(bytes32 indexed assertionId, string reason);

    error NotOwner(); error NotForwarder(); error NotCourt(); error NotQUID();
    error InvalidSide(uint8 side, uint8 max);
    error StalePosition(uint posRound, uint mktRound);
    error OrderTooSmall(uint amount, uint minimum);
    error MarketExists(); error TooManySides(); error MarketNotReady();
    error InsufficientQD(); error CooldownActive(uint availableAt);
    error SideAlreadyAsserted(); error ArbitrationInProgress();
    error CREWindowOpen(); error CREAlreadyResponded(); error NoCourt();


    modifier onlyForwarder() { if (msg.sender != FORWARDER) revert("not forwarder"); _; }
    modifier onlyCourt() { if (msg.sender != COURT) revert("not court"); _; }

    constructor(address _quid, address _forward) {
        owner = msg.sender; QUID = Basket(_quid);
        FORWARDER = _forward; // Avanti andiamo!
    }

    function setCourt(address _court) external onlyOwner {
        if (_court == address(0)) revert("not owner");
        COURT = _court;
    }

    function setCRETimeout(uint _seconds) external onlyOwner {
        if (_seconds < 1 hours || _seconds > 7 days) revert("not owner");
        CRE_TIMEOUT = _seconds;
    }

    function setMinConfidence(uint8 _min) external onlyOwner {
        if (_min > 100) revert("not owner");
        minConfidence = _min;
    }

    /// @notice Called once from Basket.setup(). Initialises both LMSR and depeg state.
    function createMarket(address[] calldata stables) external {
        if (msg.sender != address(QUID)) revert("not quid");
        if (_market.numSides != 0) revert("market exists");
        uint8 n = uint8(stables.length) + 1;
        if (n > MAX_SIDES) revert("too many sides");
        
        _market.numSides = n;
        _market.startTime = block.timestamp;
        _market.roundStartTime = block.timestamp;
        _market.b = INITIAL_B;
        _market.roundNumber = 1;
        for (uint8 i; i < stables.length; i++)
            stablecoinToSide[stables[i]] = i + 1;
    }

    /// @notice Side 0: permissionless monthly timeout.
    function resolveAsNone() external {
        if (_market.numSides == 0) revert("market not ready");
        if (_market.resolved || pendingAssertions > 0 
         || arbitratingAssertionId != bytes32(0))
            revert("arbitration in progress");

        if (block.timestamp < _market.roundStartTime + FeeLib.MONTH)
            revert("cre window open");
        _trigger(block.timestamp, 0, 0);
        emit AssertionConfirmed(bytes32(0), 0);
    }

    /// @notice File a depeg claim. Asserter must hold ≥ MIN_QD_TO_ASSERT QD.
    function requestResolution(uint8 claimedSide, uint16 maxDeviationBps)
        external returns (bytes32 assertionId) {
        if (claimedSide == 0) revert("invalid side");
        if (claimedSide >= _market.numSides) revert("invalid side");
        if (arbitratingAssertionId != bytes32(0)) revert("arbitration in progress");
        if (sideAssertionId[_market.roundNumber][claimedSide] != bytes32(0)) revert("side already asserted");
        if (QUID.balanceOf(msg.sender) < MIN_QD_TO_ASSERT) revert("insufficient qd");
        uint cooldownEnd = sideRejectedAt[_market.roundNumber][claimedSide] + REJECTION_COOLDOWN;
        if (block.timestamp < cooldownEnd) revert("cooldown active");

        assertionId = keccak256(abi.encodePacked(_market.roundNumber, 
                        claimedSide, msg.sender, _assertionNonce++));

        assertions[assertionId] = AssertionContext({
            asserter: msg.sender, claimedSide: claimedSide,
            filedAt: block.timestamp, round: _market.roundNumber,
            maxDeviationBps: maxDeviationBps
        });
        sideAssertionId[_market.roundNumber][claimedSide] = assertionId;
        if (pendingAssertions == 0) pendingAssertions++;  // first assertion freezes
        emit ResolutionRequested(assertionId, claimedSide);
    }

    function onReport(bytes calldata, bytes calldata report) external onlyForwarder {
        (bytes32 assertionId, uint8 claimedSide, uint8 recommendedSide, uint maxDeviationBps,
         uint8 confidence,) = abi.decode(report, (bytes32, uint8, uint8, uint, uint8, bytes32));

        // Recovery: stable re-pegged, allow market restart
        if (_market.resolved && recommendedSide == 0 && _market.winningSide > 0
            && confidence >= minConfidence) { _market.winningSide = 0;
            emit CRESkipped(assertionId, "depeg cleared by CRE");
            return;
        }
        
        AssertionContext memory ctx = assertions[assertionId];
        if (ctx.asserter == address(0)) { emit CRESkipped(assertionId, "unknown assertion"); return; }
        if (ctx.round != _market.roundNumber) { emit CRESkipped(assertionId, "stale round"); return; }
        if (confidence < minConfidence) { emit CRESkipped(assertionId, "low confidence"); return; }
        creResponded[assertionId] = true;
        // CRE can override jury if it arrives before receiveRuling fires
        if (arbitratingAssertionId != bytes32(0)) {
            arbitratingAssertionId = bytes32(0);
            if (recommendedSide == ctx.claimedSide) {
                _resolveDepeg(assertionId, ctx, uint16(maxDeviationBps));
            } else {
                _rejectAssertion(assertionId, ctx);
            }
            return;
        }
        // Co-depeg: market already resolved by another side this round
        if (_market.resolved) {
            if (recommendedSide == ctx.claimedSide) {
                sideDepegged[_market.roundNumber][ctx.claimedSide] = true;
                _depegSeverityBps[ctx.claimedSide] = maxDeviationBps;
                emit AssertionConfirmed(assertionId, ctx.claimedSide);
            }
            delete assertions[assertionId];
            sideAssertionId[ctx.round][ctx.claimedSide] = bytes32(0);
            if (pendingAssertions > 0) pendingAssertions--;
            return;
        }
        if (recommendedSide == ctx.claimedSide) {
            _resolveDepeg(assertionId, ctx, uint16(maxDeviationBps));
        } else {
            _rejectAssertion(assertionId, ctx);
        }
    }

    function _resolveDepeg(bytes32 assertionId, 
        AssertionContext memory ctx, uint16 sev) internal {
        sideDepegged[_market.roundNumber][ctx.claimedSide] = true;
        delete assertions[assertionId];
        _trigger(block.timestamp, ctx.claimedSide, sev);
        emit AssertionConfirmed(assertionId, ctx.claimedSide);
    }

    function _rejectAssertion(bytes32 assertionId, 
        AssertionContext memory ctx) internal {
        delete assertions[assertionId];
        sideAssertionId[ctx.round][ctx.claimedSide] = bytes32(0);
        sideRejectedAt[ctx.round][ctx.claimedSide] = block.timestamp;
        emit AssertionRejected(assertionId, ctx.claimedSide, 
                        block.timestamp + REJECTION_COOLDOWN);
        bool anyPending;
        for (uint8 s = 1; s < _market.numSides; s++) {
            bytes32 id = sideAssertionId[_market.roundNumber][s];
            if (id != bytes32(0) && assertions[id].asserter != address(0)) { 
                anyPending = true; break; 
            }
        } if (!anyPending) { 
            if (pendingAssertions > 0) pendingAssertions--; 
        }
    }

    function escalateToCourt(bytes32 assertionId) external {
        if (COURT == address(0)) revert("no court");
        AssertionContext memory ctx = assertions[assertionId];
        if (ctx.asserter == address(0)) revert("not owner"); // reuse error: "unknown"
        if (block.timestamp < ctx.filedAt + CRE_TIMEOUT) revert("cre window open");
        if (creResponded[assertionId]) revert("cre already responded");
        if (_market.resolved || arbitratingAssertionId != bytes32(0)) revert("arbitration in progress");
        if (pendingAssertions == 0) revert("not owner"); // no active assertion

        arbitratingAssertionId = assertionId;
        ICourt(COURT).requestArbitration(
            assertionId, _market.numSides,
            ctx.claimedSide, ctx.claimedSide, ctx.maxDeviationBps);
        emit ArbitrationRequested(assertionId, ctx.claimedSide);
    }

    function receiveRuling(uint8 winningSide, uint16 severityBps) external onlyCourt {
        if (arbitratingAssertionId == bytes32(0)) revert("not owner");
        if (winningSide >= _market.numSides) revert("invalid side");
        bytes32 arbId = arbitratingAssertionId;
        AssertionContext memory ctx = assertions[arbId];
        arbitratingAssertionId = bytes32(0);
        if (ctx.asserter != address(0)) delete assertions[arbId];
        if (winningSide > 0) {
            sideDepegged[_market.roundNumber][winningSide] = true;
            _trigger(block.timestamp, winningSide, severityBps);
        } else {
            if (pendingAssertions > 0) pendingAssertions--;
        }
        emit ArbitrationResolved(winningSide);
    }

    function restartMarket() external {
        if (!_market.resolved) revert("market not ready");
        if (block.timestamp < _market.revealDeadline) revert("cre window open");
        if (!_market.payoutsComplete) revert("market not ready");
        if (_market.winningSide != 0) revert("arbitration in progress"); // awaiting CRE recovery
        _resetForNewRound();
        emit MarketRestarted(_market.roundNumber);
    }

    function _trigger(uint ts, uint8 side, uint sev) internal {
        _market.resolved = true;
        _market.winningSide = side;
        _market.resolutionTimestamp = ts;
        _market.revealDeadline = block.timestamp + REVEAL_WINDOW;
        _depegSeverityBps[side] = sev;
    }

    function _resetForNewRound() internal {
        for (uint8 side; side < _market.numSides; side++) {
            uint rev = _revealedCapPerSide[side];
            _lastRoundAvgConf[side] = rev > 0 ? _confCapAccum[side] / rev : 0;
            _confCapAccum[side] = 0;
            _revealedCapPerSide[side] = 0;
            delete _depegSeverityBps[side];
        }
        _market.resolved = false;
        _market.winningSide = 0;
        _market.resolutionTimestamp = 0;
        _market.totalCapital = 0;
        _market.positionsTotal = 0;
        _market.positionsRevealed = 0;
        _market.positionsPaidOut = 0;
        _market.positionsWeighed = 0;
        _market.totalWinnerCapital = 0;
        _market.totalLoserCapital = 0;
        _market.totalWinnerWeight = 0;
        _market.totalLoserWeight = 0;
        _market.weightsComplete = false;
        _market.payoutsComplete = false;
        _market.revealDeadline = 0;
        pendingAssertions = 0;
        delete _market.q;
        delete _market.capitalPerSide;
        _market.roundStartTime = block.timestamp;
        _market.roundNumber++;
    }

    struct RevealEntry { uint confidence; bytes32 salt; }

    function placeOrder(uint8 side, uint capital, bool autoRollover, 
        bytes32 commitHash, address delegate) external nonReentrant {
        if (side >= _market.numSides) revert("invalid side");
        if (capital < MIN_ORDER) revert("order too small");
        if (commitHash == bytes32(0)) revert("not owner");
        if (_market.resolved) revert("resolved");
        if (pendingAssertions > 0) revert("side already asserted");
        QUID.transferFrom(msg.sender, address(this), capital);
        
        uint fee = (capital * FEE_BPS) / 10000;
        uint netCapital = capital - fee;
        accumulatedFees += fee;
        uint entryPrice = FeeLib.price(_market.q, 
            _market.numSides, _market.b, side);
        
        uint tokens = _buyTokens(_market, side, netCapital);
        require(_entries[msg.sender][side].length < 32, "too many entries");
        Types.Position storage position = _positions[msg.sender][side];
        if (position.user == address(0)) {
            position.user = msg.sender; position.side = side;
            position.lastRound = _market.roundNumber;
            _market.positionsTotal++;
        } else if (position.lastRound < _market.roundNumber) {
            if (position.totalCapital > 0) QUID.transfer(msg.sender, 
                                            position.totalCapital);

            position.totalCapital = 0; position.totalTokens = 0;
            position.lastRound = _market.roundNumber;
            position.revealed = false; position.revealedConfidence = 0;
            position.weight = 0; position.paidOut = false;
            _market.positionsTotal++;
            delete _entries[msg.sender][side];
        }
        position.delegate = delegate; position.totalCapital += netCapital;
        position.totalTokens += tokens; position.autoRollover = autoRollover;
        position.entryTimestamp = block.timestamp; position.entryBlock = block.number;
        _entries[msg.sender][side].push(Types.PositionEntry({ capital: netCapital, 
            tokens: tokens, commitmentHash: commitHash, timestamp: block.timestamp, 
            revealedConfidence: 0, priceAtEntry: entryPrice }));

        _market.totalCapital += netCapital;
        _market.capitalPerSide[side] += netCapital;
        emit OrderPlaced(msg.sender, side, netCapital, tokens);
    }

    function sellPosition(uint8 side, uint tokensToSell) external nonReentrant {
        if (_market.resolved) revert("arbitration in progress");
        if (pendingAssertions > 0) revert("side already asserted");
        Types.Position storage position = _positions[msg.sender][side];
        if (position.totalTokens < tokensToSell) revert("order too small");
        if (position.entryBlock >= block.number) revert("not owner");
        if (position.lastRound != _market.roundNumber) revert("stale position");
        uint capitalReduced;
        uint returned = _sellTokens(_market, side, tokensToSell);
        { Types.PositionEntry[] storage entries = _entries[msg.sender][side];
          uint length = entries.length;
          uint[] memory oldCaps = new uint[](length);
          uint[] memory oldToks = new uint[](length);
          for (uint i; i < length; i++) { 
            oldCaps[i] = entries[i].capital; 
            oldToks[i] = entries[i].tokens; 
          }
          uint[] memory newCaps; uint[] memory newToks;
          (newCaps, newToks, capitalReduced) = FeeLib.reduceEntries(oldCaps, 
                                oldToks, tokensToSell, position.totalTokens);
          uint wi;
          for (uint i; i < length; i++) {
              if (newToks[i] == 0) continue;
              if (wi != i) entries[wi] = entries[i];
              entries[wi].capital = newCaps[i]; 
              entries[wi].tokens = newToks[i]; wi++;
          }
          while (entries.length > wi) entries.pop();
        }
        position.totalTokens -= tokensToSell; 
        position.totalCapital -= capitalReduced;
        _market.totalCapital -= capitalReduced; 
        _market.capitalPerSide[side] -= capitalReduced;
        if (position.totalTokens == 0) _market.positionsTotal--;
        if (capitalReduced > returned) 
            accumulatedFees += capitalReduced - returned;
        uint balance = QUID.balanceOf(address(this));
        if (returned > balance) returned = balance;
        QUID.transfer(msg.sender, returned);

        emit PositionSold(msg.sender, 
        side, tokensToSell, returned);
    }

    function _computePositionWeight(address user, uint8 side, bool isWinner, 
        uint revealedConfidence) internal view returns (uint) {
        Types.PositionEntry[] storage entries = _entries[user][side];
        uint[] memory capitals = new uint[](entries.length);
        uint[] memory timestamps = new uint[](entries.length);
        uint[] memory prices = new uint[](entries.length);
        for (uint i; i < entries.length; i++) {
            capitals[i] = entries[i].capital;
            timestamps[i] = entries[i].timestamp;
            prices[i] = entries[i].priceAtEntry;
        }
        return FeeLib.computeWeight(
            capitals, timestamps, prices,
            _market.roundStartTime,
            _market.resolutionTimestamp,
            revealedConfidence, isWinner
        );
    }

    function _processPosition(address user, uint8 side, 
        RevealEntry[] calldata reveals, uint revealStart, 
        uint revealCount) internal returns (uint weight) {
        Types.Position storage position = _positions[user][side];
        if (position.weight > 0 || position.paidOut) return 0;
        if (position.lastRound < _market.roundNumber) {
            if (!position.autoRollover || position.totalCapital == 0) return 0;
            _rolloverPosition(user, side);
        }
        if (position.lastRound != _market.roundNumber) return 0;
        if (!position.revealed) {
            _revealPosition(user, side, reveals, revealStart, revealCount);
        }
        weight = _computePositionWeight(user, side,
            side == _market.winningSide,
            position.revealedConfidence
        );
        if (weight == 0) {
            position.paidOut = true;
            _market.positionsPaidOut++;
            _market.positionsWeighed++;
            emit PayoutPushed(user, side, 0);
            return 0;
        }
        position.weight = weight;
        if (side == _market.winningSide) 
            _market.totalWinnerWeight += weight;
        else _market.totalLoserWeight += weight;
        _market.positionsWeighed++;
    }

    function _rolloverPosition(address user, uint8 side) internal {
        Types.Position storage position = _positions[user][side];
        uint capital = position.totalCapital;
        position.totalTokens = 0;
        position.revealed = false;
        position.revealedConfidence = 0;
        position.lastRound = _market.roundNumber;
        position.weight = 0;
        position.paidOut = false;
        position.entryTimestamp = _market.roundStartTime;
        _market.positionsTotal++;
        _market.totalCapital += capital;
        _market.capitalPerSide[side] += capital;
        delete _entries[user][side];
        _entries[user][side].push(Types.PositionEntry({
            capital: capital, tokens: 0,
            commitmentHash: bytes32(0),
            timestamp: _market.roundStartTime,
            revealedConfidence: 0,
            priceAtEntry: 0
        }));
        emit Recommitted(user, side, capital);
    }

    function calculateWeights(address[] calldata users,
        uint8[] calldata sides, RevealEntry[] calldata reveals,
        uint[] calldata revealCounts) external { uint gasStart = gasleft();
        if (!_market.resolved) 
            revert("market not ready");
        if (users.length != sides.length 
         || users.length != revealCounts.length) revert("not owner");
         
        if (_market.positionsPaidOut != 0) revert("not owner");
        if (block.timestamp < _market.revealDeadline) 
            revert("cre window open");

        uint revealCursor;
        for (uint index; index < users.length; index++) {
            uint count = revealCounts[index];
            _processPosition(users[index], sides[index], 
                            reveals, revealCursor, count);
                                   revealCursor += count;
        }
        if (_market.positionsWeighed >= _market.positionsRevealed)
            _market.weightsComplete = true;

        uint gasCost = _gasToQD(gasStart - gasleft() + 21000);
        uint qdBal = QUID.balanceOf(address(this));
        if (gasCost > qdBal) gasCost = qdBal;
        if (gasCost > 0 && 
            gasCost <= accumulatedFees) {
            accumulatedFees -= gasCost;
            _reimburseKeeper(gasCost);
        }
        emit WeightsCalculated();
    }

    function pushPayouts(address[] calldata users, 
        uint8[] calldata sides) external nonReentrant {
        uint gasStart = gasleft();
        if (!_market.weightsComplete) revert("market not ready");
        if (_market.positionsWeighed != _market.positionsRevealed) 
            revert("market not ready");

        uint winnerWeight = _market.totalWinnerWeight;
        uint loserWeight  = _market.totalLoserWeight;
        uint loserCapital = _market.totalLoserCapital;
        uint8 winner = _market.winningSide;
        uint roundNum = _market.roundNumber;
        for (uint index; index < users.length; index++) {
            address user = users[index]; uint8 side = sides[index];
            Types.Position storage position = _positions[user][side];
            if (position.paidOut || 
                position.lastRound != roundNum || 
                position.weight == 0) continue;
            
            position.paidOut = true; _market.positionsPaidOut++;
            uint payout = FeeLib.computePayout(position.totalCapital, position.weight,
                winnerWeight, loserWeight, loserCapital, CONSOLATION_BPS, side == winner);
            
            uint balance = QUID.balanceOf(address(this));
            if (payout > balance) payout = balance;
            if (position.autoRollover) {
                uint fee = (position.totalCapital * ROLLOVER_FEE_BPS) / 10000;
                if (fee >= payout) fee = 0;
                accumulatedFees += fee;
                position.totalCapital = payout - fee; position.totalTokens = 0;
                position.revealed = false; position.revealedConfidence = 0;
                position.weight = 0; position.paidOut = false;
                delete _entries[user][side];
            } else { QUID.transfer(user, payout); }
            emit PayoutPushed(user, side, payout);
        }
        if (_market.positionsPaidOut >= _market.positionsRevealed) 
            _market.payoutsComplete = true;

        uint gasCost = _gasToQD(gasStart - gasleft() + 21000);
        uint qdBal = QUID.balanceOf(address(this));
        if (gasCost > qdBal) gasCost = qdBal;
        if (gasCost > 0 && gasCost <= accumulatedFees) { 
            accumulatedFees -= gasCost; _reimburseKeeper(gasCost); 
        }
    }

    function _buyTokens(Types.Market storage market, uint8 side, uint netCapital)
        internal returns (uint tokens) { int128 deltaQ;
        (tokens, deltaQ) = FeeLib.buyTokens(market.q, 
        market.numSides, market.b, side, netCapital);
        market.q[side] += deltaQ;
    }

    function _sellTokens(Types.Market storage market, uint8 side, uint tokensToSell)
        internal returns (uint returned) { int128 deltaQ;
        (returned, deltaQ) = FeeLib.sellTokens(market.q, 
        market.numSides, market.b, side, tokensToSell);
        market.q[side] -= deltaQ;
    }

    function _revealPosition(address user, uint8 side, 
        RevealEntry[] calldata reveals, uint start, uint count) internal {
        Types.Position storage position = _positions[user][side];
        Types.PositionEntry[] storage entries = _entries[user][side];
        uint cursor; uint weightedConfidenceSum;
        for (uint entry; entry < entries.length; entry++) {
            if (entries[entry].commitmentHash == bytes32(0)) {
                entries[entry].revealedConfidence = NEUTRAL_CONFIDENCE;
                weightedConfidenceSum += entries[entry].capital * NEUTRAL_CONFIDENCE;
            } else {
                if (cursor >= count) revert("not owner");
                RevealEntry calldata reveal = reveals[start + cursor];
                if (reveal.confidence < 100 || 
                  reveal.confidence > 10000 || 
                  reveal.confidence % 100 != 0) revert("bad confidence");
                
                if (keccak256(abi.encodePacked(reveal.confidence, reveal.salt)) 
                    != entries[entry].commitmentHash) revert("hash mismatch");
                
                entries[entry].revealedConfidence = reveal.confidence;
                weightedConfidenceSum += entries[entry].capital * reveal.confidence;
                cursor++;
            }
        }
        if (cursor != count) revert("not owner");
        uint avgConf = position.totalCapital > 0 ? 
            weightedConfidenceSum / position.totalCapital : NEUTRAL_CONFIDENCE;
        position.revealed = true; position.revealedConfidence = avgConf;
        
        _market.positionsRevealed++;
        _confCapAccum[side] += position.totalCapital * avgConf;
        _revealedCapPerSide[side] += position.totalCapital;
        if (side == _market.winningSide) _market.totalWinnerCapital += position.totalCapital;
        else _market.totalLoserCapital += position.totalCapital;
        emit ConfidenceRevealed(user, side, avgConf);
    }

    function getAllPrices() external view returns (uint[] memory prices) {
        prices = new uint[](_market.numSides);
        for (uint8 i; i < _market.numSides; i++)
            prices[i] = FeeLib.price(_market.q, _market.numSides, _market.b, i);
    }

    function getLMSRCost(uint8 side, int128 delta) external view returns (uint) {
        return FeeLib.cost(_market.q, _market.numSides, _market.b, side, delta);
    }

    function depegPending() external view returns (bool) {
        return _market.resolved && _market.winningSide > 0;
    }

    function paid() external view returns (bool) { return _market.payoutsComplete; }

    function isTradingEnabled() external view returns (bool) {
        return !_market.resolved && pendingAssertions == 0 && arbitratingAssertionId == bytes32(0);
    }

    function isRevealOpen() external view returns (bool) {
        return _market.resolved && block.timestamp < _market.revealDeadline;
    }

    function isDepegged(address stablecoin) external view returns (bool) {
        uint8 side = stablecoinToSide[stablecoin];
        if (side == 0 || !_market.resolved) return false;
        return _market.winningSide == side || sideDepegged[_market.roundNumber][side];
    }

    function isSideDepegged(uint round, uint8 side) external view returns (bool) {
        return sideDepegged[round][side];
    }

    function getDepegSeverityBps() external view returns (uint) {
        return _depegSeverityBps[_market.winningSide];
    }

    function getDepegStats(address stablecoin) 
        external view returns (Types.DepegStats memory stats) {
        uint8 side = stablecoinToSide[stablecoin];
        if (side == 0 || _market.numSides == 0) return stats;
        stats.capOnSide = _market.capitalPerSide[side];
        stats.capNone = _market.capitalPerSide[0];
        stats.capTotal = _market.totalCapital;
        stats.depegged = _market.resolved &&
            (_market.winningSide == side || sideDepegged[_market.roundNumber][side]);
        
        stats.avgConf = _lastRoundAvgConf[side]; stats.side = side;
        if (stats.depegged) stats.severityBps = _depegSeverityBps[side];
    }

    function getRoundStartTime() external view returns (uint) { return _market.roundStartTime; }
    function getMarketCapital() external view returns (uint) { return _market.totalCapital; }
    function getNumSides() external view returns (uint8) { return _market.numSides; }

    function getAssertionInfo() external view returns (uint8 phase, uint8 winningSide, uint round) {
        if (_market.resolved) phase = 3;
        else if (arbitratingAssertionId != bytes32(0)) phase = 4;
        else if (pendingAssertions > 0) phase = 1;
        return (phase, _market.winningSide, _market.roundNumber);
    }

    function getAssertion(bytes32 assertionId) external view
        returns (address asserter, uint8 claimedSide, uint filedAt, uint round) {
        AssertionContext memory ctx = assertions[assertionId];
        return (ctx.asserter, ctx.claimedSide, ctx.filedAt, ctx.round);
    }

    function getPendingCount() external view returns (uint count) {
        for (uint8 s = 1; s < _market.numSides; s++) {
            bytes32 id = sideAssertionId[_market.roundNumber][s];
            if (id != bytes32(0) && assertions[id].asserter != address(0)) count++;
        }
    }

    function getMarket() external view returns (Types.Market memory) { return _market; }
    function getPosition(address user, uint8 side) external view returns (Types.Position memory) { return _positions[user][side]; }
    function getPositionEntries(address user, uint8 side) external view returns (Types.PositionEntry[] memory) { return _entries[user][side]; }

    function burnAccumulatedFees() external {
        if (_market.resolved && !_market.payoutsComplete) revert("market not ready");
        uint fees = accumulatedFees;
        if (fees == 0) revert("order too small");
        accumulatedFees = 0;
        QUID.turn(address(this), fees);
    }

    /// @dev Convert gas used to QD via ETH TWAP.
    function _gasToQD(uint gasUsed) internal view returns (uint) {
        if (gasUsed == 0) return 0;
        return FullMath.mulDiv(gasUsed * block.basefee, QUID.AUX().getTWAP(0), WAD);
    }

    /// @dev Swap QD → ETH via Aux and forward to keeper.
    /// Fallback: transfer QD directly if swap fails.
    function _reimburseKeeper(uint qdAmount) internal {
        if (qdAmount == 0) return;
        uint ethBefore = address(this).balance;
        try QUID.AUX().swap{value: 0}(address(QUID), true, qdAmount, 0) {
            uint got = address(this).balance - ethBefore;
            if (got > 0) { (bool ok,) = msg.sender.call{value: got}(""); if (!ok) {} }
        } catch {
            uint qdBal = QUID.balanceOf(address(this));
            if (qdBal < qdAmount) qdAmount = qdBal;
            if (qdAmount > 0) QUID.transfer(msg.sender, qdAmount);
        }
    }
    receive() external payable {}
}
