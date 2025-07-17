// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract ListingNFT is ERC721URIStorage, Ownable, ReentrancyGuard {
    uint256 private _tokenIds;

    constructor(
        address initialOwner
    ) ERC721("OmniBazaar Listing", "OBL") Ownable(initialOwner) {
        _tokenIds = 0;
    }

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

    enum TransactionStatus {
        Pending,
        Completed,
        Cancelled
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
        require(_ownerOf(tokenId) != address(0), "Listing does not exist");
        require(ownerOf(tokenId) == msg.sender, "Not the listing owner");
        require(buyer != msg.sender, "Cannot buy your own listing");

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
        require(_ownerOf(tokenId) != address(0), "Listing does not exist");
        Transaction storage transaction = transactions[tokenId];
        require(
            msg.sender == transaction.seller || msg.sender == transaction.buyer,
            "Not authorized"
        );

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
        require(_ownerOf(tokenId) != address(0), "Listing does not exist");
        Transaction storage transaction = transactions[tokenId];
        require(
            msg.sender == transaction.seller || msg.sender == transaction.buyer,
            "Not authorized"
        );

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
        require(_ownerOf(tokenId) != address(0), "Listing does not exist");
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
            require(
                transactions[tokenId].status != TransactionStatus.Pending,
                "Cannot transfer while transaction is pending"
            );
        }

        return super._update(to, tokenId, auth);
    }
}
