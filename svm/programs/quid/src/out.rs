
use anchor_lang::prelude::*;
use anchor_spl::token_interface::{ self, Mint, TokenAccount,
    TokenInterface, TransferChecked };
use crate::state::*; use crate::etc::*;

// =============================================================================
// RESOLVE — keeper-signed verdict (post-Claude resolution)
// =============================================================================
//
// Replaces the old Switchboard-feed read. The keeper:
//   1. Probes Claude with the system prompt; aborts if Claude won't follow rubric.
//   2. Uploads each bid's evidence (verifying ed25519 sig + content hash).
//   3. Parses Claude's JSON verdict.
//   4. Publishes the canonical transcript at a stable URL.
//   5. Calls resolve(winning_sides, confidence, thread_url, thread_content_hash).
//
// thread_url + thread_content_hash are stored on-chain so a `force_jury`
// challenge can route to LZ → Court.sol with a verifiable artifact.
// Tamper-evident: keeper can take URL down but cannot serve different bytes.
//
// MODE_JURY_ONLY markets must use send_resolution_request (LZ jury) instead.

#[derive(Accounts)]
pub struct ResolveMarket<'info> {
    #[account(mut, seeds = [b"market",
        &market.market_id.to_le_bytes()[..6]],
        bump = market.bump)]
    pub market: Box<Account<'info, Market>>,

    #[account(seeds = [b"program_config"], bump = config.bump,
        constraint = keeper.key() == config.keeper @ PithyQuip::Unauthorized)]
    pub config: Box<Account<'info, ProgramConfig>>,

    pub keeper: Signer<'info>,
}

pub fn resolve_market(ctx: Context<ResolveMarket>,
    winning_sides: Vec<u8>, confidence: u64,
    thread_url: String, thread_content_hash: [u8; 32]) -> Result<()> {

    let market_key = ctx.accounts.market.key();
    let market = &mut ctx.accounts.market;
    let clock = Clock::get()?;
    let right_now = clock.unix_timestamp;

    require!(right_now >= market.deadline, PithyQuip::TradingFrozen);
    require!(!market.resolved && !market.cancelled, PithyQuip::AlreadyComplete);
    require!(!market.challenged, PithyQuip::TradingFrozen);
    // MODE_JURY_ONLY: keeper resolution is never valid here.
    require!(market.resolution_mode != MODE_JURY_ONLY, PithyQuip::NotResolved);
    // Block if a LZ resolution request is already in flight.
    require!(!market.resolution_requested, PithyQuip::AlreadyRequested);

    require!(thread_url.len() <= MAX_THREAD_URL_LEN, PithyQuip::InvalidParameters);
    // winning_sides.len() ≤ 20 in all cases. Empty array = force majeure (cancel),
    // matching Court.sol's `res.verdict = new uint8[](0)` convention AND LZ.rs's
    // FinalRuling::is_force_majeure() check. The previous u8=255 sentinel was a
    // Solana-only artifact of decoding a single-u8 outcome from a u64 oracle
    // response — no longer needed with Vec<u8> keeper-signed verdicts.
    require!(winning_sides.len() <= 20, PithyQuip::InvalidResolution);

    let num_outcomes = market.outcomes.len();
    if num_outcomes < 2 {
        market.cancelled = true;
        market.resolved = true;
        market.resolution_time = right_now;
        market.weights_complete = true;
        return Ok(());
    }

    // Force majeure → cancel with pro-rata refund (matches Court.sol).
    if winning_sides.is_empty() {
        require!(confidence >= MIN_RESOLUTION_CONFIDENCE,
                 PithyQuip::InsufficientConfidence);
        market.cancelled = true;
        market.resolved = true;
        market.resolution_time = right_now;
        market.weights_complete = true;
        market.resolution_thread_url = thread_url;
        market.thread_content_hash = thread_content_hash;
        return Ok(());
    }

    // Confidence floor. If the keeper can't reach MIN_RESOLUTION_CONFIDENCE and
    // jury_config is configured, the keeper should call send_resolution_request
    // instead. We refuse the resolve here so the caller is forced into that path.
    require!(confidence >= MIN_RESOLUTION_CONFIDENCE,
             PithyQuip::InsufficientConfidence);

    // Validate winning_sides
    require!(winning_sides.len() <= market.num_winners as usize,
             PithyQuip::InvalidResolution);
    for &w in &winning_sides {
        require!((w as usize) < num_outcomes, PithyQuip::InvalidResolution);
    }
    // Duplicates not allowed
    for i in 0..winning_sides.len() {
        for j in (i + 1)..winning_sides.len() {
            require!(winning_sides[i] != winning_sides[j],
                     PithyQuip::DuplicateOutcome);
        }
    }
    // If splits configured, the winners' splits must sum to 10_000 BPS
    if !market.winning_splits.is_empty() {
        let total: u64 = winning_sides.iter()
            .filter_map(|&ws| market.winning_splits.get(ws as usize))
            .sum();
        require!(total == 10_000, PithyQuip::InvalidResolution);
    }

    market.winning_outcome = winning_sides[0];
    market.winning_sides = winning_sides.clone();
    market.resolution_confidence = confidence;
    market.resolved = true;
    market.resolution_time = right_now;
    market.resolution_thread_url = thread_url;
    market.thread_content_hash = thread_content_hash;

    emit!(MarketResolved {
        market_key,
        winning_outcome: winning_sides[0],
        winning_sides: winning_sides.clone(),
        confidence,
    });

    // Skip reveal/weigh phases if no capital on any winning side.
    let any_capital = winning_sides.iter()
        .any(|&ws| market.total_capital_per_outcome[ws as usize] > 0);
    if !any_capital {
        market.weights_complete = true;
    }
    Ok(())
}

