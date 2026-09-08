// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title MarketplaceFeeSplitter
 * @author OmniBazaar Team
 * @notice External library that performs the canonical 1% marketplace
 *         fee split (25% transaction / 50% referral / 25% listing,
 *         each 70/20/10 sub-split) on behalf of UnifiedFeeVault.
 *         Linked via DELEGATECALL so the library executes inside the
 *         vault's storage context — all mutations land in the vault's
 *         slots.
 * @dev Splitting this out of UnifiedFeeVault saves deployed bytecode
 *      on the vault, keeping it under the 24 KiB Spurious Dragon
 *      limit. Library code is deployed once and shared across both
 *      `depositMarketplaceFee` and `_settleCoinAgnosticBuy`.
 *
 *      IMPORTANT: All entry points are `external`. Solidity links
 *      external library functions via DELEGATECALL, so the
 *      mapping/storage references passed in resolve to the *vault*'s
 *      storage slots. The library must therefore never declare its
 *      own state variables, and the vault's storage layout must
 *      remain compatible across upgrades.
 *
 *      Replays the split schedule previously hard-coded in
 *      `UnifiedFeeVault._distributeMarketplaceFee` /
 *      `_routeSplitToClaimOrOddao` /
 *      `_safePushOrQuarantine`, with the 2026-06-12 founder-ruled
 *      correction: referral = 0.50% and transaction = 0.25% (the
 *      original inline code had these two slices inverted).
 */
