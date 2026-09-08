// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from
    "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SwapExecutor} from "./SwapExecutor.sol";
import {RoyaltyResolver} from "./RoyaltyResolver.sol";
import {MarketplaceFeeSplitter} from "./MarketplaceFeeSplitter.sol";

/**
 * @title CoinAgnosticSettlement
 * @author OmniBazaar Team
 * @notice External library holding UnifiedFeeVault's coin-agnostic
 *         "pull → (swap) → 1% fee + optional priority surcharge → pay
 *         seller" settlement primitive.
 * @dev Extracted from `UnifiedFeeVault._settleCoinAgnosticBuy` PURELY to
 *      reclaim deployed bytecode so the vault stays under the 24 KiB
 *      Spurious Dragon (EIP-170) limit after the sale-time
 *      priority-surcharge feature. Linked via DELEGATECALL: it runs in
 *      the vault's storage context, so the buyer-pull, swap, royalty,
 *      fee distribution, and seller payout all touch the vault's own
 *      balance + slots. It calls the already-extracted {SwapExecutor},
 *      {RoyaltyResolver}, and {MarketplaceFeeSplitter} libraries
 *      (themselves DELEGATECALL-linked, executing in the same vault
 *      context). Observable behaviour is byte-for-byte identical to the
 *      prior in-vault implementation:
 *        - Non-priority callers pass `priorityFeeBps == 0`, so the swap
 *          gross-up denominator stays `9_900`, `surcharge == 0`,
 *          `sellerPay == receiveGross - fee`, and the
 *          `distributePriority` call is skipped — `settleP2PBuy` /
 *          `settleNftBuy` accounting is unchanged.
 *        - The vault adds the returned `feesCollectedDelta`
 *          (`fee + surcharge`) to its `totalFeesCollected` exactly as
 *          the prior inline `_distributeMarketplaceFee` did.
 */
