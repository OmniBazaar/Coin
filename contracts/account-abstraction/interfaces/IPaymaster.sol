// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {UserOperation} from "./IAccount.sol";

/**
 * @title IPaymaster
 * @author OmniCoin Development Team
 * @notice ERC-4337 Paymaster interface for gas sponsorship
 * @dev Paymasters can sponsor gas for UserOperations, allowing users
 *      to transact without holding native tokens. The EntryPoint calls
 *      validatePaymasterUserOp before execution and postOp after.
 */
interface IPaymaster {
    /// @notice Post-operation modes passed to postOp
    enum PostOpMode {
        /// @dev User operation succeeded
        opSucceeded,
        /// @dev User operation reverted (paymaster still pays gas)
        opReverted,
        /// @dev PostOp itself reverted on first call (retry)
        postOpReverted
    }

    /**
     * @notice Validate whether the paymaster agrees to sponsor this UserOperation
     * @dev Called by the EntryPoint during the validation phase.
     *      Must verify the paymaster is willing to pay and return context for postOp.
     * @param userOp The UserOperation requesting sponsorship
     * @param userOpHash Hash of the UserOperation
     * @param maxCost Maximum cost the paymaster could be charged
     * @return context Opaque data passed to postOp (empty = no postOp needed)
     * @return validationData Same format as IAccount.validateUserOp return value
     */
    function validatePaymasterUserOp(
        UserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 maxCost
    ) external returns (bytes memory context, uint256 validationData);

    /**
     * @notice Called after UserOperation execution for paymaster accounting
     * @dev The EntryPoint guarantees this is called if validatePaymasterUserOp succeeded.
     *      The paymaster can perform token transfers, logging, or other accounting here.
     * @param mode Whether the execution succeeded, reverted, or postOp reverted
     * @param context Data returned from validatePaymasterUserOp
     * @param actualGasCost Actual gas cost charged for this operation
     */
    function postOp(
        PostOpMode mode,
        bytes calldata context,
        uint256 actualGasCost
    ) external;
}
