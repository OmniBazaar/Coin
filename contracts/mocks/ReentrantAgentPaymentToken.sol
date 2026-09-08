// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @notice Interface of the reentrancy target (OmniAgentPermissions.executeWithPermission).
 */
interface IAgentPermissionsTarget {
    /**
     * @notice Mirror of OmniAgentPermissions.PaymentIntent for the reentrancy probe.
     */
    struct PaymentIntent {
        bytes32 grantId;
        address token;
        uint256 amount;
        address payTo;
        uint256 feeAmount;
        address feeRecipient;
        uint8 featureCode;
        bytes32 nonce;
        uint256 deadline;
    }

    /**
     * @notice The fund-moving entry point being probed.
     * @param intent The payment intent.
     * @param agentSig The agent signature.
     */
    function executeWithPermission(
        PaymentIntent calldata intent,
        bytes calldata agentSig
    ) external;
}

/**
 * @title ReentrantAgentPaymentToken
 * @author OmniBazaar Team — TEST ONLY
 * @notice Malicious ERC-20 that re-enters OmniAgentPermissions.executeWithPermission
 *         from inside transferFrom, to prove the ReentrancyGuard +
 *         checks-effects-interactions ordering hold. NOT for production.
 */
contract ReentrantAgentPaymentToken is ERC20 {
    /// @notice The contract to attack during transferFrom.
    address public attackTarget;

    /// @notice Stored intent replayed during the reentrant call.
    IAgentPermissionsTarget.PaymentIntent private _storedIntent;

    /// @notice Stored signature replayed during the reentrant call.
    bytes private _storedSig;

    /// @notice Whether the attack payload is armed.
    bool public armed;

    /**
     * @notice Deploy the malicious token and mint test supply to the deployer.
     */
    constructor() ERC20("ReentrantAgentPaymentToken", "EVIL") {
        _mint(msg.sender, 1_000_000 ether);
    }

    /**
     * @notice Mint tokens to an address (test convenience).
     * @param to Recipient.
     * @param amount Amount to mint.
     */
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /**
     * @notice Arm the reentrancy payload.
     * @param target The OmniAgentPermissions contract.
     * @param intent The intent to replay reentrantly.
     * @param sig The agent signature to replay.
     */
    function arm(
        address target,
        IAgentPermissionsTarget.PaymentIntent calldata intent,
        bytes calldata sig
    ) external {
        attackTarget = target;
        _storedIntent = intent;
        _storedSig = sig;
        armed = true;
    }

    /**
     * @notice transferFrom override that re-enters the target once while armed.
     * @param from Source address.
     * @param to Destination address.
     * @param amount Amount to transfer.
     * @return True on success (reverts otherwise).
     */
    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public override returns (bool) {
        if (armed && attackTarget != address(0)) {
            armed = false; // one reentrant attempt only
            IAgentPermissionsTarget(attackTarget).executeWithPermission(
                _storedIntent,
                _storedSig
            );
        }
        return super.transferFrom(from, to, amount);
    }
}
