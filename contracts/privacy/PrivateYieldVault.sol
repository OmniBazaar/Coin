// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {
    AccessControlUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {
    PausableUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {
    ReentrancyGuardUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {
    Initializable
} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    UUPSUpgradeable
} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {
    EIP712Upgradeable
} from
    "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {
    ContextUpgradeable
} from
    "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import {
    ECDSA
} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {
    MpcCore,
    gtUint256,
    ctUint256,
    itUint256,
    ctUint128,
    gtBool
} from "../coti-helium/utils/mpc/MpcCore.sol";
import {
    IBridgeVerifier
} from "../bridge/IBridgeVerifier.sol";
import {
    CommitteeAttestor
} from "../attestation/CommitteeAttestor.sol";
import {
    IPrivateERC20
} from "../coti-helium/token/PrivateERC20/IPrivateERC20.sol";

/**
 * @title PrivateYieldVault
 * @author OmniBazaar Development Team
 * @notice Privacy-preserving yield staking on COTI Helium 256-bit MPC.
 * @dev Phase 6.1 of FIX_PRIVACY:
 *      - Stake pXOM with encrypted ctUint256 principal.
 *      - APR is a function of `(amountTier, durationTier)` per CLAUDE.md
 *        tokenomics: base 5–9 % by amount tier (1, 1M, 10M, 100M, 1B XOM),
 *        +0–3 % bonus by duration tier (none / 1mo / 6mo / 2yr). Total
 *        range 5–12 %.
 *      - `amountTier` is verified on-chain via MPC range checks against
 *        the public threshold ladder; the verification reveals exactly
 *        one bit of information (claim valid or not) — the stake amount
 *        itself stays encrypted in `ctUint256`.
 *      - The verified `amountTier` is itself stored in plaintext on the
 *        `Stake` struct and emitted in `StakeOpened`, so the staker's
 *        principal is bucket-private (`log2(AMOUNT_TIER_COUNT)` ≈ 2.32
 *        bits of coarse range info leak per stake) but exact-amount
 *        private. This is a deliberate v1 design tradeoff: keeping APR
 *        math in public-tier space avoids per-accrual MPC tier resolution
 *        and matches the Tornado-Cash bucketed-anonymity-set pattern.
 *      - Reward accrual is checkpointed (no continuous compounding);
 *        callers settle their accumulated rewards via {accrue} or
 *        implicitly during {unstake}. Rewards land in the encrypted
 *        balance accumulator, claimable via {claim}.
 *      - Early-withdrawal penalty: `EARLY_PENALTY_BPS` (5 %) of principal
 *        + forfeit of all unaccrued rewards.
 *      - Carries forward all audit-remediated patterns from
 *        `PrivateDEXSettlement` (Phase 4.1) and `PrivateMarketplaceEscrow`
 *        (Phase 5.1):
 *          * COTI-only chainid guard.
 *          * EIP-712 typehash binds priceCommit + amountTier + durationTier.
 *          * Request/apply two-step on every privileged setter
 *            (TIMELOCK_DELAY == 0 during Pioneer per the deployer-direct
 *            rule; request and apply are atomic).
 *          * UUPS + 7-day two-step ossification (re-request guarded; cancel
 *            available).
 *          * `renounceRole(DEFAULT_ADMIN_ROLE, ...)` overridden to revert.
 *          * Pause does NOT block user-only escape paths
 *            ({unstake}-after-lock, {claim}).
 *          * Trusted forwarder held in proxy storage (audit H-06).
 */
