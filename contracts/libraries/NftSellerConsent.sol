// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ECDSA} from
    "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from
    "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {IntentHashing} from "./IntentHashing.sol";

/**
 * @title NftSellerConsent
 * @author OmniBazaar Team
 * @notice DELEGATECALL-linked library: seller-signed consent
 *         verification for `UnifiedFeeVault.settleNftBuy`, split out of
 *         the vault to keep it under the 24 KiB EIP-170 limit — the
 *         same reason {PrioritySettlement} carries the P2P
 *         seller-attestation check instead of the vault doing it
 *         in-line.
 * @dev `verifyAndConsume` does the FULL job in one call — digest,
 *      `ECDSA.recover`, every term comparison, the
 *      `_sellerNftNonceFloor` monotonic-nonce check, and raising the
 *      floor — even though `sellerAuth`/`intent` are already in
 *      `settleNftBuy`'s own scope. Measured smaller than splitting the
 *      comparisons back into the vault (tried; cost MORE, twice, across
 *      two different split shapes) — the per-branch revert/compare
 *      control flow is bulkier at the call site than inside one
 *      library function, regardless of where the data already lives.
 *      Both the typehash and the EIP-712 domain separator are computed
 *      locally (not taken as parameters) — `address(this)` under
 *      DELEGATECALL resolves to the vault, so this reproduces
 *      `_hashTypedDataV4` exactly while keeping the call boundary to
 *      just the struct + signature + comparison scalars + mapping ref.
 *      Errors are declared here with byte-for-byte-identical signatures
 *      to the vault's own copies, so a revert selector is identical
 *      regardless of which contract raised it — the same duplication
 *      {PrioritySettlement} uses for `BadSellerAttestation`. `external`:
 *      the vault reaches this code via a real DELEGATECALL (library
 *      address linked at deploy time), not compiler inlining, which is
 *      what actually removes the bytecode from the vault.
 */
