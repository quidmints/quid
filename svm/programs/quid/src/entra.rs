
use anchor_lang::prelude::*;
use anchor_spl::token_interface::{
    TokenInterface, TransferChecked,
    self, Mint, TokenAccount
};

use crate::etc::{ get_hex, PithyQuip, TickerRisk, SECONDS_PER_HOUR,
    SECONDS_PER_DAY, update_price_accumulator, get_twap_price,
    get_price_deviation
};

use crate::stay::*; use crate::state::*;
use anchor_lang::solana_program::{
    program::invoke_signed,
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

// Post-deploy: call update_config(None, Some(squads_vault_pda), ..., None) once
// with the hot deploy key to transfer admin to the Squads multisig.
pub fn init_config(ctx: Context<InitConfig>,
    keeper: Pubkey, token_mint: Pubkey) -> Result<()> {
    let config = &mut ctx.accounts.config;
    config.admin = ctx.accounts.admin.key();
    config.keeper = keeper;
    config.token_mint = token_mint;
    config.bump = ctx.bumps.config;
    config.registered_mints = [
          token_mint, USD_STAR];
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
    new_keeper: Option<Pubkey>, new_admin: Option<Pubkey>,
    set_bebop_authority: Option<Pubkey>) -> Result<()> {
    let config = &mut ctx.accounts.config;
    if let Some(k) = new_keeper {
        // SENSITIVE: rotates the trusted keeper. After rotation the new key
        // signs `resolve` + `enroll_device` + cosigns gated user txs.
        // Requires Squads proposal + 48h timelock (enforced by multisig config).
        config.keeper = k;
        config.config_version = config.config_version.saturating_add(1);
    }
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
        //
        // The pending_bebop_authority / bebop_authority_pending_since fields
        // and the accept_bebop_authority instruction are retained for schema
        // compatibility but no longer participate in the rotation flow.
        config.bebop_authority = authority;
    }
    Ok(())
}

/// Minimum seconds between proposing and committing a bebop_authority rotation.
pub const BEBOP_ROTATION_DELAY: i64 = 48 * 60 * 60;

pub fn accept_bebop_authority(ctx: Context<UpdateConfig>) -> Result<()> {
    let config = &mut ctx.accounts.config; let clock = Clock::get()?;
    let pending = config.pending_bebop_authority
        .ok_or(error!(PithyQuip::InvalidParameters))?;

    require!(clock.unix_timestamp.saturating_sub(
            config.bebop_authority_pending_since) >= BEBOP_ROTATION_DELAY,
        PithyQuip::TradingFrozen
    );
    config.bebop_authority = pending;
    config.pending_bebop_authority = None;
    config.bebop_authority_pending_since = 0;
    Ok(())
}

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

    #[account(mut)]
    pub quid: InterfaceAccount<'info, TokenAccount>,
    pub token_program: Interface<'info, TokenInterface>,
    pub system_program: Program<'info, System>,
}

pub fn handle_in(ctx: Context<Stockup>,
    amount: u64, ticker: String) -> Result<()> {
    require!(amount >= 100_000_000,
        PithyQuip::InvalidAmount);

    let bank = &mut ctx.accounts.bank;
    let clock = Clock::get()?;
    let right_now = clock.unix_timestamp;

    let customer = &mut ctx.accounts.depositor;
    let transfer_cpi_accounts = TransferChecked {
        from: ctx.accounts.quid.to_account_info(),
        mint: ctx.accounts.mint.to_account_info(),
        to: ctx.accounts.program_vault.to_account_info(),
        authority: ctx.accounts.signer.to_account_info(),
    };
    let decimals = ctx.accounts.mint.decimals;
    let cpi_program = ctx.accounts.token_program.to_account_info();
    let cpi_ctx = CpiContext::new(cpi_program,
            transfer_cpi_accounts);

    token_interface::transfer_checked(
            cpi_ctx, amount, decimals)?;

    if customer.owner == Pubkey::default() {
        customer.owner = ctx.accounts.signer.key();
    }
    if ticker.is_empty() {
        // Pool deposit — reuses pool_deposit() from Depositor impl
        customer.pool_deposit(bank, amount, right_now); return Ok(());
    } else { // Stock position — pledge collateral to specific ticker
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
        customer.renege(Some(t), amount as i64,
                        None, right_now)?;
    } customer.last_updated = right_now;
    bank.last_updated = right_now; Ok(())
}

