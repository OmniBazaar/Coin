// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ERC2771Context} from "@openzeppelin/contracts/metatx/ERC2771Context.sol";
import {Context} from "@openzeppelin/contracts/utils/Context.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/**
 * @title  IMinimalEscrowMinimal
 * @author OmniCoin Development Team
 * @notice Narrow interface so we don't pull the full MinimalEscrow ABI
 *         into the marketplace contract; only the public escrow-state
 *         getter, the fee + duration immutables (for parity assert at
 *         deploy time — audit H-3 / M-3), and the new
 *         `releaseFundsViaContract` entry point are needed.
 */
interface IMinimalEscrowMinimal {
    /**
     * @notice Marketplace fee in basis points enforced inside the
     *         settlement body of `releaseFundsViaContract`. Read at
     *         router construction so the router can assert lockstep
     *         and reject divergent listings deterministically (audit
     *         H-3).
     * @return bps Fee in basis points (uint256).
     */
    function MARKETPLACE_FEE_BPS() external view returns (uint256 bps);

    /**
     * @notice Maximum escrow duration (seconds). Read at router
     *         construction so MAX_LISTING_WINDOW tracks MinimalEscrow's
     *         live setting instead of drifting (audit M-3).
     * @return seconds_ Maximum escrow lifetime.
     */
    function MAX_DURATION() external view returns (uint256 seconds_);
    /**
     * @notice Release funds to the seller authenticated by a buyer-
     *         signed EIP-712 payload. See MinimalEscrow for the full
     *         semantics and revert conditions.
     * @param escrowId       Escrow whose funds are being released.
     * @param callerContract Contract address the buyer authorized
     *                       (must equal msg.sender inside MinimalEscrow).
     * @param deadline       Signature expiry in unix seconds.
     * @param signature      65-byte ECDSA signature over MinimalEscrow's
     *                       `ReleaseFundsBySig` typed data, produced by
     *                       the escrow.buyer wallet.
     */
    function releaseFundsViaContract(
        uint256 escrowId,
        address callerContract,
        uint256 deadline,
        bytes calldata signature
    ) external;

    /**
     * @notice Read the storage struct for a given escrow. Field order
     *         must mirror `MinimalEscrow.Escrow` exactly because the
     *         auto-generated getter returns positional tuple values.
     * @param  escrowId     Escrow identifier.
     * @return buyer        Address that funded the escrow.
     * @return seller       Address that receives funds on release.
     * @return arbitrator   Assigned arbitrator (zero if undisputed).
     * @return releaseVotes Tally of release votes (dispute path).
     * @return refundVotes  Tally of refund votes (dispute path).
     * @return resolved     True once the escrow has terminal-state.
     * @return disputed     True once a dispute has been raised.
     * @return amount       Remaining XOM amount held by the escrow.
     * @return expiry       Unix-seconds expiry of the escrow.
     * @return createdAt    Unix-seconds creation timestamp.
     */
    function escrows(uint256 escrowId)
        external
        view
        returns (
            address buyer,
            address seller,
            address arbitrator,
            uint8 releaseVotes,
            uint8 refundVotes,
            bool resolved,
            bool disputed,
            uint256 amount,
            uint256 expiry,
            uint256 createdAt
        );
}

