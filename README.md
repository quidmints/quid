
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

### Known gap: the return leg is blocked on the Ethereum side

QD crosses to Solana and cannot cross back. There is no outbound instruction —
`wrap_in_oft_format`, `cpi_send` and `cpi_quote` are wired and waiting, which is
why they carry `#[allow(dead_code)]` rather than being deleted.

Writing one now would be wasted, because no message it could produce would be
accepted. `Basket.sol::lzReceive` reads the message type from the first byte of
the composeMsg — `TRANSFER` is 8 — and then hands **the same bytes**, from byte
zero, to `_handleBasketTransfer`, which does
`abi.decode(msg, (uint[], uint[]))`. Those cannot both hold.
`abi.encode` of two dynamic arrays begins with a 32-byte offset, so byte zero is
`0x00` and the dispatch falls through to `revert BadType()`. Prepend the `0x08`
the dispatch wants and the first word becomes an astronomical offset, so the
decode reverts instead. There is no encoding that satisfies both readers.

Consistent with that, nothing anywhere sends one: no contract on Base, Arbitrum
or Polygon builds a TRANSFER composeMsg either, so the branch has never been
reached from any chain. It is unfinished on Ethereum, not merely unused.

Two ways out, both Solidity and so both outside this package: slice the type
byte before decoding, or drop the type byte for TRANSFER and dispatch on
`srcEid` instead. Until one of them lands, the Solana half has nothing to
target — which is also why the maturity question below stays open rather than
being settled in code.

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

### The bridge is not proven, and cannot be proven here

Both halves are written, both compile, and the pieces that can be checked in
isolation are: the payload is exactly the 40-byte header, the burn rounds to
whole shared-decimal units, the peer and origin chain are verified on receive,
and `cpi_clear` runs before any mint so a message the endpoint never delivered
cannot mint anything.

None of that is evidence the bridge works. A local validator can load the real
endpoint program — it does — but not the message libraries, DVN attestations
and executor configuration that make a send routable or a receive verifiable.
Nothing here has ever carried a message end to end.

Proving it needs a real crossing: the program deployed to Solana devnet against
endpoint id 40168, `Basket.sol` on a matching testnet, DVNs configured on both
sides, and a QD round trip observed to land. Until that has been done, treat
the return leg as untested code that compiles, not as a working bridge, and do
not let the fact that everything else in this repository is covered by tests
suggest otherwise.

## Whose credit you hold

Nobody puts real securities on chain. Every venue issues a liability against
shares it custodies, and the only question a holder actually faces is whose
balance sheet stands behind the position.

**Backed xStocks** are a claim on `Backed Assets (JE) Limited`, a Jersey SPV
registered with the JFSC. The token is freely transferable — read the mint's
Token-2022 extensions and `TransferHook` is unset while `DefaultAccountState`
is unfrozen, so there is no mechanism by which holder-level permissions could
be enforced after issuance. Two other extensions are set, and they are the
point: `PermanentDelegate`, which lets the issuer move or burn any holder's
balance, and `Pausable`, which lets them halt every transfer. Freely tradeable
and entirely at the issuer's discretion are not in tension; they are the same
design.

**Robinhood Stock Tokens** are tokenized *debt* securities. No voting rights,
no shareholder rights, no ownership claim on the underlying, issued on a chain
Robinhood operates for compliance and order routing. A licensed broker holding
the actual shares still hands the holder a liability.

**Ostium** is the OLP vault's solvency, plus an off-chain price signer. In July
2026 that signer's key was compromised and used to submit a fabricated price
report that validated cleanly, manufacturing profits paid straight out of the
vault: 23.75M USDC drained, the vault down roughly 72% from 32.7M, and the
liquidity providers absorbed all of it. Trading resumed eight days later on a
migrated environment; LP recovery was still undisclosed at the post-mortem.

Their synthetics thesis was never tested. What failed was a single key that
could mint P&L from nothing — which is the one lesson this repository should
take from them and has: prices are read on chain from Pyth, bounded by
staleness and by TWAP deviation, and there is no operator-signed feed anywhere
to compromise. Adding one for convenience is the door that must stay shut.

**Here** it is a pool that is over-collateralised, on chain, and short only the
net of each ticker. No permanent delegate over a position, no pause authority,
no chain operator between an order and the book.

### Minting is not something the program can do

There is no on-chain issuance to call. AAPLx's mint authority is
`7pt9tkctJPK7PPNQJ77GKg8ZffSF6QxoMiCFYHxrtaCj`, owned by the System Program —
a plain wallet, not a PDA, and not executable. So Backed mints by signing off
chain, and their three documented flows are consistent with that: sweeping
addresses and API keys for the market flow, RFQ, and in-kind. Onboarding buys a
whitelisted wallet and API credentials, not a program to CPI into.

