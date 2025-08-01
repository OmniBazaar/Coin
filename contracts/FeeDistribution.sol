// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {RegistryAware} from "./base/RegistryAware.sol";

/**
 * @title FeeDistribution - Avalanche Validator Integrated Version
 * @author OmniCoin Development Team
 * @notice Event-based fee distribution for Avalanche validator network
 * @dev Major changes from original:
 * - Removed arrays (feeCollections) - events only
 * - Removed aggregate tracking - computed by validator
 * - Added merkle root pattern for validator rewards
 * - Simplified to pending amounts only
 * 
 * State Reduction: ~80% less storage
 * Gas Savings: ~60% on distributions
 */
contract FeeDistribution is RegistryAware, ReentrancyGuard, Pausable, AccessControl {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // =============================================================================
    // STRUCTS
    // =============================================================================
    
    struct DistributionRatio {
        uint256 validatorShare;    // 7000 = 70%
        uint256 companyShare;      // 2000 = 20%
        uint256 developmentShare;  // 1000 = 10%
    }
    
    struct TreasuryAddresses {
        address companyTreasury;
        address developmentFund;
    }

    // =============================================================================
    // CONSTANTS
    // =============================================================================
    
    /// @notice Role for contracts that can collect fees
    bytes32 public constant COLLECTOR_ROLE = keccak256("COLLECTOR_ROLE");
    /// @notice Role for triggering distributions
    bytes32 public constant DISTRIBUTOR_ROLE = keccak256("DISTRIBUTOR_ROLE");
    /// @notice Role for treasury management
    bytes32 public constant TREASURY_ROLE = keccak256("TREASURY_ROLE");
    /// @notice Role for validators
    bytes32 public constant VALIDATOR_ROLE = keccak256("VALIDATOR_ROLE");
    /// @notice Role for Avalanche validators to update merkle roots
    bytes32 public constant AVALANCHE_VALIDATOR_ROLE = keccak256("AVALANCHE_VALIDATOR_ROLE");

    // =============================================================================
    // STATE VARIABLES
    // =============================================================================
    
    // Core configuration
    /// @notice The token used for fee payments (XOM)
    IERC20 public immutable FEE_TOKEN;
    /// @notice Distribution percentages for validators, company, and development
    DistributionRatio public distributionRatio;
    /// @notice Treasury addresses for company and development funds
    TreasuryAddresses public treasuryAddresses;
    
    // Merkle roots for validator distributions
    /// @notice Current merkle root for validator reward claims
    bytes32 public currentDistributionRoot;
    /// @notice Current distribution epoch number
    uint256 public currentEpoch;
    /// @notice Block number of last distribution update
    uint256 public lastDistributionBlock;
    
    // Only track pending/unclaimed amounts
    /// @notice Tracks which epoch each validator last claimed from
    mapping(address => uint256) public claimedInEpoch;  // Track claims to prevent double-claiming
    /// @notice Pending withdrawal amounts for company treasury
    mapping(address => uint256) public companyPendingWithdrawals;
    /// @notice Pending withdrawal amounts for development fund
    mapping(address => uint256) public developmentPendingWithdrawals;
    
    // Simple configuration
    /// @notice Time interval between distributions (default: 6 hours)
    uint256 public distributionInterval = 6 hours;
    /// @notice Timestamp of last distribution
    uint256 public lastDistributionTime;
    /// @notice Minimum amount required to trigger distribution
    uint256 public minimumDistributionAmount = 1000 * 10**18;
    
    // =============================================================================
    // EVENTS - VALIDATOR COMPATIBLE
    // =============================================================================
    
    /**
     * @notice Fee collected event for validator indexing
     * @param from Address that paid the fee
     * @param feeType Type of fee collected
     * @param amount Amount of fee collected
     * @param timestamp Block timestamp of collection
     */
    event FeeCollected(
        address indexed from,
        string feeType,
        uint256 indexed amount,
        uint256 indexed timestamp
    );
    
    /**
     * @notice Distribution event with breakdown
     * @param epoch Distribution epoch number
     * @param totalAmount Total amount distributed
     * @param validatorShare Amount allocated to validators
     * @param companyShare Amount allocated to company treasury
     * @param developmentShare Amount allocated to development fund
     * @param timestamp Block timestamp of distribution
     */
    event FeeDistributed(
        uint256 indexed epoch,
        uint256 indexed totalAmount,
        uint256 indexed validatorShare,
        uint256 companyShare,
        uint256 developmentShare,
        uint256 timestamp
    );
    
    /**
     * @notice Validator claims their reward
     * @param validator Address of claiming validator
     * @param amount Amount claimed
     * @param epoch Epoch from which reward was claimed
     * @param timestamp Block timestamp of claim
     */
    event ValidatorRewardClaimed(
        address indexed validator,
        uint256 indexed amount,
        uint256 indexed epoch,
        uint256 timestamp
    );
    
    /**
     * @notice Distribution root updated by validator
     * @param newRoot New merkle root hash
     * @param epoch Epoch number for this distribution
     * @param totalValidatorRewards Total rewards in this distribution
     * @param blockNumber Block number of update
     * @param timestamp Block timestamp of update
     */
    event DistributionRootUpdated(
        bytes32 indexed newRoot,
        uint256 indexed epoch,
        uint256 indexed totalValidatorRewards,
        uint256 blockNumber,
        uint256 timestamp
    );
    
    /**
     * @notice Company treasury withdrawal
     * @param token Token address being withdrawn
     * @param amount Amount withdrawn
     * @param recipient Address receiving the withdrawal
     * @param timestamp Block timestamp of withdrawal
     */
    event CompanyFeesWithdrawn(
        address indexed token,
        uint256 indexed amount,
        address indexed recipient,
        uint256 timestamp
    );
    
    /**
     * @notice Development fund withdrawal
     * @param token Token address being withdrawn
     * @param amount Amount withdrawn
     * @param recipient Address receiving the withdrawal
     * @param timestamp Block timestamp of withdrawal
     */
    event DevelopmentFeesWithdrawn(
        address indexed token,
        uint256 indexed amount,
        address indexed recipient,
        uint256 timestamp
    );
    
    // =============================================================================
    // ERRORS
    // =============================================================================
    
    error InvalidToken();
    error InvalidAddress();
    error InvalidAmount();
    error InvalidRatios();
    error InvalidProof();
    error AlreadyClaimed();
    error EpochMismatch();
    error InsufficientBalance();
    error TransferFailed();
    error NotValidator();
    
    // =============================================================================
    // MODIFIERS
    // =============================================================================
    
    modifier onlyValidator() {
        if (!hasRole(VALIDATOR_ROLE, msg.sender) && !hasRole(AVALANCHE_VALIDATOR_ROLE, msg.sender)) {
            revert NotValidator();
        }
        _;
    }
    
    // =============================================================================
    // CONSTRUCTOR
    // =============================================================================
    
    /**
     * @notice Initialize fee distribution contract
     * @param registry_ Address of the registry contract
     * @param feeToken_ Address of the token used for fees (XOM)
     * @param companyTreasury_ Address for company treasury withdrawals
     * @param developmentFund_ Address for development fund withdrawals
     */
    constructor(
        address registry_,
        address feeToken_,
        address companyTreasury_,
        address developmentFund_
    ) RegistryAware(registry_) {
        if (feeToken_ == address(0)) revert InvalidToken();
        if (companyTreasury_ == address(0)) revert InvalidAddress();
        if (developmentFund_ == address(0)) revert InvalidAddress();

        FEE_TOKEN = IERC20(feeToken_);
        treasuryAddresses = TreasuryAddresses({
            companyTreasury: companyTreasury_,
            developmentFund: developmentFund_
        });

        // Initialize distribution ratios (70/20/10)
        distributionRatio = DistributionRatio({
            validatorShare: 7000,
            companyShare: 2000,
            developmentShare: 1000
        });

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(COLLECTOR_ROLE, msg.sender);
        _grantRole(DISTRIBUTOR_ROLE, msg.sender);
        _grantRole(TREASURY_ROLE, msg.sender);

        lastDistributionTime = block.timestamp; // solhint-disable-line not-rely-on-time
    }
    
    // =============================================================================
    // FEE COLLECTION - EMIT EVENTS ONLY
    // =============================================================================
    
    /**
     * @notice Collect fees from various sources
     * @dev Emits event for validator indexing, no storage
     * @param feeType Type of fee being collected (e.g., "trading", "listing")
     * @param amount Amount of fee tokens to collect
     */
    function collectFees(
        string calldata feeType,
        uint256 amount
    ) external nonReentrant whenNotPaused onlyRole(COLLECTOR_ROLE) {
        if (amount == 0) revert InvalidAmount();
        
        // Transfer tokens to this contract
        FEE_TOKEN.safeTransferFrom(msg.sender, address(this), amount);
        
        // Emit event for validator indexing
        emit FeeCollected(
            msg.sender,
            feeType,
            amount,
            block.timestamp // solhint-disable-line not-rely-on-time
        );
    }
    
    /**
     * @notice Batch collect fees from multiple sources
     * @param feeTypes Array of fee type identifiers
     * @param amounts Array of corresponding fee amounts
     */
    function batchCollectFees(
        string[] calldata feeTypes,
        uint256[] calldata amounts
    ) external nonReentrant whenNotPaused onlyRole(COLLECTOR_ROLE) {
        if (feeTypes.length != amounts.length) revert InvalidAmount();
        
        uint256 totalAmount = 0;
        for (uint256 i = 0; i < amounts.length; ++i) {
            totalAmount += amounts[i];
            
            // Emit individual events for tracking
            emit FeeCollected(
                msg.sender,
                feeTypes[i],
                amounts[i],
                block.timestamp // solhint-disable-line not-rely-on-time
            );
        }
        
        // Single transfer for all fees
        FEE_TOKEN.safeTransferFrom(msg.sender, address(this), totalAmount);
    }
    
    // =============================================================================
    // DISTRIBUTION - SIMPLIFIED
    // =============================================================================
    
    /**
     * @notice Distribute collected fees according to ratios
     * @dev Simplified version - just splits amounts, validator handles individual distributions
     */
    function distributeFees() 
        external 
        nonReentrant 
        whenNotPaused 
        onlyRole(DISTRIBUTOR_ROLE) 
    {
        if (block.timestamp < lastDistributionTime + distributionInterval) { // solhint-disable-line not-rely-on-time
            revert InvalidAmount();
        }
        
        uint256 totalBalance = FEE_TOKEN.balanceOf(address(this));
        
        // Subtract already allocated amounts
        uint256 allocated = companyPendingWithdrawals[address(FEE_TOKEN)] + 
                          developmentPendingWithdrawals[address(FEE_TOKEN)];
        
        uint256 availableForDistribution = totalBalance > allocated ? 
                                         totalBalance - allocated : 0;
        
        if (availableForDistribution < minimumDistributionAmount) {
            revert InvalidAmount();
        }
        
        // Calculate shares
        uint256 validatorAmount = (availableForDistribution * distributionRatio.validatorShare) / 10000;
        uint256 companyAmount = (availableForDistribution * distributionRatio.companyShare) / 10000;
        uint256 developmentAmount = (availableForDistribution * distributionRatio.developmentShare) / 10000;
        
        // Update pending amounts (validators claim with merkle proof)
        companyPendingWithdrawals[address(FEE_TOKEN)] += companyAmount;
        developmentPendingWithdrawals[address(FEE_TOKEN)] += developmentAmount;
        
        // Update state
        lastDistributionTime = block.timestamp; // solhint-disable-line not-rely-on-time
        ++currentEpoch;
        
        // Emit event for validator indexing
        emit FeeDistributed(
            currentEpoch,
            availableForDistribution,
            validatorAmount,
            companyAmount,
            developmentAmount,
            block.timestamp // solhint-disable-line not-rely-on-time
        );
        
        // Note: Validator will compute individual shares off-chain and submit merkle root
    }
    
    // =============================================================================
    // VALIDATOR INTEGRATION
    // =============================================================================
    
    /**
     * @notice Update distribution merkle root
     * @dev Called by validator after computing individual distributions
     * @param newRoot New merkle root hash for validator rewards
     * @param epoch Epoch number this root applies to
     * @param totalValidatorRewards Total amount being distributed to validators
     */
    function updateDistributionRoot(
        bytes32 newRoot,
        uint256 epoch,
        uint256 totalValidatorRewards
    ) external onlyValidator {
        if (epoch != currentEpoch) revert EpochMismatch();
        
        currentDistributionRoot = newRoot;
        lastDistributionBlock = block.number;
        
        emit DistributionRootUpdated(
            newRoot,
            epoch,
            totalValidatorRewards,
            block.number,
            block.timestamp // solhint-disable-line not-rely-on-time
        );
    }
    
    /**
     * @notice Claim validator rewards with merkle proof
     * @param amount Amount of tokens to claim
     * @param proof Merkle proof demonstrating eligibility
     */
    function claimValidatorReward(
        uint256 amount,
        bytes32[] calldata proof
    ) external nonReentrant whenNotPaused {
        // Check not already claimed this epoch
        if (claimedInEpoch[msg.sender] > currentEpoch - 1) revert AlreadyClaimed();
        
        // Verify merkle proof
        bytes32 leaf = keccak256(abi.encodePacked(msg.sender, amount, currentEpoch));
        if (!_verifyProof(proof, currentDistributionRoot, leaf)) revert InvalidProof();
        
        // Mark as claimed
        claimedInEpoch[msg.sender] = currentEpoch;
        
        // Transfer reward
        FEE_TOKEN.safeTransfer(msg.sender, amount);
        
        emit ValidatorRewardClaimed(
            msg.sender,
            amount,
            currentEpoch,
            block.timestamp // solhint-disable-line not-rely-on-time
        );
    }
    
    // =============================================================================
    // TREASURY WITHDRAWALS
    // =============================================================================
    
    /**
     * @notice Withdraw accumulated company fees
     * @param token Address of token to withdraw
     * @param amount Amount of tokens to withdraw
     */
    function withdrawCompanyFees(
        address token,
        uint256 amount
    ) external nonReentrant onlyRole(TREASURY_ROLE) {
        if (amount > companyPendingWithdrawals[token]) revert InsufficientBalance();
        
        companyPendingWithdrawals[token] -= amount;
        
        IERC20(token).safeTransfer(treasuryAddresses.companyTreasury, amount);
        
        emit CompanyFeesWithdrawn(
            token,
            amount,
            treasuryAddresses.companyTreasury,
            block.timestamp // solhint-disable-line not-rely-on-time
        );
    }
    
    /**
     * @notice Withdraw accumulated development fees
     * @param token Address of token to withdraw
     * @param amount Amount of tokens to withdraw
     */
    function withdrawDevelopmentFees(
        address token,
        uint256 amount
    ) external nonReentrant onlyRole(TREASURY_ROLE) {
        if (amount > developmentPendingWithdrawals[token]) revert InsufficientBalance();
        
        developmentPendingWithdrawals[token] -= amount;
        
        IERC20(token).safeTransfer(treasuryAddresses.developmentFund, amount);
        
        emit DevelopmentFeesWithdrawn(
            token,
            amount,
            treasuryAddresses.developmentFund,
            block.timestamp // solhint-disable-line not-rely-on-time
        );
    }
    
    // =============================================================================
    // VIEW FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Verify a validator's claimable amount
     * @param validator Address of the validator
     * @param amount Amount they claim to be eligible for
     * @param proof Merkle proof of their eligibility
     * @return valid Whether the proof is valid
     */
    function verifyValidatorReward(
        address validator,
        uint256 amount,
        bytes32[] calldata proof
    ) external view returns (bool valid) {
        bytes32 leaf = keccak256(abi.encodePacked(validator, amount, currentEpoch));
        return _verifyProof(proof, currentDistributionRoot, leaf);
    }
    
    /**
     * @notice Check if validator has claimed in current epoch
     * @param validator Address of the validator to check
     * @return claimed Whether the validator has already claimed
     */
    function hasClaimedInEpoch(address validator) external view returns (bool claimed) {
        return claimedInEpoch[validator] > currentEpoch - 1;
    }
    
    /**
     * @notice Get fee metrics (must query validator)
     * @dev Returns empty data - actual metrics via validator API
     * @return totalFeesCollected Always 0, use validator API
     * @return totalDistributed Always 0, use validator API
     * @return totalValidatorRewards Always 0, use validator API
     * @return totalCompanyRevenue Always 0, use validator API
     * @return totalDevelopmentFunding Always 0, use validator API
     * @return distributionCount Current epoch number
     * @return lastDistribution Timestamp of last distribution
     */
    function getRevenueMetrics() external view returns (
        uint256 totalFeesCollected,
        uint256 totalDistributed,
        uint256 totalValidatorRewards,
        uint256 totalCompanyRevenue,
        uint256 totalDevelopmentFunding,
        uint256 distributionCount,
        uint256 lastDistribution
    ) {
        return (0, 0, 0, 0, 0, currentEpoch, lastDistributionTime);
    }
    
    // =============================================================================
    // ADMIN FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Update distribution ratios
     * @param validatorShare Percentage for validators (in basis points)
     * @param companyShare Percentage for company treasury (in basis points)
     * @param developmentShare Percentage for development fund (in basis points)
     */
    function setDistributionRatios(
        uint256 validatorShare,
        uint256 companyShare,
        uint256 developmentShare
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (validatorShare + companyShare + developmentShare != 10000) {
            revert InvalidRatios();
        }
        
        distributionRatio = DistributionRatio({
            validatorShare: validatorShare,
            companyShare: companyShare,
            developmentShare: developmentShare
        });
    }
    
    /**
     * @notice Update treasury addresses
     * @param companyTreasury New company treasury address
     * @param developmentFund New development fund address
     */
    function setTreasuryAddresses(
        address companyTreasury,
        address developmentFund
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (companyTreasury == address(0)) revert InvalidAddress();
        if (developmentFund == address(0)) revert InvalidAddress();
        
        treasuryAddresses = TreasuryAddresses({
            companyTreasury: companyTreasury,
            developmentFund: developmentFund
        });
    }
    
    /**
     * @notice Emergency pause
     */
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }
    
    /**
     * @notice Unpause
     */
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }
    
    /**
     * @notice Get total fees collected (must query validator)
     * @dev Returns 0 - actual data available via validator GraphQL API
     * @return total Always returns 0, use validator API for real data
     */
    function getTotalFeesCollected() external pure returns (uint256 total) {
        return 0; // Computed by validator from events
    }
    
    // =============================================================================
    // INTERNAL FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Verify merkle proof for validator reward claims
     * @param proof Array of merkle proof elements
     * @param root Merkle root to verify against
     * @param leaf Leaf node to verify
     * @return valid Whether the proof is valid
     */
    function _verifyProof(
        bytes32[] calldata proof,
        bytes32 root,
        bytes32 leaf
    ) internal pure returns (bool valid) {
        bytes32 computedHash = leaf;
        
        for (uint256 i = 0; i < proof.length; ++i) {
            bytes32 proofElement = proof[i];
            if (computedHash < proofElement) {
                computedHash = keccak256(abi.encodePacked(computedHash, proofElement));
            } else {
                computedHash = keccak256(abi.encodePacked(proofElement, computedHash));
            }
        }
        
        return computedHash == root;
    }
}