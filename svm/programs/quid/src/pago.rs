
use anchor_lang::prelude::*;
use anchor_spl::token_interface::Mint;
use switchboard_on_demand::on_demand::accounts::pull_feed::PullFeedAccountData;
use switchboard_on_demand::prelude::rust_decimal::prelude::ToPrimitive;
use crate::state::*;
use crate::stay::*;
use crate::etc::*;

// =============================================================================
// SELL POSITION (pre-deadline exit from prediciton market, LMSR mechanics)
// =============================================================================

#[derive(Accounts)]
pub struct SellPosition<'info> {
    #[account(mut, seeds = [b"market",
    &market.market_id.to_le_bytes()[..6]],
    bump = market.bump)]
    pub market: Box<Account<'info, Market>>,

    #[account(mut, seeds = [b"position",
    market.key().as_ref(), user.key().as_ref(),
    &[position.outcome]], bump = position.bump)]
    pub position: Account<'info, Position>,

    #[account(mut, seeds = [b"depository"], bump)]
    pub bank: Account<'info, Depository>,

    #[account(mut, seeds = [user.key().as_ref()], bump)]
    pub user_depositor: Account<'info, Depositor>,

    #[account(mut)]
    pub user: Signer<'info>,

    pub mint: InterfaceAccount<'info, Mint>,
    pub system_program: Program<'info, System>,
}

pub fn sell_position(ctx: Context<SellPosition>,
    tokens_to_sell: u64, max_deviation_bps: Option<u64>) -> Result<()> {
    let market = &mut ctx.accounts.market;
    let position = &mut ctx.accounts.position;
    let bank = &mut ctx.accounts.bank;
    let depositor = &mut ctx.accounts.user_depositor;

    require!(!market.resolved && !market.cancelled, PithyQuip::TradingClosed);

    let clock = Clock::get()?;
    let right_now = clock.unix_timestamp;
    require!(right_now < market.deadline, PithyQuip::TradingClosed);
    require!(tokens_to_sell <= position.total_tokens, PithyQuip::InsufficientTokens);

    update_price_accumulator(market, right_now)?;
    let max_deviation = max_deviation_bps.unwrap_or(300);
    let deviation = get_price_deviation(market, position.outcome, right_now);
    require!(deviation <= max_deviation, PithyQuip::PriceManipulated);

    market.liquidity = calculate_adaptive_liquidity(market, right_now);
    let current_price = get_twap_price(market, position.outcome, right_now);
    let capital_returned = (tokens_to_sell as f64 * current_price) as u64;
    let exit_fee = (capital_returned as u128 * market.creator_fee_bps as u128) / 10_000;
    let net_capital = capital_returned.saturating_sub(exit_fee as u64);

    position.total_tokens = position.total_tokens
        .checked_sub(tokens_to_sell)
        .ok_or(PithyQuip::Underflow)?;

    let total_tokens_before = position.total_tokens + tokens_to_sell;
    let sell_fraction = if total_tokens_before > 0 {
        (tokens_to_sell as u128 * 10_000) / (total_tokens_before as u128)
    } else { 10_000 };

    for entry in position.entries.iter_mut() {
        let time_elapsed = (right_now - entry.last_updated).max(0) as u64;
        entry.capital_seconds += (entry.capital as u128).saturating_mul(time_elapsed as u128);
        entry.last_updated = right_now;
    }

    let mut total_capital_seconds = 0u128;
    for entry in position.entries.iter() {
        total_capital_seconds = total_capital_seconds.saturating_add(entry.capital_seconds);
    }
    position.total_capital_seconds = total_capital_seconds;

    let mut total_capital_seconds_removed = 0u128;
    let mut i = 0;
    while i < position.entries.len() {
        let entry_capital = position.entries[i].capital;
        let entry_tokens = position.entries[i].tokens;
        let entry_capital_seconds = position.entries[i].capital_seconds;
        let tokens_from_entry = (entry_tokens as u128 * sell_fraction) / 10_000;

        if tokens_from_entry >= entry_tokens as u128 {
            total_capital_seconds_removed = total_capital_seconds_removed
                .saturating_add(entry_capital_seconds);
            position.total_capital = position.total_capital.saturating_sub(entry_capital);
            position.entries.remove(i);
        } else {
            let entry = &mut position.entries[i];
            let capital_from_entry = (entry_capital as u128 * tokens_from_entry) / (entry_tokens as u128);
            let capital_seconds_removed = (entry_capital_seconds * tokens_from_entry) / (entry_tokens as u128);
            entry.tokens = entry.tokens.saturating_sub(tokens_from_entry as u64);
            entry.capital = entry.capital.saturating_sub(capital_from_entry as u64);
            entry.capital_seconds = entry_capital_seconds.saturating_sub(capital_seconds_removed);
            position.total_capital = position.total_capital.saturating_sub(capital_from_entry as u64);
            total_capital_seconds_removed = total_capital_seconds_removed
                .saturating_add(capital_seconds_removed);
            i += 1;
        }
    }
    position.total_capital_seconds = position.total_capital_seconds
        .saturating_sub(total_capital_seconds_removed);

    let outcome = position.outcome;
    market.tokens_sold_per_outcome[outcome as usize] = market.tokens_sold_per_outcome[outcome as usize]
        .saturating_sub(tokens_to_sell);
    market.total_capital = market.total_capital.saturating_sub(capital_returned.min(market.total_capital));
    market.total_capital_per_outcome[outcome as usize] = market.total_capital_per_outcome[outcome as usize]
        .saturating_sub(capital_returned);
    market.fees_collected = market.fees_collected.checked_add(exit_fee as u64).ok_or(PithyQuip::Overflow)?;

    if net_capital > 0 {
        depositor.pool_deposit(bank, net_capital, right_now);
    }

    const MIN_POSITION_VALUE: u64 = 100_000_000;
    if position.entries.is_empty() || (position.total_capital > 0 && position.total_capital < MIN_POSITION_VALUE) {
        let remaining = position.total_capital;
        if remaining > 0 {
            depositor.pool_deposit(bank, remaining, right_now);
            market.total_capital = market.total_capital.saturating_sub(remaining);
            market.total_capital_per_outcome[outcome as usize] = market.total_capital_per_outcome[outcome as usize]
                .saturating_sub(remaining);
        }
        market.positions_total = market.positions_total.saturating_sub(1);
        position.total_capital = 0;
        position.total_tokens = 0;
        position.total_capital_seconds = 0;
        position.entries.clear();
    }
    Ok(())
}