That leaves two routes for acquiring the residual hedge, and they trade against
each other. On-chain through a DEX, which the program can do by itself with no
operator, at whatever secondary depth exists — thinnest exactly when it would
be needed. Or through Backed's primary market, which prices better at size but
requires an operator holding a whitelisted key and executing off chain.

The second is worth naming precisely rather than dismissing: an operator key in
the settlement path is the *shape* of what took Ostium down. It is materially
different — an execution key cannot fabricate a price the way a compromised
oracle signer can — but it is the same category of trust this design has
otherwise kept out, and it should be adopted knowingly if at all.

### What primary-market access does and does not buy

The issuer's gate is on the counterparty in front of it: onboarding with KYC
and AML, after which specific wallets are whitelisted, and only whitelisted
wallets may mint or redeem. That is an entity-level check. The beneficial owner
behind a whitelisted wallet is not enumerated, and — given the absent transfer
hook — could not be policed even if the terms asked for it. Minting is
$100,000 minimum; redemption 5,000 USD, rejectable on adverse findings, with
the issuer able to terminate a product on 30 business days' notice at a value
it determines.

So onboarding lets this protocol mint **as principal**, for its own book. It
does not make it a conduit. The moment customer assets are taken in and fiat
handed back, the intermediary is us, and that is a licensing question about
this protocol rather than a permission granted by Backed — their willingness to
face us is not a discharge of our own obligations, and their right to reject
redemptions on adverse findings is exactly them managing exposure to what we
pass through. Mint as principal and sell into the secondary market, the way an
ETF authorised participant does, and no individual's redemption is ever
intermediated.

### What is not claimed

Price discovery, and the distinction is sharper than "no perp venue does it".

A tokenised structure transmits flow to the real market at the *primary* boundary:
an authorised participant subscribes, and if the issuer hedges by buying the
share, a real order reaches the real book. Backed say they purchase the
underlying through regulated brokers at issuance, so their creations do carry
through. Robinhood's Stock Tokens are tokenised debt issued by Robinhood Assets
(Jersey) Limited giving "economic exposure to underlying securities but not any
legal or beneficial rights", and the backing mechanism is not disclosed — so
whether a subscription becomes a share purchase is the issuer's hedging policy
rather than an entitlement the holder can point at.

Either way, only the primary boundary transmits. On-chain secondary trading of
a stock token no more moves the underlying than secondary ETF volume does; the
creation and redemption baskets are the only channel, and with a $100,000
minimum mint those are thin relative to what trades on top of them.

A synthetic book has no such boundary at all. Nothing here reaches the
underlying market, ever, and that is a real difference from a tokenised
structure rather than a technicality both share. It is worth being plain about,
because the compensating claim below only stands if this one is conceded.

What is left after that is worth more than it sounds. Eighty of the 1,063
tickers priced here have a token on Solana; the other 983 — every FX pair,
every rate, some nine hundred equities — will never have one, because custody
and float do not justify it. Being synthetic is not a compromise on that tail,
it is the only way it exists at all. A venue that can only offer what it can
custody cannot reach it.

The difference from Ostium is not netting — they net too, and a buffer sized
to gross exposure was never the reason theirs exists. Their Liquidity Buffer is
first in line to settle every trade and absorbs losses in full before any reach
the vault, which puts LP capital in the *senior* position behind a junior
tranche. It exists because a trade executes without an immediate counterparty,
leaving an open-interest imbalance the buffer carries as delta, and it doubles
as working capital for settlement — which is why trades that increase skew are
charged a higher base fee. That is a two-tier capital structure, deliberately.

Here there is one tier and the junior position is *per position*: a trader's
own pledged collateral is the first loss, so it falls on whoever took the risk
rather than on a pooled layer somebody else funded. The collar and the
per-ticker reserve then sit against the residual.

Neither is strictly better and the trade should be stated honestly. Attribution
is cleaner here, and there is no buffer to fund, refill or manage. But there is
also no second layer: once a position's collateral is exhausted the loss
reaches depositors directly, where Ostium's design interposes a tranche first.
That is exactly why the unwind had to learn depth as well as elapsed time — in
a gap, the per-position first loss is the *only* thing between a trader's
deficit and everyone else's principal, so it has to be collected before it is
outrun. And a tranche is no guarantee: theirs was in place when 23.75M USDC
left the vault, and the liquidity providers absorbed all of it anyway.
