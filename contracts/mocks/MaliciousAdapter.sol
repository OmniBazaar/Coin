// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from
    "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title ISwapAdapterForMalicious
 * @notice Local copy of the ISwapAdapter interface from OmniSwapRouter
 */
interface ISwapAdapterForMalicious {
    /// @notice Execute a token swap
    function executeSwap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address recipient
    ) external returns (uint256 amountOut);

    /// @notice Estimate swap output
    function getAmountOut(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external view returns (uint256 amountOut);
}

/**
 * @title IOmniSwapRouterTarget
 * @notice Minimal interface for calling back into OmniSwapRouter during attack
 */
interface IOmniSwapRouterTarget {
    /// @notice Single-hop swap function to re-enter
    function swap(
        bytes32 sourceId,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient,
        uint256 deadline
    ) external returns (uint256 amountOut);
}

/**
 * @title MaliciousAdapter
 * @author OmniBazaar Team
 * @notice ISwapAdapter that attempts reentrancy into OmniSwapRouter
 * @dev During executeSwap(), calls back into the router's swap() function
 *      to test reentrancy protection. Configurable attack modes:
 *
 *      Mode 0 (DISABLED): Normal adapter behavior (passthrough)
 *      Mode 1 (REENTER_SWAP): Re-enters router.swap() during executeSwap()
 *      Mode 2 (STEAL_TOKENS): Attempts to redirect output to attacker
 *      Mode 3 (RETURN_ZERO): Returns 0 amountOut while keeping tokens
 */
