/**
 * scripts/initialize.js
 *
 * Calls init_config on devnet to bootstrap the QU!D program.
 *   node scripts/initialize.js <mint>
 *   QUID_MINT=<mint> node scripts/initialize.js
 */

const anchor = require('@coral-xyz/anchor')
const { PublicKey, SystemProgram, Keypair } = require('@solana/web3.js')
const { readFileSync } = require('fs')
const { homedir } = require('os')
const path = require('path')

async function main() {
  const connection = new anchor.web3.Connection(
    'https://api.devnet.solana.com',
    'confirmed',
  )

  const walletPath =
    process.env.ANCHOR_WALLET ?? `${homedir()}/.config/solana/id.json`
  const walletKeypair = Keypair.fromSecretKey(
    Uint8Array.from(JSON.parse(readFileSync(walletPath, 'utf8'))),
  )
  const wallet = new anchor.Wallet(walletKeypair)
  const provider = new anchor.AnchorProvider(connection, wallet, { commitment: 'confirmed' })
  anchor.setProvider(provider)

  const idlPath = path.resolve(__dirname, '../constants/quid.json')
  const idl = JSON.parse(readFileSync(idlPath, 'utf8'))

  const programId = new PublicKey(
    process.env.EXPO_PUBLIC_QUID_PROGRAM_ID ??
    idl.address ??
    (() => { throw new Error('Set EXPO_PUBLIC_QUID_PROGRAM_ID or deploy first') })()
  )

  const program = new anchor.Program(idl, provider)

  const mintArg = process.env.EXPO_PUBLIC_QUID_MINT ?? process.argv[2]
  if (!mintArg) {
    throw new Error(
      'Provide mint address: QUID_MINT=<addr> node scripts/initialize.js  OR  node scripts/initialize.js <addr>',
    )
  }
  const tokenMint = new PublicKey(mintArg)
  const trustedOracleFunction = PublicKey.default

  const [configPda] = PublicKey.findProgramAddressSync(
    [Buffer.from('program_config')],
    programId,
  )

  console.log('Program ID:       ', programId.toBase58())
  console.log('Admin:            ', wallet.publicKey.toBase58())
  console.log('Config PDA:       ', configPda.toBase58())
  console.log('Token Mint:       ', tokenMint.toBase58())
  console.log('Oracle Function:  ', trustedOracleFunction.toBase58(), '(placeholder)')

  const existing = await connection.getAccountInfo(configPda)
  if (existing) {
    console.log('\n⚠  program_config already exists — skipping init_config')
    console.log('   If you need to update oracle/admin, use update_config instead.')
    process.exit(0)
  }

  const sig = await program.methods
    .initConfig(trustedOracleFunction, tokenMint)
    .accounts({
      admin: wallet.publicKey,
      config: configPda,
      systemProgram: SystemProgram.programId,
    })
    .rpc()

  console.log('\n✅ init_config succeeded')
  console.log('   Signature:', sig)
  console.log('   Explorer: https://explorer.solana.com/tx/' + sig + '?cluster=devnet')
  console.log('\nAdd to seeker/.env:')
  console.log('   EXPO_PUBLIC_QUID_PROGRAM_ID=' + programId.toBase58())
  console.log('   EXPO_PUBLIC_QUID_MINT=' + tokenMint.toBase58())
  console.log('   EXPO_PUBLIC_QUID_KEEPER=' + wallet.publicKey.toBase58())
}

main().catch(err => {
  console.error('init_config failed:', err)
  process.exit(1)
})
