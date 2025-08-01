// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

// Note: IERC721 and IERC1155 imports removed as not currently used
// import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
// import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {ERC1155Supply} from "@openzeppelin/contracts/token/ERC1155/extensions/ERC1155Supply.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {RegistryAware} from "./base/RegistryAware.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/**
 * @title UnifiedNFTMarketplace
 * @author OmniCoin Development Team
 * @notice Enhanced marketplace with full ERC1155 multi-token support
 * @dev Combines functionality from:
 * - ListingNFT (marketplace listings)
 * - OmniNFTMarketplace (trading functionality)
 * - OmniERC1155 (multi-token support)
 * 
 * Features:
 * - ERC1155 multi-token support (fungible/semi-fungible)
 * - Service tokens with expiration
 * - Subscription management
 * - Event-based architecture
 * - Merkle tree verification
 */
contract UnifiedNFTMarketplace is 
    ERC1155,
    ERC1155Supply,
    AccessControl, 
    ReentrancyGuard, 
    Pausable, 
    RegistryAware 
{
    using SafeERC20 for IERC20;
    using Strings for uint256;
    
    // =============================================================================
    // TYPES & CONSTANTS
    // =============================================================================
    
    enum ListingStatus {
        ACTIVE,
        SOLD,
        CANCELLED,
        EXPIRED
    }
    
    enum ListingType {
        PRODUCT,        // Physical goods
        SERVICE,        // Time-based services
        DIGITAL,        // Digital downloads
        SUBSCRIPTION,   // Recurring services
        FUNGIBLE,       // Fungible tokens (like currency)
        SEMI_FUNGIBLE   // Limited edition items
    }
    
    enum TokenType {
        FUNGIBLE,       // Fully fungible (ERC20-like)
        SEMI_FUNGIBLE,  // Limited editions
        SERVICE,        // Service with expiration
        SUBSCRIPTION    // Recurring subscription
    }
    
    struct TokenInfo {
        address creator;         // 20 bytes - slot 0
        uint32 royaltyBps;       // 4 bytes - slot 0 (24 bytes total)
        uint32 expirationTime;   // 4 bytes - slot 0 (28 bytes total)  
        TokenType tokenType;     // 1 byte  - slot 0 (29 bytes total)
        bool acceptsPrivacy;     // 1 byte  - slot 0 (30 bytes total)
        uint256 maxSupply;       // 32 bytes - slot 1 (0 = unlimited)
        uint256 price;           // 32 bytes - slot 2
        string metadataUri;      // 32 bytes - slot 3+
    }
    
    struct ServiceToken {
        uint256 validUntil;     // Expiration timestamp
        uint256 usageCount;     // For multi-use services
        uint256 maxUsage;       // Max uses (0 = unlimited)
        bool isActive;
    }
    
    // Fee constants (basis points)
    /// @notice Marketplace fee in basis points (1%)
    uint256 public constant MARKETPLACE_FEE = 100;
    /// @notice Privacy feature fee multiplier (10x base fee)
    uint256 public constant PRIVACY_MULTIPLIER = 10;
    /// @notice Basis points constant for percentage calculations (100%)
    uint256 public constant BASIS_POINTS = 10000;
    /// @notice Maximum royalty percentage in basis points (10%)
    uint256 public constant MAX_ROYALTY = 1000;
    
    // Token constraints
    /// @notice Minimum token price (1 XOM with 6 decimals)
    uint256 public constant MIN_PRICE = 1e6;
    /// @notice Maximum tokens that can be minted in a single batch
    uint256 public constant MAX_BATCH_MINT = 10000;
    /// @notice Grace period for service token renewals
    uint256 public constant SERVICE_GRACE_PERIOD = 7 days;
    
    // =============================================================================
    // ROLES
    // =============================================================================
    
    /// @notice Administrative role for contract management
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    /// @notice Role for minting new tokens
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    /// @notice Role for content moderation
    bytes32 public constant MODERATOR_ROLE = keccak256("MODERATOR_ROLE");
    /// @notice Role for Avalanche network validators
    bytes32 public constant AVALANCHE_VALIDATOR_ROLE = keccak256("AVALANCHE_VALIDATOR_ROLE");
    /// @notice Role for URI management
    bytes32 public constant URI_SETTER_ROLE = keccak256("URI_SETTER_ROLE");
    
    // =============================================================================
    // STATE (Minimal)
    // =============================================================================
    
    // Token counter
    uint256 private _nextTokenId;
    
    /// @notice Mapping of token ID to token information
    mapping(uint256 => TokenInfo) public tokenInfo;
    
    /// @notice Service token tracking (user => tokenId => ServiceToken)
    mapping(address => mapping(uint256 => ServiceToken)) public serviceTokens;
    
    /// @notice Active listings for trading (tokenId => available amount)
    mapping(uint256 => uint256) public activeListings;
    
    /// @notice Merkle root for transaction history verification
    bytes32 public transactionHistoryRoot;
    /// @notice Merkle root for user activity tracking
    bytes32 public userActivityRoot;
    /// @notice Merkle root for token metadata verification
    bytes32 public tokenMetadataRoot;
    /// @notice Block number of last root update
    uint256 public lastRootUpdate;
    /// @notice Current epoch for root updates
    uint256 public currentEpoch;
    
    /// @notice Address receiving treasury fees
    address public treasuryAddress;
    /// @notice Address for validator pool rewards
    address public validatorPoolAddress;
    /// @notice Address for liquidity pool fees
    address public liquidityPoolAddress;
    
    // Base URI for metadata
    string private _baseTokenURI;
    
    // =============================================================================
    // EVENTS - Validator Compatible
    // =============================================================================
    
    /// @notice Emitted when a new token is created
    /// @param tokenId Unique identifier for the token
    /// @param creator Address that created the token
    /// @param tokenType Type of token (fungible, service, etc.)
    /// @param maxSupply Maximum supply for the token (0 = unlimited)
    /// @param price Price per token unit
    /// @param metadataUri IPFS URI for token metadata
    /// @param timestamp Block timestamp of creation
    event TokenCreated(
        uint256 indexed tokenId,
        address indexed creator,
        TokenType tokenType,
        uint256 maxSupply,
        uint256 price,
        string metadataUri,
        uint256 indexed timestamp
    );
    
    /// @notice Emitted when a service token is created
    /// @param tokenId Unique identifier for the service token
    /// @param creator Address that created the service token
    /// @param duration Service duration in seconds
    /// @param maxUsage Maximum number of uses (0 = unlimited)
    /// @param price Price per service unit
    /// @param timestamp Block timestamp of creation
    event ServiceTokenCreated(
        uint256 indexed tokenId,
        address indexed creator,
        uint256 indexed duration,
        uint256 indexed maxUsage,
        uint256 price,
        uint256 timestamp
    );
    
    /// @notice Emitted when tokens are purchased
    /// @param tokenId ID of purchased token
    /// @param buyer Address purchasing the tokens
    /// @param seller Address selling the tokens
    /// @param amount Number of tokens purchased
    /// @param totalPrice Total price paid (excluding fees)
    /// @param feeAmount Marketplace fees collected
    /// @param usePrivacy Whether privacy features were used
    /// @param timestamp Block timestamp of purchase
    event TokenPurchased(
        uint256 indexed tokenId,
        address indexed buyer,
        address indexed seller,
        uint256 amount,
        uint256 totalPrice,
        uint256 feeAmount,
        bool usePrivacy,
        uint256 timestamp
    );
    
    /// @notice Emitted when a service token is activated
    /// @param tokenId ID of the service token
    /// @param user Address activating the service
    /// @param validUntil Expiration timestamp
    /// @param timestamp Block timestamp of activation
    event ServiceActivated(
        uint256 indexed tokenId,
        address indexed user,
        uint256 indexed validUntil,
        uint256 indexed timestamp
    );
    
    /// @notice Emitted when a service is used
    /// @param tokenId ID of the service token
    /// @param user Address using the service
    /// @param usageCount Current usage count
    /// @param timestamp Block timestamp of usage
    event ServiceUsed(
        uint256 indexed tokenId,
        address indexed user,
        uint256 indexed usageCount,
        uint256 indexed timestamp
    );
    
    /// @notice Emitted when a listing is created
    /// @param tokenId ID of the listed token
    /// @param amount Number of tokens listed
    /// @param pricePerUnit Price per token unit
    /// @param timestamp Block timestamp of listing
    event ListingCreated(
        uint256 indexed tokenId,
        uint256 indexed amount,
        uint256 indexed pricePerUnit,
        uint256 timestamp
    );
    
    /// @notice Emitted when a listing is cancelled
    /// @param tokenId ID of the cancelled token listing
    /// @param amount Number of tokens unlisted
    /// @param timestamp Block timestamp of cancellation
    event ListingCancelled(
        uint256 indexed tokenId,
        uint256 indexed amount,
        uint256 indexed timestamp
    );
    
    /// @notice Emitted when token metadata root is updated
    /// @param newRoot New Merkle root hash
    /// @param epoch Epoch number for the update
    /// @param blockNumber Block number of the update
    /// @param timestamp Block timestamp of update
    event TokenRootUpdated(
        bytes32 indexed newRoot,
        uint256 indexed epoch,
        uint256 indexed blockNumber,
        uint256 timestamp
    );
    
    // =============================================================================
    // ERRORS
    // =============================================================================
    
    error InvalidTokenType();
    error InvalidPrice();
    error InvalidAmount();
    error InvalidDuration();
    error InsufficientPayment();
    error ExceedsMaxSupply();
    error ServiceExpired();
    error ServiceNotActive();
    error UsageLimitExceeded();
    error NotTokenCreator();
    error ListingNotActive();
    error InvalidRoyalty();
    error TransferFailed();
    error NotAvalancheValidator();
    error InvalidAddress();
    error InvalidEpoch();
    
    // =============================================================================
    // MODIFIERS
    // =============================================================================
    
    modifier onlyAvalancheValidator() {
        if (!(hasRole(AVALANCHE_VALIDATOR_ROLE, msg.sender) ||
              _isAvalancheValidator(msg.sender))) {
            revert NotAvalancheValidator();
        }
        _;
    }
    
    modifier onlyTokenCreator(uint256 tokenId) {
        if (tokenInfo[tokenId].creator != msg.sender) revert NotTokenCreator();
        _;
    }
    
    // =============================================================================
    // CONSTRUCTOR
    // =============================================================================
    
    /**
     * @notice Initialize the NFT marketplace contract
     * @dev Sets up roles, fee recipients, and base URI
     * @param _admin Address to grant admin role
     * @param _registry Registry contract address for service discovery
     * @param _treasury Treasury address for fee collection
     * @param _validatorPool Validator pool address for validator rewards
     * @param _liquidityPool Liquidity pool address for liquidity rewards
     * @param _uri Base URI for token metadata
     */
    constructor(
        address _admin,
        address _registry,
        address _treasury,
        address _validatorPool,
        address _liquidityPool,
        string memory _uri
    ) 
        ERC1155(_uri)
        RegistryAware(_registry) 
    {
        if (_admin == address(0)) revert InvalidAddress();
        if (_treasury == address(0)) revert InvalidAddress();
        if (_validatorPool == address(0)) revert InvalidAddress();
        if (_liquidityPool == address(0)) revert InvalidAddress();
        
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
        _grantRole(MINTER_ROLE, _admin);
        _grantRole(URI_SETTER_ROLE, _admin);
        
        treasuryAddress = _treasury;
        validatorPoolAddress = _validatorPool;
        liquidityPoolAddress = _liquidityPool;
        
        _nextTokenId = 1; // Start at 1
        _baseTokenURI = _uri;
    }
    
    // =============================================================================
    // TOKEN CREATION FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Create a new token type
     * @dev Supports all token types including services
     * @param initialSupply Initial number of tokens to mint
     * @param tokenType Type of token (fungible, service, etc.)
     * @param metadataUri IPFS URI for token metadata
     * @param royaltyBps Royalty percentage in basis points (max 1000 = 10%)
     * @return tokenId Unique identifier for the created token
     */
    function createToken(
        uint256 initialSupply,
        TokenType tokenType,
        string calldata metadataUri,
        uint256 royaltyBps
    ) external nonReentrant whenNotPaused returns (uint256 tokenId) {
        if (royaltyBps > MAX_ROYALTY) revert InvalidRoyalty();
        if (initialSupply > MAX_BATCH_MINT) revert InvalidAmount();
        
        tokenId = ++_nextTokenId;
        
        tokenInfo[tokenId] = TokenInfo({
            tokenType: tokenType,
            creator: msg.sender,
            maxSupply: 0, // Unlimited by default
            price: 0, // Set when listing
            royaltyBps: royaltyBps,
            expirationTime: 0,
            acceptsPrivacy: false,
            metadataUri: metadataUri
        });
        
        if (initialSupply > 0) {
            _mint(msg.sender, tokenId, initialSupply, "");
        }
        
        emit TokenCreated(
            tokenId,
            msg.sender,
            tokenType,
            0,
            0,
            metadataUri,
            block.timestamp // solhint-disable-line not-rely-on-time
        );
    }
    
    /// @notice Create service token with expiration
    /// @dev For time-based services like consultations, memberships
    /// @param initialSupply Initial supply to mint
    /// @param duration Service duration in seconds
    /// @param metadataUri IPFS URI for service metadata
    /// @param pricePerUnit Price per service unit
    /// @return tokenId Unique identifier for the service token
    function createServiceToken(
        uint256 initialSupply,
        uint256 duration,
        string calldata metadataUri,
        uint256 pricePerUnit
    ) external nonReentrant whenNotPaused returns (uint256 tokenId) {
        if (pricePerUnit < MIN_PRICE) revert InvalidPrice();
        if (duration == 0) revert InvalidDuration();
        if (initialSupply > MAX_BATCH_MINT) revert InvalidAmount();
        
        tokenId = ++_nextTokenId;
        
        tokenInfo[tokenId] = TokenInfo({
            tokenType: TokenType.SERVICE,
            creator: msg.sender,
            maxSupply: 0,
            price: pricePerUnit,
            royaltyBps: 0, // No royalties on services
            expirationTime: 0, // Set on activation
            acceptsPrivacy: false,
            metadataUri: metadataUri
        });
        
        if (initialSupply > 0) {
            _mint(msg.sender, tokenId, initialSupply, "");
            activeListings[tokenId] = initialSupply;
        }
        
        emit ServiceTokenCreated(
            tokenId,
            msg.sender,
            duration,
            0, // Unlimited usage
            pricePerUnit,
            block.timestamp // solhint-disable-line not-rely-on-time
        );
        
        emit ListingCreated(
            tokenId,
            initialSupply,
            pricePerUnit,
            block.timestamp // solhint-disable-line not-rely-on-time
        );
    }
    
    /// @notice Mint additional tokens
    /// @dev Only creator can mint more of their tokens
    /// @param tokenId ID of token to mint more of
    /// @param amount Number of tokens to mint
    function mintAdditional(
        uint256 tokenId,
        uint256 amount
    ) external nonReentrant whenNotPaused onlyTokenCreator(tokenId) {
        if (amount > MAX_BATCH_MINT) revert InvalidAmount();
        
        TokenInfo storage info = tokenInfo[tokenId];
        if (info.maxSupply > 0) {
            uint256 currentSupply = totalSupply(tokenId);
            if (currentSupply + amount > info.maxSupply) revert ExceedsMaxSupply();
        }
        
        _mint(msg.sender, tokenId, amount, "");
    }
    
    // =============================================================================
    // MARKETPLACE FUNCTIONS
    // =============================================================================
    
    /// @notice List tokens for sale
    /// @dev Creates or updates active listing
    /// @param tokenId ID of token to list
    /// @param amount Number of tokens to list
    /// @param pricePerUnit Price per token unit
    /// @param acceptsPrivacy Whether to accept privacy payments
    function createListing(
        uint256 tokenId,
        uint256 amount,
        uint256 pricePerUnit,
        bool acceptsPrivacy
    ) external nonReentrant whenNotPaused {
        if (amount == 0) revert InvalidAmount();
        if (pricePerUnit < MIN_PRICE) revert InvalidPrice();
        if (balanceOf(msg.sender, tokenId) < amount) revert InvalidAmount();
        
        tokenInfo[tokenId].price = pricePerUnit;
        tokenInfo[tokenId].acceptsPrivacy = acceptsPrivacy;
        
        activeListings[tokenId] += amount;
        
        // Transfer tokens to marketplace for escrow
        _safeTransferFrom(msg.sender, address(this), tokenId, amount, "");
        
        emit ListingCreated(
            tokenId,
            amount,
            pricePerUnit,
            block.timestamp // solhint-disable-line not-rely-on-time
        );
    }
    
    /// @notice Buy listed tokens
    /// @dev Handles payment, fees, and token transfer
    /// @param tokenId ID of token to buy
    /// @param amount Number of tokens to buy
    /// @param usePrivacy Whether to use privacy features
    function buyToken(
        uint256 tokenId,
        uint256 amount,
        bool usePrivacy
    ) external nonReentrant whenNotPaused {
        if (amount == 0) revert InvalidAmount();
        if (activeListings[tokenId] < amount) revert ListingNotActive();
        
        TokenInfo storage info = tokenInfo[tokenId];
        if (!usePrivacy || info.acceptsPrivacy) {
            
            uint256 totalPrice = info.price * amount;
            uint256 feeAmount = _calculateFee(totalPrice, usePrivacy);
            uint256 totalPayment = totalPrice + feeAmount;
            
            // Handle payment
            IERC20 token = IERC20(_getToken(usePrivacy));
            token.safeTransferFrom(msg.sender, address(this), totalPayment);
            
            // Distribute fees
            _distributeFees(feeAmount, usePrivacy, token);
            
            // Pay creator (minus royalty if resale)
            address seller = info.creator;
            uint256 royaltyAmount = 0;
            
            if (info.royaltyBps > 0 && seller != info.creator) {
                royaltyAmount = (totalPrice * info.royaltyBps) / BASIS_POINTS;
                token.safeTransfer(info.creator, royaltyAmount);
            }
            
            token.safeTransfer(seller, totalPrice - royaltyAmount);
            
            // Transfer tokens to buyer
            activeListings[tokenId] -= amount;
            _safeTransferFrom(address(this), msg.sender, tokenId, amount, "");
            
            // Activate service tokens
            if (info.tokenType == TokenType.SERVICE) {
                _activateService(msg.sender, tokenId, amount);
            }
            
            emit TokenPurchased(
                tokenId,
                msg.sender,
                seller,
                amount,
                totalPrice,
                feeAmount,
                usePrivacy,
                block.timestamp // solhint-disable-line not-rely-on-time
            );
        }
    }
    
    /// @notice Cancel listing
    /// @param tokenId ID of token to unlist
    /// @param amount Number of tokens to unlist
    function cancelListing(
        uint256 tokenId,
        uint256 amount
    ) external nonReentrant whenNotPaused {
        if (amount == 0) revert InvalidAmount();
        if (activeListings[tokenId] < amount) revert InvalidAmount();
        
        activeListings[tokenId] -= amount;
        
        // Return tokens to seller
        _safeTransferFrom(address(this), msg.sender, tokenId, amount, "");
        
        emit ListingCancelled(tokenId, amount, block.timestamp); // solhint-disable-line not-rely-on-time
    }
    
    // =============================================================================
    // SERVICE TOKEN FUNCTIONS
    // =============================================================================
    
    
    /// @notice Use a service token
    /// @dev For services with usage limits
    /// @param tokenId ID of the service token to use
    function useService(uint256 tokenId) external nonReentrant whenNotPaused {
        ServiceToken storage service = serviceTokens[msg.sender][tokenId];
        
        if (!service.isActive) revert ServiceNotActive();
        if (block.timestamp > service.validUntil) revert ServiceExpired(); // solhint-disable-line not-rely-on-time
        
        if (service.maxUsage > 0) {
            if (service.usageCount > service.maxUsage) revert UsageLimitExceeded();
            ++service.usageCount;
        }
        
        emit ServiceUsed(
            tokenId,
            msg.sender,
            service.usageCount,
            block.timestamp // solhint-disable-line not-rely-on-time
        );
    }
    
    // =============================================================================
    // MERKLE ROOT UPDATES (External functions)
    // =============================================================================
    
    /// @notice Update token metadata root
    /// @param newRoot New Merkle root hash
    /// @param epoch Epoch number for validation
    function updateTokenRoot(
        bytes32 newRoot,
        uint256 epoch
    ) external onlyAvalancheValidator {
        if (epoch != currentEpoch + 1) revert InvalidEpoch();
        
        tokenMetadataRoot = newRoot;
        lastRootUpdate = block.number;
        currentEpoch = epoch;
        
        emit TokenRootUpdated(newRoot, epoch, block.number, block.timestamp); // solhint-disable-line not-rely-on-time
    }
    
    /// @notice Update transaction history root
    /// @param newRoot New transaction history Merkle root
    function updateTransactionRoot(bytes32 newRoot) external onlyAvalancheValidator {
        transactionHistoryRoot = newRoot;
    }
    
    /// @notice Update user activity root
    /// @param newRoot New user activity Merkle root
    function updateUserActivityRoot(bytes32 newRoot) external onlyAvalancheValidator {
        userActivityRoot = newRoot;
    }
    
    // =============================================================================
    // ADMIN FUNCTIONS (External functions)
    // =============================================================================
    
    /// @notice Update fee recipients
    /// @param _treasury New treasury address
    /// @param _validatorPool New validator pool address
    /// @param _liquidityPool New liquidity pool address
    function updateFeeRecipients(
        address _treasury,
        address _validatorPool,
        address _liquidityPool
    ) external onlyRole(ADMIN_ROLE) {
        if (_treasury == address(0)) revert InvalidAddress();
        if (_validatorPool == address(0)) revert InvalidAddress();
        if (_liquidityPool == address(0)) revert InvalidAddress();
        
        treasuryAddress = _treasury;
        validatorPoolAddress = _validatorPool;
        liquidityPoolAddress = _liquidityPool;
    }
    
    /// @notice Set base URI
    /// @param baseURI New base URI for token metadata
    function setBaseURI(string calldata baseURI) external onlyRole(URI_SETTER_ROLE) {
        _baseTokenURI = baseURI;
    }
    
    /// @notice Set max supply for token
    /// @param tokenId ID of token to set max supply for
    /// @param maxSupply New maximum supply (0 = unlimited)
    function setMaxSupply(
        uint256 tokenId,
        uint256 maxSupply
    ) external onlyRole(ADMIN_ROLE) {
        tokenInfo[tokenId].maxSupply = maxSupply;
    }
    
    /**
     * @notice Emergency pause
     */
    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }
    
    /**
     * @notice Unpause
     */
    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }
    
    // =============================================================================
    // VIEW FUNCTIONS
    // =============================================================================
    
    /// @notice Get token details
    /// @param tokenId ID of token to query
    /// @return tokenType Type of the token
    /// @return creator Address that created the token
    /// @return maxSupply Maximum supply (0 = unlimited)
    /// @return price Price per token unit
    /// @return royaltyBps Royalty in basis points
    /// @return acceptsPrivacy Whether token accepts privacy payments
    /// @return metadataUri IPFS URI for metadata
    function getTokenInfo(uint256 tokenId) external view returns (
        TokenType tokenType,
        address creator,
        uint256 maxSupply,
        uint256 price,
        uint256 royaltyBps,
        bool acceptsPrivacy,
        string memory metadataUri
    ) {
        TokenInfo storage info = tokenInfo[tokenId];
        return (
            info.tokenType,
            info.creator,
            info.maxSupply,
            info.price,
            info.royaltyBps,
            info.acceptsPrivacy,
            info.metadataUri
        );
    }
    
    /// @notice Get active listing amount
    /// @param tokenId ID of token to query
    /// @return Amount of tokens available for sale
    function getActiveListing(uint256 tokenId) external view returns (uint256) {
        return activeListings[tokenId];
    }
    
    /// @notice Calculate total cost including fees
    /// @param tokenId ID of token to calculate cost for
    /// @param amount Number of tokens to buy
    /// @param usePrivacy Whether to use privacy features
    /// @return total Total cost including fees
    /// @return fee Fee amount
    function calculateTotalCost(
        uint256 tokenId,
        uint256 amount,
        bool usePrivacy
    ) external view returns (uint256 total, uint256 fee) {
        uint256 price = tokenInfo[tokenId].price * amount;
        fee = _calculateFee(price, usePrivacy);
        total = price + fee;
    }
    
    /// @notice Check if service is valid
    /// @param user Address to check service validity for
    /// @param tokenId ID of the service token
    /// @return Whether the service is valid and active
    function isServiceValid(
        address user,
        uint256 tokenId
    ) external view returns (bool) {
        ServiceToken storage service = serviceTokens[user][tokenId];
        return service.isActive && 
               block.timestamp < service.validUntil && // solhint-disable-line not-rely-on-time
               (service.maxUsage == 0 || service.usageCount < service.maxUsage);
    }
    
    /// @notice URI for token metadata
    /// @param tokenId ID of token to get URI for
    /// @return Token metadata URI
    function uri(uint256 tokenId) public view override returns (string memory) {
        string memory customUri = tokenInfo[tokenId].metadataUri;
        if (bytes(customUri).length > 0) {
            return customUri;
        }
        return string(abi.encodePacked(_baseTokenURI, tokenId.toString()));
    }
    
    /// @notice Check interface support
    /// @param interfaceId Interface identifier
    /// @return Whether interface is supported
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC1155, AccessControl)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
    
    // =============================================================================
    // INTERNAL FUNCTIONS
    // =============================================================================
    
    /// @notice Activate service token after purchase
    /// @param user Address activating the service
    /// @param tokenId ID of the service token
    /// @param amount Number of service tokens activated
    function _activateService(
        address user,
        uint256 tokenId,
        uint256 amount
    ) internal {
        TokenInfo storage info = tokenInfo[tokenId];
        if (info.tokenType != TokenType.SERVICE) revert InvalidTokenType();
        
        ServiceToken storage service = serviceTokens[user][tokenId];
        
        // Set or extend expiration
        uint256 duration = 30 days; // Default, should be stored per token type
        if (service.validUntil < block.timestamp) { // solhint-disable-line not-rely-on-time
            service.validUntil = block.timestamp + duration; // solhint-disable-line not-rely-on-time
        } else {
            service.validUntil += duration * amount;
        }
        
        service.isActive = true;
        
        emit ServiceActivated(
            tokenId,
            user,
            service.validUntil,
            block.timestamp // solhint-disable-line not-rely-on-time
        );
    }
    
    /// @notice Distribute collected fees
    /// @param feeAmount Total fee amount to distribute
    /// @param usePrivacy Whether privacy features were used (unused but kept for interface)
    /// @param token Token contract for fee distribution
    function _distributeFees(
        uint256 feeAmount,
        bool usePrivacy,
        IERC20 token
    ) internal {
        usePrivacy; // Silence unused parameter warning
        if (feeAmount == 0) return;
        
        // Fee distribution: 70% validators, 20% treasury, 10% liquidity
        uint256 validatorShare = (feeAmount * 7000) / BASIS_POINTS;
        uint256 treasuryShare = (feeAmount * 2000) / BASIS_POINTS;
        uint256 liquidityShare = feeAmount - validatorShare - treasuryShare;
        
        if (validatorShare > 0) {
            token.safeTransfer(validatorPoolAddress, validatorShare);
        }
        if (treasuryShare > 0) {
            token.safeTransfer(treasuryAddress, treasuryShare);
        }
        if (liquidityShare > 0) {
            token.safeTransfer(liquidityPoolAddress, liquidityShare);
        }
    }
    
    // =============================================================================
    // OVERRIDES (Internal functions - come first)
    // =============================================================================
    
    /// @notice Override _update function for ERC1155 and ERC1155Supply compatibility
    /// @param from Source address
    /// @param to Destination address
    /// @param ids Array of token IDs
    /// @param values Array of token amounts
    function _update(
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory values
    ) internal override(ERC1155, ERC1155Supply) {
        super._update(from, to, ids, values);
    }
    
    // =============================================================================
    // INTERNAL VIEW FUNCTIONS (come after internal functions)
    // =============================================================================
    
    /// @notice Get token contract address
    /// @param usePrivacy Whether to use privacy token
    /// @return Token contract address
    function _getToken(bool usePrivacy) internal view returns (address) {
        if (usePrivacy) {
            return REGISTRY.getContract(keccak256("PRIVATE_OMNICOIN"));
        }
        return REGISTRY.getContract(keccak256("OMNICOIN"));
    }
    
    /// @notice Check if address is Avalanche validator
    /// @param account Address to check
    /// @return Whether address is validator
    function _isAvalancheValidator(address account) internal view returns (bool) {
        address avalancheValidator = REGISTRY.getContract(keccak256("AVALANCHE_VALIDATOR"));
        return account == avalancheValidator;
    }
    
    // =============================================================================
    // INTERNAL PURE FUNCTIONS (come last)
    // =============================================================================
    
    /// @notice Calculate marketplace fee
    /// @param price Base price for fee calculation
    /// @param usePrivacy Whether privacy features are used
    /// @return Calculated fee amount
    function _calculateFee(uint256 price, bool usePrivacy) internal pure returns (uint256) {
        uint256 fee = (price * MARKETPLACE_FEE) / BASIS_POINTS;
        if (usePrivacy) {
            fee *= PRIVACY_MULTIPLIER;
        }
        return fee;
    }
}