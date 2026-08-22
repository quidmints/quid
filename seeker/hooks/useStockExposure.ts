/**
 * useStockExposure.ts
 *
 * QU!D Solana stock exposure (synthetic equities) operations.
 * Direct port of handleSolanaDeposit, handleSolanaWithdraw, and
 * refreshStockPositions from page.tsx.
 *
 * Instruction mapping:
 *   deposit(amount: u64, ticker: string) → pledge collateral + optional ticker risk
 *   withdraw(amount: u64, ticker: string, exposure: bool) → redeem collateral or adjust exposure
 *
 * Pyth remaining accounts:
 *   For withdraw(exposure=true) on a specific ticker → single Pyth price account
 *   For withdraw(exposure=false) with no ticker → all Pyth accounts for open positions
 *   Uses PYTH_ACCOUNTS map from tickers.ts (generated from etc.rs PHF maps)
 *
 * Position parsing (from depositor.positions[]):
 *   ticker:    [u8; 16] null-padded → strip \0
 *   amount:    u64 / 1e6 (QUID has 6 decimals on Solana)
 *   entryPrice: u64 / 1e6
 *   long:      bool
 *   leverage:  u8
 *   timestamp: i64
 */

import { useCallback, useState } from 'react'
import { PublicKey } from '@solana/web3.js'
import { useSolanaProgram, BN, TOKEN_PROGRAM_ID, ASSOCIATED_TOKEN_PROGRAM_ID, getAssociatedTokenAddressSync } from './useSolanaProgram'

/**
 * An optional account the program is not being given.
 *
 * `sol_pool` and `ticker_risk` are `optional: true` in the IDL and Anchor's
 * runtime reads `null` as "not supplied", which is exactly what selects the
 * SPL leg over the native-SOL one. Its `accountsStrict` types do not model
 * optional accounts yet, so the cast is where that gap is acknowledged rather
 * than papered over at each call site.
 */
const OMITTED = null as unknown as PublicKey

// ── Types ─────────────────────────────────────────────────────────────────

export interface StockPosition {
  ticker: string
  pledged: number      // QD collateral, human-readable (/ 1e6)
  exposure: number     // signed: + = long, - = short (/ 1e6)
  collarBps: number
  price: number        // current USD price (filled by caller from Pyth)
  pnlPct: number       // unrealized PnL % (calculated by caller)
  direction: 'long' | 'short' | 'flat'
  leverage: number
}

// Raw position — no longer used (Stock fields parsed directly in refreshPositions)

// ── Pyth accounts map ─────────────────────────────────────────────────────
// Imported from the generated tickers.ts (extract-tickers.ts output).
// On mobile, this file lives at constants/tickers.ts (copy from web prebuild output).
//
// If tickers.ts is not yet available, fall back to an empty map and
// the withdraw instruction will simply skip Pyth accounts.
let PYTH_ACCOUNTS: Record<string, string> = {}
try {
  // eslint-disable-next-line @typescript-eslint/no-var-requires
  PYTH_ACCOUNTS = require('@/constants/tickers').PYTH_ACCOUNTS ?? {}
} catch {
  console.warn('[useStockExposure] tickers.ts not found — Pyth accounts unavailable')
}

// ── Hook ──────────────────────────────────────────────────────────────────

