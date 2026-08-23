
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

### Whether to buy at all, and when

Default: **no, not systematically**, because the design already does most of
the work. The pool is short the *net* of each ticker, so Alice long 100 against
Bob short 100 leaves it flat however much collateral sits behind either side.
Securities only matter for the residual, and the residual is exactly what the
collar and the per-ticker reserve already cover. Hedging a book that nets to
near zero pays a spread to remove a risk that is not there.

Four things argue against a standing programme, beyond the cost:

- It converts liquid dollars into a less liquid asset, against a protocol whose
  first promise is redeemability. xStock secondary depth is thinner than the
  underlying's, and thinnest when it would be needed.
- Coverage is 80 of 1,063. Hedging the tickers that *can* be hedged, while the
  other 983 stay open, can leave a worse book than an unhedged one — the
  measurable risks removed and the rest kept.
- Basis risk. xStocks trade around the clock and the underlying does not, so a
  position marked against an equity feed but held as a token drifts from it
  over every weekend.
- Minting is closed, so every purchase is secondary-market at whatever depth
  exists that day.

If a hedge is worth holding, the rule is **persistence, not panic.**

The instinct is to buy when the books are called, which is when prices are
falling. That is the worst moment on every axis simultaneously — collateral
worth least, redemption slowest, secondary market thinnest, and the Ethereum
leg still not atomic. Buying under stress converts a modelled risk into a
realised loss, and does it at the widest spread available.

A hedge earns its cost when a net position has *persisted*: same direction,
material size, sustained across a long window. That is a different trigger from
"today is bad", and it points the other way in time — the position is put on in
calm conditions, for the few largest concentrations, and by hand long before it
is worth automating. Nothing in the program decides this; `is_deliverable()`
answers whether the option exists and stops there.

No concentration surcharge is priced against this, deliberately. `crowding_bps`
already charges a one-sided book more and offsetting flow less, which is the
same signal without the extra machinery.

### The return leg is a holder's action

Bridging back is not an operator's privilege and does not need one. The holder
burns QD on Solana and `Basket.sol` releases the matching QD to them on
Ethereum: nothing is created or destroyed, the balance changes chains. Gating
that behind an authority would leave QD-on-Solana with no exit, which is what
makes the 1:1 the accounting assumes unenforceable — no holder could redeem it
and no arbitrageur could close a gap, because closing one means moving QD home.

The maturity is the exception, and the only one. It is set by the program, not
the caller, for the reason below.

### Known gap: the return leg and the 6909 maturity

QD crosses to Solana and cannot cross back. There is no outbound instruction —
`wrap_in_oft_format`, `cpi_send` and `cpi_quote` are wired and waiting, which is
why they carry `#[allow(dead_code)]` rather than being deleted.

Building it needs a decision, and one of the three candidates is already
settled: **Solana does not track maturity and does not carry more state.**

`Basket.sol::_handleBasketTransfer` mints at whatever ids the returning message
names, and the id is a maturity — `currentMonth()` is
`(block.timestamp - _deployed) / MONTH`, a small integer off a clock. Solana's
QD is a single fungible mint and records no maturity, so on the way back there
is nothing to read the id from. What remains:

1. **Ethereum derives it.** The id is computable there, so the message would
   not need to carry one at all and Solana would never be trusted with it.
   Cleanest, and a Solidity change, so it is not on this side of the wire.
2. **Solana derives the same number from the same clock.** `MONTH` is
   2,420,000 seconds and `_deployed` is fixed the moment `Basket.sol` is live,
   so both are constants of the sort `USD_STAR` and `LZ_ENDPOINT_PROGRAM`
   already are — knowledge, not state. Solana computes
   `(now - deployed) / MONTH` from its own `Clock` and names the month *after*
   it, which is what `_handleJuryCompensation` already does when it mints at
   `currentMonth() + 1`.

The `+ 1` is doing real work. Solana's clock and Ethereum's `block.timestamp`
both track wall time but not each other, and near a month boundary they
disagree. Naming the next month means skew can only ever place the maturity
further out, never nearer — a round trip cannot shorten a wait, whichever chain
is ahead. The cost is that someone whose QD genuinely was near vesting is
pushed back a month by bridging, which is the right way round for the error to
fall.

What must not happen is the obvious version — letting the sender name the id.
The message is what mints, so a caller who picks an already-vested month
converts a locked balance into an immediately redeemable one by bridging it
twice. Until the return leg exists, that risk is theoretical; the moment it
does, the id has to come from somewhere the caller does not control. This is
the one part of an otherwise permissionless path that the program must own.

Neither option needs a new instruction. Sending QD home is a withdrawal, so it
belongs on `handle_out` with the endpoint accounts riding `remaining_accounts`
— exactly how the Kestrel round trip was folded in rather than given
instructions of its own.
