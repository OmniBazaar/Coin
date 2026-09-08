// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from
    "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IOmniSwapRouter} from "../interfaces/IOmniSwapRouter.sol";

/**
 * @title SwapExecutor
 * @author OmniBazaar Team
 * @notice External library that performs the coin-agnostic OmniSwapRouter
 *         hop of `UnifiedFeeVault._settleCoinAgnosticBuy` (buyer pays
 *         token A, seller is to receive token B). Linked via DELEGATECALL
 *         so all `forceApprove` / `swap` / `balanceOf` calls and balance
 *         movements execute inside the vault's context.
 * @dev Extracted from the vault purely to reclaim deployed bytecode
 *      (24 KiB EIP-170 budget). Observable behaviour is byte-for-byte
 *      identical to the prior inline swap branch: the gross-up
 *      `minAmountOut` (covering the 1% marketplace fee), the buyer- and
 *      receive-side fee-on-transfer balance-delta guards, the explicit
 *      `minAmountOut` re-check, and the post-swap allowance zeroing are
 *      all preserved exactly. The same-token fast path stays inline in
 *      the vault and never reaches this library.
 *
 *      IMPORTANT: The library declares no state variables; the router
 *      address is passed in by the vault (read from `nftSwapRouter`).
 */
library SwapExecutor {
    using SafeERC20 for IERC20;

    /// @notice Basis-points denominator for the fee gross-up
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    /// @notice Numerator for the 1% marketplace-fee gross-up
    /// @dev `9_900 = 10_000 - 100`; the router must deliver at least
    ///      `minReceiveAmount * 10_000 / 9_900` so the seller nets
    ///      `minReceiveAmount` AFTER the 1% fee.
    uint256 internal constant FEE_GROSSUP_DENOMINATOR = 9_900;

    /// @notice A non-standard token (fee-on-transfer / rebasing) or a
    ///         router that misreports `amountOut` was detected via a
    ///         balance-delta mismatch.
    error FeeOnTransferToken();

    /// @notice OmniSwapRouter returned less output than required after
    ///         the marketplace-fee gross-up.
    /// @param received Amount returned by the router
    /// @param required Minimum required (gross-up of `minReceiveAmount`)
    error SwapOutputTooLow(uint256 received, uint256 required);

    /**
     * @notice Pull-side already done by the caller; this swaps
     *         `paymentAmount` of `paymentToken` into `receiveToken` and
     *         returns the gross amount received.
     * @dev Runs via DELEGATECALL so `address(this)` is the vault. The
     *      caller (`_settleCoinAgnosticBuy`) is responsible for the
     *      buyer-side pull + its FoT guard before calling this, and for
     *      the fee split + seller payout after.
     * @param router OmniSwapRouter address (`nftSwapRouter`); MUST be
     *        non-zero (the caller checks `NftSwapRouterNotSet`).
     * @param paymentToken Token the vault holds and approves to `router`.
     * @param receiveToken Token the swap must deliver to the vault.
     * @param paymentAmount Exact amount of `paymentToken` to swap.
     * @param minReceiveAmount Seller's minimum receive (net of the 1%
     *        fee); grossed up to the router's `minAmountOut`.
     * @param swapPath Router path matching the buyer's `swapPathHash`.
     * @param swapSources Router source IDs — one per hop.
     * @param deadline Swap deadline (`intent.expiresAt`).
     * @param priorityFeeBps Sale-time priority-placement surcharge in
     *        basis points (0–300). Widens the gross-up so the seller
     *        still nets `minReceiveAmount` AFTER both the 1% fee AND the
     *        surcharge: the router must deliver
     *        `minReceiveAmount * 10_000 / (9_900 - priorityFeeBps)`. The
     *        normal (non-priority) path passes 0, leaving the
     *        denominator at `9_900` — byte-for-byte the prior gross-up.
     * @return receiveGross Gross `receiveToken` amount received.
     */
    function executeSwap(
        address router,
        address paymentToken,
        address receiveToken,
        uint256 paymentAmount,
        uint256 minReceiveAmount,
        address[] calldata swapPath,
        bytes32[] calldata swapSources,
        uint256 deadline,
        uint256 priorityFeeBps
    ) external returns (uint256 receiveGross) {
        // Gross-up: seller must net `minReceiveAmount` AFTER the 1%
        // marketplace fee (and any priority surcharge), so the router
        // must deliver at least
        // `minReceiveAmount * 10_000 / (9_900 - priorityFeeBps)` (plus
        // 1 wei ceil to absorb integer-division rounding). With
        // `priorityFeeBps == 0` the denominator is `9_900` — identical
        // to the prior 1%-only gross-up.
        uint256 minSwapOutput = (minReceiveAmount * BPS_DENOMINATOR)
            / (FEE_GROSSUP_DENOMINATOR - priorityFeeBps) + 1;

        IERC20(paymentToken).forceApprove(router, paymentAmount);

        IOmniSwapRouter.SwapParams memory params =
            IOmniSwapRouter.SwapParams({
                tokenIn: paymentToken,
                tokenOut: receiveToken,
                amountIn: paymentAmount,
                minAmountOut: minSwapOutput,
                path: swapPath,
                sources: swapSources,
                deadline: deadline,
                recipient: address(this)
            });

        // Receive-side FoT check: measure actual balance delta of
        // `receiveToken` and refuse to settle if the token reports a
        // different `amountOut` than what landed in the vault. Mirrors the
        // buyer-side check (M-01). Defence-in-depth against admin
        // allowlisting a receive-side FoT/rebasing token by mistake; and
        // against a buggy/malicious router that lies about `amountOut`.
        uint256 receiveBalBefore =
            IERC20(receiveToken).balanceOf(address(this));

        IOmniSwapRouter.SwapResult memory result =
            IOmniSwapRouter(router).swap(params);
        receiveGross = result.amountOut;

        uint256 receiveBalAfter =
            IERC20(receiveToken).balanceOf(address(this));
        if (receiveBalAfter - receiveBalBefore != receiveGross) {
            revert FeeOnTransferToken();
        }

        // Belt-and-braces: router already enforces minAmountOut, but
        // assert explicitly so a buggy router cannot silently
        // under-deliver to the seller.
        if (receiveGross < minSwapOutput) {
            revert SwapOutputTooLow(receiveGross, minSwapOutput);
        }

        // Solodit finding #1 (Strata 2025): zero-out the router allowance
        // after the swap. The router SHOULD have consumed exactly
        // `paymentAmount`, but a buggy/FoT-aware adapter could leave dust
        // allowance — and a future refactor could expose a drain path.
        // `forceApprove(router, 0)` is cheap insurance.
        IERC20(paymentToken).forceApprove(router, 0);
    }
}
