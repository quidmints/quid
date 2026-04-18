
use anchor_lang::prelude::*;

pub mod stay;
pub mod state;
use state::*;

pub mod entra;
use entra::*;

pub mod acta;
use acta::*;

pub mod clutch;
use clutch::*;

pub mod out;
use out::*;

pub mod peso;
use peso::*;

pub mod pago;
use pago::*;

pub mod etc;
use etc::*;

pub mod LZ;
use LZ::*;

declare_id!("EnEfbQwmy9GpKx55EfUh79sV8ruhDmtCpVaAikjjgfDp");

#[program]
pub mod quid {
    use super::*;
    pub fn deposit(ctx: Context<Stockup>, amount: u64,
        ticker: String) -> Result<()> { entra::handle_in(ctx, amount, ticker) }
    // if you're obtaining short leverage, flip the signs respectively for amount; otherwise (long):
    // positive amount = increase exposure; negative = withdraw QUID (or) redeem exposure for QUID

    pub fn withdraw<'info>(ctx: Context<'_, '_, 'info, 'info, Withdraw<'info>>,
        amount: i64, ticker: String, exposure: bool) -> Result<()> {
        clutch::handle_out(ctx, amount, ticker, exposure) // no ticker = withdraw collateral from all positions;
        // at least one Pyth key must be passed into remaining_accounts (all keys if empty string ticker)
    } // this sort of cross-margining is also re-used in the liquidation process (a means of protection)
    // as such, need to pass in all Pyth keys into liquidate (first one should be the one to liquidate)
    pub fn liquidate(ctx: Context<Liquidate>, ticker: String) -> Result<()> { // amorè ties unsurmised
        clutch::amortise(ctx, ticker) // "when grace is close to home
        // shadows turn to grey...a slave for four days,
        // cowered beyond reckless tracks of impulse...
        // made to stay.rs around rough collars"
    }

    pub fn reveal<'info>(ctx: Context<'_, '_, '_, 'info,
        BatchReveal<'info>>, reveals: Vec<Vec<RevealEntry>>) -> Result<()> {
        peso::batch_reveal(ctx, reveals)
    }

    pub fn weigh<'info>(ctx: Context<'_, '_, '_, 'info,
        CalculateWeights<'info>>) -> Result<()> {
        // peso means weigh in Spanish
        peso::calculate_weights(ctx)
    }

    pub fn payout<'info>(ctx: Context<'_, '_, '_,
                  'info, PushPayouts<'info>>) -> Result<()> { pago::push_payouts(ctx) }

    /// Commit oracle-generated evidence protocol hash before market opens.
    /// Must be called after CreateMarketPipeline completes in the Go oracle.
    /// No positions can be placed until this PDA exists.
    pub fn create_market<'info>(ctx: Context<'_, '_, '_,
        'info, CreateMarket<'info>>,
        params: CreateMarketParams) -> Result<()> {
        entra::create_market(ctx, params)
    }

    pub fn resolve<'info>(ctx: Context<'_, '_, '_, 'info,
        ResolveMarket<'info>>) -> Result<()> {
        out::resolve_market(ctx)
    }

    pub fn challenge(ctx: Context<ChallengeResolution>) -> Result<()> {
        // alte liebe rostet nicht?
        out::challenge_resolution(ctx)
    }

    pub fn resolve_challenge<'info>(ctx: Context<'_, '_, '_, 'info,
        ResolveChallenge<'info>>) -> Result<()> {
        // it's called "out" because that's where
        // we figure it all out...
        out::resolve_challenge(ctx)
    }

    pub fn bid(ctx: Context<PlaceOrder>,
        params: OrderParams) -> Result<()> {
        entra::place_order(ctx, params)
    }

        pub fn sell(ctx: Context<SellPosition>,
        tokens_to_sell: u64, max_deviation_bps: Option<u64>) -> Result<()> {
        pago::sell_position(ctx, tokens_to_sell, max_deviation_bps)
    }

    pub fn init_market_evidence(ctx: Context<InitMarketEvidence>,
        market_id: u64, params: EvidenceRequirementsParams) -> Result<()> {
        acta::init_market_evidence(ctx, market_id, params)
    }

    pub fn submit_evidence(ctx: Context<SubmitEvidence>,
        params: SubmitEvidenceParams) -> Result<()> {
        acta::submit_evidence(ctx, params)
    }

    pub fn claim_resolution_bond(ctx: Context<ClaimResolutionBond>) -> Result<()> {
        out::claim_resolution_bond(ctx)
    }

    /// The attestation certificate contains: verifiedBootState = VERIFIED,
    /// and the APK signing cert hash as written by the OS (not self-reported).
    /// The StrongBox key was generated with setAttestationChallenge =
    /// SHA256(config_account_pubkey || config_version), binding it to
    /// the current on-chain configuration.
    pub fn enroll_device(ctx: Context<EnrollDevice>,
        params: EnrollDeviceParams) -> Result<()> {
        acta::enroll_device(ctx, params)
    }

    /// Revoke a device enrollment. Callable by admin or the device itself.
    /// After revocation, submit_evidence will reject submissions from this device
    /// until re-enrollment with the current config_version.
    pub fn revoke_enrollment(ctx: Context<RevokeEnrollment>) -> Result<()> {
        acta::revoke_enrollment(ctx)
    }

    pub fn init_config(ctx: Context<InitConfig>,
        orchestrator: Pubkey, token_mint: Pubkey) -> Result<()> {
        entra::init_config(ctx, orchestrator, token_mint)
    }

    pub fn update_config(ctx: Context<UpdateConfig>,
        new_orchestrator: Option<Pubkey>,
        new_admin: Option<Pubkey>,
        set_bebop_authority: Option<Pubkey>) -> Result<()> {
        entra::update_config(ctx, new_orchestrator, new_admin,
            set_bebop_authority)
    }

    pub fn deposit_sol(ctx: Context<DepositSol>, lamports: u64) -> Result<()> {
        entra::handle_deposit_sol(ctx, lamports)
    }

    pub fn withdraw_sol(ctx: Context<WithdrawSol>, lamports: u64) -> Result<()> {
        clutch::handle_withdraw_sol(ctx, lamports)
    }

    pub fn flash_borrow<'info>(ctx: Context<'_, '_, '_, 'info, FlashBorrow<'info>>,
        lamports: u64, token_amount: u64, vault_bump: u8) -> Result<()> {
        entra::handle_flash_borrow(ctx, lamports, token_amount, vault_bump)
    }

    pub fn flash_repay<'info>(ctx: Context<'_, '_, '_, 'info, FlashRepay<'info>>,
        tip_lamports: u64, tip_token_amount: u64, vault_bump: u8) -> Result<()> {
        clutch::handle_flash_repay(ctx, tip_lamports, tip_token_amount, vault_bump)
    }

    pub fn refresh_sol_collateral(ctx: Context<RefreshSolCollateral>) -> Result<()> {
        clutch::handle_refresh_sol_collateral(ctx)
    }


    pub fn init_oapp_store(mut ctx: Context<InitOAppStore>,
        params: InitOAppStoreParams) -> Result<()> {
        LZ::init_oapp_store_handler(&mut ctx, &params)
    }

    pub fn register_chain(ctx: Context<RegisterChain>,
        params: RegisterChainParams) -> Result<()> {
        LZ::register_chain_handler(ctx, params)
    }

    /// Send resolution request to Court.sol via LayerZero.
    /// Callable by anyone after deadline, if market has jury config.
    /// Requester must hold a position >= MIN_JURY_STAKE.
    pub fn resolve_jury(ctx: Context<SendResolutionRequest>) -> Result<()> {
        LZ::send_resolution_request(ctx)
    }

    /// Permissionless force-majeure trigger for stalled jury markets.
    /// If no ruling arrives within JURY_TIMEOUT_SECS (14 days) of
    /// send_resolution_request, anyone may cancel the market so that
    /// push_payouts can return all capital.
    pub fn timeout_jury(ctx: Context<CancelJuryTimeout>) -> Result<()> {
        LZ::cancel_jury_timeout(ctx)
    }

    /// Send jury compensation to Court.sol after resolution finalized.
    pub fn tip_jury(ctx: Context<SendJuryCompensation>) -> Result<()> {
        LZ::send_jury_compensation(ctx)
    }

    /// LayerZero receive handler for incoming messages from Court.sol.
    /// Handles FINAL_RULING message type only.
    pub fn lz_receive(ctx: Context<LzReceive>,
        params: LzReceiveParams) -> Result<()> {
        require!(!params.message.is_empty(), PithyQuip::InvalidParameters);
        require!(!ctx.remaining_accounts.is_empty(),
                 PithyQuip::InsufficientAccounts);

        let chain_config_info = &ctx.remaining_accounts[0];
        let chain_data = chain_config_info.try_borrow_data()?;
        let chain_config = ChainConfig::try_deserialize(&mut chain_data.as_ref())
            .map_err(|_| PithyQuip::InvalidParameters)?;
        drop(chain_data);

        require!(chain_config.active, PithyQuip::InvalidParameters);
        require!(chain_config.eid == params.src_eid,
                 PithyQuip::InvalidParameters);
        require!(chain_config.peer_address == params.sender,
                 PithyQuip::InvalidParameters);

        // Clear the LZ nonce...
        let clear_accounts = vec![
            ctx.accounts.store.to_account_info(),
            ctx.accounts.oapp_registry.to_account_info(),
            ctx.accounts.nonce.to_account_info(),
            ctx.accounts.payload_hash.to_account_info(),
            ctx.accounts.endpoint.to_account_info(),
        ];
        let clear_params = ClearParams {
            receiver: ctx.accounts.store.key(),
            src_eid: params.src_eid,
            sender: params.sender,
            nonce: params.nonce,
            guid: params.guid,
            message: params.message.clone(),
        };
        let seeds: &[&[&[u8]]] = &[&[
            OAPP_STORE_SEED,
            &[ctx.accounts.store.bump],
        ]];
        cpi_clear(
            ctx.accounts.store.endpoint_program,
            ctx.accounts.store.key(),
            &clear_accounts, seeds, clear_params,
        )?;

        // OFT bridge message: toAddress[32] + amountSD[8], no leading type byte.
        // Detected by fixed length. All other messages have a type byte at [0].
        if params.message.len() == LZ::OFT_BRIDGE_MSG_LEN {
            require!(ctx.remaining_accounts.len() >= 4, PithyQuip::InsufficientAccounts);
            LZ::handle_oft_receive(ctx.accounts.store.key(), ctx.accounts.store.bump,
                &chain_config, &params.message, &ctx.remaining_accounts[1],
                &ctx.remaining_accounts[2], &ctx.remaining_accounts[3])?;
        } else {
            let msg_type = params.message[0];
            match msg_type {
                FINAL_RULING => {
                    let ruling = FinalRuling::decode(&params.message)?;
                    let (market_pda, _) = Pubkey::find_program_address(
                        &[b"market", &ruling.market_id.to_le_bytes()[..6]],
                        ctx.program_id,
                    );
                    // Market is at remaining_accounts[1]
                    let market_info = ctx.remaining_accounts.iter().skip(1)
                        .find(|acc| acc.key() == market_pda)
                        .ok_or(PithyQuip::InvalidParameters)?;

                    require!(market_info.owner == ctx.program_id,
                             PithyQuip::InvalidParameters);

                    let market_key = market_info.key();
                    let mut market_data = market_info.try_borrow_mut_data()?;
                    let mut market = Market::try_deserialize(
                        &mut market_data.as_ref())?;

                    let clock = Clock::get()?;
                    process_final_ruling(
                        &ruling, &mut market, &market_key,
                        clock.unix_timestamp,
                    )?;
                    market.try_serialize(&mut market_data.as_mut())?;
                },
                _ => {
                    return Err(PithyQuip::InvalidParameters.into());
                }
            }
        } Ok(())
    }

    /// LZ receive types handler — tells LayerZero which accounts
    /// to include for a given incoming message.
    pub fn lz_receive_types(ctx: Context<LzReceiveTypes>,
        params: LzReceiveParams) -> Result<Vec<LzAccount>> {
        lz_receive_types_handler(ctx, &params)
    }

    #[cfg(feature = "testing")]
    pub fn test_create_market(ctx: Context<TestCreateMarket>,
       params: CreateMarketParams) -> Result<()> {
       entra::test_create_market(ctx, params)
    }
    #[cfg(feature = "testing")]
    pub fn test_resolve(ctx: Context<TestResolve>,
        winning_outcome: u8, confidence: u64) -> Result<()> {
        out::test_resolve_market(ctx, winning_outcome, confidence)
    }

    #[cfg(feature = "testing")]
    pub fn test_receive_ruling<'info>(
        ctx: Context<'_, '_, '_, 'info, TestReceiveRuling<'info>>,
        winning_sides: Vec<u8>, force_majeure: bool) -> Result<()> {
        let market_key = ctx.accounts.market.key();
        let market = &mut ctx.accounts.market;
        let clock = Clock::get()?;
         // empty = force majeure...
        let ruling = if force_majeure {
            FinalRuling::new(market.market_id, Vec::new())?
        } else {
            FinalRuling::new(market.market_id, winning_sides)?
        };
        process_final_ruling(&ruling,
            &mut **market, &market_key,
            clock.unix_timestamp)?; Ok(())
    }
}
