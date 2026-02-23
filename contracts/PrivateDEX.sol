// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {MpcCore, gtUint64, ctUint64, gtBool} from "../coti-contracts/contracts/utils/mpc/MpcCore.sol";

/**
 * @title PrivateDEX
 * @author OmniCoin Development Team
 * @notice Privacy-preserving DEX order matching using COTI V2 MPC technology
 * @dev Handles encrypted order matching where amounts and prices remain hidden
 *
 * Architecture:
 * - Orders submitted with encrypted amounts/prices (ctUint64)
 * - Matching uses MPC operations (ge, min, add, sub, eq)
 * - Amounts never revealed on-chain
 * - Settlement occurs on Avalanche via OmniCore
 *
 * Security Features:
 * - Reentrancy protection
 * - Role-based access control
 * - Pausable for emergencies
 * - Upgradeable via UUPS pattern
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

    // ========================================================================
    // TYPE DECLARATIONS (enums + structs before constants per solhint)
    // ========================================================================

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
     *      Includes expiry for time-limited orders (M-02) and
     *      minFillAmount for slippage protection (M-03).
     */
    struct PrivateOrder {
        bytes32 orderId;         // Unique order identifier
        address trader;          // Trader address (public)
        bool isBuy;              // Buy or sell order (public)
        string pair;             // Trading pair (public, e.g., "pXOM-USDC")
        ctUint64 encAmount;      // Encrypted order size
        ctUint64 encPrice;       // Encrypted limit price
        uint256 timestamp;       // Order creation time (public)
        OrderStatus status;      // Order status (public)
        ctUint64 encFilled;      // Encrypted filled amount
        uint256 expiry;          // Order expiration timestamp (M-02)
        ctUint64 encMinFill;     // Encrypted minimum fill amount (M-03)
    }

    // ========================================================================
    // CONSTANTS
    // ========================================================================

    /// @notice Role identifier for order matchers
    bytes32 public constant MATCHER_ROLE = keccak256("MATCHER_ROLE");

    /// @notice Role identifier for admin operations
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /// @notice Maximum orders per user to prevent spam
    uint256 public constant MAX_ORDERS_PER_USER = 100;

    // ========================================================================
    // STATE VARIABLES
    // ========================================================================

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

    /// @notice Per-user order submission counter (used for order ID entropy)
    mapping(address => uint256) public userOrderCount;

    /// @notice Whether contract is ossified (permanently non-upgradeable)
    bool private _ossified;

    /**
     * @dev Storage gap for future upgrades
     * @notice Reserves storage slots for adding new variables without breaking upgradeability
     * Current storage: 8 variables (including _ossified)
     * Gap size: 50 - 8 = 42 slots reserved
     */
    uint256[42] private __gap;

    // ========================================================================
    // EVENTS
    // ========================================================================

    /// @notice Emitted when a private order is submitted
    /// @param orderId Unique order identifier
    /// @param trader Trader address
    /// @param pair Trading pair
    event PrivateOrderSubmitted(bytes32 indexed orderId, address indexed trader, string pair);

    /// @notice Emitted when two orders are matched
    /// @param buyOrderId Buy order identifier
    /// @param sellOrderId Sell order identifier
    /// @param encryptedAmount Encrypted match amount (ctUint64 as bytes32)
    event PrivateOrderMatched(
        bytes32 indexed buyOrderId,
        bytes32 indexed sellOrderId,
        bytes32 encryptedAmount
    );

    /// @notice Emitted when an order is cancelled
    /// @param orderId Order identifier
    /// @param trader Trader address
    event PrivateOrderCancelled(bytes32 indexed orderId, address indexed trader);

    /// @notice Emitted when an order status changes
    /// @param orderId Order identifier
    /// @param oldStatus Previous status
    /// @param newStatus New status
    event OrderStatusChanged(bytes32 indexed orderId, OrderStatus oldStatus, OrderStatus newStatus);

    /// @notice Emitted when the contract is permanently ossified
    /// @param contractAddress Address of this contract
    event ContractOssified(address indexed contractAddress);

    // ========================================================================
    // CUSTOM ERRORS
    // ========================================================================

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

    /// @notice Thrown when order has expired (M-02)
    error OrderExpired();

    /// @notice Thrown when fill amount is below minimum (M-03)
    error FillBelowMinimum();

    /// @notice Thrown when contract is ossified and upgrade attempted
    error ContractIsOssified();

    // ========================================================================
    // CONSTRUCTOR & INITIALIZATION
    // ========================================================================

    /**
     * @notice Constructor for PrivateDEX (upgradeable pattern)
     * @dev Disables initializers to prevent implementation contract from being initialized
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
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);
        _grantRole(MATCHER_ROLE, admin);  // Initially admin can match
    }

    // ========================================================================
    // ORDER SUBMISSION
    // ========================================================================

    /**
     * @notice Submit a private order with encrypted amount and price
     * @dev Amount and price remain encrypted throughout matching process.
     *      Includes time-limited expiry (M-02) and minimum fill size (M-03).
     * @param isBuy Whether this is a buy order
     * @param pair Trading pair symbol (e.g., "pXOM-USDC")
     * @param encAmount Encrypted order amount (ctUint64)
     * @param encPrice Encrypted limit price (ctUint64)
     * @param expiry Unix timestamp after which the order cannot be matched (M-02).
     *        Pass 0 for no expiry (good-till-cancelled).
     * @param encMinFill Encrypted minimum fill amount per match (M-03).
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
    ) external whenNotPaused nonReentrant returns (bytes32 orderId) {
        if (bytes(pair).length == 0) revert InvalidPair();
        // Cap based on active orders (not lifetime)
        // solhint-disable-next-line gas-strict-inequalities
        if (activeOrderCount[msg.sender] >= MAX_ORDERS_PER_USER) {
            revert TooManyOrders();
        }

        // Generate unique order ID with improved entropy (H-03 fix)
        // Uses abi.encode to prevent hash collisions from variable-length pair string,
        // adds block.prevrandao and per-user counter for stronger uniqueness
        uint256 userCount = ++userOrderCount[msg.sender];
        orderId = keccak256(abi.encode(
            msg.sender,
            block.timestamp, // solhint-disable-line not-rely-on-time
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
            timestamp: block.timestamp, // solhint-disable-line not-rely-on-time
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

        emit PrivateOrderSubmitted(orderId, msg.sender, pair);
        return orderId;
    }

    // ========================================================================
    // ORDER MATCHING (MPC OPERATIONS)
    // ========================================================================

    /**
     * @notice Check if two orders can match using MPC price comparison
     * @dev Uses MPC ge() and decrypt() which modify state, cannot be view.
     *      Restricted to MATCHER_ROLE to prevent price oracle attacks (M-04).
     * @param buyOrderId Buy order ID
     * @param sellOrderId Sell order ID
     * @return canMatch Whether orders can match (true if buy price >= sell price)
     */
    function canOrdersMatch( // solhint-disable-line code-complexity
        bytes32 buyOrderId,
        bytes32 sellOrderId
    ) external onlyRole(MATCHER_ROLE) returns (bool canMatch) {
        PrivateOrder storage buyOrder = orders[buyOrderId];
        PrivateOrder storage sellOrder = orders[sellOrderId];

        // Validate orders exist and have correct types
        if (buyOrder.trader == address(0)) revert OrderNotFound();
        if (sellOrder.trader == address(0)) revert OrderNotFound();

        // Check order statuses
        if (buyOrder.status != OrderStatus.OPEN && buyOrder.status != OrderStatus.PARTIALLY_FILLED) {
            return false;
        }
        if (sellOrder.status != OrderStatus.OPEN && sellOrder.status != OrderStatus.PARTIALLY_FILLED) {
            return false;
        }

        // M-02: Check expiry (0 means no expiry / good-till-cancelled)
        // solhint-disable-next-line not-rely-on-time
        if (buyOrder.expiry != 0 && block.timestamp > buyOrder.expiry) {
            return false;
        }
        // solhint-disable-next-line not-rely-on-time
        if (sellOrder.expiry != 0 && block.timestamp > sellOrder.expiry) {
            return false;
        }

        // Check order sides
        if (!buyOrder.isBuy || sellOrder.isBuy) {
            return false;
        }

        // Check trading pair match
        if (keccak256(bytes(buyOrder.pair)) != keccak256(bytes(sellOrder.pair))) {
            return false;
        }

        // MPC comparison: buyPrice >= sellPrice (encrypted)
        gtUint64 gtBuyPrice = MpcCore.onBoard(buyOrder.encPrice);
        gtUint64 gtSellPrice = MpcCore.onBoard(sellOrder.encPrice);
        gtBool gtCanMatch = MpcCore.ge(gtBuyPrice, gtSellPrice);

        // Decrypt result (only boolean is revealed, not actual prices)
        return MpcCore.decrypt(gtCanMatch);
    }

    /**
     * @notice Calculate match amount (minimum of remaining amounts)
     * @dev Uses MPC operations which modify state, cannot be view.
     *      Restricted to MATCHER_ROLE to limit price leakage (M-04).
     * @param buyOrderId Buy order ID
     * @param sellOrderId Sell order ID
     * @return encMatchAmount Encrypted match amount (ctUint64)
     */
    function calculateMatchAmount(
        bytes32 buyOrderId,
        bytes32 sellOrderId
    ) external onlyRole(MATCHER_ROLE) returns (ctUint64 encMatchAmount) {
        PrivateOrder storage buyOrder = orders[buyOrderId];
        PrivateOrder storage sellOrder = orders[sellOrderId];

        if (buyOrder.trader == address(0) || sellOrder.trader == address(0)) {
            revert OrderNotFound();
        }

        // Calculate remaining amounts using MPC subtraction
        gtUint64 gtBuyAmount = MpcCore.onBoard(buyOrder.encAmount);
        gtUint64 gtBuyFilled = MpcCore.onBoard(buyOrder.encFilled);
        gtUint64 gtBuyRemaining = MpcCore.sub(gtBuyAmount, gtBuyFilled);

        gtUint64 gtSellAmount = MpcCore.onBoard(sellOrder.encAmount);
        gtUint64 gtSellFilled = MpcCore.onBoard(sellOrder.encFilled);
        gtUint64 gtSellRemaining = MpcCore.sub(gtSellAmount, gtSellFilled);

        // Calculate minimum (match amount) using MPC
        gtUint64 gtMatchAmount = MpcCore.min(gtBuyRemaining, gtSellRemaining);

        return MpcCore.offBoard(gtMatchAmount);
    }

    /**
     * @notice Calculate trade fees using MPC multiplication
     * @dev MPC operations modify state, cannot be pure
     * @param encAmount Encrypted trade amount
     * @param feeBps Fee in basis points (public, e.g., 100 = 1%)
     * @return encFees Encrypted fee amount
     */
    function calculateTradeFees(
        ctUint64 encAmount,
        uint256 feeBps
    ) external returns (ctUint64 encFees) {
        // Convert encrypted amount to computation type
        gtUint64 gtAmount = MpcCore.onBoard(encAmount);

        // Create public values for fee calculation
        gtUint64 gtFeeBps = MpcCore.setPublic64(uint64(feeBps));
        gtUint64 gtBasis = MpcCore.setPublic64(10000);

        // Calculate: fees = (amount * feeBps) / 10000
        gtUint64 gtProduct = MpcCore.mul(gtAmount, gtFeeBps);
        gtUint64 gtFees = MpcCore.div(gtProduct, gtBasis);

        return MpcCore.offBoard(gtFees);
    }

    // ========================================================================
    // TRADE EXECUTION
    // ========================================================================

    /**
     * @notice Execute a private trade (match and update order states)
     * @dev Updates encrypted filled amounts using MPC operations. Fee calculation
     * and distribution happens during settlement on Avalanche OmniCore contract.
     * @param buyOrderId Buy order ID
     * @param sellOrderId Sell order ID
     * @param encMatchAmount Encrypted match amount (from calculateMatchAmount)
     * @return tradeId Unique trade identifier
     */
    function executePrivateTrade( // solhint-disable-line code-complexity
        bytes32 buyOrderId,
        bytes32 sellOrderId,
        ctUint64 encMatchAmount
    ) external onlyRole(MATCHER_ROLE) whenNotPaused nonReentrant returns (bytes32 tradeId) {
        PrivateOrder storage buyOrder = orders[buyOrderId];
        PrivateOrder storage sellOrder = orders[sellOrderId];

        if (buyOrder.trader == address(0) || sellOrder.trader == address(0)) {
            revert OrderNotFound();
        }

        // C-02 fix: Re-validate order statuses
        if (buyOrder.status == OrderStatus.FILLED || buyOrder.status == OrderStatus.CANCELLED) {
            revert InvalidOrderStatus();
        }
        if (sellOrder.status == OrderStatus.FILLED || sellOrder.status == OrderStatus.CANCELLED) {
            revert InvalidOrderStatus();
        }

        // M-02: Check order expiry
        // solhint-disable-next-line not-rely-on-time
        if (buyOrder.expiry != 0 && block.timestamp > buyOrder.expiry) {
            revert OrderExpired();
        }
        // solhint-disable-next-line not-rely-on-time
        if (sellOrder.expiry != 0 && block.timestamp > sellOrder.expiry) {
            revert OrderExpired();
        }

        // M-03: Check minimum fill amount for both orders
        gtUint64 gtMatchAmount_ = MpcCore.onBoard(encMatchAmount);
        _checkMinFill(buyOrder.encMinFill, gtMatchAmount_);
        _checkMinFill(sellOrder.encMinFill, gtMatchAmount_);

        // Update buy order filled amount: filled += matchAmount
        gtUint64 gtBuyFilled = MpcCore.onBoard(buyOrder.encFilled);
        gtUint64 gtMatchAmount = MpcCore.onBoard(encMatchAmount);
        gtUint64 gtNewBuyFilled = MpcCore.add(gtBuyFilled, gtMatchAmount);

        // Update sell order filled amount: filled += matchAmount
        gtUint64 gtSellFilled = MpcCore.onBoard(sellOrder.encFilled);
        gtUint64 gtNewSellFilled = MpcCore.add(gtSellFilled, gtMatchAmount);

        // H-02 fix: Overfill guard -- ensure filled does not exceed order amount
        gtUint64 gtBuyAmount = MpcCore.onBoard(buyOrder.encAmount);
        gtBool buyNotOverfilled = MpcCore.ge(gtBuyAmount, gtNewBuyFilled);
        if (!MpcCore.decrypt(buyNotOverfilled)) revert OverfillDetected();

        gtUint64 gtSellAmount = MpcCore.onBoard(sellOrder.encAmount);
        gtBool sellNotOverfilled = MpcCore.ge(gtSellAmount, gtNewSellFilled);
        if (!MpcCore.decrypt(sellNotOverfilled)) revert OverfillDetected();

        // Commit updated fill amounts after validation
        buyOrder.encFilled = MpcCore.offBoard(gtNewBuyFilled);
        sellOrder.encFilled = MpcCore.offBoard(gtNewSellFilled);

        // Check if buy order is fully filled: filled == amount
        // (reuse gtBuyAmount from overfill check above)
        OrderStatus oldBuyStatus = buyOrder.status;
        gtBool buyFullyFilled = MpcCore.eq(gtNewBuyFilled, gtBuyAmount);
        if (MpcCore.decrypt(buyFullyFilled)) {
            buyOrder.status = OrderStatus.FILLED;
            // Decrement active order count for fully filled orders (H-01 fix)
            if (activeOrderCount[buyOrder.trader] > 0) {
                --activeOrderCount[buyOrder.trader];
            }
        } else {
            buyOrder.status = OrderStatus.PARTIALLY_FILLED;
        }
        if (buyOrder.status != oldBuyStatus) {
            emit OrderStatusChanged(buyOrderId, oldBuyStatus, buyOrder.status);
        }

        // Check if sell order is fully filled: filled == amount
        // (reuse gtSellAmount from overfill check above)
        OrderStatus oldSellStatus = sellOrder.status;
        gtBool sellFullyFilled = MpcCore.eq(gtNewSellFilled, gtSellAmount);
        if (MpcCore.decrypt(sellFullyFilled)) {
            sellOrder.status = OrderStatus.FILLED;
            // Decrement active order count for fully filled orders (H-01 fix)
            if (activeOrderCount[sellOrder.trader] > 0) {
                --activeOrderCount[sellOrder.trader];
            }
        } else {
            sellOrder.status = OrderStatus.PARTIALLY_FILLED;
        }
        if (sellOrder.status != oldSellStatus) {
            emit OrderStatusChanged(sellOrderId, oldSellStatus, sellOrder.status);
        }

        // Generate trade ID
        ++totalTrades;
        // solhint-disable-next-line not-rely-on-time
        tradeId = keccak256(abi.encodePacked(buyOrderId, sellOrderId, block.timestamp, totalTrades));

        // Emit match event (amount is encrypted in event data)
        emit PrivateOrderMatched(buyOrderId, sellOrderId, bytes32(ctUint64.unwrap(encMatchAmount)));

        return tradeId;
    }

    // ========================================================================
    // ORDER MANAGEMENT
    // ========================================================================

    /**
     * @notice Cancel a private order
     * @dev Only order owner can cancel. Cannot cancel filled orders.
     * @param orderId Order ID to cancel
     */
    function cancelPrivateOrder(bytes32 orderId) external whenNotPaused {
        PrivateOrder storage order = orders[orderId];

        if (order.trader == address(0)) revert OrderNotFound();
        if (order.trader != msg.sender) revert Unauthorized();
        if (order.status == OrderStatus.FILLED || order.status == OrderStatus.CANCELLED) {
            revert InvalidOrderStatus();
        }

        OrderStatus oldStatus = order.status;
        order.status = OrderStatus.CANCELLED;

        // Decrement active order count (H-01 fix)
        if (activeOrderCount[msg.sender] > 0) {
            --activeOrderCount[msg.sender];
        }

        emit OrderStatusChanged(orderId, oldStatus, OrderStatus.CANCELLED);
        emit PrivateOrderCancelled(orderId, msg.sender);
    }

    // ========================================================================
    // QUERY FUNCTIONS (non-view external)
    // ========================================================================

    /**
     * @notice Check if order is fully filled using MPC comparison
     * @dev Uses MPC eq() and decrypt() which modify state, cannot be view
     * @param orderId Order ID to check
     * @return isFullyFilled Whether order is completely filled
     */
    function isOrderFullyFilled(bytes32 orderId) external returns (bool isFullyFilled) {
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

    // ========================================================================
    // ADMIN FUNCTIONS (external non-view, before view per solhint ordering)
    // ========================================================================

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
    function grantMatcherRole(address matcher) external onlyRole(ADMIN_ROLE) {
        if (matcher == address(0)) revert InvalidAddress();
        _grantRole(MATCHER_ROLE, matcher);
    }

    /**
     * @notice Revoke matcher role from address
     * @dev Only admin can revoke matcher role
     * @param matcher Address to revoke matcher role from
     */
    function revokeMatcherRole(address matcher) external onlyRole(ADMIN_ROLE) {
        _revokeRole(MATCHER_ROLE, matcher);
    }

    // ========================================================================
    // VIEW FUNCTIONS (external view, after non-view per solhint ordering)
    // ========================================================================

    /**
     * @notice Get privacy statistics
     * @dev Returns public metrics about platform usage
     * @return totalOrdersCount Total orders submitted
     * @return totalTradesCount Total trades executed
     * @return activeOrdersCount Currently active orders
     */
    function getPrivacyStats() external view returns (
        uint256 totalOrdersCount,
        uint256 totalTradesCount,
        uint256 activeOrdersCount
    ) {
        uint256 active = 0;
        for (uint256 i = 0; i < orderIds.length; ++i) {
            OrderStatus status = orders[orderIds[i]].status;
            if (status == OrderStatus.OPEN || status == OrderStatus.PARTIALLY_FILLED) {
                ++active;
            }
        }

        return (totalOrders, totalTrades, active);
    }

    /**
     * @notice Get order book for a trading pair (encrypted amounts)
     * @dev Returns arrays of order IDs for buy and sell sides
     * @param pair Trading pair to query
     * @param maxOrders Maximum number of orders to return per side
     * @return buyOrders Array of buy order IDs
     * @return sellOrders Array of sell order IDs
     */
    function getOrderBook(string calldata pair, uint256 maxOrders) // solhint-disable-line code-complexity
        external
        view
        returns (bytes32[] memory buyOrders, bytes32[] memory sellOrders)
    {
        bytes32 pairHash = keccak256(bytes(pair));

        // Count matching orders
        uint256 buyCount = 0;
        uint256 sellCount = 0;
        for (uint256 i = 0; i < orderIds.length; ++i) {
            bytes32 oid = orderIds[i];
            PrivateOrder storage order = orders[oid];

            if (keccak256(bytes(order.pair)) != pairHash) continue;
            if (order.status != OrderStatus.OPEN && order.status != OrderStatus.PARTIALLY_FILLED) {
                continue;
            }

            if (order.isBuy) {
                ++buyCount;
            } else {
                ++sellCount;
            }
        }

        // Cap at maxOrders
        uint256 buyLimit = buyCount > maxOrders ? maxOrders : buyCount;
        uint256 sellLimit = sellCount > maxOrders ? maxOrders : sellCount;

        // Allocate arrays
        buyOrders = new bytes32[](buyLimit);
        sellOrders = new bytes32[](sellLimit);

        // Fill arrays
        uint256 buyIdx = 0;
        uint256 sellIdx = 0;
        for (uint256 i = 0; i < orderIds.length && (buyIdx < buyLimit || sellIdx < sellLimit); ++i) {
            bytes32 oid = orderIds[i];
            PrivateOrder storage order = orders[oid];

            if (keccak256(bytes(order.pair)) != pairHash) continue;
            if (order.status != OrderStatus.OPEN && order.status != OrderStatus.PARTIALLY_FILLED) {
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

    // ========================================================================
    // INTERNAL FUNCTIONS (after external per solhint ordering)
    // ========================================================================

    /**
     * @notice Verify fill amount meets minimum requirement (M-03)
     * @dev Uses MPC comparison to check encrypted values. Skips check
     *      if encMinFill decrypts to zero (no minimum specified).
     * @param encMinFill Encrypted minimum fill amount from the order
     * @param gtFillAmount The proposed fill amount (already onboarded)
     */
    function _checkMinFill(
        ctUint64 encMinFill,
        gtUint64 gtFillAmount
    ) internal {
        gtUint64 gtMinFill = MpcCore.onBoard(encMinFill);
        gtUint64 gtZero = MpcCore.setPublic64(uint64(0));

        // Skip check if minFill is zero (no minimum set)
        gtBool isZero = MpcCore.eq(gtMinFill, gtZero);
        if (MpcCore.decrypt(isZero)) return;

        // Fill amount must be >= minimum fill amount
        gtBool meetsMinimum = MpcCore.ge(gtFillAmount, gtMinFill);
        if (!MpcCore.decrypt(meetsMinimum)) {
            revert FillBelowMinimum();
        }
    }

    /**
     * @notice Permanently remove upgrade capability (one-way, irreversible)
     * @dev Can only be called by admin (through timelock). Once ossified,
     *      the contract can never be upgraded again.
     */
    function ossify() external onlyRole(ADMIN_ROLE) {
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

    /**
     * @notice Authorize contract upgrades (UUPS pattern)
     * @dev Only admin can authorize upgrades to new implementation.
     *      Reverts if contract is ossified.
     * @param newImplementation Address of new implementation contract
     */
    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyRole(ADMIN_ROLE)
    {
        if (_ossified) revert ContractIsOssified();
    }
}
