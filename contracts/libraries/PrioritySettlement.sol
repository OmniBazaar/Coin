// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ECDSA} from
    "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from
    "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {CoinAgnosticSettlement} from "./CoinAgnosticSettlement.sol";
import {BuyIntentValidator} from "./BuyIntentValidator.sol";
import {IntentHashing} from "./IntentHashing.sol";

/**
 * @title PrioritySettlement
 * @author OmniBazaar Team
 * @notice External library implementing the full sale-time
 *         priority-placement P2P settlement orchestration for
 *         UnifiedFeeVault: stateless validation, EIP-712 buyer + seller
 *         digest computation, both signature recoveries, swap-path
 *         commitment, replay marking, the surcharge-aware
 *         {CoinAgnosticSettlement} pipeline, and the
 *         `P2PBuyWithPrioritySettled` event.
 * @dev Extracted from UnifiedFeeVault PURELY to reclaim deployed
 *      bytecode so the vault stays under the 24 KiB Spurious Dragon
 *      (EIP-170) limit. Linked via DELEGATECALL: it runs in the vault's
 *      storage context, so the replay mark, fee distribution, and seller
 *      payout all touch the vault's own slots + balance, and the event
 *      is emitted from the vault's address. The vault's external
 *      `settleP2PBuyWithPriority` holds `nonReentrant` + `whenNotPaused`
 *      and the `xomToken`-configured guard, then calls this once.
 *
 *      The vault passes its live `_domainSeparatorV4()` and the
 *      canonical typehashes, so this library declares no EIP-712 type
 *      strings of its own (the vault remains the single source of
 *      truth). The intent struct is re-declared to match the vault's
 *      `BuyP2PWithPriorityIntent` field order + types exactly — any
 *      drift silently changes the digest and breaks signatures.
 */
