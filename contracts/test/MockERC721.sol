// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

/**
 * @title MockERC721
 * @notice Minimal ERC-721 mock for testing OmniNFTStaking and related contracts.
 * @dev Exposes an unrestricted `mint` function so tests can create tokens freely.
 */
contract MockERC721 is ERC721 {
    /// @notice Deploy the mock collection.
    /// @param name_ Token name.
    /// @param symbol_ Token symbol.
    constructor(
        string memory name_,
        string memory symbol_
    ) ERC721(name_, symbol_) {}

    /**
     * @notice Mint a token to any address (no access control).
     * @param to Recipient address.
     * @param tokenId Token ID to mint.
     */
    function mint(address to, uint256 tokenId) external {
        _mint(to, tokenId);
    }
}
