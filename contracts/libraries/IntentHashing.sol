// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title IntentHashing
 * @author OmniBazaar Team
 * @notice Type-only library declaring UnifiedFeeVault's NFT and
 *         plain-P2P buy-intent structs.
 * @dev The structs are used DIRECTLY as the vault's external
 *      `settleNftBuy` / `settleP2PBuy` / `settleP2PBuyAttested`
 *      parameters. Declaring them in a shared library (rather than
 *      inside the vault) keeps a single canonical definition that the
 *      {PrioritySettlement} / {CoinAgnosticSettlement} libraries and the
 *      vault all reference without duplication. The ABI tuple is
 *      positional, so the declaring scope does NOT change the function
 *      selector or the EIP-712 struct encoding — every live client
 *      signature stays valid. No functions: a types-only library emits
 *      no deployed bytecode and needs no linking.
 *
 *      Field order + types MUST match `BUY_NFT_TYPEHASH` /
 *      `BUY_P2P_TYPEHASH` exactly or signatures silently break.
 */
library IntentHashing {
    /// @notice NFT buy intent. Field order = `BUY_NFT_TYPEHASH` layout.
    struct BuyNFTIntent {
        address buyer;
        address seller;
        address nftContract;
        uint256 nftTokenId;
        address paymentToken;
        uint256 paymentAmount;
        address receiveToken;
        uint256 minReceiveAmount;
        bytes32 swapPathHash;
        uint256 listingId;
        address referrer;
        address referrer2;
        uint256 expiresAt;
        uint256 nonce;
    }

    /// @notice Seller's NFT sale authorization. Field order =
    ///         `SELLER_NFT_SALE_TYPEHASH` layout.
    /// @dev Binds a specific token + minimum acceptable proceeds to the
    ///      SELLER's own signature. `settleNftBuy`'s `BuyNFTIntent` is
    ///      entirely buyer-authored; an ERC-721 `setApprovalForAll` grant
    ///      is collection-wide operator trust, not per-sale consent to a
    ///      price. This struct is that consent. `seller` IS kept
    ///      (despite being recoverable from the signature) so the
    ///      digest is signer-scoped: without it, the digest would be
    ///      fully deterministic from public data alone, and anyone
    ///      could pre-emptively grief a not-yet-signed listing.
    ///
    ///      `nonce` is a per-`(seller, nftContract, nftTokenId)`
    ///      MONOTONIC floor, not a plain replay guard: `settleNftBuy`
    ///      requires `nonce` strictly greater than that item's stored
    ///      floor, then raises the floor to `nonce`. This means signing
    ///      a NEW authorization for an item you've listed before does
    ///      NOT just add a second valid offer alongside the old one —
    ///      once anything (a fill, or an explicit
    ///      `cancelNftSaleAuthorization` call) raises the floor past an
    ///      older signature's `nonce`, that older signature can never
    ///      be filled again, no matter how many stale signed payloads
    ///      exist or where they've leaked to. Recommended client nonce
    ///      source: current unix time (naturally increasing, no
    ///      cross-device counter to coordinate).
    struct SellerNftSale {
        address seller;
        address nftContract;
        uint256 nftTokenId;
        address receiveToken;
        uint256 minReceiveAmount;
        uint256 expiresAt;
        uint256 nonce;
    }

    /// @notice Plain P2P buy intent. Field order = `BUY_P2P_TYPEHASH`.
    struct BuyP2PIntent {
        address buyer;
        address seller;
        bytes32 listingContentHash;
        uint256 listingId;
        address paymentToken;
        uint256 paymentAmount;
        address receiveToken;
        uint256 minReceiveAmount;
        bytes32 swapPathHash;
        address referrer;
        address referrer2;
        address listingNode;
        address sellingNode;
        uint256 expiresAt;
        uint256 nonce;
    }
}
