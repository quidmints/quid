/**
 * QU!D Protocol — Solana Keeper Extension
 *
 * Monitors leveraged stock-exposure positions (Depositor.balances)
 * and calls the `liquidate` instruction when collar constraints are breached.
 *
 * Architecture:
 *   1. Scan all Depositor PDAs via getProgramAccounts
 *   2. For each Stock in depositor.balances, fetch Pyth price
 *   3. Detect collar breach (over-profitable or under-exposed)
 *   4. Build and send `liquidate(ticker)` instruction
 *      — remaining_accounts = [ticker pyth, ...other position pyths]
 *      — The program internally calls repo(ticker, 0, price, ...) which
 *        triggers gradual amortization when MAX_AGE has elapsed
 *
 * Instruction flow:
 *   lib.rs::liquidate(ticker) → clutch.rs::amortise(ticker) → stay.rs::repo(t, 0, ...)
 *
 * The keeper earns a 0.4% (1/250) commission on each successful liquidation.
 *
 * Environment:
 *   SOLANA_RPC              — RPC endpoint (default: http://127.0.0.1:8899)
 *   SOLANA_NETWORK          — localnet | devnet | mainnet (default: localnet)
 *   SOLANA_KEEPER_KEY       — Base58 or JSON array secret key
 *   SOLANA_TOKEN_MINT       — QD SPL token mint address
 *   SOLANA_CHECK_INTERVAL   — Scan interval in ms (default: 30000)
 *
 * Run: npx ts-node keeper_solana.ts
 */

import {
  Connection, Keypair, PublicKey, TransactionInstruction,
  Transaction, sendAndConfirmTransaction, SystemProgram,
} from '@solana/web3.js'
import { createHash } from 'crypto'

// ═══════════════════════════════════════════════════════════════════════════
// CONFIG
// ═══════════════════════════════════════════════════════════════════════════

const CONFIG = {
  PROGRAM_ID: 'A1C96iUwFzpuaLBQX1AmfKwsisbC99cvGVnteHX6gJi9',
  RPC: process.env.SOLANA_RPC || 'http://127.0.0.1:8899',
  NETWORK: (process.env.SOLANA_NETWORK || 'localnet') as 'localnet' | 'devnet' | 'mainnet',
  KEEPER_KEY: process.env.SOLANA_KEEPER_KEY || '',
  TOKEN_MINT: process.env.SOLANA_TOKEN_MINT || '',
  CHECK_INTERVAL: Number(process.env.SOLANA_CHECK_INTERVAL) || 30_000,
  HERMES_URL: 'https://hermes.pyth.network',
}

// ═══════════════════════════════════════════════════════════════════════════
// PYTH MAPPINGS — mirrors etc.rs {CRYPTO,METALS,...}_ACCOUNT_MAP / HEX_MAP
// ═══════════════════════════════════════════════════════════════════════════

