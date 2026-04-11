
Bebop jazz replaced the big band's arranged harmony with   
small ensembles improvising over complex chord changes at high tempo.

Bebop.xyz chose a name that represents intent-based hops.  
Every stablecoin in the basket is in a *quid pro quo*:  
mutual redemption pressure relief, peg stability, etc.    

The Signal Foundation started on a promissory note...    
on similar terms, [MetaWeb Capital backed a meta-stable](https://etherscan.io/tx/0xa3e778f0053e07bc5a955a1bafaf5de625494f9bd7516c6264305b309b756a93).   

QU!D LTD is a BVI entity owned by Quid Labs,    
a Cayman IBC whose parent is [QuidMint Foundation](https://gitlab.com/quidmint/quid/-/blob/main/docs/AA.pdf)  

"May it be your journey on to light the day."  
The entities were founded on the cusp of the Terra crash,  
withstanding first-hand experience of collateral damage:   

under FASB ASC 958 nonprofit accounting principles,   
accumulated deficit that exists on the balance sheet  
as a documented liability against future operations.  

*"We understand you are cracked, ser, but there is no warranty for jailbroken devices..."*  

Heard that one before. One thing they won't ever tell you at the Genius bar is,  
why hasn't Siri improved much despite breakthroughs in AI. "Beg your pardon?"   

## GENIUS Act

The GENIUS Act was passed to address a specific and documented failure mode in stablecoin infrastructure:  
issuers holding reserve assets external to the stablecoin itself that could fail to maintain 1:1 backing under stress.  

The question is not whether QU!D qualifies as a permitted issuer under the Act,  
or even whether any other design could be better qualified.

The basket composition at redemption of 1 ERC20 (QD)  
varies with live market conditions, but the dollar value is invariant.

The basket generates no endogenous yield, only exogenously  
through Uniswap, AAVE, Morpho, and the 10 stablecoin vaults.  

Closer to an ETF or money market fund share,  
aggregating existing monetary instruments   
issued by third parties into a redeemable unit.

The basket's pass-through yield originates  
from the reserve income of each constituent  
stablecoin issuer's in the basket:    
FRAX's monetary premium,  DAI's DSR,    
sUSDe's funding basis, etc.  

This analysis aligns with the Commodity Futures Trading Commission's   
historical treatment of basket instruments backed by physical commodities  
and with recent SEC staff guidance distinguishing utility from investment characteristics.

Section 3(a)(1)(A) of the ICA defines an investment company  
as any issuer that is primarily engaged in the business of investing in securities.  

Whether basket-constituent stablecoins are "securities" for ICA purposes  
is itself unresolved — the GENIUS Act explicitly excludes compliant payment stablecoins  
from the definitions of "security" under the Securities Act of 1933 and the Securities Exchange Act of 1934.   
If the underlying basket constituents are not securities, the ICA's primary classification trigger does not apply.  

Depositors commit capital today and receive a claim on future value,   
sized at entry, contingent on the basket's performance over the maturity period.  

DCF secondary market pricing insinuates a warrant-like resemblance —  
a locked claim trading at a discount to face value as maturity approaches.

Section 4(a)(1)(A) requires that capital requirements *"may not exceed what is sufficient to ensure the permitted payment stablecoin issuer's ongoing operations,"* and liquidity standards *"may not exceed what is sufficient to ensure the ability of the issuer to meet the financial obligations of the issuer, including redemptions."*

These proportionality constraints are written into the statute  
because the regulation targets a gap which doesn't exist for QU!D.  

With that said, QU!D addresses the regulatory concern more completely   
than the Act's own requirements do, which makes the Act's compliance   
apparatus proportionally lighter for QU!D rather than inapplicable.  

Hayek's original argument in "The Use of Knowledge in Society" (1945) is that no central authority — including a regulator or an auditor — can replicate what a price mechanism does: aggregate dispersed private information held by millions of individual actors who each know something the others don't.   

A PCAOB-reviewed monthly attestation is a central authority making a backward-looking determination.
They tell a regulator what the reserve composition was at a point in time.   
They cannot tell a regulator in real time whether that composition is adequate given current market conditions.   

A prediction market pricing depeg probability in real time is a decentralised mechanism aggregating  
every piece of privately held information about reserve quality at every moment.  
**That's how GENIUS Act's reserve sufficiency requirement should be operationalised.**  

Participants with private knowledge about reserve quality trading against each other, rendering prices that reflect their aggregate judgment continuously.
The legal argument that follows is not that the GENIUS Act's requirements are inapplicable. It is that the depeg prediction market provides a strictly superior form of the proof the Act requires — continuous rather than monthly, forward-looking rather than backward-looking, aggregating dispersed private information rather than relying on a single auditor's determination — and that the Act's own proportionality standard at Section 4(a)(1)(A) produces lighter requirements for an issuer that has implemented a superior proof mechanism.
The Act was designed for issuers who have no market-based mechanism for demonstrating reserve sufficiency in real time.

### Section 4(a)(1)(A)

Sets a ceiling on what regulators can require of issuers — capital requirements may not exceed what is sufficient for ongoing operations.  
It is a constraint on regulatory overreach, however, not a definition of what capital reserves are for in general.

The `untouchables` tranche is not a capital reserve in the regulatory sense at all.  
It is a cost-recovery mechanism for a documented accounting loss from years ago...   

Collateral damage absorbed in the course of research and development  
is projected to be fully amortised (breakeven) as part of "**fair launch**":

from the basket's perspective, `untouchables` represent a senior liability to seed funders,  
structurally subordinating regular depositor claims below it at the accounting level  
while preserving regular depositors' dollar-equivalent redemption guarantee intact  
because the 1:1 peg is fully maintained on their portion (excl. the tranche).  

From the moment that QuidMint's accumulated deficit is fully amortised...     
preferrential treament in the`mint` function of Basket.sol ceases to exist:  
it is not fee income, not yield extraction, and not profit distribution.

A restoration of the entity's net asset position to zero, which is   
the definitional objective of nonprofit accounting.   

No profit is generated until the accumulated deficit  
is fully recovered, and the tranche is sized to achieve exactly that recovery — no more.

The tranche is an issuance spread — the difference between the dollar deposited   
and the QD issued — which is standard in any *instrumentos quidados*  
that has a spread between issue price and face value.  

The liability column of `untouchbales` in Basket.sol is not simply a tranche  
of deposited stablecoin value set aside. It is QD minted on underbacked terms:  
seed funders receive QD with the multiplier (up to 2x) without that QD being  
fully backed by an equivalent dollar value in the basket at the time of minting.  

The QD exists as a liability before the backing exists for it.  
Aux.sol's asset column of `untouchables` is what capitalises  
that underbacked liability and makes it whole over time. The two    
legs existing simultaneously is what allows the mechanism to work.  

The breakeven structure also does something Howey analysis alone cannot do —   
it removes QU!D from the category of entities with a profit motive  
with respect to the basket's output.

Howey prong 3 was designed for promoters  
who extract value from investors' capital  
through ongoing managerial decisions...  

QU!D's managerial role ends at deployment  
and initial LP attraction. After that,   

no QU!D decision determines   
what the basket produces...  

No one can upgrade the rebalancing logic,   
doing so would require a new deployment    
and manual migration by depositors themselves.

## Prohibition Незбагненний

Section 4(a)(11) of Public Law 119-27:

> *"No permitted payment stablecoin issuer or foreign payment stablecoin issuer shall pay the holder of any payment stablecoin any form of interest or yield (whether in cash, tokens, or other consideration) solely in connection with the holding, use, or retention of such payment stablecoin."*

The prohibition exists for a specific policy reason articulated in the CSBS implementation comment letter: to "disincentivize the holding of large uninsured stablecoin balances, which could trigger deposit flight out of the banking system." The concern is issuers using their own reserve income — Treasuries yield, repo income, bank interest — to pay depositors returns that make stablecoins function as uninsured deposit substitutes, destabilizing the banking system by attracting capital away from insured deposits.

The basket holds yield-bearing instruments, generating income  
under the independent governance of the instruments' respective  
protocols. QU!D holds these instruments without discretion over  
their respective rates, and without risking QU!D's own capital  
(i.e. `untouchables`) to produce said rates.  

Upon minting QD (basket shares) in exchange for their dollars, depositors accept a binding surrender of redemption optionality for a defined term — precisely the material economic risk the CSBS implementation letter identifies as the permissibility threshold: *"any payment should require a holder to engage in effort or accept risks beyond the ordinary course of holding, using, or retaining a payment stablecoin."*

The depositor accepts illiquidity, basket composition risk over the lock period, and secondary market exit at DCF valuation as their only path to early liquidity — alongside productive deployment as collateral in synthetic positions (e.g. stocks, commodities, etc.) or prediction market exposure.

Arguments around "solely" are belt-and-suspenders on the yield question. Section 17 is the reason that question may never need to be litigated at all.

### Section 17 exclusion

Not a substitute for the Howey analysis. It is a statutory roof built on top of a successful Howey prong 3 defense.  
Understanding the correct sequence matters because the payment stablecoin definition itself contains a circular constraint:  

a digital asset that is a security cannot qualify as a payment stablecoin.  
Section 17 therefore never attaches to an instrument that is already a security.

**Howey must be resolved first 🔱**

**Prong 1 — Investment of money:** Satisfied. Depositors exchange stablecoins for QD. This cannot be argued away.

**Prong 2 — Common enterprise:** Likely satisfied under horizontal commonality. All QD holders share the same basket composition and performance pro-rata. This is pooling. The correct strategy is not to contest this prong but to win decisively on prong 3. By 2024, the SEC and Southern District had effectively collapsed prongs 2 and 3 into a single inquiry — whether profits depend on the promoter's efforts — making prong 3 the operative question in any enforcement context.

**Prong 3 — Expectation of profits from the efforts of others:** This is where QD's architecture provides  
its strongest defense, and where the breakeven structure does something no Howey argument alone can accomplish.

The precise legal question is whose *ongoing managerial efforts* are the undeniably significant ones — those essential to the failure or success of the enterprise.
QU!D's efforts are limited to two moments: deployment of the contract, and initial LP attraction through the seed funder mechanism.

After those two acts, QU!D makes no ongoing managerial decisions that steer profitability,  
especially not in any way that is materially more significant than the governance decisions  
of the constituent protocols within the basket.  

The gross on-chain product flowing to QD depositors is determined entirely by independent governance decisions of independent protocols — FRAX's AMO governance, MakerDAO's DSR, Ethena's delta-neutral position management — operating under independent incentive structures with no direction from QU!D.

The Ninth Circuit's 2025 decision in *SEC v. Barry* confirmed that the operative test   
is whether the manager's *ongoing* efforts steer the project toward profitability...   
Deployment and initial bootstrapping are ongoing efforts...until they are fulfilled.

It cannot be steered toward profitability by any managerial decision because no managerial decision  
can accelerate or expand the recovery beyond what the `untouchables` mechanism represents. A promoter   
whose enterprise produces no profit until a specific, documented, terminating threshold is crossed  
and whose distribution mechanism is enforced by contract rather than discretion — is not the kind of  
promoter Howey's prong 3 was designed for. (requires an expectation of profits from the issuer's efforts).

During the seed funder phase, QU!D's enterprise produces no profits.  
After breakeven, the `untouchables` mechanism terminates   
and QU!D has no further extraction mechanism at all.  

The secondary market severs the remaining thread. *SEC v. Ripple Labs* distinguished institutional sales — where buyers specifically relied on the issuer's efforts — from programmatic secondary market sales where anonymous buyers cannot know whose efforts produce returns and therefore cannot form the expectation prong 3 requires. QD's DCF-priced secondary market is analogous: secondary buyers acquire a discount instrument whose value is determined by basket mechanics and time-to-maturity, not by any QU!D managerial decision made after deployment.

**The sequential conclusion:**

QD fails Howey prong 3 because returns are generated by the independent managerial efforts of the constituent protocols, not by QU!D.  
That failure of prong 3 means QD is not an investment contract. Non-security status means QD qualifies as a payment stablecoin under the GENIUS Act definition.

Section 17 then converts that qualification into a statutory guarantee across six federal statutes simultaneously — the Securities Act of 1933, the Securities Exchange Act of 1934, the Investment Advisers Act of 1940, the Investment Company Act of 1940, the Securities Investor Protection Act of 1970, and the Commodity Exchange Act.

Section 17 also clarifies that permitted payment stablecoin issuers are not investment companies,   
removing ICA exposure without requiring reliance on Section 3(c)(1) or 3(c)(7) exemptions.

The structural arguments in Sections II through IV are not merely regulatory positioning — they are the conditions under which this sequential logic holds at every step.
Lose the Howey prong 3 defense and Section 17 never attaches. Lose the payment stablecoin classification and the full securities analysis is inherited simultaneously.

The current enforcement environment reinforces this conclusion. SEC Chair Atkins stated publicly in July 2025 that only a limited number of crypto assets should be treated as securities under federal law, and the agency has dismissed many pending Digital Cases inconsistent with current policy. The Howey analysis should nevertheless be documented now precisely because enforcement environments shift — and QD's architecture holds under the most demanding version of that analysis regardless of who is enforcing it.

The virtual upfront `normalized` allocation in the `mint()` function of Basket.sol further compounds this distinction. What depositors receive at entry is not a current cash payment of interest. It is an accrued entitlement — a forward-looking claim on future basket yield, computed at entry and redeemable at the chosen maturity.

The CSBS implementation comment letter, interpreting Section 4(a)(11)'s scope, specifically distinguishes "irregular or unpredictable payments" from structured accrual entitlements tied to maturity choices. A depositor who selects a longer maturity accepts lock-up risk in exchange for a larger claim on future basket yield. This is option-like compensation for a commitment decision, in the category of capital allocation rights rather than issuer payments.

The GENIUS Act's language at Section 4(a)(1)(A) provides that capital requirements "may not exceed what is sufficient to ensure the permitted payment stablecoin issuer's ongoing operations." While QU!ID is not a a stablecoin issuer per se and this provision may or may not govern it directly, the principle it codifies — that capital retention is legitimate when calibrated to operational necessity — applies to basket managers by analogy and supports QU!ID's position in any regulatory dialogue about the `untouchables` tranche's purpose.
