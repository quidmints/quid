
use anchor_lang::prelude::*;
use anchor_spl::token_interface::{
    self, Mint, TokenAccount,
    TokenInterface, TransferChecked
};
use solana_program::keccak::hashv;
use crate::etc::PithyQuip;

pub const USD_STAR_DECIMALS: u8 = 6;
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

pub const SQUADS_MULTISIG_V4: &str = "SQDS4ep65T869zMMBKyuUq6aD6EgTu8psMjkvj52pCf";

/// PDA seed for the native-SOL collateral pool.
pub const SOL_POOL_SEED: &[u8] = b"sol_pool";

/// Anchor discriminator for `flash_repay` — sha256("global:flash_repay")[..8].
pub const FLASH_REPAY_DISC: [u8; 8] = [0xb6, 0x8f, 0x13, 0x17, 0x27, 0xdd, 0xb8, 0x4e];

/// Off-chain: derive the Squads v4 vault PDA (index 0) for a given multisig.
/// Seeds: [b"vault", multisig.as_ref(), &[0u8]], program = SQUADS_MULTISIG_V4
#[account]
pub struct ProgramConfig {
    /// Protocol admin. After init_config, should be a Squads v4 vault PDA.
    /// Controls: keeper, bebop_authority, registered_mints.
    pub admin: Pubkey,
    /// Single trusted server key. Used in three roles:
    ///   1. Signs its own server-side txs (e.g. `enroll_device`).
    ///   2. Signs `resolve` / `resolve_challenge` after running Claude resolution.
    ///   3. Co-signs user-built gated txs (the exposure-growth path in clutch.rs;
    ///      future device-attested submission paths from the verify helper).
    ///
    /// Compromised keeper → can post wrong verdicts (overridable via challenge +
    /// `force_jury`) and can deny gated exposure-growth, but CANNOT drain vaults
    /// (that's `bebop_authority`) or change config (admin/Squads only).
    /// `resolve_jury` is permissionless after KEEPER_GRACE_SECS so a compromised
    /// keeper cannot indefinitely freeze a market.
    ///
    /// Future re-split: if rotation independence between the "submit own tx"
    /// role and "co-sign user tx" role is ever needed, add a separate
    /// `web_cosigner: Pubkey`, route handle_out + verify-helper to it, and keep
    /// this `keeper` for resolve + enroll_device only.
    pub keeper: Pubkey,
    pub token_mint: Pubkey,
    pub registered_mints: [Pubkey; 2], // [quid_mint, USD*]
    pub bump: u8,
    /// JAM settlement program authority PDA.
    /// flash_borrow requires flash_authority.key() == this field.
    /// Pubkey::default() = flash loans disabled.
    /// SENSITIVE: rotations go through update_config (stage) →
    /// accept_bebop_authority (commit after BEBOP_ROTATION_DELAY).
    pub bebop_authority: Pubkey,
    pub pending_bebop_authority: Option<Pubkey>,
    pub bebop_authority_pending_since: i64,
    pub config_version: u32,
}

impl ProgramConfig {
    pub const SPACE: usize = 8
        + 32  // admin
        + 32  // keeper
        + 32  // token_mint
        + 64  // registered_mints [2]
        + 1   // bump
        + 32  // bebop_authority
        + 33  // pending_bebop_authority (Option<Pubkey>)
        + 8   // bebop_authority_pending_since
        + 4;  // config_version → total 246
}

/// After resolution, users have 24 hours to reveal commitments.
pub const REVEAL_WINDOW: i64 = 24 * 60 * 60; // 24 hours

/// After deadline, anyone may permissionlessly trigger LZ jury resolution
/// if the keeper has not yet posted a verdict. Bounds keeper liveness risk:
/// a stalled or compromised keeper cannot indefinitely freeze a market.
/// Effective only when `jury_config` is set on the market — markets without
/// a jury configured fall back to permissionless `cancel_jury_timeout` if
/// even the jury path stalls.
pub const KEEPER_GRACE_SECS: i64 = 24 * 60 * 60;

