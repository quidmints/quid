
use anchor_lang::prelude::*;
use anchor_spl::token_interface::{
    TokenInterface, TransferChecked,
    self, Mint, TokenAccount
};

use crate::etc::{ get_hex, PithyQuip, TickerRisk, fetch_price, Actuary };

use crate::stay::*;
use anchor_spl::associated_token::get_associated_token_address_with_program_id;
use anchor_lang::solana_program::{
    program::{invoke, invoke_signed},
    instruction::{AccountMeta, Instruction},
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
    pub config: Box<Account<'info, ProgramConfig>>,

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
    pub config: Box<Account<'info, ProgramConfig>>,
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

    /// Unconditional, and deliberately so. `handle_in`'s SPL leg looks up no
    /// price: it moves tokens into `vault/<mint>` and credits
    /// `to_accounting(amount, decimals)` as dollars. Without this constraint
    /// anyone can mint a worthless six-decimal token and be credited one for
    /// one, so the whitelist is the only thing standing between the pool and
    /// unbacked deposits. It used to sit behind a `mainnet` feature, which
    /// meant the protection was absent from every build that forgot the flag.
    #[account(constraint = config.registered_mints.contains(&mint.key())
            @ PithyQuip::InvalidMint)]
    pub mint: Box<InterfaceAccount<'info, Mint>>,

    #[account(seeds = [b"program_config"], bump = config.bump)]
    pub config: Box<Account<'info, ProgramConfig>>,

    #[account(init_if_needed, space = 8 + Depository::INIT_SPACE,
        payer = signer, seeds = [b"depository"], bump)]
    pub bank: Box<Account<'info, Depository>>,

    #[account(init_if_needed, token::mint = mint,
        token::authority = program_vault,
        payer = signer, seeds = [b"vault",
        mint.key().as_ref()], bump)]
    pub program_vault: Box<InterfaceAccount<'info, TokenAccount>>,

    #[account(init_if_needed, payer = signer,
        space = 8 + Depositor::INIT_SPACE,
        seeds = [signer.key().as_ref()], bump)]
    pub depositor: Box<Account<'info, Depositor>>,

    #[account(init_if_needed, payer = signer,
        space = 8 + TickerRisk::INIT_SPACE,
        seeds = [b"risk", ticker.as_bytes()], bump)]
    pub ticker_risk: Option<Box<Account<'info, TickerRisk>>>,

    /// Depositor's token account, source of an SPL deposit — and the only
    /// account here that belongs to the depositor rather than the protocol,
    /// so it is the only one the native leg cannot be expected to supply.
    /// `mint` and `program_vault` stay required because they exist from
    /// `init_config` onward for every caller; a wallet holding nothing but
    /// lamports has no token account to name.
    #[account(mut)]
    pub quid: Option<Box<InterfaceAccount<'info, TokenAccount>>>,

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
        let util = bank.utilisation_bps();
        risk.actuary.accrue_premium_index(right_now, util);
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

        // A SOL deposit is a yield position, not margin. It is deliberately
        // not credited to `deposited_quid`, because that is the balance
        // `renege` draws on to fund `pledged` — so crediting it would let a
        // stock position be opened against SOL, and a stock loss would then be
        // paid out of somebody's staking deposit. Only dollars margin stocks.
        //
        // It follows that a SOL move cannot reach a stock book at all, in
        // either direction, and that the depositor's claim is simply their
        // lamports: they get back what they put in, plus carry, whatever the
        // price has done in between. Nothing here needs a USD mark, so nothing
        // needs marking down.
        //
        // `sol_usd_contrib` is still tracked, as the pool's own record of what
        // it is holding in SOL. It backs no obligation but this one.
        let sol_usd_floor = collar_adjusted_usd(amount, sol_price, &risk.actuary);
        customer.sol_pledged_usd = customer.sol_pledged_usd.saturating_add(sol_usd_floor);
        bank.sol_usd_contrib = bank.sol_usd_contrib.saturating_add(sol_usd_floor);

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
    pub config: Box<Account<'info, ProgramConfig>>,

    /// Read only, and only to answer one question: is anything still parked?
    #[account(seeds = [b"depository"], bump)]
    pub bank: Box<Account<'info, Depository>>,
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
    } else {
        // Switching the issuer off while the pool still holds its token would
        // strand that balance: every unwind is addressed to the program named
        // here, so clearing it removes the only route back to lamports. Wind
        // the position down first, then disable.
        require!(ctx.accounts.bank.sol_star_shares == 0, PithyQuip::FlashLoanActive);
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

// =============================================================================
// PROTOCOL STATE — config, vaults, device enrollment
// =============================================================================
// Folded in from the former state.rs: this file is the single home for every
// persisted account and the helpers that move value between them.
pub const USD_STAR_DECIMALS: u8 = 6;

/// Every balance the Depository reasons about — `deposited_quid`, `pledged`,
/// `total_deposits`, `max_liability` — is denominated at this precision, the
/// same 6 decimals as USD*.
///
/// Token amounts arriving from a mint are RAW, and mints disagree: USD* is 6
/// decimals while bridged QD is 9 (`LZ::QD_LOCAL_DECIMALS`, with SD→local
/// scaling of 1_000). Crediting a raw amount straight into `deposited_quid`
/// therefore over-credited a QD deposit by 1000× — unbacked balance conjured
/// out of a unit mismatch. Every boundary between token units and accounting
/// units must pass through `to_accounting` / `from_accounting`.
pub const ACCOUNTING_DECIMALS: u8 = 6;


/// Raw token units → accounting units.
pub fn to_accounting(amount: u64, decimals: u8) -> Result<u64> {
    if decimals == ACCOUNTING_DECIMALS { return Ok(amount); }
    if decimals > ACCOUNTING_DECIMALS {
        let div = 10u64.checked_pow((decimals - ACCOUNTING_DECIMALS) as u32)
            .ok_or(PithyQuip::InvalidParameters)?;
        Ok(amount / div)
    } else {
        let mul = 10u64.checked_pow((ACCOUNTING_DECIMALS - decimals) as u32)
            .ok_or(PithyQuip::InvalidParameters)?;
        amount.checked_mul(mul).ok_or(PithyQuip::InvalidParameters.into())
    }
}

/// Accounting units → raw token units for a given mint.
pub fn from_accounting(units: u64, decimals: u8) -> Result<u64> {
    if decimals == ACCOUNTING_DECIMALS { return Ok(units); }
    if decimals > ACCOUNTING_DECIMALS {
        let mul = 10u64.checked_pow((decimals - ACCOUNTING_DECIMALS) as u32)
            .ok_or(PithyQuip::InvalidParameters)?;
        units.checked_mul(mul).ok_or(PithyQuip::InvalidParameters.into())
    } else {
        let div = 10u64.checked_pow((ACCOUNTING_DECIMALS - decimals) as u32)
            .ok_or(PithyQuip::InvalidParameters)?;
        Ok(units / div)
    }
}
/// USD* (star9agSpjiFe3M49B3RniVU4CMBBEK3Qnaqn3RGiFM)
pub const USD_STAR: Pubkey = Pubkey::new_from_array([
    13, 9, 93, 190, 135, 153, 95, 149, 60, 27, 94, 58, 32, 167, 130, 124,
    150, 157, 208, 228, 203, 99, 252, 41, 160, 227, 239, 15, 132, 98, 27, 92,
]);

/// Check if a mint is in the approved basket
pub fn is_approved_mint(mint: &Pubkey,
    registered_mints: &[Pubkey]) -> bool {
    registered_mints.contains(mint)
}

// =============================================================================
// PROGRAM CONFIG — admin-managed protocol settings
// =============================================================================
//
// Squads Multisig migration: pre-deployment, transfer config.admin to a Squads
// vault PDA with 48h timelock.
//
//   1. Create a Squads v4 multisig (app.squads.so or squads-cli):
//        squads-cli multisig create --threshold 2 --members key1,key2,key3
//
//   2. After init_config, call update_config(None, Some(vault_pda), ..., None)
//      once with the hot deploy key to hand control to the multisig.
//
//   3. Configure the Squads multisig with time_lock = 48 * 60 * 60 (48h).
//
//   4. Transfer the program upgrade authority to the same multisig:
//        solana program set-upgrade-authority <PROGRAM_ID> \
//            --new-upgrade-authority <SQUADS_VAULT_PDA>
//      Compromised upgrade key can replace the entire program. Highest-risk key.

/// Squads v4, mainnet. `SQDS4ep65T869zMMBKyuUq6aD6EgTu8psMjkvj52pCf`.
///
/// Bytes rather than a string, so a mistyped address is a compile error
/// instead of a runtime one. The reference implementation this pattern came
/// from carries the same constant as a `&str` with a trailing character too
/// many — it compiles, and would only fail whenever something first tried to
/// parse it.
pub const SQUADS_MULTISIG_V4: Pubkey = Pubkey::new_from_array([
    6, 129, 196, 206, 71, 226, 35, 104, 184, 177, 85, 94,
    200, 135, 175, 9, 46, 252, 126, 251, 182, 108, 163, 245,
    47, 191, 104, 212, 172, 156, 183, 168,
]);

/// PDA seed for the native-SOL collateral pool.
pub const SOL_POOL_SEED: &[u8] = b"sol_pool";

/// Anchor discriminator for `flash_repay` — sha256("global:flash_repay")[..8].
pub const FLASH_REPAY_DISC: [u8; 8] = [0xb6, 0x8f, 0x13, 0x17, 0x27, 0xdd, 0xb8, 0x4e];

/// Off-chain: derive the Squads v4 vault PDA (index 0) for a given multisig.
/// Seeds: [b"vault", multisig.as_ref(), &[0u8]], program = SQUADS_MULTISIG_V4
#[account]
pub struct ProgramConfig {
    /// Protocol admin. After init_config, should be a Squads v4 vault PDA.
    /// Controls: bebop_authority, registered_mints, the SOL* settings.
    pub admin: Pubkey,
    pub token_mint: Pubkey,
    /// Exactly two mints are ever acceptable, and neither is chosen after the
    /// fact: `USD_STAR` is a compile-time constant, and `token_mint` is fixed
    /// by `init_config` — which uses `init`, so it runs once — with no path in
    /// `update_config` to revise either. `init_oapp_store` then requires the
    /// token LayerZero mints to be that same `token_mint`, so the bridge and
    /// the deposit whitelist cannot name different assets.
    ///
    /// This matters because `handle_in`'s SPL leg does no price lookup: a mint
    /// that reaches `registered_mints` is credited as dollars at face value.
    pub registered_mints: [Pubkey; 2], // [token_mint, USD*]
    pub bump: u8,
    /// JAM settlement program authority PDA.
    /// flash_borrow requires flash_authority.key() == this field.
    /// Pubkey::default() = flash loans disabled.
    /// SENSITIVE: rotated by `update_config`. A flash loan must balance
    /// within its own transaction, so the worst a rotated authority can do is
    /// execute a flash that still has to repay — the admin path (Squads, with
    /// its own proposal delay) is the real protection, and a second on-chain
    /// timelock on top of it bought nothing.
    pub bebop_authority: Pubkey,
    pub config_version: u32,

    /// Kestrel `long_yield_carry` — the SOL* issuer. Pubkey::default() = parking
    /// off, which is both the default and the kill switch: `park_sol` fails
    /// closed while `unpark_sol` keeps working so a position can be wound down.
    pub kestrel_program: Pubkey,
    /// SOL* mint (`FDhu9642…` on mainnet).
    pub sol_star_mint: Pubkey,
    /// Share of the SOL pool that stays native — flash-loanable and
    /// synchronously withdrawable. Floored at MIN_BUFFER_BPS.
    pub sol_buffer_bps: u16,
    /// Discount applied to parked lamports when crediting depositor collateral.
    pub sol_star_haircut_bps: u16,
    /// Deadband: idle lamports are left alone until the excess over the floor
    /// exceeds this, and a park must move at least this much. The round trip
    /// costs ~40 bps, so churn is a leak.
    pub sol_park_band_bps: u16,
    /// Minimum hold before a *discretionary* unpark. Refilling a buffer that is
    /// below its floor is exempt — liquidity repair is never time-locked.
    pub sol_min_park_secs: i64,
}

impl ProgramConfig {
    pub const SPACE: usize = 8
        + 32  // admin
        + 32  // keeper
        + 32  // token_mint
        + 64  // registered_mints [2]
        + 1   // bump
        + 32  // bebop_authority
        + 4   // config_version
        + 32  // kestrel_program
        + 32  // sol_star_mint
        + 2   // sol_buffer_bps
        + 2   // sol_star_haircut_bps
        + 2   // sol_park_band_bps
        + 8;  // sol_min_park_secs → total 324
}


/// Pro-rata withdrawal across primary vault + alternate vaults from remaining_accounts.
/// remaining_accounts layout: [alt_mint, alt_vault, alt_user_ata] triplets.
/// The pool's own lamports, as a source of payment alongside the SPL vaults.
///
/// A claim is in accounting units and asset-agnostic; SOL backs it exactly as
/// the vaults do. What differs is only how value leaves — a system transfer
/// rather than a token one — so it joins the same pro-rata split rather than
/// being a special case beside it.
pub struct NativeLeg<'info> {
    pub sol_pool: AccountInfo<'info>,
    pub recipient: AccountInfo<'info>,
    pub system_program: AccountInfo<'info>,
    pub bump: u8,
    /// Lamports available, and what the pool marks them at. Paying a share of
    /// the value hands over the same share of the lamports, so the two never
    /// need the collar inverted to agree.
    pub lamports: u64,
    pub value: u64,
    /// What this leg actually paid, in lamports. The split decides the share;
    /// the caller has to move `sol_lamports` and `sol_usd_contrib` by it, and
    /// re-deriving that from the outside means reimplementing the split.
    pub paid: core::cell::Cell<u64>,
}

