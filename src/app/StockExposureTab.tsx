/**
 * StockExposureTab — Drop-in tab for page.tsx
 *
 * Reuses the EXACT design blocks from the existing Ethereum interface:
 *   - Position cards     → same as selfManagedPositions.map(pos => ...)
 *   - Info boxes         → same as p-4 rounded-xl bg-black/20 border border-white/5
 *   - Toggle buttons     → same as inline-flex p-1 rounded-lg bg-black/30 pattern
 *   - Input fields       → same as w-full px-4 py-3 rounded-xl bg-black/30 pattern
 *   - Action buttons     → same gradient buttons (cyan, orange, purple)
 *   - Stats row          → same as p-4 rounded-xl bg-white/5 border border-white/10
 *   - Sub-tab toggles    → same as flex gap-1 p-1 rounded-lg bg-white/5 pattern
 *
 * Integration into page.tsx:
 *   1. Add 'exposure' to the tab list:
 *      {['mint', 'deposit', 'withdraw', 'swap', 'exposure', 'predictions'].map(...)
 *      tab === 'exposure' ? '📈 Stocks' : ...
 *
 *   2. Add state variables (see STATE VARIABLES section below)
 *
 *   3. Paste the JSX block into the activeTab switch:
 *      {activeTab === 'exposure' && ( <StockExposureContent ... /> )}
 *
 * All Solana transactions go through the `withdraw` instruction (exposure=true)
 * which internally calls repo(). The `deposit` instruction is used only to
 * pledge initial collateral (exposure=false, ticker != "").
 *
 * Sign convention (from lib.rs):
 *   Long:  +amount = increase exposure, −amount = take profit
 *   Short: −amount = increase exposure, +amount = take profit
 *   The UI abstracts this — user picks direction + "increase/decrease"
 *   and we compute the correct signed amount.
 */

import { useCallback, useEffect, useMemo, useState } from 'react'
import {
  TICKER_CATEGORIES, PYTH_ACCOUNTS, PYTH_HEX,
  ASSET_CLASSES, CATEGORY_ASSET_CLASS,
  fetchTickerPrice, fetchBatchPrices, getAssetClass,
} from '@/lib/tickers'

// Re-export for consumers that imported from here
export { TICKER_CATEGORIES, PYTH_ACCOUNTS, fetchTickerPrice, fetchBatchPrices }

// ═══════════════════════════════════════════════════════════════════════════
// TYPES
// ═══════════════════════════════════════════════════════════════════════════

export interface StockPosition {
  ticker: string
  pledged: number      // QD collateral (in token units, /1e18)
  exposure: number     // signed: + = long units, - = short units
  collarBps: number
  price: number        // current USD price
  pnlPct: number       // unrealized PnL %
  direction: 'long' | 'short' | 'flat'
  leverage: number
}

interface StockExposureProps {
  connected: boolean
  isLoading: boolean
  txMutex: boolean
  address: string
  formatNumber: (n: number, d: number) => string
  onDeposit: (ticker: string, pledgeAmount: string) => Promise<void>
  onWithdraw: (ticker: string, amount: string, exposure: boolean) => Promise<void>
  positions: StockPosition[]
  depositedQuid: number
  walletBalance?: number  // raw ATA balance (mock USD not yet deposited)
  refreshPositions: () => Promise<void>
}

// ═══════════════════════════════════════════════════════════════════════════
// COMPONENT
// ═══════════════════════════════════════════════════════════════════════════