// Pyth receiver PDA addresses (on-chain accounts the program reads from)
const PYTH_ACCOUNTS: Record<string, string> = {
  // Crypto
  BTC:  '4cSM2e6rvbGQUFiJbqytoVMi5GgghSMr8LwVrT9VPSPo',
  ETH:  '42amVS4KgzR9rA28tkVYqVXjq9Qa8dcZQMbH5EYFX6XC',
  SOL:  '7UVimffxr9ow1uXYxsr4LHAcV58mLzhmwaeKvJ1pjLiE',
  AVAX: 'Ax9ujW5B9oqcv59N8m6f1BpTBq2rGeGaBcpKjC5UYsXU',
  ARB:  '36bVFS7FX2o7caSNorrrxNhgEE9cKxyho4YZ1EcMPnAU',
  LINK: 'AL53iGUCBjWD4oUHKVXRQaagfNSRn8mNHbLHR9iJB8Ho',
  UNI:  '5TvMFR6VxVjibmFHGUd2WA6RnDQavF3y2K4c7QYjNJLo',
  DOGE: '4L6YhY8VvUgmqG5MvJkUJATtzB2rFqdrJwQCmFLv4Jzy',
  // Metals
  XAU:  '2uPQGpm8X4ZkxMHxrAW1QuhXcse1AHEgPih6Xp9NuEWW',
  XAG:  'H9JxsWwtDZxjSL6m7cdCVsWibj3JBMD9sxqLjadoZnot',
  XPT:  '3cqhrj49qGbSfvaWCRCsTE9314NUKuUwM1REkiS2dRKe',
  XPD:  'FBy4Q8ezfPhUpz9T7dHDMvq99xo843EUjmW9j7HdSubw',
  // Commodities
  USOIL: '4LPPjSGx5s3fvANM78zVhVFhEUQSJGHc1PUFKRjR76sX',
  UKOIL: '2w9jhzYm9puy47VTNUpAhpVdSZyGSQUq7u7JVmJJ7TVc',
  // Rates
  US10Y: '3NaLNXNAJgFK2eCe5nCFBugKSMVJXzDBweHqh5mdYBRB',
  US2Y:  '7PRCyJ1rPAUTW9N6Fd6oUXE5zjvapAk5VHJtdmEi3Yrp',
  US5Y:  'EdUZZqsRp3q42UYHZLwuL376CvDEp2wPL9hFq4HX3Dre',
  US30Y: '94woK2CUvgZadCoiriEhMT5ctqBRGigyPMwceTCEthi6',
  SOFR:  '6QWz4yTU2qZJfjH2CbVThCG5Y3j4YCngh5EBeGyCjLER',
  EFFR:  '2g79DLRiuSJM75f6wbiqryA55CU7ZZYTnocbfeJUAJjw',
  // Equities (sample — full set in etc.rs)
  AAPL: 'E6xSTR4pFCE3FMfQLR4gxMHWzg7Ee4HSGML2JMxfb4im',
  MSFT: 'FRELmTrwmE2g8j38Ld7aL3PCMjzTFjb8FJL8WPRd5qtw',
  NVDA: 'DW1k1kkMKJ1HcJKy7nnp7BhF4CFrRNB7X6LCexLcqPzb',
  TSLA: 'DUEvNdLPaHc1K9LHquyVu7Gy3YehdRPQtZEJRN9TCMYL',
  AMZN: '4yTpQpPLV85xYnD8Rz7KxDeKi8Wuoek3Jn8sMWK6cvAJ',
  GOOG: 'JAvDAFnLBX23ihbVhpEMJNFEaKdfGHscKNR9a6AvA4Kd',
}

// Pyth feed hex IDs for Hermes API (devnet/mainnet)
const PYTH_HEX: Record<string, string> = {
  BTC:  '0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43',
  ETH:  '0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace',
  SOL:  '0xef0d8b6fda2ceba41da15d4095d1da392a0d2f8ed0c6c7bc0f4cfac8c280b56d',
  XAU:  '0x765d2ba906dbc32ca17cc11f5310a89e9ee1f6420508c63861f2f8ba4ee34bb2',
  XAG:  '0xf2fb02c32b055c805e7238d628e5e9dadef274376114eb1f012337cabe93871e',
  XPT:  '0x398e4bbc7cbf89d6648c21e08019d878967677753b3096799595c78f805a34e5',
  XPD:  '0x80367e9664197f37d89a07a804dffd2101c479c7c4e8490501bc9d9e1e7f9021',
  USOIL: '0x925ca92ff005ae943c158e3563f59698ce7e75c5a8c8dd43303a0a154887b3e6',
  UKOIL: '0x27f0d5e09a830083e5491795cac9ca521399c8f7fd56240d09484b14e614d57a',
  US10Y: '0x9c196541230ba421baa2a499214564312a46bb47fb6b61ef63db2f70d3ce34c1',
  SOFR:  '0x0f5fd558019a7cad9eaa012cd7228c65f2b7ed31db3f66ec557087a769df0f67',
  AAPL:  '0x49f6b65cb1de6b10eaf75e7c03ca029c306d0357e91b5311b175084a5ad55688',
  NVDA:  '0x4bde77db39dc1e91dfe5f835ba7e49a13a1a95a181a4f6dccece86a9e9f8aeec',
  TSLA:  '0x16dad506d7db8da01c87581c87ca897a012a153557d4d578c3b9c9e1bc0632f1',
}

