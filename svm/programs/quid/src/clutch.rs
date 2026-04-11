
use anchor_spl::associated_token::AssociatedToken;
use anchor_spl::token_interface::{ self, Mint,
    TokenAccount, TokenInterface, TransferChecked
};
use anchor_lang::solana_program::{
    program::invoke_signed,
    system_instruction};

use crate::stay::*;
use crate::state::{
    transfer_from_vault,
    transfer_from_vaults,
    ProgramConfig, USD_STAR,
    SOL_POOL_SEED, FLASH_REPAY_DISC,
};
use crate::etc::{ get_account,
    PithyQuip, fetch_price,
    fetch_multiple_prices,
    TickerRisk, fee_bps
};
use anchor_lang::prelude::*;
use crate::entra::{
    collar_adjusted_usd
};

#[derive(Accounts)]
#[instruction(ticker: String)]
pub struct Liquidate<'info> {
    /// CHECK: raw account only to validate ownership
    pub liquidating: AccountInfo<'info>,

    #[account(mut)]
    pub liquidator: Signer<'info>,

    #[cfg_attr(feature = "mainnet", account(
        constraint = config.registered_mints.contains(&mint.key())
            @ PithyQuip::InvalidMint
    ))]
    pub mint: InterfaceAccount<'info, Mint>,

    #[account(seeds = [b"program_config"], bump = config.bump)]
    pub config: Account<'info, ProgramConfig>,

    #[account(mut, seeds = [b"depository"], bump)]
    pub bank: Box<Account<'info, Depository>>,

    #[account(mut, seeds = [b"vault", mint.key().as_ref()], bump)]
    pub bank_token_account: InterfaceAccount<'info, TokenAccount>,

    #[account(mut, seeds = [liquidating.key().as_ref()], bump)]
    pub customer_account: Account<'info, Depositor>,

    #[account(init_if_needed, payer = liquidator,
        space = 8 + Depositor::INIT_SPACE,
        seeds = [liquidator.key().as_ref()], bump)]
    pub liquidator_depositor: Account<'info, Depositor>,

    #[account(mut, seeds = [b"risk",
    ticker.as_bytes()], bump = ticker_risk.bump)]
    pub ticker_risk: Account<'info, TickerRisk>,

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

    Banks.total_deposits += interest;
    interest = (delta.abs() as u64 / 250) as u64;
    let pos = customer.balances.iter().find(|p|
        std::str::from_utf8(&p.ticker).unwrap()
                  .trim_end_matches('\0') == t);

    let (prior_exposure, leverage) = if let Some(p) = pos {
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
        Banks.total_deposits += delta as u64;
        risk.actuary.record_activity(prior_exposure, -delta,
        leverage, slot, delta, Banks.total_deposits as i64);
    } else if delta > 0 {
        // Position was saved from liquidation
        // before we try to deduct from depository
        // attempt to salvage amount from depositor
        let prices = fetch_multiple_prices(&customer.balances,
                                    ctx.remaining_accounts)?;

        let remainder = customer.renege(None, -delta as i64,
                          Some(&prices), right_now)? as i64;
        customer.deposited_quid += (delta - remainder) as u64;

        Banks.total_deposits -= remainder as u64;
        risk.actuary.record_activity(prior_exposure, delta,
        leverage, slot, delta, Banks.total_deposits as i64);
    }
    let liquidator_dep = &mut ctx.accounts.liquidator_depositor;
    if liquidator_dep.owner == Pubkey::default() {
        liquidator_dep.owner = ctx.accounts.liquidator.key();
        liquidator_dep.last_updated = right_now;
    } else { // Update deposit_seconds before adding comission funds
        let liq_time_delta = right_now - liquidator_dep.last_updated;
        liquidator_dep.deposit_seconds += (liquidator_dep.deposited_quid as u128)
                                                       * (liq_time_delta as u128);
        liquidator_dep.last_updated = right_now;
    }   liquidator_dep.deposited_quid += interest;
    Ok(())
}

// withdrawing is either what we liquidate (TP),
// or minting what is liable to get liquidated