// =============================================================================
// PUSH PAYOUTS — compute payout + credit depositor + close position PDA
// =============================================================================
// remaining_accounts layout:
//   [position_0, depositor_0, position_1, depositor_1, ...]
//
// Payout structure (single winning outcome):
//   Loser pot = loser capital + unrevealed capital
//   Creator fee = creator_fee_bps of loser pot
//   Distributable = loser pot - creator fee
//   80% → winners (proportional to weight)
//   20% → loser consolation (proportional to weight)

#[derive(Accounts)]
pub struct PushPayouts<'info> {
    #[account(mut, seeds = [b"market",
    &market.market_id.to_le_bytes()[..6]],
    bump = market.bump)]
    pub market: Box<Account<'info, Market>>,

    #[account(mut, seeds = [b"depository"], bump)]
    pub bank: Box<Account<'info, Depository>>,

    #[account(mut, seeds = [market.creator.as_ref()], bump)]
    pub creator_depositor: Box<Account<'info, Depositor>>,

    /// CHECK: Seeds validated against market
    #[account(mut,
      seeds = [b"sol_vault", &market.market_id.to_le_bytes()[..6]],
      bump = market.sol_vault_bump)]
    pub sol_vault: SystemAccount<'info>,

    /// CHECK: Must match market.creator
    #[account(mut, address = market.creator)]
    pub creator: AccountInfo<'info>,

    #[account(init_if_needed, payer = signer, space = 8 + Depositor::INIT_SPACE,
        seeds = [signer.key().as_ref()], bump)]
    pub keeper_depositor: Box<Account<'info, Depositor>>,

    #[account(mut)]
    pub signer: Signer<'info>,

    pub system_program: Program<'info, System>,
}

