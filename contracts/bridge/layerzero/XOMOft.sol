// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { OFT } from "@layerzerolabs/oft-evm/contracts/OFT.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title XOMOft
 * @author OmniCoin Development Team
 * @notice LayerZero V2 OFT (Omnichain Fungible Token) for XOM on external EVM chains
 * @dev This is the MINT/BURN variant of the cross-chain XOM token, deployed on
 *      Ethereum, Arbitrum, Base, and Polygon. It is the "remote" side of the
 *      OmniCoin cross-chain mesh — the canonical XOM lives on Avalanche C-Chain
 *      and is wrapped by XOMOftAdapter which locks/unlocks tokens on that chain.
 *
 *      Flow:
 *      - User on Ethereum wants to send 1,000 XOM to Arbitrum
 *      - XOMOft on Ethereum burns 1,000 XOM from user
 *      - LayerZero delivers message to XOMOft on Arbitrum
 *      - XOMOft on Arbitrum mints 1,000 XOM to user
 *      - Total circulating supply across mesh stays constant (lock amount on C-Chain)
 *
 *      LayerZero V2 Endpoint IDs (EIDs):
 *      - Ethereum: 30101
 *      - Arbitrum: 30110
 *      - Base:     30184
 *      - Polygon:  30109
 *      - Avalanche C-Chain: 30106 (XOMOftAdapter)
 *
 *      Security:
 *      - Owner controls setPeer() to register trusted remote OFTs
 *      - Owner controls pause() for emergency halt of inbound/outbound transfers
 *      - Ownership transferred to timelocked multisig post-launch
 *      - LayerZero's DVN + Executor stack provides the messaging security layer
 *
 *      Tokenomics invariant:
 *      - Native XOM lives on Avalanche C-Chain (ERC-20 supply fixed at 16.6B)
 *      - Every XOM wrapped by XOMOftAdapter on C-Chain must equal the sum of
 *        XOMOft supply across all 4 remote chains. Imbalance indicates a bridge
 *        exploit and must be investigated immediately.
 */
contract XOMOft is OFT, Ownable2Step, Pausable {
    // ========================================================================
    // ERRORS
    // ========================================================================

    /// @notice Thrown when a transfer is attempted while the contract is paused
    error BridgePaused();

    // ========================================================================
    // CONSTRUCTOR
    // ========================================================================

    /**
     * @notice Deploys the XOMOft token on a remote chain
     * @param _lzEndpoint The LayerZero V2 endpoint address on this chain
     * @param _delegate The initial owner/delegate (recommended: deployer, then
     *                  transferred to timelocked multisig)
     * @dev Name and symbol are hardcoded to "OmniCoin" / "XOM" for consistency
     *      across the cross-chain mesh. Decimals default to 18 via ERC20.
     */
    constructor(
        address _lzEndpoint,
        address _delegate
    ) OFT("OmniCoin", "XOM", _lzEndpoint, _delegate) Ownable(_delegate) { }

    // ========================================================================
    // EMERGENCY CONTROLS
    // ========================================================================

    /**
     * @notice Pause all inbound and outbound bridge transfers
     * @dev Used in emergencies (e.g., suspected exploit on another chain,
     *      LayerZero DVN compromise). While paused:
     *      - Outbound sends revert in _debit()
     *      - Inbound credits revert in _credit()
     *      - Normal ERC-20 transfers on this chain continue to work
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Resume bridge transfers after a pause
     * @dev Only callable by owner. Must verify the cause of the pause has been
     *      resolved (e.g., exploit patched, peer reconfigured) before unpausing.
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    // ========================================================================
    // OFT OVERRIDES — Pause gate
    // ========================================================================

    /**
     * @notice Burn tokens from sender for outbound cross-chain transfer
     * @param _from Address to debit tokens from
     * @param _amountLD Amount in local decimals
     * @param _minAmountLD Minimum amount after dust removal (slippage protection)
     * @param _dstEid Destination LayerZero endpoint ID
     * @return amountSentLD Amount actually sent in local decimals
     * @return amountReceivedLD Amount expected to be received on destination
     * @dev Reverts if contract is paused (BridgePaused error).
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
     * @notice Mint tokens to recipient from inbound cross-chain transfer
     * @param _to Address to credit tokens to
     * @param _amountLD Amount in local decimals
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
     *      could lock the bridge's admin controls.
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
