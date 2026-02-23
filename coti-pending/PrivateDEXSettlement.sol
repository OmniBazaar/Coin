// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

// TODO: Import MpcCore when deploying to COTI network
// import {MpcCore} from "../privacy/MpcCore.sol";

/**
 * @notice Placeholder for COTI encrypted uint64
 * @dev This will be replaced with actual ctUint64 from MpcCore when deployed to COTI
 */
type ctUint64 = bytes;

/**
 * @title PrivateDEXSettlement
 * @author OmniCoin Development Team
 * @notice Privacy-preserving bilateral settlement for intent-based trading using COTI MPC
 * @dev Handles encrypted collateral locking and atomic encrypted swaps
 *
 * Architecture:
 * 1. Trader locks encrypted collateral (input tokens)
 * 2. Solver locks encrypted collateral (output tokens)
 * 3. MPC verifies sufficiency without decryption (MpcCore.ge)
 * 4. Atomic encrypted transfer (MpcCore.transfer)
 * 5. Encrypted fee calculation (MpcCore.mul/div)
 * 6. Settlement recorded on Avalanche for finality
 *
 * Precision:
 * - All amounts scaled down by 10^12 (18-decimal wei → 6-decimal micro-XOM)
 * - Max representable: ~18.4 million XOM (sufficient for all practical trades)
 *
 * Privacy Guarantees:
 * - Trade amounts encrypted throughout
 * - Only authorized parties can decrypt
 * - MPC comparisons preserve privacy
 * - Settlement verifiable without revealing amounts
 */
