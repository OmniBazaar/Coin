// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title OmniYieldFeeCollector
 * @author OmniCoin Development Team
 * @notice Collects a performance fee on yield earned through OmniBazaar
 *         and forwards the entire fee to the UnifiedFeeVault for
 *         protocol-standard 70/20/10 distribution.
 * @dev Users deposit directly into external DeFi protocols (Curve, Convex,
 *      Aave, Pendle, etc.). When they withdraw yield through OmniBazaar's
 *      UI, this contract collects the performance fee atomically.
 *
 * Flow (simple approach -- no vault wrapper):
 *   1. User withdraws yield from external protocol (off-chain step).
 *   2. User calls `collectFeeAndForward()` with their yield tokens.
 *   3. Contract deducts `performanceFeeBps` from the actual received amount.
 *   4. Fee is forwarded in full to the UnifiedFeeVault, which handles
 *      the 70/20/10 split (ODDAO / staking pool / protocol treasury).
 *   5. Net yield forwarded to user.
 *
 * Trustless guarantees:
 *   - Performance fee percentage is immutable (set at deploy).
 *   - Fee vault address is immutable (set at deploy).
 *   - Contract never holds user funds between transactions.
 *   - All token transfers use SafeERC20.
 *   - Reentrancy guard on every external entry point.
 *   - Fee-on-transfer tokens handled via balance-before/after pattern.
 */
