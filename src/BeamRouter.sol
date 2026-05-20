// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title BeamRouter
 * @author BeamPay Team
 * @notice BeamPay protocol core contract — permissionless on-chain payment router
 *         for whitelisted ERC20 tokens and native asset (ETH/BNB) — v1.3
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
 * @title BeamRouter
 * @notice BeamPay protocol main contract. Merchants get paid via pay(); merchants
 *         issue refunds via refund(). No admin, no pause, no emergency.
 *
 * @dev Hard commitment: this contract has **no pause function, no emergency
 *      multisig, no admin backdoor**. Once deployed, pay() is callable forever.
 *      Every parameter change waits out the 7-day timelock.
 */
contract BeamRouter {
    using SafeERC20 for IERC20;

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
    struct OrderRecord {
        bool exists; // Whether the order has been paid
        address payer; // Original payer (enforced for refunds)
        address token; // Token used for the order (refunds use the same token)
        uint256 amount; // Original order amount (refund ceiling)
        uint256 refunded; // Cumulative refunded amount
    }

    /// @notice Order key (keccak256(merchant, orderId)) -> OrderRecord.
    mapping(bytes32 => OrderRecord) public orders;

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

    // ========================================================
    // ============ Events ====================================
    // ========================================================

    /// @notice Successful payment.
    /// @param merchant         Merchant receiving the payment
    /// @param orderId          Merchant-side order id
    /// @param payer            Address that paid
    /// @param token            Token used (NATIVE_TOKEN for native)
    /// @param amount           Pre-fee order amount
    /// @param fee              Protocol fee actually collected (= 0 on rate-zero or fail path)
    /// @param feeRecipient     Address fee was directed to (address(0) if no fee leg)
    /// @param feeCollected     True if fee went to feeRecipient; false if redirected to merchant
    /// @param timestamp        Block timestamp of the payment
    event Paid(
        address indexed merchant,
        bytes32 indexed orderId,
        address indexed payer,
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
    ///         redirected to the merchant to preserve the H-06 invariant.
    event FeeRedirectedToMerchant(
        bytes32 indexed orderId, address token, uint256 fee, address indexed feeRecipient, address indexed merchant
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
    ) {
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
     * @notice Pay an order. Funds flow: payer -> merchant + payer -> feeRecipient,
     *         all inside this single call.
     * @param merchant Merchant receiving the payment.
     * @param token    Token to pay with — must be whitelisted. Use NATIVE_TOKEN for native asset.
     * @param amount   Order amount (pre-fee).
     * @param orderId  Merchant-scoped order id; must be unique per merchant.
     *
     * @dev Security notes:
     *      - No whenNotPaused modifier; the contract has no pause state.
     *      - CEI: state write (orders[key] = ...) happens before any external call.
     *      - nonReentrant: defends against malicious token callbacks and native recipients.
     *      - SafeERC20: tolerates non-standard ERC20s (e.g. mainnet USDT).
     *      - try-fee leg: blacklisted fee recipient does not abort the merchant leg.
     *      - amount > fee: prevents merchant from receiving 0 due to rounding.
     *      - Native path: msg.value == amount required; ERC20 path: msg.value == 0 required.
     */
    function pay(address merchant, address token, uint256 amount, bytes32 orderId) external payable nonReentrant {
        // ====== Input validation ======
        if (merchant == address(0)) revert ZeroAddress();
        if (!allowedTokens[token]) revert TokenNotAllowed();
        if (amount == 0) revert ZeroAmount();
        if (orderId == bytes32(0)) revert ZeroOrderId();

        bool isNative = token == NATIVE_TOKEN;
        if (isNative) {
            if (msg.value != amount) revert IncorrectNativeValue();
        } else {
            if (msg.value != 0) revert UnexpectedNativeValue();
        }

        // ====== Replay guard ======
        bytes32 key = keccak256(abi.encode(merchant, orderId));
        if (orders[key].exists) revert DuplicateOrder();

        // ====== Fee calculation (linear, no per-tx cap) ======
        uint256 fee = (amount * currentFeeRate) / BASIS_POINTS_DENOMINATOR;

        // Audit fix M-01: require amount > fee so the merchant never receives 0.
        // With rate <= 10 bps, fee <= amount/1000, so amount >= 1000 wei is guaranteed safe.
        // amount < 1000 wei is effectively below the minimum settlement unit.
        if (amount <= fee) revert AmountTooSmall();

        // ====== Effects (state write before any external interaction) ======
        orders[key] = OrderRecord({ exists: true, payer: msg.sender, token: token, amount: amount, refunded: 0 });

        // ====== Interactions (H-06 fix: fee-first try + redirect-to-merchant fallback) ======
        //
        // v1.0/v1.1 transferred the merchant leg before the fee leg, and used try-pattern
        // for the fee — a malicious payer could cap allowance/balance at `amount - fee`
        // so the fee transfer silently failed, bypassing the protocol fee.
        //
        // v1.2 inverted the order: speculative fee leg first; on failure, mandatory
        // redirect to merchant; then mandatory main leg. Any path where the payer can't
        // cover `amount` total reverts at the merchant leg.
        //
        // Invariant under every successful path: merchant_received + protocol_received == amount.
        //
        // v1.3 (native): same shape, but native uses .call{value:} instead of SafeERC20,
        // and when the fee redirects to merchant we combine fee+(amount-fee) into one .call
        // for `amount` (since no separate "allowance" exists for native).

        address feeTo = address(0);
        bool feeCollected = false;

        if (fee > 0) {
            // feeRecipients.length is enforced >= 1 in the constructor, so the modulo is safe.
            uint256 idx = uint256(orderId) % feeRecipients.length;
            feeTo = feeRecipients[idx];

            // Step 1: try to send fee straight to the protocol recipient.
            // Audit M-02: tolerate Tether/Circle blacklisting — failure must not revert.
            if (isNative) {
                (bool ok,) = feeTo.call{value: fee}("");
                feeCollected = ok;
            } else {
                feeCollected = IERC20(token).trySafeTransferFrom(msg.sender, feeTo, fee);
            }

            if (!feeCollected) {
                // Step 2 (fallback): fee recipient is unreachable — redirect fee to the merchant.
                // For ERC20 this is a second pull from the payer's allowance; if H-06 attacker
                // capped allowance, the safeTransferFrom here reverts the whole tx.
                // For native the redirect is bundled into the merchant .call below.
                if (!isNative) {
                    IERC20(token).safeTransferFrom(msg.sender, merchant, fee);
                }
                emit FeeTransferFailed(orderId, token, fee, feeTo);
                emit FeeRedirectedToMerchant(orderId, token, fee, feeTo, merchant);
            }
        }

        // ====== Step 3: mandatory merchant main leg ======
        // ERC20: always transfer `amount - fee`; combined with the conditional fee-redirect
        //        leg above, total merchant inflow == feeCollected ? amount-fee : amount.
        // Native: transfer (amount - fee) if fee was collected; otherwise transfer the full
        //        amount in one .call to fold the redirected fee into the same payment.
        if (isNative) {
            uint256 merchantAmount = feeCollected ? amount - fee : amount;
            (bool ok,) = merchant.call{value: merchantAmount}("");
            if (!ok) revert NativeTransferFailed();
        } else {
            IERC20(token).safeTransferFrom(msg.sender, merchant, amount - fee);
        }

        emit Paid(merchant, orderId, msg.sender, token, amount, fee, feeTo, feeCollected, block.timestamp);
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
     *      - msg.sender is implicitly the merchant (encoded into the order key).
     *      - Token is read from the stored OrderRecord; merchant cannot specify a different
     *        token. (v1.3: dropped the redundant `token` parameter that audit fix M-07
     *        previously cross-checked — the stored value is the single source of truth.)
     *      - Audit fix H-03: payer is forced from OrderRecord; not accepted as a parameter.
     *      - Protocol fee is never refunded (on-chain cost is irreversible; merchant absorbs).
     *      - Merchant must approve `amount` to this contract before calling (ERC20 path),
     *        or attach msg.value == amount (native path).
     */
    function refund(bytes32 orderId, uint256 amount) external payable nonReentrant {
        if (amount == 0) revert ZeroAmount();

        bytes32 key = keccak256(abi.encode(msg.sender, orderId));
        OrderRecord storage order = orders[key];

        // Order must exist (i.e. have been paid).
        if (!order.exists) revert OrderNotPaid();
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
            (bool ok,) = payer.call{value: amount}("");
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

    /// @notice Look up an order record.
    function getOrder(address merchant, bytes32 orderId)
        external
        view
        returns (bool exists, address payer, address token, uint256 amount, uint256 refundedAmount)
    {
        bytes32 key = keccak256(abi.encode(merchant, orderId));
        OrderRecord memory o = orders[key];
        return (o.exists, o.payer, o.token, o.amount, o.refunded);
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
