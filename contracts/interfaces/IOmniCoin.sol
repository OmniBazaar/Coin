// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title IOmniCoin
 * @author OmniCoin Development Team
 * @notice Interface for OmniCoin token with minting capability
 */
interface IOmniCoin is IERC20 {
    /**
     * @notice Mint new tokens
     * @param to Address to mint tokens to
     * @param amount Amount to mint
     */
    function mint(address to, uint256 amount) external;
    
    /**
     * @notice Get the maximum supply cap
     * @return Maximum token supply
     */
    function maxSupplyCap() external view returns (uint256);
    
    /**
     * @notice Get current token decimals
     * @return Token decimals
     */
    function decimals() external view returns (uint8);
}