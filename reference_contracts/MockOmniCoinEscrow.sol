// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title MockOmniCoinEscrow
 * @dev Mock contract for testing OmniCoinArbitration
 */
contract MockOmniCoinEscrow {
    struct Escrow {
        address seller;
        address buyer;
        address arbitrator;
        uint256 amount;
        uint256 releaseTime;
        bool released;
        bool disputed;
        bool refunded;
    }

    mapping(bytes32 => Escrow) public escrows;

    function setEscrow(
        bytes32 escrowId,
        address seller,
        address buyer,
        uint256 amount,
        uint256 releaseTime,
        bool released,
        bool disputed,
        bool refunded,
        address arbitrator
    ) external {
        escrows[escrowId] = Escrow({
            seller: seller,
            buyer: buyer,
            arbitrator: arbitrator,
            amount: amount,
            releaseTime: releaseTime,
            released: released,
            disputed: disputed,
            refunded: refunded
        });
    }

    function getEscrow(bytes32 escrowId) external view returns (
        address seller,
        address buyer,
        address arbitrator,
        uint256 amount,
        uint256 releaseTime,
        bool released,
        bool disputed,
        bool refunded
    ) {
        Escrow memory e = escrows[escrowId];
        return (
            e.seller,
            e.buyer,
            e.arbitrator,
            e.amount,
            e.releaseTime,
            e.released,
            e.disputed,
            e.refunded
        );
    }
}