// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockRevertingApproveToken
 * @author OmniBazaar Test Suite
 * @notice ERC-20 whose `approve` can be made to revert on demand, used
 *         to exercise OmniTreasuryV2's M-03 best-effort revocation path.
 * @dev When `revertOnApprove` is true, every `approve` call reverts —
 *      modelling a malicious or non-standard token that could otherwise
 *      brick `transitionGovernance` / `revokeAllApprovals` if those
 *      loops were not try/catch-wrapped.
 */
contract MockRevertingApproveToken is ERC20 {
    /// @notice When true, `approve` reverts.
    bool public revertOnApprove;

    /// @notice Thrown by `approve` while `revertOnApprove` is set.
    error ApproveDisabled();

    /**
     * @notice Deploy the token.
     * @param name_ Token name.
     * @param symbol_ Token symbol.
     */
    constructor(
        string memory name_,
        string memory symbol_
    ) ERC20(name_, symbol_) {} // solhint-disable-line no-empty-blocks

    /**
     * @notice Mint tokens to any address (test helper).
     * @param to Recipient.
     * @param amount Amount to mint.
     */
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /**
     * @notice Toggle the revert-on-approve behavior.
     * @param value True to make `approve` revert.
     */
    function setRevertOnApprove(bool value) external {
        revertOnApprove = value;
    }

    /**
     * @notice Approve a spender, reverting when sabotage is enabled.
     * @param spender The spender to approve.
     * @param value The allowance amount.
     * @return success Always true when not reverting.
     */
    function approve(
        address spender,
        uint256 value
    ) public override returns (bool success) {
        if (revertOnApprove) revert ApproveDisabled();
        success = super.approve(spender, value);
    }
}
