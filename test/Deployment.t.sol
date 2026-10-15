// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HandleVault} from "../src/HandleVault.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {DeployHandleVault} from "../script/DeployHandleVault.s.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {
    IAccessControlDefaultAdminRules
} from "@openzeppelin/contracts/access/extensions/IAccessControlDefaultAdminRules.sol";

contract DeploymentTest is Test {
    address private constant LAUNCH_OWNER = 0xD58DCd4594087c2758717A59f44A5Ac09DB65105;

    function test_deploymentConfigurationUsesExplicitOwnerNotCaller() public {
        DeployHandleVault deployment = new DeployHandleVault();
        vm.prank(makeAddr("unrelated factory"));
        (MockUSDC usdc, HandleVault vault) = deployment.deploy(LAUNCH_OWNER);
        assertEq(deployment.OWNER(), LAUNCH_OWNER);
        assertEq(usdc.owner(), LAUNCH_OWNER);
        assertEq(vault.owner(), LAUNCH_OWNER);
        assertTrue(vault.hasRole(vault.AUTHORIZER_ROLE(), LAUNCH_OWNER));
        assertTrue(vault.hasRole(vault.PAUSER_ROLE(), LAUNCH_OWNER));
        assertFalse(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), address(deployment)));
        assertFalse(vault.hasRole(vault.AUTHORIZER_ROLE(), address(deployment)));
        assertEq(vault.feeRecipient(), LAUNCH_OWNER);
        assertEq(vault.feeBps(), 0);
        (bool tokenAllowed, uint256 tokenMinimum) = vault.tokenConfigs(address(usdc));
        (bool nativeAllowed, uint256 nativeMinimum) = vault.tokenConfigs(address(0));
        assertTrue(tokenAllowed);
        assertTrue(nativeAllowed);
        assertEq(tokenMinimum, 1e6);
        assertEq(nativeMinimum, 0.0001 ether);
        assertEq(vault.outflowCaps(address(usdc)), 100_000e6);
        assertEq(vault.outflowCaps(address(0)), 10 ether);
        assertEq(usdc.totalSupply(), 0);
        assertEq(usdc.decimals(), 6);
        assertEq(usdc.name(), "Mock USDC");
        assertEq(usdc.symbol(), "mUSDC");
        _assertRuntime(address(vault));
        _assertRuntime(address(usdc));
    }

    function test_scriptRunIsSepoliaOnlyAndNeedsNoEnvironment() public {
        DeployHandleVault deployment = new DeployHandleVault();
        vm.chainId(1);
        vm.expectRevert(DeployHandleVault.WrongChain.selector);
        deployment.run();
        vm.chainId(11_155_111);
        (MockUSDC token, HandleVault vault) = deployment.run();
        assertEq(vault.owner(), LAUNCH_OWNER);
        assertEq(token.owner(), LAUNCH_OWNER);
    }

    function test_constructorDoesNotCallUndeployedToken() public {
        address predictedToken = makeAddr("future MockUSDC address");
        assertEq(predictedToken.code.length, 0);
        HandleVault vault = new HandleVault(LAUNCH_OWNER, predictedToken, 1, 1, 10 ether, 100_000e6);
        assertEq(vault.owner(), LAUNCH_OWNER);
        assertEq(vault.outflowCaps(predictedToken), 100_000e6);
        vm.expectRevert(abi.encodeWithSelector(HandleVault.InvalidToken.selector, predictedToken));
        vault.depositFor(keccak256("test only"), predictedToken, 1);
    }

    function test_constructorRejectsInvalidConfiguration() public {
        address token = makeAddr("test token");
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControlDefaultAdminRules.AccessControlInvalidDefaultAdmin.selector, address(0)
            )
        );
        new HandleVault(address(0), token, 1, 1, 1, 1);
        vm.expectRevert(HandleVault.InvalidAddress.selector);
        new HandleVault(LAUNCH_OWNER, address(0), 1, 1, 1, 1);
        vm.expectRevert(HandleVault.InvalidMinimum.selector);
        new HandleVault(LAUNCH_OWNER, token, 0, 1, 1, 1);
        vm.expectRevert(HandleVault.InvalidMinimum.selector);
        new HandleVault(LAUNCH_OWNER, token, 1, 0, 1, 1);
        vm.expectRevert(HandleVault.InvalidMinimum.selector);
        new HandleVault(LAUNCH_OWNER, token, 2, 1, 1, 1);
        vm.expectRevert(HandleVault.InvalidMinimum.selector);
        new HandleVault(LAUNCH_OWNER, token, 1, 2, 1, 1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new MockUSDC(address(0));
    }

    function test_mockMintRestrictedAndOwnershipTwoStep() public {
        MockUSDC token = new MockUSDC(LAUNCH_OWNER);
        address newOwner = makeAddr("new mint owner");
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        token.mint(newOwner, 1e6);
        vm.startPrank(LAUNCH_OWNER);
        token.mint(newOwner, 1e6);
        token.transferOwnership(newOwner);
        vm.stopPrank();
        assertEq(token.owner(), LAUNCH_OWNER);
        assertEq(token.pendingOwner(), newOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        token.acceptOwnership();
        vm.prank(newOwner);
        token.acceptOwnership();
        vm.prank(newOwner);
        token.mint(newOwner, 2e6);
        assertEq(token.balanceOf(newOwner), 3e6);
        assertEq(token.totalSupply(), 3e6);
        vm.prank(LAUNCH_OWNER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, LAUNCH_OWNER));
        token.mint(LAUNCH_OWNER, 1);
    }

    function _assertRuntime(address application) private view {
        bytes memory code = application.code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden runtime opcode");
        }
    }
}
