// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {HandleVault} from "../src/HandleVault.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/// @dev An unprivileged adversary drives the vault: forged, replayed, redirected and re-scoped
/// signatures, random refunds, admin calls, deposits of its own, plus a small amount of honest
/// activity so the state keeps moving. Every revert the vault produces is caught and checked
/// against the exact error expected; an unexpected revert or success is itself a failure.
contract AdversaryHandler is Test {
    uint256 private constant AUTHORIZER_KEY = 0xA11CE;
    bytes32 private constant VICTIM = keccak256("victim recipient");
    bytes32 private constant ATTACKER_RECIPIENT = keccak256("attacker recipient");

    HandleVault public immutable vault;
    MockUSDC public immutable usdc;
    address public immutable authorizer;
    address public immutable attacker;
    address public immutable honestDest;
    address public immutable honestSender;

    uint256 public attackerUsdcStart;
    uint256 public attackerEthStart;
    uint256 public attackerUsdcInEscrow;
    uint256 public attackerEthInEscrow;

    uint256 public honestClaims;
    uint256 public forgedAttempts;
    uint256 public redirectAttempts;
    uint256 public replayAttempts;
    uint256 public refundsPaid;
    uint256 public adminAttempts;

    struct Issued {
        uint256 nonce;
        uint256 deadline;
        bytes signature;
        bool used;
    }

    Issued[] private _issued;
    uint256 private _nextNonce;
    mapping(uint256 depositId => HandleVault.Status) public lastStatus;
    mapping(uint256 depositId => bytes32) public ghostRecipient;
    mapping(uint256 depositId => address) public ghostToken;
    mapping(uint256 depositId => uint256) public ghostAmount;
    mapping(uint256 depositId => address) public ghostSender;
    uint256 public recorded;

    constructor(HandleVault vault_, MockUSDC usdc_, address honestSender_) {
        vault = vault_;
        usdc = usdc_;
        authorizer = vm.addr(AUTHORIZER_KEY);
        attacker = makeAddr("attacker");
        honestDest = makeAddr("honest destination");
        honestSender = honestSender_;
        vm.deal(attacker, 100 ether);
        vm.prank(authorizer);
        usdc.mint(attacker, 1_000_000e6);
        attackerUsdcStart = usdc.balanceOf(attacker);
        attackerEthStart = attacker.balance;
    }

    // ------------------------------------------------------------------ honest activity

    function honestDeposit(uint256 tokenSeed, uint96 rawAmount, bool toAttackerRecipient) external {
        if (vault.paused()) return;
        bytes32 recipient = toAttackerRecipient ? ATTACKER_RECIPIENT : VICTIM;
        if (tokenSeed % 2 == 0) {
            uint256 amount = bound(rawAmount, 0.0001 ether, 1 ether);
            vm.deal(honestSender, honestSender.balance + amount);
            vm.prank(honestSender);
            uint256 id = vault.depositNativeFor{value: amount}(recipient);
            _record(id, recipient, address(0), amount, honestSender);
        } else {
            uint256 amount = bound(rawAmount, 1e6, 10_000e6);
            vm.prank(authorizer);
            usdc.mint(honestSender, amount);
            vm.startPrank(honestSender);
            usdc.approve(address(vault), amount);
            uint256 id = vault.depositFor(recipient, address(usdc), amount);
            vm.stopPrank();
            _record(id, recipient, address(usdc), amount, honestSender);
        }
    }

    /// @dev The authorizer issues a signature for the victim to the honest destination. It is
    /// kept so the adversary can later replay or redirect it.
    function honestClaim(uint256 tokenMask) external {
        uint256 nonce = _nextNonce++;
        uint256 deadline = vm.getBlockTimestamp() + 1 days;
        bytes memory sig = _sign(AUTHORIZER_KEY, VICTIM, honestDest, nonce, deadline);
        _issued.push(Issued(nonce, deadline, sig, false));
        if (vault.paused()) return;
        address[] memory tokens = _tokens(tokenMask);
        uint256 usdcBefore = usdc.balanceOf(honestDest);
        uint256 ethBefore = honestDest.balance;
        vm.prank(attacker);
        try vault.claim(VICTIM, honestDest, tokens, nonce, deadline, sig) returns (uint256 count) {
            assertGt(count, 0);
            assertTrue(vault.usedNonces(VICTIM, nonce));
            _issued[_issued.length - 1].used = true;
            ++honestClaims;
            _syncStatuses();
            assertGe(usdc.balanceOf(honestDest), usdcBefore);
            assertGe(honestDest.balance, ethBefore);
        } catch (bytes memory reason) {
            bytes4 selector = bytes4(reason);
            assertTrue(
                selector == HandleVault.NothingToClaim.selector || selector == HandleVault.OutflowCapExceeded.selector,
                "unexpected honest claim revert"
            );
            assertFalse(vault.usedNonces(VICTIM, nonce));
        }
    }

    // ------------------------------------------------------------------ adversary

    function forgedSignature(uint256 rawKey, uint256 nonce, uint256 tokenMask, bool targetVictim) external {
        uint256 key = bound(rawKey, 1, SECP256K1_ORDER - 1);
        if (key == AUTHORIZER_KEY) key += 1;
        bytes32 recipient = targetVictim ? VICTIM : ATTACKER_RECIPIENT;
        uint256 deadline = vm.getBlockTimestamp() + 1 days;
        bytes memory sig = _sign(key, recipient, attacker, nonce, deadline);
        ++forgedAttempts;
        vm.prank(attacker);
        try vault.claim(recipient, attacker, _tokens(tokenMask), nonce, deadline, sig) {
            revert("forged signature accepted");
        } catch (bytes memory reason) {
            bytes4 selector = bytes4(reason);
            if (vault.paused()) assertEq(selector, Pausable.EnforcedPause.selector);
            else if (vault.usedNonces(recipient, nonce)) assertEq(selector, HandleVault.NonceAlreadyUsed.selector);
            else assertEq(selector, HandleVault.InvalidAuthorizer.selector);
        }
    }

    function redirectIssuedSignature(uint256 pick, uint256 tokenMask, bool rescope) external {
        if (_issued.length == 0) return;
        Issued memory issued = _issued[pick % _issued.length];
        ++redirectAttempts;
        bytes32 recipient = rescope ? ATTACKER_RECIPIENT : VICTIM;
        vm.prank(attacker);
        try vault.claim(recipient, attacker, _tokens(tokenMask), issued.nonce, issued.deadline, issued.signature) {
            revert("redirected signature accepted");
        } catch (bytes memory reason) {
            bytes4 selector = bytes4(reason);
            if (vault.paused()) {
                assertEq(selector, Pausable.EnforcedPause.selector);
            } else if (vm.getBlockTimestamp() > issued.deadline) {
                assertEq(selector, HandleVault.ExpiredClaim.selector);
            } else if (vault.usedNonces(recipient, issued.nonce)) {
                assertEq(selector, HandleVault.NonceAlreadyUsed.selector);
            } else {
                assertEq(selector, HandleVault.InvalidAuthorizer.selector);
            }
        }
    }

    /// @dev Replaying an issued signature with the correct destination is legitimate relaying
    /// while the nonce is unused; once used it must fail forever, even after new deposits.
    function replayIssuedSignature(uint256 pick, uint256 tokenMask) external {
        if (_issued.length == 0) return;
        uint256 index = pick % _issued.length;
        Issued memory issued = _issued[index];
        ++replayAttempts;
        vm.prank(attacker);
        try vault.claim(
            VICTIM, honestDest, _tokens(tokenMask), issued.nonce, issued.deadline, issued.signature
        ) returns (
            uint256 count
        ) {
            assertFalse(issued.used, "used nonce replayed");
            assertGt(count, 0);
            _issued[index].used = true;
            ++honestClaims;
            _syncStatuses();
        } catch (bytes memory reason) {
            bytes4 selector = bytes4(reason);
            if (vault.paused()) {
                assertEq(selector, Pausable.EnforcedPause.selector);
            } else if (vm.getBlockTimestamp() > issued.deadline) {
                assertEq(selector, HandleVault.ExpiredClaim.selector);
            } else if (issued.used) {
                assertEq(selector, HandleVault.NonceAlreadyUsed.selector);
            } else {
                assertTrue(
                    selector == HandleVault.NothingToClaim.selector
                        || selector == HandleVault.OutflowCapExceeded.selector,
                    "unexpected replay revert"
                );
            }
        }
    }

    function attackerDeposit(uint256 tokenSeed, uint96 rawAmount) external {
        if (vault.paused()) return;
        if (tokenSeed % 2 == 0) {
            uint256 amount = bound(rawAmount, 0.0001 ether, 1 ether);
            if (attacker.balance < amount) return;
            vm.prank(attacker);
            uint256 id = vault.depositNativeFor{value: amount}(VICTIM);
            attackerEthInEscrow += amount;
            _record(id, VICTIM, address(0), amount, attacker);
        } else {
            uint256 amount = bound(rawAmount, 1e6, 10_000e6);
            if (usdc.balanceOf(attacker) < amount) return;
            vm.startPrank(attacker);
            usdc.approve(address(vault), amount);
            uint256 id = vault.depositFor(VICTIM, address(usdc), amount);
            vm.stopPrank();
            attackerUsdcInEscrow += amount;
            _record(id, VICTIM, address(usdc), amount, attacker);
        }
    }

    function refundAny(uint256 idSeed) external {
        uint256 id = idSeed % (recorded + 2);
        (address depositSender,, address token, uint256 amount, uint256 createdAt, HandleVault.Status status) =
            vault.deposits(id);
        uint256 senderBefore = _balance(token, depositSender);
        vm.prank(attacker);
        try vault.refund(id) {
            assertEq(uint256(status), uint256(HandleVault.Status.Open), "refunded a non-open deposit");
            assertGe(vm.getBlockTimestamp(), createdAt + 180 days, "refunded before the delay");
            assertEq(_balance(token, depositSender) - senderBefore, amount, "refund did not pay the sender in full");
            if (depositSender == attacker) {
                if (token == address(0)) attackerEthInEscrow -= amount;
                else attackerUsdcInEscrow -= amount;
            }
            ++refundsPaid;
            _syncStatuses();
        } catch (bytes memory reason) {
            bytes4 selector = bytes4(reason);
            if (status != HandleVault.Status.Open) assertEq(selector, HandleVault.DepositNotOpen.selector);
            else assertEq(selector, HandleVault.RefundTooEarly.selector);
        }
    }

    function adminCalls(uint256 which, uint256 value) external {
        ++adminAttempts;
        bytes32 adminRole = bytes32(0);
        bytes32 authorizerRole = vault.AUTHORIZER_ROLE();
        bytes32 pauserRole = vault.PAUSER_ROLE();
        vm.startPrank(attacker);
        bytes memory denied =
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, adminRole);
        uint256 branch = which % 8;
        if (branch == 0) {
            vm.expectRevert(denied);
            vault.setFee(bound(value, 0, 100), attacker);
        } else if (branch == 1) {
            vm.expectRevert(denied);
            vault.setOutflowCap(address(usdc), value);
        } else if (branch == 2) {
            vm.expectRevert(denied);
            vault.setTokenConfig(address(usdc), false, 1);
        } else if (branch == 3) {
            vm.expectRevert(denied);
            vault.grantRole(authorizerRole, attacker);
        } else if (branch == 4) {
            vm.expectRevert(
                abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, pauserRole)
            );
            vault.pause();
        } else if (branch == 5) {
            vm.expectRevert(denied);
            vault.beginDefaultAdminTransfer(attacker);
        } else if (branch == 6) {
            vm.expectRevert(denied);
            vault.revokeRole(authorizerRole, authorizer);
        } else {
            (bool ok,) = address(vault).call{value: 1}("");
            assertFalse(ok, "vault accepted plain ether");
        }
        vm.stopPrank();
    }

    function withdrawFeesAsAttacker() external {
        uint256 ownerBefore = usdc.balanceOf(authorizer);
        uint256 accrued = vault.accruedFees(address(usdc));
        vm.prank(attacker);
        try vault.withdrawFees(address(usdc)) {
            assertGt(accrued, 0);
            assertEq(usdc.balanceOf(authorizer) - ownerBefore, accrued);
        } catch (bytes memory reason) {
            assertEq(bytes4(reason), HandleVault.NoFees.selector);
            assertEq(accrued, 0);
        }
    }

    function pauseToggleByPauser(bool shouldPause) external {
        if (vault.paused() == shouldPause) return;
        vm.prank(authorizer);
        if (shouldPause) vault.pause();
        else vault.unpause();
    }

    function advanceTime(uint32 raw, bool mature) external {
        uint256 delta = bound(raw, 0, 36 hours);
        if (mature) delta += 180 days;
        vm.warp(vm.getBlockTimestamp() + delta);
    }

    // ------------------------------------------------------------------ oracles

    function assertStatusesMonotonic() external {
        _syncStatuses();
    }

    function openSum(address token) external view returns (uint256 sum) {
        for (uint256 id = 1; id <= recorded; ++id) {
            if (ghostToken[id] != token) continue;
            (,,,,, HandleVault.Status status) = vault.deposits(id);
            if (status == HandleVault.Status.Open) sum += ghostAmount[id];
        }
    }

    function issuedCount() external view returns (uint256) {
        return _issued.length;
    }

    function issuedUsed(uint256 index) external view returns (uint256 nonce, bool used) {
        Issued memory issued = _issued[index];
        return (issued.nonce, issued.used);
    }

    function _syncStatuses() private {
        for (uint256 id = 1; id <= recorded; ++id) {
            (address depositSender, bytes32 recipient, address token, uint256 amount,, HandleVault.Status status) =
                vault.deposits(id);
            assertEq(depositSender, ghostSender[id], "sender changed");
            assertEq(recipient, ghostRecipient[id], "recipient changed");
            assertEq(token, ghostToken[id], "token changed");
            assertEq(amount, ghostAmount[id], "amount changed");
            HandleVault.Status previous = lastStatus[id];
            if (previous != HandleVault.Status.Open) assertEq(uint256(status), uint256(previous), "closed reopened");
            lastStatus[id] = status;
        }
    }

    function _record(uint256 id, bytes32 recipient, address token, uint256 amount, address depositSender) private {
        assertEq(id, recorded + 1, "deposit ids must be sequential");
        recorded = id;
        ghostRecipient[id] = recipient;
        ghostToken[id] = token;
        ghostAmount[id] = amount;
        ghostSender[id] = depositSender;
        lastStatus[id] = HandleVault.Status.Open;
    }

    function _tokens(uint256 mask) private view returns (address[] memory list) {
        uint256 m = bound(mask, 1, 3);
        list = new address[](m == 3 ? 2 : 1);
        if (m == 1) {
            list[0] = address(usdc);
        } else if (m == 2) {
            list[0] = address(0);
        } else {
            list[0] = address(usdc);
            list[1] = address(0);
        }
    }

    function _sign(uint256 key, bytes32 recipientId, address destination, uint256 nonce, uint256 deadline)
        private
        view
        returns (bytes memory)
    {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("HandleVault"),
                keccak256("1"),
                block.chainid,
                address(vault)
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Claim(bytes32 recipientId,address dest,uint256 nonce,uint256 deadline)"),
                recipientId,
                destination,
                nonce,
                deadline
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, keccak256(abi.encodePacked(hex"1901", domain, structHash)));
        return abi.encodePacked(r, s, v);
    }

    function _balance(address token, address account) private view returns (uint256) {
        return token == address(0) ? account.balance : usdc.balanceOf(account);
    }
}

