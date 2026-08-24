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

**The Solana DVN config script does not exist.** The EVM half is written and
compiles: `evm/scripts/LZconfig.s.sol` binds send and receive libraries before
setting config — the step whose absence leaves an OApp on the endpoint defaults
while looking configured, which is how KelpDAO was on 1-of-1 when 116,500 rsETH
left through a single compromised verifier. The Solana side needs the same:
`SetConfigType::SEND_ULN` and `RECEIVE_ULN` with two required DVNs. The SDK is
installed and verified loadable, and there are 28 live DVNs on Solana —
LayerZero Labs at `4VDjp6XQaxoZf5RGwiPU9NR1EXSZn2TP4ATMmiSzLfhb` and Google at
`F7gu9kLcpn4bSTZn183mhn2RXUuMy7zckdxJZdUjuALw` mirror the EVM pair.

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

- **Conservation holds to two units on 131.8bn**, which is the documented
  residue: the partial take-profit path rounds `pledged_reduce` and lets
  `T_delta` absorb the difference. Watched by a relative bound rather than
  demanded exact.
- **Native SOL deposits have no minimum** while SPL deposits require $100, so
  dust SOL deposits can create depositor accounts cheaply. An asymmetry of the
  kind that has been wrong every other time it appeared, and unfixed.
- **Fixture mode and fork mode are complementary.** Fixtures can mint balances
  for tokens whose authority we do not hold, which is the only way the USD*
  second-vault path runs; the fork cannot, so that leg skips there. Neither
  mode alone covers everything.
