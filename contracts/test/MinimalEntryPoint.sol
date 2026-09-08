// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title MinimalEntryPoint
 * @author OmniCoin Development Team
 * @notice Minimal implementation of ERC-4337 EntryPoint for testing Account Abstraction
 * @dev This is a simplified version that implements only the required functions
 *      for basic ERC-4337 UserOperation handling. Used for testing OmniWallet integration.
 */
contract MinimalEntryPoint {
    
    // Type declarations
    struct UserOperation {
        address sender;
        uint256 nonce;
        bytes initCode;
        bytes callData;
        uint256 callGasLimit;
        uint256 verificationGasLimit;
        uint256 preVerificationGas;
        uint256 maxFeePerGas;
        uint256 maxPriorityFeePerGas;
        bytes paymasterAndData;
        bytes signature;
    }
    
    struct UserOpInfo {
        address sender;
        uint256 nonce;
        uint256 prefund;
    }

    // State variables
    /// @notice Mapping of account addresses to their deposited ETH amounts
    mapping(address => uint256) public deposits;
    
    /// @notice Mapping of account addresses to their current nonces
    mapping(address => uint256) public nonces;

    // Events
    /// @notice Emitted after each successful UserOperation execution
    /// @param userOpHash The hash of the executed UserOperation
    /// @param sender The sender account that executed the operation
    /// @param paymaster The paymaster that sponsored the operation (address(0) if none)
    /// @param nonce The nonce used for this operation
    /// @param success Whether the operation executed successfully
    /// @param actualGasCost The actual gas cost incurred
    /// @param actualGasUsed The actual gas used for execution
    event UserOperationEvent(
        bytes32 indexed userOpHash,
        address indexed sender,
        address indexed paymaster,
        uint256 nonce,
        bool success,
        uint256 actualGasCost,
        uint256 actualGasUsed
    );
    
    /// @notice Emitted when a new account is deployed via UserOperation
    /// @param userOpHash The hash of the UserOperation that deployed the account
    /// @param sender The address of the deployed account
    /// @param factory The factory contract that deployed the account
    /// @param paymaster The paymaster that sponsored the deployment
    event AccountDeployed(
        bytes32 indexed userOpHash,
        address indexed sender,
        address indexed factory,
        address paymaster
    );

    // Custom errors
    error InvalidNonce(uint256 expected, uint256 provided);
    error InsufficientDeposit(uint256 required, uint256 available);
    error UnusedParameter();
    
    /**
     * @notice Execute a batch of UserOperations
     * @param ops Array of UserOperations to execute
     * @param beneficiary Address to receive gas refunds
     */
    function handleOps(
        UserOperation[] calldata ops,
        address payable beneficiary
    ) external {
        for (uint256 i = 0; i < ops.length; ++i) {
            _handleOp(ops[i], beneficiary);
        }
    }
    
    /**
     * @notice Deposit funds for an account
     * @param account The account to deposit for
     */
    function depositTo(address account) external payable {
        deposits[account] += msg.value;
    }
    
    /**
     * @notice Get deposit info for an account
     * @param account The account to query
     * @return deposit The current deposit amount
     * @return staked Whether the account is staked (always false in minimal impl)
     * @return stake The stake amount (always 0 in minimal impl)
     * @return unstakeDelaySec The unstake delay (always 0 in minimal impl)
     * @return withdrawTime The withdraw time (always 0 in minimal impl)
     */
    function getDepositInfo(address account) external view returns (
        uint112 deposit,
        bool staked,
        uint112 stake,
        uint32 unstakeDelaySec,
        uint48 withdrawTime
    ) {
        return (uint112(deposits[account]), false, 0, 0, 0);
    }
    
    /**
     * @notice Withdraw deposit
     * @param withdrawAddress Address to withdraw to
     * @param withdrawAmount Amount to withdraw
     */
    function withdrawTo(address payable withdrawAddress, uint256 withdrawAmount) external {
        if (deposits[msg.sender] < withdrawAmount) {
            revert InsufficientDeposit(withdrawAmount, deposits[msg.sender]);
        }
        deposits[msg.sender] -= withdrawAmount;
        withdrawAddress.transfer(withdrawAmount);
    }
    
    /**
     * @notice Add stake (no-op in minimal implementation)
     * @param unstakeDelaySec The unstake delay in seconds (unused in minimal implementation)
     */
    function addStake(uint32 unstakeDelaySec) external payable {
        // Note: unstakeDelaySec parameter kept for interface compatibility
        if (unstakeDelaySec == 0) {
            // This satisfies the unused variable warning while maintaining interface
        }
        // No-op in minimal implementation
    }
    
    /**
     * @notice Unlock stake (no-op in minimal implementation)
     */
    function unlockStake() external {
        // No-op in minimal implementation
    }
    
    /**
     * @notice Withdraw stake (no-op in minimal implementation)
     * @param withdrawAddress The address to withdraw stake to (unused in minimal implementation)
     */
    function withdrawStake(address payable withdrawAddress) external {
        // Note: withdrawAddress parameter kept for interface compatibility
        if (withdrawAddress == address(0)) {
            // This satisfies the unused variable warning while maintaining interface
        }
        // No-op in minimal implementation
    }

    // Public functions

    /**
     * @notice Get the hash of a UserOperation
     * @param userOp The UserOperation to hash
     * @return The hash of the UserOperation
     */
    function getUserOpHash(UserOperation calldata userOp) public view returns (bytes32) {
        return keccak256(abi.encode(
            userOp.sender,
            userOp.nonce,
            keccak256(userOp.initCode),
            keccak256(userOp.callData),
            userOp.callGasLimit,
            userOp.verificationGasLimit,
            userOp.preVerificationGas,
            userOp.maxFeePerGas,
            userOp.maxPriorityFeePerGas,
            keccak256(userOp.paymasterAndData),
            address(this),
            block.chainid
        ));
    }

    // Internal functions

    /**
     * @notice Execute a single UserOperation
     * @param op The UserOperation to execute
     * @param beneficiary Address to receive gas refunds
     */
    function _handleOp(
        UserOperation calldata op,
        address payable beneficiary
    ) internal {
        // Note: beneficiary parameter kept for interface compatibility
        if (beneficiary == address(0)) {
            // This satisfies the unused variable warning while maintaining interface
        }
        
        // Validate nonce
        if (op.nonce != nonces[op.sender]) {
            revert InvalidNonce(nonces[op.sender], op.nonce);
        }
        ++nonces[op.sender];
        
        // Execute the operation
        (bool success,) = op.sender.call(op.callData); // solhint-disable-line avoid-low-level-calls
        
        bytes32 userOpHash = getUserOpHash(op);
        
        emit UserOperationEvent(
            userOpHash,
            op.sender,
            address(0), // No paymaster in minimal implementation
            op.nonce,
            success,
            0, // Simplified gas accounting
            0
        );
    }
}