#[derive(Accounts)]
#[instruction(amount: i64, ticker: String, exposure: bool)]
pub struct Withdraw<'info> {
    #[account(mut)]
    pub signer: Signer<'info>,

    #[cfg_attr(feature = "mainnet", account(
        constraint = config.registered_mints.contains(&mint.key())
            @ PithyQuip::InvalidMint
    ))]
    pub mint: InterfaceAccount<'info, Mint>,

    #[account(seeds = [b"program_config"], bump = config.bump)]
    pub config: Account<'info, ProgramConfig>,

    #[account(mut, seeds = [b"depository"], bump)]
    pub bank: Box<Account<'info, Depository>>,

    #[account(mut, seeds = [b"vault", mint.key().as_ref()], bump)]
    pub bank_token_account: InterfaceAccount<'info, TokenAccount>,

    #[account(mut, seeds = [signer.key().as_ref()], bump)]
    pub customer_account: Box<Account<'info, Depositor>>,

    #[account(mut, associated_token::mint = mint, associated_token::authority = signer,
        associated_token::token_program = token_program,
        constraint = customer_token_account.owner == signer.key()
    )]
    pub customer_token_account: InterfaceAccount<'info, TokenAccount>,

    #[account(mut, seeds = [b"risk", ticker.as_bytes()], bump = ticker_risk.bump)]
    pub ticker_risk: Option<Account<'info, TickerRisk>>,

    pub token_program: Interface<'info, TokenInterface>,
    pub associated_token_program: Program<'info, AssociatedToken>,
    pub system_program: Program<'info, System>,
}

pub fn handle_out<'info>(ctx: Context<'_, '_, 'info, 'info, Withdraw<'info>>, mut amount: i64,
    ticker: String, exposure: bool) -> Result<()> {
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
    if ticker.is_empty() { // withdrawal of $ deposits...
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

            let raw_max = customer.deposit_seconds.saturating_mul(Banks.total_deposits as u128)
                .checked_div(Banks.total_deposit_seconds).unwrap_or(0).min(u64::MAX as u128) as u64;

            // Borrowers pay supra to the pool proportional to their share of total drawn;
            // a pure depositor (drawn=0) gets full pro-rata yield, a borrower gets it
            // discounted by their fraction of pool risk — closing the circular subsidy
            // where funding payments flow into the pool and then back to the payer.
            let utilisation_discount = if Banks.total_drawn > 0 {
                let borrow_frac = (customer.drawn as u128 * 10_000
                                  / Banks.total_drawn as u128).min(10_000) as u64;
                10_000u64.saturating_sub(borrow_frac)
            } else { 10_000 };
            let max_value = raw_max.saturating_mul(utilisation_discount) / 10_000;

            let value = max_value.min(amount.abs() as u64);
            amt += value; Banks.total_deposits -= value;

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
        transfer_from_vaults(
            &ctx.accounts.bank_token_account,
            &ctx.accounts.mint,
            &ctx.accounts.customer_token_account,
            ctx.bumps.bank_token_account,
            vault_accounts,
            &ctx.accounts.token_program,
            ctx.program_id,
            &ctx.accounts.config.registered_mints,
            amt,
        )?;
    } else { // < ticker was not ""
        let t: &str = ticker.as_str();
        if !exposure { // < withdraw pledged from specific ticker (no exposure change)
            require!(amount < 0, PithyQuip::InvalidAmount);
            customer.renege(Some(t), amount, None, right_now)?;

            transfer_from_vault(
                &ctx.accounts.bank_token_account,
                &ctx.accounts.mint,
                &ctx.accounts.customer_token_account,
                ctx.bumps.bank_token_account,
                &ctx.accounts.token_program,
                -amount as u64,
            )?;
        } else {
            let risk = ctx.accounts.ticker_risk.as_mut().ok_or(PithyQuip::UnknownSymbol)?;
            let key: &str = get_account(t).ok_or(PithyQuip::UnknownSymbol)?;
            let first: &AccountInfo = &ctx.remaining_accounts[0];
            let first_key = first.key.to_string();
            if first_key != key {
                return Err(PithyQuip::UnknownSymbol.into());
            }
            let adjusted_price = fetch_price(t, Some(first))?;
            risk.actuary.update_price(adjusted_price as i64, slot);
            risk.actuary.check_twap_deviation(adjusted_price as i64)?;
            let pos = customer.balances.iter().find(|p|
                std::str::from_utf8(&p.ticker).unwrap()
                .trim_end_matches('\0') == t)
                .ok_or(PithyQuip::DepositFirst)?;

            let prior_exposure = pos.exposure;
            let leverage = if pos.pledged > 0 { (pos.exposure.abs() as u64
                              * adjusted_price * 100 / pos.pledged) as i64
            } else { 100 };
            let fee = fee_bps(Banks.concentration(), prior_exposure,
                                amount, &risk.actuary, leverage);

            let (mut delta, mut interest) = customer.repo(t, amount,
            adjusted_price, right_now, slot, &risk.actuary, Banks)?;

            if delta != 0 { // Take Profit:
                if delta < 0 { delta *= -1; // // < first, remove control flow meaning
                    let fee_amount = (interest as u128 * fee as u128 / 10_000) as u64;
                    let payout = interest.saturating_sub(fee_amount);

                    transfer_from_vault(
                        &ctx.accounts.bank_token_account,
                        &ctx.accounts.mint,
                        &ctx.accounts.customer_token_account,
                        ctx.bumps.bank_token_account,
                        &ctx.accounts.token_program,
                        payout,
                    )?;
                    // interest includes (partially) the pod.pledged
                    // (delta was obtained from total_deposits)...
                    Banks.total_deposits += fee_amount as u64; interest = 0;
                    // so we don't add it back to the total_deposits later ^
                } else { // was auto-protected against liquidation
                    time_delta = right_now - customer.last_updated;
                    customer.deposit_seconds += (time_delta as u128) *
                    ((customer.deposited_quid + delta as u64) as u128);
                    customer.last_updated = right_now;
                } Banks.total_deposits -= delta as u64;
            }     Banks.total_deposits += interest;
            risk.actuary.record_activity(prior_exposure,
                amount, leverage, slot, amount.abs(),
                Banks.total_deposits as i64);
        }
    } Ok(())
}

