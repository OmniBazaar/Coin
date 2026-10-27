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
import {EscrowFeeRouter} from "./libraries/EscrowFeeRouter.sol";
import {EscrowSignatureLib} from "./libraries/EscrowSignatureLib.sol";
import {
    Escrow,
    FeeAttribution,
    FeeBeneficiaries
} from "./interfaces/EscrowV2Types.sol";

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
 * V4 (2026-10-20 — per-chain escrow, founder decision 3):
 * - NO CROSS-CHAIN DEPENDENCY. The escrow no longer reads
 *   `UnifiedFeeVault.supportedPaymentTokens` and no longer calls
 *   `UnifiedFeeVault.depositMarketplaceFee`: the allowlist is its own
 *   admin-set mapping ({setSupportedToken}), and the 1% is split IN KIND ON
 *   THIS CHAIN, in the token the escrow holds, into nine pull-pattern credits
 *   (referrer, referrer2, listing node, selling node, ODDAO, staking pool,
 *   treasury). See {EscrowFeeRouter}. The three protocol sinks are immutable
 *   deploy arguments.
 * - Verdicts from the arbitration panel arrive as EIP-712 signatures from two
 *   seated judges ({executeVerdict}) instead of a call from the panel
 *   contract, so the panel can live on another chain. The panel keeps the
 *   stakes, the seat bonds and the review; this contract only ever executes a
 *   FINAL verdict (compensate buyer or seller) and can never reverse a
 *   settlement. {openDispute} lets a party freeze the escrow locally so a
 *   dispute cannot race a unilateral release.
 * - Attribution is SELLER-SIGNED ({createEscrowSigned}): the buyer can no
 *   longer nominate the referrers and nodes that share the 1%.
 *
 * V3 (2026-10-19 — token per escrow):
 * - Every escrow records the ERC-20 it holds (`Escrow.token`). v1 could only
 *   hold XOM or pXOM, both fixed at deploy, so a physical or service sale
 *   priced in any other token had no escrow path at all.
 * - `createEscrow` takes the token; creation fails unless the token is on the
 *   escrow's own allowlist, so a listing that exists can always be escrowed.
 * - Marketplace fees are collected in the escrow's own token; dispute stakes
 *   remain in that token (anti-spam collateral, not sale proceeds).
 * - Private (pXOM) escrows keep their MPC path unchanged and record pXOM as
 *   their token, so `getEscrow`/`getToken` describe them the same way.
 * - The XOM-denominated first-sale bonus is recorded for XOM sales only (see
 *   {_recordFirstSale}).
 *
 * V2 (2026-06-12, EIP-712 domain version "2"):
 * - createEscrowWithReferrers() captured referrer/referrer2 at creation
 *   (immutable per escrow, anti-fee-wash validated). Legacy
 *   createEscrow(seller, amount, duration) is kept as an XOM-defaulted
 *   overload and defaults both referrers to zero.
 * - The 1% marketplace fee was routed through
 *   UnifiedFeeVault.depositMarketplaceFee so the vault performed the canonical
 *   split: 0.50% referral (70/20/10 referrer/referrer2/ODDAO), 0.25%
 *   transaction + 0.25% listing (vault-internal 70/20/10). V4 pays that same
 *   schedule locally and drops the vault dependency entirely.
 * - Internal commit-reveal arbitration (single resolving arbitrator, used for
 *   private escrows) distributes the 5% arbitration fee 70% direct to the
 *   resolving arbitrator (pull-pattern claimable) and 30% to ODDAO. This is a
 *   distinct single-arbitrator split; the public 3-arbitrator panel
 *   (OmniArbitration) uses its own 90/10 split.
 */
