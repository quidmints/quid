/**
 * QU!D Protocol Keeper Bot
 * imports Solana keepers (their scope described in their respective files)
 *
 * Ethereum Responsibilities:
 * 1. Monitor leveraged positions and call unwind when price moves ±2.5%
 * 2. Monthly round resolution: call UMA.resolveAsNone after MONTH elapsed (side 0)
 *    Or UMA.requestResolution for depeg claims (side > 0, caller-funded bond)
 * 3. Settle assertions once liveness passes
 * 4. Auto-reveal confidences from MongoDB after resolution
 * 5. Hook lifecycle: calculateWeights → pushPayouts
 * 6. Restart market for next round after payouts complete
 * 7. Burn accumulated Hook fees periodically
 * 8. Court/Jury arbitration lifecycle:
 *    - progressToJurySelection (RANDAO headers)
 *    - Auto-reveal jury votes from MongoDB (same pattern as Hook reveals)
 *    - finalizeRound (RANDAO headers)
 *    - executeVerdict after appeal window
 *    - recoverMissedWindow fallback
 *
 * Environment Variables:
 *   KEEPER_PRIVATE_KEY    — Wallet key for Amp unwinds (gas payer)
 *   DELEGATE_PRIVATE_KEY  — Basket deployer key for Hook/UMA operations
 *                           (requestResolution, settleAssertion, calculateWeights,
 *                            pushPayouts, restartMarket, burnFees)
 *                           If not set, falls back to KEEPER_PRIVATE_KEY.
 *   MONGODB_URI           — MongoDB connection string (default: mongodb://localhost:27017/quid)
 *   L1_RPC                — Ethereum L1 RPC endpoint
 *   BASE_RPC              — Base RPC endpoint
 *   ARBITRUM_RPC          — Arbitrum RPC endpoint
 *
 * Key placement:
 *   Create a .env file alongside keeper.ts:
 *     KEEPER_PRIVATE_KEY=0x...
 *     DELEGATE_PRIVATE_KEY=0x...    # Basket deployer key
 *     MONGODB_URI=mongodb://localhost:27017/quid
 *     L1_RPC=https://eth.llamarpc.com
 *     BASE_RPC=https://mainnet.base.org
 *     ARBITRUM_RPC=https://arb1.arbitrum.io/rpc
 *
 *   Load with: source .env && npx ts-node keeper.ts
 *   Or use dotenv: npm install dotenv, then require('dotenv').config() at top
 *
 * Run: npx ts-node keeper.ts
 * Or compile: npx tsc keeper.ts && node keeper.js
 */


import { SolanaKeeper } from './keeper_solana'
import { PredictionMarketKeeper } from './keeper_prediction'
import { ethers } from 'ethers'

// Optional: uncomment if using dotenv
// require('dotenv').config()

// ============== CONFIGURATION ==============
const CONFIG = {
  RPC: {
    1: process.env.L1_RPC || 'https://eth.llamarpc.com',
    8453: process.env.BASE_RPC || 'https://mainnet.base.org',
    42161: process.env.ARBITRUM_RPC || 'https://arb1.arbitrum.io/rpc',
  } as Record<number, string>,

  CONTRACTS: {
    1: {
      aux: '0x67871019C03A81D5a510c7A8F707F0465098fE72',
      amp: '0x3cD9ef974354092C375C807122b9E1B245FD5D84',
      vogue: '0x12DD3cD054D0fe8e36486Daf504c8652396f5edC',
    },
    8453: {
      aux: '0xB3Ab6732580D9b75E8f6eb3ea8204500E9872D75',
      amp: '0x48AE204e2e2dd73C6ab6B20A040902511E48f552',
      vogue: '0x64830Cc6682C36dE6EAA1Afc771FBfc16322D092',
    },
    42161: {
      aux: '0xBb7BB6C91BDeA9502f2591B4AA71dBa3A70FF851',
      amp: '0x24896a2e1BA25903af0bBA86bE4752aDEC09bDC1',
      vogue: '0x09a0519D00fc98A1a055B5FB38d35C7668d1789F',
    },
  } as Record<number, { aux: string; amp: string; vogue: string }>,

  // Hook + UMA — L1 only for now
  HOOK: {
    1: '0x56176EBfe849206063F793b9a4869770F3851244',
  } as Record<number, string>,

  UMA: {
    1: '0x9a0A677Ae11c4E841AD7Dc9d7d24CB53D6BFBe85',
  } as Record<number, string>,

  COURT: {
    1: '0x0000000000000000000000000000000000000000', // TODO: set after deploy
  } as Record<number, string>,

  JURY: {
    1: '0x0000000000000000000000000000000000000000', // TODO: set after deploy
  } as Record<number, string>,

  PRIVATE_KEY: process.env.KEEPER_PRIVATE_KEY || '',
  DELEGATE_KEY: process.env.DELEGATE_PRIVATE_KEY || process.env.KEEPER_PRIVATE_KEY || '',
  MONGODB_URI: process.env.MONGODB_URI || 'mongodb://localhost:27017/quid',
  MONGODB_API: process.env.MONGODB_API || 'http://localhost:3000', // Next.js API base URL

  CHECK_INTERVAL: 15_000,       // Amp position checks: every 15s
  HOOK_INTERVAL: 60_000,        // Hook lifecycle checks: every 60s
  FEE_BURN_INTERVAL: 3_600_000, // Fee burns: every hour
  COURT_INTERVAL: 30_000,       // Court lifecycle checks: every 30s (tight finalize window)
  PRICE_DELTA_THRESHOLD: 25,    // ±2.5% triggers unwind

  MARKET_ID: 1,
  DEFAULT_CLAIM_SIDE: 0,        // "none depegs" — override if depeg detected
  MIN_TRADING_PERIOD: 30 * 24 * 3600, // Must match FeeLib.MONTH — resolveAsNone requires this elapsed

  // Court timing constants (must match Court.sol)
  COMMIT_PERIOD: 4 * 24 * 3600,     // 4 days
  REVEAL_WINDOW: 12 * 3600,          // 12 hours
  APPEAL_WINDOW: 7 * 24 * 3600,      // 7 days
  FINALIZE_BLOCK_WINDOW: 50,          // ~10 min at 12s/block

  // Amp runs on all chains, Hook/UMA only on L1
  ACTIVE_CHAINS: [1, 8453, 42161] as const,
  HOOK_CHAINS: [1] as const,
}

// ============== UMA Phase Enum ==============
const Phase = {
  Trading: 0,
  Asserting: 1,
  Disputed: 2,
  Resolved: 3,
} as const

// ============== ABIs ==============
// NOTE: All uint types match Solidity's `uint` (= uint256).
// Using smaller types (uint64, uint40, etc.) produces wrong function selectors.

