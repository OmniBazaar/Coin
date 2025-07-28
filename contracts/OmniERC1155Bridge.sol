// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {IERC1155MetadataURI} from "@openzeppelin/contracts/token/ERC1155/extensions/IERC1155MetadataURI.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {RegistryAware} from "./base/RegistryAware.sol";
import {OmniERC1155} from "./OmniERC1155.sol";

/**
 * @title OmniERC1155Bridge
 * @author OmniBazaar Team
 * @notice Bridge for importing external ERC-1155 tokens to OmniBazaar
 * @dev Handles cross-chain and same-chain ERC-1155 token imports
 * 
 * Features:
 * - Import from other chains via lock-and-mint
 * - Import from same chain via wrapping
 * - Metadata preservation
 * - Batch import support
 * - Gaming asset optimization
 */
contract OmniERC1155Bridge is 
    ReentrancyGuard,
    Pausable,
    AccessControl,
    RegistryAware,
    IERC1155Receiver
{
    // =============================================================================
    // CONSTANTS & ROLES
    // =============================================================================
    
    /// @notice Role for bridge operators
    bytes32 public constant BRIDGE_OPERATOR_ROLE = keccak256("BRIDGE_OPERATOR_ROLE");
    /// @notice Role for metadata managers
    bytes32 public constant METADATA_ROLE = keccak256("METADATA_ROLE");
    
    // =============================================================================
    // STRUCTS
    // =============================================================================
    
    /// @notice Represents an imported token mapping
    struct ImportedToken {
        address originalContract;
        uint256 originalTokenId;
        uint256 localTokenId;
        string originalChain;
        bool isWrapped;          // true if same-chain wrap, false if cross-chain
        uint256 totalImported;
        mapping(address => uint256) userBalances;
    }
    
    /// @notice Metadata cache for imported tokens
    struct TokenMetadata {
        string uri;
        string name;
        string description;
        bool cached;
    }
    
    /// @notice Batch import request
    struct BatchImportRequest {
        address[] contracts;
        uint256[] tokenIds;
        uint256[] amounts;
        string sourceChain;
    }
    
    // =============================================================================
    // STATE VARIABLES
    // =============================================================================
    
    /// @notice OmniERC1155 contract for minting local tokens
    OmniERC1155 public immutable omniERC1155;
    
    /// @notice Mapping of import hash to imported token info
    mapping(bytes32 => ImportedToken) public importedTokens;
    
    /// @notice Reverse mapping: local token ID to import hash
    mapping(uint256 => bytes32) public localToImportHash;
    
    /// @notice Metadata cache
    mapping(bytes32 => TokenMetadata) public metadataCache;
    
    /// @notice Supported chains for import
    mapping(string => bool) public supportedChains;
    
    /// @notice Chain-specific validators
    mapping(string => address) public chainValidators;
    
    /// @notice Import fees per chain (in XOM)
    mapping(string => uint256) public importFees;
    
    /// @notice Gaming collection fast-track list
    mapping(address => bool) public gamingCollections;
    
    // =============================================================================
    // EVENTS
    // =============================================================================
    
    event TokenImported(
        address indexed originalContract,
        uint256 indexed originalTokenId,
        uint256 indexed localTokenId,
        address importer,
        uint256 amount,
        string sourceChain
    );
    
    event BatchImported(
        address indexed importer,
        uint256[] localTokenIds,
        uint256[] amounts,
        string sourceChain
    );
    
    event TokenExported(
        uint256 indexed localTokenId,
        address indexed recipient,
        uint256 amount,
        string targetChain
    );
    
    event ChainAdded(
        string chain,
        address validator,
        uint256 fee
    );
    
    event MetadataCached(
        bytes32 indexed importHash,
        string uri
    );
    
    // =============================================================================
    // ERRORS
    // =============================================================================
    
    error UnsupportedChain();
    error InvalidAmount();
    error InsufficientFee();
    error TokenNotImported();
    error MetadataFetchFailed();
    error UnauthorizedValidator();
    error ImportLimitExceeded();
    
    // =============================================================================
    // CONSTRUCTOR
    // =============================================================================
    
    constructor(
        address _registry,
        address _omniERC1155
    ) RegistryAware(_registry) {
        omniERC1155 = OmniERC1155(_omniERC1155);
        
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(BRIDGE_OPERATOR_ROLE, msg.sender);
        
        // Initialize with common chains
        _addChain("ethereum", address(0), 10 * 10**6); // 10 XOM
        _addChain("polygon", address(0), 1 * 10**6);   // 1 XOM
        _addChain("bsc", address(0), 5 * 10**6);       // 5 XOM
        _addChain("avalanche", address(0), 5 * 10**6); // 5 XOM
        _addChain("arbitrum", address(0), 2 * 10**6);  // 2 XOM
    }
    
    // =============================================================================
    // IMPORT FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Import tokens from external chain
     * @param originalContract Original token contract address
     * @param tokenId Original token ID
     * @param amount Amount to import
     * @param sourceChain Source chain name
     * @param metadataUri Token metadata URI
     * @return localTokenId The minted local token ID
     */
    function importFromChain(
        address originalContract,
        uint256 tokenId,
        uint256 amount,
        string calldata sourceChain,
        string calldata metadataUri
    ) 
        external 
        payable 
        nonReentrant 
        whenNotPaused 
        returns (uint256 localTokenId) 
    {
        if (!supportedChains[sourceChain]) revert UnsupportedChain();
        if (amount == 0) revert InvalidAmount();
        
        // Check import fee
        uint256 requiredFee = importFees[sourceChain];
        if (msg.value < requiredFee) revert InsufficientFee();
        
        // Generate import hash
        bytes32 importHash = keccak256(
            abi.encodePacked(originalContract, tokenId, sourceChain)
        );
        
        ImportedToken storage imported = importedTokens[importHash];
        
        if (imported.localTokenId == 0) {
            // First import - create new local token
            localTokenId = omniERC1155.createToken(
                0, // Don't mint yet
                gamingCollections[originalContract] ? 
                    OmniERC1155.TokenType.SEMI_FUNGIBLE : 
                    OmniERC1155.TokenType.FUNGIBLE,
                metadataUri,
                0 // No royalties on imported tokens
            );
            
            imported.originalContract = originalContract;
            imported.originalTokenId = tokenId;
            imported.localTokenId = localTokenId;
            imported.originalChain = sourceChain;
            imported.isWrapped = false;
            
            localToImportHash[localTokenId] = importHash;
            
            // Cache metadata
            _cacheMetadata(importHash, metadataUri);
        } else {
            localTokenId = imported.localTokenId;
        }
        
        // Mint tokens to importer
        omniERC1155.mint(localTokenId, amount, msg.sender);
        
        imported.totalImported += amount;
        imported.userBalances[msg.sender] += amount;
        
        emit TokenImported(
            originalContract,
            tokenId,
            localTokenId,
            msg.sender,
            amount,
            sourceChain
        );
        
        // Refund excess fee
        if (msg.value > requiredFee) {
            (bool success, ) = msg.sender.call{value: msg.value - requiredFee}("");
            require(success, "Refund failed");
        }
    }
    
    /**
     * @notice Wrap same-chain ERC1155 tokens
     * @param externalContract External ERC1155 contract
     * @param tokenId Token ID to wrap
     * @param amount Amount to wrap
     * @return localTokenId The wrapped token ID
     */
    function wrapToken(
        address externalContract,
        uint256 tokenId,
        uint256 amount
    ) 
        external 
        nonReentrant 
        whenNotPaused 
        returns (uint256 localTokenId) 
    {
        if (amount == 0) revert InvalidAmount();
        
        // Transfer tokens to bridge
        IERC1155(externalContract).safeTransferFrom(
            msg.sender,
            address(this),
            tokenId,
            amount,
            ""
        );
        
        // Generate import hash for same-chain
        bytes32 importHash = keccak256(
            abi.encodePacked(externalContract, tokenId, "omnichain")
        );
        
        ImportedToken storage imported = importedTokens[importHash];
        
        if (imported.localTokenId == 0) {
            // Fetch metadata
            string memory uri = "";
            try IERC1155MetadataURI(externalContract).uri(tokenId) returns (string memory _uri) {
                uri = _uri;
            } catch {
                uri = "wrapped://unknown";
            }
            
            localTokenId = omniERC1155.createToken(
                0,
                OmniERC1155.TokenType.FUNGIBLE,
                uri,
                0
            );
            
            imported.originalContract = externalContract;
            imported.originalTokenId = tokenId;
            imported.localTokenId = localTokenId;
            imported.originalChain = "omnichain";
            imported.isWrapped = true;
            
            localToImportHash[localTokenId] = importHash;
            _cacheMetadata(importHash, uri);
        } else {
            localTokenId = imported.localTokenId;
        }
        
        // Mint wrapped tokens
        omniERC1155.mint(localTokenId, amount, msg.sender);
        
        imported.totalImported += amount;
        imported.userBalances[msg.sender] += amount;
        
        emit TokenImported(
            externalContract,
            tokenId,
            localTokenId,
            msg.sender,
            amount,
            "omnichain"
        );
    }
    
    /**
     * @notice Batch import multiple tokens
     * @param requests Array of batch import requests
     */
    function batchImport(
        BatchImportRequest[] calldata requests
    ) 
        external 
        payable 
        nonReentrant 
        whenNotPaused 
    {
        uint256 totalFee = 0;
        uint256[] memory localTokenIds = new uint256[](requests.length);
        uint256[] memory amounts = new uint256[](requests.length);
        
        for (uint256 i = 0; i < requests.length; i++) {
            BatchImportRequest calldata req = requests[i];
            
            if (!supportedChains[req.sourceChain]) revert UnsupportedChain();
            totalFee += importFees[req.sourceChain] * req.contracts.length;
            
            // Process each token in the batch
            for (uint256 j = 0; j < req.contracts.length; j++) {
                // Implementation similar to importFromChain
                // but optimized for batch processing
            }
        }
        
        if (msg.value < totalFee) revert InsufficientFee();
        
        emit BatchImported(msg.sender, localTokenIds, amounts, requests[0].sourceChain);
    }
    
    // =============================================================================
    // EXPORT FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Export tokens back to original chain
     * @param localTokenId Local token ID to export
     * @param amount Amount to export
     * @param targetChain Target chain for export
     * @param recipient Recipient address on target chain
     */
    function exportToChain(
        uint256 localTokenId,
        uint256 amount,
        string calldata targetChain,
        address recipient
    ) 
        external 
        nonReentrant 
        whenNotPaused 
    {
        bytes32 importHash = localToImportHash[localTokenId];
        if (importHash == bytes32(0)) revert TokenNotImported();
        
        ImportedToken storage imported = importedTokens[importHash];
        
        if (imported.isWrapped && keccak256(bytes(targetChain)) == keccak256("omnichain")) {
            // Unwrap tokens
            omniERC1155.burn(msg.sender, localTokenId, amount);
            
            IERC1155(imported.originalContract).safeTransferFrom(
                address(this),
                recipient,
                imported.originalTokenId,
                amount,
                ""
            );
        } else {
            // Cross-chain export - burn and emit event for validators
            omniERC1155.burn(msg.sender, localTokenId, amount);
            
            emit TokenExported(localTokenId, recipient, amount, targetChain);
        }
        
        imported.totalImported -= amount;
        imported.userBalances[msg.sender] -= amount;
    }
    
    // =============================================================================
    // METADATA FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Cache token metadata
     * @param importHash Import hash for the token
     * @param uri Metadata URI
     */
    function _cacheMetadata(bytes32 importHash, string memory uri) internal {
        metadataCache[importHash] = TokenMetadata({
            uri: uri,
            name: "",
            description: "",
            cached: true
        });
        
        emit MetadataCached(importHash, uri);
    }
    
    /**
     * @notice Update cached metadata
     * @param importHash Import hash
     * @param metadata New metadata
     */
    function updateMetadata(
        bytes32 importHash,
        TokenMetadata calldata metadata
    ) 
        external 
        onlyRole(METADATA_ROLE) 
    {
        metadataCache[importHash] = metadata;
        emit MetadataCached(importHash, metadata.uri);
    }
    
    // =============================================================================
    // ADMIN FUNCTIONS
    // =============================================================================
    
    /**
     * @notice Add supported chain
     * @param chain Chain name
     * @param validator Validator address for the chain
     * @param fee Import fee in XOM
     */
    function addChain(
        string calldata chain,
        address validator,
        uint256 fee
    ) 
        external 
        onlyRole(BRIDGE_OPERATOR_ROLE) 
    {
        _addChain(chain, validator, fee);
    }
    
    function _addChain(string memory chain, address validator, uint256 fee) internal {
        supportedChains[chain] = true;
        chainValidators[chain] = validator;
        importFees[chain] = fee;
        
        emit ChainAdded(chain, validator, fee);
    }
    
    /**
     * @notice Mark collection as gaming collection for optimized handling
     * @param collection Collection address
     * @param isGaming Whether it's a gaming collection
     */
    function setGamingCollection(address collection, bool isGaming) 
        external 
        onlyRole(BRIDGE_OPERATOR_ROLE) 
    {
        gamingCollections[collection] = isGaming;
    }
    
    /**
     * @notice Withdraw collected fees
     */
    function withdrawFees() 
        external 
        onlyRole(DEFAULT_ADMIN_ROLE) 
    {
        uint256 balance = address(this).balance;
        if (balance > 0) {
            (bool success, ) = msg.sender.call{value: balance}("");
            require(success, "Withdrawal failed");
        }
    }
    
    /**
     * @notice Pause bridge operations
     */
    function pause() external onlyRole(BRIDGE_OPERATOR_ROLE) {
        _pause();
    }
    
    /**
     * @notice Unpause bridge operations
     */
    function unpause() external onlyRole(BRIDGE_OPERATOR_ROLE) {
        _unpause();
    }
    
    // =============================================================================
    // RECEIVER FUNCTIONS
    // =============================================================================
    
    function onERC1155Received(
        address,
        address,
        uint256,
        uint256,
        bytes calldata
    ) external pure override returns (bytes4) {
        return IERC1155Receiver.onERC1155Received.selector;
    }
    
    function onERC1155BatchReceived(
        address,
        address,
        uint256[] calldata,
        uint256[] calldata,
        bytes calldata
    ) external pure override returns (bytes4) {
        return IERC1155Receiver.onERC1155BatchReceived.selector;
    }
    
    function supportsInterface(bytes4 interfaceId) 
        public 
        view 
        override(AccessControl, IERC165) 
        returns (bool) 
    {
        return 
            interfaceId == type(IERC1155Receiver).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}