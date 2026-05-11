/**
 * /api  — single route file for all server-side actions
 *
 * POST   { action: "confidence_store", ...fields }
 *          → upsert {confidence, salt, commitHash, evidenceUrl?, evidenceContentHash?, evidenceUserSig?}
 * GET    ?action=confidence_fetch&mktId=&chainId=&user=&side=
 *          → fetch confidences (keeper reads to auto-reveal)
 * DELETE ?action=confidence_delete&user=&mktId=&chainId=&side=
 *
 * POST   { action: "enroll", walletPubkey }
 *          → enroll web wallet on-chain (keeper signs the enroll_device tx)
 * POST   { action: "cosign", walletPubkey, txBase64 }
 *          → keeper-cosigns gated user txs (exposure-growth path in Withdraw)
 *
 * POST   { action: "evidence_upload", mktPda, mktId, chainId, user,
 *          filename, mimeType, bytesBase64, signature, commitHash }
 *          → verify ed25519 sig over (mktPda || commitHash || contentHash) against
 *            user's Solana wallet pubkey, store bytes content-addressed
 * GET    ?action=evidence_fetch&contentHash=
 *          → keeper fetches uploaded bytes by content hash (for Files API upload)
 * GET    /api/threads/{marketId}.json?chainId=
 *          → keeper-published canonical resolution transcript (set by `thread_publish`)
 * POST   { action: "thread_publish", marketId, chainId, canonicalJson }
 *          → keeper writes canonical JSON; contentHash returned for on-chain pin
 */

import { NextRequest, NextResponse } from 'next/server'
import {
  Connection, Keypair, PublicKey, Transaction,
  SystemProgram, sendAndConfirmTransaction,
} from '@solana/web3.js'
import nacl from 'tweetnacl'
import { createHash } from 'crypto'
import bs58 from 'bs58'
import { getDb, type ConfidenceDoc, type EvidenceDoc, type ThreadDoc } from '@/lib/mongo'

// ── Keypairs + constants ─────────────────────────────────────────────────────

function loadKeypair(envVar: string): Keypair {
  const raw = process.env[envVar]
  if (!raw) throw new Error(`${envVar} is not set`)
  try {
    // JSON array format: [1,2,3,...] (matches Solana CLI output)
    return Keypair.fromSecretKey(Uint8Array.from(JSON.parse(raw)))
  } catch {
    // bs58 format
    return Keypair.fromSecretKey(bs58.decode(raw))
  }
}

// Single keeper key — replaces orchestrator + web_cosigner. Same trust model:
// signs enroll_device, cosigns gated user txs, signs resolve/resolve_challenge,
// publishes resolution transcripts. To split rotation again later, keep the
// helpers parameterised by Keypair and load two distinct env vars.
const KEEPER         = loadKeypair('KEEPER_SECRET_KEY')
const CONNECTION     = new Connection(process.env.RPC_URL!, 'confirmed')
const PROGRAM_ID     = new PublicKey('HFNXYaADSSToPmgSpV6Jnsd3UcyKdkhHt5T8Am2c7wRe')
const ALLOWED_ORIGIN = process.env.ALLOWED_ORIGIN!

const REVOKED_OFFSET  = 44
const PLATFORM_OFFSET = 45
const PLATFORM_WEB    = 2
const CONFIG_VERSION_OFFSET = 242  // see state.rs SPACE comment

// Evidence upload caps
const MAX_EVIDENCE_BYTES_PER_FILE = 10 * 1024 * 1024  // 10 MB
const MAX_EVIDENCE_BYTES_PER_MARKET = 100 * 1024 * 1024 // 100 MB

// ── Config version cache ─────────────────────────────────────────────────────

let cachedConfigVersion: number | null = null
let configVersionFetchedAt = 0
const CONFIG_VERSION_TTL_MS = 60_000

