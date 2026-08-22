
use anchor_lang::prelude::*;
use anchor_spl::token_interface::{
    TokenInterface, TransferChecked,
    self, Mint, TokenAccount
};

use crate::etc::{ get_hex, PithyQuip, TickerRisk, fetch_price };

use crate::stay::*;
use anchor_lang::solana_program::{
    program::invoke_signed,
    instruction::AccountMeta,
    system_instruction,
    sysvar::instructions::{
        load_current_index_checked,
        load_instruction_at_checked,
        ID as INSTRUCTIONS_SYSVAR_ID
    }
};

#[derive(Accounts)]
pub struct InitConfig<'info> {
    #[account(mut)]
    pub admin: Signer<'info>,

    #[account(init, payer = admin,
        space = ProgramConfig::SPACE,
        seeds = [b"program_config"], bump)]
    pub config: Account<'info, ProgramConfig>,

    /// Flash loan state — separate from
    /// Depository so core accounting is
    /// never polluted with mid-tx sentinel values.
    #[account(init, payer = admin,
        space = 8 + FlashLoan::INIT_SPACE,
        seeds = [b"flash_loan"], bump)]
    pub flash_loan: Box<Account<'info, FlashLoan>>,

    pub system_program: Program<'info, System>,
}

// Post-deploy: call update_config(Some(squads_vault_pda), None) once
// with the hot deploy key to transfer admin to the Squads multisig.
pub fn init_config(ctx: Context<InitConfig>,
    token_mint: Pubkey) -> Result<()> {
    let config = &mut ctx.accounts.config;
    config.admin = ctx.accounts.admin.key();
    config.token_mint = token_mint;
    config.bump = ctx.bumps.config;
    config.registered_mints = [
          token_mint, USD_STAR];
    // SOL* parking starts off; admin turns it on with set_kestrel once the
    // deployment is pinned. Defaults are sized from the measured ~40 bps round
    // trip: a 10%-of-pool deadband and a 21-day hold clear break-even (~17 days
    // at ~8.5% APY) with margin. Buffer refills are exempt from the hold.
    config.kestrel_program = Pubkey::default();
    config.sol_star_mint = Pubkey::default();
    config.sol_buffer_bps = 5_000;
    config.sol_star_haircut_bps = 500;
    config.sol_park_band_bps = 1_000;
    config.sol_min_park_secs = 21 * 86_400;
    Ok(())
}

#[derive(Accounts)]
pub struct UpdateConfig<'info> {
    #[account(mut,
        constraint = admin.key() == config.admin @ PithyQuip::Unauthorized)]
    pub admin: Signer<'info>,

    #[account(mut,
        seeds = [b"program_config"],
        bump = config.bump)]
    pub config: Account<'info, ProgramConfig>,
}

pub fn update_config(ctx: Context<UpdateConfig>,
    new_admin: Option<Pubkey>,
    set_bebop_authority: Option<Pubkey>) -> Result<()> {
    let config = &mut ctx.accounts.config;
    if let Some(admin) = new_admin {
        config.admin = admin;
    }
    if let Some(authority) = set_bebop_authority {
        // bebop_authority controls who can call flash_borrow. Flash loans are
        // atomic (borrow + repay must balance within the same TX, enforced by
        // the flash_loan PDA's state machine and the sysvar co-presence check
        // in flash_repay), so a malicious rotation can't drain the pool — the
        // worst a new authority can do is execute a flash that must still
        // repay. No on-chain timelock needed; the admin path is the real
        // protection (Squads multisig with its own proposal delay).
        config.bebop_authority = authority;
    }
    Ok(())
}

/// Minimum seconds between proposing and committing a bebop_authority rotation.


