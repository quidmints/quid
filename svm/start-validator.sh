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
# ./start-validator.sh
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
echo ""

$VALIDATOR --reset ${PROGRAMS[@]} ${ACCOUNTS[@]}