// ═══════════════════════════════════════════════════════════════════════════
// SERIALIZATION — Anchor discriminators + Borsh encoding
// ═══════════════════════════════════════════════════════════════════════════

function ixDisc(name: string): Buffer {
  return createHash('sha256').update(`global:${name}`).digest().subarray(0, 8)
}

function borshString(s: string): Buffer {
  const bytes = Buffer.from(s, 'utf-8')
  const len = Buffer.alloc(4)
  len.writeUInt32LE(bytes.length, 0)
  return Buffer.concat([len, bytes])
}

function findPDA(programId: PublicKey, seeds: (Buffer | Uint8Array)[]): PublicKey {
  return PublicKey.findProgramAddressSync(seeds, programId)[0]
}

// ═══════════════════════════════════════════════════════════════════════════
// ACCOUNT PARSING — Depositor + Stock structs from state.rs
// ═══════════════════════════════════════════════════════════════════════════

// Stock: ticker([u8;8]) + pledged(u64) + exposure(i64) + updated(i64) + rate_bps(u16) + collar_bps(u16) = 36
const STOCK_SIZE = 68

interface StockPosition {
  ticker: string
  pledged: bigint   // u64 — QD collateral backing the position
  exposure: bigint  // i64 — SIGNED: positive = long, negative = short
  updated: bigint   // i64 — last update timestamp
  rateBps: number   // u16 — funding rate
  collarBps: number // u16 — dynamic risk buffer percentage
}

interface DepositorInfo {
  owner: PublicKey
  pda: PublicKey
  depositedQuid: bigint
  depositedLamports: bigint  // u64 @ offset 48 — native SOL in vault
  solPledgedUsd: bigint      // u64 @ offset 56 — collar-adjusted USD value of SOL
  positions: StockPosition[]
}

function parseStock(data: Buffer, offset: number): StockPosition {
  const ticker = Buffer.from(data.subarray(offset, offset + 8))
    .toString('utf-8').replace(/\0+$/, '')
  return {
    ticker,
    pledged:  data.readBigUInt64LE(offset + 8),
    exposure: data.readBigInt64LE(offset + 16),
    updated:  data.readBigInt64LE(offset + 24),
    rateBps:  data.readUInt16LE(offset + 32),
    collarBps: data.readUInt16LE(offset + 34),
  }
}

// Pyth receiver account layout (from etc.rs fetch_price):
// disc(8) + write_auth(32) + level(1) + feed_id(32) + price(i64@73) + conf(u64@81) + exp(i32@89) + time(i64@93)
function parsePythPrice(data: Buffer): number | null {
  if (data.length < 101) return null
  const rawPrice = Number(data.readBigInt64LE(73))
  const exponent = data.readInt32LE(89)
  return rawPrice * Math.pow(10, exponent)
}

// ═══════════════════════════════════════════════════════════════════════════
// COLLAR BREACH DETECTION — mirrors stay.rs repo() pre-check logic
// ═══════════════════════════════════════════════════════════════════════════
//
// For liquidation (amount == 0), repo checks:
//   Long:  over-profitable when exposure_value > pledged + collar_amt
//          under-exposed   when pledged - collar_amt > exposure_value
//   Short: over-profitable when pivot >= exposure_value (short gained)
//          losing          when exposure_value > upper (short lost)

type BreachType = 'over_profitable' | 'under_exposed'

function detectBreach(pos: StockPosition, price: number): BreachType | null {
  if (pos.exposure === 0n || pos.pledged === 0n) return null

  const bps = pos.collarBps > 0 ? pos.collarBps : 1000 // default 10%
  const collar = (pos.pledged * BigInt(bps)) / 10_000n
  const priceBI = BigInt(Math.floor(price))

  if (pos.exposure > 0n) {
    // LONG
    const expVal = pos.exposure * priceBI
    if (expVal > pos.pledged + collar) return 'over_profitable'
    if (pos.pledged - collar > expVal && expVal > 0n) return 'under_exposed'
  } else {
    // SHORT — exposure is negative, take abs
    const expVal = (-pos.exposure) * priceBI
    const pivot = pos.pledged - collar
    const upper = pos.pledged + collar
    if (pivot >= expVal && expVal > 0n) return 'over_profitable'
    if (expVal > upper) return 'under_exposed'
  }
  return null
}