contract MaliciousAdapter is ISwapAdapterForMalicious {
    using SafeERC20 for IERC20;

    // ═══════════════════════════════════════════════════════════════════════
    //                          CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Normal behavior mode
    uint8 public constant MODE_DISABLED = 0;

    /// @notice Re-enter router.swap() during executeSwap()
    uint8 public constant MODE_REENTER_SWAP = 1;

    /// @notice Redirect output tokens to attacker
    uint8 public constant MODE_STEAL_TOKENS = 2;

    /// @notice Return zero output while keeping input tokens
    uint8 public constant MODE_RETURN_ZERO = 3;

    // ═══════════════════════════════════════════════════════════════════════
    //                          STATE
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice The router contract to re-enter
    IOmniSwapRouterTarget public router;

    /// @notice Current attack mode
    uint8 public attackMode;

    /// @notice Address to steal tokens to (MODE_STEAL_TOKENS)
    address public attacker;

    /// @notice Source ID to use in reentrant swap call
    bytes32 public reentrantSourceId;

    /// @notice Whether reentrancy was attempted
    bool public reentrancyAttempted;

    /// @notice Whether reentrancy succeeded (should always be false)
    bool public reentrancySucceeded;

    /// @notice Configurable exchange rate (output = input * rate / 1e18)
    uint256 public exchangeRate;

    // ═══════════════════════════════════════════════════════════════════════
    //                          EVENTS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Emitted when a reentrancy attack is attempted
    /// @param mode The attack mode used
    /// @param success Whether the reentrancy call succeeded
    event ReentrancyAttempt(uint8 mode, bool success);

    // ═══════════════════════════════════════════════════════════════════════
    //                        CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Deploy the malicious adapter
     * @param _exchangeRate Exchange rate for normal mode (output = input * rate / 1e18)
     */
    constructor(uint256 _exchangeRate) {
        exchangeRate = _exchangeRate;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                       CONFIGURATION
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Configure the reentrancy attack
     * @param _router Router contract to re-enter
     * @param _sourceId Source ID for the reentrant swap call
     * @param _attacker Address to redirect stolen tokens to
     */
    function configureAttack(
        address _router,
        bytes32 _sourceId,
        address _attacker
    ) external {
        router = IOmniSwapRouterTarget(_router);
        reentrantSourceId = _sourceId;
        attacker = _attacker;
    }

    /**
     * @notice Set the attack mode
     * @param _mode Attack mode (0-3)
     */
    function setAttackMode(uint8 _mode) external {
        attackMode = _mode;
    }

    /**
     * @notice Set the exchange rate for normal/steal modes
     * @param _rate New exchange rate
     */
    function setExchangeRate(uint256 _rate) external {
        exchangeRate = _rate;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                    ISWAP ADAPTER IMPLEMENTATION
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @inheritdoc ISwapAdapterForMalicious
     * @dev Behavior depends on attackMode:
     *      - MODE_DISABLED: Normal swap (pull input, mint output)
     *      - MODE_REENTER_SWAP: Pull input then re-enter router.swap()
     *      - MODE_STEAL_TOKENS: Pull input, send output to attacker
     *      - MODE_RETURN_ZERO: Pull input, return 0 (keep tokens)
     */
    function executeSwap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address recipient
    ) external override returns (uint256 amountOut) {
        // Always pull input tokens from the caller (the router)
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        if (attackMode == MODE_REENTER_SWAP) {
            return _attackReenterSwap(tokenIn, tokenOut, amountIn, recipient);
        } else if (attackMode == MODE_STEAL_TOKENS) {
            return _attackStealTokens(tokenOut, amountIn, recipient);
        } else if (attackMode == MODE_RETURN_ZERO) {
            // Keep input tokens, return 0 output
            return 0;
        }

        // MODE_DISABLED: normal behavior
        amountOut = (amountIn * exchangeRate) / 1e18;
        // solhint-disable-next-line avoid-low-level-calls
        (bool success,) = tokenOut.call(
            abi.encodeWithSignature("mint(address,uint256)", recipient, amountOut)
        );
        require(success, "MaliciousAdapter: mint failed");
    }

    /**
     * @inheritdoc ISwapAdapterForMalicious
     * @dev Returns estimated output based on exchange rate
     */
    function getAmountOut(
        address,
        address,
        uint256 amountIn
    ) external view override returns (uint256 amountOut) {
        amountOut = (amountIn * exchangeRate) / 1e18;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                       ATTACK HELPERS
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Attempt reentrancy into router.swap()
     * @param tokenIn Input token for the reentrant call
     * @param tokenOut Output token for the reentrant call
     * @param amountIn Amount for the reentrant call
     * @param recipient Original recipient
     * @return amountOut Always 0 (reentrancy should fail)
     */
    function _attackReenterSwap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address recipient
    ) internal returns (uint256 amountOut) {
        reentrancyAttempted = true;

        // Approve router to pull tokens for the reentrant call
        IERC20(tokenIn).approve(address(router), amountIn);

        // Attempt reentrancy — this SHOULD revert with ReentrancyGuard
        // solhint-disable-next-line no-empty-blocks
        try router.swap(
            reentrantSourceId,
            tokenIn,
            tokenOut,
            amountIn,
            0,
            recipient,
            // solhint-disable-next-line not-rely-on-time
            block.timestamp + 3600
        ) returns (uint256) {
            // If we get here, reentrancy protection failed
            reentrancySucceeded = true;
            emit ReentrancyAttempt(MODE_REENTER_SWAP, true);
        } catch {
            // Expected: reentrancy guard blocked the call
            reentrancySucceeded = false;
            emit ReentrancyAttempt(MODE_REENTER_SWAP, false);
        }

        return 0;
    }

    /**
     * @notice Attempt to redirect output tokens to attacker
     * @param tokenOut Output token to steal
     * @param amountIn Amount used to calculate output
     * @param recipient Legitimate recipient (ignored in attack)
     * @return amountOut Output amount reported to router
     */
    function _attackStealTokens(
        address tokenOut,
        uint256 amountIn,
        address recipient
    ) internal returns (uint256 amountOut) {
        amountOut = (amountIn * exchangeRate) / 1e18;

        // Mint to attacker instead of recipient
        address target = attacker != address(0) ? attacker : recipient;
        // solhint-disable-next-line avoid-low-level-calls
        (bool success,) = tokenOut.call(
            abi.encodeWithSignature("mint(address,uint256)", target, amountOut)
        );
        require(success, "MaliciousAdapter: steal mint failed");
    }
}
