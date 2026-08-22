
use anchor_lang::prelude::*;

pub mod stay;

pub mod entra;
use entra::*;

pub mod clutch;
use clutch::*;

pub mod etc;
use etc::*;


pub mod LZ;
use LZ::*;

declare_id!("QDgHUZjtccRjKZ63MBvW8uzKR7qcqjpRfGhNSEGfDu9");

#[program]
pub mod quid {
    use super::*;
    /// Deposit. Two legs, one entrypoint: pass `mint` + `quid` for an SPL
    /// deposit, or `sol_pool` with ticker "SOL" for native lamports. Exactly
    /// one leg must be supplied.
    pub fn deposit<'info>(ctx: Context<'_, '_, 'info, 'info, Stockup<'info>>,
        amount: u64, ticker: String) -> Result<()> { entra::handle_in(ctx, amount, ticker) }
    // if you're obtaining short leverage, flip the signs respectively for amount; otherwise (long):
    // positive amount = increase exposure; negative = withdraw QUID (or) redeem exposure for QUID

    pub fn withdraw<'info>(ctx: Context<'_, '_,
        'info, 'info, Withdraw<'info>>, amount: i64, ticker: String, exposure: bool) -> Result<()> {
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

    pub fn init_config(ctx: Context<InitConfig>,
        token_mint: Pubkey) -> Result<()> {
        entra::init_config(ctx, token_mint)
    }

    /// Rotate admin, or stage a bebop_authority rotation.
    /// Pass None for any field to leave it unchanged.
    pub fn update_config(ctx: Context<UpdateConfig>,
        new_admin: Option<Pubkey>,
        set_bebop_authority: Option<Pubkey>) -> Result<()> {
        entra::update_config(ctx,
            new_admin, set_bebop_authority)
    }


    pub fn flash_borrow<'info>(ctx: Context<'_, '_, '_, 'info, FlashBorrow<'info>>,
        lamports: u64, token_amount: u64, vault_bump: u8) -> Result<()> {
        entra::handle_flash_borrow(ctx, lamports, token_amount, vault_bump)
    }

    pub fn flash_repay<'info>(ctx: Context<'_, '_, '_, 'info, FlashRepay<'info>>,
        tip_lamports: u64, tip_token_amount: u64, vault_bump: u8) -> Result<()> {
        clutch::handle_flash_repay(ctx, tip_lamports, tip_token_amount, vault_bump)
    }

    /// Permissionless batch amortisation. Supply the Pyth account for `ticker`
    /// then any number of Depositor PDAs; healthy or too-fresh positions are
    /// skipped rather than reverting the batch, and the cranker is paid a cut
    /// of what it marks.
    pub fn sweep<'info>(ctx: Context<'_, '_, 'info, 'info, Sweep<'info>>,
        ticker: String) -> Result<()> {
        clutch::handle_sweep(ctx, ticker)
    }

    pub fn refresh_sol_collateral(ctx: Context<RefreshSolCollateral>) -> Result<()> {
        clutch::handle_refresh_sol_collateral(ctx)
    }

    /// Point SOL* parking at the issuer (admin only).
    /// `kestrel_program = Pubkey::default()` disables parking.
    pub fn set_kestrel(ctx: Context<SetKestrel>, kestrel_program: Pubkey,
        sol_star_mint: Pubkey, buffer_bps: u16, haircut_bps: u16,
        park_band_bps: u16, min_park_secs: i64) -> Result<()> {
        entra::set_kestrel(ctx, kestrel_program, sol_star_mint,
                           buffer_bps, haircut_bps, park_band_bps, min_park_secs)
    }



    pub fn init_oapp_store(mut ctx: Context<InitOAppStore>,
        params: InitOAppStoreParams) -> Result<()> {
        LZ::init_oapp_store_handler(&mut ctx, &params)
    }

    /// LayerZero receive handler. The only inbound message is the OFT bridge
    /// transfer that mints QD on Solana against supply locked by Basket.sol on
    /// L1 — the maturity is copied across, never issued twice.
    pub fn lz_receive<'info>(ctx: Context<'_, '_, 'info, 'info, LzReceive<'info>>,
        params: LzReceiveParams) -> Result<()> {
        // OFT bridge message: toAddress[32] + amountSD[8], no leading type byte.
        // It is the only message type this OApp accepts.
        require!(params.message.len() == LZ::OFT_BRIDGE_MSG_LEN,
                 PithyQuip::InvalidMessageFormat);

        require!(ctx.remaining_accounts.len() >= 3,
                 PithyQuip::InsufficientAccounts);

        // The peer lives on the store, which Anchor has already verified by
        // seeds — so there is no caller-supplied account to spoof here. The
        // previous shape took a ChainConfig through remaining_accounts and had
        // to prove ownership, discriminator and liveness by hand before it
        // could trust a single field.
        require!(ctx.accounts.store.eid == params.src_eid,
                 PithyQuip::InvalidParameters);
        require!(ctx.accounts.store.peer_address == params.sender,
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
            &clear_accounts, seeds, clear_params )?;

        LZ::handle_oft_receive(&ctx.accounts.store.to_account_info(),
            ctx.accounts.store.bump, ctx.accounts.store.mint, &params.message,
            &ctx.remaining_accounts[0], &ctx.remaining_accounts[1],
            &ctx.remaining_accounts[2])
    }

    /// LZ receive types handler — tells LayerZero which accounts
    /// to include for a given incoming message.
    pub fn lz_receive_types(ctx: Context<LzReceiveTypes>,
        params: LzReceiveParams) -> Result<Vec<LzAccount>> {
        lz_receive_types_handler(ctx, &params)
    }
}
