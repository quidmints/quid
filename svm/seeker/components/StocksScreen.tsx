/**
 * StocksScreen.tsx
 *
 * React Native port of StockExposureTab.tsx.
 * Wired to useStockExposure for deposit / withdraw / positions.
 *
 * IDL-correct Stock fields (from quid.json audit):
 *   ticker [u8;8], pledged u64, exposure i64,
 *   updated i64, rate_bps u16, collar_bps u16
 *
 * withdraw(amount: i64, ticker, exposure):
 *   positive = add/increase, negative = reduce/withdraw
 */

import React, { useCallback, useEffect, useState } from 'react'
import {
  View, Text, ScrollView, TouchableOpacity, TextInput,
  StyleSheet, ActivityIndicator, Alert, RefreshControl,
} from 'react-native'
import { useStockExposure, StockPosition } from '@/hooks/useStockExposure'
import { QUID_SCALE } from '@/constants/constants'

// Ticker categories — subset matching etc.rs PHF maps
const CATEGORIES: Record<string, string[]> = {
  Crypto:    ['BTC', 'ETH', 'SOL', 'BNB', 'AVAX', 'LINK', 'MATIC', 'ARB'],
  Equities:  ['AAPL', 'MSFT', 'GOOGL', 'AMZN', 'TSLA', 'NVDA', 'META', 'NFLX'],
  Forex:     ['EUR', 'GBP', 'JPY', 'CHF', 'AUD', 'CAD', 'CNY'],
  Metals:    ['XAU', 'XAG', 'XPT', 'XPD', 'XCU'],
  Energy:    ['CL', 'NG', 'RB', 'HO'],
}

interface Props {
  walletAddress: string
  tokenMint: string
}

type SubTab = 'open' | 'manage'

