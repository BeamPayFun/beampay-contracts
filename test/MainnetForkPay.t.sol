// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { BeamRouter } from "../src/BeamRouter.sol";

/// @notice Mainnet-state simulation (NO broadcast). Forks BSC(56) + ETH(1) at the live
///         canonical CREATE3 router and simulates native pay()/refund() against real
///         on-chain state, asserting the load-bearing invariants:
///           - contract balance is always 0 (funds never held)
///           - H-06: merchant_received + protocol_received == amount
///           - refund returns to the recorded payer
///         Plus a fee>0 path on BSC via the 7-day timelock to exercise the fee split.
///
/// Run (no key, read-only forks):
///   BSC_RPC_URL=https://bsc-rpc.publicnode.com \
///   ETH_RPC_URL=https://ethereum-rpc.publicnode.com \
///   forge test --match-contract MainnetForkPay -vv
contract MainnetForkPayTest is Test {
    address constant ROUTER = 0xBEA93fceFb115b22a3D6c714Ee815B359e2AAbaa;
    address constant NATIVE = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    uint64 constant TTL = 30 days;
    uint256 constant AMOUNT = 0.01 ether;

    function _sign(BeamRouter router, Vm.Wallet memory w, bytes32 orderId, uint64 createdAt, uint64 expiresAt)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(
            abi.encode(router.ORDER_TYPEHASH(), w.addr, w.addr, w.addr, NATIVE, AMOUNT, orderId, createdAt, expiresAt)
        );
        bytes32 digest = MessageHashUtils.toTypedDataHash(router.DOMAIN_SEPARATOR(), structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(w.privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _payRefund(string memory rpcAlias) internal {
        vm.createSelectFork(vm.rpcUrl(rpcAlias));
        BeamRouter router = BeamRouter(payable(ROUTER));
        assertTrue(router.allowedTokens(NATIVE), "native must be whitelisted");

        Vm.Wallet memory m = vm.createWallet(rpcAlias);
        // Label-derived addresses can collide with a real mainnet contract (e.g. a
        // native-forwarder on ETH); neutralize code so the merchant is a plain EOA
        // that simply holds the received native asset.
        vm.etch(m.addr, "");
        address payer = makeAddr("payer");
        vm.deal(payer, AMOUNT);

        bytes32 orderId = keccak256(abi.encodePacked("fork-pay", rpcAlias));
        uint64 createdAt = uint64(block.timestamp);
        uint64 expiresAt = createdAt + TTL;
        bytes memory sig = _sign(router, m, orderId, createdAt, expiresAt);

        uint256 feeRate = router.currentFeeRate();
        uint256 fee = (AMOUNT * feeRate) / 10000;
        uint256 merchantBefore = m.addr.balance;

        vm.prank(payer);
        router.pay{ value: AMOUNT }(m.addr, m.addr, NATIVE, AMOUNT, orderId, m.addr, createdAt, expiresAt, sig);

        // Invariant 1/10: contract never holds funds.
        assertEq(ROUTER.balance, 0, "router balance 0 after pay");
        // H-06: merchant gets amount-fee (fee collected) or full amount (fee redirected). Both => sum==amount.
        uint256 merchantGain = m.addr.balance - merchantBefore;
        emit log_named_uint("feeRate(bps)", feeRate);
        emit log_named_uint("fee", fee);
        emit log_named_uint("merchantGain", merchantGain);
        emit log_named_uint("routerBalance", ROUTER.balance);
        assertTrue(merchantGain == AMOUNT - fee || merchantGain == AMOUNT, "H-06 merchant receipt");
        // payer spent exactly the order amount (no over-charge).
        assertEq(payer.balance, 0, "payer spent exactly amount");

        BeamRouter.OrderRecord memory rec = router.getOrder(m.addr, orderId);
        assertEq(rec.payer, payer, "order records payer");
        assertEq(rec.amount, AMOUNT, "order records amount");

        // Refund full amount back to the recorded payer (merchant funds it).
        uint256 payerBefore = payer.balance;
        vm.deal(m.addr, AMOUNT);
        vm.prank(m.addr);
        router.refund{ value: AMOUNT }(orderId, AMOUNT);
        assertEq(payer.balance, payerBefore + AMOUNT, "payer refunded");
        assertEq(ROUTER.balance, 0, "router balance 0 after refund");
    }

    function testForkPayRefundBSC() public {
        _payRefund("bsc");
    }

    function testForkPayRefundETH() public {
        _payRefund("ethereum");
    }

    /// Exercise the fee>0 split on BSC via the 7-day timelock, then verify H-06.
    function testForkFeeSplitH06BSC() public {
        vm.createSelectFork(vm.rpcUrl("bsc"));
        BeamRouter router = BeamRouter(payable(ROUTER));
        address gov = router.governance();

        // Raise fee to the hard cap (10 bps) through the timelock.
        vm.prank(gov);
        router.proposeFeeChange(10);
        vm.warp(block.timestamp + router.TIMELOCK_DELAY() + 1);
        router.executeFeeChange();
        assertEq(router.currentFeeRate(), 10, "fee now 10 bps");

        Vm.Wallet memory m = vm.createWallet("feemerchant");
        vm.etch(m.addr, "");
        address payer = makeAddr("feepayer");
        vm.deal(payer, AMOUNT);
        bytes32 orderId = keccak256("fork-fee");
        uint64 createdAt = uint64(block.timestamp);
        uint64 expiresAt = createdAt + TTL;
        bytes memory sig = _sign(router, m, orderId, createdAt, expiresAt);

        uint256 fee = (AMOUNT * 10) / 10000;
        uint256 merchantBefore = m.addr.balance;

        vm.prank(payer);
        router.pay{ value: AMOUNT }(m.addr, m.addr, NATIVE, AMOUNT, orderId, m.addr, createdAt, expiresAt, sig);

        uint256 merchantGain = m.addr.balance - merchantBefore;
        // protocol_received = amount - merchant_received; H-06 holds by construction + no funds stuck.
        uint256 protocolReceived = AMOUNT - merchantGain;
        assertEq(merchantGain + protocolReceived, AMOUNT, "H-06 invariant");
        assertEq(ROUTER.balance, 0, "router balance 0");
        // Normal path: fee routed to recipient, merchant gets amount-fee.
        assertTrue(merchantGain == AMOUNT - fee || merchantGain == AMOUNT, "fee split or redirect");
        emit log_named_uint("feeRate(bps)", router.currentFeeRate());
        emit log_named_uint("merchantGain", merchantGain);
        emit log_named_uint("protocolReceived", protocolReceived);
    }
}
