/**
 * lz-config.ts — bind the message libraries and require two DVNs, Solana side.
 *
 * The mirror of `evm/scripts/LZconfig.s.sol`, and it exists for the same
 * reason. KelpDAO's rsETH adapter was deployed with one required DVN on its
 * Unichain path; a single compromised verifier signed a forged message and
 * 116,500 rsETH left. Nothing in the contract was wrong. The configuration was.
 *
 * Two things have to happen, in order, and the second is worthless without the
 * first:
 *
 *   1. Bind the send and receive libraries for the pathway. Until an OApp does
 *      this it runs on the endpoint's defaults, and a config written to a
 *      library the pathway never selected changes nothing at all — which is
 *      how an integration ends up looking configured while still on 1-of-1.
 *   2. Set the ULN config on both directions with `requiredDvnCount = 2`.
 *
 * Run:
 *   ANCHOR_PROVIDER_URL=https://api.devnet.solana.com \
 *   ANCHOR_WALLET=~/.config/solana/id.json \
 *   npx tsx scripts/lz-config.ts
 *
 * Env:
 *   EID          destination endpoint id (default 30101, Ethereum mainnet)
 *   DVN_A/DVN_B  override the two required verifiers
 */
import { Connection, Keypair, PublicKey, sendAndConfirmTransaction,
         Transaction } from "@solana/web3.js";
import { EndpointProgram, SetConfigType, UlnProgram } from "@layerzerolabs/lz-solana-sdk-v2";
import { readFileSync } from "fs";
import { homedir } from "os";

/** Shared across every LayerZero token on Solana — see LZ.rs. */
const ENDPOINT = new PublicKey("76y77prsiCMvXMjuoZ5VRrhG5qYBrUMYTE5WgHqgjEn6");
const SEND_ULN = new PublicKey("7a4WjyR8VZ7yZz5XJAKm39BUGn5iT9CKcv2pmG9tdXVH");
const RECV_ULN = SEND_ULN;              // ULN302 serves both directions

/**
 * Two verifiers from different operators. Mirrors the EVM pair, and the point
 * is the independence rather than the identity: one compromise must not be
 * enough. Both are live on Solana mainnet per LayerZero's own metadata.
 */
const DVN_A = new PublicKey(process.env.DVN_A ??
  "4VDjp6XQaxoZf5RGwiPU9NR1EXSZn2TP4ATMmiSzLfhb");   // LayerZero Labs
const DVN_B = new PublicKey(process.env.DVN_B ??
  "F7gu9kLcpn4bSTZn183mhn2RXUuMy7zckdxJZdUjuALw");   // Google Cloud

/** Explicit, not zero. Zero means "whatever the library default is". */
const CONFIRMATIONS = 15;

const PROGRAM_ID = new PublicKey("QDgHUZjtccRjKZ63MBvW8uzKR7qcqjpRfGhNSEGfDu9");
const DST_EID = Number(process.env.EID ?? 30101);

async function main() {
  const url = process.env.ANCHOR_PROVIDER_URL ?? "http://127.0.0.1:8899";
  const conn = new Connection(url, "confirmed");
  const wallet = Keypair.fromSecretKey(Uint8Array.from(JSON.parse(
    readFileSync((process.env.ANCHOR_WALLET ?? `${homedir()}/.config/solana/id.json`)
      .replace("~", homedir()), "utf8"))));

  // The OApp is this program's Store PDA — the endpoint knows an OApp by the
  // account that signs for it, not by the program.
  const [store] = PublicKey.findProgramAddressSync(
    [Buffer.from("Store")], PROGRAM_ID);

  const endpoint = new EndpointProgram.Endpoint(ENDPOINT);
  const uln = {
    confirmations: CONFIRMATIONS,
    requiredDvnCount: 2,
    optionalDvnCount: 0,
    optionalDvnThreshold: 0,
    requiredDvns: [DVN_A, DVN_B].sort((a, b) => a.toBuffer().compare(b.toBuffer())),
    optionalDvns: [],
  };

  console.log(`endpoint ${ENDPOINT}\noapp     ${store}\neid      ${DST_EID}`);
  console.log(`DVNs     ${uln.requiredDvns.join("\n         ")}`);

  // 1. Bind the libraries. Without this the rest is decoration.
  for (const [what, lib] of [["send", SEND_ULN], ["receive", RECV_ULN]] as const) {
    const ix = what === "send"
      ? await endpoint.setSendLibrary(wallet.publicKey, store, lib as PublicKey, DST_EID)
      : await endpoint.setReceiveLibrary(wallet.publicKey, store, lib as PublicKey, DST_EID, 0);
    await sendAndConfirmTransaction(conn, new Transaction().add(ix), [wallet]);
    console.log(`  ✓ ${what} library bound to ${lib}`);
  }

  // 2. Require both verifiers, in both directions.
  for (const [what, type] of [["send", SetConfigType.SEND_ULN],
                              ["receive", SetConfigType.RECEIVE_ULN]] as const) {
    // The SDK bundles its own web3.js, so the Connection types are nominally
    // distinct even though they are the same class at runtime.
    const ix = await endpoint.setOappConfig(conn as any, wallet.publicKey, store,
      SEND_ULN, DST_EID, { configType: type, value: uln } as any);
    await sendAndConfirmTransaction(conn, new Transaction().add(ix), [wallet]);
    console.log(`  ✓ ${what} requires ${uln.requiredDvnCount} of ${uln.requiredDvns.length} DVNs`);
  }

  console.log("\nConfigured. Verify with getSendConfigState / getReceiveConfigState");
  console.log("before trusting it — a silent default is exactly the failure mode.");
}

main().catch(e => { console.error(e); process.exit(1); });
