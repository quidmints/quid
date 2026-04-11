/**
 * EvidenceTab.tsx — Evidence pipeline + match notifications
 *
 * Covers functionality entirely absent from PredictionMarketTab:
 *   • submitEvidence — commit SHA256(blob) hash to on-chain EvidenceSubmission PDA
 *   • ackMatch       — mark received MatchNotification as read
 *   • Pipeline status — shows BucketAssignment state (classified / pending)
 *
 * PredictionMarketTab already handles:
 *   • Market creation (including initMarketEvidence when tags are selected)
 *   • Bidding, selling, challenging, reveal, weigh, payout
 *   • Market list with LMSR price bars
 *
 * This tab shows:
 *   📤 Submit  — pick an evidence-gated market, hash a blob, submit commitment
 *   🔔 Matches — unread MatchNotifications from oracle with ack button
 *   📊 Status  — pipeline state per category (evidence count → projected → matched)
 *
 * Prop types are intentionally minimal — page.tsx wires the callbacks.
 * txMutex is boolean (useState) matching the existing page.tsx pattern.
 *
 * Exported Borsh encoders:
 *   encodeSubmitEvidence(attestationHash, contentType, nonce) → Uint8Array
 *   encodeAckMatch()                                          → Uint8Array
 *
 * Integration:
 *   1. Add 'evidence' to Solana tab list in page.tsx (done in patch)
 *   2. Mount: {activeTab === 'evidence' && networkMode === 'solana' && <EvidenceTab ... />}
 */

'use client'

import { useCallback, useEffect, useState } from 'react'
import { PublicKey } from '@solana/web3.js'
import { BN } from '@coral-xyz/anchor'

// ═══════════════════════════════════════════════════════════════════════════
// BORSH ENCODERS — exported so page.tsx instruction builders can use them
// ═══════════════════════════════════════════════════════════════════════════

function disc(name: string): Uint8Array {
  // Anchor discriminator: sha256("global:<name>")[0..8]
  // We pre-compute rather than importing sha256 to keep the bundle lean.
  const KNOWN: Record<string, number[]> = {
    submit_evidence: [101, 139, 242, 114, 233, 14, 56, 100],
    ack_match:       [163, 77,  64,  19,  230, 241, 92, 215],
  }
  return new Uint8Array(KNOWN[name] ?? [])
}

function concat(...arrays: Uint8Array[]): Uint8Array {
  const total = arrays.reduce((s, a) => s + a.length, 0)
  const out = new Uint8Array(total)
  let off = 0
  for (const a of arrays) { out.set(a, off); off += a.length }
  return out
}

/** encodeSubmitEvidence — matches SubmitEvidenceParams Borsh layout */
export function encodeSubmitEvidence(
  attestationHash: number[], // [u8; 32]
  contentType: number,        // u8
  nonce: number,              // u8
): Uint8Array {
  const params = new Uint8Array(34)
  params.set(attestationHash.slice(0, 32), 0) // attestation_hash [u8;32]
  params[32] = contentType & 0xff
  params[33] = nonce & 0xff
  return concat(disc('submit_evidence'), params)
}

/** encodeAckMatch — no params, just the discriminator */
export function encodeAckMatch(): Uint8Array {
  return disc('ack_match')
}

// ═══════════════════════════════════════════════════════════════════════════
// TYPES
// ═══════════════════════════════════════════════════════════════════════════

export interface EvidenceMarket {
  marketId: number
  pda: string
  evidencePda: string
  question: string
  submissionCount: number
  maxSubmissions: number
  timeWindowEnd: number        // unix seconds
  minTagConfidence: number     // bps 0–10000
  resolutionMode: number       // 0–3
}

export interface EvidenceSubmission {
  pda: string
  marketPda: string
  submitter: string
  attestationHash: string      // hex
  contentType: number
  nonce: number
  submittedAt: number
}

export interface MatchNotification {
  pda: string
  device: string
  counterpartyCommitment: string   // hex — blinded
  categoryHash: string             // hex
  similarityBps: number            // 0–10000
  slot: number
  read: boolean
}

