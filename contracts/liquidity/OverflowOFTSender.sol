// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from
    "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step} from
    "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from
    "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

// ══════════════════════════════════════════════════════════════════════
//                              INTERFACES + TYPES
// ══════════════════════════════════════════════════════════════════════

// solhint-disable ordering

/**
 * @title SendParam
 * @author OmniBazaar Team
 * @notice LayerZero V2 OFT send parameters (local mirror).
 * @dev Mirrors `@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol`.
 *      Declared locally so this contract does not pull the full LZ
 *      OFT SDK into its build surface.
 * @param dstEid Destination LZ endpoint ID.
 * @param to Recipient address on destination (bytes32 left-padded).
 * @param amountLD Send amount in local decimals.
 * @param minAmountLD Min amount received (slippage guard).
 * @param extraOptions Executor options (gas, native drop, …).
 * @param composeMsg Compose payload (unused — empty).
 * @param oftCmd OFT-specific opcode payload (unused — empty).
 */
struct SendParam {
    uint32 dstEid;
    bytes32 to;
    uint256 amountLD;
    uint256 minAmountLD;
    bytes extraOptions;
    bytes composeMsg;
    bytes oftCmd;
}

/**
 * @title MessagingFee
 * @author OmniBazaar Team
 * @notice LayerZero V2 messaging fee (local mirror).
 * @param nativeFee Native gas fee on the source chain.
 * @param lzTokenFee Optional LZ-token fee (unused here).
 */
struct MessagingFee {
    uint256 nativeFee;
    uint256 lzTokenFee;
}

/**
 * @title MessagingReceipt
 * @author OmniBazaar Team
 * @notice LayerZero V2 messaging receipt (local mirror).
 * @param guid Message GUID.
 * @param nonce Outbound nonce on the path.
 * @param fee Fee charged for the send.
 */
struct MessagingReceipt {
    bytes32 guid;
    uint64 nonce;
    MessagingFee fee;
}

/**
 * @title OFTReceipt
 * @author OmniBazaar Team
 * @notice LayerZero V2 OFT receipt (local mirror).
 * @param amountSentLD Amount actually debited.
 * @param amountReceivedLD Amount expected on the destination chain.
 */
struct OFTReceipt {
    uint256 amountSentLD;
    uint256 amountReceivedLD;
}

/**
 * @title IXOMOftSender
 * @author OmniBazaar Team
 * @notice Minimal subset of LayerZero V2 IOFT used by
 *         `OverflowOFTSender.flush` to bridge XOM from Avalanche
 *         C-Chain to remote chains.
 * @dev We declare only `send` + `quoteSend` + `token` +
 *      `approvalRequired`. The full IOFT lives at
 *      `oft-evm/contracts/interfaces/IOFT.sol`.
 */
interface IXOMOftSender {
    /// @notice Execute a cross-chain OFT send.
    /// @param sendParam Send parameters.
    /// @param fee The fee budget. `msg.value` MUST equal `fee.nativeFee`.
    /// @param refundAddress Recipient for any excess native fee.
    /// @return msgReceipt LayerZero messaging receipt.
    /// @return oftReceipt OFT receipt (amountSentLD / amountReceivedLD).
    function send(
        SendParam calldata sendParam,
        MessagingFee calldata fee,
        address refundAddress
    )
        external
        payable
        returns (
            MessagingReceipt memory msgReceipt,
            OFTReceipt memory oftReceipt
        );

    /// @notice Get the underlying ERC-20 the OFT bridges.
    /// @return underlying Underlying ERC-20 address.
    function token() external view returns (address underlying);

    /// @notice Whether the OFT requires ERC-20 approval prior to send.
    /// @return required Approval-required flag.
    function approvalRequired() external view returns (bool required);