contract OmniYieldFeeCollector is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // -----------------------------------------------------------------------
    // Constants
    // -----------------------------------------------------------------------

    /// @notice Basis-point denominator constant (10000 = 100%).
    uint256 private constant BPS_DENOMINATOR = 10_000;

    /// @notice Maximum allowed performance fee (10% = 1000 bps).
    uint256 private constant MAX_FEE_BPS = 1000;

    // -----------------------------------------------------------------------
    // State Variables (immutable + mutable)
    // -----------------------------------------------------------------------

    /// @notice UnifiedFeeVault address (receives 100% of collected fees
    ///         for protocol-standard 70/20/10 distribution).
    address public immutable feeVault; // solhint-disable-line immutable-vars-naming

    /// @notice Performance fee in basis points (e.g., 500 = 5%).
    uint256 public immutable performanceFeeBps; // solhint-disable-line immutable-vars-naming

    /// @notice Total fees collected per token (for transparency).
    mapping(address => uint256) public totalFeesCollected;

    // -----------------------------------------------------------------------
    // Events
    // -----------------------------------------------------------------------

    /// @notice Emitted when a performance fee is collected and forwarded
    ///         to the UnifiedFeeVault.
    /// @param user Address of the yield earner.
    /// @param token The yield token.
    /// @param actualReceived Actual amount received (after any transfer fee).
    /// @param totalFee Total fee forwarded to the UnifiedFeeVault.
    /// @param netAmount Net yield forwarded to user.
    event FeeCollected(
        address indexed user,
        address indexed token,
        uint256 indexed actualReceived,
        uint256 totalFee,
        uint256 netAmount
    );

    /// @notice Emitted when tokens are rescued from the contract.
    /// @param token The rescued token address.
    /// @param amount The amount rescued.
    event TokensRescued(
        address indexed token,
        uint256 indexed amount
    );

    // -----------------------------------------------------------------------
    // Custom Errors
    // -----------------------------------------------------------------------

    /// @notice Thrown when yield amount is zero.
    error ZeroAmount();

    /// @notice Thrown when token address is the zero address.
    error InvalidTokenAddress();

    /// @notice Thrown when the fee vault address is the zero address.
    error InvalidRecipient();

    /// @notice Thrown when performance fee exceeds safety cap.
    /// @param feeBps The provided fee in basis points
    /// @param maxBps The maximum allowed fee in basis points
    error FeeExceedsCap(uint256 feeBps, uint256 maxBps);

    /// @notice Thrown when caller is not the UnifiedFeeVault.
    error NotFeeVault();

    // -----------------------------------------------------------------------
    // Constructor
    // -----------------------------------------------------------------------

    /**
     * @notice Deploy the yield fee collector with a UnifiedFeeVault
     *         destination.
     * @dev The vault handles 70/20/10 distribution internally, so this
     *      contract only needs a single recipient address.
     * @param _feeVault            UnifiedFeeVault address (receives 100%
     *                             of collected fees).
     * @param _performanceFeeBps   Performance fee in basis points
     *                             (max 1000 = 10%).
     */
    constructor(
        address _feeVault,
        uint256 _performanceFeeBps
    ) {
        if (_feeVault == address(0)) revert InvalidRecipient();
        if (
            _performanceFeeBps == 0
            || _performanceFeeBps > MAX_FEE_BPS
        ) {
            revert FeeExceedsCap(_performanceFeeBps, MAX_FEE_BPS);
        }

        feeVault = _feeVault;
        performanceFeeBps = _performanceFeeBps;
    }

    // -----------------------------------------------------------------------
    // External Functions
    // -----------------------------------------------------------------------

    /**
     * @notice Collect performance fee from yield tokens and forward net
     *         to user. Supports fee-on-transfer tokens via balance
     *         measurement.
     * @dev User must have approved this contract for `yieldAmount` of
     *      `token`. The actual received amount may differ from
     *      `yieldAmount` for fee-on-transfer tokens. Fee and net
     *      amounts are calculated from the actual received balance.
     *      The entire fee is forwarded to the UnifiedFeeVault, which
     *      handles the protocol-standard 70/20/10 split.
     * @param token ERC20 yield token.
     * @param yieldAmount Total yield amount to transfer from user.
     */
    function collectFeeAndForward(
        address token,
        uint256 yieldAmount
    ) external nonReentrant {
        if (yieldAmount == 0) revert ZeroAmount();
        if (token == address(0)) revert InvalidTokenAddress();

        // Measure balance before transfer to handle fee-on-transfer tokens
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));

        // Pull yield tokens from user
        IERC20(token).safeTransferFrom(
            msg.sender, address(this), yieldAmount
        );

        // Calculate actual received (may be less for FoT tokens)
        uint256 actualReceived =
            IERC20(token).balanceOf(address(this)) - balanceBefore;

        // Calculate fee from actual received amount
        uint256 totalFee =
            (actualReceived * performanceFeeBps) / BPS_DENOMINATOR;
        uint256 netAmount = actualReceived - totalFee;

        // Forward entire fee to UnifiedFeeVault
        if (totalFee > 0) {
            _distributeFee(token, totalFee);
            totalFeesCollected[token] += totalFee;
        }

        // Forward net yield to user
        if (netAmount > 0) {
            IERC20(token).safeTransfer(msg.sender, netAmount);
        }

        emit FeeCollected(
            msg.sender, token, actualReceived, totalFee, netAmount
        );
    }

    /**
     * @notice Rescue tokens accidentally sent to this contract.
     * @dev Only callable by the UnifiedFeeVault. Sends all rescued
     *      tokens to the feeVault address.
     * @param token ERC20 token to rescue.
     */
    function rescueTokens(address token) external nonReentrant {
        if (msg.sender != feeVault) {
            revert NotFeeVault();
        }
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance > 0) {
            IERC20(token).safeTransfer(feeVault, balance);
            emit TokensRescued(token, balance);
        }
    }

    /**
     * @notice Calculate the fee for a given yield amount (view only).
     * @dev Does not account for fee-on-transfer tokens. For FoT tokens
     *      the actual fee will be lower since it is based on received
     *      amount rather than requested amount.
     * @param yieldAmount The yield amount to calculate fee for.
     * @return feeAmount The fee that would be collected.
     * @return netAmount The net amount after fee.
     */
    function calculateFee(
        uint256 yieldAmount
    )
        external
        view
        returns (uint256 feeAmount, uint256 netAmount)
    {
        feeAmount =
            (yieldAmount * performanceFeeBps) / BPS_DENOMINATOR;
        netAmount = yieldAmount - feeAmount;
    }

    // -----------------------------------------------------------------------
    // Internal Functions
    // -----------------------------------------------------------------------

    /**
     * @notice Forward the total fee to the UnifiedFeeVault.
     * @dev The vault handles the protocol-standard 70/20/10 split
     *      (ODDAO / staking pool / protocol treasury) internally.
     * @param token The ERC20 token to forward.
     * @param totalFee The total fee amount to send to the vault.
     */
    function _distributeFee(
        address token,
        uint256 totalFee
    ) internal {
        IERC20(token).safeTransfer(feeVault, totalFee);
    }
}
