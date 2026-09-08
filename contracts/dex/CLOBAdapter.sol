// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/* solhint-disable import-path-check */
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ISwapAdapter} from "./OmniSwapRouter.sol";
/* solhint-enable import-path-check */

/**
 * @title CLOBAdapter
 * @author OmniCoin Development Team
 * @notice Implements {ISwapAdapter} for OmniSwapRouter, routing swaps
 *         through the Central Limit Order Book (DEXSettlement). Maker
 *         orders are deposited by the owner (validator) and consumed
 *         when the router requests a swap.
 *
 * Architecture:
 *   1. Owner deposits pre-signed maker orders into the inventory.
 *   2. OmniSwapRouter calls `executeSwap()` when CLOB is the best route.
 *   3. Adapter builds a taker order (itself as taker), calls
 *      DEXSettlement.settleTrade(), and forwards output to recipient.
 *   4. Expired orders can be cleared by anyone.
 *
 * @dev This adapter only lives on the home chain (88008) initially.
 *      It does NOT support partial fills for simplicity — it matches
 *      the smallest of (amountIn, bestMaker.amountIn) per swap.
 */
contract CLOBAdapter is ISwapAdapter, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ================================================================
    // TYPES
    // ================================================================

    /**
     * @notice Mirrors DEXSettlement.Order for inventory storage.
     *         Using a local struct avoids cross-pragma import issues.
     */
    struct Order {
        /** Trader (maker) address */
        address trader;
        /** True if buy order */
        bool isBuy;
        /** Token address being sold */
        address tokenIn;
        /** Token address being bought */
        address tokenOut;
        /** Amount of tokenIn */
        uint256 amountIn;
        /** Amount of tokenOut */
        uint256 amountOut;
        /** Price in basis points */
        uint256 price;
        /** Expiry timestamp */
        uint256 deadline;
        /** Random salt */
        bytes32 salt;
        /** Matching validator address */
        address matchingValidator;
        /** Nonce for replay protection */
        uint256 nonce;
        /** Referrer address */
        address referrer;
        /** Second-level referrer address */
        address referrer2;
    }

    /**
     * @notice Deposited order with its EIP-712 signature
     */
    struct InventoryItem {
        /** The maker order (signed; NEVER mutated after deposit) */
        Order order;
        /** EIP-712 signature over `order` */
        bytes signature;
        /**
         * Remaining unfilled amounts, tracked separately so the signed
         * `order` (and its signature) stays intact across partial fills.
         * DEXSettlement tracks cumulative fill against the ORIGINAL order
         * hash, so reducing `order.amountIn/amountOut` would change the
         * digest and invalidate the maker signature on the next fill.
         */
        uint256 remainingIn;
        uint256 remainingOut;
    }

    // ================================================================
    // STATE
    // ================================================================

    /// @notice OmniSwapRouter address (only caller for executeSwap)
    address public immutable router;

    /// @notice DEXSettlement contract address
    address public immutable dexSettlement;

    /// @notice Inventory of deposited maker orders by pair hash
    /// @dev Key: keccak256(abi.encodePacked(tokenIn, tokenOut))
    mapping(bytes32 => InventoryItem[]) public inventory;

    /// @notice Number of items in inventory for a pair
    mapping(bytes32 => uint256) public inventoryCount;

    /// @notice Auto-incrementing nonce for adapter taker orders.
    /// @dev DEXSettlement marks nonces as consumed after full fills.
    ///      Each executeSwap must use a unique nonce to prevent
    ///      NonceAlreadyUsed reverts on subsequent trades.
    uint256 public nextTakerNonce;

    /// @notice Maximum iterations for _findBestOrder. Must be >=
    ///         MAX_INVENTORY_PER_PAIR so every deposited order is
    ///         selectable (otherwise the best-priced order could sit in
    ///         the unscanned tail of a full pair).
    uint256 public constant MAX_ITERATIONS = 100;

    /// @notice Maximum maker orders kept per pair. Bounds the gas of
    ///          clearExpiredOrders and _findBestOrder against deposit
    ///          flooding (M-09).
    uint256 public constant MAX_INVENTORY_PER_PAIR = 100;

    /// @notice Minimum fill threshold, in basis points of the requested
    ///         `amountIn`. Orders that can fill less than this fraction
    ///         are skipped by `_findBestOrder` so a dust order cannot
    ///         shadow larger orders (RT-04).
    uint256 public constant MIN_FILL_BPS = 100; // 1%

    /// @notice Tokens excluded from rescue (active trading inventory)
    mapping(address => bool) public excludedFromRescue;

    // ================================================================
    // EVENTS
    // ================================================================

    /**
     * @notice Emitted when a maker order is deposited
     * @param pairHash Pair identifier
     * @param trader Maker address
     * @param amountIn Order input amount
     */
    event OrderDeposited(
        bytes32 indexed pairHash,
        address indexed trader,
        uint256 indexed amountIn
    );

    /**
     * @notice Emitted when expired orders are cleared
     * @param pairHash Pair identifier
     * @param cleared Number of orders removed
     */
    event ExpiredOrdersCleared(
        bytes32 indexed pairHash,
        uint256 indexed cleared
    );

    /**
     * @notice Emitted when the owner removes a specific deposited order
     * @param pairHash Pair identifier
     * @param index Index of the removed order within the pair inventory
     */
    event OrderRemoved(
        bytes32 indexed pairHash,
        uint256 indexed index
    );

    /**
     * @notice Emitted when tokens are rescued
     * @param token Token address
     * @param to Recipient address
     * @param amount Amount rescued
     */
    event TokensRescued(
        address indexed token,
        address indexed to,
        uint256 indexed amount
    );

    /**
     * @notice Emitted when a token's rescue exclusion status changes
     * @param token Token address
     * @param excluded New exclusion status
     */
    event RescueExclusionUpdated(
        address indexed token,
        bool indexed excluded
    );

    // ================================================================
    // ERRORS
    // ================================================================

    /// @notice Caller is not the router
    error OnlyRouter();

    /// @notice No matching order found in inventory
    error NoMatchingOrder();

    /// @notice DEXSettlement call failed
    error SettlementFailed();

    /// @notice Zero address provided
    error ZeroAddress();

    /// @notice Output below minimum (slippage)
    error SlippageExceeded();

    /// @notice Token is excluded from rescue (active inventory)
    error TokenExcludedFromRescue();

    /// @notice Invalid order parameters
    error InvalidOrder();
    /// @dev Thrown when a pair already holds MAX_INVENTORY_PER_PAIR orders.
    error InventoryFull();

    // ================================================================
    // CONSTRUCTOR
    // ================================================================

    /**
     * @notice Deploy the CLOB adapter
     * @param router_ OmniSwapRouter address
     * @param dexSettlement_ DEXSettlement address
     * @param owner_ Owner address (validator)
     */
    constructor(
        address router_,
        address dexSettlement_,
        address owner_
    ) Ownable(owner_) {
        if (router_ == address(0) || dexSettlement_ == address(0)
            || owner_ == address(0)) {
            revert ZeroAddress();
        }
        router = router_;
        dexSettlement = dexSettlement_;
    }

    // ================================================================
    // ISwapAdapter — EXECUTION
    // ================================================================

    /**
     * @notice Execute a swap through the CLOB
     * @param tokenIn Input token address
     * @param tokenOut Output token address
     * @param amountIn Amount of input tokens
     * @param minAmountOut Minimum acceptable output amount (slippage)
     * @param recipient Recipient of output tokens
     * @return amountOut Amount of output tokens received
     * @dev Only callable by the OmniSwapRouter. Finds the best-priced
     *      maker order in inventory, settles via DEXSettlement, and
     *      forwards output to the recipient.
     */
    function executeSwap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient
    ) external override nonReentrant returns (uint256 amountOut) {
        if (msg.sender != router) revert OnlyRouter();

        // The maker order's tokenIn is our tokenOut (and vice versa)
        bytes32 ph = keccak256(
            abi.encodePacked(tokenOut, tokenIn)
        );
        InventoryItem[] storage items = inventory[ph];

        // Find best price order that can fill
        uint256 bestIdx;
        {
            bool found;
            (bestIdx, found) = _findBestOrder(items, amountIn);
            if (!found) revert NoMatchingOrder();
        }

        InventoryItem storage best = items[bestIdx];

        // Compute fill amounts from the REMAINING inventory, but settle
        // against the ORIGINAL signed order. The signed `order` is never
        // mutated: DEXSettlement tracks cumulative fill against the
        // original order hash, so reducing `order.amountIn/amountOut`
        // would change the digest and invalidate the maker signature on
        // the next fill (D-01).
        uint256 takerFill = best.remainingOut < amountIn
            ? best.remainingOut
            : amountIn;
        uint256 makerFill = (takerFill * best.order.amountIn)
            / best.order.amountOut;

        // H-01: Enforce minimum output (slippage protection)
        if (makerFill < minAmountOut) revert SlippageExceeded();

        // Snapshot tokenOut balance before settlement
        uint256 balanceBefore = IERC20(tokenOut).balanceOf(
            address(this)
        );

        // Snapshot the matched item (original order + signature) before
        // any state changes.
        InventoryItem memory bestItem = best;

        // M-04/RT-02: CEI — update remaining BEFORE external calls.
        // If settlement reverts the entire tx reverts, so state remains
        // consistent. Removing the item when its remaining output is
        // fully consumed keeps the inventory from filling with dust.
        if (takerFill == best.remainingOut) {
            _removeInventoryItem(items, bestIdx);
        } else {
            best.remainingIn -= makerFill;
            best.remainingOut -= takerFill;
        }
        inventoryCount[ph] = items.length;

        // Execute settlement via internal helper (reduces stack)
        _callSettlement(
            tokenIn, tokenOut, amountIn, bestItem,
            makerFill, takerFill
        );

        // Compute actual output received (delta, not full balance)
        amountOut = IERC20(tokenOut).balanceOf(address(this))
            - balanceBefore;

        // Forward output to recipient
        if (amountOut > 0) {
            IERC20(tokenOut).safeTransfer(recipient, amountOut);
        }

        return amountOut;
    }

    /**
     * @notice Internal: transfer tokens, approve, and call DEXSettlement
     * @param tokenIn Taker input token
     * @param tokenOut Taker output token
     * @param amountIn Amount of input tokens
     * @param best The matched inventory item
     * @param makerFill Portion of maker.tokenIn consumed in this fill
     * @param takerFill Portion of taker.tokenIn consumed in this fill
     * @dev Extracted to reduce stack depth in executeSwap. Reverts
     *      with the DEXSettlement revert reason if settlement fails.
     */
    function _callSettlement(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        InventoryItem memory best,
        uint256 makerFill,
        uint256 takerFill
    ) internal {
        // Transfer input tokens from router to this contract
        IERC20(tokenIn).safeTransferFrom(
            msg.sender, address(this), amountIn
        );

        // Approve DEXSettlement to spend our tokens
        IERC20(tokenIn).forceApprove(dexSettlement, amountIn);

        // Encode settleTrade call manually (cross-pragma)
        bytes memory callData = abi.encodeWithSignature(
            "settleTrade("
            "(address,bool,address,address,uint256,uint256,"
            "uint256,uint256,bytes32,address,uint256,"
            "address,address),"
            "(address,bool,address,address,uint256,uint256,"
            "uint256,uint256,bytes32,address,uint256,"
            "address,address),"
            "uint256,uint256,bytes,bytes)",
            best.order,
            _buildTakerOrder(
                tokenIn, tokenOut, amountIn, best.order
            ),
            makerFill,
            takerFill,
            best.signature,
            "" // Adapter is authorized — no taker signature
        );

        // solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory ret) =
            dexSettlement.call(callData);
        if (!success) {
            // Bubble up DEXSettlement revert reason if available
            if (ret.length > 0) {
                // solhint-disable-next-line no-inline-assembly
                assembly {
                    revert(add(ret, 32), mload(ret))
                }
            }
            revert SettlementFailed();
        }

        // Settlement only consumes `takerFill` of the approved `amountIn`
        // when the matched maker order is smaller than the swap. Reset the
        // residual allowance to zero and refund the unconsumed input to the
        // caller — leaving a standing approval plus stranded tokenIn let a
        // third party drive an adapter-taker settlement (the adapter is an
        // authorized adapter whose taker signature is skipped) and drain it.
        IERC20(tokenIn).forceApprove(dexSettlement, 0);
        uint256 residual = IERC20(tokenIn).balanceOf(address(this));
        if (residual > 0) {
            IERC20(tokenIn).safeTransfer(msg.sender, residual);
        }
    }

    // ================================================================
    // ISwapAdapter — QUOTE
    // ================================================================

    /**
     * @notice Estimate output for a CLOB swap
     * @param tokenIn Input token address
     * @param tokenOut Output token address
     * @param amountIn Amount of input tokens
     * @return amountOut Estimated output amount
     */
    function getAmountOut(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external view override returns (uint256 amountOut) {
        bytes32 ph = keccak256(
            abi.encodePacked(tokenOut, tokenIn)
        );
        InventoryItem[] storage items = inventory[ph];

        (uint256 bestIdx, bool found) = _findBestOrder(
            items, amountIn
        );
        if (!found) return 0;

        InventoryItem storage best = items[bestIdx];
        // Taker's amountIn matches the maker's remaining amountOut
        // (same token). Quote against the original signed rate.
        uint256 takerFill = best.remainingOut < amountIn
            ? best.remainingOut
            : amountIn;
        amountOut = (takerFill * best.order.amountIn)
            / best.order.amountOut;
    }

    // ================================================================
    // OWNER — INVENTORY MANAGEMENT
    // ================================================================

    /**
     * @notice Deposit a pre-signed maker order into inventory
     * @param order The maker order
     * @param signature EIP-712 signature of the order
     */
    function depositMakerOrder(
        Order calldata order,
        bytes calldata signature
    ) external onlyOwner {
        // M-02: Validate order parameters
        // solhint-disable-next-line not-rely-on-time
        if (order.amountIn == 0 || order.amountOut == 0
            || order.deadline <= block.timestamp) {
            revert InvalidOrder();
        }

        bytes32 ph = keccak256(
            abi.encodePacked(order.tokenIn, order.tokenOut)
        );
        // M-09: Cap per-pair inventory so clearExpiredOrders and
        // _findBestOrder stay gas-bounded even under deposit flooding.
        if (inventory[ph].length >= MAX_INVENTORY_PER_PAIR) {
            revert InventoryFull();
        }
        inventory[ph].push(InventoryItem({
            order: order,
            signature: signature,
            remainingIn: order.amountIn,
            remainingOut: order.amountOut
        }));
        inventoryCount[ph] = inventory[ph].length;

        emit OrderDeposited(ph, order.trader, order.amountIn);
    }

    /**
     * @notice Remove a specific deposited maker order from inventory
     * @param tokenIn Maker's tokenIn
     * @param tokenOut Maker's tokenOut
     * @param index Index of the order within the pair's inventory
     * @dev Lets the owner remove a bad order (e.g. one whose signature no
     *      longer verifies, or a wrong matchingValidator) before its expiry
     *      instead of waiting for {clearExpiredOrders} (RT-EC-02). A bad
     *      order left in inventory is selected by {_findBestOrder} and then
     *      reverts the whole settlement, blocking the pair until it expires.
     */
    function removeMakerOrder(
        address tokenIn,
        address tokenOut,
        uint256 index
    ) external onlyOwner {
        bytes32 ph = keccak256(
            abi.encodePacked(tokenIn, tokenOut)
        );
        InventoryItem[] storage items = inventory[ph];
        if (index >= items.length) revert InvalidOrder();

        _removeInventoryItem(items, index);
        inventoryCount[ph] = items.length;

        emit OrderRemoved(ph, index);
    }

    /**
     * @notice Clear expired orders from inventory for a pair
     * @param tokenIn Maker's tokenIn
     * @param tokenOut Maker's tokenOut
     */
    function clearExpiredOrders(
        address tokenIn,
        address tokenOut
    ) external nonReentrant {
        bytes32 ph = keccak256(
            abi.encodePacked(tokenIn, tokenOut)
        );
        InventoryItem[] storage items = inventory[ph];
        uint256 cleared;
        uint256 i;

        while (i < items.length) {
            // solhint-disable-next-line not-rely-on-time
            if (block.timestamp > items[i].order.deadline) {
                _removeInventoryItem(items, i);
                ++cleared;
                // Don't increment i — swap puts last item at i
            } else {
                ++i;
            }
        }

        inventoryCount[ph] = items.length;
        if (cleared > 0) {
            emit ExpiredOrdersCleared(ph, cleared);
        }
    }

    /**
     * @notice Rescue stuck tokens (safety valve)
     * @param token Token address
     * @param to Recipient
     * @param amount Amount to rescue
     * @dev Tokens in the rescue exclusion list (active trading inventory)
     *      cannot be rescued to prevent draining legitimately held tokens.
     */
    function rescueTokens(
        address token,
        address to,
        uint256 amount
    ) external onlyOwner {
        if (excludedFromRescue[token]) {
            revert TokenExcludedFromRescue();
        }
        IERC20(token).safeTransfer(to, amount);
        emit TokensRescued(token, to, amount);
    }

    /**
     * @notice Set rescue exclusion status for a token
     * @param token Token address
     * @param excluded True to prevent rescue, false to allow
     * @dev Owner should exclude tokens that are part of active
     *      trading inventory to prevent accidental draining.
     */
    function setRescueExclusion(
        address token,
        bool excluded
    ) external onlyOwner {
        excludedFromRescue[token] = excluded;
        emit RescueExclusionUpdated(token, excluded);
    }

    // ================================================================
    // INTERNAL
    // ================================================================

    /**
     * @notice Find the best-priced non-expired order in inventory
     * @param items Inventory items for the pair
     * @return bestIdx Index of the best order
     * @return found True if a matching order exists
     */
    function _findBestOrder(
        InventoryItem[] storage items,
        uint256 amountIn
    ) internal view returns (uint256 bestIdx, bool found) {
        // RT-01: priceRatio is received-per-paid from the taker's
        // perspective (maker's amountIn = taker's tokenOut, maker's
        // amountOut = taker's tokenIn), so the BEST order maximizes it.
        // The 2026-08 "fix" flipped the ratio but kept min-selection,
        // which still executed every multi-order pair at the worst price.
        uint256 bestPrice;
        uint256 len = items.length;
        // M-03: Bound iteration to prevent gas griefing
        uint256 maxIter = len < MAX_ITERATIONS ? len : MAX_ITERATIONS;
        // RT-04: skip orders that can fill less than a meaningful
        // portion of the request (1% via MIN_FILL_BPS). Without this,
        // a dust order at the best price would shadow a larger order
        // and produce a near-zero fill.
        uint256 minFill = (amountIn * MIN_FILL_BPS) / 10_000;

        for (uint256 i; i < maxIter; ++i) {
            InventoryItem storage it = items[i];
            Order storage o = it.order;
            // Skip expired
            // solhint-disable-next-line not-rely-on-time
            if (block.timestamp > o.deadline) continue;
            // M-01/D-01: Skip orders with no remaining amount — prevents
            // div-by-zero and matches only orders that can still fill.
            if (it.remainingIn == 0 || it.remainingOut == 0) continue;
            // RT-04: skip dust orders that cannot meaningfully fill
            if (it.remainingOut < minFill) continue;

            // RT-01: priceRatio is received-per-paid from the taker's
            // perspective (maker's amountIn = taker's tokenOut, maker's
            // amountOut = taker's tokenIn), so the BEST order maximizes
            // it. The rate is a property of the signed order.
            uint256 priceRatio = (o.amountIn * 1e18)
                / o.amountOut;
            if (!found || priceRatio > bestPrice) {
                bestPrice = priceRatio;
                bestIdx = i;
                found = true;
            }
        }
    }

    /**
     * @notice Remove an inventory item by swapping with last and popping
     * @param items Array to modify
     * @param idx Index to remove
     */
    function _removeInventoryItem(
        InventoryItem[] storage items,
        uint256 idx
    ) internal {
        uint256 lastIdx = items.length - 1;
        if (idx != lastIdx) {
            items[idx] = items[lastIdx];
        }
        items.pop();
    }

    /**
     * @notice Build a taker order for the adapter
     * @param tokenIn Taker's input token
     * @param tokenOut Taker's output token
     * @param amountIn Amount of input tokens
     * @param makerOrder The maker order being matched
     * @return takerOrder The constructed taker order
     */
    function _buildTakerOrder(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        Order memory makerOrder
    ) internal returns (Order memory takerOrder) {
        // Use auto-incrementing nonce to avoid NonceAlreadyUsed
        // reverts: DEXSettlement marks nonces as consumed after
        // each full fill, so every adapter trade must use a fresh
        // nonce. Post-increment ensures uniqueness.
        takerOrder = Order({
            trader: address(this),
            isBuy: !makerOrder.isBuy,
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            amountIn: amountIn,
            amountOut: (amountIn * makerOrder.amountIn)
                / makerOrder.amountOut,
            price: makerOrder.price,
            deadline: makerOrder.deadline,
            salt: keccak256(
                abi.encodePacked(
                    block.number, // solhint-disable-line not-rely-on-time
                    makerOrder.salt
                )
            ),
            matchingValidator: makerOrder.matchingValidator,
            nonce: nextTakerNonce++,
            referrer: address(0),
            referrer2: address(0)
        });
    }
}
