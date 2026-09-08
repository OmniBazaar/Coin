// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title MockActivityLedger
 * @author OmniBazaar Team
 * @notice Test double for {ValidatorActivityLedger}. Mirrors its
 *         `lastAttestationEpoch` / `attestationCount` storage and
 *         `recordEpochActivity` entry point, plus a test-only
 *         `setLastAttestationEpoch` setter so tests can pin a validator's
 *         attested epoch directly (e.g. to exercise the epoch-window
 *         inactivity boundary deterministically).
 * @dev RECORDER_ROLE mirrors the real contract's role gating; the
 *      deployer is granted both roles in the constructor.
 */
contract MockActivityLedger is AccessControl {
    bytes32 public constant RECORDER_ROLE = keccak256("RECORDER_ROLE");

    mapping(address => uint256) public attestationCount;
    mapping(address => uint256) public lastAttestationEpoch;

    event ActivityRecorded(
        address indexed validator,
        uint256 indexed epoch,
        uint256 count
    );

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(RECORDER_ROLE, msg.sender);
    }

    /**
     * @notice Record attestation for a set of validators at an epoch.
     * @dev Mirrors the real contract's idempotent + monotonic semantics.
     */
    function recordEpochActivity(
        uint256 epoch,
        address[] calldata validators
    ) external onlyRole(RECORDER_ROLE) {
        uint256 length = validators.length;
        for (uint256 i = 0; i < length; ++i) {
            address validator = validators[i];
            if (validator == address(0)) continue;
            if (lastAttestationEpoch[validator] >= epoch) continue;
            lastAttestationEpoch[validator] = epoch;
            attestationCount[validator] += 1;
            emit ActivityRecorded(
                validator, epoch, attestationCount[validator]
            );
        }
    }

    /**
     * @notice Test-only: pin a validator's last attested epoch directly.
     */
    function setLastAttestationEpoch(
        address validator,
        uint256 epoch
    ) external {
        lastAttestationEpoch[validator] = epoch;
    }
}
