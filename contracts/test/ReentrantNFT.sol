// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

/**
 * @title IReentrancyTarget
 * @notice Minimal interface exposed by `UnifiedFeeVault.settleNftBuy`
 *         that this reentrant mock invokes to prove the vault's
 *         `ReentrancyGuard` blocks hostile NFT transfer hooks.
 */
interface IReentrancyTarget {
    struct ReplayIntent {
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

    /// @notice Mirrors `IntentHashing.SellerNftSale` — the seller-signed
    ///         consent required by the M-06 fix (nonce-floor revision:
    ///         field-for-field identical to the real struct, including
    ///         `nonce`, so this mock's computed function selector
    ///         matches the vault's real `settleNftBuy` selector).
    struct ReplaySellerAuth {
        address seller;
        address nftContract;
        uint256 nftTokenId;
        address receiveToken;
        uint256 minReceiveAmount;
        uint256 expiresAt;
        uint256 nonce;
    }

    /**
     * @notice Attempt to settle an intent. Must match
     *         `UnifiedFeeVault.settleNftBuy`.
     * @param intent Buyer-signed intent.
     * @param signature EIP-712 signature.
     * @param swapPath OmniSwapRouter path (empty for same-token).
     * @param swapSources OmniSwapRouter source IDs.
     * @param sellerAuth Seller-signed `SellerNftSale` authorization.
     * @param sellerSignature Seller's EIP-712 signature over `sellerAuth`.
     */
    function settleNftBuy(
        ReplayIntent calldata intent,
        bytes calldata signature,
        address[] calldata swapPath,
        bytes32[] calldata swapSources,
        ReplaySellerAuth calldata sellerAuth,
        bytes calldata sellerSignature
    ) external;
}

/**
 * @title ReentrantNFT
 * @notice Test-only ERC-721 whose `_beforeTokenTransfer` hook attempts
 *         to re-enter the settlement contract.
 */
contract ReentrantNFT is ERC721 {
    /// @notice Target settlement contract attacked during NFT transfer.
    address public target;

    /// @notice Intent to replay during the reentrancy attempt.
    IReentrancyTarget.ReplayIntent private _replay;

    /// @notice Signature to replay during the reentrancy attempt.
    bytes private _sig;

    /// @notice Seller authorization to replay during the reentrancy
    ///         attempt (M-06 fix — content is irrelevant since the
    ///         reentrant call reverts at the `nonReentrant` modifier
    ///         before any argument is inspected, but the ABI shape
    ///         must match to reach the same function selector).
    IReentrancyTarget.ReplaySellerAuth private _sellerAuth;

    /// @notice Seller signature to replay during the reentrancy attempt.
    bytes private _sellerSig;

    /// @notice Flag the reentrancy attempt actually ran.
    bool public attempted;

    /// @notice Last error returned by the reentrant call (for assertions).
    bytes public lastError;

    constructor() ERC721("ReentrantNFT", "RNFT") {} // solhint-disable-line no-empty-blocks

    /**
     * @notice Mint a token to any recipient.
     * @param to Recipient address.
     * @param tokenId Token id to mint.
     */
    function mint(address to, uint256 tokenId) external {
        _mint(to, tokenId);
    }

    /**
     * @notice Arm the reentrancy payload.
     * @param target_ Settlement contract address.
     * @param intent Intent to replay.
     * @param sig Signature to replay.
     * @param sellerAuth Seller authorization to replay.
     * @param sellerSig Seller signature to replay.
     */
    function arm(
        address target_,
        IReentrancyTarget.ReplayIntent calldata intent,
        bytes calldata sig,
        IReentrancyTarget.ReplaySellerAuth calldata sellerAuth,
        bytes calldata sellerSig
    ) external {
        target = target_;
        _replay = intent;
        _sig = sig;
        _sellerAuth = sellerAuth;
        _sellerSig = sellerSig;
    }

    /// @dev ERC-721 v5 hook — fires during every transfer/mint/burn.
    function _update(
        address to,
        uint256 tokenId,
        address auth
    ) internal override returns (address) {
        if (target != address(0) && !attempted) {
            attempted = true;
            address[] memory emptyPath;
            bytes32[] memory emptySources;
            // solhint-disable-next-line avoid-low-level-calls
            (bool ok, bytes memory err) = target.call(
                abi.encodeWithSelector(
                    IReentrancyTarget.settleNftBuy.selector,
                    _replay,
                    _sig,
                    emptyPath,
                    emptySources,
                    _sellerAuth,
                    _sellerSig
                )
            );
            // Store the error for the test to read; swallow it so the
            // outer transaction still reverts with its OWN error if the
            // guard fires as expected.
            if (!ok) {
                lastError = err;
            }
        }
        return super._update(to, tokenId, auth);
    }
}