#[derive(Accounts)]
#[instruction(amount: u64, ticker: String)]
pub struct Stockup<'info> {
    #[account(mut)]
    pub signer: Signer<'info>,

    #[cfg_attr(feature = "mainnet", account(
        constraint = config.registered_mints.contains(&mint.key())
            @ PithyQuip::InvalidMint
    ))]
    pub mint: InterfaceAccount<'info, Mint>,

    #[account(seeds = [b"program_config"], bump = config.bump)]
    pub config: Account<'info, ProgramConfig>,

    #[account(init_if_needed, space = 8 + Depository::INIT_SPACE,
        payer = signer, seeds = [b"depository"], bump)]
    pub bank: Box<Account<'info, Depository>>,

    #[account(init_if_needed, token::mint = mint,
        token::authority = program_vault,
        payer = signer, seeds = [b"vault",
        mint.key().as_ref()], bump)]
    pub program_vault: InterfaceAccount<'info, TokenAccount>,

    #[account(init_if_needed, payer = signer,
        space = 8 + Depositor::INIT_SPACE,
        seeds = [signer.key().as_ref()], bump)]
    pub depositor: Box<Account<'info, Depositor>>,

    #[account(init_if_needed, payer = signer,
        space = 8 + TickerRisk::INIT_SPACE,
        seeds = [b"risk", ticker.as_bytes()], bump)]
    pub ticker_risk: Option<Account<'info, TickerRisk>>,

    /// Depositor's token account, source of an SPL deposit — and the only
    /// account here that belongs to the depositor rather than the protocol,
    /// so it is the only one the native leg cannot be expected to supply.
    /// `mint` and `program_vault` stay required because they exist from
    /// `init_config` onward for every caller; a wallet holding nothing but
    /// lamports has no token account to name.
    #[account(mut)]
    pub quid: Option<InterfaceAccount<'info, TokenAccount>>,

    /// Native leg: the lamport pool. Present ⇒ this is a SOL deposit and the
    /// SPL accounts above are ignored. Anchor cannot express `seeds` over an
    /// optional account, so only this one — whose seeds are constant — is
    /// optional; the SPL accounts keep every declarative constraint they had.
    /// CHECK: PDA verified by seeds.
    #[account(mut, seeds = [SOL_POOL_SEED], bump)]
    pub sol_pool: Option<AccountInfo<'info>>,

    pub token_program: Interface<'info, TokenInterface>,
    pub system_program: Program<'info, System>,
}

pub fn handle_in<'info>(ctx: Context<'_, '_, 'info, 'info, Stockup<'info>>,
    amount: u64, ticker: String) -> Result<()> {
    let bank = &mut ctx.accounts.bank;
    let clock = Clock::get()?;
    let right_now = clock.unix_timestamp;
    let customer = &mut ctx.accounts.depositor;
    if customer.owner == Pubkey::default() {
        customer.owner = ctx.accounts.signer.key();
    }

    // Exactly one leg. Native SOL is signalled by supplying `sol_pool` and no
    // `mint`; an SPL deposit is the mirror. Accepting both would let a caller
    // credit one asset while delivering another.
    if ctx.accounts.sol_pool.is_some() {
        // ── native SOL collateral ───────────────────────────────────────────
        require!(amount > 0, PithyQuip::InvalidAmount);
        let sol_pool = ctx.accounts.sol_pool.as_ref().unwrap();
        let risk = ctx.accounts.ticker_risk.as_mut()
            .ok_or(PithyQuip::UnknownSymbol)?;

        require!(ticker.as_str() == "SOL", PithyQuip::UnknownSymbol);
        let sol_price = fetch_price("SOL", ctx.remaining_accounts.first())?;
        if risk.ticker == [0u8; 8] {
            risk.ticker = Depositor::pad_ticker("SOL");
            risk.bump = ctx.bumps.ticker_risk.unwrap();
            risk.actuary.obs_count = 10;
        }
        risk.actuary.update_price(sol_price as i64, clock.slot as i64);

        // Settle first, so arriving lamports cannot claim carry generated
        // before they existed.
        customer.settle_sol_yield(bank);
        bank.sol_lamports = bank.sol_lamports.saturating_add(amount);
        customer.deposited_lamports = customer.deposited_lamports.saturating_add(amount);

        anchor_lang::system_program::transfer(
            CpiContext::new(ctx.accounts.system_program.to_account_info(),
                anchor_lang::system_program::Transfer {
                    from: ctx.accounts.signer.to_account_info(),
                    to: sol_pool.to_account_info(),
                }), amount)?;

        let sol_usd_floor = collar_adjusted_usd(amount, sol_price, &risk.actuary);
        customer.sol_pledged_usd = customer.sol_pledged_usd.saturating_add(sol_usd_floor);
        bank.sol_usd_contrib = bank.sol_usd_contrib.saturating_add(sol_usd_floor);
        customer.pool_deposit(bank, sol_usd_floor, right_now);

        // A deposit is the moment the hot buffer grows, so it is the moment
        // the parking question arises — and hanging it here means no keeper
        // has to be alive for idle SOL to earn. The Kestrel accounts ride in
        // `remaining_accounts` past the price feed; bring them and the excess
        // above the buffer floor is parked, leave them out and it waits for
        // the next depositor who does.
        let rest = ctx.remaining_accounts.get(1..).unwrap_or(&[]);
        if let Some(legs) = SolStarLegs::from_remaining(&ctx.accounts.config,
                &sol_pool.to_account_info(), ctx.bumps.sol_pool.unwrap(),
                &ctx.accounts.token_program.to_account_info(),
                &ctx.accounts.system_program.to_account_info(), rest)? {
            park_idle_sol(bank, &ctx.accounts.config, &legs,
                &ctx.accounts.signer.to_account_info(),
                sol_price, &risk.actuary, right_now)?;
        }
        return Ok(());
    }

    // ── SPL deposit ─────────────────────────────────────────────────────────
    require!(amount >= 100_000_000, PithyQuip::InvalidAmount);
    let mint = &ctx.accounts.mint;
    let vault = &ctx.accounts.program_vault;
    let from = ctx.accounts.quid.as_ref().ok_or(PithyQuip::InvalidMint)?;
    let decimals = mint.decimals;
    token_interface::transfer_checked(
        CpiContext::new(ctx.accounts.token_program.to_account_info(),
            TransferChecked {
                from: from.to_account_info(),
                mint: mint.to_account_info(),
                to: vault.to_account_info(),
                authority: ctx.accounts.signer.to_account_info(),
            }), amount, decimals)?;

    // The vault holds raw token units; the Depository counts accounting units.
    // Cross here, once, or a 9-decimal mint credits 1000× a 6-decimal one.
    let credited = to_accounting(amount, decimals)?;
    require!(credited > 0, PithyQuip::InvalidAmount);

    if ticker.is_empty() {
        customer.pool_deposit(bank, credited, right_now); return Ok(());
    } else {
        customer.accrue(bank, right_now);
        let t: &str = ticker.as_str();
        if get_hex(t).is_none() {
            return Err(PithyQuip::UnknownSymbol.into());
        }
        if let Some(risk) = ctx.accounts.ticker_risk.as_mut() {
            if risk.actuary.last_price == 0 {
                risk.ticker = Depositor::pad_ticker(t);
                risk.bump = ctx.bumps.ticker_risk.unwrap();
                risk.actuary.obs_count = 10; // bootstrap: 50% confidence
            }
        }
        customer.renege(Some(t), credited as i64, None, right_now)?;
    }
    customer.last_updated = right_now;
    bank.last_updated = right_now; Ok(())
}


