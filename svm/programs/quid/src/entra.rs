
use anchor_lang::prelude::*;
use anchor_spl::token_interface::{
    TokenInterface, TransferChecked,
    self, Mint, TokenAccount
};

use switchboard_on_demand::prelude::rust_decimal::prelude::ToPrimitive;
use crate::etc::{ get_hex, PithyQuip, TickerRisk, SECONDS_PER_HOUR,
    SECONDS_PER_DAY, update_price_accumulator,
    get_twap_price, get_price_deviation 
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

// Post-deploy: call update_config(None, Some(squads_vault_pda), ...) once
// with the hot deploy key to transfer admin to the Squads multisig.
// After that transfer, all config changes require Squads threshold + 48h timelock.
pub fn init_config(ctx: Context<InitConfig>,
    orchestrator: Pubkey, token_mint: Pubkey) -> Result<()> {
    let config = &mut ctx.accounts.config;
    config.admin = ctx.accounts.admin.key();
    config.orchestrator = orchestrator;
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
    new_orchestrator: Option<Pubkey>, new_admin: Option<Pubkey>,
    set_bebop_authority: Option<Pubkey>) -> Result<()> {
    let config = &mut ctx.accounts.config;
    if let Some(func) = new_orchestrator {
        // SENSITIVE: replaces the trusted oracle source for all risk calculations.
        // Requires Squads proposal + 48h timelock (enforced by multisig config).
        config.orchestrator = func;
    }
    if let Some(admin) = new_admin {
        config.admin = admin;
    }
    if let Some(authority) = set_bebop_authority {
        // Stages the rotation rather than applying it immediately.
        // Call accept_bebop_authority after BEBOP_ROTATION_DELAY (48 h) to commit.
        // This gives depositors an on-chain-enforceable exit window — the delay
        // cannot be bypassed even if the admin key is compromised, because
        // accept_bebop_authority checks the timestamp at execution time.
        let clock = Clock::get()?;
        config.pending_bebop_authority = Some(authority);
        config.bebop_authority_pending_since = clock.unix_timestamp;
    }
    Ok(())
}

/// Minimum seconds between proposing and committing a bebop_authority rotation.
/// Mirrors the Squads multisig time_lock recommendation — enforced on-chain so
/// even a fully compromised admin key cannot shorten the window.
pub const BEBOP_ROTATION_DELAY: i64 = 48 * 60 * 60;

/// Commit a staged bebop_authority rotation.
/// Callable by admin only, and only after BEBOP_ROTATION_DELAY has elapsed
/// since the matching update_config call. Clears the pending fields on commit.
pub fn accept_bebop_authority(ctx: Context<UpdateConfig>) -> Result<()> {
    let config = &mut ctx.accounts.config; let clock = Clock::get()?;
    let pending = config.pending_bebop_authority
        .ok_or(error!(PithyQuip::InvalidParameters))?;
    
    require!(clock.unix_timestamp.saturating_sub(
            config.bebop_authority_pending_since) >= BEBOP_ROTATION_DELAY,
        PithyQuip::TradingFrozen // timelock window not yet elapsed
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

    // remaining_accounts[0] = validation oracle feed (Switchboard Pull Feed)
    //   Must have been written by the validation oracle BEFORE this call.
    //   Contains: content_tag + APPROVED/REJECTED + quality score.
    // remaining_accounts[1] = resolution oracle feed (Switchboard Pull Feed)
    //   The feed that will be used for post-deadline resolution.
    //   Verified to belong to the trusted oracle function.
    pub system_program: Program<'info, System>,
}

pub fn create_market<'info>(ctx: Context<'_, '_, '_, 'info, 
    CreateMarket<'info>>, params: CreateMarketParams) -> Result<()> {
    let clock = Clock::get()?;
    let bank = &mut ctx.accounts.bank;
    let market = &mut ctx.accounts.market;
    let right_now = clock.unix_timestamp;

    // ─────────────────────────────────────────────────────────────
    // VALIDATION ORACLE — read the creation-time resolvability check
    // ─────────────────────────────────────────────────────────────
    // The creator must have triggered the validation oracle function
    // BEFORE calling create_market. The oracle writes APPROVED + score
    // to a Switchboard Pull Feed. We read it here and gate creation.
    //
    // Encoding: content_tag * 1_000_000_000_000 + validation_result * 100_000 + score
    //   content_tag: SHA256(question || context || exculpatory || outcomes)[0..3]
    //   validation_result: 0 = REJECTED, 1 = APPROVED
    //   score: quality score 0–10000
    require!(ctx.remaining_accounts.len() >= 2,
             PithyQuip::InsufficientAccounts);

    let validation_feed_info = &ctx.remaining_accounts[0];
    let validation_feed = switchboard_on_demand::on_demand::accounts
        ::pull_feed::PullFeedAccountData::parse(validation_feed_info.try_borrow_data()?)
                                    .map_err(|_| error!(PithyQuip::InvalidAccountOwner))?;

    // Verify validation feed was generated by trusted oracle function
    require!(verify_trusted_feed(&validation_feed, &ctx.accounts.config),
             PithyQuip::InvalidAccountOwner);

    let val_value = validation_feed.get_value(
        SB_MAX_STALE_SLOTS * 10, u64::MAX, // allow 20 min staleness for validation
        SB_MIN_SAMPLES, true).map_err(|_| error!(PithyQuip::InvalidParameters))?;
    
    let val_raw = val_value.to_u64().unwrap_or(0);
    // Validation encoding: content_tag * 1_000_000_000_000 + result * 100_000 + score
    // content_tag = SHA256(question || context || exculpatory || outcomes)[0..3]
    // This binds the feed to the SPECIFIC question content. Creator can't
    // validate question A then create market with question B.
    const TAG: u64 = 1_000_000_000_000; const CONF: u64 = 100_000;

    let validation_tag = val_raw / TAG;
    let validation_payload = val_raw % TAG;
    let validation_result = validation_payload / CONF;
    let validation_score = validation_payload % CONF;

    // Recompute content hash from actual params and verify match
    let mut content_bytes = Vec::new();
    content_bytes.extend_from_slice(params.question.as_bytes());
    content_bytes.extend_from_slice(params.context.as_bytes());
    content_bytes.extend_from_slice(params.exculpatory.as_bytes());
    
    for o in params.outcomes.iter() {
        content_bytes.extend_from_slice(o.as_bytes());
    }
    let content_hash = solana_program::keccak::hashv(
                        &[&content_bytes]).to_bytes();

    let expected_tag = u32::from_le_bytes([content_hash[0],
        content_hash[1], content_hash[2], 0, // 24-bit tag
    ]) as u64;

    require!(validation_tag == expected_tag, 
            PithyQuip::InvalidMarketBinding);
    // Must be APPROVED (result = 1) with sufficient quality score
    require!(validation_result == 1, 
    PithyQuip::QuestionNotResolvable);

    require!(validation_score >= MIN_VALIDATION_SCORE, 
                PithyQuip::QuestionNotResolvable);

    require!(!params.question.is_empty()
          && params.question.len() <= 500, 
          PithyQuip::InvalidParameters);

    // Context required — definitions, condition precedents
    require!(!params.context.is_empty()
          && params.context.len() <= 1000, 
          PithyQuip::InvalidParameters);

    // Exculpatory clauses required — force majeure handling
    require!(!params.exculpatory.is_empty()
          && params.exculpatory.len() <= 1000, 
            PithyQuip::InvalidParameters);

    let outcomes = &params.outcomes; // Resolution source (optional but bounded)
    require!(params.resolution_source.len() <= 200, PithyQuip::InvalidParameters);
    // Validate outcomes: 2–20, each non-empty and ≤ 100 chars, no duplicates
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

    require!(params.creator_bond >= MIN_CREATOR_BOND_LAMPORTS,
             PithyQuip::OrderTooSmall);

    // Transfer SOL bond from creator to vault PDA
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
        // Splits are validated at resolution time (only winning entries must sum to 10_000).
        // At creation, just ensure no single entry exceeds 10_000.
        for &split in &params.winning_splits {
            require!(split <= 10_000, PithyQuip::InvalidParameters);
        }
    }
    if !params.beneficiaries.is_empty() {
        require!(params.beneficiaries.len() == outcomes.len(),
                 PithyQuip::InvalidParameters);
        // If winning_splits is set, each 
        // split-receiving outcome needs a beneficiary
        if !params.winning_splits.is_empty() {
            for (i, &split) in params.winning_splits.iter().enumerate() {
                if split > 0 {
                    require!(params.beneficiaries[i].is_some(),
                             PithyQuip::InvalidParameters);
                }
            }
        }
    }
    // Verify the resolution feed (sb_feed) is from the trusted oracle function.
    // remaining_accounts[0] = validation feed, remaining_accounts[1] = resolution feed
    // (len >= 2 already required above)
    let resolution_feed_info = &ctx.remaining_accounts[1];
    require!(resolution_feed_info.key() == params.sb_feed, PithyQuip::InvalidParameters);
    
    let resolution_feed = switchboard_on_demand::on_demand::accounts::pull_feed::PullFeedAccountData
        ::parse(resolution_feed_info.try_borrow_data()?).map_err(|_| error!(PithyQuip::InvalidAccountOwner))?;
    require!(verify_trusted_feed(&resolution_feed, &ctx.accounts.config), PithyQuip::InvalidAccountOwner);

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
    market.sb_feed = params.sb_feed;

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

    // Resolution mode — default auto, updated by init_market_evidence
    market.resolution_mode = 0; // MODE_EXTERNAL — default; overridden by init_market_evidence

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
// PLACE ORDER — bet on an prediction market outcome
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
    // Zero commitment hash would break reveal math — _do_reveal excludes
    // zero-hash entries from confidence sum but total_capital includes them,
    // deflating the weighted average. Old code handled this for rollovers
    // (assigning neutral confidence 5000); we removed rollovers, so reject.
    require!(commitment_hash != [0u8; 32], PithyQuip::InvalidParameters);
    // ─────────────────────────────────────────────────────────────
    // TWAP MANIPULATION RESISTANCE
    // ─────────────────────────────────────────────────────────────
    update_price_accumulator(market, right_now)?;
    let max_deviation_bps = params.max_deviation_bps.unwrap_or(300);
    let deviation = get_price_deviation(market, outcome, right_now);
    require!(deviation <= max_deviation_bps, PithyQuip::PriceManipulated);
    // ─────────────────────────────────────────────────────────────
    // FUND THE BET
    // ─────────────────────────────────────────────────────────────
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
    // ─────────────────────────────────────────────────────────────
    // LMSR PRICING + POSITION UPDATE
    // ─────────────────────────────────────────────────────────────
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
        // Clamp to [1, 9_999] so zero is unambiguously "legacy/missing"
        // rather than a genuine extreme price — the reveal phase uses 0
        // as a sentinel to skip the edge-bonus path gracefully.
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
// TEST HELPERS — append to bottom of entra.rs
// =============================================================================

// Test-only market creation that skips oracle validation.
// Build with: anchor build -- --features testing

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

    // Transfer SOL bond
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

    // Init accuracy buckets
    let buckets = &mut ctx.accounts.accuracy_buckets;
    buckets.market = market.key();
    buckets.buckets = vec![0u64; AccuracyBuckets::NUM_BUCKETS];
    buckets.bump = ctx.bumps.accuracy_buckets;

    // Init market (same as create_market, minus oracle checks)
    market.market_id = bank.market_count;
    market.creator = ctx.accounts.authority.key();
    market.question = params.question.clone();
    market.context = params.context.clone();
    market.exculpatory = params.exculpatory.clone();
    market.resolution_source = params.resolution_source.clone();
    market.outcomes = params.outcomes.clone();
    market.num_outcomes = num_outcomes;
    market.sb_feed = params.sb_feed; // unused in test mode

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

    // Resolution mode — default auto, updated by init_market_evidence
    market.resolution_mode = 0; // MODE_EXTERNAL — default; overridden by init_market_evidence

    // Cross-chain resolution defaults
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

// SOL serves two purposes simultaneously:
//   1. Flash loan liquidity for JAM (sol_lamports in Depository)
//   2. Collateral for synthetic positions (sol_pledged_usd added to deposited_quid)
//
// The collateral path reuses the existing deposited_quid accounting exactly:
//   deposit_sol  → accrue deposit_seconds, deposited_quid += sol_usd_floor,
//                  total_deposits += sol_usd_floor   (same 4-line pattern as handle_in)
//   withdraw_sol → use min(locked, current) as reduction, check withdrawable()
//                  (same withdrawable() guard as handle_out)
//   refresh_sol  → marks down stale sol_pledged_usd permissionlessly when SOL drops;
//                  if total_deposits < max_liability after reduction, existing
//                  amortise() calls will fire on open positions — no new liquidation
//                  logic needed.
//
// The flash loan facility is NOT separate from the collateral deposit:
//   All deposited SOL is simultaneously:
//     - Available for JAM flash loans (sol_lamports)
//     - Contributing collar-adjusted USD to the position capacity pool (sol_pledged_usd)
//   Flash borrow zeros out sol_usd_contrib temporarily during the loan window
//   so has_capacity() remains conservative while lamports are on loan.

/// Collar-adjusted USD value for `lamports` of SOL at `price` (micro-USD/SOL).
/// Reused by deposit_sol, withdraw_sol, refresh_sol_collateral, flash_repay.
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

    /// SOL TickerRisk PDA — same pattern as every other ticker.
    /// init_if_needed on first SOL deposit; bump stored for later use.
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
    // remaining_accounts[0] = Pyth SOL/USD price account
}

