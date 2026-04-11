/**
 * QU!D Protocol — Solana Prediction Market Keeper
 *
 * Post-resolution lifecycle automation:
 *   1. Scan Market PDAs → find resolved markets needing processing
 *   2. Auto-reveal: fetch confidences from MongoDB → call `reveal` (batch_reveal)
 *      as delegate for each unrevealed position
 *   3. Calculate weights: after reveal window, call `weigh` (calculate_weights)
 *      with batches of position accounts
 *   4. Push payouts: after weights complete, call `payout` (push_payouts)
 *      with [position, depositor] pairs
 *
 * Also handles:
 *   - resolve_market: permissionless call after deadline (reads Switchboard feed)
 *   - Market state monitoring and logging
 *
 * MongoDB integration:
 *   Same /api/confidences endpoint as EVM keeper. Frontend POSTs confidences
 *   with Solana chainId (900/901/902). This keeper GETs them and calls
 *   batch_reveal as the user's reveal_delegate.
 *
 * Instruction names (lib.rs → Anchor discriminators):
 *   resolve     → sha256("global:resolve")[0..8]
 *   reveal      → sha256("global:reveal")[0..8]
 *   weigh       → sha256("global:weigh")[0..8]
 *   payout      → sha256("global:payout")[0..8]
 *
 * Run: import and call startPredictionKeeper() from keeper_solana.ts
 */

import {
  Connection, Keypair, PublicKey, TransactionInstruction,
  Transaction, sendAndConfirmTransaction, SystemProgram,
} from '@solana/web3.js'
import { createHash } from 'crypto'

// ═══════════════════════════════════════════════════════════════════════════
// CONFIG (shares with keeper_solana.ts)
// ═══════════════════════════════════════════════════════════════════════════

const PM_CONFIG = {
  PROGRAM_ID: process.env.SOLANA_PROGRAM_ID || 'A1C96iUwFzpuaLBQX1AmfKwsisbC99cvGVnteHX6gJi9',
  RPC: process.env.SOLANA_RPC || 'http://127.0.0.1:8899',
  NETWORK: (process.env.SOLANA_NETWORK || 'localnet') as 'localnet' | 'devnet' | 'mainnet',
  TOKEN_MINT: process.env.SOLANA_TOKEN_MINT || '',
  MONGODB_API: process.env.MONGODB_API || 'http://localhost:3000',
  SOLANA_CHAIN_ID: Number(process.env.SOLANA_CHAIN_ID) || 900,
  CHECK_INTERVAL: Number(process.env.PM_CHECK_INTERVAL) || 60_000, // 1 min
  BATCH_SIZE: 8,       // max positions per tx (account limit)
  REVEAL_WINDOW: 24 * 60 * 60, // 24h
}

// ═══════════════════════════════════════════════════════════════════════════
// ANCHOR HELPERS
// ═══════════════════════════════════════════════════════════════════════════

function ixDisc(name: string): Buffer {
  return createHash('sha256').update(`global:${name}`).digest().subarray(0, 8)
}

function acctDisc(name: string): Buffer {
  return createHash('sha256').update(`account:${name}`).digest().subarray(0, 8)
}

function borshString(s: string): Buffer {
  const bytes = Buffer.from(s, 'utf-8')
  const len = Buffer.alloc(4)
  len.writeUInt32LE(bytes.length, 0)
  return Buffer.concat([len, bytes])
}

function borshU64(n: bigint): Buffer {
  const buf = Buffer.alloc(8)
  buf.writeBigUInt64LE(n, 0)
  return buf
}

function findPDA(programId: PublicKey, seeds: (Buffer | Uint8Array)[]): PublicKey {
  return PublicKey.findProgramAddressSync(seeds, programId)[0]
}

// ═══════════════════════════════════════════════════════════════════════════
// MARKET STATE PARSING
// ═══════════════════════════════════════════════════════════════════════════

type MarketState = 'Trading' | 'AwaitingResolution' | 'Challenged' | 'Settling' | 'PushingPayouts' | 'Finalized' | 'Cancelled'

