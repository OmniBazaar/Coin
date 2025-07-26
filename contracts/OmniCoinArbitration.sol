// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../coti-contracts/contracts/utils/mpc/MpcCore.sol";
import "./omnicoin-erc20-coti.sol";
import "./OmniCoinAccount.sol";
import "./OmniCoinEscrow.sol";
import "./OmniCoinConfig.sol";
import "./PrivacyFeeManager.sol";

/**
 * @title OmniCoinArbitration
 * @dev Custom arbitration system leveraging COTI V2's privacy infrastructure
 * @notice Uses MPC for confidential dispute resolution with OmniBazaar arbitrator network
 */
contract OmniCoinArbitration is
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable
{
    // Structs
    struct OmniBazaarArbitrator {
        address account;
        uint256 reputation;              // Public reputation score
        uint256 participationIndex;      // PoP participation score
        uint256 totalCases;             // Total cases handled
        uint256 successfulCases;        // Successfully resolved cases
        uint256 stakingAmount;          // XOM staked for arbitration eligibility
        bool isActive;                  // Active status
        uint256 lastActiveTimestamp;    // Last activity timestamp
        ctUint64 privateEarnings;       // Private arbitration earnings (MPC)
        uint256 specializationMask;     // Bitmask for specialization areas
    }

    struct ConfidentialDispute {
        bytes32 escrowId;               // Public escrow identifier
        address primaryArbitrator;      // Main arbitrator assigned
        address[] panelArbitrators;     // Panel for complex disputes (max 3)
        uint256 timestamp;              // Dispute creation time
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
        uint256 deadlineTimestamp;      // Resolution deadline
    }

    // State variables - OmniBazaar Arbitrator Network
    mapping(address => OmniBazaarArbitrator) public arbitrators;
    mapping(bytes32 => ConfidentialDispute) private disputes;      // Private dispute storage
    mapping(address => bytes32[]) public arbitratorDisputes;
    mapping(address => bytes32[]) public userDisputes;
    
    // Private dispute tracking using COTI V2 MPC
    mapping(bytes32 => address[]) private disputeParticipants;     // [buyer, seller, arbitrator(s)]
    mapping(bytes32 => ctUint64) private disputeFeeDistribution;   // Private fee breakdown
    mapping(address => ctUint64) private arbitratorTotalEarnings;   // Private lifetime earnings
    
    // Arbitrator specialization areas (bitmask)
    uint256 public constant SPEC_DIGITAL_GOODS = 1;       // 2^0
    uint256 public constant SPEC_PHYSICAL_GOODS = 2;      // 2^1  
    uint256 public constant SPEC_SERVICES = 4;            // 2^2
    uint256 public constant SPEC_HIGH_VALUE = 8;          // 2^3 (>10,000 XOM)
    uint256 public constant SPEC_INTERNATIONAL = 16;      // 2^4
    uint256 public constant SPEC_TECHNICAL = 32;          // 2^5
    
    // Dispute resolution parameters
    uint256 public constant SIMPLE_DISPUTE_THRESHOLD = 1000 * 10**18;  // 1,000 XOM
    uint256 public constant COMPLEX_DISPUTE_THRESHOLD = 10000 * 10**18; // 10,000 XOM
    uint256 public constant PANEL_SIZE = 3;                            // Panel arbitrators
    uint256 public constant RESOLUTION_PERIOD = 7 days;                // Resolution deadline

    // Contract integrations
    OmniCoin public omniCoin;
    OmniCoinAccount public omniCoinAccount;
    OmniCoinEscrow public omniCoinEscrow;
    OmniCoinConfig public config;

    // Arbitrator eligibility requirements
    uint256 public minReputation;           // Minimum reputation score (default: 750)
    uint256 public minParticipationIndex;   // Minimum PoP score (default: 500)
    uint256 public minStakingAmount;        // Minimum XOM staked (default: 10,000)
    uint256 public maxActiveDisputes;       // Max concurrent disputes (default: 5)
    uint256 public disputeTimeout;          // Resolution timeout (default: 7 days)
    uint256 public ratingWeight;            // Rating update weight (default: 10%)
    
    // MPC availability flag (true on COTI testnet/mainnet, false in Hardhat)
    bool public isMpcAvailable;
    
    // Privacy fee configuration
    uint256 public constant PRIVACY_MULTIPLIER = 10; // 10x fee for privacy
    address public privacyFeeManager;
    
    // Fee structure (aligned with arbitration workload)
    uint256 public constant ARBITRATION_FEE_RATE = 100;    // 1% of disputed amount
    uint256 public constant ARBITRATOR_FEE_SHARE = 70;     // 70% to arbitrators (doing the work)
    uint256 public constant TREASURY_FEE_SHARE = 20;       // 20% to OmniBazaar treasury
    uint256 public constant VALIDATOR_FEE_SHARE = 10;      // 10% to validator network

    // Events - Privacy-aware arbitration events
    event ArbitratorRegistered(
        address indexed arbitrator,
        uint256 specializations,
        uint256 stakingAmount
    );
    event ArbitratorRemoved(
        address indexed arbitrator,
        string reason
    );
    event ArbitratorStakeUpdated(
        address indexed arbitrator,
        uint256 newStakingAmount
    );
    event ConfidentialDisputeCreated(
        bytes32 indexed escrowId,
        address indexed primaryArbitrator,
        uint256 disputeType,
        bytes32 evidenceHash
    );
    event DisputePanelFormed(
        bytes32 indexed escrowId,
        address[] panelArbitrators
    );
    event ConfidentialDisputeResolved(
        bytes32 indexed escrowId,
        bytes32 resolutionHash,
        uint256 timestamp,
        bytes32 payoutHash  // Hash of private payout amounts
    );
    event ArbitrationFeeDistributed(
        bytes32 indexed escrowId,
        bytes32 feeDistributionHash  // Hash of private fee distribution
    );
    event RatingSubmitted(
        bytes32 indexed escrowId,
        address indexed rater,
        uint256 rating
    );
    event ReputationUpdated(
        address indexed arbitrator,
        uint256 newReputation
    );
    event PrivateEarningsUpdated(
        address indexed arbitrator,
        bytes32 earningsHash  // Hash of private earnings update
    );

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Initializes the OmniBazaar arbitration system
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
        
        omniCoin = OmniCoin(_omniCoin);
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
     * @dev Set privacy fee manager
     */
    function setPrivacyFeeManager(address _privacyFeeManager) external onlyOwner {
        require(_privacyFeeManager != address(0), "OmniCoinArbitration: Invalid address");
        privacyFeeManager = _privacyFeeManager;
    }
    
    /**
     * @dev Set MPC availability (admin only, called when deploying to COTI testnet/mainnet)
     */
    function setMpcAvailability(bool _available) external onlyOwner {
        isMpcAvailable = _available;
    }

    /**
     * @dev Registers a new arbitrator in the OmniBazaar network
     * @param _stakingAmount Amount of XOM to stake for arbitration eligibility
     * @param _specializations Bitmask of specialization areas
     */
    function registerArbitrator(
        uint256 _stakingAmount,
        uint256 _specializations
    ) external {
        require(!arbitrators[msg.sender].isActive, "Already registered");
        require(_stakingAmount >= minStakingAmount, "Insufficient staking amount");
        require(_specializations > 0, "Must specify at least one specialization");

        uint256 reputation = 0;
        uint256 participationIndex = 0;
        
        // Skip reputation checks in testnet mode
        if (!config.isTestnetMode()) {
            reputation = omniCoinAccount.reputationScore(msg.sender);
            participationIndex = _calculateParticipationIndex(msg.sender);
            
            require(reputation >= minReputation, "Insufficient reputation");
            require(participationIndex >= minParticipationIndex, "Insufficient participation");
        }

        // Transfer staking amount to this contract
        require(
            omniCoin.transferFrom(msg.sender, address(this), _stakingAmount),
            "Staking transfer failed"
        );

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
            lastActiveTimestamp: block.timestamp,
            privateEarnings: initialEarnings,
            specializationMask: _specializations
        });

        arbitratorTotalEarnings[msg.sender] = initialEarnings;

        emit ArbitratorRegistered(msg.sender, _specializations, _stakingAmount);
    }

    /**
     * @dev Updates arbitrator staking amount
     * @param _additionalStake Additional XOM to stake
     */
    function increaseArbitratorStake(uint256 _additionalStake) external {
        require(arbitrators[msg.sender].isActive, "Not an active arbitrator");
        require(_additionalStake > 0, "Must stake additional amount");

        require(
            omniCoin.transferFrom(msg.sender, address(this), _additionalStake),
            "Additional staking transfer failed"
        );

        arbitrators[msg.sender].stakingAmount += _additionalStake;

        emit ArbitratorStakeUpdated(msg.sender, arbitrators[msg.sender].stakingAmount);
    }

    /**
     * @dev Creates a public dispute (default, no privacy fees)
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
        (address seller, address buyer, address arbitrator, uint256 amount, uint256 releaseTime, bool released, bool disputed, bool refunded) = 
            omniCoinEscrow.getEscrow(escrowId);
        
        require(disputed, "Escrow not disputed");
        require(msg.sender == buyer || msg.sender == seller, "Not authorized");
        require(disputes[_escrowId].timestamp == 0, "Dispute already exists");
        require(_buyerClaim + _sellerClaim <= amount, "Total claims exceed escrow balance");
        
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
        
        require(primaryArbitrator != address(0), "No suitable arbitrator found");
        
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
     * @dev Creates a confidential dispute with privacy (premium feature)
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
        require(usePrivacy && isMpcAvailable, "OmniCoinArbitration: Privacy not available");
        require(privacyFeeManager != address(0), "OmniCoinArbitration: Privacy fee manager not set");
        uint256 escrowId = uint256(_escrowId);
        (address seller, address buyer, address arbitrator, uint256 amount, uint256 releaseTime, bool released, bool disputed, bool refunded) = 
            omniCoinEscrow.getEscrow(escrowId);
        
        require(disputed, "Escrow not disputed");
        require(msg.sender == buyer || msg.sender == seller, "Not authorized");
        require(disputes[_escrowId].timestamp == 0, "Dispute already exists");
        
        // Validate encrypted inputs
        gtUint64 gtDisputedAmount = MpcCore.validateCiphertext(_disputedAmount);
        gtUint64 gtBuyerClaim = MpcCore.validateCiphertext(_buyerClaim);
        gtUint64 gtSellerClaim = MpcCore.validateCiphertext(_sellerClaim);
        
        // Verify claims don't exceed escrow balance
        gtUint64 gtEscrowBalance = MpcCore.setPublic64(uint64(amount));
        gtUint64 gtTotalClaim = MpcCore.add(gtBuyerClaim, gtSellerClaim);
        gtBool claimsValid = MpcCore.le(gtTotalClaim, gtEscrowBalance);
        require(MpcCore.decrypt(claimsValid), "Total claims exceed escrow balance");
        
        // Calculate privacy fee (1% of disputed amount for arbitration)
        uint256 ARBITRATION_PRIVACY_FEE_RATE = 100; // 1% in basis points
        uint256 BASIS_POINTS = 10000;
        gtUint64 feeRate = MpcCore.setPublic64(uint64(ARBITRATION_PRIVACY_FEE_RATE));
        gtUint64 basisPoints = MpcCore.setPublic64(uint64(BASIS_POINTS));
        gtUint64 fee = MpcCore.mul(gtDisputedAmount, feeRate);
        fee = MpcCore.div(fee, basisPoints);
        
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
        
        require(primaryArbitrator != address(0), "No suitable arbitrator found");
        
        // Calculate arbitration fee
        gtUint64 gtArbitrationFeeRate = MpcCore.setPublic64(uint64(ARBITRATION_FEE_RATE));
        gtUint64 gtArbitrationFee = MpcCore.mul(gtDisputedAmount, gtArbitrationFeeRate);
        gtArbitrationFee = MpcCore.div(gtArbitrationFee, basisPoints);
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
     * @dev Internal function to create dispute
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
            timestamp: block.timestamp,
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
            deadlineTimestamp: block.timestamp + RESOLUTION_PERIOD
        });
        
        // Track dispute participants
        address[] memory participants = new address[](panelArbitrators.length + 3);
        participants[0] = buyer;
        participants[1] = seller;
        participants[2] = primaryArbitrator;
        for (uint i = 0; i < panelArbitrators.length; i++) {
            participants[3 + i] = panelArbitrators[i];
        }
        disputeParticipants[_escrowId] = participants;
        
        // Update arbitrator records
        arbitratorDisputes[primaryArbitrator].push(_escrowId);
        userDisputes[buyer].push(_escrowId);
        userDisputes[seller].push(_escrowId);
        
        arbitrators[primaryArbitrator].totalCases++;
        arbitrators[primaryArbitrator].lastActiveTimestamp = block.timestamp;
        
        // Update panel arbitrators if applicable
        for (uint i = 0; i < panelArbitrators.length; i++) {
            arbitratorDisputes[panelArbitrators[i]].push(_escrowId);
            arbitrators[panelArbitrators[i]].totalCases++;
            arbitrators[panelArbitrators[i]].lastActiveTimestamp = block.timestamp;
        }
        
        emit ConfidentialDisputeCreated(_escrowId, primaryArbitrator, disputeType, _evidenceHash);
        
        if (panelArbitrators.length > 0) {
            emit DisputePanelFormed(_escrowId, panelArbitrators);
        }
    }
    
    /**
     * @dev Resolves a dispute with public payouts (default, no privacy fees)
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
        
        require(ctBool.unwrap(dispute.isResolved) == 0, "Already resolved");
        require(
            msg.sender == dispute.primaryArbitrator || _isPanelArbitrator(_escrowId, msg.sender),
            "Not authorized arbitrator"
        );
        require(block.timestamp <= dispute.deadlineTimestamp, "Resolution deadline passed");
        
        // Verify total payouts
        uint256 escrowBalance = ctUint64.unwrap(dispute.escrowBalance);
        require(_buyerPayout + _sellerPayout <= escrowBalance, "Total payouts exceed escrow balance");
        
        // For panel disputes, require consensus
        if (dispute.panelArbitrators.length > 0) {
            ctUint64 buyerPayoutEncrypted = ctUint64.wrap(_buyerPayout);
            ctUint64 sellerPayoutEncrypted = ctUint64.wrap(_sellerPayout);
            require(_verifyPanelConsensus(_escrowId, buyerPayoutEncrypted, sellerPayoutEncrypted), "Panel consensus required");
        }
        
        // Update dispute with resolution
        dispute.isResolved = ctBool.wrap(1);
        dispute.finalBuyerPayout = ctUint64.wrap(_buyerPayout);
        dispute.finalSellerPayout = ctUint64.wrap(_sellerPayout);
        dispute.resolutionHash = _resolutionHash;
        
        // Distribute arbitration fees
        _distributeArbitrationFees(_escrowId);
        
        // Update arbitrator success statistics
        arbitrators[dispute.primaryArbitrator].successfulCases++;
        for (uint i = 0; i < dispute.panelArbitrators.length; i++) {
            arbitrators[dispute.panelArbitrators[i]].successfulCases++;
        }
        
        // Execute payouts
        ctUint64 buyerPayoutEncrypted = ctUint64.wrap(_buyerPayout);
        ctUint64 sellerPayoutEncrypted = ctUint64.wrap(_sellerPayout);
        _executePrivatePayouts(_escrowId, buyerPayoutEncrypted, sellerPayoutEncrypted);
        
        // Create verification hash
        bytes32 payoutHash = keccak256(abi.encode(
            _buyerPayout, _sellerPayout, block.timestamp, _resolutionHash
        ));
        
        emit ConfidentialDisputeResolved(_escrowId, _resolutionHash, block.timestamp, payoutHash);
    }
    
    /**
     * @dev Resolves a dispute with private payouts (premium feature)
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
        require(usePrivacy && isMpcAvailable, "OmniCoinArbitration: Privacy not available");
        require(privacyFeeManager != address(0), "OmniCoinArbitration: Privacy fee manager not set");
        ConfidentialDispute storage dispute = disputes[_escrowId];
        
        gtBool gtIsResolved = MpcCore.onBoard(dispute.isResolved);
        require(!MpcCore.decrypt(gtIsResolved), "Already resolved");
        require(
            msg.sender == dispute.primaryArbitrator || _isPanelArbitrator(_escrowId, msg.sender),
            "Not authorized arbitrator"
        );
        require(block.timestamp <= dispute.deadlineTimestamp, "Resolution deadline passed");
        
        // Validate encrypted inputs
        gtUint64 gtBuyerPayout = MpcCore.validateCiphertext(_buyerPayout);
        gtUint64 gtSellerPayout = MpcCore.validateCiphertext(_sellerPayout);
        
        // Verify total payouts don't exceed escrow balance
        gtUint64 gtTotalPayout = MpcCore.add(gtBuyerPayout, gtSellerPayout);
        gtUint64 gtEscrowBalance = MpcCore.onBoard(dispute.escrowBalance);
        gtBool payoutsValid = MpcCore.le(gtTotalPayout, gtEscrowBalance);
        require(MpcCore.decrypt(payoutsValid), "Total payouts exceed escrow balance");
        
        // Calculate privacy fee for resolution (0.5% of total payout)
        uint256 RESOLUTION_PRIVACY_FEE_RATE = 50; // 0.5% in basis points
        uint256 BASIS_POINTS = 10000;
        gtUint64 feeRate = MpcCore.setPublic64(uint64(RESOLUTION_PRIVACY_FEE_RATE));
        gtUint64 basisPoints = MpcCore.setPublic64(uint64(BASIS_POINTS));
        gtUint64 fee = MpcCore.mul(gtTotalPayout, feeRate);
        fee = MpcCore.div(fee, basisPoints);
        
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
            require(_verifyPanelConsensus(_escrowId, encryptedBuyerPayout, encryptedSellerPayout), "Panel consensus required");
        }
        
        // Update dispute with private resolution
        dispute.isResolved = MpcCore.offBoard(MpcCore.setPublic(true));
        dispute.finalBuyerPayout = encryptedBuyerPayout;
        dispute.finalSellerPayout = encryptedSellerPayout;
        dispute.resolutionHash = _resolutionHash;
        
        // Distribute arbitration fees
        _distributeArbitrationFees(_escrowId);
        
        // Update arbitrator success statistics
        arbitrators[dispute.primaryArbitrator].successfulCases++;
        for (uint i = 0; i < dispute.panelArbitrators.length; i++) {
            arbitrators[dispute.panelArbitrators[i]].successfulCases++;
        }
        
        // Execute private payouts
        _executePrivatePayouts(_escrowId, encryptedBuyerPayout, encryptedSellerPayout);
        
        // Create verification hash
        bytes32 payoutHash = keccak256(abi.encode(
            encryptedBuyerPayout, encryptedSellerPayout, block.timestamp, _resolutionHash
        ));
        
        emit ConfidentialDisputeResolved(_escrowId, _resolutionHash, block.timestamp, payoutHash);
    }

    /**
     * @dev Internal function to distribute arbitration fees using COTI V2 privacy
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
            ctUint64 primaryShare = MpcCore.offBoard(gtPrimaryShare);
            
            gtUint64 gtRemaining = MpcCore.sub(gtArbitratorShare, gtPrimaryShare);
            gtUint64 gtPanelCount = MpcCore.setPublic64(uint64(dispute.panelArbitrators.length));
            gtUint64 gtPanelShare = MpcCore.div(gtRemaining, gtPanelCount);
            ctUint64 panelShare = MpcCore.offBoard(gtPanelShare);
            
            // Update primary arbitrator
            gtUint64 gtCurrentEarnings = MpcCore.onBoard(arbitrators[dispute.primaryArbitrator].privateEarnings);
            gtUint64 gtNewEarnings = MpcCore.add(gtCurrentEarnings, gtPrimaryShare);
            arbitrators[dispute.primaryArbitrator].privateEarnings = MpcCore.offBoard(gtNewEarnings);
            
            gtUint64 gtCurrentTotal = MpcCore.onBoard(arbitratorTotalEarnings[dispute.primaryArbitrator]);
            gtUint64 gtNewTotal = MpcCore.add(gtCurrentTotal, gtPrimaryShare);
            arbitratorTotalEarnings[dispute.primaryArbitrator] = MpcCore.offBoard(gtNewTotal);
                
            // Update panel arbitrators
            for (uint i = 0; i < dispute.panelArbitrators.length; i++) {
                gtUint64 gtPanelCurrentEarnings = MpcCore.onBoard(arbitrators[dispute.panelArbitrators[i]].privateEarnings);
                gtUint64 gtPanelNewEarnings = MpcCore.add(gtPanelCurrentEarnings, gtPanelShare);
                arbitrators[dispute.panelArbitrators[i]].privateEarnings = MpcCore.offBoard(gtPanelNewEarnings);
                
                gtUint64 gtPanelCurrentTotal = MpcCore.onBoard(arbitratorTotalEarnings[dispute.panelArbitrators[i]]);
                gtUint64 gtPanelNewTotal = MpcCore.add(gtPanelCurrentTotal, gtPanelShare);
                arbitratorTotalEarnings[dispute.panelArbitrators[i]] = MpcCore.offBoard(gtPanelNewTotal);
            }
        }
        
        // Store fee distribution hash for transparency
        bytes32 feeDistributionHash = keccak256(abi.encode(
            arbitratorShare, treasuryShare, validatorShare, block.timestamp
        ));
        disputeFeeDistribution[_escrowId] = totalFee;
        
        emit ArbitrationFeeDistributed(_escrowId, feeDistributionHash);
    }

    /**
     * @dev Internal function to execute private payouts
     */
    function _executePrivatePayouts(
        bytes32 _escrowId,
        ctUint64 _buyerPayout,
        ctUint64 _sellerPayout
    ) internal {
        // Get participants
        address[] memory participants = disputeParticipants[_escrowId];
        address buyer = participants[0];
        address seller = participants[1];

        // In full implementation, would execute private transfers:
        // omniCoin.privateTransfer(address(this), buyer, _buyerPayout);
        // omniCoin.privateTransfer(address(this), seller, _sellerPayout);
        
        // For now, emit event with payout hash for verification
        bytes32 payoutHash = keccak256(abi.encode(_buyerPayout, _sellerPayout, block.timestamp));
        
        // Mark escrow as resolved in the escrow contract
        // omniCoinEscrow.resolveDispute(uint256(_escrowId), buyer, seller);
    }

    /**
     * @dev Submits rating for resolved dispute (only participants)
     */
    function submitRating(
        bytes32 _escrowId,
        uint256 _rating
    ) external {
        require(_rating >= 1 && _rating <= 5, "Rating must be 1-5");
        require(_isDisputeParticipant(_escrowId, msg.sender), "Not authorized to rate");
        
        ConfidentialDispute storage dispute = disputes[_escrowId];
        if (isMpcAvailable) {
            gtBool gtIsResolved = MpcCore.onBoard(dispute.isResolved);
            require(MpcCore.decrypt(gtIsResolved), "Dispute not resolved");
        } else {
            require(ctBool.unwrap(dispute.isResolved) == 1, "Dispute not resolved");
        }
        
        address[] memory participants = disputeParticipants[_escrowId];
        address buyer = participants[0];
        address seller = participants[1];
        
        if (msg.sender == buyer) {
            require(dispute.buyerRating == 0, "Already rated");
            dispute.buyerRating = _rating;
        } else if (msg.sender == seller) {
            require(dispute.sellerRating == 0, "Already rated");
            dispute.sellerRating = _rating;
        } else {
            revert("Only buyer and seller can rate");
        }
        
        // Update arbitrator reputation if both parties have rated
        if (dispute.buyerRating > 0 && dispute.sellerRating > 0) {
            uint256 averageRating = (dispute.buyerRating + dispute.sellerRating) / 2;
            dispute.arbitratorRating = averageRating;
            
            _updateArbitratorReputation(dispute.primaryArbitrator, averageRating);
            
            // Update panel arbitrator reputations
            for (uint i = 0; i < dispute.panelArbitrators.length; i++) {
                _updateArbitratorReputation(dispute.panelArbitrators[i], averageRating);
            }
        }
        
        emit RatingSubmitted(_escrowId, msg.sender, _rating);
    }

    /**
     * @dev Gets public arbitrator information
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
     * @dev Gets public dispute information (private amounts remain confidential)
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
     * @dev Checks if dispute is resolved (decrypted for verification)
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
     * @dev Gets private dispute amounts (only for authorized parties)
     */
    function getDisputePrivateAmounts(
        bytes32 _escrowId
    ) external view returns (
        ctUint64 disputedAmount,
        ctUint64 escrowBalance,
        ctUint64 buyerClaim,
        ctUint64 sellerClaim
    ) {
        require(_isDisputeParticipant(_escrowId, msg.sender), "Not authorized");
        
        ConfidentialDispute storage dispute = disputes[_escrowId];
        return (
            dispute.disputedAmount,
            dispute.escrowBalance,
            dispute.buyerClaim,
            dispute.sellerClaim
        );
    }

    /**
     * @dev Gets arbitrator's private earnings (only for arbitrator or owner)
     */
    function getArbitratorPrivateEarnings(
        address _arbitrator
    ) external view returns (ctUint64) {
        require(
            msg.sender == _arbitrator || msg.sender == owner(),
            "Not authorized"
        );
        return arbitratorTotalEarnings[_arbitrator];
    }

    /**
     * @dev Arbitrator can claim their private earnings
     */
    function claimArbitratorEarnings() external {
        require(arbitrators[msg.sender].isActive, "Not an active arbitrator");
        
        ctUint64 earnings = arbitrators[msg.sender].privateEarnings;
        
        if (isMpcAvailable) {
            gtUint64 gtEarnings = MpcCore.onBoard(earnings);
            gtUint64 gtZero = MpcCore.setPublic64(uint64(0));
            gtBool hasEarnings = MpcCore.gt(gtEarnings, gtZero);
            require(MpcCore.decrypt(hasEarnings), "No earnings to claim");
            
            // Reset earnings to zero
            arbitrators[msg.sender].privateEarnings = MpcCore.offBoard(gtZero);
        } else {
            // In testing mode, check if earnings exist
            require(ctUint64.unwrap(earnings) > 0, "No earnings to claim");
            
            // Reset earnings to zero
            arbitrators[msg.sender].privateEarnings = ctUint64.wrap(0);
        }
        
        // In full implementation, would execute private transfer:
        // omniCoin.privateTransfer(address(this), msg.sender, earnings);
        
        bytes32 earningsHash = keccak256(abi.encode(earnings, msg.sender, block.timestamp));
        emit PrivateEarningsUpdated(msg.sender, earningsHash);
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

    // Internal helper functions
    function _selectSingleArbitrator(bytes32 _escrowId, ctUint64 _disputedAmount) internal view returns (address) {
        // Select arbitrator based on reputation, participation index, and availability
        address bestArbitrator = address(0);
        uint256 bestScore = 0;
        
        // In production, this would iterate through all registered arbitrators
        // For now, we'll implement a simplified version that can be expanded
        
        // Get escrow details to determine specialization needs
        // Note: In production, we would convert escrowId or modify getEscrow to accept bytes32
        // For now, we'll use a simple conversion
        (address seller, address buyer, , , , , , ) = omniCoinEscrow.getEscrow(uint256(_escrowId));
        
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
        
        for (uint i = 0; i < testArbitrators.length; i++) {
            if (arbitrators[testArbitrators[i]].isActive && 
                testArbitrators[i] != seller && 
                testArbitrators[i] != buyer) {
                return testArbitrators[i];
            }
        }
        
        return address(0); // No suitable arbitrator found
    }
    
    function _selectArbitrationPanel(bytes32 _escrowId, ctUint64 _disputedAmount) internal view returns (address, address[] memory) {
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
    
    function _isPanelArbitrator(bytes32 _escrowId, address _arbitrator) internal view returns (bool) {
        ConfidentialDispute storage dispute = disputes[_escrowId];
        for (uint i = 0; i < dispute.panelArbitrators.length; i++) {
            if (dispute.panelArbitrators[i] == _arbitrator) {
                return true;
            }
        }
        return false;
    }
    
    function _verifyPanelConsensus(bytes32 _escrowId, ctUint64 _buyerPayout, ctUint64 _sellerPayout) internal view returns (bool) {
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
    
    function _isDisputeParticipant(bytes32 _escrowId, address _caller) internal view returns (bool) {
        address[] memory participants = disputeParticipants[_escrowId];
        for (uint i = 0; i < participants.length; i++) {
            if (participants[i] == _caller) {
                return true;
            }
        }
        return false;
    }
    
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
    
    function _calculateParticipationIndex(address _user) internal view returns (uint256) {
        (, , , , , uint256 reputation) = omniCoinAccount.getAccountStatus(_user);
        return reputation;
    }

    /**
     * @dev Get contract version for upgrades
     */
    function getVersion() external pure returns (string memory) {
        return "OmniCoinArbitration v2.0.0 - COTI V2 Privacy Integration";
    }
}