// =============================================================================
// CHALLENGE — pay bond to dispute keeper's verdict, optionally force jury
// =============================================================================
//
// Adversarial: challenger pays max(2× creator_bond, resolution_bond) — high
// enough to deter spam DoS. If challenger sets force_jury=true and the market
// has a jury_config, the next step must be send_resolution_request (LZ jury).
// Otherwise the keeper re-runs Claude via resolve_challenge.

#[derive(Accounts)]
pub struct ChallengeResolution<'info> {
    #[account(mut, seeds = [b"market",
    &market.market_id.to_le_bytes()[..6]],
    bump = market.bump)]
    pub market: Box<Account<'info, Market>>,

    /// CHECK: PDA for challenge bond deposit
    #[account(mut,
      seeds = [b"sol_vault", &market.market_id.to_le_bytes()[..6]],
      bump = market.sol_vault_bump)]
    pub sol_vault: SystemAccount<'info>,

    #[account(mut)]
    pub challenger: Signer<'info>,

    pub system_program: Program<'info, System>,
}

pub fn challenge_resolution(ctx: Context<ChallengeResolution>,
    force_jury: bool) -> Result<()> {

    let market = &mut ctx.accounts.market;
    let clock = Clock::get()?;
    let right_now = clock.unix_timestamp;

    require!(market.resolved, PithyQuip::InvalidParameters);
    require!(!market.challenged, PithyQuip::AlreadyComplete);
    require!(!market.weights_complete, PithyQuip::AlreadyComplete);
    require!(market.challenge_count < MAX_CHALLENGES, PithyQuip::TooManyChallenges);
    require!(market.positions_processed == 0, PithyQuip::AlreadyComplete);

    let challenge_deadline = market.resolution_time + REVEAL_WINDOW;
    require!(right_now < challenge_deadline, PithyQuip::TooLate);

    // If force_jury requested, jury_config MUST be present.
    if force_jury {
        require!(market.jury_config.is_some(), PithyQuip::InvalidParameters);
    }

    // Bond = max(2× creator_bond, resolution_bond).
    let base_bond = market.creator_bond_lamports
        .saturating_mul(CHALLENGE_BOND_MULTIPLIER);
    let bond = base_bond.max(market.resolution_bond);

    anchor_lang::system_program::transfer(
        CpiContext::new(
            ctx.accounts.system_program.to_account_info(),
            anchor_lang::system_program::Transfer {
                from: ctx.accounts.challenger.to_account_info(),
                to: ctx.accounts.sol_vault.to_account_info(),
            },
        ),
        bond,
    )?;
    // DO NOT reset positions_revealed or per-position state.
    // Same outcome → reveals still valid. Different → cancel.
    market.challenged = true;
    market.resolved = false;
    market.challenge_count += 1;
    market.force_jury_pending = force_jury;
    market.total_winner_weight_revealed = 0;
    market.total_loser_weight_revealed = 0;

    emit!(MarketChallenged {
        market_key: market.key(),
        challenger: ctx.accounts.challenger.key(),
        challenge_count: market.challenge_count,
    });
    Ok(())
}

