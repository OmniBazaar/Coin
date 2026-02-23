// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {
    AccessControlUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {
    UUPSUpgradeable
} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {
    ReentrancyGuardUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title OmniSybilGuard
 * @author OmniBazaar Team
 * @notice Additional Sybil protection for gas-free OmniBazaar environment.
 * @custom:deprecated Superseded by OmniRegistration uniqueness enforcement
 * @dev Implements device fingerprinting, community reporting, and behavioral
 *      analysis using XOM ERC-20 tokens for all stake and reward operations.
 *
 * Problem: Since OmniBazaar abstracts gas fees, traditional gas-based Sybil
 * protection is ineffective. This contract provides additional protection layers:
 *
 * 1. Device Fingerprinting - Limit registrations per device
 * 2. Community Reporting - Stake-based Sybil report system
 * 3. Challenge Period - Time for suspects to defend themselves
 *
 * Economics (all in XOM ERC-20):
 * - Reporters stake REPORT_STAKE (1000 XOM) to submit report
 * - If valid: Reporter gets stake back + REPORT_REWARD (5000 XOM)
 * - If invalid: Reporter loses stake (sent to suspect)
 *
 * Pull-based withdrawal pattern: all payouts are credited to
 * `pendingWithdrawals` and claimed via `withdraw()`, preventing
 * griefing by contracts that reject token transfers.
 */
contract OmniSybilGuard is
    AccessControlUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for IERC20;

    // ═══════════════════════════════════════════════════════════════════════
    //                           TYPE DECLARATIONS
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Sybil report data structure.
     * @param reporter Address who submitted the report.
     * @param resolved Whether report has been resolved.
     * @param valid Whether report was ruled valid.
     * @param suspect Address suspected of being Sybil.
     * @param evidenceHash IPFS hash of evidence documentation.
     * @param stake Amount staked by reporter.
     * @param timestamp When the report was submitted.
     */
    struct SybilReport {
        address reporter; // slot 1: 20 bytes
        bool resolved;    // slot 1: +1 byte (packed with reporter)
        bool valid;       // slot 1: +1 byte (packed with reporter)
        address suspect;  // slot 2: 20 bytes
        bytes32 evidenceHash; // slot 3: 32 bytes
        uint256 stake;    // slot 4: 32 bytes
        uint256 timestamp; // slot 5: 32 bytes
    }

    /**
     * @notice Device fingerprint data structure.
     * @param fingerprintHash Hash of device fingerprint.
     * @param registrationCount Number of users registered from device.
     * @param timestamp When first registered.
     */
    struct DeviceFingerprint {
        bytes32 fingerprintHash;
        uint256 registrationCount;
        uint256 timestamp;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                              CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Role for validators who can register devices.
    bytes32 public constant DEVICE_REGISTRAR_ROLE =
        keccak256("DEVICE_REGISTRAR_ROLE");

    /// @notice Role for judges who resolve Sybil reports.
    bytes32 public constant JUDGE_ROLE = keccak256("JUDGE_ROLE");

    /// @notice Stake required to submit a Sybil report (1000 XOM).
    uint256 public constant REPORT_STAKE = 1000 * 10 ** 18;

    /// @notice Reward for valid Sybil report (5000 XOM).
    uint256 public constant REPORT_REWARD = 5000 * 10 ** 18;

    /// @notice Challenge period before report can be resolved (72 hours).
    uint256 public constant CHALLENGE_PERIOD = 72 hours;

    /// @notice Maximum users allowed per device (allows family sharing).
    uint256 public constant MAX_USERS_PER_DEVICE = 2;

    /// @notice Cooldown period after unflagging before new reports (30 days).
    uint256 public constant UNFLAG_COOLDOWN = 30 days;

    /// @notice Minimum judge votes required to resolve a report (M-04).
    uint256 public constant MIN_JUDGE_VOTES = 2;

    // ═══════════════════════════════════════════════════════════════════════
    //                           STATE VARIABLES
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice XOM token used for all stake and reward operations.
    IERC20 public xomToken;

    /// @notice Mapping from report ID to report data.
    mapping(bytes32 => SybilReport) public reports;

    /// @notice Mapping of flagged (Sybil) accounts.
    mapping(address => bool) public flaggedAccounts;

    /// @notice Mapping from fingerprint hash to device data.
    mapping(bytes32 => DeviceFingerprint) public deviceFingerprints;

    /// @notice Mapping from fingerprint to list of user addresses.
    mapping(bytes32 => address[]) public deviceToUsers;

    /// @notice Total number of Sybil reports submitted.
    uint256 public totalReports;

    /// @notice Total number of confirmed Sybil cases.
    uint256 public confirmedSybilCases;

    /// @notice Reward pool for Sybil reporters (funded by admin).
    uint256 public rewardPool;

    /// @notice Pull-based withdrawal balances for stake/reward payouts.
    mapping(address => uint256) public pendingWithdrawals;

    /// @notice Deferred rewards when pool was exhausted at resolution time.
    mapping(address => uint256) public pendingRewards;

    /// @notice Timestamp when an account was last unflagged (cooldown).
    mapping(address => uint256) public unflaggedAt;

    /// @notice Judge votes per report (M-04: multi-judge requirement).
    mapping(bytes32 => uint256) public reportValidVotes;

    /// @notice Judge votes against per report (M-04: multi-judge).
    mapping(bytes32 => uint256) public reportInvalidVotes;

    /// @notice Whether a judge has already voted on a specific report.
    mapping(bytes32 => mapping(address => bool)) public judgeHasVoted;

    /// @notice Whether contract is ossified (permanently non-upgradeable)
    bool private _ossified;

    /// @dev Reserved storage gap for future upgrades (reduced by 1 for _ossified).
    uint256[36] private __gap;

    // ═══════════════════════════════════════════════════════════════════════
    //                              EVENTS
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Emitted when a Sybil report is submitted.
     * @param reportId Unique identifier for the report.
     * @param suspect Address of suspected Sybil.
     * @param reporter Address who submitted report.
     */
    event SybilReported(
        bytes32 indexed reportId,
        address indexed suspect,
        address indexed reporter
    );

    /**
     * @notice Emitted when a Sybil report is resolved.
     * @param reportId The resolved report ID.
     * @param valid Whether the report was ruled valid.
     */
    event SybilResolved(bytes32 indexed reportId, bool indexed valid);

    /**
     * @notice Emitted when an account is flagged as Sybil.
     * @param account The flagged account.
     * @param reportId The report that caused flagging.
     */
    event AccountFlagged(
        address indexed account,
        bytes32 indexed reportId
    );

    /**
     * @notice Emitted when an account is unflagged after appeal.
     * @param account The unflagged account.
     */
    event AccountUnflagged(address indexed account);

    /**
     * @notice Emitted when a device is registered.
     * @param fingerprint Hash of device fingerprint.
     * @param user User address registered on device.
     */
    event DeviceRegistered(
        bytes32 indexed fingerprint,
        address indexed user
    );

    /**
     * @notice Emitted when reward pool is funded.
     * @param funder Address that funded the pool.
     * @param amount Amount of XOM added to pool.
     */
    event RewardPoolFunded(
        address indexed funder,
        uint256 indexed amount
    );

    /**
     * @notice Emitted when a user withdraws their pending balance.
     * @param user The user who withdrew.
     * @param amount The amount of XOM withdrawn.
     */
    event Withdrawn(address indexed user, uint256 indexed amount);

    /**
     * @notice Emitted when deferred reward is claimed from refilled pool.
     * @param user The reporter who claimed.
     * @param amount The amount of XOM claimed.
     */
    event DeferredRewardClaimed(
        address indexed user,
        uint256 indexed amount
    );

    /**
     * @notice Emitted when a judge casts a vote on a report (M-04).
     * @param reportId The report being voted on.
     * @param judge The judge who voted.
     * @param isValid Whether the judge voted valid or invalid.
     */
    event JudgeVoteCast(
        bytes32 indexed reportId,
        address indexed judge,
        bool indexed isValid
    );

    /// @notice Emitted when the contract is permanently ossified
    /// @param contractAddress Address of this contract
    event ContractOssified(address indexed contractAddress);

    // ═══════════════════════════════════════════════════════════════════════
    //                              ERRORS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Device has reached maximum user limit.
    error DeviceLimitExceeded();

    /// @notice Account has been flagged as Sybil.
    error AccountIsFlagged();

    /// @notice Report does not exist.
    error ReportNotFound();

    /// @notice Challenge period has not elapsed.
    error ChallengePeriodActive();

    /// @notice Report has already been resolved.
    error AlreadyResolved();

    /// @notice Cannot report yourself.
    error CannotReportSelf();

    /// @notice Account already has a pending or resolved report with ID.
    error ReportAlreadyPending();

    /// @notice Suspect address is the zero address.
    error ZeroAddress();

    /// @notice Account is already flagged.
    error AccountAlreadyFlagged();

    /// @notice Account is in unflag cooldown period.
    error UnflagCooldownActive();

    /// @notice No pending balance to withdraw.
    error NothingToWithdraw();

    /// @notice No deferred rewards to claim.
    error NoDeferredRewards();

    /// @notice XOM token address is the zero address.
    error InvalidXomToken();

    /// @notice Amount must be greater than zero.
    error ZeroAmount();

    /// @notice Judge has already voted on this report (M-04).
    error JudgeAlreadyVoted();

    /// @notice Insufficient judge votes to finalize resolution (M-04).
    error InsufficientJudgeVotes();

    /// @notice Thrown when contract is ossified and upgrade attempted
    error ContractIsOssified();

    // ═══════════════════════════════════════════════════════════════════════
    //                           INITIALIZATION
    // ═══════════════════════════════════════════════════════════════════════

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the contract with the XOM token address.
     * @dev Sets up access control and grants admin role to deployer.
     * @param _xomToken Address of the XOM ERC-20 token contract.
     */
    function initialize(address _xomToken) external initializer {
        if (_xomToken == address(0)) revert InvalidXomToken();

        __AccessControl_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        xomToken = IERC20(_xomToken);
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                        DEVICE FINGERPRINTING
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Register device fingerprint for a user.
     * @param user The user being registered.
     * @param fingerprintHash Hash of device fingerprint.
     * @dev Called during registration. Limits users per device.
     *
     * M-05 Integration Note: OmniRegistration MUST call this function
     * during its registration flow to enforce the device-per-user limit.
     * Without this integration, users can bypass device fingerprinting
     * by registering directly through OmniRegistration.
     *
     * Security:
     * - Each device can only register MAX_USERS_PER_DEVICE users
     * - Flagged accounts cannot register
     * - Only DEVICE_REGISTRAR_ROLE can call (validators)
     */
    function registerDevice(
        address user,
        bytes32 fingerprintHash
    ) external onlyRole(DEVICE_REGISTRAR_ROLE) {
        if (user == address(0)) revert ZeroAddress();
        if (flaggedAccounts[user]) revert AccountIsFlagged();

        DeviceFingerprint storage fp =
            deviceFingerprints[fingerprintHash];

        if (fp.timestamp == 0) {
            // New device
            fp.fingerprintHash = fingerprintHash;
            // solhint-disable-next-line not-rely-on-time
            fp.timestamp = block.timestamp;
            fp.registrationCount = 1;
        } else {
            // Existing device - check limit
            if (fp.registrationCount > MAX_USERS_PER_DEVICE - 1) {
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
     * @notice Report a suspected Sybil account.
     * @param suspect The suspected Sybil account address.
     * @param evidenceHash IPFS hash of evidence documentation.
     * @dev Requires prior XOM approval for REPORT_STAKE amount.
     *
     * Process:
     * 1. Reporter stakes REPORT_STAKE XOM via safeTransferFrom
     * 2. Challenge period (72h) allows suspect to defend
     * 3. Judge resolves after challenge period
     * 4. If valid: stake + reward credited to pendingWithdrawals
     * 5. If invalid: Stake credited to suspect pendingWithdrawals
     */
    function reportSybil(
        address suspect,
        bytes32 evidenceHash
    ) external nonReentrant {
        if (suspect == address(0)) revert ZeroAddress();
        if (suspect == msg.sender) revert CannotReportSelf();
        if (flaggedAccounts[suspect]) revert AccountAlreadyFlagged();

        // Check unflag cooldown (business requirement: 30-day cooldown)
        uint256 cooldownEnd = unflaggedAt[suspect];
        if (cooldownEnd != 0) {
            // solhint-disable-next-line not-rely-on-time
            if (block.timestamp < cooldownEnd + UNFLAG_COOLDOWN) {
                revert UnflagCooldownActive();
            }
        }

        // Use abi.encode (not encodePacked) for collision resistance
        /* solhint-disable not-rely-on-time */
        bytes32 reportId = keccak256(
            abi.encode(suspect, msg.sender, block.timestamp)
        );
        /* solhint-enable not-rely-on-time */

        // Prevent report ID collision (H-01)
        if (reports[reportId].timestamp != 0) {
            revert ReportAlreadyPending();
        }

        // Pull exact REPORT_STAKE XOM from reporter
        xomToken.safeTransferFrom(
            msg.sender,
            address(this),
            REPORT_STAKE
        );

        reports[reportId] = SybilReport({
            reporter: msg.sender,
            resolved: false,
            valid: false,
            suspect: suspect,
            evidenceHash: evidenceHash,
            stake: REPORT_STAKE,
            // solhint-disable-next-line not-rely-on-time
            timestamp: block.timestamp
        });

        ++totalReports;

        emit SybilReported(reportId, suspect, msg.sender);
    }

    /**
     * @notice Cast a judge vote on a Sybil report (M-04 multi-judge).
     * @param reportId The report to vote on.
     * @param isValid Whether this judge believes the report is valid.
     * @dev Only callable by JUDGE_ROLE after CHALLENGE_PERIOD.
     *      Each judge may only vote once per report.
     *      When MIN_JUDGE_VOTES threshold is reached for either side,
     *      the report is automatically finalized.
     */
    function voteOnReport(
        bytes32 reportId,
        bool isValid
    ) external onlyRole(JUDGE_ROLE) nonReentrant {
        SybilReport storage report = reports[reportId];

        if (report.timestamp == 0) revert ReportNotFound();
        if (report.resolved) revert AlreadyResolved();
        if (judgeHasVoted[reportId][msg.sender]) revert JudgeAlreadyVoted();

        // Business requirement: 72-hour challenge period
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp < report.timestamp + CHALLENGE_PERIOD) {
            revert ChallengePeriodActive();
        }

        judgeHasVoted[reportId][msg.sender] = true;

        if (isValid) {
            ++reportValidVotes[reportId];
        } else {
            ++reportInvalidVotes[reportId];
        }

        emit JudgeVoteCast(reportId, msg.sender, isValid);

        // Auto-finalize when threshold reached
        // solhint-disable-next-line gas-strict-inequalities
        if (reportValidVotes[reportId] >= MIN_JUDGE_VOTES) {
            _finalizeReport(reportId, true);
        // solhint-disable-next-line gas-strict-inequalities
        } else if (reportInvalidVotes[reportId] >= MIN_JUDGE_VOTES) {
            _finalizeReport(reportId, false);
        }
    }

    /**
     * @notice Finalize a report once enough judge votes are collected.
     * @param reportId The report to finalize.
     * @param isValid Whether the majority voted valid.
     * @dev Internal function called by voteOnReport when threshold is met.
     *      Uses pull-based withdrawal pattern for all payouts.
     *
     * If valid:
     * - Account is flagged as Sybil
     * - Reporter receives stake + reward via pendingWithdrawals
     * - If pool insufficient, reward deferred to pendingRewards
     *
     * If invalid:
     * - Reporter stake credited to suspect pendingWithdrawals
     * - Reporter loses stake
     */
    function _finalizeReport(
        bytes32 reportId,
        bool isValid
    ) internal {
        SybilReport storage report = reports[reportId];

        report.resolved = true;
        report.valid = isValid;

        if (isValid) {
            // Flag the account
            flaggedAccounts[report.suspect] = true;
            ++confirmedSybilCases;
            emit AccountFlagged(report.suspect, reportId);

            // Credit stake to reporter withdrawal balance
            pendingWithdrawals[report.reporter] += report.stake;

            // H-02: Separate flagging from reward — never revert
            if (rewardPool > REPORT_REWARD - 1) {
                rewardPool -= REPORT_REWARD;
                pendingWithdrawals[report.reporter] +=
                    REPORT_REWARD;
            } else {
                // Defer reward for later claim when pool refilled
                pendingRewards[report.reporter] += REPORT_REWARD;
            }
        } else {
            // Slash reporter stake — credit to suspect withdrawal
            pendingWithdrawals[report.suspect] += report.stake;
        }

        emit SybilResolved(reportId, isValid);
    }

    /**
     * @notice Legacy single-judge resolution (backward-compatible).
     * @param reportId The report to resolve.
     * @param isValid Whether the report is valid (suspect is Sybil).
     * @dev Only callable by DEFAULT_ADMIN_ROLE for emergency resolution.
     *      For normal operation, use voteOnReport() multi-judge flow.
     */
    function resolveReport(
        bytes32 reportId,
        bool isValid
    ) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        SybilReport storage report = reports[reportId];

        if (report.timestamp == 0) revert ReportNotFound();
        if (report.resolved) revert AlreadyResolved();

        // Business requirement: 72-hour challenge period
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp < report.timestamp + CHALLENGE_PERIOD) {
            revert ChallengePeriodActive();
        }

        _finalizeReport(reportId, isValid);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                         WITHDRAWAL FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Withdraw pending XOM balance (stakes and rewards).
     * @dev Pull-based withdrawal pattern prevents griefing by contracts
     *      that reject token transfers (M-02 mitigation).
     */
    function withdraw() external nonReentrant {
        uint256 amount = pendingWithdrawals[msg.sender];
        if (amount == 0) revert NothingToWithdraw();

        pendingWithdrawals[msg.sender] = 0;
        xomToken.safeTransfer(msg.sender, amount);

        emit Withdrawn(msg.sender, amount);
    }

    /**
     * @notice Claim deferred rewards owed when pool was empty.
     * @dev Callable once the reward pool has been refilled. Deducts
     *      from the pool and credits to pendingWithdrawals.
     */
    function claimDeferredRewards() external nonReentrant {
        uint256 owed = pendingRewards[msg.sender];
        if (owed == 0) revert NoDeferredRewards();

        // Only pay up to what the pool can cover
        uint256 claimable = owed < rewardPool + 1 ? owed : rewardPool;
        if (claimable == 0) revert NoDeferredRewards();

        pendingRewards[msg.sender] -= claimable;
        rewardPool -= claimable;
        pendingWithdrawals[msg.sender] += claimable;

        emit DeferredRewardClaimed(msg.sender, claimable);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                          ADMIN FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Fund the reward pool for reporters with XOM tokens.
     * @param amount Amount of XOM to add to the reward pool.
     * @dev Permissionless — anyone can fund. Requires XOM approval.
     */
    function fundRewardPool(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        xomToken.safeTransferFrom(
            msg.sender,
            address(this),
            amount
        );
        rewardPool += amount;

        emit RewardPoolFunded(msg.sender, amount);
    }

    /**
     * @notice Manually flag an account (emergency use).
     * @param account The account to flag.
     * @dev Only callable by JUDGE_ROLE for emergency situations.
     */
    function manualFlag(
        address account
    ) external onlyRole(JUDGE_ROLE) {
        if (account == address(0)) revert ZeroAddress();
        flaggedAccounts[account] = true;
        emit AccountFlagged(account, bytes32(0));
    }

    /**
     * @notice Remove flag from account (appeal success).
     * @param account The account to unflag.
     * @dev Only callable by DEFAULT_ADMIN_ROLE after appeal.
     *      Sets a cooldown period preventing immediate re-reporting.
     */
    function unflagAccount(
        address account
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        flaggedAccounts[account] = false;
        // solhint-disable-next-line not-rely-on-time
        unflaggedAt[account] = block.timestamp;
        emit AccountUnflagged(account);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                          VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Check if account is flagged as Sybil.
     * @param account The account to check.
     * @return True if flagged.
     */
    function isFlagged(
        address account
    ) external view returns (bool) {
        return flaggedAccounts[account];
    }

    /**
     * @notice Get users registered from a device.
     * @param fingerprint The device fingerprint hash.
     * @return Array of user addresses.
     */
    function getUsersForDevice(
        bytes32 fingerprint
    ) external view returns (address[] memory) {
        return deviceToUsers[fingerprint];
    }

    /**
     * @notice Get device registration count.
     * @param fingerprint The device fingerprint hash.
     * @return Number of users registered from device.
     */
    function getDeviceRegistrationCount(
        bytes32 fingerprint
    ) external view returns (uint256) {
        return deviceFingerprints[fingerprint].registrationCount;
    }

    /**
     * @notice Get report details.
     * @param reportId The report ID.
     * @return Report struct.
     */
    function getReport(
        bytes32 reportId
    ) external view returns (SybilReport memory) {
        return reports[reportId];
    }

    /**
     * @notice Check if a device fingerprint has reached its user limit.
     * @param fingerprintHash Hash of the device fingerprint.
     * @return True if the device has reached MAX_USERS_PER_DEVICE.
     * @dev M-05: Can be called by OmniRegistration to enforce
     *      device limits during the registration flow.
     */
    function isDeviceAtLimit(
        bytes32 fingerprintHash
    ) external view returns (bool) {
        // solhint-disable-next-line gas-strict-inequalities
        return deviceFingerprints[fingerprintHash].registrationCount >= MAX_USERS_PER_DEVICE;
    }

    /**
     * @notice Get vote counts for a report (M-04 multi-judge).
     * @param reportId The report ID.
     * @return validVotes Number of valid votes cast.
     * @return invalidVotes Number of invalid votes cast.
     */
    function getReportVotes(
        bytes32 reportId
    ) external view returns (uint256 validVotes, uint256 invalidVotes) {
        validVotes = reportValidVotes[reportId];
        invalidVotes = reportInvalidVotes[reportId];
    }

    /**
     * @notice Check if report can be resolved.
     * @param reportId The report ID.
     * @return True if challenge period elapsed and not resolved.
     */
    function canResolveReport(
        bytes32 reportId
    ) external view returns (bool) {
        SybilReport storage report = reports[reportId];
        /* solhint-disable not-rely-on-time */
        uint256 challengeEnd = report.timestamp + CHALLENGE_PERIOD;
        return
            report.timestamp != 0 &&
            !report.resolved &&
            block.timestamp > challengeEnd - 1;
        /* solhint-enable not-rely-on-time */
    }

    /**
     * @notice Get time remaining in challenge period.
     * @param reportId The report ID.
     * @return Seconds remaining (0 if period elapsed).
     */
    function getChallengeTimeRemaining(
        bytes32 reportId
    ) external view returns (uint256) {
        SybilReport storage report = reports[reportId];
        if (report.timestamp == 0) return 0;

        /* solhint-disable not-rely-on-time */
        uint256 endTime = report.timestamp + CHALLENGE_PERIOD;
        if (block.timestamp > endTime - 1) return 0;

        return endTime - block.timestamp;
        /* solhint-enable not-rely-on-time */
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                            INTERNAL
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Permanently remove upgrade capability (one-way, irreversible)
     * @dev Can only be called by admin (through timelock). Once ossified,
     *      the contract can never be upgraded again.
     */
    function ossify() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _ossified = true;
        emit ContractOssified(address(this));
    }

    /**
     * @notice Check if the contract has been permanently ossified
     * @return True if ossified (no further upgrades possible)
     */
    function isOssified() external view returns (bool) {
        return _ossified;
    }

    /**
     * @notice Authorize contract upgrade.
     * @param newImplementation Address of new implementation.
     * @dev Only callable by DEFAULT_ADMIN_ROLE. Reverts if contract is ossified.
     */
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_ossified) revert ContractIsOssified();
    }
}