pub fn push_payouts<'info>(ctx: Context<'_, '_, '_, 'info, PushPayouts<'info>>) -> Result<()> {
    let market = &mut ctx.accounts.market;
    let bank = &mut ctx.accounts.bank;
    let creator = &mut ctx.accounts.creator_depositor;
    let keeper = &mut ctx.accounts.keeper_depositor;

    require!(market.resolution_time > 0, PithyQuip::NotFinalized);
    require!(!market.payouts_complete, PithyQuip::AlreadyComplete);
    if !market.cancelled {
        require!(market.weights_complete, PithyQuip::WeightsNotCalculated);
    }

    let clock = Clock::get()?;
    let right_now = clock.unix_timestamp;

    if keeper.owner == Pubkey::default() {
        keeper.owner = ctx.accounts.signer.key();
        keeper.last_updated = right_now;
    }

    // Count beneficiary depositors at end of remaining_accounts
    let num_beneficiaries = if market.beneficiaries.is_empty() { 0 } else {
        market.winning_sides.iter()
            .filter(|&&oi| {
                let idx = oi as usize;
                idx < market.beneficiaries.len() && market.beneficiaries[idx].is_some()
            })
            .count()
    };

    let total_accounts = ctx.remaining_accounts.len();
    let position_accounts = total_accounts.saturating_sub(num_beneficiaries);
    require!(position_accounts % 2 == 0, PithyQuip::InvalidParameters);
    let num_positions = position_accounts / 2;

    // Keeper fee
    const KEEPER_FEE_PER_POSITION: u64 = 1_000;
    let keeper_fee = KEEPER_FEE_PER_POSITION.saturating_mul(num_positions as u64);
    let actual_fee = keeper_fee.min(market.fees_collected);
    if actual_fee > 0 && num_positions > 0 {
        keeper.pool_deposit(bank, actual_fee, right_now);
        market.fees_collected -= actual_fee;
    }

    // Precompute payout pools
    let (winner_pot, loser_pot, total_loser_weight, creator_fee_amt) =
        if market.cancelled || market.total_winner_capital_revealed == 0 {
            (0u128, 0u128, 0u128, 0u128)
        } else {
            let unrevealed = market.total_capital
                .saturating_sub(market.total_winner_capital_revealed)
                .saturating_sub(market.total_loser_capital_revealed);
            let loser_pot_total = market.total_loser_capital_revealed
                .saturating_add(unrevealed);

            let creator_fee_bps = market.creator_fee_bps as u128;
            let creator_fee = (loser_pot_total as u128 * creator_fee_bps) / 10_000;
            let distributable = (loser_pot_total as u128).saturating_sub(creator_fee);

            let w_pot = (distributable * 8_000) / 10_000;
            let l_pot = distributable.saturating_sub(w_pot);

            (w_pot, l_pot, market.total_loser_weight_revealed, creator_fee)
        };

    // Per-outcome winner sub-pots (for multi-winner split markets)
    // For single-winner or empty splits: sub_pot[winning_outcome] = winner_pot
    let num_outcomes = market.outcomes.len();
    let mut sub_pot = vec![0u128; num_outcomes];
    if winner_pot > 0 && !market.winning_sides.is_empty() {
        if market.winning_splits.is_empty() {
            // Equal split among winning sides
            let n = market.winning_sides.len() as u128;
            let per_side = winner_pot / n;
            for &ws in &market.winning_sides {
                if (ws as usize) < num_outcomes { sub_pot[ws as usize] = per_side; }
            }
            // Dust to first winner
            let dust = winner_pot.saturating_sub(per_side * n);
            if dust > 0 { sub_pot[market.winning_sides[0] as usize] += dust; }
        } else {
            // Split-proportional: normalize winning splits
            let total_split: u128 = market.winning_sides.iter()
                .filter_map(|&ws| market.winning_splits.get(ws as usize))
                .map(|&s| s as u128)
                .sum();
            if total_split > 0 {
                let mut allocated = 0u128;
                for (i, &ws) in market.winning_sides.iter().enumerate() {
                    let idx = ws as usize;
                    if idx < num_outcomes && idx < market.winning_splits.len() {
                        let share = winner_pot * (market.winning_splits[idx] as u128) / total_split;
                        sub_pot[idx] = share;
                        allocated += share;
                    }
                    // Dust to last winner
                    if i == market.winning_sides.len() - 1 {
                        let dust = winner_pot.saturating_sub(allocated);
                        if dust > 0 && idx < num_outcomes { sub_pot[idx] += dust; }
                    }
                }
            }
        }
    }

    let signer_info = ctx.accounts.signer.to_account_info();
    let creator_depositor_key = creator.key();
    let mut creator_bet_payout: u64 = 0;

    for i in 0..num_positions {
        let pos_info = &ctx.remaining_accounts[i * 2];
        let dep_info = &ctx.remaining_accounts[i * 2 + 1];

        let position = {
            let data = pos_info.try_borrow_data()?;
            if data.len() < 8 || data[..8] == [0u8; 8] { continue; }
            match Position::try_deserialize(&mut data.as_ref()) {
                Ok(p) => p,
                Err(_) => continue,
            }
        };

        require!(position.market == market.key(), PithyQuip::WrongMarket);
        if position.total_capital == 0 { continue; }

        let (expected_dep, _) = Pubkey::find_program_address(&[position.user.as_ref()], &crate::ID);
        if dep_info.key() != expected_dep {
            msg!("Depositor mismatch for {}", position.user);
            continue;
        }

        // Unrevealed = forfeit (weight 0, no payout)
        let is_forfeit = position.revealed_confidence == 0 && !market.cancelled
            && market.total_winner_capital_revealed > 0;

        let payout = if is_forfeit {
            0u64
        } else if market.cancelled || market.total_winner_capital_revealed == 0 {
            if market.jury_fee_pool > 0 {
                // Jury force majeure: return capital pro-rata, minus jury fees
                let remaining = (market.total_capital as u128)
                    .saturating_sub(market.jury_fee_pool as u128);
                if market.total_capital > 0 {
                    ((position.total_capital as u128)
                        .saturating_mul(remaining)
                        / (market.total_capital as u128)) as u64
                } else { 0 }
            } else {
                // Normal cancellation: full refund + pro-rata fee share
                let fee_refund = if market.total_capital > 0 {
                    ((market.fees_collected as u128)
                        .saturating_mul(position.total_capital as u128)
                        / (market.total_capital as u128)) as u64
                } else { 0 };
                position.total_capital.saturating_add(fee_refund)
            }
        } else {
            let is_winner = market.winning_sides.contains(&position.outcome);
            let oi = position.outcome as usize;
            if is_winner {
                // Per-outcome pot: use sub_pot and per-outcome weight
                let side_weight = if oi < market.winner_weight_per_outcome.len() {
                    market.winner_weight_per_outcome[oi]
                } else { 0 };
                let side_pot = if oi < sub_pot.len() { sub_pot[oi] } else { 0 };
                if side_weight > 0 && side_pot > 0 {
                    let share = (position.weight as u128)
                        .saturating_mul(side_pot) / side_weight;
                    position.total_capital.saturating_add(share as u64)
                } else {
                    position.total_capital
                }
            } else {
                if total_loser_weight > 0 {
                    (((position.weight as u128).saturating_mul(loser_pot)) / total_loser_weight) as u64
                } else { 0 }
            }
        };

        if payout > 0 {
            // If this depositor is the same account as creator_depositor
            // (named Anchor account), accumulate payout for the finalization
            // step below. Writing through remaining_accounts AND letting
            // Anchor auto-serialize the named account causes a conflict.
            if dep_info.key() == creator_depositor_key {
                creator_bet_payout += payout;
                bank.total_deposits += payout;
            } else {
                let mut dep_data = dep_info.try_borrow_mut_data()?;
                let mut depositor = match Depositor::try_deserialize(&mut dep_data.as_ref()) {
                    Ok(d) => d,
                    Err(_) => continue,
                };
                depositor.pool_deposit(bank, payout, right_now);
                depositor.try_serialize(&mut dep_data.as_mut())?;
            }
        }

        // Close position PDA: zero data + transfer rent to signer (keeper).
        // Position rent goes to the keeper who processes the batch — standard
        // Solana pattern. Creator receives their bond via the sol_vault CPI
        // at finalization. This separation ensures NO account has both direct
        // lamport writes and CPI modifications in the same instruction, which
        // avoids the runtime "sum of account balances … do not match" check.
        {
            let position_lamports = pos_info.lamports();
            **pos_info.try_borrow_mut_lamports()? = 0;
            **signer_info.try_borrow_mut_lamports()? = signer_info
                .lamports()
                .checked_add(position_lamports)
                .ok_or(PithyQuip::Overflow)?;

            let mut data = pos_info.try_borrow_mut_data()?;
            for byte in data.iter_mut() {
                *byte = 0;
            }
        }
        market.positions_processed += 1;
    }

    // Finalize when all positions processed
    if market.positions_processed >= market.positions_total {
        // ── Beneficiary fee distribution ──
        // winning_splits controls how fees_collected are split among
        // beneficiary addresses on winning sides. Remaining goes to creator.
        let mut beneficiary_distributed: u64 = 0;
        if !market.cancelled && !market.beneficiaries.is_empty()
            && !market.winning_sides.is_empty() && market.fees_collected > 0
        {
            let total_fees = market.fees_collected;
            let total_split: u128 = if market.winning_splits.is_empty() {
                // Equal split among winning sides that have beneficiaries
                market.winning_sides.iter()
                    .filter(|&&ws| {
                        let i = ws as usize;
                        i < market.beneficiaries.len() && market.beneficiaries[i].is_some()
                    })
                    .count() as u128 * 10_000
            } else {
                market.winning_sides.iter()
                    .filter_map(|&ws| market.winning_splits.get(ws as usize))
                    .map(|&s| s as u128)
                    .sum()
            };

            if total_split > 0 {
                let mut ben_acc_idx = 2 * num_positions; // beneficiary depositors start after position pairs
                for &ws in &market.winning_sides {
                    let idx = ws as usize;
                    if idx >= market.beneficiaries.len() { continue; }
                    let beneficiary_pubkey = match market.beneficiaries[idx] {
                        Some(pk) => pk,
                        None => continue,
                    };

                    let split_bps = if market.winning_splits.is_empty() {
                        10_000u128 // will be divided by total_split which = count * 10_000
                    } else {
                        market.winning_splits.get(idx).copied().unwrap_or(0) as u128
                    };
                    if split_bps == 0 { continue; }

                    let fee_share = ((total_fees as u128) * split_bps / total_split) as u64;
                    if fee_share == 0 || ben_acc_idx >= ctx.remaining_accounts.len() {
                        ben_acc_idx += 1;
                        continue;
                    }

                    let ben_dep_info = &ctx.remaining_accounts[ben_acc_idx];
                    ben_acc_idx += 1;

                    // Validate beneficiary depositor PDA
                    let (expected_ben_dep, _) = Pubkey::find_program_address(
                        &[beneficiary_pubkey.as_ref()], &crate::ID);
                    if ben_dep_info.key() != expected_ben_dep {
                        msg!("Beneficiary depositor mismatch for side {}", idx);
                        continue;
                    }

                    if let Ok(mut ben_data) = ben_dep_info.try_borrow_mut_data() {
                        if let Ok(mut ben_dep) = Depositor::try_deserialize(&mut ben_data.as_ref()) {
                            ben_dep.pool_deposit(bank, fee_share, right_now);
                            beneficiary_distributed += fee_share;
                            let _ = ben_dep.try_serialize(&mut ben_data.as_mut());
                        }
                    }
                }
            }
        }

        // Creator gets: remaining fees + creator_fee (from loser pot) + their bet payout
        let remaining_fees = market.fees_collected.saturating_sub(beneficiary_distributed);
        let total_creator_payout = remaining_fees
            .saturating_add(creator_fee_amt as u64)
            .saturating_add(creator_bet_payout);

        if total_creator_payout > 0 && !market.cancelled {
            // deposited_quid += total_creator_payout but total_deposits += only
            // fees_plus_creator_fee because creator_bet_payout was already counted
            // in bank.total_deposits inside the per-position loop above.
            creator.accrue(bank, right_now);
            creator.deposited_quid += total_creator_payout;
            let fees_plus_creator_fee = remaining_fees.saturating_add(creator_fee_amt as u64);
            bank.total_deposits += fees_plus_creator_fee;
            market.fees_collected = 0;
        } else if creator_bet_payout > 0 {
            // bank.total_deposits already updated in per-position loop
            creator.accrue(bank, right_now);
            creator.deposited_quid += creator_bet_payout;
        }

        // Reclaim SOL bond → creator
        let sol_vault = &ctx.accounts.sol_vault;
        let remaining_sol = sol_vault.lamports();
        if remaining_sol > 0 {
            let market_id_bytes = market.market_id.to_le_bytes();
            let signer_seeds: &[&[&[u8]]] = &[
                &[b"sol_vault", &market_id_bytes[..6],
                  &[market.sol_vault_bump]],
            ];

            anchor_lang::system_program::transfer(
                CpiContext::new_with_signer(
                    ctx.accounts.system_program.to_account_info(),
                    anchor_lang::system_program::Transfer {
                        from: sol_vault.to_account_info(),
                        to: ctx.accounts.creator.to_account_info(),
                    },
                    signer_seeds,
                ),
                remaining_sol,
            )?;
        }
        market.creator_bond_lamports = 0;
        market.payouts_complete = true;
    }
    Ok(())
}