export interface BucketStatus {
  categoryHashHex: string
  deviceCount: number
  projected: boolean
  matchCount: number
}

interface EvidenceTabProps {
  connected: boolean
  isLoading: boolean
  txMutex: boolean
  userPubkey: string | null
  programId?: string  // override default PROGRAM_ID for local PDA derivation
  solanaChainId: number
  formatNumber: (n: number, d?: number) => string
  onSubmitEvidence: (params: {
    marketPda: string
    evidencePda: string
    marketEvidencePda: string
    nonce: number
    attestationHash: number[]
    contentType: number
  }) => Promise<void>
  onAckMatch: (notificationPda: string) => Promise<void>
  evidenceMarkets: EvidenceMarket[]
  mySubmissions: EvidenceSubmission[]
  myNotifications: MatchNotification[]
  bucketStatuses: BucketStatus[]
  refreshMarkets: () => Promise<void>
  refreshNotifications: () => Promise<void>
}

// ═══════════════════════════════════════════════════════════════════════════
// HELPERS
// ═══════════════════════════════════════════════════════════════════════════

// PROGRAM_ID fallback — overridden by programId prop from page.tsx
const PROGRAM_ID = 'J1xE8gXrXgrFoEch6QQ9JesqyqhUAkjDuD4CLb2RWSfC'

function derivePDA(seeds: Buffer[], programId = PROGRAM_ID): string {
  try {
    return PublicKey.findProgramAddressSync(
      seeds, new PublicKey(programId)
    )[0].toBase58()
  } catch { return '' }
}

function deriveEvidencePDA(marketPda: string, submitter: string, nonce: number, programId = PROGRAM_ID): string {
  try {
    return derivePDA([
      Buffer.from('evidence'),
      new PublicKey(marketPda).toBuffer(),
      new PublicKey(submitter).toBuffer(),
      Buffer.from([nonce]),
    ], programId)
  } catch { return '' }
}

function deriveMarketEvidencePDA(marketPda: string, programId = PROGRAM_ID): string {
  try {
    return derivePDA([
      Buffer.from('market_evidence'),
      new PublicKey(marketPda).toBuffer(),
    ], programId)
  } catch { return '' }
}

function modeLabel(m: number) {
  return ['External', 'CoCo Local', 'Jury Only', 'AI + Jury'][m] ?? `Mode ${m}`
}

function timeLeft(unix: number): string {
  const d = unix - Math.floor(Date.now() / 1000)
  if (d <= 0) return 'Closed'
  if (d < 3600) return `${Math.floor(d / 60)}m`
  if (d < 86400) return `${Math.floor(d / 3600)}h`
  return `${Math.floor(d / 86400)}d`
}

function timeAgo(unix: number): string {
  const d = Math.floor(Date.now() / 1000) - unix
  if (d < 60) return `${d}s ago`
  if (d < 3600) return `${Math.floor(d / 60)}m ago`
  if (d < 86400) return `${Math.floor(d / 3600)}h ago`
  return `${Math.floor(d / 86400)}d ago`
}

function hexShort(hex: string, n = 8) {
  return hex ? `${hex.slice(0, n)}…` : '—'
}

// ═══════════════════════════════════════════════════════════════════════════
// COMPONENT
// ═══════════════════════════════════════════════════════════════════════════