impl<'info> NativeLeg<'info> {
    /// Pay `take` accounting units in lamports, pro rata to the mark.
    /// Returns the lamports sent so the caller can move its own books.
    fn pay(&self, take: u64) -> Result<u64> {
        if take == 0 || self.value == 0 { return Ok(0); }
        let out = ((self.lamports as u128).saturating_mul(take as u128)
            / self.value as u128).min(self.lamports as u128) as u64;
        if out == 0 { return Ok(0); }
        invoke_signed(
            &system_instruction::transfer(self.sol_pool.key, self.recipient.key, out),
            &[self.sol_pool.clone(), self.recipient.clone(),
              self.system_program.clone()],
            &[&[SOL_POOL_SEED, &[self.bump]]])?;
        self.paid.set(self.paid.get().saturating_add(out));
        Ok(out)
    }
}

pub fn transfer_from_vaults<'info>(
    primary_vault: &InterfaceAccount<'info, TokenAccount>,
    primary_mint: &InterfaceAccount<'info, Mint>,
    primary_user_ata: &InterfaceAccount<'info, TokenAccount>,
    primary_vault_bump: u8, remaining_accounts: &[AccountInfo<'info>],
    token_program: &Interface<'info, TokenInterface>, program_id: &Pubkey,
    registered_mints: &[Pubkey], requested_amount: u64,
    native: Option<&NativeLeg<'info>>) -> Result<u64> {
    // `requested_amount` and every figure below are ACCOUNTING units; each
    // vault's raw balance is normalised before it joins the pro-rata split and
    // each payout is converted back to that mint's own precision. Summing raw
    // balances of a 6-decimal and a 9-decimal mint would weight the latter
    // 1000× in the split and pay it out 1000× short.
    let primary_dec = primary_mint.decimals;
    let primary_bal = to_accounting(primary_vault.amount, primary_dec)?;
    // SOL is part of what backs the claim, so it is part of what pays it.
    // Leaving it out meant a depositor could be told the pool was short while
    // the SOL sat there — and, the other way, that the stables drained first
    // and the SOL was left to whoever asked last.
    let native_bal = native.map_or(0, |n| n.value);
    let mut total: u64 = primary_bal.saturating_add(native_bal);
    let mut alt_vaults: Vec<(usize, u64, u8, u8)> = Vec::new();

    let mut idx = 0;
    while idx + 2 < remaining_accounts.len() {
        let mint_info = &remaining_accounts[idx];
        let vault_info = &remaining_accounts[idx + 1];
        if !is_approved_mint(mint_info.key, registered_mints) {
            idx += 3; continue;
        }
        let (expected, bump) = Pubkey::find_program_address(
            &[b"vault", mint_info.key.as_ref()], program_id,
        );
        if vault_info.key() != expected {
            idx += 3; continue;
        }
        let data = vault_info.try_borrow_data()?;
        if data.len() < 72 { idx += 3; continue; }
        let bal = u64::from_le_bytes(data[64..72].try_into().unwrap());
        let decimals = {
            let md = mint_info.try_borrow_data()?;
            if md.len() > 44 { md[44] } else { 6 }
        };
        let bal = to_accounting(bal, decimals)?;
        if bal > 0 {
            alt_vaults.push((idx, bal, decimals, bump));
            total = total.saturating_add(bal);
        }
        idx += 3;
    }
    if total == 0 { return Ok(0); }
    let to_send = requested_amount.min(total);
    let mut sent: u64 = 0;
    if primary_bal > 0 {
        let share = ((primary_bal as u128 *
         to_send as u128) / total as u128) as u64;

         let take = share.min(primary_bal).min(to_send);
        if take > 0 {
            let raw_take = from_accounting(take, primary_dec)?;
            let mk = primary_mint.key();
            token_interface::transfer_checked(
                CpiContext::new_with_signer(
                    token_program.to_account_info(),
                    TransferChecked {
                        from: primary_vault.to_account_info(),
                        mint: primary_mint.to_account_info(),
                        to: primary_user_ata.to_account_info(),
                        authority: primary_vault.to_account_info(),
                    },
                    &[&[b"vault", mk.as_ref(), &[primary_vault_bump]]],
                ),
                raw_take, primary_dec,
            )?;
            sent += take;
        }
    } for (i, &(ai, bal, dec, bump))
        in alt_vaults.iter().enumerate() {
        let remaining = to_send.saturating_sub(sent);
        if remaining == 0 { break; }
        let take = if i == alt_vaults.len() - 1 {
            remaining.min(bal)
        } else {
            let share = ((bal as u128 *
                      to_send as u128) /
                        total as u128) as u64;

            share.min(bal).min(remaining)
        };
        if take == 0 { continue; }

        let mint_info = &remaining_accounts[ai];
        token_interface::transfer_checked(
            CpiContext::new_with_signer(
                token_program.to_account_info(),
                TransferChecked {
                    from: remaining_accounts[ai + 1].clone(),
                    mint: mint_info.clone(),
                    to: remaining_accounts[ai + 2].clone(),
                    authority: remaining_accounts[ai + 1].clone(),
                }, &[&[b"vault", mint_info.key.as_ref(), &[bump]]],
            ), from_accounting(take, dec)?, dec)?;
        sent += take;
    }
    if let Some(leg) = native {
        let remaining = to_send.saturating_sub(sent);
        if remaining > 0 {
            let take = remaining.min(leg.value);
            if leg.pay(take)? > 0 { sent += take; }
        }
    }
    Ok(sent)
}


