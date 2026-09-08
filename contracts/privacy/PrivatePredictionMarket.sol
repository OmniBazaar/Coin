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
    PrivatePredictionMath
} from "./PrivatePredictionMath.sol";
import {
    IBridgeVerifier
} from "../bridge/IBridgeVerifier.sol";
import {
    CommitteeAttestor
} from "../attestation/CommitteeAttestor.sol";

// solhint-disable max-states-count
// The deliberate 21st state slot (`attestationVerifier`) is the
// random-committee wiring added in Week 1.2 of the FIX_PRIVACY resume
// (memory/decision_privacy_roles_random_committee_2026-05-27.md).
// The 20-slot soft-cap is a maintainability heuristic; we accept the
// over-budget delta in exchange for the architectural unification of
// the relayer + escrow-oracle authorisation paths through a single
// pluggable `IBridgeVerifier`.

/**
 * @title PrivatePredictionMarket
 * @author OmniBazaar Development Team
 * @notice Privacy-preserving prediction markets on COTI Helium 256-bit MPC.
 * @dev Phase 6.3 of FIX_PRIVACY:
 *      - Markets are public — admin (or a designated `MARKET_CREATOR_ROLE`
 *        holder in v2) registers a market with a public `outcomeCount`,
 *        `resolutionDeadline`, and per-market `oracleAddress`.
 *      - Users place encrypted-stake bets on a public `outcomeIdx`. The
 *        stake amount stays encrypted (`ctUint256`); the chosen outcome
 *        is public, by design — outcome privacy would require fully-MPC
 *        outcome routing which is out-of-scope for v1.
 *      - After the resolution deadline, the per-market oracle
 *        (granted `MARKET_ORACLE_ROLE` for that market via
 *        `assignMarketOracle`) calls `resolveMarket(winningOutcome,
 *        payoutPerShareBps)`. The bps figure is computed off-chain from
 *        the public per-outcome stake totals and reflects the
 *        pari-mutuel multiplier (e.g., 18000 = 1.8× — winners get back
 *        their stake plus a share of the losing pool).
 *      - Winners call `claimPayout(marketId)` to credit
 *        `encShares × payoutPerShareBps / 10000` to their encrypted
 *        XOM accumulator. Losers' shares decay to zero on resolution
 *        (the encrypted multiplication still runs, but with 0 bps for
 *        non-winning outcomes — the result is encrypted zero, which
 *        the caller can claim but receives no value).
 *      - Cancelled markets allow `claimRefund(marketId, outcomeIdx)` for
 *        full-stake return per outcome the trader bet on (audit H-01
 *        fix — refund flag is per-outcome so multi-outcome hedgers
 *        recover every position).
 *      - The per-market oracle additionally has a `resolveAsRefund`
 *        path (audit H-02 fix) for "no-winner" or
 *        "extreme-skew-above-MAX_PAYOUT_PER_SHARE_BPS" scenarios where
 *        normal `resolveMarket` would either revert or strand pool
 *        residue. Flips status to CANCELLED, unlocking
 *        per-outcome `claimRefund`.
 *      - Admin `cancelMarket` is restricted post-deadline (audit H-03
 *        fix) — for the {CANCEL_GRACE_PERIOD} (7 days) after a
 *        market's deadline, only the per-market oracle (or
 *        `resolveAsRefund`) can advance the market. After the grace
 *        window admin can rescue stuck markets via cancel. Pre-deadline
 *        cancel is unrestricted (rare emergency use).
 *      - Carries forward all audit-remediated patterns:
 *          * COTI-only chainid guard.
 *          * EIP-712 typehash binds stakeCommit + marketId + outcomeIdx +
 *            nonce + deadline.
 *          * Dual-signature on bet (trader + escrow oracle) — same
 *            dual-attestation as PrivateRWAAMM (audit H-01).
 *          * Per-market deadline cap MAX_BET_DEADLINE = 1 h (audit H-02).
 *          * 48 h timelocks on every privileged setter (forwarder,
 *            fee recipient, default fee bps).
 *          * UUPS + 7-day two-step ossification + 48 h upgrade
 *            timelock (audit H-05 — applied from inception, not
 *            back-port).
 *          * `renounceRole(DEFAULT_ADMIN_ROLE)` overridden to revert.
 *          * Pause does NOT block user-only escape paths
 *            (`claimPayout`, `claimRefund`, `claim`).
 *          * Trusted forwarder held in proxy storage (audit H-06).
 *          * Encrypted-balance accumulator with monotonic per-recipient
 *            claim nonces.
 *          * Configurable `feeRecipient` (rejects `address(0)` and
 *            `address(this)` — audit M-02).
 *          * Claim paths use raw `msg.sender`, NOT `_msgSender()`
 *            (audit M-07).
 */
