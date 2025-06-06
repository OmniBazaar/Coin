// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./omnicoin-erc20-coti.sol";
import "./OmniCoinAccount.sol";
import "./OmniCoinPayment.sol";

/**
 * @title OmniCoinEscrow
 * @dev Implements a 2-of-3 multi-signature escrow system with COTI integration
 */
contract OmniCoinEscrow is Initializable, OwnableUpgradeable, ReentrancyGuardUpgradeable {
    // Structs
    struct Escrow {
        address buyer;
        address seller;
        address arbitrator;
        uint256 amount;
        uint256 fee;
        uint256 arbitratorFee;
        uint256 timestamp;
        bool isActive;
        bool isDisputed;
        bool isReleased;
        bool isRefunded;
        mapping(address => bool) signatures;
    }

    // State variables
    mapping(bytes32 => Escrow) public escrows;
    mapping(address => bytes32[]) public userEscrows;
    mapping(address => uint256) public arbitratorFees;
    
    OmniCoin public omniCoin;
    OmniCoinAccount public omniCoinAccount;
    OmniCoinPayment public omniCoinPayment;
    
    uint256 public escrowFee;
    uint256 public arbitratorFee;
    uint256 public minEscrowAmount;
    uint256 public maxEscrowAmount;

    // Events
    event EscrowCreated(
        bytes32 indexed escrowId,
        address indexed buyer,
        address indexed seller,
        uint256 amount,
        uint256 fee
    );
    event EscrowReleased(bytes32 indexed escrowId);
    event EscrowRefunded(bytes32 indexed escrowId);
    event EscrowDisputed(bytes32 indexed escrowId, address indexed arbitrator);
    event ArbitratorSelected(bytes32 indexed escrowId, address indexed arbitrator);
    event FeesUpdated(uint256 newEscrowFee, uint256 newArbitratorFee);
    event LimitsUpdated(uint256 newMinAmount, uint256 newMaxAmount);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Initializes the contract
     */
    function initialize(
        address _omniCoin,
        address _omniCoinAccount,
        address _omniCoinPayment,
        uint256 _escrowFee,
        uint256 _arbitratorFee,
        uint256 _minEscrowAmount,
        uint256 _maxEscrowAmount
    ) public initializer {
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();
        omniCoin = OmniCoin(_omniCoin);
        omniCoinAccount = OmniCoinAccount(_omniCoinAccount);
        omniCoinPayment = OmniCoinPayment(_omniCoinPayment);
        escrowFee = _escrowFee;
        arbitratorFee = _arbitratorFee;
        minEscrowAmount = _minEscrowAmount;
        maxEscrowAmount = _maxEscrowAmount;
    }

    /**
     * @dev Creates a new escrow
     */
    function createEscrow(
        address _seller,
        uint256 _amount
    ) external nonReentrant returns (bytes32 escrowId) {
        require(_amount >= minEscrowAmount && _amount <= maxEscrowAmount, "Invalid amount");
        require(_seller != address(0) && _seller != msg.sender, "Invalid seller");

        uint256 totalFee = escrowFee + arbitratorFee;
        require(
            omniCoin.transferFrom(msg.sender, address(this), _amount + totalFee),
            "Transfer failed"
        );

        escrowId = keccak256(
            abi.encodePacked(
                msg.sender,
                _seller,
                _amount,
                block.timestamp
            )
        );

        Escrow storage escrow = escrows[escrowId];
        escrow.buyer = msg.sender;
        escrow.seller = _seller;
        escrow.amount = _amount;
        escrow.fee = escrowFee;
        escrow.arbitratorFee = arbitratorFee;
        escrow.timestamp = block.timestamp;
        escrow.isActive = true;

        userEscrows[msg.sender].push(escrowId);
        userEscrows[_seller].push(escrowId);

        emit EscrowCreated(escrowId, msg.sender, _seller, _amount, totalFee);
    }

    /**
     * @dev Signs an escrow release
     */
    function signEscrowRelease(bytes32 _escrowId) external {
        Escrow storage escrow = escrows[_escrowId];
        require(escrow.isActive, "Escrow not active");
        require(
            msg.sender == escrow.buyer || msg.sender == escrow.seller,
            "Not authorized"
        );
        require(!escrow.signatures[msg.sender], "Already signed");

        escrow.signatures[msg.sender] = true;

        if (escrow.signatures[escrow.buyer] && escrow.signatures[escrow.seller]) {
            _releaseEscrow(_escrowId);
        }
    }

    /**
     * @dev Initiates a dispute
     */
    function initiateDispute(bytes32 _escrowId) external {
        Escrow storage escrow = escrows[_escrowId];
        require(escrow.isActive, "Escrow not active");
        require(
            msg.sender == escrow.buyer || msg.sender == escrow.seller,
            "Not authorized"
        );
        require(!escrow.isDisputed, "Already disputed");

        escrow.isDisputed = true;
        emit EscrowDisputed(_escrowId, address(0));
    }

    /**
     * @dev Selects an arbitrator for a disputed escrow
     */
    function selectArbitrator(bytes32 _escrowId, address _arbitrator) external onlyOwner {
        Escrow storage escrow = escrows[_escrowId];
        require(escrow.isDisputed, "Not disputed");
        require(escrow.arbitrator == address(0), "Arbitrator already selected");
        require(_arbitrator != address(0), "Invalid arbitrator");

        escrow.arbitrator = _arbitrator;
        emit ArbitratorSelected(_escrowId, _arbitrator);
    }

    /**
     * @dev Arbitrator resolves a dispute
     */
    function resolveDispute(bytes32 _escrowId, bool _releaseToSeller) external {
        Escrow storage escrow = escrows[_escrowId];
        require(escrow.isDisputed, "Not disputed");
        require(msg.sender == escrow.arbitrator, "Not arbitrator");

        if (_releaseToSeller) {
            _releaseEscrow(_escrowId);
        } else {
            _refundEscrow(_escrowId);
        }

        // Transfer arbitrator fee
        require(
            omniCoin.transfer(escrow.arbitrator, escrow.arbitratorFee),
            "Arbitrator fee transfer failed"
        );
        arbitratorFees[escrow.arbitrator] += escrow.arbitratorFee;
    }

    /**
     * @dev Internal function to release escrow funds
     */
    function _releaseEscrow(bytes32 _escrowId) internal {
        Escrow storage escrow = escrows[_escrowId];
        require(escrow.isActive, "Escrow not active");

        escrow.isActive = false;
        escrow.isReleased = true;

        // Transfer funds to seller
        require(
            omniCoin.transfer(escrow.seller, escrow.amount),
            "Release transfer failed"
        );

        emit EscrowReleased(_escrowId);
    }

    /**
     * @dev Internal function to refund escrow funds
     */
    function _refundEscrow(bytes32 _escrowId) internal {
        Escrow storage escrow = escrows[_escrowId];
        require(escrow.isActive, "Escrow not active");

        escrow.isActive = false;
        escrow.isRefunded = true;

        // Refund funds to buyer
        require(
            omniCoin.transfer(escrow.buyer, escrow.amount),
            "Refund transfer failed"
        );

        emit EscrowRefunded(_escrowId);
    }

    /**
     * @dev Updates fee structure
     */
    function updateFees(uint256 _escrowFee, uint256 _arbitratorFee) external onlyOwner {
        escrowFee = _escrowFee;
        arbitratorFee = _arbitratorFee;
        emit FeesUpdated(_escrowFee, _arbitratorFee);
    }

    /**
     * @dev Updates escrow amount limits
     */
    function updateLimits(uint256 _minAmount, uint256 _maxAmount) external onlyOwner {
        require(_minAmount < _maxAmount, "Invalid limits");
        minEscrowAmount = _minAmount;
        maxEscrowAmount = _maxAmount;
        emit LimitsUpdated(_minAmount, _maxAmount);
    }

    /**
     * @dev Gets escrow details
     */
    function getEscrow(bytes32 _escrowId) external view returns (
        address buyer,
        address seller,
        address arbitrator,
        uint256 amount,
        uint256 fee,
        uint256 arbitratorFee,
        uint256 timestamp,
        bool isActive,
        bool isDisputed,
        bool isReleased,
        bool isRefunded,
        bool buyerSigned,
        bool sellerSigned
    ) {
        Escrow storage escrow = escrows[_escrowId];
        return (
            escrow.buyer,
            escrow.seller,
            escrow.arbitrator,
            escrow.amount,
            escrow.fee,
            escrow.arbitratorFee,
            escrow.timestamp,
            escrow.isActive,
            escrow.isDisputed,
            escrow.isReleased,
            escrow.isRefunded,
            escrow.signatures[escrow.buyer],
            escrow.signatures[escrow.seller]
        );
    }

    /**
     * @dev Gets user's escrow history
     */
    function getUserEscrows(address _user) external view returns (bytes32[] memory) {
        return userEscrows[_user];
    }

    /**
     * @dev Gets arbitrator's total fees
     */
    function getArbitratorFees(address _arbitrator) external view returns (uint256) {
        return arbitratorFees[_arbitrator];
    }
} 