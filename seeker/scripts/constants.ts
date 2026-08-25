/**
 * constants/constants.ts
 */

export const SOLANA_CHAIN_ID = 103      // devnet

export const QUID_DECIMALS = 6
export const QUID_SCALE = 1_000_000     // 10^6
export const MIN_CONFIDENCE_BPS = 7000

export const PROGRAM_ID =
  process.env.EXPO_PUBLIC_QUID_PROGRAM_ID ??
  'A1C96iUwFzpuaLBQX1AmfKwsisbC99cvGVnteHX6gJi9'

export const API_BASE =
  process.env.EXPO_PUBLIC_API_URL ?? 'https://app.quid.io'

export const MOCK_QUID_MINT: string =
  process.env.EXPO_PUBLIC_QUID_MINT ?? 'So11111111111111111111111111111111111111112'
