// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title MockArbitrationParticipation
 * @author OmniBazaar Team
 * @notice Mock OmniParticipation for OmniArbitration tests
 * @dev Allows setting qualification status per address
 */
contract MockArbitrationParticipation {
    mapping(address => bool) private _canBeValidator;
    mapping(address => bool) private _canBeServiceNode;
    mapping(address => uint256) private _totalScore;

    /**
     * @notice Set service-node (== listing-node) eligibility for an address
     * @param user Address to configure
     * @param status True if qualified
     */
    function setCanBeServiceNode(address user, bool status) external {
        _canBeServiceNode[user] = status;
    }

    /**
     * @notice Set whether an address can be a validator
     * @param user Address to configure
     * @param status True if qualified
     */
    function setCanBeValidator(address user, bool status) external {
        _canBeValidator[user] = status;
    }

    /**
     * @notice Set total participation score
     * @param user Address to configure
     * @param score Score (0-100)
     */
    function setTotalScore(address user, uint256 score) external {
        _totalScore[user] = score;
    }

    /**
     * @notice Check if user can be a validator
     * @param user Address to check
     * @return True if qualified
     */
    function canBeValidator(
        address user
    ) external view returns (bool) {
        return _canBeValidator[user];
    }

    /**
     * @notice Check if user can be a service node
     * @dev The arbitration contract gates registration on THIS standard
     *      (founder ruling 2026-10-20). The separate validator flag is kept so
     *      tests can prove the two are not interchangeable.
     * @param user Address to check
     * @return True if qualified
     */
    function canBeServiceNode(
        address user
    ) external view returns (bool) {
        return _canBeServiceNode[user];
    }

    /**
     * @notice Get total participation score
     * @param user Address to check
     * @return Total score
     */
    function getTotalScore(
        address user
    ) external view returns (uint256) {
        return _totalScore[user];
    }
}

/**
 * @title MockArbitrationEscrow
 * @author OmniBazaar Team
 * @notice Mock escrow contract for OmniArbitration tests
 * @dev Allows setting buyer/seller/amount per escrow ID
 */
contract MockArbitrationEscrow {
    struct EscrowData {
        address buyer;
        address seller;
        uint256 amount;
    }

    mapping(uint256 => EscrowData) private _escrows;

    /// @notice Records escrows marked disputed via {markDisputed}
    /// @dev Lets tests assert that OmniArbitration.createDispute invoked the
    ///      escrow's markDisputed hook (the refund-race fix wiring).
    mapping(uint256 => bool) public disputed;

    /**
     * @notice Configure a mock escrow
     * @param escrowId Escrow ID
     * @param buyer Buyer address
     * @param seller Seller address
     * @param amount Escrow amount
     */
    function setEscrow(
        uint256 escrowId,
        address buyer,
        address seller,
        uint256 amount
    ) external {
        _escrows[escrowId] = EscrowData(buyer, seller, amount);
    }

    /**
     * @notice Mock of MinimalEscrow.markDisputed — records the flag
     * @dev OmniArbitration.createDispute calls this on every dispute open.
     *      The mock simply records it so tests can assert the wiring fired.
     * @param escrowId Escrow ID being marked disputed
     */
    function markDisputed(uint256 escrowId) external {
        disputed[escrowId] = true;
    }

    /**
     * @notice Mock of EscrowV2.unmarkDisputed — clears the recorded flag
     * @param escrowId Escrow ID to unmark
     */
    function unmarkDisputed(uint256 escrowId) external {
        disputed[escrowId] = false;
    }

    /**
     * @notice Get escrow buyer address
     * @param escrowId Escrow ID
     * @return Buyer address
     */
    function getBuyer(
        uint256 escrowId
    ) external view returns (address) {
        return _escrows[escrowId].buyer;
    }

    /**
     * @notice Get escrow seller address
     * @param escrowId Escrow ID
     * @return Seller address
     */
    function getSeller(
        uint256 escrowId
    ) external view returns (address) {
        return _escrows[escrowId].seller;
    }

    /**
     * @notice Get escrow amount
     * @param escrowId Escrow ID
     * @return Amount in XOM
     */
    function getAmount(
        uint256 escrowId
    ) external view returns (uint256) {
        return _escrows[escrowId].amount;
    }

    /// @notice Records escrows resolved via {resolveDispute}.
    mapping(uint256 => bool) public resolved;

    /// @notice When true, {resolveDispute} reverts — lets tests exercise the
    ///         atomic revert-propagation of OmniArbitration's terminal paths
    ///         (the verdict must NOT finalize if the fund-move reverts).
    bool public resolveShouldRevert;

    /// @notice Emitted when {resolveDispute} records an outcome.
    /// @param escrowId Escrow ID resolved.
    /// @param releaseFunds True = release to seller, false = refund buyer.
    event Resolved(uint256 indexed escrowId, bool releaseFunds);

    /**
     * @notice Toggle whether {resolveDispute} reverts (test control).
     * @param value True to make resolveDispute revert.
     */
    function setResolveShouldRevert(bool value) external {
        resolveShouldRevert = value;
    }

    /**
     * @notice Mock of MinimalEscrow.resolveDispute — records the outcome.
     * @dev OmniArbitration._triggerEscrowResolution now calls this directly
     *      (non-swallowed) as the LAST step of every terminal path, so a
     *      revert here reverts the whole verdict tx. Success is the norm.
     * @param escrowId Escrow ID being resolved.
     * @param releaseFunds True = release to seller, false = refund buyer.
     */
    function resolveDispute(uint256 escrowId, bool releaseFunds) external {
        if (resolveShouldRevert) revert("mock: resolveDispute reverted");
        resolved[escrowId] = true;
        emit Resolved(escrowId, releaseFunds);
    }
}
