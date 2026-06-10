# BeamPay 智能合约

[English](./README.md) | 简体中文

> 一个**无权限、不可升级、永不冻结**的链上支付路由器。商户只需一行合约调用即可完成稳定币/原生币收款，平台扣点最高 0.1%（主网当前 **0%**），且合约本身永不持有资金。

---

## 📌 一句话理解 BeamPay

**BeamPay = 链上版 Stripe Connect，但去除了"平台跑路"和"账户冻结"的风险。**

| 传统支付通道 | BeamPay |
|---|---|
| 资金先进入平台账户，再结算给商户 | 资金从付款人**直接进入订单签名的收款地址（receiver，通常即商户钱包）**，合约不经手一分钱 |
| 平台可冻结、可暂停、可改规则 | 合约**无资金管理员、无暂停按钮、无下架功能**——治理只能添加代币/收款人、在硬上限内调费率 |
| 手续费率随时可调 | 手续费率上限**硬编码 0.1%**（合约层面不可逾越） |
| 退款依赖客服 | 商户可链上直接发起部分/全额退款 |

---

## 🎯 业务人员视角：BeamPay 能为商户带来什么

### 1. 资金安全：合约永远不存钱

每一笔 `pay()` 调用都是**原子操作**：

```
付款人钱包 → 收款地址 receiver（amount - fee）
付款人钱包 → 平台费收款人（fee）
```

> `receiver` 是商户在创建订单时签名指定的收款地址（v1.4 起每笔订单可独立指定），典型场景下就是商户自己的钱包。

交易完成的那一刻，**路由器中不留存这笔支付的任何资金**——资金同笔交易进、同笔交易出。这意味着：
- 平台跑路？— 合约里没钱可跑
- 合约被攻击？— 合约里没钱可被偷
- 监管冻结合约？— 没有"冻结"这个功能存在

### 2. 费率天花板：写死在字节码里

平台费率上限是 **10 个基点（0.1%）**，且这是 Solidity `constant`（编译期常量），写进了合约字节码。

> 即使是治理多签，也**无法**把这个上限改高。要改，只能重新部署一个新合约（=新地址、新信任）。

实际生效费率（≤ 0.1%）可由治理调整，但任何费率调整都需经过下面的 7 天等待期。**主网当前费率为 0 bps（0%）**，测试网为 10 bps。

### 3. 治理透明：费率变更走 7 天时间锁

费率变更必须走两步：

1. **`proposeFeeChange`** — 治理多签发起提案，链上事件公开
2. **等待 7 天**
3. **`executeFeeChange`** — 任何人都可以执行（不只是治理方）

商户和用户有整整 7 天时间审计费率变更，必要时可撤资退出。

> 代币白名单（`addToken`）与费用收款人列表（`addFeeRecipient` / `removeFeeRecipient`）由治理即时调用（`onlyGov`），**不走时间锁**——但它们的破坏力被合约结构兜底：白名单**只增不减**（无法下架任何已支持的代币），费率无论收款人是谁都**不可能超过 0.1% 硬上限**。

### 4. 不可关停：付款功能永不下线

合约里**没有**这些函数：
- ❌ `pause()` / `unpause()`
- ❌ `emergencyStop()`
- ❌ `disableToken()` / `removeToken()`

代币白名单是**只增不减**的。合约一旦部署，`pay()` 功能就**永远可用**，直到那条链停止运行为止。

### 5. 退款机制：商户掌握主动权

商户可通过 `refund(orderId, amount)` 链上发起退款：
- 支持**部分退款**（多次退款累计不超过订单原金额）
- 退款只能退回**原付款人地址**（链上记录不可篡改）
- **平台手续费不参与退款**（已被路由走的费用不会被追回）

### 6. 多链多币种：所有链同一地址

| 链 | 路由器地址 | 支持代币 |
|---|---|---|
| Ethereum Mainnet (chainId 1) | `0xBEA93fceFb115b22a3D6c714Ee815B359e2AAbaa` | ETH（原生）+ USDT、USDC |
| BSC Mainnet (chainId 56) | `0xBEA93fceFb115b22a3D6c714Ee815B359e2AAbaa` | BNB（原生）+ USDT、USDC |
| BSC Testnet (chainId 97) | `0xBEA93fceFb115b22a3D6c714Ee815B359e2AAbaa` | tBNB + tUSDT/tUSDC（测试代币，可免费铸造） |

