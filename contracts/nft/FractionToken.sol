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
 *      Supports burning so that a 100 % holder can redeem the original NFT.
 */
contract FractionToken is ERC20, ERC20Burnable {
    /// @notice Address of the OmniFractionalNFT vault that created this token.
    address public immutable vault;

    /// @dev Only the vault can mint.
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
        vault = vaultAddress;
        _mint(initialHolder, totalShares);
    }
}