contract PrivatePredictionMarket is
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

    /// @notice Market lifecycle status.
    enum MarketStatus {
        EMPTY,
        OPEN,
        RESOLVED,
        CANCELLED
    }

    /**
     * @notice One prediction market.
     * @dev `outcomeCount` is the fixed-arity number of outcomes
     *      (≥ 2, ≤ MAX_OUTCOMES). `resolutionOracle` is the address
     *      authorised to call `resolveMarket` after `resolutionDeadline`.
     */
    // solhint-disable-next-line gas-struct-packing
    struct Market {
        uint8 outcomeCount;
        uint8 winningOutcome;       // valid only when status == RESOLVED
        MarketStatus status;
        uint64 betFeeBps;           // per-bet fee, capped at MAX_BET_FEE_BPS
        uint64 payoutPerShareBps;   // set at resolution
        uint64 resolutionDeadline;  // unix-seconds
        address resolutionOracle;
        address creator;            // who registered the market
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

    /**
     * @notice Pending timelocked UUPS implementation upgrade.
     * @dev Audit H-05 pattern — adds a 48 h delay to UUPS upgrades.
     */
    struct PendingUpgrade {
        address newImplementation;
        uint256 effectiveAt;
    }

    /**
     * @notice Pending timelocked per-market oracle reassignment.
     * @dev Audit M-02 fix — admin can rotate the resolution oracle of
     *      an open market via the standard 48 h timelock pattern when
     *      the original oracle is unresponsive or compromised. Avoids
     *      the otherwise-only-recovery path of `cancelMarket` + recreate.
     */
    struct PendingMarketOracle {
        address newOracle;
        uint256 effectiveAt;
    }

    // ========================================================================
    // CONSTANTS
    // ========================================================================

    /// @notice Role for the relayer (validator gateway).
    bytes32 public constant RELAYER_ROLE = keccak256("RELAYER_ROLE");

    /// @notice Role for escrow oracles co-signing bet attestations
    /// (audit H-01 pattern).
    bytes32 public constant ESCROW_ORACLE_ROLE =
        keccak256("ESCROW_ORACLE_ROLE");

    /// @notice Role for the off-chain oracle that resolves markets.
    /// @dev Holders are individual addresses; per-market authorisation
    ///      is enforced by `Market.resolutionOracle`. Role exists so
    ///      the validator can rotate keys in bulk via grant/revoke.
    bytes32 public constant MARKET_ORACLE_ROLE =
        keccak256("MARKET_ORACLE_ROLE");

    /// @notice Basis-points divisor (100 %).
    uint256 public constant BASIS_POINTS_DIVISOR = 10_000;

    /// @notice Maximum bet fee admin can set (1 %, audit M-05 carry).
    uint64 public constant MAX_BET_FEE_BPS = 100;

    /// @notice Default bet fee (0.30 %).
    uint64 public constant DEFAULT_BET_FEE_BPS = 30;

    /// @notice Maximum allowed `payoutPerShareBps` at resolution.
    /// @dev Capped at 100× to bound oracle-supplied multiplier and
    ///      prevent encrypted-overflow on extreme pools.
    uint64 public constant MAX_PAYOUT_PER_SHARE_BPS = 1_000_000;

    /// @notice Maximum bet-deadline window (audit H-02 pattern).
    uint256 public constant MAX_BET_DEADLINE = 1 hours;

    /// @notice Maximum number of outcomes per market.
    uint8 public constant MAX_OUTCOMES = 16;

    /// @notice 7-day ossification delay.
    uint256 public constant OSSIFICATION_DELAY = 7 days;

    /// @notice Required delay for privileged setter timelocks (48 h).
    /// @notice Set to `0` per Pioneer-Phase rule — see PrivateYieldVault
    ///         constant for full rationale.
    uint256 public constant TIMELOCK_DELAY = 0;

    /// @notice Grace window after a market's `resolutionDeadline` during
    /// which only the per-market oracle (or `resolveAsRefund`) can advance
    /// the market — admin `cancelMarket` reverts (audit H-03 fix). After
    /// the grace window, admin can rescue a stuck market via cancel.
    uint256 public constant CANCEL_GRACE_PERIOD = 7 days;

    /// @notice COTI mainnet chain id.
    uint256 private constant COTI_MAINNET_CHAIN_ID = 2_632_500;

    /// @notice COTI testnet chain id.
    uint256 private constant COTI_TESTNET_CHAIN_ID = 7_082_400;

    /// @notice EIP-712 typehash for the trader's bet-intent.
    // solhint-disable-next-line gas-small-strings, max-line-length
    bytes32 private constant BET_INTENT_TYPEHASH = keccak256("BetIntent(bytes32 betId,address trader,bytes32 marketId,uint8 outcomeIdx,bytes32 stakeCommit,bytes32 escrowProof,uint256 nonce,uint256 deadline)");

    /// @notice EIP-712 typehash for the escrow oracle's attestation.
    /// @dev Audit 2026-05-27 finding H-01 (legacy `bet` path): the
    ///      `EscrowAttestation` typehash MUST bind the same `nonce`
    ///      and `deadline` the trader's `BetIntent` binds, otherwise
    ///      the "trader + oracle co-sign the same tuple" invariant
    ///      is broken — a relayer can replay an oracle attestation
    ///      against a different (still-pending) bet by the same
    ///      trader within the MAX_BET_DEADLINE = 1 h window.
    // solhint-disable-next-line gas-small-strings, max-line-length
    bytes32 private constant ESCROW_ATTESTATION_TYPEHASH = keccak256("EscrowAttestation(bytes32 betId,address trader,bytes32 marketId,uint8 outcomeIdx,bytes32 stakeCommit,bytes32 escrowProof,uint256 nonce,uint256 deadline)");

    // ========================================================================
    // STATE VARIABLES
    // ========================================================================

    /// @notice marketId → public market record.
    mapping(bytes32 marketId => Market m) public markets;

    /// @notice (trader, marketId, outcomeIdx) → encrypted share balance.
    mapping(
        address trader
            => mapping(
                bytes32 marketId
                    => mapping(uint8 outcomeIdx => ctUint256 shares)
            )
    ) private encShares;

    /// @notice (trader, marketId, outcomeIdx) → has shares flag.
    mapping(
        address trader
            => mapping(
                bytes32 marketId
                    => mapping(uint8 outcomeIdx => bool flagged)
            )
    ) private _hasShares;

    /// @notice (trader, marketId) → has been claimed-payout flag (one-shot).
    mapping(address trader => mapping(bytes32 marketId => bool claimed))
        public payoutClaimed;

    /// @notice (trader, marketId, outcomeIdx) → has been claimed-refund
    /// flag (one-shot per outcome). Audit H-01 fix — keyed per outcome
    /// so a hedging trader who bet on multiple outcomes can refund every
    /// position on a cancelled market.
    mapping(
        address trader
            => mapping(
                bytes32 marketId
                    => mapping(uint8 outcomeIdx => bool refunded)
            )
    ) public refundClaimed;

    /// @notice address → next-expected nonce for `BetIntent` signatures.
    mapping(address trader => uint256 nonce) public nonces;

    /// @notice address → encrypted XOM-side balance (claimable).
    mapping(address holder => ctUint256 balance) private encXomBalance;

    /// @notice address → has a non-zero accumulator pending claim.
    mapping(address holder => bool flagged) private _hasUnclaimedXom;

    /// @notice address → monotonic per-recipient claim nonce.
    mapping(address holder => uint256 claimNonce) public claimNonces;

    /// @notice betId → seen flag (replay protection).
    mapping(bytes32 betId => bool seen) private seenBetIds;

    /// @notice marketId → seen flag (collision protection on createMarket).
    mapping(bytes32 marketId => bool seen) private seenMarketIds;

    /// @notice Recipient of bet-fee accumulator. Configurable + timelocked.
    address public feeRecipient;

    /// @notice ERC-2771 trusted forwarder (proxy storage — audit H-06).
    address public trustedForwarder;

    /// @notice Total lifetime markets opened (counter).
    uint256 private totalMarkets;

    /// @notice Total lifetime bets placed (counter).
    uint256 private totalBets;

    /// @notice True once the contract is permanently non-upgradable.
    bool private _ossified;

    /// @notice Block timestamp when ossification was requested (0 = none).
    uint256 public ossificationRequestTime;

    /// @notice Pending forwarder update (timelocked).
    PendingForwarder private pendingForwarder;

    /// @notice Pending fee-recipient update (timelocked).
    PendingFeeRecipient private pendingFeeRecipient;

    /// @notice Pending UUPS implementation upgrade (timelocked, audit H-05).
    PendingUpgrade public pendingUpgrade;

    /// @notice marketId → pending oracle reassignment (timelocked, audit M-02).
    mapping(bytes32 marketId => PendingMarketOracle pending)
        private pendingMarketOracleByMarket;

    /// @notice Pluggable committee-attestation verifier for the
    ///         random-committee bet path ({betWithCommittee}). Wires
    ///         directly to a `RandomCommitteeVerifier` instance —
    ///         the contract manages its own per-trader nonces, so no
    ///         `OmniAttestationGateway` nonce indirection is required.
    ///         Per
    ///         `memory/decision_privacy_roles_random_committee_2026-05-27.md`
    ///         the committee path replaces BOTH the static
    ///         `RELAYER_ROLE` allowlist AND the
    ///         `ESCROW_ORACLE_ROLE` co-signature — committee members
    ///         independently verify the off-chain `escrowProof` and
    ///         their threshold signature is the attestation. Zero
    ///         address = committee path disabled.
    IBridgeVerifier public attestationVerifier;

    /// @dev Storage gap for proxy-safe future-state additions.
    /// @dev Originally 40; shrunk to 39 for the
    ///      `pendingMarketOracleByMarket` mapping (1 slot — mappings
    ///      are single-slot regardless of value-type size). Shrunk
    ///      again to 38 for the random-committee `attestationVerifier`
    ///      slot.
    uint256[38] private __gap;

    // ========================================================================
    // EVENTS
    // ========================================================================

    /**
     * @notice Emitted when a market is created.
     * @param marketId Market identifier.
     * @param creator Address that registered the market.
     * @param oracle Per-market resolution oracle.
     * @param outcomeCount Number of outcomes.
     * @param resolutionDeadline Unix-seconds at which the oracle may resolve.
     */
    event MarketCreated(
        bytes32 indexed marketId,
        address indexed creator,
        address indexed oracle,
        uint8 outcomeCount,
        uint64 resolutionDeadline
    );

    /**
     * @notice Emitted on a successful bet.
     * @param betId Bet identifier.
     * @param trader Trader EOA.
     * @param marketId Market identifier.
     * @param outcomeIdx Public outcome the trader bet on.
     */
    event BetPlaced(
        bytes32 indexed betId,
        address indexed trader,
        bytes32 indexed marketId,
        uint8 outcomeIdx
    );

    /**
     * @notice Emitted when the oracle resolves a market.
     * @param marketId Market identifier.
     * @param oracle Resolving oracle.
     * @param winningOutcome Public winning outcome.
     * @param payoutPerShareBps Multiplier applied to winners' shares.
     */
    event MarketResolved(
        bytes32 indexed marketId,
        address indexed oracle,
        uint8 winningOutcome,
        uint64 payoutPerShareBps
    );

    /**
     * @notice Emitted when admin cancels an open market.
     * @param marketId Market identifier.
     */
    event MarketCancelled(bytes32 indexed marketId);

    /**
     * @notice Emitted when a winner credits their payout.
     * @param marketId Market identifier.
     * @param trader Winning trader.
     */
    event PayoutClaimed(bytes32 indexed marketId, address indexed trader);

    /**
     * @notice Emitted when a trader refunds their stake on a cancelled market.
     * @param marketId Market identifier.
     * @param trader Refunding trader.
     * @param outcomeIdx Outcome the original stake was placed on.
     */
    event RefundClaimed(
        bytes32 indexed marketId,
        address indexed trader,
        uint8 outcomeIdx
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
     *         attestation verifier used by {betWithCommittee}.
     * @param verifier New verifier; zero address disables the
     *         committee path (legacy {bet} entry remains functional).
     */
    event AttestationVerifierSet(IBridgeVerifier indexed verifier);

    /**
     * @notice Emitted when a bet settles via the committee
     *         attestation path. Companion to {BetPlaced}; the
     *         attester list replaces the legacy single
     *         `ESCROW_ORACLE_ROLE` attestor — every committee
     *         member independently verified the off-chain
     *         `escrowProof` before signing.
     * @param betId Bet identifier.
     * @param attesters Sorted, deduplicated list of validator
     *        attesters whose signatures satisfied the committee
     *        quorum.
     */
    event BetCommitteeAttested(
        bytes32 indexed betId,
        address[] attesters
    );

    /**
     * @notice Emitted when admin queues a per-market oracle reassignment.
     * @param marketId Market whose oracle is being rotated.
     * @param newOracle Pending replacement oracle.
     * @param effectiveAt Unix-seconds at which it can be applied.
     */
    event MarketOracleUpdateQueued(
        bytes32 indexed marketId,
        address indexed newOracle,
        uint256 effectiveAt
    );

    /**
     * @notice Emitted when the queued per-market oracle update is applied.
     * @param marketId Market whose oracle was rotated.
     * @param oldOracle Previous oracle.
     * @param newOracle New oracle.
     */
    event MarketOracleUpdated(
        bytes32 indexed marketId,
        address indexed oldOracle,
        address indexed newOracle
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
    error MarketAlreadyExists();
    error MarketNotOpen();
    error MarketNotResolved();
    error MarketNotCancelled();
    error MarketAlreadyResolved();
    error InvalidOutcomeCount();
    error InvalidOutcome();
    error InvalidResolutionDeadline();
    error ResolutionDeadlineNotElapsed();
    error CancelGraceWindowOpen();
    error PayoutAlreadyClaimed();
    error RefundAlreadyClaimed();
    error NoSharesOnOutcome();
    error NotMarketOracle();
    error InvalidPayoutBps();
    error BetFeeTooHigh();
    error BetIdAlreadyUsed();
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
    error ZeroStake();

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
     * @param escrowOracles Initial ESCROW_ORACLE_ROLE holders.
     * @param marketOracles Initial MARKET_ORACLE_ROLE holders.
     * @param trustedForwarder_ ERC-2771 forwarder; `address(0)` to disable.
     * @param feeRecipient_ Recipient of bet-fee accumulator. Must be
     *        non-zero AND not `address(this)`.
     */
    function initialize( // solhint-disable-line code-complexity
        address admin,
        address[] calldata relayers,
        address[] calldata escrowOracles,
        address[] calldata marketOracles,
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
        __EIP712_init("OmniBazaar PrivatePredictionMarket", "1");

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
        for (uint256 i = 0; i < marketOracles.length; ++i) {
            address mo = marketOracles[i];
            if (mo == address(0)) revert InvalidAddress();
            _grantRole(MARKET_ORACLE_ROLE, mo);
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
    // EXTERNAL — MARKET LIFECYCLE
    // ========================================================================

    /**
     * @notice Register a new prediction market.
     * @dev Caller must hold DEFAULT_ADMIN_ROLE in v1. The supplied
     *      `oracle` becomes `Market.resolutionOracle` and is the only
     *      address authorised to call `resolveMarket` for this market;
     *      it must also currently hold MARKET_ORACLE_ROLE so the admin
     *      can rotate keys via grant/revoke without re-registering
     *      every market.
     * @param marketId Caller-chosen 32-byte market identifier.
     * @param outcomeCount Number of outcomes (≥ 2, ≤ MAX_OUTCOMES).
     * @param resolutionDeadline Unix-seconds at which the oracle may resolve.
     * @param oracle Per-market resolution oracle address.
     * @param betFeeBps Per-bet fee in basis points (capped at MAX_BET_FEE_BPS).
     */
    function createMarket( // solhint-disable-line code-complexity
        bytes32 marketId,
        uint8 outcomeCount,
        uint64 resolutionDeadline,
        address oracle,
        uint64 betFeeBps
    ) external onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {
        if (seenMarketIds[marketId]) revert MarketAlreadyExists();
        // solhint-disable-next-line gas-strict-inequalities
        if (outcomeCount < 2 || outcomeCount > MAX_OUTCOMES) {
            revert InvalidOutcomeCount();
        }
        if (oracle == address(0)) revert InvalidAddress();
        if (!hasRole(MARKET_ORACLE_ROLE, oracle)) revert NotMarketOracle();
        // solhint-disable-next-line gas-strict-inequalities
        if (betFeeBps > MAX_BET_FEE_BPS) revert BetFeeTooHigh();
        // solhint-disable-next-line not-rely-on-time, gas-strict-inequalities
        if (resolutionDeadline <= block.timestamp) {
            revert InvalidResolutionDeadline();
        }

        markets[marketId] = Market({
            outcomeCount: outcomeCount,
            winningOutcome: 0,
            status: MarketStatus.OPEN,
            betFeeBps: betFeeBps,
            payoutPerShareBps: 0,
            resolutionDeadline: resolutionDeadline,
            resolutionOracle: oracle,
            creator: msg.sender
        });
        seenMarketIds[marketId] = true;
        unchecked {
            ++totalMarkets;
        }
        emit MarketCreated(
            marketId,
            msg.sender,
            oracle,
            outcomeCount,
            resolutionDeadline
        );
    }

    /**
     * @notice Place a trader-signed encrypted bet on a market outcome.
     * @dev Called by an authorized RELAYER. Requires both the trader's
     *      EIP-712 signature AND a separate ESCROW_ORACLE_ROLE-holder's
     *      attestation (audit H-01 dual-signature pattern from
     *      PrivateRWAAMM). The fee is taken upfront in MPC space and
     *      credited to `feeRecipient`; the post-fee stake is added to
     *      the trader's encrypted shares for the chosen outcome.
     * @param betId Unique 32-byte bet identifier.
     * @param trader Trader EOA.
     * @param marketId Market the bet targets.
     * @param outcomeIdx Public outcome the trader bets on.
     * @param encStake Encrypted XOM stake (ctUint256).
     * @param escrowProof Off-chain escrow attestation hash. Bound in
     *        both signatures.
     * @param traderNonce Expected trader nonce (replay protection).
     * @param deadline Unix-seconds deadline (≤ now + MAX_BET_DEADLINE).
     * @param traderSignature Trader's EIP-712 signature over `BetIntent`.
     * @param oracleAttestor Address of the ESCROW_ORACLE_ROLE-holder.
     * @param oracleSignature Oracle's EIP-712 signature over `EscrowAttestation`.
     */
    function bet(
        bytes32 betId,
        address trader,
        bytes32 marketId,
        uint8 outcomeIdx,
        ctUint256 calldata encStake,
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
        // Prevent trader from self-attesting if they hold ESCROW_ORACLE_ROLE
        if (oracleAttestor == trader) revert InvalidEscrowAttestation();

        bytes32 stakeCommit = _commit(encStake);
        // Audit 2026-05-27 finding H-01: bind nonce + deadline so the
        // oracle's attestation co-signs the exact same tuple as the
        // trader's BetIntent. Prevents relayer-side replay of an
        // attestation against a different in-flight bet by the same
        // trader within the MAX_BET_DEADLINE = 1 h window.
        bytes32 attestationHash = keccak256(
            abi.encode(
                ESCROW_ATTESTATION_TYPEHASH,
                betId,
                trader,
                marketId,
                outcomeIdx,
                stakeCommit,
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

        _executeBet(
            betId,
            trader,
            marketId,
            outcomeIdx,
            encStake,
            MpcCore.onBoard(encStake),
            escrowProof,
            traderNonce,
            deadline,
            traderSignature
        );
    }

    /**
     * @notice Place a trader-signed encrypted bet — committee
     *         attestation path.
     * @dev Replaces BOTH the static `RELAYER_ROLE` gate AND the
     *      single `ESCROW_ORACLE_ROLE` co-signature with a random
     *      M-of-N validator committee. Each committee member runs
     *      their own off-chain escrow-proof verifier and signs the
     *      `BetIntent` digest independently. The committee threshold
     *      quorum collectively replaces the legacy single oracle's
     *      attestation.
     *
     *      Caller authorisation: anyone may submit — the trader's
     *      EIP-712 signature + the committee's ≥M signatures carry
     *      every authorisation needed.
     *
     *      The trader (subject) MUST NOT appear in the committee
     *      attester list (Phase 2 audit Pass-1 C-2 fix).
     *
     *      Emits {BetCommitteeAttested} with the attester list for
     *      off-chain slashing recovery.
     * @param betId Unique 32-byte bet identifier.
     * @param trader Trader EOA.
     * @param marketId Market the bet targets.
     * @param outcomeIdx Public outcome the trader bets on.
     * @param encStake Encrypted XOM stake (ctUint256).
     * @param escrowProof Off-chain escrow attestation hash bound in
     *        the trader signature.
     * @param traderNonce Expected trader nonce.
     * @param deadline Unix-seconds deadline.
     * @param traderSignature Trader's EIP-712 signature over `BetIntent`.
     * @param committeeProof Verifier-specific opaque blob containing
     *        the M-of-N committee signatures over the same
     *        `BetIntent` digest as {traderSignature}.
     */
    function betWithCommittee(
        bytes32 betId,
        address trader,
        bytes32 marketId,
        uint8 outcomeIdx,
        itUint256 calldata encStake,
        bytes32 escrowProof,
        uint256 traderNonce,
        uint256 deadline,
        bytes calldata traderSignature,
        bytes calldata committeeProof
    ) external whenNotPaused nonReentrant {
        // The trader must self-broadcast this committee tx
        if (msg.sender != trader) revert InvalidSignature();
        // Audit Pass-3 H-01 — fast-reject BEFORE the expensive
        // _verifyCommittee call. Defense-in-depth: _executeBet
        // re-checks too.
        // solhint-disable-next-line not-rely-on-time, gas-strict-inequalities
        if (deadline <= block.timestamp) revert DeadlineExpired();
        if (seenBetIds[betId]) revert BetIdAlreadyUsed();
        if (nonces[trader] != traderNonce) revert InvalidNonce();

        bytes32 digest = _betIntentDigest(
            betId,
            trader,
            marketId,
            outcomeIdx,
            encStake.ciphertext,
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

        emit BetCommitteeAttested(betId, attesters);

        // Validate the client input (itUint256) — binds to msg.sender, so the
        // trader must self-broadcast this committee tx (same model as the DEX
        // lock + stake). The raw ciphertext stays for the digest.
        _executeBet(
            betId,
            trader,
            marketId,
            outcomeIdx,
            encStake.ciphertext,
            MpcCore.validateCiphertext(encStake),
            escrowProof,
            traderNonce,
            deadline,
            traderSignature
        );
    }

    /**
     * @notice Resolve a market.
     * @dev Only callable by the per-market `resolutionOracle` after
     *      `resolutionDeadline`. The oracle additionally must still
     *      hold MARKET_ORACLE_ROLE (defence-in-depth — if admin
     *      revoked the role between createMarket and resolveMarket,
     *      the call reverts and admin must reassign or cancel).
     * @param marketId Market to resolve.
     * @param winningOutcome Public winning outcome.
     * @param payoutPerShareBps Multiplier applied to winners' shares
     *        (e.g., 18000 = 1.8×). Computed off-chain from the public
     *        per-outcome stake totals.
     */
    function resolveMarket(
        bytes32 marketId,
        uint8 winningOutcome,
        uint64 payoutPerShareBps
    ) external {
        // Audit M-01 fix — NOT pause-gated. Resolution is the gateway
        // to winner payouts (a user-side escape path); pause must not
        // block it. Settlement still requires the per-market oracle
        // role check below.
        Market storage mkt = markets[marketId];
        if (mkt.status != MarketStatus.OPEN) revert MarketAlreadyResolved();
        if (msg.sender != mkt.resolutionOracle) revert NotMarketOracle();
        if (!hasRole(MARKET_ORACLE_ROLE, msg.sender)) {
            revert NotMarketOracle();
        }
        // solhint-disable-next-line not-rely-on-time, gas-strict-inequalities
        if (block.timestamp < mkt.resolutionDeadline) {
            revert ResolutionDeadlineNotElapsed();
        }
        // solhint-disable-next-line gas-strict-inequalities
        if (winningOutcome >= mkt.outcomeCount) revert InvalidOutcome();
        if (
            payoutPerShareBps == 0
                // solhint-disable-next-line gas-strict-inequalities
                || payoutPerShareBps > MAX_PAYOUT_PER_SHARE_BPS
        ) {
            revert InvalidPayoutBps();
        }

        mkt.status = MarketStatus.RESOLVED;
        mkt.winningOutcome = winningOutcome;
        mkt.payoutPerShareBps = payoutPerShareBps;
        emit MarketResolved(
            marketId, msg.sender, winningOutcome, payoutPerShareBps
        );
    }

    /**
     * @notice Per-market oracle path that converts an OPEN market to
     *         CANCELLED status post-deadline. Audit H-02 fix — resolves
     *         the "no-winner" or "extreme-skew above MAX_PAYOUT_PER_SHARE_BPS"
     *         scenarios where `resolveMarket` would either revert or
     *         silently strand pool residue. Triggers the standard
     *         `claimRefund(marketId, outcomeIdx)` path for every bettor.
     *         Same per-market oracle authorisation as `resolveMarket`.
     * @param marketId Market to resolve as a refund.
     */
    function resolveAsRefund(bytes32 marketId) external {
        Market storage mkt = markets[marketId];
        if (mkt.status != MarketStatus.OPEN) revert MarketAlreadyResolved();
        if (msg.sender != mkt.resolutionOracle) revert NotMarketOracle();
        if (!hasRole(MARKET_ORACLE_ROLE, msg.sender)) {
            revert NotMarketOracle();
        }
        // solhint-disable-next-line not-rely-on-time, gas-strict-inequalities
        if (block.timestamp < mkt.resolutionDeadline) {
            revert ResolutionDeadlineNotElapsed();
        }
        mkt.status = MarketStatus.CANCELLED;
        emit MarketCancelled(marketId);
    }

    /**
     * @notice Cancel an open market — admin emergency. Refunds via
     *         `claimRefund` become available.
     * @dev Audit H-03 fix — admin cancellation is permitted ONLY
     *      pre-deadline OR after a {CANCEL_GRACE_PERIOD} (7 days)
     *      post-deadline window during which the per-market oracle
     *      retains exclusive resolution authority. This blocks the
     *      cancel-then-front-run admin/oracle collusion vector while
     *      preserving the stuck-oracle rescue path.
     * @param marketId Market to cancel.
     */
    function cancelMarket(bytes32 marketId)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        Market storage mkt = markets[marketId];
        if (mkt.status != MarketStatus.OPEN) revert MarketAlreadyResolved();
        // solhint-disable-next-line not-rely-on-time, gas-strict-inequalities
        if (block.timestamp >= mkt.resolutionDeadline) {
            // Post-deadline: oracle has the grace window. Admin cancel
            // is blocked until CANCEL_GRACE_PERIOD has elapsed (audit H-03).
            uint256 graceEnd = mkt.resolutionDeadline + CANCEL_GRACE_PERIOD;
            // solhint-disable-next-line not-rely-on-time, gas-strict-inequalities
            if (block.timestamp < graceEnd) revert CancelGraceWindowOpen();
        }
        mkt.status = MarketStatus.CANCELLED;
        emit MarketCancelled(marketId);
    }

    // ========================================================================
    // EXTERNAL — CLAIMS (NOT pause-gated; user escape paths)
    // ========================================================================

    /**
     * @notice Claim payout on a resolved market for the caller's
     *         winning shares. One-shot per (caller, market).
     * @dev Computes `payout = encShares × payoutPerShareBps / 10000`
     *      in MPC space (the audit-mentioned `MpcCore.mul` for
     *      share-share-payout) and credits the caller's encrypted XOM
     *      accumulator. If the caller has no shares on the winning
     *      outcome, reverts with `NoSharesOnOutcome` — losers do NOT
     *      forfeit gas to a no-op claim. Uses raw `msg.sender` (audit
     *      M-07) so a malicious forwarder cannot impersonate.
     * @param marketId Resolved market.
     */
    function claimPayout(bytes32 marketId) external nonReentrant {
        Market storage mkt = markets[marketId];
        if (mkt.status != MarketStatus.RESOLVED) revert MarketNotResolved();
        address claimant = msg.sender;
        if (payoutClaimed[claimant][marketId]) revert PayoutAlreadyClaimed();

        uint8 winning = mkt.winningOutcome;
        if (!_hasShares[claimant][marketId][winning]) {
            revert NoSharesOnOutcome();
        }

        gtUint256 sharesG = MpcCore.onBoard(
            encShares[claimant][marketId][winning]
        );
        gtUint256 payoutG = PrivatePredictionMath.payout(
            sharesG,
            uint256(mkt.payoutPerShareBps),
            BASIS_POINTS_DIVISOR
        );

        // Zero the shares slot so a re-claim attempt reverts via the
        // one-shot flag (defence in depth even though `payoutClaimed`
        // already gates this).
        encShares[claimant][marketId][winning] =
            MpcCore.offBoard(MpcCore.setPublic256(0));
        _hasShares[claimant][marketId][winning] = false;

        payoutClaimed[claimant][marketId] = true;
        _accumulateXom(claimant, payoutG);
        emit PayoutClaimed(marketId, claimant);
    }

    /**
     * @notice Refund a stake on a cancelled market for a specific
     *         outcome the caller bet on. One-shot per (caller, market).
     *         Refund is the caller's full encrypted shares for that
     *         outcome (1:1, no fee).
     * @param marketId Cancelled market.
     * @param outcomeIdx Outcome the caller's stake was placed on.
     */
    function claimRefund(bytes32 marketId, uint8 outcomeIdx)
        external
        nonReentrant
    {
        Market storage mkt = markets[marketId];
        if (mkt.status != MarketStatus.CANCELLED) revert MarketNotCancelled();
        address claimant = msg.sender;
        // solhint-disable-next-line gas-strict-inequalities
        if (outcomeIdx >= mkt.outcomeCount) revert InvalidOutcome();
        // Audit H-01 fix — per-outcome refund flag lets a trader who
        // hedged across multiple outcomes recover ALL positions on a
        // cancelled market, not just one.
        if (refundClaimed[claimant][marketId][outcomeIdx]) {
            revert RefundAlreadyClaimed();
        }
        if (!_hasShares[claimant][marketId][outcomeIdx]) {
            revert NoSharesOnOutcome();
        }

        gtUint256 sharesG = MpcCore.onBoard(
            encShares[claimant][marketId][outcomeIdx]
        );

        encShares[claimant][marketId][outcomeIdx] =
            MpcCore.offBoard(MpcCore.setPublic256(0));
        _hasShares[claimant][marketId][outcomeIdx] = false;

        refundClaimed[claimant][marketId][outcomeIdx] = true;
        _accumulateXom(claimant, sharesG);
        emit RefundClaimed(marketId, claimant, outcomeIdx);
    }

    /**
     * @notice Claim accumulated encrypted XOM-side balance.
     * @dev Snapshots the pre-reset ciphertext into the event payload
     *      and increments the per-recipient `claimNonces`. NOT gated
     *      by `whenNotPaused`. Uses raw `msg.sender` (audit M-07).
     */
    function claim() external nonReentrant {
        address claimant = msg.sender;
        if (!_hasUnclaimedXom[claimant]) revert NoBalanceToClaim();

        ctUint256 memory snapshot = encXomBalance[claimant];
        ctUint256 memory zeroCt = MpcCore.offBoard(MpcCore.setPublic256(0));
        encXomBalance[claimant] = zeroCt;
        _hasUnclaimedXom[claimant] = false;

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
     *         {betWithCommittee}.
     * @dev Pioneer Phase admin model (per
     *      `memory/feedback_no_builtin_timelocks.md`): deployer-direct,
     *      zero delay. The existing timelocked setters on this contract
     *      predate the rule clarification and are documented gaps;
     *      new admin setters follow the zero-delay pattern. Once
     *      Pioneer ends, `DEFAULT_ADMIN_ROLE` transitions to
     *      `OmniTimelockController` + governance.
     *
     *      Setting `address(0)` is rejected; to disable the committee
     *      path without unsetting the slot, set a verifier whose
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

    /// @notice Apply the queued forwarder update.
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

    /// @notice Cancel the queued forwarder update.
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

    /// @notice Apply the queued fee-recipient update.
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

    /// @notice Cancel the queued fee-recipient update.
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
    // EXTERNAL — ADMIN (PAUSE + OSSIFICATION + UPGRADE TIMELOCK)
    // ========================================================================

    /// @notice Pause new markets + bets. Claim escape paths still work.
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
     * @notice Queue a UUPS implementation upgrade (audit H-05).
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

    /// @notice Cancel the queued upgrade.
    function cancelPendingUpgrade()
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (pendingUpgrade.effectiveAt == 0) revert TimelockNotRequested();
        address cancelled = pendingUpgrade.newImplementation;
        delete pendingUpgrade;
        emit UpgradeCancelled(cancelled);
    }

    /**
     * @notice Queue a per-market oracle reassignment (audit M-02 fix).
     * @dev Recovery path for an unresponsive or compromised
     *      `resolutionOracle`. Only callable while the market is OPEN.
     *      Replacement oracle must already hold MARKET_ORACLE_ROLE.
     * @param marketId Market whose oracle is being rotated.
     * @param newOracle Replacement oracle address.
     */
    function requestMarketOracleUpdate(
        bytes32 marketId,
        address newOracle
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        Market storage mkt = markets[marketId];
        if (mkt.status != MarketStatus.OPEN) revert MarketAlreadyResolved();
        if (newOracle == address(0)) revert InvalidAddress();
        if (!hasRole(MARKET_ORACLE_ROLE, newOracle)) revert NotMarketOracle();
        if (pendingMarketOracleByMarket[marketId].effectiveAt != 0) {
            revert TimelockAlreadyRequested();
        }
        // solhint-disable-next-line not-rely-on-time
        uint256 effectiveAt = block.timestamp + TIMELOCK_DELAY;
        pendingMarketOracleByMarket[marketId] = PendingMarketOracle({
            newOracle: newOracle,
            effectiveAt: effectiveAt
        });
        emit MarketOracleUpdateQueued(marketId, newOracle, effectiveAt);
    }

    /**
     * @notice Apply the queued per-market oracle reassignment.
     * @param marketId Market whose oracle update to confirm.
     */
    function confirmMarketOracleUpdate(bytes32 marketId)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        PendingMarketOracle memory pending =
            pendingMarketOracleByMarket[marketId];
        if (pending.effectiveAt == 0) revert TimelockNotRequested();
        // solhint-disable-next-line not-rely-on-time, gas-strict-inequalities
        if (block.timestamp < pending.effectiveAt) {
            revert TimelockDelayNotElapsed();
        }
        Market storage mkt = markets[marketId];
        if (mkt.status != MarketStatus.OPEN) revert MarketAlreadyResolved();
        // Re-check role at confirm time (admin may have revoked).
        if (!hasRole(MARKET_ORACLE_ROLE, pending.newOracle)) {
            revert NotMarketOracle();
        }
        address old = mkt.resolutionOracle;
        mkt.resolutionOracle = pending.newOracle;
        delete pendingMarketOracleByMarket[marketId];
        emit MarketOracleUpdated(marketId, old, pending.newOracle);
    }

    /**
     * @notice Cancel the queued per-market oracle reassignment.
     * @param marketId Market whose pending oracle update to cancel.
     */
    function cancelPendingMarketOracleUpdate(bytes32 marketId)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (pendingMarketOracleByMarket[marketId].effectiveAt == 0) {
            revert TimelockNotRequested();
        }
        delete pendingMarketOracleByMarket[marketId];
        emit PendingUpdateCancelled("marketOracle");
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
     *      (audit H-05). Mutates state to clear the pending entry on
     *      success so it cannot be replayed.
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
     * @notice Common bet-execution body shared by {bet} and
     *         {betWithCommittee}. Internal helper.
     * @dev Verifies the trader's EIP-712 signature, enforces nonce
     *      + deadline + market-open invariants, applies the
     *      protocol fee in MPC space, and credits the outcome's
     *      share accumulator. Caller owns relayer or committee
     *      authorisation; the legacy {bet} path verifies the
     *      `ESCROW_ORACLE_ROLE` co-signature before calling here.
     * @param betId Unique bet identifier.
     * @param trader Trader EOA.
     * @param marketId Market the bet targets.
     * @param outcomeIdx Public outcome the trader bets on.
     * @param encStake Encrypted XOM stake (ctUint256).
     * @param escrowProof Off-chain escrow attestation hash.
     * @param traderNonce Expected trader nonce.
     * @param deadline Unix-seconds deadline.
     * @param traderSignature Trader's EIP-712 signature over `BetIntent`.
     */
    function _executeBet( // solhint-disable-line code-complexity
        bytes32 betId,
        address trader,
        bytes32 marketId,
        uint8 outcomeIdx,
        ctUint256 calldata encStake,
        gtUint256 stakeG,
        bytes32 escrowProof,
        uint256 traderNonce,
        uint256 deadline,
        bytes calldata traderSignature
    ) private {
        if (trader == address(0)) revert InvalidAddress();
        // Zero-value stake griefing prevention
        if (MpcCore.decrypt(MpcCore.eq(stakeG, MpcCore.setPublic256(0)))) revert ZeroStake();
        // solhint-disable-next-line not-rely-on-time, gas-strict-inequalities
        if (deadline <= block.timestamp) revert DeadlineExpired();
        if (
            // solhint-disable-next-line not-rely-on-time, gas-strict-inequalities
            deadline > block.timestamp + MAX_BET_DEADLINE
        ) {
            revert DeadlineTooFar();
        }
        if (seenBetIds[betId]) revert BetIdAlreadyUsed();
        if (nonces[trader] != traderNonce) revert InvalidNonce();

        Market storage mkt = markets[marketId];
        if (mkt.status != MarketStatus.OPEN) revert MarketNotOpen();
        // solhint-disable-next-line not-rely-on-time, gas-strict-inequalities
        if (block.timestamp >= mkt.resolutionDeadline) revert MarketNotOpen();
        // solhint-disable-next-line gas-strict-inequalities
        if (outcomeIdx >= mkt.outcomeCount) revert InvalidOutcome();

        bytes32 digest = _betIntentDigest(
            betId,
            trader,
            marketId,
            outcomeIdx,
            encStake,
            escrowProof,
            traderNonce,
            deadline
        );
        if (ECDSA.recover(digest, traderSignature) != trader) {
            revert InvalidSignature();
        }

        unchecked {
            ++nonces[trader];
            ++totalBets;
        }
        seenBetIds[betId] = true;

        // Settlement in MPC space. `stakeG` is resolved by the caller —
        // committee wrapper passes `validateCiphertext(itUint256)` (self-
        // broadcast trader), relayer wrapper passes `onBoard(ctUint256)`.
        (gtUint256 feeG, gtUint256 stakeAfterG) = PrivatePredictionMath.feeSplit(
            stakeG,
            uint256(mkt.betFeeBps),
            BASIS_POINTS_DIVISOR
        );

        _accumulateShares(trader, marketId, outcomeIdx, stakeAfterG);
        _accumulateXom(feeRecipient, feeG);

        emit BetPlaced(betId, trader, marketId, outcomeIdx);
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

    /// @dev Add an encrypted delta to a trader's per-(market,outcome)
    ///      shares accumulator.
    function _accumulateShares(
        address trader,
        bytes32 marketId,
        uint8 outcomeIdx,
        gtUint256 deltaG
    )
        private
    {
        bool hasPrior = _hasShares[trader][marketId][outcomeIdx];
        gtUint256 newG = hasPrior
            ? MpcCore.checkedAdd(
                MpcCore.onBoard(encShares[trader][marketId][outcomeIdx]),
                deltaG
            )
            : deltaG;
        encShares[trader][marketId][outcomeIdx] = MpcCore.offBoard(newG);
        if (!hasPrior) _hasShares[trader][marketId][outcomeIdx] = true;
    }

    /**
     * @notice Compute the EIP-712 digest of a `BetIntent` payload.
     * @dev Extracted so {betWithCommittee} can verify the committee
     *      signed over the SAME digest the trader did, without
     *      re-computing inside the verifier.
     * @param betId Unique bet identifier.
     * @param trader Trader EOA.
     * @param marketId Market the bet targets.
     * @param outcomeIdx Public outcome the trader bets on.
     * @param encStake Encrypted XOM stake (ctUint256).
     * @param escrowProof Off-chain escrow attestation hash.
     * @param traderNonce Expected trader nonce.
     * @param deadline Unix-seconds deadline.
     * @return The EIP-712 digest.
     */
    function _betIntentDigest(
        bytes32 betId,
        address trader,
        bytes32 marketId,
        uint8 outcomeIdx,
        ctUint256 calldata encStake,
        bytes32 escrowProof,
        uint256 traderNonce,
        uint256 deadline
    ) private view returns (bytes32) {
        bytes32 stakeCommit = _commit(encStake);
        bytes32 structHash = keccak256(
            abi.encode(
                BET_INTENT_TYPEHASH,
                betId,
                trader,
                marketId,
                outcomeIdx,
                stakeCommit,
                escrowProof,
                traderNonce,
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