const AUX_ABI = [
  'function getTWAP(uint32 period) view returns (uint256)',
  'function leverETH(uint256 amount) payable external',
  'function leverUSD(uint256 amount, address token) external',
]

const AMP_ABI = [
  'function unwindZeroForOne(address[] calldata whose) external',
  'function unwindOneForZero(address[] calldata whose) external',
  'event LeveragedPositionOpened(address indexed user, bool indexed isLong, uint256 supplied, uint256 borrowed, uint256 buffer, int256 entryPrice, uint256 breakeven, uint256 blockNumber)',
  'event PositionUnwound(address indexed user, bool indexed isLong, int256 exitPrice, int256 priceDelta, uint256 blockNumber)',
]

const VOGUE_ABI = [
  'function getSwapsETH(uint256 blockNumber) view returns (tuple(uint256 total, address[] depositors, uint256[] amounts), tuple(uint256 total, address[] depositors, uint256[] amounts))',
]

const HOOK_ABI = [
  // Write functions — Hook.sol is single-market, no mktId param
  'function calculateWeights(address[] calldata users, uint8[] calldata sides, tuple(uint256 confidence, bytes32 salt)[] reveals, uint256[] calldata revealCounts)',
  'function pushPayouts(address[] calldata users, uint8[] calldata sides)',
  'function burnAccumulatedFees()',
  'function settleAssertion()',

  // View functions
  'function getMarket() view returns (tuple(uint256 marketId, uint8 numSides, uint256 startTime, uint256 roundStartTime, int128 b, bool resolved, uint8 winningSide, uint256 resolutionTimestamp, int128[12] q, uint256[12] capitalPerSide, uint256 totalCapital, uint256 positionsTotal, uint256 positionsRevealed, uint256 totalWinnerCapital, uint256 totalLoserCapital, uint256 totalWinnerWeight, uint256 totalLoserWeight, bool weightsComplete, bool payoutsComplete, bool assertionPending, uint256 positionsPaidOut, uint256 positionsWeighed, uint256 roundNumber))',
  'function getPosition(address user, uint8 side) view returns (tuple(address user, uint8 side, uint256 totalCapital, uint256 totalTokens, bytes32 commitmentHash, bool revealed, uint256 revealedConfidence, bool autoRollover, uint256 weight, bool paidOut, uint256 entryTimestamp, uint256 lastRound, address delegate))',
  'function accumulatedFees() view returns (uint256)',

  // Events — no mktId indexed
  'event ConfidenceRevealed(address indexed user, uint8 side, uint256 confidence)',
  'event OrderPlaced(address indexed user, uint8 side, uint256 capital, uint256 tokens)',
  'event Recommitted(address indexed user, uint8 side, uint256 tokens)',
]

const UMA_ABI = [
  // Write functions — UMA.sol is single-market, no mktId param
  'function requestResolution(uint8 claimedSide) returns (bytes32)',
  'function resolveAsNone()',
  'function restartMarket()',

  // View functions
  'function getAssertionInfo() view returns (uint8 phase, uint8 claimedSide, uint256 round, uint8 rejections)',
  'function isRevealOpen() view returns (bool)',
  'function isTradingEnabled() view returns (bool)',
  'function getMinimumBond() view returns (uint256)',
  'function disputeCapacity() view returns (uint256)',
]

const COURT_ABI = [
  // Write — permissionless state-transition drivers
  'function progressToJurySelection(uint64 marketId, uint8 round, bytes[] calldata headers)',
  'function finalizeRound(uint64 marketId, bytes[] calldata headers)',
  'function executeVerdict(uint64 marketId)',
  'function recoverMissedWindow(uint64 marketId)',
  'function timeoutJuryCompensation(uint64 marketId)',

  // View
  'function getMarketConfig(uint64 marketId) view returns (uint8 numSides, uint8 numWinners, bool requiresUnanimous, bool requiresSignature)',
  'function getRoundStartTime(uint64 marketId) view returns (uint256)',
  'function getCurrentRound(uint64 marketId) view returns (uint8)',
  'function getVerdictTimestamp(uint64 marketId) view returns (uint256)',
  'function getFinalizeWindow(uint64 marketId) view returns (uint256 eligibleBlock, uint256 windowEnd)',
  'function isReadyForExecution(uint64 marketId) view returns (bool ready, string reason)',

  // Events — keeper listens for these to discover active markets
  'event ArbitrationReceived(uint64 indexed marketId, bytes32 assertionId, uint8 claimedSide, uint8 recommendedSide)',
  'event ResolutionReceived(uint64 indexed marketId, uint8 numSides)',
  'event ResolutionFinalized(uint64 indexed marketId, uint8[] verdict)',
  'event ForceMajeure(uint64 indexed marketId)',
  'event MarketExtended(uint64 indexed marketId)',
]

const JURY_ABI = [
  // Write — delegate can reveal on juror's behalf
  'function revealVote(uint64 marketId, uint8 round, uint8[] calldata sides, bytes32 salt, address juror)',

  // View
  'function revealed(uint64, uint8, address) view returns (bool)',
  'function delegates(uint64, uint8, address) view returns (address)',
  'function commits(uint64, uint8, address) view returns (bytes32)',
]

// ============== TYPES ==============
interface Position {
  user: string
  isLong: boolean
  entryPrice: bigint
  breakeven: bigint
  supplied: bigint
  borrowed: bigint
  buffer: bigint
  blockNumber: number
  chainId: number
}

interface ChainState {
  provider: ethers.JsonRpcProvider
  wallet: ethers.Wallet | null
  delegateWallet: ethers.Wallet | null
  aux: ethers.Contract
  amp: ethers.Contract
  vogue: ethers.Contract
  hook: ethers.Contract | null
  uma: ethers.Contract | null
  court: ethers.Contract | null
  jury: ethers.Contract | null
  positions: Map<string, Position>
  lastProcessedBlock: number
  revealedUsers: Map<string, { user: string; side: number }>
  orderedUsers: Map<string, { user: string; side: number }>
  activeCourtMarkets: Set<number>  // auto-populated from Court events
}

// ============== KEEPER CLASS ==============
class QuidKeeper {
  private chains: Map<number, ChainState> = new Map()
  private isRunning = false

  constructor() {
    console.log('🤖 QU!D Keeper Bot Initializing...')
  }

