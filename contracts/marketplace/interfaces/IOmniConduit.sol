// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title  IOmniConduit
 * @author OmniBazaar Team
 * @notice Interface of the stable approval target the OmniBazaar NFT
 *         exchange moves tokens through. Settlement contracts depend on
 *         this interface, never on a concrete conduit, so a settlement
 *         contract can be replaced without users re-approving anything.
 * @dev Implementation and trust model: `OmniConduit.sol`.
 */
interface IOmniConduit {
    /**
     * @notice Emitted when a channel is opened or closed.
     * @param channel Contract whose authorisation changed.
     * @param open    True if the channel may now move tokens.
     */
    event ChannelUpdated(address indexed channel, bool indexed open);

    /**
     * @notice Emitted when the current owner nominates a successor.
     * @param currentOwner  Owner at the time of the nomination.
     * @param proposedOwner Address that may claim the role.
     */
    event OwnershipProposed(
        address indexed currentOwner,
        address indexed proposedOwner
    );

    /**
     * @notice Emitted when ownership actually moves.
     * @param previousOwner Owner before the change.
     * @param newOwner      Owner after the change.
     */
    event OwnershipTransferred(
        address indexed previousOwner,
        address indexed newOwner
    );

    /**
     * @notice Open or close a channel.
     * @param channel Contract to authorise or de-authorise.
     * @param open    True to open, false to close.
     */
    function updateChannel(address channel, bool open) external;

    /**
     * @notice Move one ERC-721 token on behalf of its owner.
     * @param token   ERC-721 collection.
     * @param from    Current owner.
     * @param to      Recipient.
     * @param tokenId Token to move.
     */
    function transferERC721(
        address token,
        address from,
        address to,
        uint256 tokenId
    ) external;

    /**
     * @notice Move ERC-1155 units on behalf of their owner.
     * @param token  ERC-1155 collection.
     * @param from   Current owner.
     * @param to     Recipient.
     * @param id     Token id to move.
     * @param amount Number of units to move.
     */
    function transferERC1155(
        address token,
        address from,
        address to,
        uint256 id,
        uint256 amount
    ) external;

    /**
     * @notice Move ERC-20 tokens on behalf of their owner.
     * @param token  ERC-20 token.
     * @param from   Payer.
     * @param to     Recipient.
     * @param amount Amount in the token's smallest units.
     */
    function transferERC20(
        address token,
        address from,
        address to,
        uint256 amount
    ) external;

    /**
     * @notice Report whether a contract may currently move tokens.
     * @param channel Contract to check.
     * @return open True if the channel is open.
     */
    function channels(address channel) external view returns (bool open);
}
