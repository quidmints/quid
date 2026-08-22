# SOL* / Kestrel `long_yield_carry` — verified interface (NOT integrated)

Removed from the program on purpose: SOL* is **Kestrel-issued, not Perena-issued**,
so holding it means depending on a second counterparty. This file keeps what was
established empirically, so the work is not lost if the decision is revisited.

## The issuer fact

| | mint | authority | issuer |
|---|---|---|---|
| USD* | `star9agSpjiFe3M49B3RniVU4CMBBEK3Qnaqn3RGiFM` | `ECJGrTZ6QYMEwiEAnL4oReWF126uc22e9Lojy9qyCjHT` | Perena |
| SOL* | `FDhu9642aPYNnbTnSoHdAsR9tgSxftPDPjEVdbD58nP2` | `6MSD4oSiJq8y5hmryCuMykyTjNXbhha6HSAtrT1EFKQe` | Kestrel LYC Token PDA |
| BTC* | `YXyMDi4y5aUDmxUFgUvxbm2hXR945yhYaoY9nFnM1KN` | (LYC Token PDA) | Kestrel |

On-chain metadata confirms `FDhu9642…` = "SOL Star" / `SOL*`. Perena is the brand
and front-end; Kestrel's `long_yield_carry` is the issuer. Inspected real user
mints: top-level programs are ComputeBudget + System + ATA + Token + `LYC8Yi…`.
**No Perena program appears in a SOL* mint at all** — their app builds LYC
instructions client-side via `@kestrelfi/lyc-sdk`. There is nothing to CPI into.

## Addresses

- program (prod) `LYC8YiiSzQfPpxUW2tpxfuPKGZwywAJhXKUfDP2B66f`, test `7C39GeKrqLygmgV9D4bicUaiyFhKrX6Eevk6PDACwuj7`
- SOL market Token PDA `6MSD4oSiJq8y5hmryCuMykyTjNXbhha6HSAtrT1EFKQe` (seeds `["TOKEN", mint, id]`)
- collateral vault `DHxRiKmKZn8eEUsqJrwSpHcmMthLXEbsLfYDZMHBKP9B` = ATA(TokenPDA, wSOL)
- collateral oracle `7UVimffxr9ow1uXYxsr4LHAcV58mLzhmwaeKvJ1pjLiE` (Pyth SOL/USD)
- account discriminators: `token` `[131,254,39,144,4,179,134,127]`

## Instruction shapes (from their IDL, verified by execution)

`mint_token` disc `[172,137,183,14,207,110,234,56]`, arg `deposit_amount: u64`:

| # | account | flags |
|---|---|---|
| 0 | signer | signer |
| 1 | token | writable |
| 2 | mint (yToken) | writable |
| 3 | collateral_mint (wSOL) | — |
| 4 | user_collateral_account | writable |
| 5 | user_token_account | writable |
| 6 | collateral_token_account | writable |
| 7 | token_program (yToken ops) | — |
| 8 | collateral_token_program | — |

`burn_token` disc `[185,165,216,246,144,31,70,74]`, arg
`BurnTokenParams::{Sync{burn_amount:u64} (discriminant 0) | Async{..}}`:
signer, payer(s,w), token(w), mint(w), user_token_account(w), collateral_mint,
user_collateral_account(w), **collateral_token_account(w)**, then three optional
async accounts (redemption_epoch, request, request_token_account — pass the
program's own id for `None`), token_program, collateral_token_program,
associated_token_program, system_program.

## Two bugs the fork caught (both invisible to `cargo check`)

1. yToken mint declared read-only in our Accounts struct → *"writable privilege
   escalated"*; `mint_token` does a MintTo so it must carry `mut`.
2. `collateral_token_account` passed read-only to `burn_token` → their
   `ConstraintMut`. Parse IDL flags per-account; a fixed-width regex window
   truncated before this account's `writable: true`.

## Economics measured on a mainnet fork

- 2 SOL → 1_980_040_988 SOL* (≈1.0101 SOL per SOL*, carry already in share price)
- burning 990_020_494 shares returned 0.996004 SOL
- **~40 bps round trip** in mint/burn holder fees ⇒ ~17 days of carry at ~8.5% APY
  just to break even. Any parking scheme needs a wide deadband and a min hold.
- their unlent reserve (what a `Sync` burn is paid from) was **40.86 wSOL** —
  a redemption larger than that reverts and waits on their manager.

## Reproducing the fork

Stock `solana-test-validator` 4.0.0 **aborts** on this clone set; use the repo's
own agave build (`~/Documents/agave/target/release/solana-test-validator`):

```
--url https://api.mainnet-beta.solana.com \
--clone-upgradeable-program LYC8YiiSzQfPpxUW2tpxfuPKGZwywAJhXKUfDP2B66f \
--clone 6MSD4oSiJq8y5hmryCuMykyTjNXbhha6HSAtrT1EFKQe \
--clone FDhu9642aPYNnbTnSoHdAsR9tgSxftPDPjEVdbD58nP2 \
--clone So11111111111111111111111111111111111111112 \
--clone DHxRiKmKZn8eEUsqJrwSpHcmMthLXEbsLfYDZMHBKP9B \
--clone 7UVimffxr9ow1uXYxsr4LHAcV58mLzhmwaeKvJ1pjLiE
```