// =============================================================================
// RESOLVE CHALLENGE — keeper re-runs Claude after challenge (no force_jury)
// =============================================================================

#[derive(Accounts)]
pub struct ResolveChallenge<'info> {
    #[account(mut, seeds = [b"market",
    &market.market_id.to_le_bytes()[..6]],
    bump = market.bump)]
    pub market: Box<Account<'info, Market>>,

    /// CHECK: PDA for challenge bond
    #[account(mut,
      seeds = [b"sol_vault", &market.market_id.to_le_bytes()[..6]],
      bump = market.sol_vault_bump)]
    pub sol_vault: SystemAccount<'info>,

    #[account(seeds = [b"program_config"], bump = config.bump,
        constraint = keeper.key() == config.keeper @ PithyQuip::Unauthorized)]
    pub config: Box<Account<'info, ProgramConfig>>,

    #[account(mut)]
    pub keeper: Signer<'info>,

    pub system_program: Program<'info, System>,
}

pub fn resolve_challenge(ctx: Context<ResolveChallenge>,
    winning_sides: Vec<u8>, confidence: u64,
    thread_url: String, thread_content_hash: [u8; 32]) -> Result<()> {

    let market_key = ctx.accounts.market.key();
    let market = &mut ctx.accounts.market;
    let clock = Clock::get()?;

    require!(market.challenged, PithyQuip::InvalidParameters);
    // If challenger requested jury, keeper cannot resolve — must use resolve_jury.
    require!(!market.force_jury_pending, PithyQuip::Unauthorized);

    require!(thread_url.len() <= MAX_THREAD_URL_LEN, PithyQuip::InvalidParameters);
    require!(winning_sides.len() <= 20, PithyQuip::InvalidResolution);

    // Force majeure on re-check → cancel (empty array convention, matches Court.sol)
    if winning_sides.is_empty() {
        require!(confidence >= MIN_RESOLUTION_CONFIDENCE,
                 PithyQuip::InsufficientConfidence);
        market.cancelled = true;
        market.resolved = true;
        market.challenged = false;
        market.weights_complete = true;
        market.resolution_time = clock.unix_timestamp;
        market.resolution_thread_url = thread_url;
        market.thread_content_hash = thread_content_hash;
        return Ok(());
    }

    let old_outcome = market.winning_outcome;

    // Low confidence + max challenges exceeded → cancel
    if confidence < MIN_RESOLUTION_CONFIDENCE
        && market.challenge_count >= MAX_CHALLENGES {
        market.cancelled = true;
        market.resolved = true;
        market.resolution_time = clock.unix_timestamp;
        market.weights_complete = true;
        market.challenged = false;
        market.resolution_thread_url = thread_url;
        market.thread_content_hash = thread_content_hash;
        return Ok(());
    }
    // Low confidence → stay challenged, keeper retries (or escalates to jury)
    if confidence < MIN_RESOLUTION_CONFIDENCE {
        return Err(PithyQuip::InsufficientConfidence.into());
    }

    // Validate the new outcomes
    let num_outcomes = market.outcomes.len();
    require!(winning_sides.len() <= market.num_winners as usize,
             PithyQuip::InvalidResolution);
    for &w in &winning_sides {
        require!((w as usize) < num_outcomes, PithyQuip::InvalidResolution);
    }
    for i in 0..winning_sides.len() {
        for j in (i + 1)..winning_sides.len() {
            require!(winning_sides[i] != winning_sides[j],
                     PithyQuip::DuplicateOutcome);
        }
    }

    let new_outcome = winning_sides[0];
    if new_outcome == old_outcome && winning_sides == market.winning_sides {
        // Challenge failed — original confirmed. Reveals still valid.
        market.resolved = true;
        market.challenged = false;
        market.resolution_confidence = confidence;
        market.resolution_time = clock.unix_timestamp; // restart reveal window
        market.resolution_thread_url = thread_url;
        market.thread_content_hash = thread_content_hash;
        // Challenger loses bond (stays in sol_vault → goes to creator/protocol)
    } else {
        // Challenge succeeded — re-resolve with corrected outcome.
        market.winning_outcome = new_outcome;
        market.winning_sides = winning_sides.clone();
        market.resolution_confidence = confidence;
        market.resolved = true;
        market.challenged = false;
        market.resolution_time = clock.unix_timestamp;
        market.resolution_thread_url = thread_url;
        market.thread_content_hash = thread_content_hash;

        // Reset payout pipeline — old reveals invalid against new winner
        market.total_winner_weight_revealed = 0;
        market.total_loser_weight_revealed = 0;
        market.total_winner_capital_revealed = 0;
        market.total_loser_capital_revealed = 0;
        for w in market.winner_weight_per_outcome.iter_mut() { *w = 0; }
        market.positions_revealed = 0;
        market.positions_processed = 0;
        market.weights_complete = false;

        // Nobody bet on the corrected outcome → skip to payouts (refund all)
        let any_capital = winning_sides.iter()
            .any(|&ws| market.total_capital_per_outcome[ws as usize] > 0);
        if !any_capital {
            market.weights_complete = true;
        }
        emit!(MarketResolved {
            market_key,
            winning_outcome: new_outcome,
            winning_sides,
            confidence,
        });
    }
    Ok(())
}