// =============================================================================
// SOL deposit / collateral
// =============================================================================
//
// SOL serves two roles simultaneously:
//   1. Flash-loan liquidity for JAM (sol_lamports in Depository)
//   2. Collateral for synthetic positions (sol_pledged_usd added to deposited_quid)


// =============================================================================
// FLASH BORROW (unchanged from prior)
// =============================================================================

#[derive(Accounts)]
pub struct FlashBorrow<'info> {
    /// JAM authority PDA — equivalent of require(msg.sender == JAM) in Aux.sol.
    /// CHECK: address == config.bebop_authority
    #[account(signer,
        address = config.bebop_authority @ PithyQuip::InvalidSettlementProgram,
    )]
    pub flash_authority: AccountInfo<'info>,

    /// CHECK: validated by flash_authority auth
    #[account(mut)]
    pub borrower: AccountInfo<'info>,

    #[account(mut, seeds = [b"depository"], bump)]
    pub bank: Box<Account<'info, Depository>>,

    #[account(mut, seeds = [b"flash_loan"], bump,
        constraint = flash_loan.flash_lamports == 0
            && flash_loan.flash_token_mint == Pubkey::default()
            && flash_loan.flash_token_amount == 0
            @ PithyQuip::FlashLoanActive)]
    pub flash_loan: Box<Account<'info, FlashLoan>>,

    #[account(seeds = [b"program_config"], bump)]
    pub config: Box<Account<'info, ProgramConfig>>,

    /// CHECK: PDA verified by seeds
    #[account(mut, seeds = [SOL_POOL_SEED], bump)]
    pub sol_pool: AccountInfo<'info>,

    /// CHECK: address constraint
    #[account(address = INSTRUCTIONS_SYSVAR_ID)]
    pub ix_sysvar: AccountInfo<'info>,

    pub system_program: Program<'info, System>,
}

