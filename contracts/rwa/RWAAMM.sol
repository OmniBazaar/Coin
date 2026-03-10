// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {ERC2771Context} from
    "@openzeppelin/contracts/metatx/ERC2771Context.sol";
import {IRWAAMM} from "./interfaces/IRWAAMM.sol";
import {IRWAComplianceOracle} from "./interfaces/IRWAComplianceOracle.sol";
import {RWAPool} from "./RWAPool.sol";

/**
 * @title RWAAMM
 * @author OmniCoin Development Team
 * @notice Immutable AMM for Real World Asset trading
 * @dev This contract is intentionally NON-UPGRADEABLE to maintain
 *      legal defensibility. Once deployed, ODDAO has no control
 *      over the trading logic.
 *
 * Key Features:
 * - Constant-product AMM formula (x * y = k)
 * - Support for ERC-20, ERC-3643, ERC-1400, ERC-4626 tokens
 * - Built-in protocol fee (0.30%, immutable)
 * - Compliance oracle integration
 * - Emergency pause ONLY by multi-sig (3-of-5 threshold)
 *
 * Fee Model:
 *   The protocol charges a flat 0.30% fee on every swap, deducted upfront
 *   from amountIn. The fee is split 70/20/10:
 *     - 70% (LP Fee): Transferred into the pool alongside the trade amount.
 *       This increases the pool's K-value over time, benefiting LPs
 *       proportionally to their share of the total LP token supply. LPs
 *       realize these accumulated fees when they burn LP tokens and withdraw
 *       their share of the reserves (which now include the fee donations).
 *     - 20% (Staking) + 10% (Protocol): Transferred to UnifiedFeeVault for
 *       batched distribution to the staking reward pool and protocol treasury.
 *
 *   The LP fee is a "donation" to the pool, not part of the constant-product
 *   AMM curve calculation. The swap output is computed using only
 *   amountInAfterFee (the 99.70% remainder after the full 0.30% deduction),
 *   while the pool receives amountInAfterFee + lpFee. This means:
 *     - The effective user-facing fee is always 0.30%
 *     - LP yield comes from BOTH curve spread AND explicit fee donations
 *     - getQuote() output matches actual swap output exactly
 *
 * Fee Vault Compliance:
 *   The FEE_VAULT (UnifiedFeeVault) address MUST be whitelisted in the
 *   compliance contracts of ALL registered RWA tokens (ERC-3643, ERC-1400).
 *   If the vault is not whitelisted, swaps involving those tokens as
 *   tokenIn will revert because the fee transfer to the vault will fail
 *   the token's internal compliance check. Deploy-time setup must include
 *   registering FEE_VAULT as an approved participant in each RWA token's
 *   identity registry or transfer whitelist.
 *
 * Fee-on-Transfer (FOT) Tokens:
 *   This contract does NOT support fee-on-transfer (deflationary) tokens.
 *   If tokenIn charges a transfer fee, the pool will receive less than
 *   amountToPool, and the K-invariant check may fail with KValueDecreased.
 *   All tokens used in RWA pools must deliver the exact amount specified in
 *   safeTransferFrom. This is acceptable for RWA security tokens, which do
 *   not typically charge transfer fees.
 *
 * Security Features:
 * - Reentrancy protection
 * - Deadline checks for all operations
 * - Slippage protection
 * - Multi-sig emergency controls
 */