export default function StocksScreen({ walletAddress, tokenMint }: Props) {
  const { positions, depositedQuid, isLoading, error, deposit, withdraw, refreshPositions } =
    useStockExposure()

  const [subTab, setSubTab] = useState<SubTab>('manage')
  const [category, setCategory] = useState('Crypto')
  const [selectedTicker, setSelectedTicker] = useState('')
  const [direction, setDirection] = useState<'long' | 'short'>('long')
  const [pledgeAmount, setPledgeAmount] = useState('')
  const [exposureAmount, setExposureAmount] = useState('')
  const [refreshing, setRefreshing] = useState(false)
  const [submitting, setSubmitting] = useState(false)

  // Manage-position state
  const [manageTicker, setManageTicker] = useState('')
  const [manageAction, setManageAction] = useState<'increase' | 'decrease' | 'collateral'>('increase')
  const [manageAmount, setManageAmount] = useState('')

  useEffect(() => {
    if (walletAddress) refreshPositions(walletAddress)
  }, [walletAddress, refreshPositions])

  const onRefresh = useCallback(async () => {
    setRefreshing(true)
    await refreshPositions(walletAddress)
    setRefreshing(false)
  }, [walletAddress, refreshPositions])

  // ── Open position ────────────────────────────────────────────────────────

  const handleOpenPosition = useCallback(async () => {
    if (!selectedTicker || !pledgeAmount) return
    const pledgeNum = parseFloat(pledgeAmount)
    const exposureNum = parseFloat(exposureAmount || '0')
    if (isNaN(pledgeNum) || pledgeNum <= 0) {
      Alert.alert('Enter a valid pledge amount')
      return
    }
    setSubmitting(true)
    try {
      // Step 1: deposit(pledgeAmount, ticker) — locks collateral
      await deposit(walletAddress, selectedTicker, pledgeAmount, tokenMint)

      // Step 2: withdraw(signed_exposure, ticker, exposure=true) — opens exposure
      if (exposureNum > 0) {
        const signed = direction === 'long' ? exposureAmount : (-exposureNum).toString()
        await withdraw(walletAddress, selectedTicker, signed, true, tokenMint, positions)
      }

      Alert.alert('Position opened!')
      setPledgeAmount('')
      setExposureAmount('')
      setTimeout(() => refreshPositions(walletAddress), 3000)
    } catch (e: any) {
      Alert.alert('Error', e.message)
    } finally {
      setSubmitting(false)
    }
  }, [selectedTicker, pledgeAmount, exposureAmount, direction, walletAddress, tokenMint, deposit, withdraw, positions, refreshPositions])

  // ── Manage existing position ────────────────────────────────────────────

  const handleManagePosition = useCallback(async () => {
    if (!manageTicker || !manageAmount) return
    const amt = parseFloat(manageAmount)
    if (isNaN(amt) || amt <= 0) return

    const pos = positions.find(p => p.ticker === manageTicker)
    if (!pos) { Alert.alert('Position not found'); return }

    setSubmitting(true)
    try {
      if (manageAction === 'collateral') {
        // withdraw(amount=-amt, ticker, exposure=false) — reduce pledged
        await withdraw(walletAddress, manageTicker, (-amt).toString(), false, tokenMint, positions)
      } else if (manageAction === 'increase') {
        const signed = pos.direction === 'short' ? (-amt).toString() : amt.toString()
        await withdraw(walletAddress, manageTicker, signed, true, tokenMint, positions)
      } else {
        // decrease: long → -amt, short → +amt
        const signed = pos.direction === 'short' ? amt.toString() : (-amt).toString()
        await withdraw(walletAddress, manageTicker, signed, true, tokenMint, positions)
      }

      Alert.alert('Position updated')
      setManageAmount('')
      setTimeout(() => refreshPositions(walletAddress), 3000)
    } catch (e: any) {
      Alert.alert('Error', e.message)
    } finally {
      setSubmitting(false)
    }
  }, [manageTicker, manageAmount, manageAction, positions, walletAddress, tokenMint, withdraw, refreshPositions])

  // ── Withdraw all collateral ─────────────────────────────────────────────

  const handleWithdrawAll = useCallback(async () => {
    Alert.alert('Withdraw all', `Redeem all ${depositedQuid.toFixed(2)} QD collateral?`, [
      { text: 'Cancel', style: 'cancel' },
      {
        text: 'Withdraw',
        onPress: async () => {
          setSubmitting(true)
          try {
            // withdraw(amount=-depositedQuid, ticker='', exposure=false)
            await withdraw(walletAddress, '', (-depositedQuid).toString(), false, tokenMint, positions)
            Alert.alert('Collateral withdrawn')
            setTimeout(() => refreshPositions(walletAddress), 3000)
          } catch (e: any) {
            Alert.alert('Error', e.message)
          } finally {
            setSubmitting(false)
          }
        },
      },
    ])
  }, [depositedQuid, walletAddress, tokenMint, positions, withdraw, refreshPositions])

  return (
    <View style={s.root}>
      {/* Deposited balance banner */}
      <View style={s.banner}>
        <Text style={s.bannerLabel}>Collateral</Text>
        <Text style={s.bannerValue}>{depositedQuid.toFixed(2)} QD</Text>
        {depositedQuid > 0 && (
          <TouchableOpacity onPress={handleWithdrawAll} style={s.withdrawAllBtn}>
            <Text style={s.withdrawAllText}>Withdraw all</Text>
          </TouchableOpacity>
        )}
      </View>

      {/* Sub-tab */}
      <View style={s.subTabRow}>
        {(['open', 'manage'] as SubTab[]).map(t => (
          <TouchableOpacity
            key={t}
            style={[s.subTab, subTab === t && s.subTabActive]}
            onPress={() => setSubTab(t)}
          >
            <Text style={[s.subTabText, subTab === t && s.subTabTextActive]}>
              {t === 'open' ? 'Open Position' : 'Manage'}
            </Text>
          </TouchableOpacity>
        ))}
      </View>

      <ScrollView
        style={s.scroll}
        refreshControl={<RefreshControl refreshing={refreshing} onRefresh={onRefresh} tintColor="#444" />}
      >
        {error && <Text style={s.errorText}>{error}</Text>}
        {isLoading && positions.length === 0 && (
          <ActivityIndicator color="#888" style={{ marginTop: 40 }} />
        )}

        {/* ── Open position tab ─── */}
        {subTab === 'open' && (
          <View style={s.section}>
            {/* Category tabs */}
            <ScrollView horizontal showsHorizontalScrollIndicator={false} style={s.catRow}>
              {Object.keys(CATEGORIES).map(cat => (
                <TouchableOpacity
                  key={cat}
                  style={[s.catChip, category === cat && s.catChipActive]}
                  onPress={() => { setCategory(cat); setSelectedTicker('') }}
                >
                  <Text style={[s.catChipText, category === cat && s.catChipTextActive]}>{cat}</Text>
                </TouchableOpacity>
              ))}
            </ScrollView>

            {/* Ticker grid */}
            <View style={s.tickerGrid}>
              {(CATEGORIES[category] ?? []).map(t => (
                <TouchableOpacity
                  key={t}
                  style={[s.tickerChip, selectedTicker === t && s.tickerChipActive]}
                  onPress={() => setSelectedTicker(t)}
                >
                  <Text style={[s.tickerChipText, selectedTicker === t && s.tickerChipTextActive]}>
                    {t}
                  </Text>
                </TouchableOpacity>
              ))}
            </View>

            {selectedTicker !== '' && (
              <>
                {/* Direction */}
                <Text style={s.label}>Direction</Text>
                <View style={s.dirRow}>
                  {(['long', 'short'] as const).map(d => (
                    <TouchableOpacity
                      key={d}
                      style={[s.dirBtn, direction === d && (d === 'long' ? s.dirBtnLong : s.dirBtnShort)]}
                      onPress={() => setDirection(d)}
                    >
                      <Text style={[s.dirBtnText, direction === d && s.dirBtnTextActive]}>
                        {d === 'long' ? '↑ Long' : '↓ Short'}
                      </Text>
                    </TouchableOpacity>
                  ))}
                </View>

                {/* Pledge */}
                <Text style={s.label}>Pledge collateral (QD)</Text>
                <TextInput
                  style={s.input}
                  value={pledgeAmount}
                  onChangeText={setPledgeAmount}
                  placeholder="100"
                  placeholderTextColor="#444"
                  keyboardType="decimal-pad"
                />

                {/* Exposure */}
                <Text style={s.label}>Exposure amount (QD, optional)</Text>
                <TextInput
                  style={s.input}
                  value={exposureAmount}
                  onChangeText={setExposureAmount}
                  placeholder="200"
                  placeholderTextColor="#444"
                  keyboardType="decimal-pad"
                />

                <TouchableOpacity
                  style={[s.btnPrimary, submitting && s.btnDisabled]}
                  onPress={handleOpenPosition}
                  disabled={submitting}
                >
                  {submitting
                    ? <ActivityIndicator color="#fff" size="small" />
                    : <Text style={s.btnPrimaryText}>
                        Open {direction === 'long' ? 'Long' : 'Short'} {selectedTicker}
                      </Text>
                  }
                </TouchableOpacity>
              </>
            )}
          </View>
        )}

        {/* ── Manage tab ─── */}
        {subTab === 'manage' && (
          <View style={s.section}>
            {positions.length === 0 ? (
              <Text style={s.emptyText}>No open positions</Text>
            ) : (
              <>
                {/* Position cards */}
                {positions.map(pos => (
                  <TouchableOpacity
                    key={pos.ticker}
                    style={[s.posCard, manageTicker === pos.ticker && s.posCardSelected]}
                    onPress={() => setManageTicker(prev => prev === pos.ticker ? '' : pos.ticker)}
                  >
                    <View style={s.posHeader}>
                      <Text style={s.posTicker}>{pos.ticker}</Text>
                      <View style={[s.dirBadge, pos.direction === 'long' ? s.dirBadgeLong : s.dirBadgeShort]}>
                        <Text style={s.dirBadgeText}>
                          {pos.direction === 'long' ? '↑ Long' : pos.direction === 'short' ? '↓ Short' : '— Flat'}
                        </Text>
                      </View>
                    </View>
                    <Text style={s.posMeta}>
                      Pledged {pos.pledged.toFixed(2)} QD · Exposure {Math.abs(pos.exposure).toFixed(2)} QD
                    </Text>
                    {pos.collarBps > 0 && (
                      <Text style={s.posCollar}>Collar {pos.collarBps} bps</Text>
                    )}

                    {/* Manage controls (expanded) */}
                    {manageTicker === pos.ticker && (
                      <View style={s.manageControls}>
                        <View style={s.manageActionRow}>
                          {(['increase', 'decrease', 'collateral'] as const).map(act => (
                            <TouchableOpacity
                              key={act}
                              style={[s.actChip, manageAction === act && s.actChipActive]}
                              onPress={() => setManageAction(act)}
                            >
                              <Text style={[s.actChipText, manageAction === act && s.actChipTextActive]}>
                                {act === 'increase' ? '+Exposure' : act === 'decrease' ? '-Exposure' : 'Withdraw QD'}
                              </Text>
                            </TouchableOpacity>
                          ))}
                        </View>

                        <TextInput
                          style={[s.input, { marginTop: 8 }]}
                          value={manageAmount}
                          onChangeText={setManageAmount}
                          placeholder="Amount (QD)"
                          placeholderTextColor="#444"
                          keyboardType="decimal-pad"
                        />

                        <TouchableOpacity
                          style={[s.btnPrimary, { marginTop: 8 }, submitting && s.btnDisabled]}
                          onPress={handleManagePosition}
                          disabled={submitting}
                        >
                          {submitting
                            ? <ActivityIndicator color="#fff" size="small" />
                            : <Text style={s.btnPrimaryText}>Confirm</Text>
                          }
                        </TouchableOpacity>
                      </View>
                    )}
                  </TouchableOpacity>
                ))}
              </>
            )}
          </View>
        )}
      </ScrollView>
    </View>
  )
}

