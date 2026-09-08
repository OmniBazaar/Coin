// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockERC20
 * @dev Simple ERC20 mock for testing contracts with configurable supply
 */
contract MockERC20 is ERC20 {
    constructor(
        string memory name, 
        string memory symbol, 
        uint256 initialSupply
    ) ERC20(name, symbol) {
        _mint(msg.sender, initialSupply);
    }

    // Allow minting for testing purposes
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}