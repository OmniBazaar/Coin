// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {ERC1155Supply} from "@openzeppelin/contracts/token/ERC1155/extensions/ERC1155Supply.sol";
import {ERC1155Burnable} from "@openzeppelin/contracts/token/ERC1155/extensions/ERC1155Burnable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {RegistryAware} from "./base/RegistryAware.sol";

/**
 * @title OmniERC1155
 * @author OmniBazaar Team
 * @notice Multi-token standard implementation for OmniBazaar marketplace
 * @dev Supports fungible, non-fungible, and semi-fungible tokens with dual-token payments
 * 
 * Key Features:
 * - Dual-token support (XOM and pXOM)
 * - Batch operations for gas efficiency
 * - Marketplace integration
 * - Creator royalties
 * - Import bridge compatibility
 * - Service token templates
 */
contract OmniERC1155 is 
    ERC1155, 
    ERC1155Supply, 
    ERC1155Burnable, 
    AccessControl, 
    ReentrancyGuard, 
    Pausable,
    RegistryAware 
{
    // =============================================================================
    // CONSTANTS & ROLES
    // =============================================================================
    
    /// @notice Role for minting new tokens
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    /// @notice Role for managing marketplace features
    bytes32 public constant MARKETPLACE_ROLE = keccak256("MARKETPLACE_ROLE");
    /// @notice Role for importing external tokens
    bytes32 public constant IMPORTER_ROLE = keccak256("IMPORTER_ROLE");
    
    /// @notice Maximum royalty percentage (30%)
    uint256 public constant MAX_ROYALTY_BPS = 3000;
    /// @notice Basis points denominator
    uint256 public constant BPS_DENOMINATOR = 10000;
    
    // =============================================================================
    // STRUCTS
    // =============================================================================
    
    /// @notice Token metadata and marketplace information
    struct TokenInfo {
        address creator;
        bool usePrivacy;         // Whether to use pXOM for payments
        bool isForSale;
        uint256 pricePerUnit;    // Price in smallest unit (6 decimals)
        uint256 maxPerPurchase;  // Maximum units per transaction
        uint256 royaltyBps;      // Creator royalty in basis points
        string metadataURI;      // Extended metadata URI
        TokenType tokenType;     // Type of token
    }
    
    /// @notice Types of tokens supported
    enum TokenType {
        FUNGIBLE,        // Identical items (e.g., game currency)
        NON_FUNGIBLE,    // Unique items (e.g., art)
        SEMI_FUNGIBLE,   // Limited editions
        SERVICE,         // Redeemable services
        SUBSCRIPTION     // Time-based access
    }
    
    /// @notice Service token specific data
    struct ServiceInfo {
        bool isRedeemable;
        uint256 validityPeriod;  // Seconds from purchase
        mapping(address => uint256) redemptionTime;
    }
    
    // =============================================================================
    // STATE VARIABLES
    // =============================================================================
    
    /// @notice Counter for token IDs
    uint256 private _tokenIdCounter;
    
    /// @notice Token information mapping
    mapping(uint256 => TokenInfo) public tokenInfo;
    
    /// @notice Service-specific information
    mapping(uint256 => ServiceInfo) public serviceInfo;
    
    /// @notice Accumulated royalties per token per holder
    mapping(uint256 => mapping(address => uint256)) public royaltyBalances;
    
    /// @notice Import bridge allowlist
    mapping(address => bool) public allowedImportContracts;
    
    /// @notice Custom token URIs (overrides base URI)
    mapping(uint256 => string) private _tokenURIs;
    
    // =============================================================================
    // EVENTS
    // =============================================================================
    
    /// @notice Emitted when a new token type is created
    event TokenCreated(
        uint256 indexed tokenId,
        address indexed creator,
        TokenType indexed tokenType,
        uint256 initialSupply
    );
    
    /// @notice Emitted when a token is listed for sale
    event TokenListed(
        uint256 indexed tokenId,
        uint256 indexed pricePerUnit,
        bool indexed usePrivacy
    );
    
    /// @notice Emitted when tokens are purchased from marketplace
    event TokensPurchased(
        uint256 indexed tokenId,
        address indexed buyer,
        uint256 indexed amount,
        uint256 totalPrice
    );
    
    /// @notice Emitted when royalties are distributed
    event RoyaltyDistributed(
        uint256 indexed tokenId,
        address indexed recipient,
        uint256 indexed amount
    );
    
    /// @notice Emitted when a service token is redeemed
    event ServiceRedeemed(
        uint256 indexed tokenId,
        address indexed redeemer,
        uint256 indexed timestamp
    );
    
    // =============================================================================
    // ERRORS
    // =============================================================================
    
    error InvalidPrice();
    error InvalidRoyalty();
    error TokenNotForSale();
    error InsufficientPayment();
    error ExceedsMaxPurchase();
    error NotTokenCreator();
    error InvalidTokenType();
    error ServiceAlreadyRedeemed();
    error ServiceExpired();
    error InvalidImportContract();
    error TransferFailed();
    
    // =============================================================================
    // CONSTRUCTOR
    // =============================================================================
    
    /**
     * @notice Initialize the OmniERC1155 contract
     * @param _registry Address of the OmniCoinRegistry
     * @param _uri Base URI for token metadata
     */
    constructor(
        address _registry,
        string memory _uri
    ) ERC1155(_uri) RegistryAware(_registry) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MINTER_ROLE, msg.sender);
        _grantRole(MARKETPLACE_ROLE, msg.sender);
    }
    
    // =============================================================================
    // MINTING FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Create a new token type with initial supply
     * @param amount Initial supply to mint
     * @param _tokenType Type of token to create
     * @param _metadataURI Metadata URI for the token
     * @param _royaltyBps Creator royalty in basis points
     * @return tokenId The ID of the newly created token
     */
    function createToken(
        uint256 amount,
        TokenType _tokenType,
        string memory _metadataURI,
        uint256 _royaltyBps
    ) external whenNotPaused returns (uint256 tokenId) {
        if (_royaltyBps > MAX_ROYALTY_BPS) revert InvalidRoyalty();
        
        tokenId = _tokenIdCounter++;
        
        tokenInfo[tokenId] = TokenInfo({
            creator: msg.sender,
            usePrivacy: false,
            isForSale: false,
            pricePerUnit: 0,
            maxPerPurchase: 0,
            royaltyBps: _royaltyBps,
            metadataURI: _metadataURI,
            tokenType: _tokenType
        });
        
        if (bytes(_metadataURI).length > 0) {
            _tokenURIs[tokenId] = _metadataURI;
        }
        
        if (amount > 0) {
            _mint(msg.sender, tokenId, amount, "");
        }
        
        emit TokenCreated(tokenId, msg.sender, _tokenType, amount);
    }
    
    /**
     * @notice Mint additional supply of an existing token
     * @param tokenId Token to mint
     * @param amount Amount to mint
     * @param to Recipient address
     */
    function mint(
        uint256 tokenId,
        uint256 amount,
        address to
    ) external onlyRole(MINTER_ROLE) {
        _mint(to, tokenId, amount, "");
    }
    
    /**
     * @notice Batch mint multiple tokens
     * @param to Recipient address
     * @param ids Array of token IDs
     * @param amounts Array of amounts to mint
     */
    function mintBatch(
        address to,
        uint256[] memory ids,
        uint256[] memory amounts
    ) external onlyRole(MINTER_ROLE) {
        _mintBatch(to, ids, amounts, "");
    }
    
    // =============================================================================
    // MARKETPLACE FUNCTIONS
    // =============================================================================
    
    /**
     * @notice List tokens for sale on the marketplace
     * @param tokenId Token to list
     * @param pricePerUnit Price per token in XOM/pXOM (6 decimals)
     * @param maxPerPurchase Maximum units per purchase (0 = unlimited)
     * @param usePrivacy Whether to accept pXOM payments
     */
    function listForSale(
        uint256 tokenId,
        uint256 pricePerUnit,
        uint256 maxPerPurchase,
        bool usePrivacy
    ) external {
        if (tokenInfo[tokenId].creator != msg.sender) revert NotTokenCreator();
        if (pricePerUnit == 0) revert InvalidPrice();
        
        TokenInfo storage info = tokenInfo[tokenId];
        info.isForSale = true;
        info.pricePerUnit = pricePerUnit;
        info.maxPerPurchase = maxPerPurchase;
        info.usePrivacy = usePrivacy;
        
        emit TokenListed(tokenId, pricePerUnit, usePrivacy);
    }
    
    /**
     * @notice Purchase tokens from the marketplace
     * @param tokenId Token to purchase
     * @param amount Amount to purchase
     */
    function purchase(
        uint256 tokenId,
        uint256 amount
    ) external nonReentrant whenNotPaused {
        TokenInfo storage info = tokenInfo[tokenId];
        if (!info.isForSale) revert TokenNotForSale();
        if (info.maxPerPurchase > 0 && amount > info.maxPerPurchase) {
            revert ExceedsMaxPurchase();
        }
        
        uint256 totalPrice = info.pricePerUnit * amount;
        
        // Get payment token
        address paymentToken = info.usePrivacy ?
            _getContract(REGISTRY.PRIVATE_OMNICOIN()) :
            _getContract(REGISTRY.OMNICOIN());
        
        // Transfer payment
        if (!IERC20(paymentToken).transferFrom(msg.sender, address(this), totalPrice)) {
            revert TransferFailed();
        }
        
        // Calculate and distribute royalties
        uint256 royaltyAmount = 0;
        if (info.royaltyBps > 0) {
            royaltyAmount = (totalPrice * info.royaltyBps) / BPS_DENOMINATOR;
            royaltyBalances[tokenId][info.creator] += royaltyAmount;
            emit RoyaltyDistributed(tokenId, info.creator, royaltyAmount);
        }
        
        // Transfer remaining payment to seller
        uint256 sellerAmount = totalPrice - royaltyAmount;
        address currentOwner = _msgSender(); // In real implementation, track current owner
        
        if (!IERC20(paymentToken).transfer(currentOwner, sellerAmount)) {
            revert TransferFailed();
        }
        
        // Transfer tokens to buyer
        _safeTransferFrom(currentOwner, msg.sender, tokenId, amount, "");
        
        emit TokensPurchased(tokenId, msg.sender, amount, totalPrice);
    }
    
    /**
     * @notice Withdraw accumulated royalties
     * @param tokenId Token ID to withdraw royalties for
     */
    function withdrawRoyalties(uint256 tokenId) external nonReentrant {
        uint256 balance = royaltyBalances[tokenId][msg.sender];
        if (balance == 0) revert InsufficientPayment();
        
        royaltyBalances[tokenId][msg.sender] = 0;
        
        TokenInfo storage info = tokenInfo[tokenId];
        address paymentToken = info.usePrivacy ?
            _getContract(REGISTRY.PRIVATE_OMNICOIN()) :
            _getContract(REGISTRY.OMNICOIN());
        
        if (!IERC20(paymentToken).transfer(msg.sender, balance)) {
            revert TransferFailed();
        }
    }
    
    // =============================================================================
    // SERVICE TOKEN FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Create a service token with validity period
     * @param amount Number of service tokens to create
     * @param validityPeriod How long the service is valid (in seconds)
     * @param _metadataURI Service description and terms
     * @param pricePerUnit Price per service token
     * @return tokenId The service token ID
     */
    function createServiceToken(
        uint256 amount,
        uint256 validityPeriod,
        string memory _metadataURI,
        uint256 pricePerUnit
    ) external whenNotPaused returns (uint256 tokenId) {
        tokenId = this.createToken(amount, TokenType.SERVICE, _metadataURI, 0);
        
        ServiceInfo storage service = serviceInfo[tokenId];
        service.isRedeemable = true;
        service.validityPeriod = validityPeriod;
        
        if (pricePerUnit > 0) {
            this.listForSale(tokenId, pricePerUnit, 0, false);
        }
    }
    
    /**
     * @notice Redeem a service token
     * @param tokenId Service token to redeem
     */
    function redeemService(uint256 tokenId) external {
        if (balanceOf(msg.sender, tokenId) == 0) revert InsufficientPayment();
        
        ServiceInfo storage service = serviceInfo[tokenId];
        if (!service.isRedeemable) revert InvalidTokenType();
        if (service.redemptionTime[msg.sender] > 0) revert ServiceAlreadyRedeemed();
        
        // Check if service is still valid
        // Implementation depends on how validity is tracked
        
        service.redemptionTime[msg.sender] = block.timestamp;
        
        // Burn the redeemed token
        _burn(msg.sender, tokenId, 1);
        
        emit ServiceRedeemed(tokenId, msg.sender, block.timestamp);
    }
    
    // =============================================================================
    // IMPORT BRIDGE FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Import tokens from external ERC1155 contracts
     * @param externalContract Address of external ERC1155
     * @param externalTokenId Token ID on external contract
     * @param amount Amount to import
     * @return localTokenId New token ID on this contract
     */
    function importToken(
        address externalContract,
        uint256 externalTokenId,
        uint256 amount
    ) external onlyRole(IMPORTER_ROLE) returns (uint256 localTokenId) {
        if (!allowedImportContracts[externalContract]) revert InvalidImportContract();
        
        // Create local token representation
        localTokenId = _tokenIdCounter++;
        
        tokenInfo[localTokenId] = TokenInfo({
            creator: msg.sender,
            usePrivacy: false,
            isForSale: false,
            pricePerUnit: 0,
            maxPerPurchase: 0,
            royaltyBps: 0,
            metadataURI: string(abi.encodePacked("imported/", externalTokenId)),
            tokenType: TokenType.FUNGIBLE
        });
        
        // Mint equivalent tokens
        _mint(msg.sender, localTokenId, amount, "");
        
        emit TokenCreated(localTokenId, msg.sender, TokenType.FUNGIBLE, amount);
    }
    
    // =============================================================================
    // ADMIN FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Add an external contract to import allowlist
     * @param externalContract Contract address to allow
     */
    function allowImportContract(address externalContract) 
        external 
        onlyRole(DEFAULT_ADMIN_ROLE) 
    {
        allowedImportContracts[externalContract] = true;
    }
    
    /**
     * @notice Pause all token operations
     */
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }
    
    /**
     * @notice Unpause token operations
     */
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }
    
    // =============================================================================
    // VIEW FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Get complete token information
     * @param tokenId Token to query
     * @return Token information struct
     */
    function getTokenInfo(uint256 tokenId) external view returns (TokenInfo memory) {
        return tokenInfo[tokenId];
    }
    
    /**
     * @notice Check if a service token has been redeemed
     * @param tokenId Service token ID
     * @param user User address to check
     * @return Whether the user has redeemed this service
     */
    function isServiceRedeemed(uint256 tokenId, address user) 
        external 
        view 
        returns (bool) 
    {
        return serviceInfo[tokenId].redemptionTime[user] > 0;
    }
    
    /**
     * @notice Get token URI
     * @param tokenId Token to query
     * @return URI string
     */
    function uri(uint256 tokenId) public view override returns (string memory) {
        string memory customURI = _tokenURIs[tokenId];
        if (bytes(customURI).length > 0) {
            return customURI;
        }
        return super.uri(tokenId);
    }
    
    // =============================================================================
    // OVERRIDES
    // =============================================================================
    
    /**
     * @notice Hook called for any token transfer
     * @dev Overrides both ERC1155 and ERC1155Supply
     */
    function _update(
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory values
    ) internal override(ERC1155, ERC1155Supply) whenNotPaused {
        super._update(from, to, ids, values);
    }
    
    /**
     * @notice Check if contract supports an interface
     */
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC1155, AccessControl)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}