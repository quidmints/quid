
use anchor_lang::prelude::*;
use anchor_spl::token_interface::{ self, Mint, TokenAccount, TokenInterface, TransferChecked };
use switchboard_on_demand::on_demand::accounts::pull_feed::PullFeedAccountData;
use switchboard_on_demand::prelude::rust_decimal::prelude::ToPrimitive;
use crate::state::*;
use crate::stay::*;
use crate::etc::*;

// Permissionless. Anyone can call after deadline passes.
// remaining_accounts[0] = sb_feed (Switchboard Pull Feed)
#[derive(Accounts)]
pub struct ResolveMarket<'info> {
    #[account(mut, seeds = [b"market",
    &market.market_id.to_le_bytes()[..6]],
    bump = market.bump)]
    pub market: Box<Account<'info, Market>>,

    #[account(seeds = [b"program_config"], bump = config.bump)]
    pub config: Box<Account<'info, ProgramConfig>>,

    pub signer: Signer<'info>,
}

pub fn resolve_market<'info>(ctx: Context<'_, '_, '_,
    'info, ResolveMarket<'info>>) -> Result<()> {
    let market_key = ctx.accounts.market.key();
    let market = &mut ctx.accounts.market;
    let clock = Clock::get()?;
    let right_now = clock.unix_timestamp;

    require!(right_now >= market.deadline, PithyQuip::TradingFrozen);
    require!(!market.resolved && !market.cancelled, PithyQuip::AlreadyComplete);
    require!(!market.challenged, PithyQuip::TradingFrozen);
    // MODE_JURY_ONLY: feed resolution is never valid. Caller must use
    // send_resolution_request → LZ → process_final_ruling.
    require!(market.resolution_mode != MODE_JURY_ONLY, PithyQuip::NotResolved);
    // Block if a LZ resolution request is already in flight.
    // Prevents oracle feed and jury both resolving simultaneously.
    require!(!market.resolution_requested, PithyQuip::AlreadyRequested);

    let num_outcomes = market.outcomes.len();
    if num_outcomes < 2 {
        market.cancelled = true;
        market.resolved = true;
        market.resolution_time = right_now;
        market.weights_complete = true;
        return Ok(());
    }
    require!(ctx.remaining_accounts.len() >= 1,
             PithyQuip::InsufficientAccounts);

    let feed_info = &ctx.remaining_accounts[0];
    require!(feed_info.key() == market.sb_feed,
             PithyQuip::InvalidParameters);

    let feed = PullFeedAccountData::parse(feed_info.try_borrow_data()?)
        .map_err(|_| error!(PithyQuip::InvalidAccountOwner))?;

    require!(verify_trusted_feed(&feed, &ctx.accounts.config),
                              PithyQuip::InvalidAccountOwner);

    let value = feed.get_value(SB_MAX_STALE_SLOTS,
        u64::MAX, SB_MIN_SAMPLES, true).map_err(|_|
            error!(PithyQuip::InvalidParameters))?;

    let raw = value.to_u64().unwrap_or(0);

    // MODE_AI_PLUS_JURY: oracle may resolve only if confidence >= threshold.
    // Below threshold, return NotResolved so caller knows to escalate to jury
    // via send_resolution_request. The raw confidence is in the lower bits.
    if market.resolution_mode == MODE_AI_PLUS_JURY {
        let raw_conf = raw % 100_000_u64;
        require!(raw_conf >= MIN_RESOLUTION_CONFIDENCE, PithyQuip::NotResolved);
    }
    // Single-winner or multi-winner: branch on market.num_winners
    let (winning_sides, confidence) = if market.num_winners > 1 {
        let (winners, conf) = decode_oracle_value_multi(raw, &market_key, num_outcomes)?;
        require!(winners.len() <= market.num_winners as usize,
                 PithyQuip::InvalidResolution);
        for &w in &winners {
            require!((w as usize) < num_outcomes, PithyQuip::InvalidResolution);
        }
        if !market.winning_splits.is_empty() {
            let total: u64 = winners.iter()
                .filter_map(|&ws| market.winning_splits.get(ws as usize))
                .sum();
            require!(total == 10_000, PithyQuip::InvalidResolution);
        }
        require!(conf >= MIN_RESOLUTION_CONFIDENCE, PithyQuip::InsufficientConfidence);
        (winners, conf)
    } else {
        let (outcome_index, conf) = decode_oracle_value(raw, &market_key)?;
        // Outcome 255 = force majeure → cancel with refund
        if outcome_index == 255 {
            require!(conf >= MIN_RESOLUTION_CONFIDENCE, PithyQuip::InsufficientConfidence);
            market.cancelled = true;
            market.resolved = true;
            market.resolution_time = right_now;
            market.weights_complete = true;
            return Ok(());
        }
        require!((outcome_index as usize) < num_outcomes, PithyQuip::InvalidResolution);
        require!(conf >= MIN_RESOLUTION_CONFIDENCE, PithyQuip::InsufficientConfidence);
        (vec![outcome_index], conf)
    };
    market.winning_outcome = winning_sides[0];
    market.winning_sides = winning_sides.clone();
    market.resolution_confidence = confidence;
    market.resolved = true;
    market.resolution_time = right_now;

    emit!(MarketResolved {
        market_key,
        winning_outcome: winning_sides[0],
        winning_sides: winning_sides.clone(),
        confidence,
    });
    let any_capital = winning_sides.iter()
        .any(|&ws| market.total_capital_per_outcome[ws as usize] > 0);
    if !any_capital {
        market.weights_complete = true;
    }
    Ok(())
}

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

