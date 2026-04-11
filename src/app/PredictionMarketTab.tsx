/**
 * PredictionMarketTab.tsx — Solana SAFTA Prediction Market UI
 *
 * Reuses the exact design patterns from page.tsx EVM predictions tab:
 *   - Sub-tabs: 📊 Markets / 📝 Order / 💼 Position / ✨ Create
 *   - Outcome selector grid (same as sideLabels grid)
 *   - Confidence slider (same range 500-10000, step 500)
 *   - Position cards with sell controls
 *   - LMSR price bars with percentages
 *
 * Instruction mapping (lib.rs names → Anchor discriminators):
 *   create_market → sha256("global:create_market")[0..8]
 *   bid           → sha256("global:bid")[0..8]           (PlaceOrder)
 *   sell          → sha256("global:sell")[0..8]           (SellPosition)
 *   reveal        → sha256("global:reveal")[0..8]         (BatchReveal)
 *   weigh         → sha256("global:weigh")[0..8]          (CalculateWeights)
 *   payout        → sha256("global:payout")[0..8]         (PushPayouts)
 *
 * Confidence storage:
 *   Same dual-write pattern as EVM:
 *   1. localStorage: `safta-conf-{chainId}-{marketId}-{outcome}-{pubkey}`
 *   2. POST /api/confidences: { user, mktId, side: outcome, confidence, salt, chainId, commitHash }
 *   The keeper reads from MongoDB to auto-reveal after resolution.
 *
 * commitment_hash = keccak256(confidence_le_bytes || salt_bytes)
 *   On-chain: state.rs::hash_commitment_u64(confidence, salt)
 *   Frontend: solana_keccak below (matches Solana's keccak::hashv)
 */

import { useCallback, useEffect, useMemo, useState } from 'react'

// ═══════════════════════════════════════════════════════════════════════════
// CONSTANTS
// ═══════════════════════════════════════════════════════════════════════════

// PROGRAM_ID removed — program ID comes from the IDL, not hardcoded here
const REVEAL_WINDOW = 24 * 60 * 60 // 24h in seconds

// Keeper wallet address — set to your deployed keeper's pubkey
// The keeper auto-reveals confidences after market resolution
const KEEPER_PUBKEY = process.env.NEXT_PUBLIC_SAFTA_KEEPER || ''

// Solana chainIds for MongoDB (distinguishes from EVM chains)
export const SOLANA_CHAIN_IDS = {
  localnet: 900,
  devnet:   901,
  mainnet:  902,
} as const

// ═══════════════════════════════════════════════════════════════════════════
// BORSH + ANCHOR HELPERS (browser-compatible, no Node crypto)
// ═══════════════════════════════════════════════════════════════════════════

// Precomputed Anchor discriminators: sha256("global:<name>")[0..8]
const IX_DISC: Record<string, number[]> = {
  create_market: [175, 189, 110, 210, 18, 236, 211, 211],
  bid:           [199, 56,  85,  38,  146, 243, 37, 158],
  sell:          [51,  230, 133, 164, 1,   127, 131, 173],
  reveal:        [145, 178, 106, 166, 194, 48,  117, 61],
  weigh:         [223, 15,  191, 143, 194, 43,  230, 213],
  payout:        [172, 165, 75,  114, 190, 20,  77,  179],
  challenge:     [171, 132, 110, 78,  206, 198, 60,  55],
}

function ixDisc(name: string): Uint8Array {
  return new Uint8Array(IX_DISC[name] || [])
}

function borshString(s: string): Uint8Array {
  const bytes = new TextEncoder().encode(s)
  const buf = new Uint8Array(4 + bytes.length)
  new DataView(buf.buffer).setUint32(0, bytes.length, true)
  buf.set(bytes, 4)
  return buf
}

function borshU8(n: number): Uint8Array {
  return new Uint8Array([n & 0xff])
}

function borshU16(n: number): Uint8Array {
  const buf = new Uint8Array(2)
  new DataView(buf.buffer).setUint16(0, n, true)
  return buf
}

function borshU64(n: bigint): Uint8Array {
  const buf = new Uint8Array(8)
  new DataView(buf.buffer).setBigUint64(0, n, true)
  return buf
}

function borshPubkey(base58: string): Uint8Array {
  // Base58 decode for Solana public keys (32 bytes)
  const ALPHA = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz'
  let val = BigInt(0)
  for (const ch of base58) {
    const idx = ALPHA.indexOf(ch)
    if (idx < 0) return new Uint8Array(32) // invalid char → zero key
    val = val * 58n + BigInt(idx)
  }
  const hex = val.toString(16).padStart(64, '0')
  return new Uint8Array(hex.match(/.{2}/g)!.map(b => parseInt(b, 16)))
}

function borshOptionPubkey(pk: string | null): Uint8Array {
  if (!pk) return new Uint8Array([0]) // None
  return new Uint8Array([1, ...borshPubkey(pk)])
}

function borshOptionU64(n: bigint | null): Uint8Array {
  if (n === null) return new Uint8Array([0])
  return new Uint8Array([1, ...borshU64(n)])
}

function borshVecString(strings: string[]): Uint8Array {
  const parts: Uint8Array[] = []
  const len = new Uint8Array(4)
  new DataView(len.buffer).setUint32(0, strings.length, true)
  parts.push(len)
  for (const s of strings) parts.push(borshString(s))
  return concatBytes(...parts)
}

function borshBytes32(bytes: Uint8Array): Uint8Array {
  const buf = new Uint8Array(32)
  buf.set(bytes.subarray(0, 32))
  return buf
}

function concatBytes(...arrays: Uint8Array[]): Uint8Array {
  const total = arrays.reduce((s, a) => s + a.length, 0)
  const out = new Uint8Array(total)
  let off = 0
  for (const a of arrays) { out.set(a, off); off += a.length }
  return out
}

// ═══════════════════════════════════════════════════════════════════════════
// COMMITMENT HASH — matches state.rs hash_commitment_u64
// keccak256(confidence_le_bytes(8) || salt(32))
// ═══════════════════════════════════════════════════════════════════════════

async function solanaKeccak(data: Uint8Array): Promise<Uint8Array> {
  // Use SubtleCrypto SHA-3-256 isn't available in all browsers,
  // but Solana keccak = ethereum keccak256. Use js-sha3 or inline.
  // For production: import { keccak_256 } from 'js-sha3'
  // Fallback: use ethers.keccak256 which is already in the page
  const { keccak256 } = await import('ethers')
  const hash = keccak256(data)
  return new Uint8Array(hash.match(/.{2}/g)!.map(b => parseInt(b, 16)))
}

export function generateSalt(): Uint8Array {
  return crypto.getRandomValues(new Uint8Array(32))
}

export async function generateCommitHash(
  confidence: number, salt: Uint8Array
): Promise<Uint8Array> {
  const confBytes = new Uint8Array(8)
  new DataView(confBytes.buffer).setBigUint64(0, BigInt(confidence), true)
  const input = concatBytes(confBytes, salt)
  return solanaKeccak(input)
}