#[derive(Accounts)]
pub struct WithdrawSol<'info> {
    #[account(mut)]
    pub depositor: Signer<'info>,

    #[account(
        mut, seeds = [depositor.key().as_ref()], bump,
        constraint = customer_account.owner == depositor.key() @ PithyQuip::InvalidUser,
    )]
    pub customer_account: Box<Account<'info, Depositor>>,

    #[account(mut, seeds = [b"depository"], bump)]
    pub bank: Box<Account<'info, Depository>>,

    #[account(mut, seeds = [b"risk", "SOL".as_bytes()], bump = sol_risk.bump)]
    pub sol_risk: Box<Account<'info, TickerRisk>>,

    /// CHECK: PDA verified by seeds
    #[account(mut, seeds = [SOL_POOL_SEED], bump)]
    pub sol_pool: AccountInfo<'info>,

    pub system_program: Program<'info, System>,
    // remaining_accounts[0] = Pyth SOL/USD price account
}

pub fn handle_withdraw_sol(ctx: Context<WithdrawSol>,
    lamports: u64) -> Result<()> { require!(lamports > 0, PithyQuip::InvalidAmount);
    require!(lamports <= ctx.accounts.customer_account.deposited_lamports,
            PithyQuip::InsufficientFunds);

    require!(lamports <= ctx.accounts.bank.sol_lamports,
            PithyQuip::InsufficientFunds);

    let now = Clock::get()?.unix_timestamp;
    let slot = Clock::get()?.slot as i64;
    let pyth = ctx.remaining_accounts.first();
    let sol_price = crate::etc::fetch_price("SOL", pyth)?;
    ctx.accounts.sol_risk.actuary
        .update_price(sol_price as i64, slot);

    let customer = &mut ctx.accounts.customer_account;
    let bank = &mut ctx.accounts.bank;
    // Proportional share of the locked USD contribution being withdrawn
    let locked_fraction = (lamports as u128)
        .saturating_mul(customer.sol_pledged_usd as u128)
        .checked_div(customer.deposited_lamports as u128)
        .unwrap_or(0) as u64;

    // Current collar-adjusted value of the lamports being withdrawn
    let current_floor = collar_adjusted_usd(lamports, sol_price, &ctx.accounts.sol_risk.actuary);

    // Use min(locked, current): prevents withdrawing stale value if SOL has dropped.
    // If SOL rose: depositor gets no windfall (conservative, matches Aux headroom logic).
    // If SOL fell: depositor can only take out what it's worth now — no pool theft.
    let usd_reduction = locked_fraction.min(current_floor);

    // Shared accounting: accrues deposit_seconds + solvency check + mutates deposited_quid
    customer.sol_pledged_usd = customer.sol_pledged_usd.saturating_sub(locked_fraction);
    customer.deposited_lamports = customer.deposited_lamports.saturating_sub(lamports);
    bank.sol_usd_contrib = bank.sol_usd_contrib.saturating_sub(locked_fraction);
    bank.sol_lamports = bank.sol_lamports.saturating_sub(lamports);
    customer.pool_withdraw(bank, usd_reduction, now)?;

    invoke_signed(&system_instruction::transfer(ctx.accounts.sol_pool.key, ctx.accounts.depositor.key, lamports),
        &[ctx.accounts.sol_pool.to_account_info(), ctx.accounts.depositor.to_account_info(),
          ctx.accounts.system_program.to_account_info()],
        &[&[SOL_POOL_SEED, &[ctx.bumps.sol_pool]]])?;

    Ok(())
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

pub fn handle_refresh_sol_collateral(ctx: Context<RefreshSolCollateral>) -> Result<()> {
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
        customer.deposited_lamports, sol_price, &ctx.accounts.sol_risk.actuary,
    );
    if current_floor >= customer.sol_pledged_usd {
        return Ok(()); // SOL has not dropped below locked value — nothing to do
    }
    // Unconditional mark-down: pool_mark_down does NOT check solvency.
    // This is correct — if SOL has dropped the pool may already be
    // undercollateralized, and blocking the mark-down would hide that.
    // After this call: if total_deposits < max_liability, the next
    // amortise() call on any open position will detect it and fire.
    let reduction = customer.sol_pledged_usd.saturating_sub(current_floor);
    let bank = &mut ctx.accounts.bank;
    customer.sol_pledged_usd = current_floor;
    bank.sol_usd_contrib = bank.sol_usd_contrib.saturating_sub(reduction);
    customer.pool_mark_down(bank, reduction, now);
    // If total_deposits < max_liability after this reduction, the next amortise()
    // call on any of this depositor's positions will fire. No new liquidation
    // logic needed — has_capacity() is already the gate everywhere it matters.
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
pub fn handle_flash_repay<'info>(ctx: Context<'_, '_, '_, 'info, FlashRepay<'info>>, tip_lamports: u64, tip_token_amount: u64,
    vault_bump: u8, // canonical [b"vault", mint] bump; 0 for SOL path
) -> Result<()> {
    let bank = &mut ctx.accounts.bank;
    let flash = &mut ctx.accounts.flash_loan;

    if flash.flash_token_amount > 0 {
        // ── SPL repay ─────────────────────────────────────────────────────────
        let principal = flash.flash_token_amount;
        let total     = principal.saturating_add(tip_token_amount);

        let ra = ctx.remaining_accounts;
        require!(ra.len() >= 4, PithyQuip::InvalidParameters);
        let (vault_ai, mint_ai, repayer_ata, token_prog) =
            (&ra[0], &ra[1], &ra[2], &ra[3]);

        // Validate vault PDA using caller-supplied bump (create_program_address,
        // single sha256, vs find_program_address's up-to-255-iteration loop).
        let expected = Pubkey::create_program_address(
            &[b"vault", mint_ai.key.as_ref(), &[vault_bump]], &crate::ID,
        ).map_err(|_| error!(PithyQuip::InvalidParameters))?;
        require_keys_eq!(vault_ai.key(), expected, PithyQuip::InvalidSettlementProgram);
        require_keys_eq!(*mint_ai.key, flash.flash_token_mint, PithyQuip::InvalidMint);
        // Reject fake token programs — no-op transfer would zero flash state
        // without returning principal to the vault.
        require!(
            token_prog.key() == anchor_spl::token::ID
                || token_prog.key() == anchor_spl::token_2022::ID,
            PithyQuip::InvalidParameters
        );

        let decimals = {
            let d = mint_ai.try_borrow_data()?;
            require!(d.len() >= 45, PithyQuip::InvalidParameters);
            d[44]
        };

        use anchor_spl::token_interface::{TransferChecked, transfer_checked};
        transfer_checked(
            CpiContext::new(
                token_prog.clone(),
                TransferChecked {
                    from:      repayer_ata.clone(),
                    mint:      mint_ai.clone(),
                    to:        vault_ai.clone(),
                    authority: ctx.accounts.repayer.to_account_info(),
                },
            ),
            total, decimals,
        )?;

        flash.flash_token_mint   = Pubkey::default();
        flash.flash_token_amount = 0;
    } else {
        // ── SOL repay ─────────────────────────────────────────────────────────
        require!(flash.flash_lamports > 0, PithyQuip::NoActiveFlashLoan);
        let principal = flash.flash_lamports;
        // Flash loans are free (tip_lamports is optional protocol revenue).
        let total = principal.saturating_add(tip_lamports);
        anchor_lang::system_program::transfer(
            CpiContext::new(
                ctx.accounts.system_program.to_account_info(),
                anchor_lang::system_program::Transfer {
                    from: ctx.accounts.repayer.to_account_info(),
                    to:   ctx.accounts.sol_pool.to_account_info(),
                },
            ), total,
        )?;
        flash.flash_lamports  = 0;
        bank.sol_lamports    = bank.sol_lamports.saturating_add(total);
        // Restore sol_usd_contrib at current price.
        // If SOL rose during loan: restored > original → tiny protocol gain.
        // If SOL fell: restored < original → conservative, correct.
        let slot = Clock::get()?.slot as i64;
        let pyth = ctx.remaining_accounts.first();
        let sol_price = crate::etc::fetch_price("SOL", pyth)?;
        ctx.accounts.sol_risk.actuary.update_price(sol_price as i64, slot);
        let restored = collar_adjusted_usd(
            bank.sol_lamports, sol_price,
            &ctx.accounts.sol_risk.actuary,
        );
        bank.total_deposits  = bank.total_deposits.saturating_add(restored);
        bank.sol_usd_contrib = restored;
    }
    Ok(())
}
