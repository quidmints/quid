
use anchor_lang::prelude::*;
use crate::state::*;
use crate::stay::*;
use crate::etc::*;

// =============================================================================
// BATCH REVEAL — keeper reveals confidence commitments on users' behalf
// =============================================================================
// remaining_accounts = [position_0, position_1, ...]
// reveals[i] = RevealEntry vec for position_i's committed entries

#[derive(Accounts)]
pub struct BatchReveal<'info> {
    #[account(mut, seeds = [b"market",
    &market.market_id.to_le_bytes()[..6]],
    bump = market.bump)]
    pub market: Box<Account<'info, Market>>,

    #[account(mut, seeds = [b"accuracy_buckets",
    &market.market_id.to_le_bytes()[..6]],
    bump = accuracy_buckets.bump)]
    pub accuracy_buckets: Account<'info, AccuracyBuckets>,

    pub signer: Signer<'info>,
}

pub fn batch_reveal<'info>(ctx: Context<'_, '_, '_, 'info,
    BatchReveal<'info>>, reveals: Vec<Vec<RevealEntry>>) -> Result<()> {
    let accuracy_buckets = &mut ctx.accounts.accuracy_buckets;
    let signer_key = ctx.accounts.signer.key();
    let market = &mut ctx.accounts.market;

    require!(market.resolved, PithyQuip::NotResolved);
    require!(!market.weights_complete, PithyQuip::TooLate);
    require!(!market.challenged, PithyQuip::TradingFrozen);

    // If market-level reveal counters were reset (successful challenge
    // flipped outcome), existing per-position reveals are stale.
    // Capture this BEFORE the loop since counters change as positions
    // are re-revealed.
    let is_rereveal = market.positions_revealed == 0
        && market.total_winner_capital_revealed == 0
        && market.total_loser_capital_revealed == 0;

    for (i, position_info) in ctx.remaining_accounts.iter().enumerate() {
        require!(position_info.owner == &crate::ID, PithyQuip::InvalidAccountOwner);

        let mut data = position_info.try_borrow_mut_data()?;
        let mut position = Position::try_deserialize(&mut data.as_ref())?;
        require!(position.market == market.key(), PithyQuip::WrongMarket);

        let is_authorized = position.user == signer_key
            || position.reveal_delegate.map(|d| d == signer_key).unwrap_or(false);
        require!(is_authorized, PithyQuip::Unauthorized);

        if position.revealed_confidence > 0 {
            // If market-level counters were reset (successful challenge
            // flipped outcome), stale reveals are invalid — clear and
            // allow the user to re-reveal with fresh commitments.
            if is_rereveal {
                position.revealed_confidence = 0;
                position.accuracy_percentile = 0;
                position.weight = 0;
            } else {
                position.try_serialize(&mut data.as_mut())?;
                continue;
            }
        }
        let position_reveals = reveals.get(i).ok_or(PithyQuip::InvalidRevealCount)?;
        _do_reveal(&mut position, market, accuracy_buckets, position_reveals)?;
        position.try_serialize(&mut data.as_mut())?;
    }
    Ok(())
}

