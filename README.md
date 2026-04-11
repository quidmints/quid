# ~~казино~~ cause you know

*a programmable, compliant stablecoin payment layer that allows automated, conditional,*   
*machine-driven transactions including escrow, FX, and treasury actions without manual*    
*intervention, combining settlement with an integrated institutional on-chain venue*

Bebop currently doesn't do RFQ    
for tokenised equities, but in  
the future, executing multi-day    
unwinds can use Solana contracts  
here, collateralised by Perena   
and our Ethereum basket, as a
means of hedging in case the  
unwinds face cancellations...    

That's when mid-way during a  
multi-day unwind the market  
moves the opposite direction.  
Having a hedge in place from  
the beginning makes this as   
cost-effective as possible.  

Synthetic hedge a is cost-  
effective for this, more info  
on the risk management [here](https://gitlab.com/quidmint/quid/-/blob/main/docs/WP.md).  

## Ethereum Basket

Bebop's JAM settlement contract  
gets free flash loans from `Aux`.   
Liquidity boostrapping (the cold  
start problem) is solved through  
bonds: dollar depositors are able  
to get their future yield upfront,  

as a weighted average of all the  
stable yields within our basket,  
in a way that is responsive to  
market sentiment on depeg risk.    

`Rover.sol` is the UniV3 contract,   
the name comes from "price range";  
it's always re-calibrated to be  
in the best position to collect  
fees (which are auto-compounded).  

Vogue is a type of Range Rover...    
the `Vogue.sol` version is UniV4.  
A momentum strategy for extra %  
plugs the AAVE `AMP` into `AUX`.  

There's zero-IL, single-sided provision;   
if a swap can't be fulfilled by internal  
liquidity alone, tx gets split b/w V3/V4.    

swaps on V4 are executed "abstractly"   
using “virtual balances”; as such wETH   
isn't in PoolManager, nor are stables...  

Chainlink CRE evaluates price histories from  
CoinGecko/CMC to runs depeg analysis. If it's   
offline `Court.requestArbitration()` selects  

12 jurors from the basket via RANDAO, and runs   
commit-reveal votes. Solana prediction markets   
use Court if they prefer it over AI resolution.  

## Oracle

Different models from 0G can be stacked together (in an E2E encrypted manner) for   
chained execution to resolve prediction outcomes; human resolution (fallback) via LZ.  

Before becoming a market, questions go through     
qualification path in `validate.go` to determine    
if it's resolvable at all and how to resolve it.  

- Execution plans (execution_plan.go, step_executors.go): Markets encode a DAG of typed pipeline steps (FINGERPRINT, CLASSIFY, TRANSCRIBE, EMBED, EVALUATE, RESOLVE) as JSON in EvidenceRequirements. Steps are gated by conditions (min score, tag presence, device count). The plan runs through a typed executor registry; results thread forward between steps.

- Model dispatch (model_dispatch.go): Steps that need inference route by URI scheme: 0g:<provider> → 0G Compute Network sidecar (OpenAI-compatible proxy, TeeML-verified), https:// → direct remote TEE endpoint, switchboard:<pubkey> → another CoCo Function's PullFeed. Models are never bundled in the oracle binary.

- Privacy bridge (privacy_bridge.go): Cross-provider evidence aggregation inside the TEE. 2 bands: BandPublic (boolean outputs → PullFeed) and BandTEEOnly (internal derivation only, never exits enclave). Provider envelopes fetched over switchboard: or https: endpoints, ECDH-decrypted inside the TEE.

- Resolution (deterministic_resolve.go, resolve.go): Formula-based resolution (TAG_THRESHOLD, MULTI_TAG_AND, DOMAIN_RATIO, TREND, PIPELINE_MATCH, etc.) runs first at zero cost. If the formula can't resolve

- Attestation (tee_privacy.go): Each session produces a TEEAttestation binding code hash (MRENCLAVE), input hash, and output hash via a TEE-bound P-256 key. SEV-SNP report verification checks report_data[0:32] is bound to the session and measurement[0:32] matches the trusted code hash. Full VCEK chain verification is handled by the Switchboard network verifier before the PullFeed is accepted on-chain.

### Solditiy tests
```bash
cd evm  

forge test -vvvv  

anvil --fork-url https://ethereum-rpc.publicnode.com --port 8545
forge script scripts/DeployL1.s.sol:Deploy --rpc-url http://localhost:8545 --broadcast

cd keeper/my-workflow/  

cre login  
cre workflow simulate my-workflow --target staging-settings  
3  
{"assertionId":"0x0000000000000000000000000000000000000000000000000000000000000001","claimedSide":2,"bond":"1000000000000000000","mode":"watchdog","requestTimestamp":1740153600}  
```

### Solana tests

Tickers available for demo: XAG, XAU, BTC, ETH, SOL

```
cd svm  
yarn install --ignore-engines  
cargo install spl-token-cli   
yarn refresh  
chmod +x start-validator.sh  
./start-validator.sh  
```
generates new keypair on first build  
`anchor build -- --features testing`  
get the new program ID  
`anchor keys list`  
Copy that ID and update lib.rs, then rebuild
`declare_id!("NEW_PROGRAM_ID_HERE");`  

finally  
```
anchor test --skip-build --skip-local-validator  
cd ..  
npm run build  
npm run start  
```
