// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {
    Ownable2StepUpgradeable
} from
    "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {
    UUPSUpgradeable
} from
    "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {
    IAccessControl
} from "@openzeppelin/contracts/access/IAccessControl.sol";

// ════════════════════════════════════════════════════════════════════════
//                              INTERFACES
// ════════════════════════════════════════════════════════════════════════

/**
 * @title IOmniRegistrationProvisioner
 * @notice Interface for OmniRegistration qualification checks
 * @dev Used to verify KYC tier and registration status
 */
interface IOmniRegistrationProvisioner {
    /// @notice Check if user is registered
    /// @param user Address to check
    /// @return True if registered
    function isRegistered(address user) external view returns (bool);

    /// @notice Check if user has KYC Tier 1
    /// @param user Address to check
    /// @return True if has Tier 1
    function hasKycTier1(address user) external view returns (bool);

    /// @notice Check if user has KYC Tier 2
    /// @param user Address to check
    /// @return True if has Tier 2
    function hasKycTier2(address user) external view returns (bool);

    /// @notice Check if user has KYC Tier 3
    /// @param user Address to check
    /// @return True if has Tier 3
    function hasKycTier3(address user) external view returns (bool);

    /// @notice Check if user has KYC Tier 4
    /// @param user Address to check
    /// @return True if has Tier 4
    function hasKycTier4(address user) external view returns (bool);
}

/**
 * @title IOmniParticipationProvisioner
 * @notice Interface for OmniParticipation score queries
 * @dev Used to verify participation score meets minimum
 */
interface IOmniParticipationProvisioner {
    /// @notice Get user's total participation score (0-100)
    /// @param user Address to check
    /// @return Total score
    function getTotalScore(
        address user
    ) external view returns (uint256);
}

/**
 * @title IOmniCoreProvisioner
 * @notice Interface for OmniCore validator and staking functions
 * @dev Used for stake checks and provision/deprovision calls
 */
interface IOmniCoreProvisioner {
    /// @notice Stake information structure
    struct Stake {
        uint256 amount;
        uint256 tier;
        uint256 duration;
        uint256 lockTime;
        bool active;
    }

    /// @notice Get user's stake information
    /// @param user Address to check
    /// @return Stake struct with staking details
    function getStake(
        address user
    ) external view returns (Stake memory);

    /// @notice Provision a validator (grants validator role + mapping)
    /// @param validator Address to provision
    function provisionValidator(address validator) external;

    /// @notice Deprovision a validator (revokes validator role + mapping)
    /// @param validator Address to deprovision
    function deprovisionValidator(address validator) external;
}

// ════════════════════════════════════════════════════════════════════════
//                          CONTRACT
// ════════════════════════════════════════════════════════════════════════

/**
 * @title ValidatorProvisioner
 * @author OmniBazaar Team
 * @notice Permissionless validator onboarding and offboarding
 * @dev Manages validator role provisioning across multiple contracts
 *      based on on-chain qualification criteria:
 *      - Participation score >= minParticipationScore (default: 50)
 *      - KYC tier >= minKYCTier (default: 4)
 *      - Active stake >= minStakeAmount (default: 1,000,000 XOM)
 *
 * Role provisioning covers 7 roles across 6 contracts:
 *   1. OmniRegistration: VALIDATOR_ROLE, KYC_ATTESTOR_ROLE
 *   2. OmniParticipation: VERIFIER_ROLE
 *   3. OmniValidatorRewards: BLOCKCHAIN_ROLE
 *   4. OmniCore: AVALANCHE_VALIDATOR_ROLE (via provisionValidator())
 *   5. PrivateDEX: MATCHER_ROLE (optional, if configured)
 *   6. PrivateDEXSettlement: SETTLER_ROLE (optional, if configured)
 *
 * Before this contract can manage roles, the admin must:
 *   1. Deploy and initialize this contract
 *   2. Call setXxxRoleAdmin(PROVISIONER_ROLE) on each target contract
 *   3. Grant PROVISIONER_ROLE to this contract on each target contract
 *   4. Grant PROVISIONER_ROLE to this contract on OmniCore
 *
 * @custom:security-contact security@omnibazaar.com
 */
