
use anchor_spl::associated_token::AssociatedToken;
use anchor_spl::token_interface::{ Mint,
    TokenAccount, TokenInterface
};
use anchor_lang::solana_program::{
    program::invoke_signed,
    instruction::AccountMeta,
    system_instruction
};

use crate::stay::*;
use crate::etc::{ get_account,
    PithyQuip, fetch_price,
    fetch_multiple_prices,
    TickerRisk, fee_bps
};
use anchor_lang::prelude::*;
// The SOL* subsystem and the protocol config now live beside the
// instructions that configure them.
use crate::entra::{transfer_from_vaults, ProgramConfig, SOL_POOL_SEED, NativeLeg,
    SolStarLegs, unpark_for_withdrawal, credited_lamports, collar_adjusted_usd};


/// Replace this ticker's contribution to the pool reserve with one computed on
/// its NET book. Called after `record_activity` has moved `net_exposure`, and
/// it is the only writer of `max_liability` outside the per-pod band update —
/// so the reserve reflects what the pool is actually short.
fn reconcile_ticker_reserve(risk: &mut TickerRisk, bank: &mut Depository) {
    let net = risk.actuary.get_net().unsigned_abs();
    let target = crate::etc::ticker_reserve_dollars(net, &risk.actuary);
    bank.max_liability = bank.max_liability
        .saturating_sub(risk.reserved)
        .saturating_add(target);
    risk.reserved = target;
}

#[derive(Accounts)]
#[instruction(ticker: String)]
pub struct Liquidate<'info> {
    /// CHECK: raw account only to validate ownership
    pub liquidating: AccountInfo<'info>,

    #[account(mut)]
    pub liquidator: Signer<'info>,

    /// Whitelisted unconditionally — see the note on `Stockup::mint`.
    #[account(constraint = config.registered_mints.contains(&mint.key())
            @ PithyQuip::InvalidMint)]
    pub mint: Box<InterfaceAccount<'info, Mint>>,

    #[account(seeds = [b"program_config"], bump = config.bump)]
    pub config: Box<Account<'info, ProgramConfig>>,

    #[account(mut, seeds = [b"depository"], bump)]
    pub bank: Box<Account<'info, Depository>>,

    #[account(mut, seeds = [b"vault", mint.key().as_ref()], bump)]
    pub bank_token_account: Box<InterfaceAccount<'info, TokenAccount>>,

    #[account(mut, seeds = [liquidating.key().as_ref()], bump)]
    pub customer_account: Box<Account<'info, Depositor>>,

    #[account(init_if_needed, payer = liquidator,
        space = 8 + Depositor::INIT_SPACE,
        seeds = [liquidator.key().as_ref()], bump)]
    pub liquidator_depositor: Box<Account<'info, Depositor>>,

    #[account(mut, seeds = [b"risk",
    ticker.as_bytes()], bump = ticker_risk.bump)]
    pub ticker_risk: Box<Account<'info, TickerRisk>>,

    pub token_program: Interface<'info, TokenInterface>,
    pub associated_token_program: Program<'info, AssociatedToken>,
    pub system_program: Program<'info, System>,
}

// "It's like inch by inch...step by step...closin' in on your position
//  in small doses...when things have gotten closer to the sun," she said,
// "don't think I'm pushing you away as ⚡️ strikes...court lights get dim"
pub fn amortise(ctx: Context<Liquidate>, ticker: String) -> Result<()> {
    let Banks = &mut ctx.accounts.bank;
    // "Me and my money attached emotionally
    // I get to clutchin' if you get too close to me"
    let customer = &mut ctx.accounts.customer_account;
    let risk = &mut ctx.accounts.ticker_risk;
    require_keys_eq!(customer.owner,
        ctx.accounts.liquidating.key(),
        PithyQuip::InvalidUser);

    let clock = Clock::get()?;
    let slot = clock.slot as i64;
    let t: &str = ticker.as_str();
    let right_now = clock.unix_timestamp;

    let key: &str = get_account(t).ok_or(PithyQuip::UnknownSymbol)?;
    let first = ctx.remaining_accounts.first().ok_or(PithyQuip::NoPrice)?;
    let first_key = first.key.to_string();
    if first_key != key {
        return Err(PithyQuip::UnknownSymbol.into());
    }
    let adjusted_price = fetch_price(t, Some(first))?;
    // Integrate the interval at the rate that ran over it, before the new
    // observation changes that rate.
    risk.actuary.accrue_premium_index(right_now, Banks.utilisation_bps());
    risk.actuary.update_price(adjusted_price as i64, slot);
    risk.actuary.check_twap_deviation(adjusted_price as i64)?;
    let mut time_delta = right_now - customer.last_updated;
    customer.deposit_seconds += (customer.deposited_quid as u128)
                                           * (time_delta as u128);

    time_delta = right_now - Banks.last_updated;
    Banks.total_deposit_seconds += (Banks.total_deposits as u128)
                                           * (time_delta as u128);
    Banks.last_updated = right_now;
    let (mut delta, mut interest) = customer.repo(t, 0,
    adjusted_price, right_now, slot, &risk.actuary, Banks)?;
    require!(delta != 0, PithyQuip::NotUndercollateralised);

    Banks.yield_pool += interest;
    interest = (delta.abs() as u64 / 250) as u64;
    let pos = customer.balances.iter().find(|p|
        std::str::from_utf8(&p.ticker).unwrap()
                  .trim_end_matches('\0') == t);

    let (prior_exposure, _leverage) = if let Some(p) = pos {
        let l = if p.pledged > 0 {
            ((p.exposure.abs() as u128) *
               (adjusted_price as u128) * 100 /
                    (p.pledged as u128)) as i64
        } else { 100 };
        (p.exposure, l)
    } else { (0, 100) };
    if delta < 0 { delta *= -1;
        delta -= interest as i64;
        // ^ pay liquidator's commission...
         // Take profit on behalf of all the
         // depositors, at the expense of one
        Banks.yield_pool += delta as u64;
        risk.actuary.record_activity(prior_exposure, -delta,
            slot, delta, Banks.total_deposits as i64);
        reconcile_ticker_reserve(risk, Banks);
    } else if delta > 0 {
        // Position was saved from liquidation
        // before we try to deduct from depository
        // attempt to salvage amount from depositor
        let prices = fetch_multiple_prices(&customer.balances,
                                    ctx.remaining_accounts)?;

        let remainder = customer.renege(None, -delta as i64,
                          Some(&prices), right_now)? as i64;

        // `renege` pulled `delta - remainder` out of this depositor's other
        // positions; `remainder` is what it could not reach. The recovered
        // part moves from `pledged`, which the pool does not count, into
        // `deposited_quid`, which it does — so the pool's total has to rise
        // with it. It was falling by `remainder` instead, which is neither
        // side of that move: the two ledgers drifted by `delta` every time
        // this branch fired.
        let recovered = (delta - remainder) as u64;
        customer.deposited_quid += recovered;
        Banks.total_deposits += recovered;

        // What could not be recovered is a shortfall the pool absorbs. Take
        // it from earnings first, and only from principal once those are
        // exhausted — losses should land on what was made before what was
        // deposited.
        let shortfall = remainder as u64;
        let from_yield = shortfall.min(Banks.yield_pool);
        Banks.yield_pool -= from_yield;
        Banks.total_deposits = Banks.total_deposits
            .saturating_sub(shortfall - from_yield);
        risk.actuary.record_activity(prior_exposure, delta,
            slot, delta, Banks.total_deposits as i64);
        reconcile_ticker_reserve(risk, Banks);
    }
    // Being amortised is proof this account's risk was mispriced, so it
    // cancels the rebate. Without this a trader could bank a strong RAROC,
    // ride it into a liquidation, and keep paying less.
    customer.reset_raroc();

    let liquidator_dep = &mut ctx.accounts.liquidator_depositor;
    if liquidator_dep.owner == Pubkey::default() {
        liquidator_dep.owner = ctx.accounts.liquidator.key();
        liquidator_dep.last_updated = right_now;
    } else { // Update deposit_seconds before adding comission funds
        let liq_time_delta = right_now - liquidator_dep.last_updated;
        liquidator_dep.deposit_seconds += (liquidator_dep.deposited_quid as u128)
                                                       * (liq_time_delta as u128);
        liquidator_dep.last_updated = right_now;
    }   // The commission came out of the borrower's pledge, which the pool
        // does not count, and lands in a depositor balance, which it does. So
        // the pool's total has to rise with it — crediting one side only made
        // the sum of balances exceed the total they are measured against.
        liquidator_dep.deposited_quid += interest;
        ctx.accounts.bank.total_deposits =
            ctx.accounts.bank.total_deposits.saturating_add(interest);
    Ok(())
}