pub fn challenge_resolution(ctx: Context<ChallengeResolution>) -> Result<()> {
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

    // Bond = max(creator_bond * multiplier, resolution_bond from evidence config).
    // Must at least cover re-running resolution, so challenger pays oracle cost.
    let base_bond = market.creator_bond_lamports
        .saturating_mul(CHALLENGE_BOND_MULTIPLIER);

    // Read resolution_bond from MarketEvidence if present in remaining_accounts.
    // We read raw bytes to avoid lifetime issues with Account::try_from on locals.
    let resolution_bond = if !ctx.remaining_accounts.is_empty() {
        let data = ctx.remaining_accounts[0].try_borrow_data()?;
        if data.len() >= 8 {
            // Deserialize into owned value — no borrow lifetime issues
            let mut slice: &[u8] = &data[..];
            if let Ok(me) = MarketEvidence::try_deserialize(&mut slice) {
                me.evidence.resolution_bond
            } else { 0 }
        } else { 0 }
    } else { 0 };

    let bond = base_bond.max(resolution_bond);
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
// RESOLVE CHALLENGE — re-read oracle feed after challenge
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

    #[account(seeds = [b"program_config"], bump = config.bump)]
    pub config: Box<Account<'info, ProgramConfig>>,

    #[account(mut)]
    pub signer: Signer<'info>,

    pub system_program: Program<'info, System>,
}

