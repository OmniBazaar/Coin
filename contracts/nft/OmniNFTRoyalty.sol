// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/**
 * @title OmniNFTRoyalty
 * @author OmniBazaar Development Team
 * @notice Standalone ERC-2981 royalty registry for non-OmniNFT collections.
 * @dev Collection owners can register royalty information for any NFT
 *      contract that does not natively support ERC-2981. The OmniBazaar
 *      marketplace queries this registry at settlement time for
 *      collections that lack on-chain royalty info.
 *
 *      Maximum royalty is capped at 25 % (2500 basis points).
 */
contract OmniNFTRoyalty is Ownable {
    // ── Custom errors ────────────────────────────────────────────────────
    /// @dev Thrown when the royalty exceeds the 25 % cap.
    error RoyaltyTooHigh();
    /// @dev Thrown when the caller is not the registered owner of the collection.
    error NotCollectionOwner();
    /// @dev Thrown when the recipient address is zero.
    error InvalidRecipient();

    // ── Events ───────────────────────────────────────────────────────────
    /// @notice Emitted when royalty info is set or updated.
    event RoyaltySet(
        address indexed collection,
        address indexed recipient,
        uint96 royaltyBps,
        address indexed setter
    );

    /// @notice Emitted when collection ownership in the registry changes.
    event CollectionOwnerUpdated(
        address indexed collection,
        address indexed oldOwner,
        address indexed newOwner
    );

    // ── Constants ────────────────────────────────────────────────────────
    /// @notice Maximum royalty: 25 % (2500 basis points).
    uint96 public constant MAX_ROYALTY_BPS = 2500;

    // ── Storage ──────────────────────────────────────────────────────────
    /**
     * @notice Royalty configuration for a collection.
     * @param recipient Address that receives royalty payments.
     * @param royaltyBps Royalty percentage in basis points.
     * @param registeredOwner Address that registered this entry (can update it).
     */
    struct RoyaltyInfo {
        address recipient;
        uint96 royaltyBps;
        address registeredOwner;
    }

    /// @notice Royalty info keyed by collection contract address.
    mapping(address => RoyaltyInfo) public royalties;

    /// @notice Array of all registered collection addresses.
    address[] public registeredCollections;
    /// @notice Quick lookup for whether a collection is registered.
    mapping(address => bool) public isRegistered;

    // ── Constructor ──────────────────────────────────────────────────────
    constructor() Ownable(msg.sender) {}

    // ── Registration ─────────────────────────────────────────────────────
    /**
     * @notice Register or update royalty info for a collection.
     * @dev The first caller to register a collection becomes its owner in
     *      this registry. Only the registered owner (or the contract admin)
     *      can update the entry afterwards.
     * @param collection   NFT contract address.
     * @param recipient    Royalty recipient address.
     * @param royaltyBps   Royalty in basis points (0-2500).
     */
    function setRoyalty(
        address collection,
        address recipient,
        uint96 royaltyBps
    ) external {
        if (royaltyBps > MAX_ROYALTY_BPS) revert RoyaltyTooHigh();
        if (recipient == address(0)) revert InvalidRecipient();

        RoyaltyInfo storage info = royalties[collection];

        // Only the registered owner or the contract admin can update
        if (info.registeredOwner != address(0)
            && info.registeredOwner != msg.sender
            && msg.sender != owner())
        {
            revert NotCollectionOwner();
        }

        if (!isRegistered[collection]) {
            registeredCollections.push(collection);
            isRegistered[collection] = true;
            info.registeredOwner = msg.sender;
        }

        info.recipient = recipient;
        info.royaltyBps = royaltyBps;

        emit RoyaltySet(collection, recipient, royaltyBps, msg.sender);
    }

    /**
     * @notice Transfer registry ownership of a collection entry.
     * @param collection NFT contract address.
     * @param newOwner   New registered owner.
     */
    function transferCollectionOwnership(address collection, address newOwner) external {
        RoyaltyInfo storage info = royalties[collection];
        if (info.registeredOwner != msg.sender && msg.sender != owner()) {
            revert NotCollectionOwner();
        }
        address old = info.registeredOwner;
        info.registeredOwner = newOwner;
        emit CollectionOwnerUpdated(collection, old, newOwner);
    }

    // ── Query (ERC-2981 compatible) ──────────────────────────────────────
    /**
     * @notice Query royalty info for a collection sale, ERC-2981 style.
     * @dev First checks if the collection itself supports ERC-2981. If so,
     *      delegates to it. Otherwise falls back to this registry.
     * @param collection  NFT contract address.
     * @param tokenId     Token being sold (forwarded to on-chain ERC-2981).
     * @param salePrice   Sale price in wei.
     * @return receiver   Royalty recipient.
     * @return royaltyAmount Royalty amount in wei.
     */
    function royaltyInfo(
        address collection,
        uint256 tokenId,
        uint256 salePrice
    ) external view returns (address receiver, uint256 royaltyAmount) {
        // Try on-chain ERC-2981 first (skip EOAs and precompiles)
        uint256 codeSize;
        // solhint-disable-next-line no-inline-assembly
        assembly { codeSize := extcodesize(collection) }
        if (codeSize > 0) {
            try IERC165(collection).supportsInterface(type(IERC2981).interfaceId)
                returns (bool supported)
            {
                if (supported) {
                    return IERC2981(collection).royaltyInfo(tokenId, salePrice);
                }
            } catch {
                // Collection does not support ERC-165 — fall through
            }
        }

        // Fallback to registry
        RoyaltyInfo storage info = royalties[collection];
        if (info.recipient == address(0) || info.royaltyBps == 0) {
            return (address(0), 0);
        }
        royaltyAmount = (salePrice * info.royaltyBps) / 10000;
        return (info.recipient, royaltyAmount);
    }

    // ── View helpers ─────────────────────────────────────────────────────
    /**
     * @notice Total number of registered collections.
     * @return count Number of collections.
     */
    function totalRegistered() external view returns (uint256) {
        return registeredCollections.length;
    }
}
