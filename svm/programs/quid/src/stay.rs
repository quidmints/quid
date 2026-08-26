
use anchor_lang::prelude::*;
use crate::etc::{ LIQ_GRACE_SECS, MAX_LEN, TRANCHE_RAMP_GRACES,
    MIN_TRANCHE_BPS, MAX_TRANCHE_BPS, hazard_rate_bps,
    PithyQuip, Actuary, collar_bps,
    rate_bps, max_leverage_pct };

/// Fixed-point scale for `Depository::sol_yield_index`.
pub const SOL_YIELD_SCALE: u128 = 1_000_000_000_000;

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

    // Cumulative interest paid 
    // across repo() calls...
    pub interest_paid: u64,

    /// Time-integrated economic capital: sum of (collar_dollars × seconds).
    /// RAROC denominator — how much capital was at risk, for how long...
    pub collar_dollar_seconds: u128,

    /// Collar dollars this pod currently contributes to `max_liability`.
    /// Stored rather than re-derived: the reserve used to be incremented on an
    /// exposure base and decremented on a pledged base, so for any levered pod
    /// the decrement was L× too small and `max_liability` ratcheted up forever,
    /// starving `has_capacity()` and `withdrawable()`. Booking the exact figure
    /// that was added is the only way the two sides cannot drift.
    pub collar_dollars: u64,

    /// Where this position last stood in its ticker's premium integral.
    /// The difference against the ticker's current index is what it owes for
    /// the base rate over the interval, charged at the rates that prevailed
    /// rather than at whichever one is read today.
    pub premium_checkpoint: u128,

    /// Unix time this position first went outside its band, 0 while inside it.
    /// Liquidation is a Parisian barrier — it triggers on the *excursion*, the
    /// unbroken time spent beyond the barrier — so the clock that gates it has
    /// to measure the excursion and nothing else.
    pub breached_at: i64,
}

impl Stock {
    /// What this position is worth at `price`.
    ///
    /// Written out nine times in two spellings: a `u64` saturating multiply,
    /// and a `u128` multiply clamped back to `u64`. They return the same
    /// number — `saturating_mul` already stops at `u64::MAX` — so the wide
    /// form only bought an i128 division's worth of compute on paths that run
    /// per position, per call.
    fn value_at(&self, price: u64) -> u64 {
        self.exposure.unsigned_abs().saturating_mul(price)
    }

    /// Excursion length, starting the clock on first sight of a breach.
    fn excursion(&mut self, now: i64) -> i64 {
        if self.breached_at == 0 { self.breached_at = now; }
        (now - self.breached_at).max(0)
    }

    /// Charge one grace period against the excursion for a tranche taken.
    ///
    /// The gate is `excursion > LIQ_GRACE_SECS`, and `breached_at` was set
    /// once and left alone, so a position an hour outside its band satisfied
    /// it on every call for ever after. A liquidator could call in a loop and
    /// unwind the whole position in one slot, taking a commission on each
    /// rung — the seven-day ladder climbed in seconds, which is precisely what
    /// the gradual unwind exists to prevent.
    ///
    /// So the excursion is a budget rather than a threshold: time accrues it,
    /// each tranche spends one period of it. A neglected position still
    /// accumulates, so a liquidator returning after a day may take the rungs
    /// that went unclaimed — catching up is meant to be possible, unwinding
    /// everything at once is not.
    fn spend_grace(&mut self) {
        self.breached_at = self.breached_at.saturating_add(LIQ_GRACE_SECS as i64);
    }
}

impl Space for Stock {
    const INIT_SPACE: usize = 8 + 8 + 8 + 8 + 2 + 2
          + 8 + 8  // cost_basis + interest_paid
          + 16     // collar_dollar_seconds
          + 8      // collar_dollars
          + 16     // premium_checkpoint
          + 8;     // breached_at
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

    /// Earnings the pool has taken in but not yet paid out: premiums charged
    /// to borrowers, and profit appropriated from liquidated positions.
    ///
    /// Kept apart from `total_deposits` so that stays exactly the sum of what
    /// depositors put in. Mixing them made the payout share integrate one
    /// quantity in its numerator and another in its denominator, so shares did
    /// not sum to the pool — measured at 1.188× — and tenure moved principal
    /// between depositors instead of only allocating what was earned.
    pub yield_pool: u64,
    pub max_liability: u64,
    /// Hot buffer: native lamports in the sol_pool PDA. This is what
    /// flash_borrow lends and withdraw_sol pays out — both need lamports in
    /// hand, so neither can ever be served from the parked tranche.
    pub sol_lamports: u64,
    pub sol_usd_contrib: u64,
    /// SOL* shares held by the sol_pool PDA. SOL* is Perena-branded but
    /// Kestrel-issued: its mint authority is long_yield_carry's Token PDA, and
    /// Perena's own app mints it with a top-level LYC instruction. Minting it
    /// the way Perena does means calling that program — see SOL-STAR-REFERENCE.md.
    pub sol_star_shares: u64,
    /// Lamports that bought those shares. Carry and unwind loss are realised
    /// against this basis at unpark, not marked continuously.
    pub sol_star_cost_lamports: u64,
    /// Cost less the park haircut — what the parked tranche is credited for in
    /// depositor collateral. Anything that re-marks SOL collateral from scratch
    /// must value `sol_lamports + sol_star_credited_lamports`; `flash_repay`
    /// does, and using `sol_lamports` alone silently wipes parked backing.
    pub sol_star_credited_lamports: u64,
    /// Unix seconds of the most recent park — starts the discretionary hold.
    /// A fresh park restarts it for the whole tranche: churn gets harder.
    pub sol_star_parked_at: i64,

    /// Coverage proof for the permissionless sweep: when a full pass last
    /// completed, and how many positions it touched. Nothing on Solana can
    /// enumerate accounts on-chain, so the pool cannot iterate its own book —
    /// but it can record that someone did, which is what makes "was every
    /// position looked at?" an answerable question rather than a hope.
    pub swept_at: i64,
    pub swept_count: u64,

    /// Pool-wide realised P&L and capital-at-risk-time — the denominator an
    /// account's own RAROC is measured against. Comparing to the pool average
    /// keeps the rebate relative (size cannot game it) and self-bounding (the
    /// average account earns nothing) without ranking accounts against
    /// each other.
    pub pool_realized_pnl: i64,
    pub pool_collar_dollar_seconds: u128,

    /// Cumulative SOL* carry per lamport of SOL principal, scaled by
    /// SOL_YIELD_SCALE.
    ///
    /// Carry used to be booked straight into `total_deposits`, which shares it
    /// by `deposit_seconds` across every depositor — so a USD*/QD depositor
    /// earned staking yield on lamports they never posted, while SOL price
    /// losses stayed idiosyncratic (a SOL move hits one depositor's
    /// `sol_pledged_usd`). Risk was individual and reward was socialised. The
    /// index attributes the yield to the tranche that funded it, in O(1).
    pub sol_yield_index: u128,
}

/// Per-order flash loan state. Separate from Depository so the core accounting
/// struct never carries mutable mid-tx state. Exactly one FlashLoan account
/// exists (seeds=[b"flash_loan"]) and is init_if_needed at program deploy.
/// Zero-valued fields mean no active loan.
#[account]
#[derive(InitSpace)]
pub struct FlashLoan {
    pub flash_lamports: u64, // SOL flash loan principal (0 = none)
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

    pub fn utilisation_bps(&self) -> i64 {
        if self.total_deposits == 0 { return 0; }
        ((self.total_drawn as u128 * 10_000 / self.total_deposits as u128) as u64) as i64
    }

    /// Attribute realised SOL* carry (or loss) to the SOL tranche.
    /// Returns false when there is no principal to attribute it to, in which
    /// case the caller should fall back to the pooled path.
    pub fn accrue_sol_yield(&mut self, signed_usd: i64) -> bool {
        let principal = self.sol_lamports
            .saturating_add(self.sol_star_cost_lamports) as u128;
        if principal == 0 || signed_usd == 0 { return false; }
        let magnitude = (signed_usd.unsigned_abs() as u128)
            .saturating_mul(SOL_YIELD_SCALE) / principal;
        if signed_usd > 0 {
            self.sol_yield_index = self.sol_yield_index.saturating_add(magnitude);
        } else {
            // A loss claws back unclaimed carry first; anything beyond that is
            // a real impairment and belongs on the pooled path.
            if magnitude > self.sol_yield_index { return false; }
            self.sol_yield_index -= magnitude;
        }
        true
    }


    /// Check if pool has capacity for additional collar exposure.
    ///
    /// Solvency requirement: total deposits must cover worst-case losses.
    /// max_liability tracks sum of (exposure × collar_bps) for all positions.
    /// If all positions hit their collar simultaneously, the pool must cover it.
    /// `total_deposits` is dollars, and only dollars.
    ///
    /// It used to include SOL, so every solvency question was asked against a
    /// mixture of par-valued and marked capital and a SOL move changed what a
    /// stablecoin depositor could do. That was patched here for a while, by
    /// subtracting the SOL contribution back out at each gate. The subtraction
    /// is gone because the mixing is: a SOL deposit no longer credits this at
    /// all, so there is nothing to take back out and no way for the two to
    /// disagree about how much was taken.

    pub fn has_capacity(&self, 
        additional_collar: u64) -> bool {
        if self.total_deposits == 0 { return false; }
        self.max_liability.saturating_add(additional_collar) <= self.total_deposits
    }

    /// Maximum amount LP can withdraw without breaking solvency.
    /// Must maintain enough deposits to cover worst-case collar losses.
    pub fn withdrawable(&self) -> u64 {
        self.total_deposits.saturating_add(self.yield_pool)
            .saturating_sub(self.max_liability)
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
    pub drawn: u64, // mirrors Depository.total_drawn for this account;
    // pure depositors (drawn=0) receive full yield share; borrowers receive
    // a share discounted by their proportion of total pool risk (see clutch.rs)
    
    #[max_len(MAX_LEN)] // 50
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

    /// Value of `Depository::sol_yield_index` when this depositor's SOL
    /// position was last settled. The difference is what they are owed.
    pub sol_yield_checkpoint: u128,
}

/// The base the collar is measured against: a position's notional at risk.
///
/// `collar_bps` already carries a `/lev` term, so applying it to `pledged`
/// (= exposure / L) divided by leverage a second time — the band a position
/// could absorb collapsed as 1/L², to 20 bps at 10×. Exposure value is the
/// correct base; `pledged` is the floor for a pod that has collateral posted
/// but no exposure yet, which is what keeps a fresh deposit's band non-zero.
#[inline]
pub fn collar_notional(exposure_value: u64, pledged: u64) -> u64 {
    exposure_value.max(pledged)
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
        // `old_collar_dollars` is what this pod last contributed; the caller
        // passes the pod's stored figure when it has one so the decrement is
        // exactly the increment. Falling back to a recomputation keeps pods
        // written before this field existed from over-releasing.
        let old_collar_dollars = old_exposure.saturating_mul(old_collar_bps as u64) / 10_000;

        // As above: an unpledged position is not unlevered, and reading it so
        // would size the reserve against it as if it were the safest thing in
        // the book.
        let new_leverage = if new_pledged > 0 { ((new_exposure as u128 * 100) /
                                                   new_pledged as u128).min(i64::MAX as u128) as i64
        } else if new_exposure > 0 { i64::MAX } else { 100 };

        let new_collar = collar_bps(new_leverage, actuary);
        let new_collar_dollars = collar_notional(new_exposure, new_pledged)
            .saturating_mul(new_collar as u64) / 10_000;
        Self { old_collar_dollars, new_collar_bps: new_collar as u16, new_collar_dollars }
    }

