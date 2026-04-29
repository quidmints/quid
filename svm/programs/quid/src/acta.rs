// programs/quid/src/acta.rs — Evidence pipeline and device enrollment.
//
// Evidence pipeline:
//   1. Creator calls init_market_evidence after create_market.
//      Commits the EvidenceRequirements (tags, resolution mode, bond).
//   2. Devices call submit_evidence. On-chain: DeviceEnrollment PDA verified.
//      The chain's job is to confirm the transaction came from the right app
//      on an attested device. That's it. The app does the hard part.
//   3. Oracle fetches signed feature vector from device via libp2p,
//      verifies the attestation chain, runs the evidence formula.
//      Market resolves against tags, never against session content.
//
// Device enrollment (gates submit_evidence AND deposit):
//   enroll_device     — Attestation chain verified off-chain at install time,
//                       creates DeviceEnrollment PDA with the device pubkey.
//                       Two platform paths, both producing the same on-chain
//                       artifact:
//                         Android: StrongBox-generated Ed25519 key, locked
//                                  bootloader, hardware-reported APK cert.
//                         iOS:     software Ed25519 key whose generation was
//                                  attested by an App Attest assertion over
//                                  the official bundle ID + team ID.
//   revoke_enrollment — admin or device marks enrollment revoked immediately.
//
// Liveness detection is entirely an app concern, not a chain concern.
// On Android the StrongBox key is bound to a locked bootloader and the
// specific APK signing cert; on iOS the App Attest assertion binds to the
// app's bundle ID + team ID. Verifying the submission came from an enrolled
// key is sufficient — it means the app ran, and the app runs liveness.
// No IdentityAnchor, no biometric hash, no threshold PDA. Nothing biometric
// touches the chain.

use anchor_lang::prelude::*;
use anchor_lang::solana_program::sysvar::instructions::{
    load_current_index_checked, load_instruction_at_checked,
};
use crate::state::{
    Market, MarketEvidence, EvidenceRequirements, EvidenceRequirementsParams,
    SubmitEvidenceParams, EvidenceSubmission, PipelineRoute,
    JuryConfig, ProgramConfig, RESOLUTION_BOND, MAX_EVIDENCE_SUBMISSIONS,
    SUBMISSION_GRACE_SECS, MIN_TAG_CONFIDENCE_FLOOR,
    MODE_JURY_ONLY, MODE_AI_PLUS_JURY,
    DeviceEnrollment, EnrollDeviceParams,
};
use crate::etc::PithyQuip;

// ─────────────────────────────────────────────────────────────────────────────
// INIT MARKET EVIDENCE
// ─────────────────────────────────────────────────────────────────────────────

/// Commits the evidence protocol for a market.
/// Called by the market creator after create_market.
/// The committed EvidenceRequirements cannot be changed after this.
/// The oracle is bound to run exactly what is committed here.
#[derive(Accounts)]
#[instruction(market_id: u64, params: EvidenceRequirementsParams)]
pub struct InitMarketEvidence<'info> {
    #[account(mut)]
    pub creator: Signer<'info>,

    #[account(mut,
        seeds = [b"market", &market_id.to_le_bytes()[..6]],
        bump = market.bump,
    )]
    pub market: Box<Account<'info, Market>>,

    #[account(init, payer = creator,
        space = MarketEvidence::space_for(
            params.required_tags.len(),
            params.pipeline_routes.len(),
            &params.pipeline_routes.iter().map(|r| r.tags.len()).collect::<Vec<_>>(),
            &params.pipeline_routes.iter().map(|r| r.provider_uri.len()).collect::<Vec<_>>(),
            &params.pipeline_routes.iter().map(|r| r.verdict_hint.len()).collect::<Vec<_>>(),
            params.notification_domains.len(),
        ),
        seeds = [b"market_evidence", market.key().as_ref()],
        bump,
    )]
    pub market_evidence: Account<'info, MarketEvidence>,

    /// CHECK: PDA vault — receives resolution bond
    #[account(
        mut,
        seeds = [b"sol_vault", &market_id.to_le_bytes()[..6]],
        bump = market.sol_vault_bump,
    )]
    pub sol_vault: SystemAccount<'info>,

    pub system_program: Program<'info, System>,
}