async function getConfigVersion(): Promise<number> {
  const now = Date.now()
  if (cachedConfigVersion !== null && now - configVersionFetchedAt < CONFIG_VERSION_TTL_MS) {
    return cachedConfigVersion
  }
  const [configPda] = PublicKey.findProgramAddressSync([Buffer.from('program_config')], PROGRAM_ID)
  const info = await CONNECTION.getAccountInfo(configPda)
  if (!info) throw new Error('ProgramConfig account not found')
  cachedConfigVersion = info.data.readUInt32LE(CONFIG_VERSION_OFFSET)
  configVersionFetchedAt = now
  return cachedConfigVersion
}

// ── Shared: validate enrollment PDA ─────────────────────────────────────────

async function checkEnrollment(wallet: PublicKey): Promise<
  { ok: true; pda: PublicKey } | { ok: false; error: string; status: number }
> {
  const [pda] = PublicKey.findProgramAddressSync(
    [Buffer.from('device_enrollment'), wallet.toBuffer()], PROGRAM_ID
  )
  const info = await CONNECTION.getAccountInfo(pda)
  if (!info)                                   return { ok: false, error: 'not enrolled', status: 403 }
  if (info.data[REVOKED_OFFSET])               return { ok: false, error: 'enrollment revoked', status: 403 }
  if (info.data[PLATFORM_OFFSET] !== PLATFORM_WEB) return { ok: false, error: 'not a web enrollment', status: 400 }
  return { ok: true, pda }
}

// ── POST handlers ────────────────────────────────────────────────────────────

async function handleConfidenceStore(body: any): Promise<NextResponse> {
  const {
    user, mktId, side, confidence, salt, chainId, commitHash,
    evidenceUrl, evidenceUrlHash, evidenceContentHash, evidenceUserSig,
  } = body
  if (!user || mktId === undefined || side === undefined || !confidence || !salt || !chainId || !commitHash)
    return NextResponse.json({ error: 'Missing required fields' }, { status: 400 })
  if (confidence < 100 || confidence > 10000 || confidence % 100 !== 0)
    return NextResponse.json({ error: 'Confidence must be 100-10000 in steps of 100' }, { status: 400 })

  const db = await getDb()
  await db.collection<ConfidenceDoc>('confidences').updateOne(
    { commitHash },
    { $set: {
        user: user.toLowerCase(), mktId, side, confidence, salt,
        commitHash, chainId, createdAt: new Date(),
        ...(evidenceUrl ? { evidenceUrl } : {}),
        ...(evidenceUrlHash ? { evidenceUrlHash } : {}),
        ...(evidenceContentHash ? { evidenceContentHash } : {}),
        ...(evidenceUserSig ? { evidenceUserSig } : {}),
      } },
    { upsert: true }
  )
  return NextResponse.json({ ok: true })
}

