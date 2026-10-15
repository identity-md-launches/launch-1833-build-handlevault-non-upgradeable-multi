// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VaultFixture} from "./helpers/VaultFixture.sol";
import {HandleVault} from "../src/HandleVault.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/// @dev Boundary, event, role-separation and property tests that the base suite does not pin.
/// Every expected value here is computed independently of the vault (plain loops over the
/// inputs), never by reading the vault's own view back and asserting it against itself.
/// forge-config: default.fuzz.runs = 512
contract HandleVaultEdgesTest is VaultFixture {
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
    event TokenConfigured(address indexed token, bool allowed, uint256 minimum);
    event OutflowCapSet(address indexed token, uint256 oldCap, uint256 newCap);
    event FeeConfigured(uint256 feeBps, address indexed feeRecipient);
    event FeesWithdrawn(address indexed token, address indexed recipient, uint256 amount);
    event ClaimProcessed(bytes32 indexed recipientId, uint256 indexed nonce, address indexed dest, uint256 count);

    // ---------------------------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------------------------

    function test_constructorEmitsInitialConfiguration() public {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectEmit(true, true, true, true, predicted);
        emit TokenConfigured(address(0), true, 0.0001 ether);
        vm.expectEmit(true, true, true, true, predicted);
        emit TokenConfigured(address(usdc), true, 1e6);
        vm.expectEmit(true, true, true, true, predicted);
        emit OutflowCapSet(address(0), 0, 10 ether);
        vm.expectEmit(true, true, true, true, predicted);
        emit OutflowCapSet(address(usdc), 0, 100_000e6);
        vm.expectEmit(true, true, true, true, predicted);
        emit FeeConfigured(0, owner);
        HandleVault fresh = new HandleVault(owner, address(usdc), 0.0001 ether, 1e6, 10 ether, 100_000e6);
        assertEq(address(fresh), predicted);
    }

    function test_adminSettersEmitOldAndNewValues() public {
        vm.startPrank(owner);
        vm.expectEmit(true, true, true, true, address(vault));
        emit TokenConfigured(address(other), false, 5);
        vault.setTokenConfig(address(other), false, 5);
        (bool allowed, uint256 minimum) = vault.tokenConfigs(address(other));
        assertFalse(allowed);
        assertEq(minimum, 5);
        vm.expectEmit(true, true, true, true, address(vault));
        emit OutflowCapSet(address(usdc), 100_000e6, 7e6);
        vault.setOutflowCap(address(usdc), 7e6);
        assertEq(vault.outflowCaps(address(usdc)), 7e6);
        vm.expectEmit(true, true, true, true, address(vault));
        emit FeeConfigured(42, treasury);
        vault.setFee(42, treasury);
        assertEq(vault.feeBps(), 42);
        assertEq(vault.feeRecipient(), treasury);
        vm.stopPrank();
    }

    function test_claimEmitsClaimedPerDepositInFifoOrderThenSummary() public {
        vm.prank(owner);
        vault.setFee(100, treasury);
        uint256 a = _deposit(RECIPIENT, address(usdc), 1e6);
        uint256 b = _deposit(RECIPIENT, address(usdc), 250e6);
        uint256 c = _deposit(RECIPIENT, address(0), 1 ether);
        address[] memory tokens = new address[](2);
        tokens[0] = address(usdc);
        tokens[1] = address(0);
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory sig = _signature(OWNER_KEY, RECIPIENT, dest, 5, deadline);
        vm.expectEmit(true, true, true, true, address(vault));
        emit Claimed(a, RECIPIENT, address(usdc), 1e6, dest, 1e4);
        vm.expectEmit(true, true, true, true, address(vault));
        emit Claimed(b, RECIPIENT, address(usdc), 250e6, dest, 2.5e6);
        vm.expectEmit(true, true, true, true, address(vault));
        emit Claimed(c, RECIPIENT, address(0), 1 ether, dest, 0.01 ether);
        vm.expectEmit(true, true, true, true, address(vault));
        emit ClaimProcessed(RECIPIENT, 5, dest, 3);
        vm.prank(relayer);
        vault.claim(RECIPIENT, dest, tokens, 5, deadline, sig);
        assertEq(usdc.balanceOf(dest), 251e6 - 2.51e6);
        assertEq(dest.balance, 0.99 ether);
        vm.expectEmit(true, true, true, true, address(vault));
        emit FeesWithdrawn(address(usdc), treasury, 2.51e6);
        vault.withdrawFees(address(usdc));
        _assertAccounting(address(usdc));
        _assertAccounting(address(0));
    }

    // ---------------------------------------------------------------------------------------
    // Claim bounds: token list limit, per-call sweep budget, block gas
    // ---------------------------------------------------------------------------------------

    function test_sixteenTokensAndSixtyFourDepositsFitOneClaimWellUnderBlockGas() public {
        address[] memory tokens = new address[](16);
        for (uint256 i; i < 16; ++i) {
            MockUSDC token = new MockUSDC(owner);
            tokens[i] = address(token);
            vm.startPrank(owner);
            token.mint(sender, 1_000e6);
            vault.setTokenConfig(address(token), true, 1);
            vault.setOutflowCap(address(token), 1_000e6);
            vm.stopPrank();
            for (uint256 j; j < 4; ++j) {
                _deposit(RECIPIENT, address(token), 10e6 + j);
            }
        }
        assertEq(vault.openDepositCount(RECIPIENT), 64);
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory sig = _signature(OWNER_KEY, RECIPIENT, dest, 0, deadline);
        vm.prank(relayer);
        uint256 gasBefore = gasleft();
        uint256 count = vault.claim(RECIPIENT, dest, tokens, 0, deadline, sig);
        uint256 used = gasBefore - gasleft();
        assertEq(count, 64);
        assertLt(used, 12_000_000, "a maximal claim must fit comfortably in a block");
        assertEq(vault.openDepositCount(RECIPIENT), 0);
        for (uint256 i; i < 16; ++i) {
            assertEq(MockUSDC(tokens[i]).balanceOf(dest), 40e6 + 6);
            _assertAccounting(tokens[i]);
        }
    }

    function test_sweepBudgetStopsExactlyAtSixtyFourAcrossTokenBoundary() public {
        for (uint256 i; i < 63; ++i) {
            _deposit(RECIPIENT, address(usdc), 1e6);
        }
        uint256 firstOther = _deposit(RECIPIENT, address(other), 1);
        uint256 secondOther = _deposit(RECIPIENT, address(other), 2);
        address[] memory tokens = new address[](2);
        tokens[0] = address(usdc);
        tokens[1] = address(other);
        assertEq(_claim(RECIPIENT, dest, tokens, 0), 64);
        assertEq(uint256(_status(firstOther)), uint256(HandleVault.Status.Claimed));
        assertEq(uint256(_status(secondOther)), uint256(HandleVault.Status.Open));
        assertEq(other.balanceOf(dest), 1);
        assertEq(vault.firstOpenDeposit(RECIPIENT, address(other)), secondOther);
        assertEq(vault.firstOpenDeposit(RECIPIENT, address(usdc)), 0);
        // The same nonce cannot continue; a fresh one can.
        bytes memory stale = _signature(OWNER_KEY, RECIPIENT, dest, 0, vm.getBlockTimestamp() + 1 days);
        vm.expectRevert(HandleVault.NonceAlreadyUsed.selector);
        vault.claim(RECIPIENT, dest, tokens, 0, vm.getBlockTimestamp() + 1 days, stale);
        assertEq(_claim(RECIPIENT, dest, tokens, 1), 1);
        assertEq(other.balanceOf(dest), 3);
    }

    function test_claimSkipsRefundedDepositsAndKeepsFifoOrder() public {
        uint256 a = _deposit(RECIPIENT, address(usdc), 1e6);
        uint256 b = _deposit(RECIPIENT, address(usdc), 2e6);
        uint256 c = _deposit(RECIPIENT, address(usdc), 3e6);
        vm.warp(vm.getBlockTimestamp() + 180 days);
        vault.refund(b);
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory sig = _signature(OWNER_KEY, RECIPIENT, dest, 0, deadline);
        vm.expectEmit(true, true, true, true, address(vault));
        emit Claimed(a, RECIPIENT, address(usdc), 1e6, dest, 0);
        vm.expectEmit(true, true, true, true, address(vault));
        emit Claimed(c, RECIPIENT, address(usdc), 3e6, dest, 0);
        assertEq(vault.claim(RECIPIENT, dest, _tokens(address(usdc)), 0, deadline, sig), 2);
        assertEq(usdc.balanceOf(dest), 4e6);
        assertEq(uint256(_status(b)), uint256(HandleVault.Status.Refunded));
        _assertAccounting(address(usdc));
    }

    // ---------------------------------------------------------------------------------------
    // Outflow cap boundaries
    // ---------------------------------------------------------------------------------------

    function test_depositEqualToCapAccepted() public {
        uint256 id = _deposit(RECIPIENT, address(usdc), 100_000e6);
        assertEq(uint256(_status(id)), uint256(HandleVault.Status.Open));
        assertEq(_claim(RECIPIENT, dest, _tokens(address(usdc)), 0), 1);
        assertEq(vault.remainingOutflow(address(usdc)), 0);
        _deposit(RECIPIENT, address(usdc), 1e6);
        vm.expectRevert(HandleVault.OutflowCapExceeded.selector);
        _claim(RECIPIENT, dest, _tokens(address(usdc)), 1);
    }

    function test_claimSweepsDepositEqualToRemainingCap() public {
        vm.prank(owner);
        vault.setOutflowCap(address(usdc), 1000e6);
        _deposit(RECIPIENT, address(usdc), 600e6);
        _deposit(RECIPIENT, address(usdc), 400e6);
        _deposit(RECIPIENT, address(usdc), 1e6);
        assertEq(_claim(RECIPIENT, dest, _tokens(address(usdc)), 0), 2);
        assertEq(usdc.balanceOf(dest), 1000e6);
        assertEq(vault.remainingOutflow(address(usdc)), 0);
        assertEq(vault.totalEscrowed(RECIPIENT, address(usdc)), 1e6);
    }

    /// @dev FIFO head-of-line: a queue stops at the first deposit that does not fit even if a
    /// later, smaller one would. Documented behaviour; pinned so a change is noticed.
    function test_capBlockingIsHeadOfLineFifo() public {
        vm.prank(owner);
        vault.setOutflowCap(address(usdc), 1000e6);
        _deposit(RECIPIENT, address(usdc), 900e6);
        _claim(RECIPIENT, dest, _tokens(address(usdc)), 0);
        uint256 big = _deposit(RECIPIENT, address(usdc), 500e6);
        uint256 small = _deposit(RECIPIENT, address(usdc), 50e6);
        assertEq(vault.remainingOutflow(address(usdc)), 100e6);
        vm.expectRevert(HandleVault.OutflowCapExceeded.selector);
        _claim(RECIPIENT, dest, _tokens(address(usdc)), 1);
        assertEq(uint256(_status(small)), uint256(HandleVault.Status.Open));
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        assertEq(_claim(RECIPIENT, dest, _tokens(address(usdc)), 1), 2);
        assertEq(uint256(_status(big)), uint256(HandleVault.Status.Claimed));
        assertEq(usdc.balanceOf(dest), 1450e6);
    }

    function test_adminLoweringCapBelowOpenDepositBlocksClaimButNotRefund() public {
        uint256 starting = usdc.balanceOf(sender);
        uint256 id = _deposit(RECIPIENT, address(usdc), 5000e6);
        vm.prank(owner);
        vault.setOutflowCap(address(usdc), 1000e6);
        vm.expectRevert(HandleVault.OutflowCapExceeded.selector);
        _claim(RECIPIENT, dest, _tokens(address(usdc)), 0);
        vm.prank(owner);
        vault.setOutflowCap(address(usdc), 5000e6);
        assertEq(_claim(RECIPIENT, dest, _tokens(address(usdc)), 0), 1);
        uint256 second = _deposit(RECIPIENT, address(usdc), 5000e6);
        vm.prank(owner);
        vault.setOutflowCap(address(usdc), 0);
        vm.warp(vm.getBlockTimestamp() + 180 days);
        vault.refund(second);
        assertEq(usdc.balanceOf(sender), starting - 5000e6);
        assertEq(uint256(_status(id)), uint256(HandleVault.Status.Claimed));
        assertEq(uint256(_status(second)), uint256(HandleVault.Status.Refunded));
        // Cap zero also stops new deposits of that token.
        vm.expectRevert(abi.encodeWithSelector(HandleVault.DepositExceedsCap.selector, 0));
        vm.prank(sender);
        vault.depositFor(RECIPIENT, address(usdc), 1e6);
    }

    function test_refundTokenIgnoresPauseDelistAndCapZero() public {
        uint256 starting = usdc.balanceOf(sender);
        uint256 id = _deposit(RECIPIENT, address(usdc), 3e6);
        vm.startPrank(owner);
        vault.setFee(100, treasury);
        vault.setOutflowCap(address(usdc), 0);
        vault.setTokenConfig(address(usdc), false, 1e6);
        vault.pause();
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 180 days);
        vm.expectEmit(true, true, true, true, address(vault));
        emit Refunded(id, RECIPIENT, address(usdc), 3e6, sender);
        vm.prank(relayer);
        vault.refund(id);
        assertEq(usdc.balanceOf(sender), starting);
        assertEq(vault.accruedFees(address(usdc)), 0);
        assertEq(vault.rollingOutflow(address(usdc)), 0);
        _assertAccounting(address(usdc));
    }

    // ---------------------------------------------------------------------------------------
    // Roles and custody
    // ---------------------------------------------------------------------------------------

    function test_authorizerAndPauserHaveNoAdminPowers() public {
        address signer = vm.addr(OTHER_KEY);
        address pauser = makeAddr("pauser");
        bytes32 authorizerRole = vault.AUTHORIZER_ROLE();
        bytes32 pauserRole = vault.PAUSER_ROLE();
        vm.startPrank(owner);
        vault.grantRole(authorizerRole, signer);
        vault.grantRole(pauserRole, pauser);
        vm.stopPrank();
        address[2] memory operators = [signer, pauser];
        for (uint256 i; i < 2; ++i) {
            address operator = operators[i];
            bytes memory denied =
                abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, operator, bytes32(0));
            vm.startPrank(operator);
            vm.expectRevert(denied);
            vault.setFee(100, operator);
            vm.expectRevert(denied);
            vault.setOutflowCap(address(usdc), type(uint256).max);
            vm.expectRevert(denied);
            vault.setTokenConfig(address(usdc), true, 1);
            vm.expectRevert(denied);
            vault.grantRole(authorizerRole, operator);
            vm.expectRevert(denied);
            vault.revokeRole(pauserRole, owner);
            vm.expectRevert(denied);
            vault.beginDefaultAdminTransfer(operator);
            vm.stopPrank();
        }
        vm.prank(signer);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, signer, pauserRole)
        );
        vault.pause();
        assertEq(vault.feeRecipient(), owner);
        assertEq(vault.feeBps(), 0);
    }

    function test_authorizerRenouncingItselfInvalidatesItsSignatures() public {
        _deposit(RECIPIENT, address(usdc), 1e6);
        address signer = vm.addr(OTHER_KEY);
        bytes32 role = vault.AUTHORIZER_ROLE();
        vm.prank(owner);
        vault.grantRole(role, signer);
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory sig = _signature(OTHER_KEY, RECIPIENT, dest, 0, deadline);
        vm.prank(signer);
        vault.renounceRole(role, signer);
        vm.expectRevert(HandleVault.InvalidAuthorizer.selector);
        vault.claim(RECIPIENT, dest, _tokens(address(usdc)), 0, deadline, sig);
        assertEq(_claim(RECIPIENT, dest, _tokens(address(usdc)), 0), 1);
    }

    function test_adminCannotExtractPrincipalThroughFeeSettings() public {
        _deposit(RECIPIENT, address(usdc), 500e6);
        _deposit(RECIPIENT, address(0), 2 ether);
        vm.prank(owner);
        vault.setFee(100, owner);
        vm.expectRevert(HandleVault.NoFees.selector);
        vault.withdrawFees(address(usdc));
        vm.expectRevert(HandleVault.NoFees.selector);
        vault.withdrawFees(address(0));
        uint256 ownerUsdc = usdc.balanceOf(owner);
        uint256 ownerEth = owner.balance;
        address[] memory tokens = new address[](2);
        tokens[0] = address(usdc);
        tokens[1] = address(0);
        _claim(RECIPIENT, dest, tokens, 0);
        vault.withdrawFees(address(usdc));
        vault.withdrawFees(address(0));
        assertEq(usdc.balanceOf(owner) - ownerUsdc, 5e6);
        assertEq(owner.balance - ownerEth, 0.02 ether);
        assertEq(usdc.balanceOf(address(vault)), 0);
        assertEq(address(vault).balance, 0);
    }

    function test_claimantMayRelayForItselfAndDestMayBeTheRelayer() public {
        _deposit(RECIPIENT, address(usdc), 1e6);
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory sig = _signature(OWNER_KEY, RECIPIENT, relayer, 0, deadline);
        vm.prank(relayer);
        assertEq(vault.claim(RECIPIENT, relayer, _tokens(address(usdc)), 0, deadline, sig), 1);
        assertEq(usdc.balanceOf(relayer), 1e6);
    }

    function test_zeroRecipientIdAndMaxNonceAreOrdinaryValues() public {
        bytes32 zero = bytes32(0);
        _deposit(zero, address(usdc), 1e6);
        assertEq(vault.totalEscrowed(zero, address(usdc)), 1e6);
        assertEq(vault.openDepositCount(zero), 1);
        (uint256[] memory ids,) = vault.getOpenDepositIds(zero, 0, 10);
        assertEq(ids.length, 1);
        assertEq(_claim(zero, dest, _tokens(address(usdc)), type(uint256).max), 1);
        assertTrue(vault.usedNonces(zero, type(uint256).max));
        assertFalse(vault.usedNonces(RECIPIENT, type(uint256).max));
        _deposit(zero, address(usdc), 1e6);
        vm.expectRevert(HandleVault.NonceAlreadyUsed.selector);
        _claim(zero, dest, _tokens(address(usdc)), type(uint256).max);
    }

    function test_compactSixtyFourByteSignatureRejected() public {
        _deposit(RECIPIENT, address(usdc), 1e6);
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(OWNER_KEY, _referenceDigest(address(vault), block.chainid, RECIPIENT, dest, 0, deadline));
        bytes32 vs = bytes32(uint256(s) | (uint256(v - 27) << 255));
        vm.expectRevert(HandleVault.InvalidAuthorizer.selector);
        vault.claim(RECIPIENT, dest, _tokens(address(usdc)), 0, deadline, abi.encodePacked(r, vs));
        vm.expectRevert(HandleVault.InvalidAuthorizer.selector);
        vault.claim(RECIPIENT, dest, _tokens(address(usdc)), 0, deadline, abi.encodePacked(r, s, v, uint8(1)));
        assertFalse(vault.usedNonces(RECIPIENT, 0));
    }

    function test_unpausedStateRequiredToPauseAgainAndViceVersa() public {
        vm.startPrank(owner);
        vm.expectRevert(Pausable.ExpectedPause.selector);
        vault.unpause();
        vault.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.pause();
        vault.unpause();
        vm.stopPrank();
        assertFalse(vault.paused());
    }

    // ---------------------------------------------------------------------------------------
    // Property tests
    // ---------------------------------------------------------------------------------------

    function testFuzz_feeSumOverManyDepositsMatchesPerDepositRounding(uint16 rawFee, uint96[8] memory rawAmounts)
        public
    {
        uint256 fee = bound(rawFee, 0, 100);
        vm.prank(owner);
        vault.setFee(fee, treasury);
        uint256 expectedPayout;
        uint256 expectedFees;
        uint256 gross;
        for (uint256 i; i < 8; ++i) {
            uint256 amount = bound(rawAmounts[i], 1e6, 10_000e6);
            _deposit(RECIPIENT, address(usdc), amount);
            uint256 depositFee = amount * fee / 10_000;
            expectedFees += depositFee;
            expectedPayout += amount - depositFee;
            gross += amount;
        }
        assertEq(_claim(RECIPIENT, dest, _tokens(address(usdc)), 0), 8);
        assertEq(usdc.balanceOf(dest), expectedPayout);
        assertEq(vault.accruedFees(address(usdc)), expectedFees);
        assertEq(vault.rollingOutflow(address(usdc)), gross);
        assertLe(expectedFees * 10_000, gross * 100);
        _assertAccounting(address(usdc));
    }

    function testFuzz_claimFollowsFifoUntilFirstDepositThatBreaksCap(uint96[4] memory rawAmounts, uint96 rawCap)
        public
    {
        uint256 cap = bound(rawCap, 1e6, 100_000e6);
        vm.prank(owner);
        vault.setOutflowCap(address(usdc), cap);
        uint256[4] memory amounts;
        for (uint256 i; i < 4; ++i) {
            amounts[i] = bound(rawAmounts[i], 1e6, cap);
            _deposit(RECIPIENT, address(usdc), amounts[i]);
        }
        uint256 expectedCount;
        uint256 expectedGross;
        for (uint256 i; i < 4; ++i) {
            if (amounts[i] > cap - expectedGross) break;
            expectedGross += amounts[i];
            ++expectedCount;
        }
        assertEq(_claim(RECIPIENT, dest, _tokens(address(usdc)), 0), expectedCount);
        assertEq(usdc.balanceOf(dest), expectedGross);
        assertEq(vault.rollingOutflow(address(usdc)), expectedGross);
        assertLe(expectedGross, cap);
        assertEq(vault.openDepositCount(RECIPIENT), 4 - expectedCount);
        for (uint256 i; i < 4; ++i) {
            assertEq(
                uint256(_status(i + 1)),
                uint256(i < expectedCount ? HandleVault.Status.Claimed : HandleVault.Status.Open)
            );
        }
        _assertAccounting(address(usdc));
    }

    function testFuzz_rollingWindowDropsClaimExactlyAfter24Hours(uint96 rawAmount, uint32 rawDelta) public {
        uint256 amount = bound(rawAmount, 1e6, 100_000e6);
        uint256 delta = bound(rawDelta, 0, 3 days);
        _deposit(RECIPIENT, address(usdc), amount);
        _claim(RECIPIENT, dest, _tokens(address(usdc)), 0);
        vm.warp(vm.getBlockTimestamp() + delta);
        uint256 expected = delta < 24 hours ? amount : 0;
        assertEq(vault.rollingOutflow(address(usdc)), expected);
        assertEq(vault.remainingOutflow(address(usdc)), 100_000e6 - expected);
    }

    function testFuzz_rollingWindowMatchesNaiveSumOverManyCheckpoints(uint8 rawCount, uint256 seed) public {
        uint256 count = bound(rawCount, 1, 24);
        uint256[] memory times = new uint256[](count);
        uint256[] memory amounts = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            uint256 step = uint256(keccak256(abi.encode(seed, i, "step"))) % 6 hours;
            uint256 amount = 1e6 + uint256(keccak256(abi.encode(seed, i, "amount"))) % 100e6;
            vm.warp(vm.getBlockTimestamp() + step);
            times[i] = vm.getBlockTimestamp();
            amounts[i] = amount;
            _deposit(RECIPIENT, address(usdc), amount);
            _claim(RECIPIENT, dest, _tokens(address(usdc)), i);
        }
        for (uint256 k; k < 8; ++k) {
            uint256 at = times[count - 1] + k * 4 hours;
            vm.warp(at);
            uint256 naive;
            for (uint256 i; i < count; ++i) {
                if (times[i] + 24 hours > at) naive += amounts[i];
            }
            assertEq(vault.rollingOutflow(address(usdc)), naive);
        }
    }

    function testFuzz_refundTimingBoundary(uint96 rawAmount, uint32 rawEarly, uint32 rawLate) public {
        uint256 amount = bound(rawAmount, 1e6, 100_000e6);
        uint256 early = bound(rawEarly, 1, 180 days);
        uint256 starting = usdc.balanceOf(sender);
        uint256 id = _deposit(RECIPIENT, address(usdc), amount);
        uint256 createdAt = vm.getBlockTimestamp();
        vm.warp(createdAt + 180 days - early);
        vm.expectRevert(abi.encodeWithSelector(HandleVault.RefundTooEarly.selector, createdAt + 180 days));
        vault.refund(id);
        vm.warp(createdAt + 180 days + rawLate);
        vault.refund(id);
        assertEq(usdc.balanceOf(sender), starting);
        assertEq(uint256(_status(id)), uint256(HandleVault.Status.Refunded));
        vm.expectRevert(HandleVault.DepositNotOpen.selector);
        vault.refund(id);
    }

    function testFuzz_deadlineBoundary(uint64 rawNow, uint64 deadline) public {
        uint256 now_ = bound(rawNow, 1, type(uint64).max);
        _deposit(RECIPIENT, address(usdc), 1e6);
        vm.warp(now_);
        bytes memory sig = _signature(OWNER_KEY, RECIPIENT, dest, 0, deadline);
        if (now_ > deadline) {
            vm.expectRevert(HandleVault.ExpiredClaim.selector);
            vault.claim(RECIPIENT, dest, _tokens(address(usdc)), 0, deadline, sig);
            assertFalse(vault.usedNonces(RECIPIENT, 0));
        } else {
            assertEq(vault.claim(RECIPIENT, dest, _tokens(address(usdc)), 0, deadline, sig), 1);
            assertTrue(vault.usedNonces(RECIPIENT, 0));
        }
    }

    function testFuzz_anyKeyWithoutRoleIsRejected(uint256 rawKey, uint256 nonce) public {
        uint256 key = bound(rawKey, 1, SECP256K1_ORDER - 1);
        if (key == OWNER_KEY) key += 1;
        _deposit(RECIPIENT, address(usdc), 1e6);
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory sig = _signature(key, RECIPIENT, dest, nonce, deadline);
        vm.expectRevert(HandleVault.InvalidAuthorizer.selector);
        vault.claim(RECIPIENT, dest, _tokens(address(usdc)), nonce, deadline, sig);
        assertFalse(vault.usedNonces(RECIPIENT, nonce));
        assertEq(vault.totalEscrowed(RECIPIENT, address(usdc)), 1e6);
    }

    function testFuzz_signatureBindsEveryField(bytes32 otherRecipient, address otherDest, uint256 nonce, uint64 skew)
        public
    {
        vm.assume(otherRecipient != RECIPIENT);
        vm.assume(otherDest != dest && otherDest != address(0) && otherDest != address(vault));
        vm.assume(skew != 0);
        _deposit(RECIPIENT, address(usdc), 1e6);
        _deposit(otherRecipient, address(usdc), 1e6);
        uint256 deadline = vm.getBlockTimestamp() + 1 days;
        bytes memory sig = _signature(OWNER_KEY, RECIPIENT, dest, nonce, deadline);
        vm.expectRevert(HandleVault.InvalidAuthorizer.selector);
        vault.claim(otherRecipient, dest, _tokens(address(usdc)), nonce, deadline, sig);
        vm.expectRevert(HandleVault.InvalidAuthorizer.selector);
        vault.claim(RECIPIENT, otherDest, _tokens(address(usdc)), nonce, deadline, sig);
        vm.expectRevert(HandleVault.InvalidAuthorizer.selector);
        vault.claim(RECIPIENT, dest, _tokens(address(usdc)), nonce ^ uint256(skew), deadline, sig);
        vm.expectRevert(HandleVault.InvalidAuthorizer.selector);
        vault.claim(RECIPIENT, dest, _tokens(address(usdc)), nonce, deadline + skew, sig);
        assertEq(vault.claim(RECIPIENT, dest, _tokens(address(usdc)), nonce, deadline, sig), 1);
    }

    function testFuzz_paginationVisitsEveryOpenDepositOnceInOrder(uint8 rawCount, uint8 rawLimit, uint64 closeMask)
        public
    {
        uint256 count = bound(rawCount, 1, 48);
        uint256 limit = bound(rawLimit, 1, 256);
        for (uint256 i; i < count; ++i) {
            _deposit(RECIPIENT, i % 3 == 0 ? address(other) : address(usdc), i % 3 == 0 ? 1 : 1e6);
        }
        vm.warp(vm.getBlockTimestamp() + 180 days);
        uint256 expectedOpen;
        for (uint256 i; i < count; ++i) {
            if (closeMask & (uint64(1) << uint64(i)) != 0) vault.refund(i + 1);
            else ++expectedOpen;
        }
        uint256 cursor;
        uint256 previous;
        uint256 seen;
        uint256 pages;
        do {
            (uint256[] memory ids, uint256 next) = vault.getOpenDepositIds(RECIPIENT, cursor, limit);
            assertLe(ids.length, limit);
            if (next != 0) assertEq(ids.length, limit);
            for (uint256 i; i < ids.length; ++i) {
                assertGt(ids[i], previous);
                assertEq(uint256(_status(ids[i])), uint256(HandleVault.Status.Open));
                assertEq(closeMask & (uint64(1) << uint64(ids[i] - 1)), 0);
                previous = ids[i];
                ++seen;
            }
            cursor = next;
            ++pages;
        } while (cursor != 0 && pages < 300);
        assertEq(seen, expectedOpen);
        assertEq(vault.openDepositCount(RECIPIENT), expectedOpen);
    }

    function testFuzz_minimumAndAllowlistBoundaries(uint96 rawMinimum, uint96 rawAmount) public {
        uint256 minimum = bound(rawMinimum, 1, 100_000e6);
        uint256 amount = bound(rawAmount, 1, 100_000e6);
        vm.prank(owner);
        vault.setTokenConfig(address(usdc), true, minimum);
        vm.startPrank(sender);
        usdc.approve(address(vault), amount);
        if (amount < minimum) {
            vm.expectRevert(abi.encodeWithSelector(HandleVault.BelowMinimum.selector, minimum));
            vault.depositFor(RECIPIENT, address(usdc), amount);
            assertEq(vault.nextDepositId(), 1);
        } else {
            assertEq(vault.depositFor(RECIPIENT, address(usdc), amount), 1);
            assertEq(vault.totalEscrowed(RECIPIENT, address(usdc)), amount);
        }
        vm.stopPrank();
    }
}