interface MarketData {
  pda: PublicKey
  marketId: bigint
  creator: PublicKey
  numOutcomes: number
  sbFeed: PublicKey
  deadline: bigint
  resolved: boolean
  cancelled: boolean
  winningOutcome: number
  resolutionTime: bigint
  challenged: boolean
  positionsRevealed: bigint
  positionsTotal: bigint
  positionsProcessed: bigint
  weightsComplete: boolean
  payoutsComplete: boolean
  state: MarketState
}

interface PositionData {
  pda: PublicKey
  market: PublicKey
  user: PublicKey
  outcome: number
  totalCapital: bigint
  totalTokens: bigint
  revealedConfidence: bigint
  weight: bigint
  numEntries: number
  revealDelegate: PublicKey | null
}

function getMarketState(m: {
  cancelled: boolean; payoutsComplete: boolean; weightsComplete: boolean;
  resolved: boolean; challenged: boolean; deadline: bigint;
}, now: number): MarketState {
  if (m.cancelled) return 'Cancelled'
  if (m.payoutsComplete) return 'Finalized'
  if (m.weightsComplete) return 'PushingPayouts'
  if (m.resolved && !m.challenged) return 'Settling'
  if (m.challenged) return 'Challenged'
  if (now >= Number(m.deadline)) return 'AwaitingResolution'
  return 'Trading'
}

// Partial Market parse — we only need the fields relevant to keeper logic
// Full struct is complex with variable-length strings; we read fixed-offset fields
function parseMarket(pda: PublicKey, data: Buffer): MarketData | null {
  if (data.length < 200) return null
  try {
    // disc(8) + market_id(8) + creator(32) + question(4+len) + ...
    const marketId = data.readBigUInt64LE(8)
    const creator = new PublicKey(data.subarray(16, 48))

    // Variable-length strings make parsing tricky. Read string lengths to skip.
    let offset = 48

    // question: borsh string
    const qLen = data.readUInt32LE(offset); offset += 4 + qLen
    // context: borsh string
    const cLen = data.readUInt32LE(offset); offset += 4 + cLen
    // exculpatory: borsh string
    const eLen = data.readUInt32LE(offset); offset += 4 + eLen
    // resolution_source: borsh string
    const rLen = data.readUInt32LE(offset); offset += 4 + rLen

    // outcomes: Vec<String>
    const numOutcomes = data.readUInt32LE(offset); offset += 4
    for (let i = 0; i < numOutcomes; i++) {
      const oLen = data.readUInt32LE(offset); offset += 4 + oLen
    }
    // num_outcomes: u8
    const numOutcomesU8 = data.readUInt8(offset); offset += 1

    // sb_feed: Pubkey(32)
    const sbFeed = new PublicKey(data.subarray(offset, offset + 32)); offset += 32

    // start_time: i64
    offset += 8 // skip
    // deadline: i64
    const deadline = data.readBigInt64LE(offset); offset += 8

    // liquidity: u64
    offset += 8

    // tokens_sold_per_outcome: Vec<u64>
    const tspLen = data.readUInt32LE(offset); offset += 4 + tspLen * 8

    // total_capital: u64
    offset += 8
    // total_capital_per_outcome: Vec<u64>
    const tcpLen = data.readUInt32LE(offset); offset += 4 + tcpLen * 8
    // fees_collected: u64
    offset += 8

    // creator_bond_lamports: u64
    offset += 8
    // sol_vault_bump: u8
    offset += 1

    // resolved: bool
    const resolved = data.readUInt8(offset) !== 0; offset += 1
    // cancelled: bool
    const cancelled = data.readUInt8(offset) !== 0; offset += 1
    // winning_outcome: u8
    const winningOutcome = data.readUInt8(offset); offset += 1
    // resolution_confidence: u64
    offset += 8
    // resolution_time: i64
    const resolutionTime = data.readBigInt64LE(offset); offset += 8

    // challenge_count: u8
    offset += 1
    // challenged: bool
    const challenged = data.readUInt8(offset) !== 0; offset += 1

    // positions_revealed: u64
    const positionsRevealed = data.readBigUInt64LE(offset); offset += 8
    // positions_total: u64
    const positionsTotal = data.readBigUInt64LE(offset); offset += 8
    // positions_processed: u64
    const positionsProcessed = data.readBigUInt64LE(offset); offset += 8

    // total_winner_weight_revealed: u128
    offset += 16
    // total_loser_weight_revealed: u128
    offset += 16
    // total_winner_capital_revealed: u64
    offset += 8
    // total_loser_capital_revealed: u64
    offset += 8

    // weights_complete: bool
    const weightsComplete = data.readUInt8(offset) !== 0; offset += 1
    // payouts_complete: bool
    const payoutsComplete = data.readUInt8(offset) !== 0; offset += 1

    const now = Math.floor(Date.now() / 1000)
    return {
      pda, marketId, creator, numOutcomes: numOutcomesU8, sbFeed,
      deadline: BigInt(deadline),
      resolved, cancelled, winningOutcome,
      resolutionTime: BigInt(resolutionTime),
      challenged, positionsRevealed, positionsTotal, positionsProcessed,
      weightsComplete, payoutsComplete,
      state: getMarketState({ cancelled, payoutsComplete, weightsComplete, resolved, challenged, deadline: BigInt(deadline) }, now),
    }
  } catch (e: any) {
    console.error('❌ Market parse error:', e.message?.slice(0, 80))
    return null
  }
}

