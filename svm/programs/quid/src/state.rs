
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
pub fn is_approved_mint(mint: &Pubkey, registered_mints: &[Pubkey]) -> bool {
    registered_mints.contains(mint)
}

// =============================================================================
// PROGRAM CONFIG — admin-managed trusted oracle settings
// =============================================================================

/// Stores the trusted Switchboard Function pubkey. Only feeds generated
/// by this function are accepted for validation and resolution.
/// Prevents creators from deploying their own oracle functions with
/// spoofed results.

// ── Squads Multisig v4 ──────────────────────────────────────────────────────
// Program ID for Squads Protocol v4 on mainnet.
// Before mainnet deployment, transfer config.admin to a Squads vault PDA:
//
//   1. Create a Squads v4 multisig (app.squads.so or squads-cli):
//        squads-cli multisig create --threshold 2 --members key1,key2,key3
//      → note the createKey and derive:
//        multisig = PDA([b"multisig", createKey], SQUADS_MULTISIG_V4)
//        vault    = PDA([b"vault", multisig, [0u8]], SQUADS_MULTISIG_V4)
//
//   2. After init_config, call update_config(None, Some(vault_pda), ...) once
//      with the hot deploy key to hand control to the multisig.
//
//   3. Configure the Squads multisig with time_lock = 48 * 60 * 60 (48h).
//      This gives depositors time to exit before any sensitive config change
//      (bebop_authority, orchestrator) takes effect. Squads enforces this
//      natively — no custom timelock logic needed in this program.
//
//   4. Transfer the program upgrade authority to the same multisig:
//        solana program set-upgrade-authority <PROGRAM_ID> \
//            --new-upgrade-authority <SQUADS_VAULT_PDA>
//      A compromised upgrade key can replace the entire program, bypassing
//      all runtime guards and draining all vaults. This is the highest-risk
//      key in the system.
//
pub const SQUADS_MULTISIG_V4: &str = "SQDS4ep65T869zMMBKyuUq6aD6EgTu8psMjkvj52pCf";

/// PDA seed for the native-SOL collateral pool. ⚠ confirm byte string matches original.
pub const SOL_POOL_SEED: &[u8] = b"sol_pool";

/// Anchor discriminator for `flash_repay` — sha256("global:flash_repay")[..8].
pub const FLASH_REPAY_DISC: [u8; 8] = [0xb6, 0x8f, 0x13, 0x17, 0x27, 0xdd, 0xb8, 0x4e];

/// Off-chain: derive the Squads v4 vault PDA (index 0) for a given multisig.
/// Seeds: [b"vault", multisig.as_ref(), &[0u8]], program = SQUADS_MULTISIG_V4
/// Use the Squads SDK or CLI to compute this before calling update_config.
#[account]
pub struct ProgramConfig {
    /// Protocol admin. After init_config, should be a Squads v4 vault PDA.
    /// Controls: orchestrator, bebop_authority, registered_mints.
    /// Compromised admin → bebop_authority reset → all vaults drainable
    ///   via flash loans in the same block. Use Squads time_lock = 48h.
    pub admin: Pubkey,
    /// Switchboard Function pubkey of the trusted orchestrator.
    /// Only feeds signed by this function are accepted for resolution.
    pub orchestrator: Pubkey,
    pub token_mint: Pubkey,
    pub registered_mints: [Pubkey; 2], // [quid_mint, USD*]
    pub bump: u8,
    /// JAM settlement program authority PDA.
    /// flash_borrow requires flash_authority.key() == this field.
    /// Pubkey::default() = flash loans disabled.
    /// SENSITIVE: resetting this to an attacker-controlled key grants
    ///   the ability to initiate unlimited flash loans draining all vaults.
    ///   Must only be changeable via Squads proposal with 48h time_lock.
    pub bebop_authority: Pubkey,
}

impl ProgramConfig {
    pub const SPACE: usize = 8
        + 32  // admin
        + 32  // orchestrator
        + 32  // token_mint
        + 64  // registered_mints [2]
        + 1   // bump
        + 32; // bebop_authority  → 201 bytes
}

/// Verify that a Switchboard Pull Feed was signed by the trusted oracle function.
/// Checks feed_data.authority == config.orchestrator. PullFeedAccountData
/// is parsed by the Switchboard SDK, which verifies program ownership implicitly.
pub fn verify_trusted_feed(
    feed_data: &switchboard_on_demand::on_demand::accounts::pull_feed::PullFeedAccountData,
    config: &ProgramConfig,
) -> bool {
    feed_data.authority == config.orchestrator
}

/// After resolution, users have 24 hours to reveal commitments.
/// During this window, unrevealed positions are skipped (not yet forfeited).
/// After the window closes, unrevealed positions are forfeitable by anyone.
pub const REVEAL_WINDOW: i64 = 24 * 60 * 60; // 24 hours

