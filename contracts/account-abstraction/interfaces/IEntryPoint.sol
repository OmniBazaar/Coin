// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {UserOperation} from "./IAccount.sol";

/**
 * @title IEntryPoint
 * @author OmniCoin Development Team
 * @notice ERC-4337 EntryPoint interface for processing UserOperations
 * @dev The EntryPoint is the singleton contract that all accounts and
 *      paymasters interact with. Bundlers submit UserOperations here.
 */
interface IEntryPoint {
    /// @notice Emitted after each successful UserOperation execution
    /// @param userOpHash The hash identifying this UserOperation
    /// @param sender The smart account that executed the operation
    /// @param paymaster The paymaster that sponsored gas (address(0) if none)
    /// @param nonce The nonce used
    /// @param success Whether the execution call succeeded
    /// @param actualGasCost Actual gas cost charged
    /// @param actualGasUsed Actual gas consumed
    event UserOperationEvent(
        bytes32 indexed userOpHash,
        address indexed sender,
        address indexed paymaster,
        uint256 nonce,
        bool success,
        uint256 actualGasCost,
        uint256 actualGasUsed
    );

    /// @notice Emitted when a new smart account is deployed via initCode
    /// @param userOpHash Hash of the deploying UserOperation
    /// @param sender Address of the newly deployed account
    /// @param factory Factory contract that created the account
    /// @param paymaster Paymaster that sponsored the deployment
    event AccountDeployed(
        bytes32 indexed userOpHash,
        address indexed sender,
        address indexed factory,
        address paymaster
    );

    /// @notice Emitted when a UserOperation reverts during execution
    /// @param userOpHash Hash of the failed UserOperation
    /// @param sender The account that attempted execution
    /// @param nonce Nonce of the failed operation
    /// @param revertReason ABI-encoded revert reason
    event UserOperationRevertReason(
        bytes32 indexed userOpHash,
        address indexed sender,
        uint256 nonce,
        bytes revertReason
    );

    /**
     * @notice Execute a batch of UserOperations
     * @dev Called by bundlers. Validates and executes each operation.
     * @param ops Array of UserOperations to execute
     * @param beneficiary Address to receive gas refunds
     */
    function handleOps(
        UserOperation[] calldata ops,
        address payable beneficiary
    ) external;

    /**
     * @notice Deposit funds for an account to pay for gas
     * @param account The account to fund
     */
    function depositTo(address account) external payable;

    /**
     * @notice Get the deposit balance for an account
     * @param account The account to query
     * @return The deposited balance
     */
    function balanceOf(address account) external view returns (uint256);

    /**
     * @notice Get the current nonce for an account
     * @param sender The account address
     * @param key The nonce key (supports multiple nonce sequences)
     * @return nonce The current nonce
     */
    function getNonce(address sender, uint192 key) external view returns (uint256 nonce);
}