// =============================================================================
// RESOLUTION — keeper-signed verdict, single bond, optional jury fallback
// =============================================================================
//
// MODE_AI (0):           Keeper runs Claude resolution. Verdict posted via
//                        `resolve(winning_sides, confidence, thread_url, hash)`.
// MODE_AI_PLUS_JURY (1): Same as MODE_AI; if confidence below threshold, or a
//                        challenger sets `force_jury=true`, falls through to LZ
//                        jury via `send_resolution_request`. Requires jury_config.
// MODE_JURY_ONLY (2):    No Claude pass. Permissionless `resolve_jury` after
//                        deadline. Requires jury_config.

pub const MODE_AI: u8 = 0;
pub const MODE_AI_PLUS_JURY: u8 = 1;
pub const MODE_JURY_ONLY: u8 = 2;

/// Single resolution bond (lamports) — same across all modes.
/// Covers expected Claude API or LZ message cost. Claimed by keeper after
/// resolution if fees_collected don't cover oracle_compute_cost; otherwise
/// refunded to creator.
pub const RESOLUTION_BOND: u64 = 25_000_000;

/// Keeper must report at least this confidence to resolve.
/// Below this → market stays unresolved (auto-routes to jury if jury_config set).
pub const MIN_RESOLUTION_CONFIDENCE: u64 = 7_000; // 70%

/// Maximum challenge attempts before auto-cancel with refund.
pub const MAX_CHALLENGES: u8 = 3;

// Force majeure: signalled by an EMPTY winning_sides Vec on the wire,
// matching Court.sol (`res.verdict = new uint8[](0)`) and FinalRuling's
// `is_force_majeure()` check in LZ.rs. No sentinel u8 constant needed.

/// Resolution thread URL max length (bytes).
pub const MAX_THREAD_URL_LEN: usize = 200;

pub fn transfer_from_vault<'info>(
    vault: &InterfaceAccount<'info, TokenAccount>,
    mint: &InterfaceAccount<'info, Mint>,
    recipient_ata: &InterfaceAccount<'info, TokenAccount>,
    vault_bump: u8,
    token_program: &Interface<'info, TokenInterface>,
    amount: u64) -> Result<u64> {
    if amount == 0 || vault.amount == 0 { return Ok(0); }
    let transfer_amount = amount.min(vault.amount);
    let mint_key = mint.key();
    let signer_seeds: &[&[&[u8]]] = &[&[b"vault",
            mint_key.as_ref(), &[vault_bump]]];

    let cpi_ctx = CpiContext::new_with_signer(
        token_program.to_account_info(),
        TransferChecked {
            from: vault.to_account_info(),
            mint: mint.to_account_info(),
            to: recipient_ata.to_account_info(),
            authority: vault.to_account_info(),
        },
        signer_seeds,
    );
    token_interface::transfer_checked(cpi_ctx,
        transfer_amount, mint.decimals)?;

    Ok(transfer_amount)
}