// =============================================================================
// ORACLE — RESOLUTION PIPELINE
// =============================================================================
// Resolution path is determined by EvidenceRequirements.resolution_mode:
//
//   MODE_EXTERNAL (0):    Public markets. Oracle performs Brave web searches,
//                         sends results + question to LLM, encodes verdict.
//                         Runs as a Switchboard Function — off-chain compute
//                         committed on-chain via the trusted orchestrator pubkey.
//
//   MODE_DEVICE_LOCAL (1): Private markets about specific users.
//                         Oracle connects to the relevant user's mempalace
//                         instance via libp2p (/safta/fv/1.0.0) and fetches
//                         their StrongBox-signed feature vector.
//                         Verifies the hardware attestation chain, runs the
//                         committed evidence formula on the resulting
//                         EvidenceSummary. If formula resolves, done.
//                         If not, a local model classifies the evidence.
//                         Raw session content never leaves the user's device.
//                         The user's device must be online at resolution time.
//
//   MODE_JURY_ONLY (2):   Oracle calls send_resolution_request. Market
//                         transitions to JuryPending. Awaits FinalRuling
//                         from LayerZero. No oracle verdict is produced.
//
//   MODE_AI_PLUS_JURY (3): Same as MODE_DEVICE_LOCAL. If confidence is below
//                         MIN_RESOLUTION_CONFIDENCE, escalates via
//                         send_resolution_request.
//
// Return value encoding:
//   value = market_tag * 1_000_000_000_000 + outcome_index * 100_000 + confidence
//
// On-chain extraction:
//   tag        = value / 1_000_000_000_000
//   payload    = value % 1_000_000_000_000
//   outcome    = payload / 100_000
//   confidence = payload % 100_000
//
// Tag = SHA256(market_pubkey)[0..3] — binds feed to correct market.
// =============================================================================

/// Maximum staleness for Switchboard feed reads (slots, ~400ms each)
/// 300 slots ≈ 2 minutes — feeds must be fresh at resolution time
pub const SB_MAX_STALE_SLOTS: u64 = 300;

/// Minimum oracle samples required for a valid feed value
pub const SB_MIN_SAMPLES: u32 = 1;

/// Oracle must report at least this confidence to trigger resolution.
/// Below this → market stays unresolved, oracle retries later.
pub const MIN_RESOLUTION_CONFIDENCE: u64 = 7_000; // 70%

/// Minimum oracle qualification score for any market to open (0–10000).
/// One threshold for all market types — the oracle applies stricter internal
/// bars during CreateMarketPipeline for device-evidence markets.
pub const MIN_PROTOCOL_SCORE: u64 = 5_000;

/// Outcome index emitted by qualification oracle runs.
/// The qualification oracle uses this sentinel so a validation feed value
/// can never be mistaken for a real resolution outcome.
/// Mirrors Go: const QualifySentinel = 254
pub const QUALIFY_SENTINEL: u8 = 254;

/// Maximum challenge attempts before auto-cancel with refund.
pub const MAX_CHALLENGES: u8 = 3;

/// Decode the oracle return value. Verifies market tag, extracts
/// winning outcome index and confidence score.
pub fn decode_oracle_value(raw_value: u64,
    market_key: &Pubkey) -> Result<(u8, u64)> {
    const TAG: u64 = 1_000_000_000_000;
    const CONF: u64 = 100_000;
    let returned_tag = raw_value / TAG;
    let payload = raw_value % TAG;

    let hash = solana_program::keccak::hashv(&[market_key.as_ref()]).to_bytes();
    let expected_tag = u32::from_le_bytes([hash[0], hash[1], hash[2], 0]) as u64;

    require!(returned_tag == expected_tag, PithyQuip::InvalidMarketBinding);
    let outcome_index = (payload / CONF) as u8;
    let confidence = payload % CONF;
    Ok((outcome_index, confidence))
}

/// Decode multi-winner oracle value. Same tag verification as single-winner.
/// Payload encodes a bitmask of winning outcome indices:
///   winners_bitmask = payload / 100_000
///   confidence      = payload % 100_000
///
/// Bitmask: bit i set → outcome i is a winner. Max 20 outcomes → 20 bits.
/// E.g. outcomes [0, 2, 4] → bitmask = 0b10101 = 21
///
/// Oracle uses this encoding when market.num_winners > 1.
/// Single-winner markets always use decode_oracle_value (outcome_index, not bitmask).
pub fn decode_oracle_value_multi(raw_value: u64, market_key: &Pubkey,
    num_outcomes: usize) -> Result<(Vec<u8>, u64)> {
    const TAG: u64 = 1_000_000_000_000;
    const CONF: u64 = 100_000;
    let returned_tag = raw_value / TAG;
    let payload = raw_value % TAG;

    let hash = solana_program::keccak::hashv(&[market_key.as_ref()]).to_bytes();
    let expected_tag = u32::from_le_bytes([hash[0], hash[1], hash[2], 0]) as u64;
    require!(returned_tag == expected_tag, PithyQuip::InvalidMarketBinding);

    let bitmask = payload / CONF;
    let confidence = payload % CONF;

    let mut winners = Vec::new();
    for i in 0..num_outcomes.min(20) {
        if (bitmask >> i) & 1 == 1 {
            winners.push(i as u8);
        }
    }
    require!(!winners.is_empty(),
    PithyQuip::InvalidResolution);
    Ok((winners, confidence))
}

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
    token_interface::transfer_checked(cpi_ctx, transfer_amount, mint.decimals)?;
    Ok(transfer_amount)
}

