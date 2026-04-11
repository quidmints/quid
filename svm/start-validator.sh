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
# ./start-validator.sh          # normal mode (testCreateMarket, no SB needed)
# ./start-validator.sh --sb     # with Switchboard (requires one-time dump, see below)
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
# SWITCHBOARD SETUP (one-time)
# =============================================================================
#
# The real create_market path requires Switchboard on-demand deployed on localnet.
# Without it, tests use testCreateMarket (gated behind #[cfg(feature = "testing")]).
#
# To enable real Switchboard:
#
#   1. Dump the program binary from mainnet:
#      solana program dump \
#        SBondMDrcV3K4kxZR1HNVT7osZxAHVHgYXL5Ze1oMUv \
#        tests/fixtures/sb_on_demand.so \
#        -u mainnet-beta
#
#   2. Dump a queue account (the mainnet default queue):
#      solana account \
#        A43DyUGA7s8eXPxqEjJY6EBGz8EztrzDN9YJ5M1jRzgk \
#        --output json-compact \
#        -u mainnet-beta \
#        -o tests/fixtures/sb_queue.json
#
#   3. Run with --sb flag:
#      ./start-validator.sh --sb
#
#   4. In tests, set SB_QUEUE env var:
#      SB_QUEUE=A43DyUGA7s8eXPxqEjJY6EBGz8EztrzDN9YJ5M1jRzgk \
#        anchor test --skip-build --skip-local-validator
#
# NOTE: Even with the SB program deployed, creating real feed VALUES requires
# either a running oracle (docker) or using the crossbar simulator. Without
# oracle data, PullFeed.get_value() returns an error. For localnet testing,
# the testCreateMarket path remains the practical default.
#
# The real SB path is designed for:
#   - Devnet testing (oracles already running)
#   - Integration testing with the keeper service
#   - Pre-mainnet staging
#
# =============================================================================
# FRONTEND REQUIREMENTS
# =============================================================================
#
# The frontend (page.tsx) needs more than just the program ID:
#
#   1. SAFTA program ID          → SOLANA_PROGRAMS.safta in chains.ts
#   2. IDL JSON                  → src/idl/quid.json (from anchor build)
#   3. Solana RPC URL            → getSolanaRpcUrl() in chains.ts
#   4. Keeper API                → /api/safta/feeds (creates SB feeds, returns pubkeys)
#                                  /api/safta/evidence-config (resolves tag→classifier hashes)
#   5. Phantom wallet            → Browser extension
#
# The keeper API is the bridge between frontend and Switchboard. It:
#   - Receives question/context/exculpatory/outcomes from frontend
#   - Creates validation + resolution PullFeed accounts via SB SDK
#   - Triggers the oracle to evaluate the question
#   - Returns feed pubkeys after oracle writes APPROVED + score
#   - Frontend passes these as remaining_accounts to createMarket
#
# For localnet dev without the keeper, use testCreateMarket directly.

# needed to build the validator from source due to old processor
VALIDATOR=~/Documents/agave/target/release/solana-test-validator
FIXTURES=tests/fixtures

# ─── Switchboard On-Demand ───────────────────────────────────────────────────
SB_PROGRAM_ID="SBondMDrcV3K4kxZR1HNVT7osZxAHVHgYXL5Ze1oMUv"
SB_PROGRAM_SO="$FIXTURES/sb_on_demand.so"
SB_QUEUE_PUBKEY="A43DyUGA7s8eXPxqEjJY6EBGz8EztrzDN9YJ5M1jRzgk"
SB_QUEUE_JSON="$FIXTURES/sb_queue.json"

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

# Build account arguments - only add files that exist
ACCOUNTS=()
PROGRAMS=()

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

# Always load Pyth receiver program
add_if_exists "$PYTH_RECEIVER" "$FIXTURES/${PYTH_RECEIVER}.json"

# ─── Switchboard loading (--sb flag) ─────────────────────────────────────────
SB_ENABLED=false
for arg in "$@"; do
  if [ "$arg" = "--sb" ]; then
    SB_ENABLED=true
  fi
done

if [ "$SB_ENABLED" = true ]; then
  echo ""
  echo "─── Switchboard On-Demand ───"

  if [ -f "$SB_PROGRAM_SO" ]; then
    PROGRAMS+=("--bpf-program $SB_PROGRAM_ID $SB_PROGRAM_SO")
    echo "  ✓ SB program: $SB_PROGRAM_ID"
  else
    echo "  ✗ SB program .so not found at $SB_PROGRAM_SO"
    echo "    Run: solana program dump $SB_PROGRAM_ID $SB_PROGRAM_SO -u mainnet-beta"
    echo "    Continuing without Switchboard..."
    SB_ENABLED=false
  fi

  if [ "$SB_ENABLED" = true ] && [ -f "$SB_QUEUE_JSON" ]; then
    ACCOUNTS+=("--account $SB_QUEUE_PUBKEY $SB_QUEUE_JSON")
    echo "  ✓ SB queue: $SB_QUEUE_PUBKEY"
  elif [ "$SB_ENABLED" = true ]; then
    echo "  ⚠ SB queue fixture not found at $SB_QUEUE_JSON"
    echo "    Run: solana account $SB_QUEUE_PUBKEY --output json-compact -u mainnet-beta -o $SB_QUEUE_JSON"
    echo "    Feeds can still be created but may fail without a valid queue."
  fi

  if [ "$SB_ENABLED" = true ]; then
    echo ""
    echo "  To run tests with real SB:"
    echo "    SB_QUEUE=$SB_QUEUE_PUBKEY anchor test --skip-build --skip-local-validator"
    echo ""
    echo "  NOTE: Feed values still require a running oracle or crossbar simulator."
    echo "  Without oracle data, create_market falls back to testCreateMarket."
  fi
fi

# Create funded payer account fixture
PAYER_PUBKEY=$(solana-keygen pubkey ~/.config/solana/id.json 2>/dev/null)
if [ -n "$PAYER_PUBKEY" ]; then
  echo ""
  echo "Funding payer: $PAYER_PUBKEY"
  echo "{\"pubkey\":\"$PAYER_PUBKEY\",\"account\":{\"lamports\":100000000000,\"data\":[\"\",\"base64\"],\"owner\":\"11111111111111111111111111111111\",\"executable\":false,\"rentEpoch\":0}}" > "$FIXTURES/payer.json"
  ACCOUNTS+=("--account $PAYER_PUBKEY $FIXTURES/payer.json")
fi

echo ""
echo "Starting validator with ${#ACCOUNTS[@]} fixture accounts, ${#PROGRAMS[@]} extra programs..."
if [ "$SB_ENABLED" = true ]; then
  echo "  (Switchboard ON)"
else
  echo "  (Switchboard OFF — using testCreateMarket)"
fi
echo ""

$VALIDATOR --reset ${PROGRAMS[@]} ${ACCOUNTS[@]}
