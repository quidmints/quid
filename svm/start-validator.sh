#!/bin/bash
# len=$(forge inspect src/Basket.sol:Basket deployedBytecode | sed 's/^0x//' | tr -d '\n' | wc -c) echo $((len/2))
# len=$(forge inspect src/Basket.sol:Basket bytecode | sed 's/^0x//' | tr -d '\n' | wc -c) echo $((len/2))  # bytes

# mkdir ~/.local/share/solana/install/releases/
# cd ~/.local/share/solana/install/releases/
# curl -L --retry 5  https://github.com/anza-xyz/agave/releases/download/v3.1.3/solana-release-x86_64-unknown-linux-gnu.tar.bz2 -o solana.tar.bz2
# tar -xjf solana.tar.bz2
# ln -sfn ~/.local/share/solana/install/releases/solana-release ~/.local/share/solana/install/active_release

# from the project root (Anchor directory)
# cargo-build-sbf --force-tools-install

# =============================================================================
# QUICKSTART
# =============================================================================
#
# Terminal 1 - Start validator
# yarn refresh                  # fetch fresh Pyth fixtures
# chmod +x start-validator.sh   # first time only
# ./start-validator.sh          # fixture mode: reproducible, offline, fast
# ./start-validator.sh --fork   # clone live mainnet state instead
#
# The two are complementary, not alternatives.
#
# Fixture mode replays dumps in tests/fixtures. It is deterministic and works
# offline, and it can mint balances for tokens whose real authority we do not
# hold — USD* is minted at its true address with a local authority, which is
# the only way the second-vault path gets exercised at all.
#
# Fork mode clones from mainnet at genesis: real programs, real balances, real
# oracle ages. It is the only mode where the parts that depend on somebody
# else's live state are genuinely tested — Kestrel caches a price inside its
# own account and rejects one it considers stale, so a dump can arrive already
# past their bound while a clone never does. What it cannot do is mint a token
# it does not control, so the USD* leg skips there and runs under fixtures.
#
# Terminal 2 - Run tests
# 1. Build (generates new keypair if first time)
# anchor build -- --features testing
#
# 2. Get the new program ID
# anchor keys list
#
# 3. Copy that ID and update lib.rs:
#    declare_id!("NEW_PROGRAM_ID_HERE");
#
# 4. Also update Anchor.toml [programs.localnet] section
#
# 5. Rebuild with correct ID
# anchor build -- --features testing
# anchor test --skip-build --skip-local-validator
#
# =============================================================================
# FRONTEND REQUIREMENTS
# =============================================================================
#
# The frontend needs more than just the program ID:
#
#   1. Program ID                → SOLANA_PROGRAMS.quid in chains.ts
#   2. IDL JSON                  → src/idl/quid.json (from anchor build)
#   3. Solana RPC URL            → getSolanaRpcUrl() in chains.ts
#   4. Phantom wallet            → Browser extension
#
# There is no keeper endpoint and no co-signing: every instruction here is
# either permissionless or signed by the user alone. The band is enforced on
# chain, so nothing is gained by gating a client.

# needed to build the validator from source due to old processor
VALIDATOR=~/Documents/agave/target/release/solana-test-validator
FIXTURES=tests/fixtures

# ─── Pyth price feed accounts ────────────────────────────────────────────────
# Asset Pyth accounts (for liquidation testing)
XAG_PYTH="H9JxsWwtDZxjSL6m7cdCVsWibj3JBMD9sxqLjadoZnot"
XAU_PYTH="2uPQGpm8X4ZkxMHxrAW1QuhXcse1AHEgPih6Xp9NuEWW"
BTC_PYTH="4cSM2e6rvbGQUFiJbqytoVMi5GgghSMr8LwVrT9VPSPo"
ETH_PYTH="42amVS4KgzR9rA28tkVYqVXjq9Qa8dcZQMbH5EYFX6XC"
SOL_PYTH="7UVimffxr9ow1uXYxsr4LHAcV58mLzhmwaeKvJ1pjLiE"
PYTH_RECEIVER="rec5EKMGg6MxZYaMdyBfgwp4d5rB9T1VQH5pJv5LtFJ"

# Stablecoin Pyth accounts (for depeg testing)
USDC_PYTH="Dpw1EAVrSB1ibxiDQyTAW6Zip3J4Btk2x4SgApQCeFbX"
USDT_PYTH="HT2PLQBcG5EiCcNSaMHAjSgd9F98ecpATbk4Sk5oYuM"
DAI_PYTH="FmfrxJ7YH8yVxoYpJ9ZDMeb8gUceYXYaSrQiBJ1uSZjN"
PYUSD_PYTH="9zXQxpYH3kYhtoybmZfUNNCRVuud7fY9jswTg1hLyT8k"

