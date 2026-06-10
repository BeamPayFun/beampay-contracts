# BeamPay Smart Contracts

English | [简体中文](./README.zh-CN.md)

> A **permissionless, non-upgradeable, never-freezable** on-chain payment router. Merchants accept stablecoin / native-asset payments with a single contract call; the protocol fee is capped at 0.1% (currently **0%** on mainnet), and the contract itself never holds funds.

---

## 📌 BeamPay in One Sentence

**BeamPay = an on-chain Stripe Connect, with the "platform rug-pull" and "account freeze" risks removed.**

| Traditional payment rail | BeamPay |
|---|---|
| Funds enter the platform's account first, then settle to the merchant | Funds go from the payer **directly to the order's signed payout address (`receiver`, usually the merchant's wallet)** — the contract never touches a cent |
| Platform can freeze, pause, change the rules | Contract has **no custodial admin, no pause button, no delisting** — governance can only add tokens / recipients and tune the fee within the hard cap |
| Fee rate adjustable at any time | Fee ceiling **hard-coded at 0.1%** (cannot be exceeded at the contract level) |
| Refunds depend on customer support | Merchants issue partial / full refunds directly on-chain |

---

## 🎯 For Business People: What BeamPay Gives Merchants

### 1. Fund safety: the contract never stores money

Every `pay()` call is **atomic**:

```
Payer wallet → receiver (amount - fee)
Payer wallet → protocol fee recipient (fee)
```

> `receiver` is the payout address the merchant signs into each order at creation time (per-order since v1.4) — typically the merchant's own wallet.

The moment the transaction completes, **the router retains none of the payment** — funds enter and leave in the same transaction. Which means:
- Platform rug-pull? — there's no money in the contract to run away with
- Contract gets hacked? — there's no money in the contract to steal
- Regulator freezes the contract? — there is no "freeze" function to invoke

### 2. Fee ceiling: baked into the bytecode

The protocol fee cap is **10 basis points (0.1%)**, declared as a Solidity `constant` (compile-time), so it lives in the contract bytecode.

> Even the governance multisig **cannot** raise this ceiling. Changing it requires deploying a brand-new contract (= new address, new trust).

The effective rate (≤ 0.1%) is governance-adjustable, but any rate change must pass the 7-day waiting period below. **Mainnet currently runs at 0 bps (0%)**; testnet runs at 10 bps.

### 3. Transparent governance: fee changes go through a 7-day timelock

A fee-rate change takes two steps:

1. **`proposeFeeChange`** — the governance multisig submits a proposal; an on-chain event makes it public
2. **wait 7 days**
3. **`executeFeeChange`** — callable by anyone (not just governance)

Merchants and users get a full 7 days to audit the change and exit if needed.

> The token whitelist (`addToken`) and the fee-recipient list (`addFeeRecipient` / `removeFeeRecipient`) are immediate `onlyGov` calls — **no timelock** — but their blast radius is bounded by the contract's structure: the whitelist is **add-only** (no supported token can ever be delisted), and no matter who the recipients are, the fee **can never exceed the 0.1% hard cap**.

### 4. Unstoppable: payments can never be switched off

The contract has **none** of these functions:
- ❌ `pause()` / `unpause()`
- ❌ `emergencyStop()`
- ❌ `disableToken()` / `removeToken()`

The token whitelist is **add-only**. Once deployed, `pay()` stays available **forever** — until the chain itself stops producing blocks.

### 5. Refunds: the merchant stays in control

Merchants issue refunds on-chain via `refund(orderId, amount)`:
- **Partial refunds** supported (cumulative refunds may not exceed the original order amount)
- Refunds can only go back to **the original payer address** (the on-chain record is tamper-proof)
- **The protocol fee is not refunded** (fees already routed out are not clawed back)

### 6. Multi-chain, multi-token: one address on every chain

| Chain | Router address | Supported tokens |
|---|---|---|
| Ethereum Mainnet (chainId 1) | `0xBEA93fceFb115b22a3D6c714Ee815B359e2AAbaa` | ETH (native) + USDT, USDC |
| BSC Mainnet (chainId 56) | `0xBEA93fceFb115b22a3D6c714Ee815B359e2AAbaa` | BNB (native) + USDT, USDC |
| BSC Testnet (chainId 97) | `0xBEA93fceFb115b22a3D6c714Ee815B359e2AAbaa` | tBNB + tUSDT/tUSDC (test tokens, free to mint) |

The router is deployed via **CREATE3 (CreateX factory) with a fixed salt**, giving it **the exact same address on every chain**.

Native assets (BNB/ETH) are represented by the conventional sentinel address `0xEeee...EEeE` and are whitelisted and settled like any ERC20 (the native path additionally requires `msg.value == amount`).

---

## 🛡️ Security Promises (Load-Bearing Invariants)

The following invariants hold **forever** and are continuously verified by the test suite:

| # | Invariant | What the merchant gets |
|---|---|---|
| 1 | Contract balance is always 0 | No stranded funds, no freeze risk |
| 2 | `FEE_RATE_HARD_LIMIT = 10 bps` is `constant` | Protocol fee ceiling forever ≤ 0.1% |
| 3 | No pause / no removeToken | Payments never go offline; tokens are add-only |
| 4 | Fee-rate changes pass a 7-day timelock | Ample audit window (other governance ops are immediate but bounded by invariants 2 & 3) |
| 5 | `receiver_received + protocol_received == amount` | Exact, dust-free settlement accounting |
| 6 | CEI + `nonReentrant` | Reentrancy defence |
| 7 | Compatible with non-standard ERC20s like USDT | Works even when `transfer` returns no bool |
| 8 | Refund token is read from the stored order record | Callers cannot forge the refund token |
| 9 | Two-step governance transfer + `renounceGovernance` | Governance can be renounced for good (a truly ownerless contract) |
| 10 | No `receive` / `fallback` | Stray native transfers revert — funds can't get stuck |

---

## 🔧 For Developers: How to Integrate

### Stack

- **Solidity** 0.8.28 (EVM target: Cancun, via-IR, optimizer runs: 200)
- **Build tool**: Foundry (forge)
- **Dependencies**: `forge-std` + OpenZeppelin (`EIP712`, `ECDSA` for order-signature verification; both as git submodules)
- **Code style**: Prettier + prettier-plugin-solidity

### Project layout

```
beampay-contracts/
├── src/
│   ├── BeamPayRouter.sol         # Protocol core: pay / refund / governance / timelock
│   ├── interfaces/               # External interfaces
│   └── mocks/                    # Test tokens (BeamMockERC20)
├── script/
│   ├── BeamPayRouter.s.sol       # Plain deploy script (dev only)
│   ├── DeployCreate3.s.sol       # CREATE3 production deploy (same address cross-chain)
│   ├── MineSalt.s.sol            # CREATE3 salt mining (vanity address)
│   └── DeployMocks.s.sol         # Test-token deploy (reverts on mainnet)
├── test/
│   ├── BeamPayRouterTest.t.sol   # Path tests + invariant tests
│   ├── BeamPayRouterSigned.t.sol # Signed-order (EIP-712) tests
│   └── invariant/                # Foundry invariant suite
├── deployments/                  # Deployed addresses per chain (one file each)
├── broadcast/                    # forge deploy broadcast records
├── lib/                          # git submodules (forge-std, openzeppelin-contracts)
├── foundry.toml                  # RPC / verifier / compiler config
├── remappings.txt                # Import path mappings
└── .env.example                  # Environment variable template
```

### Deployed addresses

The router lives at **the same address on every chain** (CREATE3 deterministic salt):

| Contract | Chain | Address |
|---|---|---|
| BeamPayRouter (v1.4) | ETH Mainnet | [`0xBEA93fceFb115b22a3D6c714Ee815B359e2AAbaa`](https://etherscan.io/address/0xBEA93fceFb115b22a3D6c714Ee815B359e2AAbaa#code) |
| BeamPayRouter (v1.4) | BSC Mainnet | [`0xBEA93fceFb115b22a3D6c714Ee815B359e2AAbaa`](https://bscscan.com/address/0xBEA93fceFb115b22a3D6c714Ee815B359e2AAbaa#code) |
| BeamPayRouter (v1.4) | BSC Testnet | [`0xBEA93fceFb115b22a3D6c714Ee815B359e2AAbaa`](https://testnet.bscscan.com/address/0xBEA93fceFb115b22a3D6c714Ee815B359e2AAbaa#code) |
| tUSDT (mock, 6 decimals) | BSC Testnet | [`0x0c6DfFCbb941d2fDec9c8107e8128dcb6651951c`](https://testnet.bscscan.com/address/0x0c6dffcbb941d2fdec9c8107e8128dcb6651951c#code) |
| tUSDC (mock, 6 decimals) | BSC Testnet | [`0x44a25C4cbe72a249866B6750F8594ba170a653fC`](https://testnet.bscscan.com/address/0x44a25c4cbe72a249866b6750f8594ba170a653fc#code) |

Full deployment records (constructor args, deploy txs, historical addresses) live under [`deployments/`](./deployments).

> The test tokens expose open `mint(to, amount)` and `faucet(amount)` methods — anyone can mint. `DeployMocks.s.sol` reverts on mainnet chainIds (1 / 56) to prevent accidental deployment.

### Core functions (v1.4 signed orders)

#### Payment: `pay(...)`

v1.4 uses **EIP-712 signed orders**: the merchant backend signs the order struct, the payer submits it to the router, and the router verifies the signature on-chain before settling.

```solidity
// EIP-712 order struct (signed by the merchant backend)
Order(
    address merchant,    // merchant identity
    address receiver,    // payout address (v1.4: per-order)
    address signer,      // order signer
    address token,       // ERC20 address, or NATIVE_TOKEN (0xEeee...EEeE)
    uint256 amount,
    bytes32 orderId,
    uint64  createdAt,
    uint64  expiresAt    // expired orders rejected; orderId prevents replay
)
```

**Execution order (H-06 audit fix; v1.4 pays out to `receiver`)**:
1. Try transferring the fee → fee recipient
2. On failure → forcibly route that fee to the `receiver` (emits `FeeRedirectedToMerchant` — the event name is kept for indexer backward compatibility; in v1.4 the redirected fee actually lands at `receiver`)
3. Mandatory transfer of `amount - fee` → `receiver`

**Conservation**: `receiver_received + protocol_received == amount`, always.

**Native-asset path**:
- When `token = NATIVE_TOKEN`, `msg.value` must equal `amount`
- On the ERC20 path, `msg.value` must be 0

#### Refund: `refund(orderId, amount)`

```solidity
function refund(bytes32 orderId, uint256 amount)
    external payable nonReentrant;
```

- `token` is read from the stored `OrderRecord` — **callers cannot specify it** (H-03 fix)
- `payer` is also read from the `OrderRecord`; refunds can only go back to the original payer
- Cumulative refunds may not exceed the original order amount
- **The collected protocol fee is never refunded**

### Quickstart

```bash
# 1. Init submodules (first time; includes forge-std and openzeppelin-contracts)
git submodule update --init --recursive

# 2. Build
forge build

# 3. Run tests
forge test
forge test --gas-report
forge snapshot

# 4. Format
forge fmt
forge fmt --check

# 5. Run a single test
forge test --match-test testFeeHardLimitIsConstant -vvv
```

### Environment variables (`.env`)

Copy `.env.example` to `.env` and fill in:

```bash
PRIVATE_KEY=             # deployer private key
ETHERSCAN_API_KEY=       # explorer verification (Etherscan V2 unified key — ETH + BSC + testnet)
BSC_RPC_URL=             # BSC mainnet RPC
BSC_TESTNET_RPC_URL=
ETH_RPC_URL=
GOVERNANCE=              # governance multisig (constructor arg)
INITIAL_TOKENS=          # initial token whitelist (comma-separated)
INITIAL_RECIPIENTS=      # initial fee recipients (1..20, comma-separated)
INITIAL_FEE_RATE=10      # bps; must be <= 10 (testnet runs 10; mainnet was deployed with 0)
```

### Deploy (CREATE3, same address cross-chain)

Production deploys use **CREATE3** (CreateX factory `0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed`) so the address is identical on every chain:

```bash
source .env

# (optional) mine a salt for a vanity address first
forge script script/MineSalt.s.sol

# CREATE3 deploy (BSC mainnet example)
forge script script/DeployCreate3.s.sol \
  --rpc-url $BSC_RPC_URL \
  --private-key $PRIVATE_KEY \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  --broadcast --verify -vvv
```

> `script/BeamPayRouter.s.sol` is the plain CREATE deploy script, intended for local/dev chains only; production always uses CREATE3 to preserve the cross-chain address.

### Verify a contract manually

```bash
forge verify-contract <address> BeamPayRouter \
  --chain-id 56 --api-key $ETHERSCAN_API_KEY
```

### Testing tips

```solidity
vm.createSelectFork("bsc");          // fork mainnet
deal(token, holder, amount);         // airdrop tokens to an account
vm.startPrank(actor); ... vm.stopPrank();
vm.warp(block.timestamp + 7 days);   // skip past the timelock window
```

### Security audits & continuous verification

| Tool | Purpose |
|---|---|
| **Slither** | Static analysis (`pnpm slither`, config in `slither.config.json`) |
| **Solhint** | Solidity linting (`pnpm solhint`) |
| **Foundry Invariant** | `test/invariant/` continuously verifies settlement conservation |
| **Gas Snapshot** | `.gas-snapshot` tracks gas usage; CI enforces no unrecorded regressions |
| **Prettier** | `prettier-plugin-solidity` formatting (`forge fmt --check` in CI) |

When investigating "why is the code shaped this way", grep `BeamPayRouter.sol` for `H-0x` / `M-0x` / `L-0x` tags — those are audit fix sites.

---

## ❓ FAQ

**Q: Is BeamPay custodial?**
A: No. Funds go from the payer's wallet directly to the order's payout address (`receiver`); the contract is just a router and never holds funds.

**Q: If the fee-recipient address has a problem (blacklisted / not a valid contract), is my payment affected?**
A: No. The H-06 fix guarantees: if the fee transfer fails, that amount is **forcibly routed to the order's `receiver`**, emitting a `FeeRedirectedToMerchant` event. The payout side never receives less.

**Q: Can the BeamPay team delist a token I accept?**
A: No. The token whitelist is **add-only** — there is simply no "remove token" function at the contract level.

**Q: Can the BeamPay team pause payments?**
A: No. The contract contains no pause / emergency functions of any kind.

**Q: Will the fee go up?**
A: Never above 0.1% — that's a bytecode-level hard cap. Even adjustments within the cap must pass the 7-day timelock, giving merchants ample time to react. Mainnet currently runs at 0%.

**Q: Is the contract upgradeable?**
A: **Never.** No proxy, no implementation slot — the address is the code. Upgrading means deploying a new contract, and a new address = new trust.

**Q: Do merchants need approval to integrate?**
A: No. As long as the payment token is whitelisted, any address can create signed orders and receive payments — no registration, no KYC (at the chain level).

**Q: What happens to native coins accidentally sent to the contract?**
A: The contract has **no** `receive` / `fallback` functions — all bare transfers revert, so funds can't get lost.

---

## 📚 Further Reading

- Full architecture notes: [`CLAUDE.md`](./CLAUDE.md)
- Deployed address inventory: [`deployments/`](./deployments)
- Contract source: [`src/BeamPayRouter.sol`](./src/BeamPayRouter.sol)
- Deploy broadcast records: [`broadcast/`](./broadcast)
- Integration docs (signing, native assets, webhooks): [BeamPay docs](https://github.com/BeamPayFun/beampay/tree/main/docs)

---

## 📄 License

MIT (declared in [`package.json`](./package.json)); a standalone LICENSE file will follow.

---

> **Core idea**: BeamPay doesn't rely on compliance promises or brand reputation to keep funds safe — it writes the inability to misbehave **into the contract bytecode**. Code is the promise; deployment is the commitment.
