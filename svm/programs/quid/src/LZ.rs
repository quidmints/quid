
use anchor_lang::prelude::*;
use anchor_spl::token_interface::{self, Mint, TokenAccount, TokenInterface, MintTo};
use crate::etc::PithyQuip;

use crate::state::{Market, MarketEvidence, MIN_JURY_POOL};
pub const OAPP_STORE_SEED: &[u8] = b"Store";
pub const CHAIN_SEED: &[u8] = b"Chain";
pub const LZ_RECEIVE_TYPES_SEED: &[u8] = b"LzReceiveTypes";
pub const PEER_SEED: &[u8] = b"Peer";

pub const ENFORCED_OPTIONS_SEND_MAX_LEN: usize = 512;
pub const ENFORCED_OPTIONS_SEND_AND_CALL_MAX_LEN: usize = 1024;

pub const RESOLUTION_REQUEST: u8 = 5;
pub const FINAL_RULING: u8 = 6;
pub const JURY_COMPENSATION: u8 = 7;

/// OFT message format: toAddress[32] + amountSD[8], no leading type byte.
/// Detected by message length == 40 and chain_config.mint != default.
pub const OFT_BRIDGE_MSG_LEN: usize = 40;

/// QD shared decimals on L1 (matches Basket.sol sharedDecimals()).
pub const OFT_SHARED_DECIMALS: u8 = 6;
/// QD local decimals on Solana.
pub const QD_LOCAL_DECIMALS: u8 = 9;
/// Multiply amountSD by this to get local token units.
pub const SD_TO_LOCAL: u64 = 1_000; // 10^(9-6)

#[account]
pub struct OAppStore {
    pub admin: Pubkey, pub bump: u8,
    pub endpoint_program: Pubkey,
}

impl OAppStore {
    pub const SIZE: usize = 8 + 32 + 1 + 32;
}

#[account]
pub struct ChainConfig {
    pub eid: u32, pub mint: Pubkey,
    pub peer_address: [u8; 32],
    pub enforced_options: EnforcedOptions,
    pub active: bool, pub bump: u8,
}

impl ChainConfig {
    pub const SIZE: usize = 8 + 4 + 32 + 32
        + EnforcedOptions::MAX_SIZE + 1 + 1;
}

#[derive(Clone, Default,
    AnchorSerialize,
    AnchorDeserialize)]
pub struct EnforcedOptions {
    pub send: Vec<u8>,
    pub send_and_call: Vec<u8>,
}

impl EnforcedOptions {
    pub const MAX_SIZE: usize = 4 +
    ENFORCED_OPTIONS_SEND_MAX_LEN + 4
    + ENFORCED_OPTIONS_SEND_AND_CALL_MAX_LEN;
    pub fn get_enforced_options(&self,
        composed_msg: &Option<Vec<u8>>) -> Vec<u8> {
        if composed_msg.is_none() {
            self.send.clone()
        } else {
            self.send_and_call.clone()
        }
    }
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct FinalRuling {
    pub market_id: u64,
    pub winning_sides: Vec<u8>,
}

impl FinalRuling {
    pub fn new(market_id: u64, winning_sides: Vec<u8>) -> Result<Self> {
        Ok(Self { market_id, winning_sides })
    }

