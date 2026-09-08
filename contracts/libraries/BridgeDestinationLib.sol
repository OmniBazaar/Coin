// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from
    "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IFeeSwapRouter} from "../interfaces/IFeeSwapRouter.sol";

/**
 * @title BridgeDestinationLib
 * @author OmniBazaar Team
 * @notice External library implementing UnifiedFeeVault's pinned ODDAO
 *         bridge destination (VT-21) AND the full `bridgeToTreasury` /
 *         `swapAndBridge` bodies. Split out of the vault to keep it
 *         under the 24 KiB EIP-170 limit — the vault impl was at
 *         24,575/24,576 bytes BEFORE VT-21, so every new byte of logic
 *         must live in a DELEGATECALL-linked library, not the vault.
 * @dev The ODDAO share accrued in `pendingBridge[token]` is moved by two
 *      BRIDGE_ROLE-gated entry points — `bridgeToTreasury` (in-kind) and
 *      `swapAndBridge` (swap to XOM then transfer). Before this library,
 *      BOTH took the destination as a pure caller parameter, so anyone
 *      holding `BRIDGE_ROLE` could redirect the entire ODDAO share to an
 *      address of their choosing. VT-21 pins both to a single
 *      `bridgeDestination` storage slot that only DEFAULT_ADMIN_ROLE can
 *      set, plus a one-way `lockBridgeDestination()` latch that makes it
 *      immutable at the deployer→governance handover. The caller-supplied
 *      `bridgeReceiver` argument is retained for ABI stability but must
 *      equal the stored destination or the call reverts
 *      `WrongDestination()` — it can no longer steer funds.
 *
 *      All entry points are `external`: Solidity links them via
 *      DELEGATECALL, so events are emitted as if from the vault and
 *      `address(this)` resolves to the vault. The library must never
 *      declare its own state variables; all state lives in the vault's
 *      slots and crosses the call boundary as parameters or storage
 *      references. The vault's stubs retain the `nonReentrant`,
 *      `onlyRole(BRIDGE_ROLE)`, and `whenNotPaused` modifiers, then
 *      delegatecall into the bodies below — so the reentrancy guard and
 *      role/pause checks are still enforced by the vault before any
 *      storage write or token transfer happens here.
 *
 *      Errors and events are declared here with byte-identical
 *      signatures to the vault's own copies (see
 *      `UnifiedFeeVault.WrongDestination` etc.) so the revert selector
 *      and event topic are the same regardless of which contract raised
 *      them.
 */
