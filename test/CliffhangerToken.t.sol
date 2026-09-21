// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CliffhangerToken} from "../src/CliffhangerToken.sol";

contract CliffhangerTokenTest is Test {
    CliffhangerToken token;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        token = new CliffhangerToken();
    }

    function test_metadataAndSupply() public view {
        assertEq(token.name(), "Cliffhanger");
        assertEq(token.symbol(), "CLIF");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(this)), 1e27);
    }

    function test_constructorMintsToDeployerAndEmits() public {
        vm.expectEmit(true, true, false, true);
        emit Transfer(address(0), alice, 1e27);
        vm.prank(alice);
        CliffhangerToken t = new CliffhangerToken();
        assertEq(t.balanceOf(alice), 1e27);
        assertEq(t.balanceOf(address(this)), 0);
    }

    function test_transfer() public {
        vm.expectEmit(true, true, false, true);
        emit Transfer(address(this), alice, 100);
        assertTrue(token.transfer(alice, 100));
        assertEq(token.balanceOf(alice), 100);
        assertEq(token.balanceOf(address(this)), 1e27 - 100);
    }

    function test_transferZeroAndSelf() public {
        assertTrue(token.transfer(alice, 0));
        assertTrue(token.transfer(address(this), 5));
        assertEq(token.balanceOf(address(this)), 1e27);
    }

    function test_transfer_revertsInsufficientBalance() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CliffhangerToken.InsufficientBalance.selector, alice, 0, 1));
        token.transfer(bob, 1);
    }

    function test_transfer_revertsToZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(CliffhangerToken.InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
    }

    function test_approveAndTransferFrom() public {
        vm.expectEmit(true, true, false, true);
        emit Approval(address(this), alice, 50);
        token.approve(alice, 50);
        vm.prank(alice);
        token.transferFrom(address(this), bob, 30);
        assertEq(token.balanceOf(bob), 30);
        assertEq(token.allowance(address(this), alice), 20);
    }

    function test_infiniteAllowanceNotDecreased() public {
        token.approve(alice, type(uint256).max);
        vm.prank(alice);
        token.transferFrom(address(this), bob, 30);
        assertEq(token.allowance(address(this), alice), type(uint256).max);
    }

    function test_transferFrom_revertsInsufficientAllowance() public {
        token.approve(alice, 10);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CliffhangerToken.InsufficientAllowance.selector, alice, 10, 11));
        token.transferFrom(address(this), bob, 11);
    }

    function test_approve_revertsZeroSpender() public {
        vm.expectRevert(abi.encodeWithSelector(CliffhangerToken.InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
    }

    function test_noMintSelectorsExist() public {
        string[4] memory sigs =
            ["mint(address,uint256)", "mint(uint256)", "burn(uint256)", "transferOwnership(address)"];
        for (uint256 i; i < sigs.length; ++i) {
            (bool ok,) = address(token).call(abi.encodeWithSignature(sigs[i], address(this), 1));
            assertFalse(ok, sigs[i]);
        }
        assertEq(token.totalSupply(), 1e27);
    }

    function testFuzz_transferConservesSupply(uint256 amount, address to) public {
        vm.assume(to != address(0) && to != address(this));
        amount = bound(amount, 0, 1e27);
        token.transfer(to, amount);
        assertEq(token.balanceOf(to) + token.balanceOf(address(this)), 1e27);
        assertEq(token.totalSupply(), 1e27);
    }
}
