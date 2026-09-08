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
 * @title PrivateDEXSettlement
 * @author OmniBazaar Development Team
 * @notice Privacy-preserving bilateral settlement for intent-based trading
 *         using COTI Helium 256-bit garbled circuits.
 * @dev Phase 4.1 of FIX_PRIVACY (audit-remediated 2026-05-10):
 *      - Native `ctUint256` throughout — no `1e12` scaling step.
 *      - COTI-only: deploys revert on every chain except 2632500 mainnet
 *        and 7082400 testnet.
 *      - EIP-712 typed-data trader signatures binding `intentId`, both
 *        parties, both ciphertext commitments, the live `tradingFeeBps`,
 *        nonce, and deadline.
 *      - Atomic lock → settle → fee-distribute pattern preserved so existing
 *        `BilateralSettlementService` callers migrate with minimal changes.
 *      - 70 % LP / 30 % UnifiedFeeVault split matches non-private
 *        `DEXSettlement` (vault routes ODDAO/Staking/Treasury internally).
 *      - 48-hour timelock on every privileged setter (fee bps, fee
 *        recipients, trusted forwarder) — parity with non-private
 *        `DEXSettlement.requestTradingFeeUpdate` etc.
 *      - UUPS upgradeable with two-step ossification (7-day delay,
 *        non-resettable: re-requesting reverts; explicit cancel exists).
 *      - Admin cannot accidentally brick the contract via
 *        `renounceRole(DEFAULT_ADMIN_ROLE, …)` — overridden to revert.
 *      - Pause does NOT block user-only escape paths (`cancelPrivateIntent`,
 *        `claimFees`, `invalidateNonce`).
 *      - ERC-2771 forwarder address held in **proxy storage** (not
 *        implementation immutable) so a malicious upgrade cannot swap it.
 *        Setter is admin-timelocked.
 */