// ═══════════════════════════════════════════════════════════════════════════
// SOLANA KEEPER CLASS
// ═══════════════════════════════════════════════════════════════════════════

class SolanaKeeper {
  private conn: Connection
  private programId: PublicKey
  private wallet: Keypair | null = null
  private isRunning = false
  private priceCache = new Map<string, { price: number; ts: number }>()
  private depositorDiscriminator: Buffer

  constructor() {
    this.conn = new Connection(CONFIG.RPC, 'confirmed')
    this.programId = new PublicKey(CONFIG.PROGRAM_ID)
    this.depositorDiscriminator = createHash('sha256')
      .update('account:Depositor').digest().subarray(0, 8)

    console.log('🌊 Solana Keeper initializing...')
    console.log(`   Network: ${CONFIG.NETWORK} | RPC: ${CONFIG.RPC}`)
  }

  async initialize(): Promise<void> {
    if (CONFIG.KEEPER_KEY) {
      try {
        // Try JSON array (from solana-keygen output)
        const arr = JSON.parse(CONFIG.KEEPER_KEY)
        this.wallet = Keypair.fromSecretKey(Uint8Array.from(arr))
      } catch {
        try {
          // Try base58
          const bs58 = await import('bs58')
          this.wallet = Keypair.fromSecretKey(bs58.default.decode(CONFIG.KEEPER_KEY))
        } catch {
          console.warn('⚠️ Could not parse SOLANA_KEEPER_KEY')
        }
      }
      if (this.wallet) console.log(`💰 Keeper wallet: ${this.wallet.publicKey.toBase58()}`)
    } else {
      console.warn('⚠️ No SOLANA_KEEPER_KEY — read-only mode (scan only)')
    }
    const slot = await this.conn.getSlot()
    console.log(`✅ Connected at slot ${slot}`)
  }

  // ── Price Fetching ──────────────────────────────────────────────────────

  private async fetchPrice(ticker: string): Promise<number | null> {
    const cached = this.priceCache.get(ticker)
    if (cached && Date.now() - cached.ts < 5_000) return cached.price

    const price = CONFIG.NETWORK === 'localnet'
      ? await this.priceFromChain(ticker)
      : await this.priceFromHermes(ticker)

    if (price !== null) this.priceCache.set(ticker, { price, ts: Date.now() })
    return price
  }

  private async priceFromChain(ticker: string): Promise<number | null> {
    const addr = PYTH_ACCOUNTS[ticker]
    if (!addr) return null
    try {
      const info = await this.conn.getAccountInfo(new PublicKey(addr))
      if (!info?.data) return null
      return parsePythPrice(Buffer.from(info.data))
    } catch { return null }
  }

  private async priceFromHermes(ticker: string): Promise<number | null> {
    const hex = PYTH_HEX[ticker]
    if (!hex) return null
    try {
      const r = await fetch(`${CONFIG.HERMES_URL}/api/latest_price_feeds?ids[]=${hex}`)
      if (!r.ok) return null
      const json = await r.json() as any[]
      const p = json?.[0]?.price
      if (!p) return null
      return Number(p.price) * Math.pow(10, Number(p.expo))
    } catch { return null }
  }

