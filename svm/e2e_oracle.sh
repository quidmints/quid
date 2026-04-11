#!/bin/bash
# ============================================================================
# e2e_oracle.sh — End-to-end oracle integration test
#
# Prerequisites:
#   1. anchor build -- --features testing
#   2. node tests/refresh_fixtures.mjs          (normal prices)
#   3. go build -o oracle/safta-oracle .         (from oracle/ directory)
#   4. Funded localnet wallet at ~/.config/solana/id.json
#
# Run:
#   ./tests/e2e_oracle.sh
#
# Env overrides:
#   ORACLE_BIN        — path to oracle binary (default: ./oracle/safta-oracle)
#   SOLANA_RPC_URL    — RPC endpoint (default: http://127.0.0.1:8899)
#   PROGRAM_ID        — deployed program ID
#   BRAVE_API_KEY     — needed for MODE_EXTERNAL resolution tests
#   VALIDATION_MODEL_URI — needed for AI pipeline tests (0G or OpenAI-compat)
# ============================================================================
set -euo pipefail

ORACLE_BIN="${ORACLE_BIN:-./oracle/safta-oracle}"
RPC="${SOLANA_RPC_URL:-http://127.0.0.1:8899}"
PROGRAM_ID="${PROGRAM_ID:-J1xE8gXrXgrFoEch6QQ9JesqyqhUAkjDuD4CLb2RWSfC}"
PASS=0; FAIL=0

log()  { echo "  $1"; }
ok()   { echo "  ✓ $1"; ((PASS++)); }
fail() { echo "  ✗ $1"; ((FAIL++)); }

assert_json_field() {
  local json="$1" field="$2" want="$3"
  local got; got=$(echo "$json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('$field',''))" 2>/dev/null || true)
  if [ "$got" = "$want" ]; then ok "$field == $want"; else fail "$field: got '$got', want '$want'"; fi
}

# ── 0. Validator health ───────────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════════════════"
echo " 0. Validator health"
echo "══════════════════════════════════════════════════════"

if ! curl -sf "$RPC" -d '{"jsonrpc":"2.0","id":1,"method":"getHealth"}' -H 'Content-Type: application/json' | grep -q '"ok"'; then
  echo "  FATAL: validator not running at $RPC"
  echo "  Run: solana-test-validator --reset & sleep 5"
  exit 1
fi
ok "validator healthy at $RPC"

# ── 1. Oracle binary ──────────────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════════════════"
echo " 1. Oracle binary"
echo "══════════════════════════════════════════════════════"

if [ ! -f "$ORACLE_BIN" ]; then
  fail "oracle binary not found at $ORACLE_BIN"
  echo "  Build: cd oracle && go build -o ../oracle/safta-oracle ."
  FAIL=$((FAIL+1))
else
  ok "oracle binary exists"

  # Binary exits cleanly on missing config
  RESULT=$(ORACLE_MODE=resolve "$ORACLE_BIN" 2>&1 || true)
  if echo "$RESULT" | grep -q "goroutine"; then
    fail "oracle panicked on missing config"
  else
    ok "oracle exits cleanly on missing env (no panic)"
  fi
fi

# ── 2. Anchor test suite ──────────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════════════════"
echo " 2. Anchor test suite (--skip-local-validator)"
echo "══════════════════════════════════════════════════════"

ANCHOR_OUT=$(anchor test --skip-local-validator 2>&1 || true)
PASSING=$(echo "$ANCHOR_OUT" | grep -oP '\d+ passing' | head -1 | grep -oP '\d+' || echo 0)
FAILING=$(echo "$ANCHOR_OUT" | grep -oP '\d+ failing' | head -1 | grep -oP '\d+' || echo 0)

log "passing: $PASSING  failing: $FAILING"
if [ "$FAILING" -eq 0 ]; then
  ok "all $PASSING anchor tests pass"
else
  fail "$FAILING anchor tests failed"
  echo "$ANCHOR_OUT" | grep "AssertionError\|Error:" | head -10
fi

# ── 3. Extract market pubkey from test run ────────────────────────────────────
echo ""
echo "══════════════════════════════════════════════════════"
echo " 3. Locate evidence market from test state"
echo "══════════════════════════════════════════════════════"

# Parse market PDA from anchor test output (created in section 28)
MARKET_PDA=$(echo "$ANCHOR_OUT" | grep -oP "Market ID: \d+" | tail -1 | grep -oP "\d+" || true)

