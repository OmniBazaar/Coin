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
} from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
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

/**
 * @title IAggregatorV3
 * @author OmniBazaar Development Team
 * @notice Chainlink-compatible aggregator interface for public RWA price.
 * @dev Same shape as `OmniPriceOracle.IAggregatorV3` so the same feeds
 *      already wired into the public RWA stack can be reused.
 */
interface IAggregatorV3 {
    /**
     * @notice Get the latest round data.
     * @return roundId The round ID.
     * @return answer The price (scaled by feed decimals).
     * @return startedAt Round start timestamp.
     * @return updatedAt Round update timestamp.
     * @return answeredInRound The round in which answer was computed.
     */
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );

    /**
     * @notice Number of decimals in the price feed.
     * @return Decimal count.
     */
    function decimals() external view returns (uint8);
}

// solhint-disable max-states-count
// The deliberate 21st state slot (`attestationVerifier`) is the
// random-committee wiring added in Week 1.2 of the FIX_PRIVACY resume
// (memory/decision_privacy_roles_random_committee_2026-05-27.md).
// The 20-slot soft-cap is a maintainability heuristic; we accept the
// over-budget delta in exchange for the architectural unification of
// the relayer + escrow-oracle authorisation paths through a single
// pluggable `IBridgeVerifier`.

/**
 * @title PrivateRWAAMM
 * @author OmniBazaar Development Team
 * @notice Privacy-preserving RWA trading on COTI Helium 256-bit MPC.
 * @dev Phase 6.2 of FIX_PRIVACY:
 *      - Buy/sell registered RWA assets with encrypted-quantity intents;
 *        public oracle prices keep the trade computation deterministic
 *        and verifiable while only the user's traded quantity stays
 *        private.
 *      - Per-asset Chainlink-compatible price feed (configurable +
 *        timelocked); contract scales the public price into 18-decimal
 *        canonical wei before MPC multiplication.
 *      - Per-user / per-asset encrypted balance accumulators
 *        (`encXomBalance`, `encRwaBalance`); withdrawals via the
 *        standard {claim} flow that also serves PrivateMarketplaceEscrow
 *        (Phase 5.1) and PrivateYieldVault (Phase 6.1).
 *      - Fee model: flat `tradeFeeBps` per asset (configurable, default
 *        30 bps = 0.30 %, capped at MAX_TRADE_FEE_BPS = 1 %), debited
 *        from the encrypted notional, credited to a single configurable
 *        `feeRecipient` accumulator. The single-recipient design is
 *        intentional — the off-chain UnifiedFeeVault redistributor
 *        applies the protocol's 70/20/10 split (LP / ODDAO / Treasury)
 *        from this clearing accumulator. The contract itself does NOT
 *        attempt the split on-chain because, unlike the public RWAAMM,
 *        there is no LP pool to receive the 70 % share. (Phase 6.2
 *        audit M-03 — accepted as documented design tradeoff.)
 *      - Slippage: trader signs a public `oraclePriceCommit` and the
 *        contract reverts unless the live oracle answer is within
 *        `MAX_SLIPPAGE_BPS` of the committed price.
 *      - Carries forward all audit-remediated patterns:
 *          * COTI-only chainid guard.
 *          * EIP-712 typehash binds quantityCommit + isBuy + assetId +
 *            priceFeed + oraclePriceCommit + nonce + deadline (audit
 *            H-02 fix — priceFeed binding prevents admin feed-rotation
 *            from silently changing the oracle behind a pending intent).
 *          * Deposit requires DUAL signatures — trader's intent +
 *            ESCROW_ORACLE_ROLE attestation co-signing the off-chain
 *            escrow proof (audit H-01 fix — single-relayer compromise
 *            cannot fabricate balances).
 *          * 48 h timelock on every privileged setter (asset config,
 *            forwarder, fee recipient, **and UUPS upgrades** — audit
 *            H-05 fix). Asset-config queue is keyed by assetId so
 *            multiple registrations can run in parallel (M-06 fix).
 *          * UUPS + 7-day two-step ossification (re-request guarded;
 *            cancel available).
 *          * `renounceRole(DEFAULT_ADMIN_ROLE, ...)` overridden to revert.
 *          * Pause does NOT block user-only escape paths ({claimXom},
 *            {claimRwa}). Claim paths use raw `msg.sender`, NOT
 *            `_msgSender()` (audit M-07 fix), so a malicious or
 *            compromised ERC-2771 forwarder cannot impersonate a holder.
 *          * Trusted forwarder held in proxy storage (audit H-06).
 *          * Encrypted-balance accumulator with monotonic per-recipient
 *            claim nonces.
 *          * MPC `checkedSub` enforces encrypted-balance non-underflow.
 *      - Privacy disclosure (M-02, M-04 acknowledged):
 *          * `assetId`, `isBuy`, `oraclePrice`, and `block.timestamp`
 *            are public per trade. The encrypted-quantity privacy
 *            guarantee is therefore "the magnitude of the user's
 *            traded quantity is private" — NOT "the trade is private".
 *          * A failed `_debitXom` / `_debitRwa` reverts via MPC
 *            underflow; an observer who can force a target to sign
 *            multiple probe intents could binary-search the encrypted
 *            balance via revert pattern. Mitigated by the
 *            `MAX_TRADE_DEADLINE` window (1 h) and the per-trader
 *            EIP-712 nonce monotonicity, which together require a
 *            signed-and-fresh intent for every probe.
 *          * Dust trades that round to zero notional are rejected via
 *            an explicit MPC `gt(notional, 0)` decrypt (audit M-01
 *            fix). The 1-bit leak per trade is the canonical
 *            privacy-vs-correctness tradeoff (same as the tier-check
 *            leak in PrivateYieldVault).
 */