pub fn handle_deposit_sol(ctx: Context<DepositSol>, lamports: u64) -> Result<()> {
    require!(lamports > 0, PithyQuip::InvalidAmount);

    let clock = Clock::get()?;
    let now = clock.unix_timestamp;
    let slot = clock.slot as i64;

    // Price is required to compute the collar-adjusted USD contribution
    let pyth = ctx.remaining_accounts.first();
    let sol_price = crate::etc::fetch_price("SOL", pyth)?;

    let risk = &mut ctx.accounts.sol_risk;
    if risk.ticker == [0u8; 8] {
        risk.ticker = Depositor::pad_ticker("SOL");
        risk.bump = ctx.bumps.sol_risk;
        risk.actuary.obs_count = 10; // bootstrap: 50% confidence (matches handle_in)
    }   risk.actuary.update_price(sol_price as i64, slot);

    let bank = &mut ctx.accounts.bank;
    let customer = &mut ctx.accounts.customer_account;
    if customer.owner == Pubkey::default() {
        customer.owner = ctx.accounts.depositor.key();
    }
    bank.sol_lamports = bank.sol_lamports.saturating_add(lamports);
    customer.deposited_lamports = customer.deposited_lamports.saturating_add(lamports);
    // Transfer lamports into vault before accounting updates
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
    // Shared accounting: accrues deposit_seconds + mutates deposited_quid/total_deposits
    customer.pool_deposit(bank, sol_usd_floor, now);
    Ok(())
}

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