async function handleEnroll(walletPubkey: string): Promise<NextResponse> {
  let wallet: PublicKey
  try { wallet = new PublicKey(walletPubkey) }
  catch { return NextResponse.json({ error: 'invalid wallet pubkey' }, { status: 400 }) }

  const check = await checkEnrollment(wallet)
  if (check.ok) return NextResponse.json({ ok: true, alreadyEnrolled: true })

  let configVersion: number
  try { configVersion = await getConfigVersion() }
  catch (err: any) { return NextResponse.json({ error: err.message }, { status: 500 }) }

  // sha256("global:enroll_device")[0..8] — regenerate from IDL after anchor build
  const discriminator = Buffer.from([0x6f, 0x44, 0x3a, 0x2e, 0xb2, 0x1a, 0x5c, 0x9d])
  const params = Buffer.alloc(37)
  wallet.toBuffer().copy(params, 0)
  params.writeUInt32LE(configVersion, 32)
  params.writeUInt8(PLATFORM_WEB, 36)

  const [configPda] = PublicKey.findProgramAddressSync([Buffer.from('program_config')], PROGRAM_ID)
  const [enrollmentPda] = PublicKey.findProgramAddressSync(
    [Buffer.from('device_enrollment'), wallet.toBuffer()], PROGRAM_ID
  )
  const ix = {
    programId: PROGRAM_ID,
    keys: [
      { pubkey: KEEPER.publicKey,        isSigner: true,  isWritable: true  },
      { pubkey: configPda,               isSigner: false, isWritable: false },
      { pubkey: enrollmentPda,           isSigner: false, isWritable: true  },
      { pubkey: wallet,                  isSigner: false, isWritable: false },
      { pubkey: SystemProgram.programId, isSigner: false, isWritable: false },
    ],
    data: Buffer.concat([discriminator, params]),
  }
  try {
    const { blockhash } = await CONNECTION.getLatestBlockhash()
    const tx = new Transaction({ recentBlockhash: blockhash, feePayer: KEEPER.publicKey })
    tx.add(ix)
    const sig = await sendAndConfirmTransaction(CONNECTION, tx, [KEEPER])
    return NextResponse.json({ ok: true, signature: sig })
  } catch (err: any) {
    console.error('enroll_device failed:', err)
    return NextResponse.json({ error: err.message || 'enroll failed' }, { status: 500 })
  }
}

async function handleCosign(walletPubkey: string, txBase64: string): Promise<NextResponse> {
  let wallet: PublicKey
  try { wallet = new PublicKey(walletPubkey) }
  catch { return NextResponse.json({ error: 'invalid wallet pubkey' }, { status: 400 }) }

  const check = await checkEnrollment(wallet)
  if (!check.ok) return NextResponse.json({ error: check.error }, { status: check.status })

  let tx: Transaction
  try { tx = Transaction.from(Buffer.from(txBase64, 'base64')) }
  catch { return NextResponse.json({ error: 'invalid transaction' }, { status: 400 }) }

  tx.partialSign(KEEPER)
  return NextResponse.json({ txBase64: tx.serialize({ requireAllSignatures: false }).toString('base64') })
}

/**
 * Evidence upload. The bidder signs (mktPda || commitHash || contentHash) with
 * their Solana wallet. Server verifies the ed25519 sig before storing the bytes.
 *
 * - Indexed by sha256(bytes), so a 404 on the URL doesn't matter — bytes are
 *   recoverable as long as anyone knows the hash. The on-chain commit binds the
 *   bidder to *some* hash, the keeper can verify served bytes match.
 * - Per-file cap 10 MB, per-market cap 100 MB. Caps protect mongo + keeper.
 * - First upload wins; same hash → noop (idempotent).
 */
