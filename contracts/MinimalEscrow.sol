// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MpcCore, gtUint64, ctUint64, gtBool} from "../coti-contracts/contracts/utils/mpc/MpcCore.sol";
import {ERC2771Context} from "@openzeppelin/contracts/metatx/ERC2771Context.sol";
import {Context} from "@openzeppelin/contracts/utils/Context.sol";

/**
 * @title MinimalEscrow
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
 */
contract MinimalEscrow is ReentrancyGuard, Pausable, ERC2771Context {
    using SafeERC20 for IERC20;
    using MpcCore for gtUint64;
    using MpcCore for ctUint64;
    using MpcCore for gtBool;

    // Type declarations
    /// @notice Escrow state information
    struct Escrow {
        address buyer;        // slot 1: 20 bytes
        address seller;       // slot 2: 20 bytes
        address arbitrator;   // slot 3: 20 bytes
        uint8 releaseVotes;   // slot 3: 1 byte
        uint8 refundVotes;    // slot 3: 1 byte
        bool resolved;        // slot 3: 1 byte
        bool disputed;        // slot 3: 1 byte (total: 24 bytes in slot 3)
        uint256 amount;       // slot 4: 32 bytes
        uint256 expiry;       // slot 5: 32 bytes
        uint256 createdAt;    // slot 6: 32 bytes
    }

    /// @notice Dispute commitment for commit-reveal pattern
    struct DisputeCommitment {
        bytes32 commitment;
        uint256 revealDeadline;
        bool revealed;
    }

    // Constants
    /// @notice Maximum escrow duration (30 days)
    uint256 public constant MAX_DURATION = 30 days;

    /// @notice Minimum escrow duration (1 hour)
    uint256 public constant MIN_DURATION = 1 hours;

    /// @notice Time before arbitrator can be assigned (24 hours)
    uint256 public constant ARBITRATOR_DELAY = 24 hours;

    /// @notice Dispute stake amount (0.1% of escrow)
    uint256 public constant DISPUTE_STAKE_BASIS = 10; // 0.1%

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
    /// @dev Per spec: 5% of disputed amount, split 50/50 between buyer and seller,
    ///      distributed 70% Arbitrator / 20% Validator / 10% ODDAO via FEE_COLLECTOR
    uint256 public constant ARBITRATION_FEE_BPS = 500;

    // State variables (immutables first)
    /// @notice OmniCoin token (XOM)
    IERC20 public immutable OMNI_COIN;

    /// @notice Private OmniCoin token (pXOM) for private escrows
    IERC20 public immutable PRIVATE_OMNI_COIN;

    /// @notice Registry contract for service lookups
    address public immutable REGISTRY;

    /// @notice Address that receives marketplace fees on escrow release
    /// @dev Fee distribution design: This contract sends 100% of collected fees to
    ///      FEE_COLLECTOR, which is expected to be a fee-splitting contract (e.g.,
    ///      OmniFeeRouter) that implements the OmniBazaar 70/20/10 distribution:
    ///      Transaction Fee (0.50%): 70% ODDAO, 20% Validator, 10% Staking Pool
    ///      Referral Fee (0.25%): 70% Referrer, 20% Second-Level Referrer, 10% ODDAO
    ///      Listing Fee (0.25%): 70% Listing Node, 20% Selling Node, 10% ODDAO
    ///      This separation of concerns keeps the escrow contract simple and allows
    ///      fee distribution logic to be upgraded independently.
    address public immutable FEE_COLLECTOR;

    /// @notice Marketplace fee in basis points (e.g., 100 = 1%)
    uint256 public immutable MARKETPLACE_FEE_BPS;

    /// @notice Contract admin (deployer) for arbitrator management
    address public immutable ADMIN;

    // Non-immutable state variables
    /// @notice Total marketplace fees collected per token (for transparency)
    mapping(address => uint256) public totalMarketplaceFees;

    /// @notice Escrow counter for unique IDs
    uint256 public escrowCounter;

    /// @notice Mapping of escrow ID to escrow data
    mapping(uint256 => Escrow) public escrows;

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

    /// @notice Emitted when arbitration fee is deducted from disputed escrow resolution
    /// @param escrowId Escrow identifier
    /// @param totalArbitrationFee Total arbitration fee collected
    /// @param arbitratorShare Amount sent to arbitrator
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

    // Custom errors
    error InvalidAddress();
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
    error InsufficientStake();
    error PrivacyNotAvailable();
    error CannotMixPrivacyModes();
    error AmountTooLarge();
    error NoArbitratorsAvailable();
    error OnlyAdmin();
    error NotDisputed();
    error StakeAlreadyPosted();
    error TooManyArbitrators();
    error EscrowNotExpired();

    /// @notice Caller is not the authorized arbitration contract
    error OnlyArbitrationContract();
    error NothingToClaim();

    /// @notice Restrict to admin only
    modifier onlyAdmin() {
        if (msg.sender != ADMIN) revert OnlyAdmin();
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
     * @param _feeCollector Address receiving marketplace fees
     * @param _marketplaceFeeBps Fee in basis points (e.g. 100 = 1%)
     * @param trustedForwarder_ OmniForwarder address for gasless relay (address(0) to disable)
     */
    constructor(
        address _omniCoin,
        address _privateOmniCoin,
        address _registry,
        address _feeCollector,
        uint256 _marketplaceFeeBps,
        address trustedForwarder_
    ) ERC2771Context(trustedForwarder_) {
        if (
            _omniCoin == address(0) ||
            _privateOmniCoin == address(0) ||
            _registry == address(0) ||
            _feeCollector == address(0)
        ) {
            revert InvalidAddress();
        }
        if (_marketplaceFeeBps > MAX_MARKETPLACE_FEE_BPS) {
            revert InvalidFeeConfig();
        }
        OMNI_COIN = IERC20(_omniCoin);
        PRIVATE_OMNI_COIN = IERC20(_privateOmniCoin);
        REGISTRY = _registry;
        FEE_COLLECTOR = _feeCollector;
        MARKETPLACE_FEE_BPS = _marketplaceFeeBps;
        ADMIN = msg.sender;

        // solhint-disable-next-line not-rely-on-time
        arbitratorSeed = uint256(keccak256(abi.encodePacked(
            block.timestamp,
            block.prevrandao
        )));

        // Detect if privacy is available (COTI network check)
        privacyEnabled = _detectPrivacyAvailability();
    }

    /**
     * @notice Create a new escrow
     * @dev Buyer creates escrow with seller address and token amount
     * @param seller Seller address
     * @param amount Amount of OmniCoin tokens to escrow
     * @param duration Escrow duration in seconds
     * @return escrowId Unique escrow identifier
     */
    function createEscrow(
        address seller,
        uint256 amount,
        uint256 duration
    ) external nonReentrant whenNotPaused returns (uint256 escrowId) {
        address buyer = _msgSender();
        if (seller == address(0) || seller == buyer) revert InvalidAddress();
        if (amount == 0) revert InvalidAmount();
        if (duration < MIN_DURATION || duration > MAX_DURATION) revert InvalidDuration();

        // Transfer tokens from buyer to escrow
        OMNI_COIN.safeTransferFrom(buyer, address(this), amount);
        totalEscrowed[address(OMNI_COIN)] += amount;

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
            disputed: false
        });

        emit EscrowCreated(escrowId, buyer, seller, amount, escrows[escrowId].expiry);
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
        // L-05: Only buyer can release funds to seller
        if (_msgSender() != escrow.buyer) revert NotParticipant();

        // Simple 2-party agreement (undisputed release by buyer)
        if (!escrow.disputed) {
            escrow.resolved = true;
            uint256 amount = escrow.amount;
            escrow.amount = 0;

            totalEscrowed[address(OMNI_COIN)] -= amount;

            // Deduct marketplace fee before paying seller
            uint256 feeAmount = (amount * MARKETPLACE_FEE_BPS) / BASIS_POINTS;
            uint256 sellerAmount = amount - feeAmount;

            if (feeAmount > 0) {
                OMNI_COIN.safeTransfer(FEE_COLLECTOR, feeAmount);
                totalMarketplaceFees[address(OMNI_COIN)] += feeAmount;
                emit MarketplaceFeeCollected(escrowId, FEE_COLLECTOR, feeAmount);
            }
            OMNI_COIN.safeTransfer(escrow.seller, sellerAmount);
            emit EscrowResolved(escrowId, escrow.seller, sellerAmount);
        }
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
        address caller = _msgSender();
        // M-04: Only buyer or seller can trigger refund (prevents griefing by third parties)
        if (caller != escrow.buyer && caller != escrow.seller) revert NotParticipant();

        bool canRefund = false;

        // Seller agrees to refund
        if (caller == escrow.seller && !escrow.disputed) {
            canRefund = true;
        }

        // Expired and no dispute - only buyer can claim expired refund
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp > escrow.expiry && !escrow.disputed && caller == escrow.buyer) {
            canRefund = true;
        }

        if (canRefund) {
            escrow.resolved = true;
            uint256 amount = escrow.amount;
            escrow.amount = 0;

            totalEscrowed[address(OMNI_COIN)] -= amount;
            OMNI_COIN.safeTransfer(escrow.buyer, amount);
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

        // Must wait minimum time before dispute
        uint256 disputeEarliest = escrow.createdAt + ARBITRATOR_DELAY;
        if (block.timestamp < disputeEarliest) revert DisputeTooEarly(); // solhint-disable-line not-rely-on-time

        // Require dispute stake (paid in OmniCoin)
        uint256 requiredStake = (escrow.amount * DISPUTE_STAKE_BASIS) / BASIS_POINTS;
        OMNI_COIN.safeTransferFrom(caller, address(this), requiredStake);
        disputeStakes[escrowId][caller] = requiredStake;
        totalEscrowed[address(OMNI_COIN)] += requiredStake;

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
        Escrow storage escrow = escrows[escrowId];
        DisputeCommitment storage commitment = disputeCommitments[escrowId];

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
        if (!escrow.disputed) revert NotDisputed();

        address caller = _msgSender();
        // Only the counterparty (the party who did NOT initiate the dispute) can post
        if (caller != escrow.buyer && caller != escrow.seller) {
            revert NotParticipant();
        }

        // Prevent double-staking
        if (disputeStakes[escrowId][caller] != 0) revert StakeAlreadyPosted();

        // Calculate the same stake amount the initiator paid
        // Use the original escrow amount stored at creation (escrow.amount may include
        // the dispute initiator's amount, but we use escrow.amount which was set before
        // any dispute mechanics changed it)
        uint256 requiredStake = (escrow.amount * DISPUTE_STAKE_BASIS) / BASIS_POINTS;
        if (requiredStake == 0) revert InsufficientStake();

        OMNI_COIN.safeTransferFrom(caller, address(this), requiredStake);
        disputeStakes[escrowId][caller] = requiredStake;
        totalEscrowed[address(OMNI_COIN)] += requiredStake;

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
        totalEscrowed[address(OMNI_COIN)] -= stake;
        OMNI_COIN.safeTransfer(caller, stake);

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
        if (!escrow.disputed) revert NotDisputed();

        address caller = _msgSender();
        if (caller != escrow.buyer) revert NotParticipant();

        // Must wait DISPUTE_TIMEOUT after the escrow expiry
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp < escrow.expiry + DISPUTE_TIMEOUT) {
            revert EscrowNotExpired();
        }

        // Refund buyer with no marketplace fee
        escrow.resolved = true;
        uint256 amount = escrow.amount;
        escrow.amount = 0;
        totalEscrowed[address(OMNI_COIN)] -= amount;

        // Use pull pattern for fund disbursement
        claimable[address(OMNI_COIN)][escrow.buyer] += amount;
        totalClaimable[address(OMNI_COIN)] += amount;
        emit FundsClaimable(escrow.buyer, address(OMNI_COIN), amount);

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
     * @notice Get the escrowed amount
     * @dev H-01 OmniArbitration Round 6: Implements the
     *      IArbitrationEscrow.getAmount() interface so
     *      OmniArbitration can read the disputed amount.
     *      PRIV-H03: Returns 0 for private escrows because the
     *      plaintext amount is not stored in the Escrow struct.
     *      Use getEncryptedAmount() for private escrow amounts.
     * @param escrowId Escrow identifier
     * @return Amount in XOM (0 if escrow does not exist,
     *         already resolved, or is a private escrow)
     */
    function getAmount(
        uint256 escrowId
    ) external view returns (uint256) {
        return escrows[escrowId].amount;
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
     *      - Escrow must exist and not be already resolved
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

        e.resolved = true;
        uint256 amount = e.amount;
        e.amount = 0;

        totalEscrowed[address(OMNI_COIN)] -= amount;

        address recipient;
        uint256 recipientAmount = amount;

        if (releaseFunds) {
            // Release to seller (with marketplace fee)
            recipient = e.seller;
            uint256 feeAmount =
                (amount * MARKETPLACE_FEE_BPS) / BASIS_POINTS;
            recipientAmount = amount - feeAmount;

            if (feeAmount > 0) {
                OMNI_COIN.safeTransfer(
                    FEE_COLLECTOR, feeAmount
                );
                totalMarketplaceFees[address(OMNI_COIN)] +=
                    feeAmount;
                emit MarketplaceFeeCollected(
                    escrowId, FEE_COLLECTOR, feeAmount
                );
            }
        } else {
            // Refund to buyer (no marketplace fee)
            recipient = e.buyer;
        }

        // Deduct arbitration fee from dispute stakes if disputed
        if (e.disputed) {
            uint256 arbitrationFee =
                (amount * ARBITRATION_FEE_BPS) / BASIS_POINTS;
            uint256 halfFee = arbitrationFee / 2;
            uint256 otherHalf = arbitrationFee - halfFee;

            uint256 buyerStake =
                disputeStakes[escrowId][e.buyer];
            uint256 buyerDeduction =
                halfFee > buyerStake ? buyerStake : halfFee;
            disputeStakes[escrowId][e.buyer] =
                buyerStake - buyerDeduction;

            uint256 sellerStake =
                disputeStakes[escrowId][e.seller];
            uint256 sellerDeduction =
                otherHalf > sellerStake
                    ? sellerStake
                    : otherHalf;
            disputeStakes[escrowId][e.seller] =
                sellerStake - sellerDeduction;

            uint256 totalCollected =
                buyerDeduction + sellerDeduction;
            if (totalCollected > 0) {
                totalEscrowed[address(OMNI_COIN)] -=
                    totalCollected;
                OMNI_COIN.safeTransfer(
                    FEE_COLLECTOR, totalCollected
                );
                emit ArbitrationFeeCollected(
                    escrowId,
                    totalCollected,
                    (totalCollected * 7000) / BASIS_POINTS
                );
            }
        }

        // M-01: Use pull pattern for fund disbursement
        claimable[address(OMNI_COIN)][recipient] +=
            recipientAmount;
        totalClaimable[address(OMNI_COIN)] += recipientAmount;
        emit FundsClaimable(
            recipient, address(OMNI_COIN), recipientAmount
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

        // Deterministic seed from historic data (not manipulable post-commit)
        uint256 seed = uint256(keccak256(abi.encodePacked(
            escrow.createdAt,
            arbitratorSeed,
            nonce,
            escrowId
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
     *      arbitration fee (split 50/50 from buyer and seller stakes via FEE_COLLECTOR).
     *      Marketplace fee only applies when releasing to the seller (not on refunds).
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
        totalEscrowed[address(OMNI_COIN)] -= amount;

        uint256 recipientAmount = amount;

        // Marketplace fee only charged when releasing to seller (successful transaction)
        if (recipient == escrow.seller) {
            uint256 feeAmount = (amount * MARKETPLACE_FEE_BPS) / BASIS_POINTS;
            recipientAmount = amount - feeAmount;
            if (feeAmount > 0) {
                OMNI_COIN.safeTransfer(FEE_COLLECTOR, feeAmount);
                totalMarketplaceFees[address(OMNI_COIN)] += feeAmount;
                emit MarketplaceFeeCollected(escrowId, FEE_COLLECTOR, feeAmount);
            }
        }

        // Deduct arbitration fee when escrow was disputed (5% of escrow amount)
        // Per spec: split 50/50 from buyer and seller, sent to FEE_COLLECTOR
        // which distributes 70% Arbitrator / 20% Validator / 10% ODDAO
        if (escrow.disputed) {
            uint256 arbitrationFee = (amount * ARBITRATION_FEE_BPS) / BASIS_POINTS;
            // Each party pays half from their dispute stake
            uint256 halfFee = arbitrationFee / 2;
            uint256 otherHalf = arbitrationFee - halfFee; // handles rounding

            // Deduct from buyer stake
            uint256 buyerStake = disputeStakes[escrowId][escrow.buyer];
            uint256 buyerDeduction = halfFee > buyerStake ? buyerStake : halfFee;
            disputeStakes[escrowId][escrow.buyer] = buyerStake - buyerDeduction;

            // Deduct from seller stake
            uint256 sellerStake = disputeStakes[escrowId][escrow.seller];
            uint256 sellerDeduction = otherHalf > sellerStake ? sellerStake : otherHalf;
            disputeStakes[escrowId][escrow.seller] = sellerStake - sellerDeduction;

            uint256 totalCollected = buyerDeduction + sellerDeduction;
            if (totalCollected > 0) {
                // Decrement totalEscrowed for arbitration fee portion of stakes
                totalEscrowed[address(OMNI_COIN)] -= totalCollected;
                OMNI_COIN.safeTransfer(FEE_COLLECTOR, totalCollected);
                emit ArbitrationFeeCollected(
                    escrowId, totalCollected, (totalCollected * 7000) / BASIS_POINTS
                );
            }
        }

        // M-01: Use pull pattern to prevent DoS via reverting recipients.
        // Note: totalEscrowed already decremented at line 688 for full amount.
        // We only need to credit the claimable balance (no double-decrement).
        claimable[address(OMNI_COIN)][recipient] += recipientAmount;
        totalClaimable[address(OMNI_COIN)] += recipientAmount;
        emit FundsClaimable(recipient, address(OMNI_COIN), recipientAmount);

        // Return remaining dispute stakes to both parties (if any)
        _returnDisputeStake(escrowId, escrow.buyer);
        _returnDisputeStake(escrowId, escrow.seller);

        emit EscrowResolved(escrowId, recipient, recipientAmount);
    }

    /**
     * @notice Return dispute stake to a party
     * @dev Clears stake from mapping and transfers tokens
     * @param escrowId Escrow identifier
     * @param party Address to return stake to
     */
    function _returnDisputeStake(uint256 escrowId, address party) private {
        uint256 stakeAmount = disputeStakes[escrowId][party];
        if (stakeAmount > 0) {
            disputeStakes[escrowId][party] = 0;
            // M-01: Use pull pattern for stake returns
            totalEscrowed[address(OMNI_COIN)] -= stakeAmount;
            claimable[address(OMNI_COIN)][party] += stakeAmount;
            totalClaimable[address(OMNI_COIN)] += stakeAmount;
            emit FundsClaimable(party, address(OMNI_COIN), stakeAmount);
            emit DisputeStakeReturned(escrowId, party, stakeAmount);
        }
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
        if (seller == address(0) || seller == buyer) revert InvalidAddress();
        if (duration < MIN_DURATION || duration > MAX_DURATION) revert InvalidDuration();

        // Decrypt amount for token transfer (need plain value for ERC20)
        uint64 plainAmount = MpcCore.decrypt(encryptedAmount);
        if (plainAmount == 0) revert InvalidAmount();

        // Transfer pXOM tokens from buyer to escrow
        PRIVATE_OMNI_COIN.safeTransferFrom(buyer, address(this), uint256(plainAmount));
        totalEscrowed[address(PRIVATE_OMNI_COIN)] += uint256(plainAmount);

        escrowId = ++escrowCounter;

        // Store encrypted amount
        encryptedEscrowAmounts[escrowId] = MpcCore.offBoard(encryptedAmount);
        isPrivateEscrow[escrowId] = true;
        privateEscrowAmounts[escrowId] = uint256(plainAmount);

        escrows[escrowId] = Escrow({
            buyer: buyer,
            seller: seller,
            arbitrator: address(0),
            amount: 0, // PRIV-H03: Amount hidden for privacy; use getEncryptedAmount()
            expiry: block.timestamp + duration, // solhint-disable-line not-rely-on-time
            createdAt: block.timestamp, // solhint-disable-line not-rely-on-time
            releaseVotes: 0,
            refundVotes: 0,
            resolved: false,
            disputed: false
        });

        emit PrivateEscrowCreated(escrowId, buyer, seller, escrows[escrowId].expiry);
    }

    /**
     * @notice Release private escrow funds to seller
     * @dev Both buyer and seller must agree, amount remains encrypted
     * @param escrowId Private escrow to release
     */
    function releasePrivateFunds(uint256 escrowId) external nonReentrant {
        Escrow storage escrow = escrows[escrowId];

        if (!isPrivateEscrow[escrowId]) revert CannotMixPrivacyModes();
        if (escrow.buyer == address(0)) revert EscrowNotFound();
        if (escrow.resolved) revert AlreadyResolved();
        address caller = _msgSender();
        if (caller != escrow.buyer && caller != escrow.seller) revert NotParticipant();

        // Simple 2-party agreement (buyer releases to seller)
        if (!escrow.disputed && caller == escrow.buyer) {
            escrow.resolved = true;
            // PRIV-H03: Read from private mapping instead of escrow.amount
            uint256 amount = privateEscrowAmounts[escrowId];
            privateEscrowAmounts[escrowId] = 0;

            totalEscrowed[address(PRIVATE_OMNI_COIN)] -= amount;

            // Deduct marketplace fee before paying seller
            uint256 feeAmount = (amount * MARKETPLACE_FEE_BPS) / BASIS_POINTS;
            uint256 sellerAmount = amount - feeAmount;

            if (feeAmount > 0) {
                PRIVATE_OMNI_COIN.safeTransfer(FEE_COLLECTOR, feeAmount);
                totalMarketplaceFees[address(PRIVATE_OMNI_COIN)] += feeAmount;
                emit MarketplaceFeeCollected(escrowId, FEE_COLLECTOR, feeAmount);
            }
            // M-02 (Round 6): Use pull pattern for private escrow release
            claimable[address(PRIVATE_OMNI_COIN)][escrow.seller] += sellerAmount;
            totalClaimable[address(PRIVATE_OMNI_COIN)] += sellerAmount;
            emit FundsClaimable(escrow.seller, address(PRIVATE_OMNI_COIN), sellerAmount);
            emit PrivateEscrowResolved(escrowId, escrow.seller);
        }
    }

    /**
     * @notice Refund private escrow to buyer
     * @dev Seller can agree or buyer can claim after expiry
     * @param escrowId Private escrow to refund
     */
    function refundPrivateBuyer(uint256 escrowId) external nonReentrant {
        Escrow storage escrow = escrows[escrowId];

        if (!isPrivateEscrow[escrowId]) revert CannotMixPrivacyModes();
        if (escrow.buyer == address(0)) revert EscrowNotFound();
        if (escrow.resolved) revert AlreadyResolved();
        address caller = _msgSender();
        // M-04: Only buyer or seller can trigger refund (prevents griefing by third parties)
        if (caller != escrow.buyer && caller != escrow.seller) revert NotParticipant();

        bool canRefund = false;

        // Seller agrees to refund
        if (caller == escrow.seller && !escrow.disputed) {
            canRefund = true;
        }

        // Expired and no dispute - only buyer can claim expired refund
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp > escrow.expiry && !escrow.disputed && caller == escrow.buyer) {
            canRefund = true;
        }

        if (canRefund) {
            escrow.resolved = true;
            // PRIV-H03: Read from private mapping instead of escrow.amount
            uint256 amount = privateEscrowAmounts[escrowId];
            privateEscrowAmounts[escrowId] = 0;

            totalEscrowed[address(PRIVATE_OMNI_COIN)] -= amount;
            // M-02 (Round 6): Use pull pattern for private escrow refund
            claimable[address(PRIVATE_OMNI_COIN)][escrow.buyer] += amount;
            totalClaimable[address(PRIVATE_OMNI_COIN)] += amount;
            emit FundsClaimable(escrow.buyer, address(PRIVATE_OMNI_COIN), amount);
            emit PrivateEscrowResolved(escrowId, escrow.buyer);
        }
    }

    /**
     * @notice Vote on disputed private escrow outcome
     * @dev 2-of-3 multisig voting, amounts remain encrypted
     * @param escrowId Private escrow to vote on
     * @param voteForRelease True to release to seller, false to refund buyer
     */
    function votePrivate(uint256 escrowId, bool voteForRelease) external nonReentrant {
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
                PRIVATE_OMNI_COIN.safeTransfer(FEE_COLLECTOR, feeAmount);
                totalMarketplaceFees[address(PRIVATE_OMNI_COIN)] += feeAmount;
                emit MarketplaceFeeCollected(escrowId, FEE_COLLECTOR, feeAmount);
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
        // pXOM), so the same fee logic applies directly.
        if (escrow.disputed) {
            uint256 arbitrationFee = (amount * ARBITRATION_FEE_BPS) / BASIS_POINTS;
            uint256 halfFee = arbitrationFee / 2;
            uint256 otherHalf = arbitrationFee - halfFee;

            uint256 buyerStake = disputeStakes[escrowId][escrow.buyer];
            uint256 buyerDeduction = halfFee > buyerStake ? buyerStake : halfFee;
            disputeStakes[escrowId][escrow.buyer] = buyerStake - buyerDeduction;

            uint256 sellerStake = disputeStakes[escrowId][escrow.seller];
            uint256 sellerDeduction = otherHalf > sellerStake ? sellerStake : otherHalf;
            disputeStakes[escrowId][escrow.seller] = sellerStake - sellerDeduction;

            uint256 totalCollected = buyerDeduction + sellerDeduction;
            if (totalCollected > 0) {
                totalEscrowed[address(OMNI_COIN)] -= totalCollected;
                OMNI_COIN.safeTransfer(FEE_COLLECTOR, totalCollected);
                emit ArbitrationFeeCollected(
                    escrowId, totalCollected, (totalCollected * 7000) / BASIS_POINTS
                );
            }
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
     * @notice Detect if privacy features are available on current network
     * @dev Internal function to check for COTI V2 MPC support
     * @return enabled Whether privacy is supported
     */
    function _detectPrivacyAvailability() private view returns (bool enabled) {
        // On COTI V2 network, MPC precompiles are available
        // COTI Devnet: Chain ID 13068200
        // COTI Testnet: Chain ID 7082
        // For testing in Hardhat/Fuji, return false (MPC not available)
        return (block.chainid == 13068200 || block.chainid == 7082);
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