pub fn init_market_evidence(ctx: Context<InitMarketEvidence>,
    _market_id: u64, params: EvidenceRequirementsParams) -> Result<()> {
    require!(ctx.accounts.market.creator == ctx.accounts.creator.key(), PithyQuip::Unauthorized);
    require!(!ctx.accounts.market.resolved && !ctx.accounts.market.cancelled, PithyQuip::TradingFrozen);

    let final_tags = params.required_tags.clone();

    require!(final_tags.len() >= 1 && final_tags.len() <= 8, PithyQuip::InvalidParameters);
    require!(params.pipeline_routes.len() <= 8, PithyQuip::InvalidParameters);
    require!(params.notification_domains.len() <= 16, PithyQuip::InvalidParameters);
    require!(params.resolution_mode <= 3, PithyQuip::InvalidParameters);
    for route in &params.pipeline_routes {
        require!(route.tags.len() >= 1 && route.tags.len() <= 8, PithyQuip::InvalidParameters);
        require!(route.provider_uri.len() <= 200, PithyQuip::InvalidParameters);
        require!(route.verdict_hint.len() <= 200, PithyQuip::InvalidParameters);
        require!(route.model_class <= 2, PithyQuip::InvalidParameters);
    }
    if let Some(ref jc) = params.jury_config {
        require!(jc.dst_eid > 0, PithyQuip::InvalidParameters);
        require!(
            params.resolution_mode == MODE_JURY_ONLY
                || params.resolution_mode == MODE_AI_PLUS_JURY,
            PithyQuip::InvalidParameters
        );
    }
    if params.resolution_mode == MODE_JURY_ONLY || params.resolution_mode == MODE_AI_PLUS_JURY {
        require!(params.jury_config.is_some(), PithyQuip::InvalidParameters);
    }
    require!(
        params.max_submissions >= 1 && params.max_submissions <= MAX_EVIDENCE_SUBMISSIONS,
        PithyQuip::InvalidParameters
    );
    let min_bond = RESOLUTION_BOND[params.resolution_mode as usize];
    require!(params.resolution_bond >= min_bond, PithyQuip::InvalidParameters);
    require!(params.min_tag_confidence >= MIN_TAG_CONFIDENCE_FLOOR, PithyQuip::InvalidParameters);
    require!(params.time_window_start < params.time_window_end, PithyQuip::InvalidParameters);
    if params.resolution_bond > 0 {
        anchor_lang::system_program::transfer(
            CpiContext::new(
                ctx.accounts.system_program.to_account_info(),
                anchor_lang::system_program::Transfer {
                    from: ctx.accounts.creator.to_account_info(),
                    to:   ctx.accounts.sol_vault.to_account_info(),
                },
            ),
            params.resolution_bond,
        )?;
    }
    let me = &mut ctx.accounts.market_evidence;
    let market_key = ctx.accounts.market.key();
    ctx.accounts.market.resolution_mode = params.resolution_mode;
    me.market = market_key;
    me.evidence = EvidenceRequirements {
        time_window_start:    params.time_window_start,
        time_window_end:      params.time_window_end,
        min_submissions:      params.min_submissions,
        required_tags:        final_tags,
        min_tag_confidence:   params.min_tag_confidence,
        pipeline_routes:      params.pipeline_routes.into_iter().map(|r| PipelineRoute {
            tags:              r.tags,
            provider_uri:      r.provider_uri,
            model_class:       r.model_class,
            priority:          r.priority,
            is_direct_evidence: r.is_direct_evidence,
            verdict_hint:      r.verdict_hint,
        }).collect(),
        notification_domains: params.notification_domains,
        resolution_mode:      params.resolution_mode,
        max_submissions:      params.max_submissions,
        resolution_bond:      params.resolution_bond,
        oracle_compute_cost:  params.oracle_compute_cost,
        jury_config:          params.jury_config.map(|jc| JuryConfig {
            binding:            jc.binding,
            requires_unanimous: jc.requires_unanimous,
            appeal_cost:        jc.appeal_cost,
            dst_eid:            jc.dst_eid,
        }),
    };
    me.submission_count = 0;
    me.oracle_claimed   = false;
    me.bump             = ctx.bumps.market_evidence;
    Ok(())
}

