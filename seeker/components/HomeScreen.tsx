/**
 * HomeScreen.tsx
 *
 * Root shell after login: synthetic exposure, and nothing else.
 *
 * The program exposes nothing further that belongs behind a tap — liquidation
 * is a keeper's job and flash loans are a settlement-layer concern — so there
 * is one surface and no tab bar to switch between.
 */

import React, { useCallback, useEffect, useState } from 'react'
import {
  View, Text, TouchableOpacity, StyleSheet,
  ActivityIndicator, Alert,
} from 'react-native'
import { SafeAreaView } from 'react-native-safe-area-context'
import { useSolanaProgram } from '@/hooks/useSolanaProgram'
import { MOCK_QUID_MINT } from '@/constants/constants'
import StocksScreen from './StocksScreen'

interface HomeScreenProps {
  walletAddress: string
  onDisconnect: () => void
}

export default function HomeScreen({ walletAddress, onDisconnect }: HomeScreenProps) {
  const [tokenMint, setTokenMint] = useState<string>(MOCK_QUID_MINT)
  const [mintLoading, setMintLoading] = useState(false)
  const [quidBalance, setQuidBalance] = useState<number | null>(null)

  const { fetchTokenMint, fetchTokenBalance } = useSolanaProgram()

  useEffect(() => {
    if (!walletAddress) return
    setMintLoading(true)
    fetchTokenMint()
      .then(async mint => {
        const resolvedMint = mint ?? MOCK_QUID_MINT
        setTokenMint(resolvedMint)
        const bal = await fetchTokenBalance(walletAddress, resolvedMint)
        setQuidBalance(bal)
      })
      .catch(() => {})
      .finally(() => setMintLoading(false))
  }, [walletAddress, fetchTokenMint, fetchTokenBalance])

  const handleDisconnect = useCallback(() => {
    Alert.alert('Disconnect', 'Disconnect wallet?', [
      { text: 'Cancel', style: 'cancel' },
      { text: 'Disconnect', style: 'destructive', onPress: onDisconnect },
    ])
  }, [onDisconnect])

  const short = (addr: string) => addr.slice(0, 4) + '…' + addr.slice(-4)

  return (
    <SafeAreaView style={s.root} edges={['top']}>
      {/* Header */}
      <View style={s.header}>
        <Text style={s.logo}>QU!D</Text>
        <View style={s.headerRight}>
          {mintLoading && (
            <ActivityIndicator color="#888" size="small" style={{ marginRight: 8 }} />
          )}
          {quidBalance !== null && (
            <Text style={s.balanceText}>
              {quidBalance.toLocaleString(undefined, { maximumFractionDigits: 2 })} QD
            </Text>
          )}
          <TouchableOpacity onPress={handleDisconnect} style={s.addrBtn}>
            <Text style={s.addrText}>{short(walletAddress)}</Text>
          </TouchableOpacity>
        </View>
      </View>

      <View style={s.content}>
        <StocksScreen walletAddress={walletAddress} tokenMint={tokenMint} />
      </View>
    </SafeAreaView>
  )
}

const s = StyleSheet.create({
  root: { flex: 1, backgroundColor: '#0a0a0a' },
  header: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between',
    paddingHorizontal: 16, paddingVertical: 12,
    borderBottomWidth: 1, borderBottomColor: '#1a1a1a',
  },
  logo: { color: '#fff', fontSize: 18, fontWeight: '700', letterSpacing: 2 },
  headerRight: { flexDirection: 'row', alignItems: 'center', gap: 8 },
  balanceText: { color: '#14F195', fontSize: 12, fontFamily: 'monospace' },
  addrBtn: {
    backgroundColor: '#1a1a1a', borderRadius: 8,
    paddingHorizontal: 10, paddingVertical: 5,
  },
  addrText: { color: '#888', fontSize: 12, fontFamily: 'monospace' },
  content: { flex: 1 },
})

const ms = StyleSheet.create({
  root: { flex: 1, backgroundColor: '#0a0a0a', padding: 16 },
  center: { flex: 1, alignItems: 'center', justifyContent: 'center', gap: 8 },
  emptyIcon: { fontSize: 40, opacity: 0.3 },
  empty: { color: '#555', fontSize: 14 },
  emptySub: { color: '#333', fontSize: 12, textAlign: 'center', paddingHorizontal: 32 },
  sectionTitle: {
    color: '#555', fontSize: 11, fontWeight: '600',
    letterSpacing: 1, textTransform: 'uppercase', marginBottom: 12,
  },
  card: {
    backgroundColor: '#111', borderRadius: 12, padding: 14, marginBottom: 8,
    borderWidth: 1, borderColor: '#9945FF44',
  },
  cardRead: { borderColor: '#1a1a1a', opacity: 0.6 },
  cardHeader: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center' },
  simScore: { color: '#9945FF', fontWeight: '700', fontSize: 16 },
  unreadDot: { width: 8, height: 8, borderRadius: 4, backgroundColor: '#9945FF' },
  cardSub: { color: '#666', fontSize: 12, marginTop: 4 },
  cardCta: { color: '#444', fontSize: 11, marginTop: 6 },
})
