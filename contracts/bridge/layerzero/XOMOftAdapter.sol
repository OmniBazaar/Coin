// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { OFTAdapter } from "@layerzerolabs/oft-evm/contracts/OFTAdapter.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title XOMOftAdapter
 * @author OmniCoin Development Team
 * @notice LayerZero V2 OFTAdapter for canonical XOM on Avalanche C-Chain
 * @dev This is the LOCK/UNLOCK variant of the cross-chain XOM wrapper, deployed
 *      ONLY on Avalanche C-Chain where the canonical XOM ERC-20 lives. It is
 *      the "home" side of the OmniCoin cross-chain mesh — it holds the real
 *      XOM in escrow while mirror supply circulates on remote chains via
 *      XOMOft (mint/burn) contracts.
 *
 *      Flow (outbound from C-Chain):
 *      - User on C-Chain approves XOMOftAdapter to spend 1,000 XOM
 *      - User calls adapter.send() with dstEid=30101 (Ethereum)
 *      - Adapter transfers 1,000 XOM from user into its own balance (LOCK)
 *      - LayerZero delivers message to XOMOft on Ethereum
 *      - XOMOft on Ethereum mints 1,000 XOM to user
 *
 *      Flow (inbound to C-Chain):
 *      - User on Ethereum calls XOMOft.send() with dstEid=30106 (C-Chain)
 *      - XOMOft on Ethereum burns 1,000 XOM from user
 *      - LayerZero delivers message to XOMOftAdapter on C-Chain
 *      - Adapter transfers 1,000 XOM from its own balance to user (UNLOCK)
 *
 *      Tokenomics invariant:
 *      - Balance of XOM held by XOMOftAdapter on C-Chain MUST equal the sum of
 *        XOMOft total supply across all remote chains at all times
 *      - Any deviation indicates a bridge exploit — immediate pause required
 *
 *      ⚠️ CRITICAL: Only ONE XOMOftAdapter should exist in the XOM cross-chain
 *      mesh. Deploying a second adapter would fragment liquidity and break the
 *      1:1 supply invariant. The adapter is the single source of truth for
 *      canonical XOM wrapped on remote chains.
 *
 *      LayerZero V2 Endpoint IDs (EIDs):
 *      - Avalanche C-Chain: 30106 (this contract)
 *      - Ethereum: 30101
 *      - Arbitrum: 30110
 *      - Base:     30184
 *      - Polygon:  30109
 *
 *      Security:
 *      - Owner controls setPeer() to register trusted remote OFTs
 *      - Owner controls pause() for emergency halt of inbound/outbound transfers
 *      - Ownership transferred to timelocked multisig post-launch
 *      - Wallet-level OFAC screening applies upstream at the validator layer
 */
contract XOMOftAdapter is OFTAdapter, Ownable2Step, Pausable {
    // ========================================================================
    // ERRORS
    // ========================================================================

    /// @notice Thrown when a transfer is attempted while the contract is paused
    error BridgePaused();

    // ========================================================================
    // CONSTRUCTOR
    // ========================================================================

    /**
     * @notice Deploys the XOMOftAdapter wrapping canonical XOM on C-Chain
     * @param _xomToken Address of the canonical XOM ERC-20 token on C-Chain
     * @param _lzEndpoint The LayerZero V2 endpoint address on C-Chain
     * @param _delegate The initial owner/delegate (recommended: deployer, then
     *                  transferred to timelocked multisig)
     * @dev The adapter reads decimals from _xomToken (18 for XOM). Callers must
     *      approve the adapter to spend XOM before calling send().
     */
    constructor(
        address _xomToken,
        address _lzEndpoint,
        address _delegate
    ) OFTAdapter(_xomToken, _lzEndpoint, _delegate) Ownable(_delegate) { }

    // ========================================================================
    // EMERGENCY CONTROLS
    // ========================================================================

    /**
     * @notice Pause all inbound and outbound bridge transfers
     * @dev Used in emergencies (e.g., supply invariant breach, peer compromise,
     *      LayerZero DVN compromise). While paused:
     *      - Outbound sends revert in _debit() (no XOM can be locked)
     *      - Inbound credits revert in _credit() (no XOM can be unlocked)
     *      - Canonical XOM ERC-20 continues to function normally for on-chain
     *        trading and transfers on C-Chain
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Resume bridge transfers after a pause
     * @dev Only callable by owner. Must verify the bridge invariant
     *      (adapter balance == sum of remote supplies) has been restored before
     *      unpausing. Any discrepancy must be reconciled via governance.
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    // ========================================================================
    // OFTAdapter OVERRIDES — Pause gate
    // ========================================================================

    /**
     * @notice Lock tokens in the adapter for outbound cross-chain transfer
     * @param _from Address to debit (transferFrom) tokens from
     * @param _amountLD Amount in local decimals (18 for XOM)
     * @param _minAmountLD Minimum amount after dust removal (slippage protection)
     * @param _dstEid Destination LayerZero endpoint ID
     * @return amountSentLD Amount actually sent in local decimals
     * @return amountReceivedLD Amount expected to be received on destination
     * @dev Reverts if contract is paused (BridgePaused error). The `_from`
     *      address must have approved this contract for at least _amountLD
     *      via XOM.approve() prior to calling send().
     */
    // solhint-disable-next-line ordering
    function _debit(
        address _from,
        uint256 _amountLD,
        uint256 _minAmountLD,
        uint32 _dstEid
    ) internal virtual override returns (uint256 amountSentLD, uint256 amountReceivedLD) {
        if (paused()) revert BridgePaused();
        return super._debit(_from, _amountLD, _minAmountLD, _dstEid);
    }

    /**
     * @notice Unlock tokens from the adapter for inbound cross-chain transfer
     * @param _to Address to credit (transfer) tokens to
     * @param _amountLD Amount in local decimals (18 for XOM)
     * @param _srcEid Source LayerZero endpoint ID
     * @return amountReceivedLD Amount actually credited in local decimals
     * @dev Reverts if contract is paused (BridgePaused error). When paused,
     *      LayerZero retries the message until it succeeds (once unpaused) or
     *      is manually cleared by owner via endpoint's skip/clear functions.
     */
    function _credit(
        address _to,
        uint256 _amountLD,
        uint32 _srcEid
    ) internal virtual override returns (uint256 amountReceivedLD) {
        if (paused()) revert BridgePaused();
        return super._credit(_to, _amountLD, _srcEid);
    }

    // solhint-disable ordering
    // ========================================================================
    // OWNERSHIP — Ownable2Step override (audit fix F-08)
    // ========================================================================

    /**
     * @notice Start ownership transfer to a new address (step 1 of 2)
     * @param newOwner Proposed new owner; must call acceptOwnership() to confirm
     * @dev Overrides to enforce the 2-step transfer flow. The new owner is
     *      recorded as pendingOwner and must explicitly call acceptOwnership
     *      to complete the handover. This prevents fat-finger mistakes that
     *      could lock the adapter's admin controls (and with them the
     *      entire canonical-XOM escrow on C-Chain).
     */
    function transferOwnership(
        address newOwner
    ) public virtual override(Ownable, Ownable2Step) onlyOwner {
        Ownable2Step.transferOwnership(newOwner);
    }

    /**
     * @notice Internal ownership transfer function (Ownable2Step override)
     * @param newOwner Address to assign ownership to
     * @dev Clears pendingOwner and emits OwnershipTransferred event.
     */
    function _transferOwnership(
        address newOwner
    ) internal virtual override(Ownable, Ownable2Step) {
        Ownable2Step._transferOwnership(newOwner);
    }
}
