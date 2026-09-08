// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title  ReentrantNativeSeller
 * @author OmniBazaar Team
 * @notice Test-only contract that tries to call straight back into
 *         `NFTExchange.fulfillOrder` at each of the three moments a fill
 *         hands control away: when it is paid the marketplace fee, when it
 *         is paid a creator royalty, and when it receives an ERC-1155 item
 *         as the buyer.
 * @dev It records the revert data the re-entrant call comes back with, so
 *      a test can name the exact reason the call failed rather than
 *      assuming the guard was what stopped it. It can also simply refuse
 *      payment, which proves a sale fails loudly rather than the exchange
 *      quietly keeping money that is not ours.
 */
contract ReentrantNativeSeller {
    /// @notice Exchange to call back into.
    address public exchange;

    /// @notice Encoded `fulfillOrder` call to replay on being handed control.
    bytes public reenterCalldata;

    /// @notice Value to forward on the callback, so the re-entrant call
    ///         fails for the reason under test and not for want of money.
    uint256 public reenterValue;

    /// @notice When set, reject every incoming payment.
    bool public refuse;

    /// @notice Number of times the callback actually ran.
    uint256 public reentryAttempts;

    /// @notice Revert data the last callback came back with.
    bytes public lastRevertData;

    /// @notice Emitted with the outcome of each attempted callback.
    /// @param success Whether the re-entrant call succeeded.
    event ReentryAttempted(bool indexed success);

    /// @notice Payment was refused because {refuse} is set.
    error PaymentRefused();

    /// @notice A pass-through call failed and carried no revert data.
    error CallFailed();

    /// @notice Take payment, and try to re-enter the exchange if armed.
    /// @dev Deliberately not a simple receiver — being handed control at
    ///      exactly this moment is the whole point of the mock.
    receive() external payable { // solhint-disable-line no-complex-fallback
        if (refuse) revert PaymentRefused();
        _tryReenter();
    }

    /**
     * @notice Point the mock at an exchange and arm the callback.
     * @param exchange_        Exchange to call back into.
     * @param reenterCalldata_ Encoded call to replay, or empty for none.
     * @param reenterValue_    Native currency to forward on the callback.
     */
    function arm(
        address exchange_,
        bytes calldata reenterCalldata_,
        uint256 reenterValue_
    ) external {
        exchange = exchange_;
        reenterCalldata = reenterCalldata_;
        reenterValue = reenterValue_;
    }

    /**
     * @notice Make this contract reject incoming payments.
     * @param refuse_ True to reject.
     */
    function setRefuse(bool refuse_) external {
        refuse = refuse_;
    }

    /**
     * @notice Approve a collection to be moved by a conduit, so the mock
     *         can act as the seller in a fill.
     * @param collection Collection to approve.
     * @param conduit    Conduit to approve.
     */
    function approveCollection(address collection, address conduit) external {
        // solhint-disable-next-line avoid-low-level-calls
        (bool ok, ) = collection.call(
            abi.encodeWithSignature(
                "setApprovalForAll(address,bool)",
                conduit,
                true
            )
        );
        if (!ok) revert CallFailed();
    }

    /**
     * @notice Start a fill from this contract, so the mock can act as the
     *         buyer and be handed control by the ERC-1155 receiver hook.
     * @param callData Encoded `fulfillOrder` call.
     * @param value    Native currency to send with it.
     */
    function buy(bytes calldata callData, uint256 value) external {
        // solhint-disable-next-line avoid-low-level-calls
        (bool ok, bytes memory returned) = exchange.call{value: value}(
            callData
        );
        if (!ok) {
            if (returned.length == 0) revert CallFailed();
            // Bubble the original revert so the test sees the real reason.
            assembly {
                revert(add(returned, 0x20), mload(returned))
            }
        }
    }

    /**
     * @notice ERC-1155 receiver hook — the one callback an ERC-1155 fill
     *         cannot avoid, fired after every payment leg has landed.
     * @return selector The ERC-1155 acknowledgement selector.
     */
    function onERC1155Received(
        address,
        address,
        uint256,
        uint256,
        bytes calldata
    ) external returns (bytes4 selector) {
        _tryReenter();
        return this.onERC1155Received.selector;
    }

    /// @notice Call back into the exchange if armed, recording the outcome.
    function _tryReenter() private {
        if (reenterCalldata.length > 0) {
            ++reentryAttempts;
            // solhint-disable-next-line avoid-low-level-calls
            (bool ok, bytes memory returned) = exchange.call{
                value: reenterValue
            }(reenterCalldata);
            lastRevertData = returned;
            emit ReentryAttempted(ok);
        }
    }
}