    pub fn decode(data: &[u8]) -> Result<Self> {
        require!(data.len() >= 10, PithyQuip::InvalidMessageFormat);
        require!(data[0] == FINAL_RULING, PithyQuip::InvalidMessageType);

        let mut offset = 1;
        let market_id = u64::from_le_bytes(data[offset..offset+8].try_into().unwrap());
        offset += 8;

        let num_sides = data[offset] as usize; offset += 1;
        let mut winning_sides = Vec::with_capacity(num_sides);
        for _ in 0..num_sides {
            require!(offset < data.len(), PithyQuip::InvalidMessageFormat);
            winning_sides.push(data[offset]);
            offset += 1;
        }
        Ok(Self { market_id, winning_sides })
    }
    pub fn is_force_majeure(&self) -> bool { self.winning_sides.is_empty() }
}

#[derive(Clone, Debug)]
pub struct ResolutionRequest {
    pub market_id: u64,
    pub num_sides: u8,
    pub num_winners: u8,
    pub requires_unanimous: bool,
    pub appeal_cost: u64,
    pub requester: Pubkey,
}

impl ResolutionRequest {
    /// Wire format (52 bytes): [type 1B][marketId LE 8B][numSides 1B]
    /// [numWinners 1B][requiresUnanimous 1B]
    /// [appealCost LE 8B][requester 32B]
    pub fn encode(&self) -> Vec<u8> {
        let mut message = vec![RESOLUTION_REQUEST];
        message.extend_from_slice(&self.market_id.to_le_bytes());
        message.push(self.num_sides);
        message.push(self.num_winners);
        message.push(if self.requires_unanimous { 1 } else { 0 });
        message.extend_from_slice(&self.appeal_cost.to_le_bytes());
        message.extend_from_slice(self.requester.as_ref());
        message
    }
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct JuryCompensation {
    pub market_id: u64,
    pub amount: u64,
}

impl JuryCompensation {
    pub fn encode(&self) -> Vec<u8> {
        let mut data = vec![JURY_COMPENSATION];
        data.extend_from_slice(&self.market_id.to_le_bytes());
        data.extend_from_slice(&self.amount.to_le_bytes());
        data
    }
}

/// Wrap a compose message in OFT format for cross-chain delivery
/// OFT message format (from OFTMsgCodec.sol):
///   [0-31]  = sendTo (bytes32) - recipient/peer address on destination
///   [32-39] = amountSD (uint64 BE) - 0 for non-token messages
///   [40+]   = composeMsg - the actual payload
///
/// Note: Standard OFT compose includes composeFrom (msg.sender) at [40:72],
/// but Basket.sol expects raw payload starting at [40] without composeFrom.
pub fn wrap_in_oft_format(compose_msg: Vec<u8>, send_to: [u8; 32]) -> Vec<u8> {
    let mut message = Vec::with_capacity(40 + compose_msg.len());
    message.extend_from_slice(&send_to);             // sendTo: bytes[0:32]
    message.extend_from_slice(&0u64.to_be_bytes());  // amountSD: bytes[32:40] (big-endian)
    message.extend(compose_msg);                     // composeMsg: bytes[40:]
    message
}

#[derive(Clone, AnchorSerialize, AnchorDeserialize)]
pub struct RegisterChainParams {
    pub eid: u32,
    pub mint: Pubkey,
    pub peer_address: [u8; 32],
    pub enforced_options_send: Vec<u8>,
}

#[derive(Accounts)]
#[instruction(params: RegisterChainParams)]
pub struct RegisterChain<'info> {
    #[account(mut, address = store.admin @ PithyQuip::Unauthorized)]
    pub admin: Signer<'info>,

    #[account(seeds = [OAPP_STORE_SEED], bump = store.bump)]
    pub store: Account<'info, OAppStore>,

    #[account(
        init,
        payer = admin,
        space = ChainConfig::SIZE,
        seeds = [CHAIN_SEED, &params.eid.to_be_bytes()],
        bump
    )]
    pub chain_config: Account<'info, ChainConfig>,

    pub system_program: Program<'info, System>,
}

pub fn register_chain_handler(ctx: Context<RegisterChain>,
    params: RegisterChainParams) -> Result<()> {
    let config = &mut ctx.accounts.chain_config;

    config.eid = params.eid;
    config.mint = params.mint;
    config.peer_address = params.peer_address;
    config.enforced_options = EnforcedOptions {
        send: params.enforced_options_send,
        send_and_call: Vec::new(),
    };
    config.active = true;
    config.bump = ctx.bumps.chain_config;
    Ok(())
}

#[derive(Accounts)]
pub struct SendResolutionRequest<'info> {
    #[account(mut)]
    pub requester: Signer<'info>,

    #[account(mut, seeds = [b"market", &market.market_id.to_le_bytes()[..6]], bump = market.bump)]
    pub market: Account<'info, Market>,

    #[account(seeds = [b"market_evidence", market.key().as_ref()],
              bump = market_evidence.bump)]
    pub market_evidence: Account<'info, MarketEvidence>,

    #[account(seeds = [OAPP_STORE_SEED], bump = oapp_store.bump)]
    pub oapp_store: Account<'info, OAppStore>,

    pub system_program: Program<'info, System>,
}