contract ValidatorProvisioner is
    Ownable2StepUpgradeable,
    UUPSUpgradeable
{
    // ====================================================================
    // CONSTANTS
    // ====================================================================

    /// @notice Role hash for VALIDATOR_ROLE on OmniRegistration
    bytes32 public constant VALIDATOR_ROLE =
        keccak256("VALIDATOR_ROLE");

    /// @notice Role hash for KYC_ATTESTOR_ROLE on OmniRegistration
    bytes32 public constant KYC_ATTESTOR_ROLE =
        keccak256("KYC_ATTESTOR_ROLE");

    /// @notice Role hash for VERIFIER_ROLE on OmniParticipation
    bytes32 public constant VERIFIER_ROLE =
        keccak256("VERIFIER_ROLE");

    /// @notice Role hash for BLOCKCHAIN_ROLE on OmniValidatorRewards
    bytes32 public constant BLOCKCHAIN_ROLE =
        keccak256("BLOCKCHAIN_ROLE");

    /// @notice Role hash for MATCHER_ROLE on PrivateDEX
    bytes32 public constant MATCHER_ROLE =
        keccak256("MATCHER_ROLE");

    /// @notice Role hash for SETTLER_ROLE on PrivateDEXSettlement
    bytes32 public constant SETTLER_ROLE =
        keccak256("SETTLER_ROLE");

    // ====================================================================
    // STATE VARIABLES
    // ====================================================================

    /// @notice OmniRegistration contract (VALIDATOR_ROLE + KYC_ATTESTOR_ROLE)
    IOmniRegistrationProvisioner public omniRegistration;

    /// @notice OmniParticipation contract (VERIFIER_ROLE + score queries)
    IOmniParticipationProvisioner public omniParticipation;

    /// @notice OmniCore contract (AVALANCHE_VALIDATOR_ROLE + stake queries)
    IOmniCoreProvisioner public omniCore;

    /// @notice OmniValidatorRewards contract (BLOCKCHAIN_ROLE)
    /// @dev Stored as address to call grantRole/revokeRole via IAccessControl
    address public omniValidatorRewards;

    /// @notice PrivateDEX contract (MATCHER_ROLE, optional)
    /// @dev Set to address(0) if privacy contracts are not deployed
    address public privateDEX;

    /// @notice PrivateDEXSettlement contract (SETTLER_ROLE, optional)
    /// @dev Set to address(0) if privacy contracts are not deployed
    address public privateDEXSettlement;

    /// @notice Minimum participation score required (default: 50)
    uint256 public minParticipationScore;

    /// @notice Minimum KYC tier required (1-4, default: 4)
    uint8 public minKYCTier;

    /// @notice Minimum stake amount required (18 decimals, default: 1M XOM)
    uint256 public minStakeAmount;

    /// @notice Tracks which validators have been provisioned
    mapping(address => bool) public provisionedValidators;

    /// @notice Count of currently provisioned validators
    uint256 public provisionedCount;

    /**
     * @dev Storage gap for future upgrades.
     * @notice Reserves storage slots for adding new variables in
     *         upgrades without shifting inherited contract storage.
     */
    uint256[40] private __gap;

    // ====================================================================
    // EVENTS
    // ====================================================================

    /// @notice Emitted when a validator is provisioned (all roles granted)
    /// @param validator Address of the provisioned validator
    /// @param provisionedBy Address that called provisionValidator
    event ValidatorProvisioned(
        address indexed validator,
        address indexed provisionedBy
    );

    /// @notice Emitted when a validator is deprovisioned (all roles revoked)
    /// @param validator Address of the deprovisioned validator
    /// @param deprovisionedBy Address that called deprovisionValidator
    event ValidatorDeprovisioned(
        address indexed validator,
        address indexed deprovisionedBy
    );

    /// @notice Emitted when qualification thresholds are updated
    /// @param minScore New minimum participation score
    /// @param minTier New minimum KYC tier
    /// @param minStake New minimum stake amount
    event ThresholdsUpdated(
        uint256 indexed minScore,
        uint8 indexed minTier,
        uint256 minStake
    );

    /// @notice Emitted when contract references are updated
    event ContractsUpdated();

    // ====================================================================
    // ERRORS
    // ====================================================================

    /// @notice Address is zero
    error ZeroAddress();

    /// @notice Validator is already provisioned
    error AlreadyProvisioned();

    /// @notice Validator is not provisioned
    error NotProvisioned();

    /// @notice Validator does not meet participation score requirement
    /// @param score Current score
    /// @param required Minimum required score
    error InsufficientParticipationScore(
        uint256 score,
        uint256 required
    );

    /// @notice Validator does not meet KYC tier requirement
    /// @param currentTier Current KYC tier
    /// @param requiredTier Minimum required tier
    error InsufficientKYCTier(
        uint8 currentTier,
        uint8 requiredTier
    );

    /// @notice Validator does not meet staking requirement
    /// @param staked Current stake amount
    /// @param required Minimum required stake
    error InsufficientStake(
        uint256 staked,
        uint256 required
    );

    /// @notice Validator still meets all qualifications (cannot deprovision)
    error StillQualified();

    /// @notice Invalid KYC tier value (must be 0-4)
    error InvalidKYCTier();

    /// @notice Participation score exceeds maximum possible value (100)
    error InvalidParticipationScore();

    /// @notice Stake amount cannot be zero
    error ZeroStakeAmount();

    // ====================================================================
    // INITIALIZATION
    // ====================================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the ValidatorProvisioner
     * @param _owner Owner address (deployer, later governance)
     * @param _omniRegistration OmniRegistration contract address
     * @param _omniParticipation OmniParticipation contract address
     * @param _omniCore OmniCore contract address
     * @param _omniValidatorRewards OmniValidatorRewards contract address
     */
    function initialize(
        address _owner,
        address _omniRegistration,
        address _omniParticipation,
        address _omniCore,
        address _omniValidatorRewards
    ) external initializer {
        if (_owner == address(0)) revert ZeroAddress();
        if (_omniRegistration == address(0)) revert ZeroAddress();
        if (_omniParticipation == address(0)) revert ZeroAddress();
        if (_omniCore == address(0)) revert ZeroAddress();
        if (_omniValidatorRewards == address(0)) revert ZeroAddress();

        __Ownable2Step_init();
        __UUPSUpgradeable_init();
        _transferOwnership(_owner);

        omniRegistration =
            IOmniRegistrationProvisioner(_omniRegistration);
        omniParticipation =
            IOmniParticipationProvisioner(_omniParticipation);
        omniCore = IOmniCoreProvisioner(_omniCore);
        omniValidatorRewards = _omniValidatorRewards;

        // Default qualification thresholds
        // VP-M01 audit fix: KYC tier set to 4 (full verification)
        // to match project design spec (CLAUDE.md: "Top-tier KYC
        // (Level 4 - full verification)").
        minParticipationScore = 50;
        minKYCTier = 4;
        minStakeAmount = 1_000_000 ether; // 1M XOM (18 decimals)
    }

    // ====================================================================
    // PERMISSIONLESS PROVISIONING
    // ====================================================================

    /**
     * @notice Provision a qualified validator (anyone can call)
     * @dev Checks on-chain qualifications and grants all validator
     *      roles atomically. Reverts if any qualification is not met.
     *      The validator must:
     *      - Have participation score >= minParticipationScore
     *      - Have KYC tier >= minKYCTier
     *      - Have active stake >= minStakeAmount
     *      - Not already be provisioned
     * @param validator Address of the validator to provision
     */
    function provisionValidator(address validator) external {
        if (validator == address(0)) revert ZeroAddress();
        if (provisionedValidators[validator]) {
            revert AlreadyProvisioned();
        }

        // Check qualifications
        _checkQualifications(validator);

        // Grant all roles
        _grantAllRoles(validator);

        provisionedValidators[validator] = true;
        ++provisionedCount;

        emit ValidatorProvisioned(validator, msg.sender);
    }

    /**
     * @notice Deprovision a validator who no longer qualifies
     * @dev Anyone can call. Checks that at least one qualification
     *      has lapsed. Revokes all validator roles atomically.
     * @param validator Address of the validator to deprovision
     */
    function deprovisionValidator(address validator) external {
        if (!provisionedValidators[validator]) {
            revert NotProvisioned();
        }

        // Verify at least one qualification has lapsed
        if (_isFullyQualified(validator)) {
            revert StillQualified();
        }

        // Revoke all roles
        _revokeAllRoles(validator);

        provisionedValidators[validator] = false;
        --provisionedCount;

        emit ValidatorDeprovisioned(validator, msg.sender);
    }

    // ====================================================================
    // OWNER-ONLY PROVISIONING
    // ====================================================================

    /**
     * @notice Force-provision a validator (bypasses qualification checks)
     * @dev Owner-only. Used for seed validators during alpha phase who
     *      may not yet meet all on-chain qualification thresholds.
     * @param validator Address of the validator to force-provision
     */
    function forceProvision(address validator) external onlyOwner {
        if (validator == address(0)) revert ZeroAddress();
        if (provisionedValidators[validator]) {
            revert AlreadyProvisioned();
        }

        _grantAllRoles(validator);

        provisionedValidators[validator] = true;
        ++provisionedCount;

        emit ValidatorProvisioned(validator, msg.sender);
    }

    /**
     * @notice Force-deprovision a misbehaving validator
     * @dev Owner-only. Used to immediately remove a validator
     *      regardless of their qualification status.
     * @param validator Address of the validator to force-deprovision
     */
    function forceDeprovision(address validator) external onlyOwner {
        if (!provisionedValidators[validator]) {
            revert NotProvisioned();
        }

        _revokeAllRoles(validator);

        provisionedValidators[validator] = false;
        --provisionedCount;

        emit ValidatorDeprovisioned(validator, msg.sender);
    }

    // ====================================================================
    // ADMIN CONFIGURATION
    // ====================================================================

    /**
     * @notice Update qualification thresholds
     * @dev VP-M02 audit fix: validates bounds on all parameters.
     *      - _minParticipationScore must be <= 100 (max possible score)
     *      - _minKYCTier must be <= 4 (max KYC tier)
     *      - _minStakeAmount must be > 0 (prevents bypassing stake check)
     * @param _minParticipationScore Minimum participation score (0-100)
     * @param _minKYCTier Minimum KYC tier (0-4)
     * @param _minStakeAmount Minimum stake amount (18 decimals, non-zero)
     */
    function setThresholds(
        uint256 _minParticipationScore,
        uint8 _minKYCTier,
        uint256 _minStakeAmount
    ) external onlyOwner {
        if (_minParticipationScore > 100) {
            revert InvalidParticipationScore();
        }
        if (_minKYCTier > 4) revert InvalidKYCTier();
        if (_minStakeAmount == 0) revert ZeroStakeAmount();

        minParticipationScore = _minParticipationScore;
        minKYCTier = _minKYCTier;
        minStakeAmount = _minStakeAmount;

        emit ThresholdsUpdated(
            _minParticipationScore,
            _minKYCTier,
            _minStakeAmount
        );
    }

    /**
     * @notice Update contract references
     * @dev VP-M03 audit fix: documents migration procedure.
     *      Used if target contracts are redeployed. Does NOT
     *      re-provision existing validators on the new contracts
     *      and does NOT revoke roles from old contracts.
     *
     *      MIGRATION PROCEDURE (must follow this order):
     *      1. Call `forceDeprovision()` for every provisioned
     *         validator BEFORE changing contract references. This
     *         revokes roles on the current (old) contracts.
     *      2. Call `setContracts()` to point to the new contracts.
     *      3. Ensure this contract has PROVISIONER_ROLE (or
     *         equivalent admin role) on each new target contract.
     *      4. Call `forceProvision()` or let validators call
     *         `provisionValidator()` to re-provision on the new
     *         contracts.
     *
     *      WARNING: Skipping step 1 orphans roles on old contracts.
     *      Validators would retain VALIDATOR_ROLE, KYC_ATTESTOR_ROLE,
     *      VERIFIER_ROLE, and BLOCKCHAIN_ROLE on the old contracts
     *      with no way to revoke them through this contract.
     *
     * @param _omniRegistration New OmniRegistration address
     * @param _omniParticipation New OmniParticipation address
     * @param _omniCore New OmniCore address
     * @param _omniValidatorRewards New OmniValidatorRewards address
     */
    function setContracts(
        address _omniRegistration,
        address _omniParticipation,
        address _omniCore,
        address _omniValidatorRewards
    ) external onlyOwner {
        if (_omniRegistration == address(0)) revert ZeroAddress();
        if (_omniParticipation == address(0)) revert ZeroAddress();
        if (_omniCore == address(0)) revert ZeroAddress();
        if (_omniValidatorRewards == address(0)) revert ZeroAddress();

        omniRegistration =
            IOmniRegistrationProvisioner(_omniRegistration);
        omniParticipation =
            IOmniParticipationProvisioner(_omniParticipation);
        omniCore = IOmniCoreProvisioner(_omniCore);
        omniValidatorRewards = _omniValidatorRewards;

        emit ContractsUpdated();
    }

    /**
     * @notice Set optional privacy contract references
     * @dev Set to address(0) to disable privacy role management.
     *      Can be called later when privacy contracts are deployed.
     * @param _privateDEX PrivateDEX contract address (0 = disabled)
     * @param _privateDEXSettlement PrivateDEXSettlement address (0 = disabled)
     */
    function setPrivacyContracts(
        address _privateDEX,
        address _privateDEXSettlement
    ) external onlyOwner {
        privateDEX = _privateDEX;
        privateDEXSettlement = _privateDEXSettlement;

        emit ContractsUpdated();
    }

    // ====================================================================
    // VIEW FUNCTIONS
    // ====================================================================

    /**
     * @notice Check if a validator is currently fully qualified
     * @param validator Address to check
     * @return True if all qualifications are met
     */
    function isQualified(
        address validator
    ) external view returns (bool) {
        return _isFullyQualified(validator);
    }

    /**
     * @notice Get the current KYC tier of an address (0-4)
     * @param user Address to check
     * @return tier KYC tier (0 = none, 4 = full)
     */
    function getKYCTier(
        address user
    ) external view returns (uint8 tier) {
        return _getKYCTier(user);
    }

    // ====================================================================
    // INTERNAL FUNCTIONS
    // ====================================================================

    /**
     * @notice Check all qualifications and revert if any are unmet
     * @param validator Address to check
     */
    function _checkQualifications(address validator) internal view {
        // Check participation score
        uint256 score = omniParticipation.getTotalScore(validator);
        if (score < minParticipationScore) {
            revert InsufficientParticipationScore(
                score,
                minParticipationScore
            );
        }

        // Check KYC tier
        uint8 currentTier = _getKYCTier(validator);
        if (currentTier < minKYCTier) {
            revert InsufficientKYCTier(currentTier, minKYCTier);
        }

        // Check staking
        IOmniCoreProvisioner.Stake memory stake =
            omniCore.getStake(validator);
        if (!stake.active || stake.amount < minStakeAmount) {
            revert InsufficientStake(
                stake.active ? stake.amount : 0,
                minStakeAmount
            );
        }
    }

    /**
     * @notice Check if validator meets ALL qualifications (non-reverting)
     * @param validator Address to check
     * @return True if all qualifications are met
     */
    function _isFullyQualified(
        address validator
    ) internal view returns (bool) {
        // Check participation score
        uint256 score = omniParticipation.getTotalScore(validator);
        if (score < minParticipationScore) return false;

        // Check KYC tier
        uint8 currentTier = _getKYCTier(validator);
        if (currentTier < minKYCTier) return false;

        // Check staking
        IOmniCoreProvisioner.Stake memory stake =
            omniCore.getStake(validator);
        if (!stake.active || stake.amount < minStakeAmount) {
            return false;
        }

        return true;
    }

    /**
     * @notice Get the current KYC tier of an address
     * @param user Address to check
     * @return tier KYC tier (0-4)
     */
    function _getKYCTier(
        address user
    ) internal view returns (uint8 tier) {
        if (omniRegistration.hasKycTier4(user)) return 4;
        if (omniRegistration.hasKycTier3(user)) return 3;
        if (omniRegistration.hasKycTier2(user)) return 2;
        if (omniRegistration.hasKycTier1(user)) return 1;
        return 0;
    }

    /**
     * @notice Grant all validator roles across all contracts
     * @param validator Address to grant roles to
     */
    function _grantAllRoles(address validator) internal {
        // OmniRegistration: VALIDATOR_ROLE + KYC_ATTESTOR_ROLE
        IAccessControl(address(omniRegistration)).grantRole(
            VALIDATOR_ROLE, validator
        );
        IAccessControl(address(omniRegistration)).grantRole(
            KYC_ATTESTOR_ROLE, validator
        );

        // OmniParticipation: VERIFIER_ROLE
        IAccessControl(address(omniParticipation)).grantRole(
            VERIFIER_ROLE, validator
        );

        // OmniValidatorRewards: BLOCKCHAIN_ROLE
        IAccessControl(omniValidatorRewards).grantRole(
            BLOCKCHAIN_ROLE, validator
        );

        // OmniCore: AVALANCHE_VALIDATOR_ROLE (via provisionValidator)
        omniCore.provisionValidator(validator);

        // Privacy contracts (optional)
        if (privateDEX != address(0)) {
            IAccessControl(privateDEX).grantRole(
                MATCHER_ROLE, validator
            );
        }
        if (privateDEXSettlement != address(0)) {
            IAccessControl(privateDEXSettlement).grantRole(
                SETTLER_ROLE, validator
            );
        }
    }

    /**
     * @notice Revoke all validator roles across all contracts
     * @param validator Address to revoke roles from
     */
    function _revokeAllRoles(address validator) internal {
        // OmniRegistration: VALIDATOR_ROLE + KYC_ATTESTOR_ROLE
        IAccessControl(address(omniRegistration)).revokeRole(
            VALIDATOR_ROLE, validator
        );
        IAccessControl(address(omniRegistration)).revokeRole(
            KYC_ATTESTOR_ROLE, validator
        );

        // OmniParticipation: VERIFIER_ROLE
        IAccessControl(address(omniParticipation)).revokeRole(
            VERIFIER_ROLE, validator
        );

        // OmniValidatorRewards: BLOCKCHAIN_ROLE
        IAccessControl(omniValidatorRewards).revokeRole(
            BLOCKCHAIN_ROLE, validator
        );

        // OmniCore: AVALANCHE_VALIDATOR_ROLE (via deprovisionValidator)
        omniCore.deprovisionValidator(validator);

        // Privacy contracts (optional)
        if (privateDEX != address(0)) {
            IAccessControl(privateDEX).revokeRole(
                MATCHER_ROLE, validator
            );
        }
        if (privateDEXSettlement != address(0)) {
            IAccessControl(privateDEXSettlement).revokeRole(
                SETTLER_ROLE, validator
            );
        }
    }

    /**
     * @notice Authorize contract upgrade (UUPS pattern)
     * @dev Only owner can authorize upgrades.
     * @param newImplementation Address of new implementation
     */
    function _authorizeUpgrade(
        address newImplementation // solhint-disable-line no-unused-vars
    ) internal override onlyOwner {
        // Owner-gated via modifier
    }
}