fn _do_reveal(position: &mut Position, market: &mut Market, 
    accuracy_buckets: &mut AccuracyBuckets, reveals: &[RevealEntry]) -> Result<()> {
    require!(position.revealed_confidence == 0, PithyQuip::AlreadyRevealed);
    require!(position.total_capital > 0, PithyQuip::InvalidPosition);
    let effective_end = market.resolution_time;
    let mut total_capital_seconds: u128 = 0;
    for entry in position.entries.iter_mut() {
        let time_elapsed = (effective_end - entry.last_updated).max(0) as u128;
        entry.capital_seconds = entry.capital_seconds
            .saturating_add((entry.capital as u128).saturating_mul(time_elapsed));
        entry.last_updated = effective_end;
        total_capital_seconds = total_capital_seconds.saturating_add(entry.capital_seconds);
    }
    position.total_capital_seconds = total_capital_seconds;
    let revealable_count = position.entries.len();
    require!(reveals.len() == revealable_count, PithyQuip::InvalidRevealCount);

    let mut weighted_confidence_sum: u128 = 0;
    for (i, entry) in position.entries.iter().enumerate() {
        let reveal = &reveals[i];
        let calculated_hash = hash_commitment_u64(reveal.confidence, reveal.salt);
        require!(
            calculated_hash == entry.commitment_hash,
            PithyQuip::CommitmentVerificationFailed
        );
        require!(
            reveal.confidence >= 500
                && reveal.confidence <= 10_000
                && reveal.confidence % 500 == 0,
            PithyQuip::InvalidConfidence
        );
        weighted_confidence_sum = weighted_confidence_sum
            .saturating_add(entry.capital as u128 * reveal.confidence as u128);
    }
    let weighted_avg_confidence =
        (weighted_confidence_sum / position.total_capital as u128).min(10_000) as u64;
    
    position.revealed_confidence = weighted_avg_confidence;
    // ── Loop 3: accumulate PAE (position-level avg, not per-entry joint) ─
    let mut weighted_pae_sum: u128 = 0;
    for entry in position.entries.iter() {
        weighted_pae_sum = weighted_pae_sum
            .saturating_add(entry.capital as u128 * entry.price_at_entry as u128);
    }
    let avg_pae = (weighted_pae_sum / position.total_capital as u128).min(9_999) as u64;
    // ── Accuracy: winners = confidence, losers = inverted confidence × contrarian 
    let is_winner = market.winning_sides.contains(&position.outcome);
    position.accuracy_percentile = if is_winner {
        weighted_avg_confidence
    } else {
        let base = 10_000u64.saturating_sub(weighted_avg_confidence); // inverted
        let contrarian_factor = 10_000u64.saturating_sub(avg_pae);
        (base as u128 * contrarian_factor as u128 / 10_000).min(10_000) as u64
    };
    accuracy_buckets.add_position(position.accuracy_percentile)?;
    if is_winner {
        market.total_winner_capital_revealed = market
            .total_winner_capital_revealed
            .saturating_add(position.total_capital);
    } else {
        market.total_loser_capital_revealed = market
            .total_loser_capital_revealed
            .saturating_add(position.total_capital);
    }
    market.positions_revealed += 1;
    Ok(())
}

// =============================================================================
// CALCULATE WEIGHTS — keeper computes weights for revealed positions
// =============================================================================
// remaining_accounts = [position_0, position_1, ...]
// Unrevealed positions naturally get weight 0 — skipped, counted.

#[derive(Accounts)]
pub struct CalculateWeights<'info> {
    #[account(mut, seeds = [b"market",
    &market.market_id.to_le_bytes()[..6]],
    bump = market.bump)]
    pub market: Box<Account<'info, Market>>,

    #[account(mut, seeds = [b"accuracy_buckets",
    &market.market_id.to_le_bytes()[..6]],
    bump = accuracy_buckets.bump)]
    pub accuracy_buckets: Box<Account<'info, AccuracyBuckets>>,

    #[account(mut, seeds = [b"depository"], bump)]
    pub bank: Box<Account<'info, Depository>>,

    #[account(init_if_needed, payer = signer, space = 8 + Depositor::INIT_SPACE,
        seeds = [signer.key().as_ref()], bump)]
    pub keeper_depositor: Box<Account<'info, Depositor>>,

    #[account(mut)]
    pub signer: Signer<'info>,

    pub system_program: Program<'info, System>,
}

