// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VaultFixture} from "./helpers/VaultFixture.sol";
import {HostileToken, NoReturnToken, NativeReceiver} from "./helpers/Adversaries.sol";
import {HandleVault} from "../src/HandleVault.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract AdversarialTest is VaultFixture {
    HostileToken private hostile;
    NativeReceiver private receiver;

    function setUp() public override {
        super.setUp();
        hostile = new HostileToken();
        receiver = new NativeReceiver();
        receiver.configure(vault, "", false);
        hostile.mint(sender, 1000);
        vm.startPrank(owner);
        vault.setTokenConfig(address(hostile), true, 1);
        vault.setOutflowCap(address(hostile), 1000);
        vm.stopPrank();
    }

    function test_feeOnTransferRejectedWithoutCreatingLiabilities() public {
        hostile.configure(false, false, true);
        vm.startPrank(sender);
        hostile.approve(address(vault), 100);
        vm.expectRevert(abi.encodeWithSelector(HandleVault.UnsupportedTransfer.selector, address(hostile)));
        vault.depositFor(RECIPIENT, address(hostile), 100);
        vm.stopPrank();
        assertEq(hostile.balanceOf(address(vault)), 0);
        assertEq(hostile.balanceOf(sender), 1000);
        assertEq(vault.totalOpen(address(hostile)), 0);
        assertEq(vault.nextDepositId(), 1);
        assertEq(vault.openDepositCount(RECIPIENT), 0);
    }

    function test_safeERC20RejectsFalseReturnOnDeposit() public {
        hostile.configure(false, true, false);
        vm.startPrank(sender);
        hostile.approve(address(vault), 100);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(hostile)));
        vault.depositFor(RECIPIENT, address(hostile), 100);
        vm.stopPrank();
        assertEq(vault.nextDepositId(), 1);
        assertEq(vault.totalOpen(address(hostile)), 0);
    }

    function test_tokenEnablingTaxAfterDepositCannotUnderpayClaimOrRefund() public {
        uint256 id = _deposit(RECIPIENT, address(hostile), 100);
        hostile.configure(false, false, true);
        vm.expectRevert(abi.encodeWithSelector(HandleVault.UnsupportedTransfer.selector, address(hostile)));
        _claim(RECIPIENT, dest, _tokens(address(hostile)), 0);
        assertEq(uint256(_status(id)), uint256(HandleVault.Status.Open));
        assertEq(hostile.balanceOf(dest), 0);
        vm.warp(vm.getBlockTimestamp() + 180 days);
        vm.expectRevert(abi.encodeWithSelector(HandleVault.UnsupportedTransfer.selector, address(hostile)));
        vault.refund(id);
        assertEq(uint256(_status(id)), uint256(HandleVault.Status.Open));
        hostile.configure(false, false, false);
        vault.refund(id);
        _assertAccounting(address(hostile));
    }

    function test_missingAllowanceRevertsWithoutDepositRecord() public {
        vm.prank(sender);
        vm.expectRevert();
        vault.depositFor(RECIPIENT, address(usdc), 1e6);
        assertEq(vault.nextDepositId(), 1);
        assertEq(vault.totalOpen(address(usdc)), 0);
    }

    function test_safeERC20SupportsNoReturnTokens() public {
        NoReturnToken token = new NoReturnToken();
        token.mint(sender, 1000);
        vm.startPrank(owner);
        vault.setTokenConfig(address(token), true, 1);
        vault.setOutflowCap(address(token), 1000);
        vm.stopPrank();
        vm.startPrank(sender);
        token.approve(address(vault), 1000);
        vault.depositFor(RECIPIENT, address(token), 600);
        uint256 refundId = vault.depositFor(RECIPIENT, address(token), 400);
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 180 days);
        vault.refund(refundId);
        _claim(RECIPIENT, dest, _tokens(address(token)), 0);
        assertEq(token.balanceOf(dest), 600);
        assertEq(token.balanceOf(sender), 400);
        _assertAccounting(address(token));
    }

    function test_failedTokenClaimRollsBackEveryEffectThenCanRetry() public {
        uint256 id = _deposit(RECIPIENT, address(hostile), 100);
        hostile.configure(true, false, false);
        bytes memory sig = _signature(OWNER_KEY, RECIPIENT, dest, 0, vm.getBlockTimestamp());
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(hostile)));
        vault.claim(RECIPIENT, dest, _tokens(address(hostile)), 0, vm.getBlockTimestamp(), sig);
        assertFalse(vault.usedNonces(RECIPIENT, 0));
        assertEq(uint256(_status(id)), uint256(HandleVault.Status.Open));
        assertEq(vault.rollingOutflow(address(hostile)), 0);
        assertEq(vault.firstOpenDeposit(RECIPIENT, address(hostile)), id);
        assertEq(vault.totalOpen(address(hostile)), 100);
        hostile.configure(false, false, false);
        assertEq(vault.claim(RECIPIENT, dest, _tokens(address(hostile)), 0, vm.getBlockTimestamp(), sig), 1);
        _assertAccounting(address(hostile));
    }

    function test_failedNativeTransferRollsBackEarlierTokenPayoutAndFees() public {
        uint256 tokenId = _deposit(RECIPIENT, address(usdc), 1e6);
        uint256 nativeId = _deposit(RECIPIENT, address(0), 1 ether);
        vm.prank(owner);
        vault.setFee(100, treasury);
        receiver.configure(vault, "", true);
        address[] memory tokens = new address[](2);
        tokens[0] = address(usdc);
        tokens[1] = address(0);
        bytes memory sig = _signature(OWNER_KEY, RECIPIENT, address(receiver), 0, vm.getBlockTimestamp());
        vm.expectRevert(HandleVault.NativeTransferFailed.selector);
        vault.claim(RECIPIENT, address(receiver), tokens, 0, vm.getBlockTimestamp(), sig);
        assertEq(usdc.balanceOf(address(receiver)), 0);
        assertEq(uint256(_status(tokenId)), uint256(HandleVault.Status.Open));
        assertEq(uint256(_status(nativeId)), uint256(HandleVault.Status.Open));
        assertFalse(vault.usedNonces(RECIPIENT, 0));
        assertEq(vault.accruedFees(address(usdc)), 0);
        assertEq(vault.accruedFees(address(0)), 0);
        assertEq(vault.rollingOutflow(address(usdc)), 0);
        assertEq(vault.rollingOutflow(address(0)), 0);
        _assertAccounting(address(usdc));
        _assertAccounting(address(0));
        // Another recipient still works, and the failing destination can retry once it accepts ETH.
        _deposit(SECOND_RECIPIENT, address(0), 1 ether);
        _claim(SECOND_RECIPIENT, dest, _tokens(address(0)), 1);
        receiver.configure(vault, "", false);
        assertEq(vault.claim(RECIPIENT, address(receiver), tokens, 0, vm.getBlockTimestamp(), sig), 2);
    }

    function test_failedRefundKeepsOriginalRecordAndCanRetry() public {
        vm.deal(address(this), 1 ether);
        uint256 id = receiver.depositNative{value: 1 ether}(RECIPIENT);
        receiver.configure(vault, "", true);
        vm.warp(vm.getBlockTimestamp() + 180 days);
        vm.expectRevert(HandleVault.NativeTransferFailed.selector);
        vault.refund(id);
        assertEq(uint256(_status(id)), uint256(HandleVault.Status.Open));
        assertEq(vault.totalOpen(address(0)), 1 ether);
        receiver.configure(vault, "", false);
        vault.refund(id);
        assertEq(address(receiver).balance, 1 ether);
        assertEq(receiver.observedOpenNative(), 0);
        _assertAccounting(address(0));
    }

    function test_failedTokenRefundKeepsRecord() public {
        uint256 id = _deposit(RECIPIENT, address(hostile), 100);
        hostile.configure(true, false, false);
        vm.warp(vm.getBlockTimestamp() + 180 days);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(hostile)));
        vault.refund(id);
        assertEq(uint256(_status(id)), uint256(HandleVault.Status.Open));
        hostile.configure(false, false, false);
        vault.refund(id);
        assertEq(hostile.balanceOf(sender), 1000);
    }

    function test_rejectingFeeRecipientDoesNotBlockClaimsAndWithdrawalCanRecover() public {
        receiver.configure(vault, "", true);
        vm.prank(owner);
        vault.setFee(100, address(receiver));
        _deposit(RECIPIENT, address(0), 1 ether);
        _claim(RECIPIENT, dest, _tokens(address(0)), 0);
        assertEq(dest.balance, 0.99 ether);
        vm.expectRevert(HandleVault.NativeTransferFailed.selector);
        vault.withdrawFees(address(0));
        assertEq(vault.accruedFees(address(0)), 0.01 ether);
        vm.prank(owner);
        vault.setFee(100, treasury);
        vault.withdrawFees(address(0));
        assertEq(treasury.balance, 0.01 ether);
        _assertAccounting(address(0));
    }

    function test_depositTokenCallbackCannotReenter() public {
        hostile.setCallback(address(vault), abi.encodeCall(vault.depositNativeFor, (RECIPIENT)));
        _deposit(RECIPIENT, address(hostile), 100);
        assertTrue(hostile.attempted());
        assertFalse(hostile.reentered());
        assertEq(bytes4(hostile.callbackResult()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(vault.nextDepositId(), 2);
        _assertAccounting(address(hostile));
    }

    function test_tokenPayoutCallbackCannotReenterRefund() public {
        uint256 id = _deposit(RECIPIENT, address(hostile), 100);
        vm.warp(vm.getBlockTimestamp() + 180 days);
        hostile.setCallback(address(vault), abi.encodeCall(vault.refund, (id)));
        _claim(RECIPIENT, dest, _tokens(address(hostile)), 0);
        assertTrue(hostile.attempted());
        assertFalse(hostile.reentered());
        assertEq(bytes4(hostile.callbackResult()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(hostile.balanceOf(dest), 100);
        _assertAccounting(address(hostile));
    }

    function test_nativePayoutCannotReenterClaimAndSeesSettledAccounting() public {
        _deposit(RECIPIENT, address(0), 1 ether);
        bytes memory sig = _signature(OWNER_KEY, RECIPIENT, address(receiver), 0, vm.getBlockTimestamp());
        bytes memory payload = abi.encodeCall(
            vault.claim, (RECIPIENT, address(receiver), _tokens(address(0)), 0, vm.getBlockTimestamp(), sig)
        );
        receiver.configure(vault, payload, false);
        vault.claim(RECIPIENT, address(receiver), _tokens(address(0)), 0, vm.getBlockTimestamp(), sig);
        assertTrue(receiver.attempted());
        assertFalse(receiver.reentered());
        assertEq(bytes4(receiver.result()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(receiver.observedOpenNative(), 0);
        assertEq(address(receiver).balance, 1 ether);
        _assertAccounting(address(0));
    }

    function test_nativeRefundCannotReenterRefund() public {
        vm.deal(address(this), 1 ether);
        uint256 id = receiver.depositNative{value: 1 ether}(RECIPIENT);
        receiver.configure(vault, abi.encodeCall(vault.refund, (id)), false);
        vm.warp(vm.getBlockTimestamp() + 180 days);
        vault.refund(id);
        assertTrue(receiver.attempted());
        assertFalse(receiver.reentered());
        assertEq(bytes4(receiver.result()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(address(receiver).balance, 1 ether);
        _assertAccounting(address(0));
    }

    function test_feeWithdrawalCannotReenter() public {
        vm.prank(owner);
        vault.setFee(100, address(receiver));
        _deposit(RECIPIENT, address(0), 1 ether);
        _claim(RECIPIENT, dest, _tokens(address(0)), 0);
        receiver.configure(vault, abi.encodeCall(vault.withdrawFees, (address(0))), false);
        vault.withdrawFees(address(0));
        assertTrue(receiver.attempted());
        assertFalse(receiver.reentered());
        assertEq(bytes4(receiver.result()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(address(receiver).balance, 0.01 ether);
        _assertAccounting(address(0));
    }

    function test_unsolicitedTransfersAreUnaccountedSurplusNotWithdrawableFees() public {
        vm.prank(sender);
        usdc.transfer(address(vault), 1e6);
        // Models forced ETH (e.g. a protocol balance credit); no receive function can prevent it.
        vm.deal(address(vault), 1 ether);
        _deposit(RECIPIENT, address(usdc), 1e6);
        _deposit(RECIPIENT, address(0), 1 ether);
        _claim(RECIPIENT, dest, _tokens(address(usdc)), 0);
        _claim(RECIPIENT, dest, _tokens(address(0)), 1);
        assertEq(vault.totalOpen(address(usdc)), 0);
        assertEq(vault.totalOpen(address(0)), 0);
        assertEq(usdc.balanceOf(address(vault)), 1e6);
        assertEq(address(vault).balance, 1 ether);
        vm.expectRevert(HandleVault.NoFees.selector);
        vault.withdrawFees(address(usdc));
        vm.expectRevert(HandleVault.NoFees.selector);
        vault.withdrawFees(address(0));
    }
}
