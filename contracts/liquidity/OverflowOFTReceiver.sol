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
//                              INTERFACES
// ══════════════════════════════════════════════════════════════════════

/**
 * @title ILiquidityOverflowPoolReceiver
 * @author OmniBazaar Team
 * @notice Minimal interface for a remote-chain
 *         `LiquidityOverflowPoolPermissionless` that accepts pushed
 *         overflow rewards.
 * @dev `OverflowOFTReceiver` calls `distributeOverflow(amount)` after
 *      pulling XOM that the OFT mint deposited at the receiver.
 */
interface ILiquidityOverflowPoolReceiver {
    /**
     * @notice Distribute pushed overflow XOM across registered pools.
     * @param amount XOM amount being distributed.
     */
    function distributeOverflow(uint256 amount) external;
}

// ══════════════════════════════════════════════════════════════════════
//                              CONTRACT
// ══════════════════════════════════════════════════════════════════════

/**
 * @title OverflowOFTReceiver
 * @author OmniBazaar Team
 * @notice Trustless cross-chain landing pad for XOM overflow that was
 *         bridged from OmniCoin L1 via LayerZero OFT, then forwarded
 *         into the local-chain `LiquidityOverflowPoolPermissionless`.
 * @dev Deployed once per remote chain (Ethereum, Arbitrum, Base,
 *      Polygon). The L1 `OmniValidatorRewards._routeOverflow` calls
 *      `XOMOftAdapter.send(...)` with `to = address(this)`. The
 *      destination chain's `XOMOft` mints XOM to this address. Any
 *      caller can then invoke `flush()` to forward the entire balance
 *      to the immutable `localPool` for LP-staker accrual.
 *
 *      Trustless properties:
 *      - `localPool` is `immutable` and set at deploy time. It is the
 *        ONLY address that can receive XOM out of this contract via
 *        the normal path. No admin function can change it.
 *      - `xomToken` is `immutable`. The XOM ERC-20 cannot be swapped.
 *      - `flush()` is permissionless. Any caller (LP staker, keeper,
 *        passer-by) can trigger the forward. Cost is paid by caller.
 *      - The owner has ONE narrow privilege: `recoverDust(token)` for
 *        non-XOM tokens accidentally sent to this address. Calls
 *        targeting `xomToken` revert with {CannotRecoverXOM}, which
 *        makes XOM strictly locked-to-flush.
 *
 *      Design notes:
 *      - We deliberately do NOT inherit `OAppReceiver` or implement
 *        `_lzReceive`. The L1 sender (`OmniValidatorRewards`) is not
 *        itself an OApp — it calls `XOMOftAdapter.send()`, which is the
 *        OApp at the L1 boundary. The remote XOM mint happens in the
 *        local `XOMOft` (the destination OApp); the receiver only needs
 *        to *forward* the resulting balance, which a permissionless
 *        `flush()` does atomically without LZ Compose orchestration.
 *      - `flush()` is `nonReentrant`. The local pool's
 *        `distributeOverflow` does no callbacks today, but reentrancy
 *        guard adds defense-in-depth at near-zero cost.
 *      - On `localPool` revert, the approval is rolled back to zero so
 *        the contract leaves no dangling allowance.
 *
 *      Owner / Pioneer-Phase admin lifecycle:
 *      The deployer is the initial owner. `Ownable2Step` requires an
 *      explicit two-step handoff for any future swap to a governance
 *      contract (e.g. `OmniTimelockController`). Owner has no power
 *      over XOM flows; the only privileged action is `recoverDust` for
 *      non-XOM tokens.
 */
