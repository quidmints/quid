
use anchor_lang::prelude::*;
use anchor_lang::solana_program::{
    instruction::{AccountMeta, Instruction},
    program::invoke_signed,
};
use anchor_spl::token_interface::{self, Burn, Mint, TokenAccount, TokenInterface};
use crate::etc::PithyQuip;

/// LayerZero V2 Endpoint program on Solana, and the endpoint ids either side
/// of the only bridge this program has.
///
/// Hardcoded rather than left to config because a wrong endpoint is not a
/// recoverable misconfiguration: messages are addressed to it, and QD is
/// minted on what it delivers, so a caller who supplies their own endpoint is
/// supplying their own mint authority.
///
/// From LayerZero's metadata service and checked against mainnet — the program
/// is live under the upgradeable loader at this address, and the same program
/// serves testnet. `tests/fixtures/lz_endpoint.so` is a dump of it, loaded
/// into the local validator at this address the way the Pyth feeds are, so the
/// bridge is exercised against the real program rather than a stand-in.
///
/// `76y77prsiCMvXMjuoZ5VRrhG5qYBrUMYTE5WgHqgjEn6`
pub const LZ_ENDPOINT_PROGRAM: Pubkey = Pubkey::new_from_array([
    90, 173, 118, 218, 81, 75, 110, 29, 207, 17, 3, 126,
    144, 77, 172, 61, 55, 95, 82, 92, 159, 186, 252, 177,
    149, 7, 183, 137, 7, 216, 193, 139,
]);

/// Solana mainnet. Ours.
pub const SOLANA_EID: u32 = 30_168;
/// Ethereum mainnet, where Basket.sol lives and where the ERC-6909 id a QD
/// balance was issued under is remembered.
pub const ETHEREUM_EID: u32 = 30_101;

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
    /// Basket.sol, left-padded to 32 bytes. The only address here that is not
    /// a constant: the endpoint is `LZ_ENDPOINT_PROGRAM` and the chain we
    /// accept from is `ETHEREUM_EID`, so storing either would only create a
    /// way for the record and the code to disagree.
    pub peer_address: [u8; 32],
    /// QD mint on this chain.
    pub mint: Pubkey,
    pub enforced_options: EnforcedOptions,
}

impl OAppStore {
    pub const SIZE: usize = 8 + 32 + 1 + 32 + 32
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

/// Send QD home. The mirror of `handle_oft_receive`: that mints against
/// supply locked on L1, this burns and tells L1 to release.
///
/// Permissionless by design — a holder bridging their own balance creates and
/// destroys nothing, it changes chains. Gating it would leave QD on this side
/// with no exit, and the par it is credited at unenforceable, since closing a
/// gap means moving QD home.
#[derive(Accounts)]
pub struct BridgeHome<'info> {
    #[account(mut)]
    pub signer: Signer<'info>,

    /// Holds the peer and the enforced options, and signs the endpoint CPI:
    /// the endpoint only accepts a send from the OApp that owns the peer.
    #[account(seeds = [OAPP_STORE_SEED], bump = store.bump)]
    pub store: Box<Account<'info, OAppStore>>,

    #[account(mut, address = store.mint @ PithyQuip::InvalidMint)]
    pub mint: Box<InterfaceAccount<'info, Mint>>,

    #[account(mut,
        constraint = from.mint == store.mint @ PithyQuip::InvalidMint,
        constraint = from.owner == signer.key() @ PithyQuip::Unauthorized)]
    pub from: Box<InterfaceAccount<'info, TokenAccount>>,

    pub token_program: Interface<'info, TokenInterface>,

    /// CHECK: pinned to the shared endpoint, as everywhere else.
    #[account(address = LZ_ENDPOINT_PROGRAM @ PithyQuip::InvalidSettlementProgram)]
    pub endpoint_program: AccountInfo<'info>,
}