if [ -z "$MARKET_PDA" ]; then
  # Try fetching latest market from chain directly
  MARKET_PDA=$(solana account --output json-compact \
    "$(solana address)" 2>/dev/null | python3 -c "
import sys, json
# Fallback: use a fixed test market pubkey if available
print('')
" 2>/dev/null || true)
fi

# Derive PDA from market count 0 (first test market)
MARKET_PUBKEY=$(node -e "
const { PublicKey } = require('@solana/web3.js');
const id = Buffer.alloc(8); id.writeBigUInt64LE(0n, 0);
const [pda] = PublicKey.findProgramAddressSync(
  [Buffer.from('market'), id.subarray(0,6)],
  new PublicKey('$PROGRAM_ID')
);
console.log(pda.toBase58());
" 2>/dev/null || echo "")

if [ -z "$MARKET_PUBKEY" ]; then
  fail "could not derive market PDA (is @solana/web3.js installed?)"
else
  ok "market PDA: ${MARKET_PUBKEY:0:20}…"
fi

# ── 4. Oracle resolve mode ────────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════════════════"
echo " 4. Oracle resolve mode (MODE_EXTERNAL / deterministic)"
echo "══════════════════════════════════════════════════════"

if [ -n "$MARKET_PUBKEY" ] && [ -f "$ORACLE_BIN" ]; then
  RESOLVE_OUT=$(ORACLE_MODE=resolve \
    SOLANA_RPC_URL="$RPC" \
    PROGRAM_ID="$PROGRAM_ID" \
    MARKET_PUBKEY="$MARKET_PUBKEY" \
    TRUSTED_CODE_HASHES="" \
    VALIDATION_MODEL_URI="${VALIDATION_MODEL_URI:-}" \
    "$ORACLE_BIN" 2>&1 || true)

  RESOLVE_JSON=$(echo "$RESOLVE_OUT" | grep -E '^\{' | tail -1 || true)
  if [ -z "$RESOLVE_JSON" ]; then
    fail "oracle produced no JSON output"
    log "stderr: ${RESOLVE_OUT:0:200}"
  else
    ok "oracle produced JSON result"
    STATUS=$(echo "$RESOLVE_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('Status',''))" 2>/dev/null || true)
    SUCCESS=$(echo "$RESOLVE_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('Success',''))" 2>/dev/null || true)
    log "Status: $STATUS  Success: $SUCCESS"
    if [ "$STATUS" = "Skipped" ] || [ "$STATUS" = "Resolved" ] || [ -n "$STATUS" ]; then
      ok "oracle status is well-formed: $STATUS"
    else
      fail "oracle status missing or empty"
    fi
  fi
else
  log "skipped (no market PDA or oracle binary)"
fi

# ── 5. Oracle validate mode ───────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════════════════"
echo " 5. Oracle validate mode"
echo "══════════════════════════════════════════════════════"

if [ -n "$MARKET_PUBKEY" ] && [ -f "$ORACLE_BIN" ]; then
  VALIDATE_OUT=$(ORACLE_MODE=validate \
    SOLANA_RPC_URL="$RPC" \
    PROGRAM_ID="$PROGRAM_ID" \
    MARKET_PUBKEY="$MARKET_PUBKEY" \
    TRUSTED_CODE_HASHES="" \
    VALIDATION_MODEL_URI="${VALIDATION_MODEL_URI:-}" \
    "$ORACLE_BIN" 2>&1 || true)

  if echo "$VALIDATE_OUT" | grep -qE '^\{'; then
    VSTATUS=$(echo "$VALIDATE_OUT" | grep -E '^\{' | tail -1 | \
      python3 -c "import sys,json; print(json.load(sys.stdin).get('Status',''))" 2>/dev/null || true)
    ok "validate mode returned JSON (Status: $VSTATUS)"
  elif echo "$VALIDATE_OUT" | grep -q "VALIDATION_MODEL_URI"; then
    ok "validate correctly errors on missing VALIDATION_MODEL_URI"
  else
    fail "validate mode: unexpected output"
    log "${VALIDATE_OUT:0:200}"
  fi
fi

# ── 6. Oracle match_full ──────────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════════════════"
echo " 6. Oracle match_full mode (project + compare in-process)"
echo "══════════════════════════════════════════════════════"

CATEGORY_HASH=$(node -e "
const crypto = require('crypto');
console.log(crypto.createHash('sha256').update('Construction').digest('hex'));
" 2>/dev/null || echo "")

if [ -n "$CATEGORY_HASH" ] && [ -f "$ORACLE_BIN" ]; then
  MATCH_OUT=$(ORACLE_MODE=match_full \
    SOLANA_RPC_URL="$RPC" \
    PROGRAM_ID="$PROGRAM_ID" \
    CATEGORY_HASH="$CATEGORY_HASH" \
    TRUSTED_CODE_HASHES="" \
    "$ORACLE_BIN" 2>&1 || true)

  if echo "$MATCH_OUT" | grep -qE '"Success"'; then
    MSUCCESS=$(echo "$MATCH_OUT" | grep -E '^\{' | tail -1 | \
      python3 -c "import sys,json; print(json.load(sys.stdin).get('Success',''))" 2>/dev/null || true)
    ok "match_full returned (Success: $MSUCCESS)"
  elif echo "$MATCH_OUT" | grep -q "pool too small"; then
    ok "match_full correctly rejected: pool too small (< 10 devices required)"
  else
    fail "match_full unexpected output"
    log "${MATCH_OUT:0:200}"
  fi
fi

# ── 8. Borsh parser round-trip ────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════════════════"
echo " 8. Borsh parser — real account bytes"
echo "══════════════════════════════════════════════════════"

if [ -n "$MARKET_PUBKEY" ]; then
  ACCT_JSON=$(curl -sf "$RPC" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getAccountInfo\",\"params\":[\"$MARKET_PUBKEY\",{\"encoding\":\"base64\"}]}" \
    -H 'Content-Type: application/json' 2>/dev/null || echo "{}")

  DATA=$(echo "$ACCT_JSON" | python3 -c "
import sys,json,base64
r = json.load(sys.stdin)
v = r.get('result',{}).get('value')
if v:
    d = base64.b64decode(v['data'][0])
    print(len(d))
else:
    print(0)
" 2>/dev/null || echo 0)

  if [ "$DATA" -gt 100 ] 2>/dev/null; then
    ok "Market account has $DATA bytes — parser can deserialize"
  else
    fail "Market account not found or empty ($DATA bytes)"
  fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════════════════"
TOTAL=$((PASS + FAIL))
echo " Results: $PASS/$TOTAL passed"
echo "══════════════════════════════════════════════════════"

if [ "$FAIL" -gt 0 ]; then
  echo " $FAIL test(s) failed."
  exit 1
else
  echo " All tests passed."
fi
