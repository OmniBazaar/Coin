// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title NonERC721Receiver
 * @notice Contract that intentionally does NOT implement
 *         `onERC721Received`. Used to prove that the settlement
 *         reverts when the buyer address is a non-compliant contract.
 */
contract NonERC721Receiver { // solhint-disable-line no-empty-blocks
}