// =============================================================================
// CREATE MARKET — single bond, no Switchboard, all resolution metadata in Market
// =============================================================================

#[derive(Accounts)]
#[instruction(params: CreateMarketParams)]
pub struct CreateMarket<'info> {
    #[account(mut)]
    pub authority: Signer<'info>,

    #[account(init_if_needed,
        space = 8 + Depository::INIT_SPACE,
        payer = authority, seeds = [b"depository"],
        bump)] pub bank: Box<Account<'info, Depository>>,

    #[account(init, payer = authority,
      space = Market::space_for(
          params.outcomes.len().max(2) as u8,
          params.question.len(),
          params.context.len(),
          params.exculpatory.len(),
          params.resolution_source.len()),
      seeds = [b"market", &bank.market_count.to_le_bytes()[..6]],
      bump)] pub market: Box<Account<'info, Market>>,

    /// CHECK: PDA derived from market seeds, validated by init
    #[account(mut,
      seeds = [b"sol_vault", &bank.market_count.to_le_bytes()[..6]],
      bump)] pub sol_vault: SystemAccount<'info>,

    #[account(init, payer = authority, space = AccuracyBuckets::SPACE,
      seeds = [b"accuracy_buckets", &bank.market_count.to_le_bytes()[..6]],
      bump)] pub accuracy_buckets: Box<Account<'info, AccuracyBuckets>>,

    #[account(seeds = [b"program_config"], bump = config.bump)]
    pub config: Box<Account<'info, ProgramConfig>>,

    pub system_program: Program<'info, System>,
}

