// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title ERC20MockConfigurable
 * @author OmniCoin Development Team
 * @notice Mock ERC20 token with configurable decimals for testing
 * @dev Used by PrivateUSDC (6 decimals), PrivateWBTC (8 decimals),
 *      and PrivateWETH (18 decimals) test suites to create
 *      underlying token mocks with the correct precision.
 */
contract ERC20MockConfigurable is ERC20 {
    /// @notice Custom decimal precision for this mock
    uint8 private immutable _decimals;

    /**
     * @notice Deploy mock token with configurable decimals
     * @param name_ Token name
     * @param symbol_ Token symbol
     * @param decimals_ Number of decimal places
     */
    constructor(
        string memory name_,
        string memory symbol_,
        uint8 decimals_
    ) ERC20(name_, symbol_) {
        _decimals = decimals_;
        // Mint initial supply to deployer for testing
        _mint(msg.sender, 1_000_000_000 * 10 ** uint256(decimals_));
    }

    /**
     * @notice Returns the configured number of decimals
     * @return Number of decimals
     */
    function decimals()
        public
        view
        virtual
        override
        returns (uint8)
    {
        return _decimals;
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
