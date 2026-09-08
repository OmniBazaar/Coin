// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {ERC2771Context} from
    "@openzeppelin/contracts/metatx/ERC2771Context.sol";
import {IEmergencyGuardian} from
    "../interfaces/IEmergencyGuardian.sol";
import {IAMMPermissionless} from "./interfaces/IAMMPermissionless.sol";
import {AMMPool} from "./AMMPool.sol";

/**
 * @title AMMPermissionless
 * @author OmniCoin Development Team
 * @notice Immutable AMM for permissionless token trading on external chains
 * @dev Permissionless variant of RWAAMM deployed on Ethereum, Arbitrum,
 *      Base, and Polygon. Identical swap math, fee splits, and multi-sig
 *      emergency controls as RWAAMM — only the compliance oracle and
 *      related gating are removed because external chains do not enforce
 *      OmniBazaar KYC tier checks. Wallet-level OFAC screening still
 *      applies upstream of this contract.
 *
 *      This contract is intentionally NON-UPGRADEABLE to maintain
 *      legal defensibility. Once deployed, no entity has control
 *      over the trading logic.
 *
 * Key Features:
 * - Constant-product AMM formula (x * y = k)
 * - Support for ERC-20 tokens
 * - Built-in protocol fee (0.30%, immutable)
 * - No compliance gating (wallet-level OFAC screening applies upstream)
 * - Emergency pause ONLY by multi-sig (3-of-N threshold via EmergencyGuardian)
 *
 * Fee Model:
 *   The protocol charges a flat 0.30% fee on every swap, deducted upfront
 *   from amountIn. The fee is split 70/20/10:
 *     - 70% (LP Fee): Transferred into the pool alongside the trade amount.
 *       This increases the pool's K-value over time, benefiting LPs
 *       proportionally to their share of the total LP token supply.
 *     - 20% (Staking) + 10% (Protocol): Transferred to UnifiedFeeVault for
 *       batched distribution to the staking reward pool and protocol treasury.
 *
 * Fee-on-Transfer (FOT) Tokens:
 *   This contract does NOT support fee-on-transfer (deflationary) tokens.
 *
 * Security Features:
 * - Reentrancy protection
 * - Deadline checks for all operations
 * - Slippage protection
 * - Multi-sig emergency controls
 */
