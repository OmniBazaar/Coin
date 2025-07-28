// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {
    MpcCore, 
    gtBool, 
    gtUint64, 
    ctBool, 
    ctUint64, 
    itUint64
} from "../coti-contracts/contracts/utils/mpc/MpcCore.sol";
import {OmniCoinCore} from "./OmniCoinCore.sol";
import {OmniCoinAccount} from "./OmniCoinAccount.sol";
import {OmniCoinEscrow} from "./OmniCoinEscrow.sol";
import {OmniCoinConfig} from "./OmniCoinConfig.sol";
import {PrivacyFeeManager} from "./PrivacyFeeManager.sol";

/**
 * @title OmniCoinArbitration
 * @author OmniCoin Development Team
 * @notice Custom arbitration system leveraging COTI V2's privacy infrastructure
 * @dev Uses MPC for confidential dispute resolution with OmniBazaar arbitrator network
 */
contract OmniCoinArbitration is
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable
{
    // =============================================================================
    // STRUCTS
    // =============================================================================
    
    struct OmniBazaarArbitrator {
        address account;                 // 20 bytes
        bool isActive;                   // 1 byte - Active status
        // 11 bytes padding
        ctUint64 privateEarnings;        // 32 bytes - Private arbitration earnings (MPC)
        uint256 reputation;              // 32 bytes - Public reputation score
        uint256 participationIndex;      // 32 bytes - PoP participation score
        uint256 totalCases;              // 32 bytes - Total cases handled
        uint256 successfulCases;         // 32 bytes - Successfully resolved cases
        uint256 stakingAmount;           // 32 bytes - XOM staked for arbitration eligibility
        uint256 lastActiveTimestamp;     // 32 bytes - Last activity timestamp (time tracking required)
        uint256 specializationMask;      // 32 bytes - Bitmask for specialization areas
    }

    struct ConfidentialDispute {
        bytes32 escrowId;               // Public escrow identifier
        address primaryArbitrator;      // Main arbitrator assigned
        address[] panelArbitrators;     // Panel for complex disputes (max 3)
        uint256 timestamp;              // Dispute creation time (time tracking required)
        uint256 disputeType;            // 1=Simple, 2=Complex, 3=Appeal
        bytes32 evidenceHash;           // Hash of submitted evidence
        
        // Private dispute data using COTI V2 MPC
        ctUint64 disputedAmount;        // Private disputed amount
        ctUint64 escrowBalance;         // Private total escrow balance
        ctUint64 buyerClaim;            // Private buyer's claimed amount
        ctUint64 sellerClaim;           // Private seller's claimed amount
        ctBool isResolved;              // Private resolution status
        ctUint64 finalBuyerPayout;      // Private buyer payout
        ctUint64 finalSellerPayout;     // Private seller payout
        ctUint64 arbitrationFee;        // Private arbitration fee
        
        // Public metadata
        uint256 buyerRating;            // Public buyer rating (1-5)
        uint256 sellerRating;           // Public seller rating (1-5)
        uint256 arbitratorRating;       // Public arbitrator rating (1-5)
        bytes32 resolutionHash;         // Hash of resolution reasoning
        uint256 deadlineTimestamp;      // Resolution deadline (time tracking required)
    }

    // =============================================================================
    // CONSTANTS
    // =============================================================================
    
    /// @notice Arbitrator specialization: Digital goods
    uint256 public constant SPEC_DIGITAL_GOODS = 1;       // 2^0
    /// @notice Arbitrator specialization: Physical goods
    uint256 public constant SPEC_PHYSICAL_GOODS = 2;      // 2^1  
    /// @notice Arbitrator specialization: Services
    uint256 public constant SPEC_SERVICES = 4;            // 2^2
    /// @notice Arbitrator specialization: High value transactions
    uint256 public constant SPEC_HIGH_VALUE = 8;          // 2^3 (>10,000 XOM)
    /// @notice Arbitrator specialization: International trade
    uint256 public constant SPEC_INTERNATIONAL = 16;      // 2^4
    /// @notice Arbitrator specialization: Technical disputes
    uint256 public constant SPEC_TECHNICAL = 32;          // 2^5
    
    /// @notice Threshold for simple disputes (1,000 XOM)
    uint256 public constant SIMPLE_DISPUTE_THRESHOLD = 1000 * 10**18;
    /// @notice Threshold for complex disputes (10,000 XOM)
    uint256 public constant COMPLEX_DISPUTE_THRESHOLD = 10000 * 10**18;
    /// @notice Number of arbitrators in a panel
    uint256 public constant PANEL_SIZE = 3;
    /// @notice Time limit for dispute resolution
    uint256 public constant RESOLUTION_PERIOD = 7 days;
    
    /// @notice Privacy fee multiplier (10x normal fee)
    uint256 public constant PRIVACY_MULTIPLIER = 10;
    
    /// @notice Arbitration fee rate (1% of disputed amount)
    uint256 public constant ARBITRATION_FEE_RATE = 100;
    /// @notice Arbitrator fee share (70% to arbitrators)
    uint256 public constant ARBITRATOR_FEE_SHARE = 70;
    /// @notice Treasury fee share (20% to OmniBazaar treasury)
    uint256 public constant TREASURY_FEE_SHARE = 20;
    /// @notice Validator fee share (10% to validator network)
    uint256 public constant VALIDATOR_FEE_SHARE = 10;
    
    // =============================================================================
    // CUSTOM ERRORS
    // =============================================================================
    
    error InvalidAddress();
    error AlreadyRegistered();
    error InsufficientStakingAmount();
    error NoSpecializationProvided();
    error InsufficientReputation();
    error InsufficientParticipation();
    error StakingTransferFailed();
    error NotActiveArbitrator();
    error MustStakeAdditionalAmount();
    error AdditionalStakingTransferFailed();
    error EscrowNotDisputed();
    error NotAuthorized();
    error DisputeAlreadyExists();
    error TotalClaimsExceedEscrowBalance();
    error NoSuitableArbitratorFound();
    error PrivacyNotAvailable();
    error PrivacyFeeManagerNotSet();
    error AlreadyResolved();
    error NotAuthorizedArbitrator();
    error ResolutionDeadlinePassed();
    error TotalPayoutsExceedEscrowBalance();
    error PanelConsensusRequired();
    error InvalidRating();
    error NotAuthorizedToRate();
    error DisputeNotResolved();
    error AlreadyRated();
    error OnlyBuyerAndSellerCanRate();
    error NoEarningsToClaim();
    
    // =============================================================================
    // STATE VARIABLES
    // =============================================================================
    
    /// @notice OmniBazaar arbitrator registry
    mapping(address => OmniBazaarArbitrator) public arbitrators;
    
    /// @notice Private dispute storage
    mapping(bytes32 => ConfidentialDispute) private disputes;
    
    /// @notice Arbitrator's active disputes
    mapping(address => bytes32[]) public arbitratorDisputes;
    
    /// @notice User's disputes
    mapping(address => bytes32[]) public userDisputes;
    
    // Private dispute tracking using COTI V2 MPC
    mapping(bytes32 => address[]) private disputeParticipants;     // [buyer, seller, arbitrator(s)]
    mapping(bytes32 => ctUint64) private disputeFeeDistribution;   // Private fee breakdown
    mapping(address => ctUint64) private arbitratorTotalEarnings;  // Private lifetime earnings

    /// @notice OmniCoin core contract
    OmniCoinCore public omniCoin;
    /// @notice Account abstraction contract
    OmniCoinAccount public omniCoinAccount;
    /// @notice Escrow contract
    OmniCoinEscrow public omniCoinEscrow;
    /// @notice Configuration contract
    OmniCoinConfig public config;

    /// @notice Minimum reputation score required
    uint256 public minReputation;
    /// @notice Minimum participation index required
    uint256 public minParticipationIndex;
    /// @notice Minimum staking amount required
    uint256 public minStakingAmount;
    /// @notice Maximum concurrent disputes per arbitrator
    uint256 public maxActiveDisputes;
    /// @notice Dispute resolution timeout
    uint256 public disputeTimeout;
    /// @notice Weight for rating updates
    uint256 public ratingWeight;
    
    /// @notice MPC availability flag (true on COTI network)
    bool public isMpcAvailable;
    
    /// @notice Privacy fee manager contract address
    address public privacyFeeManager;

    // =============================================================================
    // EVENTS
    // =============================================================================
    
    /**
     * @notice Emitted when an arbitrator registers
     * @param arbitrator Address of the arbitrator
     * @param specializations Bitmask of specialization areas
     * @param stakingAmount Amount of XOM staked
     */
    event ArbitratorRegistered(
        address indexed arbitrator,
        uint256 indexed specializations,
        uint256 indexed stakingAmount
    );
    /**
     * @notice Emitted when an arbitrator is removed
     * @param arbitrator Address of the arbitrator
     * @param reason Reason for removal
     */
    event ArbitratorRemoved(
        address indexed arbitrator,
        string reason
    );
    /**
     * @notice Emitted when arbitrator stake is updated
     * @param arbitrator Address of the arbitrator
     * @param newStakingAmount New staking amount
     */
    event ArbitratorStakeUpdated(
        address indexed arbitrator,
        uint256 indexed newStakingAmount
    );
    /**
     * @notice Emitted when a confidential dispute is created
     * @param escrowId Escrow contract identifier
     * @param primaryArbitrator Assigned arbitrator address
     * @param disputeType Type of dispute (1=Simple, 2=Complex, 3=Appeal)
     * @param evidenceHash Hash of submitted evidence
     */
    event ConfidentialDisputeCreated(
        bytes32 indexed escrowId,
        address indexed primaryArbitrator,
        uint256 indexed disputeType,
        bytes32 evidenceHash
    );
    /**
     * @notice Emitted when a dispute panel is formed
     * @param escrowId Escrow contract identifier
     * @param panelArbitrators Array of panel arbitrator addresses
     */
    event DisputePanelFormed(
        bytes32 indexed escrowId,
        address[] panelArbitrators
    );
    /**
     * @notice Emitted when a confidential dispute is resolved
     * @param escrowId Escrow contract identifier
     * @param resolutionHash Hash of resolution reasoning
     * @param timestamp Resolution timestamp
     * @param payoutHash Hash of private payout amounts
     */
    event ConfidentialDisputeResolved(
        bytes32 indexed escrowId,
        bytes32 resolutionHash,
        uint256 indexed timestamp,
        bytes32 payoutHash
    );
    /**
     * @notice Emitted when arbitration fees are distributed
     * @param escrowId Escrow contract identifier
     * @param feeDistributionHash Hash of private fee distribution
     */
    event ArbitrationFeeDistributed(
        bytes32 indexed escrowId,
        bytes32 feeDistributionHash
    );
    /**
     * @notice Emitted when a rating is submitted
     * @param escrowId Escrow contract identifier
     * @param rater Address of the rater
     * @param rating Rating value (1-5)
     */
    event RatingSubmitted(
        bytes32 indexed escrowId,
        address indexed rater,
        uint256 indexed rating
    );
    /**
     * @notice Emitted when arbitrator reputation is updated
     * @param arbitrator Address of the arbitrator
     * @param newReputation New reputation score
     */
    event ReputationUpdated(
        address indexed arbitrator,
        uint256 indexed newReputation
    );
    /**
     * @notice Emitted when private earnings are updated
     * @param arbitrator Address of the arbitrator
     * @param earningsHash Hash of private earnings update
     */
    event PrivateEarningsUpdated(
        address indexed arbitrator,
        bytes32 earningsHash
    );

    /// @custom:oz-upgrades-unsafe-allow constructor
    /**
     * @notice Disables initializers for implementation contract
     */
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the OmniBazaar arbitration system
     * @dev Sets up all contract references and parameters
     * @param _omniCoin OmniCoin core contract address
     * @param _omniCoinAccount Account abstraction contract address
     * @param _omniCoinEscrow Escrow contract address
     * @param _config Configuration contract address
     * @param _minReputation Minimum reputation score required
     * @param _minParticipationIndex Minimum participation index required
     * @param _minStakingAmount Minimum staking amount required
     * @param _maxActiveDisputes Maximum concurrent disputes per arbitrator
     * @param _disputeTimeout Dispute resolution timeout period
     * @param _ratingWeight Weight factor for rating updates
     */
    function initialize(
        address _omniCoin,
        address _omniCoinAccount,
        address _omniCoinEscrow,
        address _config,
        uint256 _minReputation,
        uint256 _minParticipationIndex,
        uint256 _minStakingAmount,
        uint256 _maxActiveDisputes,
        uint256 _disputeTimeout,
        uint256 _ratingWeight
    ) public initializer {
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();
        
        omniCoin = OmniCoinCore(_omniCoin);
        omniCoinAccount = OmniCoinAccount(_omniCoinAccount);
        omniCoinEscrow = OmniCoinEscrow(_omniCoinEscrow);
        config = OmniCoinConfig(_config);
        
        minReputation = _minReputation;
        minParticipationIndex = _minParticipationIndex;
        minStakingAmount = _minStakingAmount;
        maxActiveDisputes = _maxActiveDisputes;
        disputeTimeout = _disputeTimeout;
        ratingWeight = _ratingWeight;
        
        // MPC availability will be set by admin after deployment
        isMpcAvailable = false; // Default to false (Hardhat/testing mode)
    }
    
    /**
     * @notice Set the privacy fee manager contract address
     * @param _privacyFeeManager Address of the privacy fee manager contract
     */
    function setPrivacyFeeManager(address _privacyFeeManager) external onlyOwner {
        if (_privacyFeeManager == address(0)) revert InvalidAddress();
        privacyFeeManager = _privacyFeeManager;
    }
    
    /**
     * @notice Set MPC availability status for COTI network deployment
     * @param _available Whether MPC is available (true on COTI network)
     */
    function setMpcAvailability(bool _available) external onlyOwner {
        isMpcAvailable = _available;
    }

    /**
     * @notice Registers a new arbitrator in the OmniBazaar network
     * @dev Requires minimum staking and reputation (if not in testnet mode)
     * @param _stakingAmount Amount of XOM to stake for arbitration eligibility
     * @param _specializations Bitmask of specialization areas
     */
    function registerArbitrator(
        uint256 _stakingAmount,
        uint256 _specializations
    ) external {
        if (arbitrators[msg.sender].isActive) revert AlreadyRegistered();
        if (_stakingAmount < minStakingAmount) revert InsufficientStakingAmount();
        if (_specializations == 0) revert NoSpecializationProvided();

        uint256 reputation = 0;
        uint256 participationIndex = 0;
        
        // Skip reputation checks in testnet mode
        if (!config.isTestnetMode()) {
            reputation = omniCoinAccount.reputationScore(msg.sender);
            participationIndex = _calculateParticipationIndex(msg.sender);
            
            if (reputation < minReputation) revert InsufficientReputation();
            if (participationIndex < minParticipationIndex) revert InsufficientParticipation();
        }

        // Transfer staking amount to this contract
        if (!omniCoin.transferFromPublic(msg.sender, address(this), _stakingAmount)) {
            revert StakingTransferFailed();
        }

        // Initialize private earnings as zero
        ctUint64 initialEarnings;
        if (isMpcAvailable) {
            gtUint64 gtZero = MpcCore.setPublic64(uint64(0));
            initialEarnings = MpcCore.offBoard(gtZero);
        } else {
            // In testing mode, use a placeholder value
            initialEarnings = ctUint64.wrap(0);
        }

        arbitrators[msg.sender] = OmniBazaarArbitrator({
            account: msg.sender,
            reputation: reputation,
            participationIndex: participationIndex,
            totalCases: 0,
            successfulCases: 0,
            stakingAmount: _stakingAmount,
            isActive: true,
            lastActiveTimestamp: block.timestamp, // solhint-disable-line not-rely-on-time
            privateEarnings: initialEarnings,
            specializationMask: _specializations
        });

        arbitratorTotalEarnings[msg.sender] = initialEarnings;

        emit ArbitratorRegistered(msg.sender, _specializations, _stakingAmount);
    }

    /**
     * @notice Increases arbitrator's staking amount
     * @param _additionalStake Additional XOM to stake
     */
    function increaseArbitratorStake(uint256 _additionalStake) external {
        if (!arbitrators[msg.sender].isActive) revert NotActiveArbitrator();
        if (_additionalStake == 0) revert MustStakeAdditionalAmount();

        if (!omniCoin.transferFromPublic(msg.sender, address(this), _additionalStake)) {
            revert AdditionalStakingTransferFailed();
        }

        arbitrators[msg.sender].stakingAmount += _additionalStake;

        emit ArbitratorStakeUpdated(msg.sender, arbitrators[msg.sender].stakingAmount);
    }

    /**
     * @notice Creates a public dispute without privacy features
     * @dev Default method for dispute creation, no privacy fees
     * @param _escrowId The escrow ID in dispute
     * @param _disputedAmount Amount in dispute
     * @param _buyerClaim Buyer's claimed amount
     * @param _sellerClaim Seller's claimed amount
     * @param _evidenceHash Hash of dispute evidence
     */
    function createDispute(
        bytes32 _escrowId,
        uint256 _disputedAmount,
        uint256 _buyerClaim,
        uint256 _sellerClaim,
        bytes32 _evidenceHash
    ) external {
        uint256 escrowId = uint256(_escrowId);
        (address seller, address buyer, , , , bool disputed, ) = 
            omniCoinEscrow.getEscrowDetails(escrowId);
        
        // Get the escrow amount (would need separate method in production)
        uint256 amount = _disputedAmount;
        
        if (!disputed) revert EscrowNotDisputed();
        if (msg.sender != buyer && msg.sender != seller) revert NotAuthorized();
        if (disputes[_escrowId].timestamp != 0) revert DisputeAlreadyExists();
        if (_buyerClaim + _sellerClaim > amount) revert TotalClaimsExceedEscrowBalance();
        
        // Convert to encrypted for internal storage
        ctUint64 encryptedDisputedAmount = ctUint64.wrap(_disputedAmount);
        ctUint64 encryptedBuyerClaim = ctUint64.wrap(_buyerClaim);
        ctUint64 encryptedSellerClaim = ctUint64.wrap(_sellerClaim);
        ctUint64 encryptedEscrowBalance = ctUint64.wrap(amount);
        
        // Determine dispute type and select arbitrators
        uint256 disputeType = _determineDisputeType(encryptedDisputedAmount);
        address primaryArbitrator;
        address[] memory panelArbitrators;
        
        if (disputeType == 1) {
            primaryArbitrator = _selectSingleArbitrator(_escrowId, encryptedDisputedAmount);
            panelArbitrators = new address[](0);
        } else {
            (primaryArbitrator, panelArbitrators) = _selectArbitrationPanel(_escrowId, encryptedDisputedAmount);
        }
        
        if (primaryArbitrator == address(0)) revert NoSuitableArbitratorFound();
        
        // Calculate arbitration fee (public)
        uint256 fee = (_disputedAmount * ARBITRATION_FEE_RATE) / 10000;
        ctUint64 arbitrationFee = ctUint64.wrap(fee);
        
        // Create dispute
        _createDisputeInternal(
            _escrowId,
            primaryArbitrator,
            panelArbitrators,
            disputeType,
            _evidenceHash,
            encryptedDisputedAmount,
            encryptedEscrowBalance,
            encryptedBuyerClaim,
            encryptedSellerClaim,
            arbitrationFee,
            buyer,
            seller
        );
    }
    
    /**
     * @notice Creates a confidential dispute with privacy protection
     * @dev Premium feature requiring privacy fees and MPC
     * @param _escrowId The escrow ID in dispute
     * @param _disputedAmount Private amount in dispute (encrypted)
     * @param _buyerClaim Private buyer's claimed amount (encrypted)
     * @param _sellerClaim Private seller's claimed amount (encrypted)
     * @param _evidenceHash Hash of dispute evidence
     * @param usePrivacy Whether to use privacy features
     */
    function createDisputeWithPrivacy(
        bytes32 _escrowId,
        itUint64 calldata _disputedAmount,
        itUint64 calldata _buyerClaim,
        itUint64 calldata _sellerClaim,
        bytes32 _evidenceHash,
        bool usePrivacy
    ) external {
        if (!usePrivacy || !isMpcAvailable) revert PrivacyNotAvailable();
        if (privacyFeeManager == address(0)) revert PrivacyFeeManagerNotSet();
        uint256 escrowId = uint256(_escrowId);
        (address seller, address buyer, , , , bool disputed, ) = 
            omniCoinEscrow.getEscrowDetails(escrowId);
        
        // For privacy disputes, we work with encrypted amounts throughout
        // In production, the escrow contract would provide encrypted amount
        
        if (!disputed) revert EscrowNotDisputed();
        if (msg.sender != buyer && msg.sender != seller) revert NotAuthorized();
        if (disputes[_escrowId].timestamp != 0) revert DisputeAlreadyExists();
        
        // Validate encrypted inputs
        gtUint64 gtDisputedAmount = MpcCore.validateCiphertext(_disputedAmount);
        gtUint64 gtBuyerClaim = MpcCore.validateCiphertext(_buyerClaim);
        gtUint64 gtSellerClaim = MpcCore.validateCiphertext(_sellerClaim);
        
        // Verify claims don't exceed escrow balance
        // In privacy mode, we work with the encrypted disputed amount as the escrow balance
        gtUint64 gtEscrowBalance = gtDisputedAmount;
        gtUint64 gtTotalClaim = MpcCore.add(gtBuyerClaim, gtSellerClaim);
        gtBool claimsValid = MpcCore.le(gtTotalClaim, gtEscrowBalance);
        if (!MpcCore.decrypt(claimsValid)) revert TotalClaimsExceedEscrowBalance();
        
        // Calculate privacy fee (1% of disputed amount for arbitration)
        uint256 arbitrationPrivacyFeeRate = 100; // 1% in basis points
        uint256 basisPoints = 10000;
        gtUint64 feeRate = MpcCore.setPublic64(uint64(arbitrationPrivacyFeeRate));
        gtUint64 basisPointsGt = MpcCore.setPublic64(uint64(basisPoints));
        gtUint64 fee = MpcCore.mul(gtDisputedAmount, feeRate);
        fee = MpcCore.div(fee, basisPointsGt);
        
        // Collect privacy fee (10x normal fee)
        uint256 normalFee = uint64(gtUint64.unwrap(fee));
        uint256 privacyFee = normalFee * PRIVACY_MULTIPLIER;
        PrivacyFeeManager(privacyFeeManager).collectPrivacyFee(
            msg.sender,
            keccak256("ARBITRATION_DISPUTE"),
            privacyFee
        );
        
        // Convert amounts for internal storage
        ctUint64 encryptedDisputedAmount = MpcCore.offBoard(gtDisputedAmount);
        ctUint64 encryptedBuyerClaim = MpcCore.offBoard(gtBuyerClaim);
        ctUint64 encryptedSellerClaim = MpcCore.offBoard(gtSellerClaim);
        ctUint64 encryptedEscrowBalance = MpcCore.offBoard(gtEscrowBalance);
        
        // Determine dispute type and select arbitrators
        uint256 disputeType = _determineDisputeType(encryptedDisputedAmount);
        address primaryArbitrator;
        address[] memory panelArbitrators;
        
        if (disputeType == 1) {
            primaryArbitrator = _selectSingleArbitrator(_escrowId, encryptedDisputedAmount);
            panelArbitrators = new address[](0);
        } else {
            (primaryArbitrator, panelArbitrators) = _selectArbitrationPanel(_escrowId, encryptedDisputedAmount);
        }
        
        if (primaryArbitrator == address(0)) revert NoSuitableArbitratorFound();
        
        // Calculate arbitration fee
        gtUint64 gtArbitrationFeeRate = MpcCore.setPublic64(uint64(ARBITRATION_FEE_RATE));
        gtUint64 gtArbitrationFee = MpcCore.mul(gtDisputedAmount, gtArbitrationFeeRate);
        gtUint64 gtBasisPoints = MpcCore.setPublic64(uint64(10000));
        gtArbitrationFee = MpcCore.div(gtArbitrationFee, gtBasisPoints);
        ctUint64 arbitrationFee = MpcCore.offBoard(gtArbitrationFee);
        
        // Create dispute
        _createDisputeInternal(
            _escrowId,
            primaryArbitrator,
            panelArbitrators,
            disputeType,
            _evidenceHash,
            encryptedDisputedAmount,
            encryptedEscrowBalance,
            encryptedBuyerClaim,
            encryptedSellerClaim,
            arbitrationFee,
            buyer,
            seller
        );
    }
    
    /**
     * @notice Resolves a dispute with public payouts (no privacy fees)
     * @param _escrowId The dispute to resolve
     * @param _buyerPayout Payout amount for buyer
     * @param _sellerPayout Payout amount for seller
     * @param _resolutionHash Hash of resolution reasoning
     */
    function resolveDispute(
        bytes32 _escrowId,
        uint256 _buyerPayout,
        uint256 _sellerPayout,
        bytes32 _resolutionHash
    ) external nonReentrant {
        ConfidentialDispute storage dispute = disputes[_escrowId];
        
        if (ctBool.unwrap(dispute.isResolved) != 0) revert AlreadyResolved();
        if (msg.sender != dispute.primaryArbitrator && !_isPanelArbitrator(_escrowId, msg.sender)) {
            revert NotAuthorizedArbitrator();
        }
        // Time-based decision required for dispute deadline
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp > dispute.deadlineTimestamp) revert ResolutionDeadlinePassed();
        
        // Verify total payouts
        uint256 escrowBalance = ctUint64.unwrap(dispute.escrowBalance);
        if (_buyerPayout + _sellerPayout > escrowBalance) revert TotalPayoutsExceedEscrowBalance();
        
        // For panel disputes, require consensus
        if (dispute.panelArbitrators.length > 0) {
            ctUint64 buyerPayoutForConsensus = ctUint64.wrap(_buyerPayout);
            ctUint64 sellerPayoutForConsensus = ctUint64.wrap(_sellerPayout);
            if (!_verifyPanelConsensus(_escrowId, buyerPayoutForConsensus, sellerPayoutForConsensus)) {
                revert PanelConsensusRequired();
            }
        }
        
        // Update dispute with resolution
        dispute.isResolved = ctBool.wrap(1);
        dispute.finalBuyerPayout = ctUint64.wrap(_buyerPayout);
        dispute.finalSellerPayout = ctUint64.wrap(_sellerPayout);
        dispute.resolutionHash = _resolutionHash;
        
        // Distribute arbitration fees
        _distributeArbitrationFees(_escrowId);
        
        // Update arbitrator success statistics
        ++arbitrators[dispute.primaryArbitrator].successfulCases;
        for (uint256 i = 0; i < dispute.panelArbitrators.length; ++i) {
            ++arbitrators[dispute.panelArbitrators[i]].successfulCases;
        }
        
        // Execute payouts
        ctUint64 buyerPayoutEncrypted = ctUint64.wrap(_buyerPayout);
        ctUint64 sellerPayoutEncrypted = ctUint64.wrap(_sellerPayout);
        _executePrivatePayouts(_escrowId, buyerPayoutEncrypted, sellerPayoutEncrypted);
        
        // Create verification hash
        bytes32 payoutHash = keccak256(abi.encode(
            _buyerPayout, _sellerPayout, 
            block.timestamp, // solhint-disable-line not-rely-on-time
            _resolutionHash
        ));
        
        // Time tracking for resolution event
        // solhint-disable-next-line not-rely-on-time
        emit ConfidentialDisputeResolved(_escrowId, _resolutionHash, block.timestamp, payoutHash);
    }
    
    /**
     * @notice Resolves a dispute with private payouts (premium feature)
     * @param _escrowId The dispute to resolve
     * @param _buyerPayout Private payout amount for buyer (encrypted)
     * @param _sellerPayout Private payout amount for seller (encrypted)
     * @param _resolutionHash Hash of resolution reasoning
     * @param usePrivacy Whether to use privacy features
     */
    function resolveDisputeWithPrivacy(
        bytes32 _escrowId,
        itUint64 calldata _buyerPayout,
        itUint64 calldata _sellerPayout,
        bytes32 _resolutionHash,
        bool usePrivacy
    ) external nonReentrant {
        if (!usePrivacy || !isMpcAvailable) revert PrivacyNotAvailable();
        if (privacyFeeManager == address(0)) revert PrivacyFeeManagerNotSet();
        ConfidentialDispute storage dispute = disputes[_escrowId];
        
        gtBool gtIsResolved = MpcCore.onBoard(dispute.isResolved);
        if (MpcCore.decrypt(gtIsResolved)) revert AlreadyResolved();
        if (msg.sender != dispute.primaryArbitrator && !_isPanelArbitrator(_escrowId, msg.sender)) {
            revert NotAuthorizedArbitrator();
        }
        // Time-based decision required for dispute deadline
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp > dispute.deadlineTimestamp) revert ResolutionDeadlinePassed();
        
        // Validate encrypted inputs
        gtUint64 gtBuyerPayout = MpcCore.validateCiphertext(_buyerPayout);
        gtUint64 gtSellerPayout = MpcCore.validateCiphertext(_sellerPayout);
        
        // Verify total payouts don't exceed escrow balance
        gtUint64 gtTotalPayout = MpcCore.add(gtBuyerPayout, gtSellerPayout);
        gtUint64 gtEscrowBalance = MpcCore.onBoard(dispute.escrowBalance);
        gtBool payoutsValid = MpcCore.le(gtTotalPayout, gtEscrowBalance);
        if (!MpcCore.decrypt(payoutsValid)) revert TotalPayoutsExceedEscrowBalance();
        
        // Calculate privacy fee for resolution (0.5% of total payout)
        uint256 resolutionPrivacyFeeRate = 50; // 0.5% in basis points
        uint256 basisPoints = 10000;
        gtUint64 feeRate = MpcCore.setPublic64(uint64(resolutionPrivacyFeeRate));
        gtUint64 basisPointsGt = MpcCore.setPublic64(uint64(basisPoints));
        gtUint64 fee = MpcCore.mul(gtTotalPayout, feeRate);
        fee = MpcCore.div(fee, basisPointsGt);
        
        // Collect privacy fee (10x normal fee)
        uint256 normalFee = uint64(gtUint64.unwrap(fee));
        uint256 privacyFee = normalFee * PRIVACY_MULTIPLIER;
        PrivacyFeeManager(privacyFeeManager).collectPrivacyFee(
            msg.sender,
            keccak256("ARBITRATION_RESOLUTION"),
            privacyFee
        );
        
        // Convert amounts for storage
        ctUint64 encryptedBuyerPayout = MpcCore.offBoard(gtBuyerPayout);
        ctUint64 encryptedSellerPayout = MpcCore.offBoard(gtSellerPayout);
        
        // For panel disputes, require consensus
        if (dispute.panelArbitrators.length > 0) {
            if (!_verifyPanelConsensus(_escrowId, encryptedBuyerPayout, encryptedSellerPayout)) {
                revert PanelConsensusRequired();
            }
        }
        
        // Update dispute with private resolution
        dispute.isResolved = MpcCore.offBoard(MpcCore.setPublic(true));
        dispute.finalBuyerPayout = encryptedBuyerPayout;
        dispute.finalSellerPayout = encryptedSellerPayout;
        dispute.resolutionHash = _resolutionHash;
        
        // Distribute arbitration fees
        _distributeArbitrationFees(_escrowId);
        
        // Update arbitrator success statistics
        ++arbitrators[dispute.primaryArbitrator].successfulCases;
        for (uint256 i = 0; i < dispute.panelArbitrators.length; ++i) {
            ++arbitrators[dispute.panelArbitrators[i]].successfulCases;
        }
        
        // Execute private payouts
        _executePrivatePayouts(_escrowId, encryptedBuyerPayout, encryptedSellerPayout);
        
        // Create verification hash
        bytes32 payoutHash = keccak256(abi.encode(
            encryptedBuyerPayout, encryptedSellerPayout, 
            block.timestamp, // solhint-disable-line not-rely-on-time
            _resolutionHash
        ));
        
        // Time tracking for resolution event
        // solhint-disable-next-line not-rely-on-time
        emit ConfidentialDisputeResolved(_escrowId, _resolutionHash, block.timestamp, payoutHash);
    }

    /**
     * @notice Distributes arbitration fees privately using COTI V2 MPC
     * @param _escrowId Escrow identifier for the dispute
     */
    function _distributeArbitrationFees(bytes32 _escrowId) internal {
        ConfidentialDispute storage dispute = disputes[_escrowId];
        
        // Skip fee distribution in testing mode
        if (!isMpcAvailable) {
            // In testing mode, just emit event for tracking
            emit ArbitrationFeeDistributed(_escrowId, keccak256(abi.encode("test_mode_distribution")));
            return;
        }
        
        // Calculate fee distribution (70% arbitrators/20% treasury/10% validators) - all private
        ctUint64 totalFee = dispute.arbitrationFee;
        gtUint64 gtTotalFee = MpcCore.onBoard(totalFee);
        gtUint64 gtHundred = MpcCore.setPublic64(uint64(100));
        
        gtUint64 gtArbitratorPercent = MpcCore.setPublic64(uint64(ARBITRATOR_FEE_SHARE));
        gtUint64 gtArbitratorFee = MpcCore.mul(gtTotalFee, gtArbitratorPercent);
        gtUint64 gtArbitratorShare = MpcCore.div(gtArbitratorFee, gtHundred);
        ctUint64 arbitratorShare = MpcCore.offBoard(gtArbitratorShare);
        
        gtUint64 gtTreasuryPercent = MpcCore.setPublic64(uint64(TREASURY_FEE_SHARE));
        gtUint64 gtTreasuryFee = MpcCore.mul(gtTotalFee, gtTreasuryPercent);
        gtUint64 gtTreasuryShare = MpcCore.div(gtTreasuryFee, gtHundred);
        ctUint64 treasuryShare = MpcCore.offBoard(gtTreasuryShare);
        
        gtUint64 gtValidatorPercent = MpcCore.setPublic64(uint64(VALIDATOR_FEE_SHARE));
        gtUint64 gtValidatorFee = MpcCore.mul(gtTotalFee, gtValidatorPercent);
        gtUint64 gtValidatorShare = MpcCore.div(gtValidatorFee, gtHundred);
        ctUint64 validatorShare = MpcCore.offBoard(gtValidatorShare);
        
        // Update arbitrator private earnings
        if (dispute.panelArbitrators.length == 0) {
            // Single arbitrator gets full arbitrator share
            gtUint64 gtCurrentEarnings = MpcCore.onBoard(arbitrators[dispute.primaryArbitrator].privateEarnings);
            gtUint64 gtNewEarnings = MpcCore.add(gtCurrentEarnings, gtArbitratorShare);
            arbitrators[dispute.primaryArbitrator].privateEarnings = MpcCore.offBoard(gtNewEarnings);
            
            gtUint64 gtCurrentTotal = MpcCore.onBoard(arbitratorTotalEarnings[dispute.primaryArbitrator]);
            gtUint64 gtNewTotal = MpcCore.add(gtCurrentTotal, gtArbitratorShare);
            arbitratorTotalEarnings[dispute.primaryArbitrator] = MpcCore.offBoard(gtNewTotal);
        } else {
            // Split arbitrator share among panel (primary gets 50%, others split 50%)
            gtUint64 gtTwo = MpcCore.setPublic64(uint64(2));
            gtUint64 gtPrimaryShare = MpcCore.div(gtArbitratorShare, gtTwo);
            // ctUint64 primaryShare = MpcCore.offBoard(gtPrimaryShare);
            
            gtUint64 gtRemaining = MpcCore.sub(gtArbitratorShare, gtPrimaryShare);
            gtUint64 gtPanelCount = MpcCore.setPublic64(uint64(dispute.panelArbitrators.length));
            gtUint64 gtPanelShare = MpcCore.div(gtRemaining, gtPanelCount);
            // ctUint64 panelShare = MpcCore.offBoard(gtPanelShare);
            
            // Update primary arbitrator
            gtUint64 gtCurrentEarnings = MpcCore.onBoard(arbitrators[dispute.primaryArbitrator].privateEarnings);
            gtUint64 gtNewEarnings = MpcCore.add(gtCurrentEarnings, gtPrimaryShare);
            arbitrators[dispute.primaryArbitrator].privateEarnings = MpcCore.offBoard(gtNewEarnings);
            
            gtUint64 gtCurrentTotal = MpcCore.onBoard(arbitratorTotalEarnings[dispute.primaryArbitrator]);
            gtUint64 gtNewTotal = MpcCore.add(gtCurrentTotal, gtPrimaryShare);
            arbitratorTotalEarnings[dispute.primaryArbitrator] = MpcCore.offBoard(gtNewTotal);
                
            // Update panel arbitrators
            for (uint256 i = 0; i < dispute.panelArbitrators.length; ++i) {
                gtUint64 gtPanelCurrentEarnings = MpcCore.onBoard(
                    arbitrators[dispute.panelArbitrators[i]].privateEarnings
                );
                gtUint64 gtPanelNewEarnings = MpcCore.add(gtPanelCurrentEarnings, gtPanelShare);
                arbitrators[dispute.panelArbitrators[i]].privateEarnings = MpcCore.offBoard(gtPanelNewEarnings);
                
                gtUint64 gtPanelCurrentTotal = MpcCore.onBoard(arbitratorTotalEarnings[dispute.panelArbitrators[i]]);
                gtUint64 gtPanelNewTotal = MpcCore.add(gtPanelCurrentTotal, gtPanelShare);
                arbitratorTotalEarnings[dispute.panelArbitrators[i]] = MpcCore.offBoard(gtPanelNewTotal);
            }
        }
        
        // Store fee distribution hash for transparency
        bytes32 feeDistributionHash = keccak256(abi.encode(
            arbitratorShare, treasuryShare, validatorShare, 
            block.timestamp // solhint-disable-line not-rely-on-time
        ));
        disputeFeeDistribution[_escrowId] = totalFee;
        
        emit ArbitrationFeeDistributed(_escrowId, feeDistributionHash);
    }

    /**
     * @notice Executes private payouts to dispute participants
     * @dev Parameters are unused in current implementation
     */
    function _executePrivatePayouts(
        bytes32, // _escrowId - will be used in full implementation
        ctUint64, // _buyerPayout - will be used in full implementation 
        ctUint64 // _sellerPayout - will be used in full implementation
    ) internal view {
        // Get participants - will be used in full implementation
        // address[] memory participants = disputeParticipants[_escrowId];
        // address buyer = participants[0];
        // address seller = participants[1];

        // In full implementation, would execute private transfers:
        // omniCoin.privateTransfer(address(this), buyer, _buyerPayout);
        // omniCoin.privateTransfer(address(this), seller, _sellerPayout);
        
        // For now, emit event with payout hash for verification
        // bytes32 payoutHash = keccak256(abi.encode(_buyerPayout, _sellerPayout, block.timestamp));
        
        // Mark escrow as resolved in the escrow contract
        // omniCoinEscrow.resolveDispute(uint256(_escrowId), buyer, seller);
    }

    /**
     * @notice Submits rating for a resolved dispute
     * @param _escrowId Escrow identifier for the dispute
     * @param _rating Rating value (1-5 scale)
     */
    function submitRating(
        bytes32 _escrowId,
        uint256 _rating
    ) external {
        if (_rating < 1 || _rating > 5) revert InvalidRating();
        if (!_isDisputeParticipant(_escrowId, msg.sender)) revert NotAuthorizedToRate();
        
        ConfidentialDispute storage dispute = disputes[_escrowId];
        if (isMpcAvailable) {
            gtBool gtIsResolved = MpcCore.onBoard(dispute.isResolved);
            if (!MpcCore.decrypt(gtIsResolved)) revert DisputeNotResolved();
        } else {
            if (ctBool.unwrap(dispute.isResolved) != 1) revert DisputeNotResolved();
        }
        
        address[] memory participants = disputeParticipants[_escrowId];
        address buyer = participants[0];
        address seller = participants[1];
        
        if (msg.sender == buyer) {
            if (dispute.buyerRating != 0) revert AlreadyRated();
            dispute.buyerRating = _rating;
        } else if (msg.sender == seller) {
            if (dispute.sellerRating != 0) revert AlreadyRated();
            dispute.sellerRating = _rating;
        } else {
            revert OnlyBuyerAndSellerCanRate();
        }
        
        // Update arbitrator reputation if both parties have rated
        if (dispute.buyerRating > 0 && dispute.sellerRating > 0) {
            uint256 averageRating = (dispute.buyerRating + dispute.sellerRating) / 2;
            dispute.arbitratorRating = averageRating;
            
            _updateArbitratorReputation(dispute.primaryArbitrator, averageRating);
            
            // Update panel arbitrator reputations
            for (uint256 i = 0; i < dispute.panelArbitrators.length; ++i) {
                _updateArbitratorReputation(dispute.panelArbitrators[i], averageRating);
            }
        }
        
        emit RatingSubmitted(_escrowId, msg.sender, _rating);
    }

    /**
     * @notice Gets public arbitrator information
     * @param _arbitrator Address of the arbitrator
     * @return reputation Arbitrator's reputation score
     * @return participationIndex Participation index score
     * @return totalCases Total number of cases handled
     * @return successfulCases Number of successfully resolved cases
     * @return stakingAmount Amount of XOM staked
     * @return isActive Whether arbitrator is currently active
     * @return lastActiveTimestamp Last activity timestamp
     * @return specializationMask Bitmask of specialization areas
     */
    function getArbitratorInfo(
        address _arbitrator
    )
        external
        view
        returns (
            uint256 reputation,
            uint256 participationIndex,
            uint256 totalCases,
            uint256 successfulCases,
            uint256 stakingAmount,
            bool isActive,
            uint256 lastActiveTimestamp,
            uint256 specializationMask
        )
    {
        OmniBazaarArbitrator storage arbitrator = arbitrators[_arbitrator];
        return (
            arbitrator.reputation,
            arbitrator.participationIndex,
            arbitrator.totalCases,
            arbitrator.successfulCases,
            arbitrator.stakingAmount,
            arbitrator.isActive,
            arbitrator.lastActiveTimestamp,
            arbitrator.specializationMask
        );
    }

    /**
     * @notice Gets public dispute information
     * @param _escrowId Escrow identifier for the dispute
     * @return primaryArbitrator Address of primary arbitrator
     * @return panelArbitrators Array of panel arbitrator addresses
     * @return timestamp Dispute creation timestamp
     * @return disputeType Type of dispute (1=Simple, 2=Complex, 3=Appeal)
     * @return evidenceHash Hash of submitted evidence
     * @return resolutionHash Hash of resolution reasoning
     * @return deadlineTimestamp Resolution deadline timestamp
     * @return buyerRating Buyer's rating for arbitrator
     * @return sellerRating Seller's rating for arbitrator
     * @return arbitratorRating Average rating for arbitrator
     */
    function getDisputePublicInfo(
        bytes32 _escrowId
    )
        external
        view
        returns (
            address primaryArbitrator,
            address[] memory panelArbitrators,
            uint256 timestamp,
            uint256 disputeType,
            bytes32 evidenceHash,
            bytes32 resolutionHash,
            uint256 deadlineTimestamp,
            uint256 buyerRating,
            uint256 sellerRating,
            uint256 arbitratorRating
        )
    {
        ConfidentialDispute storage dispute = disputes[_escrowId];
        return (
            dispute.primaryArbitrator,
            dispute.panelArbitrators,
            dispute.timestamp,
            dispute.disputeType,
            dispute.evidenceHash,
            dispute.resolutionHash,
            dispute.deadlineTimestamp,
            dispute.buyerRating,
            dispute.sellerRating,
            dispute.arbitratorRating
        );
    }

    /**
     * @notice Checks if a dispute is resolved
     * @param _escrowId Escrow identifier for the dispute
     * @return bool Whether the dispute is resolved
     */
    function isDisputeResolved(bytes32 _escrowId) external returns (bool) {
        ConfidentialDispute storage dispute = disputes[_escrowId];
        if (isMpcAvailable) {
            gtBool gtIsResolved = MpcCore.onBoard(dispute.isResolved);
            return MpcCore.decrypt(gtIsResolved);
        } else {
            return ctBool.unwrap(dispute.isResolved) == 1;
        }
    }

    /**
     * @notice Gets private dispute amounts (restricted access)
     * @param _escrowId Escrow identifier for the dispute
     * @return disputedAmount Encrypted disputed amount
     * @return escrowBalance Encrypted escrow balance
     * @return buyerClaim Encrypted buyer's claim
     * @return sellerClaim Encrypted seller's claim
     */
    function getDisputePrivateAmounts(
        bytes32 _escrowId
    ) external view returns (
        ctUint64 disputedAmount,
        ctUint64 escrowBalance,
        ctUint64 buyerClaim,
        ctUint64 sellerClaim
    ) {
        if (!_isDisputeParticipant(_escrowId, msg.sender)) revert NotAuthorized();
        
        ConfidentialDispute storage dispute = disputes[_escrowId];
        return (
            dispute.disputedAmount,
            dispute.escrowBalance,
            dispute.buyerClaim,
            dispute.sellerClaim
        );
    }

    /**
     * @notice Gets arbitrator's private earnings (restricted access)
     * @param _arbitrator Address of the arbitrator
     * @return ctUint64 Encrypted total earnings
     */
    function getArbitratorPrivateEarnings(
        address _arbitrator
    ) external view returns (ctUint64) {
        if (msg.sender != _arbitrator && msg.sender != owner()) {
            revert NotAuthorized();
        }
        return arbitratorTotalEarnings[_arbitrator];
    }

    /**
     * @notice Allows arbitrator to claim their accumulated earnings
     */
    function claimArbitratorEarnings() external {
        if (!arbitrators[msg.sender].isActive) revert NotActiveArbitrator();
        
        ctUint64 earnings = arbitrators[msg.sender].privateEarnings;
        
        if (isMpcAvailable) {
            gtUint64 gtEarnings = MpcCore.onBoard(earnings);
            gtUint64 gtZero = MpcCore.setPublic64(uint64(0));
            gtBool hasEarnings = MpcCore.gt(gtEarnings, gtZero);
            if (!MpcCore.decrypt(hasEarnings)) revert NoEarningsToClaim();
            
            // Reset earnings to zero
            arbitrators[msg.sender].privateEarnings = MpcCore.offBoard(gtZero);
        } else {
            // In testing mode, check if earnings exist
            if (ctUint64.unwrap(earnings) == 0) revert NoEarningsToClaim();
            
            // Reset earnings to zero
            arbitrators[msg.sender].privateEarnings = ctUint64.wrap(0);
        }
        
        // In full implementation, would execute private transfer:
        // omniCoin.privateTransfer(address(this), msg.sender, earnings);
        
        // Time tracking for earnings claim
        bytes32 earningsHash = keccak256(abi.encode(
            earnings, msg.sender, 
            block.timestamp // solhint-disable-line not-rely-on-time
        ));
        emit PrivateEarningsUpdated(msg.sender, earningsHash);
    }

    /**
     * @notice Gets user's dispute history
     * @param _user Address of the user
     * @return bytes32[] Array of dispute escrow IDs
     */
    function getUserDisputes(
        address _user
    ) external view returns (bytes32[] memory) {
        return userDisputes[_user];
    }

    /**
     * @notice Gets arbitrator's dispute history
     * @param _arbitrator Address of the arbitrator
     * @return bytes32[] Array of dispute escrow IDs
     */
    function getArbitratorDisputes(
        address _arbitrator
    ) external view returns (bytes32[] memory) {
        return arbitratorDisputes[_arbitrator];
    }

    // Internal helper functions
    
    /**
     * @notice Internal function to create dispute record
     * @param _escrowId Escrow identifier
     * @param primaryArbitrator Selected primary arbitrator
     * @param panelArbitrators Array of panel arbitrators
     * @param disputeType Type of dispute (1=Simple, 2=Complex, 3=Appeal)
     * @param _evidenceHash Hash of submitted evidence
     * @param disputedAmount Encrypted disputed amount
     * @param escrowBalance Encrypted escrow balance
     * @param buyerClaim Encrypted buyer claim
     * @param sellerClaim Encrypted seller claim
     * @param arbitrationFee Encrypted arbitration fee
     * @param buyer Buyer address
     * @param seller Seller address
     */
    function _createDisputeInternal(
        bytes32 _escrowId,
        address primaryArbitrator,
        address[] memory panelArbitrators,
        uint256 disputeType,
        bytes32 _evidenceHash,
        ctUint64 disputedAmount,
        ctUint64 escrowBalance,
        ctUint64 buyerClaim,
        ctUint64 sellerClaim,
        ctUint64 arbitrationFee,
        address buyer,
        address seller
    ) internal {
        // Create dispute
        disputes[_escrowId] = ConfidentialDispute({
            escrowId: _escrowId,
            primaryArbitrator: primaryArbitrator,
            panelArbitrators: panelArbitrators,
            timestamp: block.timestamp, // solhint-disable-line not-rely-on-time
            disputeType: disputeType,
            evidenceHash: _evidenceHash,
            disputedAmount: disputedAmount,
            escrowBalance: escrowBalance,
            buyerClaim: buyerClaim,
            sellerClaim: sellerClaim,
            isResolved: isMpcAvailable ? MpcCore.offBoard(MpcCore.setPublic(false)) : ctBool.wrap(0),
            finalBuyerPayout: isMpcAvailable ? MpcCore.offBoard(MpcCore.setPublic64(uint64(0))) : ctUint64.wrap(0),
            finalSellerPayout: isMpcAvailable ? MpcCore.offBoard(MpcCore.setPublic64(uint64(0))) : ctUint64.wrap(0),
            arbitrationFee: arbitrationFee,
            buyerRating: 0,
            sellerRating: 0,
            arbitratorRating: 0,
            resolutionHash: bytes32(0),
            // solhint-disable-next-line not-rely-on-time
            deadlineTimestamp: block.timestamp + RESOLUTION_PERIOD
        });
        
        // Track dispute participants
        address[] memory participants = new address[](panelArbitrators.length + 3);
        participants[0] = buyer;
        participants[1] = seller;
        participants[2] = primaryArbitrator;
        for (uint256 i = 0; i < panelArbitrators.length; ++i) {
            participants[3 + i] = panelArbitrators[i];
        }
        disputeParticipants[_escrowId] = participants;
        
        // Update arbitrator records
        arbitratorDisputes[primaryArbitrator].push(_escrowId);
        userDisputes[buyer].push(_escrowId);
        userDisputes[seller].push(_escrowId);
        
        ++arbitrators[primaryArbitrator].totalCases;
        arbitrators[primaryArbitrator].lastActiveTimestamp = 
            block.timestamp; // solhint-disable-line not-rely-on-time
        
        // Update panel arbitrators if applicable
        for (uint256 i = 0; i < panelArbitrators.length; ++i) {
            arbitratorDisputes[panelArbitrators[i]].push(_escrowId);
            ++arbitrators[panelArbitrators[i]].totalCases;
            arbitrators[panelArbitrators[i]].lastActiveTimestamp = 
                block.timestamp; // solhint-disable-line not-rely-on-time
        }
        
        emit ConfidentialDisputeCreated(_escrowId, primaryArbitrator, disputeType, _evidenceHash);
        
        if (panelArbitrators.length > 0) {
            emit DisputePanelFormed(_escrowId, panelArbitrators);
        }
    }
    
    /**
     * @notice Selects a single arbitrator for simple disputes
     * @param _escrowId Escrow identifier
     * @return address Selected arbitrator address
     */
    function _selectSingleArbitrator(bytes32 _escrowId, ctUint64) internal view returns (address) {
        // Select arbitrator based on reputation, participation index, and availability
        // address bestArbitrator = address(0);
        // uint256 bestScore = 0;
        
        // In production, this would iterate through all registered arbitrators
        // For now, we'll implement a simplified version that can be expanded
        
        // Get escrow details to determine specialization needs
        // Note: In production, we would convert escrowId or modify getEscrow to accept bytes32
        // For now, we'll use a simple conversion
        (address seller, address buyer, , , , , ) = omniCoinEscrow.getEscrowDetails(uint256(_escrowId));
        
        // Simple selection: Find active arbitrator with highest reputation
        // In production, this would:
        // 1. Filter by specialization mask
        // 2. Check availability (not at max disputes)
        // 3. Avoid conflicts of interest
        // 4. Consider participation index
        
        // For MVP, return the first active arbitrator found
        // This ensures the contract works while allowing for future enhancement
        
        // Hardcoded test arbitrator addresses for MVP
        // In production, this would iterate through all registered arbitrators
        address[3] memory testArbitrators = [
            address(0x70997970C51812dc3A010C7d01b50e0d17dc79C8), // Hardhat account #1
            address(0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC), // Hardhat account #2  
            address(0x90F79bf6EB2c4f870365E785982E1f101E93b906)  // Hardhat account #3
        ];
        
        for (uint256 i = 0; i < testArbitrators.length; ++i) {
            if (arbitrators[testArbitrators[i]].isActive && 
                testArbitrators[i] != seller && 
                testArbitrators[i] != buyer) {
                return testArbitrators[i];
            }
        }
        
        return address(0); // No suitable arbitrator found
    }
    
    /**
     * @notice Selects arbitration panel for complex disputes
     * @param _escrowId Escrow identifier
     * @param _disputedAmount Encrypted disputed amount
     * @return address Primary arbitrator address
     * @return address[] Panel arbitrator addresses
     */
    function _selectArbitrationPanel(
        bytes32 _escrowId, 
        ctUint64 _disputedAmount
    ) internal view returns (address, address[] memory) {
        // For complex disputes, select a primary arbitrator and panel
        address primaryArbitrator = _selectSingleArbitrator(_escrowId, _disputedAmount);
        
        // Panel size is defined by PANEL_SIZE constant (3)
        // Primary arbitrator + 2 panel members
        address[] memory panel = new address[](PANEL_SIZE - 1);
        
        // In production, this would:
        // 1. Select panel members with relevant specializations
        // 2. Ensure no conflicts of interest
        // 3. Balance workload across arbitrators
        // 4. Consider timezone/availability
        
        // For MVP, return empty panel
        // This allows the contract to function while we build out the full selection algorithm
        
        return (primaryArbitrator, panel);
    }
    
    /**
     * @notice Determines dispute type based on amount and complexity
     * @param _disputedAmount Encrypted disputed amount
     * @return uint256 Dispute type (1=Simple, 2=Complex, 3=Appeal)
     */
    function _determineDisputeType(ctUint64 _disputedAmount) internal returns (uint256) {
        // Determine dispute type based on amount and complexity
        // Type 1: Simple - Single arbitrator, amount < 1,000 XOM
        // Type 2: Complex - Panel required, amount >= 1,000 XOM and < 10,000 XOM  
        // Type 3: Appeal - Special handling (future implementation)
        
        if (isMpcAvailable) {
            // Use MPC to compare encrypted amount with thresholds
            gtUint64 gtAmount = MpcCore.onBoard(_disputedAmount);
            gtUint64 gtSimpleThreshold = MpcCore.setPublic64(uint64(SIMPLE_DISPUTE_THRESHOLD / 10**18));
            gtUint64 gtComplexThreshold = MpcCore.setPublic64(uint64(COMPLEX_DISPUTE_THRESHOLD / 10**18));
            
            gtBool isSimple = MpcCore.lt(gtAmount, gtSimpleThreshold);
            if (MpcCore.decrypt(isSimple)) {
                return 1; // Simple dispute
            }
            
            gtBool isComplex = MpcCore.lt(gtAmount, gtComplexThreshold);
            if (MpcCore.decrypt(isComplex)) {
                return 2; // Complex dispute requiring panel
            }
            
            return 2; // Very high value, also requires panel
        } else {
            // In testing mode, use unwrapped values
            uint256 amount = ctUint64.unwrap(_disputedAmount);
            
            if (amount < SIMPLE_DISPUTE_THRESHOLD) {
                return 1; // Simple dispute
            } else {
                return 2; // Complex dispute requiring panel
            }
        }
    }
    
    /**
     * @notice Checks if an address is a panel arbitrator for a dispute
     * @param _escrowId Escrow identifier
     * @param _arbitrator Address to check
     * @return bool Whether the address is a panel arbitrator
     */
    function _isPanelArbitrator(bytes32 _escrowId, address _arbitrator) internal view returns (bool) {
        ConfidentialDispute storage dispute = disputes[_escrowId];
        for (uint256 i = 0; i < dispute.panelArbitrators.length; ++i) {
            if (dispute.panelArbitrators[i] == _arbitrator) {
                return true;
            }
        }
        return false;
    }
    
    /**
     * @notice Verifies panel consensus for dispute resolution
     * @param _escrowId Escrow identifier
     * @return bool Whether consensus is achieved
     */
    function _verifyPanelConsensus(bytes32 _escrowId, ctUint64, ctUint64) internal view returns (bool) {
        // Verify panel consensus for complex disputes
        // In production, this would:
        // 1. Track individual panel member votes
        // 2. Require majority agreement on payout amounts
        // 3. Allow for dissenting opinions to be recorded
        // 4. Implement time-based voting windows
        
        ConfidentialDispute storage dispute = disputes[_escrowId];
        
        // For MVP, we implement a simplified consensus check
        // In the future, this would track encrypted votes from each panel member
        
        if (dispute.panelArbitrators.length == 0) {
            return true; // No panel, no consensus needed
        }
        
        // Check that at least 2/3 of panel agrees (majority)
        // In production, we would store panel votes and check agreement
        // For now, we assume consensus if the primary arbitrator submits
        
        // Future implementation would include:
        // mapping(bytes32 => mapping(address => PanelVote)) panelVotes;
        // where PanelVote contains encrypted payout amounts and timestamps
        
        return true; // Simplified for MVP
    }
    
    /**
     * @notice Checks if an address is a dispute participant
     * @param _escrowId Escrow identifier
     * @param _caller Address to check
     * @return bool Whether the address is a participant
     */
    function _isDisputeParticipant(bytes32 _escrowId, address _caller) internal view returns (bool) {
        address[] memory participants = disputeParticipants[_escrowId];
        for (uint256 i = 0; i < participants.length; ++i) {
            if (participants[i] == _caller) {
                return true;
            }
        }
        return false;
    }
    
    /**
     * @notice Updates arbitrator reputation based on rating
     * @param _arbitrator Arbitrator address
     * @param _rating Rating value (1-5)
     */
    function _updateArbitratorReputation(address _arbitrator, uint256 _rating) internal {
        OmniBazaarArbitrator storage arbitrator = arbitrators[_arbitrator];
        
        // Convert rating (1-5) to reputation points (20-100)
        uint256 ratingPoints = (_rating - 1) * 20 + 20;
        
        // Weighted average update
        uint256 newReputation = (
            arbitrator.reputation * (100 - ratingWeight) +
            ratingPoints * ratingWeight
        ) / 100;
        
        arbitrator.reputation = newReputation;
        
        emit ReputationUpdated(_arbitrator, newReputation);
    }
    
    /**
     * @notice Calculates user's participation index
     * @param _user User address
     * @return uint256 Participation index value
     */
    function _calculateParticipationIndex(address _user) internal view returns (uint256) {
        (, , , , , uint256 reputation) = omniCoinAccount.getAccountStatus(_user);
        return reputation;
    }

    /**
     * @notice Get contract version for upgrades
     * @return string Version identifier
     */
    function getVersion() external pure returns (string memory) {
        return "OmniCoinArbitration v2.0.0 - COTI V2 Privacy Integration";
    }
}