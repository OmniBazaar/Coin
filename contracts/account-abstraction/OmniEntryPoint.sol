// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {IEntryPoint} from "./interfaces/IEntryPoint.sol";
import {IAccount, UserOperation} from "./interfaces/IAccount.sol";
import {IPaymaster} from "./interfaces/IPaymaster.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title OmniEntryPoint
 * @author OmniCoin Development Team
 * @notice Production ERC-4337 EntryPoint for the OmniCoin L1 chain
 * @dev Singleton contract that processes UserOperations from bundlers.
 *      Replaces MinimalEntryPoint.sol with proper validation, paymaster support,
 *      account deployment via initCode, and gas accounting.
 *
 *      Simplified vs canonical EntryPoint:
 *      - No aggregator support (not needed for ECDSA/passkey signatures)
 *      - Simplified staking (not needed on our L1 with known bundlers)
 *      - Full paymaster support for gasless UX
 *      - Full account deployment via initCode/factory
 */
contract OmniEntryPoint is IEntryPoint, ReentrancyGuard {
    // ══════════════════════════════════════════════════════════════
    //                        CONSTANTS
    // ══════════════════════════════════════════════════════════════

    /// @notice Validation result: signature is valid
    uint256 internal constant SIG_VALID = 0;

    /// @notice Validation result: signature is invalid
    uint256 internal constant SIG_INVALID = 1;

    /// @notice Maximum gas allowed for a single UserOperation
    uint256 internal constant MAX_OP_GAS = 10_000_000;

    // ══════════════════════════════════════════════════════════════
    //                      STATE VARIABLES
    // ══════════════════════════════════════════════════════════════

    /// @notice Deposit balances for accounts and paymasters
    mapping(address => uint256) private _deposits;

    /// @notice Nonce management: nonces[sender][key] = sequentialNonce
    /// @dev Supports multiple nonce sequences per account via key parameter
    mapping(address => mapping(uint192 => uint256)) private _nonceSequences;

    // ══════════════════════════════════════════════════════════════
    //                       CUSTOM ERRORS
    // ══════════════════════════════════════════════════════════════

    /// @notice Nonce mismatch for UserOperation
    /// @param expected The expected nonce
    /// @param provided The nonce in the UserOperation
    error InvalidNonce(uint256 expected, uint256 provided);

    /// @notice Account validation returned failure
    /// @param account The account that failed validation
    error AccountValidationFailed(address account);

    /// @notice Paymaster validation returned failure
    /// @param paymaster The paymaster that failed validation
    error PaymasterValidationFailed(address paymaster);

    /// @notice Account deployment via initCode failed
    /// @param factory The factory that failed
    error AccountDeploymentFailed(address factory);

    /// @notice Insufficient deposit for operation
    /// @param required Amount needed
    /// @param available Amount available
    error InsufficientDeposit(uint256 required, uint256 available);

    /// @notice Withdrawal exceeds deposit
    error WithdrawalExceedsDeposit();

    /// @notice Invalid beneficiary address
    error InvalidBeneficiary();

    /// @notice Gas limits exceed maximum
    error GasLimitExceeded();

    // ══════════════════════════════════════════════════════════════
    //                        RECEIVE
    // ══════════════════════════════════════════════════════════════

    /// @notice Allow deposits of native tokens
    receive() external payable {
        _deposits[msg.sender] += msg.value;
    }

    // ══════════════════════════════════════════════════════════════
    //                  EXTERNAL FUNCTIONS (NON-VIEW)
    // ══════════════════════════════════════════════════════════════

    /**
     * @notice Deposit funds for an account to pay for gas
     * @param account The account to fund
     */
    function depositTo(address account) external payable override {
        _deposits[account] += msg.value;
    }

    /**
     * @notice Withdraw from deposit
     * @param withdrawAddress Address to receive funds
     * @param withdrawAmount Amount to withdraw
     */
    function withdrawTo(
        address payable withdrawAddress,
        uint256 withdrawAmount
    ) external {
        if (_deposits[msg.sender] < withdrawAmount) {
            revert WithdrawalExceedsDeposit();
        }
        _deposits[msg.sender] -= withdrawAmount;
        // solhint-disable-next-line avoid-low-level-calls
        (bool success,) = withdrawAddress.call{value: withdrawAmount}("");
        if (!success) revert WithdrawalExceedsDeposit();
    }

    /**
     * @notice Execute a batch of UserOperations
     * @dev Called by bundlers. For each operation:
     *      1. Deploy account if initCode is present
     *      2. Validate nonce
     *      3. Call account.validateUserOp()
     *      4. Validate paymaster (if specified)
     *      5. Execute the operation
     *      6. Call paymaster.postOp() if applicable
     *      7. Refund excess gas to beneficiary
     * @param ops Array of UserOperations
     * @param beneficiary Address to receive gas refunds
     */
    function handleOps(
        UserOperation[] calldata ops,
        address payable beneficiary
    ) external override nonReentrant {
        if (beneficiary == address(0)) revert InvalidBeneficiary();

        uint256 opsLength = ops.length;
        for (uint256 i; i < opsLength; ++i) {
            _handleSingleOp(ops[i], beneficiary);
        }
    }

    // ══════════════════════════════════════════════════════════════
    //                  EXTERNAL/PUBLIC VIEW FUNCTIONS
    // ══════════════════════════════════════════════════════════════

    /**
     * @notice Get the deposit balance for an account
     * @param account The account to query
     * @return The deposited balance
     */
    function balanceOf(address account) external view override returns (uint256) {
        return _deposits[account];
    }

    /**
     * @notice Get the current nonce for a sender and key
     * @dev The nonce is composed of a 192-bit key and a 64-bit sequential value.
     *      Full nonce = key << 64 | sequentialNonce
     * @param sender The account address
     * @param key The nonce key (allows parallel nonce sequences)
     * @return nonce The full nonce value
     */
    function getNonce(
        address sender,
        uint192 key
    ) external view override returns (uint256 nonce) {
        return (uint256(key) << 64) | _nonceSequences[sender][key];
    }

    /**
     * @notice Compute the hash of a UserOperation
     * @dev The hash includes the EntryPoint address and chain ID to prevent replay.
     * @param userOp The UserOperation to hash
     * @return The unique hash
     */
    function getUserOpHash(
        UserOperation calldata userOp
    ) public view returns (bytes32) {
        return keccak256(
            abi.encode(
                _hashUserOpFields(userOp),
                address(this),
                block.chainid
            )
        );
    }

    // ══════════════════════════════════════════════════════════════
    //                    INTERNAL FUNCTIONS
    // ══════════════════════════════════════════════════════════════

    /**
     * @notice Process a single UserOperation
     * @param op The UserOperation to execute
     * @param beneficiary Gas refund recipient
     */
    function _handleSingleOp(
        UserOperation calldata op,
        address payable beneficiary
    ) internal {
        uint256 gasStart = gasleft();

        // Step 0: Validate total gas does not exceed maximum
        uint256 totalGas = op.callGasLimit
            + op.verificationGasLimit
            + op.preVerificationGas;
        if (totalGas > MAX_OP_GAS) revert GasLimitExceeded();

        // Step 1: Deploy account if initCode is present, otherwise verify it exists
        if (op.initCode.length > 0) {
            _deployAccount(op);
        } else if (op.sender.code.length == 0) {
            revert AccountDeploymentFailed(address(0));
        }

        // Step 2: Validate nonce
        _validateNonce(op.sender, op.nonce);

        // Step 3: Compute UserOp hash
        bytes32 userOpHash = getUserOpHash(op);

        // Step 4: Validate account signature
        uint256 missingFunds = _accountPrefund(op);
        uint256 validationData = IAccount(op.sender).validateUserOp(
            op,
            userOpHash,
            missingFunds
        );
        if (_extractSigResult(validationData) != SIG_VALID) {
            revert AccountValidationFailed(op.sender);
        }

        // Step 5: Validate paymaster (if present)
        address paymaster = _getPaymaster(op);
        bytes memory paymasterContext;
        if (paymaster != address(0)) {
            uint256 maxCost = _maxOperationCost(op);
            (paymasterContext,) = IPaymaster(paymaster).validatePaymasterUserOp(
                op,
                userOpHash,
                maxCost
            );
        }

        // Step 6: Execute the operation
        // solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory revertReason) = op.sender.call{
            gas: op.callGasLimit
        }(op.callData);

        if (!success) {
            emit UserOperationRevertReason(
                userOpHash, op.sender, op.nonce, revertReason
            );
        }

        // Step 7: Deduct gas, call paymaster postOp, emit event, refund
        uint256 actualGasCost = (gasStart - gasleft()) * tx.gasprice;
        _deductGasCost(op.sender, paymaster, actualGasCost);
        _callPaymasterPostOp(
            paymaster, paymasterContext, success, actualGasCost
        );

        emit UserOperationEvent(
            userOpHash, op.sender, paymaster,
            op.nonce, success, actualGasCost, gasStart - gasleft()
        );

        _refundBeneficiary(beneficiary, actualGasCost);
    }

    /**
     * @notice Deduct gas cost from the responsible party's deposit
     * @dev If a paymaster is present, it pays; otherwise the sender pays
     * @param sender The UserOp sender address
     * @param paymaster The paymaster address (address(0) if none)
     * @param actualGasCost Gas cost to deduct
     */
    function _deductGasCost(
        address sender,
        address paymaster,
        uint256 actualGasCost
    ) internal {
        if (paymaster != address(0)) {
            _deposits[paymaster] -= actualGasCost;
        } else {
            _deposits[sender] -= actualGasCost;
        }
    }

    /**
     * @notice Call paymaster postOp with fallback retry on revert
     * @dev If the first postOp call reverts, retries with postOpReverted mode.
     *      No-ops if paymaster is address(0) or context is empty.
     * @param paymaster The paymaster address
     * @param paymasterContext Context from validatePaymasterUserOp
     * @param success Whether the UserOp execution succeeded
     * @param actualGasCost Actual gas cost to report
     */
    function _callPaymasterPostOp(
        address paymaster,
        bytes memory paymasterContext,
        bool success,
        uint256 actualGasCost
    ) internal {
        if (paymaster == address(0) || paymasterContext.length == 0) return;

        IPaymaster.PostOpMode mode = success
            ? IPaymaster.PostOpMode.opSucceeded
            : IPaymaster.PostOpMode.opReverted;

        try IPaymaster(paymaster).postOp(
            mode, paymasterContext, actualGasCost
        ) {
            // PostOp succeeded
        } catch {
            // PostOp reverted - retry with postOpReverted mode
            try IPaymaster(paymaster).postOp(
                IPaymaster.PostOpMode.postOpReverted,
                paymasterContext,
                actualGasCost
            ) {} catch {} // solhint-disable-line no-empty-blocks
        }
    }

    /**
     * @notice Refund gas costs to the beneficiary
     * @dev Sends the lesser of actualGasCost and contract balance.
     *      Silently ignores transfer failure.
     * @param beneficiary Address to receive the refund
     * @param actualGasCost Gas cost to refund
     */
    function _refundBeneficiary(
        address payable beneficiary,
        uint256 actualGasCost
    ) internal {
        if (actualGasCost == 0 || address(this).balance == 0) return;

        uint256 refund = actualGasCost < address(this).balance
            ? actualGasCost
            : address(this).balance;
        // solhint-disable-next-line avoid-low-level-calls
        (bool refundSuccess,) = beneficiary.call{value: refund}("");
        (refundSuccess); // Ignore refund failure
    }

    /**
     * @notice Deploy an account using initCode
     * @dev initCode format: first 20 bytes = factory address, remaining = factory calldata
     * @param op The UserOperation containing initCode
     */
    function _deployAccount(UserOperation calldata op) internal {
        bytes calldata initCode = op.initCode;
        address factory = address(bytes20(initCode[:20]));
        bytes calldata factoryData = initCode[20:];

        // solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory returnData) = factory.call(factoryData);
        if (!success) revert AccountDeploymentFailed(factory);

        // Verify the deployed address matches sender
        if (returnData.length > 31) {
            address deployed = abi.decode(returnData, (address));
            if (deployed != op.sender) revert AccountDeploymentFailed(factory);
        }

        address paymaster = _getPaymaster(op);
        emit AccountDeployed(
            getUserOpHash(op),
            op.sender,
            factory,
            paymaster
        );
    }

    /**
     * @notice Validate and increment nonce
     * @param sender Account address
     * @param fullNonce The full nonce (key << 64 | sequential)
     */
    function _validateNonce(address sender, uint256 fullNonce) internal {
        uint192 key = uint192(fullNonce >> 64);
        uint64 seq = uint64(fullNonce);
        uint256 currentSeq = _nonceSequences[sender][key];

        if (seq != currentSeq) {
            revert InvalidNonce(currentSeq | (uint256(key) << 64), fullNonce);
        }
        _nonceSequences[sender][key] = currentSeq + 1;
    }

    /**
     * @notice Calculate missing account funds needed for prefunding
     * @param op The UserOperation
     * @return missingFunds Amount the account must deposit
     */
    function _accountPrefund(UserOperation calldata op) internal view returns (uint256 missingFunds) {
        uint256 maxGasCost = _maxOperationCost(op);
        uint256 currentDeposit = _deposits[op.sender];

        // If paymaster is present, paymaster pays — no account prefund needed
        if (op.paymasterAndData.length > 0) return 0;

        if (currentDeposit > maxGasCost - 1) return 0;
        return maxGasCost - currentDeposit;
    }

    /**
     * @notice Extract and validate the packed validation data from validateUserOp
     * @dev ERC-4337 validation data packing:
     *      - Bits 0-159: aggregator address (0 = no aggregator, 1 = invalid sig)
     *      - Bits 160-207: validUntil (uint48, 0 = no expiry)
     *      - Bits 208-255: validAfter (uint48, 0 = no restriction)
     *      Rejects unknown aggregators (non-zero address other than address(1)).
     * @param validationData The packed validation data from validateUserOp
     * @return sigResult 0 if valid, 1 if invalid
     */
    function _extractSigResult(
        uint256 validationData
    ) internal view returns (uint256 sigResult) {
        // Extract aggregator from lower 160 bits
        address aggregator = address(uint160(validationData));
        if (aggregator == address(1)) return SIG_INVALID;

        // Reject unknown aggregators (aggregator support not implemented)
        if (aggregator != address(0)) return SIG_INVALID;

        // Extract time range from upper bits
        uint48 validUntil = uint48(validationData >> 160);
        uint48 validAfter = uint48(validationData >> 208);

        // Validate time ranges
        // solhint-disable-next-line not-rely-on-time
        if (validUntil != 0 && block.timestamp > validUntil) {
            return SIG_INVALID;
        }
        // solhint-disable-next-line not-rely-on-time
        if (validAfter != 0 && block.timestamp < validAfter) {
            return SIG_INVALID;
        }

        return SIG_VALID;
    }

    /**
     * @notice Calculate maximum gas cost for an operation
     * @param op The UserOperation
     * @return maxCost Maximum native token cost
     */
    function _maxOperationCost(UserOperation calldata op) internal pure returns (uint256 maxCost) {
        uint256 totalGas = op.callGasLimit + op.verificationGasLimit + op.preVerificationGas;
        return totalGas * op.maxFeePerGas;
    }

    /**
     * @notice Extract paymaster address from paymasterAndData
     * @param op The UserOperation
     * @return paymaster The paymaster address (address(0) if none)
     */
    function _getPaymaster(UserOperation calldata op) internal pure returns (address paymaster) {
        if (op.paymasterAndData.length < 20) return address(0);
        return address(bytes20(op.paymasterAndData[:20]));
    }

    /**
     * @notice Hash UserOperation fields (without EntryPoint and chain)
     * @param userOp The UserOperation to hash
     * @return Hash of the operation fields
     */
    function _hashUserOpFields(
        UserOperation calldata userOp
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                userOp.sender,
                userOp.nonce,
                keccak256(userOp.initCode),
                keccak256(userOp.callData),
                userOp.callGasLimit,
                userOp.verificationGasLimit,
                userOp.preVerificationGas,
                userOp.maxFeePerGas,
                userOp.maxPriorityFeePerGas,
                keccak256(userOp.paymasterAndData)
            )
        );
    }

}
