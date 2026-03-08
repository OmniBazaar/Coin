// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";

/**
 * @title MockERC1155
 * @author OmniBazaar Development Team
 * @notice Minimal ERC-1155 mock for unit testing. No access control on mint.
 */
contract MockERC1155 is ERC1155 {
    /// @notice Deploy mock ERC-1155 with an empty URI.
    constructor() ERC1155("") {} // solhint-disable-line no-empty-blocks

    /**
     * @notice Mint tokens to any address (testing only).
     * @param to Recipient.
     * @param id Token type ID.
     * @param amount Amount to mint.
     */
    function mint(address to, uint256 id, uint256 amount) external {
        _mint(to, id, amount, "");
    }
}