// Position parse — fixed-size struct
function parsePosition(pda: PublicKey, data: Buffer): PositionData | null {
  if (data.length < 100) return null
  try {
    // disc(8) + market(32) + user(32) + outcome(1) + total_capital(8) +
    // total_tokens(8) + total_capital_seconds(16) + vec_len(4) + entries(var) + ...
    const market = new PublicKey(data.subarray(8, 40))
    const user = new PublicKey(data.subarray(40, 72))
    const outcome = data.readUInt8(72)
    const totalCapital = data.readBigUInt64LE(73)
    const totalTokens = data.readBigUInt64LE(81)

    // total_capital_seconds: u128
    let offset = 89 + 16 // skip tcs
    // entries Vec<PositionEntry> — each entry is 80 bytes
    const numEntries = data.readUInt32LE(offset); offset += 4
    offset += numEntries * 80 // skip entries

    // revealed_confidence: u64
    const revealedConfidence = data.readBigUInt64LE(offset); offset += 8
    // accuracy_percentile: u64
    offset += 8
    // weight: u128
    const weight = data.readBigUInt64LE(offset) // read lower 64 bits only
    offset += 16
    // reveal_delegate: Option<Pubkey>
    const hasDelegate = data.readUInt8(offset); offset += 1
    const revealDelegate = hasDelegate ? new PublicKey(data.subarray(offset, offset + 32)) : null

    return {
      pda, market, user, outcome, totalCapital, totalTokens,
      revealedConfidence, weight, numEntries, revealDelegate,
    }
  } catch { return null }
}

// ═══════════════════════════════════════════════════════════════════════════
// PREDICTION MARKET KEEPER
// ═══════════════════════════════════════════════════════════════════════════

export class PredictionMarketKeeper {
  private conn: Connection
  private programId: PublicKey
  private wallet: Keypair | null = null
  private isRunning = false
  private marketDisc: Buffer
  private positionDisc: Buffer

  constructor(conn?: Connection, wallet?: Keypair) {
    this.conn = conn || new Connection(PM_CONFIG.RPC, 'confirmed')
    this.programId = new PublicKey(PM_CONFIG.PROGRAM_ID)
    this.wallet = wallet || null
    this.marketDisc = acctDisc('Market')
    this.positionDisc = acctDisc('Position')
    console.log('🔮 Prediction Market Keeper initializing...')
  }

  setWallet(kp: Keypair) { this.wallet = kp }

  // ── Market Discovery ────────────────────────────────────────────────

  async scanMarkets(): Promise<MarketData[]> {
    try {
      const accounts = await this.conn.getProgramAccounts(this.programId, {
        filters: [{ memcmp: { offset: 0, bytes: this.marketDisc.toString('base64') } }],
      })
      const markets: MarketData[] = []
      for (const { pubkey, account } of accounts) {
        const m = parseMarket(pubkey, Buffer.from(account.data))
        if (m) markets.push(m)
      }
      return markets
    } catch (e: any) {
      console.error('❌ scanMarkets:', e.message?.slice(0, 100))
      return []
    }
  }