// =============================================================================
// SOL* PARKING — shared constants, accounting, SPL helpers
// =============================================================================
// The SOL pool does two jobs that both demand native lamports in this program's
// PDA: it is JAM's flash-loan liquidity (paid out and repaid in one tx) and it
// is depositor collateral (`withdraw_sol` pays out synchronously). Neither can
// be served from a yield-bearing wrapper, so the pool splits into a hot buffer
// and a parked tranche. See SOL-STAR-REFERENCE.md for the verified interface.
//
// REDEMPTION IS NOT ATOMIC ON THE ISSUER'S SIDE. `burn_token` has two shapes:
// `Sync`, paid from their unlent reserves, and `Async`, which queues an
// `AsyncBurnRequest` in a FIFO epoch only their manager can settle, with the
// payout haircut by unwind loss. We only ever send `Sync`: if reserves are
// short the CPI reverts and the tranche stays parked. This program never holds
// a claim it cannot value, and never owes a depositor out of a queue position.
//
// VALUATION reads none of their account layout — the tranche is marked at cost
// less `sol_star_haircut_bps`, and carry is realised at unpark. Understating is
// the safe direction: `has_capacity` gets stricter, never looser. Their
// `recollateralize_loss` instruction is proof share price can fall.

/// Native SOL mint — the collateral SOL* is minted against.
pub const WSOL_MINT: Pubkey = Pubkey::new_from_array([
    6, 155, 136, 87, 254, 171, 129, 132, 251, 104, 127, 99, 70, 24, 192, 53,
    218, 196, 57, 220, 26, 235, 59, 85, 152, 160, 240, 0, 0, 0, 0, 1,
]);