路由器通过 **CREATE3（CreateX factory）盐定址部署**，在所有链上拥有**完全相同的地址**。

原生币（BNB/ETH）通过约定的特殊地址 `0xEeee...EEeE` 表示，白名单与结算语义与 ERC20 一致（原生路径额外要求 `msg.value == amount`）。

---

## 🛡️ 安全承诺（Load-Bearing Invariants）

以下是合约**永远成立**的不变式，由测试套件持续验证：

| 序号 | 不变式 | 商户得到的保证 |
|---|---|---|
| 1 | 合约余额恒等于 0 | 资金不滞留，无被冻结风险 |
| 2 | `FEE_RATE_HARD_LIMIT = 10 bps` 是 `constant` | 平台费率上限永远 ≤ 0.1% |
| 3 | 无 pause / 无 removeToken | 付款功能永不下线，代币只增不减 |
| 4 | 费率变更经 7 天 timelock | 商户有充足审计窗口（其余治理操作即时，但受不变式 2、3 兜底） |
| 5 | `receiver_received + protocol_received == amount` | 收款金额账目精确无尘 |
| 6 | CEI + `nonReentrant` 保护 | 防御重入攻击 |
| 7 | 兼容 USDT 等"非标"ERC20 | 即使代币 `transfer` 不返回 bool 也能正常工作 |
| 8 | 退款代币读自订单存档 | 调用方无法伪造退款代币 |
| 9 | 两步治理切换 + `renounceGovernance` | 治理可永久放弃（变成真正的无主合约） |
| 10 | 无 `receive` / `fallback` | 裸原生转账直接 revert，资金不会卡在合约里 |

---

## 🔧 开发人员视角：如何对接

### 技术栈

- **Solidity** 0.8.28（EVM target: Cancun，via-IR，optimizer runs: 200）
- **构建工具**：Foundry（forge）
- **依赖**：`forge-std` + OpenZeppelin（`EIP712`、`ECDSA`，用于订单签名校验；均为 git submodule）
- **代码风格**：Prettier + prettier-plugin-solidity

### 项目结构

```
beampay-contracts/
├── src/
│   ├── BeamPayRouter.sol         # 协议核心:pay / refund / 治理 / timelock
│   ├── interfaces/               # 外部接口
│   └── mocks/                    # 测试代币(BeamMockERC20)
├── script/
│   ├── BeamPayRouter.s.sol       # 普通部署脚本(开发用)
│   ├── DeployCreate3.s.sol       # CREATE3 生产部署(跨链同地址)
│   ├── MineSalt.s.sol            # CREATE3 盐挖掘(vanity 地址)
│   └── DeployMocks.s.sol         # 测试代币部署(主网 revert)
├── test/
│   ├── BeamPayRouterTest.t.sol   # 路径测试 + 不变量测试
│   ├── BeamPayRouterSigned.t.sol # 签名订单(EIP-712)测试
│   └── invariant/                # Foundry invariant 套件
├── deployments/                  # 各链已部署地址(每链一个文件)
├── broadcast/                    # forge 部署广播记录
├── lib/                          # git submodule(forge-std, openzeppelin-contracts)
├── foundry.toml                  # RPC / 验证器 / 编译器配置
├── remappings.txt                # 导入路径映射
└── .env.example                  # 环境变量模板
```

### 部署地址

路由器在**所有链上是同一个地址**（CREATE3 盐定址）：