async function handleEvidenceUpload(body: any): Promise<NextResponse> {
  const { mktPda, mktId, chainId, user, filename, mimeType,
          bytesBase64, signature, commitHash } = body
  if (!mktPda || mktId === undefined || !chainId || !user
        || !bytesBase64 || !signature || !commitHash) {
    return NextResponse.json({ error: 'Missing required fields' }, { status: 400 })
  }

  const bytes = Buffer.from(bytesBase64, 'base64')
  if (bytes.length === 0)
    return NextResponse.json({ error: 'empty upload' }, { status: 400 })
  if (bytes.length > MAX_EVIDENCE_BYTES_PER_FILE)
    return NextResponse.json({ error: 'file too large (>10MB)' }, { status: 413 })

  const contentHash = createHash('sha256').update(bytes).digest('hex')

  // Verify ed25519 signature over (mktPda || commitHashBytes || contentHashBytes)
  // signed by `user` (Solana wallet pubkey, base58).
  let userPk: PublicKey
  try { userPk = new PublicKey(user) }
  catch { return NextResponse.json({ error: 'invalid user pubkey' }, { status: 400 }) }

  let mktPdaPk: PublicKey
  try { mktPdaPk = new PublicKey(mktPda) }
  catch { return NextResponse.json({ error: 'invalid mktPda' }, { status: 400 }) }

  let commitHashHex = commitHash.startsWith('0x') ? commitHash.slice(2) : commitHash
  if (commitHashHex.length !== 64)
    return NextResponse.json({ error: 'commitHash must be 32-byte hex' }, { status: 400 })

  const message = Buffer.concat([
    mktPdaPk.toBuffer(),
    Buffer.from(commitHashHex, 'hex'),
    Buffer.from(contentHash, 'hex'),
  ])

  let sigBytes: Uint8Array
  try {
    const sigHex = signature.startsWith('0x') ? signature.slice(2) : signature
    sigBytes = sigHex.length === 128
      ? Uint8Array.from(Buffer.from(sigHex, 'hex'))
      : bs58.decode(signature)
  } catch {
    return NextResponse.json({ error: 'invalid signature encoding' }, { status: 400 })
  }
  if (sigBytes.length !== 64)
    return NextResponse.json({ error: 'signature must be 64 bytes' }, { status: 400 })

  const ok = nacl.sign.detached.verify(
    Uint8Array.from(message), sigBytes, userPk.toBytes()
  )
  if (!ok) return NextResponse.json({ error: 'signature verification failed' }, { status: 401 })

  const db = await getDb()
  const evidence = db.collection<EvidenceDoc>('evidence')

  // Per-market cap check
  const cursor = evidence.aggregate([
    { $match: { mktId, chainId } },
    { $group: { _id: null, total: { $sum: '$size' } } },
  ])
  const agg = await cursor.toArray()
  const usedBytes = agg.length ? (agg[0] as any).total : 0
  if (usedBytes + bytes.length > MAX_EVIDENCE_BYTES_PER_MARKET) {
    return NextResponse.json({ error: 'market evidence cap exceeded (100MB)' }, { status: 413 })
  }

  // Idempotent on contentHash — first upload wins.
  await evidence.updateOne(
    { contentHash },
    { $setOnInsert: {
        contentHash, mktId, chainId,
        user: user.toLowerCase(), filename: filename || '',
        mimeType: mimeType || 'application/octet-stream',
        bytes, size: bytes.length, createdAt: new Date(),
      } },
    { upsert: true }
  )

  return NextResponse.json({ ok: true, contentHash, size: bytes.length })
}

/**
 * Keeper publishes the canonical resolution transcript JSON.
 * Returns the keccak256 hash so the keeper can pin it on-chain via resolve().
 *
 * Auth: signed by the keeper's request — for self-hosted demo we accept any
 * caller (single keeper). For multi-keeper rotation, gate on KEEPER pubkey or
 * a bearer token.
 */
async function handleThreadPublish(body: any): Promise<NextResponse> {
  const { marketId, chainId, canonicalJson } = body
  if (marketId === undefined || !chainId || typeof canonicalJson !== 'string')
    return NextResponse.json({ error: 'Missing required fields' }, { status: 400 })

  const contentHash = createHash('sha256').update(canonicalJson).digest('hex')

  const db = await getDb()
  await db.collection<ThreadDoc>('threads').updateOne(
    { marketId, chainId },
    { $set: { marketId, chainId, contentHash, canonicalJson, publishedAt: new Date() } },
    { upsert: true }
  )

  return NextResponse.json({ ok: true, contentHash })
}

// ── POST ─────────────────────────────────────────────────────────────────────

