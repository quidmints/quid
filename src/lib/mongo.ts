/**
 * MongoDB connection helper for QU!D Protocol
 *
 * Stores commit-reveal data:
 *   - confidences  : per-bid {confidence, salt, evidenceUrl, evidenceContentHash, commitHash}
 *   - evidence     : content-addressed bytes (uploaded user evidence, indexed by sha256 of bytes)
 *   - threads      : keeper-published canonical resolution transcripts {marketId → JSON}
 *
 * Setup on your SSH machine:
 *   1. Install MongoDB:
 *        sudo apt-get install -y gnupg curl
 *        curl -fsSL https://www.mongodb.org/static/pgp/server-7.0.asc | sudo gpg -o /usr/share/keyrings/mongodb-server-7.0.gpg --dearmor
 *        echo "deb [ signed-by=/usr/share/keyrings/mongodb-server-7.0.gpg ] https://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/7.0 multiverse" | sudo tee /etc/apt/sources.list.d/mongodb-org-7.0.list
 *        sudo apt-get update && sudo apt-get install -y mongodb-org
 *        sudo systemctl enable --now mongod
 *
 *   2. Or use Docker:
 *        docker run -d --name mongo -p 27017:27017 -v mongo-data:/data/db mongo:7
 *
 *   3. Set environment variable:
 *        MONGODB_URI=mongodb://localhost:27017/quid
 *
 *   4. Add to .env.local (Next.js picks this up):
 *        MONGODB_URI=mongodb://localhost:27017/quid
 *
 *   5. Install driver:
 *        npm install mongodb
 */

import { MongoClient, type Db } from 'mongodb'

const MONGODB_URI = process.env.MONGODB_URI || 'mongodb://localhost:27017/quid'

let client: MongoClient | null = null
let db: Db | null = null

export async function getDb(): Promise<Db> {
  if (db) return db

  client = new MongoClient(MONGODB_URI)
  await client.connect()
  db = client.db() // uses db name from URI (defaults to 'quid')

  // confidences — commit-reveal store, one doc per (commitHash)
  const confidences = db.collection('confidences')
  await confidences.createIndex({ commitHash: 1 }, { unique: true })
  await confidences.createIndex({ user: 1, mktId: 1, side: 1, chainId: 1 })
  await confidences.createIndex({ chainId: 1, mktId: 1 })

  // evidence — content-addressed bytes, one doc per (contentHash)
  // NOTE: bytes stored as Buffer (Mongo BinData). Cap enforced at write time.
  const evidence = db.collection('evidence')
  await evidence.createIndex({ contentHash: 1 }, { unique: true })
  await evidence.createIndex({ mktId: 1, chainId: 1 })

  // threads — keeper-published resolution transcripts
  const threads = db.collection('threads')
  await threads.createIndex({ marketId: 1, chainId: 1 }, { unique: true })

  console.log('✅ MongoDB connected:', MONGODB_URI)
  return db
}

/**
 * One commit-reveal entry.
 *
 * commitHash = keccak256( le8(confidence) || evidenceUrlHash || salt )
 *   evidenceUrlHash = keccak256(utf8(evidenceUrl)), or zero32 for no-evidence bids.
 *
 * evidenceContentHash is the sha256 of the actual uploaded bytes (not the URL).
 * The on-chain RevealEntry only carries evidenceUrlHash; contentHash is kept
 * here so the keeper can verify served bytes match what the bidder uploaded.
 */
export interface ConfidenceDoc {
  user: string                   // wallet address (lowercase, base58 for Solana / hex for EVM)
  mktId: number                  // market ID
  side: number                   // outcome index (Solana) / side (EVM 0=no-depeg, 1..N=stables)
  confidence: number             // 500-10000 (step 500 on Solana, 100 on EVM Hook)
  salt: string                   // 32-byte hex
  commitHash: string             // hex, on-chain commitment
  evidenceUrl?: string           // optional: where the keeper can fetch evidence
  evidenceUrlHash?: string       // hex, keccak256(utf8(evidenceUrl)) — bound into commit
  evidenceContentHash?: string   // hex, sha256 of uploaded bytes
  evidenceUserSig?: string       // hex, ed25519 sig over (mktPda || commitHash || contentHash)
  chainId: number
  createdAt: Date
}

/** One uploaded evidence blob, content-addressed. */
export interface EvidenceDoc {
  contentHash: string            // hex sha256, primary key
  mktId: number
  chainId: number
  user: string                   // wallet that uploaded (lowercase / base58)
  filename: string               // user-supplied (display only)
  mimeType: string
  bytes: Buffer                  // BinData in Mongo
  size: number
  createdAt: Date
}

/** Keeper-published canonical resolution transcript for a market. */
export interface ThreadDoc {
  marketId: number
  chainId: number
  /** keccak256 of the canonical JSON (matches market.thread_content_hash on-chain) */
  contentHash: string
  /** Canonical JSON: {systemPrompt, evidenceManifest, claudeMessages, verdict} */
  canonicalJson: string
  publishedAt: Date
}
