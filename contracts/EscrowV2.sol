// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MpcCore, gtUint64, ctUint64, gtBool} from "../coti-contracts/contracts/utils/mpc/MpcCore.sol";
import {ERC2771Context} from "@openzeppelin/contracts/metatx/ERC2771Context.sol";
import {Context} from "@openzeppelin/contracts/utils/Context.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IOmniRegistration} from "./interfaces/IOmniRegistration.sol";
import {EscrowFeeRouter} from "./libraries/EscrowFeeRouter.sol";
import {EscrowPrivacyOps} from "./libraries/EscrowPrivacyOps.sol";
import {Escrow} from "./interfaces/EscrowV2Types.sol";

/**
 * @title IFeeVaultTokenAllowlist
 * @author OmniCoin Development Team
 * @notice The ONE list of tokens a marketplace payment may be denominated in.
 * @dev EscrowV2 asks the fee vault rather than keeping its own copy, so a
 *      token can never be escrowable but unsettleable (or the reverse). The
 *      vault's mapping is admin-gated and 48-hour timelocked on chain.
 */
interface IFeeVaultTokenAllowlist {
    /**
     * @notice Whether the vault accepts this token for marketplace settlement
     * @param token ERC-20 address
     * @return allowed True when payments in `token` are accepted
     */
    function supportedPaymentTokens(address token) external view returns (bool);
}

/**
 * @title EscrowV2
 * @author OmniCoin Development Team
 * @notice Ultra-simple 2-of-3 multisig escrow with privacy support via COTI V2 MPC
 * @dev Security-first design prevents arbitrator gaming and frivolous disputes
 *
 * Features:
 * - Public escrow for standard XOM transactions
 * - Private escrow for pXOM with encrypted amounts (COTI network only)
 * - Automatic privacy detection based on chain ID
 * - Graceful degradation on non-COTI networks
 * - Maintains full backward compatibility
 * - ERC2771Context for gasless meta-transactions via OmniForwarder
 *
 * Gasless Support:
 * - All user-facing functions use _msgSender() for gasless relay compatibility
 * - Admin functions (addArbitrator, removeArbitrator, pause, etc.) use msg.sender directly
 * - Commit-reveal pattern works correctly: same user relays both commit and reveal
 *
 * V3 (2026-10-19 — deployed as EscrowV2, token per escrow):
 * - Every escrow records the ERC-20 it holds (`Escrow.token`). v1 could only
 *   hold XOM or pXOM, both fixed at deploy, so a physical or service sale
 *   priced in any other allowlisted token had no escrow path at all.
 * - `createEscrow` / `createEscrowWithReferrers` take the token and require
 *   `UnifiedFeeVault.supportedPaymentTokens(token)` — the same list the
 *   marketplace uses to publish a listing, so a listing that exists can be
 *   escrowed.
 * - Marketplace fees are collected in the escrow's own token; dispute stakes
 *   remain XOM (anti-spam collateral, not sale proceeds).
 * - Private (pXOM) escrows keep their MPC path unchanged and record pXOM as
 *   their token, so `getEscrow`/`getToken` describe them the same way.
 * - The XOM-denominated first-sale bonus is recorded for XOM sales only (see
 *   {_recordFirstSale}).
 *
 * V2 (2026-06-12, founder-approved redeploy — EIP-712 domain version "2"):
 * - createEscrowWithReferrers() captures referrer/referrer2 at creation
 *   (immutable per escrow, anti-fee-wash validated). Legacy
 *   createEscrow(seller, amount, duration) is kept as an XOM-defaulted
 *   overload and defaults both referrers to zero.
 * - On release of a public XOM escrow the 1% marketplace fee is routed via
 *   UnifiedFeeVault.depositMarketplaceFee so the vault performs the canonical
 *   split: 0.50% referral (70/20/10 referrer/referrer2/ODDAO), 0.25%
 *   transaction + 0.25% listing (vault-internal 70/20/10; node attribution is
 *   not available at escrow level, so listing-component recipients are passed
 *   as zero and route to ODDAO per the vault's documented zero-address path).
 *   If the vault call cannot succeed (vault paused, missing DEPOSITOR_ROLE,
 *   sub-minimum sale, non-1% fee config), the full fee falls back to a direct
 *   transfer to FEE_VAULT exactly as in v1 — release can never be blocked by
 *   fee-routing.
 * - Internal commit-reveal arbitration (single resolving arbitrator, used for
 *   private escrows) distributes the 5% arbitration fee 70% direct to the
 *   resolving arbitrator (pull-pattern claimable) and 30% to FEE_VAULT. This
 *   is a distinct single-arbitrator split; the public 3-arbitrator panel
 *   (OmniArbitration) uses its own 90/10 split. The v1 NatSpec claimed a
 *   70/20/10 split that never happened on-chain (100% went to the vault);
 *   v2 makes code and documentation agree.
 */
