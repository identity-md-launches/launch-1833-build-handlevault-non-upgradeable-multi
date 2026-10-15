// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HandleVault} from "../../src/HandleVault.sol";
import {MockUSDC} from "../../src/MockUSDC.sol";

abstract contract VaultFixture is Test {
    uint256 internal constant OWNER_KEY = 0xA11CE;
    uint256 internal constant OTHER_KEY = 0xB0B;
    bytes32 internal constant RECIPIENT = keccak256("test recipient with salt");
    bytes32 internal constant SECOND_RECIPIENT = keccak256("second test recipient with salt");
    address internal owner;
    address internal sender;
    address internal dest;
    address internal relayer;
    address internal treasury;
    MockUSDC internal usdc;
    MockUSDC internal other;
    HandleVault internal vault;

    function setUp() public virtual {
        vm.chainId(11_155_111);
        vm.warp(10 days);
        owner = vm.addr(OWNER_KEY);
        sender = makeAddr("sender");
        dest = makeAddr("destination");
        relayer = makeAddr("relayer");
        treasury = makeAddr("fee recipient");
        usdc = new MockUSDC(owner);
        other = new MockUSDC(owner);
        vault = new HandleVault(owner, address(usdc), 0.0001 ether, 1e6, 10 ether, 100_000e6);
        vm.startPrank(owner);
        vault.setTokenConfig(address(other), true, 1);
        vault.setOutflowCap(address(other), 100_000e6);
        usdc.mint(sender, 10_000_000e6);
        other.mint(sender, 10_000_000e6);
        vm.stopPrank();
        vm.deal(sender, 1000 ether);
    }

    function _tokens(address token) internal pure returns (address[] memory list) {
        list = new address[](1);
        list[0] = token;
    }

    function _deposit(bytes32 recipientId, address token, uint256 amount) internal returns (uint256 id) {
        vm.startPrank(sender);
        if (token == address(0)) {
            id = vault.depositNativeFor{value: amount}(recipientId);
        } else {
            MockUSDC(token).approve(address(vault), amount);
            id = vault.depositFor(recipientId, token, amount);
        }
        vm.stopPrank();
    }

    // Independent reference implementation of the EIP-712 encoding. The signing tests do not
    // trust vault.claimDigest(), CLAIM_TYPEHASH(), or domainSeparator() to generate signatures.
    function _referenceDigest(
        address verifyingContract,
        uint256 chainId,
        bytes32 recipientId,
        address destination,
        uint256 nonce,
        uint256 deadline
    ) internal pure returns (bytes32) {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("HandleVault"),
                keccak256("1"),
                chainId,
                verifyingContract
            )
        );
        bytes32 claimHash = keccak256(
            abi.encode(
                keccak256("Claim(bytes32 recipientId,address dest,uint256 nonce,uint256 deadline)"),
                recipientId,
                destination,
                nonce,
                deadline
            )
        );
        return keccak256(abi.encodePacked(hex"1901", domain, claimHash));
    }

    function _signature(uint256 key, bytes32 recipientId, address destination, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest = _referenceDigest(address(vault), block.chainid, recipientId, destination, nonce, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function _claim(bytes32 recipientId, address destination, address[] memory tokens, uint256 nonce)
        internal
        returns (uint256 count)
    {
        uint256 deadline = vm.getBlockTimestamp() + 1 days;
        bytes memory signature = _signature(OWNER_KEY, recipientId, destination, nonce, deadline);
        vm.prank(relayer);
        return vault.claim(recipientId, destination, tokens, nonce, deadline, signature);
    }

    function _status(uint256 id) internal view returns (HandleVault.Status status) {
        (,,,,, status) = vault.deposits(id);
    }

    function _assertAccounting(address token) internal view {
        uint256 balance = token == address(0) ? address(vault).balance : MockUSDC(token).balanceOf(address(vault));
        assertEq(balance, vault.totalOpen(token) + vault.accruedFees(token));
    }
}
