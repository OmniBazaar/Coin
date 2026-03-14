// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ERC2771Context} from "@openzeppelin/contracts/metatx/ERC2771Context.sol";
import {Context} from "@openzeppelin/contracts/utils/Context.sol";

/**
 * @title OmniPredictionRouter
 * @author OmniCoin Development Team
 * @notice Trustless fee-collecting router for prediction market trades.
 * @dev Deployed on Polygon (Polymarket) and Gnosis (Omen). Collects a
 *      capped fee atomically, then forwards the net amount to the target
 *      platform contract. Outcome tokens flow directly to the caller.
 *
 * Trustless guarantees:
 *   - Fee percentage is capped by immutable `MAX_FEE_BPS` (set at deploy).
 *   - Fee vault address is mutable (owner-only, for Pioneer Phase flexibility).
 *   - Contract never holds user funds between transactions.
 *   - All token transfers use SafeERC20 (reverts on failure).
 *   - Reentrancy guard on every external entry point.
 *   - Ownable2Step for safe two-step ownership transfer.
 *
 * Gas optimisations:
 *   - Immutable storage for fee cap.
 *   - Custom errors instead of revert strings.
 *
 * ERC-1155 compatibility:
 *   - Inherits ERC1155Holder so the contract can receive Polymarket CTF
 *     and Omen ConditionalTokens (both ERC-1155).
 *   - Provides `buyWithFeeAndSweepERC1155()` for ERC-1155 outcome token
 *     sweep after trade execution.
 */
