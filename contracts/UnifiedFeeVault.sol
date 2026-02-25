// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AccessControlUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from
    "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {PausableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from
    "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// ════════════════════════════════════════════════════════════════════════
//                          UNIFIED FEE VAULT
// ════════════════════════════════════════════════════════════════════════

/**
 * @title UnifiedFeeVault
 * @author OmniBazaar Team
 * @notice Aggregates protocol fees from all OmniBazaar markets and
 *         splits them according to the universal 70/20/10 schedule
 * @dev Single collection point for fees from MinimalEscrow,
 *      DEXSettlement, RWAAMM, RWAFeeCollector, OmniFeeRouter,
 *      OmniYieldFeeCollector, OmniPredictionRouter, and any future
 *      fee-generating contracts.
 *
 * Fee Distribution (per FIX_FEE_PAYMENTS.md):
 *   70% → ODDAO Treasury (held for periodic bridging to Optimism)
 *   20% → StakingRewardPool (on-chain, immediate transfer)
 *   10% → Protocol Treasury (on-chain, governance-controlled)
 *
 * Design Decisions:
 * - UUPS upgradeable: allows fee logic updates without redeployment
 * - Pausable: emergency stop capability for fee processing
 * - Multi-token: accepts XOM, USDC, or any ERC20 fee payments
 * - Permissionless distribute(): anyone can trigger the fee split
 * - Role-gated bridge: only BRIDGE_ROLE can withdraw ODDAO share
 * - Deposit whitelist: only approved fee contracts can deposit
 *
 * Safety:
 * - ReentrancyGuard on all state-changing external functions
 * - CEI pattern (checks-effects-interactions) throughout
 * - Zero-amount guards on all transfers
 * - Overflow-safe math via Solidity 0.8.x defaults
 * - Ossification support for permanent finalization
 * - UUPS upgrade restricted to DEFAULT_ADMIN_ROLE
 */
