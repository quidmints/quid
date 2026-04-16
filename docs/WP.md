## QU!D

### Integrations

| Partner | Integration |
|---|---|
| mempalace / Switchboard | We extended mempalace with libp2p in order to support personality-based matching, and model orchestration for our event outcome resolution oracle (used by our prediction markets state machine). Contributing local compute in exchange for matches is a voluntary quid pro quo, minimizing the oracle cost in terms of compute. |
| Perena.org |  QU!D supplements Perena's basket on Solana with our Ethereum-imported basket from L1. The quid quo there is between every stable in the basket, due to how quid bonds strengthen each one's peg. |
| Uniswap Foundation | Stake to play. Rover/Vogue manage Uniswap V3/V4 LP positions; zero-IL single-sided provision; virtual balance swaps. Chainlink powers the de-peg detection module. |
| USYC / Hashnote | Overnight repo wrapper. All USDC entering the protocol is wrapped in USYC before entering the basket, giving every dollar a T-bill floor yield. |
| Ether.fi / AAVE / Morpho | Yield sources. Deposited stablecoins earn yield through AAVE money markets and Morpho vaults, accruing in time-weighted share calculation. |
| Bebop.xyz | Exclusive flashloan gate. JAM-settled transactions are the only path to basket borrow access. Solvers route through multiple hops and repay atomically — the basket is the liquidity source. |
| Base / Arbitrum / Polygon | Basket shares of the L2 deployments stake into the L1 basket. |

### The basket

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

FRAX's AMO extends further because the redemption overhang is gone. MakerDAO's DSR sustains higher. Ethena's basis trade runs tighter. Each of those extensions is output — aggregate output of productive activity enabled by committed capital,
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

Bebop's JAM is the exclusive flashloan gate into the basket contract, enforced by `msg.sender == jamSettlement`.
This is both access control and a liquidity facility: only JAM-settled transactions have borrow reach within a single block.
Because JAM's settlement is atomic, solvers can borrow from the basket, route through multiple hops,
and repay in the same Ethereum block — the basket itself becomes the liquidity source when no pre-funded counterparty exists.

For solvers, this is a structural capital efficiency gain with zero cost.
JAM currently requires funds to be transferred to the JamSettlement contract before execution —
the pre-commitment bottleneck that makes large institutional sequences either capital-prohibitive
or dependent on a single large counterparty. With QU!D's basket as the flash loan source,
solvers access basket liquidity for each hop without pre-locking capital.

The basket provides the liquidity. The solver routes and repays atomically.
The basket is already capitalised by dollar depositor bonds attracted by the yield structure.
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

