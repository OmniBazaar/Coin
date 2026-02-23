// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC2981} from
    "@openzeppelin/contracts/interfaces/IERC2981.sol";
import {IERC165} from
    "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/**
 * @title IOwnable
 * @author OmniBazaar Development Team
 * @notice Minimal interface to query collection ownership.
 * @dev Used to verify that a caller owns an NFT collection contract
 *      implementing the OpenZeppelin Ownable pattern.
 */
interface IOwnable {
    /**
     * @notice Returns the owner of the contract.
     * @return ownerAddress The owner address.
     */
    function owner() external view returns (address ownerAddress);
}

/**
 * @title OmniNFTRoyalty
 * @author OmniBazaar Development Team
 * @notice Standalone ERC-2981 royalty registry for NFT collections.
 * @dev Collection owners can register royalty information for any
 *      NFT contract that does not natively support ERC-2981. The
 *      OmniBazaar marketplace queries this registry at settlement
 *      time. Maximum royalty is capped at 25 % (2500 basis points).
 *      Delegated ERC-2981 results are also capped at 25 %.
 */
contract OmniNFTRoyalty is Ownable {
    // ── Structs ──────────────────────────────────────────────────────
    /**
     * @notice Royalty configuration for a collection.
     * @param recipient Address that receives royalty payments.
     * @param royaltyBps Royalty percentage in basis points.
     * @param registeredOwner Address that registered this entry.
     */
    struct RoyaltyInfo {
        address recipient;
        uint96 royaltyBps;
        address registeredOwner;
    }

    // ── Constants ────────────────────────────────────────────────────
    /// @notice Maximum royalty: 25 % (2500 basis points).
    uint96 public constant MAX_ROYALTY_BPS = 2500;

    // ── Storage ──────────────────────────────────────────────────────
    /// @notice Royalty info keyed by collection contract address.
    mapping(address => RoyaltyInfo) public royalties;

    /// @notice Array of all registered collection addresses.
    address[] public registeredCollections;
    /// @notice Quick lookup for whether a collection is registered.
    mapping(address => bool) public isRegistered;

    // ── Events ───────────────────────────────────────────────────────
    /// @notice Emitted when royalty info is set or updated.
    /// @param collection NFT contract address.
    /// @param recipient Royalty recipient address.
    /// @param royaltyBps Royalty percentage in basis points.
    /// @param setter Address that made the change.
    event RoyaltySet(
        address indexed collection,
        address indexed recipient,
        uint96 royaltyBps,
        address indexed setter
    );

    /// @notice Emitted when collection registry ownership changes.
    /// @param collection NFT contract address.
    /// @param oldOwner Previous registered owner.
    /// @param newOwner New registered owner.
    event CollectionOwnerUpdated(
        address indexed collection,
        address indexed oldOwner,
        address indexed newOwner
    );

    // ── Custom errors ────────────────────────────────────────────────
    /// @dev Thrown when the royalty exceeds the 25 % cap.
    error RoyaltyTooHigh();
    /// @dev Thrown when the caller is not the registered owner.
    error NotCollectionOwner();
    /// @dev Thrown when the recipient address is zero.
    error InvalidRecipient();
    /// @dev Thrown when the collection address is zero.
    error InvalidCollection();
    /// @dev Caller not collection owner; collection lacks Ownable.
    error OwnershipVerificationFailed();
    /// @dev Thrown when newOwner is the zero address.
    error InvalidNewOwner();

    // ── Constructor ──────────────────────────────────────────────────
    /// @notice Deploy the royalty registry with the caller as admin.
    constructor() Ownable(msg.sender) {}

    // ── Registration ─────────────────────────────────────────────────
    /**
     * @notice Register or update royalty info for a collection.
     * @dev First-time registration requires ownership verification
     *      via `Ownable(collection).owner()`. If the collection does
     *      not implement Ownable, only the contract admin can register.
     * @param collection NFT contract address.
     * @param recipient  Royalty recipient address.
     * @param royaltyBps Royalty in basis points (0-2500).
     */
    function setRoyalty(
        address collection,
        address recipient,
        uint96 royaltyBps
    ) external {
        if (collection == address(0)) revert InvalidCollection();
        if (royaltyBps > MAX_ROYALTY_BPS) revert RoyaltyTooHigh();
        if (recipient == address(0)) revert InvalidRecipient();

        RoyaltyInfo storage info = royalties[collection];

        // Only the registered owner or the admin can update
        if (
            info.registeredOwner != address(0)
                && info.registeredOwner != msg.sender
                && msg.sender != owner()
        ) {
            revert NotCollectionOwner();
        }

        if (!isRegistered[collection]) {
            // H-01: Verify caller owns the collection via Ownable.
            if (msg.sender != owner()) {
                _verifyCollectionOwnership(collection);
            }
            registeredCollections.push(collection);
            isRegistered[collection] = true;
            info.registeredOwner = msg.sender;
        }

        info.recipient = recipient;
        info.royaltyBps = royaltyBps;

        emit RoyaltySet(
            collection,
            recipient,
            royaltyBps,
            msg.sender
        );
    }

    /**
     * @notice Transfer registry ownership of a collection entry.
     * @param collection NFT contract address.
     * @param newOwner   New registered owner.
     */
    function transferCollectionOwnership(
        address collection,
        address newOwner
    ) external {
        if (newOwner == address(0)) revert InvalidNewOwner();
        RoyaltyInfo storage info = royalties[collection];
        if (
            info.registeredOwner != msg.sender
                && msg.sender != owner()
        ) {
            revert NotCollectionOwner();
        }
        address old = info.registeredOwner;
        info.registeredOwner = newOwner;
        emit CollectionOwnerUpdated(collection, old, newOwner);
    }

    // ── Query (ERC-2981 compatible) ──────────────────────────────────
    /**
     * @notice Query royalty info for a collection sale (ERC-2981).
     * @dev First checks if the collection supports ERC-2981. If so,
     *      delegates and caps at 25 %. Falls back to this registry.
     * @param collection NFT contract address.
     * @param tokenId    Token being sold.
     * @param salePrice  Sale price in wei.
     * @return receiver  Royalty recipient.
     * @return royaltyAmount Royalty amount in wei.
     */
    function royaltyInfo(
        address collection,
        uint256 tokenId,
        uint256 salePrice
    ) external view returns (
        address receiver,
        uint256 royaltyAmount
    ) {
        // Try on-chain ERC-2981 first (skip EOAs / precompiles)
        uint256 codeSize;
        // solhint-disable-next-line no-inline-assembly
        assembly { codeSize := extcodesize(collection) }
        if (codeSize > 0) {
            try IERC165(collection).supportsInterface(
                type(IERC2981).interfaceId
            ) returns (bool supported) {
                if (supported) {
                    // M-01: Wrap royaltyInfo in try/catch
                    try IERC2981(collection).royaltyInfo(
                        tokenId,
                        salePrice
                    ) returns (address r, uint256 amt) {
                        // H-02: Cap delegated royalty at 25 %
                        uint256 maxAmt =
                            (salePrice * MAX_ROYALTY_BPS) / 10000;
                        if (amt > maxAmt) {
                            amt = maxAmt;
                        }
                        return (r, amt);
                    } catch {
                        // royaltyInfo reverted; fall through
                    }
                }
            } catch {
                // No ERC-165 support; fall through
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

    // ── View helpers ─────────────────────────────────────────────────
    /**
     * @notice Total number of registered collections.
     * @return count Number of collections.
     */
    function totalRegistered() external view returns (uint256) {
        return registeredCollections.length;
    }

    // ── Internal helpers ─────────────────────────────────────────────
    /**
     * @notice Verify that msg.sender is the Ownable owner of a collection.
     * @dev Reverts if the collection lacks Ownable or returns a
     *      different owner. Admin can bypass this check.
     * @param collection NFT contract address.
     */
    function _verifyCollectionOwnership(
        address collection
    ) internal view {
        try IOwnable(collection).owner() returns (
            address collOwner
        ) {
            if (collOwner != msg.sender) {
                revert OwnershipVerificationFailed();
            }
        } catch {
            revert OwnershipVerificationFailed();
        }
    }
}