contract RWAAMM is IRWAAMM, ReentrancyGuard, ERC2771Context {
    using SafeERC20 for IERC20;
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    // ========================================================================
    // CONSTANTS (IMMUTABLE - CANNOT BE CHANGED AFTER DEPLOYMENT)
    // ========================================================================

    /// @notice Protocol fee in basis points (30 = 0.30%)
    /// @dev This is immutable - critical for legal defensibility
    uint256 public constant PROTOCOL_FEE_BPS = 30;

    /// @notice Basis points denominator
    uint256 public constant BPS_DENOMINATOR = 10000;

    /// @notice Fee split: Liquidity Providers (70%)
    uint256 public constant FEE_LP_BPS = 7000;

    /// @notice Fee split: Staking Pool (20%)
    uint256 public constant FEE_STAKING_BPS = 2000;

    /// @notice Fee split: Liquidity Pool (10%)
    uint256 public constant FEE_LIQUIDITY_BPS = 1000;

    /// @notice Minimum liquidity locked on first deposit
    uint256 public constant MINIMUM_LIQUIDITY = 1000;

    /// @notice Emergency pause requires 3-of-5 multi-sig
    uint256 public constant PAUSE_THRESHOLD = 3;

    /// @notice Number of multi-sig signers
    uint256 public constant MULTISIG_COUNT = 5;

    // ========================================================================
    // IMMUTABLE STATE (SET AT DEPLOYMENT)
    // ========================================================================

    /// @notice Emergency multi-sig address 1
    address public immutable EMERGENCY_SIGNER_1;
    /// @notice Emergency multi-sig address 2
    address public immutable EMERGENCY_SIGNER_2;
    /// @notice Emergency multi-sig address 3
    address public immutable EMERGENCY_SIGNER_3;
    /// @notice Emergency multi-sig address 4
    address public immutable EMERGENCY_SIGNER_4;
    /// @notice Emergency multi-sig address 5
    address public immutable EMERGENCY_SIGNER_5;

    /// @notice Fee vault contract address (UnifiedFeeVault)
    address public immutable FEE_VAULT;

    /// @notice XOM token address (for fee collection)
    address public immutable XOM_TOKEN;

    /// @notice Compliance oracle contract
    IRWAComplianceOracle public immutable COMPLIANCE_ORACLE;

    /// @notice Deployer address (initial pool creator)
    // solhint-disable-next-line var-name-mixedcase
    address private immutable DEPLOYER;

    // ========================================================================
    // STATE VARIABLES
    // ========================================================================

    /// @notice Mapping of pool ID to pool contract address
    mapping(bytes32 => address) private _pools;

    /// @notice Mapping of pool ID to pause status
    mapping(bytes32 => bool) private _poolPaused;

    /// @notice Global pause flag
    bool private _globalPause;

    /// @notice Nonce for pause/unpause operations (replay protection)
    /// @dev Audit fix M-02: Separated from pool-creator nonce so that
    ///      concurrent multi-sig operations do not block each other.
    uint256 private _emergencyNonce;

    /// @notice Nonce for pool creator management (replay protection)
    /// @dev Audit fix M-02: Independent counter for setPoolCreator()
    ///      so emergency pause and pool-creator operations can be
    ///      prepared and submitted simultaneously.
    uint256 private _poolCreatorNonce;

    /// @notice Array of all pool IDs
    bytes32[] private _allPoolIds;

    /// @notice Authorized pool creators (prevents uncontrolled pool creation)
    mapping(address => bool) private _poolCreators;

    // ========================================================================
    // ERRORS
    // ========================================================================

    /// @notice Thrown when pool already exists
    error PoolAlreadyExists(bytes32 poolId);

    /// @notice Thrown when tokens are identical
    error IdenticalTokens();

    /// @notice Thrown when token address is zero
    error ZeroAddress();

    /// @notice Thrown when global pause is active
    error GloballyPaused();

    /// @notice Thrown when signature is invalid
    error InvalidSignature(address signer);

    /// @notice Thrown when signer is not authorized
    error UnauthorizedSigner(address signer);

    /// @notice Thrown when duplicate signature detected
    error DuplicateSignature(address signer);

    /// @notice Thrown when duplicate emergency signer provided at deployment
    error DuplicateSigner(address signer);

    /// @notice Thrown when nonce is invalid
    error InvalidNonce(uint256 expected, uint256 provided);

    /// @notice Thrown when caller lacks the pool creator role
    error NotPoolCreator();

    /// @notice Thrown when invalid signer address
    error InvalidSigner();

    /// @notice Thrown when neither token in a new pool is registered
    ///         with the compliance oracle (audit fix H-02)
    /// @param token0 First token address
    /// @param token1 Second token address
    error UnregisteredPoolTokens(address token0, address token1);

    // ========================================================================
    // CONSTRUCTOR (IMMUTABLE PARAMETERS SET HERE)
    // ========================================================================

    /**
     * @notice Deploy the immutable RWAAMM contract
     * @dev All immutable parameters set here and CANNOT be changed
     * @param _emergencyMultisig Array of 5 multi-sig addresses
     * @param _feeVault Fee vault contract address (UnifiedFeeVault)
     * @param _xomToken XOM token address
     * @param _complianceOracle Compliance oracle contract
     * @param trustedForwarder_ Trusted ERC-2771 forwarder address
     */
    // solhint-disable-next-line code-complexity
    constructor(
        address[5] memory _emergencyMultisig,
        address _feeVault,
        address _xomToken,
        address _complianceOracle,
        address trustedForwarder_
    ) ERC2771Context(trustedForwarder_) {
        // Validate all emergency signer addresses
        for (uint256 i = 0; i < MULTISIG_COUNT; ++i) {
            if (_emergencyMultisig[i] == address(0)) revert ZeroAddress();
        }

        // Check for duplicate signers (immutable, cannot fix after deploy)
        for (uint256 i = 0; i < MULTISIG_COUNT; ++i) {
            for (uint256 j = i + 1; j < MULTISIG_COUNT; ++j) {
                if (_emergencyMultisig[i] == _emergencyMultisig[j]) {
                    revert DuplicateSigner(_emergencyMultisig[i]);
                }
            }
        }

        // Set emergency signers individually (immutable)
        EMERGENCY_SIGNER_1 = _emergencyMultisig[0];
        EMERGENCY_SIGNER_2 = _emergencyMultisig[1];
        EMERGENCY_SIGNER_3 = _emergencyMultisig[2];
        EMERGENCY_SIGNER_4 = _emergencyMultisig[3];
        EMERGENCY_SIGNER_5 = _emergencyMultisig[4];

        if (_feeVault == address(0)) revert ZeroAddress();
        if (_xomToken == address(0)) revert ZeroAddress();
        if (_complianceOracle == address(0)) revert ZeroAddress();

        FEE_VAULT = _feeVault;
        XOM_TOKEN = _xomToken;
        COMPLIANCE_ORACLE = IRWAComplianceOracle(_complianceOracle);

        // Deployer is the initial pool creator
        DEPLOYER = msg.sender;
        _poolCreators[msg.sender] = true;
    }

    // ========================================================================
    // MODIFIERS
    // ========================================================================

    /**
     * @notice Ensure deadline has not passed
     * @param deadline Transaction deadline timestamp
     */
    // solhint-disable-next-line ordering
    modifier checkDeadline(uint256 deadline) {
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp > deadline) {
            // solhint-disable-next-line not-rely-on-time
            revert DeadlineExpired(deadline, block.timestamp);
        }
        _;
    }

    /**
     * @notice Ensure system is not paused
     */
    modifier whenNotPaused() {
        if (_globalPause) revert GloballyPaused();
        _;
    }

    /**
     * @notice Ensure specific pool is not paused
     * @param poolId Pool identifier
     */
    modifier whenPoolNotPaused(bytes32 poolId) {
        if (_poolPaused[poolId]) revert PoolPaused(poolId);
        _;
    }

    // ========================================================================
    // VIEW FUNCTIONS
    // ========================================================================

    /**
     * @inheritdoc IRWAAMM
     */
    function protocolFeeBps() external pure override returns (uint256) {
        return PROTOCOL_FEE_BPS;
    }

    /**
     * @inheritdoc IRWAAMM
     */
    function getPool(bytes32 poolId) external view override returns (PoolInfo memory info) {
        address poolAddr = _pools[poolId];
        if (poolAddr == address(0)) revert PoolNotFound(poolId);

        RWAPool pool = RWAPool(poolAddr);
        (uint256 reserve0, uint256 reserve1, ) = pool.getReserves();

        info = PoolInfo({
            token0: pool.token0(),
            token1: pool.token1(),
            reserve0: reserve0,
            reserve1: reserve1,
            totalLiquidity: IERC20(poolAddr).totalSupply(),
            lastUpdateTimestamp: block.timestamp, // solhint-disable-line not-rely-on-time
            status: _poolPaused[poolId] ? PoolStatus.PAUSED : PoolStatus.ACTIVE,
            complianceRequired: _isComplianceRequired(pool.token0(), pool.token1())
        });
    }

    /**
     * @inheritdoc IRWAAMM
     */
    function getPoolId(
        address token0,
        address token1
    ) public pure override returns (bytes32 poolId) {
        // Sort tokens for consistent pool ID
        (address tokenA, address tokenB) = token0 < token1
            ? (token0, token1)
            : (token1, token0);
        poolId = keccak256(abi.encodePacked(tokenA, tokenB));
    }

    /**
     * @inheritdoc IRWAAMM
     * @dev The output reflects the full 0.30% fee deduction. LP revenue
     *      includes both the AMM curve spread and a 70% fee donation
     *      that increases pool reserves over time.
     */
    function getQuote(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external view override returns (
        uint256 amountOut,
        uint256 protocolFee,
        uint256 priceImpact
    ) {
        if (amountIn == 0) revert ZeroAmount();

        bytes32 poolId = getPoolId(tokenIn, tokenOut);
        address poolAddr = _pools[poolId];
        if (poolAddr == address(0)) revert PoolNotFound(poolId);

        RWAPool pool = RWAPool(poolAddr);
        (uint256 reserve0, uint256 reserve1, ) = pool.getReserves();

        // Determine reserves based on token order
        (uint256 reserveIn, uint256 reserveOut) = pool.token0() == tokenIn
            ? (reserve0, reserve1)
            : (reserve1, reserve0);

        // Calculate protocol fee
        protocolFee = (amountIn * PROTOCOL_FEE_BPS) / BPS_DENOMINATOR;
        uint256 amountInAfterFee = amountIn - protocolFee;

        // Constant product formula: (x + dx) * (y - dy) = x * y
        // dy = (y * dx) / (x + dx)
        amountOut = (reserveOut * amountInAfterFee) / (reserveIn + amountInAfterFee);

        // Calculate price impact in basis points
        if (reserveIn > 0) {
            uint256 idealAmountOut = (reserveOut * amountInAfterFee) / reserveIn;
            if (idealAmountOut > 0) {
                priceImpact = ((idealAmountOut - amountOut) * BPS_DENOMINATOR) / idealAmountOut;
            }
        }
    }

    /**
     * @inheritdoc IRWAAMM
     */
    function poolExists(bytes32 poolId) external view override returns (bool exists) {
        exists = _pools[poolId] != address(0);
    }

    /**
     * @notice Get all pool IDs
     * @return Array of pool IDs
     */
    function getAllPoolIds() external view returns (bytes32[] memory) {
        return _allPoolIds;
    }

    /**
     * @notice Get pool address by ID
     * @param poolId Pool identifier
     * @return Pool contract address
     */
    function getPoolAddress(bytes32 poolId) external view returns (address) {
        return _pools[poolId];
    }

    /**
     * @inheritdoc IRWAAMM
     */
    function getPool(
        address token0,
        address token1
    ) external view override returns (address pool) {
        bytes32 poolId = getPoolId(token0, token1);
        pool = _pools[poolId];
    }

    /**
     * @notice Check if global pause is active
     * @return True if globally paused
     */
    function isGloballyPaused() external view returns (bool) {
        return _globalPause;
    }

    /**
     * @notice Get current emergency pause/unpause nonce
     * @dev Audit fix M-02: This nonce is used only for
     *      emergencyPause() and emergencyUnpause() operations.
     * @return Current nonce value
     */
    function emergencyNonce() external view returns (uint256) {
        return _emergencyNonce;
    }

    /**
     * @notice Get current pool creator management nonce
     * @dev Audit fix M-02: Independent nonce for setPoolCreator().
     * @return Current pool creator nonce value
     */
    function poolCreatorNonce() external view returns (uint256) {
        return _poolCreatorNonce;
    }

    // ========================================================================
    // POOL CREATION
    // ========================================================================

    /**
     * @notice Create a new liquidity pool
     * @param token0 First token address
     * @param token1 Second token address
     * @return poolId The pool identifier
     * @return poolAddress The pool contract address
     */
    function createPool(
        address token0,
        address token1
    ) external whenNotPaused returns (bytes32 poolId, address poolAddress) {
        if (!_poolCreators[_msgSender()]) revert NotPoolCreator();
        return _createPool(token0, token1);
    }

    // ========================================================================
    // SWAP FUNCTIONS
    // ========================================================================

    /* solhint-disable code-complexity */
    /**
     * @notice Execute token swap with fee splitting and end-user compliance
     * @dev Routes through compliance checks, calculates 70/20/10 fee split,
     *      and executes the constant-product swap on the pool.
     *
     *      Compliance (audit fix C-01/C-02): When a trusted contract such as
     *      RWARouter calls this function, `_msgSender()` resolves to the
     *      router address, not the human user. The `onBehalfOf` parameter
     *      allows the router to identify the actual end user so that
     *      compliance is checked against the real user, not the router.
     *      Pass `address(0)` to default to `_msgSender()`.
     * @param tokenIn Input token address
     * @param tokenOut Output token address
     * @param amountIn Input amount
     * @param amountOutMin Minimum output amount (slippage protection)
     * @param deadline Transaction deadline
     * @param onBehalfOf Actual end user for compliance checks.
     *        Pass `address(0)` to use `_msgSender()`.
     * @return result Swap result information
     */
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        uint256 deadline,
        address onBehalfOf
    ) external override
        nonReentrant
        whenNotPaused
        checkDeadline(deadline)
        returns (SwapResult memory result)
    {
        if (amountIn == 0) revert ZeroAmount();

        address caller = _msgSender();
        address complianceTarget = _resolveComplianceTarget(
            caller, onBehalfOf
        );

        bytes32 poolId = getPoolId(tokenIn, tokenOut);
        if (_poolPaused[poolId]) revert PoolPaused(poolId);

        address poolAddr = _pools[poolId];
        if (poolAddr == address(0)) revert PoolNotFound(poolId);

        // Check compliance against the actual end user, not the
        // calling contract (fixes audit finding C-01/C-02)
        if (_isComplianceRequired(tokenIn, tokenOut)) {
            _checkSwapCompliance(
                complianceTarget, tokenIn, tokenOut, amountIn
            );
        }

        RWAPool pool = RWAPool(poolAddr);
        (uint256 reserve0, uint256 reserve1, ) = pool.getReserves();

        // Determine reserves based on token order
        bool isToken0In = pool.token0() == tokenIn;
        (uint256 reserveIn, uint256 reserveOut) = isToken0In
            ? (reserve0, reserve1)
            : (reserve1, reserve0);

        // Calculate protocol fee (0.30% of amountIn)
        uint256 protocolFee = (amountIn * PROTOCOL_FEE_BPS)
            / BPS_DENOMINATOR;
        uint256 amountInAfterFee = amountIn - protocolFee;

        // Split protocol fee: 70% stays in pool (LP revenue),
        // 30% goes to UnifiedFeeVault (20% staking + 10% protocol)
        uint256 lpFee = (protocolFee * FEE_LP_BPS) / BPS_DENOMINATOR;
        uint256 vaultFee = protocolFee - lpFee;

        // Calculate output amount (LP fee portion stays in pool
        // to increase reserves and benefit liquidity providers)
        uint256 amountToPool = amountInAfterFee + lpFee;
        uint256 amountOut = (reserveOut * amountInAfterFee)
            / (reserveIn + amountInAfterFee);

        // Check slippage
        if (amountOut < amountOutMin) {
            revert SlippageExceeded(amountOutMin, amountOut);
        }

        // Transfer input tokens to pool (trade amount + LP fee)
        IERC20(tokenIn).safeTransferFrom(
            caller, poolAddr, amountToPool
        );

        // Transfer vault fee (20% staking + 10% protocol)
        // to UnifiedFeeVault for batched distribution
        if (vaultFee > 0) {
            IERC20(tokenIn).safeTransferFrom(
                caller, FEE_VAULT, vaultFee
            );
        }

        // Execute swap on pool
        (uint256 amount0Out, uint256 amount1Out) = isToken0In
            ? (uint256(0), amountOut)
            : (amountOut, uint256(0));

        pool.swap(amount0Out, amount1Out, caller, "");

        // Build result with price impact
        result = _buildSwapResult(
            tokenIn, tokenOut, amountIn, amountOut,
            protocolFee, amountInAfterFee, reserveIn, reserveOut
        );

        emit Swap(
            complianceTarget, tokenIn, tokenOut,
            amountIn, amountOut, protocolFee
        );
    }
    /* solhint-enable code-complexity */

    // ========================================================================
    // LIQUIDITY FUNCTIONS
    // ========================================================================

    /* solhint-disable code-complexity */
    /**
     * @notice Add liquidity to a token pair pool with end-user compliance
     * @dev Creates pool if it doesn't exist. Calculates optimal amounts
     *      based on current reserves. Enforces compliance checks against
     *      the actual end user via `onBehalfOf` (audit fix C-01/C-02).
     * @param token0 First token address
     * @param token1 Second token address
     * @param amount0Desired Desired amount of token0
     * @param amount1Desired Desired amount of token1
     * @param amount0Min Minimum amount of token0
     * @param amount1Min Minimum amount of token1
     * @param deadline Transaction deadline
     * @param onBehalfOf Actual end user for compliance checks.
     *        Pass `address(0)` to use `_msgSender()`.
     * @return amount0 Actual token0 deposited
     * @return amount1 Actual token1 deposited
     * @return liquidity LP tokens minted
     */
    function addLiquidity(
        address token0,
        address token1,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 deadline,
        address onBehalfOf
    ) external override
        nonReentrant
        whenNotPaused
        checkDeadline(deadline)
        returns (
            uint256 amount0,
            uint256 amount1,
            uint256 liquidity
        )
    {
        address caller = _msgSender();
        address complianceTarget = _resolveComplianceTarget(
            caller, onBehalfOf
        );

        bytes32 poolId = getPoolId(token0, token1);
        address poolAddr = _pools[poolId];

        // Create pool if it doesn't exist (requires pool creator role)
        if (poolAddr == address(0)) {
            if (!_poolCreators[caller]) revert NotPoolCreator();
            (, poolAddr) = _createPool(token0, token1);
        }

        if (_poolPaused[poolId]) revert PoolPaused(poolId);

        // Check compliance against the actual end user, not the
        // calling contract (fixes audit finding C-01/C-02)
        if (_isComplianceRequired(token0, token1)) {
            _checkLiquidityCompliance(
                complianceTarget, token0, token1
            );
        }

        RWAPool pool = RWAPool(poolAddr);
        (uint256 reserve0, uint256 reserve1, ) = pool.getReserves();

        // Determine token order -- swap user amounts to match pool's
        // canonical token0/token1 ordering. Do NOT swap reserves;
        // they are already in pool order from getReserves().
        bool isToken0First = pool.token0() == token0;
        if (!isToken0First) {
            (amount0Desired, amount1Desired) = (
                amount1Desired, amount0Desired
            );
            (amount0Min, amount1Min) = (amount1Min, amount0Min);
        }

        // Calculate optimal amounts for the current reserve ratio
        (amount0, amount1) = _calcOptimalAmounts(
            reserve0, reserve1,
            amount0Desired, amount1Desired,
            amount0Min, amount1Min
        );

        // Transfer tokens to pool
        address actualToken0 = pool.token0();
        address actualToken1 = pool.token1();

        IERC20(actualToken0).safeTransferFrom(
            caller, poolAddr, amount0
        );
        IERC20(actualToken1).safeTransferFrom(
            caller, poolAddr, amount1
        );

        // Mint LP tokens
        liquidity = pool.mint(caller);

        // Swap back amounts if needed for return values
        if (!isToken0First) {
            (amount0, amount1) = (amount1, amount0);
        }

        emit LiquidityAdded(
            complianceTarget, poolId, amount0, amount1, liquidity
        );
    }
    /* solhint-enable code-complexity */

    /**
     * @notice Remove liquidity with end-user compliance verification
     * @dev The `onBehalfOf` parameter identifies the actual end user for
     *      compliance checking when called via a router contract
     *      (audit fix C-01/C-02). Pass `address(0)` to use `_msgSender()`.
     *
     *      Audit fix M-03: Compliance checks are intentionally SKIPPED
     *      for removeLiquidity(). Users who deposited while compliant
     *      must always be able to withdraw their own funds, even if
     *      their KYC status subsequently expires or is revoked. Blocking
     *      withdrawals for deregistered users constitutes fund seizure
     *      and creates worse regulatory exposure than allowing the exit.
     *      The restriction should be on acquiring new positions (swap,
     *      addLiquidity), not on exiting existing ones.
     * @param token0 First token address
     * @param token1 Second token address
     * @param liquidity LP tokens to burn
     * @param amount0Min Minimum token0 to receive
     * @param amount1Min Minimum token1 to receive
     * @param deadline Transaction deadline
     * @param onBehalfOf Actual end user for compliance checks.
     *        Pass `address(0)` to use `_msgSender()`.
     * @return amount0 Token0 received
     * @return amount1 Token1 received
     */
    function removeLiquidity(
        address token0,
        address token1,
        uint256 liquidity,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 deadline,
        address onBehalfOf
    ) external override
        nonReentrant
        whenNotPaused
        checkDeadline(deadline)
        returns (
            uint256 amount0,
            uint256 amount1
        )
    {
        address caller = _msgSender();
        address complianceTarget = _resolveComplianceTarget(
            caller, onBehalfOf
        );

        bytes32 poolId = getPoolId(token0, token1);
        address poolAddr = _pools[poolId];
        if (poolAddr == address(0)) revert PoolNotFound(poolId);

        // Audit fix M-03: Compliance checks SKIPPED for withdrawals.
        // Users must always be able to exit positions regardless of
        // current compliance status. See NatSpec above for rationale.

        RWAPool pool = RWAPool(poolAddr);

        // Transfer LP tokens to pool
        IERC20(poolAddr).safeTransferFrom(
            caller, poolAddr, liquidity
        );

        // Burn LP tokens and get underlying
        (amount0, amount1) = pool.burn(caller);

        // Check minimums
        bool isToken0First = pool.token0() == token0;
        if (!isToken0First) {
            (amount0, amount1) = (amount1, amount0);
        }

        if (amount0 < amount0Min) {
            revert SlippageExceeded(amount0Min, amount0);
        }
        if (amount1 < amount1Min) {
            revert SlippageExceeded(amount1Min, amount1);
        }

        emit LiquidityRemoved(
            complianceTarget, poolId, amount0, amount1, liquidity
        );
    }

    // ========================================================================
    // POOL CREATOR MANAGEMENT
    // ========================================================================

    /**
     * @notice Emitted when a pool creator is added or removed
     * @param creator Creator address
     * @param authorized True if added, false if removed
     */
    event PoolCreatorUpdated(
        address indexed creator,
        bool indexed authorized
    );

    /**
     * @notice Add or remove an authorized pool creator
     * @dev Only callable via multi-sig (3-of-5) for security.
     *      Pool creation must be controlled to prevent creation of
     *      pools for unregistered wrapper tokens that bypass compliance.
     * @param creator Address to authorize or deauthorize
     * @param authorized True to add, false to remove
     * @param signatures Multi-sig signatures
     */
    function setPoolCreator(
        address creator,
        bool authorized,
        bytes[] calldata signatures
    ) external {
        if (creator == address(0)) revert ZeroAddress();

        // Audit fix M-02: Use _poolCreatorNonce instead of the
        // shared _emergencyNonce so that pause/unpause and pool
        // creator operations can be prepared simultaneously.
        bytes32 messageHash = keccak256(abi.encodePacked(
            "SET_POOL_CREATOR",
            creator,
            authorized,
            _poolCreatorNonce,
            block.chainid,
            address(this)
        ));

        _verifyMultiSig(messageHash, signatures);
        ++_poolCreatorNonce;

        _poolCreators[creator] = authorized;

        emit PoolCreatorUpdated(creator, authorized);
    }

    /**
     * @notice Check if an address is an authorized pool creator
     * @param creator Address to check
     * @return True if authorized
     */
    function isPoolCreator(
        address creator
    ) external view returns (bool) {
        return _poolCreators[creator];
    }

    // ========================================================================
    // EMERGENCY FUNCTIONS (MULTI-SIG REQUIRED)
    // ========================================================================

    /**
     * @inheritdoc IRWAAMM
     */
    function emergencyPause(
        bytes32 poolId,
        string calldata reason,
        bytes[] calldata signatures
    ) external override {
        // Verify multi-sig
        bytes32 messageHash = keccak256(abi.encodePacked(
            "PAUSE",
            poolId,
            reason,
            _emergencyNonce,
            block.chainid,
            address(this)
        ));

        _verifyMultiSig(messageHash, signatures);

        // Increment nonce for replay protection
        ++_emergencyNonce;

        // Apply pause
        if (poolId == bytes32(0)) {
            _globalPause = true;
        } else {
            _poolPaused[poolId] = true;
        }

        emit EmergencyPaused(poolId, _msgSender(), reason);
    }

    /**
     * @inheritdoc IRWAAMM
     */
    function emergencyUnpause(
        bytes32 poolId,
        bytes[] calldata signatures
    ) external override {
        // Verify multi-sig
        bytes32 messageHash = keccak256(abi.encodePacked(
            "UNPAUSE",
            poolId,
            _emergencyNonce,
            block.chainid,
            address(this)
        ));

        _verifyMultiSig(messageHash, signatures);

        // Increment nonce for replay protection
        ++_emergencyNonce;

        // Remove pause
        if (poolId == bytes32(0)) {
            _globalPause = false;
        } else {
            _poolPaused[poolId] = false;
        }

        emit EmergencyUnpaused(poolId, _msgSender());
    }

    // ========================================================================
    // INTERNAL FUNCTIONS
    // ========================================================================

    /**
     * @notice Verify multi-sig signatures
     * @param messageHash Hash of the message to verify
     * @param signatures Array of signatures
     */
    function _verifyMultiSig(
        bytes32 messageHash,
        bytes[] calldata signatures
    ) internal view {
        if (signatures.length < PAUSE_THRESHOLD) {
            revert InsufficientSignatures(PAUSE_THRESHOLD, signatures.length);
        }

        bytes32 ethSignedHash = messageHash.toEthSignedMessageHash();
        address[] memory signers = new address[](signatures.length);

        for (uint256 i = 0; i < signatures.length; ++i) {
            address signer = ethSignedHash.recover(signatures[i]);

            // Check if signer is authorized (check each signer individually)
            bool isAuthorized = _isEmergencySigner(signer);
            if (!isAuthorized) revert UnauthorizedSigner(signer);

            // Check for duplicate signatures
            for (uint256 k = 0; k < i; ++k) {
                if (signers[k] == signer) revert DuplicateSignature(signer);
            }

            signers[i] = signer;
        }
    }

    /**
     * @notice Check if address is an emergency signer
     * @param signer Address to check
     * @return True if signer is authorized
     */
    function _isEmergencySigner(address signer) internal view returns (bool) {
        return signer == EMERGENCY_SIGNER_1 ||
               signer == EMERGENCY_SIGNER_2 ||
               signer == EMERGENCY_SIGNER_3 ||
               signer == EMERGENCY_SIGNER_4 ||
               signer == EMERGENCY_SIGNER_5;
    }

    /**
     * @notice Internal pool creation logic
     * @dev Deploys a new RWAPool and registers it. Shared by createPool()
     *      and addLiquidity() (auto-creation path).
     *
     *      Audit M-01: Fee-on-transfer (FOT) tokens are NOT supported.
     *      If a pool is created with an FOT token, all subsequent swaps
     *      will revert with KValueDecreased because the pool receives
     *      less than amountToPool. The initial liquidity may succeed,
     *      trapping LP funds. Pool creators MUST verify that all tokens
     *      deliver exact transfer amounts. RWA security tokens (ERC-3643,
     *      ERC-1400) do not charge transfer fees, so this limitation is
     *      acceptable for the intended use case.
     * @param token0 First token address
     * @param token1 Second token address
     * @return poolId The pool identifier
     * @return poolAddress The deployed pool contract address
     */
    function _createPool(
        address token0,
        address token1
    ) internal returns (bytes32 poolId, address poolAddress) {
        if (token0 == token1) revert IdenticalTokens();
        if (token0 == address(0) || token1 == address(0)) {
            revert ZeroAddress();
        }

        // Audit fix H-02: Verify at least one token is registered
        // with the compliance oracle before creating a pool. This
        // prevents pool creators from creating pools for unregistered
        // or malicious tokens that could bypass compliance checks.
        // At least one token should be a known, registered asset
        // (e.g., XOM or a registered RWA token).
        bool token0Registered = COMPLIANCE_ORACLE.isTokenRegistered(
            token0
        );
        bool token1Registered = COMPLIANCE_ORACLE.isTokenRegistered(
            token1
        );
        if (!token0Registered && !token1Registered) {
            revert UnregisteredPoolTokens(token0, token1);
        }

        // Sort tokens for consistent ordering
        (address tokenA, address tokenB) = token0 < token1
            ? (token0, token1)
            : (token1, token0);

        poolId = getPoolId(tokenA, tokenB);
        if (_pools[poolId] != address(0)) {
            revert PoolAlreadyExists(poolId);
        }

        // Deploy new pool contract
        RWAPool pool = new RWAPool();
        pool.initialize(tokenA, tokenB);

        _pools[poolId] = address(pool);
        _allPoolIds.push(poolId);

        emit PoolCreated(poolId, tokenA, tokenB, _msgSender());

        poolAddress = address(pool);
    }

    /**
     * @notice Resolve the compliance target address
     * @dev Returns `onBehalfOf` if it is non-zero, otherwise falls back
     *      to `caller` (the `_msgSender()`). This allows direct callers
     *      to omit or zero-out the parameter while router contracts pass
     *      the actual end user for compliance verification.
     * @param caller The immediate caller (`_msgSender()`)
     * @param onBehalfOf The end user address supplied by the caller.
     *        `address(0)` means "use caller".
     * @return complianceTarget The address to verify compliance against
     */
    function _resolveComplianceTarget(
        address caller,
        address onBehalfOf
    ) internal pure returns (address complianceTarget) {
        complianceTarget = onBehalfOf == address(0)
            ? caller
            : onBehalfOf;
    }

    /**
     * @notice Build a SwapResult struct with price impact calculation
     * @dev Extracted from swap() to reduce function body length.
     * @param tokenIn Input token address (for route)
     * @param tokenOut Output token address (for route)
     * @param amountIn Total input amount
     * @param amountOut Calculated output amount
     * @param protocolFee Fee charged
     * @param amountInAfterFee Input minus fee (for price impact calc)
     * @param reserveIn Input token reserve before swap
     * @param reserveOut Output token reserve before swap
     * @return result Populated SwapResult struct
     */
    function _buildSwapResult(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 protocolFee,
        uint256 amountInAfterFee,
        uint256 reserveIn,
        uint256 reserveOut
    ) internal pure returns (SwapResult memory result) {
        uint256 priceImpact = 0;
        if (reserveIn > 0) {
            uint256 idealOut = (reserveOut * amountInAfterFee)
                / reserveIn;
            if (idealOut > 0) {
                priceImpact = (
                    (idealOut - amountOut) * BPS_DENOMINATOR
                ) / idealOut;
            }
        }

        address[] memory route = new address[](2);
        route[0] = tokenIn;
        route[1] = tokenOut;

        result = SwapResult({
            amountIn: amountIn,
            amountOut: amountOut,
            protocolFee: protocolFee,
            priceImpact: priceImpact,
            route: route
        });
    }

    /**
     * @notice Calculate optimal deposit amounts based on current reserves
     * @dev Extracted from addLiquidity() to reduce function body length.
     *      Returns desired amounts for the first deposit (empty pool).
     * @param reserve0 Current reserve of token0
     * @param reserve1 Current reserve of token1
     * @param amount0Desired Desired deposit of token0
     * @param amount1Desired Desired deposit of token1
     * @param amount0Min Minimum acceptable token0
     * @param amount1Min Minimum acceptable token1
     * @return amount0 Optimal token0 deposit
     * @return amount1 Optimal token1 deposit
     */
    function _calcOptimalAmounts(
        uint256 reserve0,
        uint256 reserve1,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min
    ) internal pure returns (uint256 amount0, uint256 amount1) {
        if (reserve0 == 0 && reserve1 == 0) {
            return (amount0Desired, amount1Desired);
        }

        uint256 amount1Optimal = (amount0Desired * reserve1)
            / reserve0;
        // solhint-disable-next-line gas-strict-inequalities
        if (amount1Optimal <= amount1Desired) {
            if (amount1Optimal < amount1Min) {
                revert SlippageExceeded(amount1Min, amount1Optimal);
            }
            return (amount0Desired, amount1Optimal);
        }

        uint256 amount0Optimal = (amount1Desired * reserve0)
            / reserve1;
        if (amount0Optimal < amount0Min) {
            revert SlippageExceeded(amount0Min, amount0Optimal);
        }
        return (amount0Optimal, amount1Desired);
    }

    /**
     * @notice Check if compliance is required for token pair
     * @param tokenA First token address
     * @param tokenB Second token address
     * @return True if compliance is required
     */
    function _isComplianceRequired(
        address tokenA,
        address tokenB
    ) internal view returns (bool) {
        // Check if either token is a registered RWA token
        return COMPLIANCE_ORACLE.isTokenRegistered(tokenA) ||
               COMPLIANCE_ORACLE.isTokenRegistered(tokenB);
    }

    /**
     * @notice Check swap compliance
     * @param user User address
     * @param tokenIn Input token
     * @param tokenOut Output token
     * @param amountIn Input amount
     */
    function _checkSwapCompliance(
        address user,
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) internal view {
        (bool inputCompliant, bool outputCompliant, string memory reason) =
            COMPLIANCE_ORACLE.checkSwapCompliance(
                user, tokenIn, tokenOut, amountIn
            );

        if (!inputCompliant) {
            revert ComplianceCheckFailed(user, tokenIn, reason);
        }
        if (!outputCompliant) {
            revert ComplianceCheckFailed(user, tokenOut, reason);
        }
    }

    /**
     * @notice Check liquidity compliance for both tokens
     * @dev Verifies that the user passes compliance for each registered
     *      token individually. LP positions grant exposure to underlying
     *      assets, so compliance must be checked before add/remove.
     * @param user User address to check
     * @param tokenA First token in the pair
     * @param tokenB Second token in the pair
     */
    function _checkLiquidityCompliance(
        address user,
        address tokenA,
        address tokenB
    ) internal view {
        if (COMPLIANCE_ORACLE.isTokenRegistered(tokenA)) {
            IRWAComplianceOracle.ComplianceResult memory resultA =
                COMPLIANCE_ORACLE.checkCompliance(user, tokenA);
            if (
                resultA.status
                    != IRWAComplianceOracle.ComplianceStatus.COMPLIANT
            ) {
                revert ComplianceCheckFailed(
                    user, tokenA, resultA.reason
                );
            }
        }
        if (COMPLIANCE_ORACLE.isTokenRegistered(tokenB)) {
            IRWAComplianceOracle.ComplianceResult memory resultB =
                COMPLIANCE_ORACLE.checkCompliance(user, tokenB);
            if (
                resultB.status
                    != IRWAComplianceOracle.ComplianceStatus.COMPLIANT
            ) {
                revert ComplianceCheckFailed(
                    user, tokenB, resultB.reason
                );
            }
        }
    }
}
