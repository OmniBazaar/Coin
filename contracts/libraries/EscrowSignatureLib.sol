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
 *      SEATED judges must sign. Seats are drawn per dispute from the escrow's
 *      whole roster, so a large roster never becomes "any two of many": only
 *      the three judges assigned to this case can land a verdict. Signers may
 *      never be the buyer or the seller (defence in depth: the draw already
 *      excludes them, and the escrow enforces it locally).

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
    /// @notice The escrow has no seated panel yet, so no verdict is possible
    error PanelNotSeatedYet();
    /// @notice The seller's attribution signature is missing, stale or wrong
    error InvalidSellerSignature();

    /// @notice Number of distinct judge signatures a verdict needs
    uint256 internal constant VERDICT_THRESHOLD = 2;

    /// @notice Upper bound on supplied signature bytes (bounded gas)
    /// @dev Exactly three judges are seated per case, so a fourth signature can
    ///      never be eligible and is never paid.
    uint256 internal constant MAX_SIGNATURES = 3;

    /// @notice How many judges one panel seats
    uint256 internal constant SEATS = 3;

    /// @notice Most roster entries the seat draw will inspect before giving up
    /// @dev A roster of tens of thousands would otherwise make seating gas
    ///      unbounded. Rejection sampling normally lands three distinct seats
    ///      in a handful of attempts; the bound fails closed.
    uint256 internal constant MAX_SEAT_ATTEMPTS = 200;

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
     * @notice Verify a verdict bundle and return EVERY judge it names
     * @dev Founder decision 2026-10-27 (tie-break): a three-judge panel can
     *      split two ways, and the judge who breaks the tie signs the winning
     *      direction while the dissenter stays on the losing one. Both are
     *      participants and both must be paid, so this classifies each
     *      signature against BOTH digests (release and refund, same
     *      `validUntil`) instead of a single one.
     *
     *      Rules:
     *      - at least two distinct rostered non-party judges signed the
     *        requested direction;
     *      - every supplied signature must be a valid rostered non-party
     *        signature over one of the two digests — a stray blob reverts;
     *      - a signer appears once only, even if they signed both directions
     *        (a contradictory judge is paid once, not twice).
     * @param domainSeparator The escrow's `_domainSeparatorV4()`
     * @param escrowId Escrow the verdict applies to
     * @param releaseFunds The direction being executed
     * @param validUntil Bundle deadline (both directions share it)
     * @param signatures Judge signatures (65 bytes each)
     * @param seats The three judges seated for THIS escrow at dispute time
     * @param seatCount Number of seats recorded (must be three)
     * @param buyer Escrow buyer (may never sign)
     * @param seller Escrow seller (may never sign)
     * @return signers Every distinct judge whose signature was accepted
     */
    function verifyVerdict(
        bytes32 domainSeparator,
        uint256 escrowId,
        bool releaseFunds,
        uint256 validUntil,
        bytes[] calldata signatures,
        address[3] memory seats,
        uint8 seatCount,
        address buyer,
        address seller
    ) external view returns (address[] memory signers) {
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp > validUntil) revert InvalidVerdict();
        // No seats means nobody can judge this case; it belongs to the timeout
        // backstop, never to a signature bundle.
        if (seatCount != SEATS) revert PanelNotSeatedYet();
        uint256 count = signatures.length;
        if (count < VERDICT_THRESHOLD || count > MAX_SIGNATURES) {
            revert NotEnoughVerdicts();
        }

        bytes32 winning = _digest(
            domainSeparator, escrowId, releaseFunds, validUntil
        );
        bytes32 losing = _digest(
            domainSeparator, escrowId, !releaseFunds, validUntil
        );

        // NOTE: `tryRecover` succeeds for ANY well-formed signature — a wrong
        // digest simply recovers a different address. So each signature is
        // classified by whether the RECOVERED address is an eligible signer,
        // not by the recovery error code.
        address[MAX_SIGNATURES] memory seen;
        bool[MAX_SIGNATURES] memory seenWinning;
        signers = new address[](count);
        uint256 onWinning;
        uint256 kept;
        for (uint256 i = 0; i < count; ++i) {
            (address signer, ECDSA.RecoverError err, ) = ECDSA.tryRecover(
                winning,
                signatures[i]
            );
            bool onWin = err == ECDSA.RecoverError.NoError &&
                _isSeated(signer, seats) &&
                signer != buyer &&
                signer != seller;
            if (!onWin) {
                (signer, err, ) = ECDSA.tryRecover(losing, signatures[i]);
                if (
                    err != ECDSA.RecoverError.NoError ||
                    !_isSeated(signer, seats) ||
                    signer == buyer ||
                    signer == seller
                ) {
                    revert InvalidVerdict();
                }
            }
            // 🛑 A REPEATED SIGNER IS COUNTED AND PAID ONCE. A judge who signed
            // BOTH directions during deliberation is a contradictory voter, not
            // an attacker; reverting would hand the case to the timeout instead
            // of the judges. The winning direction still counts if either copy
            // was on it.
            uint256 existing = type(uint256).max;
            for (uint256 j = 0; j < kept; ++j) {
                if (seen[j] == signer) {
                    existing = j;
                    break;
                }
            }
            if (existing != type(uint256).max) {
                if (onWin && !seenWinning[existing]) {
                    seenWinning[existing] = true;
                    ++onWinning;
                }
                continue;
            }
            seen[kept] = signer;
            seenWinning[kept] = onWin;
            signers[kept] = signer;
            ++kept;
            if (onWin) ++onWinning;
        }
        if (onWinning < VERDICT_THRESHOLD) revert NotEnoughVerdicts();
        // Trim the array to the signers actually kept.
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            mstore(signers, kept)
        }
    }

    /**
     * @notice Draw the three judges who will hear one disputed escrow
     * @dev Founder direction 2026-11-12: the panel is three OF N, not a fixed
     *      three. The escrow holds the whole roster and this draw picks three
     *      of it per case, so a large roster never degrades into "any two of
     *      many can sign".
     *
     *      The entropy is the block hash of the block the dispute was opened
     *      in — unknown when the disputing party signed the transaction, so
     *      neither party can grind for a favourable panel. It must be spent
     *      inside the 256-block window in which that hash is available; the
     *      Validator seats the panel on the next block. If nobody seats it, the
     *      case falls to the trustless timeout refund, which is the safe
     *      direction.
     *
     *      Rejection sampling is exact modulo a negligible bias (a 256-bit hash
     *      against a roster size), excludes both parties and the escrow
     *      itself, and is bounded so gas cannot grow with the roster.
     * @param roster The escrow's judge roster (storage)
     * @param escrowId Escrow identifier (mixed into the seed)
     * @param entropy Block hash of the dispute's opening block
     * @param excluded Addresses that may never be seated: both parties and the
     *        escrow itself. Zero entries are ignored. 🛑 NOT the fee-attribution
     *        slots: the seller chooses those, so excluding them would let a
     *        party shrink or empty the panel pool.
     * @return seats The three drawn judges, zero-padded if fewer were found
     * @return found How many distinct seats the draw produced
     */
    function selectSeats(
        address[] storage roster,
        uint256 escrowId,
        bytes32 entropy,
        address[3] memory excluded
    ) external view returns (address[3] memory seats, uint256 found) {
        uint256 rosterSize = roster.length;
        if (rosterSize < SEATS) {
            return (seats, 0);
        }
        uint256 nonce = 0;
        while (found < SEATS && nonce < MAX_SEAT_ATTEMPTS) {
            bytes32 h = keccak256(
                abi.encodePacked(escrowId, entropy, nonce, rosterSize)
            );
            address candidate = roster[uint256(h) % rosterSize];
            ++nonce;

            if (candidate == address(0) || _isExcluded(candidate, excluded)) {
                continue;
            }
            bool duplicate = false;
            for (uint256 j = 0; j < found; ++j) {
                if (seats[j] == candidate) {
                    duplicate = true;
                    break;
                }
            }
            if (duplicate) {
                continue;
            }
            seats[found] = candidate;
            ++found;
        }
    }

    /**
     * @notice Whether an address may never be seated for one escrow
     * @param candidate Roster entry under test
     * @param excluded Buyer, seller and the escrow itself
     * @return True when the entry must be skipped
     */
    function _isExcluded(
        address candidate,
        address[3] memory excluded
    ) private pure returns (bool) {
        for (uint256 i = 0; i < 3; ++i) {
            if (excluded[i] != address(0) && candidate == excluded[i]) {
                return true;
            }
        }
        return false;
    }

    /**
     * @notice Whether an address is one of the three seated judges
     */
    function _isSeated(
        address signer,
        address[3] memory seats
    ) private pure returns (bool) {
        if (signer == address(0)) {
            return false;
        }
        return signer == seats[0] || signer == seats[1] || signer == seats[2];
    }

    /**
     * @notice EIP-712 digest of one verdict direction
     */
    function _digest(
        bytes32 domainSeparator,
        uint256 escrowId,
        bool releaseFunds,
        uint256 validUntil
    ) private pure returns (bytes32) {
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
