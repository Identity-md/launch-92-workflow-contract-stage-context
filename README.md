# Cliffhanger — CLIF token and VestingCliff

Contracts for the Cliffhanger project launch on Sepolia (chain id 11155111).

| Contract | Source | ABI | Constructor |
| --- | --- | --- | --- |
| `CliffhangerToken` (launch token, CLIF) | `src/CliffhangerToken.sol` | `docs/abi/CliffhangerToken.json` | none |
| `VestingCliff` (application) | `src/VestingCliff.sol` | `docs/abi/VestingCliff.json` | `address token_` → `$token` |

## Build and test (offline)

```sh
forge build
forge test
forge fmt --check
```

`forge-std` is vendored as ordinary files under `lib/forge-std` (v1.9.7, `src/` only), so no network is
needed. `foundry.toml` pins solc 0.8.26, `bytecode_hash = "none"`, `ffi = false`, no filesystem permissions.

## CliffhangerToken (CLIF)

- Name `Cliffhanger`, symbol `CLIF`, 18 decimals.
- Zero-argument constructor mints exactly 1,000,000,000 CLIF (10^27 minor units) to `msg.sender`
  (the ProjectFactory at launch). `totalSupply` is `immutable`.
- No mint, burn, owner, admin, pause, blocklist, fee or upgrade path. Plain ERC-20 transfer/approve/transferFrom;
  an allowance of `type(uint256).max` is treated as infinite. Transfers to `address(0)` and approvals to
  `address(0)` revert.

## VestingCliff

Irrevocable CLIF vesting with a cliff.

### Rules

- `createSchedule(beneficiary, amount, cliff, end)` — the caller (funder) must have approved at least `amount`
  CLIF to the contract. The schedule's `start` is the creation block timestamp. Requirements:
  `amount > 0`; `beneficiary` is not `address(0)` or the contract itself; `start <= cliff <= end`; `end > start`.
  `cliff == start` means no cliff; `cliff == end` means everything unlocks at once at `end`.
  The contract checks it received exactly `amount` (fee-on-transfer tokens are rejected).
- Vested amount at time `t`:
  - `0` if `t < cliff`
  - `amount` if `t >= end`
  - otherwise `amount * (t - start) / (end - start)` (rounded down).

  So vesting accrues linearly from creation, but nothing is released before the cliff; at the cliff the
  portion accrued since `start` becomes claimable at once. **Assumption:** this is the standard
  "linear-from-start with cliff" reading of the brief (same as OpenZeppelin's VestingWallet with a cliff).
  If the product intends "linear from cliff to end" (zero at the cliff), the formula must change before launch.
- `claim(id)` — only the schedule's beneficiary; transfers all vested-but-unclaimed CLIF to the beneficiary.
  Reverts with `NothingToClaim` if nothing is claimable.
- Irrevocable: there is no revoke, cancel, withdraw, sweep, owner, admin, fee, pause or upgrade function.
  The funder has no rights after creation. Tokens sent to the contract outside `createSchedule` are stuck
  forever (no sweep by design).
- Beneficiaries cannot be changed. A beneficiary that cannot call `claim` (e.g. a contract without that
  ability) leaves its tokens locked permanently — funders must choose beneficiaries carefully.

### Views (for the website)

`token()`, `scheduleCount()`, `getSchedule(id)` (funder, beneficiary, start, cliff, end, amount, claimed),
`vestedAmount(id)`, `vestedAmountAt(id, timestamp)`, `claimableAmount(id)`, `schedulesOfBeneficiary(addr)`,
`schedulesOfFunder(addr)`, `totalLocked()` (sum of unclaimed amounts; equals the contract's CLIF balance
unless someone sends CLIF directly).

### Events

`ScheduleCreated(id, funder, beneficiary, amount, start, cliff, end)` and `Claimed(id, beneficiary, amount)`
are emitted for every state change.

### Security properties

- Checks-effects-interactions: all storage writes and events happen before the token call. A `nonReentrant`
  guard additionally blocks re-entry into `createSchedule`/`claim` from a malicious token (tested).
- The only external calls are to the immutable `token`. No ETH handling, no `delegatecall`, `callcode` or
  `selfdestruct`.
- Token calls accept bool-returning and no-return ERC-20s; a `false` return or revert rolls the whole call back.
- Timestamps come from `block.timestamp`; validators can shift them by a few seconds, which only affects
  vesting by seconds' worth of tokens. No randomness is involved.

## Tests

- `test/CliffhangerToken.t.sol` — metadata, supply, transfers, allowances, failure cases, absence of mint/admin
  selectors, fuzzed supply conservation.
- `test/VestingCliff.t.sol` — creation (storage, events, indexes), every input validation error, missing
  allowance/balance, the vesting curve at and around the cliff and the end, partial/full/repeat claims,
  unauthorized callers (stranger and funder), unknown ids, schedule isolation, absence of revoke/admin
  selectors, and a fuzz test for monotonic vesting and conservation of funds.
  `VestingCliffAdversarialTokenTest` covers re-entrancy through a malicious token during create and claim,
  fee-on-transfer rejection, false-returning tokens (no state change on failure) and no-return tokens.
- The protected launch floor (token supply, decimals, runtime opcodes, factory CREATE2 deployment of
  `VestingCliff` with the predicted token address) was also run locally and passes.

Passing tests are not an audit; the workflow requires an independent adversarial review before deployment.

## Deployment parameters (for the manifest and deployer services)

- Network: Sepolia, chain id 11155111. Deployment via ProjectFactory only; this repository contains no
  broadcast script, private key or funded wallet, and contributors do not deploy.
- Manifest: kind `evm_project`; launch token `CliffhangerToken`; contracts in order:
  1. `VestingCliff` with `constructorArgs: ["$token"]`.
- No `$owner` argument is needed: neither contract has any privileged role.
- Pool (policy terms, not a valuation): native ETH (zero address), fee 3000, tickSpacing 60, no hook,
  initialPrice `79228162514264337593543950336` (sqrtPriceX96). The factory seeds liquidity with CLIF only.

## Operational responsibilities

- Policy, signed artifact linkage, source publication, attestation, admission and deployment belong to the
  platform services, not to this repository.
- After deployment, the website reads addresses and ABIs from `dist/imd-deployment.json`; the ABIs in
  `docs/abi/` are the source for those.
- There is nothing to operate on-chain after deployment: no keys, no admin actions, no upgrades. Users must
  understand that schedules are irrevocable and beneficiaries are fixed.
