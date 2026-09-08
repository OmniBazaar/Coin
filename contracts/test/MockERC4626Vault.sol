// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title MockERC4626Vault
 * @author Omni Development DAO
 * @notice Test-only mock of an ERC-4626 yield vault (e.g., sDAI).
 *         Implements just enough of the standard for the
 *         {OmniSdaiAdapter} unit tests:
 *           - `deposit(uint256 assets, address receiver) returns (uint256 shares)`
 *           - `asset() view returns (address)`
 *           - share-token state via inherited ERC20.
 *
 *         Behavior knobs:
 *         - `sharesPerAsset`: configurable conversion rate (default 1:1).
 *         - `forceZeroShares`: makes `deposit` return 0 (exercises
 *           {OmniSdaiAdapter.VaultReturnedZeroShares}).
 *         - `forceRevert`: makes `deposit` revert.
 * @dev NOT for production use. Test contract only. Skips the full
 *      ERC-4626 spec (`mint`, `withdraw`, `redeem`, preview functions)
 *      because the adapter only exercises `deposit` + `asset`.
 */
contract MockERC4626Vault is ERC20 {
    using SafeERC20 for IERC20;

    /// @notice The vault's underlying asset (e.g., DAI for sDAI mock).
    IERC20 public immutable ASSET_TOKEN;
    /// @notice Conversion rate: shares minted per 1 unit of asset.
    ///         Default 1 (1:1). Set via {setSharesPerAsset}.
    uint256 public sharesPerAsset = 1;
    /// @notice When true, `deposit` returns 0 shares (exercises VaultReturnedZeroShares).
    bool public forceZeroShares;
    /// @notice When true, `deposit` reverts.
    bool public forceRevert;

    /// @notice Deploy a mock vault wired to an underlying ERC-20 asset.
    /// @param assetAddr Underlying asset address (e.g., test DAI)
    /// @param name_     ERC-20 name for the share token
    /// @param symbol_   ERC-20 symbol for the share token
    constructor(address assetAddr, string memory name_, string memory symbol_) ERC20(name_, symbol_) {
        ASSET_TOKEN = IERC20(assetAddr);
    }

    /// @notice ERC-4626 `asset()` — the underlying token address.
    /// @return The address of the underlying asset
    function asset() external view returns (address) {
        return address(ASSET_TOKEN);
    }

    /// @notice Set the shares-per-asset conversion rate for tests.
    /// @param rate Whole-number shares minted per 1 unit of asset deposited
    function setSharesPerAsset(uint256 rate) external {
        sharesPerAsset = rate;
    }

    /// @notice Toggle the `deposit returns 0 shares` failure mode.
    /// @param value true → next `deposit` returns 0
    function setForceZeroShares(bool value) external {
        forceZeroShares = value;
    }

    /// @notice Toggle the `deposit reverts` failure mode.
    /// @param value true → next `deposit` reverts
    function setForceRevert(bool value) external {
        forceRevert = value;
    }

    /// @notice Production-shape ERC-4626 deposit. Pulls assets from
    ///         caller, mints shares to `receiver`.
    /// @param assets    Asset amount the caller is depositing
    /// @param receiver  Address that receives the minted shares
    /// @return shares   Shares minted to `receiver`
    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        require(!forceRevert, "MockVault: forced revert");
        ASSET_TOKEN.safeTransferFrom(msg.sender, address(this), assets);
        if (forceZeroShares) {
            return 0;
        }
        shares = assets * sharesPerAsset;
        _mint(receiver, shares);
    }
}