library MarketplaceFeeSplitter {
    /**
     * @notice Recipients of the four claim-eligible sub-splits
     * @param referrer Primary referrer (zero routes to ODDAO)
     * @param referrerL2 Secondary referrer (zero routes to ODDAO)
     * @param listingNode Node hosting the listing
     * @param sellingNode Node serving the buyer
     */
    struct Recipients {
        address referrer;
        address referrerL2;
        address listingNode;
        address sellingNode;
    }

    /// @notice Basis-points denominator
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    /// @notice ODDAO sub-split share (70%)
    uint256 internal constant ODDAO_BPS = 7_000;

    /// @notice Staking / secondary sub-split share (20%)
    uint256 internal constant SECONDARY_BPS = 2_000;

    /**
     * @notice Emitted when a push transfer to a recipient fails and
     *         the amount is quarantined into `pendingClaims`
     * @param recipient Address that failed to receive
     * @param token ERC20 token address
     * @param amount Amount quarantined for pull withdrawal
     */
    event TransferQuarantined(
        address indexed recipient,
        address indexed token,
        uint256 indexed amount
    );

    /**
     * @notice Distribute a 1% marketplace fee across the canonical
     *         9 splits using the 70/20/10 schedule
     * @dev Mirrors `UnifiedFeeVault._distributeMarketplaceFee`
     *      verbatim. All storage writes target the calling vault's
     *      slots via DELEGATECALL.
     * @param token Fee token (XOM or any allowlisted ERC20).
     * @param feeAmount The 1% fee already in the vault.
     * @param recipients Referrer + referrer2 + listing/selling nodes.
     * @param pendingBridge Storage ref to vault's `pendingBridge`.
     * @param pendingClaims Storage ref to vault's `pendingClaims`.
     * @param totalPendingClaims Storage ref to vault's
     *        `totalPendingClaims`.
     * @param totalDistributed Storage ref to vault's
     *        `totalDistributed`.
     * @param stakingPool Recipient of the 20%-of-tx-fee staking share.
     * @param protocolTreasury Recipient of the 10%-of-tx-fee protocol
     *        share.
     * @return totalFeeAdded Amount added to lifetime fee accounting
     *         (`feeAmount`).
     */
    function distribute(
        address token,
        uint256 feeAmount,
        Recipients calldata recipients,
        mapping(address => uint256) storage pendingBridge,
        mapping(address => mapping(address => uint256))
            storage pendingClaims,
        mapping(address => uint256) storage totalPendingClaims,
        mapping(address => uint256) storage totalDistributed,
        address stakingPool,
        address protocolTreasury
    ) external returns (uint256 totalFeeAdded) {
        // Split 1: Transaction fee (0.25% = quarter of total fee)
        uint256 txFee = feeAmount / 4;
        uint256 txOddao = (txFee * ODDAO_BPS) / BPS_DENOMINATOR;
        uint256 txStaking =
            (txFee * SECONDARY_BPS) / BPS_DENOMINATOR;
        uint256 txProtocol = txFee - txOddao - txStaking;

        pendingBridge[token] += txOddao;
        _safePushOrQuarantine(
            token,
            stakingPool,
            txStaking,
            pendingClaims,
            totalPendingClaims
        );
        _safePushOrQuarantine(
            token,
            protocolTreasury,
            txProtocol,
            pendingClaims,
            totalPendingClaims
        );

        // Split 2: Referral fee (0.50% = half of total fee)
        uint256 refFee = feeAmount / 2;
        uint256 refPrimary =
            (refFee * ODDAO_BPS) / BPS_DENOMINATOR;
        uint256 refSecondary =
            (refFee * SECONDARY_BPS) / BPS_DENOMINATOR;
        _routeSplitToClaimOrOddao(
            token,
            recipients.referrer,
            refPrimary,
            pendingBridge,
            pendingClaims,
            totalPendingClaims
        );
        _routeSplitToClaimOrOddao(
            token,
            recipients.referrerL2,
            refSecondary,
            pendingBridge,
            pendingClaims,
            totalPendingClaims
        );
        // Remainder (10%) always to ODDAO.
        pendingBridge[token] +=
            refFee - refPrimary - refSecondary;

        // Split 3: Listing fee (0.25% = remainder)
        uint256 listFee = feeAmount - txFee - refFee;
        uint256 listNode =
            (listFee * ODDAO_BPS) / BPS_DENOMINATOR;
        uint256 sellNode =
            (listFee * SECONDARY_BPS) / BPS_DENOMINATOR;
        _routeSplitToClaimOrOddao(
            token,
            recipients.listingNode,
            listNode,
            pendingBridge,
            pendingClaims,
            totalPendingClaims
        );
        _routeSplitToClaimOrOddao(
            token,
            recipients.sellingNode,
            sellNode,
            pendingBridge,
            pendingClaims,
            totalPendingClaims
        );
        pendingBridge[token] += listFee - listNode - sellNode;

        totalDistributed[token] += feeAmount;

        totalFeeAdded = feeAmount;
    }

    /**
     * @notice Split a token's free balance 70/20/10 ODDAO / staking /
     *         protocol — the permissionless `UnifiedFeeVault.distribute`
     *         body, relocated into the library
     * @dev Extracted to reclaim vault deployed bytecode (24 KiB EIP-170
     *      budget). The 70% ODDAO share accrues to `pendingBridge`; the
     *      20% staking and 10% protocol (remainder) shares are pushed via
     *      `_safePushOrQuarantine` (reverting recipients are quarantined,
     *      M-03). The caller handles the `distributable < 10` dust skip
     *      and the `totalFeesCollected` bump. All storage writes target
     *      the vault's slots via DELEGATECALL.
     * @param token Fee token to distribute.
     * @param distributable Free (non-committed) balance to split.
     * @param pendingBridge Storage ref to vault's `pendingBridge`.
     * @param pendingClaims Storage ref to vault's `pendingClaims`.
     * @param totalPendingClaims Storage ref to vault's
     *        `totalPendingClaims`.
     * @param totalDistributed Storage ref to vault's `totalDistributed`.
     * @param stakingPool Recipient of the 20% staking share.
     * @param protocolTreasury Recipient of the 10% protocol share.
     * @return oddaoShare 70% accrued to `pendingBridge`.
     * @return stakingShare 20% pushed to `stakingPool`.
     * @return protocolShare 10% remainder pushed to `protocolTreasury`.
     */
    function distributeBalance(
        address token,
        uint256 distributable,
        mapping(address => uint256) storage pendingBridge,
        mapping(address => mapping(address => uint256))
            storage pendingClaims,
        mapping(address => uint256) storage totalPendingClaims,
        mapping(address => uint256) storage totalDistributed,
        address stakingPool,
        address protocolTreasury
    )
        external
        returns (
            uint256 oddaoShare,
            uint256 stakingShare,
            uint256 protocolShare
        )
    {
        oddaoShare = (distributable * ODDAO_BPS) / BPS_DENOMINATOR;
        stakingShare =
            (distributable * SECONDARY_BPS) / BPS_DENOMINATOR;
        // Protocol gets the remainder to avoid rounding dust loss.
        protocolShare = distributable - oddaoShare - stakingShare;

        // Effects before interactions (CEI).
        pendingBridge[token] += oddaoShare;
        totalDistributed[token] += distributable;

        if (stakingShare > 0) {
            _safePushOrQuarantine(
                token,
                stakingPool,
                stakingShare,
                pendingClaims,
                totalPendingClaims
            );
        }
        if (protocolShare > 0) {
            _safePushOrQuarantine(
                token,
                protocolTreasury,
                protocolShare,
                pendingClaims,
                totalPendingClaims
            );
        }
    }

    /**
     * @notice Route a sale-time priority-placement surcharge 70/20/10
     *         across listing node / selling node / ODDAO
     * @dev Standalone entry point the vault calls SEPARATELY, AFTER the
     *      normal 1% `distribute(...)` split, on the priority settle
     *      path only. Mirrors "Split 3" (the listing-fee component) of
     *      `distribute`, reusing the same `listingNode` / `sellingNode`
     *      recipients: 70% to the listing node, 20% to the selling
     *      node, 10% (remainder) to ODDAO. A zero node routes its share
     *      to ODDAO via `_routeSplitToClaimOrOddao`; with both nodes
     *      zero, 100% accrues to ODDAO (`pendingBridge`). A zero
     *      `amount` is a no-op so the non-priority path never calls in.
     *      Bumps `totalDistributed[token]` by `amount`. All storage
     *      writes target the calling vault's slots via DELEGATECALL.
     * @param token Fee token the surcharge is held in.
     * @param amount Priority surcharge already in the vault (0 = no-op).
     * @param listingNode Listing-node recipient (zero routes to ODDAO).
     * @param sellingNode Selling-node recipient (zero routes to ODDAO).
     * @param pendingBridge Storage ref to vault's `pendingBridge`.
     * @param pendingClaims Storage ref to vault's `pendingClaims`.
     * @param totalPendingClaims Storage ref to vault's
     *        `totalPendingClaims`.
     * @param totalDistributed Storage ref to vault's `totalDistributed`.
     */
    function distributePriority(
        address token,
        uint256 amount,
        address listingNode,
        address sellingNode,
        mapping(address => uint256) storage pendingBridge,
        mapping(address => mapping(address => uint256))
            storage pendingClaims,
        mapping(address => uint256) storage totalPendingClaims,
        mapping(address => uint256) storage totalDistributed
    ) external {
        if (amount == 0) return;
        uint256 pList = (amount * ODDAO_BPS) / BPS_DENOMINATOR;
        uint256 pSell = (amount * SECONDARY_BPS) / BPS_DENOMINATOR;
        _routeSplitToClaimOrOddao(
            token,
            listingNode,
            pList,
            pendingBridge,
            pendingClaims,
            totalPendingClaims
        );
        _routeSplitToClaimOrOddao(
            token,
            sellingNode,
            pSell,
            pendingBridge,
            pendingClaims,
            totalPendingClaims
        );
        // Remainder (10%) always to ODDAO.
        pendingBridge[token] += amount - pList - pSell;
        totalDistributed[token] += amount;
    }

    /**
     * @notice External entry point for `safePushOrQuarantine` so the
     *         standalone `UnifiedFeeVault.distribute()` flow can also
     *         delegatecall into the shared implementation.
     * @dev Identical semantics to the private helper used inside
     *      `distribute(...)`. Kept as a thin wrapper to avoid
     *      duplicating bytecode for the standalone caller.
     * @param token ERC20 token to transfer
     * @param recipient Target address
     * @param amount Amount to transfer
     * @param pendingClaims Storage ref to vault's `pendingClaims`.
     * @param totalPendingClaims Storage ref to vault's
     *        `totalPendingClaims`.
     */
    function safePushOrQuarantine(
        address token,
        address recipient,
        uint256 amount,
        mapping(address => mapping(address => uint256))
            storage pendingClaims,
        mapping(address => uint256) storage totalPendingClaims
    ) external {
        _safePushOrQuarantine(
            token,
            recipient,
            amount,
            pendingClaims,
            totalPendingClaims
        );
    }

    /**
     * @notice Route a sub-split to either pull-claim or ODDAO
     * @dev Non-zero recipient → credit `pendingClaims[recipient][token]`
     *      + `totalPendingClaims[token]`. Zero recipient → ODDAO
     *      (`pendingBridge[token]`). Mirrors
     *      `UnifiedFeeVault._routeSplitToClaimOrOddao`.
     * @param token ERC20 fee token
     * @param recipient Claimant address (zero routes to ODDAO)
     * @param amount Sub-split amount
     * @param pendingBridge Storage ref to vault's `pendingBridge`.
     * @param pendingClaims Storage ref to vault's `pendingClaims`.
     * @param totalPendingClaims Storage ref to vault's
     *        `totalPendingClaims`.
     */
    function _routeSplitToClaimOrOddao(
        address token,
        address recipient,
        uint256 amount,
        mapping(address => uint256) storage pendingBridge,
        mapping(address => mapping(address => uint256))
            storage pendingClaims,
        mapping(address => uint256) storage totalPendingClaims
    ) private {
        if (amount == 0) return;
        if (recipient != address(0)) {
            pendingClaims[recipient][token] += amount;
            totalPendingClaims[token] += amount;
        } else {
            pendingBridge[token] += amount;
        }
    }

    /**
     * @notice Attempt to push tokens to a recipient; quarantine on
     *         failure
     * @dev Mirrors `UnifiedFeeVault._safePushOrQuarantine`. Wraps
     *      transfer in a low-level call so a reverting recipient does
     *      not block the entire distribute() transaction. On failure,
     *      the amount is credited to `pendingClaims` for later pull
     *      withdrawal and a `TransferQuarantined` event is emitted.
     * @param token ERC20 token to transfer
     * @param recipient Target address
     * @param amount Amount to transfer
     * @param pendingClaims Storage ref to vault's `pendingClaims`.
     * @param totalPendingClaims Storage ref to vault's
     *        `totalPendingClaims`.
     */
    function _safePushOrQuarantine(
        address token,
        address recipient,
        uint256 amount,
        mapping(address => mapping(address => uint256))
            storage pendingClaims,
        mapping(address => uint256) storage totalPendingClaims
    ) private {
        // solhint-disable-next-line avoid-low-level-calls
        (bool success, ) = address(token).call(
            abi.encodeWithSelector(
                IERC20.transfer.selector,
                recipient,
                amount
            )
        );

        bool transferred;
        if (success) {
            assembly {
                let returndata_size := returndatasize()
                if iszero(returndata_size) { transferred := 1 }
                if eq(returndata_size, 32) {
                    returndatacopy(0, 0, 32)
                    transferred := mload(0)
                }
            }
        }

        if (!transferred) {
            // C-01 audit fix: track global pending claims total
            /* solhint-disable reentrancy */
            pendingClaims[recipient][token] += amount;
            totalPendingClaims[token] += amount;
            /* solhint-enable reentrancy */
            emit TransferQuarantined(recipient, token, amount);
        }
    }
}
