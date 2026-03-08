// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title ReentrantReceiver
 * @author OmniBazaar Development Team
 * @notice Malicious contract that attempts reentrancy on
 *         OmniTreasury.transferNative when it receives native XOM.
 * @dev Used exclusively in OmniTreasury reentrancy tests.
 */
contract ReentrantReceiver {
    /// @notice The treasury address to re-enter.
    address public immutable TREASURY;

    /// @notice Deploy with the treasury address to attack.
    /// @param treasury_ The OmniTreasury contract address.
    constructor(address treasury_) {
        TREASURY = treasury_;
    }

    /**
     * @notice Attempts to re-enter OmniTreasury.transferNative when
     *         receiving native XOM.
     * @dev Intentionally reverts to test that reentrancy guard blocks
     *      the nested call. The revert propagates up.
     */
    receive() external payable {
        // Try to re-enter transferNative
        // solhint-disable-next-line avoid-low-level-calls
        (bool success, ) = TREASURY.call(
            abi.encodeWithSignature(
                "transferNative(address,uint256)",
                address(this),
                msg.value
            )
        );
        // If the reentrancy guard works, success will be false
        // Revert to signal the attack was attempted
        if (!success) {
            revert("reentrancy blocked");
        }
    }
}