// withdrawing is either what we liquidate (TP),
// or minting what is liable to get liquidated

#[derive(Accounts)]
#[instruction(amount: i64, 
ticker: String, exposure: bool)]
pub struct Withdraw<'info> {
    #[account(mut)]
    pub signer: Signer<'info>,

    /// Whitelisted unconditionally — see the note on `Stockup::mint`.
    #[account(constraint = config.registered_mints.contains(&mint.key())
            @ PithyQuip::InvalidMint)]
    pub mint: Box<InterfaceAccount<'info, Mint>>,

    #[account(seeds = [b"program_config"], bump = config.bump)]
    pub config: Box<Account<'info, ProgramConfig>>,

    #[account(mut, seeds = [b"depository"], bump)]
    pub bank: Box<Account<'info, Depository>>,

    #[account(mut, seeds = [b"vault", mint.key().as_ref()], bump)]
    pub bank_token_account: Box<InterfaceAccount<'info, TokenAccount>>,

    #[account(mut, seeds = [signer.key().as_ref()], bump)]
    pub customer_account: Box<Account<'info, Depositor>>,

    /// Destination of an SPL withdrawal. Created on demand: a depositor who
    /// arrived with native SOL has never needed a token account for this mint,
    /// and requiring them to make one first is an enrollment step in all but
    /// name. The address is the canonical ATA either way, so creating it here
    /// cannot be pointed anywhere else.
    #[account(init_if_needed, payer = signer,
        associated_token::mint = mint,
        associated_token::authority = signer,
        associated_token::token_program = token_program,
    )]
    pub customer_token_account: Box<InterfaceAccount<'info, TokenAccount>>,

    /// Native leg: the lamport pool. Present ⇒ this is a SOL withdrawal and
    /// the SPL accounts above are ignored.
    /// CHECK: PDA verified by seeds.
    #[account(mut, seeds = [SOL_POOL_SEED], bump)]
    pub sol_pool: Option<AccountInfo<'info>>,

    #[account(mut, seeds = [b"risk", ticker.as_bytes()], bump = ticker_risk.bump)]
    pub ticker_risk: Option<Box<Account<'info, TickerRisk>>>,

    pub token_program: Interface<'info, TokenInterface>,
    pub associated_token_program: Program<'info, AssociatedToken>,
    pub system_program: Program<'info, System>,
}