pub fn send_resolution_request(
    ctx: Context<SendResolutionRequest>) -> Result<()> {
    let market = &mut ctx.accounts.market; let clock = Clock::get()?;
    require!(!market.resolution_received, PithyQuip::AlreadyResolved);
    require!(!market.resolved && !market.cancelled, PithyQuip::AlreadyComplete);
    require!(!market.resolution_requested, PithyQuip::AlreadyRequested);
    require!(market.total_capital >= MIN_JURY_POOL,
                PithyQuip::RequesterPositionTooSmall);
    require!(clock.unix_timestamp >= market.resolution_time,
                PithyQuip::TooEarlyToResolve);

    // remaining_accounts layout:
    //   [0]     = ChainConfig PDA
    //   [1..7]  = LZ quote accounts
    //   [7..]   = LZ send accounts
    require!(!ctx.remaining_accounts.is_empty(), PithyQuip::InsufficientAccounts);
    let chain_config_info = &ctx.remaining_accounts[0];
    require!(chain_config_info.owner == &crate::ID, PithyQuip::InvalidPeer);

    let chain_data = chain_config_info.try_borrow_data()?;
    require!(chain_data.len() >= 12, PithyQuip::InvalidPeer);
    let eid_bytes = u32::from_le_bytes(chain_data[8..12].try_into().unwrap()).to_be_bytes();
    let (expected_pda, _) = Pubkey::find_program_address(&[CHAIN_SEED, &eid_bytes], &crate::ID);

    let chain_config = ChainConfig::try_deserialize_unchecked(&mut chain_data.as_ref())
                                         .map_err(|_| PithyQuip::InvalidPeer)?;
    require!(chain_config_info.key() == expected_pda, PithyQuip::InvalidPeer);
    
    require!(chain_config.active, PithyQuip::InvalidPeer);
    require!(chain_config.peer_address != [0u8; 32], PithyQuip::PeerNotConfigured);

    let jury_config = ctx.accounts.market_evidence.evidence.jury_config.as_ref()
                                            .ok_or(PithyQuip::InvalidParameters)?;

    let request = ResolutionRequest { market_id: market.market_id,
        num_sides: market.outcomes.len() as u8, num_winners: market.num_winners,
        requires_unanimous: jury_config.requires_unanimous,
        appeal_cost: jury_config.appeal_cost,
        requester: ctx.accounts.requester.key(),
    };  market.resolution_requested = true;
    market.resolution_requested_time = Some(clock.unix_timestamp);
    market.resolution_requester = Some(ctx.accounts.requester.key());

    let compose_msg = request.encode();
    let message = wrap_in_oft_format(compose_msg, chain_config.peer_address);
    let seeds: &[&[&[u8]]] = &[&[OAPP_STORE_SEED, &[ctx.accounts.oapp_store.bump]]];
    let options = chain_config.enforced_options.get_enforced_options(&None::<Vec<u8>>);

    let quote_start = 1;
    let quote_end = quote_start + 6; let send_start = quote_end;
    require!(ctx.remaining_accounts.len() >= send_start + 7,
                    PithyQuip::InsufficientAccounts);

    let quote_accounts = &ctx.remaining_accounts[quote_start..quote_end];
    let send_accounts = &ctx.remaining_accounts[send_start..];
    let quote_result = cpi_quote(
        ctx.accounts.oapp_store.endpoint_program,
        quote_accounts, QuoteParams {
            sender: ctx.accounts.oapp_store.key(),
            dst_eid: chain_config.eid,
            receiver: chain_config.peer_address,
            message: message.clone(),
            options: options.clone(),
            pay_in_lz_token: false,
        },
    )?;
    require!(ctx.accounts.requester.lamports() >= quote_result.native_fee,
                                            PithyQuip::InsufficientLZFee);
    cpi_send(
        ctx.accounts.oapp_store.endpoint_program,
        ctx.accounts.oapp_store.key(), send_accounts,
        seeds, SendParams { dst_eid: chain_config.eid,
            receiver: chain_config.peer_address,
            message, options,
            native_fee: quote_result.native_fee,
            lz_token_fee: quote_result.lz_token_fee,
        })?;
    Ok(())
}

/// Permissionless force-majeure escape hatch for stalled jury markets.
///
/// If a ruling has not arrived within JURY_TIMEOUT_SECS of
/// `send_resolution_request`, anyone may call this to cancel the market
/// and unblock refunds via push_payouts. This covers two failure modes:
///   1. The LZ message was never delivered (infra failure).
///   2. The jury never reached a verdict (hung indefinitely).
///
/// Callable by anyone — no stake required. The 14-day window is generous
/// enough that calling early is not possible for any real network condition.
#[derive(Accounts)]
pub struct CancelJuryTimeout<'info> {
    /// Anyone may trigger — permissionless.
    pub caller: Signer<'info>,

    #[account(mut, seeds = [b"market",
    &market.market_id.to_le_bytes()[..6]],
    bump = market.bump)]
    pub market: Account<'info, Market>,
}

