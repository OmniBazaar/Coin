// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ReentrancyGuard} from
    "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ERC2771Context} from
    "@openzeppelin/contracts/metatx/ERC2771Context.sol";
import {Context} from "@openzeppelin/contracts/utils/Context.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from
    "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {RoyaltyResolver} from "../libraries/RoyaltyResolver.sol";
import {IOmniConduit} from "./interfaces/IOmniConduit.sol";

/**
 * @title  NFTExchange
 * @author OmniBazaar Team
 * @notice Non-custodial NFT settlement. The seller signs an order off
 *         chain; the buyer fills it in **one** transaction; the exchange
 *         holds neither the money nor the token at any point.
 *
 * @dev WHAT THIS REPLACES, AND WHY.
 *
 *      `NFTMarketplaceEscrow` (this contract's predecessor) got the token
 *      leg right and the money leg wrong. Its `createEscrow` pulled the
 *      buyer's tokens **into the contract** and paid them out in a later
 *      transaction, so buying was `approve → createEscrow → fillListing`:
 *      two transactions with a custody window between them. That was the
 *      only place in the whole NFT path where the platform held user
 *      funds, which sat badly beside a load-bearing non-custodial claim.
 *      OpenSea and Blur are one transaction and hold nothing; so is this.
 *      There is no `createEscrow` here and no escrow to create.
 *
 *      It also hard-coded a single payment token
 *      (`IERC20 public immutable OMNI_COIN`) and had no `payable`
 *      function anywhere, so listing in ETH was not a missing feature —
 *      it was impossible. Here the payment token lives **inside the
 *      signed order**, and the zero address means the chain's own
 *      currency. Listing in ETH collects ETH.
 *
 *      And it handled ERC-721 only, while the importer happily discovers
 *      ERC-1155. Both are supported here, with ERC-1155 orders fillable
 *      in parts.
 *
 * @dev HOW A SALE WORKS. The seller approves {CONDUIT} once for the
 *      collection and signs an {Order}. A buyer calls {fulfillOrder} with
 *      that order and signature, sending the chain's own currency along
 *      with the call or having approved the conduit for the ERC-20 named
 *      in the order. In that single transaction the price is split into
 *      the marketplace fee, any EIP-2981 creator royalty and the seller's
 *      proceeds, each pushed straight to its recipient, and the token
 *      moves straight from the seller to the buyer. Nothing settles into
 *      this contract's own balance except native currency in flight
 *      within the same call, which is fully paid out before it returns.
 *
 * @dev CANCELLING. Two routes, both on chain, both per seller.
 *      {cancelOrders} kills named orders. {incrementCounter} kills every
 *      order the caller has ever signed, in one transaction, by moving
 *      their counter forward — and it moves it forward by a *block-hash
 *      derived* amount rather than by one, copying Seaport, so that a
 *      malicious bulk payload cannot pre-sign orders that become valid at
 *      a predictable future counter value.
 *
 * @dev BULK SIGNING. N orders cost the seller ONE signature. The
 *      construction is Seaport's and is copied deliberately rather than
 *      invented: the signed type is `BulkOrder(Order[2][2]…[2] tree)`,
 *      and because EIP-712 hashes a fixed-size array as
 *      `keccak256(concat(encodeData(element)))`, nesting `[2]` to depth
 *      *h* IS an unsorted binary Merkle tree over plain
 *      `keccak256(left ‖ right)` — no sorting, no leaf prefix, no
 *      pre-hashing. The wallet still renders readable typed data, so this
 *      is not blind signing. The leaf is the byte-identical single-order
 *      hash, so bulk signing is purely additive and single-order
 *      verification is untouched. The proof rides inside the signature
 *      argument as `65-byte signature ‖ 3-byte index ‖ h × 32-byte
 *      sibling`, so {fulfillOrder}'s arguments never change.
 *      Reference: `seaport-core/src/lib/Verifiers.sol`,
 *      `docs/SeaportDocumentation.md`.
 *
 *      Trees are padded to a power of two with unfulfillable all-zero
 *      orders. They are NEVER built by duplicating a trailing odd node —
 *      that construction produces proofs which fail their own
 *      verification (see memory `trustless_data_t2_2026-07-26`), and the
 *      generator we ship (`Coin/scripts/lib/bulkOrderTree.ts`) pads.
 *
 * @dev AUCTIONS ARE NOT BUILT, BUT THE SIGNATURE SHAPE IS FINAL.
 *      Adding a field to {Order} later would change the EIP-712 type hash
 *      and silently invalidate every signature outstanding at that
 *      moment. So the fields auctions need are here from the first
 *      version: an order {kind}, and a price expressed over time as
 *      `startPrice` / `endPrice` / `startTime` / `endTime` rather than as
 *      a single number. A fixed-price sale simply sets start equal to
 *      end. A Dutch auction then needs no new field at all, and an
 *      English auction needs only somewhere to keep bids. Only
 *      {OrderKind.FixedPrice} is fillable today; the others revert.
 *
 * @dev NO TIPPING HOLE. Seaport lets a fulfiller append consideration
 *      items after the offerer signed, which is the root of its
 *      documented front-running risk. There is no consideration array
 *      here at all: the fee, the royalty and the seller's proceeds are
 *      each derived on chain from fields the seller signed, so there is
 *      nothing for a fulfiller to append to.
 *
 * @dev PIONEER PHASE. {admin} is the deployer EOA and stays that way.
 *      There is no delay anywhere in this contract — no propose-then-wait
 *      pattern, no timelock in any admin path. The admin handshake is
 *      two-step only so the role cannot be handed to an address unable to
 *      claim it; the successor may accept in the very next block. The
 *      role is a plain address, so the post-Pioneer handover to
 *      governance is one transfer on the day the founder authorises it.
 *
 * @dev Re-entrancy: `nonReentrant` on every state-mutating external, and
 *      order state is written before any external call. The ERC-1155 leg
 *      necessarily calls back into the buyer (`onERC1155Received` — the
 *      standard has no transfer without it) and the native-currency legs
 *      call out to the fee vault, the creator and the seller; the guard
 *      plus checks-effects-interactions covers all of them.
 */