/// Pro-rata withdrawal across primary vault + alternate vaults from remaining_accounts.
/// remaining_accounts layout: [alt_mint, alt_vault, alt_user_ata] triplets.
pub fn transfer_from_vaults<'info>(
    primary_vault: &InterfaceAccount<'info, TokenAccount>,
    primary_mint: &InterfaceAccount<'info, Mint>,
    primary_user_ata: &InterfaceAccount<'info, TokenAccount>,
    primary_vault_bump: u8, remaining_accounts: &[AccountInfo<'info>],
    token_program: &Interface<'info, TokenInterface>, program_id: &Pubkey,
    registered_mints: &[Pubkey], requested_amount: u64) -> Result<u64> {
    let primary_bal = primary_vault.amount;
    let mut total: u64 = primary_bal;
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
                take, primary_mint.decimals,
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
            ), take, dec)?;
        sent += take;
    } Ok(sent)
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct OrderParams {
    pub outcome: u8,
    pub capital: u64,
    /// commitment_hash = keccak256(le8(confidence) || evidence_url_hash || salt)
    /// where evidence_url_hash = keccak256(utf8_bytes(evidence_url)),
    /// or [0u8;32] for no-evidence bids.
    pub commitment_hash: [u8; 32],
    pub reveal_delegate: Option<Pubkey>,
    pub max_deviation_bps: Option<u64>,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct RevealEntry {
    pub confidence: u64,
    /// keccak256(utf8_bytes(evidence_url)) for this entry, or [0u8;32]
    /// for no-evidence bids. Bound to the on-chain commitment_hash.
    pub evidence_url_hash: [u8; 32],
    pub salt: [u8; 32],
}

// =============================================================================
// MARKET — Event Outcome Predictions
// =============================================================================

#[account]
pub struct Market {
    pub market_id: u64,
    pub creator: Pubkey,
    /// The prediction question. Must be objectively resolvable.
    pub question: String,
    pub context: String,
    pub exculpatory: String,
    /// Optional hint for the keeper on where to find resolution data.
    pub resolution_source: String,
    pub outcomes: Vec<String>,
    pub num_outcomes: u8,

    pub start_time: i64,
    pub deadline: i64,

    // LMSR
    pub liquidity: u64,
    pub tokens_sold_per_outcome: Vec<u64>,

    // Capital tracking
    pub total_capital: u64,
    pub total_capital_per_outcome: Vec<u64>,
    pub fees_collected: u64,

    // SOL bond — total = MIN_CREATOR_BOND_LAMPORTS + RESOLUTION_BOND
    pub creator_bond_lamports: u64,
    pub sol_vault_bump: u8,

    // Resolution
    pub resolved: bool,
    pub cancelled: bool,
    pub winning_outcome: u8,
    pub resolution_confidence: u64,
    pub resolution_time: i64,

    // Multi-winner support
    pub winning_sides: Vec<u8>,
    pub winning_splits: Vec<u64>,
    pub num_winners: u8,
    pub beneficiaries: Vec<Option<Pubkey>>,

    // Challenge mechanism
    pub challenge_count: u8,
    pub challenged: bool,

    // Settlement tracking
    pub positions_revealed: u64,
    pub positions_total: u64,
    pub positions_processed: u64,
    pub total_winner_weight_revealed: u128,
    pub total_loser_weight_revealed: u128,
    pub total_winner_capital_revealed: u64,
    pub total_loser_capital_revealed: u64,
    pub winner_weight_per_outcome: Vec<u128>,

    pub weights_complete: bool,
    pub payouts_complete: bool,
    pub creator_fee_bps: u16,
    pub time_decay_lambda: u64,

    // TWAP manipulation resistance
    pub price_cumulative_per_outcome: Vec<u128>,
    pub price_checkpoint_per_outcome: Vec<u128>,
    pub last_price_update: i64,
    pub checkpoint_timestamp: i64,

    // ── Resolution mode — set at create_market, immutable ──
    // 0=ai, 1=ai_plus_jury, 2=jury_only
    pub resolution_mode: u8,

    // ── Resolution accounting (folded in from removed MarketEvidence PDA) ──
    /// Bond earmark for the keeper (lamports). Always RESOLUTION_BOND.
    pub resolution_bond: u64,
    /// Estimated keeper compute cost (QD tokens). If non-zero and fees_collected
    /// covers it, keeper is paid from fees and SOL bond is refunded to creator.
    pub oracle_compute_cost: u64,
    /// True after keeper has claimed the resolution bond.
    pub oracle_claimed: bool,
    /// Optional jury fallback config. Required for MODE_AI_PLUS_JURY and MODE_JURY_ONLY.
    pub jury_config: Option<JuryConfig>,
    /// Set when a challenger calls challenge(force_jury=true). Locks out
    /// resolve_challenge (keeper Claude re-run) and unlocks resolve_jury
    /// (LZ jury escalation). Cleared once the LZ request is sent.
    pub force_jury_pending: bool,

    // ── Resolution thread (set at resolve time) ──
    /// URL of the keeper's published resolution transcript (canonical JSON).
    /// Empty until resolve(). Capped at MAX_THREAD_URL_LEN bytes.
    pub resolution_thread_url: String,
    /// keccak256 of the canonical transcript JSON. Tamper-evident: a malicious
    /// keeper can take the URL down but cannot serve different bytes that hash
    /// the same. Verifiable off-chain by jurors during challenge.
    pub thread_content_hash: [u8; 32],

    // ── Cross-chain resolution (optional, via LayerZero) ──
    pub resolution_requested: bool,
    pub resolution_received: bool,
    pub resolution_requester: Option<Pubkey>,
    pub resolution_requested_time: Option<i64>,
    pub resolution_finalized: i64,
    pub jury_fee_pool: u64,
    pub bump: u8,

    /// SHA256(resolution_source) stored at create_market(). verdict_resolve
    /// verifies the submitted template URL against this, proving the evaluation
    /// used the criteria the creator committed to. None = no Claude oracle path.
    pub verdict_hash: Option<[u8; 32]>,
}

impl Market {
    /// Dynamic space calculation based on outcomes and string lengths.
    ///
    /// Per outcome: label borsh(4+50 avg)
    ///   + parallel vecs: tokens(8) + capital(8) + twap_cum(16) + twap_chk(16)
    ///   + multi-winner: split(8) + beneficiary(1+32) + winner_weight(16)
    ///   = ~159 avg, padded to 166.
    /// Fixed: discriminator(8) + scalars(~280) + vec_prefixes(10×4=40)
    ///   + string_prefixes(4×4=16) + thread_url(4+200=204) + thread_hash(32)
    ///   + jury_config(1+14=15) + safety(60) + verdict_hash(1+32=33) = ~688. Round to 695.
    const FIXED_OVERHEAD: usize = 695;
    const PER_OUTCOME_BYTES: usize = 166;

    pub fn space_for(num_outcomes: u8, question_len: usize, context_len: usize,
                     exculpatory_len: usize, source_len: usize) -> usize {

        Self::FIXED_OVERHEAD + 4 + question_len
            + 4 + context_len + 4 + exculpatory_len
            + 4 + source_len + (num_outcomes as usize) * Self::PER_OUTCOME_BYTES
    }

    pub fn get_state(&self,
        current_time: i64) -> MarketState {
        if self.cancelled {
            if self.resolution_requested {
                return MarketState::ForceMajeure;
            }
            return MarketState::Cancelled;
        }
        if self.payouts_complete {
            return MarketState::Finalized;
        }
        if self.weights_complete {
            return MarketState::PushingPayouts;
        }
        if self.resolved && !self.challenged {
            return MarketState::Settling;
        }
        if self.challenged {
            return MarketState::Challenged;
        }
        if self.resolution_requested && !self.resolution_received {
            return MarketState::JuryPending;
        }
        if current_time >= self.deadline {
            return MarketState::AwaitingResolution;
        }
        MarketState::Trading
    }
}

impl anchor_lang::Key for Market {
    fn key(&self) -> Pubkey {
        let (pda, _) = Pubkey::find_program_address(
            &[b"market", &self.market_id.to_le_bytes()[..6]],
            &crate::ID);
        pda
    }
}

pub const MIN_CREATOR_BOND_LAMPORTS: u64 = 100_000_000;

/// Total minimum SOL bond a creator must pay (lamports).
/// Of which RESOLUTION_BOND is earmarked for keeper compensation.
pub const MIN_TOTAL_CREATOR_BOND: u64 = MIN_CREATOR_BOND_LAMPORTS + RESOLUTION_BOND;

/// Challenge bond multiplier. Challenger stakes 2× creator bond + resolution bond.
pub const CHALLENGE_BOND_MULTIPLIER: u64 = 2;

pub const MIN_JURY_POOL: u64 = 1_000_000;

/// If a jury ruling has not arrived within this window after
/// `send_resolution_request`, anyone may call `cancel_jury_timeout`
/// to enter force majeure (market cancelled, full refunds).
pub const JURY_TIMEOUT_SECS: i64 = 14 * 24 * 60 * 60;

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct JuryConfig {
    pub binding: bool,
    pub requires_unanimous: bool,
    pub appeal_cost: u64,
    pub dst_eid: u32,
}

impl JuryConfig {
    pub const SIZE: usize = 1 + 1 + 8 + 4; // 14 bytes
}

#[derive(AnchorSerialize,
    AnchorDeserialize, Clone)]
