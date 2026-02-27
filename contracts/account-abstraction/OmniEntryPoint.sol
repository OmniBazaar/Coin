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

    /// @notice Maximum native token cost allowed for a single UserOperation
    /// @dev Prevents unreasonable deposit obligations from extreme maxFeePerGas values.
    ///      Set to 100 ETH equivalent -- adjust for OmniCoin L1 economics.
    uint256 internal constant MAX_OP_COST = 100 ether;

    /// @notice Fixed gas overhead added to actualGasCost to cover post-execution
    ///         bookkeeping (deposit deduction, postOp call, event emission, refund)
    /// @dev Without this overhead, bundlers are systematically undercompensated
    ///      because gas consumed after the cost snapshot is not accounted for.
    uint256 internal constant GAS_OVERHEAD = 40_000;

    // ══════════════════════════════════════════════════════════════
    //                      STATE VARIABLES
    // ══════════════════════════════════════════════════════════════

    /// @notice Deposit balances for accounts and paymasters
    mapping(address => uint256) private _deposits;

    /// @notice Nonce management: nonces[sender][key] = sequentialNonce
    /// @dev Supports multiple nonce sequences per account via key parameter
    mapping(address => mapping(uint192 => uint256)) private _nonceSequences;

    // ══════════════════════════════════════════════════════════════
    //                          EVENTS
    // ══════════════════════════════════════════════════════════════

    /// @notice Emitted when funds are deposited for an account
    /// @param account The account that received the deposit
    /// @param totalDeposit The total deposit balance after this deposit
    event Deposited(
        address indexed account,
        uint256 indexed totalDeposit
    );

    /// @notice Emitted when funds are withdrawn from an account's deposit
    /// @param account The account that withdrew
    /// @param withdrawAddress The address that received the withdrawal
    /// @param amount The amount withdrawn
    event Withdrawn(
        address indexed account,
        address indexed withdrawAddress,
        uint256 indexed amount
    );

    /// @notice Emitted when the payer's deposit is insufficient to cover gas
    /// @param payer The address whose deposit was insufficient
    /// @param deficit The shortfall amount (gasCost - availableDeposit)
    event GasDeficit(
        address indexed payer,
        uint256 indexed deficit
    );

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

    /// @notice UserOperation gas cost exceeds maximum allowed cost
    error OperationCostExceeded();

    // ══════════════════════════════════════════════════════════════
    //                        RECEIVE
    // ══════════════════════════════════════════════════════════════

    /// @notice Allow deposits of native tokens
    /// @dev Credits the sender's deposit balance. To fund a different account,
    ///      use depositTo(). Direct ETH transfers credit the sender's EOA, NOT
    ///      a smart account -- use depositTo() for smart account funding.
    receive() external payable { // solhint-disable-line no-complex-fallback
        _deposits[msg.sender] += msg.value;
        emit Deposited(msg.sender, _deposits[msg.sender]);
    }

    // ══════════════════════════════════════════════════════════════
    //                  EXTERNAL FUNCTIONS (NON-VIEW)
    // ══════════════════════════════════════════════════════════════

    /**
     * @notice Deposit funds for an account to pay for gas
     * @dev Protected by nonReentrant to prevent deposit manipulation
     *      during handleOps execution (H-01).
     * @param account The account to fund
     */
    function depositTo(
        address account
    ) external payable override nonReentrant {
        _deposits[account] += msg.value;
        emit Deposited(account, _deposits[account]);
    }

    /**
     * @notice Withdraw from deposit
     * @dev Protected by nonReentrant to prevent withdrawal during handleOps
     *      execution. A smart account calling withdrawTo during UserOp
     *      execution would bypass gas accounting (H-01).
     * @param withdrawAddress Address to receive funds
     * @param withdrawAmount Amount to withdraw
     */
    function withdrawTo(
        address payable withdrawAddress,
        uint256 withdrawAmount
    ) external nonReentrant {
        if (_deposits[msg.sender] < withdrawAmount) {
            revert WithdrawalExceedsDeposit();
        }
        _deposits[msg.sender] -= withdrawAmount;
        // solhint-disable-next-line avoid-low-level-calls
        (bool success,) = withdrawAddress.call{value: withdrawAmount}("");
        if (!success) revert WithdrawalExceedsDeposit();
        emit Withdrawn(msg.sender, withdrawAddress, withdrawAmount);
    }

    /**
     * @notice Execute a batch of UserOperations
     * @dev Called by bundlers. Processes each operation independently via
     *      try/catch so that one failed operation does not revert the entire
     *      batch (M-03). For each operation:
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
            // M-03: Isolate each UserOp so one failure does not
            // abort the entire bundle. handleSingleOp is external
            // to enable try/catch.
            try this.handleSingleOp(ops[i], beneficiary) {
                // Operation succeeded
            } catch (bytes memory reason) {
                emit UserOperationRevertReason(
                    getUserOpHash(ops[i]),
                    ops[i].sender,
                    ops[i].nonce,
                    reason
                );
            }
        }
    }

    /**
     * @notice Process a single UserOperation (external for try/catch)
     * @dev This function is external so that handleOps can wrap each call
     *      in try/catch for failure isolation. Only callable by this
     *      contract itself (enforced by require).
     * @param op The UserOperation to execute
     * @param beneficiary Gas refund recipient
     */
    function handleSingleOp(
        UserOperation calldata op,
        address payable beneficiary
    ) external {
        // Only callable by this contract (from handleOps try/catch)
        if (msg.sender != address(this)) {
            revert InvalidBeneficiary();
        }
        _handleSingleOp(op, beneficiary);
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
     * @dev Orchestrates validation, execution, and gas accounting.
     *      Validation is extracted into _validateOp for complexity reduction.
     * @param op The UserOperation to execute
     * @param beneficiary Gas refund recipient
     */
    function _handleSingleOp(
        UserOperation calldata op,
        address payable beneficiary
    ) internal {
        uint256 gasStart = gasleft();

        // Phase 1: Validate (deploy, nonce, account sig, paymaster)
        (
            bytes32 userOpHash,
            address paymaster,
            bytes memory paymasterContext
        ) = _validateOp(op);

        // Phase 2: Execute the operation
        // solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory revertReason) = op.sender.call{
            gas: op.callGasLimit
        }(op.callData);

        if (!success) {
            emit UserOperationRevertReason(
                userOpHash, op.sender, op.nonce, revertReason
            );
        }

        // Phase 3: Gas accounting and refund
        _settleGas(
            op, userOpHash, gasStart, paymaster,
            paymasterContext, success, beneficiary
        );
    }

    /**
     * @notice Validate a UserOperation (deploy, nonce, account, paymaster)
     * @dev Extracted from _handleSingleOp for complexity reduction.
     *      Applies: C-03, H-02, H-03, M-01, M-04, L-04.
     * @param op The UserOperation to validate
     * @return userOpHash The computed operation hash
     * @return paymaster The paymaster address (address(0) if none)
     * @return paymasterContext Context from paymaster validation
     */
    function _validateOp(
        UserOperation calldata op
    ) internal returns (
        bytes32 userOpHash,
        address paymaster,
        bytes memory paymasterContext
    ) {
        // Step 0: Gas limit checks
        uint256 totalGas = op.callGasLimit
            + op.verificationGasLimit
            + op.preVerificationGas;
        if (totalGas > MAX_OP_GAS) revert GasLimitExceeded();
        uint256 maxCost = _maxOperationCost(op);
        if (maxCost > MAX_OP_COST) revert OperationCostExceeded();

        // Step 1: Deploy or verify account exists
        userOpHash = getUserOpHash(op);
        _ensureAccountDeployed(op, userOpHash);

        // Step 2: Validate nonce
        _validateNonce(op.sender, op.nonce);

        // Step 3: Validate account signature (H-02: verify prefund)
        _validateAccountSig(op, userOpHash);

        // Step 4: Validate paymaster (C-03: check validationData)
        paymaster = _getPaymaster(op);
        if (paymaster != address(0)) {
            paymasterContext = _validatePaymaster(
                op, userOpHash, paymaster, maxCost
            );
        }
    }

    /**
     * @notice Ensure the account is deployed, deploying via initCode if needed
     * @dev H-03: Factory gas-limited. M-01: Code verified post-deploy.
     * @param op The UserOperation
     * @param userOpHash Pre-computed UserOp hash
     */
    function _ensureAccountDeployed(
        UserOperation calldata op,
        bytes32 userOpHash
    ) internal {
        if (op.initCode.length > 0) {
            _deployAccount(op, userOpHash);
            // M-01: Verify code was deployed at op.sender
            if (op.sender.code.length == 0) {
                revert AccountDeploymentFailed(address(0));
            }
        } else if (op.sender.code.length == 0) {
            revert AccountDeploymentFailed(address(0));
        }
    }

    /**
     * @notice Validate account signature and verify prefund payment
     * @dev H-02: Checks deposit increased by missingFunds after validateUserOp
     * @param op The UserOperation
     * @param userOpHash The operation hash
     */
    function _validateAccountSig(
        UserOperation calldata op,
        bytes32 userOpHash
    ) internal {
        uint256 missingFunds = _accountPrefund(op);
        uint256 depositBefore = _deposits[op.sender];
        uint256 validationData = IAccount(op.sender).validateUserOp(
            op, userOpHash, missingFunds
        );
        if (_extractSigResult(validationData) != SIG_VALID) {
            revert AccountValidationFailed(op.sender);
        }
        // H-02: Verify the account paid missingFunds
        if (
            missingFunds > 0
            && _deposits[op.sender] < depositBefore + missingFunds
        ) {
            revert InsufficientDeposit(
                depositBefore + missingFunds,
                _deposits[op.sender]
            );
        }
    }

    /**
     * @notice Validate paymaster sponsorship
     * @dev C-03: Captures and validates paymaster's validationData.
     *      L-01 (audit): Verifies paymaster deposit covers maxCost.
     * @param op The UserOperation
     * @param userOpHash The operation hash
     * @param paymaster The paymaster address
     * @param maxCost Maximum gas cost for this operation
     * @return paymasterContext Context data for postOp
     */
    function _validatePaymaster(
        UserOperation calldata op,
        bytes32 userOpHash,
        address paymaster,
        uint256 maxCost
    ) internal returns (bytes memory paymasterContext) {
        if (_deposits[paymaster] < maxCost) {
            revert InsufficientDeposit(maxCost, _deposits[paymaster]);
        }
        uint256 pmValidationData;
        (paymasterContext, pmValidationData) = IPaymaster(paymaster)
            .validatePaymasterUserOp(op, userOpHash, maxCost);
        if (_extractSigResult(pmValidationData) != SIG_VALID) {
            revert PaymasterValidationFailed(paymaster);
        }
    }

    /**
     * @notice Settle gas costs: deduct, call postOp, emit event, refund
     * @dev M-02: Adds GAS_OVERHEAD to actualGasCost.
     *      C-01: Underflow-safe deduction.
     *      C-02: Failed refund credits payer.
     * @param op The UserOperation
     * @param userOpHash The operation hash
     * @param gasStart Gas snapshot from start of execution
     * @param paymaster The paymaster (address(0) if none)
     * @param paymasterContext Context for postOp
     * @param success Whether execution succeeded
     * @param beneficiary Gas refund recipient
     */
    function _settleGas(
        UserOperation calldata op,
        bytes32 userOpHash,
        uint256 gasStart,
        address paymaster,
        bytes memory paymasterContext,
        bool success,
        address payable beneficiary
    ) internal {
        uint256 actualGasUsed = (gasStart - gasleft()) + GAS_OVERHEAD;
        uint256 actualGasCost = actualGasUsed * tx.gasprice;
        address payer = paymaster != address(0)
            ? paymaster
            : op.sender;
        _deductGasCost(payer, actualGasCost);
        _callPaymasterPostOp(
            paymaster, paymasterContext, success, actualGasCost
        );
        emit UserOperationEvent(
            userOpHash, op.sender, paymaster,
            op.nonce, success, actualGasCost, actualGasUsed
        );
        _refundBeneficiary(beneficiary, payer, actualGasCost);
    }

    /**
     * @notice Deduct gas cost from the responsible party's deposit
     * @dev C-01: Uses underflow-safe deduction. If the payer's deposit
     *      is insufficient, deducts whatever is available and emits a
     *      GasDeficit event instead of reverting. This prevents a
     *      single underfunded operation from aborting the entire batch.
     * @param payer The address paying for gas (paymaster or sender)
     * @param actualGasCost Gas cost to deduct
     */
    function _deductGasCost(
        address payer,
        uint256 actualGasCost
    ) internal {
        uint256 deposit = _deposits[payer];
        if (deposit < actualGasCost) {
            // C-01: Deduct what is available, emit deficit
            _deposits[payer] = 0;
            emit GasDeficit(payer, actualGasCost - deposit);
        } else {
            _deposits[payer] -= actualGasCost;
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
     * @notice Refund gas costs to the beneficiary (bundler)
     * @dev C-02: If the ETH transfer to the beneficiary fails, the refund
     *      amount is credited back to the payer's deposit instead of being
     *      silently discarded. This prevents a desynchronization between
     *      the internal deposit ledger and actual contract balance.
     * @param beneficiary Address to receive the refund
     * @param payer The address that was charged for gas
     * @param actualGasCost Gas cost to refund
     */
    function _refundBeneficiary(
        address payable beneficiary,
        address payer,
        uint256 actualGasCost
    ) internal {
        if (actualGasCost == 0 || address(this).balance == 0) return;

        uint256 refund = actualGasCost < address(this).balance
            ? actualGasCost
            : address(this).balance;
        // solhint-disable-next-line avoid-low-level-calls
        (bool refundSuccess,) = beneficiary.call{value: refund}("");
        if (!refundSuccess) {
            // C-02: Credit back to payer since beneficiary cannot receive
            _deposits[payer] += refund;
        }
    }

    /**
     * @notice Deploy an account using initCode
     * @dev initCode format: first 20 bytes = factory address,
     *      remaining = factory calldata.
     *      H-03: Factory call is gas-limited to verificationGasLimit.
     *      M-01: Code existence at op.sender is verified by the caller
     *      after this function returns.
     *      I-01: Pre-computed userOpHash is passed to avoid double hashing.
     * @param op The UserOperation containing initCode
     * @param userOpHash Pre-computed hash of the UserOperation
     */
    function _deployAccount(
        UserOperation calldata op,
        bytes32 userOpHash
    ) internal {
        bytes calldata initCode = op.initCode;
        address factory = address(bytes20(initCode[:20]));
        bytes calldata factoryData = initCode[20:];

        // H-03: Limit factory call gas to verificationGasLimit
        // solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory returnData) = factory.call{
            gas: op.verificationGasLimit
        }(factoryData);
        if (!success) revert AccountDeploymentFailed(factory);

        // Verify the deployed address matches sender
        if (returnData.length > 31) {
            address deployed = abi.decode(returnData, (address));
            if (deployed != op.sender) {
                revert AccountDeploymentFailed(factory);
            }
        }

        address paymaster = _getPaymaster(op);
        emit AccountDeployed(
            userOpHash,
            op.sender,
            factory,
            paymaster
        );
    }

    /**
     * @notice Validate and increment nonce
     * @dev L-02: The nonce is incremented BEFORE account validation runs.
     *      If account validation fails, the revert rolls back the increment.
     *      This ordering means the account sees nonce+1 during validateUserOp
     *      if it queries the EntryPoint. This deviates from the canonical
     *      EntryPoint (which increments after validation) but is safe because
     *      all failures revert the entire _handleSingleOp call.
     *
     *      Nonce ordering guarantees:
     *      - Each (sender, key) pair has an independent sequential counter.
     *      - Nonces MUST be submitted in order within a key sequence.
     *      - Different keys allow parallel nonce sequences (e.g., key=0 for
     *        normal ops, key=1 for governance votes, key=2 for session keys).
     *      - A nonce is consumed atomically: either the entire UserOp succeeds
     *        and the nonce is incremented, or the op reverts and the nonce
     *        remains unchanged.
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
     * @dev M-04: Handles the zero maxGasCost edge case explicitly to
     *      prevent underflow. If a paymaster is present, no account
     *      prefund is needed (the paymaster covers gas).
     * @param op The UserOperation
     * @return missingFunds Amount the account must deposit
     */
    function _accountPrefund(
        UserOperation calldata op
    ) internal view returns (uint256 missingFunds) {
        // If paymaster is present, paymaster pays -- no account prefund
        if (op.paymasterAndData.length > 0) return 0;

        uint256 maxGasCost = _maxOperationCost(op);
        // M-04: Prevent underflow when maxGasCost is 0
        if (maxGasCost == 0) return 0;

        uint256 currentDeposit = _deposits[op.sender];
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