export async function POST(req: NextRequest) {
  if (req.headers.get('origin') !== ALLOWED_ORIGIN)
    return NextResponse.json({ error: 'forbidden' }, { status: 403 })

  let body: Record<string, any>
  try { body = await req.json() }
  catch { return NextResponse.json({ error: 'invalid JSON' }, { status: 400 }) }

  try {
    switch (body.action) {
      case 'confidence_store':
        return await handleConfidenceStore(body)
      case 'enroll':
        if (!body.walletPubkey) return NextResponse.json({ error: 'walletPubkey required' }, { status: 400 })
        return await handleEnroll(body.walletPubkey)
      case 'cosign':
        if (!body.walletPubkey || !body.txBase64) return NextResponse.json({ error: 'walletPubkey and txBase64 required' }, { status: 400 })
        return await handleCosign(body.walletPubkey, body.txBase64)
      case 'evidence_upload':
        return await handleEvidenceUpload(body)
      case 'thread_publish':
        return await handleThreadPublish(body)
      default:
        return NextResponse.json({ error: 'unknown action' }, { status: 400 })
    }
  } catch (err: any) {
    console.error('POST /api error:', err)
    return NextResponse.json({ error: err.message || 'Internal error' }, { status: 500 })
  }
}

// ── GET ──────────────────────────────────────────────────────────────────────

export async function GET(req: NextRequest) {
  const { searchParams } = new URL(req.url)
  const action = searchParams.get('action')

  if (action === 'confidence_fetch') {
    try {
      const mktId   = searchParams.get('mktId')
      const chainId = searchParams.get('chainId')
      if (!mktId || !chainId) return NextResponse.json({ error: 'mktId, chainId required' }, { status: 400 })

      const filter: any = { mktId: parseInt(mktId), chainId: parseInt(chainId) }
      const user = searchParams.get('user')
      const side = searchParams.get('side')
      if (user) filter.user = user.toLowerCase()
      if (side !== null) filter.side = parseInt(side)

      const db = await getDb()
      const confidences = await db.collection<ConfidenceDoc>('confidences')
        .find(filter).sort({ createdAt: 1 }).toArray()
      return NextResponse.json({ confidences })
    } catch (err: any) {
      return NextResponse.json({ error: err.message || 'Internal error' }, { status: 500 })
    }
  }

  if (action === 'evidence_fetch') {
    try {
      const contentHash = searchParams.get('contentHash')
      if (!contentHash) return NextResponse.json({ error: 'contentHash required' }, { status: 400 })

      const db = await getDb()
      const doc = await db.collection<EvidenceDoc>('evidence').findOne({ contentHash })
      if (!doc) return NextResponse.json({ error: 'not found' }, { status: 404 })

      // Stream bytes back as base64 — keeper decodes and forwards to Anthropic Files API.
      // (For larger blobs, switch to streaming response.)
      const bytes = doc.bytes instanceof Buffer ? doc.bytes : Buffer.from(doc.bytes as any)
      return NextResponse.json({
        contentHash: doc.contentHash,
        filename: doc.filename, mimeType: doc.mimeType,
        size: doc.size, bytesBase64: bytes.toString('base64'),
      })
    } catch (err: any) {
      return NextResponse.json({ error: err.message || 'Internal error' }, { status: 500 })
    }
  }

  return NextResponse.json({ error: 'unknown action' }, { status: 400 })
}

// ── DELETE ───────────────────────────────────────────────────────────────────

export async function DELETE(req: NextRequest) {
  const { searchParams } = new URL(req.url)
  const action = searchParams.get('action')

  if (action === 'confidence_delete') {
    try {
      const user    = searchParams.get('user')
      const mktId   = searchParams.get('mktId')
      const chainId = searchParams.get('chainId')
      if (!user || !mktId || !chainId) return NextResponse.json({ error: 'user, mktId, chainId required' }, { status: 400 })

      const filter: any = { user: user.toLowerCase(), mktId: parseInt(mktId), chainId: parseInt(chainId) }
      const side = searchParams.get('side')
      if (side !== null) filter.side = parseInt(side)

      const db = await getDb()
      const result = await db.collection<ConfidenceDoc>('confidences').deleteMany(filter)
      return NextResponse.json({ ok: true, deleted: result.deletedCount })
    } catch (err: any) {
      return NextResponse.json({ error: err.message || 'Internal error' }, { status: 500 })
    }
  }

  return NextResponse.json({ error: 'unknown action' }, { status: 400 })
}