/// Pro-rata withdrawal across primary vault + alternate vaults from remaining_accounts.
/// remaining_accounts layout: [alt_mint, alt_vault, alt_user_ata] triplets.
/// If total available < requested, transfers what's available.
pub fn transfer_from_vaults<'info>(
    primary_vault: &InterfaceAccount<'info, TokenAccount>,
    primary_mint: &InterfaceAccount<'info, Mint>,
    primary_user_ata: &InterfaceAccount<'info, TokenAccount>,
    primary_vault_bump: u8,
    remaining_accounts: &[AccountInfo<'info>],
    token_program: &Interface<'info, TokenInterface>,
    program_id: &Pubkey,
    registered_mints: &[Pubkey],
    requested_amount: u64) -> Result<u64> {
    // Phase 1: tally total available across all vaults
    let primary_bal = primary_vault.amount;
    let mut total: u64 = primary_bal;
    // Collect alternate vault balances
    let mut alt_vaults: Vec<(usize, u64, u8, u8)> = Vec::new(); // (idx, balance, decimals, bump)
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
    if primary_bal > 0 { // Phase 2: pro-rata transfers (primary vault share)
        let share = ((primary_bal as u128 * to_send as u128) / total as u128) as u64;
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
    } for (i, &(ai, bal, dec, bump)) in alt_vaults.iter().enumerate() {
        let remaining = to_send.saturating_sub(sent);
        if remaining == 0 { break; }
        // Last vault gets remainder to avoid rounding dust
        let take = if i == alt_vaults.len() - 1 {
            remaining.min(bal)
        } else {
            let share = ((bal as u128 * to_send as u128) / total as u128) as u64;
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
                },
                &[&[b"vault", mint_info.key.as_ref(), &[bump]]],
            ),
            take, dec,
        )?;
        sent += take;
    } Ok(sent)
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct OrderParams {
    pub outcome: u8,
    pub capital: u64,
    pub commitment_hash: [u8; 32],
    pub reveal_delegate: Option<Pubkey>,
    pub max_deviation_bps: Option<u64>,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct RevealEntry {
    pub confidence: u64,
    pub salt: [u8; 32],
}

// =============================================================================
// MARKET — Event Outcome Predictions resolved by AI and/or Jury on Ethereum
// =============================================================================

#[account]
pub struct Market {
    pub market_id: u64,
    pub creator: Pubkey,
    /// The prediction question. Must be an objectively resolvable question
    /// about a future real-world event.
    pub question: String,
    /// Definitions, condition precedents, special terms.
    /// e.g. "BTC price = CoinGecko daily close UTC. 'Close above' means
    /// the final daily candle close price strictly > threshold."
    pub context: String,
    /// Force majeure / exculpatory clauses.
    /// e.g. "Market cancels if: CoinGecko is offline for >24h during
    /// measurement period; BTC undergoes a chain halt >6h; exchange
    /// delisting removes >50% of CoinGecko's price sources."
    pub exculpatory: String,
    /// Optional hint for the oracle on where to find resolution data.
    /// e.g. "check CoinGecko", "check AP News", "check NBA.com"
    pub resolution_source: String,
    /// The possible outcomes. Fixed at creation. Minimum 2.
    pub outcomes: Vec<String>,
    /// Cached outcome count — MUST stay in sync with outcomes.len().
    /// Used by etc.rs::update_price_accumulator TWAP loop.
    pub num_outcomes: u8,

    /// Single Switchboard Pull Feed for this market.
    /// Oracle writes resolution result here.
    pub sb_feed: Pubkey,

    pub start_time: i64,
    pub deadline: i64,

    // LMSR
    pub liquidity: u64,
    pub tokens_sold_per_outcome: Vec<u64>,

    // Capital tracking
    pub total_capital: u64,
    pub total_capital_per_outcome: Vec<u64>,
    pub fees_collected: u64,

    // SOL bond
    pub creator_bond_lamports: u64,
    pub sol_vault_bump: u8,

    // Resolution
    pub resolved: bool,
    pub cancelled: bool,
    pub winning_outcome: u8,
    pub resolution_confidence: u64,
    pub resolution_time: i64,

    // Multi-winner support
    /// All winning outcome indices. For single-winner markets: vec![winning_outcome].
    /// For multi-winner contests: multiple indices (up to num_winners).
    pub winning_sides: Vec<u8>,
    /// BPS allocation per outcome index. Set at creation.
    /// Empty = equal split among winners. If non-empty: len == num_outcomes,
    /// only entries at winning_sides indices matter, must sum to 10_000.
    pub winning_splits: Vec<u64>,
    /// Expected number of winners. 1 = standard prediction market.
    /// >1 = contest/tournament with multiple winning outcomes.
    pub num_winners: u8,
    /// Optional beneficiary addresses parallel to outcomes.
    /// Used for fee-split payouts to side sponsors/creators.
    /// Empty = no beneficiaries. If non-empty: len == num_outcomes.
    pub beneficiaries: Vec<Option<Pubkey>>,

    // Challenge mechanism
    /// Number of times this resolution has been challenged and re-evaluated.
    pub challenge_count: u8,
    /// Whether a challenge is currently pending (oracle re-run in progress).
    pub challenged: bool,

    // Settlement tracking
    pub positions_revealed: u64,
    pub positions_total: u64,
    pub positions_processed: u64,
    pub total_winner_weight_revealed: u128,
    pub total_loser_weight_revealed: u128,
    pub total_winner_capital_revealed: u64,
    pub total_loser_capital_revealed: u64,
    /// Per-outcome winner weight — populated during calculate_weights.
    /// Parallel to outcomes. Only indices in winning_sides are meaningful.
    /// Used by push_payouts for split-based pot partitioning.
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
    // Mirrors EvidenceRequirements.resolution_mode for fast access during resolve.
    // 0=external 1=device_local 2=jury_only 3=ai_plus_jury
    pub resolution_mode: u8,

    // ── Cross-chain resolution (optional, via LayerZero) ──
    pub resolution_requested: bool,
    pub resolution_received: bool,
    pub resolution_requester: Option<Pubkey>,
    pub resolution_requested_time: Option<i64>,
    pub resolution_finalized: i64,
    pub jury_fee_pool: u64,

    pub bump: u8,
}

impl Market {
    /// Dynamic space calculation based on outcomes and string lengths.
    ///
    /// Per outcome: label borsh(4+50 avg)
    ///   + parallel vecs: tokens(8) + capital(8) + twap_cum(16) + twap_chk(16)
    ///   + multi-winner: winning_side(1) + split(8) + beneficiary(1+32) + winner_weight(16)
    ///   = 160 avg
    /// Fixed: discriminator(8) + scalar_fields(~270) + vec_prefixes(10×4=40)
    ///   + string length prefixes(4×4=16)
    ///   + padding(32 bytes safety margin) = 366
    const FIXED_OVERHEAD: usize = 427; // 366 + 60 (jury/resolution fields) + 1 (resolution_mode)
    const PER_OUTCOME_BYTES: usize = 166; // padded for longer labels

    pub fn space_for(num_outcomes: u8, question_len: usize, context_len: usize,
                     exculpatory_len: usize, source_len: usize) -> usize {
        Self::FIXED_OVERHEAD
            + 4 + question_len
            + 4 + context_len
            + 4 + exculpatory_len
            + 4 + source_len
            + (num_outcomes as usize) * Self::PER_OUTCOME_BYTES
    }

    pub fn get_state(&self, current_time: i64) -> MarketState {
        if self.cancelled {
            // Jury force majeure: cancelled during resolution process
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
            &crate::ID,
        );
        pda
    }
}

pub const MIN_CREATOR_BOND_LAMPORTS: u64 = 100_000_000;

/// Challenge bond = 2× creator bond. Challenger stakes this;
/// if challenge succeeds (resolution flips), they get it back + reward.
/// If challenge fails, bond goes to market fees.
pub const CHALLENGE_BOND_MULTIPLIER: u64 = 2;

// ── Anti-DoS ──
/// Hard cap on evidence submissions per market.
pub const MAX_EVIDENCE_SUBMISSIONS: u8 = 32;
/// Minimum resolution bond by mode (lamports). Creator deposits at init.
/// Oracle operator claims after resolution. Indexed by MODE_* constants.
///
/// Costs reflect actual oracle compute:
///   MODE_EXTERNAL:     Brave API calls + 3-sample LLM consensus + Switchboard Function
///   MODE_DEVICE_LOCAL: Oracle connects to user's mempalace via libp2p, verifies
///                      StrongBox attestation chain, runs formula + local model
///   MODE_JURY_ONLY:    LZ send cost only; no oracle verdict produced
///   MODE_AI_PLUS_JURY: Same as DEVICE_LOCAL; jury escalation funded by requester separately
pub const RESOLUTION_BOND: [u64; 4] = [
    75_000_000,  // MODE_EXTERNAL (0): Brave + 3-sample LLM consensus + Switchboard
    25_000_000,  // MODE_DEVICE_LOCAL (1): libp2p mempalace fetch + attestation + local model
    5_000_000,   // MODE_JURY_ONLY (2): LZ message cost only, no oracle compute
    25_000_000,  // MODE_AI_PLUS_JURY (3): same as DEVICE_LOCAL; jury path is requester-funded
];

/// 0 = public: Brave web search + LLM verdict (Switchboard Function)
pub const MODE_EXTERNAL: u8 = 0;
/// 1 = private: oracle connects to user's mempalace via libp2p, fetches
///     StrongBox-signed feature vector, runs formula locally
pub const MODE_DEVICE_LOCAL: u8 = 1;
/// 2 = jury: no oracle verdict; send_resolution_request → LayerZero → await ruling
pub const MODE_JURY_ONLY: u8 = 2;
/// 3 = device-local pipeline first; jury escalation via LZ if confidence below threshold
pub const MODE_AI_PLUS_JURY: u8 = 3;

pub const MIN_JURY_POOL: u64 = 1_000_000;

/// If a jury ruling has not arrived within this window after
/// `send_resolution_request`, anyone may call `cancel_jury_timeout`
/// to enter force majeure (market cancelled, full refunds).
/// 14 days — generous enough for cross-chain latency + appeal rounds.
pub const JURY_TIMEOUT_SECS: i64 = 14 * 24 * 60 * 60;

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct CreateMarketParams {
    pub question: String,
    pub context: String,
    pub exculpatory: String,
    pub resolution_source: String,
    pub outcomes: Vec<String>,
    pub sb_feed: Pubkey,
    pub deadline: i64,
    pub liquidity: u64,
    pub creator_fee_bps: u16,
    pub creator_bond: u64,
    // Multi-winner support
    /// Number of expected winners. 1 = standard. >1 = contest.
    pub num_winners: u8,
    /// BPS allocation per outcome. Empty = equal split.
    /// If non-empty: len == outcomes.len(), winning entries sum to 10_000.
    pub winning_splits: Vec<u64>,
    /// Optional beneficiary per outcome for fee-split payouts.
    /// Empty = no beneficiaries. If non-empty: len == outcomes.len().
    pub beneficiaries: Vec<Option<Pubkey>>,
}

/// Minimum validation score from the creation-time oracle.
/// Questions scoring below this are rejected (not resolvable enough).
pub const MIN_VALIDATION_SCORE: u64 = 6_000; // 60%

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MarketState {
    Trading,
    AwaitingResolution,
    JuryPending,
    Challenged,
    Settling,
    PushingPayouts,
    Finalized,
    Cancelled,
    ForceMajeure,
}


#[account]
pub struct AccuracyBuckets {
    pub market: Pubkey,
    pub buckets: Vec<u64>,
    pub bump: u8,
}

impl AccuracyBuckets {
    pub const NUM_BUCKETS: usize = 100;
    pub const SPACE: usize = 8 + 32 + 4 + (8 * Self::NUM_BUCKETS) + 1;

    pub fn add_position(&mut self, accuracy: u64) -> Result<()> {
        let bucket_idx = ((accuracy as usize)
            .saturating_mul(Self::NUM_BUCKETS) / 10_001)
            .min(Self::NUM_BUCKETS - 1);
        if bucket_idx < self.buckets.len() {
            self.buckets[bucket_idx] = self.buckets[bucket_idx].saturating_add(1);
        }
        Ok(())
    }

    /// Calculate percentile rank for a given accuracy score.
    /// With ≤1 total positions, percentile ranking is meaningless —
    /// return midpoint (5000) to avoid degenerate weight=0 outcomes
    /// where a solo winner gets no share of the pot.
    pub fn calculate_percentile(&self, accuracy: u64, total_positions: u64) -> u64 {
        if total_positions <= 1 { return 5000; }
        let bucket_idx = ((accuracy as usize)
            .saturating_mul(Self::NUM_BUCKETS) / 10_001)
            .min(Self::NUM_BUCKETS - 1);
        let mut positions_below = 0u64;
        for i in 0..bucket_idx {
            if i < self.buckets.len() {
                positions_below = positions_below.saturating_add(self.buckets[i]);
            }
        }
        if bucket_idx < self.buckets.len() {
            positions_below = positions_below.saturating_add(self.buckets[bucket_idx] / 2);
        }
        ((positions_below as u128)
            .saturating_mul(10_000) / (total_positions as u128))
            .min(10_000) as u64
    }
}

#[derive(Clone, AnchorSerialize, AnchorDeserialize)]
pub struct PositionEntry {
    pub capital: u64,
    pub tokens: u64,
    pub timestamp: i64,
    pub capital_seconds: u128,
    pub last_updated: i64,
    pub commitment_hash: [u8; 32],
}

/// Position PDA — one per (market, user, outcome).
///
/// Lifecycle: created in place_order, weight computed in calculate_weights,
/// then atomically paid out + closed (data zeroed, rent → creator) in
/// push_payouts. Zeroed discriminator prevents double-processing.
#[account]
pub struct Position {
    pub market: Pubkey,
    pub user: Pubkey,
    pub outcome: u8,
    pub total_capital: u64,
    pub total_tokens: u64,
    pub total_capital_seconds: u128,
    pub entries: Vec<PositionEntry>,
    /// 0 = unrevealed. Set during reveal phase of calculate_weights.
    pub revealed_confidence: u64,
    /// Raw accuracy score for bucket lookup. Actual percentile
    /// is computed in the weigh phase from AccuracyBuckets.
    pub accuracy_percentile: u64,
    pub weight: u128,
    pub reveal_delegate: Option<Pubkey>,
    pub bump: u8,
}

impl Position { pub const MAX_ENTRIES: usize = 20;
    pub const SPACE: usize = 8 + 32 + 32 + 1 + 8 + 8 + 16
        + 4 + (Self::MAX_ENTRIES * 80) + 8 + 8 + 16 + 33 + 1;
}

pub fn hash_commitment_u64(confidence: u64, salt: [u8; 32]) -> [u8; 32] {
    hashv(&[&confidence.to_le_bytes(), &salt]).to_bytes()
}

// =============================================================================
// EVENTS — indexed off-chain for frontend discovery
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

/// One attestation per (market, submitter, nonce). Submitted by device.
///
/// Hardware attestation chain:
///   1. Device captures session inside isolated process (OS cannot access raw data).
///   2. Feature extraction + StrongBox signing inside isolated process.
///   3. StrongBox signs SHA256(attestation_hash || nonce || market_pubkey).
///   4. Client includes Ed25519Program instruction in the same transaction.
///   5. submit_evidence verifies the Ed25519 instruction via instructions sysvar.
///
/// The signed feature vector (~few KB) is served directly by the device
/// via libp2p (/safta/fv/1.0.0 protocol) when the oracle requests it.
/// Raw session content never leaves the device.
///
/// Seeds: [b"evidence", market.key().as_ref(), submitter.key().as_ref(), &[nonce]]

#[account]
pub struct EvidenceSubmission {
    pub market: Pubkey,
    pub submitter: Pubkey,          // StrongBox-bound device pubkey
    /// SHA256 of the StrongBox-signed feature vector.
    /// Oracle verifies StrongBox signature chain and that
    /// SHA256(feature_vector) == attestation_hash.
    pub attestation_hash: [u8; 32],
    pub submitted_at: i64,
    /// 0 = audio, 1 = video. Hint for which feature schema to apply.
    pub content_type: u8,
    pub bump: u8,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct TagOutput {
    pub tag_id: [u8; 32],          // keccak of tag name
    pub confidence_bps: u16,        // 0-10000
    pub slot_count: u16,            // slots with this tag above threshold
}

impl EvidenceSubmission {
    /// Fixed space: disc(8) + market(32) + submitter(32) + attestation_hash(32)
    /// + submitted_at(8) + content_type(1) + bump(1) = 114 bytes.
    pub const SPACE: usize = 8 + 32 + 32 + 32 + 8 + 1 + 1; // 114 bytes

    pub fn space_for(num_models: usize, num_tags: usize) -> usize {
        8       // discriminator
        + 32    // market
        + 32    // submitter
        + 8 + 8 + 4 + 4 // timestamps, gps
        + 4 + (num_models * 32) // model_hashes vec
        + 4 + (num_tags * 36) // tags vec (32+2+2 per tag)
        + 32    // attestation_hash
        + 8 + 1 + 1 // submitted_at, content_type, bump
    }
}

// ── MARKET EVIDENCE (separate PDA — zero changes to Market struct) ──

/// Per-market evidence requirements. Created alongside market when creator
/// opts in to the evidence layer. Separate PDA so existing markets are
/// unaffected — Market struct layout does not change.
///
/// Seeds: [b"market_evidence", market.key().as_ref()]
#[account]
pub struct MarketEvidence {
    pub market: Pubkey,
    pub evidence: EvidenceRequirements,
    pub submission_count: u64,
    /// True after oracle operator has claimed the resolution bond.
    pub oracle_claimed: bool,
    pub bump: u8,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct EvidenceRequirements {
    /// Evidence must have timestamps overlapping this window.
    pub time_window_start: i64,
    pub time_window_end: i64,
    /// Minimum independent device submissions for the oracle to consider
    /// evidence sufficient. 0 = any amount is informational.
    pub min_submissions: u8,
    /// Required tag IDs. Evidence must contain at least one above min_confidence.
    pub required_tags: Vec<[u8; 32]>,
    /// Minimum per-tag confidence in bps (5000-10000). Floor 50%.
    pub min_tag_confidence: u16,

    // ── v3.2 additions ──

    /// Pipeline routes: tag→provider mappings for specialized model routing.
    /// When evidence matches route tags, the oracle dispatches to the
    /// specified provider URI (e.g., "switchboard:<model_id>" for registered
    /// models, "https://api.anthropic.com" for external LLM).
    pub pipeline_routes: Vec<PipelineRoute>,
    /// Notification domain hashes. Oracle groups tag detections by domain
    /// for summarization (e.g., speech.count, music.instruments).
    pub notification_domains: Vec<[u8; 32]>,
    /// Resolution mode. Use MODE_* constants:
    ///   0=MODE_EXTERNAL, 1=MODE_DEVICE_LOCAL (device-attested), 2=MODE_JURY_ONLY, 3=MODE_AI_PLUS_JURY.
    pub resolution_mode: u8,
    /// Hard cap on evidence submissions. Makes oracle processing cost bounded.
    /// Must be 1..=MAX_EVIDENCE_SUBMISSIONS. submit_evidence rejects beyond this.
    pub max_submissions: u8,
    /// Bond deposited by market creator (lamports). Covers oracle's off-chain
    /// resolution costs (API keys, compute). Claimed by oracle after resolution.
    /// Must be >= RESOLUTION_BOND[resolution_mode].
    pub resolution_bond: u64,
    /// Optional human jury configuration for cross-chain resolution via LayerZero.
    pub jury_config: Option<JuryConfig>,
    /// Estimated oracle compute cost in QD tokens. If non-zero and fees_collected
    /// covers it, oracle is paid from fees and SOL bond is refunded to creator.
    pub oracle_compute_cost: u64,
}

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

/// A pipeline route maps a set of tags to a processing endpoint.
/// The oracle uses this to dispatch evidence to specialized processors
/// (e.g., Whisper for transcription, embedder for semantic analysis).
/// model_class tells the oracle which model class produces input for this route.
#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct PipelineRoute {
    /// Tag IDs that trigger this route (keccak hashes).
    pub tags: Vec<[u8; 32]>,
    /// Provider URI. Examples: "switchboard:<model_id>", "https://api.anthropic.com".
    pub provider_uri: String,
    /// Pipeline role of the model that feeds this route.
    /// 0=CLASSIFIER, 1=TRANSCRIBER, 2=EMBEDDER.
    pub model_class: u8,
    /// Priority (lower = higher priority). Routes evaluated in order.
    pub priority: u8,
    /// If true, this route's output counts as direct evidence for resolution
    /// (vs. supplementary context for the LLM).
    pub is_direct_evidence: bool,
    /// Optional hint for the oracle on what this route's verdict means.
    pub verdict_hint: String,
}


/// Grace period after time_window_end for late device syncs (24 hours).
pub const SUBMISSION_GRACE_SECS: i64 = 86_400;

/// Minimum allowed min_tag_confidence (50%). Prevents accidentally disabling filtering.
pub const MIN_TAG_CONFIDENCE_FLOOR: u16 = 5000;

impl MarketEvidence {
    pub fn space_for(num_tags: usize, num_routes: usize, route_tag_counts: &[usize],
                     route_uri_lens: &[usize], route_verdict_lens: &[usize],
                     num_notif_domains: usize) -> usize {
        let mut size = 8       // discriminator
        + 32    // market
        // EvidenceRequirements:
        + 8 + 8                         // time_window
        + 1                             // min_submissions
        + 4 + (num_tags * 32)           // required_tags
        + 2                             // min_tag_confidence
        // v3.2 fields:
        + 4;    // pipeline_routes vec prefix
        // Each PipelineRoute: vec_prefix(4) + tags(N*32) + string_prefix(4) + uri
        //   + model_class(1) + priority(1) + is_direct(1) + string_prefix(4) + verdict
        for i in 0..num_routes {
            let n_tags = if i < route_tag_counts.len() { route_tag_counts[i] } else { 0 };
            let uri_len = if i < route_uri_lens.len() { route_uri_lens[i] } else { 0 };
            let verdict_len = if i < route_verdict_lens.len() { route_verdict_lens[i] } else { 0 };
            size += 4 + (n_tags * 32) + 4 + uri_len + 1 + 1 + 1 + 4 + verdict_len;
        }
        size += 4 + (num_notif_domains * 32)  // notification_domains
        + 1                             // resolution_mode
        + 1                             // max_submissions
        + 8                             // resolution_bond
        + 1 + 14                        // Option<JuryConfig>
        + 8                             // oracle_compute_cost
        // end EvidenceRequirements
        + 8     // submission_count
        + 1     // oracle_claimed
        + 1;    // bump
        size
    }
}

// ── EVIDENCE PARAMS (for instruction arguments) ──

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct EvidenceRequirementsParams {
    pub time_window_start: i64,
    pub time_window_end: i64,
    pub min_submissions: u8,
    pub required_tags: Vec<[u8; 32]>,
    pub min_tag_confidence: u16,
    // v3.2
    pub pipeline_routes: Vec<PipelineRouteParams>,
    pub notification_domains: Vec<[u8; 32]>,
    /// Resolution mode — use MODE_* constants (0=EXTERNAL, 1=DEVICE_LOCAL, 2=JURY_ONLY, 3=AI_PLUS_JURY).
    pub resolution_mode: u8,
    /// Hard cap on evidence submissions. 1..=32.
    pub max_submissions: u8,
    /// Resolution bond in lamports. Must be >= RESOLUTION_BOND[mode].
    pub resolution_bond: u64,
    /// Optional jury config. If Some, market supports human jury.
    pub jury_config: Option<JuryConfigParams>,
    /// Estimated oracle compute cost in QD tokens. Set to 0 for legacy behaviour.
    pub oracle_compute_cost: u64,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct JuryConfigParams {
    pub binding: bool,
    pub requires_unanimous: bool,
    pub appeal_cost: u64,
    pub dst_eid: u32,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct PipelineRouteParams {
    pub tags: Vec<[u8; 32]>,
    pub provider_uri: String,
    pub model_class: u8,
    pub priority: u8,
    pub is_direct_evidence: bool,
    pub verdict_hint: String,
}


#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct SubmitEvidenceParams {
    /// SHA256 of the StrongBox-signed feature vector.
    /// Served on-demand by the device via libp2p (/safta/fv/1.0.0).
    pub attestation_hash: [u8; 32],
    /// Ed25519 signature from StrongBox over:
    ///   SHA256(attestation_hash || nonce || market_pubkey)
    /// Verified on-chain via the Ed25519Program instructions sysvar.
    /// The client must include an Ed25519Program instruction immediately
    /// before submit_evidence in the same transaction.
    ///
    /// Replay prevention: nonce is per-(market, device) — the EvidenceSubmission
    /// PDA is seeded with [market, submitter, nonce], so each nonce is consumed
    /// exactly once. time_window_end bounds when submissions are accepted.
    pub strongbox_signature: [u8; 64],
    /// 0=audio, 1=video. Hint for oracle feature schema selection.
    pub content_type: u8,
    /// Allows multiple submissions per device per market (different sessions).
    pub nonce: u8,
}

// ── EVIDENCE EVENTS ──

#[event]
pub struct EvidenceSubmitted {
    pub market: Pubkey,
    pub submitter: Pubkey,
    pub content_type: u8,
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

/*
    Goal: Aggregate probabilistic beliefs into prices
    Method: Maximum entropy + cost function

    C(q) = b·log(Σ exp(qᵢ/b))

    Prices: pᵢ = exp(qᵢ/b) / Z  where Z = Σexp(qⱼ/b)

    This IS a Boltzmann distribution:
    - qᵢ = shares (like energy states)
    - b = liquidity parameter (like temperature kT)
    - pᵢ = probability (price) of outcome i
    - Z = partition function (we don't need this)

    Properties:
    - Σ p_i = 1.0 (prices sum to 1)
    - 0 < p_i < 1 (valid probabilities)
    - ∂p_i/∂q_i = p_i(1-p_i)/b (price sensitivity)
*/
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

// =============================================================================
// ADAPTIVE PARAMETERS
// =============================================================================

/// Theory:
/// - Information arrival rate decreases over time: I(t) = I₀ × exp(-λt)
/// - Early traders have information advantage
/// - Late traders may have better information but less time to profit
/// - Optimal λ balances: early mover advantage vs. late information value
///
/// Derivation from first principles:
/// 1. Define information value decay: V(t) = V₀ × exp(-λt)
/// 2. Total expected information: ∫₀¹ V(t) dt = V₀ × (1 - exp(-λ)) / λ
/// 3. Early trader advantage: A = V(0) / V(1) = exp(λ)
/// 4. Want moderate advantage: 2 ≤ A ≤ 10 (early traders get 2-10x late traders)
///
/// 5. For binary markets:
///    - Information arrives quickly → high λ (≈ 5-10)
///    - Early traders should dominate
///
/// 6. For complex markets (many outcomes):
///    - Information arrives slowly → low λ (≈ 1-3)
///    - Late analysis may be more valuable
///
/// 7. Duration matters:
///    - Short markets: High λ (information decays fast)
///    - Long markets: Low λ (information accumulates)
///
/// Optimal formula derived from maximizing market efficiency:
///    λ* = λ_base × √(num_outcomes) / ln(1 + duration_hours)
///
/// Where:
/// - λ_base depends on market type (prediction, futures, etc.)
/// - √(num_outcomes) captures complexity
/// - ln(1 + duration) captures diminishing returns of time
///

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


/// Theory:
/// - LMSR cost function: C(q) = b × ln(Σ exp(q_i / b))
/// - Market maker subsidizes early trades (creates initial liquidity)
/// - As more traders arrive, market becomes more efficient
/// - Optimal b balances: liquidity provision vs. subsidy cost
///
/// Derivation from first principles:
/// 1. Expected volume V ∝ √(duration) × num_outcomes
/// 2. Price volatility σ ∝ 1/√(num_positions_expected)
/// 3. Optimal liquidity b* minimizes: subsidy_cost + inefficiency_cost
///
///    subsidy_cost(b) = b × ln(n) where n = num_outcomes
///    inefficiency_cost(b) = k × σ² × V / b where k is constant
///
/// 4. Taking derivative and setting to 0:
///    d/db [b × ln(n) + k × σ² × V / b] = 0
///    ln(n) - k × σ² × V / b² = 0
///
/// 5. Solving for b*:
///    b* = √(k × σ² × V / ln(n))
///
/// 6. Substituting empirical values and simplifying:
///    b* = α × √(duration_days) × ⁴√(num_outcomes) × √(expected_volume)
///
/// Where:
/// - α is calibration constant (≈ 1000 from empirical data)
/// - duration_days = market lifetime in days
/// - num_outcomes = number of possible outcomes
/// - expected_volume = E[total capital] ≈ β × duration_days × num_outcomes
///

pub fn calculate_adaptive_liquidity(market: &Market, current_timestamp: i64) -> u64 {
    let initial_liquidity = market.liquidity as f64;
    let age_seconds = current_timestamp.saturating_sub(market.start_time);
    let age_days = ((age_seconds as f64) / 86400.0).max(0.01);

    let time_factor = (1.0 + age_days.ln()).max(1.0);

    let n = market.outcomes.len() as f64;
    const BETA: f64 = 500.0;
    let expected_capital = BETA * n;
    let expected_ctp = expected_capital * age_days;

    let actual_ctp = ((market.total_capital as f64) * age_days / 2.0).max(expected_ctp * 0.1);
    let ctp_ratio = (actual_ctp / expected_ctp).max(0.5).min(10.0);
    let volume_factor = ctp_ratio.powf(0.25);

    let complexity_factor = n.powf(0.25);
    let entropy_factor = 1.0 + (n.ln() / 10.0);

    let liquidity = initial_liquidity * time_factor * volume_factor * complexity_factor * entropy_factor;

    liquidity.max(initial_liquidity).min(initial_liquidity * 10.0) as u64
}

pub fn calculate_time_decay(position_duration: i64,
    market_duration: i64, lambda: u64) -> u64 {
    if market_duration <= 0 { return 10_000; }
    let participation = ((position_duration as u128)
        .saturating_mul(10_000) / (market_duration as u128))
        .min(10_000) as u64;

    if lambda <= 100 { return participation; }

    if lambda <= 200 {
        let t = lambda - 100;
        let linear = participation as u128;
        let quad = (participation as u128)
            .saturating_mul(participation as u128) / 10_000;
        return ((linear.saturating_mul((100 - t) as u128)
            .saturating_add(quad.saturating_mul(t as u128))) / 100) as u64;
    }

    let quad = ((participation as u128)
        .saturating_mul(participation as u128) / 10_000) as u64;
    let cubic = ((quad as u128)
        .saturating_mul(participation as u128) / 10_000) as u64;

    cubic.max(1000)
}

// =============================================================================
// DEVICE ENROLLMENT
// =============================================================================
// At app install time:
//   1. App generates a StrongBox signing key with setAttestationChallenge
//      set to SHA256(config.key() || config_version).
//   2. App submits attestation certificate chain to enroll_device.
//   3. Oracle verifies off-chain: OS version, cert chain, APK signing cert.
//      On-chain: only config_version is checked.
//      Oracle verifies the full chain against Google/GrapheneOS root off-chain.
//   4. DeviceEnrollment PDA created storing device pubkey + cert chain hash.
//
// At evidence submission time:
//   1. StrongBox signs SHA256(attestation_hash || slot || nonce) with enrolled key.
//   2. submit_evidence checks: DeviceEnrollment exists, not revoked,
//      signature verified via Ed25519Program instructions sysvar.
//      Full Ed25519 verification is oracle-side — the on-chain guard is the
//      DeviceEnrollment PDA constraints, not the signature itself.
//
// APK identity is bound at key generation:
//   The attestation certificate's attestApplicationId extension contains the
//   APK signing certificate recorded by the OS (not the app) at key gen time.
//   Hardware-reported, not self-reported.
//
// Seeds: [b"device_enrollment", device_pubkey.as_ref()]


#[account]
pub struct DeviceEnrollment {
    /// Ed25519 pubkey generated in StrongBox at app install time.
    /// All submit_evidence calls must carry a StrongBox signature
    /// verifiable against this key.
    ///
    /// The oracle verifies off-chain at enrollment time:
    ///   verifiedBootState = VERIFIED  — locked bootloader, unmodified OS
    ///   osVersion >= minimum          — StrongBox API availability
    ///   apk_cert_hash matches expected — hardware-reported APK signing cert
    ///     (OS writes this into attestApplicationId at key generation time;
    ///      a bootlegged APK signed with a different key produces a different hash)
    ///
    /// On-chain the PDA exists only to record that the oracle accepted this
    /// device_pubkey, and to allow revocation. Nothing else is stored because
    /// nothing else needs to be re-checked on-chain after enrollment.
    pub device_pubkey: Pubkey,

    pub revoked: bool, // admin or device owner can revoke; blocks submit_evidence immediately
    pub bump: u8,
}

impl DeviceEnrollment {
    pub const SPACE: usize = 8
        + 32  // device_pubkey
        + 1   // revoked
        + 1;  // bump  → 42 bytes
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct EnrollDeviceParams {
    /// StrongBox-generated Ed25519 pubkey for this device.
    pub device_pubkey: Pubkey,
}
