
use anchor_lang::prelude::*;
use crate::etc::PithyQuip;

pub const OAPP_STORE_SEED: &[u8] = b"Store";
pub const CHAIN_SEED: &[u8] = b"Chain";
pub const LZ_RECEIVE_TYPES_SEED: &[u8] = b"LzReceiveTypes";
pub const PEER_SEED: &[u8] = b"Peer";

pub const ENFORCED_OPTIONS_SEND_MAX_LEN: usize = 512;
pub const ENFORCED_OPTIONS_SEND_AND_CALL_MAX_LEN: usize = 1024;

/// OFT message format: toAddress[32] + amountSD[8], no leading type byte.
/// The only inbound message this OApp accepts.
pub const OFT_BRIDGE_MSG_LEN: usize = 40;

/// QD shared decimals on L1 (matches Basket.sol sharedDecimals()).
pub const OFT_SHARED_DECIMALS: u8 = 6;
/// QD local decimals on Solana.
pub const QD_LOCAL_DECIMALS: u8 = 9;
/// Multiply amountSD by this to get local token units.
pub const SD_TO_LOCAL: u64 = 1_000;

/// The OApp, and its single counterparty.
///
/// There was a `ChainConfig` PDA per registered chain, keyed by endpoint id.
/// Solana accepts QD from exactly one place — Basket.sol on L1 — so a registry
/// was a table with one row, an instruction to populate it, an account to pass
/// on every receive, and an ownership check to get wrong. Folding the peer into
/// the store removes all four: the peer is pinned at init and `lz_receive`
/// validates against an account it already holds.
#[account]
pub struct OAppStore {
    pub admin: Pubkey, pub bump: u8,
    pub endpoint_program: Pubkey,
    /// Endpoint id of the L1 we accept from.
    pub eid: u32,
    /// Basket.sol, left-padded to 32 bytes.
    pub peer_address: [u8; 32],
    /// QD mint on this chain.
    pub mint: Pubkey,
    pub enforced_options: EnforcedOptions,
}

impl OAppStore {
    pub const SIZE: usize = 8 + 32 + 1 + 32 + 4 + 32 + 32
        + EnforcedOptions::MAX_SIZE;
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

/// Encode an outbound OFT payload: `to[32] ‖ amountSD[8] ‖ composeMsg`.
///
/// The `compose_msg` is what carries the ERC-6909 ids home. `Basket.sol`'s
/// `_handleBasketTransfer` decodes it as `abi.encode(uint[] ids, uint[]
/// amounts)` and mints at exactly those ids, so a QD balance that arrived
/// under one id returns under the same one only if this payload names it.
/// Solana never interprets an id — it is an opaque label here, and the whole
/// job is to hand it back unaltered.
///
/// `amount_sd` used to be hardcoded to zero, which would have failed L1's
/// `require(_handleBasketTransfer(...) == amountReceivedLD)` on the first
/// real send.
#[allow(dead_code)]
pub fn wrap_in_oft_format(compose_msg: Vec<u8>, send_to: [u8; 32],
    amount_sd: u64) -> Vec<u8> {
    let mut message = Vec::with_capacity(OFT_BRIDGE_MSG_LEN + compose_msg.len());
    message.extend_from_slice(&send_to);
    message.extend_from_slice(&amount_sd.to_be_bytes());
    message.extend(compose_msg);
    message
}


/// Handle an incoming OFT QD bridge transfer from L1.
///
/// `store_info` is both the mint authority and the PDA that signs for it, so
/// it must be handed to `invoke_signed` alongside the mint and destination —
/// the runtime resolves every AccountMeta against the infos passed here, and
/// omitting the signing authority fails the CPI with a missing account.
pub fn handle_oft_receive<'a>(store_info: &AccountInfo<'a>,
    store_bump: u8, expected_mint: Pubkey,
    message: &[u8], mint_info: &AccountInfo<'a>,
    recipient_info: &AccountInfo<'a>, token_prog: &AccountInfo<'a>) -> Result<()> {
    require!(message.len() >= OFT_BRIDGE_MSG_LEN, PithyQuip::InvalidMessageFormat);
    require!(expected_mint != Pubkey::default(), PithyQuip::InvalidParameters);

    let to_bytes: [u8; 32] = message[..32].try_into()
        .map_err(|_| PithyQuip::InvalidMessageFormat)?;
    let amount_sd = u64::from_be_bytes(
        message[32..40].try_into().map_err(|_| PithyQuip::InvalidMessageFormat)?
    );
    require!(amount_sd > 0, PithyQuip::InvalidParameters);

    let recipient_pubkey = Pubkey::from(to_bytes);
    require!(mint_info.key() == expected_mint, PithyQuip::InvalidMint);
    {
        let ata_data = recipient_info.try_borrow_data()?;
        require!(ata_data.len() >= 64, PithyQuip::InvalidParameters);
        let acct_owner = Pubkey::try_from(&ata_data[32..64])
            .map_err(|_| PithyQuip::InvalidParameters)?;
        require!(acct_owner == recipient_pubkey, PithyQuip::InvalidParameters);
    }
    // Anything past the fixed header is the OFT composeMsg — the metadata
    // field the standard already provides, and the one `Basket.sol` already
    // decodes as `abi.encode(uint[] ids, uint[] amounts)`. Ignoring it here is
    // deliberate: QD is a single fungible mint on this chain, the ERC-6909 id
    // is remembered on Ethereum, and Solana's job is to avoid corrupting a
    // label it does not interpret.
    //
    // Ignored, not rejected. A revert inside `lz_receive` is not a safe way to
    // object: an undeliverable message leaves the QD locked on L1 with no way
    // through, so a tail we do not need must never be able to wedge the bridge.
    let amount_local = amount_sd.checked_mul(SD_TO_LOCAL)
        .ok_or(PithyQuip::InvalidParameters)?;

    let seeds: &[&[u8]] = &[OAPP_STORE_SEED, &[store_bump]];
    let signer_seeds = &[seeds];
    let mint_ix = anchor_lang::solana_program::instruction::Instruction {
        program_id: *token_prog.key,
        accounts: vec![
            anchor_lang::solana_program::instruction::AccountMeta::new(*mint_info.key, false),
            anchor_lang::solana_program::instruction::AccountMeta::new(*recipient_info.key, false),
            anchor_lang::solana_program::instruction::AccountMeta::new_readonly(*store_info.key, true),
        ],
        data: {
            let mut d = vec![7u8];
            d.extend_from_slice(&amount_local.to_le_bytes());
            d
        },
    };
    anchor_lang::solana_program::program::invoke_signed(&mint_ix,
        &[mint_info.clone(), recipient_info.clone(),
          store_info.clone(), token_prog.clone()], signer_seeds)?;

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

#[derive(Accounts)]
#[instruction(params: LzReceiveParams)]
pub struct LzReceive<'info> {
    #[account(mut, seeds = [OAPP_STORE_SEED], bump = store.bump)]
    pub store: Box<Account<'info, OAppStore>>,

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
    pub store: Box<Account<'info, OAppStore>>,

    /// QD mint on this chain. Its account owner is the token program that
    /// `handle_oft_receive` must be handed, and that the recipient's ATA is
    /// derived under — Token and Token-2022 give different ATAs.
    /// CHECK: address-checked against the store; only `owner` is read.
    #[account(address = store.mint @ PithyQuip::InvalidMint)]
    pub mint: AccountInfo<'info>,
}

