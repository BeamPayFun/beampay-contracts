// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { BeamPayRouter } from "../../src/BeamPayRouter.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";

/// @notice Handler that exercises `pay()` with fuzzed arguments.
contract BeamPayRouterHandler is Test {
    BeamPayRouter public router;
    MockERC20 public token;
    address public feeRecipient;

    struct Payment {
        address merchant;
        address feeTo;
        uint256 amount;
        uint256 receiverReceived;
        uint256 protocolReceived;
    }

    Payment[] public payments;
    uint256 public orderNonce;

    constructor(BeamPayRouter _router, MockERC20 _token, address _feeRecipient) {
        router = _router;
        token = _token;
        feeRecipient = _feeRecipient;
    }

    function pay(uint256 rawMerchant, uint256 amount, bytes32 rawOrderId) external {
        // bound amount to reasonable range
        amount = bound(amount, 1001, 1_000_000_000e18);

        // Derive a deterministic but unique merchant *wallet* (need a private key so the
        // handler can produce a valid EIP-712 signature). secp256k1 order N is enforced
        // by bounding the key to [1, N-1] — vm.addr rejects keys outside that range.
        uint256 merchantPriv = uint256(keccak256(abi.encode(rawMerchant, payments.length, "merchant")));
        merchantPriv =
            bound(merchantPriv, 1, 115792089237316195423570985008687907852837564279074904382605163141518161494336);
        address merchant = vm.addr(merchantPriv);

        // ensure unique orderId per (merchant, orderId) pair
        bytes32 orderId = keccak256(abi.encode(rawOrderId, orderNonce++));

        // mint and approve as handler (handler is the payer)
        token.mint(address(this), amount);
        token.approve(address(router), amount);

        // Receiver == merchant for this handler — the invariant under test is ledger accounting,
        // not receiver/merchant divergence. Receiver/merchant divergence is covered by unit tests.
        address receiver = merchant;
        uint256 receiverBalBefore = token.balanceOf(receiver);
        uint256 feeToBalBefore = token.balanceOf(feeRecipient);

        // If this order already exists (unlikely with nonce), skip
        if (router.getOrder(merchant, orderId).payer != address(0)) return;

        // Build and sign the EIP-712 order payload with the merchant's derived key.
        uint64 createdAt = uint64(block.timestamp);
        uint64 expiresAt = uint64(block.timestamp + 30 days);
        bytes32 structHash = keccak256(
            abi.encode(
                router.ORDER_TYPEHASH(),
                merchant,
                receiver,
                merchant,
                address(token),
                amount,
                orderId,
                createdAt,
                expiresAt
            )
        );
        bytes32 digest = MessageHashUtils.toTypedDataHash(router.DOMAIN_SEPARATOR(), structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(merchantPriv, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        try router.pay(merchant, receiver, address(token), amount, orderId, merchant, createdAt, expiresAt, sig) {
            uint256 receiverReceived = token.balanceOf(receiver) - receiverBalBefore;
            uint256 protocolReceived = token.balanceOf(feeRecipient) - feeToBalBefore;

            payments.push(
                Payment({
                    merchant: merchant,
                    feeTo: feeRecipient,
                    amount: amount,
                    receiverReceived: receiverReceived,
                    protocolReceived: protocolReceived
                })
            );
        } catch {
            // Reverted pays are not recorded.
        }
    }

    function paymentsLength() external view returns (uint256) {
        return payments.length;
    }
}

/// @notice Invariant test verifying the ledger invariant:
///         merchant_received + protocol_received == amount for every pay() call.
contract BeamPayRouterInvariant is Test {
    BeamPayRouter public router;
    BeamPayRouterHandler public handler;
    MockERC20 public token;

    address governance = makeAddr("governance");
    address feeRecipient = makeAddr("feeRecipient");

    function setUp() public {
        token = new MockERC20("Mock Token", "MKT", 18);

        address[] memory tokens = new address[](1);
        tokens[0] = address(token);

        address[] memory recipients = new address[](1);
        recipients[0] = feeRecipient;

        router = new BeamPayRouter(governance, tokens, recipients, 10);
        handler = new BeamPayRouterHandler(router, token, feeRecipient);

        targetContract(address(handler));
    }

    function invariant_ledgerBalanceMatchesAmount() public view {
        uint256 len = handler.paymentsLength();
        for (uint256 i = 0; i < len; i++) {
            (,, uint256 amount, uint256 receiverReceived, uint256 protocolReceived) = handler.payments(i);

            assertEq(receiverReceived + protocolReceived, amount, "invariant violated: receiver + protocol != amount");
        }
    }

    function invariant_contractBalanceAlwaysZero() public view {
        assertEq(token.balanceOf(address(router)), 0, "router token balance must be 0");
    }
}
