// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
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
 * Security Features:
 * - Reentrancy protection
 * - Deadline checks for all operations
 * - Slippage protection
 * - Multi-sig emergency controls
 */
contract RWAAMM is IRWAAMM, ReentrancyGuard {
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

    /// @notice Nonce for emergency operations (replay protection)
    uint256 private _emergencyNonce;

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
     */
    // solhint-disable-next-line code-complexity
    constructor(
        address[5] memory _emergencyMultisig,
        address _feeVault,
        address _xomToken,
        address _complianceOracle
    ) {
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
     * @notice Get current emergency nonce
     * @return Current nonce value
     */
    function emergencyNonce() external view returns (uint256) {
        return _emergencyNonce;
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
        if (!_poolCreators[msg.sender]) revert NotPoolCreator();
        return _createPool(token0, token1);
    }

    // ========================================================================
    // SWAP FUNCTIONS
    // ========================================================================

    /* solhint-disable code-complexity */
    /**
     * @notice Execute token swap with fee splitting
     * @dev Routes through compliance checks, calculates 70/20/10 fee split,
     *      and executes the constant-product swap on the pool.
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

        bytes32 poolId = getPoolId(tokenIn, tokenOut);
        if (_poolPaused[poolId]) revert PoolPaused(poolId);

        address poolAddr = _pools[poolId];
        if (poolAddr == address(0)) revert PoolNotFound(poolId);

        // Check compliance if required
        if (_isComplianceRequired(tokenIn, tokenOut)) {
            _checkSwapCompliance(msg.sender, tokenIn, tokenOut, amountIn);
        }

        RWAPool pool = RWAPool(poolAddr);
        (uint256 reserve0, uint256 reserve1, ) = pool.getReserves();

        // Determine reserves based on token order
        bool isToken0In = pool.token0() == tokenIn;
        (uint256 reserveIn, uint256 reserveOut) = isToken0In
            ? (reserve0, reserve1)
            : (reserve1, reserve0);

        // Calculate protocol fee (0.30% of amountIn)
        uint256 protocolFee = (amountIn * PROTOCOL_FEE_BPS) / BPS_DENOMINATOR;
        uint256 amountInAfterFee = amountIn - protocolFee;

        // Split protocol fee: 70% stays in pool (LP revenue),
        // 30% goes to FeeCollector (20% staking + 10% liquidity)
        uint256 lpFee = (protocolFee * FEE_LP_BPS) / BPS_DENOMINATOR;
        uint256 collectorFee = protocolFee - lpFee;

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
            msg.sender, poolAddr, amountToPool
        );

        // Transfer collector fee (20% staking + 10% liquidity)
        // to UnifiedFeeVault for batched distribution
        if (collectorFee > 0) {
            IERC20(tokenIn).safeTransferFrom(
                msg.sender, FEE_VAULT, collectorFee
            );
        }

        // Execute swap on pool
        (uint256 amount0Out, uint256 amount1Out) = isToken0In
            ? (uint256(0), amountOut)
            : (amountOut, uint256(0));

        pool.swap(amount0Out, amount1Out, msg.sender, "");

        // Calculate price impact
        uint256 priceImpact = 0;
        if (reserveIn > 0) {
            uint256 idealAmountOut = (reserveOut * amountInAfterFee) / reserveIn;
            if (idealAmountOut > 0) {
                priceImpact = ((idealAmountOut - amountOut) * BPS_DENOMINATOR) / idealAmountOut;
            }
        }

        // Build result
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

        emit Swap(msg.sender, tokenIn, tokenOut, amountIn, amountOut, protocolFee);
    }
    /* solhint-enable code-complexity */

    // ========================================================================
    // LIQUIDITY FUNCTIONS
    // ========================================================================

    /* solhint-disable code-complexity */
    /**
     * @notice Add liquidity to a token pair pool
     * @dev Creates pool if it doesn't exist. Calculates optimal amounts
     *      based on current reserves. Enforces compliance checks.
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
        bytes32 poolId = getPoolId(token0, token1);
        address poolAddr = _pools[poolId];

        // Create pool if it doesn't exist (requires pool creator role)
        if (poolAddr == address(0)) {
            if (!_poolCreators[msg.sender]) revert NotPoolCreator();
            (, poolAddr) = _createPool(token0, token1);
        }

        if (_poolPaused[poolId]) revert PoolPaused(poolId);

        // Check compliance for both tokens (RWA tokens require
        // KYC/accreditation for all interactions, including liquidity)
        if (_isComplianceRequired(token0, token1)) {
            _checkLiquidityCompliance(msg.sender, token0, token1);
        }

        RWAPool pool = RWAPool(poolAddr);
        (uint256 reserve0, uint256 reserve1, ) = pool.getReserves();

        // Determine token order — swap user amounts to match pool's
        // canonical token0/token1 ordering. Do NOT swap reserves;
        // they are already in pool order from getReserves().
        bool isToken0First = pool.token0() == token0;
        if (!isToken0First) {
            (amount0Desired, amount1Desired) = (amount1Desired, amount0Desired);
            (amount0Min, amount1Min) = (amount1Min, amount0Min);
        }

        // Calculate optimal amounts
        if (reserve0 == 0 && reserve1 == 0) {
            (amount0, amount1) = (amount0Desired, amount1Desired);
        } else {
            uint256 amount1Optimal = (amount0Desired * reserve1) / reserve0;
            // solhint-disable-next-line gas-strict-inequalities
            if (amount1Optimal <= amount1Desired) {
                if (amount1Optimal < amount1Min) {
                    revert SlippageExceeded(amount1Min, amount1Optimal);
                }
                (amount0, amount1) = (amount0Desired, amount1Optimal);
            } else {
                uint256 amount0Optimal = (amount1Desired * reserve0) / reserve1;
                if (amount0Optimal < amount0Min) {
                    revert SlippageExceeded(amount0Min, amount0Optimal);
                }
                (amount0, amount1) = (amount0Optimal, amount1Desired);
            }
        }

        // Transfer tokens to pool
        address actualToken0 = pool.token0();
        address actualToken1 = pool.token1();

        IERC20(actualToken0).safeTransferFrom(msg.sender, poolAddr, amount0);
        IERC20(actualToken1).safeTransferFrom(msg.sender, poolAddr, amount1);

        // Mint LP tokens
        liquidity = pool.mint(msg.sender);

        // Swap back amounts if needed for return values
        if (!isToken0First) {
            (amount0, amount1) = (amount1, amount0);
        }

        emit LiquidityAdded(msg.sender, poolId, amount0, amount1, liquidity);
    }
    /* solhint-enable code-complexity */

    /**
     * @inheritdoc IRWAAMM
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
        bytes32 poolId = getPoolId(token0, token1);
        address poolAddr = _pools[poolId];
        if (poolAddr == address(0)) revert PoolNotFound(poolId);

        // Check compliance for both tokens before withdrawal
        if (_isComplianceRequired(token0, token1)) {
            _checkLiquidityCompliance(msg.sender, token0, token1);
        }

        RWAPool pool = RWAPool(poolAddr);

        // Transfer LP tokens to pool
        IERC20(poolAddr).safeTransferFrom(msg.sender, poolAddr, liquidity);

        // Burn LP tokens and get underlying
        (amount0, amount1) = pool.burn(msg.sender);

        // Check minimums
        bool isToken0First = pool.token0() == token0;
        if (!isToken0First) {
            (amount0, amount1) = (amount1, amount0);
        }

        if (amount0 < amount0Min) revert SlippageExceeded(amount0Min, amount0);
        if (amount1 < amount1Min) revert SlippageExceeded(amount1Min, amount1);

        emit LiquidityRemoved(msg.sender, poolId, amount0, amount1, liquidity);
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

        bytes32 messageHash = keccak256(abi.encodePacked(
            "SET_POOL_CREATOR",
            creator,
            authorized,
            _emergencyNonce,
            block.chainid,
            address(this)
        ));

        _verifyMultiSig(messageHash, signatures);
        ++_emergencyNonce;

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

        emit EmergencyPaused(poolId, msg.sender, reason);
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

        emit EmergencyUnpaused(poolId, msg.sender);
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
        RWAPool pool = new RWAPool();
        pool.initialize(tokenA, tokenB);

        _pools[poolId] = address(pool);
        _allPoolIds.push(poolId);

        emit PoolCreated(poolId, tokenA, tokenB, msg.sender);

        poolAddress = address(pool);
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