pub fn resolve_challenge<'info>(ctx: Context<'_, '_, '_,
    'info, ResolveChallenge<'info>>) -> Result<()> {
    let market_key = ctx.accounts.market.key();
    let market = &mut ctx.accounts.market;
    let clock = Clock::get()?;

    require!(market.challenged, PithyQuip::InvalidParameters);

    require!(ctx.remaining_accounts.len() >= 1,
             PithyQuip::InsufficientAccounts);

    let feed_info = &ctx.remaining_accounts[0];
    require!(feed_info.key() == market.sb_feed,
             PithyQuip::InvalidParameters);

    let feed = PullFeedAccountData::parse(feed_info.try_borrow_data()?)
        .map_err(|_| error!(PithyQuip::InvalidAccountOwner))?;

    require!(verify_trusted_feed(&feed, &ctx.accounts.config),
             PithyQuip::InvalidAccountOwner);

    let value = feed.get_value(
        SB_MAX_STALE_SLOTS, u64::MAX, SB_MIN_SAMPLES, true,
    ).map_err(|_| error!(PithyQuip::InvalidParameters))?;

    let raw = value.to_u64().unwrap_or(0);
    let (new_outcome, new_confidence) = decode_oracle_value(raw, &market_key)?;

    // Force majeure on re-check → cancel
    if new_outcome == 255 && new_confidence >= MIN_RESOLUTION_CONFIDENCE {
        market.cancelled = true;
        market.resolved = true;
        market.challenged = false;
        market.weights_complete = true;
        market.resolution_time = clock.unix_timestamp;
        return Ok(());
    }
    let old_outcome = market.winning_outcome;
    // Low confidence + max challenges exceeded → cancel
    if new_confidence < MIN_RESOLUTION_CONFIDENCE
        && market.challenge_count >= MAX_CHALLENGES {
        market.cancelled = true; market.resolved = true;
        market.resolution_time = clock.unix_timestamp;
        market.weights_complete = true;
        market.challenged = false;
        return Ok(());
    }
    // Low confidence → stay challenged, oracle needs to retry
    if new_confidence < MIN_RESOLUTION_CONFIDENCE {
        return Err(PithyQuip::InsufficientConfidence.into());
    }
    // Validate the new outcome is in range
    require!((new_outcome as usize) < market.outcomes.len(), PithyQuip::InvalidResolution);
    if new_outcome == old_outcome {
        // Challenge failed — original confirmed. Reveals still valid.
        market.resolved = true;
        market.challenged = false;
        market.resolution_confidence = new_confidence;
        // Restart reveal window
        market.resolution_time = clock.unix_timestamp;
        // Challenger loses bond (stays in sol_vault → goes to creator/protocol)
    } else {
        // Challenge succeeded — re-resolve with corrected outcome.
        // The old winner/loser reveals are invalid because they were
        // computed against the wrong winning_outcome, so the full
        // reveal → weigh → payout pipeline must restart.
        market.winning_outcome = new_outcome;
        market.winning_sides = vec![new_outcome];
        market.resolution_confidence = new_confidence;
        market.resolved = true;
        market.challenged = false;
        market.resolution_time = clock.unix_timestamp;

        // Reset payout pipeline — old reveals invalid
        market.total_winner_weight_revealed = 0;
        market.total_loser_weight_revealed = 0;
        market.total_winner_capital_revealed = 0;
        market.total_loser_capital_revealed = 0;
        for w in market.winner_weight_per_outcome.iter_mut() { *w = 0; }
        market.positions_revealed = 0;
        market.positions_processed = 0;
        market.weights_complete = false;
        // Challenger gets bond back via sol_vault → resolved at payout time.
        // Creator bond portion may be slashed as reward.
        // Nobody bet on the corrected outcome → skip to payouts (refund all)
        if market.total_capital_per_outcome[new_outcome as usize] == 0 {
            market.weights_complete = true;
        }
        emit!(MarketResolved {
            market_key,
            winning_outcome: new_outcome,
            winning_sides: vec![new_outcome],
            confidence: new_confidence,
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
// CLAIM RESOLUTION BOND — oracle operator claims after successful resolution
// =============================================================================

/// Oracle operator claims the resolution bond after market is resolved.
/// Permissionless timing: anyone can trigger (bond goes to config.admin),
/// but only after market.resolved == true.
#[derive(Accounts)]
pub struct ClaimResolutionBond<'info> {
    #[account(seeds = [b"market",
    &market.market_id.to_le_bytes()[..6]],
    bump = market.bump)]
    pub market: Box<Account<'info, Market>>,

    #[account(mut, seeds = [b"market_evidence", market.key().as_ref()],
        bump = market_evidence.bump)]
    pub market_evidence: Account<'info, MarketEvidence>,

    /// CHECK: PDA vault holding the bond
    #[account(mut,
      seeds = [b"sol_vault", &market.market_id.to_le_bytes()[..6]],
      bump = market.sol_vault_bump)]
    pub sol_vault: SystemAccount<'info>,

    /// Oracle operator (config.admin) receives the bond when fees don't cover compute.
    #[account(mut, address = config.admin)]
    pub oracle_operator: SystemAccount<'info>,

    /// Market creator receives bond refund when fees_collected >= oracle_compute_cost.
    /// CHECK: Must match market.creator.
    #[account(mut, address = market.creator)]
    pub creator: SystemAccount<'info>,

    #[account(address = config.token_mint)]
    pub mint: InterfaceAccount<'info, Mint>,

    #[account(seeds = [b"program_config"], bump = config.bump)]
    pub config: Box<Account<'info, ProgramConfig>>,

    /// QD token vault — pays oracle when fees cover compute cost.
    #[account(mut, seeds = [b"vault", config.token_mint.as_ref()], bump)]
    pub program_vault: InterfaceAccount<'info, TokenAccount>,

    /// Oracle operator's QD token account for fee payment.
    #[account(mut, token::mint = config.token_mint,
              token::authority = oracle_operator)]
    pub oracle_fee_account: InterfaceAccount<'info, TokenAccount>,

    pub token_program: Interface<'info, TokenInterface>,
    pub system_program: Program<'info, System>,
}

pub fn claim_resolution_bond(ctx: Context<ClaimResolutionBond>) -> Result<()> {
    // Extract immutable fields before splitting the borrow
    let market_resolved   = ctx.accounts.market.resolved;
    let market_id         = ctx.accounts.market.market_id;
    let sol_vault_bump    = ctx.accounts.market.sol_vault_bump;
    let fees              = ctx.accounts.market.fees_collected;
    let me = &mut ctx.accounts.market_evidence;

    require!(market_resolved, PithyQuip::InvalidParameters);
    require!(!me.oracle_claimed, PithyQuip::AlreadyComplete);

    let bond = me.evidence.resolution_bond;
    let compute_cost = me.evidence.oracle_compute_cost;

    me.oracle_claimed = true;

    if bond == 0 && compute_cost == 0 {
        return Ok(());
    }

    let market_id_bytes = market_id.to_le_bytes();
    let seeds: &[&[u8]] = &[b"sol_vault", &market_id_bytes[..6],
                             &[sol_vault_bump]];

    let oracle_gets_bond = if compute_cost > 0 && fees >= compute_cost {
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
                token_interface::TransferChecked {
                    from:      ctx.accounts.program_vault.to_account_info(),
                    mint:      ctx.accounts.mint.to_account_info(),
                    to:        ctx.accounts.oracle_fee_account.to_account_info(),
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
        true // fees insufficient — oracle claims SOL bond instead
    };
    if oracle_gets_bond && bond > 0 {
        anchor_lang::system_program::transfer(
            CpiContext::new_with_signer(
                ctx.accounts.system_program.to_account_info(),
                anchor_lang::system_program::Transfer {
                    from: ctx.accounts.sol_vault.to_account_info(),
                    to: ctx.accounts.oracle_operator.to_account_info(),
                },
                &[seeds],
            ),
            bond,
        )?;
    }
    Ok(())
}
