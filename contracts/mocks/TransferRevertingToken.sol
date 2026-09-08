// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title TransferRevertingToken
 * @author OmniBazaar Team
 * @notice ERC20 that reverts transfer() to specific blocked addresses
 * @dev Used to test quarantine/blacklist paths in UnifiedFeeVault and
 *      other contracts that must handle failed token transfers gracefully.
 *
 *      - Tokens can be minted freely (test helper)
 *      - transfer() and transferFrom() revert when the recipient is blocked
 *      - Owner can add/remove blocked addresses
 */
contract TransferRevertingToken is ERC20 {
    // ═══════════════════════════════════════════════════════════════════════
    //                          ERRORS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Thrown when a transfer targets a blocked address
    /// @param recipient The blocked recipient address
    error TransferBlocked(address recipient);

    // ═══════════════════════════════════════════════════════════════════════
    //                          STATE
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev Addresses that will cause transfer() to revert
    mapping(address => bool) private _blocked;

    // ═══════════════════════════════════════════════════════════════════════
    //                          EVENTS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Emitted when an address is added to or removed from the blocklist
    /// @param account The affected address
    /// @param blocked Whether the address is now blocked
    event BlockStatusChanged(address indexed account, bool blocked);

    // ═══════════════════════════════════════════════════════════════════════
    //                        CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Deploy the transfer-reverting token
     * @param name_ Token name
     * @param symbol_ Token symbol
     */
    constructor(
        string memory name_,
        string memory symbol_
    ) ERC20(name_, symbol_) {}

    // ═══════════════════════════════════════════════════════════════════════
    //                       MOCK CONTROLS
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Block or unblock an address from receiving transfers
     * @param account Address to block or unblock
     * @param blocked True to block, false to unblock
     */
    function setBlocked(address account, bool blocked) external {
        _blocked[account] = blocked;
        emit BlockStatusChanged(account, blocked);
    }

    /**
     * @notice Check if an address is blocked
     * @param account Address to check
     * @return True if the address is blocked
     */
    function isBlocked(address account) external view returns (bool) {
        return _blocked[account];
    }

    /**
     * @notice Mint tokens to an address (unrestricted for testing)
     * @param to Recipient address
     * @param amount Amount to mint
     */
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /**
     * @notice Burn tokens from an address (unrestricted for testing)
     * @param from Address to burn from
     * @param amount Amount to burn
     */
    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                       OVERRIDES
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Internal transfer hook that enforces the blocklist
     * @dev Reverts with TransferBlocked if the recipient is on the blocklist.
     *      This catches both transfer() and transferFrom() paths.
     * @param from Sender address
     * @param to Recipient address
     * @param value Transfer amount
     */
    function _update(
        address from,
        address to,
        uint256 value
    ) internal virtual override {
        if (_blocked[to]) {
            revert TransferBlocked(to);
        }
        super._update(from, to, value);
    }
}