  async scanPositionsForMarket(marketPda: PublicKey): Promise<PositionData[]> {
    try {
      const accounts = await this.conn.getProgramAccounts(this.programId, {
        filters: [
          { memcmp: { offset: 0, bytes: this.positionDisc.toString('base64') } },
          // market pubkey at offset 8
          { memcmp: { offset: 8, bytes: marketPda.toBase58() } },
        ],
      })
      const positions: PositionData[] = []
      for (const { pubkey, account } of accounts) {
        const p = parsePosition(pubkey, Buffer.from(account.data))
        if (p && p.totalCapital > 0n) positions.push(p)
      }
      return positions
    } catch (e: any) {
      console.error('❌ scanPositions:', e.message?.slice(0, 100))
      return []
    }
  }

  // ── Phase 1: Auto-Reveal ────────────────────────────────────────────
  // After market.resolved, fetch confidences from MongoDB for positions
  // where we are the reveal_delegate, then call `reveal` (batch_reveal)

  async autoReveal(market: MarketData): Promise<number> {
    if (!this.wallet) return 0
    if (!market.resolved || market.cancelled) return 0
    if (market.weightsComplete) return 0

    const positions = await this.scanPositionsForMarket(market.pda)
    const unrevealed = positions.filter(p =>
      p.revealedConfidence === 0n && p.totalCapital > 0n &&
      (p.user.equals(this.wallet!.publicKey) ||
       (p.revealDelegate && p.revealDelegate.equals(this.wallet!.publicKey)))
    )

    if (!unrevealed.length) return 0

    // Fetch confidences from MongoDB
    let dbConfs: Array<{
      user: string; side: number; confidence: number; salt: string; commitHash: string
    }> = []
    try {
      const resp = await fetch(
        `${PM_CONFIG.MONGODB_API}/api/confidences?mktId=${market.marketId}&chainId=${PM_CONFIG.SOLANA_CHAIN_ID}`
      )
      if (resp.ok) {
        const data = await resp.json()
        dbConfs = data.confidences || []
      }
    } catch (e) {
      console.warn('⚠️ MongoDB fetch failed:', e)
      return 0
    }

    if (!dbConfs.length) {
      console.log(`ℹ️ Market #${market.marketId}: no confidences in DB to reveal`)
      return 0
    }

    // Group by user+outcome
    const confMap = new Map<string, Array<{ confidence: number; salt: string }>>()
    for (const conf of dbConfs) {
      const key = `${conf.user}-${conf.side}`
      if (!confMap.has(key)) confMap.set(key, [])
      confMap.get(key)!.push({ confidence: conf.confidence, salt: conf.salt })
    }

    let revealCount = 0
    const accuracyBuckets = findPDA(this.programId, [
      Buffer.from('accuracy_buckets'), Buffer.from(market.marketId.toString())
    ])

    // Batch reveals (max BATCH_SIZE positions per tx)
    for (let batch = 0; batch < unrevealed.length; batch += PM_CONFIG.BATCH_SIZE) {
      const batchPositions = unrevealed.slice(batch, batch + PM_CONFIG.BATCH_SIZE)
      const batchReveals: Buffer[] = [] // Vec<Vec<RevealEntry>> encoded
      const remainingAccounts: PublicKey[] = []
      const validPositions: PositionData[] = []

      for (const pos of batchPositions) {
        const key = `${pos.user.toBase58()}-${pos.outcome}`
        const reveals = confMap.get(key)
        if (!reveals || reveals.length !== pos.numEntries) continue

        validPositions.push(pos)
        remainingAccounts.push(pos.pda)

        // Encode Vec<RevealEntry>: each is confidence(u64) + salt([u8;32])
        const entries: Buffer[] = []
        for (const r of reveals) {
          entries.push(borshU64(BigInt(r.confidence)))
          entries.push(Buffer.from(r.salt, 'hex').subarray(0, 32))
        }
        batchReveals.push(Buffer.concat(entries))
      }

      if (!validPositions.length) continue

      try {
        // Encode reveals: Vec<Vec<RevealEntry>>
        // outer vec len + for each: inner vec len + entries
        const outerLen = Buffer.alloc(4)
        outerLen.writeUInt32LE(validPositions.length, 0)
        const revealParts: Buffer[] = [outerLen]

        for (let i = 0; i < validPositions.length; i++) {
          const innerLen = Buffer.alloc(4)
          innerLen.writeUInt32LE(validPositions[i].numEntries, 0)
          revealParts.push(innerLen)
          revealParts.push(batchReveals[i])
        }

        // market_id bytes for PDA derivation (first 6 bytes of LE u64)
        const mktIdBuf = Buffer.alloc(8)
        mktIdBuf.writeBigUInt64LE(market.marketId, 0)

        const accuracyPda = findPDA(this.programId, [
          Buffer.from('accuracy_buckets'), mktIdBuf.subarray(0, 6)
        ])

        const ix = new TransactionInstruction({
          keys: [
            { pubkey: market.pda,            isSigner: false, isWritable: true },
            { pubkey: accuracyPda,           isSigner: false, isWritable: true },
            { pubkey: this.wallet.publicKey,  isSigner: true,  isWritable: false },
            ...remainingAccounts.map(pk => ({ pubkey: pk, isSigner: false, isWritable: true })),
          ],
          programId: this.programId,
          data: Buffer.concat([ixDisc('reveal'), ...revealParts]),
        })

        const tx = new Transaction().add(ix)
        const sig = await sendAndConfirmTransaction(this.conn, tx, [this.wallet])
        console.log(`🔓 Revealed ${validPositions.length} positions for market #${market.marketId}: ${sig}`)
        revealCount += validPositions.length
      } catch (e: any) {
        console.error(`❌ Reveal batch failed:`, e.message?.slice(0, 120))
      }
    }

    return revealCount
  }

