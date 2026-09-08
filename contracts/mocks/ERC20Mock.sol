// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title ERC20Mock
 * @author OmniCoin Development Team
 * @notice Mock ERC20 token for testing purposes
 * @dev Simple implementation with mint function for testing
 */
contract ERC20Mock is ERC20 {
    /**
     * @notice Deploy mock token with name and symbol
     * @param name_ Token name
     * @param symbol_ Token symbol
     */
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {
        // Mint initial supply to deployer for testing
        _mint(msg.sender, 1_000_000_000 * 10 ** decimals());
    }

    /**
     * @notice Mint tokens to an address
     * @param to Recipient address
     * @param amount Amount to mint
     */
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /**
     * @notice Burn tokens from caller
     * @param amount Amount to burn
     */
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}