contract EscrowV2 is ReentrancyGuard, Pausable, ERC2771Context, EIP712 {
    using SafeERC20 for IERC20;
    using MpcCore for gtUint64;
    using MpcCore for ctUint64;
    using MpcCore for gtBool;

    // Type declarations
    // {Escrow} is declared in ./interfaces/EscrowV2Types.sol so the two linked
    // libraries (fee routing, privacy ops) can take a storage pointer to it.

    /// @notice Dispute commitment for commit-reveal pattern
    struct DisputeCommitment {
        bytes32 commitment;
        uint256 revealDeadline;
        bool revealed;
    }

    /// @notice Referral attribution captured at escrow creation
    /// @dev Immutable per escrow (written once in {_createEscrow}, never
    ///      updated). Threaded into UnifiedFeeVault.depositMarketplaceFee
    ///      at release so the 0.50% referral component splits 70/20/10
    ///      referrer / referrer2 / ODDAO. Zero addresses route the
    ///      corresponding share to ODDAO (vault-side behavior).
    struct EscrowReferrers {
        address referrer;   // slot 1: primary referrer
        address referrer2;  // slot 2: second-level referrer
    }

    // Constants
    /// @notice Maximum escrow duration (30 days)
    uint256 public constant MAX_DURATION = 30 days;

    /// @notice Minimum escrow duration (1 hour)
    uint256 public constant MIN_DURATION = 1 hours;

    /// @notice Time before arbitrator can be assigned (24 hours)
    uint256 public constant ARBITRATOR_DELAY = 24 hours;

    /// @notice Buyer inspection window opened when the seller marks an escrow
    ///         delivered, after which the escrow may be permissionlessly
    ///         released to the seller (7 days).
    uint256 public constant INSPECTION_PERIOD = 7 days;

    /// @notice Dispute stake amount (2.5% of escrow — covers half the 5% arbitration fee)
    uint256 public constant DISPUTE_STAKE_BASIS = 250; // 2.5%

    /// @notice Basis points denominator
    uint256 public constant BASIS_POINTS = 10000;

    /// @notice Maximum number of registered arbitrators (M-03: prevent unbounded loop)
    uint256 public constant MAX_ARBITRATORS = 100;

    /// @notice Timeout for unresolved disputes (30 days)
    uint256 public constant DISPUTE_TIMEOUT = 30 days;

    /// @notice Grace period after reveal deadline for stake reclaim (H-02 Round 6)
    uint256 public constant REVEAL_GRACE_PERIOD = 24 hours;

    /// @notice Default marketplace fee (1% = 100 bps)
    uint256 public constant DEFAULT_MARKETPLACE_FEE_BPS = 100;

    /// @notice Maximum marketplace fee cap (5% = 500 bps)
    uint256 public constant MAX_MARKETPLACE_FEE_BPS = 500;

    /// @notice Arbitration fee in basis points (5% = 500 bps)
    /// @dev Per spec: 5% of disputed amount, charged 50/50 from the buyer's
    ///      and seller's dispute stakes. Distribution (V2, honest): 70%
    ///      direct to the single resolving arbitrator via the pull-pattern
    ///      claimable balance, 30% to FEE_VAULT (UnifiedFeeVault). When the
    ///      dispute is resolved by the external OmniArbitration contract
    ///      instead of the internal commit-reveal vote, the full escrow-side
    ///      fee goes to FEE_VAULT because the resolving panel is compensated
    ///      by OmniArbitration's own 90/10 fee distribution (30% per
    ///      arbitrator, 10% to the vault).
    uint256 public constant ARBITRATION_FEE_BPS = 500;

    /// @notice Share of the arbitration fee paid directly to the single
    ///         resolving arbitrator (70% = 7000 bps). Distinct from the
    ///         public 3-arbitrator panel (OmniArbitration), which pays
    ///         30% to each arbitrator and 10% to the vault.
    uint256 public constant ARBITRATOR_FEE_SHARE_BPS = 7000;

    // State variables (immutables first)
    /// @notice OmniCoin token (XOM)
    IERC20 public immutable OMNI_COIN;

    /// @notice Private OmniCoin token (pXOM) for private escrows
    IERC20 public immutable PRIVATE_OMNI_COIN;

    /// @notice Registry contract for service lookups
    address public immutable REGISTRY;

    /// @notice UnifiedFeeVault address that receives the marketplace and
    ///         arbitration fees collected by this contract
    /// @dev V2 fee routing: on release of a public XOM escrow this contract
    ///      approves FEE_VAULT and calls depositMarketplaceFee, which pulls
    ///      the 1% fee and performs the canonical on-chain split
    ///      (founder-ruled 2026-06-12 semantics):
    ///      Referral Fee (0.50%): 70% Referrer, 20% Second-Level Referrer, 10% ODDAO
    ///      Transaction Fee (0.25%): 70% ODDAO, 20% Staking Pool, 10% Protocol Treasury
    ///      Listing Fee (0.25%): 70% Listing Node, 20% Selling Node, 10% ODDAO
    ///      Listing/selling node attribution is not available at escrow
    ///      level, so both are passed as zero and the vault routes those
    ///      shares to ODDAO. If the vault call reverts (paused, role not
    ///      granted, sub-minimum sale) or MARKETPLACE_FEE_BPS != 100, the
    ///      full fee is transferred directly to FEE_VAULT (v1 behavior;
    ///      lands in the vault's undistributed pool). Arbitration fees: 30%
    ///      of the internal commit-reveal fee goes here (70% direct to the
    ///      resolving arbitrator); 100% when resolved via OmniArbitration.
    ///      This contract must hold DEPOSITOR_ROLE on the vault for the
    ///      referral-aware path to activate.
    address public immutable FEE_VAULT;

    /// @notice Marketplace fee in basis points (e.g., 100 = 1%)
    uint256 public immutable MARKETPLACE_FEE_BPS;

    /// @notice Contract admin for arbitrator management + pause/recovery.
    /// @dev Two-step settable (transferAdmin/acceptAdmin) so the admin can be
    ///      handed to the OmniTimelockController at the governance cutover.
    ///      The live pre-handover deploy had this `immutable` (= deployer EOA),
    ///      which cannot be handed over — the reason for this redeploy.
    address public admin;

    /// @notice Pending admin (two-step transfer; must call acceptAdmin).
    address public pendingAdmin;

    // Non-immutable state variables
    /// @notice Total marketplace fees collected per token (for transparency)
    mapping(address => uint256) public totalMarketplaceFees;

    /// @notice Escrow counter for unique IDs
    uint256 public escrowCounter;

    /// @notice Mapping of escrow ID to escrow data
    mapping(uint256 => Escrow) public escrows;

    /// @notice Referral attribution per escrow (set once at creation)
    /// @dev Both addresses zero for unreferred escrows (no storage write).
    mapping(uint256 => EscrowReferrers) public escrowReferrers;

    /// @notice Mapping of escrow ID to voter addresses to votes
    mapping(uint256 => mapping(address => bool)) public hasVoted;

    /// @notice Mapping of escrow ID to dispute commitments
    mapping(uint256 => DisputeCommitment) public disputeCommitments;

    /// @notice Random seed for arbitrator selection
    uint256 private arbitratorSeed;

    /// @notice Registered arbitrator addresses
    address[] public arbitratorList;

    /// @notice Quick lookup for arbitrator status
    mapping(address => bool) public isRegisteredArbitrator;

    /// @notice Dispute stakes held per escrow (escrowId => disputer => stake amount)
    mapping(uint256 => mapping(address => uint256)) public disputeStakes;

    /// @notice Claimable balances for pull-based withdrawal (M-01: DoS protection)
    /// @dev token address => user address => claimable amount
    mapping(address => mapping(address => uint256)) public claimable;

    /// @notice Total tokens held in active escrows per token (for M-07 rescue accounting)
    mapping(address => uint256) public totalEscrowed;

    /// @notice Total tokens in claimable balances per token (M-01: pull-pattern accounting)
    mapping(address => uint256) public totalClaimable;

    // Privacy-related state variables
    /// @notice Encrypted amounts for private escrows (ct = ciphertext for storage)
    mapping(uint256 => ctUint64) private encryptedEscrowAmounts;

    /// @notice Flag indicating if an escrow is private
    mapping(uint256 => bool) public isPrivateEscrow;

    /// @notice Internal plaintext amounts for private escrows (not publicly queryable)
    /// @dev PRIV-H03: Used internally for ERC20 transfers at resolution time.
    ///      Not exposed via any public getter. The encrypted amount is accessible
    ///      via getEncryptedAmount().
    mapping(uint256 => uint256) private privateEscrowAmounts;

    /// @notice Whether privacy features are enabled on this network
    bool private privacyEnabled;

    /// @notice Authorized OmniArbitration contract address
    /// @dev H-01 OmniArbitration Round 6: Only this address may call
    ///      resolveDispute(). Set via setArbitrationContract() by admin.
    address public arbitrationContract;

    // Events
    /// @notice Emitted when escrow is created
    /// @param escrowId Unique escrow identifier
    /// @param buyer Buyer address
    /// @param seller Seller address
    /// @param amount Escrow amount
    /// @param expiry Expiration timestamp
    event EscrowCreated(
        uint256 indexed escrowId,
        address indexed buyer,
        address indexed seller,
        uint256 amount,
        uint256 expiry
    );

    /// @notice Emitted when an escrow's settlement token is recorded
    /// @param escrowId Unique escrow identifier
    /// @param token ERC-20 the escrow holds
    event EscrowToken(uint256 indexed escrowId, address indexed token);

    /// @notice Emitted when fee-attribution nodes are recorded
    /// @param escrowId Unique escrow identifier
    /// @param listingNode Node that hosted the listing (zero = none)
    /// @param sellingNode Node that served the sale (zero = none)
    event EscrowAttribution(
        uint256 indexed escrowId,
        address indexed listingNode,
        address indexed sellingNode
    );

    /// @notice Emitted when referral attribution is captured at creation
    /// @dev Only emitted when at least one referrer is non-zero.
    /// @param escrowId Unique escrow identifier
    /// @param referrer Primary referrer
    /// @param referrer2 Second-level referrer
    event EscrowReferrersSet(
        uint256 indexed escrowId,
        address indexed referrer,
        address indexed referrer2
    );

    /// @notice Emitted when dispute is raised
    /// @param escrowId Escrow identifier
    /// @param disputer Address raising dispute
    /// @param arbitrator Assigned arbitrator
    event DisputeRaised(
        uint256 indexed escrowId,
        address indexed disputer,
        address indexed arbitrator
    );

    /// @notice Emitted when escrow is resolved
    /// @param escrowId Escrow identifier
    /// @param winner Address receiving funds
    /// @param amount Amount released
    event EscrowResolved(
        uint256 indexed escrowId,
        address indexed winner,
        uint256 indexed amount
    );

    /// @notice Emitted when the seller marks an escrow delivered, opening the
    ///         buyer inspection window before permissionless seller-release.
    /// @param escrowId Escrow identifier
    /// @param seller Seller that marked the escrow delivered
    /// @param inspectionDeadline Unix time after which the escrow may be
    ///        permissionlessly released to the seller
    event DeliveryMarked(
        uint256 indexed escrowId,
        address indexed seller,
        uint256 inspectionDeadline
    );

    /// @notice Emitted when vote is cast
    /// @param escrowId Escrow identifier
    /// @param voter Address casting vote
    /// @param voteFor True if voting for release, false for refund
    event VoteCast(
        uint256 indexed escrowId,
        address indexed voter,
        bool indexed voteFor
    );

    /// @notice Emitted when private escrow is created
    /// @param escrowId Unique escrow identifier
    /// @param buyer Buyer address
    /// @param seller Seller address
    /// @param expiry Expiration timestamp
    /// @dev Amount not revealed for privacy
    event PrivateEscrowCreated(
        uint256 indexed escrowId,
        address indexed buyer,
        address indexed seller,
        uint256 expiry
    );

    /// @notice Emitted when private escrow is resolved
    /// @param escrowId Escrow identifier
    /// @param winner Address receiving funds
    /// @dev Amount not revealed for privacy
    event PrivateEscrowResolved(uint256 indexed escrowId, address indexed winner);

    /// @notice Emitted when private dispute is raised
    /// @param escrowId Escrow identifier
    /// @param disputer Address raising dispute
    /// @param arbitrator Assigned arbitrator
    event PrivateDisputeRaised(
        uint256 indexed escrowId,
        address indexed disputer,
        address indexed arbitrator
    );

    /// @notice Emitted when a dispute commitment is made (step 1 of commit-reveal)
    /// @param escrowId Escrow identifier
    /// @param committer Address that committed
    /// @param commitment Commitment hash
    event DisputeCommitted(
        uint256 indexed escrowId,
        address indexed committer,
        bytes32 indexed commitment
    );

    /// @notice Emitted when arbitrator is added to registry
    /// @param arbitrator Address of the new arbitrator
    event ArbitratorAdded(address indexed arbitrator);

    /// @notice Emitted when arbitrator is removed from registry
    /// @param arbitrator Address of the removed arbitrator
    event ArbitratorRemoved(address indexed arbitrator);

    /// @notice Emitted when dispute stake is returned
    /// @param escrowId Escrow identifier
    /// @param disputer Address receiving stake back
    /// @param amount Stake amount returned
    event DisputeStakeReturned(
        uint256 indexed escrowId,
        address indexed disputer,
        uint256 indexed amount
    );

    /// @notice Emitted when marketplace fee is collected on escrow release
    /// @param escrowId Escrow identifier
    /// @param feeCollector Address receiving the fee
    /// @param feeAmount Fee amount collected
    event MarketplaceFeeCollected(
        uint256 indexed escrowId,
        address indexed feeCollector,
        uint256 indexed feeAmount
    );

    /// @notice Emitted when a fee owed to FEE_VAULT could not be transferred
    ///         because the token refused it. The amount stays in the contract
    ///         as protocol surplus instead of blocking a settlement.
    /// @param token Token that refused the transfer
    /// @param amount Amount left in the contract
    event FeeTransferDeferred(address indexed token, uint256 indexed amount);

    /// @notice Emitted when a marketplace fee transfer is waived. Settlement is
    ///         never blocked by fee routing; the protocol forgoes the fee
    ///         (which stays in the contract as surplus) rather than the sale.
    /// @param escrowId Escrow identifier
    /// @param token Escrow token whose fee could not be transferred
    /// @param feeAmount Fee that was waived (retained as protocol surplus)
    event MarketplaceFeeWaived(
        uint256 indexed escrowId,
        address indexed token,
        uint256 indexed feeAmount
    );

    /// @notice Emitted when arbitration fee is deducted from disputed escrow resolution
    /// @param escrowId Escrow identifier
    /// @param totalArbitrationFee Total arbitration fee collected
    /// @param arbitratorShare Amount credited to the resolving arbitrator's
    ///        claimable balance (70%; zero when resolved via OmniArbitration,
    ///        whose panel is paid by OmniArbitration's own fee). Remainder
    ///        (totalArbitrationFee - arbitratorShare) is sent to FEE_VAULT.
    event ArbitrationFeeCollected(
        uint256 indexed escrowId,
        uint256 totalArbitrationFee,
        uint256 arbitratorShare
    );

    /// @notice Emitted when funds are credited to pull-based claimable balance (M-01)
    /// @param user Address receiving the claimable credit
    /// @param token Token address credited
    /// @param amount Amount credited
    event FundsClaimable(
        address indexed user,
        address indexed token,
        uint256 indexed amount
    );

    /// @notice Emitted when a user withdraws from their claimable balance (M-01)
    /// @param user Address withdrawing
    /// @param token Token address withdrawn
    /// @param amount Amount withdrawn
    event FundsClaimed(
        address indexed user,
        address indexed token,
        uint256 indexed amount
    );

    /// @notice Emitted when the counterparty posts a matching dispute stake
    /// @param escrowId Escrow identifier
    /// @param party Address posting the counter-stake
    /// @param amount Stake amount
    event CounterpartyStakePosted(
        uint256 indexed escrowId,
        address indexed party,
        uint256 amount
    );

    /// @notice Emitted when OmniArbitration resolves a dispute
    /// @param escrowId Escrow identifier
    /// @param releasedToSeller True if funds released to seller
    /// @param recipient Address receiving funds
    /// @param amount Amount resolved
    event DisputeResolvedByArbitration(
        uint256 indexed escrowId,
        bool indexed releasedToSeller,
        address indexed recipient,
        uint256 amount
    );

    /// @notice Emitted when the arbitration contract address is set
    /// @param oldArbitration Previous arbitration contract address
    /// @param newArbitration New arbitration contract address
    event ArbitrationContractUpdated(
        address indexed oldArbitration,
        address indexed newArbitration
    );

    /// @notice Emitted when the authorized OmniArbitration contract marks
    ///         an escrow disputed because a judge-panel dispute was opened
    /// @dev Set once per escrow at OmniArbitration.createDispute time. Blocks
    ///      every party-unilateral exit (refundBuyer, releaseFundsViaContract)
    ///      until the panel resolves the dispute via resolveDispute().
    /// @param escrowId Escrow identifier marked disputed
    event EscrowMarkedDisputed(uint256 indexed escrowId);

    /// @notice Emitted when a panel dispute is cancelled before resolution
    /// @param escrowId Escrow identifier
    event EscrowUnmarkedDisputed(uint256 indexed escrowId);

    // Custom errors
    error InvalidAddress();
    /// @notice Escrow token is not on the fee vault's payment allowlist
    error TokenNotSupported();
    /// @notice The token moved a different amount than it reported (fee-on-transfer / rebasing)
    error TokenTransferMismatch();
    /// @notice The vault's allowlist could not be read (RPC/upgrade failure)
    error AllowlistUnavailable();
    /// @notice This escrow must resolve through the internal 2-of-3 vote, not the panel
    error UseInternalArbitration();
    /// @notice A fee-attribution node collides with a party or the other node
    error BadAttribution();
    error InvalidFeeConfig();
    error InvalidAmount();
    error InvalidDuration();
    error EscrowNotFound();
    error EscrowExpired();
    error AlreadyVoted();
    error NotParticipant();
    error AlreadyResolved();
    error DisputeTooEarly();
    error InvalidCommitment();
    error RevealDeadlinePassed();
    error AlreadyDisputed();
    /// @notice The escrow has already been marked delivered by the seller.
    error AlreadyDelivered();
    /// @notice The escrow has not been marked delivered by the seller.
    error NotDelivered();
    /// @notice The buyer inspection window has not yet elapsed.
    error InspectionPending();
    /// @notice Permissionless seller-release is unavailable for private escrows.
    error PrivateEscrowUnsupported();
    error InsufficientStake();
    error PrivacyNotAvailable();
    error CannotMixPrivacyModes();
    error AmountTooLarge();
    error NoArbitratorsAvailable();
    error OnlyAdmin();
    error NotPendingAdmin();
    error NotDisputed();
    error StakeAlreadyPosted();
    error TooManyArbitrators();
    error EscrowNotExpired();

    /// @notice Caller is not the authorized arbitration contract
    error OnlyArbitrationContract();
    error NothingToClaim();

    /// @notice Referrer slot collides with buyer/seller, or referrer2
    ///         collides with buyer/seller/referrer (anti-fee-wash)
    error BadReferrer();

    /// @notice A previous dispute commit has not been reclaimed; call reclaimExpiredStake() first
    error PreviousCommitNotReclaimed();

    /// @notice When an arbitration contract is set, internal vote resolution must defer to it
    error UseArbitrationContract();

    // ──────────────────────────────────────────────────────────────────────
    // Errors specific to {releaseFundsViaContract} (P1-A / Phase 4.x).
    // ──────────────────────────────────────────────────────────────────────

    /// @notice Caller of {releaseFundsViaContract} differs from the address
    ///         the buyer authorized in the signed payload's `callerContract`
    ///         field. Prevents a different contract from front-running the
    ///         buyer's sig.
    error CallerNotAuthorized();

    /// @notice The signature's `deadline` has passed. Buyer must re-sign.
    error DeadlinePassed();

    /// @notice ECDSA recovery from the supplied signature did not yield
    ///         `escrow.buyer`. Either tampering or wrong signer.
    error InvalidSignature();

    /// @notice EIP-712 type hash for the `ReleaseFundsBySig` payload.
    /// @dev Keccak256 of the exact human-readable type string. Used by
    ///      {releaseFundsViaContract} to recover the buyer's signer
    ///      address from a wallet-built EIP-712 typed-data signature.
    ///      The buyer signs over (escrowId, callerContract, deadline);
    ///      no per-buyer nonce is needed because `escrow.resolved` acts
    ///      as the single-consumption flag (a release sig commits to a
    ///      specific escrowId; once resolved the escrow can never be
    ///      re-released).
    bytes32 public constant RELEASE_FUNDS_BY_SIG_TYPEHASH = keccak256(
        "ReleaseFundsBySig(uint256 escrowId,address callerContract,uint256 deadline)"
    );

    /// @notice Restrict to admin only
    modifier onlyAdmin() {
        if (msg.sender != admin) revert OnlyAdmin();
        _;
    }

    /// @notice Restrict to authorized OmniArbitration contract
    /// @dev H-01 OmniArbitration Round 6: Only the registered
    ///      arbitration contract may call resolveDispute().
    modifier onlyArbitration() {
        if (msg.sender != arbitrationContract) {
            revert OnlyArbitrationContract();
        }
        _;
    }

    /**
     * @param _omniCoin OmniCoin token address (XOM)
     * @param _privateOmniCoin Private OmniCoin token address (pXOM)
     * @param _registry Registry contract address
     * @param _feeVault UnifiedFeeVault address that receives all marketplace
     *        and arbitration fees for on-chain 70/20/10 distribution
     * @param _marketplaceFeeBps Fee in basis points (e.g. 100 = 1%)
     * @param trustedForwarder_ OmniForwarder address for gasless relay (address(0) to disable)
     */
    /// @dev AUDIT ACCEPTED (Round 6): The trusted forwarder address is immutable by design.
    ///      ERC-2771 forwarder immutability is standard practice (OpenZeppelin default).
    ///      Changing the forwarder post-deployment would break all existing meta-transaction
    ///      infrastructure. If the forwarder is compromised, ossify() + governance pause
    ///      provides emergency protection. A new proxy can be deployed if needed.
    constructor(
        address _omniCoin,
        address _privateOmniCoin,
        address _registry,
        address _feeVault,
        uint256 _marketplaceFeeBps,
        address trustedForwarder_
    )
        ERC2771Context(trustedForwarder_)
        EIP712("OmniBazaar EscrowV2", "3")
    {
        if (
            _omniCoin == address(0) ||
            _privateOmniCoin == address(0) ||
            _registry == address(0) ||
            _feeVault == address(0)
        ) {
            revert InvalidAddress();
        }
        if (_marketplaceFeeBps > MAX_MARKETPLACE_FEE_BPS) {
            revert InvalidFeeConfig();
        }
        // 🛑 The canonical 1% split lives in UnifiedFeeVault.depositMarketplaceFee
        // (it pulls saleAmount / 100). Any other value here silently falls back
        // to an undistributed transfer and loses the entire referral split, and
        // 0 disables the marketplace fee altogether. Pin it.
        if (_marketplaceFeeBps != DEFAULT_MARKETPLACE_FEE_BPS) {
            revert InvalidFeeConfig();
        }
        if (_feeVault.code.length == 0) revert InvalidAddress();
        OMNI_COIN = IERC20(_omniCoin);
        PRIVATE_OMNI_COIN = IERC20(_privateOmniCoin);
        REGISTRY = _registry;
        FEE_VAULT = _feeVault;
        MARKETPLACE_FEE_BPS = _marketplaceFeeBps;
        admin = msg.sender;

        // solhint-disable-next-line not-rely-on-time
        arbitratorSeed = uint256(keccak256(abi.encodePacked(
            block.timestamp,
            block.prevrandao
        )));

        // Detect if privacy is available (COTI network check)
        privacyEnabled = _detectPrivacyAvailability();
    }

    /**
     * @notice Create a new escrow in a caller-chosen token
     * @dev Buyer creates escrow with seller address, token and amount. Both
     *      referrer slots default to zero (the referral component of the
     *      release fee routes to ODDAO inside the vault).
     *
     *      `token` MUST be on UnifiedFeeVault.supportedPaymentTokens — the same
     *      list the marketplace uses to publish a listing, so a listing that
     *      exists can always be escrowed. Zero addresses and tokens without
     *      code are rejected.
     * @param seller Seller address
     * @param token ERC-20 to escrow (XOM, bridged USDC, …)
     * @param amount Amount of `token` in its smallest unit
     * @param duration Escrow duration in seconds
     * @return escrowId Unique escrow identifier
     */
    function createEscrow(
        address seller,
        address token,
        uint256 amount,
        uint256 duration
    ) external nonReentrant whenNotPaused returns (uint256 escrowId) {
        return _createEscrow(
            seller,
            token,
            amount,
            duration,
            address(0),
            address(0),
            address(0),
            address(0)
        );
    }

    /**
     * @notice Create a new XOM escrow (legacy v1 signature)
     * @dev Preserved so a client that still encodes the v1 selector keeps
     *      working. XOM is the default token; any other asset must use the
     *      token-taking overload.
     * @param seller Seller address
     * @param amount Amount of XOM wei to escrow
     * @param duration Escrow duration in seconds
     * @return escrowId Unique escrow identifier
     */
    function createEscrow(
        address seller,
        uint256 amount,
        uint256 duration
    ) external nonReentrant whenNotPaused returns (uint256 escrowId) {
        return _createEscrow(
            seller,
            address(OMNI_COIN),
            amount,
            duration,
            address(0),
            address(0),
            address(0),
            address(0)
        );
    }

    /**
     * @notice Create a new escrow with two-level referral attribution
     * @dev V2 entry point. Referrers are captured once at creation and are
     *      immutable for the escrow's lifetime. Anti-fee-wash rules mirror
     *      UnifiedFeeVault._validateReferrerPair: a non-zero referrer must
     *      not equal buyer or seller; a non-zero referrer2 must not equal
     *      buyer, seller, or referrer. Zero addresses are allowed and route
     *      the corresponding referral share to ODDAO at release.
     * @param seller Seller address
     * @param token ERC-20 to escrow (must be vault-allowlisted)
     * @param amount Amount of `token` in its smallest unit
     * @param duration Escrow duration in seconds
     * @param referrer Primary referrer (zero if none)
     * @param referrer2 Second-level referrer (zero if none)
     * @return escrowId Unique escrow identifier
     */
    function createEscrowWithReferrers(
        address seller,
        address token,
        uint256 amount,
        uint256 duration,
        address referrer,
        address referrer2
    ) external nonReentrant whenNotPaused returns (uint256 escrowId) {
        return _createEscrow(
            seller,
            token,
            amount,
            duration,
            referrer,
            referrer2,
            address(0),
            address(0)
        );
    }

    /**
     * @notice Create an escrow with fee-attribution nodes (no referrers)
     * @dev The listing row carries the nodes that earned the listing slice of
     *      the 1% fee. Without passing them, that slice routes to ODDAO inside
     *      the vault (v1 behaviour). The addresses are attribution CLAIMS by
     *      the caller, exactly like the referrer slots: they must be distinct
     *      from the buyer, the seller and each other, but the contract cannot
     *      prove the listing was really hosted by them.
     * @param seller Seller address
     * @param token ERC-20 to escrow (allowlisted)
     * @param amount Amount in the token's smallest unit
     * @param duration Escrow duration in seconds
     * @param listingNode Node that hosted the listing (zero = none)
     * @param sellingNode Node that served the sale (zero = none)
     * @return escrowId Unique escrow identifier
     */
    function createEscrowWithAttribution(
        address seller,
        address token,
        uint256 amount,
        uint256 duration,
        address listingNode,
        address sellingNode
    ) external nonReentrant whenNotPaused returns (uint256 escrowId) {
        return _createEscrow(
            seller,
            token,
            amount,
            duration,
            address(0),
            address(0),
            listingNode,
            sellingNode
        );
    }

    /**
     * @notice Create an escrow with referrers AND fee-attribution nodes
     * @dev The complete attribution set, so one escrow carries every recipient
     *      of the 1% marketplace fee.
     * @param seller Seller address
     * @param token ERC-20 to escrow (allowlisted)
     * @param amount Amount in the token's smallest unit
     * @param duration Escrow duration in seconds
     * @param referrer Primary referrer (zero if none)
     * @param referrer2 Second-level referrer (zero if none)
     * @param listingNode Node that hosted the listing (zero = none)
     * @param sellingNode Node that served the sale (zero = none)
     * @return escrowId Unique escrow identifier
     */
    function createEscrowWithReferrersAndNodes(
        address seller,
        address token,
        uint256 amount,
        uint256 duration,
        address referrer,
        address referrer2,
        address listingNode,
        address sellingNode
    ) external nonReentrant whenNotPaused returns (uint256 escrowId) {
        return _createEscrow(
            seller,
            token,
            amount,
            duration,
            referrer,
            referrer2,
            listingNode,
            sellingNode
        );
    }

    /**
     * @notice Create a new XOM escrow with referral attribution (legacy v1 signature)
     * @dev Preserved for clients that encode the v1 selector; defaults the
     *      token to XOM. Use the token-taking overload for any other asset.
     * @param seller Seller address
     * @param amount Amount of XOM wei to escrow
     * @param duration Escrow duration in seconds
     * @param referrer Primary referrer (zero if none)
     * @param referrer2 Second-level referrer (zero if none)
     * @return escrowId Unique escrow identifier
     */
    function createEscrowWithReferrers(
        address seller,
        uint256 amount,
        uint256 duration,
        address referrer,
        address referrer2
    ) external nonReentrant whenNotPaused returns (uint256 escrowId) {
        return _createEscrow(
            seller,
            address(OMNI_COIN),
            amount,
            duration,
            referrer,
            referrer2,
            address(0),
            address(0)
        );
    }

    /**
     * @notice Shared escrow-creation body
     * @dev Validates parties + referrer pair + token allowlist, pulls the
     *      escrow token, writes the escrow record and (when present) the
     *      referral attribution.
     * @param seller Seller address
     * @param token ERC-20 to escrow (must be vault-allowlisted)
     * @param amount Amount of `token` in its smallest unit
     * @param duration Escrow duration in seconds
     * @param referrer Primary referrer (zero if none)
     * @param referrer2 Second-level referrer (zero if none)
     * @return escrowId Unique escrow identifier
     */
    function _createEscrow(
        address seller,
        address token,
        uint256 amount,
        uint256 duration,
        address referrer,
        address referrer2,
        address listingNode,
        address sellingNode
    ) private returns (uint256 escrowId) {
        address buyer = _msgSender();
        if (seller == address(0) || seller == buyer || seller == address(this)) {
            revert InvalidAddress();
        }
        if (amount == 0) revert InvalidAmount();
        if (duration < MIN_DURATION || duration > MAX_DURATION) revert InvalidDuration();
        _requireSupportedToken(token);

        _validateReferrerPair(buyer, seller, referrer, referrer2);
        _validateAttributionNodes(
            buyer,
            seller,
            referrer,
            referrer2,
            listingNode,
            sellingNode
        );

        // A fee that floors to zero would let a seller split sales into
        // sub-100-unit escrows and pay nothing. One unit of the smallest
        // denominator is the floor at which the 1% is actually collectible.
        if (amount < _minEscrowAmount()) revert InvalidAmount();

        // Credit only what actually ARRIVED (see {_pullExact}).
        _pullExact(IERC20(token), buyer, amount);
        totalEscrowed[token] += amount;

        escrowId = ++escrowCounter;

        escrows[escrowId] = Escrow({
            buyer: buyer,
            seller: seller,
            arbitrator: address(0),
            amount: amount,
            expiry: block.timestamp + duration, // solhint-disable-line not-rely-on-time
            createdAt: block.timestamp, // solhint-disable-line not-rely-on-time
            releaseVotes: 0,
            refundVotes: 0,
            resolved: false,
            disputed: false,
            delivered: false,
            inspectionDeadline: 0,
            token: token,
            listingNode: listingNode,
            sellingNode: sellingNode
        });

        emit EscrowToken(escrowId, token);
        emit EscrowAttribution(escrowId, listingNode, sellingNode);

        if (referrer != address(0) || referrer2 != address(0)) {
            escrowReferrers[escrowId] = EscrowReferrers({
                referrer: referrer,
                referrer2: referrer2
            });
            emit EscrowReferrersSet(escrowId, referrer, referrer2);
        }

        emit EscrowCreated(escrowId, buyer, seller, amount, escrows[escrowId].expiry);
    }

    /**
     * @notice Release funds to seller (happy path)
     * @dev Both buyer and seller must agree
     * @param escrowId Escrow to release
     */
    function releaseFunds(uint256 escrowId) external nonReentrant whenNotPaused {
        Escrow storage escrow = escrows[escrowId];

        if (isPrivateEscrow[escrowId]) revert CannotMixPrivacyModes();
        if (escrow.buyer == address(0)) revert EscrowNotFound();
        if (escrow.resolved) revert AlreadyResolved();
        // A disputed escrow resolves only through its dispute path (panel
        // resolveDispute or internal 2-of-3 vote), never a unilateral release.
        // Mirror refundBuyer / releaseFundsViaContract: an explicit, actionable
        // revert instead of a swallowed success no-op, so the three
        // party-unilateral exits behave consistently on a disputed escrow.
        if (escrow.disputed) revert AlreadyDisputed();
        // L-05: Only buyer can release funds to seller
        if (_msgSender() != escrow.buyer) revert NotParticipant();

        // Simple 2-party agreement (undisputed release by buyer). The
        // `disputed` case reverted above, so this always runs on a
        // non-disputed escrow.
        escrow.resolved = true;
        uint256 amount = escrow.amount;
        escrow.amount = 0;

        totalEscrowed[escrow.token] -= amount;

        // Deduct marketplace fee before paying seller (referral-aware)
        uint256 sellerAmount = _collectMarketplaceFee(escrowId, escrow.token, amount);
        IERC20(escrow.token).safeTransfer(escrow.seller, sellerAmount);
        emit EscrowResolved(escrowId, escrow.seller, sellerAmount);

        // Best-effort first-sale bonus credit (see {_recordFirstSale}).
        _recordFirstSale(escrow.seller, escrow.token, amount, escrow.buyer);
    }

    /**
     * @notice Release funds to seller via a contract acting on behalf of
     *         the buyer, authenticated by a buyer-signed EIP-712 payload.
     *
     * @dev Designed for atomic-settlement contracts (e.g.
     *      `NFTMarketplaceEscrow`) that need to release escrow funds AND
     *      perform a paired action (NFT `transferFrom`) in a single
     *      transaction the buyer signs once.
     *
     *      The buyer pre-signs a `ReleaseFundsBySig` typed-data payload
     *      that commits to:
     *        - the specific `escrowId` being released,
     *        - the specific `callerContract` authorized to invoke this
     *          (so the sig can never be replayed via a different
     *          contract),
     *        - a `deadline` (so stale sigs can't be submitted
     *          indefinitely).
     *
     *      Sig is consumed implicitly: once this succeeds,
     *      `escrow.resolved == true` and any replay reverts at
     *      `AlreadyResolved`. No per-buyer monotonic nonce is needed
     *      (per design doc decision: per-escrow boolean via existing
     *      resolved flag).
     *
     *      Settlement body is identical to {releaseFunds}: collect
     *      marketplace fee, transfer remainder to seller, emit
     *      `EscrowResolved`. Disputed escrows are rejected — the
     *      arbitration path must run instead.
     *
     *      Re-entrancy: `nonReentrant`. State writes precede every
     *      `safeTransfer` (CEI). Domain separator is the standard
     *      OpenZeppelin EIP-712 v4 separator bound at construction.
     *
     * @param escrowId       Escrow to release. Must exist and not be
     *                       already resolved or disputed.
     * @param callerContract Address the buyer authorized to invoke this
     *                       function. Must equal `msg.sender`. Allows
     *                       a buyer to delegate release authority to
     *                       exactly one settlement contract per signed
     *                       payload.
     * @param deadline       Unix-seconds expiry of the signature. Must
     *                       be in the future (block.timestamp ≤ deadline).
     * @param signature      65-byte ECDSA signature over the EIP-712
     *                       digest of `ReleaseFundsBySig(escrowId,
     *                       callerContract, deadline)` produced by the
     *                       escrow.buyer wallet.
     */
    function releaseFundsViaContract(
        uint256 escrowId,
        address callerContract,
        uint256 deadline,
        bytes calldata signature
    ) external nonReentrant whenNotPaused {
        Escrow storage escrow = escrows[escrowId];

        if (isPrivateEscrow[escrowId]) revert CannotMixPrivacyModes();
        if (escrow.buyer == address(0)) revert EscrowNotFound();
        if (escrow.resolved) revert AlreadyResolved();
        if (escrow.disputed) revert AlreadyDisputed();
        if (_msgSender() != callerContract) revert CallerNotAuthorized();
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp > deadline) revert DeadlinePassed();

        // Verify EIP-712 signature against the escrow's recorded buyer.
        // Using OpenZeppelin's `_hashTypedDataV4` ensures the digest
        // matches what the wallet computes when the buyer signs via
        // `eth_signTypedData_v4`.
        bytes32 structHash = keccak256(
            abi.encode(
                RELEASE_FUNDS_BY_SIG_TYPEHASH,
                escrowId,
                callerContract,
                deadline
            )
        );
        bytes32 digest = _hashTypedDataV4(structHash);
        address recovered = ECDSA.recover(digest, signature);
        if (recovered != escrow.buyer) revert InvalidSignature();

        // Execute the same settlement body as {releaseFunds}. State
        // writes precede the safeTransfer (CEI), mirroring
        // {releaseFunds} verbatim so dispute/resolution accounting
        // stays in lock-step.
        escrow.resolved = true;
        uint256 amount = escrow.amount;
        escrow.amount = 0;

        totalEscrowed[escrow.token] -= amount;

        uint256 sellerAmount = _collectMarketplaceFee(escrowId, escrow.token, amount);
        IERC20(escrow.token).safeTransfer(escrow.seller, sellerAmount);
        emit EscrowResolved(escrowId, escrow.seller, sellerAmount);

        // Best-effort first-sale bonus credit (see {_recordFirstSale}).
        _recordFirstSale(escrow.seller, escrow.token, amount, escrow.buyer);
    }

    /**
     * @notice Seller marks an escrow delivered, opening the buyer's inspection
     *         window ({INSPECTION_PERIOD}).
     * @dev Fixes the silent-buyer gap: after delivery the seller no longer
     *      depends on the buyer's action (nor loses funds to the buyer's
     *      post-expiry self-refund) to be paid. Once delivered, the buyer's
     *      exits are an explicit {releaseFunds} approval or opening a dispute
     *      within the inspection window — the post-expiry refund path in
     *      {refundBuyer} is closed for delivered escrows. Seller-only; a
     *      resolved, disputed, or already-delivered escrow reverts.
     * @param escrowId The escrow to mark delivered.
     */
    function markDelivered(uint256 escrowId) external whenNotPaused {
        Escrow storage escrow = escrows[escrowId];

        if (escrow.buyer == address(0)) revert EscrowNotFound();
        // Private escrows have no permissionless seller-release path
        // (releaseExpiredToSeller rejects them), so a delivery flag would only
        // remove the buyer's expiry refund without giving the seller anything.
        if (isPrivateEscrow[escrowId]) revert PrivateEscrowUnsupported();
        if (escrow.resolved) revert AlreadyResolved();
        if (escrow.disputed) revert AlreadyDisputed();
        if (escrow.delivered) revert AlreadyDelivered();
        if (_msgSender() != escrow.seller) revert NotParticipant();

        escrow.delivered = true;
        // solhint-disable-next-line not-rely-on-time
        uint256 deadline = block.timestamp + INSPECTION_PERIOD;
        escrow.inspectionDeadline = deadline;

        emit DeliveryMarked(escrowId, escrow.seller, deadline);
    }

    /**
     * @notice Permissionlessly release a delivered, undisputed escrow to the
     *         seller once the buyer's inspection window has elapsed.
     * @dev The seller-protection counterpart to the buyer's post-expiry
     *      {refundBuyer}. Anyone may call it (the seller, or a keeper) — it
     *      moves funds only to the recorded seller and only when the escrow is
     *      delivered, not disputed, not resolved, and past `inspectionDeadline`.
     *      The settlement body is identical to {releaseFunds}: collect the
     *      referral-aware marketplace fee and transfer the remainder to the
     *      seller. Private escrows settle their encrypted amounts on a separate
     *      path and revert here with {PrivateEscrowUnsupported}.
     * @param escrowId The escrow to release to the seller.
     */
    function releaseExpiredToSeller(uint256 escrowId)
        external
        nonReentrant
        whenNotPaused
    {
        Escrow storage escrow = escrows[escrowId];

        if (escrow.buyer == address(0)) revert EscrowNotFound();
        if (escrow.resolved) revert AlreadyResolved();
        if (escrow.disputed) revert AlreadyDisputed();
        if (isPrivateEscrow[escrowId]) revert PrivateEscrowUnsupported();
        if (!escrow.delivered) revert NotDelivered();
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp <= escrow.inspectionDeadline) {
            revert InspectionPending();
        }

        // Settlement body identical to {releaseFunds} (CEI: all state writes
        // precede the token transfer).
        escrow.resolved = true;
        uint256 amount = escrow.amount;
        escrow.amount = 0;

        totalEscrowed[escrow.token] -= amount;

        uint256 sellerAmount = _collectMarketplaceFee(escrowId, escrow.token, amount);
        IERC20(escrow.token).safeTransfer(escrow.seller, sellerAmount);
        emit EscrowResolved(escrowId, escrow.seller, sellerAmount);

        // Best-effort first-sale bonus credit (see {_recordFirstSale}).
        _recordFirstSale(escrow.seller, escrow.token, amount, escrow.buyer);
    }

    /**
     * @notice Refund to buyer (seller agrees or timeout)
     * @dev Seller can agree or buyer can claim after expiry
     * @param escrowId Escrow to refund
     */
    function refundBuyer(uint256 escrowId) external nonReentrant {
        Escrow storage escrow = escrows[escrowId];

        if (isPrivateEscrow[escrowId]) revert CannotMixPrivacyModes();
        if (escrow.buyer == address(0)) revert EscrowNotFound();
        if (escrow.resolved) revert AlreadyResolved();
        // A disputed escrow is resolved exclusively through its dispute path
        // (internal 2-of-3 vote or the external OmniArbitration judge panel),
        // never by a unilateral refund. Reverting here closes the refund race:
        // once markDisputed() (panel) or revealDispute() (internal) sets the
        // flag, neither party can drain the escrow while resolution is pending,
        // so a winning seller can no longer lose principal to a buyer's
        // post-expiry self-refund. Explicit revert (was a silent no-op) gives
        // the caller an actionable error instead of a swallowed refund.
        if (escrow.disputed) revert AlreadyDisputed();
        address caller = _msgSender();
        // M-04: Only buyer or seller can trigger refund (prevents griefing by third parties)
        if (caller != escrow.buyer && caller != escrow.seller) revert NotParticipant();

        // The `disputed` case already reverted above, so every branch below
        // runs only on a non-disputed escrow.
        bool canRefund = false;

        // Seller agrees to refund
        if (caller == escrow.seller) {
            canRefund = true;
        }

        // Expired refund — only the buyer can claim it. Additionally gated on
        // the seller's dispute window having opened (createdAt +
        // ARBITRATOR_DELAY): without this, a buyer who picks a duration shorter
        // than ARBITRATOR_DELAY (allowed: MIN_DURATION is 1h) could let the
        // escrow expire and reclaim funds before the seller is ever able to
        // commit a dispute, leaving a delivering seller with no recourse.
        // Also gated on `!delivered`: once the seller has marked the escrow
        // delivered (opening the buyer's inspection window), the buyer can no
        // longer silently reclaim funds on expiry — the honest exit is an
        // explicit {releaseFunds} or a dispute within the window, which is what
        // protects a delivering seller from a passive buyer.
        // solhint-disable-next-line not-rely-on-time
        if (
            caller == escrow.buyer
            && block.timestamp > escrow.expiry
            && block.timestamp >= escrow.createdAt + ARBITRATOR_DELAY
            && !escrow.delivered
        ) {
            canRefund = true;
        }

        if (canRefund) {
            escrow.resolved = true;
            uint256 amount = escrow.amount;
            escrow.amount = 0;

            totalEscrowed[escrow.token] -= amount;
            IERC20(escrow.token).safeTransfer(escrow.buyer, amount);
            emit EscrowResolved(escrowId, escrow.buyer, amount);
        }
    }

    /**
     * @notice Commit to raising a dispute (step 1 of commit-reveal)
     * @dev Prevents front-running arbitrator selection
     * @param escrowId Escrow to dispute
     * @param commitment Hash of (escrowId, nonce, msg.sender)
     */
    function commitDispute(uint256 escrowId, bytes32 commitment) external nonReentrant whenNotPaused {
        if (commitment == bytes32(0)) revert InvalidAmount(); // L-04: reject zero commitment
        Escrow storage escrow = escrows[escrowId];

        if (escrow.buyer == address(0)) revert EscrowNotFound();
        if (escrow.resolved) revert AlreadyResolved();
        if (escrow.disputed) revert AlreadyDisputed();
        address caller = _msgSender();
        if (caller != escrow.buyer && caller != escrow.seller) revert NotParticipant();

        // v2: once the external judge panel (OmniArbitration) is connected,
        // PUBLIC disputes go through it (deposit-backed random committee). The
        // judge panel cannot price a private-coin escrow (its value is hidden,
        // so the panel's 5%-of-amount fee can't be computed), so PRIVATE escrows
        // keep using this internal commit-reveal + votePrivate path. Rejecting
        // public disputes here also prevents a stale client stranding a stake
        // and disables the internal single-judge selection for public escrows.
        if (
            arbitrationContract != address(0) &&
            !isPrivateEscrow[escrowId] &&
            escrow.token == address(OMNI_COIN)
        ) {
            revert UseArbitrationContract();
        }

        // F2: reject overwriting an ACTIVE commitment regardless of caller. The
        // H-01 guard below only stops the SAME caller re-committing with an
        // unreclaimed stake; without this a counterparty could overwrite the
        // committer's commitment, seize arbitrator selection, and freeze the
        // committer's stake. The counterparty's legitimate path is
        // postCounterpartyStake after reveal, not a competing commit.
        DisputeCommitment storage activeCommit = disputeCommitments[escrowId];
        if (
            activeCommit.commitment != bytes32(0) &&
            !activeCommit.revealed &&
            block.timestamp <= activeCommit.revealDeadline // solhint-disable-line not-rely-on-time
        ) {
            revert AlreadyDisputed();
        }

        // H-01 FIX: Prevent re-commit that would orphan previous dispute stake.
        // If a previous commit exists and the caller still has an unreturned stake,
        // they must call reclaimExpiredStake() first to recover it.
        if (
            disputeCommitments[escrowId].commitment != bytes32(0) &&
            disputeStakes[escrowId][caller] > 0
        ) {
            revert PreviousCommitNotReclaimed();
        }

        // Must wait minimum time before dispute
        uint256 disputeEarliest = escrow.createdAt + ARBITRATOR_DELAY;
        if (block.timestamp < disputeEarliest) revert DisputeTooEarly(); // solhint-disable-line not-rely-on-time

        // Require dispute stake (paid in OmniCoin). L-B: for private-coin
        // escrows the public `amount` is zero (value lives in
        // privateEscrowAmounts), so base the stake on the private amount —
        // otherwise private disputes were free (no anti-frivolous deterrent and
        // the counterparty could never post a matching stake).
        uint256 disputeBase = isPrivateEscrow[escrowId]
            ? privateEscrowAmounts[escrowId]
            : escrow.amount;
        uint256 requiredStake = (disputeBase * DISPUTE_STAKE_BASIS) / BASIS_POINTS;
        // Reject zero-stake (dust) disputes — mirror postCounterpartyStake so a
        // sub-1000-wei private escrow can't be disputed for free.
        if (requiredStake == 0) revert InsufficientStake();
        // 🛑 The stake is denominated in the SAME asset as `disputeBase`.
        // v1 could hard-code XOM because the principal was always XOM; with a
        // per-escrow token, a USDC principal (6 decimals) staked in XOM wei
        // would be ~1e12 too small, making disputes free and arbitrators
        // unpaid. Private escrows keep XOM stakes: pXOM is 1:1 with XOM and
        // 18-decimal, so the v1 arithmetic was already correct for them.
        address stakeToken = _stakeToken(escrowId);
        _pullExact(IERC20(stakeToken), caller, requiredStake);
        disputeStakes[escrowId][caller] = requiredStake;
        totalEscrowed[stakeToken] += requiredStake;

        disputeCommitments[escrowId] = DisputeCommitment({
            commitment: commitment,
            revealDeadline: block.timestamp + 1 hours, // solhint-disable-line not-rely-on-time
            revealed: false
        });

        emit DisputeCommitted(escrowId, caller, commitment);
    }

    /**
     * @notice Reveal dispute and assign arbitrator (step 2)
     * @dev Deterministic arbitrator assignment
     * @param escrowId Escrow to dispute
     * @param nonce Random nonce from commitment
     */
    function revealDispute(uint256 escrowId, uint256 nonce) external nonReentrant whenNotPaused {
        // v2: internal public-dispute path is disabled once the judge panel is
        // wired (mirrors commitDispute); private escrows still resolve here.
        if (
            arbitrationContract != address(0) &&
            !isPrivateEscrow[escrowId] &&
            escrows[escrowId].token == address(OMNI_COIN)
        ) {
            revert UseArbitrationContract();
        }

        Escrow storage escrow = escrows[escrowId];
        DisputeCommitment storage commitment = disputeCommitments[escrowId];

        // A commitment made before the parties settled must not be revealable
        // after settlement: it would flip `disputed` on a resolved escrow and
        // strand the committer's stake (every exit reverts AlreadyResolved,
        // and reclaimExpiredStake refuses a disputed escrow).
        if (escrow.buyer == address(0)) revert EscrowNotFound();
        if (escrow.resolved) revert AlreadyResolved();

        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp > commitment.revealDeadline) revert RevealDeadlinePassed();
        if (commitment.revealed) revert AlreadyDisputed();

        address caller = _msgSender();
        // Verify commitment (hash includes caller address for consistency)
        bytes32 expectedHash = keccak256(abi.encodePacked(
            escrowId,
            nonce,
            caller
        ));
        if (commitment.commitment != expectedHash) revert InvalidCommitment();

        commitment.revealed = true;
        escrow.disputed = true;

        // Deterministic arbitrator selection
        address arbitrator = selectArbitrator(escrowId, nonce);
        escrow.arbitrator = arbitrator;

        emit DisputeRaised(escrowId, caller, arbitrator);
    }

    /**
     * @notice Post a matching dispute stake as the counterparty
     * @dev After a dispute is raised, the counterparty (buyer or seller) must also post
     *      a dispute stake. This eliminates the moral hazard of one-sided staking where
     *      only the disputer bears economic risk. Both parties must have skin in the game.
     *      If the counterparty fails to post their stake, the arbitrator may consider
     *      that in their resolution decision.
     * @param escrowId Escrow identifier
     */
    function postCounterpartyStake(uint256 escrowId) external nonReentrant {
        Escrow storage escrow = escrows[escrowId];

        if (escrow.buyer == address(0)) revert EscrowNotFound();
        if (escrow.resolved) revert AlreadyResolved();
        // v2: public panel escrows track no internal counterparty stake — defer
        // to OmniArbitration (see {_requireInternalDisputePath}).
        _requireInternalDisputePath(escrowId);
        if (!escrow.disputed) revert NotDisputed();

        address caller = _msgSender();
        // Only the counterparty (the party who did NOT initiate the dispute) can post
        if (caller != escrow.buyer && caller != escrow.seller) {
            revert NotParticipant();
        }

        // Prevent double-staking
        if (disputeStakes[escrowId][caller] != 0) revert StakeAlreadyPosted();

        // Calculate the same stake amount the initiator paid. L-B: mirror
        // commitDispute and base private-coin escrows on privateEscrowAmounts
        // (escrow.amount is zero for them) so the counterparty can actually
        // match the initiator's stake instead of always reverting InsufficientStake.
        uint256 disputeBase = isPrivateEscrow[escrowId]
            ? privateEscrowAmounts[escrowId]
            : escrow.amount;
        uint256 requiredStake = (disputeBase * DISPUTE_STAKE_BASIS) / BASIS_POINTS;
        if (requiredStake == 0) revert InsufficientStake();

        address stakeToken = _stakeToken(escrowId);
        _pullExact(IERC20(stakeToken), caller, requiredStake);
        disputeStakes[escrowId][caller] = requiredStake;
        totalEscrowed[stakeToken] += requiredStake;

        emit CounterpartyStakePosted(escrowId, caller, requiredStake);
    }

    /**
     * @notice Reclaim dispute stake when the commit was never revealed
     * @dev H-02 (Round 6): Prevents permanent loss of dispute stakes
     *      when a party commits but fails to reveal within the deadline.
     *      The caller can reclaim their stake after the reveal deadline
     *      plus a grace period has passed, provided the dispute was never
     *      successfully revealed (escrow.disputed remains false).
     * @param escrowId Escrow identifier
     */
    function reclaimExpiredStake(uint256 escrowId) external nonReentrant {
        Escrow storage escrow = escrows[escrowId];
        if (escrow.buyer == address(0)) revert EscrowNotFound();
        // If the dispute was successfully revealed, stakes are
        // handled by the normal resolution path -- not reclaimable
        if (escrow.disputed) revert AlreadyDisputed();

        DisputeCommitment storage commitment = disputeCommitments[escrowId];
        // Must have a commitment (revealDeadline > 0 indicates a commit was made)
        if (commitment.revealDeadline == 0) revert InvalidCommitment();
        // Must not have been revealed
        if (commitment.revealed) revert AlreadyDisputed();
        // Must wait until reveal deadline + grace period has passed
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp <= commitment.revealDeadline + REVEAL_GRACE_PERIOD) {
            revert DisputeTooEarly();
        }

        address caller = _msgSender();
        uint256 stake = disputeStakes[escrowId][caller];
        if (stake == 0) revert NothingToClaim();

        disputeStakes[escrowId][caller] = 0;
        address stakeToken = _stakeToken(escrowId);
        totalEscrowed[stakeToken] -= stake;
        IERC20(stakeToken).safeTransfer(caller, stake);

        emit DisputeStakeReturned(escrowId, caller, stake);
    }

    /**
     * @notice Claim refund on a disputed escrow that has timed out
     * @dev M-01 (Round 6): If a disputed escrow remains unresolved for
     *      DISPUTE_TIMEOUT (30 days) after its expiry, the buyer can
     *      reclaim the escrowed funds. This prevents permanent fund
     *      lock when an arbitrator becomes unavailable and buyer/seller
     *      votes are split.
     *
     *      No marketplace fee is charged on timeout refunds (same as
     *      normal refund path). Dispute stakes are returned to both
     *      parties via pull pattern.
     * @param escrowId Escrow identifier
     */
    function claimDisputeTimeout(uint256 escrowId) external nonReentrant {
        Escrow storage escrow = escrows[escrowId];
        if (escrow.buyer == address(0)) revert EscrowNotFound();
        if (escrow.resolved) revert AlreadyResolved();
        // Trustless last-resort backstop — deliberately kept reachable for
        // PUBLIC panel escrows as well. Its DISPUTE_TIMEOUT gate fires 30 days
        // AFTER expiry, far later than OmniArbitration's own ~7-day default
        // resolution (triggerDefaultResolution) and its appeal window, so it
        // CANNOT re-create the 24h post-expiry refundBuyer race this change
        // closed (that race lived in the short window right after
        // createdAt + ARBITRATOR_DELAY). It only bites when the panel FAILED to
        // resolve at all — e.g. no seatable arbitrator committee (< 3 eligible),
        // where OmniArbitration is stuck in PendingSelection and its own
        // default-resolution is unreachable. Without this path such an escrow
        // would be frozen forever with no permissionless exit. Defaults to a
        // buyer refund, matching triggerDefaultResolution's own default outcome.
        if (!escrow.disputed) revert NotDisputed();

        address caller = _msgSender();
        if (caller != escrow.buyer) revert NotParticipant();

        // Must wait DISPUTE_TIMEOUT after the escrow expiry
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp < escrow.expiry + DISPUTE_TIMEOUT) {
            revert EscrowNotExpired();
        }

        // Refund buyer with no marketplace fee. For a private escrow the
        // public `amount` is deliberately zero (the value lives encrypted in
        // privateEscrowAmounts), so read the real figure — otherwise this
        // "last-resort rescue" resolves the escrow and refunds nothing,
        // stranding the principal where recoverERC20 cannot reach it.
        escrow.resolved = true;
        uint256 amount;
        if (isPrivateEscrow[escrowId]) {
            amount = privateEscrowAmounts[escrowId];
            privateEscrowAmounts[escrowId] = 0;
        } else {
            amount = escrow.amount;
            escrow.amount = 0;
        }
        totalEscrowed[escrow.token] -= amount;

        // Use pull pattern for fund disbursement
        claimable[escrow.token][escrow.buyer] += amount;
        totalClaimable[escrow.token] += amount;
        emit FundsClaimable(escrow.buyer, escrow.token, amount);

        // Return dispute stakes to both parties
        _returnDisputeStake(escrowId, escrow.buyer);
        _returnDisputeStake(escrowId, escrow.seller);

        emit EscrowResolved(escrowId, escrow.buyer, amount);
    }

    /**
     * @notice Vote on disputed escrow outcome
     * @dev 2-of-3 multisig voting
     * @param escrowId Escrow to vote on
     * @param voteForRelease True to release to seller, false to refund buyer
     */
    function vote(uint256 escrowId, bool voteForRelease) external nonReentrant whenNotPaused {
        Escrow storage escrow = escrows[escrowId];

        // M-03 FIX: an internal vote must never compete with the external
        // OmniArbitration panel for the SAME escrow. The discriminator is
        // `arbitrator`, not merely "a panel is configured": revealDispute
        // always assigns one when it opens an internal dispute, while the
        // panel's own markDisputed never touches it. Keying on the panel flag
        // alone made every non-XOM dispute unreachable (its commit/reveal are
        // allowed to run while the panel is wired), leaving the buyer as the
        // only party who could ever exit — via claimDisputeTimeout.
        if (arbitrationContract != address(0) && escrow.arbitrator == address(0)) {
            revert UseArbitrationContract();
        }

        // Private escrows MUST resolve through votePrivate()/_resolvePrivateEscrow:
        // their real value lives in privateEscrowAmounts (escrow.amount == 0), so
        // resolving here via _resolveEscrow would set resolved=true while paying
        // nothing and never zeroing privateEscrowAmounts — permanently stranding
        // the pXOM (and recoverERC20 excludes it from totalEscrowed, so even admin
        // could not rescue it). Mirror votePrivate()'s isPrivateEscrow guard.
        if (isPrivateEscrow[escrowId]) revert CannotMixPrivacyModes();

        address caller = _msgSender();

        _validateVote(escrow, escrowId, caller);

        hasVoted[escrowId][caller] = true;

        if (voteForRelease) {
            ++escrow.releaseVotes;
        } else {
            ++escrow.refundVotes;
        }

        emit VoteCast(escrowId, caller, voteForRelease);

        // Check if we have a decision (2 votes)
        if (escrow.releaseVotes > 1) {
            _resolveEscrow(escrow, escrowId, escrow.seller);
        } else if (escrow.refundVotes > 1) {
            _resolveEscrow(escrow, escrowId, escrow.buyer);
        }
    }

    /**
     * @notice Get escrow details
     * @dev PRIV-H03: For private escrows the `amount` field will be 0.
     *      Use getEncryptedAmount() to retrieve the MPC-encrypted value.
     * @param escrowId Escrow identifier
     * @return Escrow data (amount is 0 for private escrows)
     */
    function getEscrow(uint256 escrowId) external view returns (Escrow memory) {
        return escrows[escrowId];
    }

    /**
     * @notice Check if address has voted
     * @param escrowId Escrow identifier
     * @param voter Address to check
     * @return voted Whether address has voted
     */
    function hasUserVoted(uint256 escrowId, address voter) external view returns (bool voted) {
        return hasVoted[escrowId][voter];
    }

    // ========================================================================
    // IArbitrationEscrow INTERFACE (OmniArbitration Integration)
    // ========================================================================

    /**
     * @notice Get the buyer address for an escrow
     * @dev H-01 OmniArbitration Round 6: Implements the
     *      IArbitrationEscrow.getBuyer() interface so
     *      OmniArbitration can read escrow parties.
     * @param escrowId Escrow identifier
     * @return Buyer address (address(0) if escrow does not exist)
     */
    function getBuyer(
        uint256 escrowId
    ) external view returns (address) {
        return escrows[escrowId].buyer;
    }

    /**
     * @notice Get the seller address for an escrow
     * @dev H-01 OmniArbitration Round 6: Implements the
     *      IArbitrationEscrow.getSeller() interface so
     *      OmniArbitration can read escrow parties.
     * @param escrowId Escrow identifier
     * @return Seller address (address(0) if escrow does not exist)
     */
    function getSeller(
        uint256 escrowId
    ) external view returns (address) {
        return escrows[escrowId].seller;
    }

    /**
     * @notice Get the ERC-20 an escrow holds
     * @param escrowId Escrow identifier
     * @return The token address (address(0) if the escrow does not exist)
     */
    function getToken(uint256 escrowId) external view returns (address) {
        return escrows[escrowId].token;
    }

    /**
     * @notice Get the escrowed amount
     * @dev H-01 OmniArbitration Round 6: Implements the
     *      IArbitrationEscrow.getAmount() interface so
     *      OmniArbitration can read the disputed amount.
     *      PRIV-H03: Returns 0 for private escrows because the
     *      plaintext amount is not stored in the Escrow struct.
     *      Use getEncryptedAmount() for private escrow amounts.
     *      🛑 The unit is the ESCROW TOKEN's smallest unit, not XOM. Read
     *      {getToken} alongside this. The external OmniArbitration panel only
     *      ever prices disputes on XOM escrows ({markDisputed} refuses the
     *      rest), so its XOM assumption holds there.
     * @param escrowId Escrow identifier
     * @return Amount in the escrow token's smallest unit (0 if the escrow
     *         does not exist, is already resolved, or is a private escrow)
     */
    function getAmount(
        uint256 escrowId
    ) external view returns (uint256) {
        return escrows[escrowId].amount;
    }

    /**
     * @notice Mark an escrow disputed on behalf of the authorized
     *         OmniArbitration contract when a judge-panel dispute is opened
     * @dev B4/v2 refund-race fix. On the public L1 path a panel dispute is
     *      created in OmniArbitration.createDispute, which previously left
     *      this escrow's `disputed` flag false. That allowed the buyer to
     *      call {refundBuyer} after expiry WHILE the panel was still
     *      deliberating; the eventual {resolveDispute} callback then reverted
     *      with AlreadyResolved (caught upstream and surfaced only as the
     *      unmonitored ResolutionCallFailed event), so a winning seller could
     *      lose principal. Setting `disputed` here blocks every
     *      party-unilateral exit ({refundBuyer}, {releaseFundsViaContract})
     *      until the panel resolves.
     *
     *      Authorization mirrors {resolveDispute}: only the registered
     *      arbitrationContract may call this (see {onlyArbitration}). The
     *      resolved flag remains the single terminal gate, so no explicit
     *      clear of `disputed` is needed at resolution time — once
     *      {resolveDispute} sets `resolved`, every exit path short-circuits
     *      on AlreadyResolved regardless of `disputed`.
     *
     *      Idempotent: a repeat call while already disputed is a no-op.
     *      Reverts if the escrow is absent (EscrowNotFound) or already
     *      resolved (AlreadyResolved) — the latter makes
     *      OmniArbitration.createDispute correctly reject a dispute against
     *      an escrow whose funds have already been released or refunded.
     * @param escrowId Escrow identifier to mark disputed
     */
    function markDisputed(
        uint256 escrowId
    ) external onlyArbitration {
        Escrow storage escrow = escrows[escrowId];
        if (escrow.buyer == address(0)) revert EscrowNotFound();
        if (escrow.resolved) revert AlreadyResolved();
        // The judge panel prices its dispute deposit in XOM from getAmount().
        // A non-XOM escrow's amount is in another token's units, so the panel
        // cannot price it — such escrows resolve through the internal 2-of-3
        // vote (token-denominated stakes). Refusing here means createDispute
        // fails closed rather than opening a dispute priced in the wrong unit.
        if (escrow.token != address(OMNI_COIN)) revert UseInternalArbitration();
        // An internal dispute (revealDispute) always has an arbitrator; the
        // panel's own disputes never do. Refusing here stops the panel from
        // opening a second venue on top of an internal dispute that was
        // started before the panel was wired — the loser's resolution would
        // revert atomically and strand the panel's dispute fee.
        if (escrow.arbitrator != address(0)) revert AlreadyDisputed();
        if (!escrow.disputed) {
            escrow.disputed = true;
            emit EscrowMarkedDisputed(escrowId);
        }
    }

    /**
     * @notice Clear an escrow's disputed flag when a dispute is cancelled
     * @dev Counterpart to {markDisputed}. `createDispute` takes the fee and
     *      freezes the escrow up front; if the panel cannot be seated the
     *      arbitration contract cancels the dispute and calls this to restore
     *      the release/refund/inspection exits. Only the registered
     *      arbitration contract may call it, and never on a resolved escrow.
     * @param escrowId Escrow identifier
     */
    function unmarkDisputed(uint256 escrowId) external onlyArbitration {
        Escrow storage escrow = escrows[escrowId];
        if (escrow.buyer == address(0)) revert EscrowNotFound();
        if (escrow.resolved) revert AlreadyResolved();
        if (escrow.disputed) {
            escrow.disputed = false;
            emit EscrowUnmarkedDisputed(escrowId);
        }
    }

    /**
     * @notice Resolve a dispute by releasing or refunding escrow
     * @dev H-01 OmniArbitration Round 6: Called exclusively by
     *      the authorized OmniArbitration contract after its
     *      arbitration panel reaches a resolution. This function
     *      handles fund distribution (marketplace fee on release,
     *      arbitration fee from dispute stakes) and returns
     *      remaining stakes to both parties.
     *
     *      Security:
     *      - Only callable by the registered arbitrationContract
     *      - Escrow must exist, be marked disputed, and not already resolved
     *        (the disputed gate prevents a compromised panel from force-resolving
     *        a non-disputed escrow)
     *      - Uses pull pattern (claimable balances) for fund
     *        disbursement to prevent DoS via reverting recipients
     *      - Re-entrancy protected via nonReentrant
     *
     * @param escrowId Escrow ID to resolve
     * @param releaseFunds True to release to seller, false to
     *        refund buyer
     */
    function resolveDispute(
        uint256 escrowId,
        bool releaseFunds
    ) external nonReentrant onlyArbitration {
        Escrow storage e = escrows[escrowId];

        if (e.buyer == address(0)) revert EscrowNotFound();
        if (e.resolved) revert AlreadyResolved();
        if (!e.disputed) revert NotDisputed();

        e.resolved = true;

        // M-02 FIX: For private escrows, e.amount is 0 (real amount is in
        // privateEscrowAmounts). Determine the correct amount and token.
        bool isPrivate = isPrivateEscrow[escrowId];
        uint256 amount;
        if (isPrivate) {
            amount = privateEscrowAmounts[escrowId];
            privateEscrowAmounts[escrowId] = 0;
        } else {
            amount = e.amount;
            e.amount = 0;
        }
        IERC20 token = IERC20(e.token);

        totalEscrowed[address(token)] -= amount;

        address recipient;
        uint256 recipientAmount = amount;

        if (releaseFunds) {
            // Release to seller (with marketplace fee)
            recipient = e.seller;
            if (isPrivate) {
                // Private (pXOM) path keeps the v1 routing: full fee
                // direct to FEE_VAULT. depositMarketplaceFee is
                // XOM-centric and pXOM is not a vault-supported
                // marketplace fee token.
                uint256 feeAmount =
                    (amount * MARKETPLACE_FEE_BPS) / BASIS_POINTS;
                recipientAmount = amount - feeAmount;

                if (feeAmount > 0) {
                    token.safeTransfer(FEE_VAULT, feeAmount);
                    totalMarketplaceFees[address(token)] +=
                        feeAmount;
                    emit MarketplaceFeeCollected(
                        escrowId, FEE_VAULT, feeAmount
                    );
                }
            } else {
                // Public path: referral-aware vault split, in escrow token
                recipientAmount =
                    _collectMarketplaceFee(escrowId, e.token, amount);
            }
        } else {
            // Refund to buyer (no marketplace fee)
            recipient = e.buyer;
        }

        // Deduct arbitration fee from dispute stakes if disputed. The stake
        // asset is {_stakeToken}: the escrow's own token for a public escrow,
        // XOM for a private one. `_collectArbitrationFee` reads it itself, so
        // this call site must not assume XOM.
        // The resolving panel lives in OmniArbitration and is paid by
        // OmniArbitration's own 70/30 fee distribution, so the
        // escrow-side stake fee routes 100% to FEE_VAULT here
        // (arbitratorRecipient = zero).
        if (e.disputed) {
            _collectArbitrationFee(escrowId, e, amount, address(0));
        }

        // M-01: Use pull pattern for fund disbursement
        claimable[address(token)][recipient] +=
            recipientAmount;
        totalClaimable[address(token)] += recipientAmount;
        emit FundsClaimable(
            recipient, address(token), recipientAmount
        );

        // Return remaining dispute stakes to both parties
        _returnDisputeStake(escrowId, e.buyer);
        _returnDisputeStake(escrowId, e.seller);

        emit DisputeResolvedByArbitration(
            escrowId, releaseFunds, recipient, recipientAmount
        );
        emit EscrowResolved(
            escrowId, recipient, recipientAmount
        );
    }

    /**
     * @notice Reject an escrow token the fee vault will not settle
     * @dev Single source of truth: the vault's own allowlist. A token must
     *      also have code — a plain address has no ERC-20 behaviour and every
     *      transfer against it would revert after the buyer had committed.
     * @param token ERC-20 address supplied by the buyer
     */
    function _requireSupportedToken(address token) private view {
        EscrowFeeRouter.requireSupportedToken(
            FEE_VAULT, token, address(PRIVATE_OMNI_COIN), address(this)
        );
    }

    /**
     * @notice Transfer a protocol fee, or leave it in the contract on refusal
     * @dev The transfer is attempted with a low-level call so a reverting or
     *      short-returning token cannot roll back a settlement. On failure the
     *      amount is simply retained (protocol surplus) and an event records it.
     * @param token Fee token
     * @param to Recipient (FEE_VAULT)
     * @param amount Fee amount
     */
    function _payOrHold(IERC20 token, address to, uint256 amount) private {
        // Routed through the linked fee-routing library (see
        // {_collectMarketplaceFee} for why); same low-level, never-reverting
        // transfer with a FeeTransferDeferred event on refusal.
        EscrowFeeRouter.payOrHold(token, to, amount);
    }

    /**
     * @notice Smallest escrow amount that still yields a non-zero 1% fee
     * @dev fee = amount * MARKETPLACE_FEE_BPS / BASIS_POINTS, so the fee
     *      floors to zero below BASIS_POINTS / MARKETPLACE_FEE_BPS (100 at the
     *      pinned 1%). A sub-minimum escrow would settle with no marketplace
     *      fee at all — reachable by splitting a sale into many small escrows,
     *      and materially so for a low-decimal token.
     * @return Minimum escrow amount in the token's smallest unit
     */
    function _minEscrowAmount() private view returns (uint256) {
        return BASIS_POINTS / MARKETPLACE_FEE_BPS;
    }

    /**
     * @notice Pull `amount` and require that exactly that much arrived
     * @dev A fee-on-transfer or negative-rebasing token would otherwise leave
     *      this contract recording more than it holds, making every exit
     *      revert and recoverERC20 refuse the remainder. Used for the escrow
     *      principal, private deposits and both dispute stakes, because a
     *      token can start charging a fee after an escrow was created.
     * @param token ERC-20 to pull
     * @param from Payer
     * @param amount Amount requested
     */
    function _pullExact(IERC20 token, address from, uint256 amount) private {
        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(from, address(this), amount);
        if (token.balanceOf(address(this)) - before != amount) {
            revert TokenTransferMismatch();
        }
    }

    /**
     * @notice Validate the fee-attribution nodes against the parties
     * @dev Mirrors the anti-fee-wash rule for referrers: a node may not be the
     *      buyer, the seller, a referrer, or the other node. Zero is allowed
     *      (the share routes to ODDAO).
     * @param buyer Escrow buyer
     * @param seller Escrow seller
     * @param referrer Primary referrer
     * @param referrer2 Second-level referrer
     * @param listingNode Node that hosted the listing
     * @param sellingNode Node that served the sale
     */
    function _validateAttributionNodes(
        address buyer,
        address seller,
        address referrer,
        address referrer2,
        address listingNode,
        address sellingNode
    ) private pure {
        EscrowFeeRouter.validateAttributionNodes(
            buyer, seller, referrer, referrer2, listingNode, sellingNode
        );
    }

    /**
     * @notice The asset a dispute stake is denominated in
     * @dev Private escrows stake in XOM (pXOM is 1:1 with XOM and 18-decimal,
     *      so v1's arithmetic remains correct and the stake stays a stable
     *      anti-spam bond). Every other escrow stakes in its own token, which
     *      is the only way "2.5% of the principal" is dimensionally true.
     * @param escrowId Escrow identifier
     * @return Stake token address
     */
    function _stakeToken(uint256 escrowId) private view returns (address) {
        return isPrivateEscrow[escrowId]
            ? address(OMNI_COIN)
            : escrows[escrowId].token;
    }

    /**
     * @notice Select arbitrator deterministically from registered arbitrator list
     * @dev Uses escrow creation block and nonce for deterministic selection.
     *      Excludes buyer and seller from selection to prevent conflict of interest.
     * @param escrowId Escrow identifier
     * @param nonce Random nonce from reveal
     * @return arbitrator Selected arbitrator address
     */
    function selectArbitrator(
        uint256 escrowId,
        uint256 nonce
    ) internal view returns (address arbitrator) {
        uint256 listLen = arbitratorList.length;
        if (listLen == 0) revert NoArbitratorsAvailable();

        Escrow storage escrow = escrows[escrowId];

        // Reveal-time entropy makes the selection unpredictable at COMMIT time.
        // Every other input here — createdAt, arbitratorSeed (a constructor
        // constant readable from storage), escrowId, and the caller-chosen
        // nonce — is fixed and public when the disputer commits, so without
        // this they could grind `nonce` offline to land on a colluding
        // arbitrator. `blockhash(block.number - 1)` and `prevrandao` belong to
        // the REVEAL block, which is always later than the commit block and so
        // cannot be precomputed when the commitment is made.
        // NOTE: this is grind-RESISTANCE, not cryptographic randomness — the
        // validator that produces the reveal block retains marginal influence
        // over blockhash/prevrandao. Removing that residual requires a VRF or
        // the RandomCommitteeVerifier committee path (tracked separately).
        // solhint-disable-next-line not-rely-on-time
        uint256 seed = uint256(keccak256(abi.encodePacked(
            escrow.createdAt,
            arbitratorSeed,
            nonce,
            escrowId,
            blockhash(block.number - 1),
            block.prevrandao
        )));

        // Try up to listLen times to find an arbitrator who is not a party
        for (uint256 attempt = 0; attempt < listLen; ++attempt) {
            uint256 idx = (seed + attempt) % listLen;
            address candidate = arbitratorList[idx];
            if (candidate != escrow.buyer && candidate != escrow.seller) {
                return candidate;
            }
        }

        // All arbitrators are parties (should not happen with >2 arbitrators)
        revert NoArbitratorsAvailable();
    }

    /**
     * @notice Resolve escrow and transfer funds
     * @dev Internal helper to avoid code duplication. When disputed, deducts a 5%
     *      arbitration fee (charged 50/50 from buyer and seller stakes) and
     *      distributes it 70% to the resolving arbitrator (pull-pattern
     *      claimable) / 30% to FEE_VAULT, mirroring OmniArbitration.
     *      Marketplace fee only applies when releasing to the seller (not on
     *      refunds) and routes through the referral-aware vault split.
     *      Returns remaining dispute stakes to both parties after arbitration fee.
     * @param escrow Escrow data
     * @param escrowId Escrow identifier
     * @param recipient Address to receive funds
     */
    function _resolveEscrow(
        Escrow storage escrow,
        uint256 escrowId,
        address recipient
    ) private {
        escrow.resolved = true;
        uint256 amount = escrow.amount;
        escrow.amount = 0;

        // Decrement totalEscrowed for the escrow principal
        totalEscrowed[escrow.token] -= amount;

        uint256 recipientAmount = amount;

        // Marketplace fee only charged when releasing to seller (successful transaction)
        if (recipient == escrow.seller) {
            recipientAmount = _collectMarketplaceFee(escrowId, escrow.token, amount);
        }

        // Deduct arbitration fee when escrow was disputed (5% of escrow
        // amount): 70% to the resolving arbitrator, 30% to FEE_VAULT.
        if (escrow.disputed) {
            _collectArbitrationFee(
                escrowId, escrow, amount, escrow.arbitrator
            );
        }

        // M-01: Use pull pattern to prevent DoS via reverting recipients.
        // Note: totalEscrowed already decremented at line 688 for full amount.
        // We only need to credit the claimable balance (no double-decrement).
        claimable[escrow.token][recipient] += recipientAmount;
        totalClaimable[escrow.token] += recipientAmount;
        emit FundsClaimable(recipient, escrow.token, recipientAmount);

        // Return remaining dispute stakes to both parties (if any)
        _returnDisputeStake(escrowId, escrow.buyer);
        _returnDisputeStake(escrowId, escrow.seller);

        emit EscrowResolved(escrowId, recipient, recipientAmount);
    }

    /**
     * @notice Require that an internal-path dispute action is allowed
     * @dev Once the external judge panel (OmniArbitration) is wired via
     *      {setArbitrationContract}, PUBLIC escrows are owned by the panel for
     *      dispute open and resolution. This guard reverts the internal-path
     *      counterparty-stake action ({postCounterpartyStake}) for a public
     *      panel escrow so it cannot compete with the panel — critical since
     *      {markDisputed} sets `disputed` on panel escrows, making that internal
     *      path otherwise reachable (the panel tracks no escrow-side stakes).
     *      Note: {claimDisputeTimeout} is intentionally NOT gated by this — it
     *      is retained as the trustless 30-day last-resort backstop that
     *      guarantees a public panel escrow can never be frozen if the panel
     *      cannot be seated (see {claimDisputeTimeout}). Private-coin escrows
     *      keep the full internal commit-reveal flow (the panel cannot price a
     *      hidden amount).
     * @param escrowId Escrow identifier being acted on
     */
    function _requireInternalDisputePath(uint256 escrowId) private view {
        if (
            arbitrationContract != address(0) &&
            !isPrivateEscrow[escrowId] &&
            escrows[escrowId].token == address(OMNI_COIN)
        ) {
            revert UseArbitrationContract();
        }
    }

    /**
     * @notice Return dispute stake to a party
     * @dev Clears stake from mapping and transfers tokens
     * @param escrowId Escrow identifier
     * @param party Address to return stake to
     */
    function _returnDisputeStake(uint256 escrowId, address party) private {
        EscrowFeeRouter.returnDisputeStake(
            disputeStakes,
            claimable,
            totalEscrowed,
            totalClaimable,
            escrowId,
            _stakeToken(escrowId),
            party
        );
    }

    /**
     * @notice Anti-fee-wash validation of the two referrer slots
     * @dev Mirrors UnifiedFeeVault._validateReferrerPair: a non-zero
     *      referrer must not equal buyer or seller; a non-zero referrer2
     *      must not equal buyer, seller, or referrer. Zero addresses are
     *      always allowed (their share routes to ODDAO at release).
     * @param buyer Escrow buyer
     * @param seller Escrow seller
     * @param referrer Primary referrer (zero if none)
     * @param referrer2 Second-level referrer (zero if none)
     */
    function _validateReferrerPair(
        address buyer,
        address seller,
        address referrer,
        address referrer2
    ) private pure {
        EscrowFeeRouter.validateReferrerPair(buyer, seller, referrer, referrer2);
    }

    /**
     * @notice Collect the marketplace fee on a public XOM escrow release
     *         with referral-aware vault distribution
     * @dev Fee = amount * MARKETPLACE_FEE_BPS / BASIS_POINTS, deducted from
     *      the seller's proceeds. Preferred path: approve FEE_VAULT and call
     *      depositMarketplaceFee(token, amount, referrer, referrer2, 0, 0)
     *      so UnifiedFeeVault performs the canonical on-chain split (0.50%
     *      referral 70/20/10 referrer/referrer2/ODDAO; 0.25% transaction and
     *      0.25% listing vault-internal). The vault credits referrers via
     *      its quarantine-safe pendingClaims pull pattern, so reverting
     *      referrer addresses can never block this release.
     *
     *      The vault path is only taken when the escrow fee exactly equals
     *      the vault's own 1% computation (amount / 100), i.e. when
     *      MARKETPLACE_FEE_BPS == 100 — otherwise the vault would pull a
     *      different amount than this contract earmarked. On ANY vault
     *      revert (paused, DEPOSITOR_ROLE not granted, saleAmount below the
     *      vault minimum) the fee falls back to the v1 direct transfer to
     *      FEE_VAULT, where it lands in the vault's undistributed pool.
     *      Escrow release is therefore never blocked by fee routing.
     *
     *      Caller must have already zeroed the escrow amount and
     *      decremented totalEscrowed (CEI) before invoking.
     * @param escrowId Escrow identifier (for referral lookup + events)
     * @param token Fee token — the escrow's own token
     * @param amount Gross escrow amount being released
     * @return sellerAmount Net amount owed to the seller (amount - fee)
     */
    function _collectMarketplaceFee(
        uint256 escrowId,
        address token,
        uint256 amount
    ) private returns (uint256 sellerAmount) {
        // Fee routing lives in an external linked library (DELEGATECALL) to
        // keep this contract under the 24,576-byte EIP-170 limit. The library
        // executes in THIS contract's storage context: the `totalMarketplaceFees`
        // slot and the events are the escrow's own.
        EscrowReferrers storage refs = escrowReferrers[escrowId];
        Escrow storage e = escrows[escrowId];
        return EscrowFeeRouter.collectMarketplaceFee(
            totalMarketplaceFees,
            escrowId,
            token,
            amount,
            MARKETPLACE_FEE_BPS,
            FEE_VAULT,
            refs.referrer,
            refs.referrer2,
            e.listingNode,
            e.sellingNode
        );
    }

    /**
     * @notice Deduct and distribute the 5% arbitration fee from dispute
     *         stakes (charged 50/50 buyer/seller, capped at each stake)
     * @dev Distribution: 70% (ARBITRATOR_FEE_SHARE_BPS) to
     *      `arbitratorRecipient` via the
     *      pull-pattern claimable balance (arbitrators are arbitrary
     *      addresses — pull prevents transfer-revert griefing), remainder
     *      to FEE_VAULT by direct transfer. Passing
     *      `arbitratorRecipient = address(0)` routes 100% to FEE_VAULT
     *      (used by the OmniArbitration-driven {resolveDispute} path,
     *      where the resolving panel is paid by OmniArbitration's own fee).
     *      Stakes are always XOM, including for private escrows.
     * @param escrowId Escrow identifier
     * @param escrow Escrow data (buyer/seller read for stake deduction)
     * @param amount Disputed escrow principal the 5% is computed on
     * @param arbitratorRecipient Resolving arbitrator (zero → all to vault)
     */
    function _collectArbitrationFee(
        uint256 escrowId,
        Escrow storage escrow,
        uint256 amount,
        address arbitratorRecipient
    ) private {
        EscrowFeeRouter.collectArbitrationFee(
            disputeStakes,
            claimable,
            totalEscrowed,
            totalClaimable,
            escrowId,
            _stakeToken(escrowId),
            escrow.buyer,
            escrow.seller,
            amount,
            ARBITRATION_FEE_BPS,
            ARBITRATOR_FEE_SHARE_BPS,
            arbitratorRecipient,
            FEE_VAULT
        );
    }

    /**
     * @notice Validate vote eligibility
     * @dev H-03: Requires escrow to be disputed before voting is allowed.
     *      Non-disputed escrows must use releaseFunds() or refundBuyer().
     * @param escrow Escrow data
     * @param escrowId Escrow identifier
     * @param caller Address of the voter (from _msgSender())
     */
    function _validateVote(
        Escrow storage escrow,
        uint256 escrowId,
        address caller
    ) private view {
        if (escrow.resolved) revert AlreadyResolved();
        // H-03: Voting only allowed on disputed escrows
        if (!escrow.disputed) revert NotDisputed();
        if (hasVoted[escrowId][caller]) revert AlreadyVoted();

        // For disputed escrows, arbitrator can also vote
        bool isParticipant = caller == escrow.buyer ||
                           caller == escrow.seller ||
                           caller == escrow.arbitrator;
        if (!isParticipant) revert NotParticipant();
    }

    // ========================================================================
    // ARBITRATOR MANAGEMENT (Admin Only)
    // ========================================================================

    /**
     * @notice Set the authorized OmniArbitration contract address
     * @dev H-01 OmniArbitration Round 6: Only this address may call
     *      resolveDispute(). Setting to address(0) disables external
     *      arbitration resolution. Only callable by admin.
     * @param _arbitrationContract Address of the OmniArbitration contract
     */
    function setArbitrationContract(
        address _arbitrationContract
    ) external onlyAdmin {
        // M-01 FIX: Guard against EOAs and zero-code addresses that would break
        // dispute resolution. The arbitration contract must have deployed code.
        // address(0) is deliberately allowed — it disables external arbitration
        // resolution (per the NatSpec above), so a broken/compromised panel can
        // always be severed.
        if (
            _arbitrationContract != address(0) &&
            _arbitrationContract.code.length == 0
        ) {
            revert InvalidAddress();
        }

        address oldArbitration = arbitrationContract;
        arbitrationContract = _arbitrationContract;

        emit ArbitrationContractUpdated(
            oldArbitration, _arbitrationContract
        );
    }

    /**
     * @notice Add an arbitrator to the registry
     * @dev Only admin can add arbitrators. These addresses can be selected to resolve disputes.
     * @param arbitrator Address to add as arbitrator
     */
    function addArbitrator(address arbitrator) external onlyAdmin {
        if (arbitrator == address(0)) revert InvalidAddress();
        if (isRegisteredArbitrator[arbitrator]) revert AlreadyDisputed(); // already registered
        // solhint-disable-next-line gas-strict-inequalities
        if (arbitratorList.length >= MAX_ARBITRATORS) revert TooManyArbitrators();
        isRegisteredArbitrator[arbitrator] = true;
        arbitratorList.push(arbitrator);
        emit ArbitratorAdded(arbitrator);
    }

    /**
     * @notice Remove an arbitrator from the registry
     * @dev Swaps with last element and pops for O(1) removal
     * @param arbitrator Address to remove
     */
    function removeArbitrator(address arbitrator) external onlyAdmin {
        if (!isRegisteredArbitrator[arbitrator]) revert InvalidAddress();
        isRegisteredArbitrator[arbitrator] = false;

        // Find and swap-remove from array
        uint256 len = arbitratorList.length;
        for (uint256 i = 0; i < len; ++i) {
            if (arbitratorList[i] == arbitrator) {
                arbitratorList[i] = arbitratorList[len - 1];
                arbitratorList.pop();
                break;
            }
        }
        emit ArbitratorRemoved(arbitrator);
    }

    /**
     * @notice Get the number of registered arbitrators
     * @return count Number of arbitrators
     */
    function arbitratorCount() external view returns (uint256 count) {
        return arbitratorList.length;
    }

    // ========================================================================
    // PRIVACY ESCROW FUNCTIONS
    // ========================================================================

    /**
     * @notice Create a new private escrow with encrypted amount
     * @dev Buyer creates escrow using pXOM with amount encrypted via MPC
     * @param seller Seller address
     * @param encryptedAmount Encrypted amount of pXOM tokens (gtUint64)
     * @param duration Escrow duration in seconds
     * @return escrowId Unique escrow identifier
     */
    function createPrivateEscrow(
        address seller,
        gtUint64 encryptedAmount,
        uint256 duration
    ) external nonReentrant whenNotPaused returns (uint256 escrowId) {
        if (!privacyEnabled) revert PrivacyNotAvailable();
        address buyer = _msgSender();
        escrowId = ++escrowCounter;
        EscrowPrivacyOps.createEscrow(
            escrows,
            encryptedEscrowAmounts,
            privateEscrowAmounts,
            isPrivateEscrow,
            totalEscrowed,
            address(PRIVATE_OMNI_COIN),
            _minEscrowAmount(),
            buyer,
            seller,
            encryptedAmount,
            duration,
            MIN_DURATION,
            MAX_DURATION,
            escrowId
        );
    }

    /**
     * @notice Release private escrow funds to seller
     * @dev Both buyer and seller must agree, amount remains encrypted
     * @param escrowId Private escrow to release
     */
    function releasePrivateFunds(uint256 escrowId) external nonReentrant {
        if (!isPrivateEscrow[escrowId]) revert CannotMixPrivacyModes();
        EscrowPrivacyOps.releaseFunds(
            escrows,
            privateEscrowAmounts,
            totalEscrowed,
            totalMarketplaceFees,
            claimable,
            totalClaimable,
            address(PRIVATE_OMNI_COIN),
            FEE_VAULT,
            MARKETPLACE_FEE_BPS,
            escrowId,
            _msgSender()
        );
    }

    /**
     * @notice Refund private escrow to buyer
     * @dev Seller can agree or buyer can claim after expiry
     * @param escrowId Private escrow to refund
     */
    function refundPrivateBuyer(uint256 escrowId) external nonReentrant {
        if (!isPrivateEscrow[escrowId]) revert CannotMixPrivacyModes();
        EscrowPrivacyOps.refundBuyer(
            escrows,
            privateEscrowAmounts,
            totalEscrowed,
            claimable,
            totalClaimable,
            address(PRIVATE_OMNI_COIN),
            ARBITRATOR_DELAY,
            escrowId,
            _msgSender()
        );
    }

    /**
     * @notice Vote on disputed private escrow outcome
     * @dev 2-of-3 multisig voting, amounts remain encrypted
     * @param escrowId Private escrow to vote on
     * @param voteForRelease True to release to seller, false to refund buyer
     */
    function votePrivate(uint256 escrowId, bool voteForRelease) external nonReentrant {
        // v2: do NOT defer to the external judge panel here. Private-coin escrows
        // keep their value hidden in privateEscrowAmounts, which the public judge
        // panel cannot price, so private disputes always resolve through this
        // internal 2-of-3 path — even after arbitrationContract is set for public
        // escrows. (Public escrows use vote(), which still defers when wired.)
        Escrow storage escrow = escrows[escrowId];

        if (!isPrivateEscrow[escrowId]) revert CannotMixPrivacyModes();

        address caller = _msgSender();
        _validateVote(escrow, escrowId, caller);

        hasVoted[escrowId][caller] = true;

        if (voteForRelease) {
            ++escrow.releaseVotes;
        } else {
            ++escrow.refundVotes;
        }

        emit VoteCast(escrowId, caller, voteForRelease);

        // Check if we have a decision (2 votes)
        if (escrow.releaseVotes > 1) {
            _resolvePrivateEscrow(escrow, escrowId, escrow.seller);
        } else if (escrow.refundVotes > 1) {
            _resolvePrivateEscrow(escrow, escrowId, escrow.buyer);
        }
    }

    /**
     * @notice Resolve private escrow and transfer funds
     * @dev Internal helper for private escrow resolution. Returns dispute stakes
     *      (paid in XOM, not pXOM) to both parties when disputed.
     * @param escrow Escrow data
     * @param escrowId Escrow identifier
     * @param recipient Address to receive funds
     */
    function _resolvePrivateEscrow(
        Escrow storage escrow,
        uint256 escrowId,
        address recipient
    ) private {
        escrow.resolved = true;
        // PRIV-H03: Read from private mapping instead of escrow.amount
        uint256 amount = privateEscrowAmounts[escrowId];
        privateEscrowAmounts[escrowId] = 0;

        totalEscrowed[address(PRIVATE_OMNI_COIN)] -= amount;

        uint256 recipientAmount = amount;

        // H-02: Marketplace fee on seller releases (matching public escrow behavior)
        if (recipient == escrow.seller) {
            uint256 feeAmount = (amount * MARKETPLACE_FEE_BPS) / BASIS_POINTS;
            recipientAmount = amount - feeAmount;
            if (feeAmount > 0) {
                PRIVATE_OMNI_COIN.safeTransfer(FEE_VAULT, feeAmount);
                totalMarketplaceFees[address(PRIVATE_OMNI_COIN)] += feeAmount;
                emit MarketplaceFeeCollected(escrowId, FEE_VAULT, feeAmount);
            }
        }

        // M-02 (Round 6): Use pull pattern for private escrow resolution,
        // matching the public escrow path. Prevents DoS from reverting recipients.
        claimable[address(PRIVATE_OMNI_COIN)][recipient] += recipientAmount;
        totalClaimable[address(PRIVATE_OMNI_COIN)] += recipientAmount;
        emit FundsClaimable(recipient, address(PRIVATE_OMNI_COIN), recipientAmount);

        // H-01 (Round 6): Deduct arbitration fee from dispute stakes
        // for private escrows, matching the public escrow path in
        // _resolveEscrow(). Dispute stakes are always in XOM (not
        // pXOM), so the same fee logic applies directly: 70% to the
        // resolving arbitrator, 30% to FEE_VAULT.
        if (escrow.disputed) {
            _collectArbitrationFee(
                escrowId, escrow, amount, escrow.arbitrator
            );
        }

        // Return remaining dispute stakes (always in XOM) to both parties
        _returnDisputeStake(escrowId, escrow.buyer);
        _returnDisputeStake(escrowId, escrow.seller);

        emit PrivateEscrowResolved(escrowId, recipient);
    }

    /**
     * @notice Check if privacy features are available
     * @dev Returns true on COTI V2 network, false otherwise
     * @return available Whether privacy features are available
     */
    function privacyAvailable() public view returns (bool available) {
        return privacyEnabled;
    }

    /**
     * @notice Get encrypted amount for private escrow
     * @dev Only returns data for private escrows
     * @param escrowId Escrow identifier
     * @return encryptedAmount Encrypted amount (ctUint64)
     */
    function getEncryptedAmount(uint256 escrowId) external view returns (ctUint64 encryptedAmount) {
        if (!isPrivateEscrow[escrowId]) revert CannotMixPrivacyModes();
        return encryptedEscrowAmounts[escrowId];
    }

    /**
     * @notice Record a seller's first marketplace sale for the first-sale bonus
     * @dev Best-effort, contract-to-contract bridge into {OmniRegistration}.
     *      `REGISTRY` is the OmniRegistration contract (the same address used
     *      for arbitrator lookups), and this escrow is an authorized recorder.
     *      `markFirstSaleCompleted` enforces anti-Sybil rules (minimum sale
     *      amount, account age, referrer divergence) and REVERTS for
     *      non-qualifying sales — which must never roll back a settled escrow —
     *      so both the eligibility read and the record call are wrapped in
     *      try/catch and skipped once the seller has a first sale on record.
     * @param seller The seller who just received escrow funds
     * @param token The escrow's settlement token
     * @param saleAmount The gross sale amount (XOM wei; 18 decimals)
     * @param buyer The buyer in this escrow
     */
    function _recordFirstSale(
        address seller,
        address token,
        uint256 saleAmount,
        address buyer
    ) private {
        // Lives in the external linked fee-routing library for the same
        // bytecode-budget reason as the fee routing above. Best-effort: it can
        // never revert a settled escrow.
        EscrowFeeRouter.recordFirstSale(
            REGISTRY,
            address(OMNI_COIN),
            seller,
            token,
            saleAmount,
            buyer
        );
    }

    /**
     * @notice Detect if privacy features are available on current network
     * @dev Internal function to check for COTI V2 MPC support
     * @return enabled Whether privacy is supported
     */
    function _detectPrivacyAvailability() private view returns (bool enabled) {
        // On COTI V2 network, MPC precompiles are available.
        // COTI mainnet 2632500, COTI testnet 7082400, COTI devnet 13068200 —
        // the ids the validator's chain config uses. The old testnet value
        // (7082) matches no network, so a COTI testnet deployment silently
        // reported privacy unavailable.
        // For testing in Hardhat/Fuji, return false (MPC not available).
        return (
            block.chainid == 2632500 ||
            block.chainid == 7082400 ||
            block.chainid == 13068200
        );
    }

    // ========================================================================
    // ADMIN FUNCTIONS (Pause, Recovery)
    // ========================================================================

    /// @notice Emitted when accidentally sent tokens are recovered
    /// @param token Token address recovered
    /// @param amount Amount recovered
    /// @param recipient Address receiving recovered tokens
    event TokensRecovered(
        address indexed token,
        uint256 indexed amount,
        address indexed recipient
    );

    /// @notice Emitted when admin rotation is proposed (step 1 of 2).
    /// @param currentAdmin Address currently holding admin
    /// @param proposed Address proposed as successor
    event AdminProposed(address indexed currentAdmin, address indexed proposed);

    /// @notice Emitted when admin rotation completes (step 2 of 2).
    /// @param oldAdmin Address that previously held admin
    /// @param newAdmin Address that now holds admin
    event AdminTransferred(address indexed oldAdmin, address indexed newAdmin);

    /**
     * @notice Propose admin rotation (step 1 of 2).
     * @dev Admin-only. The `newAdmin` must call {acceptAdmin} to finalize.
     * @param newAdmin Proposed successor admin address.
     */
    function transferAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert InvalidAddress();
        pendingAdmin = newAdmin;
        emit AdminProposed(admin, newAdmin);
    }

    /**
     * @notice Accept the pending admin rotation (step 2 of 2).
     * @dev Callable only by the pending admin. Clears pendingAdmin on success.
     */
    function acceptAdmin() external {
        if (msg.sender != pendingAdmin) revert NotPendingAdmin();
        address old = admin;
        admin = pendingAdmin;
        pendingAdmin = address(0);
        emit AdminTransferred(old, admin);
    }

    /**
     * @notice Withdraw accumulated claimable balance (M-01: pull pattern)
     * @dev Allows users to withdraw funds credited during escrow resolution.
     *      This prevents DoS where a reverting recipient blocks _resolveEscrow().
     *      Users MUST call this after escrow resolution to receive their funds.
     * @param token Token address to withdraw (typically OMNI_COIN)
     */
    function withdrawClaimable(address token) external nonReentrant {
        address caller = _msgSender();
        uint256 amount = claimable[token][caller];
        if (amount == 0) revert NothingToClaim();

        claimable[token][caller] = 0;
        totalClaimable[token] -= amount;
        IERC20(token).safeTransfer(caller, amount);

        emit FundsClaimed(caller, token, amount);
    }

    /**
     * @notice Pause the contract, preventing new escrow creation and state changes
     * @dev Only callable by admin. Existing escrows can still be resolved (refundBuyer
     *      is not paused) to prevent funds from being permanently locked.
     */
    function pause() external onlyAdmin {
        _pause();
    }

    /**
     * @notice Unpause the contract, re-enabling normal operations
     * @dev Only callable by admin
     */
    function unpause() external onlyAdmin {
        _unpause();
    }

    /**
     * @notice Recover ERC20 tokens accidentally sent to this contract
     * @dev Only allows recovery of tokens that are NOT held in active escrows
     *      or pending in claimable balances.
     *      The recoverable amount is: balance - totalEscrowed - totalClaimable.
     *      This prevents admin from withdrawing funds belonging to escrow participants.
     * @param token Address of the ERC20 token to recover
     * @param recipient Address to receive the recovered tokens
     */
    function recoverERC20(address token, address recipient) external onlyAdmin {
        if (token == address(0) || recipient == address(0)) revert InvalidAddress();

        uint256 contractBalance = IERC20(token).balanceOf(address(this));
        uint256 locked = totalEscrowed[token] + totalClaimable[token];

        // solhint-disable-next-line gas-strict-inequalities
        if (contractBalance <= locked) revert NothingToClaim();

        uint256 recoverable = contractBalance - locked;
        IERC20(token).safeTransfer(recipient, recoverable);

        emit TokensRecovered(token, recoverable, recipient);
    }

    // ========================================================================
    // ERC2771Context Overrides (resolve diamond with Pausable's Context)
    // ========================================================================

    /**
     * @notice Resolve _msgSender between Context (via Pausable) and ERC2771Context
     * @dev Returns the original user address when called through the trusted forwarder
     * @return The original transaction signer (user) when relayed, or msg.sender when direct
     */
    function _msgSender()
        internal
        view
        override(Context, ERC2771Context)
        returns (address)
    {
        return ERC2771Context._msgSender();
    }

    /**
     * @notice Resolve _msgData between Context (via Pausable) and ERC2771Context
     * @dev Strips the appended sender address from calldata when relayed
     * @return The original calldata without the ERC2771 suffix
     */
    function _msgData()
        internal
        view
        override(Context, ERC2771Context)
        returns (bytes calldata)
    {
        return ERC2771Context._msgData();
    }

    /**
     * @notice Resolve _contextSuffixLength between Context and ERC2771Context
     * @dev Returns 20 (address length) for ERC2771 context suffix stripping
     * @return The number of bytes appended to calldata by the forwarder (20)
     */
    function _contextSuffixLength()
        internal
        view
        override(Context, ERC2771Context)
        returns (uint256)
    {
        return ERC2771Context._contextSuffixLength();
    }
}