pub struct CreateMarketParams {
    pub question: String,
    pub context: String,
    pub exculpatory: String,
    pub resolution_source: String,
    pub outcomes: Vec<String>,
    pub deadline: i64,
    pub liquidity: u64,
    pub creator_fee_bps: u16,
    /// Total SOL bond. Must be >= MIN_TOTAL_CREATOR_BOND.
    /// Of this, RESOLUTION_BOND is earmarked for keeper compensation.
    pub creator_bond: u64,
    /// 0=AI, 1=AI_PLUS_JURY, 2=JURY_ONLY.
    pub resolution_mode: u8,
    /// Required when resolution_mode != MODE_AI.
    pub jury_config: Option<JuryConfig>,
    /// Estimated keeper compute cost in QD tokens. 0 = always pay keeper from SOL bond.
    pub oracle_compute_cost: u64,
    // Multi-winner support
    pub num_winners: u8,
    pub winning_splits: Vec<u64>,
    pub beneficiaries: Vec<Option<Pubkey>>,
}

#[derive(Clone, Copy,
    Debug, PartialEq, Eq)]
pub enum MarketState { Trading,
    AwaitingResolution, JuryPending,
    Challenged, Settling, PushingPayouts,
    Finalized, Cancelled, ForceMajeure,
}

#[account]
pub struct AccuracyBuckets {
    pub market: Pubkey,
    pub buckets: Vec<u64>,
    pub bump: u8,
}

