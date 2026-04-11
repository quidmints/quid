/**
 * API route: /api/confidences
 *
 * POST — Store a confidence commitment (one per entry, keyed by commitHash)
 * GET  — Retrieve stored confidences for a user/market/side
 * DELETE — Remove old entries for a user/market/side (used on recommit/new round)
 *
 * Each placeOrder creates a new entry with a unique commitHash.
 * batchReveal needs ALL entries for a position, in chronological order.
 */

import { NextRequest, NextResponse } from 'next/server'
import { getDb, type ConfidenceDoc } from '@/lib/mongo'

export async function POST(req: NextRequest) {
  try {
    const body = await req.json()
    const { user, mktId, side, confidence, salt, chainId, commitHash } = body

    if (!user || mktId === undefined || side === undefined || !confidence || !salt || !chainId || !commitHash) {
      return NextResponse.json({ error: 'Missing required fields' }, { status: 400 })
    }
    if (confidence < 100 || confidence > 10000 || confidence % 100 !== 0) {
      return NextResponse.json({ error: 'Confidence must be 100-10000 in steps of 100' }, { status: 400 })
    }

    const db = await getDb()
    const collection = db.collection<ConfidenceDoc>('confidences')

    // Upsert by commitHash — each entry is unique by its hash
    // Multiple orders on same side = multiple docs (different commitHashes)
    await collection.updateOne(
      { commitHash },
      {
        $set: {
          user: user.toLowerCase(),
          mktId,
          side,
          confidence,
          salt,
          commitHash,
          chainId,
          createdAt: new Date(),
        },
      },
      { upsert: true }
    )

    return NextResponse.json({ ok: true })
  } catch (err: any) {
    console.error('POST /api/confidences error:', err)
    return NextResponse.json({ error: err.message || 'Internal error' }, { status: 500 })
  }
}

export async function GET(req: NextRequest) {
  try {
    const { searchParams } = new URL(req.url)
    const user = searchParams.get('user')
    const mktId = searchParams.get('mktId')
    const side = searchParams.get('side')
    const chainId = searchParams.get('chainId')

    if (!mktId || !chainId) {
      return NextResponse.json({ error: 'mktId, chainId required' }, { status: 400 })
    }

    const db = await getDb()
    const collection = db.collection<ConfidenceDoc>('confidences')

    const filter: any = {
      mktId: parseInt(mktId),
      chainId: parseInt(chainId),
    }
    if (user) {
      filter.user = user.toLowerCase()
    }
    if (side !== null && side !== undefined) {
      filter.side = parseInt(side)
    }

    // Sort by createdAt — batchReveal needs entries in chronological order
    const confidences = await collection.find(filter).sort({ createdAt: 1 }).toArray()

    return NextResponse.json({ confidences })
  } catch (err: any) {
    console.error('GET /api/confidences error:', err)
    return NextResponse.json({ error: err.message || 'Internal error' }, { status: 500 })
  }
}

export async function DELETE(req: NextRequest) {
  try {
    const { searchParams } = new URL(req.url)
    const user = searchParams.get('user')
    const mktId = searchParams.get('mktId')
    const side = searchParams.get('side')
    const chainId = searchParams.get('chainId')

    if (!user || !mktId || !chainId) {
      return NextResponse.json({ error: 'user, mktId, chainId required' }, { status: 400 })
    }

    const db = await getDb()
    const collection = db.collection<ConfidenceDoc>('confidences')

    const filter: any = {
      user: user.toLowerCase(),
      mktId: parseInt(mktId),
      chainId: parseInt(chainId),
    }
    if (side !== null && side !== undefined) {
      filter.side = parseInt(side)
    }

    const result = await collection.deleteMany(filter)
    return NextResponse.json({ ok: true, deleted: result.deletedCount })
  } catch (err: any) {
    console.error('DELETE /api/confidences error:', err)
    return NextResponse.json({ error: err.message || 'Internal error' }, { status: 500 })
  }
}
