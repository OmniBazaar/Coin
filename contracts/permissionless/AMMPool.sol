// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IAMMPool} from "./interfaces/IAMMPool.sol";

/**
 * @title AMMPool
 * @author OmniCoin Development Team
 * @notice Liquidity pool for a single token pair in the permissionless
 *         AMM (e.g., XOM/USDC on Ethereum, Arbitrum, Base, Polygon)
 * @dev Implements constant-product AMM with LP token minting.
 *      Permissionless variant of RWAPool — identical Uniswap V2 math,
 *      audit fixes, and LP accounting, with the surrounding factory
 *      (AMMPermissionless) imposing no compliance gating.
 *
 * Key Features:
 * - Constant-product formula: x * y = k, where x and y are the
 *   reserves of token0 and token1 respectively. Every swap preserves
 *   or increases k, ensuring that the product of reserves never
 *   decreases. Output amount dy for input dx is calculated as:
 *   dy = (y * dx) / (x + dx).
 * - LP tokens as ERC20 for composability. LP token value accrues
 *   from both the constant-product curve spread and explicit fee
 *   donations from AMMPermissionless (70% of the 0.30% protocol fee).
 * - Cumulative price oracles (TWAP support via UQ112x112 fixed-point)
 * - Reentrancy protection via lock modifier
 * - Flash swaps disabled (audit fix H-02, inherited from RWAPool)
 * - Rate-limited sync() to resist oracle manipulation (audit fix H-01)
 * - Factory-only access control on critical functions
 *
 * Relationship to AMMPermissionless:
 *   AMMPool is deployed and initialized by AMMPermissionless (the
 *   factory). All state-changing operations (mint, burn, swap, skim)
 *   are restricted to the factory via the onlyFactory modifier.
 *   AMMPermissionless handles fee collection, pause enforcement, and
 *   multi-sig emergency controls before delegating to the pool. Users
 *   typically interact with AMMPool indirectly via RouterPermissionless
 *   or AMMPermissionless directly.
 *
 * Security Features:
 * - Reentrancy lock
 * - Factory-only access for mint, burn, swap, skim
 * - Minimum liquidity lock (1000 wei)
 * - Minimum initial deposit (10000 sqrt-units, audit M-01)
 * - K-value invariant check with uint112 overflow guard
 * - Balance synchronization
 */
