// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/**
 * @title EscrowSignatureLib
 * @author OmniCoin Development Team
 * @notice External library that verifies the two signatures an EscrowV2 can
 *         be driven by: a 2-of-N judge verdict (delivered from the L1
 *         arbitration panel on a non-L1 chain) and a seller's fee-attribution
 *         consent.
 * @dev External linked library (DELEGATECALL into the escrow's context) so the
 *      escrow stays under EIP-170. It declares no storage; the judge roster is
 *      passed as a storage pointer to the escrow's own mapping.

 *      Both payloads are EIP-712 typed data. The escrow computes the domain
 *      separator (its own name/version/chainId/contract), so a signature can
 *      never be replayed onto another chain or another escrow deployment.

 *      VERDICT — the L1 panel produces a final verdict only (release to seller
 *      or refund to buyer); it never reverses a settled escrow, and the verdict
 *      is bound to one escrow id and a `validUntil` deadline. Two distinct
 *      rostered judges must sign. Signers may never be the buyer or the seller
 *      (defence in depth: the panel already excludes parties from its seats,
 *      and the escrow enforces it locally).

 *      ATTRIBUTION — the seller, not the buyer, decides who receives the 1%
 *      fee slices (primary/secondary referrer, listing node, selling node).
 *      Without this, a buyer could route the referral halves to its own
 *      addresses. A zero attribution set needs no signature; any non-zero slot
 *      requires the seller's signature over the complete set.
 */
library EscrowSignatureLib {
    /// @dev OZ typed-data hashing (uses the same anchor bytes as EIP712).
    using MessageHashUtils for bytes32;

    /// @notice A verdict signature bundle was malformed or not from a roster
    error InvalidVerdict();
    /// @notice Fewer than two distinct rostered judge signatures
    error NotEnoughVerdicts();
    /// @notice The seller's attribution signature is missing, stale or wrong
    error InvalidSellerSignature();

    /// @notice Number of distinct judge signatures a verdict needs
    uint256 internal constant VERDICT_THRESHOLD = 2;

    /// @notice Upper bound on supplied signature bytes (bounded gas)
    uint256 internal constant MAX_SIGNATURES = 16;

    /// @dev keccak256("Verdict(uint256 escrowId,bool releaseFunds,uint256 validUntil)")
    bytes32 internal constant VERDICT_TYPEHASH = keccak256(
        "Verdict(uint256 escrowId,bool releaseFunds,uint256 validUntil)"
    );

    /// @dev keccak256(
    ///   "Attribution(address seller,address token,address referrer,address referrer2,address listingNode,address sellingNode,uint256 validUntil)"
    /// )
    bytes32 internal constant ATTRIBUTION_TYPEHASH = keccak256(
        "Attribution(address seller,address token,address referrer,address referrer2,address listingNode,address sellingNode,uint256 validUntil)"
    );

    /**
     * @notice The verdict type hash, for clients and tests
     */
    function verdictTypehash() external pure returns (bytes32) {
        return VERDICT_TYPEHASH;
    }

    /**
     * @notice The attribution type hash, for clients and tests
     */
    function attributionTypehash() external pure returns (bytes32) {
        return ATTRIBUTION_TYPEHASH;
    }

    /**
     * @notice Hash a verdict into the escrow's EIP-712 domain
     * @param domainSeparator The escrow's `_domainSeparatorV4()`
     * @param escrowId Escrow the verdict applies to
     * @param releaseFunds True = pay the seller, false = refund the buyer
     * @param validUntil Unix time after which the bundle is rejected
     * @return The digest the seated judges sign
     */
    function hashVerdict(
        bytes32 domainSeparator,
        uint256 escrowId,
        bool releaseFunds,
        uint256 validUntil
    ) external pure returns (bytes32) {
        return
            MessageHashUtils.toTypedDataHash(
                domainSeparator,
                keccak256(
                    abi.encode(
                        VERDICT_TYPEHASH,
                        escrowId,
                        releaseFunds,
                        validUntil
                    )
                )
            );
    }

    /**
     * @notice Hash a seller attribution consent into the escrow's domain
     * @param domainSeparator The escrow's `_domainSeparatorV4()`
     * @param seller Seller granting the consent (bound into the digest)
     * @param token Settlement token (bound, so consent is per asset)
     * @param referrer Primary referrer
     * @param referrer2 Second-level referrer
     * @param listingNode Listing node
     * @param sellingNode Selling node
     * @param validUntil Unix time after which the consent is rejected
     * @return The digest the seller signs
     */
    function hashAttribution(
        bytes32 domainSeparator,
        address seller,
        address token,
        address referrer,
        address referrer2,
        address listingNode,
        address sellingNode,
        uint256 validUntil
    ) external pure returns (bytes32) {
        return
            MessageHashUtils.toTypedDataHash(
                domainSeparator,
                keccak256(
                    abi.encode(
                        ATTRIBUTION_TYPEHASH,
                        seller,
                        token,
                        referrer,
                        referrer2,
                        listingNode,
                        sellingNode,
                        validUntil
                    )
                )
            );
    }

    /**
     * @notice Verify that a verdict carries two distinct rostered signatures
     * @dev Every supplied signature must be valid, rostered and distinct: an
     *      extra unusable blob is a revert, not something to skip past.
     * @param digest The verdict digest (see {hashVerdict})
     * @param signatures Judge signatures (65 bytes each)
     * @param judges Judge roster (escrow storage slot)
     * @param buyer Escrow buyer (may never sign)
     * @param seller Escrow seller (may never sign)
     * @param validUntil Bundle deadline
     */
    function verifyVerdict(
        bytes32 digest,
        bytes[] calldata signatures,
        mapping(address => bool) storage judges,
        address buyer,
        address seller,
        uint256 validUntil
    ) external view {
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp > validUntil) revert InvalidVerdict();
        uint256 count = signatures.length;
        if (count < VERDICT_THRESHOLD || count > MAX_SIGNATURES) {
            revert NotEnoughVerdicts();
        }

        address[MAX_SIGNATURES] memory seen;
        for (uint256 i = 0; i < count; ++i) {
            (address signer, ECDSA.RecoverError err, ) = ECDSA.tryRecover(
                digest,
                signatures[i]
            );
            if (err != ECDSA.RecoverError.NoError) revert InvalidVerdict();
            if (!judges[signer]) revert InvalidVerdict();
            if (signer == buyer || signer == seller) revert InvalidVerdict();
            for (uint256 j = 0; j < i; ++j) {
                if (seen[j] == signer) revert InvalidVerdict();
            }
            seen[i] = signer;
        }
    }

    /**
     * @notice Verify the seller's signature over a non-zero attribution set
     * @param digest The attribution digest (see {hashAttribution})
     * @param signature The seller's 65-byte signature
     * @param seller The escrow's seller, who must be the signer
     * @param validUntil Consent deadline
     */
    function verifyAttribution(
        bytes32 digest,
        bytes calldata signature,
        address seller,
        uint256 validUntil
    ) external view {
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp > validUntil) revert InvalidSellerSignature();
        (address signer, ECDSA.RecoverError err, ) = ECDSA.tryRecover(
            digest,
            signature
        );
        if (err != ECDSA.RecoverError.NoError || signer != seller) {
            revert InvalidSellerSignature();
        }
    }
}