pub fn create_market<'info>(ctx: Context<'_, '_, '_, 'info,
    CreateMarket<'info>>, params: CreateMarketParams) -> Result<()> {
    let clock = Clock::get()?;
    let bank = &mut ctx.accounts.bank;
    let market = &mut ctx.accounts.market;
    let right_now = clock.unix_timestamp;

    // ── Parameter validation ──
    require!(!params.question.is_empty()
          && params.question.len() <= 500,
          PithyQuip::InvalidParameters);

    require!(!params.context.is_empty()
          && params.context.len() <= 1000,
          PithyQuip::InvalidParameters);

    require!(!params.exculpatory.is_empty()
          && params.exculpatory.len() <= 1000,
            PithyQuip::InvalidParameters);

    require!(params.resolution_source.len() <= 200, PithyQuip::InvalidParameters);

    let outcomes = &params.outcomes;
    require!(outcomes.len() >= 2
          && outcomes.len() <= 20,
    PithyQuip::InvalidParameters);

    for (i, o) in outcomes.iter().enumerate() {
        require!(!o.is_empty() && o.len() <= 100,
                    PithyQuip::InvalidParameters);

        for j in (i + 1)..outcomes.len() {
            require!(o != &outcomes[j],
            PithyQuip::DuplicateOutcome);
        }
    }
    let num_outcomes = outcomes.len() as u8;
    let duration = params.deadline - right_now;
    require!(duration >= 24 * SECONDS_PER_HOUR
          && duration <= 365 * SECONDS_PER_DAY,
                PithyQuip::InvalidParameters);

    // ── Resolution mode + jury config ──
    require!(params.resolution_mode <= MODE_JURY_ONLY, PithyQuip::InvalidParameters);
    if params.resolution_mode == MODE_AI_PLUS_JURY
        || params.resolution_mode == MODE_JURY_ONLY {
        let jc = params.jury_config.as_ref()
            .ok_or(error!(PithyQuip::InvalidParameters))?;
        require!(jc.dst_eid > 0, PithyQuip::InvalidParameters);
    }

    // ── Bond: single transfer covers floor + resolution bond ──
    require!(params.creator_bond >= MIN_TOTAL_CREATOR_BOND,
             PithyQuip::OrderTooSmall);

    anchor_lang::system_program::transfer(
        CpiContext::new(
            ctx.accounts.system_program.to_account_info(),
            anchor_lang::system_program::Transfer {
                from: ctx.accounts.authority.to_account_info(),
                to: ctx.accounts.sol_vault.to_account_info(),
            }), params.creator_bond)?;

    require!(params.creator_fee_bps <= 2000, PithyQuip::InvalidParameters);
    require!(params.liquidity >= 100_000_000, PithyQuip::InvalidParameters);

    // Multi-winner validation
    let num_winners = if params.num_winners == 0 { 1 } else { params.num_winners };
    require!(num_winners >= 1 && (num_winners as usize) < outcomes.len(),
             PithyQuip::InvalidParameters);

    if !params.winning_splits.is_empty() {
        require!(params.winning_splits.len() == outcomes.len(),
                 PithyQuip::InvalidParameters);
        for &split in &params.winning_splits {
            require!(split <= 10_000, PithyQuip::InvalidParameters);
        }
    }
    if !params.beneficiaries.is_empty() {
        require!(params.beneficiaries.len() == outcomes.len(),
                 PithyQuip::InvalidParameters);
        if !params.winning_splits.is_empty() {
            for (i, &split) in params.winning_splits.iter().enumerate() {
                if split > 0 {
                    require!(params.beneficiaries[i].is_some(),
                             PithyQuip::InvalidParameters);
                }
            }
        }
    }

    let lambda_f64 = calculate_adaptive_lambda(duration, num_outcomes as usize);
    let lambda = (lambda_f64 * 100.0).clamp(10.0, 1000.0) as u64;

    // Initialize accuracy buckets
    let buckets = &mut ctx.accounts.accuracy_buckets;
    buckets.market = market.key();
    buckets.buckets = vec![0u64;
    AccuracyBuckets::NUM_BUCKETS];
    buckets.bump = ctx.bumps.accuracy_buckets;

    // Initialize market
    market.market_id = bank.market_count;
    market.creator = ctx.accounts.authority.key();
    market.question = params.question.clone();
    market.context = params.context.clone();
    market.exculpatory = params.exculpatory.clone();
    market.resolution_source = params.resolution_source.clone();
    market.outcomes = params.outcomes.clone();
    market.num_outcomes = num_outcomes;

    market.start_time = right_now;
    market.deadline = params.deadline;
    market.creator_fee_bps = params.creator_fee_bps;
    market.creator_bond_lamports = params.creator_bond;
    market.sol_vault_bump = ctx.bumps.sol_vault;

    market.tokens_sold_per_outcome = vec![0u64; num_outcomes as usize];
    market.total_capital = 0;
    market.total_capital_per_outcome = vec![0u64; num_outcomes as usize];
    market.fees_collected = 0;

    market.resolved = false;
    market.cancelled = false;
    market.winning_outcome = 0;
    market.resolution_confidence = 0;
    market.resolution_time = 0;
    market.winning_sides = Vec::new();
    market.winning_splits = params.winning_splits.clone();
    market.num_winners = num_winners;
    market.beneficiaries = params.beneficiaries.clone();
    market.challenge_count = 0;
    market.challenged = false;

    market.positions_revealed = 0;
    market.positions_total = 0;
    market.positions_processed = 0;
    market.total_winner_weight_revealed = 0;
    market.total_loser_weight_revealed = 0;
    market.total_winner_capital_revealed = 0;
    market.total_loser_capital_revealed = 0;
    market.winner_weight_per_outcome = vec![0u128; num_outcomes as usize];
    market.weights_complete = false;
    market.payouts_complete = false;

    market.liquidity = params.liquidity;
    market.time_decay_lambda = lambda;

    market.price_cumulative_per_outcome = vec![0u128; num_outcomes as usize];
    market.price_checkpoint_per_outcome = vec![0u128; num_outcomes as usize];
    market.last_price_update = right_now;
    market.checkpoint_timestamp = right_now;

    // Resolution accounting (folded in from removed MarketEvidence)
    market.resolution_mode = params.resolution_mode;
    market.resolution_bond = RESOLUTION_BOND;
    market.oracle_compute_cost = params.oracle_compute_cost;
    market.oracle_claimed = false;
    market.jury_config = params.jury_config.clone();

    // Resolution thread — empty until resolve()
    market.resolution_thread_url = String::new();
    market.thread_content_hash = [0u8; 32];

    // Cross-chain resolution defaults
    market.resolution_requested = false;
    market.resolution_received = false;
    market.resolution_requester = None;
    market.resolution_requested_time = None;
    market.resolution_finalized = 0;
    market.jury_fee_pool = 0;

    market.bump = ctx.bumps.market;
    bank.market_count += 1;

    emit!(MarketCreated {
        market_id: market.market_id,
        market_key: market.key(),
        question: market.question.clone(),
        outcomes: market.outcomes.clone(),
        creator: market.creator,
        deadline: market.deadline,
    });
    Ok(())
}