contract OmniPredictionRouter is Ownable2Step, ReentrancyGuard, ERC1155Holder, ERC2771Context {
    using SafeERC20 for IERC20;

    // -----------------------------------------------------------------------
    // Constants
    // -----------------------------------------------------------------------

    /// @notice Basis-point denominator constant
    uint256 private constant BPS_DENOMINATOR = 10_000;

    /// @notice Minimum gas reserved for post-call operations (M-03 mitigation).
    uint256 private constant GAS_RESERVE = 50_000;

    /// @notice Timelock delay for fee vault address changes (48 hours)
    /// @dev FE-H-01 remediation: prevents instant fee redirection
    ///      by a compromised owner key
    uint256 public constant FEE_VAULT_DELAY = 48 hours;

    // -----------------------------------------------------------------------
    // Immutable State
    // -----------------------------------------------------------------------

    /// @notice Maximum fee in basis points (e.g. 200 = 2.00%)
    uint256 public immutable MAX_FEE_BPS; // solhint-disable-line immutable-vars-naming

    // -----------------------------------------------------------------------
    // Mutable State
    // -----------------------------------------------------------------------

    /// @notice UnifiedFeeVault address -- receives 100% of prediction fees for 70/20/10 distribution
    address public feeVault;

    /// @notice Pending fee vault address awaiting timelock acceptance
    /// @dev FE-H-01: Set by proposeFeeVault(), applied by acceptFeeVault()
    address public pendingFeeVault;

    /// @notice Timestamp when the fee vault change was proposed
    /// @dev FE-H-01: acceptFeeVault() requires
    ///      block.timestamp >= feeVaultChangeTimestamp + FEE_VAULT_DELAY
    uint256 public feeVaultChangeTimestamp;

    /// @notice Approved prediction market platforms that can be called
    /// @dev Only addresses in this mapping may be used as platformTarget
    mapping(address => bool) public approvedPlatforms;

    // -----------------------------------------------------------------------
    // Events
    // -----------------------------------------------------------------------

    /// @notice Emitted on every successful fee-collecting trade
    /// @param user         The trader's address
    /// @param collateral   The collateral token (USDC / WXDAI)
    /// @param totalAmount  Total amount pulled from user (including fee)
    /// @param feeAmount    Fee collected and sent to feeVault
    /// @param netAmount    Amount forwarded to the platform
    /// @param platform     Target platform contract address
    event TradeExecuted(
        address indexed user,
        address indexed collateral,
        uint256 totalAmount,
        uint256 feeAmount,
        uint256 netAmount,
        address indexed platform
    );

    /// @notice Emitted when a platform's approval status changes
    /// @param platform The platform contract address
    /// @param approved Whether the platform is now approved (true) or revoked (false)
    event PlatformApprovalChanged(
        address indexed platform,
        bool indexed approved
    );

    /// @notice Emitted when a fee vault address change is proposed
    /// @param current Current UnifiedFeeVault address
    /// @param proposed Proposed new UnifiedFeeVault address
    /// @param effectiveAt Timestamp when the change can be accepted
    event FeeVaultChangeProposed(
        address indexed current,
        address indexed proposed,
        uint256 effectiveAt
    );

    /// @notice Emitted when a proposed fee vault change is accepted
    /// @param oldVault Previous UnifiedFeeVault address
    /// @param newVault New UnifiedFeeVault address
    event FeeVaultChangeAccepted(
        address indexed oldVault,
        address indexed newVault
    );

    /// @notice Emitted when tokens are rescued from the contract
    /// @param token ERC20 token that was rescued
    /// @param amount Amount of tokens rescued
    event TokensRescued(
        address indexed token,
        uint256 indexed amount
    );

    // -----------------------------------------------------------------------
    // Custom Errors
    // -----------------------------------------------------------------------

    /// @notice Thrown when the requested fee exceeds the on-chain cap
    error FeeExceedsCap(uint256 feeAmount, uint256 maxAllowed);

    /// @notice Thrown when total amount is zero
    error ZeroAmount();

    /// @notice Thrown when fee is larger than total amount
    error FeeExceedsTotal(uint256 feeAmount, uint256 totalAmount);

    /// @notice Thrown when the platform call fails
    error PlatformCallFailed(address target, bytes reason);

    /// @notice Thrown when collateral token is the zero address
    error InvalidCollateralToken();

    /// @notice Thrown when platform target is invalid (zero address, not approved, self, or collateral)
    error InvalidPlatformTarget();

    /// @notice Thrown when the caller has insufficient outcome tokens after the trade
    error InsufficientOutcomeTokens();

    /// @notice Thrown when the transaction deadline has passed
    error DeadlineExpired();

    /// @notice Thrown when the provided fee vault address is invalid (zero address)
    error InvalidFeeVault();

    /// @notice Thrown when the outcome token address is invalid (zero address)
    error InvalidOutcomeToken();

    /// @notice Thrown when a fee-on-transfer token delivers less than expected (M-01)
    error FeeOnTransferNotSupported();

    /// @notice Thrown when no fee vault change is pending
    error NoFeeVaultChangePending();

    /// @notice Thrown when the fee vault timelock delay has not yet elapsed
    /// @param availableAt Timestamp when the change becomes available
    error FeeVaultTimelockActive(uint256 availableAt);

    /// @notice Thrown when the platform target has no deployed code (M-04)
    error PlatformNotContract();

    // -----------------------------------------------------------------------
    // Constructor
    // -----------------------------------------------------------------------

    /**
     * @notice Deploy the prediction router with an initial fee vault and cap.
     * @param feeVault_     UnifiedFeeVault address -- receives 100% of prediction fees
     *                      for 70/20/10 distribution (initial value, owner-changeable)
     * @param maxFeeBps_    Maximum fee in basis points (immutable, e.g. 200 = 2%)
     * @param trustedForwarder_ OmniForwarder address for gasless relay (address(0) to disable)
     */
    constructor(
        address feeVault_,
        uint256 maxFeeBps_,
        address trustedForwarder_
    ) Ownable(msg.sender) ERC2771Context(trustedForwarder_) {
        if (feeVault_ == address(0)) revert InvalidFeeVault();
        if (maxFeeBps_ == 0 || maxFeeBps_ > 1000) {
            // Cap cannot exceed 10% as a hard safety bound
            revert FeeExceedsCap(maxFeeBps_, 1000);
        }
        feeVault = feeVault_;
        MAX_FEE_BPS = maxFeeBps_;
    }

    // -----------------------------------------------------------------------
    // Admin Functions
    // -----------------------------------------------------------------------

    /**
     * @notice Propose a new UnifiedFeeVault address (step 1 of 2)
     * @dev FE-H-01 remediation: starts a 48-hour timelock before the
     *      new vault address can be accepted. This prevents a
     *      compromised owner from instantly redirecting all fees.
     *      Emits {FeeVaultChangeProposed}.
     * @param feeVault_ Proposed new UnifiedFeeVault address
     */
    function proposeFeeVault(
        address feeVault_
    ) external onlyOwner {
        if (feeVault_ == address(0)) revert InvalidFeeVault();

        pendingFeeVault = feeVault_;
        // solhint-disable-next-line not-rely-on-time
        feeVaultChangeTimestamp = block.timestamp;

        emit FeeVaultChangeProposed(
            feeVault,
            feeVault_,
            block.timestamp + FEE_VAULT_DELAY // solhint-disable-line not-rely-on-time
        );
    }

    /**
     * @notice Accept the pending fee vault address change (step 2 of 2)
     * @dev FE-H-01 remediation: can only be called after the 48-hour
     *      timelock has elapsed. Clears the pending state after
     *      applying the change. Emits {FeeVaultChangeAccepted}.
     */
    function acceptFeeVault() external onlyOwner {
        if (pendingFeeVault == address(0)) {
            revert NoFeeVaultChangePending();
        }

        uint256 availableAt =
            feeVaultChangeTimestamp + FEE_VAULT_DELAY;
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp < availableAt) {
            revert FeeVaultTimelockActive(availableAt);
        }

        address oldVault = feeVault;
        feeVault = pendingFeeVault;

        // Clear pending state
        pendingFeeVault = address(0);
        feeVaultChangeTimestamp = 0;

        emit FeeVaultChangeAccepted(oldVault, feeVault);
    }

    /**
     * @notice Add or remove a platform from the approved platforms list.
     * @dev Only callable by owner. Prevents the zero address from
     *      being approved.
     * @param platform Address of the platform contract to approve or revoke
     * @param approved True to approve, false to revoke
     */
    function setPlatformApproval(
        address platform,
        bool approved
    ) external onlyOwner {
        if (platform == address(0)) revert InvalidPlatformTarget();
        approvedPlatforms[platform] = approved;
        emit PlatformApprovalChanged(platform, approved);
    }

    // -----------------------------------------------------------------------
    // External Functions
    // -----------------------------------------------------------------------

    /**
     * @notice Execute a prediction market trade with atomic fee collection.
     * @dev Flow:
     *      1. Validate deadline has not passed.
     *      2. Validate platformTarget is on the approved platforms list.
     *      3. Pull `totalAmount` of `collateralToken` from caller.
     *      4. Send `feeAmount` to `feeVault`.
     *      5. Validate fee does not exceed `MAX_FEE_BPS` cap.
     *      6. Approve net amount to `platformTarget`.
     *      7. Call `platformTarget` with `platformData`.
     *
     *      WARNING: This function does NOT sweep outcome tokens. The caller
     *      MUST encode the recipient address in `platformData` so that the
     *      platform sends outcome tokens directly to `msg.sender`. If the
     *      platform sends ERC-20 tokens to this router instead, use
     *      `buyWithFeeAndSweep()`. For ERC-1155 outcome tokens (Polymarket
     *      CTF, Omen ConditionalTokens), use `buyWithFeeAndSweepERC1155()`.
     *
     * @param collateralToken ERC20 collateral (USDC on Polygon, WXDAI on Gnosis)
     * @param totalAmount     Total amount user wants to spend (fee inclusive)
     * @param feeAmount       Fee to collect (calculated off-chain, validated on-chain)
     * @param platformTarget  Address of the platform contract (FPMM, CTFExchange, etc.)
     * @param platformData    ABI-encoded call data for the platform contract
     * @param deadline        Unix timestamp after which the transaction reverts (MEV protection)
     */
    function buyWithFee(
        address collateralToken,
        uint256 totalAmount,
        uint256 feeAmount,
        address platformTarget,
        bytes calldata platformData,
        uint256 deadline
    ) external nonReentrant {
        address caller = _msgSender();
        uint256 netAmount = _validateTradeParams(
            collateralToken, totalAmount, feeAmount,
            platformTarget, deadline
        );

        _executeTrade(
            caller, collateralToken, totalAmount, feeAmount,
            netAmount, platformTarget, platformData
        );

        emit TradeExecuted(
            caller,
            collateralToken,
            totalAmount,
            feeAmount,
            netAmount,
            platformTarget
        );
    }

    /**
     * @notice Execute a trade and sweep ERC-20 outcome tokens back to caller.
     * @dev Same as buyWithFee but additionally transfers any ERC-20 outcome
     *      tokens received by this contract back to msg.sender. Use when the
     *      platform sends ERC-20 tokens to the router instead of directly to
     *      the caller. For ERC-1155 outcome tokens (Polymarket CTF, Omen
     *      ConditionalTokens), use `buyWithFeeAndSweepERC1155()` instead.
     *
     * @param collateralToken ERC20 collateral (USDC on Polygon, WXDAI on Gnosis)
     * @param totalAmount     Total amount user wants to spend (fee inclusive)
     * @param feeAmount       Fee to collect
     * @param platformTarget  Address of the platform contract
     * @param platformData    ABI-encoded call data for the platform contract
     * @param outcomeToken    ERC20 outcome token to sweep to caller after trade
     * @param minOutcome      Minimum outcome tokens expected (slippage protection)
     * @param deadline        Unix timestamp after which the transaction reverts (MEV protection)
     */
    function buyWithFeeAndSweep(
        address collateralToken,
        uint256 totalAmount,
        uint256 feeAmount,
        address platformTarget,
        bytes calldata platformData,
        address outcomeToken,
        uint256 minOutcome,
        uint256 deadline
    ) external nonReentrant {
        if (outcomeToken == address(0)) revert InvalidOutcomeToken();

        address caller = _msgSender();
        uint256 netAmount = _validateTradeParams(
            collateralToken, totalAmount, feeAmount,
            platformTarget, deadline
        );

        // --- M-02: Record ERC-20 outcome balance BEFORE trade ---
        uint256 outcomeBefore = IERC20(outcomeToken).balanceOf(
            address(this)
        );

        _executeTrade(
            caller, collateralToken, totalAmount, feeAmount,
            netAmount, platformTarget, platformData
        );

        // --- M-02: Sweep only the delta (prevents donation attack) ---
        uint256 outcomeReceived =
            IERC20(outcomeToken).balanceOf(address(this)) - outcomeBefore;
        if (outcomeReceived < minOutcome) {
            revert InsufficientOutcomeTokens();
        }
        if (outcomeReceived > 0) {
            IERC20(outcomeToken).safeTransfer(
                caller, outcomeReceived
            );
        }

        emit TradeExecuted(
            caller,
            collateralToken,
            totalAmount,
            feeAmount,
            netAmount,
            platformTarget
        );
    }

    /**
     * @notice Execute a trade and sweep ERC-1155 outcome tokens back to caller.
     * @dev Same as buyWithFeeAndSweep but handles ERC-1155 tokens (Polymarket
     *      CTF, Omen ConditionalTokens). The contract must inherit ERC1155Holder
     *      to receive these tokens. After executing the platform call, only the
     *      delta of ERC-1155 outcome tokens (balance after minus balance before)
     *      is transferred to `msg.sender` (M-02 donation attack mitigation).
     *
     * @param collateralToken ERC20 collateral (USDC on Polygon, WXDAI on Gnosis)
     * @param totalAmount     Total amount user wants to spend (fee inclusive)
     * @param feeAmount       Fee to collect
     * @param platformTarget  Address of the platform contract
     * @param platformData    ABI-encoded call data for the platform contract
     * @param outcomeToken    ERC-1155 outcome token contract address (CTF)
     * @param outcomeTokenId  ERC-1155 token ID for the specific outcome position
     * @param minOutcome      Minimum outcome tokens expected (slippage protection)
     * @param deadline        Unix timestamp after which the tx reverts (MEV protection)
     */
    function buyWithFeeAndSweepERC1155(
        address collateralToken,
        uint256 totalAmount,
        uint256 feeAmount,
        address platformTarget,
        bytes calldata platformData,
        address outcomeToken,
        uint256 outcomeTokenId,
        uint256 minOutcome,
        uint256 deadline
    ) external nonReentrant {
        if (outcomeToken == address(0)) revert InvalidOutcomeToken();

        address caller = _msgSender();
        uint256 netAmount = _validateTradeParams(
            collateralToken, totalAmount, feeAmount,
            platformTarget, deadline
        );

        // --- M-02: Record ERC-1155 outcome balance BEFORE trade ---
        uint256 outcomeBefore = IERC1155(outcomeToken).balanceOf(
            address(this), outcomeTokenId
        );

        _executeTrade(
            caller, collateralToken, totalAmount, feeAmount,
            netAmount, platformTarget, platformData
        );

        // --- M-02: Sweep only the delta (prevents donation attack) ---
        uint256 outcomeReceived = IERC1155(outcomeToken).balanceOf(
            address(this), outcomeTokenId
        ) - outcomeBefore;
        if (outcomeReceived < minOutcome) {
            revert InsufficientOutcomeTokens();
        }
        if (outcomeReceived > 0) {
            IERC1155(outcomeToken).safeTransferFrom(
                address(this), caller, outcomeTokenId,
                outcomeReceived, ""
            );
        }

        emit TradeExecuted(
            caller,
            collateralToken,
            totalAmount,
            feeAmount,
            netAmount,
            platformTarget
        );
    }

    /**
     * @notice Rescue tokens accidentally sent to this contract.
     * @dev Only callable by owner. Sends rescued tokens to the UnifiedFeeVault.
     * @param token ERC20 token to rescue
     */
    function rescueTokens(address token) external nonReentrant onlyOwner {
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance > 0) {
            IERC20(token).safeTransfer(feeVault, balance);
            emit TokensRescued(token, balance);
        }
    }

    /**
     * @notice Returns true if this contract implements the given interface
     * @param interfaceId Interface identifier to check
     * @return True if the interface is supported
     * @dev Required to resolve Ownable2Step vs ERC1155Holder conflict.
     */
    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    /**
     * @notice Disabled to prevent accidental loss of contract admin control
     * @dev Always reverts. Ownership can only be transferred via two-step
     *      {transferOwnership} + {acceptOwnership} flow.
     */
    function renounceOwnership() public pure override {
        revert InvalidFeeVault();
    }

    // -----------------------------------------------------------------------
    // Internal Overrides (ERC2771Context — resolve diamond with Ownable)
    // -----------------------------------------------------------------------

    /**
     * @notice Resolve _msgSender between Context (via Ownable)
     *         and ERC2771Context
     * @dev Returns the original user address when called through
     *      the trusted forwarder. Used by buyWithFee(),
     *      buyWithFeeAndSweep(), and buyWithFeeAndSweepERC1155()
     *      to identify the actual user.
     * @return The original transaction signer when relayed, or
     *         msg.sender when direct
     */
    function _msgSender()
        internal
        view
        override(Context, ERC2771Context)
        returns (address)
    {
        return ERC2771Context._msgSender();
    }

    /**
     * @notice Resolve _msgData between Context (via Ownable)
     *         and ERC2771Context
     * @dev Strips the appended sender address from calldata
     *      when relayed
     * @return The original calldata without the ERC2771 suffix
     */
    function _msgData()
        internal
        view
        override(Context, ERC2771Context)
        returns (bytes calldata)
    {
        return ERC2771Context._msgData();
    }

    /**
     * @notice Resolve _contextSuffixLength between Context
     *         and ERC2771Context
     * @dev Returns 20 (address length) for ERC2771 context
     *      suffix stripping
     * @return The number of bytes appended to calldata by the
     *         forwarder (20)
     */
    function _contextSuffixLength()
        internal
        view
        override(Context, ERC2771Context)
        returns (uint256)
    {
        return ERC2771Context._contextSuffixLength();
    }

    // -----------------------------------------------------------------------
    // Private Functions (mutating before view per solhint ordering)
    // -----------------------------------------------------------------------

    /**
     * @notice Execute the core trade logic: pull collateral, send fee,
     *         approve platform, and execute the platform call.
     * @dev Called by all buy functions after validation.
     *      M-01: Uses balance-before/after to detect fee-on-transfer tokens.
     *      M-03: Caps gas forwarded to the platform call so post-call
     *            operations (approval reset, sweep, event) cannot be starved.
     * @param caller          Address of the user (from _msgSender())
     * @param collateralToken ERC20 collateral token address
     * @param totalAmount     Total amount pulled from the user
     * @param feeAmount       Fee sent to the UnifiedFeeVault
     * @param netAmount       Amount approved and forwarded to the platform
     * @param platformTarget  Approved platform contract address
     * @param platformData    ABI-encoded call data for the platform
     */
    function _executeTrade(
        address caller,
        address collateralToken,
        uint256 totalAmount,
        uint256 feeAmount,
        uint256 netAmount,
        address platformTarget,
        bytes calldata platformData
    ) private {
        // --- M-01: Pull collateral with balance-before/after check ---
        uint256 balBefore = IERC20(collateralToken).balanceOf(address(this));
        IERC20(collateralToken).safeTransferFrom(
            caller, address(this), totalAmount
        );
        uint256 actualReceived =
            IERC20(collateralToken).balanceOf(address(this)) - balBefore;
        if (actualReceived != totalAmount) {
            revert FeeOnTransferNotSupported();
        }

        // --- Send fee to UnifiedFeeVault ---
        if (feeAmount > 0) {
            IERC20(collateralToken).safeTransfer(feeVault, feeAmount);
        }

        // --- Approve net amount to platform ---
        IERC20(collateralToken).forceApprove(platformTarget, netAmount);

        // --- M-03: Execute platform trade with gas reserve ---
        uint256 gasForCall = gasleft() - GAS_RESERVE;
        // solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory returnData) = platformTarget.call{
            gas: gasForCall
        }(platformData);
        if (!success) revert PlatformCallFailed(platformTarget, returnData);

        // Reset leftover approval to zero (gas refund + safety)
        IERC20(collateralToken).forceApprove(platformTarget, 0);
    }

    /**
     * @notice Validate that a platform target is safe to call.
     * @dev Checks that the target is non-zero, on the approved list,
     *      not the collateral token, and not this contract.
     * @param platformTarget  Address of the platform contract to validate
     * @param collateralToken Address of the collateral token (must differ from target)
     */
    function _validatePlatformTarget(
        address platformTarget,
        address collateralToken
    ) private view {
        if (platformTarget == address(0)) revert InvalidPlatformTarget();
        if (!approvedPlatforms[platformTarget]) {
            revert InvalidPlatformTarget();
        }
        if (platformTarget == collateralToken) {
            revert InvalidPlatformTarget();
        }
        if (platformTarget == address(this)) {
            revert InvalidPlatformTarget();
        }
        // M-04: Verify target has deployed code
        if (platformTarget.code.length == 0) {
            revert PlatformNotContract();
        }
    }

    /**
     * @notice Validate common trade parameters shared by both buy functions.
     * @dev Checks deadline, zero amounts, zero addresses, platform allowlist,
     *      fee-over-total, and fee cap. Delegates platform target validation
     *      to `_validatePlatformTarget`.
     * @param collateralToken ERC20 collateral token address
     * @param totalAmount     Total amount the user wants to spend (fee inclusive)
     * @param feeAmount       Fee to collect
     * @param platformTarget  Address of the platform contract
     * @param deadline        Unix timestamp after which the transaction reverts
     * @return netAmount      The amount remaining after the fee is deducted
     */
    function _validateTradeParams(
        address collateralToken,
        uint256 totalAmount,
        uint256 feeAmount,
        address platformTarget,
        uint256 deadline
    ) private view returns (uint256 netAmount) {
        // --- Deadline check ---
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp > deadline) revert DeadlineExpired();

        // --- Input validation ---
        if (totalAmount == 0) revert ZeroAmount();
        if (collateralToken == address(0)) revert InvalidCollateralToken();
        _validatePlatformTarget(platformTarget, collateralToken);
        if (feeAmount > totalAmount) {
            revert FeeExceedsTotal(feeAmount, totalAmount);
        }

        // --- On-chain fee cap enforcement ---
        uint256 maxAllowed = (totalAmount * MAX_FEE_BPS) / BPS_DENOMINATOR;
        if (feeAmount > maxAllowed) {
            revert FeeExceedsCap(feeAmount, maxAllowed);
        }

        netAmount = totalAmount - feeAmount;
    }
}
