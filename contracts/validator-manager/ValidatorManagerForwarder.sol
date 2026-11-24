// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

/**
 * @title ValidatorManagerForwarder
 * @notice Temporary implementation for the OmniBazaar L1 specialization proxy
 *         (0x100c0De1C0FFEe00000000000000000000000000). It exists only to let
 *         the base validator manager be driven by its owner during the
 *         2026-11-24 validator owner rotation, because the live
 *         NativeTokenStakingManager refuses removal inside the 365-day
 *         minStakeDuration that all five validators were registered with.
 *
 * 🛑 THIS CONTRACT MUST NEVER DECLARE STATE.
 * The proxy slot it is installed into holds the live staking manager's storage.
 * Every variable below is `constant` or `immutable`, which lives in code, never
 * in storage. Adding a state variable would corrupt the staking state of the
 * proxy the moment it is written.
 *
 * Why this works:
 *  - The base manager (MANAGER) gates both functions with `onlyOwner`, and its
 *    owner is the specialization proxy itself.
 *  - A call that reaches this implementation through the proxy makes the proxy
 *    the caller of MANAGER, so the owner check passes.
 *  - The base's own removal path has no minStakeDuration gate (that rule lives
 *    only in the staking manager), so it can emit the weight-0 Warp message.
 *
 * Access: only OPERATOR may call. Deployed with the successor cold address, so
 * the compromised key used to install the upgrade gains no new power.
 */
contract ValidatorManagerForwarder {
    /// @notice The base validator manager this contract drives.
    address public constant MANAGER = 0x0Feedc0de0000000000000000000000000000000;

    /// @notice The only account allowed to call through this contract.
    address public immutable OPERATOR;

    error NotOperator(address caller);
    error ZeroAddress();

    constructor(address operator) {
        if (operator == address(0)) revert ZeroAddress();
        OPERATOR = operator;
    }

    modifier onlyOperator() {
        if (msg.sender != OPERATOR) revert NotOperator(msg.sender);
        _;
    }

    /**
     * @notice Starts removal of a validation. The base manager emits the
     *         L1ValidatorWeightMessage with weight 0 that the P-Chain consumes
     *         in a SetL1ValidatorWeightTx.
     */
    function initiateValidatorRemoval(bytes32 validationID) external onlyOperator {
        IBaseValidatorManager(MANAGER).initiateValidatorRemoval(validationID);
    }

    /**
     * @notice Completes removal once the P-Chain has confirmed. The caller must
     *         supply the signed P-Chain Warp message as a transaction predicate
     *         (access list entry for 0x0200…0005), exactly as the historical
     *         completion transactions on this L1 did.
     */
    function completeValidatorRemoval(uint32 messageIndex) external onlyOperator {
        IBaseValidatorManager(MANAGER).completeValidatorRemoval(messageIndex);
    }

    /**
     * @notice Re-sends a removal message that was emitted but never consumed.
     *         Harmless to keep; it is the only other function of the base's
     *         removal path and needs no storage of its own.
     */
    function resendValidatorRemovalMessage(bytes32 validationID) external onlyOperator {
        IBaseValidatorManager(MANAGER).resendValidatorRemovalMessage(validationID);
    }
}

interface IBaseValidatorManager {
    function initiateValidatorRemoval(bytes32 validationID) external;

    function completeValidatorRemoval(uint32 messageIndex) external;

    function resendValidatorRemovalMessage(bytes32 validationID) external;
}
