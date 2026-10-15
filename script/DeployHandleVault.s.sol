// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {HandleVault} from "../src/HandleVault.sol";
import {MockUSDC} from "../src/MockUSDC.sol";

/// @notice Deterministic configuration and local deployment rehearsal for the launch service.
/// @dev Does not read credentials, broadcast, or initialize contracts after their constructors.
/// The launch service deploys MockUSDC first and supplies its address to HandleVault.
contract DeployHandleVault is Script {
    uint256 public constant SEPOLIA_CHAIN_ID = 11_155_111;
    address public constant OWNER = 0xD58DCd4594087c2758717A59f44A5Ac09DB65105;
    uint256 public constant NATIVE_MINIMUM = 0.0001 ether;
    uint256 public constant USDC_MINIMUM = 1e6;
    uint256 public constant NATIVE_CAP = 10 ether;
    uint256 public constant USDC_CAP = 100_000e6;

    error WrongChain();

    function run() external returns (MockUSDC usdc, HandleVault vault) {
        if (block.chainid != SEPOLIA_CHAIN_ID) revert WrongChain();
        (usdc, vault) = deploy(OWNER);
        console2.log("Simulated MockUSDC (not a live deployment):", address(usdc));
        console2.log("Simulated HandleVault (not a live deployment):", address(vault));
    }

    /// @notice Explicit owner argument makes the deployment independent of caller/factory identity.
    function deploy(address owner) public returns (MockUSDC usdc, HandleVault vault) {
        usdc = new MockUSDC(owner);
        vault = new HandleVault(owner, address(usdc), NATIVE_MINIMUM, USDC_MINIMUM, NATIVE_CAP, USDC_CAP);
    }
}