#[cfg(feature = "testing")]
#[derive(Accounts)]
pub struct TestResolve<'info> {
    #[account(mut, seeds = [b"market",
    &market.market_id.to_le_bytes()[..6]],
    bump = market.bump)]
    pub market: Box<Account<'info, Market>>,

    pub authority: Signer<'info>,
}

#[cfg(feature = "testing")]
pub fn test_resolve_market(ctx: Context<TestResolve>,
    winning_outcome: u8, confidence: u64) -> Result<()> {
    let market = &mut ctx.accounts.market;
    let clock = Clock::get()?;

    require!(!market.resolved && !market.cancelled, PithyQuip::AlreadyComplete);
    require!((winning_outcome as usize) < market.outcomes.len(),
             PithyQuip::InvalidParameters);

    market.winning_outcome = winning_outcome;
    market.winning_sides = vec![winning_outcome];
    market.resolution_confidence = confidence;
    market.resolved = true;
    market.resolution_time = clock.unix_timestamp;

    if market.total_capital_per_outcome[winning_outcome as usize] == 0 {
        market.weights_complete = true;
    }
    Ok(())
}

// =============================================================================
// CLAIM RESOLUTION BOND — keeper claims after successful resolution
// =============================================================================
//
// Permissionless timing: anyone can trigger.
//   - If fees_collected covers oracle_compute_cost → keeper paid in QD,
//     SOL bond refunded to creator.
//   - Otherwise → keeper claims SOL bond (covers Claude API cost).
//
// All accounting now lives on Market itself (no separate MarketEvidence PDA).

