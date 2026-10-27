// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title EscrowV2Types
 * @author OmniCoin Development Team
 * @notice Shared structs for EscrowV2 and its linked libraries.
 * @dev Declared at file level so that `EscrowV2` and `EscrowFeeRouter` refer
 *      to the SAME Solidity type: a library function can only take a
 *      `mapping(uint256 => Escrow) storage` pointer if both sides agree on the
 *      struct definition. `Escrow` field order and types are the storage
 *      layout — do not reorder or resize a field.
 */
/**
 * @notice The four fee-attribution recipients an escrow can claim at
 *         creation, plus the escrow-specific records
 * @dev Grouped into a memory struct so the fee-splitting library call stays
 *      within the EVM's stack limit (`FeeAttribution` replaces four separate
 *      address arguments).
 */
struct FeeAttribution {
    address referrer;    // primary referrer (zero → ODDAO)
    address referrer2;   // second-level referrer (zero → ODDAO)
    address listingNode; // node that hosted the listing (zero → ODDAO)
    address sellingNode; // node that served the sale (zero → ODDAO)
}

/**
 * @notice The three protocol-owned recipients of the in-kind 1% split
 * @dev Set at deploy. The escrow pays its own chain's fee in the sale token
 *      (referential recipients included), so it needs the local addresses of
 *      the ODDAO, staking-pool and treasury sinks — it no longer reads a
 *      cross-chain fee vault.
 */
struct FeeBeneficiaries {
    address oddao;
    address stakingPool;
    address treasury;
}

/**
 * @notice Recorded state of one escrowed sale
 */
struct Escrow {
    address buyer;        // slot 0: 20 bytes
    address seller;       // slot 1: 20 bytes
    bool resolved;        // slot 2: 1 byte
    bool disputed;        // slot 2: 1 byte
    bool delivered;       // slot 2: 1 byte
    uint256 amount;       // slot 3: 32 bytes
    uint256 expiry;       // slot 4: 32 bytes
    uint256 createdAt;    // slot 5: 32 bytes
    uint256 inspectionDeadline; // slot 6: 32 bytes
    // The ERC-20 this escrow actually holds.
    address token;        // slot 7: 20 bytes
    address listingNode;  // slot 8: 20 bytes
    address sellingNode;  // slot 9: 20 bytes
    // When a party froze the escrow for the judge panel (0 = never) and the
    // arbitration fee snapshotted at that moment, in the escrow's own token.
    // The timeout uses the timestamp to decide whether a delivery assertion
    // predates the freeze; the fee is what the filer was shown, so a later
    // parameter change cannot alter what this case costs.
    uint128 disputeOpenedAt; // slot 10: 16 bytes
    uint128 disputeFee;      // slot 10: 16 bytes
}
