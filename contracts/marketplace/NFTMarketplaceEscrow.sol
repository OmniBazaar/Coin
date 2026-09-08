// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import {ERC2771Context} from "@openzeppelin/contracts/metatx/ERC2771Context.sol";
import {Context} from "@openzeppelin/contracts/utils/Context.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/**
 * @title  NFTMarketplaceEscrow
 * @author OmniCoin Development Team
 * @notice Self-contained NFT-for-XOM atomic settlement contract. Owns
 *         its own escrow lifecycle — buyer locks XOM into THIS
 *         contract (not MinimalEscrow), seller signs a `Listing`,
 *         buyer signs a `FillAuthorization`, anyone can submit
 *         {fillListing} which atomically releases XOM (less fee) to
 *         seller AND pulls the NFT to buyer in one transaction.
 *
 * @dev v1 (`NFTMarketplaceEscrow.sol` at
 *      `0x10F3687c5e491a2F380d87D0756c782051ef14c2`) was a thin router
 *      on top of `MinimalEscrow.releaseFundsViaContract`. That function
 *      was committed to source but never re-deployed; the live
 *      MinimalEscrow at `0x1Bbce5CC4d985178F28DE86597dC7747A4E4d4A7`
 *      doesn't have it. v1 went paused-on-arrival. v2 (this contract)
 *      removes the MinimalEscrow dependency by holding the escrow
 *      locally — same fee economics, same UnifiedFeeVault recipient,
 *      same EIP-712 domain shape, simpler buyer ceremony (one sig
 *      instead of two).
 *
 *      Full forensics + design rationale are recorded internally.
 *      Audit history: audited 2026-05-16; bytecode-drift sweep 2026-05-17
 *      caught the v1 issue.
 *
 * @dev DISPUTE MODEL — ABSENT BY DESIGN.
 *
 *      Unlike `MinimalEscrow`, NFTMarketplaceEscrow does NOT support
 *      dispute, arbitration, voting, counter-party stake, or any
 *      third-party adjudication path. Atomic fill is final the moment
 *      `fillListing` confirms.
 *
 *      Buyer protection: the buyer signed for the exact NFT digest
 *      (`FillAuthorization` binds `listingDigest`). The seller signed
 *      for the exact price (`Listing`). On-chain `transferFrom` +
 *      `safeTransfer` execute atomically inside `fillListing` —
 *      either both legs land or neither does. There is no stuck-state
 *      requiring arbitration.
 *
 *      Buyer protection against unresponsive sellers: post-expiry
 *      `refundBuyer` returns the full escrowed amount with no fee.
 *
 *      Seller voluntary refund: `releaseToBuyer` can be called by the
 *      seller at any time pre-resolution to return the buyer's funds
 *      immediately (no expiry wait, no buyer involvement).
 *
 *      Trades that may need subjective adjudication (physical-good
 *      condition, NFT authenticity disputes, etc.) MUST use the legacy
 *      `MinimalEscrow` 2-tx flow, which retains its
 *      `commitDispute` → `resolveDispute` machinery.
 *
 *      Wallet UX MUST surface this to the buyer prior to the
 *      `FillAuthorization` typed-data prompt.
 *
 * @dev Re-entrancy: `nonReentrant` on every state-mutating external.
 *      CEI: state writes (resolved=true, amount=0, nonce consumed)
 *      precede the two external `safeTransfer` calls and the
 *      `IERC721.transferFrom`. A malicious `nftContract` chosen by
 *      the listing can revert during `transferFrom` (which reverts
 *      the whole tx — buyer is never charged without getting the
 *      NFT) but cannot re-enter the router thanks to `nonReentrant`.
 *      No `safeTransferFrom` on the NFT — avoids the
 *      `onERC721Received` callback surface entirely (matches Seaport
 *      / 0x v4 pattern).
 *
 * @dev Gasless: ERC2771Context. OmniForwarder is the trusted
 *      forwarder; `_msgSender()` resolves to the buyer when invoked
 *      via the relay. `pause` / `unpause` use raw `msg.sender` so
 *      the emergency switch cannot depend on the forwarder being
 *      healthy.
 *
 * @custom:audit Awaiting v2's own 7-pass audit. All v1 audit
 *               findings (C-1/H-2/H-3/M-1/M-3/M-5 from pass 1,
 *               C-01/H-01/L-03/M-04 from passes 2-7) transfer
 *               structurally; net-new audit surface is the escrow
 *               lifecycle (createEscrow / refundBuyer /
 *               releaseToBuyer) + the fee body inlined from
 *               MinimalEscrow.
 */
