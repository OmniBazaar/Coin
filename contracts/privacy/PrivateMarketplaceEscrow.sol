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
 * @title PrivateMarketplaceEscrow
 * @author OmniBazaar Development Team
 * @notice Privacy-preserving marketplace escrow on COTI Helium 256-bit MPC.
 * @dev Phase 5.1 of FIX_PRIVACY:
 *      - Native `ctUint256` price commitment — no `1e12` scaling.
 *      - COTI-only: deploys revert on every chain except 2632500 / 7082400.
 *      - Atomic flow: `create → release | refund | dispute → arbitrate`.
 *      - EIP-712 typed-data buyer signature binds the encrypted-price
 *        commitment + seller + listing ref + deadline.
 *      - 0.25 % escrow fee on release, off-boarded to a configurable
 *        UnifiedFeeVault recipient (vault routes ODDAO / Staking /
 *        Treasury internally).
 *      - 5 % arbitration fee on dispute resolution (split 50/50 buyer/
 *        seller — same as MinimalEscrow), accrued to the vault.
 *      - 48-hour timelock on every privileged setter (fee bps, fee
 *        recipient, arbitrator, trusted forwarder).
 *      - UUPS upgradeable with 7-day two-step ossification (re-request
 *        guarded; explicit cancel exists).
 *      - `renounceRole(DEFAULT_ADMIN_ROLE, ...)` is overridden to revert
 *        — prevents accidentally bricking the contract.
 *      - ERC-2771 forwarder address held in PROXY storage so a malicious
 *        upgrade cannot swap it (audit pattern H-06).
 */
