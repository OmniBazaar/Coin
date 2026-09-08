// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from
    "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC2981} from
    "@openzeppelin/contracts/interfaces/IERC2981.sol";

/**
 * @title RoyaltyResolver
 * @author OmniBazaar Team
 * @notice External library that resolves and pays the EIP-2981 creator
 *         royalty owed on an atomic NFT buy (N-ROY) on behalf of
 *         UnifiedFeeVault. Linked via DELEGATECALL so the royalty
 *         `safeTransfer` and `RoyaltyPaid` event execute inside the
 *         vault's context (vault balance is debited, the log is emitted
 *         from the vault's address).
 * @dev Extracted from `UnifiedFeeVault._settleCoinAgnosticBuy` purely to
 *      reclaim vault deployed bytecode (24 KiB EIP-170 budget). Observable
 *      behaviour is identical to the prior inline implementation: the
 *      royalty lookup is gas-bounded to {ROYALTY_GAS_LIMIT} and
 *      try/catch-tolerant of non-ERC-2981 collections, the royalty is
 *      clamped to the seller's post-fee proceeds, and `RoyaltyPaid` keeps
 *      the same `(address,uint256,address,uint256)` signature (identical
 *      topic0) so off-chain indexers are unaffected.
 *
 *      IMPORTANT: The library declares no state variables. All execution
 *      is stateless except for the SafeERC20 transfer of receive-token
 *      from the vault's balance to the creator.
 */
library RoyaltyResolver {
    using SafeERC20 for IERC20;

    /// @notice Gas forwarded to a listed collection's `royaltyInfo`
    ///         during an atomic NFT buy (N-ROY). A seller-chosen
    ///         collection cannot grief the relayer's gas (gasless path):
    ///         a `royaltyInfo` that exceeds this ceiling out-of-gases,
    ///         is caught, and is treated as paying no royalty.
    uint256 private constant ROYALTY_GAS_LIMIT = 50_000;

    /**
     * @notice Emitted when an EIP-2981 creator royalty is paid out of an
     *         atomic NFT buy's proceeds (N-ROY).
     * @param nftContract Collection whose `royaltyInfo` was honored
     * @param tokenId Token sold
     * @param royaltyRecipient Creator address paid the royalty
     * @param royaltyAmount Receive-token amount paid to the creator
     */
    event RoyaltyPaid(
        address indexed nftContract,
        uint256 indexed tokenId,
        address royaltyRecipient,
        uint256 royaltyAmount
    );

    /**
     * @notice Resolve and pay any EIP-2981 creator royalty owed on an
     *         atomic NFT buy, returning the seller's reduced proceeds.
     * @dev Queries the listed collection's `royaltyInfo` over the full
     *      receive-side sale value, clamps the result to `sellerPay`
     *      (royalty is senior to seller proceeds — worst case the seller
     *      nets zero), pays the creator via `safeTransfer`, and emits
     *      {RoyaltyPaid}. Tolerant of collections that don't implement
     *      ERC-2981 or that exceed {ROYALTY_GAS_LIMIT} (returns
     *      `sellerPay` unchanged, no transfer, no event). Runs via
     *      DELEGATECALL so the transfer debits the vault's balance.
     * @param receiveToken Token the seller receives (royalty is paid in
     *        this token).
     * @param nftContract Collection to query.
     * @param tokenId Token being sold.
     * @param receiveGross Full receive-side sale value the royalty is
     *        computed on.
     * @param sellerPay Seller's proceeds after the marketplace fee; the
     *        royalty upper bound.
     * @return newSellerPay `sellerPay` net of any royalty paid.
     */
    function resolveAndPay(
        address receiveToken,
        address nftContract,
        uint256 tokenId,
        uint256 receiveGross,
        uint256 sellerPay
    ) external returns (uint256 newSellerPay) {
        newSellerPay = sellerPay;
        (address recipient, uint256 royalty) = resolve(
            nftContract,
            tokenId,
            receiveGross,
            sellerPay
        );
        if (royalty > 0) {
            // royalty <= sellerPay by the clamp in `_resolve`, so the
            // subtraction cannot underflow.
            unchecked {
                newSellerPay = sellerPay - royalty;
            }
            IERC20(receiveToken).safeTransfer(recipient, royalty);
            emit RoyaltyPaid(nftContract, tokenId, recipient, royalty);
        }
    }

    /**
     * @notice Gas-bounded, try/catch-tolerant EIP-2981 lookup.
     * @dev `IERC2981.royaltyInfo` is `view`, so the compiler emits a
     *      STATICCALL — no re-entrancy surface. Clamps the royalty to
     *      `maxRoyalty`.
     *
     *      `internal`, so a caller that pays in a currency this library
     *      cannot transfer — native ETH, POL or XOM — can reuse exactly
     *      this lookup and do its own payout. `NFTExchange` does that.
     *      Being `internal` it is inlined into each caller, so the
     *      deployed library bytecode is unchanged and the live
     *      `UnifiedFeeVault` link is unaffected.
     * @param nftContract Collection to query.
     * @param tokenId Token being sold.
     * @param salePrice Receive-side sale value.
     * @param maxRoyalty Upper bound (the seller's post-fee proceeds).
     * @return recipient Creator address, or `address(0)` if none.
     * @return royalty Receive-token amount owed, clamped to `maxRoyalty`.
     */
    function resolve(
        address nftContract,
        uint256 tokenId,
        uint256 salePrice,
        uint256 maxRoyalty
    ) internal view returns (address recipient, uint256 royalty) {
        try
            IERC2981(nftContract).royaltyInfo{gas: ROYALTY_GAS_LIMIT}(
                tokenId,
                salePrice
            )
        returns (address royaltyRecipient, uint256 royaltyDue) {
            if (royaltyRecipient != address(0) && royaltyDue > 0) {
                recipient = royaltyRecipient;
                royalty =
                    royaltyDue > maxRoyalty ? maxRoyalty : royaltyDue;
            }
        } catch {
            // Collection does not implement ERC-2981 — no royalty owed.
        }
    }
}