// =============================================================================
// PLACE ORDER — bet on a prediction market outcome
// =============================================================================

#[derive(Accounts)]
#[instruction(params: OrderParams)]
pub struct PlaceOrder<'info> {
    #[account(mut, seeds = [b"market",
    &market.market_id.to_le_bytes()[..6]],
    bump = market.bump)]
    pub market: Box<Account<'info, Market>>,

    #[account(init_if_needed,
        payer = user, space = Position::SPACE,
        seeds = [b"position", market.key().as_ref(),
        user.key().as_ref(), &[params.outcome]], bump)]
    pub position: Box<Account<'info, Position>>,

    #[cfg_attr(feature = "mainnet", account(
        constraint = config.registered_mints.contains(&mint.key())
            @ PithyQuip::InvalidMint
    ))]
    pub mint: InterfaceAccount<'info, Mint>,

    #[account(seeds = [b"program_config"], bump = config.bump)]
    pub config: Box<Account<'info, ProgramConfig>>,

    #[account(mut, seeds = [b"vault",
        mint.key().as_ref()], bump)]
    pub program_vault: InterfaceAccount<'info, TokenAccount>,

    #[account(mut)]
    pub user: Signer<'info>,

    #[account(mut, seeds = [b"depository"], bump)]
    pub bank: Box<Account<'info, Depository>>,

    #[account(init_if_needed, payer = user,
        space = 8 + Depositor::INIT_SPACE,
        seeds = [user.key().as_ref()], bump)]
    pub depositor: Box<Account<'info, Depositor>>,

    #[account(mut)]
    pub quid: InterfaceAccount<'info, TokenAccount>,
    pub token_program: Interface<'info, TokenInterface>,
    pub system_program: Program<'info, System>,
}

