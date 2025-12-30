// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IRWAPool} from "./interfaces/IRWAPool.sol";

/**
 * @title RWAPool
 * @author OmniCoin Development Team
 * @notice Liquidity pool for RWA/XOM token pairs
 * @dev Implements constant-product AMM with LP token minting
 *
 * Key Features:
 * - Constant-product formula (x * y = k)
 * - LP tokens as ERC20 for composability
 * - Cumulative price oracles (TWAP support)
 * - Reentrancy protection via lock
 * - Flash swap support via callback
 *
 * Security Features:
 * - Reentrancy lock
 * - Minimum liquidity lock (1000 wei)
 * - K-value invariant check
 * - Balance synchronization
 */
contract RWAPool is ERC20, IRWAPool {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // ========================================================================
    // CONSTANTS
    // ========================================================================

    /// @inheritdoc IRWAPool
    uint256 public constant MINIMUM_LIQUIDITY = 1000;

    /// @notice Address to lock minimum liquidity
    address private constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    // ========================================================================
    // STATE VARIABLES
    // ========================================================================

    /// @notice Factory/AMM contract address
    address public factory;

    /// @inheritdoc IRWAPool
    address public token0;

    /// @inheritdoc IRWAPool
    address public token1;

    /// @notice Reserve of token0
    uint112 private reserve0;

    /// @notice Reserve of token1
    uint112 private reserve1;

    /// @notice Timestamp of last reserve update
    uint32 private blockTimestampLast;

    /// @inheritdoc IRWAPool
    uint256 public price0CumulativeLast;

    /// @inheritdoc IRWAPool
    uint256 public price1CumulativeLast;

    /// @inheritdoc IRWAPool
    uint256 public kLast;

    /// @notice Reentrancy lock
    uint256 private unlocked = 1;

    // ========================================================================
    // ERRORS
    // ========================================================================

    /// @notice Thrown when caller is not factory
    error NotFactory();

    /// @notice Thrown when pool is already initialized
    error AlreadyInitialized();

    /// @notice Thrown when recipient is invalid
    error InvalidRecipient();

    // ========================================================================
    // MODIFIERS
    // ========================================================================

    /**
     * @notice Reentrancy lock modifier
     */
    modifier lock() {
        if (unlocked != 1) revert Locked();
        unlocked = 0;
        _;
        unlocked = 1;
    }

    // ========================================================================
    // CONSTRUCTOR
    // ========================================================================

    /**
     * @notice Create pool contract
     * @dev Token addresses set via initialize()
     */
    constructor() ERC20("RWA Pool LP Token", "RWA-LP") {
        factory = msg.sender;
    }

    // ========================================================================
    // INITIALIZATION
    // ========================================================================

    /**
     * @inheritdoc IRWAPool
     */
    function initialize(address _token0, address _token1) external override {
        if (msg.sender != factory) revert NotFactory();
        if (token0 != address(0)) revert AlreadyInitialized();

        token0 = _token0;
        token1 = _token1;
    }

    // ========================================================================
    // VIEW FUNCTIONS
    // ========================================================================

    /**
     * @inheritdoc IRWAPool
     */
    function getReserves() public view override returns (
        uint256 _reserve0,
        uint256 _reserve1,
        uint32 _blockTimestampLast
    ) {
        _reserve0 = reserve0;
        _reserve1 = reserve1;
        _blockTimestampLast = blockTimestampLast;
    }

    // ========================================================================
    // LIQUIDITY FUNCTIONS
    // ========================================================================

    /**
     * @inheritdoc IRWAPool
     */
    function mint(address to) external override lock returns (uint256 liquidity) {
        (uint256 _reserve0, uint256 _reserve1,) = getReserves();
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        uint256 amount0 = balance0 - _reserve0;
        uint256 amount1 = balance1 - _reserve1;

        uint256 _totalSupply = totalSupply();

        if (_totalSupply == 0) {
            // First deposit - mint minimum liquidity to dead address
            liquidity = Math.sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY;
            _mint(DEAD_ADDRESS, MINIMUM_LIQUIDITY);
        } else {
            // Subsequent deposits - proportional to existing reserves
            liquidity = Math.min(
                (amount0 * _totalSupply) / _reserve0,
                (amount1 * _totalSupply) / _reserve1
            );
        }

        if (liquidity == 0) revert InsufficientLiquidityMinted();

        _mint(to, liquidity);

        _update(balance0, balance1, _reserve0, _reserve1);
        kLast = uint256(reserve0) * uint256(reserve1);

        emit Mint(msg.sender, amount0, amount1);
    }

    /**
     * @inheritdoc IRWAPool
     */
    function burn(address to) external override lock returns (
        uint256 amount0,
        uint256 amount1
    ) {
        if (to == address(0) || to == address(this)) revert InvalidRecipient();

        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        uint256 liquidity = balanceOf(address(this));

        uint256 _totalSupply = totalSupply();

        // Calculate proportional amounts
        amount0 = (liquidity * balance0) / _totalSupply;
        amount1 = (liquidity * balance1) / _totalSupply;

        if (amount0 == 0 || amount1 == 0) revert InsufficientLiquidityBurned();

        // Burn LP tokens
        _burn(address(this), liquidity);

        // Transfer underlying tokens
        IERC20(token0).safeTransfer(to, amount0);
        IERC20(token1).safeTransfer(to, amount1);

        // Update reserves
        balance0 = IERC20(token0).balanceOf(address(this));
        balance1 = IERC20(token1).balanceOf(address(this));

        _update(balance0, balance1, uint256(reserve0), uint256(reserve1));
        kLast = uint256(reserve0) * uint256(reserve1);

        emit Burn(msg.sender, amount0, amount1, to);
    }

    // ========================================================================
    // SWAP FUNCTIONS
    // ========================================================================

    /**
     * @inheritdoc IRWAPool
     */
    function swap(
        uint256 amount0Out,
        uint256 amount1Out,
        address to,
        bytes calldata data
    ) external override lock {
        if (amount0Out == 0 && amount1Out == 0) revert InsufficientOutputAmount();
        if (to == address(0) || to == token0 || to == token1) revert InvalidRecipient();

        (uint256 _reserve0, uint256 _reserve1,) = getReserves();

        if (amount0Out >= _reserve0 || amount1Out >= _reserve1) {
            revert InsufficientLiquidity(
                amount0Out > amount1Out ? amount0Out : amount1Out,
                amount0Out > amount1Out ? _reserve0 : _reserve1
            );
        }

        // Optimistically transfer output
        if (amount0Out > 0) IERC20(token0).safeTransfer(to, amount0Out);
        if (amount1Out > 0) IERC20(token1).safeTransfer(to, amount1Out);

        // Flash swap callback (if data provided)
        if (data.length > 0) {
            IRWAPoolCallee(to).rwaPoolCall(msg.sender, amount0Out, amount1Out, data);
        }

        // Get updated balances
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));

        // Calculate amounts in
        uint256 amount0In = balance0 > _reserve0 - amount0Out
            ? balance0 - (_reserve0 - amount0Out)
            : 0;
        uint256 amount1In = balance1 > _reserve1 - amount1Out
            ? balance1 - (_reserve1 - amount1Out)
            : 0;

        if (amount0In == 0 && amount1In == 0) revert InsufficientInputAmount();

        // Verify k invariant (with 0.3% fee already deducted by AMM)
        // Note: Fee is handled by RWAAMM, not the pool
        uint256 balance0Adjusted = balance0;
        uint256 balance1Adjusted = balance1;

        if (balance0Adjusted * balance1Adjusted < _reserve0 * _reserve1) {
            revert KValueDecreased();
        }

        _update(balance0, balance1, _reserve0, _reserve1);
    }

    // ========================================================================
    // SYNCHRONIZATION FUNCTIONS
    // ========================================================================

    /**
     * @inheritdoc IRWAPool
     */
    function sync() external override lock {
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        _update(balance0, balance1, uint256(reserve0), uint256(reserve1));
    }

    /**
     * @inheritdoc IRWAPool
     */
    function skim(address to) external override lock {
        if (to == address(0)) revert InvalidRecipient();

        address _token0 = token0;
        address _token1 = token1;

        uint256 excess0 = IERC20(_token0).balanceOf(address(this)) - reserve0;
        uint256 excess1 = IERC20(_token1).balanceOf(address(this)) - reserve1;

        if (excess0 > 0) IERC20(_token0).safeTransfer(to, excess0);
        if (excess1 > 0) IERC20(_token1).safeTransfer(to, excess1);
    }

    // ========================================================================
    // INTERNAL FUNCTIONS
    // ========================================================================

    /**
     * @notice Update reserves and cumulative prices
     * @param balance0 New balance of token0
     * @param balance1 New balance of token1
     * @param _reserve0 Previous reserve of token0
     * @param _reserve1 Previous reserve of token1
     */
    function _update(
        uint256 balance0,
        uint256 balance1,
        uint256 _reserve0,
        uint256 _reserve1
    ) private {
        // Check for overflow
        if (balance0 > type(uint112).max || balance1 > type(uint112).max) {
            revert Overflow();
        }

        // solhint-disable-next-line not-rely-on-time
        uint32 blockTimestamp = uint32(block.timestamp % 2**32);
        uint32 timeElapsed;

        unchecked {
            timeElapsed = blockTimestamp - blockTimestampLast;
        }

        // Update cumulative prices (for TWAP oracles)
        if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
            // Accumulate price * time
            unchecked {
                price0CumulativeLast += (_reserve1 * timeElapsed) / _reserve0;
                price1CumulativeLast += (_reserve0 * timeElapsed) / _reserve1;
            }
        }

        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        blockTimestampLast = blockTimestamp;

        emit Sync(balance0, balance1);
    }
}

/**
 * @title IRWAPoolCallee
 * @author OmniCoin Development Team
 * @notice Interface for flash swap callbacks
 */
interface IRWAPoolCallee {
    /**
     * @notice Called during flash swap
     * @param sender Original swap initiator
     * @param amount0 Token0 amount received
     * @param amount1 Token1 amount received
     * @param data Arbitrary callback data
     */
    function rwaPoolCall(
        address sender,
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) external;
}
