// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import { BeamRouter } from "../../src/BeamRouter.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";

/// @notice Handler that exercises `pay()` with fuzzed arguments.
contract BeamRouterHandler is Test {
    BeamRouter public router;
    MockERC20 public token;
    address public feeRecipient;

    struct Payment {
        address merchant;
        address feeTo;
        uint256 amount;
        uint256 merchantReceived;
        uint256 protocolReceived;
    }

    Payment[] public payments;
    uint256 public orderNonce;

    constructor(BeamRouter _router, MockERC20 _token, address _feeRecipient) {
        router = _router;
        token = _token;
        feeRecipient = _feeRecipient;
    }

    function pay(uint256 rawMerchant, uint256 amount, bytes32 rawOrderId) external {
        // bound amount to reasonable range
        amount = bound(amount, 1001, 1_000_000_000e18);

        // derive a deterministic but unique merchant address
        address merchant = address(uint160(uint256(keccak256(abi.encode(rawMerchant, payments.length)))));

        // ensure unique orderId per (merchant, orderId) pair
        bytes32 orderId = keccak256(abi.encode(rawOrderId, orderNonce++));

        // mint and approve as handler (handler is the payer)
        token.mint(address(this), amount);
        token.approve(address(router), amount);

        uint256 merchantBalBefore = token.balanceOf(merchant);
        uint256 feeToBalBefore = token.balanceOf(feeRecipient);

        // If this order already exists (unlikely with nonce), skip
        (bool exists,,,,) = router.getOrder(merchant, orderId);
        if (exists) return;

        try router.pay(merchant, address(token), amount, orderId) {
            uint256 merchantReceived = token.balanceOf(merchant) - merchantBalBefore;
            uint256 protocolReceived = token.balanceOf(feeRecipient) - feeToBalBefore;

            payments.push(
                Payment({
                    merchant: merchant,
                    feeTo: feeRecipient,
                    amount: amount,
                    merchantReceived: merchantReceived,
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
contract BeamRouterInvariant is Test {
    BeamRouter public router;
    BeamRouterHandler public handler;
    MockERC20 public token;

    address governance = makeAddr("governance");
    address feeRecipient = makeAddr("feeRecipient");

    function setUp() public {
        token = new MockERC20("Mock Token", "MKT", 18);

        address[] memory tokens = new address[](1);
        tokens[0] = address(token);

        address[] memory recipients = new address[](1);
        recipients[0] = feeRecipient;

        router = new BeamRouter(governance, tokens, recipients, 10);
        handler = new BeamRouterHandler(router, token, feeRecipient);

        targetContract(address(handler));
    }

    function invariant_ledgerBalanceMatchesAmount() public view {
        uint256 len = handler.paymentsLength();
        for (uint256 i = 0; i < len; i++) {
            (,, uint256 amount, uint256 merchantReceived, uint256 protocolReceived) = handler.payments(i);

            assertEq(merchantReceived + protocolReceived, amount, "invariant violated: merchant + protocol != amount");
        }
    }

    function invariant_contractBalanceAlwaysZero() public view {
        assertEq(token.balanceOf(address(router)), 0, "router token balance must be 0");
    }
}
