// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {RegistryAware} from "./base/RegistryAware.sol";

/**
 * @title SecureSend
 * @author OmniBazaar Team
 * @notice A secure escrow contract for facilitating transactions between buyers and sellers with an escrow agent
 * @dev Implements a voting-based escrow system with automatic resolution based on participant votes
 */
contract SecureSend is ReentrancyGuard, Ownable, RegistryAware {
    // solhint-disable-next-line gas-struct-packing
    struct Escrow {
        address buyer;
        address seller;
        address escrowAgent;
        uint256 amount;
        uint256 expirationTime;
        uint256 positiveVotes;
        uint256 negativeVotes;
        bool isReleased;
        bool isRefunded;
        mapping(address => bool) hasVoted;
    }

    // Constants
    /// @notice Fee percentage charged on escrow transactions (100 = 1%)
    uint256 public constant ESCROW_FEE_PERCENTAGE = 100; // 1%
    
    /// @notice Minimum number of votes required to resolve an escrow
    uint256 public constant MIN_VOTES_REQUIRED = 2;
    
    /// @notice Default expiration time for escrows if not specified
    uint256 public constant DEFAULT_EXPIRATION_TIME = 90 days;

    // State variables
    /// @notice Mapping of escrow IDs to Escrow structs
    mapping(bytes32 => Escrow) public escrows;
    
    /// @notice Whether to use private token for this escrow
    mapping(bytes32 => bool) public escrowUsePrivacy;
    
    /// @notice Address that receives escrow fees
    address public feeCollector;

    // Events
    /**
     * @notice Emitted when a new escrow is created
     * @param escrowId Unique identifier for the escrow
     * @param buyer Address of the buyer
     * @param seller Address of the seller
     * @param escrowAgent Address of the escrow agent
     * @param amount Amount of tokens locked in escrow
     * @param expirationTime Timestamp when the escrow expires
     */
    event EscrowCreated(
        bytes32 indexed escrowId,
        address indexed buyer,
        address indexed seller,
        address escrowAgent,
        uint256 amount,
        uint256 expirationTime
    );
    
    /**
     * @notice Emitted when an escrow is released to the seller
     * @param escrowId Unique identifier for the escrow
     * @param releasedBy Address that triggered the release
     */
    event EscrowReleased(bytes32 indexed escrowId, address indexed releasedBy);
    
    /**
     * @notice Emitted when an escrow is refunded to the buyer
     * @param escrowId Unique identifier for the escrow
     * @param refundedBy Address that triggered the refund
     */
    event EscrowRefunded(bytes32 indexed escrowId, address indexed refundedBy);
    
    /**
     * @notice Emitted when a vote is cast on an escrow
     * @param escrowId Unique identifier for the escrow
     * @param voter Address of the voter
     * @param isPositive Whether the vote is positive (true) or negative (false)
     */
    event VoteCast(
        bytes32 indexed escrowId,
        address indexed voter,
        bool indexed isPositive
    );

    // Custom errors
    error InvalidSellerAddress();
    error InvalidEscrowAgentAddress();
    error InvalidAmount();
    error InvalidExpirationTime();
    error TransferFailed();
    error EscrowNotFound();
    error NotBuyer();
    error AlreadyVoted();
    error EscrowExpired();
    error NotSellerOrAgent();
    error NotBuyerOrAgent();
    error EscrowAlreadyReleased();
    error EscrowAlreadyRefunded();
    error NotExpired();
    error InsufficientVotes();
    error NotEscrowAgent();
    error InvalidAddress();

    /**
     * @notice Initializes the SecureSend contract
     * @param _registry Address of the OmniCoinRegistry contract
     * @param _feeCollector Address that will receive escrow fees
     */
    constructor(
        address _registry,
        address _feeCollector
    ) Ownable(msg.sender) RegistryAware(_registry) {
        feeCollector = _feeCollector;
    }

    /**
     * @notice Creates a new escrow between buyer and seller with an escrow agent
     * @param _seller Address of the seller
     * @param _escrowAgent Address of the escrow agent
     * @param _amount Amount of tokens to lock in escrow
     * @param _expirationTime Timestamp when the escrow expires
     * @param _usePrivacy Whether to use PrivateOmniCoin for this escrow
     * @return escrowId Unique identifier for the created escrow
     */
    function createEscrow(
        address _seller,
        address _escrowAgent,
        uint256 _amount,
        uint256 _expirationTime,
        bool _usePrivacy
    ) external nonReentrant returns (bytes32 escrowId) {
        if (_seller == address(0)) revert InvalidSellerAddress();
        if (_escrowAgent == address(0)) revert InvalidEscrowAgentAddress();
        if (_amount == 0) revert InvalidAmount();
        // solhint-disable-next-line not-rely-on-time
        if (_expirationTime < block.timestamp + 1) revert InvalidExpirationTime();

        escrowId = keccak256(
            abi.encodePacked(
                msg.sender,
                _seller,
                _escrowAgent,
                _amount,
                // solhint-disable-next-line not-rely-on-time
                block.timestamp
            )
        );

        if (escrows[escrowId].buyer != address(0)) revert EscrowNotFound();

        Escrow storage escrow = escrows[escrowId];
        escrow.buyer = msg.sender;
        escrow.seller = _seller;
        escrow.escrowAgent = _escrowAgent;
        escrow.amount = _amount;
        escrow.expirationTime = _expirationTime;
        escrow.isReleased = false;
        escrow.isRefunded = false;
        escrow.positiveVotes = 0;
        escrow.negativeVotes = 0;

        // Store privacy preference
        escrowUsePrivacy[escrowId] = _usePrivacy;
        
        // Transfer tokens to escrow contract
        address tokenContract = _usePrivacy ? 
            _getContract(REGISTRY.PRIVATE_OMNICOIN()) : 
            _getContract(REGISTRY.OMNICOIN());
        if (!IERC20(tokenContract).transferFrom(msg.sender, address(this), _amount))
            revert TransferFailed();

        emit EscrowCreated(
            escrowId,
            msg.sender,
            _seller,
            _escrowAgent,
            _amount,
            _expirationTime
        );
    }

    /**
     * @notice Allows buyer, seller, or escrow agent to vote on the escrow outcome
     * @param _escrowId Unique identifier for the escrow
     * @param _isPositive Whether the vote is positive (release to seller) or negative (refund to buyer)
     */
    function vote(bytes32 _escrowId, bool _isPositive) external {
        Escrow storage escrow = escrows[_escrowId];
        
        _validateVoter(escrow);
        _validateVoteEligibility(escrow);

        escrow.hasVoted[msg.sender] = true;
        if (_isPositive) {
            ++escrow.positiveVotes;
        } else {
            ++escrow.negativeVotes;
        }

        emit VoteCast(_escrowId, msg.sender, _isPositive);

        _checkAndResolveEscrow(_escrowId, escrow);
    }

    /**
     * @notice Extends the expiration time of an active escrow
     * @param _escrowId Unique identifier for the escrow
     * @param _newExpirationTime New expiration timestamp (must be later than current)
     */
    function extendExpirationTime(
        bytes32 _escrowId,
        uint256 _newExpirationTime
    ) external {
        Escrow storage escrow = escrows[_escrowId];
        if (msg.sender != escrow.buyer && 
            msg.sender != escrow.seller && 
            msg.sender != escrow.escrowAgent)
            revert NotBuyerOrAgent();
        if (escrow.isReleased || escrow.isRefunded)
            revert EscrowAlreadyReleased();
        // solhint-disable-next-line not-rely-on-time
        if (_newExpirationTime < block.timestamp + 1) 
            revert InvalidExpirationTime();
        if (_newExpirationTime < escrow.expirationTime + 1) 
            revert InvalidExpirationTime();

        escrow.expirationTime = _newExpirationTime;
    }

    /**
     * @notice Retrieves detailed information about an escrow
     * @param _escrowId Unique identifier for the escrow
     * @return buyer Address of the buyer
     * @return seller Address of the seller
     * @return escrowAgent Address of the escrow agent
     * @return amount Amount of tokens locked in escrow
     * @return expirationTime Timestamp when the escrow expires
     * @return isReleased Whether the escrow has been released
     * @return isRefunded Whether the escrow has been refunded
     * @return positiveVotes Number of positive votes
     * @return negativeVotes Number of negative votes
     */
    function getEscrowDetails(
        bytes32 _escrowId
    )
        external
        view
        returns (
            address buyer,
            address seller,
            address escrowAgent,
            uint256 amount,
            uint256 expirationTime,
            bool isReleased,
            bool isRefunded,
            uint256 positiveVotes,
            uint256 negativeVotes
        )
    {
        Escrow storage escrow = escrows[_escrowId];
        return (
            escrow.buyer,
            escrow.seller,
            escrow.escrowAgent,
            escrow.amount,
            escrow.expirationTime,
            escrow.isReleased,
            escrow.isRefunded,
            escrow.positiveVotes,
            escrow.negativeVotes
        );
    }

    /**
     * @notice Checks if an address has already voted on an escrow
     * @param _escrowId Unique identifier for the escrow
     * @param _voter Address to check
     * @return hasVoted Whether the address has voted
     */
    function hasVoted(
        bytes32 _escrowId,
        address _voter
    ) external view returns (bool) {
        return escrows[_escrowId].hasVoted[_voter];
    }

    /**
     * @notice Checks if enough votes have been cast and resolves the escrow
     * @param _escrowId The escrow ID
     * @param escrow The escrow struct
     */
    function _checkAndResolveEscrow(bytes32 _escrowId, Escrow storage escrow) internal {
        if (escrow.positiveVotes > MIN_VOTES_REQUIRED - 1) {
            _releaseEscrow(_escrowId);
        } else if (escrow.negativeVotes > MIN_VOTES_REQUIRED - 1) {
            _refundEscrow(_escrowId);
        }
    }

    /**
     * @notice Internal function to release escrow funds to the seller
     * @param _escrowId Unique identifier for the escrow
     */
    function _releaseEscrow(bytes32 _escrowId) internal {
        Escrow storage escrow = escrows[_escrowId];
        if (escrow.isReleased || escrow.isRefunded)
            revert EscrowAlreadyReleased();

        escrow.isReleased = true;

        // Calculate and transfer escrow fee
        uint256 feeAmount = (escrow.amount * ESCROW_FEE_PERCENTAGE) / 10000;
        uint256 sellerAmount = escrow.amount - feeAmount;

        address tokenContract = escrowUsePrivacy[_escrowId] ? 
            _getContract(REGISTRY.PRIVATE_OMNICOIN()) : 
            _getContract(REGISTRY.OMNICOIN());
        
        if (!IERC20(tokenContract).transfer(escrow.seller, sellerAmount))
            revert TransferFailed();
        if (!IERC20(tokenContract).transfer(feeCollector, feeAmount))
            revert TransferFailed();

        emit EscrowReleased(_escrowId, msg.sender);
    }

    /**
     * @notice Internal function to refund escrow funds to the buyer
     * @param _escrowId Unique identifier for the escrow
     */
    function _refundEscrow(bytes32 _escrowId) internal {
        Escrow storage escrow = escrows[_escrowId];
        if (escrow.isReleased || escrow.isRefunded)
            revert EscrowAlreadyReleased();

        escrow.isRefunded = true;

        // Calculate and transfer escrow fee
        uint256 feeAmount = (escrow.amount * ESCROW_FEE_PERCENTAGE) / 10000;
        uint256 buyerAmount = escrow.amount - feeAmount;

        address tokenContract = escrowUsePrivacy[_escrowId] ? 
            _getContract(REGISTRY.PRIVATE_OMNICOIN()) : 
            _getContract(REGISTRY.OMNICOIN());
        
        if (!IERC20(tokenContract).transfer(escrow.buyer, buyerAmount))
            revert TransferFailed();
        if (!IERC20(tokenContract).transfer(feeCollector, feeAmount))
            revert TransferFailed();

        emit EscrowRefunded(_escrowId, msg.sender);
    }

    /**
     * @notice Validates that the sender is eligible to vote
     * @param escrow The escrow struct to validate against
     */
    function _validateVoter(Escrow storage escrow) internal view {
        if (msg.sender != escrow.buyer && 
            msg.sender != escrow.seller && 
            msg.sender != escrow.escrowAgent)
            revert NotBuyerOrAgent();
    }

    /**
     * @notice Validates that voting is still allowed on this escrow
     * @param escrow The escrow struct to validate
     */
    function _validateVoteEligibility(Escrow storage escrow) internal view {
        if (escrow.hasVoted[msg.sender]) revert AlreadyVoted();
        if (escrow.isReleased || escrow.isRefunded)
            revert EscrowAlreadyReleased();
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp > escrow.expirationTime) revert EscrowExpired();
    }
}