  // ── Phase 2: Calculate Weights ──────────────────────────────────────
  // After reveal window closes (or all revealed), call `weigh`

  async calculateWeights(market: MarketData): Promise<number> {
    if (!this.wallet) return 0
    if (!market.resolved || market.cancelled || market.weightsComplete) return 0

    const now = Math.floor(Date.now() / 1000)
    const revealDeadline = Number(market.resolutionTime) + PM_CONFIG.REVEAL_WINDOW
    const allRevealed = market.positionsRevealed >= market.positionsTotal

    if (now < revealDeadline && !allRevealed) {
      console.log(`⏳ Market #${market.marketId}: reveal window open until ${new Date(revealDeadline * 1000).toISOString()}`)
      return 0
    }

    const positions = await this.scanPositionsForMarket(market.pda)
    // Filter to unweighed positions (weight == 0, total_capital > 0)
    const unweighed = positions.filter(p => p.weight === 0n && p.totalCapital > 0n)
    if (!unweighed.length) return 0

    let weightCount = 0
    const mktIdBuf = Buffer.alloc(8)
    mktIdBuf.writeBigUInt64LE(market.marketId, 0)

    const accuracyPda = findPDA(this.programId, [
      Buffer.from('accuracy_buckets'), mktIdBuf.subarray(0, 6)
    ])
    const bank = findPDA(this.programId, [Buffer.from('depository')])
    const keeperDep = findPDA(this.programId, [this.wallet.publicKey.toBuffer()])

    for (let batch = 0; batch < unweighed.length; batch += PM_CONFIG.BATCH_SIZE) {
      const batchPositions = unweighed.slice(batch, batch + PM_CONFIG.BATCH_SIZE)

      try {
        const ix = new TransactionInstruction({
          keys: [
            { pubkey: market.pda,            isSigner: false, isWritable: true },
            { pubkey: accuracyPda,           isSigner: false, isWritable: true },
            { pubkey: bank,                  isSigner: false, isWritable: true },
            { pubkey: keeperDep,             isSigner: false, isWritable: true },
            { pubkey: this.wallet.publicKey,  isSigner: true,  isWritable: true },
            { pubkey: SystemProgram.programId, isSigner: false, isWritable: false },
            ...batchPositions.map(p => ({ pubkey: p.pda, isSigner: false, isWritable: true })),
          ],
          programId: this.programId,
          data: ixDisc('weigh'),
        })

        const tx = new Transaction().add(ix)
        const sig = await sendAndConfirmTransaction(this.conn, tx, [this.wallet])
        console.log(`⚖️ Weighed ${batchPositions.length} positions for market #${market.marketId}: ${sig}`)
        weightCount += batchPositions.length
      } catch (e: any) {
        const msg = e.message || ''
        if (msg.includes('AlreadyComplete')) break
        console.error(`❌ Weigh batch failed:`, msg.slice(0, 120))
      }
    }

    return weightCount
  }