pub fn bridge_home<'info>(ctx: Context<'_, '_, 'info, 'info, BridgeHome<'info>>,
    amount: u64, to: [u8; 20], native_fee: u64) -> Result<()> {
    // Only whole shared-decimal units survive the wire, so anything finer
    // would be burned here and never arrive. Round the burn down to what the
    // message can actually carry rather than silently keeping the remainder.
    let amount_sd = amount / SD_TO_LOCAL;
    require!(amount_sd > 0, PithyQuip::InvalidAmount);
    let burn_amount = amount_sd.saturating_mul(SD_TO_LOCAL);

    token_interface::burn(CpiContext::new(
        ctx.accounts.token_program.to_account_info(),
        Burn {
            mint: ctx.accounts.mint.to_account_info(),
            from: ctx.accounts.from.to_account_info(),
            authority: ctx.accounts.signer.to_account_info(),
        }), burn_amount)?;

    // An Ethereum address, left-padded the way `bytes32ToAddress` reads it.
    let mut recipient = [0u8; 32];
    recipient[12..].copy_from_slice(&to);

    let store = &ctx.accounts.store;
    let seeds: &[&[&[u8]]] = &[&[OAPP_STORE_SEED, &[store.bump]]];
    cpi_send(LZ_ENDPOINT_PROGRAM, ctx.remaining_accounts, seeds,
        SendParams {
            dst_eid: ETHEREUM_EID,
            // The destination OApp is Basket.sol; the end recipient rides in
            // the message's own `sendTo` field, set just above.
            receiver: store.peer_address,
            message: wrap_in_oft_format(recipient, amount_sd),
            options: store.enforced_options.get_enforced_options(&None),
            native_fee, lz_token_fee: 0,
        })?;

    emit!(QDBridgeSent { sender: ctx.accounts.signer.key(),
                         recipient: to, amount_sd });
    Ok(())
}

#[event]
pub struct QDBridgeSent {
    pub sender: Pubkey,
    pub recipient: [u8; 20],
    /// What was burned is this times `SD_TO_LOCAL`, so only one is recorded.
    pub amount_sd: u64,
}

