
use anchor_lang::prelude::*;
use crate::etc::{ MAX_AGE, MAX_LEN,
    PithyQuip, Actuary, collar_bps,
    rate_bps, max_leverage_x100 };

#[derive(AnchorSerialize,
    AnchorDeserialize,
    Clone, Copy, Debug,
    PartialEq, Eq)]
pub struct Stock {
    // (b"GOOGL\0\0\0")
    pub ticker: [u8; 8],
    pub pledged: u64,
    pub exposure: i64,
    // ^ same precision
    // as USD* (10^6)
    pub updated: i64,
    pub rate_bps: u16,
    pub collar_bps: u16,

    // cost_basis tracks entry cost across renege() adjustments.
    // PnL at close = transfer - cost_basis - interest_paid...
    pub cost_basis: u64,
    // Cumulative interest paid position across repo() calls
    pub interest_paid: u64,

    /// Time-integrated economic capital: sum of (collar_dollars × seconds).
    /// RAROC denominator — how much capital was at risk, for how long...
    pub collar_dollar_seconds: u128,
}
impl Space for Stock {
    const INIT_SPACE:
    usize = 8 + 8 + 8
          + 8 + 2 + 2
          + 8 + 8  // cost_basis + interest_paid
          + 16;    // collar_dollar_seconds
}

#[account]
#[derive(InitSpace)]
pub struct Depository {
    pub last_updated: i64,
    pub total_deposits: u64,
    pub total_deposit_seconds: u128,
    // ^ the faster one enter & exit,
    // the less of an accrued yield
    // one can take (slower, stickier
    // depositors get more, pro rata)
    pub total_drawn: u64,
    // ^ leverage exposure
    pub market_count: u64,
    // ^ prediction markets
    pub max_liability: u64,
    pub sol_lamports: u64,
    pub sol_usd_contrib: u64,
}

/// Per-order flash loan state. Separate from Depository so the core accounting
/// struct never carries mutable mid-tx state. Exactly one FlashLoan account
/// exists (seeds=[b"flash_loan"]) and is init_if_needed at program deploy.
/// Zero-valued fields mean no active loan.
#[account]
#[derive(InitSpace)]
pub struct FlashLoan {
    pub flash_lamports:     u64,    // SOL flash loan principal (0 = none)
    // SPL token flash loan — Pubkey::default()/0 means no active loan.
    // SOL and SPL are mutually exclusive (enforced in flash_borrow).
    pub flash_token_mint:   Pubkey,
    pub flash_token_amount: u64,
}

// naive timestamping: it over-weights early dust deposits;
// can be gamed by adding size later to inherit "old" age.
// To prevent this, we use dollar-seconds, time-weighted
// deposit value, updated continuously to stay accurate.

impl Depository {
    /// Update utilization when positions are opened/closed
    /// tracks total amount at risk (value of all positions)
    pub fn utilisation(&mut self, drawn_change: i64) {
        if drawn_change > 0 {
            self.total_drawn = self.total_drawn.saturating_add(
                                            drawn_change as u64);
        } else {
            self.total_drawn = self.total_drawn.saturating_sub(
                                    drawn_change.unsigned_abs());
        }
    }

    pub fn concentration(&self) -> i64 {
        if self.total_deposits == 0 { return 0; }
        ((self.total_drawn as u128 * 10_000 / self.total_deposits as u128) as u64) as i64
    }

    pub fn update_liability(&mut self, old: u64, new: u64) {
        self.max_liability = self.max_liability.saturating_sub(old).saturating_add(new);
    }

    /// Check if pool has capacity for additional collar exposure.
    ///
    /// Solvency requirement: total deposits must cover worst-case losses.
    /// max_liability tracks sum of (exposure × collar_bps) for all positions.
    /// If all positions hit their collar simultaneously, the pool must cover it.
    pub fn has_capacity(&self, additional_collar: u64) -> bool {
        if self.total_deposits == 0 { return false; }
        self.max_liability.saturating_add(additional_collar) <= self.total_deposits
    }

    /// Maximum amount LP can withdraw without breaking solvency.
    /// Must maintain enough deposits to cover worst-case collar losses.
    pub fn withdrawable(&self) -> u64 {
        self.total_deposits.saturating_sub(self.max_liability)
    }
}

#[account]
#[derive(InitSpace)]
pub struct Depositor {
    pub owner: Pubkey,
    pub deposited_quid: u64,
    pub deposited_lamports: u64,
    pub sol_pledged_usd: u64,
    pub deposit_seconds: u128,
    pub last_updated: i64,
    pub drawn: u64,     // mirrors Depository.total_drawn for this account;
    // pure depositors (drawn=0) receive full yield share; borrowers receive
    // a share discounted by their proportion of total pool risk (see clutch.rs)
    #[max_len(MAX_LEN)]
    pub balances: Vec<Stock>,
    pub realized_pnl: i64,
    pub total_interest_paid: u64,
    /* liquidation buffer the pool
    is holding against this position
    at any moment. Not full pledged
    amount, not exposure — the capital
    the pool has committed to absorb
    before liquidating.
    collar_dollar_seconds = integral
    of collar_dollars over time.

    When you divide realized_pnl
    by total_collar_dollar_seconds
    (normalized to a common  unit),
    you get the return per unit of
    economic capital deployed: real
    measure of whether a trader is
    generating alpha or just taking
    pool-subsidized risk.
    */
    pub total_collar_dollar_seconds: u128,
}

