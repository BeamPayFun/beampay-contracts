// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/**
 * @title BeamPayRouter
 * @author BeamPay Team
 * @notice BeamPay protocol core contract — permissionless on-chain payment router
 *         for whitelisted ERC20 tokens and native asset (ETH/BNB) — v1.4 (per-order receiver)
 *
 * @dev Design Principles:
 *      1. Funds Never Held in Contract
 *         pay() transfers payer -> merchant and payer -> feeRecipient directly
 *         (ERC20: SafeERC20 pull; native: forwarded via .call{value:}).
 *         The contract's own balance is always 0, minimising loss exposure on any
 *         compromise.
 *
 *      2. Price Floor Hardcoded
 *         FEE_RATE_HARD_LIMIT (0.1%) is `constant` — no governance op can exceed it.
 *         Fee = amount * rate / BASIS_POINTS_DENOMINATOR, linear, no per-tx cap, so
 *         per-payment cost scales with merchant turnover and is fully predictable.
 *
 *      3. Blacklist-Resistant Fee Path
 *         Fee leg is "try fee -> recipient, fall back to merchant on failure". If
 *         any fee recipient is blacklisted by an issuer (Tether/Circle), payments
 *         still complete — protocol just doesn't collect fee that round.
 *
 *      4. No Pause / No Emergency / No Admin (True Permissionless)
 *         Once deployed, nobody — including governance — can halt pay(). Every
 *         parameter change goes through the 7-day timelock. No fast track exists.
 *
 *      5. Transparent, Auditable Governance
 *         Fee rate / token whitelist / recipient pool changes are all logged on
 *         chain; rate changes additionally gated by 7-day TIMELOCK_DELAY.
 *
 *      6. No receive / No fallback
 *         The contract refuses bare native transfers (no receive(), no fallback()).
 *         Native value only enters via pay()/refund() and exits in the same tx —
 *         the contract never holds a stray wei.
 *
 *      7. Protocol Fee Cannot Be Bypassed (H-06 fix, v1.2+)
 *         pay() order is: (a) try fee -> recipient; (b) on failure, mandatory
 *         fee -> merchant and emit FeeRedirectedToMerchant; (c) mandatory main leg
 *         to merchant. Invariant under every successful path:
 *             merchant_received + protocol_received == amount.
 *
 *      8. Native Asset Support (v1.3+)
 *         A sentinel address NATIVE_TOKEN (0xEeee...EEeE) represents the chain's
 *         native asset. pay() and refund() are `payable` and dispatch:
 *             - token == NATIVE_TOKEN: require msg.value == amount; transfer via
 *               .call{value:}("") with the H-06 fallback semantics preserved.
 *             - token != NATIVE_TOKEN: require msg.value == 0; existing SafeERC20
 *               pull path unchanged.
 *         NATIVE_TOKEN still has to be added to the whitelist via addToken().
 *
 *     10. Per-Order Receiver (v1.4+)
 *         `receiver` is signed into every Order (EIP-712) and is the sole payout
 *         destination — both the principal leg and the H-06 fee-redirect fallback
 *         target `receiver`, not `merchant`. `merchant` retains its semantics as
 *         order-key namespace, refund() caller, and event index.
 *         `merchantReceiver[merchant]` is a per-merchant UX hint that merchants
 *         may rotate freely; pay() never reads it. Rotating the config does NOT
 *         invalidate already-signed orders — each order pays to whichever
 *         receiver was signed at order-creation time.
 *         Invariant updated to: receiver_received + protocol_received == amount.
 */

