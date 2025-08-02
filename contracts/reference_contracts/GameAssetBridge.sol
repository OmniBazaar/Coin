// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {RegistryAware} from "./base/RegistryAware.sol";
import {UnifiedNFTMarketplace} from "./UnifiedNFTMarketplace.sol";

/**
 * @title GameAssetBridge
 * @author OmniCoin Development Team
 * @notice Simplified bridge for importing gaming assets and NFTs to OmniBazaar
 * @dev Event-based architecture with minimal state
 * 
 * Features:
 * - Import ERC-721 and ERC-1155 tokens
 * - Cross-chain asset verification via merkle proofs
 * - Automatic listing creation in MARKETPLACE
 * - Gaming collection fast-track
 * 
 * State Reduction: ~80% less storage than original
 */
contract GameAssetBridge is 
    ReentrancyGuard,
    Pausable,
    AccessControl,
    RegistryAware,
    IERC1155Receiver,
    IERC721Receiver
{
    // =============================================================================
    // ROLES
    // =============================================================================
    
    /// @notice Bridge operator role identifier
    bytes32 public constant BRIDGE_OPERATOR_ROLE = keccak256("BRIDGE_OPERATOR_ROLE");
    /// @notice Avalanche validator role identifier
    bytes32 public constant AVALANCHE_VALIDATOR_ROLE = keccak256("AVALANCHE_VALIDATOR_ROLE");
    
    // =============================================================================
    // STATE (Minimal)
    // =============================================================================
    
    // Reference to marketplace
    /// @notice Unified NFT marketplace contract
    UnifiedNFTMarketplace public immutable MARKETPLACE;
    
    // Merkle roots for cross-chain verification
    /// @notice Merkle root for cross-chain asset verification
    bytes32 public crossChainAssetsRoot;
    /// @notice Merkle root for gaming collections verification
    bytes32 public gamingCollectionsRoot;
    /// @notice Block number of last root update
    uint256 public lastRootUpdate;
    /// @notice Current epoch for cross-chain verification
    uint256 public currentEpoch;
    
    // Basic fee configuration
    /// @notice Base bridge fee in wei
    uint256 public baseBridgeFee = 0.001 ether; // 0.1% in XOM
    /// @notice Address that receives bridge fees
    address public feeRecipient;
    
    // =============================================================================
    // EVENTS - Validator Compatible
    // =============================================================================
    
    /// @notice Emitted when an asset is imported to the MARKETPLACE
    /// @param originalContract Address of the original token contract
    /// @param originalTokenId ID of the original token
    /// @param importer Address that imported the asset
    /// @param marketplaceTokenId ID of the created MARKETPLACE listing
    /// @param metadataUri Metadata URI for the asset
    /// @param amount Amount of tokens imported
    /// @param isERC1155 Whether the token is ERC1155
    /// @param sourceChain Source blockchain name
    /// @param timestamp Block timestamp of import
    event AssetImported(
        address indexed originalContract,
        uint256 indexed originalTokenId,
        address indexed importer,
        uint256 marketplaceTokenId,
        string metadataUri,
        uint256 amount,
        bool isERC1155,
        string sourceChain,
        uint256 timestamp
    );
    
    /// @notice Emitted when a cross-chain import is completed
    /// @param importHash Hash of the import transaction
    /// @param importer Address that imported the asset
    /// @param sourceChain Source blockchain name
    /// @param proofHash Hash of the merkle proof
    /// @param timestamp Block timestamp of import
    event CrossChainImport(
        bytes32 indexed importHash,
        address indexed importer,
        string sourceChain,
        bytes32 proofHash,
        uint256 indexed timestamp
    );
    
    /// @notice Emitted when bridge fees are collected
    /// @param importer Address that paid the fee
    /// @param feeAmount Amount of fee collected
    /// @param sourceChain Source blockchain name
    /// @param timestamp Block timestamp of fee collection
    event BridgeFeeCollected(
        address indexed importer,
        uint256 indexed feeAmount,
        string sourceChain,
        uint256 indexed timestamp
    );
    
    /// @notice Emitted when a merkle root is updated
    /// @param newRoot New merkle root value
    /// @param rootType Type of root (crossChain or gaming)
    /// @param epoch Epoch number for the update
    /// @param timestamp Block timestamp of update
    event RootUpdated(
        bytes32 indexed newRoot,
        string rootType,
        uint256 indexed epoch,
        uint256 indexed timestamp
    );
    
    // =============================================================================
    // ERRORS
    // =============================================================================
    
    error InvalidProof();
    error UnsupportedToken();
    error InsufficientFee();
    error TransferFailed();
    error NotAvalancheValidator();
    
    // =============================================================================
    // MODIFIERS
    // =============================================================================
    
    modifier onlyAvalancheValidator() {
        if (!hasRole(AVALANCHE_VALIDATOR_ROLE, msg.sender) &&
            !_isAvalancheValidator(msg.sender)) {
            revert NotAvalancheValidator();
        }
        _;
    }
    
    // =============================================================================
    // CONSTRUCTOR
    // =============================================================================
    
    /**
     * @notice Initialize the GameAssetBridge
     * @param _admin Address to grant admin role
     * @param _registry Address of the registry contract
     * @param _marketplace Address of the marketplace contract
     * @param _feeRecipient Address to receive bridge fees
     */
    constructor(
        address _admin,
        address _registry,
        address _marketplace,
        address _feeRecipient
    ) RegistryAware(_registry) {
        if (_admin == address(0)) revert UnsupportedToken();
        if (_marketplace == address(0)) revert UnsupportedToken();
        if (_feeRecipient == address(0)) revert UnsupportedToken();
        
        MARKETPLACE = UnifiedNFTMarketplace(_marketplace);
        feeRecipient = _feeRecipient;
        
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(BRIDGE_OPERATOR_ROLE, _admin);
    }
    
    // =============================================================================
    // IMPORT FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Import ERC-721 NFT and list on MARKETPLACE
     * @dev Creates listing in UnifiedNFTMarketplace
     * @param tokenContract Address of the ERC721 contract
     * @param tokenId ID of the token to import
     * @param listingPrice Price for the MARKETPLACE listing
     * @param metadataUri URI for token metadata
     * @param metadataHash Hash of the metadata
     * @param acceptsPrivacy Whether listing accepts privacy payments
     * @return marketplaceTokenId ID of the created MARKETPLACE listing
     */
    function importERC721(
        address tokenContract,
        uint256 tokenId,
        uint256 listingPrice,
        string calldata metadataUri,
        string calldata metadataHash,
        bool acceptsPrivacy
    ) external payable nonReentrant whenNotPaused returns (uint256 marketplaceTokenId) {
        if (msg.value < baseBridgeFee) revert InsufficientFee();
        
        // Transfer NFT to this contract
        IERC721(tokenContract).safeTransferFrom(msg.sender, address(this), tokenId);
        
        // Create listing in MARKETPLACE
        // Note: This bridge will need MINTER_ROLE on MARKETPLACE
        marketplaceTokenId = MARKETPLACE.createListing(
            listingPrice,
            UnifiedNFTMarketplace.ListingType.DIGITAL,
            metadataUri,
            metadataHash,
            30 days, // Default duration
            acceptsPrivacy
        );
        
        // Transfer MARKETPLACE NFT to original owner
        IERC721(address(MARKETPLACE)).safeTransferFrom(
            address(this), 
            msg.sender, 
            marketplaceTokenId
        );
        
        // Collect fee
        if (msg.value > 0) {
            (bool success, ) = feeRecipient.call{value: msg.value}("");
            if (!success) revert TransferFailed();
        }
        
        emit AssetImported(
            tokenContract,
            tokenId,
            msg.sender,
            marketplaceTokenId,
            metadataUri,
            1, // Amount for ERC-721
            false, // Not ERC-1155
            "local",
            block.timestamp // solhint-disable-line not-rely-on-time
        );
        
        emit BridgeFeeCollected(
            msg.sender, 
            msg.value, 
            "local", 
            block.timestamp
        ); // solhint-disable-line not-rely-on-time
    }
    
    /**
     * @notice Import ERC-1155 token and list on marketplace
     * @param tokenContract Address of the ERC1155 contract
     * @param tokenId ID of the token to import
     * @param amount Amount of tokens to import
     * @param pricePerUnit Price per unit for the listing
     * @param metadataUri URI for token metadata
     * @param metadataHash Hash of the metadata
     * @param acceptsPrivacy Whether listing accepts privacy payments
     * @return marketplaceTokenId ID of the created marketplace listing
     */
    function importERC1155(
        address tokenContract,
        uint256 tokenId,
        uint256 amount,
        uint256 pricePerUnit,
        string calldata metadataUri,
        string calldata metadataHash,
        bool acceptsPrivacy
    ) external payable nonReentrant whenNotPaused returns (uint256 marketplaceTokenId) {
        if (msg.value < baseBridgeFee) revert InsufficientFee();
        if (amount == 0) revert UnsupportedToken();
        
        // Transfer tokens to this contract
        IERC1155(tokenContract).safeTransferFrom(
            msg.sender, 
            address(this), 
            tokenId, 
            amount, 
            ""
        );
        
        // Create listing for the bundle
        marketplaceTokenId = MARKETPLACE.createListing(
            pricePerUnit * amount,
            UnifiedNFTMarketplace.ListingType.DIGITAL,
            metadataUri,
            metadataHash,
            30 days,
            acceptsPrivacy
        );
        
        // Transfer MARKETPLACE NFT to original owner
        IERC721(address(MARKETPLACE)).safeTransferFrom(
            address(this), 
            msg.sender, 
            marketplaceTokenId
        );
        
        // Collect fee
        if (msg.value > 0) {
            (bool success, ) = feeRecipient.call{value: msg.value}("");
            if (!success) revert TransferFailed();
        }
        
        emit AssetImported(
            tokenContract,
            tokenId,
            msg.sender,
            marketplaceTokenId,
            metadataUri,
            amount,
            true, // Is ERC-1155
            "local",
            block.timestamp // solhint-disable-line not-rely-on-time
        );
        
        emit BridgeFeeCollected(
            msg.sender, 
            msg.value, 
            "local", 
            block.timestamp
        ); // solhint-disable-line not-rely-on-time
    }
    
    /**
     * @notice Import cross-chain asset with merkle proof
     * @dev Validator provides proof of asset ownership on source chain
     * @param sourceChain Name of the source blockchain
     * @param originalContract Address of the original contract on source chain
     * @param originalTokenId ID of the original token
     * @param amount Amount of tokens to import
     * @param listingPrice Price for the marketplace listing
     * @param metadataUri URI for token metadata
     * @param metadataHash Hash of the metadata
     * @param proof Merkle proof of asset ownership
     * @return marketplaceTokenId ID of the created marketplace listing
     */
    function importCrossChain(
        string calldata sourceChain,
        address originalContract,
        uint256 originalTokenId,
        uint256 amount,
        uint256 listingPrice,
        string calldata metadataUri,
        string calldata metadataHash,
        bytes32[] calldata proof
    ) external payable nonReentrant whenNotPaused returns (uint256 marketplaceTokenId) {
        if (msg.value < baseBridgeFee * 2) revert InsufficientFee();
        
        // Verify cross-chain ownership via merkle proof
        bytes32 leaf = keccak256(abi.encodePacked(
            sourceChain,
            originalContract,
            originalTokenId,
            msg.sender,
            amount,
            currentEpoch
        ));
        
        if (!_verifyProof(proof, crossChainAssetsRoot, leaf)) revert InvalidProof();
        
        // Create listing
        marketplaceTokenId = MARKETPLACE.createListing(
            listingPrice,
            UnifiedNFTMarketplace.ListingType.DIGITAL,
            metadataUri,
            metadataHash,
            30 days,
            false // Cross-chain imports don't support privacy initially
        );
        
        // Mint to user (MARKETPLACE NFT represents the cross-chain asset)
        IERC721(address(MARKETPLACE)).safeTransferFrom(
            address(this), 
            msg.sender, 
            marketplaceTokenId
        );
        
        // Collect fee
        if (msg.value > 0) {
            (bool success, ) = feeRecipient.call{value: msg.value}("");
            if (!success) revert TransferFailed();
        }
        
        bytes32 importHash = keccak256(abi.encodePacked(
            sourceChain,
            originalContract,
            originalTokenId,
            amount
        ));
        
        emit CrossChainImport(
            importHash,
            msg.sender,
            sourceChain,
            leaf,
            block.timestamp // solhint-disable-line not-rely-on-time
        );
        
        emit AssetImported(
            originalContract,
            originalTokenId,
            msg.sender,
            marketplaceTokenId,
            metadataUri,
            amount,
            amount > 1, // Assume ERC-1155 if amount > 1
            sourceChain,
            block.timestamp // solhint-disable-line not-rely-on-time
        );
        
        emit BridgeFeeCollected(
            msg.sender, 
            msg.value, 
            sourceChain, 
            block.timestamp
        ); // solhint-disable-line not-rely-on-time
    }
    
    // =============================================================================
    // VERIFICATION FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Check if collection is fast-tracked for gaming
     * @param collection Address of the collection contract
     * @param proof Merkle proof for gaming collection verification
     * @return valid Whether the collection is a verified gaming collection
     */
    function isGamingCollection(
        address collection,
        bytes32[] calldata proof
    ) external view returns (bool valid) {
        bytes32 leaf = keccak256(abi.encodePacked(collection, currentEpoch));
        return _verifyProof(proof, gamingCollectionsRoot, leaf);
    }
    
    /**
     * @notice Verify cross-chain asset ownership
     * @param sourceChain Name of the source blockchain
     * @param originalContract Address of the original contract
     * @param originalTokenId ID of the original token
     * @param owner Address of the token owner
     * @param amount Amount of tokens owned
     * @param proof Merkle proof of ownership
     * @return valid Whether the ownership proof is valid
     */
    function verifyCrossChainAsset(
        string calldata sourceChain,
        address originalContract,
        uint256 originalTokenId,
        address owner,
        uint256 amount,
        bytes32[] calldata proof
    ) external view returns (bool valid) {
        bytes32 leaf = keccak256(abi.encodePacked(
            sourceChain,
            originalContract,
            originalTokenId,
            owner,
            amount,
            currentEpoch
        ));
        return _verifyProof(proof, crossChainAssetsRoot, leaf);
    }
    
    // =============================================================================
    // MERKLE ROOT UPDATES
    // =============================================================================
    
    /**
     * @notice Update cross-chain assets root
     * @param newRoot New merkle root for cross-chain assets
     * @param epoch New epoch number
     */
    function updateCrossChainRoot(
        bytes32 newRoot,
        uint256 epoch
    ) external onlyAvalancheValidator {
        if (epoch != currentEpoch + 1) revert InvalidProof();
        
        crossChainAssetsRoot = newRoot;
        lastRootUpdate = block.number;
        currentEpoch = epoch;
        
        emit RootUpdated(newRoot, "crossChain", epoch, block.timestamp); // solhint-disable-line not-rely-on-time
    }
    
    /**
     * @notice Update gaming collections root
     * @param newRoot New merkle root for gaming collections
     */
    function updateGamingCollectionsRoot(
        bytes32 newRoot
    ) external onlyAvalancheValidator {
        gamingCollectionsRoot = newRoot;
        emit RootUpdated(newRoot, "gaming", currentEpoch, block.timestamp); // solhint-disable-line not-rely-on-time
    }
    
    // =============================================================================
    // ADMIN FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Update bridge fee
     * @param _fee New bridge fee in wei
     */
    function setBridgeFee(uint256 _fee) external onlyRole(DEFAULT_ADMIN_ROLE) {
        baseBridgeFee = _fee;
    }
    
    /**
     * @notice Update fee recipient
     * @param _recipient New address to receive bridge fees
     */
    function setFeeRecipient(address _recipient) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_recipient == address(0)) revert UnsupportedToken();
        feeRecipient = _recipient;
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
    
    // =============================================================================
    // RECEIVER FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Handle ERC1155 token transfers
     * @param operator Address which called safeTransferFrom
     * @param from Address which previously owned the token
     * @param id Token ID being transferred
     * @param value Amount of tokens being transferred
     * @param data Additional data with no specified format
     * @return selector ERC1155 received selector
     */
    function onERC1155Received(
        address, /* operator */
        address, /* from */
        uint256, /* id */
        uint256, /* value */
        bytes calldata /* data */
    ) external pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }
    
    /**
     * @notice Handle batch ERC1155 token transfers
     * @param operator Address which called safeBatchTransferFrom
     * @param from Address which previously owned the tokens
     * @param ids Array of token IDs being transferred
     * @param values Array of amounts of tokens being transferred
     * @param data Additional data with no specified format
     * @return selector ERC1155 batch received selector
     */
    function onERC1155BatchReceived(
        address, /* operator */
        address, /* from */
        uint256[] calldata, /* ids */
        uint256[] calldata, /* values */
        bytes calldata /* data */
    ) external pure returns (bytes4) {
        return this.onERC1155BatchReceived.selector;
    }
    
    /**
     * @notice Handle ERC721 token transfers
     * @param operator Address which called safeTransferFrom
     * @param from Address which previously owned the token
     * @param tokenId Token ID being transferred
     * @param data Additional data with no specified format
     * @return selector ERC721 received selector
     */
    function onERC721Received(
        address, /* operator */
        address, /* from */
        uint256, /* tokenId */
        bytes calldata /* data */
    ) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
    
    // =============================================================================
    // INTERNAL FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Verify a merkle proof
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
    
    /**
     * @notice Check if address is an Avalanche validator
     * @param account Address to check
     * @return isValidator Whether the address is a validator
     */
    function _isAvalancheValidator(address account) internal view returns (bool isValidator) {
        address avalancheValidator = registry.getContract(keccak256("AVALANCHE_VALIDATOR"));
        return account == avalancheValidator;
    }
    
    /**
     * @notice Check if contract supports an interface
     * @param interfaceId Interface identifier to check
     * @return supported Whether the interface is supported
     */
    function supportsInterface(bytes4 interfaceId) 
        public 
        view 
        override(AccessControl) 
        returns (bool supported) 
    {
        return 
            interfaceId == type(IERC1155Receiver).interfaceId ||
            interfaceId == type(IERC721Receiver).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}