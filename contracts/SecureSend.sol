// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract SecureSend is ReentrancyGuard, Ownable {
    struct Escrow {
        address buyer;
        address seller;
        address escrowAgent;
        uint256 amount;
        uint256 expirationTime;
        bool isReleased;
        bool isRefunded;
        mapping(address => bool) hasVoted;
        uint256 positiveVotes;
        uint256 negativeVotes;
    }

    // Constants
    uint256 public constant ESCROW_FEE_PERCENTAGE = 100; // 1%
    uint256 public constant MIN_VOTES_REQUIRED = 2;
    uint256 public constant DEFAULT_EXPIRATION_TIME = 90 days;

    // State variables
    mapping(bytes32 => Escrow) public escrows;
    IERC20 public paymentToken;
    address public feeCollector;

    // Events
    event EscrowCreated(
        bytes32 indexed escrowId,
        address indexed buyer,
        address indexed seller,
        address escrowAgent,
        uint256 amount,
        uint256 expirationTime
    );
    event EscrowReleased(bytes32 indexed escrowId, address indexed releasedBy);
    event EscrowRefunded(bytes32 indexed escrowId, address indexed refundedBy);
    event VoteCast(
        bytes32 indexed escrowId,
        address indexed voter,
        bool isPositive
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

    constructor(
        address _paymentToken,
        address _feeCollector
    ) Ownable(msg.sender) {
        paymentToken = IERC20(_paymentToken);
        feeCollector = _feeCollector;
    }

    function createEscrow(
        address _seller,
        address _escrowAgent,
        uint256 _amount,
        uint256 _expirationTime
    ) external nonReentrant returns (bytes32) {
        if (_seller == address(0)) revert InvalidSellerAddress();
        if (_escrowAgent == address(0)) revert InvalidEscrowAgentAddress();
        if (_amount == 0) revert InvalidAmount();
        if (_expirationTime <= block.timestamp) revert InvalidExpirationTime();

        bytes32 escrowId = keccak256(
            abi.encodePacked(
                msg.sender,
                _seller,
                _escrowAgent,
                _amount,
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

        // Transfer tokens to escrow contract
        if (!paymentToken.transferFrom(msg.sender, address(this), _amount))
            revert TransferFailed();

        emit EscrowCreated(
            escrowId,
            msg.sender,
            _seller,
            _escrowAgent,
            _amount,
            _expirationTime
        );

        return escrowId;
    }

    function vote(bytes32 _escrowId, bool _isPositive) external {
        Escrow storage escrow = escrows[_escrowId];
        if (msg.sender != escrow.buyer && 
            msg.sender != escrow.seller && 
            msg.sender != escrow.escrowAgent)
            revert NotBuyerOrAgent();
        if (escrow.hasVoted[msg.sender]) revert AlreadyVoted();
        if (escrow.isReleased || escrow.isRefunded)
            revert EscrowAlreadyReleased();
        if (block.timestamp > escrow.expirationTime) revert EscrowExpired();

        escrow.hasVoted[msg.sender] = true;
        if (_isPositive) {
            ++escrow.positiveVotes;
        } else {
            ++escrow.negativeVotes;
        }

        emit VoteCast(_escrowId, msg.sender, _isPositive);

        // Check if enough votes are in to resolve the escrow
        if (escrow.positiveVotes >= MIN_VOTES_REQUIRED) {
            _releaseEscrow(_escrowId);
        } else if (escrow.negativeVotes >= MIN_VOTES_REQUIRED) {
            _refundEscrow(_escrowId);
        }
    }

    function _releaseEscrow(bytes32 _escrowId) internal {
        Escrow storage escrow = escrows[_escrowId];
        if (escrow.isReleased || escrow.isRefunded)
            revert EscrowAlreadyReleased();

        escrow.isReleased = true;

        // Calculate and transfer escrow fee
        uint256 feeAmount = (escrow.amount * ESCROW_FEE_PERCENTAGE) / 10000;
        uint256 sellerAmount = escrow.amount - feeAmount;

        if (!paymentToken.transfer(escrow.seller, sellerAmount))
            revert TransferFailed();
        if (!paymentToken.transfer(feeCollector, feeAmount))
            revert TransferFailed();

        emit EscrowReleased(_escrowId, msg.sender);
    }

    function _refundEscrow(bytes32 _escrowId) internal {
        Escrow storage escrow = escrows[_escrowId];
        if (escrow.isReleased || escrow.isRefunded)
            revert EscrowAlreadyReleased();

        escrow.isRefunded = true;

        // Calculate and transfer escrow fee
        uint256 feeAmount = (escrow.amount * ESCROW_FEE_PERCENTAGE) / 10000;
        uint256 buyerAmount = escrow.amount - feeAmount;

        if (!paymentToken.transfer(escrow.buyer, buyerAmount))
            revert TransferFailed();
        if (!paymentToken.transfer(feeCollector, feeAmount))
            revert TransferFailed();

        emit EscrowRefunded(_escrowId, msg.sender);
    }

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
        if (_newExpirationTime <= block.timestamp) 
            revert InvalidExpirationTime();
        if (_newExpirationTime <= escrow.expirationTime) 
            revert InvalidExpirationTime();

        escrow.expirationTime = _newExpirationTime;
    }

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

    function hasVoted(
        bytes32 _escrowId,
        address _voter
    ) external view returns (bool) {
        return escrows[_escrowId].hasVoted[_voter];
    }
}
