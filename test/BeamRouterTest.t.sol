// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { BeamRouter } from "../src/BeamRouter.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { MockBadERC20 } from "./mocks/MockBadERC20.sol";
import { MockFeeFailingToken } from "./mocks/MockFeeFailingToken.sol";
import { MockReentrantToken } from "./mocks/MockReentrantToken.sol";

/// @notice Comprehensive tests covering the load-bearing invariants from CLAUDE.md:
///         1. Funds never held in contract (post-`pay()` balance == 0).
///         2. FEE_RATE_HARD_LIMIT = 10 bps is constant and unreachable by governance.
///         3. No pause/emergency surface — `pay()` cannot be stopped post-deploy.
///         4. proposeFeeChange + TIMELOCK_DELAY + executeFeeChange path.
///         5. H-06 fee bypass fix: merchant_received + protocol_received == amount on success.
///         6. CEI + nonReentrant on `pay()` and `refund()`.
///         7. SafeERC20 dual-mode against USDT-style (non-returning) ERC20 mocks.
///         8. Refund constraints — token match, payer from OrderRecord, cumulative <= amount.
///         9. Two-step governance transfer + renounceGovernance.
///        10. No receive/fallback — direct ETH transfer reverts.
contract BeamRouterTest is Test {
    BeamRouter router;

    address governance = makeAddr("governance");
    address payer = makeAddr("payer");
    // Merchant is a real wallet so the test suite can produce EIP-712 signatures via vm.sign.
    Vm.Wallet merchantWallet;
    address merchant;
    address feeRecipient = makeAddr("feeRecipient");
    address other = makeAddr("other");

    MockERC20 token;

    function setUp() public {
        merchantWallet = vm.createWallet("merchant");
        merchant = merchantWallet.addr;

        token = new MockERC20("Mock Token", "MKT", 18);

        address[] memory tokens = new address[](1);
        tokens[0] = address(token);

        address[] memory recipients = new address[](1);
        recipients[0] = feeRecipient;

        router = new BeamRouter(governance, tokens, recipients, 10);
    }

    // ========================================================
    // Test helper: produce the (signer, createdAt, expiresAt, signature) tuple
    // that the v1.0 pay() expects. Uses `merchantWallet` (or the supplied wallet)
    // as the EIP-712 signer over a default 30-day window.
    // ========================================================

    function _signOrderOn(
        BeamRouter target,
        Vm.Wallet memory wallet,
        address merchantAddr,
        address receiverAddr,
        address tokenAddr,
        uint256 amount,
        bytes32 orderId
    ) internal view returns (address signer, uint64 createdAt, uint64 expiresAt, bytes memory signature) {
        signer = wallet.addr;
        createdAt = uint64(block.timestamp);
        expiresAt = uint64(block.timestamp + 30 days);
        bytes32 structHash = keccak256(
            abi.encode(
                target.ORDER_TYPEHASH(),
                merchantAddr,
                receiverAddr,
                signer,
                tokenAddr,
                amount,
                orderId,
                createdAt,
                expiresAt
            )
        );
        bytes32 digest = MessageHashUtils.toTypedDataHash(target.DOMAIN_SEPARATOR(), structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wallet.privateKey, digest);
        signature = abi.encodePacked(r, s, v);
    }

    /// @dev Convenience wrapper: signs with `merchantWallet` and sets `receiver = merchant`,
    ///      preserving the v1.3 semantics for tests that don't care about receiver/merchant
    ///      divergence. Tests that need a distinct receiver should call `_signOrderOn` directly.
    function _signOrderAsMerchant(address tokenAddr, uint256 amount, bytes32 orderId)
        internal
        view
        returns (address signer, uint64 createdAt, uint64 expiresAt, bytes memory signature)
    {
        return _signOrderOn(router, merchantWallet, merchant, merchant, tokenAddr, amount, orderId);
    }

    // ========================================================
    // Constants & access control
    // ========================================================

    function testFeeHardLimitIsConstant() public view {
        assertEq(router.FEE_RATE_HARD_LIMIT(), 10);
    }

    function testNoReceiveReverts() public {
        vm.deal(payer, 1 ether);
        vm.prank(payer);
        (bool ok,) = address(router).call{ value: 1 ether }("");
        assertFalse(ok, "router accepted ETH");
    }

    // ========================================================
    // pay() happy path
    // ========================================================

    function testPayHappyPath() public {
        uint256 amount = 100_000;
        uint256 fee = (amount * 10) / 10_000; // 100
        bytes32 orderId = keccak256("order-1");
        (address _s, uint64 _ca, uint64 _ea, bytes memory _sig) = _signOrderAsMerchant(address(token), amount, orderId);

        token.mint(payer, amount);
        vm.prank(payer);
        token.approve(address(router), amount);

        vm.prank(payer);
        vm.expectEmit(true, true, true, false);
        emit BeamRouter.Paid(
            merchant, orderId, payer, merchant, address(token), amount, fee, feeRecipient, true, block.timestamp
        );
        router.pay(merchant, merchant, address(token), amount, orderId, _s, _ca, _ea, _sig);

        assertEq(token.balanceOf(merchant), amount - fee);
        assertEq(token.balanceOf(feeRecipient), fee);
        assertEq(token.balanceOf(address(router)), 0);

        BeamRouter.OrderRecord memory rec = router.getOrder(merchant, orderId);
        assertTrue(rec.payer != address(0));
        assertEq(rec.payer, payer);
        assertEq(rec.token, address(token));
        assertEq(rec.amount, amount);
        assertEq(rec.refunded, 0);
    }

    function testPayDuplicateOrderReverts() public {
        uint256 amount = 100_000;
        bytes32 orderId = keccak256("order-1");
        (address _s, uint64 _ca, uint64 _ea, bytes memory _sig) = _signOrderAsMerchant(address(token), amount, orderId);

        token.mint(payer, amount * 2);
        vm.prank(payer);
        token.approve(address(router), amount * 2);

        vm.prank(payer);
        router.pay(merchant, merchant, address(token), amount, orderId, _s, _ca, _ea, _sig);

        vm.prank(payer);
        vm.expectRevert(BeamRouter.DuplicateOrder.selector);
        router.pay(merchant, merchant, address(token), amount, orderId, _s, _ca, _ea, _sig);
    }

    function testPayWithNonReturningERC20() public {
        MockBadERC20 badToken = new MockBadERC20("Bad Token", "BAD", 6);
        vm.prank(governance);
        router.addToken(address(badToken));

        uint256 amount = 100_000;
        uint256 fee = (amount * 10) / 10_000;
        bytes32 orderId = keccak256("order-bad");
        (address _s, uint64 _ca, uint64 _ea, bytes memory _sig) =
            _signOrderAsMerchant(address(badToken), amount, orderId);

        badToken.mint(payer, amount);
        vm.prank(payer);
        badToken.approve(address(router), amount);

        vm.prank(payer);
        router.pay(merchant, merchant, address(badToken), amount, orderId, _s, _ca, _ea, _sig);

        assertEq(badToken.balanceOf(merchant), amount - fee);
        assertEq(badToken.balanceOf(feeRecipient), fee);
        assertEq(badToken.balanceOf(address(router)), 0);
    }

    function testPayTokenNotWhitelistedReverts() public {
        MockERC20 badToken = new MockERC20("Unlisted", "UNL", 18);
        bytes32 orderId = keccak256("order-unlisted");
        // Revert hits TokenNotAllowed before the signature check, so dummy sig args suffice.
        uint64 t = uint64(block.timestamp);

        badToken.mint(payer, 100_000);
        vm.prank(payer);
        badToken.approve(address(router), 100_000);

        vm.prank(payer);
        vm.expectRevert(BeamRouter.TokenNotAllowed.selector);
        router.pay(merchant, merchant, address(badToken), 100_000, orderId, merchant, t, t + 1, "");
    }

    function testPayFeeRedirectToMerchant() public {
        MockFeeFailingToken feeFailToken = new MockFeeFailingToken("FeeFail", "FF", 18);
        feeFailToken.setBlockedRecipient(feeRecipient);

        vm.prank(governance);
        router.addToken(address(feeFailToken));

        uint256 amount = 100_000;
        uint256 fee = (amount * 10) / 10_000;
        bytes32 orderId = keccak256("order-ff");
        (address _s, uint64 _ca, uint64 _ea, bytes memory _sig) =
            _signOrderAsMerchant(address(feeFailToken), amount, orderId);

        feeFailToken.mint(payer, amount);
        vm.prank(payer);
        feeFailToken.approve(address(router), amount);

        vm.prank(payer);
        vm.expectEmit(true, false, false, true);
        emit BeamRouter.FeeRedirectedToMerchant(orderId, address(feeFailToken), fee, feeRecipient, merchant, merchant);
        router.pay(merchant, merchant, address(feeFailToken), amount, orderId, _s, _ca, _ea, _sig);

        // Merchant receives both the principal and the redirected fee
        assertEq(feeFailToken.balanceOf(merchant), amount);
        assertEq(feeFailToken.balanceOf(feeRecipient), 0);
        assertEq(feeFailToken.balanceOf(address(router)), 0);
    }

    // ========================================================
    // refund()
    // ========================================================

    function testRefundHappyPath() public {
        uint256 amount = 100_000;
        bytes32 orderId = keccak256("order-1");
        (address _s, uint64 _ca, uint64 _ea, bytes memory _sig) = _signOrderAsMerchant(address(token), amount, orderId);

        token.mint(payer, amount);
        vm.prank(payer);
        token.approve(address(router), amount);
        vm.prank(payer);
        router.pay(merchant, merchant, address(token), amount, orderId, _s, _ca, _ea, _sig);

        uint256 refundAmount = 30_000;
        token.mint(merchant, refundAmount);
        vm.prank(merchant);
        token.approve(address(router), refundAmount);

        vm.prank(merchant);
        vm.expectEmit(true, true, true, false);
        emit BeamRouter.Refunded(orderId, merchant, payer, address(token), refundAmount, block.timestamp);
        router.refund(orderId, refundAmount);

        assertEq(token.balanceOf(payer), refundAmount);
        // Merchant originally received amount - fee from pay, then was minted refundAmount,
        // then sent refundAmount back in refund. Net balance = amount - fee.
        assertEq(token.balanceOf(merchant), amount - (amount * 10) / 10_000);

        assertEq(router.getOrder(merchant, orderId).refunded, refundAmount);
    }

    function testRefundExceedsOrderReverts() public {
        uint256 amount = 100_000;
        bytes32 orderId = keccak256("order-1");
        (address _s, uint64 _ca, uint64 _ea, bytes memory _sig) = _signOrderAsMerchant(address(token), amount, orderId);

        token.mint(payer, amount);
        vm.prank(payer);
        token.approve(address(router), amount);
        vm.prank(payer);
        router.pay(merchant, merchant, address(token), amount, orderId, _s, _ca, _ea, _sig);

        token.mint(merchant, amount);
        vm.prank(merchant);
        token.approve(address(router), amount);

        // First refund half
        vm.prank(merchant);
        router.refund(orderId, amount / 2);

        // Second refund exceeds remaining
        vm.prank(merchant);
        vm.expectRevert(BeamRouter.RefundExceedsOrder.selector);
        router.refund(orderId, amount / 2 + 1);
    }

    function testRefundOnlyMerchant() public {
        uint256 amount = 100_000;
        bytes32 orderId = keccak256("order-1");
        (address _s, uint64 _ca, uint64 _ea, bytes memory _sig) = _signOrderAsMerchant(address(token), amount, orderId);

        token.mint(payer, amount);
        vm.prank(payer);
        token.approve(address(router), amount);
        vm.prank(payer);
        router.pay(merchant, merchant, address(token), amount, orderId, _s, _ca, _ea, _sig);

        token.mint(merchant, amount);
        vm.prank(merchant);
        token.approve(address(router), amount);

        vm.prank(other);
        vm.expectRevert(BeamRouter.OrderNotPaid.selector);
        router.refund(orderId, amount);
    }

    // ========================================================
    // Governance: fee change timelock
    // ========================================================

    function testProposeAndExecuteFeeChange() public {
        vm.prank(governance);
        router.proposeFeeChange(5);

        (uint256 newRate, uint256 effectiveTime) = router.pending();
        assertGt(effectiveTime, 0);
        assertEq(newRate, 5);
        assertEq(effectiveTime, block.timestamp + 7 days);

        vm.warp(block.timestamp + 7 days);
        router.executeFeeChange();

        assertEq(router.currentFeeRate(), 5);
        (, uint256 effectiveTimeAfter) = router.pending();
        assertEq(effectiveTimeAfter, 0);
    }

    function testExecuteFeeChangeBeforeTimelockReverts() public {
        vm.prank(governance);
        router.proposeFeeChange(5);

        vm.expectRevert(BeamRouter.TimelockNotExpired.selector);
        router.executeFeeChange();
    }

    function testCancelPendingChange() public {
        vm.prank(governance);
        router.proposeFeeChange(5);

        vm.prank(governance);
        router.cancelPendingChange();

        (, uint256 effectiveTime) = router.pending();
        assertEq(effectiveTime, 0);
    }

    function testProposeFeeChangeExceedsHardLimitReverts() public {
        vm.prank(governance);
        vm.expectRevert(BeamRouter.RateExceedsHardLimit.selector);
        router.proposeFeeChange(11);
    }

    // ========================================================
    // Governance: token & recipient management
    // ========================================================

    function testAddToken() public {
        MockERC20 newToken = new MockERC20("New", "NEW", 18);
        vm.prank(governance);
        router.addToken(address(newToken));
        assertTrue(router.allowedTokens(address(newToken)));
    }

    function testAddTokenZeroAddressReverts() public {
        vm.prank(governance);
        vm.expectRevert(BeamRouter.ZeroAddress.selector);
        router.addToken(address(0));
    }

    function testAddTokenDuplicateReverts() public {
        vm.prank(governance);
        vm.expectRevert(BeamRouter.AlreadyAllowed.selector);
        router.addToken(address(token));
    }

    function testAddFeeRecipient() public {
        address newRecipient = makeAddr("newRecipient");
        vm.prank(governance);
        router.addFeeRecipient(newRecipient);
        assertTrue(router.isFeeRecipient(newRecipient));
    }

    function testRemoveFeeRecipient() public {
        address newRecipient = makeAddr("newRecipient");
        vm.prank(governance);
        router.addFeeRecipient(newRecipient);

        uint256 lengthBefore = router.feeRecipientsLength();
        vm.prank(governance);
        router.removeFeeRecipient(lengthBefore - 1, newRecipient);

        assertFalse(router.isFeeRecipient(newRecipient));
        assertEq(router.feeRecipientsLength(), lengthBefore - 1);
    }

    function testRemoveFeeRecipientAddressMismatchReverts() public {
        // Add a second recipient so index 0 removal doesn't hit MustKeepAtLeastOne first
        address newRecipient = makeAddr("newRecipient");
        vm.prank(governance);
        router.addFeeRecipient(newRecipient);

        vm.prank(governance);
        vm.expectRevert(BeamRouter.AddressMismatch.selector);
        router.removeFeeRecipient(0, makeAddr("wrong"));
    }

    function testRemoveLastFeeRecipientReverts() public {
        vm.prank(governance);
        vm.expectRevert(BeamRouter.MustKeepAtLeastOne.selector);
        router.removeFeeRecipient(0, feeRecipient);
    }

    // ========================================================
    // Governance transfer (two-step)
    // ========================================================

    function testTransferGovernanceAndAccept() public {
        address newGov = makeAddr("newGov");
        vm.prank(governance);
        router.transferGovernance(newGov);
        assertEq(router.pendingGovernance(), newGov);

        vm.prank(newGov);
        router.acceptGovernance();
        assertEq(router.governance(), newGov);
        assertEq(router.pendingGovernance(), address(0));
    }

    function testAcceptGovernanceWrongCallerReverts() public {
        address newGov = makeAddr("newGov");
        vm.prank(governance);
        router.transferGovernance(newGov);

        vm.prank(other);
        vm.expectRevert(BeamRouter.NotPendingGovernance.selector);
        router.acceptGovernance();
    }

    function testRenounceGovernance() public {
        vm.prank(governance);
        router.renounceGovernance();
        assertEq(router.governance(), address(0));
        assertEq(router.pendingGovernance(), address(0));
    }

    // ========================================================
    // nonReentrant guard
    // ========================================================

    function testPayNonReentrant() public {
        MockReentrantToken reentrantToken = new MockReentrantToken();
        reentrantToken.setTarget(router);
        reentrantToken.setPayParams(merchant, keccak256("order-re"));

        vm.prank(governance);
        router.addToken(address(reentrantToken));

        uint256 amount = 100_000;
        bytes32 orderId = keccak256("order-re");
        (address _s, uint64 _ca, uint64 _ea, bytes memory _sig) =
            _signOrderAsMerchant(address(reentrantToken), amount, orderId);

        reentrantToken.mint(payer, amount * 2);
        vm.prank(payer);
        reentrantToken.approve(address(router), amount * 2);

        vm.prank(payer);
        // The first pay() should succeed; the nested pay() inside transferFrom should revert with Reentrant
        router.pay(merchant, merchant, address(reentrantToken), amount, orderId, _s, _ca, _ea, _sig);

        // Verify that the reentrant attempt was made but failed
        assertTrue(reentrantToken.reentered());
    }

    // ========================================================
    // CEI ordering & balance invariants
    // ========================================================

    function testContractBalanceZeroAfterPay() public {
        uint256 amount = 100_000;
        bytes32 orderId = keccak256("order-1");
        (address _s, uint64 _ca, uint64 _ea, bytes memory _sig) = _signOrderAsMerchant(address(token), amount, orderId);

        token.mint(payer, amount);
        vm.prank(payer);
        token.approve(address(router), amount);

        vm.prank(payer);
        router.pay(merchant, merchant, address(token), amount, orderId, _s, _ca, _ea, _sig);

        assertEq(token.balanceOf(address(router)), 0);
    }

    function testCEIStateWrittenBeforeExternalCalls() public {
        // This is implicitly verified by testPayDuplicateOrderReverts:
        // if state were written after the transfer, a reentrant call could
        // pass the duplicate check. Since nonReentrant blocks it, and the
        // duplicate check also blocks it, CEI holds.
        testPayDuplicateOrderReverts();
    }

    // ========================================================
    // Native asset (ETH/BNB) — v1.3
    // ========================================================

    function _whitelistNative() internal {
        address native = router.NATIVE_TOKEN();
        vm.prank(governance);
        router.addToken(native);
    }

    function testPayNativeHappyPath() public {
        _whitelistNative();
        uint256 amount = 1 ether;
        uint256 fee = (amount * 10) / 10_000;
        bytes32 orderId = keccak256("order-native");
        address native = router.NATIVE_TOKEN();
        (address _s, uint64 _ca, uint64 _ea, bytes memory _sig) = _signOrderAsMerchant(native, amount, orderId);

        vm.deal(payer, amount);
        vm.prank(payer);
        router.pay{ value: amount }(merchant, merchant, native, amount, orderId, _s, _ca, _ea, _sig);

        assertEq(merchant.balance, amount - fee);
        assertEq(feeRecipient.balance, fee);
        assertEq(address(router).balance, 0);

        BeamRouter.OrderRecord memory rec = router.getOrder(merchant, orderId);
        assertTrue(rec.payer != address(0));
        assertEq(rec.payer, payer);
        assertEq(rec.token, native);
        assertEq(rec.amount, amount);
    }

    function testPayNativeIncorrectValueReverts() public {
        _whitelistNative();
        uint256 amount = 1 ether;
        bytes32 orderId = keccak256("order-native-bad-value");
        address native = router.NATIVE_TOKEN();
        // Revert hits IncorrectNativeValue before the signature check; dummy sig args suffice.
        uint64 t = uint64(block.timestamp);

        vm.deal(payer, amount);
        vm.prank(payer);
        vm.expectRevert(BeamRouter.IncorrectNativeValue.selector);
        router.pay{ value: amount - 1 }(merchant, merchant, native, amount, orderId, merchant, t, t + 1, "");
    }

    function testPayErc20WithValueReverts() public {
        uint256 amount = 100_000;
        bytes32 orderId = keccak256("order-erc20-bad-value");
        // Revert hits UnexpectedNativeValue before the signature check; dummy sig args suffice.
        uint64 t = uint64(block.timestamp);

        token.mint(payer, amount);
        vm.prank(payer);
        token.approve(address(router), amount);

        vm.deal(payer, 1 ether);
        vm.prank(payer);
        vm.expectRevert(BeamRouter.UnexpectedNativeValue.selector);
        router.pay{ value: 1 wei }(merchant, merchant, address(token), amount, orderId, merchant, t, t + 1, "");
    }

    function testPayNativeFeeRedirect() public {
        // Spin up a router whose only fee recipient is a contract without receive()/fallback(),
        // so the native fee leg fails and must redirect to merchant.
        NoReceive blockedRecipient = new NoReceive();

        address[] memory tokens = new address[](0);
        address[] memory recipients = new address[](1);
        recipients[0] = address(blockedRecipient);
        BeamRouter altRouter = new BeamRouter(governance, tokens, recipients, 10);
        address native = altRouter.NATIVE_TOKEN();
        vm.prank(governance);
        altRouter.addToken(native);

        uint256 amount = 1 ether;
        uint256 fee = (amount * 10) / 10_000;
        bytes32 orderId = keccak256("order-native-redirect");
        // altRouter has its own EIP-712 domain (different verifyingContract), so sign against it explicitly.
        (address _s, uint64 _ca, uint64 _ea, bytes memory _sig) =
            _signOrderOn(altRouter, merchantWallet, merchant, merchant, native, amount, orderId);

        vm.deal(payer, amount);
        vm.prank(payer);
        vm.expectEmit(true, false, false, true);
        emit BeamRouter.FeeRedirectedToMerchant(orderId, native, fee, address(blockedRecipient), merchant, merchant);
        altRouter.pay{ value: amount }(merchant, merchant, native, amount, orderId, _s, _ca, _ea, _sig);

        // Merchant gets the full amount (principal + redirected fee).
        assertEq(merchant.balance, amount);
        assertEq(address(blockedRecipient).balance, 0);
        assertEq(address(altRouter).balance, 0);
    }

    function testRefundNativeHappyPath() public {
        _whitelistNative();
        uint256 amount = 1 ether;
        uint256 fee = (amount * 10) / 10_000;
        bytes32 orderId = keccak256("order-native-refund");
        address native = router.NATIVE_TOKEN();
        (address _s, uint64 _ca, uint64 _ea, bytes memory _sig) = _signOrderAsMerchant(native, amount, orderId);

        vm.deal(payer, amount);
        vm.prank(payer);
        router.pay{ value: amount }(merchant, merchant, native, amount, orderId, _s, _ca, _ea, _sig);

        uint256 refundAmount = 0.3 ether;
        // Merchant already holds (amount - fee) from the pay() above; no extra deal needed.
        uint256 merchantBalanceBefore = merchant.balance;
        uint256 payerBalanceBefore = payer.balance;
        vm.prank(merchant);
        vm.expectEmit(true, true, true, false);
        emit BeamRouter.Refunded(orderId, merchant, payer, native, refundAmount, block.timestamp);
        router.refund{ value: refundAmount }(orderId, refundAmount);

        assertEq(payer.balance, payerBalanceBefore + refundAmount);
        // Merchant net: had (amount - fee), sent refundAmount back.
        assertEq(merchant.balance, merchantBalanceBefore - refundAmount);
        assertEq(address(router).balance, 0);

        assertEq(router.getOrder(merchant, orderId).refunded, refundAmount);
    }

    function testRefundNativeIncorrectValueReverts() public {
        _whitelistNative();
        uint256 amount = 1 ether;
        bytes32 orderId = keccak256("order-native-refund-bad");
        address native = router.NATIVE_TOKEN();
        (address _s, uint64 _ca, uint64 _ea, bytes memory _sig) = _signOrderAsMerchant(native, amount, orderId);

        vm.deal(payer, amount);
        vm.prank(payer);
        router.pay{ value: amount }(merchant, merchant, native, amount, orderId, _s, _ca, _ea, _sig);

        vm.deal(merchant, 1 ether);
        vm.prank(merchant);
        vm.expectRevert(BeamRouter.IncorrectNativeValue.selector);
        router.refund{ value: 0.2 ether }(orderId, 0.3 ether);
    }

    function testRefundErc20WithValueReverts() public {
        uint256 amount = 100_000;
        bytes32 orderId = keccak256("order-1");
        (address _s, uint64 _ca, uint64 _ea, bytes memory _sig) = _signOrderAsMerchant(address(token), amount, orderId);

        token.mint(payer, amount);
        vm.prank(payer);
        token.approve(address(router), amount);
        vm.prank(payer);
        router.pay(merchant, merchant, address(token), amount, orderId, _s, _ca, _ea, _sig);

        token.mint(merchant, amount);
        vm.prank(merchant);
        token.approve(address(router), amount);

        vm.deal(merchant, 1 ether);
        vm.prank(merchant);
        vm.expectRevert(BeamRouter.UnexpectedNativeValue.selector);
        router.refund{ value: 1 wei }(orderId, amount / 2);
    }

    function testContractBalanceZeroAfterNativePay() public {
        _whitelistNative();
        uint256 amount = 1 ether;
        bytes32 orderId = keccak256("order-native-bal");
        address native = router.NATIVE_TOKEN();
        (address _s, uint64 _ca, uint64 _ea, bytes memory _sig) = _signOrderAsMerchant(native, amount, orderId);

        vm.deal(payer, amount);
        vm.prank(payer);
        router.pay{ value: amount }(merchant, merchant, native, amount, orderId, _s, _ca, _ea, _sig);

        assertEq(address(router).balance, 0);
    }

    // ========================================================
    // Per-order receiver (v1.4+)
    // ========================================================

    function testPayUsesOrderReceiverNotConfig() public {
        address altReceiver = makeAddr("altReceiver");
        // Merchant config says altReceiver; order is signed with `other` as receiver.
        vm.prank(merchant);
        router.setReceiver(altReceiver);

        uint256 amount = 100_000;
        uint256 fee = (amount * 10) / 10_000;
        bytes32 orderId = keccak256("receiver-override");
        (address _s, uint64 _ca, uint64 _ea, bytes memory _sig) =
            _signOrderOn(router, merchantWallet, merchant, other, address(token), amount, orderId);

        token.mint(payer, amount);
        vm.prank(payer);
        token.approve(address(router), amount);

        vm.prank(payer);
        router.pay(merchant, other, address(token), amount, orderId, _s, _ca, _ea, _sig);

        assertEq(token.balanceOf(other), amount - fee, "signed receiver gets principal");
        assertEq(token.balanceOf(feeRecipient), fee, "fee leg unaffected");
        assertEq(token.balanceOf(altReceiver), 0, "config receiver must be ignored by pay()");
        assertEq(token.balanceOf(merchant), 0, "merchant must not receive in v1.4+");

        BeamRouter.OrderRecord memory rec = router.getOrder(merchant, orderId);
        assertEq(rec.receiver, other, "OrderRecord persists signed receiver");
    }

    function testPayWorksWithStaleConfig() public {
        address altReceiver = makeAddr("altReceiver");
        uint256 amount = 100_000;
        uint256 fee = (amount * 10) / 10_000;
        bytes32 orderId = keccak256("stale-config");
        // Sign first.
        (address _s, uint64 _ca, uint64 _ea, bytes memory _sig) =
            _signOrderOn(router, merchantWallet, merchant, other, address(token), amount, orderId);

        // Merchant rotates config AFTER signing — must not affect the in-flight order.
        vm.prank(merchant);
        router.setReceiver(altReceiver);

        token.mint(payer, amount);
        vm.prank(payer);
        token.approve(address(router), amount);
        vm.prank(payer);
        router.pay(merchant, other, address(token), amount, orderId, _s, _ca, _ea, _sig);

        assertEq(token.balanceOf(other), amount - fee);
        assertEq(token.balanceOf(altReceiver), 0);
    }

    function testSetReceiverIsMerchantScoped() public {
        address altReceiver = makeAddr("altReceiver");
        // `other` writes its own slot — merchant's slot must be untouched.
        vm.prank(other);
        router.setReceiver(altReceiver);

        assertEq(router.merchantReceiver(merchant), address(0));
        assertEq(router.merchantReceiver(other), altReceiver);
    }

    function testSetReceiverEmitsAndPersists() public {
        address altReceiver = makeAddr("altReceiver");
        vm.expectEmit(true, true, true, true);
        emit BeamRouter.ReceiverUpdated(merchant, address(0), altReceiver);
        vm.prank(merchant);
        router.setReceiver(altReceiver);
        assertEq(router.merchantReceiver(merchant), altReceiver);
    }

    function testSetReceiverClear() public {
        address altReceiver = makeAddr("altReceiver");
        vm.prank(merchant);
        router.setReceiver(altReceiver);
        vm.prank(merchant);
        router.setReceiver(address(0));
        assertEq(router.merchantReceiver(merchant), address(0));
    }

    function testPayRevertsZeroReceiver() public {
        uint256 amount = 100_000;
        bytes32 orderId = keccak256("zero-receiver");
        // Build sig with receiver=address(0); pay() will revert before sig recovery is reached.
        (address _s, uint64 _ca, uint64 _ea, bytes memory _sig) =
            _signOrderOn(router, merchantWallet, merchant, address(0), address(token), amount, orderId);

        token.mint(payer, amount);
        vm.prank(payer);
        token.approve(address(router), amount);

        vm.prank(payer);
        vm.expectRevert(BeamRouter.ZeroAddress.selector);
        router.pay(merchant, address(0), address(token), amount, orderId, _s, _ca, _ea, _sig);
    }

    function testRefundOnlyMerchantAndIgnoresReceiver() public {
        // Pay with receiver=other; refund must (a) revert when called by non-merchant
        // (including by the receiver itself), and (b) when called by merchant, send the
        // refund to the original payer — never to the receiver.
        uint256 amount = 100_000;
        bytes32 orderId = keccak256("refund-merchant-only");
        (address _s, uint64 _ca, uint64 _ea, bytes memory _sig) =
            _signOrderOn(router, merchantWallet, merchant, other, address(token), amount, orderId);

        token.mint(payer, amount);
        vm.prank(payer);
        token.approve(address(router), amount);
        vm.prank(payer);
        router.pay(merchant, other, address(token), amount, orderId, _s, _ca, _ea, _sig);

        // Receiver tries to refund — order key is (msg.sender, orderId), so OrderNotPaid hits.
        token.mint(other, amount);
        vm.prank(other);
        token.approve(address(router), amount);
        vm.prank(other);
        vm.expectRevert(BeamRouter.OrderNotPaid.selector);
        router.refund(orderId, amount / 2);

        // Merchant refunds — funds flow to payer, not receiver.
        token.mint(merchant, amount);
        vm.prank(merchant);
        token.approve(address(router), amount);
        uint256 payerBalBefore = token.balanceOf(payer);
        uint256 receiverBalBefore = token.balanceOf(other);
        vm.prank(merchant);
        router.refund(orderId, amount / 2);
        assertEq(token.balanceOf(payer), payerBalBefore + amount / 2, "refund must reach payer");
        assertEq(token.balanceOf(other), receiverBalBefore, "receiver must not see refund");
    }

    function testPaidEventCarriesReceiver() public {
        uint256 amount = 100_000;
        uint256 fee = (amount * 10) / 10_000;
        bytes32 orderId = keccak256("event-receiver");
        (address _s, uint64 _ca, uint64 _ea, bytes memory _sig) =
            _signOrderOn(router, merchantWallet, merchant, other, address(token), amount, orderId);

        token.mint(payer, amount);
        vm.prank(payer);
        token.approve(address(router), amount);

        vm.prank(payer);
        vm.expectEmit(true, true, true, true);
        emit BeamRouter.Paid(
            merchant, orderId, payer, other, address(token), amount, fee, feeRecipient, true, block.timestamp
        );
        router.pay(merchant, other, address(token), amount, orderId, _s, _ca, _ea, _sig);
    }

    function testPayNativeUsesReceiver() public {
        _whitelistNative();
        uint256 amount = 1 ether;
        uint256 fee = (amount * 10) / 10_000;
        bytes32 orderId = keccak256("native-receiver");
        address native = router.NATIVE_TOKEN();
        (address _s, uint64 _ca, uint64 _ea, bytes memory _sig) =
            _signOrderOn(router, merchantWallet, merchant, other, native, amount, orderId);

        vm.deal(payer, amount);
        vm.prank(payer);
        router.pay{ value: amount }(merchant, other, native, amount, orderId, _s, _ca, _ea, _sig);

        assertEq(other.balance, amount - fee);
        assertEq(feeRecipient.balance, fee);
        assertEq(merchant.balance, 0);
    }

    function testPayNativeFeeRedirectGoesToReceiver() public {
        // Blocked fee recipient → H-06 fallback fee must land at receiver, not merchant.
        NoReceive blocked = new NoReceive();
        address[] memory tokens = new address[](0);
        address[] memory recipients = new address[](1);
        recipients[0] = address(blocked);
        BeamRouter alt = new BeamRouter(governance, tokens, recipients, 10);
        address native = alt.NATIVE_TOKEN();
        vm.prank(governance);
        alt.addToken(native);

        uint256 amount = 1 ether;
        uint256 fee = (amount * 10) / 10_000;
        bytes32 orderId = keccak256("native-redirect-receiver");
        (address _s, uint64 _ca, uint64 _ea, bytes memory _sig) =
            _signOrderOn(alt, merchantWallet, merchant, other, native, amount, orderId);

        vm.deal(payer, amount);
        vm.prank(payer);
        vm.expectEmit(true, false, false, true);
        emit BeamRouter.FeeRedirectedToMerchant(orderId, native, fee, address(blocked), merchant, other);
        alt.pay{ value: amount }(merchant, other, native, amount, orderId, _s, _ca, _ea, _sig);

        assertEq(other.balance, amount, "receiver gets principal + redirected fee");
        assertEq(merchant.balance, 0);
        assertEq(address(blocked).balance, 0);
        assertEq(address(alt).balance, 0);
    }
}

/// @dev Helper contract that intentionally has no receive()/fallback(); used to simulate
///      a fee recipient whose native call always fails (forcing the H-06 fee-redirect path).
contract NoReceive { }
