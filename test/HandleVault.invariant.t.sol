// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {HandleVault} from "../src/HandleVault.sol";
import {MockUSDC} from "../src/MockUSDC.sol";

/// @dev Independent, deliberately simple O(n) model. The implementation uses linked queues
/// and binary-searched cumulative history; this oracle scans immutable records and claim logs.
contract VaultHandler is Test {
    uint256 private constant SIGNER_KEY = 0xA11CE;
    HandleVault public immutable vault;
    address public immutable owner;
    address[3] public tokens;
    address[3] public senders;
    address[3] public destinations;
    bytes32[3] public recipients;

    struct ModelDeposit {
        address sender;
        bytes32 recipientId;
        address token;
        uint256 amount;
        uint256 createdAt;
        HandleVault.Status status;
    }

    struct ModelOutflow {
        address token;
        uint256 timestamp;
        uint256 amount;
    }

    ModelDeposit[] public records;
    ModelOutflow[] private _claims;
    mapping(address => uint256) public modelFees;
    mapping(address => uint256) public deposited;
    mapping(address => uint256) public refunded;
    mapping(address => uint256) public paid;
    mapping(address => uint256) public feesWithdrawn;
    mapping(address => uint256) public caps;
    mapping(address => bool) public allowed;
    mapping(bytes32 => uint256) public nextNonce;
    uint256 public modelFeeBps;
    address public modelFeeRecipient;
    bool public modelPaused;
    uint256 public successfulDeposits;
    uint256 public successfulClaims;
    uint256 public successfulRefunds;
    uint256 public successfulWithdrawals;

    constructor(HandleVault vault_, MockUSDC first, MockUSDC second) {
        vault = vault_;
        owner = vm.addr(SIGNER_KEY);
        tokens = [address(0), address(first), address(second)];
        for (uint256 i; i < 3; ++i) {
            senders[i] = address(uint160(uint256(keccak256(abi.encode("invariant sender", i)))));
            destinations[i] = address(uint160(uint256(keccak256(abi.encode("invariant destination", i)))));
            recipients[i] = keccak256(abi.encode("invariant recipient", i));
            allowed[tokens[i]] = true;
            caps[tokens[i]] = i == 0 ? 10 ether : 100_000e6;
        }
        modelFeeRecipient = owner;
    }

    function deposit(uint256 recipientSeed, uint256 tokenSeed, uint256 senderSeed, uint96 rawAmount) external {
        address token = tokens[tokenSeed % 3];
        if (modelPaused || !allowed[token] || caps[token] == 0) return;
        uint256 amount = bound(rawAmount, 1, caps[token]);
        address sender = senders[senderSeed % 3];
        bytes32 recipientId = recipients[recipientSeed % 3];
        uint256 id;
        if (token == address(0)) {
            vm.deal(sender, sender.balance + amount);
            vm.prank(sender);
            id = vault.depositNativeFor{value: amount}(recipientId);
        } else {
            vm.prank(owner);
            MockUSDC(token).mint(sender, amount);
            vm.startPrank(sender);
            MockUSDC(token).approve(address(vault), amount);
            id = vault.depositFor(recipientId, token, amount);
            vm.stopPrank();
        }
        records.push(ModelDeposit(sender, recipientId, token, amount, vm.getBlockTimestamp(), HandleVault.Status.Open));
        assertEq(id, records.length);
        deposited[token] += amount;
        ++successfulDeposits;
    }

    function claim(uint256 recipientSeed, uint256 tokenMask, uint256 destinationSeed) external {
        if (modelPaused) return;
        bytes32 recipientId = recipients[recipientSeed % 3];
        address destination = destinations[destinationSeed % 3];
        uint256 mask = bound(tokenMask, 1, 7);
        uint256 tokenCount;
        for (uint256 i; i < 3; ++i) {
            if (mask & (1 << i) != 0) ++tokenCount;
        }
        address[] memory selected = new address[](tokenCount);
        uint256 selectedIndex;
        uint256 expectedCount;
        uint256 visited;
        uint256[] memory payouts = new uint256[](3);
        uint256[] memory beforeBalances = new uint256[](3);
        for (uint256 i; i < 3; ++i) {
            address token = tokens[i];
            beforeBalances[i] = _balance(token, destination);
            if (mask & (1 << i) == 0) continue;
            selected[selectedIndex++] = token;
            uint256 spent = modelOutflow(token);
            uint256 available = spent < caps[token] ? caps[token] - spent : 0;
            uint256 gross;
            // The recipient share stays at 100% in this model, so the shared window alone binds.
            for (uint256 j; j < records.length && expectedCount < 64 && visited < 256; ++j) {
                ModelDeposit storage record = records[j];
                if (
                    record.status != HandleVault.Status.Open || record.recipientId != recipientId
                        || record.token != token
                ) continue;
                ++visited;
                // A deposit that does not fit is skipped, not a stop: later ones are still examined.
                if (record.amount > available - gross) continue;
                uint256 fee = record.amount * modelFeeBps / 10_000;
                gross += record.amount;
                payouts[i] += record.amount - fee;
                modelFees[token] += fee;
                record.status = HandleVault.Status.Claimed;
                ++expectedCount;
            }
            if (gross != 0) {
                _claims.push(ModelOutflow(token, vm.getBlockTimestamp(), gross));
                paid[token] += payouts[i];
            }
        }
        if (expectedCount == 0) return;
        uint256 nonce = nextNonce[recipientId]++;
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
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
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(SIGNER_KEY, keccak256(abi.encodePacked(hex"1901", domain, structHash)));
        assertEq(
            vault.claim(recipientId, destination, selected, nonce, deadline, abi.encodePacked(r, s, v)), expectedCount
        );
        assertTrue(vault.usedNonces(recipientId, nonce));
        for (uint256 i; i < 3; ++i) {
            assertEq(_balance(tokens[i], destination) - beforeBalances[i], payouts[i]);
        }
        ++successfulClaims;
    }

    function refund(uint256 idSeed) external {
        if (records.length == 0) return;
        uint256 index = idSeed % records.length;
        ModelDeposit storage record = records[index];
        if (record.status != HandleVault.Status.Open || vm.getBlockTimestamp() < record.createdAt + 180 days) return;
        uint256 beforeBalance = _balance(record.token, record.sender);
        vault.refund(index + 1);
        record.status = HandleVault.Status.Refunded;
        refunded[record.token] += record.amount;
        assertEq(_balance(record.token, record.sender) - beforeBalance, record.amount);
        ++successfulRefunds;
    }

    function withdrawFees(uint256 tokenSeed) external {
        address token = tokens[tokenSeed % 3];
        if (modelFees[token] == 0) return;
        uint256 beforeBalance = _balance(token, modelFeeRecipient);
        uint256 amount = modelFees[token];
        vault.withdrawFees(token);
        feesWithdrawn[token] += amount;
        modelFees[token] = 0;
        assertEq(_balance(token, modelFeeRecipient) - beforeBalance, amount);
        ++successfulWithdrawals;
    }

    function configureFee(uint16 feeSeed, uint256 recipientSeed) external {
        modelFeeBps = bound(feeSeed, 0, 100);
        modelFeeRecipient = destinations[recipientSeed % 3];
        vm.prank(owner);
        vault.setFee(modelFeeBps, modelFeeRecipient);
    }

    function configureCap(uint256 tokenSeed, uint96 rawCap) external {
        address token = tokens[tokenSeed % 3];
        caps[token] = bound(rawCap, 0, token == address(0) ? 10 ether : 100_000e6);
        vm.prank(owner);
        vault.setOutflowCap(token, caps[token]);
    }

    function toggleAllowed(uint256 tokenSeed) external {
        address token = tokens[tokenSeed % 3];
        allowed[token] = !allowed[token];
        vm.prank(owner);
        vault.setTokenConfig(token, allowed[token], 1);
    }

    function togglePause() external {
        modelPaused = !modelPaused;
        vm.prank(owner);
        if (modelPaused) vault.pause();
        else vault.unpause();
    }

    function advanceTime(uint32 secondsSeed, bool mature) external {
        uint256 delta = bound(secondsSeed, 0, 2 days);
        if (mature) delta += 180 days;
        vm.warp(vm.getBlockTimestamp() + delta);
    }

    function modelOutflow(address token) public view returns (uint256 total) {
        for (uint256 i; i < _claims.length; ++i) {
            ModelOutflow memory entry = _claims[i];
            if (entry.token == token && entry.timestamp + 24 hours > vm.getBlockTimestamp()) total += entry.amount;
        }
    }

    function assertModel() external view {
        uint256[] memory sums = new uint256[](3);
        for (uint256 i; i < records.length; ++i) {
            ModelDeposit memory record = records[i];
            (
                address sender,
                bytes32 recipientId,
                address token,
                uint256 amount,
                uint256 createdAt,
                HandleVault.Status status
            ) = vault.deposits(i + 1);
            assertEq(sender, record.sender);
            assertEq(recipientId, record.recipientId);
            assertEq(token, record.token);
            assertEq(amount, record.amount);
            assertEq(createdAt, record.createdAt);
            assertEq(uint256(status), uint256(record.status));
            for (uint256 t; t < 3; ++t) {
                if (record.token == tokens[t] && record.status == HandleVault.Status.Open) sums[t] += record.amount;
            }
        }
        for (uint256 t; t < 3; ++t) {
            address token = tokens[t];
            assertEq(vault.totalOpen(token), sums[t]);
            assertEq(vault.accruedFees(token), modelFees[token]);
            assertEq(_balance(token, address(vault)), sums[t] + modelFees[token]);
            assertEq(
                _balance(token, address(vault)), deposited[token] - refunded[token] - paid[token] - feesWithdrawn[token]
            );
            assertEq(vault.rollingOutflow(token), modelOutflow(token));
            uint256 spent = modelOutflow(token);
            assertEq(vault.remainingOutflow(token), spent < caps[token] ? caps[token] - spent : 0);
        }
        assertEq(vault.paused(), modelPaused);
        assertEq(vault.feeBps(), modelFeeBps);
    }

    function assertQueues() external view {
        for (uint256 r; r < 3; ++r) {
            uint256[] memory expected = new uint256[](records.length);
            uint256 count;
            for (uint256 i; i < records.length; ++i) {
                if (records[i].recipientId == recipients[r] && records[i].status == HandleVault.Status.Open) {
                    expected[count++] = i + 1;
                }
            }
            assertEq(vault.openDepositCount(recipients[r]), count);
            uint256 cursor;
            uint256 seen;
            do {
                (uint256[] memory ids, uint256 next) = vault.getOpenDepositIds(recipients[r], cursor, 3);
                for (uint256 i; i < ids.length; ++i) {
                    assertLt(seen, count);
                    assertEq(ids[i], expected[seen++]);
                }
                cursor = next;
            } while (cursor != 0);
            assertEq(seen, count);
            for (uint256 t; t < 3; ++t) {
                uint256 sum;
                uint256 first;
                for (uint256 i; i < count; ++i) {
                    ModelDeposit memory d = records[expected[i] - 1];
                    if (d.token == tokens[t]) {
                        sum += d.amount;
                        if (first == 0) first = expected[i];
                    }
                }
                assertEq(vault.totalEscrowed(recipients[r], tokens[t]), sum);
                assertEq(vault.firstOpenDeposit(recipients[r], tokens[t]), first);
            }
        }
    }

    function _balance(address token, address account) private view returns (uint256) {
        return token == address(0) ? account.balance : MockUSDC(token).balanceOf(account);
    }
}

