// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @dev Minimal interface for initializing a freshly cloned collection.
interface IOmniNFTCollection {
    function initialize(
        address _owner,
        string calldata _name,
        string calldata _symbol,
        uint256 _maxSupply,
        uint96 _royaltyBps,
        address _royaltyRecipient,
        string calldata _unrevealedURI
    ) external;
}

/**
 * @title OmniNFTFactory
 * @author OmniBazaar Development Team
 * @notice Deploys ERC-1167 minimal proxy clones of OmniNFTCollection.
 * @dev Each `createCollection` call produces a new, independently-owned
 *      NFT collection at a unique address. The factory tracks all
 *      deployed collections and charges a configurable platform fee
 *      on primary sales (collected by the collection contract itself,
 *      distributed off-chain by the platform).
 */
contract OmniNFTFactory is Ownable {
    // ── Custom errors ────────────────────────────────────────────────────
    /// @dev Thrown when the implementation address is zero.
    error InvalidImplementation();
    /// @dev Thrown when the platform fee exceeds the maximum.
    error FeeTooHigh();
    /// @dev Thrown when maxSupply is zero.
    error InvalidMaxSupply();

    // ── Events ───────────────────────────────────────────────────────────
    /**
     * @notice Emitted when a new collection is deployed through the factory.
     * @param collection   The deployed clone address.
     * @param creator      The collection owner.
     * @param name         Collection name.
     * @param symbol       Collection symbol.
     * @param maxSupply    Maximum token supply.
     * @param royaltyBps   Royalty in basis points.
     */
    event CollectionCreated(
        address indexed collection,
        address indexed creator,
        string name,
        string symbol,
        uint256 maxSupply,
        uint96 royaltyBps
    );

    /// @notice Emitted when the platform fee is updated.
    event PlatformFeeUpdated(uint16 newFeeBps);
    /// @notice Emitted when the implementation address is updated.
    event ImplementationUpdated(address indexed newImplementation);

    // ── Constants ────────────────────────────────────────────────────────
    /// @notice Maximum platform fee: 10 % (1000 basis points).
    uint16 public constant MAX_PLATFORM_FEE_BPS = 1000;

    // ── Storage ──────────────────────────────────────────────────────────
    /// @notice Implementation contract address used for ERC-1167 clones.
    address public implementation;
    /// @notice Platform fee in basis points on primary sales (default 250 = 2.5%).
    uint16 public platformFeeBps;
    /// @notice Array of all deployed collection addresses.
    address[] public collections;
    /// @notice Mapping from collection address to whether it was deployed by this factory.
    mapping(address => bool) public isFactoryCollection;
    /// @notice Collections deployed by a specific creator.
    mapping(address => address[]) public creatorCollections;

    // ── Constructor ──────────────────────────────────────────────────────
    /**
     * @notice Deploy the factory with the given implementation.
     * @param _implementation OmniNFTCollection implementation address.
     */
    constructor(address _implementation) Ownable(msg.sender) {
        if (_implementation == address(0)) revert InvalidImplementation();
        implementation = _implementation;
        platformFeeBps = 250; // 2.5%
    }

    // ── Collection creation ──────────────────────────────────────────────
    /**
     * @notice Deploy a new NFT collection as a minimal proxy clone.
     * @param name             Collection name.
     * @param symbol           Collection symbol.
     * @param maxSupply        Maximum token supply.
     * @param royaltyBps       Royalty in basis points (0-2500).
     * @param royaltyRecipient Address receiving royalties.
     * @param unrevealedURI    Placeholder URI before reveal.
     * @return clone           Address of the deployed collection.
     */
    function createCollection(
        string calldata name,
        string calldata symbol,
        uint256 maxSupply,
        uint96 royaltyBps,
        address royaltyRecipient,
        string calldata unrevealedURI
    ) external returns (address clone) {
        if (maxSupply == 0) revert InvalidMaxSupply();

        clone = Clones.clone(implementation);

        IOmniNFTCollection(clone).initialize(
            msg.sender,
            name,
            symbol,
            maxSupply,
            royaltyBps,
            royaltyRecipient,
            unrevealedURI
        );

        collections.push(clone);
        isFactoryCollection[clone] = true;
        creatorCollections[msg.sender].push(clone);

        emit CollectionCreated(clone, msg.sender, name, symbol, maxSupply, royaltyBps);
    }

    // ── Admin ────────────────────────────────────────────────────────────
    /**
     * @notice Update the platform fee.
     * @param newFeeBps New fee in basis points.
     */
    function setPlatformFee(uint16 newFeeBps) external onlyOwner {
        if (newFeeBps > MAX_PLATFORM_FEE_BPS) revert FeeTooHigh();
        platformFeeBps = newFeeBps;
        emit PlatformFeeUpdated(newFeeBps);
    }

    /**
     * @notice Update the implementation contract for future clones.
     * @param _implementation New implementation address.
     */
    function setImplementation(address _implementation) external onlyOwner {
        if (_implementation == address(0)) revert InvalidImplementation();
        implementation = _implementation;
        emit ImplementationUpdated(_implementation);
    }

    // ── View helpers ─────────────────────────────────────────────────────
    /**
     * @notice Total number of collections deployed.
     * @return count Number of collections.
     */
    function totalCollections() external view returns (uint256) {
        return collections.length;
    }

    /**
     * @notice Number of collections created by a specific address.
     * @param creator Creator address.
     * @return count Number of collections.
     */
    function creatorCollectionCount(address creator) external view returns (uint256) {
        return creatorCollections[creator].length;
    }
}
