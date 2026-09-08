// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {
    PrivateMarketplaceEscrow
} from "../privacy/PrivateMarketplaceEscrow.sol";
import {
    ctUint256,
    ctUint128
} from "../coti-helium/utils/mpc/MpcCore.sol";

/**
 * @title TestPrivateMarketplaceEscrow
 * @author OmniBazaar Development Team
 * @notice Test-only child of {PrivateMarketplaceEscrow} exposing the internal
 *         committee dispute-resolution authorisation so the Hardhat suite can
 *         exercise it directly — the production settlement it guards runs
 *         through the COTI MPC precompile, which is unavailable under Hardhat.
 *         Proving the AUTHORISATION (committee-attested, no deployer key) is
 *         the whole point of {resolveDisputeWithCommittee}; the encrypted
 *         payout math is proven separately on COTI testnet (per `Coin/CLAUDE.md`).
 * @dev NOT for production deploy.
 */
contract TestPrivateMarketplaceEscrow is PrivateMarketplaceEscrow {
    /**
     * @notice Seed a DISPUTED escrow record directly (bypassing the MPC
     *         custody pull in {createEscrow}) so committee-resolution
     *         authorisation can be driven end-to-end on Hardhat. The seeded
     *         `encPrice` is a zero ciphertext; any settlement that follows
     *         reverts at the MPC boundary, which is exactly the boundary the
     *         authorisation tests stop at.
     * @param escrowId Escrow identifier.
     * @param buyer Buyer address.
     * @param seller Seller address.
     * @param arbitrator Arbitrator address.
     */
    function seedDisputedEscrow(
        bytes32 escrowId,
        address buyer,
        address seller,
        address arbitrator
    ) external {
        escrows[escrowId] = PrivateEscrow({
            buyer: buyer,
            seller: seller,
            arbitrator: arbitrator,
            listingRef: bytes32(0),
            encPrice: ctUint256({
                ciphertextHigh: ctUint128.wrap(0),
                ciphertextLow: ctUint128.wrap(0)
            }),
            // solhint-disable-next-line not-rely-on-time
            createdAt: block.timestamp,
            // solhint-disable-next-line not-rely-on-time
            deadline: block.timestamp + 1 days,
            // solhint-disable-next-line not-rely-on-time
            disputeRaisedAt: block.timestamp,
            escrowFeeBpsAtCreate: DEFAULT_ESCROW_FEE_BPS,
            status: EscrowStatus.DISPUTED
        });
    }

    /**
     * @notice External wrapper around {_verifyDisputeOutcome} so tests can
     *         assert the real committee-authorisation logic without touching
     *         MPC settlement.
     * @param escrowId Escrow identifier bound into the digest.
     * @param winner Attested winner bound into the digest.
     * @param buyer Escrow buyer (committee-excluded party).
     * @param seller Escrow seller (committee-excluded party).
     * @param arbitrator Escrow arbitrator (committee-excluded party).
     * @param committeeProof Proof blob `commitBlock(32) || sigs`.
     * @return attesters Recovered committee attester addresses.
     */
    function verifyDisputeOutcome(
        bytes32 escrowId,
        address winner,
        address buyer,
        address seller,
        address arbitrator,
        bytes calldata committeeProof
    ) external view returns (address[] memory attesters) {
        return _verifyDisputeOutcome(
            escrowId, winner, buyer, seller, arbitrator, committeeProof
        );
    }

    /**
     * @notice Expose the EIP-712 dispute-resolution digest so tests can build
     *         the committee signatures the same way the contract verifies them.
     * @param escrowId Escrow identifier.
     * @param winner Attested winner.
     * @return The EIP-712 digest.
     */
    function resolveDisputeDigest(bytes32 escrowId, address winner)
        external
        view
        returns (bytes32)
    {
        return _resolveDisputeDigest(escrowId, winner);
    }
}