pub fn handle_out<'info>(ctx: Context<'_, '_,
    'info, 'info, Withdraw<'info>>, mut amount: i64,
    ticker: String, exposure: bool) -> Result<()> {
    // `sol_pool` with ticker "SOL" withdraws lamports and nothing else, the
    // mirror of how `handle_in` selects its native leg. With an empty ticker
    // it means something different: pay this pool withdrawal from the SOL as
    // well as the vaults, pro rata, because SOL backs the claim exactly as
    // they do. Supplying it is how a caller says the pool's lamports are on
    // the table; leaving it out limits the payout to the vaults.
    //
    // The native leg alone accepts 0, meaning all of it: a depositor cannot
    // know their own accrued carry ahead of time, and a full exit is exactly
    // the case where guessing the figure strands lamports behind.
    if ctx.accounts.sol_pool.is_some() && ticker == "SOL" {
        return withdraw_native(ctx, amount.unsigned_abs());
    }
    require!(amount != 0, PithyQuip::InvalidAmount);

    let Banks = &mut ctx.accounts.bank;
    let customer = &mut ctx.accounts.customer_account;
    require_keys_eq!(customer.owner,
        ctx.accounts.signer.key(),
        PithyQuip::InvalidUser);

    let clock = Clock::get()?;
    let slot = clock.slot as i64;
    let right_now = clock.unix_timestamp;

    // time-weighted metrics for interest rate calculation
    let mut time_delta = right_now - Banks.last_updated;
    Banks.total_deposit_seconds += (time_delta as u128) *
    (Banks.total_deposits as u128);
    Banks.last_updated = right_now;
    let mut amt: u64 = 0;
    if ticker.is_empty() { 
    // withdrawal of $ deposits...
        // returns your pro-rata share of the pool, plus your
        // accrued yield, net of any losses for honoring TPs
        require!(amount < 0, PithyQuip::InvalidAmount);
        // Track where vault triplets start in remaining_accounts
        let mut vault_offset: usize = 0;
        if exposure { // first empty credit accounts,
        // prior to withdrawing from Depository...
            let prices = fetch_multiple_prices(&customer.balances,
                ctx.remaining_accounts)?; amt = amount.abs() as u64;
            vault_offset = customer.balances.len();
            // amount gets passed into renege as a negative number,
            // but if a remainder is returned it will be positive
            amount = customer.renege(None, amount as i64,
                       Some(&prices), right_now)? as i64;

            amt -= amount as u64;
            // used to keep track of how much we know
            // (so far) that we'll be transferring...
        } // whether we entered exposure's if clause or not (amount gets reused in there)
        if amount.abs() > 0 { // if there's a remainder (returned by renege), or otherwise:
            time_delta = right_now - customer.last_updated;
            customer.deposit_seconds += (time_delta as u128) * (customer.deposited_quid as u128);
            // Principal comes back at par; only the earnings are weighted by
            // tenure. Weighting the whole pool by tenure is what let a long
            // depositor's claim exceed what they put in, with the difference
            // coming out of later depositors' principal, and what made the
            // shares fail to sum to the pool at all.
            //
            // Time-weighting still does the job it was there for: someone who
            // arrives just before a large liquidation has almost no
            // deposit-seconds, so their share of that windfall is almost
            // nothing, however large it is. They get their principal back and
            // no more, which is exactly what a just-in-time depositor should
            // get. What they can no longer do is arrive late and be paid out
            // of somebody else's stake.
            let earned = if Banks.total_deposit_seconds > 0 && Banks.yield_pool > 0 {
                customer.deposit_seconds
                    .saturating_mul(Banks.yield_pool as u128)
                    .checked_div(Banks.total_deposit_seconds)
                    .unwrap_or(0).min(Banks.yield_pool as u128) as u64
            } else { 0 };

            // Earn on the part of your own stake that is backing somebody
            // else, and on no more than that. A borrower who has drawn against
            // their whole deposit is net a taker of risk and earns nothing; a
            // depositor who has drawn against a tenth of it still earns on the
            // other nine, which is genuinely at work for the pool.
            //
            // This used to divide by `total_drawn` — a borrower's share of all
            // borrowing rather than of their own capital. The sole borrower in
            // a pool therefore had a share of one and earned nothing at all,
            // however large their deposit and however small their draw, purely
            // because nobody else happened to be borrowing. That made being
            // both depositor and borrower irrational, which is exactly the
            // position a conditional-exposure product puts somebody in.
            let utilisation_discount = if customer.deposited_quid > 0 {
                let committed = (customer.drawn as u128 * 10_000
                    / customer.deposited_quid as u128).min(10_000) as u64;
                10_000u64.saturating_sub(committed)
            } else { 0 };
            let earned = earned.saturating_mul(utilisation_discount) / 10_000;
            let max_value = customer.deposited_quid.saturating_add(earned);

            // Withheld: the pool cannot pay out what it is holding against
            // open exposure. `max_liability` is the reserve against every
            // ticker's net, and until now it was a number that restrained
            // nothing — `withdrawable()` existed and was never called. That
            // left the settlement-timing gap open: a gain is credited when a
            // position closes, but the offsetting loss is collected over
            // several liquidation calls, and in between this path would pay
            // the winner out of principal that had not been collected yet.
            //
            // No premium closes that, because it is not a mispricing; it is a
            // lag. Ostium funds a junior tranche to bridge it. The same
            // protection is available here without raising any capital, by
            // withholding the amount already reserved rather than by holding
            // a separate pot in front of it — the reserve was always the right
            // number, it just had to bind.
            // Each depositor's own share of the free capacity, not the whole
            // of it. `withdrawable()` is pool-wide — total plus earnings, less
            // what is reserved against borrowers — and capping a payout by it
            // directly let the first to ask take all of it, leaving the next
            // depositor with the same claim holding nothing. That is a race,
            // and a race is a run: the rational move becomes withdrawing
            // before anyone else does.
            //
            // Prorating it makes the constraint a rule instead. When the pool
            // can release 60% of what it owes, everybody can take 60% of their
            // own claim, whenever they ask and in any order. Nobody is blocked
            // by somebody else's earlier exit, and there is nothing to be
            // gained by being first.
            //
            // The remainder is not lost, only committed: it is backing
            // positions that are still open, and it frees as those close.
            let backing = Banks.total_deposits.saturating_add(Banks.yield_pool);
            let free = Banks.withdrawable();
            let my_share = if backing > 0 {
                ((max_value as u128).saturating_mul(free as u128)
                    / backing as u128).min(u64::MAX as u128) as u64
            } else { 0 };

            let value = max_value.min(amount.abs() as u64).min(my_share);
            amt += value;
            // Spend principal first, then earnings, so the two ledgers each
            // fall by what actually left them.
            let from_principal = value.min(customer.deposited_quid);
            Banks.total_deposits -= from_principal;
            Banks.yield_pool = Banks.yield_pool
                .saturating_sub(value.saturating_sub(from_principal));

            let old_deposited = customer.deposited_quid;
            customer.deposited_quid -= customer.deposited_quid.min(value);

            if old_deposited > 0 && value > 0 {
                customer.adjust_deposit_seconds(value, right_now);
            }
            customer.last_updated = right_now;
        }
        // Pro-rata across primary vault + alternate vaults (USD*, etc.)
        // remaining_accounts after price feeds: [alt_mint, alt_vault, alt_user_ata] triplets
        let vault_accounts = if vault_offset < ctx.remaining_accounts.len() {
            &ctx.remaining_accounts[vault_offset..]
        } else { &[] };
        // in vault_accounts. Empty slice = no alt vaults (primary only).
        // `amt` is accounting units; transfer_from_vaults normalises each
        // vault and converts every payout back to that mint's precision.
        // The pool's lamports join the split when they are offered, marked
        // the way they were credited so a share of the value is a share of
        // the lamports.
        let native = match (&ctx.accounts.sol_pool, ctx.bumps.sol_pool,
                            ctx.accounts.ticker_risk.as_ref()) {
            (Some(pool), Some(bump), Some(risk)) if Banks.sol_lamports > 0 => {
                let price = fetch_price("SOL", ctx.remaining_accounts.first())?;
                Some(NativeLeg {
                    sol_pool: pool.clone(),
                    recipient: ctx.accounts.signer.to_account_info(),
                    system_program: ctx.accounts.system_program.to_account_info(),
                    bump,
                    lamports: Banks.sol_lamports,
                    value: crate::entra::collar_adjusted_usd(
                        Banks.sol_lamports, price, &risk.actuary),
                    paid: core::cell::Cell::new(0),
                })
            }
            _ => None,
        };

        let paid = transfer_from_vaults(&ctx.accounts.bank_token_account,
            &ctx.accounts.mint,
            &ctx.accounts.customer_token_account,
            ctx.bumps.bank_token_account, vault_accounts,
            &ctx.accounts.token_program, ctx.program_id,
            &ctx.accounts.config.registered_mints, amt,
            native.as_ref())?;

        // Whatever left as lamports leaves the pool's SOL books with it,
        // marked the same way it was valued going in.
        let _ = paid;
        if let Some(leg) = native.as_ref() {
            let out = leg.paid.get();
            if out > 0 {
                let value_out = ((leg.value as u128).saturating_mul(out as u128)
                    / leg.lamports.max(1) as u128) as u64;
                Banks.sol_lamports = Banks.sol_lamports.saturating_sub(out);
                Banks.sol_usd_contrib = Banks.sol_usd_contrib
                    .saturating_sub(value_out.min(Banks.sol_usd_contrib));
            }
        }
    } else { // < ticker was not ""
        let t: &str = ticker.as_str();
        if !exposure { // < withdraw pledged from specific ticker (no exposure change)
            require!(amount < 0, PithyQuip::InvalidAmount);
            customer.renege(Some(t), amount, None, right_now)?;
            // Pro rata across the vaults, as everywhere else: `renege` worked
            // in accounting units and the claim is asset-agnostic, so a single
            // vault could refuse a withdrawal the pool as a whole can cover.
            let pledged_vaults = if !ctx.remaining_accounts.is_empty() {
                &ctx.remaining_accounts[..]
            } else { &[] };
            transfer_from_vaults(&ctx.accounts.bank_token_account,
                &ctx.accounts.mint,
                &ctx.accounts.customer_token_account,
                ctx.bumps.bank_token_account, pledged_vaults,
                &ctx.accounts.token_program, ctx.program_id,
                &ctx.accounts.config.registered_mints,
                (-amount) as u64, None)?;
        } else {
            let risk = ctx.accounts.ticker_risk.as_mut().ok_or(PithyQuip::UnknownSymbol)?;
            let key: &str = get_account(t).ok_or(PithyQuip::UnknownSymbol)?;
            let first: &AccountInfo = &ctx.remaining_accounts[0];
            let first_key = first.key.to_string();
            if first_key != key {
                return Err(PithyQuip::UnknownSymbol.into());
            }
            let adjusted_price = fetch_price(t, Some(first))?;
            risk.actuary.accrue_premium_index(right_now, Banks.utilisation_bps());
            risk.actuary.update_price(adjusted_price as i64, slot);
            risk.actuary.check_twap_deviation(adjusted_price as i64)?;
            let pos = customer.balances.iter().find(|p|
                std::str::from_utf8(&p.ticker).unwrap()
                .trim_end_matches('\0') == t)
                .ok_or(PithyQuip::DepositFirst)?;

            let prior_exposure = pos.exposure; let pre_pledged = pos.pledged;
            let leverage = if pos.pledged > 0 { (pos.exposure.abs() as u64
                              * adjusted_price * 100 / pos.pledged) as i64
            } else { 100 };
            // Same barrier distance the carry prices against, so the entry
            // prepayment and the running charge cannot disagree.
            let exposure_value = (prior_exposure.unsigned_abs() as u128)
                .saturating_mul(adjusted_price as u128)
                .min(u64::MAX as u128) as u64;
            let collar_now = crate::etc::collar_bps(leverage, &risk.actuary);
            let barrier = collar_notional(exposure_value, pre_pledged)
                .saturating_add(collar_notional(exposure_value, pre_pledged)
                    .saturating_mul(collar_now as u64) / 10_000);
            let distance_bps = if exposure_value > 0 {
                ((barrier.saturating_sub(exposure_value) as u128)
                    .saturating_mul(10_000) / exposure_value as u128)
                    .min(i64::MAX as u128) as i64
            } else { 10_000 };
            let fee = fee_bps(Banks.utilisation_bps(), prior_exposure,
                                amount, &risk.actuary, leverage, distance_bps);
            // Pre-call snapshot of deposited_quid. Combined with pre_pledged
            // and post-call reads, lets clutch compute total_deposits delta
            // directly from vault invariant: dq + Σpledged + T = vault
            // (token-account balance). For any in-program mutation, T must
            // change to absorb the dq + pledged delta plus any wallet payout
            // that drops the vault. This makes clutch a thin invariant-preserving
            // shell over repo's pod/dq mutations.
            let pre_dq = customer.deposited_quid;
            let (delta, interest) = customer.repo(t, amount,
            adjusted_price, right_now, slot, &risk.actuary, Banks)?;

            // Post-call snapshot. Position may have been zeroed out by all-in TP;
            // treat absent pod as exposure=0, pledged=0.
            let (post_pledged, post_exposure) = customer.balances.iter().find(|p|
                std::str::from_utf8(&p.ticker).unwrap().trim_end_matches('\0') == t)
                .map_or((0u64, 0i64), |p| (p.pledged, p.exposure));

            let dq_delta_repo: i128 = (customer.deposited_quid as i128)
                                        .saturating_sub(pre_dq as i128);

            let pledged_delta: i128 = (post_pledged as i128)
                        .saturating_sub(pre_pledged as i128);

            // Dispatch by delta sign and exposure motion. For T_delta:
            //   wallet TP:  T_delta = -(dq_delta + pledged_delta) - payout
            //   capitalize: credit dq first, then T_delta = -(dq_delta_total + pledged_delta)
            //   else:       T_delta = -(dq_delta + pledged_delta)
            // Signed math (i128) — partial TP profit yields negative T_delta;
            // auto-protect (with fee retention) yields positive T_delta.
            let signed_t_delta: i128 = if delta < 0 {
                // All-in TP wallet: interest = total payout, fee carved.
                let fee_amount = (interest as u128 * fee as u128 / 10_000) as u64;
                let payout = interest.saturating_sub(fee_amount);

                // Sourced across every vault, not out of whichever mint the
                // caller happened to name. `repo` returns this as one figure
                // but it is two things: the trader's own pledge coming back,
                // and profit that comes from the pool. Paying either from a
                // single vault meant a take-profit could fail for want of
                // liquidity in one asset while the others sat full — the pool
                // solvent, the payout impossible. A claim here is
                // asset-agnostic exactly as it is on a pool withdrawal, so it
                // is paid the same way: pro rata across what backs it, each
                // vault converted back to its own precision.
                //
                // Alt vaults ride behind the price feed, in the same
                // [mint, vault, user_ata] triplets a pool withdrawal uses.
                let tp_vaults = if ctx.remaining_accounts.len() > 1 {
                    &ctx.remaining_accounts[1..]
                } else { &[] };
                transfer_from_vaults(&ctx.accounts.bank_token_account,
                    &ctx.accounts.mint,
                    &ctx.accounts.customer_token_account,
                    ctx.bumps.bank_token_account, tp_vaults,
                    &ctx.accounts.token_program, ctx.program_id,
                    &ctx.accounts.config.registered_mints, payout, None)?;

                -(dq_delta_repo.saturating_add(pledged_delta)).saturating_sub(payout as i128)
            } 
            else if interest > 0 && post_exposure.abs() < prior_exposure.abs() {
                // Partial TP capitalize. Credit user_credit to deposited_quid;
                // T_delta absorbs the resulting invariant gap (negative for
                // profit, positive for loss/AI absorption). No fee on partial.
                // Note: we route here whenever interest > 0 AND exposure shrank,
                // regardless of delta sign. The dust case (highly leveraged
                // position closing tiny slice) yields delta_signal = 0 due to
                // integer rounding on pledged_reduce, but user_credit is still
                // owed and must be capitalized — the delta value is a routing
                // hint, not a gate. Only auto-protect/drain paths reach the
                // `else` branch (they grow exposure, not shrink it).
                customer.deposited_quid = customer.deposited_quid.saturating_add(interest);
                let dq_delta_total: i128 = dq_delta_repo.saturating_add(interest as i128);
                
                time_delta = right_now - customer.last_updated; 
                customer.last_updated = right_now; 
                
                customer.deposit_seconds = customer.deposit_seconds.saturating_add(
                (time_delta as u128).saturating_mul(customer.deposited_quid as u128));
                
                -(dq_delta_total.saturating_add(pledged_delta))
            } else {
                // Auto-protect (over-profit / over-loss / Adding-exp drain) or
                // pure-exposure paths (under-exposed / short-ITM) where dq drops
                // but pledged stays. T_delta picks up fee + AI for protect cases
                // and AI alone for pure-exposure cases.
                if delta > 0 {
                    time_delta = right_now - customer.last_updated;
                    customer.last_updated = right_now;
                    customer.deposit_seconds = customer.deposit_seconds.saturating_add(
                                    (time_delta as u128).saturating_mul(pre_dq as u128));
                }
                -(dq_delta_repo.saturating_add(pledged_delta))
            };
            // A borrower's profit is paid out of the pool, so it is a loss to
            // depositors — and it used to land straight on `total_deposits`,
            // an aggregate that no individual claim tracks. Every depositor
            // still claimed par against a pool that held less, which makes
            // withdrawing before a large take-profit and returning afterwards
            // strictly profitable: the leaver keeps par and the stayers absorb
            // it. Resetting the tenure clock is no deterrent, because tenure
            // governs earnings and what is being dodged is principal.
            //
            // Premiums are what the pool collected for carrying exactly this
            // risk, so they pay for it first. Only a loss beyond everything
            // earned reaches deposits, and that is genuine impairment rather
            // than the ordinary cost of writing the other side of a trade.
            if signed_t_delta >= 0 {
                Banks.yield_pool = Banks.yield_pool
                    .saturating_add(signed_t_delta as u64);
            } else {
                let loss = (-signed_t_delta) as u64;
                let from_yield = loss.min(Banks.yield_pool);
                Banks.yield_pool -= from_yield;
                Banks.total_deposits = Banks.total_deposits
                    .saturating_sub(loss - from_yield);
            }
            // `amount` is in asset units here; the risk state is dollars.
            let value_delta = (amount as i128)
                .saturating_mul(adjusted_price as i128)
                .clamp(i64::MIN as i128, i64::MAX as i128) as i64;
            risk.actuary.record_activity(prior_exposure, value_delta,
                slot, value_delta.abs(), Banks.total_deposits as i64);
            reconcile_ticker_reserve(risk, Banks);
        }
    } Ok(())
}