/// Helper for liability
/// state transitions
/// (transient, not persisted)
struct LiabilityUpdate {
    old_collar_dollars: u64,
    new_collar_bps: u16,
    new_collar_dollars: u64,
}

impl LiabilityUpdate {
    fn compute(old_exposure: u64, old_collar_bps: u16,
        new_exposure: u64, new_pledged: u64, actuary: &Actuary) -> Self {
        let old_collar_dollars = old_exposure.saturating_mul(old_collar_bps as u64) / 10_000;
        let new_leverage = if new_pledged > 0 {
            ((new_exposure as u128 * 100) /
              new_pledged as u128).min(i64::MAX as u128) as i64
        } else { 100 };

        let new_collar = collar_bps(new_leverage, actuary);
        let new_collar_dollars = new_exposure.saturating_mul(new_collar as u64) / 10_000;
        Self { old_collar_dollars, new_collar_bps: new_collar as u16, new_collar_dollars }
    }
    fn apply(self, pod: &mut Stock,
            depository: &mut Depository) {
        pod.collar_bps = self.new_collar_bps;
        depository.update_liability(self.old_collar_dollars,
                                    self.new_collar_dollars);
    }
}

impl Depositor {
    pub fn pad_ticker(ticker: &str) -> [u8; 8] {
        let mut padded = [0u8; 8];
        let bytes = ticker.trim().as_bytes();
        let len = bytes.len().min(8);
        padded[..len].copy_from_slice(&bytes[..len]);
        padded
    }

    pub fn adjust_deposit_seconds(&mut self,
        amount_reduced: u64, current_time: i64) {
        if self.deposited_quid > 0 && amount_reduced > 0 {
            let time_delta = (current_time - self.last_updated).max(0) as u128;
            self.deposit_seconds = self.deposit_seconds.saturating_add(
                time_delta.saturating_mul(self.deposited_quid as u128));

            let remaining = self.deposited_quid.saturating_sub(
                                                amount_reduced) as u128;
            if self.deposited_quid > 0 {
                self.deposit_seconds = self.deposit_seconds .checked_mul(remaining)
                .and_then(|v| v.checked_div(self.deposited_quid as u128)).unwrap_or(0);
            }
            self.last_updated = current_time;
        }
    }

    /// Mirror every depository.utilisation(delta) call on this account so that
    /// clutch.rs can discount yield claims by the borrower's share of pool risk.
    pub fn update_drawn(&mut self, change: i64) {
        if change > 0 {
            self.drawn = self.drawn.saturating_add(change as u64);
        } else {
            self.drawn = self.drawn.saturating_sub(change.unsigned_abs());
        }
    }

    /// Accrue time-weighted deposit_seconds and total_deposit_seconds
    /// without mutating deposited_quid or total_deposits.
    /// Call before any operation that changes deposited_quid on an existing customer.
    pub fn accrue(&mut self, bank: &mut Depository, now: i64) {
        if self.owner == Pubkey::default() { return; }
        let dc = now.saturating_sub(self.last_updated) as u64;
        self.deposit_seconds = self.deposit_seconds
            .saturating_add(self.deposited_quid as u128 * dc as u128);
        let db = now.saturating_sub(bank.last_updated) as u64;
        bank.total_deposit_seconds = bank.total_deposit_seconds
            .saturating_add(bank.total_deposits as u128 * db as u128);
        self.last_updated = now;
        bank.last_updated = now;
    }

    pub fn pool_deposit(&mut self,
        bank: &mut Depository, usd: u64, now: i64) {
        if self.owner != Pubkey::default() {
            let dc = now.saturating_sub(self.last_updated) as u64;
            self.deposit_seconds = self.deposit_seconds
                .saturating_add(self.deposited_quid as u128 * dc as u128);
            let db = now.saturating_sub(bank.last_updated) as u64;
            bank.total_deposit_seconds = bank.total_deposit_seconds
                .saturating_add(bank.total_deposits as u128 * db as u128);
        }
        self.deposited_quid = self.deposited_quid.saturating_add(usd);
        bank.total_deposits = bank.total_deposits.saturating_add(usd);
        self.last_updated = now;
        bank.last_updated = now;
    }

    pub fn pool_withdraw(&mut self,
        bank: &mut Depository, usd: u64, now: i64) -> Result<()> {
        let dc = now.saturating_sub(self.last_updated) as u64;
        self.deposit_seconds = self.deposit_seconds
            .saturating_add(self.deposited_quid as u128 * dc as u128);
        let db = now.saturating_sub(bank.last_updated) as u64;
        bank.total_deposit_seconds = bank.total_deposit_seconds
            .saturating_add(bank.total_deposits as u128 * db as u128);
        let new_total = bank.total_deposits.saturating_sub(usd);
        require!(new_total >= bank.max_liability, PithyQuip::Undercollateralised);
        self.deposited_quid = self.deposited_quid.saturating_sub(usd);
        bank.total_deposits = new_total;
        self.last_updated = now;
        bank.last_updated = now;
        Ok(())
    }

    pub fn pool_mark_down(&mut self,
        bank: &mut Depository, usd: u64, now: i64) {
        let dc = now.saturating_sub(self.last_updated) as u64;
        self.deposit_seconds = self.deposit_seconds
            .saturating_add(self.deposited_quid as u128 * dc as u128);
        let db = now.saturating_sub(bank.last_updated) as u64;
        bank.total_deposit_seconds = bank.total_deposit_seconds
            .saturating_add(bank.total_deposits as u128 * db as u128);
        self.deposited_quid = self.deposited_quid.saturating_sub(usd);
        bank.total_deposits = bank.total_deposits.saturating_sub(usd);
        self.last_updated = now;
        bank.last_updated = now;
    }