contract NFTMarketplaceEscrow is
    ReentrancyGuard,
    Pausable,
    ERC2771Context,
    EIP712
{
    using SafeERC20 for IERC20;

    // ─── Types ────────────────────────────────────────────────────────

    /**
     * @notice Per-escrow state. Packed to 3 storage slots.
     * @param buyer    Address that funded the escrow.
     * @param expiry   Unix-seconds expiry. Settlement window is
     *                 `[creation, expiry]` (inclusive). Refund window
     *                 is `(expiry, +∞)`. Boundary semantics: at
     *                 `block.timestamp == expiry`, `fillListing`
     *                 succeeds (settlement allowed at the boundary
     *                 second); `refundBuyer` reverts `EscrowNotExpired`
     *                 (refund requires strictly past expiry). One
     *                 second after expiry, `fillListing` reverts
     *                 `EscrowExpired`; `refundBuyer` succeeds. No
     *                 overlap, no gap.
     * @param resolved True once the escrow has reached a terminal
     *                 state (filled, refunded, or seller-released).
     *                 Resolved escrows can never be re-released.
     * @param seller   NFT seller authorized to receive XOM on fill.
     * @param amount   XOM amount held by this escrow (smallest units).
     *                 Zero once resolved.
     */
    struct Escrow {
        address buyer;
        uint64 expiry;
        bool resolved;
        address seller;
        uint256 amount;
    }

    /**
     * @notice Seller's signed listing envelope. Identical shape to v1.
     * @param seller            EVM address of the NFT owner. Must
     *                          match signature recovery.
     * @param buyer             Optional buyer binding. Non-zero =
     *                          OTC trade restricted to that address;
     *                          zero = permissionless open listing
     *                          (v1 audit C-1).
     * @param nftContract       ERC-721 contract address.
     * @param tokenId           Token id within `nftContract`.
     * @param askPriceXom       Required `escrow.amount` on the matched
     *                          escrow (smallest XOM units).
     * @param expiry            Unix seconds after which the listing
     *                          cannot be filled.
     * @param nonce             Per-seller monotonic counter; consumed
     *                          on first fill to prevent replay.
     * @param marketplaceFeeBps Fee in basis points the seller agreed
     *                          to at listing time. Asserted equal to
     *                          this contract's immutable
     *                          `MARKETPLACE_FEE_BPS` on fill.
     */
    // CON-1 (N-L5): `marketplaceFeeBps` widened to `uint256` so the
    // struct field, the contract immutable, the event field, and the
    // EIP-712 type string all agree on width. The struct no longer
    // benefits from `gas-struct-packing` because every member is now a
    // full-slot type — the disable comment is retained because the
    // surrounding solhint config is unchanged.
    // solhint-disable-next-line gas-struct-packing
    struct Listing {
        address seller;
        address buyer;
        address nftContract;
        uint256 tokenId;
        uint256 askPriceXom;
        uint256 expiry;
        uint256 nonce;
        uint256 marketplaceFeeBps;
    }

    // ─── Constants ────────────────────────────────────────────────────

    /// @notice Required signature length for ECDSA recovery.
    uint256 public constant SIGNATURE_LENGTH = 65;

    /// @notice Denominator for basis-point math.
    uint256 public constant BASIS_POINTS = 10_000;

    /// @notice Gas forwarded to a listed collection's `royaltyInfo`
    ///         during settlement (N-ROY audit I-1). `listing.nftContract`
    ///         is seller-chosen, so the EIP-2981 lookup is gas-bounded to
    ///         stop a malicious collection from burning the relayer's gas
    ///         (gasless path) by returning after consuming all forwarded
    ///         gas. 50k is generous for a conforming `royaltyInfo` (an OZ
    ///         ERC2981 lookup is a single SLOAD + mulDiv, well under 5k);
    ///         a collection whose royalty logic exceeds this ceiling is
    ///         treated as paying no royalty (the call out-of-gases, is
    ///         caught, and the full post-fee amount goes to the seller).
    uint256 private constant ROYALTY_GAS_LIMIT = 50_000;

    /// @notice Minimum escrow duration. Mirrors `MinimalEscrow.MIN_DURATION`
    ///         so buyers can't accidentally pick a near-instant expiry.
    uint64 public constant MIN_ESCROW_DURATION = 1 hours;

    /// @notice Maximum escrow duration. Mirrors `MinimalEscrow.MAX_DURATION`
    ///         (30 days) so the listing-expiry bound matches expectations
    ///         users learned from the legacy escrow flow.
    uint64 public constant MAX_ESCROW_DURATION = 30 days;

    /// @notice EIP-712 type hash for the `Listing` struct.
    /// @dev Order MUST match struct field order. solhint suppressions
    ///      acknowledge that EIP-712 requires the canonical multi-field
    ///      signature string.
    ///      CON-1 (N-L5): `marketplaceFeeBps` widened from `uint64` to
    ///      `uint256` so the on-chain immutable, the struct field, the
    ///      event field, and the typed-data tuple all carry the same
    ///      width — eliminates the silent cast surface flagged by the
    ///      audit. The narrower width was never a real saving (struct
    ///      packing of `uint256` … `uint64` left the same 32-byte slot
    ///      occupied anyway).
    bytes32 public constant LISTING_TYPEHASH = keccak256( // solhint-disable-line gas-small-strings
        // solhint-disable-next-line max-line-length, gas-small-strings
        "Listing(address seller,address buyer,address nftContract,uint256 tokenId,uint256 askPriceXom,uint256 expiry,uint256 nonce,uint256 marketplaceFeeBps)"
    );

    /// @notice EIP-712 type hash for the buyer's `FillAuthorization`
    ///         envelope (v1 audit C-01).
    /// @dev The buyer's single fill-side sig — pins their intent to
    ///      a specific listing digest. v2 has no second buyer sig.
    bytes32 public constant FILL_AUTHORIZATION_TYPEHASH = keccak256( // solhint-disable-line gas-small-strings
        // solhint-disable-next-line gas-small-strings
        "FillAuthorization(uint256 escrowId,bytes32 listingDigest,uint256 deadline)"
    );

    // ─── Immutables ───────────────────────────────────────────────────

    /// @notice XOM token. Buyer-side escrowed funds live here.
    IERC20 public immutable OMNI_COIN;

    /// @notice Recipient of the marketplace fee skim. Same
    ///         UnifiedFeeVault address `MinimalEscrow` uses, so the
    ///         downstream fee accounting / split logic treats fills
    ///         from v2 identically to fills from the legacy 2-tx flow.
    address public immutable FEE_VAULT;

    /// @notice Marketplace fee in basis points (1% = 100). Set once at
    ///         construction; not mutable. The deployer is expected to
    ///         pass the same value `MinimalEscrow.MARKETPLACE_FEE_BPS`
    ///         currently returns so fill economics stay aligned.
    /// @dev CON-1 (N-L5): widened from `uint64` to `uint256` so every
    ///      site that touches the fee carries the same width.
    uint256 public immutable MARKETPLACE_FEE_BPS;

    /// @notice Current admin for pause/unpause + admin transfer.
    /// @dev CON-1 (N-M1): admin is mutable so the role can be rotated
    ///      without redeploying. Transfer goes through a two-step
    ///      propose/accept handshake (`proposeAdmin` / `acceptAdmin`)
    ///      to avoid setting the role to a wallet that cannot actually
    ///      claim it. The initial value is the deployer.
    address public admin;

    /// @notice Address proposed as the next admin (zero = no pending transfer).
    /// @dev CON-1: the prospective admin must call `acceptAdmin()` to
    ///      finalize. Either the current admin (via `proposeAdmin(0)`) or
    ///      the prospective admin (by simply never calling accept) can
    ///      cancel the transfer.
    address public pendingAdmin;

    // ─── State ────────────────────────────────────────────────────────

    /// @notice Per-escrow records.
    mapping(uint256 => Escrow) public escrows;

    /// @notice Monotonic id assigner. Pre-increment on createEscrow
    ///         so escrowId 0 stays unused (sentinel for "no escrow").
    uint256 public escrowCounter;

    /// @notice Consumed seller nonces. True = already filled or
    ///         cancelled; subsequent matching listings revert.
    mapping(address => mapping(uint256 => bool)) public sellerNonces;

    // ─── Events ───────────────────────────────────────────────────────

    /**
     * @notice Emitted on `createEscrow`. Indexers track this to mark
     *         offers as `escrow_pending` in the marketplace DB.
     * @param escrowId Newly assigned escrow id.
     * @param buyer    Funding wallet (`_msgSender()`).
     * @param seller   Intended counter-party.
     * @param amount   XOM amount locked.
     * @param expiry   Unix-seconds expiry.
     */
    event EscrowCreated(
        uint256 indexed escrowId,
        address indexed buyer,
        address indexed seller,
        uint256 amount,
        uint64 expiry
    );

    /**
     * @notice Emitted on successful atomic settlement. Mirrors v1 +
     *         adds the consumed seller nonce (v1 audit L-02 follow-up).
     * @param seller             NFT seller (XOM recipient).
     * @param buyer              NFT recipient (== `escrow.buyer`, the
     *                           address that funded the escrow). Audit
     *                           v2 H-01: this is NOT the tx submitter
     *                           — recipient-hijack via mempool replay
     *                           is closed.
     * @param nftContract        ERC-721 collection.
     * @param tokenId            Token transferred.
     * @param escrowId           Escrow funding the buyer's leg.
     * @param marketplaceFeeBps  Fee bps actually applied (from listing).
     * @custom:note The consumed seller nonce can be derived from the
     *              listing struct that produced the call — indexers
     *              fetching by `(seller, listingDigest)` reconstruct
     *              it without an indexed event field.
     */
    event ListingFilled(
        address indexed seller,
        address indexed buyer,
        address indexed nftContract,
        uint256 tokenId,
        uint256 escrowId,
        uint256 marketplaceFeeBps
    );

    /**
     * @notice Emitted on `refundBuyer` (post-expiry) or
     *         `releaseToBuyer` (seller-initiated). Same shape for both
     *         paths — indexer can tell them apart by tx caller.
     * @dev `amount` is not indexed because indexers filter by
     *      `escrowId` / `buyer`; a value-typed indexed bytes32 of
     *      `amount` would not be a useful query key.
     * @param escrowId Escrow that was refunded.
     * @param buyer    Recipient of the returned XOM.
     * @param amount   Returned amount.
     * @custom:solhint gas-indexed-events is intentionally not applied
     *                 — value-typed indexed fields are not useful as
     *                 query keys for indexers that filter by
     *                 escrowId/buyer.
     */
    event EscrowRefunded(
        uint256 indexed escrowId,
        address indexed buyer,
        uint256 amount
    );

    /**
     * @notice Emitted when a fee skim hits the FEE_VAULT. Same event
     *         name + shape `MinimalEscrow` uses so downstream
     *         marketplace-fee accounting / splitters treat both
     *         sources identically.
     * @param escrowId  Escrow that produced the fee.
     * @param feeVault  Recipient (`FEE_VAULT`).
     * @param feeAmount Skimmed amount.
     * @custom:solhint gas-indexed-events intentional — value-typed
     *                 indexed fields aren't useful for indexer query
     *                 patterns (filter by escrowId/feeVault).
     */
    event MarketplaceFeeCollected(
        uint256 indexed escrowId,
        address indexed feeVault,
        uint256 feeAmount
    );

    /**
     * @notice Emitted when an EIP-2981 creator royalty is paid out of a
     *         fill's proceeds (N-ROY). Absent when the listed collection
     *         does not implement ERC-2981 or returns a zero royalty.
     * @param escrowId         Escrow that produced the royalty.
     * @param nftContract      Collection whose `royaltyInfo` was honored.
     * @param tokenId          Token sold.
     * @param royaltyRecipient Creator address paid the royalty.
     * @param royaltyAmount    XOM paid to the creator.
     * @custom:solhint gas-indexed-events intentional — recipient/amount
     *                 are filtered by escrowId/nftContract/tokenId.
     */
    event RoyaltyPaid(
        uint256 indexed escrowId,
        address indexed nftContract,
        uint256 indexed tokenId,
        address royaltyRecipient,
        uint256 royaltyAmount
    );

    /**
     * @notice Emitted when a seller burns one of their own listing
     *         nonces off-fill via {cancelListingNonce}. v1 audit M-04
     *         carry. Lets indexers prune cancelled listings without
     *         a full event scan.
     * @param seller Seller whose nonce is now consumed.
     * @param nonce  Cancelled nonce.
     */
    event ListingNonceCancelled(address indexed seller, uint256 indexed nonce);

    /// @notice Emitted when the current admin proposes a new admin.
    /// @dev CON-1 (N-M1): first half of the two-step admin handoff.
    /// @param currentAdmin   Admin at the time of the proposal.
    /// @param proposedAdmin  Wallet that must call `acceptAdmin` to take the role.
    event AdminTransferProposed(
        address indexed currentAdmin,
        address indexed proposedAdmin
    );

    /// @notice Emitted when an admin transfer completes.
    /// @dev CON-1 (N-M1): second half of the two-step admin handoff.
    /// @param oldAdmin Previous admin.
    /// @param newAdmin Wallet that called `acceptAdmin`.
    event AdminTransferred(
        address indexed oldAdmin,
        address indexed newAdmin
    );

    // ─── Errors ───────────────────────────────────────────────────────

    /// @notice Zero address supplied where a real address is required.
    error InvalidAddress();

    /// @notice Escrow duration outside `[MIN_ESCROW_DURATION,
    ///         MAX_ESCROW_DURATION]`.
    error InvalidDuration();

    /// @notice `createEscrow` amount must be greater than zero.
    error AmountZero();

    /// @notice Buyer cannot escrow against themselves.
    error SelfEscrowForbidden();

    /// @notice Listing expired (block.timestamp > listing.expiry).
    error ListingExpired();

    /// @notice `listing.expiry` more than `MAX_ESCROW_DURATION` in the
    ///         future (prevents indefinite-lifetime sigs).
    error ListingExpiryTooFar();

    /// @notice Listing's `marketplaceFeeBps` doesn't match this
    ///         contract's immutable. Stale listing signed against an
    ///         older fee setting.
    error FeeBpsMismatch();

    /// @notice Signature is not exactly 65 bytes long.
    error InvalidSignatureLength();

    /// @notice Seller's signature doesn't recover to `listing.seller`.
    error InvalidSellerSignature();

    /// @notice `(listing.seller, listing.nonce)` already consumed.
    error NonceAlreadyConsumed();

    /// @notice Filler is not the listing's bound buyer (v1 audit C-1).
    error FillerNotAuthorized();

    /// @notice Buyer release sig deadline exceeds listing.expiry
    ///         (v1 audit H-01).
    error BuyerDeadlineExceedsListingExpiry();

    /// @notice Buyer sig deadline already passed.
    error DeadlinePassed();

    /// @notice Buyer's `FillAuthorization` signature didn't recover
    ///         to the funding escrow's buyer (v1 audit C-01).
    error InvalidBuyerAuthorization();

    /// @notice The supplied `escrowId` has no record.
    error EscrowNotFound();

    /// @notice The escrow has already been resolved (filled, refunded,
    ///         or released).
    error EscrowAlreadyResolved();

    /// @notice The escrow has not yet reached its expiry — refund is
    ///         not yet available to the buyer.
    error EscrowNotExpired();

    /// @notice The escrow's seller doesn't match the listing's seller.
    error EscrowSellerMismatch();

    /// @notice The escrow's amount doesn't match the listing's
    ///         `askPriceXom`. Sanity guard against partial-fill
    ///         attempts.
    error EscrowAmountMismatch();

    /// @notice On-chain `escrow.expiry` already passed — buyer is
    ///         entitled to a refund and fillListing must NOT settle
    ///         against the stale escrow.
    error EscrowExpired();

    /// @notice Caller of a buyer-only path isn't the escrow's buyer.
    error NotEscrowBuyer();

    /// @notice Caller of a seller-only path isn't the escrow's seller.
    error NotEscrowSeller();

    /// @notice Listing's `nftContract` is the zero address (v1 L-03).
    error InvalidNftContract();

    /// @notice Caller of admin function isn't the recorded ADMIN.
    error NotAdmin();

    /// @notice Caller of `acceptAdmin` is not the recorded `pendingAdmin`.
    error NotPendingAdmin();

    // ─── Constructor ──────────────────────────────────────────────────

    /**
     * @notice Wire the immutables.
     * @param _omniCoin           OmniCoin XOM token address.
     * @param _feeVault           UnifiedFeeVault address (or whatever
     *                            `MinimalEscrow.FEE_VAULT()` returns).
     * @param _marketplaceFeeBps  Marketplace fee bps. Caller should
     *                            pass the value
     *                            `MinimalEscrow.MARKETPLACE_FEE_BPS()`
     *                            currently returns so v1 + v2 paths
     *                            stay economically aligned.
     * @param _trustedForwarder   OmniForwarder for gasless meta-tx.
     */
    constructor(
        address _omniCoin,
        address _feeVault,
        uint256 _marketplaceFeeBps,
        address _trustedForwarder
    )
        ERC2771Context(_trustedForwarder)
        EIP712("OmniBazaar NFTMarketplaceEscrow", "1")
    {
        if (_omniCoin == address(0)) revert InvalidAddress();
        if (_feeVault == address(0)) revert InvalidAddress();
        OMNI_COIN = IERC20(_omniCoin);
        FEE_VAULT = _feeVault;
        MARKETPLACE_FEE_BPS = _marketplaceFeeBps;
        admin = msg.sender;
    }

    // ─── Admin: pause / unpause / transfer ────────────────────────────

    /**
     * @notice Pause new escrow creation + new fills. Admin-only.
     * @dev    Uses raw `msg.sender` (not `_msgSender()`) intentionally:
     *         the emergency switch must not depend on the forwarder
     *         being healthy, since a compromised forwarder is one of
     *         the scenarios that justifies a pause.
     *
     *         Pre-existing escrows remain refundable via
     *         {refundBuyer} (after expiry) or {releaseToBuyer}
     *         (seller-initiated, any time) — neither is gated by
     *         `whenNotPaused`. Users always retain a path to their
     *         funds.
     */
    function pause() external {
        if (msg.sender != admin) revert NotAdmin();
        _pause();
    }

    /// @notice Resume new escrow creation + new fills. Admin-only.
    function unpause() external {
        if (msg.sender != admin) revert NotAdmin();
        _unpause();
    }

    /**
     * @notice Propose a new admin (first half of the CON-1 two-step
     *         handoff). Pass `address(0)` to cancel a pending proposal.
     * @dev Admin-only. The proposed wallet must subsequently call
     *      {acceptAdmin} to take the role. The two-step pattern stops
     *      the role from being assigned to a wallet that cannot actually
     *      claim it (typo, contract that can't sign, etc.). Uses raw
     *      `msg.sender` for the same reason as {pause} — admin paths
     *      must not depend on a healthy forwarder.
     * @param newAdmin Wallet to be granted the admin role on accept,
     *                 or `address(0)` to clear any pending proposal.
     */
    function proposeAdmin(address newAdmin) external {
        if (msg.sender != admin) revert NotAdmin();
        pendingAdmin = newAdmin;
        emit AdminTransferProposed(admin, newAdmin);
    }

    /**
     * @notice Accept a pending admin transfer (second half of the CON-1
     *         two-step handoff). Only callable by the address recorded
     *         in {pendingAdmin}.
     * @dev Clears `pendingAdmin` and rotates `admin` atomically. After
     *      this call returns, the previous admin loses access to
     *      {pause} / {unpause} / {proposeAdmin}. Re-uses `msg.sender`
     *      (not `_msgSender()`) for forwarder-independence.
     */
    function acceptAdmin() external {
        if (msg.sender != pendingAdmin) revert NotPendingAdmin();
        address previous = admin;
        admin = msg.sender;
        pendingAdmin = address(0);
        emit AdminTransferred(previous, msg.sender);
    }

    // ─── Buyer-facing externals ──────────────────────────────────────

    /**
     * @notice Buyer locks `amount` XOM into a new escrow for the named
     *         seller. The buyer must have pre-approved this contract
     *         for at least `amount` XOM via `OMNI_COIN.approve(...)`.
     *
     * @dev    Escrow id is a fresh monotonic counter (starting at 1;
     *         id 0 is the sentinel "no escrow"). `_msgSender()`
     *         resolves through ERC-2771 so the gasless relay flow
     *         correctly assigns the buyer.
     *
     *         CEI: `escrows` slot is written before the `safeTransferFrom`
     *         external. If the transfer reverts (insufficient balance
     *         or approval), the whole tx reverts and the slot writes
     *         roll back — no orphaned escrow records.
     *
     * @param seller    Counter-party that may fill the listing.
     * @param amount    XOM amount to escrow (must be > 0).
     * @param duration  Escrow lifetime in seconds. Must be in
     *                  `[MIN_ESCROW_DURATION, MAX_ESCROW_DURATION]`.
     * @return escrowId Newly assigned escrow id.
     */
    function createEscrow(
        address seller,
        uint256 amount,
        uint64 duration
    ) external nonReentrant whenNotPaused returns (uint256 escrowId) {
        if (seller == address(0)) revert InvalidAddress();
        address buyer_ = _msgSender();
        if (seller == buyer_) revert SelfEscrowForbidden();
        if (amount == 0) revert AmountZero();
        if (duration < MIN_ESCROW_DURATION || duration > MAX_ESCROW_DURATION) {
            revert InvalidDuration();
        }

        unchecked {
            escrowId = ++escrowCounter;
        }
        // solhint-disable-next-line not-rely-on-time
        uint64 expiry = uint64(block.timestamp) + duration;
        escrows[escrowId] = Escrow({
            buyer: buyer_,
            expiry: expiry,
            resolved: false,
            seller: seller,
            amount: amount
        });

        emit EscrowCreated(escrowId, buyer_, seller, amount, expiry);

        // External — pulls XOM from buyer. SafeERC20 reverts on
        // non-standard tokens; OmniCoin is well-behaved so this is a
        // belt-and-braces guard.
        OMNI_COIN.safeTransferFrom(buyer_, address(this), amount);
    }

    /**
     * @notice Buyer reclaims their XOM after expiry. No fee.
     * @dev    Requires `block.timestamp > escrow.expiry`. The
     *         strict-greater ordering matches `MinimalEscrow`'s
     *         convention (the buyer can refund at the exact second
     *         past expiry; fills are blocked at the same instant).
     *
     * @param escrowId Escrow to refund.
     */
    function refundBuyer(uint256 escrowId) external nonReentrant {
        Escrow storage escrow = escrows[escrowId];
        if (escrow.buyer == address(0)) revert EscrowNotFound();
        if (escrow.resolved) revert EscrowAlreadyResolved();
        if (_msgSender() != escrow.buyer) revert NotEscrowBuyer();
        // Strict inequality: refund allowed only when block.timestamp
        // is past the expiry boundary (matches `fillListing`'s
        // ` > listing.expiry` cutoff so the two paths can't collide
        // on the boundary second).
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp < escrow.expiry + 1) revert EscrowNotExpired();

        uint256 amount = escrow.amount;
        address buyer_ = escrow.buyer;
        escrow.resolved = true;
        escrow.amount = 0;

        emit EscrowRefunded(escrowId, buyer_, amount);

        OMNI_COIN.safeTransfer(buyer_, amount);
    }

    /**
     * @notice Seller voluntarily returns the buyer's funds at any time
     *         before resolution. Use case: seller realizes they can't
     *         deliver and doesn't want to make the buyer wait out the
     *         expiry. No fee on this path.
     *
     * @param escrowId Escrow to release back to the buyer.
     */
    function releaseToBuyer(uint256 escrowId) external nonReentrant {
        Escrow storage escrow = escrows[escrowId];
        if (escrow.buyer == address(0)) revert EscrowNotFound();
        if (escrow.resolved) revert EscrowAlreadyResolved();
        if (_msgSender() != escrow.seller) revert NotEscrowSeller();

        uint256 amount = escrow.amount;
        address buyer_ = escrow.buyer;
        escrow.resolved = true;
        escrow.amount = 0;

        emit EscrowRefunded(escrowId, buyer_, amount);

        OMNI_COIN.safeTransfer(buyer_, amount);
    }

    // ─── Seller-facing externals ─────────────────────────────────────

    /**
     * @notice Seller burns one of their own listing nonces off-fill.
     *         Lets a seller invalidate a previously-signed listing
     *         without waiting for expiry — v1 audit M-04 carry.
     *
     * @dev    Marks `sellerNonces[_msgSender()][nonce] = true`. Any
     *         pre-signed listing using `_msgSender()` as seller and
     *         this `nonce` becomes unfillable. Reverts if the nonce
     *         is already consumed (idempotent on the cancelled state).
     *
     *         INTENTIONALLY NOT `whenNotPaused`. A seller whose
     *         signature has leaked during an emergency must still
     *         be able to burn the nonce immediately. While the
     *         router is paused, `fillListing` is blocked too — so a
     *         leaked sig cannot settle during the window — but
     *         sellers should not be locked out of self-help.
     *
     * @param nonce Listing nonce to burn.
     */
    function cancelListingNonce(uint256 nonce) external {
        if (sellerNonces[_msgSender()][nonce]) revert NonceAlreadyConsumed();
        sellerNonces[_msgSender()][nonce] = true;
        emit ListingNonceCancelled(_msgSender(), nonce);
    }

    // ─── Atomic settle (permissionless) ──────────────────────────────

    /**
     * @notice Atomically release the buyer's escrow XOM to the seller
     *         (less fee) AND transfer the NFT from seller to buyer in
     *         one transaction.
     *
     * @dev Flow:
     *      1. C-1: if listing binds a specific buyer, reject other
     *         fillers.
     *      2. H-01: buyer's deadline must not outlive listing.expiry.
     *      3. `_validateListing` — sig recovery, expiry, fee match,
     *         nonce freshness, nftContract != 0 (L-03).
     *      4. `_validateEscrowAgainstListing` — escrow exists, not
     *         resolved, not expired (H-2), seller match, amount match.
     *      5. C-01: recover the buyer's FillAuthorization signer and
     *         compare against `escrow.buyer`. Reject mismatch.
     *      6. Consume the seller nonce (state write before externals).
     *      7. Mark escrow resolved, zero amount (state write before externals).
     *      8. Compute fee + recipient amount.
     *      9. External: safeTransfer fee → FEE_VAULT.
     *     10. External: safeTransfer seller-share → seller.
     *     11. External: IERC721.transferFrom seller → buyer.
     *     12. Emit ListingFilled.
     *
     *      Anyone with valid sigs can submit; the NFT lands at
     *      `_msgSender()` for open listings, or at `listing.buyer` for
     *      OTC-bound listings (enforced via the C-1 check that
     *      `_msgSender() == listing.buyer`).
     *
     * @param listing                Seller's signed listing envelope.
     * @param sellerSignature        65-byte ECDSA sig over the Listing.
     * @param escrowId               Funding escrow id.
     * @param buyerFillAuthorization 65-byte ECDSA sig over the buyer's
     *                               FillAuthorization payload.
     * @param buyerDeadline          Unix-seconds deadline the buyer
     *                               committed to in FillAuthorization.
     */
    function fillListing(
        Listing calldata listing,
        bytes calldata sellerSignature,
        uint256 escrowId,
        bytes calldata buyerFillAuthorization,
        uint256 buyerDeadline
    ) external nonReentrant whenNotPaused {
        if (listing.buyer != address(0) && _msgSender() != listing.buyer) {
            revert FillerNotAuthorized();
        }
        if (buyerDeadline > listing.expiry) {
            revert BuyerDeadlineExceedsListingExpiry();
        }

        // Listing-side checks before deadline-passed so the more
        // specific `ListingExpired` revert fires when both an expired
        // listing and a past buyerDeadline are present (a stale signed
        // pair). Better UX than a vague "deadline passed".
        _validateListing(listing, sellerSignature);
        Escrow storage escrow = _validateEscrowAgainstListing(escrowId, listing);

        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp > buyerDeadline) revert DeadlinePassed();
        _verifyBuyerFillAuthorization(
            listing,
            escrowId,
            buyerDeadline,
            buyerFillAuthorization,
            escrow.buyer
        );

        // CEI: consume nonce + mark escrow resolved BEFORE externals.
        sellerNonces[listing.seller][listing.nonce] = true;
        uint256 amount = escrow.amount;
        address escrowBuyer = escrow.buyer;
        escrow.resolved = true;
        escrow.amount = 0;

        uint256 feeAmount = (amount * MARKETPLACE_FEE_BPS) / BASIS_POINTS;
        uint256 afterFee = amount - feeAmount;

        // N-ROY: honor EIP-2981 creator royalties (see {_resolveRoyalty}).
        (address royaltyRecipient, uint256 royaltyAmount) = _resolveRoyalty(
            listing.nftContract,
            listing.tokenId,
            amount,
            afterFee
        );

        uint256 sellerAmount = afterFee - royaltyAmount;

        if (feeAmount > 0) {
            OMNI_COIN.safeTransfer(FEE_VAULT, feeAmount);
            emit MarketplaceFeeCollected(escrowId, FEE_VAULT, feeAmount);
        }
        if (royaltyAmount > 0) {
            OMNI_COIN.safeTransfer(royaltyRecipient, royaltyAmount);
            emit RoyaltyPaid(
                escrowId,
                listing.nftContract,
                listing.tokenId,
                royaltyRecipient,
                royaltyAmount
            );
        }
        OMNI_COIN.safeTransfer(listing.seller, sellerAmount);

        // Audit v2 H-01 remediation: NFT recipient is the ESCROW
        // BUYER, NOT the tx submitter. Without this, a frontrunner
        // who extracts a leaked FillAuthorization sig from the
        // mempool could re-submit fillListing with their own
        // `_msgSender()` and steal the NFT while the escrow buyer's
        // XOM still pays for it. Hard-coding `escrow.buyer` as
        // recipient closes the gap structurally — the address that
        // paid for the trade is always the address that gets the NFT.
        //
        // For OTC listings (`listing.buyer != 0`), the C-1 check
        // already ensures the submitter is `listing.buyer`. The
        // expected flow is that the OTC buyer also funded the escrow
        // (so `escrow.buyer == listing.buyer == _msgSender()`); if a
        // third party funded the escrow on the OTC buyer's behalf,
        // the NFT still flows to whoever's XOM paid for it, which is
        // the safer default.
        //
        // Plain transferFrom — no `onERC721Received` callback surface.
        IERC721(listing.nftContract).transferFrom(
            listing.seller,
            escrowBuyer,
            listing.tokenId
        );

        emit ListingFilled(
            listing.seller,
            escrowBuyer,
            listing.nftContract,
            listing.tokenId,
            escrowId,
            listing.marketplaceFeeBps
        );
    }

    /**
     * @notice Resolve the EIP-2981 creator royalty owed on a fill.
     * @dev    Queries the listed collection's `royaltyInfo` over the
     *         full sale price. `IERC2981.royaltyInfo` is declared
     *         `view`, so the compiler emits a STATICCALL — no
     *         re-entrancy surface — gas-bounded to {ROYALTY_GAS_LIMIT}
     *         (I-1) so a seller-chosen collection cannot grief the
     *         relayer's gas, and the try/catch tolerates collections
     *         that don't implement ERC-2981 — or that exceed the gas
     *         ceiling — (returns a zero royalty). The royalty is
     *         defensively clamped to
     *         `maxRoyalty` (the proceeds remaining after the
     *         marketplace fee) so a misbehaving collection can never
     *         underflow the seller payout — worst case the seller, who
     *         chose to list that collection, receives zero.
     * @param  nftContract Collection to query.
     * @param  tokenId     Token being sold.
     * @param  salePrice   Full XOM sale price the royalty is computed on.
     * @param  maxRoyalty  Upper bound (proceeds after marketplace fee).
     * @return recipient   Creator address, or `address(0)` if none.
     * @return royalty      XOM owed to the creator, clamped to maxRoyalty.
     */
    function _resolveRoyalty(
        address nftContract,
        uint256 tokenId,
        uint256 salePrice,
        uint256 maxRoyalty
    ) private view returns (address recipient, uint256 royalty) {
        try
            IERC2981(nftContract).royaltyInfo{gas: ROYALTY_GAS_LIMIT}(
                tokenId,
                salePrice
            )
        returns (address royaltyRecipient, uint256 royaltyDue) {
            if (royaltyRecipient != address(0) && royaltyDue > 0) {
                recipient = royaltyRecipient;
                royalty = royaltyDue > maxRoyalty ? maxRoyalty : royaltyDue;
            }
        } catch {
            // Collection does not implement ERC-2981 — no royalty owed.
        }
    }

    // ─── Views (wallet helpers) ──────────────────────────────────────

    /**
     * @notice Compute the EIP-712 digest of a Listing under v2's
     *         domain. Wallets call this to sanity-check the digest
     *         they're prompting the user to sign.
     * @param  listing The Listing struct.
     * @return digest  The typed-data digest a wallet would sign.
     */
    function listingDigest(Listing calldata listing)
        external
        view
        returns (bytes32 digest)
    {
        return _hashTypedDataV4(_hashListing(listing));
    }

    /**
     * @notice Compute the EIP-712 digest of a FillAuthorization.
     *         Wallet helper for the C-01 second-sig.
     * @param  listing  The Listing being authorized.
     * @param  escrowId Escrow id funding the fill.
     * @param  deadline Unix-seconds deadline the buyer signs over.
     * @return digest   The typed-data digest a wallet would sign.
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

    /**
     * @notice Return the EIP-712 domain separator. Useful for
     *         off-chain signers that don't compute it themselves.
     * @return separator The cached or freshly computed domain separator.
     */
    function domainSeparator() external view returns (bytes32 separator) {
        return _domainSeparatorV4();
    }

    /**
     * @notice Compute the struct hash (pre-domain) of a Listing.
     *         Pure helper kept after the view helpers per Solidity
     *         pure/view function-ordering conventions.
     * @param  listing    The Listing struct.
     * @return structHash Keccak256 of the encoded Listing.
     */
    function hashListing(Listing calldata listing)
        external
        pure
        returns (bytes32 structHash)
    {
        return _hashListing(listing);
    }

    // ─── Internal helpers ─────────────────────────────────────────────

    /**
     * @notice Verify the seller's listing envelope: nftContract !=
     *         0 (L-03), expiry window, fee parity, sig shape +
     *         recovery, nonce freshness. Reverts on any failure
     *         with a typed error.
     * @param listing         Seller's signed listing envelope.
     * @param sellerSignature 65-byte ECDSA signature over the Listing.
     * @custom:complexity Cyclomatic complexity 8 (>7 default) is
     *                    inherent to the branch-count of typed
     *                    validation reverts; accepted per project
     *                    precedent (matches v1 + PrivateDEXSettlement).
     */
    function _validateListing(
        Listing calldata listing,
        bytes calldata sellerSignature
    ) internal view {
        if (listing.nftContract == address(0)) revert InvalidNftContract();
        // H-03: Reject EOA nftContract — IERC721.transferFrom to an EOA
        // succeeds silently, making the NFT delivery leg a no-op while the
        // XOM leg still pays out. A real ERC-721 collection has code.
        if (listing.nftContract.code.length == 0) revert InvalidNftContract();
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp > listing.expiry) revert ListingExpired();
        // solhint-disable-next-line not-rely-on-time
        if (listing.expiry > block.timestamp + MAX_ESCROW_DURATION) {
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
     * @notice Cross-check the funding escrow against the listing.
     *         Returns the escrow storage pointer so the caller
     *         doesn't have to re-read.
     * @param  escrowId Escrow id the buyer wants to use as funding.
     * @param  listing  Seller's listing envelope to match against.
     * @return escrow   Storage pointer to the validated escrow.
     */
    function _validateEscrowAgainstListing(
        uint256 escrowId,
        Listing calldata listing
    ) internal view returns (Escrow storage escrow) {
        // CON-1 (N-M2): SLOAD-dedupe via a single memory copy. The five
        // field reads below previously could compile to up to three
        // separate SLOAD operations on slot 0 (buyer / expiry / resolved
        // share a 32-byte slot) plus slot-1 + slot-2 reads. Loading the
        // whole struct into memory once guarantees exactly three SLOADs
        // regardless of optimizer settings. The returned storage pointer
        // is just a calldata reference — no read — so the caller still
        // gets a slot to write back to with `escrow.resolved = true` etc.
        Escrow memory esc = escrows[escrowId];
        if (esc.buyer == address(0)) revert EscrowNotFound();
        if (esc.resolved) revert EscrowAlreadyResolved();
        // H-2: an expired escrow belongs to the buyer (refundBuyer);
        // fillListing must NOT drain it.
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp > esc.expiry) revert EscrowExpired();
        if (esc.seller != listing.seller) revert EscrowSellerMismatch();
        if (esc.amount != listing.askPriceXom) {
            revert EscrowAmountMismatch();
        }
        escrow = escrows[escrowId];
    }

    /**
     * @notice Recover the buyer's FillAuthorization signer and compare
     *         against the escrow's recorded buyer (C-01).
     * @param listing                The listing being filled.
     * @param escrowId               Escrow id funding the fill.
     * @param buyerDeadline          Deadline the buyer committed to.
     * @param buyerFillAuthorization 65-byte ECDSA signature.
     * @param escrowBuyer            Address recorded as `escrow.buyer`.
     */
    function _verifyBuyerFillAuthorization(
        Listing calldata listing,
        uint256 escrowId,
        uint256 buyerDeadline,
        bytes calldata buyerFillAuthorization,
        address escrowBuyer
    ) internal view {
        if (buyerFillAuthorization.length != SIGNATURE_LENGTH) {
            revert InvalidSignatureLength();
        }
        // N-L2 semantic pin: `hashedListing` is the FULL EIP-712
        // typed-data digest of the Listing struct (domain-separated),
        // NOT a bare struct-hash. Off-chain clients MUST compute it via
        // `ethers.TypedDataEncoder.hash(domain, types, value)` — the
        // equivalent of `_hashTypedDataV4(_hashListing(listing))` —
        // before feeding it into the FillAuthorization typed-data
        // value. Using `TypedDataEncoder.hashStruct()` (struct-hash,
        // no domain) would silently produce a signature that recovers
        // to a different address and revert at `InvalidBuyerAuthorization`.
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
        if (recovered != escrowBuyer) revert InvalidBuyerAuthorization();
    }

    // ─── ERC2771 Overrides (diamond with Pausable's Context) ─────────
    //
    // Placed before the pure helper below so solhint's `pure-last`
    // ordering rule is satisfied (`internal view` precedes `internal
    // pure` in the file).

    /**
     * @notice Resolve `_msgSender` between Context and ERC2771Context.
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
     * @notice ERC2771 calldata suffix length override.
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
     * @notice Compute keccak256(abi.encode(LISTING_TYPEHASH, …)).
     * @param  listing    The Listing struct.
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
