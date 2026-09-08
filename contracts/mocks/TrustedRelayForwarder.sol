// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title TrustedRelayForwarder
 * @author OmniBazaar Team — TEST ONLY
 * @notice Minimal "permissive" ERC-2771-compatible forwarder used by
 *         unit tests. NOT for production deployment.
 * @dev The real OmniForwarder validates EIP-712 signatures + nonces
 *      and appends the meta-tx signer to the calldata. For unit
 *      tests we don't need the signature flow — the test itself
 *      constructs the suffixed calldata directly and passes it to
 *      this contract's `relay` function, which just forwards it
 *      verbatim via a low-level CALL.
 *
 *      Net effect: any contract that lists this forwarder as its
 *      `trustedForwarder` sees the test-supplied suffix-address as
 *      its `_msgSender()`, exactly as it would in production.
 */
contract TrustedRelayForwarder {
    /// @notice Emitted on every successful relay.
    /// @param target The target contract the call was forwarded to.
    /// @param caller The EOA that submitted the relay.
    /// @param success Underlying CALL success flag.
    event Relayed(
        address indexed target,
        address indexed caller,
        bool indexed success
    );

    /// @notice The target rejected the forwarded call.
    /// @param returnData Raw return data from the CALL.
    error TargetReverted(bytes returnData);

    /**
     * @notice Forward `data` to `target` via a low-level CALL.
     * @dev Reverts (with the target's revert data) on CALL failure.
     * @param target Address to call.
     * @param data Already-constructed calldata, including any
     *             ERC-2771 trailing sender-address suffix.
     * @return result Return data from the target call.
     */
    function relay(
        address target,
        bytes calldata data
    ) external payable returns (bytes memory result) {
        // solhint-disable-next-line avoid-low-level-calls
        (bool ok, bytes memory ret) = target.call{value: msg.value}(data);
        emit Relayed(target, msg.sender, ok);
        if (!ok) {
            // Re-revert with the original revert data when present.
            if (ret.length > 0) {
                // solhint-disable-next-line no-inline-assembly
                assembly {
                    revert(add(ret, 32), mload(ret))
                }
            }
            revert TargetReverted(ret);
        }
        return ret;
    }
}