pub fn place_order(ctx: Context<PlaceOrder>,
    params: OrderParams) -> Result<()> {
    let market = &mut ctx.accounts.market;
    let position = &mut ctx.accounts.position;
    let depositor = &mut ctx.accounts.depositor;
    let bank = &mut ctx.accounts.bank;

    let outcome = params.outcome;
    let clock = Clock::get()?;
    let capital = params.capital;
    let right_now = clock.unix_timestamp;
    let commitment_hash = params.commitment_hash;

    require!(capital >= 1000, PithyQuip::OrderTooSmall);
    require!(right_now < market.deadline, PithyQuip::TradingClosed);
    require!(!market.resolved && !market.cancelled, PithyQuip::TradingFrozen);
    require!((outcome as usize) < market.outcomes.len(), PithyQuip::InvalidParameters);
    require!(commitment_hash != [0u8; 32], PithyQuip::InvalidParameters);

    update_price_accumulator(market, right_now)?;
    let max_deviation_bps = params.max_deviation_bps.unwrap_or(300);
    let deviation = get_price_deviation(market, outcome, right_now);
    require!(deviation <= max_deviation_bps, PithyQuip::PriceManipulated);

    if depositor.owner == Pubkey::default() {
        depositor.owner = ctx.accounts.user.key();
        depositor.last_updated = right_now;
        depositor.deposited_quid = 0;
        depositor.deposit_seconds = 0;
        depositor.balances = Vec::new();
    } else {
        let td = right_now - depositor.last_updated;
        depositor.deposit_seconds += (td as u128) *
        (depositor.deposited_quid as u128);
        depositor.last_updated = right_now;
    }
    let total_needed = capital;
    let from_depositor = depositor.deposited_quid.min(total_needed);
    let from_cpi = total_needed.saturating_sub(from_depositor);
    if from_depositor > 0 {
        depositor.deposited_quid -= from_depositor;
        let td = right_now - bank.last_updated;
        bank.total_deposit_seconds += (bank.total_deposits as u128) * (td as u128);
        bank.total_deposits -= from_depositor;
        bank.last_updated = right_now;
    }
    if from_cpi > 0 {
        let decimals = ctx.accounts.mint.decimals;
        let transfer_ctx = CpiContext::new(
            ctx.accounts.token_program.to_account_info(),
            TransferChecked {
                from: ctx.accounts.quid.to_account_info(),
                mint: ctx.accounts.mint.to_account_info(),
                to: ctx.accounts.program_vault.to_account_info(),
                authority: ctx.accounts.user.to_account_info(),
            },
        );
        token_interface::transfer_checked(
         transfer_ctx, from_cpi, decimals)?;
    }
    let creator_fee = (capital as u128 * market.creator_fee_bps as u128) / 10_000;
    let net_capital = capital - creator_fee as u64;

    market.liquidity = calculate_adaptive_liquidity(market, right_now);
    let current_price = get_twap_price(market, outcome, right_now);
    let tokens_bought = (net_capital as f64 / current_price) as u64;
    require!(tokens_bought > 0, PithyQuip::OrderTooSmall);

    if position.market == Pubkey::default() {
        position.market = market.key();
        position.user = ctx.accounts.user.key();
        position.outcome = outcome;
        position.total_capital = 0;
        position.total_tokens = 0;
        position.total_capital_seconds = 0;
        position.entries = Vec::new();
        position.revealed_confidence = 0;
        position.accuracy_percentile = 0;
        position.weight = 0;
        position.reveal_delegate = params.reveal_delegate;
        position.bump = ctx.bumps.position;
        market.positions_total += 1;
    }
    require!(position.entries.len() < Position::MAX_ENTRIES,
                                PithyQuip::TooManyEntries);

    position.entries.push(PositionEntry { capital: net_capital,
        tokens: tokens_bought, timestamp: right_now,
        capital_seconds: 0, last_updated: right_now, commitment_hash,
        price_at_entry: (current_price * 10_000.0).round().clamp(1.0, 9_999.0) as u16,
    });
    position.total_capital += net_capital;
    position.total_tokens += tokens_bought;
    market.tokens_sold_per_outcome[outcome as usize] += tokens_bought;
    market.total_capital += net_capital;
    market.total_capital_per_outcome[outcome as usize] += net_capital;
    market.fees_collected += creator_fee as u64;
    Ok(())
}

// =============================================================================
// DEVICE ENROLLMENT (absorbed from acta.rs)
// =============================================================================