library PrioritySettlement {
    /// @notice Mirror of `UnifiedFeeVault.BuyP2PWithPriorityIntent`
    ///         (field order + types MUST match exactly).
    struct Intent {
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
        uint256 priorityFeeBps;
    }

    /// @notice Vault config + canonical EIP-712 constants for one call
    /// @dev Built once by the vault wrapper and threaded through. Holds
    ///      the live domain separator, the two canonical typehashes, the
    ///      swap router, the two fee recipients, and the surcharge cap.
    /// @param domainSeparator Vault's `_domainSeparatorV4()`.
    /// @param intentTypehash Vault's `BUY_P2P_WITH_PRIORITY_TYPEHASH`.
    /// @param attestationTypehash Vault's
    ///        `SELLER_PRIORITY_ATTESTATION_TYPEHASH`.
    /// @param nftSwapRouter Vault's `nftSwapRouter`.
    /// @param stakingPool Vault's staking-pool fee recipient.
    /// @param protocolTreasury Vault's protocol-treasury fee recipient.
    /// @param maxPriorityFeeBps Vault's `MAX_PRIORITY_FEE_BPS` cap.
    struct Context {
        bytes32 domainSeparator;
        bytes32 intentTypehash;
        bytes32 attestationTypehash;
        address nftSwapRouter;
        address stakingPool;
        address protocolTreasury;
        uint256 maxPriorityFeeBps;
    }

    /// @notice Vault config + canonical EIP-712 constants for a plain
    ///         (non-priority) P2P settlement
    /// @param domainSeparator Vault's `_domainSeparatorV4()`.
    /// @param intentTypehash Vault's `BUY_P2P_TYPEHASH`.
    /// @param nodeAttestationTypehash Vault's
    ///        `SELLER_NODE_ATTESTATION_TYPEHASH`.
    /// @param nftSwapRouter Vault's `nftSwapRouter`.
    /// @param stakingPool Vault's staking-pool fee recipient.
    /// @param protocolTreasury Vault's protocol-treasury fee recipient.
    /// @param requireAttestation True on the `settleP2PBuyAttested` path
    ///        (verify the seller node co-signature); false on the
    ///        unattested `settleP2PBuy` path (reject non-zero nodes).
    struct P2PContext {
        bytes32 domainSeparator;
        bytes32 intentTypehash;
        bytes32 nodeAttestationTypehash;
        address nftSwapRouter;
        address stakingPool;
        address protocolTreasury;
        bool requireAttestation;
    }

    /// @notice Emitted on every successful priority-placement P2P buy
    /// @dev Declared here so the DELEGATECALL emits it from the vault's
    ///      address with the same topic0 + signature as the vault's
    ///      `P2PBuyWithPrioritySettled`. Off-chain indexers see no
    ///      difference from an in-vault emit.
    /// @param listingId Off-chain listing identifier (pass-through)
    /// @param listingContentHash Off-chain listing content hash
    /// @param buyer Intent buyer (and signer)
    /// @param seller Seller who received `sellerPay`
    /// @param paymentToken Token the buyer paid in
    /// @param paymentAmount Gross amount paid by the buyer
    /// @param receiveToken Token the seller received
    /// @param receiveGross Gross receive-side amount (pre fee + surcharge)
    /// @param fee 1% marketplace fee in `receiveToken`
    /// @param prioritySurcharge Priority surcharge in `receiveToken`
    /// @param referrer Primary referrer (zero routes share to ODDAO)
    /// @param referrer2 Secondary referrer (zero routes to ODDAO)
    /// @param listingNode Listing node (zero routes share to ODDAO)
    /// @param sellingNode Selling node (zero routes share to ODDAO)
    event P2PBuyWithPrioritySettled(
        uint256 indexed listingId,
        bytes32 indexed listingContentHash,
        address indexed buyer,
        address seller,
        address paymentToken,
        uint256 paymentAmount,
        address receiveToken,
        uint256 receiveGross,
        uint256 fee,
        uint256 prioritySurcharge,
        address referrer,
        address referrer2,
        address listingNode,
        address sellingNode
    );

    /// @notice Emitted on every successful plain (non-priority) P2P buy
    /// @dev Declared here so the DELEGATECALL emits it from the vault's
    ///      address with the same topic0 + signature as the vault's
    ///      `P2PBuySettled`. Off-chain indexers see no difference.
    /// @param listingId Off-chain listing identifier (pass-through)
    /// @param listingContentHash Off-chain listing content hash
    /// @param buyer Intent buyer (and signer)
    /// @param seller Seller who received `sellerPay`
    /// @param paymentToken Token the buyer paid in
    /// @param paymentAmount Gross amount paid by the buyer
    /// @param receiveToken Token the seller received
    /// @param receiveGross Gross receive-side amount (pre marketplace fee)
    /// @param fee 1% marketplace fee in `receiveToken`
    /// @param referrer Primary referrer (zero routes share to ODDAO)
    /// @param referrer2 Secondary referrer (zero routes to ODDAO)
    /// @param listingNode Listing node (zero routes share to ODDAO)
    /// @param sellingNode Selling node (zero routes share to ODDAO)
    event P2PBuySettled(
        uint256 indexed listingId,
        bytes32 indexed listingContentHash,
        address indexed buyer,
        address seller,
        address paymentToken,
        uint256 paymentAmount,
        address receiveToken,
        uint256 receiveGross,
        uint256 fee,
        address referrer,
        address referrer2,
        address listingNode,
        address sellingNode
    );

    /// @notice `priorityFeeBps` exceeds the vault's cap (3% = 300 bps)
    error PriorityFeeTooHigh();

    /// @notice Unattested `settleP2PBuy` received non-zero nodes
    error NodesRequireAttestation();

    /// @notice Buyer signature did not recover to `intent.buyer`
    error BadSigner();

    /// @notice Seller attestation did not recover to `intent.seller`
    error BadSellerAttestation();

    /// @notice Supplied swap route does not match the committed hash
    error BadSwapPath();

    /// @notice The intent digest has already been settled
    error Replay();

    /**
     * @notice Validate, authenticate, replay-guard, settle, and emit for
     *         a priority-placement P2P buy
     * @dev Full CEI: cap check → stateless validation → swap-path
     *      commitment → buyer signature → seller attestation → replay
     *      mark (BEFORE the settlement external calls) →
     *      {CoinAgnosticSettlement.settle} → event. Runs in the vault's
     *      storage context via DELEGATECALL.
     * @param ctx Vault config + canonical EIP-712 constants.
     * @param intent Buyer-signed priority intent.
     * @param signature Buyer's EIP-712 signature over `intentTypehash`.
     * @param sellerAttestation Seller's signature over
     *        `attestationTypehash`.
     * @param swapPath Router path matching `intent.swapPathHash`.
     * @param swapSources Router source IDs — one per hop.
     * @param usedP2PIntents Vault's `_usedP2PIntents` replay mapping.
     * @param supportedPaymentTokens Vault's allowlist mapping.
     * @param perTokenMinSaleAmount Vault's per-token floor mapping.
     * @param pendingBridge Vault's `pendingBridge` mapping.
     * @param pendingClaims Vault's `pendingClaims` mapping.
     * @param totalPendingClaims Vault's `totalPendingClaims` mapping.
     * @param totalDistributed Vault's `totalDistributed` mapping.
     * @return feesCollectedDelta Amount to add to `totalFeesCollected`.
     */
    function settle(
        Context calldata ctx,
        Intent calldata intent,
        bytes calldata signature,
        bytes calldata sellerAttestation,
        address[] calldata swapPath,
        bytes32[] calldata swapSources,
        mapping(bytes32 => bool) storage usedP2PIntents,
        mapping(address => bool) storage supportedPaymentTokens,
        mapping(address => uint256) storage perTokenMinSaleAmount,
        mapping(address => uint256) storage pendingBridge,
        mapping(address => mapping(address => uint256))
            storage pendingClaims,
        mapping(address => uint256) storage totalPendingClaims,
        mapping(address => uint256) storage totalDistributed
    ) external returns (uint256 feesCollectedDelta) {
        if (intent.priorityFeeBps > ctx.maxPriorityFeeBps) {
            revert PriorityFeeTooHigh();
        }

        _validate(intent, supportedPaymentTokens, perTokenMinSaleAmount);
        _verifySwapPath(
            intent.swapPathHash, ctx.nftSwapRouter, swapPath, swapSources
        );

        // ─── Buyer signature over the priority typehash ───────────
        bytes32 digest = _hashIntent(
            ctx.domainSeparator, ctx.intentTypehash, intent
        );
        if (ECDSA.recover(digest, signature) != intent.buyer) {
            revert BadSigner();
        }

        // ─── Seller consent to rate + node attribution ────────────
        bytes32 attDigest = _hashAttestation(
            ctx.domainSeparator,
            ctx.attestationTypehash,
            intent.listingContentHash,
            intent.listingNode,
            intent.sellingNode,
            intent.priorityFeeBps
        );
        if (
            ECDSA.recover(attDigest, sellerAttestation) != intent.seller
        ) {
            revert BadSellerAttestation();
        }

        // ─── Replay protection: mark BEFORE any external call ─────
        if (usedP2PIntents[digest]) revert Replay();
        usedP2PIntents[digest] = true;

        feesCollectedDelta = _runSettlement(
            ctx,
            intent,
            swapPath,
            swapSources,
            pendingBridge,
            pendingClaims,
            totalPendingClaims,
            totalDistributed
        );
    }

    /**
     * @notice Validate, authenticate, replay-guard, settle, and emit for
     *         a plain (non-priority) P2P buy — the shared body of
     *         `settleP2PBuy` and `settleP2PBuyAttested`
     * @dev Byte-for-byte the prior in-vault `_executeP2PSettlement`
     *      (plus the node-gating both callers did), relocated to keep
     *      the vault under the 24 KiB EIP-170 limit. Node gating:
     *        - `requireAttestation == false` (`settleP2PBuy`): reject any
     *          non-zero `listingNode` / `sellingNode` (M-05).
     *        - `requireAttestation == true` (`settleP2PBuyAttested`):
     *          recover `sellerNodeAttestation` over
     *          `nodeAttestationTypehash` and require it == `intent.seller`.
     *      Then CEI: validation → swap-path commitment → buyer signature
     *      → replay mark (BEFORE external calls) →
     *      {CoinAgnosticSettlement.settle} (priorityFeeBps = 0) → event.
     *      Runs in the vault's storage context via DELEGATECALL.
     * @param ctx Vault config + canonical EIP-712 constants + the
     *        `requireAttestation` flag.
     * @param intent Buyer-signed plain P2P intent.
     * @param signature Buyer's EIP-712 signature over `intentTypehash`.
     * @param sellerNodeAttestation Seller's signature over
     *        `nodeAttestationTypehash` (ignored when
     *        `requireAttestation == false`).
     * @param swapPath Router path matching `intent.swapPathHash`.
     * @param swapSources Router source IDs — one per hop.
     * @param usedP2PIntents Vault's `_usedP2PIntents` replay mapping.
     * @param supportedPaymentTokens Vault's allowlist mapping.
     * @param perTokenMinSaleAmount Vault's per-token floor mapping.
     * @param pendingBridge Vault's `pendingBridge` mapping.
     * @param pendingClaims Vault's `pendingClaims` mapping.
     * @param totalPendingClaims Vault's `totalPendingClaims` mapping.
     * @param totalDistributed Vault's `totalDistributed` mapping.
     * @return feesCollectedDelta Amount to add to `totalFeesCollected`.
     */
    function settleP2P(
        P2PContext calldata ctx,
        IntentHashing.BuyP2PIntent calldata intent,
        bytes calldata signature,
        bytes calldata sellerNodeAttestation,
        address[] calldata swapPath,
        bytes32[] calldata swapSources,
        mapping(bytes32 => bool) storage usedP2PIntents,
        mapping(address => bool) storage supportedPaymentTokens,
        mapping(address => uint256) storage perTokenMinSaleAmount,
        mapping(address => uint256) storage pendingBridge,
        mapping(address => mapping(address => uint256))
            storage pendingClaims,
        mapping(address => uint256) storage totalPendingClaims,
        mapping(address => uint256) storage totalDistributed
    ) external returns (uint256 feesCollectedDelta) {
        // ─── Node gating ──────────────────────────────────────────
        if (ctx.requireAttestation) {
            bytes32 attDigest = MessageHashUtils.toTypedDataHash(
                ctx.domainSeparator,
                keccak256(
                    abi.encode(
                        ctx.nodeAttestationTypehash,
                        intent.listingContentHash,
                        intent.listingNode,
                        intent.sellingNode
                    )
                )
            );
            if (
                ECDSA.recover(attDigest, sellerNodeAttestation)
                    != intent.seller
            ) {
                revert BadSellerAttestation();
            }
        } else if (
            intent.listingNode != address(0) ||
            intent.sellingNode != address(0)
        ) {
            revert NodesRequireAttestation();
        }

        _validateP2P(
            intent, supportedPaymentTokens, perTokenMinSaleAmount
        );
        _verifySwapPath(
            intent.swapPathHash, ctx.nftSwapRouter, swapPath, swapSources
        );

        // ─── Buyer signature over the plain P2P typehash ──────────
        bytes32 digest = _hashP2P(
            ctx.domainSeparator, ctx.intentTypehash, intent
        );
        if (ECDSA.recover(digest, signature) != intent.buyer) {
            revert BadSigner();
        }

        // ─── Replay protection: mark BEFORE any external call ─────
        if (usedP2PIntents[digest]) revert Replay();
        usedP2PIntents[digest] = true;

        feesCollectedDelta = _runP2PSettlement(
            ctx,
            intent,
            swapPath,
            swapSources,
            pendingBridge,
            pendingClaims,
            totalPendingClaims,
            totalDistributed
        );
    }

    /**
     * @notice Run the plain-P2P payment pipeline + emit `P2PBuySettled`
     * @dev Split out of `settleP2P` for stack depth. Delegates to
     *      {CoinAgnosticSettlement.settle} with `priorityFeeBps = 0` and
     *      no royalty (P2P / goods path), so the accounting is identical
     *      to the prior in-vault `_executeP2PSettlement`.
     * @param ctx Vault config.
     * @param intent Buyer-signed plain P2P intent.
     * @param swapPath Router path.
     * @param swapSources Router source IDs.
     * @param pendingBridge Vault's `pendingBridge` mapping.
     * @param pendingClaims Vault's `pendingClaims` mapping.
     * @param totalPendingClaims Vault's `totalPendingClaims` mapping.
     * @param totalDistributed Vault's `totalDistributed` mapping.
     * @return feesCollectedDelta `fee` (no surcharge on this path).
     */
    function _runP2PSettlement(
        P2PContext calldata ctx,
        IntentHashing.BuyP2PIntent calldata intent,
        address[] calldata swapPath,
        bytes32[] calldata swapSources,
        mapping(address => uint256) storage pendingBridge,
        mapping(address => mapping(address => uint256))
            storage pendingClaims,
        mapping(address => uint256) storage totalPendingClaims,
        mapping(address => uint256) storage totalDistributed
    ) private returns (uint256 feesCollectedDelta) {
        uint256 receiveGross;
        uint256 fee;
        (receiveGross, fee, , feesCollectedDelta) =
            CoinAgnosticSettlement.settle(
                ctx.nftSwapRouter,
                ctx.stakingPool,
                ctx.protocolTreasury,
                CoinAgnosticSettlement.SettleParams({
                    buyer: intent.buyer,
                    seller: intent.seller,
                    paymentToken: intent.paymentToken,
                    paymentAmount: intent.paymentAmount,
                    receiveToken: intent.receiveToken,
                    minReceiveAmount: intent.minReceiveAmount,
                    deadline: intent.expiresAt,
                    royaltyNftContract: address(0),
                    royaltyTokenId: 0
                }),
                CoinAgnosticSettlement.FeeRecipients({
                    referrer: intent.referrer,
                    referrer2: intent.referrer2,
                    listingNode: intent.listingNode,
                    sellingNode: intent.sellingNode,
                    priorityFeeBps: 0
                }),
                pendingBridge,
                pendingClaims,
                totalPendingClaims,
                totalDistributed,
                swapPath,
                swapSources
            );

        emit P2PBuySettled(
            intent.listingId,
            intent.listingContentHash,
            intent.buyer,
            intent.seller,
            intent.paymentToken,
            intent.paymentAmount,
            intent.receiveToken,
            receiveGross,
            fee,
            intent.referrer,
            intent.referrer2,
            intent.listingNode,
            intent.sellingNode
        );
    }

    /**
     * @notice Run the surcharge-aware payment pipeline + emit the event
     * @dev Split out of `settle` to keep its stack depth below the
     *      Solidity 16-local limit. Delegates the pull → swap → fee +
     *      surcharge → payout to {CoinAgnosticSettlement.settle}.
     * @param ctx Vault config.
     * @param intent Buyer-signed priority intent.
     * @param swapPath Router path.
     * @param swapSources Router source IDs.
     * @param pendingBridge Vault's `pendingBridge` mapping.
     * @param pendingClaims Vault's `pendingClaims` mapping.
     * @param totalPendingClaims Vault's `totalPendingClaims` mapping.
     * @param totalDistributed Vault's `totalDistributed` mapping.
     * @return feesCollectedDelta `fee + surcharge`.
     */
    function _runSettlement(
        Context calldata ctx,
        Intent calldata intent,
        address[] calldata swapPath,
        bytes32[] calldata swapSources,
        mapping(address => uint256) storage pendingBridge,
        mapping(address => mapping(address => uint256))
            storage pendingClaims,
        mapping(address => uint256) storage totalPendingClaims,
        mapping(address => uint256) storage totalDistributed
    ) private returns (uint256 feesCollectedDelta) {
        uint256 receiveGross;
        uint256 fee;
        (receiveGross, fee, , feesCollectedDelta) =
            CoinAgnosticSettlement.settle(
                ctx.nftSwapRouter,
                ctx.stakingPool,
                ctx.protocolTreasury,
                CoinAgnosticSettlement.SettleParams({
                    buyer: intent.buyer,
                    seller: intent.seller,
                    paymentToken: intent.paymentToken,
                    paymentAmount: intent.paymentAmount,
                    receiveToken: intent.receiveToken,
                    minReceiveAmount: intent.minReceiveAmount,
                    deadline: intent.expiresAt,
                    royaltyNftContract: address(0),
                    royaltyTokenId: 0
                }),
                CoinAgnosticSettlement.FeeRecipients({
                    referrer: intent.referrer,
                    referrer2: intent.referrer2,
                    listingNode: intent.listingNode,
                    sellingNode: intent.sellingNode,
                    priorityFeeBps: intent.priorityFeeBps
                }),
                pendingBridge,
                pendingClaims,
                totalPendingClaims,
                totalDistributed,
                swapPath,
                swapSources
            );

        emit P2PBuyWithPrioritySettled(
            intent.listingId,
            intent.listingContentHash,
            intent.buyer,
            intent.seller,
            intent.paymentToken,
            intent.paymentAmount,
            intent.receiveToken,
            receiveGross,
            fee,
            (receiveGross * intent.priorityFeeBps) / 10_000,
            intent.referrer,
            intent.referrer2,
            intent.listingNode,
            intent.sellingNode
        );
    }

    /**
     * @notice Stateless validation of a plain P2P intent
     * @dev Same checks as the priority path via {BuyIntentValidator}.
     * @param intent Buyer-signed plain P2P intent.
     * @param supportedPaymentTokens Vault allowlist mapping.
     * @param perTokenMinSaleAmount Vault per-token floor mapping.
     */
    function _validateP2P(
        IntentHashing.BuyP2PIntent calldata intent,
        mapping(address => bool) storage supportedPaymentTokens,
        mapping(address => uint256) storage perTokenMinSaleAmount
    ) private view {
        BuyIntentValidator.validateBuyerSellerPair(
            intent.buyer, intent.seller
        );
        BuyIntentValidator.validateTokensAmountsExpiry(
            intent.paymentToken,
            intent.receiveToken,
            intent.paymentAmount,
            intent.minReceiveAmount,
            intent.expiresAt,
            supportedPaymentTokens,
            perTokenMinSaleAmount
        );
        BuyIntentValidator.validateReferrerPair(
            intent.buyer,
            intent.seller,
            intent.referrer,
            intent.referrer2
        );
        BuyIntentValidator.validateNodes(
            intent.buyer,
            intent.seller,
            intent.referrer,
            intent.referrer2,
            intent.listingNode,
            intent.sellingNode
        );
    }

    /**
     * @notice Stateless validation of a priority intent
     * @dev Same checks as the plain P2P path (buyer/seller pair,
     *      allowlist + amount + expiry, H-01 referrer, node anti-fee-wash)
     *      via the shared {BuyIntentValidator}.
     * @param intent Buyer-signed priority intent.
     * @param supportedPaymentTokens Vault allowlist mapping.
     * @param perTokenMinSaleAmount Vault per-token floor mapping.
     */
    function _validate(
        Intent calldata intent,
        mapping(address => bool) storage supportedPaymentTokens,
        mapping(address => uint256) storage perTokenMinSaleAmount
    ) private view {
        BuyIntentValidator.validateBuyerSellerPair(
            intent.buyer, intent.seller
        );
        BuyIntentValidator.validateTokensAmountsExpiry(
            intent.paymentToken,
            intent.receiveToken,
            intent.paymentAmount,
            intent.minReceiveAmount,
            intent.expiresAt,
            supportedPaymentTokens,
            perTokenMinSaleAmount
        );
        BuyIntentValidator.validateReferrerPair(
            intent.buyer,
            intent.seller,
            intent.referrer,
            intent.referrer2
        );
        BuyIntentValidator.validateNodes(
            intent.buyer,
            intent.seller,
            intent.referrer,
            intent.referrer2,
            intent.listingNode,
            intent.sellingNode
        );
    }

    /**
     * @notice EIP-712 digest of a plain `BuyP2PIntent`
     * @param domainSeparator Vault's `_domainSeparatorV4()`.
     * @param typehash Vault's `BUY_P2P_TYPEHASH`.
     * @param intent Buyer-signed plain P2P intent.
     * @return digest Digest ready for `ECDSA.recover`.
     */
    function _hashP2P(
        bytes32 domainSeparator,
        bytes32 typehash,
        IntentHashing.BuyP2PIntent calldata intent
    ) private pure returns (bytes32 digest) {
        bytes memory encoded = abi.encode(
            typehash,
            intent.buyer,
            intent.seller,
            intent.listingContentHash,
            intent.listingId,
            intent.paymentToken,
            intent.paymentAmount,
            intent.receiveToken,
            intent.minReceiveAmount,
            intent.swapPathHash,
            intent.referrer,
            intent.referrer2,
            intent.listingNode,
            intent.sellingNode,
            intent.expiresAt,
            intent.nonce
        );
        digest = MessageHashUtils.toTypedDataHash(
            domainSeparator, keccak256(encoded)
        );
    }

    /**
     * @notice Verify the swap route matches the committed hash
     * @dev Mirrors `UnifiedFeeVault._verifySwapPathCommitment`: a zero
     *      hash requires empty arrays; otherwise
     *      `keccak256(abi.encode(path, sources, router))` must match.
     * @param expectedHash `intent.swapPathHash`.
     * @param nftSwapRouter Current router bound into the commitment.
     * @param swapPath Caller-supplied path.
     * @param swapSources Caller-supplied source IDs.
     */
    function _verifySwapPath(
        bytes32 expectedHash,
        address nftSwapRouter,
        address[] calldata swapPath,
        bytes32[] calldata swapSources
    ) private pure {
        if (expectedHash == bytes32(0)) {
            if (swapPath.length != 0 || swapSources.length != 0) {
                revert BadSwapPath();
            }
            return;
        }
        if (
            keccak256(abi.encode(swapPath, swapSources, nftSwapRouter))
                != expectedHash
        ) {
            revert BadSwapPath();
        }
    }

    /**
     * @notice EIP-712 digest of a priority intent
     * @param domainSeparator Vault's `_domainSeparatorV4()`.
     * @param typehash Vault's `BUY_P2P_WITH_PRIORITY_TYPEHASH`.
     * @param intent Buyer-signed priority intent.
     * @return digest Digest ready for `ECDSA.recover`.
     */
    function _hashIntent(
        bytes32 domainSeparator,
        bytes32 typehash,
        Intent calldata intent
    ) private pure returns (bytes32 digest) {
        bytes memory encoded = abi.encode(
            typehash,
            intent.buyer,
            intent.seller,
            intent.listingContentHash,
            intent.listingId,
            intent.paymentToken,
            intent.paymentAmount,
            intent.receiveToken,
            intent.minReceiveAmount,
            intent.swapPathHash,
            intent.referrer,
            intent.referrer2,
            intent.listingNode,
            intent.sellingNode,
            intent.expiresAt,
            intent.nonce,
            intent.priorityFeeBps
        );
        digest = MessageHashUtils.toTypedDataHash(
            domainSeparator, keccak256(encoded)
        );
    }

    /**
     * @notice EIP-712 digest of the seller priority attestation
     * @param domainSeparator Vault's `_domainSeparatorV4()`.
     * @param typehash Vault's `SELLER_PRIORITY_ATTESTATION_TYPEHASH`.
     * @param listingContentHash Listing content hash bound.
     * @param listingNode Listing-node recipient (zero allowed).
     * @param sellingNode Selling-node recipient (zero allowed).
     * @param priorityFeeBps Surcharge rate the seller consents to.
     * @return digest Digest ready for `ECDSA.recover`.
     */
    function _hashAttestation(
        bytes32 domainSeparator,
        bytes32 typehash,
        bytes32 listingContentHash,
        address listingNode,
        address sellingNode,
        uint256 priorityFeeBps
    ) private pure returns (bytes32 digest) {
        digest = MessageHashUtils.toTypedDataHash(
            domainSeparator,
            keccak256(
                abi.encode(
                    typehash,
                    listingContentHash,
                    listingNode,
                    sellingNode,
                    priorityFeeBps
                )
            )
        );
    }
}
