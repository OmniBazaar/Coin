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
    // CONSTANTS
    // ========================================================================

    /// @notice Role identifier for order matchers
    bytes32 public constant MATCHER_ROLE = keccak256("MATCHER_ROLE");

    /// @notice Role identifier for admin operations
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /// @notice Maximum orders per user to prevent spam
    uint256 public constant MAX_ORDERS_PER_USER = 100;

    // ========================================================================
    // ENUMS
    // ========================================================================

    /// @notice Order status enumeration
    enum OrderStatus {
        OPEN,              // Order is active and can be matched
        PARTIALLY_FILLED,  // Order is partially executed
        FILLED,            // Order is completely filled
        CANCELLED          // Order was cancelled by user
    }

    // ========================================================================
    // STRUCTS
    // ========================================================================

    /**
     * @notice Private order structure with encrypted fields
     * @dev Amount and price are encrypted using COTI V2 MPC
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
    }

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

    /**
     * @dev Storage gap for future upgrades
     * @notice Reserves storage slots for adding new variables without breaking upgradeability
     * Current storage: 5 variables (orders, orderIds, userOrders, totalOrders, totalTrades)
     * Gap size: 50 - 5 = 45 slots reserved
     */
    uint256[45] private __gap;

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
    // UUPS UPGRADE AUTHORIZATION
    // ========================================================================

    /**
     * @notice Authorize contract upgrades (UUPS pattern)
     * @dev Only admin can authorize upgrades to new implementation
     * @param newImplementation Address of new implementation contract
     */
    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyRole(ADMIN_ROLE)
    {
        // Authorization check handled by onlyRole modifier
        // newImplementation parameter required by UUPS but not used in authorization logic
    }

    // ========================================================================
    // ORDER SUBMISSION
    // ========================================================================

    /**
     * @notice Submit a private order with encrypted amount and price
     * @dev Amount and price remain encrypted throughout matching process
     * @param isBuy Whether this is a buy order
     * @param pair Trading pair symbol (e.g., "pXOM-USDC")
     * @param encAmount Encrypted order amount (ctUint64)
     * @param encPrice Encrypted limit price (ctUint64)
     * @return orderId Unique order identifier
     */
    function submitPrivateOrder(
        bool isBuy,
        string calldata pair,
        ctUint64 encAmount,
        ctUint64 encPrice
    ) external whenNotPaused nonReentrant returns (bytes32 orderId) {
        if (bytes(pair).length == 0) revert InvalidPair();
        if (userOrders[msg.sender].length >= MAX_ORDERS_PER_USER) revert TooManyOrders();

        // Generate unique order ID
        orderId = keccak256(abi.encodePacked(
            msg.sender,
            pair,
            block.timestamp,
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
            timestamp: block.timestamp,
            status: OrderStatus.OPEN,
            encFilled: encZero
        });

        // Track order
        orderIds.push(orderId);
        userOrders[msg.sender].push(orderId);
        ++totalOrders;

        emit PrivateOrderSubmitted(orderId, msg.sender, pair);
        return orderId;
    }

    // ========================================================================
    // ORDER MATCHING (MPC OPERATIONS)
    // ========================================================================

    /**
     * @notice Check if two orders can match using MPC price comparison
     * @dev Uses MPC ge() and decrypt() which modify state, cannot be view
     * @param buyOrderId Buy order ID
     * @param sellOrderId Sell order ID
     * @return canMatch Whether orders can match (true if buy price >= sell price)
     */
    function canOrdersMatch(
        bytes32 buyOrderId,
        bytes32 sellOrderId
    ) external returns (bool canMatch) {
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
     * @dev Uses MPC operations which modify state, cannot be view
     * @param buyOrderId Buy order ID
     * @param sellOrderId Sell order ID
     * @return encMatchAmount Encrypted match amount (ctUint64)
     */
    function calculateMatchAmount(
        bytes32 buyOrderId,
        bytes32 sellOrderId
    ) external returns (ctUint64 encMatchAmount) {
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
    function executePrivateTrade(
        bytes32 buyOrderId,
        bytes32 sellOrderId,
        ctUint64 encMatchAmount
    ) external onlyRole(MATCHER_ROLE) whenNotPaused nonReentrant returns (bytes32 tradeId) {
        PrivateOrder storage buyOrder = orders[buyOrderId];
        PrivateOrder storage sellOrder = orders[sellOrderId];

        if (buyOrder.trader == address(0) || sellOrder.trader == address(0)) {
            revert OrderNotFound();
        }

        // Update buy order filled amount: filled += matchAmount
        gtUint64 gtBuyFilled = MpcCore.onBoard(buyOrder.encFilled);
        gtUint64 gtMatchAmount = MpcCore.onBoard(encMatchAmount);
        gtUint64 gtNewBuyFilled = MpcCore.add(gtBuyFilled, gtMatchAmount);
        buyOrder.encFilled = MpcCore.offBoard(gtNewBuyFilled);

        // Update sell order filled amount: filled += matchAmount
        gtUint64 gtSellFilled = MpcCore.onBoard(sellOrder.encFilled);
        gtUint64 gtNewSellFilled = MpcCore.add(gtSellFilled, gtMatchAmount);
        sellOrder.encFilled = MpcCore.offBoard(gtNewSellFilled);

        // Check if buy order is fully filled: filled == amount
        OrderStatus oldBuyStatus = buyOrder.status;
        gtUint64 gtBuyAmount = MpcCore.onBoard(buyOrder.encAmount);
        gtBool buyFullyFilled = MpcCore.eq(gtNewBuyFilled, gtBuyAmount);
        if (MpcCore.decrypt(buyFullyFilled)) {
            buyOrder.status = OrderStatus.FILLED;
        } else {
            buyOrder.status = OrderStatus.PARTIALLY_FILLED;
        }
        if (buyOrder.status != oldBuyStatus) {
            emit OrderStatusChanged(buyOrderId, oldBuyStatus, buyOrder.status);
        }

        // Check if sell order is fully filled: filled == amount
        OrderStatus oldSellStatus = sellOrder.status;
        gtUint64 gtSellAmount = MpcCore.onBoard(sellOrder.encAmount);
        gtBool sellFullyFilled = MpcCore.eq(gtNewSellFilled, gtSellAmount);
        if (MpcCore.decrypt(sellFullyFilled)) {
            sellOrder.status = OrderStatus.FILLED;
        } else {
            sellOrder.status = OrderStatus.PARTIALLY_FILLED;
        }
        if (sellOrder.status != oldSellStatus) {
            emit OrderStatusChanged(sellOrderId, oldSellStatus, sellOrder.status);
        }

        // Generate trade ID
        ++totalTrades;
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

        emit OrderStatusChanged(orderId, oldStatus, OrderStatus.CANCELLED);
        emit PrivateOrderCancelled(orderId, msg.sender);
    }

    // ========================================================================
    // QUERY FUNCTIONS
    // ========================================================================

    /**
     * @notice Get encrypted order details
     * @dev Anyone can query, but only trader can decrypt amounts
     * @param orderId Order ID to query
     * @return order Private order struct (includes encrypted amounts)
     */
    function getPrivateOrder(bytes32 orderId) external view returns (PrivateOrder memory order) {
        if (orders[orderId].trader == address(0)) revert OrderNotFound();
        return orders[orderId];
    }

    /**
     * @notice Get user's private order IDs
     * @param trader Trader address
     * @return orderList Array of order IDs
     */
    function getUserOrders(address trader) external view returns (bytes32[] memory orderList) {
        return userOrders[trader];
    }

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
    function getOrderBook(string calldata pair, uint256 maxOrders)
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
    // ADMIN FUNCTIONS
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
        if (matcher == address(0)) revert InvalidAmount();
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
}