/**
 * @title NFTMarketplaceEscrowLegacy (formerly NFTMarketplaceEscrow)
 * @author OmniCoin Development Team
 * @notice Atomic NFT-for-XOM settlement contract built on top of
 *         {MinimalEscrow}. Lets a buyer settle (release XOM to seller AND
 *         pull the NFT) in a single buyer-signed transaction so the
 *         pre-existing 2-tx flow (release + transferFrom) — which can
 *         strand the buyer if the seller forgets the second tx — is no
 *         longer the canonical path.
 *
 * @dev Trust model is fully on-chain:
 *
 *      - Seller signs an EIP-712 `Listing` envelope off-chain that
 *        commits to (nftContract, tokenId, askPriceXom, expiry, nonce,
 *        marketplaceFeeBps). `marketplaceFeeBps` is bound at listing
 *        time per design decision — subsequent admin fee changes do
 *        NOT affect already-listed offers.
 *
 *      - Seller pre-calls `nftContract.setApprovalForAll(this, true)`
 *        once per collection. Same approval pattern users already do
 *        for Uniswap/OpenSea — revocable, contract-bound, no admin.
 *
 *      - Buyer escrows XOM via {MinimalEscrow.createEscrow} (unchanged
 *        from today's flow).
 *
 *      - Buyer signs an EIP-712 `ReleaseFundsBySig` payload that
 *        commits this contract address as `callerContract` so the sig
 *        can only be consumed here.
 *
 *      - Buyer (or a relayer on their behalf via OmniForwarder)
 *        invokes {fillListing} with both signatures. The function:
 *          1. Verifies the seller's `Listing` signature.
 *          2. Verifies the listing has not expired and the per-seller
 *             nonce has not been consumed.
 *          3. Sanity-checks the escrow against the listing (seller,
 *             amount).
 *          4. Calls {MinimalEscrow.releaseFundsViaContract}, which
 *             verifies the buyer's release signature and transfers
 *             XOM (less fee) to the seller. After this point the
 *             escrow is resolved on-chain.
 *          5. Pulls the NFT from seller to buyer via
 *             `IERC721.transferFrom`. If this reverts the entire tx
 *             reverts — buyer never pays without getting the NFT.
 *
 *      Trust assumptions baseline:
 *        - Buyer trusts: MinimalEscrow code, NFTMarketplaceEscrow code,
 *          their own buyerReleaseSig.
 *        - Seller trusts: MinimalEscrow code, NFTMarketplaceEscrow code,
 *          their own setApprovalForAll(this, true), their own listing sig.
 *        - Neither side trusts an admin or off-chain operator.
 *
 *      Re-entrancy: `nonReentrant`. CEI: all state writes precede the
 *      external calls (escrow release, NFT transfer). Both external
 *      calls are well-known-safe contracts (audited MinimalEscrow
 *      + caller-chosen IERC721; a malicious NFT contract still cannot
 *      drain via re-entry because the nonce is consumed first).
 *
 *      Gasless: ERC2771Context. OmniForwarder is the trusted forwarder;
 *      `_msgSender()` resolves to the buyer when invoked via the relay.
 *
 * @custom:audit Awaiting 7-pass audit matching the PrivateDEXSettlement
 *               2026-05-10 pattern. NOT FOR MAINNET DEPLOY until audit
 *               + remediation complete. Tracked in
 *               `Coin/contracts/NFT_ATOMIC_SETTLEMENT_DESIGN.md`.
 */
