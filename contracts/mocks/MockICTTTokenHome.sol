// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from
    "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title MockICTTTokenHome
 * @author OmniBazaar Team — TEST ONLY
 * @notice Minimal stand-in for the L1 Avalanche ICTT
 *         `ERC20TokenHome` used by `OmniValidatorRewards._routeOverflow`.
 * @dev Records every successful send + supports programmable revert.
 *      Pulls the underlying ERC-20 from the caller via SafeERC20
 *      `transferFrom` to mirror the lock/release pattern.
 */
contract MockICTTTokenHome {
    using SafeERC20 for IERC20;

    /// @notice Re-exported SendTokensInput (matches the canonical
    ///         ICTT struct in OmniValidatorRewards.sol).
    struct SendTokensInput {
        bytes32 destinationBlockchainID;
        address destinationTokenTransferrerAddress;
        address recipient;
        address primaryFeeTokenAddress;
        uint256 primaryFee;
        uint256 secondaryFee;
        uint256 requiredGasLimit;
        address multiHopFallback;
    }

    /// @notice One recorded send call.
    struct SendRecord {
        bytes32 destinationBlockchainID;
        address destinationTokenTransferrerAddress;
        address recipient;
        uint256 amount;
    }

    /// @notice Underlying ERC-20 the TokenHome bridges.
    IERC20 public immutable xom;

    /// @notice If true, the next `send()` call reverts.
    bool public shouldRevert;

    /// @notice Ordered list of every successful send call.
    SendRecord[] public sends;

    /// @notice Number of recorded sends.
    /// @return n `sends.length`.
    function sendCount() external view returns (uint256 n) {
        return sends.length;
    }

    /// @notice Most recent recorded send.
    /// @return record Last entry (reverts if empty).
    function lastSend() external view returns (SendRecord memory record) {
        return sends[sends.length - 1];
    }

    /**
     * @notice Construct with the underlying ERC-20.
     * @param xom_ The XOM ERC-20 on the home chain.
     */
    constructor(address xom_) {
        xom = IERC20(xom_);
    }

    /// @notice Programmatic flip: make the next `send` revert.
    /// @param v Revert flag.
    function setShouldRevert(bool v) external {
        shouldRevert = v;
    }

    /**
     * @notice Mock of `IERC20TokenTransferrer.send`.
     * @dev Not payable (matches the real ICTT signature). Pulls
     *      `amount` of the underlying ERC-20 from `msg.sender` via
     *      `safeTransferFrom`, then records the call.
     * @param input Send parameters.
     * @param amount Amount to bridge.
     */
    function send(
        SendTokensInput calldata input,
        uint256 amount
    ) external {
        if (shouldRevert) revert("MockICTTTokenHome: forced revert");
        xom.safeTransferFrom(msg.sender, address(this), amount);
        sends.push(
            SendRecord({
                destinationBlockchainID: input.destinationBlockchainID,
                destinationTokenTransferrerAddress: input
                    .destinationTokenTransferrerAddress,
                recipient: input.recipient,
                amount: amount
            })
        );
    }
}
