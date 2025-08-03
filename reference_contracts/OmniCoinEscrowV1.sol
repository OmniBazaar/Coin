// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract OmniCoinEscrow is Ownable, ReentrancyGuard {
    struct Escrow {
        uint256 id;
        address seller;
        address buyer;
        address arbitrator;
        uint256 amount;
        uint256 releaseTime;
        bool released;
        bool disputed;
        bool refunded;
    }

    struct Dispute {
        uint256 escrowId;
        address reporter;
        string reason;
        uint256 timestamp;
        bool resolved;
        address resolver;
        bool outcome;
    }

    IERC20 public token;

    mapping(uint256 => Escrow) public escrows;
    mapping(uint256 => Dispute) public disputes;
    mapping(address => uint256[]) public userEscrows;

    uint256 public escrowCount;
    uint256 public disputeCount;
    uint256 public minEscrowAmount;
    uint256 public maxEscrowDuration;
    uint256 public arbitrationFee;

    event EscrowCreated(
        uint256 indexed escrowId,
        address indexed seller,
        address indexed buyer,
        uint256 amount,
        uint256 releaseTime
    );
    event EscrowReleased(uint256 indexed escrowId);
    event EscrowRefunded(uint256 indexed escrowId);
    event DisputeCreated(
        uint256 indexed escrowId,
        uint256 indexed disputeId,
        address indexed reporter,
        string reason
    );
    event DisputeResolved(
        uint256 indexed escrowId,
        uint256 indexed disputeId,
        address indexed resolver,
        bool outcome
    );
    event MinEscrowAmountUpdated(uint256 newAmount);
    event MaxEscrowDurationUpdated(uint256 newDuration);
    event ArbitrationFeeUpdated(uint256 newFee);

    constructor(address _token, address initialOwner) Ownable(initialOwner) {
        token = IERC20(_token);
        minEscrowAmount = 100 * 10 ** 6; // 100 tokens
        maxEscrowDuration = 30 days;
        arbitrationFee = 10 * 10 ** 6; // 10 tokens
    }

    function createEscrow(
        address _buyer,
        address _arbitrator,
        uint256 _amount,
        uint256 _duration
    ) external nonReentrant {
        require(_buyer != address(0), "Invalid buyer");
        require(_arbitrator != address(0), "Invalid arbitrator");
        require(_amount >= minEscrowAmount, "Amount too small");
        require(_duration <= maxEscrowDuration, "Duration too long");

        uint256 escrowId = escrowCount++;

        escrows[escrowId] = Escrow({
            id: escrowId,
            seller: msg.sender,
            buyer: _buyer,
            arbitrator: _arbitrator,
            amount: _amount,
            releaseTime: block.timestamp + _duration,
            released: false,
            disputed: false,
            refunded: false
        });

        userEscrows[msg.sender].push(escrowId);
        userEscrows[_buyer].push(escrowId);

        require(
            token.transferFrom(msg.sender, address(this), _amount),
            "Transfer failed"
        );

        emit EscrowCreated(
            escrowId,
            msg.sender,
            _buyer,
            _amount,
            block.timestamp + _duration
        );
    }

    function releaseEscrow(uint256 _escrowId) external nonReentrant {
        Escrow storage escrow = escrows[_escrowId];
        require(msg.sender == escrow.buyer, "Not buyer");
        require(!escrow.released, "Already released");
        require(!escrow.refunded, "Already refunded");
        require(!escrow.disputed, "Dispute active");

        escrow.released = true;

        require(
            token.transfer(escrow.seller, escrow.amount),
            "Transfer failed"
        );

        emit EscrowReleased(_escrowId);
    }

    function refundEscrow(uint256 _escrowId) external nonReentrant {
        Escrow storage escrow = escrows[_escrowId];
        require(msg.sender == escrow.seller, "Not seller");
        require(!escrow.released, "Already released");
        require(!escrow.refunded, "Already refunded");
        require(!escrow.disputed, "Dispute active");
        require(block.timestamp >= escrow.releaseTime, "Not expired");

        escrow.refunded = true;

        require(
            token.transfer(escrow.seller, escrow.amount),
            "Transfer failed"
        );

        emit EscrowRefunded(_escrowId);
    }

    function createDispute(
        uint256 _escrowId,
        string memory _reason
    ) external nonReentrant {
        Escrow storage escrow = escrows[_escrowId];
        require(
            msg.sender == escrow.buyer || msg.sender == escrow.seller,
            "Not participant"
        );
        require(!escrow.released, "Already released");
        require(!escrow.refunded, "Already refunded");
        require(!escrow.disputed, "Dispute active");

        escrow.disputed = true;

        uint256 disputeId = disputeCount++;

        disputes[disputeId] = Dispute({
            escrowId: _escrowId,
            reporter: msg.sender,
            reason: _reason,
            timestamp: block.timestamp,
            resolved: false,
            resolver: address(0),
            outcome: false
        });

        emit DisputeCreated(_escrowId, disputeId, msg.sender, _reason);
    }

    function resolveDispute(
        uint256 _disputeId,
        bool _outcome
    ) external nonReentrant {
        Dispute storage dispute = disputes[_disputeId];
        require(!dispute.resolved, "Already resolved");

        Escrow storage escrow = escrows[dispute.escrowId];
        require(msg.sender == escrow.arbitrator, "Not arbitrator");

        dispute.resolved = true;
        dispute.resolver = msg.sender;
        dispute.outcome = _outcome;

        if (_outcome) {
            escrow.released = true;
            require(
                token.transfer(escrow.seller, escrow.amount),
                "Transfer failed"
            );
        } else {
            escrow.refunded = true;
            require(
                token.transfer(escrow.buyer, escrow.amount),
                "Transfer failed"
            );
        }

        emit DisputeResolved(
            dispute.escrowId,
            _disputeId,
            msg.sender,
            _outcome
        );
    }

    function setMinEscrowAmount(uint256 _amount) external onlyOwner {
        require(_amount > 0, "Invalid amount");
        minEscrowAmount = _amount;
        emit MinEscrowAmountUpdated(_amount);
    }

    function setMaxEscrowDuration(uint256 _duration) external onlyOwner {
        require(_duration > 0, "Invalid duration");
        maxEscrowDuration = _duration;
        emit MaxEscrowDurationUpdated(_duration);
    }

    function setArbitrationFee(uint256 _fee) external onlyOwner {
        require(_fee > 0, "Invalid fee");
        arbitrationFee = _fee;
        emit ArbitrationFeeUpdated(_fee);
    }

    function getEscrow(
        uint256 _escrowId
    )
        external
        view
        returns (
            address seller,
            address buyer,
            address arbitrator,
            uint256 amount,
            uint256 releaseTime,
            bool released,
            bool disputed,
            bool refunded
        )
    {
        Escrow storage escrow = escrows[_escrowId];
        return (
            escrow.seller,
            escrow.buyer,
            escrow.arbitrator,
            escrow.amount,
            escrow.releaseTime,
            escrow.released,
            escrow.disputed,
            escrow.refunded
        );
    }

    function getDispute(
        uint256 _disputeId
    )
        external
        view
        returns (
            uint256 escrowId,
            address reporter,
            string memory reason,
            uint256 timestamp,
            bool resolved,
            address resolver,
            bool outcome
        )
    {
        Dispute storage dispute = disputes[_disputeId];
        return (
            dispute.escrowId,
            dispute.reporter,
            dispute.reason,
            dispute.timestamp,
            dispute.resolved,
            dispute.resolver,
            dispute.outcome
        );
    }

    function getUserEscrows(
        address _user
    ) external view returns (uint256[] memory) {
        return userEscrows[_user];
    }
}