pub fn calculate_weights<'info>(
    ctx: Context<'_, '_, '_, 'info, CalculateWeights<'info>>) -> Result<()> {
    let accuracy_buckets = &mut ctx.accounts.accuracy_buckets;
    let market = &mut ctx.accounts.market;
    let bank = &mut ctx.accounts.bank;
    let keeper = &mut ctx.accounts.keeper_depositor;

    require!(market.resolved, PithyQuip::NotResolved);
    require!(!market.weights_complete, PithyQuip::AlreadyComplete);
    require!(!market.challenged, PithyQuip::TradingFrozen);

    let clock = Clock::get()?;
    let right_now = clock.unix_timestamp;

    // Only after reveal window closes OR everyone already revealed
    let reveal_deadline = market.resolution_time + REVEAL_WINDOW;
    let all_revealed = market.positions_revealed >= market.positions_total;
    require!(right_now >= reveal_deadline || all_revealed,
             PithyQuip::TradingFrozen);

    let num_positions = ctx.remaining_accounts.len();
    require!(num_positions > 0, PithyQuip::NoPositions);

    if keeper.owner == Pubkey::default() {
        keeper.owner = ctx.accounts.signer.key();
        keeper.last_updated = right_now;
    }

    const KEEPER_FEE_PER_POSITION: u64 = 500;
    let keeper_fee = KEEPER_FEE_PER_POSITION.saturating_mul(num_positions as u64);
    let actual_fee = keeper_fee.min(market.fees_collected);
    if actual_fee > 0 {
        let time_delta = (right_now - keeper.last_updated).max(0);
        keeper.deposit_seconds += (keeper.deposited_quid as u128)
            .saturating_mul(time_delta as u128);
        keeper.deposited_quid += actual_fee;
        bank.total_deposits += actual_fee;
        keeper.last_updated = right_now;
        market.fees_collected -= actual_fee;
    }

    let effective_end = market.resolution_time;
    let market_duration = effective_end.saturating_sub(market.start_time).max(1);

    // If market-level weight aggregates were reset (successful challenge
    // flipped outcome), all existing per-position weights are stale and
    // must be recalculated. Capture this BEFORE the loop since the
    // aggregates will be non-zero after processing the first position.
    let is_reweight = market.total_winner_weight_revealed == 0
        && market.total_loser_weight_revealed == 0
        && market.positions_processed == 0;

    for position_info in ctx.remaining_accounts.iter() {
        require!(position_info.owner == &crate::ID, PithyQuip::InvalidAccountOwner);

        let mut data = position_info.try_borrow_mut_data()?;
        let mut position = Position::try_deserialize(&mut data.as_ref())?;
        require!(position.market == market.key(), PithyQuip::WrongMarket);

        // Ghost position from full sell — skip without counting
        if position.total_capital == 0 {
            position.try_serialize(&mut data.as_mut())?;
            continue;
        }

        // Already weighed — but if market counters were reset by a
        // successful challenge that flipped the outcome, the old weight
        // is stale and must be recalculated.
        if position.weight > 0 {
            if is_reweight {
                position.weight = 0;
            } else {
                position.try_serialize(&mut data.as_mut())?;
                continue;
            }
        }

        // Unrevealed — weight stays 0, just count it
        if position.revealed_confidence == 0 {
            market.positions_processed += 1;
            position.try_serialize(&mut data.as_mut())?;
            continue;
        }

        let percentile = accuracy_buckets.calculate_percentile(
            position.accuracy_percentile, market.positions_revealed);

        let mut time_weighted_total = 0u128;
        for entry in position.entries.iter() {
            let entry_duration = effective_end.saturating_sub(entry.timestamp);
            let entry_decay = calculate_time_decay(
                entry_duration, market_duration, market.time_decay_lambda);
            time_weighted_total = time_weighted_total.saturating_add(
                entry.capital_seconds.saturating_mul(entry_decay as u128) / 10_000
            );
        }
        position.weight = time_weighted_total.saturating_mul(percentile as u128) / 10_000;

        let is_winner = market.winning_sides.contains(&position.outcome);
        if is_winner {
            market.total_winner_weight_revealed = market.total_winner_weight_revealed
                .saturating_add(position.weight);
            // Per-outcome tracking for split-based pot partitioning
            let oi = position.outcome as usize;
            if oi < market.winner_weight_per_outcome.len() {
                market.winner_weight_per_outcome[oi] = market.winner_weight_per_outcome[oi]
                    .saturating_add(position.weight);
            }
        } else {
            market.total_loser_weight_revealed = market.total_loser_weight_revealed
                .saturating_add(position.weight);
        }
        market.positions_processed += 1;
        position.try_serialize(&mut data.as_mut())?;
    }

    if market.positions_processed >= market.positions_total {
        market.weights_complete = true;
        market.positions_processed = 0; // reset for push_payouts
    }
    Ok(())
}