pub fn cancel_jury_timeout(ctx: Context<CancelJuryTimeout>) -> Result<()> {
    let market = &mut ctx.accounts.market;
    let clock = Clock::get()?;

    // Must have actually sent a resolution request (not just a jury-mode market).
    require!(market.resolution_requested, PithyQuip::InvalidParameters);
    // Must not already be resolved or cancelled.
    require!(!market.resolution_received && !market.cancelled,
             PithyQuip::AlreadyComplete);
    // Must be past the timeout window.
    let requested_at = market.resolution_requested_time
        .ok_or(PithyQuip::InvalidParameters)?;
    require!(
        clock.unix_timestamp >= requested_at + crate::state::JURY_TIMEOUT_SECS,
        PithyQuip::TooSoon
    );
    // Enter force majeure: cancelled = true, resolved = true so push_payouts
    // can run and return everyone's capital. winning_sides stays empty —
    // pago::push_payouts already handles the cancelled/force-majeure path.
    market.cancelled = true;
    market.resolved = true;
    market.resolution_received = true; // prevent duplicate triggers
    market.resolution_finalized = clock.unix_timestamp;
    market.winning_sides = Vec::new();
    market.winning_splits = Vec::new();
    market.resolution_time = clock.unix_timestamp;
    market.weights_complete = true; // no weigh phase needed for refunds

    emit!(crate::state::JuryRulingReceived {
        market_key: market.key(),
        winning_sides: Vec::new(), // empty = force majeure signal
    });
    Ok(())
}

/// Handle an incoming OFT QD bridge transfer from L1.
///
/// Called from lib.rs lz_receive when message.len() == OFT_BRIDGE_MSG_LEN
/// and chain_config.mint is set. Mints QD to the recipient.
///
/// remaining_accounts layout for OFT receive (after ChainConfig at [0]):
///   [1] = QD mint (mut) — must match chain_config.mint
///   [2] = recipient token account (mut) — must be for the QD mint
///   [3] = token program
///
/// The OAppStore PDA (OAPP_STORE_SEED) must be the mint authority.
pub fn handle_oft_receive<'a>(store_key: Pubkey,
    store_bump: u8, chain_config: &ChainConfig,
    message: &[u8], mint_info: &AccountInfo<'a>,
    recipient_info: &AccountInfo<'a>, token_prog: &AccountInfo<'a>) -> Result<()> {
    require!(message.len() >= OFT_BRIDGE_MSG_LEN, PithyQuip::InvalidMessageFormat);
    require!(chain_config.mint != Pubkey::default(), PithyQuip::InvalidParameters);

    // Decode OFT message: toAddress[32] + amountSD[8 BE]
    let to_bytes: [u8; 32] = message[..32].try_into()
        .map_err(|_| PithyQuip::InvalidMessageFormat)?;
    let amount_sd = u64::from_be_bytes(
        message[32..40].try_into().map_err(|_| PithyQuip::InvalidMessageFormat)?
    );
    require!(amount_sd > 0, PithyQuip::InvalidParameters);

    let recipient_pubkey = Pubkey::from(to_bytes);
    // Verify mint matches registered chain mint
    require!(mint_info.key() == chain_config.mint, PithyQuip::InvalidMint);
    // Verify token account belongs to the declared recipient
    {
        let ata_data = recipient_info.try_borrow_data()?;
        // SPL token account: owner at bytes [32..64]
        require!(ata_data.len() >= 64, PithyQuip::InvalidParameters);
        let acct_owner = Pubkey::try_from(&ata_data[32..64])
            .map_err(|_| PithyQuip::InvalidParameters)?;
        require!(acct_owner == recipient_pubkey, PithyQuip::InvalidParameters);
    }
    // Convert SD → local decimals
    let amount_local = amount_sd.checked_mul(SD_TO_LOCAL)
        .ok_or(PithyQuip::InvalidParameters)?;

    // Mint QD to recipient using OAppStore PDA as mint authority
    let seeds: &[&[u8]] = &[OAPP_STORE_SEED, &[store_bump]];
    let signer_seeds = &[seeds];
    let mint_ix = anchor_lang::solana_program::instruction::Instruction {
        program_id: *token_prog.key,
        accounts: vec![
            anchor_lang::solana_program::instruction::AccountMeta::new(*mint_info.key, false),
            anchor_lang::solana_program::instruction::AccountMeta::new(*recipient_info.key, false),
            anchor_lang::solana_program::instruction::AccountMeta::new_readonly(store_key, true),
        ],
        // spl-token MintTo discriminator: [7] for legacy, [14] for 2022
        // Use raw invoke_signed with the token program's mint_to instruction
        data: {
            let mut d = vec![7u8]; // MintTo instruction index for spl-token
            d.extend_from_slice(&amount_local.to_le_bytes());
            d
        },
    };
    anchor_lang::solana_program::program::invoke_signed(&mint_ix,
        &[mint_info.clone(), recipient_info.clone()], signer_seeds)?;
    
    emit!(QDBridgeReceived { recipient: recipient_pubkey,
                             amount_sd, amount_local });

    msg!("QD bridge: {} SD → {} local units minted to {}",
        amount_sd, amount_local, recipient_pubkey); Ok(())
}