# LayerZero V2 Endpoint, dumped from mainnet with
#   solana -u m program dump 76y77prsiCMvXMjuoZ5VRrhG5qYBrUMYTE5WgHqgjEn6 \
#          tests/fixtures/lz_endpoint.so
# Loaded at its real address so the bridge is exercised against the actual
# program rather than a stand-in — the same trick as the Pyth feeds below.
LZ_ENDPOINT="76y77prsiCMvXMjuoZ5VRrhG5qYBrUMYTE5WgHqgjEn6"

# Build account arguments - only add files that exist
ACCOUNTS=()
PROGRAMS=()

# Kestrel `long_yield_carry`, the SOL* issuer. Program plus the three live
# accounts a mint/burn touches: the SOL market Token PDA, its wSOL collateral
# vault, and the SOL* mint itself. Same approach as the Pyth feeds — real
# program, real state, so the CPI is exercised rather than mocked.
KESTREL="LYC8YiiSzQfPpxUW2tpxfuPKGZwywAJhXKUfDP2B66f"
SOL_STAR_MINT="FDhu9642aPYNnbTnSoHdAsR9tgSxftPDPjEVdbD58nP2"
KESTREL_TOKEN="6MSD4oSiJq8y5hmryCuMykyTjNXbhha6HSAtrT1EFKQe"
KESTREL_VAULT="DHxRiKmKZn8eEUsqJrwSpHcmMthLXEbsLfYDZMHBKP9B"
WSOL_MINT="So11111111111111111111111111111111111111112"

if [ -f "$FIXTURES/kestrel.so" ]; then
  PROGRAMS+=("--bpf-program $KESTREL $FIXTURES/kestrel.so")
else
  echo "  ⚠ Skipping Kestrel (fixture not found)"
fi

if [ -f "$FIXTURES/lz_endpoint.so" ]; then
  PROGRAMS+=("--bpf-program $LZ_ENDPOINT $FIXTURES/lz_endpoint.so")
else
  echo "  ⚠ Skipping LayerZero endpoint (fixture not found)"
fi

# Helper function to add account if fixture exists
add_if_exists() {
  local addr=$1
  local file=$2
  if [ -f "$file" ]; then
    ACCOUNTS+=("--account $addr $file")
    return 0
  else
    echo "  ⚠ Skipping $addr (fixture not found)"
    return 1
  fi
}

# Load normal asset fixtures
add_if_exists "$XAG_PYTH" "$FIXTURES/${XAG_PYTH}.json"
add_if_exists "$XAU_PYTH" "$FIXTURES/${XAU_PYTH}.json"
add_if_exists "$BTC_PYTH" "$FIXTURES/${BTC_PYTH}.json"
add_if_exists "$ETH_PYTH" "$FIXTURES/${ETH_PYTH}.json"
add_if_exists "$SOL_PYTH" "$FIXTURES/${SOL_PYTH}.json"

# Load normal stablecoin fixtures
add_if_exists "$USDC_PYTH" "$FIXTURES/${USDC_PYTH}.json"
add_if_exists "$USDT_PYTH" "$FIXTURES/${USDT_PYTH}.json"
add_if_exists "$DAI_PYTH" "$FIXTURES/${DAI_PYTH}.json"
add_if_exists "$PYUSD_PYTH" "$FIXTURES/${PYUSD_PYTH}.json"

# Kestrel's live state: the SOL market Token PDA, its wSOL collateral vault,
# and the SOL* mint. These have to come after add_if_exists is defined.
add_if_exists "$SOL_STAR_MINT" "$FIXTURES/${SOL_STAR_MINT}.json"
add_if_exists "$KESTREL_TOKEN" "$FIXTURES/${KESTREL_TOKEN}.json"
add_if_exists "$KESTREL_VAULT" "$FIXTURES/${KESTREL_VAULT}.json"
add_if_exists "$WSOL_MINT"     "$FIXTURES/${WSOL_MINT}.json"

# Always load Pyth receiver program
add_if_exists "$PYTH_RECEIVER" "$FIXTURES/${PYTH_RECEIVER}.json"

# Create funded payer account fixture
PAYER_PUBKEY=$(solana-keygen pubkey ~/.config/solana/id.json 2>/dev/null)
if [ -n "$PAYER_PUBKEY" ]; then
  echo ""
  echo "Funding payer: $PAYER_PUBKEY"
  echo "{\"pubkey\":\"$PAYER_PUBKEY\",\"account\":{\"lamports\":100000000000,\"data\":[\"\",\"base64\"],\"owner\":\"11111111111111111111111111111111\",\"executable\":false,\"rentEpoch\":0}}" > "$FIXTURES/payer.json"
  ACCOUNTS+=("--account $PAYER_PUBKEY $FIXTURES/payer.json")