contract PrivateMarketplaceEscrow is
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

    /// @notice Escrow lifecycle status.
    enum EscrowStatus {
        EMPTY,
        ACTIVE,
        DISPUTED,
        RELEASED,
        REFUNDED,
        ARBITRATED_TO_SELLER,
        ARBITRATED_TO_BUYER
    }

    /**
     * @notice One escrow record. The encrypted price ciphertext is stored
     *         alongside public counterparty metadata so the off-chain
     *         indexer can surface the listing without ever decrypting.
     */
    // solhint-disable-next-line gas-struct-packing
    struct PrivateEscrow {
        address buyer;
        address seller;
        address arbitrator;
        bytes32 listingRef;
        ctUint256 encPrice;
        uint256 createdAt;
        uint256 deadline;
        uint256 disputeRaisedAt;
        uint64 escrowFeeBpsAtCreate;
        EscrowStatus status;
    }

    /**
     * @notice Pending timelocked update for the escrow fee.
     * @dev Zero `effectiveAt` = no pending update.
     */
    struct PendingFee {
        uint64 newFeeBps;
        uint256 effectiveAt;
    }

    /**
     * @notice Pending timelocked update for the fee-vault recipient.
     * @dev Zero `effectiveAt` = no pending update.
     */
    struct PendingFeeVault {
        address feeVault;
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

    /// @notice Role for the relayer/matcher service that creates escrows on
    ///         behalf of signed-intent buyers (validator gateway).
    bytes32 public constant RELAYER_ROLE = keccak256("RELAYER_ROLE");

    /// @notice Role for arbitrators allowed to call {arbitrate}.
    bytes32 public constant ARBITRATOR_ROLE = keccak256("ARBITRATOR_ROLE");

    /// @notice Basis-points divisor (100 %).
    uint256 public constant BASIS_POINTS_DIVISOR = 10_000;

    /// @notice Maximum escrow fee (5 %, mirrors `MinimalEscrow`).
    uint64 public constant MAX_ESCROW_FEE_BPS = 500;

    /// @notice Default escrow fee (0.25 %, per CLAUDE.md tokenomics).
    uint64 public constant DEFAULT_ESCROW_FEE_BPS = 25;

    /// @notice Arbitration fee in basis points (2.5 %; per CLAUDE.md the
    ///         total cost of arbitration is 5 % split 50/50 buyer/seller —
    ///         in v1 we lack a bond mechanism so the loser cannot post
    ///         their share, and the contract collects only the winner's
    ///         half from the principal payout. The remaining 2.5 % is a
    ///         documented v1 shortfall pending the v2 bond mechanism
    ///         (audit H-01 + I-01). See `arbitrate`.
    uint64 public constant ARBITRATION_FEE_BPS = 250;

    /// @notice Minimum seconds before a dispute can be raised after create
    ///         (24 hours, matching `MinimalEscrow` for parity — audit M-01).
    uint256 public constant MIN_DISPUTE_DELAY = 24 hours;

    /// @notice After this many seconds in DISPUTED status without resolution,
    ///         the buyer can call {expireDispute} to refund themselves
    ///         unilaterally. Mirrors `MinimalEscrow.DISPUTE_TIMEOUT`.
    ///         (Audit H-02.)
    uint256 public constant DISPUTE_TIMEOUT = 30 days;

    /// @notice 7-day ossification delay.
    uint256 public constant OSSIFICATION_DELAY = 7 days;

    /// @notice Required delay for privileged setter timelocks (48 h).
    /// @notice Set to `0` per Pioneer-Phase rule — see PrivateYieldVault
    ///         constant for full rationale.
    uint256 public constant TIMELOCK_DELAY = 0;

    /// @notice COTI mainnet chain id.
    uint256 private constant COTI_MAINNET_CHAIN_ID = 2_632_500;

    /// @notice COTI testnet chain id.
    uint256 private constant COTI_TESTNET_CHAIN_ID = 7_082_400;

    /// @notice EIP-712 typehash for the buyer's create-escrow intent.
    /// @dev String length is fixed by the EIP-712 spec.
    // solhint-disable-next-line gas-small-strings, max-line-length
    bytes32 private constant CREATE_ESCROW_TYPEHASH = keccak256("CreateEscrowIntent(bytes32 escrowId,address buyer,address seller,address arbitrator,bytes32 listingRef,bytes32 priceCommit,uint64 escrowFeeBps,uint256 deadline)");

    /// @notice EIP-712 typehash for the committee's dispute-resolution
    ///         outcome attestation. The random M-of-N validator committee
    ///         signs this digest to attest which party won a disputed
    ///         escrow, authorizing {resolveDisputeWithCommittee} without any
    ///         single `ARBITRATOR_ROLE` (deployer-key) signature.
    /// @dev String length is fixed by the EIP-712 spec.
    // solhint-disable-next-line gas-small-strings, max-line-length
    bytes32 private constant RESOLVE_DISPUTE_TYPEHASH = keccak256("ResolveDisputeOutcome(bytes32 escrowId,address winner)");

    // ========================================================================
    // STATE VARIABLES
    // ========================================================================

    /// @notice escrowId → escrow record.
    mapping(bytes32 escrowId => PrivateEscrow entry) public escrows;

    /// @notice DEPRECATED by the settlement-direct migration (initializeV3).
    /// @dev The escrow now holds real pXOM custody and pays recipients
    ///      directly via {IPrivateERC20-transferGT}, so no encrypted
    ///      per-recipient accumulator is used. These slots are retained ONLY
    ///      to preserve the proxy storage layout; the live code never reads or
    ///      writes them. Any pre-migration entries were unbacked accounting
    ///      (no token custody existed before this upgrade) and are
    ///      intentionally orphaned.
    mapping(address recipient => ctUint256 balance) private accumulatedBalances;

    /// @notice DEPRECATED — layout-reserved only. See {accumulatedBalances}.
    mapping(address recipient => bool flagged) private _hasUnclaimed;

    /// @notice DEPRECATED — layout-reserved only. See {accumulatedBalances}.
    mapping(address recipient => uint256 claimNonce) public claimNonces;

    /// @notice Active escrow fee in basis points.
    uint64 public escrowFeeBps;

    /// @notice Active UnifiedFeeVault recipient on COTI.
    address public feeVault;

    /// @notice ERC-2771 trusted forwarder (proxy storage — audit H-06).
    address public trustedForwarder;

    /// @notice Total lifetime escrows created.
    uint256 public totalEscrows;

    /// @notice True once the contract is permanently non-upgradable.
    bool private _ossified;

    /// @notice Block timestamp when ossification was requested (0 = none).
    uint256 public ossificationRequestTime;

    /// @notice Pending fee update (timelocked).
    PendingFee public pendingFee;

    /// @notice Pending fee-vault update (timelocked).
    PendingFeeVault public pendingFeeVault;

    /// @notice Pending forwarder update (timelocked).
    PendingForwarder public pendingForwarder;

    /// @notice Pending UUPS implementation upgrade (timelocked, audit H-05
    /// back-port). The first upgrade FROM the pre-back-port impl bypasses
    /// this gate (the OLD impl had no `pendingUpgrade` requirement); every
    /// subsequent upgrade enforces the 48 h two-step.
    PendingUpgrade public pendingUpgrade;

    /// @notice Pluggable committee-attestation verifier for the
    ///         random-committee escrow-creation path
    ///         ({createEscrowWithCommittee}). Per
    ///         `memory/decision_privacy_roles_random_committee_2026-05-27.md`
    ///         the committee path replaces the static
    ///         `RELAYER_ROLE` allowlist. Zero address = committee
    ///         path disabled; legacy {createEscrow}
    ///         (`RELAYER_ROLE`-gated) remains functional.
    IBridgeVerifier public attestationVerifier;

    /// @notice COTI pXOM token ({PrivateOmniCoin}) whose encrypted balance
    ///         backs every escrow. Set once via {initializeV3}. From that
    ///         upgrade on, {createEscrow} pulls the buyer's committed price
    ///         into custody and release/refund/arbitrate pay out of it.
    IPrivateERC20 public privateToken;

    /// @dev Storage gap for proxy-safe future-state additions.
    /// @dev Originally 40; shrunk to 38 to account for the H-05
    ///      back-port `pendingUpgrade` slot pair (struct = 2 slots:
    ///      address + uint256). Shrunk again to 37 for the
    ///      random-committee `attestationVerifier` slot. Shrunk to 36 for the
    ///      settlement-direct `privateToken` slot (initializeV3).
    uint256[36] private __gap;

    // ========================================================================
    // EVENTS
    // ========================================================================

    /**
     * @notice Emitted when a new escrow is created.
     * @param escrowId Identifier of the escrow.
     * @param buyer Buyer address.
     * @param seller Seller address.
     * @param arbitrator Assigned arbitrator (admin-set).
     * @param listingRef Off-chain listing reference (e.g., IPFS CID).
     * @param escrowFeeBpsAtCreate Fee bps captured at create time.
     */
    event PrivateEscrowCreated(
        bytes32 indexed escrowId,
        address indexed buyer,
        address indexed seller,
        address arbitrator,
        bytes32 listingRef,
        uint64 escrowFeeBpsAtCreate
    );

    /**
     * @notice Emitted when the buyer releases the escrow to the seller.
     * @param escrowId Identifier of the escrow.
     * @param buyer Buyer who released.
     * @param seller Recipient of the encrypted payout.
     */
    event PrivateEscrowReleased(
        bytes32 indexed escrowId,
        address indexed buyer,
        address indexed seller
    );

    /**
     * @notice Emitted when the seller refunds the buyer.
     * @param escrowId Identifier of the escrow.
     * @param buyer Recipient of the encrypted refund.
     * @param seller Seller who refunded.
     */
    event PrivateEscrowRefunded(
        bytes32 indexed escrowId,
        address indexed buyer,
        address indexed seller
    );

    /**
     * @notice Emitted when a dispute is raised.
     * @param escrowId Identifier of the escrow.
     * @param disputer Address that raised the dispute (buyer or seller).
     */
    event PrivateDisputeRaised(bytes32 indexed escrowId, address indexed disputer);

    /**
     * @notice Emitted when an arbitrator resolves a disputed escrow.
     * @param escrowId Identifier of the escrow.
     * @param arbitrator Arbitrator who resolved.
     * @param winner The party whose side won the dispute (buyer or seller).
     */
    event PrivateEscrowArbitrated(
        bytes32 indexed escrowId,
        address indexed arbitrator,
        address indexed winner
    );

    /**
     * @notice Emitted when the backing pXOM token is bound via {initializeV3}.
     * @param token Address of the COTI {PrivateOmniCoin} (pXOM) contract.
     */
    event PrivateTokenSet(address indexed token);

    /**
     * @notice Emitted when admin queues an escrow-fee update.
     * @param newFeeBps Pending fee in basis points.
     * @param effectiveAt Earliest block timestamp at which it can be applied.
     */
    event EscrowFeeUpdateQueued(uint64 indexed newFeeBps, uint256 effectiveAt);

    /**
     * @notice Emitted when the queued escrow-fee update is applied.
     * @param oldFeeBps Previous fee.
     * @param newFeeBps New fee.
     */
    event EscrowFeeUpdated(uint64 indexed oldFeeBps, uint64 indexed newFeeBps);

    /**
     * @notice Emitted when admin queues a fee-vault update.
     * @param feeVault Pending vault address.
     * @param effectiveAt Earliest block timestamp at which it can be applied.
     */
    event FeeVaultUpdateQueued(address indexed feeVault, uint256 effectiveAt);

    /**
     * @notice Emitted when the queued fee-vault update is applied.
     * @param oldVault Previous vault address.
     * @param newVault New vault address.
     */
    event FeeVaultUpdated(address indexed oldVault, address indexed newVault);

    /**
     * @notice Emitted when admin queues a trusted-forwarder update.
     * @param forwarder Pending forwarder address.
     * @param effectiveAt Earliest block timestamp at which it can be applied.
     */
    event TrustedForwarderUpdateQueued(address indexed forwarder, uint256 effectiveAt);

    /**
     * @notice Emitted when the queued forwarder update is applied.
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
     *         attestation verifier used by {createEscrowWithCommittee}.
     * @param verifier New verifier; zero address disables the
     *         committee path (legacy {createEscrow} remains functional).
     */
    event AttestationVerifierSet(IBridgeVerifier indexed verifier);

    /**
     * @notice Emitted when an escrow is created via the committee
     *         attestation path. Companion to {PrivateEscrowCreated};
     *         persists the attester list so off-chain slashing
     *         pipelines can recover it after the 256-block blockhash
     *         window expires.
     * @param escrowId Escrow identifier.
     * @param attesters Sorted, deduplicated list of validator
     *        attesters whose signatures satisfied the committee
     *        quorum.
     */
    event EscrowCommitteeAttested(
        bytes32 indexed escrowId,
        address[] attesters
    );

    /**
     * @notice Emitted when a disputed escrow is resolved via the random
     *         committee attestation path ({resolveDisputeWithCommittee})
     *         rather than by a single `ARBITRATOR_ROLE` holder. Companion
     *         to {PrivateEscrowArbitrated}; persists the attester list so
     *         off-chain slashing pipelines can recover it after the
     *         256-block blockhash window expires.
     * @param escrowId Escrow identifier.
     * @param winner The party the committee attested as the dispute winner.
     * @param attesters Sorted, deduplicated list of validator attesters
     *        whose signatures satisfied the committee quorum.
     */
    event PrivateDisputeCommitteeResolved(
        bytes32 indexed escrowId,
        address indexed winner,
        address[] attesters
    );

    // ========================================================================
    // CUSTOM ERRORS
    // ========================================================================

    error EscrowAlreadyExists();
    error EscrowNotActive();
    error EscrowNotDisputed();
    error InvalidAddress();
    error InvalidBuyerSignature();
    error NotBuyer();
    error NotSeller();
    error NotPartyToEscrow();
    error DeadlineExpired();
    error TooEarlyToDispute();
    error EscrowFeeTooHigh();
    error EscrowFeeMismatch();
    error UnsupportedChain(uint256 chainId);
    error TimelockDelayNotElapsed();
    error TimelockNotRequested();
    error TimelockAlreadyRequested();
    error UpgradeNotAuthorized();
    error ContractIsOssified();
    error OssificationNotRequested();
    error OssificationAlreadyRequested();
    error OssificationDelayNotElapsed();
    error CannotRenounceAdmin();
    error AttestationVerifierNotSet();
    error InvalidCommitteeAttestation();
    error SubjectInCommittee();
    error InvalidVerifier();
    error InvalidWinner();
    /// @dev The backing pXOM token has not been bound via {initializeV3}.
    error PrivateTokenNotSet();

    // ========================================================================
    // CONSTRUCTOR & INITIALIZATION
    // ========================================================================

    /**
     * @notice Constructor that disables initializers on the implementation.
     * @custom:oz-upgrades-unsafe-allow constructor
     */
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the proxy state.
     * @dev Reverts on any chain other than COTI 2632500 / 7082400.
     * @param admin Admin (DEFAULT_ADMIN_ROLE). Multisig+timelock recommended.
     * @param relayers Initial RELAYER_ROLE holders (validator matchers).
     * @param arbitrators Initial ARBITRATOR_ROLE holders.
     * @param feeVault_ UnifiedFeeVault recipient address on COTI.
     * @param trustedForwarder_ ERC-2771 forwarder; `address(0)` to disable meta-tx.
     */
    function initialize( // solhint-disable-line code-complexity
        address admin,
        address[] calldata relayers,
        address[] calldata arbitrators,
        address feeVault_,
        address trustedForwarder_
    ) external initializer {
        if (
            block.chainid != COTI_MAINNET_CHAIN_ID
                && block.chainid != COTI_TESTNET_CHAIN_ID
        ) {
            revert UnsupportedChain(block.chainid);
        }
        if (admin == address(0)) revert InvalidAddress();
        // Audit M-1: feeVault == this would brick fee payouts (`from == to`).
        if (feeVault_ == address(0) || feeVault_ == address(this)) {
            revert InvalidAddress();
        }

        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        // solhint-disable-next-line gas-small-strings
        __EIP712_init("OmniBazaar PrivateMarketplaceEscrow", "1");

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        for (uint256 i = 0; i < relayers.length; ++i) {
            address r = relayers[i];
            if (r == address(0)) revert InvalidAddress();
            _grantRole(RELAYER_ROLE, r);
        }
        for (uint256 i = 0; i < arbitrators.length; ++i) {
            address a = arbitrators[i];
            if (a == address(0)) revert InvalidAddress();
            _grantRole(ARBITRATOR_ROLE, a);
        }

        feeVault = feeVault_;
        escrowFeeBps = DEFAULT_ESCROW_FEE_BPS;
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
     * @notice Reinitializer (version 3) — bind the COTI pXOM token whose
     *         encrypted balance backs every escrow, enabling real custody.
     * @dev Settlement-direct migration. From this upgrade on, {createEscrow}
     *      and {createEscrowWithCommittee} pull the buyer's committed price
     *      into custody via {IPrivateERC20-transferFromGT}, and
     *      {release}/{refund}/{arbitrate}/{expireDispute} pay recipients
     *      directly via {IPrivateERC20-transferGT}. The legacy
     *      encrypted-accumulator + `claim` model is removed (its storage slots
     *      are layout-reserved — see {accumulatedBalances}).
     *
     *      Pioneer-Phase rule: the caller is the deployer EOA holding
     *      `DEFAULT_ADMIN_ROLE`; no timelock. Run atomically with the UUPS
     *      upgrade (`upgradeToAndCall`) so no escrow can be created before the
     *      token is bound.
     * @param pxom_ Address of {PrivateOmniCoin} (pXOM) on COTI 2632500.
     */
    function initializeV3(address pxom_)
        external
        reinitializer(3)
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (pxom_ == address(0)) revert InvalidAddress();
        privateToken = IPrivateERC20(pxom_);
        emit PrivateTokenSet(pxom_);
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
    // EXTERNAL — ESCROW LIFECYCLE
    // ========================================================================

    /**
     * @notice Create a new escrow on behalf of a signed-intent buyer.
     * @dev Called by an authorized RELAYER. The buyer's EIP-712 signature
     *      binds the encrypted-price commitment + seller + arbitrator
     *      + listingRef + escrowFeeBps + deadline so the relayer cannot
     *      substitute any of those after the buyer signs (audit H-01).
     *
     *      Takes real pXOM custody: after verifying the buyer's signature,
     *      the escrow pulls `encPrice` from the buyer into its own balance via
     *      {IPrivateERC20-transferFromGT} (the buyer pre-approves this
     *      contract as spender for the encrypted amount). The pull reverts
     *      privacy-safely — only a success bit is decrypted, never the
     *      amount — on insufficient balance/allowance, so a created escrow is
     *      always fully funded. Settlement (release/refund/arbitrate) later
     *      pays recipients directly out of this custody via
     *      {IPrivateERC20-transferGT}.
     * @param escrowId Unique escrow identifier.
     * @param buyer Buyer address.
     * @param seller Seller address.
     * @param arbitrator Arbitrator (must hold ARBITRATOR_ROLE).
     * @param listingRef Off-chain listing reference (IPFS CID, etc.).
     * @param encPrice Encrypted price commitment (ctUint256).
     * @param expectedFeeBps Fee bps the buyer signed against.
     * @param deadline Unix-seconds settlement deadline.
     * @param buyerSignature EIP-712 signature from the buyer.
     */
    function createEscrow( // solhint-disable-line code-complexity
        bytes32 escrowId,
        address buyer,
        address seller,
        address arbitrator,
        bytes32 listingRef,
        ctUint256 calldata encPrice,
        uint64 expectedFeeBps,
        uint256 deadline,
        bytes calldata buyerSignature
    ) external onlyRole(RELAYER_ROLE) whenNotPaused nonReentrant {
        if (buyer == address(0)) revert InvalidAddress();
        if (seller == address(0)) revert InvalidAddress();
        if (arbitrator == address(0)) revert InvalidAddress();
        if (!hasRole(ARBITRATOR_ROLE, arbitrator)) revert InvalidAddress();
        if (buyer == seller) revert InvalidAddress();
        // Audit M-1: a payout to the escrow itself would revert
        // (`from == to`) and brick settlement — reject self-address parties.
        if (buyer == address(this) || seller == address(this)) {
            revert InvalidAddress();
        }
        // Audit M-2: fail fast (and avoid a silent no-op pull to a code-less
        // address) if the backing token was never bound via initializeV3.
        if (address(privateToken) == address(0)) revert PrivateTokenNotSet();
        // solhint-disable-next-line not-rely-on-time, gas-strict-inequalities
        if (deadline <= block.timestamp) revert DeadlineExpired();
        if (escrows[escrowId].status != EscrowStatus.EMPTY) {
            revert EscrowAlreadyExists();
        }
        uint64 liveFeeBps = escrowFeeBps;
        if (expectedFeeBps != liveFeeBps) revert EscrowFeeMismatch();

        bytes32 priceCommit = _commit(encPrice);
        bytes32 structHash = keccak256(
            abi.encode(
                CREATE_ESCROW_TYPEHASH,
                escrowId,
                buyer,
                seller,
                arbitrator,
                listingRef,
                priceCommit,
                expectedFeeBps,
                deadline
            )
        );
        bytes32 digest = _hashTypedDataV4(structHash);
        if (ECDSA.recover(digest, buyerSignature) != buyer) {
            revert InvalidBuyerSignature();
        }

        escrows[escrowId] = PrivateEscrow({
            buyer: buyer,
            seller: seller,
            arbitrator: arbitrator,
            listingRef: listingRef,
            encPrice: encPrice,
            // solhint-disable-next-line not-rely-on-time
            createdAt: block.timestamp,
            deadline: deadline,
            disputeRaisedAt: 0,
            escrowFeeBpsAtCreate: liveFeeBps,
            status: EscrowStatus.ACTIVE
        });

        unchecked {
            ++totalEscrows;
        }

        // Take real pXOM custody: pull the buyer's committed price into the
        // escrow (buyer pre-approves this contract as spender). Reverts
        // privacy-safely on insufficient balance/allowance — see NatSpec.
        privateToken.transferFromGT(
            buyer, address(this), MpcCore.onBoard(encPrice)
        );

        emit PrivateEscrowCreated(
            escrowId, buyer, seller, arbitrator, listingRef, liveFeeBps
        );
    }

    /**
     * @notice Create an escrow — committee attestation path.
     * @dev Replaces the static `RELAYER_ROLE` gate with a random
     *      M-of-N validator committee per
     *      `memory/decision_privacy_roles_random_committee_2026-05-27.md`.
     *      Both gates verify the same `CreateEscrowIntent` EIP-712
     *      digest: buyer's signature + committee's ≥M signatures.
     *
     *      Caller authorisation: anyone may submit.
     *
     *      The buyer (subject) MUST NOT appear in the committee
     *      attester list (Phase 2 audit Pass-1 C-2 fix).
     *
     *      Emits {EscrowCommitteeAttested} with the attester list.
     *      The dispute-arbitration flow has its own committee path,
     *      {resolveDisputeWithCommittee}, so neither escrow creation nor
     *      dispute resolution requires a deployer-key signature; the legacy
     *      `ARBITRATOR_ROLE` {arbitrate} remains as a swappable fallback.
     * @param escrowId Unique escrow identifier.
     * @param buyer Buyer address.
     * @param seller Seller address.
     * @param arbitrator Arbitrator (must hold ARBITRATOR_ROLE).
     * @param listingRef Off-chain listing reference (IPFS CID, etc.).
     * @param encPrice Encrypted price commitment (ctUint256).
     * @param expectedFeeBps Fee bps the buyer signed against.
     * @param deadline Unix-seconds settlement deadline.
     * @param buyerSignature EIP-712 signature from the buyer.
     * @param committeeProof Verifier-specific opaque blob containing
     *        the M-of-N committee signatures over the same
     *        `CreateEscrowIntent` digest as {buyerSignature}.
     */
    function createEscrowWithCommittee( // solhint-disable-line code-complexity
        bytes32 escrowId,
        address buyer,
        address seller,
        address arbitrator,
        bytes32 listingRef,
        itUint256 calldata encPrice,
        uint64 expectedFeeBps,
        uint256 deadline,
        bytes calldata buyerSignature,
        bytes calldata committeeProof
    ) external whenNotPaused nonReentrant {
        if (buyer == address(0)) revert InvalidAddress();
        if (seller == address(0)) revert InvalidAddress();
        if (arbitrator == address(0)) revert InvalidAddress();
        if (!hasRole(ARBITRATOR_ROLE, arbitrator)) revert InvalidAddress();
        if (buyer == seller) revert InvalidAddress();
        // Audit M-1: a payout to the escrow itself would revert
        // (`from == to`) and brick settlement — reject self-address parties.
        if (buyer == address(this) || seller == address(this)) {
            revert InvalidAddress();
        }
        // Audit M-2: fail fast (and avoid a silent no-op pull to a code-less
        // address) if the backing token was never bound via initializeV3.
        if (address(privateToken) == address(0)) revert PrivateTokenNotSet();
        // solhint-disable-next-line not-rely-on-time, gas-strict-inequalities
        if (deadline <= block.timestamp) revert DeadlineExpired();
        if (escrows[escrowId].status != EscrowStatus.EMPTY) {
            revert EscrowAlreadyExists();
        }
        uint64 liveFeeBps = escrowFeeBps;
        if (expectedFeeBps != liveFeeBps) revert EscrowFeeMismatch();

        bytes32 digest = _createEscrowIntentDigest(
            escrowId,
            buyer,
            seller,
            arbitrator,
            listingRef,
            encPrice.ciphertext,
            expectedFeeBps,
            deadline
        );
        if (ECDSA.recover(digest, buyerSignature) != buyer) {
            revert InvalidBuyerSignature();
        }

        (bool valid, address[] memory attesters) =
            _verifyCommittee(digest, committeeProof);
        if (!valid) revert InvalidCommitteeAttestation();

        uint256 attesterCount = attesters.length;
        if (attesterCount == 0) revert InvalidCommitteeAttestation();
        // Audit 2026-05-27 finding C-1: subject-not-in-committee must
        // exclude every named party (buyer, seller, arbitrator), not
        // just the EIP-712 signer. A seller or arbitrator seated on
        // the committee could otherwise self-attest to escrows they
        // have direct stake in. The Phase 2 audit Pass-1 C-2 framing
        // ("subject MUST NOT appear in the committee") generalises
        // here to the full set of named on-chain parties.
        for (uint256 i = 0; i < attesterCount; ) {
            address a = attesters[i];
            if (a == buyer || a == seller || a == arbitrator) {
                revert SubjectInCommittee();
            }
            unchecked {
                ++i;
            }
        }

        // Validate the buyer's encrypted INPUT (itUint256): binds the
        // ciphertext to msg.sender (the buyer, who broadcasts this committee
        // create) + this contract + this selector, yielding a network
        // gtUint256. The stored price is the offBoard of that handle (a NETWORK
        // ctUint256) so release/refund/dispute can re-`onBoard` it — the raw
        // client input ciphertext is user-key encrypted and is NOT onBoard-able
        // (mirrors PrivateYieldVault; replaces the broken onBoard(ctUint256)).
        gtUint256 priceG = MpcCore.validateCiphertext(encPrice);

        escrows[escrowId] = PrivateEscrow({
            buyer: buyer,
            seller: seller,
            arbitrator: arbitrator,
            listingRef: listingRef,
            encPrice: MpcCore.offBoard(priceG),
            // solhint-disable-next-line not-rely-on-time
            createdAt: block.timestamp,
            deadline: deadline,
            disputeRaisedAt: 0,
            escrowFeeBpsAtCreate: liveFeeBps,
            status: EscrowStatus.ACTIVE
        });

        unchecked {
            ++totalEscrows;
        }

        // Take real pXOM custody: pull the buyer's committed price into the
        // escrow (buyer pre-approves this contract as spender). Reverts
        // privacy-safely on insufficient balance/allowance — see {createEscrow}.
        privateToken.transferFromGT(buyer, address(this), priceG);

        emit EscrowCommitteeAttested(escrowId, attesters);
        emit PrivateEscrowCreated(
            escrowId, buyer, seller, arbitrator, listingRef, liveFeeBps
        );
    }

    /**
     * @notice Buyer releases the escrow to the seller.
     * @dev Buyer-only. Splits the encrypted price into seller payout
     *      (`price * (1 - feeBps/10000)`) and vault fee
     *      (`price * feeBps/10000`); transfers each directly to the recipient
     *      from escrow custody via {IPrivateERC20-transferGT} (see {_settle}).
     * @param escrowId Escrow identifier.
     */
    function release(bytes32 escrowId) external whenNotPaused nonReentrant {
        PrivateEscrow storage entry = escrows[escrowId];
        if (entry.status != EscrowStatus.ACTIVE) revert EscrowNotActive();
        if (msg.sender != entry.buyer) revert NotBuyer();

        entry.status = EscrowStatus.RELEASED;

        _settle(entry);
        emit PrivateEscrowReleased(escrowId, entry.buyer, entry.seller);
    }

    /**
     * @notice Seller refunds the escrow to the buyer.
     * @dev Seller-only. Transfers the entire encrypted price back to the
     *      buyer from escrow custody via {IPrivateERC20-transferGT} (no fee;
     *      the seller is voluntarily forfeiting the trade, the platform should
     *      not penalize the buyer with a fee).
     * @param escrowId Escrow identifier.
     */
    function refund(bytes32 escrowId) external whenNotPaused nonReentrant {
        PrivateEscrow storage entry = escrows[escrowId];
        if (entry.status != EscrowStatus.ACTIVE) revert EscrowNotActive();
        if (msg.sender != entry.seller) revert NotSeller();

        entry.status = EscrowStatus.REFUNDED;

        gtUint256 priceG = MpcCore.onBoard(entry.encPrice);
        privateToken.transferGT(entry.buyer, priceG);
        emit PrivateEscrowRefunded(escrowId, entry.buyer, entry.seller);
    }

    /**
     * @notice Buyer or seller raises a dispute.
     * @dev Either party may dispute after {MIN_DISPUTE_DELAY} has elapsed.
     *      Sets status → DISPUTED; arbitrator resolves via {arbitrate}.
     *      NOT gated by `whenNotPaused` so users can always escape a
     *      stuck escrow even during admin pause.
     * @param escrowId Escrow identifier.
     */
    function dispute(bytes32 escrowId) external nonReentrant {
        PrivateEscrow storage entry = escrows[escrowId];
        if (entry.status != EscrowStatus.ACTIVE) revert EscrowNotActive();
        address caller = msg.sender;
        if (caller != entry.buyer && caller != entry.seller) {
            revert NotPartyToEscrow();
        }
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp < entry.createdAt + MIN_DISPUTE_DELAY) {
            revert TooEarlyToDispute();
        }

        entry.status = EscrowStatus.DISPUTED;
        // solhint-disable-next-line not-rely-on-time
        entry.disputeRaisedAt = block.timestamp;
        emit PrivateDisputeRaised(escrowId, caller);
    }

    /**
     * @notice Arbitrator resolves a disputed escrow.
     * @dev Audit H-03: caller MUST be the arbitrator captured in the
     *      escrow record at create time, not just any holder of
     *      `ARBITRATOR_ROLE`. Audit M-03: NOT gated by `whenNotPaused`
     *      so admin pause cannot trap DISPUTED escrows.
     *
     *      Splits the encrypted price:
     *        - 2.5 % arbitration fee → fee vault (winner's half of the
     *          50/50 cost; loser's half deferred to v2 bond mechanism).
     *        - winner receives `price * (1 − 2.5 %)`; loser receives 0.
     *      Single-arbitrator decisions accepted in v1; panel rotation
     *      deferred to v2.
     * @param escrowId Escrow identifier.
     * @param winner The party who won the dispute (must equal `buyer` or
     *               `seller`).
     */
    function arbitrate(bytes32 escrowId, address winner)
        external
        nonReentrant
        onlyRole(ARBITRATOR_ROLE)
    {
        PrivateEscrow storage entry = escrows[escrowId];
        if (entry.status != EscrowStatus.DISPUTED) revert EscrowNotDisputed();
        // Audit Pass-3 M-4 — explicit zero-address guard. The check
        // below transitively excludes address(0) because buyer/seller
        // are non-zero per createEscrow's address(0) guard, but a
        // future change that loosened those checks would silently
        // re-open this attack surface. Pin the invariant explicitly.
        if (winner == address(0)) revert InvalidWinner();
        if (winner != entry.buyer && winner != entry.seller) {
            revert InvalidWinner();
        }
        // Audit H-03: only the per-escrow assigned arbitrator may resolve.
        if (msg.sender != entry.arbitrator) revert NotPartyToEscrow();

        entry.status = winner == entry.buyer
            ? EscrowStatus.ARBITRATED_TO_BUYER
            : EscrowStatus.ARBITRATED_TO_SELLER;

        _settleArbitration(entry, winner);

        emit PrivateEscrowArbitrated(escrowId, msg.sender, winner);
    }

    /**
     * @notice Resolve a disputed escrow on a random-committee attestation —
     *         no `ARBITRATOR_ROLE` (deployer-key) signature required.
     * @dev Replaces the single-arbitrator trust assumption of {arbitrate}
     *      with the same random M-of-N validator committee already used by
     *      {createEscrowWithCommittee}, per
     *      `memory/decision_privacy_roles_random_committee_2026-05-27.md`.
     *      The committee decides the OUTCOME (which party won); the contract
     *      enforces the identical payout split as {arbitrate}
     *      (2.5 % arbitration fee → vault, remainder → winner) via the
     *      shared {_settleArbitration}. This removes the manual
     *      deployer-key arbitration step so dispute resolution survives the
     *      post-launch retirement of the deployer key.
     *
     *      Authorisation model:
     *        - Anyone may submit (the gas-paying relayer / winner / any
     *          party). Authority comes solely from the committee's ≥M
     *          signatures over the {RESOLVE_DISPUTE_TYPEHASH} digest binding
     *          `(escrowId, winner)`.
     *        - The committee is derived from the on-chain eligible-set
     *          snapshot via {_verifyCommittee} (Fisher-Yates over
     *          `blockhash(commitBlock)`), so no static role allowlist is
     *          consulted.
     *        - No named party (buyer, seller, arbitrator) may appear in the
     *          attester list — a party seated on the committee could
     *          otherwise self-attest an outcome they profit from (mirrors
     *          the {createEscrowWithCommittee} subject-exclusion, Phase 2
     *          audit Pass-1 C-2).
     *
     *      Fallbacks preserved: the buyer's {expireDispute} timeout escape
     *      and the legacy {arbitrate} (`ARBITRATOR_ROLE`, a swappable
     *      address) both remain callable.
     *
     *      NOT gated by `whenNotPaused` — admin pause must not trap DISPUTED
     *      escrows (audit M-03, matching {arbitrate}).
     *
     *      Emits {PrivateDisputeCommitteeResolved} (attester list) and
     *      {PrivateEscrowArbitrated} (with `arbitrator = address(this)` to
     *      mark a committee resolution) so existing indexers pick it up.
     * @param escrowId Escrow identifier.
     * @param winner The party the committee attested as the winner (must
     *        equal the escrow's `buyer` or `seller`).
     * @param committeeProof Proof blob `commitBlock(32) || sig0(65) || ...`
     *        carrying the M-of-N committee signatures over the
     *        {RESOLVE_DISPUTE_TYPEHASH} digest for `(escrowId, winner)`.
     */
    function resolveDisputeWithCommittee(
        bytes32 escrowId,
        address winner,
        bytes calldata committeeProof
    ) external nonReentrant {
        PrivateEscrow storage entry = escrows[escrowId];
        if (entry.status != EscrowStatus.DISPUTED) revert EscrowNotDisputed();
        // Audit Pass-3 M-4 parity with {arbitrate}: explicit zero-address
        // guard even though the winner==buyer||seller check below already
        // excludes it (buyer/seller are non-zero at create).
        if (winner == address(0)) revert InvalidWinner();
        if (winner != entry.buyer && winner != entry.seller) {
            revert InvalidWinner();
        }

        address[] memory attesters = _verifyDisputeOutcome(
            escrowId,
            winner,
            entry.buyer,
            entry.seller,
            entry.arbitrator,
            committeeProof
        );

        entry.status = winner == entry.buyer
            ? EscrowStatus.ARBITRATED_TO_BUYER
            : EscrowStatus.ARBITRATED_TO_SELLER;

        _settleArbitration(entry, winner);

        emit PrivateDisputeCommitteeResolved(escrowId, winner, attesters);
        // `arbitrator = address(this)` marks a committee (not single-role)
        // resolution while keeping the existing indexer event shape.
        emit PrivateEscrowArbitrated(escrowId, address(this), winner);
    }

    /**
     * @notice Auto-resolve a dispute that has timed out without arbitration.
     * @dev Audit H-02: callable by the buyer once
     *      `block.timestamp > entry.disputeRaisedAt + DISPUTE_TIMEOUT`.
     *      Refunds the full encrypted price to the buyer (no fee — same
     *      treatment as a seller-initiated {refund}). Mirrors
     *      `MinimalEscrow`'s expired-buyer-refund path.
     *
     *      NOT gated by `whenNotPaused` — the timeout is a user-recovery
     *      escape that admin pause must not block.
     * @param escrowId Escrow identifier.
     */
    function expireDispute(bytes32 escrowId) external nonReentrant {
        PrivateEscrow storage entry = escrows[escrowId];
        if (entry.status != EscrowStatus.DISPUTED) revert EscrowNotDisputed();
        if (msg.sender != entry.buyer) revert NotBuyer();
        // solhint-disable-next-line not-rely-on-time, gas-strict-inequalities
        if (block.timestamp < entry.disputeRaisedAt + DISPUTE_TIMEOUT) {
            revert DeadlineExpired();
        }

        _refundDisputed(escrowId, entry);
    }

    /**
     * @notice Default-resolution timeout for a committee dispute (VT-27).
     * @dev Permissionless: once
     *      `block.timestamp >= entry.disputeRaisedAt + DISPUTE_TIMEOUT`
     *      with no resolution, anyone can auto-refund the buyer. Uses the SAME
     *      {DISPUTE_TIMEOUT} as {expireDispute} (NOT a shorter window) because
     *      the escrow does not yet carry a per-escrow "committee-path" flag to
     *      distinguish committee disputes from single-arbitrator disputes — a
     *      shorter permissionless window would silently cut the seller's
     *      arbitration protection (audit VT-27 F2). When {resolveDisputeWithCommittee}
     *      is gated behind an explicit committee-path flag, a shorter
     *      committee-specific timeout can be reintroduced scoped to that flag.
     *
     *      The refund always goes to the buyer (no fee — same treatment as
     *      {expireDispute}), so a permissionless trigger cannot be abused for
     *      theft; it only un-sticks a dispute that never resolved.
     *
     *      NOT gated by `whenNotPaused` — the timeout is a user-recovery
     *      escape that admin pause must not block.
     * @param escrowId Escrow identifier.
     */
    function expireCommitteeDispute(bytes32 escrowId) external nonReentrant {
        PrivateEscrow storage entry = escrows[escrowId];
        if (entry.status != EscrowStatus.DISPUTED) revert EscrowNotDisputed();
        // solhint-disable-next-line not-rely-on-time, gas-strict-inequalities
        if (block.timestamp < entry.disputeRaisedAt + DISPUTE_TIMEOUT) {
            revert DeadlineExpired();
        }

        _refundDisputed(escrowId, entry);
    }

    /**
     * @notice Shared refund body for a DISPUTED escrow (buyer refund, no fee).
     * @dev Mirrors the seller-initiated {refund} treatment: the encrypted price
     *      is returned to the buyer in full. Used by both {expireDispute}
     *      (buyer-only, `DISPUTE_TIMEOUT`) and {expireCommitteeDispute}
     *      (permissionless, `DISPUTE_TIMEOUT`).
     * @param escrowId Escrow identifier.
     * @param entry Escrow storage ref (already validated DISPUTED + timed out).
     */
    function _refundDisputed(
        bytes32 escrowId,
        PrivateEscrow storage entry
    ) private {
        entry.status = EscrowStatus.REFUNDED;

        gtUint256 priceG = MpcCore.onBoard(entry.encPrice);
        privateToken.transferGT(entry.buyer, priceG);
        emit PrivateEscrowRefunded(escrowId, entry.buyer, entry.seller);
    }

    // ========================================================================
    // EXTERNAL — ATTESTATION VERIFIER WIRING (PIONEER PHASE)
    // ========================================================================

    /**
     * @notice Point the random-committee attestation verifier used by
     *         {createEscrowWithCommittee}.
     * @dev Pioneer Phase admin model: deployer-direct, zero delay.
     *      Once Pioneer ends, `DEFAULT_ADMIN_ROLE` transitions to
     *      `OmniTimelockController` + governance.
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
     * @notice Queue an escrow-fee update; effective after {TIMELOCK_DELAY}.
     * @param newFeeBps New fee in basis points (max {MAX_ESCROW_FEE_BPS}).
     */
    function requestEscrowFeeUpdate(uint64 newFeeBps)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (newFeeBps > MAX_ESCROW_FEE_BPS) revert EscrowFeeTooHigh();
        if (pendingFee.effectiveAt != 0) revert TimelockAlreadyRequested();
        // solhint-disable-next-line not-rely-on-time
        uint256 effectiveAt = block.timestamp + TIMELOCK_DELAY;
        pendingFee = PendingFee({newFeeBps: newFeeBps, effectiveAt: effectiveAt});
        emit EscrowFeeUpdateQueued(newFeeBps, effectiveAt);
    }

    /**
     * @notice Apply the queued escrow-fee update.
     * @dev Audit M-02: admin-gated to prevent searcher front-running of
     *      fee changes (any caller could otherwise flip the fee at the
     *      timelock boundary, causing user `createEscrow` calls to revert
     *      with `EscrowFeeMismatch`).
     */
    function confirmEscrowFeeUpdate() external onlyRole(DEFAULT_ADMIN_ROLE) {
        PendingFee memory pending = pendingFee;
        if (pending.effectiveAt == 0) revert TimelockNotRequested();
        // solhint-disable-next-line not-rely-on-time, gas-strict-inequalities
        if (block.timestamp < pending.effectiveAt) revert TimelockDelayNotElapsed();
        uint64 oldFee = escrowFeeBps;
        escrowFeeBps = pending.newFeeBps;
        delete pendingFee;
        emit EscrowFeeUpdated(oldFee, pending.newFeeBps);
    }

    /**
     * @notice Cancel the queued escrow-fee update.
     */
    function cancelPendingEscrowFeeUpdate()
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (pendingFee.effectiveAt == 0) revert TimelockNotRequested();
        delete pendingFee;
        emit PendingUpdateCancelled("escrowFee");
    }

    /**
     * @notice Queue a fee-vault update; effective after {TIMELOCK_DELAY}.
     * @param newVault New UnifiedFeeVault recipient on COTI.
     */
    function requestFeeVaultUpdate(address newVault)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        // Audit M-1: feeVault == this would brick fee payouts (`from == to`).
        if (newVault == address(0) || newVault == address(this)) {
            revert InvalidAddress();
        }
        if (pendingFeeVault.effectiveAt != 0) revert TimelockAlreadyRequested();
        // solhint-disable-next-line not-rely-on-time
        uint256 effectiveAt = block.timestamp + TIMELOCK_DELAY;
        pendingFeeVault =
            PendingFeeVault({feeVault: newVault, effectiveAt: effectiveAt});
        emit FeeVaultUpdateQueued(newVault, effectiveAt);
    }

    /**
     * @notice Apply the queued fee-vault update.
     * @dev Audit M-02 — admin-gated for the same front-running reason.
     */
    function confirmFeeVaultUpdate() external onlyRole(DEFAULT_ADMIN_ROLE) {
        PendingFeeVault memory pending = pendingFeeVault;
        if (pending.effectiveAt == 0) revert TimelockNotRequested();
        // solhint-disable-next-line not-rely-on-time, gas-strict-inequalities
        if (block.timestamp < pending.effectiveAt) revert TimelockDelayNotElapsed();
        address old = feeVault;
        feeVault = pending.feeVault;
        delete pendingFeeVault;
        emit FeeVaultUpdated(old, pending.feeVault);
    }

    /**
     * @notice Cancel the queued fee-vault update.
     */
    function cancelPendingFeeVaultUpdate()
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (pendingFeeVault.effectiveAt == 0) revert TimelockNotRequested();
        delete pendingFeeVault;
        emit PendingUpdateCancelled("feeVault");
    }

    /**
     * @notice Queue a trusted-forwarder update; effective after {TIMELOCK_DELAY}.
     * @param newForwarder New ERC-2771 forwarder; `address(0)` disables meta-tx.
     */
    function requestTrustedForwarderUpdate(address newForwarder)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (pendingForwarder.effectiveAt != 0) revert TimelockAlreadyRequested();
        // solhint-disable-next-line not-rely-on-time
        uint256 effectiveAt = block.timestamp + TIMELOCK_DELAY;
        pendingForwarder =
            PendingForwarder({forwarder: newForwarder, effectiveAt: effectiveAt});
        emit TrustedForwarderUpdateQueued(newForwarder, effectiveAt);
    }

    /**
     * @notice Apply the queued forwarder update.
     * @dev Audit M-02 — admin-gated for the same front-running reason.
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

    // ========================================================================
    // EXTERNAL — ADMIN (PAUSE + OSSIFICATION)
    // ========================================================================

    /// @notice Pause new escrow creation + release/refund/arbitrate.
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /// @notice Resume.
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /**
     * @notice Begin the 7-day ossification window.
     * @dev Reverts if a request is already pending; use {cancelOssificationRequest}.
     */
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
    // INTERNAL
    // ========================================================================

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

    /**
     * @notice ERC-2771 sender resolution. Returns the trader address from
     *         calldata if the forwarder relayed; otherwise `msg.sender`.
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
     * @notice ERC-2771 trailing-byte length (forwarder address suffix).
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
     * @notice Verify a random-committee dispute-outcome attestation and
     *         return the attester list.
     * @dev Extracted from {resolveDisputeWithCommittee} so the committee
     *      authorisation can be unit-tested off-chain (no MPC) exactly as
     *      the contract runs it. Reverts:
     *        - {InvalidCommitteeAttestation} if `_verifyCommittee` fails or
     *          the attester set is empty;
     *        - {SubjectInCommittee} if any named party (buyer, seller,
     *          arbitrator) appears among the attesters.
     * @param escrowId Escrow identifier bound into the digest.
     * @param winner The attested winner bound into the digest.
     * @param buyer Escrow buyer (excluded from the committee).
     * @param seller Escrow seller (excluded from the committee).
     * @param arbitrator Escrow arbitrator (excluded from the committee).
     * @param committeeProof Proof blob `commitBlock(32) || sigs`.
     * @return attesters Recovered committee attester addresses.
     */
    function _verifyDisputeOutcome(
        bytes32 escrowId,
        address winner,
        address buyer,
        address seller,
        address arbitrator,
        bytes calldata committeeProof
    ) internal view returns (address[] memory attesters) {
        bytes32 digest = _resolveDisputeDigest(escrowId, winner);
        bool valid;
        (valid, attesters) = _verifyCommittee(digest, committeeProof);
        if (!valid) revert InvalidCommitteeAttestation();
        uint256 attesterCount = attesters.length;
        if (attesterCount == 0) revert InvalidCommitteeAttestation();
        // Subject-not-in-committee: no named on-chain party may sit on the
        // committee that decides an outcome they profit from (mirrors
        // {createEscrowWithCommittee}; Phase 2 audit Pass-1 C-2).
        for (uint256 i = 0; i < attesterCount; ) {
            address a = attesters[i];
            if (a == buyer || a == seller || a == arbitrator) {
                revert SubjectInCommittee();
            }
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Compute the EIP-712 digest of a {RESOLVE_DISPUTE_TYPEHASH}
     *         outcome attestation.
     * @dev The committee signs the EIP-191 envelope of this digest (the wrap
     *      happens inside {_verifyCommittee}). Domain-separated via
     *      {_hashTypedDataV4}, so a signature is bound to this contract +
     *      chain and cannot be replayed against another privacy contract.
     * @param escrowId Escrow identifier.
     * @param winner Attested winner.
     * @return The EIP-712 digest.
     */
    function _resolveDisputeDigest(bytes32 escrowId, address winner)
        internal
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(
            abi.encode(RESOLVE_DISPUTE_TYPEHASH, escrowId, winner)
        );
        return _hashTypedDataV4(structHash);
    }

    /**
     * @notice Settle a non-arbitrated escrow — split price into seller
     *         payout + vault fee and pay both directly from custody.
     * @dev Audit Pass-3 M-1 cleanup: the previous signature carried a
     *      `refundToBuyer` boolean whose `true` branch was dead code
     *      (`refund` and `expireDispute` both inline the buyer-credit
     *      logic directly). Removed the parameter to eliminate the
     *      footgun.
     *
     *      `feeG + sellerG == priceG`, so the two transfers drain exactly the
     *      custody pulled at create — the escrow is never left holding a
     *      residual balance for this escrow.
     * @param entry Escrow record (storage pointer).
     */
    function _settle(PrivateEscrow storage entry) private {
        gtUint256 priceG = MpcCore.onBoard(entry.encPrice);
        uint64 feeBps = entry.escrowFeeBpsAtCreate;
        gtUint256 feeG = MpcCore.div(
            MpcCore.checkedMul(priceG, MpcCore.setPublic256(uint256(feeBps))),
            MpcCore.setPublic256(BASIS_POINTS_DIVISOR)
        );
        gtUint256 sellerG = MpcCore.checkedSub(priceG, feeG);
        privateToken.transferGT(feeVault, feeG);
        privateToken.transferGT(entry.seller, sellerG);
    }

    /**
     * @notice Settle a resolved dispute — pay the winner from custody net of
     *         the arbitration fee. Shared by {arbitrate} (single-role path)
     *         and {resolveDisputeWithCommittee} (committee path) so both
     *         apply the identical split.
     * @dev Splits the encrypted price: 2.5 % arbitration fee → fee vault
     *      (winner's half of the 50/50 cost; loser's half deferred to the v2
     *      bond mechanism — audit H-01), remainder → winner. `arbFeeG +
     *      winnerAmountG == priceG`, so the two transfers drain exactly the
     *      custody pulled at create.
     * @param entry Escrow record (storage pointer). Caller MUST have already
     *        set `entry.status` to the terminal ARBITRATED_* value.
     * @param winner The party receiving the payout (buyer or seller).
     */
    function _settleArbitration(PrivateEscrow storage entry, address winner)
        private
    {
        gtUint256 priceG = MpcCore.onBoard(entry.encPrice);
        // 2.5 % arbitration fee → vault (audit H-01).
        gtUint256 arbFeeG = MpcCore.div(
            MpcCore.checkedMul(
                priceG, MpcCore.setPublic256(uint256(ARBITRATION_FEE_BPS))
            ),
            MpcCore.setPublic256(BASIS_POINTS_DIVISOR)
        );
        gtUint256 winnerAmountG = MpcCore.checkedSub(priceG, arbFeeG);

        privateToken.transferGT(feeVault, arbFeeG);
        privateToken.transferGT(winner, winnerAmountG);
    }

    /**
     * @notice Compute the EIP-712 digest of a `CreateEscrowIntent`
     *         payload.
     * @dev Extracted so {createEscrowWithCommittee} can verify the
     *      committee signed over the SAME digest the buyer did,
     *      without re-computing inside the verifier.
     * @param escrowId Unique escrow identifier.
     * @param buyer Buyer address.
     * @param seller Seller address.
     * @param arbitrator Arbitrator address.
     * @param listingRef Off-chain listing reference.
     * @param encPrice Encrypted price commitment.
     * @param expectedFeeBps Fee bps the buyer signed against.
     * @param deadline Unix-seconds settlement deadline.
     * @return The EIP-712 digest.
     */
    function _createEscrowIntentDigest(
        bytes32 escrowId,
        address buyer,
        address seller,
        address arbitrator,
        bytes32 listingRef,
        ctUint256 calldata encPrice,
        uint64 expectedFeeBps,
        uint256 deadline
    ) private view returns (bytes32) {
        bytes32 priceCommit = _commit(encPrice);
        bytes32 structHash = keccak256(
            abi.encode(
                CREATE_ESCROW_TYPEHASH,
                escrowId,
                buyer,
                seller,
                arbitrator,
                listingRef,
                priceCommit,
                expectedFeeBps,
                deadline
            )
        );
        return _hashTypedDataV4(structHash);
    }

    /**
     * @notice Hash an encrypted-amount ciphertext into a 32-byte commitment.
     * @param ct Encrypted amount ciphertext.
     * @return The 32-byte commitment.
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