/// Native-SOL branch of `handle_out`. Kept as its own function for the same
/// reason the SPL branch is inline: one instruction, two disjoint account sets.
fn withdraw_native<'info>(ctx: Context<'_, '_, 'info, 'info, Withdraw<'info>>,
    mut lamports: u64) -> Result<()> {
    let sol_pool = ctx.accounts.sol_pool.as_ref().unwrap().clone();
    if lamports == 0 { lamports = ctx.accounts.customer_account.deposited_lamports; }
    require!(lamports > 0, PithyQuip::InvalidAmount);
    require!(lamports <= ctx.accounts.customer_account.deposited_lamports,
            PithyQuip::InsufficientFunds);

    let now = Clock::get()?.unix_timestamp;
    let slot = Clock::get()?.slot as i64;
    let pyth = ctx.remaining_accounts.first();
    let sol_price = crate::etc::fetch_price("SOL", pyth)?;
    let risk = ctx.accounts.ticker_risk.as_mut().ok_or(PithyQuip::UnknownSymbol)?;
    risk.actuary.accrue_premium_index(now, ctx.accounts.bank.utilisation_bps());
    risk.actuary.update_price(sol_price as i64, slot);

    // Anything the hot buffer cannot cover comes out of the parked tranche,
    // and the round trip is charged to the caller who forced it rather than
    // socialised — see `unpark_for_withdrawal`. Without the Kestrel accounts
    // the withdrawal is limited to the buffer, as it always was.
    let rest = ctx.remaining_accounts.get(1..).unwrap_or(&[]);
    let forfeit = match SolStarLegs::from_remaining(&ctx.accounts.config,
            &sol_pool, ctx.bumps.sol_pool.unwrap(),
            &ctx.accounts.token_program.to_account_info(),
            &ctx.accounts.system_program.to_account_info(), rest)? {
        Some(legs) => unpark_for_withdrawal(&mut ctx.accounts.bank,
            &ctx.accounts.config, &legs, &ctx.accounts.signer.to_account_info(),
            lamports, sol_price, &risk.actuary)?,
        None => {
            require!(lamports <= ctx.accounts.bank.sol_lamports,
                     PithyQuip::InsufficientFunds);
            0
        }
    };

    let bank = &mut ctx.accounts.bank;
    let customer = &mut ctx.accounts.customer_account;
    // Pay out carry earned on this SOL before the principal shrinks.
    customer.settle_sol_yield(bank);
    // The claim is lamports, so paying it is not a solvency question: the
    // depositor gets back what they put in plus carry, whatever the price has
    // done. There is no USD mark to measure it against, because a SOL deposit
    // margins nothing and underwrites nobody.
    //
    // Clamp before touching any book. The pool PDA holds deposits and nothing
    // else — no separate rent was ever funded into it — so its last few
    // thousand lamports are what keeps the account alive, and sending them
    // would delete the pool underneath everybody still in it. Paying what can
    // be paid beats refusing: whatever is not paid is not deducted either, so
    // it stays owed and becomes payable as soon as anyone else deposits.
    let rent_floor = Rent::get()?.minimum_balance(sol_pool.data_len());
    let spendable = sol_pool.lamports().saturating_sub(rent_floor);
    lamports = lamports.min(spendable.saturating_add(forfeit));
    require!(lamports > 0, PithyQuip::InsufficientFunds);

    // Now every book moves by the same, final figure.
    let locked_fraction = (lamports as u128)
        .saturating_mul(customer.sol_pledged_usd as u128)
        .checked_div(customer.deposited_lamports as u128)
        .unwrap_or(0) as u64;

    customer.sol_pledged_usd = customer.sol_pledged_usd.saturating_sub(locked_fraction);
    customer.deposited_lamports = customer.deposited_lamports.saturating_sub(lamports);
    bank.sol_usd_contrib = bank.sol_usd_contrib.saturating_sub(locked_fraction);
    bank.sol_lamports = bank.sol_lamports.saturating_sub(lamports);

    // The forfeit stays in the pool: the caller's claim falls by `lamports`
    // but only `lamports - forfeit` leaves, which is what "the withdrawer eats
    // the haircut" means in lamports.
    invoke_signed(&system_instruction::transfer(sol_pool.key,
                        ctx.accounts.signer.key, lamports.saturating_sub(forfeit)),
        &[sol_pool.to_account_info(),
          ctx.accounts.signer.to_account_info(),
          ctx.accounts.system_program.to_account_info()],
        &[&[SOL_POOL_SEED, &[ctx.bumps.sol_pool.unwrap()]]])?; Ok(())
}


