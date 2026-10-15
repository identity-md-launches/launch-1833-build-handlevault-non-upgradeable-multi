// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VaultFixture} from "./helpers/VaultFixture.sol";
import {HandleVault} from "../src/HandleVault.sol";

/// @notice Head-of-line skipping, the per-claim visit bound, and the per-recipient share of each
/// token's rolling cap. The fixture deploys with the script values: 100,000 mUSDC cap, fee 0.
contract CapSharingTest is VaultFixture {
    address internal attacker = makeAddr("attacker");
    address internal victimWallet = makeAddr("victim wallet");

    function setUp() public override {
        super.setUp();
        vm.prank(owner);
        usdc.mint(attacker, 1_000_000e6);
        vm.deal(attacker, 100 ether);
    }

    function _depositFrom(address from, bytes32 recipientId, uint256 amount) internal returns (uint256 id) {
        vm.startPrank(from);
        usdc.approve(address(vault), amount);
        id = vault.depositFor(recipientId, address(usdc), amount);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- head-of-line skipping

    function test_oversizedHeadIsSkippedAndLaterDepositsArePaid() public {
        uint256 blocker = _depositFrom(attacker, RECIPIENT, 100_000e6);
        uint256 wanted = _deposit(RECIPIENT, address(usdc), 50e6);
        uint256 wantedToo = _deposit(RECIPIENT, address(usdc), 25e6);
        // Any other claim in the window makes a cap-sized head unfit until the window empties.
        _deposit(SECOND_RECIPIENT, address(usdc), 1e6);
        _claim(SECOND_RECIPIENT, dest, _tokens(address(usdc)), 0);
        assertEq(vault.remainingOutflow(address(usdc)), 100_000e6 - 1e6);

        vm.expectEmit(true, true, true, true);
        emit HandleVault.DepositSkipped(blocker, RECIPIENT, address(usdc));
        assertEq(_claim(RECIPIENT, victimWallet, _tokens(address(usdc)), 0), 2);
        assertEq(usdc.balanceOf(victimWallet), 75e6);
        assertEq(uint256(_status(wanted)), uint256(HandleVault.Status.Claimed));
        assertEq(uint256(_status(wantedToo)), uint256(HandleVault.Status.Claimed));
        assertEq(uint256(_status(blocker)), uint256(HandleVault.Status.Open));
        assertEq(vault.firstOpenDeposit(RECIPIENT, address(usdc)), blocker);
        assertEq(vault.totalEscrowed(RECIPIENT, address(usdc)), 100_000e6);
        _assertAccounting(address(usdc));

        // Deposits that arrive later keep flowing past the parked head.
        uint256 later = _deposit(RECIPIENT, address(usdc), 10e6);
        assertEq(_claim(RECIPIENT, victimWallet, _tokens(address(usdc)), 1), 1);
        assertEq(uint256(_status(later)), uint256(HandleVault.Status.Claimed));

        // Once the window has cleared, the head fits again and FIFO resumes from it.
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        assertEq(_claim(RECIPIENT, victimWallet, _tokens(address(usdc)), 2), 1);
        assertEq(uint256(_status(blocker)), uint256(HandleVault.Status.Claimed));
        assertEq(usdc.balanceOf(victimWallet), 100_085e6);
        _assertAccounting(address(usdc));
    }

    function test_skipKeepsFifoOrderAmongDepositsThatFit() public {
        vm.prank(owner);
        vault.setOutflowCap(address(usdc), 1000e6);
        uint256 a = _deposit(RECIPIENT, address(usdc), 600e6);
        uint256 b = _deposit(RECIPIENT, address(usdc), 600e6);
        uint256 c = _deposit(RECIPIENT, address(usdc), 300e6);
        uint256 d = _deposit(RECIPIENT, address(usdc), 300e6);
        // a fits (600 of 1000), b does not (would reach 1200), c fits (900), d does not (1200).
        assertEq(_claim(RECIPIENT, dest, _tokens(address(usdc)), 0), 2);
        assertEq(uint256(_status(a)), uint256(HandleVault.Status.Claimed));
        assertEq(uint256(_status(b)), uint256(HandleVault.Status.Open));
        assertEq(uint256(_status(c)), uint256(HandleVault.Status.Claimed));
        assertEq(uint256(_status(d)), uint256(HandleVault.Status.Open));
        assertEq(vault.rollingOutflow(address(usdc)), 900e6);
        assertEq(vault.firstOpenDeposit(RECIPIENT, address(usdc)), b);
        (uint256[] memory ids,) = vault.getOpenDepositIds(RECIPIENT, 0, 10);
        assertEq(ids.length, 2);
        assertEq(ids[0], b);
        assertEq(ids[1], d);
        _assertAccounting(address(usdc));
    }

    function test_nothingFitsStillRevertsWithCapExceeded() public {
        vm.prank(owner);
        vault.setOutflowCap(address(usdc), 1000e6);
        _deposit(RECIPIENT, address(usdc), 900e6);
        _deposit(RECIPIENT, address(usdc), 200e6);
        _deposit(RECIPIENT, address(usdc), 150e6);
        assertEq(_claim(RECIPIENT, dest, _tokens(address(usdc)), 0), 1);
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory sig = _signature(OWNER_KEY, RECIPIENT, dest, 1, deadline);
        vm.expectRevert(HandleVault.OutflowCapExceeded.selector);
        vault.claim(RECIPIENT, dest, _tokens(address(usdc)), 1, deadline, sig);
        assertFalse(vault.usedNonces(RECIPIENT, 1));
    }

    function test_visitBudgetBoundsSkippedDepositsAndContinues() public {
        vm.prank(owner);
        vault.setOutflowCap(address(usdc), 1000e6);
        uint256 visits = vault.MAX_VISITS_PER_CLAIM();
        // Use most of the window so that 600 mUSDC deposits do not fit but 1 mUSDC ones do.
        _deposit(SECOND_RECIPIENT, address(usdc), 500e6);
        _claim(SECOND_RECIPIENT, dest, _tokens(address(usdc)), 0);
        for (uint256 i; i < visits; ++i) {
            _depositFrom(attacker, RECIPIENT, 600e6);
        }
        uint256 wanted = _deposit(RECIPIENT, address(usdc), 1e6);
        // The whole visit budget is spent on unfit deposits; the call reverts without burning the nonce.
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory sig = _signature(OWNER_KEY, RECIPIENT, victimWallet, 0, deadline);
        vm.expectRevert(HandleVault.OutflowCapExceeded.selector);
        vault.claim(RECIPIENT, victimWallet, _tokens(address(usdc)), 0, deadline, sig);
        assertFalse(vault.usedNonces(RECIPIENT, 0));
        // Once the window clears, up to 64 of the parked deposits are swept per call and the rest
        // continue; the 1 mUSDC deposit is reached as the queue drains.
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        assertEq(_claim(RECIPIENT, victimWallet, _tokens(address(usdc)), 1), 1);
        assertEq(usdc.balanceOf(victimWallet), 600e6);
        assertEq(uint256(_status(wanted)), uint256(HandleVault.Status.Open));
        _assertAccounting(address(usdc));
    }

    function test_visitBudgetIsSharedAcrossTokens() public {
        vm.startPrank(owner);
        vault.setOutflowCap(address(usdc), 1000e6);
        vault.setOutflowCap(address(other), 1000e6);
        vm.stopPrank();
        _deposit(SECOND_RECIPIENT, address(usdc), 500e6);
        _claim(SECOND_RECIPIENT, dest, _tokens(address(usdc)), 0);
        uint256 visits = vault.MAX_VISITS_PER_CLAIM();
        for (uint256 i; i < visits; ++i) {
            _depositFrom(attacker, RECIPIENT, 600e6);
        }
        _deposit(RECIPIENT, address(other), 7);
        address[] memory tokens = new address[](2);
        tokens[0] = address(usdc);
        tokens[1] = address(other);
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory sig = _signature(OWNER_KEY, RECIPIENT, dest, 0, deadline);
        vm.expectRevert(HandleVault.OutflowCapExceeded.selector);
        vault.claim(RECIPIENT, dest, tokens, 0, deadline, sig);
        // Listing the unblocked token first spends one visit on it and pays it.
        tokens[0] = address(other);
        tokens[1] = address(usdc);
        assertEq(_claim(RECIPIENT, dest, tokens, 0), 1);
        assertEq(other.balanceOf(dest), 7);
    }

    function test_loweredCapSkipsOversizedDepositUntilRaised() public {
        uint256 big = _deposit(RECIPIENT, address(usdc), 5000e6);
        uint256 small = _deposit(RECIPIENT, address(usdc), 100e6);
        vm.prank(owner);
        vault.setOutflowCap(address(usdc), 1000e6);
        assertEq(_claim(RECIPIENT, dest, _tokens(address(usdc)), 0), 1);
        assertEq(uint256(_status(small)), uint256(HandleVault.Status.Claimed));
        assertEq(uint256(_status(big)), uint256(HandleVault.Status.Open));
        vm.prank(owner);
        vault.setOutflowCap(address(usdc), 10_000e6);
        assertEq(_claim(RECIPIENT, dest, _tokens(address(usdc)), 1), 1);
        assertEq(uint256(_status(big)), uint256(HandleVault.Status.Claimed));
    }

    // ---------------------------------------------------------------- recipient share

    function test_defaultShareIsWholeCapAndViewsAgree() public view {
        assertEq(vault.recipientShareBps(), 10_000);
        assertEq(vault.DEFAULT_RECIPIENT_SHARE_BPS(), 10_000);
        assertEq(vault.recipientCap(address(usdc)), 100_000e6);
        assertEq(vault.recipientCap(address(0)), 10 ether);
        assertEq(vault.recipientRemainingOutflow(RECIPIENT, address(usdc)), 100_000e6);
        assertEq(vault.recipientRollingOutflow(RECIPIENT, address(usdc)), 0);
    }

    function test_setRecipientShareValidationEventAndAccess() public {
        vm.expectRevert();
        vault.setRecipientShareBps(5000);
        vm.startPrank(owner);
        vm.expectRevert(HandleVault.InvalidShare.selector);
        vault.setRecipientShareBps(0);
        vm.expectRevert(HandleVault.InvalidShare.selector);
        vault.setRecipientShareBps(10_001);
        vm.expectEmit(true, true, true, true);
        emit HandleVault.RecipientShareSet(10_000, 2500);
        vault.setRecipientShareBps(2500);
        vm.stopPrank();
        assertEq(vault.recipientShareBps(), 2500);
        assertEq(vault.recipientCap(address(usdc)), 25_000e6);
        assertEq(vault.recipientCap(address(0)), 2.5 ether);
    }

    function test_depositsAreBoundedByRecipientCap() public {
        vm.prank(owner);
        vault.setRecipientShareBps(2500);
        vm.startPrank(sender);
        usdc.approve(address(vault), 100_000e6);
        vm.expectRevert(abi.encodeWithSelector(HandleVault.DepositExceedsCap.selector, 25_000e6));
        vault.depositFor(RECIPIENT, address(usdc), 25_000e6 + 1);
        vault.depositFor(RECIPIENT, address(usdc), 25_000e6);
        vm.expectRevert(abi.encodeWithSelector(HandleVault.DepositExceedsCap.selector, 2.5 ether));
        vault.depositNativeFor{value: 2.5 ether + 1}(RECIPIENT);
        vault.depositNativeFor{value: 2.5 ether}(RECIPIENT);
        vm.stopPrank();
    }

    function test_oneRecipientCannotConsumeTheWholeWindowWhenShared() public {
        vm.prank(owner);
        vault.setRecipientShareBps(2500);
        uint256 victimDeposit = _deposit(RECIPIENT, address(usdc), 5e6);
        bytes32 attackerHandle = keccak256("attacker handle");
        // The attacker cycles the largest deposit allowed and claims it straight back, for free.
        _depositFrom(attacker, attackerHandle, 25_000e6);
        assertEq(_claim(attackerHandle, attacker, _tokens(address(usdc)), 0), 1);
        assertEq(usdc.balanceOf(attacker), 1_000_000e6);
        assertEq(vault.recipientRemainingOutflow(attackerHandle, address(usdc)), 0);
        assertEq(vault.remainingOutflow(address(usdc)), 75_000e6);
        // A second cycle by the same handle in the window is refused, nonce untouched.
        _depositFrom(attacker, attackerHandle, 25_000e6);
        uint256 deadline = vm.getBlockTimestamp() + 2 days;
        bytes memory sig = _signature(OWNER_KEY, attackerHandle, attacker, 1, deadline);
        vm.expectRevert(HandleVault.OutflowCapExceeded.selector);
        vault.claim(attackerHandle, attacker, _tokens(address(usdc)), 1, deadline, sig);
        assertFalse(vault.usedNonces(attackerHandle, 1));
        // The victim's claim is unaffected by the attacker's window.
        assertEq(vault.recipientRemainingOutflow(RECIPIENT, address(usdc)), 25_000e6);
        assertEq(_claim(RECIPIENT, victimWallet, _tokens(address(usdc)), 0), 1);
        assertEq(usdc.balanceOf(victimWallet), 5e6);
        assertEq(uint256(_status(victimDeposit)), uint256(HandleVault.Status.Claimed));
        // The attacker's own window rolls over after 24 hours like the shared one.
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        assertEq(vault.recipientRollingOutflow(attackerHandle, address(usdc)), 0);
        assertEq(vault.claim(attackerHandle, attacker, _tokens(address(usdc)), 1, deadline, sig), 1);
        _assertAccounting(address(usdc));
    }

    function test_recipientWindowIsExactlyTwentyFourHoursAndCountsFees() public {
        vm.startPrank(owner);
        vault.setRecipientShareBps(1000);
        vault.setFee(100, treasury);
        vm.stopPrank();
        uint256 start = vm.getBlockTimestamp();
        _deposit(RECIPIENT, address(usdc), 6000e6);
        _deposit(RECIPIENT, address(usdc), 6000e6);
        assertEq(_claim(RECIPIENT, dest, _tokens(address(usdc)), 0), 1);
        assertEq(vault.recipientRollingOutflow(RECIPIENT, address(usdc)), 6000e6);
        assertEq(vault.recipientRemainingOutflow(RECIPIENT, address(usdc)), 4000e6);
        assertEq(usdc.balanceOf(dest), 5940e6);
        bytes memory sig = _signature(OWNER_KEY, RECIPIENT, dest, 1, start + 2 days);
        vm.warp(start + 24 hours - 1);
        vm.expectRevert(HandleVault.OutflowCapExceeded.selector);
        vault.claim(RECIPIENT, dest, _tokens(address(usdc)), 1, start + 2 days, sig);
        vm.warp(start + 24 hours);
        assertEq(vault.recipientRollingOutflow(RECIPIENT, address(usdc)), 0);
        assertEq(vault.claim(RECIPIENT, dest, _tokens(address(usdc)), 1, start + 2 days, sig), 1);
        _assertAccounting(address(usdc));
    }

    function test_recipientWindowsAreIndependentPerToken() public {
        vm.prank(owner);
        vault.setRecipientShareBps(1000);
        _deposit(RECIPIENT, address(usdc), 10_000e6);
        _deposit(RECIPIENT, address(usdc), 1e6);
        _deposit(RECIPIENT, address(other), 10_000e6);
        address[] memory tokens = new address[](2);
        tokens[0] = address(usdc);
        tokens[1] = address(other);
        assertEq(_claim(RECIPIENT, dest, tokens, 0), 2);
        assertEq(vault.recipientRemainingOutflow(RECIPIENT, address(usdc)), 0);
        assertEq(vault.recipientRemainingOutflow(RECIPIENT, address(other)), 0);
        assertEq(vault.totalEscrowed(RECIPIENT, address(usdc)), 1e6);
        assertEq(vault.remainingOutflow(address(usdc)), 90_000e6);
    }

    function test_loweringShareBelowExistingDepositDelaysItUntilRaised() public {
        uint256 big = _deposit(RECIPIENT, address(usdc), 50_000e6);
        uint256 small = _deposit(RECIPIENT, address(usdc), 100e6);
        vm.prank(owner);
        vault.setRecipientShareBps(2500);
        assertEq(_claim(RECIPIENT, dest, _tokens(address(usdc)), 0), 1);
        assertEq(uint256(_status(small)), uint256(HandleVault.Status.Claimed));
        assertEq(uint256(_status(big)), uint256(HandleVault.Status.Open));
        vm.prank(owner);
        vault.setRecipientShareBps(10_000);
        assertEq(_claim(RECIPIENT, dest, _tokens(address(usdc)), 1), 1);
        assertEq(uint256(_status(big)), uint256(HandleVault.Status.Claimed));
        // Refunds never depend on either window.
        uint256 parked = _deposit(RECIPIENT, address(usdc), 50_000e6);
        vm.prank(owner);
        vault.setRecipientShareBps(1);
        vm.warp(vm.getBlockTimestamp() + 180 days);
        vault.refund(parked);
        assertEq(uint256(_status(parked)), uint256(HandleVault.Status.Refunded));
    }

    function testFuzz_recipientNeverExceedsShareOrSharedCapInOneWindow(uint16 rawShare, uint96[8] memory rawAmounts)
        public
    {
        uint256 share = bound(rawShare, 1, 10_000);
        vm.startPrank(owner);
        vault.setOutflowCap(address(usdc), 1000e6);
        vault.setRecipientShareBps(share);
        vm.stopPrank();
        uint256 cap = vault.recipientCap(address(usdc));
        vm.assume(cap >= 1e6);
        for (uint256 i; i < rawAmounts.length; ++i) {
            _deposit(RECIPIENT, address(usdc), bound(rawAmounts[i], 1e6, cap));
        }
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory sig = _signature(OWNER_KEY, RECIPIENT, dest, 0, deadline);
        (bool ok,) = address(vault)
            .call(abi.encodeCall(vault.claim, (RECIPIENT, dest, _tokens(address(usdc)), 0, deadline, sig)));
        assertTrue(ok, "at least the first deposit fits an empty window");
        assertLe(vault.recipientRollingOutflow(RECIPIENT, address(usdc)), cap);
        assertLe(vault.rollingOutflow(address(usdc)), 1000e6);
        assertEq(vault.rollingOutflow(address(usdc)), vault.recipientRollingOutflow(RECIPIENT, address(usdc)));
        _assertAccounting(address(usdc));
    }
}
