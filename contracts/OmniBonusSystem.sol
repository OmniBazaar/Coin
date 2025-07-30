// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {RegistryAware} from "./base/RegistryAware.sol";

/**
 * @title OmniBonusSystem
 * @author OmniCoin Development Team
 * @notice Manages welcome, referral, and first sale bonuses for OmniBazaar
 * @dev Implements tiered bonus distribution system as per design specifications
 */
contract OmniBonusSystem is AccessControl, ReentrancyGuard, Pausable, RegistryAware {
    
    // =============================================================================
    // CONSTANTS & ROLES
    // =============================================================================
    
    /// @notice Role for bonus distributors (can trigger bonus payments)
    bytes32 public constant DISTRIBUTOR_ROLE = keccak256("DISTRIBUTOR_ROLE");
    /// @notice Role for bonus managers (can update tiers and amounts)
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    
    /// @notice Token decimals (must match OmniCoin)
    uint256 public constant DECIMALS = 6;
    
    // =============================================================================
    // STRUCTS
    // =============================================================================
    
    /// @notice Bonus tier configuration
    struct BonusTier {
        uint256 minUserCount;    // Minimum users for this tier
        uint256 welcomeBonus;    // Welcome bonus amount
        uint256 referralBonus;   // Referral bonus amount
        uint256 firstSaleBonus;  // First sale bonus amount
    }
    
    // =============================================================================
    // STATE VARIABLES
    // =============================================================================
    
    /// @notice Array of bonus tiers (ordered by minUserCount descending)
    BonusTier[] public bonusTiers;
    
    /// @notice Tracks if user has claimed welcome bonus
    mapping(address => bool) public hasClaimedWelcome;
    
    /// @notice Tracks if user has claimed first sale bonus
    mapping(address => bool) public hasClaimedFirstSale;
    
    /// @notice Tracks referral relationships (user => referrer)
    mapping(address => address) public referrers;
    
    /// @notice Tracks referral bonus claims (user => referrer => claimed)
    mapping(address => mapping(address => bool)) public referralClaimed;
    
    /// @notice Total users registered (for tier calculation)
    uint256 public totalUsers;
    
    /// @notice Total bonuses distributed by type
    mapping(string => uint256) public totalDistributed;
    
    // =============================================================================
    // EVENTS
    // =============================================================================
    
    event WelcomeBonusClaimed(address indexed user, uint256 amount, uint256 tier);
    event ReferralBonusClaimed(address indexed referrer, address indexed referee, uint256 amount);
    event FirstSaleBonusClaimed(address indexed seller, uint256 amount);
    event ReferralRegistered(address indexed user, address indexed referrer);
    event BonusTierUpdated(uint256 indexed tierIndex, uint256 minUsers, uint256 welcomeBonus);
    event UserRegistered(address indexed user, uint256 totalUsers);
    
    // =============================================================================
    // ERRORS
    // =============================================================================
    
    error AlreadyClaimed();
    error InvalidReferrer();
    error NoTierAvailable();
    error TransferFailed();
    error InvalidAmount();
    error InvalidTier();
    error SelfReferral();
    
    // =============================================================================
    // CONSTRUCTOR
    // =============================================================================
    
    /**
     * @notice Initialize the bonus system
     * @param _registry Registry contract address
     */
    constructor(address _registry) RegistryAware(_registry) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(DISTRIBUTOR_ROLE, msg.sender);
        _grantRole(MANAGER_ROLE, msg.sender);
        
        // Initialize bonus tiers as per design document
        _initializeBonusTiers();
    }
    
    // =============================================================================
    // INITIALIZATION
    // =============================================================================
    
    /**
     * @notice Initialize default bonus tiers
     * @dev Sets up the tiered bonus structure from the design document
     */
    function _initializeBonusTiers() private {
        // Tier 1: 0-250,000 users
        bonusTiers.push(BonusTier({
            minUserCount: 0,
            welcomeBonus: 10_000 * 10**DECIMALS,      // 10,000 XOM
            referralBonus: 2_500 * 10**DECIMALS,      // 2,500 XOM
            firstSaleBonus: 500 * 10**DECIMALS        // 500 XOM
        }));
        
        // Tier 2: 250,001-500,000 users
        bonusTiers.push(BonusTier({
            minUserCount: 250_001,
            welcomeBonus: 5_000 * 10**DECIMALS,       // 5,000 XOM
            referralBonus: 1_250 * 10**DECIMALS,      // 1,250 XOM
            firstSaleBonus: 250 * 10**DECIMALS        // 250 XOM
        }));
        
        // Tier 3: 500,001-1,000,000 users
        bonusTiers.push(BonusTier({
            minUserCount: 500_001,
            welcomeBonus: 2_500 * 10**DECIMALS,       // 2,500 XOM
            referralBonus: 625 * 10**DECIMALS,        // 625 XOM
            firstSaleBonus: 125 * 10**DECIMALS        // 125 XOM
        }));
        
        // Tier 4: 1,000,001-2,000,000 users
        bonusTiers.push(BonusTier({
            minUserCount: 1_000_001,
            welcomeBonus: 1_250 * 10**DECIMALS,       // 1,250 XOM
            referralBonus: 312_500_000,               // 312.5 XOM (312.5 * 10^6)
            firstSaleBonus: 62_500_000                // 62.5 XOM (62.5 * 10^6)
        }));
        
        // Tier 5: 2,000,001+ users
        bonusTiers.push(BonusTier({
            minUserCount: 2_000_001,
            welcomeBonus: 625 * 10**DECIMALS,         // 625 XOM
            referralBonus: 156_250_000,               // 156.25 XOM (156.25 * 10^6)
            firstSaleBonus: 31_250_000                // 31.25 XOM (31.25 * 10^6)
        }));
    }
    
    // =============================================================================
    // USER FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Register a new user with optional referrer
     * @param user User address to register
     * @param referrer Optional referrer address
     */
    function registerUser(address user, address referrer) 
        external 
        onlyRole(DISTRIBUTOR_ROLE) 
        whenNotPaused 
    {
        if (referrer != address(0)) {
            if (referrer == user) revert SelfReferral();
            if (referrers[user] != address(0)) revert InvalidReferrer();
            
            referrers[user] = referrer;
            emit ReferralRegistered(user, referrer);
        }
        
        totalUsers++;
        emit UserRegistered(user, totalUsers);
    }
    
    /**
     * @notice Claim welcome bonus for a user
     * @param user User address to receive bonus
     */
    function claimWelcomeBonus(address user) 
        external 
        onlyRole(DISTRIBUTOR_ROLE) 
        whenNotPaused 
        nonReentrant 
    {
        if (hasClaimedWelcome[user]) revert AlreadyClaimed();
        
        BonusTier memory tier = getCurrentTier();
        uint256 amount = tier.welcomeBonus;
        
        hasClaimedWelcome[user] = true;
        totalDistributed["welcome"] += amount;
        
        _transferBonus(user, amount);
        
        emit WelcomeBonusClaimed(user, amount, totalUsers);
    }
    
    /**
     * @notice Claim referral bonus when referee makes first purchase
     * @param referee User who was referred
     */
    function claimReferralBonus(address referee) 
        external 
        onlyRole(DISTRIBUTOR_ROLE) 
        whenNotPaused 
        nonReentrant 
    {
        address referrer = referrers[referee];
        if (referrer == address(0)) revert InvalidReferrer();
        if (referralClaimed[referee][referrer]) revert AlreadyClaimed();
        
        BonusTier memory tier = getCurrentTier();
        uint256 amount = tier.referralBonus;
        
        referralClaimed[referee][referrer] = true;
        totalDistributed["referral"] += amount;
        
        _transferBonus(referrer, amount);
        
        emit ReferralBonusClaimed(referrer, referee, amount);
    }
    
    /**
     * @notice Claim first sale bonus for a seller
     * @param seller Seller address to receive bonus
     */
    function claimFirstSaleBonus(address seller) 
        external 
        onlyRole(DISTRIBUTOR_ROLE) 
        whenNotPaused 
        nonReentrant 
    {
        if (hasClaimedFirstSale[seller]) revert AlreadyClaimed();
        
        BonusTier memory tier = getCurrentTier();
        uint256 amount = tier.firstSaleBonus;
        
        hasClaimedFirstSale[seller] = true;
        totalDistributed["firstSale"] += amount;
        
        _transferBonus(seller, amount);
        
        emit FirstSaleBonusClaimed(seller, amount);
    }
    
    // =============================================================================
    // VIEW FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Get the current bonus tier based on total users
     * @return Current bonus tier
     */
    function getCurrentTier() public view returns (BonusTier memory) {
        for (uint256 i = bonusTiers.length; i > 0; i--) {
            if (totalUsers >= bonusTiers[i - 1].minUserCount) {
                return bonusTiers[i - 1];
            }
        }
        revert NoTierAvailable();
    }
    
    /**
     * @notice Check if user can claim welcome bonus
     * @param user User address to check
     * @return Whether user can claim
     */
    function canClaimWelcome(address user) external view returns (bool) {
        return !hasClaimedWelcome[user];
    }
    
    /**
     * @notice Check if referrer can claim bonus for referee
     * @param referee User who was referred
     * @return Whether referral bonus can be claimed
     */
    function canClaimReferral(address referee) external view returns (bool) {
        address referrer = referrers[referee];
        return referrer != address(0) && !referralClaimed[referee][referrer];
    }
    
    /**
     * @notice Check if seller can claim first sale bonus
     * @param seller Seller address to check
     * @return Whether first sale bonus can be claimed
     */
    function canClaimFirstSale(address seller) external view returns (bool) {
        return !hasClaimedFirstSale[seller];
    }
    
    // =============================================================================
    // ADMIN FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Update a bonus tier
     * @param tierIndex Index of tier to update
     * @param minUsers Minimum users for tier
     * @param welcomeBonus Welcome bonus amount
     * @param referralBonus Referral bonus amount
     * @param firstSaleBonus First sale bonus amount
     */
    function updateBonusTier(
        uint256 tierIndex,
        uint256 minUsers,
        uint256 welcomeBonus,
        uint256 referralBonus,
        uint256 firstSaleBonus
    ) external onlyRole(MANAGER_ROLE) {
        if (tierIndex >= bonusTiers.length) revert InvalidTier();
        
        bonusTiers[tierIndex] = BonusTier({
            minUserCount: minUsers,
            welcomeBonus: welcomeBonus,
            referralBonus: referralBonus,
            firstSaleBonus: firstSaleBonus
        });
        
        emit BonusTierUpdated(tierIndex, minUsers, welcomeBonus);
    }
    
    /**
     * @notice Add a new bonus tier
     * @param minUsers Minimum users for tier
     * @param welcomeBonus Welcome bonus amount
     * @param referralBonus Referral bonus amount
     * @param firstSaleBonus First sale bonus amount
     */
    function addBonusTier(
        uint256 minUsers,
        uint256 welcomeBonus,
        uint256 referralBonus,
        uint256 firstSaleBonus
    ) external onlyRole(MANAGER_ROLE) {
        bonusTiers.push(BonusTier({
            minUserCount: minUsers,
            welcomeBonus: welcomeBonus,
            referralBonus: referralBonus,
            firstSaleBonus: firstSaleBonus
        }));
        
        emit BonusTierUpdated(bonusTiers.length - 1, minUsers, welcomeBonus);
    }
    
    /**
     * @notice Pause bonus distribution
     */
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }
    
    /**
     * @notice Unpause bonus distribution
     */
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }
    
    // =============================================================================
    // INTERNAL FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Transfer bonus to recipient
     * @param recipient Address to receive bonus
     * @param amount Bonus amount
     */
    function _transferBonus(address recipient, uint256 amount) private {
        address omniCoin = REGISTRY.getContract(keccak256("OMNICOIN"));
        
        if (!IERC20(omniCoin).transfer(recipient, amount)) {
            revert TransferFailed();
        }
    }
    
    /**
     * @notice Emergency withdrawal of tokens
     * @param token Token address
     * @param amount Amount to withdraw
     */
    function emergencyWithdraw(address token, uint256 amount) 
        external 
        onlyRole(DEFAULT_ADMIN_ROLE) 
    {
        if (!IERC20(token).transfer(msg.sender, amount)) {
            revert TransferFailed();
        }
    }
}