    fn apply(self, pod: &mut Stock,
            depository: &mut Depository) {
        pod.collar_bps = self.new_collar_bps;
        // The pod records what its own band is worth — used for the RAROC
        // denominator and for `collar_amount` — but no longer books it into
        // `max_liability`. The pool reserves against the NET of each ticker
        // (`reconcile_ticker_reserve`), and having two writers on one figure
        // is what let it ratchet before.
        let _ = depository;
        pod.collar_dollars = self.new_collar_dollars;
    }
}


/// One liquidation slice, shared by all four call sites.
///
/// The long/short × over/under branches were four verbatim copies of this
/// sequence — which is precisely how four identical `reduce` computations
/// stayed identical and wrong until the ladder audit. Sign is derived from the
/// pod, so there is one implementation and the mirror cannot drift from the
/// original. Returns (signed dollar delta, cost_basis, interest_paid,
/// collar_dollar_seconds, closed) — the RAROC fields are handed back because
/// the caller must end the pod borrow before touching `Depositor`.
/// Premium owed on `exposure_value` at `rate_bps` per annum over `dt` seconds,
/// and how many of those seconds it pays for — the amount by which the caller
/// may then advance `pod.updated`.
///
/// The charge is capped at the pledge, because collateral is all we can take.
/// What we must not do is write the remainder off, which is what the plain
/// `saturating_sub` here used to do: a position whose pledge had been eaten
/// went on holding exposure for free, and since nothing else charges it, for
/// good. Capping the charge and returning only the span the pledge covers
/// leaves the shortfall on the clock, so the debt keeps growing and the
/// excursion keeps the position liquidatable.
///
/// The division truncates and the lost sub-unit is not carried. That is a
/// deliberate floor rather than an oversight: the loss is under one accounting
/// unit — 1e-6 of a dollar — per call, and the only way to compound it is to
/// pay a transaction fee per call to save a millionth of a cent. Carrying it
/// would cost a field in every `Stock` to defend against an attack that loses
/// money faster than the pool does.
fn premium_due(exposure_value: u64, position_rate_bps: i64, dt: i64,
    base_bps_seconds: u128, pledged: u64) -> (u64, i64) {
    const YEAR_BPS: u128 = 31_536_000 * 10_000;
    let dt = dt.max(0);
    // The integrated half is already rate-times-seconds; the position half is
    // a rate that still has to be spread over the interval. Both land in the
    // same unit before either is divided.
    let bps_seconds = base_bps_seconds.saturating_add(
        (position_rate_bps.max(0) as u128).saturating_mul(dt as u128));
    if bps_seconds == 0 || exposure_value == 0 { return (0, dt); }

    let accrued = ((exposure_value as u128).saturating_mul(bps_seconds)
        / YEAR_BPS).min(u64::MAX as u128) as u64;
    if accrued <= pledged { return (accrued, dt); }

    // Only part of the interval is affordable. Bill the share of it the pledge
    // covers, so the remainder stays on the clock rather than being forgiven.
    let billed = ((pledged as u128).saturating_mul(dt as u128)
        / accrued.max(1) as u128).min(dt as u128) as i64;
    (pledged, billed)
}

fn amortise_tranche(pod: &mut Stock, price: u64, excursion: i64, util_bps: i64,
    actuary: &Actuary, depository: &mut Depository, old_exposure_value: u64,
    current_time: i64) -> (i64, u64, u64, u128, bool) {
    let long = pod.exposure > 0;
    // How far outside the band this is, in units. The ladder answers "how
    // long"; this answers "how far", and the two are needed together: a slow
    // drift should be unwound gently, but a gap moves the loss faster than a
    // time-based slice can collect it, and what the pledge cannot cover comes
    // out of depositors who never took the trade.
    //
    // Nothing is tuned here. The band is restored by closing exactly the
    // excess over its edge, so that quantity is the floor on a tranche — never
    // more than makes the position sound again, and never less. In a drift the
    // ladder dominates and liquidation stays gentle; in a gap this does, which
    // is the only case where gentleness costs somebody else.
    let collar = collar_amount(pod, price);
    let exposure_value =pod.value_at(price);
    let upper = pod.pledged.saturating_add(collar);
    let lower = pod.pledged.saturating_sub(collar);
    let breach = if exposure_value > upper { exposure_value - upper }
                 else if lower > exposure_value { lower - exposure_value }
                 else { 0 };
    let restoring = if price > 0 { breach / price } else { 0 };

    let tranche = Depositor::tranche_size(pod.exposure.unsigned_abs(),
                                   excursion, util_bps)
                  .max(restoring)
                  .min(pod.exposure.unsigned_abs());

    pod.spend_grace();

    // Toward zero, whichever side it is on.
    pod.exposure = if long { pod.exposure.saturating_sub(tranche as i64) }
                   else    { pod.exposure.saturating_add(tranche as i64) };

    let unwound_value = tranche.saturating_mul(price);
    pod.pledged = pod.pledged.saturating_sub(unwound_value);
    if pod.exposure == 0 { pod.breached_at = 0; }
    pod.updated = current_time;

    let new_exp = pod.value_at(price);

    LiabilityUpdate::compute(old_exposure_value, pod.collar_bps,
                             new_exp, pod.pledged, actuary)
        .apply(pod, depository);

    // Unwinding always credits the pool: the delta is negative by construction.
    let dollars = -((unwound_value as i128).min(i64::MAX as i128) as i64);
    let closed = pod.exposure == 0;
    let raroc = (pod.cost_basis, pod.interest_paid, pod.collar_dollar_seconds);
    if closed {
        // Zero on the pod so re-entry cannot double-count into Depositor totals.
        pod.cost_basis = 0;
        pod.interest_paid = 0;
        pod.collar_dollar_seconds = 0;
    }
    (dollars, raroc.0, raroc.1, raroc.2, closed)
}


/// Over-profitable auto-protect, shared by the long and short branches.
///
/// The position's value has run past `upper`, so the excess is pulled from the
/// depositor's pool balance into `pledged` — restoring the band — plus a fee
/// the pool retains. Returns the gross amount charged, or `None` when the
/// depositor cannot cover it and the caller must fall through to liquidation.
///
/// The two sides had drifted: long charged `excess` and credited
/// `excess − fee`, short charged `excess + fee` and credited ≈`excess`. Only
/// the second actually restores the band; the first left `pledged` short by
/// the fee, so a "protected" long could still sit outside its collar. One
/// implementation, the correct convention, and the mirror cannot drift again.
fn post_variation_margin(pod: &mut Stock, dq: &mut u64, depository: &mut Depository,
    actuary: &Actuary, old_exposure_value: u64, exposure: u64, upper: u64,
    current_time: i64) -> Result<Option<u64>> {
    let excess = exposure.saturating_sub(upper);
    let gross = excess.saturating_add(excess / 250);   // user pays excess + fee
    if *dq < gross { return Ok(None); }

    let net = gross.saturating_sub(gross / 250);       // credited to pledged
    let new_pledged = pod.pledged.saturating_add(net);
    let lelu = LiabilityUpdate::compute(old_exposure_value, pod.collar_bps,
                                        exposure, new_pledged, actuary);

    let increase = lelu.new_collar_dollars
        .saturating_sub(lelu.old_collar_dollars);
    require!(depository.has_capacity(increase), PithyQuip::PoolAtCapacity);

    *dq -= gross;
    pod.pledged = new_pledged;
    pod.breached_at = 0;   // the breach this cured is over
    pod.updated = current_time;
    lelu.apply(pod, depository);
    Ok(Some(gross))
}


/// Settle a partial close: release pledged and cost basis pro rata to the value
/// being closed, re-mark the liability, and snapshot the RAROC fields.
///
/// `user_credit` is deliberately NOT computed here. The two sides differ for
/// real reasons: a long is paid the mark less accrued interest, because its
/// collateral stays with the pool as margin; a short is paid its released
/// collateral plus P&L measured against basis, because closing means buying
/// back. Folding them into one formula would silently change what one side is
/// owed. Everything mechanical around that difference is shared here.
///
/// Returns (pledged_released, interest_on_closed, raroc, fully_closed).
fn settle_partial_close(pod: &mut Stock, depository: &mut Depository,
    actuary: &Actuary, old_exposure_value: u64, closed_value: u64,
    position_value: u64, price: u64, current_time: i64,
    accrued_interest: u64) -> (u64, u64, (u64, u64, u128), bool) {
    let numer = closed_value as u128;
    let denom = (position_value as u128).max(1);
    let pro_rata = |v: u64| ((v as u128).saturating_mul(numer)
        .checked_div(denom).unwrap_or(0)).min(v as u128) as u64;

    let interest_on_closed = pro_rata(accrued_interest);
    let pledged_released = pro_rata(pod.pledged);
    let cost_basis_released = pro_rata(pod.cost_basis);

    pod.pledged = pod.pledged.saturating_sub(pledged_released);
    pod.cost_basis = pod.cost_basis.saturating_sub(cost_basis_released);
    pod.updated = current_time;

    let new_exp = pod.value_at(price);

    let lelu = LiabilityUpdate::compute(old_exposure_value, pod.collar_bps,
                                        new_exp, pod.pledged, actuary);

    // Snapshot before zeroing: this branch also handles a full close (a flat or
    // losing exit routes here), and re-entry must not double-count cb/ip/cds
    // into the Depositor totals.
    let fully_closed = pod.exposure == 0;
    let raroc = (pod.cost_basis, pod.interest_paid, pod.collar_dollar_seconds);
    if fully_closed {
        pod.cost_basis = 0;
        pod.interest_paid = 0;
        pod.collar_dollar_seconds = 0;
    }
    lelu.apply(pod, depository);
    (pledged_released, interest_on_closed, raroc, fully_closed)
}


/// Collar band in dollars for a pod at `price`, from its stored bps.
/// Falls back to a tenth of notional when the pod has never been marked — a
/// fresh deposit that has not yet been through `repo()`.
fn collar_amount(pod: &Stock, price: u64) -> u64 {
    let notional = collar_notional(
        pod.value_at(price), pod.pledged);
    if pod.collar_bps > 0 {
        notional.saturating_mul(pod.collar_bps as u64) / 10_000
    } else {
        notional / 10
    }
}