// Permissionlessly marks down a depositor's stale sol_pledged_usd when SOL
// price has fallen since their last deposit. Positioned alongside amortise() —
// same keeper-callable pattern, same has_capacity() consequence.
//
// If after marking down total_deposits < max_liability, the pool is technically
// undercollateralised. No new liquidation path is needed: the next amortise()
// call on any open position will detect has_capacity() violated and fire.
// The keeper that calls refresh_sol_collateral should immediately call amortise()
// on the depositor's largest open position in the same or next transaction.

#[derive(Accounts)]
pub struct RefreshSolCollateral<'info> {
    // No signer required — permissionless, same as amortise()
    /// CHECK: owner verified inside handler
    pub depositor: AccountInfo<'info>,

    #[account(
        mut,
        seeds = [depositor.key().as_ref()], bump,
        constraint = customer_account.owner == depositor.key() @ PithyQuip::InvalidUser,
    )]
    pub customer_account: Box<Account<'info, Depositor>>,

    #[account(mut, seeds = [b"depository"], bump)]
    pub bank: Box<Account<'info, Depository>>,

    #[account(mut, seeds = [b"risk", "SOL".as_bytes()], bump = sol_risk.bump)]
    pub sol_risk: Box<Account<'info, TickerRisk>>,
    // remaining_accounts[0] = Pyth SOL/USD price account
}