function saltToHex(salt: Uint8Array): string {
  return Array.from(salt).map(b => b.toString(16).padStart(2, '0')).join('')
}

function hexToSalt(hex: string): Uint8Array {
  const bytes = new Uint8Array(32)
  for (let i = 0; i < 32; i++) bytes[i] = parseInt(hex.slice(i * 2, i * 2 + 2), 16)
  return bytes
}

// ═══════════════════════════════════════════════════════════════════════════
// LMSR PRICING — mirrors etc.rs get_lmsr_price / get_twap_price (simplified)
// ═══════════════════════════════════════════════════════════════════════════

function lmsrPrices(tokensSold: number[], liquidity: number): number[] {
  if (!liquidity || liquidity <= 0) return tokensSold.map(() => 1 / tokensSold.length)
  const b = liquidity
  const exps = tokensSold.map(q => Math.exp(q / b))
  const sumExp = exps.reduce((s, e) => s + e, 0)
  return exps.map(e => e / sumExp)
}

// ═══════════════════════════════════════════════════════════════════════════
// TYPES
// ═══════════════════════════════════════════════════════════════════════════

export interface MarketInfo {
  marketId: number
  pda: string
  question: string
  context: string
  exculpatory: string
  resolutionSource: string
  outcomes: string[]
  deadline: number
  startTime: number
  liquidity: number
  tokensSoldPerOutcome: number[]
  totalCapital: number
  totalCapitalPerOutcome: number[]
  feesCollected: number
  creatorFeeBps: number
  creatorBondLamports: number
  resolved: boolean
  cancelled: boolean
  winningOutcome: number
  resolutionConfidence: number
  resolutionTime: number
  challenged: boolean
  challengeCount: number
  positionsRevealed: number
  positionsTotal: number
  positionsProcessed: number
  weightsComplete: boolean
  payoutsComplete: boolean
  state: 'Trading' | 'AwaitingResolution' | 'Challenged' | 'Settling' | 'PushingPayouts' | 'Finalized' | 'Cancelled'
}

export interface PositionInfo {
  pda: string
  outcome: number
  totalCapital: number
  totalTokens: number
  revealedConfidence: number
  weight: number
  numEntries: number
  revealDelegate: string | null
}

interface ConfEntry {
  confidence: number
  salt: string // hex
  commitHash: string // hex
}

// ═══════════════════════════════════════════════════════════════════════════
// LOCALSTORAGE HELPERS — same dual-write pattern as EVM Hook
// ═══════════════════════════════════════════════════════════════════════════

function storageKey(chainId: number, marketId: number, outcome: number, user: string): string {
  return `safta-conf-${chainId}-${marketId}-${outcome}-${user}`
}

function getStoredConfidences(chainId: number, marketId: number, outcome: number, user: string): ConfEntry[] {
  try {
    return JSON.parse(localStorage.getItem(storageKey(chainId, marketId, outcome, user)) || '[]')
  } catch { return [] }
}

function appendStoredConfidence(chainId: number, marketId: number, outcome: number, user: string, entry: ConfEntry) {
  const key = storageKey(chainId, marketId, outcome, user)
  try {
    const existing = JSON.parse(localStorage.getItem(key) || '[]')
    existing.push(entry)
    localStorage.setItem(key, JSON.stringify(existing))
  } catch {
    localStorage.setItem(key, JSON.stringify([entry]))
  }
}

function getAverageConfidence(entries: ConfEntry[]): number | null {
  if (!entries.length) return null
  return Math.round(entries.reduce((s, e) => s + e.confidence, 0) / entries.length)
}

// ═══════════════════════════════════════════════════════════════════════════
// REGISTRY TAG — used by TagPicker
// ═══════════════════════════════════════════════════════════════════════════

export interface RegistryTag {
  name: string          // human-readable: "Construction", "HeavyMachinery"
  tagId: string         // hex of keccak256(name) — [u8; 32]
  modelCount: number    // how many active models produce this tag
}

// ═══════════════════════════════════════════════════════════════════════════
// PROPS
// ═══════════════════════════════════════════════════════════════════════════

interface PredictionMarketProps {
  connected: boolean
  isLoading: boolean
  txMutex: boolean
  userPubkey: string   // base58 Solana pubkey
  solanaChainId: number // 900/901/902
  formatNumber: (n: number, d: number) => string
  // Chain interaction callbacks — wire to @solana/web3.js + Phantom
  onCreateMarket: (params: {
    question: string; context: string; exculpatory: string;
    resolutionSource: string; outcomes: string[];
    deadline: number; liquidity: number; creatorFeeBps: number;
    creatorBond: number; selectedTagIds: string[];
    matchNotificationPda?: string; // optional ack'd MatchNotification PDA
  }) => Promise<void>
  onPlaceOrder: (params: {
    marketPda: string; outcome: number; capital: number;
    commitmentHash: Uint8Array; revealDelegate: string | null;
    maxDeviationBps: number | null;
  }) => Promise<void>
  onSellPosition: (params: {
    marketPda: string; positionPda: string; tokensToSell: number;
    maxDeviationBps: number | null;
  }) => Promise<void>
  onChallengeMarket: (params: {
    marketPda: string; marketId: number;
  }) => Promise<void>
  // Registry tags (fetched by parent from on-chain ModelEntry PDAs)
  registryTags: RegistryTag[]
  // Data
  markets: MarketInfo[]
  positions: Map<string, PositionInfo[]> // marketPda → positions
  depositedQuid: number
  refreshMarkets: () => Promise<void>
  refreshPositions: (marketPda: string) => Promise<void>
}

// ═══════════════════════════════════════════════════════════════════════════
// COMPONENT
// ═══════════════════════════════════════════════════════════════════════════

