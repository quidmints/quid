#!/usr/bin/env npx tsx
/**
 * extract-tickers.ts — Build-time extractor for Pyth ticker data
 *
 * Reads svm/programs/quid/src/etc.rs and extracts all phf_map! entries
 * (HEX_MAP → Hermes feed IDs, ACCOUNT_MAP → Solana receiver addresses)
 * into a single tickers.ts that the frontend imports.
 *
 * Usage:
 *   npx tsx scripts/extract-tickers.ts
 *   # or add to package.json:
 *   #   "prebuild": "npx tsx scripts/extract-tickers.ts"
 *
 * Single source of truth: svm/programs/quid/src/etc.rs
 * Generated output:    src/lib/tickers.ts
 */

import { readFileSync, writeFileSync } from 'fs'
import { resolve, dirname } from 'path'

// ── Config ──────────────────────────────────────────────────────────────

// Adjust these paths relative to your project root
const ETC_RS_PATH = resolve(__dirname, 'programs/quid/src/etc.rs')
const OUTPUT_PATH = resolve(__dirname, '../src/lib/tickers.ts')

// Map name prefix → { category, assetClass }
// Order matters for frontend display
const MAP_CATEGORIES: Record<string, { category: string; assetClass: string; maxLev: number; minFeeBps: number; label: string }> = {
  CRYPTO:               { category: 'Crypto',            assetClass: 'Crypto',        maxLev: 3,  minFeeBps: 4, label: 'Crypto' },
  US_EQUITIES:          { category: 'US Equities',       assetClass: 'Equity',        maxLev: 4,  minFeeBps: 4, label: 'Equity' },
  GB_EQUITIES:          { category: 'UK Equities',       assetClass: 'Equity',        maxLev: 4,  minFeeBps: 4, label: 'Equity' },
  DE_EQUITIES:          { category: 'DE Equities',       assetClass: 'Equity',        maxLev: 4,  minFeeBps: 4, label: 'Equity' },
  FR_EQUITIES:          { category: 'FR Equities',       assetClass: 'Equity',        maxLev: 4,  minFeeBps: 4, label: 'Equity' },
  NL_EQUITIES:          { category: 'NL Equities',       assetClass: 'Equity',        maxLev: 4,  minFeeBps: 4, label: 'Equity' },
  LU_EQUITIES:          { category: 'LU Equities',       assetClass: 'Equity',        maxLev: 4,  minFeeBps: 4, label: 'Equity' },
  FX_USD:               { category: 'FX',                assetClass: 'FX',            maxLev: 10, minFeeBps: 2, label: 'FX' },
  METALS:               { category: 'Metals',            assetClass: 'PreciousMetal',  maxLev: 5,  minFeeBps: 3, label: 'Precious Metal' },
  COMMODITIES:          { category: 'Commodities',       assetClass: 'Commodity',     maxLev: 3,  minFeeBps: 4, label: 'Commodity' },
  RATES:                { category: 'Rates',             assetClass: 'Rates',         maxLev: 10, minFeeBps: 2, label: 'Rate' },
  STAKING_DERIVATIVES:  { category: 'Staking Derivs',    assetClass: 'StakingDeriv',  maxLev: 5,  minFeeBps: 3, label: 'Staking Derivative' },
}

// ── Parser ──────────────────────────────────────────────────────────────

interface PhfMapEntry {
  key: string
  value: string
}

function parsePhfMaps(source: string): Map<string, PhfMapEntry[]> {
  const maps = new Map<string, PhfMapEntry[]>()
  const pattern = /pub static (\w+): phf::Map.*?= phf_map! \{([\s\S]*?)\};/g
  let match: RegExpExecArray | null
  while ((match = pattern.exec(source)) !== null) {
    const name = match[1]
    const body = match[2]
    const entries: PhfMapEntry[] = []
    const entryPattern = /"([^"]+)"\s*=>\s*"([^"]+)"/g
    let em: RegExpExecArray | null
    while ((em = entryPattern.exec(body)) !== null) {
      entries.push({ key: em[1], value: em[2] })
    }
    maps.set(name, entries)
  }
  return maps
}

// ── Generator ───────────────────────────────────────────────────────────