// remaining_accounts for SPL path (token_amount > 0):
//   [0] vault — mut, seeds [b"vault", mint.key()]
//   [1] mint
//   [2] borrower_ata — mut
//   [3] token_program
pub fn handle_flash_borrow<'info>(ctx: Context<'_, '_, '_, 
    'info, FlashBorrow<'info>>, lamports: u64, token_amount: u64,
    // canonical bump for [b"vault", mint]; use create_program_address
    // instead of find_program_address (~100 CU vs ~2000 CU for the sha256 loop)
    vault_bump: u8) -> Result<()> { require!(lamports > 0 || token_amount > 0, PithyQuip::InvalidAmount);
    require!(!(lamports > 0 && token_amount > 0), PithyQuip::InvalidAmount); // SOL xor SPL

    let bank = &mut ctx.accounts.bank;
    // FlashLoanActive guard is enforced 
    // by Anchor constraint on flash_loan account.
    let flash = &mut ctx.accounts.flash_loan;

    // Verify flash_repay present later 
    let ixs = &ctx.accounts.ix_sysvar;
    // in this tx — same discriminator covers both SOL and SPL.
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
        // Zero sol_usd_contrib so has_capacity() is conservative during flash window.
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
        // ── SPL path — remaining_accounts: [vault, mint, borrower_ata, token_prog] ─
        // QU!D lends USD* (or any registered_mint) directly from its vault PDA.
        //
        // USD* (star9agSpjiFe3M49B3RniVU4CMBBEK3Qnaqn3RGiFM) is NOT the Numéraire V1
        // LP token. It is governed entirely by the Perena bankineco program:
        //   bankineco program: save8RQVPMWNTzU18t3GBvBkN9hT7jsGjiCQ28FpD9H
        //   SDK: github.com/perena/bankineco-sdk  (@perena/bankineco-sdk on npm)
        //
        // Flash loan cycle for a solver borrowing USD*:
        //   1. Borrow USD* from QU!D (this instruction)
        //   2. Burn USD* → USDC via bankineco burnForYieldingGen  ← details below
        //   3. Execute arb with USDC
        //   4. Mint USD* ← USDC via bankineco mintWYieldingGen    ← details below
        //   5. Repay USD* to QU!D
        //
        // USD* is NAV-backed by a basket of up to 16 yield-bearing assets;
        // burn/mint operate against a single chosen vault at the current oracle
        // price — no AMM curve, no proportional multi-token redemption.
        // USDC is permanently reserved (always redeemable); other vaults vary.
        // Round-trip fee: ~0.05% per leg (burnFeeBps + mintFeeBps), ~0.1% total.
        // Cross-vault round-trips (burn USDC, repay with PYUSD) add oracle drift
        // risk — see mintWYieldingGen note below. Same-vault round-trip is safest.
        //
        // ── burnForYieldingGen (USD* → yielding_mint) ───────────────────────────
        //   discriminator (Anchor sha256): [167, 22, 56, 95, 212, 15, 185, 218]
        //   args (borsh):  amount_to_send: u64, minimum_yielding_withdrawn: u64
        //
        //   yieldingMint is the OUTPUT token — solver chooses from the bank's
        //   idleVaultIndices map (any vault with available balance):
        //     USDC  → vaultIndex=3 (MARGINFI_USDC)   EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v
        //     PYUSD → vaultIndex=0 (KAMINO_PYUSD)    2b1kV6DkPAnxd5ixfnxCpjxmKwqjjaYmCZfHsFu24GXo
        //     USDS  → vaultIndex=0 (KAMINO_USDS)     USDSwr9ApdHk5bvJKMjzff41FfuX8bSxdKcR81vTwcA
        //     JUPUSD→ vaultIndex=0 (JUPLEND_JUPUSD)  JuprjznTrTSp2UFa3ZBUFgwdAmtZCq4MQCwysN55USD
        //     CASH  → vaultIndex=4 (KAMINO_CASH)     CASHx9KJUStyftLFWGvEVf59SGeG9sh5FfcnZMVPCASH
        //   vaultState = PDA([b"VAULT", bankState, yieldingMint, [vaultIndex]], bankineco)
        //   Solver picks whichever vault has sufficient liquidity for the arb amount.
        //   USDC is permanently reserved (always liquid); others may have varying depth.
        //
        //   accounts:
        //     user            [mut, signer]  solver pubkey
        //     bankState       [mut]          sM6P4mh53CnG4faN4Fo3seY7wMSAiHdy8o6gKjwQF7A
        //                                      PDA([b"BANK", [0]], bankineco)
        //     vaultState      [mut]          PDA([b"VAULT", bank, yieldingMint, [idx]], bankineco)
        //     oracleState     [ ]            PDA([b"VORACLEA", vaultState], bankineco)
        //     yieldingMint    [ ]            chosen output mint (see table above)
        //     bankMint        [mut]          star9agSpjiFe3M49B3RniVU4CMBBEK3Qnaqn3RGiFM (USD*)
        //     yieldingUserTa  [mut]          ATA(solver, yieldingMint)  ← receives output
        //     bankMintUserTa  [mut]          ATA(solver, USD*)          ← USD* burned from here
        //     yieldingVaultAta[mut]          ATA(vaultState, yieldingMint)
        //     teamState       [mut]          PDA([b"VTEAMA", vaultState], bankineco)
        //     feeTeamAta      [mut]          ATA(teamState, yieldingMint)
        //     systemProgram   [ ]            11111111111111111111111111111111
        //     tokenProgram    [ ]            TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA
        //
        // ── mintWYieldingGen (yieldingMint → USD*, for repayment) ───────────────
        //   discriminator: [31, 100, 17, 215, 62, 12, 31, 2]
        //   args (borsh):  amount_yielding_deposit: u64, min_usdstar_minted: u64
        //   accounts: identical layout to burnForYieldingGen above
        //             yieldingUserTa → bankMintUserTa direction reversed
        //   yieldingMint for repay SHOULD match the burn yieldingMint. Cross-vault
        //   round-trips (burn USDC, mint back with PYUSD) expose the solver to NAV
        //   drift between oracle ticks and double the fee cost (~0.1% round-trip
        //   vs ~0.05%). If the repay mint yields fewer USD* than borrowed (oracle
        //   price drift or depegged constituent), the solver absorbs the shortfall.
        //   Safest pattern: burn → USDC, arb, mint → USDC (same vault, same oracle).
        //
        // ── Implementation note ──────────────────────────────────────────────────
        //   burnForYieldingGen and mintWYieldingGen are JAM interactions in the
        //   solver's settle() call, bracketing the actual arb interactions:
        //     [flash_borrow (use_jam_authority:true)] →
        //     [burnForYieldingGen (use_jam_authority:false)] →
        //     [... arb / fills with constituent ...] →
        //     [mintWYieldingGen (use_jam_authority:false)] →
        //     [flash_repay (use_jam_authority:true)]
        //   The solver is the payer/user/signer for both bankineco calls.
        //   use_jam_authority:false because bankineco validates solver as user,
        //   not JAM authority. All PDAs above are stable on-chain constants.
        //   The USDC vault used by getVault(USDC) is idleVaultIndices[USDC] = index 3
        //   (MARGINFI_USDC). This vault deploys capital into Marginfi and requires
        //   additional remaining accounts for burn (buildMarginfiWithdrawRemainingAccounts)
        //   and mint (buildMarginfiDepositRemainingAccounts) unless the Marginfi protocol
        //   is paused, in which case no extra accounts are needed. Use the bankineco
        //   SDK's getMintAndBurnCpiAccounts() to get the full account list including
        //   any lending protocol accounts for the chosen vault.
        let ra = ctx.remaining_accounts;
        require!(ra.len() >= 4, PithyQuip::InvalidParameters);
        let (vault_ai, mint_ai, borrower_ata, token_prog) =
            (&ra[0], &ra[1], &ra[2], &ra[3]);

        // Verify vault PDA using caller-supplied canonical bump.
        // create_program_address (single sha256 ~100 CU) replaces
        // find_program_address (up to 255 sha256 iterations ~2000 CU).
        // Off-chain: bump = Pubkey::find_program_address([b"vault", mint], ID).1
        let expected = Pubkey::create_program_address(
            &[b"vault", mint_ai.key.as_ref(), &[vault_bump]], &crate::ID,
        ).map_err(|_| error!(PithyQuip::InvalidParameters))?;
        
        require_keys_eq!(vault_ai.key(), expected, 
            PithyQuip::InvalidSettlementProgram);
        // Only registered_mints may be borrowed.
        require!(
            ctx.accounts.config.registered_mints.contains(mint_ai.key),
            PithyQuip::InvalidMint
        );
        // Reject fake token programs — a no-op transfer would let the loan
        // be recorded without tokens leaving the vault (same A9 fix as JAM settle).
        require!(token_prog.key() == anchor_spl::token::ID
              || token_prog.key() == anchor_spl::token_2022::ID,
            PithyQuip::InvalidParameters
        );
        // Read vault balance + mint decimals from raw account data
        // (same pattern as state.rs::transfer_from_vaults).
        let vault_amount = { let d = vault_ai.try_borrow_data()?;
            // SPL token account: amount at bytes 64..72 (165-byte layout).
            require!(d.len() >= 72, PithyQuip::InvalidParameters);
            u64::from_le_bytes(d[64..72].try_into().unwrap())
        };

        require!(token_amount <= vault_amount, 
                PithyQuip::InsufficientFunds);
        // SPL token mint layout: decimals at byte offset 44, min size 82 bytes.
        // Hard require rather than silent fallback — if the account is not a
        // valid mint the registered_mints check above should have caught it.
        let decimals = { let d = mint_ai.try_borrow_data()?;
            require!(d.len() >= 45, PithyQuip::InvalidParameters);
            d[44]
        };

        flash.flash_token_mint = *mint_ai.key; flash.flash_token_amount = token_amount;
        // Vault PDA signs for itself (same seeds pattern as transfer_from_vaults).
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