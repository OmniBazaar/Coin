// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title QualificationOracle
 * @notice Ultra-lean oracle storing ONLY boolean qualification flags
 * @custom:deprecated Superseded by QualificationOracle in contracts/
 * @dev Stores minimal data on-chain - full PoP scoring happens off-chain
 *
 * Architecture Principle: ULTRA-LEAN
 * - Stores ONLY boolean qualified flags (1 bit per address)
 * - NO PoP scores stored on-chain
 * - NO KYC data stored on-chain
 * - Qualification determined off-chain by verifier service
 *
 * Off-Chain Qualification Criteria (enforced by verifier):
 * - PoP score >= 50 points (from ParticipationScoreService)
 * - KYC tier >= 3 (full verification)
 * - Minimum stake >= 1,000,000 XOM
 * - Good reputation (no penalties)
 */
contract QualificationOracle is
    Initializable,
    OwnableUpgradeable,
    UUPSUpgradeable
{
    // ========== STATE VARIABLES ==========

    /// @notice Authorized verifier address (TypeScript service)
    address public verifier;

    /// @notice Qualification status (address => qualified)
    mapping(address => bool) public qualified;

    /// @notice Qualification timestamp (for auditing)
    mapping(address => uint256) public qualifiedAt;

    /// @notice Disqualification reason hashes (for transparency)
    mapping(address => bytes32) public disqualificationReason;

    // ========== EVENTS ==========

    event Qualified(address indexed user, uint256 timestamp);

    event Disqualified(address indexed user, bytes32 reason);

    event VerifierChanged(
        address indexed oldVerifier,
        address indexed newVerifier
    );

    // ========== ERRORS ==========

    error OnlyVerifier();
    error AlreadyQualified(address user);
    error NotQualified(address user);

    // ========== INITIALIZATION ==========

    /**
     * @notice Initialize the contract (UUPS pattern)
     * @param _verifier Initial verifier address
     */
    function initialize(address _verifier) public initializer {
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();

        verifier = _verifier;
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

    // ========== MODIFIERS ==========

    modifier onlyVerifier() {
        if (msg.sender != verifier) {
            revert OnlyVerifier();
        }
        _;
    }

    // ========== ADMIN FUNCTIONS ==========

    /**
     * @notice Change verifier address
     * @param newVerifier New verifier address
     */
    function setVerifier(address newVerifier) external onlyOwner {
        emit VerifierChanged(verifier, newVerifier);
        verifier = newVerifier;
    }

    // ========== QUALIFICATION MANAGEMENT ==========

    /**
     * @notice Mark address as qualified (verifier only)
     * @param user Address to qualify
     *
     * Called by off-chain verifier after checking:
     * - PoP score >= 50
     * - KYC tier >= 3
     * - Stake >= 1M XOM
     */
    function setQualified(address user) external onlyVerifier {
        qualified[user] = true;
        qualifiedAt[user] = block.timestamp;

        // Clear any previous disqualification reason
        delete disqualificationReason[user];

        emit Qualified(user, block.timestamp);
    }

    /**
     * @notice Batch qualify multiple addresses (gas efficient)
     * @param users Array of addresses to qualify
     */
    function batchSetQualified(address[] calldata users) external onlyVerifier {
        uint256 timestamp = block.timestamp;

        for (uint256 i = 0; i < users.length; i++) {
            address user = users[i];
            qualified[user] = true;
            qualifiedAt[user] = timestamp;
            delete disqualificationReason[user];

            emit Qualified(user, timestamp);
        }
    }

    /**
     * @notice Remove qualification (verifier only)
     * @param user Address to disqualify
     * @param reason Hash of disqualification reason (stored on IPFS)
     *
     * Reasons include:
     * - PoP score dropped below 50
     * - KYC downgraded below tier 3
     * - Reputation penalties
     * - Stake withdrawn below minimum
     */
    function setDisqualified(address user, bytes32 reason)
        external
        onlyVerifier
    {
        qualified[user] = false;
        disqualificationReason[user] = reason;

        emit Disqualified(user, reason);
    }

    /**
     * @notice Batch disqualify multiple addresses
     * @param users Array of addresses to disqualify
     * @param reasons Array of reason hashes
     */
    function batchSetDisqualified(
        address[] calldata users,
        bytes32[] calldata reasons
    ) external onlyVerifier {
        require(users.length == reasons.length, "Length mismatch");

        for (uint256 i = 0; i < users.length; i++) {
            qualified[users[i]] = false;
            disqualificationReason[users[i]] = reasons[i];

            emit Disqualified(users[i], reasons[i]);
        }
    }

    // ========== VIEW FUNCTIONS ==========

    /**
     * @notice Check if address is qualified to be validator
     * @param user Address to check
     * @return True if qualified
     */
    function isQualified(address user) external view returns (bool) {
        return qualified[user];
    }

    /**
     * @notice Get qualification details
     * @param user Address to check
     * @return Qualification status
     * @return Qualification timestamp (0 if not qualified)
     * @return Disqualification reason hash (0 if qualified)
     */
    function getQualificationDetails(address user)
        external
        view
        returns (
            bool,
            uint256,
            bytes32
        )
    {
        return (qualified[user], qualifiedAt[user], disqualificationReason[user]);
    }

    /**
     * @notice Batch check qualifications
     * @param users Array of addresses to check
     * @return qualifications Array of qualification statuses
     */
    function batchIsQualified(address[] calldata users)
        external
        view
        returns (bool[] memory qualifications)
    {
        qualifications = new bool[](users.length);

        for (uint256 i = 0; i < users.length; i++) {
            qualifications[i] = qualified[users[i]];
        }
    }
}
