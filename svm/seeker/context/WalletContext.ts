/**
 * WalletContext.ts
 *
 * Shared context type for cross-platform wallet state.
 * Implemented by WalletProvider (Android: MWA, iOS: Phantom deep links).
 */

import { createContext } from 'react'
import { Connection, PublicKey, VersionedTransaction } from '@solana/web3.js'

export interface WalletAccount {
  address: PublicKey
  publicKey: PublicKey  // alias for compatibility
}

export interface WalletContextValue {
  // State
  account: WalletAccount | null
  connection: Connection
  chain: string

  // Actions
  connect: () => Promise<void>
  disconnect: () => Promise<void>
  signAndSendTransaction: (
    transaction: VersionedTransaction,
    minContextSlot?: number,
  ) => Promise<string>
  signMessage: (message: Uint8Array) => Promise<Uint8Array>
  signIn: () => Promise<void>
}

export const WalletContext = createContext<WalletContextValue | null>(null)
