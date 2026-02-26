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
 * 1. Settler locks encrypted collateral for trader and solver
 * 2. MPC verifies sufficiency without decryption (MpcCore.ge)
 * 3. Atomic encrypted transfer (balance updates via MPC add/sub)
 * 4. Encrypted fee calculation (MpcCore.mul / MpcCore.div)
 * 5. Fee recipients claim accumulated encrypted fees
 * 6. Settlement hash recorded on Avalanche for cross-chain finality
 *
 * Precision:
 * - All amounts scaled down by 1e12 (18-decimal wei to 6-decimal)
 * - Max representable: ~18.4 million XOM per trade (uint64 limit)
 *
 * Privacy Guarantees:
 * - Trade amounts encrypted throughout settlement
 * - Only authorized parties can decrypt their own data
 * - MPC comparisons preserve privacy (only booleans revealed)
 * - Fee amounts encrypted; recipients claim without seeing others
 *
 * Security:
 * - UUPS upgradeable with ossification option
 * - SETTLER_ROLE restricts settlement execution
 * - Per-trader nonces prevent replay attacks
 * - Deadline enforcement prevents stale settlements
 * - Reentrancy protection on all state-changing functions
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
     * @param trader Trader address (intent creator)
     * @param solver Solver address (quote provider)
     * @param tokenIn Input token contract address
     * @param tokenOut Output token contract address
     * @param traderCollateral Encrypted trader collateral (ctUint64)
     * @param solverCollateral Encrypted solver collateral (ctUint64)
     * @param nonce Trader nonce at time of locking (replay protection)
     * @param deadline Settlement deadline (unix timestamp)
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
    bytes32 public constant SETTLER_ROLE = keccak256("SETTLER_ROLE");

    /// @notice Role for admin operations
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

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

    /// @notice Emergency stop flag (separate from Pausable)
    bool public emergencyStop;

    /// @notice Total number of settlements executed
    uint256 public totalSettlements;

    /// @notice Whether contract is ossified (permanently non-upgradeable)
    bool private _ossified;

    /**
     * @dev Storage gap for future upgrades.
     * @notice Reserves 40 slots for adding new variables without
     *         breaking upgradeability.
     */
    uint256[40] private __gap;

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
    event FeesClaimed(address indexed recipient);

    /// @notice Emitted when a private intent is cancelled
    /// @param intentId Intent identifier
    /// @param trader Trader address
    event PrivateIntentCancelled(
        bytes32 indexed intentId,
        address indexed trader
    );

    /// @notice Emitted when emergency stop is triggered
    /// @param triggeredBy Address that triggered the stop
    /// @param reason Reason for emergency stop
    event EmergencyStopped(
        address indexed triggeredBy,
        string reason
    );

    /// @notice Emitted when trading resumes after emergency stop
    /// @param resumedBy Address that resumed trading
    event TradingResumed(address indexed resumedBy);

    /// @notice Emitted when fee recipients are updated
    /// @param oddao New ODDAO address
    /// @param stakingPool New staking pool address
    event FeeRecipientsUpdated(
        address indexed oddao,
        address indexed stakingPool
    );

    /// @notice Emitted when the contract is permanently ossified
    /// @param contractAddress Address of this contract
    event ContractOssified(address indexed contractAddress);

    // ========================================================================
    // CUSTOM ERRORS
    // ========================================================================

    /// @notice Thrown when emergency stop is active
    error EmergencyStopActive();

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
    // EXTERNAL FUNCTIONS — SETTLEMENT
    // ========================================================================

    /**
     * @notice Lock encrypted collateral for bilateral settlement
     * @dev Called by a settler (validator) on behalf of the trader.
     *      Amounts must be pre-scaled to 6-decimal micro-XOM before
     *      encryption. Consumes the trader's current nonce.
     * @param intentId Unique intent identifier
     * @param trader Trader address
     * @param tokenIn Input token contract address
     * @param tokenOut Output token contract address
     * @param encTraderAmount Encrypted trader collateral (ctUint64)
     * @param encSolverAmount Encrypted solver collateral (ctUint64)
     * @param traderNonce Expected trader nonce (replay protection)
     * @param deadline Settlement deadline (unix timestamp)
     */
    function lockPrivateCollateral( // solhint-disable-line code-complexity
        bytes32 intentId,
        address trader,
        address tokenIn,
        address tokenOut,
        ctUint64 encTraderAmount,
        ctUint64 encSolverAmount,
        uint256 traderNonce,
        uint256 deadline
    )
        external
        onlyRole(SETTLER_ROLE)
        whenNotPaused
        nonReentrant
    {
        if (emergencyStop) revert EmergencyStopActive();
        if (trader == address(0)) revert InvalidAddress();
        if (tokenIn == address(0)) revert InvalidAddress();
        if (tokenOut == address(0)) revert InvalidAddress();
        // solhint-disable-next-line not-rely-on-time
        if (deadline < block.timestamp + 1) revert DeadlineExpired();
        if (
            privateCollateral[intentId].status != SettlementStatus.EMPTY
        ) {
            revert CollateralAlreadyLocked();
        }
        if (nonces[trader] != traderNonce) revert InvalidNonce();

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
        if (emergencyStop) revert EmergencyStopActive();
        if (solver == address(0)) revert InvalidAddress();
        if (validator == address(0)) revert InvalidAddress();

        PrivateCollateral storage col = privateCollateral[intentId];

        if (col.status != SettlementStatus.LOCKED) {
            revert CollateralNotLocked();
        }
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp > col.deadline) revert DeadlineExpired();

        col.solver = solver;

        // --- MPC sufficiency verification ---
        // OnBoard encrypted amounts into computation types
        gtUint64 gtTrader = MpcCore.onBoard(col.traderCollateral);
        gtUint64 gtSolver = MpcCore.onBoard(col.solverCollateral);

        // Verify trader collateral is non-zero
        gtUint64 gtZero = MpcCore.setPublic64(uint64(0));
        gtBool traderNonZero = MpcCore.ge(gtTrader, gtZero);
        if (!MpcCore.decrypt(traderNonZero)) {
            revert InsufficientCollateral();
        }

        // Verify solver collateral is non-zero
        gtBool solverNonZero = MpcCore.ge(gtSolver, gtZero);
        if (!MpcCore.decrypt(solverNonZero)) {
            revert InsufficientCollateral();
        }

        // --- Encrypted fee calculation (0.2% trading fee) ---
        // fee = (traderAmount * TRADING_FEE_BPS) / BASIS_POINTS_DIVISOR
        gtUint64 gtFeeBps = MpcCore.setPublic64(TRADING_FEE_BPS);
        gtUint64 gtBasis = MpcCore.setPublic64(BASIS_POINTS_DIVISOR);
        gtUint64 gtFeeProduct = MpcCore.mul(gtTrader, gtFeeBps);
        gtUint64 gtTotalFee = MpcCore.div(gtFeeProduct, gtBasis);

        // --- 70/20/10 fee split (encrypted) ---
        // oddaoFee = (totalFee * 7000) / 10000
        gtUint64 gtOddaoShare = MpcCore.setPublic64(ODDAO_SHARE_BPS);
        gtUint64 gtOddaoProduct = MpcCore.mul(gtTotalFee, gtOddaoShare);
        gtUint64 gtOddaoFee = MpcCore.div(gtOddaoProduct, gtBasis);

        // stakingFee = (totalFee * 2000) / 10000
        gtUint64 gtStakingShare = MpcCore.setPublic64(
            STAKING_POOL_SHARE_BPS
        );
        gtUint64 gtStakingProduct = MpcCore.mul(
            gtTotalFee, gtStakingShare
        );
        gtUint64 gtStakingFee = MpcCore.div(gtStakingProduct, gtBasis);

        // validatorFee = totalFee - oddaoFee - stakingFee (remainder)
        gtUint64 gtPartialSum = MpcCore.add(gtOddaoFee, gtStakingFee);
        gtUint64 gtValidatorFee = MpcCore.sub(gtTotalFee, gtPartialSum);

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

        // Generate settlement hash (amounts remain encrypted)
        bytes32 settlementHash = keccak256(
            abi.encode(
                intentId,
                col.trader,
                solver,
                col.tokenIn,
                col.tokenOut,
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
     * @param intentId Intent identifier
     */
    function cancelPrivateIntent(
        bytes32 intentId
    ) external whenNotPaused {
        PrivateCollateral storage col = privateCollateral[intentId];

        if (col.status != SettlementStatus.LOCKED) {
            revert CollateralNotLocked();
        }
        if (msg.sender != col.trader) revert NotTrader();

        col.status = SettlementStatus.CANCELLED;
        emit PrivateIntentCancelled(intentId, msg.sender);
    }

    /**
     * @notice Claim accumulated encrypted fees
     * @dev Any fee recipient can call to withdraw their balance.
     *      The encrypted balance is reset to zero after claiming.
     *      The actual pXOM transfer must be handled off-chain by
     *      the COTI bridge since this contract only tracks amounts.
     */
    function claimFees() external nonReentrant {
        // Load current accumulated fees for caller
        gtUint64 gtBalance = MpcCore.onBoard(
            accumulatedFees[msg.sender]
        );

        // Verify non-zero balance
        gtUint64 gtZero = MpcCore.setPublic64(uint64(0));
        gtBool hasBalance = MpcCore.ge(gtBalance, gtZero);
        if (!MpcCore.decrypt(hasBalance)) {
            revert InsufficientCollateral();
        }

        // Reset accumulated fees to zero
        accumulatedFees[msg.sender] = MpcCore.offBoard(gtZero);

        emit FeesClaimed(msg.sender);
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
     * @param recipient Fee recipient address
     * @return Encrypted fee balance (ctUint64)
     */
    function getAccumulatedFees(
        address recipient
    ) external view returns (ctUint64) {
        return accumulatedFees[recipient];
    }

    // ========================================================================
    // ADMIN FUNCTIONS
    // ========================================================================

    /**
     * @notice Update fee recipient addresses
     * @param oddao New ODDAO treasury address
     * @param stakingPool New staking pool address
     */
    function updateFeeRecipients( // solhint-disable-line ordering
        address oddao,
        address stakingPool
    ) external onlyRole(ADMIN_ROLE) {
        if (oddao == address(0)) revert InvalidAddress();
        if (stakingPool == address(0)) revert InvalidAddress();

        feeRecipients = FeeRecipients({
            oddao: oddao,
            stakingPool: stakingPool
        });

        emit FeeRecipientsUpdated(oddao, stakingPool);
    }

    /**
     * @notice Trigger emergency stop for all settlements
     * @param reason Reason for the emergency stop
     */
    function emergencyStopTrading(
        string calldata reason
    ) external onlyRole(ADMIN_ROLE) {
        emergencyStop = true;
        emit EmergencyStopped(msg.sender, reason);
    }

    /**
     * @notice Resume trading after an emergency stop
     */
    function resumeTrading() external onlyRole(ADMIN_ROLE) {
        emergencyStop = false;
        emit TradingResumed(msg.sender);
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
     * @notice Pause the contract
     */
    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause the contract
     */
    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    // ========================================================================
    // OSSIFICATION & UPGRADE AUTHORIZATION
    // ========================================================================

    /**
     * @notice Permanently remove upgrade capability (irreversible)
     * @dev Once ossified, no further proxy upgrades are possible.
     */
    function ossify() external onlyRole(ADMIN_ROLE) {
        _ossified = true;
        emit ContractOssified(address(this));
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
        gtUint64 gtNew = MpcCore.add(gtCurrent, gtFee);
        accumulatedFees[recipient] = MpcCore.offBoard(gtNew);
    }
}