/// @notice Minimal ERC20 interface; intentionally untyped return to tolerate
///         non-standard tokens (e.g. mainnet USDT) which omit the return value.
interface IERC20 {
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/**
 * @notice SafeERC20 library — handles non-standard ERC20 implementations.
 * @dev Audit fixes H-01 / M-02:
 *      - Mainnet USDT (0xdAC17F958D2ee523a2206206994597C13D831ec7) does not
 *        return a value from transferFrom.
 *      - Some tokens return false on failure instead of reverting.
 *      Both cases must be handled via low-level call + return-data length check.
 */
library SafeERC20 {
    /// @notice Strict transferFrom: reverts on failure.
    function safeTransferFrom(IERC20 token, address from, address to, uint256 value) internal {
        (bool success, bytes memory returndata) =
            address(token).call(abi.encodeWithSelector(token.transferFrom.selector, from, to, value));
        // Call must succeed, and return data must be either empty (USDT-style) or decode to true.
        if (!success) revert SafeERC20Failed();
        if (returndata.length > 0 && !abi.decode(returndata, (bool))) {
            revert SafeERC20Failed();
        }
    }

    /// @notice Lenient transferFrom: returns false on failure instead of reverting.
    ///         Used for the speculative fee leg so a blacklisted recipient does
    ///         not abort the whole payment.
    function trySafeTransferFrom(IERC20 token, address from, address to, uint256 value) internal returns (bool) {
        (bool success, bytes memory returndata) =
            address(token).call(abi.encodeWithSelector(token.transferFrom.selector, from, to, value));
        if (!success) return false;
        if (returndata.length > 0 && !abi.decode(returndata, (bool))) return false;
        return true;
    }

    error SafeERC20Failed();
}

/**
 * @title BeamPayRouter
 * @notice BeamPay protocol main contract. Merchants get paid via pay(); merchants
 *         issue refunds via refund(). No admin, no pause, no emergency.
 *
 * @dev Hard commitment: this contract has **no pause function, no emergency
 *      multisig, no admin backdoor**. Once deployed, pay() is callable forever.
 *      Every parameter change waits out the 7-day timelock.
 */
contract BeamPayRouter is EIP712 {
    using SafeERC20 for IERC20;
    using ECDSA for bytes32;

    // ========================================================
    // ============ Hard Limits (forever immutable) ===========
    // ========================================================

    /// @notice Fee rate ceiling = 0.1% (10 bps). `constant` — no governance op can exceed it.
    /// @dev    The single hard commitment to merchants. v1.1+ has no per-tx fee cap;
    ///         fee scales linearly so low-ticket merchants don't see distorted effective rates.
    uint256 public constant FEE_RATE_HARD_LIMIT = 10;

    /// @notice Timelock delay for governance parameter changes = 7 days.
    uint256 public constant TIMELOCK_DELAY = 7 days;

    /// @notice Basis-point denominator (10000 => "per-myriad").
    uint256 public constant BASIS_POINTS_DENOMINATOR = 10000;

    /// @notice Cap on size of fee-recipient pool (gas-DoS guard + governance abuse cap).
    uint256 public constant MAX_FEE_RECIPIENTS = 20;

    /// @notice Sentinel address representing the chain's native asset (ETH/BNB).
    /// @dev    1inch/Curve convention; chosen so it cannot collide with any real ERC20.
    ///         Must still be added to the whitelist via addToken(NATIVE_TOKEN).
    address public constant NATIVE_TOKEN = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    /// @notice EIP-712 typehash for the merchant-signed `Order` struct.
    /// @dev    Field order MUST match the front-end's `signTypedData` payload exactly.
    ///         v1.4: `receiver` inserted immediately after `merchant`.
    bytes32 public constant ORDER_TYPEHASH = keccak256(
        "Order(address merchant,address receiver,address signer,address token,uint256 amount,bytes32 orderId,uint64 createdAt,uint64 expiresAt)"
    );

    // ========================================================
    // ============ Governance ================================
    // ========================================================

    /// @notice Governance multisig (2/3 recommended).
    /// @dev    Can only mutate parameters through the 7-day timelock.
    ///         No pause power, no arbitrary withdrawal power.
    address public governance;

    /// @notice Pending new governance address for the two-step handoff.
    /// @dev    Audit fix M-03: prevents permanent loss of governance via single-step typo.
    address public pendingGovernance;

    // ========================================================
    // ============ Current Effective Values ==================
    // ========================================================

    /// @notice Currently effective fee rate (bps). Adjustable via 7-day timelock.
    uint256 public currentFeeRate;

    // ========================================================
    // ============ Pending Fee Change (Timelock) =============
    // ========================================================

    /// @dev `effectiveTime == 0` is the sentinel for "no pending proposal".
    ///      A real proposal always sets `block.timestamp + TIMELOCK_DELAY`, which can
    ///      never be 0 on a live chain, so the sentinel is safe and we save the SSTORE
    ///      that a separate `bool exists` would have required (bool packs into its own
    ///      slot after a uint256, so removing it removes a full storage slot).
    struct PendingChange {
        uint256 newRate;
        uint256 effectiveTime;
    }
    PendingChange public pending;

    // ========================================================
    // ============ Fee Recipient Pool ========================
    // ========================================================

    /// @notice Pool of fee-receiving addresses; orderId hash modulo selects one per pay.
    address[] public feeRecipients;

    /// @notice Membership flag for O(1) duplicate detection.
    /// @dev    Audit fix H-04: feeRecipients had no de-duplication.
    mapping(address => bool) public isFeeRecipient;

    // ========================================================
    // ============ Token Whitelist ===========================
    // ========================================================

    /// @notice Whitelist of accepted tokens (incl. NATIVE_TOKEN once governance adds it).
    mapping(address => bool) public allowedTokens;

    // ========================================================
    // ============ Order State ===============================
    // ========================================================

    /// @notice Full order record stored per (merchant, orderId).
    /// @dev Audit fix M-08: merged processed/orderAmount/refunded into a single struct
    ///                    to cut storage cost.
    ///      v1.0: dropped `exists` — `payer != address(0)` serves as the sentinel for
    ///            "order paid" (pay() always writes a non-zero msg.sender). Added
    ///            `signer`, `createdAt`, `expiresAt` from the EIP-712 signed payload.
    ///      v1.4: added `receiver` (signed in EIP-712). Storage layout (6 slots):
    ///              slot0: payer(20) + createdAt(8)
    ///              slot1: token(20)
    ///              slot2: amount(32)
    ///              slot3: refunded(32)
    ///              slot4: receiver(20)
    ///              slot5: signer(20) + expiresAt(8)
    struct OrderRecord {
        address payer; // 20B — non-zero iff order paid (replaces `exists`)
        uint64 createdAt; // 8B — timestamp from signed payload (packs with payer)
        address token; // 20B — token used for the order (refunds use same)
        uint256 amount; // 32B — original order amount (refund ceiling)
        uint256 refunded; // 32B — cumulative refunded amount
        address receiver; // 20B — payout destination from signed payload (v1.4+)
        address signer; // 20B — recovered EIP-712 signer (merchant or delegate)
        uint64 expiresAt; // 8B — timestamp from signed payload (packs with signer)
    }

    /// @notice Order key (keccak256(merchant, orderId)) -> OrderRecord.
    mapping(bytes32 => OrderRecord) public orders;

    // ========================================================
    // ============ Merchant Signer Delegation ================
    // ========================================================

    /// @notice Per-merchant authorized signer. address(0) = no delegate; only the merchant
    ///         itself may sign orders. Setting a non-zero value lets that wallet co-sign on
    ///         the merchant's behalf. Self-sovereign: only the merchant (msg.sender) writes
    ///         its own slot, no governance involvement.
    /// @dev    Single delegate per merchant; calling `setSigner(addr)` overwrites the previous
    ///         delegate. Calling `setSigner(address(0))` clears delegation.
    mapping(address merchant => address signer) public merchantSigner;

    // ========================================================
    // ============ Merchant Receiver Hint (v1.4+) ============
    // ========================================================

    /// @notice Per-merchant default payout address — UX hint only.
    /// @dev    pay() does NOT read this. The payout destination is the `receiver`
    ///         field of the signed Order. This mapping exists so dashboards /
    ///         off-chain order builders can fetch a sane default when creating
    ///         a new order. Self-sovereign: only the merchant (msg.sender) writes
    ///         its own slot. Rotating this value never invalidates already-signed
    ///         orders — each order pays to whichever receiver was signed at
    ///         order-creation time.
    mapping(address merchant => address receiver) public merchantReceiver;

    // ========================================================
    // ============ Reentrancy Guard ==========================
    // ========================================================

    uint256 private _locked = 1;

    // ========================================================
    // ============ Custom Errors (gas-efficient) =============
    // ========================================================

    error ZeroAddress();
    error ZeroAmount();
    error ZeroOrderId();
    error TokenNotAllowed();
    error DuplicateOrder();
    error OrderNotPaid();
    error RefundExceedsOrder();
    error AmountTooSmall();
    error NotGovernance();
    error NotPendingGovernance();
    error Reentrant();
    error RateExceedsHardLimit();
    error NoPending();
    error TimelockNotExpired();
    error AlreadyFeeRecipient();
    error NotAFeeRecipient();
    error AddressMismatch();
    error MustKeepAtLeastOne();
    error TooManyRecipients();
    error AlreadyAllowed();

    /// @notice msg.value did not match the native amount.
    error IncorrectNativeValue();
    /// @notice msg.value was sent on an ERC20 path.
    error UnexpectedNativeValue();
    /// @notice Low-level .call{value:} to a recipient failed (out of gas, revert, etc.).
    error NativeTransferFailed();

    /// @notice block.timestamp > expiresAt: signed order is past its expiry window.
    error OrderExpired();
    /// @notice signer parameter is not the merchant and not the merchant's authorized delegate.
    error UnauthorizedSigner();
    /// @notice ECDSA.recover(digest, signature) did not equal the declared `signer`.
    error InvalidSignature();
    /// @notice expiresAt <= createdAt: signed window is empty or inverted.
    error InvalidExpiry();

    // ========================================================
    // ============ Events ====================================
    // ========================================================

    /// @notice Successful payment.
    /// @param merchant         Order owner (event-indexed; NOT the payout destination in v1.4+)
    /// @param orderId          Merchant-side order id
    /// @param payer            Address that paid
    /// @param receiver         Payout destination signed into the order (v1.4+)
    /// @param token            Token used (NATIVE_TOKEN for native)
    /// @param amount           Pre-fee order amount
    /// @param fee              Protocol fee actually collected (= 0 on rate-zero or fail path)
    /// @param feeRecipient     Address fee was directed to (address(0) if no fee leg)
    /// @param feeCollected     True if fee went to feeRecipient; false if redirected to receiver
    /// @param timestamp        Block timestamp of the payment
    event Paid(
        address indexed merchant,
        bytes32 indexed orderId,
        address indexed payer,
        address receiver,
        address token,
        uint256 amount,
        uint256 fee,
        address feeRecipient,
        bool feeCollected,
        uint256 timestamp
    );

    event Refunded(
        bytes32 indexed orderId,
        address indexed merchant,
        address indexed payer,
        address token,
        uint256 amount,
        uint256 timestamp
    );

    event FeeTransferFailed(bytes32 indexed orderId, address token, uint256 fee, address feeRecipient);
    /// @notice Fee recipient was unreachable (blacklist, contract revert, etc.); fee was
    ///         redirected to the order's `receiver` to preserve the H-06 invariant.
    /// @dev    Event name kept as `FeeRedirectedToMerchant` for indexer backward compatibility.
    ///         In v1.4+ the redirected fee lands at `receiver` (the payout destination), not
    ///         at the merchant — `merchant` is still emitted (indexed) as the order owner.
    event FeeRedirectedToMerchant(
        bytes32 indexed orderId,
        address token,
        uint256 fee,
        address indexed feeRecipient,
        address indexed merchant,
        address receiver
    );
    event FeeChangeProposed(uint256 newRate, uint256 effectiveTime);
    event FeeChangeExecuted(uint256 newRate);
    event FeeChangeCancelled();
    event TokenAdded(address indexed token);
    event FeeRecipientAdded(address indexed recipient);
    event FeeRecipientRemoved(uint256 index, address indexed recipient);
    event GovernanceTransferStarted(address indexed oldGov, address indexed pendingGov);
    event GovernanceTransferred(address indexed oldGov, address indexed newGov);
    event Initialized(address governance, uint256 feeRate, uint256 timelockDelay);

    /// @notice Merchant updated its authorized signer delegate.
    /// @param merchant  Merchant whose delegate slot was written.
    /// @param oldSigner Previous delegate (address(0) if none).
    /// @param newSigner New delegate (address(0) clears delegation).
    event SignerUpdated(address indexed merchant, address indexed oldSigner, address indexed newSigner);

    /// @notice Merchant updated its default payout-receiver hint (v1.4+).
    /// @param merchant    Merchant whose receiver slot was written.
    /// @param oldReceiver Previous default receiver (address(0) if none).
    /// @param newReceiver New default receiver (address(0) clears the hint).
    event ReceiverUpdated(address indexed merchant, address indexed oldReceiver, address indexed newReceiver);

    // ========================================================
    // ============ Modifiers =================================
    // ========================================================

    modifier onlyGov() {
        if (msg.sender != governance) revert NotGovernance();
        _;
    }

    /// @notice Reentrancy guard; depth-1 protection against ERC777/ERC20 callbacks
    ///         and against native recipients that re-enter via receive().
    /// @dev Audit fix L-01: paired with CEI as defence-in-depth.
    modifier nonReentrant() {
        if (_locked != 1) revert Reentrant();
        _locked = 2;
        _;
        _locked = 1;
    }

    // ========================================================
    // ============ Constructor ===============================
    // ========================================================

    /**
     * @notice Deploy the router.
     * @param _governance         Governance multisig (2/3 recommended).
     * @param _initialTokens      Initial whitelist; include NATIVE_TOKEN to enable native pay.
     * @param _initialRecipients  Fee recipient pool (>= 1, recommended >= 3 per chain).
     * @param _initialFeeRate     Starting fee rate in bps; must be <= FEE_RATE_HARD_LIMIT.
     *
     * @dev No emergencyMultisig parameter — there is no emergency mode.
     *      No per-tx fee cap — fee = amount * rate / 10000, linear.
     */
    constructor(
        address _governance,
        address[] memory _initialTokens,
        address[] memory _initialRecipients,
        uint256 _initialFeeRate
    ) EIP712("BeamPayRouter", "1") {
        // Audit fix H-05: validate constructor parameters.
        if (_governance == address(0)) revert ZeroAddress();
        if (_initialFeeRate > FEE_RATE_HARD_LIMIT) revert RateExceedsHardLimit();
        // Audit fix M-09: at least one fee recipient is required so the modulo dispatch never reverts.
        if (_initialRecipients.length == 0) revert MustKeepAtLeastOne();
        if (_initialRecipients.length > MAX_FEE_RECIPIENTS) revert TooManyRecipients();

        governance = _governance;
        currentFeeRate = _initialFeeRate;

        // Seed the token whitelist (zero-address check inline).
        for (uint256 i = 0; i < _initialTokens.length; i++) {
            if (_initialTokens[i] == address(0)) revert ZeroAddress();
            allowedTokens[_initialTokens[i]] = true;
            emit TokenAdded(_initialTokens[i]);
        }

        // Seed the fee recipient pool with zero-address + duplicate guards.
        // Audit fix H-04: dedupe initial recipients and reject address(0).
        for (uint256 i = 0; i < _initialRecipients.length; i++) {
            address recipient = _initialRecipients[i];
            if (recipient == address(0)) revert ZeroAddress();
            if (isFeeRecipient[recipient]) revert AlreadyFeeRecipient();
            isFeeRecipient[recipient] = true;
            feeRecipients.push(recipient);
            emit FeeRecipientAdded(recipient);
        }

        emit Initialized(_governance, _initialFeeRate, TIMELOCK_DELAY);
    }

    // ========================================================
    // ============ Core Pay Function =========================
    // ========================================================

    /**
     * @notice Pay a merchant-signed order. Funds flow: payer -> receiver + payer -> feeRecipient,
     *         all inside this single call.
     * @param merchant   Order owner (event index, refund caller); NOT the payout destination in v1.4+.
     * @param receiver   Payout destination signed into the order (v1.4+). Must be non-zero.
     * @param token      Token to pay with — must be whitelisted. Use NATIVE_TOKEN for native asset.
     * @param amount     Order amount (pre-fee).
     * @param orderId    Merchant-scoped order id; must be unique per merchant.
     * @param signer     Declared signer of the EIP-712 payload (must equal `merchant` or
     *                   `merchantSigner[merchant]`).
     * @param createdAt  Timestamp (unix seconds) when the merchant signed the order.
     * @param expiresAt  Timestamp (unix seconds) after which the signature is no longer valid.
     * @param signature  EIP-712 secp256k1 signature over the `Order` struct (see ORDER_TYPEHASH).
     *
     * @dev Security notes:
     *      - No whenNotPaused modifier; the contract has no pause state.
     *      - CEI: state write (orders[key] = ...) happens before any external call.
     *      - nonReentrant: defends against malicious token callbacks and native recipients.
     *      - SafeERC20: tolerates non-standard ERC20s (e.g. mainnet USDT).
     *      - try-fee leg: blacklisted fee recipient does not abort the receiver leg.
     *      - amount > fee: prevents receiver from receiving 0 due to rounding.
     *      - Native path: msg.value == amount required; ERC20 path: msg.value == 0 required.
     *      - EIP-712 signature binds (chainId, verifyingContract, merchant, receiver, signer,
     *        token, amount, orderId, createdAt, expiresAt). Any tamper invalidates the signature.
     *      - `merchantReceiver[merchant]` is intentionally not consulted: `receiver` is the
     *        single source of truth, fixed at signing time. Merchants may rotate the hint
     *        without invalidating already-signed orders.
     */
    function pay(
        address merchant,
        address receiver,
        address token,
        uint256 amount,
        bytes32 orderId,
        address signer,
        uint64 createdAt,
        uint64 expiresAt,
        bytes calldata signature
    ) external payable nonReentrant {
        // ====== Input validation ======
        if (merchant == address(0)) revert ZeroAddress();
        if (receiver == address(0)) revert ZeroAddress();
        if (!allowedTokens[token]) revert TokenNotAllowed();
        if (amount == 0) revert ZeroAmount();
        if (orderId == bytes32(0)) revert ZeroOrderId();

        bool isNative = token == NATIVE_TOKEN;
        if (isNative) {
            if (msg.value != amount) revert IncorrectNativeValue();
        } else {
            if (msg.value != 0) revert UnexpectedNativeValue();
        }

        // ====== Temporal validation (v1.0 signed orders) ======
        if (expiresAt <= createdAt) revert InvalidExpiry();
        if (block.timestamp > expiresAt) revert OrderExpired();

        // ====== Signer authorization (v1.0 signed orders) ======
        // Declared signer must be either the merchant itself or the merchant's currently
        // authorized delegate. merchantSigner[merchant] == address(0) collapses to
        // "only merchant may sign" — never matches a non-zero `signer` parameter.
        if (signer != merchant && signer != merchantSigner[merchant]) revert UnauthorizedSigner();

        // ====== EIP-712 signature verification (v1.0 signed orders; v1.4 adds `receiver`) ======
        bytes32 structHash = keccak256(
            abi.encode(ORDER_TYPEHASH, merchant, receiver, signer, token, amount, orderId, createdAt, expiresAt)
        );
        bytes32 digest = _hashTypedDataV4(structHash);
        if (digest.recover(signature) != signer) revert InvalidSignature();

        // ====== Replay guard (payer != 0 sentinel; replaces old `exists` flag) ======
        bytes32 key = keccak256(abi.encode(merchant, orderId));
        if (orders[key].payer != address(0)) revert DuplicateOrder();

        // ====== Fee calculation (linear, no per-tx cap) ======
        uint256 fee = (amount * currentFeeRate) / BASIS_POINTS_DENOMINATOR;

        // Audit fix M-01: require amount > fee so the merchant never receives 0.
        // With rate <= 10 bps, fee <= amount/1000, so amount >= 1000 wei is guaranteed safe.
        // amount < 1000 wei is effectively below the minimum settlement unit.
        if (amount <= fee) revert AmountTooSmall();

        // ====== Effects (state write before any external interaction) ======
        orders[key] = OrderRecord({
            payer: msg.sender,
            createdAt: createdAt,
            token: token,
            amount: amount,
            refunded: 0,
            receiver: receiver,
            signer: signer,
            expiresAt: expiresAt
        });

        // ====== Interactions (H-06 fix: fee-first try + redirect-to-receiver fallback) ======
        //
        // v1.0/v1.1 transferred the receiver leg before the fee leg, and used try-pattern
        // for the fee — a malicious payer could cap allowance/balance at `amount - fee`
        // so the fee transfer silently failed, bypassing the protocol fee.
        //
        // v1.2 inverted the order: speculative fee leg first; on failure, mandatory
        // redirect to receiver; then mandatory main leg. Any path where the payer can't
        // cover `amount` total reverts at the receiver leg.
        //
        // Invariant under every successful path: receiver_received + protocol_received == amount.
        //
        // v1.3 (native): same shape, but native uses .call{value:} instead of SafeERC20,
        // and when the fee redirects to receiver we combine fee+(amount-fee) into one .call
        // for `amount` (since no separate "allowance" exists for native).
        //
        // v1.4: `receiver` (from the signed order) replaces `merchant` as the payout target.
        //       `merchant` is retained as the order owner / event index / refund caller.

        address feeTo = address(0);
        bool feeCollected = false;

        if (fee > 0) {
            // feeRecipients.length is enforced >= 1 in the constructor, so the modulo is safe.
            uint256 idx = uint256(orderId) % feeRecipients.length;
            feeTo = feeRecipients[idx];

            // Step 1: try to send fee straight to the protocol recipient.
            // Audit M-02: tolerate Tether/Circle blacklisting — failure must not revert.
            if (isNative) {
                (bool ok,) = feeTo.call{ value: fee }("");
                feeCollected = ok;
            } else {
                feeCollected = IERC20(token).trySafeTransferFrom(msg.sender, feeTo, fee);
            }

            if (!feeCollected) {
                // Step 2 (fallback): fee recipient is unreachable — redirect fee to the receiver.
                // For ERC20 this is a second pull from the payer's allowance; if an H-06 attacker
                // capped allowance, the safeTransferFrom here reverts the whole tx.
                // For native the redirect is bundled into the receiver .call below.
                if (!isNative) {
                    IERC20(token).safeTransferFrom(msg.sender, receiver, fee);
                }
                emit FeeTransferFailed(orderId, token, fee, feeTo);
                emit FeeRedirectedToMerchant(orderId, token, fee, feeTo, merchant, receiver);
            }
        }

        // ====== Step 3: mandatory receiver main leg ======
        // ERC20: always transfer `amount - fee`; combined with the conditional fee-redirect
        //        leg above, total receiver inflow == feeCollected ? amount-fee : amount.
        // Native: transfer (amount - fee) if fee was collected; otherwise transfer the full
        //        amount in one .call to fold the redirected fee into the same payment.
        if (isNative) {
            uint256 receiverAmount = feeCollected ? amount - fee : amount;
            (bool ok,) = receiver.call{ value: receiverAmount }("");
            if (!ok) revert NativeTransferFailed();
        } else {
            IERC20(token).safeTransferFrom(msg.sender, receiver, amount - fee);
        }

        emit Paid(merchant, orderId, msg.sender, receiver, token, amount, fee, feeTo, feeCollected, block.timestamp);
    }

    // ========================================================
    // ============ Refund Function ===========================
    // ========================================================

    /**
     * @notice Refund (part of) an order. Callable only by the original merchant.
     * @param orderId Merchant-side order id.
     * @param amount  Refund amount (partial refunds allowed; cumulative cap = order amount).
     *
     * @dev Security notes:
     *      - msg.sender is implicitly the merchant (encoded into the order key). Only the
     *        merchant can refund — the order's `receiver` has no refund authority.
     *      - Token is read from the stored OrderRecord; merchant cannot specify a different
     *        token. (v1.3: dropped the redundant `token` parameter that audit fix M-07
     *        previously cross-checked — the stored value is the single source of truth.)
     *      - Audit fix H-03: payer is forced from OrderRecord; not accepted as a parameter.
     *      - Protocol fee is never refunded (on-chain cost is irreversible; merchant absorbs).
     *      - Merchant must approve `amount` to this contract before calling (ERC20 path),
     *        or attach msg.value == amount (native path).
     *      - v1.4: the order's `receiver` slot is intentionally ignored here. Refunds
     *        always flow to the original payer, regardless of who got paid out by pay().
     */
    function refund(bytes32 orderId, uint256 amount) external payable nonReentrant {
        if (amount == 0) revert ZeroAmount();

        bytes32 key = keccak256(abi.encode(msg.sender, orderId));
        OrderRecord storage order = orders[key];

        // Order must exist (i.e. have been paid). v1.0: `payer != 0` replaces dropped `exists`.
        if (order.payer == address(0)) revert OrderNotPaid();
        // Cumulative refund cap.
        if (order.refunded + amount > order.amount) revert RefundExceedsOrder();

        // ====== Effects ======
        order.refunded += amount;
        // Audit fix H-03: payer always sourced from stored record.
        address payer = order.payer;
        address token = order.token;

        // ====== Interactions ======
        if (token == NATIVE_TOKEN) {
            if (msg.value != amount) revert IncorrectNativeValue();
            (bool ok,) = payer.call{ value: amount }("");
            if (!ok) revert NativeTransferFailed();
        } else {
            if (msg.value != 0) revert UnexpectedNativeValue();
            // Merchant must have approved `amount` to this contract first.
            IERC20(token).safeTransferFrom(msg.sender, payer, amount);
        }

        emit Refunded(orderId, msg.sender, payer, token, amount, block.timestamp);
    }

    // ========================================================
    // ============ Governance: Fee Change with Timelock ======
    // ========================================================
    // This is the **only** path that mutates fee parameters, and it must wait
    // out the full 7-day timelock. No emergency channel, no fast track —
    // governance itself cannot bypass the delay.

    /**
     * @notice Propose a new fee rate. Takes effect after TIMELOCK_DELAY.
     * @param newRate New rate in bps. Must be <= FEE_RATE_HARD_LIMIT.
     */
    function proposeFeeChange(uint256 newRate) external onlyGov {
        if (newRate > FEE_RATE_HARD_LIMIT) revert RateExceedsHardLimit();

        // Audit fix M-05: emit Cancelled when overwriting an existing pending proposal.
        if (pending.effectiveTime != 0) {
            emit FeeChangeCancelled();
        }

        pending = PendingChange({ newRate: newRate, effectiveTime: block.timestamp + TIMELOCK_DELAY });
        emit FeeChangeProposed(newRate, block.timestamp + TIMELOCK_DELAY);
    }

    /**
     * @notice Execute an already-matured fee change. Permissionless on purpose —
     *         governance cannot delay approved proposals indefinitely.
     */
    function executeFeeChange() external {
        if (pending.effectiveTime == 0) revert NoPending();
        if (block.timestamp < pending.effectiveTime) revert TimelockNotExpired();

        uint256 newRate = pending.newRate;

        // Defence in depth: re-check the hard limit at execution time.
        if (newRate > FEE_RATE_HARD_LIMIT) revert RateExceedsHardLimit();

        currentFeeRate = newRate;
        delete pending;

        emit FeeChangeExecuted(newRate);
    }

    /// @notice Governance-only: cancel a pending fee proposal.
    function cancelPendingChange() external onlyGov {
        if (pending.effectiveTime == 0) revert NoPending();
        delete pending;
        emit FeeChangeCancelled();
    }

    // ========================================================
    // ============ Token Whitelist (add-only) ================
    // ========================================================
    // Design commitment: the whitelist is **append-only**.
    //
    // - addToken() is callable by governance without timelock — it only widens
    //   merchant/customer choice and has zero negative impact on integrators.
    //
    // - There is intentionally NO disableToken / removeToken. Such a function
    //   would be equivalent to a per-token pause and would break the "once
    //   integrated, BeamPay cannot cut you off" commitment that defines this
    //   contract. If a specific token misbehaves (e.g. a USDT-side pause), the
    //   issue is handled by the token itself or by merchant-side UI changes —
    //   not by this contract.

    /**
     * @notice Whitelist a token (or the native asset) so it can be used in pay().
     * @dev Add-only: there is intentionally no removeToken/disableToken (see note above).
     *      Pass NATIVE_TOKEN to enable native (ETH/BNB) payments. Reverts on zero address
     *      or a token that is already allowed.
     * @param token Token address to allow, or NATIVE_TOKEN for the chain's native asset.
     */
    function addToken(address token) external onlyGov {
        if (token == address(0)) revert ZeroAddress();
        if (allowedTokens[token]) revert AlreadyAllowed();
        allowedTokens[token] = true;
        emit TokenAdded(token);
    }

    // ========================================================
    // ============ Fee Recipient Management ==================
    // ========================================================

    /**
     * @notice Add a new fee recipient.
     * @dev Audit fix H-04: zero-address + duplicate + size-cap guards.
     */
    function addFeeRecipient(address recipient) external onlyGov {
        if (recipient == address(0)) revert ZeroAddress();
        if (isFeeRecipient[recipient]) revert AlreadyFeeRecipient();
        if (feeRecipients.length >= MAX_FEE_RECIPIENTS) revert TooManyRecipients();

        isFeeRecipient[recipient] = true;
        feeRecipients.push(recipient);
        emit FeeRecipientAdded(recipient);
    }

    /**
     * @notice Remove a fee recipient.
     * @param index Array index of the recipient to remove.
     * @param expectedAddress Expected address at that index (guards against index drift
     *                       between governance sign-off and on-chain execution).
     * @dev Audit fix M-06: dual-parameter confirmation prevents accidental wrong removal.
     */
    function removeFeeRecipient(uint256 index, address expectedAddress) external onlyGov {
        if (index >= feeRecipients.length) revert NotAFeeRecipient();
        if (feeRecipients.length <= 1) revert MustKeepAtLeastOne();

        address actual = feeRecipients[index];
        if (actual != expectedAddress) revert AddressMismatch();

        // swap-and-pop
        feeRecipients[index] = feeRecipients[feeRecipients.length - 1];
        feeRecipients.pop();
        isFeeRecipient[actual] = false;

        emit FeeRecipientRemoved(index, actual);
    }

    // ========================================================
    // ============ Governance Transfer (two-step) ============
    // ========================================================

    /**
     * @notice Begin a two-step governance handoff.
     * @dev Audit fix M-03: the new governance must call acceptGovernance() to take effect,
     *      preventing accidental permanent loss of access via a typo.
     */
    function transferGovernance(address newGov) external onlyGov {
        if (newGov == address(0)) revert ZeroAddress();
        pendingGovernance = newGov;
        emit GovernanceTransferStarted(governance, newGov);
    }

    /// @notice New governance accepts the role.
    function acceptGovernance() external {
        if (msg.sender != pendingGovernance) revert NotPendingGovernance();
        address old = governance;
        governance = pendingGovernance;
        pendingGovernance = address(0);
        emit GovernanceTransferred(old, governance);
    }

    /**
     * @notice Permanently renounce governance (irreversible).
     * @dev After this call, governance == address(0). Every onlyGov function reverts.
     *      Fee rate / whitelist / recipients freeze at their current values forever.
     *      This is the "graduation" switch: once the protocol is stable, governance
     *      can step away entirely.
     */
    function renounceGovernance() external onlyGov {
        address old = governance;
        governance = address(0);
        pendingGovernance = address(0);
        emit GovernanceTransferred(old, address(0));
    }

    // ========================================================
    // ============ Merchant Signer Delegation ================
    // ========================================================
    // Merchant-sovereign: each merchant writes its own `merchantSigner` slot directly.
    // No governance, no timelock — a merchant must be able to rotate / revoke a leaked
    // delegate key without waiting 7 days. The signer field is scoped to that merchant
    // only; it cannot grant signing authority for any other merchant.

    /// @notice Set or clear the merchant's authorized signing delegate.
    /// @dev    msg.sender is the merchant. Passing `newSigner == address(0)` clears
    ///         delegation so only the merchant itself can sign subsequent orders.
    /// @param newSigner New delegate address (or address(0) to clear).
    function setSigner(address newSigner) external {
        address oldSigner = merchantSigner[msg.sender];
        merchantSigner[msg.sender] = newSigner;
        emit SignerUpdated(msg.sender, oldSigner, newSigner);
    }

    // ========================================================
    // ============ Merchant Receiver Hint (v1.4+) ============
    // ========================================================
    // Self-sovereign default-payout hint. Each merchant writes its own
    // `merchantReceiver` slot directly — no governance, no timelock. pay()
    // never reads this slot: the payout destination is the `receiver` field
    // of the signed Order. Rotating this value lets dashboards / order
    // builders pick up a new default for FUTURE orders without invalidating
    // already-signed ones.

    /// @notice Set or clear the merchant's default payout receiver (UX hint only).
    /// @dev    msg.sender is the merchant. `newReceiver == address(0)` clears the hint.
    ///         This is NOT validated against future order signatures — pay() uses the
    ///         receiver embedded in the signed order, never this mapping.
    /// @param newReceiver New default receiver (or address(0) to clear).
    function setReceiver(address newReceiver) external {
        address oldReceiver = merchantReceiver[msg.sender];
        merchantReceiver[msg.sender] = newReceiver;
        emit ReceiverUpdated(msg.sender, oldReceiver, newReceiver);
    }

    // ========================================================
    // ============ View Functions ============================
    // ========================================================

    /// @notice Return all fee recipients (for front-end integrations).
    function getFeeRecipients() external view returns (address[] memory) {
        return feeRecipients;
    }

    /// @notice Return the size of the fee-recipient pool.
    function feeRecipientsLength() external view returns (uint256) {
        return feeRecipients.length;
    }

    /// @notice Look up an order record. Returns a zero-valued struct (payer == address(0))
    ///         if no order was paid for this (merchant, orderId) pair.
    function getOrder(address merchant, bytes32 orderId) external view returns (OrderRecord memory) {
        return orders[keccak256(abi.encode(merchant, orderId))];
    }

    /// @notice EIP-712 domain separator for the current chain / contract address.
    /// @dev    Front-ends should use this to verify they are signing against the correct domain.
    // solhint-disable-next-line func-name-mixedcase
    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /// @notice Compute the fee for a given amount under the current rate (linear, no cap).
    function calculateFee(uint256 amount) external view returns (uint256) {
        return (amount * currentFeeRate) / BASIS_POINTS_DENOMINATOR;
    }

    // ========================================================
    // ============ NO receive / fallback =====================
    // ========================================================
    // receive() and fallback() are intentionally not implemented. Any bare native
    // transfer to this contract reverts. Native value only enters via pay() or
    // refund() and exits in the same call, so the contract's balance is always 0.

    // ========================================================
    // ============ NO pause / NO emergency / NO admin ========
    // ============ NO disableToken / NO removeToken ==========
    // ========================================================
    // The following functions are deliberately absent:
    //   - pause / unpause
    //   - emergencyMultisig / setEmergencyMultisig
    //   - emergencyReduceFee
    //   - disableToken / removeToken
    // Any token in the whitelist stays in; any running pay() cannot be stopped.
    // That is the merchant-facing core commitment of this contract:
    //   the whitelist only grows, and payments are uninterruptible.
}