  private async batchPrices(tickers: string[]): Promise<Map<string, number>> {
    const out = new Map<string, number>()

    // Try batch Hermes for non-localnet
    if (CONFIG.NETWORK !== 'localnet') {
      const ids = tickers.map(t => PYTH_HEX[t]).filter(Boolean)
      if (ids.length) {
        try {
          const qs = ids.map(h => `ids[]=${h}`).join('&')
          const r = await fetch(`${CONFIG.HERMES_URL}/api/latest_price_feeds?${qs}`)
          if (r.ok) {
            for (const feed of (await r.json()) as any[]) {
              const hexId = '0x' + feed.id
              const t = Object.entries(PYTH_HEX).find(([, v]) => v === hexId)?.[0]
              if (t && feed.price) {
                const p = Number(feed.price.price) * Math.pow(10, Number(feed.price.expo))
                out.set(t, p)
                this.priceCache.set(t, { price: p, ts: Date.now() })
              }
            }
          }
        } catch { /* fall through to individual */ }
      }
    }

    // Fill any gaps
    for (const t of tickers) {
      if (!out.has(t)) {
        const p = await this.fetchPrice(t)
        if (p !== null) out.set(t, p)
      }
    }
    return out
  }

  // ── Depositor Scanning ──────────────────────────────────────────────────

  private async scanDepositors(): Promise<DepositorInfo[]> {
    try {
      const accounts = await this.conn.getProgramAccounts(this.programId, {
        filters: [{
          memcmp: { offset: 0, bytes: this.depositorDiscriminator.toString('base64') }
        }],
      })

      const result: DepositorInfo[] = []
      for (const { pubkey, account } of accounts) {
        const d = Buffer.from(account.data)
        // disc(8)+owner(32)+quid(8)+lam(8)+sol_usd(8)+seconds(16)+last(8)+drawn(8)+veclen(4)=100
        if (d.length < 100) continue

        const owner             = new PublicKey(d.subarray(8, 40))
        const depositedQuid     = d.readBigUInt64LE(40)
        const depositedLamports = d.readBigUInt64LE(48)  // new field
        const solPledgedUsd     = d.readBigUInt64LE(56)  // new field

        // balances Vec<Stock> starts at offset 96 = 8+32+8+8+8+16+8+8
        const vecOffset = 96
        if (d.length < vecOffset + 4) continue
        const count = d.readUInt32LE(vecOffset)

        const positions: StockPosition[] = []
        for (let i = 0; i < count; i++) {
          const off = vecOffset + 4 + i * STOCK_SIZE
          if (off + STOCK_SIZE > d.length) break
          const pos = parseStock(d, off)
          if (pos.ticker && (pos.pledged > 0n || pos.exposure !== 0n)) {
            positions.push(pos)
          }
        }

        if (positions.length > 0 || depositedLamports > 0n) {
          result.push({ owner, pda: pubkey, depositedQuid, depositedLamports, solPledgedUsd, positions })
        }
      }
      return result
    } catch (e: any) {
      console.error('❌ scanDepositors:', e.message?.slice(0, 120))
      return []
    }
  }

  // ── Instruction Building ────────────────────────────────────────────────
  // liquidate(ticker: String) — clutch.rs Liquidate accounts struct:
  //   [0] liquidating    (target owner pubkey, read-only)
  //   [1] liquidator     (signer, mut)
  //   [2] mint           (read-only)
  //   [3] bank           (mut, PDA["depository"])
  //   [4] bank_token_account (mut, PDA["vault", mint])
  //   [5] customer_account   (mut, PDA[owner])
  //   [6] liquidator_depositor (mut, PDA[liquidator], init_if_needed)
  //   [7] ticker_risk    (mut, PDA["risk", ticker])
  //   [8] token_program
  //   [9] associated_token_program
  //  [10] system_program
  //   remaining_accounts: [pyth_ticker, pyth_other1, pyth_other2, ...]

