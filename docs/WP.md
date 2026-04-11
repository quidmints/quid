## QU!D

An Ethereum basket that holds the top ten stablecoins. USDC's de-peg during the SVB crisis
exposed the concentration risk of single-collateral synthetic protocols —
our basket holds diversified exposure so every position is not exposed to the same tail event.

All USDC entering the protocol is wrapped in USYC — Hashnote's overnight repo product —
before entering the basket, giving every dollar a T-bill floor yield regardless of on-chain activity.
This is the monetary floor: depositors earn at minimum the risk-free rate, with on-chain yield stacked above it.

The basket targets over 10% APY through AAVE money market yield, Morpho vault yield,
Uniswap V3/V4 LP fees from Rover and Vogue, and the volatility risk premium
from the momentum strategy plugged into the AMP module.

Every stablecoin in the basket — FRAX, DAI, sDAI, sUSDe, and the others — maintains its peg through a combination of redemption arbitrage and issuer-side reserve management. The structural vulnerability common to all of them is the same: sudden large redemptions force the issuer to unwind reserve positions at speed, under stress, precisely when those positions are hardest to unwind. FRAX's AMO has to reduce its Curve liquidity deployment. MakerDAO has to liquidate collateral positions. Ethena has to close delta-neutral short positions on perpetual markets where funding rates may already be dislocated. Each of these issuer-side responses to redemption pressure is itself a source of further peg instability — the act of defending the peg creates secondary market effects that threaten it.

When basket stablecoins enter QD term deposits, they are removed from each issuer's redemption queue for the duration of the lock. A depositor who commits to a six-month QD maturity is not going to redeem their FRAX allocation from Frax Finance during that period. They cannot — the QD maturity lock prevents it. That FRAX is, from Frax Finance's perspective, effectively in cold storage. Its AMO does not need to stand ready to redeem it. Its reserve positions do not need to be sized defensively against it. The same logic applies simultaneously to every other constituent in the basket.

This is the cross-strengthening mechanism: the QD term deposit structure induces lock-up across all basket constituents simultaneously and in proportion to the basket's weights. A single term deposit decision by a QD depositor removes liquidity pressure from FRAX, DAI, sUSDe, sDAI and every other constituent at the same time. No individual issuer could offer this — FRAX locking can only reduce pressure on FRAX. QD locking reduces pressure on all of them at once.

The yield multiplier makes this self-reinforcing. Longer maturities receive higher yield claims because longer locks provide more durable liquidity removal for every constituent issuer. The depositor choosing a twelve-month lock over a three-month lock is not just earning more yield — they are providing each issuer twelve months of redemption pressure relief instead of three. The yield multiplier is the market-clearing price for that additional service. Each issuer's peg stability improves as a direct function of the aggregate lock duration across the basket, which the yield structure continuously incentivizes depositors to extend.

The result is a virtuous dynamic that no single-constituent stablecoin can replicate. Higher QD yield attracts more term deposits. More term deposits lock more of each constituent for longer. More constituent lock-up reduces each issuer's need for defensive reserve positioning. Less defensive reserve positioning means each issuer can deploy more capital toward yield generation rather than redemption readiness. More yield generation by each constituent flows through the basket's weighted average to QD holders. The cycle is self-reinforcing at each step.

FRAX's AMO extends further because the redemption overhang is gone. MakerDAO's DSR sustains higher. Ethena's basis trade runs tighter.
Each of those extensions is output — aggregate output of productive activity enabled by committed capital,
accruing across all constituents before any netting. QD reduces pressure on all of them simultaneously.

The constituents correlate in direction but diverge continuously in magnitude —
Ethena's basis, DAI's DSR, FRAX's AMO deployment depth are set by independent mechanics
on independent governance timelines. No single constituent can move the weighted average to an arbitrary level.
The basket's rebalancing continuously adjusts weights as magnitudes diverge.

Rover.sol constantly recalibrates its Uniswap V3 range to maximise fee collection with auto-compounding.
Vogue.sol is the V4 equivalent, bootstrapped against V3.