The asymmetry worth noting: a strangle trader profits from volatility, but a QU!D depositor with an open synthetic profits from directional move within the collar, not from volatility per se. High volatility actually hurts them by narrowing the collar (via the actuary's `obs_count` / `confidence` model increasing `collar_bps` as realized vol rises), which reduces the [lower, upper] band and makes forced intervention more likely. So in vol terms, they're short gamma — exactly like a strangle seller, not a buyer.

The `amortise()` liquidation speed formula — speed = 0.5 + 1.5 × util_factor — also maps onto this. At low utilization the pool runs slow liquidations (like letting a short strangle expire with time), at high utilization it accelerates (like a short strangle getting margin-called into a vol spike). The pool is collectively managing a book of short strangles, and utilization is the implicit vol surface.

### Borrower-Friendly Liquidation

Before any liquidation, the system checks if the trader has savings deposits. If so, it auto-repairs the position using the trader's own idle capital — capital that on Binance or dYdX would sit idle while the position gets liquidated next to it.

The liquidation algorithm amortises: traders can close positions themselves at any point, including cross-margining between positions, keeping whatever remains. Conservative leverage follows from this coherent tradeoff: aggressive leverage and generous grace periods cannot coexist.

### Prediction Markets

The mechanism was inspired by Belgian auctions: a confidence parameter adds a second dimension. First-order bet: which side wins — capital allocation through LMSR pricing. Second-order bet: how right you think you are — private confidence via commit-reveal. These two dimensions are orthogonal.

A winner's accuracy equals their confidence. A loser's accuracy equals the complement. When you commit a confidence value you choose a point on a seesaw — pushing up your winner-world weight pushes down your loser-world weight. The only optimal strategy is to weight these by your actual private probability estimate. Any deviation tilts the seesaw the wrong way in expectation. Percentile ranking prevents the collapse where everyone picks the same confidence: if the field clusters, anyone who deviates because they genuinely have different calibration gets a distinct bucket placement and — if correct — higher percentile. The mechanism rewards heterogeneous private information and punishes herding.

The 80/20 split between winner and loser pools gives the accuracy signal economic teeth on the losing side. A loser who committed low confidence recovers a meaningful fraction of capital. A loser who committed max confidence loses almost everything. Both worlds have payout gradients driven by accuracy.

Time-weighted capital accumulation rewards early conviction — the hardest kind because you commit before the information environment matures. Late entrants have more data but less weight per dollar. LMSR gives every side an independent continuous price. The TWAP overlay is the manipulation defence: sustaining artificial capital pressure over the entire TWAP window means that capital is at risk the entire time.

## Mempalace

Why is the mempalace repo logo a pyramid? The pyramid match kernel, along with other
theoretical building blocks, are explained briefly here...information geometry,
random matrix theory, etc.

Alan Watts identified a structural weakness of how most people relate:
the game of one-upmanship. Not a character flaw — a reflex installed
before the person had the cognitive capacity to examine it.

The pattern: subordination move, status assertion, pre-emptive defensive
positioning. Both parties experience it as responding appropriately to
what the other person is doing. Neither sees themselves doing it.
Both leave feeling vaguely worse than before.

This is the primary mechanism of wasted human time. Not malice. Not
stupidity. Inherited reflexes generating friction, misunderstanding,
and missed connection at scale, continuously, invisibly.

Combining inference models to produce the most high quality matches possible between people   
after assimilating as much information as possible about what's inside their heads: this is the goal.

### What the system is trying to do

Our recursive backtracker for voice recordings is based on a Tetris solver built in 2017 at École 42 (Fremont) — the home of unstoppable domains. 

Today's version does what Siri is architecturally incapable of: it scans a day's recording in reverse chronological order,  
uses later context to reinterpret earlier speech, and produces a content DAG whose structure determines  
the optimal task execution order. The signal is provably content that came from the person.

The purpose it peer pressure. To raise our standards in communication.   
Matching with people we can actually talk to.

### Most matching systems ask: who is similar to this person?

Our system asks something different: whose presence would activate the
associative memory structures that are most load-bearing for this person?

These are not the same question. Two people can be highly similar in
behavioral profile and be completely wrong for each other. Two people
can appear different on surface measures and have a recognition experience
the moment they interact — a sense of "I know this person already."

The theoretical bet is that the second question is the right one, and
that it is answerable from behavioral data if you measure the right things.

### What the behavioral data actually is: from raw session to feature vector

You're watching how someone talks. Not only what they say — how they say it,  
considering the surrounding context. 

Do they pause before answering? Do they interrupt? Does their voice get higher
or lower when they're challenged? How often do they initiate versus respond?
How much silence are they comfortable with? These patterns are consistent
across contexts for a given person. Over enough measurements in diverse
settings across time, this expresses signal about personality.

**Technical definition:** A session feature vector is a fixed-length array of
continuous-valued behavioral measurements extracted from audio and video:
- Prosodic features: pitch contour, energy envelope, rhythm, speaking rate
- Temporal features: response latency, silence duration, turn-taking patterns
- Social features: overlap rate, initiative ratio, entrainment (do they sync
  with the other person's rhythm?)
- Affect features: valence and arousal estimated from prosody

Even in 6 dimensions, cosine similarity answers "are these geometrically
similar?" The question we actually need answered is "does B's signature
pattern activate A's associative memory structure?" Those are not the
same.

### The pyramid match kernel

You have two people, each described by a small set of unusual
behavioral vectors (3–8 vectors each). You want to know how well they match.

One approach: find the closest pair, measure their distance. But this ignores
whether there's a second close pair, a third. Two people who share three
genuine behavioral correspondences at high precision are a stronger match
than two people who share one at moderate precision.

The pyramid match kernel counts matches at multiple levels of precision
simultaneously and weights them: matches at fine precision count more than
matches at coarse precision.

**Why this is the right tool here:**
The behavioral signature is a small set of vectors — outlier eigenvectors.
Comparing two people's signatures is comparing two small point sets.

The pyramid kernel naturally rewards specificity: two people who are weird
in exactly the same way (fine-level alignment) score much higher than two
people who merely have broadly similar behavioral distributions.

This is the mathematical formalization of "same kind of weird."
Weirdness is precisely what makes fine-resolution matches possible.
The more unusual both people's outlier structure is along the same axis,
the higher the pyramid kernel scores them.

### The knowledge graph sketch and structural resonance

The way concepts are connected in your mempalace is a map of how ideas
associate in your mind.

Two people can both care about jazz, but one person's jazz connects
primarily to historical musicology (jazz → 1950s → bebop → chord theory)
while another's connects to emotional memory (jazz → specific bar →
specific night → grief). The topology is different even when the surface
topic is the same.

### Engagement vectors and anchor compatibility

The engagement vector captures this:

| Dimension | What it measures |
|-----------|-----------------|
| temporal_depth | log(1 + days since first encounter) × centrality — how long has this concept been load-bearing in your thinking? |
| engagement_rate | frequency of return relative to total sessions |
| centrality | connection count in KG / max connections — how central is this concept to your whole associative network? |
| affect_mean | average emotional valence of sessions involving this concept |
| affect_variance | stability of that emotional response — is it reliably meaningful or situationally variable? |
| initiative_rate | do you bring this topic up, or do you engage when others do? |

### Anchors: the load-bearing concepts

Everyone has a handful of concepts that are both deeply embedded
(temporal_depth × centrality high) and emotionally salient (affect_mean high).
These are what Maltz would call the self-image load-bearing structures —
the things that when touched, produce a non-trivial response. The things
that when absent from a relationship, make the relationship feel shallow.

The anchor score measures whether B's deeply-held concepts resonate with
A's deeply-held concepts. Not whether they share topics. Whether the
specific things that are most emotionally load-bearing for each person
overlap, or whether the neighborhoods around those load-bearing concepts
are semantically adjacent.

Cosine similarity between anchor embeddings can tell you whether two
people's deepest concepts are semantically related. It cannot tell you
whether B's pattern of engagement activates A's memory structures — that's
a recognition event, and whether it happens is only knowable from
observing the interaction. 

**Its behavioral fingerprint:**

| Signal | What it indicates |
|--------|------------------|
| Rising pitch on declarative statements | Performing uncertainty to invite validation — the statement becomes a question |
| Compressed response latency | Not listening; waiting to speak. The next move was already prepared. |
| High overlap rate | Interrupting not from excitement but from needing to redirect attention |
| Volume escalation when challenged | Status assertion under pressure |
| Low KG cross-connectivity to other person | Not genuinely curious — evaluating and positioning |
| High engagement with confirming material, low with challenging | Closed system |
| Brief affect peak followed by return to baseline | The satisfaction of status assertion, which never actually satisfies |

The system detects these patterns from the behavioral pipeline — not from
content, from the structure of how a person engages. The matching oracle
recognizes configurations where two people both running strong one-upmanship
reflexes will produce poor network health outcomes regardless of initial
chemistry. Initial chemistry between two skilled performers is often high.
The behavioral fingerprint diverges from the long-term outcome.

### Psycho-Cybernetics and palace evolution

Maxwell Maltz's core observation: the self-image is not a consciously held
belief. It is a target-seeking mechanism that operates below deliberate
thought. Once installed, it runs automatically toward a fixed attractor —
the way a gyroscope seeks equilibrium.

The somatic layer holds this: posture, breath, vocal register, movement,
spatial positioning relative to others. These operate without conscious
direction and persist when the cognitive override fails — when the person
is tired, surprised, drunk, or under pressure.

**Why behavioral signatures capture this better than questionnaires:**
A questionnaire asks what the person consciously believes about themselves.
The self-image mechanism runs at a level below that. Behavioral signatures —
prosodic patterns, temporal rhythms, engagement structures — are readouts
of the mechanism itself, not of the person's narrative about it.

### Three types of post-match palace evolution

When a match forms, the two palaces begin influencing each other's growth.
The palace records everything. Three patterns are distinguishable:

**Growth transmission:** The person's behavioral signature evolves toward
greater coherence with its prior trajectory. New KG wings grow from
genuine co-discovery. Previously active rooms stay active or gain new
connections. Affect trajectory shows increasing baseline stability with
higher capacity for genuine positive affect. This is a compatible match.

**Replacement transmission:** The behavioral signature narrows. Previously
active KG rooms go quiet. Engagement maps show the other person's conceptual
territory appearing in this person's palace while their own original
territory deactivates. The self-image mechanism is tracking a new target
installed by the relationship rather than running toward its genuine
trajectory. This is what manipulation and controlling relationships do,
below the level of conscious awareness.

**Somatic installation below the conscious layer:**
Some post-match changes appear in the behavioral signature — changed
prosodic patterns, changed engagement maps, changed temporal rhythms —
without any corresponding new KG node. The concept never passed through
conscious processing. This is the most sensitive signal: genuine deep
influence (if it's growth transmission) or the mechanism of control
(if it's replacement transmission).

**How the system distinguishes them:**
`evolution_tracker.py` records palace snapshots and marks the
merge baseline. Post-match evolution is measured against that baseline:
- KG growth direction: continuous with prior structure or replacing it?
- Signature coherence: more or less coherent with pre-merge trajectory?
- Transmission balance: bilateral growth or unilateral colonization?
- Room activation: do the person's own rooms stay alive?

The theoretical framework tells us what compatibility is and why cosine
similarity can't measure it. But the trained model that actually measures
it requires labeled examples: pairs of people who interacted, along with
ground-truth outcomes.

The Arena generates those examples. Each challenge:
- Is a controlled interaction with known emotional/behavioral structure
- Produces measurable behavioral responses from both participants
- Creates a labeled pair: these two people interacted, this is what happened

Challenge types map to matching dimensions:
- Karaoke → shared emotional territory, anchor activation proxy
- Rap battle (generative adversarial) → presence-in-exchange,
  whether opposition generates vs. extracts
- Active listening module → listening quality, response calibration
- Problem under ambiguity → epistemic style, tolerance for uncertainty

### The feedback loop

Prediction market resolves → ground truth label produced →
pipeline configuration that generated the match scored →
composition_matrix_hash updates →
pop_version increments →
all signatures recomputed against new geometry →
next generation of matches uses better model.

The resolution feedback store in `switchboard/resolution_feedback.py`
is where this loop connects. It records: pipeline configuration used,
resolution outcome, confidence. The model registry in
`oracle/models/model_registry.py` is where trained models are loaded
into `match_compare_semantic.py` to replace the cosine proxy.

### Generative vs. extractive adversarial dynamics

Not all challenge formats are equivalent for training signal:

**Generative adversarial:** The opposition makes both parties better.
Each move creates a constraint requiring genuine creative response.
The challenge grows more interesting as it proceeds. Both leave with
something they didn't have.

**Extractive adversarial:** The goal is the other party's failure.
One party is depleted. The challenge resolves when one is exhausted.

Both exist in human interaction. Both are worth measuring. The scoring
function distinguishes them. A match between two people who thrive in
generative adversarial exchange is a different prediction than one between
two people who default to extractive. The Arena's job is to surface which
each person is running.

### Prediction markets as epistemological grounding

A model trained on interaction data that nobody has economic stake in
is trained on soft labels. The person said the interaction was good.
Did they mean it? Were they performing satisfaction? Were they accurately
predicting their own long-term experience?

A prediction market creates a hard label: capital was staked on a specific
outcome, the outcome either happened or it didn't. A resolution is expensive
to corrupt systematically because it requires maintaining a false reality
across multiple independent evidence submissions over time.

### Why the geometry is always provisional

The population manifold geometry — which behavioral dimensions are
discriminative, where clusters form, what "close" means — is estimated
from data. That estimate starts wrong and gets less wrong as the
population grows.

A matching system that commits to one geometry before the estimate
stabilizes produces matches that are biased toward early-adopter
behavioral patterns. A system that updates aggressively as new data
arrives produces match instability: pairs that matched under one geometry
don't match under the updated one.

The resolution is to maintain uncertainty over which geometry is correct:
run an ensemble of plausible geometries and surface only matches that
score well across the whole ensemble. High-confidence matches are robust
to geometric uncertainty. Low-confidence matches are sensitive to it.

**The Twitter bootstrap** provides the initial ensemble: an engagement
graph from real accounts gives a rough initial map of where compatibility
clusters exist and what behavioral signatures distinguish them. It's
wrong in specific ways (platform mechanics distort engagement) but
far better than random initialization.

`manifold_index.py` tracks retrieval quality EMA (exponential moving
average) and uncertainty per region of the behavioral space. Regions where
the current geometry is confidently calibrated produce high-confidence
matches. Regions where few labeled examples exist produce uncertain ones.
This uncertainty is what drives match ranking — not raw distance, but
distance-under-uncertainty.

## Security Model: Genuine Recording from Mobile

### The Problem
The oracle must verify that a recording genuinely came from the device's camera/microphone and was not fabricated (a pre-recorded file, AI-synthesized audio, etc.).

### The Solution: Four-Layer Chain

**Layer 1: APK Integrity**
- App binary hash committed on-chain at enrollment time
- Android Key Attestation: StrongBox records which app (by signing cert) generated the recording key
- Verified boot state in attestation certificate — rooted device (unlocked bootloader) is detectable at the hardware level and rejected at enrollment

**Layer 2: Isolated Process**
- Recording runs in an Android isolated process with no filesystem access, no network access, no debugger access
- OS cannot intercept the camera/microphone buffer
- Hardware-protected media path (repurposed DRM infrastructure): camera feed → protected buffer → isolated process → feature extraction

**Layer 3: Acoustic Watermark**
- The phone embeds a PRBS carrier signal at -48 dBFS in voiced frames only
- Carrier is seeded with: `SHA256("safta-watermark:" + session_key + ":" + timestamp_ms + ":" + device_pubkey)`
- Session key is generated by StrongBox at session start — hardware-bound, not extractable by OS
- The oracle verifies watermark correlation over voiced frames (threshold table adapts to codec)
- A recording not captured through the SAFTA pipeline will not have the correct watermark because the seed requires the session key

**Layer 4: StrongBox Attestation**
- After feature extraction, StrongBox signs: `SHA256(feature_vector || model_hash || slot || nonce)`
- The attestation certificate chain proves: locked bootloader + known APK signing cert + genuine StrongBox
- `attestation_hash = SHA256(signed_feature_vector)` committed on-chain
- Oracle verifies the full chain before evaluating evidence

### Threat Model
**Protected against:** Application-layer fabrication, pre-recorded files, OS-level interception, rooted devices, APK modification.

**Not protected against:** Hardware-level attacks (extracting StrongBox key from secure element) — requires nation-state-level resources, outside threat model.

## Privacy Architecture

### What Leaves the Device
| Data | Destination | Encrypted | Reversible |
|------|-------------|-----------|------------|
| Signed feature vector | device (served via libp2p) | No | No — abstracted |
| Behavioral signature | local laptop store | No | No — eigenvectors |
| KG sketch | local laptop store | No | No — MinHash |
| Engagement vectors | local laptop store | No | No — statistics |
| Palace content | local laptop (ChromaDB + SQLite) | Yes | Only with device key |
| AAAK digest (sync) | Laptop (local, no encryption) | No | Partial |

### What Never Leaves the Laptop
- Raw audio/video
- Session content (transcripts before feature extraction)
- Palace full content (ChromaDB verbatim storage)
- Private weight vectors for matching composition matrix

### Three DAGs

### DAG 1: Per-Session (On-Device)
```
Camera/microphone → isolated process
  → Whisper + prosody extraction
  → StrongBox signs feature vector
  → ACCUMULATE: update (μ, C, n) via Chan's formula
  → PALACE UPDATE: new KG triples + engagement vectors
  → signed feature vector → served over libp2p on demand
  → attestation_hash → Solana EvidenceSubmission
```

### DAG 2: Matching (laptop daemon tasks)

Runs on the laptop. Device records and submits attestation_hash to Solana — that is all the device does. KG extraction, accumulator updates, behavioral signature computation, and all matching happen on the laptop after sync.

```
Note: behavioral signature is a coarse public pre-filter only. Semantic matching
requires both parties' entity embeddings decrypted simultaneously inside the TEE.
Neither device OS nor any third party ever sees the other's entity embeddings in
plaintext. Only `combined_score_bps` and blinded pseudonyms exit the TEE.


Phase 1 match_project (O(N)):
  reads signatures from local laptop store
  pseudonym = SHA256(device_key || category_hash || pop_version)
  LSH projection → BucketAssignment PDA (keyed by pseudonym, not device key)
  unlinkable across categories and pop_version updates

Phase 2 match_compare (O(K²) per bucket, parallel):
  reads all signatures in bucket from local laptop store
  pairwise pyramid match kernel:
    behavioral_score: pyramid_match_kernel(sig_A, sig_B)
    semantic_score:   cosine(room_embeddings_A, room_embeddings_B)
    engagement_score: cosine(engagement_vectors_A, engagement_vectors_B)
    structural_score: Jaccard(kg_sketch_A, kg_sketch_B)
  composite = composition_matrix × [b, s, e, k]
  bilateral_score = harmonic_mean(score_A→B, score_B→A)
  above threshold → MatchNotification pair
```

### DAG 3: Population Aggregation (laptop daemon, periodic)
```
All device (μ, C, n) from local laptop store
  → DP: calibrated Gaussian noise on each contribution (ε-DP)
  → threshold mixing: K=5 nodes, T=3 required (not a honeypot)
  → Chan aggregation → pop_C
  → eigendecomposition → LSH hash family
  → write to local laptop store
  → commit composition_matrix_hash to IntentIndex PDA
  → increment pop_version
```

### Matching Dimensions

Four dimensions that must all align to reduce false positives:

| Dimension | What it measures | Why it matters |
|-----------|-----------------|----------------|
| Behavioral signature | Outlier eigenvectors of `(C_device - pop_C)` | How you are in the world |
| Semantic room embeddings | Dense vectors over palace room content | What you think about |
| Engagement vectors | 6-dim depth/consistency per KG entity | Surface vs deep interest |
| KG structural sketch | MinHash over random walk sketches | How ideas connect |

### The Irreducible Gap
The **anchor compatibility** signal — whether the specific emotional memory anchoring your interest in a topic resonates with another person's — cannot be measured from signatures alone. This is detectable only through direct interaction. The matching system narrows the candidate pool. The Arena generates the training data. The system learns from interaction outcomes.

### Phone ↔ Laptop Sync

**No encryption on the local channel** — both devices are owned by the same user. 
The threat model (someone on the local network) is addressed by HMAC authentication, not content encryption.

**Protocol:**
1. Pairing: 6-digit code (valid 5 min), derives shared HMAC key via `SHA256(code + device_pubkey)`
2. Sync payload: StrongBox-signed AAAK-compressed daily digest + new KG triples + engagement updates
3. Laptop ingests via MemPalace MCP calls
4. Device rotation: new phone generates new pairing code; old key explicitly revoked by user action

**The device is the encryption boundary.** Content leaving the local network is encrypted. Content within it is HMAC-authenticated only.

