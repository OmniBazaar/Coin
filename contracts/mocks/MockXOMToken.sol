// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockXOMToken
 * @author OmniBazaar Team
 * @notice Mock ERC20 token for testing OmniValidatorRewards
 * @dev Simple ERC20 token with mint function for tests
 */
contract MockXOMToken is ERC20 {
    /**
     * @notice Constructor
     */
    constructor() ERC20("Mock XOM", "mXOM") {}

    /**
     * @notice Mint tokens to address
     * @param to Recipient address
     * @param amount Amount to mint
     */
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /**
     * @notice Burn tokens from address
     * @param from Address to burn from
     * @param amount Amount to burn
     */
    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}
