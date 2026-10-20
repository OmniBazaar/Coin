// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title EscrowV2Types
 * @author OmniCoin Development Team
 * @notice Shared storage struct for EscrowV2 and its linked fee-routing
 *         library.
 * @dev Declared at file level so that `EscrowV2` and `EscrowFeeRouter` refer
 *      to the SAME Solidity type: a library function can only take a
 *      `mapping(uint256 => Escrow) storage` pointer if both sides agree on the
 *      struct definition. Field order and types are the storage layout — do
 *      not reorder or resize a field.
 */
struct Escrow {
    address buyer;        // slot 1: 20 bytes
    address seller;       // slot 2: 20 bytes
    address arbitrator;   // slot 3: 20 bytes
    uint8 releaseVotes;   // slot 3: 1 byte
    uint8 refundVotes;    // slot 3: 1 byte
    bool resolved;        // slot 3: 1 byte
    bool disputed;        // slot 3: 1 byte (total: 24 bytes in slot 3)
    uint256 amount;       // slot 4: 32 bytes
    uint256 expiry;       // slot 5: 32 bytes
    uint256 createdAt;    // slot 6: 32 bytes
    // Seller-asserted delivery + inspection window (permissionless
    // seller-release path). Appended after the original fields.
    bool delivered;              // slot 7: 1 byte
    uint256 inspectionDeadline;  // slot 8: 32 bytes
    // The ERC-20 this escrow actually holds. v1 inferred it from
    // `isPrivateEscrow` (XOM or pXOM, both fixed at deploy); v2 records it
    // per escrow so any vault-allowlisted token can be escrowed.
    address token;
    // Fee-attribution nodes, recorded at creation. They receive the listing
    // slice of the 1% (0.175% listing node / 0.05% selling node) when the fee
    // goes through the vault's referral-aware split. Zero addresses route
    // their share to ODDAO.
    address listingNode;
    address sellingNode;
}