contract UnifiedFeeVault is
    AccessControlUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable
{
    using SafeERC20 for IERC20;

    // ════════════════════════════════════════════════════════════════════
    //                           CONSTANTS
    // ════════════════════════════════════════════════════════════════════

    /// @notice ODDAO share: 70% of all collected fees
    uint256 public constant ODDAO_BPS = 7000;

    /// @notice Staking pool share: 20% of all collected fees
    uint256 public constant STAKING_BPS = 2000;

    /// @notice Protocol treasury share: 10% of all collected fees
    uint256 public constant PROTOCOL_BPS = 1000;

    /// @notice Basis points denominator for percentage math
    uint256 public constant BPS_DENOMINATOR = 10000;

    /// @notice Role for addresses that can deposit fees
    bytes32 public constant DEPOSITOR_ROLE = keccak256("DEPOSITOR_ROLE");

    /// @notice Role for addresses that can bridge ODDAO funds
    bytes32 public constant BRIDGE_ROLE = keccak256("BRIDGE_ROLE");

    /// @notice Role for administrative operations
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    // ════════════════════════════════════════════════════════════════════
    //                         STATE VARIABLES
    // ════════════════════════════════════════════════════════════════════

    /// @notice StakingRewardPool address (receives 20%)
    address public stakingPool;

    /// @notice Protocol treasury address (receives 10%)
    address public protocolTreasury;

    /// @notice ODDAO share per token, awaiting bridge to Optimism
    /// @dev token address => accumulated amount
    mapping(address => uint256) public pendingBridge;

    /// @notice Lifetime fees distributed per token (for transparency)
    /// @dev token address => total distributed amount
    mapping(address => uint256) public totalDistributed;

    /// @notice Lifetime fees bridged per token (for transparency)
    /// @dev token address => total bridged amount
    mapping(address => uint256) public totalBridged;

    /// @notice Whether the contract has been permanently ossified
    /// @dev Once true, no further upgrades are possible
    bool private _ossified;

    /// @notice Storage gap for future upgrades (47 slots reserved)
    uint256[47] private __gap;

    // ════════════════════════════════════════════════════════════════════
    //                             EVENTS
    // ════════════════════════════════════════════════════════════════════

    /// @notice Emitted when fees are deposited into the vault
    /// @param token ERC20 token address that was deposited
    /// @param amount Amount of tokens deposited
    /// @param depositor Address that deposited the fees
    event FeesDeposited(
        address indexed token,
        uint256 indexed amount,
        address indexed depositor
    );

    /// @notice Emitted when accumulated fees are split 70/20/10
    /// @param token ERC20 token address that was distributed
    /// @param oddaoShare Amount sent to ODDAO holding (70%)
    /// @param stakingShare Amount sent to StakingRewardPool (20%)
    event FeesDistributed(
        address indexed token,
        uint256 indexed oddaoShare,
        uint256 indexed stakingShare
    );

    /// @notice Emitted when ODDAO funds are bridged to Optimism
    /// @param token ERC20 token address that was bridged
    /// @param amount Amount bridged
    /// @param recipient Bridge receiver address
    event FeesBridged(
        address indexed token,
        uint256 indexed amount,
        address indexed recipient
    );

    /// @notice Emitted when recipient addresses are updated
    /// @param stakingPool New staking pool address
    /// @param protocolTreasury New protocol treasury address
    event RecipientsUpdated(
        address indexed stakingPool,
        address indexed protocolTreasury
    );

    /// @notice Emitted when the contract is permanently ossified
    /// @param caller Address that triggered ossification
    event ContractOssified(address indexed caller);

    // ════════════════════════════════════════════════════════════════════
    //                          CUSTOM ERRORS
    // ════════════════════════════════════════════════════════════════════

    /// @notice Thrown when a zero address is provided
    error ZeroAddress();

    /// @notice Thrown when a zero amount is provided
    error ZeroAmount();

    /// @notice Thrown when there is nothing to distribute
    error NothingToDistribute();

    /// @notice Thrown when bridge amount exceeds pending balance
    /// @param requested Amount requested for bridging
    /// @param available Amount available for bridging
    error InsufficientPendingBalance(
        uint256 requested,
        uint256 available
    );

    /// @notice Thrown when the contract is ossified and upgrades are blocked
    error ContractIsOssified();

    // ════════════════════════════════════════════════════════════════════
    //                      CONSTRUCTOR & INITIALIZER
    // ════════════════════════════════════════════════════════════════════

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the UnifiedFeeVault proxy
     * @dev Called once during proxy deployment. Sets up roles and
     *      recipient addresses for the 70/20/10 split.
     * @param admin Address granted DEFAULT_ADMIN_ROLE and ADMIN_ROLE
     * @param _stakingPool StakingRewardPool contract address (20%)
     * @param _protocolTreasury Protocol treasury address (10%)
     */
    function initialize(
        address admin,
        address _stakingPool,
        address _protocolTreasury
    ) external initializer {
        if (admin == address(0)) revert ZeroAddress();
        if (_stakingPool == address(0)) revert ZeroAddress();
        if (_protocolTreasury == address(0)) revert ZeroAddress();

        __AccessControl_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);
        _grantRole(BRIDGE_ROLE, admin);

        stakingPool = _stakingPool;
        protocolTreasury = _protocolTreasury;
    }

    // ════════════════════════════════════════════════════════════════════
    //                        EXTERNAL FUNCTIONS
    // ════════════════════════════════════════════════════════════════════

    /**
     * @notice Deposit fees into the vault from an approved fee contract
     * @dev Only addresses with DEPOSITOR_ROLE can call this. The caller
     *      must have approved this contract for the deposit amount.
     * @param token ERC20 token address to deposit
     * @param amount Amount of tokens to deposit
     */
    function deposit(
        address token,
        uint256 amount
    ) external onlyRole(DEPOSITOR_ROLE) nonReentrant whenNotPaused {
        if (token == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        emit FeesDeposited(token, amount, msg.sender);
    }

    /**
     * @notice Split accumulated fees for a token using 70/20/10
     * @dev Permissionless: anyone can trigger distribution. This
     *      encourages timely fee processing without relying on
     *      a centralized caller.
     *
     *      The 70% ODDAO share stays in the vault, tracked in
     *      pendingBridge[token], until bridgeToTreasury() is called.
     *
     *      The 20% and 10% shares are transferred immediately to
     *      stakingPool and protocolTreasury respectively.
     * @param token ERC20 token address to distribute
     */
    function distribute(
        address token
    ) external nonReentrant whenNotPaused {
        if (token == address(0)) revert ZeroAddress();

        uint256 balance = IERC20(token).balanceOf(address(this));
        uint256 distributable = balance - pendingBridge[token];

        if (distributable == 0) revert NothingToDistribute();

        // Calculate shares
        uint256 oddaoShare =
            (distributable * ODDAO_BPS) / BPS_DENOMINATOR;
        uint256 stakingShare =
            (distributable * STAKING_BPS) / BPS_DENOMINATOR;
        // Protocol gets remainder to avoid rounding dust loss
        uint256 protocolShare =
            distributable - oddaoShare - stakingShare;

        // Effects: update state before transfers (CEI)
        pendingBridge[token] += oddaoShare;
        totalDistributed[token] += distributable;

        // Interactions: transfer staking and protocol shares
        if (stakingShare > 0) {
            IERC20(token).safeTransfer(stakingPool, stakingShare);
        }
        if (protocolShare > 0) {
            IERC20(token).safeTransfer(
                protocolTreasury, protocolShare
            );
        }

        emit FeesDistributed(token, oddaoShare, stakingShare);
    }

    /**
     * @notice Bridge accumulated ODDAO share to Optimism treasury
     * @dev Only BRIDGE_ROLE can call. Transfers tokens to a bridge
     *      receiver address (bridge contract or direct recipient).
     *      The bridge operator is responsible for completing the
     *      cross-chain transfer.
     * @param token ERC20 token to bridge
     * @param amount Amount to bridge (must be <= pendingBridge)
     * @param bridgeReceiver Address to send tokens to
     */
    function bridgeToTreasury(
        address token,
        uint256 amount,
        address bridgeReceiver
    ) external onlyRole(BRIDGE_ROLE) nonReentrant whenNotPaused {
        if (token == address(0)) revert ZeroAddress();
        if (bridgeReceiver == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        uint256 pending = pendingBridge[token];
        if (amount > pending) {
            revert InsufficientPendingBalance(amount, pending);
        }

        // Effects first (CEI)
        pendingBridge[token] -= amount;
        totalBridged[token] += amount;

        // Interaction
        IERC20(token).safeTransfer(bridgeReceiver, amount);

        emit FeesBridged(token, amount, bridgeReceiver);
    }

    // ════════════════════════════════════════════════════════════════════
    //                         ADMIN FUNCTIONS
    // ════════════════════════════════════════════════════════════════════

    /**
     * @notice Update the staking pool and protocol treasury addresses
     * @dev Only callable by ADMIN_ROLE. Use when these contracts are
     *      redeployed or upgraded to new addresses.
     * @param _stakingPool New StakingRewardPool address
     * @param _protocolTreasury New protocol treasury address
     */
    function setRecipients(
        address _stakingPool,
        address _protocolTreasury
    ) external onlyRole(ADMIN_ROLE) {
        if (_stakingPool == address(0)) revert ZeroAddress();
        if (_protocolTreasury == address(0)) revert ZeroAddress();

        stakingPool = _stakingPool;
        protocolTreasury = _protocolTreasury;

        emit RecipientsUpdated(_stakingPool, _protocolTreasury);
    }

    /**
     * @notice Pause the contract in case of emergency
     * @dev Blocks deposit, distribute, and bridgeToTreasury
     */
    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause the contract after emergency resolution
     */
    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    /**
     * @notice Permanently freeze the contract against upgrades
     * @dev Cannot be undone. Use only when the fee vault logic
     *      has been battle-tested and no further changes are needed.
     */
    function ossify() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _ossified = true;
        emit ContractOssified(msg.sender);
    }

    // ════════════════════════════════════════════════════════════════════
    //                          VIEW FUNCTIONS
    // ════════════════════════════════════════════════════════════════════

    /**
     * @notice Get the undistributed balance for a token
     * @dev This is the amount available for the next distribute() call.
     *      Equals the vault's token balance minus the ODDAO share
     *      that has already been split but not yet bridged.
     * @param token ERC20 token address to query
     * @return Undistributed token balance
     */
    function undistributed(address token) external view returns (uint256) {
        uint256 balance = IERC20(token).balanceOf(address(this));
        uint256 pending = pendingBridge[token];
        if (balance < pending) return 0;
        return balance - pending;
    }

    /**
     * @notice Get the pending ODDAO bridge amount for a token
     * @param token ERC20 token address to query
     * @return Amount awaiting bridging to Optimism
     */
    function pendingForBridge(
        address token
    ) external view returns (uint256) {
        return pendingBridge[token];
    }

    /**
     * @notice Check whether the contract has been ossified
     * @return True if no further upgrades are possible
     */
    function isOssified() external view returns (bool) {
        return _ossified;
    }

    // ════════════════════════════════════════════════════════════════════
    //                       INTERNAL FUNCTIONS
    // ════════════════════════════════════════════════════════════════════

    /**
     * @notice Authorize a UUPS upgrade
     * @dev Restricted to DEFAULT_ADMIN_ROLE and blocked when ossified
     * @param newImplementation Address of the new implementation
     */
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_ossified) revert ContractIsOssified();
        (newImplementation); // silence unused variable warning
    }
}