There is zero-IL, single-sided provision — if a swap cannot be fulfilled by internal liquidity alone,
the transaction splits between V3 and V4. Swaps in Vogue execute against virtual balances;
wETH is not in PoolManager, nor are stables. Basket tokens from L2 plug into L1.

The collateral and the redemption obligation are the same instruments,
held in the same contract, with no QU!D balance sheet interposed. No fractional reserve.

The Genius Act's proportionality standard reaches one conclusion:
the capital required to ensure redemption ability is the basket itself,
which the contract already holds in full.

The basket's capital structure hinges on how to stake ETH into Uniswap in such a way  
that it earns full upside in terms of ETH's price, without diluting those returns    
by pairing with dollar capital that demands its own share of the same yield.

Dollar depositors fund the basket through bonds — receiving their weighted average gross on-chain product claim upfront, as a forward-accruing entitlement computed at entry from the basket's weighted average yield at that moment. This is the cold-start liquidity bootstrapping mechanism. Dollar capital commits to a maturity lock and receives a yield multiplier calibrated to the lock duration. The maturity lock removes that capital from each constituent issuer's redemption queue for the duration of the lock — not a 1:1 claim on any specific constituent, but the basket-weighted fraction of aggregate locked capital attributed to each issuer's weight at that moment.

ETH depositors are an entirely separate class. They receive ETH yield from ETH deployed through QU!D's infrastructure — staking returns, Uniswap LP fees on ETH-side positions — without sharing that yield with dollar depositors. Dollar depositors receive the basket's weighted gross on-chain product plus fee claims on the dollar portion of Uniswap liquidity, paid by third-party traders to access that liquidity. These are two distinct yield surfaces, two distinct depositor classes, two distinct sources. Neither cross-subsidises the other.

This is not available anywhere else. Every other Uniswap LP protocol pairs ETH with a stablecoin counterpart and shares all fees pro-rata across both sides. QU!D's architecture lets ETH stake fully into Uniswap range positions while dollar capital earns its own separate basket yield. ETH earns the full upside of being the productive asset. Dollars earn the full return of the stablecoin ecosystem they stabilise.

### The Exclusive Flashloan Gate

Bebop solves a capital efficiency problem. It inherits none of QU!D's regulatory surface (or lack thereof) in doing so.  
With that said, Bebop's JAM is the exclusive flashloan gate into the basket contract, enforced by `msg.sender == jamSettlement`.

This is both access control and a liquidity facility: only JAM-settled transactions have borrow reach within a single block.
Because JAM's settlement is atomic, solvers can borrow from the basket, route through multiple hops,
and repay in the same Ethereum block — the basket itself becomes the liquidity source when no pre-funded counterparty exists.

For solvers, this is a structural capital efficiency gain with zero cost.
JAM currently requires funds to be transferred to the JamSettlement contract before execution —
the pre-commitment bottleneck that makes large institutional sequences either capital-prohibitive
or dependent on a single large counterparty. With QU!D's basket as the flash loan source,
solvers access basket liquidity for each hop without pre-locking capital.

The basket provides the liquidity. The solver routes and repays atomically.
The basket is already capitalised by dollar depositor bonds attracted by the yield structure in Section III.
Solvers receive free flash loans from capital that exists because ETH depositors wanted to stake without selling.
The flash loan facility costs QU!D nothing to provide and costs solvers nothing to use.

### De-peg Detection: Chainlink CRE, and Court.sol

Nexus Mutual's claims process involves a committee vote, a waiting period, and a payout in NXM whose value may have moved adversely during the delay — the harm and the compensation are separated in time. The uncertainty about recovery is priced into the premium. You pay not just for the expected loss but for the probability that the recovery mechanism fails, delays, or pays out in something worth less than you lost.
The basket settles immediately against itself.

When a constituent depegs and a depositor redeems, the haircut applies at the moment of redemption — a portion goes to TVL, protecting remaining depositors from absorbing the full cost of the exit. There is no claims committee, no waiting period, no recovery token. The settlement is immediate and the remaining basket absorbs it continuously rather than discretely. That removes the recovery uncertainty from the premium calculation.