/// Verify the StrongBox Ed25519 signature via the instructions sysvar.
///
/// The client must include an Ed25519Program instruction immediately before
/// the submit_evidence instruction in the same transaction. That instruction
/// proves the StrongBox key signed the evidence payload.
///
/// Signed message: SHA256(attestation_hash || nonce || market_pubkey)
///   32 + 1 + 32 = 65 bytes → SHA256 → 32 byte digest
///
/// Replay prevention:
///   - nonce: the EvidenceSubmission PDA is seeded with (market, submitter, nonce),
///     so a given nonce can only be used once per device per market.
///   - time_window_end: submissions outside the window are rejected.
///   Together these make the slot unnecessary in the signed message.
///
/// Why not just check the Solana transaction signature?
///   The transaction is signed by the wallet holding the enrolled key — that
///   proves key control. The strongbox_signature proves the specific payload
///   (attestation_hash) was produced by StrongBox during this session, not
///   replayed from a previous session by the same key holder.
fn verify_strongbox_signature(instructions_sysvar: &AccountInfo,
    device_pubkey: &Pubkey, attestation_hash: &[u8; 32],
    nonce: u8, market_pubkey: &Pubkey,
    signature: &[u8; 64]) -> Result<()> {
    // Build the expected message and hash it
    let mut preimage = Vec::with_capacity(65);
    preimage.extend_from_slice(attestation_hash);
    preimage.push(nonce);
    preimage.extend_from_slice(market_pubkey.as_ref());
    
    let message = switchboard_on_demand::solana_compat::hash::hash(&preimage).to_bytes(); // SHA256, 32 bytes
    // Find the Ed25519 instruction immediately preceding this one
    let current_idx = load_current_index_checked(instructions_sysvar)
                                .map_err(|_| PithyQuip::Unauthorized)?;
    require!(current_idx > 0, 
    PithyQuip::Unauthorized);

    let ed25519_ix = load_instruction_at_checked((current_idx - 1) 
        as usize, instructions_sysvar).map_err(|_| 
                        PithyQuip::Unauthorized)?;

    require!(ed25519_ix.program_id == switchboard_on_demand::solana_compat::ed25519_program::id(),
            PithyQuip::Unauthorized);

    let data = &ed25519_ix.data;

    // Ed25519 instruction data layout:
    //   [0]      num_signatures (u8)
    //   [1]      padding (u8)
    //   [2..16]  per-signature header (14 bytes):
    //   [0..2]  signature_offset        (u16 LE)
    //   [2..4]  signature_ix_index      (u16 LE, 0xFFFF = same ix)
    //   [4..6]  pubkey_offset           (u16 LE)
    //   [6..8]  pubkey_ix_index         (u16 LE)
    //   [8..10] message_data_offset     (u16 LE)
    //   [10..12] message_data_size      (u16 LE)
    //   [12..14] message_ix_index       (u16 LE)
    // followed by the raw signature (64), pubkey (32), and message bytes
    require!(data.len() >= 2, PithyQuip::Unauthorized);
    let num_sigs = data[0] as usize;
    
    require!(num_sigs >= 1 && 
        data.len() >= 2 + num_sigs * 14, 
            PithyQuip::Unauthorized);

    let h = &data[2..2 + 14]; // first signature header
    let sig_off = u16::from_le_bytes([h[0], h[1]]) as usize;
    let pk_off  = u16::from_le_bytes([h[4], h[5]]) as usize;
    let msg_off = u16::from_le_bytes([h[8], h[9]]) as usize;
    let msg_len = u16::from_le_bytes([h[10], h[11]]) as usize;

    // Verify signature bytes match what the client passed in params
    require!(data.len() >= sig_off + 64, PithyQuip::Unauthorized);
    require!(data[sig_off..sig_off + 64] == *signature,
            PithyQuip::Unauthorized);
            
    // Verify pubkey matches the enrolled device key
    require!(data.len() >= pk_off + 32, PithyQuip::Unauthorized);
    require!(data[pk_off..pk_off + 32] == device_pubkey.to_bytes(),
            PithyQuip::Unauthorized);

    // Verify message matches SHA256(attestation_hash || nonce || market_pubkey)
    require!(msg_len == 32 && data.len() >= msg_off + 32,
            PithyQuip::Unauthorized);

    require!(data[msg_off..msg_off + 32] == message,
            PithyQuip::Unauthorized); Ok(())
}

