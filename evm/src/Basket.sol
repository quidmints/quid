// SPDX-License-Identifier: MIT

pragma solidity ^0.8.26;

import {Aux} from  "./Aux.sol";
import {Link} from "./Link.sol";
import {Jury} from "./Jury.sol";

import {Court} from "./Court.sol";
import {OFT} from "./imports/OFT.sol";
import {Types} from "./imports/Types.sol";

import {Origin} from "./imports/oapp/OApp.sol";
import {BasketLib} from "./imports/BasketLib.sol";
import {SortedSetLib} from "./imports/SortedSet.sol";

import {ERC6909} from "solmate/src/tokens/ERC6909.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {MessageCodec} from "./imports/MessageCodec.sol";

import {IERC4626} from "forge-std/interfaces/IERC4626.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {SendParam} from "./imports/oapp/interfaces/IOFT.sol";
import {OFTMsgCodec} from "./imports/oapp/libs/OFTMsgCodec.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "solmate/src/utils/ReentrancyGuard.sol";
import {MessagingReceipt, MessagingFee} from "./imports/oapp/OAppSender.sol";

contract Basket is OFT, // LZ
    ERC6909, ReentrancyGuard {
    using SortedSetLib for SortedSetLib.Set;
    using OFTMsgCodec for bytes32;
    using OFTMsgCodec for bytes;

    error NotIn();
    error Locked();
    error NoBalance();
    error AlreadyIn();
    error WrongChain();         // LZ message arrived from unexpected srcEid
    error Unauthorized();
    error EmptyPayload();       // LZ send: no basket payload in calldata
    error PayloadMismatch();    // sum of batch amounts != OFT amountSentLD
    error InsufficientFee();    // msg.value < LayerZero native fee
    error MismatchedArrays();   // ids.length != amounts.length or empty
    error InsufficientBalance(); // sender balance < amount for a batch id
    error InsufficientUnlocked(); // transfer would exceed unlocked balance

    uint internal _deployed; // quidmint
    uint constant CAP = 600_000 * 1e18;
    error NoEndpoint(); error BadType();
    // since the pre-seed was in 2022...
    uint internal seeded; // seed round
    uint public target; // to recap...
    Link public LINK; Aux public AUX;
    address payable internal court;
    address payable public V4;
    address internal jury;
    modifier onlyUs() {
        if (!auth(msg.sender))
            revert Unauthorized(); _;
    }

    function auth(address who) public view returns (bool) {
        return (who == address(AUX) || who == V4 
            || who == address(LINK) || who == jury 
            || who == court); // vanilla (no hooks)
    }
    // QD holders call optInJury() to volunteer for paid jury duty...
    address constant LZ = 0x1a44076050125825900e736c501f859c50fE728c;
    uint32 public constant SOLANA_EID = 30168;
    uint32 public constant BASE_EID = 30184;
    uint32 public constant ARBI_EID = 30110;
    uint32 public constant POLY_EID = 30109;

    uint public l2Deposits;
    address[] internal l2Baskets;
    address[] internal juryPool;
    mapping(address => uint) internal juryLocked;
    mapping(address => uint) internal juryPoolIndex;

    mapping(uint => uint) public totalSupplies;
    mapping(address => bool) internal isL2Basket;
    mapping(address => uint) internal untouchables;

    constructor(address _vogue, address _aux)
        OFT("QU!D", "QD", LZ, msg.sender)
        Ownable(msg.sender) {
        V4 = payable(_vogue);
        AUX = Aux(payable(_aux));
        _deployed = block.timestamp;
    }

    function setup(address _hook, address _court,
        address _jury/*, address[] l2BasketAddrs */) external { 
            if (msg.sender != owner()
            || address(LINK) != address(0))
                revert Unauthorized();

        LINK = Link(payable(_hook)); court = payable(_court);
        jury = _jury; address[] memory stables = AUX.getStables();
        /*
        setPeer(SOLANA_EID, solanaProgram32Bytes);
        for (uint i = 0; i < l2Eids.length; i++) {
            setPeer(l2Eids[i], l2PeerBytes32[i]);
            _registerL2Basket(l2BasketAddresses[i]);
        } */
        LINK.createMarket(stables);
        // renounceOwnership();
    }

    function _registerL2Basket(address _l2) internal {
        if (msg.sender != owner()
            || isL2Basket[_l2])
            revert Unauthorized();

        isL2Basket[_l2] = true;
        l2Baskets.push(_l2);
    }

    /// @notice Distribute proportional
    /// L2 basket tokens on redeem...
    function distributeL2(address to,
        uint burned, uint total) external
        onlyUs returns (uint totalOut) {
        if (l2Deposits == 0) return 0;
        totalOut = BasketLib.distributeL2(
            l2Baskets, to, burned, total);

        l2Deposits -= Math.min(
          l2Deposits, totalOut);
    }

    mapping(address => SortedSetLib.Set) private perMonth;
    function currentMonth() public view returns (uint month) {
        month = (block.timestamp - _deployed) / BasketLib.MONTH;
    }

    function lockForJury(address juror,
        uint amount) onlyUs external {
        juryLocked[juror] += amount;
    }

    function unlockFromJury(address juror,
        uint amount) onlyUs external {
        juryLocked[juror] -= Math.min(
            juryLocked[juror], amount);
    }

    /// @notice Opt in to the jury pool. Any QD holder can volunteer.
    function optInJury() external {
        if (super.balanceOf(msg.sender) <= 500e18) revert NoBalance();
        if (juryPoolIndex[msg.sender] != 0) revert AlreadyIn();
        juryPool.push(msg.sender); 
        juryPoolIndex[msg.sender] = juryPool.length;
    }

    /// @notice Opt out of the jury pool; can't while
    /// stake is locked (actively serving on a jury).
    function optOutJury() external {
        uint idx = juryPoolIndex[msg.sender];
        if (idx == 0) revert NotIn();
        if (juryLocked[msg.sender] != 0) revert Locked();
        uint last = juryPool.length;
        if (idx != last) {
            address lastAddr = juryPool[last - 1];
            juryPool[idx - 1] = lastAddr;
            juryPoolIndex[lastAddr] = idx;
        } juryPool.pop();
        juryPoolIndex[msg.sender] = 0;
    } function juryPoolSize()
        external view returns (uint) {
        return juryPool.length;
    }

    /// @notice jury pool member by index.
    /// Used by Jury.voirDire for RANDAO
    /// seeded by random selection...
    function juryPoolMember(uint idx)
        external view returns (address) {
        return juryPool[idx];
    }

    function _debit(uint _amountLD, uint _minAmountLD,
        uint32 _dstEid) internal override returns
        (uint amountSentLD, uint amountReceivedLD) {
        // keep OFT safety math (fees, min amount)
        (amountSentLD, amountReceivedLD) = _debitView(
                     _amountLD, _minAmountLD, _dstEid);

        // pull basket payload from send(...) calldata...
        bytes memory payload = BasketLib.extract(msg.data);
        if (payload.length == 0) revert EmptyPayload(); uint total;

        (uint[] memory ids,
         uint[] memory amounts) = abi.decode(
                    payload, (uint[], uint[]));

        if (ids.length != amounts.length
         || ids.length == 0) revert MismatchedArrays();

        uint rate = this.decimalConversionRate();
        for (uint i = 0; i < ids.length; ++i) {
            uint id = ids[i]; uint amt = amounts[i] * rate;
            if (balanceOf[msg.sender][id] < amt)
                revert InsufficientBalance();

            total += amt;
            totalSupplies[id] -= amt;
            balanceOf[msg.sender][id] -= amt;
            if (balanceOf[msg.sender][id] == 0)
                perMonth[msg.sender].remove(id);
        }
        if (total != amountSentLD) revert PayloadMismatch();
        super._update(msg.sender, address(0), total);
    }
    
    function _lzReceive(Origin calldata _origin,
        bytes32 _guid, bytes calldata _message,
        address, bytes calldata) internal override {
        // check is sufficient; LZ nonces prevent replay
        if (_origin.sender != peers[_origin.srcEid]) 
            revert Unauthorized();

        uint64 amountSD = _message.amountSD();
        uint amountReceivedLD = _toLD(amountSD);
        bytes memory composeMsg = _message.composeMsg();
        address to = _message.sendTo().bytes32ToAddress();
        uint8 msgType = MessageCodec.getMessageType(composeMsg);
        
        if (msgType == MessageCodec.RESOLUTION_REQUEST) {
            if (_origin.srcEid != SOLANA_EID) revert WrongChain();
            Court(court).receiveResolutionRequest(composeMsg);
            emit OFTReceived(_guid, _origin.srcEid, court, 0);
        } 
        else if (msgType == MessageCodec.JURY_COMPENSATION) {
            if (_origin.srcEid != SOLANA_EID) revert WrongChain();
            _handleJuryCompensation(_guid, _origin.srcEid, 
                            composeMsg, amountReceivedLD);
        } 
        else if (msgType == MessageCodec.TRANSFER) {
            if (_origin.srcEid != SOLANA_EID 
             && _origin.srcEid != BASE_EID
             && _origin.srcEid != ARBI_EID
             && _origin.srcEid != POLY_EID) revert WrongChain();
            require(_handleBasketTransfer(composeMsg, 
                                        to) == amountReceivedLD);
        } else revert BadType();
    }

    function _handleJuryCompensation(bytes32 _guid,
        uint32 srcEid, bytes memory composeMsg, 
        uint amountReceived) internal {
        (uint64 marketId, uint64 amountSolana) =
            MessageCodec.decodeJuryCompensation(composeMsg);

        uint amount = MessageCodec.toEthereumAmount(amountSolana);
        require(amount == amountReceived, "amount mismatch"); 
        _mint(jury, currentMonth() + 1, amount);

        Jury(jury).receiveJuryFunds(marketId, amount);
        emit OFTReceived(_guid, srcEid, jury, amount);
    }

    function sendToSolana(bytes memory composeMsg)
        external onlyUs payable returns (bytes32) {
        if (composeMsg.length == 0) revert EmptyPayload();

        if (address(endpoint) == address(0)) revert NoEndpoint();
        uint8 msgType = MessageCodec.getMessageType(composeMsg);
        if (msgType != MessageCodec.FINAL_RULING) revert BadType();
        // little train, wait for me; once was blind but now I see

        uint32 dstEid = SOLANA_EID;
        bytes memory options = BasketLib.buildOptions(msgType);
        MessagingFee memory fee = _quote(dstEid,
                    composeMsg, options, false);

        if (msg.value < fee.nativeFee) revert InsufficientFee();
        MessagingReceipt memory receipt = _lzSend(dstEid,
                    composeMsg, options, fee, msg.sender);

        if (msg.value > fee.nativeFee) {
            (bool ok,) = payable(msg.sender).call{
                value: msg.value - fee.nativeFee}("");
            require(ok);
        } return receipt.guid;
    }

    function _handleBasketTransfer(
      bytes memory msg, address to)
      internal returns (uint total) {
      (uint[] memory ids,
       uint[] memory amounts) = abi.decode(msg,
                              (uint[], uint[]));

       if (ids.length != amounts.length
        || ids.length == 0) revert MismatchedArrays();

        uint rate = this.decimalConversionRate();
        for (uint i = 0; i < ids.length; ++i) {
            uint scaled = amounts[i] * rate;
            _mint(to, ids[i], scaled);
            total += scaled;
        }
    }

    function turn(address from, uint value) external
        onlyUs returns (uint sent, uint seedBurned) {
        uint seedBefore = untouchables[from];
        address destination = (msg.sender == jury) ?
                                jury : address(0);

        sent = _transferHelper(from, destination, value);
        seedBurned = seedBefore - untouchables[from];
    }

    function _mint(address receiver,
        uint when, uint amount)
        internal override {
        totalSupplies[when] += amount;
        perMonth[receiver].insert(when);
        super._update(address(0), receiver, amount);
        balanceOf[receiver][when] += amount;
        emit Transfer(msg.sender, address(0),
                    receiver, when, amount);
    }

    function mint(address pledge, uint amount,
        address token, uint when) external
        nonReentrant returns (uint normalized) {
        uint nextMonth = currentMonth() + 1;
        // this is used by Vogue.withdraw()
        if (auth(msg.sender)) { _mint(pledge,
           nextMonth, amount); return amount;
        }
        if (isL2Basket[token]) {
            IERC20(token).transferFrom(pledge,
                        address(this), amount);

            l2Deposits += amount;
            _mint(pledge, nextMonth,
            amount); return amount;
        }
        uint deposited = AUX.deposit(
               pledge, token, amount);

        (uint[14] memory deposits,
         uint avgYield) = AUX.get_deposits();
        uint decimals = IERC20(token).decimals();
        uint month = Math.max(Math.min(when,
                nextMonth + 12), nextMonth);

        bool isSeed = month == 13 && seeded < CAP;
        (normalized, month) = BasketLib.calcMintYield(deposited,
            decimals, month, nextMonth, seeded, avgYield, isSeed);

        if (isSeed) { seeded += normalized;
            untouchables[pledge] += normalized;
            target += normalized;
        }
        _mint(pledge, month, normalized);
    }

    function transfer(address to,
        uint value) public override returns (bool) {
        require(value == _transferHelper(msg.sender,
                          to, value)); return true;
    }

    function transfer(address to, uint256, uint256 amount)
        public override returns (bool) {
        require(amount == _transferHelper(msg.sender, to, amount));
        return true;
    }

    function transferFrom(address from, address to, uint256, uint256 amount)
        public override returns (bool) {
        _spendAllowance(from, _msgSender(), amount);
        _transferHelper(from, to, amount); return true;
    }

    function transferFrom(address from,
        address to, uint value) public
        override returns (bool) {
        address spender = _msgSender();
        _spendAllowance(from, spender, value);
        _transferHelper(from, to, value); return true;
    }

    function _transferHelper(address from, address to,
        uint amount) internal returns (uint sent) {
        if (super.balanceOf(from) - juryLocked[from] < amount)
            revert InsufficientUnlocked();

        uint[] memory batches = perMonth[from].getSortedSet();
        bool turning = to == address(0); int i = turning &&
            from != address(LINK) ? BasketLib.matureBatches(
                        batches, block.timestamp, _deployed):
                                     int(batches.length - 1);
        while (amount > 0 && i >= 0) {
            uint k = batches[uint(i)];
            uint amt = balanceOf[from][k];
            if (amt > 0) {
                amt = Math.min(amount, amt);
                balanceOf[from][k] -= amt;
                if (!turning) {
                    perMonth[to].insert(k);
                    balanceOf[to][k] += amt;
                } else
                    totalSupplies[k] -= amt;
                if (balanceOf[from][k] == 0)
                    perMonth[from].remove(k);
                
                amount -= amt; sent += amt;
            } i -= 1; // liable to be -1
        } // -1 means "no mature batches"
        if (sent > 0) { 
            super._update(from, to, sent);
            // ^ should burn from totalSupply
            // if necessary (to = address(0))
            if (untouchables[from] > 0) {
                uint seed = Math.min(sent,
                  untouchables[from]);
                untouchables[from] -= seed;
                if (to == address(0))
                    target -= Math.min(target, seed);
                else untouchables[to] += seed;
            }
        }
    }
}
