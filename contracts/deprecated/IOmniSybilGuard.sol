// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IOmniSybilGuard
 * @author OmniBazaar Team
 * @notice Interface for OmniSybilGuard contract
 * @custom:deprecated Superseded by OmniRegistration uniqueness enforcement
 * @dev Defines the public API for Sybil protection and device fingerprinting
 */
interface IOmniSybilGuard {
    // ═══════════════════════════════════════════════════════════════════════
    //                              STRUCTS
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Sybil report data structure
     * @param reporter Address who submitted the report
     * @param suspect Address suspected of being Sybil
     * @param evidenceHash IPFS hash of evidence
     * @param timestamp When report was submitted
     * @param stake Amount staked by reporter
     * @param resolved Whether report has been resolved
     * @param valid Whether report was ruled valid
     */
    struct SybilReport {
        address reporter;
        address suspect;
        bytes32 evidenceHash;
        uint256 timestamp;
        uint256 stake;
        bool resolved;
        bool valid;
    }

    /**
     * @notice Device fingerprint data structure
     * @param fingerprintHash Hash of device fingerprint
     * @param timestamp When first registered
     * @param registrationCount Number of users registered from device
     */
    struct DeviceFingerprint {
        bytes32 fingerprintHash;
        uint256 timestamp;
        uint256 registrationCount;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                              EVENTS
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Emitted when a Sybil report is submitted
     * @param reportId Unique report identifier
     * @param suspect Suspected Sybil address
     * @param reporter Reporter address
     */
    event SybilReported(
        bytes32 indexed reportId,
        address indexed suspect,
        address indexed reporter
    );

    /**
     * @notice Emitted when a Sybil report is resolved
     * @param reportId Resolved report ID
     * @param valid Whether report was valid
     */
    event SybilResolved(bytes32 indexed reportId, bool valid);

    /**
     * @notice Emitted when an account is flagged
     * @param account Flagged account
     * @param reportId Report that caused flagging
     */
    event AccountFlagged(address indexed account, bytes32 indexed reportId);

    /**
     * @notice Emitted when a device is registered
     * @param fingerprint Device fingerprint hash
     * @param user User registered on device
     */
    event DeviceRegistered(bytes32 indexed fingerprint, address indexed user);

    // ═══════════════════════════════════════════════════════════════════════
    //                              ERRORS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Device limit exceeded
    error DeviceLimitExceeded();

    /// @notice Account is flagged
    error AccountIsFlagged();

    /// @notice Report not found
    error ReportNotFound();

    /// @notice Challenge period active
    error ChallengePeriodActive();

    /// @notice Already resolved
    error AlreadyResolved();

    /// @notice Insufficient stake
    error InsufficientStake();

    /// @notice Insufficient reward pool
    error InsufficientRewardPool();

    /// @notice Cannot report self
    error CannotReportSelf();

    // ═══════════════════════════════════════════════════════════════════════
    //                              FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Register device fingerprint for a user
     * @param user The user being registered
     * @param fingerprintHash Hash of device fingerprint
     */
    function registerDevice(address user, bytes32 fingerprintHash) external;

    /**
     * @notice Report a suspected Sybil account
     * @param suspect The suspected account
     * @param evidenceHash IPFS hash of evidence
     */
    function reportSybil(address suspect, bytes32 evidenceHash) external payable;

    /**
     * @notice Resolve a Sybil report
     * @param reportId The report to resolve
     * @param isValid Whether report is valid
     */
    function resolveReport(bytes32 reportId, bool isValid) external;

    /**
     * @notice Fund the reward pool
     */
    function fundRewardPool() external payable;

    /**
     * @notice Check if account is flagged
     * @param account The account to check
     * @return True if flagged
     */
    function isFlagged(address account) external view returns (bool);

    /**
     * @notice Get users for a device
     * @param fingerprint Device fingerprint hash
     * @return Array of user addresses
     */
    function getUsersForDevice(
        bytes32 fingerprint
    ) external view returns (address[] memory);

    /**
     * @notice Get device registration count
     * @param fingerprint Device fingerprint hash
     * @return Registration count
     */
    function getDeviceRegistrationCount(
        bytes32 fingerprint
    ) external view returns (uint256);

    /**
     * @notice Get report details
     * @param reportId Report ID
     * @return Report struct
     */
    function getReport(
        bytes32 reportId
    ) external view returns (SybilReport memory);

    /**
     * @notice Check if report can be resolved
     * @param reportId Report ID
     * @return True if resolvable
     */
    function canResolveReport(bytes32 reportId) external view returns (bool);

    /**
     * @notice Get challenge time remaining
     * @param reportId Report ID
     * @return Seconds remaining
     */
    function getChallengeTimeRemaining(
        bytes32 reportId
    ) external view returns (uint256);

    /**
     * @notice Get report stake requirement
     * @return Stake in wei
     */
    function REPORT_STAKE() external view returns (uint256);

    /**
     * @notice Get report reward amount
     * @return Reward in wei
     */
    function REPORT_REWARD() external view returns (uint256);

    /**
     * @notice Get challenge period duration
     * @return Duration in seconds
     */
    function CHALLENGE_PERIOD() external view returns (uint256);

    /**
     * @notice Get max users per device
     * @return Maximum count
     */
    function MAX_USERS_PER_DEVICE() external view returns (uint256);

    /**
     * @notice Get reward pool balance
     * @return Balance in wei
     */
    function rewardPool() external view returns (uint256);

    /**
     * @notice Get total reports count
     * @return Total count
     */
    function totalReports() external view returns (uint256);

    /**
     * @notice Get confirmed Sybil cases count
     * @return Confirmed count
     */
    function confirmedSybilCases() external view returns (uint256);
}