  async initialize(): Promise<void> {
    for (const chainId of CONFIG.ACTIVE_CHAINS) {
      const rpc = CONFIG.RPC[chainId]
      if (!rpc) { console.warn(`⚠️ No RPC for chain ${chainId}`); continue }

      const provider = new ethers.JsonRpcProvider(rpc)
      const contracts = CONFIG.CONTRACTS[chainId]

      let wallet: ethers.Wallet | null = null
      if (CONFIG.PRIVATE_KEY) {
        wallet = new ethers.Wallet(CONFIG.PRIVATE_KEY, provider)
        console.log(`💰 Keeper wallet: ${wallet.address} (chain ${chainId})`)
      } else {
        console.warn('⚠️ No KEEPER_PRIVATE_KEY — read-only mode')
      }

      let delegateWallet: ethers.Wallet | null = null
      if (CONFIG.DELEGATE_KEY) {
        delegateWallet = new ethers.Wallet(CONFIG.DELEGATE_KEY, provider)
        if (delegateWallet.address !== wallet?.address) {
          console.log(`🔑 Delegate wallet: ${delegateWallet.address} (chain ${chainId})`)
        }
      }

      const aux = new ethers.Contract(contracts.aux, AUX_ABI, wallet || provider)
      const amp = new ethers.Contract(contracts.amp, AMP_ABI, wallet || provider)
      const vogue = new ethers.Contract(contracts.vogue, VOGUE_ABI, provider)

      // Hook + UMA — only on configured chains (L1)
      const hookAddr = CONFIG.HOOK[chainId]
      let hook: ethers.Contract | null = null
      if (hookAddr && hookAddr !== ethers.ZeroAddress) {
        hook = new ethers.Contract(hookAddr, HOOK_ABI, delegateWallet || wallet || provider)
        console.log(`🔮 Hook: ${hookAddr} (chain ${chainId})`)
      }

      const umaAddr = CONFIG.UMA[chainId]
      let uma: ethers.Contract | null = null
      if (umaAddr && umaAddr !== ethers.ZeroAddress) {
        uma = new ethers.Contract(umaAddr, UMA_ABI, delegateWallet || wallet || provider)
        console.log(`⚡ UMA: ${umaAddr} (chain ${chainId})`)
      }

      // Court + Jury — L1 only, same as Hook/UMA
      const courtAddr = CONFIG.COURT[chainId]
      let court: ethers.Contract | null = null
      if (courtAddr && courtAddr !== ethers.ZeroAddress) {
        court = new ethers.Contract(courtAddr, COURT_ABI, delegateWallet || wallet || provider)
        console.log(`⚖️ Court: ${courtAddr} (chain ${chainId})`)
      }

      const juryAddr = CONFIG.JURY[chainId]
      let jury: ethers.Contract | null = null
      if (juryAddr && juryAddr !== ethers.ZeroAddress) {
        jury = new ethers.Contract(juryAddr, JURY_ABI, delegateWallet || wallet || provider)
        console.log(`🏛️ Jury: ${juryAddr} (chain ${chainId})`)
      }

      const currentBlock = await provider.getBlockNumber()

      this.chains.set(chainId, {
        provider, wallet, delegateWallet, aux, amp, vogue, hook, uma, court, jury,
        positions: new Map(),
        lastProcessedBlock: currentBlock - 1000,
        revealedUsers: new Map(),
        orderedUsers: new Map(),
        activeCourtMarkets: new Set(),  // populated by loadActiveCourtMarkets
      })

      console.log(`✅ Chain ${chainId} initialized at block ${currentBlock}`)
    }
  }

  // ─── AMP (Leverage Unwinds) ────────────────────────────────────

  async loadHistoricalPositions(chainId: number): Promise<void> {
    const state = this.chains.get(chainId)
    if (!state) return

    console.log(`📜 Loading historical positions for chain ${chainId}...`)
    const currentBlock = await state.provider.getBlockNumber()
    const fromBlock = Math.max(0, currentBlock - 50000)

    try {
      const openEvents = await state.amp.queryFilter(state.amp.filters.LeveragedPositionOpened(), fromBlock, currentBlock)
      const closeEvents = await state.amp.queryFilter(state.amp.filters.PositionUnwound(), fromBlock, currentBlock)
      const closedUsers = new Set(closeEvents.map((e: any) => e.args.user.toLowerCase()))

      for (const event of openEvents) {
        const args = (event as any).args
        const user = args.user.toLowerCase()
        if (closedUsers.has(user)) continue
        state.positions.set(`${chainId}-${user}-${args.isLong}`, {
          user: args.user, isLong: args.isLong, entryPrice: args.entryPrice,
          breakeven: args.breakeven, supplied: args.supplied, borrowed: args.borrowed,
          buffer: args.buffer, blockNumber: Number(args.blockNumber), chainId,
        })
      }
      console.log(`📊 Loaded ${state.positions.size} active positions on chain ${chainId}`)
    } catch (error) {
      console.error(`❌ Error loading positions for chain ${chainId}:`, error)
    }
  }

  async checkAndUnwindPositions(chainId: number): Promise<void> {
    const state = this.chains.get(chainId)
    if (!state?.wallet || state.positions.size === 0) return

    try {
      const currentPrice = await state.aux.getTWAP(1800)
      const toUnwindLong: string[] = []
      const toUnwindShort: string[] = []

      for (const [, position] of state.positions) {
        if (position.chainId !== chainId) continue
        const delta = Number(((currentPrice - position.entryPrice) * 1000n) / position.entryPrice)
        if (delta <= -CONFIG.PRICE_DELTA_THRESHOLD || delta >= CONFIG.PRICE_DELTA_THRESHOLD) {
          console.log(`⚡ ${position.user} needs unwinding: delta=${delta / 10}%`)
          ;(position.isLong ? toUnwindLong : toUnwindShort).push(position.user)
        }
      }

      for (const [list, fn, label] of [
        [toUnwindLong, 'unwindZeroForOne', 'long'],
        [toUnwindShort, 'unwindOneForZero', 'short'],
      ] as const) {
        if (list.length > 0) {
          const batch = list.slice(0, 30)
          console.log(`🔄 Unwinding ${batch.length} ${label} positions...`)
          try {
            const tx = await (state.amp as any)[fn](batch)
            await tx.wait()
            console.log(`✅ Unwind ${label} confirmed: ${tx.hash}`)
            for (const user of batch) {
              state.positions.delete(`${chainId}-${user.toLowerCase()}-${label === 'long'}`)
            }
          } catch (e: any) { console.error(`❌ Unwind ${label} failed:`, e.message) }
        }
      }
    } catch (error) {
      console.error(`❌ Position check error (chain ${chainId}):`, error)
    }
  }

  async listenForNewPositions(chainId: number): Promise<void> {
    const state = this.chains.get(chainId)
    if (!state) return

    state.amp.on('LeveragedPositionOpened', (user, isLong, supplied, borrowed, buffer, entryPrice, breakeven, blockNumber) => {
      console.log(`🆕 Position: ${user} ${isLong ? 'LONG' : 'SHORT'} at $${Number(entryPrice) / 1e18}`)
      state.positions.set(`${chainId}-${user.toLowerCase()}-${isLong}`, {
        user, isLong, entryPrice, breakeven, supplied, borrowed, buffer,
        blockNumber: Number(blockNumber), chainId,
      })
    })

    state.amp.on('PositionUnwound', (user, isLong) => {
      state.positions.delete(`${chainId}-${user.toLowerCase()}-${isLong}`)
    })

    console.log(`👂 Amp events on chain ${chainId}`)
  }

