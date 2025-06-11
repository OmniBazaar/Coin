// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract ListingNFT is ERC721URIStorage, Ownable, ReentrancyGuard {
    using Counters for Counters.Counter;
    Counters.Counter private _tokenIds;

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

    enum TransactionStatus { Pending, Completed, Cancelled }

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

    constructor() ERC721("OmniBazaar Listing", "OBL") {}

    function mint(address to, string memory tokenURI) public returns (uint256) {
        _tokenIds.increment();
        uint256 newTokenId = _tokenIds.current();

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
        require(_exists(tokenId), "Listing does not exist");
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
        require(_exists(tokenId), "Listing does not exist");
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
        require(_exists(tokenId), "Listing does not exist");
        Transaction storage transaction = transactions[tokenId];
        require(
            msg.sender == transaction.seller || msg.sender == transaction.buyer,
            "Not authorized"
        );

        transaction.escrowId = escrowId;
        transaction.updatedAt = block.timestamp;
    }

    function getUserListings(address user) public view returns (uint256[] memory) {
        return userListings[user];
    }

    function getUserTransactions(address user) public view returns (uint256[] memory) {
        return userTransactions[user];
    }

    function getTransaction(uint256 tokenId) public view returns (Transaction memory) {
        require(_exists(tokenId), "Listing does not exist");
        return transactions[tokenId];
    }

    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 tokenId
    ) internal virtual override {
        super._beforeTokenTransfer(from, to, tokenId);
        require(
            transactions[tokenId].status != TransactionStatus.Pending,
            "Cannot transfer while transaction is pending"
        );
    }
} 