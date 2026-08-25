/**
 * WalletProvider.tsx
 *
 * Android → MWA via @solana-mobile/mobile-wallet-adapter-protocol-web3js
 * iOS     → Phantom deep link protocol via expo-linking
 */

import React, { PropsWithChildren, useCallback, useEffect, useRef, useState } from 'react'
import { Platform } from 'react-native'
import * as Linking from 'expo-linking'
import { Connection, PublicKey, VersionedTransaction } from '@solana/web3.js'
import bs58 from 'bs58'
import nacl from 'tweetnacl'
import { WalletContext, WalletAccount, WalletContextValue } from '@/context/WalletContext'

// ─── Helpers ──────────────────────────────────────────────────────────────────

/** Safely extract a string from Expo Linking queryParams (which can be string | string[]) */
function param(params: Record<string, string | string[] | undefined>, key: string): string | null {
  const v = params[key]
  if (!v) return null
  return Array.isArray(v) ? v[0] : v
}

// ─── Android: MWA ─────────────────────────────────────────────────────────────

let AndroidWalletProvider: React.FC<PropsWithChildren<{ endpoint: string; chain: string }>> | null = null

if (Platform.OS === 'android') {
  const { transact } = require('@solana-mobile/mobile-wallet-adapter-protocol-web3js')

  AndroidWalletProvider = function AndroidWalletProviderImpl({
    children, endpoint, chain,
  }: PropsWithChildren<{ endpoint: string; chain: string }>) {
    const [account, setAccount] = useState<WalletAccount | null>(null)
    const connection = new Connection(endpoint, 'confirmed')

    const connect = useCallback(async () => {
      await transact(async (wallet: any) => {
        const authResult = await wallet.authorize({
          cluster: chain,
          identity: { name: 'QU!D', uri: 'https://quid.so' },
        })
        // MWA returns address as base64-encoded bytes, not base58
        const addressBytes = Buffer.from(authResult.accounts[0].address, 'base64')
        const pubkey = new PublicKey(addressBytes)
        setAccount({ address: pubkey, publicKey: pubkey })
      })
    }, [chain])

    const disconnect = useCallback(async () => {
      await transact(async (wallet: any) => {
        await wallet.deauthorize({ auth_token: '' })
      })
      setAccount(null)
    }, [])

    const signAndSendTransaction = useCallback(
      async (transaction: VersionedTransaction, minContextSlot?: number) => {
        return await transact(async (wallet: any) => {
          await wallet.authorize({
            cluster: chain,
            identity: { name: 'QU!D', uri: 'https://quid.so' },
          })
          const result = await wallet.signAndSendTransactions({
            minContextSlot,
            transactions: [transaction],
          })
          return result[0]
        })
      }, [chain])

    const signMessage = useCallback(async (message: Uint8Array) => {
      return await transact(async (wallet: any) => {
        await wallet.authorize({
          cluster: chain,
          identity: { name: 'QU!D', uri: 'https://quid.so' },
        })
        const result = await wallet.signMessages({ addresses: [], payloads: [message] })
        return result[0]
      })
    }, [chain])

    const signIn = useCallback(async () => { await connect() }, [connect])

    const value: WalletContextValue = {
      account, connection, chain,
      connect, disconnect, signAndSendTransaction, signMessage, signIn,
    }
    return <WalletContext.Provider value={value}>{children}</WalletContext.Provider>
  }
}

// ─── iOS: Phantom Deep Links ───────────────────────────────────────────────────

