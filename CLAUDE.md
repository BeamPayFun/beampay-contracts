# beam-contracts

## Project Overview

BeamPay protocol contracts — a permissionless on-chain payment router for whitelisted ERC20 tokens and the chain's native asset (ETH/BNB). Deployable on BSC and Ethereum. `BeamPayRouter` is the only canonical contract; there is intentionally no proxy, no admin, no pause.

**Chain targets:** BSC Mainnet (56) / Ethereum Mainnet (1) / BSC Testnet (97)

## Stack

- **Build/Test/Deploy:** Foundry (forge)
- **Solidity:** 0.8.24, EVM target: cancun, optimizer runs: 200
- **No proxy, no upgrades.** `BeamPayRouter` is deployed once and is immutable for code; only parameters change, via a 7-day Timelock inside the contract.
- **Dependencies:** managed as git submodules in `lib/` (`forge-std` only — `BeamPayRouter.sol` is self-contained, no OpenZeppelin)
- **Code style:** Prettier with `prettier-plugin-solidity`, print width 120, 4-space indent

## Key Files

| File | Purpose |
|------|---------|
| `src/BeamPayRouter.sol` | Protocol core — `pay`, `refund`, fee/token/recipient governance, 7-day timelock |
| `script/BeamPayRouter.s.sol` | One-shot deploy script (no proxy) |
| `test/BeamPayRouterTest.t.sol` | Invariant + path tests against the load-bearing rules in CLAUDE.md |
| `foundry.toml` | RPC endpoints, verifier, compiler |
| `remappings.txt` | Import path aliases |
| `.env.example` | Environment variable template |

## Commands

```bash
# Init submodules (first time only)
forge install foundry-rs/forge-std --no-commit

# Build / test
forge build
forge test
forge test --gas-report
forge snapshot

# Format
forge fmt
forge fmt --check

# Deploy (BSC mainnet)
source .env
forge script script/BeamPayRouter.s.sol:BeamPayRouterScript \
  --rpc-url $BSC_RPC_URL \
  --private-key $PRIVATE_KEY \
  --etherscan-api-key $BSCSCAN_API_KEY \
  --broadcast --verify -vvv

# Verify manually
forge verify-contract <address> BeamPayRouter \
  --chain-id 56 --api-key $BSCSCAN_API_KEY
```

## Environment Variables

Copy `.env.example` → `.env`:

```
PRIVATE_KEY=           # deployer
BSCSCAN_API_KEY=       # verification
ETHERSCAN_API_KEY=
BSC_RPC_URL=           # BSC mainnet RPC
BSC_TESTNET_RPC_URL=
ETH_RPC_URL=
GOVERNANCE=            # governance multisig (constructor arg)
INITIAL_TOKENS=        # comma-separated whitelist tokens
INITIAL_RECIPIENTS=    # comma-separated fee recipients (1..20)
INITIAL_FEE_RATE=10    # bps, MUST be <= 10
```

## Load-Bearing Invariants (do not regress)

Mirrored from `../CLAUDE.md`. Each is a product property, not a code style preference:

1. Funds never held in contract — `pay()` is `transferFrom payer → merchant` + `payer → feeRecipient` direct, contract balance always 0.
2. `FEE_RATE_HARD_LIMIT = 10` bps is `constant`. Governance cannot exceed it.
3. No `pause`/`unpause`/`emergency*`/`disableToken`/`removeToken`. Token whitelist is add-only. `pay()` cannot be stopped post-deploy.
4. All parameter changes pass through 7-day `TIMELOCK_DELAY`: `propose*` → wait → `execute*` (anyone callable).
5. H-06 fix: order inside `pay()` is (a) try fee → recipient; (b) on failure, mandatory fee → merchant + `FeeRedirectedToMerchant`; (c) mandatory `amount - fee` → merchant. Invariant: `merchant_received + protocol_received == amount`.
6. CEI + `nonReentrant` on `pay()` and `refund()`.
7. ERC20 path: `safeTransferFrom` reverts on fail (mandatory legs); `trySafeTransferFrom` returns bool (speculative fee leg only). Both handle USDT-style ERC20s. Native path: `.call{value:}("")` with the same try/redirect/main-leg semantics; `nonReentrant` is the sole reentrancy defence on the native rail.
8. Refund (v1.3+ signature `refund(orderId, amount)`): token is read from stored `OrderRecord` — caller cannot specify a different token. Payer pulled from `OrderRecord` (H-03); cumulative refunded ≤ order amount; protocol fee never refunded.
9. Two-step governance handoff + `renounceGovernance`.
10. No `receive` / `fallback` — bare native transfers revert. Native value only enters via `pay()` / `refund()` and leaves in the same call; contract balance is always 0.
11. Native asset support (v1.3+): sentinel `NATIVE_TOKEN = 0xEeee…EEeE` (1inch convention) represents the chain's native asset and must be whitelisted via `addToken()` like any ERC20. `pay`/`refund` are `payable`: `msg.value == amount` on the native path; `msg.value == 0` on the ERC20 path.

When investigating "why is the code shaped this way", grep `BeamPayRouter.sol` for `H-0x` / `M-0x` / `L-0x` audit tags — those are intentional fix sites.

## Testing Patterns

```solidity
vm.createSelectFork("bsc");          // fork BSC mainnet
deal(token, holder, amount);         // mint mock balance
vm.startPrank(actor); ... stopPrank;
vm.warp(block.timestamp + 7 days);   // exit timelock window
```

Run one test:
```bash
forge test --match-test testFeeHardLimitIsConstant -vvv
```

## Pre-commit Hooks

Husky + lint-staged runs Prettier on `*.sol` before commit.

## Security & Analysis

- **Slither**: Static analysis via `pnpm slither` (config: `slither.config.json`).
- **Solhint**: Linting via `pnpm solhint` (config: `.solhint.json`).
- **Gas Snapshots**: Tracked in `.gas-snapshot`; CI enforces no unrecorded regressions via `forge snapshot --check`.
- **Invariant Tests**: Foundry invariant suite in `test/invariant/` verifies ledger invariants such as `merchant_received + protocol_received == amount` after every `pay()` call.
