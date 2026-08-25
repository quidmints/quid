# What is not done

Kept honest rather than aspirational: everything here is either untested,
unenforced, or a decision nobody has made yet. Anything that is finished is in
the commit log, not in this file.

Current state, so the gaps below have a baseline: 61 Rust unit tests and 53
suite tests, passing under fixtures and against forked mainnet alike. Every
instruction in the IDL is exercised by at least one test. `forge build` is
clean, the Seeker app typechecks, and there is no dead code.

## Blocked on a real crossing

**The bridge has never carried a message.** Both halves compile and the checks
that stand between a forged message and a mint are covered — peer, origin
chain, payload length, all of which run before `cpi_clear`. What follows them
is not: a delivered message needs DVN attestations and executor delivery, and
no fork produces those. Cloning the endpoint, ULN302, the DVN and the executor
gives the code, not the consensus.

Proving it needs devnet — this program against eid 40168, `Basket.sol` on a
matching testnet, DVNs configured on both sides, and a QD round trip observed
to land. Until then, treat the return leg as code that compiles rather than a
working bridge, and do not let the suite's coverage suggest otherwise.

**Both DVN config scripts are written but neither has been run.**
`evm/scripts/LZconfig.s.sol` and `svm/scripts/lz-config.ts` bind the send and
receive libraries before setting config — the step whose absence leaves an OApp
on the endpoint defaults while looking configured, which is how KelpDAO was on
1-of-1 when 116,500 rsETH left through a single compromised verifier — and then
require two DVNs from different operators in both directions. They compile and
typecheck; running them needs a deployment to point at.

**Devnet is blocked on funding.** The wallet
`4BYcGVBnvzPKT74wZaTE3aoaJTePZWunEDiji1EbkuNP` holds no devnet SOL and the
faucet is rate-limited, so the program cannot be deployed there. That is the
only thing between here and a real crossing: the code is written, the config
scripts exist, and `Basket.sol` needs a matching testnet deployment.

## Claims are amounts, not shares

A loss larger than everything the pool has earned reaches `total_deposits`,
which is an aggregate no individual claim tracks. Every depositor still claims
par against a pool that holds less, so withdrawing before a large loss and
returning afterwards is strictly profitable — the leaver keeps par, the stayers
absorb it. Resetting the tenure clock does not deter it: tenure governs
earnings, and what is being dodged is principal.

Ordinary borrower profit no longer reaches principal — premiums are what the
pool collected for carrying that risk, so they pay for it first, and
`a_loss_within_earnings_leaves_every_claim_backed` pins that. The gap is what
remains after earnings are exhausted, which is genuine impairment.

Closing it means `deposited_quid` becoming a share of the pool rather than a
fixed amount, so a mark-down reaches every claim at once and there is nothing
to step out of. The machinery already exists in miniature: `sol_yield_index`
is a per-unit accumulator applied lazily at each touch, and a NAV index is the
same shape used in both directions. It is a change to the accounting model
rather than a bug fix, which is why it is written down here rather than done.
`a_loss_beyond_earnings_is_not_yet_marked_to_claims` documents the exposure.

## Half-integrated premium

The base rate — this ticker's volatility against how full the pool is — is
integrated as it happens, so an interval is billed at the rates that ran over
it. The position-specific half is not: leverage and distance to the barrier
are read at settlement and applied across the whole window, even though both
move with price throughout it.

That half is smaller than the base, which measured 7.5x between a calm state
and a violent one, and it cannot be integrated the same way because it is
per-position rather than per-ticker — an index would need one accumulator per
position, which is the loop this design exists to avoid. Frequent touches keep
the error small, which is what `sweep` is for.

## Untested

- **`bebop_jam` is cloned but not deployed.** The flash path is proven on our
  side of the interface with the tests signing as `bebop_authority` directly.
  Nothing has exercised JAM calling us.
- **Kestrel beyond the round trip.** Parking and unparking work against the
  live program in fork mode. The buffer-floor edges, unwinding while the issuer
  is disabled, and partial unparks are not covered — fork mode makes these
  straightforward to write now.
- **The oracle path has not been attacked.** Staleness and TWAP-deviation
  bounds exist and read soundly; the vol-suppression attack is defended at the
  source. Nobody has tried to break them on purpose.
- **No concurrency or reentrancy work.** Solana's model makes EVM-style
  reentrancy unavailable, and the flash loan is bounded by the instruction
  sysvar within its own transaction, but neither has been probed.
- **The 983 tickers with no token on Solana** are priced and tradeable, and the
  suite exercises a handful of them.

## Unenforced

- **`svm/keypair.json` is the secret key for program
  `QDgHUZjtccRjKZ63MBvW8uzKR7qcqjpRfGhNSEGfDu9` and is committed on `main`.**
  Deleted on `dev` and gitignored, but it stays in history: anyone who has had
  read access can redeploy over that address. Treat it as compromised and
  rotate before any real deployment. Not done here because it changes the
  program ID everywhere and is a decision rather than a fix.
- **`SQUADS_MULTISIG_V4` is a bare `&str` that nothing checks.** `config.admin`
  is whoever called `init_config` and can be rotated to any pubkey, with no
  requirement that the destination is a Squads vault. Enforcing it means
  deriving `[b"vault", multisig, 0]` under the Squads program, which needs the
  multisig address — hardcode it the way the LayerZero endpoint is, or require
  the new admin to be owned by the Squads program, which blocks rotation to a
  plain wallet without naming a specific vault.

## Known and accepted

- **Conservation is exact** as of the SOL-carry fix: 131,800,000,264 owed
  against 131,800,000,264 held. The two-unit residue previously attributed to
  rounding in the partial take-profit path was mostly attributed carry that had
  no backing. The assertion is still a relative bound, since integer division
  in that path can legitimately leave a unit behind.
- **Native SOL deposits have no minimum** while SPL deposits require $100, so
  dust SOL deposits can create depositor accounts cheaply. An asymmetry of the
  kind that has been wrong every other time it appeared, and unfixed.
- **Fixture mode and fork mode are complementary.** Fixtures can mint balances
  for tokens whose authority we do not hold, which is the only way the USD*
  second-vault path runs; the fork cannot, so that leg skips there. Neither
  mode alone covers everything.
