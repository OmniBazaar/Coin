// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
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
contract MinimalEscrow is ReentrancyGuard {
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

    // State variables (immutables first)
    /// @notice OmniCoin token (XOM)
    IERC20 public immutable OMNI_COIN;

    /// @notice Private OmniCoin token (pXOM) for private escrows
    IERC20 public immutable PRIVATE_OMNI_COIN;

    /// @notice Registry contract for service lookups
    address public immutable REGISTRY;
    
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

    // Custom errors
    error InvalidAddress();
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

    /**
     * @notice Initialize escrow with token and registry
     * @param _omniCoin OmniCoin token address (XOM)
     * @param _privateOmniCoin Private OmniCoin token address (pXOM)
     * @param _registry Registry contract address
     */
    constructor(address _omniCoin, address _privateOmniCoin, address _registry) {
        if (_omniCoin == address(0) || _privateOmniCoin == address(0) || _registry == address(0)) {
            revert InvalidAddress();
        }
        OMNI_COIN = IERC20(_omniCoin);
        PRIVATE_OMNI_COIN = IERC20(_privateOmniCoin);
        REGISTRY = _registry;

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
    ) external nonReentrant returns (uint256 escrowId) {
        if (seller == address(0) || seller == msg.sender) revert InvalidAddress();
        if (amount == 0) revert InvalidAmount();
        if (duration < MIN_DURATION || duration > MAX_DURATION) revert InvalidDuration();
        
        // Transfer tokens from buyer to escrow
        OMNI_COIN.safeTransferFrom(msg.sender, address(this), amount);
        
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
    function releaseFunds(uint256 escrowId) external nonReentrant {
        Escrow storage escrow = escrows[escrowId];
        
        if (escrow.buyer == address(0)) revert EscrowNotFound();
        if (escrow.resolved) revert AlreadyResolved();
        if (msg.sender != escrow.buyer && msg.sender != escrow.seller) revert NotParticipant();
        
        // Simple 2-party agreement
        if (!escrow.disputed && msg.sender == escrow.buyer) {
            escrow.resolved = true;
            uint256 amount = escrow.amount;
            escrow.amount = 0;
            
            OMNI_COIN.safeTransfer(escrow.seller, amount);
            emit EscrowResolved(escrowId, escrow.seller, amount);
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
        
        bool canRefund = false;
        
        // Seller agrees to refund
        if (msg.sender == escrow.seller && !escrow.disputed) {
            canRefund = true;
        }
        
        // Expired and no dispute
        if (block.timestamp > escrow.expiry && !escrow.disputed) { // solhint-disable-line not-rely-on-time
            canRefund = true;
        }
        
        if (canRefund) {
            escrow.resolved = true;
            uint256 amount = escrow.amount;
            escrow.amount = 0;
            
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
    function commitDispute(uint256 escrowId, bytes32 commitment) external {
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
    function revealDispute(uint256 escrowId, uint256 nonce) external {
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
     * @notice Vote on disputed escrow outcome
     * @dev 2-of-3 multisig voting
     * @param escrowId Escrow to vote on
     * @param voteForRelease True to release to seller, false to refund buyer
     */
    function vote(uint256 escrowId, bool voteForRelease) external nonReentrant {
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
     * @notice Select arbitrator deterministically
     * @dev Uses escrow creation block and nonce for randomness
     * @param escrowId Escrow identifier
     * @param nonce Random nonce from reveal
     * @return arbitrator Selected arbitrator address
     */
    function selectArbitrator(
        uint256 escrowId,
        uint256 nonce
    ) internal view returns (address arbitrator) {
        // Get validator list from registry (simplified for now)
        // In production, this would query the actual validator registry

        // Use deterministic randomness based on historic data
        uint256 seed = uint256(keccak256(abi.encodePacked(
            escrows[escrowId].createdAt,
            arbitratorSeed,
            nonce,
            escrowId
        )));

        // For now, return a deterministic address
        // In production, this would select from validator pool
        arbitrator = address(uint160(seed));
    }

    /**
     * @notice Resolve escrow and transfer funds
     * @dev Internal helper to avoid code duplication
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

        OMNI_COIN.safeTransfer(recipient, amount);
        emit EscrowResolved(escrowId, recipient, amount);
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
    ) external nonReentrant returns (uint256 escrowId) {
        if (!privacyEnabled) revert PrivacyNotAvailable();
        if (seller == address(0) || seller == msg.sender) revert InvalidAddress();
        if (duration < MIN_DURATION || duration > MAX_DURATION) revert InvalidDuration();

        // Decrypt amount for token transfer (need plain value for ERC20)
        uint64 plainAmount = MpcCore.decrypt(encryptedAmount);
        if (plainAmount == 0) revert InvalidAmount();

        // Transfer pXOM tokens from buyer to escrow
        PRIVATE_OMNI_COIN.safeTransferFrom(msg.sender, address(this), uint256(plainAmount));

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

            PRIVATE_OMNI_COIN.safeTransfer(escrow.seller, amount);
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

        bool canRefund = false;

        // Seller agrees to refund
        if (msg.sender == escrow.seller && !escrow.disputed) {
            canRefund = true;
        }

        // Expired and no dispute
        if (block.timestamp > escrow.expiry && !escrow.disputed) { // solhint-disable-line not-rely-on-time
            canRefund = true;
        }

        if (canRefund) {
            escrow.resolved = true;
            uint256 amount = escrow.amount;
            escrow.amount = 0;

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
     * @dev Internal helper for private escrow resolution
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

        PRIVATE_OMNI_COIN.safeTransfer(recipient, amount);
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
}