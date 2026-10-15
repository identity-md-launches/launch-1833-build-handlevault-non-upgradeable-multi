// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Design hook only, deliberately NOT implemented by HandleVault v1.
/// @dev A future separately deployed version must bind adapter, destination chain, final recipient,
/// and bridge data in a NEW EIP-712 type/domain. A v1 Claim must never authorize arbitrary bridge calls.
interface IFutureHandleVault {
    function claimTo(
        bytes32 recipientId,
        address adapter,
        uint256 destinationChainId,
        bytes32 destinationRecipient,
        address[] calldata tokens,
        uint256 nonce,
        uint256 deadline,
        bytes calldata bridgeData,
        bytes calldata signature
    ) external;
}
