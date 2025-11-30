// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

/**
 * @title OmniSybilGuard
 * @author OmniBazaar Team
 * @notice Additional Sybil protection for gas-free OmniBazaar environment
 * @dev Implements device fingerprinting, community reporting, and behavioral analysis
 *
 * Problem: Since OmniBazaar abstracts gas fees, traditional gas-based Sybil
 * protection is ineffective. This contract provides additional protection layers:
 *
 * 1. Device Fingerprinting - Limit registrations per device
 * 2. Community Reporting - Stake-based Sybil report system
 * 3. Challenge Period - Time for suspects to defend themselves
 *
 * Economics:
 * - Reporters stake REPORT_STAKE (1000 XOM) to submit report
 * - If valid: Reporter gets stake back + REPORT_REWARD (5000 XOM)
 * - If invalid: Reporter loses stake (sent to suspect)
 */
contract OmniSybilGuard is
    AccessControlUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable
{
    // ═══════════════════════════════════════════════════════════════════════
    //                              CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Role for validators who can register devices
    bytes32 public constant REPORTER_ROLE = keccak256("REPORTER_ROLE");

    /// @notice Role for judges who resolve Sybil reports
    bytes32 public constant JUDGE_ROLE = keccak256("JUDGE_ROLE");

    /// @notice Stake required to submit a Sybil report (1000 XOM)
    uint256 public constant REPORT_STAKE = 1000 * 10 ** 18;

    /// @notice Reward for valid Sybil report (5000 XOM)
    uint256 public constant REPORT_REWARD = 5000 * 10 ** 18;

    /// @notice Challenge period before report can be resolved (72 hours)
    uint256 public constant CHALLENGE_PERIOD = 72 hours;

    /// @notice Maximum users allowed per device (allows family sharing)
    uint256 public constant MAX_USERS_PER_DEVICE = 2;

    // ═══════════════════════════════════════════════════════════════════════
    //                              STORAGE
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Sybil report data structure
     * @param reporter Address who submitted the report
     * @param suspect Address suspected of being Sybil
     * @param evidenceHash IPFS hash of evidence documentation
     * @param timestamp When the report was submitted
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

    /// @notice Mapping from report ID to report data
    mapping(bytes32 => SybilReport) public reports;

    /// @notice Mapping of flagged (Sybil) accounts
    mapping(address => bool) public flaggedAccounts;

    /// @notice Mapping from fingerprint hash to device data
    mapping(bytes32 => DeviceFingerprint) public deviceFingerprints;

    /// @notice Mapping from fingerprint to list of user addresses
    mapping(bytes32 => address[]) public deviceToUsers;

    /// @notice Total number of Sybil reports submitted
    uint256 public totalReports;

    /// @notice Total number of confirmed Sybil cases
    uint256 public confirmedSybilCases;

    /// @notice Reward pool for Sybil reporters (funded by admin)
    uint256 public rewardPool;

    // ═══════════════════════════════════════════════════════════════════════
    //                              EVENTS
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Emitted when a Sybil report is submitted
     * @param reportId Unique identifier for the report
     * @param suspect Address of suspected Sybil
     * @param reporter Address who submitted report
     */
    event SybilReported(
        bytes32 indexed reportId,
        address indexed suspect,
        address indexed reporter
    );

    /**
     * @notice Emitted when a Sybil report is resolved
     * @param reportId The resolved report ID
     * @param valid Whether the report was ruled valid
     */
    event SybilResolved(bytes32 indexed reportId, bool valid);

    /**
     * @notice Emitted when an account is flagged as Sybil
     * @param account The flagged account
     * @param reportId The report that caused flagging
     */
    event AccountFlagged(address indexed account, bytes32 indexed reportId);

    /**
     * @notice Emitted when a device is registered
     * @param fingerprint Hash of device fingerprint
     * @param user User address registered on device
     */
    event DeviceRegistered(bytes32 indexed fingerprint, address indexed user);

    /**
     * @notice Emitted when reward pool is funded
     * @param funder Address that funded the pool
     * @param amount Amount added to pool
     */
    event RewardPoolFunded(address indexed funder, uint256 amount);

    // ═══════════════════════════════════════════════════════════════════════
    //                              ERRORS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Device has reached maximum user limit
    error DeviceLimitExceeded();

    /// @notice Account has been flagged as Sybil
    error AccountIsFlagged();

    /// @notice Report does not exist
    error ReportNotFound();

    /// @notice Challenge period has not elapsed
    error ChallengePeriodActive();

    /// @notice Report has already been resolved
    error AlreadyResolved();

    /// @notice Insufficient stake provided
    error InsufficientStake();

    /// @notice Insufficient reward pool balance
    error InsufficientRewardPool();

    /// @notice Cannot report yourself
    error CannotReportSelf();

    /// @notice ETH transfer/payout failed
    error PayoutFailed();

    /// @notice Must send funds
    error MustSendFunds();

    /// @notice Account already has pending report
    error ReportAlreadyPending();

    // ═══════════════════════════════════════════════════════════════════════
    //                           INITIALIZATION
    // ═══════════════════════════════════════════════════════════════════════

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the contract
     * @dev Sets up access control and grants admin role to deployer
     */
    function initialize() public initializer {
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                        DEVICE FINGERPRINTING
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Register device fingerprint for a user
     * @param user The user being registered
     * @param fingerprintHash Hash of device fingerprint
     * @dev Called during registration. Limits users per device to prevent Sybil.
     *
     * Security:
     * - Each device can only register MAX_USERS_PER_DEVICE users
     * - Flagged accounts cannot register
     * - Only REPORTER_ROLE can call (validators)
     */
    function registerDevice(
        address user,
        bytes32 fingerprintHash
    ) external onlyRole(REPORTER_ROLE) {
        if (flaggedAccounts[user]) revert AccountIsFlagged();

        DeviceFingerprint storage fp = deviceFingerprints[fingerprintHash];

        if (fp.timestamp == 0) {
            // New device
            fp.fingerprintHash = fingerprintHash;
            fp.timestamp = block.timestamp;
            fp.registrationCount = 1;
        } else {
            // Existing device - check limit
            if (fp.registrationCount >= MAX_USERS_PER_DEVICE) {
                revert DeviceLimitExceeded();
            }
            ++fp.registrationCount;
        }

        deviceToUsers[fingerprintHash].push(user);

        emit DeviceRegistered(fingerprintHash, user);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                         SYBIL REPORTING
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Report a suspected Sybil account
     * @param suspect The suspected Sybil account address
     * @param evidenceHash IPFS hash of evidence documentation
     * @dev Requires stake of REPORT_STAKE. Stake returned + reward if valid.
     *
     * Process:
     * 1. Reporter stakes REPORT_STAKE
     * 2. Challenge period (72h) allows suspect to defend
     * 3. Judge resolves after challenge period
     * 4. If valid: Reporter gets stake + reward, suspect flagged
     * 5. If invalid: Stake sent to suspect as compensation
     */
    function reportSybil(
        address suspect,
        bytes32 evidenceHash
    ) external payable nonReentrant {
        if (msg.value < REPORT_STAKE) revert InsufficientStake();
        if (suspect == msg.sender) revert CannotReportSelf();

        bytes32 reportId = keccak256(
            abi.encodePacked(suspect, msg.sender, block.timestamp)
        );

        reports[reportId] = SybilReport({
            reporter: msg.sender,
            suspect: suspect,
            evidenceHash: evidenceHash,
            timestamp: block.timestamp,
            stake: msg.value,
            resolved: false,
            valid: false
        });

        ++totalReports;

        emit SybilReported(reportId, suspect, msg.sender);
    }

    /**
     * @notice Resolve a Sybil report after challenge period
     * @param reportId The report to resolve
     * @param isValid Whether the report is valid (suspect is Sybil)
     * @dev Only callable by JUDGE_ROLE after CHALLENGE_PERIOD.
     *
     * If valid:
     * - Account is flagged as Sybil
     * - Reporter receives stake + reward from pool
     *
     * If invalid:
     * - Reporter's stake sent to suspect
     * - Reporter loses stake
     */
    function resolveReport(
        bytes32 reportId,
        bool isValid
    ) external onlyRole(JUDGE_ROLE) nonReentrant {
        SybilReport storage report = reports[reportId];

        if (report.timestamp == 0) revert ReportNotFound();
        if (report.resolved) revert AlreadyResolved();
        if (block.timestamp < report.timestamp + CHALLENGE_PERIOD) {
            revert ChallengePeriodActive();
        }

        report.resolved = true;
        report.valid = isValid;

        if (isValid) {
            // Flag the account
            flaggedAccounts[report.suspect] = true;
            ++confirmedSybilCases;
            emit AccountFlagged(report.suspect, reportId);

            // Check reward pool has funds
            if (rewardPool < REPORT_REWARD) revert InsufficientRewardPool();
            rewardPool -= REPORT_REWARD;

            // Return stake + reward to reporter
            uint256 totalPayout = report.stake + REPORT_REWARD;
            (bool success, ) = report.reporter.call{value: totalPayout}("");
            if (!success) revert PayoutFailed();
        } else {
            // Slash reporter's stake (goes to suspect as compensation)
            (bool success, ) = report.suspect.call{value: report.stake}("");
            if (!success) revert PayoutFailed();
        }

        emit SybilResolved(reportId, isValid);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                          ADMIN FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Fund the reward pool for Sybil reporters
     * @dev Only callable by admin. Anyone can send funds via fundRewardPool.
     */
    function fundRewardPool() external payable {
        if (msg.value == 0) revert MustSendFunds();
        rewardPool += msg.value;
        emit RewardPoolFunded(msg.sender, msg.value);
    }

    /**
     * @notice Manually flag an account (emergency use)
     * @param account The account to flag
     * @dev Only callable by JUDGE_ROLE for emergency situations
     */
    function manualFlag(address account) external onlyRole(JUDGE_ROLE) {
        flaggedAccounts[account] = true;
        emit AccountFlagged(account, bytes32(0));
    }

    /**
     * @notice Remove flag from account (appeal success)
     * @param account The account to unflag
     * @dev Only callable by DEFAULT_ADMIN_ROLE after successful appeal
     */
    function unflagAccount(
        address account
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        flaggedAccounts[account] = false;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                          VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Check if account is flagged as Sybil
     * @param account The account to check
     * @return True if flagged
     */
    function isFlagged(address account) external view returns (bool) {
        return flaggedAccounts[account];
    }

    /**
     * @notice Get users registered from a device
     * @param fingerprint The device fingerprint hash
     * @return Array of user addresses
     */
    function getUsersForDevice(
        bytes32 fingerprint
    ) external view returns (address[] memory) {
        return deviceToUsers[fingerprint];
    }

    /**
     * @notice Get device registration count
     * @param fingerprint The device fingerprint hash
     * @return Number of users registered from device
     */
    function getDeviceRegistrationCount(
        bytes32 fingerprint
    ) external view returns (uint256) {
        return deviceFingerprints[fingerprint].registrationCount;
    }

    /**
     * @notice Get report details
     * @param reportId The report ID
     * @return Report struct
     */
    function getReport(
        bytes32 reportId
    ) external view returns (SybilReport memory) {
        return reports[reportId];
    }

    /**
     * @notice Check if report can be resolved
     * @param reportId The report ID
     * @return True if challenge period elapsed and not resolved
     */
    function canResolveReport(bytes32 reportId) external view returns (bool) {
        SybilReport storage report = reports[reportId];
        return
            report.timestamp != 0 &&
            !report.resolved &&
            block.timestamp >= report.timestamp + CHALLENGE_PERIOD;
    }

    /**
     * @notice Get time remaining in challenge period
     * @param reportId The report ID
     * @return Seconds remaining (0 if period elapsed)
     */
    function getChallengeTimeRemaining(
        bytes32 reportId
    ) external view returns (uint256) {
        SybilReport storage report = reports[reportId];
        if (report.timestamp == 0) return 0;

        uint256 endTime = report.timestamp + CHALLENGE_PERIOD;
        if (block.timestamp >= endTime) return 0;

        return endTime - block.timestamp;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                            INTERNAL
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Authorize contract upgrade
     * @param newImplementation Address of new implementation
     * @dev Only callable by DEFAULT_ADMIN_ROLE
     */
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    /**
     * @notice Receive function to accept ETH for reward pool
     */
    receive() external payable {
        rewardPool += msg.value;
        emit RewardPoolFunded(msg.sender, msg.value);
    }
}
