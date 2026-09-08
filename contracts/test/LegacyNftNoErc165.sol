// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title  LegacyNftNoErc165
 * @author OmniBazaar Team
 * @notice An ERC-721-shaped collection from before ERC-165 was universal:
 *         it has `transferFrom(address,address,uint256)` and
 *         `setApprovalForAll`, but implements no `supportsInterface` at
 *         all.
 * @dev Test-only. It exists to prove that an interface-declaration check
 *      alone cannot tell an NFT collection from money — plenty of valuable
 *      2017-18 collections answer nothing, and no lying is required to get
 *      past such a check, only silence. `OmniConduit` therefore gates
 *      payment tokens on whether they keep ERC-20 allowances, which this
 *      contract does not.
 */
contract LegacyNftNoErc165 {
    /// @notice Owner of each token id.
    mapping(uint256 => address) public ownerOf;

    /// @notice Operator approvals, as ERC-721 defines them.
    mapping(address => mapping(address => bool)) public isApprovedForAll;

    /// @notice The token is not owned by the named account.
    error NotOwner();

    /// @notice The caller may not move this token.
    error NotApproved();

    /**
     * @notice Mint a token.
     * @param to      Recipient.
     * @param tokenId Token to create.
     */
    function mint(address to, uint256 tokenId) external {
        ownerOf[tokenId] = to;
    }

    /**
     * @notice Approve an operator for every token the caller owns.
     * @param operator Operator to authorise.
     * @param approved Whether the operator is authorised.
     */
    function setApprovalForAll(address operator, bool approved) external {
        isApprovedForAll[msg.sender][operator] = approved;
    }

    /**
     * @notice Move a token. Returns nothing, exactly as ERC-721 does — and
     *         that is the whole point: `SafeERC20` accepts a contract that
     *         returns nothing, so this call is indistinguishable from a
     *         well-behaved ERC-20 transfer at the call site.
     * @param from    Current owner.
     * @param to      Recipient.
     * @param tokenId Token to move.
     */
    function transferFrom(address from, address to, uint256 tokenId) external {
        if (ownerOf[tokenId] != from) revert NotOwner();
        if (msg.sender != from && !isApprovedForAll[from][msg.sender]) {
            revert NotApproved();
        }
        ownerOf[tokenId] = to;
    }
}
