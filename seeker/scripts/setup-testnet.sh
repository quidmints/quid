#!/usr/bin/env bash
# scripts/setup-testnet.sh
#
# Creates a mock QUID token on Solana testnet using spl-token-cli,
# mints tokens to your wallet, then prints the mint address for .env.
#
# Prerequisites:
#   - solana-cli configured for testnet: solana config set --url testnet
#   - spl-token-cli installed: cargo install spl-token-cli
#   - A funded testnet wallet (request airdrop below if needed)
#   - ts-node installed: npm install -g ts-node typescript
#
# Usage:
#   bash scripts/setup-testnet.sh
#
# After this script completes:
#   1. Copy the printed MOCK_QUID_MINT address into your .env file
#   2. Run: npm run init-config
#   3. Restart Expo

set -euo pipefail

CLUSTER="testnet"
DECIMALS=6
MINT_AMOUNT=10000000   # 10 million QD (with 6 decimal places = 10_000_000_000_000 raw)

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  QU!D testnet mock token setup"
echo "═══════════════════════════════════════════════════════"
echo ""

# 1. Confirm cluster
CURRENT_CLUSTER=$(solana config get | grep "RPC URL" | awk '{print $NF}')
echo "→ Current RPC: $CURRENT_CLUSTER"
if [[ "$CURRENT_CLUSTER" != *"testnet"* ]]; then
  echo "  WARNING: Cluster does not look like testnet."
  echo "  Run: solana config set --url testnet"
  read -p "  Continue anyway? [y/N] " yn
  [[ "$yn" != "y" ]] && exit 1
fi

# 2. Get wallet address
WALLET=$(solana address)
echo "→ Wallet: $WALLET"

# 3. Check balance — airdrop if low
BALANCE=$(solana balance "$WALLET" | awk '{print $1}')
echo "→ Balance: $BALANCE SOL"
if (( $(echo "$BALANCE < 1" | bc -l) )); then
  echo "  Requesting airdrop (2 SOL)..."
  solana airdrop 2 "$WALLET" --url testnet || echo "  Airdrop may be rate-limited — fund manually if needed"
fi

# 4. Create token mint (6 decimals, authority = wallet)
echo ""
echo "→ Creating mock QUID token (6 decimals)..."
MINT=$(spl-token create-token \
  --decimals "$DECIMALS" \
  --url "$CLUSTER" \
  2>&1 | grep "Creating token" | awk '{print $3}')

if [[ -z "$MINT" ]]; then
  echo "  ERROR: Could not parse mint address from spl-token output."
  echo "  Run manually: spl-token create-token --decimals 6 --url testnet"
  exit 1
fi

echo "  ✓ Mint: $MINT"

# 5. Create associated token account for wallet
echo "→ Creating token account..."
spl-token create-account "$MINT" --url "$CLUSTER" > /dev/null

# 6. Mint tokens to wallet
echo "→ Minting $MINT_AMOUNT QD to wallet..."
spl-token mint "$MINT" "$MINT_AMOUNT" --url "$CLUSTER" > /dev/null
echo "  ✓ Minted"

# 7. Verify
BALANCE_QD=$(spl-token balance "$MINT" --url "$CLUSTER")
echo "  ✓ Token balance: $BALANCE_QD"

# 8. Write .env if it doesn't exist yet
if [[ ! -f ".env" ]]; then
  cp .env.example .env
  echo "  Created .env from .env.example"
fi

# Update EXPO_PUBLIC_MOCK_QUID_MINT in .env
if grep -q "EXPO_PUBLIC_MOCK_QUID_MINT" .env; then
  sed -i.bak "s|EXPO_PUBLIC_MOCK_QUID_MINT=.*|EXPO_PUBLIC_MOCK_QUID_MINT=$MINT|" .env
  rm -f .env.bak
  echo "  ✓ Updated .env EXPO_PUBLIC_MOCK_QUID_MINT=$MINT"
else
  echo "EXPO_PUBLIC_MOCK_QUID_MINT=$MINT" >> .env
  echo "  ✓ Appended EXPO_PUBLIC_MOCK_QUID_MINT to .env"
fi

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  Mock token ready!"
echo ""
echo "  MOCK_QUID_MINT = $MINT"
echo ""
echo "  Next steps:"
echo "  1. Make sure .env has EXPO_PUBLIC_SOLANA_RPC=https://api.testnet.solana.com"
echo "  2. Deploy the program to testnet: anchor deploy --provider.cluster testnet"
echo "  3. Initialize on-chain config: npm run init-config"
echo "  4. Start the app: npm start"
echo "═══════════════════════════════════════════════════════"
echo ""
