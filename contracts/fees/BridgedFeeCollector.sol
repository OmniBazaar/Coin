// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title BridgedFeeCollector
 * @author Omni Development DAO
 * @notice Per-external-chain protocol-fee sink that the operator
 *         periodically sweeps to OmniCoin L1's UnifiedFeeVault.
 *
 *         Designed to be the `FEE_VAULT` constructor arg for every Tier
 *         B router adapter + the `feeCollector` field on
 *         OmniFeeRouter, replacing the ODDAO Treasury EOA that's
 *         currently routed there. Solves the founder's 2026-05-28
 *         "no fees to deployer" directive at the architectural level:
 *         fees land in a contract that the operator can drain to L1
 *         on a deliberate schedule, instead of an EOA that mixes
 *         protocol revenue with hot-wallet usage.
 *
 *         Cross-chain bridging mechanism is INTENTIONALLY out-of-
 *         contract — there is no `bridgeToL1()` autopilot inside this
 *         contract because every external chain has a different
 *         USDC-to-L1 path (Polygon → CCTP → C-Chain → ICTT → L1;
 *         Ethereum → same; Arbitrum → CCTP; BSC → no CCTP, needs
 *         LayerZero or similar). Building a single in-contract
 *         multi-path bridger would either (a) hardcode all paths +
 *         break when partner contracts change, or (b) require trusted
 *         off-chain relayers. Owner-callable `sweep` to an
 *         operator-chosen destination is the simplest correct shape:
 *         the operator picks the bridge per-call.
 *
 *         Trustless properties:
 *         - Owner-only `sweep` / `sweepAll` reject calls whose swept
 *           `amount` is below the configured per-token `minSweepAmount`
 *           — this blocks dust-sized sweeps (avoids wasting a bridge tx
 *           on trivial amounts once sweeps are relayer-delegated). It is
 *           NOT a residual-balance reserve: the owner can still drain the
 *           full balance in one call. Any reserve policy lives at the
 *           operator multisig, not on-chain.
 *         - `renounceOwnership()` is DISABLED (reverts): the owner is the
 *           only party that can move fees out, so renouncing would
 *           permanently lock every collected token. Ownership can be
 *           rotated (2-step) but never dropped.
 *         - Non-upgradeable BY DESIGN: a transient fund holder the owner
 *           can always fully drain, so there is no upgrade key to
 *           compromise and no way a missing upgrade traps funds (sweep
 *           out, redeploy, re-point routers). Deliberate deviation from
 *           the codebase's usual UUPS pattern.
 *         - 2-step owner rotation via OpenZeppelin Ownable2Step
 *           (`transferOwnership` → `acceptOwnership`) — the new owner
 *           MUST explicitly accept, so a typo in `transferOwnership`
 *           cannot brick the contract. There is NO time delay; if
 *           operator policy needs a 24h gate, layer it at the
 *           operator multisig / Safe level.
 *         - Pausable via `pause()` for emergency stops; pauses ONLY
 *           the sweep path; deposits keep arriving.
 *         - `rescueETH()` separate from `sweep` so accidental ETH sent
 *           here doesn't get mixed with fee accounting. Both functions
 *           carry `nonReentrant` for defense-in-depth.
 *
 *         Decision: founder-authorized 2026-05-28 (Option 3 of the
 *         deployer-EOA-fee-routing CSW). See
 *         `memory/decision_fee_coverage_goal_2026-05-28.md`.
 *
 *         Phase B of `the internal revenue-tier plan` — deploy on
 *         Ethereum, Polygon, Arbitrum, Avalanche, BSC. Update Tier B
 *         adapters + OmniFeeRouters on each chain to point at the
 *         chain-local BridgedFeeCollector.
 */