const s = StyleSheet.create({
  root: { flex: 1, backgroundColor: '#0a0a0a' },
  banner: {
    flexDirection: 'row', alignItems: 'center',
    padding: 12, paddingHorizontal: 16,
    backgroundColor: '#111', borderBottomWidth: 1, borderBottomColor: '#1a1a1a',
  },
  bannerLabel: { color: '#888', fontSize: 12, marginRight: 6 },
  bannerValue: { color: '#fff', fontWeight: '700', fontSize: 15, flex: 1 },
  withdrawAllBtn: {
    backgroundColor: '#1a1a1a', borderRadius: 6,
    paddingHorizontal: 10, paddingVertical: 4,
  },
  withdrawAllText: { color: '#888', fontSize: 12 },

  subTabRow: {
    flexDirection: 'row',
    borderBottomWidth: 1, borderBottomColor: '#1a1a1a',
  },
  subTab: { flex: 1, padding: 10, alignItems: 'center' },
  subTabActive: { borderBottomWidth: 2, borderBottomColor: '#3b82f6' },
  subTabText: { color: '#444', fontSize: 13 },
  subTabTextActive: { color: '#3b82f6' },

  scroll: { flex: 1 },
  section: { padding: 12 },
  errorText: { color: '#ef4444', padding: 16 },
  emptyText: { color: '#444', textAlign: 'center', marginTop: 40 },

  catRow: { marginBottom: 12 },
  catChip: {
    backgroundColor: '#1a1a1a', borderRadius: 8,
    paddingHorizontal: 12, paddingVertical: 7,
    marginRight: 6, borderWidth: 1, borderColor: '#1a1a1a',
  },
  catChipActive: { borderColor: '#3b82f6' },
  catChipText: { color: '#888', fontSize: 12 },
  catChipTextActive: { color: '#3b82f6' },

  tickerGrid: { flexDirection: 'row', flexWrap: 'wrap', gap: 6, marginBottom: 16 },
  tickerChip: {
    backgroundColor: '#1a1a1a', borderRadius: 8,
    paddingHorizontal: 12, paddingVertical: 8,
    borderWidth: 1, borderColor: '#1a1a1a',
  },
  tickerChipActive: { borderColor: '#a855f7' },
  tickerChipText: { color: '#888', fontSize: 13 },
  tickerChipTextActive: { color: '#a855f7', fontWeight: '600' },

  label: { color: '#888', fontSize: 12, marginBottom: 6, marginTop: 14 },
  input: {
    backgroundColor: '#1a1a1a', borderRadius: 8,
    padding: 12, color: '#fff', fontSize: 15,
  },
  dirRow: { flexDirection: 'row', gap: 8, marginBottom: 4 },
  dirBtn: {
    flex: 1, borderRadius: 8, borderWidth: 1, borderColor: '#1a1a1a',
    padding: 10, alignItems: 'center', backgroundColor: '#1a1a1a',
  },
  dirBtnLong: { borderColor: '#22c55e', backgroundColor: '#22c55e22' },
  dirBtnShort: { borderColor: '#ef4444', backgroundColor: '#ef444422' },
  dirBtnText: { color: '#888', fontWeight: '600', fontSize: 13 },
  dirBtnTextActive: { color: '#fff' },

  btnPrimary: {
    backgroundColor: '#3b82f6', borderRadius: 8,
    padding: 13, alignItems: 'center', marginTop: 16,
  },
  btnPrimaryText: { color: '#fff', fontWeight: '700', fontSize: 14 },
  btnDisabled: { opacity: 0.5 },

  posCard: {
    backgroundColor: '#111', borderRadius: 12,
    padding: 14, marginBottom: 8,
    borderWidth: 1, borderColor: '#1a1a1a',
  },
  posCardSelected: { borderColor: '#3b82f6' },
  posHeader: { flexDirection: 'row', justifyContent: 'space-between', marginBottom: 6 },
  posTicker: { color: '#fff', fontWeight: '700', fontSize: 16 },
  dirBadge: { borderRadius: 6, paddingHorizontal: 8, paddingVertical: 3 },
  dirBadgeLong: { backgroundColor: '#22c55e22' },
  dirBadgeShort: { backgroundColor: '#ef444422' },
  dirBadgeText: { fontSize: 11, fontWeight: '600', color: '#fff' },
  posMeta: { color: '#888', fontSize: 12 },
  posCollar: { color: '#a855f7', fontSize: 11, marginTop: 2 },

  manageControls: { marginTop: 12, borderTopWidth: 1, borderTopColor: '#1a1a1a', paddingTop: 10 },
  manageActionRow: { flexDirection: 'row', gap: 6 },
  actChip: {
    flex: 1, backgroundColor: '#0a0a0a', borderRadius: 7,
    paddingVertical: 7, alignItems: 'center',
    borderWidth: 1, borderColor: '#1a1a1a',
  },
  actChipActive: { borderColor: '#3b82f6' },
  actChipText: { color: '#444', fontSize: 11 },
  actChipTextActive: { color: '#3b82f6' },
})