contract AMMPermissionless is IAMMPermissionless, ReentrancyGuard, ERC2771Context {
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

    /// @notice Fee split: Protocol Treasury (10%)
    uint256 public constant FEE_PROTOCOL_BPS = 1000;

    /// @notice Minimum liquidity locked on first deposit
    uint256 public constant MINIMUM_LIQUIDITY = 1000;

    /// @notice Emergency pause requires 3-of-5 multi-sig
    uint256 public constant PAUSE_THRESHOLD = 3;

    // ========================================================================
    // IMMUTABLE STATE (SET AT DEPLOYMENT)
    // ========================================================================

    /// @notice Fee vault contract address (UnifiedFeeVault on this chain)
    address public immutable FEE_VAULT;

    /// @notice XOM token address (for fee collection)
    address public immutable XOM_TOKEN;

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
    /// @dev Audit fix M-02: Independent counter for setPoolCreator().
    uint256 private _poolCreatorNonce;

    /// @notice Array of all pool IDs
    bytes32[] private _allPoolIds;

    /// @notice Authorized pool creators (prevents uncontrolled pool creation)
    mapping(address => bool) private _poolCreators;

    /// @notice Emergency guardian contract for multi-sig verification
    /// @dev Mutable (audit H-02): delegating signer checks to a swappable
    ///      guardian lets the guardian be rotated or upgraded without
    ///      redeploying this AMM. Changed only via the two-step
    ///      {proposeEmergencyGuardian} / {applyEmergencyGuardian} flow
    ///      gated by {guardianAdmin}.
    IEmergencyGuardian private _emergencyGuardian;

    /// @notice Pending guardian set by {proposeEmergencyGuardian}
    /// @dev Finalized by {applyEmergencyGuardian}.
    IEmergencyGuardian private _pendingGuardian;

    /// @notice Address authorized to change the emergency guardian
    /// @dev Initialized to the deployer. Transferable via
    ///      {transferGuardianAdmin}. During Pioneer Phase this is the
    ///      protocol operator; post-Pioneer it transfers to governance.
    address public guardianAdmin;

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

    /// @notice Thrown when nonce is invalid
    error InvalidNonce(uint256 expected, uint256 provided);

    /// @notice Thrown when caller lacks the pool creator role
    error NotPoolCreator();

    /// @notice Thrown when the caller is not the guardian admin
    error NotGuardianAdmin();

    /// @notice Thrown when no guardian change is pending
    error NoPendingGuardianChange();

    /// @notice Thrown when a proposed guardian has no deployed code
    error GuardianNotContract();

    /// @notice Thrown when proposing the guardian that is already set
    error GuardianAlreadySet(address guardian);

    // ========================================================================
    // CONSTRUCTOR (IMMUTABLE PARAMETERS SET HERE)
    // ========================================================================

    /**
     * @notice Deploy the immutable AMMPermissionless contract
     * @dev All immutable parameters set here and CANNOT be changed.
     *      Emergency signer verification is delegated to the
     *      EmergencyGuardian contract, enabling guardian rotation
     *      via timelock governance without redeploying the AMM.
     * @param _guardian EmergencyGuardian contract address
     * @param _feeVault Fee vault contract address (UnifiedFeeVault)
     * @param _xomToken XOM token address on this chain (OFT)
     * @param trustedForwarder_ Trusted ERC-2771 forwarder address
     */
    constructor(
        address _guardian,
        address _feeVault,
        address _xomToken,
        address trustedForwarder_
    ) ERC2771Context(trustedForwarder_) {
        if (_guardian == address(0)) revert ZeroAddress();
        if (_feeVault == address(0)) revert ZeroAddress();
        if (_xomToken == address(0)) revert ZeroAddress();

        _emergencyGuardian = IEmergencyGuardian(_guardian);
        FEE_VAULT = _feeVault;
        XOM_TOKEN = _xomToken;
        guardianAdmin = msg.sender;

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

    /**
     * @notice Restrict a function to the guardian admin
     */
    modifier onlyGuardianAdmin() {
        if (_msgSender() != guardianAdmin) revert NotGuardianAdmin();
        _;
    }

    // ========================================================================
    // VIEW FUNCTIONS
    // ========================================================================

    /**
     * @inheritdoc IAMMPermissionless
     */
    function protocolFeeBps() external pure override returns (uint256) {
        return PROTOCOL_FEE_BPS;
    }

    /**
     * @inheritdoc IAMMPermissionless
     */
    function getPool(bytes32 poolId) external view override returns (PoolInfo memory info) {
        address poolAddr = _pools[poolId];
        if (poolAddr == address(0)) revert PoolNotFound(poolId);

        AMMPool pool = AMMPool(poolAddr);
        (uint256 reserve0, uint256 reserve1, ) = pool.getReserves();

        info = PoolInfo({
            token0: pool.token0(),
            token1: pool.token1(),
            reserve0: reserve0,
            reserve1: reserve1,
            totalLiquidity: IERC20(poolAddr).totalSupply(),
            lastUpdateTimestamp: block.timestamp, // solhint-disable-line not-rely-on-time
            status: _poolPaused[poolId] ? PoolStatus.PAUSED : PoolStatus.ACTIVE
        });
    }

    /**
     * @inheritdoc IAMMPermissionless
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
     * @inheritdoc IAMMPermissionless
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

        AMMPool pool = AMMPool(poolAddr);
        (uint256 reserve0, uint256 reserve1, ) = pool.getReserves();

        // Determine reserves based on token order
        (uint256 reserveIn, uint256 reserveOut) = pool.token0() == tokenIn
            ? (reserve0, reserve1)
            : (reserve1, reserve0);

        // Calculate protocol fee
        protocolFee = (amountIn * PROTOCOL_FEE_BPS) / BPS_DENOMINATOR;
        uint256 amountInAfterFee = amountIn - protocolFee;

        // Constant product formula: (x + dx) * (y - dy) = x * y
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
     * @inheritdoc IAMMPermissionless
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
     * @inheritdoc IAMMPermissionless
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
     * @return Current nonce value
     */
    function emergencyNonce() external view returns (uint256) {
        return _emergencyNonce;
    }

    /**
     * @notice Get current pool creator management nonce
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

    /**
     * @notice Execute token swap with fee splitting
     * @dev Calculates 70/20/10 fee split and executes constant-product
     *      swap on the pool. No compliance gating on external chains.
     * @param tokenIn Input token address
     * @param tokenOut Output token address
     * @param amountIn Input amount
     * @param amountOutMin Minimum output amount (slippage protection)
     * @param deadline Transaction deadline
     * @return result Swap result information
     */
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        uint256 deadline
    ) external override
        nonReentrant
        whenNotPaused
        checkDeadline(deadline)
        returns (SwapResult memory result)
    {
        if (amountIn == 0) revert ZeroAmount();

        address caller = _msgSender();

        bytes32 poolId = getPoolId(tokenIn, tokenOut);
        if (_poolPaused[poolId]) revert PoolPaused(poolId);

        address poolAddr = _pools[poolId];
        if (poolAddr == address(0)) revert PoolNotFound(poolId);

        AMMPool pool = AMMPool(poolAddr);
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
            caller, tokenIn, tokenOut,
            amountIn, amountOut, protocolFee
        );
    }

    // ========================================================================
    // LIQUIDITY FUNCTIONS
    // ========================================================================

    /* solhint-disable code-complexity */
    /**
     * @notice Add liquidity to a token pair pool
     * @dev Creates pool if it doesn't exist (requires pool creator role).
     *      Calculates optimal amounts based on current reserves.
     * @param token0 First token address
     * @param token1 Second token address
     * @param amount0Desired Desired amount of token0
     * @param amount1Desired Desired amount of token1
     * @param amount0Min Minimum amount of token0
     * @param amount1Min Minimum amount of token1
     * @param deadline Transaction deadline
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
        uint256 deadline
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

        bytes32 poolId = getPoolId(token0, token1);
        address poolAddr = _pools[poolId];

        // Create pool if it doesn't exist (requires pool creator role)
        if (poolAddr == address(0)) {
            if (!_poolCreators[caller]) revert NotPoolCreator();
            (, poolAddr) = _createPool(token0, token1);
        }

        if (_poolPaused[poolId]) revert PoolPaused(poolId);

        AMMPool pool = AMMPool(poolAddr);
        (uint256 reserve0, uint256 reserve1, ) = pool.getReserves();

        // Determine token order -- swap user amounts to match pool's
        // canonical token0/token1 ordering.
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
            caller, poolId, amount0, amount1, liquidity
        );
    }
    /* solhint-enable code-complexity */

    /**
     * @notice Remove liquidity from pool
     * @param token0 First token address
     * @param token1 Second token address
     * @param liquidity LP tokens to burn
     * @param amount0Min Minimum token0 to receive
     * @param amount1Min Minimum token1 to receive
     * @param deadline Transaction deadline
     * @return amount0 Token0 received
     * @return amount1 Token1 received
     */
    function removeLiquidity(
        address token0,
        address token1,
        uint256 liquidity,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 deadline
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

        bytes32 poolId = getPoolId(token0, token1);
        address poolAddr = _pools[poolId];
        if (poolAddr == address(0)) revert PoolNotFound(poolId);

        AMMPool pool = AMMPool(poolAddr);

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
            caller, poolId, amount0, amount1, liquidity
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
    // GUARDIAN MANAGEMENT (TWO-STEP, GUARDIAN-ADMIN GATED)
    // ========================================================================

    /**
     * @notice Emitted when a new emergency guardian is proposed
     * @dev Step 1 of a two-step change; finalized by
     *      {applyEmergencyGuardian}.
     * @param newGuardian Proposed guardian contract address
     */
    event EmergencyGuardianProposed(address indexed newGuardian);

    /**
     * @notice Emitted when a proposed emergency guardian is applied
     * @param oldGuardian Previous guardian contract address
     * @param newGuardian New guardian contract address
     */
    event EmergencyGuardianUpdated(
        address indexed oldGuardian,
        address indexed newGuardian
    );

    /**
     * @notice Emitted when the guardian admin is transferred
     * @param oldAdmin Previous admin address
     * @param newAdmin New admin address
     */
    event GuardianAdminTransferred(
        address indexed oldAdmin,
        address indexed newAdmin
    );

    /**
     * @notice Get the current emergency guardian contract
     * @return The guardian contract delegating {isGuardian} checks
     */
    function emergencyGuardian()
        public
        view
        returns (IEmergencyGuardian)
    {
        return _emergencyGuardian;
    }

    /**
     * @notice Propose a new emergency guardian (step 1 of 2)
     * @dev The guardian must have deployed code so {isGuardian} never
     *      reverts (audit H-03 pattern). Finalize with
     *      {applyEmergencyGuardian}. Two steps prevent a single
     *      accidental or compromised transaction from silently
     *      replacing the guardian.
     * @param newGuardian New guardian contract address
     */
    function proposeEmergencyGuardian(
        address newGuardian
    ) external onlyGuardianAdmin {
        if (newGuardian == address(0)) revert ZeroAddress();
        if (newGuardian.code.length == 0) revert GuardianNotContract();
        if (newGuardian == address(_emergencyGuardian)) {
            revert GuardianAlreadySet(newGuardian);
        }

        _pendingGuardian = IEmergencyGuardian(newGuardian);

        emit EmergencyGuardianProposed(newGuardian);
    }

    /**
     * @notice Apply a proposed emergency guardian (step 2 of 2)
     * @dev Finalizes the guardian set by {proposeEmergencyGuardian}.
     */
    function applyEmergencyGuardian() external onlyGuardianAdmin {
        IEmergencyGuardian pending = _pendingGuardian;
        if (address(pending) == address(0)) {
            revert NoPendingGuardianChange();
        }

        IEmergencyGuardian oldGuardian = _emergencyGuardian;
        _emergencyGuardian = pending;
        delete _pendingGuardian;

        emit EmergencyGuardianUpdated(
            address(oldGuardian), address(pending)
        );
    }

    /**
     * @notice Transfer guardian admin authority
     * @dev Post-Pioneer this transfers to governance. The recipient
     *      should be a trusted contract or multisig.
     * @param newAdmin New guardian admin address
     */
    function transferGuardianAdmin(
        address newAdmin
    ) external onlyGuardianAdmin {
        if (newAdmin == address(0)) revert ZeroAddress();

        address oldAdmin = guardianAdmin;
        guardianAdmin = newAdmin;

        emit GuardianAdminTransferred(oldAdmin, newAdmin);
    }

    // ========================================================================
    // EMERGENCY FUNCTIONS (MULTI-SIG REQUIRED)
    // ========================================================================

    /**
     * @inheritdoc IAMMPermissionless
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
     * @inheritdoc IAMMPermissionless
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
     * @dev Delegates to the guardian contract's {isGuardian} so that the
     *      guardian set can be rotated via the guardian contract OR the
     *      guardian itself swapped via the two-step
     *      {proposeEmergencyGuardian}/{applyEmergencyGuardian} flow —
     *      neither requires redeploying this AMM (audit H-02).
     * @param signer Address to check
     * @return True if signer is an active guardian
     */
    function _isEmergencySigner(address signer) internal view returns (bool) {
        return _emergencyGuardian.isGuardian(signer);
    }

    /**
     * @notice Internal pool creation logic
     * @dev Deploys a new AMMPool and registers it. Shared by createPool()
     *      and addLiquidity() (auto-creation path).
     *
     *      Audit M-01: Fee-on-transfer (FOT) tokens are NOT supported.
     *      Pool creators MUST verify that all tokens deliver exact
     *      transfer amounts.
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

        // Sort tokens for consistent ordering
        (address tokenA, address tokenB) = token0 < token1
            ? (token0, token1)
            : (token1, token0);

        poolId = getPoolId(tokenA, tokenB);
        if (_pools[poolId] != address(0)) {
            revert PoolAlreadyExists(poolId);
        }

        // Deploy new pool contract
        AMMPool pool = new AMMPool();
        pool.initialize(tokenA, tokenB);

        _pools[poolId] = address(pool);
        _allPoolIds.push(poolId);

        emit PoolCreated(poolId, tokenA, tokenB, _msgSender());

        poolAddress = address(pool);
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
}
