// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./omnicoin-erc20-coti.sol";
import "./OmniCoinAccount.sol";
import "./OmniCoinEscrow.sol";

/**
 * @title OmniCoinArbitration
 * @dev Implements arbitration system with COTI reputation integration
 */
contract OmniCoinArbitration is
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable
{
    // Structs
    struct Arbitrator {
        address account;
        uint256 reputation;
        uint256 participationIndex;
        uint256 totalCases;
        uint256 successfulCases;
        bool isActive;
        uint256 lastActiveTimestamp;
    }

    struct Dispute {
        bytes32 escrowId;
        address arbitrator;
        uint256 timestamp;
        bool isResolved;
        string resolution;
        uint256 buyerRating;
        uint256 sellerRating;
        uint256 arbitratorRating;
    }

    // State variables
    mapping(address => Arbitrator) public arbitrators;
    mapping(bytes32 => Dispute) public disputes;
    mapping(address => bytes32[]) public arbitratorDisputes;
    mapping(address => bytes32[]) public userDisputes;

    OmniCoin public omniCoin;
    OmniCoinAccount public omniCoinAccount;
    OmniCoinEscrow public omniCoinEscrow;

    uint256 public minReputation;
    uint256 public minParticipationIndex;
    uint256 public maxActiveDisputes;
    uint256 public disputeTimeout;
    uint256 public ratingWeight;

    // Events
    event ArbitratorRegistered(address indexed arbitrator);
    event ArbitratorRemoved(address indexed arbitrator);
    event DisputeCreated(bytes32 indexed escrowId, address indexed arbitrator);
    event DisputeResolved(bytes32 indexed escrowId, string resolution);
    event RatingSubmitted(
        bytes32 indexed escrowId,
        address indexed rater,
        uint256 rating
    );
    event ReputationUpdated(address indexed arbitrator, uint256 newReputation);
    event ParticipationIndexUpdated(
        address indexed arbitrator,
        uint256 newIndex
    );

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
        address _omniCoinEscrow,
        uint256 _minReputation,
        uint256 _minParticipationIndex,
        uint256 _maxActiveDisputes,
        uint256 _disputeTimeout,
        uint256 _ratingWeight
    ) public initializer {
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();
        omniCoin = OmniCoin(_omniCoin);
        omniCoinAccount = OmniCoinAccount(_omniCoinAccount);
        omniCoinEscrow = OmniCoinEscrow(_omniCoinEscrow);
        minReputation = _minReputation;
        minParticipationIndex = _minParticipationIndex;
        maxActiveDisputes = _maxActiveDisputes;
        disputeTimeout = _disputeTimeout;
        ratingWeight = _ratingWeight;
    }

    /**
     * @dev Registers a new arbitrator
     */
    function registerArbitrator() external {
        require(!arbitrators[msg.sender].isActive, "Already registered");

        uint256 reputation = omniCoinAccount.reputationScore(msg.sender);
        uint256 participationIndex = _calculateParticipationIndex(msg.sender);

        require(reputation >= minReputation, "Insufficient reputation");
        require(
            participationIndex >= minParticipationIndex,
            "Insufficient participation"
        );

        arbitrators[msg.sender] = Arbitrator({
            account: msg.sender,
            reputation: reputation,
            participationIndex: participationIndex,
            totalCases: 0,
            successfulCases: 0,
            isActive: true,
            lastActiveTimestamp: block.timestamp
        });

        emit ArbitratorRegistered(msg.sender);
    }

    /**
     * @dev Removes an arbitrator
     */
    function removeArbitrator(address _arbitrator) external onlyOwner {
        require(arbitrators[_arbitrator].isActive, "Not an active arbitrator");
        arbitrators[_arbitrator].isActive = false;
        emit ArbitratorRemoved(_arbitrator);
    }

    /**
     * @dev Creates a new dispute
     */
    function createDispute(bytes32 _escrowId) external {
        uint256 escrowId = uint256(_escrowId);
        (, , , , , , bool disputed, ) = omniCoinEscrow.getEscrow(escrowId);
        require(disputed, "Escrow not disputed");

        address arbitrator = _selectArbitrator();
        require(arbitrator != address(0), "No suitable arbitrator found");

        disputes[_escrowId] = Dispute({
            escrowId: _escrowId,
            arbitrator: arbitrator,
            timestamp: block.timestamp,
            isResolved: false,
            resolution: "",
            buyerRating: 0,
            sellerRating: 0,
            arbitratorRating: 0
        });

        arbitratorDisputes[arbitrator].push(_escrowId);

        // Get buyer and seller addresses from escrow
        (address seller, address buyer, , , , , , ) = omniCoinEscrow.getEscrow(
            escrowId
        );
        userDisputes[buyer].push(_escrowId);
        userDisputes[seller].push(_escrowId);

        arbitrators[arbitrator].totalCases++;
        arbitrators[arbitrator].lastActiveTimestamp = block.timestamp;

        emit DisputeCreated(_escrowId, arbitrator);
    }

    /**
     * @dev Resolves a dispute
     */
    function resolveDispute(
        bytes32 _escrowId,
        string calldata _resolution
    ) external {
        Dispute storage dispute = disputes[_escrowId];
        require(!dispute.isResolved, "Already resolved");
        require(msg.sender == dispute.arbitrator, "Not the arbitrator");
        require(
            block.timestamp <= dispute.timestamp + disputeTimeout,
            "Dispute timeout"
        );

        dispute.isResolved = true;
        dispute.resolution = _resolution;

        // Update arbitrator stats
        arbitrators[dispute.arbitrator].successfulCases++;

        emit DisputeResolved(_escrowId, _resolution);
    }

    /**
     * @dev Submits a rating for a resolved dispute
     */
    function submitRating(bytes32 _escrowId, uint256 _rating) external {
        Dispute storage dispute = disputes[_escrowId];
        require(dispute.isResolved, "Dispute not resolved");
        require(_rating > 0 && _rating <= 5, "Invalid rating");

        // Get buyer and seller addresses from escrow
        uint256 escrowId = uint256(_escrowId);
        (address seller, address buyer, , , , , , ) = omniCoinEscrow.getEscrow(
            escrowId
        );

        if (msg.sender == buyer) {
            dispute.buyerRating = _rating;
        } else if (msg.sender == seller) {
            dispute.sellerRating = _rating;
        } else {
            revert("Not authorized");
        }

        _updateArbitratorReputation(dispute.arbitrator, _rating);
        emit RatingSubmitted(_escrowId, msg.sender, _rating);
    }

    /**
     * @dev Internal function to select an arbitrator
     */
    function _selectArbitrator() internal view returns (address) {
        address selectedArbitrator;
        uint256 highestScore;

        for (uint256 i = 0; i < arbitratorDisputes[msg.sender].length; i++) {
            address arbitrator = arbitrators[msg.sender].account;
            if (!arbitrators[arbitrator].isActive) continue;

            uint256 activeDisputes = _getActiveDisputes(arbitrator);
            if (activeDisputes >= maxActiveDisputes) continue;

            uint256 score = _calculateArbitratorScore(arbitrator);
            if (score > highestScore) {
                highestScore = score;
                selectedArbitrator = arbitrator;
            }
        }

        return selectedArbitrator;
    }

    /**
     * @dev Internal function to calculate arbitrator score
     */
    function _calculateArbitratorScore(
        address _arbitrator
    ) internal view returns (uint256) {
        Arbitrator storage arbitrator = arbitrators[_arbitrator];
        if (arbitrator.totalCases == 0) return 0;

        uint256 successRate = (arbitrator.successfulCases * 100) /
            arbitrator.totalCases;
        return
            (arbitrator.reputation *
                successRate *
                arbitrator.participationIndex) / 100;
    }

    /**
     * @dev Internal function to calculate participation index
     */
    function _calculateParticipationIndex(
        address _user
    ) internal view returns (uint256) {
        // Implementation would integrate with COTI's participation index
        (, , , , , uint256 reputation) = omniCoinAccount.getAccountStatus(
            _user
        );
        return reputation;
    }

    /**
     * @dev Internal function to get active disputes for an arbitrator
     */
    function _getActiveDisputes(
        address _arbitrator
    ) internal view returns (uint256) {
        uint256 count;
        for (uint256 i = 0; i < arbitratorDisputes[_arbitrator].length; i++) {
            if (!disputes[arbitratorDisputes[_arbitrator][i]].isResolved) {
                count++;
            }
        }
        return count;
    }

    /**
     * @dev Internal function to update arbitrator reputation
     */
    function _updateArbitratorReputation(
        address _arbitrator,
        uint256 _rating
    ) internal {
        Arbitrator storage arbitrator = arbitrators[_arbitrator];
        uint256 newReputation = (arbitrator.reputation *
            (100 - ratingWeight) +
            _rating *
            ratingWeight) / 100;
        arbitrator.reputation = newReputation;
        emit ReputationUpdated(_arbitrator, newReputation);
    }

    /**
     * @dev Updates minimum requirements
     */
    function updateRequirements(
        uint256 _minReputation,
        uint256 _minParticipationIndex,
        uint256 _maxActiveDisputes,
        uint256 _disputeTimeout,
        uint256 _ratingWeight
    ) external onlyOwner {
        minReputation = _minReputation;
        minParticipationIndex = _minParticipationIndex;
        maxActiveDisputes = _maxActiveDisputes;
        disputeTimeout = _disputeTimeout;
        ratingWeight = _ratingWeight;
    }

    /**
     * @dev Gets arbitrator details
     */
    function getArbitrator(
        address _arbitrator
    )
        external
        view
        returns (
            uint256 reputation,
            uint256 participationIndex,
            uint256 totalCases,
            uint256 successfulCases,
            bool isActive,
            uint256 lastActiveTimestamp
        )
    {
        Arbitrator storage arbitrator = arbitrators[_arbitrator];
        return (
            arbitrator.reputation,
            arbitrator.participationIndex,
            arbitrator.totalCases,
            arbitrator.successfulCases,
            arbitrator.isActive,
            arbitrator.lastActiveTimestamp
        );
    }

    /**
     * @dev Gets dispute details
     */
    function getDispute(
        bytes32 _escrowId
    )
        external
        view
        returns (
            address arbitrator,
            uint256 timestamp,
            bool isResolved,
            string memory resolution,
            uint256 buyerRating,
            uint256 sellerRating,
            uint256 arbitratorRating
        )
    {
        Dispute storage dispute = disputes[_escrowId];
        return (
            dispute.arbitrator,
            dispute.timestamp,
            dispute.isResolved,
            dispute.resolution,
            dispute.buyerRating,
            dispute.sellerRating,
            dispute.arbitratorRating
        );
    }

    /**
     * @dev Gets user's dispute history
     */
    function getUserDisputes(
        address _user
    ) external view returns (bytes32[] memory) {
        return userDisputes[_user];
    }

    /**
     * @dev Gets arbitrator's dispute history
     */
    function getArbitratorDisputes(
        address _arbitrator
    ) external view returns (bytes32[] memory) {
        return arbitratorDisputes[_arbitrator];
    }
}