pub fn handle_refresh_sol_collateral(
    ctx: Context<RefreshSolCollateral>) -> Result<()> {
    let slot = Clock::get()?.slot as i64;
    let now = Clock::get()?.unix_timestamp;
    let pyth = ctx.remaining_accounts.first();
    let sol_price = crate::etc::fetch_price("SOL", pyth)?;
    ctx.accounts.sol_risk.actuary
        .update_price(sol_price as i64, slot);

    let customer = &mut ctx.accounts.customer_account;
    if customer.deposited_lamports == 0 || customer.sol_pledged_usd == 0 {
        return Ok(()); // nothing to refresh
    }
    let current_floor = collar_adjusted_usd(
        customer.deposited_lamports, sol_price, 
        &ctx.accounts.sol_risk.actuary,
    );
    if current_floor >= customer.sol_pledged_usd {
        return Ok(()); // SOL has not dropped below locked value — nothing to do
    }
    // Re-mark the pool's record of what it holds in SOL, and stop there.
    //
    // This used to hand the reduction to `pool_mark_down`, which drained the
    // depositor's dollar balance and then reached into their open positions'
    // `pledged` — deleveraging a stock book because SOL had fallen. That
    // followed from SOL being credited as margin. It no longer is: a SOL
    // deposit margins nothing, so a SOL move has nothing to deleverage, and
    // the depositor's claim is their lamports either way.
    //
    // What remains is bookkeeping. The mark matters because `sol_usd_contrib`
    // is what the pool reports it is holding, and an unmarked one would
    // overstate it.
    let reduction = customer.sol_pledged_usd.saturating_sub(current_floor);
    let bank = &mut ctx.accounts.bank;
    customer.sol_pledged_usd = current_floor;
    bank.sol_usd_contrib = bank.sol_usd_contrib.saturating_sub(reduction);
    let _ = now;
    Ok(())
}

