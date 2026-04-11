
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Types} from "./imports/Types.sol";

/// @notice Bebop JAM settlement interface (settle path)
interface IJamSettlement {
    function settle(Types.JamOrder calldata order,
        bytes calldata signature, // raw EIP-712 sig bytes
        Types.Interaction[] calldata interactions,
        bytes memory hooksData, // ABI-encoded hooks (or "")
        address balanceRecipient // where taker sell tokens go
    ) external payable;
}

interface IAux {
    function flashLoan(
        address borrower,
        address token,
        uint256 amount,
        uint16 shareBps,
        bytes calldata data
    ) external returns (bool);
}

/// @dev Architecture: settle wraps flashLoan (flashLoan doesn't wrap settle).
///   JamSettlement.settle() runs interactions via runInteractions,
///   where msg.sender = JamSettlement. The flashLoan call lives inside
///   that interaction list, so Aux can gate with a single require:
///     require(msg.sender == jamSettlement)
///
/// Solver.sol is not a capital provider, a market maker, or a risk-bearing
/// counterparty. It is a named address — the minimum legal and technical
/// presence required for JamSettlement.settle() to have a msg.sender...
///
/// settle() is nonReentrant. runInteractions executes the full interactions
/// array sequentially within that single nonReentrant context. There is no
/// guard on individual interaction calls — only on the outer settle() entry point.
/// This means sequential flash loan calls from within the interactions
/// array are not blocked by JamSettlement's guard.
///
/// Capital: provided by Aux (the basket), not by the solver.
/// Routing: the callbackOps passed in at call time. Solver.sol executes blindly
///   inside onFlashLoan. It does not compute routes. It doesn't hold inventory.
///   It doesn't bear the risk of a sequence failing — if any callbackOp
///   reverts, the entire transaction reverts and Aux never moved.
///
/// The solver's contribution is: a signature, an address,
/// and colocation with infrastructure for optimal execution.
/// - No inventory: Aux.flashLoan() provides the buy token at execution
///   time. The solver holds nothing before solve() is called.
/// - No settlement risk: atomic execution guarantees either the full
///   sequence completes and Aux is repaid, or the transaction reverts.
///   There is no window during which the solver holds unhedged exposure.
/// - No credit intermediation: the solver passes sell tokens directly
///   from taker (via balanceRecipient = address(this)) to the
///   JamSettlement, and buy tokens from Aux to JamSettlement.
///   It is a router, not a counterparty.
///
/// The solve() function accepts callbackOps constructed entirely off-chain
/// by the operator. The solver executes them without discretion:
///   for (uint i; i < ops.length; ++i) { ops[i].to.call(...) }
///
/// There is no routing intelligence in this contract. No ongoing managerial
/// decision about which path to take, which DEX to use, which sequence to
/// execute. Those decisions were made before solve() was called, encoded
/// in callbackOps, and passed in by the operator.
///
/// The basket is the underwriter: it holds bonded dollar deposits locked
/// against redemption but not against productive deployment through
/// solver-routed execution sequences. Those bonded dollars move within
/// the atomic execution window and return with profit.
///
/// shareBps is the fraction of execution profit the solver returns to Aux
/// LPs beyond the principal repayment. This is not interest paid by the
/// protocol. It is the solver's voluntary contribution of execution surplus
///
///   Token flow for a typical order (taker sells WETH, buys USDC):
///
///   1. solve() calls JamSettlement.settle()
///   2. settle step 5: taker's WETH → Solver (balanceRecipient)
///   3. settle step 6: runInteractions → Aux.flashLoan(Solver, USDC, ...)
///        msg.sender = JamSettlement ✓
///        Aux sends 2000 USDC → Solver
///        Solver.onFlashLoan():
///          a. callbackOps route buy tokens to JamSettlement
///          b. callbackOps swap sell tokens for repayment
///          c. profit split: tip to Aux, rest stays
///          d. principal + tip → Aux
///        Aux checks returned >= sent ✓
///   4. settle step 7: USDC on JamSettlement → taker ✓
///
///   shareBps is the priority auction signal:
///   higher share → more gross on-chain product to basket LPs
///   → preferential orchestrator treatment → more order flow.
///
contract JamSolver is Ownable {
    bytes32 constant CALLBACK_SUCCESS =
        keccak256("ERC3156FlashBorrower.onFlashLoan");

    address public immutable aux;
    address public jamSettlement;

    error Unauthorized();
    error Insolvent();
    error CallFailed();

    /// @notice Emitted on successful settlement.
    /// @dev profit is the gross execution surplus before the shareBps split.
    ///      auxShare is the portion returned to Aux LPs as gross on-chain
    ///      product — not interest paid by the protocol, but execution surplus
    ///      generated by the solver's routing and voluntarily shared with the
    ///      capital pool that made the execution possible.
    event Settled(
        address indexed solver,
        address indexed token,
        uint256 borrowed,
        uint256 profit,
        uint256 auxShare
    );

    constructor(
        address _aux,
        address _jamSettlement
    ) Ownable(msg.sender) {
        aux = _aux;
        jamSettlement = _jamSettlement;
    }

    /// @notice Execute a JAM settlement using Aux flash loan.
    ///
    /// @param token       Token to borrow from Aux (typically the buy token).
    ///
    /// @param amount      Amount to borrow. This is the first-hop seed capital.
    ///                    In a multi-hop sequence each cleared hop releases
    ///                    proceeds into the next — the solver does not need
    ///                    the full notional of every hop pre-committed.
    ///                    Aux provides the first-hop capital. The sequence
    ///                    self-funds from there.
    ///
    /// @param shareBps    Profit share to Aux LPs (5000 = 50%). Higher bids
    ///                    generate more gross on-chain product and improve
    ///                    the orchestrator's future outlook about the solver.
    ///
    ///                    The solver retains (10000 - shareBps) bps
    ///                    of execution surplus as its routing fee.
    ///
    /// @param order       Bebop JAM order (Types.JamOrder — matches JamOrderLib exactly).
    ///                    Fields: taker, receiver, expiry, exclusivityDeadline, nonce,
    ///                    executor, partnerInfo, sellTokens[], buyTokens[],
    ///                    sellAmounts[], buyAmounts[], usingPermit2.
    ///                    Received from the JAM orchestrator off-chain and passed through.
    ///                    The solver is the named execution agent for an intent it did not originate.
    ///
    /// @param signature   Raw EIP-712 taker signature.
    ///
    /// @param hooksData   ABI-encoded hooks (pass "" if none).
    ///
    /// @param callbackOps Operations executed inside the flash loan callback.
    ///                    Constructed entirely off-chain by the operator.
    ///                    The solver executes them without discretion —
    ///                    no routing intelligence lives in this contract.
    ///                    This is architecturally significant: the absence
    ///                    of on-chain routing logic means the solver makes
    ///                    no ongoing managerial decisions that could be
    ///                    characterised as steering the basket's output.
    ///                    It executes what it is told. Coordination happens
    ///                    off-chain, by software, before solve() is called.
    function solve(
        address token,
        uint256 amount,
        uint16 shareBps,
        Types.JamOrder calldata order,
        bytes calldata signature,
        bytes calldata hooksData,
        Types.Interaction[] calldata callbackOps
    ) external onlyOwner {
        // Single interaction: the flash loan itself.
        // JamSettlement.runInteractions calls to.call{value}(data),
        // making msg.sender = jamSettlement at Aux.flashLoan. This
        // is the structural gate — no other path satisfies it.
        //
        // The gate enforces the legal architecture:
        // only a JAM-settled transaction can borrow from the basket.
        // The basket is not a general lending facility. It is a
        // JAM-exclusive flash loan source. The gate is the contract's
        // expression of the relational mapping: Bebop routes, Aux
        // capitalises, the solver names itself as execution agent.
        Types.Interaction[] memory ix = new Types.Interaction[](1);
        ix[0] = Types.Interaction({
            result: true,
            to:     aux,
            value:  0,
            data:   abi.encodeWithSelector(
                        IAux.flashLoan.selector,
                        address(this), // borrower
                        token,
                        amount,
                        shareBps,
                        abi.encode(callbackOps)
                    )
        });

        IJamSettlement(jamSettlement).settle(
            order,
            signature,
            ix,
            hooksData,
            address(this) // balanceRecipient: solver holds sell tokens
                          // transiently during onFlashLoan execution.
                          // They are converted to the borrowed token
                          // for repayment before onFlashLoan returns.
                          // The solver never holds them past the callback.
        );
    }

    /// @notice ERC-3156 flash loan callback.
    ///
    /// @dev Called by Aux during flashLoan (which itself runs inside
    ///      JamSettlement.settle → runInteractions).
    ///
    ///      Two guards enforce the trust boundary:
    ///      1. msg.sender == aux: only Aux can invoke this callback.
    ///         Prevents a malicious contract from calling onFlashLoan
    ///         directly to extract tokens without repaying.
    ///      2. initiator == address(this): only this solver can initiate
    ///         a flash loan that callbacks here. Prevents a different
    ///         address from using this solver's callback to execute
    ///         arbitrary operations against borrowed Aux capital.
    ///
    ///      These guards together mean the callback can only execute
    ///      when solve() on this contract initiated the sequence through
    ///      JamSettlement. The atomicity guarantee follows: if any
    ///      callbackOp reverts, the transaction reverts, Aux never moved,
    ///      and the basket's collateral is untouched.
    ///
    ///      The callbackOps execute arbitrary calls inside the flash loan.
    ///      The onlyOwner gate on solve() means only the operator who
    ///      controls the solver's owner key can construct callbackOps.
    ///      The attack surface is the operator's key, not the contract itself.
    ///
    function onFlashLoan(address initiator, address token,
        uint256 amount, uint16 shareBps, bytes calldata data) external
        returns (bytes32) { if (msg.sender != aux) revert Unauthorized();
        if (initiator != address(this)) revert Unauthorized();
        Types.Interaction[] memory ops = abi.decode(data,
                               (Types.Interaction[]));

        // Execute operator-constructed callback operations.
        // The solver has no knowledge of what these do beyond their
        // on-chain effects. They were constructed off-chain, passed
        // through solve(), encoded in data, and decoded here...

        // Solver is the named executor of a pre-determined sequence.
        // This is the architectural expression of the legal argument:
        // no ongoing managerial decision is made by the solver at
        // execution time. The decisions were made before solve() was
        // called, by software, by the operator who controls the key.

        for (uint i; i < ops.length; ++i) {
            (bool ok,) = ops[i].to.call{
                value: ops[i].value
            }(ops[i].data);
            if (!ok) revert CallFailed();
        }

        // ── Profit split ──────────────────────────────────────
        // bal >= amount: solvency check. If callbackOps failed to
        // generate enough tokens to repay, revert Insolvent() and
        // the entire transaction unwinds.
        //
        // tip = (surplus × shareBps) / 10000
        // This is the gross on-chain product flowing to basket LPs.
        // Not interest paid by the protocol. Not a distribution from
        // reserves. The execution surplus generated by routing a real
        // trade through real liquidity, shared with the capital pool
        // that made the routing possible, computed as a fraction of
        // what the routing actually produced.
        //
        // That is not yield paid by QU!D. It is the output of committed
        // capital doing work — gross on-chain product in its most
        // concrete on-chain form.
        {
            uint256 bal = IERC20(token).balanceOf(address(this));
            if (bal < amount) revert Insolvent();
            uint256 tip = ((bal - amount) * shareBps) / 10000;
            IERC20(token).transfer(aux, amount + tip);
            emit Settled(owner(), token, amount, bal - amount, tip);
        }
        return CALLBACK_SUCCESS;
    }

    // ── Admin ───────────────────────────────────────────────────

    /// @notice Update JAM settlement address.
    /// @dev This is the one ongoing managerial decision this contract
    ///      supports: pointing at a different JAM settlement contract.
    function setJamSettlement(address _jam) external onlyOwner {
        jamSettlement = _jam;
    }

    /// @notice Withdraw accumulated profits or stuck tokens.
    /// @dev Execution surplus not shared with Aux (the (1 - shareBps)
    ///      fraction) accumulates here and is withdrawable by the owner.
    ///      It is not yield from QD. It is not gross on-chain product
    ///      from the basket. It is the solver's share of execution
    ///      surplus from trades it routed — a routing fee, not an
    ///      investment return.
    function rescue(address token, uint256 amount) external onlyOwner {
        IERC20(token).transfer(owner(), amount);
    }

    /// @notice Rescue stuck ETH.
    function rescueETH() external onlyOwner {
        payable(owner()).transfer(address(this).balance);
    }

    receive() external payable {}
}