#[derive(Accounts)]
#[instruction(params: EnrollDeviceParams)]
pub struct EnrollDevice<'info> {
    #[account(mut)]
    pub payer: Signer<'info>,

    /// Keeper signs to authorize enrollment.
    pub keeper: Signer<'info>,

    #[account(seeds = [b"program_config"], bump = config.bump,
        constraint = keeper.key() == config.keeper @ PithyQuip::Unauthorized,
    )]
    pub config: Account<'info, ProgramConfig>,

    #[account(init, payer = payer,
        space = DeviceEnrollment::SPACE,
        seeds = [b"device_enrollment",
        params.device_pubkey.as_ref()],
        bump,
    )]
    pub enrollment: Account<'info, DeviceEnrollment>,

    pub system_program: Program<'info, System>,
}

pub fn enroll_device(ctx: Context<EnrollDevice>,
    params: EnrollDeviceParams) -> Result<()> {
    require!(params.config_version == ctx.accounts.config.config_version,
        PithyQuip::Unauthorized);

    require!(params.platform == DeviceEnrollment::PLATFORM_ANDROID_STRONGBOX
          || params.platform == DeviceEnrollment::PLATFORM_IOS_SECURE_ENCLAVE
          || params.platform == DeviceEnrollment::PLATFORM_WEB,
        PithyQuip::InvalidParameters);

    let e = &mut ctx.accounts.enrollment;
    e.device_pubkey = params.device_pubkey;
    e.config_version = params.config_version;
    e.revoked = false;
    e.platform = params.platform;
    e.bump = ctx.bumps.enrollment;

    emit!(DeviceEnrolled {
        device_pubkey: params.device_pubkey,
        platform: params.platform,
    });
    Ok(())
}

#[derive(Accounts)]
pub struct RevokeEnrollment<'info> {
    #[account(mut,
        seeds = [b"device_enrollment",
        enrollment.device_pubkey.as_ref()],
        bump = enrollment.bump,
    )]
    pub enrollment: Account<'info, DeviceEnrollment>,

    #[account(seeds = [b"program_config"], bump = config.bump)]
    pub config: Account<'info, ProgramConfig>,

    pub signer: Signer<'info>,
}

pub fn revoke_enrollment(ctx: Context<RevokeEnrollment>) -> Result<()> {
    let is_admin  = ctx.accounts.signer.key() == ctx.accounts.config.admin;
    let is_device = ctx.accounts.signer.key() == ctx.accounts.enrollment.device_pubkey;
    require!(is_admin || is_device, PithyQuip::Unauthorized);
    ctx.accounts.enrollment.revoked = true;
    Ok(())
}

// =============================================================================
// SOL deposit / collateral
// =============================================================================
//
// SOL serves two roles simultaneously:
//   1. Flash-loan liquidity for JAM (sol_lamports in Depository)
//   2. Collateral for synthetic positions (sol_pledged_usd added to deposited_quid)

pub fn collar_adjusted_usd(lamports: u64, price: u64, actuary: &crate::etc::Actuary) -> u64 {
    let collar = crate::etc::collar_bps(100, actuary) as u64;
    let raw = (lamports as u128)
        .saturating_mul(price as u128)
        .checked_div(1_000_000_000u128)
        .unwrap_or(0).min(u64::MAX as u128) as u64;
    raw.saturating_sub(raw.saturating_mul(collar) / 10_000)
}

#[derive(Accounts)]
pub struct DepositSol<'info> {
    #[account(mut)]
    pub depositor: Signer<'info>,

    #[account(
        init_if_needed, payer = depositor,
        space = 8 + Depositor::INIT_SPACE,
        seeds = [depositor.key().as_ref()], bump,
    )]
    pub customer_account: Box<Account<'info, Depositor>>,

    #[account(mut, seeds = [b"depository"], bump)]
    pub bank: Box<Account<'info, Depository>>,

    #[account(
        init_if_needed, payer = depositor,
        space = 8 + TickerRisk::INIT_SPACE,
        seeds = [b"risk", "SOL".as_bytes()], bump,
    )]
    pub sol_risk: Box<Account<'info, TickerRisk>>,

    /// CHECK: PDA verified by seeds
    #[account(mut, seeds = [SOL_POOL_SEED], bump)]
    pub sol_pool: AccountInfo<'info>,

    pub system_program: Program<'info, System>,
}