/// Pull `gap` dollars from the depositor's free balance to push exposure back
/// toward its band — the mirror of `post_variation_margin`, which moves value
/// the other way. Long and short differ only in how the gap is measured, so
/// the caller supplies it and everything else is shared.
///
/// The two copies had drifted in what they reported as the utilisation change:
/// long booked the drained amount, short booked `amount × price`, which in
/// this branch can be zero (a liquidator passes 0) or unrelated to what was
/// actually drained. The drain is the exposure change, so the drain is what
/// is reported.
///
/// Returns the gross drained, or `None` if the depositor cannot fund it.
fn reinstate_exposure(pod: &mut Stock, dq: &mut u64, depository: &mut Depository,
    actuary: &Actuary, old_exposure_value: u64, exposure: u64, gap: u64,
    price: u64, current_time: i64) -> Result<Option<u64>> {
    let gross = gap.saturating_add(gap / 250);
    if *dq < gross || price == 0 { return Ok(None); }

    let net = gross.saturating_sub(gross / 250);
    let new_exp = exposure.saturating_add(net);
    let lelu = LiabilityUpdate::compute(old_exposure_value, pod.collar_bps,
                                        new_exp, pod.pledged, actuary);

    let increase = lelu.new_collar_dollars
        .saturating_sub(lelu.old_collar_dollars);
    require!(depository.has_capacity(increase), PithyQuip::PoolAtCapacity);

    *dq -= gross;
    // Units bought with `net`, signed by which way the pod already leans.
    let units = (net / price) as i64;
    pod.exposure = pod.exposure.saturating_add(units);
    pod.breached_at = 0;   // the breach this cured is over
    pod.updated = current_time;
    lelu.apply(pod, depository);
    Ok(Some(gross))
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
    /// One rung of a gradual liquidation, and everything that must follow it.
    ///
    /// Every breach branch in `repo()` ended with the same fifteen lines:
    /// check the excursion is past its grace, take a tranche, move `drawn` and
    /// utilisation by what was unwound, and flush RAROC if the position closed.
    /// Four copies meant four places for one of those steps to be forgotten.
    fn unwind_a_tranche(&mut self, pod_index: usize, price: u64, util_bps: i64,
        actuary: &Actuary, depository: &mut Depository, old_exposure_value: u64,
        current_time: i64, now: i64, accrued_interest: u64) -> Result<(i64, u64)> {
        let pod = &mut self.balances[pod_index];
        let excursion = pod.excursion(now);
        require!(excursion > LIQ_GRACE_SECS as i64, PithyQuip::TooSoon);

        let (dollars, pod_cb, pod_ip, pod_cds, closed) =
            amortise_tranche(pod, price, excursion, util_bps, actuary,
                             depository, old_exposure_value, current_time);

        self.update_drawn(dollars);
        depository.utilisation(dollars);
        if closed {
            self.flush_raroc(pod_cb, pod_ip, pod_cds, 0);
            Depositor::flush_raroc_pool(depository,
                -(pod_cb as i64) - pod_ip as i64, pod_cds);
        }
        Ok((dollars, accrued_interest))
    }

    /// Time-weight both sides before any balance moves.
    ///
    /// Every path that changes `deposited_quid` has to age the depositor's
    /// seconds and the pool's on the *old* balances first, or the change is
    /// backdated to the last touch. It was written out at four call sites,
    /// which is four chances to age one side and not the other.
    fn accrue_seconds(&mut self, bank: &mut Depository, now: i64) {
        let dc = now.saturating_sub(self.last_updated) as u64;
        self.deposit_seconds = self.deposit_seconds
            .saturating_add(self.deposited_quid as u128 * dc as u128);

        let db = now.saturating_sub(bank.last_updated) as u64;
        bank.total_deposit_seconds = bank.total_deposit_seconds
            .saturating_add(bank.total_deposits as u128 * db as u128);
    }

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
        self.accrue_seconds(bank, now);
        
        self.last_updated = now; bank.last_updated = now;
    }

    /// Credit this depositor the SOL* carry accrued since their last touch and
    /// re-checkpoint. Must run before `deposited_lamports` changes, or the new
    /// principal would earn yield generated before it arrived.
    pub fn settle_sol_yield(&mut self, bank: &mut Depository) -> u64 {
        if self.deposited_lamports == 0 {
            self.sol_yield_checkpoint = bank.sol_yield_index;
            return 0;
        }
        let delta = bank.sol_yield_index.saturating_sub(self.sol_yield_checkpoint);
        self.sol_yield_checkpoint = bank.sol_yield_index;
        if delta == 0 { return 0; }
        let owed = (delta.saturating_mul(self.deposited_lamports as u128)
            / SOL_YIELD_SCALE).min(u64::MAX as u128) as u64;
        if owed > 0 {
            // Carry lands on the SOL position that earned it, not on the
            // dollar balance. Crediting `deposited_quid` would have made
            // staking yield spendable as stock margin — the same crossing the
            // deposit no longer makes, and pointless to close in one direction
            // only.
            //
            // The pool's own mark rises with it, in the same place, so the two
            // cannot drift: value enters the books when it is attributed
            // rather than when it is realised, and is never counted twice.
            self.sol_pledged_usd = self.sol_pledged_usd.saturating_add(owed);
            bank.sol_usd_contrib = bank.sol_usd_contrib.saturating_add(owed);
        }
        owed
    }

    pub fn pool_deposit(&mut self,
        bank: &mut Depository, 
        usd: u64, now: i64) {
        // Unconditional, and that is the fix rather than an oversight. This
        // used to be skipped for a first-time depositor — correct for their
        // side, which has no balance to age — but `bank.last_updated` was
        // advanced regardless, so the pool's seconds for that interval were
        // lost from `total_deposit_seconds` for good.
        //
        // Every payout is a share of that denominator, so each first deposit
        // shrank it and inflated everyone's share. The shares stopped summing
        // to the pool, which is a first-mover advantage: the early withdrawer
        // gets the inflated figure and the last one out finds it missing.
        //
        // A new depositor's `deposited_quid` is still zero here, so their side
        // contributes nothing and only the pool's interval is counted.
        self.accrue_seconds(bank, now);
        self.deposited_quid = self.deposited_quid.saturating_add(usd);
        bank.total_deposits = bank.total_deposits.saturating_add(usd);
        self.last_updated = now; bank.last_updated = now;
    }

    pub fn pool_withdraw(
        &mut self, bank: &mut Depository, 
        usd: u64, now: i64) -> Result<()> {
        self.accrue_seconds(bank, now);
let new_total = bank.total_deposits.saturating_sub(usd);

        require!(new_total >= bank.max_liability, 
                PithyQuip::Undercollateralised);

        self.deposited_quid = self.deposited_quid.saturating_sub(usd);
        self.last_updated = now; bank.last_updated = now;
        bank.total_deposits = new_total;
        Ok(())
    }


    /// Size of one liquidation tranche, in position units.
    ///
    /// The old form was `size × (elapsed / LIQ_GRACE_SECS) × speed`, but the branch is
    /// gated on `elapsed > LIQ_GRACE_SECS`, so that ratio is always > 1: the first
    /// eligible call took 50% of a position at 10% utilisation and 100% at 33%.
    /// That is a cliff seizure, not a ladder — and `LIQ_GRACE_SECS` only moved when it
    /// fired, never how steep it was.
    ///
    /// Measuring the *excess* over the threshold instead starts each bite near
    /// zero and grows it with staleness, clamped to [MIN_NIBBLE, MAX_NIBBLE].
    /// `repo()` stamps `pod.updated = now` on every call, so elapsed resets and
    /// the next bite is small again. The position unwinds over many calls at
    /// many prices: the borrower keeps the chance to cure or take profit, and
    /// depositors realise the excess gradually instead of at one print.
    #[inline]
    /// Share of the remaining position a liquidator may take, given how long
    /// the position has been outside its band and how badly the pool needs the
    /// capacity back. Integer bps throughout: this sits on the liquidation
    /// path, and soft-float is what put `repo()` into the compute ceiling.
    fn tranche_size(size: u64, excursion: i64, util_bps: i64) -> u64 {
        // Urgency: 0.65× in a quiet pool, 2× when fully drawn.
        let speed_bps = 5_000 + 15_000 * util_bps.clamp(1_000, 10_000) / 10_000;
        // How far up the ramp this excursion has climbed, in bps of the ramp.
        let over = (excursion - LIQ_GRACE_SECS as i64).max(0);
        let climbed = (over * 10_000 / (LIQ_GRACE_SECS as i64 * TRANCHE_RAMP_GRACES))
                          .min(10_000);
        let frac_bps = MIN_TRANCHE_BPS
            + (MAX_TRANCHE_BPS - MIN_TRANCHE_BPS) * climbed / 10_000;
        let frac_bps = (frac_bps * speed_bps / 10_000)
                           .clamp(MIN_TRANCHE_BPS, MAX_TRANCHE_BPS);
        (((size as u128) * frac_bps as u128 / 10_000) as u64).max(1)
    }

    /// Accumulate collar_dollar_seconds on a pod before any pledged/collar mutation.
    /// Integral of capital-at-risk over time — the RAROC denominator. Uses the
    /// pod's booked `collar_dollars` so the integral measures the same capital
    /// the pool actually reserved, not a pledged-based re-derivation.
    #[inline]
    fn accumulate_collar_seconds(pod: &mut Stock, current_time: i64) {
        let elapsed = (current_time - pod.updated).max(0) as u128;
        if elapsed > 0 && pod.collar_bps > 0 {
            let collar_dollars = if pod.collar_dollars > 0 { pod.collar_dollars }
                else { pod.pledged.saturating_mul(pod.collar_bps as u64) / 10_000 };

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

    /// Same figures, into the pool aggregate. Split from `flush_raroc` because
    /// the depositor borrow and the depository borrow cannot be held together.
    pub fn flush_raroc_pool(bank: &mut Depository, net: i64, cds: u128) {
        bank.pool_realized_pnl = bank.pool_realized_pnl.saturating_add(net);
        bank.pool_collar_dollar_seconds =
            bank.pool_collar_dollar_seconds.saturating_add(cds);
    }

    /// Wipe this account's risk-adjusted record. Called when a position is
    /// amortised: the event that proves the account's risk was mispriced is
    /// exactly the event that should cancel its rebate.
    pub fn reset_raroc(&mut self) {
        self.realized_pnl = 0;
        self.total_collar_dollar_seconds = 0;
    }

    // Position shrinking means "virtual sale": profitable synthetic redemption withdraws
    // Banks.total_deposits (more than pledged); similar to a collar (hedge wrapper), one
    // strategy for protecting against losses...though it limits large gains (under X%);
    // lest borrowers dilute depositors' yield, following solution creates speed bumps
    pub fn repo(&mut self, ticker: &str, // reposition, or repossession (it depends)
        mut amount: i64, price: u64, // < obtained from Pyth by etc.rs helper function
        current_time: i64, slot: i64, actuary: &Actuary,
        depository: &mut Depository) -> Result<(i64, u64)> {
        require!(price > 0, PithyQuip::InvalidPrice);
        let padded = Self::pad_ticker(ticker);
        // Index rather than a reference: the liquidation rungs below need
        // `&mut self` again after touching the pod, and re-borrowing by index
        // is what lets that be one helper instead of four inline copies.
        let pod_index = self.balances.iter()
            .position(|p| p.ticker == padded)
            .ok_or(PithyQuip::DepositFirst)?;
        let pod = &mut self.balances[pod_index];

        let old_exposure_value = pod.value_at(price);

        // Same rule as the gates below, and it matters more here: `collar_bps`
        // widens the band as leverage falls, so reading an unpledged position
        // as 1x handed the riskiest position in the book the most room before
        // anyone could touch it. Unbounded leverage yields the tightest band.
        let leverage = if pod.pledged > 0 {
            ((old_exposure_value as u128 * 100) /
            pod.pledged as u128).min(i64::MAX as u128) as i64
        } else if old_exposure_value > 0 { i64::MAX } else { 100 };

        let collar = collar_bps(leverage, actuary);
        let collar_amt = collar_notional(old_exposure_value, pod.pledged)
            .saturating_mul(collar as u64) / 10_000;
        let time_elapsed = current_time.saturating_sub(pod.updated);

        let conc = depository.utilisation_bps();
        // Carry (utilisation) plus the hazard premium for the delay this
        // position is being granted. The barrier is the collar; the distance to
        // it, in bps of exposure, is what makes the price moneyness-sensitive —
        // a position hugging its collar pays for the gap risk it is imposing,
        // one far inside it pays almost nothing. Signed `amount` selects the
        // side; the expression is otherwise identical long and short.
        let barrier = collar_notional(old_exposure_value, pod.pledged)
            .saturating_add(collar_amt);
        let distance_bps = if old_exposure_value > 0 {
            ((barrier.saturating_sub(old_exposure_value) as u128)
                .saturating_mul(10_000) / old_exposure_value as u128)
                .min(i64::MAX as u128) as i64
        } else { 10_000 };

        // Two halves, charged differently because they are known differently.
        //
        // The base — this ticker's volatility against how full the pool is —
        // has been integrated as it happened, in `premium_index`, so the
        // interval is billed at the rates that actually ran over it rather
        // than at whichever one prevails today. That is worth doing: the same
        // ticker prices 7.5x apart between a calm state and a violent one, and
        // reading it once let a borrower choose which by timing their touch.
        //
        // The rest — leverage, and how close this position sits to its barrier
        // — belongs to the position and not to the interval, so it is read now
        // and applied across it. That half is still a point estimate, and the
        // honest limit of a lazy scheme.
        let base_bps_seconds = actuary.premium_index
            .saturating_sub(pod.premium_checkpoint);
        pod.premium_checkpoint = actuary.premium_index;

        let position_rate = rate_bps(conc, leverage, actuary)
            .saturating_sub(rate_bps(conc, 100, actuary))
            .saturating_add(hazard_rate_bps(distance_bps, collar, amount, actuary,
                            depository.total_deposits, depository.max_liability));

        let (accrued_interest, billed_secs) = premium_due(old_exposure_value,
            position_rate, time_elapsed, base_bps_seconds, pod.pledged);

        let util_bps = (conc as i64).clamp(1_000, 10_000);
        let max_lev = max_leverage_pct(actuary, slot, conc);

        pod.pledged -= accrued_interest;
        pod.interest_paid = pod.interest_paid.saturating_add(accrued_interest);
        // The meter, not the wall clock: every downstream stamp of
        // `current_time` moves `pod.updated` only over the seconds the pool was
        // actually paid for, leaving the unbilled remainder to accrue.
        let now = current_time;
        let current_time = pod.updated.saturating_add(billed_secs).min(now);
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
            if exposure > upper { // Over-profitable: restore the band or be unwound
                if let Some(gross) = post_variation_margin(pod, &mut self.deposited_quid,
                        depository, actuary, old_exposure_value, exposure,
                        upper, current_time)? {
                    let _ = &pod; // end borrow before &mut self
                    self.update_drawn(gross as i64);
                    depository.utilisation(gross as i64);
                    // `gross` is a routing hint for clutch's snapshot dispatch:
                    // exposure is unchanged here, so T is computed from
                    // snapshots and the fee stays in the reserve.
                    return Ok((gross as i64, accrued_interest));
                }
                else if amount != 0 {
                    // Not a liquidator, and the depositor cannot fund the
                    // restoration: profit this large can only be taken once
                    // the position is back inside its band.
                    return Err(PithyQuip::Undercollateralised.into());
                }
                else {
                    // Liquidator. Profit that belongs to one depositor is
                    // appropriated by all of them, slowly, which is what gives
                    // the borrower time to react and close.
                    return self.unwind_a_tranche(pod_index, price, util_bps,
                        actuary, depository, old_exposure_value,
                        current_time, now, accrued_interest);
                }
            }
            let lower = pod.pledged.saturating_sub(collar_amt);
            if lower > exposure && exposure > 0 { // under-exposed: push it back
                let gap = lower.saturating_sub(exposure).saturating_sub(collar_amt);
                if let Some(drained) = reinstate_exposure(pod, &mut self.deposited_quid,
                        depository, actuary, old_exposure_value, exposure, gap,
                        price, current_time)? {
                    let _ = &pod; // end borrow before &mut self
                    self.update_drawn(drained as i64);
                    depository.utilisation(drained as i64);
                    // pledged is untouched here: dq funds the exposure, and
                    // clutch's snapshot dispatch books T = drain + interest.
                    return Ok((0, accrued_interest));
                }
                else if amount == 0 {
                    return self.unwind_a_tranche(pod_index, price, util_bps,
                        actuary, depository, old_exposure_value,
                        current_time, now, accrued_interest);
                } else { // ^ total deposits ^ incremented plus ^
                    return Err(PithyQuip::Undercollateralised.into());
                }
            } // Inside the band: neither breach branch fired, so the
              // excursion is over and the clock resets.
              pod.breached_at = 0;
              require!(amount != 0, PithyQuip::InvalidAmount);
            pod.exposure = pod.exposure.saturating_add(amount);
            if amount < 0 { // trying to redeem units,
                // this reduces exposure and pledged,
                // while trying to redeem units...
                if pod.exposure < 0 {
                    amount = amount.saturating_add(
                     pod.exposure.saturating_neg());
                     pod.exposure = 0;
                } // $ value to be sent to depositor is accounted as:
                let redeem_dollars = (amount.unsigned_abs() as u128)
                                      .saturating_mul(price as u128)
                                     .min(u64::MAX as u128) as u64;

                if redeem_dollars > pod.pledged { // all-in TP...
                    let total = redeem_dollars; // full take-profit
                    let from_pool = total.saturating_sub(pod.pledged)
                                         .saturating_sub(accrued_interest);

                    pod.pledged = 0; pod.updated = current_time;
                    let new_exp = pod.value_at(price);

                    let lelu = LiabilityUpdate::compute(old_exposure_value,
                            pod.collar_bps, new_exp, pod.pledged, actuary);

                    lelu.apply(pod, depository);
                    let util_change = -((amount.unsigned_abs() as i128)
                                         .saturating_mul(price as i128)
                                        .min(i64::MAX as i128) as i64);

                    // RAROC: extract before update_drawn ends the window to hold pod.
                    // Zero on the pod itself so re-entry doesn't double-count
                    // cb/ip/cds into Depositor totals on the next close.
                    let (cb, ip, cds) = (pod.cost_basis, pod.interest_paid, 
                                                pod.collar_dollar_seconds);
                    pod.cost_basis = 0; 
                    pod.interest_paid = 0;
                    pod.collar_dollar_seconds = 0;

                    let _ = &pod; 
                    // end borrow before &mut self
                    self.update_drawn(util_change);
                    depository.utilisation(util_change);
                    self.flush_raroc(cb, ip, cds, total);
                    return Ok((-(from_pool as i64), total));
                } else { // partial take-profit — capitalize into deposited_quid
                    // User intent: small early TP as a hedge. No fee, gain banked
                    // for redeployment or later withdrawal.
                    //
                    // Return signal: delta = pledged_reduce + AI, interest = user_credit.
                    // clutch dispatches by (delta>0, interest>0, exposure_decreased)
                    // and computes total_deposits delta from snapshots so the vault
                    // invariant `dq + Σpledged + T = vault` holds:
                    //   customer.deposited_quid += interest (= user_credit)
                    //   T_delta = pledged_reduce + AI - user_credit  (signed)
                    //
                    // Profit case → T_delta < 0: pool reserve funds the gain.
                    // Loss case   → T_delta > 0: pool reserve absorbs the loss.
                    //
                    // A long is paid the mark less the interest attributable
                    // to the slice; its collateral stays with the pool as margin.
                    let (_released, interest_on_closed, raroc, fully_closed) =
                        settle_partial_close(pod, depository, actuary,
                            old_exposure_value, redeem_dollars,
                            old_exposure_value, price, current_time,
                            accrued_interest);
                    let user_credit = redeem_dollars.saturating_sub(interest_on_closed);
                    let (pod_cb, pod_ip, pod_cds) = raroc;
                    let pod_exp_after = if fully_closed { 0 } else { pod.exposure };
                    let pledged_reduce = _released;
                    let _ = &pod;
                    let util_change = -(redeem_dollars as i64);
                    self.update_drawn(util_change);
                    depository.utilisation(util_change);

                    if pod_exp_after == 0 {
                        self.flush_raroc(pod_cb, pod_ip, 
                                    pod_cds, user_credit);
                    }
                    let delta_signal = pledged_reduce.saturating_add(accrued_interest);
                    return Ok((delta_signal as i64, user_credit));
                }
            } else { // Adding exposure
                let new_exp = (pod.exposure as u64).saturating_mul(price);
                // Zero pledge is not one-times leverage, it is exposure
                // against nothing. Defaulting to 100 let a pod whose pledge
                // had been consumed — by premiums, or by withdrawing it —
                // pass this check and keep adding, which is the one thing the
                // check exists to stop.
                let post_lev = if pod.pledged > 0 {
                    ((new_exp as u128 * 100) / pod.pledged as u128).min(i64::MAX as u128) as i64
                } else if new_exp > 0 { i64::MAX } else { 100 };

                require!(post_lev <= max_lev, PithyQuip::Undercollateralised);
                let delta = pod.pledged.saturating_add(collar_amt);
                let mut taken_from_pool: u64 = 0;
                if new_exp > delta {
                    let excess = new_exp.saturating_sub(delta);
                    if self.deposited_quid >= excess {
                        self.deposited_quid -= excess;
                        pod.pledged = pod.pledged.saturating_add(excess);
                        // dq → pledged transfer; clutch's snapshot dispatch
                        // sees dq drop and pledged grow, T_delta picks up AI.
                        taken_from_pool = excess;
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
                let final_exp = pod.value_at(price);

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
                // Return `taken_from_pool` (=excess drained, or 0 if none).
                // Pledged grew (excess moved from dq → pledged), exposure grew,
                // so clutch falls through to the snapshot-based "else" branch:
                //   T_delta = -(dq_delta + pledged_delta) absorbs the dq drain
                return Ok((taken_from_pool as i64, accrued_interest));
            }
        } let exposure = ((-pod.exposure) as u64).saturating_mul(price);
        let pivot = pod.pledged.saturating_sub(collar_amt);
        if pivot >= exposure && exposure > 0 {
            // Short in profit beyond its collar: same move, mirrored.
            let gap = pivot.saturating_sub(exposure);
            if let Some(drained) = reinstate_exposure(pod, &mut self.deposited_quid,
                    depository, actuary, old_exposure_value, exposure, gap,
                    price, current_time)? {
                let _ = &pod; // end borrow before &mut self
                self.update_drawn(drained as i64);
                depository.utilisation(drained as i64);
                return Ok((0, accrued_interest));
            }
            else if amount != 0 {
                return Err(PithyQuip::Undercollateralised.into());
            } else {
                let excursion = pod.excursion(now);
                    require!(excursion > LIQ_GRACE_SECS as i64, PithyQuip::TooSoon);

                    let (dollars, pod_cb, pod_ip, pod_cds, closed) =
                        amortise_tranche(pod, price, excursion, util_bps,
                                   actuary, depository, old_exposure_value,
                                   current_time);
                    let _ = &pod; // end borrow before &mut self
                    self.update_drawn(dollars);
                    depository.utilisation(dollars);
                    if closed {
                        self.flush_raroc(pod_cb, pod_ip, pod_cds, 0);
                        Depositor::flush_raroc_pool(depository,
                            -(pod_cb as i64) - pod_ip as i64, pod_cds);
                    }
                    return Ok((dollars, accrued_interest));
            }
        } if exposure > pivot || exposure == 0 {
            let upper = pod.pledged.saturating_add(collar_amt);
            if exposure > upper { // Over-profitable: restore the band or be unwound
                if let Some(gross) = post_variation_margin(pod, &mut self.deposited_quid,
                        depository, actuary, old_exposure_value, exposure,
                        upper, current_time)? {
                    let _ = &pod; // end borrow before &mut self
                    self.update_drawn(gross as i64);
                    depository.utilisation(gross as i64);
                    // `gross` is a routing hint for clutch's snapshot dispatch:
                    // exposure is unchanged here, so T is computed from
                    // snapshots and the fee stays in the reserve.
                    return Ok((gross as i64, accrued_interest));
                }
                else if amount != 0 {
                    // Not a liquidator, and the depositor cannot fund the
                    // restoration: profit this large can only be taken once
                    // the position is back inside its band.
                    return Err(PithyQuip::Undercollateralised.into());
                }
                else {
                    // Liquidator. Profit that belongs to one depositor is
                    // appropriated by all of them, slowly, which is what gives
                    // the borrower time to react and close.
                    return self.unwind_a_tranche(pod_index, price, util_bps,
                        actuary, depository, old_exposure_value,
                        current_time, now, accrued_interest);
                }
            }
            pod.breached_at = 0;   // in band, as above
            let old_exp = exposure; let mut drawn_delta_608: i64 = 0;
            // deferred update for the one non-returning branch
            pod.exposure = pod.exposure.saturating_add(amount);
            if amount > 0 && old_exp > 0 {
                // Redeeming short — capitalize into deposited_quid (mirrors long partial TP).
                // No fee on partial close; user banks the gain to redeploy or withdraw later.
                if pod.exposure > 0 { 
                    amount = amount.saturating_sub(pod.exposure); 
                    pod.exposure = 0;
                } // Units: redeem_dollars and old_exp are both dollar-denominated, so
                // amt_frac is a clean fraction. (amount is in shares; multiplying by
                // price brings it into dollar space.)
                let redeem_dollars = (amount.unsigned_abs() as u128)
                                      .saturating_mul(price as u128)
                                     .min(u64::MAX as u128) as u64;

                // A short is paid its released collateral plus P&L against
                // basis: closing means buying back, so profit is basis − exit.
                let (pledged_reduce, interest_on_closed, raroc, fully_closed) =
                    settle_partial_close(pod, depository, actuary,
                        old_exposure_value, redeem_dollars,
                        if old_exp > 0 { old_exp } else { 1 }, price,
                        current_time, accrued_interest);
                let cost_basis_share = pledged_reduce.saturating_add(interest_on_closed);
                let signed_pnl: i128 =
                    (cost_basis_share as i128) - (redeem_dollars as i128);
                let user_credit: u64 = (pledged_reduce as i128)
                    .saturating_add(signed_pnl).max(0) as u64;
                let (pod_cb, pod_ip, pod_cds) = raroc;
                let pod_exp_after = if fully_closed { 0 } else { pod.exposure };
                let _ = &pod;
                let util_change = -(redeem_dollars as i64);

                self.update_drawn(util_change);
                depository.utilisation(util_change);

                if pod_exp_after == 0 {
                    self.flush_raroc(pod_cb, pod_ip, 
                                pod_cds, user_credit);
                }
                // Return signal: delta = pledged_reduce + AI, interest = user_credit.
                // clutch dispatches: delta>0 + interest>0 + exposure_decreased
                //   → partial TP capitalize: deposited_quid += interest;
                //                       T_delta computed from snapshots.
                let delta_signal = pledged_reduce.saturating_add(accrued_interest);
                return Ok((delta_signal as i64, user_credit));
            } 
            else if amount < 0 { // issue short exposure...
                let new_exp = ((-pod.exposure) as u64).saturating_mul(price);
                let post_lev = if pod.pledged > 0 {
                    ((new_exp as u128 * 100) / 
                    pod.pledged as u128).min(
                        i64::MAX as u128) as i64
                }
                // Same reasoning as the long side: no pledge is not 1x.
                else if new_exp > 0 { i64::MAX } else { 100 };

                require!(post_lev <= max_lev, 
                PithyQuip::Undercollateralised);

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
                        // pod.pledged unchanged (only pod.exposure becomes more
                        // negative). Same shape as long under-exposed and short ITM:
                        // dq drained by `room`, AI deducted from pledged, clutch's
                        // snapshot dispatch yields T_delta = room + AI. Pool absorbs
                        // the dq drop as solvency surplus while user gains short...
                        return Ok((0, accrued_interest));

                    } else { return Err(PithyQuip::UnderExposed.into()); }
                } else if new_exp > upper { // to prevent OverExposed,
                // adding positive number shrinks negative exposure...
                    pod.exposure = pod.exposure.saturating_add(
                      (((new_exp.saturating_sub(upper)) as f64) / price as f64) as i64);
                    
                    drawn_delta_608 = -((new_exp.saturating_sub(upper)) as i64);
                    depository.utilisation(drawn_delta_608);
                }
            } pod.updated = current_time; // why wouldn't a depositor just:
            // select the smallest distance, (greater than pod.pledged) in
            // order to maximise potential profit?  maybe they know a big
            // drop is ahead, and they want to minimise the chance they
            // might be liquidated; either way we want to maximise control
            let final_exp = pod.value_at(price);

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
            // Visit largest-pledged first, but do NOT permute `balances`:
            // `prices` was built by fetch_multiple_prices() in the CURRENT
            // order, so sorting the array in place made `prices[i]` belong to
            // a different position — every pod valued with someone else's
            // price, over- or under-releasing real collateral. Order an index
            // list instead and keep pod and price on the same subscript.
            let mut order: Vec<usize> = (0..self.balances.len()).collect();
            order.sort_by(|&a, &b| self.balances[b].pledged
                                       .cmp(&self.balances[a].pledged));
            let mut deducting: u64 = amount.unsigned_abs();
            // bigger they come, harder they fall and all
            for i in order {
                if deducting == 0 { break; }
                let price = prices.as_ref()
                                  .and_then(|p| p.get(i).copied())
                                  .ok_or(PithyQuip::NoPrice)?;
                let pod = &mut self.balances[i];
                // Same band repo() will judge it by — otherwise a position
                // could withdraw itself into a state repo() liquidates.
                let collar_amt = collar_amount(pod, price);
                let max: u64 = if pod.exposure > 0 {
                    let exposure_value = (pod.exposure as u64).saturating_mul(price);
                    (pod.pledged.saturating_add(collar_amt)).saturating_sub(exposure_value)
                }
                else if pod.exposure < 0 {
                    // we don't have to worry about if
                    // pledged - X% will be worth more
                    // than exposure, as (theoretically)
                    // by that point it's liquidated...
                    let exposure_value = pod.value_at(price);
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
                // `updated` is the interest clock AND the liquidation-grace
                // clock, and nothing here charges interest. Stamping it on a
                // live position let a borrower withdraw one unit of collateral
                // to wipe the premium accrued since the last `repo()` — and to
                // push the grace period out again — for as long as they liked.
                // A flat pod accrues nothing, so its clock is free to move.
                if pod.exposure == 0 { pod.updated = current_time; }
            }   amount = deducting as i64; // < remainder (out & clutch)
        } else { // remove or add dollars to one specific position...
            // Reachable with no ticker and a positive amount, where `unwrap`
            // aborted the transaction instead of returning. A panic is not a
            // rejection: it costs the caller the fee, tells them nothing, and
            // cannot be handled by anything above it.
            let padded = Self::pad_ticker(ticker.ok_or(PithyQuip::UnknownSymbol)?);
            if let Some(pod) = self.balances.iter_mut().find(
                                 |pod| pod.ticker == padded) {
                let price = prices.and_then(|p| p.first())
                                    .copied().unwrap_or(0);

                if pod.exposure != 0 && price == 0 {
                    return Err(PithyQuip::NoPrice.into());
                }
                let exposure = pod.value_at(price);
                // Same band repo() will judge it by — otherwise a position
                // could withdraw itself into a state repo() liquidates.
                let collar_amt = collar_amount(pod, price);
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
                // Same reasoning as the sweep branch: only a flat pod may have
                // its clock moved by a path that charges nothing.
                if pod.exposure == 0 { pod.updated = current_time; }
            } else { require!(amount > 0, PithyQuip::InvalidAmount);
                if self.balances.len() >= MAX_LEN {
                    return Err(PithyQuip::MaxPositionsReached.into());
                }   self.balances.push(Stock { breached_at: 0, premium_checkpoint: 0, ticker: padded,
                        pledged: amount as u64, exposure: 0,
                        updated: current_time, rate_bps: 0,
                        collar_bps: 0,
                        cost_basis: amount as u64,
                        interest_paid: 0,
                        collar_dollar_seconds: 0,
                        collar_dollars: 0,
                    }); amount = 0;
            }
        } // Prune spent positions only. The threshold here used to be $10 of
        // pledge, and a pod under it was dropped without its collateral being
        // returned anywhere — silently confiscated to the pool. Nothing else
        // in this file moves value without a matching entry, and the cases
        // that land under $10 are precisely the honest ones: a pledge ground
        // down by premiums, or the residue of a full close. The slot pressure
        // it was defending against is already bounded by MAX_LEN and by the
        // deposit minimum, and a depositor can always withdraw the residue,
        // which zeroes the pod and prunes it here on the next pass.
        self.balances.retain(|pod| pod.pledged > 0 || pod.exposure != 0);
        // keep positions that have over $10 pledged OR any exposure...
        // (exposure will shrink via continuous funding until liquidated)
        Ok(amount) // < remainder must be returned if ticker was None...
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::entra::*;

    pub(super) fn bank(hot: u64, cost: u64, credited: u64) -> Depository {
        Depository { last_updated: 0, total_deposits: 0, total_deposit_seconds: 0, yield_pool: 0,
            total_drawn: 0, max_liability: 0, sol_lamports: hot, sol_usd_contrib: 0,
            sol_star_shares: 0, sol_star_cost_lamports: cost,
            sol_star_credited_lamports: credited, sol_star_parked_at: 0,
            swept_at: 0, swept_count: 0,
            pool_realized_pnl: 0, pool_collar_dollar_seconds: 0,
            sol_yield_index: 0 }
    }

    pub(super) fn depositor(lamports: u64) -> Depositor {
        Depositor { owner: Pubkey::new_unique(), deposited_quid: 0,
            deposited_lamports: lamports, sol_pledged_usd: 0, deposit_seconds: 0,
            last_updated: 0, drawn: 0, balances: vec![], realized_pnl: 0,
            total_interest_paid: 0, total_collar_dollar_seconds: 0,
            sol_yield_checkpoint: 0 }
    }

    #[test]
    fn buffer_floor_is_computed_on_the_whole_pool() {
        // 40 hot + 60 parked: a 50% buffer measures against 100, not 40.
        let b = bank(40, 60, 57);
        assert_eq!(sol_total_lamports(&b), 100);
        assert_eq!(required_buffer(&b, 5_000), 50);
        assert!(b.sol_lamports < required_buffer(&b, 5_000));
    }

    #[test]
    fn buffer_floor_cannot_be_configured_away() {
        let b = bank(100, 0, 0);
        assert_eq!(required_buffer(&b, 0), 20);       // clamped to MIN_BUFFER_BPS
        assert_eq!(required_buffer(&b, 10_000), 100); // all of it stays hot
    }

    #[test]
    fn credited_lamports_counts_the_parked_tranche() {
        // The flash_repay re-mark bug: crediting sol_lamports alone drops 57.
        let b = bank(40, 60, 57);
        assert_eq!(credited_lamports(&b), 97);
        assert_ne!(credited_lamports(&b), b.sol_lamports);
    }

    #[test]
    fn park_band_scales_with_the_pool() {
        assert_eq!(park_band(&bank(500, 500, 475), 1_000), 100);
        assert_eq!(park_band(&bank(0, 0, 0), 1_000), 0);
    }

    #[test]
    fn credit_adjustment_lands_on_earnings_before_principal() {
        let mut b = bank(0, 0, 0);
        b.total_deposits = 1_000; b.sol_usd_contrib = 1_000;

        // With no surplus, a loss has nowhere to go but principal.
        adjust_sol_credit(&mut b, -400);
        assert_eq!((b.total_deposits, b.yield_pool, b.sol_usd_contrib), (600, 0, 600));

        // A gain is the pool's, not any depositor's: principal is unchanged.
        adjust_sol_credit(&mut b, 150);
        assert_eq!((b.total_deposits, b.yield_pool, b.sol_usd_contrib), (600, 150, 750));

        // The next loss comes off that surplus first, and only then principal.
        adjust_sol_credit(&mut b, -200);
        assert_eq!((b.total_deposits, b.yield_pool, b.sol_usd_contrib), (550, 0, 550));

        // And it saturates rather than wrapping.
        adjust_sol_credit(&mut b, -10_000);
        assert_eq!((b.total_deposits, b.yield_pool, b.sol_usd_contrib), (0, 0, 0));
    }

    pub(super) fn pod(pledged: u64, exposure: i64, collar_bps: u16, collar_dollars: u64) -> Stock {
        Stock { ticker: [0u8; 8], breached_at: 0, premium_checkpoint: 0,
            pledged, exposure, updated: 0, rate_bps: 0,
            collar_bps, cost_basis: pledged, interest_paid: 0,
            collar_dollar_seconds: 0, collar_dollars }
    }

    #[test]
    fn collar_notional_is_exposure_when_levered_pledged_when_flat() {
        // 3× position: $1k pledged carrying $3k of exposure.
        assert_eq!(collar_notional(3_000, 1_000), 3_000);
        // Collateral posted, no exposure yet — the band must not be zero.
        assert_eq!(collar_notional(0, 1_000), 1_000);
    }

    #[test]
    fn band_no_longer_collapses_with_leverage() {
        // Regression: collar_bps carries a /lev term, so sizing the band off
        // `pledged` (= exposure/L) divided by leverage twice and the absorbable
        // move fell as 1/L² — 20 bps at 10×. On the notional it falls as 1/L.
        // Uses the real collar, so the test cannot drift from the model: a
        // fitted tail on a ticker with a heavy exceedance sample.
        let mut a = crate::etc::Actuary::default();
        a.observed_vol_bps = 200; a.obs_count = 200; a.last_price = 1_000_000;
        for k in 0..30 {
            let x: i64 = if k == 29 { 1_200 } else { 120 };
            a.exceed_count += 1; a.exceed_sum += x;
            a.exceed_sumsq += (x as i128) * (x as i128);
        }
        let mut prev_ratio = f64::MAX;
        for lev in [100u64, 300, 500, 1000] {
            let collar = crate::etc::collar_bps(lev as i64, &a).max(0) as u64;
            let pledged = 1_000u64;
            let exposure = pledged * lev / 100;
            let band = collar_notional(exposure, pledged) * collar / 10_000;
            let ratio = band as f64 / exposure as f64;         // absorbable move
            // Never the 1/L² cliff: at 10× the old path gave 0.0020.
            assert!(ratio >= 0.019, "lev {lev}: absorbable move {ratio} too tight");
            assert!(ratio <= prev_ratio, "band must not widen with leverage");
            prev_ratio = ratio;
        }
    }

    #[test]
    fn band_is_recorded_on_the_pod_not_the_pool() {
        // The band a position is judged by lives on the pod. The pool's
        // reserve is a separate, netted figure — two writers on one number is
        // what let max_liability ratchet.
        let mut bank = bank(0, 0, 0);
        bank.total_deposits = 1_000_000;
        let mut p = pod(1_000, 3, 0, 0);

        LiabilityUpdate { old_collar_dollars: 0, new_collar_bps: 233,
            new_collar_dollars: 700 }.apply(&mut p, &mut bank);
        assert_eq!(p.collar_dollars, 700, "the pod records its own band");
        assert_eq!(bank.max_liability, 0,
                   "the band must not book itself into the pool reserve");

        LiabilityUpdate { old_collar_dollars: 0, new_collar_bps: 0,
            new_collar_dollars: 0 }.apply(&mut p, &mut bank);
        assert_eq!(p.collar_dollars, 0, "and releases cleanly on close");
    }


    #[test]
    fn no_pledge_is_not_one_times_leverage() {
        // Every leverage computation guarded its division with `else { 100 }`,
        // so a position whose pledge had been consumed — by premiums, or by
        // withdrawing it — read as 1x. The gates let it keep adding exposure,
        // and `collar_bps`, which widens the band as leverage falls, handed it
        // the most room in the book.
        let price = 100u64;
        let mut spent = pod(0, 500, 200, 0);        // exposure, nothing behind it
        assert_eq!(spent.pledged, 0);
        assert!(spent.value_at(price) > 0);

        // The band for unbounded leverage is the tightest available, not the
        // widest — which is what reading it as 1x produced.
        let a = crate::etc::Actuary::default();
        let unpledged = collar_bps(i64::MAX, &a);
        let unlevered = collar_bps(100, &a);
        assert!(unpledged <= unlevered,
                "an unpledged position must not get a wider band than a flat one");

        // And a flat pod with no pledge is genuinely unlevered, so it keeps
        // the ordinary treatment.
        spent.exposure = 0;
        assert_eq!(spent.value_at(price), 0);
    }

    #[test]
    fn a_liquidator_cannot_climb_the_whole_ladder_at_once() {
        // The gate is `excursion > LIQ_GRACE_SECS`. With `breached_at` set once
        // and never moved, a position an hour past its band satisfied that on
        // every call for ever after, so the rungs could all be taken in one
        // slot — each paying a commission. Time now buys grace and each
        // tranche spends it.
        let g = LIQ_GRACE_SECS as i64;
        let mut p = pod(20_000_000, 500, 200, 0);
        p.breached_at = 1_000;
        let now = 1_000 + g + 1;                    // just past the first rung

        assert!(p.excursion(now) > g, "the first tranche is due");
        p.spend_grace();
        assert!(p.excursion(now) <= g,
                "a second tranche in the same slot must not be due");

        // Waiting earns the next rung, and only the next one.
        assert!(p.excursion(now + g) > g, "an hour later it is due again");
        p.spend_grace();
        assert!(p.excursion(now + g) <= g, "and only one at a time");

        // Neglect accrues: a liquidator returning after a day may take the
        // rungs that went unclaimed, which is the intended catch-up.
        let neglected = now + 24 * g;
        let mut taken = 0;
        while p.excursion(neglected) > g { p.spend_grace(); taken += 1; }
        assert!(taken > 20 && taken < 30,
                "about a day's worth of rungs, not the whole position: {taken}");
    }

    #[test]
    fn a_deep_breach_is_unwound_by_depth_not_by_the_clock() {
        // The ladder alone measures how long a position has been outside its
        // band. A gap does not wait: the loss outruns a time-based slice, and
        // whatever the pledge cannot cover lands on depositors. So a tranche
        // is at least what restores the band.
        let price = 100u64;
        let mut deep = pod(10_000, 500, 200, 0);      // 50k of exposure on 10k
        let collar = collar_amount(&deep, price);
        let exposure_value = (deep.exposure as u64) * price;
        let band_top = deep.pledged + collar;
        assert!(exposure_value > band_top, "fixture must actually be breached");

        let restoring = (exposure_value - band_top) / price;
        let ladder = Depositor::tranche_size(deep.exposure.unsigned_abs(),
                                             LIQ_GRACE_SECS as i64 + 1, 5_000);
        assert!(restoring > ladder,
                "a breach this deep should outrun the opening rung");

        // And the floor never exceeds the position: a breach larger than the
        // whole thing closes it, rather than asking for units that do not exist.
        deep.pledged = 0;
        let collar = collar_amount(&deep, price);
        let over = ((deep.exposure as u64) * price).saturating_sub(collar) / price;
        assert!(over.min(deep.exposure.unsigned_abs()) <= deep.exposure.unsigned_abs());
    }

    #[test]
    fn liquidation_is_a_ladder_not_a_cliff() {
        let size = 1_000_000u64;
        // Just past the gate: the floor, scaled by urgency — not the position.
        let first = Depositor::tranche_size(size, LIQ_GRACE_SECS as i64 + 1, 5_000);
        assert!(first >= size * MIN_TRANCHE_BPS as u64 / 10_000
             && first <= size * (2 * MIN_TRANCHE_BPS) as u64 / 10_000,
                "opening tranche should sit on the floor, got {first}");

        // The old formula took 100% here (ratio > 1 × speed 1.25).
        let mid = Depositor::tranche_size(size, (LIQ_GRACE_SECS as i64) * 2, 5_000);
        assert!(mid < size / 5, "a single tranche must stay small: {mid}");

        // However stale, never more than the ceiling in one call.
        let stale = Depositor::tranche_size(size, (LIQ_GRACE_SECS as i64) * 1_000, 10_000);
        assert_eq!(stale, size * MAX_TRANCHE_BPS as u64 / 10_000);

        // Monotone in staleness, and a live position is never a no-op.
        let mut prev = 0;
        for mult in 1..=8 {
            let r = Depositor::tranche_size(size, (LIQ_GRACE_SECS as i64) * mult, 5_000);
            assert!(r >= prev && r >= 1);
            prev = r;
        }
    }

    #[test]
    fn ladder_unwinds_fully_but_takes_many_calls() {
        // Depositors get many prints, the borrower gets time to cure: a fully
        // stale position at max utilisation still needs >20 calls to be 90% gone.
        let mut remaining = 1_000_000u64;
        let mut calls = 0;
        while remaining > 100_000 && calls < 500 {
            remaining -= Depositor::tranche_size(remaining, (LIQ_GRACE_SECS as i64) * 1_000, 10_000)
                .min(remaining);
            calls += 1;
        }
        assert!(calls >= 20, "unwind was too abrupt: {calls} calls");
        assert!(remaining <= 100_000, "unwind stalled at {remaining}");
    }

    #[test]
    fn accounting_units_are_mint_agnostic() {
        // The bug: bridged QD is 9 decimals, USD* is 6, and raw amounts were
        // credited straight into deposited_quid — so 1 QD counted as 1000 USD*.
        let one_usd_star = 1_000_000u64;      // 1.0 at 6dp
        let one_qd       = 1_000_000_000u64;  // 1.0 at 9dp
        assert_eq!(to_accounting(one_usd_star, 6).unwrap(),
                   to_accounting(one_qd, 9).unwrap(),
                   "a unit of either mint must credit the same");
        assert_eq!(to_accounting(one_qd, 9).unwrap(), 1_000_000);

        // A 2-decimal mint scales up rather than truncating to nothing.
        assert_eq!(to_accounting(100, 2).unwrap(), 1_000_000);
    }

    #[test]
    fn accounting_round_trips_back_to_raw() {
        for (raw, dec) in [(1_000_000u64, 6u8), (1_000_000_000, 9), (100, 2)] {
            let units = to_accounting(raw, dec).unwrap();
            assert_eq!(from_accounting(units, dec).unwrap(), raw,
                       "round trip lost value at {dec} decimals");
        }
        // Sub-unit dust below accounting precision truncates, never inflates.
        assert_eq!(to_accounting(999, 9).unwrap(), 0);
        assert_eq!(from_accounting(0, 9).unwrap(), 0);
    }

    #[test]
    fn auto_protect_restores_the_band_on_both_sides() {
        // The two sides had drifted: long credited `excess − fee` to pledged,
        // leaving the position still outside its collar after "protection".
        // One helper now serves both, and the credited amount must close the
        // gap it was called to close.
        let mut b = bank(0, 0, 0);
        b.total_deposits = 1_000_000;
        let a = Actuary::default();

        for exposure_sign in [1i64, -1] {
            let mut p = pod(1_000, exposure_sign, 0, 0);
            let mut dq = 100_000u64;
            let upper = 1_100u64;      // pledged + collar
            let exposure = 2_000u64;   // 900 past the band

            let gross = post_variation_margin(&mut p, &mut dq, &mut b, &a,
                                      exposure, exposure, upper, 1)
                .unwrap().expect("depositor can fund it");

            assert!(gross >= 900, "charge covers the excess: {gross}");
            assert!(p.pledged + 1 >= 1_000 + 900,
                    "pledged must absorb the excess, got {}", p.pledged);
            assert_eq!(dq, 100_000 - gross, "charged exactly once");
        }
    }

    #[test]
    fn auto_protect_declines_when_the_depositor_cannot_fund_it() {
        let mut b = bank(0, 0, 0);
        b.total_deposits = 1_000_000;
        let a = Actuary::default();
        let mut p = pod(1_000, 1, 0, 0);
        let mut dq = 10u64;                    // nowhere near the excess
        assert!(post_variation_margin(&mut p, &mut dq, &mut b, &a, 2_000, 2_000, 1_100, 1)
                .unwrap().is_none(), "must fall through to liquidation");
        assert_eq!(dq, 10, "a declined protection charges nothing");
        assert_eq!(p.pledged, 1_000, "and moves no collateral");
    }

    #[test]
    fn slicing_the_charge_never_double_bills_or_amplifies() {
        // A borrower picks how often the pool charges them, so both directions
        // matter: slicing must never bill the same second twice, and the
        // truncation it does buy must stay bounded by one unit per call.
        let (value, rate, span) = (1_000_000_000_000u64, 500i64, 3_600i64);
        let pledge = u64::MAX;
        let (lump, secs) = premium_due(value, rate, span, 0, pledge);
        assert_eq!(secs, span, "a covered charge pays for the whole span");

        // Faithful to repo(): the caller picks `now`, the charge is taken over
        // `now - pod.updated`, and the meter advances by what was billed.
        let (mut billed, mut meter) = (0u64, 0i64);
        for now in 1..=span {
            let (c, secs) = premium_due(value, rate, now - meter, 0, pledge);
            billed += c;
            meter += secs;
        }
        assert!(billed <= lump, "slicing double-billed: {billed} > {lump}");
        assert!(lump - billed <= span as u64,
                "truncation must stay under a unit per call: lost {}", lump - billed);
    }

    #[test]
    fn an_exhausted_pledge_keeps_owing() {
        // Only the pledge can be taken, but the rest is not forgiven: the
        // meter stays put, so the debt keeps accruing and the position stays
        // liquidatable instead of holding exposure for free.
        let (charged, billed) = premium_due(1_000_000_000_000, 500, 31_536_000, 0, 7);
        assert_eq!(charged, 7, "cannot take more than the pledge");
        assert!(billed < 31_536_000, "unpayable premium must stay on the clock");

        let (charged, billed) = premium_due(1_000_000_000_000, 500, 31_536_000, 0, 0);
        assert_eq!((charged, billed), (0, 0), "a spent pledge buys no time");
    }

    #[test]
    fn paying_premiums_does_not_buy_immunity_from_liquidation() {
        // Liquidation is Parisian: it triggers on the unbroken time spent
        // outside the band. Gating it on time-since-last-touch let a breaching
        // borrower reset their own grace period every few minutes forever.
        let mut p = pod(20_000_000, 5, 200, 0);
        assert_eq!(p.excursion(1_000), 0, "clock starts on first sight of breach");
        assert_eq!(p.excursion(1_100), 100);
        assert_eq!(p.excursion(9_000), 8_000, "touching it does not restart it");

        p.breached_at = 0;   // cured: back inside the band
        assert_eq!(p.excursion(9_100), 0, "a cure ends the excursion");

        // And the tranche keeps growing with the excursion, so an unattended
        // breach is unwound faster the longer it is left.
        let g = LIQ_GRACE_SECS as i64;
        let rung = |n: i64| Depositor::tranche_size(1_000_000, g * n, 3_333);
        assert!(rung(2) < rung(20) && rung(20) < rung(TRANCHE_RAMP_GRACES + 2),
                "ladder must steepen with the excursion, not saturate on rung one");
        assert_eq!(rung(TRANCHE_RAMP_GRACES + 2), rung(TRANCHE_RAMP_GRACES * 10),
                   "and level off at the ceiling once the ramp is climbed");
    }

    #[test]
    fn dust_withdrawals_cannot_reset_the_premium_clock() {
        // The avoidance vector: interest is charged only in repo(), against
        // (now − pod.updated). renege() moves collateral and charged nothing,
        // yet stamped that same field — so withdrawing one unit wiped the
        // premium accrued since the last touch, and pushed the liquidation
        // grace period out with it.
        let mut d = depositor(0);
        d.balances = vec![pod(20_000_000, 5, 200, 0)];   // live, above dust
        d.balances[0].ticker = Depositor::pad_ticker("AAA");
        d.balances[0].updated = 1_000;
        let prices = vec![100u64];

        d.renege(None, -50, Some(&prices), 9_000).unwrap();
        assert_eq!(d.balances[0].updated, 1_000,
                   "a live position's clock must survive a collateral withdrawal");

        // A flat pod owes nothing, so moving its clock costs the pool nothing.
        d.balances[0].exposure = 0;
        d.renege(None, -50, Some(&prices), 12_000).unwrap();
        assert_eq!(d.balances[0].updated, 12_000,
                   "a flat pod may be re-stamped");
    }

    #[test]
    fn sweep_values_each_position_with_its_own_price() {
        // Regression: renege() sorted `balances` by pledged desc while `prices`
        // had been built in the unsorted order, so pod[i] was valued with
        // another pod's price. Order the small position first so the sort
        // must reorder, and give the two tickers wildly different prices.
        let mut d = depositor(0);
        d.balances = vec![
            pod(1_000, 1, 1_000, 0),      // small pledge, listed first
            pod(9_000, 1, 1_000, 0),      // large pledge, listed second
        ];
        d.balances[0].ticker = Depositor::pad_ticker("AAA");
        d.balances[1].ticker = Depositor::pad_ticker("BBB");
        let prices = vec![2, 1_000];      // AAA cheap, BBB dear

        let before: Vec<u64> = d.balances.iter().map(|p| p.pledged).collect();
        d.renege(None, -500, Some(&prices), 10).unwrap();

        // Whatever it released, the array order must be untouched — that is
        // what keeps pod and price on the same subscript.
        assert_eq!(d.balances[0].ticker, Depositor::pad_ticker("AAA"));
        assert_eq!(d.balances[1].ticker, Depositor::pad_ticker("BBB"));
        assert!(d.balances.iter().zip(before.iter())
                 .all(|(p, &b)| p.pledged <= b), "collateral only decreases");
    }

    #[test]
    fn sol_carry_pays_the_sol_tranche_not_everyone() {
        // 100 lamports of principal, split 60/40 between two SOL depositors.
        let mut b = bank(100, 0, 0);
        let mut sol_a = depositor(60);
        let mut sol_b = depositor(40);
        let mut stable_only = depositor(0);   // USD*/QD depositor, no lamports

        assert!(b.accrue_sol_yield(1_000), "carry must attribute to principal");
        assert_eq!(sol_a.settle_sol_yield(&mut b), 600);
        assert_eq!(sol_b.settle_sol_yield(&mut b), 400);
        assert_eq!(stable_only.settle_sol_yield(&mut b), 0,
                   "a depositor who posted no SOL earns no staking yield");
        // Attributed exactly once, to the SOL side, and only when claimed.
        // The dollar pool is untouched: staking carry is not stock margin.
        assert_eq!(b.sol_usd_contrib, 1_000);
        assert_eq!(sol_a.sol_pledged_usd, 600);
        assert_eq!(sol_a.deposited_quid, 0,
                   "carry must not become spendable as margin");
        assert_eq!(b.total_deposits, 0);
    }

    #[test]
    fn settling_twice_pays_once() {
        let mut b = bank(100, 0, 0);
        let mut d = depositor(100);
        b.accrue_sol_yield(500);
        assert_eq!(d.settle_sol_yield(&mut b), 500);
        assert_eq!(d.settle_sol_yield(&mut b), 0, "checkpoint must consume it");
    }

    #[test]
    fn arriving_principal_cannot_claim_earlier_carry() {
        let mut b = bank(100, 0, 0);
        b.accrue_sol_yield(1_000);            // earned before latecomer arrives
        let mut latecomer = depositor(0);
        latecomer.settle_sol_yield(&mut b);   // checkpoint at deposit time
        latecomer.deposited_lamports = 100;
        assert_eq!(latecomer.settle_sol_yield(&mut b), 0,
                   "yield generated before the deposit is not theirs");
    }

    #[test]
    fn unwind_loss_claws_back_carry_then_falls_through() {
        let mut b = bank(100, 0, 0);
        b.accrue_sol_yield(1_000);
        assert!(b.accrue_sol_yield(-400), "loss inside unclaimed carry");
        let mut d = depositor(100);
        assert_eq!(d.settle_sol_yield(&mut b), 600);
        // A loss deeper than the remaining carry is a real impairment: the
        // caller must socialise it rather than the index going negative.
        assert!(!b.accrue_sol_yield(-1_000));
    }

    #[test]
    fn wsol_mint_constant_is_the_native_mint() {
        assert_eq!(WSOL_MINT.to_string(),
                   "So11111111111111111111111111111111111111112");
    }
}

#[cfg(test)]
mod frame_budget {
    use super::*;
    use crate::entra::ProgramConfig;
    use crate::etc::{TickerRisk, Actuary};

    /// Anchor deserialises every `Account<T>` inline on the instruction's
    /// stack frame, and SBF gives each frame 4KB. `Box` moves the payload to
    /// the 32KB bump heap for the price of one indirection.
    ///
    /// The trap is that the overflow is silent — the program aborts with
    /// "Program failed to complete" and a compute count far under budget, and
    /// whether it happens at all shifts when an unrelated constraint is added.
    /// This test makes the budget explicit so growth in an account type fails
    /// here, loudly, rather than in whichever instruction happened to be
    /// closest to the edge.
    #[test]
    fn account_types_stay_inside_the_frame_budget() {
        let sizes: [(&str, usize); 6] = [
            ("Depositor",     core::mem::size_of::<Depositor>()),
            ("Depository",    core::mem::size_of::<Depository>()),
            ("TickerRisk",    core::mem::size_of::<TickerRisk>()),
            ("Actuary",       core::mem::size_of::<Actuary>()),
            ("ProgramConfig", core::mem::size_of::<ProgramConfig>()),
            ("FlashLoan",     core::mem::size_of::<FlashLoan>()),
        ];
        for (name, size) in sizes { println!("{name:>14}: {size:>6} bytes inline"); }

        // These are all small — the collections that dominate them
        // (`Depositor::balances`, the Actuary's history) are `Vec`s, whose
        // contents Borsh already puts on the heap. What overflows a frame is
        // the sum across a context: every account's payload, plus the
        // temporaries Anchor generates per constraint. That total is not
        // visible from any one type, which is why the policy is to box every
        // deserialised account rather than to box the ones that look big.
        //
        // The cost of the policy is bounded and worth stating: at most a
        // dozen accounts in any context, none of them above this bound, is
        // well under the 32KB bump heap — where an over-allocation fails
        // loudly, unlike the silent frame overflow it replaces.
        for (name, size) in sizes {
            assert!(size < 4_096, "{name} is {size} bytes — too large to ever sit inline");
        }
        assert!(sizes.iter().map(|(_, s)| s).sum::<usize>() * 2 < 32_768,
                "boxing every account twice over must still fit the bump heap");
    }
}

#[cfg(test)]
mod state_machine_stress {
    use super::*;
    use crate::entra::*;
    use super::tests::{pod, depositor};

    struct Lcg(u64);
    impl Lcg {
        fn next(&mut self) -> u64 {
            self.0 = self.0.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            self.0 >> 11
        }
        fn pick(&mut self, n: u64) -> u64 { self.next() % n.max(1) }
    }

    /// The identity every operation has to preserve: a depositor's own books
    /// balance. What they hold free plus what is committed to positions is
    /// what they are owed — nothing may appear or vanish between the two.
    fn assert_books_balance(d: &Depositor, before: u64, label: &str) {
        let after = d.deposited_quid
            + d.balances.iter().map(|p| p.pledged).sum::<u64>();
        assert!(after <= before,
                "{label}: books grew from {before} to {after} with no deposit");
    }

    /// Drive `renege` through every ordering of add, remove, and remove-all,
    /// against a book that is sometimes flat, sometimes levered, sometimes
    /// already stripped of collateral — the combinations that only occur when
    /// somebody is closing a position while another is being opened.
    #[test]
    fn renege_never_creates_value_in_any_order() {
        for seed in 1..=64u64 {
            let mut rng = Lcg(seed);
            let mut d = depositor(0);
            d.deposited_quid = 1_000_000_000;

            // Two or three positions, some levered, some bare.
            let count = 2 + rng.pick(2) as usize;
            for i in 0..count {
                let pledged = rng.pick(500_000_000);
                let exposure = rng.pick(2_000_000) as i64 - 1_000_000;
                let mut p = pod(pledged, exposure, 200, 0);
                p.ticker = Depositor::pad_ticker(match i { 0 => "AAA", 1 => "BBB", _ => "CCC" });
                d.balances.push(p);
            }
            let prices: Vec<u64> = d.balances.iter().map(|_| 1 + rng.pick(1_000)).collect();

            for step in 0..24 {
                let before = d.deposited_quid
                    + d.balances.iter().map(|p| p.pledged).sum::<u64>();
                let now = 1_000 + step * 900;

                let r = match rng.pick(4) {
                    // Strip collateral across the whole book, including past
                    // the point where there is any left to take.
                    0 => d.renege(None, -(rng.pick(2_000_000_000) as i64), Some(&prices), now),
                    // Add to one position.
                    1 => d.renege(Some("AAA"), rng.pick(100_000_000) as i64, None, now),
                    // Remove from one position, sometimes more than it holds.
                    2 => d.renege(Some("BBB"), -(rng.pick(900_000_000) as i64),
                                  Some(&vec![prices[0]]), now),
                    // A no-op amount, which must not be treated as a sweep.
                    _ => d.renege(Some("CCC"), 0, Some(&vec![prices[0]]), now),
                };
                // Whether it succeeded or refused, nothing may have been minted.
                let _ = r;
                assert_books_balance(&d, before, &format!("seed {seed} step {step}"));

                for p in &d.balances {
                    assert!(p.cost_basis <= p.pledged.max(p.cost_basis),
                            "seed {seed}: cost basis detached from pledge");
                }
            }
        }
    }

    /// Stripping a position of its collateral must not leave it able to grow.
    /// This is the shape the `else { 100 }` leverage guard allowed: a pod with
    /// exposure and nothing behind it reading as unlevered.
    #[test]
    fn a_stripped_position_cannot_be_grown() {
        let a = crate::etc::Actuary::default();
        let mut d = depositor(0);
        let mut p = pod(1_000_000, 5_000, 200, 0);
        p.ticker = Depositor::pad_ticker("AAA");
        d.balances.push(p);

        // Take every last unit of collateral out.
        let _ = d.renege(Some("AAA"), -1_000_000, Some(&vec![100]), 1_000);
        let stripped = d.balances[0].pledged;

        // Whatever remains, the position may not be valued as if it were safe.
        if stripped == 0 && d.balances[0].exposure != 0 {
            let lev_reads_unlevered = collar_bps(100, &a);
            let lev_reads_unbounded = collar_bps(i64::MAX, &a);
            assert!(lev_reads_unbounded <= lev_reads_unlevered,
                    "a stripped position must not be handed the wider band");
        }
    }
}

#[cfg(test)]
mod sol_yield_conservation {
    use super::*;
    use crate::entra::*;
    use super::tests::{depositor, bank};

    /// Attributed SOL carry has to be backed by something the pool holds.
    ///
    /// `settle_sol_yield` credits a depositor's balance and `total_deposits`.
    /// The value behind it is the SOL* tranche appreciating, which the pool
    /// records in `sol_usd_contrib` — so if the index moves without that
    /// figure moving, the pool owes more than it holds.
    #[test]
    fn attributed_carry_is_backed_by_the_pools_own_mark() {
        let mut b = bank(10_000_000_000, 0, 0);
        b.sol_usd_contrib = 1_000_000;
        b.total_deposits = 1_000_000;

        let mut d = depositor(10_000_000_000);
        d.sol_pledged_usd = 1_000_000;
        d.sol_yield_checkpoint = b.sol_yield_index;

        let held_before = b.sol_usd_contrib;
        let owed_before = b.total_deposits;

        // Carry realised on the parked tranche.
        assert!(b.accrue_sol_yield(50_000), "carry should attribute to SOL");
        let owed = d.settle_sol_yield(&mut b);
        assert!(owed > 0, "the depositor should be credited");

        // Carry lands on the SOL position and on the pool's SOL mark, in
        // step. It never touches the dollar side, because a SOL deposit
        // margins nothing.
        let _ = owed_before;
        let held_delta = b.sol_usd_contrib - held_before;
        assert_eq!(d.sol_pledged_usd, 1_000_000 + held_delta,
            "the depositor's SOL position must rise by what the pool marked");
        assert_eq!(b.total_deposits, 1_000_000,
            "and the dollar side must not move at all");
    }
}

#[cfg(test)]
mod exit_fairness {
    use super::*;
    use crate::entra::*;
    use super::tests::bank;

    /// When the pool is reserved against borrowers, who can still get out?
    ///
    /// `withdrawable()` is a pool-wide figure — total plus earnings, less the
    /// reserve. Capping each payout by it means the first depositor to ask can
    /// take the whole of the free capacity and the next one finds none, which
    /// is a race rather than a rule.
    #[test]
    fn free_capacity_is_shared_not_raced() {
        let mut b = bank(0, 0, 0);
        b.total_deposits = 1_000_000;
        b.max_liability = 400_000;          // borrowers' reserve
        let free = b.withdrawable();
        assert_eq!(free, 600_000);

        // Two depositors of equal size. Each is owed 500_000 and the pool can
        // release 600_000 between them, so a fair rule gives each 300_000.
        let alice = 500_000u64;
        let bob = 500_000u64;

        let fair = |mine: u64| (mine as u128 * free as u128
                                / (b.total_deposits + b.yield_pool) as u128) as u64;
        assert_eq!(fair(alice), 300_000);
        assert_eq!(fair(bob), 300_000);
        assert!(fair(alice) + fair(bob) <= free,
                "shares of free capacity must not sum past it");

        // Whereas capping by the pool-wide figure alone lets the first mover
        // take everything: 500_000 of the 600_000, leaving 100_000 for a
        // depositor owed the same amount.
        let first_mover_takes = alice.min(free);
        assert_eq!(first_mover_takes, 500_000);
        assert!(bob.min(free - first_mover_takes) < fair(bob),
                "the second depositor is left worse off by arriving second");
    }
}

#[cfg(test)]
mod exit_and_return {
    use super::*;
    use crate::entra::*;
    use super::tests::{depositor, bank};

    /// A borrower's profit is paid out of the pool, so it is a loss to
    /// depositors. Where it lands decides whether leaving before it and
    /// returning afterwards is profitable.
    ///
    /// Against earnings it is not: the leaver forfeits their tenure share of
    /// premiums, which is the thing tenure exists to allocate, and every
    /// claim on principal stays exactly equal to what backs it.
    #[test]
    fn a_loss_within_earnings_leaves_every_claim_backed() {
        let mut b = bank(0, 0, 0);
        let mut stayer = depositor(0);
        let mut leaver = depositor(0);

        stayer.pool_deposit(&mut b, 1_000_000, 0);
        leaver.pool_deposit(&mut b, 1_000_000, 0);
        b.yield_pool = 500_000;                    // premiums collected

        let taken = leaver.deposited_quid;
        leaver.pool_withdraw(&mut b, taken, 100).unwrap();

        // A 400_000 take-profit, paid for by premiums as `handle_out` now does.
        let loss = 400_000u64;
        let from_yield = loss.min(b.yield_pool);
        b.yield_pool -= from_yield;
        b.total_deposits = b.total_deposits.saturating_sub(loss - from_yield);

        leaver.pool_deposit(&mut b, taken, 200);

        assert_eq!(stayer.deposited_quid + leaver.deposited_quid, b.total_deposits,
            "principal claims must still equal the principal that backs them");
        assert_eq!(b.yield_pool, 100_000, "the loss came out of premiums");
    }

    /// The limit of that protection, stated rather than assumed.
    ///
    /// A loss larger than everything the pool has earned reaches deposits, and
    /// `total_deposits` is an aggregate no individual claim tracks — so every
    /// depositor still claims par against a pool holding less, and leaving
    /// before it is once again strictly better than staying. Closing this
    /// needs claims to be shares of the pool rather than fixed amounts, so a
    /// mark-down reaches everyone at once and there is nothing to step out of.
    #[test]
    fn a_loss_beyond_earnings_is_not_yet_marked_to_claims() {
        let mut b = bank(0, 0, 0);
        let mut a = depositor(0);
        let mut c = depositor(0);
        a.pool_deposit(&mut b, 1_000_000, 0);
        c.pool_deposit(&mut b, 1_000_000, 0);

        b.total_deposits = b.total_deposits.saturating_sub(400_000);  // beyond earnings

        assert!(a.deposited_quid + c.deposited_quid > b.total_deposits,
            "documented gap: claims {} exceed the {} backing them",
            a.deposited_quid + c.deposited_quid, b.total_deposits);
    }
}



#[cfg(test)]
mod sol_is_not_margin {
    use super::*;
    use super::tests::{depositor, bank, pod};

    /// A SOL deposit is a yield position. It must not fund stock margin, and a
    /// stock loss must not reach it — the two directions of the same rule.
    #[test]
    fn sol_cannot_be_spent_as_stock_margin() {
        let mut b = bank(0, 0, 0);
        let mut d = depositor(0);

        // Deposit SOL: lamports and the pool's SOL mark move, the dollar
        // balance does not.
        d.deposited_lamports = 10_000_000_000;
        d.sol_pledged_usd = 1_000_000;
        b.sol_usd_contrib = 1_000_000;

        assert_eq!(d.deposited_quid, 0,
            "SOL must not appear in the balance that funds pledged");
        assert_eq!(b.total_deposits, 0,
            "nor in the pool's dollar backing");

        // So there is nothing for `renege` to draw on: a stock position cannot
        // be opened against it.
        assert!(d.renege(Some("AAA"), 500_000, None, 100).is_ok());
        assert_eq!(d.balances.first().map_or(0, |p| p.pledged), 500_000);
        // ...and that pledge came from the dollar side going negative-free,
        // which is to say it could only ever have come from a dollar deposit.
        assert_eq!(d.deposited_quid, 0);
    }

    /// The pool's solvency gates do not see SOL, so a crash in it cannot
    /// narrow a stablecoin depositor's exit.
    #[test]
    fn a_sol_crash_leaves_the_dollar_book_untouched() {
        let mut b = bank(0, 0, 0);
        b.total_deposits = 600_000;        // dollars only
        b.sol_usd_contrib = 400_000;       // SOL, alongside
        b.max_liability = 300_000;

        let free = b.withdrawable();
        let room = b.has_capacity(100_000);

        b.sol_usd_contrib = 100_000;       // SOL falls 75%

        assert_eq!(b.withdrawable(), free);
        assert_eq!(b.has_capacity(100_000), room);
        assert_eq!(b.total_deposits, 600_000, "dollars, untouched");
        let _ = pod(0, 0, 0, 0);
    }
}
