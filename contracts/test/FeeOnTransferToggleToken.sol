// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title FeeOnTransferToggleToken
 * @author OmniCoin Development Team
 * @notice Mock ERC20 whose per-transfer burn fee can be toggled on and off
 * @dev Testing-only. Used to exercise StableSwapPool's fail-closed
 *      fee-on-transfer guard ({FeeOnTransferNotSupported}). The fee can be
 *      disabled (0 bps) to seed a pool with exact-amount transfers and then
 *      enabled to verify that a subsequent {exchange} input pull reverts. The
 *      fee portion is burned, so `balanceOf(to)` rises by less than the
 *      nominal `amount` while the ERC20 bookkeeping stays consistent.
 */
contract FeeOnTransferToggleToken is ERC20 {
    /// @notice Current transfer fee in basis points (100 = 1%)
    uint256 public feeBps;

    /// @notice Thrown when a fee above 50% is requested
    error FeeTooHigh();

    /**
     * @notice Deploy the toggleable fee-on-transfer mock
     * @param name_ Token name
     * @param symbol_ Token symbol
     * @param feeBps_ Initial transfer fee in basis points (<= 5000)
     */
    constructor(
        string memory name_,
        string memory symbol_,
        uint256 feeBps_
    ) ERC20(name_, symbol_) {
        if (feeBps_ > 5000) revert FeeTooHigh();
        feeBps = feeBps_;
    }

    /**
     * @notice Set the per-transfer burn fee in basis points
     * @param feeBps_ New fee in basis points (<= 5000)
     */
    function setFeeBps(uint256 feeBps_) external {
        if (feeBps_ > 5000) revert FeeTooHigh();
        feeBps = feeBps_;
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
     * @notice Internal update hook that burns the configured fee on transfers
     * @dev Fee applies only to real transfers, never to mints or burns.
     * @param from Sender (address(0) for mints)
     * @param to Recipient (address(0) for burns)
     * @param amount Nominal transfer amount
     */
    function _update(
        address from,
        address to,
        uint256 amount
    ) internal override {
        if (from != address(0) && to != address(0) && feeBps > 0) {
            uint256 fee = (amount * feeBps) / 10_000;
            super._update(from, to, amount - fee);
            if (fee > 0) super._update(from, address(0), fee);
        } else {
            super._update(from, to, amount);
        }
    }
}