#[event]
pub struct QDBridgeReceived {
    pub recipient: Pubkey,
    pub amount_sd: u64,
    pub amount_local: u64,
}

/// Apply a jury FinalRuling to a market.
/// Handles normal resolution and force majeure.
pub fn process_final_ruling(ruling: &FinalRuling,
    market: &mut Market, _market_key: &Pubkey,
    timestamp: i64) -> Result<()> {
    require!(!market.resolution_received, 
            PithyQuip::AlreadyResolved);

    if ruling.is_force_majeure() {
        market.cancelled = true;
        market.winning_sides = Vec::new();
        market.winning_splits = Vec::new();
    } else {
        market.winning_sides = ruling.winning_sides.clone();
    }
    market.resolution_received = true;
    market.resolution_finalized = timestamp;
    Ok(())
}

#[derive(Accounts)]
pub struct SendJuryCompensation<'info> {
    #[account(mut, seeds = [b"market",
    &market.market_id.to_le_bytes()[..6]],
    bump = market.bump)]
    pub market: Account<'info, Market>,

    #[account(seeds = [OAPP_STORE_SEED],
               bump = oapp_store.bump)]
    pub oapp_store: Account<'info, OAppStore>,

    #[account(mut)]
    pub payer: Signer<'info>,
    pub system_program: Program<'info, System>,
}

pub fn send_jury_compensation(ctx: Context<SendJuryCompensation>) -> Result<()> {
    let market = &mut ctx.accounts.market;
    require!(market.resolution_finalized > 0,
            PithyQuip::ResolutionNotFinal);

    market.jury_fee_pool = 0;
    let amount = market.jury_fee_pool;
    let compensation = JuryCompensation {
    market_id: market.market_id, amount };
    
    let compose_msg = compensation.encode();
    let seeds: &[&[&[u8]]] = &[&[OAPP_STORE_SEED,
                &[ctx.accounts.oapp_store.bump]]];

    // remaining_accounts: [0] = ChainConfig, [1..6] = quote, [7..] = send
    let chain_config_info = &ctx.remaining_accounts[0];
    require!(chain_config_info.owner == &crate::ID, PithyQuip::InvalidPeer);

    let chain_data = chain_config_info.try_borrow_data()?;
    require!(chain_data.len() >= 12, PithyQuip::InvalidPeer);
    let eid_bytes = u32::from_le_bytes(chain_data[8..12].try_into().unwrap()).to_be_bytes();
    let (expected_pda, _) = Pubkey::find_program_address(&[CHAIN_SEED, &eid_bytes], &crate::ID);

    let chain_config = ChainConfig::try_deserialize_unchecked(&mut chain_data.as_ref())
                                         .map_err(|_| PithyQuip::InvalidPeer)?;
    require!(chain_config_info.key() == expected_pda, PithyQuip::InvalidPeer);
    
    require!(chain_config.active, PithyQuip::InvalidPeer);
    require!(chain_config.peer_address != [0u8; 32], PithyQuip::PeerNotConfigured);

    let message = wrap_in_oft_format(compose_msg, chain_config.peer_address);
    let options = chain_config.enforced_options.get_enforced_options(&None::<Vec<u8>>);
    let quote_accounts = &ctx.remaining_accounts[1..7];
    let send_accounts = &ctx.remaining_accounts[7..];
    let quote_result = cpi_quote(
        ctx.accounts.oapp_store.endpoint_program, quote_accounts,
        QuoteParams {
            sender: ctx.accounts.oapp_store.key(),
            dst_eid: chain_config.eid,
            receiver: chain_config.peer_address,
            message: message.clone(),
            options: options.clone(),
            pay_in_lz_token: false,
        },
    )?;
    cpi_send(
        ctx.accounts.oapp_store.endpoint_program,
        ctx.accounts.oapp_store.key(), send_accounts, seeds,
        SendParams { dst_eid: chain_config.eid, receiver: chain_config.peer_address,
            message, options, native_fee: quote_result.native_fee, lz_token_fee: 0 },
    )?;
    Ok(())
}