The basket reduces the systemic amplification of harm, which reduces expected loss, which reduces the insurance premium that makers need to charge to participate. Ribbon's covered call strategy is expensive because the risk of catastrophic loss during a depeg is real and the recovery is uncertain. If immediate settlement against the basket eliminates recovery uncertainty, makers can quote tighter because their downside is bounded and certain rather than unbounded and probabilistic.

Every historical manipulatable de-peg — UST, USDC/SVB — followed the same pattern: whoever found out first exited. The de-peg was as much a consequence of the exit race as any fundamental problem. Fast actors created the damage that slow actors absorbed. QU!D's de-peg detection pipeline prevents this.

Chainlink CRE evaluates evidence — fetching price histories, running temporal de-peg analysis (duration thresholds, candle counting), and publishing its recommendation.

If CRE is unavailabe, as a fallback 12 jurors are selected from the basket via RANDAO. They commit votes — auto-revealed for them — or are slashed. Solana prediction markets can also use Court optionally. If depositors redeem during a de-peg, a haircut applies — a cut goes to TVL, protecting remaining depositors from absorbing the full cost of the exit race.

### The Solvency Invariant

The Solana depository (adding another layer of yield generation to basket tokens) maintains one invariant at all times: `max_liability ≤ total_deposits`.

`max_liability` is the running sum of exposure × collar_bps across every open position. Even if every leveraged position simultaneously moves adversely — the worst-case correlated scenario — the pool survives. Collars tighten automatically as the Actuary observes higher volatility, reducing `max_liability` even as positions stay open. The solvency bound is self-enforcing.

### The Actuary: Bayesian Risk Without Monte Carlo

The Actuary is backward-looking: it observes vol, tracks drawdowns, counts jumps. It does not forecast. `vol_bps` is the continuous diffusion component σ. `jump_factor` scales the jump component. This is Merton's parametric result encoded on-chain: total effective risk = diffusion × jump multiplier.

When `confidence < 2000`, `effective_vol()` returns 15000 (150% annualised) regardless of empirical vol. As confidence grows toward 10000, the floor decays: `floor = 15000 - (confidence × (15000 - empirical_vol)) / 10000`. A new asset starts at maximum fear and exponentially relaxes as data accumulates — the Bayesian update encoded as a floor function: pessimistic prior, empirical vol likelihood, posterior interpolating between them weighted by confidence.

The `cvar_multiplier` is the pre-emptive structural response to correlated collapse. When total pool concentration in one asset class rises, all positions in that class get tighter collars regardless of individual risk estimates. They liquidate sooner, reducing `max_liability` before the fault slips. You cannot model the tail. You can tighten the buffer.

Monte Carlo says "based on my model, your 99th percentile loss is exactly 847 bps." The Actuary says "I don't know how volatile this is, so I assume the worst until I learn." 2008 was a 25-sigma event under every MC model in production. The models were precise, auditable, computationally expensive, and worthless exactly when they mattered. The Actuary's approach is closer to what Taleb would endorse: accept that you cannot model tails, build structural buffers.

A strangle is long a call and a put on the same underlying at different strikes — you profit if the asset moves sharply in either direction, you lose the premium if it stays flat. The payoff is convex: bounded loss in the middle, unbounded gain at the extremes.

QU!D's collar system is structurally the inverse of that. A depositor who opens a synthetic position has their P&L bounded on both sides by collar_bps. If the position moves more than `collar_amt` above pledged (over-profitable), `repo()` forces them to take profit or add collateral — the upper collar. If it moves more than `collar_amt` below `pledged` (under-exposed), they must add collateral or face liquidation — the lower collar. The range [`pledged` - `collar_amt`, `pledged` + `collar_amt`] is the band where the position is allowed to live without intervention.

So the collar band is essentially a short strangle written by the depositor against themselves. They've sold the tails. The pool is the counterparty — it absorbs the residual risk beyond the collar, which is why max_liability tracks the sum of all collar_dollars across open positions. That's the pool's maximum exposure if every position simultaneously hits its liquidation boundary.