fi

# USD* — the second registered mint, and a compile-time constant in the
# program, so it has to exist at exactly that address to be exercised at all.
# Its real authority is Perena's, which we do not hold, so the fixture is an
# SPL mint at the right address with the local payer as authority: enough to
# mint test balances and prove the two-vault pro-rata payout, without
# pretending to be the real token.
USD_STAR="star9agSpjiFe3M49B3RniVU4CMBBEK3Qnaqn3RGiFM"
if [ -n "$PAYER_PUBKEY" ]; then
  node -e '
    const [addr, auth] = process.argv.slice(1);
    const bs58 = (s) => { const A="123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
      let n=0n; for (const c of s) n = n*58n + BigInt(A.indexOf(c));
      const b=[]; while(n>0n){ b.unshift(Number(n & 255n)); n >>= 8n; }
      while(b.length<32) b.unshift(0); return Buffer.from(b); };
    const d = Buffer.alloc(82);
    d.writeUInt32LE(1, 0);                 // mint authority present
    bs58(auth).copy(d, 4);                 // ... and it is the payer
    d.writeUInt8(6, 44);                   // decimals, as USD* has
    d.writeUInt8(1, 45);                   // initialized
    process.stdout.write(JSON.stringify({ pubkey: addr, account: {
      lamports: 1461600, data: [d.toString("base64"), "base64"],
      owner: "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA",
      executable: false, rentEpoch: 0 }}));
  ' "$USD_STAR" "$PAYER_PUBKEY" > "$FIXTURES/usd_star.json"
  ACCOUNTS+=("--account $USD_STAR $FIXTURES/usd_star.json")
fi

echo ""
echo "Starting validator with ${#ACCOUNTS[@]} fixture accounts, ${#PROGRAMS[@]} extra programs..."
echo ""

# ── Fork mode ────────────────────────────────────────────────────────────────
# `./start-validator.sh --fork` clones the accounts and programs from live
# mainnet instead of replaying the dumps in tests/fixtures.
#
# The dumps are reproducible and fast, which is what a suite wants, but they
# are a photograph: Kestrel caches a price inside its own state and rejects one
# it considers stale, so a fixture can arrive already past their bound, and no
# amount of local care makes an old snapshot current. Cloning fetches whatever
# mainnet holds right now — real balances, real oracle ages, real program
# versions — which is the only way the parts of this that depend on somebody
# else's live state get exercised at all.
if [ "$1" = "--fork" ]; then
  MAINNET="${FORK_URL:-https://api.mainnet-beta.solana.com}"
  echo ""
  echo "Forking mainnet state from $MAINNET"

  CLONE=()
  # Upgradeable programs need their data account cloned too, which the plain
  # --clone does not do.
  for p in "$PYTH_RECEIVER" "$KESTREL" "$LZ_ENDPOINT" \
           7a4WjyR8VZ7yZz5XJAKm39BUGn5iT9CKcv2pmG9tdXVH \
           HtEYV4xB4wvsj5fgTkcfuChYpvGYzgzwvNhgDZQNh7wW \
           6doghB248px58JSSwG4qejQ46kFMW4AMj7vzJnWZHNZn; do
    CLONE+=(--clone-upgradeable-program "$p")
  done

  # The endpoint's own state, and the ULN's. Without these the endpoint
  # program is loaded but inert: `register_oapp` and `clear` both read them,
  # so cloning the code alone tests nothing about the CPIs that matter.
  CLONE+=(--clone 2uk9pQh3tB5ErV7LGQJcbWjb4KeJ2UJki5qJZ8QG56G3)   # Endpoint settings
  CLONE+=(--clone 2XgGZG4oP29U3w5h4nTk1V2LFHL23zKDPJjs3psGzLKQ)   # ULN302 message lib

  # Live accounts: every price feed the suite reads, Kestrel's market state and
  # its collateral vault, and the two mints.
  for a in "$XAG_PYTH" "$XAU_PYTH" "$BTC_PYTH" "$ETH_PYTH" "$SOL_PYTH" \
           "$USDC_PYTH" "$USDT_PYTH" "$PYUSD_PYTH" \
           "$SOL_STAR_MINT" "$KESTREL_TOKEN" "$KESTREL_VAULT" "$WSOL_MINT"; do
    CLONE+=(--clone "$a")
  done

  # The payer still has to be funded locally — mainnet does not know it.
  exec $VALIDATOR --reset --url "$MAINNET" "${CLONE[@]}" \
       --account "$PAYER_PUBKEY" "$FIXTURES/payer.json"
fi

$VALIDATOR --reset ${PROGRAMS[@]} ${ACCOUNTS[@]}