    /// Accumulate collar_dollar_seconds on a pod before any pledged/collar mutation.
    /// collar_dollars = pledged × collar_bps / 10_000 (economic capital at risk).
    /// Integral of capital-at-risk over time — the RAROC denominator.
    #[inline]
    fn accumulate_collar_seconds(pod: &mut Stock, current_time: i64) {
        let elapsed = (current_time - pod.updated).max(0) as u128;
        if elapsed > 0 && pod.collar_bps > 0 {
            let collar_dollars = pod.pledged
                .saturating_mul(pod.collar_bps as u64) / 10_000;
            pod.collar_dollar_seconds = pod.collar_dollar_seconds
                .saturating_add(elapsed.saturating_mul(collar_dollars as u128));
        }
    }

    /// Accumulate Depositor RAROC fields from a closed position.
    /// Pass pod field values directly to avoid borrow conflict with self.balances.
    /// Call at every code path that zeroes pod.exposure in repo().
    /// Also passes collar_dollar_seconds so the RAROC denominator is complete.
    fn flush_raroc(&mut self, cost_basis: u64, interest_paid: u64,
        collar_dollar_seconds: u128, transfer: u64) {
        let net = transfer as i64 - cost_basis as i64
                                  - interest_paid as i64;

        self.realized_pnl = self.realized_pnl.saturating_add(net);
        self.total_interest_paid =
            self.total_interest_paid.saturating_add(interest_paid);
        self.total_collar_dollar_seconds =
            self.total_collar_dollar_seconds.saturating_add(collar_dollar_seconds);
    }