  // ── Phase 3: Push Payouts ───────────────────────────────────────────
  // After weights complete, send payouts in [position, depositor] pairs

  async pushPayouts(market: MarketData): Promise<number> {
    if (!this.wallet) return 0
    if (!market.weightsComplete && !market.cancelled) return 0
    if (market.payoutsComplete) return 0

    const positions = await this.scanPositionsForMarket(market.pda)
    // All positions that still have capital (not yet paid)
    const unpaid = positions.filter(p => p.totalCapital > 0n)
    if (!unpaid.length) return 0

    const bank = findPDA(this.programId, [Buffer.from('depository')])
    const creatorDep = findPDA(this.programId, [market.creator.toBuffer()])
    const keeperDep = findPDA(this.programId, [this.wallet.publicKey.toBuffer()])

    const mktIdBuf = Buffer.alloc(8)
    mktIdBuf.writeBigUInt64LE(market.marketId, 0)
    const solVault = findPDA(this.programId, [Buffer.from('sol_vault'), mktIdBuf.subarray(0, 6)])

    let payoutCount = 0
    // Halve batch size since each position needs 2 accounts (position + depositor)
    const batchSize = Math.floor(PM_CONFIG.BATCH_SIZE / 2)

    for (let batch = 0; batch < unpaid.length; batch += batchSize) {
      const batchPositions = unpaid.slice(batch, batch + batchSize)
      const remainingAccounts: { pubkey: PublicKey; isSigner: boolean; isWritable: boolean }[] = []

      for (const pos of batchPositions) {
        const depositorPda = findPDA(this.programId, [pos.user.toBuffer()])
        remainingAccounts.push({ pubkey: pos.pda, isSigner: false, isWritable: true })
        remainingAccounts.push({ pubkey: depositorPda, isSigner: false, isWritable: true })
      }

      try {
        const ix = new TransactionInstruction({
          keys: [
            { pubkey: market.pda,            isSigner: false, isWritable: true },
            { pubkey: bank,                  isSigner: false, isWritable: true },
            { pubkey: creatorDep,            isSigner: false, isWritable: true },
            { pubkey: solVault,              isSigner: false, isWritable: true },
            { pubkey: market.creator,        isSigner: false, isWritable: true },
            { pubkey: keeperDep,             isSigner: false, isWritable: true },
            { pubkey: this.wallet.publicKey,  isSigner: true,  isWritable: true },
            { pubkey: SystemProgram.programId, isSigner: false, isWritable: false },
            ...remainingAccounts,
          ],
          programId: this.programId,
          data: ixDisc('payout'),
        })

        const tx = new Transaction().add(ix)
        const sig = await sendAndConfirmTransaction(this.conn, tx, [this.wallet])
        console.log(`💰 Paid ${batchPositions.length} positions for market #${market.marketId}: ${sig}`)
        payoutCount += batchPositions.length
      } catch (e: any) {
        const msg = e.message || ''
        if (msg.includes('AlreadyComplete')) break
        console.error(`❌ Payout batch failed:`, msg.slice(0, 120))
      }
    }

    return payoutCount
  }

  // ── Phase 0: Resolve Market (permissionless) ────────────────────────
  // After deadline, anyone can call resolve to read the Switchboard feed

