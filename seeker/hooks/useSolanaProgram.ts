/**
 * useSolanaProgram.ts
 *
 * Core Solana plumbing for the Seeker app.
 * Uses useWallet() — cross-platform (MWA on Android, Phantom deep links on iOS).
 */

import { useCallback, useMemo } from 'react'
import {
  PublicKey,
  TransactionInstruction,
  TransactionMessage,
  VersionedTransaction,
  SystemProgram as SolSystemProgram,
} from '@solana/web3.js'
import { Program, AnchorProvider, BN } from '@coral-xyz/anchor'
import { useWallet } from '@/hooks/useWallet'
import {
  getAssociatedTokenAddressSync,
  TOKEN_PROGRAM_ID,
  ASSOCIATED_TOKEN_PROGRAM_ID,
} from '@solana/spl-token'

import quidIdl from '@/constants/quid.json'

const SOLANA_PROGRAM_ID =
  process.env.EXPO_PUBLIC_QUID_PROGRAM_ID ?? 'QDgHUZjtccRjKZ63MBvW8uzKR7qcqjpRfGhNSEGfDu9'

export interface SolanaPDAs {
  bank: PublicKey
  depositor: PublicKey
  config: PublicKey
  programId: PublicKey
}

export function useSolanaProgram() {
  const { connection, signAndSendTransaction } = useWallet()

  const programId = useMemo(() => new PublicKey(SOLANA_PROGRAM_ID), [])

  const getReadonlyProgram = useCallback((): Program => {
    const dummyWallet = {
      signTransaction: async (tx: any) => tx,
      signAllTransactions: async (txs: any[]) => txs,
      publicKey: PublicKey.default,
    }
    const provider = new AnchorProvider(connection, dummyWallet as any, {
      commitment: 'confirmed',
    })
    return new Program(
      { ...quidIdl, address: programId.toBase58() } as any,
      provider,
    )
  }, [connection, programId])

  const derivePDAs = useCallback(
    (userBase58: string): SolanaPDAs => {
      const userPk = new PublicKey(userBase58)
      const [bank] = PublicKey.findProgramAddressSync(
        [Buffer.from('depository')],
        programId,
      )
      const [depositor] = PublicKey.findProgramAddressSync(
        [userPk.toBuffer()],
        programId,
      )
      const [config] = PublicKey.findProgramAddressSync(
        [Buffer.from('program_config')],
        programId,
      )
      return { bank, depositor, config, programId }
    },
    [programId],
  )

  const deriveVaultPDA = useCallback(
    (mintPk: PublicKey): PublicKey => {
      const [vault] = PublicKey.findProgramAddressSync(
        [Buffer.from('vault'), mintPk.toBuffer()],
        programId,
      )
      return vault
    },
    [programId],
  )

  const deriveTickerRiskPDA = useCallback(
    (ticker: string): PublicKey => {
      if (!ticker) return programId
      const [pda] = PublicKey.findProgramAddressSync(
        [Buffer.from('risk'), Buffer.from(ticker)],
        programId,
      )
      return pda
    },
    [programId],
  )

  const sendSolTx = useCallback(
    async (
      instructions: TransactionInstruction[],
      feePayer: PublicKey,
    ): Promise<string> => {
      console.trace('[sendSolTx] called')
      const {
        context: { slot: minContextSlot },
        value: latestBlockhash,
      } = await connection.getLatestBlockhashAndContext()

      const message = new TransactionMessage({
        payerKey: feePayer,
        recentBlockhash: latestBlockhash.blockhash,
        instructions,
      }).compileToLegacyMessage()

      const tx = new VersionedTransaction(message)
      const signature = await signAndSendTransaction(tx, minContextSlot)

      await connection.confirmTransaction(
        { signature, ...latestBlockhash },
        'confirmed',
      )
      return signature
    },
    [connection, signAndSendTransaction],
  )

  const fetchTokenMint = useCallback(async (): Promise<string | null> => {
    try {
      const program = getReadonlyProgram()
      const [configPda] = PublicKey.findProgramAddressSync(
        [Buffer.from('program_config')],
        programId,
      )
      const config = await (program.account as any).programConfig.fetch(configPda)
      return (config.tokenMint as PublicKey).toBase58()
    } catch (e) {
      console.warn('[useSolanaProgram] fetchTokenMint failed:', e)
      return null
    }
  }, [getReadonlyProgram, programId])

  /**
   * Fetch the SPL token balance for a user's ATA.
   * Returns human-readable balance (divided by decimals).
   */
  const fetchTokenBalance = useCallback(
    async (userPubkey: string, mintAddress: string): Promise<number> => {
      try {
        const userPk = new PublicKey(userPubkey)
        const mintPk = new PublicKey(mintAddress)
        const ata = getAssociatedTokenAddressSync(mintPk, userPk)
        const balance = await connection.getTokenAccountBalance(ata)
        return balance.value.uiAmount ?? 0
      } catch {
        return 0
      }
    },
    [connection],
  )


  return {
    connection,
    programId,
    getReadonlyProgram,
    derivePDAs,
    deriveVaultPDA,
    deriveTickerRiskPDA,
    sendSolTx,
    fetchTokenMint,
    fetchTokenBalance,
    BN,
    TOKEN_PROGRAM_ID,
    ASSOCIATED_TOKEN_PROGRAM_ID,
    SolSystemProgram,
    getAssociatedTokenAddressSync,
  }
}

export { getAssociatedTokenAddressSync, TOKEN_PROGRAM_ID, ASSOCIATED_TOKEN_PROGRAM_ID, BN }
