// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VaultFixture} from "./helpers/VaultFixture.sol";
import {HandleVault} from "../src/HandleVault.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {
    IAccessControlDefaultAdminRules
} from "@openzeppelin/contracts/access/extensions/IAccessControlDefaultAdminRules.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract HandleVaultTest is VaultFixture {
    event Deposited(
        uint256 indexed depositId, bytes32 indexed recipientId, address indexed token, uint256 amount, address sender
    );
    event Claimed(
        uint256 indexed depositId,
        bytes32 indexed recipientId,
        address indexed token,
        uint256 amount,
        address dest,
        uint256 fee
    );
    event Refunded(
        uint256 indexed depositId, bytes32 indexed recipientId, address indexed token, uint256 amount, address sender
    );

    function test_initialConfiguration() public view {
        assertEq(vault.owner(), owner);
        assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), owner));
        assertTrue(vault.hasRole(vault.AUTHORIZER_ROLE(), owner));
        assertTrue(vault.hasRole(vault.PAUSER_ROLE(), owner));
        assertEq(vault.REFUND_DELAY(), 180 days);
        assertEq(vault.feeBps(), 0);
        assertEq(vault.feeRecipient(), owner);
        assertEq(vault.defaultAdminDelay(), 1 days);
        assertEq(usdc.decimals(), 6);
        assertEq(usdc.owner(), owner);
    }

    function test_depositRecordEventAndTotals() public {
        vm.prank(sender);
        usdc.approve(address(vault), 3e6);
        vm.expectEmit(true, true, true, true, address(vault));
        emit Deposited(1, RECIPIENT, address(usdc), 3e6, sender);
        vm.prank(sender);
        assertEq(vault.depositFor(RECIPIENT, address(usdc), 3e6), 1);
        (
            address depositor,
            bytes32 recipientId,
            address token,
            uint256 amount,
            uint256 createdAt,
            HandleVault.Status status
        ) = vault.deposits(1);
        assertEq(depositor, sender);
        assertEq(recipientId, RECIPIENT);
        assertEq(token, address(usdc));
        assertEq(amount, 3e6);
        assertEq(createdAt, vm.getBlockTimestamp());
        assertEq(uint256(status), uint256(HandleVault.Status.Open));
        _deposit(RECIPIENT, address(usdc), 2e6);
        _deposit(SECOND_RECIPIENT, address(usdc), 7e6);
        assertEq(vault.totalEscrowed(RECIPIENT, address(usdc)), 5e6);
        assertEq(vault.totalEscrowed(SECOND_RECIPIENT, address(usdc)), 7e6);
        assertEq(vault.totalOpen(address(usdc)), 12e6);
        assertEq(vault.openDepositCount(RECIPIENT), 2);
        _assertAccounting(address(usdc));
    }

    function test_relayClaimEventsAndZeroFees() public {
        uint256 id = _deposit(RECIPIENT, address(usdc), 3e6);
        vm.expectEmit(true, true, true, true, address(vault));
        emit Claimed(id, RECIPIENT, address(usdc), 3e6, dest, 0);
        assertEq(_claim(RECIPIENT, dest, _tokens(address(usdc)), 99), 1);
        assertEq(usdc.balanceOf(dest), 3e6);
        assertEq(usdc.balanceOf(relayer), 0);
        assertEq(uint256(_status(id)), uint256(HandleVault.Status.Claimed));
        assertEq(vault.totalEscrowed(RECIPIENT, address(usdc)), 0);
        assertEq(vault.openDepositCount(RECIPIENT), 0);
        assertEq(vault.firstOpenDeposit(RECIPIENT, address(usdc)), 0);
        assertEq(vault.accruedFees(address(usdc)), 0);
        assertTrue(vault.usedNonces(RECIPIENT, 99));
        _assertAccounting(address(usdc));
    }

    function test_multiTokenAndNativeClaim() public {
        _deposit(RECIPIENT, address(usdc), 3e6);
        _deposit(RECIPIENT, address(0), 1 ether);
        _deposit(RECIPIENT, address(other), 17);
        _deposit(SECOND_RECIPIENT, address(usdc), 7e6);
        address[] memory tokens = new address[](3);
        tokens[0] = address(usdc);
        tokens[1] = address(0);
        tokens[2] = address(other);
        assertEq(_claim(RECIPIENT, dest, tokens, 0), 3);
        assertEq(usdc.balanceOf(dest), 3e6);
        assertEq(other.balanceOf(dest), 17);
        assertEq(dest.balance, 1 ether);
        assertEq(vault.totalOpen(address(usdc)), 7e6);
        _assertAccounting(address(usdc));
        _assertAccounting(address(other));
        _assertAccounting(address(0));
    }

    function test_partialSweepContinuationIsFIFOAndBounded() public {
        uint256 max = vault.MAX_DEPOSITS_PER_CLAIM();
        for (uint256 i; i < max + 7; ++i) {
            _deposit(RECIPIENT, address(usdc), 1e6);
        }
        _deposit(RECIPIENT, address(0), 1 ether);
        address[] memory tokens = new address[](2);
        tokens[0] = address(usdc);
        tokens[1] = address(0);
        assertEq(_claim(RECIPIENT, dest, tokens, 1), max);
        assertEq(vault.openDepositCount(RECIPIENT), 8);
        assertEq(vault.firstOpenDeposit(RECIPIENT, address(usdc)), max + 1);
        assertEq(uint256(_status(max)), uint256(HandleVault.Status.Claimed));
        assertEq(uint256(_status(max + 1)), uint256(HandleVault.Status.Open));
        assertEq(_claim(RECIPIENT, dest, tokens, 2), 8);
        assertEq(usdc.balanceOf(dest), (max + 7) * 1e6);
        assertEq(dest.balance, 1 ether);
        assertEq(vault.openDepositCount(RECIPIENT), 0);
        // New deposits work after both queues have become empty.
        _deposit(RECIPIENT, address(usdc), 2e6);
        assertEq(_claim(RECIPIENT, dest, _tokens(address(usdc)), 3), 1);
        _assertAccounting(address(usdc));
    }

    function test_globalSweepLimitAcrossTokens() public {
        for (uint256 i; i < 40; ++i) {
            _deposit(RECIPIENT, address(usdc), 1e6);
            _deposit(RECIPIENT, address(other), 1);
        }
        address[] memory tokens = new address[](2);
        tokens[0] = address(usdc);
        tokens[1] = address(other);
        assertEq(_claim(RECIPIENT, dest, tokens, 1), 64);
        assertEq(usdc.balanceOf(dest), 40e6);
        assertEq(other.balanceOf(dest), 24);
        assertEq(_claim(RECIPIENT, dest, tokens, 2), 16);
    }

    function test_unlistedTokensRemainOpen() public {
        _deposit(RECIPIENT, address(usdc), 2e6);
        uint256 untouched = _deposit(RECIPIENT, address(other), 3);
        _claim(RECIPIENT, dest, _tokens(address(usdc)), 0);
        assertEq(uint256(_status(untouched)), uint256(HandleVault.Status.Open));
        assertEq(vault.totalEscrowed(RECIPIENT, address(other)), 3);
    }

    function test_paginationAndConstantTimeMiddleRemoval() public {
        for (uint256 i; i < 7; ++i) {
            _deposit(RECIPIENT, i % 2 == 0 ? address(usdc) : address(other), 1e6);
        }
        (uint256[] memory ids, uint256 cursor) = vault.getOpenDepositIds(RECIPIENT, 0, 3);
        assertEq(ids.length, 3);
        assertEq(ids[0], 1);
        assertEq(ids[2], 3);
        assertEq(cursor, 4);
        (ids, cursor) = vault.getOpenDepositIds(RECIPIENT, cursor, 3);
        assertEq(ids[0], 4);
        assertEq(ids[2], 6);
        assertEq(cursor, 7);
        (ids, cursor) = vault.getOpenDepositIds(RECIPIENT, cursor, 3);
        assertEq(ids.length, 1);
        assertEq(ids[0], 7);
        assertEq(cursor, 0);
        vm.warp(vm.getBlockTimestamp() + 180 days);
        vault.refund(3);
        vault.refund(1);
        vault.refund(7);
        (ids, cursor) = vault.getOpenDepositIds(RECIPIENT, 0, 256);
        assertEq(ids.length, 4);
        assertEq(ids[0], 2);
        assertEq(ids[1], 4);
        assertEq(ids[2], 5);
        assertEq(ids[3], 6);
        assertEq(cursor, 0);
        _claim(RECIPIENT, dest, _tokens(address(usdc)), 0);
        (ids,) = vault.getOpenDepositIds(RECIPIENT, 0, 256);
        assertEq(ids.length, 3);
        assertEq(ids[0], 2);
        assertEq(ids[1], 4);
        assertEq(ids[2], 6);
        _claim(RECIPIENT, dest, _tokens(address(other)), 1);
        (ids, cursor) = vault.getOpenDepositIds(RECIPIENT, 0, 256);
        assertEq(ids.length, 0);
        assertEq(cursor, 0);
    }

    function test_invalidPagination() public {
        _deposit(RECIPIENT, address(usdc), 1e6);
        vm.expectRevert(HandleVault.InvalidPageSize.selector);
        vault.getOpenDepositIds(RECIPIENT, 0, 0);
        vm.expectRevert(HandleVault.InvalidPageSize.selector);
        vault.getOpenDepositIds(RECIPIENT, 0, 257);
        vm.expectRevert(HandleVault.InvalidCursor.selector);
        vault.getOpenDepositIds(SECOND_RECIPIENT, 1, 1);
        vm.expectRevert(HandleVault.InvalidCursor.selector);
        vault.getOpenDepositIds(RECIPIENT, 2, 1);
        _claim(RECIPIENT, dest, _tokens(address(usdc)), 0);
        vm.expectRevert(HandleVault.InvalidCursor.selector);
        vault.getOpenDepositIds(RECIPIENT, 1, 1);
    }

    function test_refundExactDelayToOriginalSenderByAnyone() public {
        uint256 starting = usdc.balanceOf(sender);
        uint256 id = _deposit(RECIPIENT, address(usdc), 3e6);
        uint256 refundableAt = vm.getBlockTimestamp() + 180 days;
        vm.warp(refundableAt - 1);
        vm.expectRevert(abi.encodeWithSelector(HandleVault.RefundTooEarly.selector, refundableAt));
        vault.refund(id);
        vm.warp(refundableAt);
        vm.expectEmit(true, true, true, true, address(vault));
        emit Refunded(id, RECIPIENT, address(usdc), 3e6, sender);
        vm.prank(relayer);
        vault.refund(id);
        assertEq(usdc.balanceOf(sender), starting);
        assertEq(usdc.balanceOf(relayer), 0);
        assertEq(uint256(_status(id)), uint256(HandleVault.Status.Refunded));
        assertEq(vault.rollingOutflow(address(usdc)), 0);
        _assertAccounting(address(usdc));
        vm.expectRevert(HandleVault.DepositNotOpen.selector);
        vault.refund(id);
    }

    function test_refundNativeNoFeeWhilePausedDisabledAndCapZero() public {
        uint256 starting = sender.balance;
        uint256 id = _deposit(RECIPIENT, address(0), 1 ether);
        vm.startPrank(owner);
        vault.setFee(100, treasury);
        vault.setOutflowCap(address(0), 0);
        vault.setTokenConfig(address(0), false, 1);
        vault.pause();
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 180 days + 1);
        vault.refund(id);
        assertEq(sender.balance, starting);
        assertEq(vault.accruedFees(address(0)), 0);
        _assertAccounting(address(0));
    }

    function test_refundClaimedOrUnknownRejected() public {
        uint256 id = _deposit(RECIPIENT, address(usdc), 1e6);
        _claim(RECIPIENT, dest, _tokens(address(usdc)), 0);
        vm.warp(vm.getBlockTimestamp() + 180 days);
        vm.expectRevert(HandleVault.DepositNotOpen.selector);
        vault.refund(id);
        vm.expectRevert(HandleVault.DepositNotOpen.selector);
        vault.refund(0);
        vm.expectRevert(HandleVault.DepositNotOpen.selector);
        vault.refund(999);
    }

    function test_matureDepositsStillClaimableUntilRefunded() public {
        _deposit(RECIPIENT, address(usdc), 1e6);
        vm.warp(vm.getBlockTimestamp() + 200 days);
        assertEq(_claim(RECIPIENT, dest, _tokens(address(usdc)), 0), 1);
    }

    function test_capPartialSweepAndRollover() public {
        vm.prank(owner);
        vault.setOutflowCap(address(usdc), 1000e6);
        _deposit(RECIPIENT, address(usdc), 600e6);
        _deposit(RECIPIENT, address(usdc), 600e6);
        uint256 firstTime = vm.getBlockTimestamp();
        assertEq(_claim(RECIPIENT, dest, _tokens(address(usdc)), 0), 1);
        assertEq(vault.rollingOutflow(address(usdc)), 600e6);
        assertEq(vault.remainingOutflow(address(usdc)), 400e6);
        bytes memory sig = _signature(OWNER_KEY, RECIPIENT, dest, 1, firstTime + 2 days);
        vm.warp(firstTime + 24 hours - 1);
        vm.expectRevert(HandleVault.OutflowCapExceeded.selector);
        vault.claim(RECIPIENT, dest, _tokens(address(usdc)), 1, firstTime + 2 days, sig);
        assertFalse(vault.usedNonces(RECIPIENT, 1));
        vm.warp(firstTime + 24 hours);
        assertEq(vault.rollingOutflow(address(usdc)), 0);
        assertEq(vault.claim(RECIPIENT, dest, _tokens(address(usdc)), 1, firstTime + 2 days, sig), 1);
        assertEq(usdc.balanceOf(dest), 1200e6);
    }

    function test_capIsRollingNotCalendarBucketAndCannotBeResetByConfig() public {
        vm.prank(owner);
        vault.setOutflowCap(address(usdc), 1000e6);
        uint256 start = vm.getBlockTimestamp();
        _deposit(RECIPIENT, address(usdc), 400e6);
        _claim(RECIPIENT, dest, _tokens(address(usdc)), 0);
        vm.warp(start + 23 hours);
        _deposit(RECIPIENT, address(usdc), 400e6);
        _claim(RECIPIENT, dest, _tokens(address(usdc)), 1);
        vm.startPrank(owner);
        vault.setOutflowCap(address(usdc), 0);
        assertEq(vault.remainingOutflow(address(usdc)), 0);
        vault.setTokenConfig(address(usdc), false, 1e6);
        vault.setTokenConfig(address(usdc), true, 1e6);
        vault.setOutflowCap(address(usdc), 1000e6);
        vm.stopPrank();
        assertEq(vault.remainingOutflow(address(usdc)), 200e6);
        vm.warp(start + 24 hours);
        assertEq(vault.rollingOutflow(address(usdc)), 400e6);
        assertEq(vault.remainingOutflow(address(usdc)), 600e6);
        vm.warp(start + 47 hours);
        assertEq(vault.rollingOutflow(address(usdc)), 0);
    }

    function test_capCountsAllRecipientsAndFeesAndSameTimestampClaims() public {
        vm.startPrank(owner);
        vault.setOutflowCap(address(usdc), 100e6);
        vault.setFee(100, treasury);
        vm.stopPrank();
        _deposit(RECIPIENT, address(usdc), 40e6);
        _deposit(SECOND_RECIPIENT, address(usdc), 60e6);
        _claim(RECIPIENT, dest, _tokens(address(usdc)), 0);
        _claim(SECOND_RECIPIENT, dest, _tokens(address(usdc)), 0);
        assertEq(vault.rollingOutflow(address(usdc)), 100e6);
        assertEq(vault.remainingOutflow(address(usdc)), 0);
        assertEq(usdc.balanceOf(dest), 99e6);
        vault.withdrawFees(address(usdc));
        assertEq(vault.rollingOutflow(address(usdc)), 100e6);
        assertEq(usdc.balanceOf(treasury), 1e6);
        _assertAccounting(address(usdc));
    }

    function test_capBlockedTokenDoesNotBlockAnotherToken() public {
        _deposit(RECIPIENT, address(usdc), 1e6);
        _deposit(RECIPIENT, address(other), 1);
        vm.prank(owner);
        vault.setOutflowCap(address(usdc), 0);
        address[] memory tokens = new address[](2);
        tokens[0] = address(usdc);
        tokens[1] = address(other);
        assertEq(_claim(RECIPIENT, dest, tokens, 0), 1);
        assertEq(vault.totalEscrowed(RECIPIENT, address(usdc)), 1e6);
        assertEq(other.balanceOf(dest), 1);
    }

    function test_nativeCapEnforcement() public {
        _deposit(RECIPIENT, address(0), 6 ether);
        _deposit(RECIPIENT, address(0), 6 ether);
        assertEq(_claim(RECIPIENT, dest, _tokens(address(0)), 0), 1);
        assertEq(vault.rollingOutflow(address(0)), 6 ether);
        vm.expectRevert(HandleVault.OutflowCapExceeded.selector);
        _claim(RECIPIENT, dest, _tokens(address(0)), 1);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        assertEq(_claim(RECIPIENT, dest, _tokens(address(0)), 1), 1);
    }

    function test_feeMaxRoundedPerDepositAndWithdrawOnlyFees() public {
        vm.prank(owner);
        vault.setFee(100, treasury);
        _deposit(RECIPIENT, address(other), 199);
        _deposit(RECIPIENT, address(other), 199);
        _deposit(SECOND_RECIPIENT, address(other), 13);
        _claim(RECIPIENT, dest, _tokens(address(other)), 0);
        assertEq(other.balanceOf(dest), 396);
        assertEq(vault.accruedFees(address(other)), 2);
        _assertAccounting(address(other));
        vm.prank(owner);
        vault.pause();
        vm.prank(relayer);
        vault.withdrawFees(address(other));
        assertEq(other.balanceOf(treasury), 2);
        assertEq(other.balanceOf(address(vault)), 13);
        assertEq(vault.totalOpen(address(other)), 13);
        _assertAccounting(address(other));
        vm.expectRevert(HandleVault.NoFees.selector);
        vault.withdrawFees(address(other));
    }

    function test_nativeFeesAndRecipientChange() public {
        _deposit(RECIPIENT, address(0), 1 ether);
        vm.prank(owner);
        vault.setFee(100, treasury);
        _claim(RECIPIENT, dest, _tokens(address(0)), 0);
        assertEq(dest.balance, 0.99 ether);
        assertEq(vault.accruedFees(address(0)), 0.01 ether);
        vm.prank(owner);
        vault.setFee(0, relayer);
        vault.withdrawFees(address(0));
        assertEq(relayer.balance, 0.01 ether);
        assertEq(treasury.balance, 0);
        _assertAccounting(address(0));
    }

    function test_feeRejectsInvalidParameters() public {
        vm.startPrank(owner);
        vm.expectRevert(HandleVault.FeeTooHigh.selector);
        vault.setFee(101, treasury);
        vm.expectRevert(HandleVault.InvalidAddress.selector);
        vault.setFee(0, address(0));
        vm.expectRevert(HandleVault.InvalidAddress.selector);
        vault.setFee(0, address(vault));
        vm.stopPrank();
    }

    function test_allowlistAndMinimumsAndMaxDeposit() public {
        vm.prank(owner);
        vault.setTokenConfig(address(other), false, 1);
        vm.expectRevert(abi.encodeWithSelector(HandleVault.TokenNotAllowed.selector, address(other)));
        vault.depositFor(RECIPIENT, address(other), 1);
        vm.expectRevert(abi.encodeWithSelector(HandleVault.BelowMinimum.selector, 1e6));
        vault.depositFor(RECIPIENT, address(usdc), 1e6 - 1);
        vm.expectRevert(abi.encodeWithSelector(HandleVault.BelowMinimum.selector, 1e6));
        vault.depositFor(RECIPIENT, address(usdc), 0);
        vm.expectRevert(abi.encodeWithSelector(HandleVault.DepositExceedsCap.selector, 100_000e6));
        vault.depositFor(RECIPIENT, address(usdc), 100_000e6 + 1);
        vm.expectRevert(HandleVault.UseNativeDeposit.selector);
        vault.depositFor(RECIPIENT, address(0), 1);
        vm.deal(address(this), 11 ether);
        vm.expectRevert(abi.encodeWithSelector(HandleVault.BelowMinimum.selector, 0.0001 ether));
        vault.depositNativeFor{value: 1}(RECIPIENT);
        vm.expectRevert(abi.encodeWithSelector(HandleVault.DepositExceedsCap.selector, 10 ether));
        vault.depositNativeFor{value: 11 ether}(RECIPIENT);
        _deposit(RECIPIENT, address(usdc), 1e6);
        _deposit(RECIPIENT, address(0), 0.0001 ether);
        vm.startPrank(owner);
        vault.setTokenConfig(address(usdc), false, 1e6);
        vault.setTokenConfig(address(0), false, 1);
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(HandleVault.TokenNotAllowed.selector, address(0)));
        vault.depositNativeFor(RECIPIENT);
        // Deallowlisting affects only incoming deposits.
        assertEq(_claim(RECIPIENT, dest, _tokens(address(usdc)), 0), 1);
        assertEq(_claim(RECIPIENT, dest, _tokens(address(0)), 1), 1);
    }

    function test_configurationValidationAndNoCodeToken() public {
        vm.startPrank(owner);
        vm.expectRevert(HandleVault.InvalidMinimum.selector);
        vault.setTokenConfig(address(usdc), true, 0);
        vm.expectRevert(HandleVault.InvalidAddress.selector);
        vault.setTokenConfig(address(vault), true, 1);
        vault.setTokenConfig(relayer, true, 1);
        vault.setOutflowCap(relayer, 100);
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(HandleVault.InvalidToken.selector, relayer));
        vault.depositFor(RECIPIENT, relayer, 1);
    }

    function test_pauseSemanticsAndUnpause() public {
        uint256 id = _deposit(RECIPIENT, address(usdc), 1e6);
        bytes memory signature = _signature(OWNER_KEY, RECIPIENT, dest, 0, type(uint256).max);
        vm.prank(owner);
        vault.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.depositFor(RECIPIENT, address(usdc), 1e6);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.depositNativeFor(RECIPIENT);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.claim(RECIPIENT, dest, _tokens(address(usdc)), 0, type(uint256).max, signature);
        vm.warp(vm.getBlockTimestamp() + 180 days);
        vault.refund(id);
        vm.prank(owner);
        vault.unpause();
        _deposit(RECIPIENT, address(usdc), 2e6);
        assertEq(vault.claim(RECIPIENT, dest, _tokens(address(usdc)), 0, type(uint256).max, signature), 1);
    }

    function test_adminOnlySettersAndRoleManagement() public {
        bytes memory denied =
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, sender, bytes32(0));
        vm.startPrank(sender);
        vm.expectRevert(denied);
        vault.setTokenConfig(address(usdc), true, 1);
        vm.expectRevert(denied);
        vault.setOutflowCap(address(usdc), type(uint256).max);
        vm.expectRevert(denied);
        vault.setFee(100, sender);
        bytes32 authorizerRole = vault.AUTHORIZER_ROLE();
        vm.expectRevert(denied);
        vault.grantRole(authorizerRole, sender);
        vm.expectRevert(denied);
        vault.revokeRole(authorizerRole, owner);
        vm.expectRevert(denied);
        vault.beginDefaultAdminTransfer(sender);
        vm.stopPrank();
    }

    function test_pauserRoleSeparatedFromAuthorizer() public {
        bytes32 role = vault.PAUSER_ROLE();
        vm.prank(sender);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, sender, role));
        vault.pause();
        vm.prank(owner);
        vault.grantRole(role, sender);
        vm.prank(sender);
        vault.pause();
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, relayer, role));
        vault.unpause();
        vm.prank(sender);
        vault.unpause();
        assertFalse(vault.hasRole(vault.AUTHORIZER_ROLE(), sender));
    }

    function test_twoStepDelayedAdminTransfer() public {
        vm.prank(owner);
        vault.beginDefaultAdminTransfer(sender);
        (address pending, uint48 ready) = vault.pendingDefaultAdmin();
        assertEq(pending, sender);
        assertEq(vault.owner(), owner);
        vm.prank(sender);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControlDefaultAdminRules.AccessControlEnforcedDefaultAdminDelay.selector, ready
            )
        );
        vault.acceptDefaultAdminTransfer();
        vm.warp(uint256(ready) + 1);
        vm.prank(relayer);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControlDefaultAdminRules.AccessControlInvalidDefaultAdmin.selector, relayer)
        );
        vault.acceptDefaultAdminTransfer();
        vm.prank(sender);
        vault.acceptDefaultAdminTransfer();
        assertEq(vault.owner(), sender);
        assertFalse(vault.hasRole(bytes32(0), owner));
        vm.prank(sender);
        vault.setFee(100, treasury);
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, owner, bytes32(0))
        );
        vault.setFee(0, treasury);
        // Transferring admin is deliberately independent of signer and pauser rotation.
        assertTrue(vault.hasRole(vault.AUTHORIZER_ROLE(), owner));
    }

    function test_adminHandoverCancellationAndNoBypassOrRenounce() public {
        vm.startPrank(owner);
        vault.beginDefaultAdminTransfer(sender);
        vault.cancelDefaultAdminTransfer();
        (address pending,) = vault.pendingDefaultAdmin();
        assertEq(pending, address(0));
        vm.expectRevert(HandleVault.InvalidAddress.selector);
        vault.beginDefaultAdminTransfer(address(0));
        vm.expectRevert(HandleVault.InvalidAddress.selector);
        vault.beginDefaultAdminTransfer(address(vault));
        vm.expectRevert(IAccessControlDefaultAdminRules.AccessControlEnforcedDefaultAdminRules.selector);
        vault.grantRole(bytes32(0), sender);
        vm.expectRevert(IAccessControlDefaultAdminRules.AccessControlEnforcedDefaultAdminRules.selector);
        vault.revokeRole(bytes32(0), owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControlDefaultAdminRules.AccessControlEnforcedDefaultAdminDelay.selector, uint48(0)
            )
        );
        vault.renounceRole(bytes32(0), owner);
        vm.stopPrank();
    }

    function test_nativeDirectTransferRejected() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(vault).call{value: 1}("");
        assertFalse(ok);
        assertEq(address(vault).balance, 0);
    }

    function testFuzz_amountsAndFeesConserveFunds(uint96 rawAmount, uint16 rawFee) public {
        uint256 amount = bound(rawAmount, 1e6, 100_000e6);
        uint256 fee = bound(rawFee, 0, 100);
        vm.prank(owner);
        vault.setFee(fee, treasury);
        _deposit(RECIPIENT, address(usdc), amount);
        _claim(RECIPIENT, dest, _tokens(address(usdc)), 0);
        uint256 expectedFee = amount * fee / 10_000;
        assertEq(usdc.balanceOf(dest), amount - expectedFee);
        assertEq(vault.accruedFees(address(usdc)), expectedFee);
        _assertAccounting(address(usdc));
        if (expectedFee != 0) vault.withdrawFees(address(usdc));
        assertEq(usdc.balanceOf(treasury) + usdc.balanceOf(dest), amount);
        _assertAccounting(address(usdc));
    }

    function testFuzz_nativeAmountRefundedInFull(uint96 rawAmount, uint32 extraDelay) public {
        uint256 amount = bound(rawAmount, 0.0001 ether, 10 ether);
        uint256 initial = sender.balance;
        uint256 id = _deposit(RECIPIENT, address(0), amount);
        vm.warp(vm.getBlockTimestamp() + 180 days + extraDelay);
        vault.refund(id);
        assertEq(sender.balance, initial);
        _assertAccounting(address(0));
    }

    function test_maxUintAmountFeeDoesNotOverflow() public {
        MockUSDC huge = new MockUSDC(owner);
        vm.startPrank(owner);
        huge.mint(sender, type(uint256).max);
        vault.setTokenConfig(address(huge), true, 1);
        vault.setOutflowCap(address(huge), type(uint256).max);
        vault.setFee(100, treasury);
        vm.stopPrank();
        _deposit(RECIPIENT, address(huge), type(uint256).max);
        _claim(RECIPIENT, dest, _tokens(address(huge)), 0);
        assertEq(vault.accruedFees(address(huge)), type(uint256).max / 100);
        _assertAccounting(address(huge));
    }

    function test_lifetimeOutflowWrapDoesNotDisableClaims() public {
        MockUSDC huge = new MockUSDC(owner);
        vm.startPrank(owner);
        huge.mint(sender, type(uint256).max);
        vault.setTokenConfig(address(huge), true, 1);
        vault.setOutflowCap(address(huge), type(uint256).max);
        vm.stopPrank();
        _deposit(RECIPIENT, address(huge), type(uint256).max);
        _claim(RECIPIENT, dest, _tokens(address(huge)), 0);
        assertEq(vault.rollingOutflow(address(huge)), type(uint256).max);
        vm.prank(dest);
        huge.transfer(sender, type(uint256).max);
        _deposit(RECIPIENT, address(huge), 5);
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        _claim(RECIPIENT, dest, _tokens(address(huge)), 1);
        assertEq(vault.rollingOutflow(address(huge)), 5);
        _deposit(RECIPIENT, address(huge), 8);
        _claim(RECIPIENT, dest, _tokens(address(huge)), 2);
        assertEq(vault.rollingOutflow(address(huge)), 13);
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        assertEq(vault.rollingOutflow(address(huge)), 0);
        _assertAccounting(address(huge));
    }

    function test_rollingCapAtTimestampZero() public {
        vm.warp(0);
        _deposit(RECIPIENT, address(usdc), 1e6);
        _claim(RECIPIENT, dest, _tokens(address(usdc)), 0);
        assertEq(vault.rollingOutflow(address(usdc)), 1e6);
        vm.warp(24 hours - 1);
        assertEq(vault.rollingOutflow(address(usdc)), 1e6);
        vm.warp(24 hours);
        assertEq(vault.rollingOutflow(address(usdc)), 0);
    }
}
