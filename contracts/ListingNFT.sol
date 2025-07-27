// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721URIStorage} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title ListingNFT
 * @author OmniCoin Development Team
 * @notice NFT contract for OmniBazaar marketplace listings
 * @dev ERC721 implementation with transaction management and escrow integration
 */
contract ListingNFT is ERC721URIStorage, Ownable, ReentrancyGuard {
    // =============================================================================
    // ENUMS & STRUCTS
    // =============================================================================
    
    enum TransactionStatus {
        Pending,
        Completed,
        Cancelled
    }
    
    struct Transaction {
        address seller;
        address buyer;
        uint256 price;
        uint256 quantity;
        TransactionStatus status;
        string escrowId;
        uint256 createdAt;  // Time tracking required for transaction history
        uint256 updatedAt;  // Time tracking required for transaction updates
    }
    
    // =============================================================================
    // STATE VARIABLES
    // =============================================================================
    
    /// @notice Current token ID counter
    uint256 private _tokenIds;
    
    /// @notice Mapping of approved minter addresses
    mapping(address => bool) public approvedMinters;
    
    /// @notice Mapping of token ID to transaction details
    mapping(uint256 => Transaction) public transactions;
    
    /// @notice Mapping of user address to their listing token IDs
    mapping(address => uint256[]) public userListings;
    
    /// @notice Mapping of user address to their transaction token IDs
    mapping(address => uint256[]) public userTransactions;
    
    // =============================================================================
    // CUSTOM ERRORS
    // =============================================================================
    
    error NotAuthorizedToMint();
    error ListingDoesNotExist();
    error NotListingOwner();
    error CannotBuyOwnListing();
    error NotAuthorized();
    error CannotTransferPendingTransaction();

    // =============================================================================
    // EVENTS
    // =============================================================================
    
    /**
     * @notice Emitted when minter approval status changes
     * @param minter Address of the minter
     * @param approved Whether the minter is approved
     */
    event MinterApprovalChanged(address indexed minter, bool indexed approved);

    /**
     * @notice Initialize the ListingNFT contract
     * @param initialOwner Address to be granted ownership
     */
    constructor(
        address initialOwner
    ) ERC721("OmniBazaar Listing", "OBL") Ownable(initialOwner) {
        _tokenIds = 0;
    }

    /**
     * @notice Set or revoke minter approval
     * @dev Only owner can approve minters
     * @param minter Address to approve/revoke
     * @param approved Whether to approve or revoke
     */
    function setApprovedMinter(address minter, bool approved) external onlyOwner {
        approvedMinters[minter] = approved;
        emit MinterApprovalChanged(minter, approved);
    }

    /**
     * @notice Check if an address is an approved minter
     * @param minter Address to check
     * @return approved Whether the address is approved
     */
    function isApprovedMinter(address minter) public view returns (bool approved) {
        return approvedMinters[minter];
    }

    /**
     * @notice Emitted when a new transaction is created
     * @param tokenId The NFT token ID
     * @param seller Address of the seller
     * @param buyer Address of the buyer
     * @param price Transaction price
     * @param quantity Number of items (always 1 for NFTs)
     */
    event TransactionCreated(
        uint256 indexed tokenId,
        address indexed seller,
        address indexed buyer,
        uint256 price,
        uint256 quantity
    );

    /**
     * @notice Emitted when transaction status changes
     * @param tokenId The NFT token ID
     * @param seller Address of the seller
     * @param buyer Address of the buyer
     * @param status New transaction status
     */
    event TransactionStatusChanged(
        uint256 indexed tokenId,
        address indexed seller,
        address indexed buyer,
        TransactionStatus status
    );

    /**
     * @notice Mint a new listing NFT
     * @dev Only approved minters or owner can mint
     * @param to Address to receive the NFT
     * @param tokenURI Metadata URI for the listing
     * @return tokenId The newly minted token ID
     */
    function mint(address to, string memory tokenURI) public returns (uint256 tokenId) {
        if (!approvedMinters[msg.sender] && msg.sender != owner())
            revert NotAuthorizedToMint();
        
        ++_tokenIds;
        uint256 newTokenId = _tokenIds;

        _mint(to, newTokenId);
        _setTokenURI(newTokenId, tokenURI);

        userListings[to].push(newTokenId);

        return newTokenId;
    }

    /**
     * @notice Create a new transaction for a listing
     * @dev Only the token owner can create a transaction
     * @param tokenId The NFT token ID
     * @param buyer Address of the buyer
     * @param quantity Number of items (always 1 for NFTs)
     * @param price Transaction price in wei
     * @return transactionId The token ID (same as input)
     */
    function createTransaction(
        uint256 tokenId,
        address buyer,
        uint256 quantity,
        uint256 price
    ) public nonReentrant returns (uint256 transactionId) {
        if (_ownerOf(tokenId) == address(0)) revert ListingDoesNotExist();
        if (ownerOf(tokenId) != msg.sender) revert NotListingOwner();
        if (buyer == msg.sender) revert CannotBuyOwnListing();

        Transaction memory newTransaction = Transaction({
            seller: msg.sender,
            buyer: buyer,
            price: price,
            quantity: quantity,
            status: TransactionStatus.Pending,
            escrowId: "",
            createdAt: block.timestamp,  // Time tracking required for transaction history
            updatedAt: block.timestamp  // Time tracking required for transaction updates
        });

        transactions[tokenId] = newTransaction;
        userTransactions[buyer].push(tokenId);

        emit TransactionCreated(tokenId, msg.sender, buyer, price, quantity);

        return tokenId;
    }

    /**
     * @notice Update the status of a transaction
     * @dev Only seller or buyer can update status
     * @param tokenId The NFT token ID
     * @param newStatus New status to set
     */
    function updateTransactionStatus(
        uint256 tokenId,
        TransactionStatus newStatus
    ) public {
        if (_ownerOf(tokenId) == address(0)) revert ListingDoesNotExist();
        Transaction storage transaction = transactions[tokenId];
        if (msg.sender != transaction.seller && msg.sender != transaction.buyer)
            revert NotAuthorized();

        transaction.status = newStatus;
        transaction.updatedAt = block.timestamp;  // Time tracking required for transaction updates

        emit TransactionStatusChanged(
            tokenId,
            transaction.seller,
            transaction.buyer,
            newStatus
        );
    }

    /**
     * @notice Set the escrow ID for a transaction
     * @dev Only seller or buyer can set escrow ID
     * @param tokenId The NFT token ID
     * @param escrowId The escrow contract ID
     */
    function setEscrowId(uint256 tokenId, string memory escrowId) public {
        if (_ownerOf(tokenId) == address(0)) revert ListingDoesNotExist();
        Transaction storage transaction = transactions[tokenId];
        if (msg.sender != transaction.seller && msg.sender != transaction.buyer)
            revert NotAuthorized();

        transaction.escrowId = escrowId;
        transaction.updatedAt = block.timestamp;  // Time tracking required for transaction updates
    }

    /**
     * @notice Get all listing token IDs for a user
     * @param user Address of the user
     * @return listings Array of token IDs owned by the user
     */
    function getUserListings(
        address user
    ) public view returns (uint256[] memory listings) {
        return userListings[user];
    }

    /**
     * @notice Get all transaction token IDs for a user
     * @param user Address of the user
     * @return transactionIds Array of token IDs where user is buyer
     */
    function getUserTransactions(
        address user
    ) public view returns (uint256[] memory transactionIds) {
        return userTransactions[user];
    }

    /**
     * @notice Get transaction details for a token
     * @param tokenId The NFT token ID
     * @return transaction Transaction details
     */
    function getTransaction(
        uint256 tokenId
    ) public view returns (Transaction memory transaction) {
        if (_ownerOf(tokenId) == address(0)) revert ListingDoesNotExist();
        return transactions[tokenId];
    }

    /**
     * @notice Override transfer to prevent transfers during pending transactions
     * @dev Checks transaction status before allowing transfer
     * @param to Destination address
     * @param tokenId Token to transfer
     * @param auth Authorized address making the transfer
     * @return from Previous owner address
     */
    function _update(
        address to,
        uint256 tokenId,
        address auth
    ) internal override returns (address from) {
        from = _ownerOf(tokenId);

        // Check if transaction is pending before transfer
        if (from != address(0) && to != address(0)) {
            if (transactions[tokenId].status == TransactionStatus.Pending)
                revert CannotTransferPendingTransaction();
        }

        return super._update(to, tokenId, auth);
    }
}