/// Device submits evidence for a market.
///
/// HOW APP INTEGRITY IS ENFORCED
///
/// The transaction must be signed by the enrolled StrongBox key
/// (submitter == DeviceEnrollment.device_pubkey). StrongBox keys cannot
/// be exported from the hardware — a signature from this key proves the
/// submission originated from that physical device.
///
/// The oracle only created the DeviceEnrollment PDA after verifying:
///   - verifiedBootState = VERIFIED (locked bootloader, unmodified OS)
///   - APK signing cert matches expected (hardware-reported by OS, not
///     self-reported — proves the correct app generated the key)
///
/// Therefore: if the chain can verify the DeviceEnrollment PDA exists and
/// is not revoked, it knows the transaction came from the expected app on
/// an unmodified device. No other check is needed for app integrity.
///
/// The strongbox_signature field is a secondary payload-specific proof:
/// the device signed SHA256(attestation_hash || nonce || market_pubkey)
/// at submission time. This binds the specific evidence payload to this
/// nonce and market, preventing replay of a previous session's evidence.
/// Verified on-chain via the Ed25519Program instructions sysvar.
///
/// Session content never leaves the device. 
/// Oracle fetches the signed feature vector via libp2p

#[derive(Accounts)]
#[instruction(params: SubmitEvidenceParams)]
pub struct SubmitEvidence<'info> {
    #[account(mut)]
    pub submitter: Signer<'info>,

    #[account(seeds = [b"market", 
        &market.market_id.to_le_bytes()[..6]],
        bump = market.bump,
    )]
    pub market: Box<Account<'info, Market>>,

    #[account(mut,
        seeds = [b"market_evidence", 
            market.key().as_ref()],
        bump = market_evidence.bump,
    )]
    pub market_evidence: Account<'info, MarketEvidence>,

    /// StrongBox hardware attestation enrollment for this device.
    #[account(seeds = [b"device_enrollment", submitter.key().as_ref()], bump = enrollment.bump,
        constraint = enrollment.device_pubkey == submitter.key() @ PithyQuip::Unauthorized,
        constraint = !enrollment.revoked                         @ PithyQuip::Unauthorized,
    )]
    pub enrollment: Account<'info, DeviceEnrollment>,

    #[account(init, payer = submitter,
        space = EvidenceSubmission::SPACE,
        seeds = [b"evidence",
            market.key().as_ref(),
            submitter.key().as_ref(),
            &[params.nonce]], bump,
    )]
    pub evidence: Account<'info, EvidenceSubmission>,

    /// Instructions sysvar — required for Ed25519 signature verification.
    /// The transaction must include an Ed25519Program instruction immediately
    /// before this one, proving the StrongBox key signed the evidence payload.
    ///
    /// CHECK: verified as instructions sysvar via require_keys_eq in submit_evidence.
    pub instructions: UncheckedAccount<'info>,

    pub system_program: Program<'info, System>,
}