#[derive(Accounts)]
pub struct FlashRepay<'info> {
    #[account(mut)]
    pub repayer: Signer<'info>,

    #[account(mut, seeds = [b"depository"], bump)]
    pub bank: Box<Account<'info, Depository>>,

    #[account(mut, seeds = [b"flash_loan"], bump)]
    pub flash_loan: Box<Account<'info, FlashLoan>>,

    #[account(mut, seeds = [b"risk", "SOL".as_bytes()], bump = sol_risk.bump)]
    pub sol_risk: Box<Account<'info, TickerRisk>>,

    /// CHECK: PDA verified by seeds
    #[account(mut, seeds = [SOL_POOL_SEED], bump)]
    pub sol_pool: AccountInfo<'info>,

    pub system_program: Program<'info, System>,
    // remaining_accounts[0] = Pyth SOL/USD price account
}

// remaining_accounts for SPL repay (flash_token_amount > 0):
//   [0] vault — mut, seeds [b"vault", mint.key()]
//   [1] mint
//   [2] repayer_ata — mut
//   [3] token_program
// remaining_accounts[0] = Pyth SOL/USD price account (SOL repay only)
pub fn handle_flash_repay<'info>(ctx: Context<'_, '_, '_, 'info, 
    FlashRepay<'info>>, tip_lamports: u64, tip_token_amount: u64,
    // canonical [b"vault", mint] bump; 0 for SOL path
    vault_bump: u8) -> Result<()> {
    let bank = &mut ctx.accounts.bank;
    let flash = &mut ctx.accounts.flash_loan;
    if flash.flash_token_amount > 0 {
        let ra = ctx.remaining_accounts;
        let principal = flash.flash_token_amount;
        let total = principal.saturating_add(tip_token_amount);
        require!(ra.len() >= 4, PithyQuip::InvalidParameters);
        let (vault_ai, mint_ai, repayer_ata, token_prog) =
            (&ra[0], &ra[1], &ra[2], &ra[3]);

        // Validate vault PDA using caller-supplied bump (create_program_address,
        // single sha256, vs find_program_address's up-to-255-iteration loop).
        let expected = Pubkey::create_program_address(&[b"vault", 
            mint_ai.key.as_ref(), &[vault_bump]], &crate::ID).map_err(|_| 
                                 error!(PithyQuip::InvalidParameters))?;
        
        require_keys_eq!(vault_ai.key(), expected, PithyQuip::InvalidSettlementProgram);
        require_keys_eq!(*mint_ai.key, flash.flash_token_mint, PithyQuip::InvalidMint);
        // Reject fake token programs — no-op transfer would zero flash state
        // without returning principal to the vault.
        require!(token_prog.key() == anchor_spl::token::ID
              || token_prog.key() == anchor_spl::token_2022::ID, 
                                      PithyQuip::InvalidParameters);
        
        let decimals = { let d = mint_ai.try_borrow_data()?;
            require!(d.len() >= 45, PithyQuip::InvalidParameters);
            d[44]
        };
        use anchor_spl::token_interface::{
            TransferChecked, transfer_checked
        };
        transfer_checked(CpiContext::new(token_prog.clone(),
                TransferChecked { from: repayer_ata.clone(),
                    mint: mint_ai.clone(), to: vault_ai.clone(),
                    authority: ctx.accounts.repayer.to_account_info(),
                }), total, decimals)?;
                
        flash.flash_token_mint = Pubkey::default();
        flash.flash_token_amount = 0;
    } else { // SOL repay
        require!(flash.flash_lamports > 0, 
            PithyQuip::NoActiveFlashLoan);
            
        let principal = flash.flash_lamports;
        // Flash loans are free (tip_lamports is optional protocol revenue).
        let total = principal.saturating_add(tip_lamports);
        anchor_lang::system_program::transfer(CpiContext::new(
                ctx.accounts.system_program.to_account_info(),
                anchor_lang::system_program::Transfer {
                    from: ctx.accounts.repayer.to_account_info(),
                    to: ctx.accounts.sol_pool.to_account_info() }), total)?;
        
        flash.flash_lamports = 0;
        bank.sol_lamports = bank.sol_lamports.saturating_add(total);
        // Restore sol_usd_contrib at current price.
        // If SOL rose during loan: restored > original → tiny protocol gain.
        // If SOL fell: restored < original → conservative, correct.
        let slot = Clock::get()?.slot as i64;
        let pyth = ctx.remaining_accounts.first();
        let sol_price = crate::etc::fetch_price("SOL", pyth)?;
        ctx.accounts.sol_risk.actuary.update_price(sol_price as i64, slot);
        // Re-mark on hot + parked-net-of-haircut. flash_borrow zeroes the whole
        // sol_usd_contrib, so restoring from sol_lamports alone would delete the
        // parked tranche's backing on every SOL flash loan.
        let restored = collar_adjusted_usd(credited_lamports(bank), sol_price,
                                          &ctx.accounts.sol_risk.actuary);
        bank.total_deposits = bank.total_deposits.saturating_add(restored);
        bank.sol_usd_contrib = restored;
    } Ok(())
}

// =============================================================================
// SOL* PARKING — unpark
// =============================================================================


