// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {
    AccessControlUpgradeable
} from
    "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {
    PausableUpgradeable
} from
    "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {
    ReentrancyGuardUpgradeable
} from
    "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {
    Initializable
} from
    "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    UUPSUpgradeable
} from
    "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {
    MpcCore,
    gtUint64,
    ctUint64,
    gtBool
} from "../coti-contracts/contracts/utils/mpc/MpcCore.sol";

/**
 * @title PrivateDEX
 * @author OmniCoin Development Team
 * @notice Privacy-preserving DEX order matching using COTI V2 MPC
 *         garbled circuits
 * @dev Handles encrypted order matching where amounts and prices
 *      remain hidden throughout the order lifecycle.
 *
 * Architecture:
 * - Orders submitted with encrypted amounts/prices (ctUint64)
 * - Matching uses MPC operations (ge, min, checkedAdd, checkedSub)
 * - Amounts and prices are never revealed on-chain
 * - Settlement occurs on Avalanche via OmniCore/PrivateDEXSettlement
 *
 * Precision:
 * - All amounts MUST be pre-scaled by 1e12 (18-decimal wei to
 *   6-decimal micro-XOM) before encryption, due to COTI MPC uint64
 *   limitation.
 * - Max order size: type(uint64).max in 6-decimal units =
 *   ~18,446,744 XOM per order.
 * - Larger orders must use the non-private DEX.
 *
 * Order Lifecycle:
 * 1. OPEN: Order submitted via submitPrivateOrder(). Active, can
 *    be matched or cancelled.
 * 2. PARTIALLY_FILLED: Some quantity has been matched via
 *    executePrivateTrade(). Still active for further matching.
 * 3. FILLED: Full quantity matched. Terminal state.
 * 4. CANCELLED: User cancelled via cancelPrivateOrder(). Terminal.
 *
 * Security Features:
 * - Reentrancy protection on all state-changing functions
 * - Role-based access control (MATCHER_ROLE for trade execution)
 * - Pausable for emergencies
 * - Upgradeable via UUPS with two-step ossification (7-day delay)
 * - Checked MPC arithmetic (checkedAdd/checkedSub/checkedMul)
 *   reverts on overflow instead of silently wrapping
 * - Match amounts computed internally (not externally supplied)
 *   to prevent matcher fabrication
 * - Price re-validation inside executePrivateTrade() prevents
 *   stale or incompatible matches
 *
 * Privacy Guarantees:
 * - Order amounts encrypted (ctUint64)
 * - Order prices encrypted (ctUint64)
 * - Filled amounts encrypted
 * - Only trader can decrypt their own data
 */
