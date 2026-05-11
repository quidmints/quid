/**
 * GET /api/threads/{marketId}.json?chainId=
 *
 * Returns the canonical resolution transcript JSON published by the keeper
 * via POST /api?action=thread_publish. Used by:
 *   - jurors during a force_jury challenge to verify on-chain
 *     market.thread_content_hash matches the served bytes
 *   - anyone curious about how a market resolved
 *
 * Note: the URL stored on-chain is .../api/threads/{marketId}.json. Next.js
 * dynamic routes capture {marketId} including the .json suffix, so we strip
 * it before lookup.
 */

import { NextRequest, NextResponse } from 'next/server'
import { getDb, type ThreadDoc } from '@/lib/mongo'

export async function GET(
  req: NextRequest,
  { params }: { params: { marketId: string } },
) {
  const raw = params.marketId
  // Accept .../{id}.json or .../{id}
  const idStr = raw.endsWith('.json') ? raw.slice(0, -5) : raw
  const marketId = parseInt(idStr, 10)
  if (!Number.isFinite(marketId) || marketId < 0) {
    return NextResponse.json({ error: 'invalid marketId' }, { status: 400 })
  }

  const { searchParams } = new URL(req.url)
  const chainIdRaw = searchParams.get('chainId')
  const chainId = chainIdRaw ? parseInt(chainIdRaw, 10) : 900

  try {
    const db = await getDb()
    const doc = await db.collection<ThreadDoc>('threads')
      .findOne({ marketId, chainId })
    if (!doc) return NextResponse.json({ error: 'thread not found' }, { status: 404 })

    // Serve the canonical JSON verbatim so its sha256 matches the published
    // contentHash. We DON'T re-stringify — that would change byte order.
    return new NextResponse(doc.canonicalJson, {
      status: 200,
      headers: {
        'content-type': 'application/json; charset=utf-8',
        'x-content-hash': doc.contentHash,
        'cache-control': 'public, max-age=300',
      },
    })
  } catch (err: any) {
    return NextResponse.json({ error: err.message || 'Internal error' }, { status: 500 })
  }
}