library BridgeDestinationLib {
    using SafeERC20 for IERC20;

    // ────────────────────────────────────────────────────────── errors ──
    // All signatures are byte-identical to UnifiedFeeVault's own copies so
    // the revert selector is the same whether raised here or in the vault.

    /// @notice Caller-supplied `bridgeReceiver` does not match the
    ///         pinned `bridgeDestination` — see
    ///         `UnifiedFeeVault.WrongDestination`.
    error WrongDestination();

    /// @notice `bridgeDestination` is already locked and can no longer
    ///         be changed — see `UnifiedFeeVault.BridgeDestinationLocked`.
    error BridgeDestinationLocked();

    /// @notice No `bridgeDestination` has been set yet (unreachable
    ///         after a correct initialize/upgrade, but guarded so a
    ///         misconfigured vault cannot burn to `address(0)`) — see
    ///         `UnifiedFeeVault.BridgeDestinationNotSet`.
    error BridgeDestinationNotSet();

    /// @notice A zero address was supplied where an account is required.
    error ZeroAddress();

    /// @notice A zero amount was supplied.
    error ZeroAmount();

    /// @notice The bridge amount exceeds the pending balance.
    /// @param requested The amount requested.
    /// @param available The pending balance available.
    error InsufficientPendingBalance(uint256 requested, uint256 available);

    /// @notice The swap router is not configured.
    error SwapRouterNotSet();

    /// @notice The XOM token is not configured.
    error XOMTokenNotSet();

    /// @notice The swap produced less than the required minimum output.
    /// @param received The actual XOM received.
    /// @param minimum The required minimum.
    error InsufficientSwapOutput(uint256 received, uint256 minimum);

    /// @notice The swap/bridge deadline has expired.
    error DeadlineExpired();

    // ────────────────────────────────────────────────────────── events ──

    /// @notice Emitted when ODDAO funds are bridged (in kind) — see
    ///         `UnifiedFeeVault.FeesBridged`.
    /// @param token ERC20 token address that was bridged.
    /// @param amount Amount bridged.
    /// @param recipient The pinned bridge destination.
    event FeesBridged(
        address indexed token,
        uint256 indexed amount,
        address indexed recipient
    );

    /// @notice Emitted when a fee token is swapped to XOM and bridged —
    ///         see `UnifiedFeeVault.FeesSwappedAndBridged`.
    /// @param token ERC20 fee token that was swapped.
    /// @param tokenAmount Amount of original token swapped.
    /// @param xomReceived Amount of XOM received from the swap.
    /// @param recipient The pinned bridge destination.
    event FeesSwappedAndBridged(
        address indexed token,
        uint256 indexed tokenAmount,
        uint256 xomReceived,
        address indexed recipient
    );

    /// @notice Emitted when DEFAULT_ADMIN_ROLE moves the pinned bridge
    ///         destination — see
    ///         `UnifiedFeeVault.BridgeDestinationUpdated`.
    /// @param oldDestination The destination before the change.
    /// @param newDestination The destination after the change.
    event BridgeDestinationUpdated(
        address indexed oldDestination,
        address indexed newDestination
    );

    /// @notice Emitted when DEFAULT_ADMIN_ROLE permanently locks the
    ///         bridge destination — see
    ///         `UnifiedFeeVault.BridgeDestinationLocked`.
    event BridgeDestinationLatched();

    // ──────────────────────────────────────────────────── bridge bodies ──

    /**
     * @notice Bridge accumulated ODDAO share to the pinned ODDAO
     *         treasury (in kind)
     * @dev Full body of `UnifiedFeeVault.bridgeToTreasury`, relocated
     *      here for the EIP-170 budget. The vault stub has already
     *      enforced `nonReentrant` + `onlyRole(BRIDGE_ROLE)` +
     *      `whenNotPaused`. Transfers `amount` of `token` to
     *      `bridgeDestination`, after asserting the caller-supplied
     *      `bridgeReceiver` matches it (`WrongDestination()` on
     *      mismatch, `BridgeDestinationNotSet()` if the destination is
     *      zero). Effects before interactions (CEI).
     * @param token ERC20 token to bridge (non-zero).
     * @param amount Amount to bridge (non-zero, ≤ pending).
     * @param bridgeReceiver Must equal `bridgeDestination` (pinned).
     * @param bridgeDestination The vault's pinned destination slot.
     * @param pendingBridge Storage ref to the vault's `pendingBridge`.
     * @param totalBridged Storage ref to the vault's `totalBridged`.
     */
    function bridgeToTreasury(
        address token,
        uint256 amount,
        address bridgeReceiver,
        address bridgeDestination,
        mapping(address => uint256) storage pendingBridge,
        mapping(address => uint256) storage totalBridged
    ) external {
        if (token == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        assertDestination(bridgeReceiver, bridgeDestination);

        uint256 pending = pendingBridge[token];
        if (amount > pending) {
            revert InsufficientPendingBalance(amount, pending);
        }

        // Effects first (CEI)
        pendingBridge[token] -= amount;
        totalBridged[token] += amount;

        // Interaction
        IERC20(token).safeTransfer(bridgeDestination, amount);

        emit FeesBridged(token, amount, bridgeDestination);
    }

    /**
     * @notice Swap a fee token to XOM and bridge to the pinned ODDAO
     *         treasury
     * @dev Full body of `UnifiedFeeVault.swapAndBridge`, relocated here
     *      for the EIP-170 budget. The vault stub has already enforced
     *      `nonReentrant` + `onlyRole(BRIDGE_ROLE)` + `whenNotPaused`.
     *      Deducts from `pendingBridge[token]`, swaps via the
     *      `swapRouter` adapter with a balance-before/after received
     *      check and a deadline, zeroes any residual router allowance,
     *      and transfers the XOM to the pinned `bridgeDestination`.
     * @param token ERC20 fee token to swap.
     * @param amount Amount of token to swap (≤ pending).
     * @param minXOMOut Minimum XOM output (slippage protection).
     * @param bridgeReceiver Must equal `bridgeDestination` (pinned).
     * @param deadline Timestamp by which the swap must execute.
     * @param bridgeDestination The vault's pinned destination slot.
     * @param swapRouter The vault's IFeeSwapRouter adapter slot.
     * @param xomToken The vault's XOM token slot.
     * @param pendingBridge Storage ref to the vault's `pendingBridge`.
     * @param totalBridged Storage ref to the vault's `totalBridged`.
     */
    function swapAndBridge(
        address token,
        uint256 amount,
        uint256 minXOMOut,
        address bridgeReceiver,
        uint256 deadline,
        address bridgeDestination,
        address swapRouter,
        address xomToken,
        mapping(address => uint256) storage pendingBridge,
        mapping(address => uint256) storage totalBridged
    ) external {
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (token == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (swapRouter == address(0)) revert SwapRouterNotSet();
        if (xomToken == address(0)) revert XOMTokenNotSet();
        assertDestination(bridgeReceiver, bridgeDestination);

        uint256 pending = pendingBridge[token];
        if (amount > pending) {
            revert InsufficientPendingBalance(amount, pending);
        }

        // Effects (CEI)
        pendingBridge[token] -= amount;
        totalBridged[token] += amount;

        // Interactions: approve adapter, execute swap
        IERC20(token).forceApprove(swapRouter, amount);

        uint256 xomBefore = IERC20(xomToken).balanceOf(address(this));

        IFeeSwapRouter(swapRouter).swapExactInput(
            token, xomToken, amount, minXOMOut,
            address(this), deadline
        );

        // Zero-out any allowance the router did not fully consume.
        IERC20(token).forceApprove(swapRouter, 0);

        uint256 xomReceived =
            IERC20(xomToken).balanceOf(address(this)) - xomBefore;

        if (xomReceived < minXOMOut) {
            revert InsufficientSwapOutput(xomReceived, minXOMOut);
        }

        // Transfer XOM to the pinned bridge destination
        IERC20(xomToken).safeTransfer(bridgeDestination, xomReceived);

        emit FeesSwappedAndBridged(
            token, amount, xomReceived, bridgeDestination
        );
    }

    // ─────────────────────────────────────────────── destination admin ──

    /**
     * @notice Compute the new pinned bridge destination for the vault
     * @dev The vault writes the returned value into its own
     *      `bridgeDestination` slot. Reverts if the destination is
     *      already latched (`bridgeDestinationLocked`) or if the
     *      proposed address is zero. No built-in delay: during Pioneer
     *      the DEPLOYER EOA is sole DEFAULT_ADMIN_ROLE and the one-way
     *      latch — not a timelock — is the "immutable at handover"
     *      mechanism (see the vault's `RECIPIENT_CHANGE_DELAY` NatSpec).
     * @param current The vault's current `bridgeDestination` (for the
     *        emitted event).
     * @param locked Whether the vault's `bridgeDestinationLocked` latch
     *        is already set.
     * @param newDestination The proposed pinned destination.
     * @return The value to store into `bridgeDestination`.
     */
    function setDestination(
        address current,
        bool locked,
        address newDestination
    ) external returns (address) {
        if (locked) revert BridgeDestinationLocked();
        if (newDestination == address(0)) revert ZeroAddress();
        emit BridgeDestinationUpdated(current, newDestination);
        return newDestination;
    }

    /**
     * @notice Compute the value for the vault's one-way latch
     * @dev The vault writes the returned `true` into its own
     *      `bridgeDestinationLocked` slot. Reverts if the latch is
     *      already set, so the event fires at most once and the
     *      destination becomes immutable.
     * @param currentLocked The vault's current
     *        `bridgeDestinationLocked` value.
     * @return The value to store into `bridgeDestinationLocked` (always
     *         true).
     */
    function lock(bool currentLocked) external returns (bool) {
        if (currentLocked) revert BridgeDestinationLocked();
        emit BridgeDestinationLatched();
        return true;
    }

    /**
     * @notice Enforce the VT-21 pin on a BRIDGE_ROLE bridge call
     * @dev The caller-supplied `bridgeReceiver` must equal the stored
     *      `bridgeDestination` (revert `WrongDestination()`), and the
     *      stored destination must be non-zero (revert
     *      `BridgeDestinationNotSet()`), so a vault upgraded without its
     *      destination seeded cannot silently transfer to `address(0)`.
     * @param bridgeReceiver The caller-supplied destination argument.
     * @param bridgeDestination The vault's stored pinned destination.
     */
    function assertDestination(
        address bridgeReceiver,
        address bridgeDestination
    ) internal pure {
        if (bridgeDestination == address(0)) {
            revert BridgeDestinationNotSet();
        }
        if (bridgeReceiver != bridgeDestination) {
            revert WrongDestination();
        }
    }
}
