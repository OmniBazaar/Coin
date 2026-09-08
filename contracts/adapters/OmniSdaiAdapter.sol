// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {RouterAdapterBase} from "./RouterAdapterBase.sol";

/**
 * @title OmniSdaiAdapter
 * @author Omni Development DAO
 * @notice Tier-B ERC-4626 deposit wrapper. Production deployment targets
 *         Maker's sDAI vault (DAI → sDAI at the Dai Savings Rate), but the
 *         source is permissionless ERC-4626 — the SAME contract works for
 *         any standard ERC-4626 yield vault (sFRAX, yvUSDC, Pendle PT, etc.)
 *         deployed with that vault's address at construction.
 *
 *         This is the third Tier-B archetype: standardized vault deposit.
 *         Compared to the Ondo InstantMint pattern (which mints to msg.sender
 *         and required the adapter to forward the output), ERC-4626's
 *         `deposit(assets, receiver)` signature lets the vault mint shares
 *         DIRECTLY to the user. No adapter-holds-tokens step, no
 *         transfer-restriction question. Cleanest of the three adapters.
 *
 *         Flow:
 *           1. UI shows: "Deposit 1,000 DAI to sDAI (Dai Savings Rate ~6%)."
 *           2. User signs `depositVault(netDaiAmount)`.
 *           3. Adapter pulls `gross = net * 1.0025` DAI from msg.sender.
 *           4. Adapter skims fee to UnifiedFeeVault.
 *           5. Adapter approves the vault for net DAI.
 *           6. Adapter calls `vault.deposit(net, msg.sender)`.
 *           7. Vault mints shares (sDAI / sFRAX / etc.) directly to user.
 *
 *         External wallets (MetaMask, hardware) work identically. User's
 *         input asset is whatever the vault accepts (DAI for sDAI, USDC
 *         for yvUSDC, etc.) — set at construction.
 *
 * @dev Decision: `decision_revenue_architecture_2026-05-27.md`.
 *      Plan: `the internal revenue-tier plan` Phase 2.6 (sDAI substitution
 *      for Backed, founder-approved 2026-05-27).
 */
contract OmniSdaiAdapter is RouterAdapterBase {
    using SafeERC20 for IERC20;

    /// @notice The ERC-4626 vault this adapter routes deposits into.
    ///         For Ethereum mainnet sDAI: `0x83F20F44975D03b1b09e64809B757c47f942BEeA`.
    IERC4626 public immutable VAULT;

    /// @notice Emitted on every successful vault deposit.
    /// @param user            Address that signed the tx + receives the shares
    /// @param grossAssets     Total input asset pulled from `user` (gross)
    /// @param sharesReceived  Vault shares minted directly to `user`
    /// @param feeAssets       Fee portion sent to {FEE_VAULT}
    /// @param netAssets       Net assets deposited into the vault
    event SdaiDeposited(
        address indexed user,
        uint256 indexed grossAssets,
        uint256 indexed sharesReceived,
        uint256 feeAssets,
        uint256 netAssets
    );

    /// @dev Reverts if the vault returns zero shares for a non-zero deposit.
    ///      Indicates a misconfigured / paused vault.
    error VaultReturnedZeroShares();

    /// @notice Vault minted fewer shares than the caller's floor (M-07).
    /// @param received Shares actually minted.
    /// @param minSharesOut Caller's signed minimum.
    error SlippageExceeded(uint256 received, uint256 minSharesOut);

    /**
     * @notice Deploy the ERC-4626 vault deposit adapter with a fixed
     *         25 bp protocol fee.
     * @param vaultAsset Address of the vault's underlying asset (e.g.,
     *                   DAI for sDAI; FRAX for sFRAX; USDC for yvUSDC).
     *                   MUST match `vault.asset()` — verify at deploy.
     * @param feeVault   UnifiedFeeVault on this adapter's home chain.
     * @param vault      The ERC-4626 vault contract address.
     */
    constructor(
        address vaultAsset,
        address feeVault,
        address vault
    ) RouterAdapterBase(vaultAsset, feeVault, 25) {
        if (vault == address(0)) revert ZeroAddress("vault");
        VAULT = IERC4626(vault);
    }

    /**
     * @notice Deposit `netAssetAmount` of the underlying asset into the
     *         vault on behalf of `msg.sender` with a 25 bp routing fee.
     * @dev Caller must approve `quoteGrossForNet(netAssetAmount)` of
     *      {INPUT_TOKEN} to this adapter before calling. The vault mints
     *      shares DIRECTLY to msg.sender; no adapter-held intermediate
     *      state.
     * @param netAssetAmount Net assets to deposit (post-fee).
     * @param minSharesOut Minimum vault shares the caller will accept
     *        (M-07 slippage floor). Bound the ERC-4626 share price the
     *        caller signed against inflation / donation front-running;
     *        pass `0` only for an explicit no-floor call.
     * @return sharesReceived Vault shares minted to msg.sender.
     */
    function depositVault(uint256 netAssetAmount, uint256 minSharesOut)
        external
        nonReentrant
        returns (uint256 sharesReceived)
    {
        (uint256 feeAssets, uint256 grossAssets) =
            _collectGrossAndForwardFee(netAssetAmount);

        // forceApprove handles the case where a prior partial approval is
        // still outstanding (DAI is fine, included for consistency).
        INPUT_TOKEN.forceApprove(address(VAULT), netAssetAmount);
        sharesReceived = VAULT.deposit(netAssetAmount, msg.sender);
        if (sharesReceived == 0) revert VaultReturnedZeroShares();
        // M-07: enforce the caller's slippage floor.
        if (sharesReceived < minSharesOut) {
            revert SlippageExceeded(sharesReceived, minSharesOut);
        }

        emit SdaiDeposited(
            msg.sender,
            grossAssets,
            sharesReceived,
            feeAssets,
            netAssetAmount
        );
    }
}