  // ─── HOOK + UMA (Prediction Market Lifecycle) ──────────────────

  async listenForHookEvents(chainId: number): Promise<void> {
    const state = this.chains.get(chainId)
    if (!state?.hook) return

    state.hook.on('ConfidenceRevealed', (user: string, side: number) => {
      state.revealedUsers.set(`${user.toLowerCase()}-${side}`, { user, side })
    })

    state.hook.on('OrderPlaced', (user: string, side: number) => {
      state.orderedUsers.set(`${user.toLowerCase()}-${side}`, { user, side })
    })

    state.hook.on('Recommitted', (user: string, side: number) => {
      state.orderedUsers.set(`${user.toLowerCase()}-${side}`, { user, side })
    })

    console.log(`👂 Hook events on chain ${chainId}`)
  }

  async listenForCourtEvents(chainId: number): Promise<void> {
    const state = this.chains.get(chainId)
    if (!state?.court) return

    // Solana-originated markets
    state.court.on('ResolutionReceived', (marketId: bigint) => {
      state.activeCourtMarkets.add(Number(marketId))
      console.log(`📩 Chain ${chainId}: Resolution received for market ${marketId}`)
    })

    // UMA arbitration
    state.court.on('ArbitrationReceived', (marketId: bigint) => {
      state.activeCourtMarkets.add(Number(marketId))
      console.log(`⚖️ Chain ${chainId}: Arbitration received for market ${marketId}`)
    })

    // Finalized — remove from active set
    state.court.on('ResolutionFinalized', (marketId: bigint) => {
      state.activeCourtMarkets.delete(Number(marketId))
      console.log(`✅ Chain ${chainId}: Resolution finalized for market ${marketId}`)
    })

    // Force majeure — also removes (ruling already sent)
    state.court.on('ForceMajeure', (marketId: bigint) => {
      state.activeCourtMarkets.delete(Number(marketId))
      console.log(`🚨 Chain ${chainId}: Force majeure for market ${marketId}`)
    })

    // Market extended — ruling sent, resolution done
    state.court.on('MarketExtended', (marketId: bigint) => {
      state.activeCourtMarkets.delete(Number(marketId))
      console.log(`🔄 Chain ${chainId}: Market extended for ${marketId}`)
    })

    console.log(`👂 Court events on chain ${chainId}`)
  }

  async loadActiveCourtMarkets(chainId: number): Promise<void> {
    const state = this.chains.get(chainId)
    if (!state?.court) return

    try {
      const currentBlock = await state.provider.getBlockNumber()
      const fromBlock = Math.max(0, currentBlock - 50000)

      // Scan for any market that entered resolution
      const resEvents = await state.court.queryFilter(
        state.court.filters.ResolutionReceived(), fromBlock, currentBlock)
      const arbEvents = await state.court.queryFilter(
        state.court.filters.ArbitrationReceived(), fromBlock, currentBlock)

      for (const e of [...resEvents, ...arbEvents]) {
        state.activeCourtMarkets.add(Number((e as any).args.marketId))
      }

      // Remove any that already finalized
      const finEvents = await state.court.queryFilter(
        state.court.filters.ResolutionFinalized(), fromBlock, currentBlock)
      const fmEvents = await state.court.queryFilter(
        state.court.filters.ForceMajeure(), fromBlock, currentBlock)
      const extEvents = await state.court.queryFilter(
        state.court.filters.MarketExtended(), fromBlock, currentBlock)

      for (const e of [...finEvents, ...fmEvents, ...extEvents]) {
        state.activeCourtMarkets.delete(Number((e as any).args.marketId))
      }

      // MarketId 0 (UMA) always monitored — check if in active resolution
      const [numSides] = await state.court.getMarketConfig(0)
      if (Number(numSides) > 0) state.activeCourtMarkets.add(0)

      console.log(`📋 Chain ${chainId}: ${state.activeCourtMarkets.size} active Court markets: [${[...state.activeCourtMarkets].join(', ')}]`)
    } catch (e: any) {
      console.error(`❌ loadActiveCourtMarkets error (chain ${chainId}):`, e.message?.slice(0, 80))
    }
  }

  async loadRevealedUsers(chainId: number): Promise<void> {
    const state = this.chains.get(chainId)
    if (!state?.hook) return

    try {
      const currentBlock = await state.provider.getBlockNumber()
      const fromBlock = Math.max(0, currentBlock - 50000)

      const revealEvents = await state.hook.queryFilter(
        state.hook.filters.ConfidenceRevealed(), fromBlock, currentBlock
      )
      for (const event of revealEvents) {
        const args = (event as any).args
        state.revealedUsers.set(`${args.user.toLowerCase()}-${Number(args.side)}`, {
          user: args.user, side: Number(args.side),
        })
      }

      const orderEvents = await state.hook.queryFilter(
        state.hook.filters.OrderPlaced(), fromBlock, currentBlock
      )
      for (const event of orderEvents) {
        const args = (event as any).args
        state.orderedUsers.set(`${args.user.toLowerCase()}-${Number(args.side)}`, {
          user: args.user, side: Number(args.side),
        })
      }

      console.log(`📊 Chain ${chainId}: ${state.revealedUsers.size} revealed, ${state.orderedUsers.size} ordered`)
    } catch (e: any) {
      console.error(`❌ loadRevealedUsers error (chain ${chainId}):`, e.message?.slice(0, 80))
    }
  }