/// `long_yield_carry::mint_token` — sha256("global:mint_token")[..8].
pub const MINT_TOKEN_DISC: [u8; 8] = [172, 137, 183, 14, 207, 110, 234, 56];
/// `long_yield_carry::burn_token` — sha256("global:burn_token")[..8].
pub const BURN_TOKEN_DISC: [u8; 8] = [185, 165, 216, 246, 144, 31, 70, 74];
/// Borsh discriminant of `BurnTokenParams::Sync { burn_amount: u64 }`.
pub const BURN_PARAMS_SYNC: u8 = 0;

/// The buffer floor can never be configured below this, whatever an admin sets.
pub const MIN_BUFFER_BPS: u16 = 2_000; // 20% stays native, always

/// Ceiling on the discretionary hold, so a mis-set config cannot freeze the
/// tranche for years. Liquidity refills are exempt from the hold entirely.
pub const MAX_MIN_PARK_SECS: i64 = 90 * 86_400;

/// Total SOL backing the pool, hot and parked, in lamports at cost.
pub fn sol_total_lamports(bank: &Depository) -> u64 {
    bank.sol_lamports.saturating_add(bank.sol_star_cost_lamports)
}

/// Lamports that must remain native and immediately payable.
pub fn required_buffer(bank: &Depository, buffer_bps: u16) -> u64 {
    let bps = buffer_bps.max(MIN_BUFFER_BPS) as u128;
    ((sol_total_lamports(bank) as u128).saturating_mul(bps) / 10_000) as u64
}

