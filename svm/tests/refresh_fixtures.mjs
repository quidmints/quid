#!/usr/bin/env node
// Refresh Pyth price feed fixtures from mainnet
//
// Usage:
//   node refresh_fixtures.mjs              # Fetch current prices
//   node refresh_fixtures.mjs --crash      # Also create 50% crashed fixtures (for liquidation tests)
//   node refresh_fixtures.mjs --crash 0.30 # Custom crash ratio (30% of original)

import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

// Pyth accounts for supported collateral assets
const ASSET_ACCOUNTS = {
  XAG: "H9JxsWwtDZxjSL6m7cdCVsWibj3JBMD9sxqLjadoZnot",
  XAU: "2uPQGpm8X4ZkxMHxrAW1QuhXcse1AHEgPih6Xp9NuEWW",
  BTC: "4cSM2e6rvbGQUFiJbqytoVMi5GgghSMr8LwVrT9VPSPo",
  ETH: "42amVS4KgzR9rA28tkVYqVXjq9Qa8dcZQMbH5EYFX6XC",
  SOL: "7UVimffxr9ow1uXYxsr4LHAcV58mLzhmwaeKvJ1pjLiE",
};

// Pyth receiver program (needed for price verification)
const PYTH_RECEIVER = "rec5EKMGg6MxZYaMdyBfgwp4d5rB9T1VQH5pJv5LtFJ";

// Pyth account data offsets (from fetch_price in etc.rs)
const PRICE_OFFSET = 73;        // i64 price
const EXPONENT_OFFSET = 89;     // i32 exponent
const PUBLISH_TIME_OFFSET = 93; // i64 publish_time

const RPC_URL = process.env.HELIUS_RPC || "https://api.mainnet-beta.solana.com";

async function fetchAccount(addr) {
  const resp = await fetch(RPC_URL, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      jsonrpc: "2.0",
      id: 1,
      method: "getAccountInfo",
      params: [addr, { encoding: "base64" }],
    }),
  });

  const json = JSON.parse(await resp.text());
  const value = json.result?.value;
  if (!value) return null;

  return {
    pubkey: addr,
    account: {
      lamports: value.lamports,
      data: value.data,
      owner: value.owner,
      executable: value.executable,
      rentEpoch: 0,
    },
  };
}

function crashFixture(fixture, ratio) {
  const clone = JSON.parse(JSON.stringify(fixture));
  const data = Buffer.from(clone.account.data[0], "base64");

  const originalPrice = data.readBigInt64LE(PRICE_OFFSET);
  const exponent = data.readInt32LE(EXPONENT_OFFSET);
  const newPrice = BigInt(Math.round(Number(originalPrice) * ratio));

  data.writeBigInt64LE(newPrice, PRICE_OFFSET);
  data.writeBigInt64LE(BigInt(Math.floor(Date.now() / 1000)), PUBLISH_TIME_OFFSET);
  clone.account.data[0] = data.toString("base64");

  return {
    fixture: clone,
    originalUsd: Number(originalPrice) * Math.pow(10, exponent),
    newUsd: Number(newPrice) * Math.pow(10, exponent),
  };
}

async function main() {
  const args = process.argv.slice(2);
  const doCrash = args.includes("--crash");

  let crashRatio = 0.50;
  const idx = args.indexOf("--crash");
  if (idx !== -1 && args[idx + 1] && !args[idx + 1].startsWith("-")) {
    crashRatio = parseFloat(args[idx + 1]);
    if (isNaN(crashRatio) || crashRatio <= 0 || crashRatio >= 1) {
      console.error("Crash ratio must be between 0 and 1 (e.g. 0.50 for 50%)");
      process.exit(1);
    }
  }

  const fixturesDir = path.join(__dirname, "../tests/fixtures");
  fs.mkdirSync(fixturesDir, { recursive: true });

  console.log(`RPC: ${RPC_URL}\n`);

  for (const [ticker, addr] of Object.entries(ASSET_ACCOUNTS)) {
    process.stdout.write(`${ticker} (${addr.slice(0, 12)}...) `);
    try {
      const fixture = await fetchAccount(addr);
      if (!fixture) { console.log("✗ not found"); continue; }

      const filePath = path.join(fixturesDir, `${addr}.json`);
      fs.writeFileSync(filePath, JSON.stringify(fixture, null, 2));
      console.log(`✓ ${fs.statSync(filePath).size}b`);

      if (doCrash) {
        const { fixture: crashed, originalUsd, newUsd } = crashFixture(fixture, crashRatio);
        fs.writeFileSync(path.join(fixturesDir, `${addr}_CRASHED.json`), JSON.stringify(crashed, null, 2));
        console.log(`  ↳ CRASHED: $${originalUsd.toFixed(2)} → $${newUsd.toFixed(2)}`);
      }
    } catch (e) {
      console.log(`✗ ${e.message}`);
    }
  }

  process.stdout.write(`\nPyth Receiver (${PYTH_RECEIVER.slice(0, 12)}...) `);
  try {
    const fixture = await fetchAccount(PYTH_RECEIVER);
    if (fixture) {
      fs.writeFileSync(path.join(fixturesDir, `${PYTH_RECEIVER}.json`), JSON.stringify(fixture, null, 2));
      console.log("✓");
    } else { console.log("✗ not found"); }
  } catch (e) { console.log(`✗ ${e.message}`); }

  console.log(`\nFixtures → ${fixturesDir}`);
  if (doCrash) {
    console.log(`Crashed at ${(crashRatio * 100).toFixed(0)}% of spot (for liquidation tests)`);
    console.log(`\n  ./start-validator.sh --crash`);
  } else {
    console.log(`\nFor liquidation test fixtures: node refresh_fixtures.mjs --crash`);
  }
}

main().catch(console.error);