#[derive(Accounts)]
pub struct ClaimResolutionBond<'info> {
    #[account(mut, seeds = [b"market",
    &market.market_id.to_le_bytes()[..6]],
    bump = market.bump)]
    pub market: Box<Account<'info, Market>>,

    /// CHECK: PDA vault holding the bond
    #[account(mut,
      seeds = [b"sol_vault", &market.market_id.to_le_bytes()[..6]],
      bump = market.sol_vault_bump)]
    pub sol_vault: SystemAccount<'info>,

    /// Keeper receives the bond when fees don't cover compute cost.
    #[account(mut, address = config.keeper)]
    pub keeper: SystemAccount<'info>,

    /// Market creator receives bond refund when fees_collected >= oracle_compute_cost.
    /// CHECK: Must match market.creator.
    #[account(mut, address = market.creator)]
    pub creator: SystemAccount<'info>,

    #[account(address = config.token_mint)]
    pub mint: InterfaceAccount<'info, Mint>,

    #[account(seeds = [b"program_config"], bump = config.bump)]
    pub config: Box<Account<'info, ProgramConfig>>,

    /// QD token vault — pays keeper when fees cover compute cost.
    #[account(mut, seeds = [b"vault", config.token_mint.as_ref()], bump)]
    pub program_vault: InterfaceAccount<'info, TokenAccount>,

    /// Keeper's QD token account for fee payment.
    #[account(mut, token::mint = config.token_mint,
              token::authority = keeper)]
    pub keeper_fee_account: InterfaceAccount<'info, TokenAccount>,

    pub token_program: Interface<'info, TokenInterface>,
    pub system_program: Program<'info, System>,
}

pub fn claim_resolution_bond(ctx: Context<ClaimResolutionBond>) -> Result<()> {
    let market_resolved = ctx.accounts.market.resolved;
    let market_id       = ctx.accounts.market.market_id;
    let sol_vault_bump  = ctx.accounts.market.sol_vault_bump;
    let fees            = ctx.accounts.market.fees_collected;
    let bond            = ctx.accounts.market.resolution_bond;
    let compute_cost    = ctx.accounts.market.oracle_compute_cost;
    let already_claimed = ctx.accounts.market.oracle_claimed;

    require!(market_resolved, PithyQuip::InvalidParameters);
    require!(!already_claimed, PithyQuip::AlreadyComplete);

    ctx.accounts.market.oracle_claimed = true;

    if bond == 0 && compute_cost == 0 {
        return Ok(());
    }

    let market_id_bytes = market_id.to_le_bytes();
    let seeds: &[&[u8]] = &[b"sol_vault", &market_id_bytes[..6],
                            &[sol_vault_bump]];

    let keeper_gets_bond = if compute_cost > 0 && fees >= compute_cost {
        // Pay keeper from accumulated fees in QD.
        ctx.accounts.market.fees_collected =
            ctx.accounts.market.fees_collected.saturating_sub(compute_cost);

        let vault_seeds: &[&[u8]] = &[
            b"vault",
            ctx.accounts.config.token_mint.as_ref(),
            &[ctx.bumps.program_vault],
        ];
        token_interface::transfer_checked(
            CpiContext::new_with_signer(
                ctx.accounts.token_program.to_account_info(),
                TransferChecked {
                    from:      ctx.accounts.program_vault.to_account_info(),
                    mint:      ctx.accounts.mint.to_account_info(),
                    to:        ctx.accounts.keeper_fee_account.to_account_info(),
                    authority: ctx.accounts.program_vault.to_account_info(),
                },
                &[vault_seeds],
            ),
            compute_cost,
            ctx.accounts.mint.decimals,
        )?;

        // Refund SOL bond to creator.
        if bond > 0 {
            anchor_lang::system_program::transfer(
                CpiContext::new_with_signer(
                    ctx.accounts.system_program.to_account_info(),
                    anchor_lang::system_program::Transfer {
                        from: ctx.accounts.sol_vault.to_account_info(),
                        to:   ctx.accounts.creator.to_account_info(),
                    },
                    &[seeds],
                ),
                bond,
            )?;
        }
        false
    } else {
        true // fees insufficient — keeper claims SOL bond instead
    };
    if keeper_gets_bond && bond > 0 {
        anchor_lang::system_program::transfer(
            CpiContext::new_with_signer(
                ctx.accounts.system_program.to_account_info(),
                anchor_lang::system_program::Transfer {
                    from: ctx.accounts.sol_vault.to_account_info(),
                    to:   ctx.accounts.keeper.to_account_info(),
                },
                &[seeds],
            ),
            bond,
        )?;
    }
    Ok(())
}


// =============================================================================
// VERDICT RESOLVE -- keeper submits Claude evaluation result
// =============================================================================
// Keeper-only. template_url verified against verdict_hash (SHA256(resolution_source)
// stored at create_market), proving evaluation used the committed criteria.
// winning_sides + confidence from aggregated Claude verdict JSON.
// Wrong result can be challenged or escalated to jury.
// Mirrors resolve_market() so challenge/weigh/payout work identically downstream.