pub fn handle_flash_borrow<'info>(ctx: Context<'_, '_, '_,
    'info, FlashBorrow<'info>>, lamports: u64, token_amount: u64,
    vault_bump: u8) -> Result<()> { require!(lamports > 0 || token_amount > 0, PithyQuip::InvalidAmount);
    require!(!(lamports > 0 && token_amount > 0), PithyQuip::InvalidAmount);

    let bank = &mut ctx.accounts.bank;
    let flash = &mut ctx.accounts.flash_loan;

    let ixs = &ctx.accounts.ix_sysvar;
    let current_idx = load_current_index_checked(ixs)? as usize;

    let mut found = false; let mut i = current_idx + 1;
    loop { match load_instruction_at_checked(i, ixs) {
            Ok(ix) => { if ix.program_id == crate::ID && ix.data.len() >= 8
                        && ix.data[..8] == FLASH_REPAY_DISC { found = true; break; }
                i += 1;
            } Err(_) => break,
        }
    } require!(found, PithyQuip::FlashRepayMissing);
    if lamports > 0 {
        require!(lamports <= bank.sol_lamports, PithyQuip::InsufficientFunds);
        let old_contrib = bank.sol_usd_contrib;

        bank.total_deposits = bank.total_deposits.saturating_sub(old_contrib);
        bank.sol_usd_contrib = 0; flash.flash_lamports = lamports;
        bank.sol_lamports = bank.sol_lamports.saturating_sub(lamports);
        invoke_signed(&system_instruction::transfer(ctx.accounts.sol_pool.key,
                ctx.accounts.borrower.key, lamports),
            &[ctx.accounts.sol_pool.to_account_info(),
              ctx.accounts.borrower.to_account_info(),
              ctx.accounts.system_program.to_account_info(),
            ], &[&[SOL_POOL_SEED, &[ctx.bumps.sol_pool]]],
        )?;
    } else {
        let ra = ctx.remaining_accounts;
        require!(ra.len() >= 4, PithyQuip::InvalidParameters);
        let (vault_ai, mint_ai, borrower_ata, token_prog) =
            (&ra[0], &ra[1], &ra[2], &ra[3]);

        let expected = Pubkey::create_program_address(
            &[b"vault", mint_ai.key.as_ref(), &[vault_bump]], &crate::ID,
        ).map_err(|_| error!(PithyQuip::InvalidParameters))?;

        require_keys_eq!(vault_ai.key(), expected,
            PithyQuip::InvalidSettlementProgram);
        require!(
            ctx.accounts.config.registered_mints.contains(mint_ai.key),
            PithyQuip::InvalidMint
        );
        require!(token_prog.key() == anchor_spl::token::ID
              || token_prog.key() == anchor_spl::token_2022::ID,
            PithyQuip::InvalidParameters
        );
        let vault_amount = { let d = vault_ai.try_borrow_data()?;
            require!(d.len() >= 72, PithyQuip::InvalidParameters);
            u64::from_le_bytes(d[64..72].try_into().unwrap())
        };

        require!(token_amount <= vault_amount,
                PithyQuip::InsufficientFunds);
        let decimals = { let d = mint_ai.try_borrow_data()?;
            require!(d.len() >= 45, PithyQuip::InvalidParameters);
            d[44]
        };

        flash.flash_token_mint = *mint_ai.key; flash.flash_token_amount = token_amount;
        use anchor_spl::token_interface::{TransferChecked, transfer_checked};
        transfer_checked(CpiContext::new_with_signer(
                token_prog.clone(), TransferChecked {
                    from: vault_ai.clone(),
                    mint: mint_ai.clone(),
                    to: borrower_ata.clone(),
                    authority: vault_ai.clone(),
                }, &[&[b"vault",
                mint_ai.key.as_ref(),
                &[vault_bump]]],
            ), token_amount, decimals,
        )?;
    } Ok(())
}

// =============================================================================
// SOL* PARKING — config + park
// =============================================================================

#[derive(Accounts)]
pub struct SetKestrel<'info> {
    #[account(mut, address = config.admin @ PithyQuip::Unauthorized)]
    pub admin: Signer<'info>,

    #[account(mut, seeds = [b"program_config"], bump = config.bump)]
    pub config: Account<'info, ProgramConfig>,
}

/// Point SOL* parking at the issuer. `kestrel_program = Pubkey::default()`
/// disables parking: `park_sol` fails closed while `unpark_sol` keeps working,
/// so a live position can always be wound down.
pub fn set_kestrel(ctx: Context<SetKestrel>, kestrel_program: Pubkey,
    sol_star_mint: Pubkey, buffer_bps: u16, haircut_bps: u16,
    park_band_bps: u16, min_park_secs: i64) -> Result<()> {
    require!(buffer_bps >= MIN_BUFFER_BPS, PithyQuip::InvalidParameters);
    require!(buffer_bps <= 10_000 && haircut_bps <= 10_000,
             PithyQuip::InvalidParameters);

    // The band must fit under the non-buffer share, or park_sol can never
    // satisfy both "move at least a band" and "leave the floor intact".
    require!((park_band_bps as u32) <= (10_000 - buffer_bps as u32),
             PithyQuip::InvalidParameters);

    require!(min_park_secs >= 0 && min_park_secs <= MAX_MIN_PARK_SECS,
             PithyQuip::InvalidParameters);

    // Enabling requires both halves; disabling clears both.
    if kestrel_program != Pubkey::default() {
        require!(sol_star_mint != Pubkey::default(), PithyQuip::InvalidParameters);
    }
    let config = &mut ctx.accounts.config;
    config.kestrel_program = kestrel_program;
    config.sol_star_mint = sol_star_mint;
    config.sol_buffer_bps = buffer_bps;
    config.sol_star_haircut_bps = haircut_bps;
    config.sol_park_band_bps = park_band_bps;
    config.sol_min_park_secs = min_park_secs;
    Ok(())
}