/// Encode an outbound OFT payload: `to[32] ‖ amountSD[8]`, and nothing else.
///
/// A QD return is a plain token transfer, so it carries no compose message —
/// the absence is the meaning. `Basket.sol` reads the recipient and the size
/// straight from this header and derives the maturity itself, so there is
/// nothing left to encode: no ids, no amounts, no message type. An earlier
/// shape sent `abi.encode(uint[] ids, uint[] amounts)` behind a type byte,
/// which duplicated both header fields and could not be decoded anyway.
pub fn wrap_in_oft_format(send_to: [u8; 32], amount_sd: u64) -> Vec<u8> {
    let mut message = Vec::with_capacity(OFT_BRIDGE_MSG_LEN);
    message.extend_from_slice(&send_to);
    message.extend_from_slice(&amount_sd.to_be_bytes());
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
    bump, seeds::program = LZ_ENDPOINT_PROGRAM)]
    pub oapp_registry: AccountInfo<'info>,

    /// CHECK: LayerZero nonce account
    #[account(seeds = [b"Nonce",
        store.key().as_ref(),
        &params.src_eid.to_be_bytes(), &params.sender[..]],
        bump, seeds::program = LZ_ENDPOINT_PROGRAM
    )]
    pub nonce: AccountInfo<'info>,

    /// CHECK: LayerZero payload hash account
    #[account(mut,
        seeds = [b"PayloadHash",
        store.key().as_ref(),
        &params.src_eid.to_be_bytes(),
        &params.sender[..], &params.nonce.to_be_bytes()],
        bump, seeds::program = LZ_ENDPOINT_PROGRAM
    )]
    pub payload_hash: AccountInfo<'info>,

    /// CHECK: LayerZero endpoint settings
    #[account(mut, seeds = [b"Endpoint"],
    bump, seeds::program = LZ_ENDPOINT_PROGRAM)]
    pub endpoint: AccountInfo<'info>,

    /// CHECK: the shared endpoint, pinned. The CPI below is addressed using
    /// `store.endpoint_program`, so this account is not what authorises it —
    /// constraining it anyway keeps a caller from presenting one program here
    /// and having the seeds above resolved against another.
    #[account(address = LZ_ENDPOINT_PROGRAM @ PithyQuip::InvalidSettlementProgram)]
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

    require!(params.src_eid == ETHEREUM_EID, PithyQuip::InvalidParameters);
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
    /// Basket.sol on Ethereum, left-padded to 32 bytes. The endpoint and the
    /// endpoint id are deliberately not parameters — they come from
    /// `LZ_ENDPOINT_PROGRAM` and `ETHEREUM_EID`, so there is no configuration
    /// under which this OApp talks to the wrong endpoint or accepts from the
    /// wrong chain.
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

    /// The protocol config, for the one thing it settles here: which token
    /// this bridge is allowed to mint. `registered_mints` is fixed at
    /// `init_config` to exactly `[token_mint, USD_STAR]` and nothing can
    /// change it afterwards, so tying the bridge's mint to `token_mint` is
    /// what makes "only these two" true rather than merely intended.
    #[account(seeds = [b"program_config"], bump = config.bump)]
    pub config: Box<Account<'info, crate::entra::ProgramConfig>>,

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
    ctx.accounts.store.peer_address = params.peer_address;
    // The token LayerZero mints and the token deposits accept have to be the
    // same one. They were set from separate inputs with nothing relating them,
    // so a bridge could have been stood up minting a token the pool would not
    // take — or, with the mint whitelist keyed on the other value, taking one
    // the bridge never minted.
    require_keys_eq!(params.mint, ctx.accounts.config.token_mint,
                     PithyQuip::InvalidMint);
    ctx.accounts.store.mint = params.mint;
    ctx.accounts.store.enforced_options = EnforcedOptions {
        send: params.enforced_options_send.clone(),
        send_and_call: Vec::new(),
    };
    ctx.accounts.lz_receive_types_accounts.store = ctx.accounts.store.key();

    // Register with the endpoint, which is what makes this program an OApp it
    // will deliver to. Gated on the accounts being supplied rather than on a
    // cargo feature: `#[cfg(not(feature = "testing"))]` meant the binary under
    // test skipped a CPI the shipped one performs, so the one path that
    // matters was the one never exercised. Same shape as the mint whitelist
    // that sat behind a `mainnet` feature and was therefore absent from every
    // build that forgot the flag.
    //
    // A caller who supplies the endpoint accounts registers; one who does not
    // gets a store that is configured but unregistered — a state worth being
    // able to reach deliberately and hard to reach by accident.
    if !ctx.remaining_accounts.is_empty() {
        let register_params = RegisterOAppParams { delegate: ctx.accounts.store.admin };
        let seeds: &[&[&[u8]]] = &[&[OAPP_STORE_SEED, &[ctx.accounts.store.bump]]];
        cpi_register_oapp(LZ_ENDPOINT_PROGRAM,
                          ctx.remaining_accounts, seeds, register_params)?;
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





#[cfg(test)]
mod bridge_label {
    use super::*;

    /// The endpoint address is the one value here that cannot be wrong twice.
    /// It is written as bytes, so this decodes it back to the base58 that
    /// LayerZero publishes and that `solana program show` resolves on mainnet.
    #[test]
    fn endpoint_constant_is_the_published_address() {
        const ALPHABET: &[u8] = b"123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
        let mut digits: Vec<u8> = vec![0];
        for &byte in LZ_ENDPOINT_PROGRAM.as_ref() {
            let mut carry = byte as usize;
            for d in digits.iter_mut() {
                carry += (*d as usize) << 8;
                *d = (carry % 58) as u8;
                carry /= 58;
            }
            while carry > 0 { digits.push((carry % 58) as u8); carry /= 58; }
        }
        let encoded: String = digits.iter().rev()
            .map(|&d| ALPHABET[d as usize] as char).collect();
        assert_eq!(encoded, "76y77prsiCMvXMjuoZ5VRrhG5qYBrUMYTE5WgHqgjEn6");
        assert_eq!(SOLANA_EID, 30_168);
        assert_eq!(ETHEREUM_EID, 30_101);
    }

    #[test]
    fn outbound_payload_is_the_header_and_nothing_else() {
        // The empty composeMsg is the whole design: Basket.sol treats "no
        // message" as a plain transfer, reads recipient and size from the
        // header, and derives the maturity. Anything encoded here would be a
        // duplicate of the header or a field a sender could choose.
        let mut recipient = [0u8; 32];
        recipient[12..].copy_from_slice(&[0xAB; 20]);
        let msg = wrap_in_oft_format(recipient, 1_234_567);

        assert_eq!(msg.len(), OFT_BRIDGE_MSG_LEN, "header only, no composeMsg");
        assert_eq!(&msg[..32], &recipient, "recipient occupies the first word");
        assert_eq!(u64::from_be_bytes(msg[32..40].try_into().unwrap()), 1_234_567,
                   "the amount is the header's, and Ethereum mints exactly it");
    }

    #[test]
    fn dust_below_a_shared_unit_cannot_be_burned() {
        // The wire carries whole shared-decimal units. Burning finer than that
        // would destroy QD the message could never carry.
        assert_eq!(SD_TO_LOCAL, 1_000);
        let below = SD_TO_LOCAL - 1;
        assert_eq!(below / SD_TO_LOCAL, 0, "sub-unit amounts must be refused");
        let ragged = 2 * SD_TO_LOCAL + 7;
        assert_eq!((ragged / SD_TO_LOCAL) * SD_TO_LOCAL, 2 * SD_TO_LOCAL,
                   "the burn rounds down to what can actually arrive");
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

/// Call the endpoint, signing as the OApp.
///
/// The three entry points below — send, clear, register — differ only in an
/// eight-byte discriminator and the params they serialise. Each carried its
/// own copy of "build the AccountMeta list, append borsh, invoke_signed",
/// which is three places for an account flag to be dropped in transit.
fn endpoint_cpi<'info, P: AnchorSerialize>(endpoint_program: Pubkey,
    discriminator: [u8; 8], accounts: &[AccountInfo<'info>],
    signer_seeds: &[&[&[u8]]], params: P) -> Result<()> {
    let mut ix_data = discriminator.to_vec();
    ix_data.extend_from_slice(&params.try_to_vec()?);

    // The PDA we are signing for has to be *declared* a signer in the
    // instruction, not merely passed with seeds. Copying `is_signer` off the
    // account info could never do that: a PDA is not a signer of the outer
    // transaction, so it arrives false and the endpoint rejects the call as
    // unsigned. `invoke_signed` grants the privilege only where the meta asks
    // for it and the seeds check out.
    //
    // Deriving it from the seeds rather than taking it as a parameter keeps
    // the two from disagreeing — an earlier signature carried the OApp as an
    // argument, went unread, and was removed as dead precisely because nothing
    // consumed it.
    let signers: Vec<Pubkey> = signer_seeds.iter()
        .filter_map(|seeds| Pubkey::create_program_address(seeds, &crate::ID).ok())
        .collect();

    let ix = Instruction {
        program_id: endpoint_program,
        accounts: accounts.iter().map(|acc| AccountMeta {
            pubkey: *acc.key,
            is_signer: acc.is_signer || signers.contains(acc.key),
            is_writable: acc.is_writable }).collect(),
        data: ix_data,
    };
    invoke_signed(&ix, accounts, signer_seeds)?;
    Ok(())
}

/// `endpoint::send`
fn cpi_send<'info>(endpoint_program: Pubkey,
    remaining_accounts: &[AccountInfo<'info>],
    signer_seeds: &[&[&[u8]]], params: SendParams) -> Result<()> {
    endpoint_cpi(endpoint_program, [102, 251, 20, 187, 65, 75, 12, 69],
                 remaining_accounts, signer_seeds, params)
}

/// `endpoint::clear` — settles the nonce so a payload cannot be replayed.
pub fn cpi_clear<'info>(endpoint_program: Pubkey,
    accounts: &[AccountInfo<'info>],
    signer_seeds: &[&[&[u8]]], params: ClearParams) -> Result<()> {
    endpoint_cpi(endpoint_program, [250, 39, 28, 213, 123, 163, 133, 5],
                 accounts, signer_seeds, params)
}

/// `endpoint::register_oapp`
pub fn cpi_register_oapp<'info>(endpoint_program: Pubkey,
    accounts: &[AccountInfo<'info>],
    signer_seeds: &[&[&[u8]]], params: RegisterOAppParams) -> Result<()> {
    endpoint_cpi(endpoint_program, [129, 89, 71, 68, 11, 82, 210, 125],
                 accounts, signer_seeds, params)
}
