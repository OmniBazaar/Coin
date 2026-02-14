// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/**
 * @notice ERC-4337 UserOperation struct (v0.6 format)
 * @dev Used across all account abstraction contracts for consistency
 */
struct UserOperation {
    /// @notice Smart account address executing this operation
    address sender;
    /// @notice Anti-replay nonce (must match EntryPoint nonce for sender)
    uint256 nonce;
    /// @notice Factory address + calldata to deploy the account (empty if account exists)
    bytes initCode;
    /// @notice Calldata to execute on the account
    bytes callData;
    /// @notice Gas limit for the main execution call
    uint256 callGasLimit;
    /// @notice Gas limit for the validation phase
    uint256 verificationGasLimit;
    /// @notice Extra gas to compensate for pre-execution overhead
    uint256 preVerificationGas;
    /// @notice Maximum fee per gas (EIP-1559)
    uint256 maxFeePerGas;
    /// @notice Maximum priority fee per gas (EIP-1559)
    uint256 maxPriorityFeePerGas;
    /// @notice Paymaster address + validation data + context (empty if self-paying)
    bytes paymasterAndData;
    /// @notice Signature over the userOpHash, validated by the account
    bytes signature;
}

/**
 * @title IAccount
 * @author OmniCoin Development Team
 * @notice ERC-4337 account interface for smart wallet validation
 * @dev Accounts must implement validateUserOp to participate in the
 *      Account Abstraction protocol. The EntryPoint calls this to verify
 *      that the account authorizes the UserOperation.
 */
interface IAccount {
    /**
     * @notice Validate a UserOperation and pay prefund if needed
     * @dev Must validate the signature and nonce. Must pay the EntryPoint
     *      (caller) the missing funds for the operation. The signature is
     *      validated using the account's own scheme (ECDSA, multisig, passkey, etc.).
     * @param userOp The UserOperation to validate
     * @param userOpHash Hash of the UserOperation (includes EntryPoint address and chainId)
     * @param missingAccountFunds Amount the account must pay to the EntryPoint
     * @return validationData Packed validation data:
     *         - 0 = valid signature
     *         - 1 = invalid signature
     *         - Upper 160 bits: aggregator address (0 for no aggregator)
     *         - Bits 160-207: validUntil (6 bytes, 0 = infinite)
     *         - Bits 208-255: validAfter (6 bytes, 0 = always valid)
     */
    function validateUserOp(
        UserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 missingAccountFunds
    ) external returns (uint256 validationData);
}