export function useStockExposure() {
  const {
    connection, getReadonlyProgram,
    derivePDAs, deriveVaultPDA, deriveTickerRiskPDA,
    sendSolTx, SolSystemProgram,
  } = useSolanaProgram()

  const [positions, setPositions] = useState<StockPosition[]>([])
  const [depositedQuid, setDepositedQuid] = useState(0)
  const [isLoading, setIsLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)

  // ── Deposit (pledge QD collateral + open ticker exposure) ───────────────
  /**
   * Calls deposit(amount, ticker).
   * amount: QUID in display units (e.g. "100" → 100_000_000 at 6 decimals)
   * ticker: empty string = no exposure, just pledging collateral
   */
  const deposit = useCallback(async (
    userPubkey: string,
    ticker: string,
    displayAmount: string,
    tokenMint: string
  ): Promise<string> => {
    setIsLoading(true)
    setError(null)

    try {
      const { bank, depositor, config } = derivePDAs(userPubkey)
      const userPk = new PublicKey(userPubkey)
      const mintPk = new PublicKey(tokenMint)

      const vault = deriveVaultPDA(mintPk)
      const tickerRiskPda = deriveTickerRiskPDA(ticker)
      const userAta = getAssociatedTokenAddressSync(mintPk, userPk)

      const amountRaw = Math.floor(parseFloat(displayAmount) * 1e6)

      const program = getReadonlyProgram()
      const ix = await program.methods
        .deposit(new BN(amountRaw), ticker)
        .accountsStrict({
          signer: userPk,
          mint: mintPk,
          config,
          bank,
          programVault: vault,
          depositor,
          tickerRisk: tickerRiskPda,
          quid: userAta,
          // Native-SOL leg selector: absent ⇒ SPL deposit. Supplying the
          // sol_pool PDA instead is what routes `deposit` to lamports.
          solPool: OMITTED,
          tokenProgram: TOKEN_PROGRAM_ID,
          systemProgram: SolSystemProgram.programId,
        })
        .instruction()

      const sig = await sendSolTx([ix], userPk)
      console.log('[useStockExposure] deposit sig:', sig)
      return sig
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err)
      setError(msg)
      throw err
    } finally {
      setIsLoading(false)
    }
  }, [derivePDAs, deriveVaultPDA, deriveTickerRiskPDA, getReadonlyProgram, sendSolTx, SolSystemProgram])

  // ── Withdraw (redeem collateral or adjust exposure) ──────────────────────
  /**
   * Calls withdraw(amount, ticker, exposure).
   *
   * exposure=false, ticker=""  → redeem all/some QD collateral
   * exposure=true,  ticker="X" → close/reduce position in ticker X
   * exposure=false, ticker="X" → same as false + no ticker (lib.rs ignores ticker when exposure=false)
   *
   * Pyth remaining accounts are added for price verification:
   *   - Single ticker: one Pyth account for that ticker
   *   - No ticker (full redeem): all Pyth accounts for open positions
   */
  const withdraw = useCallback(async (
    userPubkey: string,
    ticker: string,
    displayAmount: string,
    exposure: boolean,
    tokenMint: string,
    currentPositions: StockPosition[] = []
  ): Promise<string> => {
    setIsLoading(true)
    setError(null)

    try {
      const { bank, depositor, config } = derivePDAs(userPubkey)
      const userPk = new PublicKey(userPubkey)
      const mintPk = new PublicKey(tokenMint)

      const vault = deriveVaultPDA(mintPk)
      const tickerRiskPda = deriveTickerRiskPDA(ticker)
      const userAta = getAssociatedTokenAddressSync(mintPk, userPk)

      // withdraw(amount: i64, ticker, exposure)
      // positive = increase/add, negative = decrease/withdraw
      // displayAmount may be negative (e.g. "-100") — preserve the sign
      const amountRaw = Math.trunc(parseFloat(displayAmount) * 1e6)

      // Build Pyth remaining accounts (matches page.tsx logic exactly)
      const pythRemaining: { pubkey: PublicKey; isWritable: boolean; isSigner: boolean }[] = []
      if (ticker && PYTH_ACCOUNTS[ticker]) {
        pythRemaining.push({
          pubkey: new PublicKey(PYTH_ACCOUNTS[ticker]),
          isWritable: false,
          isSigner: false,
        })
      } else if (!ticker) {
        // Full redeem — include Pyth accounts for all open positions
        for (const pos of currentPositions) {
          const pk = PYTH_ACCOUNTS[pos.ticker]
          if (pk) {
            pythRemaining.push({ pubkey: new PublicKey(pk), isWritable: false, isSigner: false })
          }
        }
      }

      const program = getReadonlyProgram()
      const ix = await program.methods
        .withdraw(new BN(amountRaw), ticker, exposure)
        .accountsStrict({
          signer: userPk,
          mint: mintPk,
          config,
          bank,
          bankTokenAccount: vault,
          customerAccount: depositor,
          customerTokenAccount: userAta,
          // Native-SOL leg selector, as on deposit: absent ⇒ SPL withdrawal.
          solPool: OMITTED,
          tickerRisk: tickerRiskPda,
          tokenProgram: TOKEN_PROGRAM_ID,
          associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
          systemProgram: SolSystemProgram.programId,
        })
        .remainingAccounts(pythRemaining)
        .instruction()

      const sig = await sendSolTx([ix], userPk)
      console.log('[useStockExposure] withdraw sig:', sig)
      return sig
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err)
      setError(msg)
      throw err
    } finally {
      setIsLoading(false)
    }
  }, [derivePDAs, deriveVaultPDA, deriveTickerRiskPDA, getReadonlyProgram, sendSolTx, SolSystemProgram])

  // ── Refresh Positions ────────────────────────────────────────────────────
  /**
   * Fetches the depositor account and parses all open positions.
   * Matches refreshStockPositions in page.tsx exactly.
   */
  const refreshPositions = useCallback(async (userPubkey: string) => {
    if (!userPubkey) return
    try {
      const program = getReadonlyProgram()
      const { depositor } = derivePDAs(userPubkey)

      const acc = await (program.account as any).depositor.fetch(depositor)
      setDepositedQuid(acc.depositedQuid.toNumber() / 1e6)

      // IDL: Depositor.balances = Vec<Stock>
      // Stock fields: ticker [u8;8], pledged u64, exposure i64,
      //               updated i64, rate_bps u16, collar_bps u16
      const stockPositions: StockPosition[] = (acc.balances ?? [])
        .map((s: any) => {
          const ticker = new TextDecoder()
            .decode(Uint8Array.from(s.ticker))
            .replace(/\0/g, '')
          if (!ticker) return null

          const pledged = s.pledged.toNumber() / 1e6
          // exposure is i64: positive = long, negative = short
          const exposureRaw: number = s.exposure.toNumber()
          const exposure = exposureRaw / 1e6

          return {
            ticker,
            pledged,
            exposure,
            collarBps: s.collarBps ?? 0,
            price: 0,     // filled by caller via Pyth
            pnlPct: 0,    // filled by caller
            direction: exposureRaw > 0 ? 'long' : exposureRaw < 0 ? 'short' : 'flat',
            leverage: 1,  // collar mechanics handled on-chain
          } as StockPosition
        })
        .filter(Boolean) as StockPosition[]

      setPositions(stockPositions)
    } catch (e: unknown) {
      const msg = e instanceof Error ? e.message : String(e)
      if (msg.includes('Account does not exist') || msg.includes('could not find')) {
        setPositions([])
        setDepositedQuid(0)
      } else {
        console.warn('[useStockExposure] refreshPositions failed:', e)
      }
    }
  }, [getReadonlyProgram, derivePDAs])

  return {
    positions,
    depositedQuid,
    isLoading,
    error,
    deposit,
    withdraw,
    refreshPositions,
  }
}