  /**
   * Auto-reveal: after market resolution, fetch confidences from MongoDB
   * and call batchReveal as delegate for each unrevealed user.
   *
   * Hook.sol checks: msg.sender == pos.user || msg.sender == pos.delegate
   * Frontend always sets delegate = keeper address during placeOrder.
   */
  async autoRevealConfidences(chainId: number): Promise<void> {
    const state = this.chains.get(chainId)
    if (!state?.hook) return

    const signer = state.delegateWallet || state.wallet
    if (!signer) return

    try {
      const resp = await fetch(
        `${CONFIG.MONGODB_API}/api/confidences?mktId=${CONFIG.MARKET_ID}&chainId=${chainId}`
      )
      if (!resp.ok) {
        console.warn(`⚠️ Chain ${chainId}: Could not fetch confidences from API (${resp.status})`)
        return
      }
      const { confidences } = await resp.json() as {
        confidences: Array<{ user: string; side: number; confidence: number; salt: string }>
      }
      if (!confidences?.length) {
        console.log(`ℹ️ Chain ${chainId}: No confidences in DB to auto-reveal`)
        return
      }

      // Group by user+side — each position can have MULTIPLE entries
      const byUserSide = new Map<string, { user: string; side: number; reveals: Array<{ confidence: number; salt: string }> }>()
      for (const conf of confidences) {
        const key = `${conf.user.toLowerCase()}-${conf.side}`
        if (state.revealedUsers.has(key)) continue
        if (!byUserSide.has(key)) {
          byUserSide.set(key, { user: conf.user, side: conf.side, reveals: [] })
        }
        byUserSide.get(key)!.reveals.push({ confidence: conf.confidence, salt: conf.salt })
      }

      const hookWithSigner = state.hook.connect(signer) as ethers.Contract

      for (const [key, { user, side, reveals }] of byUserSide) {
        try {
          const pos = await state.hook.getPosition(user, side)
          if (pos.revealed || pos.totalTokens === 0n) continue
          if (pos.delegate.toLowerCase() !== signer.address.toLowerCase()) {
            console.log(`⏭️ Skipping ${user} side ${side}: delegate mismatch`)
            continue
          }

          console.log(`🔓 Chain ${chainId}: Revealing ${reveals.length} entries for ${user} side ${side}`)
          const tx = await hookWithSigner.batchReveal(user, side, reveals)
          await tx.wait()

          state.revealedUsers.set(key, { user, side })
          console.log(`✅ Auto-revealed ${user} side ${side} (${reveals.length} entries)`)
        } catch (e: any) {
          console.error(`❌ Auto-reveal ${user} side ${side}:`, e.message?.slice(0, 100))
        }
      }
    } catch (e: any) {
      console.error(`❌ autoRevealConfidences (chain ${chainId}):`, e.message?.slice(0, 100))
    }
  }

  /**
   * Full round lifecycle:
   *
   *   Trading ──(MONTH)──► resolveAsNone ──► Resolved (no depeg, no OOV3)
   *   Trading ──────────► requestResolution(side>0) ──(liveness)──► settleAssertion
   *     ──► Resolved ──(reveal window)──► autoReveal → calculateWeights → pushPayouts
   *     ──► restartMarket ──► Trading (next round)
   *
   * resolveAsNone(): permissionless, no bond, just needs MONTH elapsed.
   * requestResolution(side): caller must fund the bond (BOND_TOKEN.transferFrom).
   */
  async checkHookLifecycle(chainId: number): Promise<void> {
    const state = this.chains.get(chainId)
    if (!state?.hook || !state?.uma) return
    if (!state.delegateWallet && !state.wallet) return

    try {
      const market = await state.hook.getMarket()
      const [phase] = await state.uma.getAssertionInfo() as [number, number, bigint, number]

      // ── Step 0: Resolve round (Trading → Resolved or Asserting) ──────
      // Side 0 ("none depegged"): call resolveAsNone() — permissionless, no bond, needs MONTH elapsed.
      // Side > 0 (depeg claim): call requestResolution(side) — caller-funded bond via transferFrom.
      if (phase === Phase.Trading) {
        const block = await state.provider.getBlock('latest')
        const now = block!.timestamp
        const roundStart = Number(market.roundStartTime)
        const elapsed = now - roundStart

        if (elapsed >= CONFIG.MIN_TRADING_PERIOD && Number(market.positionsTotal) > 0) {
          try {
            const umaSigner = state.uma.connect(state.delegateWallet || state.wallet!) as ethers.Contract
            if (CONFIG.DEFAULT_CLAIM_SIDE === 0) {
              // "None depegged" — resolveAsNone() bypasses OOV3 entirely
              console.log(`📢 Chain ${chainId}: Resolving as "none depegged" (round ${market.roundNumber})`)
              const tx = await umaSigner.resolveAsNone()
              await tx.wait()
              console.log(`✅ Chain ${chainId}: Resolved as none — reveal window open`)
            } else {
              // Depeg claim — requestResolution(side) requires caller bond
              // Keeper must hold BOND_TOKEN and approve UMA contract first
              console.log(`📢 Chain ${chainId}: Asserting side ${CONFIG.DEFAULT_CLAIM_SIDE} (round ${market.roundNumber})`)
              const tx = await umaSigner.requestResolution(CONFIG.DEFAULT_CLAIM_SIDE)
              await tx.wait()
              console.log(`✅ Chain ${chainId}: Resolution requested — liveness starts`)
            }
          } catch (e: any) {
            console.error(`❌ resolution:`, e.message?.slice(0, 120))
          }
        }
        return
      }

      // ── Step 1: Settle assertion (Asserting → Resolved or Trading) ──
      if (phase === Phase.Asserting || phase === Phase.Disputed) {
        try {
          const tx = await state.hook.settleAssertion()
          await tx.wait()
          console.log(`✅ Chain ${chainId}: Assertion settled`)
        } catch (e: any) {
          // Expected to fail if liveness hasn't passed
          console.log(`⏳ Chain ${chainId}: settleAssertion not ready yet`)
        }
        return
      }

      // ── Step 2+: Post-resolution lifecycle (Resolved phase) ───
      if (phase === Phase.Resolved) {
        // 2a+2b. Reveal + calculate weights in one pass.
        // Fetch confidences from MongoDB for committed entries.
        // Rollover positions get revealCounts[i]=0 → auto NEUTRAL on-chain.
        // Stale autoRollover positions get LMSR entry on-chain too.
        if (!market.weightsComplete) {
          // Build user list: both revealed (already done) and ordered (need processing)
          const all = new Map<string, { user: string; side: number }>()
          for (const [k, v] of state.revealedUsers) all.set(k, v)
          for (const [k, v] of state.orderedUsers) all.set(k, v)

          // Fetch confidences from MongoDB
          let dbConfs: Array<{ user: string; side: number; confidence: number; salt: string }> = []
          try {
            const resp = await fetch(
              `${CONFIG.MONGODB_API}/api/confidences?mktId=${CONFIG.MARKET_ID}&chainId=${chainId}`
            )
            if (resp.ok) {
              const data = await resp.json() as { confidences: typeof dbConfs }
              dbConfs = data.confidences || []
            }
          } catch (e: any) {
            console.warn(`⚠️ Chain ${chainId}: MongoDB fetch failed, proceeding with rollover-only`)
          }

          // Group DB reveals by user+side
          const revealMap = new Map<string, Array<{ confidence: number; salt: string }>>()
          for (const conf of dbConfs) {
            const key = `${conf.user.toLowerCase()}-${conf.side}`
            if (!revealMap.has(key)) revealMap.set(key, [])
            revealMap.get(key)!.push({ confidence: conf.confidence, salt: conf.salt })
          }

          // Build arrays for calculateWeights
          const users: string[] = []
          const sides: number[] = []
          const reveals: Array<{ confidence: number; salt: string }> = []
          const revealCounts: number[] = []

          for (const v of all.values()) {
            users.push(v.user); sides.push(v.side)
            const key = `${v.user.toLowerCase()}-${v.side}`
            const posReveals = revealMap.get(key)
            if (posReveals && !state.revealedUsers.has(key)) {
              reveals.push(...posReveals)
              revealCounts.push(posReveals.length)
            } else {
              revealCounts.push(0) // rollover or already revealed
            }
          }

          if (users.length > 0) {
            // Batch in chunks — reveals must be sliced correspondingly
            for (let i = 0; i < users.length; i += 50) {
              const end = Math.min(i + 50, users.length)
              const batchUsers = users.slice(i, end)
              const batchSides = sides.slice(i, end)
              const batchCounts = revealCounts.slice(i, end)
              // Slice reveals: sum of counts for this batch
              const revStart = revealCounts.slice(0, i).reduce((a, b) => a + b, 0)
              const revEnd = revStart + batchCounts.reduce((a, b) => a + b, 0)
              const batchReveals = reveals.slice(revStart, revEnd)

              try {
                const tx = await state.hook.calculateWeights(
                  batchUsers, batchSides, batchReveals, batchCounts
                )
                await tx.wait()
                console.log(`✅ Chain ${chainId}: Weights calculated (batch ${Math.floor(i / 50) + 1})`)
                // Mark all as revealed for tracking
                for (let j = i; j < end; j++) {
                  const key = `${users[j].toLowerCase()}-${sides[j]}`
                  state.revealedUsers.set(key, { user: users[j], side: sides[j] })
                }
              } catch (e: any) {
                console.error(`❌ calculateWeights:`, e.message?.slice(0, 100))
              }
            }
          }
          return
        }

        // 2c. Push payouts after weights
        if (market.weightsComplete && !market.payoutsComplete) {
          const users: string[] = []
          const sides: number[] = []
          for (const v of state.revealedUsers.values()) {
            users.push(v.user); sides.push(v.side)
          }
          if (users.length > 0) {
            for (let i = 0; i < users.length; i += 50) {
              try {
                const tx = await state.hook.pushPayouts(
                  users.slice(i, i + 50), sides.slice(i, i + 50)
                )
                await tx.wait()
                console.log(`✅ Chain ${chainId}: Payouts pushed (batch ${Math.floor(i / 50) + 1})`)
              } catch (e: any) {
                console.error(`❌ pushPayouts:`, e.message?.slice(0, 100))
              }
            }
          }
          return
        }

        // 2d. Restart market for next round
        // Requires: payoutsComplete AND reveal deadline passed (checked on-chain)
        if (market.payoutsComplete) {
          try {
            const umaSigner = state.uma.connect(state.delegateWallet || state.wallet!) as ethers.Contract
            const tx = await umaSigner.restartMarket()
            await tx.wait()
            console.log(`🔄 Chain ${chainId}: Market restarted — round ${Number(market.roundNumber) + 1}`)

            // Clear round-local tracking for fresh round
            state.revealedUsers.clear()
            state.orderedUsers.clear()
          } catch (e: any) {
            // Expected if reveal window hasn't closed yet
            console.log(`⏳ Chain ${chainId}: restartMarket not ready (reveal window still open?)`)
          }
          return
        }
      }
    } catch (e: any) {
      console.error(`❌ Hook lifecycle (chain ${chainId}):`, e.message?.slice(0, 100))
    }
  }