#[derive(Accounts)]
#[instruction(params: LzReceiveParams)]
pub struct LzReceive<'info> {
    #[account(mut, seeds = [OAPP_STORE_SEED], bump = store.bump)]
    pub store: Account<'info, OAppStore>,

    /// CHECK: LayerZero endpoint account
    #[account(seeds = [b"OApp", store.key().as_ref()],
    bump, seeds::program = store.endpoint_program)]
    pub oapp_registry: AccountInfo<'info>,

    /// CHECK: LayerZero nonce account
    #[account(seeds = [b"Nonce",
        store.key().as_ref(),
        &params.src_eid.to_be_bytes(), &params.sender[..]],
        bump, seeds::program = store.endpoint_program
    )]
    pub nonce: AccountInfo<'info>,

    /// CHECK: LayerZero payload hash account
    #[account(mut,
        seeds = [b"PayloadHash",
        store.key().as_ref(),
        &params.src_eid.to_be_bytes(),
        &params.sender[..], &params.nonce.to_be_bytes()],
        bump, seeds::program = store.endpoint_program
    )]
    pub payload_hash: AccountInfo<'info>,

    /// CHECK: LayerZero endpoint settings
    #[account(mut, seeds = [b"Endpoint"],
    bump, seeds::program = store.endpoint_program)]
    pub endpoint: AccountInfo<'info>,

    /// CHECK: LayerZero endpoint program
    pub endpoint_program: AccountInfo<'info>,
}

#[derive(Accounts)]
pub struct LzReceiveTypes<'info> {
    #[account(seeds = [OAPP_STORE_SEED], bump = store.bump)]
    pub store: Account<'info, OAppStore>,
}

pub fn lz_receive_types_handler(ctx: Context<LzReceiveTypes>,
    params: &LzReceiveParams) -> Result<Vec<LzAccount>> {
    require!(!params.message.is_empty(), PithyQuip::InvalidMessageType);
    let mut accounts = vec![];

    // OFT bridge transfer: toAddress[32] + amountSD[8], no type byte
    if params.message.len() == OFT_BRIDGE_MSG_LEN {
        // Caller must include: ChainConfig, QD mint, recipient ATA, token program
        // These are passed as remaining_accounts in lz_receive.
        // lz_receive_types returns empty here — accounts are caller-specified.
        return Ok(accounts);
    }

    let msg_type = params.message[0];
    if msg_type == FINAL_RULING {
        let ruling = FinalRuling::decode(&params.message)?;
        let (market_pda, _) = Pubkey::find_program_address(&[b"market",
                &ruling.market_id.to_le_bytes()[..6]], ctx.program_id);
        accounts.push(LzAccount { pubkey: market_pda,
            is_signer: false, is_writable: true });
    }
    Ok(accounts)
}

#[derive(Clone,
    AnchorSerialize,
    AnchorDeserialize)]
pub struct InitOAppStoreParams {
    pub endpoint: Pubkey,
}

