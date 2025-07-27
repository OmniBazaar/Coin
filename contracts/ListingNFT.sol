// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721URIStorage} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract ListingNFT is ERC721URIStorage, Ownable, ReentrancyGuard {
    // Enums
    enum TransactionStatus {
        Pending,
        Completed,
        Cancelled
    }
    
    // Structs
    struct Transaction {
        address seller;
        address buyer;
        uint256 price;
        uint256 quantity;
        TransactionStatus status;
        string escrowId;
        uint256 createdAt;
        uint256 updatedAt;
    }
    
    // Custom errors
    error NotAuthorizedToMint();
    error ListingDoesNotExist();
    error NotListingOwner();
    error CannotBuyOwnListing();
    error NotAuthorized();
    error CannotTransferPendingTransaction();
    
    // State variables
    uint256 private _tokenIds;
    mapping(address => bool) public approvedMinters;

    // Events
    event MinterApprovalChanged(address indexed minter, bool approved);

    constructor(
        address initialOwner
    ) ERC721("OmniBazaar Listing", "OBL") Ownable(initialOwner) {
        _tokenIds = 0;
    }

    /**
     * @dev Set or revoke minter approval
     * @param minter Address to approve/revoke
     * @param approved Whether to approve or revoke
     */
    function setApprovedMinter(address minter, bool approved) external onlyOwner {
        approvedMinters[minter] = approved;
        emit MinterApprovalChanged(minter, approved);
    }

    /**
     * @dev Check if an address is an approved minter
     * @param minter Address to check
     * @return Whether the address is approved
     */
    function isApprovedMinter(address minter) public view returns (bool) {
        return approvedMinters[minter];
    }

    mapping(uint256 => Transaction) public transactions;
    mapping(address => uint256[]) public userListings;
    mapping(address => uint256[]) public userTransactions;

    event TransactionCreated(
        uint256 indexed tokenId,
        address indexed seller,
        address indexed buyer,
        uint256 price,
        uint256 quantity
    );

    event TransactionStatusChanged(
        uint256 indexed tokenId,
        address indexed seller,
        address indexed buyer,
        TransactionStatus status
    );

    function mint(address to, string memory tokenURI) public returns (uint256) {
        if (!approvedMinters[msg.sender] && msg.sender != owner())
            revert NotAuthorizedToMint();
        
        _tokenIds++;
        uint256 newTokenId = _tokenIds;

        _mint(to, newTokenId);
        _setTokenURI(newTokenId, tokenURI);

        userListings[to].push(newTokenId);

        return newTokenId;
    }

    function createTransaction(
        uint256 tokenId,
        address buyer,
        uint256 quantity,
        uint256 price
    ) public nonReentrant returns (uint256) {
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
            createdAt: block.timestamp,
            updatedAt: block.timestamp
        });

        transactions[tokenId] = newTransaction;
        userTransactions[buyer].push(tokenId);

        emit TransactionCreated(tokenId, msg.sender, buyer, price, quantity);

        return tokenId;
    }

    function updateTransactionStatus(
        uint256 tokenId,
        TransactionStatus newStatus
    ) public {
        if (_ownerOf(tokenId) == address(0)) revert ListingDoesNotExist();
        Transaction storage transaction = transactions[tokenId];
        if (msg.sender != transaction.seller && msg.sender != transaction.buyer)
            revert NotAuthorized();

        transaction.status = newStatus;
        transaction.updatedAt = block.timestamp;

        emit TransactionStatusChanged(
            tokenId,
            transaction.seller,
            transaction.buyer,
            newStatus
        );
    }

    function setEscrowId(uint256 tokenId, string memory escrowId) public {
        if (_ownerOf(tokenId) == address(0)) revert ListingDoesNotExist();
        Transaction storage transaction = transactions[tokenId];
        if (msg.sender != transaction.seller && msg.sender != transaction.buyer)
            revert NotAuthorized();

        transaction.escrowId = escrowId;
        transaction.updatedAt = block.timestamp;
    }

    function getUserListings(
        address user
    ) public view returns (uint256[] memory) {
        return userListings[user];
    }

    function getUserTransactions(
        address user
    ) public view returns (uint256[] memory) {
        return userTransactions[user];
    }

    function getTransaction(
        uint256 tokenId
    ) public view returns (Transaction memory) {
        if (_ownerOf(tokenId) == address(0)) revert ListingDoesNotExist();
        return transactions[tokenId];
    }

    function _update(
        address to,
        uint256 tokenId,
        address auth
    ) internal override returns (address) {
        address from = _ownerOf(tokenId);

        // Check if transaction is pending before transfer
        if (from != address(0) && to != address(0)) {
            if (transactions[tokenId].status == TransactionStatus.Pending)
                revert CannotTransferPendingTransaction();
        }

        return super._update(to, tokenId, auth);
    }
}