    /// @notice Quote the LZ native fee for a `send` call.
    /// @param sendParam Parameters of the planned send.
    /// @param payInLzToken Pay-in-LZ-token flag (unused; pass false).
    /// @return fee The quoted MessagingFee.
    function quoteSend(
        SendParam calldata sendParam,
        bool payInLzToken
    ) external view returns (MessagingFee memory fee);
}
// solhint-enable ordering

// ══════════════════════════════════════════════════════════════════════
//                              CONTRACT
// ══════════════════════════════════════════════════════════════════════

/**
 * @title OverflowOFTSender
 * @author OmniBazaar Team
 * @notice Avalanche C-Chain dispatcher for cross-chain Early-LP
 *         overflow rewards. Receives BridgedXOM via Avalanche ICTT
 *         from the L1 `OmniValidatorRewards`, then dispatches per-
 *         remote-chain shares via LayerZero V2 OFT to
 *         `OverflowOFTReceiver` instances on Ethereum, Arbitrum,
 *         Base, and Polygon.
 * @dev Deployed once on Avalanche C-Chain (chain ID 43114).
 *
 *      Architecture:
 *        L1 OmniValidatorRewards._routeOverflow
 *          → ICTT ERC20TokenHome.send
 *            (XOM bridged to BridgedXOM on C-Chain)
 *          → arrives at this contract as a plain ERC-20 transfer
 *          → permissionless `flush()` splits by weight + dispatches
 *            via `xomOftAdapter.send` per configured eid
 *          → arrives at `OverflowOFTReceiver` on the remote chain
 *          → permissionless `flush()` forwards to local LP pool.
 *
 *      Trustless properties:
 *        - `xomToken` + `xomOftAdapter` are `immutable` (set at
 *          construction; admin cannot rewire).
 *        - `flush()` is permissionless. Any caller can trigger
 *          dispatch. The destination receivers (set via
 *          `setChainReceiver`) and weights (`setChainWeight`) are
 *          admin-configurable but the contract has NO function that
 *          can move XOM to any address other than via OFT.send to the
 *          configured per-chain receivers. There is NO admin "rescue"
 *          for XOM — XOM is strict-locked-to-dispatch.
 *        - Owner has TWO narrow privileges: `recoverDust(non-XOM)`
 *          for misdirected ERC-20s, and configuration (per-chain
 *          weight + receiver, LZ fee reserve). Owner CANNOT divert
 *          XOM.
 *        - LZ native-fee reserve is contract-held; topped up
 *          permissionlessly via `receive()` or `topUpFeeReserve()`.
 *          Withdrawable only by owner via `withdrawFeeReserve`.
 *        - CEI: `flush()` debits `feeReserve` + bumps
 *          `totalDispatched` BEFORE every `OFT.send`; rollback on
 *          revert preserves invariants.
 *        - Skip-not-revert: when a chain's send fails (quote revert,
 *          send revert, fee reserve short), the share remains in the
 *          contract for the next `flush` call. No XOM is lost.
 *
 *      Source-verification note: this contract does NOT verify that
 *      incoming XOM came from the L1 OmniValidatorRewards via ICTT —
 *      anyone can transfer BridgedXOM to this address and have it
 *      dispatched to the LP pools. That's intentional and safe: it
 *      effectively allows third parties to "donate" to the cross-
 *      chain LP rewards, and the dispatch destinations are fixed to
 *      the configured OverflowOFTReceivers (which only flush into
 *      the LP pools).
 */