contract PrivateRWAAMM is
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

    /**
     * @notice Per-asset on-chain configuration.
     * @dev `priceFeed` is a Chainlink-compatible aggregator. Asset is
     *      tradable iff `enabled == true` AND a non-zero feed is wired.
     *      `priceFeedDecimals` is auto-derived at confirm time from
     *      `IAggregatorV3.decimals()` (audit H-04 fix — never trust
     *      admin-supplied decimals).
     */
    struct AssetConfig {
        address priceFeed;
        uint64 tradeFeeBps;
        uint32 maxPriceStaleness; // seconds; MUST be > 0 (audit H-03)
        uint8 priceFeedDecimals;  // auto-derived in confirmAssetUpdate
        bool enabled;
    }

    /**
     * @notice Pending timelocked update for an asset registration.
     * @dev Zero `effectiveAt` = no pending update. Keyed by `assetId`
     *      so multiple assets can be queued in parallel
     *      (audit M-06 fix).
     */
    struct PendingAsset {
        AssetConfig config;
        uint256 effectiveAt;
    }

    /**
     * @notice Pending timelocked UUPS implementation upgrade.
     * @dev Zero `effectiveAt` = no pending upgrade. Audit H-05 fix —
     *      adds a 48 h delay to the UUPS upgrade authority so users
     *      have a grace window to detect a malicious implementation
     *      swap before it becomes live.
     */
    struct PendingUpgrade {
        address newImplementation;
        uint256 effectiveAt;
    }

    /**
     * @notice Pending timelocked update for the trusted forwarder.
     */
    struct PendingForwarder {
        address forwarder;
        uint256 effectiveAt;
    }

    /**
     * @notice Pending timelocked update for the fee recipient.
     */
    struct PendingFeeRecipient {
        address recipient;
        uint256 effectiveAt;
    }

    // ========================================================================
    // CONSTANTS
    // ========================================================================

    /// @notice Role for the relayer (validator gateway).
    bytes32 public constant RELAYER_ROLE = keccak256("RELAYER_ROLE");

    /// @notice Role for escrow oracles (audit H-01 fix). An ESCROW_ORACLE_ROLE
    /// holder co-signs every `deposit` to attest that an off-chain escrow
    /// proof anchors the encrypted credit; without this co-signature the
    /// relayer alone could fabricate balances.
    bytes32 public constant ESCROW_ORACLE_ROLE =
        keccak256("ESCROW_ORACLE_ROLE");

    /// @notice Basis-points divisor (100 %).
    uint256 public constant BASIS_POINTS_DIVISOR = 10_000;

    /// @notice Maximum trade fee admin can set (1 %, audit M-05 fix).
    uint64 public constant MAX_TRADE_FEE_BPS = 100;

    /// @notice Default trade fee (0.30 %).
    uint64 public constant DEFAULT_TRADE_FEE_BPS = 30;

    /// @notice Maximum allowed slippage between committed + live price (1 %).
    uint64 public constant MAX_SLIPPAGE_BPS = 100;

    /// @notice Maximum trade-deadline window (audit H-02 fix). Trader
    /// signatures cannot outlive the price-feed timelock window —
    /// caps deadline at `block.timestamp + 1 hour`.
    uint256 public constant MAX_TRADE_DEADLINE = 1 hours;

    /// @notice Deposit-deadline ceiling — same 1h shape as trade. Audit
    ///         Pass-3 M-01 mitigation: bounds how far in the future a
    ///         pre-signed deposit can still execute.
    uint256 public constant MAX_DEPOSIT_DEADLINE = 1 hours;

    /// @notice Maximum allowed `maxPriceStaleness` per asset (audit H-03).
    uint32 public constant MAX_PRICE_STALENESS = 1 days;

    /// @notice 18-decimal canonical scale (matches XOM token).
    uint256 public constant CANONICAL_DECIMALS = 18;

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

    /// @notice EIP-712 typehash for the trader's trade-intent.
    /// @dev `priceFeed` binding (audit H-02 fix) prevents an admin
    ///      feed-rotation from settling a stale-but-still-valid intent
    ///      against a different oracle than the one the trader saw.
    // solhint-disable-next-line gas-small-strings, max-line-length
    bytes32 private constant TRADE_INTENT_TYPEHASH = keccak256("TradeIntent(bytes32 tradeId,address trader,bytes32 assetId,address priceFeed,bool isBuy,bytes32 quantityCommit,uint256 oraclePriceCommit,uint256 nonce,uint256 deadline)");

    /// @notice EIP-712 typehash for the trader's deposit-intent.
    /// @dev `escrowProof` binding (audit H-01 fix) ties the encrypted
    ///      accumulator credit to a specific off-chain escrow attestation.
    // solhint-disable-next-line gas-small-strings, max-line-length
    bytes32 private constant DEPOSIT_INTENT_TYPEHASH = keccak256("DepositIntent(bytes32 depositId,address trader,bytes32 assetId,bytes32 amountCommit,bytes32 escrowProof,uint256 nonce,uint256 deadline)");

    /// @notice EIP-712 typehash for the escrow oracle's attestation.
    /// @dev Audit H-01 fix — a separate ESCROW_ORACLE_ROLE-holder
    ///      signs this attestation to confirm the off-chain escrow
    ///      lock has been verified before the encrypted accumulator
    ///      is credited.
    // solhint-disable-next-line gas-small-strings, max-line-length
    /// @dev Audit 2026-05-27: bind `nonce` and `deadline` so the
    ///      oracle's `EscrowAttestation` co-signs the EXACT same
    ///      tuple as the trader's `DepositIntent`. Mirrors the
    ///      PrivatePredictionMarket fix; closes the same
    ///      relayer-side replay window against a different
    ///      in-flight deposit by the same trader.
    bytes32 private constant ESCROW_ATTESTATION_TYPEHASH = keccak256("EscrowAttestation(bytes32 depositId,address trader,bytes32 assetId,bytes32 amountCommit,bytes32 escrowProof,uint256 nonce,uint256 deadline)");

    // ========================================================================
    // STATE VARIABLES
    // ========================================================================

    /// @notice assetId → public asset configuration.
    mapping(bytes32 assetId => AssetConfig cfg) public assetConfigs;

    /// @notice address → next-expected nonce for `TradeIntent` signatures.
    mapping(address trader => uint256 nonce) public nonces;

    /// @notice address → encrypted XOM-side balance (claimable).
    mapping(address holder => ctUint256 balance) private encXomBalance;

    /// @notice address → assetId → encrypted RWA balance (claimable).
    mapping(address holder => mapping(bytes32 assetId => ctUint256 balance))
        private encRwaBalance;

    /// @notice address → has a non-zero XOM accumulator pending claim.
    mapping(address holder => bool flagged) private _hasUnclaimedXom;

    /// @notice address → assetId → has a non-zero RWA accumulator.
    mapping(address holder => mapping(bytes32 assetId => bool flagged))
        private _hasUnclaimedRwa;

    /// @notice address → monotonic per-recipient claim nonce (XOM side).
    mapping(address holder => uint256 claimNonce) public xomClaimNonces;

    /// @notice address → assetId → monotonic per-recipient RWA claim nonce.
    mapping(address holder => mapping(bytes32 assetId => uint256 claimNonce))
        public rwaClaimNonces;

    /// @notice tradeId → seen flag (replay protection at the trade-id layer).
    mapping(bytes32 tradeId => bool seen) private seenTradeIds;

    /// @notice depositId → seen flag (replay protection at the deposit-id layer).
    mapping(bytes32 depositId => bool seen) private seenDepositIds;

    /// @notice Recipient of trade-fee accumulator. Configurable + timelocked.
    address public feeRecipient;

    /// @notice ERC-2771 trusted forwarder (proxy storage — audit H-06).
    address public trustedForwarder;

    /// @notice Total lifetime trades (counter).
    uint256 private totalTrades;

    /// @notice True once the contract is permanently non-upgradable.
    bool private _ossified;

    /// @notice Block timestamp when ossification was requested (0 = none).
    uint256 public ossificationRequestTime;

    /// @notice assetId → pending asset-config update (timelocked).
    /// @dev Mapping-keyed so multiple assets can be queued in parallel
    ///      (audit M-06 fix).
    mapping(bytes32 assetId => PendingAsset pending) private pendingAssetById;

    /// @notice Pending forwarder update (timelocked).
    PendingForwarder private pendingForwarder;

    /// @notice Pending fee-recipient update (timelocked).
    PendingFeeRecipient private pendingFeeRecipient;

    /// @notice Pending UUPS implementation upgrade (timelocked, audit H-05).
    PendingUpgrade public pendingUpgrade;

    /// @notice Pluggable committee-attestation verifier for the
    ///         random-committee paths ({tradeWithCommittee} +
    ///         {depositWithCommittee}). Wires directly to a
    ///         `RandomCommitteeVerifier` instance — the privacy
    ///         contracts manage their own per-trader nonces, so no
    ///         `OmniAttestationGateway` nonce-consumption indirection
    ///         is required. Per
    ///         `memory/decision_privacy_roles_random_committee_2026-05-27.md`
    ///         the committee path replaces BOTH the static
    ///         `RELAYER_ROLE` allowlist AND (for deposits) the
    ///         `ESCROW_ORACLE_ROLE` co-signature — committee members
    ///         independently verify the off-chain `escrowProof` and
    ///         their threshold signature is the attestation. Zero
    ///         address = committee path disabled (legacy paths still
    ///         work).
    IBridgeVerifier public attestationVerifier;

    /// @dev Storage gap for proxy-safe future-state additions.
    /// @dev Reserved 40 originally; shrunk to 38 to account for the
    ///      `pendingUpgrade` slot pair added by the audit H-05 remediation.
    ///      The `pendingAssetById` mapping replaces the old
    ///      `pendingAsset` singleton (no net slot change — both occupy
    ///      a single mapping/struct slot at the same layout position).
    ///      Further shrunk to 37 for the random-committee
    ///      `attestationVerifier` slot.
    uint256[37] private __gap;

    // ========================================================================
    // EVENTS
    // ========================================================================

    /**
     * @notice Emitted when admin queues an asset registration / update.
     * @param assetId Asset identifier.
     * @param effectiveAt Unix-seconds at which it can be applied.
     */
    event AssetUpdateQueued(bytes32 indexed assetId, uint256 effectiveAt);

    /**
     * @notice Emitted when the queued asset update is applied.
     * @param assetId Asset identifier.
     * @param priceFeed New price feed.
     * @param tradeFeeBps New trade-fee bps.
     * @param enabled New enabled flag.
     */
    event AssetUpdated(
        bytes32 indexed assetId,
        address indexed priceFeed,
        uint64 tradeFeeBps,
        bool enabled
    );

    /**
     * @notice Emitted when the trader deposits into the XOM accumulator.
     * @param depositId Deposit identifier.
     * @param trader Trader EOA.
     * @param assetId Asset identifier (`bytes32(0)` for XOM-side).
     */
    event Deposited(
        bytes32 indexed depositId,
        address indexed trader,
        bytes32 indexed assetId
    );

    /**
     * @notice Emitted on a successful trade.
     * @param tradeId Trade identifier.
     * @param trader Trader EOA.
     * @param assetId Asset identifier.
     * @param isBuy True for buy, false for sell.
     * @param oraclePrice Oracle answer used for settlement (18-decimal scaled).
     */
    event TradeSettled(
        bytes32 indexed tradeId,
        address indexed trader,
        bytes32 indexed assetId,
        bool isBuy,
        uint256 oraclePrice
    );

    /**
     * @notice Emitted when a recipient claims their XOM accumulator.
     * @param recipient Claiming address.
     * @param claimNonce Per-recipient monotonic nonce.
     * @param ciphertextHigh Pre-reset ciphertext high half.
     * @param ciphertextLow Pre-reset ciphertext low half.
     */
    event XomClaimed(
        address indexed recipient,
        uint256 indexed claimNonce,
        uint256 ciphertextHigh,
        uint256 ciphertextLow
    );

    /**
     * @notice Emitted when a recipient claims their per-asset RWA accumulator.
     * @param recipient Claiming address.
     * @param assetId Asset identifier.
     * @param claimNonce Per-recipient + per-asset monotonic nonce.
     * @param ciphertextHigh Pre-reset ciphertext high half.
     * @param ciphertextLow Pre-reset ciphertext low half.
     */
    event RwaClaimed(
        address indexed recipient,
        bytes32 indexed assetId,
        uint256 indexed claimNonce,
        uint256 ciphertextHigh,
        uint256 ciphertextLow
    );

    /**
     * @notice Emitted when admin queues a forwarder update.
     * @param forwarder Pending forwarder.
     * @param effectiveAt Unix-seconds at which it can be applied.
     */
    event TrustedForwarderUpdateQueued(
        address indexed forwarder,
        uint256 effectiveAt
    );

    /**
     * @notice Emitted when the queued forwarder update is applied.
     * @param oldForwarder Previous forwarder.
     * @param newForwarder New forwarder.
     */
    event TrustedForwarderUpdated(
        address indexed oldForwarder,
        address indexed newForwarder
    );

    /**
     * @notice Emitted when admin queues a fee-recipient update.
     * @param recipient Pending fee recipient.
     * @param effectiveAt Unix-seconds at which it can be applied.
     */
    event FeeRecipientUpdateQueued(
        address indexed recipient,
        uint256 effectiveAt
    );

    /**
     * @notice Emitted when the queued fee-recipient update is applied.
     * @param oldRecipient Previous recipient.
     * @param newRecipient New recipient.
     */
    event FeeRecipientUpdated(
        address indexed oldRecipient,
        address indexed newRecipient
    );

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
    event OssificationRequested(
        address indexed contractAddress,
        uint256 indexed requestTime
    );

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
    event ContractOssified(
        address indexed contractAddress,
        uint256 indexed confirmTime
    );

    /**
     * @notice Emitted when admin queues a UUPS implementation upgrade.
     * @param newImplementation Pending implementation address.
     * @param effectiveAt Unix-seconds at which it can be applied.
     */
    event UpgradeQueued(
        address indexed newImplementation,
        uint256 effectiveAt
    );

    /**
     * @notice Emitted when admin cancels a pending upgrade.
     * @param newImplementation Cancelled implementation address.
     */
    event UpgradeCancelled(address indexed newImplementation);

    /**
     * @notice Emitted when admin (re)points the random-committee
     *         attestation verifier used by {tradeWithCommittee} and
     *         {depositWithCommittee}.
     * @param verifier New verifier; zero address disables both
     *         committee paths (legacy {trade} and {deposit} entries
     *         remain functional).
     */
    event AttestationVerifierSet(IBridgeVerifier indexed verifier);

    /**
     * @notice Emitted when a trade settles via the committee
     *         attestation path. Companion to {TradeSettled};
     *         persists the attester list so off-chain slashing
     *         pipelines can recover it after the 256-block
     *         blockhash window expires.
     * @param tradeId Trade identifier.
     * @param attesters Sorted, deduplicated list of validator
     *        attesters whose signatures satisfied the committee
     *        quorum.
     */
    event TradeCommitteeAttested(
        bytes32 indexed tradeId,
        address[] attesters
    );

    /**
     * @notice Emitted when a deposit settles via the committee
     *         attestation path. Companion to {Deposited}; the
     *         attester list replaces the legacy single
     *         `ESCROW_ORACLE_ROLE` attestor — every committee
     *         member independently verified the off-chain
     *         `escrowProof` before signing.
     * @param depositId Deposit identifier.
     * @param attesters Sorted, deduplicated list of validator
     *        attesters whose signatures satisfied the committee
     *        quorum.
     */
    event DepositCommitteeAttested(
        bytes32 indexed depositId,
        address[] attesters
    );

    // ========================================================================
    // CUSTOM ERRORS
    // ========================================================================

    error InvalidAddress();
    error UnsupportedChain(uint256 chainId);
    error InvalidNonce();
    error InvalidSignature();
    error InvalidEscrowAttestation();
    error DeadlineExpired();
    error DeadlineTooFar();
    error AssetNotEnabled();
    error AssetAlreadyConfigured();
    error InvalidPriceFeed();
    error InvalidPriceFeedDecimals();
    error StalePrice();
    error InvalidPrice();
    error InvalidStaleness();
    error SlippageExceeded();
    error PriceFeedMismatch();
    error TradeFeeTooHigh();
    error TradeIdAlreadyUsed();
    error DepositIdAlreadyUsed();
    error ZeroNotional();
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
     * @param admin Admin (DEFAULT_ADMIN_ROLE).
     * @param relayers Initial RELAYER_ROLE holders.
     * @param escrowOracles Initial ESCROW_ORACLE_ROLE holders. Each
     *        must co-sign a `deposit` (audit H-01 fix). May be empty
     *        at init; admin grants later. While empty, `deposit`
     *        reverts.
     * @param trustedForwarder_ ERC-2771 forwarder; `address(0)` to disable.
     * @param feeRecipient_ Recipient of trade-fee accumulator. Must be
     *        non-zero AND not `address(this)` (audit M-02 fix carried
     *        forward from PrivateYieldVault).
     */
    function initialize( // solhint-disable-line code-complexity
        address admin,
        address[] calldata relayers,
        address[] calldata escrowOracles,
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
        __EIP712_init("OmniBazaar PrivateRWAAMM", "1");

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        for (uint256 i = 0; i < relayers.length; ++i) {
            address r = relayers[i];
            if (r == address(0)) revert InvalidAddress();
            _grantRole(RELAYER_ROLE, r);
        }
        for (uint256 i = 0; i < escrowOracles.length; ++i) {
            address o = escrowOracles[i];
            if (o == address(0)) revert InvalidAddress();
            _grantRole(ESCROW_ORACLE_ROLE, o);
        }

        trustedForwarder = trustedForwarder_;
        feeRecipient = feeRecipient_;
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
    // EXTERNAL — DEPOSITS (encrypted accumulator credit)
    // ========================================================================

    /**
     * @notice Credit an encrypted balance into the trader's accumulator.
     * @dev Called by an authorized RELAYER with the trader's EIP-712
     *      signature AND a separate ESCROW_ORACLE_ROLE attestation
     *      signature (audit H-01 fix). The trader's intent binds the
     *      `escrowProof` value; the oracle's attestation co-signs the
     *      same `escrowProof`. Without both signatures the relayer
     *      cannot fabricate balances — the oracle's role is to verify
     *      off-chain that the bridge / public-chain escrow lock
     *      corresponding to `escrowProof` actually exists before
     *      issuing its attestation.
     *
     *      The on-chain contract does NOT verify the escrowProof
     *      itself (that's the oracle's job — it could be a Merkle
     *      proof of an L1 lock, an AWM message hash, or any commitment
     *      scheme the bridge supports). The contract's invariant is
     *      "no encrypted credit without two-of-two role-based signatures
     *      attesting to the off-chain escrow."
     * @param depositId Unique 32-byte deposit identifier.
     * @param trader Trader EOA.
     * @param assetId `bytes32(0)` for XOM, otherwise a registered RWA id.
     * @param encAmount Encrypted amount (ctUint256).
     * @param escrowProof Off-chain escrow attestation hash (e.g., Merkle
     *        root + leaf-proof commitment). Bound in both signatures.
     * @param traderNonce Expected trader nonce (replay protection).
     * @param deadline Unix-seconds deadline.
     * @param traderSignature Trader's EIP-712 signature over `DepositIntent`.
     * @param oracleAttestor Address of the ESCROW_ORACLE_ROLE-holding
     *        attestor whose signature is provided. Must hold the role
     *        at call time.
     * @param oracleSignature Oracle's EIP-712 signature over
     *        `EscrowAttestation`.
     */
    function deposit(
        bytes32 depositId,
        address trader,
        bytes32 assetId,
        ctUint256 calldata encAmount,
        bytes32 escrowProof,
        uint256 traderNonce,
        uint256 deadline,
        bytes calldata traderSignature,
        address oracleAttestor,
        bytes calldata oracleSignature
    ) external onlyRole(RELAYER_ROLE) whenNotPaused nonReentrant {
        if (!hasRole(ESCROW_ORACLE_ROLE, oracleAttestor)) {
            revert InvalidEscrowAttestation();
        }

        bytes32 amountCommit = _commit(encAmount);
        // Audit 2026-05-27: bind nonce + deadline (see typehash
        // NatSpec). Closes relayer-side replay window.
        bytes32 attestationHash = keccak256(
            abi.encode(
                ESCROW_ATTESTATION_TYPEHASH,
                depositId,
                trader,
                assetId,
                amountCommit,
                escrowProof,
                traderNonce,
                deadline
            )
        );
        bytes32 attestationDigest = _hashTypedDataV4(attestationHash);
        if (
            ECDSA.recover(attestationDigest, oracleSignature) != oracleAttestor
        ) {
            revert InvalidEscrowAttestation();
        }

        _executeDeposit(
            depositId,
            trader,
            assetId,
            encAmount,
            MpcCore.onBoard(encAmount),
            escrowProof,
            traderNonce,
            deadline,
            traderSignature
        );
    }

    /**
     * @notice Credit an encrypted balance into the trader's
     *         accumulator — committee attestation path.
     * @dev Replaces BOTH the static `RELAYER_ROLE` gate AND the
     *      single `ESCROW_ORACLE_ROLE` co-signature with a random
     *      M-of-N validator committee. Each committee member runs
     *      their own off-chain escrow-proof verifier (Merkle
     *      inclusion against the L1 lock event) and signs the
     *      `DepositIntent` digest independently. The committee
     *      threshold quorum collectively replaces the legacy single
     *      oracle's attestation.
     *
     *      Caller authorisation: anyone may submit — the trader's
     *      EIP-712 signature + the committee's ≥M signatures carry
     *      every authorisation needed.
     *
     *      The trader (subject) MUST NOT appear in the committee
     *      attester list (Phase 2 audit Pass-1 C-2 fix).
     *
     *      Emits {DepositCommitteeAttested} with the attester list
     *      for off-chain slashing recovery.
     * @param depositId Unique deposit identifier.
     * @param trader Trader EOA.
     * @param assetId `bytes32(0)` for XOM, otherwise a registered RWA id.
     * @param encAmount Encrypted amount (ctUint256).
     * @param escrowProof Off-chain escrow attestation hash bound in
     *        the trader signature (the committee independently
     *        verified its validity off-chain).
     * @param traderNonce Expected trader nonce.
     * @param deadline Unix-seconds deadline.
     * @param traderSignature Trader's EIP-712 signature over `DepositIntent`.
     * @param committeeProof Verifier-specific opaque blob containing
     *        the M-of-N committee signatures over the same
     *        `DepositIntent` digest as {traderSignature}.
     */
    function depositWithCommittee(
        bytes32 depositId,
        address trader,
        bytes32 assetId,
        itUint256 calldata encAmount,
        bytes32 escrowProof,
        uint256 traderNonce,
        uint256 deadline,
        bytes calldata traderSignature,
        bytes calldata committeeProof
    ) external whenNotPaused nonReentrant {
        // Audit Pass-3 H-01 — fast-reject BEFORE the expensive
        // _verifyCommittee call. Defense-in-depth: _executeDeposit
        // re-checks too.
        // solhint-disable-next-line not-rely-on-time, gas-strict-inequalities
        if (deadline <= block.timestamp) revert DeadlineExpired();
        if (seenDepositIds[depositId]) revert DepositIdAlreadyUsed();
        if (nonces[trader] != traderNonce) revert InvalidNonce();

        bytes32 digest = _depositIntentDigest(
            depositId,
            trader,
            assetId,
            encAmount.ciphertext,
            escrowProof,
            traderNonce,
            deadline
        );
        (bool valid, address[] memory attesters) =
            _verifyCommittee(digest, committeeProof);
        if (!valid) revert InvalidCommitteeAttestation();

        uint256 attesterCount = attesters.length;
        if (attesterCount == 0) revert InvalidCommitteeAttestation();
        for (uint256 i = 0; i < attesterCount; ) {
            if (attesters[i] == trader) revert SubjectInCommittee();
            unchecked {
                ++i;
            }
        }

        emit DepositCommitteeAttested(depositId, attesters);

        // Validate the client input (itUint256) — binds to msg.sender, so the
        // trader must self-broadcast this committee tx (same model as the DEX
        // lock + stake). The raw ciphertext stays for the digest.
        _executeDeposit(
            depositId,
            trader,
            assetId,
            encAmount.ciphertext,
            MpcCore.validateCiphertext(encAmount),
            escrowProof,
            traderNonce,
            deadline,
            traderSignature
        );
    }

    // ========================================================================
    // EXTERNAL — TRADE
    // ========================================================================

    /**
     * @notice Settle an encrypted-quantity buy or sell against a
     *         registered RWA asset, priced at the live oracle answer.
     * @dev Called by an authorized RELAYER. The trader's EIP-712
     *      signature binds the tradeId, asset, direction, `quantityCommit`,
     *      committed oracle price, nonce, and deadline.
     *
     *      Settlement math (all on encrypted quantities, public price):
     *        notional      = quantity × price (private × public)
     *        feeAmt        = notional × tradeFeeBps / BASIS_POINTS_DIVISOR
     *        notionalAfter = notional - feeAmt
     *      Buy:  encXomBalance[trader] -= notional;
     *            encRwaBalance[trader][asset] += quantity;
     *            encXomBalance[feeRecipient] += feeAmt.
     *      Sell: encRwaBalance[trader][asset] -= quantity;
     *            encXomBalance[trader] += notionalAfter;
     *            encXomBalance[feeRecipient] += feeAmt.
     *
     *      The trader's signed `oraclePriceCommit` is checked against
     *      the live oracle answer and reverts unless within
     *      MAX_SLIPPAGE_BPS (1 %). This bounds protocol-side price
     *      manipulation while still using the live answer for settlement.
     * @param tradeId Unique 32-byte trade identifier.
     * @param trader Trader EOA.
     * @param assetId Registered RWA asset.
     * @param isBuy True for buy, false for sell.
     * @param encQuantity Encrypted RWA quantity (ctUint256).
     * @param oraclePriceCommit Trader's signed oracle-price expectation
     *        (18-dec scaled).
     * @param traderNonce Expected trader nonce.
     * @param deadline Unix-seconds deadline.
     * @param traderSignature EIP-712 signature.
     */
    function trade(
        bytes32 tradeId,
        address trader,
        bytes32 assetId,
        bool isBuy,
        ctUint256 calldata encQuantity,
        uint256 oraclePriceCommit,
        uint256 traderNonce,
        uint256 deadline,
        bytes calldata traderSignature
    ) external onlyRole(RELAYER_ROLE) whenNotPaused nonReentrant {
        _executeTrade(
            tradeId,
            trader,
            assetId,
            isBuy,
            encQuantity,
            MpcCore.onBoard(encQuantity),
            oraclePriceCommit,
            traderNonce,
            deadline,
            traderSignature
        );
    }

    /**
     * @notice Settle an encrypted-quantity trade — committee
     *         attestation path.
     * @dev Replaces the static `RELAYER_ROLE` gate with a random
     *      M-of-N validator committee. Both gates verify the same
     *      `TradeIntent` EIP-712 digest: trader's signature + the
     *      committee's ≥M signatures.
     *
     *      Caller authorisation: anyone may submit. Subject ∉
     *      committee invariant enforced.
     *
     *      Emits {TradeCommitteeAttested} with the attester list.
     * @param tradeId Unique trade identifier.
     * @param trader Trader EOA.
     * @param assetId Registered RWA asset.
     * @param isBuy True for buy, false for sell.
     * @param encQuantity Encrypted RWA quantity (ctUint256).
     * @param oraclePriceCommit Trader's signed oracle-price expectation.
     * @param traderNonce Expected trader nonce.
     * @param deadline Unix-seconds deadline.
     * @param traderSignature EIP-712 signature.
     * @param committeeProof Verifier-specific opaque blob containing
     *        the M-of-N committee signatures over the same
     *        `TradeIntent` digest as {traderSignature}.
     */
    function tradeWithCommittee(
        bytes32 tradeId,
        address trader,
        bytes32 assetId,
        bool isBuy,
        itUint256 calldata encQuantity,
        uint256 oraclePriceCommit,
        uint256 traderNonce,
        uint256 deadline,
        bytes calldata traderSignature,
        bytes calldata committeeProof
    ) external whenNotPaused nonReentrant {
        // Audit Pass-3 H-01 — fast-reject BEFORE the expensive
        // _verifyCommittee call. Defense-in-depth: _executeTrade
        // re-checks too.
        // solhint-disable-next-line not-rely-on-time, gas-strict-inequalities
        if (deadline <= block.timestamp) revert DeadlineExpired();
        if (seenTradeIds[tradeId]) revert TradeIdAlreadyUsed();
        if (nonces[trader] != traderNonce) revert InvalidNonce();

        AssetConfig memory cfg = assetConfigs[assetId];
        if (!cfg.enabled) revert AssetNotEnabled();

        bytes32 digest = _tradeIntentDigest(
            tradeId,
            trader,
            assetId,
            cfg.priceFeed,
            isBuy,
            encQuantity.ciphertext,
            oraclePriceCommit,
            traderNonce,
            deadline
        );
        (bool valid, address[] memory attesters) =
            _verifyCommittee(digest, committeeProof);
        if (!valid) revert InvalidCommitteeAttestation();

        uint256 attesterCount = attesters.length;
        if (attesterCount == 0) revert InvalidCommitteeAttestation();
        for (uint256 i = 0; i < attesterCount; ) {
            if (attesters[i] == trader) revert SubjectInCommittee();
            unchecked {
                ++i;
            }
        }

        emit TradeCommitteeAttested(tradeId, attesters);

        // Validate the client input (itUint256) — binds to msg.sender, so the
        // trader must self-broadcast this committee tx (same model as the DEX
        // lock + stake). The raw ciphertext stays for the digest.
        _executeTrade(
            tradeId,
            trader,
            assetId,
            isBuy,
            encQuantity.ciphertext,
            MpcCore.validateCiphertext(encQuantity),
            oraclePriceCommit,
            traderNonce,
            deadline,
            traderSignature
        );
    }

    /**
     * @notice Claim accumulated encrypted XOM-side balance.
     * @dev Snapshots the pre-reset ciphertext into the event payload
     *      and increments the per-recipient `xomClaimNonces`. NOT gated
     *      by `whenNotPaused` (user escape path).
     *
     *      Uses raw `msg.sender` instead of `_msgSender()` (audit M-07
     *      fix) so a malicious or compromised ERC-2771 forwarder cannot
     *      forge a sender to drain another holder's accumulator.
     */
    function claimXom() external nonReentrant {
        address claimant = msg.sender;
        if (!_hasUnclaimedXom[claimant]) revert NoBalanceToClaim();

        ctUint256 memory snapshot = encXomBalance[claimant];
        ctUint256 memory zeroCt = MpcCore.offBoard(MpcCore.setPublic256(0));
        encXomBalance[claimant] = zeroCt;
        _hasUnclaimedXom[claimant] = false;

        uint256 nonce = ++xomClaimNonces[claimant];
        emit XomClaimed(
            claimant,
            nonce,
            ctUint128.unwrap(snapshot.ciphertextHigh),
            ctUint128.unwrap(snapshot.ciphertextLow)
        );
    }

    /**
     * @notice Claim accumulated encrypted RWA-side balance for a given asset.
     * @dev Uses raw `msg.sender` (audit M-07 fix). See {claimXom}.
     * @param assetId Registered RWA asset.
     */
    function claimRwa(bytes32 assetId) external nonReentrant {
        address claimant = msg.sender;
        if (!_hasUnclaimedRwa[claimant][assetId]) revert NoBalanceToClaim();

        ctUint256 memory snapshot = encRwaBalance[claimant][assetId];
        ctUint256 memory zeroCt = MpcCore.offBoard(MpcCore.setPublic256(0));
        encRwaBalance[claimant][assetId] = zeroCt;
        _hasUnclaimedRwa[claimant][assetId] = false;

        uint256 nonce = ++rwaClaimNonces[claimant][assetId];
        emit RwaClaimed(
            claimant,
            assetId,
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
     *         {tradeWithCommittee} and {depositWithCommittee}.
     * @dev Pioneer Phase admin model (per
     *      `memory/feedback_no_builtin_timelocks.md`): deployer-direct,
     *      zero delay. The existing timelocked setters on this contract
     *      (`requestFeeRecipient`, `requestAssetUpdate`, etc.) predate
     *      the rule clarification and are documented gaps; new admin
     *      setters follow the zero-delay pattern. Once Pioneer ends,
     *      `DEFAULT_ADMIN_ROLE` transitions to `OmniTimelockController`
     *      + governance and the 7-day delay applies to the admin
     *      transfer itself, not to per-setter built-in delays.
     *
     *      Setting `address(0)` is rejected; to disable the committee
     *      paths without unsetting the slot, set a verifier whose
     *      `quorumThreshold()` exceeds the eligible pool.
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
     * @notice Queue an asset registration / update.
     * @dev `priceFeedDecimals` is ignored — auto-derived in
     *      {confirmAssetUpdate} from `IAggregatorV3.decimals()` (audit
     *      H-04 fix). `maxPriceStaleness` MUST be > 0 and ≤
     *      {MAX_PRICE_STALENESS} (audit H-03 fix).
     * @param assetId Asset identifier (caller-chosen 32-byte tag).
     * @param cfg Full asset configuration. `tradeFeeBps` capped at
     *        {MAX_TRADE_FEE_BPS}; `priceFeed` must be non-zero.
     */
    function requestAssetUpdate(bytes32 assetId, AssetConfig calldata cfg)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (cfg.priceFeed == address(0)) revert InvalidPriceFeed();
        if (cfg.tradeFeeBps > MAX_TRADE_FEE_BPS) revert TradeFeeTooHigh();
        if (
            cfg.maxPriceStaleness == 0
                // solhint-disable-next-line gas-strict-inequalities
                || cfg.maxPriceStaleness > MAX_PRICE_STALENESS
        ) {
            revert InvalidStaleness();
        }
        if (pendingAssetById[assetId].effectiveAt != 0) {
            revert TimelockAlreadyRequested();
        }
        // solhint-disable-next-line not-rely-on-time
        uint256 effectiveAt = block.timestamp + TIMELOCK_DELAY;
        pendingAssetById[assetId] = PendingAsset({
            config: cfg,
            effectiveAt: effectiveAt
        });
        emit AssetUpdateQueued(assetId, effectiveAt);
    }

    /**
     * @notice Apply the queued asset update.
     * @dev Reads the live feed's `decimals()` and writes it into the
     *      stored config (audit H-04 fix — never trust the admin-supplied
     *      `priceFeedDecimals`). A misconfigured feed reverts here.
     * @param assetId Asset identifier whose pending update to confirm.
     */
    function confirmAssetUpdate(bytes32 assetId)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        PendingAsset memory pending = pendingAssetById[assetId];
        if (pending.effectiveAt == 0) revert TimelockNotRequested();
        // solhint-disable-next-line not-rely-on-time, gas-strict-inequalities
        if (block.timestamp < pending.effectiveAt) {
            revert TimelockDelayNotElapsed();
        }
        // Read decimals from the live feed and override.
        uint8 liveDecimals = IAggregatorV3(pending.config.priceFeed).decimals();
        // solhint-disable-next-line gas-strict-inequalities
        if (liveDecimals > 36) revert InvalidPriceFeedDecimals();
        pending.config.priceFeedDecimals = liveDecimals;
        assetConfigs[assetId] = pending.config;
        delete pendingAssetById[assetId];
        emit AssetUpdated(
            assetId,
            pending.config.priceFeed,
            pending.config.tradeFeeBps,
            pending.config.enabled
        );
    }

    /**
     * @notice Cancel the queued asset update.
     * @param assetId Asset identifier whose pending update to cancel.
     */
    function cancelPendingAssetUpdate(bytes32 assetId)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (pendingAssetById[assetId].effectiveAt == 0) {
            revert TimelockNotRequested();
        }
        delete pendingAssetById[assetId];
        emit PendingUpdateCancelled("asset");
    }

    /**
     * @notice Queue a trusted-forwarder update.
     * @param newForwarder New ERC-2771 forwarder; `address(0)` to disable.
     */
    function requestTrustedForwarderUpdate(address newForwarder)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (pendingForwarder.effectiveAt != 0) {
            revert TimelockAlreadyRequested();
        }
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
        if (block.timestamp < pending.effectiveAt) {
            revert TimelockDelayNotElapsed();
        }
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
     *      as `initialize` (fee accumulator must be a claimable
     *      recipient). PrivateYieldVault audit M-02 fix carried forward.
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

    /// @notice Pause new trades + deposits. Claim still works.
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
     * @notice Queue a UUPS implementation upgrade (audit H-05 fix).
     * @dev Adds a 48 h grace window between request and execution so
     *      users can detect a malicious-implementation swap before it
     *      becomes live.
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
     *      (audit H-05 fix). The caller must (a) hold DEFAULT_ADMIN_ROLE,
     *      (b) have queued THIS exact `newImplementation` via
     *      `requestUpgrade`, and (c) wait until `effectiveAt`. The
     *      pending entry is cleared on successful upgrade so it cannot
     *      be replayed.
     *
     *      State mutation in a `_authorizeUpgrade` override is required
     *      here (clearing `pendingUpgrade`) so the function is
     *      non-`view` — diverges from the OZ default but is a documented
     *      pattern for timelocked UUPS upgrades.
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
        return (msg.sender == trustedForwarder && msg.data.length >= 20)
            ? 20
            : 0;
    }

    /**
     * @notice Common deposit-execution body shared by {deposit} and
     *         {depositWithCommittee}. Internal helper.
     * @dev Verifies the trader's EIP-712 signature, enforces nonce +
     *      deadline + asset-enabled invariants, and credits the
     *      encrypted accumulator. Caller owns relayer or committee
     *      authorisation; for the legacy {deposit} path the caller
     *      additionally verifies the `ESCROW_ORACLE_ROLE`
     *      co-signature before calling here.
     * @param depositId Unique deposit identifier.
     * @param trader Trader EOA.
     * @param assetId `bytes32(0)` for XOM, otherwise a registered RWA id.
     * @param encAmount Encrypted amount (ctUint256).
     * @param escrowProof Off-chain escrow attestation hash (verified
     *        off-chain by the caller's role / committee).
     * @param traderNonce Expected trader nonce.
     * @param deadline Unix-seconds deadline.
     * @param traderSignature Trader's EIP-712 signature over `DepositIntent`.
     */
    function _executeDeposit(
        bytes32 depositId,
        address trader,
        bytes32 assetId,
        ctUint256 calldata encAmount,
        gtUint256 amountG,
        bytes32 escrowProof,
        uint256 traderNonce,
        uint256 deadline,
        bytes calldata traderSignature
    ) private {
        if (trader == address(0)) revert InvalidAddress();
        // solhint-disable-next-line not-rely-on-time, gas-strict-inequalities
        if (deadline <= block.timestamp) revert DeadlineExpired();
        if (
            // Audit Pass-3 M-01 — cap how far in the future a pre-signed
            // deposit can execute. Mirrors the trade ceiling.
            // solhint-disable-next-line not-rely-on-time, gas-strict-inequalities
            deadline > block.timestamp + MAX_DEPOSIT_DEADLINE
        ) {
            revert DeadlineTooFar();
        }
        if (seenDepositIds[depositId]) revert DepositIdAlreadyUsed();
        if (nonces[trader] != traderNonce) revert InvalidNonce();
        if (assetId != bytes32(0) && !assetConfigs[assetId].enabled) {
            revert AssetNotEnabled();
        }

        bytes32 digest = _depositIntentDigest(
            depositId,
            trader,
            assetId,
            encAmount,
            escrowProof,
            traderNonce,
            deadline
        );
        if (ECDSA.recover(digest, traderSignature) != trader) {
            revert InvalidSignature();
        }

        unchecked {
            ++nonces[trader];
        }
        seenDepositIds[depositId] = true;

        // `amountG` is resolved by the caller: the committee wrapper passes
        // `validateCiphertext(itUint256)` (binds the client input to the
        // self-broadcasting trader); the relayer wrapper passes
        // `onBoard(ctUint256)`. A raw client ciphertext is NOT onBoard-able.
        if (assetId == bytes32(0)) {
            _accumulateXom(trader, amountG);
        } else {
            _accumulateRwa(trader, assetId, amountG);
        }
        emit Deposited(depositId, trader, assetId);
    }

    /**
     * @notice Common trade-execution body shared by {trade} and
     *         {tradeWithCommittee}. Internal helper.
     * @dev Verifies the trader's EIP-712 signature, reads the live
     *      oracle price, performs the slippage check, and settles
     *      the encrypted trade in MPC space. Caller owns relayer or
     *      committee authorisation.
     * @param tradeId Unique trade identifier.
     * @param trader Trader EOA.
     * @param assetId Registered RWA asset.
     * @param isBuy True for buy, false for sell.
     * @param encQuantity Encrypted RWA quantity (ctUint256).
     * @param oraclePriceCommit Trader's signed oracle-price expectation.
     * @param traderNonce Expected trader nonce.
     * @param deadline Unix-seconds deadline.
     * @param traderSignature EIP-712 signature.
     */
    function _executeTrade( // solhint-disable-line code-complexity, function-max-lines
        bytes32 tradeId,
        address trader,
        bytes32 assetId,
        bool isBuy,
        ctUint256 calldata encQuantity,
        gtUint256 quantityG,
        uint256 oraclePriceCommit,
        uint256 traderNonce,
        uint256 deadline,
        bytes calldata traderSignature
    ) private {
        if (trader == address(0)) revert InvalidAddress();
        // solhint-disable-next-line not-rely-on-time, gas-strict-inequalities
        if (deadline <= block.timestamp) revert DeadlineExpired();
        // Audit H-02 fix — bound deadline so trader signatures cannot
        // outlive a 48 h price-feed timelock window.
        if (
            // solhint-disable-next-line not-rely-on-time, gas-strict-inequalities
            deadline > block.timestamp + MAX_TRADE_DEADLINE
        ) {
            revert DeadlineTooFar();
        }
        if (seenTradeIds[tradeId]) revert TradeIdAlreadyUsed();
        if (nonces[trader] != traderNonce) revert InvalidNonce();

        AssetConfig memory cfg = assetConfigs[assetId];
        if (!cfg.enabled) revert AssetNotEnabled();

        bytes32 digest = _tradeIntentDigest(
            tradeId,
            trader,
            assetId,
            cfg.priceFeed,
            isBuy,
            encQuantity,
            oraclePriceCommit,
            traderNonce,
            deadline
        );
        if (ECDSA.recover(digest, traderSignature) != trader) {
            revert InvalidSignature();
        }

        // Read live oracle price + slippage check vs trader's commit.
        uint256 livePrice = _readOraclePrice(cfg);
        _checkSlippage(oraclePriceCommit, livePrice);

        unchecked {
            ++nonces[trader];
            ++totalTrades;
        }
        seenTradeIds[tradeId] = true;

        // Settlement in MPC space. `quantityG` is resolved by the caller —
        // committee wrapper passes `validateCiphertext(itUint256)` (self-
        // broadcast trader), relayer wrapper passes `onBoard(ctUint256)`.
        gtUint256 priceG = MpcCore.setPublic256(livePrice);
        gtUint256 notionalG = MpcCore.checkedMul(quantityG, priceG);
        // Notional is in (token-decimals × price-scale-decimals) units;
        // we treat the public oracle price as already-18-decimal-scaled
        // by `_readOraclePrice` so notional is a 36-dec product. Divide
        // by 1e18 to get an 18-dec XOM-equivalent notional.
        gtUint256 oneE18 = MpcCore.setPublic256(10 ** CANONICAL_DECIMALS);
        gtUint256 notionalScaledG = MpcCore.div(notionalG, oneE18);

        // Audit M-01 fix — reject dust trades where the integer-div
        // `notionalScaled` rounds to zero (otherwise the buyer would
        // receive a non-zero quantity for a zero XOM debit). Decrypt
        // a single bit to learn "non-zero" — same 1-bit leak that the
        // tier check leaks in PrivateYieldVault, accepted as the
        // canonical privacy-vs-correctness tradeoff.
        gtBool nonZeroG = MpcCore.gt(
            notionalScaledG, MpcCore.setPublic256(0)
        );
        if (!MpcCore.decrypt(nonZeroG)) revert ZeroNotional();

        gtUint256 feeBpsG =
            MpcCore.setPublic256(uint256(cfg.tradeFeeBps));
        gtUint256 bpsDivG = MpcCore.setPublic256(BASIS_POINTS_DIVISOR);
        gtUint256 feeNumG = MpcCore.checkedMul(notionalScaledG, feeBpsG);
        gtUint256 feeG = MpcCore.div(feeNumG, bpsDivG);
        gtUint256 notionalAfterG =
            MpcCore.checkedSub(notionalScaledG, feeG);

        if (isBuy) {
            // Buyer pays notional PLUS the trade fee (fee-on-top), symmetric
            // with the sell side which withholds the fee from the seller's
            // proceeds. This FUNDS the `feeRecipient` credit below: previously
            // the buyer was debited only `notionalScaledG` while `feeRecipient`
            // was credited `feeG` with no offsetting debit, minting unbacked
            // XOM into the claim accumulator and under-collateralising claims
            // (a solvency bug — the last claimer could not be paid). The buyer
            // still receives the full unscaled quantity.
            _debitXom(
                trader,
                MpcCore.checkedAdd(notionalScaledG, feeG)
            );
            _accumulateRwa(trader, assetId, quantityG);
        } else {
            // Seller forfeits the unscaled quantity. Receives net notional.
            _debitRwa(trader, assetId, quantityG);
            _accumulateXom(trader, notionalAfterG);
        }
        _accumulateXom(feeRecipient, feeG);

        emit TradeSettled(tradeId, trader, assetId, isBuy, livePrice);
    }

    /// @dev Add an encrypted delta to a recipient's XOM accumulator.
    function _accumulateXom(address recipient, gtUint256 deltaG) private {
        bool hasPrior = _hasUnclaimedXom[recipient];
        gtUint256 newG = hasPrior
            ? MpcCore.checkedAdd(MpcCore.onBoard(encXomBalance[recipient]), deltaG)
            : deltaG;
        encXomBalance[recipient] = MpcCore.offBoard(newG);
        if (!hasPrior) _hasUnclaimedXom[recipient] = true;
    }

    /// @dev Subtract an encrypted delta from a holder's XOM accumulator.
    ///      Reverts via `MpcCore.checkedSub` if the holder has insufficient
    ///      balance (encrypted-balance underflow check, audit H-05 pattern).
    function _debitXom(address holder, gtUint256 deltaG) private {
        gtUint256 priorG = MpcCore.onBoard(encXomBalance[holder]);
        gtUint256 newG = MpcCore.checkedSub(priorG, deltaG);
        encXomBalance[holder] = MpcCore.offBoard(newG);
        // The accumulator may have been zeroed out by this debit, but
        // the next `claim` will surface that as "noBalanceToClaim only
        // if flag is false" — flag stays true so the caller still sees
        // the empty-but-flagged state and either claims (and resets) or
        // accumulates more. This avoids a separate decrypt-to-detect-zero
        // round-trip on every debit.
        _hasUnclaimedXom[holder] = true;
    }

    /// @dev Add an encrypted delta to a recipient's per-asset RWA accumulator.
    function _accumulateRwa(
        address recipient,
        bytes32 assetId,
        gtUint256 deltaG
    )
        private
    {
        bool hasPrior = _hasUnclaimedRwa[recipient][assetId];
        gtUint256 newG = hasPrior
            ? MpcCore.checkedAdd(
                MpcCore.onBoard(encRwaBalance[recipient][assetId]),
                deltaG
            )
            : deltaG;
        encRwaBalance[recipient][assetId] = MpcCore.offBoard(newG);
        if (!hasPrior) _hasUnclaimedRwa[recipient][assetId] = true;
    }

    /// @dev Subtract an encrypted delta from a holder's per-asset RWA
    ///      accumulator. Reverts via `MpcCore.checkedSub` if insufficient.
    function _debitRwa(
        address holder,
        bytes32 assetId,
        gtUint256 deltaG
    )
        private
    {
        gtUint256 priorG = MpcCore.onBoard(encRwaBalance[holder][assetId]);
        gtUint256 newG = MpcCore.checkedSub(priorG, deltaG);
        encRwaBalance[holder][assetId] = MpcCore.offBoard(newG);
        _hasUnclaimedRwa[holder][assetId] = true;
    }

    /**
     * @dev Read the live oracle price and scale to 18-decimals canonical.
     *      Reverts on stale or non-positive answer.
     *
     *      Audit H-03 fixes:
     *        - `answeredInRound >= roundId` (round-completeness — rejects
     *          stale aggregator responses from a feed migration).
     *        - `updatedAt > 0` (rejects in-flight rounds).
     *        - `cfg.maxPriceStaleness` is enforced unconditionally (no
     *          zero-disable bypass; init-time validation already requires
     *          a non-zero value, but the runtime check here is
     *          defence-in-depth in case storage is corrupted).
     */
    function _readOraclePrice( // solhint-disable-line code-complexity
        AssetConfig memory cfg
    )
        private
        view
        returns (uint256)
    {
        (
            uint80 roundId,
            int256 answer,
            ,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = IAggregatorV3(cfg.priceFeed).latestRoundData();

        // solhint-disable-next-line gas-strict-inequalities
        if (answer <= 0) revert InvalidPrice();
        if (updatedAt == 0) revert StalePrice();
        // solhint-disable-next-line gas-strict-inequalities
        if (answeredInRound < roundId) revert StalePrice();
        if (cfg.maxPriceStaleness == 0) revert InvalidStaleness();
        // solhint-disable-next-line not-rely-on-time, gas-strict-inequalities
        if (block.timestamp - updatedAt > cfg.maxPriceStaleness) {
            revert StalePrice();
        }

        uint256 raw = uint256(answer);
        // Scale to 18 decimals.
        if (cfg.priceFeedDecimals == CANONICAL_DECIMALS) {
            return raw;
        }
        // solhint-disable-next-line gas-strict-inequalities
        if (cfg.priceFeedDecimals < CANONICAL_DECIMALS) {
            return raw * 10 ** (CANONICAL_DECIMALS - cfg.priceFeedDecimals);
        }
        return raw / 10 ** (cfg.priceFeedDecimals - CANONICAL_DECIMALS);
    }

    /**
     * @notice Compute the EIP-712 digest of a `TradeIntent` payload.
     * @dev Extracted so {tradeWithCommittee} can verify the committee
     *      signed over the SAME digest the trader did, without
     *      re-computing inside the verifier.
     * @param tradeId Unique trade identifier.
     * @param trader Trader EOA.
     * @param assetId Registered RWA asset.
     * @param priceFeed Asset's bound price feed at signing time (audit H-02).
     * @param isBuy True for buy, false for sell.
     * @param encQuantity Encrypted RWA quantity (ctUint256).
     * @param oraclePriceCommit Trader's signed oracle-price expectation.
     * @param traderNonce Expected trader nonce.
     * @param deadline Unix-seconds deadline.
     * @return The EIP-712 digest.
     */
    function _tradeIntentDigest(
        bytes32 tradeId,
        address trader,
        bytes32 assetId,
        address priceFeed,
        bool isBuy,
        ctUint256 calldata encQuantity,
        uint256 oraclePriceCommit,
        uint256 traderNonce,
        uint256 deadline
    ) private view returns (bytes32) {
        bytes32 quantityCommit = _commit(encQuantity);
        // Audit H-02 fix — `priceFeed` is bound in the typehash so a
        // post-signature feed rotation invalidates pending intents.
        bytes32 structHash = keccak256(
            abi.encode(
                TRADE_INTENT_TYPEHASH,
                tradeId,
                trader,
                assetId,
                priceFeed,
                isBuy,
                quantityCommit,
                oraclePriceCommit,
                traderNonce,
                deadline
            )
        );
        return _hashTypedDataV4(structHash);
    }

    /**
     * @notice Compute the EIP-712 digest of a `DepositIntent` payload.
     * @dev Extracted so {depositWithCommittee} can verify the committee
     *      signed over the SAME digest the trader did, without
     *      re-computing inside the verifier.
     * @param depositId Unique deposit identifier.
     * @param trader Trader EOA.
     * @param assetId `bytes32(0)` for XOM, otherwise a registered RWA id.
     * @param encAmount Encrypted amount (ctUint256).
     * @param escrowProof Off-chain escrow attestation hash.
     * @param traderNonce Expected trader nonce.
     * @param deadline Unix-seconds deadline.
     * @return The EIP-712 digest.
     */
    function _depositIntentDigest(
        bytes32 depositId,
        address trader,
        bytes32 assetId,
        ctUint256 calldata encAmount,
        bytes32 escrowProof,
        uint256 traderNonce,
        uint256 deadline
    ) private view returns (bytes32) {
        bytes32 amountCommit = _commit(encAmount);
        bytes32 structHash = keccak256(
            abi.encode(
                DEPOSIT_INTENT_TYPEHASH,
                depositId,
                trader,
                assetId,
                amountCommit,
                escrowProof,
                traderNonce,
                deadline
            )
        );
        return _hashTypedDataV4(structHash);
    }

    /**
     * @dev Revert unless `live` is within MAX_SLIPPAGE_BPS of `commit`.
     *      Bound check is symmetric (|live - commit| / commit ≤ bps).
     */
    function _checkSlippage(uint256 commit, uint256 live) private pure {
        if (commit == 0) revert InvalidPrice();
        uint256 diff = live > commit ? live - commit : commit - live;
        // diff / commit ≤ MAX_SLIPPAGE_BPS / BASIS_POINTS_DIVISOR
        // ⇔ diff * BASIS_POINTS_DIVISOR ≤ MAX_SLIPPAGE_BPS * commit
        if (
            diff * BASIS_POINTS_DIVISOR
                > uint256(MAX_SLIPPAGE_BPS) * commit
        ) {
            revert SlippageExceeded();
        }
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
