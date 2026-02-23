// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from
    "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

/**
 * @title FractionToken
 * @author OmniBazaar Development Team
 * @notice Minimal ERC-20 representing fractional ownership of a locked NFT.
 * @dev Deployed by OmniFractionalNFT when an NFT is fractionalized.
 *      Only the vault contract may burn tokens so that the invariant
 *      totalSupply == VAULT.totalShares is preserved until an explicit
 *      redeem or buyout operation (C-01 audit fix).
 */
contract FractionToken is ERC20, ERC20Burnable {
    /// @notice Address of the OmniFractionalNFT vault that created this token.
    address public immutable VAULT;

    /// @dev Caller is not the vault contract.
    error OnlyVault();

    /**
     * @notice Deploy a new fraction token.
     * @param tokenName ERC-20 name.
     * @param tokenSymbol ERC-20 symbol.
     * @param vaultAddress OmniFractionalNFT contract address.
     * @param initialHolder Address to receive initial supply.
     * @param totalShares Total number of fractional shares to mint.
     */
    constructor(
        string memory tokenName,
        string memory tokenSymbol,
        address vaultAddress,
        address initialHolder,
        uint256 totalShares
    ) ERC20(tokenName, tokenSymbol) {
        VAULT = vaultAddress;
        _mint(initialHolder, totalShares);
    }

    // ── Public functions (overrides) ──────────────────────────────────

    /**
     * @notice Burn tokens from the caller -- restricted to vault only.
     * @dev Overrides ERC20Burnable.burn() to prevent arbitrary burns
     *      that would break the totalSupply == totalShares invariant.
     * @param amount Amount of tokens to burn.
     */
    function burn(uint256 amount) public override {
        if (msg.sender != VAULT) revert OnlyVault();
        super.burn(amount);
    }

    /**
     * @notice Burn tokens from an account -- restricted to vault only.
     * @dev Overrides ERC20Burnable.burnFrom(). The vault calls this
     *      during redeem() and executeBuyout() in OmniFractionalNFT.
     *      Requires prior ERC-20 approval from account to vault.
     * @param account Account whose tokens will be burned.
     * @param amount Amount of tokens to burn.
     */
    function burnFrom(address account, uint256 amount) public override {
        if (msg.sender != VAULT) revert OnlyVault();
        super.burnFrom(account, amount);
    }

    /**
     * @notice Burn tokens from an account without requiring ERC-20
     *         allowance -- restricted to vault only.
     * @dev M-03: Allows the vault to burn share tokens during redeem()
     *      and executeBuyout() without the holder needing to call
     *      approve() first. This improves UX by eliminating the extra
     *      approval transaction while maintaining the same security
     *      guarantee (only the vault can call this).
     * @param account Account whose tokens will be burned.
     * @param amount Amount of tokens to burn.
     */
    function vaultBurn(address account, uint256 amount) external {
        if (msg.sender != VAULT) revert OnlyVault();
        _burn(account, amount);
    }
}