  private buildLiquidateIx(
    target: PublicKey,
    ticker: string,
    pythKeys: PublicKey[],
  ): TransactionInstruction {
    if (!this.wallet) throw new Error('No wallet')
    const mint = new PublicKey(CONFIG.TOKEN_MINT)
    const bank = findPDA(this.programId, [Buffer.from('depository')])
    const vault = findPDA(this.programId, [Buffer.from('vault'), mint.toBuffer()])
    const customer = findPDA(this.programId, [target.toBuffer()])
    const liquidator = findPDA(this.programId, [this.wallet.publicKey.toBuffer()])
    const tickerRisk = findPDA(this.programId, [Buffer.from('risk'), Buffer.from(ticker)])

    const TOKEN_PROGRAM = new PublicKey('TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA')
    const ASSOC_TOKEN = new PublicKey('ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL')

    const keys = [
      { pubkey: target,                     isSigner: false, isWritable: false },
      { pubkey: this.wallet.publicKey,      isSigner: true,  isWritable: true  },
      { pubkey: mint,                       isSigner: false, isWritable: false },
      { pubkey: bank,                       isSigner: false, isWritable: true  },
      { pubkey: vault,                      isSigner: false, isWritable: true  },
      { pubkey: customer,                   isSigner: false, isWritable: true  },
      { pubkey: liquidator,                 isSigner: false, isWritable: true  },
      { pubkey: tickerRisk,                 isSigner: false, isWritable: true  },
      { pubkey: TOKEN_PROGRAM,              isSigner: false, isWritable: false },
      { pubkey: ASSOC_TOKEN,                isSigner: false, isWritable: false },
      { pubkey: SystemProgram.programId,    isSigner: false, isWritable: false },
      // remaining_accounts: all pyth price feeds
      ...pythKeys.map(pk => ({ pubkey: pk, isSigner: false, isWritable: false })),
    ]

    return new TransactionInstruction({
      keys,
      programId: this.programId,
      data: Buffer.concat([ixDisc('liquidate'), borshString(ticker)]),
    })
  }

  // ── Refresh SOL Collateral ──────────────────────────────────────────────
  // refreshSolCollateral(ctx) — clutch.rs RefreshSolCollateral accounts struct:
  //   [0] depositor       (owner pubkey, read-only, CHECK)
  //   [1] customer_account (mut, PDA[owner])
  //   [2] bank            (mut, PDA["depository"])
  //   [3] sol_risk        (mut, PDA["risk", "SOL"])
  //   remaining_accounts: [pyth_sol]

  private buildRefreshSolCollateralIx(owner: PublicKey): TransactionInstruction {
    const bank    = findPDA(this.programId, [Buffer.from('depository')])
    const customer = findPDA(this.programId, [owner.toBuffer()])
    const solRisk  = findPDA(this.programId, [Buffer.from('risk'), Buffer.from('SOL')])
    const solPyth  = new PublicKey(PYTH_ACCOUNTS['SOL'])

    const keys = [
      { pubkey: owner,    isSigner: false, isWritable: false },
      { pubkey: customer, isSigner: false, isWritable: true  },
      { pubkey: bank,     isSigner: false, isWritable: true  },
      { pubkey: solRisk,  isSigner: false, isWritable: true  },
      // remaining_accounts
      { pubkey: solPyth,  isSigner: false, isWritable: false },
    ]
    return new TransactionInstruction({
      keys,
      programId: this.programId,
      data: ixDisc('refresh_sol_collateral'),
    })
  }

  // ── Main Sweep ──────────────────────────────────────────────────────────

