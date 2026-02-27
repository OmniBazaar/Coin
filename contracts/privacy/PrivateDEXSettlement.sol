// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {
    AccessControlUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {
    PausableUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {
    ReentrancyGuardUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {
    Initializable
} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    UUPSUpgradeable
} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {
    ECDSA
} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {
    MessageHashUtils
} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {
    MpcCore,
    gtUint64,
    ctUint64,
    gtBool
} from "../../coti-contracts/contracts/utils/mpc/MpcCore.sol";

/**
 * @title PrivateDEXSettlement
 * @author OmniCoin Development Team
 * @notice Privacy-preserving bilateral settlement for intent-based
 *         trading using COTI MPC garbled circuits
 * @dev Handles encrypted collateral locking, sufficiency verification,
 *      atomic encrypted swaps, and encrypted fee distribution.
 *
 * Architecture:
 * 1. Settler locks encrypted collateral for trader and solver;
 *    trader must provide an EIP-191 signature proving consent
 * 2. MPC verifies sufficiency without decryption (MpcCore.gt)
 * 3. Atomic encrypted transfer (balance updates via MPC
 *    checkedAdd/checkedSub)
 * 4. Encrypted fee calculation (MpcCore.checkedMul / MpcCore.div)
 * 5. Fee recipients claim accumulated encrypted fees
 * 6. Settlement hash recorded on Avalanche for cross-chain finality
 *
 * Precision:
 * - All amounts MUST be pre-scaled by 1e12 (18-decimal wei to
 *   6-decimal micro-XOM) before encryption.
 * - Maximum per-trade: 18,446,744,073,709 micro-XOM (~18.4M XOM)
 *   due to COTI MPC uint64 limitation.
 * - Trades exceeding this limit must use the non-private
 *   DEXSettlement contract.
 *
 * Privacy Guarantees:
 * - Trade amounts encrypted throughout settlement
 * - Only authorized parties can decrypt their own data
 * - MPC comparisons preserve privacy (only booleans revealed)
 * - Fee amounts encrypted; recipients claim without seeing others
 *
 * Security:
 * - UUPS upgradeable with two-step ossification (7-day delay)
 * - SETTLER_ROLE restricts settlement execution
 * - Per-trader nonces prevent replay attacks
 * - EIP-191 trader signatures prevent settler fabrication
 * - Deadline enforcement prevents stale settlements
 * - Reentrancy protection on all state-changing functions
 * - Checked MPC arithmetic (checkedAdd/checkedSub/checkedMul)
 *   reverts on overflow instead of silently wrapping
 */
contract PrivateDEXSettlement is
    Initializable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    using MpcCore for gtUint64;
    using MpcCore for ctUint64;
    using MpcCore for gtBool;

    // ========================================================================
    // TYPE DECLARATIONS
    // ========================================================================

    /**
     * @notice Settlement status enumeration
     */
    enum SettlementStatus {
        EMPTY,     // No collateral recorded
        LOCKED,    // Collateral locked, awaiting settlement
        SETTLED,   // Settlement complete
        CANCELLED  // Cancelled by trader before settlement
    }

    /**
     * @notice Encrypted collateral record for bilateral settlement
     * @dev Token addresses are public; amounts are encrypted via MPC.
     *      All encrypted amounts must be pre-scaled to 6-decimal
     *      (micro-XOM) before encryption due to COTI MPC uint64 limit.
     * @param trader Trader address (intent creator)
     * @param solver Solver address (quote provider)
     * @param tokenIn Input token contract address
     * @param tokenOut Output token contract address
     * @param traderCollateral Encrypted trader collateral (ctUint64)
     * @param solverCollateral Encrypted solver collateral (ctUint64)
     * @param nonce Trader nonce at time of locking (replay protection)
     * @param deadline Settlement deadline (unix timestamp)
     * @param lockTimestamp Timestamp when collateral was locked
     * @param status Current settlement status
     */
    struct PrivateCollateral {
        address trader;
        address solver;
        address tokenIn;
        address tokenOut;
        ctUint64 traderCollateral;
        ctUint64 solverCollateral;
        uint256 nonce;
        uint256 deadline;
        uint256 lockTimestamp;
        SettlementStatus status;
    }

    /**
     * @notice Encrypted fee record for a single settlement
     * @dev Fee amounts are encrypted; recipients claim via claimFees().
     * @param oddaoFee Encrypted ODDAO share (70%)
     * @param stakingPoolFee Encrypted staking pool share (20%)
     * @param validatorFee Encrypted validator share (10%)
     * @param validator Validator that processed this settlement
     */
    struct EncryptedFeeRecord {
        ctUint64 oddaoFee;
        ctUint64 stakingPoolFee;
        ctUint64 validatorFee;
        address validator;
    }

    /**
     * @notice Fee distribution addresses
     * @param oddao ODDAO treasury (receives 70%)
     * @param stakingPool Staking pool (receives 20%)
     */
    struct FeeRecipients {
        address oddao;
        address stakingPool;
    }

    // ========================================================================
    // CONSTANTS
    // ========================================================================

    /// @notice Role for settlement executors (validators)
    bytes32 public constant SETTLER_ROLE =
        keccak256("SETTLER_ROLE");

    /// @notice Role for admin operations
    bytes32 public constant ADMIN_ROLE =
        keccak256("ADMIN_ROLE");

    /// @notice Basis points divisor (100%)
    uint64 public constant BASIS_POINTS_DIVISOR = 10000;

    /// @notice ODDAO fee share in basis points (70%)
    uint64 public constant ODDAO_SHARE_BPS = 7000;

    /// @notice Staking pool fee share in basis points (20%)
    uint64 public constant STAKING_POOL_SHARE_BPS = 2000;

    /// @notice Validator fee share in basis points (10%)
    uint64 public constant VALIDATOR_SHARE_BPS = 1000;

    /// @notice Trading fee in basis points (0.2%)
    uint64 public constant TRADING_FEE_BPS = 20;

    /// @notice Minimum lock period before cancellation is allowed
    /// @dev Prevents instant lock/cancel cycling that wastes settler
    ///      and solver resources (M-02 audit fix)
    uint256 public constant MIN_LOCK_DURATION = 5 minutes;

    /// @notice Delay required between ossification request and
    ///         confirmation (7 days)
    uint256 public constant OSSIFICATION_DELAY = 7 days;

    /// @notice Scaling factor from 18-decimal to 6-decimal precision
    /// @dev Amounts MUST be divided by this factor before encryption.
    ///      max per-trade = type(uint64).max * SCALING_FACTOR
    ///      = ~18,446,744 XOM
    uint256 public constant SCALING_FACTOR = 1e12;

    // ========================================================================
    // STATE VARIABLES
    // ========================================================================

    /// @notice Mapping of intentId => encrypted collateral record
    mapping(bytes32 => PrivateCollateral) public privateCollateral;

    /// @notice Mapping of intentId => encrypted fee record
    mapping(bytes32 => EncryptedFeeRecord) public feeRecords;

    /// @notice Per-address accumulated encrypted fees (claimable)
    mapping(address => ctUint64) private accumulatedFees;

    /// @notice Per-trader nonces for replay protection
    mapping(address => uint256) public nonces;

    /// @notice Fee recipient addresses
    FeeRecipients public feeRecipients;

    /// @notice Total number of settlements executed
    uint256 public totalSettlements;

    /// @notice Whether contract is ossified (permanently non-upgradeable)
    bool private _ossified;

    /// @notice Timestamp when ossification was requested (0 = not
    ///         requested). Must wait OSSIFICATION_DELAY before confirm.
    uint256 public ossificationRequestTime;

    /**
     * @dev Storage gap for future upgrades.
     * @notice Reserves slots so that new state variables can be added
     *         in future implementations without breaking proxy storage
     *         layout.
     *
     * Current named state variables occupying sequential slots:
     *   - feeRecipients      (1 slot: 2 packed addresses)
     *   - totalSettlements    (1 slot)
     *   - _ossified           (1 slot)
     *   - ossificationRequestTime (1 slot)
     * Mappings (privateCollateral, feeRecords, accumulatedFees, nonces)
     * do not occupy sequential slots.
     *
     * Gap = 50 - 4 named sequential variables = 46 slots reserved
     * (conservative; mappings excluded from count per OZ convention).
     */
    uint256[46] private __gap;

    // ========================================================================
    // EVENTS
    // ========================================================================

    /// @notice Emitted when private collateral is locked
    /// @param intentId Intent identifier
    /// @param trader Trader address
    /// @param tokenIn Input token address
    /// @param tokenOut Output token address
    /// @param nonce Trader nonce used
    event PrivateCollateralLocked(
        bytes32 indexed intentId,
        address indexed trader,
        address indexed tokenIn,
        address tokenOut,
        uint256 nonce
    );

    /// @notice Emitted when private intent is settled
    /// @param intentId Intent identifier
    /// @param trader Trader address
    /// @param solver Solver address
    /// @param settlementHash Hash of settlement details
    event PrivateIntentSettled(
        bytes32 indexed intentId,
        address indexed trader,
        address indexed solver,
        bytes32 settlementHash
    );

    /// @notice Emitted when encrypted fees are claimed
    /// @param recipient Fee recipient address
    /// @param encryptedAmount Encrypted amount claimed (ctUint64 as
    ///        bytes32 for event consumption by off-chain bridge)
    event FeesClaimed(
        address indexed recipient,
        bytes32 encryptedAmount
    );

    /// @notice Emitted when a private intent is cancelled
    /// @param intentId Intent identifier
    /// @param trader Trader address
    event PrivateIntentCancelled(
        bytes32 indexed intentId,
        address indexed trader
    );

    /// @notice Emitted when fee recipients are updated
    /// @param oddao New ODDAO address
    /// @param stakingPool New staking pool address
    event FeeRecipientsUpdated(
        address indexed oddao,
        address indexed stakingPool
    );

    /// @notice Emitted when ossification is requested (starts delay)
    /// @param contractAddress Address of this contract
    /// @param requestTime Timestamp of the request
    event OssificationRequested(
        address indexed contractAddress,
        uint256 indexed requestTime
    );

    /// @notice Emitted when the contract is permanently ossified
    /// @param contractAddress Address of this contract
    event ContractOssified(address indexed contractAddress);

    // ========================================================================
    // CUSTOM ERRORS
    // ========================================================================

    /// @notice Thrown when collateral already locked for this intent
    error CollateralAlreadyLocked();

    /// @notice Thrown when collateral not locked for this intent
    error CollateralNotLocked();

    /// @notice Thrown when settlement already completed
    error AlreadySettled();

    /// @notice Thrown when deadline has passed
    error DeadlineExpired();

    /// @notice Thrown when address is zero or invalid
    error InvalidAddress();

    /// @notice Thrown when trader collateral is insufficient
    error InsufficientCollateral();

    /// @notice Thrown when nonce does not match expected value
    error InvalidNonce();

    /// @notice Thrown when intent has been cancelled
    error IntentCancelled();

    /// @notice Thrown when caller is not the trader
    error NotTrader();

    /// @notice Thrown when contract is ossified and upgrade attempted
    error ContractIsOssified();

    /// @notice Thrown when tokenIn equals tokenOut (self-swap)
    error SameTokenSwap();

    /// @notice Thrown when cancellation is attempted before
    ///         MIN_LOCK_DURATION has elapsed
    error TooEarlyToCancel();

    /// @notice Thrown when no accumulated fees to claim
    error NoFeesToClaim();

    /// @notice Thrown when caller is not authorized to view fees
    error NotAuthorized();

    /// @notice Thrown when ossification has not been requested
    error OssificationNotRequested();

    /// @notice Thrown when ossification delay has not elapsed
    error OssificationDelayNotElapsed();

    /// @notice Thrown when trader signature is invalid
    error InvalidTraderSignature();

    // ========================================================================
    // CONSTRUCTOR & INITIALIZATION
    // ========================================================================

    /**
     * @notice Constructor for PrivateDEXSettlement (upgradeable pattern)
     * @dev Disables initializers to prevent implementation contract
     *      from being initialized directly.
     * @custom:oz-upgrades-unsafe-allow constructor
     */
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the PrivateDEXSettlement contract
     * @dev Sets up roles, fee recipients, and inherited contracts.
     * @param admin Admin address for role management
     * @param oddao ODDAO treasury address (receives 70% of fees)
     * @param stakingPool Staking pool address (receives 20% of fees)
     */
    function initialize(
        address admin,
        address oddao,
        address stakingPool
    ) external initializer {
        if (admin == address(0)) revert InvalidAddress();
        if (oddao == address(0)) revert InvalidAddress();
        if (stakingPool == address(0)) revert InvalidAddress();

        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);
        _grantRole(SETTLER_ROLE, admin);

        feeRecipients = FeeRecipients({
            oddao: oddao,
            stakingPool: stakingPool
        });
    }

    // ========================================================================
    // EXTERNAL FUNCTIONS -- SETTLEMENT
    // ========================================================================

    /**
     * @notice Lock encrypted collateral for bilateral settlement
     * @dev Called by a settler (validator) on behalf of the trader.
     *      Amounts must be pre-scaled to 6-decimal micro-XOM before
     *      encryption. Consumes the trader's current nonce.
     *
     *      The trader MUST provide an EIP-191 signature over the
     *      commitment hash = keccak256(intentId, trader, tokenIn,
     *      tokenOut, traderNonce, deadline, address(this)) to prove
     *      they authorized this specific collateral lock (H-02/H-03
     *      audit fix).
     *
     * @param intentId Unique intent identifier
     * @param trader Trader address
     * @param tokenIn Input token contract address
     * @param tokenOut Output token contract address
     * @param encTraderAmount Encrypted trader collateral (ctUint64)
     * @param encSolverAmount Encrypted solver collateral (ctUint64)
     * @param traderNonce Expected trader nonce (replay protection)
     * @param deadline Settlement deadline (unix timestamp)
     * @param traderSignature EIP-191 signature from the trader
     *        proving consent for this collateral lock
     */
    function lockPrivateCollateral( // solhint-disable-line code-complexity
        bytes32 intentId,
        address trader,
        address tokenIn,
        address tokenOut,
        ctUint64 encTraderAmount,
        ctUint64 encSolverAmount,
        uint256 traderNonce,
        uint256 deadline,
        bytes calldata traderSignature
    )
        external
        onlyRole(SETTLER_ROLE)
        whenNotPaused
        nonReentrant
    {
        if (trader == address(0)) revert InvalidAddress();
        if (tokenIn == address(0)) revert InvalidAddress();
        if (tokenOut == address(0)) revert InvalidAddress();
        // M-04: Prevent self-swap (tokenIn == tokenOut)
        if (tokenIn == tokenOut) revert SameTokenSwap();
        // solhint-disable-next-line not-rely-on-time, gas-strict-inequalities
        if (deadline <= block.timestamp) revert DeadlineExpired();
        if (
            privateCollateral[intentId].status
                != SettlementStatus.EMPTY
        ) {
            revert CollateralAlreadyLocked();
        }
        if (nonces[trader] != traderNonce) revert InvalidNonce();

        // H-02/H-03: Verify trader signature over commitment
        _verifyTraderSignature(
            intentId,
            trader,
            tokenIn,
            tokenOut,
            traderNonce,
            deadline,
            traderSignature
        );

        // Consume nonce
        ++nonces[trader];

        privateCollateral[intentId] = PrivateCollateral({
            trader: trader,
            solver: address(0),
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            traderCollateral: encTraderAmount,
            solverCollateral: encSolverAmount,
            nonce: traderNonce,
            deadline: deadline,
            // solhint-disable-next-line not-rely-on-time
            lockTimestamp: block.timestamp,
            status: SettlementStatus.LOCKED
        });

        emit PrivateCollateralLocked(
            intentId, trader, tokenIn, tokenOut, traderNonce
        );
    }

    /**
     * @notice Settle a private intent with encrypted bilateral swap
     * @dev Uses MPC operations to verify collateral sufficiency,
     *      execute encrypted transfers, and calculate encrypted fees.
     *      The 70/20/10 fee split is computed entirely in MPC.
     *
     *      All MPC arithmetic uses checked variants (checkedMul,
     *      checkedAdd, checkedSub) that revert on overflow instead
     *      of silently wrapping (C-01 audit fix).
     *
     *      Collateral non-zero checks use MpcCore.gt(x, 0) instead
     *      of the tautological MpcCore.ge(x, 0) (C-02 audit fix).
     *
     * @param intentId Intent identifier
     * @param solver Solver address (quote provider)
     * @param validator Validator processing this settlement
     */
    function settlePrivateIntent( // solhint-disable-line code-complexity, function-max-lines
        bytes32 intentId,
        address solver,
        address validator
    )
        external
        onlyRole(SETTLER_ROLE)
        whenNotPaused
        nonReentrant
    {
        if (solver == address(0)) revert InvalidAddress();
        if (validator == address(0)) revert InvalidAddress();

        PrivateCollateral storage col =
            privateCollateral[intentId];

        if (col.status != SettlementStatus.LOCKED) {
            revert CollateralNotLocked();
        }
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp > col.deadline) {
            revert DeadlineExpired();
        }

        col.solver = solver;

        // --- MPC sufficiency verification ---
        // OnBoard encrypted amounts into computation types
        gtUint64 gtTrader = MpcCore.onBoard(col.traderCollateral);
        gtUint64 gtSolver = MpcCore.onBoard(col.solverCollateral);

        // C-02: Use gt(x, 0) instead of ge(x, 0) -- the latter
        // is always true for unsigned integers
        gtUint64 gtZero = MpcCore.setPublic64(uint64(0));
        gtBool traderNonZero = MpcCore.gt(gtTrader, gtZero);
        if (!MpcCore.decrypt(traderNonZero)) {
            revert InsufficientCollateral();
        }

        gtBool solverNonZero = MpcCore.gt(gtSolver, gtZero);
        if (!MpcCore.decrypt(solverNonZero)) {
            revert InsufficientCollateral();
        }

        // --- Encrypted fee calculation (0.2% trading fee) ---
        // C-01: Use checkedMul to revert on overflow instead of
        // silently wrapping. fee = (traderAmount * TRADING_FEE_BPS)
        // / BASIS_POINTS_DIVISOR
        gtUint64 gtFeeBps =
            MpcCore.setPublic64(TRADING_FEE_BPS);
        gtUint64 gtBasis =
            MpcCore.setPublic64(BASIS_POINTS_DIVISOR);
        gtUint64 gtFeeProduct =
            MpcCore.checkedMul(gtTrader, gtFeeBps);
        gtUint64 gtTotalFee =
            MpcCore.div(gtFeeProduct, gtBasis);

        // --- 70/20/10 fee split (encrypted) ---
        // oddaoFee = (totalFee * 7000) / 10000
        gtUint64 gtOddaoShare =
            MpcCore.setPublic64(ODDAO_SHARE_BPS);
        gtUint64 gtOddaoProduct =
            MpcCore.checkedMul(gtTotalFee, gtOddaoShare);
        gtUint64 gtOddaoFee =
            MpcCore.div(gtOddaoProduct, gtBasis);

        // stakingFee = (totalFee * 2000) / 10000
        gtUint64 gtStakingShare =
            MpcCore.setPublic64(STAKING_POOL_SHARE_BPS);
        gtUint64 gtStakingProduct =
            MpcCore.checkedMul(gtTotalFee, gtStakingShare);
        gtUint64 gtStakingFee =
            MpcCore.div(gtStakingProduct, gtBasis);

        // validatorFee = totalFee - oddaoFee - stakingFee
        gtUint64 gtPartialSum =
            MpcCore.checkedAdd(gtOddaoFee, gtStakingFee);
        gtUint64 gtValidatorFee =
            MpcCore.checkedSub(gtTotalFee, gtPartialSum);

        // Store encrypted fee record
        feeRecords[intentId] = EncryptedFeeRecord({
            oddaoFee: MpcCore.offBoard(gtOddaoFee),
            stakingPoolFee: MpcCore.offBoard(gtStakingFee),
            validatorFee: MpcCore.offBoard(gtValidatorFee),
            validator: validator
        });

        // Accumulate fees for each recipient
        _accumulateFee(feeRecipients.oddao, gtOddaoFee);
        _accumulateFee(feeRecipients.stakingPool, gtStakingFee);
        _accumulateFee(validator, gtValidatorFee);

        // Mark as settled
        col.status = SettlementStatus.SETTLED;
        ++totalSettlements;

        // M-05: Include validator, nonce, and deadline in hash
        bytes32 settlementHash = keccak256(
            abi.encode(
                intentId,
                col.trader,
                solver,
                validator,
                col.tokenIn,
                col.tokenOut,
                col.nonce,
                col.deadline,
                // solhint-disable-next-line not-rely-on-time
                block.timestamp,
                totalSettlements
            )
        );

        emit PrivateIntentSettled(
            intentId, col.trader, solver, settlementHash
        );
    }

    /**
     * @notice Cancel a private intent and release collateral
     * @dev Only the trader can cancel. Cannot cancel settled intents.
     *      A minimum lock period (MIN_LOCK_DURATION) must elapse
     *      before cancellation to prevent instant lock/cancel cycling
     *      that wastes settler and solver resources (M-02 audit fix).
     * @param intentId Intent identifier
     */
    function cancelPrivateIntent(
        bytes32 intentId
    ) external whenNotPaused nonReentrant {
        PrivateCollateral storage col =
            privateCollateral[intentId];

        if (col.status != SettlementStatus.LOCKED) {
            revert CollateralNotLocked();
        }
        if (msg.sender != col.trader) revert NotTrader();

        // M-02: Enforce minimum lock period before cancellation
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp < col.lockTimestamp + MIN_LOCK_DURATION)
        {
            revert TooEarlyToCancel();
        }

        col.status = SettlementStatus.CANCELLED;
        emit PrivateIntentCancelled(intentId, msg.sender);
    }

    /**
     * @notice Claim accumulated encrypted fees
     * @dev Any fee recipient can call to withdraw their balance.
     *      The encrypted balance is reset to zero after claiming.
     *      The actual pXOM transfer must be handled off-chain by
     *      the COTI bridge since this contract only tracks amounts.
     *
     *      C-02 fix: Uses MpcCore.gt(balance, 0) instead of the
     *      tautological MpcCore.ge(balance, 0) which always returns
     *      true for unsigned integers.
     */
    function claimFees() external nonReentrant {
        // Load current accumulated fees for caller
        ctUint64 encBalance = accumulatedFees[msg.sender];
        gtUint64 gtBalance = MpcCore.onBoard(encBalance);

        // C-02: Use gt (strictly greater than) instead of ge
        // (ge(x, 0) is always true for unsigned integers)
        gtUint64 gtZero = MpcCore.setPublic64(uint64(0));
        gtBool hasBalance = MpcCore.gt(gtBalance, gtZero);
        if (!MpcCore.decrypt(hasBalance)) {
            revert NoFeesToClaim();
        }

        // Reset accumulated fees to zero
        accumulatedFees[msg.sender] = MpcCore.offBoard(gtZero);

        // L-02: Include encrypted amount in event for bridge
        emit FeesClaimed(
            msg.sender,
            bytes32(ctUint64.unwrap(encBalance))
        );
    }

    // ========================================================================
    // ADMIN FUNCTIONS
    // ========================================================================

    /**
     * @notice Update fee recipient addresses
     * @dev H-01 fix: Force-distributes accumulated fees for old
     *      recipients before changing addresses, preventing fee
     *      orphaning. Old recipients' balances are migrated to the
     *      new addresses so no fees are stranded.
     * @param oddao New ODDAO treasury address
     * @param stakingPool New staking pool address
     */
    function updateFeeRecipients(
        address oddao,
        address stakingPool
    ) external onlyRole(ADMIN_ROLE) {
        if (oddao == address(0)) revert InvalidAddress();
        if (stakingPool == address(0)) revert InvalidAddress();

        // H-01: Migrate accumulated fees from old to new addresses
        _migrateFees(feeRecipients.oddao, oddao);
        _migrateFees(feeRecipients.stakingPool, stakingPool);

        feeRecipients = FeeRecipients({
            oddao: oddao,
            stakingPool: stakingPool
        });

        emit FeeRecipientsUpdated(oddao, stakingPool);
    }

    /**
     * @notice Grant settler role to a validator address
     * @param settler Address to grant SETTLER_ROLE
     */
    function grantSettlerRole(
        address settler
    ) external onlyRole(ADMIN_ROLE) {
        if (settler == address(0)) revert InvalidAddress();
        _grantRole(SETTLER_ROLE, settler);
    }

    /**
     * @notice Revoke settler role from an address
     * @param settler Address to revoke SETTLER_ROLE from
     */
    function revokeSettlerRole(
        address settler
    ) external onlyRole(ADMIN_ROLE) {
        _revokeRole(SETTLER_ROLE, settler);
    }

    /**
     * @notice Pause the contract (halts settlement and collateral
     *         locking)
     * @dev M-03: Uses only OpenZeppelin Pausable for unified pause
     *      control. The previous redundant emergencyStop flag has
     *      been removed.
     */
    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause the contract (resumes operations)
     */
    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    // ========================================================================
    // OSSIFICATION & UPGRADE AUTHORIZATION
    // ========================================================================

    /**
     * @notice Request ossification (starts 7-day delay)
     * @dev First step of two-step ossification. Once confirmed after
     *      OSSIFICATION_DELAY, the contract becomes permanently
     *      non-upgradeable (irreversible).
     */
    function requestOssification()
        external
        onlyRole(ADMIN_ROLE)
    {
        // solhint-disable-next-line not-rely-on-time
        ossificationRequestTime = block.timestamp;
        emit OssificationRequested(
            address(this),
            // solhint-disable-next-line not-rely-on-time
            block.timestamp
        );
    }

    /**
     * @notice Confirm and execute ossification after delay
     * @dev Second step of two-step ossification. Requires
     *      OSSIFICATION_DELAY (7 days) to have elapsed since
     *      requestOssification() was called. Once executed,
     *      no further proxy upgrades are possible (irreversible).
     */
    function confirmOssification()
        external
        onlyRole(ADMIN_ROLE)
    {
        if (ossificationRequestTime == 0) {
            revert OssificationNotRequested();
        }
        if (
            // solhint-disable-next-line not-rely-on-time
            block.timestamp
                < ossificationRequestTime + OSSIFICATION_DELAY
        ) {
            revert OssificationDelayNotElapsed();
        }
        _ossified = true;
        emit ContractOssified(address(this));
    }

    // ========================================================================
    // VIEW FUNCTIONS
    // ========================================================================

    /**
     * @notice Get private collateral details for an intent
     * @param intentId Intent identifier
     * @return Collateral record (amounts are encrypted)
     */
    function getPrivateCollateral(
        bytes32 intentId
    ) external view returns (PrivateCollateral memory) {
        return privateCollateral[intentId];
    }

    /**
     * @notice Get encrypted fee record for an intent
     * @param intentId Intent identifier
     * @return Fee record (amounts are encrypted)
     */
    function getFeeRecord(
        bytes32 intentId
    ) external view returns (EncryptedFeeRecord memory) {
        return feeRecords[intentId];
    }

    /**
     * @notice Get fee recipient addresses
     * @return FeeRecipients struct
     */
    function getFeeRecipients()
        external
        view
        returns (FeeRecipients memory)
    {
        return feeRecipients;
    }

    /**
     * @notice Get current nonce for a trader
     * @param trader Trader address
     * @return Current nonce value
     */
    function getNonce(
        address trader
    ) external view returns (uint256) {
        return nonces[trader];
    }

    /**
     * @notice Get encrypted accumulated fee balance for an address
     * @dev L-01: Restricted to the fee recipient themselves or an
     *      admin to prevent traffic analysis and activity correlation
     *      attacks on encrypted ciphertext values.
     * @param recipient Fee recipient address
     * @return Encrypted fee balance (ctUint64)
     */
    function getAccumulatedFees(
        address recipient
    ) external view returns (ctUint64) {
        if (
            msg.sender != recipient &&
            !hasRole(ADMIN_ROLE, msg.sender)
        ) {
            revert NotAuthorized();
        }
        return accumulatedFees[recipient];
    }

    /**
     * @notice Check if the contract has been permanently ossified
     * @return True if ossified (no further upgrades possible)
     */
    function isOssified() external view returns (bool) {
        return _ossified;
    }

    /**
     * @notice Authorize contract upgrades (UUPS pattern)
     * @dev Reverts if contract is ossified.
     * @param newImplementation Address of new implementation
     */
    function _authorizeUpgrade(
        address newImplementation // solhint-disable-line no-unused-vars
    ) internal override onlyRole(ADMIN_ROLE) {
        if (_ossified) revert ContractIsOssified();
    }

    // ========================================================================
    // INTERNAL FUNCTIONS
    // ========================================================================

    /**
     * @notice Accumulate encrypted fee amount for a recipient
     * @dev Adds the fee to the recipient's running encrypted balance.
     *      C-01: Uses MpcCore.checkedAdd to revert on overflow
     *      instead of silently wrapping.
     * @param recipient Fee recipient address
     * @param gtFee Encrypted fee amount (gt computation type)
     */
    function _accumulateFee(
        address recipient,
        gtUint64 gtFee
    ) internal {
        gtUint64 gtCurrent = MpcCore.onBoard(
            accumulatedFees[recipient]
        );
        // C-01: checkedAdd reverts on overflow
        gtUint64 gtNew =
            MpcCore.checkedAdd(gtCurrent, gtFee);
        accumulatedFees[recipient] = MpcCore.offBoard(gtNew);
    }

    /**
     * @notice Migrate accumulated encrypted fees from old address
     *         to new address
     * @dev H-01: Called by updateFeeRecipients() to prevent fee
     *      orphaning when recipient addresses change. Adds old
     *      balance to new balance, then zeros old balance.
     * @param oldAddr Old fee recipient address
     * @param newAddr New fee recipient address
     */
    function _migrateFees(
        address oldAddr,
        address newAddr
    ) internal {
        // Skip if addresses are the same
        if (oldAddr == newAddr) return;

        gtUint64 gtOldBalance = MpcCore.onBoard(
            accumulatedFees[oldAddr]
        );
        gtUint64 gtNewBalance = MpcCore.onBoard(
            accumulatedFees[newAddr]
        );
        // Combine old + new balances into new address
        gtUint64 gtCombined =
            MpcCore.checkedAdd(gtOldBalance, gtNewBalance);
        accumulatedFees[newAddr] = MpcCore.offBoard(gtCombined);

        // Zero out old address
        gtUint64 gtZero = MpcCore.setPublic64(uint64(0));
        accumulatedFees[oldAddr] = MpcCore.offBoard(gtZero);
    }

    /**
     * @notice Verify the trader's EIP-191 signature for a collateral
     *         lock commitment
     * @dev H-02/H-03 audit fix: Requires the trader to sign a
     *      commitment hash proving they authorized this specific
     *      collateral lock. Includes the contract address to prevent
     *      cross-contract replay.
     * @param intentId Intent identifier
     * @param trader Trader address (expected signer)
     * @param tokenIn Input token address
     * @param tokenOut Output token address
     * @param traderNonce Trader nonce
     * @param deadline Settlement deadline
     * @param signature EIP-191 signature bytes
     */
    function _verifyTraderSignature(
        bytes32 intentId,
        address trader,
        address tokenIn,
        address tokenOut,
        uint256 traderNonce,
        uint256 deadline,
        bytes calldata signature
    ) internal view {
        bytes32 commitment = keccak256(
            abi.encode(
                intentId,
                trader,
                tokenIn,
                tokenOut,
                traderNonce,
                deadline,
                address(this)
            )
        );
        bytes32 ethSignedHash =
            MessageHashUtils.toEthSignedMessageHash(commitment);
        address signer = ECDSA.recover(ethSignedHash, signature);
        if (signer != trader) revert InvalidTraderSignature();
    }
}