/// Deadband width as a share of the pool. Both halves matter: without the
/// minimum size a keeper parks dust every slot, and without the pre-park margin
/// the buffer oscillates around its floor. At ~40 bps a round trip, that churn
/// is a straight leak.
pub fn park_band(bank: &Depository, band_bps: u16) -> u64 {
    ((sol_total_lamports(bank) as u128).saturating_mul(band_bps as u128) / 10_000) as u64
}


/// Lamports the pool credits as depositor collateral: hot at face plus the
/// parked tranche net of its haircut.
pub fn credited_lamports(bank: &Depository) -> u64 {
    bank.sol_lamports.saturating_add(bank.sol_star_credited_lamports)
}

/// Move bank-level SOL credit in either direction. Parking haircuts it down;
/// unparking restores it and books realised carry.
pub fn adjust_sol_credit(bank: &mut Depository, usd: i64) {
    // Against earnings, not principal. A parking haircut or a realised carry
    // changes what the pool is worth without changing what anybody deposited,
    // so putting it in `total_deposits` broke the identity that total is the
    // sum of the parts — and left the difference belonging to nobody.
    // Earnings are exactly the right home: a gain is shared by tenure, a loss
    // comes off the shared surplus before it can reach anyone's stake.
    if usd >= 0 {
        let v = usd as u64;
        bank.sol_usd_contrib = bank.sol_usd_contrib.saturating_add(v);
        bank.yield_pool = bank.yield_pool.saturating_add(v);
    } else {
        let v = usd.unsigned_abs();
        bank.sol_usd_contrib = bank.sol_usd_contrib.saturating_sub(v);
        // Only once the surplus is gone does a loss touch principal.
        let from_yield = v.min(bank.yield_pool);
        bank.yield_pool -= from_yield;
        bank.total_deposits = bank.total_deposits.saturating_sub(v - from_yield);
    }
}


/// The accounts a Kestrel round trip needs. Parking and unparking want the
/// same ten — they differ only in which instruction they build and which way
/// the lamports run — so they share one set here instead of two account
/// contexts that have to be kept in step with each other by hand.
///
/// Holding them as `AccountInfo` is what lets both directions be reached from
/// `handle_in` and `handle_out` without either of those growing a second
/// context: the caller assembles this from whatever optional accounts it was
/// given, and the round trip does not care which instruction it came from.
pub struct SolStarLegs<'info> {
    pub sol_pool: AccountInfo<'info>,
    pub wsol_mint: AccountInfo<'info>,
    pub sol_star_mint: AccountInfo<'info>,
    pub pool_wsol: AccountInfo<'info>,
    pub pool_sol_star: AccountInfo<'info>,
    pub kestrel_program: AccountInfo<'info>,
    pub kestrel_token: AccountInfo<'info>,
    pub collateral_vault: AccountInfo<'info>,
    pub token_program: AccountInfo<'info>,
    pub sol_star_token_program: AccountInfo<'info>,
    pub associated_token_program: AccountInfo<'info>,
    pub system_program: AccountInfo<'info>,
    pub pool_bump: u8,
}

/// Kestrel accounts carried past the price feed in `remaining_accounts`, in
/// this order. They ride there rather than in the account contexts because
/// `Stockup` and `Withdraw` would otherwise each grow the same nine fields —
/// and `Withdraw::try_accounts` has already been over the 4KB frame once.
/// Their presence is the parameter: bring them and the round trip runs, leave
/// them out and the deposit or withdrawal proceeds without it.
pub const SOL_STAR_LEGS: usize = 9;

