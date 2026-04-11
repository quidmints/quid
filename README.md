
##  

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