  private async sweep(): Promise<void> {
    if (!this.wallet) return

    const depositors = await this.scanDepositors()
    if (!depositors.length) return

    // Collect unique tickers
    const tickers = new Set<string>()
    for (const d of depositors) for (const p of d.positions) tickers.add(p.ticker)

    const prices = await this.batchPrices([...tickers])
    let count = 0

    for (const dep of depositors) {
      for (const pos of dep.positions) {
        const price = prices.get(pos.ticker)
        if (!price || price <= 0) continue

        const breach = detectBreach(pos, price)
        if (!breach) continue

        const dir = pos.exposure > 0n ? 'LONG' : 'SHORT'
        const lev = pos.pledged > 0n
          ? Number((BigInt(Math.abs(Number(pos.exposure))) * BigInt(Math.floor(price)) * 100n) / pos.pledged) / 100
          : 0
        console.log(
          `⚡ ${dep.owner.toBase58().slice(0, 8)}… ${pos.ticker} ${dir} ${breach}` +
          ` | exp=${pos.exposure} pledged=${pos.pledged} price=$${price.toFixed(2)} lev=${lev.toFixed(1)}x`
        )

        try {
          // Build remaining_accounts: ticker's pyth first, then all other positions' pyths
          const pythKeys: PublicKey[] = []
          const mainPyth = PYTH_ACCOUNTS[pos.ticker]
          if (!mainPyth) { console.warn(`   ⚠️ No Pyth account for ${pos.ticker}`); continue }
          pythKeys.push(new PublicKey(mainPyth))

          for (const other of dep.positions) {
            if (other.ticker === pos.ticker) continue
            const otherPyth = PYTH_ACCOUNTS[other.ticker]
            if (otherPyth) pythKeys.push(new PublicKey(otherPyth))
          }

          const ix = this.buildLiquidateIx(dep.owner, pos.ticker, pythKeys)
          const tx = new Transaction().add(ix)
          const sig = await sendAndConfirmTransaction(this.conn, tx, [this.wallet])
          console.log(`   ✅ Liquidated: ${sig}`)
          count++
        } catch (e: any) {
          const msg = e.message || ''
          if (msg.includes('TooSoon'))                 console.log(`   ⏳ Too soon since last update`)
          else if (msg.includes('NotUndercollateralised')) console.log(`   ✓ Position recovered`)
          else                                          console.error(`   ❌ ${msg.slice(0, 120)}`)
        }
      }
    }
    // ── Refresh stale SOL collateral ─────────────────────────────────────
    // Any depositor with depositedLamports > 0 may have stale sol_pledged_usd
    // if SOL price has dropped since their last deposit/withdraw.
    // refreshSolCollateral is permissionless — keeper pays the fee.
    let refreshCount = 0
    for (const dep of depositors) {
      if (dep.depositedLamports === 0n) continue
      try {
        const ix = this.buildRefreshSolCollateralIx(dep.owner)
        const tx = new Transaction().add(ix)
        await sendAndConfirmTransaction(this.conn, tx, [this.wallet!])
        refreshCount++
      } catch (e: any) {
        // Silently skip — price may be fresh enough that no mark-down occurred
        const msg = e.message || ''
        if (!msg.includes('NoPrice')) {
          console.warn(`   ⚠️ refresh ${dep.owner.toBase58().slice(0, 8)}…: ${msg.slice(0, 60)}`)
        }
      }
    }
    if (refreshCount) console.log(`🔄 Refreshed SOL collateral for ${refreshCount} depositor(s)`)

    if (count) console.log(`📊 Sweep done: ${count} liquidation(s)`)
  }

  // ── Lifecycle ───────────────────────────────────────────────────────────

  async start(): Promise<void> {
    await this.initialize()
    this.isRunning = true
    console.log(`\n🌊 Solana Keeper running — interval ${CONFIG.CHECK_INTERVAL / 1000}s\n`)
    while (this.isRunning) {
      try { await this.sweep() }
      catch (e: any) { console.error('❌ Sweep error:', e.message?.slice(0, 120)) }
      await new Promise(r => setTimeout(r, CONFIG.CHECK_INTERVAL))
    }
  }

  stop(): void { this.isRunning = false; console.log('🛑 Solana keeper stopping') }
}

// ═══════════════════════════════════════════════════════════════════════════
// ENTRYPOINT
// ═══════════════════════════════════════════════════════════════════════════
//
// The prediction-market and LSH match keepers that used to run alongside this
// one are gone with the machinery they served: the program exposes no markets
// and no BucketAssignment accounts to keep. What is left is liquidation, and
// that is permissionless — this process is a convenience, not an authority.

export { SolanaKeeper, PYTH_ACCOUNTS, PYTH_HEX, detectBreach }
export type { StockPosition, DepositorInfo, BreachType }

if (require.main === module) {
  const stockKeeper = new SolanaKeeper()

  const shutdown = () => { stockKeeper.stop(); process.exit(0) }
  process.on('SIGINT',  shutdown)
  process.on('SIGTERM', shutdown)

  stockKeeper.start().catch(console.error)
}