impl<'info> SolStarLegs<'info> {
    /// Assemble from `remaining_accounts`, validating every address here
    /// instead of in two account contexts that would have to agree.
    /// `rest` is `remaining_accounts` past the price feed.
    pub fn from_remaining(config: &ProgramConfig, sol_pool: &AccountInfo<'info>,
        pool_bump: u8, token_program: &AccountInfo<'info>,
        system_program: &AccountInfo<'info>,
        rest: &[AccountInfo<'info>]) -> Result<Option<Self>> {
        if rest.len() < SOL_STAR_LEGS { return Ok(None); }
        let legs = Self {
            sol_pool: sol_pool.clone(),
            kestrel_token: rest[0].clone(),
            collateral_vault: rest[1].clone(),
            wsol_mint: rest[2].clone(),
            sol_star_mint: rest[3].clone(),
            pool_wsol: rest[4].clone(),
            pool_sol_star: rest[5].clone(),
            kestrel_program: rest[6].clone(),
            sol_star_token_program: rest[7].clone(),
            associated_token_program: rest[8].clone(),
            token_program: token_program.clone(),
            system_program: system_program.clone(),
            pool_bump,
        };

        // Only the address is checked here, not that parking is switched on.
        // Unwinding must stay possible in states where parking is not: the
        // instruction this replaced kept its unpark path alive for exactly
        // that reason, and `park_idle_sol` is where the enabled check belongs.
        require!(*legs.kestrel_program.key == config.kestrel_program,
                 PithyQuip::InvalidSettlementProgram);
        require!(*legs.sol_star_mint.key == config.sol_star_mint, PithyQuip::InvalidMint);
        require!(*legs.wsol_mint.key == WSOL_MINT, PithyQuip::InvalidMint);
        require!(*legs.associated_token_program.key == anchor_spl::associated_token::ID,
                 PithyQuip::InvalidParameters);
        require!(*legs.sol_star_token_program.key == anchor_spl::token::ID
              || *legs.sol_star_token_program.key == anchor_spl::token_2022::ID,
                 PithyQuip::InvalidParameters);

        // The two pool ATAs are where SOL* and wSOL land. Deriving them rather
        // than trusting the caller is the whole of the security here: a
        // substituted account would mint the pool's SOL* to somebody else.
        require!(*legs.pool_wsol.key == get_associated_token_address_with_program_id(
                     sol_pool.key, legs.wsol_mint.key, legs.token_program.key),
                 PithyQuip::InvalidParameters);
        require!(*legs.pool_sol_star.key == get_associated_token_address_with_program_id(
                     sol_pool.key, legs.sol_star_mint.key, legs.sol_star_token_program.key),
                 PithyQuip::InvalidParameters);
        Ok(Some(legs))
    }

    /// Both directions need the pool's ATAs to exist, and `unpark` closes the
    /// wSOL one on its way out, so neither can assume the other left it there.
    fn ensure_atas(&self, payer: &AccountInfo<'info>) -> Result<()> {
        for (ata, mint, tp) in [
            (&self.pool_wsol, &self.wsol_mint, &self.token_program),
            (&self.pool_sol_star, &self.sol_star_mint, &self.sol_star_token_program),
        ] {
            if !ata.data_is_empty() { continue; }
            anchor_spl::associated_token::create_idempotent(CpiContext::new(
                self.associated_token_program.clone(),
                anchor_spl::associated_token::Create {
                    payer: payer.clone(),
                    associated_token: ata.clone(),
                    authority: self.sol_pool.clone(),
                    mint: mint.clone(),
                    system_program: self.system_program.clone(),
                    token_program: tp.clone(),
                }))?;
        }
        Ok(())
    }

    /// Wrap `lamports` and mint SOL* against them. Returns shares received.
    pub fn park(&self, payer: &AccountInfo<'info>, lamports: u64) -> Result<u64> {
        self.ensure_atas(payer)?;
        let seeds: &[&[&[u8]]] = &[&[SOL_POOL_SEED, &[self.pool_bump]]];

        // ── wrap: lamports → wSOL in the pool's own ATA ──────────────────────
        invoke_signed(
            &system_instruction::transfer(self.sol_pool.key,
                                          self.pool_wsol.key, lamports),
            &[self.sol_pool.clone(), self.pool_wsol.clone(),
              self.system_program.clone()], seeds)?;

        invoke(&spl_sync_native(self.token_program.key, self.pool_wsol.key)?,
               &[self.pool_wsol.clone()])?;

        // ── mint_token(deposit_amount = lamports) ────────────────────────────
        let before = token_amount(&self.pool_sol_star)?;

        let mut data = Vec::with_capacity(16);
        data.extend_from_slice(&MINT_TOKEN_DISC);
        data.extend_from_slice(&lamports.to_le_bytes());

        let ix = Instruction {
            program_id: *self.kestrel_program.key,
            accounts: vec![
                AccountMeta::new_readonly(*self.sol_pool.key, true),
                AccountMeta::new(*self.kestrel_token.key, false),
                AccountMeta::new(*self.sol_star_mint.key, false),
                AccountMeta::new_readonly(*self.wsol_mint.key, false),
                AccountMeta::new(*self.pool_wsol.key, false),
                AccountMeta::new(*self.pool_sol_star.key, false),
                AccountMeta::new(*self.collateral_vault.key, false),
                AccountMeta::new_readonly(*self.sol_star_token_program.key, false),
                AccountMeta::new_readonly(*self.token_program.key, false),
            ],
            data,
        };
        invoke_signed(&ix, &[
            self.sol_pool.clone(), self.kestrel_token.clone(),
            self.sol_star_mint.clone(), self.wsol_mint.clone(),
            self.pool_wsol.clone(), self.pool_sol_star.clone(),
            self.collateral_vault.clone(),
            self.sol_star_token_program.clone(), self.token_program.clone(),
        ], seeds)?;

        let shares_out = token_amount(&self.pool_sol_star)?.saturating_sub(before);
        require!(shares_out > 0, PithyQuip::InsufficientFunds);

        // The wrap must have been fully consumed — a partial deposit would
        // strand lamports as wSOL, counted as neither hot nor parked.
        require!(token_amount(&self.pool_wsol)? == 0, PithyQuip::InvalidAmount);
        Ok(shares_out)
    }

    /// Burn `shares` of SOL* and unwrap the proceeds back into the pool.
    /// Returns lamports recovered. `payer` funds the redemption accounts and
    /// must be a signer of the enclosing transaction.
    pub fn unpark(&self, payer: &AccountInfo<'info>, shares: u64) -> Result<u64> {
        self.ensure_atas(payer)?;
        let seeds: &[&[&[u8]]] = &[&[SOL_POOL_SEED, &[self.pool_bump]]];
        let wsol_before = token_amount(&self.pool_wsol)?;

        // Sync only — never Async. Their handler reverts if unlent reserves are
        // short, which is the behaviour we want: the refill fails loudly
        // instead of this program acquiring a queued claim it cannot pay a
        // depositor out of.
        let mut data = Vec::with_capacity(17);
        data.extend_from_slice(&BURN_TOKEN_DISC);
        data.push(BURN_PARAMS_SYNC);
        data.extend_from_slice(&shares.to_le_bytes());

        // Anchor encodes an omitted `Option<Account>` as the program's own id.
        let none = *self.kestrel_program.key;

        let ix = Instruction {
            program_id: *self.kestrel_program.key,
            accounts: vec![
                AccountMeta::new_readonly(*self.sol_pool.key, true),
                AccountMeta::new(*payer.key, true),
                AccountMeta::new(*self.kestrel_token.key, false),
                AccountMeta::new(*self.sol_star_mint.key, false),
                AccountMeta::new(*self.pool_sol_star.key, false),
                AccountMeta::new_readonly(*self.wsol_mint.key, false),
                AccountMeta::new(*self.pool_wsol.key, false),
                // Writable: burn_token pays the redemption out of this reserve.
                AccountMeta::new(*self.collateral_vault.key, false),
                AccountMeta::new_readonly(none, false),   // redemption_epoch = None
                AccountMeta::new_readonly(none, false),   // request          = None
                AccountMeta::new_readonly(none, false),   // request_token_ac = None
                AccountMeta::new_readonly(*self.sol_star_token_program.key, false),
                AccountMeta::new_readonly(*self.token_program.key, false),
                AccountMeta::new_readonly(*self.associated_token_program.key, false),
                AccountMeta::new_readonly(*self.system_program.key, false),
            ],
            data,
        };
        invoke_signed(&ix, &[
            self.sol_pool.clone(), payer.clone(), self.kestrel_token.clone(),
            self.sol_star_mint.clone(), self.pool_sol_star.clone(),
            self.wsol_mint.clone(), self.pool_wsol.clone(),
            self.collateral_vault.clone(), self.kestrel_program.clone(),
            self.sol_star_token_program.clone(), self.token_program.clone(),
            self.associated_token_program.clone(), self.system_program.clone(),
        ], seeds)?;

        let lamports_out = token_amount(&self.pool_wsol)?.saturating_sub(wsol_before);
        require!(lamports_out > 0, PithyQuip::InsufficientFunds);

        // ── unwrap: close the wSOL ATA back into the pool ────────────────────
        // Closing returns balance + rent to sol_pool. Only the balance is
        // credited to sol_lamports; the rent was funded by whoever opened the
        // ATA and stays as pool slack rather than depositor collateral.
        invoke_signed(&spl_close_account(self.token_program.key,
                self.pool_wsol.key, self.sol_pool.key, self.sol_pool.key)?,
            &[self.pool_wsol.clone(), self.sol_pool.clone()], seeds)?;
        Ok(lamports_out)
    }
}

/// Lamports valued in USD, less the collar — the conservative mark the pool
/// credits SOL collateral at. Lives here with the rest of the SOL helpers
/// now that both the park and unpark sides need it.
pub fn collar_adjusted_usd(lamports: u64, price: u64, actuary: &Actuary) -> u64 {
    let collar = crate::etc::collar_bps(100, actuary) as u64;
    let raw = (lamports as u128)
        .saturating_mul(price as u128)
        .checked_div(1_000_000_000u128)
        .unwrap_or(0).min(u64::MAX as u128) as u64;
    raw.saturating_sub(raw.saturating_mul(collar) / 10_000)
}

/// Park whatever the hot buffer holds above its floor, if that excess is at
/// least a full band wide. Called from `handle_in` rather than by a keeper: a
/// deposit is the moment the buffer grows, so it is the moment the question
/// arises, and hanging it off the deposit means no keeper has to be alive for
/// idle SOL to earn.
///
/// Silent when there is nothing to do. Not silent when Kestrel refuses — a
/// caller who does not want a deposit to depend on Kestrel being up simply
/// leaves the accounts out, and that is the parameter.
pub fn park_idle_sol<'info>(bank: &mut Depository, config: &ProgramConfig,
    legs: &SolStarLegs<'info>, payer: &AccountInfo<'info>, sol_price: u64,
    actuary: &Actuary, now: i64) -> Result<u64> {
    // Parking is the direction that can be switched off; unparking is not.
    require!(config.kestrel_program != Pubkey::default(), PithyQuip::Unauthorized);
    let floor = required_buffer(bank, config.sol_buffer_bps);
    let band = park_band(bank, config.sol_park_band_bps);
    // Both halves of the deadband: act only when the hot side is a full band
    // clear of its floor, and only in band-sized moves. At ~40bps a round trip
    // the churn of parking dust every slot is a straight leak.
    if bank.sol_lamports < floor.saturating_add(band) { return Ok(0); }
    let lamports = bank.sol_lamports.saturating_sub(floor);
    if lamports < band { return Ok(0); }

    let shares_out = legs.park(payer, lamports)?;

    let haircut_lamports = ((lamports as u128)
        .saturating_mul(config.sol_star_haircut_bps as u128) / 10_000) as u64;

    bank.sol_lamports = bank.sol_lamports.saturating_sub(lamports);
    bank.sol_star_shares = bank.sol_star_shares.saturating_add(shares_out);
    bank.sol_star_cost_lamports = bank.sol_star_cost_lamports.saturating_add(lamports);
    bank.sol_star_credited_lamports = bank.sol_star_credited_lamports
        .saturating_add(lamports.saturating_sub(haircut_lamports));
    bank.sol_star_parked_at = now;

    let usd = collar_adjusted_usd(haircut_lamports, sol_price, actuary);
    adjust_sol_credit(bank, -(usd.min(i64::MAX as u64) as i64));
    emit!(SolParked { lamports, shares_out, credit_haircut_usd: usd });
    Ok(lamports)
}