  async tryResolve(market: MarketData): Promise<boolean> {
    if (!this.wallet) return false
    if (market.resolved || market.cancelled || market.challenged) return false

    const now = Math.floor(Date.now() / 1000)
    if (now < Number(market.deadline)) return false

    const configPda = findPDA(this.programId, [Buffer.from('program_config')])

    try {
      const ix = new TransactionInstruction({
        keys: [
          { pubkey: market.pda,            isSigner: false, isWritable: true },
          { pubkey: configPda,             isSigner: false, isWritable: false },
          { pubkey: this.wallet.publicKey,  isSigner: true,  isWritable: false },
          // remaining_accounts[0] = sb_feed
          { pubkey: market.sbFeed,         isSigner: false, isWritable: false },
        ],
        programId: this.programId,
        data: ixDisc('resolve'),
      })

      const tx = new Transaction().add(ix)
      const sig = await sendAndConfirmTransaction(this.conn, tx, [this.wallet])
      console.log(`✅ Resolved market #${market.marketId}: ${sig}`)
      return true
    } catch (e: any) {
      const msg = e.message || ''
      if (msg.includes('AlreadyComplete')) return false
      if (msg.includes('InsufficientConfidence')) {
        console.log(`⏳ Market #${market.marketId}: oracle confidence too low, retry later`)
        return false
      }
      console.error(`❌ Resolve market #${market.marketId}:`, msg.slice(0, 120))
      return false
    }
  }

  // ── Main Loop ───────────────────────────────────────────────────────

  async sweep(): Promise<void> {
    if (!this.wallet) return

    const markets = await this.scanMarkets()
    if (!markets.length) return

    for (const market of markets) {
      switch (market.state) {
        case 'Trading':
          // Nothing to do
          break

        case 'AwaitingResolution':
          console.log(`📋 Market #${market.marketId}: past deadline, attempting resolve...`)
          await this.tryResolve(market)
          break

        case 'Settling': {
          // Phase 1: reveal unrevealed positions
          const revealed = await this.autoReveal(market)
          if (revealed > 0) console.log(`   Revealed ${revealed} positions`)

          // Phase 2: calculate weights (if reveal window closed)
          const weighed = await this.calculateWeights(market)
          if (weighed > 0) console.log(`   Weighed ${weighed} positions`)
          break
        }

        case 'PushingPayouts': {
          // Phase 3: push payouts
          const paid = await this.pushPayouts(market)
          if (paid > 0) console.log(`   Paid ${paid} positions`)
          break
        }

        case 'Challenged':
          console.log(`🔒 Market #${market.marketId}: challenged, waiting for resolution`)
          break

        case 'Finalized':
        case 'Cancelled':
          // Done
          break
      }
    }
  }

  async start(): Promise<void> {
    this.isRunning = true
    console.log(`\n🔮 Prediction Market Keeper started — interval ${PM_CONFIG.CHECK_INTERVAL / 1000}s\n`)
    while (this.isRunning) {
      try { await this.sweep() }
      catch (e: any) { console.error('❌ PM sweep error:', e.message?.slice(0, 120)) }
      await new Promise(r => setTimeout(r, PM_CONFIG.CHECK_INTERVAL))
    }
  }

  stop() { this.isRunning = false; console.log('🛑 Prediction Market Keeper stopping') }
}

// ═══════════════════════════════════════════════════════════════════════════
// STANDALONE ENTRYPOINT
// ═══════════════════════════════════════════════════════════════════════════

export async function startPredictionKeeper(conn?: Connection, wallet?: Keypair) {
  const keeper = new PredictionMarketKeeper(conn, wallet)

  if (!wallet && process.env.SOLANA_KEEPER_KEY) {
    try {
      const arr = JSON.parse(process.env.SOLANA_KEEPER_KEY)
      keeper.setWallet(Keypair.fromSecretKey(Uint8Array.from(arr)))
    } catch {
      try {
        const bs58 = await import('bs58')
        keeper.setWallet(Keypair.fromSecretKey(bs58.default.decode(process.env.SOLANA_KEEPER_KEY)))
      } catch { console.warn('⚠️ Could not parse SOLANA_KEEPER_KEY for PM keeper') }
    }
  }

  return keeper
}

if (require.main === module) {
  startPredictionKeeper().then(k => {
    process.on('SIGINT', () => { k.stop(); process.exit(0) })
    process.on('SIGTERM', () => { k.stop(); process.exit(0) })
    k.start().catch(console.error)
  })
}