export default function StockExposureTab({
  connected, isLoading, txMutex, address, formatNumber,
  onDeposit, onWithdraw, positions, depositedQuid, walletBalance = 0, refreshPositions,
}: StockExposureProps) {

  // ── Local state ──
  const [subTab, setSubTab] = useState<'deposit' | 'open' | 'manage'>('deposit')
  const [category, setCategory] = useState('Crypto')
  const [search, setSearch] = useState('')
  const [selectedTicker, setSelectedTicker] = useState('')
  const [direction, setDirection] = useState<'long' | 'short'>('long')
  const [pledgeAmount, setPledgeAmount] = useState('')
  const [exposureAmount, setExposureAmount] = useState('')
  const [tickerPrice, setTickerPrice] = useState<number | null>(null)
  const [priceLoading, setPriceLoading] = useState(false)

  // Manage sub-tab state
  const [poolDepositAmount, setPoolDepositAmount] = useState('')
  const [manageTicker, setManageTicker] = useState('')
  const [manageAction, setManageAction] = useState<'increase' | 'decrease' | 'collateral'>('increase')
  const [manageAmount, setManageAmount] = useState('')

  // ── Filtered tickers ──
  const filteredTickers = useMemo(() => {
    const list = TICKER_CATEGORIES[category] || []
    if (!search) return list
    const q = search.toUpperCase()
    return list.filter(t => t.includes(q))
  }, [category, search])

  // ── Fetch price when ticker changes ──
  useEffect(() => {
    if (!selectedTicker) { setTickerPrice(null); return }
    let cancelled = false
    setPriceLoading(true)
    fetchTickerPrice(selectedTicker).then(p => {
      if (!cancelled) { setTickerPrice(p); setPriceLoading(false) }
    })
    return () => { cancelled = true }
  }, [selectedTicker])

  // ── Computed values ──
  const acKey = CATEGORY_ASSET_CLASS[category] || 'Crypto'
  const assetInfo = ASSET_CLASSES[acKey] || { maxLev: 3, minFeeBps: 4, label: category }
  const pledgeNum = parseFloat(pledgeAmount) || 0
  const exposureNum = parseFloat(exposureAmount) || 0
  const notional = tickerPrice ? exposureNum * tickerPrice : 0
  const leverage = pledgeNum > 0 ? notional / pledgeNum : 0

  // ── Handlers ──
  const handlePoolDeposit = useCallback(async () => {
    const amt = parseFloat(poolDepositAmount)
    if (!amt || amt <= 0) return
    // deposit(amount, "") — empty ticker = pool deposit path in entra.rs handle_in
    // tickerRisk account = null (Option<Account>::None), no Pyth needed
    await onDeposit('', poolDepositAmount)
    setPoolDepositAmount('')
    setTimeout(refreshPositions, 1500)
  }, [poolDepositAmount, onDeposit, refreshPositions])

  const handleOpenPosition = useCallback(async () => {
    if (!selectedTicker || !pledgeAmount || pledgeNum <= 0) return
    // Step 1: deposit(amount=pledgeNum, ticker=selectedTicker, exposure=false)
    //   → entra.rs: creates Stock with pledged collateral, zero exposure
    await onDeposit(selectedTicker, pledgeAmount)

    // Step 2: withdraw(amount=signed, ticker=selectedTicker, exposure=true)
    //   → clutch.rs → repo(): applies exposure
    if (exposureNum > 0) {
      // For long: positive amount increases exposure
      // For short: negative amount increases exposure (goes more negative)
      const signedAmount = direction === 'long'
        ? exposureAmount
        : (-exposureNum).toString()
      await onWithdraw(selectedTicker, signedAmount, true)
    }

    setPledgeAmount('')
    setExposureAmount('')
    setTimeout(refreshPositions, 3000)
  }, [selectedTicker, pledgeAmount, exposureAmount, direction, pledgeNum, exposureNum, onDeposit, onWithdraw, refreshPositions])

  const handleManagePosition = useCallback(async () => {
    if (!manageTicker || !manageAmount) return
    const amt = parseFloat(manageAmount)
    if (isNaN(amt) || amt <= 0) return

    const pos = positions.find(p => p.ticker === manageTicker)
    if (!pos) return

    if (manageAction === 'collateral') {
      // withdraw(amount=-amt, ticker, exposure=false) → just reduce pledged
      await onWithdraw(manageTicker, (-amt).toString(), false)
    } else if (manageAction === 'increase') {
      // increase: long → +amt, short → -amt
      const signed = pos.direction === 'short' ? (-amt).toString() : amt.toString()
      await onWithdraw(manageTicker, signed, true)
    } else {
      // decrease (take profit): long → -amt, short → +amt
      const signed = pos.direction === 'short' ? amt.toString() : (-amt).toString()
      await onWithdraw(manageTicker, signed, true)
    }

    setManageAmount('')
    setTimeout(refreshPositions, 3000)
  }, [manageTicker, manageAmount, manageAction, positions, onWithdraw, refreshPositions])

  // ═══════════════════════════════════════════════════════════════════════
  // RENDER
  // ═══════════════════════════════════════════════════════════════════════

  return (
    <div className="space-y-6">

      {/* ── Sub-tab toggle (reuses deposit sub-tab pattern) ── */}
      <div className="flex gap-1 p-1 rounded-lg bg-white/5">
        <button
          onClick={() => setSubTab('deposit')}
          className={`flex-1 py-2 rounded-md text-sm font-medium transition-all ${
            subTab === 'deposit' ? 'bg-white/10 text-white' : 'text-gray-500 hover:text-gray-300'
          }`}
        >
          💰 Deposit
        </button>
        <button
          onClick={() => setSubTab('manage')}
          className={`flex-1 py-2 rounded-md text-sm font-medium transition-all ${
            subTab === 'manage' ? 'bg-white/10 text-white' : 'text-gray-500 hover:text-gray-300'
          }`}
        >
          My Positions
        </button>
        <button
          onClick={() => setSubTab('open')}
          className={`flex-1 py-2 rounded-md text-sm font-medium transition-all ${
            subTab === 'open' ? 'bg-white/10 text-white' : 'text-gray-500 hover:text-gray-300'
          }`}
        >
          Open Position
        </button>
      </div>

      {/* ══════════════════════════════════════════════════════════════════ */}
      {/* DEPOSIT SUB-TAB — add QD to pool (empty ticker path)              */}
      {/* ══════════════════════════════════════════════════════════════════ */}
      {subTab === 'deposit' && (
        <div className="space-y-4">
          <div className="p-4 rounded-xl bg-black/20 border border-white/5">
            <p className="text-sm text-gray-400 mb-1">
              Deposit mock USD into the QU!D pool. This backs the depository and
              funds your prediction market bids without opening any stock exposure.
            </p>
            <p className="text-xs text-gray-600 mt-2">
              Calls: <code className="text-cyan-400">deposit(amount, "")</code> — empty ticker = pool deposit
            </p>
          </div>

          {/* Balance info */}
          <div className="grid grid-cols-2 gap-3">
            <div className="p-4 rounded-xl bg-white/5 border border-white/10">
              <p className="text-xs text-gray-500 uppercase tracking-wider mb-1">Wallet Balance</p>
              <p className="text-xl font-bold">
                {walletBalance > 0 ? `${formatNumber(walletBalance, 2)} QD` : '—'}
              </p>
            </div>
            <div className="p-4 rounded-xl bg-white/5 border border-white/10">
              <p className="text-xs text-gray-500 uppercase tracking-wider mb-1">Pool Balance</p>
              <p className="text-xl font-bold">
                {depositedQuid > 0 ? `${formatNumber(depositedQuid, 2)} QD` : '—'}
              </p>
            </div>
          </div>

          {/* Amount input */}
          <div>
            <label className="block text-sm text-gray-400 mb-2">Amount to Deposit (QD)</label>
            <div className="relative">
              <input
                type="number"
                value={poolDepositAmount}
                onChange={(e) => setPoolDepositAmount(e.target.value)}
                placeholder="0.0"
                min="100"
                className="w-full px-4 py-3 rounded-xl bg-black/30 border border-white/10 focus:border-cyan-500/50 focus:outline-none text-xl"
              />
              <div className="absolute right-3 top-1/2 -translate-y-1/2 flex items-center gap-2">
                {walletBalance > 0 && (
                  <button
                    onClick={() => setPoolDepositAmount(walletBalance.toString())}
                    className="px-3 py-1 rounded-md bg-white/10 text-xs text-cyan-400 hover:bg-white/20"
                  >
                    MAX
                  </button>
                )}
                <span className="text-sm text-gray-400">QD</span>
              </div>
            </div>
            <p className="mt-1 text-xs text-gray-600">Minimum deposit: 100 QD</p>
          </div>

          <button
            onClick={handlePoolDeposit}
            disabled={
              !connected || isLoading || txMutex ||
              !poolDepositAmount || parseFloat(poolDepositAmount) < 100
            }
            className="w-full py-4 rounded-xl font-bold text-lg bg-gradient-to-r from-cyan-500 to-blue-600 hover:opacity-90 transition-opacity disabled:opacity-50 disabled:cursor-not-allowed"
          >
            {!connected ? 'Connect Wallet'
              : isLoading ? 'Processing...'
              : `Deposit ${poolDepositAmount ? formatNumber(parseFloat(poolDepositAmount), 2) : ''} QD to Pool`
            }
          </button>
        </div>
      )}

      {/* ══════════════════════════════════════════════════════════════════ */}
      {/* MANAGE SUB-TAB — active positions list                           */}
      {/* ══════════════════════════════════════════════════════════════════ */}
      {subTab === 'manage' && (
        <>
          {/* Pool info bar (reuses stats row pattern) */}
          <div className="grid grid-cols-3 gap-3">
            <div className="p-4 rounded-xl bg-white/5 border border-white/10">
              <p className="text-xs text-gray-500 uppercase tracking-wider mb-1">Pool Deposits</p>
              <p className="text-xl font-bold">
                {depositedQuid > 0 ? `${formatNumber(depositedQuid, 2)} QD` : '—'}
              </p>
              {walletBalance > 0 && (
                <p className="text-xs text-gray-500 mt-1">
                  +{formatNumber(walletBalance, 2)} in wallet
                </p>
              )}
            </div>
            <div className="p-4 rounded-xl bg-white/5 border border-white/10">
              <p className="text-xs text-gray-500 uppercase tracking-wider mb-1">Open Positions</p>
              <p className="text-xl font-bold">{positions.length}</p>
            </div>
            <div className="p-4 rounded-xl bg-white/5 border border-white/10">
              <p className="text-xs text-gray-500 uppercase tracking-wider mb-1">Total Exposure</p>
              <p className="text-xl font-bold">
                {positions.length > 0
                  ? `$${formatNumber(positions.reduce((s, p) => s + Math.abs(p.exposure) * p.price, 0), 0)}`
                  : '—'
                }
              </p>
            </div>
          </div>

          {/* Position cards (reuses selfManagedPositions.map pattern) */}
          {positions.length > 0 ? (
            <div className="space-y-2">
              {positions.map((pos) => {
                const isSelected = manageTicker === pos.ticker
                const exposureValue = Math.abs(pos.exposure) * pos.price
                const pnlColor = pos.pnlPct >= 0 ? 'text-green-400' : 'text-red-400'
                const dirColor = pos.direction === 'long' ? 'text-cyan-400' : 'text-orange-400'
                const dirIcon = pos.direction === 'long' ? '📈' : '📉'

                return (
                  <div key={pos.ticker}>
                    {/* Card — same layout as position #{pos.id} cards */}
                    <div
                      className={`p-3 rounded-xl border transition-all cursor-pointer ${
                        isSelected
                          ? 'bg-cyan-500/10 border-cyan-500/30'
                          : 'bg-white/5 border-white/10 hover:border-white/20'
                      }`}
                      onClick={() => setManageTicker(isSelected ? '' : pos.ticker)}
                    >
                      <div className="flex items-center justify-between">
                        <div>
                          <div className="flex items-center gap-2">
                            <span className="text-sm font-medium text-white">{pos.ticker}</span>
                            <span className={`text-xs font-medium ${dirColor}`}>
                              {dirIcon} {pos.direction.toUpperCase()}
                            </span>
                            <span className="text-[10px] text-gray-500">
                              {pos.leverage.toFixed(1)}x
                            </span>
                          </div>
                          <p className="text-[10px] text-gray-500">
                            Pledged: {formatNumber(pos.pledged, 2)} QD
                            {' • '}Exposure: ${formatNumber(exposureValue, 2)}
                            {' • '}Collar: {pos.collarBps}bps
                          </p>
                        </div>
                        <div className="text-right">
                          <p className="text-sm font-medium text-white">
                            ${formatNumber(pos.price, pos.price < 1 ? 6 : 2)}
                          </p>
                          <p className={`text-xs font-medium ${pnlColor}`}>
                            {pos.pnlPct >= 0 ? '+' : ''}{pos.pnlPct.toFixed(2)}%
                          </p>
                        </div>
                      </div>
                    </div>

                    {/* Expanded manage controls (appears on click) */}
                    {isSelected && (
                      <div className="mt-2 p-4 rounded-xl bg-black/20 border border-white/5 space-y-4">
                        {/* Action toggle (reuses inline-flex toggle pattern) */}
                        <div className="flex justify-center">
                          <div className="inline-flex p-1 rounded-lg bg-black/30 border border-white/10">
                            {(['increase', 'decrease', 'collateral'] as const).map(a => (
                              <button
                                key={a}
                                onClick={() => setManageAction(a)}
                                className={`px-4 py-2 rounded-md text-sm font-medium transition-all ${
                                  manageAction === a
                                    ? a === 'decrease' ? 'bg-orange-500/20 text-orange-400'
                                    : a === 'collateral' ? 'bg-purple-500/20 text-purple-400'
                                    : 'bg-cyan-500/20 text-cyan-400'
                                    : 'text-gray-400 hover:text-white'
                                }`}
                              >
                                {a === 'increase' ? '↗ Add Exposure'
                                  : a === 'decrease' ? '↙ Take Profit'
                                  : '🏦 Withdraw Collateral'}
                              </button>
                            ))}
                          </div>
                        </div>

                        {/* Amount input (reuses standard input pattern) */}
                        <div className="relative">
                          <input
                            type="number"
                            value={manageAmount}
                            onChange={(e) => setManageAmount(e.target.value)}
                            placeholder="0.0"
                            className="w-full px-4 py-3 rounded-xl bg-black/30 border border-white/10 focus:border-cyan-500/50 focus:outline-none text-xl"
                          />
                          <span className="absolute right-3 top-1/2 -translate-y-1/2 text-sm text-gray-400">
                            {manageAction === 'collateral' ? 'QD' : 'units'}
                          </span>
                        </div>

                        {/* Info box (reuses info summary pattern) */}
                        <div className="p-3 rounded-xl bg-white/5 border border-white/10">
                          {manageAction === 'increase' && (
                            <>
                              <div className="flex justify-between text-sm mb-1">
                                <span className="text-gray-400">Action</span>
                                <span className="text-cyan-400">
                                  Add {pos.direction} exposure
                                </span>
                              </div>
                              <div className="flex justify-between text-sm">
                                <span className="text-gray-400">New Leverage</span>
                                <span className="text-white">
                                  {manageAmount
                                    ? `${((Math.abs(pos.exposure) + parseFloat(manageAmount || '0')) * pos.price / pos.pledged).toFixed(1)}x`
                                    : `${pos.leverage.toFixed(1)}x`
                                  }
                                </span>
                              </div>
                            </>
                          )}
                          {manageAction === 'decrease' && (
                            <>
                              <div className="flex justify-between text-sm mb-1">
                                <span className="text-gray-400">Action</span>
                                <span className="text-orange-400">Take profit / reduce</span>
                              </div>
                              <div className="flex justify-between text-sm">
                                <span className="text-gray-400">Payout Est.</span>
                                <span className="text-green-400">
                                  {manageAmount && pos.price > 0
                                    ? `~$${formatNumber(parseFloat(manageAmount) * pos.price, 2)}`
                                    : '—'}
                                </span>
                              </div>
                            </>
                          )}
                          {manageAction === 'collateral' && (
                            <>
                              <div className="flex justify-between text-sm mb-1">
                                <span className="text-gray-400">Action</span>
                                <span className="text-purple-400">Withdraw pledged QD</span>
                              </div>
                              <div className="flex justify-between text-sm">
                                <span className="text-gray-400">Remaining Pledge</span>
                                <span className="text-white">
                                  {manageAmount
                                    ? `${formatNumber(Math.max(0, pos.pledged - parseFloat(manageAmount || '0')), 2)} QD`
                                    : `${formatNumber(pos.pledged, 2)} QD`
                                  }
                                </span>
                              </div>
                            </>
                          )}
                        </div>

                        {/* Submit button */}
                        <button
                          onClick={handleManagePosition}
                          disabled={!connected || isLoading || txMutex || !manageAmount || parseFloat(manageAmount) <= 0}
                          className={`w-full py-3 rounded-xl font-bold text-sm hover:opacity-90 transition-opacity disabled:opacity-50 disabled:cursor-not-allowed ${
                            manageAction === 'decrease'
                              ? 'bg-gradient-to-r from-orange-500 to-red-500'
                              : manageAction === 'collateral'
                              ? 'bg-gradient-to-r from-purple-500 to-indigo-600'
                              : 'bg-gradient-to-r from-cyan-500 to-blue-600'
                          }`}
                        >
                          {isLoading ? 'Processing...'
                            : manageAction === 'increase' ? `Add ${pos.direction} Exposure`
                            : manageAction === 'decrease' ? 'Take Profit'
                            : 'Withdraw Collateral'
                          }
                        </button>
                      </div>
                    )}
                  </div>
                )
              })}
            </div>
          ) : (
            <div className="text-center py-8">
              <p className="text-gray-500 text-sm mb-3">No open stock positions</p>
              <button
                onClick={() => setSubTab('open')}
                className="px-6 py-2 rounded-lg bg-white/10 text-sm text-cyan-400 hover:bg-white/15 transition-all"
              >
                Open a Position →
              </button>
            </div>
          )}
        </>
      )}

      {/* ══════════════════════════════════════════════════════════════════ */}
      {/* OPEN SUB-TAB — new position wizard                               */}
      {/* ══════════════════════════════════════════════════════════════════ */}
      {subTab === 'open' && (
        <>
          {/* Category selector (reuses token-grid 5-col pattern) */}
          <div>
            <label className="block text-sm text-gray-400 mb-2">Asset Class</label>
            <div className="grid grid-cols-6 gap-2">
              {Object.keys(TICKER_CATEGORIES).map(cat => (
                <button
                  key={cat}
                  onClick={() => { setCategory(cat); setSelectedTicker(''); setSearch('') }}
                  className={`p-2 rounded-lg text-xs font-medium border transition-all ${
                    category === cat
                      ? 'bg-cyan-500/20 border-cyan-500/50 text-cyan-400'
                      : 'bg-white/5 border-white/10 text-gray-400 hover:border-white/20'
                  }`}
                >
                  {cat}
                  <span className="block text-[10px] text-gray-500 mt-0.5">
                    ≤{ASSET_CLASSES[CATEGORY_ASSET_CLASS[cat] || 'Crypto']?.maxLev || 3}x
                  </span>
                </button>
              ))}
            </div>
          </div>

          {/* Ticker search + grid (reuses stablecoin selector pattern) */}
          <div>
            <div className="flex justify-between items-center mb-2">
              <label className="text-sm text-gray-400">Select Ticker</label>
              <div className="relative">
                <input
                  type="text"
                  value={search}
                  onChange={(e) => setSearch(e.target.value)}
                  placeholder="Search..."
                  className="w-32 px-3 py-1 rounded-lg bg-black/30 border border-white/10 text-xs focus:border-cyan-500/50 focus:outline-none"
                />
              </div>
            </div>
            <div className="grid grid-cols-5 gap-2 max-h-48 overflow-y-auto">
              {filteredTickers.map(ticker => {
                const isSelected = selectedTicker === ticker
                const hasPyth = !!PYTH_ACCOUNTS[ticker]
                return (
                  <button
                    key={ticker}
                    onClick={() => setSelectedTicker(isSelected ? '' : ticker)}
                    disabled={!hasPyth}
                    className={`p-3 rounded-xl border transition-all text-left ${
                      isSelected
                        ? 'bg-cyan-500/20 border-cyan-500/50 text-cyan-400'
                        : hasPyth
                        ? 'bg-white/5 border-white/10 text-gray-400 hover:border-white/20'
                        : 'bg-white/[0.02] border-white/5 opacity-40 cursor-not-allowed'
                    }`}
                  >
                    <span className={`text-sm font-medium ${isSelected ? 'text-cyan-400' : ''}`}>
                      {ticker}
                    </span>
                    {!hasPyth && (
                      <span className="block text-[9px] text-gray-600 mt-0.5">No feed</span>
                    )}
                  </button>
                )
              })}
            </div>
          </div>

          {/* Direction toggle */}
          {selectedTicker && (
            <>
              <div>
                <label className="block text-sm text-gray-400 mb-2">Direction</label>
                <div className="inline-flex p-1 rounded-lg bg-black/30 border border-white/10">
                  <button
                    onClick={() => setDirection('long')}
                    className={`px-4 py-2 rounded-md text-sm font-medium transition-all ${
                      direction === 'long' ? 'bg-cyan-500/20 text-cyan-400' : 'text-gray-400 hover:text-white'
                    }`}
                  >
                    📈 Long
                  </button>
                  <button
                    onClick={() => setDirection('short')}
                    className={`px-4 py-2 rounded-md text-sm font-medium transition-all ${
                      direction === 'short' ? 'bg-orange-500/20 text-orange-400' : 'text-gray-400 hover:text-white'
                    }`}
                  >
                    📉 Short
                  </button>
                </div>
              </div>

              {/* Collateral input */}
              <div>
                <label className="block text-sm text-gray-400 mb-2">Pledge Collateral (QD)</label>
                <div className="relative">
                  <input
                    type="number"
                    value={pledgeAmount}
                    onChange={(e) => setPledgeAmount(e.target.value)}
                    placeholder="0.0"
                    className="w-full px-4 py-3 rounded-xl bg-black/30 border border-white/10 focus:border-cyan-500/50 focus:outline-none text-xl"
                  />
                  <div className="absolute right-3 top-1/2 -translate-y-1/2 flex items-center gap-2">
                    {depositedQuid > 0 && (
                      <button
                        onClick={() => setPledgeAmount(depositedQuid.toString())}
                        className="px-3 py-1 rounded-md bg-white/10 text-xs text-cyan-400 hover:bg-white/20"
                      >
                        MAX
                      </button>
                    )}
                    <span className="text-sm text-gray-400">QD</span>
                  </div>
                </div>
                <p className="mt-2 text-sm text-gray-500">
                  Available: {formatNumber(depositedQuid, 2)} QD in pool
                </p>
              </div>

              {/* Exposure input */}
              <div>
                <label className="block text-sm text-gray-400 mb-2">
                  Exposure Amount ({selectedTicker} units)
                </label>
                <div className="relative">
                  <input
                    type="number"
                    value={exposureAmount}
                    onChange={(e) => setExposureAmount(e.target.value)}
                    placeholder="0.0"
                    className="w-full px-4 py-3 rounded-xl bg-black/30 border border-white/10 focus:border-cyan-500/50 focus:outline-none text-xl"
                  />
                  <span className="absolute right-3 top-1/2 -translate-y-1/2 text-sm text-gray-400">
                    {selectedTicker}
                  </span>
                </div>
              </div>

              {/* Position summary (reuses info box pattern) */}
              <div className="p-4 rounded-xl bg-black/20 border border-white/5">
                <div className="flex justify-between text-sm mb-2">
                  <span className="text-gray-400">Ticker</span>
                  <span className="text-white">{selectedTicker}</span>
                </div>
                <div className="flex justify-between text-sm mb-2">
                  <span className="text-gray-400">Current Price</span>
                  <span className="text-white">
                    {priceLoading ? '...' : tickerPrice
                      ? `$${formatNumber(tickerPrice, tickerPrice < 1 ? 6 : 2)}`
                      : '—'
                    }
                  </span>
                </div>
                <div className="flex justify-between text-sm mb-2">
                  <span className="text-gray-400">Direction</span>
                  <span className={direction === 'long' ? 'text-cyan-400' : 'text-orange-400'}>
                    {direction === 'long' ? '📈 Long' : '📉 Short'} {selectedTicker}
                  </span>
                </div>
                <div className="flex justify-between text-sm mb-2">
                  <span className="text-gray-400">Notional Value</span>
                  <span className="text-white">
                    {notional > 0 ? `$${formatNumber(notional, 2)}` : '—'}
                  </span>
                </div>
                <div className="flex justify-between text-sm mb-2">
                  <span className="text-gray-400">Leverage</span>
                  <span className={leverage > assetInfo.maxLev
                    ? 'text-red-400' : leverage > 0 ? 'text-green-400' : 'text-gray-400'
                  }>
                    {leverage > 0 ? `${leverage.toFixed(1)}x` : '—'}
                    {leverage > assetInfo.maxLev && ` (max: ${assetInfo.maxLev}x)`}
                  </span>
                </div>
                <div className="flex justify-between text-sm">
                  <span className="text-gray-400">Asset Class</span>
                  <span className="text-gray-300">{assetInfo.label}</span>
                </div>
              </div>

              {/* Leverage warning */}
              {leverage > assetInfo.maxLev && (
                <div className="p-3 rounded-lg bg-red-500/10 border border-red-500/30 text-red-400 text-sm">
                  Leverage {leverage.toFixed(1)}x exceeds max {assetInfo.maxLev}x for {assetInfo.label}. Reduce exposure or add more collateral.
                </div>
              )}

              {/* Open position button */}
              <button
                onClick={handleOpenPosition}
                disabled={
                  !connected || isLoading || txMutex ||
                  !selectedTicker || pledgeNum <= 0 ||
                  leverage > assetInfo.maxLev
                }
                className={`w-full py-4 rounded-xl font-bold text-lg hover:opacity-90 transition-opacity disabled:opacity-50 disabled:cursor-not-allowed ${
                  direction === 'long'
                    ? 'bg-gradient-to-r from-cyan-500 to-blue-600'
                    : 'bg-gradient-to-r from-orange-500 to-red-500'
                }`}
              >
                {!connected ? 'Connect Wallet'
                  : isLoading ? 'Processing...'
                  : exposureNum > 0
                  ? `Open ${direction.toUpperCase()} ${selectedTicker} (${leverage.toFixed(1)}x)`
                  : `Pledge Collateral for ${selectedTicker}`
                }
              </button>

              {/* Signed amount explanation */}
              <div className="p-3 rounded-xl bg-cyan-500/5 border border-cyan-500/20">
                <p className="text-xs text-cyan-400/80">
                  {direction === 'long'
                    ? `Long: positive amount → increase exposure. The program calls withdraw(+${exposureNum || 0}, "${selectedTicker}", true) which routes to repo() adding long exposure.`
                    : `Short: negative amount → increase exposure. The program calls withdraw(-${exposureNum || 0}, "${selectedTicker}", true) which routes to repo() adding short exposure.`
                  }
                </p>
              </div>
            </>
          )}
        </>
      )}

      {!connected && (
        <p className="text-center text-gray-500 text-sm py-4">
          Connect a Solana wallet (Phantom) to manage stock exposure positions.
        </p>
      )}
    </div>
  )
}

