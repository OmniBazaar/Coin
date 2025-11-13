// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title IPrivateOmniCoin
 * @author OmniCoin Development Team
 * @notice Interface for PrivateOmniCoin contract interactions
 */
interface IPrivateOmniCoin is IERC20 {
    /**
     * @notice Mint new pXOM tokens
     * @param to Address to mint tokens to
     * @param amount Amount to mint
     */
    function mint(address to, uint256 amount) external;

    /**
     * @notice Burn pXOM tokens from an address
     * @param from Address to burn from
     * @param amount Amount to burn
     */
    function burnFrom(address from, uint256 amount) external;

    /**
     * @notice Check if privacy features are available
     * @return available Whether privacy is available
     */
    function privacyAvailable() external view returns (bool available);
}

/**
 * @title OmniPrivacyBridge
 * @author OmniCoin Development Team
 * @notice Bridge contract for converting between public XOM and private pXOM tokens
 * @dev Facilitates secure conversions with fee management and safety limits
 *
 * Architecture:
 * - XOM → pXOM: Locks XOM, mints private pXOM balance (0.3% fee)
 * - pXOM → XOM: Burns private pXOM balance, releases XOM (no fee)
 *
 * Security Features:
 * - Pausable for emergency stops
 * - Conversion limits to prevent large manipulations
 * - Reentrancy protection
 * - Role-based access control
 * - Slippage protection for fee calculations
 * - Upgradeable via UUPS proxy pattern
 */
