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
    mapping(address => uint256) private _totalScore;

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
}
