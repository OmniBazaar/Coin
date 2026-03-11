// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title ERC20MockDecimals
 * @author OmniCoin Development Team
 * @notice Mock ERC20 with configurable decimals for testing
 * @dev Used to simulate tokens like USDC (6 decimals) or WBTC (8 decimals).
 *      No access control on mint -- testing only.
 */
contract ERC20MockDecimals is ERC20 {
    /// @notice Custom decimals value
    uint8 private immutable _decimals;

    /**
     * @notice Deploy mock token with custom decimals
     * @param name_ Token name
     * @param symbol_ Token symbol
     * @param decimals_ Number of decimals
     */
    constructor(
        string memory name_,
        string memory symbol_,
        uint8 decimals_
    ) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    /**
     * @notice Returns the configured number of decimals
     * @return The number of decimals
     */
    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    /**
     * @notice Mint tokens to an address (testing only)
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
