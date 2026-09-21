// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CliffhangerToken} from "../src/CliffhangerToken.sol";
import {VestingCliff} from "../src/VestingCliff.sol";
import {ReentrantToken, FeeOnTransferToken, FalseReturningToken, NoReturnToken} from "./mocks/MockTokens.sol";

contract VestingCliffTest is Test {
    CliffhangerToken token;
    VestingCliff vesting;

    address funder = makeAddr("funder");
    address beneficiary = makeAddr("beneficiary");
    address stranger = makeAddr("stranger");

    uint256 constant AMOUNT = 1_000e18;
    uint64 T0;

    event ScheduleCreated(
        uint256 indexed id,
        address indexed funder,
        address indexed beneficiary,
        uint256 amount,
        uint64 start,
        uint64 cliff,
        uint64 end
    );
    event Claimed(uint256 indexed id, address indexed beneficiary, uint256 amount);

    function setUp() public {
        vm.warp(1_700_000_000);
        T0 = uint64(block.timestamp);
        token = new CliffhangerToken();
        vesting = new VestingCliff(address(token));
        token.transfer(funder, 100_000e18);
        vm.prank(funder);
        token.approve(address(vesting), type(uint256).max);
    }

    function _create(uint256 amount, uint64 cliff, uint64 end) internal returns (uint256) {
        vm.prank(funder);
        return vesting.createSchedule(beneficiary, amount, cliff, end);
    }

    // ------------------------------------------------------------ constructor

    function test_constructor_setsToken() public view {
        assertEq(address(vesting.token()), address(token));
        assertEq(vesting.scheduleCount(), 0);
        assertEq(vesting.totalLocked(), 0);
    }

    function test_constructor_revertsOnZeroOrEoaToken() public {
        vm.expectRevert(VestingCliff.InvalidToken.selector);
        new VestingCliff(address(0));
        vm.expectRevert(VestingCliff.InvalidToken.selector);
        new VestingCliff(stranger);
    }

    // --------------------------------------------------------------- create

    function test_create_storesScheduleAndPullsTokens() public {
        vm.expectEmit(true, true, true, true);
        emit ScheduleCreated(0, funder, beneficiary, AMOUNT, T0, T0 + 100, T0 + 1000);
        uint256 id = _create(AMOUNT, T0 + 100, T0 + 1000);

        assertEq(id, 0);
        VestingCliff.Schedule memory s = vesting.getSchedule(0);
        assertEq(s.funder, funder);
        assertEq(s.beneficiary, beneficiary);
        assertEq(s.start, T0);
        assertEq(s.cliff, T0 + 100);
        assertEq(s.end, T0 + 1000);
        assertEq(s.amount, AMOUNT);
        assertEq(s.claimed, 0);
        assertEq(token.balanceOf(address(vesting)), AMOUNT);
        assertEq(token.balanceOf(funder), 100_000e18 - AMOUNT);
        assertEq(vesting.totalLocked(), AMOUNT);
        assertEq(vesting.scheduleCount(), 1);
    }

    function test_create_indexesByBeneficiaryAndFunder() public {
        _create(1, T0, T0 + 1);
        vm.prank(funder);
        vesting.createSchedule(stranger, 2, T0, T0 + 1);
        _create(3, T0, T0 + 1);

        uint256[] memory b = vesting.schedulesOfBeneficiary(beneficiary);
        assertEq(b.length, 2);
        assertEq(b[0], 0);
        assertEq(b[1], 2);
        assertEq(vesting.schedulesOfBeneficiary(stranger).length, 1);
        assertEq(vesting.schedulesOfFunder(funder).length, 3);
        assertEq(vesting.schedulesOfFunder(beneficiary).length, 0);
    }

    function test_create_funderMayBeBeneficiary() public {
        vm.prank(funder);
        uint256 id = vesting.createSchedule(funder, AMOUNT, T0, T0 + 10);
        vm.warp(T0 + 10);
        vm.prank(funder);
        vesting.claim(id);
        assertEq(token.balanceOf(funder), 100_000e18);
    }

    function test_create_revertsZeroAmount() public {
        vm.expectRevert(VestingCliff.ZeroAmount.selector);
        _create(0, T0 + 1, T0 + 2);
    }

    function test_create_revertsInvalidBeneficiary() public {
        vm.startPrank(funder);
        vm.expectRevert(VestingCliff.InvalidBeneficiary.selector);
        vesting.createSchedule(address(0), AMOUNT, T0, T0 + 1);
        vm.expectRevert(VestingCliff.InvalidBeneficiary.selector);
        vesting.createSchedule(address(vesting), AMOUNT, T0, T0 + 1);
        vm.stopPrank();
    }

    function test_create_revertsCliffInPast() public {
        vm.expectRevert(VestingCliff.InvalidTimes.selector);
        _create(AMOUNT, T0 - 1, T0 + 10);
    }

    function test_create_revertsEndBeforeCliff() public {
        vm.expectRevert(VestingCliff.InvalidTimes.selector);
        _create(AMOUNT, T0 + 10, T0 + 9);
    }

    function test_create_revertsZeroDuration() public {
        vm.expectRevert(VestingCliff.InvalidTimes.selector);
        _create(AMOUNT, T0, T0);
    }

    function test_create_boundaryTimesAccepted() public {
        _create(AMOUNT, T0, T0 + 1); // no cliff
        _create(AMOUNT, T0 + 5, T0 + 5); // pure cliff
        assertEq(vesting.scheduleCount(), 2);
    }

    function test_create_revertsWithoutAllowance() public {
        vm.prank(funder);
        token.approve(address(vesting), AMOUNT - 1);
        vm.expectRevert(VestingCliff.TransferFailed.selector);
        _create(AMOUNT, T0 + 1, T0 + 2);
        assertEq(vesting.scheduleCount(), 0);
        assertEq(vesting.totalLocked(), 0);
    }

    function test_create_revertsInsufficientBalance() public {
        vm.expectRevert(VestingCliff.TransferFailed.selector);
        _create(100_000e18 + 1, T0 + 1, T0 + 2);
    }

    // ---------------------------------------------------------------- vesting

    function test_cliffDoesNotReleasePreCliffAccrual() public {
        uint256 id = _create(AMOUNT, T0 + 250, T0 + 1000);
        vm.warp(T0 + 250);
        assertEq(vesting.vestedAmount(id), 0);
        assertEq(vesting.claimableAmount(id), 0);
        vm.prank(beneficiary);
        vm.expectRevert(abi.encodeWithSelector(VestingCliff.NothingToClaim.selector, id));
        vesting.claim(id);
        assertEq(vesting.getSchedule(id).claimed, 0);
        assertEq(vesting.totalLocked(), AMOUNT);
        assertEq(token.balanceOf(address(vesting)), AMOUNT);
        assertEq(token.balanceOf(beneficiary), 0);
    }

    function test_vested_curveWithCliff() public {
        uint256 id = _create(AMOUNT, T0 + 250, T0 + 1000);
        assertEq(vesting.vestedAmount(id), 0);
        assertEq(vesting.vestedAmountAt(id, T0 + 249), 0);
        assertEq(vesting.vestedAmountAt(id, T0 + 250), 0);
        assertEq(vesting.vestedAmountAt(id, T0 + 251), AMOUNT / 750);
        assertEq(vesting.vestedAmountAt(id, T0 + 500), AMOUNT / 3);
        assertEq(vesting.vestedAmountAt(id, T0 + 625), AMOUNT / 2);
        assertEq(vesting.vestedAmountAt(id, T0 + 999), (AMOUNT * 749) / 750);
        assertEq(vesting.vestedAmountAt(id, T0 + 1000), AMOUNT);
        assertEq(vesting.vestedAmountAt(id, type(uint256).max), AMOUNT);
    }

    function test_vested_pureCliff() public {
        uint256 id = _create(AMOUNT, T0 + 100, T0 + 100);
        assertEq(vesting.vestedAmountAt(id, T0 + 99), 0);
        assertEq(vesting.vestedAmountAt(id, T0 + 100), AMOUNT);
    }

    function test_views_revertUnknownSchedule() public {
        vm.expectRevert(abi.encodeWithSelector(VestingCliff.UnknownSchedule.selector, 0));
        vesting.getSchedule(0);
        vm.expectRevert(abi.encodeWithSelector(VestingCliff.UnknownSchedule.selector, 7));
        vesting.vestedAmount(7);
        vm.expectRevert(abi.encodeWithSelector(VestingCliff.UnknownSchedule.selector, 7));
        vesting.claimableAmount(7);
        vm.expectRevert(abi.encodeWithSelector(VestingCliff.UnknownSchedule.selector, 7));
        vesting.vestedAmountAt(7, 0);
    }

    // ------------------------------------------------------------------ claim

    function test_claim_revertsBeforeCliff() public {
        uint256 id = _create(AMOUNT, T0 + 100, T0 + 1000);
        vm.warp(T0 + 99);
        vm.prank(beneficiary);
        vm.expectRevert(abi.encodeWithSelector(VestingCliff.NothingToClaim.selector, id));
        vesting.claim(id);
    }

    function test_claim_atCliffAndPartial() public {
        uint256 id = _create(AMOUNT, T0 + 100, T0 + 1000);
        vm.warp(T0 + 100);
        assertEq(vesting.claimableAmount(id), 0);
        vm.prank(beneficiary);
        vm.expectRevert(abi.encodeWithSelector(VestingCliff.NothingToClaim.selector, id));
        vesting.claim(id);

        vm.warp(T0 + 190);
        assertEq(vesting.claimableAmount(id), AMOUNT / 10);

        vm.expectEmit(true, true, false, true);
        emit Claimed(id, beneficiary, AMOUNT / 10);
        vm.prank(beneficiary);
        assertEq(vesting.claim(id), AMOUNT / 10);
        assertEq(token.balanceOf(beneficiary), AMOUNT / 10);
        assertEq(vesting.claimableAmount(id), 0);
        assertEq(vesting.totalLocked(), AMOUNT - AMOUNT / 10);

        // Same block again: nothing new.
        vm.prank(beneficiary);
        vm.expectRevert(abi.encodeWithSelector(VestingCliff.NothingToClaim.selector, id));
        vesting.claim(id);

        vm.warp(T0 + 550);
        vm.prank(beneficiary);
        assertEq(vesting.claim(id), AMOUNT * 40 / 100);
        assertEq(token.balanceOf(beneficiary), AMOUNT / 2);
        assertEq(vesting.totalLocked(), AMOUNT / 2);

        vm.warp(T0 + 1000);
        vm.prank(beneficiary);
        assertEq(vesting.claim(id), AMOUNT / 2);
        assertEq(token.balanceOf(beneficiary), AMOUNT);
        assertEq(token.balanceOf(address(vesting)), 0);
        assertEq(vesting.totalLocked(), 0);
    }

    function test_claim_fullAtEndThenNothing() public {
        uint256 id = _create(AMOUNT, T0 + 100, T0 + 1000);
        vm.warp(T0 + 5000);
        vm.prank(beneficiary);
        assertEq(vesting.claim(id), AMOUNT);
        assertEq(token.balanceOf(beneficiary), AMOUNT);
        assertEq(token.balanceOf(address(vesting)), 0);
        assertEq(vesting.totalLocked(), 0);
        assertEq(vesting.getSchedule(id).claimed, AMOUNT);

        vm.prank(beneficiary);
        vm.expectRevert(abi.encodeWithSelector(VestingCliff.NothingToClaim.selector, id));
        vesting.claim(id);
    }

    function test_claim_revertsForNonBeneficiary() public {
        uint256 id = _create(AMOUNT, T0, T0 + 10);
        vm.warp(T0 + 10);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(VestingCliff.NotBeneficiary.selector, id, stranger));
        vesting.claim(id);
        // The funder cannot claw back either: the schedule is irrevocable.
        vm.prank(funder);
        vm.expectRevert(abi.encodeWithSelector(VestingCliff.NotBeneficiary.selector, id, funder));
        vesting.claim(id);
    }

    function test_claim_revertsUnknownSchedule() public {
        vm.prank(beneficiary);
        vm.expectRevert(abi.encodeWithSelector(VestingCliff.UnknownSchedule.selector, 0));
        vesting.claim(0);
    }

    function test_claim_schedulesAreIsolated() public {
        uint256 a = _create(AMOUNT, T0, T0 + 100);
        uint256 b = _create(2 * AMOUNT, T0 + 50, T0 + 100);
        vm.warp(T0 + 100);
        vm.prank(beneficiary);
        vesting.claim(a);
        assertEq(vesting.claimableAmount(b), 2 * AMOUNT);
        assertEq(vesting.getSchedule(b).claimed, 0);
        vm.prank(beneficiary);
        vesting.claim(b);
        assertEq(token.balanceOf(beneficiary), 3 * AMOUNT);
    }

    function test_noRevokeOrAdminSelectors() public {
        uint256 id = _create(AMOUNT, T0, T0 + 10);
        string[5] memory sigs =
            ["revoke(uint256)", "cancel(uint256)", "withdraw(uint256)", "transferOwnership(address)", "sweep(address)"];
        for (uint256 i; i < sigs.length; ++i) {
            vm.prank(funder);
            (bool ok,) = address(vesting).call(abi.encodeWithSignature(sigs[i], id));
            assertFalse(ok, sigs[i]);
        }
        assertEq(token.balanceOf(address(vesting)), AMOUNT);
    }

    // ------------------------------------------------------------------- fuzz

    function testFuzz_claimsConserveFunds(uint96 amount, uint32 cliffOff, uint32 dur, uint32[4] memory steps) public {
        amount = uint96(bound(amount, 1, 100_000e18));
        uint64 cliff = T0 + uint64(cliffOff);
        uint64 end = cliff + uint64(dur);
        vm.assume(end > T0);
        uint256 id = _create(amount, cliff, end);

        uint256 t = T0;
        uint256 prevVested;
        for (uint256 i; i < steps.length; ++i) {
            t += steps[i];
            vm.warp(t);
            uint256 v = vesting.vestedAmount(id);
            assertGe(v, prevVested, "vesting must be monotonic");
            assertLe(v, amount);
            if (t < cliff) assertEq(v, 0);
            prevVested = v;
            uint256 claimable = vesting.claimableAmount(id);
            if (claimable > 0) {
                vm.prank(beneficiary);
                vesting.claim(id);
            }
            assertEq(token.balanceOf(beneficiary) + token.balanceOf(address(vesting)), amount);
            assertEq(token.balanceOf(address(vesting)), vesting.totalLocked());
        }
        vm.warp(end);
        if (vesting.claimableAmount(id) > 0) {
            vm.prank(beneficiary);
            vesting.claim(id);
        }
        assertEq(token.balanceOf(beneficiary), amount);
        assertEq(vesting.totalLocked(), 0);
    }
}