contract HandleVaultInvariantTest is StdInvariant, Test {
    VaultHandler private handler;

    function setUp() public {
        vm.warp(10 days);
        vm.chainId(11_155_111);
        address owner = vm.addr(0xA11CE);
        MockUSDC first = new MockUSDC(owner);
        MockUSDC second = new MockUSDC(owner);
        HandleVault vault = new HandleVault(owner, address(first), 1, 1, 10 ether, 100_000e6);
        vm.startPrank(owner);
        vault.setTokenConfig(address(second), true, 1);
        vault.setOutflowCap(address(second), 100_000e6);
        vm.stopPrank();
        handler = new VaultHandler(vault, first, second);
        // Seed each flow so conservation assertions never pass solely because no deposits happened.
        handler.configureFee(100, 0);
        handler.deposit(0, 0, 0, 1 ether);
        handler.deposit(0, 1, 1, 10e6);
        handler.deposit(0, 2, 2, 10e6);
        handler.claim(0, 7, 0);
        handler.withdrawFees(0);
        handler.deposit(1, 0, 1, 1 ether);
        handler.deposit(1, 1, 1, 1e6);
        handler.deposit(1, 2, 1, 1e6);
        handler.advanceTime(0, true);
        handler.refund(3);
        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = VaultHandler.deposit.selector;
        selectors[1] = VaultHandler.claim.selector;
        selectors[2] = VaultHandler.refund.selector;
        selectors[3] = VaultHandler.withdrawFees.selector;
        selectors[4] = VaultHandler.configureFee.selector;
        selectors[5] = VaultHandler.configureCap.selector;
        selectors[6] = VaultHandler.toggleAllowed.selector;
        selectors[7] = VaultHandler.togglePause.selector;
        selectors[8] = VaultHandler.advanceTime.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_balancesEqualOpenDepositsPlusAccruedFeesAndModel() public view {
        handler.assertModel();
    }

    function invariant_openPaginationAndPerRecipientTotalsMatchModel() public view {
        handler.assertQueues();
    }

    function afterInvariant() public view {
        assertGt(handler.successfulDeposits(), 0);
        assertGt(handler.successfulClaims(), 0);
        assertGt(handler.successfulRefunds(), 0);
        assertGt(handler.successfulWithdrawals(), 0);
    }
}