contract EscrowV2 is ReentrancyGuard, Pausable, ERC2771Context, EIP712 {
    using SafeERC20 for IERC20;
    using MpcCore for gtUint64;
    using MpcCore for ctUint64;
    using MpcCore for gtBool;

    // Type declarations
    // {Escrow} is declared in ./interfaces/EscrowV2Types.sol so the two linked
    // libraries (fee routing, privacy ops) can take a storage pointer to it.

    /// @notice Referral attribution captured at escrow creation
    /// @dev Immutable per escrow (written once in {_createEscrow}, never
    ///      updated). Threaded into UnifiedFeeVault.depositMarketplaceFee
    ///      at release so the 0.50% referral component splits 70/20/10
    ///      referrer / referrer2 / ODDAO. Zero addresses route the
    ///      corresponding share to ODDAO (vault-side behavior).
    struct EscrowReferrers {
        address referrer;   // slot 0: primary referrer
        address referrer2;  // slot 1: second-level referrer
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

    /// @notice Basis points denominator
    uint256 public constant BASIS_POINTS = 10000;

    /// @notice Timeout for unresolved disputes (30 days)
    uint256 public constant DISPUTE_TIMEOUT = 30 days;

    /// @notice Grace period after reveal deadline for stake reclaim (H-02 Round 6)
    uint256 public constant REVEAL_GRACE_PERIOD = 24 hours;

    /// @notice Default marketplace fee (1% = 100 bps)
    uint256 public constant DEFAULT_MARKETPLACE_FEE_BPS = 100;

    /// @notice Maximum marketplace fee cap (5% = 500 bps)
    uint256 public constant MAX_MARKETPLACE_FEE_BPS = 500;

    /// @notice Default arbitration fee (5%) used at construction
    /// @dev The live value is the settable `arbitrationFeeBps`.
    uint256 public constant DEFAULT_ARBITRATION_FEE_BPS = 500;

    /// @notice Hard ceiling on the settable arbitration fee (10%)
    uint256 public constant MAX_ARBITRATION_FEE_BPS = 1000;

    /// @notice Hard ceiling on the settable fee-to-amount ratio (50%)
    uint256 public constant MAX_FEE_OF_AMOUNT_BPS = 5000;

    /// @notice Most addresses the verdict roster may hold
    uint256 public constant MAX_VERDICT_JUDGES = 3;

    /// @notice How long after expiry a verdict is still executable
    /// @dev MUST stay shorter than {DISPUTE_TIMEOUT}: the trustless timeout
    ///      opens at expiry + DISPUTE_TIMEOUT, and the two paths must never be
    ///      callable in the same block or a losing party can race the verdict.
    uint256 public constant VERDICT_WINDOW = 25 days;

    // State variables (immutables first)
    /// @notice OmniCoin token (XOM)
    IERC20 public immutable OMNI_COIN;

    /// @notice Private OmniCoin token (pXOM) for private escrows
    IERC20 public immutable PRIVATE_OMNI_COIN;

    /// @notice Registry contract for service lookups
    address public immutable REGISTRY;

    /// @notice ODDAO recipient of the protocol-owned slices of the fee split
    /// @dev V4: the 1% is paid in kind on THIS chain. This address receives
    ///      the transaction/listing 70/10 slices and every zero-address
    ///      attribution slot, plus the arbitration fee remainder.
    ///
    ///      SETTABLE BEHIND A DELAY (founder decision 2026-10-27). These three
    ///      sinks were immutable, so a protocol reorganisation meant a new
    ///      escrow on every chain. A two-step change with a 48-hour delay keeps
    ///      the "no single party can redirect fees instantly" property while
    ///      removing the redeploy.
    address public ODDAO;

    /// @notice Staking-pool recipient of the 20% transaction slice
    address public STAKING_POOL;

    /// @notice Protocol-treasury recipient of the 10% transaction slice
    address public PROTOCOL_TREASURY;

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

    /// @notice Delay before a proposed fee-recipient change takes effect
    uint256 public constant BENEFICIARY_DELAY = 48 hours;

    /// @notice The three sinks a pending change would install
    address public pendingOddao;
    address public pendingStakingPool;
    address public pendingTreasury;

    /// @notice When the pending change was proposed (0 = none)
    uint256 public beneficiaryProposedAt;

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

    /// @notice Claimable balances for pull-based withdrawal (M-01: DoS protection)
    /// @dev token address => user address => claimable amount
    mapping(address => mapping(address => uint256)) public claimable;

    /// @notice Total tokens held in active escrows per token (for M-07 rescue accounting)
    mapping(address => uint256) public totalEscrowed;

    /// @notice Total tokens in claimable balances per token (M-01: pull-pattern accounting)
    mapping(address => uint256) public totalClaimable;

    /// @notice Tokens this escrow will settle — THIS chain's allowlist
    /// @dev Founder decision 3 (2026-10-20): each chain's escrow owns its
    ///      own list instead of reading UnifiedFeeVault.supportedPaymentTokens
    ///      on another chain. XOM is seeded in the constructor; the admin adds
    ///      bridged assets as they become usable here.
    mapping(address => bool) public supportedToken;

    /// @notice Judge addresses whose verdict signatures this escrow accepts
    /// @dev A verdict needs two DISTINCT rostered judges (see
    ///      {executeVerdict}). The admin points this at the arbitration
    ///      panel's seated judges — the same EOAs that sit on the L1 panel.
    mapping(address => bool) public verdictJudge;

    /// @notice How many addresses are on the verdict roster
    /// @dev CAPPED AT {MAX_VERDICT_JUDGES}: the threshold is 2 of N, so a
    ///      growing roster silently lowers the bar to "any two of many" and
    ///      divides the fee further. The panel is fixed at three.
    uint256 public verdictJudgeCount;

    /// @notice Arbitration fee charged on a disputed resolution (bps of amount)
    /// @dev Settable so the fee never needs a redeploy. 500 = 5%.
    uint256 public arbitrationFeeBps;

    /// @notice Smallest arbitration fee, per token (in that token's units)
    /// @dev 5% of a small sale is dust. The floor keeps a verdict worth
    ///      deciding; per token because the contract cannot price tokens.
    mapping(address => uint256) public minArbitrationFee;

    /// @notice Largest arbitration fee as a share of the disputed amount (bps)
    /// @dev Above this a dispute is refused: arbitrating must never cost a
    ///      quarter of the sale. 2500 = 25%.
    uint256 public maxArbitrationFeeBps;

    /// @notice Share of the arbitration fee paid to the judges (bps)
    /// @dev 2 signers → 8000 (40% each), 3 signers → 8100 (27% each).
    uint256 public judgePoolBps2;
    uint256 public judgePoolBps3;

    /// @notice Share paid to whoever submits the verdict (bps of the fee)
    /// @dev 2 signers → 1000, 3 signers → 900. Covers the submitter's gas out
    ///      of the case itself.
    uint256 public submitterBps2;
    uint256 public submitterBps3;

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

    /// @notice Emitted when the 1% marketplace fee is split in kind on release
    /// @param escrowId Escrow identifier
    /// @param token Fee token (the escrow's own token)
    /// @param feeAmount Total fee split into the nine claimable credits
    event MarketplaceFeeSplit(
        uint256 indexed escrowId,
        address indexed token,
        uint256 feeAmount
    );

    /// @notice Emitted when arbitration fee is deducted from disputed escrow resolution
    /// @param escrowId Escrow identifier
    /// @param totalArbitrationFee Total arbitration fee collected
    /// @param arbitratorShare Amount credited to the resolving arbitrator's
    ///        claimable balance (70%; zero when resolved by the judge panel,
    ///        which is paid by its own fee on its own chain). Remainder
    ///        (totalArbitrationFee - arbitratorShare) is credited to ODDAO.
    event ArbitrationFeeCollected(
        uint256 indexed escrowId,
        uint256 totalArbitrationFee,
        uint256 arbitratorShare
    );

    /// @notice Emitted when a party freezes an escrow for the judge panel
    /// @param escrowId Escrow identifier
    /// @param disputer The buyer or seller that opened the dispute
    event EscrowDisputeOpened(
        uint256 indexed escrowId,
        address indexed disputer,
        uint256 stake
    );

    /// @notice Emitted when a signed 2-of-N judge verdict is executed
    /// @param escrowId Escrow identifier
    /// @param releaseFunds True = paid the seller, false = refunded the buyer
    /// @param validUntil Deadline the judges signed
    event VerdictExecuted(
        uint256 indexed escrowId,
        bool releaseFunds,
        uint256 validUntil
    );

    /// @notice Emitted when the admin adds/removes a settlement token
    event SupportedTokenUpdated(address indexed token, bool allowed);

    /// @notice Emitted when the admin adds/removes a verdict judge
    event VerdictJudgeUpdated(address indexed judge, bool allowed);

    /// @notice Emitted when the arbitration fee parameters change
    event ArbitrationFeeConfigured(uint256 feeBps, uint256 maxFeeOfAmountBps);

    /// @notice Emitted when a per-token fee floor changes
    event MinArbitrationFeeSet(address indexed token, uint256 amount);

    /// @notice Emitted when the judge/submitter split changes
    event ArbitrationSplitConfigured(
        uint256 pool2,
        uint256 pool3,
        uint256 submitter2,
        uint256 submitter3
    );

    /// @notice Emitted when a fee-recipient change is proposed
    event BeneficiariesProposed(
        address indexed oddao,
        address indexed stakingPool,
        address indexed treasury
    );

    /// @notice Emitted when proposed fee recipients take effect
    event BeneficiariesUpdated(
        address indexed oddao,
        address indexed stakingPool,
        address indexed treasury
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

    // Custom errors
    error InvalidAddress();
    /// @notice Escrow token is not on the fee vault's payment allowlist
    error TokenNotSupported();
    /// @notice The token moved a different amount than it reported (fee-on-transfer / rebasing)
    error TokenTransferMismatch();
    /// @notice The vault's allowlist could not be read (RPC/upgrade failure)
    error AllowlistUnavailable();
    /// @notice This escrow must resolve through the internal 2-of-3 vote, not the panel
    /// @notice A fee-attribution node collides with a party or the other node
    error BadAttribution();
    error InvalidFeeConfig();
    /// @notice Fee would exceed the settable share of the disputed amount
    error FeeTooLarge();
    /// @notice The verdict roster already holds {MAX_VERDICT_JUDGES}
    error TooManyVerdictJudges();
    /// @notice No beneficiary change has been proposed
    error NoPendingBeneficiaries();
    /// @notice The beneficiary change delay has not elapsed
    error BeneficiaryDelayActive();
    error InvalidAmount();
    error InvalidDuration();
    error EscrowNotFound();
    error EscrowExpired();
    error NotParticipant();
    error AlreadyResolved();
    error DisputeTooEarly();
    error AlreadyDisputed();
    /// @notice The escrow has already been marked delivered by the seller.
    error AlreadyDelivered();
    /// @notice The escrow has not been marked delivered by the seller.
    error NotDelivered();
    /// @notice The buyer inspection window has not yet elapsed.
    error InspectionPending();
    /// @notice Permissionless seller-release is unavailable for private escrows.
    error AmountTooLarge();
    error OnlyAdmin();
    error NotPendingAdmin();
    error NotDisputed();
    error EscrowNotExpired();

    /// @notice Caller is not the authorized arbitration contract
    error NothingToClaim();

    /// @notice Referrer slot collides with buyer/seller, or referrer2
    ///         collides with buyer/seller/referrer (anti-fee-wash)
    error BadReferrer();

    /// @notice A previous dispute commit has not been reclaimed; call reclaimExpiredStake() first

    /// @notice When an arbitration contract is set, internal vote resolution must defer to it

    /// @notice A non-zero attribution set arrived without the seller's consent
    error InvalidSellerSignature();

    /// @notice A verdict signature was malformed, unrostered, duplicated or stale
    error InvalidVerdict();

    /// @notice Fewer than two distinct judge signatures were supplied
    error NotEnoughVerdicts();

    /// @notice The seller's inspection window has not elapsed yet
    error InspectionWindowOpen();

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
        address _oddao,
        address _stakingPool,
        address _protocolTreasury,
        uint256 _marketplaceFeeBps,
        address trustedForwarder_
    )
        ERC2771Context(trustedForwarder_)
        EIP712("OmniBazaar EscrowV2", "3")
    {
        // XOM and the three protocol sinks are required. pXOM and the registry
        // are optional: a chain that has neither (Avalanche today) still gets a
        // working escrow — privacy stays unavailable there (the chain-id check)
        // and the first-sale bridge no-ops on a codeless registry.
        if (
            _omniCoin == address(0) ||
            _oddao == address(0) ||
            _stakingPool == address(0) ||
            _protocolTreasury == address(0)
        ) {
            revert InvalidAddress();
        }
        // The three protocol sinks receive slices of EVERY sale's fee, so a
        // duplicated sink would silently merge two of them into one.
        if (
            _oddao == _stakingPool ||
            _oddao == _protocolTreasury ||
            _stakingPool == _protocolTreasury ||
            _oddao == address(this) ||
            _stakingPool == address(this) ||
            _protocolTreasury == address(this)
        ) {
            revert InvalidAddress();
        }
        if (_marketplaceFeeBps > MAX_MARKETPLACE_FEE_BPS) {
            revert InvalidFeeConfig();
        }
        // 🛑 The 1% split below is computed from this figure. Any other value
        // changes every seller's take, and 0 disables the marketplace fee
        // altogether. Pin it.
        if (_marketplaceFeeBps != DEFAULT_MARKETPLACE_FEE_BPS) {
            revert InvalidFeeConfig();
        }
        OMNI_COIN = IERC20(_omniCoin);
        PRIVATE_OMNI_COIN = IERC20(_privateOmniCoin);
        REGISTRY = _registry;
        ODDAO = _oddao;
        STAKING_POOL = _stakingPool;
        PROTOCOL_TREASURY = _protocolTreasury;
        MARKETPLACE_FEE_BPS = _marketplaceFeeBps;
        admin = msg.sender;

        // XOM is the chain's own asset and always settles here. Every other
        // token is added per chain by the admin as it becomes usable.
        supportedToken[_omniCoin] = true;

        arbitrationFeeBps = DEFAULT_ARBITRATION_FEE_BPS;
        maxArbitrationFeeBps = 2500;
        judgePoolBps2 = 8000;
        judgePoolBps3 = 8100;
        submitterBps2 = 1000;
        submitterBps3 = 900;
    }

    /**
     * @notice Create a new escrow in a caller-chosen token
     * @dev Buyer creates escrow with seller address, token and amount. Both
     *      referrer slots default to zero (the referral component of the
     *      release fee routes to ODDAO inside the vault).
     *
     *      `token` MUST be on this escrow's own allowlist
     *      ({setSupportedToken}); the Validator checks the same list before it
     *      publishes a listing, so a listing that exists can always be
     *      escrowed. Zero addresses and tokens without code are rejected.
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
        return
            _createEscrow(
                seller, token, amount, duration, _noAttribution(), 0
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
        return
            _createEscrow(
                seller,
                address(OMNI_COIN),
                amount,
                duration,
                _noAttribution(),
                0
            );
    }

    /**
     * @notice Create an escrow whose fee attribution the SELLER signed
     * @dev V4 entry point (founder decision 3d). The referral and node slots
     *      decide who receives seven of the nine slices of the 1% fee, and the
     *      fee is paid out of the seller's proceeds — so the SELLER, not the
     *      buyer, must consent to the set. The seller signs the EIP-712
     *      `Attribution` payload once per token/set/deadline (typically when
     *      creating the listing); the buyer replays that signature here.
     *
     *      A zero attribution set needs no consent: use {createEscrow}. Any
     *      non-zero slot requires `sellerSignature` over exactly these values,
     *      and the recovered signer must be the escrow's seller.
     *
     *      Anti-fee-wash rules are unchanged: a referrer or node may not be the
     *      buyer, the seller, or another attribution slot.
     * @param seller Seller address (must be the attribution signer)
     * @param token ERC-20 to escrow (must be on this escrow's allowlist)
     * @param amount Amount of `token` in its smallest unit
     * @param duration Escrow duration in seconds
     * @param attribution Referrer + node set the seller consented to
     * @param validUntil Unix time after which the consent expires
     * @param sellerSignature Seller's EIP-712 signature over the set
     * @return escrowId Unique escrow identifier
     */
    function createEscrowSigned(
        address seller,
        address token,
        uint256 amount,
        uint256 duration,
        FeeAttribution calldata attribution,
        uint256 validUntil,
        bytes calldata sellerSignature
    ) external nonReentrant whenNotPaused returns (uint256 escrowId) {
        _requireSellerAttribution(
            seller, token, attribution, validUntil, sellerSignature
        );
        return _createEscrow(
            seller, token, amount, duration, attribution, validUntil
        );
    }

    /**
     * @notice Shared escrow-creation body
     * @dev Validates parties + attribution + token allowlist, pulls the escrow
     *      token, writes the escrow record and (when present) the attribution.
     *      A non-zero attribution set has already been proved to carry the
     *      seller's signature by the caller ({createEscrowSigned}).
     * @param seller Seller address
     * @param token ERC-20 to escrow (must be on this escrow's allowlist)
     * @param amount Amount of `token` in its smallest unit
     * @param duration Escrow duration in seconds
     * @param attribution Seller-consented referrer + node set (may be empty)
     * @param validUntil Attribution consent deadline (0 when empty)
     * @return escrowId Unique escrow identifier
     */
    function _createEscrow(
        address seller,
        address token,
        uint256 amount,
        uint256 duration,
        FeeAttribution memory attribution,
        uint256 validUntil
    ) private returns (uint256 escrowId) {
        address buyer = _msgSender();
        if (seller == address(0) || seller == buyer || seller == address(this)) {
            revert InvalidAddress();
        }
        if (amount == 0) revert InvalidAmount();
        if (duration < MIN_DURATION || duration > MAX_DURATION) revert InvalidDuration();
        // A non-empty set arriving here without a live consent would let a
        // buyer nominate the fee recipients. The checked entry point is
        // {createEscrowSigned}; this is the belt-and-braces backstop.
        if (validUntil == 0 && !_isEmptyAttribution(attribution)) {
            revert InvalidSellerSignature();
        }
        _requireSupportedToken(token);

        _validateReferrerPair(
            buyer, seller, attribution.referrer, attribution.referrer2
        );
        _validateAttributionNodes(
            buyer,
            seller,
            attribution.referrer,
            attribution.referrer2,
            attribution.listingNode,
            attribution.sellingNode
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
            amount: amount,
            expiry: block.timestamp + duration, // solhint-disable-line not-rely-on-time
            createdAt: block.timestamp, // solhint-disable-line not-rely-on-time
            resolved: false,
            disputed: false,
            delivered: false,
            inspectionDeadline: 0,
            token: token,
            listingNode: attribution.listingNode,
            sellingNode: attribution.sellingNode,
            disputeOpenedAt: 0,
            disputeFee: 0
        });

        emit EscrowToken(escrowId, token);
        emit EscrowAttribution(
            escrowId, attribution.listingNode, attribution.sellingNode
        );

        if (
            attribution.referrer != address(0) ||
            attribution.referrer2 != address(0)
        ) {
            escrowReferrers[escrowId] = EscrowReferrers({
                referrer: attribution.referrer,
                referrer2: attribution.referrer2
            });
            emit EscrowReferrersSet(
                escrowId, attribution.referrer, attribution.referrer2
            );
        }

        emit EscrowCreated(escrowId, buyer, seller, amount, escrows[escrowId].expiry);
    }

    /**
     * @notice The empty attribution set (no referrers, no nodes)
     */
    function _noAttribution() private pure returns (FeeAttribution memory) {
        return FeeAttribution(address(0), address(0), address(0), address(0));
    }

    /**
     * @notice Whether an attribution set nominates nobody
     */
    function _isEmptyAttribution(
        FeeAttribution memory attribution
    ) private pure returns (bool) {
        return
            attribution.referrer == address(0) &&
            attribution.referrer2 == address(0) &&
            attribution.listingNode == address(0) &&
            attribution.sellingNode == address(0);
    }

    /**
     * @notice Require the seller's EIP-712 consent over a non-empty set
     * @dev Zero sets are allowed unsigned. Otherwise the digest binds the
     *      chain (domain separator), this escrow, the token, the seller and
     *      every attribution slot, plus `validUntil`.
     */
    function _requireSellerAttribution(
        address seller,
        address token,
        FeeAttribution calldata attribution,
        uint256 validUntil,
        bytes calldata sellerSignature
    ) private view {
        if (_isEmptyAttribution(attribution)) {
            // An empty set needs no consent; a stray deadline/signature is
            // ignored rather than rejected so clients can always call once.
            return;
        }
        bytes32 digest = EscrowSignatureLib.hashAttribution(
            _domainSeparatorV4(),
            seller,
            token,
            attribution.referrer,
            attribution.referrer2,
            attribution.listingNode,
            attribution.sellingNode,
            validUntil
        );
        // Returns on success; reverts InvalidSellerSignature otherwise.
        EscrowSignatureLib.verifyAttribution(
            digest, sellerSignature, seller, validUntil
        );
    }

    /**
     * @notice Release funds to seller (happy path)
     * @dev Both buyer and seller must agree
     * @param escrowId Escrow to release
     */
    function releaseFunds(uint256 escrowId) external nonReentrant whenNotPaused {
        Escrow storage escrow = escrows[escrowId];

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
    function markDelivered(uint256 escrowId) external {
        Escrow storage escrow = escrows[escrowId];

        if (escrow.buyer == address(0)) revert EscrowNotFound();
        // Private escrows have no permissionless seller-release path
        // (releaseExpiredToSeller rejects them), so a delivery flag would only
        if (escrow.resolved) revert AlreadyResolved();
        // 🛑 Delivery is a FACT, not a payout, so it stays recordable while a
        // dispute is open. Refusing it let a buyer freeze the escrow one block
        // before delivery and keep `delivered` false — which handed them the
        // whole principal on the timeout refund (re-audit D-1). This call moves
        // no money: {releaseExpiredToSeller} and {refundBuyer} still refuse a
        // disputed escrow, and the timeout outcome is what reads the flag.
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

        // 🛑 Permissionless (re-audit D-2): the timeout is the only exit a
        // frozen escrow has when no verdict arrives, and its outcome is decided
        // by on-chain state (delivered or not), not by the caller. Restricting
        // it to the buyer let that buyer lock a DELIVERED escrow's principal
        // forever, because calling it would pay the seller.

        // Must wait DISPUTE_TIMEOUT after the escrow expiry
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp < escrow.expiry + DISPUTE_TIMEOUT) {
            revert EscrowNotExpired();
        }

        // Refund buyer with no marketplace fee. No arbitration fee is charged:
        // no panel decided, so nobody earned one.
        escrow.resolved = true;
        uint256 amount = escrow.amount;
        escrow.amount = 0;
        address token = escrow.token;
        totalEscrowed[token] -= amount;

        // 🛑 A DELIVERED escrow times out to the SELLER (audit C-1), but only
        // when the delivery was asserted BEFORE the freeze: `inspectionDeadline`
        // is `deliveredAt + INSPECTION_PERIOD`, so this compares the assertion
        // against `disputeOpenedAt`. A seller who marks delivery after the buyer
        // disputed gains nothing from it (re-audit N-1) — the older claim wins,
        // and the seller's route is a signed verdict, not the timeout.
        address recipient = escrow.buyer;
        uint256 payout = amount;
        if (
            escrow.delivered &&
            escrow.inspectionDeadline - INSPECTION_PERIOD <= escrow.disputeOpenedAt
        ) {
            // The buyer's inspection window must also have elapsed: otherwise a
            // delivery marked one block earlier would pay the seller before the
            // buyer could inspect (re-audit N-1.3).
            // solhint-disable-next-line not-rely-on-time
            if (block.timestamp <= escrow.inspectionDeadline) {
                revert InspectionWindowOpen();
            }
            recipient = escrow.seller;
            payout = _collectMarketplaceFee(escrowId, token, amount);
        }

        // Use pull pattern for fund disbursement
        claimable[token][recipient] += payout;
        totalClaimable[token] += payout;
        emit FundsClaimable(recipient, token, payout);

        emit EscrowResolved(escrowId, recipient, payout);
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
     * @notice Freeze an escrow for the judge panel (called by a party)
     * @dev V4: on a chain that has no local arbitration contract, the buyer or
     *      seller opens the dispute HERE first, so neither party can unilaterally
     *      release or refund while the panel deliberates. The dispute itself
     *      lives on the panel's chain; this call only freezes the money and
     *      records who froze it.
     *
     *      A disputed escrow can only be settled by a 2-of-3 signed verdict
     *      ({executeVerdict}) or by the trustless {claimDisputeTimeout} refund
     *      that fires DISPUTE_TIMEOUT after expiry — the same backstop a panel
     *      escrow already relies on. That backstop is what keeps a party from
     *      freezing funds forever.
     * @param escrowId Escrow to freeze
     */
    function openDispute(uint256 escrowId) external nonReentrant whenNotPaused {
        Escrow storage e = escrows[escrowId];
        if (e.buyer == address(0)) revert EscrowNotFound();
        if (e.resolved) revert AlreadyResolved();
        if (e.disputed) revert AlreadyDisputed();
        address caller = _msgSender();
        if (caller != e.buyer && caller != e.seller) revert NotParticipant();

        // 🛑 FILING IS FREE AND NOTHING IS STAKED (founder decision
        // 2026-10-27). The arbitration fee comes out of the escrow's own
        // payout at resolution, so it is collectible in full without either
        // party posting anything. A stake here only re-created the friction
        // that left real disputes half-funded and unarbitrable.
        //
        // The fee is SNAPSHOTTED now, so the number the filer was shown is the
        // number charged even if the parameters are tuned while the case runs.
        uint256 fee = _arbitrationFee(e.amount, e.token);
        // Refuse a dispute whose fee would eat more than `maxArbitrationFeeBps`
        // of the sale (default a quarter). Below that, arbitration costs more
        // than the amount in dispute.
        if (fee * BASIS_POINTS > e.amount * maxArbitrationFeeBps) {
            revert FeeTooLarge();
        }

        e.disputed = true;
        // solhint-disable-next-line not-rely-on-time
        e.disputeOpenedAt = uint128(block.timestamp);
        e.disputeFee = uint128(fee);

        emit EscrowDisputeOpened(escrowId, caller, fee);
    }

    /**
     * @notice Execute a FINAL judge verdict delivered as EIP-712 signatures
     * @dev V4 (founder decision 3): the judge panel lives on the OmniCoin L1
     *      chain with the stakes and the seat bonds, and can sit over a sale
     *      escrowed on another chain. Its verdict travels as signatures from
     *      two DISTINCT seated judges over this escrow's EIP-712 domain, so no
     *      cross-chain call or bridge is involved.
     *
     *      This is compensation, never reversal: a verdict pays the seller
     *      (releaseFunds = true, marketplace fee charged) or refunds the buyer
     *      (false, no fee), once, on an escrow that is already frozen by
     *      {openDispute} or {markDisputed}. `resolved` makes it single-use.
     *
     *      Signature checks (see {EscrowSignatureLib.verifyVerdict}): every
     *      supplied signature must be valid, from a rostered judge, distinct,
     *      and not the buyer or the seller; the bundle must still be inside
     *      `validUntil`.
     * @param escrowId Escrow the verdict applies to
     * @param releaseFunds True = pay the seller, false = refund the buyer
     * @param validUntil Unix time the judges signed as the bundle deadline
     * @param signatures Two or more judge signatures (65 bytes each)
     */
    function executeVerdict(
        uint256 escrowId,
        bool releaseFunds,
        uint256 validUntil,
        bytes[] calldata signatures
    ) external nonReentrant whenNotPaused {
        Escrow storage e = escrows[escrowId];
        if (e.buyer == address(0)) revert EscrowNotFound();
        if (e.resolved) revert AlreadyResolved();
        if (!e.disputed) revert NotDisputed();
        // 🛑 The verdict window closes STRICTLY BEFORE the trustless timeout
        // opens (expiry + DISPUTE_TIMEOUT). Without the gap both paths are
        // callable in the same block at the boundary, so whichever party pays
        // gas first decides the outcome — a losing party could beat a verdict
        // with a timeout refund.
        // solhint-disable-next-line not-rely-on-time
        if (validUntil > e.expiry + VERDICT_WINDOW) revert InvalidVerdict();

        // Recovers EVERY signer presented, on either direction, so a judge who
        // dissented is still paid. Reverts unless two distinct rostered
        // non-party judges signed the requested direction.
        address[] memory signers = EscrowSignatureLib.verifyVerdict(
            _domainSeparatorV4(),
            escrowId,
            releaseFunds,
            validUntil,
            signatures,
            verdictJudge,
            e.buyer,
            e.seller
        );
        _resolve(escrowId, releaseFunds, signers);
        emit VerdictExecuted(escrowId, releaseFunds, validUntil);
    }

    /**
     * @notice Settle a disputed escrow from a judge verdict
     * @dev Pays the seller (charging the in-kind 1%) or refunds the buyer,
     *      deducts the arbitration fee SNAPSHOTTED at {openDispute} from that
     *      payout, credits the judges and the submitter, and credits the payee
     *      through the pull-pattern ledger.
     *
     *      🛑 The fee never comes from a stake and never touches principal:
     *      it is a share of the disputed amount taken out of what the escrow
     *      was going to pay anyway. That is the only collection path a party
     *      cannot starve by declining to participate.
     * @param escrowId Escrow to resolve
     * @param releaseFunds True = pay the seller, false = refund the buyer
     * @param signers Every judge whose signature the bundle carried
     */
    function _resolve(
        uint256 escrowId,
        bool releaseFunds,
        address[] memory signers
    ) private {
        Escrow storage e = escrows[escrowId];

        if (e.buyer == address(0)) revert EscrowNotFound();
        if (e.resolved) revert AlreadyResolved();
        if (!e.disputed) revert NotDisputed();

        e.resolved = true;

        uint256 amount = e.amount;
        e.amount = 0;
        address tokenAddr = e.token;
        uint256 fee = e.disputeFee;
        e.disputeFee = 0;

        totalEscrowed[tokenAddr] -= amount;

        address recipient;
        uint256 recipientAmount;

        if (releaseFunds) {
            // Release to seller: the in-kind 1% split runs on this chain.
            recipient = e.seller;
            recipientAmount = _collectMarketplaceFee(escrowId, tokenAddr, amount);
        } else {
            // Refund to buyer (no marketplace fee)
            recipient = e.buyer;
            recipientAmount = amount;
        }

        // 🛑 THE FEE COMES OUT OF THE PAYOUT. Guarded so no parameter change
        // can ever make the fee exceed what is being paid out.
        if (fee >= recipientAmount) revert InvalidFeeConfig();
        recipientAmount -= fee;
        _payArbitrationFee(escrowId, tokenAddr, fee, signers);

        // M-01: pull-pattern disbursement — a reverting recipient can never
        // block a resolution.
        claimable[tokenAddr][recipient] += recipientAmount;
        totalClaimable[tokenAddr] += recipientAmount;
        emit FundsClaimable(recipient, tokenAddr, recipientAmount);

        emit DisputeResolvedByArbitration(
            escrowId, releaseFunds, recipient, recipientAmount
        );
        emit EscrowResolved(escrowId, recipient, recipientAmount);
    }

    /**
     * @notice Reject an escrow token the fee vault will not settle
     * @dev Single source of truth: the vault's own allowlist. A token must
     *      also have code — a plain address has no ERC-20 behaviour and every
     *      transfer against it would revert after the buyer had committed.
     * @param token ERC-20 address supplied by the buyer
     */
    function _requireSupportedToken(address token) private view {
        // Each validator returns `true` on success. That return value is the
        // mislink guard: a DELEGATECALL to an address with no code SUCCEEDS
        // with empty returndata, so a validator that returned nothing would
        // silently pass every check if the library were linked wrong. Decoding
        // the bool makes that case revert instead.
        //
        // The allowlist is THIS contract's own mapping (founder decision 3):
        // the escrow never reads another chain's vault.
        if (
            !EscrowFeeRouter.requireSupportedToken(
                supportedToken,
                token,
                address(PRIVATE_OMNI_COIN),
                address(this)
            )
        ) {
            revert AllowlistUnavailable();
        }
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
    ) private view {
        // Same burn rule as {_validateReferrerPair}: the escrow itself can
        // never collect a credit.
        if (listingNode == address(this) || sellingNode == address(this)) {
            revert BadAttribution();
        }
        // Returns true; see {_requireSupportedToken} for why the value matters.
        if (
            !EscrowFeeRouter.validateAttributionNodes(
                buyer, seller, referrer, referrer2, listingNode, sellingNode
            )
        ) {
            revert BadAttribution();
        }
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
    ) private view {
        // A referral slice credited to this contract could never be withdrawn
        // (nothing can call withdrawClaimable as the escrow), so it would be
        // burned out of the seller's proceeds.
        if (referrer == address(this) || referrer2 == address(this)) {
            revert BadReferrer();
        }
        // Returns true; see {_requireSupportedToken} for why the value matters.
        if (!EscrowFeeRouter.validateReferrerPair(buyer, seller, referrer, referrer2)) {
            revert BadReferrer();
        }
    }

    /**
     * @notice Split the 1% marketplace fee in kind on THIS chain
     * @dev Fee = amount * MARKETPLACE_FEE_BPS / BASIS_POINTS, deducted from the
     *      seller's proceeds and credited to the nine canonical recipients as
     *      pull-pattern claims in the escrow's own token (see
     *      {EscrowFeeRouter.collectMarketplaceFee}). No cross-chain call: the
     *      escrow holds the fee, so settlement can never depend on another
     *      chain's vault.
     *
     *      Caller must have already zeroed the escrow amount and decremented
     *      totalEscrowed (CEI) before invoking.
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
        // executes in THIS contract's storage context: the `claimable` and
        // `totalMarketplaceFees` slots and the events are the escrow's own.
        EscrowReferrers storage refs = escrowReferrers[escrowId];
        Escrow storage e = escrows[escrowId];
        return
            EscrowFeeRouter.collectMarketplaceFee(
                claimable,
                totalClaimable,
                totalMarketplaceFees,
                escrowId,
                token,
                amount,
                MARKETPLACE_FEE_BPS,
                FeeAttribution({
                    referrer: refs.referrer,
                    referrer2: refs.referrer2,
                    listingNode: e.listingNode,
                    sellingNode: e.sellingNode
                }),
                FeeBeneficiaries({
                    oddao: ODDAO,
                    stakingPool: STAKING_POOL,
                    treasury: PROTOCOL_TREASURY
                })
            );
    }

    /**
     * @notice The three protocol fee sinks on this chain
     */
    function _beneficiaries() private view returns (FeeBeneficiaries memory) {
        return
            FeeBeneficiaries({
                oddao: ODDAO,
                stakingPool: STAKING_POOL,
                treasury: PROTOCOL_TREASURY
            });
    }

    /**
     * @notice The arbitration fee for one disputed escrow, in its own token
     * @dev Percentage of the disputed amount with a per-token floor. The floor
     *      exists because a share of a small sale is dust; the ceiling
     *      (`maxArbitrationFeeBps` of the amount) is enforced at filing.
     * @param amount Disputed principal
     * @param token Settlement token (the floor is per token, in its own units)
     * @return fee The fee, in `token` units
     */
    function _arbitrationFee(
        uint256 amount,
        address token
    ) private view returns (uint256 fee) {
        fee = (amount * arbitrationFeeBps) / BASIS_POINTS;
        uint256 floorFee = minArbitrationFee[token];
        if (fee < floorFee) fee = floorFee;
    }

    /**
     * @notice Credit the arbitration fee to the judges, the submitter and ODDAO
     * @dev The split lives in {EscrowFeeRouter} so the schedule can be tuned
     *      without growing this contract. `signers` carries EVERY judge the
     *      bundle named, so a dissenter is paid too.
     * @param escrowId Escrow identifier (for events)
     * @param token Fee token
     * @param fee Fee amount (non-zero)
     * @param signers Judges whose signatures were presented
     */
    function _payArbitrationFee(
        uint256 escrowId,
        address token,
        uint256 fee,
        address[] memory signers
    ) private {
        EscrowFeeRouter.payArbitrationFee(
            claimable,
            totalClaimable,
            escrowId,
            token,
            fee,
            signers,
            _msgSender(),
            ODDAO,
            judgePoolBps2,
            judgePoolBps3,
            submitterBps2,
            submitterBps3
        );
    }



    // ========================================================================
    // ARBITRATOR MANAGEMENT (Admin Only)
    // ========================================================================


    /**
     * @notice Add or remove a settlement token on THIS chain's allowlist
     * @dev Founder decision 3: each chain's escrow owns its list. A token must
     *      have code (a plain address has no ERC-20 behaviour and every
     *      transfer against it would revert after the buyer had committed) and
     *      may not be the escrow itself. Removing a token never blocks an
     *      existing escrow's settlement — releases only move the token the
     *      escrow already holds.
     * @param token ERC-20 address
     * @param allowed True to accept new escrows in this token
     */
    function setSupportedToken(address token, bool allowed) external onlyAdmin {
        if (token == address(0) || token == address(this)) {
            revert InvalidAddress();
        }
        if (allowed && token.code.length == 0) revert InvalidAddress();
        supportedToken[token] = allowed;
        emit SupportedTokenUpdated(token, allowed);
    }

    /**
     * @notice Add or remove a judge whose verdict signature this escrow honors
     * @dev The roster is the set of addresses the L1 panel seats. Two DISTINCT
     *      rostered judges execute a verdict ({executeVerdict}); a roster with
     *      fewer than two entries makes every verdict unexecutable, which
     *      leaves the party-opened dispute to the 30-day timeout backstop. Only
     *      the admin can change it, and it can never include the escrow.
     * @param judge Judge address
     * @param allowed True to accept this judge's verdict signature
     */
    function setVerdictJudge(address judge, bool allowed) external onlyAdmin {
        if (judge == address(0) || judge == address(this)) {
            revert InvalidAddress();
        }
        if (verdictJudge[judge] == allowed) return;
        if (allowed) {
            // 🛑 The panel is three. More judges divide the fee and turn "2 of
            // 3" into "any 2 of N", which only lowers the bar for collusion.
            if (verdictJudgeCount >= MAX_VERDICT_JUDGES) {
                revert TooManyVerdictJudges();
            }
            ++verdictJudgeCount;
        } else {
            --verdictJudgeCount;
        }
        verdictJudge[judge] = allowed;
        emit VerdictJudgeUpdated(judge, allowed);
    }

    /**
     * @notice Set the arbitration fee and the ceiling on its share of a sale
     * @dev Both are policy, not code: tuning them must never need a redeploy.
     *      The fee is snapshotted per dispute, so a change here can never alter
     *      what an already-filed case costs.
     * @param feeBps Fee in basis points of the disputed amount (1..1000)
     * @param maxFeeOfAmountBps Ceiling as bps of the amount (1..5000)
     */
    function setArbitrationFee(
        uint256 feeBps,
        uint256 maxFeeOfAmountBps
    ) external onlyAdmin {
        if (
            feeBps == 0 ||
            feeBps > MAX_ARBITRATION_FEE_BPS ||
            maxFeeOfAmountBps == 0 ||
            maxFeeOfAmountBps > MAX_FEE_OF_AMOUNT_BPS
        ) {
            revert InvalidFeeConfig();
        }
        arbitrationFeeBps = feeBps;
        maxArbitrationFeeBps = maxFeeOfAmountBps;
        emit ArbitrationFeeConfigured(feeBps, maxFeeOfAmountBps);
    }

    /**
     * @notice Set the smallest arbitration fee for one token
     * @dev Per token because the contract cannot price tokens; one unit of the
     *      token's own denomination. Zero disables the floor.
     * @param token Settlement token
     * @param amount Minimum fee in that token's units
     */
    function setMinArbitrationFee(
        address token,
        uint256 amount
    ) external onlyAdmin {
        if (token == address(0)) revert InvalidAddress();
        minArbitrationFee[token] = amount;
        emit MinArbitrationFeeSet(token, amount);
    }

    /**
     * @notice Set the judge/submitter shares of the arbitration fee
     * @dev Two schedules, by how many judges signed (2, or 3+). ODDAO takes
     *      whatever is left, which is also where rounding dust lands. Each
     *      schedule must leave ODDAO at least 5% so the protocol is never
     *      crowded out of its own fee.
     * @param pool2 Judge pool when two judges signed (bps)
     * @param pool3 Judge pool when three signed (bps)
     * @param sub2 Submitter share when two judges signed (bps)
     * @param sub3 Submitter share when three signed (bps)
     */
    function setArbitrationSplit(
        uint256 pool2,
        uint256 pool3,
        uint256 sub2,
        uint256 sub3
    ) external onlyAdmin {
        if (pool2 > BASIS_POINTS || pool3 > BASIS_POINTS) {
            revert InvalidFeeConfig();
        }
        if (pool2 + sub2 > BASIS_POINTS || pool3 + sub3 > BASIS_POINTS) {
            revert InvalidFeeConfig();
        }
        if (
            BASIS_POINTS - pool2 - sub2 < 500 ||
            BASIS_POINTS - pool3 - sub3 < 500
        ) {
            revert InvalidFeeConfig();
        }
        judgePoolBps2 = pool2;
        judgePoolBps3 = pool3;
        submitterBps2 = sub2;
        submitterBps3 = sub3;
        emit ArbitrationSplitConfigured(pool2, pool3, sub2, sub3);
    }

    /**
     * @notice Propose new fee-recipient addresses
     * @dev Takes effect only after {BENEFICIARY_DELAY} and an explicit
     *      {acceptBeneficiaries}, so a compromised admin key cannot redirect
     *      the protocol's income in one transaction.
     */
    function proposeBeneficiaries(
        address oddao,
        address stakingPool,
        address treasury
    ) external onlyAdmin {
        if (
            oddao == address(0) ||
            stakingPool == address(0) ||
            treasury == address(0)
        ) {
            revert InvalidAddress();
        }
        if (
            oddao == stakingPool ||
            oddao == treasury ||
            stakingPool == treasury
        ) {
            revert InvalidAddress();
        }
        pendingOddao = oddao;
        pendingStakingPool = stakingPool;
        pendingTreasury = treasury;
        // solhint-disable-next-line not-rely-on-time
        beneficiaryProposedAt = block.timestamp;
        emit BeneficiariesProposed(oddao, stakingPool, treasury);
    }

    /**
     * @notice Install the proposed fee recipients once the delay has passed
     */
    function acceptBeneficiaries() external onlyAdmin {
        uint256 proposedAt = beneficiaryProposedAt;
        if (proposedAt == 0) revert NoPendingBeneficiaries();
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp < proposedAt + BENEFICIARY_DELAY) {
            revert BeneficiaryDelayActive();
        }
        ODDAO = pendingOddao;
        STAKING_POOL = pendingStakingPool;
        PROTOCOL_TREASURY = pendingTreasury;
        pendingOddao = address(0);
        pendingStakingPool = address(0);
        pendingTreasury = address(0);
        beneficiaryProposedAt = 0;
        emit BeneficiariesUpdated(ODDAO, STAKING_POOL, PROTOCOL_TREASURY);
    }

    /**
     * @notice The EIP-712 type hash a judge signs for a verdict
     * @dev Exposed so clients and the L1 panel build byte-identical digests.
     */
    function VERDICT_TYPEHASH() external pure returns (bytes32) {
        return EscrowSignatureLib.verdictTypehash();
    }

    /**
     * @notice The EIP-712 type hash a seller signs to authorize attribution
     */
    function ATTRIBUTION_TYPEHASH() external pure returns (bytes32) {
        return EscrowSignatureLib.attributionTypehash();
    }




    // ========================================================================
    // PRIVACY ESCROW FUNCTIONS
    // ========================================================================








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