/// Unpark enough to pay a withdrawal the hot buffer cannot cover, and return
/// the round-trip loss the withdrawer is charged for it.
///
/// The loss lands on the depositor who forced the unwind rather than on the
/// pool. Parked SOL is the pool's yield position; demanding it back early is a
/// demand for immediacy, and socialising the ~40bps would pay for that
/// immediacy out of the depositors who did not ask for it — the first-mover
/// subsidy that makes a run rational. Charging it to the caller makes leaving
/// early cost exactly what leaving early costs.
///
/// Deliberately not subject to `sol_min_park_secs`: the hold is there to stop
/// discretionary churn, and turning it on a depositor's own withdrawal would
/// convert a yield optimisation into a liquidity trap.
pub fn unpark_for_withdrawal<'info>(bank: &mut Depository, config: &ProgramConfig,
    legs: &SolStarLegs<'info>, payer: &AccountInfo<'info>, wanted: u64,
    sol_price: u64, actuary: &Actuary) -> Result<u64> {
    let deficit = wanted.saturating_sub(bank.sol_lamports);
    if deficit == 0 { return Ok(0); }
    require!(bank.sol_star_shares > 0 && bank.sol_star_cost_lamports > 0,
             PithyQuip::InsufficientFunds);

    // Shares whose cost covers the deficit, rounded up so one lamport short
    // does not fail the withdrawal.
    let shares = (((deficit as u128).saturating_mul(bank.sol_star_shares as u128)
            + bank.sol_star_cost_lamports as u128 - 1)
            / bank.sol_star_cost_lamports as u128)
        .min(bank.sol_star_shares as u128) as u64;

    let pro_rata = |v: u64| ((v as u128).saturating_mul(shares as u128)
        .checked_div(bank.sol_star_shares as u128).unwrap_or(0)) as u64;
    let cost_released = pro_rata(bank.sol_star_cost_lamports);
    let credit_released = pro_rata(bank.sol_star_credited_lamports);

    let lamports_out = legs.unpark(payer, shares)?;
    // Bound what a single print can cost the withdrawer. Beyond the configured
    // haircut this is not a haircut, it is a bad price, and they are better
    // served by the withdrawal failing so they can size down or come back.
    let tolerated = cost_released.saturating_sub(
        ((cost_released as u128).saturating_mul(config.sol_star_haircut_bps as u128)
            / 10_000) as u64);
    require!(lamports_out >= tolerated, PithyQuip::InsufficientFunds);

    bank.sol_star_shares = bank.sol_star_shares.saturating_sub(shares);
    bank.sol_star_cost_lamports = bank.sol_star_cost_lamports.saturating_sub(cost_released);
    bank.sol_star_credited_lamports = bank.sol_star_credited_lamports
        .saturating_sub(credit_released);
    bank.sol_lamports = bank.sol_lamports.saturating_add(lamports_out);

    // The tranche was credited at `credit_released` and came back as
    // `lamports_out`. That difference is everything that happened while
    // parked — carry earned, the haircut released, an unwind loss — and it is
    // the pool's, booked once against the mark.
    let signed = (collar_adjusted_usd(lamports_out, sol_price, actuary)
                      .min(i64::MAX as u64) as i64)
        .saturating_sub(collar_adjusted_usd(credit_released, sol_price, actuary)
                      .min(i64::MAX as u64) as i64);
    if !bank.accrue_sol_yield(signed) { adjust_sol_credit(bank, signed); }
    emit!(SolUnparked { shares, lamports_out, cost_released, realised_usd: signed });

    // What the caller forfeits: cost in, lamports out. Left in the buffer, so
    // the pool holds slightly more than the sum of claims against it — the
    // conservative direction, and the same shape as the ATA rent slack.
    Ok(cost_released.saturating_sub(lamports_out))
}

