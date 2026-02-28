// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockFeeOnTransferToken
 * @author OmniCoin Development Team
 * @notice Mock ERC20 that burns a percentage on every transfer
 * @dev Used to test DEXSettlement balance-before/after guards
 *      (M-07 fee-on-transfer detection). The fee is expressed
 *      in basis points (e.g., 100 = 1%). On each transfer the
 *      recipient receives (amount - fee) and fee tokens are
 *      burned, so `balanceOf(to)` increases by less than the
 *      nominal `amount` parameter.
 */
contract MockFeeOnTransferToken is ERC20 {
    /// @notice Transfer fee in basis points (100 = 1%)
    uint256 public immutable feeBps; // solhint-disable-line immutable-vars-naming

    /// @notice Thrown when constructor fee exceeds 50%
    error FeeTooHigh();

    /**
     * @notice Deploy mock fee-on-transfer token
     * @param name_   Token name
     * @param symbol_ Token symbol
     * @param _feeBps Fee in basis points (e.g., 100 for 1%)
     */
    constructor(
        string memory name_,
        string memory symbol_,
        uint256 _feeBps
    ) ERC20(name_, symbol_) {
        if (_feeBps > 5000) revert FeeTooHigh();
        feeBps = _feeBps;
    }

    /**
     * @notice Mint tokens to an address (unrestricted for testing)
     * @param to     Recipient address
     * @param amount Amount to mint
     */
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /**
     * @notice Internal update hook that burns a fee on transfers
     * @param from   Sender (address(0) for mints)
     * @param to     Recipient (address(0) for burns)
     * @param amount Nominal transfer amount
     * @dev Fee is only applied on real transfers (not mints or
     *      explicit burns). The fee portion is burned (sent to
     *      address(0)), so the recipient receives less than
     *      `amount` while the ERC20 bookkeeping remains correct.
     */
    function _update(
        address from,
        address to,
        uint256 amount
    ) internal override {
        // Apply fee only on real transfers (not mint/burn)
        if (from != address(0) && to != address(0) && feeBps > 0) {
            uint256 fee = (amount * feeBps) / 10_000;
            uint256 netAmount = amount - fee;
            // Transfer net to recipient
            super._update(from, to, netAmount);
            // Burn the fee
            if (fee > 0) {
                super._update(from, address(0), fee);
            }
        } else {
            super._update(from, to, amount);
        }
    }
}
