// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VaultFixture} from "./helpers/VaultFixture.sol";
import {HandleVault} from "../src/HandleVault.sol";

contract SignaturesTest is VaultFixture {
    uint256 private deadline;

    function setUp() public override {
        super.setUp();
        deadline = vm.getBlockTimestamp() + 1 days;
        _deposit(RECIPIENT, address(usdc), 5e6);
    }

    function test_digestMatchesIndependentReferenceAndTypehash() public view {
        assertEq(vault.CLAIM_TYPEHASH(), 0x1864f171689e98e3f2f87c8a15907d4fb03045729017118057305c1e0d842410);
        assertEq(
            vault.claimDigest(RECIPIENT, dest, 123, deadline),
            _referenceDigest(address(vault), block.chainid, RECIPIENT, dest, 123, deadline)
        );
        assertEq(
            vault.domainSeparator(),
            keccak256(
                abi.encode(
                    bytes32(0x8b73c3c69bb8fe3d512ecc4cf759cc79239f7b179b0ffacaa9a75d522b39400f),
                    keccak256("HandleVault"),
                    keccak256("1"),
                    block.chainid,
                    address(vault)
                )
            )
        );
        (bytes1 fields, string memory name, string memory version, uint256 chainId, address verifyingContract,,) =
            vault.eip712Domain();
        assertEq(fields, hex"0f");
        assertEq(name, "HandleVault");
        assertEq(version, "1");
        assertEq(chainId, 11_155_111);
        assertEq(verifyingContract, address(vault));
    }

    function testFuzz_digestMatchesReference(bytes32 recipientId, address destination, uint256 nonce, uint256 expiry)
        public
        view
    {
        assertEq(
            vault.claimDigest(recipientId, destination, nonce, expiry),
            _referenceDigest(address(vault), block.chainid, recipientId, destination, nonce, expiry)
        );
    }

    function test_nonAuthorizerCannotClaim() public {
        bytes memory sig = _signature(OTHER_KEY, RECIPIENT, dest, 0, deadline);
        vm.expectRevert(HandleVault.InvalidAuthorizer.selector);
        vault.claim(RECIPIENT, dest, _tokens(address(usdc)), 0, deadline, sig);
        assertFalse(vault.usedNonces(RECIPIENT, 0));
        assertEq(vault.totalOpen(address(usdc)), 5e6);
    }

    function test_replayRejectedEvenIfNewDepositsArrive() public {
        bytes memory sig = _signature(OWNER_KEY, RECIPIENT, dest, 0, deadline);
        vault.claim(RECIPIENT, dest, _tokens(address(usdc)), 0, deadline, sig);
        _deposit(RECIPIENT, address(usdc), 1e6);
        vm.expectRevert(HandleVault.NonceAlreadyUsed.selector);
        vault.claim(RECIPIENT, dest, _tokens(address(usdc)), 0, deadline, sig);
        assertEq(vault.totalOpen(address(usdc)), 1e6);
    }

    function test_wrongRecipientDestinationNonceOrDeadlineRejected() public {
        _deposit(SECOND_RECIPIENT, address(usdc), 1e6);
        bytes memory sig = _signature(OWNER_KEY, RECIPIENT, dest, 7, deadline);
        vm.expectRevert(HandleVault.InvalidAuthorizer.selector);
        vault.claim(SECOND_RECIPIENT, dest, _tokens(address(usdc)), 7, deadline, sig);
        vm.expectRevert(HandleVault.InvalidAuthorizer.selector);
        vault.claim(RECIPIENT, relayer, _tokens(address(usdc)), 7, deadline, sig);
        vm.expectRevert(HandleVault.InvalidAuthorizer.selector);
        vault.claim(RECIPIENT, dest, _tokens(address(usdc)), 8, deadline, sig);
        vm.expectRevert(HandleVault.InvalidAuthorizer.selector);
        vault.claim(RECIPIENT, dest, _tokens(address(usdc)), 7, deadline + 1, sig);
    }

    function test_expiredRejectedAndExactDeadlineAccepted() public {
        bytes memory sig = _signature(OWNER_KEY, RECIPIENT, dest, 0, deadline);
        vm.warp(deadline + 1);
        vm.expectRevert(HandleVault.ExpiredClaim.selector);
        vault.claim(RECIPIENT, dest, _tokens(address(usdc)), 0, deadline, sig);
        vm.warp(deadline);
        assertEq(vault.claim(RECIPIENT, dest, _tokens(address(usdc)), 0, deadline, sig), 1);
    }

    function test_chainIdSeparatesSignaturesAndDomainUpdates() public {
        bytes memory sig = _signature(OWNER_KEY, RECIPIENT, dest, 0, deadline);
        bytes32 domain = vault.domainSeparator();
        vm.chainId(1);
        assertNotEq(vault.domainSeparator(), domain);
        vm.expectRevert(HandleVault.InvalidAuthorizer.selector);
        vault.claim(RECIPIENT, dest, _tokens(address(usdc)), 0, deadline, sig);
        assertEq(
            vault.claimDigest(RECIPIENT, dest, 0, deadline),
            _referenceDigest(address(vault), 1, RECIPIENT, dest, 0, deadline)
        );
    }

    function test_otherVaultSignatureRejected() public {
        HandleVault otherVault = new HandleVault(owner, address(usdc), 1, 1, 10 ether, 100_000e6);
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(OWNER_KEY, _referenceDigest(address(otherVault), block.chainid, RECIPIENT, dest, 0, deadline));
        vm.expectRevert(HandleVault.InvalidAuthorizer.selector);
        vault.claim(RECIPIENT, dest, _tokens(address(usdc)), 0, deadline, abi.encodePacked(r, s, v));
    }

    function test_authorizerRotationRevokesOutstandingSignatures() public {
        bytes memory oldSig = _signature(OWNER_KEY, RECIPIENT, dest, 0, deadline);
        bytes32 role = vault.AUTHORIZER_ROLE();
        address nextSigner = vm.addr(OTHER_KEY);
        vm.startPrank(owner);
        vault.grantRole(role, nextSigner);
        vault.revokeRole(role, owner);
        vm.stopPrank();
        vm.expectRevert(HandleVault.InvalidAuthorizer.selector);
        vault.claim(RECIPIENT, dest, _tokens(address(usdc)), 0, deadline, oldSig);
        bytes memory newSig = _signature(OTHER_KEY, RECIPIENT, dest, 0, deadline);
        assertEq(vault.claim(RECIPIENT, dest, _tokens(address(usdc)), 0, deadline, newSig), 1);
        _deposit(RECIPIENT, address(usdc), 1e6);
        vm.expectRevert(HandleVault.NonceAlreadyUsed.selector);
        vault.claim(RECIPIENT, dest, _tokens(address(usdc)), 0, deadline, newSig);
    }

    function test_nonceScopedToRecipientButSharedByAuthorizers() public {
        _claim(RECIPIENT, dest, _tokens(address(usdc)), 0);
        _deposit(SECOND_RECIPIENT, address(usdc), 1e6);
        assertEq(_claim(SECOND_RECIPIENT, dest, _tokens(address(usdc)), 0), 1);
        bytes32 role = vault.AUTHORIZER_ROLE();
        address secondSigner = vm.addr(OTHER_KEY);
        vm.prank(owner);
        vault.grantRole(role, secondSigner);
        _deposit(RECIPIENT, address(usdc), 1e6);
        bytes memory sig = _signature(OTHER_KEY, RECIPIENT, dest, 0, deadline);
        vm.expectRevert(HandleVault.NonceAlreadyUsed.selector);
        vault.claim(RECIPIENT, dest, _tokens(address(usdc)), 0, deadline, sig);
    }

    function test_malformedMalleableAndInvalidVSignaturesRejected() public {
        vm.expectRevert(HandleVault.InvalidAuthorizer.selector);
        vault.claim(RECIPIENT, dest, _tokens(address(usdc)), 0, deadline, hex"1234");
        vm.expectRevert(HandleVault.InvalidAuthorizer.selector);
        vault.claim(RECIPIENT, dest, _tokens(address(usdc)), 0, deadline, new bytes(65));
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(OWNER_KEY, _referenceDigest(address(vault), block.chainid, RECIPIENT, dest, 0, deadline));
        uint256 curveOrder = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes memory highS = abi.encodePacked(r, bytes32(curveOrder - uint256(s)), v == 27 ? uint8(28) : uint8(27));
        vm.expectRevert(HandleVault.InvalidAuthorizer.selector);
        vault.claim(RECIPIENT, dest, _tokens(address(usdc)), 0, deadline, highS);
        vm.expectRevert(HandleVault.InvalidAuthorizer.selector);
        vault.claim(RECIPIENT, dest, _tokens(address(usdc)), 0, deadline, abi.encodePacked(r, s, uint8(0)));
    }

    function test_badDestinationAndTokenListsRejected() public {
        bytes memory sig = _signature(OWNER_KEY, RECIPIENT, dest, 0, deadline);
        vm.expectRevert(HandleVault.InvalidAddress.selector);
        vault.claim(RECIPIENT, address(0), _tokens(address(usdc)), 0, deadline, sig);
        vm.expectRevert(HandleVault.InvalidAddress.selector);
        vault.claim(RECIPIENT, address(vault), _tokens(address(usdc)), 0, deadline, sig);
        vm.expectRevert(HandleVault.InvalidTokenList.selector);
        vault.claim(RECIPIENT, dest, new address[](0), 0, deadline, sig);
        vm.expectRevert(HandleVault.InvalidTokenList.selector);
        vault.claim(RECIPIENT, dest, new address[](17), 0, deadline, sig);
        address[] memory duplicate = new address[](2);
        duplicate[0] = address(usdc);
        duplicate[1] = address(usdc);
        vm.expectRevert(abi.encodeWithSelector(HandleVault.DuplicateToken.selector, address(usdc)));
        vault.claim(RECIPIENT, dest, duplicate, 0, deadline, sig);
        assertFalse(vault.usedNonces(RECIPIENT, 0));
    }

    function test_emptyClaimDoesNotBurnNonce() public {
        bytes memory sig = _signature(OWNER_KEY, RECIPIENT, dest, 0, deadline);
        vm.expectRevert(HandleVault.NothingToClaim.selector);
        vault.claim(RECIPIENT, dest, _tokens(address(other)), 0, deadline, sig);
        assertFalse(vault.usedNonces(RECIPIENT, 0));
        assertEq(vault.claim(RECIPIENT, dest, _tokens(address(usdc)), 0, deadline, sig), 1);
    }

    function test_tokenSubsetIsDeliberatelyUnsigned() public {
        _deposit(RECIPIENT, address(other), 1);
        bytes memory sig = _signature(OWNER_KEY, RECIPIENT, dest, 0, deadline);
        vm.prank(relayer);
        assertEq(vault.claim(RECIPIENT, dest, _tokens(address(other)), 0, deadline, sig), 1);
        assertEq(usdc.balanceOf(dest), 0);
        assertEq(other.balanceOf(dest), 1);
        assertEq(vault.totalEscrowed(RECIPIENT, address(usdc)), 5e6);
    }
}