library CoinAgnosticSettlement {
    using SafeERC20 for IERC20;

    /// @notice Fee recipients + surcharge rate threaded into settlement
    /// @param referrer Primary referrer (zero routes to ODDAO)
    /// @param referrer2 Secondary referrer (zero routes to ODDAO)
    /// @param listingNode Listing node (zero routes to ODDAO)
    /// @param sellingNode Selling node (zero routes to ODDAO)
    /// @param priorityFeeBps Priority surcharge in bps (0 = none)
    struct FeeRecipients {
        address referrer;
        address referrer2;
        address listingNode;
        address sellingNode;
        uint256 priorityFeeBps;
    }

    /// @notice Buyer/seller + token + amount + swap-deadline scalars
    /// @dev Grouped to keep `settle`'s parameter list readable. Built by
    ///      the vault's single `_settleCoinAgnosticBuy` wrapper (one site).
    /// @param buyer Address debited in `paymentToken`
    /// @param seller Address credited in `receiveToken`
    /// @param paymentToken Token the buyer pays
    /// @param paymentAmount Exact `paymentToken` amount pulled
    /// @param receiveToken Token the seller receives
    /// @param minReceiveAmount Minimum `receiveToken` net of fee
    /// @param deadline Swap deadline (`intent.expiresAt`)
    /// @param royaltyNftContract NFT collection for EIP-2981 royalty, or
    ///        zero to skip royalty handling (the P2P / goods path)
    /// @param royaltyTokenId Token id passed to `royaltyInfo`
    struct SettleParams {
        address buyer;
        address seller;
        address paymentToken;
        uint256 paymentAmount;
        address receiveToken;
        uint256 minReceiveAmount;
        uint256 deadline;
        address royaltyNftContract;
        uint256 royaltyTokenId;
    }

    /// @notice Basis-points denominator for the surcharge math
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    /// @notice A non-standard token (fee-on-transfer / rebasing) was
    ///         detected via a buyer-side balance-delta mismatch.
    error FeeOnTransferToken();

    /// @notice The swap router was required but is unconfigured.
    error NftSwapRouterNotSet();

    /// @notice `receiveGross / 100` rounded to zero (sale too small).
    error SaleAmountTooSmall();

    /// @notice Final `sellerPay` is below `minReceiveAmount`.
    error SlippageExceeded();

    /**
     * @notice Execute the coin-agnostic settlement pipeline
     * @dev Caller (vault) is responsible for signature verification,
     *      replay marking, swap-path commitment, and emitting the
     *      flow-specific event; this primitive owns pull → swap → fee +
     *      surcharge → royalty → seller payout.
     * @param nftSwapRouter Vault's `nftSwapRouter` (read by the caller).
     * @param stakingPool Vault's staking-pool fee recipient.
     * @param protocolTreasury Vault's protocol-treasury fee recipient.
     * @param p Receive-token + buyer/seller settlement parameters.
     * @param r Fee recipients + priority surcharge rate.
     * @param pendingBridge Vault's `pendingBridge` mapping (ref).
     * @param pendingClaims Vault's `pendingClaims` mapping (ref).
     * @param totalPendingClaims Vault's `totalPendingClaims` (ref).
     * @param totalDistributed Vault's `totalDistributed` (ref).
     * @param swapPath Router path matching the buyer's `swapPathHash`.
     * @param swapSources Router source IDs — one per hop.
     * @return receiveGross Gross amount received in `receiveToken`.
     * @return fee Marketplace fee (1% of `receiveGross`).
     * @return sellerPay Net amount transferred to `seller`.
     * @return feesCollectedDelta Amount to add to the vault's
     *         `totalFeesCollected` (`fee + surcharge`).
     */
    function settle(
        address nftSwapRouter,
        address stakingPool,
        address protocolTreasury,
        SettleParams calldata p,
        FeeRecipients calldata r,
        mapping(address => uint256) storage pendingBridge,
        mapping(address => mapping(address => uint256))
            storage pendingClaims,
        mapping(address => uint256) storage totalPendingClaims,
        mapping(address => uint256) storage totalDistributed,
        address[] calldata swapPath,
        bytes32[] calldata swapSources
    )
        external
        returns (
            uint256 receiveGross,
            uint256 fee,
            uint256 sellerPay,
            uint256 feesCollectedDelta
        )
    {
        receiveGross =
            _acquireReceiveGross(nftSwapRouter, p, r, swapPath, swapSources);

        // ─── Fee split + surcharge + seller pay ────────────────────
        fee = receiveGross / 100;
        if (fee == 0) revert SaleAmountTooSmall();
        // Sale-time priority-placement surcharge (0–300 bps of gross),
        // skimmed from the seller's proceeds on top of the 1% fee. Zero
        // is the normal (non-priority) case and never alters the payout.
        uint256 surcharge =
            (receiveGross * r.priorityFeeBps) / BPS_DENOMINATOR;
        // Overflow-safe: fee + surcharge <= 1% + 3% = 4% of receiveGross,
        // always strictly less than receiveGross.
        unchecked {
            sellerPay = receiveGross - fee - surcharge;
        }
        if (sellerPay < p.minReceiveAmount) revert SlippageExceeded();

        // N-ROY: honor any EIP-2981 creator royalty on the NFT path.
        // Senior to the seller's proceeds; clamped to `sellerPay`.
        // Skipped (no external call) when `royaltyNftContract == 0` (the
        // P2P / goods path), so P2P behaviour is provably unchanged.
        if (p.royaltyNftContract != address(0)) {
            sellerPay = RoyaltyResolver.resolveAndPay(
                p.receiveToken,
                p.royaltyNftContract,
                p.royaltyTokenId,
                receiveGross,
                sellerPay
            );
        }

        // Normal 1% fee distribution (9-way 70/20/10 split).
        MarketplaceFeeSplitter.distribute(
            p.receiveToken,
            fee,
            MarketplaceFeeSplitter.Recipients({
                referrer: r.referrer,
                referrerL2: r.referrer2,
                listingNode: r.listingNode,
                sellingNode: r.sellingNode
            }),
            pendingBridge,
            pendingClaims,
            totalPendingClaims,
            totalDistributed,
            stakingPool,
            protocolTreasury
        );
        feesCollectedDelta = fee;

        // Route the priority surcharge 70/20/10 listing/selling/ODDAO as
        // a SEPARATE call AFTER the normal distribution. Zero surcharge
        // (non-priority path) is a no-op, so accounting is unchanged.
        if (surcharge > 0) {
            MarketplaceFeeSplitter.distributePriority(
                p.receiveToken,
                surcharge,
                r.listingNode,
                r.sellingNode,
                pendingBridge,
                pendingClaims,
                totalPendingClaims,
                totalDistributed
            );
            feesCollectedDelta += surcharge;
        }

        IERC20(p.receiveToken).safeTransfer(p.seller, sellerPay);
    }

    /**
     * @notice Pull the buyer's payment and acquire the receive-side gross
     * @dev Buyer-side FoT balance-delta guard (M-01), then either the
     *      same-token fast path or the {SwapExecutor} hop with the
     *      priority-aware gross-up denominator (`9_900 - priorityFeeBps`).
     * @param nftSwapRouter Vault's `nftSwapRouter`.
     * @param p Settlement parameters.
     * @param r Fee recipients (for `priorityFeeBps`).
     * @param swapPath Router path.
     * @param swapSources Router source IDs.
     * @return receiveGross Gross `receiveToken` amount acquired.
     */
    function _acquireReceiveGross(
        address nftSwapRouter,
        SettleParams calldata p,
        FeeRecipients calldata r,
        address[] calldata swapPath,
        bytes32[] calldata swapSources
    ) private returns (uint256 receiveGross) {
        // ─── Pull payment from buyer (M-01 FoT balance-delta guard) ─
        uint256 balBefore =
            IERC20(p.paymentToken).balanceOf(address(this));
        // slither-disable-next-line arbitrary-send-erc20
        IERC20(p.paymentToken).safeTransferFrom(
            p.buyer, address(this), p.paymentAmount
        );
        if (
            IERC20(p.paymentToken).balanceOf(address(this))
                - balBefore
                != p.paymentAmount
        ) {
            revert FeeOnTransferToken();
        }

        // ─── Acquire the receive-side gross amount ────────────────
        if (p.paymentToken == p.receiveToken) {
            receiveGross = p.paymentAmount;
        } else {
            if (nftSwapRouter == address(0)) {
                revert NftSwapRouterNotSet();
            }
            // The gross-up denominator widens from `9_900` to
            // `9_900 - priorityFeeBps` so the seller still nets
            // `minReceiveAmount` after BOTH the 1% fee and the surcharge.
            // Non-priority callers pass `0` → denominator stays `9_900`.
            receiveGross = SwapExecutor.executeSwap(
                nftSwapRouter,
                p.paymentToken,
                p.receiveToken,
                p.paymentAmount,
                p.minReceiveAmount,
                swapPath,
                swapSources,
                p.deadline,
                r.priorityFeeBps
            );
        }
    }
}