| 合约 | 链 | 地址 |
|---|---|---|
| BeamPayRouter (v1.4) | ETH Mainnet | [`0xBEA93fceFb115b22a3D6c714Ee815B359e2AAbaa`](https://etherscan.io/address/0xBEA93fceFb115b22a3D6c714Ee815B359e2AAbaa#code) |
| BeamPayRouter (v1.4) | BSC Mainnet | [`0xBEA93fceFb115b22a3D6c714Ee815B359e2AAbaa`](https://bscscan.com/address/0xBEA93fceFb115b22a3D6c714Ee815B359e2AAbaa#code) |
| BeamPayRouter (v1.4) | BSC Testnet | [`0xBEA93fceFb115b22a3D6c714Ee815B359e2AAbaa`](https://testnet.bscscan.com/address/0xBEA93fceFb115b22a3D6c714Ee815B359e2AAbaa#code) |
| tUSDT (mock，6 位精度) | BSC Testnet | [`0x0c6DfFCbb941d2fDec9c8107e8128dcb6651951c`](https://testnet.bscscan.com/address/0x0c6dffcbb941d2fdec9c8107e8128dcb6651951c#code) |
| tUSDC (mock，6 位精度) | BSC Testnet | [`0x44a25C4cbe72a249866B6750F8594ba170a653fC`](https://testnet.bscscan.com/address/0x44a25c4cbe72a249866b6750f8594ba170a653fc#code) |

完整部署记录（构造参数、部署交易、历史地址）见 [`deployments/`](./deployments)。

> 测试代币提供 `mint(to, amount)` 和 `faucet(amount)` 开放方法，任何人可铸造。`DeployMocks.s.sol` 对主网 chainId（1 / 56）会 revert，避免误部署。

### 核心函数（v1.4 签名订单）

#### 收款：`pay(...)`

v1.4 采用 **EIP-712 签名订单**：商户后端对订单结构签名，付款人提交给路由器，路由器链上验签后结算。

```solidity
// EIP-712 订单结构（商户后端签名）
Order(
    address merchant,    // 商户标识
    address receiver,    // 收款地址（v1.4：每笔订单独立指定）
    address signer,      // 订单签名者
    address token,       // ERC20 地址，或 NATIVE_TOKEN (0xEeee...EEeE)
    uint256 amount,
    bytes32 orderId,
    uint64  createdAt,
    uint64  expiresAt    // 过期订单被拒绝；orderId 防重放
)
```

**执行顺序（H-06 审计修复，v1.4 收款方为 receiver）**：
1. 尝试转手续费 → 费用收款人
2. 若失败 → 强制把这笔费用转给 `receiver`（触发 `FeeRedirectedToMerchant` 事件——事件名为兼容 indexer 保留，v1.4 实际落账地址是 `receiver`）
3. 强制转 `amount - fee` 给 `receiver`

**金额守恒**：`receiver_received + protocol_received == amount` 永远成立。

**原生币路径**：
- `token = NATIVE_TOKEN` 时，`msg.value` 必须等于 `amount`
- ERC20 路径时，`msg.value` 必须为 0

#### 退款：`refund(orderId, amount)`

```solidity
function refund(bytes32 orderId, uint256 amount)
    external payable nonReentrant;
```

- `token` 从订单存档 `OrderRecord` 读取，**调用方无法指定**（H-03 修复）
- `payer` 也从 `OrderRecord` 读取，退款只能退回原付款人
- 累计退款不得超过订单原金额
- **已收的协议费不参与退款**

### 快速开始

```bash
# 1. 初始化子模块（首次；含 forge-std 与 openzeppelin-contracts）
git submodule update --init --recursive

# 2. 构建
forge build

# 3. 运行测试
forge test
forge test --gas-report
forge snapshot

# 4. 格式化
forge fmt
forge fmt --check

# 5. 跑单个测试
forge test --match-test testFeeHardLimitIsConstant -vvv
```

### 环境变量（`.env`）

将 `.env.example` 复制为 `.env` 并填入：

```bash
PRIVATE_KEY=             # 部署者私钥
ETHERSCAN_API_KEY=       # 合约验证用（Etherscan V2 统一 key，覆盖 ETH/BSC/testnet）
BSC_RPC_URL=             # BSC mainnet RPC
BSC_TESTNET_RPC_URL=
ETH_RPC_URL=
GOVERNANCE=              # 治理多签地址（构造函数参数）
INITIAL_TOKENS=          # 初始白名单代币（逗号分隔）
INITIAL_RECIPIENTS=      # 初始费用收款人（1..20 个，逗号分隔）
INITIAL_FEE_RATE=10      # 基点；必须 <= 10（测试网为 10；主网部署时为 0）
```

### 部署（CREATE3，跨链同地址）

生产部署走 **CREATE3**（CreateX factory `0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed`），保证所有链上地址一致：

```bash
source .env

# （可选）先挖盐，得到 vanity 地址
forge script script/MineSalt.s.sol

# CREATE3 部署（BSC mainnet 示例）
forge script script/DeployCreate3.s.sol \
  --rpc-url $BSC_RPC_URL \
  --private-key $PRIVATE_KEY \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  --broadcast --verify -vvv
```

> `script/BeamPayRouter.s.sol` 是普通 CREATE 部署脚本，仅用于本地/开发链；生产环境一律使用 CREATE3 以保持跨链同地址。

### 手动验证合约

```bash
forge verify-contract <address> BeamPayRouter \
  --chain-id 56 --api-key $ETHERSCAN_API_KEY
```

### 测试技巧

```solidity
vm.createSelectFork("bsc");          // 主网 fork 测试
deal(token, holder, amount);         // 给账户空投代币
vm.startPrank(actor); ... vm.stopPrank();
vm.warp(block.timestamp + 7 days);   // 跳过 timelock 窗口
```

### 安全审计与持续验证

| 工具 | 用途 |
|---|---|
| **Slither** | 静态分析（`pnpm slither`，配置见 `slither.config.json`） |
| **Solhint** | Solidity Linting（`pnpm solhint`） |
| **Foundry Invariant** | `test/invariant/` 持续验证账目守恒 |
| **Gas Snapshot** | `.gas-snapshot` 跟踪 gas 消耗，CI 强制无未记录回归 |
| **Prettier** | `prettier-plugin-solidity` 格式化（CI 跑 `forge fmt --check`） |

排查"代码为什么这样写"时，可在 `BeamPayRouter.sol` 中搜索 `H-0x` / `M-0x` / `L-0x` 标签——这些是审计修复点。

---

## ❓ 常见问题

**Q：BeamPay 是托管的吗？**
A：不是。资金从付款人钱包直接到订单指定的收款地址（receiver），合约只是路由器，永远不持有资金。

**Q：如果手续费收款地址出问题（被冻结/不存在合约），我的收款会受影响吗？**
A：不会。H-06 修复保证：若手续费转账失败，这部分钱会被**强制转给订单的 receiver**，并发出 `FeeRedirectedToMerchant` 事件。收款方收到的金额永远不会少。

**Q：BeamPay 团队可以下架我接受的代币吗？**
A：不能。代币白名单是**只增不减**的，合约层面就没有"移除代币"的函数。

**Q：BeamPay 团队可以暂停付款吗？**
A：不能。合约里没有任何 pause / emergency 类型的函数。

**Q：手续费会涨吗？**
A：不会超过 0.1%。这是字节码硬上限。即使在上限内调整，也要走 7 天 timelock，商户有充足时间反应。主网当前费率为 0%。

**Q：合约是否升级？**
A：**永远不会升级**。没有代理，没有 implementation slot，地址即代码。要升级只能部署新合约，新地址 = 新信任。

**Q：商户接入需要审批吗？**
A：不需要。只要付款代币在白名单内，任何地址都可以创建签名订单收款，无需注册、无需 KYC（链上层面）。

**Q：误转入合约的原生币会怎样？**
A：合约**没有** `receive` / `fallback` 函数，所有裸转账都会 revert，资金不会丢失。

---

## 📚 进一步阅读

- 完整架构说明：[`CLAUDE.md`](./CLAUDE.md)
- 已部署地址清单：[`deployments/`](./deployments)
- 合约源码：[`src/BeamPayRouter.sol`](./src/BeamPayRouter.sol)
- 部署广播记录：[`broadcast/`](./broadcast)
- 集成文档（签名、原生币、Webhook）：[BeamPay docs](https://github.com/BeamPayFun/beampay/tree/main/docs)

---

## 📄 许可证

MIT（声明于 [`package.json`](./package.json)）；独立 LICENSE 文件后续补充。

---

> **核心理念**：BeamPay 不靠合规承诺、不靠品牌信誉来保证资金安全，而是把不可作恶性**写进合约字节码**。代码即承诺，部署即固化。