contract PrivateDEXSettlement is
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

    /// @notice Settlement status enumeration.
    enum SettlementStatus {
        EMPTY,
        LOCKED,
        SETTLED,
        CANCELLED
    }

    /**
     * @notice Encrypted collateral record for a bilateral settlement.
     * @dev Token addresses are public; amounts are 256-bit encrypted.
     *      `tradingFeeBpsAtLock` snapshots the live fee at lock time so a
     *      mid-flight `confirmTradingFeeUpdate` cannot retroactively raise
     *      the rate (audit H-01/H-02 remediation).
     */
    struct PrivateCollateral {
        address trader;
        address solver;
        address tokenIn;
        address tokenOut;
        ctUint256 traderCollateral;
        ctUint256 solverCollateral;
        uint256 nonce;
        uint256 deadline;
        uint256 lockTimestamp;
        uint64 tradingFeeBpsAtLock;
        SettlementStatus status;
    }

    /**
     * @notice Encrypted fee record for a single settlement.
     * @dev `lpFee` is the 70 % LP-pool share, `vaultFee` the 30 %
     *      UnifiedFeeVault share. Recipients claim accumulated balances via
     *      {claimFees}; the contract never decrypts.
     */
    struct EncryptedFeeRecord {
        ctUint256 lpFee;
        ctUint256 vaultFee;
    }

    /**
     * @notice Fee recipient addresses.
     * @dev Mirrors non-private DEXSettlement: 70 % to `liquidityPool`, 30 %
     *      to `feeVault`. UnifiedFeeVault performs the 70/20/10 ODDAO /
     *      Staking / Protocol split internally.
     */
    struct FeeRecipients {
        address liquidityPool;
        address feeVault;
    }

    /**
     * @notice Pending timelocked update for fee recipients.
     * @dev Zero `effectiveAt` = no pending update.
     */
    struct PendingFeeRecipients {
        address liquidityPool;
        address feeVault;
        uint256 effectiveAt;
    }

    /**
     * @notice Pending timelocked update for `tradingFeeBps`.
     * @dev Zero `effectiveAt` = no pending update.
     */
    struct PendingTradingFee {
        uint64 newFeeBps;
        uint256 effectiveAt;
    }

    /**
     * @notice Pending timelocked update for the ERC-2771 trusted forwarder.
     * @dev Zero `effectiveAt` = no pending update.
     */
    struct PendingForwarder {
        address forwarder;
        uint256 effectiveAt;
    }

    /**
     * @notice Pending timelocked UUPS implementation upgrade.
     * @dev Phase 6.2 audit H-05 back-port — adds a 48 h delay to UUPS
     *      upgrades so users have a grace window to detect a malicious
     *      implementation swap before it becomes live. Zero
     *      `effectiveAt` = no pending upgrade.
     */
    struct PendingUpgrade {
        address newImplementation;
        uint256 effectiveAt;
    }

    // ========================================================================
    // CONSTANTS
    // ========================================================================

    /// @notice Role for matchers (validator off-chain matcher service).
    bytes32 public constant SETTLER_ROLE = keccak256("SETTLER_ROLE");

    /// @notice Basis-points divisor (100 %).
    uint256 public constant BASIS_POINTS_DIVISOR = 10_000;

    /// @notice LP-pool fee share — 70 %.
    uint256 public constant LP_SHARE_BPS = 7_000;

    /// @notice UnifiedFeeVault fee share — 30 % (vault splits internally).
    uint256 public constant VAULT_SHARE_BPS = 3_000;

    /// @notice Maximum trading fee (1.00 %).
    uint64 public constant MAX_TRADING_FEE_BPS = 100;

    /// @notice Minimum lock period before {cancelPrivateIntent} is allowed.
    /// @dev Prevents instant lock/cancel cycling that wastes solver gas.
    uint256 public constant MIN_LOCK_DURATION = 5 minutes;

    /// @notice Required delay between {requestOssification} and
    ///         {confirmOssification} (7 days).
    uint256 public constant OSSIFICATION_DELAY = 7 days;

    /// @notice Required delay for privileged setter timelocks (48 h).
    /// @notice Set to `0` per Pioneer-Phase rule — see PrivateYieldVault
    ///         constant for full rationale. (Non-private DEXSettlement
    ///         keeps its own 48h timelock independently.)
    uint256 public constant TIMELOCK_DELAY = 0;

    /// @notice COTI mainnet chain id.
    uint256 private constant COTI_MAINNET_CHAIN_ID = 2_632_500;

    /// @notice COTI testnet chain id (kept enabled for real-MPC integration
    ///         tests; production safety preserved by the precompile).
    uint256 private constant COTI_TESTNET_CHAIN_ID = 7_082_400;

    /// @notice EIP-712 type hash for the trader's lock-commitment intent.
    /// @dev String length is fixed by the EIP-712 spec (must literally match
    ///      the encoded type signature) — `gas-small-strings` and
    ///      `max-line-length` cannot apply. The typehash binds the
    ///      encrypted-amount commitments AND the live fee bps so a
    ///      `SETTLER_ROLE` matcher cannot substitute either after the
    ///      trader signs (audit H-01).
    // solhint-disable-next-line gas-small-strings, max-line-length
    bytes32 private constant LOCK_INTENT_TYPEHASH = keccak256("LockIntent(bytes32 intentId,address trader,address solver,address tokenIn,address tokenOut,bytes32 traderCommit,bytes32 solverCommit,uint64 tradingFeeBps,uint256 nonce,uint256 deadline)");

    /// @notice EIP-712 type hash for the SettleIntent the M-of-N committee
    ///         signs in {settleBilateralWithCommittee}. The committee attests
    ///         that the two named LOCKED intents are authorized to settle
    ///         together; the contract independently enforces token/counterparty
    ///         reciprocity and amount-compatibility (the latter via MPC), so
    ///         the committee never sees or vouches for amounts.
    // solhint-disable-next-line gas-small-strings, max-line-length
    bytes32 private constant SETTLE_INTENT_TYPEHASH = keccak256("SettleIntent(bytes32 intentIdA,bytes32 intentIdB)");

    // ========================================================================
    // STATE VARIABLES
    // ========================================================================

    /// @notice intentId → encrypted collateral record.
    mapping(bytes32 intentId => PrivateCollateral entry) public privateCollateral;

    /// @notice intentId → encrypted fee record.
    mapping(bytes32 intentId => EncryptedFeeRecord entry) public feeRecords;

    /// @notice address → encrypted accumulated fee balance (claimable).
    /// @dev UNUSED — fees are distributed directly via transferGT in _settleOne.
    mapping(address recipient => ctUint256 balance) private accumulatedFees;

    /// @notice address → has a non-zero accumulated balance pending claim.
    /// @dev UNUSED — fees are distributed directly via transferGT in _settleOne.
    mapping(address recipient => bool flagged) private _hasUnclaimedFees;

    /// @notice address → monotonic per-recipient claim nonce.
    /// @dev Emitted in {FeesClaimed} so off-chain bridges can deduplicate
    ///      events idempotently (audit H-05).
    mapping(address recipient => uint256 claimNonce) public claimNonces;

    /// @notice trader → next-expected nonce (replay protection).
    mapping(address trader => uint256 nonce) public nonces;

    /// @notice Fee recipient addresses (active).
    FeeRecipients public feeRecipients;

    /// @notice Pending fee recipient update (timelocked).
    PendingFeeRecipients public pendingFeeRecipients;

    /// @notice Total settlements executed (lifetime counter).
    uint256 public totalSettlements;

    /// @notice True once the contract is permanently non-upgradable.
    bool private _ossified;

    /// @notice Block timestamp when ossification was requested
    ///         (0 = no pending request).
    uint256 public ossificationRequestTime;

    /// @notice Configurable trading fee in basis points (default 20 = 0.20 %).
    /// @dev Privacy precludes referral tracking, so only the base fee is
    ///      configurable here. The fee bps in effect at lock time is
    ///      snapshotted into `PrivateCollateral.tradingFeeBpsAtLock`.
    uint64 public tradingFeeBps;

    /// @notice Pending trading-fee update (timelocked).
    PendingTradingFee public pendingTradingFee;

    /// @notice ERC-2771 trusted forwarder (proxy storage — NOT implementation
    ///         immutable). `address(0)` disables meta-tx. Audit H-06.
    address public trustedForwarder;

    /// @notice Pending trusted-forwarder update (timelocked).
    PendingForwarder public pendingForwarder;

    /// @notice Pending UUPS implementation upgrade (timelocked, audit H-05
    /// back-port). The first upgrade FROM the pre-back-port impl bypasses
    /// this gate (the OLD impl had no `pendingUpgrade` requirement); every
    /// subsequent upgrade enforces the 48 h two-step.
    PendingUpgrade public pendingUpgrade;

    /// @notice Pluggable committee-attestation verifier for the
    ///         random-committee lock path
    ///         ({lockPrivateCollateralWithCommittee}). Per
    ///         `memory/decision_privacy_roles_random_committee_2026-05-27.md`
    ///         the committee path replaces the static
    ///         `SETTLER_ROLE` allowlist with state-derived M-of-N
    ///         attestation. Zero address = committee path disabled;
    ///         legacy {lockPrivateCollateral} (SETTLER_ROLE-gated)
    ///         remains functional.
    IBridgeVerifier public attestationVerifier;

    /// @dev Storage gap for proxy-safe future-state additions.
    /// @dev Originally 40; shrunk to 38 to account for the H-05
    ///      back-port `pendingUpgrade` slot pair (struct = 2 slots:
    ///      address + uint256). Shrunk again to 37 for the
    ///      random-committee `attestationVerifier` slot.
    uint256[37] private __gap;

    // ========================================================================
    // EVENTS
    // ========================================================================

    /**
     * @notice Emitted on a successful collateral lock.
     * @param intentId Intent identifier.
     * @param trader Trader address.
     * @param tokenIn Input token contract.
     * @param tokenOut Output token contract.
     * @param nonce Trader nonce consumed by this lock.
     * @param tradingFeeBpsAtLock Live fee bps captured into the record.
     */
    event PrivateCollateralLocked(
        bytes32 indexed intentId,
        address indexed trader,
        address indexed tokenIn,
        address tokenOut,
        uint256 nonce,
        uint64 tradingFeeBpsAtLock
    );

    /**
     * @notice Emitted when a private intent is atomically settled.
     * @param intentId Intent identifier.
     * @param trader Trader address.
     * @param solver Solver address.
     * @param settlementHash Audit hash binding intent + parties + chainid.
     */
    event PrivateIntentSettled(
        bytes32 indexed intentId,
        address indexed trader,
        address indexed solver,
        bytes32 settlementHash
    );

    /**
     * @notice Emitted when both legs of a matched trade settle atomically via
     *         {settleBilateral}. Each leg additionally emits its own
     *         {PrivateIntentSettled}; this event is the canonical on-chain
     *         record that the two legs settled together in one transaction.
     * @dev Off-chain consumers: this asserts ONLY that the two intents settled
     *      in the SAME transaction — NOT that they are a verified counterparty
     *      pair. The contract never compares the two legs (each leg validates
     *      and settles independently against its own trader-signed lock), so a
     *      settler chooses which two intents to bundle. Treat the pairing as an
     *      attribution hint, not proof of an on-chain matched trade. No on-chain
     *      value depends on the pairing.
     * @param intentIdA First leg intent identifier.
     * @param intentIdB Second leg intent identifier.
     */
    event PrivateBilateralSettled(
        bytes32 indexed intentIdA,
        bytes32 indexed intentIdB
    );

    /**
     * @notice Emitted when a recipient claims their accumulated encrypted fees.
     * @dev UNUSED — fees are distributed directly via transferGT in _settleOne.
     */
    event FeesClaimed(
        address indexed recipient,
        uint256 indexed claimNonce,
        uint256 ciphertextHigh,
        uint256 ciphertextLow
    );

    /**
     * @notice Emitted when a trader cancels a locked-but-unsettled intent.
     * @param intentId Intent identifier.
     * @param trader Trader who cancelled.
     */
    event PrivateIntentCancelled(bytes32 indexed intentId, address indexed trader);

    /**
     * @notice Emitted when a trader invalidates a pending nonce (audit M-06).
     * @param trader Trader address.
     * @param invalidatedNonce Nonce that was bumped.
     */
    event NonceInvalidated(address indexed trader, uint256 indexed invalidatedNonce);

    /**
     * @notice Emitted when admin queues a fee-recipient update (timelock starts).
     * @param liquidityPool Pending LP-pool address.
     * @param feeVault Pending UnifiedFeeVault address.
     * @param effectiveAt Earliest block timestamp at which it can be applied.
     */
    event FeeRecipientsUpdateQueued(
        address indexed liquidityPool,
        address indexed feeVault,
        uint256 effectiveAt
    );

    /**
     * @notice Emitted when the queued fee-recipient update is applied.
     * @param liquidityPool New LP-pool address.
     * @param feeVault New UnifiedFeeVault address.
     */
    event FeeRecipientsUpdated(address indexed liquidityPool, address indexed feeVault);

    /**
     * @notice Emitted when admin queues a trading-fee update (timelock starts).
     * @param newFeeBps Pending fee in basis points.
     * @param effectiveAt Earliest block timestamp at which it can be applied.
     */
    event TradingFeeUpdateQueued(uint64 indexed newFeeBps, uint256 effectiveAt);

    /**
     * @notice Emitted when admin updates the trading fee.
     * @param oldFeeBps Previous fee in basis points.
     * @param newFeeBps New fee in basis points.
     */
    event TradingFeeUpdated(uint64 indexed oldFeeBps, uint64 indexed newFeeBps);

    /**
     * @notice Emitted when admin queues a trusted-forwarder update.
     * @param forwarder Pending forwarder address.
     * @param effectiveAt Earliest block timestamp at which it can be applied.
     */
    event TrustedForwarderUpdateQueued(address indexed forwarder, uint256 effectiveAt);

    /**
     * @notice Emitted when the queued trusted-forwarder update is applied.
     * @param oldForwarder Previous forwarder.
     * @param newForwarder New forwarder.
     */
    event TrustedForwarderUpdated(address indexed oldForwarder, address indexed newForwarder);

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
     * @notice Emitted when admin confirms ossification (irreversible).
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
     *         attestation verifier used by
     *         {lockPrivateCollateralWithCommittee}.
     * @param verifier New verifier; zero address disables the
     *         committee path (legacy {lockPrivateCollateral}
     *         remains functional).
     */
    event AttestationVerifierSet(IBridgeVerifier indexed verifier);

    /**
     * @notice Emitted when a private collateral lock settles via
     *         the committee attestation path. Companion to
     *         {PrivateCollateralLocked}; persists the attester list
     *         so off-chain slashing pipelines can recover it after
     *         the 256-block blockhash window expires.
     * @param intentId Intent identifier.
     * @param attesters Sorted, deduplicated list of validator
     *        attesters whose signatures satisfied the committee
     *        quorum.
     */
    event LockCommitteeAttested(
        bytes32 indexed intentId,
        address[] attesters
    );

    /**
     * @notice Emitted when a bilateral pair settles through the M-of-N
     *         committee-attested, user-broadcast path
     *         ({settleBilateralWithCommittee}).
     * @param intentIdA First leg intent identifier.
     * @param intentIdB Second leg intent identifier.
     * @param attesters The committee members whose signatures authorized the
     *        settle (length == recovered sig count, in [quorumM, committeeSize]).
     */
    event SettleCommitteeAttested(
        bytes32 indexed intentIdA,
        bytes32 indexed intentIdB,
        address[] attesters
    );

    // ========================================================================
    // CUSTOM ERRORS
    // ========================================================================

    error CollateralAlreadyLocked();
    error CollateralNotLocked();
    error AlreadySettled();
    error DeadlineExpired();
    error InvalidAddress();
    error InvalidNonce();
    error IntentCancelled();
    error NotTrader();
    error ContractIsOssified();
    error SameTokenSwap();
    error TooEarlyToCancel();
    /// @dev UNUSED — fees are distributed directly via transferGT in _settleOne.
    error NoFeesToClaim();
    error OssificationNotRequested();
    error OssificationAlreadyRequested();
    error OssificationDelayNotElapsed();
    error InvalidTraderSignature();
    error TradingFeeTooHigh();
    error TradingFeeMismatch();
    error UnsupportedChain(uint256 chainId);
    error TimelockDelayNotElapsed();
    error TimelockNotRequested();
    error TimelockAlreadyRequested();
    error UpgradeNotAuthorized();
    error CannotRenounceAdmin();
    error AttestationVerifierNotSet();
    error InvalidCommitteeAttestation();
    error SubjectInCommittee();
    /// @dev The two intents are not a settleable pair: tokens not reciprocal,
    ///      counterparties not reciprocal, a leg not LOCKED, or the encrypted
    ///      amounts fail the MPC equality check (A gives ≠ B expects).
    error IncompatibleMatch();
    error InvalidVerifier();
    error EmptySettlerSet();
    /// @notice A deprecated SETTLER_ROLE lock/settle path was called; the only
    ///         supported paths are the committee-attested ones
    ///         (`lockPrivateCollateralWithCommittee` /
    ///         `settleBilateralWithCommittee`), which move real principal
    ///         non-custodially with no trusted relayer key.
    error DeprecatedUseCommitteePath();

    // ========================================================================
    // CONSTRUCTOR & INITIALIZATION
    // ========================================================================

    /**
     * @notice Constructor that disables initializers on the implementation.
     * @dev Trusted forwarder is held in PROXY storage (audit H-06) — not
     *      pinned at construction. The implementation does not need it.
     * @custom:oz-upgrades-unsafe-allow constructor
     */
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the proxy state.
     * @dev Reverts on any chain other than COTI 2632500 / 7082400 — the
     *      MPC precompile does not exist elsewhere, and a deploy on the
     *      wrong chain would silently swallow encrypted operations.
     * @param admin Admin (DEFAULT_ADMIN_ROLE). Should be a multisig+timelock
     *              in production; deploy script revokes its SETTLER_ROLE
     *              once external settlers are wired.
     * @param settlers Initial SETTLER_ROLE holders (the matcher service
     *              addresses for each gateway validator). Audit M-02.
     * @param liquidityPool LP-pool address (70 % share).
     * @param feeVault UnifiedFeeVault address (30 % share).
     * @param trustedForwarder_ ERC-2771 forwarder address; pass `address(0)`
     *              to disable meta-tx until a COTI forwarder is deployed.
     */
    function initialize( // solhint-disable-line code-complexity
        address admin,
        address[] calldata settlers,
        address liquidityPool,
        address feeVault,
        address trustedForwarder_
    ) external initializer {
        if (
            block.chainid != COTI_MAINNET_CHAIN_ID
                && block.chainid != COTI_TESTNET_CHAIN_ID
        ) {
            revert UnsupportedChain(block.chainid);
        }
        if (admin == address(0)) revert InvalidAddress();
        if (liquidityPool == address(0)) revert InvalidAddress();
        if (feeVault == address(0)) revert InvalidAddress();
        if (settlers.length == 0) revert EmptySettlerSet();

        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        __EIP712_init("OmniBazaar PrivateDEXSettlement", "1");

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        for (uint256 i = 0; i < settlers.length; ++i) {
            address s = settlers[i];
            if (s == address(0)) revert InvalidAddress();
            _grantRole(SETTLER_ROLE, s);
        }

        feeRecipients = FeeRecipients({
            liquidityPool: liquidityPool,
            feeVault: feeVault
        });

        tradingFeeBps = 20; // 0.20 %
        trustedForwarder = trustedForwarder_;
    }

    /**
     * @notice Reinitializer (version 2) — bind embedded {CommitteeAttestor}
     *         parameters and seed the eligible-set snapshot atomically with
     *         the UUPS upgrade.
     * @dev See {PrivateYieldVault.initializeV2} for the canonical pattern;
     *      identical semantics here. Pioneer-Phase rule applies.
     * @param committeeSize_ N.
     * @param quorumM_ M; must satisfy `quorumM_ * 3 >= committeeSize_ * 2`.
     * @param bootstrapSet Initial eligible-set, sorted ascending.
     * @param l1Block L1 block at which `bootstrapSet` was computed (or 0).
     */
    function initializeV2(
        uint256 committeeSize_,
        uint256 quorumM_,
        address[] calldata bootstrapSet,
        uint256 l1Block
    ) external reinitializer(2) onlyRole(DEFAULT_ADMIN_ROLE) {
        // Audit Pass-3 H-1 — see PrivateYieldVault.initializeV2 for rationale.
        __CommitteeAttestor_init(committeeSize_, quorumM_);
        address[] memory seed = new address[](bootstrapSet.length);
        for (uint256 i = 0; i < bootstrapSet.length; ++i) {
            seed[i] = bootstrapSet[i];
        }
        _bootstrapSnapshot(seed, l1Block, 1);
    }

    /**
     * @notice Admin-gated update of committee (N, M) parameters.
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
    // EXTERNAL — SETTLEMENT
    // ========================================================================

    /**
     * @notice DEPRECATED — the trusted-relayer (`SETTLER_ROLE`) lock path.
     * @dev Superseded by {lockPrivateCollateralWithCommittee}, which is
     *      authorized by an M-of-N committee proof, broadcast by the trader
     *      (own key + gas), and now escrows the trader's collateral
     *      non-custodially. This path required a trusted SETTLER key and, since
     *      the itUint256 retrofit, could not be settled anyway (its stored
     *      client `ctUint256` is not `onBoard`-able). Retained only to preserve
     *      the ABI selector; it always reverts. Escrow/swap now moves real
     *      principal, so re-enabling a keyed lock would reintroduce a trust
     *      surface — the committee path is the only supported lock.
     */
    function lockPrivateCollateral(
        bytes32,
        address,
        address,
        address,
        address,
        ctUint256 calldata,
        ctUint256 calldata,
        uint64,
        uint256,
        uint256,
        bytes calldata
    ) external onlyRole(SETTLER_ROLE) {
        revert DeprecatedUseCommitteePath();
    }

    /**
     * @notice Lock encrypted collateral — committee attestation path.
     * @dev Replaces the static `SETTLER_ROLE` gate with a random
     *      M-of-N validator committee per
     *      `memory/decision_privacy_roles_random_committee_2026-05-27.md`.
     *      Both gates verify the same `LockIntent` EIP-712 digest:
     *      trader's signature + committee's ≥M signatures.
     *
     *      Caller authorisation: anyone may submit — the trader's
     *      EIP-712 signature + the committee's ≥M signatures carry
     *      every authorisation needed.
     *
     *      The trader (subject) MUST NOT appear in the committee
     *      attester list (Phase 2 audit Pass-1 C-2 fix).
     *
     *      Emits {LockCommitteeAttested} with the attester list.
     *      The follow-up `settlePrivateIntent` continues to require
     *      `SETTLER_ROLE` — its committee migration is tracked as
     *      residual Week 1.2 work (settler-side authorisation model
     *      requires distinct security analysis from this user-signed
     *      lock flow).
     * @param intentId Unique intent identifier.
     * @param trader Trader address.
     * @param solver Solver address (matched off-chain).
     * @param tokenIn Input token (`pXOM`/`pUSDC`/...).
     * @param tokenOut Output token.
     * @param encTraderAmount Encrypted trader collateral (ctUint256).
     * @param encSolverAmount Encrypted solver collateral (ctUint256).
     * @param expectedFeeBps Trader's expected `tradingFeeBps` at sign time.
     * @param traderNonce Expected trader nonce (replay protection).
     * @param deadline Settlement deadline (unix seconds).
     * @param traderSignature EIP-712 signature from the trader.
     * @param committeeProof Verifier-specific opaque blob containing
     *        the M-of-N committee signatures over the same
     *        `LockIntent` digest as {traderSignature}.
     */
    function lockPrivateCollateralWithCommittee( // solhint-disable-line code-complexity, function-max-lines
        bytes32 intentId,
        address trader,
        address solver,
        address tokenIn,
        address tokenOut,
        itUint256 calldata encTraderAmount,
        itUint256 calldata encSolverAmount,
        uint64 expectedFeeBps,
        uint256 traderNonce,
        uint256 deadline,
        bytes calldata traderSignature,
        bytes calldata committeeProof
    ) external whenNotPaused nonReentrant {
        if (msg.sender != trader) revert NotTrader();
        if (trader == address(0)) revert InvalidAddress();
        if (solver == address(0)) revert InvalidAddress();
        if (tokenIn == address(0)) revert InvalidAddress();
        if (tokenOut == address(0)) revert InvalidAddress();
        if (tokenIn == tokenOut) revert SameTokenSwap();
        // solhint-disable-next-line not-rely-on-time, gas-strict-inequalities
        if (deadline <= block.timestamp) revert DeadlineExpired();
        if (privateCollateral[intentId].status != SettlementStatus.EMPTY) {
            revert CollateralAlreadyLocked();
        }
        if (nonces[trader] != traderNonce) revert InvalidNonce();
        uint64 liveFeeBps = tradingFeeBps;
        if (expectedFeeBps != liveFeeBps) revert TradingFeeMismatch();

        bytes32 digest = _lockIntentDigest(
            intentId,
            trader,
            solver,
            tokenIn,
            tokenOut,
            encTraderAmount.ciphertext,
            encSolverAmount.ciphertext,
            expectedFeeBps,
            traderNonce,
            deadline
        );
        if (ECDSA.recover(digest, traderSignature) != trader) {
            revert InvalidTraderSignature();
        }

        (bool valid, address[] memory attesters) =
            _verifyCommittee(digest, committeeProof);
        if (!valid) revert InvalidCommitteeAttestation();

        uint256 attesterCount = attesters.length;
        if (attesterCount == 0) revert InvalidCommitteeAttestation();
        // Audit 2026-05-27 finding H-1: subject-not-in-committee must
        // exclude BOTH named parties (trader AND solver). A solver
        // seated on the committee for their own intent could
        // otherwise self-attest to a settlement that benefits them
        // (e.g., accepting a worse fee/price than the off-chain
        // matcher would have negotiated). The Phase 2 audit Pass-1
        // C-2 framing generalises to the full set of named on-chain
        // parties.
        for (uint256 i = 0; i < attesterCount; ) {
            address a = attesters[i];
            if (a == trader || a == solver) revert SubjectInCommittee();
            unchecked {
                ++i;
            }
        }

        unchecked {
            ++nonces[trader];
        }

        // Validate the user-supplied encrypted INPUTS (itUint256): each binds
        // its ciphertext to msg.sender (the trader, who broadcasts this lock) +
        // this contract + this function selector, and yields a network
        // gtUint256 handle. Persist the principals as NETWORK ctUint256
        // (offBoard of the validated handles) so settle can re-`onBoard` them.
        // The raw input ciphertext is user-key encrypted and is NOT onBoard-able
        // — `onBoard(ctUint256)` of a client input reverts in the MPC precompile
        // (the gap that left settle unexecutable; mirrors PrivateYieldVault).
        gtUint256 traderCollateralG =
            MpcCore.validateCiphertext(encTraderAmount);
        ctUint256 memory storedTraderCollateral =
            MpcCore.offBoard(traderCollateralG);
        ctUint256 memory storedSolverCollateral =
            MpcCore.offBoard(MpcCore.validateCiphertext(encSolverAmount));

        privateCollateral[intentId] = PrivateCollateral({
            trader: trader,
            solver: solver,
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            traderCollateral: storedTraderCollateral,
            solverCollateral: storedSolverCollateral,
            nonce: traderNonce,
            deadline: deadline,
            // solhint-disable-next-line not-rely-on-time
            lockTimestamp: block.timestamp,
            tradingFeeBpsAtLock: liveFeeBps,
            status: SettlementStatus.LOCKED
        });

        // Escrow the trader's input collateral into the contract. Non-custodial:
        // the funds are released only to the counterparty on a committee-
        // attested settle, or refunded to the trader on cancelPrivateIntent —
        // no party (including the platform) can redirect them. The trader is
        // msg.sender on this committee path and must have approveGT'd this
        // contract for `tokenIn`. Mirrors PrivateYieldVault.stake's escrow via
        // {IPrivateERC20-transferFromGT}; the GT transfer is callback-free
        // (no receiver hook) and runs after all state effects.
        IPrivateERC20(tokenIn).transferFromGT(
            trader,
            address(this),
            traderCollateralG
        );

        emit LockCommitteeAttested(intentId, attesters);
        emit PrivateCollateralLocked(
            intentId, trader, tokenIn, tokenOut, traderNonce, liveFeeBps
        );
    }

    /**
     * @notice DEPRECATED — the single-leg trusted-relayer (`SETTLER_ROLE`)
     *         settle path.
     * @dev Disabled because, now that lock escrows real principal, a single-leg
     *      settle would move the trader's escrowed funds to `solver` with no
     *      reciprocal on-chain leg — a one-directional send, not an atomic
     *      swap, and a loss risk. Only {settleBilateralWithCommittee} (both legs
     *      escrowed, reciprocity + MPC amount-equality enforced, committee-
     *      attested, taker-broadcast) may move principal. Always reverts.
     */
    function settlePrivateIntent(
        bytes32,
        address,
        address
    ) external onlyRole(SETTLER_ROLE) {
        revert DeprecatedUseCommitteePath();
    }

    /**
     * @notice DEPRECATED — the trusted-relayer (`SETTLER_ROLE`) bilateral
     *         settle path.
     * @dev Superseded by {settleBilateralWithCommittee} (committee-attested,
     *      taker-broadcast, no SETTLER key). Now that settle moves real
     *      principal, retaining a keyed settle would reintroduce a trust
     *      surface, so this path is disabled and always reverts.
     */
    function settleBilateral(
        bytes32,
        address,
        bytes32,
        address,
        address
    ) external onlyRole(SETTLER_ROLE) {
        revert DeprecatedUseCommitteePath();
    }

    /**
     * @notice Atomically settle a matched pair, authorized by an M-of-N
     *         committee proof and broadcast by any caller (the taker, who pays
     *         COTI gas) — the trustless, user-paid settlement path.
     * @dev Replaces the trusted-relayer {settleBilateral} (SETTLER_ROLE-gated,
     *      backend-paid) with the same trust model as
     *      {lockPrivateCollateralWithCommittee}: a random M-of-N committee
     *      (derived from the eligible-set snapshot) signs the
     *      `(intentIdA, intentIdB)` SettleIntent digest. There is no
     *      `SETTLER_ROLE` gate, so the matcher needs no on-chain key and
     *      sponsors no gas; the caller (taker) broadcasts and pays.
     *
     *      Trust split — the committee can attest only what it can verify
     *      WITHOUT decrypting (which would break privacy), so each assertion
     *      is enforced where it can be made soundly:
     *        - Token + counterparty reciprocity: enforced ON-CHAIN here against
     *          the stored, EIP-712-bound lock records.
     *        - Both legs LOCKED: enforced ON-CHAIN here (and re-checked in
     *          {_settleOne}).
     *        - Amount compatibility (A gives exactly what B expects, and
     *          vice-versa): enforced ON-CHAIN via MPC equality of the two
     *          independently-encrypted ciphertexts; `decrypt` reveals ONLY the
     *          single compatible/not boolean, never the amounts.
     *        - WHICH two locked intents settle together (off-chain matching /
     *          liveness): attested by the committee.
     *      Because amounts/tokens/fee are fixed by each trader's lock signature
     *      and compatibility is cryptographically enforced, a malicious caller
     *      cannot mis-settle; the worst case is a failed (reverting) attempt.
     *
     *      Same atomicity guarantee as {settleBilateral}: both legs reach
     *      {SettlementStatus.SETTLED} or the whole tx reverts. Not
     *      `SETTLER_ROLE`-gated; `whenNotPaused` + `nonReentrant`.
     * @param intentIdA First leg intent identifier.
     * @param intentIdB Second leg intent identifier.
     * @param committeeProof `commitBlock(32) || sig0(65) || …` over the
     *        SettleIntent digest; M-of-N signers from the current committee.
     */
    function settleBilateralWithCommittee( // solhint-disable-line code-complexity
        bytes32 intentIdA,
        bytes32 intentIdB,
        bytes calldata committeeProof
    ) external whenNotPaused nonReentrant {
        PrivateCollateral storage a = privateCollateral[intentIdA];
        PrivateCollateral storage b = privateCollateral[intentIdB];

        // Both legs must be LOCKED. (Detailed status/deadline checks re-run in
        // _settleOne; this early guard lets us read the records safely below.)
        if (
            a.status != SettlementStatus.LOCKED ||
            b.status != SettlementStatus.LOCKED
        ) {
            revert IncompatibleMatch();
        }

        // Structural reciprocity — each leg sells what the other buys and names
        // the other as counterparty. Bound into each trader's lock signature,
        // so it cannot have been forged. (Also rejects intentIdA == intentIdB,
        // since a real lock has tokenIn != tokenOut.)
        if (
            a.tokenIn != b.tokenOut ||
            a.tokenOut != b.tokenIn ||
            a.solver != b.trader ||
            b.solver != a.trader
        ) {
            revert IncompatibleMatch();
        }

        // Committee attestation over the pairing.
        bytes32 digest = _settleDigest(intentIdA, intentIdB);
        (bool valid, address[] memory attesters) =
            _verifyCommittee(digest, committeeProof);
        if (!valid || attesters.length == 0) {
            revert InvalidCommitteeAttestation();
        }
        // No named party may sit on its own settlement committee (audit H-1
        // analogue). a.solver == b.trader and b.solver == a.trader, so the two
        // distinct parties are exactly {a.trader, a.solver}.
        uint256 attesterCount = attesters.length;
        for (uint256 i = 0; i < attesterCount; ) {
            address att = attesters[i];
            if (att == a.trader || att == a.solver) revert SubjectInCommittee();
            unchecked {
                ++i;
            }
        }

        // Amount compatibility, enforced cryptographically. The two ciphertexts
        // are independent per-trader encryptions of the same value, so they
        // cannot be byte-compared — only an MPC equality reveals it. `decrypt`
        // surfaces ONLY the single boolean, never the amounts.
        gtBool givesMatch = MpcCore.eq(
            MpcCore.onBoard(a.traderCollateral),
            MpcCore.onBoard(b.solverCollateral)
        );
        gtBool wantsMatch = MpcCore.eq(
            MpcCore.onBoard(a.solverCollateral),
            MpcCore.onBoard(b.traderCollateral)
        );
        if (!MpcCore.decrypt(MpcCore.and(givesMatch, wantsMatch))) {
            revert IncompatibleMatch();
        }

        // Settle both legs atomically. A committee member (guaranteed in the
        // eligible-set snapshot) is the attributed `validator`; the stored
        // `solver` is passed through (re-checked against the record in
        // {_settleOne}).
        address validator = attesters[0];
        _settleOne(intentIdA, a.solver, validator);
        _settleOne(intentIdB, b.solver, validator);

        emit SettleCommitteeAttested(intentIdA, intentIdB, attesters);
        emit PrivateBilateralSettled(intentIdA, intentIdB);
    }

    /**
     * @notice Cancel a locked intent before settlement.
     * @dev Only callable by the original trader, only after
     *      {MIN_LOCK_DURATION} has elapsed. NOT gated by `whenNotPaused`
     *      — pause must not trap user-only escape paths (audit M-01).
     * @param intentId Intent identifier.
     */
    function cancelPrivateIntent(bytes32 intentId)
        external
        nonReentrant
    {
        PrivateCollateral storage entry = privateCollateral[intentId];
        if (entry.status == SettlementStatus.EMPTY) revert CollateralNotLocked();
        if (entry.status == SettlementStatus.SETTLED) revert AlreadySettled();
        if (entry.status == SettlementStatus.CANCELLED) revert IntentCancelled();
        if (msg.sender != entry.trader) revert NotTrader();
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp < entry.lockTimestamp + MIN_LOCK_DURATION) {
            revert TooEarlyToCancel();
        }

        entry.status = SettlementStatus.CANCELLED;

        // Refund the escrowed input collateral to the trader — the unilateral
        // liveness guarantee: if no settle lands, the trader reclaims their own
        // funds after MIN_LOCK_DURATION, and no other party can block it (this
        // path is deliberately not `whenNotPaused`-gated, audit M-01). Balances
        // the transferFromGT pull in lockPrivateCollateralWithCommittee.
        // Callback-free GT transfer, after the state effect (status flipped to
        // CANCELLED above, so a re-entrant call would hit the IntentCancelled
        // guard).
        IPrivateERC20(entry.tokenIn).transferGT(
            entry.trader,
            MpcCore.onBoard(entry.traderCollateral)
        );

        emit PrivateIntentCancelled(intentId, entry.trader);
    }

    /**
     * @notice Invalidate the trader's pending nonce.
     * @dev Lets a trader shred a stale signed `LockIntent` before a matcher
     *      can replay it (audit M-06). Standard 0x v4 / CoW Protocol pattern.
     *      Caller must pass their current nonce so a stale invalidate call
     *      does not skip ahead unnecessarily.
     *      NOT gated by `whenNotPaused` (audit M-01).
     * @param nonce Current nonce expected by the trader (must equal `nonces[trader]`).
     */
    function invalidateNonce(uint256 nonce) external {
        address trader = msg.sender;
        if (nonces[trader] != nonce) revert InvalidNonce();
        unchecked {
            ++nonces[trader];
        }
        emit NonceInvalidated(trader, nonce);
    }

    /**
     * @notice Claim accumulated encrypted fees.
     * @dev UNUSED — fees are distributed directly via transferGT in _settleOne.
     *      Retained as a no-op revert to preserve the ABI selector for any
     *      off-chain caller that may reference it.
     */
    function claimFees() external nonReentrant {
        revert NoFeesToClaim();
    }

    // ========================================================================
    // EXTERNAL — ATTESTATION VERIFIER WIRING (PIONEER PHASE)
    // ========================================================================

    /**
     * @notice Point the random-committee attestation verifier used by
     *         {lockPrivateCollateralWithCommittee}.
     * @dev Pioneer Phase admin model (per
     *      `memory/feedback_no_builtin_timelocks.md`): deployer-direct,
     *      zero delay. Once Pioneer ends, `DEFAULT_ADMIN_ROLE`
     *      transitions to `OmniTimelockController` + governance.
     *
     *      Setting `address(0)` is rejected.
     * @param newVerifier `IBridgeVerifier` implementation (typically
     *        a `RandomCommitteeVerifier` proxy).
     */
    function setAttestationVerifier(IBridgeVerifier newVerifier)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (address(newVerifier) == address(0)) revert InvalidAddress();
        // Defense-in-depth (audit 2026-05-27 M-02): probe the new
        // verifier implements `IBridgeVerifier` before adopting it.
        // `quorumThreshold()` is a cheap stateless view every
        // implementation provides; a contract without it (or a
        // non-contract address) reverts and the swap is rejected
        // up-front. Catches deployer typos before they brick the
        // committee path. Does NOT defend against an adversarial
        // deployer (Pioneer-Phase accepted).
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
     * @notice Queue a fee-recipient update; effective after {TIMELOCK_DELAY}
     *         (audit H-03).
     * @param liquidityPool New LP-pool address (70 % share).
     * @param feeVault      New UnifiedFeeVault address (30 % share).
     */
    function requestFeeRecipientUpdate(address liquidityPool, address feeVault)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (liquidityPool == address(0)) revert InvalidAddress();
        if (feeVault == address(0)) revert InvalidAddress();
        if (pendingFeeRecipients.effectiveAt != 0) revert TimelockAlreadyRequested();
        // solhint-disable-next-line not-rely-on-time
        uint256 effectiveAt = block.timestamp + TIMELOCK_DELAY;
        pendingFeeRecipients = PendingFeeRecipients({
            liquidityPool: liquidityPool,
            feeVault: feeVault,
            effectiveAt: effectiveAt
        });
        emit FeeRecipientsUpdateQueued(liquidityPool, feeVault, effectiveAt);
    }

    /**
     * @notice Apply the queued fee-recipient update.
     * @dev Anyone can call once the delay has elapsed (no admin gate needed
     *      to reduce ops friction; admin gate is on the queue side).
     */
    function confirmFeeRecipientUpdate() external {
        PendingFeeRecipients memory pending = pendingFeeRecipients;
        if (pending.effectiveAt == 0) revert TimelockNotRequested();
        // solhint-disable-next-line not-rely-on-time, gas-strict-inequalities
        if (block.timestamp < pending.effectiveAt) revert TimelockDelayNotElapsed();
        feeRecipients = FeeRecipients({
            liquidityPool: pending.liquidityPool,
            feeVault: pending.feeVault
        });
        delete pendingFeeRecipients;
        emit FeeRecipientsUpdated(pending.liquidityPool, pending.feeVault);
    }

    /**
     * @notice Cancel the queued fee-recipient update.
     */
    function cancelPendingFeeRecipientUpdate() external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (pendingFeeRecipients.effectiveAt == 0) revert TimelockNotRequested();
        delete pendingFeeRecipients;
        emit PendingUpdateCancelled("feeRecipients");
    }

    /**
     * @notice Queue a trading-fee update; effective after {TIMELOCK_DELAY}
     *         (audit H-02).
     * @param newFeeBps New fee in basis points (max {MAX_TRADING_FEE_BPS}).
     */
    function requestTradingFeeUpdate(uint64 newFeeBps)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (newFeeBps > MAX_TRADING_FEE_BPS) revert TradingFeeTooHigh();
        if (pendingTradingFee.effectiveAt != 0) revert TimelockAlreadyRequested();
        // solhint-disable-next-line not-rely-on-time
        uint256 effectiveAt = block.timestamp + TIMELOCK_DELAY;
        pendingTradingFee = PendingTradingFee({
            newFeeBps: newFeeBps,
            effectiveAt: effectiveAt
        });
        emit TradingFeeUpdateQueued(newFeeBps, effectiveAt);
    }

    /**
     * @notice Apply the queued trading-fee update.
     */
    function confirmTradingFeeUpdate() external {
        PendingTradingFee memory pending = pendingTradingFee;
        if (pending.effectiveAt == 0) revert TimelockNotRequested();
        // solhint-disable-next-line not-rely-on-time, gas-strict-inequalities
        if (block.timestamp < pending.effectiveAt) revert TimelockDelayNotElapsed();
        uint64 oldFee = tradingFeeBps;
        tradingFeeBps = pending.newFeeBps;
        delete pendingTradingFee;
        emit TradingFeeUpdated(oldFee, pending.newFeeBps);
    }

    /**
     * @notice Cancel the queued trading-fee update.
     */
    function cancelPendingTradingFeeUpdate() external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (pendingTradingFee.effectiveAt == 0) revert TimelockNotRequested();
        delete pendingTradingFee;
        emit PendingUpdateCancelled("tradingFee");
    }

    /**
     * @notice Queue a trusted-forwarder update; effective after {TIMELOCK_DELAY}.
     * @dev Forwarder is held in proxy storage rather than implementation
     *      immutable so a malicious upgrade cannot swap it (audit H-06).
     * @param newForwarder New ERC-2771 trusted forwarder; `address(0)`
     *        disables meta-tx.
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
     * @notice Apply the queued trusted-forwarder update.
     */
    function confirmTrustedForwarderUpdate() external {
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
     * @notice Cancel the queued trusted-forwarder update.
     */
    function cancelPendingTrustedForwarderUpdate() external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (pendingForwarder.effectiveAt == 0) revert TimelockNotRequested();
        delete pendingForwarder;
        emit PendingUpdateCancelled("trustedForwarder");
    }

    // ========================================================================
    // EXTERNAL — ADMIN (PAUSE + OSSIFICATION)
    // ========================================================================

    /// @notice Pause settlements (admin emergency control).
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /// @notice Resume settlements.
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /**
     * @notice Begin the 7-day ossification window.
     * @dev Reverts if a request is already in flight (audit M-03 — no
     *      silent timer reset). Use {cancelOssificationRequest} to cancel
     *      explicitly.
     */
    function requestOssification() external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_ossified) revert ContractIsOssified();
        if (ossificationRequestTime != 0) revert OssificationAlreadyRequested();
        // solhint-disable-next-line not-rely-on-time
        ossificationRequestTime = block.timestamp;
        // solhint-disable-next-line not-rely-on-time
        emit OssificationRequested(address(this), block.timestamp);
    }

    /// @notice Cancel a pending ossification request (audit M-03).
    function cancelOssificationRequest() external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_ossified) revert ContractIsOssified();
        if (ossificationRequestTime == 0) revert OssificationNotRequested();
        ossificationRequestTime = 0;
        emit OssificationRequestCancelled(address(this));
    }

    /// @notice Confirm ossification — permanent, irreversible.
    function confirmOssification() external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_ossified) revert ContractIsOssified();
        if (ossificationRequestTime == 0) revert OssificationNotRequested();
        // solhint-disable-next-line not-rely-on-time
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
     * @notice Trader's next-expected nonce. Used by matchers building intents.
     * @param trader Address whose nonce to look up.
     * @return Next nonce expected for `trader`'s next lock.
     */
    function getNonce(address trader) external view returns (uint256) {
        return nonces[trader];
    }

    /**
     * @notice EIP-712 domain separator, useful for off-chain intent signing.
     * @return The current domain separator.
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
    // EXTERNAL — ROLE OVERRIDES (audit M-04)
    // ========================================================================

    /**
     * @notice Disallow renouncing `DEFAULT_ADMIN_ROLE` to prevent bricking.
     * @dev OpenZeppelin v5 base allows any holder to renounce; if the last
     *      admin renounces pre-ossification, the contract becomes
     *      un-pausable, un-upgradeable, and fee-recipient-frozen forever.
     *      Other roles renounce normally.
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
    // INTERNAL
    // ========================================================================

    /**
     * @notice Internal per-leg settlement core shared by {settlePrivateIntent}
     *         and {settleBilateral}.
     * @dev Carries all per-leg validation and encrypted fee accounting. Holds
     *      NO reentrancy guard of its own — both callers are `nonReentrant`, so
     *      {settleBilateral} can invoke it twice within a single guarded call.
     * @param intentId Intent identifier.
     * @param solver   Counterparty/solver bound to the lock.
     * @param validator Eligible-set validator attributed to the settlement.
     */
    function _settleOne( // solhint-disable-line code-complexity
        bytes32 intentId,
        address solver,
        address validator
    ) internal {
        PrivateCollateral storage entry = privateCollateral[intentId];
        if (entry.status == SettlementStatus.EMPTY) revert CollateralNotLocked();
        if (entry.status == SettlementStatus.SETTLED) revert AlreadySettled();
        if (entry.status == SettlementStatus.CANCELLED) revert IntentCancelled();
        // solhint-disable-next-line not-rely-on-time, gas-strict-inequalities
        if (entry.deadline <= block.timestamp) revert DeadlineExpired();
        if (solver == address(0)) revert InvalidAddress();
        if (validator == address(0)) revert InvalidAddress();
        if (entry.solver != solver) revert InvalidAddress();
        // Audit Pass-3 H-02 — the `validator` argument is recorded in
        // the settlement hash for off-chain attribution. Constraining
        // it to the CURRENT eligible-set means a misbehaving SETTLER
        // cannot stamp settlements with arbitrary or already-slashed
        // validator addresses. CommitteeAttestor.isInSnapshot is the
        // canonical membership probe — same source-of-truth as the
        // _verifyCommittee path uses for committee selection.
        if (!isInSnapshot(validator)) revert InvalidAddress();

        entry.status = SettlementStatus.SETTLED;

        uint64 feeBps = entry.tradingFeeBpsAtLock;

        // Encrypted fee math — single `checkedMul`-chain ending in one div
        // for LP, one for total. `feeBps` is captured at lock time.
        gtUint256 traderG = MpcCore.onBoard(entry.traderCollateral);
        gtUint256 totalFeeG = MpcCore.div(
            MpcCore.checkedMul(traderG, MpcCore.setPublic256(uint256(feeBps))),
            MpcCore.setPublic256(BASIS_POINTS_DIVISOR)
        );
        gtUint256 lpFeeG = MpcCore.div(
            MpcCore.checkedMul(totalFeeG, MpcCore.setPublic256(LP_SHARE_BPS)),
            MpcCore.setPublic256(BASIS_POINTS_DIVISOR)
        );
        gtUint256 vaultFeeG = MpcCore.checkedSub(totalFeeG, lpFeeG);

        // Move the escrowed principal — the actual private asset swap.
        // `entry.traderCollateral` of `entry.tokenIn` was pulled into the
        // contract at lock; here it is paid out in full. The counterparty (the
        // reciprocal leg's trader, bound as `solver` in this leg's trader-signed
        // lock and re-checked above) receives the net; the two fee recipients
        // receive the LP/vault split. The three amounts sum EXACTLY to the
        // escrowed collateral (net = collateral − totalFee; totalFee = lpFee +
        // vaultFee), so no dust is stranded in the contract. Callback-free GT
        // transfers, after all state effects (status already flipped above).
        gtUint256 netG = MpcCore.checkedSub(traderG, totalFeeG);
        IPrivateERC20 token = IPrivateERC20(entry.tokenIn);
        token.transferGT(solver, netG);
        token.transferGT(feeRecipients.liquidityPool, lpFeeG);
        token.transferGT(feeRecipients.feeVault, vaultFeeG);

        unchecked {
            ++totalSettlements;
        }

        bytes32 settlementHash = keccak256(
            abi.encode(
                intentId,
                entry.trader,
                solver,
                validator,
                entry.tokenIn,
                entry.tokenOut,
                // solhint-disable-next-line not-rely-on-time
                block.timestamp,
                block.chainid
            )
        );
        emit PrivateIntentSettled(intentId, entry.trader, solver, settlementHash);
    }

    /**
     * @dev UUPS authorization — denies upgrades once ossified, and
     *      enforces the 48 h two-step timelock from {requestUpgrade}
     *      (audit H-05 back-port). The caller must (a) hold
     *      DEFAULT_ADMIN_ROLE, (b) have queued THIS exact
     *      `newImplementation` via `requestUpgrade`, and (c) wait until
     *      `effectiveAt`. The pending entry is cleared on success so
     *      it cannot be replayed.
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

    // ─── ERC-2771 (proxy-storage forwarder) ───────────────────────────────

    /**
     * @notice ERC-2771 sender resolution. Returns the trader address from
     *         calldata if the forwarder relayed; otherwise `msg.sender`.
     * @return sender Resolved sender address (forwarder-aware).
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
            // Last 20 bytes of calldata = the forwarded sender.
            assembly {
                sender := shr(96, calldataload(sub(calldatasize(), 20)))
            }
        } else {
            sender = msg.sender;
        }
    }

    /**
     * @notice ERC-2771 calldata resolution. Strips the 20-byte forwarder
     *         suffix when applicable.
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
     * @notice ERC-2771 calldata suffix length.
     * @return 20 when the forwarder relayed, 0 otherwise.
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
     * @notice Compute the EIP-712 digest of a `LockIntent` payload.
     * @dev Extracted so {lockPrivateCollateralWithCommittee} can
     *      verify the committee signed over the SAME digest the
     *      trader did, without re-computing inside the verifier.
     * @param intentId Unique intent identifier.
     * @param trader Trader address.
     * @param solver Solver address.
     * @param tokenIn Input token.
     * @param tokenOut Output token.
     * @param encTraderAmount Encrypted trader collateral.
     * @param encSolverAmount Encrypted solver collateral.
     * @param expectedFeeBps Trader's expected `tradingFeeBps` at sign time.
     * @param traderNonce Expected trader nonce.
     * @param deadline Settlement deadline.
     * @return The EIP-712 digest.
     */
    function _lockIntentDigest(
        bytes32 intentId,
        address trader,
        address solver,
        address tokenIn,
        address tokenOut,
        ctUint256 calldata encTraderAmount,
        ctUint256 calldata encSolverAmount,
        uint64 expectedFeeBps,
        uint256 traderNonce,
        uint256 deadline
    ) private view returns (bytes32) {
        bytes32 traderCommit = _commit(encTraderAmount);
        bytes32 solverCommit = _commit(encSolverAmount);
        bytes32 structHash = keccak256(
            abi.encode(
                LOCK_INTENT_TYPEHASH,
                intentId,
                trader,
                solver,
                tokenIn,
                tokenOut,
                traderCommit,
                solverCommit,
                expectedFeeBps,
                traderNonce,
                deadline
            )
        );
        return _hashTypedDataV4(structHash);
    }

    /**
     * @notice EIP-712 digest the committee signs to authorize settling the
     *         pair `(intentIdA, intentIdB)` in {settleBilateralWithCommittee}.
     * @dev Domain-bound to this contract + chain, so a proof cannot be replayed
     *      on another deployment. The intent ids are unique per active lock,
     *      and a settled intent stays SETTLED, so the pairing is non-replayable.
     * @param intentIdA First leg intent identifier.
     * @param intentIdB Second leg intent identifier.
     * @return The typed-data digest the M-of-N committee signs.
     */
    function _settleDigest(bytes32 intentIdA, bytes32 intentIdB)
        private
        view
        returns (bytes32)
    {
        return _hashTypedDataV4(
            keccak256(abi.encode(SETTLE_INTENT_TYPEHASH, intentIdA, intentIdB))
        );
    }

    /**
     * @dev Hash an encrypted-amount ciphertext into a 32-byte commitment for
     *      EIP-712 binding. The high/low halves uniquely identify the
     *      ctUint256 value the trader signed over.
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