contract PrivateDEXSettlement is Ownable, Pausable, ReentrancyGuard {
    // ========================================================================
    // CONSTANTS
    // ========================================================================

    /// @notice Basis points divisor (100%)
    uint256 public constant BASIS_POINTS_DIVISOR = 10000;

    /// @notice ODDAO fee share (70%)
    uint256 public constant ODDAO_SHARE = 7000;

    /// @notice Staking pool fee share (20%)
    uint256 public constant STAKING_POOL_SHARE = 2000;

    /// @notice Validator fee share (10%)
    uint256 public constant VALIDATOR_SHARE = 1000;

    /// @notice Trading fee in basis points (0.2%)
    uint256 public constant TRADING_FEE_BPS = 20;

    // ========================================================================
    // STRUCTS
    // ========================================================================

    /**
     * @notice Encrypted collateral record
     * @param trader Trader address
     * @param solver Solver address
     * @param traderCollateral Encrypted trader collateral (ctUint64)
     * @param solverCollateral Encrypted solver collateral (ctUint64)
     * @param deadline Settlement deadline
     * @param locked Whether collateral is locked
     * @param settled Whether settlement is complete
     */
    struct PrivateCollateral {
        address trader;
        address solver;
        ctUint64 traderCollateral;
        ctUint64 solverCollateral;
        uint256 deadline;
        bool locked;
        bool settled;
    }

    /**
     * @notice Fee distribution addresses
     * @param oddao Address of ODDAO treasury (receives 70%)
     * @param stakingPool Address of staking pool (receives 20%)
     */
    struct FeeRecipients {
        address oddao;
        address stakingPool;
    }

    // ========================================================================
    // STATE VARIABLES
    // ========================================================================

    /// @notice Mapping of intentId => encrypted collateral record
    mapping(bytes32 => PrivateCollateral) public privateCollateral;

    /// @notice Fee recipient addresses
    FeeRecipients public feeRecipients;

    /// @notice Emergency stop flag
    bool public emergencyStop;

    // ========================================================================
    // EVENTS
    // ========================================================================

    /**
     * @notice Emitted when private collateral is locked
     * @param intentId Intent identifier
     * @param trader Trader address
     * @param solver Solver address
     */
    event PrivateCollateralLocked(
        bytes32 indexed intentId,
        address indexed trader,
        address indexed solver
    );

    /**
     * @notice Emitted when private intent is settled
     * @param intentId Intent identifier
     * @param trader Trader address
     * @param solver Solver address
     * @param settlementHash Hash of settlement details (amounts hidden)
     */
    event PrivateIntentSettled(
        bytes32 indexed intentId,
        address indexed trader,
        address indexed solver,
        bytes32 settlementHash
    );

    /**
     * @notice Emitted when emergency stop is triggered
     * @param triggeredBy Address that triggered the stop
     * @param reason Reason for emergency stop
     */
    event EmergencyStop(address indexed triggeredBy, string reason);

    // ========================================================================
    // CUSTOM ERRORS
    // ========================================================================

    /// @notice Thrown when emergency stop is active
    error EmergencyStopActive();

    /// @notice Thrown when collateral already locked
    error CollateralAlreadyLocked();

    /// @notice Thrown when collateral not locked
    error CollateralNotLocked();

    /// @notice Thrown when settlement already complete
    error AlreadySettled();

    /// @notice Thrown when deadline has passed
    error DeadlineExpired();

    /// @notice Thrown when address is invalid
    error InvalidAddress();

    /// @notice Thrown when collateral insufficient
    error InsufficientCollateral();

    // ========================================================================
    // CONSTRUCTOR
    // ========================================================================

    /**
     * @notice Constructor to initialize the PrivateDEXSettlement contract
     * @param _oddao Address of ODDAO treasury (receives 70%)
     * @param _stakingPool Address of staking pool (receives 20%)
     */
    constructor(
        address _oddao,
        address _stakingPool
    ) Ownable(msg.sender) {
        if (_oddao == address(0) || _stakingPool == address(0)) {
            revert InvalidAddress();
        }

        feeRecipients = FeeRecipients({
            oddao: _oddao,
            stakingPool: _stakingPool
        });
    }

    // ========================================================================
    // EXTERNAL FUNCTIONS - SETTLEMENT
    // ========================================================================

    /**
     * @notice Lock encrypted collateral for bilateral settlement
     * @param intentId Intent identifier
     * @param encryptedTraderAmount Encrypted trader collateral (ctUint64)
     * @param encryptedSolverAmount Encrypted solver collateral (ctUint64)
     * @param deadline Settlement deadline timestamp
     * @dev Amounts must be scaled to 6-decimal micro-XOM before encryption
     */
    function lockPrivateCollateral(
        bytes32 intentId,
        ctUint64 encryptedTraderAmount,
        ctUint64 encryptedSolverAmount,
        uint256 deadline
    ) external whenNotPaused {
        if (privateCollateral[intentId].locked) revert CollateralAlreadyLocked();
        if (deadline <= block.timestamp) revert DeadlineExpired();

        privateCollateral[intentId] = PrivateCollateral({
            trader: msg.sender,
            solver: address(0), // Will be set during settlement
            traderCollateral: encryptedTraderAmount,
            solverCollateral: encryptedSolverAmount,
            deadline: deadline,
            locked: true,
            settled: false
        });

        emit PrivateCollateralLocked(intentId, msg.sender, address(0));
    }

    /**
     * @notice Settle private intent with encrypted bilateral swap
     * @param intentId Intent identifier
     * @param solver Solver address
     * @dev Uses MPC to verify and transfer encrypted amounts
     */
    function settlePrivateIntent(
        bytes32 intentId,
        address solver
    ) external nonReentrant whenNotPaused {
        if (emergencyStop) revert EmergencyStopActive();

        PrivateCollateral storage collateral = privateCollateral[intentId];

        if (!collateral.locked) revert CollateralNotLocked();
        if (collateral.settled) revert AlreadySettled();
        if (block.timestamp > collateral.deadline) revert DeadlineExpired();

        // Set solver
        collateral.solver = solver;

        // TODO: MPC encrypted transfers (Phase 5 full implementation)
        // This will use:
        // 1. gtUint64 gtTraderAmount = MpcCore.onBoard(collateral.traderCollateral);
        // 2. gtUint64 gtSolverAmount = MpcCore.onBoard(collateral.solverCollateral);
        // 3. Verify sufficiency: MpcCore.ge(gtTraderAmount, requiredAmount)
        // 4. Execute transfer: MpcCore.transfer(trader, solver, gtTraderAmount)
        // 5. Calculate fees: MpcCore.mul(amount, fee) / MpcCore.div(amount, divisor)
        // 6. Distribute fees to recipients (encrypted)

        // Mark as settled
        collateral.settled = true;

        // Generate settlement hash (amounts remain encrypted)
        bytes32 settlementHash = keccak256(
            abi.encode(intentId, collateral.trader, solver, block.timestamp)
        );

        emit PrivateIntentSettled(intentId, collateral.trader, solver, settlementHash);
    }

    /**
     * @notice Cancel private intent and release collateral
     * @param intentId Intent identifier
     * @dev Can only be called by trader
     */
    function cancelPrivateIntent(bytes32 intentId) external {
        PrivateCollateral storage collateral = privateCollateral[intentId];

        if (!collateral.locked) revert CollateralNotLocked();
        if (collateral.settled) revert AlreadySettled();
        if (msg.sender != collateral.trader) revert InvalidAddress();

        // Reset collateral
        collateral.locked = false;
    }

    // ========================================================================
    // VIEW FUNCTIONS
    // ========================================================================

    /**
     * @notice Get private collateral details
     * @param intentId Intent identifier
     * @return Collateral record (amounts encrypted)
     */
    function getPrivateCollateral(
        bytes32 intentId
    ) external view returns (PrivateCollateral memory) {
        return privateCollateral[intentId];
    }

    /**
     * @notice Get fee recipient addresses
     * @return FeeRecipients struct
     */
    function getFeeRecipients() external view returns (FeeRecipients memory) {
        return feeRecipients;
    }

    // ========================================================================
    // ADMIN FUNCTIONS
    // ========================================================================

    /**
     * @notice Update fee recipient addresses
     * @param _oddao New ODDAO address (receives 70%)
     * @param _stakingPool New staking pool address (receives 20%)
     */
    function updateFeeRecipients(
        address _oddao,
        address _stakingPool
    ) external onlyOwner {
        if (_oddao == address(0) || _stakingPool == address(0)) {
            revert InvalidAddress();
        }

        feeRecipients = FeeRecipients({
            oddao: _oddao,
            stakingPool: _stakingPool
        });
    }

    /**
     * @notice Trigger emergency stop for trading
     * @param reason Reason for emergency stop
     */
    function emergencyStopTrading(string calldata reason) external onlyOwner {
        emergencyStop = true;
        emit EmergencyStop(msg.sender, reason);
    }

    /**
     * @notice Resume trading after emergency stop
     */
    function resumeTrading() external onlyOwner {
        emergencyStop = false;
    }

    /**
     * @notice Pause contract
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause contract
     */
    function unpause() external onlyOwner {
        _unpause();
    }
}