contract VestingCliffAdversarialTokenTest is Test {
    address funder = makeAddr("funder");
    address beneficiary = makeAddr("beneficiary");
    uint64 T0;

    function setUp() public {
        vm.warp(1_700_000_000);
        T0 = uint64(block.timestamp);
    }

    function test_reentrancyDuringCreateIsBlocked() public {
        ReentrantToken t = new ReentrantToken();
        VestingCliff v = new VestingCliff(address(t));
        t.mint(funder, 1_000);
        vm.prank(funder);
        t.approve(address(v), 1_000);
        t.arm(address(v), abi.encodeCall(VestingCliff.createSchedule, (beneficiary, 1, T0, T0 + 1)));

        vm.prank(funder);
        v.createSchedule(beneficiary, 500, T0, T0 + 10);

        assertTrue(t.reentered());
        assertFalse(t.reentrySucceeded());
        assertEq(bytes4(t.reentryRevertData()), VestingCliff.Reentrancy.selector);
        assertEq(v.scheduleCount(), 1);
        assertEq(v.totalLocked(), 500);
        assertEq(t.balanceOf(address(v)), 500);
    }

    function test_reentrancyDuringClaimIsBlocked() public {
        ReentrantToken t = new ReentrantToken();
        VestingCliff v = new VestingCliff(address(t));
        t.mint(funder, 1_000);
        vm.prank(funder);
        t.approve(address(v), 1_000);
        // The token itself is the beneficiary, so a successful re-entrant claim would be authorized.
        vm.prank(funder);
        uint256 id = v.createSchedule(address(t), 1_000, T0, T0 + 100);
        t.arm(address(v), abi.encodeCall(VestingCliff.claim, (id)));

        vm.warp(T0 + 50);
        vm.prank(address(t));
        uint256 got = v.claim(id);

        assertEq(got, 500);
        assertTrue(t.reentered());
        assertFalse(t.reentrySucceeded());
        assertEq(bytes4(t.reentryRevertData()), VestingCliff.Reentrancy.selector);
        assertEq(t.balanceOf(address(t)), 500);
        assertEq(t.balanceOf(address(v)), 500);
        assertEq(v.getSchedule(id).claimed, 500);
        assertEq(v.totalLocked(), 500);
    }

    function test_feeOnTransferTokenRejected() public {
        FeeOnTransferToken t = new FeeOnTransferToken();
        VestingCliff v = new VestingCliff(address(t));
        t.mint(funder, 1_000);
        vm.prank(funder);
        t.approve(address(v), 1_000);
        vm.prank(funder);
        vm.expectRevert(abi.encodeWithSelector(VestingCliff.AmountMismatch.selector, 1_000, 990));
        v.createSchedule(beneficiary, 1_000, T0, T0 + 10);
        assertEq(v.scheduleCount(), 0);
    }

    function test_falseReturningTokenRejectedOnCreate() public {
        FalseReturningToken t = new FalseReturningToken();
        VestingCliff v = new VestingCliff(address(t));
        t.mint(funder, 1_000);
        vm.prank(funder);
        t.approve(address(v), 1_000);
        t.setFailing(true);
        vm.prank(funder);
        vm.expectRevert(VestingCliff.TransferFailed.selector);
        v.createSchedule(beneficiary, 1_000, T0, T0 + 10);
    }

    function test_falseReturningTokenRevertsClaimWithoutStateChange() public {
        FalseReturningToken t = new FalseReturningToken();
        VestingCliff v = new VestingCliff(address(t));
        t.mint(funder, 1_000);
        vm.prank(funder);
        t.approve(address(v), 1_000);
        vm.prank(funder);
        uint256 id = v.createSchedule(beneficiary, 1_000, T0, T0 + 10);

        t.setFailing(true);
        vm.warp(T0 + 10);
        vm.prank(beneficiary);
        vm.expectRevert(VestingCliff.TransferFailed.selector);
        v.claim(id);
        assertEq(v.getSchedule(id).claimed, 0);
        assertEq(v.claimableAmount(id), 1_000);

        t.setFailing(false);
        vm.prank(beneficiary);
        v.claim(id);
        assertEq(t.balanceOf(beneficiary), 1_000);
    }

    function test_noReturnTokenSupported() public {
        NoReturnToken t = new NoReturnToken();
        VestingCliff v = new VestingCliff(address(t));
        t.mint(funder, 1_000);
        vm.prank(funder);
        t.approve(address(v), 1_000);
        vm.prank(funder);
        uint256 id = v.createSchedule(beneficiary, 1_000, T0, T0 + 10);
        vm.warp(T0 + 10);
        vm.prank(beneficiary);
        v.claim(id);
        assertEq(t.balanceOf(beneficiary), 1_000);
    }
}