impl AccuracyBuckets {
    pub const NUM_BUCKETS: usize = 100;
    pub const SPACE: usize = 8 + 32 +
        4 + (8 * Self::NUM_BUCKETS) + 1;

    pub fn add_position(&mut self,
        accuracy: u64) -> Result<()> {
        let bucket_idx = ((accuracy as usize)
            .saturating_mul(Self::NUM_BUCKETS) / 10_001)
            .min(Self::NUM_BUCKETS - 1);

        if bucket_idx < self.buckets.len() {
            self.buckets[bucket_idx] = self.buckets[bucket_idx].saturating_add(1);
        }
        Ok(())
    }

    pub fn calculate_percentile(&self, accuracy: u64,
            total_positions: u64) -> u64 {

        if total_positions <= 1 { return 5000; }
        let bucket_idx = ((accuracy as usize)
            .saturating_mul(Self::NUM_BUCKETS) / 10_001)
            .min(Self::NUM_BUCKETS - 1);

        let positions_below_x2 = self.buckets[..bucket_idx].iter()
            .fold(0u64, |acc, &b| acc.saturating_add(b).saturating_add(b))
            + self.buckets.get(bucket_idx).copied().unwrap_or(0);

        ((positions_below_x2 as u128).saturating_mul(10_000) /
        ((total_positions as u128).saturating_mul(2))).min(10_000) as u64
    }
}

#[derive(Clone,
    AnchorSerialize,
    AnchorDeserialize)]
pub struct PositionEntry {
    pub capital: u64,
    pub tokens: u64,
    pub timestamp: i64,
    pub capital_seconds: u128,
    pub last_updated: i64,
    pub commitment_hash: [u8; 32],
    /// LMSR TWAP price for this outcome at order placement time, in BPS (0–10_000).
    pub price_at_entry: u16,
}

/// Position PDA — one per (market, user, outcome).
#[account]
pub struct Position {
    pub market: Pubkey,
    pub user: Pubkey,
    pub outcome: u8,
    pub total_capital: u64,
    pub total_tokens: u64,
    pub total_capital_seconds: u128,
    pub entries: Vec<PositionEntry>,
    /// 0 = unrevealed. Set during reveal phase.
    pub revealed_confidence: u64,
    pub accuracy_percentile: u64,
    pub weight: u128,
    pub reveal_delegate: Option<Pubkey>,
    pub bump: u8,
}