library NftSellerConsent {
    /// @notice `SELLER_NFT_SALE_TYPEHASH` — duplicated here (byte-for-
    ///         byte identical to the vault's own public constant) so it
    ///         doesn't need to cross the call boundary as a parameter
    ///         on every invocation. DO NOT edit independently of the
    ///         vault's copy.
    bytes32 internal constant SELLER_NFT_SALE_TYPEHASH = keccak256(
        "SellerNftSale(address seller,address nftContract,"
        "uint256 nftTokenId,address receiveToken,uint256 minReceiveAmount,"
        "uint256 expiresAt,uint256 nonce)"
    );

    /// @dev Standard EIP-712 domain typehash + the vault's own
    ///      `__EIP712_init("OmniBazaar", "1")` name/version, duplicated
    ///      here so the domain separator can be recomputed locally
    ///      (`address(this)` resolves to the VAULT under DELEGATECALL,
    ///      exactly matching `_domainSeparatorV4()`) instead of crossing
    ///      the call boundary as one more parameter. DO NOT edit
    ///      independently of the vault's `__EIP712_init` call.
    bytes32 private constant EIP712_DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,"
        "address verifyingContract)"
    );
    bytes32 private constant NAME_HASH = keccak256(bytes("OmniBazaar"));
    bytes32 private constant VERSION_HASH = keccak256(bytes("1"));

    /// @notice Seller consent signature does not recover to
    ///         `intent.seller` — see `UnifiedFeeVault.BadSellerAttestation`.
    error BadSellerAttestation();

    /// @notice `sellerAuth` terms disagree with the buyer's intent —
    ///         see `UnifiedFeeVault.SellerAuthorizationMismatch`.
    error SellerAuthorizationMismatch();

    /// @notice `auth.nonce` is at or below the item's current nonce
    ///         floor (superseded by a later fill or an explicit
    ///         `cancelNftSaleAuthorization`) — see
    ///         `UnifiedFeeVault.SellerAuthorizationUsed`.
    error SellerAuthorizationUsed();

    /// @notice Authorization's `expiresAt` has passed — see
    ///         `UnifiedFeeVault.Expired`.
    error Expired();

    /// @notice `swapPath`/`swapSources` don't match the intent's
    ///         committed `swapPathHash` — see `UnifiedFeeVault.BadSwapPath`.
    error BadSwapPath();

    /// @notice `intent.buyer == intent.seller`, or either is zero — see
    ///         `UnifiedFeeVault.SelfBuy` / `.ZeroAddress`.
    error SelfBuy();

    /// @notice `intent.nftContract`, `paymentToken`, or `receiveToken`
    ///         is the zero address — see `UnifiedFeeVault.ZeroAddress`.
    error ZeroAddress();

    /// @notice `paymentToken` or `receiveToken` is not on
    ///         `supportedPaymentTokens` — see
    ///         `UnifiedFeeVault.UnsupportedToken`.
    error UnsupportedToken(address token);

    /// @notice `paymentAmount` or `minReceiveAmount` is zero — see
    ///         `UnifiedFeeVault.ZeroAmount`.
    error ZeroAmount();

    /// @notice `minReceiveAmount` is below
    ///         `perTokenMinSaleAmount[receiveToken]` — see
    ///         `UnifiedFeeVault.SaleAmountTooSmall`.
    error SaleAmountTooSmall();

    /// @notice A referrer collides with the buyer/seller, or
    ///         `referrer2 == referrer` — see `UnifiedFeeVault.BadReferrer`.
    error BadReferrer();

    /**
     * @notice Verify a seller's sale authorization against a buyer's
     *         intent terms and raise the item's nonce floor to consume
     *         it.
     * @dev CEI: raises `nonceFloor[itemKey]` before returning, so the
     *      vault can safely proceed to external calls immediately after
     *      this returns. The floor check (`auth.nonce >
     *      nonceFloor[itemKey]`) — not a used-digest boolean — is what
     *      makes a fill also invalidate every OLDER authorization for
     *      the same item, not just this exact one; see
     *      `IntentHashing.SellerNftSale` NatSpec.
     * @param auth Seller-signed sale authorization.
     * @param sellerSignature Seller's EIP-712 signature over `auth`.
     * @param intentSeller `intent.seller` — must equal `auth.seller`.
     * @param intentNftContract `intent.nftContract`.
     * @param intentNftTokenId `intent.nftTokenId`.
     * @param intentReceiveToken `intent.receiveToken`.
     * @param intentMinReceiveAmount `intent.minReceiveAmount` — must be
     *        `>= auth.minReceiveAmount`.
     * @param nonceFloor The vault's own `_sellerNftNonceFloor` mapping,
     *        by storage reference.
     */
    function verifyAndConsume(
        IntentHashing.SellerNftSale calldata auth,
        bytes calldata sellerSignature,
        address intentSeller,
        address intentNftContract,
        uint256 intentNftTokenId,
        address intentReceiveToken,
        uint256 intentMinReceiveAmount,
        mapping(bytes32 => uint256) storage nonceFloor
    ) external {
        bytes32 authDigest = digest(auth);
        if (ECDSA.recover(authDigest, sellerSignature) != intentSeller) {
            revert BadSellerAttestation();
        }
        bytes32 itemKey = keccak256(
            abi.encode(auth.seller, auth.nftContract, auth.nftTokenId)
        );
        if (auth.nonce <= nonceFloor[itemKey]) {
            revert SellerAuthorizationUsed();
        }
        if (
            auth.seller != intentSeller ||
            auth.nftContract != intentNftContract ||
            auth.nftTokenId != intentNftTokenId ||
            auth.receiveToken != intentReceiveToken ||
            intentMinReceiveAmount < auth.minReceiveAmount
        ) {
            revert SellerAuthorizationMismatch();
        }
        // solhint-disable-next-line not-rely-on-time, gas-strict-inequalities
        if (block.timestamp >= auth.expiresAt) revert Expired();
        nonceFloor[itemKey] = auth.nonce;
    }

    /**
     * @notice Verify the caller-supplied swap route matches the one the
     *         buyer committed to in `swapPathHash`.
     * @dev Moved from a vault-internal `_verifySwapPathCommitment` (its
     *      only caller was `settleNftBuy`) purely to reclaim vault
     *      bytecode — same 24 KiB EIP-170 reason as the rest of this
     *      library. No behavior change. If `expectedHash == bytes32(0)`
     *      the caller MUST pass empty arrays — that's the "no-swap
     *      (fast path)" signal. For any non-zero commitment this
     *      recomputes `keccak256(abi.encode(path, sources,
     *      nftSwapRouter))` and compares.
     *
     *      Kept as a SEPARATE call from `verifyAndConsume` — merging
     *      the two into one function (tried) measured LARGER, not
     *      smaller, despite removing a second dispatch: past some
     *      point, one function with more parameters costs more than
     *      two smaller ones under this compiler profile.
     *
     *      Solodit finding (Spearbit/Uniswap 2024): binding only the
     *      route `(path, sources)` into the hash lets a governance
     *      `proposeNftSwapRouter + applyNftSwapRouter` between signing
     *      and submission execute a buyer's signed intent against a
     *      DIFFERENT router than the buyer authorized. Including the
     *      current `nftSwapRouter` in the commitment makes the signed
     *      intent implicitly invalid after any router change — users
     *      are forced to re-quote + re-sign against the new router.
     *      Wallet-side: the quote step reads `vault.nftSwapRouter()` and
     *      computes `swapPathHash` the same way.
     * @param expectedHash `intent.swapPathHash`.
     * @param swapPath Router path supplied by the caller.
     * @param swapSources Router source IDs supplied by the caller.
     * @param nftSwapRouter The vault's `nftSwapRouter` address, folded
     *        into the commitment hash.
     */
    function verifySwapPathCommitment(
        bytes32 expectedHash,
        address[] calldata swapPath,
        bytes32[] calldata swapSources,
        address nftSwapRouter
    ) external pure {
        if (expectedHash == bytes32(0)) {
            if (swapPath.length != 0 || swapSources.length != 0) {
                revert BadSwapPath();
            }
            return;
        }
        bytes32 computed = keccak256(
            abi.encode(swapPath, swapSources, nftSwapRouter)
        );
        if (computed != expectedHash) revert BadSwapPath();
    }

    /**
     * @notice Stateless validation of a `BuyNFTIntent` — buyer/seller
     *         invariants, token allowlist + amount + expiry invariants,
     *         and the two-slot referrer anti-fee-wash check.
     * @dev Moved from vault-internal `_validateNftIntent` +
     *      `_validateBuyerSellerPair` + `_validateTokensAmountsExpiry` +
     *      `_validateReferrerPair` — all four had exactly one caller
     *      each (`settleNftBuy`, directly or transitively), so
     *      extracting the whole chain purely reclaims vault bytecode
     *      under the 24 KiB EIP-170 limit. No behavior change.
     * @param buyer `intent.buyer`.
     * @param seller `intent.seller`.
     * @param nftContract `intent.nftContract`.
     * @param paymentToken `intent.paymentToken`.
     * @param receiveToken `intent.receiveToken`.
     * @param paymentAmount `intent.paymentAmount`.
     * @param minReceiveAmount `intent.minReceiveAmount`.
     * @param expiresAt `intent.expiresAt`.
     * @param referrer `intent.referrer`.
     * @param referrer2 `intent.referrer2`.
     * @param supportedPaymentTokens The vault's own
     *        `supportedPaymentTokens` allowlist, by storage reference.
     * @param perTokenMinSaleAmount The vault's own
     *        `perTokenMinSaleAmount` floors, by storage reference.
     */
    function validateIntent(
        address buyer,
        address seller,
        address nftContract,
        address paymentToken,
        address receiveToken,
        uint256 paymentAmount,
        uint256 minReceiveAmount,
        uint256 expiresAt,
        address referrer,
        address referrer2,
        mapping(address => bool) storage supportedPaymentTokens,
        mapping(address => uint256) storage perTokenMinSaleAmount
    ) external view {
        _validateBuyerSellerPair(buyer, seller, nftContract);
        _validateTokensAmountsExpiry(
            paymentToken,
            receiveToken,
            paymentAmount,
            minReceiveAmount,
            expiresAt,
            supportedPaymentTokens,
            perTokenMinSaleAmount
        );
        _validateReferrerPair(buyer, seller, referrer, referrer2);
    }

    /**
     * @notice Compute the EIP-712 digest of a `SellerNftSale`
     *         authorization under the vault's own domain.
     * @dev Reproduces exactly what `_hashTypedDataV4` on the vault
     *      would produce: recomputes the domain separator locally
     *      (`address(this)` under DELEGATECALL is the vault) rather
     *      than taking it as a parameter — one less value to marshal
     *      across the call boundary on every invocation. `public` (not
     *      `external`) so `verifyAndConsume` can call it directly.
     * @param auth Seller-signed sale authorization.
     * @return authDigest The typed-data digest.
     */
    function digest(
        IntentHashing.SellerNftSale calldata auth
    ) public view returns (bytes32 authDigest) {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                NAME_HASH,
                VERSION_HASH,
                block.chainid,
                address(this)
            )
        );
        authDigest = MessageHashUtils.toTypedDataHash(
            domainSeparator,
            keccak256(
                abi.encode(
                    SELLER_NFT_SALE_TYPEHASH,
                    auth.seller,
                    auth.nftContract,
                    auth.nftTokenId,
                    auth.receiveToken,
                    auth.minReceiveAmount,
                    auth.expiresAt,
                    auth.nonce
                )
            )
        );
    }

    /**
     * @notice Private helper: buyer/seller/nftContract address invariants.
     * @dev Split out of `validateIntent` purely to bring its cyclomatic
     *      complexity down — a `private` helper costs nothing extra at
     *      the vault boundary (it's inlined within this SAME deployed
     *      library, not a further external call).
     */
    function _validateBuyerSellerPair(
        address buyer,
        address seller,
        address nftContract
    ) private pure {
        if (buyer == seller) revert SelfBuy();
        if (buyer == address(0)) revert ZeroAddress();
        if (seller == address(0)) revert ZeroAddress();
        if (nftContract == address(0)) revert ZeroAddress();
    }

    /**
     * @notice Private helper: token allowlist + amount + expiry
     *         invariants.
     * @dev See `_validateBuyerSellerPair` NOTE on why this is split out.
     */
    function _validateTokensAmountsExpiry(
        address paymentToken,
        address receiveToken,
        uint256 paymentAmount,
        uint256 minReceiveAmount,
        uint256 expiresAt,
        mapping(address => bool) storage supportedPaymentTokens,
        mapping(address => uint256) storage perTokenMinSaleAmount
    ) private view {
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
     * @notice Private helper: the H-01 two-slot referrer anti-fee-wash
     *         check.
     * @dev See `_validateBuyerSellerPair` NOTE on why this is split out.
     */
    function _validateReferrerPair(
        address buyer,
        address seller,
        address referrer,
        address referrer2
    ) private pure {
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
}