    // Position shrinking means "virtual sale": profitable synthetic redemption withdraws
    // Banks.total_deposits (more than pledged); similar to a collar (hedge wrapper), one
    // strategy for protecting against losses...though it limits large gains (under X%);
    // lest borrowers dilute depositors' yield, following solution creates speed bumps
    pub fn repo(&mut self, ticker: &str, // reposition, or repossession (it depends)
        mut amount: i64, price: u64, current_time: i64, slot: i64, actuary: &Actuary,
        depository: &mut Depository) -> Result<(i64, u64)> {
        require!(price > 0, PithyQuip::InvalidPrice);
        let padded = Self::pad_ticker(ticker);
        let pod = self.balances.iter_mut()
            .find(|p| p.ticker == padded)
            .ok_or(PithyQuip::DepositFirst)?;

        let old_exposure_value = (pod.exposure.unsigned_abs() as u128)
            .saturating_mul(price as u128)
            .min(u64::MAX as u128) as u64;

        let leverage = if pod.pledged > 0 {
            ((old_exposure_value as u128 * 100) /
            pod.pledged as u128).min(i64::MAX as u128) as i64
        } else { 100 };

        let collar = collar_bps(leverage, actuary);
        let collar_amt = pod.pledged.saturating_mul(collar as u64) / 10_000;
        let time_elapsed = current_time.saturating_sub(pod.updated);

        let conc = depository.concentration();
        let rate = rate_bps(conc, leverage, actuary);
        let accrued_interest = ((old_exposure_value as u128)
                                .saturating_mul(rate as u128)
                                .saturating_mul(time_elapsed.max(0) as u128)
                                / (31_536_000u128 * 10_000u128)) as u64;

        let util_factor = (conc as f64 / 10000.0).max(0.1).min(1.0);
        let max_lev = max_leverage_x100(actuary, slot, conc);
        pod.pledged = pod.pledged.saturating_sub(accrued_interest);
        pod.interest_paid = pod.interest_paid.saturating_add(accrued_interest);
        if pod.exposure > 0 || (pod.exposure == 0 && amount > 0) {
            // if increasing exposure for long...it must not be
            // either worth > pledged, or less than X%
            // same for decreasing, except that whole
            // amount can be decreased to take profit
            // before we apply changes to exposure,
            // run checks against current ^^^^^^^^
            let upper = pod.pledged.saturating_add(collar_amt);
            let exposure = old_exposure_value;
            // for the first clause, amount irrelevant
            // (contains solely a preventative intent)
            // unless amount == 0 (liquidator caller)
            if exposure > upper { // Over-profitable:
                // must take profit or add collateral
                let delta = exposure.saturating_sub(upper); // gross excess; user pays this...
                let net = delta.saturating_sub(delta / 250); // net added to pledged after fee
                if self.deposited_quid >= delta { 
                    let new_pledged = pod.pledged.saturating_add(net);
                    let lelu = LiabilityUpdate::compute(old_exposure_value,
                            pod.collar_bps, exposure, new_pledged, actuary);
                    let collar_increase = lelu.new_collar_dollars.saturating_sub(lelu.old_collar_dollars);
                    require!(depository.has_capacity(collar_increase), PithyQuip::PoolAtCapacity);

                    self.deposited_quid -= delta;
                    pod.updated = current_time;
                    pod.pledged = new_pledged;
                    lelu.apply(pod, depository);
                    self.update_drawn(delta as i64);
                    depository.utilisation(delta as i64);
                    // Don't record take profit, happens when
                    // calling instruction (avoids double-count)
                    return Ok((delta as i64, accrued_interest));
                } // need to burn ^ from depository's shares...
                else if amount != 0 { // caller is not liquidator;
                    // if your profit is too much, you can only TP
                    // when it's X% above the max profitabiltiy, as
                    // you caller deducts from Banks.total_deposits...
                    return Err(PithyQuip::Undercollateralised.into());
                    // can't increase exposure or TP (collar constraint)...
                } // "this is beginning to feel like the bolt busted loose from
                // the lever...I'm trying to reconstruct the air and all that it
                // brings...oxidation is the compromise you own...if you plant
                // ice...then harvest wind..from a static explosion," amortised.
                else if amount == 0 { // < function got called by a liquidator...
                // it means profit attribution that should belong to 1 depositor
                // is actually getting appropriated by all depositors, slowly,
                // giving the depositor time to react and close their position
                    require!(time_elapsed > MAX_AGE as i64, PithyQuip::TooSoon);
                    // Amortization speed: 0.5x at 10% util, 2.0x at 100% util
                    // Base: 4 days to liquidate, faster at high utilization
                    let speed = 0.5 + 1.5 * util_factor;
                    let reduce =  ((pod.exposure.unsigned_abs() as f64 *
                        (time_elapsed as f64 / MAX_AGE as f64)) * speed) as u64;
                    let reduce = reduce.max(1);

                    pod.exposure = pod.exposure.saturating_sub(reduce as i64);
                    let reduce_dollars = reduce.saturating_mul(price);
                    pod.pledged = pod.pledged.saturating_sub(reduce_dollars);
                    pod.updated = current_time;

                    let new_exp = (pod.exposure.unsigned_abs() as u128)
                        .saturating_mul(price as u128)
                        .min(u64::MAX as u128) as u64;

                    let lelu = LiabilityUpdate::compute(old_exposure_value,
                            pod.collar_bps, new_exp, pod.pledged, actuary);

                    lelu.apply(pod, depository);
                    let neg_reduce = (reduce_dollars as i64).saturating_neg();

                    let pod_exposure_after = pod.exposure;
                    let (pod_cb, pod_ip, pod_cds) = (pod.cost_basis,
                        pod.interest_paid, pod.collar_dollar_seconds);
                    let _ = &pod; // end borrow before &mut self
                    self.update_drawn(neg_reduce);
                    depository.utilisation(neg_reduce);
                    if pod_exposure_after == 0 {
                        self.flush_raroc(pod_cb, pod_ip, pod_cds, 0);
                    }   return Ok((neg_reduce, accrued_interest));
                } // ^ (-) indicates amount is (+) to Banks.total_deposits
             // as it performs a credit (ditto for UniV4's PoolManager) and
            // pays the liquidator a small cut (delta - 0.05% gets absorbed)
            } let lower = pod.pledged.saturating_sub(collar_amt);
            if lower > exposure && exposure > 0 { // under-exposed:
                // exceeding maximum drop of X%
                // first, try prevent liquidation
                let mut delta = lower.saturating_sub(exposure).saturating_sub(collar_amt);
                delta = delta.saturating_add(delta / 250);
                if self.deposited_quid >= delta {
                    let new_exp = exposure.saturating_add(delta).saturating_sub(delta / 250);
                    let lelu = LiabilityUpdate::compute(old_exposure_value,
                            pod.collar_bps, new_exp, pod.pledged, actuary);

                    let collar_increase = lelu.new_collar_dollars.saturating_sub(lelu.old_collar_dollars);
                    require!(depository.has_capacity(collar_increase), PithyQuip::PoolAtCapacity);

                    self.deposited_quid -= delta;
                    pod.exposure = pod.exposure.saturating_add(
                        ((delta.saturating_sub(delta / 250)) as f64 / price as f64) as i64
                    );
                    // Track increased exposure
                    pod.updated = current_time;
                    lelu.apply(pod, depository);
                    self.update_drawn(delta as i64);
                    depository.utilisation(delta as i64);
                    return Ok((delta as i64, accrued_interest));
                }
                else if amount == 0 {
                    require!(time_elapsed > MAX_AGE as i64, PithyQuip::TooSoon);
                    let speed = 0.5 + 1.5 * util_factor;

                    let reduce = ((pod.exposure.abs() as f64 *
                        (time_elapsed as f64 / MAX_AGE as f64)) * speed) as u64;

                    let reduce = reduce.max(1);
                    pod.exposure -= reduce as i64;
                    let reduce_dollars = reduce * price;
                    pod.pledged = pod.pledged.saturating_sub(reduce_dollars);
                    pod.updated = current_time;

                    let new_exp = pod.exposure.abs() as u64 * price;
                    let lelu = LiabilityUpdate::compute(
                        old_exposure_value, pod.collar_bps,
                        new_exp, pod.pledged, actuary);

                    lelu.apply(pod, depository);
                    self.update_drawn(-(reduce_dollars as i64));
                    depository.utilisation(-(reduce_dollars as i64));
                    return Ok((-(reduce_dollars as i64), accrued_interest));
                } else { // ^ total deposits ^ incremented plus ^
                    return Err(PithyQuip::Undercollateralised.into());
                }
            } require!(amount != 0, PithyQuip::InvalidAmount);
            pod.exposure = pod.exposure.saturating_add(amount);
            if amount < 0 { // trying to redeem units,
                // this reduces exposure and pledged,
                // while trying to redeem units...
                if pod.exposure < 0 {
                    amount = amount.saturating_add(
                     pod.exposure.saturating_neg());
                    pod.exposure = 0;
                }
                // $ value to be sent to depositor is accounted as:
                let redeem_dollars = (amount.unsigned_abs() as u128)
                                      .saturating_mul(price as u128)
                                     .min(u64::MAX as u128) as u64;

                if redeem_dollars > pod.pledged { // all-in TP...
                    let total = redeem_dollars; // full take-profit...
                    let from_pool = total.saturating_sub(pod.pledged).saturating_sub(accrued_interest);

                    pod.pledged = 0; pod.updated = current_time;
                    let new_exp = (pod.exposure.unsigned_abs() as u128)
                                         .saturating_mul(price as u128)
                                        .min(u64::MAX as u128) as u64;

                    let lelu = LiabilityUpdate::compute(old_exposure_value,
                    pod.collar_bps, new_exp, pod.pledged, actuary);

                    lelu.apply(pod, depository);
                    let util_change = -((amount.unsigned_abs() as i128)
                                         .saturating_mul(price as i128)
                                        .min(i64::MAX as i128) as i64);
                    // RAROC: extract before update_drawn ends the window to hold pod
                    let (cb, ip, cds) = (pod.cost_basis, pod.interest_paid, pod.collar_dollar_seconds);
                    self.update_drawn(util_change);
                    depository.utilisation(util_change);
                    self.flush_raroc(cb, ip, cds, total);
                    return Ok((-(from_pool as i64), total));
                } else { // partial take-profit
                    pod.pledged = pod.pledged.saturating_sub(redeem_dollars);
                    let transfer = redeem_dollars.saturating_sub(accrued_interest);
                    pod.updated = current_time;
                    let new_exp = (pod.exposure.unsigned_abs() as u128)
                                         .saturating_mul(price as u128)
                                                 .min(u64::MAX as u128) as u64;

                    let lelu = LiabilityUpdate::compute(old_exposure_value,
                    pod.collar_bps, new_exp, pod.pledged, actuary);

                    lelu.apply(pod, depository);
                    let util_change = -((amount.unsigned_abs() as i128)
                                           .saturating_mul(price as i128)
                                           .min(i64::MAX as i128) as i64);
                    let _ = &pod; // end borrow before &mut self
                    self.update_drawn(util_change);
                    depository.utilisation(util_change);
                    return Ok((0, transfer));
                }
            } else { // Adding exposure
                let new_exp = (pod.exposure as u64).saturating_mul(price);
                let post_lev = if pod.pledged > 0 {
                    ((new_exp as u128 * 100) / pod.pledged as u128).min(i64::MAX as u128) as i64
                } else { 100 };
                require!(post_lev <= max_lev, PithyQuip::Undercollateralised);
                let delta = pod.pledged.saturating_add(collar_amt);
                if new_exp > delta {
                    let excess = new_exp.saturating_sub(delta);
                    if self.deposited_quid >= excess {
                        self.deposited_quid -= excess;
                        pod.pledged = pod.pledged.saturating_add(excess);
                    } else {
                        pod.exposure = pod.exposure.saturating_sub(
                             (excess as f64 / price as f64) as i64);
                    }
                } else if pod.pledged > collar_amt {
                    let room = pod.pledged.saturating_sub(collar_amt);
                    if room > new_exp { pod.exposure = pod.exposure.saturating_add(
                             ((room.saturating_sub(new_exp)) as f64 / price as f64) as i64);
                    }
                } pod.updated = current_time;
                let final_exp = (pod.exposure.unsigned_abs() as u128)
                                        .saturating_mul(price as u128)
                                        .min(u64::MAX as u128) as u64;

                let lelu = LiabilityUpdate::compute(old_exposure_value,
                        pod.collar_bps, final_exp, pod.pledged, actuary);

                if amount > 0 {
                    let collar_increase = lelu.new_collar_dollars.saturating_sub(lelu.old_collar_dollars);
                    require!(depository.has_capacity(collar_increase), PithyQuip::PoolAtCapacity);
                }
                lelu.apply(pod, depository);
                let util_change = (amount as i128)
                    .saturating_mul(price as i128)
                          .clamp(i64::MIN as i128,
                                 i64::MAX as i128) as i64;

                self.update_drawn(util_change);
                depository.utilisation(util_change);
                return Ok((0, accrued_interest));
            }
        } let exposure = ((-pod.exposure) as u64).saturating_mul(price);
        let pivot = pod.pledged.saturating_sub(collar_amt);
        if pivot >= exposure && exposure > 0 {
            // Short in profit beyond collar
            let mut delta = pivot.saturating_sub(exposure);
            delta = delta.saturating_add(delta / 250);
            if self.deposited_quid >= delta {
                let new_exp = exposure.saturating_add(delta).saturating_sub(delta / 250);
                let lelu = LiabilityUpdate::compute(old_exposure_value, pod.collar_bps,
                                                    new_exp, pod.pledged, actuary);

                let collar_increase = lelu.new_collar_dollars.saturating_sub(lelu.old_collar_dollars);
                require!(depository.has_capacity(collar_increase), PithyQuip::PoolAtCapacity);

                self.deposited_quid -= delta;
                pod.exposure = pod.exposure.saturating_add((
                    ((delta.saturating_sub(delta / 250)) as f64) / price as f64) as i64);

                pod.updated = current_time;
                lelu.apply(pod, depository);
                let util_change = (amount as i128)
                    .saturating_mul(price as i128)
                    .clamp(i64::MIN as i128, i64::MAX as i128) as i64;

                self.update_drawn(util_change);
                depository.utilisation(util_change);
                return Ok((delta as i64, accrued_interest));
            }
            else if amount != 0 {
                return Err(PithyQuip::Undercollateralised.into());
            } else {
                require!(time_elapsed > MAX_AGE as i64, PithyQuip::TooSoon);

                let speed = 0.5 + 1.5 * util_factor;
                let reduce = ((pod.exposure.unsigned_abs() as f64 *
                    (time_elapsed as f64 / MAX_AGE as f64)) * speed) as u64;

                let reduce = reduce.max(1);
                pod.exposure = pod.exposure.saturating_add(reduce as i64);
                pod.pledged = pod.pledged.saturating_sub(
                            reduce.saturating_mul(price));

                pod.updated = current_time;
                let new_exp = (pod.exposure.unsigned_abs() as u128)
                                     .saturating_mul(price as u128)
                                    .min(u64::MAX as u128) as u64;

                let lelu = LiabilityUpdate::compute(old_exposure_value,
                pod.collar_bps, new_exp, pod.pledged, actuary);

                lelu.apply(pod, depository);
                let dollars = -((reduce as i128).saturating_mul(price as i128)
                                               .min(i64::MAX as i128) as i64);
                let pod_exp = pod.exposure;
                let (pod_cb, pod_ip, pod_cds) = (pod.cost_basis,
                    pod.interest_paid, pod.collar_dollar_seconds);

                self.update_drawn(dollars);
                depository.utilisation(dollars);
                // RAROC: short liquidation nibble
                if pod_exp == 0 {
                    self.flush_raroc(pod_cb,
                        pod_ip, pod_cds, 0);
                }
                return Ok((dollars,
                accrued_interest));
            }
        } if exposure > pivot || exposure == 0 {
            let upper = pod.pledged.saturating_add(collar_amt);
            if exposure > upper {
                let mut delta = exposure.saturating_sub(upper);
                delta = delta.saturating_add(delta / 250);
                if self.deposited_quid >= delta {
                    let new_pledged = pod.pledged.saturating_add(delta).saturating_sub(delta / 250);
                    let lelu = LiabilityUpdate::compute(old_exposure_value, pod.collar_bps,
                                                            exposure, new_pledged, actuary);

                    let collar_increase = lelu.new_collar_dollars.saturating_sub(lelu.old_collar_dollars);
                    require!(depository.has_capacity(collar_increase), PithyQuip::PoolAtCapacity);

                    self.deposited_quid -= delta;
                    pod.pledged = new_pledged;
                    pod.updated = current_time;
                    lelu.apply(pod, depository);
                    self.update_drawn(delta as i64);
                    depository.utilisation(delta as i64);
                    return Ok((delta as i64, accrued_interest));
                }
                else if amount == 0 {
                    require!(time_elapsed > MAX_AGE as i64, PithyQuip::TooSoon);

                    let speed = 0.5 + 1.5 * util_factor;
                    let reduce = ((pod.exposure.abs() as f64 *
                        (time_elapsed as f64 / MAX_AGE as f64)) * speed) as u64;

                    let reduce = reduce.max(1); pod.updated = current_time;
                    pod.exposure = pod.exposure.saturating_add(reduce as i64);
                    pod.pledged = pod.pledged.saturating_sub(reduce.saturating_mul(price));
                    let new_exp = (pod.exposure.unsigned_abs() as u128)
                                         .saturating_mul(price as u128)
                                        .min(u64::MAX as u128) as u64;

                    let lelu = LiabilityUpdate::compute(old_exposure_value,
                    pod.collar_bps, new_exp, pod.pledged, actuary);

                    lelu.apply(pod, depository);
                    let dollars = -((reduce as i128).saturating_mul(price as i128)
                                                    .min(i64::MAX as i128) as i64);
                    let pod_exp = pod.exposure;
                    let (pod_cb, pod_ip, pod_cds) = (pod.cost_basis,
                        pod.interest_paid, pod.collar_dollar_seconds);

                    self.update_drawn(dollars);
                    depository.utilisation(dollars);
                    // RAROC: short over-profit liquidation nibble
                    if pod_exp == 0 {
                        self.flush_raroc(pod_cb, pod_ip, pod_cds, 0);
                    }
                    return Ok((dollars, accrued_interest));
                } else {
                    return Err(PithyQuip::Undercollateralised.into());
                }
            }
            let old_exp = exposure;
            let mut drawn_delta_608: i64 = 0;
            // deferred update for the one non-returning branch
            pod.exposure = pod.exposure.saturating_add(amount);
            if amount > 0 && old_exp > 0 {
                // Redeeming short
                if pod.exposure > 0 {
                    amount = amount.saturating_sub(pod.exposure);
                    pod.exposure = 0;
                }
                let amt_frac = if old_exp > 0 {
                    amount as f64 / old_exp as f64
                } else { 0.0 };
                let profit = ((((pod.pledged.saturating_sub(old_exp)) as f64) *
                            amt_frac) as u64).saturating_sub(accrued_interest);

                let pledged_reduce = (pod.pledged as f64 * amt_frac) as i64;
                pod.pledged = pod.pledged.saturating_sub(pledged_reduce.unsigned_abs());

                let new_exp = (pod.exposure.unsigned_abs() as u128)
                                     .saturating_mul(price as u128)
                                    .min(u64::MAX as u128) as u64;

                let lelu = LiabilityUpdate::compute(old_exposure_value,
                pod.collar_bps, new_exp, pod.pledged, actuary);

                lelu.apply(pod, depository);
                let util_change = -((pledged_reduce as i128)
                              .saturating_mul(price as i128)
                                    .clamp(i64::MIN as i128,
                                           i64::MAX as i128) as i64);

                let pod_exp = pod.exposure;
                let (pod_cb, pod_ip, pod_cds) = (pod.cost_basis,
                    pod.interest_paid, pod.collar_dollar_seconds);

                self.update_drawn(util_change);
                depository.utilisation(util_change);

                let transfer_out = (profit as i64).saturating_add(pledged_reduce) as u64;
                // RAROC: short TP - record when position fully closed
                if pod_exp == 0 {
                    self.flush_raroc(pod_cb, pod_ip, pod_cds, transfer_out);
                }
                return Ok((-(profit as i64), transfer_out));
            } else if amount < 0 { // issue short exposure...
                let new_exp = ((-pod.exposure) as u64).saturating_mul(price);
                let post_lev = if pod.pledged > 0 {
                    ((new_exp as u128 * 100) / pod.pledged as u128).min(i64::MAX as u128) as i64
                } else { 100 };
                require!(post_lev <= max_lev, PithyQuip::Undercollateralised);
                let upper = pod.pledged.saturating_add(collar_amt);
                if pod.pledged > new_exp {
                    // ^ not a valid state unless we
                    // are taking profits (don't let
                    // taking on more exposure while
                    // taking profit before TP first)
                    let room = pod.pledged.saturating_sub(new_exp);
                    if self.deposited_quid >= room {
                        let lelu = LiabilityUpdate::compute(old_exposure_value, pod.collar_bps,
                                            new_exp.saturating_add(room), pod.pledged, actuary);

                        let collar_increase = lelu.new_collar_dollars.saturating_sub(lelu.old_collar_dollars);
                        require!(depository.has_capacity(collar_increase), PithyQuip::PoolAtCapacity);

                        self.deposited_quid -= room;
                        pod.exposure = pod.exposure.saturating_sub(
                                (room as f64 / price as f64) as i64);

                        pod.updated = current_time;
                        lelu.apply(pod, depository);
                        self.update_drawn(room as i64);
                        depository.utilisation(room as i64);
                        return Ok((room as i64, accrued_interest));
                } else { return Err(PithyQuip::UnderExposed.into()); }
                } else if new_exp > upper { // to prevent OverExposed,
                // adding positive number shrinks negative exposure...
                    pod.exposure = pod.exposure.saturating_add(
                        (((new_exp.saturating_sub(upper)) as f64) / price as f64) as i64
                    );
                    drawn_delta_608 = -((new_exp.saturating_sub(upper)) as i64);
                    depository.utilisation(drawn_delta_608);
                }
            } pod.updated = current_time; // why wouldn't a depositor just:
            // select the smallest distance, (greater than pod.pledged) in
            // order to maximise potential profit?  maybe they know a big
            // drop is ahead, and they want to minimise the chance they
            // might be liquidated; either way we want to maximise control
            let final_exp = (pod.exposure.unsigned_abs() as u128)
                                    .saturating_mul(price as u128)
                                    .min(u64::MAX as u128) as u64;
            let lelu = LiabilityUpdate::compute(old_exposure_value,
            pod.collar_bps, final_exp, pod.pledged, actuary);

            lelu.apply(pod, depository);
            let _ = &pod; // end borrow before deferred self.update_drawn
            if drawn_delta_608 != 0 { self.update_drawn(drawn_delta_608); }
            return Ok((0, accrued_interest));
        }
        Ok((0, 0)) // open halfway each morning to close halfway each night,
    } // when I touch, it feel like heaven; when I kiss, it kiss to save...
    // I ain't circlin' 'round for saviors, live my life a certain way...
    // I don't need a kind of captain...grabbin' back and I don't beg...
    // don't wanna hear how you are different...or how we are the same.
    // When you gonna show me how you love me: the way to make me stay
    pub fn renege(&mut self, ticker: Option<&str>, mut amount: i64,
        prices: Option<&Vec<u64>>, current_time: i64) -> Result<i64> { // pod: подушка
        // eyes get shut with chains that pillow armies eventually set free like horses
        if ticker.is_none() && amount < 0 { // removing collateral from every position
            // first, we must sort positions by descending amount (without reallocating)
            self.balances.sort_by(|a, b| b.pledged.cmp(&a.pledged));
            let mut deducting: u64 = amount.unsigned_abs();
            // bigger they come, harder they fall and all
            for i in 0..self.balances.len() {
                if deducting == 0 { break; }
                let pod = &mut self.balances[i];
                let price = prices.as_ref()
                                  .and_then(|p| p.get(i).copied())
                                  .ok_or(PithyQuip::NoPrice)?;
                // Use stored collar_bps (default 10% if not set)
                let collar_amt = if pod.collar_bps > 0 {
                    pod.pledged.saturating_mul(pod.collar_bps as u64) / 10_000
                } else {
                    pod.pledged / 10
                };

                let max: u64 = if pod.exposure > 0 {
                    let exposure_value = (pod.exposure as u64).saturating_mul(price);
                    (pod.pledged.saturating_add(collar_amt)).saturating_sub(exposure_value)
                }
                else if pod.exposure < 0 {
                    // we don't have to worry about if
                    // pledged - X% will be worth more
                    // than exposure, as (theoretically)
                    // by that point it's liquidated...
                    let exposure_value = (pod.exposure.unsigned_abs()).saturating_mul(price);
                    let pledged_minus_collar = pod.pledged.saturating_sub(collar_amt);
                    exposure_value.saturating_sub(pledged_minus_collar)
                }
                else { pod.pledged };

                let deducted = max.min(deducting); deducting -= deducted;
                // Accumulate collar-seconds before reducing pledged,
                // so RAROC tracking is consistent with the single-ticker path.
                Depositor::accumulate_collar_seconds(pod, current_time);
                pod.pledged = pod.pledged.saturating_sub(deducted);
                // cost_basis decreases when collateral is removed
                pod.cost_basis = pod.cost_basis.saturating_sub(deducted);
                pod.updated = current_time;
            }   amount = deducting as i64; // < remainder (out & clutch)
        } else { // remove or add dollars to one specific position...
            let padded = Self::pad_ticker(ticker.unwrap());
            if let Some(pod) = self.balances.iter_mut().find(
                                 |pod| pod.ticker == padded) {
                let price = prices.and_then(|p| p.first())
                                    .copied().unwrap_or(0);

                if pod.exposure != 0 && price == 0 {
                    return Err(PithyQuip::NoPrice.into());
                }
                let exposure = (pod.exposure.unsigned_abs()).saturating_mul(price);
                // Use stored collar_bps (or default 10% if not set)
                let collar_amt = if pod.collar_bps > 0 {
                    pod.pledged.saturating_mul(pod.collar_bps as u64) / 10_000
                } else {
                    pod.pledged / 10
                };
                // deducting...we check the max, same as we did above,
                // with a slightly different approach (why not, right?)
                if amount < 0 { require!(pod.pledged >= amount.unsigned_abs(),
                                            PithyQuip::InvalidAmount);
                    if pod.exposure < 0 {
                        // short position
                        if exposure > pod.pledged { // most we can deduct
                            let max: i64 = -(collar_amt.saturating_sub(
                                exposure.saturating_sub(pod.pledged)
                            ) as i64);
                            amount = max.max(amount); // in absolute value
                            // terms this ^ actually returns smaller one...
                        }
                        else if pod.pledged > exposure {
                            // short is in-the-money, so
                            // it doesn't make sense to
                            // decrease collateral as it
                            // would diminish profitability
                            return Err(PithyQuip::TakeProfit.into());
                        }
                    } else if pod.exposure > 0 {
                        let mut max: u64 = 0;
                        // most we can deduct
                        if pod.pledged >= exposure {
                             max = collar_amt.saturating_sub(pod.pledged.saturating_sub(exposure));
                        }
                        else if exposure > pod.pledged {
                            max = collar_amt.saturating_sub(exposure.saturating_sub(pod.pledged));
                        }
                        amount = -((max.min(amount.unsigned_abs())) as i64);
                    }
                    // RAROC: accumulate before remove
                    Depositor::accumulate_collar_seconds(pod, current_time);
                    pod.pledged = pod.pledged.saturating_sub(amount.unsigned_abs());
                    pod.cost_basis = pod.cost_basis.saturating_sub(amount.unsigned_abs());
                } else { // amount is > 0
                    if pod.exposure < 0 {
                        if exposure > pod.pledged { // simple enough here, not
                            // sure why anyone would do this, but it's doable...
                            amount = amount.min(exposure.saturating_sub(pod.pledged) as i64);
                        }
                        else if pod.pledged > exposure {
                            // short is in-the-money; throw as
                            // would be like cheating otherwise
                            // as adding collateral widens the
                            // delta (i.e. profitability, what's
                            // deducted from bank.total_deposits)...
                            return Err(PithyQuip::TakeProfit.into());
                        }
                    } else if pod.exposure > 0 {
                        let mut max: u64 = 0;
                        // most we can deduct
                        if pod.pledged >= exposure {
                            max = collar_amt.saturating_sub(pod.pledged.saturating_sub(exposure));
                        }
                        else if exposure > pod.pledged {
                            max = exposure.saturating_add(collar_amt).saturating_sub(pod.pledged);
                        }   amount = max.min(amount as u64) as i64;
                    }
                    pod.pledged = pod.pledged.saturating_add(amount as u64);
                    pod.cost_basis = pod.cost_basis.saturating_add(amount as u64);
                } amount = 0; self.last_updated = current_time;
            } else { require!(amount > 0, PithyQuip::InvalidAmount);
                if self.balances.len() >= MAX_LEN {
                    return Err(PithyQuip::MaxPositionsReached.into());
                }   self.balances.push(Stock { ticker: padded,
                        pledged: amount as u64, exposure: 0,
                        updated: current_time, rate_bps: 0,
                        collar_bps: 0,
                        cost_basis: amount as u64,
                        interest_paid: 0,
                        collar_dollar_seconds: 0,
                    }); amount = 0;
            }
        } self.balances.retain(|pod| pod.pledged > 10_000_000 || pod.exposure != 0);
        // keep positions that have over $10 pledged OR any exposure...
        // (exposure will shrink via continuous funding until liquidated)
        Ok(amount) // < remainder must be returned if ticker was None...
    }
}