contract AMMPool is ERC20, IAMMPool {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // ========================================================================
    // CONSTANTS
    // ========================================================================

    /// @inheritdoc IAMMPool
    uint256 public constant MINIMUM_LIQUIDITY = 1000;

    /// @notice Minimum initial deposit to prevent share inflation attacks
    /// @dev First depositor must provide at least this much liquidity
    ///      (sqrt(amount0 * amount1) >= MINIMUM_INITIAL_DEPOSIT).
    ///
    ///      Audit M-01: For low-decimal tokens, a higher threshold is
    ///      used compared to Uniswap V2's 1000. With
    ///      MINIMUM_INITIAL_DEPOSIT = 10_000, the first depositor must
    ///      provide sqrt(amount0 * amount1) >= 10_000.
    uint256 public constant MINIMUM_INITIAL_DEPOSIT = 10_000;

    /// @notice Address to lock minimum liquidity (dead address)
    address private constant DEAD_ADDRESS =
        0x000000000000000000000000000000000000dEaD;

    // ========================================================================
    // STATE VARIABLES
    // ========================================================================

    /// @notice Factory/AMM contract that created this pool
    address public factory;

    /// @inheritdoc IAMMPool
    address public token0;

    /// @inheritdoc IAMMPool
    address public token1;

    /// @notice Reserve of token0
    uint112 private reserve0;

    /// @notice Reserve of token1
    uint112 private reserve1;

    /// @notice Timestamp of last reserve update
    uint32 private blockTimestampLast;

    /// @inheritdoc IAMMPool
    uint256 public price0CumulativeLast;

    /// @inheritdoc IAMMPool
    uint256 public price1CumulativeLast;

    /// @inheritdoc IAMMPool
    /// @dev Audit M-03: kLast stores the product of reserves after each
    ///      mint/burn operation. Exposed for external consumers but NOT
    ///      used for security-critical validation. The K-invariant check
    ///      in swap() uses live balances, not kLast.
    uint256 public kLast;

    /// @notice Reentrancy lock state (1 = unlocked, 0 = locked)
    uint256 private unlocked = 1;

    /// @notice Block number of the last sync() call (audit fix H-01)
    uint256 private _lastSyncBlock;

    // ========================================================================
    // ERRORS
    // ========================================================================

    /// @notice Thrown when caller is not the factory contract
    error NotFactory();

    /// @notice Thrown when pool is already initialized
    error AlreadyInitialized();

    /// @notice Thrown when recipient is invalid (zero or self)
    error InvalidRecipient();

    /// @notice Thrown when initial deposit is too small
    /// @param provided Amount of liquidity provided (sqrt)
    /// @param required Minimum required (MINIMUM_INITIAL_DEPOSIT)
    error InitialDepositTooSmall(uint256 provided, uint256 required);

    /// @notice Thrown when flash swaps are attempted (audit fix H-02)
    error FlashSwapsDisabled();

    /// @notice Thrown when sync() is called more than once per block
    error SyncRateLimited();

    /// @notice Thrown when a token address is the zero address
    error InvalidToken();

    /// @notice Thrown when token0 and token1 are the same address
    error DuplicateTokens();

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

    /**
     * @notice Restricts access to the factory contract only
     */
    modifier onlyFactory() {
        if (msg.sender != factory) revert NotFactory();
        _;
    }

    // ========================================================================
    // CONSTRUCTOR
    // ========================================================================

    /**
     * @notice Create pool contract
     * @dev Token addresses are set via initialize() after deployment.
     */
    constructor() ERC20("AMM Pool LP Token", "AMM-LP") {
        factory = msg.sender;
    }

    // ========================================================================
    // EXTERNAL FUNCTIONS
    // ========================================================================

    /**
     * @inheritdoc IAMMPool
     */
    function initialize(
        address _token0,
        address _token1
    ) external override onlyFactory {
        if (token0 != address(0)) revert AlreadyInitialized();
        if (_token0 == address(0)) revert InvalidToken();
        if (_token1 == address(0)) revert InvalidToken();
        if (_token0 == _token1) revert DuplicateTokens();

        token0 = _token0;
        token1 = _token1;
    }

    /**
     * @inheritdoc IAMMPool
     */
    function mint(
        address to
    ) external override lock onlyFactory returns (uint256 liquidity) {
        uint256 _reserve0 = reserve0;
        uint256 _reserve1 = reserve1;
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        uint256 amount0 = balance0 - _reserve0;
        uint256 amount1 = balance1 - _reserve1;

        uint256 _totalSupply = totalSupply();

        if (_totalSupply == 0) {
            // First deposit - enforce minimum to prevent inflation attack
            uint256 sqrtProduct = Math.sqrt(amount0 * amount1);
            if (sqrtProduct < MINIMUM_INITIAL_DEPOSIT) {
                revert InitialDepositTooSmall(
                    sqrtProduct, MINIMUM_INITIAL_DEPOSIT
                );
            }
            liquidity = sqrtProduct - MINIMUM_LIQUIDITY;
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
     * @inheritdoc IAMMPool
     */
    function burn(
        address to
    ) external override lock onlyFactory returns (
        uint256 amount0,
        uint256 amount1
    ) {
        if (to == address(0) || to == address(this)) {
            revert InvalidRecipient();
        }

        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        uint256 liquidity = balanceOf(address(this));

        uint256 _totalSupply = totalSupply();

        // Calculate proportional amounts
        amount0 = (liquidity * balance0) / _totalSupply;
        amount1 = (liquidity * balance1) / _totalSupply;

        if (amount0 == 0 || amount1 == 0) {
            revert InsufficientLiquidityBurned();
        }

        // Burn LP tokens
        _burn(address(this), liquidity);

        // CEI pattern: Update reserves BEFORE transfers to prevent
        // read-only reentrancy.
        uint256 newBalance0 = balance0 - amount0;
        uint256 newBalance1 = balance1 - amount1;
        _update(
            newBalance0,
            newBalance1,
            uint256(reserve0),
            uint256(reserve1)
        );
        kLast = newBalance0 * newBalance1;

        // Transfer underlying tokens (after state updates)
        IERC20(token0).safeTransfer(to, amount0);
        IERC20(token1).safeTransfer(to, amount1);

        emit Burn(msg.sender, amount0, amount1, to);
    }

    /**
     * @inheritdoc IAMMPool
     * @dev Flash swaps are disabled (audit fix H-02 + M-01): passing
     *      non-empty data will revert with FlashSwapsDisabled() BEFORE
     *      any token transfers occur.
     */
    function swap(
        uint256 amount0Out,
        uint256 amount1Out,
        address to,
        bytes calldata data
    ) external override lock onlyFactory {
        _validateSwapParams(amount0Out, amount1Out, to);

        uint256 _reserve0 = reserve0;
        uint256 _reserve1 = reserve1;

        _validateSwapReserves(
            amount0Out, amount1Out, _reserve0, _reserve1
        );

        // Audit fix H-02 + M-01: Flash swaps are disabled.
        if (data.length > 0) {
            revert FlashSwapsDisabled();
        }

        // Optimistically transfer output
        if (amount0Out > 0) {
            IERC20(token0).safeTransfer(to, amount0Out);
        }
        if (amount1Out > 0) {
            IERC20(token1).safeTransfer(to, amount1Out);
        }

        // Get updated balances and verify invariants
        _verifyAndUpdateSwap(
            _reserve0, _reserve1, amount0Out, amount1Out, to
        );
    }

    /**
     * @inheritdoc IAMMPool
     * @dev Audit fix H-01: Rate-limited to once per block to resist
     *      donation-based TWAP oracle manipulation.
     */
    function sync() external override lock {
        if (_lastSyncBlock == block.number) {
            revert SyncRateLimited();
        }
        _lastSyncBlock = block.number;

        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        _update(
            balance0,
            balance1,
            uint256(reserve0),
            uint256(reserve1)
        );
    }

    /**
     * @inheritdoc IAMMPool
     */
    function skim(
        address to
    ) external override lock onlyFactory {
        if (to == address(0)) revert InvalidRecipient();

        address _token0 = token0;
        address _token1 = token1;

        uint256 excess0 = IERC20(_token0).balanceOf(address(this))
            - reserve0;
        uint256 excess1 = IERC20(_token1).balanceOf(address(this))
            - reserve1;

        if (excess0 > 0) {
            IERC20(_token0).safeTransfer(to, excess0);
        }
        if (excess1 > 0) {
            IERC20(_token1).safeTransfer(to, excess1);
        }
    }

    // ========================================================================
    // PUBLIC VIEW FUNCTIONS
    // ========================================================================

    /**
     * @inheritdoc IAMMPool
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
    // PRIVATE FUNCTIONS
    // ========================================================================

    /**
     * @notice Verify k-invariant and update state after a swap
     * @param _reserve0 Previous reserve of token0
     * @param _reserve1 Previous reserve of token1
     * @param amount0Out Token0 output amount
     * @param amount1Out Token1 output amount
     * @param _swapRecipient Swap recipient address for event emission
     */
    function _verifyAndUpdateSwap(
        uint256 _reserve0,
        uint256 _reserve1,
        uint256 amount0Out,
        uint256 amount1Out,
        address _swapRecipient
    ) private {
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));

        // Calculate amounts in
        uint256 amount0In = balance0 > _reserve0 - amount0Out
            ? balance0 - (_reserve0 - amount0Out)
            : 0;
        uint256 amount1In = balance1 > _reserve1 - amount1Out
            ? balance1 - (_reserve1 - amount1Out)
            : 0;

        if (amount0In == 0 && amount1In == 0) {
            revert InsufficientInputAmount();
        }

        // Guard against uint256 overflow in the K-invariant check.
        if (
            balance0 > type(uint112).max
            || balance1 > type(uint112).max
        ) {
            revert Overflow();
        }

        // Verify k invariant (constant-product: x * y = k)
        if (balance0 * balance1 < _reserve0 * _reserve1) {
            revert KValueDecreased();
        }

        _update(balance0, balance1, _reserve0, _reserve1);

        emit Swap(
            msg.sender,
            amount0In,
            amount1In,
            amount0Out,
            amount1Out,
            _swapRecipient
        );
    }

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
        if (
            balance0 > type(uint112).max
            || balance1 > type(uint112).max
        ) {
            revert Overflow();
        }

        // solhint-disable-next-line not-rely-on-time
        uint32 blockTimestamp = uint32(block.timestamp % 2 ** 32);
        uint32 timeElapsed;

        unchecked {
            timeElapsed = blockTimestamp - blockTimestampLast;
        }

        // Update cumulative prices (UQ112x112 fixed-point for TWAP)
        if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
            unchecked {
                price0CumulativeLast +=
                    ((_reserve1 << 112) / _reserve0) * timeElapsed;
                price1CumulativeLast +=
                    ((_reserve0 << 112) / _reserve1) * timeElapsed;
            }
        }

        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        blockTimestampLast = blockTimestamp;

        emit Sync(balance0, balance1);
    }

    /**
     * @notice Validate basic swap parameters
     * @param amount0Out Token0 output amount
     * @param amount1Out Token1 output amount
     * @param to Recipient address
     */
    function _validateSwapParams(
        uint256 amount0Out,
        uint256 amount1Out,
        address to
    ) private view {
        if (amount0Out == 0 && amount1Out == 0) {
            revert InsufficientOutputAmount();
        }
        if (to == address(0) || to == token0 || to == token1) {
            revert InvalidRecipient();
        }
    }

    /**
     * @notice Validate that output amounts do not exceed reserves
     * @param amount0Out Token0 output amount
     * @param amount1Out Token1 output amount
     * @param _reserve0 Current reserve of token0
     * @param _reserve1 Current reserve of token1
     */
    function _validateSwapReserves(
        uint256 amount0Out,
        uint256 amount1Out,
        uint256 _reserve0,
        uint256 _reserve1
    ) private pure {
        bool valid0 = amount0Out < _reserve0;
        bool valid1 = amount1Out < _reserve1;

        if (!valid0 || !valid1) {
            uint256 requested = amount0Out > amount1Out
                ? amount0Out : amount1Out;
            uint256 available = amount0Out > amount1Out
                ? _reserve0 : _reserve1;
            revert InsufficientLiquidity(requested, available);
        }
    }
}
