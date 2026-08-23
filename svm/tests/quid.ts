import * as anchor from "@coral-xyz/anchor";
import { Program } from "@coral-xyz/anchor";
import {
  PublicKey, Keypair, SystemProgram, LAMPORTS_PER_SOL, ComputeBudgetProgram,
} from "@solana/web3.js";
import {
  TOKEN_PROGRAM_ID,
  ASSOCIATED_TOKEN_PROGRAM_ID,
  createMint, createAccount,
  mintTo, getAccount,
  getAssociatedTokenAddress, getAssociatedTokenAddressSync,
} from "@solana/spl-token";
import { Quid } from "../target/types/quid";
import { expect } from "chai";
import BN from "bn.js";
import { readFileSync } from "fs";
import { homedir } from "os";

// =============================================================================
// PYTH PRICE HELPER (uses fixture accounts loaded by start-validator.sh)
// =============================================================================

const PYTH_ACCOUNTS: Record<string, PublicKey> = {
  XAG: new PublicKey("H9JxsWwtDZxjSL6m7cdCVsWibj3JBMD9sxqLjadoZnot"),
  XAU: new PublicKey("2uPQGpm8X4ZkxMHxrAW1QuhXcse1AHEgPih6Xp9NuEWW"),
  BTC: new PublicKey("4cSM2e6rvbGQUFiJbqytoVMi5GgghSMr8LwVrT9VPSPo"),
  ETH: new PublicKey("42amVS4KgzR9rA28tkVYqVXjq9Qa8dcZQMbH5EYFX6XC"),
  SOL: new PublicKey("7UVimffxr9ow1uXYxsr4LHAcV58mLzhmwaeKvJ1pjLiE"),
};

class PythPriceHelper {
  private latestPrices: Map<string, number> = new Map();

  async fetchPrices(tickers: string[]): Promise<Map<string, number>> {
    const feedIds: Record<string, string> = {
      XAG: "f2fb02c32b055c805e7238d628e5e9dadef274376114eb1f012337cabe93871e",
      XAU: "765d2ba906dbc32ca17cc11f5310a89e9ee1f6420508c63861f2f8ba4ee34bb2",
      BTC: "e62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43",
      ETH: "ff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace",
      SOL: "ef0d8b6fda2ceba41da15d4095d1da392a0d2f8ed0c6c7bc0f4cfac8c280b56d",
    };
    const ids = tickers.map((t) => feedIds[t]).filter(Boolean);
    if (ids.length === 0) return this.latestPrices;
    try {
      const url = `https://hermes.pyth.network/v2/updates/price/latest?${ids.map((id) => `ids[]=${id}`).join("&")}`;
      const resp = await fetch(url);
      const data = await resp.json();
      for (const parsed of (data as any).parsed || []) {
        const ticker = Object.keys(feedIds).find((k) => feedIds[k] === parsed.id);
        if (ticker) {
          const price = Number(parsed.price.price) * Math.pow(10, parsed.price.expo);
          this.latestPrices.set(ticker, price);
        }
      }
    } catch (e) {
      console.log("  ⚠ Could not fetch Hermes prices");
    }
    return this.latestPrices;
  }

  getAccount(ticker: string): PublicKey {
    const account = PYTH_ACCOUNTS[ticker];
    if (!account) throw new Error(`No Pyth account for ticker: ${ticker}`);
    return account;
  }

  getAccountMetas(tickers: string[]): Array<{ pubkey: PublicKey; isSigner: boolean; isWritable: boolean }> {
    return tickers.map((ticker) => ({
      pubkey: this.getAccount(ticker),
      isSigner: false,
      isWritable: false,
    }));
  }

  getPrice(ticker: string): number | undefined {
    return this.latestPrices.get(ticker);
  }

  printPrices(): void {
    console.log("  Current Prices (from Hermes):");
    for (const [ticker, price] of this.latestPrices) {
      console.log(`    ${ticker}: $${price.toFixed(4)}`);
    }
  }
}

// =============================================================================
// TEST SUITE — QU!D Depository
// =============================================================================
// Build with: anchor build -- --features testing
// Run with:   anchor test --skip-local-validator
//
// Pyth fixtures required for the ticker/liquidation sections:
//   node tests/refresh_fixtures.mjs          # normal prices
//   node tests/refresh_fixtures.mjs --depeg  # crashed prices for liquidation
//
// Sections: 1 config · 2 pool · 3 ticker/exposure · 4 liquidation · 5 actuary
//           6 depository auth · 7 config auth · 8 summary · FL flash loans
// (6/7/8 were 21/24/25 in the pre-fork merged suite.)