contract OmniPrivacyBridge is
    Initializable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    // ========================================================================
    // CONSTANTS
    // ========================================================================

    /// @notice Role identifier for operators who can pause/unpause
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    /// @notice Role identifier for fee management
    bytes32 public constant FEE_MANAGER_ROLE = keccak256("FEE_MANAGER_ROLE");

    /// @notice Maximum single conversion amount (18.4 ether due to uint64 limit in MPC)
    uint256 public constant MAX_CONVERSION_AMOUNT = type(uint64).max;

    /// @notice Privacy conversion fee in basis points (30 = 0.3%)
    uint16 public constant PRIVACY_FEE_BPS = 30;

    /// @notice Basis points denominator (10000 = 100%)
    uint16 public constant BPS_DENOMINATOR = 10000;

    /// @notice Minimum conversion amount to prevent dust attacks
    uint256 public constant MIN_CONVERSION_AMOUNT = 1e15; // 0.001 tokens

    // ========================================================================
    // STATE VARIABLES
    // ========================================================================

    /// @notice Address of the public OmniCoin (XOM) token
    /// @dev No longer immutable for upgradeability, initialized in initialize()
    IERC20 public omniCoin;

    /// @notice Address of the private PrivateOmniCoin (pXOM) token
    /// @dev No longer immutable for upgradeability, initialized in initialize()
    IPrivateOmniCoin public privateOmniCoin;

    /// @notice Maximum allowed conversion per transaction (adjustable by admin)
    uint256 public maxConversionLimit;

    /// @notice Total amount of XOM locked in bridge
    uint256 public totalLocked;

    /// @notice Total conversions to private (cumulative metric)
    uint256 public totalConvertedToPrivate;

    /// @notice Total conversions to public (cumulative metric)
    uint256 public totalConvertedToPublic;

    /**
     * @dev Storage gap for future upgrades
     * @notice Reserves storage slots to allow adding new variables in upgrades
     * Current storage: 6 variables (OMNI_COIN, PRIVATE_OMNI_COIN, maxConversionLimit,
     * totalLocked, totalConvertedToPrivate, totalConvertedToPublic)
     * Gap size: 50 - 6 = 44 slots reserved
     */
    uint256[44] private __gap;

    // ========================================================================
    // EVENTS
    // ========================================================================

    /// @notice Emitted when XOM is converted to pXOM
    /// @param user Address performing the conversion
    /// @param amountIn Amount of XOM provided
    /// @param amountOut Amount of pXOM credited (after fee)
    /// @param fee Fee charged for conversion
    event ConvertedToPrivate(
        address indexed user,
        uint256 indexed amountIn,
        uint256 indexed amountOut,
        uint256 fee
    );

    /// @notice Emitted when pXOM is converted to XOM
    /// @param user Address performing the conversion
    /// @param amountOut Amount of XOM released
    event ConvertedToPublic(address indexed user, uint256 indexed amountOut);

    /// @notice Emitted when max conversion limit is updated
    /// @param oldLimit Previous limit
    /// @param newLimit New limit
    event MaxConversionLimitUpdated(uint256 indexed oldLimit, uint256 indexed newLimit);

    /// @notice Emitted when emergency withdrawal is performed
    /// @param token Address of token withdrawn
    /// @param to Recipient address
    /// @param amount Amount withdrawn
    event EmergencyWithdrawal(address indexed token, address indexed to, uint256 indexed amount);

    // ========================================================================
    // CUSTOM ERRORS
    // ========================================================================

    /// @notice Thrown when amount is zero
    error ZeroAmount();

    /// @notice Thrown when amount is below minimum
    error BelowMinimum();

    /// @notice Thrown when amount exceeds maximum
    error ExceedsMaximum();

    /// @notice Thrown when amount exceeds uint64 limit for MPC
    error AmountTooLarge();

    /// @notice Thrown when insufficient locked funds for release
    error InsufficientLockedFunds();

    /// @notice Thrown when privacy features are not available
    error PrivacyNotAvailable();

    /// @notice Thrown when address is zero
    error ZeroAddress();

    /// @notice Thrown when conversion would exceed configured limit
    error ExceedsConversionLimit();

    // ========================================================================
    // CONSTRUCTOR & INITIALIZATION
    // ========================================================================

    /**
     * @notice Constructor for OmniPrivacyBridge (upgradeable pattern)
     * @dev Disables initializers to prevent implementation contract from being initialized
     * @custom:oz-upgrades-unsafe-allow constructor
     */
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize OmniPrivacyBridge (replaces constructor)
     * @dev Initializes all inherited contracts and sets up token addresses and roles
     * @param _omniCoin Address of OmniCoin (XOM) token contract
     * @param _privateOmniCoin Address of PrivateOmniCoin (pXOM) token contract
     */
    function initialize(address _omniCoin, address _privateOmniCoin) external initializer {
        if (_omniCoin == address(0) || _privateOmniCoin == address(0)) {
            revert ZeroAddress();
        }

        // Initialize all inherited contracts
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        // Set token addresses (no longer immutable)
        omniCoin = IERC20(_omniCoin);
        privateOmniCoin = IPrivateOmniCoin(_privateOmniCoin);

        // Set initial max conversion limit (10 million tokens)
        maxConversionLimit = 10_000_000 * 1e18;

        // Grant roles to deployer
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);
        _grantRole(FEE_MANAGER_ROLE, msg.sender);
    }

    // ========================================================================
    // CONVERSION FUNCTIONS
    // ========================================================================

    /**
     * @notice Convert public XOM to public pXOM
     * @dev User must approve bridge contract before calling. Charges 0.3% fee.
     *      User can then call PrivateOmniCoin.convertToPrivate() to make pXOM private.
     * @param amount Amount of XOM to convert (must fit in uint64)
     */
    function convertXOMtoPXOM(uint256 amount) external nonReentrant whenNotPaused {
        // Input validation
        if (amount == 0) revert ZeroAmount();
        if (amount < MIN_CONVERSION_AMOUNT) revert BelowMinimum();
        if (amount > MAX_CONVERSION_AMOUNT) revert AmountTooLarge();
        if (amount > maxConversionLimit) revert ExceedsConversionLimit();

        // Calculate fee and amount after fee
        uint256 fee = (amount * PRIVACY_FEE_BPS) / BPS_DENOMINATOR;
        uint256 amountAfterFee = amount - fee;

        // Transfer XOM from user to bridge (locks tokens)
        omniCoin.safeTransferFrom(msg.sender, address(this), amount);

        // Update tracking
        totalLocked += amount;
        totalConvertedToPrivate += amount;

        // Mint public pXOM to user (requires bridge to have MINTER_ROLE on PrivateOmniCoin)
        // User can then call PrivateOmniCoin.convertToPrivate() to convert to encrypted balance
        privateOmniCoin.mint(msg.sender, amountAfterFee);

        emit ConvertedToPrivate(msg.sender, amount, amountAfterFee, fee);
    }

    /**
     * @notice Convert public pXOM back to public XOM
     * @dev No fee charged for this direction. User must approve bridge to spend pXOM.
     *      If user has encrypted pXOM balance, they must first call PrivateOmniCoin.convertToPublic().
     * @param amount Amount of pXOM to convert
     */
    function convertPXOMtoXOM(uint256 amount) external nonReentrant whenNotPaused {
        // Input validation
        if (amount == 0) revert ZeroAmount();
        if (amount < MIN_CONVERSION_AMOUNT) revert BelowMinimum();
        if (amount > MAX_CONVERSION_AMOUNT) revert AmountTooLarge();

        // Check if we have enough locked XOM to release
        if (amount > totalLocked) revert InsufficientLockedFunds();

        // Burn pXOM from user (requires bridge to have BURNER_ROLE or user approval)
        privateOmniCoin.burnFrom(msg.sender, amount);

        // Update tracking
        totalLocked -= amount;
        totalConvertedToPublic += amount;

        // Transfer XOM tokens to the user
        omniCoin.safeTransfer(msg.sender, amount);

        emit ConvertedToPublic(msg.sender, amount);
    }

    // ========================================================================
    // ADMIN FUNCTIONS
    // ========================================================================

    /**
     * @notice Update maximum single conversion limit
     * @dev Only admin can update
     * @param newLimit New maximum conversion amount
     */
    function setMaxConversionLimit(uint256 newLimit) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newLimit == 0) revert ZeroAmount();
        if (newLimit > MAX_CONVERSION_AMOUNT) revert ExceedsMaximum();

        uint256 oldLimit = maxConversionLimit;
        maxConversionLimit = newLimit;

        emit MaxConversionLimitUpdated(oldLimit, newLimit);
    }

    /**
     * @notice Pause all conversions
     * @dev Only operator can pause
     */
    function pause() external onlyRole(OPERATOR_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause conversions
     * @dev Only operator can unpause
     */
    function unpause() external onlyRole(OPERATOR_ROLE) {
        _unpause();
    }

    /**
     * @notice Emergency withdrawal of tokens
     * @dev Only admin can withdraw. Use only in emergency situations.
     * @param token Address of token to withdraw
     * @param to Recipient address
     * @param amount Amount to withdraw
     */
    function emergencyWithdraw(
        address token,
        address to,
        uint256 amount
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        IERC20(token).safeTransfer(to, amount);

        emit EmergencyWithdrawal(token, to, amount);
    }

    // ========================================================================
    // UUPS UPGRADE AUTHORIZATION
    // ========================================================================

    /**
     * @notice Authorize contract upgrades (UUPS pattern)
     * @dev Only admin can authorize upgrades to new implementation
     * @param newImplementation Address of new implementation contract
     */
    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        // Authorization check handled by onlyRole modifier
        // newImplementation parameter required by UUPS but not used in authorization logic
    }

    // ========================================================================
    // VIEW FUNCTIONS
    // ========================================================================

    /**
     * @notice Get bridge statistics
     * @return _totalLocked Current amount of XOM locked
     * @return _totalConvertedToPrivate Cumulative conversions to private
     * @return _totalConvertedToPublic Cumulative conversions to public
     */
    function getBridgeStats()
        external
        view
        returns (
            uint256 _totalLocked,
            uint256 _totalConvertedToPrivate,
            uint256 _totalConvertedToPublic
        )
    {
        return (totalLocked, totalConvertedToPrivate, totalConvertedToPublic);
    }

    /**
     * @notice Get conversion rate (always 1:1, but fees apply)
     * @dev Fee is 0.3% for XOM → pXOM, 0% for pXOM → XOM
     * @return rate Conversion rate (always 1e18 for 1:1)
     */
    function getConversionRate() external pure returns (uint256 rate) {
        return 1e18; // 1:1 conversion rate
    }

    /**
     * @notice Calculate exact output amount for XOM → pXOM conversion
     * @param amountIn Amount of XOM to convert
     * @return amountOut Amount of pXOM received (after 0.3% fee)
     * @return fee Fee charged
     */
    function previewConvertToPrivate(uint256 amountIn)
        external
        pure
        returns (uint256 amountOut, uint256 fee)
    {
        fee = (amountIn * PRIVACY_FEE_BPS) / BPS_DENOMINATOR;
        amountOut = amountIn - fee;
    }

    /**
     * @notice Calculate exact output amount for pXOM → XOM conversion
     * @param amountIn Amount of pXOM to convert
     * @return amountOut Amount of XOM received (no fee)
     */
    function previewConvertToPublic(uint256 amountIn) external pure returns (uint256 amountOut) {
        return amountIn; // No fee for this direction
    }
}