impl Position { pub const MAX_ENTRIES: usize = 20;
    pub const SPACE: usize = 8 + 32 + 32 + 1 + 8 + 8 + 16
        + 4 + (Self::MAX_ENTRIES * 82) + 8 + 8 + 16 + 33 + 1;
}

/// Two-value commitment: keccak256(le8(confidence) || evidence_url_hash || salt).
/// evidence_url_hash = keccak256(utf8_bytes(url)), or [0u8;32] for no-evidence bids.
pub fn hash_commitment(confidence: u64,
            evidence_url_hash: &[u8; 32],
            salt: &[u8; 32]) -> [u8; 32] {

    hashv(&[&confidence.to_le_bytes(), evidence_url_hash, salt]).to_bytes()
}

// =============================================================================
// EVENTS
// =============================================================================

#[event]
pub struct MarketCreated {
    pub market_id: u64,
    pub market_key: Pubkey,
    pub question: String,
    pub outcomes: Vec<String>,
    pub creator: Pubkey,
    pub deadline: i64,
}

#[event]
pub struct MarketResolved {
    pub market_key: Pubkey,
    pub winning_outcome: u8,
    pub winning_sides: Vec<u8>,
    pub confidence: u64,
}

#[event]
pub struct MarketChallenged {
    pub market_key: Pubkey,
    pub challenger: Pubkey,
    pub challenge_count: u8,
}

#[event]
pub struct JuryRequested {
    pub market_key: Pubkey,
    pub requester: Pubkey,
}

#[event]
pub struct JuryRulingReceived {
    pub market_key: Pubkey,
    pub winning_sides: Vec<u8>,
}

/* LMSR: C(q) = b·log(Σ exp(qᵢ/b)); pᵢ = exp(qᵢ/b)/Z (Boltzmann). */
pub fn calculate_lmsr_price(outcome_index: usize,
    shares_per_outcome: &[u64], liquidity: f64) -> Result<f64> {
    require!(outcome_index < shares_per_outcome.len(), PithyQuip::InvalidSide);
    require!(liquidity > 0.0, PithyQuip::InvalidLiquidity);
    let ratios: Vec<f64> = shares_per_outcome.iter()
        .map(|&s| (s as f64) / liquidity).collect();
    let max_ratio = ratios.iter().cloned().fold(
                    f64::NEG_INFINITY, f64::max);

    let exp_values: Vec<f64> = ratios.iter()
        .map(|&r| (r - max_ratio).exp())
        .collect();

    let sum: f64 = exp_values.iter().sum();
    require!(sum.is_finite() && sum > 0.0,
    PithyQuip::PriceCalculationOverflow);

    let price = exp_values[outcome_index] / sum;
    require!(price >= 0.0 && price <= 1.0,
                PithyQuip::InvalidPrice);
    Ok(price)
}

pub fn calculate_adaptive_lambda(duration_seconds: i64, num_outcomes: usize) -> f64 {
    let duration_hours = ((duration_seconds as f64) / 3600.0).max(0.1).min(8760.0);

    const LAMBDA_BASE: f64 = 5.0;
    const LAMBDA_MIN: f64 = 0.5;
    const LAMBDA_MAX: f64 = 10.0;

    let complexity = (num_outcomes as f64).sqrt();
    let complexity_adjustment = 1.0 / (1.0 + (complexity - 2.0) / 5.0);
    let duration_factor = if duration_hours < 1.0 {
        (2.0 / duration_hours).min(4.0)
    } else if duration_hours < 24.0 {
        3.0 / (1.0 + duration_hours.ln()).max(0.5)
    } else if duration_hours < 168.0 {
        2.0 / (1.0 + duration_hours.ln()).max(0.5)
    } else {
        1.5 / (1.0 + duration_hours.ln()).max(0.5)
    };
    let liquidity_premium = if duration_hours < 12.0 { 1.5 } else { 1.0 };
    let lambda_star = LAMBDA_BASE * complexity_adjustment * duration_factor * liquidity_premium;
    let lambda_clamped = lambda_star.max(LAMBDA_MIN).min(LAMBDA_MAX);

    if lambda_clamped.exp() > 50_000.0 {
        return LAMBDA_MAX.min(9.0);
    }
    lambda_clamped
}

