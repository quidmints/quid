/**
 * MongoDB connection helper for QU!D Protocol
 *
 * Stores confidence data for the commit-reveal scheme in Hook.sol
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

  // Create indexes for efficient queries
  const confidences = db.collection('confidences')
  await confidences.createIndex({ commitHash: 1 }, { unique: true })
  await confidences.createIndex({ user: 1, mktId: 1, side: 1, chainId: 1 })
  await confidences.createIndex({ chainId: 1, mktId: 1 })

  console.log('✅ MongoDB connected:', MONGODB_URI)
  return db
}

export interface ConfidenceDoc {
  user: string      // wallet address (lowercase)
  mktId: number     // market ID
  side: number      // side (0 = no depeg, 1..N = stablecoins)
  confidence: number // 100-10000 (step 100)
  salt: string      // bytes32 hex string
  commitHash: string // keccak256(abi.encodePacked(confidence, salt))
  chainId: number
  createdAt: Date
}