export default function PredictionMarketTab({
  connected, isLoading, txMutex, userPubkey, solanaChainId,
  formatNumber, onCreateMarket, onPlaceOrder, onSellPosition,
  onChallengeMarket, registryTags,
  markets, positions, depositedQuid, refreshMarkets, refreshPositions,
}: PredictionMarketProps) {

  // ── Sub-tabs ──
  const [subTab, setSubTab] = useState<'markets' | 'order' | 'position' | 'create'>('markets')

  // ── Selected market ──
  const [selectedMarketId, setSelectedMarketId] = useState<number | null>(null)
  const selectedMarket = useMemo(
    () => markets.find(m => m.marketId === selectedMarketId) || null,
    [markets, selectedMarketId]
  )

  // ── Order state ──
  const [orderOutcome, setOrderOutcome] = useState(0)
  const [orderAmount, setOrderAmount] = useState('')
  const [orderConfidence, setOrderConfidence] = useState(5000)
  const [orderDelegate, setOrderDelegate] = useState(true) // auto-set keeper as delegate

  // ── Sell state ──
  const [sellTokens, setSellTokens] = useState('')
  const [sellOutcome, setSellOutcome] = useState(0)

  // ── Create market state ──
  const [cmQuestion, setCmQuestion] = useState('')
  const [cmContext, setCmContext] = useState('')
  const [cmExculpatory, setCmExculpatory] = useState('')
  const [cmResSource, setCmResSource] = useState('')
  const [cmOutcomes, setCmOutcomes] = useState(['Yes', 'No'])
  const [cmDeadlineDays, setCmDeadlineDays] = useState(7)
  const [cmLiquidity, setCmLiquidity] = useState('10000')
  const [cmFeeBps, setCmFeeBps] = useState(200)
  const [cmBondSol, setCmBondSol] = useState('0.1')
  const [cmSelectedTags, setCmSelectedTags] = useState<string[]>([]) // hex tag IDs
  const [cmTagSearch, setCmTagSearch] = useState('')
  const [cmMatchNotifPda, setCmMatchNotifPda] = useState('') // optional ack'd match notification

  // ── Computed ──
  const prices = useMemo(() => {
    if (!selectedMarket) return []
    return lmsrPrices(selectedMarket.tokensSoldPerOutcome, selectedMarket.liquidity)
  }, [selectedMarket])

  const myPositions = useMemo(() => {
    if (!selectedMarket) return []
    return positions.get(selectedMarket.pda) || []
  }, [selectedMarket, positions])

  // ── Auto-select first market ──
  useEffect(() => {
    if (markets.length > 0 && selectedMarketId === null) {
      setSelectedMarketId(markets[0].marketId)
    }
  }, [markets, selectedMarketId])

  // ── Handlers ──

  const handlePlaceOrder = useCallback(async () => {
    if (!selectedMarket || !orderAmount || txMutex) return
    const capital = parseFloat(orderAmount)
    if (isNaN(capital) || capital < 0.001) return

    const salt = generateSalt()
    const commitHash = await generateCommitHash(orderConfidence, salt)
    const commitHashHex = Array.from(commitHash).map(b => b.toString(16).padStart(2, '0')).join('')
    const saltHex = saltToHex(salt)

    // Keeper pubkey as reveal_delegate (auto-reveals after resolution)
    const delegate = orderDelegate && KEEPER_PUBKEY ? KEEPER_PUBKEY : null

    await onPlaceOrder({
      marketPda: selectedMarket.pda,
      outcome: orderOutcome,
      capital: Math.floor(capital * 1e6), // assuming 6 decimal mint, adjust as needed
      commitmentHash: commitHash,
      revealDelegate: delegate,
      maxDeviationBps: 300,
    })

    // Dual-write confidence
    const confEntry: ConfEntry = {
      confidence: orderConfidence,
      salt: saltHex,
      commitHash: commitHashHex,
    }

    // localStorage
    appendStoredConfidence(solanaChainId, selectedMarket.marketId, orderOutcome, userPubkey, confEntry)

    // MongoDB
    try {
      await fetch('/api/confidences', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          user: userPubkey,
          mktId: selectedMarket.marketId,
          side: orderOutcome,
          confidence: orderConfidence,
          salt: saltHex,
          commitHash: commitHashHex,
          chainId: solanaChainId,
        }),
      })
    } catch (e) { console.warn('Could not store confidence to API:', e) }

    setOrderAmount('')
    setTimeout(() => {
      refreshPositions(selectedMarket.pda)
      refreshMarkets()
    }, 3000)
  }, [selectedMarket, orderAmount, orderOutcome, orderConfidence, orderDelegate,
      txMutex, solanaChainId, userPubkey, onPlaceOrder, refreshPositions, refreshMarkets])

  const handleSellPosition = useCallback(async () => {
    if (!selectedMarket || !sellTokens || txMutex) return
    const tokens = parseFloat(sellTokens)
    if (isNaN(tokens) || tokens <= 0) return

    const pos = myPositions.find(p => p.outcome === sellOutcome)
    if (!pos) return

    await onSellPosition({
      marketPda: selectedMarket.pda,
      positionPda: pos.pda,
      tokensToSell: Math.floor(tokens * 1e6),
      maxDeviationBps: 300,
    })

    setSellTokens('')
    setTimeout(() => {
      refreshPositions(selectedMarket.pda)
      refreshMarkets()
    }, 3000)
  }, [selectedMarket, sellTokens, sellOutcome, myPositions, txMutex,
      onSellPosition, refreshPositions, refreshMarkets])

  const handleCreateMarket = useCallback(async () => {
    if (!cmQuestion || cmOutcomes.length < 2 || txMutex) return

    const deadline = Math.floor(Date.now() / 1000) + cmDeadlineDays * 86400
    const liquidity = Math.floor(parseFloat(cmLiquidity) * 1e6)
    const bond = Math.floor(parseFloat(cmBondSol) * 1e9) // lamports

    await onCreateMarket({
      question: cmQuestion,
      context: cmContext,
      exculpatory: cmExculpatory,
      resolutionSource: cmResSource,
      outcomes: cmOutcomes.filter(o => o.trim()),
      deadline,
      liquidity,
      creatorFeeBps: cmFeeBps,
      creatorBond: bond,
      selectedTagIds: cmSelectedTags,
      matchNotificationPda: cmMatchNotifPda.trim() || undefined,
    })

    setCmQuestion('')
    setCmContext('')
    setCmExculpatory('')
    setCmOutcomes(['Yes', 'No'])
    setCmSelectedTags([])
    setCmTagSearch('')
    setCmMatchNotifPda('')
    setTimeout(refreshMarkets, 5000)
  }, [cmQuestion, cmContext, cmExculpatory, cmResSource, cmOutcomes,
      cmDeadlineDays, cmLiquidity, cmFeeBps, cmBondSol, cmSelectedTags,
      txMutex, onCreateMarket, refreshMarkets])

  // ═══════════════════════════════════════════════════════════════════════
  // RENDER
  // ═══════════════════════════════════════════════════════════════════════

  return (
    <div className="space-y-4">

      {/* Sub-tabs (reuses predictions sub-tab pattern) */}
      <div className="flex gap-1 p-1 rounded-lg bg-white/5">
        {(['markets', 'order', 'position', 'create'] as const).map(tab => (
          <button
            key={tab}
            onClick={() => setSubTab(tab)}
            className={`flex-1 py-1.5 rounded text-xs font-medium capitalize transition-all ${
              subTab === tab ? 'bg-white/10 text-white' : 'text-gray-500 hover:text-gray-300'
            }`}
          >
            {tab === 'markets' ? '📊 Markets' : tab === 'order' ? '📝 Order'
              : tab === 'position' ? '💼 Position' : '✨ Create'}
          </button>
        ))}
      </div>

      {/* Market selector (when not on create tab) */}
      {subTab !== 'create' && markets.length > 0 && (
        <div>
          <label className="text-xs text-gray-400 mb-1 block">Active Market</label>
          <select
            value={selectedMarketId ?? ''}
            onChange={(e) => setSelectedMarketId(Number(e.target.value))}
            className="w-full px-3 py-2 rounded-xl bg-black/30 border border-white/10 text-sm text-white focus:border-cyan-500/50 focus:outline-none"
          >
            {markets.map(m => (
              <option key={m.marketId} value={m.marketId}>
                #{m.marketId}: {m.question.slice(0, 60)}{m.question.length > 60 ? '…' : ''}
                {' '}[{m.state}]
              </option>
            ))}
          </select>
        </div>
      )}

      {/* ══════════════════════════════════════════════════════════════ */}
      {/* MARKETS — overview / LMSR prices                             */}
      {/* ══════════════════════════════════════════════════════════════ */}
      {subTab === 'markets' && (
        <div className="space-y-3">
          {selectedMarket ? (
            <>
              {/* Market header (reuses predictions header) */}
              <div className="flex items-center justify-between">
                <div>
                  <h3 className="text-lg font-bold">{selectedMarket.question}</h3>
                  <p className="text-xs text-gray-500">
                    Market #{selectedMarket.marketId}
                    {' • '}{selectedMarket.positionsTotal} positions
                    {' • '}{selectedMarket.state === 'Trading' ? '🟢 Trading'
                      : selectedMarket.state === 'Settling' ? '⏳ Settling'
                      : selectedMarket.state === 'Challenged' ? '🔒 Challenged'
                      : selectedMarket.state === 'Finalized' ? '✅ Finalized'
                      : selectedMarket.state === 'Cancelled' ? '❌ Cancelled'
                      : `📋 ${selectedMarket.state}`
                    }
                  </p>
                </div>
                <div className="text-right">
                  <p className="text-sm font-bold">${formatNumber(selectedMarket.totalCapital / 1e6, 2)}</p>
                  <p className="text-xs text-gray-500">Total Capital</p>
                </div>
              </div>

              {/* Context / exculpatory */}
              {selectedMarket.context && (
                <div className="p-3 rounded-xl bg-white/5 border border-white/10">
                  <p className="text-xs text-gray-500 mb-1">Context</p>
                  <p className="text-xs text-gray-300">{selectedMarket.context}</p>
                </div>
              )}

              {/* LMSR price bars (reuses hookPrices.map pattern exactly) */}
              <div className="space-y-2">
                {prices.map((price, i) => {
                  const label = selectedMarket.outcomes[i] || `Outcome ${i}`
                  const capital = selectedMarket.totalCapitalPerOutcome[i] || 0
                  const pct = price * 100
                  const isWinner = selectedMarket.resolved && selectedMarket.winningOutcome === i
                  return (
                    <div key={i} className={`p-3 rounded-xl border transition-all ${
                      isWinner ? 'bg-green-500/10 border-green-500/30' : 'bg-white/5 border-white/10'
                    }`}>
                      <div className="flex items-center justify-between mb-1">
                        <span className="text-sm font-medium">
                          {label} {isWinner && ' ✅'}
                        </span>
                        <span className="text-sm font-bold" style={{
                          color: pct > 60 ? '#06b6d4' : '#3b82f6'
                        }}>
                          {pct.toFixed(1)}%
                        </span>
                      </div>
                      <div className="w-full h-2 rounded-full bg-white/10 overflow-hidden">
                        <div
                          className="h-full rounded-full transition-all"
                          style={{
                            width: `${Math.min(pct, 100)}%`,
                            background: isWinner ? '#22c55e' : pct > 60 ? '#06b6d4' : '#3b82f6'
                          }}
                        />
                      </div>
                      <p className="text-xs text-gray-500 mt-1">${formatNumber(capital / 1e6, 2)} capital</p>
                    </div>
                  )
                })}
              </div>

              {/* Market details */}
              <div className="p-3 rounded-xl bg-white/5 border border-white/10">
                <div className="grid grid-cols-2 gap-2 text-xs">
                  <div>
                    <span className="text-gray-500">Deadline:</span>
                    <span className="ml-1 text-white">
                      {new Date(selectedMarket.deadline * 1000).toLocaleString()}
                    </span>
                  </div>
                  <div>
                    <span className="text-gray-500">Creator Fee:</span>
                    <span className="ml-1 text-white">{(selectedMarket.creatorFeeBps / 100).toFixed(1)}%</span>
                  </div>
                  <div>
                    <span className="text-gray-500">Liquidity (B):</span>
                    <span className="ml-1 text-white">{formatNumber(selectedMarket.liquidity / 1e6, 2)}</span>
                  </div>
                  <div>
                    <span className="text-gray-500">Bond:</span>
                    <span className="ml-1 text-white">{(selectedMarket.creatorBondLamports / 1e9).toFixed(3)} SOL</span>
                  </div>
                  {selectedMarket.resolutionSource && (
                    <div className="col-span-2">
                      <span className="text-gray-500">Resolution Source:</span>
                      <span className="ml-1 text-cyan-400">{selectedMarket.resolutionSource}</span>
                    </div>
                  )}
                </div>
              </div>

              {/* Challenge button — visible when market is resolved, within window, not already challenged */}
              {selectedMarket.resolved && !selectedMarket.challenged && !selectedMarket.weightsComplete && (() => {
                const now = Math.floor(Date.now() / 1000)
                const challengeDeadline = selectedMarket.resolutionTime + REVEAL_WINDOW
                const withinWindow = now < challengeDeadline
                const maxChallenges = 3
                const canChallenge = withinWindow && selectedMarket.challengeCount < maxChallenges
                const bondSol = (selectedMarket.creatorBondLamports * 2) / 1e9

                return canChallenge ? (
                  <div className="p-3 rounded-xl bg-orange-500/5 border border-orange-500/20">
                    <div className="flex items-center justify-between mb-2">
                      <div>
                        <p className="text-sm font-semibold text-orange-400">⚡ Challenge Resolution</p>
                        <p className="text-[10px] text-gray-400 mt-0.5">
                          Disagree with outcome "{selectedMarket.outcomes[selectedMarket.winningOutcome]}"?
                          Challenge triggers oracle re-evaluation.
                        </p>
                      </div>
                      <div className="text-right">
                        <p className="text-xs font-mono text-orange-300">{bondSol.toFixed(4)} SOL</p>
                        <p className="text-[10px] text-gray-500">bond (2× creator)</p>
                      </div>
                    </div>
                    <div className="flex items-center gap-2">
                      <p className="text-[10px] text-gray-500 flex-1">
                        {selectedMarket.challengeCount}/{maxChallenges} challenges used
                        {' • '}Window closes {new Date(challengeDeadline * 1000).toLocaleString()}
                      </p>
                      <button
                        onClick={async () => {
                          try {
                            await onChallengeMarket({
                              marketPda: selectedMarket.pda,
                              marketId: selectedMarket.marketId,
                            })
                            setTimeout(refreshMarkets, 5000)
                          } catch (e: any) {
                            console.error('Challenge failed:', e)
                          }
                        }}
                        disabled={!connected || isLoading || txMutex}
                        className="px-4 py-2 rounded-lg font-bold text-sm bg-gradient-to-r from-orange-500 to-red-600 hover:opacity-90 transition-opacity disabled:opacity-50 disabled:cursor-not-allowed whitespace-nowrap"
                      >
                        {isLoading ? 'Submitting...' : 'Challenge'}
                      </button>
                    </div>
                  </div>
                ) : withinWindow ? (
                  <p className="text-[10px] text-gray-500 text-center">
                    Max challenges ({maxChallenges}) reached for this market.
                  </p>
                ) : null
              })()}
            </>
          ) : (
            <div className="text-center py-12">
              <div className="text-4xl mb-4">🔮</div>
              <h3 className="text-xl font-bold mb-2">Prediction Markets</h3>
              <p className="text-gray-400 mb-4">No active markets found.</p>
              <button
                onClick={() => setSubTab('create')}
                className="px-6 py-2 rounded-lg bg-white/10 text-sm text-cyan-400 hover:bg-white/15 transition-all"
              >
                Create a Market →
              </button>
            </div>
          )}
        </div>
      )}

      {/* ══════════════════════════════════════════════════════════════ */}
      {/* ORDER — place order (bid)                                    */}
      {/* ══════════════════════════════════════════════════════════════ */}
      {subTab === 'order' && selectedMarket && (
        <div className="space-y-4">
          {/* Outcome selector (reuses sideLabels grid pattern) */}
          <div>
            <label className="text-xs text-gray-400 mb-2 block">
              Select Outcome
            </label>
            <div className={`grid gap-2 ${
              selectedMarket.outcomes.length <= 3 ? 'grid-cols-3'
                : selectedMarket.outcomes.length <= 4 ? 'grid-cols-4'
                : 'grid-cols-3'
            }`}>
              {selectedMarket.outcomes.map((label, i) => (
                <button
                  key={i}
                  onClick={() => setOrderOutcome(i)}
                  className={`p-2 rounded-lg text-xs font-medium border transition-all ${
                    orderOutcome === i
                      ? 'bg-cyan-500/20 border-cyan-500/50 text-cyan-400'
                      : 'bg-white/5 border-white/10 text-gray-400 hover:border-white/20'
                  }`}
                >
                  {label}
                  {prices[i] !== undefined && (
                    <span className="block text-[10px] text-gray-500 mt-0.5">
                      {(prices[i] * 100).toFixed(1)}%
                    </span>
                  )}
                </button>
              ))}
            </div>
          </div>

          {/* Amount (reuses Hook order amount input) */}
          <div>
            <label className="text-xs text-gray-400 mb-1 block">Amount (QD)</label>
            <div className="flex gap-2">
              <input
                type="number"
                value={orderAmount}
                onChange={(e) => setOrderAmount(e.target.value)}
                placeholder="100"
                min="0.001"
                className="flex-1 px-4 py-3 rounded-xl bg-white/5 border border-white/10 text-white placeholder-gray-600 focus:outline-none focus:border-cyan-500/50"
              />
              {depositedQuid > 0 && (
                <button
                  onClick={() => setOrderAmount(formatNumber(depositedQuid, 2))}
                  className="px-3 py-1 text-xs text-cyan-400 border border-cyan-500/30 rounded-lg hover:bg-cyan-500/10"
                >
                  MAX
                </button>
              )}
            </div>
            <p className="text-xs text-gray-500 mt-1">
              Pool Balance: {formatNumber(depositedQuid, 2)} QD
              {' • '}Creator fee: {(selectedMarket.creatorFeeBps / 100).toFixed(1)}%
            </p>
          </div>

          {/* Confidence slider (reuses Hook confidence pattern exactly) */}
          <div>
            <div className="flex justify-between items-center mb-1">
              <label className="text-xs text-gray-400">Confidence</label>
              <span className="text-xs font-bold text-cyan-400">
                {(orderConfidence / 100).toFixed(0)}%
              </span>
            </div>
            <input
              type="range"
              min={500}
              max={10000}
              step={500}
              value={orderConfidence}
              onChange={(e) => setOrderConfidence(parseInt(e.target.value))}
              className="w-full"
            />
            <p className="text-xs text-gray-500 mt-1">
              Higher confidence = more weight if correct, less if wrong.
              Commit-reveal: hidden until resolution. Range: 5%-100% (step 5%).
            </p>
          </div>

          {/* Delegate toggle */}
          <div className="flex items-center justify-between p-3 rounded-xl bg-white/5 border border-white/10">
            <div>
              <p className="text-sm">Auto-reveal delegate</p>
              <p className="text-xs text-gray-500">Let keeper reveal your confidence after resolution</p>
            </div>
            <button
              onClick={() => setOrderDelegate(!orderDelegate)}
              className={`w-12 h-6 rounded-full transition-all ${orderDelegate ? 'bg-cyan-500' : 'bg-white/20'}`}
            >
              <div className={`w-5 h-5 rounded-full bg-white shadow transition-transform ${orderDelegate ? 'translate-x-6' : 'translate-x-0.5'}`} />
            </button>
          </div>

          {/* Order summary */}
          {orderAmount && parseFloat(orderAmount) > 0 && (
            <div className="p-3 rounded-xl bg-black/20 border border-white/5">
              <div className="flex justify-between text-sm mb-1">
                <span className="text-gray-400">Outcome</span>
                <span className="text-white">{selectedMarket.outcomes[orderOutcome]}</span>
              </div>
              <div className="flex justify-between text-sm mb-1">
                <span className="text-gray-400">Current Price</span>
                <span className="text-white">{(prices[orderOutcome] * 100).toFixed(1)}%</span>
              </div>
              <div className="flex justify-between text-sm mb-1">
                <span className="text-gray-400">Est. Tokens</span>
                <span className="text-white">
                  {prices[orderOutcome] > 0
                    ? formatNumber(
                        (parseFloat(orderAmount) * (1 - selectedMarket.creatorFeeBps / 10000))
                        / prices[orderOutcome], 2)
                    : '—'}
                </span>
              </div>
              <div className="flex justify-between text-sm">
                <span className="text-gray-400">Confidence</span>
                <span className="text-cyan-400">{(orderConfidence / 100).toFixed(0)}% 🔒</span>
              </div>
            </div>
          )}

          {/* Place order button */}
          <button
            onClick={handlePlaceOrder}
            disabled={
              !connected || isLoading || txMutex || !orderAmount ||
              parseFloat(orderAmount) < 0.001 ||
              selectedMarket.resolved || selectedMarket.cancelled ||
              selectedMarket.state !== 'Trading'
            }
            className="w-full py-3 rounded-xl font-bold bg-gradient-to-r from-purple-500 to-pink-600 hover:opacity-90 transition-opacity disabled:opacity-50 disabled:cursor-not-allowed"
          >
            {isLoading ? 'Processing...' : connected ? 'Place Order' : 'Connect Wallet'}
          </button>

          {selectedMarket.state !== 'Trading' && (
            <p className="text-xs text-yellow-400 text-center">
              {selectedMarket.resolved ? 'Market resolved — no new orders'
                : selectedMarket.cancelled ? 'Market cancelled'
                : selectedMarket.challenged ? 'Market frozen — challenge in progress'
                : `Market state: ${selectedMarket.state}`}
            </p>
          )}
        </div>
      )}

      {/* ══════════════════════════════════════════════════════════════ */}
      {/* POSITION — view + sell                                       */}
      {/* ══════════════════════════════════════════════════════════════ */}
      {subTab === 'position' && selectedMarket && (
        <div className="space-y-3">
          {myPositions.length > 0 ? (
            myPositions.map(pos => {
              const label = selectedMarket.outcomes[pos.outcome] || `Outcome ${pos.outcome}`
              const isWinner = selectedMarket.resolved && selectedMarket.winningOutcome === pos.outcome
              const storedEntries = getStoredConfidences(solanaChainId, selectedMarket.marketId, pos.outcome, userPubkey)
              const avgConf = pos.revealedConfidence > 0 ? pos.revealedConfidence : getAverageConfidence(storedEntries)

              // Payout estimate
              const totalCap = selectedMarket.totalCapital
              const mySideCap = selectedMarket.totalCapitalPerOutcome[pos.outcome] || 0
              const otherCap = totalCap - mySideCap
              const myShare = mySideCap > 0 ? pos.totalCapital / mySideCap : 0
              const basePayout = isWinner ? pos.totalCapital + myShare * otherCap * 0.8 : myShare * otherCap * 0.2

              return (
                <div key={pos.pda} className={`p-4 rounded-xl border ${
                  isWinner ? 'bg-green-500/10 border-green-500/30' : 'bg-white/5 border-white/10'
                }`}>
                  <div className="flex items-center justify-between mb-2">
                    <span className="text-sm font-medium">{label}</span>
                    {pos.revealedConfidence > 0 && (
                      <span className="text-xs text-green-400 px-2 py-0.5 rounded bg-green-500/10">Revealed</span>
                    )}
                    {isWinner && (
                      <span className="text-xs text-green-400 px-2 py-0.5 rounded bg-green-500/10">Winner ✅</span>
                    )}
                  </div>

                  <div className="grid grid-cols-2 gap-2 text-xs">
                    <div>
                      <span className="text-gray-500">Capital:</span>
                      <span className="ml-1 text-white">${formatNumber(pos.totalCapital / 1e6, 2)}</span>
                    </div>
                    <div>
                      <span className="text-gray-500">Tokens:</span>
                      <span className="ml-1 text-white">{formatNumber(pos.totalTokens / 1e6, 2)}</span>
                    </div>

                    {/* Confidence display (revealed or from localStorage) */}
                    {pos.revealedConfidence > 0 ? (
                      <div>
                        <span className="text-gray-500">Confidence:</span>
                        <span className="ml-1 text-green-400">
                          {(pos.revealedConfidence / 100).toFixed(0)}% ✓
                        </span>
                      </div>
                    ) : avgConf !== null ? (
                      <div>
                        <span className="text-gray-500">Confidence:</span>
                        <span className="ml-1 text-yellow-400" title={`${storedEntries.length} commit(s)`}>
                          ~{(avgConf / 100).toFixed(0)}% 🔒
                        </span>
                      </div>
                    ) : (
                      <div>
                        <span className="text-gray-500">Confidence:</span>
                        <span className="ml-1 text-gray-600">hidden</span>
                      </div>
                    )}

                    <div>
                      <span className="text-gray-500">Entries:</span>
                      <span className="ml-1 text-white">{pos.numEntries}</span>
                    </div>
                  </div>

                  {/* Payout estimate (reuses Hook payout estimate pattern) */}
                  {totalCap > 0 && mySideCap > 0 && !selectedMarket.cancelled && (
                    <div className="mt-2 p-2 rounded-lg bg-white/[0.03] border border-white/5">
                      <p className="text-[10px] text-gray-500 mb-1">If {label} wins:</p>
                      <div className="flex items-baseline gap-2">
                        <span className="text-sm font-bold text-emerald-400">
                          ≈ ${formatNumber(basePayout / 1e6, 2)}
                        </span>
                        <span className="text-[10px] text-gray-500">
                          ({((basePayout / pos.totalCapital - 1) * 100).toFixed(0)}% return)
                        </span>
                      </div>
                      <p className="text-[10px] text-gray-600 mt-0.5">
                        Pool: ${formatNumber(totalCap / 1e6, 0)} total
                        {' • '}${formatNumber(mySideCap / 1e6, 0)} on {label}
                      </p>
                    </div>
                  )}

                  {/* Sell controls (reuses Hook sell pattern) */}
                  {!selectedMarket.resolved && selectedMarket.state === 'Trading' && (
                    <div className="mt-3 flex gap-2">
                      <input
                        type="number"
                        value={sellOutcome === pos.outcome ? sellTokens : ''}
                        onChange={(e) => { setSellOutcome(pos.outcome); setSellTokens(e.target.value) }}
                        placeholder="Tokens to sell"
                        className="flex-1 px-3 py-2 rounded-lg bg-white/5 border border-white/10 text-xs text-white placeholder-gray-600 focus:outline-none focus:border-cyan-500/50"
                      />
                      <button
                        onClick={() => { setSellOutcome(pos.outcome); handleSellPosition() }}
                        disabled={!sellTokens || parseFloat(sellTokens) <= 0 || txMutex}
                        className="px-3 py-2 text-xs rounded-lg bg-red-500/20 text-red-400 border border-red-500/30 hover:bg-red-500/30 disabled:opacity-50"
                      >
                        Sell
                      </button>
                    </div>
                  )}
                </div>
              )
            })
          ) : (
            <div className="text-center py-8 text-gray-500 text-sm">
              {connected ? 'No positions in this market' : 'Connect wallet to view positions'}
            </div>
          )}
        </div>
      )}

      {/* ══════════════════════════════════════════════════════════════ */}
      {/* CREATE — market creation wizard                              */}
      {/* ══════════════════════════════════════════════════════════════ */}
      {subTab === 'create' && (
        <div className="space-y-4">
          <div className="flex items-center justify-between mb-2">
            <h3 className="text-lg font-bold">Create Prediction Market</h3>
          </div>

          {/* Question */}
          <div>
            <label className="text-xs text-gray-400 mb-1 block">Question *</label>
            <textarea
              value={cmQuestion}
              onChange={(e) => setCmQuestion(e.target.value)}
              placeholder="Will BTC close above $100,000 on March 1, 2026?"
              rows={2}
              className="w-full px-4 py-3 rounded-xl bg-black/30 border border-white/10 text-sm text-white placeholder-gray-600 focus:outline-none focus:border-cyan-500/50 resize-none"
            />
          </div>

          {/* Context */}
          <div>
            <label className="text-xs text-gray-400 mb-1 block">Context / Definitions</label>
            <textarea
              value={cmContext}
              onChange={(e) => setCmContext(e.target.value)}
              placeholder="BTC price = CoinGecko daily close UTC. 'Close above' means final daily candle close > threshold."
              rows={2}
              className="w-full px-4 py-3 rounded-xl bg-black/30 border border-white/10 text-sm text-white placeholder-gray-600 focus:outline-none focus:border-cyan-500/50 resize-none"
            />
          </div>

          {/* Exculpatory */}
          <div>
            <label className="text-xs text-gray-400 mb-1 block">Force Majeure / Exculpatory</label>
            <textarea
              value={cmExculpatory}
              onChange={(e) => setCmExculpatory(e.target.value)}
              placeholder="Market cancels if: data source offline >24h during measurement period..."
              rows={2}
              className="w-full px-4 py-3 rounded-xl bg-black/30 border border-white/10 text-sm text-white placeholder-gray-600 focus:outline-none focus:border-cyan-500/50 resize-none"
            />
          </div>

          {/* Resolution source */}
          <div>
            <label className="text-xs text-gray-400 mb-1 block">Resolution Source</label>
            <input
              type="text"
              value={cmResSource}
              onChange={(e) => setCmResSource(e.target.value)}
              placeholder="CoinGecko, AP News, NBA.com..."
              className="w-full px-4 py-3 rounded-xl bg-black/30 border border-white/10 text-sm text-white placeholder-gray-600 focus:outline-none focus:border-cyan-500/50"
            />
          </div>

          {/* Match Notification — optional provenance link from RFQ */}
          <div>
            <label className="text-xs text-gray-400 mb-1 block">
              Match Notification PDA
              <span className="ml-1.5 text-gray-600 font-normal">(optional — links contest to your match)</span>
            </label>
            <input
              type="text"
              value={cmMatchNotifPda}
              onChange={(e) => setCmMatchNotifPda(e.target.value)}
              placeholder="Paste ack'd MatchNotification PDA to derive required tags automatically"
              className="w-full px-4 py-3 rounded-xl bg-black/30 border border-white/10 text-sm text-white placeholder-gray-600 focus:outline-none focus:border-cyan-500/50 font-mono"
            />
            {cmMatchNotifPda.trim() && (
              <p className="text-[10px] text-cyan-400/70 mt-0.5">
                ✓ category_hash will be prepended to required tags — notification must be ack'd first
              </p>
            )}
          </div>

          {/* Outcomes */}
          <div>
            <label className="text-xs text-gray-400 mb-1 block">
              Outcomes ({cmOutcomes.length}) — minimum 2
            </label>
            <div className="space-y-2">
              {cmOutcomes.map((outcome, i) => (
                <div key={i} className="flex gap-2">
                  <input
                    type="text"
                    value={outcome}
                    onChange={(e) => {
                      const next = [...cmOutcomes]
                      next[i] = e.target.value
                      setCmOutcomes(next)
                    }}
                    placeholder={`Outcome ${i + 1}`}
                    className="flex-1 px-3 py-2 rounded-lg bg-black/30 border border-white/10 text-sm text-white placeholder-gray-600 focus:outline-none focus:border-cyan-500/50"
                  />
                  {cmOutcomes.length > 2 && (
                    <button
                      onClick={() => setCmOutcomes(cmOutcomes.filter((_, j) => j !== i))}
                      className="px-2 text-red-400 hover:text-red-300"
                    >
                      ✕
                    </button>
                  )}
                </div>
              ))}
              {cmOutcomes.length < 10 && (
                <button
                  onClick={() => setCmOutcomes([...cmOutcomes, ''])}
                  className="w-full py-2 rounded-lg border border-dashed border-white/20 text-xs text-gray-400 hover:border-white/40 hover:text-white transition-all"
                >
                  + Add Outcome
                </button>
              )}
            </div>
          </div>

          {/* Domain Tags — TagPicker (unions all tags from active registry models) */}
          <div>
            <label className="text-xs text-gray-400 mb-1 block">
              Domain Tags {cmSelectedTags.length > 0 && `(${cmSelectedTags.length} selected)`}
            </label>
            <p className="text-[10px] text-gray-500 mb-2">
              Tag your market's domain so the right evidence classifiers are matched.
            </p>
            {/* Selected tags as pills */}
            {cmSelectedTags.length > 0 && (
              <div className="flex flex-wrap gap-1.5 mb-2">
                {cmSelectedTags.map(tagId => {
                  const tag = registryTags.find(t => t.tagId === tagId)
                  return (
                    <button
                      key={tagId}
                      onClick={() => setCmSelectedTags(prev => prev.filter(t => t !== tagId))}
                      className="flex items-center gap-1 px-2.5 py-1 rounded-full bg-cyan-500/20 border border-cyan-500/40 text-xs text-cyan-300 hover:bg-red-500/20 hover:border-red-500/40 hover:text-red-300 transition-all group"
                    >
                      {tag?.name || tagId.slice(0, 8) + '…'}
                      <span className="text-[10px] opacity-60 group-hover:opacity-100">✕</span>
                    </button>
                  )
                })}
              </div>
            )}
            {/* Tag search + dropdown */}
            {registryTags.length > 0 ? (
              <div className="relative">
                <input
                  type="text"
                  value={cmTagSearch}
                  onChange={(e) => setCmTagSearch(e.target.value)}
                  placeholder="Search tags..."
                  className="w-full px-3 py-2 rounded-xl bg-black/30 border border-white/10 text-xs text-white placeholder-gray-600 focus:outline-none focus:border-cyan-500/50"
                />
                {/* Filtered dropdown */}
                {cmTagSearch && (
                  <div className="absolute z-10 mt-1 w-full max-h-40 overflow-y-auto rounded-xl bg-[#1a1b1e] border border-white/10 shadow-xl">
                    {registryTags
                      .filter(t =>
                        t.name.toLowerCase().includes(cmTagSearch.toLowerCase()) &&
                        !cmSelectedTags.includes(t.tagId)
                      )
                      .slice(0, 12)
                      .map(tag => (
                        <button
                          key={tag.tagId}
                          onClick={() => {
                            setCmSelectedTags(prev => [...prev, tag.tagId])
                            setCmTagSearch('')
                          }}
                          className="w-full flex items-center justify-between px-3 py-2 text-xs text-gray-300 hover:bg-white/10 hover:text-white transition-colors"
                        >
                          <span>{tag.name}</span>
                          <span className="text-[10px] text-gray-500">{tag.modelCount} model{tag.modelCount !== 1 ? 's' : ''}</span>
                        </button>
                      ))}
                    {registryTags.filter(t =>
                      t.name.toLowerCase().includes(cmTagSearch.toLowerCase()) &&
                      !cmSelectedTags.includes(t.tagId)
                    ).length === 0 && (
                      <p className="px-3 py-2 text-xs text-gray-500">No matching tags</p>
                    )}
                  </div>
                )}
                {/* Quick-pick: show top tags when no search */}
                {!cmTagSearch && cmSelectedTags.length === 0 && (
                  <div className="flex flex-wrap gap-1.5 mt-2">
                    {registryTags.slice(0, 8).map(tag => (
                      <button
                        key={tag.tagId}
                        onClick={() => setCmSelectedTags(prev => [...prev, tag.tagId])}
                        className="px-2 py-1 rounded-full bg-white/5 border border-white/10 text-[10px] text-gray-400 hover:bg-cyan-500/10 hover:border-cyan-500/30 hover:text-cyan-300 transition-all"
                      >
                        {tag.name}
                      </button>
                    ))}
                  </div>
                )}
              </div>
            ) : (
              <p className="text-[10px] text-gray-600 italic">
                No active models in registry. Tags will be available once classifiers are registered.
              </p>
            )}
          </div>

          {/* Parameters row */}
          <div className="grid grid-cols-2 gap-3">
            <div>
              <label className="text-xs text-gray-400 mb-1 block">Deadline (days)</label>
              <input
                type="number"
                value={cmDeadlineDays}
                onChange={(e) => setCmDeadlineDays(parseInt(e.target.value) || 7)}
                min={1}
                max={365}
                className="w-full px-3 py-2 rounded-xl bg-black/30 border border-white/10 text-sm text-white focus:outline-none focus:border-cyan-500/50"
              />
            </div>
            <div>
              <label className="text-xs text-gray-400 mb-1 block">Liquidity (QD)</label>
              <input
                type="number"
                value={cmLiquidity}
                onChange={(e) => setCmLiquidity(e.target.value)}
                placeholder="10000"
                className="w-full px-3 py-2 rounded-xl bg-black/30 border border-white/10 text-sm text-white focus:outline-none focus:border-cyan-500/50"
              />
            </div>
            <div>
              <label className="text-xs text-gray-400 mb-1 block">Creator Fee (bps)</label>
              <input
                type="number"
                value={cmFeeBps}
                onChange={(e) => setCmFeeBps(parseInt(e.target.value) || 0)}
                min={0}
                max={1000}
                className="w-full px-3 py-2 rounded-xl bg-black/30 border border-white/10 text-sm text-white focus:outline-none focus:border-cyan-500/50"
              />
              <p className="text-[10px] text-gray-500 mt-0.5">{(cmFeeBps / 100).toFixed(1)}%</p>
            </div>
            <div>
              <label className="text-xs text-gray-400 mb-1 block">Bond (SOL)</label>
              <input
                type="number"
                value={cmBondSol}
                onChange={(e) => setCmBondSol(e.target.value)}
                placeholder="0.1"
                min="0.1"
                step="0.01"
                className="w-full px-3 py-2 rounded-xl bg-black/30 border border-white/10 text-sm text-white focus:outline-none focus:border-cyan-500/50"
              />
              <p className="text-[10px] text-gray-500 mt-0.5">Min: 0.1 SOL</p>
            </div>
          </div>

          {/* Summary */}
          {cmQuestion && cmOutcomes.filter(o => o.trim()).length >= 2 && (
            <div className="p-3 rounded-xl bg-cyan-500/5 border border-cyan-500/20">
              <p className="text-xs text-cyan-400/80">
                Market: "{cmQuestion.slice(0, 80)}{cmQuestion.length > 80 ? '…' : ''}"
                {' • '}{cmOutcomes.filter(o => o.trim()).length} outcomes
                {' • '}{cmDeadlineDays}d deadline
                {' • '}{(cmFeeBps / 100).toFixed(1)}% fee
                {' • '}{cmBondSol} SOL bond
              </p>
            </div>
          )}

          {/* Create button */}
          <button
            onClick={handleCreateMarket}
            disabled={
              !connected || isLoading || txMutex ||
              !cmQuestion || cmOutcomes.filter(o => o.trim()).length < 2
            }
            className="w-full py-4 rounded-xl font-bold text-lg bg-gradient-to-r from-cyan-500 to-blue-600 hover:opacity-90 transition-opacity disabled:opacity-50 disabled:cursor-not-allowed"
          >
            {isLoading ? 'Creating...' : connected ? 'Create Market' : 'Connect Wallet'}
          </button>

          <p className="text-xs text-gray-500 text-center">
            Requires validation oracle approval before market goes live.
            Bond is refunded when market finalizes (minus creator fee on loser pot).
          </p>
        </div>
      )}

      {!connected && (
        <p className="text-center text-gray-500 text-sm py-4">
          Connect a Solana wallet (Phantom) to interact with prediction markets.
        </p>
      )}
    </div>
  )
}