/// @dev RENAMED 2026-05-17 from `NFTMarketplaceEscrow` to
///      `NFTMarketplaceEscrowLegacy` after the v1 thin-router design
///      was abandoned. The deployed v1 instance at
///      `0x10F3687c5e491a2F380d87D0756c782051ef14c2` is ADMIN-paused
///      and dead-on-arrival — it depends on
///      `MinimalEscrow.releaseFundsViaContract` which doesn't exist
///      on the deployed MinimalEscrow bytecode. Kept as a source
///      reference for the v1 audit + paused-contract identification.
///      Production traffic uses the self-contained
///      `NFTMarketplaceEscrow` contract (v2 design, same file
///      naming convention as before the rename). See
///      `Coin/contracts/NFT_ATOMIC_SETTLEMENT_DESIGN.md` §"v2
///      Option E" for the supersede rationale.
contract NFTMarketplaceEscrowLegacy is
    ReentrancyGuard,
    Pausable,
    ERC2771Context,
    EIP712
{
    // ─── Types ────────────────────────────────────────────────────────

    /**
     * @notice Seller's signed listing envelope.
     * @param seller            EVM address of the NFT owner. Must match
     *                          the signature recovery.
     * @param buyer             Optional buyer binding. When non-zero,
     *                          ONLY this address may fill the listing
     *                          (`_msgSender() == buyer` required). When
     *                          zero, the listing is permissionless —
     *                          any caller funding a matching escrow
     *                          can fill (the classic open-marketplace
     *                          flow, matching OpenSea/Sudoswap UX).
     *                          Bound here per audit C-1 so sellers can
     *                          do private OTC trades without exposing
     *                          the listing sig to mempool front-runs.
     * @param nftContract       ERC-721 contract address.
     * @param tokenId           Token id within `nftContract`.
     * @param askPriceXom       Required escrow.amount on the matched
     *                          escrow (smallest XOM units). Sanity
     *                          check; the actual XOM transfer is
     *                          driven by `escrow.amount` inside
     *                          {MinimalEscrow}.
     * @param expiry            Unix seconds after which the listing
     *                          cannot be filled.
     * @param nonce             Per-seller monotonic counter; consumed
     *                          on first fill to prevent replay.
     * @param marketplaceFeeBps Fee in basis points that the seller has
     *                          agreed to at listing time. Bound here
     *                          so subsequent admin fee changes do not
     *                          affect already-listed offers (design
     *                          decision 3, locked 2026-05-16).
     * @dev   Calldata struct — Solidity never packs calldata fields, so
     *        the gas-struct-packing solhint warning here is a false
     *        positive. The field order is chosen to match the EIP-712
     *        type-string for signature compatibility, NOT for storage
     *        packing.
     */
    // solhint-disable-next-line gas-struct-packing
    struct Listing {
        address seller;
        address buyer;
        address nftContract;
        uint256 tokenId;
        uint256 askPriceXom;
        uint256 expiry;
        uint256 nonce;
        uint64 marketplaceFeeBps;
    }

    // ─── Constants ────────────────────────────────────────────────────

    /// @notice Required signature length for ECDSA recovery.
    uint256 public constant SIGNATURE_LENGTH = 65;

    /// @notice EIP-712 type hash for the `Listing` struct.
    /// @dev String must match the struct field order exactly. The
    ///      gas-small-strings warning is intentional — EIP-712 requires
    ///      the canonical multi-field signature string.
    bytes32 public constant LISTING_TYPEHASH = keccak256( // solhint-disable-line gas-small-strings
        // solhint-disable-next-line max-line-length, gas-small-strings
        "Listing(address seller,address buyer,address nftContract,uint256 tokenId,uint256 askPriceXom,uint256 expiry,uint256 nonce,uint64 marketplaceFeeBps)"
    );

    /// @notice EIP-712 type hash for the buyer's `FillAuthorization`
    ///         envelope. Audit C-01 remediation (2026-05-16).
    /// @dev The buyer signs THIS payload alongside MinimalEscrow's
    ///      `ReleaseFundsBySig`. It commits to the exact listing being
    ///      filled (via the listing's EIP-712 digest) so a malicious
    ///      seller cannot present a substitute listing at fill time
    ///      to redirect the buyer's XOM into a different NFT.
    bytes32 public constant FILL_AUTHORIZATION_TYPEHASH = keccak256( // solhint-disable-line gas-small-strings
        // solhint-disable-next-line gas-small-strings
        "FillAuthorization(uint256 escrowId,bytes32 listingDigest,uint256 deadline)"
    );

    // ─── Immutables ───────────────────────────────────────────────────

    /// @notice MinimalEscrow proxy — holds the XOM and runs settlement.
    IMinimalEscrowMinimal public immutable MINIMAL_ESCROW;

    /// @notice Marketplace fee in basis points enforced inside the
    ///         settlement body of `MinimalEscrow.releaseFundsViaContract`.
    ///         Asserted equal to `MinimalEscrow.MARKETPLACE_FEE_BPS()`
    ///         at construction time (audit H-3) so listings whose
    ///         `marketplaceFeeBps` matches this immutable will receive
    ///         the bps they signed for.
    uint64 public immutable MARKETPLACE_FEE_BPS;

    /// @notice Maximum listing window in seconds. Read from
    ///         `MinimalEscrow.MAX_DURATION()` at construction (audit
    ///         M-3) so the router tracks the live MinimalEscrow setting
    ///         instead of carrying a duplicated constant that could
    ///         drift across future redeploys.
    uint256 public immutable MAX_LISTING_WINDOW;

    /// @notice Admin who can pause/unpause this router (audit M-5).
    ///         Set to `msg.sender` at construction. No transfer
    ///         mechanism — re-deploy to rotate.
    address public immutable ADMIN;

    // ─── State ────────────────────────────────────────────────────────

    /// @notice Consumed seller nonces. `sellerNonces[seller][nonce]
    ///         == true` means the (seller, nonce) pair has already
    ///         filled a listing and cannot be reused.
    mapping(address => mapping(uint256 => bool)) public sellerNonces;

    // ─── Events ───────────────────────────────────────────────────────

    /**
     * @notice Emitted on a successful atomic settlement.
     * @param seller          NFT seller (XOM recipient).
     * @param buyer           NFT recipient (XOM payer).
     * @param nftContract     ERC-721 contract.
     * @param tokenId         Token transferred.
     * @param escrowId        MinimalEscrow id that funded the buyer's leg.
     * @param nonce           Seller's listing nonce consumed by this fill
     *                        (indexer needs this to prune the consumed
     *                        listing from active-listing views — audit
     *                        L-02 follow-up).
     * @param marketplaceFeeBps Fee bps applied to the settlement (from
     *                        the seller's signed listing).
     */
    event ListingFilled(
        address indexed seller,
        address indexed buyer,
        address indexed nftContract,
        uint256 tokenId,
        uint256 escrowId,
        uint256 nonce,
        uint64 marketplaceFeeBps
    );

    /**
     * @notice Emitted when a seller burns a listing nonce off-fill
     *         via {cancelListingNonce}. Audit M-04 — lets indexers
     *         prune cancelled listings from UI without scanning every
     *         fillListing event.
     * @param seller Seller whose nonce is now consumed.
     * @param nonce  Nonce that was cancelled.
     */
    event ListingNonceCancelled(address indexed seller, uint256 indexed nonce);

    // ─── Errors ───────────────────────────────────────────────────────

    /// @notice Zero address supplied where a real address is required.
    error InvalidAddress();

    /// @notice Listing's `expiry` is in the past.
    error ListingExpired();

    /// @notice Listing's `expiry` is more than `MAX_LISTING_WINDOW`
    ///         in the future (prevents indefinite-lifetime sigs).
    error ListingExpiryTooFar();

    /// @notice Seller's signature does not recover to `listing.seller`.
    error InvalidSellerSignature();

    /// @notice The (listing.seller, listing.nonce) pair was already
    ///         consumed by a prior fill.
    error NonceAlreadyConsumed();

    /// @notice The escrow's seller does not match the listing's seller.
    error EscrowSellerMismatch();

    /// @notice The escrow's amount does not match the listing's
    ///         askPriceXom. Sanity check; prevents a buyer from
    ///         using a smaller escrow to fill a larger listing.
    error EscrowAmountMismatch();

    /// @notice The escrow has already been resolved or refunded.
    error EscrowNotActive();

    /// @notice The escrow is in dispute; arbitration must run instead.
    error EscrowDisputed();

    /// @notice The seller's listing committed to a `marketplaceFeeBps`
    ///         that does not match this contract's immutable value.
    ///         A stale listing signed against an older fee is rejected.
    error FeeBpsMismatch();

    /// @notice Signature is not exactly 65 bytes long.
    error InvalidSignatureLength();

    /// @notice Listing was bound to a specific buyer via `listing.buyer`
    ///         and `_msgSender()` is somebody else. Audit C-1.
    error FillerNotAuthorized();

    /// @notice The on-chain escrow has passed its `expiry`; the buyer
    ///         is entitled to a refund and the listing must not be
    ///         settled against a stale escrow. Audit H-2.
    error EscrowExpired();

    /// @notice The escrow's recorded amount is zero. Settlement against
    ///         a zero-amount escrow would transfer the NFT for free
    ///         and emit polluting zero-amount events. Audit M-1.
    error EscrowAmountZero();

    /// @notice Buyer's `FillAuthorization` signature did not recover
    ///         to `escrow.buyer`, OR was signed against a different
    ///         listing digest / escrowId / deadline than the one
    ///         being filled. Audit C-01 — blocks the bait-and-switch
    ///         attack class where a seller substitutes a listing
    ///         after the buyer signed `ReleaseFundsBySig`.
    error InvalidBuyerAuthorization();

    /// @notice The buyer's signature deadline outlives the listing
    ///         itself. The buyer's authorization cannot exceed the
    ///         lifetime of the listing it authorizes. Audit H-01.
    error BuyerDeadlineExceedsListingExpiry();

    // ─── Constructor ──────────────────────────────────────────────────

    /**
     * @notice Wire the immutable references.
     * @dev    Asserts at construction that the supplied `_marketplaceFeeBps`
     *         equals `MinimalEscrow.MARKETPLACE_FEE_BPS()` so settlements
     *         and listing-bound fee bps stay in lockstep (audit H-3).
     *         Reads MinimalEscrow.MAX_DURATION() and uses it as the
     *         router's MAX_LISTING_WINDOW (audit M-3).
     *         Sets `ADMIN = msg.sender` for the pause/unpause hooks
     *         (audit M-5).
     * @param _minimalEscrow      Deployed MinimalEscrow proxy.
     * @param _marketplaceFeeBps  Listing-bound fee bps. Must equal the
     *                            MinimalEscrow's MARKETPLACE_FEE_BPS or
     *                            construction reverts with FeeBpsMismatch.
     * @param trustedForwarder_   OmniForwarder for gasless meta-tx.
     */
    constructor(
        address _minimalEscrow,
        uint64 _marketplaceFeeBps,
        address trustedForwarder_
    )
        ERC2771Context(trustedForwarder_)
        EIP712("OmniBazaar NFTMarketplaceEscrow", "1")
    {
        if (_minimalEscrow == address(0)) revert InvalidAddress();
        IMinimalEscrowMinimal me = IMinimalEscrowMinimal(_minimalEscrow);
        // Audit H-3: refuse to deploy if the router's listing-bound
        // fee bps doesn't match MinimalEscrow's settlement-time bps.
        if (me.MARKETPLACE_FEE_BPS() != uint256(_marketplaceFeeBps)) {
            revert FeeBpsMismatch();
        }
        MINIMAL_ESCROW = me;
        MARKETPLACE_FEE_BPS = _marketplaceFeeBps;
        // Audit M-3: read MAX_DURATION from MinimalEscrow rather than
        // carrying a duplicated constant.
        MAX_LISTING_WINDOW = me.MAX_DURATION();
        ADMIN = msg.sender;
    }

    // ─── Admin: pause / unpause (audit M-5) ──────────────────────────

    /// @notice Caller is not the recorded ADMIN.
    error NotAdmin();

    /**
     * @notice Pause new fills. ADMIN-only emergency switch (audit M-5
     *         remediation). Pre-existing listings + in-flight escrows
     *         are unaffected on MinimalEscrow's side; this only halts
     *         the router's atomic-settlement entry point.
     */
    function pause() external {
        if (msg.sender != ADMIN) revert NotAdmin();
        _pause();
    }

    /**
     * @notice Resume new fills. ADMIN-only.
     */
    function unpause() external {
        if (msg.sender != ADMIN) revert NotAdmin();
        _unpause();
    }

    // ─── External: fillListing ───────────────────────────────────────

    /**
     * @notice Atomically release the buyer's escrow XOM to the seller
     *         AND transfer the NFT from seller to buyer in one tx.
     *
     * @dev The buyer (or a relayer on their behalf via OmniForwarder)
     *      submits:
     *        - the seller's signed `Listing`,
     *        - the seller's ECDSA signature,
     *        - the on-chain `escrowId` the buyer created,
     *        - the buyer's `ReleaseFundsBySig` signature (deadline
     *          included in calldata so MinimalEscrow verifies),
     *        - the deadline that signature commits to.
     *
     *      Function flow (CEI strictly):
     *        1. Reject if listing expired.
     *        2. Recover seller from listing sig; reject on mismatch.
     *        3. Reject if (seller, nonce) already consumed.
     *        4. Reject if listing-bound feeBps != contract's cached
     *           feeBps. Protects against admin fee changes silently
     *           altering historical listings.
     *        5. Read escrow state from MinimalEscrow; sanity-check
     *           seller, amount, resolved=false, disputed=false.
     *        6. Mark nonce consumed (state write before externals).
     *        7. Call `MinimalEscrow.releaseFundsViaContract` — that
     *           verifies the buyer sig and transfers XOM.
     *        8. Pull the NFT via `IERC721.transferFrom(seller, buyer,
     *           tokenId)`. Reverts whole tx if seller hasn't
     *           pre-approved this contract OR the NFT was sold
     *           elsewhere first. Either way: escrow funds also revert
     *           via the outer revert — buyer is never charged without
     *           getting the NFT.
     *
     *      The buyer is `_msgSender()` so the gasless flow works (when
     *      OmniForwarder relays, `_msgSender()` is the original buyer,
     *      not the forwarder address). Anyone with valid sigs can
     *      submit, but the NFT lands at `_msgSender()` — which is the
     *      buyer because their own forwarder-signed envelope sets it.
     *
     * @param listing                Seller's signed listing envelope.
     * @param sellerSignature        65-byte ECDSA sig over the Listing.
     * @param escrowId               MinimalEscrow id the buyer created.
     * @param buyerReleaseSignature  65-byte ECDSA sig the buyer signed
     *                               over MinimalEscrow's
     *                               ReleaseFundsBySig typed-data.
     * @param buyerFillAuthorization 65-byte ECDSA sig the buyer signed
     *                               over this contract's
     *                               FillAuthorization(escrowId,
     *                               listingDigest, deadline). Audit
     *                               C-01 — pins the buyer's intent
     *                               to the exact listing being filled.
     * @param buyerDeadline          Shared deadline both buyer sigs
     *                               commit to. Forwarded verbatim to
     *                               MinimalEscrow. Audit H-01 — must
     *                               not exceed `listing.expiry`.
     * @custom:complexity Cyclomatic complexity 8 (>7 default) is
     *                    inherent to the branch-count of typed
     *                    validation reverts; matches the
     *                    PrivateDEXSettlement precedent and is
     *                    accepted per Coin module policy.
     */
    function fillListing(
        Listing calldata listing,
        bytes calldata sellerSignature,
        uint256 escrowId,
        bytes calldata buyerReleaseSignature,
        bytes calldata buyerFillAuthorization,
        uint256 buyerDeadline
    ) external nonReentrant whenNotPaused {
        // Audit C-1: if the seller bound the listing to a specific
        // buyer (private OTC trade), reject any other filler before
        // doing any work. `_msgSender()` resolves through
        // ERC2771Context so this also locks down relay-submitted
        // calls (forwarder must replay the buyer's signed envelope).
        if (listing.buyer != address(0) && _msgSender() != listing.buyer) {
            revert FillerNotAuthorized();
        }

        // Audit H-01: the buyer's authorization deadline cannot
        // outlive the listing it authorizes. Folded into the C-01
        // remediation pass.
        if (buyerDeadline > listing.expiry) {
            revert BuyerDeadlineExceedsListingExpiry();
        }

        // Validation factored out to keep cyclomatic complexity ≤ 7.
        // Each helper either passes or reverts with a typed error.
        _validateListing(listing, sellerSignature);
        _validateEscrowAgainstListing(escrowId, listing);

        // Audit C-01: verify the buyer signed a FillAuthorization
        // envelope that pins THIS listing's digest. Without this
        // check, a seller with two listing-sigs at the same price
        // could swap which NFT the buyer receives after the buyer
        // signed only the listing-agnostic ReleaseFundsBySig. We
        // recover the buyer's address from the FillAuthorization sig
        // and compare against the on-chain `escrow.buyer` (already
        // loaded inside `_validateEscrowAgainstListing` and re-read
        // here from the canonical MinimalEscrow storage so this is
        // a verifiable single source of truth).
        _verifyBuyerFillAuthorization(
            listing,
            escrowId,
            buyerDeadline,
            buyerFillAuthorization
        );

        // Consume the seller nonce BEFORE any external call (CEI).
        sellerNonces[listing.seller][listing.nonce] = true;

        // External call #1 — release XOM via MinimalEscrow. The buyer's
        // EIP-712 release signature is verified inside MinimalEscrow
        // against `escrowBuyer`; mismatch reverts both legs.
        MINIMAL_ESCROW.releaseFundsViaContract(
            escrowId,
            address(this),
            buyerDeadline,
            buyerReleaseSignature
        );

        // External call #2 — pull the NFT to the buyer. `_msgSender()`
        // resolves through ERC2771Context so a relay-submitted call
        // still credits the original buyer.
        IERC721(listing.nftContract).transferFrom(
            listing.seller,
            _msgSender(),
            listing.tokenId
        );

        emit ListingFilled(
            listing.seller,
            _msgSender(),
            listing.nftContract,
            listing.tokenId,
            escrowId,
            listing.nonce,
            listing.marketplaceFeeBps
        );
    }

    /**
     * @notice Seller-initiated nonce burn. Lets a seller invalidate a
     *         previously-signed `Listing` envelope without filling it
     *         — useful when the listing leaks, the price moves, or
     *         the seller changes their mind. Audit M-04 remediation.
     *
     * @dev Marks `sellerNonces[_msgSender()][nonce] = true`. Any
     *      pre-signed listing using `_msgSender()` as seller and this
     *      `nonce` becomes unfillable. Reverts if the nonce has
     *      already been consumed (idempotent on the cancelled state).
     *      `_msgSender()` resolves through ERC2771Context so sellers
     *      can cancel via the gasless OmniRelay flow.
     *
     * @param nonce Listing nonce to burn.
     */
    function cancelListingNonce(uint256 nonce) external whenNotPaused {
        if (sellerNonces[_msgSender()][nonce]) revert NonceAlreadyConsumed();
        sellerNonces[_msgSender()][nonce] = true;
        emit ListingNonceCancelled(_msgSender(), nonce);
    }

    /**
     * @notice Compute the full EIP-712 digest (domain-separated typed
     *         data hash) for a `Listing`. Wallets sign this exact
     *         32-byte value.
     * @param listing The Listing struct.
     * @return digest The typed-data digest a wallet would sign.
     */
    function listingDigest(Listing calldata listing)
        external
        view
        returns (bytes32 digest)
    {
        return _hashTypedDataV4(_hashListing(listing));
    }

    /**
     * @notice Return the EIP-712 domain separator. Useful for off-chain
     *         signers that don't compute it themselves.
     * @return separator The cached or freshly computed domain separator.
     */
    function domainSeparator() external view returns (bytes32 separator) {
        return _domainSeparatorV4();
    }

    /**
     * @notice Compute the EIP-712 struct hash for a `Listing`. Exposed
     *         so wallets can sanity-check the digest they're signing
     *         matches what this contract verifies.
     * @param listing The Listing struct.
     * @return structHash Keccak256 of the encoded Listing.
     */
    function hashListing(Listing calldata listing)
        external
        pure
        returns (bytes32 structHash)
    {
        return _hashListing(listing);
    }

    /**
     * @notice Compute the FillAuthorization EIP-712 digest a wallet
     *         signs. Audit C-01 helper — wallets call this to verify
     *         that the digest they're prompting the user to sign
     *         matches what {fillListing} will verify.
     * @param listing  The Listing being authorized.
     * @param escrowId Escrow id funding the fill.
     * @param deadline Unix-seconds deadline the buyer signs over.
     * @return digest  The typed-data digest a wallet would sign.
     */
    function fillAuthorizationDigest(
        Listing calldata listing,
        uint256 escrowId,
        uint256 deadline
    ) external view returns (bytes32 digest) {
        bytes32 hashedListing = _hashTypedDataV4(_hashListing(listing));
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    FILL_AUTHORIZATION_TYPEHASH,
                    escrowId,
                    hashedListing,
                    deadline
                )
            )
        );
    }

    // ─── Internal helpers ─────────────────────────────────────────────

    /**
     * @notice Verify the seller's listing envelope: expiry window,
     *         fee-bps match, signature shape + recovery, and nonce
     *         freshness. Reverts on any failure with a typed error.
     * @param listing         Seller's signed listing envelope.
     * @param sellerSignature 65-byte ECDSA signature.
     */
    function _validateListing(
        Listing calldata listing,
        bytes calldata sellerSignature
    ) internal view {
        // Audit L-03: zero-address `nftContract` is a sentinel value
        // and must be rejected explicitly with a typed error rather
        // than allowed to fall through to a confusing low-level
        // revert during `transferFrom`.
        if (listing.nftContract == address(0)) revert InvalidAddress();
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp > listing.expiry) revert ListingExpired();
        // solhint-disable-next-line not-rely-on-time
        if (listing.expiry > block.timestamp + MAX_LISTING_WINDOW) {
            revert ListingExpiryTooFar();
        }
        if (listing.marketplaceFeeBps != MARKETPLACE_FEE_BPS) {
            revert FeeBpsMismatch();
        }
        if (sellerSignature.length != SIGNATURE_LENGTH) {
            revert InvalidSignatureLength();
        }
        bytes32 digest = _hashTypedDataV4(_hashListing(listing));
        address recovered = ECDSA.recover(digest, sellerSignature);
        if (recovered != listing.seller) revert InvalidSellerSignature();
        if (sellerNonces[listing.seller][listing.nonce]) {
            revert NonceAlreadyConsumed();
        }
    }

    /**
     * @notice Recover the buyer's address from the FillAuthorization
     *         signature and compare against `escrow.buyer`. Audit
     *         C-01 — without this check, a seller could substitute
     *         a different listing at fill time and the buyer's
     *         release-sig (which doesn't bind any listing) would
     *         still authorize the swap.
     * @dev    Reads `escrow.buyer` from MinimalEscrow at call-time;
     *         this is the same source-of-truth used by
     *         MinimalEscrow's own buyer-sig recovery a few lines
     *         later, so the two sigs are mutually consistent.
     * @param listing                The listing being filled.
     * @param escrowId               Escrow id funding the fill.
     * @param buyerDeadline          Deadline the buyer committed to.
     * @param buyerFillAuthorization 65-byte ECDSA signature.
     */
    function _verifyBuyerFillAuthorization(
        Listing calldata listing,
        uint256 escrowId,
        uint256 buyerDeadline,
        bytes calldata buyerFillAuthorization
    ) internal view {
        if (buyerFillAuthorization.length != SIGNATURE_LENGTH) {
            revert InvalidSignatureLength();
        }
        bytes32 hashedListing = _hashTypedDataV4(_hashListing(listing));
        bytes32 fillAuthDigest = _hashTypedDataV4(
            keccak256(
                abi.encode(
                    FILL_AUTHORIZATION_TYPEHASH,
                    escrowId,
                    hashedListing,
                    buyerDeadline
                )
            )
        );
        address recovered = ECDSA.recover(fillAuthDigest, buyerFillAuthorization);
        (address escrowBuyer, , , , , , , , , ) = MINIMAL_ESCROW.escrows(escrowId);
        if (recovered != escrowBuyer) revert InvalidBuyerAuthorization();
    }

    /**
     * @notice Cross-check the on-chain escrow state against the listing
     *         (seller, amount, lifecycle flags). The buyer's signature
     *         on the release leg is verified inside MinimalEscrow, not
     *         here — this only sanity-checks that the buyer didn't try
     *         to fill the listing against a smaller/disputed/resolved
     *         escrow.
     * @param escrowId Escrow id the buyer wants to use as funding.
     * @param listing  Seller's listing envelope to match against.
     */
    function _validateEscrowAgainstListing(
        uint256 escrowId,
        Listing calldata listing
    ) internal view {
        (
            address escrowBuyer,
            address escrowSeller,
            /* arbitrator */,
            /* releaseVotes */,
            /* refundVotes */,
            bool resolved,
            bool disputed,
            uint256 amount,
            uint256 escrowExpiry,
            /* createdAt */
        ) = MINIMAL_ESCROW.escrows(escrowId);

        if (escrowBuyer == address(0)) revert EscrowNotActive();
        if (resolved) revert EscrowNotActive();
        if (disputed) revert EscrowDisputed();
        // Audit H-2: an expired escrow belongs to the buyer (they can
        // call refundBuyer); fillListing must NOT drain it.
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp > escrowExpiry) revert EscrowExpired();
        if (escrowSeller != listing.seller) revert EscrowSellerMismatch();
        // Audit M-1: reject zero-amount escrows even if the listing
        // somehow also signed askPriceXom=0 (which would slip past
        // the equality check below).
        if (amount == 0) revert EscrowAmountZero();
        if (amount != listing.askPriceXom) revert EscrowAmountMismatch();
    }

    // ─── ERC2771 Overrides (diamond with Pausable's Context) ─────────

    /**
     * @notice Resolve `_msgSender` between Context (via Pausable) and
     *         ERC2771Context. Mirrors {MinimalEscrow}'s override so
     *         relay-submitted calls credit the original signer.
     * @return sender The effective caller.
     */
    function _msgSender()
        internal
        view
        override(Context, ERC2771Context)
        returns (address sender)
    {
        return ERC2771Context._msgSender();
    }

    /**
     * @notice Resolve `_msgData` between Context and ERC2771Context.
     * @return data Calldata with the forwarder's appended address
     *              stripped when applicable.
     */
    function _msgData()
        internal
        view
        override(Context, ERC2771Context)
        returns (bytes calldata data)
    {
        return ERC2771Context._msgData();
    }

    /**
     * @notice Length of the suffix ERC2771 appends to forwarded calls.
     *         Default OpenZeppelin value. Pulled into an explicit
     *         override so the diamond compiles cleanly.
     * @return length The fixed 20-byte address suffix length.
     */
    function _contextSuffixLength()
        internal
        view
        override(Context, ERC2771Context)
        returns (uint256 length)
    {
        return ERC2771Context._contextSuffixLength();
    }

    /**
     * @notice Compute keccak256(abi.encode(LISTING_TYPEHASH, …)) for a
     *         given Listing. Pure for cheap on-chain digest mirroring.
     * @param listing The Listing struct.
     * @return structHash The struct hash.
     */
    function _hashListing(Listing calldata listing)
        internal
        pure
        returns (bytes32 structHash)
    {
        return keccak256(
            abi.encode(
                LISTING_TYPEHASH,
                listing.seller,
                listing.buyer,
                listing.nftContract,
                listing.tokenId,
                listing.askPriceXom,
                listing.expiry,
                listing.nonce,
                listing.marketplaceFeeBps
            )
        );
    }
}