contract BridgedFeeCollector is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // -----------------------------------------------------------------------
    // State
    // -----------------------------------------------------------------------

    /// @notice When `true`, `sweep` reverts. Deposits keep working.
    bool public sweepPaused;

    /// @notice Per-token minimum SIZE of a single sweep call. `sweep` /
    ///         `sweepAll` revert if the amount being swept is below this
    ///         floor. Defaults to 0 (no minimum) until the owner calls
    ///         `setMinSweepAmount`. This is a minimum per-call amount to
    ///         avoid wasting a bridge transaction on dust once sweeps are
    ///         relayer-delegated — it is NOT a residual-balance reserve
    ///         (the owner can still drain the full balance in one call).
    mapping(address token => uint256 amount) public minSweepAmount;

    // -----------------------------------------------------------------------
    // Events
    // -----------------------------------------------------------------------

    /**
     * @notice Emitted when the owner sweeps accumulated fees to a destination.
     * @param token Address of the ERC-20 token swept.
     * @param destination Address that received the swept tokens.
     * @param amount Amount of tokens transferred.
     * @param caller The owner address that triggered the sweep.
     */
    event Swept(
        address indexed token,
        address indexed destination,
        uint256 amount,
        address indexed caller
    );

    /**
     * @notice Emitted when the owner sweeps native chain currency.
     * @param destination Address that received the native value.
     * @param amount Wei amount transferred.
     */
    event RescuedETH(address indexed destination, uint256 amount); // solhint-disable-line gas-indexed-events

    /**
     * @notice Emitted when the per-token minimum sweep amount changes.
     * @param token Address of the ERC-20.
     * @param amount New minimum in token base units.
     */
    event MinSweepAmountUpdated(address indexed token, uint256 amount); // solhint-disable-line gas-indexed-events

    /**
     * @notice Emitted when sweep is paused or unpaused.
     * @param paused True if sweeping is now disabled.
     */
    event SweepPausedUpdated(bool paused); // solhint-disable-line gas-indexed-events

    // -----------------------------------------------------------------------
    // Errors
    // -----------------------------------------------------------------------

    /// @dev Reverts on sweep when the requested amount falls below the
    ///      configured `minSweepAmount` for the token.
    error BelowMinSweepAmount(uint256 requested, uint256 minimum);

    /// @dev Reverts when sweep is paused via {pause}.
    error SweepIsPaused();

    /// @dev Reverts on attempts to sweep to the zero address — would
    ///      effectively burn fee revenue.
    error ZeroDestination();

    /// @dev Reverts on attempts to sweep zero tokens — useless call.
    error ZeroAmount();

    /// @dev Reverts on attempts to rescue ETH to the zero address.
    error ZeroETHDestination();

    /// @dev Reverts when the ETH rescue transfer fails (e.g. recipient
    ///      contract rejects native value).
    error ETHTransferFailed();

    /// @dev Reverts on `renounceOwnership()`. The owner is the only party
    ///      that can move fees out, so renouncing would permanently lock
    ///      every collected token. Ownership can be rotated (2-step) but
    ///      never dropped.
    error RenounceDisabled();

    /// @dev Reverts when `sweepAll` finds a zero token balance to sweep.
    error NothingToSweep();

    // -----------------------------------------------------------------------
    // Constructor
    // -----------------------------------------------------------------------

    /**
     * @notice Deploy the collector with an explicit non-deployer owner.
     * @dev Per the 2026-05-28 fee-coverage directive, the deploy
     *      script SHOULD pass a non-deployer multisig or ODDAO
     *      Treasury here. This contract does NOT itself check that
     *      `_owner` is non-deployer — that's a deploy-script concern,
     *      enforced in `scripts/deploy-bridged-feecollector.js`.
     * @param _owner Initial owner — receives admin / sweep / rotation
     *               rights. Should be a multisig or an EOA controlled
     *               by a non-deployer party.
     */
    constructor(address _owner) Ownable(_owner) {}

    /**
     * @notice Accept native chain currency. Owner can reclaim via
     *         {rescueETH}. Kept payable so a misrouted bridge tx
     *         doesn't revert silently and leave funds stuck in the
     *         sender's contract.
     */
    receive() external payable {}

    // -----------------------------------------------------------------------
    // Sweep — owner-only
    // -----------------------------------------------------------------------

    /**
     * @notice Send accumulated `token` balance to `destination`.
     *         Operator picks the destination per-call so the choice
     *         of cross-chain bridge (CCTP, LayerZero, OmniBridge,
     *         etc.) lives off-chain in the operator's workflow.
     * @dev Reverts if `sweepPaused`, `destination == address(0)`,
     *      `amount == 0`, or `amount < minSweepAmount[token]`.
     * @param token Address of the ERC-20 to sweep.
     * @param destination Address that receives the swept tokens.
     *                    Typically a bridge contract or an
     *                    intermediate hot wallet operated by the
     *                    fee-sweep relayer.
     * @param amount Amount of `token` to transfer.
     */
    function sweep(
        address token,
        address destination,
        uint256 amount
    ) external onlyOwner nonReentrant {
        if (sweepPaused) revert SweepIsPaused();
        if (destination == address(0)) revert ZeroDestination();
        if (amount == 0) revert ZeroAmount();
        uint256 floor = minSweepAmount[token];
        if (amount < floor) revert BelowMinSweepAmount(amount, floor);

        IERC20(token).safeTransfer(destination, amount);
        emit Swept(token, destination, amount, msg.sender);
    }

    /**
     * @notice Sweep the ENTIRE `token` balance to `destination` in one call.
     * @dev Convenience wrapper over {sweep} for the common "drain everything"
     *      operation. Removes the read-balance-then-submit-amount race: the
     *      full balance is read and transferred atomically, so a fee deposit
     *      landing between an off-chain balance read and this call is never
     *      left behind or double-counted. Applies the same guards as {sweep}:
     *      reverts if `sweepPaused`, `destination == address(0)`, the balance
     *      is zero (`NothingToSweep`), or the balance is below
     *      `minSweepAmount[token]`.
     * @param token Address of the ERC-20 to sweep in full.
     * @param destination Address that receives the entire balance.
     */
    function sweepAll(
        address token,
        address destination
    ) external onlyOwner nonReentrant {
        if (sweepPaused) revert SweepIsPaused();
        if (destination == address(0)) revert ZeroDestination();
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal == 0) revert NothingToSweep();
        uint256 floor = minSweepAmount[token];
        if (bal < floor) revert BelowMinSweepAmount(bal, floor);

        IERC20(token).safeTransfer(destination, bal);
        emit Swept(token, destination, bal, msg.sender);
    }

    /**
     * @notice Pause sweep operations. Deposits keep arriving.
     * @dev Owner-only. Emits {SweepPausedUpdated}.
     */
    function pause() external onlyOwner {
        sweepPaused = true;
        emit SweepPausedUpdated(true);
    }

    /**
     * @notice Resume sweep operations.
     * @dev Owner-only. Emits {SweepPausedUpdated}.
     */
    function unpause() external onlyOwner {
        sweepPaused = false;
        emit SweepPausedUpdated(false);
    }

    /**
     * @notice Set a minimum sweep amount for the given token.
     * @dev A zero value disables the floor for the token. Used to
     *      prevent dust sweeps when delegating to a relayer.
     * @param token Address of the ERC-20.
     * @param amount Minimum amount the sweep call must request.
     */
    function setMinSweepAmount(
        address token,
        uint256 amount
    ) external onlyOwner {
        minSweepAmount[token] = amount;
        emit MinSweepAmountUpdated(token, amount);
    }

    // -----------------------------------------------------------------------
    // Rescue paths
    // -----------------------------------------------------------------------

    /**
     * @notice Recover native chain currency (ETH / MATIC / BNB / AVAX)
     *         accidentally sent to this contract.
     * @dev Native value should never normally land here — fees are
     *      always ERC-20. The rescue path exists for the inevitable
     *      operator-error case (a wrong-recipient bridge tx, an
     *      airdrop, etc.).
     * @param destination Address to send the recovered native value.
     */
    function rescueETH(address payable destination) external onlyOwner nonReentrant {
        if (destination == address(0)) revert ZeroETHDestination();
        uint256 bal = address(this).balance;
        if (bal == 0) revert ZeroAmount();
        (bool ok, ) = destination.call{value: bal}("");
        if (!ok) revert ETHTransferFailed();
        emit RescuedETH(destination, bal);
    }

    // -----------------------------------------------------------------------
    // Ownership
    // -----------------------------------------------------------------------

    /**
     * @notice Disabled. Renouncing ownership would permanently lock all
     *         collected fees, because the owner is the only party able to
     *         `sweep` / `sweepAll` / `rescueETH` funds out. Ownership can be
     *         rotated via {transferOwnership} + {acceptOwnership}, never
     *         dropped.
     * @dev Overrides OpenZeppelin `Ownable.renounceOwnership` to revert
     *      unconditionally (M-1 audit remediation). Stricter than the
     *      inherited `onlyOwner` no-op; honors the contract's documented
     *      brick-resistance guarantee.
     */
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }
}