function iOSWalletProvider({
  children, endpoint, chain,
}: PropsWithChildren<{ endpoint: string; chain: string }>) {
  const [account, setAccount] = useState<WalletAccount | null>(null)
  const connection = new Connection(endpoint, 'confirmed')

  const dappKeyPair = useRef(nacl.box.keyPair())
  const sharedSecret = useRef<Uint8Array | null>(null)
  const session = useRef<string | null>(null)

  // Must match "scheme" in app.json exactly
  const redirectUrl = 'quid://'

  const encryptPayload = useCallback((payload: object) => {
    if (!sharedSecret.current) throw new Error('No shared secret')
    const nonce = nacl.randomBytes(24)
    const encryptedPayload = nacl.box.after(
      Buffer.from(JSON.stringify(payload)),
      nonce,
      sharedSecret.current,
    )
    return { nonce: bs58.encode(nonce), encryptedPayload: bs58.encode(encryptedPayload) }
  }, [])

  const decryptPayload = useCallback((data: string, nonce: string) => {
    if (!sharedSecret.current) throw new Error('No shared secret')
    const decrypted = nacl.box.open.after(
      bs58.decode(data),
      bs58.decode(nonce),
      sharedSecret.current,
    )
    if (!decrypted) throw new Error('Decryption failed')
    return JSON.parse(Buffer.from(decrypted).toString('utf8'))
  }, [])

  const pendingResolve = useRef<((sig: string) => void) | null>(null)
  const pendingReject = useRef<((e: unknown) => void) | null>(null)

  useEffect(() => {
    const subscription = Linking.addEventListener('url', ({ url }) => {
      console.log('[WalletProvider] incoming url:', url)
      try {
        const parsed = Linking.parse(url)
        if (!parsed.queryParams) return
        const p = parsed.queryParams as Record<string, string | string[] | undefined>

        const phantomPubKeyStr = param(p, 'phantom_encryption_public_key')
        const dataStr = param(p, 'data')
        const nonceStr = param(p, 'nonce')
        const errorCode = param(p, 'errorCode')

        if (errorCode) {
          console.error('[WalletProvider] Phantom error:', param(p, 'errorMessage'))
          pendingReject.current?.(new Error(param(p, 'errorMessage') ?? 'Phantom error'))
          pendingResolve.current = null
          pendingReject.current = null
          return
        }

        // Connect response — has phantom_encryption_public_key
        if (phantomPubKeyStr && dataStr && nonceStr && !sharedSecret.current) {
          const phantomKey = bs58.decode(phantomPubKeyStr)
          sharedSecret.current = nacl.box.before(phantomKey, dappKeyPair.current.secretKey)
          const payload = decryptPayload(dataStr, nonceStr)
          session.current = payload.session
          const pubkey = new PublicKey(payload.public_key)
          setAccount({ address: pubkey, publicKey: pubkey })
          return
        }

        // signAndSendTransaction / signMessage response
        if (dataStr && nonceStr && pendingResolve.current) {
          const payload = decryptPayload(dataStr, nonceStr)
          pendingResolve.current(payload.signature)
          pendingResolve.current = null
          pendingReject.current = null
        }
      } catch (e) {
        console.error('[WalletProvider] url handler error:', e)
        pendingReject.current?.(e)
        pendingResolve.current = null
        pendingReject.current = null
      }
    })
    return () => subscription.remove()
  }, [decryptPayload])

  const connect = useCallback(async () => {
    console.log('[WalletProvider] opening: connect')
    const params = new URLSearchParams({
      dapp_encryption_public_key: bs58.encode(dappKeyPair.current.publicKey),
      cluster: chain.replace('solana:', ''),
      app_url: 'https://quid.so',
      redirect_link: redirectUrl,
    })
    await Linking.openURL(`phantom://v1/connect?${params}`)
  }, [chain, redirectUrl])

  const disconnect = useCallback(async () => {
    console.log('[WalletProvider] opening: disconnect')
    if (session.current && sharedSecret.current) {
      const { nonce, encryptedPayload } = encryptPayload({ session: session.current })
      const params = new URLSearchParams({
        dapp_encryption_public_key: bs58.encode(dappKeyPair.current.publicKey),
        nonce,
        redirect_link: redirectUrl,
        payload: encryptedPayload,
      })
      await Linking.openURL(`phantom://v1/disconnect?${params}`)
    }
    session.current = null
    sharedSecret.current = null
    setAccount(null)
  }, [encryptPayload, redirectUrl])

  const signAndSendTransaction = useCallback(
    async (transaction: VersionedTransaction, _minContextSlot?: number): Promise<string> => {
      console.log('[WalletProvider] opening: signAndSendTransaction')
      if (!session.current || !sharedSecret.current) throw new Error('Not connected')
      const serialized = Buffer.from(transaction.serialize()).toString('base64')
      const { nonce, encryptedPayload } = encryptPayload({
        session: session.current,
        transaction: serialized,
      })
      const params = new URLSearchParams({
        dapp_encryption_public_key: bs58.encode(dappKeyPair.current.publicKey),
        nonce,
        redirect_link: redirectUrl,
        payload: encryptedPayload,
      })
      return new Promise((resolve, reject) => {
        pendingResolve.current = resolve
        pendingReject.current = reject
        Linking.openURL(`phantom://v1/signAndSendTransaction?${params}`)
      })
    }, [encryptPayload, redirectUrl])

  const signMessage = useCallback(
    async (message: Uint8Array): Promise<Uint8Array> => {
      console.log('[WalletProvider] opening: signMessage')
      if (!session.current || !sharedSecret.current) throw new Error('Not connected')
      const { nonce, encryptedPayload } = encryptPayload({
        session: session.current,
        message: Buffer.from(message).toString('base64'),
      })
      const params = new URLSearchParams({
        dapp_encryption_public_key: bs58.encode(dappKeyPair.current.publicKey),
        nonce,
        redirect_link: redirectUrl,
        payload: encryptedPayload,
      })
      return new Promise((resolve, reject) => {
        pendingResolve.current = (sig: string) => resolve(bs58.decode(sig))
        pendingReject.current = reject
        Linking.openURL(`phantom://v1/signMessage?${params}`)
      })
    }, [encryptPayload, redirectUrl])

  const signIn = useCallback(async () => connect(), [connect])

  const value: WalletContextValue = {
    account, connection, chain,
    connect, disconnect, signAndSendTransaction, signMessage, signIn,
  }
  return <WalletContext.Provider value={value}>{children}</WalletContext.Provider>
}

export function WalletProvider({ children, endpoint, chain }: PropsWithChildren<{ endpoint: string; chain: string }>) {
  if (Platform.OS === 'android' && AndroidWalletProvider) {
    return (
      <AndroidWalletProvider endpoint={endpoint} chain={chain}>
        {children}
      </AndroidWalletProvider>
    )
  }
  return iOSWalletProvider({ children, endpoint, chain })
}
