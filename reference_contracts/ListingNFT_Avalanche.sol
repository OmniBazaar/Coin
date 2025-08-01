// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721URIStorage} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {RegistryAware} from "./base/RegistryAware.sol";

/**
 * @title ListingNFT - Avalanche Validator Integrated Version
 * @author OmniCoin Development Team
 * @notice Event-based NFT contract for OmniBazaar marketplace
 * @dev Major changes from original:
 * - Removed transaction storage mapping - events only
 * - Removed userListings arrays - indexed by validator
 * - Removed userTransactions arrays - indexed by validator
 * - Added validator-compatible events
 * - Transaction history via event queries
 * 
 * State Reduction: ~70% less storage
 * All marketplace data indexed by AvalancheValidator
 */
contract ListingNFT is ERC721URIStorage, RegistryAware, Ownable, ReentrancyGuard {
    
    // =============================================================================
    // MINIMAL STATE - ONLY ESSENTIAL DATA
    // =============================================================================
    
    // Current token ID counter (required for NFT minting)
    uint256 private _tokenIds;
    
    // Approved minters (required for access control)
    mapping(address => bool) public approvedMinters;
    
    // Active listing prices (minimal marketplace state)
    mapping(uint256 => uint256) public listingPrices;
    mapping(uint256 => bool) public isListed;
    
    // Merkle root for transaction verification
    bytes32 public transactionRoot;
    uint256 public lastRootUpdate;
    uint256 public currentEpoch;
    
    // =============================================================================
    // EVENTS - VALIDATOR COMPATIBLE
    // =============================================================================
    
    /**
     * @notice Listing created event for marketplace indexing
     * @dev Matches validator's expected format
     */
    event ListingCreated(
        uint256 indexed tokenId,
        address indexed seller,
        uint256 indexed categoryId,
        uint256 price,
        string metadataIPFS,
        uint256 timestamp
    );
    
    /**
     * @notice Listing updated event
     */
    event ListingUpdated(
        uint256 indexed tokenId,
        uint256 newPrice,
        bool isActive,
        uint256 timestamp
    );
    
    /**
     * @notice Item purchased event
     */
    event ItemPurchased(
        uint256 indexed tokenId,
        address indexed buyer,
        address indexed seller,
        uint256 price,
        uint256 timestamp
    );
    
    /**
     * @notice Listing cancelled event
     */
    event ListingCancelled(
        uint256 indexed tokenId,
        address indexed seller,
        uint256 timestamp
    );
    
    /**
     * @notice Transaction root updated by validator
     */
    event TransactionRootUpdated(
        bytes32 indexed newRoot,
        uint256 epoch,
        uint256 blockNumber,
        uint256 timestamp
    );
    
    /**
     * @notice Minter approval changed
     */
    event MinterApprovalChanged(
        address indexed minter,
        bool approved,
        uint256 timestamp
    );
    
    // =============================================================================
    // ERRORS
    // =============================================================================
    
    error NotAuthorizedToMint();
    error ListingDoesNotExist();
    error NotListingOwner();
    error CannotBuyOwnListing();
    error InsufficientPayment();
    error ListingNotActive();
    error InvalidProof();
    error NotAvalancheValidator();
    
    // =============================================================================
    // MODIFIERS
    // =============================================================================
    
    modifier onlyAvalancheValidator() {
        require(
            _isAvalancheValidator(msg.sender),
            "Only Avalanche validators"
        );
        _;
    }
    
    // =============================================================================
    // CONSTRUCTOR
    // =============================================================================
    
    constructor(
        address registry,
        address initialOwner
    ) ERC721("OmniBazaar Listing", "OBL") 
      RegistryAware(registry) 
      Ownable(initialOwner) {
        _tokenIds = 0;
    }
    
    // =============================================================================
    // MINTING FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Mint a new listing NFT
     * @dev Emits event for validator indexing
     */
    function mint(
        address to,
        string memory tokenURI,
        uint256 price,
        uint256 categoryId
    ) public returns (uint256 tokenId) {
        if (!approvedMinters[msg.sender] && msg.sender != owner())
            revert NotAuthorizedToMint();
        
        ++_tokenIds;
        uint256 newTokenId = _tokenIds;

        _mint(to, newTokenId);
        _setTokenURI(newTokenId, tokenURI);
        
        // Set initial listing data
        listingPrices[newTokenId] = price;
        isListed[newTokenId] = true;
        
        // Emit event for validator indexing
        emit ListingCreated(
            newTokenId,
            to,
            categoryId,
            price,
            tokenURI, // IPFS CID
            block.timestamp
        );

        return newTokenId;
    }
    
    // =============================================================================
    // MARKETPLACE FUNCTIONS - EVENT BASED
    // =============================================================================
    
    /**
     * @notice Update listing price
     * @dev Only emits event, price tracked by validator
     */
    function updateListing(uint256 tokenId, uint256 newPrice) 
        external 
        nonReentrant 
    {
        if (ownerOf(tokenId) != msg.sender) revert NotListingOwner();
        
        listingPrices[tokenId] = newPrice;
        
        emit ListingUpdated(
            tokenId,
            newPrice,
            isListed[tokenId],
            block.timestamp
        );
    }
    
    /**
     * @notice Cancel a listing
     */
    function cancelListing(uint256 tokenId) 
        external 
        nonReentrant 
    {
        if (ownerOf(tokenId) != msg.sender) revert NotListingOwner();
        
        isListed[tokenId] = false;
        listingPrices[tokenId] = 0;
        
        emit ListingCancelled(
            tokenId,
            msg.sender,
            block.timestamp
        );
        
        emit ListingUpdated(
            tokenId,
            0,
            false,
            block.timestamp
        );
    }
    
    /**
     * @notice Purchase a listed item
     * @dev Simplified - actual payment handled by marketplace contract
     */
    function purchase(uint256 tokenId) 
        external 
        payable 
        nonReentrant 
    {
        if (!isListed[tokenId]) revert ListingNotActive();
        
        address seller = ownerOf(tokenId);
        if (seller == msg.sender) revert CannotBuyOwnListing();
        
        uint256 price = listingPrices[tokenId];
        if (msg.value < price) revert InsufficientPayment();
        
        // Update state
        isListed[tokenId] = false;
        listingPrices[tokenId] = 0;
        
        // Transfer NFT
        _transfer(seller, msg.sender, tokenId);
        
        // Transfer payment (in real implementation, would go through escrow)
        (bool success, ) = seller.call{value: price}("");
        require(success, "Payment failed");
        
        // Refund excess
        if (msg.value > price) {
            (bool refundSuccess, ) = msg.sender.call{value: msg.value - price}("");
            require(refundSuccess, "Refund failed");
        }
        
        // Emit event for validator indexing
        emit ItemPurchased(
            tokenId,
            msg.sender,
            seller,
            price,
            block.timestamp
        );
    }
    
    // =============================================================================
    // VALIDATOR INTEGRATION
    // =============================================================================
    
    /**
     * @notice Update transaction merkle root
     * @dev Called by validator after indexing all transactions
     */
    function updateTransactionRoot(
        bytes32 newRoot,
        uint256 epoch
    ) external onlyAvalancheValidator {
        require(epoch == currentEpoch + 1, "Invalid epoch");
        
        transactionRoot = newRoot;
        lastRootUpdate = block.number;
        currentEpoch = epoch;
        
        emit TransactionRootUpdated(
            newRoot,
            epoch,
            block.number,
            block.timestamp
        );
    }
    
    /**
     * @notice Verify a transaction with merkle proof
     * @dev Anyone can verify historical transactions
     */
    function verifyTransaction(
        uint256 tokenId,
        address buyer,
        address seller,
        uint256 price,
        uint256 transactionTime,
        bytes32[] calldata proof
    ) external view returns (bool) {
        bytes32 leaf = keccak256(abi.encodePacked(
            tokenId,
            buyer,
            seller,
            price,
            transactionTime,
            currentEpoch
        ));
        return _verifyProof(proof, transactionRoot, leaf);
    }
    
    // =============================================================================
    // ADMIN FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Set or revoke minter approval
     */
    function setApprovedMinter(address minter, bool approved) external onlyOwner {
        approvedMinters[minter] = approved;
        emit MinterApprovalChanged(minter, approved, block.timestamp);
    }
    
    // =============================================================================
    // VIEW FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Check if an address is an approved minter
     */
    function isApprovedMinter(address minter) public view returns (bool) {
        return approvedMinters[minter];
    }
    
    /**
     * @notice Get user's listings (must query validator)
     * @dev Returns empty array - actual data via GraphQL API
     */
    function getUserListings(address) external pure returns (uint256[] memory) {
        return new uint256[](0); // Maintained by validator
    }
    
    /**
     * @notice Get user's transaction history (must query validator)
     * @dev Returns empty array - actual data via GraphQL API
     */
    function getUserTransactions(address) external pure returns (uint256[] memory) {
        return new uint256[](0); // Maintained by validator
    }
    
    /**
     * @notice Get listing info
     * @dev Basic on-chain data only, full details via validator
     */
    function getListingInfo(uint256 tokenId) external view returns (
        address seller,
        uint256 price,
        bool active,
        string memory uri
    ) {
        seller = ownerOf(tokenId);
        price = listingPrices[tokenId];
        active = isListed[tokenId];
        uri = tokenURI(tokenId);
    }
    
    // =============================================================================
    // INTERNAL FUNCTIONS
    // =============================================================================
    
    function _verifyProof(
        bytes32[] calldata proof,
        bytes32 root,
        bytes32 leaf
    ) internal pure returns (bool) {
        bytes32 computedHash = leaf;
        
        for (uint256 i = 0; i < proof.length; i++) {
            bytes32 proofElement = proof[i];
            if (computedHash <= proofElement) {
                computedHash = keccak256(abi.encodePacked(computedHash, proofElement));
            } else {
                computedHash = keccak256(abi.encodePacked(proofElement, computedHash));
            }
        }
        
        return computedHash == root;
    }
    
    function _isAvalancheValidator(address account) internal view returns (bool) {
        address avalancheValidator = registry.getContract(keccak256("AVALANCHE_VALIDATOR"));
        return account == avalancheValidator;
    }
    
    /**
     * @notice Override transfer to emit listing events
     */
    function _transfer(
        address from,
        address to,
        uint256 tokenId
    ) internal override {
        // If listed, cancel listing on transfer
        if (isListed[tokenId] && from != address(0)) {
            isListed[tokenId] = false;
            listingPrices[tokenId] = 0;
            
            emit ListingCancelled(tokenId, from, block.timestamp);
            emit ListingUpdated(tokenId, 0, false, block.timestamp);
        }
        
        super._transfer(from, to, tokenId);
    }
}