contract OverflowOFTReceiver is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ══════════════════════════════════════════════════════════════════
    //                              STORAGE
    // ══════════════════════════════════════════════════════════════════

    /// @notice The XOM ERC-20 on this chain (the remote `XOMOft`).
    /// @dev Immutable: prevents admin from redirecting which token is
    ///      treated as locked-to-flush.
    IERC20 public immutable xomToken;

    /// @notice The local `LiquidityOverflowPoolPermissionless` that
    ///         receives forwarded overflow.
    /// @dev Immutable: prevents admin from diverting overflow to an
    ///      attacker-controlled pool address.
    ILiquidityOverflowPoolReceiver public immutable localPool;

    /// @notice LayerZero V2 endpoint ID of the source chain (OmniCoin
    ///         L1) that this receiver expects overflow from.
    /// @dev View-only field for off-chain monitoring. The actual peer
    ///      verification happens at the `XOMOft` layer when the OFT
    ///      message is delivered; the receiver itself does not enforce
    ///      `srcEid` because it has no `_lzReceive` surface.
    uint32 public immutable srcEid;

    // ══════════════════════════════════════════════════════════════════
    //                              EVENTS
    // ══════════════════════════════════════════════════════════════════

    /// @notice Emitted on every successful flush to the local pool.
    /// @param caller Address that initiated the flush.
    /// @param amount XOM amount forwarded to the local pool.
    event Flushed(address indexed caller, uint256 indexed amount);

    /// @notice Emitted when the owner rescues non-XOM dust.
    /// @param token ERC-20 token recovered (never `xomToken`).
    /// @param to Recipient of the recovered balance.
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

    /// @notice Receiver currently holds no XOM.
    error NothingToFlush();

    /// @notice Caller attempted to recover the locked `xomToken`.
    error CannotRecoverXOM();

    /// @notice The local pool reverted on `distributeOverflow`.
    /// @param reason ABI-encoded revert reason from the pool.
    error PoolRejected(bytes reason);

    // ══════════════════════════════════════════════════════════════════
    //                           CONSTRUCTOR
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Deploy the receiver for one remote chain.
     * @param xomToken_ Address of the local-chain `XOMOft` (the OFT
     *                  that mints XOM to this contract on receipt of
     *                  an L1 cross-chain send).
     * @param localPool_ Address of the local-chain
     *                   `LiquidityOverflowPoolPermissionless` that
     *                   will receive the forwarded overflow.
     * @param srcEid_ LayerZero endpoint ID of OmniCoin L1 (the source
     *                from which overflow is bridged).
     * @param owner_ Initial owner. Holds only the `recoverDust`
     *               privilege; cannot redirect XOM. Recommended:
     *               deployer for Pioneer Phase, governance later.
     */
    constructor(
        address xomToken_,
        address localPool_,
        uint32 srcEid_,
        address owner_
    ) Ownable(owner_) {
        if (xomToken_ == address(0)) revert ZeroAddress();
        if (localPool_ == address(0)) revert ZeroAddress();
        if (owner_ == address(0)) revert ZeroAddress();

        xomToken = IERC20(xomToken_);
        localPool = ILiquidityOverflowPoolReceiver(localPool_);
        srcEid = srcEid_;
    }

    // ══════════════════════════════════════════════════════════════════
    //                         PERMISSIONLESS OPS
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Forward the entire XOM balance held by this contract to
     *         the immutable `localPool`.
     * @dev Permissionless. Any caller can trigger this — typically an
     *      LP staker, a keeper, or the L1 operator after triggering a
     *      cross-chain send. Reverts if no XOM is held or if the local
     *      pool rejects the distribution; in the latter case the
     *      approval is rolled back to zero before reverting so the
     *      receiver leaves no dangling allowance.
     *
     *      CEI: the balance read happens before any external call;
     *      the approval is to a known immutable address; the actual
     *      transfer is performed by the pool's `safeTransferFrom`.
     *
     * @return amount XOM amount forwarded.
     */
    function flush()
        external
        nonReentrant
        returns (uint256 amount)
    {
        amount = xomToken.balanceOf(address(this));
        if (amount == 0) revert NothingToFlush();

        // Approve the local pool to pull. forceApprove handles
        // non-conformant ERC-20s that revert on non-zero→non-zero
        // approve. XOM is OZ-conformant so plain approve would also
        // work; forceApprove is just defensive.
        xomToken.forceApprove(address(localPool), amount);

        // Try the distribute. The pool may return without pulling any
        // tokens (no active stakers — `liveWeight == 0`). Detect that
        // no-op: only emit `Flushed` when tokens actually moved, and
        // clear the approval so no dangling allowance remains. On a
        // genuine revert, clear the approval before bubbling the reason.
        try localPool.distributeOverflow(amount) {
            uint256 remaining = xomToken.balanceOf(address(this));
            if (remaining < amount) {
                amount = amount - remaining;
                emit Flushed(msg.sender, amount);
            } else {
                xomToken.forceApprove(address(localPool), 0);
                amount = 0;
            }
        } catch (bytes memory reason) {
            xomToken.forceApprove(address(localPool), 0);
            revert PoolRejected(reason);
        }
    }

    // ══════════════════════════════════════════════════════════════════
    //                         OWNER FUNCTIONS
    // ══════════════════════════════════════════════════════════════════

    /**
     * @notice Recover non-XOM ERC-20 tokens accidentally sent to this
     *         contract. Cannot move the locked `xomToken`.
     * @dev Only the owner can call. The XOM lockout makes this a safe
     *      escape hatch for misdirected USDC, wrong-token transfers,
     *      etc. — without weakening the trustless guarantee that the
     *      ONLY destination for XOM is `localPool`.
     * @param token ERC-20 token to recover. Must NOT be `xomToken`.
     * @param to Recipient for the recovered balance.
     * @param amount Amount to transfer.
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

    /**
     * @notice Read the XOM balance currently held by this receiver
     *         that would be forwarded on the next `flush()` call.
     * @return amount Current XOM balance held by this contract.
     */
    function pendingBalance() external view returns (uint256 amount) {
        return xomToken.balanceOf(address(this));
    }
}