export default function EvidenceTab({
  connected, isLoading, txMutex, userPubkey, solanaChainId, programId: programIdProp,
  formatNumber, onSubmitEvidence, onAckMatch,
  evidenceMarkets, mySubmissions, myNotifications, bucketStatuses,
  refreshMarkets, refreshNotifications,
}: EvidenceTabProps) {
  const effectiveProgramId = programIdProp || PROGRAM_ID

  type SubTab = 'submit' | 'notifications' | 'status'
  const [subTab, setSubTab] = useState<SubTab>('submit')

  // ── Submit state ──
  const [selectedMarket, setSelectedMarket] = useState<EvidenceMarket | null>(null)
  const [contentType, setContentType] = useState<0 | 1>(0)
  const [blobNote, setBlobNote] = useState('')
  const [submitting, setSubmitting] = useState(false)
  const [submitStatus, setSubmitStatus] = useState<string | null>(null)

  // ── Notification state ──
  const [acking, setAcking] = useState<string | null>(null)

  const unread = myNotifications.filter(n => !n.read).length

  // Auto-select first market
  useEffect(() => {
    if (!selectedMarket && evidenceMarkets.length > 0) {
      setSelectedMarket(evidenceMarkets[0])
    }
  }, [evidenceMarkets, selectedMarket])

  // ── Submit handler ────────────────────────────────────────────────────────

  const handleSubmit = useCallback(async () => {
    if (!selectedMarket || !userPubkey || txMutex) return
    setSubmitting(true); setSubmitStatus(null)
    try {
      // Nonce = next unused slot for this (market, submitter) pair
      const used = mySubmissions.filter(
        s => s.marketPda === selectedMarket.pda && s.submitter === userPubkey
      ).length
      const nonce = used
      if (nonce >= selectedMarket.maxSubmissions) {
        setSubmitStatus(`Market full — max ${selectedMarket.maxSubmissions} submissions`)
        return
      }

      // SHA256 the blob note (or random bytes if blank) using SubtleCrypto
      const data = blobNote
        ? new TextEncoder().encode(blobNote)
        : window.crypto.getRandomValues(new Uint8Array(32))
      const hashBuf = await window.crypto.subtle.digest('SHA-256', data)
      const attestationHash = Array.from(new Uint8Array(hashBuf))

      const evidencePda = deriveEvidencePDA(selectedMarket.pda, userPubkey, nonce, effectiveProgramId)
      const marketEvidencePda = deriveMarketEvidencePDA(selectedMarket.pda, effectiveProgramId)
      if (!evidencePda || !marketEvidencePda) throw new Error('PDA derivation failed')

      await onSubmitEvidence({
        marketPda: selectedMarket.pda,
        evidencePda,
        marketEvidencePda,
        nonce,
        attestationHash,
        contentType,
      })
      setSubmitStatus(`✓ Submitted nonce=${nonce} — SHA256 committed on-chain`)
      setBlobNote('')
      await refreshMarkets()
    } catch (e: any) {
      setSubmitStatus(`✗ ${e.message?.slice(0, 120) ?? String(e)}`)
    } finally {
      setSubmitting(false)
    }
  }, [selectedMarket, userPubkey, txMutex, mySubmissions, blobNote,
      contentType, onSubmitEvidence, refreshMarkets])

  // ── Ack handler ───────────────────────────────────────────────────────────

  const handleAck = useCallback(async (notif: MatchNotification) => {
    if (txMutex) return
    setAcking(notif.pda)
    try {
      await onAckMatch(notif.pda)
      await refreshNotifications()
    } catch (e: any) {
      console.error('ack failed', e)
    } finally {
      setAcking(null)
    }
  }, [txMutex, onAckMatch, refreshNotifications])

  // ── My submissions for selected market ───────────────────────────────────

  const myMarketSubmissions = selectedMarket
    ? mySubmissions.filter(s => s.marketPda === selectedMarket.pda
        && s.submitter === userPubkey)
    : []

  // ─────────────────────────────────────────────────────────────────────────
  // RENDER
  // ─────────────────────────────────────────────────────────────────────────

  return (
    <div className="space-y-4">

      {/* Header */}
      <div className="flex items-center justify-between p-4 rounded-xl bg-white/5 border border-white/10">
        <div>
          <p className="text-sm font-semibold text-white">Evidence Pipeline</p>
          <p className="text-xs text-gray-400 mt-0.5">
            Submit device attestations · Read oracle match notifications
          </p>
        </div>
        {unread > 0 && (
          <div className="flex items-center gap-1.5 px-3 py-1.5 rounded-full bg-cyan-500/20 border border-cyan-500/40">
            <span className="w-2 h-2 rounded-full bg-cyan-400 animate-pulse" />
            <span className="text-xs text-cyan-300 font-medium">{unread} new</span>
          </div>
        )}
      </div>

      {/* Sub-tabs */}
      <div className="flex gap-1 p-1 rounded-lg bg-white/5">
        {([
          ['submit',        '📤 Submit'],
          ['notifications', `🔔 Matches${unread ? ` (${unread})` : ''}`],
          ['status',        '📊 Pipeline'],
        ] as [SubTab, string][]).map(([id, label]) => (
          <button key={id} onClick={() => setSubTab(id)}
            className={`flex-1 py-2 px-3 rounded-md text-xs font-medium transition-all ${
              subTab === id ? 'bg-white/10 text-white' : 'text-gray-400 hover:text-white'
            }`}>
            {label}
          </button>
        ))}
      </div>

      {/* ── SUBMIT ──────────────────────────────────────────────────────────── */}
      {subTab === 'submit' && (
        <div className="space-y-4">
          {!connected && (
            <div className="p-3 rounded-xl bg-yellow-500/10 border border-yellow-500/20 text-xs text-yellow-300">
              Connect Phantom to submit evidence
            </div>
          )}

          {/* Market selector */}
          <div>
            <label className="block text-xs text-gray-400 mb-1.5">Market</label>
            <select
              value={selectedMarket?.pda ?? ''}
              onChange={e => setSelectedMarket(
                evidenceMarkets.find(m => m.pda === e.target.value) ?? null
              )}
              className="w-full px-4 py-3 rounded-xl bg-black/30 border border-white/10 text-white text-sm
                         focus:outline-none focus:border-cyan-500/50"
            >
              <option value="">— Select market —</option>
              {evidenceMarkets.map(m => (
                <option key={m.pda} value={m.pda}>
                  {m.question.slice(0, 55)}{m.question.length > 55 ? '…' : ''}
                  {' '}({m.submissionCount}/{m.maxSubmissions})
                </option>
              ))}
            </select>
          </div>

          {selectedMarket && (
            <>
              {/* Market info row */}
              <div className="grid grid-cols-2 gap-2 text-xs">
                {[
                  ['Mode', modeLabel(selectedMarket.resolutionMode)],
                  ['Min confidence', `${(selectedMarket.minTagConfidence / 100).toFixed(0)}%`],
                  ['Window', timeLeft(selectedMarket.timeWindowEnd)],
                  ['Submissions', `${selectedMarket.submissionCount} / ${selectedMarket.maxSubmissions}`],
                ].map(([k, v]) => (
                  <div key={k} className="flex justify-between p-2 rounded-lg bg-black/20 border border-white/5">
                    <span className="text-gray-400">{k}</span>
                    <span className={v === 'Closed' ? 'text-red-400' : 'text-white'}>{v}</span>
                  </div>
                ))}
              </div>

              {/* Submission fill bar */}
              <div className="h-1.5 rounded-full bg-white/5 overflow-hidden">
                <div className="h-full rounded-full bg-gradient-to-r from-cyan-500 to-blue-500"
                  style={{ width: `${Math.round(selectedMarket.submissionCount / selectedMarket.maxSubmissions * 100)}%` }}
                />
              </div>

              {/* Content type */}
              <div>
                <label className="block text-xs text-gray-400 mb-1.5">Content type</label>
                <div className="flex gap-1 p-1 rounded-lg bg-white/5">
                  {([0, 1] as const).map(t => (
                    <button key={t} onClick={() => setContentType(t)}
                      className={`flex-1 py-2 rounded-md text-xs font-medium transition-all ${
                        contentType === t ? 'bg-white/10 text-white' : 'text-gray-400 hover:text-white'
                      }`}>
                      {t === 0 ? '🎵 Audio' : '📹 Video'}
                    </button>
                  ))}
                </div>
              </div>

              {/* Blob note */}
              <div>
                <label className="block text-xs text-gray-400 mb-1.5">
                  Attestation note
                  <span className="ml-2 text-gray-600 font-normal">(SHA256 hashed · blank = random)</span>
                </label>
                <textarea
                  value={blobNote}
                  onChange={e => setBlobNote(e.target.value)}
                  rows={2}
                  placeholder="Production: necklace firmware provides the blob hash. Leave blank for random."
                  className="w-full px-4 py-3 rounded-xl bg-black/30 border border-white/10 text-white
                             text-xs placeholder:text-gray-600 resize-none focus:outline-none focus:border-cyan-500/50"
                />
                <p className="text-[10px] text-gray-600 mt-1">
                  The full audio/video blob lives on 0G Storage. Only SHA256(blob) is stored on-chain.
                  The oracle fetches and verifies the full blob at resolution time inside CoCo.
                </p>
              </div>

              {/* Submit button */}
              <button
                onClick={handleSubmit}
                disabled={!connected || submitting || txMutex
                  || selectedMarket.submissionCount >= selectedMarket.maxSubmissions
                  || selectedMarket.timeWindowEnd < Date.now() / 1000}
                className={`w-full py-3 rounded-xl font-semibold text-sm transition-all ${
                  !connected || submitting
                    ? 'bg-gray-700 text-gray-500 cursor-not-allowed'
                    : 'bg-gradient-to-r from-cyan-500 to-blue-500 text-white hover:shadow-lg hover:shadow-cyan-500/25'
                }`}
              >
                {submitting ? 'Submitting…' : '📤 Submit Evidence'}
              </button>

              {submitStatus && (
                <div className={`p-3 rounded-xl text-xs ${
                  submitStatus.startsWith('✓')
                    ? 'bg-green-500/10 border border-green-500/20 text-green-300'
                    : 'bg-red-500/10 border border-red-500/20 text-red-300'
                }`}>
                  {submitStatus}
                </div>
              )}

              {/* My submissions for this market */}
              {myMarketSubmissions.length > 0 && (
                <div>
                  <p className="text-xs text-gray-400 mb-2">Your submissions</p>
                  <div className="space-y-1.5">
                    {myMarketSubmissions.map(s => (
                      <div key={s.pda}
                        className="flex items-center justify-between px-3 py-2 rounded-lg bg-black/20 border border-white/5 text-xs">
                        <div className="flex items-center gap-2">
                          <span className="text-gray-300">nonce={s.nonce}</span>
                          <span className="text-gray-600">·</span>
                          <span>{s.contentType === 0 ? '🎵' : '📹'}</span>
                          <span className="font-mono text-gray-400">{hexShort(s.attestationHash)}</span>
                        </div>
                        <span className="text-gray-500">{timeAgo(s.submittedAt)}</span>
                      </div>
                    ))}
                  </div>
                </div>
              )}
            </>
          )}

          {evidenceMarkets.length === 0 && (
            <div className="p-8 rounded-xl bg-black/20 border border-white/5 text-center">
              <p className="text-gray-400 text-sm">No evidence-gated markets</p>
              <p className="text-gray-600 text-xs mt-1">
                Markets appear after creator calls initMarketEvidence (with ≥1 required tag)
              </p>
            </div>
          )}

          <button onClick={refreshMarkets}
            className="w-full py-2 rounded-lg text-xs text-gray-400 hover:text-white bg-white/5 hover:bg-white/10 transition-all">
            ↻ Refresh
          </button>
        </div>
      )}

      {/* ── NOTIFICATIONS ───────────────────────────────────────────────────── */}
      {subTab === 'notifications' && (
        <div className="space-y-3">
          <p className="text-xs text-gray-500 leading-relaxed px-1">
            Match notifications are written by the oracle after pairwise cosine similarity
            exceeds 72% inside CoCo. The counterparty is blinded on-chain — the oracle
            delivers the nonce off-chain to let you reveal who matched.
          </p>

          {myNotifications.length === 0 ? (
            <div className="p-8 rounded-xl bg-black/20 border border-white/5 text-center">
              <p className="text-gray-400 text-sm">No match notifications yet</p>
              <p className="text-gray-600 text-xs mt-1">
                Oracle runs match_compare after your category reaches 10+ devices
              </p>
            </div>
          ) : myNotifications.map(n => (
            <div key={n.pda}
              className={`p-4 rounded-xl border transition-all ${
                n.read ? 'bg-black/20 border-white/5' : 'bg-cyan-500/5 border-cyan-500/20'
              }`}>
              <div className="flex items-start justify-between gap-3">
                <div className="flex-1 min-w-0 space-y-2">
                  <div className="flex items-center gap-2">
                    {!n.read && <span className="w-2 h-2 rounded-full bg-cyan-400 shrink-0" />}
                    <span className="text-sm font-medium text-white">
                      {(n.similarityBps / 100).toFixed(1)}% similarity
                    </span>
                    <span className="text-xs text-gray-500">slot {n.slot}</span>
                  </div>
                  <div className="grid grid-cols-2 gap-x-4 gap-y-1 text-xs">
                    <span className="text-gray-400">Category</span>
                    <span className="font-mono text-gray-300">{hexShort(n.categoryHash)}</span>
                    <span className="text-gray-400">Counterparty</span>
                    <span className="font-mono text-gray-300">{hexShort(n.counterpartyCommitment)}</span>
                  </div>
                  {n.read && <p className="text-xs text-gray-600">Acknowledged</p>}
                </div>
                {!n.read && (
                  <button onClick={() => handleAck(n)} disabled={acking === n.pda}
                    className="shrink-0 px-3 py-1.5 rounded-lg text-xs font-medium bg-cyan-500/20
                               text-cyan-300 hover:bg-cyan-500/30 transition-all disabled:opacity-50">
                    {acking === n.pda ? '…' : 'Ack'}
                  </button>
                )}
              </div>
            </div>
          ))}

          <button onClick={refreshNotifications}
            className="w-full py-2 rounded-lg text-xs text-gray-400 hover:text-white bg-white/5 hover:bg-white/10 transition-all">
            ↻ Refresh
          </button>
        </div>
      )}

      {/* ── PIPELINE STATUS ─────────────────────────────────────────────────── */}
      {subTab === 'status' && (
        <div className="space-y-3">
          <p className="text-xs text-gray-500 px-1">
            Matching pipeline: evidence submitted → oracle projects into 16 LSH buckets
            → pairwise cosine similarity inside CoCo → MatchNotification PDAs written.
          </p>

          {/* Pipeline stages diagram */}
          <div className="flex items-center gap-1 text-[10px] text-gray-500 px-1 overflow-x-auto">
            {['submitEvidence', '→', 'match_project', '→', 'BucketAssignment', '→',
              'match_compare (×16)', '→', 'MatchNotification'].map((s, i) => (
              <span key={i} className={s === '→' ? 'text-gray-700' :
                'px-2 py-1 rounded bg-white/5 whitespace-nowrap'}>{s}</span>
            ))}
          </div>

          {bucketStatuses.length === 0 ? (
            <div className="p-8 rounded-xl bg-black/20 border border-white/5 text-center">
              <p className="text-gray-400 text-sm">No active categories</p>
              <p className="text-gray-600 text-xs mt-1">
                Categories appear when ≥10 devices have evidence in the same category
              </p>
            </div>
          ) : bucketStatuses.map(b => (
            <div key={b.categoryHashHex} className="p-4 rounded-xl bg-black/20 border border-white/5">
              <div className="flex items-center justify-between mb-2">
                <span className="font-mono text-xs text-gray-300">{b.categoryHashHex.slice(0, 24)}…</span>
                <div className="flex items-center gap-2">
                  <span className={`px-2 py-0.5 rounded-full text-[10px] font-medium ${
                    b.matchCount > 0
                      ? 'bg-green-500/20 text-green-300'
                      : b.projected
                        ? 'bg-blue-500/20 text-blue-300'
                        : 'bg-yellow-500/20 text-yellow-300'
                  }`}>
                    {b.matchCount > 0 ? `${b.matchCount} matched` : b.projected ? 'Projected' : 'Pending'}
                  </span>
                </div>
              </div>
              <div className="flex items-center gap-4 text-xs text-gray-500">
                <span>devices: {b.deviceCount}</span>
                <span className={`flex items-center gap-1 ${b.projected ? 'text-blue-400' : ''}`}>
                  {b.projected ? '✓' : '○'} match_project
                </span>
                <span className={`flex items-center gap-1 ${b.matchCount > 0 ? 'text-green-400' : ''}`}>
                  {b.matchCount > 0 ? '✓' : '○'} match_compare
                </span>
              </div>
            </div>
          ))}
        </div>
      )}
    </div>
  )
}
