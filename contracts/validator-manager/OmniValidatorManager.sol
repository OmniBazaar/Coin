// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title OmniValidatorManager
 * @notice Ultra-lean validator manager for OmniCoin L1 with permissionless registration
 * @dev Bypasses Avalanche CLI Validator Manager initialization bug
 *
 * Ultra-Lean Architecture:
 * - Stores ONLY essential validator data on-chain (nodeID, BLS key, status)
 * - NO PoP scores stored on-chain (computed off-chain for rewards)
 * - Qualification check via boolean oracle (minimal on-chain storage)
 * - Equal consensus weights for all validators (democratic, weight = 100)
 *
 * Permissionless Registration:
 * - Anyone can register if qualified
 * - Qualification checked via QualificationOracle (boolean flag)
 * - Off-chain verifier sets qualified=true after checking:
 *   - PoP score >= 50
 *   - KYC tier >= 3
 *   - Stake >= 1M XOM
 *
 * Reward Distribution:
 * - Handled entirely off-chain in BlockRewardService.ts
 * - Uses ParticipationScoreService.ts for PoP-weighted rewards
 * - Zero on-chain computation or storage
 */
contract OmniValidatorManager is
    Initializable,
    OwnableUpgradeable,
    UUPSUpgradeable
{
    // ========== STATE VARIABLES ==========

    /// @notice Fixed consensus weight for ALL validators (democratic)
    uint64 public constant VALIDATOR_WEIGHT = 100;

    /// @notice Qualification oracle contract address
    address public qualificationOracle;

    /// @notice Validator information (ultra-lean)
    struct ValidatorInfo {
        bytes nodeID;
        bytes blsPublicKey;
        address owner;
        uint64 registeredAt;
        bool active;
    }

    /// @notice Mapping of validator addresses to their info
    mapping(address => ValidatorInfo) public validators;

    /// @notice Mapping of nodeID hash to validator address
    mapping(bytes32 => address) public nodeIDToAddress;

    /// @notice Array of all validator addresses
    address[] public validatorAddresses;

    /// @notice Total number of active validators
    uint256 public activeValidatorCount;

    // ========== EVENTS ==========

    event ValidatorRegistered(
        address indexed validator,
        bytes nodeID,
        bytes blsPublicKey
    );

    event ValidatorActivated(address indexed validator);

    event ValidatorDeactivated(address indexed validator);

    event QualificationOracleUpdated(
        address indexed oldOracle,
        address indexed newOracle
    );

    // ========== ERRORS ==========

    error NotQualified(address user);
    error ValidatorAlreadyRegistered(address validator);
    error ValidatorNotFound(address validator);
    error OracleNotSet();
    error InvalidNodeID();
    error InvalidBLSPublicKey();

    // ========== INITIALIZATION ==========

    /**
     * @notice Initialize the contract (UUPS pattern)
     * @param _qualificationOracle Address of qualification oracle
     */
    function initialize(address _qualificationOracle) public initializer {
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();

        qualificationOracle = _qualificationOracle;
    }

    /**
     * @notice Required by UUPS pattern
     * @param newImplementation Address of new implementation
     */
    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyOwner
    {}

    // ========== ADMIN FUNCTIONS ==========

    /**
     * @notice Set qualification oracle
     * @param oracle Address of qualification oracle contract
     */
    function setQualificationOracle(address oracle) external onlyOwner {
        emit QualificationOracleUpdated(qualificationOracle, oracle);
        qualificationOracle = oracle;
    }

    // ========== VALIDATOR REGISTRATION (PERMISSIONLESS) ==========

    /**
     * @notice Register as a validator (permissionless if qualified)
     * @param nodeID The NodeID of the validator
     * @param blsPublicKey The BLS public key (48 bytes)
     *
     * Requirements:
     * - Must be qualified (QualificationOracle.isQualified returns true)
     * - Valid nodeID and BLS public key
     * - Not already registered
     *
     * Qualification Criteria (enforced off-chain by verifier):
     * - PoP score >= 50 points
     * - KYC tier >= 3
     * - Stake >= 1,000,000 XOM
     * - Good reputation (no active penalties)
     *
     * Note: All validators receive EQUAL consensus weight (100)
     *       PoP scoring affects REWARDS only (computed off-chain)
     *
     * @return success True if registration succeeds
     */
    function registerValidator(
        bytes calldata nodeID,
        bytes calldata blsPublicKey
    ) external returns (bool success) {
        // Check oracle is set
        if (qualificationOracle == address(0)) {
            revert OracleNotSet();
        }

        // Validate inputs
        if (nodeID.length == 0) {
            revert InvalidNodeID();
        }
        if (blsPublicKey.length != 48) {
            revert InvalidBLSPublicKey();
        }

        // Check not already registered
        if (validators[msg.sender].owner != address(0)) {
            revert ValidatorAlreadyRegistered(msg.sender);
        }

        // Check qualification (ULTRA-LEAN: only boolean check, no scores stored)
        bool isQualified = IQualificationOracle(qualificationOracle).isQualified(
            msg.sender
        );

        if (!isQualified) {
            revert NotQualified(msg.sender);
        }

        // Create nodeID hash for mapping
        bytes32 nodeIDHash = keccak256(nodeID);

        // Register validator with EQUAL consensus weight (no score storage)
        validators[msg.sender] = ValidatorInfo({
            nodeID: nodeID,
            blsPublicKey: blsPublicKey,
            owner: msg.sender,
            registeredAt: uint64(block.timestamp),
            active: true
        });

        nodeIDToAddress[nodeIDHash] = msg.sender;
        validatorAddresses.push(msg.sender);
        activeValidatorCount++;

        emit ValidatorRegistered(msg.sender, nodeID, blsPublicKey);
        emit ValidatorActivated(msg.sender);

        return true;
    }

    /**
     * @notice Deactivate a validator (admin only, for penalties)
     * @param validator Address of validator to deactivate
     */
    function deactivateValidator(address validator) external onlyOwner {
        ValidatorInfo storage info = validators[validator];
        if (info.owner == address(0)) {
            revert ValidatorNotFound(validator);
        }

        if (info.active) {
            info.active = false;
            activeValidatorCount--;
            emit ValidatorDeactivated(validator);
        }
    }

    /**
     * @notice Reactivate a validator (admin only)
     * @param validator Address of validator to reactivate
     */
    function reactivateValidator(address validator) external onlyOwner {
        ValidatorInfo storage info = validators[validator];
        if (info.owner == address(0)) {
            revert ValidatorNotFound(validator);
        }

        if (!info.active) {
            // Re-check qualification
            if (qualificationOracle != address(0)) {
                bool isQualified = IQualificationOracle(qualificationOracle)
                    .isQualified(validator);

                if (!isQualified) {
                    revert NotQualified(validator);
                }
            }

            info.active = true;
            activeValidatorCount++;
            emit ValidatorActivated(validator);
        }
    }

    // ========== VIEW FUNCTIONS ==========

    /**
     * @notice Get validator information
     * @param validator Address of validator
     * @return info Validator information struct
     */
    function getValidator(address validator)
        external
        view
        returns (ValidatorInfo memory info)
    {
        return validators[validator];
    }

    /**
     * @notice Get validator by nodeID
     * @param nodeID The nodeID to look up
     * @return validator Address of validator
     */
    function getValidatorByNodeID(bytes calldata nodeID)
        external
        view
        returns (address validator)
    {
        bytes32 nodeIDHash = keccak256(nodeID);
        return nodeIDToAddress[nodeIDHash];
    }

    /**
     * @notice Get all active validators
     * @return active Array of active validator addresses
     */
    function getActiveValidators() external view returns (address[] memory active) {
        uint256 count = activeValidatorCount;
        active = new address[](count);

        uint256 index = 0;
        for (uint256 i = 0; i < validatorAddresses.length && index < count; i++) {
            address validatorAddr = validatorAddresses[i];
            if (validators[validatorAddr].active) {
                active[index] = validatorAddr;
                index++;
            }
        }
    }

    /**
     * @notice Get validator's consensus weight (always 100 for all validators)
     * @dev Parameter ignored - weight is constant for all validators
     * @return Consensus weight (constant 100)
     */
    function getValidatorWeight(address /* validator */)
        external
        pure
        returns (uint64)
    {
        // All validators have EQUAL consensus weight
        // PoP scoring happens off-chain for reward distribution only
        return VALIDATOR_WEIGHT;
    }

    /**
     * @notice Check if address is an active validator
     * @param validator Address to check
     * @return isActive True if validator is active
     */
    function isActiveValidator(address validator)
        external
        view
        returns (bool isActive)
    {
        ValidatorInfo storage info = validators[validator];
        return info.owner != address(0) && info.active;
    }

    /**
     * @notice Get total number of validators (active + inactive)
     * @return count Total validator count
     */
    function getTotalValidatorCount() external view returns (uint256 count) {
        return validatorAddresses.length;
    }
}

/**
 * @notice Interface for ultra-lean Qualification Oracle
 * @dev Stores ONLY boolean qualification flags, no scores
 */
interface IQualificationOracle {
    /**
     * @notice Check if address is qualified to be validator
     * @param user Address to check
     * @return isQualified True if qualified (score >= 50, KYC >= 3, stake >= 1M XOM)
     */
    function isQualified(address user) external view returns (bool isQualified);
}