contract OverflowOFTSender is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ══════════════════════════════════════════════════════════════════
    //                              CONSTANTS
    // ══════════════════════════════════════════════════════════════════

    /// @notice Basis-points denominator for weight splits.
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @notice Maximum number of remote chains that may receive
    ///         cross-chain overflow.
    /// @dev Bounds the gas cost of `flush` iteration. Mainnet design
    ///      uses 4 chains (Ethereum, Arbitrum, Base, Polygon).
    uint256 public constant MAX_CHAIN_CONFIGS = 10;

    // ══════════════════════════════════════════════════════════════════
    //                              STORAGE
    // ══════════════════════════════════════════════════════════════════

    /// @notice BridgedXOM ERC-20 on Avalanche C-Chain (the token
    ///         minted by `ERC20TokenRemote_XOM` on ICTT delivery).
    /// @dev Immutable: prevents admin from redirecting which token is
    ///      treated as locked-to-dispatch.
    IERC20 public immutable xomToken;

    /// @notice The `XOMOftAdapter` on Avalanche C-Chain that bridges
    ///         BridgedXOM via LayerZero V2 OFT to remote chains.
    /// @dev Immutable: mainnet C-Chain
    ///      `0x7320c95A79698Af70c64a9Cc1b2c37F10657ccD7`. The adapter
    ///      pulls BridgedXOM via `transferFrom` on `send()`.
    address public immutable xomOftAdapter;

    /// @notice LayerZero V2 endpoint IDs configured to receive
    ///         cross-chain overflow shares.
    /// @dev Iterated by `flush`. Insert via `setChainReceiver()`;
    ///      remove via `removeChainConfig()`. Bounded by
    ///      `MAX_CHAIN_CONFIGS`.
    uint32[] public configuredEids;

    /// @notice Per-chain weight in basis points used to split the
    ///         receiver's XOM balance at `flush` time.
    /// @dev For each `eid` in `configuredEids`, the share is
    ///      `balance * chainWeightBps[eid] / sumOfWeights`. Pure
    ///      proportional split (sum need not equal
    ///      `BPS_DENOMINATOR`).
    mapping(uint32 => uint16) public chainWeightBps;

    /// @notice Per-chain `OverflowOFTReceiver` address (bytes32
    ///         left-padded for LZ V2).
    mapping(uint32 => bytes32) public chainReceiver;

    /// @notice Pre-paid native AVAX reserve for LayerZero relay
    ///         fees on outgoing OFT sends.
    /// @dev Decremented by the quoted native fee on every successful
    ///      send. When reserve is short, that chain is skipped and
    ///      the share is left in the contract for next flush.
    uint256 public feeReserve;

    /// @notice Cumulative XOM dispatched across all flushes (sum of
    ///         all per-chain sends). Monotonic.
    uint256 public totalDispatched;

    // ══════════════════════════════════════════════════════════════════
    //                              EVENTS
    // ══════════════════════════════════════════════════════════════════

    /// @notice Emitted when a chain receiver is set or cleared.
    /// @param eid LZ endpoint ID.
    /// @param receiver Receiver (bytes32 left-padded).
    event ChainReceiverUpdated(
        uint32 indexed eid,
        bytes32 indexed receiver
    );

    /// @notice Emitted when a chain weight is updated.
    /// @param eid LZ endpoint ID.
    /// @param oldBps Previous weight.
    /// @param newBps New weight.
    event ChainWeightUpdated(
        uint32 indexed eid,
        uint16 indexed oldBps,
        uint16 indexed newBps
    );

    /// @notice Emitted when a chain config is removed entirely.
    /// @param eid LZ endpoint ID.
    event ChainConfigRemoved(uint32 indexed eid);

    /// @notice Emitted when the LZ native-fee reserve is topped up.
    /// @param sender Address that funded the top-up.
    /// @param amount Native value added.
    /// @param newReserve New reserve total.
    event FeeReserveToppedUp(
        address indexed sender,
        uint256 indexed amount,
        uint256 indexed newReserve
    );

    /// @notice Emitted when native is withdrawn from the reserve.
    /// @param recipient Recipient.
    /// @param amount Amount withdrawn.
    /// @param newReserve New reserve total.
    event FeeReserveWithdrawn(
        address indexed recipient,
        uint256 indexed amount,
        uint256 indexed newReserve
    );

    /// @notice Emitted on every successful per-chain OFT dispatch.
    /// @param caller Address that triggered `flush`.
    /// @param eid Destination LZ endpoint ID.
    /// @param amount BridgedXOM dispatched.
    /// @param nativeFeePaid LZ native fee consumed.
    event Dispatched(
        address indexed caller,
        uint32 indexed eid,
        uint256 indexed amount,
        uint256 nativeFeePaid
    );

    /// @notice Emitted when a chain is skipped during `flush` due to
    ///         missing config / insufficient fee reserve / failed
    ///         send. The share is left in the contract for next flush.
    /// @param eid LZ endpoint ID skipped.
    /// @param amount Share that would have been dispatched.
    /// @param reason Skip reason: 1=zero receiver, 2=fee short,
    ///        3=quote revert, 4=send revert.
    event ChainSkipped(
        uint32 indexed eid,
        uint256 indexed amount,
        uint8 indexed reason
    );

    /// @notice Emitted when the owner recovers non-XOM dust.
    /// @param token ERC-20 recovered (never `xomToken`).
    /// @param to Recipient.
    /// @param amount Amount recovered.
    event DustRecovered(
        address indexed token,
        address indexed to,
        uint256 indexed amount
    );

    // ══════════════════════════════════════════════════════════════════
    //                              ERRORS
    // ══════════════════════════════════════════════════════════════════

    /// @notice Provided address is the zero address.
    error ZeroAddress();

    /// @notice Provided amount is zero.
    error ZeroAmount();

    /// @notice Caller attempted to recover the locked `xomToken`.
    error CannotRecoverXOM();

    /// @notice The OFT adapter's underlying token does not match
    ///         `xomToken`.
    error AdapterTokenMismatch();

    /// @notice `MAX_CHAIN_CONFIGS` reached.
    error TooManyChainConfigs();

    /// @notice Caller operated on an unconfigured eid.
    error ChainNotConfigured();

    /// @notice Withdraw exceeds the current fee reserve.
    /// @param required Amount requested.
    /// @param available Reserve currently held.
    error InsufficientFeeReserve(uint256 required, uint256 available);

    /// @notice Native-fee withdrawal recipient rejected the transfer.
    error NativeTransferFailed();

    /// @notice `flush()` called with no XOM held + no work to do.
    error NothingToFlush();

    /// @notice No remote chains are configured with non-zero weight
    ///         + receiver. `flush()` would dispatch nothing.
    error NoActiveChains();

    // ══════════════════════════════════════════════════════════════════
    //                           CONSTRUCTOR
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Deploy the C-Chain dispatcher.
     * @param xomToken_ The BridgedXOM ERC-20 on Avalanche C-Chain
     *        (mainnet: `0xAF72f6caF76775DaEAbAf5C82Ce05D97359C8Fa1`).
     * @param xomOftAdapter_ The `XOMOftAdapter` on Avalanche C-Chain
     *        (mainnet: `0x7320c95A79698Af70c64a9Cc1b2c37F10657ccD7`).
     * @param owner_ Initial owner. Holds config + dust-recovery
     *        privileges; cannot divert XOM. Recommended: deployer for
     *        Pioneer Phase, governance later.
     */
    constructor(
        address xomToken_,
        address xomOftAdapter_,
        address owner_
    ) Ownable(owner_) {
        if (xomToken_ == address(0)) revert ZeroAddress();
        if (xomOftAdapter_ == address(0)) revert ZeroAddress();
        if (owner_ == address(0)) revert ZeroAddress();
        xomToken = IERC20(xomToken_);
        xomOftAdapter = xomOftAdapter_;
        // RT-07: guard against wiring an OFT adapter whose underlying
        // token differs from `xomToken` — every flush would otherwise
        // approve the wrong token and XOM would be permanently stuck.
        if (IXOMOftSender(xomOftAdapter_).token() != xomToken_) {
            revert AdapterTokenMismatch();
        }
    }

    // ══════════════════════════════════════════════════════════════════
    //                         PERMISSIONLESS OPS
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Dispatch the contract's current XOM balance across all
     *         configured remote chains by weight. Permissionless.
     * @dev For each `(eid, receiver, weightBps)` in `configuredEids`
     *      with non-zero `receiver` AND non-zero `weightBps`:
     *        share = balance * weightBps / sumOfActiveWeights
     *      The function calls `xomOftAdapter.send(...)` for each
     *      share, debits `feeReserve` by the quoted native fee, and
     *      bumps `totalDispatched`. On any send failure the chain is
     *      skipped (XOM remains in the contract for next flush).
     *
     *      Reverts with `NothingToFlush` if balance is zero.
     *      Reverts with `NoActiveChains` if no chain has weight > 0
     *      AND receiver != 0 (operator misconfig — XOM would have
     *      nowhere to go).
     *
     *      CEI per chain: approve adapter; debit feeReserve + bump
     *      totalDispatched BEFORE the external `send`; rollback in
     *      catch.
     *
     * @return totalSent Aggregate XOM dispatched in this call.
     */
    function flush()
        external
        nonReentrant
        returns (uint256 totalSent)
    {
        uint256 balance = xomToken.balanceOf(address(this));
        if (balance == 0) revert NothingToFlush();

        // Sum active weights (chains with both non-zero weight + non-
        // zero receiver).
        uint256 len = configuredEids.length;
        uint256 sumActiveWeights;
        for (uint256 i = 0; i < len;) {
            uint32 eid = configuredEids[i];
            if (
                chainReceiver[eid] != bytes32(0)
                    && chainWeightBps[eid] > 0
            ) {
                sumActiveWeights += chainWeightBps[eid];
            }
            unchecked { ++i; }
        }
        if (sumActiveWeights == 0) revert NoActiveChains();

        // Dispatch per chain.
        for (uint256 i = 0; i < len;) {
            uint32 eid = configuredEids[i];
            bytes32 receiver = chainReceiver[eid];
            uint16 wBps = chainWeightBps[eid];

            if (receiver == bytes32(0) || wBps == 0) {
                if (receiver == bytes32(0) && wBps > 0) {
                    emit ChainSkipped(eid, 0, 1);
                }
                unchecked { ++i; }
                continue;
            }

            uint256 share = (balance * wBps) / sumActiveWeights;
            if (share == 0) {
                unchecked { ++i; }
                continue;
            }

            // `_trySendOne` debits `feeReserve` + emits the
            // `Dispatched(eid, amount, nativeFeePaid)` event internally;
            // the caller only needs the success flag to accumulate
            // `totalSent`.
            (bool ok, ) = _trySendOne(eid, receiver, share);
            if (ok) {
                totalSent += share;
            }
            unchecked { ++i; }
        }
    }

    /**
     * @notice Top up the LayerZero native-fee reserve. Permissionless.
     * @dev Operator (or anyone) sends native AVAX along with this
     *      call; the contract records it as `feeReserve`. Used to
     *      pre-fund LZ relay fees consumed by `flush`. If LZ refunds
     *      excess fee to this contract (via the `refundAddress` arg),
     *      the raw native balance grows past `feeReserve`; calling
     *      `topUpFeeReserve()` with `msg.value == 0` reconciles by
     *      crediting the delta.
     */
    function topUpFeeReserve() external payable {
        if (msg.value == 0) {
            uint256 bal = address(this).balance;
            if (bal > feeReserve) {
                uint256 delta = bal - feeReserve;
                feeReserve = bal;
                emit FeeReserveToppedUp(msg.sender, delta, bal);
            }
            return;
        }
        feeReserve += msg.value;
        emit FeeReserveToppedUp(msg.sender, msg.value, feeReserve);
    }

    /**
     * @notice Plain `receive()` for raw native funding.
     * @dev Increments `feeReserve` and emits. Kept grouped with the
     *      other fee-reserve helpers for readability — solhint's
     *      ordering rule would prefer it earlier in the file but
     *      splitting it from `topUpFeeReserve` reduces clarity of
     *      the fee-reserve surface.
     */
    // solhint-disable-next-line ordering
    receive() external payable {
        if (msg.value > 0) {
            feeReserve += msg.value;
            emit FeeReserveToppedUp(msg.sender, msg.value, feeReserve);
        }
    }

    // ══════════════════════════════════════════════════════════════════
    //                         OWNER FUNCTIONS
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Set or clear the receiver address for a remote chain.
     * @dev Inserting a new `eid` pushes onto `configuredEids` (subject
     *      to `MAX_CHAIN_CONFIGS`). Setting receiver to `bytes32(0)`
     *      keeps the eid in the list but causes `flush` to skip it
     *      with reason=1; use `removeChainConfig` to fully remove.
     * @param eid Destination LZ V2 endpoint ID.
     * @param receiver Receiver address as bytes32 (left-padded).
     */
    function setChainReceiver(
        uint32 eid,
        bytes32 receiver
    ) external onlyOwner {
        if (!_isConfigured(eid)) {
            if (configuredEids.length > MAX_CHAIN_CONFIGS - 1) {
                revert TooManyChainConfigs();
            }
            configuredEids.push(eid);
        }
        chainReceiver[eid] = receiver;
        emit ChainReceiverUpdated(eid, receiver);
    }

    /**
     * @notice Set the per-chain weight in basis points.
     * @dev Weights are PROPORTIONAL — the sum need not equal
     *      `BPS_DENOMINATOR`. Passing `0` keeps the eid in the list
     *      but pauses sends to it (skip reason=1).
     * @param eid LZ endpoint ID. MUST be configured.
     * @param newBps New weight.
     */
    function setChainWeight(
        uint32 eid,
        uint16 newBps
    ) external onlyOwner {
        if (!_isConfigured(eid)) revert ChainNotConfigured();
        uint16 old = chainWeightBps[eid];
        chainWeightBps[eid] = newBps;
        emit ChainWeightUpdated(eid, old, newBps);
    }

    /**
     * @notice Remove a chain config entirely.
     * @dev Clears weight + receiver + splices the eid out of
     *      `configuredEids`. O(n) where n = `configuredEids.length`.
     * @param eid LZ endpoint ID.
     */
    function removeChainConfig(
        uint32 eid
    ) external onlyOwner {
        uint256 len = configuredEids.length;
        for (uint256 i = 0; i < len;) {
            if (configuredEids[i] == eid) {
                if (i != len - 1) {
                    configuredEids[i] = configuredEids[len - 1];
                }
                configuredEids.pop();
                delete chainWeightBps[eid];
                delete chainReceiver[eid];
                emit ChainConfigRemoved(eid);
                return;
            }
            unchecked { ++i; }
        }
        revert ChainNotConfigured();
    }

    /**
     * @notice Withdraw native from the fee reserve.
     * @dev Owner-only. CEI: decrement first, then call.
     * @param to Recipient.
     * @param amount Amount.
     */
    function withdrawFeeReserve(
        address payable to,
        uint256 amount
    ) external nonReentrant onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (amount > feeReserve) {
            revert InsufficientFeeReserve(amount, feeReserve);
        }
        feeReserve -= amount;
        // solhint-disable-next-line avoid-low-level-calls
        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert NativeTransferFailed();
        // solhint-disable-next-line reentrancy
        emit FeeReserveWithdrawn(to, amount, feeReserve);
    }

    /**
     * @notice Recover non-XOM ERC-20 tokens accidentally sent to this
     *         contract. Cannot move the locked `xomToken`.
     * @dev XOM lockout: the only path for XOM out of this contract is
     *      via `flush` to the configured OverflowOFTReceivers.
     * @param token ERC-20 token to recover. MUST NOT be `xomToken`.
     * @param to Recipient.
     * @param amount Amount.
     */
    function recoverDust(
        address token,
        address to,
        uint256 amount
    ) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        if (to == address(0)) revert ZeroAddress();
        if (token == address(xomToken)) revert CannotRecoverXOM();
        IERC20(token).safeTransfer(to, amount);
        emit DustRecovered(token, to, amount);
    }

    // ══════════════════════════════════════════════════════════════════
    //                          VIEW FUNCTIONS
    // ══════════════════════════════════════════════════════════════════

    /// @notice Number of configured remote chains.
    /// @return n `configuredEids.length`.
    function configuredEidsLength() external view returns (uint256 n) {
        return configuredEids.length;
    }

    /// @notice Pending XOM balance that would be dispatched on the
    ///         next `flush()` call.
    /// @return amount Current XOM balance held.
    function pendingBalance() external view returns (uint256 amount) {
        return xomToken.balanceOf(address(this));
    }

    // ══════════════════════════════════════════════════════════════════
    //                       INTERNAL FUNCTIONS
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Try to dispatch `amount` to `eid → receiver` via OFT.
     * @dev On any failure (quote revert, fee reserve short, send
     *      revert) returns `false` and the share remains in the
     *      contract for next flush. On success, decrements feeReserve
     *      + bumps totalDispatched BEFORE the send (CEI), rolls back
     *      in the catch.
     * @param eid Destination LZ endpoint ID.
     * @param receiver Destination receiver (bytes32 left-padded).
     * @param amount XOM amount.
     * @return ok Whether the send was executed.
     * @return feePaid Native fee actually paid (0 if skipped/failed).
     */
    function _trySendOne(
        uint32 eid,
        bytes32 receiver,
        uint256 amount
    ) internal returns (bool ok, uint256 feePaid) {
        SendParam memory sp = SendParam({
            dstEid: eid,
            to: receiver,
            amountLD: amount,
            // Sender-controlled amount; no MEV / sandwich surface.
            // The only loss vector is OFT shared-decimals rounding
            // (≤ 1e12 wei), which is acceptable for reward dust.
            minAmountLD: 0,
            extraOptions: bytes(""),
            composeMsg: bytes(""),
            oftCmd: bytes("")
        });

        uint256 nativeFee;
        try IXOMOftSender(xomOftAdapter).quoteSend(sp, false)
            returns (MessagingFee memory fee)
        {
            nativeFee = fee.nativeFee;
        } catch {
            emit ChainSkipped(eid, amount, 3);
            return (false, 0);
        }

        if (nativeFee > feeReserve) {
            emit ChainSkipped(eid, amount, 2);
            return (false, 0);
        }

        xomToken.forceApprove(xomOftAdapter, amount);

        // CEI: debit reserve + bump cumulative BEFORE send.
        feeReserve -= nativeFee;
        totalDispatched += amount;

        // solhint-disable-next-line check-send-result
        try IXOMOftSender(xomOftAdapter).send{value: nativeFee}(
            sp,
            MessagingFee({nativeFee: nativeFee, lzTokenFee: 0}),
            address(this)
        ) {
            emit Dispatched(msg.sender, eid, amount, nativeFee);
            return (true, nativeFee);
        } catch {
            // Roll back; share stays in the contract.
            // solhint-disable-next-line reentrancy
            feeReserve += nativeFee;
            // solhint-disable-next-line reentrancy
            totalDispatched -= amount;
            xomToken.forceApprove(xomOftAdapter, 0);
            emit ChainSkipped(eid, amount, 4);
            return (false, 0);
        }
    }

    /**
     * @notice O(n) check whether `eid` is in `configuredEids`.
     * @param eid Candidate LZ endpoint ID.
     * @return present True if already configured.
     */
    function _isConfigured(
        uint32 eid
    ) internal view returns (bool present) {
        uint256 len = configuredEids.length;
        for (uint256 i = 0; i < len;) {
            if (configuredEids[i] == eid) return true;
            unchecked { ++i; }
        }
        return false;
    }
}
