/**
 * useAuth.ts
 *
 * Auth state for QU!D. Wraps useWallet() (cross-platform: MWA on Android,
 * Phantom deep links on iOS) and layers secp256k1 key derivation on top.
 */

import { useCallback, useEffect, useState } from 'react'
import { useWallet } from '@/hooks/useWallet'
import * as SecureStore from 'expo-secure-store'
import { deriveEthKeyFromWallet, type DerivedEthKey } from '@/utils/deriveEthKey'

const MASTER_SECRET_KEY = 'quid:device-master-secret'

export type AuthStatus =
  | 'idle'
  | 'connecting'
  | 'connected'
  | 'deriving'
  | 'ready'
  | 'error'

export interface AuthState {
  status: AuthStatus
  walletAddress: string | null
  ethKey: DerivedEthKey | null
  deviceSeedHex: string | null
  error: string | null
}

export interface AuthActions {
  connect: () => Promise<void>
  disconnect: () => void
  deriveKey: () => Promise<void>
}

export function useAuth(): AuthState & AuthActions {
  const { account, connect: walletConnect, disconnect: walletDisconnect, signMessage } = useWallet()

  const [status, setStatus] = useState<AuthStatus>('idle')
  const [ethKey, setEthKey] = useState<DerivedEthKey | null>(null)
  const [deviceSeedHex, setDeviceSeedHex] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    if (account) {
      setStatus(prev => (prev === 'idle' || prev === 'connecting' ? 'connected' : prev))
    } else {
      setStatus('idle')
      setEthKey(null)
      setDeviceSeedHex(null)
      setError(null)
    }
  }, [account])

  const getMasterSecret = useCallback(async (): Promise<Uint8Array> => {
    const stored = await SecureStore.getItemAsync(MASTER_SECRET_KEY)
    if (stored) return Uint8Array.from(Buffer.from(stored, 'hex'))
    const secret = crypto.getRandomValues(new Uint8Array(32))
    await SecureStore.setItemAsync(
      MASTER_SECRET_KEY,
      Buffer.from(secret).toString('hex'),
      { requireAuthentication: false, keychainAccessible: SecureStore.WHEN_UNLOCKED_THIS_DEVICE_ONLY },
    )
    return secret
  }, [])

  const connect = useCallback(async () => {
    setStatus('connecting')
    setError(null)
    try {
      await walletConnect()
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : String(err))
      setStatus('error')
    }
  }, [walletConnect])

  const disconnect = useCallback(() => {
    walletDisconnect()
  }, [walletDisconnect])

  const deriveKey = useCallback(async () => {
    if (!account) throw new Error('Wallet not connected')
    setStatus('deriving')
    setError(null)
    try {
      const derived = await deriveEthKeyFromWallet(
        (msg: Uint8Array) => signMessage(msg),
        account.address.toString(),
      )
      setEthKey(derived)
      setDeviceSeedHex(
        Array.from(derived.compressedKeyHash)
          .map(b => b.toString(16).padStart(2, '0'))
          .join(''),
      )
      setStatus('ready')
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : String(err))
      setStatus('error')
    }
  }, [account, signMessage])

  return {
    status,
    walletAddress: account?.address.toString() ?? null,
    ethKey,
    deviceSeedHex,
    error,
    connect,
    disconnect,
    deriveKey,
  }
}
