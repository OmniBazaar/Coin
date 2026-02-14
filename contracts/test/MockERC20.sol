// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockERC20
 * @author OmniBazaar Development Team
 * @notice Minimal ERC-20 mock for unit testing. No access control on mint.
 */
contract MockERC20 is ERC20 {
    /**
     * @notice Deploy mock token.
     * @param name_ Token name.
     * @param symbol_ Token symbol.
     */
    constructor(
        string memory name_,
        string memory symbol_
    ) ERC20(name_, symbol_) {} // solhint-disable-line no-empty-blocks

    /**
     * @notice Mint tokens to any address (testing only).
     * @param to Recipient.
     * @param amount Amount to mint.
     */
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