#[derive(Accounts)]
pub struct VerdictResolve<'info> {
    #[account(constraint = caller.key() == config.keeper @ PithyQuip::Unauthorized)]
    pub caller: Signer<'info>,

    #[account(seeds = [b"program_config"], bump = config.bump)]
    pub config: Box<Account<'info, ProgramConfig>>,

    #[account(mut,
        seeds = [b"market", &market.market_id.to_le_bytes()[..6]],
        bump = market.bump,
    )]
    pub market: Box<Account<'info, Market>>,
}

pub fn verdict_resolve(
    ctx: Context<VerdictResolve>,
    template_url: String,
    winning_sides: Vec<u8>,
    confidence: u64,
) -> Result<()> {
    let market_key = ctx.accounts.market.key();
    let market = &mut ctx.accounts.market;
    let clock = Clock::get()?;
    let right_now = clock.unix_timestamp;

    require!(right_now >= market.deadline, PithyQuip::TradingFrozen);
    require!(!market.resolved && !market.cancelled, PithyQuip::AlreadyComplete);
    require!(!market.challenged, PithyQuip::TradingFrozen);
    require!(market.resolution_mode != MODE_JURY_ONLY, PithyQuip::NotResolved);
    require!(!market.resolution_requested, PithyQuip::AlreadyRequested);

    require!(template_url.len() <= MAX_THREAD_URL_LEN, PithyQuip::InvalidParameters);
    let verdict_hash = market.verdict_hash
        .ok_or(error!(PithyQuip::InvalidParameters))?;
    let submitted_hash = anchor_lang::solana_program::hash::hash(template_url.as_bytes());
    require!(submitted_hash.to_bytes() == verdict_hash, PithyQuip::InvalidParameters);

    require!(winning_sides.len() <= 20, PithyQuip::InvalidResolution);

    let num_outcomes = market.outcomes.len();
    if num_outcomes < 2 {
        market.cancelled = true; market.resolved = true;
        market.resolution_time = right_now; market.weights_complete = true;
        return Ok(());
    }

    if winning_sides.is_empty() {
        require!(confidence >= MIN_RESOLUTION_CONFIDENCE, PithyQuip::InsufficientConfidence);
        market.cancelled = true; market.resolved = true;
        market.resolution_time = right_now; market.weights_complete = true;
        market.resolution_thread_url = template_url;
        market.thread_content_hash = verdict_hash;
        return Ok(());
    }

    require!(confidence >= MIN_RESOLUTION_CONFIDENCE, PithyQuip::InsufficientConfidence);
    require!(winning_sides.len() <= market.num_winners as usize, PithyQuip::InvalidResolution);
    for &w in &winning_sides {
        require!((w as usize) < num_outcomes, PithyQuip::InvalidResolution);
    }
    for i in 0..winning_sides.len() {
        for j in (i + 1)..winning_sides.len() {
            require!(winning_sides[i] != winning_sides[j], PithyQuip::DuplicateOutcome);
        }
    }
    if !market.winning_splits.is_empty() {
        let total: u64 = winning_sides.iter()
            .filter_map(|&ws| market.winning_splits.get(ws as usize)).sum();
        require!(total == 10_000, PithyQuip::InvalidResolution);
    }

    market.winning_outcome = winning_sides[0];
    market.winning_sides = winning_sides.clone();
    market.resolution_confidence = confidence;
    market.resolved = true;
    market.resolution_time = right_now;
    // resolution_finalized stays 0 -- set by claim_resolution_bond after
    // challenge window expires, matching resolve_market() behaviour.
    market.resolution_thread_url = template_url;
    market.thread_content_hash = verdict_hash;

    emit!(MarketResolved {
        market_key,
        winning_outcome: winning_sides[0],
        winning_sides: winning_sides.clone(),
        confidence,
    });

    let any_capital = winning_sides.iter()
        .any(|&ws| market.total_capital_per_outcome[ws as usize] > 0);
    if !any_capital { market.weights_complete = true; }
    Ok(())
}