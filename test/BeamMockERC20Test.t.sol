// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import { BeamMockERC20 } from "../src/mocks/BeamMockERC20.sol";

contract BeamMockERC20Test is Test {
    BeamMockERC20 t;

    function setUp() public {
        t = new BeamMockERC20("Beam Test USDT", "tUSDT", 6);
    }

    function testMetadata() public view {
        assertEq(t.name(), "Beam Test USDT");
        assertEq(t.symbol(), "tUSDT");
        assertEq(t.decimals(), 6);
        assertEq(t.totalSupply(), 0);
    }

    function testAnyoneCanMint() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");

        vm.prank(alice);
        t.mint(bob, 1_000_000e6);

        assertEq(t.balanceOf(bob), 1_000_000e6);
        assertEq(t.totalSupply(), 1_000_000e6);
    }

    function testFaucetMintsToCaller() public {
        address alice = makeAddr("alice");
        vm.prank(alice);
        t.faucet(500e6);
        assertEq(t.balanceOf(alice), 500e6);
    }

    function testMintEmitsTransferFromZero() public {
        address alice = makeAddr("alice");
        vm.expectEmit(true, true, true, true);
        emit BeamMockERC20.Transfer(address(0), alice, 123);
        t.mint(alice, 123);
    }

    function testMintToZeroReverts() public {
        vm.expectRevert(bytes("mint to zero"));
        t.mint(address(0), 1);
    }

    function testTransferAndAllowance() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");

        t.mint(alice, 100e6);

        vm.prank(alice);
        t.approve(bob, 40e6);
        assertEq(t.allowance(alice, bob), 40e6);

        vm.prank(bob);
        t.transferFrom(alice, bob, 40e6);
        assertEq(t.balanceOf(alice), 60e6);
        assertEq(t.balanceOf(bob), 40e6);
        assertEq(t.allowance(alice, bob), 0);
    }

    function testInfiniteAllowanceNotDecremented() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        t.mint(alice, 100e6);

        vm.prank(alice);
        t.approve(bob, type(uint256).max);

        vm.prank(bob);
        t.transferFrom(alice, bob, 40e6);
        assertEq(t.allowance(alice, bob), type(uint256).max);
    }

    function testInsufficientBalanceReverts() public {
        address alice = makeAddr("alice");
        vm.prank(alice);
        vm.expectRevert(bytes("insufficient balance"));
        t.transfer(makeAddr("bob"), 1);
    }
}