contract PrivateYieldVault is
    Initializable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable,
    EIP712Upgradeable,
    CommitteeAttestor
{
    using MpcCore for gtUint256;
    using MpcCore for ctUint256;
    using MpcCore for gtBool;

    // ========================================================================
    // TYPE DECLARATIONS
    // ========================================================================

    /// @notice Stake lifecycle status.
    enum StakeStatus {
        EMPTY,
        ACTIVE,
        WITHDRAWN
    }

    /**
     * @notice One staking position.
     * @dev `encAmount` is the encrypted principal. `amountTier` is verified
     *      on-chain against the encrypted principal at stake time; both
     *      tiers are public after that point so APR math can run with public
     *      multipliers and one MPC mul/div per accrual.
     */
    // solhint-disable-next-line gas-struct-packing
    struct Stake {
        address owner;
        ctUint256 encAmount;
        uint256 stakedAt;
        uint256 lockEnd;
        uint256 lastAccrualAt;
        uint8 amountTier;
        uint8 durationTier;
        StakeStatus status;
        // True once the staker's pXOM principal was pulled into vault custody
        // via {IPrivateERC20-transferFromGT} at stake time (settlement-direct
        // escrow, bound via {initializeV3}). Packs into the same storage slot
        // as `amountTier`/`durationTier`/`status` (all sub-32-byte), so
        // pre-escrow stakes written before the V3 upgrade read `false` with no
        // storage-layout migration — {unstake} keeps the legacy
        // encrypted-accumulator payout for those, real pXOM custody payout for
        // escrowed stakes.
        bool escrowed;
    }

    /**
     * @notice Pending timelocked update for the early-withdrawal penalty.
     * @dev Zero `effectiveAt` = no pending update.
     */
    struct PendingPenalty {
        uint64 newPenaltyBps;
        uint256 effectiveAt;
    }

    /**
     * @notice Pending timelocked update for the trusted forwarder.
     * @dev Zero `effectiveAt` = no pending update.
     */
    struct PendingForwarder {
        address forwarder;
        uint256 effectiveAt;
    }

    /**
     * @notice Pending timelocked update for the fee recipient.
     * @dev Zero `effectiveAt` = no pending update.
     */
    struct PendingFeeRecipient {
        address recipient;
        uint256 effectiveAt;
    }

    /**
     * @notice Pending timelocked UUPS implementation upgrade.
     * @dev Phase 6.2 audit H-05 back-port — a request/apply two-step on UUPS
     *      upgrades. `TIMELOCK_DELAY == 0` during Pioneer (deployer-direct
     *      rule), so request and apply are atomic; post-Pioneer the delay is
     *      reinstated via governance so users get a grace window to detect a
     *      malicious implementation swap. Zero `effectiveAt` = no pending
     *      upgrade.
     */
    struct PendingUpgrade {
        address newImplementation;
        uint256 effectiveAt;
    }

    // ========================================================================
    // CONSTANTS
    // ========================================================================

    /// @notice Role for the relayer (validator gateway).
    bytes32 public constant RELAYER_ROLE = keccak256("RELAYER_ROLE");

    /// @notice Basis-points divisor (100 %).
    uint256 public constant BASIS_POINTS_DIVISOR = 10_000;

    /// @notice Seconds in a calendar year (used in APR math).
    uint256 public constant SECONDS_PER_YEAR = 365 days;

    /// @notice Maximum early-withdrawal penalty (10 %).
    uint64 public constant MAX_EARLY_PENALTY_BPS = 1_000;

    /// @notice Default early-withdrawal penalty (5 %).
    uint64 public constant DEFAULT_EARLY_PENALTY_BPS = 500;

    /// @notice Number of amount tiers (5).
    uint8 public constant AMOUNT_TIER_COUNT = 5;

    /// @notice Number of duration tiers (4: none / 1mo / 6mo / 2yr).
    uint8 public constant DURATION_TIER_COUNT = 4;

    /// @notice 7-day ossification delay.
    uint256 public constant OSSIFICATION_DELAY = 7 days;

    /// @notice Required delay for privileged setter timelocks (48 h).
    /// @notice Set to `0` per `memory/feedback_no_builtin_timelocks.md`
    ///         Pioneer-Phase rule: the deployer EOA is the sole admin
    ///         with zero on-chain delay; the request/apply two-step
    ///         structure is preserved (admin commits publicly before
    ///         applying) but the wait is gone. Was `48 hours` in the
    ///         H-05 back-port; the founder's no-built-in-delays rule
    ///         predates the back-port and supersedes it.
    uint256 public constant TIMELOCK_DELAY = 0;

    /// @notice COTI mainnet chain id.
    uint256 private constant COTI_MAINNET_CHAIN_ID = 2_632_500;

    /// @notice COTI testnet chain id.
    uint256 private constant COTI_TESTNET_CHAIN_ID = 7_082_400;

    /// @notice EIP-712 typehash for the staker's stake-intent.
    /// @dev String length is fixed by the EIP-712 spec.
    // solhint-disable-next-line gas-small-strings, max-line-length
    bytes32 private constant STAKE_INTENT_TYPEHASH = keccak256("StakeIntent(bytes32 stakeId,address staker,bytes32 amountCommit,uint8 amountTier,uint8 durationTier,uint256 nonce,uint256 deadline)");

    // ========================================================================
    // STATE VARIABLES
    // ========================================================================

    /// @notice stakeId → stake record.
    mapping(bytes32 stakeId => Stake entry) public stakes;

    /// @notice address → next-expected nonce for `StakeIntent` signatures.
    mapping(address staker => uint256 nonce) public nonces;

    /// @notice address → encrypted accumulated balance (claimable).
    mapping(address recipient => ctUint256 balance) private accumulatedBalances;

    /// @notice address → has a non-zero accumulated balance pending claim.
    mapping(address recipient => bool flagged) private _hasUnclaimed;

    /// @notice address → monotonic per-recipient claim nonce.
    mapping(address recipient => uint256 claimNonce) public claimNonces;

    /// @notice Amount-tier minimum thresholds (XOM in wei). Index 0..4.
    /// @dev Configured at initialize; immutable post-deploy.
    uint256[5] public amountThresholds;

    /// @notice Duration-tier lock periods (seconds). Index 0..3.
    uint256[4] public durationLockPeriods;

    /// @notice Active early-withdrawal penalty in basis points.
    uint64 public earlyPenaltyBps;

    /// @notice ERC-2771 trusted forwarder (proxy storage — audit H-06).
    address public trustedForwarder;

    /// @notice Recipient of early-withdrawal penalty accumulator.
    /// @dev Configurable + timelocked. Set at initialize and rotatable
    ///      via the `requestFeeRecipientUpdate` two-step. Penalties
    ///      accrue here (not `address(this)`) so they remain claimable
    ///      via the standard {claim} flow.
    address public feeRecipient;

    /// @notice Total lifetime stakes opened (counter).
    uint256 public totalStakes;

    /// @notice True once the contract is permanently non-upgradable.
    bool private _ossified;

    /// @notice Block timestamp when ossification was requested (0 = none).
    uint256 public ossificationRequestTime;

    /// @notice Pending penalty update (timelocked).
    PendingPenalty public pendingPenalty;

    /// @notice Pending forwarder update (timelocked).
    PendingForwarder public pendingForwarder;

    /// @notice Pending fee-recipient update (timelocked).
    PendingFeeRecipient public pendingFeeRecipient;

    /// @notice Pending UUPS implementation upgrade (timelocked).
    /// @dev Phase 6.2 audit H-05 back-port. The first upgrade FROM the
    ///      pre-back-port impl bypasses this gate (the OLD impl had no
    ///      `pendingUpgrade` requirement); every subsequent upgrade
    ///      enforces the request/apply two-step (TIMELOCK_DELAY == 0 during
    ///      Pioneer, so request and apply are atomic).
    PendingUpgrade public pendingUpgrade;

    /// @notice Pluggable committee-attestation verifier for the
    ///         random-committee relayer path ({stakeWithCommittee}).
    /// @dev Implements `IBridgeVerifier`; the privacy stack wires
    ///      DIRECTLY to a `RandomCommitteeVerifier` instance rather
    ///      than the gateway because privacy contracts manage their
    ///      own per-staker nonces (no gateway nonce consumption).
    ///      Zero-address = committee path disabled. Set via
    ///      {setAttestationVerifier}; Pioneer Phase rule applies
    ///      (deployer-direct, no built-in delay). Per the canonical
    ///      `memory/decision_privacy_roles_random_committee_2026-05-27.md`
    ///      this replaces the static `RELAYER_ROLE` allowlist with
    ///      random committee selection that scales as validators join.
    ///      The legacy `RELAYER_ROLE`-gated {stake} entry remains live
    ///      during the transition; both paths produce identical
    ///      on-chain state.
    IBridgeVerifier public attestationVerifier;

    /// @notice COTI pXOM ({PrivateOmniCoin}) token whose encrypted balance
    ///         backs every escrowed stake. Bound once via {initializeV3}.
    /// @dev Settlement-direct escrow (mirrors {PrivateMarketplaceEscrow}).
    ///      From the V3 upgrade on, {stake}/{stakeWithCommittee} pull the
    ///      staker's principal into custody via
    ///      {IPrivateERC20-transferFromGT} and {unstake} releases it via
    ///      {IPrivateERC20-transferGT}. Zero-address (pre-V3) = legacy
    ///      no-custody accumulator behavior; a stake call reverts
    ///      {PrivateTokenNotSet} until bound. Appended after
    ///      `attestationVerifier` (consuming one `__gap` slot) so the proxy
    ///      storage layout of every prior field is unchanged.
    IPrivateERC20 public privateToken;

    /// @dev Storage gap for proxy-safe future-state additions.
    /// @dev Originally 40; shrunk to 37 for the Phase 6.1 init state
    ///      (`feeRecipient` + `pendingFeeRecipient`). Further shrunk
    ///      to 35 to account for the H-05 back-port `pendingUpgrade`
    ///      slot pair (struct = 2 slots: address + uint256). Shrunk
    ///      again to 34 for the random-committee `attestationVerifier`
    ///      slot, then to 33 for the settlement-direct `privateToken` slot.
    uint256[33] private __gap;

    // ========================================================================
    // EVENTS
    // ========================================================================

    /**
     * @notice Emitted when a new stake is opened.
     * @param stakeId Stake identifier.
     * @param staker Staker EOA.
     * @param amountTier Verified amount tier.
     * @param durationTier Duration tier.
     * @param lockEnd Unix-seconds when the lock expires.
     */
    event StakeOpened(
        bytes32 indexed stakeId,
        address indexed staker,
        uint8 amountTier,
        uint8 durationTier,
        uint256 lockEnd
    );

    /**
     * @notice Emitted when a stake's accrued rewards are checkpointed.
     * @param stakeId Stake identifier.
     * @param staker Staker EOA.
     * @param accrualAt Block timestamp at checkpoint.
     */
    event RewardsAccrued(
        bytes32 indexed stakeId,
        address indexed staker,
        uint256 indexed accrualAt
    );

    /**
     * @notice Emitted when a stake is closed.
     * @param stakeId Stake identifier.
     * @param staker Staker EOA.
     * @param earlyExit True if the stake was unstaked before its `lockEnd`.
     */
    event StakeClosed(
        bytes32 indexed stakeId,
        address indexed staker,
        bool earlyExit
    );

    /**
     * @notice Emitted when a recipient claims their accumulated balance.
     * @param recipient Claiming address.
     * @param claimNonce Per-recipient monotonic nonce.
     * @param ciphertextHigh Pre-reset ciphertext high half.
     * @param ciphertextLow Pre-reset ciphertext low half.
     */
    event BalanceClaimed(
        address indexed recipient,
        uint256 indexed claimNonce,
        uint256 ciphertextHigh,
        uint256 ciphertextLow
    );

    /**
     * @notice Emitted when admin queues a penalty update.
     * @param newPenaltyBps Pending penalty bps.
     * @param effectiveAt Unix-seconds at which it can be applied.
     */
    event PenaltyUpdateQueued(uint64 indexed newPenaltyBps, uint256 effectiveAt);

    /**
     * @notice Emitted when the queued penalty update is applied.
     * @param oldPenaltyBps Previous bps.
     * @param newPenaltyBps New bps.
     */
    event PenaltyUpdated(uint64 indexed oldPenaltyBps, uint64 indexed newPenaltyBps);

    /**
     * @notice Emitted when admin queues a forwarder update.
     * @param forwarder Pending forwarder.
     * @param effectiveAt Unix-seconds at which it can be applied.
     */
    event TrustedForwarderUpdateQueued(address indexed forwarder, uint256 effectiveAt);

    /**
     * @notice Emitted when the queued forwarder update is applied.
     * @param oldForwarder Previous forwarder.
     * @param newForwarder New forwarder.
     */
    event TrustedForwarderUpdated(address indexed oldForwarder, address indexed newForwarder);

    /**
     * @notice Emitted when admin queues a fee-recipient update.
     * @param recipient Pending fee recipient.
     * @param effectiveAt Unix-seconds at which it can be applied.
     */
    event FeeRecipientUpdateQueued(address indexed recipient, uint256 effectiveAt);

    /**
     * @notice Emitted when the queued fee-recipient update is applied.
     * @param oldRecipient Previous recipient.
     * @param newRecipient New recipient.
     */
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);

    /**
     * @notice Emitted when admin cancels a pending timelocked update.
     * @param what String tag identifying which queue was cancelled.
     */
    event PendingUpdateCancelled(string what);

    /**
     * @notice Emitted when admin starts the ossification window.
     * @param contractAddress This contract.
     * @param requestTime Block timestamp at request.
     */
    event OssificationRequested(address indexed contractAddress, uint256 indexed requestTime);

    /**
     * @notice Emitted when admin cancels a pending ossification request.
     * @param contractAddress This contract.
     */
    event OssificationRequestCancelled(address indexed contractAddress);

    /**
     * @notice Emitted when admin confirms ossification.
     * @param contractAddress This contract.
     * @param confirmTime Block timestamp at confirmation.
     */
    event ContractOssified(address indexed contractAddress, uint256 indexed confirmTime);

    /**
     * @notice Emitted when admin queues a UUPS implementation upgrade.
     * @dev Phase 6.2 audit H-05 back-port.
     * @param newImplementation Pending implementation address.
     * @param effectiveAt Unix-seconds at which it can be applied.
     */
    event UpgradeQueued(address indexed newImplementation, uint256 effectiveAt);

    /**
     * @notice Emitted when admin cancels a pending upgrade.
     * @param newImplementation Cancelled implementation address.
     */
    event UpgradeCancelled(address indexed newImplementation);

    /**
     * @notice Emitted when admin (re)points the random-committee
     *         attestation verifier used by {stakeWithCommittee}.
     * @param verifier New verifier; `address(0)` disables the
     *         committee path entirely (legacy {stake} still works).
     */
    event AttestationVerifierSet(IBridgeVerifier indexed verifier);

    /**
     * @notice Emitted when the backing pXOM token is bound via {initializeV3}.
     * @param token {PrivateOmniCoin} (pXOM) address on COTI 2632500.
     */
    event PrivateTokenSet(address indexed token);

    /**
     * @notice Emitted when a stake is opened via the committee
     *         attestation path. The legacy `RELAYER_ROLE` path emits
     *         only {StakeOpened}; this companion event records the
     *         attester list so off-chain slashing can recover it
     *         after the 256-block `blockhash` window expires.
     * @param stakeId Stake identifier.
     * @param attesters Sorted, deduplicated list of validator
     *        attesters whose signatures satisfied the committee
     *        quorum. Empty arrays are rejected by the verifier.
     */
    event StakeCommitteeAttested(
        bytes32 indexed stakeId,
        address[] attesters
    );

    // ========================================================================
    // CUSTOM ERRORS
    // ========================================================================

    error InvalidAddress();
    error UnsupportedChain(uint256 chainId);
    error StakeAlreadyExists();
    error StakeNotActive();
    error InvalidNonce();
    error InvalidStakerSignature();
    error DeadlineExpired();
    error InvalidAmountTier();
    error InvalidDurationTier();
    error InvalidAmountThresholds();
    error InvalidDurationLockPeriods();
    error AmountTierVerificationFailed();
    error NotStaker();
    error PenaltyTooHigh();
    error TimelockDelayNotElapsed();
    error TimelockNotRequested();
    error TimelockAlreadyRequested();
    error UpgradeNotAuthorized();
    error ContractIsOssified();
    error OssificationNotRequested();
    error OssificationAlreadyRequested();
    error OssificationDelayNotElapsed();
    error CannotRenounceAdmin();
    error NoBalanceToClaim();
    error AttestationVerifierNotSet();
    error InvalidCommitteeAttestation();
    /// @dev The backing pXOM token has not been bound via {initializeV3}.
    error PrivateTokenNotSet();
    error SubjectInCommittee();
    error InvalidVerifier();

    // ========================================================================
    // CONSTRUCTOR & INITIALIZATION
    // ========================================================================

    /**
     * @notice Constructor — disables initializers on the implementation.
     * @custom:oz-upgrades-unsafe-allow constructor
     */
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the proxy state.
     * @dev Reverts on any chain other than COTI 2632500 / 7082400.
     *      Amount thresholds: entry 0 MUST be 0 (the lower bound for
     *      tier 0 is implicit). Thresholds 1..4 must be strictly
     *      ascending. Duration lock periods: must be non-decreasing
     *      (typically 0 / 30 days / 180 days / 730 days).
     * @param admin Admin (DEFAULT_ADMIN_ROLE).
     * @param relayers Initial RELAYER_ROLE holders.
     * @param amountThresholds_ Amount-tier minimums in 18-decimal wei
     *        (length 5; entry 0 must be 0).
     * @param durationLockPeriods_ Lock periods in seconds (length 4;
     *        non-decreasing).
     * @param trustedForwarder_ ERC-2771 forwarder; `address(0)` to disable.
     * @param feeRecipient_ Recipient of early-withdrawal penalties.
     *        Must be non-zero — a `address(this)` placeholder is
     *        explicitly disallowed because the contract has no
     *        self-claim path (audit M-02 from Phase 6.1 review).
     */
    function initialize( // solhint-disable-line code-complexity
        address admin,
        address[] calldata relayers,
        uint256[5] calldata amountThresholds_,
        uint256[4] calldata durationLockPeriods_,
        address trustedForwarder_,
        address feeRecipient_
    ) external initializer {
        if (
            block.chainid != COTI_MAINNET_CHAIN_ID
                && block.chainid != COTI_TESTNET_CHAIN_ID
        ) {
            revert UnsupportedChain(block.chainid);
        }
        if (admin == address(0)) revert InvalidAddress();
        if (feeRecipient_ == address(0)) revert InvalidAddress();
        if (feeRecipient_ == address(this)) revert InvalidAddress();

        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        // solhint-disable-next-line gas-small-strings
        __EIP712_init("OmniBazaar PrivateYieldVault", "1");

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        for (uint256 i = 0; i < relayers.length; ++i) {
            address r = relayers[i];
            if (r == address(0)) revert InvalidAddress();
            _grantRole(RELAYER_ROLE, r);
        }

        // Tier-0 floor MUST be 0 — `_verifyAmountTier` would underflow
        // `checkedSub(thresholds[0], 1)` otherwise.
        if (amountThresholds_[0] != 0) revert InvalidAmountThresholds();
        // Validate strictly-ascending thresholds 1..4.
        for (uint256 i = 1; i < AMOUNT_TIER_COUNT; ++i) {
            // solhint-disable-next-line gas-strict-inequalities
            if (amountThresholds_[i] <= amountThresholds_[i - 1]) {
                revert InvalidAmountThresholds();
            }
        }
        // Validate non-decreasing duration lock periods.
        for (uint256 i = 1; i < DURATION_TIER_COUNT; ++i) {
            // solhint-disable-next-line gas-strict-inequalities
            if (durationLockPeriods_[i] < durationLockPeriods_[i - 1]) {
                revert InvalidDurationLockPeriods();
            }
        }
        amountThresholds = amountThresholds_;
        durationLockPeriods = durationLockPeriods_;

        earlyPenaltyBps = DEFAULT_EARLY_PENALTY_BPS;
        trustedForwarder = trustedForwarder_;
        feeRecipient = feeRecipient_;
    }

    /**
     * @notice Reinitializer (version 2) — bind embedded {CommitteeAttestor}
     *         parameters and seed the eligible-set snapshot atomically with
     *         the UUPS upgrade.
     * @dev Callable exactly once via
     *      `proxy.upgradeToAndCall(newImpl, abi.encodeCall(this.initializeV2, (...)))`.
     *      Pioneer Phase rule: deployer EOA wraps both the upgrade tx and
     *      this call in a single signed broadcast — no built-in delay.
     *
     *      Bootstrap snapshot uses sequence = 1 so subsequent
     *      `pushEligibleSetUpdate` calls (sequence >= 2) advance monotonically.
     * @param committeeSize_ N — must be in [MIN_COMMITTEE_SIZE, MAX_COMMITTEE_SIZE].
     * @param quorumM_ M — must satisfy `quorumM_ * 3 >= committeeSize_ * 2`.
     * @param bootstrapSet Initial eligible-set, sorted ascending (the
     *        `privacyV2.validators` list from `coti-mainnet.json` is the
     *        canonical seed at deploy time).
     * @param l1Block L1 block at which `bootstrapSet` was computed; 0 for
     *        a clean bootstrap.
     */
    function initializeV2(
        uint256 committeeSize_,
        uint256 quorumM_,
        address[] calldata bootstrapSet,
        uint256 l1Block
    ) external reinitializer(2) onlyRole(DEFAULT_ADMIN_ROLE) {
        // Audit Pass-3 H-1 — reinitializer(2) enforces VERSION uniqueness
        // only, not CALLER authorization. Without this role check, a non-
        // admin can frontrun a deploy script that does `upgradeTo(impl)` +
        // separate `initializeV2(...)` tx and take total control of the
        // committee gate. Atomic `upgradeToAndCall(impl, encodeCall(...))`
        // is the safer pattern; the role check is defense-in-depth.
        __CommitteeAttestor_init(committeeSize_, quorumM_);
        address[] memory seed = new address[](bootstrapSet.length);
        for (uint256 i = 0; i < bootstrapSet.length; ++i) {
            seed[i] = bootstrapSet[i];
        }
        _bootstrapSnapshot(seed, l1Block, 1);
    }

    /**
     * @notice Reinitializer (version 3) — bind the COTI pXOM token whose
     *         encrypted balance backs every stake, enabling real custody.
     * @dev Settlement-direct escrow migration, mirroring
     *      {PrivateMarketplaceEscrow.initializeV3}. From this upgrade on,
     *      {stake}/{stakeWithCommittee} pull the staker's principal into
     *      vault custody via {IPrivateERC20-transferFromGT} and {unstake}
     *      releases principal (and any early-exit penalty) directly via
     *      {IPrivateERC20-transferGT}. Reward accrual is unchanged — it
     *      continues to credit the encrypted accumulator surfaced by the
     *      {BalanceClaimed} bridge event, which never draws on the vault's
     *      escrowed pXOM balance, so escrowed principal is conserved
     *      one-to-one (in at stake, out at unstake) and the vault can never
     *      pay principal on funds never deposited.
     *
     *      Stakes opened before this upgrade carry `escrowed == false`
     *      (the new struct flag defaults to zero for pre-existing entries)
     *      and keep the legacy encrypted-accumulator payout in {unstake};
     *      no live pXOM backs them and none is paid out for them.
     *
     *      Pioneer-Phase rule: the caller is the deployer EOA holding
     *      `DEFAULT_ADMIN_ROLE`; no timelock. Run atomically with the UUPS
     *      upgrade (`upgradeToAndCall`) so no escrowed stake can be opened
     *      before the token is bound.
     * @param pxom_ Address of {PrivateOmniCoin} (pXOM) on COTI 2632500.
     */
    function initializeV3(address pxom_)
        external
        reinitializer(3)
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (pxom_ == address(0)) revert InvalidAddress();
        // Defense-in-depth (audit Low): reject a non-zero but CODE-LESS
        // address. Because {IPrivateERC20-transferFromGT}/{transferGT}
        // return void, a call to an EOA would silently no-op (Solidity
        // inserts no extcodesize check), making both the stake pull and the
        // unstake payout do nothing. Binding must point at the real pXOM
        // contract; an EOA typo is rejected up front.
        if (pxom_.code.length == 0) revert InvalidAddress();
        privateToken = IPrivateERC20(pxom_);
        emit PrivateTokenSet(pxom_);
    }

    /**
     * @notice Admin-gated update of committee (N, M) parameters. Pioneer
     *         Phase: DEPLOYER EOA holds DEFAULT_ADMIN_ROLE with zero delay.
     * @param newCommitteeSize New N.
     * @param newQuorumM New M.
     */
    function setCommitteeParameters(
        uint256 newCommitteeSize,
        uint256 newQuorumM
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setCommitteeParameters(newCommitteeSize, newQuorumM);
    }

    /**
     * @notice Admin-gated emergency override of the eligible-set snapshot.
     *         Used when every previous-snapshot signer is unreachable and
     *         a signed `pushEligibleSetUpdate` cannot succeed.
     * @param set Sorted-ascending, deduped eligible-set.
     * @param l1Block L1 block at which the source pool was computed.
     * @param sequence Monotonic id; must exceed the current sequence.
     */
    function bootstrapEligibleSet(
        address[] calldata set,
        uint256 l1Block,
        uint256 sequence
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        address[] memory mem = new address[](set.length);
        for (uint256 i = 0; i < set.length; ++i) mem[i] = set[i];
        _bootstrapSnapshot(mem, l1Block, sequence);
    }

    /**
     * @notice Admin-gated, one-way enablement of mandatory commit-block seed
     *         pinning for `_verifyCommittee` (COMMITTEE-GRINDING fix — see
     *         {CommitteeSeedPinningLib}). Once enabled it can never be
     *         disabled again ({CommitteeAttestor-_requireCommitteeSeedPinning}
     *         sets a one-way latch).
     * @dev Off-chain committee coordinators MUST call
     *      `requestCommitteeSeed(digest)` and use the pinned block returned
     *      by `pinnedCommitBlock(digest)` when assembling a committee proof
     *      once this is enabled — every subsequent `*WithCommittee` call
     *      whose proof carries an unpinned/mismatched `commitBlock` will
     *      revert. Do not enable until the off-chain coordinator is
     *      confirmed to be pinning-aware.
     */
    function requireCommitteeSeedPinning() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _requireCommitteeSeedPinning();
    }

    // ========================================================================
    // EXTERNAL — STAKE LIFECYCLE
    // ========================================================================

    /**
     * @notice Open a new stake from a signed `StakeIntent` — legacy
     *         `RELAYER_ROLE`-gated path.
     * @dev Thin wrapper that delegates to {_executeStake} after the
     *      role check. Retained for compatibility while the committee
     *      path ({stakeWithCommittee}) is being rolled out; once that
     *      path is stable for 30 days a follow-up upgrade removes
     *      both this entry and the role itself. The staker's EIP-712
     *      signature binds the `amountCommit` (hash of the encrypted
     *      principal), both tier indices, the nonce, and the deadline
     *      — so the relayer cannot substitute any of those.
     *
     *      Tier verification: {_executeStake} performs an MPC range
     *      check that `encAmount ∈ [thresholds[tier], thresholds[tier+1])`
     *      (or `[thresholds[4], ∞)` for the top tier), decrypts the
     *      resulting bool (1 bit of information), and reverts on
     *      failure. The stake amount itself stays encrypted.
     * @param stakeId Unique stake identifier.
     * @param staker Staker EOA.
     * @param encAmount Encrypted principal (ctUint256).
     * @param amountTier Claimed amount tier (0..4).
     * @param durationTier Claimed duration tier (0..3).
     * @param stakerNonce Expected staker nonce (replay protection).
     * @param deadline Unix-seconds deadline.
     * @param stakerSignature EIP-712 signature.
     */
    function stake(
        bytes32 stakeId,
        address staker,
        ctUint256 calldata encAmount,
        uint8 amountTier,
        uint8 durationTier,
        uint256 stakerNonce,
        uint256 deadline,
        bytes calldata stakerSignature
    ) external onlyRole(RELAYER_ROLE) whenNotPaused nonReentrant {
        // Fail fast before the MPC onBoard if the backing token is unbound
        // (settlement-direct escrow requires custody; see {initializeV3}).
        if (address(privateToken) == address(0)) revert PrivateTokenNotSet();
        // Relayer path: the encrypted principal is treated as a network
        // ctUint256. Encrypted-INPUT via a relayer cannot use
        // validateCiphertext (which binds to msg.sender); the committee
        // path is the trustless route for user-supplied itUint256 input.
        gtUint256 amountG = MpcCore.onBoard(encAmount);
        _executeStake(
            stakeId,
            staker,
            encAmount,
            amountG,
            amountTier,
            durationTier,
            stakerNonce,
            deadline,
            stakerSignature
        );
    }

    /**
     * @notice Open a new stake from a signed `StakeIntent` — committee
     *         attestation path.
     * @dev Replaces the static `RELAYER_ROLE` allowlist with a random
     *      M-of-N validator committee per
     *      `memory/decision_privacy_roles_random_committee_2026-05-27.md`.
     *      Two independent gates must pass:
     *        1. Staker's EIP-712 `StakeIntent` signature recovers to
     *           `staker` (verified in {_executeStake}).
     *        2. `attestationVerifier.verify(digest, committeeProof)`
     *           returns `(true, attesters[])` where the attester list
     *           does NOT contain `staker` (subject ∉ committee — the
     *           audit Pass-1 C-2 fix from the Phase 2 attestation
     *           remediation).
     *      The digest hashed over in both gates is the SAME EIP-712
     *      digest, so a successful committee attestation is a
     *      cryptographic proof that ≥M validators independently saw
     *      the same payload before this tx was submitted.
     *
     *      Caller authorisation: anyone may submit (no `RELAYER_ROLE`
     *      check) — the committee signatures + the staker signature
     *      together carry every authorisation needed.
     *
     *      Side effect: emits {StakeCommitteeAttested} with the
     *      attester list so off-chain slashing pipelines aren't
     *      dependent on `blockhash(commitBlock)` (256-block window).
     * @param stakeId Unique stake identifier.
     * @param staker Staker EOA.
     * @param encAmount Encrypted principal (ctUint256).
     * @param amountTier Claimed amount tier (0..4).
     * @param durationTier Claimed duration tier (0..3).
     * @param stakerNonce Expected staker nonce (replay protection).
     * @param deadline Unix-seconds deadline.
     * @param stakerSignature EIP-712 signature.
     * @param committeeProof Verifier-specific opaque blob (`bytes`)
     *        containing the M-of-N committee signatures over the
     *        same EIP-712 digest as {stakerSignature}. See
     *        {RandomCommitteeVerifier.verify} for the canonical
     *        ECDSA encoding.
     */
    function stakeWithCommittee(
        bytes32 stakeId,
        address staker,
        itUint256 calldata encAmount,
        uint8 amountTier,
        uint8 durationTier,
        uint256 stakerNonce,
        uint256 deadline,
        bytes calldata stakerSignature,
        bytes calldata committeeProof
    ) external whenNotPaused nonReentrant {
        // Fail fast before any committee/MPC work if the backing token is
        // unbound (settlement-direct escrow requires custody; see
        // {initializeV3}).
        if (address(privateToken) == address(0)) revert PrivateTokenNotSet();
        // Audit Pass-3 H-01 — fast-reject BEFORE the expensive
        // _verifyCommittee call to prevent DoS on stale or replayed
        // intents. Defense-in-depth: _executeStake re-checks too.
        // solhint-disable-next-line not-rely-on-time, gas-strict-inequalities
        if (deadline <= block.timestamp) revert DeadlineExpired();
        if (stakes[stakeId].status != StakeStatus.EMPTY) {
            revert StakeAlreadyExists();
        }
        if (nonces[staker] != stakerNonce) revert InvalidNonce();

        bytes32 digest = _stakeIntentDigest(
            stakeId,
            staker,
            encAmount.ciphertext,
            amountTier,
            durationTier,
            stakerNonce,
            deadline
        );

        (bool valid, address[] memory attesters) =
            _verifyCommittee(digest, committeeProof);
        if (!valid) revert InvalidCommitteeAttestation();

        // Defense-in-depth (audit Pass-2 finding F-8): reject empty
        // attester arrays. `IBridgeVerifier.verify` is documented as
        // returning an empty array iff `valid` is false, but a buggy
        // or misconfigured verifier returning `(true, [])` would
        // bypass the subject-not-in-committee loop entirely. The
        // staker EIP-712 signature still binds the operation, so the
        // worst case under an empty-attester pass is that `_executeStake`
        // accepts a stake the staker did sign — but the attester list
        // is load-bearing for off-chain slashing (see
        // memory/decision_privacy_roles_random_committee_2026-05-27.md).
        uint256 attesterCount = attesters.length;
        if (attesterCount == 0) revert InvalidCommitteeAttestation();
        for (uint256 i = 0; i < attesterCount; ) {
            if (attesters[i] == staker) revert SubjectInCommittee();
            unchecked {
                ++i;
            }
        }

        emit StakeCommitteeAttested(stakeId, attesters);

        // Validate the user-supplied encrypted INPUT (itUint256): binds the
        // ciphertext to msg.sender (the staker, who broadcasts this tx) +
        // this contract + this function selector, and yields a network
        // gtUint256 handle. Replaces the broken `onBoard(ctUint256)` path,
        // which expected a network ciphertext the client cannot produce.
        gtUint256 amountG = MpcCore.validateCiphertext(encAmount);
        _executeStake(
            stakeId,
            staker,
            encAmount.ciphertext,
            amountG,
            amountTier,
            durationTier,
            stakerNonce,
            deadline,
            stakerSignature
        );
    }

    /**
     * @notice Checkpoint accrued rewards into the staker's accumulated
     *         balance. Anyone can call (gasless harvest pattern).
     * @param stakeId Stake identifier.
     */
    function accrue(bytes32 stakeId) external nonReentrant {
        Stake storage entry = stakes[stakeId];
        if (entry.status != StakeStatus.ACTIVE) revert StakeNotActive();
        _accrueRewards(entry);
        // solhint-disable-next-line not-rely-on-time
        emit RewardsAccrued(stakeId, entry.owner, block.timestamp);
    }

    /**
     * @notice Close an active stake. Only callable by the staker.
     * @dev For escrowed (V3+) stakes, principal is released as REAL pXOM from
     *      vault custody via {IPrivateERC20-transferGT}; for legacy pre-V3
     *      stakes (no pXOM ever escrowed) the original encrypted-accumulator
     *      payout is preserved. Two paths in each case:
     *        1. `block.timestamp >= entry.lockEnd` — full payout: principal
     *           (custody for escrowed, accumulator for legacy) + accrued
     *           rewards credited to the staker's encrypted accumulator (the
     *           {BalanceClaimed} bridge; rewards never draw on vault custody).
     *        2. `block.timestamp < entry.lockEnd` — early-exit penalty:
     *           - Forfeit ALL unaccrued rewards (since `lastAccrualAt`).
     *           - Pay `earlyPenaltyBps` of the principal as a penalty
     *             (to `feeRecipient`).
     *           - Receive principal × (1 − earlyPenaltyBps).
     *      NOT gated by `whenNotPaused` so the user can always exit.
     *
     *      Uses raw `msg.sender` instead of `_msgSender()` (audit M-07
     *      fix mirroring PrivateRWAAMM lines 1026-1031) so a malicious
     *      or compromised ERC-2771 forwarder cannot impersonate the
     *      staker and force an early-exit on someone else's stake.
     *      The forwarder path is preserved on {stake} where the
     *      staker's separate EIP-712 signature blocks impersonation.
     * @param stakeId Stake identifier.
     */
    function unstake(bytes32 stakeId) external nonReentrant {
        Stake storage entry = stakes[stakeId];
        if (entry.status != StakeStatus.ACTIVE) revert StakeNotActive();
        if (msg.sender != entry.owner) revert NotStaker();

        // solhint-disable-next-line not-rely-on-time, gas-strict-inequalities
        bool earlyExit = block.timestamp < entry.lockEnd;

        // Checks-Effects-Interactions: close the stake BEFORE any external
        // pXOM transfer (audit Informational, CEI hygiene). Redundant with
        // `nonReentrant` + the callback-free `transferGT` (no receiver hook)
        // + the admin-bound trusted `privateToken`, but defense-in-depth.
        entry.status = StakeStatus.WITHDRAWN;

        gtUint256 principalG = MpcCore.onBoard(entry.encAmount);

        if (entry.escrowed) {
            // Settlement-direct (V3+): release REAL pXOM out of vault custody.
            // Principal is conserved one-to-one with the {transferFromGT} pull
            // at stake; rewards (full-exit) accrue into the encrypted
            // accumulator / {BalanceClaimed} bridge and never draw on the
            // vault's escrowed pXOM balance.
            if (!earlyExit) {
                // Full payout: principal from custody + remaining rewards via
                // the bridge accumulator.
                _accrueRewards(entry);
                privateToken.transferGT(entry.owner, principalG);
            } else {
                // Early exit: principal × (1 − penaltyBps) → staker;
                // penalty → feeRecipient. Both paid from custody. Unaccrued
                // rewards forfeited (no _accrueRewards call).
                (gtUint256 penaltyG, gtUint256 payoutG) =
                    _earlyExitSplit(principalG);
                privateToken.transferGT(feeRecipient, penaltyG);
                privateToken.transferGT(entry.owner, payoutG);
            }
        } else {
            // Legacy pre-V3 stake: no pXOM was ever escrowed for it, so keep
            // the original encrypted-accumulator payout (claimable via the
            // {BalanceClaimed} bridge). The vault holds no custody to release
            // for these, so a {transferGT} would revert — the accumulator
            // path is preserved unchanged for backward compatibility.
            if (!earlyExit) {
                _accrueRewards(entry);
                _accumulateG(entry.owner, principalG);
            } else {
                // Penalty accumulator is `feeRecipient` — it can `claim()`
                // like any recipient; funds are NOT stranded at
                // `address(this)` (audit M-02 / fix).
                (gtUint256 penaltyG, gtUint256 payoutG) =
                    _earlyExitSplit(principalG);
                _accumulateG(feeRecipient, penaltyG);
                _accumulateG(entry.owner, payoutG);
            }
        }

        emit StakeClosed(stakeId, entry.owner, earlyExit);
    }

    /**
     * @notice Claim accumulated encrypted balance.
     * @dev Snapshots the pre-reset ciphertext into the event payload and
     *      increments the per-recipient `claimNonce` for bridge idempotency.
     *      NOT gated by `whenNotPaused`.
     *
     *      Uses raw `msg.sender` instead of `_msgSender()` (audit M-07
     *      fix mirroring PrivateRWAAMM lines 1050-1054) so a malicious
     *      or compromised ERC-2771 forwarder cannot forge a `claimant`
     *      to force-reset another holder's accumulator and leak their
     *      ciphertext snapshot via the {BalanceClaimed} event.
     */
    function claim() external nonReentrant {
        address claimant = msg.sender;
        if (!_hasUnclaimed[claimant]) revert NoBalanceToClaim();

        ctUint256 memory snapshot = accumulatedBalances[claimant];
        ctUint256 memory zeroCt = MpcCore.offBoard(MpcCore.setPublic256(0));
        accumulatedBalances[claimant] = zeroCt;
        _hasUnclaimed[claimant] = false;

        uint256 nonce = ++claimNonces[claimant];
        emit BalanceClaimed(
            claimant,
            nonce,
            ctUint128.unwrap(snapshot.ciphertextHigh),
            ctUint128.unwrap(snapshot.ciphertextLow)
        );
    }

    // ========================================================================
    // EXTERNAL — ATTESTATION VERIFIER WIRING (PIONEER PHASE)
    // ========================================================================

    /**
     * @notice Point the random-committee attestation verifier used by
     *         {stakeWithCommittee}.
     * @dev Pioneer Phase admin model (per
     *      `memory/feedback_no_builtin_timelocks.md`): the deployer
     *      EOA holds `DEFAULT_ADMIN_ROLE` and changes take effect
     *      immediately — no 48 h two-step. The two existing
     *      timelocked setters on this contract (`requestFeeRecipient`,
     *      `requestPenaltyUpdate`) predate the rule clarification
     *      and are documented gaps; new admin setters follow the
     *      zero-delay pattern. Once Pioneer ends, the
     *      `DEFAULT_ADMIN_ROLE` holder transitions from the deployer
     *      EOA to `OmniTimelockController` + governance — at which
     *      point a 7-day governance delay applies *to the admin
     *      transfer itself*, not to a per-setter built-in delay.
     *
     *      Setting `address(0)` is rejected; to disable the
     *      committee path without unsetting the slot, set a verifier
     *      whose `quorumThreshold()` exceeds the eligible pool.
     * @param newVerifier `IBridgeVerifier` implementation (typically
     *        a `RandomCommitteeVerifier` proxy).
     */
    function setAttestationVerifier(IBridgeVerifier newVerifier)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (address(newVerifier) == address(0)) revert InvalidAddress();
        // Defense-in-depth (audit Pass-2 finding M-01): probe the new
        // verifier implements `IBridgeVerifier` before adopting it.
        // A typo in the deployer transaction that lands at an
        // unrelated contract address would otherwise silently brick
        // {stakeWithCommittee} on the next call. `quorumThreshold()`
        // is a cheap stateless view that every `IBridgeVerifier`
        // implementation provides; a contract without it (or a
        // non-contract address) reverts and the swap is rejected
        // up-front. Does NOT defend against an adversarial deployer
        // who deliberately wires a malicious verifier — that risk is
        // explicitly accepted under the Pioneer Phase admin model.
        try newVerifier.quorumThreshold() returns (uint256) {
            // Implementation present; proceed.
        } catch {
            revert InvalidVerifier();
        }
        attestationVerifier = newVerifier;
        emit AttestationVerifierSet(newVerifier);
    }

    // ========================================================================
    // EXTERNAL — ADMIN (TIMELOCKED SETTERS)
    // ========================================================================

    /**
     * @notice Queue an early-withdrawal penalty update.
     * @param newPenaltyBps New penalty in basis points (max {MAX_EARLY_PENALTY_BPS}).
     */
    function requestPenaltyUpdate(uint64 newPenaltyBps)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (newPenaltyBps > MAX_EARLY_PENALTY_BPS) revert PenaltyTooHigh();
        if (pendingPenalty.effectiveAt != 0) revert TimelockAlreadyRequested();
        // solhint-disable-next-line not-rely-on-time
        uint256 effectiveAt = block.timestamp + TIMELOCK_DELAY;
        pendingPenalty = PendingPenalty({
            newPenaltyBps: newPenaltyBps,
            effectiveAt: effectiveAt
        });
        emit PenaltyUpdateQueued(newPenaltyBps, effectiveAt);
    }

    /**
     * @notice Apply the queued penalty update.
     */
    function confirmPenaltyUpdate() external onlyRole(DEFAULT_ADMIN_ROLE) {
        PendingPenalty memory pending = pendingPenalty;
        if (pending.effectiveAt == 0) revert TimelockNotRequested();
        // solhint-disable-next-line not-rely-on-time, gas-strict-inequalities
        if (block.timestamp < pending.effectiveAt) revert TimelockDelayNotElapsed();
        uint64 oldPen = earlyPenaltyBps;
        earlyPenaltyBps = pending.newPenaltyBps;
        delete pendingPenalty;
        emit PenaltyUpdated(oldPen, pending.newPenaltyBps);
    }

    /**
     * @notice Cancel the queued penalty update.
     */
    function cancelPendingPenaltyUpdate()
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (pendingPenalty.effectiveAt == 0) revert TimelockNotRequested();
        delete pendingPenalty;
        emit PendingUpdateCancelled("penalty");
    }

    /**
     * @notice Queue a trusted-forwarder update.
     * @param newForwarder New ERC-2771 forwarder; `address(0)` to disable.
     */
    function requestTrustedForwarderUpdate(address newForwarder)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (pendingForwarder.effectiveAt != 0) revert TimelockAlreadyRequested();
        // solhint-disable-next-line not-rely-on-time
        uint256 effectiveAt = block.timestamp + TIMELOCK_DELAY;
        pendingForwarder = PendingForwarder({
            forwarder: newForwarder,
            effectiveAt: effectiveAt
        });
        emit TrustedForwarderUpdateQueued(newForwarder, effectiveAt);
    }

    /**
     * @notice Apply the queued forwarder update.
     */
    function confirmTrustedForwarderUpdate()
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        PendingForwarder memory pending = pendingForwarder;
        if (pending.effectiveAt == 0) revert TimelockNotRequested();
        // solhint-disable-next-line not-rely-on-time, gas-strict-inequalities
        if (block.timestamp < pending.effectiveAt) revert TimelockDelayNotElapsed();
        address old = trustedForwarder;
        trustedForwarder = pending.forwarder;
        delete pendingForwarder;
        emit TrustedForwarderUpdated(old, pending.forwarder);
    }

    /**
     * @notice Cancel the queued forwarder update.
     */
    function cancelPendingTrustedForwarderUpdate()
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (pendingForwarder.effectiveAt == 0) revert TimelockNotRequested();
        delete pendingForwarder;
        emit PendingUpdateCancelled("trustedForwarder");
    }

    /**
     * @notice Queue a fee-recipient update.
     * @dev Reverts on `address(0)` and `address(this)` — same invariant
     *      as `initialize` (penalty accumulator must be a claimable
     *      recipient).
     * @param newRecipient New fee recipient.
     */
    function requestFeeRecipientUpdate(address newRecipient)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (newRecipient == address(0)) revert InvalidAddress();
        if (newRecipient == address(this)) revert InvalidAddress();
        if (pendingFeeRecipient.effectiveAt != 0) {
            revert TimelockAlreadyRequested();
        }
        // solhint-disable-next-line not-rely-on-time
        uint256 effectiveAt = block.timestamp + TIMELOCK_DELAY;
        pendingFeeRecipient = PendingFeeRecipient({
            recipient: newRecipient,
            effectiveAt: effectiveAt
        });
        emit FeeRecipientUpdateQueued(newRecipient, effectiveAt);
    }

    /**
     * @notice Apply the queued fee-recipient update.
     */
    function confirmFeeRecipientUpdate()
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        PendingFeeRecipient memory pending = pendingFeeRecipient;
        if (pending.effectiveAt == 0) revert TimelockNotRequested();
        // solhint-disable-next-line not-rely-on-time, gas-strict-inequalities
        if (block.timestamp < pending.effectiveAt) {
            revert TimelockDelayNotElapsed();
        }
        address old = feeRecipient;
        feeRecipient = pending.recipient;
        delete pendingFeeRecipient;
        emit FeeRecipientUpdated(old, pending.recipient);
    }

    /**
     * @notice Cancel the queued fee-recipient update.
     */
    function cancelPendingFeeRecipientUpdate()
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (pendingFeeRecipient.effectiveAt == 0) {
            revert TimelockNotRequested();
        }
        delete pendingFeeRecipient;
        emit PendingUpdateCancelled("feeRecipient");
    }

    // ========================================================================
    // EXTERNAL — ADMIN (PAUSE + OSSIFICATION)
    // ========================================================================

    /// @notice Pause new stakes. Unstake + claim still work.
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /// @notice Resume.
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /// @notice Begin the 7-day ossification window.
    function requestOssification() external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_ossified) revert ContractIsOssified();
        if (ossificationRequestTime != 0) revert OssificationAlreadyRequested();
        // solhint-disable-next-line not-rely-on-time
        ossificationRequestTime = block.timestamp;
        // solhint-disable-next-line not-rely-on-time
        emit OssificationRequested(address(this), block.timestamp);
    }

    /// @notice Cancel a pending ossification request.
    function cancelOssificationRequest()
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (_ossified) revert ContractIsOssified();
        if (ossificationRequestTime == 0) revert OssificationNotRequested();
        ossificationRequestTime = 0;
        emit OssificationRequestCancelled(address(this));
    }

    /// @notice Confirm ossification — irreversible.
    function confirmOssification() external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_ossified) revert ContractIsOssified();
        if (ossificationRequestTime == 0) revert OssificationNotRequested();
        // solhint-disable-next-line not-rely-on-time, gas-strict-inequalities
        if (block.timestamp < ossificationRequestTime + OSSIFICATION_DELAY) {
            revert OssificationDelayNotElapsed();
        }
        _ossified = true;
        // solhint-disable-next-line not-rely-on-time
        emit ContractOssified(address(this), block.timestamp);
    }

    /**
     * @notice Queue a UUPS implementation upgrade (audit H-05 back-port).
     * @dev Adds a 48 h grace window between request and execution so
     *      users can detect a malicious-implementation swap before it
     *      becomes live. The first upgrade FROM the pre-back-port impl
     *      is unaffected (the OLD impl had no `pendingUpgrade`
     *      requirement); every subsequent upgrade enforces this gate.
     * @param newImplementation New implementation address.
     */
    function requestUpgrade(address newImplementation)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (_ossified) revert ContractIsOssified();
        if (newImplementation == address(0)) revert InvalidAddress();
        if (pendingUpgrade.effectiveAt != 0) {
            revert TimelockAlreadyRequested();
        }
        // solhint-disable-next-line not-rely-on-time
        uint256 effectiveAt = block.timestamp + TIMELOCK_DELAY;
        pendingUpgrade = PendingUpgrade({
            newImplementation: newImplementation,
            effectiveAt: effectiveAt
        });
        emit UpgradeQueued(newImplementation, effectiveAt);
    }

    /**
     * @notice Cancel the queued upgrade.
     */
    function cancelPendingUpgrade()
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (pendingUpgrade.effectiveAt == 0) revert TimelockNotRequested();
        address cancelled = pendingUpgrade.newImplementation;
        delete pendingUpgrade;
        emit UpgradeCancelled(cancelled);
    }

    // ========================================================================
    // EXTERNAL — VIEWS
    // ========================================================================

    /**
     * @notice EIP-712 domain separator.
     * @return Current domain separator.
     */
    function domainSeparatorV4() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /**
     * @notice Has this proxy been ossified?
     * @return True if upgrades are permanently disabled.
     */
    function isOssified() external view returns (bool) {
        return _ossified;
    }

    // ========================================================================
    // PUBLIC — ROLE OVERRIDES + FORWARDER CHECK
    // ========================================================================

    /**
     * @notice Disallow renouncing `DEFAULT_ADMIN_ROLE` to prevent bricking.
     * @inheritdoc AccessControlUpgradeable
     */
    function renounceRole(bytes32 role, address callerConfirmation)
        public
        override
    {
        if (role == DEFAULT_ADMIN_ROLE) revert CannotRenounceAdmin();
        super.renounceRole(role, callerConfirmation);
    }

    /**
     * @notice ERC-2771 forwarder check.
     * @param forwarder Candidate forwarder address.
     * @return True if `forwarder` is the current trusted forwarder.
     */
    function isTrustedForwarder(address forwarder) public view returns (bool) {
        return forwarder != address(0) && forwarder == trustedForwarder;
    }

    // ========================================================================
    // PUBLIC — PURE
    // ========================================================================

    /**
     * @notice Compute the APR (basis points) for a given tier pair.
     * @param amountTier Amount tier (0..4).
     * @param durationTier Duration tier (0..3).
     * @return Total APR in basis points.
     */
    function aprBpsFor(uint8 amountTier, uint8 durationTier)
        public
        pure
        returns (uint256)
    {
        // solhint-disable-next-line gas-strict-inequalities
        if (amountTier >= AMOUNT_TIER_COUNT) revert InvalidAmountTier();
        // solhint-disable-next-line gas-strict-inequalities
        if (durationTier >= DURATION_TIER_COUNT) revert InvalidDurationTier();
        // 5–9 % base + 0–3 % duration bonus = 5–12 % total.
        return 500 + (uint256(amountTier) * 100) + (uint256(durationTier) * 100);
    }

    // ========================================================================
    // INTERNAL
    // ========================================================================

    /**
     * @dev UUPS authorization — denies upgrades once ossified, and
     *      enforces the 48 h two-step timelock from {requestUpgrade}
     *      (audit H-05 back-port). The caller must (a) hold
     *      DEFAULT_ADMIN_ROLE, (b) have queued THIS exact
     *      `newImplementation` via `requestUpgrade`, and (c) wait until
     *      `effectiveAt`. The pending entry is cleared on success so it
     *      cannot be replayed.
     *
     *      State mutation here (clearing `pendingUpgrade`) makes the
     *      function non-`view` — diverges from the OZ default but is
     *      a documented pattern for timelocked UUPS upgrades.
     */
    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (_ossified) revert ContractIsOssified();
        if (newImplementation == address(0)) revert InvalidAddress();
        PendingUpgrade memory pending = pendingUpgrade;
        if (
            pending.effectiveAt == 0
                || pending.newImplementation != newImplementation
        ) {
            revert UpgradeNotAuthorized();
        }
        // solhint-disable-next-line not-rely-on-time, gas-strict-inequalities
        if (block.timestamp < pending.effectiveAt) {
            revert TimelockDelayNotElapsed();
        }
        delete pendingUpgrade;
    }

    /**
     * @notice ERC-2771 sender resolution.
     * @return sender Resolved sender address.
     * @inheritdoc ContextUpgradeable
     */
    function _msgSender()
        internal
        view
        override(ContextUpgradeable)
        returns (address sender)
    {
        // solhint-disable-next-line gas-strict-inequalities
        if (msg.sender == trustedForwarder && msg.data.length >= 20) {
            assembly {
                sender := shr(96, calldataload(sub(calldatasize(), 20)))
            }
        } else {
            sender = msg.sender;
        }
    }

    /**
     * @notice ERC-2771 calldata resolution.
     * @inheritdoc ContextUpgradeable
     */
    function _msgData()
        internal
        view
        override(ContextUpgradeable)
        returns (bytes calldata)
    {
        // solhint-disable-next-line gas-strict-inequalities
        if (msg.sender == trustedForwarder && msg.data.length >= 20) {
            return msg.data[:msg.data.length - 20];
        }
        return msg.data;
    }

    /**
     * @notice ERC-2771 trailing-byte length.
     * @return 20 when forwarder relayed, 0 otherwise.
     */
    function _contextSuffixLength()
        internal
        view
        override(ContextUpgradeable)
        returns (uint256)
    {
        // solhint-disable-next-line gas-strict-inequalities
        return (msg.sender == trustedForwarder && msg.data.length >= 20) ? 20 : 0;
    }

    /**
     * @notice Internal stake processor shared by both external entry
     *         points ({stake} and {stakeWithCommittee}).
     * @dev Single-source-of-truth. Caller is responsible for relayer
     *      or committee authorisation; this helper only verifies
     *      the staker's EIP-712 signature, MPC tier range, and
     *      writes state.
     * @param stakeId Unique stake identifier.
     * @param staker Staker EOA.
     * @param encAmount Encrypted-principal ciphertext (`ctUint256`), used for
     *        the `StakeIntent` amount commitment. The caller has already
     *        resolved it to the `amountG` handle below.
     * @param amountG Validated MPC handle for the principal (from
     *        `validateCiphertext` on the committee path, or `onBoard` on the
     *        relayer path). Range-checked and offBoarded into storage here.
     * @param amountTier Claimed amount tier (0..4).
     * @param durationTier Claimed duration tier (0..3).
     * @param stakerNonce Expected staker nonce (replay protection).
     * @param deadline Unix-seconds deadline.
     * @param stakerSignature EIP-712 signature over `StakeIntent`.
     */
    function _executeStake( // solhint-disable-line code-complexity
        bytes32 stakeId,
        address staker,
        ctUint256 calldata encAmount,
        gtUint256 amountG,
        uint8 amountTier,
        uint8 durationTier,
        uint256 stakerNonce,
        uint256 deadline,
        bytes calldata stakerSignature
    ) private {
        if (staker == address(0)) revert InvalidAddress();
        // solhint-disable-next-line not-rely-on-time, gas-strict-inequalities
        if (deadline <= block.timestamp) revert DeadlineExpired();
        if (stakes[stakeId].status != StakeStatus.EMPTY) {
            revert StakeAlreadyExists();
        }
        if (nonces[staker] != stakerNonce) revert InvalidNonce();
        // solhint-disable-next-line gas-strict-inequalities
        if (amountTier >= AMOUNT_TIER_COUNT) revert InvalidAmountTier();
        // solhint-disable-next-line gas-strict-inequalities
        if (durationTier >= DURATION_TIER_COUNT) revert InvalidDurationTier();
        // Settlement-direct escrow (V3): the backing pXOM token MUST be bound
        // via {initializeV3} before any escrowed stake can open, else the
        // principal pull below would silently no-op against a code-less
        // address and the vault would credit APR on funds it never holds.
        if (address(privateToken) == address(0)) revert PrivateTokenNotSet();

        bytes32 digest = _stakeIntentDigest(
            stakeId,
            staker,
            encAmount,
            amountTier,
            durationTier,
            stakerNonce,
            deadline
        );
        if (ECDSA.recover(digest, stakerSignature) != staker) {
            revert InvalidStakerSignature();
        }

        // MPC range check: principal ∈ [thresholds[tier], thresholds[tier+1]).
        if (!_verifyAmountTier(amountG, amountTier)) {
            revert AmountTierVerificationFailed();
        }

        unchecked {
            ++nonces[staker];
        }

        // solhint-disable-next-line not-rely-on-time
        uint256 nowTs = block.timestamp;
        // Persist the principal as a NETWORK ctUint256 (offBoard of the
        // validated handle) so unstake/accrue can re-`onBoard` it. The raw
        // input ciphertext is user-key encrypted and is NOT onBoard-able.
        ctUint256 memory storedAmount = MpcCore.offBoard(amountG);
        stakes[stakeId] = Stake({
            owner: staker,
            encAmount: storedAmount,
            stakedAt: nowTs,
            lockEnd: nowTs + durationLockPeriods[durationTier],
            lastAccrualAt: nowTs,
            amountTier: amountTier,
            durationTier: durationTier,
            status: StakeStatus.ACTIVE,
            escrowed: true
        });

        unchecked {
            ++totalStakes;
        }

        // Take real pXOM custody: pull the staker's principal into the vault.
        // Mirrors {PrivateMarketplaceEscrow.createEscrow} — the staker
        // pre-approves this contract as an encrypted-allowance spender; the
        // pull reverts privacy-safely (only a success bit is ever decrypted,
        // never the amount) on insufficient balance/allowance, so an opened
        // stake is always fully funded. `amountG` is the already-validated
        // principal handle (range-checked above), reused here to avoid a
        // redundant onBoard.
        privateToken.transferFromGT(staker, address(this), amountG);

        emit StakeOpened(
            stakeId,
            staker,
            amountTier,
            durationTier,
            stakes[stakeId].lockEnd
        );
    }

    /**
     * @dev Verify the staker's claimed `amountTier` matches their encrypted
     *      principal via MPC range check. Returns false on failure (caller
     *      reverts). Reveals exactly one bit of information: claim valid
     *      or not.
     *
     *      The boolean combination of the lower- and upper-bound checks
     *      is performed in MPC space (`MpcCore.and(geLow, ltHigh)`)
     *      followed by a single `decrypt(...)` call. This collapses the
     *      observable side-channel to a single bit; using two separate
     *      `decrypt(...)` calls joined by Solidity's short-circuit `&&`
     *      would leak ~`log2(3) ≈ 1.58` bits via gas / trace ordering
     *      (audit M-01 from Phase 6.1 review).
     *
     *      Tier 0 is special-cased to skip the lower-bound check —
     *      `thresholds[0] == 0` is enforced at `initialize` and
     *      `checkedSub(0, 1)` would otherwise revert via underflow.
     */
    function _verifyAmountTier(gtUint256 amountG, uint8 tier)
        private
        returns (bool)
    {
        // Top tier — only lower bound matters.
        if (tier == AMOUNT_TIER_COUNT - 1) {
            gtUint256 lowG =
                MpcCore.setPublic256(amountThresholds[tier]);
            gtBool geLow = MpcCore.gt(
                amountG, MpcCore.checkedSub(lowG, MpcCore.setPublic256(1))
            );
            return MpcCore.decrypt(geLow);
        }

        gtUint256 highG = MpcCore.setPublic256(amountThresholds[tier + 1]);
        gtBool ltHigh = MpcCore.lt(amountG, highG);

        // Tier 0 — `thresholds[0] == 0`, so any non-negative value
        // satisfies the lower bound; only the upper bound is informative.
        if (tier == 0) {
            return MpcCore.decrypt(ltHigh);
        }

        gtUint256 lowMid = MpcCore.setPublic256(amountThresholds[tier]);
        gtBool geLowMid = MpcCore.gt(
            amountG, MpcCore.checkedSub(lowMid, MpcCore.setPublic256(1))
        );
        // AND in MPC space, then single decrypt — one bit of leakage.
        gtBool inRangeG = MpcCore.and(geLowMid, ltHigh);
        return MpcCore.decrypt(inRangeG);
    }

    /**
     * @dev Accrue rewards for a stake into the owner's encrypted balance.
     *      Reward = principal × aprBps × elapsed / (10000 × secondsPerYear).
     *
     *      Accrual is capped at `entry.lockEnd`: after the lock window
     *      expires the duration-tier APR bonus stops compounding. The
     *      duration-tier component of the APR rewards committing
     *      capital for a fixed window — paying that bonus indefinitely
     *      past `lockEnd` (where the stake is freely withdrawable)
     *      would mean a 2-year-tier stake left untouched for 5 years
     *      captures the 12% top APR for the full 5 years even though
     *      its commitment ended at year 2. The cap closes that gap;
     *      stakers who want to keep accruing past lock-end must
     *      `unstake` (claiming principal + accrued rewards) and open
     *      a fresh stake at the duration tier they're willing to
     *      commit to.
     */
    function _accrueRewards(Stake storage entry) private {
        // solhint-disable-next-line not-rely-on-time
        uint256 nowTs = block.timestamp;
        uint256 accrualCeiling =
            nowTs < entry.lockEnd ? nowTs : entry.lockEnd;
        // solhint-disable-next-line gas-strict-inequalities
        if (accrualCeiling <= entry.lastAccrualAt) {
            entry.lastAccrualAt = accrualCeiling;
            return;
        }
        uint256 elapsed = accrualCeiling - entry.lastAccrualAt;
        uint256 aprBps = aprBpsFor(entry.amountTier, entry.durationTier);
        // rewards = encAmount * aprBps * elapsed / (BASIS_POINTS_DIVISOR * SECONDS_PER_YEAR).
        // Use a single mul-mul-div sequence to keep precision.
        gtUint256 principalG = MpcCore.onBoard(entry.encAmount);
        gtUint256 numG = MpcCore.checkedMul(
            MpcCore.checkedMul(principalG, MpcCore.setPublic256(aprBps)),
            MpcCore.setPublic256(elapsed)
        );
        gtUint256 denom =
            MpcCore.setPublic256(BASIS_POINTS_DIVISOR * SECONDS_PER_YEAR);
        gtUint256 rewardG = MpcCore.div(numG, denom);
        _accumulateG(entry.owner, rewardG);
        entry.lastAccrualAt = accrualCeiling;
    }

    /**
     * @notice Split a principal handle into the early-withdrawal penalty and
     *         the staker payout.
     * @dev `penalty = principal × earlyPenaltyBps / 10000`,
     *      `payout = principal − penalty`. Shared by the escrowed (custody
     *      {IPrivateERC20-transferGT}) and legacy (accumulator) {unstake}
     *      branches.
     * @param principalG Onboarded principal handle.
     * @return penaltyG Encrypted penalty amount.
     * @return payoutG Encrypted staker payout amount.
     */
    function _earlyExitSplit(gtUint256 principalG)
        private
        returns (gtUint256 penaltyG, gtUint256 payoutG)
    {
        uint64 pen = earlyPenaltyBps;
        penaltyG = MpcCore.div(
            MpcCore.checkedMul(principalG, MpcCore.setPublic256(uint256(pen))),
            MpcCore.setPublic256(BASIS_POINTS_DIVISOR)
        );
        payoutG = MpcCore.checkedSub(principalG, penaltyG);
    }

    /// @dev Add an encrypted delta to a recipient's accumulated balance.
    function _accumulateG(address recipient, gtUint256 deltaG) private {
        bool hasPrior = _hasUnclaimed[recipient];
        gtUint256 newG = hasPrior
            ? MpcCore.checkedAdd(MpcCore.onBoard(accumulatedBalances[recipient]), deltaG)
            : deltaG;
        accumulatedBalances[recipient] = MpcCore.offBoard(newG);
        if (!hasPrior) _hasUnclaimed[recipient] = true;
    }

    /**
     * @notice Compute the EIP-712 digest of a `StakeIntent` payload.
     * @dev Extracted from {_executeStake} so {stakeWithCommittee} can
     *      verify the committee signed over the SAME digest the staker
     *      did, without re-computing inside the verifier.
     * @param stakeId Unique stake identifier.
     * @param staker Staker EOA.
     * @param encAmount Encrypted principal (ctUint256).
     * @param amountTier Claimed amount tier (0..4).
     * @param durationTier Claimed duration tier (0..3).
     * @param stakerNonce Expected staker nonce (replay protection).
     * @param deadline Unix-seconds deadline.
     * @return The EIP-712 digest.
     */
    function _stakeIntentDigest(
        bytes32 stakeId,
        address staker,
        ctUint256 calldata encAmount,
        uint8 amountTier,
        uint8 durationTier,
        uint256 stakerNonce,
        uint256 deadline
    ) private view returns (bytes32) {
        bytes32 amountCommit = _commit(encAmount);
        bytes32 structHash = keccak256(
            abi.encode(
                STAKE_INTENT_TYPEHASH,
                stakeId,
                staker,
                amountCommit,
                amountTier,
                durationTier,
                stakerNonce,
                deadline
            )
        );
        return _hashTypedDataV4(structHash);
    }

    /**
     * @dev Hash an encrypted-amount ciphertext into a 32-byte commitment.
     */
    function _commit(ctUint256 calldata ct) private pure returns (bytes32) {
        return keccak256(
            abi.encode(
                ctUint128.unwrap(ct.ciphertextHigh),
                ctUint128.unwrap(ct.ciphertextLow)
            )
        );
    }
}
