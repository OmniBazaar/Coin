// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockSwitchableFeeToken
 * @author OmniCoin Development Team
 * @notice Mock ERC-20 whose transfer fee is switched ON after the fact
 * @dev {MockFeeOnTransferToken} charges its fee on the very first transfer, so
 *      an escrow can never take custody of it: {EscrowV2._pullExact} measures
 *      the balance delta at creation and reverts `TokenTransferMismatch` before
 *      any settlement exists to test.
 *
 *      This mock starts at a zero fee and lets the test turn a fee on later,
 *      which is the realistic case the push must survive: a token that begins
 *      charging a tax after the escrow was funded. The push to ODDAO then
 *      delivers less than the scheduled amount, the shortfall is emitted as
 *      `OddaoPushShortfall`, and the settlement MUST still succeed — reverting
 *      here would brick every fee-bearing path, including the delivered
 *      timeout backstop, with no recovery route.
 *
 *      The fee is burned (sent to address(0)), so `balanceOf(to)` grows by less
 *      than the nominal `amount` while ERC-20 bookkeeping stays correct.
 */
contract MockSwitchableFeeToken is ERC20 {
    /// @notice Transfer fee in basis points (100 = 1%)
    uint256 public feeBps; // solhint-disable-line immutable-vars-naming

    /// @notice Thrown when a fee above 50% is requested
    error FeeTooHigh();

    /**
     * @notice Deploy a token that starts with no transfer fee
     * @param name_ Token name
     * @param symbol_ Token symbol
     */
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {} // solhint-disable-line no-empty-blocks

    /**
     * @notice Turn the transfer fee on (or change it)
     * @param newFeeBps Fee in basis points (0..5000)
     */
    function setFeeBps(uint256 newFeeBps) external {
        if (newFeeBps > 5000) revert FeeTooHigh();
        feeBps = newFeeBps;
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
     * @notice Internal update hook that burns a fee on transfers
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
            if (fee > 0) {
                super._update(from, address(0), fee);
            }
        } else {
            super._update(from, to, amount);
        }
    }
}
