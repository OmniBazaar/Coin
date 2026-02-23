// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MpcCore, gtUint64, ctUint64, gtBool} from "../coti-contracts/contracts/utils/mpc/MpcCore.sol";

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
 */
contract MinimalEscrow is ReentrancyGuard, Pausable {
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

    // Privacy-related state variables
    /// @notice Encrypted amounts for private escrows (ct = ciphertext for storage)
    mapping(uint256 => ctUint64) private encryptedEscrowAmounts;

    /// @notice Flag indicating if an escrow is private
    mapping(uint256 => bool) public isPrivateEscrow;

    /// @notice Whether privacy features are enabled on this network
    bool private privacyEnabled;

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

    /// @notice Emitted when the counterparty posts a matching dispute stake
    /// @param escrowId Escrow identifier
    /// @param party Address posting the counter-stake
    /// @param amount Stake amount
    event CounterpartyStakePosted(
        uint256 indexed escrowId,
        address indexed party,
        uint256 amount
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
    error NothingToClaim();

    /**
     * @notice Initialize escrow with token and registry
     * @param _omniCoin OmniCoin token address (XOM)
     * @param _privateOmniCoin Private OmniCoin token address (pXOM)
     * @param _registry Registry contract address
     */
    /// @notice Restrict to admin only
    modifier onlyAdmin() {
        if (msg.sender != ADMIN) revert OnlyAdmin();
        _;
    }

    constructor(
        address _omniCoin,
        address _privateOmniCoin,
        address _registry,
        address _feeCollector,
        uint256 _marketplaceFeeBps
    ) {
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
        if (seller == address(0) || seller == msg.sender) revert InvalidAddress();
        if (amount == 0) revert InvalidAmount();
        if (duration < MIN_DURATION || duration > MAX_DURATION) revert InvalidDuration();
        
        // Transfer tokens from buyer to escrow
        OMNI_COIN.safeTransferFrom(msg.sender, address(this), amount);
        totalEscrowed[address(OMNI_COIN)] += amount;

        escrowId = ++escrowCounter;
        
        escrows[escrowId] = Escrow({
            buyer: msg.sender,
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
        
        emit EscrowCreated(escrowId, msg.sender, seller, amount, escrows[escrowId].expiry);
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
        if (msg.sender != escrow.buyer && msg.sender != escrow.seller) revert NotParticipant();
        
        // Simple 2-party agreement
        if (!escrow.disputed && msg.sender == escrow.buyer) {
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
        // M-04: Only buyer or seller can trigger refund (prevents griefing by third parties)
        if (msg.sender != escrow.buyer && msg.sender != escrow.seller) revert NotParticipant();

        bool canRefund = false;

        // Seller agrees to refund
        if (msg.sender == escrow.seller && !escrow.disputed) {
            canRefund = true;
        }

        // Expired and no dispute - only buyer can claim expired refund
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp > escrow.expiry && !escrow.disputed && msg.sender == escrow.buyer) {
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
        Escrow storage escrow = escrows[escrowId];
        
        if (escrow.buyer == address(0)) revert EscrowNotFound();
        if (escrow.resolved) revert AlreadyResolved();
        if (escrow.disputed) revert AlreadyDisputed();
        if (msg.sender != escrow.buyer && msg.sender != escrow.seller) revert NotParticipant();
        
        // Must wait minimum time before dispute
        uint256 disputeEarliest = escrow.createdAt + ARBITRATOR_DELAY;
        if (block.timestamp < disputeEarliest) revert DisputeTooEarly(); // solhint-disable-line not-rely-on-time
        
        // Require dispute stake (paid in OmniCoin)
        uint256 requiredStake = (escrow.amount * DISPUTE_STAKE_BASIS) / BASIS_POINTS;
        OMNI_COIN.safeTransferFrom(msg.sender, address(this), requiredStake);
        disputeStakes[escrowId][msg.sender] = requiredStake;
        totalEscrowed[address(OMNI_COIN)] += requiredStake;

        disputeCommitments[escrowId] = DisputeCommitment({
            commitment: commitment,
            revealDeadline: block.timestamp + 1 hours, // solhint-disable-line not-rely-on-time
            revealed: false
        });
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
        
        // Verify commitment
        bytes32 expectedHash = keccak256(abi.encodePacked(
            escrowId, 
            nonce, 
            msg.sender
        ));
        if (commitment.commitment != expectedHash) revert InvalidCommitment();
        
        commitment.revealed = true;
        escrow.disputed = true;
        
        // Deterministic arbitrator selection
        address arbitrator = selectArbitrator(escrowId, nonce);
        escrow.arbitrator = arbitrator;
        
        emit DisputeRaised(escrowId, msg.sender, arbitrator);
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

        // Only the counterparty (the party who did NOT initiate the dispute) can post
        if (msg.sender != escrow.buyer && msg.sender != escrow.seller) {
            revert NotParticipant();
        }

        // Prevent double-staking
        if (disputeStakes[escrowId][msg.sender] != 0) revert StakeAlreadyPosted();

        // Calculate the same stake amount the initiator paid
        // Use the original escrow amount stored at creation (escrow.amount may include
        // the dispute initiator's amount, but we use escrow.amount which was set before
        // any dispute mechanics changed it)
        uint256 requiredStake = (escrow.amount * DISPUTE_STAKE_BASIS) / BASIS_POINTS;
        if (requiredStake == 0) revert InsufficientStake();

        OMNI_COIN.safeTransferFrom(msg.sender, address(this), requiredStake);
        disputeStakes[escrowId][msg.sender] = requiredStake;
        totalEscrowed[address(OMNI_COIN)] += requiredStake;

        emit CounterpartyStakePosted(escrowId, msg.sender, requiredStake);
    }

    /**
     * @notice Vote on disputed escrow outcome
     * @dev 2-of-3 multisig voting
     * @param escrowId Escrow to vote on
     * @param voteForRelease True to release to seller, false to refund buyer
     */
    function vote(uint256 escrowId, bool voteForRelease) external nonReentrant whenNotPaused {
        Escrow storage escrow = escrows[escrowId];
        
        _validateVote(escrow, escrowId);
        
        hasVoted[escrowId][msg.sender] = true;
        
        if (voteForRelease) {
            ++escrow.releaseVotes;
        } else {
            ++escrow.refundVotes;
        }
        
        emit VoteCast(escrowId, msg.sender, voteForRelease);
        
        // Check if we have a decision (2 votes)
        if (escrow.releaseVotes > 1) {
            _resolveEscrow(escrow, escrowId, escrow.seller);
        } else if (escrow.refundVotes > 1) {
            _resolveEscrow(escrow, escrowId, escrow.buyer);
        }
    }

    /**
     * @notice Get escrow details
     * @param escrowId Escrow identifier
     * @return Escrow data
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

        OMNI_COIN.safeTransfer(recipient, recipientAmount);

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
            totalEscrowed[address(OMNI_COIN)] -= stakeAmount;
            OMNI_COIN.safeTransfer(party, stakeAmount);
            emit DisputeStakeReturned(escrowId, party, stakeAmount);
        }
    }

    /**
     * @notice Validate vote eligibility
     * @dev Checks resolution status and participation
     * @param escrow Escrow data
     * @param escrowId Escrow identifier
     */
    function _validateVote(Escrow storage escrow, uint256 escrowId) private view {
        if (escrow.resolved) revert AlreadyResolved();
        if (hasVoted[escrowId][msg.sender]) revert AlreadyVoted();

        // For disputed escrows, arbitrator can also vote
        bool isParticipant = msg.sender == escrow.buyer ||
                           msg.sender == escrow.seller ||
                           (escrow.disputed && msg.sender == escrow.arbitrator);
        if (!isParticipant) revert NotParticipant();
    }

    // ========================================================================
    // ARBITRATOR MANAGEMENT (Admin Only)
    // ========================================================================

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
        if (seller == address(0) || seller == msg.sender) revert InvalidAddress();
        if (duration < MIN_DURATION || duration > MAX_DURATION) revert InvalidDuration();

        // Decrypt amount for token transfer (need plain value for ERC20)
        uint64 plainAmount = MpcCore.decrypt(encryptedAmount);
        if (plainAmount == 0) revert InvalidAmount();

        // Transfer pXOM tokens from buyer to escrow
        PRIVATE_OMNI_COIN.safeTransferFrom(msg.sender, address(this), uint256(plainAmount));
        totalEscrowed[address(PRIVATE_OMNI_COIN)] += uint256(plainAmount);

        escrowId = ++escrowCounter;

        // Store encrypted amount
        encryptedEscrowAmounts[escrowId] = MpcCore.offBoard(encryptedAmount);
        isPrivateEscrow[escrowId] = true;

        escrows[escrowId] = Escrow({
            buyer: msg.sender,
            seller: seller,
            arbitrator: address(0),
            amount: uint256(plainAmount), // Store plain for public queries
            expiry: block.timestamp + duration, // solhint-disable-line not-rely-on-time
            createdAt: block.timestamp, // solhint-disable-line not-rely-on-time
            releaseVotes: 0,
            refundVotes: 0,
            resolved: false,
            disputed: false
        });

        emit PrivateEscrowCreated(escrowId, msg.sender, seller, escrows[escrowId].expiry);
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
        if (msg.sender != escrow.buyer && msg.sender != escrow.seller) revert NotParticipant();

        // Simple 2-party agreement (buyer releases to seller)
        if (!escrow.disputed && msg.sender == escrow.buyer) {
            escrow.resolved = true;
            uint256 amount = escrow.amount;
            escrow.amount = 0;

            totalEscrowed[address(PRIVATE_OMNI_COIN)] -= amount;

            // Deduct marketplace fee before paying seller
            uint256 feeAmount = (amount * MARKETPLACE_FEE_BPS) / BASIS_POINTS;
            uint256 sellerAmount = amount - feeAmount;

            if (feeAmount > 0) {
                PRIVATE_OMNI_COIN.safeTransfer(FEE_COLLECTOR, feeAmount);
                totalMarketplaceFees[address(PRIVATE_OMNI_COIN)] += feeAmount;
                emit MarketplaceFeeCollected(escrowId, FEE_COLLECTOR, feeAmount);
            }
            PRIVATE_OMNI_COIN.safeTransfer(escrow.seller, sellerAmount);
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
        // M-04: Only buyer or seller can trigger refund (prevents griefing by third parties)
        if (msg.sender != escrow.buyer && msg.sender != escrow.seller) revert NotParticipant();

        bool canRefund = false;

        // Seller agrees to refund
        if (msg.sender == escrow.seller && !escrow.disputed) {
            canRefund = true;
        }

        // Expired and no dispute - only buyer can claim expired refund
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp > escrow.expiry && !escrow.disputed && msg.sender == escrow.buyer) {
            canRefund = true;
        }

        if (canRefund) {
            escrow.resolved = true;
            uint256 amount = escrow.amount;
            escrow.amount = 0;

            totalEscrowed[address(PRIVATE_OMNI_COIN)] -= amount;
            PRIVATE_OMNI_COIN.safeTransfer(escrow.buyer, amount);
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

        _validateVote(escrow, escrowId);

        hasVoted[escrowId][msg.sender] = true;

        if (voteForRelease) {
            ++escrow.releaseVotes;
        } else {
            ++escrow.refundVotes;
        }

        emit VoteCast(escrowId, msg.sender, voteForRelease);

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
        uint256 amount = escrow.amount;
        escrow.amount = 0;

        totalEscrowed[address(PRIVATE_OMNI_COIN)] -= amount;
        PRIVATE_OMNI_COIN.safeTransfer(recipient, amount);

        // Return dispute stakes (always in XOM) to both parties
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
     * @dev Only allows recovery of tokens that are NOT held in active escrows.
     *      The recoverable amount is: contract balance - totalEscrowed[token].
     *      This prevents admin from withdrawing funds belonging to escrow participants.
     * @param token Address of the ERC20 token to recover
     * @param recipient Address to receive the recovered tokens
     */
    function recoverERC20(address token, address recipient) external onlyAdmin {
        if (token == address(0) || recipient == address(0)) revert InvalidAddress();

        uint256 contractBalance = IERC20(token).balanceOf(address(this));
        uint256 locked = totalEscrowed[token];

        // solhint-disable-next-line gas-strict-inequalities
        if (contractBalance <= locked) revert NothingToClaim();

        uint256 recoverable = contractBalance - locked;
        IERC20(token).safeTransfer(recipient, recoverable);

        emit TokensRecovered(token, recoverable, recipient);
    }
}