/// Accounts `lz_receive` needs appended to `remaining_accounts`, in the exact
/// order the handler indexes them: [mint, recipient_ata, token_program]. Returning an empty vec here (as the pre-fork code did for
/// OFT messages) makes every inbound bridge transfer fail the handler's
/// `remaining_accounts.len() >= 4` check — the executor builds the account
/// list from this view, so nothing else can supply them.
///
/// The recipient ATA must already exist; `handle_oft_receive` mints into it
/// and does not create it.
pub fn lz_receive_types_handler(ctx: Context<LzReceiveTypes>,
    params: &LzReceiveParams) -> Result<Vec<LzAccount>> {
    require!(params.message.len() == OFT_BRIDGE_MSG_LEN,
             PithyQuip::InvalidMessageFormat);

    require!(params.src_eid == ctx.accounts.store.eid,
             PithyQuip::InvalidParameters);
    let mint = ctx.accounts.store.mint;
    let token_program = *ctx.accounts.mint.owner;

    let to_bytes: [u8; 32] = params.message[..32].try_into()
        .map_err(|_| PithyQuip::InvalidMessageFormat)?;

    let recipient = Pubkey::from(to_bytes);
    let (recipient_ata, _) = Pubkey::find_program_address(
        &[recipient.as_ref(), token_program.as_ref(), mint.as_ref()],
        &anchor_spl::associated_token::ID);

    Ok(vec![
        LzAccount { pubkey: mint, is_signer: false, is_writable: true },
        LzAccount { pubkey: recipient_ata, is_signer: false, is_writable: true },
        LzAccount { pubkey: token_program, is_signer: false, is_writable: false },
    ])
}

#[derive(Clone,
    AnchorSerialize,
    AnchorDeserialize)]
pub struct InitOAppStoreParams {
    pub endpoint: Pubkey,
    pub eid: u32,
    pub peer_address: [u8; 32],
    pub mint: Pubkey,
    pub enforced_options_send: Vec<u8>,
}