pub fn handle_deposit_sol(ctx: Context<DepositSol>, lamports: u64) -> Result<()> {
    require!(lamports > 0, PithyQuip::InvalidAmount);

    let clock = Clock::get()?;
    let now = clock.unix_timestamp;
    let slot = clock.slot as i64;

    let pyth = ctx.remaining_accounts.first();
    let sol_price = crate::etc::fetch_price("SOL", pyth)?;

    let risk = &mut ctx.accounts.sol_risk;
    if risk.ticker == [0u8; 8] {
        risk.ticker = Depositor::pad_ticker("SOL");
        risk.bump = ctx.bumps.sol_risk;
        risk.actuary.obs_count = 10;
    }   risk.actuary.update_price(sol_price as i64, slot);

    let bank = &mut ctx.accounts.bank;
    let customer = &mut ctx.accounts.customer_account;
    if customer.owner == Pubkey::default() {
        customer.owner = ctx.accounts.depositor.key();
    }
    bank.sol_lamports = bank.sol_lamports.saturating_add(lamports);
    customer.deposited_lamports = customer.deposited_lamports.saturating_add(lamports);
    anchor_lang::system_program::transfer(
        CpiContext::new(
            ctx.accounts.system_program.to_account_info(),
            anchor_lang::system_program::Transfer {
                from: ctx.accounts.depositor.to_account_info(),
                to: ctx.accounts.sol_pool.to_account_info(),
            },
        ),
        lamports,
    )?;
    let sol_usd_floor = collar_adjusted_usd(lamports, sol_price, &risk.actuary);
    customer.sol_pledged_usd = customer.sol_pledged_usd.saturating_add(sol_usd_floor);
    bank.sol_usd_contrib = bank.sol_usd_contrib.saturating_add(sol_usd_floor);
    customer.pool_deposit(bank, sol_usd_floor, now);
    Ok(())
}

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
// TEST HELPERS
// =============================================================================

#[cfg(feature = "testing")]
#[derive(Accounts)]
#[instruction(params: CreateMarketParams)]
pub struct TestCreateMarket<'info> {
    #[account(mut)]
    pub authority: Signer<'info>,

    #[account(init_if_needed,
        space = 8 + Depository::INIT_SPACE,
        payer = authority, seeds = [b"depository"],
        bump)] pub bank: Box<Account<'info, Depository>>,

    #[account(init, payer = authority,
      space = Market::space_for(
          params.outcomes.len().max(2) as u8,
          params.question.len(),
          params.context.len(),
          params.exculpatory.len(),
          params.resolution_source.len()),
      seeds = [b"market", &bank.market_count.to_le_bytes()[..6]],
      bump)] pub market: Box<Account<'info, Market>>,

    /// CHECK: PDA derived from market seeds
    #[account(mut,
      seeds = [b"sol_vault", &bank.market_count.to_le_bytes()[..6]],
      bump)]
    pub sol_vault: SystemAccount<'info>,

    #[account(init, payer = authority, space = AccuracyBuckets::SPACE,
      seeds = [b"accuracy_buckets", &bank.market_count.to_le_bytes()[..6]],
      bump)] pub accuracy_buckets: Box<Account<'info, AccuracyBuckets>>,

    pub system_program: Program<'info, System>,
}

