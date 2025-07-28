// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title MinimalEntryPoint
 * @notice Minimal implementation of ERC-4337 EntryPoint for testing
 * @dev This is a simplified version that implements only the required functions
 */
contract MinimalEntryPoint {
    
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
    
    // Events
    event UserOperationEvent(
        bytes32 indexed userOpHash,
        address indexed sender,
        address indexed paymaster,
        uint256 nonce,
        bool success,
        uint256 actualGasCost,
        uint256 actualGasUsed
    );
    
    event AccountDeployed(
        bytes32 indexed userOpHash,
        address indexed sender,
        address factory,
        address paymaster
    );
    
    // State
    mapping(address => uint256) public deposits;
    mapping(address => uint256) public nonces;
    
    /**
     * @notice Execute a batch of UserOperations
     * @param ops Array of UserOperations to execute
     * @param beneficiary Address to receive gas refunds
     */
    function handleOps(
        UserOperation[] calldata ops,
        address payable beneficiary
    ) external {
        for (uint256 i = 0; i < ops.length; i++) {
            _handleOp(ops[i], beneficiary);
        }
    }
    
    /**
     * @notice Execute a single UserOperation
     * @param op The UserOperation to execute
     * @param beneficiary Address to receive gas refunds
     */
    function _handleOp(
        UserOperation calldata op,
        address payable beneficiary
    ) internal {
        // Validate nonce
        require(op.nonce == nonces[op.sender], "Invalid nonce");
        nonces[op.sender]++;
        
        // Execute the operation
        (bool success,) = op.sender.call(op.callData);
        
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
        require(deposits[msg.sender] >= withdrawAmount, "Insufficient deposit");
        deposits[msg.sender] -= withdrawAmount;
        withdrawAddress.transfer(withdrawAmount);
    }
    
    /**
     * @notice Add stake (no-op in minimal implementation)
     */
    function addStake(uint32) external payable {
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
     */
    function withdrawStake(address payable) external {
        // No-op in minimal implementation
    }
}