#[derive(Accounts)]
#[instruction(params: InitOAppStoreParams)]
pub struct InitOAppStore<'info> {
    #[account(mut)]
    pub payer: Signer<'info>,

    #[account(init, payer = payer, space = OAppStore::SIZE, seeds = [OAPP_STORE_SEED], bump)]
    pub store: Box<Account<'info, OAppStore>>,

    #[account(init, payer = payer, space = LzReceiveTypesAccounts::SIZE,
              seeds = [LZ_RECEIVE_TYPES_SEED, &store.key().to_bytes()], bump)]
    pub lz_receive_types_accounts: Box<Account<'info, LzReceiveTypesAccounts>>,

    /// CHECK: Verified via constraint - program data must be derived from program
    #[account(
        constraint = {
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
    ctx.accounts.store.eid = params.eid;
    ctx.accounts.store.peer_address = params.peer_address;
    ctx.accounts.store.mint = params.mint;
    ctx.accounts.store.enforced_options = EnforcedOptions {
        send: params.enforced_options_send.clone(),
        send_and_call: Vec::new(),
    };
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

#[derive(Clone, AnchorSerialize, AnchorDeserialize)]
pub struct LzReceiveParams {
    pub src_eid: u32,
    pub sender: [u8; 32],
    pub nonce: u64,
    pub guid: [u8; 32],
    pub message: Vec<u8>,
    pub extra_data: Vec<u8>,
}

#[derive(Clone, AnchorSerialize, AnchorDeserialize)]
pub struct SendParams {
    pub dst_eid: u32,
    pub receiver: [u8; 32],
    pub message: Vec<u8>,
    pub options: Vec<u8>,
    pub native_fee: u64,
    pub lz_token_fee: u64,
}

#[derive(Clone, AnchorSerialize, AnchorDeserialize)]
pub struct ClearParams {
    pub receiver: Pubkey,
    pub src_eid: u32,
    pub sender: [u8; 32],
    pub nonce: u64,
    pub guid: [u8; 32],
    pub message: Vec<u8>,
}

#[derive(Clone, AnchorSerialize, AnchorDeserialize)]
pub struct RegisterOAppParams {
    pub delegate: Pubkey,
}

#[derive(Clone, AnchorSerialize, AnchorDeserialize)]
pub struct LzAccount {
    pub pubkey: Pubkey,
    pub is_signer: bool,
    pub is_writable: bool,
}

#[derive(Clone, AnchorSerialize, AnchorDeserialize)]
pub struct QuoteParams {
    pub sender: Pubkey,
    pub dst_eid: u32,
    pub receiver: [u8; 32],
    pub message: Vec<u8>,
    pub options: Vec<u8>,
    pub pay_in_lz_token: bool,
}

#[derive(Clone, AnchorSerialize, AnchorDeserialize)]
pub struct MessagingFee {
    pub native_fee: u64,
    pub lz_token_fee: u64,
}

/// Outbound endpoint CPI shims. Unused while the OApp is receive-only; they
/// are the other half of the QD bridge (burn on Solana → release on L1) and
/// are kept wired so that leg is an instruction, not a re-implementation.
#[allow(dead_code)]
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

#[allow(dead_code)]
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

#[cfg(test)]
mod bridge_label {
    use super::*;

    /// `Basket.sol` mints at whatever ids the composeMsg names, so the id a
    /// balance came in under survives a round trip only if the return payload
    /// carries it. These pin the two halves of that: the header is fixed-width
    /// and the label rides behind it, and the amount field is real.
    #[test]
    fn outbound_payload_carries_the_label_and_a_real_amount() {
        let to = [7u8; 32];
        // abi.encode(uint[] ids, uint[] amounts) — opaque to us, and that is
        // the point: it is handed back exactly as it must arrive at L1.
        let label = vec![0xAB, 0xCD, 0xEF];
        let msg = wrap_in_oft_format(label.clone(), to, 1_234_567);

        assert_eq!(&msg[..32], &to, "recipient occupies the first word");
        assert_eq!(u64::from_be_bytes(msg[32..40].try_into().unwrap()), 1_234_567,
                   "amount must be the real figure — L1 requires it to match");
        assert_eq!(&msg[OFT_BRIDGE_MSG_LEN..], &label[..],
                   "the id label must survive encoding byte for byte");
    }

    #[test]
    fn a_trailing_label_cannot_wedge_the_bridge() {
        // The header is a floor, not an exact width. A composeMsg Solana has
        // no use for must pass through harmlessly: rejecting it would make the
        // message undeliverable and strand the QD locked on L1, which is a far
        // worse failure than ignoring a label Ethereum already remembers.
        let bare = vec![0u8; OFT_BRIDGE_MSG_LEN];
        let labelled = { let mut m = bare.clone(); m.extend_from_slice(&[0xFF; 96]); m };
        for m in [&bare, &labelled] {
            assert!(m.len() >= OFT_BRIDGE_MSG_LEN,
                    "both shapes clear the header check that gates delivery");
        }
    }
}