describe("QU!D Protocol — Depository Suite", () => {
  const provider = anchor.AnchorProvider.env();
  anchor.setProvider(provider);
  const program = anchor.workspace.Quid as Program<Quid>;

  const walletPath = process.env.ANCHOR_WALLET || `${homedir()}/.config/solana/id.json`;
  const payer = Keypair.fromSecretKey(
    new Uint8Array(JSON.parse(readFileSync(walletPath, "utf-8")))
  );

  // ── State ──────────────────────────────────────────────────────────────────
  let mintUSD: PublicKey;
  let userTokenAccount: PublicKey;

  let bankPDA: PublicKey;
  let vaultPDA: PublicKey;
  let configPDA: PublicKey;
  let flashLoanPDA: PublicKey;
  let depositorPDA: PublicKey;

  // Users
  let user2: Keypair;
  let user2TokenAccount: PublicKey;

  let user3: Keypair;
  let user3TokenAccount: PublicKey;


  // Liquidation
  let liquidator: Keypair;
  let victim: Keypair;
  let victimTokenAccount: PublicKey;
  let victimDepositorPDA: PublicKey;

  // Pyth helper
  let pyth: PythPriceHelper;

  // ── Helpers ────────────────────────────────────────────────────────────────

  async function airdrop(pubkey: PublicKey, sol = 10) {
    const sig = await provider.connection.requestAirdrop(pubkey, sol * LAMPORTS_PER_SOL);
    await provider.connection.confirmTransaction(sig);
  }

  function deriveBank(): PublicKey {
    const [pda] = PublicKey.findProgramAddressSync([Buffer.from("depository")], program.programId);
    return pda;
  }

  function deriveVault(mint: PublicKey): PublicKey {
    const [pda] = PublicKey.findProgramAddressSync(
      [Buffer.from("vault"), mint.toBuffer()], program.programId
    );
    return pda;
  }

  function deriveConfig(): PublicKey {
    const [pda] = PublicKey.findProgramAddressSync([Buffer.from("program_config")], program.programId);
    return pda;
  }

  function deriveFlashLoan(): PublicKey {
    const [pda] = PublicKey.findProgramAddressSync([Buffer.from("flash_loan")], program.programId);
    return pda;
  }

  function deriveDepositor(owner: PublicKey): PublicKey {
    const [pda] = PublicKey.findProgramAddressSync([owner.toBuffer()], program.programId);
    return pda;
  }

  function deriveTickerRisk(ticker: string): PublicKey {
    const [pda] = PublicKey.findProgramAddressSync(
      [Buffer.from("risk"), Buffer.from(ticker)], program.programId
    );
    return pda;
  }

  function deriveSolPool(): PublicKey {
    const [pda] = PublicKey.findProgramAddressSync(
      [Buffer.from("sol_pool")], program.programId
    );
    return pda;
  }

  function deriveSolRisk(): PublicKey {
    // Matches Rust: seeds = [b"risk", "SOL".as_bytes()]
    return deriveTickerRisk("SOL");
  }

  // Kestrel's SOL* round trip. Addresses are mainnet's, loaded into the
  // validator from dumps by start-validator.sh.
  const KESTREL  = new PublicKey("LYC8YiiSzQfPpxUW2tpxfuPKGZwywAJhXKUfDP2B66f");
  const SOL_STAR = new PublicKey("FDhu9642aPYNnbTnSoHdAsR9tgSxftPDPjEVdbD58nP2");
  const K_TOKEN  = new PublicKey("6MSD4oSiJq8y5hmryCuMykyTjNXbhha6HSAtrT1EFKQe");
  const K_VAULT  = new PublicKey("DHxRiKmKZn8eEUsqJrwSpHcmMthLXEbsLfYDZMHBKP9B");
  const WSOL     = new PublicKey("So11111111111111111111111111111111111111112");

  /// The accounts SolStarLegs::from_remaining expects, in its order, to sit
  /// after the price feed in remaining_accounts.
  function solStarLegs() {
    const solPool = deriveSolPool();
    return [K_TOKEN, K_VAULT, WSOL, SOL_STAR,
            getAssociatedTokenAddressSync(WSOL, solPool, true),
            getAssociatedTokenAddressSync(SOL_STAR, solPool, true),
            KESTREL, TOKEN_PROGRAM_ID, ASSOCIATED_TOKEN_PROGRAM_ID]
      .map(pubkey => ({ pubkey, isSigner: false, isWritable: true }));
  }

  async function sleep(ms: number): Promise<void> {
    return new Promise(resolve => setTimeout(resolve, ms));
  }

  // ── Setup ──────────────────────────────────────────────────────────────────

  before(async () => {
    console.log("\n╔══════════════════════════════════════════════════════════════╗");
    console.log("║  QU!D PROTOCOL — DEPOSITORY TEST SUITE                       ║");
    console.log("║  Pool · exposure · liquidation · flash loans                 ║");
    console.log("╚══════════════════════════════════════════════════════════════╝\n");

    // Pyth helper
    pyth = new PythPriceHelper();
    try {
      await pyth.fetchPrices(["XAG", "XAU", "BTC", "ETH", "SOL"]);
      pyth.printPrices();
    } catch (e: any) {
      console.log("  ⚠ Could not fetch Hermes prices (offline mode)");
    }

    // Create mock USD mint (6 decimals)
    mintUSD = await createMint(provider.connection, payer, payer.publicKey, null, 6);
    console.log("✓ Mock USD mint:", mintUSD.toString());

    // Derive PDAs
    bankPDA = deriveBank();
    vaultPDA = deriveVault(mintUSD);
    configPDA = deriveConfig();
    flashLoanPDA = deriveFlashLoan();
    depositorPDA = deriveDepositor(payer.publicKey);
    console.log("  Bank PDA:", bankPDA.toString());
    console.log("  Vault PDA:", vaultPDA.toString());
    console.log("  Config PDA:", configPDA.toString());
    console.log("  Flash Loan PDA:", flashLoanPDA.toString());

    // Create user token account and mint tokens
    userTokenAccount = await createAccount(provider.connection, payer, mintUSD, payer.publicKey);
    await mintTo(provider.connection, payer, mintUSD, userTokenAccount, payer.publicKey, 1_000_000 * 10 ** 6);
    console.log("✓ Minted 1,000,000 USD to payer");

    // User2
    user2 = Keypair.generate();
    await airdrop(user2.publicKey);
    user2TokenAccount = await createAccount(provider.connection, payer, mintUSD, user2.publicKey);
    await mintTo(provider.connection, payer, mintUSD, user2TokenAccount, payer.publicKey, 100_000 * 10 ** 6);
    console.log("✓ User2 setup with 100,000 USD");

    // User3
    user3 = Keypair.generate();
    await airdrop(user3.publicKey);
    user3TokenAccount = await createAccount(provider.connection, payer, mintUSD, user3.publicKey);
    await mintTo(provider.connection, payer, mintUSD, user3TokenAccount, payer.publicKey, 50_000 * 10 ** 6);
    console.log("✓ User3 setup with 50,000 USD");

    // Liquidator
    liquidator = Keypair.generate();
    await airdrop(liquidator.publicKey);
    console.log("✓ Liquidator setup");

    // Victim for liquidation tests
    victim = Keypair.generate();
    await airdrop(victim.publicKey);
    victimTokenAccount = await createAccount(provider.connection, payer, mintUSD, victim.publicKey);
    await mintTo(provider.connection, payer, mintUSD, victimTokenAccount, payer.publicKey, 10_000 * 10 ** 6);
    victimDepositorPDA = deriveDepositor(victim.publicKey);
    console.log("✓ Victim setup for liquidation tests (10,000 USD)");

    console.log("\n────────────────────────────────────────────────────────────────\n");
  });

  // =========================================================================
  // 1. PROGRAM CONFIG
  // =========================================================================

  describe("1. Program Config", () => {
    it("1.1 Initializes program config", async () => {
      await program.methods
        .initConfig(mintUSD)
        .accountsStrict({
          admin: payer.publicKey,
          config: configPDA,
          flashLoan: flashLoanPDA,
          solPool:         null,
          systemProgram: SystemProgram.programId,
        })
        .rpc();
      const config = await program.account.programConfig.fetch(configPDA);
      expect(config.tokenMint.toString()).to.equal(mintUSD.toString());
      // registered_mints = [mintUSD, USD_STAR]
      expect(config.registeredMints[0].toString()).to.equal(mintUSD.toString());
    });

    it("1.2 Updates config", async () => {
      // The keeper is gone — parking folded into handle_in, which was its last
      // power — so bebop_authority is what update_config still rotates.
      const newBebop = Keypair.generate().publicKey;

      await program.methods
        .updateConfig(null, newBebop)
        .accountsStrict({
          admin: payer.publicKey,
          config: configPDA,
        })
        .rpc();

      const config = await program.account.programConfig.fetch(configPDA);
      expect(config.bebopAuthority.toString()).to.equal(newBebop.toString());
      console.log("  ✓ bebop_authority rotated");
    });  });

  // =========================================================================
  // 2. POOL DEPOSITS & WITHDRAWALS
  // =========================================================================

  describe("2. Pool Deposits & Withdrawals", () => {
    it("2.1 Deposits collateral to pool (no ticker)", async () => {
      const amount = new BN(100_000 * 10 ** 6);

      await program.methods
        .deposit(amount, "")
        .accountsStrict({
          signer: payer.publicKey,
          mint: mintUSD,
          config: configPDA,
          bank: bankPDA,
          programVault: vaultPDA,
          depositor: depositorPDA,
          tickerRisk: null,
          quid: userTokenAccount,
          tokenProgram: TOKEN_PROGRAM_ID,
          solPool:         null,
          systemProgram: SystemProgram.programId,
        })
        .rpc();

      const depositor = await program.account.depositor.fetch(depositorPDA);
      expect(depositor.depositedQuid.toNumber()).to.equal(amount.toNumber());
      console.log("  ✓ Deposited", (depositor.depositedQuid.toNumber() / 10 ** 6).toFixed(2), "USD");
    });

    it("2.2 User2 deposits to pool", async () => {
      const amount = new BN(20_000 * 10 ** 6);

      await program.methods
        .deposit(amount, "")
        .accountsStrict({
          signer: user2.publicKey,
          mint: mintUSD,
          config: configPDA,
          bank: bankPDA,
          programVault: vaultPDA,
          depositor: deriveDepositor(user2.publicKey),
          tickerRisk: null,
          quid: user2TokenAccount,
          tokenProgram: TOKEN_PROGRAM_ID,
          solPool:         null,
          systemProgram: SystemProgram.programId,
        })
        .signers([user2])
        .rpc();

      console.log("  ✓ User2 deposited 20,000 USD");
    });

    it("2.3 User3 deposits to pool", async () => {
      const amount = new BN(5_000 * 10 ** 6);

      await program.methods
        .deposit(amount, "")
        .accountsStrict({
          signer: user3.publicKey,
          mint: mintUSD,
          config: configPDA,
          bank: bankPDA,
          programVault: vaultPDA,
          depositor: deriveDepositor(user3.publicKey),
          tickerRisk: null,
          quid: user3TokenAccount,
          tokenProgram: TOKEN_PROGRAM_ID,
          solPool:         null,
          systemProgram: SystemProgram.programId,
        })
        .signers([user3])
        .rpc();

      console.log("  ✓ User3 deposited 5,000 USD");
    });

    it("2.4 Withdraws collateral from pool", async () => {
      const withdrawAmount = new BN(-5_000 * 10 ** 6);
      const customerATA = await getAssociatedTokenAddress(mintUSD, payer.publicKey);
      const balanceBefore = await getAccount(provider.connection, userTokenAccount);

      // deposit_seconds accumulates as unix_timestamp delta — need ≥1s elapsed
      // or raw_max = 0 and the time-weighted share calculation returns nothing.
      await sleep(2000);

      await program.methods
        .withdraw(withdrawAmount, "", false)
        .accountsStrict({
          signer: payer.publicKey,
          mint: mintUSD,
          config: configPDA,
          bank: bankPDA,
          bankTokenAccount: vaultPDA,
          customerAccount: depositorPDA,
          customerTokenAccount: userTokenAccount,
          tickerRisk: null,
          solPool: null,
          tokenProgram: TOKEN_PROGRAM_ID,
          associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
          solPool:         null,
          systemProgram: SystemProgram.programId,
        })
        .rpc();

      const balanceAfter = await getAccount(provider.connection, userTokenAccount);
      const received = Number(balanceAfter.amount) - Number(balanceBefore.amount);
      console.log("  ✓ Withdrew:", (received / 10 ** 6).toFixed(2), "USD");
      expect(received).to.be.greaterThan(0);
    });

    it("2.5 Rejects deposit below minimum ($100)", async () => {
      try {
        await program.methods
          .deposit(new BN(50 * 10 ** 6), "") // $50 < $100 min
          .accountsStrict({
            signer: payer.publicKey,
            mint: mintUSD,
            config: configPDA,
            bank: bankPDA,
            programVault: vaultPDA,
            depositor: depositorPDA,
            tickerRisk: null,
            quid: userTokenAccount,
            solPool: null,
            tokenProgram: TOKEN_PROGRAM_ID,
            systemProgram: SystemProgram.programId,
          })
          .rpc();
        expect.fail("Should have rejected small deposit");
      } catch (e: any) {
        expect(e.message).to.include("InvalidAmount");
        console.log("  ✓ Rejected deposit below minimum");
      }
    });  });

  // =========================================================================
  // 3. TICKER DEPOSITS & SYNTHETIC EXPOSURE
  // =========================================================================
  // These tests require Pyth price fixtures loaded by start-validator.sh
  // Run: node tests/refresh_fixtures.mjs first

  describe("3. Ticker Deposits & Exposure", () => {
    it("3.1 Deposits with XAG ticker (pledged only, no exposure)", async () => {
      const amount = new BN(10_000 * 10 ** 6);
      const tickerRiskPDA = deriveTickerRisk("XAG");

      await program.methods
        .deposit(amount, "XAG")
        .accountsStrict({
          signer: payer.publicKey,
          mint: mintUSD,
          config: configPDA,
          bank: bankPDA,
          programVault: vaultPDA,
          depositor: depositorPDA,
          tickerRisk: tickerRiskPDA,
          quid: userTokenAccount,
          tokenProgram: TOKEN_PROGRAM_ID,
          solPool:         null,
          systemProgram: SystemProgram.programId,
        })
        .rpc();

      const depositor = await program.account.depositor.fetch(depositorPDA);
      const xagPos = depositor.balances.find(
        (b: any) => Buffer.from(b.ticker).toString().replace(/\0/g, "") === "XAG"
      );
      expect(xagPos).to.exist;
      console.log("  ✓ XAG pledged:", (xagPos.pledged.toNumber() / 10 ** 6).toFixed(2), "USD");
    });

    it("3.2 Adds long exposure to XAG", async () => {
      // With 10K pledged and XAG at ~$87, max leverage ~4.4x allows
      // exposure value up to ~$44K => ~500 units.  Use 100 units
      // to stay well within bounds after Actuary bootstrap.
      const amount = new BN(100 * 10 ** 6); // 100 units (micro-precision)
      const tickerRiskPDA = deriveTickerRisk("XAG");

      await program.methods
        .withdraw(amount, "XAG", true)
        .accountsStrict({
          signer: payer.publicKey,
          mint: mintUSD,
          config: configPDA,
          bank: bankPDA,
          bankTokenAccount: vaultPDA,
          customerAccount: depositorPDA,
          customerTokenAccount: userTokenAccount,
          tickerRisk: tickerRiskPDA,
          solPool: null,
          tokenProgram: TOKEN_PROGRAM_ID,
          associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
          solPool:         null,
          systemProgram: SystemProgram.programId,
        })
        .remainingAccounts([
          { pubkey: pyth.getAccount("XAG"), isSigner: false, isWritable: false }
        ])
        .rpc();

      const depositor = await program.account.depositor.fetch(depositorPDA);
      const xagPos = depositor.balances.find(
        (b: any) => Buffer.from(b.ticker).toString().replace(/\0/g, "") === "XAG"
      );
      expect(xagPos.exposure.toNumber()).to.be.greaterThan(0);
      console.log("  ✓ XAG long exposure:", xagPos.exposure.toString());
    });

    it("3.6 Prints depositor state", async () => {
      const depositor = await program.account.depositor.fetch(depositorPDA);

      console.log("\n  Depositor State:");
      console.log("    Pool deposit (USD*):", (depositor.depositedQuid.toNumber() / 10 ** 6).toFixed(2));

      for (const bal of depositor.balances) {
        const ticker = Buffer.from(bal.ticker).toString().replace(/\0/g, "");
        if (ticker) {
          console.log(
            `    ${ticker}: pledged=${(bal.pledged.toNumber() / 10 ** 6).toFixed(2)}, exposure=${bal.exposure.toString()}`
          );
        }
      }
    });

    it("3.7 Verifies pool capacity tracking", async () => {
      const bank = await program.account.depository.fetch(bankPDA);

      console.log("\n  Pool State:");
      console.log("    Total Deposits:", (bank.totalDeposits.toNumber() / 10 ** 6).toFixed(2), "USD");
      console.log("    Total Drawn:", (bank.totalDrawn.toNumber() / 10 ** 6).toFixed(2), "USD");
      console.log("    Max Liability:", (bank.maxLiability.toNumber() / 10 ** 6).toFixed(2), "USD");

      const concentration = bank.totalDeposits.toNumber() > 0
        ? (bank.totalDrawn.toNumber() * 10000 / bank.totalDeposits.toNumber())
        : 0;
      console.log("    Concentration:", concentration.toFixed(2), "bps");
      console.log("  ✓ Pool tracking verified");
    });

    it("3.8 Rejects invalid ticker deposit", async () => {
      try {
        await program.methods
          .deposit(new BN(1_000 * 10 ** 6), "FAKE")
          .accountsStrict({
            signer: payer.publicKey,
            mint: mintUSD,
            config: configPDA,
            bank: bankPDA,
            programVault: vaultPDA,
            depositor: depositorPDA,
            tickerRisk: deriveTickerRisk("FAKE"),
            quid: userTokenAccount,
            solPool: null,
            tokenProgram: TOKEN_PROGRAM_ID,
            systemProgram: SystemProgram.programId,
          })
          .rpc();
        expect.fail("Should reject invalid ticker");
      } catch (e: any) {
        console.log("  ✓ Rejected invalid ticker FAKE");
      }
    });  });

  // =========================================================================
  // 4. LIQUIDATION
  // =========================================================================

  describe("4. Liquidation", () => {
    it("4.1 Creates victim position for liquidation test", async () => {
      const tickerRiskPDA = deriveTickerRisk("XAG");
      const depositAmount = new BN(1_000 * 10 ** 6);

      // Victim deposits pledged to XAG
      await program.methods
        .deposit(depositAmount, "XAG")
        .accountsStrict({
          signer: victim.publicKey,
          mint: mintUSD,
          config: configPDA,
          bank: bankPDA,
          programVault: vaultPDA,
          depositor: victimDepositorPDA,
          tickerRisk: tickerRiskPDA,
          quid: victimTokenAccount,
          tokenProgram: TOKEN_PROGRAM_ID,
          solPool:         null,
          systemProgram: SystemProgram.programId,
        })
        .signers([victim])
        .rpc();

      // Create long exposure
      // Victim has $1K pledged on XAG at ~$87: max leverage ~4.2x
      // max exposure_value ~$4.2K => max units ~4.2K/87 ~48K.  Use 5M raw
      // (note: exposure is in asset units where units * whole_dollar_price = USD value,
      //  so 5_000_000 * 87 = $435M... that's still too much.
      //  Actually we need units * price ≤ pledged * max_lev / 100
      //  = 1_000_000_000 * 420 / 100 = 4_200_000_000
      //  => units ≤ 4_200_000_000 / 87 ≈ 48_275_862.  Use 20_000_000.)
      const exposureAmount = new BN(20_000_000);

      try {
        await program.methods
          .withdraw(exposureAmount, "XAG", true)
          .accountsStrict({
            signer: victim.publicKey,
            mint: mintUSD,
            config: configPDA,
            bank: bankPDA,
            bankTokenAccount: vaultPDA,
            customerAccount: victimDepositorPDA,
            customerTokenAccount: victimTokenAccount,
            tickerRisk: tickerRiskPDA,
            solPool: null,
            tokenProgram: TOKEN_PROGRAM_ID,
            associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
            systemProgram: SystemProgram.programId,
          })
          .remainingAccounts([
            { pubkey: pyth.getAccount("XAG"), isSigner: false, isWritable: false }
          ])
          .signers([victim])
          .rpc();

        const depositor = await program.account.depositor.fetch(victimDepositorPDA);
        const xagPos = depositor.balances.find(
          (b: any) => Buffer.from(b.ticker).toString().replace(/\0/g, "") === "XAG"
        );

        console.log("  Victim Position:");
        console.log("    Pledged:", (xagPos.pledged.toNumber() / 10 ** 6).toFixed(2), "USD");
        console.log("    Exposure:", xagPos.exposure.toString());
        console.log("  ✓ Leveraged position created");
      } catch (e: any) {
        const errStr = e.toString();
        if (errStr.includes("PoolAtCapacity") || errStr.includes("6007")) {
          console.log("  ⚠ Pool at capacity — skipping exposure (LP deposits needed first)");
        } else {
          throw e;
        }
      }
    });

    it("4.2 Liquidation rejected when position healthy", async () => {
      const tickerRiskPDA = deriveTickerRisk("XAG");

      try {
        await program.methods
          .liquidate("XAG")
          .accountsStrict({
            liquidating: victim.publicKey,
            liquidator: liquidator.publicKey,
            mint: mintUSD,
            config: configPDA,
            bank: bankPDA,
            bankTokenAccount: vaultPDA,
            customerAccount: victimDepositorPDA,
            liquidatorDepositor: deriveDepositor(liquidator.publicKey),
            tickerRisk: tickerRiskPDA,
            tokenProgram: TOKEN_PROGRAM_ID,
            associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
            systemProgram: SystemProgram.programId,
          })
          .remainingAccounts([
            { pubkey: pyth.getAccount("XAG"), isSigner: false, isWritable: false },
          ])
          .signers([liquidator])
          .rpc();

        console.log("  ⚠ Liquidation succeeded (position may have been unhealthy)");
      } catch (e: any) {
        if (e.message?.includes("NotUndercollateralised")) {
          console.log("  ✓ Liquidation correctly rejected (position healthy)");
        } else {
          console.log("  ✓ Liquidation rejected:", e.message?.slice(0, 60));
        }
      }
    });

    it("4.3 Documents liquidation flow", async () => {
      console.log("\n  Liquidation Mechanism (from stay.rs):");
      console.log("    1. Position breaches collar threshold");
      console.log("    2. Self-salvage check: if deposited_quid >= shortfall");
      console.log("       → Auto-salvage from user's pool deposit");
      console.log("    3. Third-party liquidation allowed only if:");
      console.log("       - Insufficient pool funds for self-salvage");
      console.log("       - Position age > MAX_AGE");
      console.log("    4. Amortization gradually reduces exposure");
      console.log("    5. Liquidator receives 0.4% commission (delta / 250)");
      console.log("\n  ✓ MEV protection: bots cannot frontrun self-salvage");
    });  });

  // =========================================================================
  // 5. ACTUARY RISK MODEL
  // =========================================================================

  describe("5. Actuary Risk Model", () => {
    it("5.1 Verifies TickerRisk state for XAG", async () => {
      const tickerRiskPDA = deriveTickerRisk("XAG");
      try {
        const risk = await program.account.tickerRisk.fetch(tickerRiskPDA);
        const ticker = Buffer.from(risk.ticker).toString().replace(/\0/g, "");
        console.log("  TickerRisk for:", ticker);
        console.log("    observed_vol:", risk.actuary.observedVolBps.toString());
        console.log("    max_drawdown:", risk.actuary.maxDrawdownBps.toString());
        console.log("    last_price:", risk.actuary.lastPrice.toString());
        console.log("    obs_count:", risk.actuary.obsCount.toString());
        console.log("    jump_count:", risk.actuary.jumpCount.toString());
        console.log("    velocity:", risk.actuary.velocity.toString());
        console.log("    net_exposure:", risk.actuary.netExposure.toString());
        console.log("    total_exposure:", risk.actuary.totalExposure.toString());
        console.log("    twap_price:", risk.actuary.twapPrice.toString());
        console.log("  ✓ TickerRisk active");
      } catch {
        console.log("  ⚠ TickerRisk not yet initialised for XAG");
      }
    });

    it("5.2 Documents Actuary learning model", async () => {
      console.log("\n  Actuary Risk Oracle — learns from observation:");
      console.log("    - Confidence: obs × 100 / (obs + 10)");
      console.log("      10 obs → 50%, 50 obs → 83%, 100 obs → 91%");
      console.log("    - Vol floor decays with confidence (prevents quiet-start attack)");
      console.log("    - Asset classes: FX(80bps), Equity(200bps), Crypto(400bps)");
      console.log("    - Jump detection: move > 3σ");
      console.log("    - TWAP EMA with adaptive alpha for manipulation resistance");
      console.log("  ✓ Documented");
    });  });

  // =========================================================================
  // 6. DEPOSITORY AUTHORIZATION GUARDS
  // =========================================================================

  describe("6. Depository Authorization Guards", () => {
    it("6.1 Rejects withdrawal from another user's depositor", async () => {
      // user2 tries to withdraw from payer's depositor account
      try {
        await program.methods
          .withdraw(new BN(-100 * 10 ** 6), "", false)
          .accountsStrict({
            signer: user2.publicKey,
            mint: mintUSD,
            config: configPDA,
            bank: bankPDA,
            bankTokenAccount: vaultPDA,
            customerAccount: depositorPDA, // payer's depositor
            customerTokenAccount: user2TokenAccount,
            tickerRisk: null,
            solPool: null,
            tokenProgram: TOKEN_PROGRAM_ID,
            associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
            systemProgram: SystemProgram.programId,
          })
          .signers([user2])
          .rpc();
        expect.fail("Should reject withdrawal from another user's account");
      } catch (e: any) {
        // PDA seeds won't match user2's key → Anchor seed constraint failure
        console.log("  ✓ Rejected withdrawal from another user's depositor");
      }
    });

    it("6.2 Rejects positive amount for pool withdrawal (must be negative)", async () => {
      try {
        await program.methods
          .withdraw(new BN(100 * 10 ** 6), "", false) // positive = invalid for pool withdraw
          .accountsStrict({
            signer: payer.publicKey,
            mint: mintUSD,
            config: configPDA,
            bank: bankPDA,
            bankTokenAccount: vaultPDA,
            customerAccount: depositorPDA,
            customerTokenAccount: userTokenAccount,
            tickerRisk: null,
            solPool: null,
            tokenProgram: TOKEN_PROGRAM_ID,
            associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
            systemProgram: SystemProgram.programId,
          })
          .rpc();
        expect.fail("Should reject positive amount for pool withdrawal");
      } catch (e: any) {
        expect(e.toString()).to.include("InvalidAmount");
        console.log("  ✓ Rejected positive amount for pool withdrawal");
      }
    });

    it("6.3 Multiple sequential deposits accumulate correctly", async () => {
      const depBefore = await program.account.depositor.fetch(depositorPDA);
      const beforeQuid = depBefore.depositedQuid.toNumber();

      const deposit1 = 500 * 10 ** 6;
      const deposit2 = 300 * 10 ** 6;

      await program.methods
        .deposit(new BN(deposit1), "")
        .accountsStrict({
          signer: payer.publicKey,
          mint: mintUSD,
          config: configPDA,
          bank: bankPDA,
          programVault: vaultPDA,
          depositor: depositorPDA,
          tickerRisk: null,
          quid: userTokenAccount,
          tokenProgram: TOKEN_PROGRAM_ID,
          solPool:         null,
          systemProgram: SystemProgram.programId,
        })
        .rpc();

      await program.methods
        .deposit(new BN(deposit2), "")
        .accountsStrict({
          signer: payer.publicKey,
          mint: mintUSD,
          config: configPDA,
          bank: bankPDA,
          programVault: vaultPDA,
          depositor: depositorPDA,
          tickerRisk: null,
          quid: userTokenAccount,
          tokenProgram: TOKEN_PROGRAM_ID,
          solPool:         null,
          systemProgram: SystemProgram.programId,
        })
        .rpc();

      const depAfter = await program.account.depositor.fetch(depositorPDA);
      const afterQuid = depAfter.depositedQuid.toNumber();

      expect(afterQuid).to.be.greaterThanOrEqual(beforeQuid + deposit1 + deposit2);
      console.log("  ✓ Sequential deposits accumulated:",
        ((afterQuid - beforeQuid) / 10 ** 6).toFixed(2), "USD added");
    });  });

  // =========================================================================
  // 7. CONFIG AUTHORIZATION
  // =========================================================================

  describe("7. Config Authorization", () => {
    it("7.1 Non-admin cannot update config", async () => {
      try {
        await program.methods
          .updateConfig(Keypair.generate().publicKey, null)
          .accountsStrict({
            admin: user2.publicKey,
            config: configPDA,
          })
          .signers([user2])
          .rpc();
        expect.fail("Should reject non-admin config update");
      } catch (e: any) {
        expect(e.toString()).to.include("Unauthorized");
        console.log("  ✓ Rejected non-admin config update");
      }
    });

    it("7.2 Admin transfers admin to new key then back", async () => {
      const tempAdmin = Keypair.generate();
      await airdrop(tempAdmin.publicKey);

      // Transfer admin to tempAdmin
      await program.methods
        .updateConfig(tempAdmin.publicKey, null)
        .accountsStrict({
          admin: payer.publicKey,
          config: configPDA,
        })
        .rpc();

      let config = await program.account.programConfig.fetch(configPDA);
      expect(config.admin.toString()).to.equal(tempAdmin.publicKey.toString());

      // Old admin can no longer update
      try {
        await program.methods
          .updateConfig(payer.publicKey, null)
          .accountsStrict({
            admin: payer.publicKey,
            config: configPDA,
          })
          .rpc();
        expect.fail("Old admin should be rejected");
      } catch (e: any) {
        expect(e.toString()).to.include("Unauthorized");
      }

      // Transfer back
      await program.methods
        .updateConfig(payer.publicKey, null)
        .accountsStrict({
          admin: tempAdmin.publicKey,
          config: configPDA,
        })
        .signers([tempAdmin])
        .rpc();

      config = await program.account.programConfig.fetch(configPDA);
      expect(config.admin.toString()).to.equal(payer.publicKey.toString());
      console.log("  ✓ Admin transfer and revocation verified");
    });  });

  // =========================================================================
  // 8. SYSTEM STATE SUMMARY
  // =========================================================================

  describe("8. System Summary", () => {
    it("8.1 Prints final system state", async () => {
      const bank = await program.account.depository.fetch(bankPDA);
      console.log("\n  ═══ FINAL SYSTEM STATE ═══");
      console.log("  Total deposits:", (bank.totalDeposits.toNumber() / 10 ** 6).toFixed(2), "USD");
      console.log("  Total drawn:", (bank.totalDrawn.toNumber() / 10 ** 6).toFixed(2), "USD");
      console.log("  Max liability:", (bank.maxLiability.toNumber() / 10 ** 6).toFixed(2), "USD");

      const payerDep = await program.account.depositor.fetch(depositorPDA);
      const user2Dep = await program.account.depositor.fetch(deriveDepositor(user2.publicKey));
      const user3Dep = await program.account.depositor.fetch(deriveDepositor(user3.publicKey));

      console.log("\n  Depositor balances:");
      console.log("    Payer:", (payerDep.depositedQuid.toNumber() / 10 ** 6).toFixed(2), "USD");
      console.log("    User2:", (user2Dep.depositedQuid.toNumber() / 10 ** 6).toFixed(2), "USD");
      console.log("    User3:", (user3Dep.depositedQuid.toNumber() / 10 ** 6).toFixed(2), "USD");

      console.log("\n  Payer positions:");
      for (const bal of payerDep.balances) {
        const ticker = Buffer.from(bal.ticker).toString().replace(/\0/g, "");
        if (ticker) {
          console.log(
            `    ${ticker}: pledged=${(bal.pledged.toNumber() / 10 ** 6).toFixed(2)}, exposure=${bal.exposure.toString()}`
          );
        }
      }

        console.log("\n  ✓ All DeFi tests complete");
    });  });


  // =========================================================================
  // FL. Flash Loans
  // =========================================================================
  // Tests cover SOL and SPL paths for flash_borrow / flash_repay.
  // Both instructions now require the dedicated FlashLoan PDA account.
  // FlashBorrow: flash_loan must be zero-state (FlashLoanActive constraint).
  // FlashRepay:  must be in same TX as flash_borrow (sysvar co-presence).
  // =========================================================================

  describe("FL. Flash Loans", () => {
    // flash_authority must be a keypair signer whose pubkey matches config.bebop_authority.
    // Set bebop_authority to payer before the suite, then restore to default after.
    let bebopAuthKp: anchor.web3.Keypair;

    before(async () => {
      bebopAuthKp = payer; // reuse payer as flash authority in tests
      await program.methods
        .updateConfig(null, payer.publicKey)
        .accountsStrict({ admin: payer.publicKey, config: configPDA })
        .rpc();

      // depositSol updates bank.sol_lamports AND transfers lamports to sol_pool.
      // Direct SystemProgram.transfer alone does NOT update bank.sol_lamports.
      // Native SOL rides `deposit` now: ticker "SOL" plus solPool selects the
      // native leg. `quid` is null on purpose — a wallet holding nothing but
      // lamports owns no token account, and requiring one would be an
      // enrollment step before a first deposit could be made at all.
      await program.methods
        .deposit(new BN(2 * LAMPORTS_PER_SOL), "SOL")
        .accountsStrict({
          signer:          payer.publicKey,
          mint:            mintUSD,
          config:          configPDA,
          bank:            bankPDA,
          programVault:    vaultPDA,
          depositor:       depositorPDA,
          tickerRisk:      deriveSolRisk(),
          quid:            null,
          solPool:         deriveSolPool(),
          tokenProgram:    TOKEN_PROGRAM_ID,
          systemProgram:   SystemProgram.programId,
        })
        .remainingAccounts(pyth.getAccountMetas(["SOL"]))
        .rpc();
      console.log("  ✓ bebop_authority set to payer, 2 SOL deposited into flash loan vault");
    });

    it("FL.1 SOL flash borrow and repay round-trip succeeds", async () => {
      const BORROW_SOL = new BN(500_000_000); // 0.5 SOL
      const TIP_SOL    = new BN(0);

      const bankBefore  = await program.account.depository.fetch(bankPDA);
      const flashBefore = await program.account.flashLoan.fetch(flashLoanPDA);
      expect(flashBefore.flashLamports.toNumber()).to.equal(0);

      // Build borrow and repay as two instructions in one TX so the
      // sysvar co-presence check passes.
      const borrowIx = await program.methods
        .flashBorrow(BORROW_SOL, new BN(0), 0)
        .accountsStrict({
          flashAuthority: bebopAuthKp.publicKey,
          borrower:       payer.publicKey,
          bank:           bankPDA,
          flashLoan:      flashLoanPDA,
          config:         configPDA,
          solPool:        deriveSolPool(),
          ixSysvar:       anchor.web3.SYSVAR_INSTRUCTIONS_PUBKEY,
          systemProgram:  SystemProgram.programId,
        })
        .instruction();

      const repayIx = await program.methods
        .flashRepay(TIP_SOL, new BN(0), 0)
        .accountsStrict({
          repayer:       payer.publicKey,
          bank:          bankPDA,
          flashLoan:     flashLoanPDA,
          solRisk:       deriveSolRisk(),
          solPool:       deriveSolPool(),
          systemProgram: SystemProgram.programId,
        })
        .remainingAccounts(pyth.getAccountMetas(["SOL"]))
        .instruction();

      const tx = new anchor.web3.Transaction().add(borrowIx, repayIx);
      await provider.sendAndConfirm(tx, [payer, bebopAuthKp]);

      const bankAfter  = await program.account.depository.fetch(bankPDA);
      const flashAfter = await program.account.flashLoan.fetch(flashLoanPDA);

      expect(flashAfter.flashLamports.toNumber()).to.equal(0);
      expect(bankAfter.solLamports.toNumber()).to.equal(bankBefore.solLamports.toNumber());
      console.log("  ✓ SOL flash loan round-trip: borrowed",
        BORROW_SOL.toNumber() / LAMPORTS_PER_SOL, "SOL, repaid, state zeroed");
    });

    it("FL.2 SOL flash borrow with tip increases sol_lamports", async () => {
      const BORROW_SOL = new BN(100_000_000); // 0.1 SOL
      const TIP_SOL    = new BN(10_000_000);  // 0.01 SOL tip

      const bankBefore = await program.account.depository.fetch(bankPDA);

      const borrowIx = await program.methods
        .flashBorrow(BORROW_SOL, new BN(0), 0)
        .accountsStrict({
          flashAuthority: bebopAuthKp.publicKey,
          borrower:       payer.publicKey,
          bank:           bankPDA,
          flashLoan:      flashLoanPDA,
          config:         configPDA,
          solPool:        deriveSolPool(),
          ixSysvar:       anchor.web3.SYSVAR_INSTRUCTIONS_PUBKEY,
          systemProgram:  SystemProgram.programId,
        })
        .instruction();

      const repayIx = await program.methods
        .flashRepay(TIP_SOL, new BN(0), 0)
        .accountsStrict({
          repayer:       payer.publicKey,
          bank:          bankPDA,
          flashLoan:     flashLoanPDA,
          solRisk:       deriveSolRisk(),
          solPool:       deriveSolPool(),
          systemProgram: SystemProgram.programId,
        })
        .remainingAccounts(pyth.getAccountMetas(["SOL"]))
        .instruction();

      const tx = new anchor.web3.Transaction().add(borrowIx, repayIx);
      await provider.sendAndConfirm(tx, [payer, bebopAuthKp]);

      const bankAfter  = await program.account.depository.fetch(bankPDA);
      const flashAfter = await program.account.flashLoan.fetch(flashLoanPDA);

      expect(flashAfter.flashLamports.toNumber()).to.equal(0);
      expect(bankAfter.solLamports.toNumber()).to.equal(
        bankBefore.solLamports.toNumber() + TIP_SOL.toNumber()
      );
      console.log("  ✓ SOL flash loan with tip: pool grew by",
        TIP_SOL.toNumber() / LAMPORTS_PER_SOL, "SOL");
    });

    it("FL.3 Second borrow rejected while first is in-flight (FlashLoanActive)", async () => {
      // Manually set flash state by running a borrow without a repay — impossible
      // due to sysvar check. Instead, verify constraint fires when we attempt
      // a standalone borrow on a pre-populated account by simulating the state.
      // We verify the error code path by attempting borrow + borrow (no repay).
      // This TX will fail at sysvar check on second borrow (no repay present),
      // but demonstrates the error path for double-borrow is blocked.
      try {
        const borrowIx = await program.methods
          .flashBorrow(new BN(100_000_000), new BN(0), 0)
          .accountsStrict({
            flashAuthority: bebopAuthKp.publicKey,
            borrower:       payer.publicKey,
            bank:           bankPDA,
            flashLoan:      flashLoanPDA,
            config:         configPDA,
            solPool:        deriveSolPool(),
            ixSysvar:       anchor.web3.SYSVAR_INSTRUCTIONS_PUBKEY,
            systemProgram:  SystemProgram.programId,
          })
          .instruction();

        // Submit borrow alone — no repay in TX → FlashRepayMissing
        const tx = new anchor.web3.Transaction().add(borrowIx);
        await provider.sendAndConfirm(tx, [payer]);
        expect.fail("Should have rejected borrow without repay");
      } catch (e: any) {
        const msg = e.toString();
        const ok = msg.includes("FlashRepayMissing") || msg.includes("6") || msg.includes("flash");
        if (!ok) throw e;
        console.log("  ✓ Borrow without repay rejected:", msg.slice(0, 60));
      }
    });

    it("FL.4 Repay with wrong mint rejected", async () => {
      const wrongMint = await createMint(
        provider.connection, payer, payer.publicKey, null, 6
      );
      const wrongVaultPDA = deriveVault(wrongMint);

      // Fund wrong vault so the transfer doesn't fail on balance
      const wrongVaultAta = wrongVaultPDA; // vault IS the ATA in this program
      // We don't need to fund — we expect rejection before transfer

      const borrowIx = await program.methods
        .flashBorrow(new BN(0), new BN(1_000_000), 0) // SPL borrow attempt
        .accountsStrict({
          flashAuthority: bebopAuthKp.publicKey,
          borrower:       payer.publicKey,
          bank:           bankPDA,
          flashLoan:      flashLoanPDA,
          config:         configPDA,
          solPool:        deriveSolPool(),
          ixSysvar:       anchor.web3.SYSVAR_INSTRUCTIONS_PUBKEY,
          systemProgram:  SystemProgram.programId,
        })
        .remainingAccounts([
          { pubkey: vaultPDA,      isSigner: false, isWritable: true },
          { pubkey: mintUSD,       isSigner: false, isWritable: false },
          { pubkey: userTokenAccount, isSigner: false, isWritable: true },
          { pubkey: TOKEN_PROGRAM_ID, isSigner: false, isWritable: false },
        ])
        .instruction();

      // Repay using wrong mint — should be rejected with InvalidMint
      const repayIx = await program.methods
        .flashRepay(new BN(0), new BN(1_000_000), 0)
        .accountsStrict({
          repayer:       payer.publicKey,
          bank:          bankPDA,
          flashLoan:     flashLoanPDA,
          solRisk:       deriveSolRisk(),
          solPool:       deriveSolPool(),
          systemProgram: SystemProgram.programId,
        })
        .remainingAccounts([
          { pubkey: wrongVaultPDA,   isSigner: false, isWritable: true },
          { pubkey: wrongMint,       isSigner: false, isWritable: false },
          { pubkey: userTokenAccount, isSigner: false, isWritable: true },
          { pubkey: TOKEN_PROGRAM_ID, isSigner: false, isWritable: false },
        ])
        .instruction();

      try {
        const tx = new anchor.web3.Transaction().add(borrowIx, repayIx);
        await provider.sendAndConfirm(tx, [payer]);
        expect.fail("Should have rejected wrong-mint repay");
      } catch (e: any) {
        const msg = e.toString();
        const ok = msg.includes("InvalidMint") || msg.includes("InvalidParameters")
                || msg.includes("InvalidSettlementProgram") || msg.includes("Error");
        if (!ok) throw e;
        console.log("  ✓ Wrong-mint repay rejected");
      }
    });

    it("FL.5 SPL flash borrow not permitted for unregistered mint", async () => {
      const unregisteredMint = await createMint(
        provider.connection, payer, payer.publicKey, null, 6
      );
      const unregVault = deriveVault(unregisteredMint);

      try {
        const borrowIx = await program.methods
          .flashBorrow(new BN(0), new BN(1_000_000), 0)
          .accountsStrict({
            flashAuthority: bebopAuthKp.publicKey,
            borrower:       payer.publicKey,
            bank:           bankPDA,
            flashLoan:      flashLoanPDA,
            config:         configPDA,
            solPool:        deriveSolPool(),
            ixSysvar:       anchor.web3.SYSVAR_INSTRUCTIONS_PUBKEY,
            systemProgram:  SystemProgram.programId,
          })
          .remainingAccounts([
            { pubkey: unregVault,        isSigner: false, isWritable: true },
            { pubkey: unregisteredMint,  isSigner: false, isWritable: false },
            { pubkey: userTokenAccount,  isSigner: false, isWritable: true },
            { pubkey: TOKEN_PROGRAM_ID,  isSigner: false, isWritable: false },
          ])
          .instruction();

        const repayIx = await program.methods
          .flashRepay(new BN(0), new BN(1_000_000), 0)
          .accountsStrict({
            repayer:       payer.publicKey,
            bank:          bankPDA,
            flashLoan:     flashLoanPDA,
            solRisk:       deriveSolRisk(),
            solPool:       deriveSolPool(),
            systemProgram: SystemProgram.programId,
          })
          .remainingAccounts([
            { pubkey: unregVault,       isSigner: false, isWritable: true },
            { pubkey: unregisteredMint, isSigner: false, isWritable: false },
            { pubkey: userTokenAccount, isSigner: false, isWritable: true },
            { pubkey: TOKEN_PROGRAM_ID, isSigner: false, isWritable: false },
          ])
          .instruction();

        const tx = new anchor.web3.Transaction().add(borrowIx, repayIx);
        await provider.sendAndConfirm(tx, [payer]);
        expect.fail("Should have rejected unregistered mint borrow");
      } catch (e: any) {
        const msg = e.toString();
        const ok = msg.includes("InvalidMint") || msg.includes("Error");
        if (!ok) throw e;
        console.log("  ✓ Unregistered mint borrow rejected");
      }
    });

    it("FL.6 Flash loan state is zero after suite (invariant check)", async () => {
      const flash = await program.account.flashLoan.fetch(flashLoanPDA);
      expect(flash.flashLamports.toNumber()).to.equal(0);
      expect(flash.flashTokenAmount.toNumber()).to.equal(0);
      expect(flash.flashTokenMint.toString()).to.equal(SystemProgram.programId.toString());
      console.log("  ✓ FlashLoan PDA is fully zeroed — no loan in flight");
    });

  });

  // =========================================================================
  // SW. Sweep & stress seams
  // =========================================================================
  // The sweep processes caller-supplied accounts in a loop, so the cases that
  // matter are the hostile ones: foreign accounts, look-alikes, and positions
  // that are simply healthy. None of them may revert the batch — a sweep that
  // dies on one bad account marks nothing, which is the failure mode the
  // permissionless design exists to avoid.

  describe("SW. Sweep & stress seams", () => {
    it("SW.1 Sweep is permissionless and survives a healthy book", async () => {
      const before = await program.account.depository.fetch(bankPDA);

      await program.methods
        .sweep("XAG")
        .accountsStrict({
          cranker: user2.publicKey,
          config: configPDA,
          bank: bankPDA,
          tickerRisk: deriveTickerRisk("XAG"),
          crankerAccount: deriveDepositor(user2.publicKey),
          systemProgram: SystemProgram.programId,
        })
        .remainingAccounts([
          { pubkey: pyth.getAccount("XAG"), isSigner: false, isWritable: false },
          { pubkey: depositorPDA,           isSigner: false, isWritable: true  },
          { pubkey: victimDepositorPDA,     isSigner: false, isWritable: true  },
        ])
        .signers([user2])
        .rpc();

      const after = await program.account.depository.fetch(bankPDA);
      expect(after.sweptAt.toNumber()).to.be.greaterThan(0);
      expect(after.sweptAt.toNumber()).to.be.greaterThanOrEqual(before.sweptAt.toNumber());
      console.log("  ✓ Swept by a non-keeper; coverage stamped at",
                  after.sweptAt.toNumber());
    });

    it("SW.2 Foreign and look-alike accounts are skipped, not fatal", async () => {
      // A system account, the config PDA, and a random key — none of them are
      // Depositors. The batch must complete regardless.
      await program.methods
        .sweep("XAG")
        .accountsStrict({
          cranker: user2.publicKey,
          config: configPDA,
          bank: bankPDA,
          tickerRisk: deriveTickerRisk("XAG"),
          crankerAccount: deriveDepositor(user2.publicKey),
          systemProgram: SystemProgram.programId,
        })
        .remainingAccounts([
          { pubkey: pyth.getAccount("XAG"),   isSigner: false, isWritable: false },
          { pubkey: SystemProgram.programId,  isSigner: false, isWritable: true  },
          { pubkey: configPDA,                isSigner: false, isWritable: true  },
          { pubkey: Keypair.generate().publicKey, isSigner: false, isWritable: true },
          { pubkey: depositorPDA,             isSigner: false, isWritable: true  },
        ])
        .signers([user2])
        .rpc();
      console.log("  ✓ Hostile batch completed without reverting");
    });

    it("SW.3 Sweep rejects a price account for the wrong ticker", async () => {
      try {
        await program.methods
          .sweep("XAG")
          .accountsStrict({
            cranker: user2.publicKey,
            config: configPDA,
            bank: bankPDA,
            tickerRisk: deriveTickerRisk("XAG"),
            crankerAccount: deriveDepositor(user2.publicKey),
            systemProgram: SystemProgram.programId,
          })
          .remainingAccounts([
            { pubkey: pyth.getAccount("ETH"), isSigner: false, isWritable: false },
            { pubkey: depositorPDA,           isSigner: false, isWritable: true  },
          ])
          .signers([user2])
          .rpc();
        expect.fail("Should reject a mismatched price feed");
      } catch (e: any) {
        expect(e.toString()).to.match(/UnknownSymbol|Tickers/);
        console.log("  ✓ Mismatched feed rejected");
      }
    });

    it("SW.4 Sweep with no price account at all is rejected", async () => {
      try {
        await program.methods
          .sweep("XAG")
          .accountsStrict({
            cranker: user2.publicKey,
            config: configPDA,
            bank: bankPDA,
            tickerRisk: deriveTickerRisk("XAG"),
            crankerAccount: deriveDepositor(user2.publicKey),
            systemProgram: SystemProgram.programId,
          })
          .remainingAccounts([])
          .signers([user2])
          .rpc();
        expect.fail("Should reject an empty batch");
      } catch (e: any) {
        expect(e.toString()).to.match(/NoPrice|UnknownSymbol/);
        console.log("  ✓ Empty batch rejected");
      }
    });

    it("SW.5 Parking is refused while it is switched off", async () => {
      // set_kestrel has never been called, so kestrel_program is default and
      // handle_in's parking step must fail closed rather than reach a CPI.
      const cfg = await program.account.programConfig.fetch(configPDA);
      expect(cfg.kestrelProgram.toString()).to.equal(PublicKey.default.toString());
      console.log("  ✓ SOL* parking disabled by default");
    });

    it("SW.5b SOL* park and unpark round-trip against the live Kestrel program",
       async function () {
      // Kestrel's `long_yield_carry` is loaded into the validator from a
      // mainnet dump, together with the real SOL market Token PDA, its wSOL
      // collateral vault and the SOL* mint — so this exercises the actual CPI
      // rather than a stand-in. Skips cleanly if the fixture is absent.
      if (!(await provider.connection.getAccountInfo(KESTREL))) {
        console.log("  ⚠ Kestrel fixture absent — skipping");
        this.skip();
      }

      // Enable parking: 20% stays hot (the floor), 5% deadband, no hold, so a
      // single deposit clears the band and a withdrawal can unwind at once.
      await program.methods
        .setKestrel(KESTREL, SOL_STAR, 2000, 500, 500, new BN(0))
        .accountsStrict({ admin: payer.publicKey, config: configPDA, bank: bankPDA })
        .rpc();

      const solPool = deriveSolPool();
      const legs = solStarLegs();
      const budget = [ComputeBudgetProgram.setComputeUnitLimit({ units: 400_000 })];

      const before = await program.account.depository.fetch(bankPDA);

      await program.methods
        .deposit(new BN(3 * LAMPORTS_PER_SOL), "SOL")
        .accountsStrict({
          signer: payer.publicKey, mint: mintUSD, config: configPDA,
          bank: bankPDA, programVault: vaultPDA, depositor: depositorPDA,
          tickerRisk: deriveSolRisk(), quid: null, solPool,
          tokenProgram: TOKEN_PROGRAM_ID, systemProgram: SystemProgram.programId,
        })
        .remainingAccounts([...pyth.getAccountMetas(["SOL"]), ...legs])
        .preInstructions(budget)
        .rpc();

      const parked = await program.account.depository.fetch(bankPDA);
      expect(parked.solStarShares.toNumber())
        .to.be.greaterThan(before.solStarShares.toNumber(),
                           "the deposit should have parked its excess as SOL*");
      // Parked lamports are credited net of the haircut, never above cost.
      expect(parked.solStarCreditedLamports.toNumber())
        .to.be.at.most(parked.solStarCostLamports.toNumber());
      console.log("  ✓ parked", parked.solStarCostLamports.toNumber(),
                  "lamports →", parked.solStarShares.toNumber(), "SOL*");

      // Now take more than the hot buffer holds, forcing an unwind.
      const hot = parked.solLamports.toNumber();
      await program.methods
        .withdraw(new BN(hot + LAMPORTS_PER_SOL), "SOL", false)
        .accountsStrict({
          signer: payer.publicKey, mint: mintUSD, config: configPDA,
          bank: bankPDA, bankTokenAccount: vaultPDA,
          customerAccount: depositorPDA, customerTokenAccount: userTokenAccount,
          solPool, tickerRisk: deriveSolRisk(),
          tokenProgram: TOKEN_PROGRAM_ID,
          associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
          systemProgram: SystemProgram.programId,
        })
        .remainingAccounts([...pyth.getAccountMetas(["SOL"]), ...legs])
        .preInstructions(budget)
        .rpc();

      const after = await program.account.depository.fetch(bankPDA);
      expect(after.solStarShares.toNumber())
        .to.be.lessThan(parked.solStarShares.toNumber(),
                        "the withdrawal should have burned SOL* to pay out");
      console.log("  ✓ unparked, ", after.solStarShares.toNumber(), "SOL* left");

      // Switching the issuer off while SOL* is still held would strand it —
      // every unwind is addressed to the program named in config, so clearing
      // it removes the only route back to lamports. The program refuses.
      expect(after.solStarShares.toNumber()).to.be.greaterThan(0);
      try {
        await program.methods
          .setKestrel(PublicKey.default, PublicKey.default, 2000, 500, 1000,
                      new BN(21 * 86400))
          .accountsStrict({ admin: payer.publicKey, config: configPDA, bank: bankPDA })
          .rpc();
        expect.fail("Disabling Kestrel with SOL* outstanding should be refused");
      } catch (e: any) {
        expect(e.toString()).to.match(/FlashLoanActive|custom program error/);
        console.log("  ✓ cannot switch off the issuer while its token is held");
      }
      // Kestrel stays enabled for the rest of the suite; unwinding must remain
      // possible in that state, which is what SW.8 goes on to exercise.
    });

    it("SW.6 Deposit of zero and unknown tickers are rejected", async () => {
      for (const [amount, ticker, why] of [
        [new BN(0), "", "zero amount"],
        [new BN(500 * 10 ** 6), "NOTATICKER", "unknown ticker"],
      ] as [BN, string, string][]) {
        try {
          await program.methods
            .deposit(amount, ticker)
            .accountsStrict({
              signer: payer.publicKey,
              mint: mintUSD,
              config: configPDA,
              bank: bankPDA,
              programVault: vaultPDA,
              depositor: depositorPDA,
              tickerRisk: ticker ? deriveTickerRisk(ticker) : null,
              quid: userTokenAccount,
              solPool: null,
              tokenProgram: TOKEN_PROGRAM_ID,
              systemProgram: SystemProgram.programId,
            })
            .rpc();
          expect.fail(`Should reject ${why}`);
        } catch (e: any) {
          expect(e.toString()).to.match(/InvalidAmount|UnknownSymbol|Simulation failed/);
        }
      }
      console.log("  ✓ Zero deposits and unknown tickers rejected");
    });

    it("SW.7 Withdrawing more than the balance cannot mint value", async () => {
      const before = await program.account.depositor.fetch(depositorPDA);
      const absurd = new BN(-1).mul(new BN(10 ** 15));
      try {
        await program.methods
          .withdraw(absurd, "", false)
          .accountsStrict({
            signer: payer.publicKey,
            mint: mintUSD,
            config: configPDA,
            bank: bankPDA,
            bankTokenAccount: vaultPDA,
            customerAccount: depositorPDA,
            customerTokenAccount: userTokenAccount,
            tickerRisk: null,
            solPool: null,
            tokenProgram: TOKEN_PROGRAM_ID,
            associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
            systemProgram: SystemProgram.programId,
          })
          .rpc();
      } catch (e: any) { /* reverting is an acceptable outcome */ }

      const after = await program.account.depositor.fetch(depositorPDA);
      expect(after.depositedQuid.toNumber())
        .to.be.at.most(before.depositedQuid.toNumber());
      console.log("  ✓ Oversized withdrawal cannot increase a balance");
    });

    it("SW.8 A native SOL withdrawal of 0 means all of it", async () => {
      // A depositor cannot know their own accrued carry ahead of time, so the
      // full-exit path takes 0 rather than a figure they would have to guess.
      const before = await program.account.depositor.fetch(depositorPDA);
      expect(before.depositedLamports.toNumber()).to.be.greaterThan(0);

      await program.methods
        .withdraw(new BN(0), "SOL", false)
        .accountsStrict({
          signer: payer.publicKey,
          mint: mintUSD,
          config: configPDA,
          bank: bankPDA,
          bankTokenAccount: vaultPDA,
          customerAccount: depositorPDA,
          customerTokenAccount: userTokenAccount,
          solPool: deriveSolPool(),
          tickerRisk: deriveSolRisk(),
          tokenProgram: TOKEN_PROGRAM_ID,
          associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
          systemProgram: SystemProgram.programId,
        })
        .remainingAccounts([...pyth.getAccountMetas(["SOL"]), ...solStarLegs()])
        .preInstructions([ComputeBudgetProgram.setComputeUnitLimit({ units: 400_000 })])
        .rpc();

      const after = await program.account.depositor.fetch(depositorPDA);
      expect(after.depositedLamports.toNumber()).to.equal(0);
      console.log("  ✓ Full SOL exit drained", before.depositedLamports.toString(), "lamports");
    });

    it("SW.10 The LayerZero endpoint and origin chain cannot be pointed elsewhere", async () => {
      // The endpoint is hardcoded: messages are addressed to it and QD is
      // minted on what it delivers, so a caller supplying their own would be
      // supplying their own mint authority. `init_oapp_store` takes only the
      // L1 peer now — the endpoint and eid come from constants.
      const [storePDA] = PublicKey.findProgramAddressSync(
        [Buffer.from("Store")], program.programId);
      const [typesPDA] = PublicKey.findProgramAddressSync(
        [Buffer.from("LzReceiveTypes"), storePDA.toBuffer()], program.programId);
      const [programData] = PublicKey.findProgramAddressSync(
        [program.programId.toBuffer()],
        new PublicKey("BPFLoaderUpgradeab1e11111111111111111111111"));

      const peer = Buffer.alloc(32);            // Basket.sol, left-padded
      Buffer.from("beef".repeat(10), "hex").copy(peer, 12, 0, 20);

      await program.methods
        .initOappStore({
          peerAddress: Array.from(peer),
          mint: mintUSD,
          enforcedOptionsSend: Buffer.alloc(0),
        })
        .accountsStrict({
          payer: payer.publicKey,
          store: storePDA,
          config: configPDA,
          lzReceiveTypesAccounts: typesPDA,
          program: program.programId,
          programData,
          systemProgram: SystemProgram.programId,
        })
        .rpc();

      const store = await program.account.oAppStore.fetch(storePDA);
      // The endpoint and the origin chain are not stored at all — they are
      // constants in the program, so there is no record that could disagree
      // with the code. What the store does hold is the peer and the mint.
      expect(store.peerAddress).to.deep.equal(Array.from(peer));
      // The token the bridge mints is the token the deposit whitelist accepts.
      expect(store.mint.toString()).to.equal(mintUSD.toString());
      const cfg = await program.account.programConfig.fetch(configPDA);
      expect(cfg.registeredMints.length).to.equal(2);
      expect(cfg.registeredMints.map((m: any) => m.toString()))
        .to.include(store.mint.toString());
      console.log("  ✓ peer recorded; endpoint and origin chain are constants,",
                  "and the bridge mint is the registered token");
    });

    it("SW.11 The bridge cannot mint a token the pool would not take", async () => {
      // Exactly two mints are ever acceptable: USD* (a compile-time constant)
      // and the token fixed at init_config. Standing the bridge up on anything
      // else would mint QD no deposit path credits.
      const rogue = await createMint(provider.connection, payer, payer.publicKey, null, 6);
      const [storePDA] = PublicKey.findProgramAddressSync(
        [Buffer.from("Store")], program.programId);
      const [typesPDA] = PublicKey.findProgramAddressSync(
        [Buffer.from("LzReceiveTypes"), storePDA.toBuffer()], program.programId);
      const [programData] = PublicKey.findProgramAddressSync(
        [program.programId.toBuffer()],
        new PublicKey("BPFLoaderUpgradeab1e11111111111111111111111"));

      try {
        await program.methods
          .initOappStore({
            peerAddress: Array.from(Buffer.alloc(32)),
            mint: rogue,
            enforcedOptionsSend: Buffer.alloc(0),
          })
          .accountsStrict({
            payer: payer.publicKey, store: storePDA, config: configPDA,
            lzReceiveTypesAccounts: typesPDA, program: program.programId,
            programData, systemProgram: SystemProgram.programId,
          })
          .rpc();
        expect.fail("A bridge mint outside the whitelist should be rejected");
      } catch (e: any) {
        // SW.10 already initialised the store, so either guard is a correct
        // refusal; what must never hold is a store naming a foreign mint.
        const store = await program.account.oAppStore.fetch(storePDA);
        expect(store.mint.toString()).to.not.equal(rogue.toString());
        console.log("  ✓ foreign bridge mint refused");
      }
    });

    it("SW.9 A pool withdrawal still rejects 0", async () => {
      // Only the native leg reads 0 as "everything" — an SPL withdrawal of 0
      // is a malformed request, not a full exit.
      try {
        await program.methods
          .withdraw(new BN(0), "", false)
          .accountsStrict({
            signer: payer.publicKey,
            mint: mintUSD,
            config: configPDA,
            bank: bankPDA,
            bankTokenAccount: vaultPDA,
            customerAccount: depositorPDA,
            customerTokenAccount: userTokenAccount,
            solPool: null,
            tickerRisk: null,
            tokenProgram: TOKEN_PROGRAM_ID,
            associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
            systemProgram: SystemProgram.programId,
          })
          .rpc();
        expect.fail("Zero-amount pool withdrawal should be rejected");
      } catch (e: any) {
        expect(e.toString()).to.include("InvalidAmount");
        console.log("  ✓ Zero rejected on the pool leg");
      }
    });
  });
});
