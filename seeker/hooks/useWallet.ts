/**
 * useWallet.ts
 *
 * Cross-platform Solana wallet hook.
 *   Android → Mobile Wallet Adapter (MWA) bottom sheet, no app switch
 *   iOS     → Phantom deep link protocol, switches to Phantom then returns
 *
 * Exposes the same interface as the old useMobileWallet() so all call
 * sites are a single import-line change.
 */

import { useCallback, useContext } from 'react'
import { Platform } from 'react-native'
import { WalletContext, WalletContextValue } from '@/context/WalletContext'

export function useWallet(): WalletContextValue {
  const ctx = useContext(WalletContext)
  if (!ctx) throw new Error('useWallet must be used inside WalletProvider')
  return ctx
}

// Re-export platform flag for components that need to adapt UI
export const IS_IOS = Platform.OS === 'ios'
export const IS_ANDROID = Platform.OS === 'android'