#[derive(Accounts)]
#[instruction(params: InitOAppStoreParams)]
pub struct InitOAppStore<'info> {
    #[account(mut)]
    pub payer: Signer<'info>,

    #[account(init, payer = payer, space = OAppStore::SIZE, seeds = [OAPP_STORE_SEED], bump)]
    pub store: Account<'info, OAppStore>,

    #[account(init, payer = payer, space = LzReceiveTypesAccounts::SIZE,
              seeds = [LZ_RECEIVE_TYPES_SEED, &store.key().to_bytes()], bump)]
    pub lz_receive_types_accounts: Account<'info, LzReceiveTypesAccounts>,

    /// CHECK: Verified via constraint - program data must be derived from program
    #[account(
        constraint = {
            // Derive the expected programdata address from the program ID
            let (expected_programdata, _) = Pubkey::find_program_address(
                &[program.key().as_ref()],
                &anchor_lang::solana_program::bpf_loader_upgradeable::id()
            );
            expected_programdata == program_data.key()
        } @ PithyQuip::InvalidParameters
    )]
    pub program: AccountInfo<'info>,

    /// CHECK: Constraint ensures payer IS the upgrade authority
    #[account(
        constraint = {
            let data = program_data.try_borrow_data()?;
            // UpgradeableLoaderState::ProgramData layout:
            // - bytes 0..4: enum variant (3 = ProgramData)
            // - bytes 4..12: slot (u64)
            // - byte 12: Option discriminant (0 = None, 1 = Some)
            // - bytes 13..45: upgrade_authority pubkey (if Some)
            if data.len() < 45 { return Err(PithyQuip::InvalidParameters.into()); }
            let variant = u32::from_le_bytes(data[0..4].try_into().unwrap());
            if variant != 3 { return Err(PithyQuip::InvalidParameters.into()); }
            let has_authority = data[12] == 1;
            if !has_authority { return Err(PithyQuip::Unauthorized.into()); }
            let authority_bytes: [u8; 32] = data[13..45].try_into().unwrap();
            let upgrade_authority = Pubkey::new_from_array(authority_bytes);
            upgrade_authority == payer.key()
        } @ PithyQuip::Unauthorized
    )]
    pub program_data: AccountInfo<'info>,
    pub system_program: Program<'info, System>,
}

pub fn init_oapp_store_handler(ctx: &mut Context<InitOAppStore>, params: &InitOAppStoreParams) -> Result<()> {
    ctx.accounts.store.admin = ctx.accounts.payer.key();
    ctx.accounts.store.bump = ctx.bumps.store;
    ctx.accounts.store.endpoint_program = params.endpoint;
    ctx.accounts.lz_receive_types_accounts.store = ctx.accounts.store.key();

    #[cfg(not(feature = "testing"))]
    {
        let register_params = RegisterOAppParams { delegate: ctx.accounts.store.admin };
        let seeds: &[&[&[u8]]] = &[&[OAPP_STORE_SEED, &[ctx.accounts.store.bump]]];
        cpi_register_oapp(params.endpoint, ctx.accounts.store.key(), ctx.remaining_accounts, seeds, register_params)?;
    }
    Ok(())
}

#[account]
pub struct LzReceiveTypesAccounts {
    pub store: Pubkey,
}

impl LzReceiveTypesAccounts {
    pub const SIZE: usize = 8 + 32;
}

#[derive(Clone,
    AnchorSerialize,
    AnchorDeserialize)]
pub struct LzReceiveParams {
    pub src_eid: u32,
    pub sender: [u8; 32],
    pub nonce: u64,
    pub guid: [u8; 32],
    pub message: Vec<u8>,
    pub extra_data: Vec<u8>,
}

#[derive(Clone,
    AnchorSerialize,
    AnchorDeserialize)]
pub struct SendParams {
    pub dst_eid: u32,
    pub receiver: [u8; 32],
    pub message: Vec<u8>,
    pub options: Vec<u8>,
    pub native_fee: u64,
    pub lz_token_fee: u64,
}

#[derive(Clone,
    AnchorSerialize,
    AnchorDeserialize)]
pub struct ClearParams {
    pub receiver: Pubkey,
    pub src_eid: u32,
    pub sender: [u8; 32],
    pub nonce: u64,
    pub guid: [u8; 32],
    pub message: Vec<u8>,
}

#[derive(Clone,
    AnchorSerialize,
    AnchorDeserialize)]
pub struct RegisterOAppParams {
    pub delegate: Pubkey,
}

#[derive(Clone,
    AnchorSerialize,
    AnchorDeserialize)]
pub struct LzAccount {
    pub pubkey: Pubkey,
    pub is_signer: bool,
    pub is_writable: bool,
}

#[derive(Clone,
    AnchorSerialize,
    AnchorDeserialize)]
pub struct QuoteParams {
    pub sender: Pubkey,
    pub dst_eid: u32,
    pub receiver: [u8; 32],
    pub message: Vec<u8>,
    pub options: Vec<u8>,
    pub pay_in_lz_token: bool,
}

#[derive(Clone,
    AnchorSerialize,
    AnchorDeserialize)]
pub struct MessagingFee {
    pub native_fee: u64,
    pub lz_token_fee: u64,
}

