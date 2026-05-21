# beam-contracts

Foundry workspace for the BeamPay protocol — a permissionless on-chain payment router for whitelisted ERC20 tokens and native asset (ETH/BNB).

The router is intentionally non-upgradeable, has no admin pause, and enforces a hard 0.1% fee ceiling at the bytecode level.

## Quickstart

```bash
forge install foundry-rs/forge-std --no-commit
forge build
forge test
```

See `CLAUDE.md` for full architecture, deploy runbook, and load-bearing invariants.

## Deployments

Canonical addresses live under [`deployments/`](./deployments/). One file per chain.

### BSC Testnet (chainId 97)

| Contract | Address |
|---|---|
| BeamRouter (v1.0 signed-orders) | [`0x67b7E4a8c77877C0FF51e03554B373211FbB1711`](https://testnet.bscscan.com/address/0x67b7e4a8c77877c0ff51e03554b373211fbb1711#code) |
| tUSDT (mock) | [`0x0c6DfFCbb941d2fDec9c8107e8128dcb6651951c`](https://testnet.bscscan.com/address/0x0c6dffcbb941d2fdec9c8107e8128dcb6651951c#code) |
| tUSDC (mock) | [`0x44a25C4cbe72a249866B6750F8594ba170a653fC`](https://testnet.bscscan.com/address/0x44a25c4cbe72a249866b6750f8594ba170a653fc#code) |

Mock tokens are 6 decimals, open-mint via `mint(to, amount)` or `faucet(amount)`. **Testnet only** — `DeployMocks.s.sol` reverts on chainId 1 / 56.