#[cfg(feature = "testing")]
pub fn test_create_market(ctx: Context<TestCreateMarket>,
    params: CreateMarketParams) -> Result<()> {
    let clock = Clock::get()?;
    let bank = &mut ctx.accounts.bank;
    let market = &mut ctx.accounts.market;
    let right_now = clock.unix_timestamp;

    let outcomes = &params.outcomes;
    require!(outcomes.len() >= 2 && outcomes.len() <= 20, PithyQuip::InvalidParameters);
    let num_outcomes = outcomes.len() as u8;

    let duration = params.deadline - right_now;
    require!(duration >= SECONDS_PER_HOUR && duration <= 365 * SECONDS_PER_DAY,
             PithyQuip::InvalidParameters);

    // Allow lower bond in tests for ergonomics
    require!(params.creator_bond > 0, PithyQuip::OrderTooSmall);
    anchor_lang::system_program::transfer(
        CpiContext::new(
            ctx.accounts.system_program.to_account_info(),
            anchor_lang::system_program::Transfer {
                from: ctx.accounts.authority.to_account_info(),
                to: ctx.accounts.sol_vault.to_account_info(),
            },
        ),
        params.creator_bond,
    )?;

    let lambda_f64 = calculate_adaptive_lambda(duration, num_outcomes as usize);
    let lambda = (lambda_f64 * 100.0).clamp(10.0, 1000.0) as u64;

    let buckets = &mut ctx.accounts.accuracy_buckets;
    buckets.market = market.key();
    buckets.buckets = vec![0u64; AccuracyBuckets::NUM_BUCKETS];
    buckets.bump = ctx.bumps.accuracy_buckets;

    market.market_id = bank.market_count;
    market.creator = ctx.accounts.authority.key();
    market.question = params.question.clone();
    market.context = params.context.clone();
    market.exculpatory = params.exculpatory.clone();
    market.resolution_source = params.resolution_source.clone();
    market.outcomes = params.outcomes.clone();
    market.num_outcomes = num_outcomes;

    market.start_time = right_now;
    market.deadline = params.deadline;
    market.creator_fee_bps = params.creator_fee_bps;
    market.creator_bond_lamports = params.creator_bond;
    market.sol_vault_bump = ctx.bumps.sol_vault;

    market.tokens_sold_per_outcome = vec![0u64; num_outcomes as usize];
    market.total_capital = 0;
    market.total_capital_per_outcome = vec![0u64; num_outcomes as usize];
    market.fees_collected = 0;

    market.resolved = false;
    market.cancelled = false;
    market.winning_outcome = 0;
    market.resolution_confidence = 0;
    market.resolution_time = 0;
    let num_winners = if params.num_winners == 0 { 1 } else { params.num_winners };
    market.winning_sides = Vec::new();
    market.winning_splits = params.winning_splits.clone();
    market.num_winners = num_winners;
    market.beneficiaries = params.beneficiaries.clone();
    market.challenge_count = 0;
    market.challenged = false;

    market.positions_revealed = 0;
    market.positions_total = 0;
    market.positions_processed = 0;
    market.total_winner_weight_revealed = 0;
    market.total_loser_weight_revealed = 0;
    market.total_winner_capital_revealed = 0;
    market.total_loser_capital_revealed = 0;
    market.winner_weight_per_outcome = vec![0u128; num_outcomes as usize];
    market.weights_complete = false;
    market.payouts_complete = false;

    market.liquidity = params.liquidity;
    market.time_decay_lambda = lambda;

    market.price_cumulative_per_outcome = vec![0u128; num_outcomes as usize];
    market.price_checkpoint_per_outcome = vec![0u128; num_outcomes as usize];
    market.last_price_update = right_now;
    market.checkpoint_timestamp = right_now;

    market.resolution_mode = params.resolution_mode;
    market.resolution_bond = RESOLUTION_BOND;
    market.oracle_compute_cost = params.oracle_compute_cost;
    market.oracle_claimed = false;
    market.jury_config = params.jury_config.clone();
    market.resolution_thread_url = String::new();
    market.thread_content_hash = [0u8; 32];

    market.resolution_requested = false;
    market.resolution_received = false;
    market.resolution_requester = None;
    market.resolution_requested_time = None;
    market.resolution_finalized = 0;
    market.jury_fee_pool = 0;

    market.bump = ctx.bumps.market;
    bank.market_count += 1;

    Ok(())
}
