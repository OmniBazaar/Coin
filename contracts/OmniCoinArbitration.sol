// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "./OmniCoinMultisig.sol";

/**
 * @title OmniCoinArbitration
 * @dev Arbitration contract for handling escrow disputes
 */
contract OmniCoinArbitration is Initializable, OwnableUpgradeable, ReentrancyGuardUpgradeable {
    // Structs
    struct Escrow {
        address buyer;
        address seller;
        address token;
        uint256 amount;
        uint256 deadline;
        bool released;
        bool disputed;
        bool resolved;
        address arbitrator;
        string metadata;
    }

    struct Dispute {
        uint256 escrowId;
        address claimant;
        string reason;
        uint256 timestamp;
        bool resolved;
        address winner;
    }

    // State variables
    mapping(uint256 => Escrow) public escrows;
    mapping(uint256 => Dispute) public disputes;
    mapping(address => bool) public arbitrators;
    mapping(address => uint256) public arbitratorStakes;
    mapping(address => uint256) public arbitratorReputation;
    uint256 public minStakeAmount;
    uint256 public disputeFee;
    uint256 public nextEscrowId;
    OmniCoinMultisig public multisig;

    // Events
    event EscrowCreated(uint256 indexed escrowId, address indexed buyer, address indexed seller, uint256 amount);
    event EscrowReleased(uint256 indexed escrowId, address indexed releaser);
    event DisputeRaised(uint256 indexed escrowId, address indexed claimant, string reason);
    event DisputeResolved(uint256 indexed escrowId, address indexed winner);
    event ArbitratorAdded(address indexed arbitrator);
    event ArbitratorRemoved(address indexed arbitrator);
    event StakeDeposited(address indexed arbitrator, uint256 amount);
    event StakeWithdrawn(address indexed arbitrator, uint256 amount);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Initializes the contract
     */
    function initialize(
        address _multisig,
        uint256 _minStakeAmount,
        uint256 _disputeFee
    ) public initializer {
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();

        multisig = OmniCoinMultisig(_multisig);
        minStakeAmount = _minStakeAmount;
        disputeFee = _disputeFee;
    }

    /**
     * @dev Creates a new escrow
     */
    function createEscrow(
        address _seller,
        address _token,
        uint256 _amount,
        uint256 _deadline,
        string calldata _metadata
    ) external nonReentrant returns (uint256 escrowId) {
        require(_seller != address(0), "Invalid seller address");
        require(_amount > 0, "Amount must be greater than 0");
        require(_deadline > block.timestamp, "Invalid deadline");

        escrowId = nextEscrowId++;
        escrows[escrowId] = Escrow({
            buyer: msg.sender,
            seller: _seller,
            token: _token,
            amount: _amount,
            deadline: _deadline,
            released: false,
            disputed: false,
            resolved: false,
            arbitrator: address(0),
            metadata: _metadata
        });

        IERC20Upgradeable(_token).transferFrom(msg.sender, address(this), _amount);

        emit EscrowCreated(escrowId, msg.sender, _seller, _amount);
    }

    /**
     * @dev Releases funds to the seller
     */
    function releaseEscrow(uint256 _escrowId) external nonReentrant {
        Escrow storage escrow = escrows[_escrowId];
        require(msg.sender == escrow.buyer, "Only buyer can release");
        require(!escrow.released, "Already released");
        require(!escrow.disputed, "Escrow is disputed");

        escrow.released = true;
        IERC20Upgradeable(escrow.token).transfer(escrow.seller, escrow.amount);

        emit EscrowReleased(_escrowId, msg.sender);
    }

    /**
     * @dev Raises a dispute
     */
    function raiseDispute(uint256 _escrowId, string calldata _reason) external nonReentrant {
        Escrow storage escrow = escrows[_escrowId];
        require(msg.sender == escrow.buyer || msg.sender == escrow.seller, "Not a party to escrow");
        require(!escrow.released, "Escrow already released");
        require(!escrow.disputed, "Dispute already raised");
        require(block.timestamp <= escrow.deadline, "Escrow expired");

        escrow.disputed = true;
        disputes[_escrowId] = Dispute({
            escrowId: _escrowId,
            claimant: msg.sender,
            reason: _reason,
            timestamp: block.timestamp,
            resolved: false,
            winner: address(0)
        });

        emit DisputeRaised(_escrowId, msg.sender, _reason);
    }

    /**
     * @dev Resolves a dispute
     */
    function resolveDispute(uint256 _escrowId, address _winner) external {
        require(arbitrators[msg.sender], "Not an arbitrator");
        require(arbitratorStakes[msg.sender] >= minStakeAmount, "Insufficient stake");

        Escrow storage escrow = escrows[_escrowId];
        Dispute storage dispute = disputes[_escrowId];
        require(escrow.disputed, "No dispute");
        require(!dispute.resolved, "Already resolved");
        require(_winner == escrow.buyer || _winner == escrow.seller, "Invalid winner");

        dispute.resolved = true;
        dispute.winner = _winner;
        escrow.resolved = true;

        // Transfer funds to winner
        IERC20Upgradeable(escrow.token).transfer(_winner, escrow.amount);

        // Update arbitrator reputation
        arbitratorReputation[msg.sender] += 1;

        emit DisputeResolved(_escrowId, _winner);
    }

    /**
     * @dev Adds an arbitrator
     */
    function addArbitrator(address _arbitrator) external onlyOwner {
        require(!arbitrators[_arbitrator], "Already an arbitrator");
        arbitrators[_arbitrator] = true;
        emit ArbitratorAdded(_arbitrator);
    }

    /**
     * @dev Removes an arbitrator
     */
    function removeArbitrator(address _arbitrator) external onlyOwner {
        require(arbitrators[_arbitrator], "Not an arbitrator");
        arbitrators[_arbitrator] = false;
        emit ArbitratorRemoved(_arbitrator);
    }

    /**
     * @dev Deposits stake for arbitration
     */
    function depositStake() external payable nonReentrant {
        require(arbitrators[msg.sender], "Not an arbitrator");
        arbitratorStakes[msg.sender] += msg.value;
        emit StakeDeposited(msg.sender, msg.value);
    }

    /**
     * @dev Withdraws stake
     */
    function withdrawStake(uint256 _amount) external nonReentrant {
        require(arbitratorStakes[msg.sender] >= _amount, "Insufficient stake");
        arbitratorStakes[msg.sender] -= _amount;
        payable(msg.sender).transfer(_amount);
        emit StakeWithdrawn(msg.sender, _amount);
    }

    /**
     * @dev Updates minimum stake amount
     */
    function updateMinStakeAmount(uint256 _newAmount) external onlyOwner {
        minStakeAmount = _newAmount;
    }

    /**
     * @dev Updates dispute fee
     */
    function updateDisputeFee(uint256 _newFee) external onlyOwner {
        disputeFee = _newFee;
    }

    /**
     * @dev Returns arbitrator statistics
     */
    function getArbitratorStats(address _arbitrator) external view returns (
        bool isArbitrator,
        uint256 stake,
        uint256 reputation
    ) {
        return (
            arbitrators[_arbitrator],
            arbitratorStakes[_arbitrator],
            arbitratorReputation[_arbitrator]
        );
    }

    /**
     * @dev Returns escrow details
     */
    function getEscrow(uint256 _escrowId) external view returns (
        address buyer,
        address seller,
        address token,
        uint256 amount,
        uint256 deadline,
        bool released,
        bool disputed,
        bool resolved,
        address arbitrator,
        string memory metadata
    ) {
        Escrow storage escrow = escrows[_escrowId];
        return (
            escrow.buyer,
            escrow.seller,
            escrow.token,
            escrow.amount,
            escrow.deadline,
            escrow.released,
            escrow.disputed,
            escrow.resolved,
            escrow.arbitrator,
            escrow.metadata
        );
    }

    /**
     * @dev Returns dispute details
     */
    function getDispute(uint256 _escrowId) external view returns (
        address claimant,
        string memory reason,
        uint256 timestamp,
        bool resolved,
        address winner
    ) {
        Dispute storage dispute = disputes[_escrowId];
        return (
            dispute.claimant,
            dispute.reason,
            dispute.timestamp,
            dispute.resolved,
            dispute.winner
        );
    }
} 