// =============================================================================
// SWEEP — permissionless, fault-tolerant batch amortisation
// =============================================================================
//
// `amortise` only ever runs if somebody calls it for one specific position, so
// nothing guaranteed that every position was examined. The C++ this replaces
// solves that with a cursor and a batch size, walking its user table inside a
// keeper-authorised `doupdate`. Solana cannot iterate accounts on-chain at all,
// so the equivalent inverts: the caller supplies the batch, the program checks
// each account is genuinely one of ours, and coverage is recorded rather than
// enumerated.
//
// Two properties that matter more than the iteration itself:
//
//   * Permissionless. Vigor's sweep needs contract authority; this one needs a
//     signer with rent for their own commission account. A dark keeper cannot
//     stop the book from being marked.
//   * Fault-tolerant. A position that is healthy, too fresh, or malformed is
//     SKIPPED, not reverted. One bad account in a batch of thirty used to mean
//     the whole transaction failed and nothing was marked.
//
// The price is fetched once for the batch rather than once per position, which
// is what makes a large batch cheaper than N separate `amortise` calls.

#[derive(Accounts)]
#[instruction(ticker: String)]
pub struct Sweep<'info> {
    #[account(mut)]
    pub cranker: Signer<'info>,

    #[account(seeds = [b"program_config"], bump = config.bump)]
    pub config: Box<Account<'info, ProgramConfig>>,

    #[account(mut, seeds = [b"depository"], bump)]
    pub bank: Box<Account<'info, Depository>>,

    #[account(mut, seeds = [b"risk", ticker.as_bytes()], bump = ticker_risk.bump)]
    pub ticker_risk: Box<Account<'info, TickerRisk>>,

    /// Commission lands here, so cranking pays for itself.
    #[account(init_if_needed, payer = cranker,
        space = 8 + Depositor::INIT_SPACE,
        seeds = [cranker.key().as_ref()], bump)]
    pub cranker_account: Box<Account<'info, Depositor>>,

    pub system_program: Program<'info, System>,
    // remaining_accounts[0]  = Pyth price account for `ticker`
    // remaining_accounts[1..] = Depositor PDAs to examine (writable)
}

pub fn handle_sweep<'info>(ctx: Context<'_, '_, 'info, 'info, Sweep<'info>>,
    ticker: String) -> Result<()> {
    let t: &str = ticker.as_str();
    let key: &str = get_account(t).ok_or(PithyQuip::UnknownSymbol)?;
    let first = ctx.remaining_accounts.first().ok_or(PithyQuip::NoPrice)?;
    require!(first.key.to_string() == key, PithyQuip::UnknownSymbol);

    let clock = Clock::get()?;
    let (now, slot) = (clock.unix_timestamp, clock.slot as i64);

    // Once for the batch, not once per position.
    let price = fetch_price(t, Some(first))?;
    let util = ctx.accounts.bank.utilisation_bps();
    let risk = &mut ctx.accounts.ticker_risk;
    risk.actuary.accrue_premium_index(now, util);
    risk.actuary.update_price(price as i64, slot);
    risk.actuary.check_twap_deviation(price as i64)?;

    let bank = &mut ctx.accounts.bank;
    let elapsed = now.saturating_sub(bank.last_updated);
    bank.total_deposit_seconds = bank.total_deposit_seconds
        .saturating_add((bank.total_deposits as u128)
            .saturating_mul(elapsed.max(0) as u128));
    bank.last_updated = now;

    let mut commission: u64 = 0;
    let mut touched: u64 = 0;

    for info in ctx.remaining_accounts.iter().skip(1) {
        // Ours, writable, and a real Depositor — or skipped, never reverted.
        if info.owner != ctx.program_id || !info.is_writable { continue; }
        let mut data = match info.try_borrow_mut_data() { Ok(d) => d, Err(_) => continue };
        let mut customer = match Depositor::try_deserialize(&mut data.as_ref()) {
            Ok(c) => c, Err(_) => continue,
        };
        // The PDA is seeded by its owner, so this rules out a look-alike
        // account carrying someone else's balances.
        let (expected, _) = Pubkey::find_program_address(
            &[customer.owner.as_ref()], ctx.program_id);
        if expected != info.key() { continue; }

        let before = customer.deposited_quid;
        match customer.repo(t, 0, price, now, slot, &risk.actuary, bank) {
            Ok((delta, interest)) if delta != 0 => {
                let cut = (delta.unsigned_abs()) / 250;
                bank.yield_pool = bank.yield_pool.saturating_add(interest);
                if delta < 0 {
                    // Profit taken on behalf of every depositor, at the
                    // expense of this one — less the cranker's cut.
                    let credited = delta.unsigned_abs().saturating_sub(cut);
                    bank.yield_pool = bank.yield_pool.saturating_add(credited);
                    risk.actuary.record_activity(0, -(credited as i64), slot,
                        credited as i64, bank.total_deposits as i64);
                    reconcile_ticker_reserve(risk, bank);
                } else {
                    // Salvaged from the depositor's own free balance. Without
                    // prices for their other positions a sweep cannot sell
                    // across the book, so it takes only what is already liquid.
                    let take = (delta as u64).min(customer.deposited_quid);
                    customer.deposited_quid -= take;
                    bank.yield_pool = bank.yield_pool.saturating_add(take);
                }
                commission = commission.saturating_add(cut);
                touched += 1;
                let _ = before;
                if customer.try_serialize(&mut data.as_mut()).is_err() { continue; }
            }
            // Healthy, too fresh, or unpriceable: leave it alone.
            _ => continue,
        }
    }

    bank.swept_at = now;
    bank.swept_count = bank.swept_count.saturating_add(touched);

    let cranker_acct = &mut ctx.accounts.cranker_account;
    if cranker_acct.owner == Pubkey::default() {
        cranker_acct.owner = ctx.accounts.cranker.key();
        cranker_acct.last_updated = now;
    }
    cranker_acct.deposited_quid = cranker_acct.deposited_quid
        .saturating_add(commission);
    // Same move as the liquidator's cut: pledge is not in the total, a
    // depositor balance is, so the total rises with it.
    ctx.accounts.bank.total_deposits =
        ctx.accounts.bank.total_deposits.saturating_add(commission);

    emit!(Swept { ticker, touched, commission, at: now });
    Ok(())
}

#[event]
pub struct Swept {
    pub ticker: String,
    pub touched: u64,
    pub commission: u64,
    pub at: i64,
}