function generate() {
  console.log(`Reading ${ETC_RS_PATH}...`)
  const source = readFileSync(ETC_RS_PATH, 'utf-8')
  const maps = parsePhfMaps(source)
  console.log(`Parsed ${maps.size} phf_maps`)

  // Build per-category ticker data
  interface TickerData {
    hex: string    // Pyth Hermes feed ID (0x...)
    account: string // Solana receiver account (base58)
  }

  interface CategoryData {
    category: string
    assetClass: string
    maxLev: number
    minFeeBps: number
    label: string
    tickers: Map<string, TickerData>
  }

  const categories: CategoryData[] = []
  let totalTickers = 0

  for (const [prefix, meta] of Object.entries(MAP_CATEGORIES)) {
    const hexMap = maps.get(`${prefix}_HEX_MAP`)
    const acctMap = maps.get(`${prefix}_ACCOUNT_MAP`)
    if (!hexMap && !acctMap) {
      console.warn(`  ⚠ No maps found for ${prefix}`)
      continue
    }

    const tickers = new Map<string, TickerData>()

    // Merge hex + account maps (they should have the same keys)
    const acctLookup = new Map(acctMap?.map(e => [e.key, e.value]) ?? [])

    for (const entry of (hexMap ?? [])) {
      tickers.set(entry.key, {
        hex: entry.value,
        account: acctLookup.get(entry.key) ?? '',
      })
    }

    // Add any accounts without hex entries (shouldn't happen, but defensive)
    for (const entry of (acctMap ?? [])) {
      if (!tickers.has(entry.key)) {
        tickers.set(entry.key, { hex: '', account: entry.value })
      }
    }

    const missingAccounts = [...tickers.entries()].filter(([, v]) => !v.account).length
    const missingHex = [...tickers.entries()].filter(([, v]) => !v.hex).length
    if (missingAccounts > 0) console.warn(`  ⚠ ${prefix}: ${missingAccounts} tickers missing account`)
    if (missingHex > 0) console.warn(`  ⚠ ${prefix}: ${missingHex} tickers missing hex feed ID`)

    console.log(`  ${meta.category}: ${tickers.size} tickers`)
    totalTickers += tickers.size
    categories.push({ ...meta, tickers })
  }

  console.log(`Total: ${totalTickers} tickers across ${categories.length} categories`)

  // ── Emit TypeScript ─────────────────────────────────────────────────

  const lines: string[] = []
  const W = (s: string) => lines.push(s)

  W(`/**`)
  W(` * tickers.ts — AUTO-GENERATED by extract-tickers.ts`)
  W(` * Source: svm/programs/quid/src/etc.rs`)
  W(` * Generated: ${new Date().toISOString()}`)
  W(` * Total: ${totalTickers} tickers across ${categories.length} categories`)
  W(` *`)
  W(` * DO NOT EDIT MANUALLY — re-run: npx tsx scripts/extract-tickers.ts`)
  W(` */`)
  W(``)
  W(`// ═══════════════════════════════════════════════════════════════════════════`)
  W(`// TYPES`)
  W(`// ═══════════════════════════════════════════════════════════════════════════`)
  W(``)
  W(`export interface TickerInfo {`)
  W(`  hex: string      // Pyth Hermes feed ID (0x...) for browser price fetching`)
  W(`  account: string  // Solana Pyth receiver account (base58) for remaining_accounts`)
  W(`}`)
  W(``)
  W(`export interface AssetClassInfo {`)
  W(`  maxLev: number   // max leverage ×1 (e.g. 3 = 3x)`)
  W(`  minFeeBps: number`)
  W(`  label: string    // display label`)
  W(`}`)
  W(``)
  W(`// ═══════════════════════════════════════════════════════════════════════════`)
  W(`// ASSET CLASSES (from AssetClass enum in etc.rs)`)
  W(`// ═══════════════════════════════════════════════════════════════════════════`)
  W(``)
  W(`export const ASSET_CLASSES: Record<string, AssetClassInfo> = {`)
  // Deduplicate by assetClass name
  const emitted = new Set<string>()
  for (const cat of categories) {
    if (!emitted.has(cat.assetClass)) {
      emitted.add(cat.assetClass)
      W(`  '${cat.assetClass}': { maxLev: ${cat.maxLev}, minFeeBps: ${cat.minFeeBps}, label: '${cat.label}' },`)
    }
  }
  W(`}`)
  W(``)

  // ── TICKER_CATEGORIES: category name → sorted ticker list
  W(`// ═══════════════════════════════════════════════════════════════════════════`)
  W(`// CATEGORIES — category name → ticker symbols (sorted)`)
  W(`// ═══════════════════════════════════════════════════════════════════════════`)
  W(``)
  W(`export const TICKER_CATEGORIES: Record<string, string[]> = {`)
  for (const cat of categories) {
    const sorted = [...cat.tickers.keys()].sort()
    // Chunk into lines of ~10 for readability
    const chunks: string[][] = []
    for (let i = 0; i < sorted.length; i += 12) {
      chunks.push(sorted.slice(i, i + 12))
    }
    W(`  '${cat.category}': [`)
    for (const chunk of chunks) {
      W(`    ${chunk.map(t => `'${t}'`).join(', ')},`)
    }
    W(`  ],`)
  }
  W(`}`)
  W(``)

  // ── CATEGORY_ASSET_CLASS: which AssetClass each category maps to
  W(`// Maps UI category → AssetClass key (for leverage/fee lookups)`)
  W(`export const CATEGORY_ASSET_CLASS: Record<string, string> = {`)
  for (const cat of categories) {
    W(`  '${cat.category}': '${cat.assetClass}',`)
  }
  W(`}`)
  W(``)

  // ── PYTH_ACCOUNTS: ticker → Solana receiver address (for remaining_accounts)
  W(`// ═══════════════════════════════════════════════════════════════════════════`)
  W(`// PYTH ACCOUNTS — Solana receiver addresses for remaining_accounts`)
  W(`// ═══════════════════════════════════════════════════════════════════════════`)
  W(``)
  W(`export const PYTH_ACCOUNTS: Record<string, string> = {`)
  for (const cat of categories) {
    const sorted = [...cat.tickers.entries()]
      .filter(([, v]) => v.account)
      .sort(([a], [b]) => a.localeCompare(b))
    if (sorted.length === 0) continue
    W(`  // ── ${cat.category} (${sorted.length}) ──`)
    for (const [ticker, data] of sorted) {
      W(`  '${ticker}': '${data.account}',`)
    }
  }
  W(`}`)
  W(``)

  // ── PYTH_HEX: ticker → Hermes feed ID (for browser price API)
  W(`// ═══════════════════════════════════════════════════════════════════════════`)
  W(`// PYTH HEX — Hermes feed IDs for browser price fetching`)
  W(`// ═══════════════════════════════════════════════════════════════════════════`)
  W(``)
  W(`export const PYTH_HEX: Record<string, string> = {`)
  for (const cat of categories) {
    const sorted = [...cat.tickers.entries()]
      .filter(([, v]) => v.hex)
      .sort(([a], [b]) => a.localeCompare(b))
    if (sorted.length === 0) continue
    W(`  // ── ${cat.category} (${sorted.length}) ──`)
    for (const [ticker, data] of sorted) {
      W(`  '${ticker}': '${data.hex}',`)
    }
  }
  W(`}`)
  W(``)

  // ── Convenience: all ticker symbols as a flat set
  W(`// ═══════════════════════════════════════════════════════════════════════════`)
  W(`// CONVENIENCE`)
  W(`// ═══════════════════════════════════════════════════════════════════════════`)
  W(``)
  W(`/** All ${totalTickers} supported ticker symbols */`)
  W(`export const ALL_TICKERS: string[] = Object.keys(PYTH_ACCOUNTS).sort()`)
  W(``)
  W(`/** Resolve ticker → asset class info (leverage, fees) */`)
  W(`export function getAssetClass(ticker: string): AssetClassInfo {`)
  W(`  for (const [cat, tickers] of Object.entries(TICKER_CATEGORIES)) {`)
  W(`    if (tickers.includes(ticker)) {`)
  W(`      const ac = CATEGORY_ASSET_CLASS[cat]`)
  W(`      if (ac && ASSET_CLASSES[ac]) return ASSET_CLASSES[ac]`)
  W(`    }`)
  W(`  }`)
  W(`  return ASSET_CLASSES['Crypto'] // default, matches etc.rs`)
  W(`}`)
  W(``)
  W(`/** Fetch price from Pyth Hermes (browser-safe, no API key) */`)
  W(`export async function fetchTickerPrice(ticker: string): Promise<number | null> {`)
  W(`  const hex = PYTH_HEX[ticker]`)
  W(`  if (!hex) return null`)
  W(`  try {`)
  W(`    const r = await fetch(\`https://hermes.pyth.network/api/latest_price_feeds?ids[]=\${hex}\`)`)
  W(`    if (!r.ok) return null`)
  W(`    const json = await r.json()`)
  W(`    const p = json?.[0]?.price`)
  W(`    if (!p) return null`)
  W(`    return Number(p.price) * Math.pow(10, p.expo)`)
  W(`  } catch { return null }`)
  W(`}`)
  W(``)
  W(`/** Batch-fetch prices from Pyth Hermes */`)
  W(`export async function fetchBatchPrices(tickers: string[]): Promise<Record<string, number>> {`)
  W(`  const ids = tickers.map(t => PYTH_HEX[t]).filter(Boolean)`)
  W(`  if (!ids.length) return {}`)
  W(`  try {`)
  W(`    const qs = ids.map(h => \`ids[]=\${h}\`).join('&')`)
  W(`    const r = await fetch(\`https://hermes.pyth.network/api/latest_price_feeds?\${qs}\`)`)
  W(`    if (!r.ok) return {}`)
  W(`    const out: Record<string, number> = {}`)
  W(`    for (const feed of await r.json()) {`)
  W(`      const hexId = '0x' + feed.id`)
  W(`      const t = Object.entries(PYTH_HEX).find(([, v]) => v === hexId)?.[0]`)
  W(`      if (t && feed.price) out[t] = Number(feed.price.price) * Math.pow(10, feed.price.expo)`)
  W(`    }`)
  W(`    return out`)
  W(`  } catch { return {} }`)
  W(`}`)
  W(``)

  // ── Write ───────────────────────────────────────────────────────────

  const output = lines.join('\n')
  writeFileSync(OUTPUT_PATH, output, 'utf-8')
  console.log(`\n✅ Written ${OUTPUT_PATH} (${(output.length / 1024).toFixed(1)} KB, ${lines.length} lines)`)
}

generate()
