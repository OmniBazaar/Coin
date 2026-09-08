// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title ValidatorActivityLedger
 * @author OmniBazaar Team
 * @notice On-chain record of committee-attested validator activity (VT-18).
 *
 * @dev OmniValidatorRewards historically derived the activity component of
 *      reward weights from `submitHeartbeat` — a signal every validator could
 *      self-report (BLOCKCHAIN_ROLE was held by the validators themselves), so
 *      a validator could manufacture its own "active" status. This contract
 *      replaces that signal: an off-chain tally reads the M-of-N committee
 *      attestation events (`CommitteeAttested` / `RootPublished`) and records,
 *      per epoch, which validators were genuinely attested active. The rewards
 *      contract then reads {lastAttestationEpoch} here instead of the
 *      heartbeat.
 *
 *      Idempotent and monotonic: `recordEpochActivity` only records a
 *      validator once per epoch, and a validator's recorded epoch can never
 *      move backwards, so a misbehaving recorder cannot re-write history.
 *
 *      Not upgradeable, on purpose — the value of a ledger is that it does not
 *      move. `admin` (the deployer EOA during Pioneer) holds DEFAULT_ADMIN_ROLE
 *      and grants RECORDER_ROLE to the tally operator (a designated gateway
 *      EOA, or the validator fleet). All administrative calls are direct, with
 *      no timelock, per the Pioneer-phase contract rule.
 */
contract ValidatorActivityLedger is AccessControl {
    // ──────────────────────────────────────────────────────────── roles ──

    /// @notice The role permitted to call {recordEpochActivity}.
    bytes32 public constant RECORDER_ROLE = keccak256("RECORDER_ROLE");

    // ──────────────────────────────────────────────────────── clock ──

    /// @notice Epoch duration in seconds (matches OmniValidatorRewards).
    uint256 public constant EPOCH_DURATION = 2;

    /// @notice Maximum epochs a recording may run ahead of the ledger's own
    ///         clock. Bounds a rogue recorder to a short horizon — it can no
    ///         longer write a far-future epoch and grant permanent activity.
    uint256 public constant MAX_FUTURE_EPOCH_SLACK = 100;

    /// @notice Ledger genesis timestamp; the ledger derives its epoch clock
    ///         from this to bound recordings against wall time.
    uint256 public immutable genesisTimestamp;

    // ─────────────────────────────────────────────────────────── state ──

    /// @notice Lifetime count of epochs in which a validator was attested
    ///         active. Monotonic; used for monitoring and bounties.
    mapping(address => uint256) public attestationCount;

    /// @notice The most recent epoch in which a validator was attested
    ///         active. Zero if never attested. Monotonic.
    mapping(address => uint256) public lastAttestationEpoch;

    // ────────────────────────────────────────────────────────── events ──

    /// @notice A validator was recorded active for an epoch.
    /// @param validator The validator address.
    /// @param epoch The epoch recorded.
    /// @param count The validator's updated lifetime attestation count.
    event ActivityRecorded(
        address indexed validator,
        uint256 indexed epoch,
        uint256 count
    );

    // ────────────────────────────────────────────────────────── errors ──

    /// @notice A zero address was supplied where an account is required.
    error ZeroAddress();

    /// @notice The recording epoch is too far ahead of the ledger's clock.
    /// @param epoch The (rejected) epoch.
    /// @param currentEpoch The ledger's current epoch.
    error EpochTooFarInFuture(uint256 epoch, uint256 currentEpoch);

    // ───────────────────────────────────────────────────── construction ──

    /**
     * @notice Deploy the ledger.
     * @param initialAdmin The administrative account (deployer EOA during
     *        Pioneer; a governance contract after the handover). Granted both
     *        DEFAULT_ADMIN_ROLE and RECORDER_ROLE so the deployer can record
     *        activity immediately and delegate RECORDER_ROLE to the tally
     *        operator.
     * @param genesisTimestamp_ The epoch-clock genesis the ledger must share with
     *        `OmniValidatorRewards`. The tally records the REWARDS epoch, and the
     *        rewards contract reads `lastAttestationEpoch` on the same scale, so
     *        this MUST equal `OmniValidatorRewards.genesisTimestamp()` — NOT the
     *        ledger's own deploy time, or every recording is rejected as
     *        `EpochTooFarInFuture`.
     */
    constructor(address initialAdmin, uint256 genesisTimestamp_) {
        if (initialAdmin == address(0)) revert ZeroAddress();
        if (genesisTimestamp_ == 0) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
        _grantRole(RECORDER_ROLE, initialAdmin);
        genesisTimestamp = genesisTimestamp_;
    }

    // ─────────────────────────────────────────────────────── recording ──

    /**
     * @notice Record that a set of validators were attested active for an
     *         epoch.
     * @dev Idempotent per (epoch, validator): each validator is recorded at
     *      most once per epoch, and a validator's recorded epoch is monotonic,
     *      so a stale or duplicate call cannot re-write history. Zero-address
     *      entries are skipped.
     * @param epoch The epoch the validators were attested active in.
     * @param validators The validator addresses attested active.
     */
    function recordEpochActivity(
        uint256 epoch,
        address[] calldata validators
    ) external onlyRole(RECORDER_ROLE) {
        // Reject far-future epochs: bound the recording to the ledger's own
        // clock + a short slack, so a rogue recorder cannot grant a validator
        // permanent activity by writing an enormous epoch.
        // solhint-disable-next-line not-rely-on-time
        uint256 currentEpoch = (block.timestamp - genesisTimestamp)
            / EPOCH_DURATION;
        if (epoch > currentEpoch + MAX_FUTURE_EPOCH_SLACK) {
            revert EpochTooFarInFuture(epoch, currentEpoch);
        }

        uint256 length = validators.length;
        for (uint256 i = 0; i < length; ++i) {
            address validator = validators[i];
            if (validator == address(0)) continue;
            // Idempotency: only record a monotonically increasing epoch.
            if (lastAttestationEpoch[validator] >= epoch) continue;

            lastAttestationEpoch[validator] = epoch;
            ++attestationCount[validator];
            emit ActivityRecorded(
                validator, epoch, attestationCount[validator]
            );
        }
    }
}