// ═══════════════════════════════════════════════════════════════════════════
// INSTRUCTION DATA BUILDERS — for integration layer
// ═══════════════════════════════════════════════════════════════════════════
// These return raw Uint8Array instruction data. The integration layer
// wraps them in TransactionInstruction with the correct accounts.

export function encodeBid(
  outcome: number, capital: bigint, commitmentHash: Uint8Array,
  revealDelegate: string | null, maxDeviationBps: bigint | null,
): Uint8Array {
  // OrderParams: outcome(u8) + capital(u64) + commitment_hash([u8;32]) +
  //   reveal_delegate(Option<Pubkey>) + max_deviation_bps(Option<u64>)
  return concatBytes(
    ixDisc('bid'),
    borshU8(outcome),
    borshU64(capital),
    borshBytes32(commitmentHash),
    borshOptionPubkey(revealDelegate),
    borshOptionU64(maxDeviationBps),
  )
}

export function encodeSell(
  tokensToSell: bigint, maxDeviationBps: bigint | null,
): Uint8Array {
  return concatBytes(
    ixDisc('sell'),
    borshU64(tokensToSell),
    borshOptionU64(maxDeviationBps),
  )
}

export function encodeCreateMarket(
  question: string, context: string, exculpatory: string,
  resolutionSource: string, outcomes: string[], sbFeed: string,
  deadline: bigint, liquidity: bigint, creatorFeeBps: number, creatorBond: bigint,
  numWinners: number = 1, winningSplits: bigint[] = [], beneficiaries: (string | null)[] = [],
): Uint8Array {
  // Vec<u64> for winning_splits
  const splitsLen = new Uint8Array(4)
  new DataView(splitsLen.buffer).setUint32(0, winningSplits.length, true)
  const splitsData = concatBytes(splitsLen, ...winningSplits.map(s => borshU64(s)))
  // Vec<Option<Pubkey>> for beneficiaries
  const beneLen = new Uint8Array(4)
  new DataView(beneLen.buffer).setUint32(0, beneficiaries.length, true)
  const beneData = concatBytes(beneLen, ...beneficiaries.map(b => borshOptionPubkey(b)))
  return concatBytes(
    ixDisc('create_market'),
    borshString(question),
    borshString(context),
    borshString(exculpatory),
    borshString(resolutionSource),
    borshVecString(outcomes),
    borshPubkey(sbFeed),
    borshU64(BigInt(deadline)),
    borshU64(liquidity),
    borshU16(creatorFeeBps),
    borshU64(creatorBond),
    borshU8(numWinners),
    splitsData,
    beneData,
  )
}

// challenge_resolution has no params — just the discriminator
export function encodeChallenge(): Uint8Array {
  return ixDisc('challenge')
}

// ═══════════════════════════════════════════════════════════════════════════
// ACCOUNT LAYOUTS — for parsing Market / Position from getProgramAccounts
// ═══════════════════════════════════════════════════════════════════════════
// Integration layer should use these to parse on-chain data into MarketInfo
// and PositionInfo objects that this component consumes.
//
// Market PDA: seeds = [b"market", &market_id.to_le_bytes()[..6]]
// Position PDA: seeds = [b"position", market.key(), user.key(), &[outcome]]
// Depositor PDA: seeds = [user.key()]
//
// For full parsing, see the anchor IDL or the struct definitions in state.rs.