The connection to RAROC is the interesting part. `collar_dollar_seconds` — the time-integral of `pledged` × `collar_bps / 10_000` — is measuring how much of that short strangle premium the depositor has effectively paid over time. It's the capital they had committed to the pool's risk absorption facility, for how long. `realized_pnl` / `total_collar_dollar_seconds` tells you whether they generated returns in excess of the collar cost — which is the true risk-adjusted measure, equivalent to asking whether they were theta-positive net of gamma.

The asymmetry worth noting: a strangle trader profits from volatility, but a QU!D depositor with an open synthetic profits from directional move within the collar, not from volatility per se. High volatility actually hurts them by widening the collar (via the actuary's `obs_count` / `confidence` model increasing `collar_bps` as realized vol rises), which reduces the [lower, upper] band and makes forced intervention more likely. So in vol terms, they're short gamma — exactly like a strangle seller, not a buyer.

The `amortise()` liquidation speed formula — speed = 0.5 + 1.5 × util_factor — also maps onto this. At low utilization the pool runs slow liquidations (like letting a short strangle expire with time), at high utilization it accelerates (like a short strangle getting margin-called into a vol spike). The pool is collectively managing a book of short strangles, and utilization is the implicit vol surface.

### Borrower-Friendly Liquidation

Before any liquidation, the system checks if the trader has savings deposits. If so, it auto-repairs the position using the trader's own idle capital — capital that on Binance or dYdX would sit idle while the position gets liquidated next to it.

The liquidation algorithm amortises: traders can close positions themselves at any point, including cross-margining between positions, keeping whatever remains. Conservative leverage follows from this coherent tradeoff: aggressive leverage and generous grace periods cannot coexist.

## Prediction Markets: The Belgian Mechanism

The mechanism was inspired by Belgian auctions: a confidence parameter adds a second dimension. First-order bet: which side wins — capital allocation through LMSR pricing. Second-order bet: how right you think you are — private confidence via commit-reveal. These two dimensions are orthogonal.

A winner's accuracy equals their confidence. A loser's accuracy equals the complement. When you commit a confidence value you choose a point on a seesaw — pushing up your winner-world weight pushes down your loser-world weight. The only optimal strategy is to weight these by your actual private probability estimate. Any deviation tilts the seesaw the wrong way in expectation. Percentile ranking prevents the collapse where everyone picks the same confidence: if the field clusters, anyone who deviates because they genuinely have different calibration gets a distinct bucket placement and — if correct — higher percentile. The mechanism rewards heterogeneous private information and punishes herding.

The 80/20 split between winner and loser pools gives the accuracy signal economic teeth on the losing side. A loser who committed low confidence recovers a meaningful fraction of capital. A loser who committed max confidence loses almost everything. Both worlds have payout gradients driven by accuracy.

Time-weighted capital accumulation rewards early conviction — the hardest kind because you commit before the information environment matures. Late entrants have more data but less weight per dollar. LMSR gives every side an independent continuous price. The TWAP overlay is the manipulation defence: sustaining artificial capital pressure over the entire TWAP window means that capital is at risk the entire time.

---

## Collaborations

| Partner | Integration |
|---|---|
| Perena.org | Solana stablecoin basket. QU!D supplements Perena's basket on Solana with an Ethereum-imported basket on L1, taking deposits of L2 baskets inside L1. |
| mempalace | oracle orchestrator |
| USYC / Hashnote | Overnight repo wrapper. All USDC entering the protocol is wrapped in USYC before entering the basket, giving every dollar a T-bill floor yield. |
| AAVE / Morpho | Yield sources. Deposited stablecoins earn yield through AAVE money markets and Morpho vaults, accruing in time-weighted share calculation. |
| Uniswap Foundation | Liquidity management. Rover/Vogue manage Uniswap V3/V4 LP positions; zero-IL single-sided provision; virtual balance swaps. |
| Bebop.xyz | Exclusive flashloan gate. JAM-settled transactions are the only path to basket borrow access. Solvers route through multiple hops and repay atomically — the basket is the liquidity source. |
| Base / Arbitrum / Polygon | L2 deployment. AuxArb, AuxBase, AuxPoly handle WETH and bridged token variants. |