// ═══════════════════════════════════════════════════════════════════════════
// INTEGRATION SNIPPET — paste into page.tsx
// ═══════════════════════════════════════════════════════════════════════════

/*

1. Add to tab list (line ~1912):

   {['mint', 'deposit', 'withdraw', 'swap', 'exposure', 'predictions'].map((tab) => (
     <button key={tab} onClick={() => setActiveTab(tab)}
       className={`flex-1 py-2 rounded-md text-sm font-medium capitalize transition-all ${
         activeTab === tab ? 'bg-white/10 text-white' : 'text-gray-500 hover:text-gray-300'
       }`}
     >
       {tab === 'mint' ? 'Mint QD' : tab === 'predictions' ? '📊 De-pegs' : tab === 'exposure' ? '📈 Stocks' : tab}
     </button>
   ))}

2. Add tab content (after withdraw tab, before swap tab):

   {activeTab === 'exposure' && (
     <StockExposureTab
       connected={connected}
       isLoading={isLoading}
       txMutex={txMutex}
       address={address}
       formatNumber={formatNumber}
       onDeposit={async (ticker, amount) => {
         // Call Solana program.methods.deposit(BigInt(parseFloat(amount) * 1e18), ticker, false)
         //   .accounts({ ... })
         //   .rpc()
       }}
       onWithdraw={async (ticker, amount, exposure) => {
         // Call Solana program.methods.withdraw(BigInt(parseFloat(amount) * ???), ticker, exposure)
         //   .accounts({ ... })
         //   .remainingAccounts([{ pubkey: new PublicKey(PYTH_ACCOUNTS[ticker]), ... }])
         //   .rpc()
       }}
       positions={stockPositions}
       depositedQuid={Number(depositedQuid) / 1e18}
       refreshPositions={async () => {
         // Fetch depositor account and parse balances
       }}
     />
   )}

3. The onDeposit and onWithdraw callbacks should build Solana transactions:
   - onDeposit: calls `deposit(amount, ticker, false)` → entra.rs handle_in
   - onWithdraw: calls `withdraw(signed_amount, ticker, exposure)` → clutch.rs handle_out
     with remaining_accounts = [PYTH_ACCOUNTS[ticker]]
   - For pool withdraw with credit clearing (ticker="", exposure=true),
     ALL pyth accounts for user's positions must be in remaining_accounts

*/