  async burnHookFees(chainId: number): Promise<void> {
    const state = this.chains.get(chainId)
    if (!state?.hook) return
    try {
      const fees = await state.hook.accumulatedFees()
      if (fees > 0n) {
        const tx = await state.hook.burnAccumulatedFees()
        await tx.wait()
        console.log(`🔥 Chain ${chainId}: Burned ${ethers.formatUnits(fees, 18)} QD in fees`)
      }
    } catch (e: any) {
      console.error(`❌ burnFees (chain ${chainId}):`, e.message?.slice(0, 80))
    }
  }

  // ─── COURT + JURY (Arbitration Lifecycle) ─────────────────────

  /**
   * RLP-encode a block header for RANDAO verification.
   * Court.progressToJurySelection and Court.finalizeRound need raw
   * block headers so RandaoLib can extract prevRandao (mixHash).
   * The contract verifies keccak256(header) == blockhash(n).
   *
   * Post-Dencun field order (EIP-4844 + EIP-4788).
   * If the chain fork changes, update field list accordingly.
   */
  static rlpEncodeHeader(block: any): string {
    // Numeric fields: strip leading zero-padding for canonical RLP,
    // then left-pad to even length (ethers.encodeRlp requires even hex).
    // Matches hexToBuffer() in encodeHeader.js (the tested FFI version).
    const strip = (hex: string): string => {
      if (!hex || !hex.startsWith('0x')) return '0x'
      let s = hex.replace(/^0x0+/, '0x')
      if (s === '0x') return '0x' // zero → empty bytes
      // ethers.getBytes requires even-length hex
      if ((s.length - 2) % 2 !== 0) s = '0x0' + s.slice(2)
      return s
    }

    const fields: string[] = [
      block.parentHash,                    // 32 bytes
      block.sha3Uncles,                    // 32 bytes
      block.miner,                         // 20 bytes
      block.stateRoot,                     // 32 bytes
      block.transactionsRoot,              // 32 bytes
      block.receiptsRoot,                  // 32 bytes
      block.logsBloom,                     // 256 bytes
      strip(block.difficulty),             // uint
      strip(block.number),                 // uint
      strip(block.gasLimit),               // uint
      strip(block.gasUsed || '0x0'),       // uint (can be zero)
      strip(block.timestamp),              // uint
      block.extraData || '0x',             // variable bytes
      block.mixHash,                       // 32 bytes (= prevRandao post-merge)
      block.nonce,                         // 8 bytes
      // EIP-1559 (London)
      strip(block.baseFeePerGas),
      // EIP-4895 (Shanghai)
      block.withdrawalsRoot,               // 32 bytes
      // EIP-4844 (Cancun)
      strip(block.blobGasUsed),
      strip(block.excessBlobGas),
      // EIP-4788 (Cancun)
      block.parentBeaconBlockRoot,         // 32 bytes
    ]

    const encoded = ethers.encodeRlp(fields)

    // Verify hash — same check as encodeHeader.js FFI script.
    // If this fails, the contract would revert anyway, but
    // catching it here gives us a useful error message.
    const hash = ethers.keccak256(encoded)
    if (hash !== block.hash) {
      throw new Error(
        `RLP hash mismatch for block ${block.number}: ` +
        `expected ${block.hash}, got ${hash}`
      )
    }

    return encoded
  }

