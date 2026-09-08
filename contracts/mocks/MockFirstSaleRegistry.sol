// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title MockFirstSaleRegistry
 * @author OmniCoin Development Team
 * @notice Minimal stand-in for OmniRegistration's first-sale recorder surface,
 *         used to test {MinimalEscrow._recordFirstSale} wiring in isolation.
 * @dev Implements only the two methods MinimalEscrow calls. Records the last
 *      call's arguments and a call counter so tests can assert the escrow
 *      bridged the sale; `shouldRevert` simulates a non-qualifying sale
 *      (anti-Sybil revert) to verify settlement is not rolled back.
 */
contract MockFirstSaleRegistry {
    /// @notice Per-seller first-sale completion flag.
    mapping(address => bool) public completed;
    /// @notice Number of times {markFirstSaleCompleted} was invoked.
    uint256 public callCount;
    /// @notice Seller from the most recent {markFirstSaleCompleted} call.
    address public lastSeller;
    /// @notice Sale amount from the most recent {markFirstSaleCompleted} call.
    uint256 public lastAmount;
    /// @notice Buyer from the most recent {markFirstSaleCompleted} call.
    address public lastBuyer;
    /// @notice When true, {markFirstSaleCompleted} reverts (non-qualifying sale).
    bool public shouldRevert;

    /// @notice Thrown when {markFirstSaleCompleted} is configured to revert.
    error FirstSaleRequirementsNotMet();

    /**
     * @notice Set the revert behavior of {markFirstSaleCompleted}.
     * @param value True to make the recorder revert.
     */
    function setShouldRevert(bool value) external {
        shouldRevert = value;
    }

    /**
     * @notice Pre-mark a seller as having completed a first sale.
     * @param seller The seller to mark.
     */
    function setCompleted(address seller) external {
        completed[seller] = true;
    }

    /**
     * @notice OmniRegistration-compatible first-sale eligibility read.
     * @param user The seller address.
     * @return True if the seller already has a first sale recorded.
     */
    function hasCompletedFirstSale(address user) external view returns (bool) {
        return completed[user];
    }

    /**
     * @notice OmniRegistration-compatible first-sale recorder.
     * @param seller The seller who completed the sale.
     * @param saleAmount The gross sale amount.
     * @param buyer The buyer in the transaction.
     */
    function markFirstSaleCompleted(
        address seller,
        uint256 saleAmount,
        address buyer
    ) external {
        if (shouldRevert) {
            revert FirstSaleRequirementsNotMet();
        }
        callCount += 1;
        lastSeller = seller;
        lastAmount = saleAmount;
        lastBuyer = buyer;
        completed[seller] = true;
    }
}
