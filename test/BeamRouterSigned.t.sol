// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { BeamRouter } from "../src/BeamRouter.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";

/// @notice v1.0 signed-order semantics: EIP-712 signature, signer delegation, expiry window.
///         These tests live next to BeamRouterTest.t.sol but focus only on the new surfaces.
contract BeamRouterSignedTest is Test {
    BeamRouter router;

    address governance = makeAddr("governance");
    address payer = makeAddr("payer");
    address feeRecipient = makeAddr("feeRecipient");

    Vm.Wallet merchantWallet;
    Vm.Wallet delegateWallet;
    Vm.Wallet attackerWallet;
    address merchant;

    MockERC20 token;

    uint64 constant DEFAULT_TTL = 30 days;

    function setUp() public {
        merchantWallet = vm.createWallet("merchant");
        delegateWallet = vm.createWallet("delegate");
        attackerWallet = vm.createWallet("attacker");
        merchant = merchantWallet.addr;

        token = new MockERC20("Mock Token", "MKT", 18);

        address[] memory tokens = new address[](1);
        tokens[0] = address(token);
        address[] memory recipients = new address[](1);
        recipients[0] = feeRecipient;

        router = new BeamRouter(governance, tokens, recipients, 10);
    }

    // ========================================================
    // Helpers
    // ========================================================

    function _signOrderOn(
        BeamRouter target,
        Vm.Wallet memory wallet,
        address merchantAddr,
        address receiverAddr,
        address tokenAddr,
        uint256 amount,
        bytes32 orderId,
        uint64 createdAt,
        uint64 expiresAt
    ) internal view returns (bytes memory signature) {
        bytes32 structHash = keccak256(
            abi.encode(
                target.ORDER_TYPEHASH(),
                merchantAddr,
                receiverAddr,
                wallet.addr,
                tokenAddr,
                amount,
                orderId,
                createdAt,
                expiresAt
            )
        );
        bytes32 digest = MessageHashUtils.toTypedDataHash(target.DOMAIN_SEPARATOR(), structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wallet.privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _mintAndApprove(address actor, uint256 amount) internal {
        token.mint(actor, amount);
        vm.prank(actor);
        token.approve(address(router), amount);
    }

    // ========================================================
    // setSigner — delegation lifecycle
    // ========================================================

    function testSetSignerEmitsAndPersists() public {
        assertEq(router.merchantSigner(merchant), address(0));

        vm.expectEmit(true, true, true, true);
        emit BeamRouter.SignerUpdated(merchant, address(0), delegateWallet.addr);
        vm.prank(merchant);
        router.setSigner(delegateWallet.addr);

        assertEq(router.merchantSigner(merchant), delegateWallet.addr);
    }

    function testSetSignerClear() public {
        vm.prank(merchant);
        router.setSigner(delegateWallet.addr);
        assertEq(router.merchantSigner(merchant), delegateWallet.addr);

        vm.expectEmit(true, true, true, true);
        emit BeamRouter.SignerUpdated(merchant, delegateWallet.addr, address(0));
        vm.prank(merchant);
        router.setSigner(address(0));

        assertEq(router.merchantSigner(merchant), address(0));
    }

    function testSetSignerIsMerchantScoped() public {
        // Attacker cannot write merchant's signer slot — setSigner uses msg.sender as the key.
        address attacker = attackerWallet.addr;
        vm.prank(attacker);
        router.setSigner(delegateWallet.addr);

        // Merchant's slot is untouched; only the attacker's own slot was written.
        assertEq(router.merchantSigner(merchant), address(0));
        assertEq(router.merchantSigner(attacker), delegateWallet.addr);
    }

    // ========================================================
    // pay — happy paths (merchant signs, delegate signs)
    // ========================================================

    function testPayMerchantSelfSigned() public {
        uint256 amount = 100_000;
        bytes32 orderId = keccak256("self");
        uint64 createdAt = uint64(block.timestamp);
        uint64 expiresAt = createdAt + DEFAULT_TTL;
        bytes memory sig = _signOrderOn(
            router, merchantWallet, merchant, merchant, address(token), amount, orderId, createdAt, expiresAt
        );

        _mintAndApprove(payer, amount);
        vm.prank(payer);
        router.pay(merchant, merchant, address(token), amount, orderId, merchant, createdAt, expiresAt, sig);

        // OrderRecord captures the v1.0 fields.
        BeamRouter.OrderRecord memory rec = router.getOrder(merchant, orderId);
        assertTrue(rec.payer != address(0));
        assertEq(rec.payer, payer);
        assertEq(rec.signer, merchant);
        assertEq(rec.createdAt, createdAt);
        assertEq(rec.expiresAt, expiresAt);
    }

    function testPayDelegateSigned() public {
        // Merchant authorizes delegate.
        vm.prank(merchant);
        router.setSigner(delegateWallet.addr);

        uint256 amount = 100_000;
        bytes32 orderId = keccak256("delegate");
        uint64 createdAt = uint64(block.timestamp);
        uint64 expiresAt = createdAt + DEFAULT_TTL;
        bytes memory sig = _signOrderOn(
            router, delegateWallet, merchant, merchant, address(token), amount, orderId, createdAt, expiresAt
        );

        _mintAndApprove(payer, amount);
        vm.prank(payer);
        router.pay(merchant, merchant, address(token), amount, orderId, delegateWallet.addr, createdAt, expiresAt, sig);

        assertEq(router.getOrder(merchant, orderId).signer, delegateWallet.addr);
    }

    function testRevokedDelegateCannotSignAfterClear() public {
        vm.prank(merchant);
        router.setSigner(delegateWallet.addr);

        // Merchant revokes delegation.
        vm.prank(merchant);
        router.setSigner(address(0));

        uint256 amount = 100_000;
        bytes32 orderId = keccak256("revoked-delegate");
        uint64 createdAt = uint64(block.timestamp);
        uint64 expiresAt = createdAt + DEFAULT_TTL;
        bytes memory sig = _signOrderOn(
            router, delegateWallet, merchant, merchant, address(token), amount, orderId, createdAt, expiresAt
        );

        _mintAndApprove(payer, amount);
        vm.prank(payer);
        vm.expectRevert(BeamRouter.UnauthorizedSigner.selector);
        router.pay(merchant, merchant, address(token), amount, orderId, delegateWallet.addr, createdAt, expiresAt, sig);
    }

    // ========================================================
    // pay — signature tampering
    // ========================================================

    function testPayTamperedAmountReverts() public {
        uint256 signedAmount = 100_000;
        uint256 paidAmount = 1; // tampered down
        bytes32 orderId = keccak256("tamper-amount");
        uint64 createdAt = uint64(block.timestamp);
        uint64 expiresAt = createdAt + DEFAULT_TTL;
        // Sign over `signedAmount`, but submit `paidAmount` — recovered signer must mismatch.
        bytes memory sig = _signOrderOn(
            router, merchantWallet, merchant, merchant, address(token), signedAmount, orderId, createdAt, expiresAt
        );

        _mintAndApprove(payer, paidAmount);
        vm.prank(payer);
        vm.expectRevert(BeamRouter.InvalidSignature.selector);
        router.pay(merchant, merchant, address(token), paidAmount, orderId, merchant, createdAt, expiresAt, sig);
    }

    function testPayTamperedOrderIdReverts() public {
        uint256 amount = 100_000;
        bytes32 signedOrderId = keccak256("signed");
        bytes32 paidOrderId = keccak256("paid");
        uint64 createdAt = uint64(block.timestamp);
        uint64 expiresAt = createdAt + DEFAULT_TTL;
        bytes memory sig = _signOrderOn(
            router, merchantWallet, merchant, merchant, address(token), amount, signedOrderId, createdAt, expiresAt
        );

        _mintAndApprove(payer, amount);
        vm.prank(payer);
        vm.expectRevert(BeamRouter.InvalidSignature.selector);
        router.pay(merchant, merchant, address(token), amount, paidOrderId, merchant, createdAt, expiresAt, sig);
    }

    function testPaySignatureFromAttackerReverts() public {
        uint256 amount = 100_000;
        bytes32 orderId = keccak256("attacker");
        uint64 createdAt = uint64(block.timestamp);
        uint64 expiresAt = createdAt + DEFAULT_TTL;
        // Attacker signs claiming `signer = attacker`. UnauthorizedSigner fires before sig check.
        bytes memory sig = _signOrderOn(
            router, attackerWallet, merchant, merchant, address(token), amount, orderId, createdAt, expiresAt
        );

        _mintAndApprove(payer, amount);
        vm.prank(payer);
        vm.expectRevert(BeamRouter.UnauthorizedSigner.selector);
        router.pay(merchant, merchant, address(token), amount, orderId, attackerWallet.addr, createdAt, expiresAt, sig);
    }

    function testPaySignatureFromWrongMerchantSlotReverts() public {
        // Attacker signs claiming `signer = merchant` (so the auth check passes by name),
        // but the actual signature is from a different key. ECDSA recovery → != merchant.
        uint256 amount = 100_000;
        bytes32 orderId = keccak256("forged");
        uint64 createdAt = uint64(block.timestamp);
        uint64 expiresAt = createdAt + DEFAULT_TTL;
        bytes32 structHash = keccak256(
            abi.encode(
                router.ORDER_TYPEHASH(),
                merchant,
                merchant, // receiver
                merchant, // signer (forged)
                address(token),
                amount,
                orderId,
                createdAt,
                expiresAt
            )
        );
        bytes32 digest = MessageHashUtils.toTypedDataHash(router.DOMAIN_SEPARATOR(), structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(attackerWallet.privateKey, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        _mintAndApprove(payer, amount);
        vm.prank(payer);
        vm.expectRevert(BeamRouter.InvalidSignature.selector);
        router.pay(merchant, merchant, address(token), amount, orderId, merchant, createdAt, expiresAt, sig);
    }

    // ========================================================
    // pay — temporal validation
    // ========================================================

    function testPayExpiredOrderReverts() public {
        uint256 amount = 100_000;
        bytes32 orderId = keccak256("expired");
        uint64 createdAt = uint64(block.timestamp);
        uint64 expiresAt = createdAt + 60;
        bytes memory sig = _signOrderOn(
            router, merchantWallet, merchant, merchant, address(token), amount, orderId, createdAt, expiresAt
        );

        _mintAndApprove(payer, amount);
        vm.warp(uint256(expiresAt) + 1);

        vm.prank(payer);
        vm.expectRevert(BeamRouter.OrderExpired.selector);
        router.pay(merchant, merchant, address(token), amount, orderId, merchant, createdAt, expiresAt, sig);
    }

    function testPayAtExactExpirySucceeds() public {
        // block.timestamp == expiresAt should still be accepted (the check is `>`, not `>=`).
        uint256 amount = 100_000;
        bytes32 orderId = keccak256("on-the-edge");
        uint64 createdAt = uint64(block.timestamp);
        uint64 expiresAt = createdAt + 60;
        bytes memory sig = _signOrderOn(
            router, merchantWallet, merchant, merchant, address(token), amount, orderId, createdAt, expiresAt
        );

        _mintAndApprove(payer, amount);
        vm.warp(uint256(expiresAt));

        vm.prank(payer);
        router.pay(merchant, merchant, address(token), amount, orderId, merchant, createdAt, expiresAt, sig);
    }

    function testPayInvalidExpiryReverts() public {
        uint256 amount = 100_000;
        bytes32 orderId = keccak256("zero-window");
        uint64 createdAt = uint64(block.timestamp);
        uint64 expiresAt = createdAt; // empty window
        bytes memory sig = _signOrderOn(
            router, merchantWallet, merchant, merchant, address(token), amount, orderId, createdAt, expiresAt
        );

        _mintAndApprove(payer, amount);
        vm.prank(payer);
        vm.expectRevert(BeamRouter.InvalidExpiry.selector);
        router.pay(merchant, merchant, address(token), amount, orderId, merchant, createdAt, expiresAt, sig);
    }

    // ========================================================
    // pay — replay & domain binding
    // ========================================================

    function testReplaySameOrderReverts() public {
        uint256 amount = 100_000;
        bytes32 orderId = keccak256("replay");
        uint64 createdAt = uint64(block.timestamp);
        uint64 expiresAt = createdAt + DEFAULT_TTL;
        bytes memory sig = _signOrderOn(
            router, merchantWallet, merchant, merchant, address(token), amount, orderId, createdAt, expiresAt
        );

        _mintAndApprove(payer, amount * 2);
        vm.prank(payer);
        router.pay(merchant, merchant, address(token), amount, orderId, merchant, createdAt, expiresAt, sig);

        vm.prank(payer);
        vm.expectRevert(BeamRouter.DuplicateOrder.selector);
        router.pay(merchant, merchant, address(token), amount, orderId, merchant, createdAt, expiresAt, sig);
    }

    function testCrossRouterReplayReverts() public {
        // Deploy a second router at a different address; its DOMAIN_SEPARATOR differs by
        // `verifyingContract`. A signature for the first router must not authorize the second.
        address[] memory tokens = new address[](1);
        tokens[0] = address(token);
        address[] memory recipients = new address[](1);
        recipients[0] = feeRecipient;
        BeamRouter altRouter = new BeamRouter(governance, tokens, recipients, 10);

        uint256 amount = 100_000;
        bytes32 orderId = keccak256("cross-router");
        uint64 createdAt = uint64(block.timestamp);
        uint64 expiresAt = createdAt + DEFAULT_TTL;
        // Sign for the ORIGINAL router.
        bytes memory sig = _signOrderOn(
            router, merchantWallet, merchant, merchant, address(token), amount, orderId, createdAt, expiresAt
        );

        _mintAndApprove(payer, amount);
        // Submit the same sig to the second router → digest mismatch → recover != merchant.
        vm.prank(payer);
        vm.expectRevert(BeamRouter.InvalidSignature.selector);
        altRouter.pay(merchant, merchant, address(token), amount, orderId, merchant, createdAt, expiresAt, sig);
    }

    function testDomainSeparatorIsAddressBound() public {
        // Two routers at different addresses → distinct domain separators.
        address[] memory tokens = new address[](1);
        tokens[0] = address(token);
        address[] memory recipients = new address[](1);
        recipients[0] = feeRecipient;
        BeamRouter altRouter = new BeamRouter(governance, tokens, recipients, 10);

        assertTrue(router.DOMAIN_SEPARATOR() != altRouter.DOMAIN_SEPARATOR());
    }
}