/// forge-config: default.invariant.runs = 96
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract HandleVaultSecurityInvariantTest is StdInvariant, Test {
    AdversaryHandler private handler;
    HandleVault private vault;
    MockUSDC private usdc;
    address private authorizer;

    function setUp() public {
        vm.warp(30 days);
        vm.chainId(11_155_111);
        authorizer = vm.addr(0xA11CE);
        usdc = new MockUSDC(authorizer);
        vault = new HandleVault(authorizer, address(usdc), 0.0001 ether, 1e6, 10 ether, 100_000e6);
        vm.prank(authorizer);
        vault.setFee(100, authorizer);
        address honestSender = makeAddr("honest sender");
        handler = new AdversaryHandler(vault, usdc, honestSender);
        handler.honestDeposit(1, 500e6, false);
        handler.honestDeposit(0, 0.5 ether, false);
        handler.honestDeposit(1, 5e6, true);
        handler.attackerDeposit(1, 7e6);
        handler.honestClaim(3);
        // Seed every adversarial path once so afterInvariant's counters are never vacuous.
        handler.forgedSignature(12_345, 0, 3, true);
        handler.redirectIssuedSignature(0, 3, false);
        handler.replayIssuedSignature(0, 3);
        handler.adminCalls(0, 5);
        handler.advanceTime(0, true);
        handler.refundAny(3);
        bytes4[] memory selectors = new bytes4[](12);
        selectors[0] = AdversaryHandler.honestDeposit.selector;
        selectors[1] = AdversaryHandler.honestClaim.selector;
        selectors[2] = AdversaryHandler.forgedSignature.selector;
        selectors[3] = AdversaryHandler.redirectIssuedSignature.selector;
        selectors[4] = AdversaryHandler.replayIssuedSignature.selector;
        selectors[5] = AdversaryHandler.attackerDeposit.selector;
        selectors[6] = AdversaryHandler.refundAny.selector;
        selectors[7] = AdversaryHandler.adminCalls.selector;
        selectors[8] = AdversaryHandler.withdrawFeesAsAttacker.selector;
        selectors[9] = AdversaryHandler.pauseToggleByPauser.selector;
        selectors[10] = AdversaryHandler.advanceTime.selector;
        selectors[11] = AdversaryHandler.assertStatusesMonotonic.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    /// @notice The adversary can never end up holding more than it started with minus what it
    /// still has in escrow: nothing leaks to an unauthorised destination.
    function invariant_adversaryNeverProfits() public view {
        address attacker = handler.attacker();
        assertEq(usdc.balanceOf(attacker) + handler.attackerUsdcInEscrow(), handler.attackerUsdcStart());
        assertEq(attacker.balance + handler.attackerEthInEscrow(), handler.attackerEthStart());
    }

    function invariant_balanceEqualsOpenDepositsPlusAccruedFees() public view {
        assertEq(usdc.balanceOf(address(vault)), handler.openSum(address(usdc)) + vault.accruedFees(address(usdc)));
        assertEq(address(vault).balance, handler.openSum(address(0)) + vault.accruedFees(address(0)));
        assertEq(vault.totalOpen(address(usdc)), handler.openSum(address(usdc)));
        assertEq(vault.totalOpen(address(0)), handler.openSum(address(0)));
    }

    function invariant_usedNoncesStayUsedAndUnusedStayUnused() public view {
        uint256 count = handler.issuedCount();
        for (uint256 i; i < count; ++i) {
            (uint256 nonce, bool used) = handler.issuedUsed(i);
            assertEq(vault.usedNonces(keccak256("victim recipient"), nonce), used);
        }
    }

    function invariant_privilegesAndConfigurationUntouchedByAdversary() public view {
        address attacker = handler.attacker();
        assertTrue(vault.hasRole(bytes32(0), authorizer));
        assertTrue(vault.hasRole(vault.AUTHORIZER_ROLE(), authorizer));
        assertFalse(vault.hasRole(bytes32(0), attacker));
        assertFalse(vault.hasRole(vault.AUTHORIZER_ROLE(), attacker));
        assertFalse(vault.hasRole(vault.PAUSER_ROLE(), attacker));
        (address pending,) = vault.pendingDefaultAdmin();
        assertEq(pending, address(0));
        assertEq(vault.feeBps(), 100);
        assertEq(vault.feeRecipient(), authorizer);
        assertEq(vault.outflowCaps(address(usdc)), 100_000e6);
        assertEq(vault.outflowCaps(address(0)), 10 ether);
    }

    function invariant_rollingOutflowNeverExceedsCap() public view {
        assertLe(vault.rollingOutflow(address(usdc)), 100_000e6);
        assertLe(vault.rollingOutflow(address(0)), 10 ether);
    }

    function afterInvariant() public view {
        assertGt(handler.honestClaims(), 0);
        assertGt(handler.forgedAttempts(), 0);
        assertGt(handler.redirectAttempts(), 0);
        assertGt(handler.replayAttempts(), 0);
        assertGt(handler.adminAttempts(), 0);
        assertGt(handler.refundsPaid(), 0);
    }
}