contract PrivateDEX is
    Initializable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    using MpcCore for gtUint64;
    using MpcCore for ctUint64;
    using MpcCore for gtBool;

    // ====================================================================
    // TYPE DECLARATIONS (enums + structs before constants per solhint)
    // ====================================================================

    /// @notice Order status enumeration
    enum OrderStatus {
        OPEN,              // Order is active and can be matched
        PARTIALLY_FILLED,  // Order is partially executed
        FILLED,            // Order is completely filled
        CANCELLED          // Order was cancelled by user
    }

    /**
     * @notice Private order structure with encrypted fields
     * @dev Amount and price are encrypted using COTI V2 MPC.
     *      All encrypted amounts must be pre-scaled to 6-decimal
     *      (micro-XOM) before encryption due to COTI MPC uint64
     *      limitation.
     */
    struct PrivateOrder {
        bytes32 orderId;         // Unique order identifier
        address trader;          // Trader address (public)
        bool isBuy;              // Buy or sell order (public)
        string pair;             // Trading pair (public)
        ctUint64 encAmount;      // Encrypted order size
        ctUint64 encPrice;       // Encrypted limit price
        uint256 timestamp;       // Order creation time (public)
        OrderStatus status;      // Order status (public)
        ctUint64 encFilled;      // Encrypted filled amount
        uint256 expiry;          // Order expiration timestamp
        ctUint64 encMinFill;     // Encrypted minimum fill amount
    }

    // ====================================================================
    // CONSTANTS
    // ====================================================================

    /// @notice Role identifier for order matchers
    bytes32 public constant MATCHER_ROLE =
        keccak256("MATCHER_ROLE");

    /// @notice Role identifier for admin operations
    bytes32 public constant ADMIN_ROLE =
        keccak256("ADMIN_ROLE");

    /// @notice Maximum orders per user to prevent spam
    uint256 public constant MAX_ORDERS_PER_USER = 100;

    /// @notice Delay required between ossification request and
    ///         confirmation (7 days)
    uint256 public constant OSSIFICATION_DELAY = 7 days;

    /// @notice Maximum fee in basis points (100% = 10000)
    uint64 public constant MAX_FEE_BPS = 10000;

    // ====================================================================
    // STATE VARIABLES
    // ====================================================================

    /// @notice Mapping of order ID to order details
    mapping(bytes32 => PrivateOrder) public orders;

    /// @notice Array of all order IDs for iteration
    bytes32[] public orderIds;

    /// @notice Mapping of user address to their order IDs
    mapping(address => bytes32[]) public userOrders;

    /// @notice Total number of orders submitted
    uint256 public totalOrders;

    /// @notice Total number of trades executed
    uint256 public totalTrades;

    /// @notice Active (non-filled, non-cancelled) order count per user
    mapping(address => uint256) public activeOrderCount;

    /// @notice Per-user order submission counter (order ID entropy)
    mapping(address => uint256) public userOrderCount;

    /// @notice Whether contract is ossified (permanently
    ///         non-upgradeable)
    bool private _ossified;

    /// @notice Global active order counter for O(1) stats queries
    /// @dev L-01: Incremented on submit, decremented on fill/cancel
    uint256 public totalActiveOrders;

    /// @notice Timestamp when ossification was requested (0 = not
    ///         requested). Must wait OSSIFICATION_DELAY before confirm.
    uint256 public ossificationRequestTime;

    /**
     * @dev Storage gap for future upgrades.
     * @notice Reserves storage slots for adding new variables in
     *         upgrades without shifting inherited contract storage.
     *
     * Current named sequential state variables:
     *   - orderIds             (1 slot for length)
     *   - totalOrders          (1 slot)
     *   - totalTrades          (1 slot)
     *   - _ossified            (1 slot)
     *   - totalActiveOrders    (1 slot)
     *   - ossificationRequestTime (1 slot)
     * Mappings (orders, userOrders, activeOrderCount, userOrderCount)
     * do not consume sequential slots.
     *
     * Gap = 50 - 6 = 44 slots reserved
     */
    uint256[44] private __gap;

    // ====================================================================
    // EVENTS
    // ====================================================================

    /// @notice Emitted when a private order is submitted
    /// @param orderId Unique order identifier
    /// @param trader Trader address
    /// @param pair Trading pair
    event PrivateOrderSubmitted(
        bytes32 indexed orderId,
        address indexed trader,
        string pair
    );

    /// @notice Emitted when two orders are matched
    /// @param buyOrderId Buy order identifier
    /// @param sellOrderId Sell order identifier
    /// @param tradeId Unique trade identifier
    event PrivateOrderMatched(
        bytes32 indexed buyOrderId,
        bytes32 indexed sellOrderId,
        bytes32 indexed tradeId
    );

    /// @notice Emitted when an order is cancelled
    /// @param orderId Order identifier
    /// @param trader Trader address
    event PrivateOrderCancelled(
        bytes32 indexed orderId,
        address indexed trader
    );

    /// @notice Emitted when an order status changes
    /// @param orderId Order identifier
    /// @param oldStatus Previous status
    /// @param newStatus New status
    event OrderStatusChanged(
        bytes32 indexed orderId,
        OrderStatus oldStatus,
        OrderStatus newStatus
    );

    /// @notice Emitted when ossification is requested (starts delay)
    /// @param contractAddress Address of this contract
    /// @param requestTime Timestamp of the request
    event OssificationRequested(
        address indexed contractAddress,
        uint256 indexed requestTime
    );

    /// @notice Emitted when the contract is permanently ossified
    /// @param contractAddress Address of this contract
    event ContractOssified(address indexed contractAddress);

    // ====================================================================
    // CUSTOM ERRORS
    // ====================================================================

    /// @notice Thrown when order does not exist
    error OrderNotFound();

    /// @notice Thrown when caller is not order owner
    error Unauthorized();

    /// @notice Thrown when amount is invalid
    error InvalidAmount();

    /// @notice Thrown when order status prevents operation
    error InvalidOrderStatus();

    /// @notice Thrown when user has too many orders
    error TooManyOrders();

    /// @notice Thrown when trading pair is invalid
    error InvalidPair();

    /// @notice Thrown when fill amount exceeds order amount (overfill)
    error OverfillDetected();

    /// @notice Thrown when an invalid address is provided
    error InvalidAddress();

    /// @notice Thrown when order has expired
    error OrderExpired();

    /// @notice Thrown when fill amount is below minimum
    error FillBelowMinimum();

    /// @notice Thrown when contract is ossified and upgrade attempted
    error ContractIsOssified();

    /// @notice Thrown when buy price < sell price (incompatible)
    error PriceIncompatible();

    /// @notice Thrown when buy/sell sides do not match expectations
    error InvalidOrderSides();

    /// @notice Thrown when trading pairs do not match between orders
    error PairMismatch();

    /// @notice Thrown when fee exceeds 100%
    error FeeTooHigh();

    /// @notice Thrown when ossification has not been requested
    error OssificationNotRequested();

    /// @notice Thrown when ossification delay has not elapsed
    error OssificationDelayNotElapsed();

    // ====================================================================
    // CONSTRUCTOR & INITIALIZATION
    // ====================================================================

    /**
     * @notice Constructor for PrivateDEX (upgradeable pattern)
     * @dev Disables initializers to prevent implementation contract
     *      from being initialized directly.
     * @custom:oz-upgrades-unsafe-allow constructor
     */
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the PrivateDEX contract
     * @dev Initializes all inherited contracts and sets up roles
     * @param admin Admin address for role management
     */
    function initialize(address admin) external initializer {
        if (admin == address(0)) revert InvalidAddress();

        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);
        _grantRole(MATCHER_ROLE, admin);
    }

    // ====================================================================
    // ORDER SUBMISSION
    // ====================================================================

    /**
     * @notice Submit a private order with encrypted amount and price
     * @dev Amount and price remain encrypted throughout the matching
     *      process. All encrypted amounts must be pre-scaled to
     *      6-decimal (micro-XOM) before encryption due to COTI MPC
     *      uint64 limitation.
     * @param isBuy Whether this is a buy order
     * @param pair Trading pair symbol (e.g., "pXOM-USDC")
     * @param encAmount Encrypted order amount (ctUint64)
     * @param encPrice Encrypted limit price (ctUint64)
     * @param expiry Unix timestamp after which the order cannot be
     *        matched. Pass 0 for no expiry (good-till-cancelled).
     * @param encMinFill Encrypted minimum fill amount per match.
     *        Pass encrypted zero for no minimum.
     * @return orderId Unique order identifier
     */
    function submitPrivateOrder(
        bool isBuy,
        string calldata pair,
        ctUint64 encAmount,
        ctUint64 encPrice,
        uint256 expiry,
        ctUint64 encMinFill
    )
        external
        whenNotPaused
        nonReentrant
        returns (bytes32 orderId)
    {
        if (bytes(pair).length == 0) revert InvalidPair();
        // Cap based on active orders (not lifetime)
        // solhint-disable-next-line gas-strict-inequalities
        if (activeOrderCount[msg.sender] >= MAX_ORDERS_PER_USER) {
            revert TooManyOrders();
        }

        // Generate unique order ID with strong entropy
        uint256 userCount = ++userOrderCount[msg.sender];
        orderId = keccak256(abi.encode(
            msg.sender,
            // solhint-disable-next-line not-rely-on-time
            block.timestamp,
            block.prevrandao,
            userCount,
            totalOrders
        ));

        // Initialize encrypted zero for filled amount
        gtUint64 gtZero = MpcCore.setPublic64(uint64(0));
        ctUint64 encZero = MpcCore.offBoard(gtZero);

        // Create order
        orders[orderId] = PrivateOrder({
            orderId: orderId,
            trader: msg.sender,
            isBuy: isBuy,
            pair: pair,
            encAmount: encAmount,
            encPrice: encPrice,
            // solhint-disable-next-line not-rely-on-time
            timestamp: block.timestamp,
            status: OrderStatus.OPEN,
            encFilled: encZero,
            expiry: expiry,
            encMinFill: encMinFill
        });

        // Track order
        orderIds.push(orderId);
        userOrders[msg.sender].push(orderId);
        ++totalOrders;
        ++activeOrderCount[msg.sender];
        // L-01: Maintain global active order counter
        ++totalActiveOrders;

        emit PrivateOrderSubmitted(orderId, msg.sender, pair);
        return orderId;
    }

    // ====================================================================
    // ORDER MATCHING (MPC OPERATIONS)
    // ====================================================================

    /**
     * @notice Check if two orders can match using MPC price comparison
     * @dev Uses MPC ge() and decrypt() which modify state, cannot be
     *      view. Restricted to MATCHER_ROLE to prevent price oracle
     *      attacks.
     * @param buyOrderId Buy order ID
     * @param sellOrderId Sell order ID
     * @return canMatch Whether orders can match (buy price >= sell
     *         price, same pair, correct sides, not expired)
     */
    function canOrdersMatch( // solhint-disable-line code-complexity
        bytes32 buyOrderId,
        bytes32 sellOrderId
    )
        external
        onlyRole(MATCHER_ROLE)
        nonReentrant
        returns (bool canMatch)
    {
        PrivateOrder storage buyOrder = orders[buyOrderId];
        PrivateOrder storage sellOrder = orders[sellOrderId];

        // Validate orders exist and have correct types
        if (buyOrder.trader == address(0)) {
            revert OrderNotFound();
        }
        if (sellOrder.trader == address(0)) {
            revert OrderNotFound();
        }

        // Check order statuses
        if (
            buyOrder.status != OrderStatus.OPEN &&
            buyOrder.status != OrderStatus.PARTIALLY_FILLED
        ) {
            return false;
        }
        if (
            sellOrder.status != OrderStatus.OPEN &&
            sellOrder.status != OrderStatus.PARTIALLY_FILLED
        ) {
            return false;
        }

        // Check expiry (0 means no expiry / good-till-cancelled)
        /* solhint-disable not-rely-on-time */
        if (
            buyOrder.expiry != 0 &&
            block.timestamp > buyOrder.expiry
        ) {
            return false;
        }
        if (
            sellOrder.expiry != 0 &&
            block.timestamp > sellOrder.expiry
        ) {
            return false;
        }
        /* solhint-enable not-rely-on-time */

        // Check order sides
        if (!buyOrder.isBuy || sellOrder.isBuy) {
            return false;
        }

        // Check trading pair match
        if (
            keccak256(bytes(buyOrder.pair)) !=
            keccak256(bytes(sellOrder.pair))
        ) {
            return false;
        }

        // MPC comparison: buyPrice >= sellPrice (encrypted)
        gtUint64 gtBuyPrice =
            MpcCore.onBoard(buyOrder.encPrice);
        gtUint64 gtSellPrice =
            MpcCore.onBoard(sellOrder.encPrice);
        gtBool gtCanMatch = MpcCore.ge(gtBuyPrice, gtSellPrice);

        // Decrypt result (only boolean revealed, not prices)
        return MpcCore.decrypt(gtCanMatch);
    }

    /**
     * @notice Calculate match amount (minimum of remaining amounts)
     * @dev Uses MPC operations which modify state, cannot be view.
     *      Restricted to MATCHER_ROLE to limit price leakage.
     *      H-01: Uses checkedSub to revert on underflow.
     * @param buyOrderId Buy order ID
     * @param sellOrderId Sell order ID
     * @return encMatchAmount Encrypted match amount (ctUint64)
     */
    function calculateMatchAmount(
        bytes32 buyOrderId,
        bytes32 sellOrderId
    )
        external
        onlyRole(MATCHER_ROLE)
        nonReentrant
        returns (ctUint64 encMatchAmount)
    {
        PrivateOrder storage buyOrder = orders[buyOrderId];
        PrivateOrder storage sellOrder = orders[sellOrderId];

        if (
            buyOrder.trader == address(0) ||
            sellOrder.trader == address(0)
        ) {
            revert OrderNotFound();
        }

        // Calculate remaining amounts using checked subtraction
        gtUint64 gtBuyAmount =
            MpcCore.onBoard(buyOrder.encAmount);
        gtUint64 gtBuyFilled =
            MpcCore.onBoard(buyOrder.encFilled);
        gtUint64 gtBuyRemaining =
            MpcCore.checkedSub(gtBuyAmount, gtBuyFilled);

        gtUint64 gtSellAmount =
            MpcCore.onBoard(sellOrder.encAmount);
        gtUint64 gtSellFilled =
            MpcCore.onBoard(sellOrder.encFilled);
        gtUint64 gtSellRemaining =
            MpcCore.checkedSub(gtSellAmount, gtSellFilled);

        // Calculate minimum (match amount) using MPC
        gtUint64 gtMatchAmount =
            MpcCore.min(gtBuyRemaining, gtSellRemaining);

        return MpcCore.offBoard(gtMatchAmount);
    }

    /**
     * @notice Calculate trade fees using MPC multiplication
     * @dev H-02: Restricted to MATCHER_ROLE to prevent resource
     *      exhaustion. feeBps validated to be <= MAX_FEE_BPS (10000).
     *      H-01: Uses checkedMul to revert on overflow.
     * @param encAmount Encrypted trade amount
     * @param feeBps Fee in basis points (max 10000 = 100%)
     * @return encFees Encrypted fee amount
     */
    function calculateTradeFees(
        ctUint64 encAmount,
        uint64 feeBps
    )
        external
        onlyRole(MATCHER_ROLE)
        nonReentrant
        returns (ctUint64 encFees)
    {
        // H-02: Validate fee does not exceed 100%
        if (feeBps > MAX_FEE_BPS) revert FeeTooHigh();

        // Convert encrypted amount to computation type
        gtUint64 gtAmount = MpcCore.onBoard(encAmount);

        // Create public values for fee calculation
        gtUint64 gtFeeBps = MpcCore.setPublic64(feeBps);
        gtUint64 gtBasis = MpcCore.setPublic64(MAX_FEE_BPS);

        // H-01: checkedMul reverts on overflow
        // Calculate: fees = (amount * feeBps) / 10000
        gtUint64 gtProduct =
            MpcCore.checkedMul(gtAmount, gtFeeBps);
        gtUint64 gtFees = MpcCore.div(gtProduct, gtBasis);

        return MpcCore.offBoard(gtFees);
    }

    // ====================================================================
    // TRADE EXECUTION
    // ====================================================================

    /**
     * @notice Execute a private trade (match and update order states)
     * @dev C-01 fix: Match amount is computed internally as
     *      min(buyRemaining, sellRemaining), not supplied externally.
     *      C-02 fix: Price, side, and pair are re-validated inside
     *      this function to prevent stale or incompatible matches.
     *      H-01 fix: All MPC arithmetic uses checked variants.
     *
     *      Fee calculation and distribution happens during settlement
     *      on Avalanche OmniCore / PrivateDEXSettlement contract.
     *
     * @param buyOrderId Buy order ID
     * @param sellOrderId Sell order ID
     * @return tradeId Unique trade identifier
     */
    function executePrivateTrade( // solhint-disable-line code-complexity, function-max-lines
        bytes32 buyOrderId,
        bytes32 sellOrderId
    )
        external
        onlyRole(MATCHER_ROLE)
        whenNotPaused
        nonReentrant
        returns (bytes32 tradeId)
    {
        PrivateOrder storage buyOrder = orders[buyOrderId];
        PrivateOrder storage sellOrder = orders[sellOrderId];

        if (
            buyOrder.trader == address(0) ||
            sellOrder.trader == address(0)
        ) {
            revert OrderNotFound();
        }

        // Validate order statuses
        if (
            buyOrder.status == OrderStatus.FILLED ||
            buyOrder.status == OrderStatus.CANCELLED
        ) {
            revert InvalidOrderStatus();
        }
        if (
            sellOrder.status == OrderStatus.FILLED ||
            sellOrder.status == OrderStatus.CANCELLED
        ) {
            revert InvalidOrderStatus();
        }

        // C-02: Re-validate order sides
        if (!buyOrder.isBuy) revert InvalidOrderSides();
        if (sellOrder.isBuy) revert InvalidOrderSides();

        // C-02: Re-validate trading pair match
        if (
            keccak256(bytes(buyOrder.pair)) !=
            keccak256(bytes(sellOrder.pair))
        ) {
            revert PairMismatch();
        }

        // Check order expiry
        /* solhint-disable not-rely-on-time */
        if (
            buyOrder.expiry != 0 &&
            block.timestamp > buyOrder.expiry
        ) {
            revert OrderExpired();
        }
        if (
            sellOrder.expiry != 0 &&
            block.timestamp > sellOrder.expiry
        ) {
            revert OrderExpired();
        }
        /* solhint-enable not-rely-on-time */

        // C-02: Re-validate price compatibility (buyPrice >= sellPrice)
        gtUint64 gtBuyPrice =
            MpcCore.onBoard(buyOrder.encPrice);
        gtUint64 gtSellPrice =
            MpcCore.onBoard(sellOrder.encPrice);
        gtBool pricesCompatible =
            MpcCore.ge(gtBuyPrice, gtSellPrice);
        if (!MpcCore.decrypt(pricesCompatible)) {
            revert PriceIncompatible();
        }

        // C-01: Compute match amount internally as
        // min(buyRemaining, sellRemaining) -- prevents matcher from
        // fabricating arbitrary match amounts
        gtUint64 gtBuyAmount =
            MpcCore.onBoard(buyOrder.encAmount);
        gtUint64 gtBuyFilled =
            MpcCore.onBoard(buyOrder.encFilled);
        gtUint64 gtBuyRemaining =
            MpcCore.checkedSub(gtBuyAmount, gtBuyFilled);

        gtUint64 gtSellAmount =
            MpcCore.onBoard(sellOrder.encAmount);
        gtUint64 gtSellFilled =
            MpcCore.onBoard(sellOrder.encFilled);
        gtUint64 gtSellRemaining =
            MpcCore.checkedSub(gtSellAmount, gtSellFilled);

        gtUint64 gtMatchAmount =
            MpcCore.min(gtBuyRemaining, gtSellRemaining);

        // Check minimum fill for both orders
        _checkMinFill(buyOrder.encMinFill, gtMatchAmount);
        _checkMinFill(sellOrder.encMinFill, gtMatchAmount);

        // Update buy order filled amount: filled += matchAmount
        gtUint64 gtNewBuyFilled =
            MpcCore.checkedAdd(gtBuyFilled, gtMatchAmount);

        // Update sell order filled amount: filled += matchAmount
        gtUint64 gtNewSellFilled =
            MpcCore.checkedAdd(gtSellFilled, gtMatchAmount);

        // Overfill guard: ensure filled does not exceed order amount
        gtBool buyNotOverfilled =
            MpcCore.ge(gtBuyAmount, gtNewBuyFilled);
        if (!MpcCore.decrypt(buyNotOverfilled)) {
            revert OverfillDetected();
        }

        gtBool sellNotOverfilled =
            MpcCore.ge(gtSellAmount, gtNewSellFilled);
        if (!MpcCore.decrypt(sellNotOverfilled)) {
            revert OverfillDetected();
        }

        // Commit updated fill amounts after validation
        buyOrder.encFilled = MpcCore.offBoard(gtNewBuyFilled);
        sellOrder.encFilled = MpcCore.offBoard(gtNewSellFilled);

        // Check if buy order is fully filled
        OrderStatus oldBuyStatus = buyOrder.status;
        gtBool buyFullyFilled =
            MpcCore.eq(gtNewBuyFilled, gtBuyAmount);
        if (MpcCore.decrypt(buyFullyFilled)) {
            buyOrder.status = OrderStatus.FILLED;
            if (activeOrderCount[buyOrder.trader] > 0) {
                --activeOrderCount[buyOrder.trader];
            }
            // L-01: Decrement global counter
            if (totalActiveOrders > 0) {
                --totalActiveOrders;
            }
        } else {
            buyOrder.status = OrderStatus.PARTIALLY_FILLED;
        }
        if (buyOrder.status != oldBuyStatus) {
            emit OrderStatusChanged(
                buyOrderId, oldBuyStatus, buyOrder.status
            );
        }

        // Check if sell order is fully filled
        OrderStatus oldSellStatus = sellOrder.status;
        gtBool sellFullyFilled =
            MpcCore.eq(gtNewSellFilled, gtSellAmount);
        if (MpcCore.decrypt(sellFullyFilled)) {
            sellOrder.status = OrderStatus.FILLED;
            if (activeOrderCount[sellOrder.trader] > 0) {
                --activeOrderCount[sellOrder.trader];
            }
            // L-01: Decrement global counter
            if (totalActiveOrders > 0) {
                --totalActiveOrders;
            }
        } else {
            sellOrder.status = OrderStatus.PARTIALLY_FILLED;
        }
        if (sellOrder.status != oldSellStatus) {
            emit OrderStatusChanged(
                sellOrderId, oldSellStatus, sellOrder.status
            );
        }

        // M-03: Use abi.encode + prevrandao for trade ID
        ++totalTrades;
        tradeId = keccak256(abi.encode(
            buyOrderId,
            sellOrderId,
            // solhint-disable-next-line not-rely-on-time
            block.timestamp,
            block.prevrandao,
            totalTrades
        ));

        // Emit match event with trade ID
        emit PrivateOrderMatched(
            buyOrderId, sellOrderId, tradeId
        );

        return tradeId;
    }

    // ====================================================================
    // ORDER MANAGEMENT
    // ====================================================================

    /**
     * @notice Cancel a private order
     * @dev Only order owner can cancel. Cannot cancel filled orders.
     * @param orderId Order ID to cancel
     */
    function cancelPrivateOrder(
        bytes32 orderId
    ) external whenNotPaused nonReentrant {
        PrivateOrder storage order = orders[orderId];

        if (order.trader == address(0)) revert OrderNotFound();
        if (order.trader != msg.sender) revert Unauthorized();
        if (
            order.status == OrderStatus.FILLED ||
            order.status == OrderStatus.CANCELLED
        ) {
            revert InvalidOrderStatus();
        }

        OrderStatus oldStatus = order.status;
        order.status = OrderStatus.CANCELLED;

        // Decrement active order count
        if (activeOrderCount[msg.sender] > 0) {
            --activeOrderCount[msg.sender];
        }
        // L-01: Decrement global counter
        if (totalActiveOrders > 0) {
            --totalActiveOrders;
        }

        emit OrderStatusChanged(
            orderId, oldStatus, OrderStatus.CANCELLED
        );
        emit PrivateOrderCancelled(orderId, msg.sender);
    }

    // ====================================================================
    // QUERY FUNCTIONS (non-view external)
    // ====================================================================

    /**
     * @notice Check if order is fully filled using MPC comparison
     * @dev Uses MPC eq() and decrypt() which modify state, cannot
     *      be view.
     * @param orderId Order ID to check
     * @return isFullyFilled Whether order is completely filled
     */
    function isOrderFullyFilled(
        bytes32 orderId
    ) external nonReentrant returns (bool isFullyFilled) {
        PrivateOrder storage order = orders[orderId];

        if (order.trader == address(0)) revert OrderNotFound();

        // Check status first (optimization)
        if (order.status == OrderStatus.FILLED) {
            return true;
        }
        if (order.status == OrderStatus.CANCELLED) {
            return false;
        }

        // MPC comparison: filled == amount
        gtUint64 gtAmount = MpcCore.onBoard(order.encAmount);
        gtUint64 gtFilled = MpcCore.onBoard(order.encFilled);
        gtBool gtIsFull = MpcCore.eq(gtFilled, gtAmount);

        return MpcCore.decrypt(gtIsFull);
    }

    // ====================================================================
    // ADMIN FUNCTIONS
    // ====================================================================

    /**
     * @notice Pause all trading operations
     * @dev Only admin can pause
     */
    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause trading operations
     * @dev Only admin can unpause
     */
    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    /**
     * @notice Grant matcher role to address
     * @dev Only admin can grant matcher role
     * @param matcher Address to grant matcher role
     */
    function grantMatcherRole(
        address matcher
    ) external onlyRole(ADMIN_ROLE) {
        if (matcher == address(0)) revert InvalidAddress();
        _grantRole(MATCHER_ROLE, matcher);
    }

    /**
     * @notice Revoke matcher role from address
     * @dev Only admin can revoke matcher role
     * @param matcher Address to revoke matcher role from
     */
    function revokeMatcherRole(
        address matcher
    ) external onlyRole(ADMIN_ROLE) {
        _revokeRole(MATCHER_ROLE, matcher);
    }

    // ====================================================================
    // OSSIFICATION
    // ====================================================================

    /**
     * @notice Request ossification (starts 7-day delay)
     * @dev M-01: Two-step ossification prevents accidental or
     *      malicious irreversible lockout. Once confirmed after
     *      OSSIFICATION_DELAY, the contract becomes permanently
     *      non-upgradeable.
     */
    function requestOssification()
        external
        onlyRole(ADMIN_ROLE)
    {
        // solhint-disable-next-line not-rely-on-time
        ossificationRequestTime = block.timestamp;
        emit OssificationRequested(
            address(this),
            // solhint-disable-next-line not-rely-on-time
            block.timestamp
        );
    }

    /**
     * @notice Confirm and execute ossification after delay
     * @dev Requires OSSIFICATION_DELAY (7 days) to have elapsed
     *      since requestOssification() was called. Once executed,
     *      no further proxy upgrades are possible (irreversible).
     */
    function confirmOssification()
        external
        onlyRole(ADMIN_ROLE)
    {
        if (ossificationRequestTime == 0) {
            revert OssificationNotRequested();
        }
        if (
            // solhint-disable-next-line not-rely-on-time
            block.timestamp
                < ossificationRequestTime + OSSIFICATION_DELAY
        ) {
            revert OssificationDelayNotElapsed();
        }
        _ossified = true;
        emit ContractOssified(address(this));
    }

    /**
     * @notice Check if the contract has been permanently ossified
     * @return True if ossified (no further upgrades possible)
     */
    function isOssified() external view returns (bool) {
        return _ossified;
    }

    // ====================================================================
    // VIEW FUNCTIONS
    // ====================================================================

    /**
     * @notice Get privacy statistics
     * @dev Returns public metrics about platform usage. Uses the
     *      totalActiveOrders counter for O(1) gas efficiency (L-01).
     * @return totalOrdersCount Total orders submitted
     * @return totalTradesCount Total trades executed
     * @return activeOrdersCount Currently active orders
     */
    function getPrivacyStats() external view returns (
        uint256 totalOrdersCount,
        uint256 totalTradesCount,
        uint256 activeOrdersCount
    ) {
        return (totalOrders, totalTrades, totalActiveOrders);
    }

    /**
     * @notice Get order book for a trading pair (encrypted amounts)
     * @dev Returns arrays of order IDs for buy and sell sides.
     *      Warning: iterates orderIds array -- gas cost grows with
     *      total order count. Intended for off-chain calls only.
     * @param pair Trading pair to query
     * @param maxOrders Maximum number of orders to return per side
     * @return buyOrders Array of buy order IDs
     * @return sellOrders Array of sell order IDs
     */
    function getOrderBook( // solhint-disable-line code-complexity
        string calldata pair,
        uint256 maxOrders
    )
        external
        view
        returns (
            bytes32[] memory buyOrders,
            bytes32[] memory sellOrders
        )
    {
        bytes32 pairHash = keccak256(bytes(pair));

        // Count matching orders
        uint256 buyCount = 0;
        uint256 sellCount = 0;
        for (uint256 i = 0; i < orderIds.length; ++i) {
            bytes32 oid = orderIds[i];
            PrivateOrder storage order = orders[oid];

            if (
                keccak256(bytes(order.pair)) != pairHash
            ) continue;
            if (
                order.status != OrderStatus.OPEN &&
                order.status != OrderStatus.PARTIALLY_FILLED
            ) {
                continue;
            }

            if (order.isBuy) {
                ++buyCount;
            } else {
                ++sellCount;
            }
        }

        // Cap at maxOrders
        uint256 buyLimit =
            buyCount > maxOrders ? maxOrders : buyCount;
        uint256 sellLimit =
            sellCount > maxOrders ? maxOrders : sellCount;

        // Allocate arrays
        buyOrders = new bytes32[](buyLimit);
        sellOrders = new bytes32[](sellLimit);

        // Fill arrays
        uint256 buyIdx = 0;
        uint256 sellIdx = 0;
        for (
            uint256 i = 0;
            i < orderIds.length &&
                (buyIdx < buyLimit || sellIdx < sellLimit);
            ++i
        ) {
            bytes32 oid = orderIds[i];
            PrivateOrder storage order = orders[oid];

            if (
                keccak256(bytes(order.pair)) != pairHash
            ) continue;
            if (
                order.status != OrderStatus.OPEN &&
                order.status != OrderStatus.PARTIALLY_FILLED
            ) {
                continue;
            }

            if (order.isBuy && buyIdx < buyLimit) {
                buyOrders[buyIdx] = oid;
                ++buyIdx;
            } else if (!order.isBuy && sellIdx < sellLimit) {
                sellOrders[sellIdx] = oid;
                ++sellIdx;
            }
        }

        return (buyOrders, sellOrders);
    }

    // ====================================================================
    // INTERNAL FUNCTIONS
    // ====================================================================

    /**
     * @notice Verify fill amount meets minimum requirement
     * @dev L-03: Simplified -- always performs exactly 1 MPC ge()
     *      comparison + 1 decrypt. When encMinFill is zero, ge(fill,0)
     *      is trivially true, so no separate zero-check is needed.
     * @param encMinFill Encrypted minimum fill amount from the order
     * @param gtFillAmount The proposed fill amount (already onboarded)
     */
    function _checkMinFill(
        ctUint64 encMinFill,
        gtUint64 gtFillAmount
    ) internal {
        gtUint64 gtMinFill = MpcCore.onBoard(encMinFill);

        // Fill amount must be >= minimum fill amount.
        // When minFill is zero, this is trivially true (any
        // fill >= 0), so no minimum is enforced.
        gtBool meetsMinimum =
            MpcCore.ge(gtFillAmount, gtMinFill);
        if (!MpcCore.decrypt(meetsMinimum)) {
            revert FillBelowMinimum();
        }
    }

    /**
     * @notice Authorize contract upgrades (UUPS pattern)
     * @dev Only admin can authorize upgrades to new implementation.
     *      Reverts if contract is ossified.
     * @param newImplementation Address of new implementation contract
     */
    function _authorizeUpgrade(
        address newImplementation // solhint-disable-line no-unused-vars
    )
        internal
        override
        onlyRole(ADMIN_ROLE)
    {
        if (_ossified) revert ContractIsOssified();
    }
}
