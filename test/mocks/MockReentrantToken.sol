// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { BeamPayRouter } from "../../src/BeamPayRouter.sol";

/// @notice Malicious ERC20 mock that reenters pay() or refund() during transferFrom.
/// @dev  Used to verify the nonReentrant guard on BeamPayRouter.
contract MockReentrantToken {
    string public name = "Reentrant";
    string public symbol = "RNT";
    uint8 public decimals = 18;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    BeamPayRouter public target;
    address public merchant;
    bytes32 public orderId;
    bool public reentered;

    constructor() { }

    function setTarget(BeamPayRouter _target) external {
        target = _target;
    }

    function setPayParams(address _merchant, bytes32 _orderId) external {
        merchant = _merchant;
        orderId = _orderId;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "insufficient balance");
        require(allowance[from][msg.sender] >= amount, "insufficient allowance");

        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;

        if (!reentered && address(target) != address(0)) {
            reentered = true;
            // Attempt reentrancy into pay() with a different orderId. The nonReentrant modifier
            // runs before input/signature validation, so dummy signer/expiry/sig values are fine —
            // we only need this call to reach the modifier and trigger Reentrant.
            bytes32 reentrantOrderId = keccak256(abi.encodePacked(orderId, uint256(1)));
            try target.pay(
                merchant,
                merchant, // receiver (any non-zero works; nonReentrant fires before any other check)
                address(this),
                amount,
                reentrantOrderId,
                merchant,
                uint64(block.timestamp),
                uint64(block.timestamp + 1),
                ""
            ) { }
                catch { }
        }

        return true;
    }
}