  /**
   * Fetch RLP-encoded block headers for the N most recent blocks.
   * Used by progressToJurySelection and finalizeRound which pass
   * headers to RandaoLib for on-chain RANDAO seed derivation.
   *
   * Headers are for blocks [latest, latest-1, ...latest-(count-1)].
   * The TX will land ~1 block later, so the contract references
   * block.number-1 = latest, block.number-2 = latest-1, etc.
   */
  async fetchBlockHeaders(provider: ethers.JsonRpcProvider, count: number): Promise<string[]> {
    const latest = await provider.getBlockNumber()
    const headers: string[] = []
    for (let i = 0; i < count; i++) {
      const blockNum = latest - i
      const block = await provider.send('eth_getBlockByNumber', [
        '0x' + blockNum.toString(16), false
      ])
      if (!block) throw new Error(`Block ${blockNum} not found`)
      headers.push(QuidKeeper.rlpEncodeHeader(block))
    }
    return headers
  }

  /**
   * Auto-reveal jury votes — mirrors autoRevealConfidences exactly.
   *
   * Flow: juror commits via frontend with delegate=keeper address,
   * frontend stores {juror, marketId, round, sides[], salt} in MongoDB.
   * After COMMIT_PERIOD ends, keeper fetches from MongoDB and calls
   * Jury.revealVote(marketId, round, sides, salt, juror) as delegate.
   *
   * Jury.sol checks: msg.sender == delegates[mktId][round][juror] || msg.sender == juror
   */
  async autoRevealJuryVotes(chainId: number, marketId: number, round: number): Promise<void> {
    const state = this.chains.get(chainId)
    if (!state?.jury) return

    const signer = state.delegateWallet || state.wallet
    if (!signer) return

    try {
      const resp = await fetch(
        `${CONFIG.MONGODB_API}/api/jury-votes?marketId=${marketId}&round=${round}`
      )
      if (!resp.ok) {
        console.warn(`⚠️ Chain ${chainId}: Could not fetch jury votes from API (${resp.status})`)
        return
      }
      const { votes } = await resp.json() as {
        votes: Array<{ juror: string; sides: number[]; salt: string }>
      }
      if (!votes?.length) {
        console.log(`ℹ️ Chain ${chainId}: No jury votes in DB for market ${marketId} round ${round}`)
        return
      }

      const juryWithSigner = state.jury.connect(signer) as ethers.Contract

      for (const vote of votes) {
        try {
          // Skip if already revealed on-chain
          const alreadyRevealed = await state.jury.revealed(marketId, round, vote.juror)
          if (alreadyRevealed) continue

          // Verify keeper is delegate for this juror
          const delegate = await state.jury.delegates(marketId, round, vote.juror)
          if (delegate.toLowerCase() !== signer.address.toLowerCase()) {
            console.log(`⏭️ Skipping juror ${vote.juror}: delegate mismatch`)
            continue
          }

          // Verify commitment exists (juror actually committed)
          const commitment = await state.jury.commits(marketId, round, vote.juror)
          if (commitment === ethers.ZeroHash) {
            console.log(`⏭️ Skipping juror ${vote.juror}: no commitment on-chain`)
            continue
          }

          console.log(`🔓 Chain ${chainId}: Revealing jury vote for ${vote.juror} (market ${marketId} round ${round})`)
          const tx = await juryWithSigner.revealVote(
            marketId, round, vote.sides, vote.salt, vote.juror
          )
          await tx.wait()
          console.log(`✅ Jury vote revealed for ${vote.juror}`)
        } catch (e: any) {
          console.error(`❌ Jury reveal ${vote.juror}:`, e.message?.slice(0, 100))
        }
      }
    } catch (e: any) {
      console.error(`❌ autoRevealJuryVotes (chain ${chainId}):`, e.message?.slice(0, 100))
    }
  }

