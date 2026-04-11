
## De-peg watchdog

`my-workflow` is connected to the stable-coin basket through `UMA.sol` which is live on mainnet.
`oracle-cre` is just a PoC, but is a worthwhile construction too: weighing evidence, applying rules,  
consulting AI models, returning a verdict — was already general.

Our Switchboard oracle reads market data directly from the Solana blockchain before running its resolution logic.   
It asks: "what is the question, what evidence was submitted, what are the rules?" — all from chain state.   
This means it only works for markets on Solana, and only when triggered by Switchboard.  

The CRE oracle in this folder receives inputs as structured data in the trigger message itself.   
Whatever system is calling it — UMA on Ethereum, an insurance protocol, a logistics contract: it packages the question,     
the possible outcomes, and the evidence it has collected, and sends it in. The oracle evaluates it and returns a verdict.   
No blockchain access required during resolution.  

### What this enables concretely:  
For UMA disputes: when a bond is challenged, the Chainlink DON calls the CRE oracle with the asserted claim and any forensic evidence.  
The oracle returns a verdict, and the workflow executes the settlement automatically.  
For any structured dispute: the same resolution pipeline that powers SAFTA markets — deterministic formula evaluation,  
AI fallback via 0G compute, evidence weighting — is now available to any contract that can produce a structured claim, on any chain Chainlink supports.  

The two steps that previously fetched market state and evidence windows from Solana before any analysis happened are simply gone — replaced by a trigger payload.  
The pipeline itself, the AI routing, the deterministic formula engine, the evidence scoring — none of that changed. The 0G storage integration still works for adaptation blobs,  
just via HTTP gateway instead of the Go SDK. Trust is established by Chainlink's own DON pinning the WASM bytecode hash at deployment,  
rather than by AMD hardware attestation inside a Switchboard enclave.

### Switchboard vs CRE — the structural difference:
The Switchboard oracle is sovereign: it reads its own chain, maintains its own trust model through hardware attestation,  
and is triggered by its own network. It is purpose-built for markets on Solana.  

The CRE oracle is general: it is a function that takes a question and evidence and returns an answer.  
It has no opinion about where the question came from or what chain the answer lands on. That is handled by the workflow around it.  

## QU!D Protocol Keeper Bot

Automated keeper bot for the QU!D Protocol that:
1. Monitors leveraged positions and calls `unwind` when price moves ±2.5%

## Setup

```bash
# CRE CLI
curl -sSL https://docs.chain.link/cre/install | sh
cre login

# Go (wasip1 target must be supported)
go version  # >= 1.23
```

# Resolve dependencies (creates go.sum)
go mod tidy

```
### 3. Generate UMA Bindings (Recommended)
```bash
# This creates type-safe Go bindings from UMA.sol ABI
# which gives you WriteReportFromOnReport() instead of raw WriteReport()

cre generate-bindings --abi ../out/UMA.sol/UMA.json --pkg uma --out my-workflow/uma/
```

### 4. Configure
```bash
# Copy .env template
cp .env.example .env
# Edit with your keys:
#   CRE_ETH_PRIVATE_KEY=0x... (any funded Sepolia key)
#   GEMINI_API_KEY_VAR=...    (optional, falls back to deterministic)
#   CMC_API_KEY_VAR=...       (optional)

# Update contract addresses in config files:
#   my-workflow/config.staging.json  → umaContractAddress, auxContractAddress
#   my-workflow/config.production.json → same
```

### 5. Test
```bash
# Dry-run simulation (no broadcast)
cd safta-cre
cre workflow simulate my-workflow --target staging-settings

# With HTTP trigger (like forge vm.ffi does):
cre workflow simulate my-workflow \
  --non-interactive \
  --trigger-index 2 \
  --http-payload '{"assertionId":"0xabc...","claimedSide":2,"bond":"1000000000000000000","mode":"watchdog"}' \
  --target staging-settings

# Forge integration test:
cd ..  # back to repo root
forge test --match-test test_CRE -vvv --ffi
```

## Configuration

Set environment variables:

```bash
# RPC endpoints (optional - uses public RPCs by default)
export ETH_RPC="https://eth-mainnet.alchemyapi.io/v2/YOUR_KEY"
export POLYGON_RPC="https://polygon-mainnet.alchemyapi.io/v2/YOUR_KEY"

# Keeper wallet private key (required for transactions)
export KEEPER_PRIVATE_KEY="0x..."
```

## Running

### Development (read-only mode)
```bash
npm start
```

### Production
```bash
# Build first
npm run build

# Run compiled version
node keeper.js
```

### Using PM2 (recommended for production)
```bash
pm2 start keeper.js --name "quid-keeper"
pm2 save
pm2 startup
```

## How It Works

### Position Monitoring

The keeper tracks `LeveragedPositionOpened` events from the Amp contract and maintains a list of active positions. Every 15 seconds, it:

1. Fetches current ETH price from `Aux.getTWAP(1800)`
2. Calculates price delta for each position: `(currentPrice - entryPrice) / entryPrice`
3. If delta is ≤ -2.5% or ≥ +2.5%, calls the appropriate unwind function:
   - `unwindZeroForOne()` for long positions
   - `unwindOneForZero()` for short positions

The keeper needs ETH/MATIC to pay for transactions:
- `unwindZeroForOne` / `unwindOneForZero`: ~200k-500k gas per batch

Ensure your keeper wallet is funded on all active chains.
