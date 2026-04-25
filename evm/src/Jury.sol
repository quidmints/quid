
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Basket} from "./Basket.sol";
import {RandaoLib} from "./imports/RandaoLib.sol";
import {ReentrancyGuard} from "solmate/src/utils/ReentrancyGuard.sol";

interface ICourt {
    /// @dev One call returns all data Jury needs for distribution and routing.
    function getDistributionData(uint64 marketId) external view returns (
        uint verdictTs, uint8[] memory finalVerdict, uint8 currentRound, uint8 numSides);
}

contract Jury is ReentrancyGuard {
    address public court;
    address public immutable basket;

    uint constant REVEAL_SIZE = 12;
    uint constant FULL_JURY = 21;
    uint constant COMMIT_PERIOD = 4 days;
    uint constant REVEAL_WINDOW = 12 hours;
    uint constant APPEAL_WINDOW = 7 days;

    /// @dev Passed to voirDire to carry market config without extra stack slots.
    struct JuryConfig { uint8 numSides; uint8 numWinners; bool requiresUnanimous; }

    struct Round {
        uint8 numSides;
        uint8 numWinners;
        bool requiresUnanimous;
        address appellant;
        address[] jurors;
        uint[] revealedIndices;
        bool finalized;
        uint8[] verdict;
        bool unanimous;
        bool meetsThreshold;
        uint roundStart; // cached from Court to avoid cross-contract calls in commit/reveal
    }

    struct Compensation {
        uint baseFromSolana;
        uint appealPool; // QD from appellant appeal costs
        bool baseReceived;
        bool distributed;
    }

    mapping(uint64 => mapping(uint8 => Round)) public rounds;
    mapping(uint64 => mapping(address => bool)) public hasServed;
    mapping(uint64 => mapping(address => uint)) public lockedStake;
    mapping(uint64 => mapping(uint8 => mapping(address => bool))) public revealed;
    mapping(uint64 => mapping(uint8 => mapping(address => uint8[]))) public votes;
    mapping(uint64 => mapping(uint8 => mapping(address => bytes32))) public commits;
    mapping(uint64 => mapping(uint8 => mapping(address => address))) public delegates;
    mapping(uint64 => Compensation) public compensation;
    // O(1) juror membership — populated in voirDire
    mapping(uint64 => mapping(uint8 => mapping(address => bool))) public isJurorForRound;

    event JuryFulfilled(uint64 indexed marketId, uint8 round);
    event InsufficientStakers(uint64 indexed marketId, uint8 round, uint current, uint needed);
    event VoteCommitted(uint64 indexed marketId, uint8 round, address juror);
    event VoteRevealed(uint64 indexed marketId, uint8 round, address juror);
    event RoundFinalized(uint64 indexed marketId, uint8 round);
    event JurorSlashed(address juror, uint amount);
    event JurorCompensated(address juror, uint amount);
    event JuryCompensated(uint64 indexed marketId, uint total);

    error OnlyCourt();
    error OnlyBasket();
    error AlreadyCommitted();
    error AlreadyFinalized();
    error DoubleSpend();
    error NotActive();
    error NotJuror();
    error Unauthorized();
    error CommitPeriodEnded();
    error CommitPeriodActive();
    error RevealPeriodEnded();
    error AlreadyRevealed();
    error InvalidCommit();
    error InsufficientCommits();
    error InsufficientHeaders();

    modifier onlyCourt() {
        if (court == address(0) || msg.sender != court) revert OnlyCourt();
        _;
    }

    modifier onlyBasket() {
        if (msg.sender != basket) revert OnlyBasket();
        _;
    }

    address public owner;
    address public treasury; // receives unclaimable compensation; set once in setup

    modifier onlyOwner() { require(msg.sender == owner); _; }

    constructor(address _basket) {
        owner = msg.sender; basket = _basket;
    }

    function setup(address _court) external onlyOwner {
        court = _court;
        treasury = owner;  // lock in deployer as treasury before renouncing
        owner = address(0); // renounce: court address is immutable after setup
    }

    function receiveJuryFunds(uint64 marketId, uint amount)
        external nonReentrant onlyBasket {
        Compensation storage comp = compensation[marketId];

        (uint verdictTs,, , uint8 numSides) = ICourt(court).getDistributionData(marketId);

        // Late compensation: no active resolution AND no pending verdict → treasury
        if (numSides == 0 && verdictTs == 0) {
            Basket(basket).transfer(treasury, amount);
            return;
        }
        if (comp.distributed) {
            Basket(basket).transfer(treasury, amount);
            return;
        }
        if (comp.baseReceived) revert DoubleSpend();
        comp.baseFromSolana = amount;
        comp.baseReceived = true;
        _tryDistribute(marketId);
    }

    function addAppealCost(uint64 marketId, uint amount) external onlyCourt {
        compensation[marketId].appealPool += amount;
    }

    /// @notice Reset compensation state when Court evicts a resolved market,
    /// so a re-resolution doesn't send new funds to treasury.
    function resetCompensation(uint64 marketId) external onlyCourt {
        delete compensation[marketId];
    }

    function refundAppellant(uint64 marketId, uint amount, address appellant) external onlyCourt {
        compensation[marketId].appealPool -= amount;
        Basket(basket).transfer(appellant, amount);
    }

    function markCompensationTimedOut(uint64 marketId) external onlyCourt {
        Compensation storage comp = compensation[marketId];
        comp.baseFromSolana = 0; comp.baseReceived = true;
    }

    function tryDistribute(uint64 marketId) external nonReentrant {
        _tryDistribute(marketId);
    }

    function _tryDistribute(uint64 marketId) internal {
        Compensation storage comp = compensation[marketId];
        (uint verdictTs, uint8[] memory finalVerdict, uint8 finalRound,) =
            ICourt(court).getDistributionData(marketId);

        if (verdictTs == 0 || block.timestamp <= verdictTs + APPEAL_WINDOW ||
            !comp.baseReceived || comp.distributed) return;

        comp.distributed = true;
        emit JuryCompensated(marketId, _distributeCompensation(
            marketId, finalRound, finalVerdict, comp.baseFromSolana, comp.appealPool));
        comp.baseFromSolana = 0;
        comp.appealPool = 0;
    }

    function _distributeCompensation(uint64 marketId, uint8 finalRound,
        uint8[] memory finalVerdict, uint baseComp, uint appealPool)
        internal returns (uint distributed) {
        uint correctCount = 0;
        // At most REVEAL_SIZE jurors per round can be in correctJurors
        address[] memory correctJurors = new address[]((finalRound + 1) * REVEAL_SIZE);
        uint prize = baseComp + appealPool;
        for (uint8 roundNum = 0; roundNum <= finalRound; roundNum++) {
            (uint slashed, uint correct) = _processRoundJurors(
                marketId, roundNum, finalVerdict, correctJurors, correctCount);
            prize += slashed;
            correctCount = correct;
        }
        if (correctCount > 0) {
            uint perJuror = prize / correctCount;
            for (uint i = 0; i < correctCount; i++) {
                Basket(basket).transfer(correctJurors[i], perJuror);
            }
            distributed = perJuror * correctCount;
            if (prize - distributed > 0) Basket(basket).transfer(treasury, prize - distributed);
        } else {
            Basket(basket).transfer(treasury, prize);
            distributed = prize;
        } return distributed;
    }

    function voirDire(uint64 marketId, uint8 round,
        uint roundStart, JuryConfig calldata cfg,
        bytes[] calldata headers) external onlyCourt returns (bool) {
        Round storage r = rounds[marketId][round];

        // Round 0 with existing data: clear ALL old rounds for re-resolution
        if (round == 0 && (r.finalized || r.jurors.length > 0)) {
            for (uint8 oldRound = 0; oldRound < 10; oldRound++) {
                Round storage oldR = rounds[marketId][oldRound];
                if (oldR.jurors.length == 0) continue;
                for (uint i = 0; i < oldR.jurors.length; i++) {
                    address juror = oldR.jurors[i];
                    uint stake = lockedStake[marketId][juror];
                    if (stake > 0) {
                        Basket(basket).unlockFromJury(juror, stake);
                        lockedStake[marketId][juror] = 0;
                    }
                    hasServed[marketId][juror] = false;
                    isJurorForRound[marketId][oldRound][juror] = false;
                    delete commits[marketId][oldRound][juror];
                    delete revealed[marketId][oldRound][juror];
                    delete votes[marketId][oldRound][juror];
                    delete delegates[marketId][oldRound][juror];
                }
                delete rounds[marketId][oldRound];
            }
        } else if (r.finalized || r.jurors.length > 0) {
            // RETRY within same resolution: clear only this round
            for (uint i = 0; i < r.jurors.length; i++) {
                address juror = r.jurors[i];
                uint stake = lockedStake[marketId][juror];
                if (stake > 0) {
                    Basket(basket).unlockFromJury(juror, stake);
                    lockedStake[marketId][juror] = 0;
                }
                hasServed[marketId][juror] = false;
                isJurorForRound[marketId][round][juror] = false;
                delete commits[marketId][round][juror];
                delete revealed[marketId][round][juror];
                delete votes[marketId][round][juror];
                delete delegates[marketId][round][juror];
            }
            delete rounds[marketId][round];
        }
        r = rounds[marketId][round];
        if (r.numSides == 0) {
            r.numSides = cfg.numSides;
            r.numWinners = cfg.numWinners;
            r.requiresUnanimous = cfg.requiresUnanimous;
        }
        if (headers.length < 3 || headers.length > 10) revert InsufficientHeaders();
        bytes32 seed = RandaoLib.getHistoricalRandaoValue(block.number - 1, headers[0]);
        seed = keccak256(abi.encodePacked(seed,
            RandaoLib.getHistoricalRandaoValue(block.number - 2, headers[1]),
            RandaoLib.getHistoricalRandaoValue(block.number - 3, headers[2])));

        for (uint i = 3; i < headers.length; i++) {
            seed = keccak256(abi.encodePacked(seed,
                RandaoLib.getHistoricalRandaoValue(block.number - (i + 1), headers[i])));
        }
        uint poolSize = Basket(basket).juryPoolSize();
        if (poolSize < FULL_JURY) {
            emit InsufficientStakers(marketId,
                round, poolSize, FULL_JURY); return false;
        }
        // Partial Fisher-Yates shuffle: iterate through pool indices in a
        // random order, never revisiting the same index. This avoids the
        // birthday-problem collision issue of rejection sampling, which
        // at poolSize == FULL_JURY would fail ~66% of the time even with
        // generous maxAttempts bounds.
        uint selected = 0;
        uint[] memory pool = new uint[](poolSize);
        for (uint i = 0; i < poolSize; i++) pool[i] = i;
        for (uint i = 0; i < poolSize && selected < FULL_JURY; i++) {
            seed = keccak256(abi.encodePacked(seed, i));
            { uint j = i + uint(seed) % (poolSize - i);
              uint t = pool[i]; pool[i] = pool[j]; pool[j] = t; }
            if (_selectAndLockJuror(marketId, round,
                    Basket(basket).juryPoolMember(pool[i]), r)) selected++;
        }
        if (selected != FULL_JURY) return false;
        r.roundStart = roundStart;
        return true;
    }

    function commitVote(uint64 marketId, uint8 round,
        bytes32 commitment, address delegate) external {
        Round storage r = rounds[marketId][round];
        if (r.finalized) revert AlreadyFinalized();
        if (r.jurors.length == 0) revert NotActive();

        if (r.roundStart == 0) revert NotActive();
        if (block.timestamp > r.roundStart + COMMIT_PERIOD) revert CommitPeriodEnded();

        if (!isJurorForRound[marketId][round][msg.sender]) revert NotJuror();

        if (commitment == bytes32(0)) revert InvalidCommit(); // bytes32(0) treated as uncommitted
        if (commits[marketId][round][msg.sender] != bytes32(0)) revert AlreadyCommitted();
        if (delegate != address(0)) delegates[marketId][round][msg.sender] = delegate;

        commits[marketId][round][msg.sender] = commitment;
        emit VoteCommitted(marketId, round, msg.sender);
    }

    function revealVote(uint64 marketId, uint8 round,
        uint8[] calldata sides, bytes32 salt, address juror) external {
        Round storage r = rounds[marketId][round];
        if (r.finalized) revert AlreadyFinalized();

        if (msg.sender != delegates[marketId][round][juror] && msg.sender != juror) revert Unauthorized();
        if (r.roundStart == 0) revert NotActive();
        if (block.timestamp < r.roundStart + COMMIT_PERIOD) revert CommitPeriodActive();
        if (block.timestamp > r.roundStart + COMMIT_PERIOD + REVEAL_WINDOW) revert RevealPeriodEnded();

        if (revealed[marketId][round][juror]) revert AlreadyRevealed();
        if (commits[marketId][round][juror] != keccak256(abi.encode(sides, salt))) revert InvalidCommit();

        revealed[marketId][round][juror] = true;
        votes[marketId][round][juror] = sides;
        emit VoteRevealed(marketId, round, juror);
    }

    function finalizeRound(uint64 marketId, uint8 round,
        bytes[] calldata headers) external onlyCourt
        returns (uint8[] memory verdict, bool unanimous, bool meetsThreshold) {
        Round storage r = rounds[marketId][round];
        if (r.finalized) revert AlreadyFinalized();
        if (r.revealedIndices.length == 0) {
            if (block.timestamp <= r.roundStart + COMMIT_PERIOD) revert CommitPeriodActive();
            uint commitCount = 0;
            for (uint i = 0; i < r.jurors.length; i++) {
                if (commits[marketId][round][r.jurors[i]] != bytes32(0)) commitCount++;
            }
            if (commitCount < REVEAL_SIZE) {
                // Treat low participation as a hung jury — releases stakes
                // via _handleHungJury → new voirDire → clears lockedStake.
                r.finalized = true; // prevent re-entry
                r.meetsThreshold = false;
                r.unanimous = false;
                r.verdict = new uint8[](0);
                emit RoundFinalized(marketId, round);
                return (r.verdict, false, false);
            }
            if (headers.length < 2) revert InsufficientHeaders();

            bytes32 seed = RandaoLib.getHistoricalRandaoValue(block.number - 1, headers[0]);
            seed = keccak256(abi.encodePacked(seed, RandaoLib.getHistoricalRandaoValue(
                                                        block.number - 2, headers[1])));
            for (uint i = 2; i < headers.length; i++) {
                seed = keccak256(abi.encodePacked(seed,
                    RandaoLib.getHistoricalRandaoValue(
                    block.number - (i + 1), headers[i])));
            }
            // Build juror-index list for committed jurors, then partial Fisher-Yates
            // to select REVEAL_SIZE without collision.
            uint[] memory committedIdx = new uint[](commitCount);
            uint n = 0;
            for (uint i = 0; i < r.jurors.length; i++) {
                if (commits[marketId][round][r.jurors[i]] != bytes32(0)) {
                    committedIdx[n++] = i;
                }
            }
            for (uint i = 0; i < REVEAL_SIZE; i++) {
                seed = keccak256(abi.encodePacked(seed, i));
                { uint j = i + uint(seed) % (commitCount - i);
                  uint t = committedIdx[i]; committedIdx[i] = committedIdx[j]; committedIdx[j] = t; }
                r.revealedIndices.push(committedIdx[i]);
            }
        } uint revealCount = 0;
        for (uint i = 0; i < r.revealedIndices.length; i++) {
            address juror = r.jurors[r.revealedIndices[i]];
            if (revealed[marketId][round][juror]) revealCount++;
        }
        if (r.numWinners > 1) {
            (r.verdict,
             r.unanimous,
             r.meetsThreshold) = _getMultiWinner(marketId, round, r);
        } else {
            uint8[] memory voteCounts = new uint8[](r.numSides);
            for (uint i = 0; i < r.revealedIndices.length; i++) {
                address juror = r.jurors[r.revealedIndices[i]];
                if (revealed[marketId][round][juror]) {
                    uint8[] memory jurorVotes = votes[marketId][round][juror];
                    if (jurorVotes.length > 0 && jurorVotes[0] < r.numSides) {
                        voteCounts[jurorVotes[0]]++;
                    }
                }
            } uint8 maxVotes = 0;
            uint8 winningSide = 0;
            for (uint8 side = 0; side < r.numSides; side++) {
                if (voteCounts[side] > maxVotes) {
                    maxVotes = voteCounts[side];
                    winningSide = side;
                }
            }
            r.unanimous = (revealCount > 0 && maxVotes == revealCount);
            r.meetsThreshold = (revealCount > 0 && maxVotes * 3 >= revealCount * 2);
            r.verdict = new uint8[](1);
            r.verdict[0] = winningSide;
        }   r.finalized = true;
        emit RoundFinalized(marketId, round);
        return (r.verdict, r.unanimous, r.meetsThreshold);
    }

    function getStoredVerdict(uint64 marketId, uint8 round)
        external view returns (uint8[] memory verdict,
        bool unanimous, bool meetsThreshold) {
        Round storage r = rounds[marketId][round];
        return (r.verdict, r.unanimous, r.meetsThreshold);
    }

    function _selectAndLockJuror(uint64 marketId, uint8 round,
        address candidate, Round storage r) internal returns (bool) {
        if (hasServed[marketId][candidate]) return false;
        uint balance = Basket(basket).balanceOf(candidate);
        if (balance < 500e18) return false; // must hold at least 500 QD
        uint stake = balance / 5; // 20% of balance locked
        r.jurors.push(candidate);
        isJurorForRound[marketId][round][candidate] = true;
        hasServed[marketId][candidate] = true;
        lockedStake[marketId][candidate] = stake;
        Basket(basket).lockForJury(candidate, stake);
        return true;
    }

    function _getMultiWinner(uint64 marketId, uint8 round, Round storage r)
        internal view returns (uint8[] memory, bool, bool) {
        uint8[][] memory positionVotes = new uint8[][](r.numWinners);
        for (uint8 pos = 0; pos < r.numWinners; pos++) {
            positionVotes[pos] = new uint8[](r.numSides);
        }
        uint revealCount = 0;
        for (uint i = 0; i < r.revealedIndices.length; i++) {
            address juror = r.jurors[r.revealedIndices[i]];
            if (revealed[marketId][round][juror]) revealCount++;
        }
        for (uint i = 0; i < r.revealedIndices.length; i++) {
            address juror = r.jurors[r.revealedIndices[i]];
            if (revealed[marketId][round][juror]) {
                uint8[] memory ranking = votes[marketId][round][juror];
                for (uint8 pos = 0; pos < r.numWinners && pos < ranking.length; pos++) {
                    if (ranking[pos] < r.numSides) {
                        positionVotes[pos][ranking[pos]]++;
                    }
                }
            }
        } uint8[] memory winners = new uint8[](r.numWinners);
        uint8[] memory winnerVotes = new uint8[](r.numWinners);
        for (uint8 pos = 0; pos < r.numWinners; pos++) {
            uint8 maxVotes = 0;
            for (uint8 side = 0; side < r.numSides; side++) {
                if (positionVotes[pos][side] > maxVotes ||
                    (positionVotes[pos][side] == maxVotes &&
                    uint(keccak256(abi.encodePacked(
                        blockhash(block.number - 1),
                        pos, side))) % 2 == 0)) {
                            maxVotes = positionVotes[pos][side];
                            winners[pos] = side;
                }
            } winnerVotes[pos] = maxVotes;
        }
        if (revealCount == 0) {
            return (winners, false, false);
        }
        bool meetsThreshold = true;
        for (uint8 pos = 0; pos < r.numWinners; pos++) {
            if (winnerVotes[pos] * 3 < revealCount * 2) {
                meetsThreshold = false;
                break;
            }
        }
        bool unanimous = true;
        for (uint8 pos = 0; pos < r.numWinners; pos++) {
            if (winnerVotes[pos] != revealCount) {
                unanimous = false;
                break;
            }
        } return (winners, unanimous, meetsThreshold);
    }

    function getCorrectJurors(uint64 marketId,
        uint8 round) external view returns (address[] memory) {
        Round storage r = rounds[marketId][round];
        uint8[] memory finalVerdict = r.verdict;
        uint correct = 0;
        for (uint i = 0; i < r.revealedIndices.length; i++) {
            address juror = r.jurors[r.revealedIndices[i]];
            if (revealed[marketId][round][juror] &&
                _verdictMatches(votes[marketId][round][juror], finalVerdict)) {
                correct++;
            }
        } address[] memory correctJurors = new address[](correct);
        correct = 0;
        for (uint i = 0; i < r.revealedIndices.length; i++) {
            address juror = r.jurors[r.revealedIndices[i]];
            if (revealed[marketId][round][juror] &&
                _verdictMatches(votes[marketId][round][juror], finalVerdict)) {
                correctJurors[correct++] = juror;
            }
        } return correctJurors;
    }

    function isJuror(uint64 marketId, uint8 round,
        address addr) external view returns (bool) {
        return isJurorForRound[marketId][round][addr];
    }

    function _processRoundJurors(uint64 marketId,
        uint8 roundNum, uint8[] memory finalVerdict,
        address[] memory correctJurors, uint correctCount)
        internal returns (uint slashed, uint newCorrectCount) {
        Round storage round = rounds[marketId][roundNum];
        newCorrectCount = correctCount;

        // NOTE: turn() burns from mature batches only. If the juror's
        // entire QD balance is in immature batches, the burn returns 0
        // and the juror escapes the slash. Accepted tradeoff — in practice
        // jurors who hold meaningful stake will have some mature tokens,
        // and the selection mechanism favours larger holders...
        for (uint i = 0; i < round.revealedIndices.length; i++) {
            uint jurorIndex = round.revealedIndices[i];
            address juror = round.jurors[jurorIndex];
            uint stake = lockedStake[marketId][juror];
            if (stake == 0) continue;
            if (!revealed[marketId][roundNum][juror]) {
                Basket(basket).unlockFromJury(juror, stake);
                Basket(basket).turn(juror, stake);
                slashed += stake;
                emit JurorSlashed(juror, stake);
            } else if (_verdictMatches(votes[marketId][roundNum][juror], finalVerdict)) {
                Basket(basket).unlockFromJury(juror, stake);
                correctJurors[newCorrectCount++] = juror;
            } else {
                Basket(basket).unlockFromJury(juror, stake);
            }
            lockedStake[marketId][juror] = 0;
        }
        for (uint i = 0; i < round.jurors.length; i++) {
            address juror = round.jurors[i];
            uint stake = lockedStake[marketId][juror];
            if (stake > 0) {
                Basket(basket).unlockFromJury(juror, stake);
                lockedStake[marketId][juror] = 0;
            }
        }
    }

    function _verdictMatches(uint8[] memory a,
        uint8[] memory b) internal pure returns (bool) {
        if (a.length != b.length) return false;
        for (uint i = 0; i < a.length; i++) {
            if (a[i] != b[i]) return false;
        }
        return true;
    }

    function setAppellant(uint64 marketId,
        uint8 round, address appellant) external onlyCourt {
        rounds[marketId][round].appellant = appellant;
    }

    /// @notice Carry appellant from one round to the next in a single call.
    /// Saves one external CALL vs getAppellant + setAppellant in Court.
    function carryAppellant(uint64 marketId,
        uint8 fromRound, uint8 toRound) external onlyCourt returns (address appellant) {
        appellant = rounds[marketId][fromRound].appellant;
        if (appellant != address(0))
            rounds[marketId][toRound].appellant = appellant;
    }

    function getAppellant(uint64 marketId,
        uint8 round) external view returns (address) {
        return rounds[marketId][round].appellant;
    }

    function getJurors(uint64 marketId,
        uint8 round) external view
        returns (address[] memory) {
        return rounds[marketId][round].jurors;
    }
}