  /**
   * Court lifecycle — polls each monitored marketId and drives state forward.
   *
   * State machine per marketId:
   *   1. numSides > 0, no jury yet       → progressToJurySelection (needs headers)
   *   2. Jury selected, commit period     → wait
   *   3. Reveal window open               → autoRevealJuryVotes
   *   4. Finalize window                  → finalizeRound (needs headers)
   *   5. Missed finalize window           → recoverMissedWindow
   *   6. Verdict + appeal window          → wait
   *   7. Appeal window closed             → executeVerdict
   *
   * Steps 1 and 4 need RANDAO block headers. If header encoding fails
   * (fork mismatch, RPC issue), TX reverts harmlessly — retry next cycle.
   */
  async checkCourtLifecycle(chainId: number): Promise<void> {
    const state = this.chains.get(chainId)
    if (!state?.court || !state?.jury) return
    if (!state.delegateWallet && !state.wallet) return

    const signer = state.delegateWallet || state.wallet!
    const courtSigner = state.court.connect(signer) as ethers.Contract

    for (const marketId of state.activeCourtMarkets) {
      try {
        const [numSides, , ,] = await state.court.getMarketConfig(marketId)
        if (numSides === 0) continue // no active resolution

        const roundStart = Number(await state.court.getRoundStartTime(marketId))
        const currentRound = Number(await state.court.getCurrentRound(marketId))
        const vTimestamp = Number(await state.court.getVerdictTimestamp(marketId))
        const [eligibleBlock, windowEnd] = await state.court.getFinalizeWindow(marketId)
        const currentBlock = await state.provider.getBlockNumber()
        const block = await state.provider.getBlock('latest')
        const now = block!.timestamp

        // ── Step 7: Execute verdict after appeal window ──
        if (vTimestamp > 0 && now > vTimestamp + CONFIG.APPEAL_WINDOW) {
          try {
            const [ready, reason] = await state.court.isReadyForExecution(marketId)
            if (ready) {
              console.log(`⚖️ Chain ${chainId}: Executing verdict for market ${marketId}`)
              const tx = await courtSigner.executeVerdict(marketId)
              await tx.wait()
              console.log(`✅ Chain ${chainId}: Verdict executed for market ${marketId}`)
            } else if (reason === 'Already executed') {
              // Verdict sent — ensure jury compensation completes.
              // For arbitration (marketId 0), no Solana funds arrive,
              // so timeoutJuryCompensation triggers distribution from
              // slashed appeal costs only. Reverts harmlessly if
              // compensation already received/distributed.
              try {
                const tx = await courtSigner.timeoutJuryCompensation(marketId)
                await tx.wait()
                console.log(`💰 Chain ${chainId}: Jury compensation completed for market ${marketId}`)
              } catch { /* already distributed or not yet eligible */ }
            } else {
              console.log(`⏳ Chain ${chainId}: Market ${marketId} not ready: ${reason}`)
            }
          } catch (e: any) {
            console.error(`❌ executeVerdict market ${marketId}:`, e.message?.slice(0, 100))
          }
          continue
        }

        // ── Step 6: Appeal window active — wait ──
        if (vTimestamp > 0 && now <= vTimestamp + CONFIG.APPEAL_WINDOW) {
          continue
        }

        // ── Step 5: Missed finalize window — recover ──
        if (Number(eligibleBlock) > 0 && currentBlock > Number(windowEnd) && vTimestamp === 0) {
          try {
            console.log(`🔧 Chain ${chainId}: Recovering missed window for market ${marketId}`)
            const tx = await courtSigner.recoverMissedWindow(marketId)
            await tx.wait()
            console.log(`✅ Chain ${chainId}: Missed window recovered for market ${marketId}`)
          } catch (e: any) {
            console.error(`❌ recoverMissedWindow market ${marketId}:`, e.message?.slice(0, 100))
          }
          continue
        }

        // ── Step 4: Finalize window — call finalizeRound ──
        if (Number(eligibleBlock) > 0 && currentBlock >= Number(eligibleBlock)
            && currentBlock <= Number(windowEnd)) {
          try {
            const headers = await this.fetchBlockHeaders(state.provider, 3)
            console.log(`⚖️ Chain ${chainId}: Finalizing round ${currentRound} for market ${marketId}`)
            const tx = await courtSigner.finalizeRound(marketId, headers)
            await tx.wait()
            console.log(`✅ Chain ${chainId}: Round ${currentRound} finalized for market ${marketId}`)
          } catch (e: any) {
            // Expected if headers don't match (block timing) — retry next cycle
            console.log(`⏳ Chain ${chainId}: finalizeRound not ready: ${e.message?.slice(0, 80)}`)
          }
          continue
        }

        // ── Step 3: Reveal window — auto-reveal jury votes ──
        // Guard: eligibleBlock > 0 confirms progressToJurySelection succeeded.
        // Without this, roundStart > 0 combined with a failed jury selection
        // means now >= roundStart + COMMIT_PERIOD is trivially true, firing
        // spurious reveal attempts every cycle indefinitely.
        if (Number(eligibleBlock) > 0 && roundStart > 0
            && now >= roundStart + CONFIG.COMMIT_PERIOD
            && now <= roundStart + CONFIG.COMMIT_PERIOD + CONFIG.REVEAL_WINDOW) {
            await this.autoRevealJuryVotes(chainId, marketId, currentRound)
            continue
        }

        // ── Step 2: Commit period — wait ──
        if (Number(eligibleBlock) > 0 && roundStart > 0
            && now < roundStart + CONFIG.COMMIT_PERIOD) {
          continue
        }

        // ── Step 1: No jury yet — progress to selection ──
        if (Number(eligibleBlock) === 0 && roundStart > 0) {
          try {
            const headers = await this.fetchBlockHeaders(state.provider, 3)
            console.log(`⚖️ Chain ${chainId}: Selecting jury for market ${marketId} round ${currentRound}`)
            const tx = await courtSigner.progressToJurySelection(marketId, currentRound, headers)
            await tx.wait()
            console.log(`✅ Chain ${chainId}: Jury selection complete for market ${marketId}`)
          } catch (e: any) {
            // Expected if not enough jurors opted in, or headers mismatch
            console.log(`⏳ Chain ${chainId}: Jury selection not ready: ${e.message?.slice(0, 80)}`)
          }
        }
      } catch (e: any) {
        console.error(`❌ Court lifecycle market ${marketId} (chain ${chainId}):`, e.message?.slice(0, 100))
      }
    }
  }

  // ─── MAIN LOOP ─────────────────────────────────────────────────

  async runLoop(): Promise<void> {
    this.isRunning = true
    console.log(`\n🚀 Keeper started — Amp: ${CONFIG.CHECK_INTERVAL / 1000}s | Hook: ${CONFIG.HOOK_INTERVAL / 1000}s | Court: ${CONFIG.COURT_INTERVAL / 1000}s | Fees: ${CONFIG.FEE_BURN_INTERVAL / 1000}s\n`)

    let hookCounter = 0
    let feeBurnCounter = 0
    let courtCounter = 0

    while (this.isRunning) {
      // Amp unwinds — all chains
      for (const chainId of CONFIG.ACTIVE_CHAINS) {
        await this.checkAndUnwindPositions(chainId)
      }

      // Hook + UMA lifecycle — L1 only
      hookCounter += CONFIG.CHECK_INTERVAL
      if (hookCounter >= CONFIG.HOOK_INTERVAL) {
        hookCounter = 0
        for (const chainId of CONFIG.HOOK_CHAINS) {
          await this.checkHookLifecycle(chainId)
        }
      }

      // Court + Jury lifecycle — L1 only
      courtCounter += CONFIG.CHECK_INTERVAL
      if (courtCounter >= CONFIG.COURT_INTERVAL) {
        courtCounter = 0
        for (const chainId of CONFIG.HOOK_CHAINS) {
          await this.checkCourtLifecycle(chainId)
        }
      }

      // Fee burns — L1 only
      feeBurnCounter += CONFIG.CHECK_INTERVAL
      if (feeBurnCounter >= CONFIG.FEE_BURN_INTERVAL) {
        feeBurnCounter = 0
        for (const chainId of CONFIG.HOOK_CHAINS) {
          await this.burnHookFees(chainId)
        }
      }

      await new Promise(resolve => setTimeout(resolve, CONFIG.CHECK_INTERVAL))
    }
  }

  stop(): void { this.isRunning = false; console.log('🛑 Stopping...') }

  async start(): Promise<void> {
    await this.initialize()

    // Amp event listeners — all chains
    for (const chainId of CONFIG.ACTIVE_CHAINS) {
      await this.loadHistoricalPositions(chainId)
      await this.listenForNewPositions(chainId)
    }

    // Hook event listeners — L1 only
    for (const chainId of CONFIG.HOOK_CHAINS) {
      await this.loadRevealedUsers(chainId)
      await this.listenForHookEvents(chainId)
      await this.loadActiveCourtMarkets(chainId)
      await this.listenForCourtEvents(chainId)
    }

    await this.runLoop()
  }
}

async function main() {
  const evmKeeper = new QuidKeeper()
  const solKeeper = new SolanaKeeper()
  const pmKeeper = new PredictionMarketKeeper()

  const shutdown = () => {
    evmKeeper.stop()
    solKeeper.stop()
    pmKeeper.stop()
    process.exit(0)
  }
  process.on('SIGINT', shutdown)
  process.on('SIGTERM', shutdown)

  // Run all three in parallel — each can fail independently
  await Promise.allSettled([
    evmKeeper.start().catch(e => console.error('EVM keeper error:', e.message)),
    solKeeper.start().catch(e => console.error('Solana stock keeper error:', e.message)),
    pmKeeper.start().catch(e => console.error('Solana PM keeper error:', e.message)),
  ])
}

main().catch(console.error)
