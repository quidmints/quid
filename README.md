
# 

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

## Physical delivery, and why it is optional

The book is synthetic. `stay.rs` prices exposure, nets it per ticker, and
reserves against the residual — the pool is short the *net* of each ticker, not
the gross, because a long and a short of the same size leave it flat. Nothing
in the program holds a share.

"Calling the books" means taking that net and standing behind it with the real
security. `etc.rs` carries the delivery set for exactly this: `XSTOCK_MINTS`
maps a ticker to the Backed Finance xStock that settles it on Solana, and
`is_deliverable()` answers whether a net position *could* be handed over rather
than carried. The addresses are hardcoded and mainnet-verified, for the same
reason `USD_STAR` and `LZ_ENDPOINT_PROGRAM` are: the symbol "AAPLx" is not
scarce, a token-list lookup returns several, and delivering against the wrong
one is delivering nothing. All 80 are Token-2022 mints, which is why the token
handling stays interface-generic instead of assuming the legacy program.

**Coverage is a minority, by construction.** 80 of the 1,063 tickers this
program prices have a token on Solana. The other 983 — every FX pair, every
rate, most equities — can be traded and can never be delivered. That is not a
gap to close; it is the shape of the product. The delivery set is an input to
a decision, not a gate on opening a position.

### The two legs, and the one that is not atomic

Buying a share to deliver means redeeming collateral first, and the collateral
sits on two chains:

- **Solana.** Perena USD* unwraps to its constituent dollars, swaps to whichever
  the venue wants, and buys the xStock. One transaction, and flash-loanable
  through the JAM path already wired in `entra.rs`.
- **Ethereum.** QD travels by LayerZero and redeems against `Basket.sol` for
  stables there. This is **not** atomic and cannot be made so. Message delivery
  is DVN verification plus executor, minutes at best, and no Solana transaction
  can contain the outcome.

So half the balance sheet can be mobilised inside a block and half cannot. Any
delivery obligation with a deadline shorter than a bridge round trip is one the
protocol cannot meet from the Ethereum side, however solvent it is.

### Who requires this

Nobody, today, and the protocol is not obliged to anyone. Two reasons to keep
the capability anyway:

The first is regulatory, and it is narrower than it first appears. The SEC's
2026 guidance on tokenized securities splits third-party tokens in two:
*custodial*, where the holder gets a security entitlement — an indirect
interest in real shares — and *synthetic*, covering linked securities and
security-based swaps, where the holder gets the economic return and no
ownership interest at all. A synthetic position on a single equity, sold to
someone who is not an eligible contract participant, is not merely a
registration problem: a third party **may not offer or sell** it to that person.

What the guidance does *not* say is that buying the share fixes this. The
classification turns on what the holder receives, not on what the issuer
happens to hold, so a pool that owns AAPLx against its net still owes its users
a synthetic return unless they are given an entitlement to it. Delivery is a
precondition for ever offering the custodial form, and it answers the specific
objection the SEC raises against synthetics — that the holder carries the third
party's bankruptcy risk on top of the market's. It is not a reclassification,
and treating it as one would be the expensive kind of wrong.

The second is economic, and it is the stronger one. Gains paid to borrowers in
`stay.rs` come out of the same dollars that back depositors. Holding the actual
security against a net position means the payout is funded by the security
appreciating, not by diluting the people who never took the trade.

**Minting is not open to us.** xStocks enter circulation through Backed's
primary market, which requires issuer KYC/AML onboarding, a whitelisted
address, qualified-professional-investor status, and a $100,000 minimum. Kraken
is a distribution venue, not an issuer — "minting with Kraken" is not a
mechanism. Absent becoming an authorised participant, delivery means buying on
the secondary market at whatever depth exists, which is thinner than the
underlying and thinnest when it matters.

### Wrong-way risk: the books get called at the worst moment

The trigger for wanting real securities is a market that is falling, and that
is precisely when the collateral behind them is worth least. The sequence:

ETH falls. Holders pull QD out of `Basket.sol` in exchange for ETH and redeem
for stables, so the stables leave first and the pool is left holding a
disproportionate share of the asset that is dropping. The AMM does not rebalance
to 50/50 on its own — that requires an arbitrageur willing to take the falling
side, which is the trade nobody wants in a crash, so the imbalance can persist
well past the moment it matters. Meanwhile the QD still outstanding is
concentrated on Solana, backed by that skewed pool.

Every term moves the wrong way together: the collateral is worth less, the
redemption that would mobilise it is slowest, the secondary market for the
share is thinnest, and the reason to want the share is that prices are moving.
This is why solvency here is a statement about what the pool can be *valued* at,
not what it can be *converted* into, and why the two should never be conflated
in anything the protocol claims.

### Known gap: the return leg and the 6909 maturity

QD crosses to Solana and cannot cross back. There is no outbound instruction —
`wrap_in_oft_format`, `cpi_send` and `cpi_quote` are wired and waiting, which is
why they carry `#[allow(dead_code)]` rather than being deleted.

Building it needs a decision that is not the program's to make alone.
`Basket.sol::_handleBasketTransfer` mints at whatever ids the returning message
names, and the id is a maturity: `currentMonth()` is
`(block.timestamp - _deployed) / MONTH`, a small integer off a clock. Solana's
QD is a single fungible mint and records no maturity, so on the way back there
is nothing to read the id from. Three ways out, and they are not equivalent:

1. **Ethereum chooses.** The cleanest — the id is derivable there, and Solana
   never has to be trusted with it. Needs a Solidity change, so it is not on
   this side of the wire.
2. **Solana tracks maturity per holder.** Correct, and the most state this
   program would carry for one feature.
3. **Return at the least favourable maturity.** No new state: always name the
   newest month, so a round trip can never shorten the wait. Safe by
   construction, and unfair to anyone whose QD really was near vesting.

What must not happen is the obvious version — letting the sender name the id.
The message is what mints, so a caller who picks an already-vested month
converts a locked balance into an immediately redeemable one by bridging it
twice. Until the return leg exists, that risk is theoretical; the moment it
does, the id has to come from somewhere the caller does not control.
