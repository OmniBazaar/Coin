// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from
    "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title MockXOMOftAdapter
 * @author OmniBazaar Team — TEST ONLY
 * @notice Minimal stand-in for the LayerZero V2 OFT/OFTAdapter that
 *         `OmniValidatorRewards._routeOverflow` calls on L1.
 * @dev Mirrors the surface of `IXOMOftSender` declared inline in
 *      `OmniValidatorRewards.sol`. Records every successful send for
 *      test assertions and supports per-eid programmable failure
 *      modes (revert-on-quote, revert-on-send, native-fee).
 *
 *      Behavior:
 *      - `quoteSend(sp, false)` returns `MessagingFee{nativeFee, 0}`
 *        where `nativeFee` is either the global `defaultFee` or a
 *        per-eid override set via `setFeeFor(eid, fee)`.
 *      - `send(sp, fee, refundAddr)` validates `msg.value ==
 *        fee.nativeFee`, pulls `amountLD` of XOM via SafeERC20
 *        `transferFrom`, then records the call. Optionally reverts
 *        when `shouldRevertSend[eid] == true`.
 *      - `approvalRequired()` returns `true` to mimic the L1
 *        adapter's lock/release pattern.
 *
 *      Out of scope:
 *      - No actual cross-chain message delivery. The receiving end
 *        is exercised separately in `OverflowOFTReceiver.flush.test.ts`.
 */
contract MockXOMOftAdapter {
    using SafeERC20 for IERC20;

    /// @notice One recorded send call.
    struct SendRecord {
        uint32 eid;
        bytes32 to;
        uint256 amount;
        uint256 nativeFeePaid;
    }

    /// @notice Re-exported SendParam (matches IXOMOftSender).
    struct SendParam {
        uint32 dstEid;
        bytes32 to;
        uint256 amountLD;
        uint256 minAmountLD;
        bytes extraOptions;
        bytes composeMsg;
        bytes oftCmd;
    }

    /// @notice Re-exported MessagingFee.
    struct MessagingFee {
        uint256 nativeFee;
        uint256 lzTokenFee;
    }

    /// @notice Re-exported MessagingReceipt.
    struct MessagingReceipt {
        bytes32 guid;
        uint64 nonce;
        MessagingFee fee;
    }

    /// @notice Re-exported OFTReceipt.
    struct OFTReceipt {
        uint256 amountSentLD;
        uint256 amountReceivedLD;
    }

    /// @notice Underlying XOM ERC-20.
    IERC20 public immutable xom;

    /// @notice Default native fee returned by `quoteSend` when no
    ///         per-eid override is set.
    uint256 public defaultFee;

    /// @notice Per-eid native fee override (0 = use default).
    mapping(uint32 => uint256) public feeFor;

    /// @notice Per-eid revert switch for `send`.
    mapping(uint32 => bool) public shouldRevertSend;

    /// @notice Per-eid revert switch for `quoteSend`.
    mapping(uint32 => bool) public shouldRevertQuote;

    /// @notice Ordered list of every successful send call.
    SendRecord[] public sends;

    /// @notice Get the count of recorded sends.
    /// @return n Number of `sends` entries.
    function sendCount() external view returns (uint256 n) {
        return sends.length;
    }

    /// @notice Get the most recent send record.
    /// @return record Last entry; reverts if empty.
    function lastSend() external view returns (SendRecord memory record) {
        return sends[sends.length - 1];
    }

    /**
     * @notice Deploy with the XOM token reference.
     * @param xom_ Underlying XOM ERC-20.
     */
    constructor(address xom_) {
        xom = IERC20(xom_);
        defaultFee = 0;
    }

    /// @notice Programmatic: set default fee (test setup).
    /// @param fee Native fee in wei.
    function setDefaultFee(uint256 fee) external {
        defaultFee = fee;
    }

    /// @notice Programmatic: override the fee for one eid (test setup).
    /// @param eid Destination eid.
    /// @param fee Native fee in wei.
    function setFeeFor(uint32 eid, uint256 fee) external {
        feeFor[eid] = fee;
    }

    /// @notice Programmatic: make `send(...)` revert for one eid.
    /// @param eid Destination eid.
    /// @param value Revert flag.
    function setShouldRevertSend(uint32 eid, bool value) external {
        shouldRevertSend[eid] = value;
    }

    /// @notice Programmatic: make `quoteSend(...)` revert for one eid.
    /// @param eid Destination eid.
    /// @param value Revert flag.
    function setShouldRevertQuote(uint32 eid, bool value) external {
        shouldRevertQuote[eid] = value;
    }

    /// @notice Mirror of IXOMOftSender.token().
    /// @return underlying The underlying ERC-20 address.
    function token() external view returns (address underlying) {
        return address(xom);
    }

    /// @notice Mirror of IXOMOftSender.approvalRequired().
    /// @return required Always true (L1 adapter pattern).
    function approvalRequired() external pure returns (bool required) {
        return true;
    }

    /// @notice Mirror of IXOMOftSender.quoteSend().
    /// @param sp Send parameters.
    /// @param payInLzToken Pay-in-LZ-token flag (ignored).
    /// @return fee The mocked MessagingFee.
    function quoteSend(
        SendParam calldata sp,
        bool payInLzToken
    ) external view returns (MessagingFee memory fee) {
        payInLzToken; // silence unused
        if (shouldRevertQuote[sp.dstEid]) {
            revert("MockXOMOftAdapter: quote revert");
        }
        uint256 f = feeFor[sp.dstEid];
        if (f == 0) f = defaultFee;
        return MessagingFee({nativeFee: f, lzTokenFee: 0});
    }

    /// @notice Mirror of IXOMOftSender.send().
    /// @param sp Send parameters.
    /// @param fee Fee budget. `msg.value` MUST match `fee.nativeFee`.
    /// @param refundAddress Recipient for any excess (unused here).
    /// @return msgReceipt The mocked messaging receipt.
    /// @return oftReceipt The mocked OFT receipt.
    function send(
        SendParam calldata sp,
        MessagingFee calldata fee,
        address refundAddress
    )
        external
        payable
        returns (
            MessagingReceipt memory msgReceipt,
            OFTReceipt memory oftReceipt
        )
    {
        refundAddress; // silence unused
        if (shouldRevertSend[sp.dstEid]) {
            revert("MockXOMOftAdapter: send revert");
        }
        require(
            msg.value == fee.nativeFee,
            "MockXOMOftAdapter: bad msg.value"
        );

        xom.safeTransferFrom(msg.sender, address(this), sp.amountLD);

        sends.push(
            SendRecord({
                eid: sp.dstEid,
                to: sp.to,
                amount: sp.amountLD,
                nativeFeePaid: msg.value
            })
        );

        msgReceipt = MessagingReceipt({
            guid: keccak256(
                abi.encodePacked(
                    sp.dstEid,
                    sp.to,
                    sp.amountLD,
                    block.number,
                    sends.length
                )
            ),
            nonce: uint64(sends.length),
            fee: fee
        });
        oftReceipt = OFTReceipt({
            amountSentLD: sp.amountLD,
            amountReceivedLD: sp.amountLD
        });
    }
}