pub fn calculate_adaptive_liquidity(
    market: &Market, current_timestamp: i64) -> u64 {
    let initial_liquidity = market.liquidity as f64;
    let age_seconds = current_timestamp.saturating_sub(market.start_time);
    let age_days = ((age_seconds as f64) / 86400.0).max(0.01);
    let time_factor = (1.0 + age_days.ln()).max(1.0);

    let n = market.outcomes.len() as f64;
    const BETA: f64 = 500.0;
    let expected_capital = BETA * n;
    let expected_ctp = expected_capital * age_days;

    let actual_ctp = ((market.total_capital as f64) *
        age_days / 2.0).max(expected_ctp * 0.1);

    let ctp_ratio = (actual_ctp / expected_ctp).max(0.5).min(10.0);
    let volume_factor = ctp_ratio.powf(0.25);

    let complexity_factor = n.powf(0.25);
    let entropy_factor = 1.0 + (n.ln() / 10.0);

    let liquidity = initial_liquidity * time_factor
        * volume_factor * complexity_factor * entropy_factor;

    liquidity.max(initial_liquidity).min(
        initial_liquidity * 10.0) as u64
}

pub fn calculate_time_decay(position_duration: i64,
    market_duration: i64, lambda: u64) -> u64 {
    if market_duration <= 0 { return 10_000; }
    let participation = ((position_duration as u128)
        .saturating_mul(10_000) / (market_duration as u128))
        .min(10_000) as u64;

    if lambda < 100 { return participation; }
    if lambda < 200 {
        let t = lambda - 100;
        let linear = participation as u128;
        let quad = (participation as u128)
            .saturating_mul(participation as u128) / 10_000;
        return (linear.saturating_mul((100 - t) as u128)
            .saturating_add(quad.saturating_mul(t as u128)) / 100) as u64;
    }
    let p = participation as u128;
    let blend = ((lambda - 200)
        as u128).min(800) * 10_000 / 800;
    let quadratic = p * p / 10_000;
    let quartic   = p * p / 10_000 * p / 10_000 * p / 10_000;
    let blended = (quadratic * (10_000 - blend) / 10_000
        + quartic * blend / 10_000).min(10_000) as u64;
    let floor = (participation / 2).max(100);
    blended.max(floor)
}

// =============================================================================
// DEVICE ENROLLMENT
// =============================================================================
// Enrolled-device PDA gating for spam-resistant gated paths (currently:
// exposure-growth in clutch.rs::handle_out, future: hardware-attested
// submissions via the verify helper). Web platform = server-cosigned by
// config.keeper. Mobile platforms (StrongBox / App Attest) are reserved
// for future use; the verify_strongbox_signature helper in entra.rs is
// retained for that path even though no current instruction calls it.
//
// Seeds: [b"device_enrollment", device_pubkey.as_ref()]

#[account]
pub struct DeviceEnrollment {
    pub device_pubkey: Pubkey,
    pub config_version: u32,
    pub revoked: bool,
    pub platform: u8,
    pub bump: u8,
}

impl DeviceEnrollment {
    pub const SPACE: usize = 8
        + 32  // device_pubkey
        + 4   // config_version
        + 1   // revoked
        + 1   // platform
        + 1;  // bump  → 47 bytes

    pub const PLATFORM_ANDROID_STRONGBOX: u8 = 0;
    pub const PLATFORM_IOS_SECURE_ENCLAVE: u8 = 1;
    /// Browser session enrolled via server cosigner.
    pub const PLATFORM_WEB: u8 = 2;
}

#[derive(AnchorSerialize,
    AnchorDeserialize, Clone)]
pub struct EnrollDeviceParams {
    pub device_pubkey: Pubkey,
    pub config_version: u32,
    pub platform: u8,
}

#[event]
pub struct DeviceEnrolled {
    pub device_pubkey: Pubkey,
    pub platform: u8,
}