contract NFTExchange is ReentrancyGuard, Pausable, ERC2771Context, EIP712 {
    // ─── Types ────────────────────────────────────────────────────────

    /**
     * @notice How an order's price is determined.
     * @dev Stored in {Order} as a `uint8` so the EIP-712 type string is
     *      stable regardless of how many kinds are added later.
     *      Only {FixedPrice} is fillable in this version.
     */
    enum OrderKind {
        /// @dev Price is constant. `startPrice` must equal `endPrice`.
        FixedPrice,
        /// @dev Reserved: price decays from `startPrice` to `endPrice`.
        DutchAuction,
        /// @dev Reserved: ascending bids, settled at the winning bid.
        EnglishAuction
    }

    /**
     * @notice Which token standard the offered item follows.
     * @dev Stored in {Order} as a `uint8`.
     */
    enum ItemType {
        /// @dev ERC-721. `amount` must be 1 and fills are all-or-nothing.
        ERC721,
        /// @dev ERC-1155. `amount` may exceed 1 and fills may be partial.
        ERC1155
    }

    /**
     * @notice What the seller signs. Everything that decides who gets paid
     *         what is in here, so nothing material can be substituted
     *         after signing.
     * @param kind              Member of {OrderKind}.
     * @param itemType          Member of {ItemType}.
     * @param offerer           Seller. Must own the item and have approved
     *                          {CONDUIT}. Signature must recover to this.
     * @param taker             Zero for an open listing anyone may buy;
     *                          otherwise the only address allowed to fill,
     *                          which is how a private sale is expressed.
     * @param nftContract       Collection holding the item.
     * @param tokenId           Item within `nftContract`.
     * @param amount            Units offered. Exactly 1 for ERC-721.
     * @param paymentToken      Currency the buyer pays in. **The zero
     *                          address means the chain's own currency** —
     *                          ETH on Ethereum, POL on Polygon, ETH on
     *                          Base, XOM on OmniCoin L1.
     * @param startPrice        Total price for all `amount` units at
     *                          `startTime`, in `paymentToken`'s smallest
     *                          units.
     * @param endPrice          Total price at `endTime`. Equal to
     *                          `startPrice` for a fixed-price sale.
     * @param startTime         Unix seconds before which the order cannot
     *                          be filled.
     * @param endTime           Unix seconds after which the order cannot
     *                          be filled. Inclusive.
     * @param counter           The seller's {counters} value at signing.
     *                          {incrementCounter} invalidates every order
     *                          carrying an older value.
     * @param salt              Free field making otherwise identical
     *                          orders distinguishable.
     * @param marketplaceFeeBps Fee in basis points the seller agreed to.
     *                          Asserted equal to {MARKETPLACE_FEE_BPS} on
     *                          fill, so a stale order fails loudly rather
     *                          than settling at the wrong fee.
     * @param maxRoyaltyBps     Most of the sale the seller is willing to
     *                          give the creator, in basis points. The
     *                          royalty is read from the collection at fill
     *                          time, and a collection's owner can change it
     *                          after the seller has signed — so without
     *                          this the seller is signing a price whose
     *                          split they do not control. Set it to 10,000
     *                          to accept whatever the collection says.
     * @param referrer          Who introduced this trade, or zero. Carried
     *                          for the referral share of the marketplace
     *                          fee. See the note on {ReferralRecorded}.
     * @param referrer2         Second-level referrer, or zero.
     */
    struct Order {
        uint8 kind;
        uint8 itemType;
        address offerer;
        address taker;
        address nftContract;
        uint256 tokenId;
        uint256 amount;
        address paymentToken;
        uint256 startPrice;
        uint256 endPrice;
        uint64 startTime;
        uint64 endTime;
        uint256 counter;
        uint256 salt;
        uint256 marketplaceFeeBps;
        uint256 maxRoyaltyBps;
        address referrer;
        address referrer2;
    }

    /**
     * @notice How much of an order is used up, and whether it was killed.
     * @dev One storage slot. `filled` counts units, so an ERC-1155 order
     *      can be bought in parts by different buyers.
     * @param cancelled True once the seller has cancelled the order.
     * @param filled    Units already sold. Never exceeds `Order.amount`.
     */
    struct OrderStatus {
        bool cancelled;
        uint248 filled;
    }

    // ─── Constants ────────────────────────────────────────────────────

    /// @notice Denominator for basis-point arithmetic.
    uint256 public constant BASIS_POINTS = 10_000;

    /// @notice Longest a signable order may still have to run at the
    ///         moment it is filled.
    /// @dev Six months, matching the longest listing the large venues
    ///      offer. It bounds how long a leaked signature stays dangerous;
    ///      a seller wanting longer re-signs.
    uint64 public constant MAX_ORDER_DURATION = 180 days;

    /// @notice Length of a plain ECDSA signature.
    uint256 public constant SIGNATURE_LENGTH = 65;

    /// @notice Bytes a bulk signature carries before the first proof
    ///         element: 65 signature bytes plus a 3-byte leaf index.
    uint256 private constant BULK_SIG_HEADER_LENGTH = 68;

    /// @notice Deepest bulk tree accepted, matching Seaport. Depth 24 is
    ///         16,777,216 orders under one signature.
    uint256 private constant MAX_BULK_HEIGHT = 24;

    /// @notice Canonical EIP-712 type string for {Order}.
    /// @dev Public so off-chain signers can read the authoritative string
    ///      off the chain instead of keeping their own copy in step by
    ///      hand — the exact drift that has bitten this codebase before.
    string public constant ORDER_TYPE_STRING = "Order(uint8 kind,uint8 itemType,address offerer,address taker,address nftContract,uint256 tokenId,uint256 amount,address paymentToken,uint256 startPrice,uint256 endPrice,uint64 startTime,uint64 endTime,uint256 counter,uint256 salt,uint256 marketplaceFeeBps,uint256 maxRoyaltyBps,address referrer,address referrer2)"; // solhint-disable-line max-line-length, gas-small-strings

    /// @notice EIP-712 type hash for {Order}.
    /// @dev Must stay byte-identical to {ORDER_TYPE_STRING}; the test
    ///      suite asserts `keccak256(ORDER_TYPE_STRING) == ORDER_TYPEHASH`
    ///      so the two can never drift apart unnoticed.
    bytes32 public constant ORDER_TYPEHASH = keccak256("Order(uint8 kind,uint8 itemType,address offerer,address taker,address nftContract,uint256 tokenId,uint256 amount,address paymentToken,uint256 startPrice,uint256 endPrice,uint64 startTime,uint64 endTime,uint256 counter,uint256 salt,uint256 marketplaceFeeBps,uint256 maxRoyaltyBps,address referrer,address referrer2)"); // solhint-disable-line max-line-length, gas-small-strings

    // ─── Immutables ───────────────────────────────────────────────────

    /// @notice Stable approval target every token movement goes through.
    /// @dev Sellers and ERC-20 buyers approve the conduit, not this
    ///      contract, so their approvals survive the next settlement
    ///      upgrade. See `OmniConduit.sol`.
    IOmniConduit public immutable CONDUIT;


    /// @notice Marketplace fee in basis points. 1% is 100.
    /// @dev Set once at construction with no setter, exactly as the
    ///      contract this replaces did. Every order restates the value it
    ///      was signed against and the fill asserts the two agree.
    uint256 public immutable MARKETPLACE_FEE_BPS;

    // ─── State ────────────────────────────────────────────────────────

    /// @notice Where the marketplace fee is sent.
    /// @dev Settable, and it has to be. The obvious choice on OmniCoin L1
    ///      is `UnifiedFeeVault`, and that contract has no `receive` and no
    ///      payable fallback — measured against the live deployment, a
    ///      plain value transfer to it reverts. Had this been `immutable`,
    ///      pointing it at a recipient that cannot take the chain's own
    ///      currency would have bricked every native sale with no remedy
    ///      but a redeploy. It is a plain deployer-direct setter with no
    ///      delay, which is what Pioneer Phase requires.
    address public feeVault;

    /// @notice Account allowed to pause, unpause and hand on the role.
    /// @dev The deployer EOA during Pioneer Phase.
    address public admin;

    /// @notice Account nominated as the next {admin}; zero when none.
    address public pendingAdmin;

    /// @notice Per-seller counter. Every order names the value current
    ///         when it was signed.
    mapping(address => uint256) public counters;

    /// @notice Per-seller, per-order fill and cancellation state.
    /// @dev Keyed by seller as well as order hash so {cancelOrders} can
    ///      take bare hashes and still be unable to touch anyone else's
    ///      orders.
    mapping(address => mapping(bytes32 => OrderStatus)) private _orderStatus;

    // ─── Events ───────────────────────────────────────────────────────

    /**
     * @notice Emitted once per successful fill.
     * @param orderHash    Struct hash of the filled order.
     * @param offerer      Seller.
     * @param buyer        Address that paid and received the item.
     * @param nftContract  Collection.
     * @param tokenId      Item sold.
     * @param fillAmount   Units transferred in this fill.
     * @param paymentToken Currency paid, zero for the chain's own.
     * @param totalPrice   Gross amount the buyer paid for this fill.
     */
    event OrderFulfilled(
        bytes32 indexed orderHash,
        address indexed offerer,
        address indexed buyer,
        address nftContract,
        uint256 tokenId,
        uint256 fillAmount,
        address paymentToken,
        uint256 totalPrice
    );

    /**
     * @notice Emitted when a seller kills one named order.
     * @param offerer   Seller who cancelled.
     * @param orderHash Order that can no longer be filled.
     */
    event OrderCancelled(address indexed offerer, bytes32 indexed orderHash);

    /**
     * @notice Emitted when a seller kills every order they have signed.
     * @param offerer    Seller whose counter moved.
     * @param newCounter Value orders must now carry to be fillable.
     * @custom:solhint `gas-indexed-events` is deliberately not applied.
     *                 Indexers filter these by seller; a value-typed topic
     *                 is not a useful key and costs gas to emit. Same
     *                 judgement the contract this replaces made.
     */
    event CounterIncremented(address indexed offerer, uint256 newCounter);

    /**
     * @notice Emitted when the marketplace fee is paid.
     * @dev Amount is not indexed: indexers filter by order and vault, and
     *      a value-typed topic would not be a useful key.
     * @param orderHash Order that produced the fee.
     * @param feeVault  Recipient.
     * @param feeAmount Amount paid.
     * @custom:solhint `gas-indexed-events` is deliberately not applied,
     *                 for the reason given on {CounterIncremented}.
     */
    event MarketplaceFeeCollected(
        bytes32 indexed orderHash,
        address indexed feeVault,
        uint256 feeAmount
    );

    /**
     * @notice Emitted when an EIP-2981 creator royalty is paid. Absent
     *         when the collection declares none.
     * @param orderHash        Order that produced the royalty.
     * @param nftContract      Collection whose `royaltyInfo` was honoured.
     * @param tokenId          Item sold.
     * @param royaltyRecipient Creator paid.
     * @param royaltyAmount    Amount paid, in the order's payment token.
     */
    event RoyaltyPaid(
        bytes32 indexed orderHash,
        address indexed nftContract,
        uint256 indexed tokenId,
        address royaltyRecipient,
        uint256 royaltyAmount
    );

    /**
     * @notice Emitted when a trade names a referrer.
     * @dev The marketplace fee is a single transfer to {feeVault}; how the
     *      vault then splits it is the vault's business. This event is how
     *      the referral share of that split is attributed, so a referrer
     *      recorded here can be paid without the exchange itself needing to
     *      know the fee schedule.
     * @param orderHash Order that named them.
     * @param referrer  Who introduced the trade.
     * @param referrer2 Second-level referrer, or zero.
     */
    event ReferralRecorded(
        bytes32 indexed orderHash,
        address indexed referrer,
        address indexed referrer2
    );

    /**
     * @notice Emitted when the marketplace-fee recipient changes.
     * @param previousVault Recipient before the change.
     * @param newVault      Recipient after the change.
     */
    event FeeVaultUpdated(
        address indexed previousVault,
        address indexed newVault
    );

    /**
     * @notice Emitted when the current admin nominates a successor.
     * @param currentAdmin  Admin at the time of the nomination.
     * @param proposedAdmin Address that may claim the role.
     */
    event AdminTransferProposed(
        address indexed currentAdmin,
        address indexed proposedAdmin
    );

    /**
     * @notice Emitted when the admin role actually moves.
     * @param oldAdmin Admin before the change.
     * @param newAdmin Admin after the change.
     */
    event AdminTransferred(
        address indexed oldAdmin,
        address indexed newAdmin
    );

    // ─── Errors ───────────────────────────────────────────────────────

    /// @notice Zero address supplied where a real address is required.
    error InvalidAddress();

    /// @notice Caller is not the recorded {admin}.
    error NotAdmin();

    /// @notice Caller of {acceptAdmin} is not the recorded {pendingAdmin}.
    error NotPendingAdmin();

    /// @notice Order's collection address is zero.
    error InvalidNftContract();

    /// @notice Order names a kind this version cannot settle. Auctions
    ///         are designed for but not built.
    error OrderKindNotSupported();

    /// @notice Order names a token standard that does not exist.
    error InvalidItemType();

    /// @notice A fixed-price order whose start and end prices differ.
    error PriceNotFixed();

    /// @notice Order offers zero units, an ERC-721 order offers other than
    ///         exactly one, or the offered amount is too large to record.
    error InvalidOrderAmount();

    /// @notice Order is priced in the very collection it is selling.
    error InvalidPaymentToken();

    /// @notice Buyer asked for zero units, more units than remain, or a
    ///         part of an ERC-721.
    error InvalidFillAmount();

    /// @notice Order's `endTime` is before its `startTime`.
    error InvalidOrderWindow();

    /// @notice The order's `startTime` has not arrived.
    error OrderNotStarted();

    /// @notice The order's `endTime` has passed.
    error OrderExpired();

    /// @notice Order would still be live more than {MAX_ORDER_DURATION}
    ///         from now.
    error OrderWindowTooLong();

    /// @notice Order's fee does not match {MARKETPLACE_FEE_BPS}.
    error FeeBpsMismatch();

    /// @notice Constructor was given a fee of 100% or more.
    error InvalidFeeBps();

    /// @notice Order carries a counter the seller has moved past — the
    ///         seller has cancelled everything they signed.
    error CounterOutOfDate();

    /// @notice Order was cancelled by name.
    error OrderIsCancelled();

    /// @notice Signature does not belong to the order's `offerer`.
    error InvalidSellerSignature();

    /// @notice Bulk signature names a leaf index the tree cannot hold.
    error BulkOrderIndexOutOfRange();

    /// @notice Bulk tree depth outside the range the contract can verify.
    error InvalidBulkOrderHeight();

    /// @notice The sale is too small for the marketplace fee to be
    ///         expressed in the payment token's smallest unit.
    error PriceTooSmall();

    /// @notice The collection now demands a larger creator royalty than
    ///         the seller agreed to when they signed.
    error RoyaltyExceedsCap();

    /// @notice Order names a specific buyer and the caller is not them.
    error FillerNotAuthorized();

    /// @notice Seller cannot buy their own order.
    error SelfFillForbidden();

    /// @notice Buyer sent less than the order's price.
    error InsufficientNativeValue();

    /// @notice Buyer sent the chain's own currency for an order priced in
    ///         an ERC-20.
    error UnexpectedNativeValue();

    /// @notice A native-currency payout was rejected by its recipient.
    error NativeTransferFailed();

    /// @notice An order priced in the chain's own currency was submitted
    ///         through the gasless relay, where the currency would come
    ///         from the relayer rather than the buyer.
    error NativeFillViaForwarder();

    // ─── Constructor ──────────────────────────────────────────────────

    /**
     * @notice Wire the immutables and take the admin role.
     * @dev The deploying account becomes {admin}, per the Pioneer-Phase
     *      rule that the deployer EOA is the sole controller.
     * @param conduit_           Stable approval target. See `OmniConduit`.
     * @param feeVault_          Marketplace-fee recipient.
     * @param marketplaceFeeBps_ Fee in basis points; 100 is the 1% the
     *                           marketplace charges today.
     * @param trustedForwarder_  OmniForwarder, for gasless fills of orders
     *                           priced in an ERC-20.
     */
    constructor(
        address conduit_,
        address feeVault_,
        uint256 marketplaceFeeBps_,
        address trustedForwarder_
    )
        ERC2771Context(trustedForwarder_)
        EIP712("OmniBazaar NFTExchange", "1")
    {
        if (conduit_ == address(0)) revert InvalidAddress();
        if (feeVault_ == address(0)) revert InvalidAddress();
        // A fee of a full 100% or more would leave the seller nothing.
        // solhint-disable-next-line gas-strict-inequalities
        if (marketplaceFeeBps_ >= BASIS_POINTS) revert InvalidFeeBps();
        CONDUIT = IOmniConduit(conduit_);
        feeVault = feeVault_;
        MARKETPLACE_FEE_BPS = marketplaceFeeBps_;
        admin = msg.sender;
    }

    // ─── Admin ────────────────────────────────────────────────────────

    /**
     * @notice Stop new fills.
     * @dev Admin-only, and deliberately on raw `msg.sender` rather than
     *      `_msgSender()`: a compromised forwarder is one of the reasons
     *      to pause, so the switch must not depend on the forwarder being
     *      healthy. Cancelling is never paused — a seller whose signature
     *      has leaked must always be able to kill it.
     */
    function pause() external {
        if (msg.sender != admin) revert NotAdmin();
        _pause();
    }

    /// @notice Resume fills. Admin-only, raw `msg.sender` as with {pause}.
    function unpause() external {
        if (msg.sender != admin) revert NotAdmin();
        _unpause();
    }

    /**
     * @notice Point the marketplace fee at a different recipient.
     * @dev Admin-only, immediate, no waiting period — the Pioneer-Phase
     *      pattern. It exists because a fee recipient that cannot accept
     *      the chain's own currency would otherwise brick every native sale
     *      permanently; see the note on {feeVault}.
     * @param newVault New fee recipient.
     */
    function setFeeVault(address newVault) external {
        if (msg.sender != admin) revert NotAdmin();
        if (newVault == address(0)) revert InvalidAddress();
        // M-01: Probe the new vault with a 0-value call to verify it can
        // receive the chain's own currency. Without this check, setting a
        // feeVault that lacks a payable receive/fallback would brick every
        // native-currency sale — the _sendNative call in _payOut would
        // always revert and no native-priced order could ever be filled.
        // solhint-disable-next-line avoid-low-level-calls
        (bool ok,) = payable(newVault).call{value: 0}("");
        if (!ok) revert InvalidAddress();
        emit FeeVaultUpdated(feeVault, newVault);
        feeVault = newVault;
    }

    /**
     * @notice Nominate the next admin, or pass the zero address to cancel
     *         a pending nomination.
     * @dev Admin-only. The nominee must call {acceptAdmin}; there is no
     *      waiting period, only the handshake, so the role cannot land on
     *      an address unable to claim it.
     * @param newAdmin Address that may claim the role, or zero to cancel.
     */
    function proposeAdmin(address newAdmin) external {
        if (msg.sender != admin) revert NotAdmin();
        pendingAdmin = newAdmin;
        emit AdminTransferProposed(admin, newAdmin);
    }

    /**
     * @notice Claim the admin role previously nominated via
     *         {proposeAdmin}.
     * @dev Callable only by {pendingAdmin}. Rotates the role and clears
     *      the nomination in the same call.
     */
    function acceptAdmin() external {
        if (msg.sender != pendingAdmin) revert NotPendingAdmin();
        address previous = admin;
        admin = msg.sender;
        pendingAdmin = address(0);
        emit AdminTransferred(previous, msg.sender);
    }

    // ─── Seller: cancelling ───────────────────────────────────────────

    /**
     * @notice Kill named orders so they can never be filled.
     * @dev Only ever touches the caller's own orders, because the record
     *      is kept under the caller's address. Cancelling an order that
     *      is already cancelled, already filled or was never signed is
     *      harmless and still emits, which keeps the client simple.
     *
     *      Not pausable: a seller whose signature has leaked during an
     *      emergency must still be able to kill it.
     * @param orderHashes Struct hashes of the orders to kill, as returned
     *                    by {hashOrder}.
     */
    function cancelOrders(bytes32[] calldata orderHashes) external {
        address offerer = _msgSender();
        uint256 length = orderHashes.length;
        for (uint256 i = 0; i < length; ) {
            _orderStatus[offerer][orderHashes[i]].cancelled = true;
            emit OrderCancelled(offerer, orderHashes[i]);
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Kill every order the caller has ever signed, in one
     *         transaction.
     * @dev The counter jumps forward by a block-hash-derived amount
     *      rather than by one. Seaport does this so that a seller tricked
     *      into signing a bulk payload cannot have had orders pre-signed
     *      against predictable future counter values waiting to become
     *      valid the moment they cancel everything. The jump is forced to
     *      be at least one, so the call always actually cancels —
     *      Seaport's own version can no-op if the block hash happens to
     *      have a zero high byte.
     *
     *      Not pausable, for the same reason as {cancelOrders}.
     * @return newCounter The value orders must now carry to be fillable.
     */
    function incrementCounter() external returns (uint256 newCounter) {
        address offerer = _msgSender();
        uint256 jump;
        unchecked {
            // Top 128 bits of the previous block hash, plus one so the
            // jump is never zero.
            //
            // The width matters and 128 is not arbitrary. A bulk tree may
            // hold up to `2 ** MAX_BULK_HEIGHT` orders, so if the jump had
            // fewer than that many possible values, one bulk signature
            // could carry a pre-signed order for EVERY counter this call
            // can reach — and cancelling everything would hand the attacker
            // a live order in the same transaction, which is the exact
            // thing this mechanism exists to prevent. 2**128 possibilities
            // against 2**24 leaves leaves no such coverage. Seaport shifts
            // by the same 128.
            //
            // Not a source of randomness anyone relies on for value — it
            // only has to be unpredictable when an attacker prepares a
            // payload.
            jump = (uint256(blockhash(block.number - 1)) >> 128) + 1;
            newCounter = counters[offerer] + jump;
        }
        counters[offerer] = newCounter;
        emit CounterIncremented(offerer, newCounter);
    }

    // ─── Buyer: the whole of buying ───────────────────────────────────

    /**
     * @notice Buy from a signed order. One transaction, nothing held.
     *
     * @dev Order of operations is checks, then the single state write,
     *      then every external call:
     *
     *      1. Reject a native-currency fill arriving through the relay,
     *         where the currency would be the relayer's.
     *      2. Validate the order's own fields, its time window, its fee
     *         and its counter.
     *      3. Verify the seller's signature — plain, or bulk with the
     *         proof carried inside the signature argument.
     *      4. Check the order is neither cancelled nor already used up,
     *         and reserve `fillAmount` units by writing `filled`.
     *      5. Split the price into fee, royalty and seller proceeds.
     *      6. Pay all three, then move the item, then refund any
     *         native-currency overpayment.
     *
     *      Step 4 completes before step 6 begins, so a recipient that
     *      calls back in finds the units already spoken for; the
     *      re-entrancy guard stops it re-entering at all.
     *
     * @param order      The seller's signed order.
     * @param signature  Seller's signature. 65 bytes for one order, or
     *                   `65 ‖ 3-byte index ‖ h × 32-byte sibling` for one
     *                   order out of a bulk-signed tree of depth `h`.
     *                   A smart-contract wallet's EIP-1271 signature of
     *                   any other length is accepted on the single-order
     *                   path.
     * @param fillAmount Units to buy. Must be 1 for ERC-721; may be any
     *                   part of what remains for ERC-1155.
     */
    function fulfillOrder(
        Order calldata order,
        bytes calldata signature,
        uint256 fillAmount
    ) external payable nonReentrant whenNotPaused {
        address buyer = _msgSender();
        bool payingNative = order.paymentToken == address(0);

        // A gasless fill would spend the relayer's own currency, not the
        // buyer's, and hand the item to the buyer. Refuse rather than
        // rely on the forwarder to get value accounting right.
        if (payingNative && msg.sender != buyer) {
            revert NativeFillViaForwarder();
        }
        if (!payingNative && msg.value != 0) revert UnexpectedNativeValue();

        _validateOrderParties(order, buyer);
        _validateOrderItem(order, fillAmount);
        _validateOrderTerms(order);

        bytes32 orderHash = _hashOrder(order);
        _verifySignature(order.offerer, orderHash, signature);

        uint256 totalPrice = _reserveAndPrice(order, orderHash, fillAmount);
        if (payingNative && msg.value < totalPrice) {
            revert InsufficientNativeValue();
        }

        _payOut(order, orderHash, buyer, totalPrice);
        _deliver(order, buyer, fillAmount);

        emit OrderFulfilled(
            orderHash,
            order.offerer,
            buyer,
            order.nftContract,
            order.tokenId,
            fillAmount,
            order.paymentToken,
            totalPrice
        );

        // Last, so an overpaying buyer cannot use the refund as a
        // re-entrancy foothold into anything that still matters.
        if (payingNative && msg.value > totalPrice) {
            unchecked {
                _sendNative(buyer, msg.value - totalPrice);
            }
        }
    }

    // ─── Views ────────────────────────────────────────────────────────

    /**
     * @notice Read how much of an order is used up and whether it was
     *         cancelled.
     * @param offerer   Seller who signed the order.
     * @param orderHash Struct hash from {hashOrder}.
     * @return cancelled True if the seller killed this order by name.
     * @return filled    Units already sold.
     */
    function getOrderStatus(address offerer, bytes32 orderHash)
        external
        view
        returns (bool cancelled, uint256 filled)
    {
        OrderStatus memory status = _orderStatus[offerer][orderHash];
        return (status.cancelled, uint256(status.filled));
    }

    /**
     * @notice The full typed-data digest a wallet signs for one order.
     * @dev Clients should compare their own computation against this
     *      before prompting a user, rather than trusting that their copy
     *      of the type string is still in step with ours.
     * @param order The order.
     * @return digest The digest to sign.
     */
    function orderDigest(Order calldata order)
        external
        view
        returns (bytes32 digest)
    {
        return _hashTypedDataV4(_hashOrder(order));
    }

    /**
     * @notice The EIP-712 domain separator, for signers that do not
     *         compute it themselves.
     * @return separator The domain separator.
     */
    function domainSeparator() external view returns (bytes32 separator) {
        return _domainSeparatorV4();
    }

    /**
     * @notice Price of a whole order right now, in its payment token.
     * @dev A user interface should quote from this rather than from the
     *      order's raw fields, so that when auctions arrive the quote
     *      follows the price without the interface changing.
     * @param order The order.
     * @return price Total for all `amount` units.
     */
    function currentPrice(Order calldata order)
        external
        pure
        returns (uint256 price)
    {
        return _currentPrice(order);
    }

    /**
     * @notice Struct hash of an order — its identity for cancelling and
     *         for indexing, and the leaf of a bulk-signing tree.
     * @param order The order.
     * @return structHash The order hash.
     */
    function hashOrder(Order calldata order)
        external
        pure
        returns (bytes32 structHash)
    {
        return _hashOrder(order);
    }

    /**
     * @notice EIP-712 type hash of the bulk-order wrapper for a tree of a
     *         given depth.
     * @dev Exposed so the signing client can prove its nested type string
     *      matches ours before asking a user to sign it.
     * @param height Tree depth, 1 to {MAX_BULK_HEIGHT}. A tree of depth
     *               `h` carries `2 ** h` orders.
     * @return typeHash The type hash for that depth.
     */
    function bulkOrderTypehash(uint256 height)
        external
        pure
        returns (bytes32 typeHash)
    {
        if (height == 0 || height > MAX_BULK_HEIGHT) {
            revert InvalidBulkOrderHeight();
        }
        return _bulkOrderTypehash(height);
    }


    // ─── ERC-2771 overrides ───────────────────────────────────────────

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
     * @return data Calldata with any forwarder suffix stripped.
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
     * @notice Length of the forwarder's appended-address suffix.
     * @return length The fixed 20-byte suffix length.
     */
    function _contextSuffixLength()
        internal
        view
        override(Context, ERC2771Context)
        returns (uint256 length)
    {
        return ERC2771Context._contextSuffixLength();
    }

    // ─── Private: money and delivery ──────────────────────────────────

    /**
     * @notice Reserve the requested units against the order's remaining
     *         supply and work out what they cost.
     * @dev This is the only state write a fill makes, and it happens
     *      before any external call.
     * @param order      The order.
     * @param orderHash  Its struct hash.
     * @param fillAmount Units requested.
     * @return totalPrice What the buyer owes for those units.
     */
    function _reserveAndPrice(
        Order calldata order,
        bytes32 orderHash,
        uint256 fillAmount
    ) private returns (uint256 totalPrice) {
        OrderStatus storage status = _orderStatus[order.offerer][orderHash];
        if (status.cancelled) revert OrderIsCancelled();

        // `filled` is a `uint248` and a Solidity cast to a narrower type
        // truncates in silence, so an order offering more units than that
        // field can hold would wrap its own fill count back to zero and
        // become refillable without limit. No real collection is anywhere
        // near this supply; the bound just makes the cast provably safe.
        if (order.amount > type(uint248).max) revert InvalidOrderAmount();

        uint256 newFilled = uint256(status.filled) + fillAmount;
        if (newFilled > order.amount) revert InvalidFillAmount();
        status.filled = uint248(newFilled);

        // Rounded up, so buying part of an ERC-1155 order can never come
        // out cheaper per unit than buying all of it.
        totalPrice = Math.mulDiv(
            _currentPrice(order),
            fillAmount,
            order.amount,
            Math.Rounding.Ceil
        );
    }

    /**
     * @notice Split the price and pay all three recipients.
     * @dev Both currencies take the same shape: fee, then royalty, then
     *      the seller. For an ERC-20 the money never touches this
     *      contract at all — each leg is a separate transfer straight
     *      from the buyer through the conduit. For the chain's own
     *      currency it arrives with the call and is fully paid out before
     *      the call returns.
     *
     *      The EIP-2981 lookup is `RoyaltyResolver`'s, unchanged: bounded
     *      to 50,000 gas so a seller-chosen collection cannot burn a
     *      relayer's gas, tolerant of collections that do not implement
     *      the standard, and clamped to the seller's post-fee proceeds so
     *      a misbehaving collection can never make the payout underflow.
     * @param order      The order.
     * @param orderHash  Its struct hash.
     * @param buyer      Payer.
     * @param totalPrice Gross amount for this fill.
     */
    function _payOut(
        Order calldata order,
        bytes32 orderHash,
        address buyer,
        uint256 totalPrice
    ) private {
        // `Math.mulDiv` rather than `a * b / c`: a seller-chosen price
        // close to the top of the range would otherwise overflow the
        // intermediate product and revert for no reason.
        uint256 feeAmount = Math.mulDiv(
            totalPrice,
            MARKETPLACE_FEE_BPS,
            BASIS_POINTS
        );
        // A sale priced so low that 1% of it rounds away to nothing pays no
        // fee at all — and, worse, collapses the payment to a single
        // transfer, which is the shape a payment-token confusion attack
        // needs. Refuse to settle a sale the fee cannot be expressed on.
        if (totalPrice > 0 && feeAmount == 0) revert PriceTooSmall();
        uint256 afterFee = totalPrice - feeAmount;

        (address royaltyRecipient, uint256 royaltyAmount) = RoyaltyResolver
            .resolve(
                order.nftContract,
                order.tokenId,
                totalPrice,
                afterFee
            );

        // The royalty is read from the collection NOW, and a collection's
        // owner can raise it after the seller signed — every OpenZeppelin
        // ERC-2981 collection ships an owner-settable royalty. Without this
        // check a collection owner could set the royalty to 99%, buy every
        // outstanding listing themselves, take the money straight back as
        // "royalty", and leave the seller nothing. The seller signed a cap;
        // honour it.
        if (
            royaltyAmount >
            Math.mulDiv(
                totalPrice,
                order.maxRoyaltyBps,
                BASIS_POINTS,
                Math.Rounding.Floor
            )
        ) {
            revert RoyaltyExceedsCap();
        }

        uint256 sellerAmount = afterFee - royaltyAmount;

        address vault = feeVault;
        if (feeAmount > 0) {
            _pay(order.paymentToken, buyer, vault, feeAmount);
            emit MarketplaceFeeCollected(orderHash, vault, feeAmount);
            if (order.referrer != address(0)) {
                emit ReferralRecorded(
                    orderHash,
                    order.referrer,
                    order.referrer2
                );
            }
        }
        if (royaltyAmount > 0) {
            _pay(order.paymentToken, buyer, royaltyRecipient, royaltyAmount);
            emit RoyaltyPaid(
                orderHash,
                order.nftContract,
                order.tokenId,
                royaltyRecipient,
                royaltyAmount
            );
        }
        if (sellerAmount > 0) {
            _pay(order.paymentToken, buyer, order.offerer, sellerAmount);
        }
    }

    /**
     * @notice Move the item from the seller to the buyer.
     * @dev Through the conduit, against the approval the seller granted
     *      it, so nothing is ever held here. ERC-721 uses the plain
     *      transfer, which has no receiver callback; ERC-1155 has no such
     *      variant, so that leg does call into the buyer and runs inside
     *      the re-entrancy guard with all state already written.
     * @param order      The order.
     * @param buyer      Recipient.
     * @param fillAmount Units to move.
     */
    function _deliver(
        Order calldata order,
        address buyer,
        uint256 fillAmount
    ) private {
        if (order.itemType == uint8(ItemType.ERC721)) {
            CONDUIT.transferERC721(
                order.nftContract,
                order.offerer,
                buyer,
                order.tokenId
            );
        } else {
            CONDUIT.transferERC1155(
                order.nftContract,
                order.offerer,
                buyer,
                order.tokenId,
                fillAmount
            );
        }
    }

    /**
     * @notice Pay one recipient in whichever currency the order names.
     * @param paymentToken ERC-20 to pay in, or zero for the chain's own
     *                     currency.
     * @param payer        Buyer, for the ERC-20 path.
     * @param to           Recipient.
     * @param amount       Amount to pay.
     */
    function _pay(
        address paymentToken,
        address payer,
        address to,
        uint256 amount
    ) private {
        if (paymentToken == address(0)) {
            _sendNative(to, amount);
        } else {
            CONDUIT.transferERC20(paymentToken, payer, to, amount);
        }
    }

    /**
     * @notice Send the chain's own currency, reverting if it is refused.
     * @dev All gas is forwarded, because a recipient may legitimately be
     *      a contract wallet that needs more than a stipend. A recipient
     *      that refuses payment makes the whole sale fail, which is the
     *      right outcome: the alternative is quietly keeping money that
     *      is not ours, and for the creator royalty it would be quietly
     *      not paying a royalty at all.
     * @param to     Recipient.
     * @param amount Amount to send.
     */
    function _sendNative(address to, uint256 amount) private {
        // solhint-disable-next-line avoid-low-level-calls
        (bool ok, ) = payable(to).call{value: amount}("");
        if (!ok) revert NativeTransferFailed();
    }

    // ─── Private: validation ──────────────────────────────────────────

    /**
     * @notice Check the order's time window, its fee and its counter.
     * @dev The counter check is what makes {incrementCounter} a real
     *      cancel-everything: an order signed against an older counter
     *      value can never be filled again.
     * @param order The order.
     */
    function _validateOrderTerms(Order calldata order) private view {
        if (order.endTime < order.startTime) revert InvalidOrderWindow();
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp < order.startTime) revert OrderNotStarted();
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp > order.endTime) revert OrderExpired();
        // Bound the window the seller actually signed, not what is left of
        // it. Checking the remainder would let an order signed to run for
        // ten years sit unfillable for nine and a half — the seller's
        // listing silently refusing every buyer — and then come alive for a
        // full six months at a price fixed a decade earlier. `endTime` is
        // already known to be at or after `startTime`.
        if (order.endTime - order.startTime > MAX_ORDER_DURATION) {
            revert OrderWindowTooLong();
        }

        if (order.marketplaceFeeBps != MARKETPLACE_FEE_BPS) {
            revert FeeBpsMismatch();
        }
        if (order.counter != counters[order.offerer]) {
            revert CounterOutOfDate();
        }
    }

    /**
     * @notice Verify that `offerer` signed this order, plainly or as one
     *         leaf of a bulk-signed tree.
     * @dev Which it is, is decided purely by the signature's length, the
     *      way Seaport decides it: exactly {SIGNATURE_LENGTH} is a plain
     *      signature; `68 + 32h` for `1 <= h <= 24` is a bulk one. Any
     *      other length is handed to the single-order path, where a
     *      smart-contract wallet's EIP-1271 signature of arbitrary length
     *      still works. A contract wallet whose signature happened to be
     *      exactly `68 + 32h` bytes long would be read as bulk; that is
     *      Seaport's behaviour too, and it is why the client offers
     *      contract wallets per-item signing rather than bulk.
     * @param offerer   Address the signature must belong to.
     * @param orderHash Struct hash of the order being filled.
     * @param signature Signature, with any bulk proof appended.
     */
    function _verifySignature(
        address offerer,
        bytes32 orderHash,
        bytes calldata signature
    ) private view {
        uint256 length = signature.length;
        bytes32 digest;
        bytes calldata ecdsaSignature = signature;

        // Only a plain key can have produced a bulk signature, so only an
        // offerer with no code is routed by length. This is what stops a
        // contract wallet's signature being mistaken for a bulk one: four
        // 65-byte owner signatures concatenated is 260 bytes, which is
        // exactly `68 + 32 * 6` — so without this, every 4-of-N Safe would
        // be handed a depth-6 Merkle digest it never approved and would be
        // unable to sell anything, silently, with a misleading error. It
        // also matches how OpenZeppelin's own `SignatureChecker` dispatches.
        if (offerer.code.length == 0 && _isBulkSignatureLength(length)) {
            uint256 height;
            unchecked {
                height = (length - BULK_SIG_HEADER_LENGTH) / 32;
            }
            digest = _bulkOrderDigest(orderHash, signature, height);
            ecdsaSignature = signature[:SIGNATURE_LENGTH];
        } else {
            digest = _hashTypedDataV4(orderHash);
        }

        if (
            !SignatureChecker.isValidSignatureNow(
                offerer,
                digest,
                ecdsaSignature
            )
        ) {
            revert InvalidSellerSignature();
        }
    }

    /**
     * @notice Rebuild the bulk-order digest from a leaf and the proof
     *         carried in the signature.
     * @dev Plain `keccak256(left ‖ right)` with no sorting and no leaf
     *      prefix, walking the leaf index from its lowest bit up — this
     *      is not a convention we chose, it is what EIP-712's own
     *      encoding of `Order[2][2]…[2]` computes, which is the whole
     *      reason the wallet can still render the data it is signing.
     * @param leaf      Struct hash of the order being filled.
     * @param signature Full signature argument, proof included.
     * @param height    Tree depth implied by the signature's length.
     * @return digest The typed-data digest the seller actually signed.
     */
    function _bulkOrderDigest(
        bytes32 leaf,
        bytes calldata signature,
        uint256 height
    ) private view returns (bytes32 digest) {
        uint256 key = uint256(
            uint24(bytes3(signature[SIGNATURE_LENGTH:BULK_SIG_HEADER_LENGTH]))
        );
        // A leaf index the tree cannot hold would otherwise silently walk
        // the proof with meaningless direction bits.
        // solhint-disable-next-line gas-strict-inequalities
        if (key >= (uint256(1) << height)) {
            revert BulkOrderIndexOutOfRange();
        }

        bytes32 node = leaf;
        for (uint256 i = 0; i < height; ) {
            uint256 offset;
            unchecked {
                offset = BULK_SIG_HEADER_LENGTH + (i * 32);
            }
            bytes32 sibling = bytes32(signature[offset:offset + 32]);
            node = (key & 1) == 0
                ? keccak256(abi.encodePacked(node, sibling))
                : keccak256(abi.encodePacked(sibling, node));
            key >>= 1;
            unchecked {
                ++i;
            }
        }

        return _hashTypedDataV4(
            keccak256(abi.encode(_bulkOrderTypehash(height), node))
        );
    }

    // ─── Private: pricing and hashing ─────────────────────────────────

    /**
     * @notice Check who the order is between.
     * @dev One of three validators — parties, item, terms — split only so
     *      that each stays within the project's cyclomatic-complexity
     *      limit. Together they are every check a fill makes that does not
     *      depend on the signature or on how much of the order is left.
     * @param order The order.
     * @param buyer Address that will pay and receive.
     */
    function _validateOrderParties(Order calldata order, address buyer)
        private
        pure
    {
        if (order.nftContract == address(0)) revert InvalidNftContract();
        if (order.offerer == address(0)) revert InvalidAddress();
        if (order.offerer == buyer) revert SelfFillForbidden();
        if (order.taker != address(0) && order.taker != buyer) {
            revert FillerNotAuthorized();
        }
        // An NFT collection is not money. `OmniConduit.transferERC20`
        // catches the general case — ERC-20 and ERC-721 share the
        // `transferFrom` selector, so a collection named as an order's
        // payment token turns a payment leg into a token transfer with the
        // price read as a token id. This is the one instance the conduit
        // could not catch on its own, and it costs nothing to refuse here.
        if (order.paymentToken == order.nftContract) {
            revert InvalidPaymentToken();
        }
    }

    /**
     * @notice Check what the order offers and how much of it is wanted.
     * @dev An ERC-721 order is one indivisible item, so both the offered
     *      amount and the requested amount must be exactly one. An
     *      ERC-1155 order may offer many units and may be bought in parts.
     * @param order      The order.
     * @param fillAmount Units requested.
     */
    function _validateOrderItem(Order calldata order, uint256 fillAmount)
        private
        pure
    {
        if (order.itemType > uint8(ItemType.ERC1155)) {
            revert InvalidItemType();
        }
        if (order.amount == 0) revert InvalidOrderAmount();
        if (fillAmount == 0) revert InvalidFillAmount();
        if (order.itemType == uint8(ItemType.ERC721)) {
            if (order.amount != 1) revert InvalidOrderAmount();
            if (fillAmount != 1) revert InvalidFillAmount();
        }
    }

    /**
     * @notice Price of a whole order right now.
     * @dev Only fixed-price orders settle in this version. The order
     *      already carries `startPrice` / `endPrice` / `startTime` /
     *      `endTime`, so when auctions arrive this function grows a
     *      branch and no outstanding signature is disturbed — which is
     *      the entire reason those fields are here today.
     * @param order The order.
     * @return price Total for all `amount` units.
     */
    function _currentPrice(Order calldata order)
        private
        pure
        returns (uint256 price)
    {
        if (order.kind != uint8(OrderKind.FixedPrice)) {
            revert OrderKindNotSupported();
        }
        if (order.startPrice != order.endPrice) revert PriceNotFixed();
        return order.startPrice;
    }

    /**
     * @notice Whether a signature length is a well-formed bulk signature.
     * @dev `65 signature + 3 index + 32h proof` for `1 <= h <= 24`.
     * @param length Signature length in bytes.
     * @return isBulk True if the length can only be a bulk signature.
     */
    function _isBulkSignatureLength(uint256 length)
        private
        pure
        returns (bool isBulk)
    {
        unchecked {
            if (length < BULK_SIG_HEADER_LENGTH + 32) return false;
            if (length > BULK_SIG_HEADER_LENGTH + (MAX_BULK_HEIGHT * 32)) {
                return false;
            }
            return (length - BULK_SIG_HEADER_LENGTH) % 32 == 0;
        }
    }

    /**
     * @notice EIP-712 type hash of `BulkOrder(Order[2]…[2] tree)` for a
     *         tree of the given depth.
     * @dev Built from {ORDER_TYPE_STRING} at call time rather than kept
     *      as twenty-four hard-coded constants the way Seaport does.
     *      Twenty-four constants would silently fall out of step with the
     *      order type the day a field is added — and a field will be
     *      added, when auctions arrive. Deriving it costs a few thousand
     *      gas on a bulk fill and cannot drift.
     * @param height Tree depth.
     * @return typeHash The type hash.
     */
    function _bulkOrderTypehash(uint256 height)
        private
        pure
        returns (bytes32 typeHash)
    {
        bytes memory brackets = new bytes(height * 3);
        for (uint256 i = 0; i < height; ) {
            uint256 at;
            unchecked {
                at = i * 3;
            }
            brackets[at] = "[";
            brackets[at + 1] = "2";
            brackets[at + 2] = "]";
            unchecked {
                ++i;
            }
        }
        return keccak256(
            abi.encodePacked(
                "BulkOrder(Order",
                brackets,
                " tree)",
                ORDER_TYPE_STRING
            )
        );
    }

    /**
     * @notice Struct hash of an order.
     * @param order The order.
     * @return structHash `keccak256(abi.encode(ORDER_TYPEHASH, …))`.
     */
    function _hashOrder(Order calldata order)
        private
        pure
        returns (bytes32 structHash)
    {
        return keccak256(
            abi.encode(
                ORDER_TYPEHASH,
                order.kind,
                order.itemType,
                order.offerer,
                order.taker,
                order.nftContract,
                order.tokenId,
                order.amount,
                order.paymentToken,
                order.startPrice,
                order.endPrice,
                order.startTime,
                order.endTime,
                order.counter,
                order.salt,
                order.marketplaceFeeBps,
                order.maxRoyaltyBps,
                order.referrer,
                order.referrer2
            )
        );
    }
}