fn cpi_send<'info>(
    endpoint_program: Pubkey, _oapp: Pubkey,
    remaining_accounts: &[AccountInfo<'info>],
    signer_seeds: &[&[&[u8]]], params: SendParams) -> Result<()> {
    let mut ix_data = vec![102, 251, 20, 187, 65, 75, 12, 69];
    ix_data.extend_from_slice(&params.try_to_vec()?);
    let ix = anchor_lang::solana_program::instruction::Instruction {
        program_id: endpoint_program, accounts: remaining_accounts.iter()
            .map(|acc| anchor_lang::solana_program::instruction::AccountMeta {
                pubkey: *acc.key, is_signer: acc.is_signer,
                is_writable: acc.is_writable }).collect(),
        data: ix_data,
    };
    anchor_lang::solana_program::program::invoke_signed(
                  &ix, remaining_accounts, signer_seeds)?;
    Ok(())
}

fn cpi_quote<'info>(endpoint_program: Pubkey,
    accounts: &[AccountInfo<'info>], params: QuoteParams) -> Result<MessagingFee> {
    let mut ix_data = vec![53, 91, 145, 11, 230, 75, 175, 90];
    ix_data.extend_from_slice(&params.try_to_vec()?);
    let ix = anchor_lang::solana_program::instruction::Instruction {
        program_id: endpoint_program, accounts: accounts.iter().map(
        |acc| anchor_lang::solana_program::instruction::AccountMeta {
                            pubkey: *acc.key, is_signer: acc.is_signer,
                is_writable: acc.is_writable }).collect(), data: ix_data };

    anchor_lang::solana_program::program::invoke(&ix, accounts)?;
    let (program_id, return_data) = anchor_lang::solana_program::program::get_return_data()
                                                        .ok_or(PithyQuip::NoReturnData)?;

    require!(program_id == endpoint_program, PithyQuip::InvalidReturnData);
    MessagingFee::try_from_slice(&return_data).map_err(|_| PithyQuip::InvalidReturnData.into())
}

pub fn cpi_clear<'info>(
    endpoint_program: Pubkey, _oapp: Pubkey, accounts: &[AccountInfo<'info>],
    signer_seeds: &[&[&[u8]]], params: ClearParams) -> Result<()> {
    let mut ix_data = vec![250, 39, 28, 213, 123, 163, 133, 5];

    ix_data.extend_from_slice(&params.try_to_vec()?);
    let ix = anchor_lang::solana_program::instruction::Instruction {
        program_id: endpoint_program, accounts: accounts.iter().map(
                |acc| anchor_lang::solana_program::instruction::AccountMeta {
                                pubkey: *acc.key, is_signer: acc.is_signer,
                                is_writable: acc.is_writable, }).collect(),
        data: ix_data,
    };
    anchor_lang::solana_program::program::invoke_signed(
                            &ix, accounts, signer_seeds)?;
    Ok(())
}

pub fn cpi_register_oapp<'info>(
    endpoint_program: Pubkey, _oapp: Pubkey, accounts: &[AccountInfo<'info>],
    signer_seeds: &[&[&[u8]]], params: RegisterOAppParams) -> Result<()> {
    let mut ix_data = vec![129, 89, 71, 68, 11, 82, 210, 125];
    ix_data.extend_from_slice(&params.try_to_vec()?);

    let ix = anchor_lang::solana_program::instruction::Instruction {
        program_id: endpoint_program, accounts: accounts.iter().map(
                |acc| anchor_lang::solana_program::instruction::AccountMeta {
                                pubkey: *acc.key, is_signer: acc.is_signer,
                                is_writable: acc.is_writable, }).collect(),
        data: ix_data,
    };
    anchor_lang::solana_program::program::invoke_signed(
                            &ix, accounts, signer_seeds)?;
    Ok(())
}

pub fn get_accounts_for_clear(_endpoint_program: &Pubkey,
    _receiver: &Pubkey, _src_eid: u32, _sender: &[u8; 32],
    _nonce: u64) -> Vec<LzAccount> { vec![] }

#[cfg(feature = "testing")]
#[derive(Accounts)]
pub struct TestReceiveRuling<'info> {
    #[account(mut)]
    pub authority: Signer<'info>,

    #[account(mut, seeds = [b"market",
              &market.market_id.to_le_bytes()[..6]],
              bump = market.bump)]
    pub market: Account<'info, Market>,
}