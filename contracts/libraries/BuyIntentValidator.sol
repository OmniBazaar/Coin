// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title BuyIntentValidator
 * @author OmniBazaar Team
 * @notice External library holding the stateless (and allowlist /
 *         expiry) validation primitives for UnifiedFeeVault's
 *         coin-agnostic buy intents — buyer/seller pair, token
 *         allowlist + amount + expiry, the H-01 referrer anti-fee-wash
 *         check, and the listing/selling node anti-fee-wash checks.
 * @dev Used by {PrioritySettlement} (and available to the vault) so the
 *      priority orchestration validates exactly like the plain-P2P /
 *      NFT flows without re-duplicating the logic. Linked via
 *      DELEGATECALL: the two storage mappings (`supportedPaymentTokens`,
 *      `perTokenMinSaleAmount`) are passed by reference so the allowlist
 *      + per-token-floor reads resolve to the vault's slots. Logic +
 *      custom-error selectors are byte-for-byte equivalent to the
 *      vault's inline `_validate*` helpers (the error definitions are
 *      duplicated here so the library can `revert` them; the 4-byte
 *      selector is identical to the vault's, which still declares them).
 */
library BuyIntentValidator {
    /// @notice Buyer equals seller
    error SelfBuy();

    /// @notice A required address argument was zero
    error ZeroAddress();

    /// @notice A required amount argument was zero
    error ZeroAmount();

    /// @notice `paymentToken` or `receiveToken` is not allowlisted
    /// @param token The offending token address
    error UnsupportedToken(address token);

    /// @notice `minReceiveAmount` is below the per-token dust floor
    error SaleAmountTooSmall();

    /// @notice Intent has expired (`block.timestamp >= expiresAt`)
    error Expired();

    /// @notice A referrer slot collides with buyer / seller / referrer
    error BadReferrer();

    /// @notice `listingNode` collides with buyer / referrer / referrer2
    ///         / sellingNode
    error BadListingNode();

    /// @notice `sellingNode` collides with buyer / seller / referrer /
    ///         referrer2
    error BadSellingNode();

    /**
     * @notice Allowlist + amount + expiry invariants
     * @dev Reverts `UnsupportedToken` / `ZeroAmount` /
     *      `SaleAmountTooSmall` / `Expired`. Reads the vault's allowlist
     *      + per-token floor via the passed storage mappings.
     * @param paymentToken Token the buyer pays
     * @param receiveToken Token the seller receives
     * @param paymentAmount Buyer's pay amount
     * @param minReceiveAmount Seller's minimum receive (net of fee)
     * @param expiresAt Intent expiry (Unix timestamp)
     * @param supportedPaymentTokens Vault's allowlist mapping (ref).
     * @param perTokenMinSaleAmount Vault's per-token floor mapping (ref).
     */
    // solhint-disable-next-line code-complexity
    function validateTokensAmountsExpiry(
        address paymentToken,
        address receiveToken,
        uint256 paymentAmount,
        uint256 minReceiveAmount,
        uint256 expiresAt,
        mapping(address => bool) storage supportedPaymentTokens,
        mapping(address => uint256) storage perTokenMinSaleAmount
    ) external view {
        if (!supportedPaymentTokens[paymentToken]) {
            revert UnsupportedToken(paymentToken);
        }
        if (!supportedPaymentTokens[receiveToken]) {
            revert UnsupportedToken(receiveToken);
        }
        if (paymentAmount == 0) revert ZeroAmount();
        if (minReceiveAmount == 0) revert ZeroAmount();
        if (minReceiveAmount < perTokenMinSaleAmount[receiveToken]) {
            revert SaleAmountTooSmall();
        }
        // solhint-disable-next-line not-rely-on-time, gas-strict-inequalities
        if (block.timestamp >= expiresAt) revert Expired();
    }

    /**
     * @notice Buyer / seller address invariants
     * @dev Reverts `SelfBuy` if equal, `ZeroAddress` if either is zero.
     * @param buyer Intent buyer
     * @param seller Intent seller
     */
    function validateBuyerSellerPair(
        address buyer,
        address seller
    ) external pure {
        if (buyer == seller) revert SelfBuy();
        if (buyer == address(0)) revert ZeroAddress();
        if (seller == address(0)) revert ZeroAddress();
    }

    /**
     * @notice H-01 two-slot referrer anti-fee-wash check
     * @dev Reverts `BadReferrer` on any collision with buyer / seller,
     *      or `referrer2 == referrer` (both non-zero).
     * @param buyer Intent buyer
     * @param seller Intent seller
     * @param referrer Primary referrer (zero routes to ODDAO)
     * @param referrer2 Secondary referrer (zero routes to ODDAO)
     */
    // solhint-disable-next-line code-complexity
    function validateReferrerPair(
        address buyer,
        address seller,
        address referrer,
        address referrer2
    ) external pure {
        if (referrer != address(0)) {
            if (referrer == buyer) revert BadReferrer();
            if (referrer == seller) revert BadReferrer();
        }
        if (referrer2 != address(0)) {
            if (referrer2 == buyer) revert BadReferrer();
            if (referrer2 == seller) revert BadReferrer();
            if (referrer2 == referrer) revert BadReferrer();
        }
    }

    /**
     * @notice Listing/selling node anti-fee-wash checks
     * @dev A non-zero `listingNode` may equal the seller (merchant runs
     *      own node) but not buyer / referrer / referrer2 / sellingNode;
     *      a non-zero `sellingNode` may not equal buyer / seller /
     *      referrer / referrer2. Reverts `BadListingNode` /
     *      `BadSellingNode`.
     * @param buyer Intent buyer
     * @param seller Intent seller
     * @param referrer Primary referrer
     * @param referrer2 Secondary referrer
     * @param listingNode Listing-node fee recipient (zero allowed)
     * @param sellingNode Selling-node fee recipient (zero allowed)
     */
    function validateNodes(
        address buyer,
        address seller,
        address referrer,
        address referrer2,
        address listingNode,
        address sellingNode
    ) external pure {
        _validateListingNode(
            buyer, referrer, referrer2, listingNode, sellingNode
        );
        _validateSellingNode(
            buyer, seller, referrer, referrer2, sellingNode
        );
    }

    /**
     * @notice Listing-node slot of the node anti-fee-wash check
     * @dev Reverts `BadListingNode` if a non-zero `listingNode` collides
     *      with buyer / referrer / referrer2 / sellingNode (the seller
     *      collision is intentionally allowed — merchant runs own node).
     * @param buyer Intent buyer
     * @param referrer Primary referrer
     * @param referrer2 Secondary referrer
     * @param listingNode Listing-node fee recipient (zero allowed)
     * @param sellingNode Selling-node fee recipient (for the !=  check)
     */
    function _validateListingNode(
        address buyer,
        address referrer,
        address referrer2,
        address listingNode,
        address sellingNode
    ) private pure {
        if (listingNode == address(0)) return;
        if (listingNode == buyer) revert BadListingNode();
        if (listingNode == referrer) revert BadListingNode();
        if (listingNode == referrer2) revert BadListingNode();
        if (listingNode == sellingNode) revert BadListingNode();
    }

    /**
     * @notice Selling-node slot of the node anti-fee-wash check
     * @dev Reverts `BadSellingNode` if a non-zero `sellingNode` collides
     *      with buyer / seller / referrer / referrer2.
     * @param buyer Intent buyer
     * @param seller Intent seller
     * @param referrer Primary referrer
     * @param referrer2 Secondary referrer
     * @param sellingNode Selling-node fee recipient (zero allowed)
     */
    function _validateSellingNode(
        address buyer,
        address seller,
        address referrer,
        address referrer2,
        address sellingNode
    ) private pure {
        if (sellingNode == address(0)) return;
        if (sellingNode == buyer) revert BadSellingNode();
        if (sellingNode == seller) revert BadSellingNode();
        if (sellingNode == referrer) revert BadSellingNode();
        if (sellingNode == referrer2) revert BadSellingNode();
    }
}