/// Read an SPL token account's `amount` straight from account data, so balances
/// are re-read after a CPI rather than trusting Anchor's pre-CPI snapshot.
pub fn token_amount(info: &AccountInfo) -> Result<u64> {
    let data = info.try_borrow_data()?;
    require!(data.len() >= 72, PithyQuip::InvalidParameters);
    Ok(u64::from_le_bytes(data[64..72].try_into().unwrap()))
}

/// `SyncNative` — instruction 17 in both Token and Token-2022.
pub fn spl_sync_native(token_program: &Pubkey, account: &Pubkey)
    -> Result<anchor_lang::solana_program::instruction::Instruction> {
    require!(*token_program == anchor_spl::token::ID
          || *token_program == anchor_spl::token_2022::ID,
        PithyQuip::InvalidParameters);
    Ok(anchor_lang::solana_program::instruction::Instruction {
        program_id: *token_program,
        accounts: vec![anchor_lang::solana_program::instruction::AccountMeta::new(*account, false)],
        data: vec![17u8] })
}

/// `CloseAccount` — instruction 9 in both Token and Token-2022.
pub fn spl_close_account(token_program: &Pubkey, account: &Pubkey,
    destination: &Pubkey, authority: &Pubkey)
    -> Result<anchor_lang::solana_program::instruction::Instruction> {
    use anchor_lang::solana_program::instruction::AccountMeta;
    require!(*token_program == anchor_spl::token::ID
          || *token_program == anchor_spl::token_2022::ID,
        PithyQuip::InvalidParameters);
    Ok(anchor_lang::solana_program::instruction::Instruction {
        program_id: *token_program,
        accounts: vec![
            AccountMeta::new(*account, false),
            AccountMeta::new(*destination, false),
            AccountMeta::new_readonly(*authority, true),
        ], data: vec![9u8] })
}

#[event]
pub struct SolParked {
    pub lamports: u64,
    pub shares_out: u64,
    pub credit_haircut_usd: u64,
}

#[event]
pub struct SolUnparked {
    pub shares: u64,
    pub lamports_out: u64,
    pub cost_released: u64,
    pub realised_usd: i64,
}
