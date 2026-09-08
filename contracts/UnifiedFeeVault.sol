// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AccessControlUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from
    "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {PausableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from
    "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from
    "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {EIP712Upgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {ECDSA} from
    "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IFeeSwapRouter} from "./interfaces/IFeeSwapRouter.sol";
import {ERC2771ContextUpgradeable} from
    "@openzeppelin/contracts-upgradeable/metatx/ERC2771ContextUpgradeable.sol";
import {ContextUpgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import {MarketplaceFeeSplitter} from
    "./libraries/MarketplaceFeeSplitter.sol";
import {CoinAgnosticSettlement} from
    "./libraries/CoinAgnosticSettlement.sol";
import {PrioritySettlement} from
    "./libraries/PrioritySettlement.sol";
import {IntentHashing} from
    "./libraries/IntentHashing.sol";
import {NftSellerConsent} from
    "./libraries/NftSellerConsent.sol";
import {BridgeDestinationLib} from
    "./libraries/BridgeDestinationLib.sol";

/**
 * @title IOmniPrivacyBridge
 * @author OmniBazaar Team
 * @notice Subset of OmniPrivacyBridge used by UnifiedFeeVault.
 * @dev    Phase 1 V2 redesign (FIX_PRIVACY 1.7-D): the legacy v1
 *         `convertPXOMtoXOM(uint256)` synchronous L1-side flow does not exist
 *         in V2 because pXOM is now COTI-only (chain 2632500). The vault is
 *         on L1 (chain 88008), so it cannot hold or burn pXOM directly. The
 *         V2 bridge surface used for COTI→L1 redemption is
 *         `OmniPrivacyBridge_COTI.burnAndQueueUnlock(pToken, amount, l1Recipient)`,
 *         but that runs on COTI and is asynchronous (24–72h challenge window
 *         depending on tier). A synchronous L1-only `convertPXOMtoXOM` cannot
 *         exist in the V2 architecture.
 *
 *         The legacy interface is preserved here to keep the existing
 *         `convertPXOMAndBridge` ABI selector for any historical caller —
 *         the function reverts with `LegacyPrivacyBridgeRemoved` until
 *         Phase 5 redesigns the privacy-fee path (likely splitting it into
 *         an L1 lock + COTI burn-redeem with explicit async bookkeeping).
 *         The live UnifiedFeeVault proxy at 0xf702f60683c5AFd2351d0b0941c0AADEa62015e1
 *         does not currently have a `privacyBridge` address pointed at it
 *         (it was the legacy v1 0x739b44D2…, sunset), so no live caller is
 *         affected by this change.
 */
interface IOmniPrivacyBridge {
    /// @dev Legacy v1 surface kept only so the calldata shape doesn't
    ///      drift from historical clients. NOT IMPLEMENTED in V2 — see
    ///      contract-level NatSpec above.
    function convertPXOMtoXOM(uint256 amount) external;
}

// ════════════════════════════════════════════════════════════════════════
//                          UNIFIED FEE VAULT
// ════════════════════════════════════════════════════════════════════════

/**
 * @title UnifiedFeeVault
 * @author OmniBazaar Team
 * @notice Aggregates protocol fees from all OmniBazaar markets and
 *         splits them according to the universal 70/20/10 schedule
 * @dev Single collection point for fees from MinimalEscrow,
 *      DEXSettlement, RWAAMM, RWAFeeCollector, OmniFeeRouter,
 *      OmniYieldFeeCollector, OmniPredictionRouter, and any future
 *      fee-generating contracts.
 *
 * Fee Distribution (per FIX_FEE_PAYMENTS.md):
 *   70% -> ODDAO Treasury (held for periodic bridging to Optimism)
 *   20% -> StakingRewardPool (on-chain, immediate transfer)
 *   10% -> Protocol Treasury (on-chain, governance-controlled)
 *
 * Design Decisions:
 * - UUPS upgradeable: allows fee logic updates without redeployment
 * - Pausable: emergency stop capability for fee processing
 * - Multi-token: accepts XOM, USDC, or any ERC20 fee payments
 * - Permissionless distribute(): anyone can trigger the fee split
 * - Role-gated bridge: only BRIDGE_ROLE can withdraw ODDAO share
 * - Deposit whitelist: only approved fee contracts can deposit
 * - Pull pattern: recipients claim fees; reverting recipients
 *   do not block distribution (M-03 audit fix)
 * - Config changes use a propose/apply pattern (recipients, routers, token,
 *   bridge mode). RECIPIENT_CHANGE_DELAY is 0 during the Pioneer phase so the
 *   deployer-admin can propose + apply in immediate succession; the audit
 *   trail (events + two-call API) is retained (was 48h, M-02 audit fix —
 *   superseded by the Pioneer deployer-direct rule).
 * - Rescue: admin can recover non-committed tokens (M-04 audit fix)
 *
 * Safety:
 * - ReentrancyGuard on all state-changing external functions
 * - CEI pattern (checks-effects-interactions) throughout
 * - Zero-amount guards on all transfers
 * - Overflow-safe math via Solidity 0.8.x defaults
 * - Ossification support for permanent finalization
 * - UUPS upgrade restricted to DEFAULT_ADMIN_ROLE
 *
 * @custom:security-contact security@omnibazaar.com
 * @custom:deployment-note ADMIN_ROLE and DEFAULT_ADMIN_ROLE
 *      should be transferred to a multi-sig (e.g., Gnosis Safe)
 *      before mainnet launch to mitigate centralization risk.
 *      Single-key admin control is acceptable only during testnet
 *      and initial deployment phases.
 * @custom:upgrade-note For future upgrades, consider migrating
 *      DEFAULT_ADMIN_ROLE management to
 *      AccessControlDefaultAdminRulesUpgradeable to enforce
 *      two-step admin transfers with a built-in timelock.
 */
contract UnifiedFeeVault is
    AccessControlUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    ERC2771ContextUpgradeable,
    EIP712Upgradeable
{
    using SafeERC20 for IERC20;

    /// @dev AUDIT ACCEPTED (Round 6): Fee-on-transfer and rebasing tokens are not
    ///      supported. OmniCoin (XOM) is the primary token and does not have these
    ///      features. Only vetted tokens (XOM, USDC, WBTC, WETH) are whitelisted
    ///      for use in the platform. This is documented in deployment guides.

    // ════════════════════════════════════════════════════════════════════
    //                              ENUMS
    // ════════════════════════════════════════════════════════════════════

    /// @notice Strategy for bridging a token's ODDAO share
    /// @dev IN_KIND (0) bridges the original token as-is.
    ///      SWAP_TO_XOM (1) swaps the token to XOM before bridging.
    enum BridgeMode {
        IN_KIND,
        SWAP_TO_XOM
    }

    /// @notice Buyer-signed EIP-712 intent to purchase an NFT with
    ///         coin-agnostic payment and atomic on-chain auto-swap.
    /// @dev The buyer pays `paymentAmount` of `paymentToken`; the vault
    ///      atomically routes any needed swap through OmniSwapRouter
    ///      so the seller ultimately receives `receiveToken` (net of
    ///      the 1% marketplace fee). Field order and types MUST match
    ///      `BUY_NFT_TYPEHASH` exactly or buyer signatures fail.
    ///
    ///      Fields:
    ///        - `paymentToken` / `paymentAmount`: what the buyer pays
    ///        - `receiveToken` / `minReceiveAmount`: what the seller
    ///          must receive (net, after 1% marketplace fee) — slippage
    ///          floor enforced on-chain.
    ///        - `swapPathHash`: commitment to a specific swap route
    ///          picked by the wallet's IntentRouter at quote time
    ///          (`keccak256(abi.encode(path[], sources[]))`). If zero,
    ///          caller MUST pass empty path/sources and the contract
    ///          rejects (routes must be explicit).
    ///        - `referrer`/`referrer2`: two-level attribution for the
    ///          referral component of the 1% marketplace fee.
    // NOTE: the `BuyNFTIntent` and `BuyP2PIntent` structs are declared in
    // the DELEGATECALL-linked {IntentHashing} library and used DIRECTLY
    // as the `settleNftBuy` / `settleP2PBuy` / `settleP2PBuyAttested`
    // external parameters. The ABI tuple is positional, so the declaring
    // scope does NOT change the function selector or the EIP-712 struct
    // encoding — every live client signature stays valid. The big
    // `keccak256(abi.encode(typehash, fields…))` digest computation lives
    // in {IntentHashing} to keep the vault under the 24 KiB EIP-170
    // limit; the canonical `BUY_NFT_TYPEHASH` / `BUY_P2P_TYPEHASH`
    // constants remain declared in this vault as the source of truth.
    //
    // BuyNFTIntent fields (order MUST match `BUY_NFT_TYPEHASH`):
    //   buyer, seller, nftContract, nftTokenId, paymentToken,
    //   paymentAmount, receiveToken, minReceiveAmount, swapPathHash,
    //   listingId, referrer, referrer2, expiresAt, nonce.
    // BuyP2PIntent fields (order MUST match `BUY_P2P_TYPEHASH`):
    //   buyer, seller, listingContentHash, listingId, paymentToken,
    //   paymentAmount, receiveToken, minReceiveAmount, swapPathHash,
    //   referrer, referrer2, listingNode, sellingNode, expiresAt, nonce.
    // `listingNode` / `sellingNode` are accepted ONLY via
    // `settleP2PBuyAttested` (seller M-05 co-signature); `settleP2PBuy`
    // requires both zero. P2P settlement is payment-only (no on-chain
    // good/service transfer — delivery is off-chain).

    // NOTE: the packed fee-recipient struct previously declared here
    // (`FeeRecipients`) now lives in the DELEGATECALL-linked
    // {CoinAgnosticSettlement} library as
    // `CoinAgnosticSettlement.FeeRecipients` (referrer, referrer2,
    // listingNode, sellingNode, priorityFeeBps). The 3 settlement
    // entry points build that library type directly so the vault never
    // re-encodes it — this keeps the vault under the 24 KiB EIP-170
    // limit. NFT callers pass the node fields as `address(0)` and
    // `priorityFeeBps == 0` (preserving the prior ODDAO routing); P2P
    // callers pass the seller-attested nodes; the priority path passes
    // the seller-consented surcharge rate.

    // NOTE: the priority intent struct — a backward-compatible parallel
    // of `BuyP2PIntent` (all 15 fields, same order) plus a trailing
    // `priorityFeeBps` (0–300 = 0–3% of the receive-side gross) — is
    // declared as `PrioritySettlement.Intent` and used DIRECTLY as the
    // `settleP2PBuyWithPriority` external parameter. The ABI tuple
    // `(address,address,bytes32,uint256,address,uint256,address,uint256,
    // bytes32,address,address,address,address,uint256,uint256,uint256)`
    // is positional, so the struct's declaring scope does not affect the
    // function selector or the EIP-712 encoding. Settled ONLY by
    // `settleP2PBuyWithPriority`; the surcharge is skimmed from the
    // SELLER's proceeds, so that path additionally REQUIRES the seller's
    // `SellerPriorityAttestation` co-signature binding
    // `(listingContentHash, listingNode, sellingNode, priorityFeeBps)`.
    // Field order + types MUST match `BUY_P2P_WITH_PRIORITY_TYPEHASH`.

    // ════════════════════════════════════════════════════════════════════
    //                           CONSTANTS
    // ════════════════════════════════════════════════════════════════════

    /// @notice ODDAO share: 70% of all collected fees
    uint256 public constant ODDAO_BPS = 7000;

    /// @notice Staking pool share: 20% of all collected fees
    uint256 public constant STAKING_BPS = 2000;

    /// @notice Protocol treasury share: 10% of all collected fees
    uint256 public constant PROTOCOL_BPS = 1000;

    /// @notice Basis points denominator for percentage math
    uint256 public constant BPS_DENOMINATOR = 10000;

    /// @notice Role for addresses that can deposit fees
    bytes32 public constant DEPOSITOR_ROLE =
        keccak256("DEPOSITOR_ROLE");

    /// @notice Role for addresses that can bridge ODDAO funds
    bytes32 public constant BRIDGE_ROLE =
        keccak256("BRIDGE_ROLE");

    /// @notice Role for administrative operations
    bytes32 public constant ADMIN_ROLE =
        keccak256("ADMIN_ROLE");

    /// @notice Delay between proposing and applying a configuration change.
    /// @dev Zero during the Pioneer phase: the DEPLOYER EOA is the sole admin
    ///      and must be able to propose + apply a recipient / router / bridge /
    ///      token change in immediate succession, with no built-in wait (the
    ///      canonical Pioneer-phase rule bans a `propose → wait N hours → apply`
    ///      constant delay inside a functional contract). The two-call
    ///      propose/apply API and its events are retained for the audit trail;
    ///      only the enforced wait is removed. Post-Pioneer the external
    ///      timelock (OmniTimelockController) supplies any required delay when
    ///      admin authority migrates from the deployer to governance.
    uint256 public constant RECIPIENT_CHANGE_DELAY = 0;

    /// @notice Minimum sale amount for marketplace fees (M-04 Round 6)
    /// @dev Prevents rounding loss on extremely small sales.
    ///      10000 ensures totalFee >= 100, providing adequate
    ///      precision for all 70/20/10 sub-splits.
    uint256 public constant MIN_SALE_AMOUNT = 10_000;

    /// @notice Canonical EIP-712 typehash for `BuyNFTIntent`
    /// @dev Must match byte-for-byte the string hashed by wallet
    ///      clients and validators. Any deviation silently
    ///      invalidates every prior buyer signature. DO NOT edit.
    bytes32 public constant BUY_NFT_TYPEHASH = keccak256(
        "BuyNFT(address buyer,address seller,address nftContract,"
        "uint256 nftTokenId,address paymentToken,uint256 paymentAmount,"
        "address receiveToken,uint256 minReceiveAmount,"
        "bytes32 swapPathHash,uint256 listingId,address referrer,"
        "address referrer2,uint256 expiresAt,uint256 nonce)"
    );

    /// @notice Canonical EIP-712 typehash for `BuyP2PIntent`
    /// @dev MUST match byte-for-byte the string hashed by wallet clients
    ///      and validators. Any deviation silently invalidates every
    ///      prior buyer signature. DO NOT edit.
    bytes32 public constant BUY_P2P_TYPEHASH = keccak256(
        "BuyP2P(address buyer,address seller,bytes32 listingContentHash,"
        "uint256 listingId,address paymentToken,uint256 paymentAmount,"
        "address receiveToken,uint256 minReceiveAmount,"
        "bytes32 swapPathHash,address referrer,address referrer2,"
        "address listingNode,address sellingNode,"
        "uint256 expiresAt,uint256 nonce)"
    );

    /// @notice Canonical EIP-712 typehash for the seller's node
    ///         attestation (audit M-05)
    /// @dev The SELLER signs this at listing time, binding the
    ///      listing-fee node recipients to the listing content. Without
    ///      it a buyer could unilaterally redirect the listing/selling
    ///      node shares (~0.45% of every sale) to their own wallets by
    ///      signing arbitrary node addresses into the intent —
    ///      `settleP2PBuy` is permissionless, so the validator-side
    ///      listing↔intent cross-check is bypassable. No nonce/expiry:
    ///      the attestation is a standing fact bound to
    ///      `listingContentHash` (content change ⇒ new hash ⇒ new
    ///      attestation) and replaying it is idempotent attribution
    ///      data, not value movement. MUST match wallet clients
    ///      byte-for-byte. DO NOT edit.
    bytes32 public constant SELLER_NODE_ATTESTATION_TYPEHASH = keccak256(
        "SellerNodeAttestation(bytes32 listingContentHash,"
        "address listingNode,address sellingNode)"
    );

    /// @notice Maximum sale-time priority-placement surcharge: 3% (300 bps)
    /// @dev Hard cap enforced by `settleP2PBuyWithPriority`. The seller
    ///      co-signs the exact `priorityFeeBps` (`<= MAX_PRIORITY_FEE_BPS`)
    ///      so the surcharge can never exceed what the seller consented
    ///      to and the fee + surcharge stay strictly below `receiveGross`.
    uint256 public constant MAX_PRIORITY_FEE_BPS = 300;

    /// @notice Canonical EIP-712 typehash for `BuyP2PWithPriorityIntent`
    /// @dev The `BuyP2P` type string with `,uint256 priorityFeeBps`
    ///      appended before the closing `)` and the type name changed to
    ///      `BuyP2PWithPriority`. A SEPARATE typehash from
    ///      `BUY_P2P_TYPEHASH` so a buyer signature over the old type can
    ///      NEVER be replayed on the priority path (and vice versa).
    ///      MUST match wallet clients byte-for-byte. DO NOT edit.
    bytes32 public constant BUY_P2P_WITH_PRIORITY_TYPEHASH = keccak256(
        "BuyP2PWithPriority(address buyer,address seller,"
        "bytes32 listingContentHash,"
        "uint256 listingId,address paymentToken,uint256 paymentAmount,"
        "address receiveToken,uint256 minReceiveAmount,"
        "bytes32 swapPathHash,address referrer,address referrer2,"
        "address listingNode,address sellingNode,"
        "uint256 expiresAt,uint256 nonce,uint256 priorityFeeBps)"
    );

    /// @notice Canonical EIP-712 typehash for the seller's priority
    ///         surcharge attestation
    /// @dev The seller co-signs this to consent to the exact
    ///      `priorityFeeBps` skimmed from their proceeds AND to bind the
    ///      `listingNode` / `sellingNode` that receive 70/20% of the
    ///      surcharge. Modelled on `SELLER_NODE_ATTESTATION_TYPEHASH`
    ///      (M-05) with the surcharge rate added. Standing fact bound to
    ///      `listingContentHash` (no nonce/expiry; replay is idempotent
    ///      attribution + rate data, never value movement). MUST match
    ///      wallet clients byte-for-byte. DO NOT edit.
    bytes32 public constant SELLER_PRIORITY_ATTESTATION_TYPEHASH =
        keccak256(
            "SellerPriorityAttestation(bytes32 listingContentHash,"
            "address listingNode,address sellingNode,"
            "uint256 priorityFeeBps)"
        );

    /// @notice Canonical EIP-712 typehash for the seller's NFT sale
    ///         authorization
    /// @dev `settleNftBuy` is buyer-signed-only and permissionless: an
    ///      ERC-721 `setApprovalForAll(vault, true)` grant is
    ///      collection-wide operator trust, not consent to sell any
    ///      SPECIFIC token at any SPECIFIC price. Without this
    ///      attestation, any address could name an approved seller in a
    ///      self-authored `BuyNFTIntent`, pick any token that seller
    ///      owns, and force a sale at the `perTokenMinSaleAmount` dust
    ///      floor. This binds the exact item, receive currency, and
    ///      minimum proceeds the seller actually agreed to.
    ///
    ///      `nonce` is a per-`(seller, nftContract, nftTokenId)`
    ///      MONOTONIC floor (see `IntentHashing.SellerNftSale` NatSpec),
    ///      not a plain replay guard — closes a sharper variant of "no
    ///      cancel": without it, repricing an item by signing a NEW
    ///      authorization would leave every OLDER signed price still
    ///      fillable by anyone until each individually expires. A fill
    ///      OR an explicit `cancelNftSaleAuthorization` call raises the
    ///      floor, permanently invalidating every authorization at or
    ///      below it in one step, however many stale ones exist.
    ///      MUST match wallet clients byte-for-byte. DO NOT edit.
    bytes32 public constant SELLER_NFT_SALE_TYPEHASH = keccak256(
        "SellerNftSale(address seller,address nftContract,"
        "uint256 nftTokenId,address receiveToken,uint256 minReceiveAmount,"
        "uint256 expiresAt,uint256 nonce)"
    );

    // ════════════════════════════════════════════════════════════════════
    //                         STATE VARIABLES
    // ════════════════════════════════════════════════════════════════════

    /// @notice StakingRewardPool address (receives 20%)
    address public stakingPool;

    /// @notice Protocol treasury address (receives 10%)
    address public protocolTreasury;

    /// @notice ODDAO share per token, awaiting bridge to Optimism
    /// @dev token address => accumulated amount
    mapping(address => uint256) public pendingBridge;

    /// @notice Lifetime fees distributed per token (for transparency)
    /// @dev token address => total distributed amount
    mapping(address => uint256) public totalDistributed;

    /// @notice Lifetime fees bridged per token (for transparency)
    /// @dev token address => total bridged amount
    mapping(address => uint256) public totalBridged;

    /// @notice Whether the contract has been permanently ossified
    /// @dev Once true, no further upgrades are possible
    bool private _ossified;

    /// @custom:deprecated Kept for UUPS storage layout compatibility.
    ///     Was: address public pendingStakingPool (packed in slot 5
    ///     with _ossified). Removed in Pioneer Phase (no recipient
    ///     timelock). Must remain to preserve slot assignments of all
    ///     subsequent state variables.
    /// @custom:oz-renamed-from pendingStakingPool
    // solhint-disable-next-line var-name-mixedcase
    address private __deprecated_pendingStakingPool;

    /// @custom:deprecated Kept for UUPS storage layout compatibility.
    ///     Was: address public pendingProtocolTreasury (slot 6).
    /// @custom:oz-renamed-from pendingProtocolTreasury
    // solhint-disable-next-line var-name-mixedcase
    address private __deprecated_pendingProtocolTreasury;

    /// @custom:deprecated Kept for UUPS storage layout compatibility.
    ///     Was: uint256 public recipientChangeTimestamp (slot 7).
    /// @custom:oz-renamed-from recipientChangeTimestamp
    // solhint-disable-next-line var-name-mixedcase
    uint256 private __deprecated_recipientChangeTimestamp;

    /// @notice Accumulated claimable fees per recipient per token
    /// @dev M-03 audit fix: pull pattern for reverting recipients.
    ///      recipient address => token address => claimable amount
    mapping(address => mapping(address => uint256))
        public pendingClaims;

    /// @notice Total pending claims per token across all recipients
    /// @dev C-01 audit fix: tracks sum of all pendingClaims for
    ///      each token so rescueToken() and distribute() can
    ///      accurately calculate committed funds.
    ///      token address => total claimable amount
    mapping(address => uint256) public totalPendingClaims;

    // ── In-Kind / Swap-to-XOM Bridge Mode ────────────────────────

    /// @notice Per-token bridge strategy: in-kind (default) or swap
    /// @dev token address => BridgeMode enum value
    mapping(address => BridgeMode) public tokenBridgeMode;

    /// @notice IFeeSwapRouter adapter for token→XOM conversions
    address public swapRouter;

    /// @notice XOM token address (target of swap-to-XOM path)
    address public xomToken;

    /// @notice OmniPrivacyBridge address for pXOM→XOM conversions
    address public privacyBridge;

    /// @notice PrivateOmniCoin (pXOM) token address
    address public pxomToken;

    // ── Timelock: Swap Router ─────────────────────────────────────

    /// @notice Proposed swap router awaiting timelock expiry
    /// @dev H-03 audit fix: timelock on critical configuration
    address public pendingSwapRouter;

    /// @notice Timestamp when proposed swap router can be applied
    /// @dev Zero means no pending change
    uint256 public swapRouterChangeTimestamp;

    // ── Timelock: Privacy Bridge ──────────────────────────────────

    /// @notice Proposed privacy bridge awaiting timelock expiry
    /// @dev H-03 audit fix: timelock on critical configuration
    address public pendingPrivacyBridgeAddr;

    /// @notice Proposed pXOM token for pending privacy bridge change
    /// @dev H-03 audit fix: paired with pendingPrivacyBridgeAddr
    address public pendingPXOMToken;

    /// @notice Timestamp when proposed privacy bridge can be applied
    /// @dev Zero means no pending change
    uint256 public privacyBridgeChangeTimestamp;

    // ── Timelock: Ossification ────────────────────────────────────

    /// @notice Timestamp when ossification can be confirmed
    /// @dev L-01 audit fix: 48-hour propose/confirm pattern.
    ///      Zero means no pending ossification.
    uint256 public ossificationScheduledAt;

    // ── Timelock: Recipients (M-01 Round 6) ─────────────────────

    /// @notice Proposed staking pool address awaiting timelock
    /// @dev M-01 Round 6: replaces deprecated pendingStakingPool
    address public pendingNewStakingPool;

    /// @notice Proposed protocol treasury address awaiting timelock
    /// @dev M-01 Round 6: replaces deprecated pendingProtocolTreasury
    address public pendingNewProtocolTreasury;

    /// @notice Timestamp when proposed recipients can be applied
    /// @dev Zero means no pending change
    uint256 public recipientChangeTime;

    // ── Timelock: XOM Token (M-02 Round 6) ──────────────────────

    /// @notice Proposed XOM token address awaiting timelock
    /// @dev M-02 Round 6: prevents instant swap target manipulation
    address public pendingXomToken;

    /// @notice Timestamp when proposed XOM token can be applied
    /// @dev Zero means no pending change
    uint256 public xomTokenChangeTime;

    // ── Timelock: Bridge Mode (M-03 Round 6) ────────────────────

    /// @notice Token for pending bridge mode change
    /// @dev M-03 Round 6: prevents instant bridge mode manipulation
    address public pendingBridgeModeToken;

    /// @notice Proposed bridge mode awaiting timelock
    BridgeMode public pendingBridgeMode;

    /// @notice Timestamp when proposed bridge mode can be applied
    /// @dev Zero means no pending change
    uint256 public bridgeModeChangeTime;

    /// @notice Cumulative fees collected by this contract (in token wei)
    /// @dev AUDIT FIX (Round 6 FEE-AP-10): Cross-contract fee accounting.
    ///      Aggregates all fees across all tokens for a single total.
    uint256 public totalFeesCollected;

    /// @notice Pending redirect: original claimant
    /// @dev ADV-R8-05: Part of propose/apply redirect timelock
    address public pendingRedirectClaimant;

    /// @notice Pending redirect: new recipient
    /// @dev ADV-R8-05: Part of propose/apply redirect timelock
    address public pendingRedirectRecipient;

    /// @notice Pending redirect: token address
    /// @dev ADV-R8-05: Part of propose/apply redirect timelock
    address public pendingRedirectToken;

    /// @notice Pending redirect: timestamp when proposed
    /// @dev ADV-R8-05: Apply allowed after RECIPIENT_CHANGE_DELAY
    uint256 public pendingRedirectTimestamp;

    /// @notice Replay protection for NFT buy intents: digest => used.
    /// @dev Each EIP-712 `BuyNFTIntent` digest may be consumed at most
    ///      once by `settleNftBuy`. Occupies one storage slot for the
    ///      mapping itself; value storage is separate per key.
    mapping(bytes32 => bool) private _usedNftIntents;

    // ── NFT Settlement: Coin-Agnostic Auto-Swap ──────────────────

    /// @notice OmniSwapRouter adapter used for coin-agnostic NFT
    ///         settlement (buyer pays token A, seller receives token B)
    /// @dev Distinct from `swapRouter` (IFeeSwapRouter) used for ODDAO
    ///      bridge conversions. Gated by the propose/apply pattern via
    ///      `proposeNftSwapRouter` / `applyNftSwapRouter`.
    address public nftSwapRouter;

    /// @notice Allowlist of tokens accepted as `paymentToken` /
    ///         `receiveToken` in `BuyNFTIntent`
    /// @dev Admin-settable via propose/apply (delay 0 during Pioneer).
    mapping(address => bool) public supportedPaymentTokens;

    /// @notice Per-token minimum receive (net) amount before settlement
    /// @dev Replaces the single `MIN_SALE_AMOUNT` floor with a per-token
    ///      value so tokens with different decimals (6-dec USDC vs
    ///      18-dec XOM) can have appropriate dust thresholds.
    mapping(address => uint256) public perTokenMinSaleAmount;

    // ── Timelock: NFT Swap Router ────────────────────────────────

    /// @notice Proposed NFT swap router awaiting timelock expiry
    address public pendingNftSwapRouter;

    /// @notice Timestamp when proposed NFT swap router may be applied
    uint256 public nftSwapRouterChangeTime;

    // ── Timelock: Supported Payment Tokens ───────────────────────

    /// @notice Token proposed for allowlist add/remove
    address public pendingSupportedToken;

    /// @notice Whether the proposed change sets the token supported
    bool public pendingSupportedTokenFlag;

    /// @notice Timestamp when proposed allowlist change may be applied
    uint256 public supportedTokenChangeTime;

    // ── Timelock: Per-Token Min Sale Amount ──────────────────────

    /// @notice Token proposed for min-sale-amount change
    address public pendingMinSaleToken;

    /// @notice Proposed per-token minimum receive amount
    uint256 public pendingMinSaleAmount;

    /// @notice Timestamp when proposed min change may be applied
    uint256 public minSaleChangeTime;

    /// @notice Replay protection for `BuyP2PIntent` digests: digest =>
    ///         used.
    /// @dev Each EIP-712 `BuyP2PIntent` digest may be consumed at most
    ///      once by `settleP2PBuy`. Distinct from `_usedNftIntents` so a
    ///      digest for one intent type never collides with a digest for
    ///      the other (typehashes differ, but keeping the mappings
    ///      separate makes the invariant explicit and future-proofs
    ///      against any hash coincidence).
    mapping(bytes32 => bool) private _usedP2PIntents;

    /// @notice Monotonic nonce floor per `(seller, nftContract,
    ///         nftTokenId)`: `keccak256(abi.encode(seller, nftContract,
    ///         nftTokenId))` => the highest `SellerNftSale.nonce` ever
    ///         consumed or explicitly cancelled for that item.
    /// @dev `settleNftBuy` requires `auth.nonce > floor` then raises
    ///      `floor` to `auth.nonce`; `cancelNftSaleAuthorization` does
    ///      the same without a fill. Because the check is `>` (not a
    ///      used-digest boolean), raising the floor invalidates EVERY
    ///      authorization at or below it in one step — a seller who
    ///      signed several stale prices over time doesn't need to
    ///      individually name and cancel each one. Distinct from
    ///      `_usedNftIntents` (which tracks the buyer's `BuyNFTIntent`
    ///      digest, a one-shot replay guard, not a per-item floor).
    ///      `private`, no dedicated getter (both a `public` mapping's
    ///      auto-getter and a custom 3-param view measured LARGER than
    ///      omitting a getter entirely — 24 KiB EIP-170 budget). Clients
    ///      track their own last-signed nonce per item; a stale guess
    ///      only costs a `SellerAuthorizationUsed` revert, not a fund
    ///      risk. Follow-up: add a getter once other vault logic is
    ///      extracted to reclaim headroom.
    mapping(bytes32 => uint256) private _sellerNftNonceFloor;

    /// @notice Canonical ODDAO treasury that `bridgeToTreasury` and
    ///         `swapAndBridge` transfer to (VT-21 pin)
    /// @dev Previously both BRIDGE_ROLE entry points took the
    ///      destination as a pure caller parameter, so whoever held
    ///      BRIDGE_ROLE could redirect the entire ODDAO share. Now the
    ///      destination is a single admin-set slot; the caller-supplied
    ///      `bridgeReceiver` argument must equal it or the call reverts
    ///      `WrongDestination()`. Seeded in `initialize()` to
    ///      `oddaoTreasury` for fresh deploys; the upgrade path sets it
    ///      via {setBridgeDestination} (Pioneer deployer-direct — no
    ///      built-in delay). {lockBridgeDestination} latches it one-way
    ///      so it becomes immutable at the deployer→governance
    ///      handover. Setter/latch/guard logic lives in the
    ///      DELEGATECALL-linked {BridgeDestinationLib} library (EIP-170
    ///      budget). Consumes 1 storage slot from `__gap` (packs the
    ///      `address` + `bool`).
    address public bridgeDestination;

    /// @notice One-way latch: when true, `bridgeDestination` is
    ///         immutable (VT-21)
    bool public bridgeDestinationLocked;

    /// @notice Storage gap for future upgrades
    /// @dev Budget: 38 (post-M-05) - 1 new root-mapping slot
    ///      (`_sellerNftNonceFloor`) - 1 slot (VT-21
    ///      `bridgeDestination` + `bridgeDestinationLocked` packed) =
    ///      36. The OZ slot-walker (`validateUpgrade`) is the source of
    ///      truth — match it. Reduce gap by N when adding N new state
    ///      variables.
    uint256[36] private __gap;

    // ════════════════════════════════════════════════════════════════════
    //                             EVENTS
    // ════════════════════════════════════════════════════════════════════

    /// @notice Emitted when fees are deposited into the vault
    /// @param token ERC20 token address that was deposited
    /// @param amount Amount of tokens deposited
    /// @param depositor Address that deposited the fees
    event FeesDeposited(
        address indexed token,
        uint256 indexed amount,
        address indexed depositor
    );

    /// @notice Emitted when fees arrive via direct transfer (e.g., RWAAMM)
    /// @param token ERC20 token address that was notified
    /// @param amount Amount reported by the caller
    /// @param sender Address that sent the notification
    event FeesNotified(
        address indexed token,
        uint256 indexed amount,
        address indexed sender
    );

    /// @notice Emitted when accumulated fees are split 70/20/10
    /// @param token ERC20 token address that was distributed
    /// @param oddaoShare Amount allocated to ODDAO holding (70%)
    /// @param stakingShare Amount allocated to StakingRewardPool (20%)
    /// @param protocolShare Amount allocated to Protocol Treasury (10%)
    event FeesDistributed(
        address indexed token,
        uint256 indexed oddaoShare,
        uint256 indexed stakingShare,
        uint256 protocolShare
    );

    /// @notice Emitted when ODDAO funds are bridged to Optimism
    /// @param token ERC20 token address that was bridged
    /// @param amount Amount bridged
    /// @param recipient Bridge receiver address
    event FeesBridged(
        address indexed token,
        uint256 indexed amount,
        address indexed recipient
    );

    /// @notice Emitted when DEFAULT_ADMIN_ROLE moves the VT-21 pinned
    ///         bridge destination
    /// @dev Actually emitted inside the DELEGATECALL-linked
    ///      {BridgeDestinationLib}; declared here too (free — no emit
    ///      call site in the vault) purely so clients reading the
    ///      vault's own ABI can decode it.
    /// @param oldDestination The destination before the change.
    /// @param newDestination The destination after the change.
    event BridgeDestinationUpdated(
        address indexed oldDestination,
        address indexed newDestination
    );

    /// @notice Emitted when DEFAULT_ADMIN_ROLE permanently locks the
    ///         VT-21 pinned bridge destination
    /// @dev Actually emitted inside {BridgeDestinationLib}; declared
    ///      here too for the same ABI-decodability reason as
    ///      `BridgeDestinationUpdated`.
    event BridgeDestinationLatched();

    /// @notice Emitted when recipient addresses are updated
    /// @param stakingPool New staking pool address
    /// @param protocolTreasury New protocol treasury address
    event RecipientsUpdated(
        address indexed stakingPool,
        address indexed protocolTreasury
    );


    /// @notice Emitted when the contract is permanently ossified
    /// @param caller Address that triggered ossification
    event ContractOssified(address indexed caller);

    /// @notice Emitted when accidentally sent tokens are rescued
    /// @param token ERC20 token address that was rescued
    /// @param amount Amount rescued
    /// @param recipient Address receiving the rescued tokens
    event TokensRescued(
        address indexed token,
        uint256 indexed amount,
        address indexed recipient
    );

    /// @notice Emitted when a push transfer fails and is quarantined
    /// @param recipient Address that failed to receive
    /// @param token ERC20 token address
    /// @param amount Amount quarantined for pull withdrawal
    event TransferQuarantined(
        address indexed recipient,
        address indexed token,
        uint256 indexed amount
    );

    /// @notice Emitted when quarantined fees are claimed
    /// @param recipient Address claiming the fees
    /// @param token ERC20 token address
    /// @param amount Amount claimed
    event PendingClaimWithdrawn(
        address indexed recipient,
        address indexed token,
        uint256 indexed amount
    );

    /// @notice Emitted when fees are swapped to XOM and bridged
    /// @param token Original fee token that was swapped
    /// @param tokenAmount Amount of original token swapped
    /// @param xomReceived Amount of XOM received from swap
    /// @param recipient Bridge receiver address
    event FeesSwappedAndBridged(
        address indexed token,
        uint256 indexed tokenAmount,
        uint256 xomReceived,
        address indexed recipient
    );

    /// @notice Emitted when pXOM is converted to XOM via privacy bridge
    /// @param amount Amount of pXOM converted
    /// @param xomReceived Amount of XOM received
    event PXOMConverted(
        uint256 indexed amount,
        uint256 indexed xomReceived
    );

    /// @notice Emitted when a token's bridge mode is changed
    /// @param token Token whose mode was updated
    /// @param mode New bridge mode (0=IN_KIND, 1=SWAP_TO_XOM)
    event TokenBridgeModeSet(
        address indexed token,
        BridgeMode indexed mode
    );

    /// @notice Emitted when a new swap router is proposed
    /// @param router Proposed IFeeSwapRouter adapter address
    /// @param effectiveTimestamp When the change can be applied
    event SwapRouterProposed(
        address indexed router,
        uint256 indexed effectiveTimestamp
    );

    /// @notice Emitted when the swap router is updated
    /// @param oldRouter Previous IFeeSwapRouter adapter address
    /// @param newRouter New IFeeSwapRouter adapter address
    event SwapRouterUpdated(
        address indexed oldRouter,
        address indexed newRouter
    );

    /// @notice Emitted when a new privacy bridge config is proposed
    /// @param bridge Proposed OmniPrivacyBridge address
    /// @param pxom Proposed PrivateOmniCoin address
    /// @param effectiveTimestamp When the change can be applied
    event PrivacyBridgeProposed(
        address indexed bridge,
        address indexed pxom,
        uint256 indexed effectiveTimestamp
    );

    /// @notice Emitted when the privacy bridge config is updated
    /// @param oldBridge Previous OmniPrivacyBridge address
    /// @param newBridge New OmniPrivacyBridge address
    /// @param pxom New PrivateOmniCoin address
    event PrivacyBridgeUpdated(
        address indexed oldBridge,
        address indexed newBridge,
        address indexed pxom
    );

    /// @notice Emitted when the XOM token address is set
    /// @param xom New XOM token address
    event XOMTokenUpdated(address indexed xom);

    /// @notice Emitted when ossification is proposed
    /// @param effectiveTimestamp When ossification can be confirmed
    event OssificationProposed(uint256 indexed effectiveTimestamp);

    /// @notice Emitted when a recipient change is proposed (M-01 Round 6)
    /// @param stakingPool Proposed staking pool address
    /// @param protocolTreasury Proposed protocol treasury address
    /// @param effectiveTimestamp When the change can be applied
    event RecipientsProposed(
        address indexed stakingPool,
        address indexed protocolTreasury,
        uint256 indexed effectiveTimestamp
    );

    /// @notice Emitted when a XOM token change is proposed (M-02 Round 6)
    /// @param xom Proposed XOM token address
    /// @param effectiveTimestamp When the change can be applied
    event XOMTokenProposed(
        address indexed xom,
        uint256 indexed effectiveTimestamp
    );

    /// @notice Emitted when a bridge mode change is proposed (M-03 Round 6)
    /// @param token Token whose mode is being changed
    /// @param mode Proposed bridge mode
    /// @param effectiveTimestamp When the change can be applied
    event BridgeModeProposed(
        address indexed token,
        BridgeMode indexed mode,
        uint256 indexed effectiveTimestamp
    );

    /// @notice Emitted when a pending claim is redirected by admin
    /// @param originalClaimant Address that originally held the claim
    /// @param newRecipient Address receiving the redirected claim
    /// @param token ERC20 token address
    /// @param amount Amount redirected
    event ClaimRedirected(
        address indexed originalClaimant,
        address indexed newRecipient,
        address indexed token,
        uint256 amount
    );

    /// @notice Emitted when a stuck claim redirect is proposed
    /// @param originalClaimant Address that currently holds the claim
    /// @param newRecipient Proposed new recipient
    /// @param token ERC20 token of the claim
    /// @param effectiveAt Timestamp when redirect can be applied
    event RedirectStuckClaimProposed(
        address indexed originalClaimant,
        address indexed newRecipient,
        address indexed token,
        uint256 effectiveAt
    );

    /// @notice Emitted when a pending redirect proposal is cancelled
    /// @param originalClaimant Claimant whose redirect was cancelled
    event RedirectStuckClaimCancelled(
        address indexed originalClaimant
    );

    /// @notice Emitted on every successful atomic NFT buy
    /// @param listingId Off-chain listing identifier (pass-through)
    /// @param buyer Intent buyer (and signer)
    /// @param seller NFT seller who received `sellerPay`
    /// @param nftContract ERC-721 contract address
    /// @param nftTokenId Token id transferred
    /// @param paymentToken Token the buyer paid in
    /// @param paymentAmount Gross amount paid by the buyer
    /// @param receiveToken Token the seller received
    /// @param receiveGross Gross receive-side amount (pre marketplace fee)
    /// @param marketFee 1% marketplace fee in `receiveToken`
    event NFTBought(
        uint256 indexed listingId,
        address indexed buyer,
        address indexed seller,
        address nftContract,
        uint256 nftTokenId,
        address paymentToken,
        uint256 paymentAmount,
        address receiveToken,
        uint256 receiveGross,
        uint256 marketFee
    );

    /// @notice Emitted when `cancelNftSaleAuthorization` raises an
    ///         item's nonce floor, invalidating every `SellerNftSale`
    ///         authorization at or below it
    /// @param itemKey `keccak256(abi.encode(seller, nftContract,
    ///        nftTokenId))` — the `_sellerNftNonceFloor` mapping key
    /// @param seller The caller (always `msg.sender` — see
    ///        `cancelNftSaleAuthorization`)
    event NftSaleAuthorizationCancelled(
        bytes32 indexed itemKey,
        address indexed seller
    );

    /// @dev The EIP-2981 creator-royalty payout emits `RoyaltyPaid`
    ///      (`address,uint256,address,uint256`) from this vault's address
    ///      via the DELEGATECALL-linked {RoyaltyResolver} library. The
    ///      event is declared there to keep the vault under the 24 KiB
    ///      EIP-170 limit; topic0 and the emitting address are unchanged,
    ///      so off-chain indexers correlate it with the same-transaction
    ///      {NFTBought} by `nftContract`/`tokenId` exactly as before.

    /// @notice Emitted when a supported-payment-token change is proposed
    /// @param token Token whose allowlist flag is being changed
    /// @param supported Proposed flag
    /// @param effectiveTimestamp When the change may be applied
    event SupportedPaymentTokenProposed(
        address indexed token,
        bool indexed supported,
        uint256 indexed effectiveTimestamp
    );

    /// @notice Emitted when a supported-payment-token change is applied
    /// @param token Token whose allowlist flag changed
    /// @param supported New flag value
    event SupportedPaymentTokenUpdated(
        address indexed token,
        bool indexed supported
    );

    /// @notice Emitted when a per-token min sale amount change is proposed
    /// @param token Token whose min is being changed
    /// @param amount Proposed min amount
    /// @param effectiveTimestamp When the change may be applied
    event MinSaleAmountProposed(
        address indexed token,
        uint256 indexed amount,
        uint256 indexed effectiveTimestamp
    );

    /// @notice Emitted when a per-token min sale amount change is applied
    /// @param token Token whose min changed
    /// @param amount New min amount
    event MinSaleAmountUpdated(
        address indexed token,
        uint256 indexed amount
    );

    /// @notice Emitted when an NFT swap router change is proposed
    /// @param router Proposed OmniSwapRouter address
    /// @param effectiveTimestamp When the change may be applied
    event NftSwapRouterProposed(
        address indexed router,
        uint256 indexed effectiveTimestamp
    );

    /// @notice Emitted when an NFT swap router change is applied
    /// @param oldRouter Previous router
    /// @param newRouter New router
    event NftSwapRouterUpdated(
        address indexed oldRouter,
        address indexed newRouter
    );

    /// @notice Emitted on every successful atomic P2P marketplace buy
    /// @param listingId Off-chain listing identifier (pass-through)
    /// @param listingContentHash Off-chain listing content hash
    ///        (attested by the seller at listing time)
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

    // NOTE: the `P2PBuyWithPrioritySettled` event is declared in the
    // DELEGATECALL-linked {PrioritySettlement} library (which emits it
    // from this vault's address with the same topic0 + signature) to
    // keep the vault under the 24 KiB EIP-170 limit — exactly as the
    // {RoyaltyResolver} `RoyaltyPaid` event is. Off-chain indexers see
    // no difference from an in-vault emit.

    // ════════════════════════════════════════════════════════════════════
    //                          CUSTOM ERRORS
    // ════════════════════════════════════════════════════════════════════

    /// @notice Thrown when a zero address is provided
    error ZeroAddress();

    /// @notice Thrown when a zero amount is provided
    error ZeroAmount();

    /// @notice Thrown when there is nothing to distribute
    error NothingToDistribute();

    /// @notice Thrown when bridge amount exceeds pending balance
    /// @param requested Amount requested for bridging
    /// @param available Amount available for bridging
    error InsufficientPendingBalance(
        uint256 requested,
        uint256 available
    );

    /// @notice Thrown when the contract is ossified and upgrades blocked
    error ContractIsOssified();

    /// @notice Thrown when timelock delay has not elapsed
    error TimelockNotElapsed();

    /// @notice Thrown when no pending recipient change exists
    error NoPendingChange();

    /// @notice Thrown when there is nothing to claim
    error NothingToClaim();

    /// @notice Thrown when rescue would drain committed funds
    /// @param token Token address involved
    /// @param committed Amount committed (pendingBridge)
    error CannotRescueCommittedFunds(
        address token,
        uint256 committed
    );

    /// @notice Thrown when new implementation has no deployed code
    error InvalidImplementation();

    /// @notice Thrown when swapRouter is not configured
    error SwapRouterNotSet();

    /// @notice Thrown when xomToken is not configured
    error XOMTokenNotSet();

    /// @notice Thrown when swap output is below the minimum
    /// @param received Actual XOM received
    /// @param minimum Required minimum
    error InsufficientSwapOutput(
        uint256 received,
        uint256 minimum
    );

    /// @notice Thrown when pXOM→XOM conversion fails
    error PXOMConversionFailed();

    /// @notice Thrown when `convertPXOMAndBridge` is called in V2.
    /// @dev    The function exists for ABI continuity but the synchronous
    ///         L1-side pXOM→XOM path does not exist in V2 (pXOM is COTI-only).
    ///         Phase 5 will redesign with explicit async bookkeeping.
    error LegacyPrivacyBridgeRemoved();

    /// @notice Thrown when a swap/conversion deadline has expired
    error DeadlineExpired();

    /// @notice Thrown when the timelock delay has not yet expired
    error TimelockNotExpired();

    /// @notice Thrown when no pending claim exists for redirect
    error NoPendingClaim();

    /// @notice Thrown when privacy bridge is not configured
    error PrivacyBridgeNotSet();

    /// @notice Thrown when sale amount is below minimum (M-04 Round 6)
    error SaleAmountTooSmall();

    /// @notice NFT-buy intent has already expired
    error Expired();

    /// @notice Signer recovered from signature does not match
    ///         `intent.buyer`
    error BadSigner();

    /// @notice NFT-buy intent payment token is not XOM (`xomToken`)
    error BadToken();

    /// @notice NFT-buy intent lists the same address as buyer
    ///         and seller
    error SelfBuy();

    /// @notice NFT-buy intent digest has already been consumed
    error Replay();

    /// @notice Referrer address collides with buyer/seller, or the
    ///         two referrer slots collide with each other
    /// @dev Prevents fee-wash attacks where a buyer or seller would
    ///      otherwise self-credit the referral component of the fee
    error BadReferrer();

    /// @notice `settleNftBuy` called before `xomToken` was configured
    /// @dev Admin must run the existing `proposeXomToken` /
    ///      `applyXomToken` timelock sequence before any NFT buy can
    ///      settle. Kept separate from `XOMTokenNotSet` so NFT-flow
    ///      error paths are easy to distinguish in off-chain traces.
    error SettlementNotConfigured();

    /// @notice `paymentToken` or `receiveToken` is not in the allowlist
    /// @param token The offending token address
    error UnsupportedToken(address token);

    /// @notice Caller-supplied swap path does not match the committed
    ///         `swapPathHash` signed by the buyer
    error BadSwapPath();

    /// @notice Final seller pay is below `intent.minReceiveAmount`
    ///         (defense-in-depth; primary check is on the router)
    error SlippageExceeded();

    /// @notice NFT swap router has not been configured
    error NftSwapRouterNotSet();

    /// @notice A non-standard token (fee-on-transfer, rebasing, etc.) was
    ///         detected during `settleNftBuy` payment pull. The vault
    ///         refuses to settle against these tokens because the received
    ///         balance would diverge from the signed `paymentAmount` and
    ///         poison the internal accounting.
    error FeeOnTransferToken();

    /// @notice `initializeV2` invoked on a proxy that has not completed
    ///         the V1 `initialize()` boot (no staking pool configured).
    ///         Guard against accidental V2-only bootstrap of a fresh
    ///         proxy that bypasses the V1 state seeding.
    error NotInitialized();

    /// @notice `proposeMinSaleAmount` rejected: a floor below 100 would
    ///         produce `fee = amount / 100 = 0`, allowing zero-fee spam
    ///         intents to consume `_usedNftIntents` slots.
    error MinSaleAmountTooLow();

    /// @notice P2P intent `listingNode` collides with buyer,
    ///         referrer, referrer2, or sellingNode
    /// @dev Anti-fee-wash guard (mirrors H-01 for referrers).
    ///      The `listingNode == seller` case was previously also
    ///      rejected as anti-fee-wash, but was removed 2026-05-18
    ///      per founder direction: the intended use case is that a
    ///      merchant runs HER OWN listing node and imports her
    ///      eBay/etsy/etc. listings to it — in that flow the listing
    ///      node IS the seller, and earning the 70% listing-node
    ///      share is the correct payout (compensates the seller for
    ///      hosting the listing on her own infrastructure). The
    ///      remaining collisions (buyer / referrer / referrer2 /
    ///      sellingNode) still revert.
    error BadListingNode();

    /// @notice P2P intent `sellingNode` collides with buyer, seller,
    ///         referrer, or referrer2
    /// @dev Anti-fee-wash guard. The `listingNode == sellingNode` check
    ///      is on `BadListingNode` (raised on the listingNode pass so
    ///      the errors remain referential to the offending field).
    error BadSellingNode();

    /// @notice `settleP2PBuy` (unattested path) received an intent with
    ///         non-zero `listingNode` / `sellingNode`
    /// @dev Audit M-05: node fee attribution requires the seller's
    ///      co-signature. Intents carrying node addresses must settle
    ///      through `settleP2PBuyAttested`; the unattested path only
    ///      accepts zero nodes (shares route to ODDAO).
    error NodesRequireAttestation();

    /// @notice Seller node attestation signature does not recover to
    ///         `intent.seller`
    /// @dev Audit M-05. Raised by `settleP2PBuyAttested` when the
    ///      attestation over `(listingContentHash, listingNode,
    ///      sellingNode)` was not signed by the listing's seller.
    ///      Also raised by `settleP2PBuyWithPriority` when the seller's
    ///      `SellerPriorityAttestation` does not recover to
    ///      `intent.seller`. Also raised by `settleNftBuy` when
    ///      `sellerSignature` over `SellerNftSale` does not recover to
    ///      `intent.seller`.
    error BadSellerAttestation();

    /// @notice `settleP2PBuyWithPriority` intent carries a
    ///         `priorityFeeBps` above `MAX_PRIORITY_FEE_BPS` (300 = 3%)
    error PriorityFeeTooHigh();

    /// @notice `settleNftBuy`'s `sellerAuth` terms do not match the
    ///         buyer's `intent`
    /// @dev Raised when `sellerAuth.seller`/`nftContract`/`nftTokenId`/
    ///      `receiveToken` disagree with `intent`, or when
    ///      `intent.minReceiveAmount` is below the seller's
    ///      `minReceiveAmount` floor — a buyer cannot fill a listing for
    ///      a different item or at a worse price than the seller signed.
    ///      Actually thrown inside the DELEGATECALL-linked
    ///      {NftSellerConsent} library; declared here too (free — no
    ///      revert call site means no extra bytecode) purely so clients
    ///      reading the vault's own ABI can decode it.
    error SellerAuthorizationMismatch();

    /// @notice A `SellerNftSale` authorization digest was already
    ///         consumed (filled or cancelled)
    /// @dev Distinct from `Replay` (which guards `BuyNFTIntent` digests)
    ///      so the two can never collide or be confused in logs.
    ///      Actually thrown inside {NftSellerConsent}; declared here too
    ///      for the same ABI-decodability reason as
    ///      `SellerAuthorizationMismatch`.
    error SellerAuthorizationUsed();

    /// @notice Caller-supplied `bridgeReceiver` does not match the
    ///         VT-21 pinned `bridgeDestination`
    /// @dev Raised when a BRIDGE_ROLE call to `bridgeToTreasury` /
    ///      `swapAndBridge` names a receiver other than the stored
    ///      `bridgeDestination` — the caller argument can no longer
    ///      steer funds. Actually thrown inside the DELEGATECALL-linked
    ///      {BridgeDestinationLib} library; declared here too (free — no
    ///      revert call site in the vault) purely so clients reading the
    ///      vault's own ABI can decode it.
    error WrongDestination();

    /// @notice `bridgeDestination` is latched and can no longer be
    ///         changed
    /// @dev Raised by {setBridgeDestination} / `lockBridgeDestination`
    ///      once `bridgeDestinationLocked` is true. Actually thrown
    ///      inside {BridgeDestinationLib}; declared here for the same
    ///      ABI-decodability reason as `WrongDestination`.
    error BridgeDestinationLocked();

    /// @notice No `bridgeDestination` is set (unreachable after a
    ///         correct initialize/upgrade)
    /// @dev Raised when a bridge call reaches {BridgeDestinationLib}
    ///      while `bridgeDestination` is still zero — a defensive guard
    ///      so a vault upgraded without seeding its destination cannot
    ///      transfer to `address(0)`. Actually thrown inside
    ///      {BridgeDestinationLib}; declared here for the same
    ///      ABI-decodability reason as `WrongDestination`.
    error BridgeDestinationNotSet();

    // ════════════════════════════════════════════════════════════════════
    //                      CONSTRUCTOR & INITIALIZER
    // ════════════════════════════════════════════════════════════════════

    /**
     * @notice Constructor that disables initializers for the
     *         implementation contract
     * @dev Sets the trusted forwarder address as an immutable
     *      (stored in bytecode, not proxy storage). Pass address(0)
     *      to disable meta-transaction support.
     * @param trustedForwarder_ Address of the OmniForwarder
     *        contract for gasless relay
     */
    /// @dev AUDIT ACCEPTED (Round 6): The trusted forwarder address is immutable by design.
    ///      ERC-2771 forwarder immutability is standard practice (OpenZeppelin default).
    ///      Changing the forwarder post-deployment would break all existing meta-transaction
    ///      infrastructure. If the forwarder is compromised, ossify() + governance pause
    ///      provides emergency protection. A new proxy can be deployed if needed.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(
        address trustedForwarder_
    ) ERC2771ContextUpgradeable(trustedForwarder_) {
        _disableInitializers();
    }

    /**
     * @notice Initialize the UnifiedFeeVault proxy
     * @dev Called once during proxy deployment. Sets up roles and
     *      recipient addresses for the 70/20/10 split.
     *      Fee distribution ratios:
     *        ODDAO:    70% (7000 BPS) -- held for bridging
     *        Staking:  20% (2000 BPS) -- immediate transfer
     *        Protocol: 10% (1000 BPS) -- immediate transfer
     * @param admin Address granted DEFAULT_ADMIN_ROLE and ADMIN_ROLE
     * @param _stakingPool StakingRewardPool contract address (20%)
     * @param _protocolTreasury Protocol treasury address (10%)
     */
    function initialize(
        address admin,
        address _stakingPool,
        address _protocolTreasury
    ) external initializer {
        if (admin == address(0)) revert ZeroAddress();
        if (_stakingPool == address(0)) revert ZeroAddress();
        if (_protocolTreasury == address(0)) revert ZeroAddress();

        __AccessControl_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        __EIP712_init("OmniBazaar", "1");

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);
        _grantRole(BRIDGE_ROLE, admin);

        stakingPool = _stakingPool;
        protocolTreasury = _protocolTreasury;

        // VT-21: seed the pinned bridge destination to the canonical
        // ODDAO treasury. The upgrade path (this proxy is live) sets it
        // via {setBridgeDestination} — see the deploy script.
        bridgeDestination =
            0x664B6347a69A22b35348D42E4640CA92e1609378;
    }

    /**
     * @notice One-time post-upgrade initializer for coin-agnostic NFT
     *         settlement
     * @dev Seeds the `EIP712Upgradeable` domain (required for
     *      `settleNftBuy` signature verification), plus the initial
     *      OmniSwapRouter address, the XOM allowlist entry, and the
     *      default XOM per-token minimum sale amount (preserves the
     *      prior `MIN_SALE_AMOUNT = 10_000` behavior for XOM).
     *
     *      Uses `reinitializer(2)` because the original `initialize`
     *      ran at version 1. Callers MUST configure additional
     *      supported tokens (USDC, USDT, WETH, WBTC, etc.) via the
     *      `proposeSupportedPaymentToken` / `applySupportedPaymentToken`
     *      timelock after this upgrade.
     *
     *      NOTE: This function does NOT apply the timelock on the
     *      initial NFT swap router set during the upgrade — that is a
     *      one-time bootstrap. All subsequent router changes MUST go
     *      through the propose/apply pattern (delay 0 during Pioneer).
     *
     * @param _nftSwapRouter Deployed OmniSwapRouter address used to
     *        bridge payment-token to receive-token during NFT
     *        settlement. MUST be non-zero.
     * @param _xomToken Deployed OmniCoin (XOM) address. Seeded into the
     *        allowlist and used as the default `xomToken` reference.
     *        MUST be non-zero. Passing a different `_xomToken` later
     *        must go through the existing `proposeXomToken` timelock.
     */
    function initializeV2(
        address _nftSwapRouter,
        address _xomToken
    )
        external
        reinitializer(2)
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        // L-03 audit fix: `reinitializer(2)` on OZ 5.x permits V2 bootstrap
        // without ever running V1 `initialize()`. If a deploy script forgets
        // the V1 init, V2 would silently seed a proxy with no stakingPool
        // and no protocolTreasury — every fee distribution would then
        // quarantine to `address(0)`. Block it by requiring V1 state.
        if (stakingPool == address(0) || protocolTreasury == address(0)) {
            revert NotInitialized();
        }

        if (_nftSwapRouter == address(0)) revert ZeroAddress();
        if (_xomToken == address(0)) revert ZeroAddress();

        __EIP712_init("OmniBazaar", "1");

        nftSwapRouter = _nftSwapRouter;
        xomToken = _xomToken;
        supportedPaymentTokens[_xomToken] = true;
        perTokenMinSaleAmount[_xomToken] = MIN_SALE_AMOUNT;
    }

    // ════════════════════════════════════════════════════════════════════
    //                        EXTERNAL FUNCTIONS
    // ════════════════════════════════════════════════════════════════════

    /**
     * @notice Deposit fees into the vault from an approved fee contract
     * @dev Only addresses with DEPOSITOR_ROLE can call this. The caller
     *      must have approved this contract for the deposit amount.
     *      Emits the actual received amount to handle fee-on-transfer
     *      tokens correctly.
     * @param token ERC20 token address to deposit
     * @param amount Amount of tokens to deposit
     */
    function deposit(
        address token,
        uint256 amount
    ) external nonReentrant onlyRole(DEPOSITOR_ROLE) whenNotPaused {
        if (token == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        address caller = _msgSender();
        uint256 balBefore =
            IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(
            caller, address(this), amount
        );
        uint256 actualReceived =
            IERC20(token).balanceOf(address(this)) - balBefore;

        emit FeesDeposited(token, actualReceived, caller);
    }

    /**
     * @notice Notify the vault that fees arrived via direct transfer
     * @dev M-01 audit fix: RWAAMM sends fees via direct safeTransfer
     *      bypassing deposit(). This function emits FeesNotified so
     *      off-chain indexers can track all fee inflows. Restricted
     *      to DEPOSITOR_ROLE to prevent spoofed notifications from
     *      polluting the audit trail.
     * @param token ERC20 token address that was transferred
     * @param amount Amount that was transferred
     */
    function notifyDeposit(
        address token,
        uint256 amount
    ) external onlyRole(DEPOSITOR_ROLE) {
        if (token == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        emit FeesNotified(token, amount, _msgSender());
    }

    /**
     * @notice Split accumulated fees for a token using 70/20/10
     * @dev Permissionless: anyone can trigger distribution. This
     *      encourages timely fee processing without relying on
     *      a centralized caller.
     *
     *      The 70% ODDAO share stays in the vault, tracked in
     *      pendingBridge[token], until bridgeToTreasury() is called.
     *
     *      The 20% and 10% shares are pushed to stakingPool and
     *      protocolTreasury respectively. If a push fails (recipient
     *      reverts), the share is quarantined in pendingClaims for
     *      later pull withdrawal via claimPending() (M-03 audit fix).
     *
     *      Fee Distribution Ratios:
     *        ODDAO:    70% (7000 BPS)
     *        Staking:  20% (2000 BPS)
     *        Protocol: 10% (1000 BPS, remainder to avoid dust loss)
     * @param token ERC20 token address to distribute
     */
    function distribute(
        address token
    ) external nonReentrant whenNotPaused {
        if (token == address(0)) revert ZeroAddress();

        uint256 balance = IERC20(token).balanceOf(address(this));
        // H-01 audit fix: subtract totalPendingClaims to avoid
        // double-counting claimable amounts as distributable.
        uint256 distributable = balance
            - pendingBridge[token]
            - totalPendingClaims[token];

        if (distributable == 0) revert NothingToDistribute();

        // L-03 audit fix: skip dust amounts that would break
        // the 70/20/10 split due to integer rounding.
        if (distributable < 10) return;

        // AUDIT FIX (Round 6 FEE-AP-10): Cross-contract fee accounting.
        totalFeesCollected += distributable;

        // The 70/20/10 ODDAO / staking / protocol split (incl. the M-03
        // quarantine-safe pushes for reverting recipients) lives in the
        // linked library so the vault stays under the 24 KiB EIP-170
        // limit. Storage writes target the vault's slots via DELEGATECALL.
        (
            uint256 oddaoShare,
            uint256 stakingShare,
            uint256 protocolShare
        ) = MarketplaceFeeSplitter.distributeBalance(
                token,
                distributable,
                pendingBridge,
                pendingClaims,
                totalPendingClaims,
                totalDistributed,
                stakingPool,
                protocolTreasury
            );

        emit FeesDistributed(
            token, oddaoShare, stakingShare, protocolShare
        );
    }

    /**
     * @notice Claim quarantined fees that failed to push
     * @dev M-03 audit fix: pull pattern for reverting recipients.
     *      Only the intended recipient can claim their quarantined
     *      fees.
     * @param token ERC20 token address to claim
     */
    function claimPending(
        address token
    ) external nonReentrant {
        address caller = _msgSender();
        uint256 amount = pendingClaims[caller][token];
        if (amount == 0) revert NothingToClaim();

        // C-01 audit fix: decrement global tracker before transfer
        pendingClaims[caller][token] = 0;
        totalPendingClaims[token] -= amount;

        IERC20(token).safeTransfer(caller, amount);

        emit PendingClaimWithdrawn(caller, token, amount);
    }

    // ════════════════════════════════════════════════════════════════════
    //                   MARKETPLACE FEE SETTLEMENT
    // ════════════════════════════════════════════════════════════════════

    /**
     * @notice Deposit and distribute a marketplace transaction fee
     * @dev Calculates the 1% marketplace fee split on-chain:
     *      - 0.25% transaction fee: 70% ODDAO, 20% staking pool,
     *        10% protocol treasury
     *      - 0.50% referral fee: 70% referrer, 20% L2 referrer, 10%
     *        ODDAO
     *      - 0.25% listing fee: 70% listing node, 20% selling node,
     *        10% ODDAO
     *
     *      Caller must have DEPOSITOR_ROLE and have approved this
     *      contract for the fee amount (1% of saleAmount in XOM).
     *
     *      TRUST BOUNDARY (VT-20): DEPOSITOR_ROLE is granted ONLY to
     *      fee-collecting CONTRACTS (the 7 live fee contracts — see
     *      deployments/mainnet.json), never to an EOA, so the
     *      caller-named attribution fields (`referrer`, `referrerL2`,
     *      `listingNode`, `sellingNode`) are not an EOA-reachable
     *      surface. The only live caller of this function is
     *      `MinimalEscrow`, which derives those fields from the
     *      buyer-validated marketplace listing — a zero node routes its
     *      share to ODDAO and an unlisted referrer cannot be invented
     *      by the caller. On the P2P path the attribution is further
     *      bound by the buyer's EIP-712 `BuyP2PIntent` signature
     *      (`settleP2PBuy`, or `settleP2PBuyAttested` which additionally
     *      requires the seller's node attestation) — a depositor cannot
     *      mint referral or node rewards it is not entitled to.
     *      Should a new depositor ever be added, it must uphold the
     *      same property: attribution fields are data, not credentials.
     *
     * @param token XOM token address (fee currency)
     * @param saleAmount Total sale amount (fee calculated as 1%)
     * @param referrer Referrer who referred the seller (zero if none)
     * @param referrerL2 Second-level referrer (zero if none)
     * @param listingNode Node where listing was created
     * @param sellingNode Node where buyer is shopping
     */
    function depositMarketplaceFee(
        address token,
        uint256 saleAmount,
        address referrer,
        address referrerL2,
        address listingNode,
        address sellingNode
    ) external nonReentrant onlyRole(DEPOSITOR_ROLE) whenNotPaused {
        if (token == address(0)) revert ZeroAddress();
        if (saleAmount == 0) revert ZeroAmount();
        // M-04 Round 6: Reject sub-dust sales that lose
        // precision in the 70/20/10 sub-splits
        if (saleAmount < MIN_SALE_AMOUNT) {
            revert SaleAmountTooSmall();
        }

        // Total fee = 1% of sale amount
        uint256 totalFee = saleAmount / 100;
        if (totalFee == 0) revert ZeroAmount();

        // H-01 audit fix: use _msgSender() for ERC-2771 meta-tx support
        address caller = _msgSender();

        // M-02 audit fix: balance-before/after for fee-on-transfer
        uint256 balBefore =
            IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(
            caller, address(this), totalFee
        );
        uint256 actualFee =
            IERC20(token).balanceOf(address(this)) - balBefore;

        _distributeMarketplaceFee(
            token,
            actualFee,
            referrer,
            referrerL2,
            listingNode,
            sellingNode
        );

        emit FeesDeposited(token, actualFee, caller);
    }

    // ════════════════════════════════════════════════════════════════════
    //                  NFT MARKETPLACE ATOMIC BUY
    // ════════════════════════════════════════════════════════════════════

    /**
     * @notice Atomically settle a buyer-signed coin-agnostic
     *         `BuyNFTIntent`
     * @dev Execution order (CEI):
     *        1. Stateless guards (xomToken configured, per-token min,
     *           allowlist, zero-address, buyer != seller, expiry,
     *           H-01 referrer anti-fee-wash).
     *        2. EIP-712 signature verification.
     *        3. Replay guard (mark digest BEFORE any external call).
     *        4. Swap-path commitment check (matches signed
     *           `swapPathHash`).
     *        5. Pull `paymentAmount` of `paymentToken` from buyer.
     *        6. If `paymentToken == receiveToken` — skip swap;
     *           else — call OmniSwapRouter with the signed path.
     *        7. Run the 70/20/10 marketplace fee split on 1% of the
     *           receive-token gross amount (`_distributeMarketplaceFee`).
     *        8. Pay seller `sellerPay` in `receiveToken`.
     *        9. Transfer NFT from seller to buyer atomically.
     *        10. Emit `NFTBought`.
     *
     *      `ReentrancyGuard` protects against hostile
     *      `onERC721Received` hooks. Any revert unwinds everything.
     *
     *      Caller does NOT need `DEPOSITOR_ROLE` — the buyer's
     *      signature authenticates; relayers / gasless forwarders
     *      submit on the buyer's behalf.
     *
     *      Requires `sellerAuth` — the seller's own EIP-712 consent
     *      (`SELLER_NFT_SALE_TYPEHASH`) to sell THIS token for at least
     *      `sellerAuth.minReceiveAmount` of `sellerAuth.receiveToken`.
     *      `intent` is otherwise entirely buyer-authored, and an ERC-721
     *      `setApprovalForAll` grant is collection-wide operator trust,
     *      not per-sale price consent — without this check any address
     *      could name an approved seller and force a sale at the dust
     *      floor.
     *
     * @param intent The buyer-signed coin-agnostic intent.
     * @param signature EIP-712 65-byte r/s/v signature.
     * @param swapPath Router path (`path[]`) — MUST match
     *        `keccak256(abi.encode(swapPath, swapSources))` ==
     *        `intent.swapPathHash`. Pass empty array only when the
     *        intent signals a zero-swap case (`paymentToken ==
     *        receiveToken` AND `swapPathHash == bytes32(0)`).
     * @param swapSources Router source IDs (`sources[]`) — one per hop.
     * @param sellerAuth The seller-signed authorization for this exact
     *        item + minimum proceeds.
     * @param sellerSignature Seller's EIP-712 65-byte r/s/v signature
     *        over `sellerAuth` (`SELLER_NFT_SALE_TYPEHASH`).
     */
    function settleNftBuy(
        IntentHashing.BuyNFTIntent calldata intent,
        bytes calldata signature,
        address[] calldata swapPath,
        bytes32[] calldata swapSources,
        IntentHashing.SellerNftSale calldata sellerAuth,
        bytes calldata sellerSignature
    ) external nonReentrant whenNotPaused {
        if (xomToken == address(0)) revert SettlementNotConfigured();

        // ─── Seller consent: the specific item + minimum proceeds ──
        // Delegated to {NftSellerConsent} (DELEGATECALL-linked, EIP-170
        // budget — see the library's NatSpec). Marks the authorization
        // consumed BEFORE returning, matching the CEI discipline of the
        // buyer-intent replay mark below.
        NftSellerConsent.verifyAndConsume(
            sellerAuth,
            sellerSignature,
            intent.seller,
            intent.nftContract,
            intent.nftTokenId,
            intent.receiveToken,
            intent.minReceiveAmount,
            _sellerNftNonceFloor
        );

        // Delegated to {NftSellerConsent} — see the NOTE below.
        NftSellerConsent.validateIntent(
            intent.buyer,
            intent.seller,
            intent.nftContract,
            intent.paymentToken,
            intent.receiveToken,
            intent.paymentAmount,
            intent.minReceiveAmount,
            intent.expiresAt,
            intent.referrer,
            intent.referrer2,
            supportedPaymentTokens,
            perTokenMinSaleAmount
        );

        // ─── Signature verification ───────────────────────────────
        bytes32 digest = _hashNftIntent(intent);
        address signer = ECDSA.recover(digest, signature);
        if (signer != intent.buyer) revert BadSigner();

        // ─── Replay protection: mark BEFORE any external call ─────
        if (_usedNftIntents[digest]) revert Replay();
        _usedNftIntents[digest] = true;

        // ─── Swap-path commitment (delegated — see NOTE below) ─────
        NftSellerConsent.verifySwapPathCommitment(
            intent.swapPathHash, swapPath, swapSources, nftSwapRouter
        );

        // ─── Shared coin-agnostic settlement primitive ────────────
        // NFT flow does NOT model listing/selling nodes — their shares
        // route to ODDAO via the zero-address path in
        // `_distributeMarketplaceFee`. P2P flow threads real nodes.
        CoinAgnosticSettlement.FeeRecipients memory recipients =
            CoinAgnosticSettlement.FeeRecipients({
            referrer: intent.referrer,
            referrer2: intent.referrer2,
            listingNode: address(0),
            sellingNode: address(0),
            priorityFeeBps: 0
        });
        (uint256 receiveGross, uint256 fee,) =
            _settleCoinAgnosticBuy(
                intent.buyer,
                intent.seller,
                intent.paymentToken,
                intent.paymentAmount,
                intent.receiveToken,
                intent.minReceiveAmount,
                recipients,
                swapPath,
                swapSources,
                intent.expiresAt,
                intent.nftContract,
                intent.nftTokenId
            );

        // ─── NFT transfer (atomic with payment) ───────────────────
        IERC721(intent.nftContract).safeTransferFrom(
            intent.seller, intent.buyer, intent.nftTokenId
        );

        emit NFTBought(
            intent.listingId,
            intent.buyer,
            intent.seller,
            intent.nftContract,
            intent.nftTokenId,
            intent.paymentToken,
            intent.paymentAmount,
            intent.receiveToken,
            receiveGross,
            fee
        );
    }

    // ════════════════════════════════════════════════════════════════════
    //               P2P MARKETPLACE ATOMIC BUY (SIBLING)
    // ════════════════════════════════════════════════════════════════════

    /**
     * @notice Atomically settle a buyer-signed coin-agnostic
     *         `BuyP2PIntent`
     * @dev Sibling to `settleNftBuy`. Reuses the audited
     *      `_settleCoinAgnosticBuy` helper, the same EIP-712 domain,
     *      and the same replay-protection and swap-path-commitment
     *      logic. Differences versus the NFT flow:
     *        - No NFT transfer — goods/services delivery is off-chain.
     *        - `listingNode` / `sellingNode` MUST be zero on this
     *          path (audit M-05): node fee attribution requires the
     *          seller's co-signature via `settleP2PBuyAttested`. With
     *          zero nodes the listing-fee sub-split (70% listing /
     *          20% selling / 10% ODDAO) routes entirely to ODDAO via
     *          the zero-address path in `_distributeMarketplaceFee`.
     *        - Replay is tracked in a separate `_usedP2PIntents`
     *          mapping, so the same digest space never collides with
     *          NFT intents (different typehashes already guarantee
     *          distinct digests; separate storage makes the invariant
     *          explicit).
     *
     *      Execution order (CEI):
     *        1. Stateless guards (`xomToken` configured; allowlist;
     *           zero-address; buyer != seller; expiry; anti-fee-wash
     *           referrer AND node checks; min receive floor).
     *        2. Swap-path commitment (binds `nftSwapRouter`).
     *        3. EIP-712 signature verification.
     *        4. Replay guard — mark digest BEFORE any external call.
     *        5. Shared `_settleCoinAgnosticBuy` primitive (pull →
     *           optional swap → 1% fee split → seller pay).
     *        6. Emit `P2PBuySettled`.
     *
     *      Caller does NOT need `DEPOSITOR_ROLE` — the buyer's
     *      signature authenticates; relayers / gasless forwarders
     *      submit on the buyer's behalf.
     *
     * @param intent The buyer-signed P2P intent.
     * @param signature EIP-712 65-byte r/s/v signature.
     * @param swapPath Router path — MUST match the committed
     *        `keccak256(abi.encode(swapPath, swapSources, nftSwapRouter))`
     *        in `intent.swapPathHash`. Pass empty when the intent is a
     *        same-token fast path (`paymentToken == receiveToken` AND
     *        `swapPathHash == bytes32(0)`).
     * @param swapSources Router source IDs (`sources[]`) — one per hop.
     */
    function settleP2PBuy(
        IntentHashing.BuyP2PIntent calldata intent,
        bytes calldata signature,
        address[] calldata swapPath,
        bytes32[] calldata swapSources
    ) external nonReentrant whenNotPaused {
        if (xomToken == address(0)) revert SettlementNotConfigured();

        // The shared plain-P2P orchestration (node gating → validation →
        // swap-path commitment → buyer signature → replay mark →
        // settlement → `P2PBuySettled`) lives in the DELEGATECALL-linked
        // {PrioritySettlement} library to keep the vault under the 24 KiB
        // EIP-170 limit. `requireAttestation = false` rejects any
        // non-zero node (M-05); an empty `sellerNodeAttestation` is
        // passed since none is needed on the unattested path.
        totalFeesCollected += PrioritySettlement.settleP2P(
            _p2pContext(false),
            intent,
            signature,
            "",
            swapPath,
            swapSources,
            _usedP2PIntents,
            supportedPaymentTokens,
            perTokenMinSaleAmount,
            pendingBridge,
            pendingClaims,
            totalPendingClaims,
            totalDistributed
        );
    }

    /**
     * @notice Atomically settle a buyer-signed `BuyP2PIntent` whose
     *         listing/selling node attribution is co-signed by the
     *         seller (audit M-05)
     * @dev Identical to `settleP2PBuy` plus one extra verification:
     *      `sellerAttestation` must be the seller's EIP-712 signature
     *      over `SellerNodeAttestation(listingContentHash, listingNode,
     *      sellingNode)` (same domain as the buy intents). This binds
     *      the node fee recipients to the seller's listing instead of
     *      the buyer's word — `settleP2PBuy`-style permissionless
     *      submission can no longer redirect the ~0.45% node shares.
     *
     *      The attestation is standing (no nonce / expiry): it is
     *      created once at listing time, bound to the listing content
     *      hash, and idempotent — replaying it only re-states the same
     *      attribution fact. Zero nodes are also accepted here (an
     *      attested "no nodes" listing settles like the legacy path).
     *
     *      Caller does NOT need `DEPOSITOR_ROLE` — the buyer's
     *      signature authenticates; relayers / gasless forwarders
     *      submit on the buyer's behalf.
     *
     * @param intent The buyer-signed P2P intent.
     * @param signature Buyer's EIP-712 65-byte r/s/v signature.
     * @param sellerAttestation Seller's EIP-712 signature over
     *        `(intent.listingContentHash, intent.listingNode,
     *        intent.sellingNode)` using
     *        `SELLER_NODE_ATTESTATION_TYPEHASH`.
     * @param swapPath Router path — same contract as `settleP2PBuy`.
     * @param swapSources Router source IDs — one per hop.
     */
    function settleP2PBuyAttested(
        IntentHashing.BuyP2PIntent calldata intent,
        bytes calldata signature,
        bytes calldata sellerAttestation,
        address[] calldata swapPath,
        bytes32[] calldata swapSources
    ) external nonReentrant whenNotPaused {
        if (xomToken == address(0)) revert SettlementNotConfigured();

        // Same shared {PrioritySettlement} orchestration as
        // `settleP2PBuy` with `requireAttestation = true`: the library
        // recovers `sellerAttestation` over
        // `SELLER_NODE_ATTESTATION_TYPEHASH` and requires it ==
        // `intent.seller` before settling (M-05). Behaviour is
        // byte-for-byte the prior in-vault path.
        totalFeesCollected += PrioritySettlement.settleP2P(
            _p2pContext(true),
            intent,
            signature,
            sellerAttestation,
            swapPath,
            swapSources,
            _usedP2PIntents,
            supportedPaymentTokens,
            perTokenMinSaleAmount,
            pendingBridge,
            pendingClaims,
            totalPendingClaims,
            totalDistributed
        );
    }

    /**
     * @notice Atomically settle a buyer-signed `BuyP2PWithPriorityIntent`
     *         carrying a seller-consented priority-placement surcharge
     * @dev Backward-compatible parallel of `settleP2PBuyAttested`. The
     *      surcharge (`intent.priorityFeeBps`, 0–300 bps) is skimmed from
     *      the SELLER's proceeds and routed 70/20/10 listing/selling/ODDAO
     *      via `MarketplaceFeeSplitter.distributePriority` AFTER the normal
     *      1% fee split — the existing `settleP2PBuy`/`settleNftBuy`
     *      accounting is untouched.
     *
     *      Because the surcharge reduces the seller's net, the seller MUST
     *      co-sign `sellerPriorityAttestation` over
     *      `SellerPriorityAttestation(listingContentHash, listingNode,
     *      sellingNode, priorityFeeBps)` (recovered signer == intent.seller).
     *      This binds the rate AND the node recipients to the listing, so a
     *      buyer cannot inflate the surcharge or redirect the node shares.
     *
     *      CEI: cap check → buyer signature → seller attestation → replay
     *      mark (BEFORE external calls) → shared `_settleCoinAgnosticBuy`
     *      primitive (now surcharge-aware) → event.
     *
     * @param intent The buyer-signed priority P2P intent.
     * @param signature Buyer's EIP-712 65-byte r/s/v signature over
     *        `BUY_P2P_WITH_PRIORITY_TYPEHASH` (an old `BuyP2P` signature
     *        does NOT verify — distinct typehash).
     * @param sellerPriorityAttestation Seller's EIP-712 signature over
     *        `SELLER_PRIORITY_ATTESTATION_TYPEHASH`.
     * @param swapPath Router path matching `intent.swapPathHash`.
     * @param swapSources Router source IDs — one per hop.
     */
    function settleP2PBuyWithPriority(
        PrioritySettlement.Intent calldata intent,
        bytes calldata signature,
        bytes calldata sellerPriorityAttestation,
        address[] calldata swapPath,
        bytes32[] calldata swapSources
    ) external nonReentrant whenNotPaused {
        if (xomToken == address(0)) revert SettlementNotConfigured();

        // The full priority orchestration (cap check → validation →
        // swap-path commitment → buyer signature → seller attestation →
        // replay mark → surcharge-aware settlement → event) lives in the
        // DELEGATECALL-linked {PrioritySettlement} library to keep the
        // vault under the 24 KiB EIP-170 limit. It runs in this vault's
        // storage context (replay mark, fee distribution, seller payout
        // all land here; the event emits from this address) and returns
        // the `fee + surcharge` delta added to `totalFeesCollected`. The
        // intent is passed straight through (the external param IS the
        // library's `Intent` type — same ABI tuple, no re-encode).
        totalFeesCollected += PrioritySettlement.settle(
            PrioritySettlement.Context({
                domainSeparator: _domainSeparatorV4(),
                intentTypehash: BUY_P2P_WITH_PRIORITY_TYPEHASH,
                attestationTypehash:
                    SELLER_PRIORITY_ATTESTATION_TYPEHASH,
                nftSwapRouter: nftSwapRouter,
                stakingPool: stakingPool,
                protocolTreasury: protocolTreasury,
                maxPriorityFeeBps: MAX_PRIORITY_FEE_BPS
            }),
            intent,
            signature,
            sellerPriorityAttestation,
            swapPath,
            swapSources,
            _usedP2PIntents,
            supportedPaymentTokens,
            perTokenMinSaleAmount,
            pendingBridge,
            pendingClaims,
            totalPendingClaims,
            totalDistributed
        );
    }

    /**
     * @notice Check whether a P2P-buy intent digest has been used
     * @dev Used by wallet clients and indexers to detect already
     *      settled intents before attempting to submit them.
     * @param intentHash EIP-712 digest of the `BuyP2PIntent`
     *        (`ethers.TypedDataEncoder.hash` with `BUY_P2P_TYPEHASH`
     *        types over this vault's domain).
     * @return True if the digest has been consumed by `settleP2PBuy`.
     */
    function isP2PIntentUsed(
        bytes32 intentHash
    ) external view returns (bool) {
        return _usedP2PIntents[intentHash];
    }

    // NOTE: the `hashP2PIntent` / `hashNftIntent` external view
    // wrappers were removed in the M-05 upgrade to keep the contract
    // under the 24,576-byte code-size limit. No production caller
    // existed — clients compute the identical digest locally via
    // `ethers.TypedDataEncoder.hash(domain, types, intent)`.

    /**
     * @notice Check whether an NFT-buy intent digest has been used
     * @dev Used by wallet clients and indexers to detect already
     *      settled intents before attempting to submit them.
     * @param intentHash EIP-712 digest of the `BuyNFTIntent`
     *        (`ethers.TypedDataEncoder.hash` with `BUY_NFT_TYPEHASH`
     *        types over this vault's domain).
     * @return True if the digest has been consumed by `settleNftBuy`.
     */
    function isNftIntentUsed(
        bytes32 intentHash
    ) external view returns (bool) {
        return _usedNftIntents[intentHash];
    }

    /**
     * @notice Raise the nonce floor for one of the caller's own items to
     *         `block.timestamp`, invalidating every `SellerNftSale`
     *         authorization signed up to now in one call.
     * @dev No signature needed — `msg.sender` IS the seller being acted
     *      on, matching the `(seller, nftContract, nftTokenId)`-keyed
     *      floor. Uses `block.timestamp` (not a caller-supplied value)
     *      so this stays a single-argument call and pairs exactly with
     *      the recommended client nonce source (current unix time —
     *      see `IntentHashing.SellerNftSale` NatSpec): any authorization
     *      the seller signs AFTER calling this still has a nonce greater
     *      than the new floor and remains fillable, so cancelling never
     *      blocks a fresh relist. A no-op call (two cancels in the same
     *      block, or a floor already ahead of `block.timestamp`) is a
     *      silent return, not a revert — it's an expected timing
     *      coincidence, not a caller bug.
     * @param nftContract Collection address.
     * @param nftTokenId Token id.
     */
    function cancelNftSaleAuthorization(
        address nftContract,
        uint256 nftTokenId
    ) external {
        bytes32 itemKey =
            keccak256(abi.encode(msg.sender, nftContract, nftTokenId));
        // solhint-disable-next-line not-rely-on-time, gas-strict-inequalities
        if (block.timestamp <= _sellerNftNonceFloor[itemKey]) return;
        // solhint-disable-next-line not-rely-on-time
        _sellerNftNonceFloor[itemKey] = block.timestamp;
        emit NftSaleAuthorizationCancelled(itemKey, msg.sender);
    }

    /* solhint-disable func-name-mixedcase */
    /**
     * @notice Expose the EIP-712 domain separator used by
     *         `BuyNFTIntent` and `BuyP2PIntent` signatures
     * @dev Wallets verify signatures locally before broadcasting,
     *      and EIP-712-compliant dApps may display the domain. Both
     *      NFT and P2P intents use the same domain separator
     *      (`name = "OmniBazaar"`, `version = "1"`), so the NFT-
     *      named accessor is canonical for both flows.
     * @return domainSeparator The current domain separator hash.
     */
    function BUY_NFT_DOMAIN_SEPARATOR()
        external
        view
        returns (bytes32 domainSeparator)
    {
        domainSeparator = _domainSeparatorV4();
    }
    /* solhint-enable func-name-mixedcase */

    // ════════════════════════════════════════════════════════════════════
    //                     FEE BREAKDOWN VIEW FUNCTIONS
    // ════════════════════════════════════════════════════════════════════

    /**
     * @notice Bridge accumulated ODDAO share to the pinned ODDAO
     *         treasury
     * @dev Only BRIDGE_ROLE can call. VT-21: the destination is the
     *      STORED `bridgeDestination` (admin-set, one-way-latchable) —
     *      the caller-supplied `bridgeReceiver` argument is retained
     *      only for ABI stability and MUST equal it or the call reverts
     *      `WrongDestination()`. BRIDGE_ROLE can no longer redirect the
     *      ODDAO share to an arbitrary address. The bridge operator is
     *      responsible for completing any cross-chain transfer.
     * @param token ERC20 token to bridge
     * @param amount Amount to bridge (must be <= pendingBridge)
     * @param bridgeReceiver Must equal `bridgeDestination()` (pinned)
     */
    function bridgeToTreasury(
        address token,
        uint256 amount,
        address bridgeReceiver
    ) external nonReentrant onlyRole(BRIDGE_ROLE) whenNotPaused {
        // VT-21: the full body (assertDestination + pending/totalBridged
        // accounting + safeTransfer + FeesBridged) lives in the
        // DELEGATECALL-linked {BridgeDestinationLib} for the EIP-170
        // budget. The reentrancy/role/pause guards stay here on the stub.
        BridgeDestinationLib.bridgeToTreasury(
            token,
            amount,
            bridgeReceiver,
            bridgeDestination,
            pendingBridge,
            totalBridged
        );
    }

    // ════════════════════════════════════════════════════════════════════
    //                         ADMIN FUNCTIONS
    // ════════════════════════════════════════════════════════════════════

    /**
     * @notice Set the pinned ODDAO treasury that `bridgeToTreasury`
     *         and `swapAndBridge` transfer to (VT-21)
     * @dev Only DEFAULT_ADMIN_ROLE. Reverts `BridgeDestinationLocked()`
     *      once {lockBridgeDestination} has been called (one-way) and
     *      `ZeroAddress()` for the zero address. NO built-in delay:
     *      during Pioneer the DEPLOYER EOA is sole DEFAULT_ADMIN_ROLE
     *      and this is an immediate deployer-direct setter (canonical
     *      Pioneer rule bans a propose→wait→apply constant delay inside
     *      a functional contract); the one-way latch is the
     *      "immutable at handover" mechanism, not a timelock. The logic
     *      runs in the DELEGATECALL-linked {BridgeDestinationLib} to
     *      keep the vault under the 24 KiB EIP-170 limit.
     * @param _bridgeDestination The new pinned destination. MUST be
     *        non-zero.
     */
    function setBridgeDestination(
        address _bridgeDestination
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        bridgeDestination = BridgeDestinationLib.setDestination(
            bridgeDestination,
            bridgeDestinationLocked,
            _bridgeDestination
        );
    }

    /**
     * @notice Permanently latch `bridgeDestination` so it can never be
     *         changed again (VT-21)
     * @dev Only DEFAULT_ADMIN_ROLE. One-way: once true,
     *      `bridgeDestinationLocked` can never go back to false, and
     *      {setBridgeDestination} reverts `BridgeDestinationLocked()`.
     *      Intended to be called at the deployer→governance handover to
     *      make the destination immutable without an external timelock.
     *      Reverts if the latch is already set. The logic runs in
     *      {BridgeDestinationLib} for the same EIP-170 reason as
     *      {setBridgeDestination}.
     */
    function lockBridgeDestination()
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        // Guard: never latch a zero destination — the latch is one-way, so a
        // premature lock on an unseeded destination would brick the bridge
        // permanently (audit VT-21 F2).
        if (bridgeDestination == address(0)) {
            revert BridgeDestinationNotSet();
        }
        bridgeDestinationLocked = BridgeDestinationLib.lock(
            bridgeDestinationLocked
        );
    }

    /**
     * @notice Propose new staking pool and protocol treasury
     *         addresses with timelock (M-01 Round 6)
     * @dev Queues the change via propose/apply (RECIPIENT_CHANGE_DELAY = 0
     *      during Pioneer, so apply may follow in the same block). Call
     *      `applyRecipients()` after the delay to apply.
     * @param _stakingPool Proposed StakingRewardPool address (20%)
     * @param _protocolTreasury Proposed protocol treasury address (10%)
     */
    function proposeRecipients(
        address _stakingPool,
        address _protocolTreasury
    ) external onlyRole(ADMIN_ROLE) {
        if (_stakingPool == address(0)) revert ZeroAddress();
        if (_protocolTreasury == address(0)) revert ZeroAddress();

        pendingNewStakingPool = _stakingPool;
        pendingNewProtocolTreasury = _protocolTreasury;
        // solhint-disable-next-line not-rely-on-time
        recipientChangeTime = block.timestamp + RECIPIENT_CHANGE_DELAY;

        emit RecipientsProposed(
            _stakingPool,
            _protocolTreasury,
            recipientChangeTime
        );
    }

    /**
     * @notice Apply pending recipient change after timelock
     *         (M-01 Round 6)
     * @dev Reverts if timelock has not elapsed or no pending
     *      change exists.
     */
    function applyRecipients()
        external
        onlyRole(ADMIN_ROLE)
    {
        if (pendingNewStakingPool == address(0)) {
            revert NoPendingChange();
        }
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp < recipientChangeTime) {
            revert TimelockNotExpired();
        }

        stakingPool = pendingNewStakingPool;
        protocolTreasury = pendingNewProtocolTreasury;
        delete pendingNewStakingPool;
        delete pendingNewProtocolTreasury;
        delete recipientChangeTime;

        emit RecipientsUpdated(stakingPool, protocolTreasury);
    }

    /**
     * @notice Rescue accidentally sent tokens from the vault
     * @dev M-04 audit fix: allows recovery of non-fee tokens or
     *      excess tokens not committed to pendingBridge. Cannot
     *      rescue tokens that are committed for ODDAO bridging.
     *      Only DEFAULT_ADMIN_ROLE can call.
     * @param token ERC20 token address to rescue
     * @param amount Amount to rescue
     * @param recipient Address to send rescued tokens to
     */
    function rescueToken(
        address token,
        uint256 amount,
        address recipient
    ) external nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0)) revert ZeroAddress();
        if (recipient == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        // C-01 audit fix: include totalPendingClaims in committed
        // funds so admin cannot drain user-claimable balances.
        uint256 vaultBalance =
            IERC20(token).balanceOf(address(this));
        uint256 committed =
            pendingBridge[token] + totalPendingClaims[token];
        if (vaultBalance < committed + amount) {
            revert CannotRescueCommittedFunds(token, committed);
        }

        IERC20(token).safeTransfer(recipient, amount);
        emit TokensRescued(token, amount, recipient);
    }

    /**
     * @notice Pause the contract in case of emergency
     * @dev Blocks deposit, distribute, and bridgeToTreasury.
     *      Only ADMIN_ROLE can pause.
     */
    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause the contract after emergency resolution
     * @dev Only ADMIN_ROLE can unpause.
     */
    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    /**
     * @notice Propose permanent ossification of the contract
     * @dev L-01 audit fix: ossification now requires a 48-hour
     *      delay between proposal and confirmation to prevent
     *      accidental or malicious irreversible freezes.
     *      Only DEFAULT_ADMIN_ROLE can propose.
     */
    function proposeOssification()
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        // solhint-disable-next-line not-rely-on-time
        ossificationScheduledAt = block.timestamp + 48 hours;
        emit OssificationProposed(ossificationScheduledAt);
    }

    /**
     * @notice Confirm and execute permanent ossification
     * @dev Cannot be undone. The 48-hour timelock must have
     *      elapsed since proposeOssification() was called.
     *      Only DEFAULT_ADMIN_ROLE can confirm.
     */
    function confirmOssification()
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (ossificationScheduledAt == 0) {
            revert NoPendingChange();
        }
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp < ossificationScheduledAt) {
            revert TimelockNotExpired();
        }

        _ossified = true;
        delete ossificationScheduledAt;
        emit ContractOssified(_msgSender());
    }

    // ── In-Kind / Swap-to-XOM Admin Configuration ────────────────

    /**
     * @notice Propose a bridge mode change for a specific token
     *         (M-03 Round 6)
     * @dev Queues the change via propose/apply (RECIPIENT_CHANGE_DELAY = 0
     *      during Pioneer, so apply may follow in the same block). Call
     *      `applyTokenBridgeMode()` after the delay to apply.
     *      Prevents instant bridge mode manipulation.
     * @param token ERC20 token whose mode to change
     * @param mode Proposed bridge mode
     */
    function proposeTokenBridgeMode(
        address token,
        BridgeMode mode
    ) external onlyRole(ADMIN_ROLE) {
        if (token == address(0)) revert ZeroAddress();

        pendingBridgeModeToken = token;
        pendingBridgeMode = mode;
        // solhint-disable-next-line not-rely-on-time
        bridgeModeChangeTime = block.timestamp + RECIPIENT_CHANGE_DELAY;

        emit BridgeModeProposed(token, mode, bridgeModeChangeTime);
    }

    /**
     * @notice Apply pending bridge mode change after timelock
     *         (M-03 Round 6)
     * @dev Reverts if timelock has not elapsed or no pending
     *      change exists.
     */
    function applyTokenBridgeMode()
        external
        onlyRole(ADMIN_ROLE)
    {
        if (pendingBridgeModeToken == address(0)) {
            revert NoPendingChange();
        }
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp < bridgeModeChangeTime) {
            revert TimelockNotExpired();
        }

        tokenBridgeMode[pendingBridgeModeToken] = pendingBridgeMode;

        emit TokenBridgeModeSet(
            pendingBridgeModeToken, pendingBridgeMode
        );

        delete pendingBridgeModeToken;
        delete pendingBridgeMode;
        delete bridgeModeChangeTime;
    }

    /**
     * @notice Propose a new IFeeSwapRouter adapter address
     * @dev H-03 audit fix: swap router changes are timelocked to
     *      prevent instant diversion of swap proceeds from a
     *      compromised ADMIN_ROLE key. After RECIPIENT_CHANGE_DELAY
     *      (delay 0 during Pioneer), call applySwapRouter() to finalize.
     * @param _router Proposed FeeSwapAdapter contract address
     */
    function proposeSwapRouter(
        address _router
    ) external onlyRole(ADMIN_ROLE) {
        if (_router == address(0)) revert ZeroAddress();

        pendingSwapRouter = _router;
        /* solhint-disable not-rely-on-time */
        swapRouterChangeTimestamp =
            block.timestamp + RECIPIENT_CHANGE_DELAY;
        /* solhint-enable not-rely-on-time */
        emit SwapRouterProposed(
            _router, swapRouterChangeTimestamp
        );
    }

    /**
     * @notice Apply the pending swap router change after timelock
     * @dev Reverts if timelock has not elapsed or no pending change
     *      exists. Only ADMIN_ROLE can execute.
     */
    function applySwapRouter()
        external
        onlyRole(ADMIN_ROLE)
    {
        if (pendingSwapRouter == address(0)) {
            revert NoPendingChange();
        }
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp < swapRouterChangeTimestamp) {
            revert TimelockNotExpired();
        }

        address old = swapRouter;
        swapRouter = pendingSwapRouter;
        delete pendingSwapRouter;
        delete swapRouterChangeTimestamp;
        emit SwapRouterUpdated(old, swapRouter);
    }

    /**
     * @notice Propose a new XOM token address with timelock
     *         (M-02 Round 6)
     * @dev Queues the change via propose/apply (RECIPIENT_CHANGE_DELAY = 0
     *      during Pioneer, so apply may follow in the same block). Call
     *      `applyXomToken()` after the delay to apply.
     *      Prevents instant swap target manipulation by a
     *      compromised admin key.
     * @param _xomToken Proposed OmniCoin ERC20 address
     */
    function proposeXomToken(
        address _xomToken
    ) external onlyRole(ADMIN_ROLE) {
        if (_xomToken == address(0)) revert ZeroAddress();

        pendingXomToken = _xomToken;
        // solhint-disable-next-line not-rely-on-time
        xomTokenChangeTime = block.timestamp + RECIPIENT_CHANGE_DELAY;

        emit XOMTokenProposed(_xomToken, xomTokenChangeTime);
    }

    /**
     * @notice Apply pending XOM token change after timelock
     *         (M-02 Round 6)
     * @dev Reverts if timelock has not elapsed or no pending
     *      change exists.
     */
    function applyXomToken()
        external
        onlyRole(ADMIN_ROLE)
    {
        if (pendingXomToken == address(0)) {
            revert NoPendingChange();
        }
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp < xomTokenChangeTime) {
            revert TimelockNotExpired();
        }

        xomToken = pendingXomToken;
        delete pendingXomToken;
        delete xomTokenChangeTime;

        emit XOMTokenUpdated(xomToken);
    }

    // ── Coin-Agnostic NFT Settlement Admin ───────────────────────

    /**
     * @notice Propose a new OmniSwapRouter address for NFT settlement
     * @dev Queues the change via propose/apply (RECIPIENT_CHANGE_DELAY = 0
     *      during Pioneer, so apply may follow in the same block). Guards against
     *      instant diversion of buyer proceeds through a malicious
     *      router if the admin key is compromised.
     * @param _router Proposed OmniSwapRouter address.
     */
    function proposeNftSwapRouter(
        address _router
    ) external onlyRole(ADMIN_ROLE) {
        if (_router == address(0)) revert ZeroAddress();
        pendingNftSwapRouter = _router;
        // solhint-disable-next-line not-rely-on-time
        nftSwapRouterChangeTime =
            block.timestamp + RECIPIENT_CHANGE_DELAY;
        emit NftSwapRouterProposed(_router, nftSwapRouterChangeTime);
    }

    /**
     * @notice Apply the proposed NFT swap router change
     * @dev Reverts if timelock not elapsed or no pending change.
     */
    function applyNftSwapRouter()
        external
        onlyRole(ADMIN_ROLE)
        whenNotPaused
    {
        if (pendingNftSwapRouter == address(0)) {
            revert NoPendingChange();
        }
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp < nftSwapRouterChangeTime) {
            revert TimelockNotExpired();
        }
        address old = nftSwapRouter;
        nftSwapRouter = pendingNftSwapRouter;
        delete pendingNftSwapRouter;
        delete nftSwapRouterChangeTime;
        emit NftSwapRouterUpdated(old, nftSwapRouter);
    }

    /**
     * @notice Propose a supported-payment-token allowlist change
     * @dev Only admin-approved tokens can be used as `paymentToken`
     *      or `receiveToken` in `BuyNFTIntent`. propose/apply (delay 0
     *      during Pioneer).
     * @param token Token whose allowlist flag is being changed.
     * @param supported Proposed flag (true=add, false=remove).
     */
    function proposeSupportedPaymentToken(
        address token,
        bool supported
    ) external onlyRole(ADMIN_ROLE) {
        if (token == address(0)) revert ZeroAddress();
        pendingSupportedToken = token;
        pendingSupportedTokenFlag = supported;
        // solhint-disable-next-line not-rely-on-time
        supportedTokenChangeTime =
            block.timestamp + RECIPIENT_CHANGE_DELAY;
        emit SupportedPaymentTokenProposed(
            token, supported, supportedTokenChangeTime
        );
    }

    /**
     * @notice Apply the proposed supported-payment-token change
     * @dev Reverts if timelock not elapsed or no pending change.
     */
    function applySupportedPaymentToken()
        external
        onlyRole(ADMIN_ROLE)
        whenNotPaused
    {
        if (pendingSupportedToken == address(0)) {
            revert NoPendingChange();
        }
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp < supportedTokenChangeTime) {
            revert TimelockNotExpired();
        }
        address token = pendingSupportedToken;
        bool flag = pendingSupportedTokenFlag;
        supportedPaymentTokens[token] = flag;
        delete pendingSupportedToken;
        delete pendingSupportedTokenFlag;
        delete supportedTokenChangeTime;
        emit SupportedPaymentTokenUpdated(token, flag);
    }

    /**
     * @notice Propose a per-token minimum sale amount change
     * @dev Tokens with different decimals need different dust
     *      thresholds (e.g. 10_000 wei XOM vs 10_000 wei USDC).
     *      propose/apply (delay 0 during Pioneer).
     * @param token Token whose minimum is changing.
     * @param amount Proposed min `minReceiveAmount` (in token wei).
     */
    function proposeMinSaleAmount(
        address token,
        uint256 amount
    ) external onlyRole(ADMIN_ROLE) {
        if (token == address(0)) revert ZeroAddress();
        // M-03 audit fix: enforce a hard floor so `fee = amount / 100`
        // is always >= 1. Without this, an admin could set `amount = 1`
        // and a spammer could fill `_usedNftIntents` with zero-fee
        // intents cheaply. 100 wei is the minimum that preserves the
        // 1% fee rate's non-zero invariant.
        if (amount < 100) revert MinSaleAmountTooLow();
        pendingMinSaleToken = token;
        pendingMinSaleAmount = amount;
        // solhint-disable-next-line not-rely-on-time
        minSaleChangeTime =
            block.timestamp + RECIPIENT_CHANGE_DELAY;
        emit MinSaleAmountProposed(token, amount, minSaleChangeTime);
    }

    /**
     * @notice Apply the proposed min sale amount change
     * @dev Reverts if timelock not elapsed or no pending change.
     */
    function applyMinSaleAmount()
        external
        onlyRole(ADMIN_ROLE)
        whenNotPaused
    {
        if (pendingMinSaleToken == address(0)) {
            revert NoPendingChange();
        }
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp < minSaleChangeTime) {
            revert TimelockNotExpired();
        }
        address token = pendingMinSaleToken;
        uint256 amount = pendingMinSaleAmount;
        perTokenMinSaleAmount[token] = amount;
        delete pendingMinSaleToken;
        delete pendingMinSaleAmount;
        delete minSaleChangeTime;
        emit MinSaleAmountUpdated(token, amount);
    }

    /**
     * @notice Propose new OmniPrivacyBridge and pXOM addresses
     * @dev H-03 audit fix: privacy bridge changes are timelocked
     *      to prevent instant diversion of pXOM conversion flow.
     *      After RECIPIENT_CHANGE_DELAY (0 during Pioneer), call
     *      applyPrivacyBridge() to finalize.
     * @param _bridge Proposed OmniPrivacyBridge contract address
     * @param _pxom Proposed PrivateOmniCoin (pXOM) ERC20 address
     */
    function proposePrivacyBridge(
        address _bridge,
        address _pxom
    ) external onlyRole(ADMIN_ROLE) {
        if (_bridge == address(0)) revert ZeroAddress();
        if (_pxom == address(0)) revert ZeroAddress();

        pendingPrivacyBridgeAddr = _bridge;
        pendingPXOMToken = _pxom;
        /* solhint-disable not-rely-on-time */
        privacyBridgeChangeTimestamp =
            block.timestamp + RECIPIENT_CHANGE_DELAY;
        /* solhint-enable not-rely-on-time */
        emit PrivacyBridgeProposed(
            _bridge, _pxom, privacyBridgeChangeTimestamp
        );
    }

    /**
     * @notice Apply the pending privacy bridge change after timelock
     * @dev Reverts if timelock has not elapsed or no pending change
     *      exists. Only ADMIN_ROLE can execute.
     */
    function applyPrivacyBridge()
        external
        onlyRole(ADMIN_ROLE)
    {
        if (pendingPrivacyBridgeAddr == address(0)) {
            revert NoPendingChange();
        }
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp < privacyBridgeChangeTimestamp) {
            revert TimelockNotExpired();
        }

        address oldBridge = privacyBridge;
        privacyBridge = pendingPrivacyBridgeAddr;
        pxomToken = pendingPXOMToken;
        delete pendingPrivacyBridgeAddr;
        delete pendingPXOMToken;
        delete privacyBridgeChangeTimestamp;
        emit PrivacyBridgeUpdated(
            oldBridge, privacyBridge, pxomToken
        );
    }

    // ── Swap-and-Bridge Functions ────────────────────────────────

    /**
     * @notice Swap a fee token to XOM and bridge to the pinned ODDAO
     *         treasury
     * @dev Deducts from pendingBridge[token], swaps via the
     *      IFeeSwapRouter adapter, and transfers XOM to the STORED
     *      `bridgeDestination` (VT-21 — see {bridgeToTreasury}; the
     *      caller-supplied `bridgeReceiver` must equal it or the call
     *      reverts `WrongDestination()`).
     *      Uses balance-before/after to verify received amount.
     *      M-03 audit fix: deadline parameter prevents stale
     *      transactions from executing at unfavorable prices.
     * @param token ERC20 fee token to swap
     * @param amount Amount of token to swap (must be <= pending)
     * @param minXOMOut Minimum XOM output (slippage protection)
     * @param bridgeReceiver Must equal `bridgeDestination()` (pinned)
     * @param deadline Timestamp by which the swap must execute
     */
    function swapAndBridge(
        address token,
        uint256 amount,
        uint256 minXOMOut,
        address bridgeReceiver,
        uint256 deadline
    )
        external
        nonReentrant
        onlyRole(BRIDGE_ROLE)
        whenNotPaused
    {
        // VT-21: the full body (assertDestination + swap + XOM transfer)
        // lives in the DELEGATECALL-linked {BridgeDestinationLib} for the
        // EIP-170 budget. The reentrancy/role/pause guards stay here.
        BridgeDestinationLib.swapAndBridge(
            token,
            amount,
            minXOMOut,
            bridgeReceiver,
            deadline,
            bridgeDestination,
            swapRouter,
            xomToken,
            pendingBridge,
            totalBridged
        );
    }

    /**
     * @notice (Legacy v1 — disabled in V2.) Convert accumulated pXOM fees to
     *         XOM and bridge.
     * @dev    Phase 1 V2 redesign (FIX_PRIVACY 1.7-D): the synchronous
     *         L1-side `bridge.convertPXOMtoXOM(amount)` path does not exist
     *         in V2 because pXOM is COTI-only and the V2 bridge's redemption
     *         path is asynchronous (`burnAndQueueUnlock` on COTI →
     *         attestation → 24–72h challenge window → `executeUnlock` on L1).
     *         This function reverts unconditionally; Phase 5 will replace it
     *         with an explicit async pXOM-fee redemption flow that initiates
     *         the burn on COTI and credits the bridgeReceiver only after the
     *         L1 unlock executes.
     *
     *         Live UnifiedFeeVault deployment (UUPS proxy 0xf702f60683c5AFd2351d0b0941c0AADEa62015e1):
     *         the `privacyBridge` storage slot was pointed at the legacy v1
     *         OmniPrivacyBridge 0x739b44D2…, which has been sunset. No
     *         currently-active caller depends on the success of this
     *         function.
     */
    function convertPXOMAndBridge(
        uint256 amount,
        address bridgeReceiver,
        uint256 minXOMOut // solhint-disable-line no-unused-vars
    )
        external
        view
        onlyRole(BRIDGE_ROLE)
        whenNotPaused
    {
        // Read-only sanity so static-analysis still picks up the parameters
        // as inputs and BRIDGE_ROLE remains required for any future caller.
        _validatePXOMBridge(bridgeReceiver, amount);
        revert LegacyPrivacyBridgeRemoved();
    }

    // ════════════════════════════════════════════════════════════════════
    //                          VIEW FUNCTIONS
    // ════════════════════════════════════════════════════════════════════

    /**
     * @notice Get the undistributed balance for a token
     * @dev This is the amount available for the next distribute()
     *      call. Equals the vault's token balance minus the ODDAO
     *      share (pendingBridge) and user-claimable amounts
     *      (totalPendingClaims) that are already committed.
     * @param token ERC20 token address to query
     * @return Undistributed token balance
     */
    function undistributed(
        address token
    ) external view returns (uint256) {
        uint256 balance = IERC20(token).balanceOf(address(this));
        uint256 committed =
            pendingBridge[token] + totalPendingClaims[token];
        if (balance < committed) return 0;
        return balance - committed;
    }

    /**
     * @notice Get the pending ODDAO bridge amount for a token
     * @param token ERC20 token address to query
     * @return Amount awaiting bridging to Optimism
     */
    function pendingForBridge(
        address token
    ) external view returns (uint256) {
        return pendingBridge[token];
    }

    /**
     * @notice Check whether the contract has been ossified
     * @return True if no further upgrades are possible
     */
    function isOssified() external view returns (bool) {
        return _ossified;
    }

    /**
     * @notice Get the claimable amount for a recipient/token pair
     * @dev Used by recipients whose push transfer was quarantined
     * @param recipient Address to check
     * @param token ERC20 token address to check
     * @return Amount available for claim via claimPending()
     */
    function getClaimable(
        address recipient,
        address token
    ) external view returns (uint256) {
        return pendingClaims[recipient][token];
    }

    /**
     * @notice Propose redirecting a stuck pending claim (step 1 of 2)
     * @dev ADV-R8-05 remediation: adds a RECIPIENT_CHANGE_DELAY
     *      timelock before the redirect is applied. This prevents a
     *      compromised admin from instantly redirecting all stuck claims
     *      to an attacker-controlled address.
     *      L-04 audit fix: if a claimant is blacklisted by a token
     *      (e.g., USDC) and cannot receive transfers, an admin can
     *      redirect the claim to a new address so the funds are not
     *      permanently stuck.
     *      Only DEFAULT_ADMIN_ROLE can call.
     *      Emits {RedirectStuckClaimProposed}.
     * @param originalClaimant Address that currently holds the claim
     * @param newRecipient Address to receive the redirected claim
     * @param token ERC20 token address of the claim
     */
    function proposeRedirectStuckClaim(
        address originalClaimant,
        address newRecipient,
        address token
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newRecipient == address(0)) revert ZeroAddress();
        if (pendingClaims[originalClaimant][token] == 0) {
            revert NoPendingClaim();
        }

        pendingRedirectClaimant = originalClaimant;
        pendingRedirectRecipient = newRecipient;
        pendingRedirectToken = token;
        // solhint-disable-next-line not-rely-on-time
        pendingRedirectTimestamp = block.timestamp;

        emit RedirectStuckClaimProposed(
            originalClaimant,
            newRecipient,
            token,
            block.timestamp + RECIPIENT_CHANGE_DELAY // solhint-disable-line not-rely-on-time
        );
    }

    /**
     * @notice Apply the proposed stuck claim redirect (step 2 of 2)
     * @dev ADV-R8-05: can only be called after RECIPIENT_CHANGE_DELAY
     *      has elapsed since the proposal. Clears pending state after
     *      applying the redirect.
     *      Only DEFAULT_ADMIN_ROLE can call.
     *      Emits {ClaimRedirected}.
     */
    function applyRedirectStuckClaim()
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (pendingRedirectClaimant == address(0)) {
            revert NoPendingClaim();
        }
        // solhint-disable-next-line not-rely-on-time
        if (
            block.timestamp
                < pendingRedirectTimestamp + RECIPIENT_CHANGE_DELAY
        ) {
            revert TimelockNotExpired();
        }

        address claimant = pendingRedirectClaimant;
        address recipient = pendingRedirectRecipient;
        address token = pendingRedirectToken;

        uint256 amount = pendingClaims[claimant][token];
        if (amount == 0) revert NoPendingClaim();

        pendingClaims[claimant][token] = 0;
        pendingClaims[recipient][token] += amount;

        // Clear pending state
        pendingRedirectClaimant = address(0);
        pendingRedirectRecipient = address(0);
        pendingRedirectToken = address(0);
        pendingRedirectTimestamp = 0;

        emit ClaimRedirected(claimant, recipient, token, amount);
    }

    /**
     * @notice Cancel a pending stuck claim redirect
     * @dev ADV-R8-05: allows admin to cancel a pending redirect
     *      during the timelock window.
     *      Only DEFAULT_ADMIN_ROLE can call.
     *      Emits {RedirectStuckClaimCancelled}.
     */
    function cancelRedirectStuckClaim()
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (pendingRedirectClaimant == address(0)) {
            revert NoPendingClaim();
        }

        address claimant = pendingRedirectClaimant;

        pendingRedirectClaimant = address(0);
        pendingRedirectRecipient = address(0);
        pendingRedirectToken = address(0);
        pendingRedirectTimestamp = 0;

        emit RedirectStuckClaimCancelled(claimant);
    }

    // ════════════════════════════════════════════════════════════════════
    //                       INTERNAL FUNCTIONS
    // ════════════════════════════════════════════════════════════════════

    /**
     * @notice Split an already-collected marketplace fee 70/20/10
     *         across transaction / referral / listing components
     * @dev Shared by `depositMarketplaceFee` (pulls fee from caller
     *      first) and `settleNftBuy` (buyer's XOM already in vault).
     *      The caller is responsible for having the `feeAmount`
     *      physically present in the vault before invoking this
     *      helper — the helper does NOT pull tokens. It only
     *      performs the accounting / quarantine-safe pushes.
     *
     *      Ratio layout (mirrors the original inline code):
     *        Transaction (50% of fee): 70/20/10 ODDAO/staking/proto
     *        Referral    (25% of fee): 70/20/10 referrer/ref2/ODDAO
     *        Listing     (25% of fee): 70/20/10 list/sell/ODDAO
     *
     *      Zero-address referrer / node slots route their share
     *      to ODDAO (`pendingBridge`). Non-zero recipients land
     *      in `pendingClaims` for pull withdrawal via
     *      `claimPending` (M-03 audit fix).
     *
     *      Updates `totalDistributed[token]` and `totalFeesCollected`
     *      identically to the previous inline code.
     *
     * @param token ERC20 fee token.
     * @param feeAmount Fee amount already in vault balance.
     * @param referrer Primary referrer (zero routes share to ODDAO).
     * @param referrerL2 Secondary referrer (zero routes to ODDAO).
     * @param listingNode Listing node (zero routes to ODDAO).
     * @param sellingNode Selling node (zero routes to ODDAO).
     */
    function _distributeMarketplaceFee(
        address token,
        uint256 feeAmount,
        address referrer,
        address referrerL2,
        address listingNode,
        address sellingNode
    ) internal {
        // Bytecode-size optimisation: the 9-way split logic lives in
        // an external library linked via DELEGATECALL so the vault
        // stays under the 24 KiB Spurious Dragon deployment limit.
        // The library receives storage references and writes to the
        // vault's slots directly — observable behaviour is identical
        // to the prior inline implementation.
        MarketplaceFeeSplitter.distribute(
            token,
            feeAmount,
            MarketplaceFeeSplitter.Recipients({
                referrer: referrer,
                referrerL2: referrerL2,
                listingNode: listingNode,
                sellingNode: sellingNode
            }),
            pendingBridge,
            pendingClaims,
            totalPendingClaims,
            totalDistributed,
            stakingPool,
            protocolTreasury
        );
        // AUDIT FIX (Round 6 FEE-AP-10): Cross-contract fee accounting
        totalFeesCollected += feeAmount;
    }

    /**
     * @notice Coin-agnostic "pull → (swap) → fee → pay seller" primitive
     * @dev Shared helper so future P2P marketplace settlement (non-NFT)
     *      can reuse the exact same payment pipeline. Callers remain
     *      responsible for: signature verification, replay marking,
     *      swap-path commitment check, and the final receive-side
     *      transfer of the asset (NFT / goods).
     *
     *      Flow:
     *        1. Pull `paymentAmount` of `paymentToken` from `buyer`.
     *        2. Fast path: `paymentToken == receiveToken` →
     *           `receiveGross = paymentAmount`.
     *        3. Swap path: approve OmniSwapRouter and call `swap()`
     *           with a gross-up `minAmountOut` covering the 1% fee
     *           plus `minReceiveAmount`.
     *        4. Compute 1% marketplace fee, distribute via
     *           `_distributeMarketplaceFee`.
     *        5. `sellerPay = receiveGross - fee` → `safeTransfer`
     *           to seller.
     *        6. Defense-in-depth: revert `SlippageExceeded` if
     *           `sellerPay < minReceiveAmount` (should never trip
     *           given the router's `minAmountOut` check, but
     *           covers ceil-div edge cases).
     *        7. N-ROY: when `royaltyNftContract != address(0)` (NFT
     *           path only), resolve the EIP-2981 creator royalty on
     *           `receiveGross` (see {RoyaltyResolver.resolveAndPay}),
     *           deduct it from `sellerPay`, pay the creator, and emit
     *           {RoyaltyPaid}.
     *           The royalty is senior to the seller's proceeds (it is
     *           taken AFTER the swap-slippage floor in step 6, mirroring
     *           the audited {NFTMarketplaceEscrow} semantics — worst
     *           case the seller, who chose to list that royalty-bearing
     *           collection, nets zero). P2P callers pass `address(0)`
     *           and this step is skipped entirely (no external call).
     *
     * @param buyer Address being debited in `paymentToken`
     * @param seller Address being credited in `receiveToken`
     * @param paymentToken Token the buyer pays
     * @param paymentAmount Exact amount of `paymentToken` pulled
     * @param receiveToken Token the seller receives
     * @param minReceiveAmount Minimum `receiveToken` net of fee
     * @param recipients Packed fee-recipient addresses (referrer,
     *        referrer2, listingNode, sellingNode). NFT callers pass
     *        listing/selling nodes as `address(0)` so their shares route
     *        to ODDAO (matches the prior behaviour); P2P callers pass the
     *        seller-attested node addresses. Using a struct keeps the
     *        stack depth below Solidity's 16-local hard limit.
     * @param swapPath Router path — empty for same-token fast path
     * @param swapSources Router source IDs
     * @param deadline Swap deadline (same as intent.expiresAt)
     * @param royaltyNftContract NFT collection to query for an EIP-2981
     *        royalty, or `address(0)` to skip royalty handling entirely
     *        (the P2P / goods-and-services path).
     * @param royaltyTokenId Token id passed to `royaltyInfo`; ignored
     *        when `royaltyNftContract == address(0)`.
     * @return receiveGross Gross amount received in `receiveToken`
     * @return fee Marketplace fee (1% of `receiveGross`)
     * @return sellerPay Net amount transferred to `seller`
     */
    function _settleCoinAgnosticBuy(
        address buyer,
        address seller,
        address paymentToken,
        uint256 paymentAmount,
        address receiveToken,
        uint256 minReceiveAmount,
        CoinAgnosticSettlement.FeeRecipients memory recipients,
        address[] calldata swapPath,
        bytes32[] calldata swapSources,
        uint256 deadline,
        address royaltyNftContract,
        uint256 royaltyTokenId
    )
        internal
        returns (
            uint256 receiveGross,
            uint256 fee,
            uint256 sellerPay
        )
    {
        // The full pull → (swap) → 1% fee + optional priority surcharge →
        // royalty → seller-payout pipeline lives in the DELEGATECALL-linked
        // {CoinAgnosticSettlement} library so the vault stays under the
        // 24 KiB EIP-170 limit. It executes in the vault's storage context
        // (all balance + slot mutations land here) and itself calls the
        // already-extracted {SwapExecutor} / {RoyaltyResolver} /
        // {MarketplaceFeeSplitter} libraries. Non-priority callers pass
        // `recipients.priorityFeeBps == 0`, so the surcharge is zero and
        // the `settleP2PBuy` / `settleNftBuy` accounting is byte-for-byte
        // the prior in-vault behaviour. The library returns
        // `feesCollectedDelta` (`fee + surcharge`) which is added to
        // `totalFeesCollected` here, exactly as the prior inline
        // `_distributeMarketplaceFee` did.
        uint256 feesCollectedDelta;
        (receiveGross, fee, sellerPay, feesCollectedDelta) =
            CoinAgnosticSettlement.settle(
                nftSwapRouter,
                stakingPool,
                protocolTreasury,
                CoinAgnosticSettlement.SettleParams({
                    buyer: buyer,
                    seller: seller,
                    paymentToken: paymentToken,
                    paymentAmount: paymentAmount,
                    receiveToken: receiveToken,
                    minReceiveAmount: minReceiveAmount,
                    deadline: deadline,
                    royaltyNftContract: royaltyNftContract,
                    royaltyTokenId: royaltyTokenId
                }),
                recipients,
                pendingBridge,
                pendingClaims,
                totalPendingClaims,
                totalDistributed,
                swapPath,
                swapSources
            );
        totalFeesCollected += feesCollectedDelta;
    }

    // NOTE: the swap-route commitment check (verify caller-supplied
    // `swapPath`/`swapSources` against the buyer's signed
    // `swapPathHash`, folding in the current `nftSwapRouter` per the
    // Solodit Spearbit/Uniswap-2024 router-swap finding) moved into
    // `NftSellerConsent.verifyAndConsume` (merged with the seller-
    // consent check into one call) — its only caller was `settleNftBuy`,
    // so extracting it purely reclaims vault bytecode under the 24 KiB
    // EIP-170 limit. No behavior change; full rationale is on that
    // function's NatSpec.

    /**
     * @notice Build the {PrioritySettlement} plain-P2P context
     * @dev One private builder so `settleP2PBuy` /
     *      `settleP2PBuyAttested` share the 7-field struct construction
     *      (keeps each external function small). Reads the vault's live
     *      domain separator, canonical typehashes, swap router, and fee
     *      recipients.
     * @param requireAttestation True on the attested path.
     * @return ctx The populated `P2PContext`.
     */
    function _p2pContext(
        bool requireAttestation
    ) private view returns (PrioritySettlement.P2PContext memory ctx) {
        ctx = PrioritySettlement.P2PContext({
            domainSeparator: _domainSeparatorV4(),
            intentTypehash: BUY_P2P_TYPEHASH,
            nodeAttestationTypehash: SELLER_NODE_ATTESTATION_TYPEHASH,
            nftSwapRouter: nftSwapRouter,
            stakingPool: stakingPool,
            protocolTreasury: protocolTreasury,
            requireAttestation: requireAttestation
        });
    }

    // NOTE: `BuyNFTIntent` stateless validation (buyer/seller
    // invariants, token allowlist + amount + expiry invariants, the
    // H-01 two-slot referrer anti-fee-wash check) moved into
    // `NftSellerConsent.validateIntent` — the four vault-internal
    // functions that used to live here
    // (`_validateNftIntent`/`_validateBuyerSellerPair`/
    // `_validateTokensAmountsExpiry`/`_validateReferrerPair`) had
    // exactly one caller each, so extracting the whole chain purely
    // reclaims vault bytecode under the 24 KiB EIP-170 limit. No
    // behavior change; full rationale is on that function's NatSpec.

    // NOTE: the plain-P2P stateless validation, node anti-fee-wash
    // checks, seller-node-attestation digest, `BuyP2PIntent` digest, and
    // the shared settlement body (`_executeP2PSettlement`) all moved into
    // the DELEGATECALL-linked {PrioritySettlement} library (`settleP2P`)
    // to keep the vault under the 24 KiB EIP-170 limit. The vault's
    // `settleP2PBuy` / `settleP2PBuyAttested` are thin wrappers around it.
    // The NFT path keeps its own in-vault `_hashNftIntent` (its intent
    // validation moved to `NftSellerConsent.validateIntent` — see the
    // NOTE above).

    // NOTE: the priority-intent + seller-priority-attestation EIP-712
    // digest computation (and the whole priority orchestration) lives in
    // the {PrioritySettlement} library to keep the vault under the
    // 24 KiB EIP-170 limit. The canonical typehash constants
    // (`BUY_P2P_WITH_PRIORITY_TYPEHASH`,
    // `SELLER_PRIORITY_ATTESTATION_TYPEHASH`) remain declared in this
    // vault as the single source of truth and are passed into the
    // library at call time.

    /**
     * @notice Compute the EIP-712 digest for a `BuyNFTIntent`
     * @dev Uses `BUY_NFT_TYPEHASH` and the vault's domain separator
     *      (`name = "OmniBazaar"`, `version = "1"`, `chainId`,
     *      `verifyingContract = this`).
     * @param intent Buyer-signed intent.
     * @return digest The `_hashTypedDataV4` digest ready for ECDSA.
     */
    function _hashNftIntent(
        IntentHashing.BuyNFTIntent calldata intent
    ) internal view returns (bytes32 digest) {
        bytes memory encoded = abi.encode(
            BUY_NFT_TYPEHASH,
            intent.buyer,
            intent.seller,
            intent.nftContract,
            intent.nftTokenId,
            intent.paymentToken,
            intent.paymentAmount,
            intent.receiveToken,
            intent.minReceiveAmount,
            intent.swapPathHash,
            intent.listingId,
            intent.referrer,
            intent.referrer2,
            intent.expiresAt,
            intent.nonce
        );
        digest = _hashTypedDataV4(keccak256(encoded));
    }

    // NOTE: the `SellerNftSale` EIP-712 digest computation (and the
    // seller-consent verify/cancel logic that uses it) lives in the
    // DELEGATECALL-linked {NftSellerConsent} library — see the NOTE in
    // `settleNftBuy` for why. Clients compute the identical digest
    // locally via `ethers.TypedDataEncoder.hash(domain, types, auth)`,
    // same as every other intent type in this vault.

    // NOTE: the former `_safePushOrQuarantine` vault wrapper was removed
    // when the standalone `distribute()` 70/20/10 split moved into
    // `MarketplaceFeeSplitter.distributeBalance` (its only remaining
    // caller). The quarantine-safe push logic now lives entirely in the
    // library; the vault no longer needs a local wrapper.

    /**
     * @notice Authorize a UUPS upgrade
     * @dev Restricted to DEFAULT_ADMIN_ROLE and blocked when ossified.
     *      Validates that the new implementation has deployed code
     *      to prevent bricking the proxy (I-04 audit fix).
     * @param newImplementation Address of the new implementation
     */
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_ossified) revert ContractIsOssified();
        if (newImplementation.code.length == 0) {
            revert InvalidImplementation();
        }
    }

    /**
     * @notice Validate inputs for convertPXOMAndBridge
     * @dev Extracted to reduce cyclomatic complexity of
     *      convertPXOMAndBridge. Checks zero-address, zero-amount,
     *      bridge/pxom/xom config, and pending balance.
     * @param bridgeReceiver Destination address for XOM
     * @param amount Amount of pXOM to convert
     */
    function _validatePXOMBridge(
        address bridgeReceiver,
        uint256 amount
    ) internal view {
        if (bridgeReceiver == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (privacyBridge == address(0)) revert PrivacyBridgeNotSet();
        if (pxomToken == address(0)) revert PrivacyBridgeNotSet();
        if (xomToken == address(0)) revert XOMTokenNotSet();

        uint256 pending = pendingBridge[pxomToken];
        if (amount > pending) {
            revert InsufficientPendingBalance(amount, pending);
        }
    }

    // ════════════════════════════════════════════════════════════════════
    //           ERC2771Context Overrides (resolve diamond)
    // ════════════════════════════════════════════════════════════════════

    /**
     * @notice Resolve _msgSender between ContextUpgradeable and
     *         ERC2771ContextUpgradeable
     * @dev Returns the original user address when called through
     *      the trusted forwarder. Used by claimPending() to
     *      identify the actual claimant.
     * @return The original transaction signer when relayed, or
     *         msg.sender when direct
     */
    function _msgSender()
        internal
        view
        override(
            ContextUpgradeable,
            ERC2771ContextUpgradeable
        )
        returns (address)
    {
        return ERC2771ContextUpgradeable._msgSender();
    }

    /**
     * @notice Resolve _msgData between ContextUpgradeable and
     *         ERC2771ContextUpgradeable
     * @dev Strips the appended sender address from calldata
     *      when relayed
     * @return The original calldata without the ERC2771 suffix
     */
    function _msgData()
        internal
        view
        override(
            ContextUpgradeable,
            ERC2771ContextUpgradeable
        )
        returns (bytes calldata)
    {
        return ERC2771ContextUpgradeable._msgData();
    }

    /**
     * @notice Resolve _contextSuffixLength between
     *         ContextUpgradeable and ERC2771ContextUpgradeable
     * @dev Returns 20 (address length) for ERC2771 context
     *      suffix stripping
     * @return The number of bytes appended to calldata by the
     *         forwarder (20)
     */
    function _contextSuffixLength()
        internal
        view
        override(
            ContextUpgradeable,
            ERC2771ContextUpgradeable
        )
        returns (uint256)
    {
        return ERC2771ContextUpgradeable._contextSuffixLength();
    }
}