pub fn submit_evidence(ctx: Context<SubmitEvidence>,
    params: SubmitEvidenceParams) -> Result<()> {
    let market = &ctx.accounts.market;
    let me = &mut ctx.accounts.market_evidence;
    let evidence = &mut ctx.accounts.evidence;
    let clock = Clock::get()?;

    // Verify instructions account is the actual sysvar — replaces the removed
    // #[account(address = ...)] constraint to avoid the Accounts derive Pubkey conflict.
    require_keys_eq!(ctx.accounts.instructions.key(),
        anchor_lang::solana_program::sysvar::instructions::ID,
        PithyQuip::Unauthorized);

    require!(!market.resolved && !market.cancelled, PithyQuip::TradingFrozen);
    require!(me.submission_count < me.evidence.max_submissions as u64, PithyQuip::InvalidParameters);
    require!(clock.unix_timestamp <= me.evidence.time_window_end + SUBMISSION_GRACE_SECS,
            PithyQuip::InvalidParameters);

    // Verify the StrongBox signature via the Ed25519 instructions sysvar.
    // The client must have included an Ed25519Program instruction immediately
    // before this one in the same transaction, signing:
    //   SHA256(attestation_hash || nonce || market_pubkey)
    // with the enrolled device key.
    verify_strongbox_signature(&ctx.accounts.instructions, &ctx.accounts.enrollment.device_pubkey,
        &params.attestation_hash, params.nonce, &market.key(), &params.strongbox_signature)?;

    evidence.market = market.key();
    evidence.submitter = ctx.accounts.submitter.key();
    evidence.attestation_hash = params.attestation_hash;
    evidence.submitted_at = clock.unix_timestamp;
    evidence.content_type = params.content_type.min(1);
    evidence.bump = ctx.bumps.evidence;
    me.submission_count += 1;

    emit!(crate::state::EvidenceSubmitted { 
        market: market.key(),
        submitter: ctx.accounts.submitter.key(),
        content_type: evidence.content_type,
    });
    Ok(())
}

/// Enroll a device. Creates a DeviceEnrollment PDA gating all future
/// submit_evidence calls from this device.
///
/// The oracle verifies the full attestation certificate chain off-chain
/// before calling this instruction:
///   verifiedBootState = VERIFIED (locked bootloader, unmodified OS)
///   osVersion >= minimum (StrongBox availability)
///   apk_cert_hash matches expected signing cert (hardware-reported by OS,
///     not self-reported — a bootlegged APK produces a different hash)
///
/// On-chain: the PDA simply records that the oracle accepted this
/// device_pubkey. Nothing else is stored or checked — the oracle's
/// off-chain verification already happened, and the chain trusts it
/// the same way it trusts any oracle result.
///
/// Note: market creation (init_market_evidence) does NOT require enrollment.
/// Any wallet can create a market. Enrollment is only required for
/// submit_evidence — the operation that contributes data to resolution.

#[derive(Accounts)]
#[instruction(params: EnrollDeviceParams)]
pub struct EnrollDevice<'info> {
    // Device user pays rent — same as submit_evidence
    #[account(mut)]
    pub payer: Signer<'info>,

    // Oracle signs to authorize — proves off-chain attestation passed
    pub orchestrator: Signer<'info>,

    #[account(seeds = [b"program_config"], bump = config.bump, 
        constraint = orchestrator.key() == config.orchestrator @ PithyQuip::Unauthorized,
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
        // stale challenge — re-attest against current config
        PithyQuip::Unauthorized);
        
    require!(params.platform == DeviceEnrollment::PLATFORM_ANDROID_STRONGBOX
          || params.platform == DeviceEnrollment::PLATFORM_IOS_SECURE_ENCLAVE,
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

/// Revoke a device enrollment. Admin or device owner.
/// Takes effect immediately — next submit_evidence from this device fails
/// the DeviceEnrollment constraint on-chain without reaching the oracle.
///
/// The PDA is kept alive (not closed) so the device cannot silently re-enroll
/// under the same key. Re-enrollment requires a new StrongBox key under the
/// current config_version.

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

#[event]
pub struct DeviceEnrolled {
    pub device_pubkey: Pubkey,
    pub platform: u8,
}
