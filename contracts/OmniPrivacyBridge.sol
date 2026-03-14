// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC2771ContextUpgradeable} from
    "@openzeppelin/contracts-upgradeable/metatx/ERC2771ContextUpgradeable.sol";
import {ContextUpgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";

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
 * @dev Facilitates secure conversions with fee management and safety limits.
 *
 * Privacy Fee: 0.5% (50 basis points) charged on XOM -> pXOM conversions only.
 * This fee is the sole fee point for privacy operations. PrivateOmniCoin does
 * NOT charge a separate fee. After bridging, users can call
 * PrivateOmniCoin.convertToPrivate() to encrypt their pXOM balance using
 * COTI V2's MPC (Multi-Party Computation) garbled circuits for on-chain privacy.
 *
 * Architecture:
 * - XOM -> pXOM: Locks XOM, mints public pXOM (0.5% fee). User then
 *   optionally calls PrivateOmniCoin.convertToPrivate() for MPC encryption.
 * - pXOM -> XOM: Burns public pXOM, releases XOM (no fee). User must first
 *   call PrivateOmniCoin.convertToPublic() if pXOM is encrypted.
 *
 * COTI Integration:
 * - COTI V2 provides confidential token balances via MPC garbled circuits
 * - The bridge operates on PUBLIC pXOM (ERC20 layer), not encrypted balances
 * - Privacy (encryption) is handled by PrivateOmniCoin, not this bridge
 * - Bridge works regardless of MPC availability status
 *
 * Security Features:
 * - Pausable for emergency stops
 * - Per-transaction conversion limits (configurable)
 * - Daily volume limits (calendar-day boundaries, configurable)
 * - Reentrancy protection on all conversion functions
 * - Dual-role access control: OPERATOR_ROLE for routine operations
 *   (pause, unpause, limit adjustments), DEFAULT_ADMIN_ROLE for
 *   critical functions (emergency withdraw, fee withdrawal, ossify)
 * - Solvency tracking: totalLocked == sum of outstanding bridge-minted pXOM
 * - bridgeMintedPXOM prevents genesis pXOM from draining bridge reserves
 * - Upgradeable via UUPS proxy pattern with ossification capability
 */
contract OmniPrivacyBridge is
    Initializable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable,
    ERC2771ContextUpgradeable
{
    using SafeERC20 for IERC20;

    // ========================================================================
    // CONSTANTS
    // ========================================================================

    /// @notice Privacy conversion fee in basis points (50 = 0.5%)
    uint16 public constant PRIVACY_FEE_BPS = 50;

    /// @notice Basis points denominator (10000 = 100%)
    uint16 public constant BPS_DENOMINATOR = 10000;

    /// @notice Minimum conversion amount to prevent dust attacks
    uint256 public constant MIN_CONVERSION_AMOUNT = 1e15; // 0.001 tokens

    /// @notice Role for routine operational functions (pause, parameter tuning)
    /// @dev M-01 audit fix: separates routine operations from critical admin
    ///      functions (emergency withdraw, ossification) to reduce single-key
    ///      risk. OPERATOR_ROLE holders can adjust limits and pause/unpause,
    ///      while DEFAULT_ADMIN_ROLE is reserved for critical operations.
    bytes32 public constant OPERATOR_ROLE =
        keccak256("OPERATOR_ROLE");

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

    /// @notice Total pXOM minted through this bridge (excludes genesis supply)
    uint256 public bridgeMintedPXOM;

    /// @notice Total accumulated conversion fees available for withdrawal
    uint256 public totalFeesCollected;

    /// @notice Maximum total conversion volume allowed per day (0 = unlimited)
    uint256 public dailyVolumeLimit;

    /// @notice Cumulative conversion volume in the current day
    uint256 public currentDayVolume;

    /// @notice Timestamp of the start of the current daily period
    uint256 public currentDayStart;

    /// @notice Whether contract is ossified (permanently non-upgradeable)
    bool private _ossified;

    /// @notice Delay required between requesting and executing ossification
    uint256 public constant OSSIFICATION_DELAY = 48 hours;

    /// @notice Timestamp when ossification was requested (0 = not requested)
    uint256 public ossificationRequestedAt;

    /**
     * @dev Storage gap for future upgrades
     * @notice Reserves storage slots to allow adding new variables
     *         in upgrades. Current storage: 13 variables (omniCoin,
     *         privateOmniCoin, maxConversionLimit, totalLocked,
     *         totalConvertedToPrivate, totalConvertedToPublic,
     *         bridgeMintedPXOM, totalFeesCollected, dailyVolumeLimit,
     *         currentDayVolume, currentDayStart, _ossified,
     *         ossificationRequestedAt)
     *         Pre-mainnet: gap set to 50 for ample future upgrade room.
     *         Reduce gap by N when adding N new state variables.
     */
    uint256[50] private __gap;

    // ========================================================================
    // EVENTS
    // ========================================================================

    /// @notice Emitted when XOM is converted to pXOM
    /// @dev Amount details intentionally omitted to protect user privacy.
    ///      Bridge volume can be tracked via totalConvertedToPrivate state variable.
    /// @param user Address performing the conversion
    event ConvertedToPrivate(address indexed user);

    /// @notice Emitted when pXOM is converted to XOM
    /// @dev Amount details intentionally omitted to protect user privacy.
    ///      Bridge volume can be tracked via totalConvertedToPublic state variable.
    /// @param user Address performing the conversion
    event ConvertedToPublic(address indexed user);

    /// @notice Emitted when max conversion limit is updated
    /// @param oldLimit Previous limit
    /// @param newLimit New limit
    event MaxConversionLimitUpdated(uint256 oldLimit, uint256 newLimit);

    /// @notice Emitted when emergency withdrawal is performed
    /// @param token Address of token withdrawn
    /// @param to Recipient address
    /// @param amount Amount withdrawn
    event EmergencyWithdrawal(
        address indexed token,
        address indexed to,
        uint256 amount
    );

    /// @notice Emitted when accumulated fees are withdrawn
    /// @param recipient Address receiving the fees
    /// @param amount Amount of fees withdrawn
    event FeesWithdrawn(
        address indexed recipient,
        uint256 amount
    );

    /// @notice Emitted when daily volume limit is updated
    /// @param oldLimit Previous daily limit
    /// @param newLimit New daily limit (0 = unlimited)
    event DailyVolumeLimitUpdated(
        uint256 oldLimit,
        uint256 newLimit
    );

    /// @notice Emitted when the contract is permanently ossified
    /// @param contractAddress Address of this contract
    event ContractOssified(address indexed contractAddress);

    /// @notice Emitted when ossification is requested (starts delay)
    /// @param requestedAt Timestamp when ossification was requested
    event OssificationRequested(uint256 indexed requestedAt);

    /// @notice Emitted when ossification is executed after delay
    /// @param executedAt Timestamp when ossification was executed
    event OssificationExecuted(uint256 indexed executedAt);

    // ========================================================================
    // CUSTOM ERRORS
    // ========================================================================

    /// @notice Thrown when amount is zero
    error ZeroAmount();

    /// @notice Thrown when amount is below minimum
    error BelowMinimum();

    /// @notice Thrown when insufficient locked funds for release
    error InsufficientLockedFunds();

    /// @notice Thrown when privacy features are not available
    error PrivacyNotAvailable();

    /// @notice Thrown when address is zero
    error ZeroAddress();

    /// @notice Thrown when conversion would exceed configured limit
    error ExceedsConversionLimit();

    /// @notice Thrown when daily volume limit would be exceeded
    error DailyVolumeLimitExceeded();

    /// @notice Thrown when contract is ossified and upgrade attempted
    error ContractIsOssified();

    /// @notice Thrown when ossification has not been requested
    error OssificationNotRequested();

    /// @notice Thrown when ossification delay has not elapsed
    error OssificationDelayNotMet();

    /// @notice Thrown when ossification has already been requested
    error OssificationAlreadyRequested();

    // ========================================================================
    // CONSTRUCTOR & INITIALIZATION
    // ========================================================================

    /**
     * @notice Constructor for OmniPrivacyBridge (upgradeable pattern)
     * @dev Disables initializers to prevent implementation contract from being initialized.
     *      The trustedForwarder_ address is stored as an immutable by
     *      ERC2771ContextUpgradeable for meta-transaction support.
     * @param trustedForwarder_ Address of the ERC-2771 trusted forwarder
     *        for meta-transaction support (e.g., OmniForwarder)
     * @custom:oz-upgrades-unsafe-allow constructor
     */
    constructor(
        address trustedForwarder_
    ) ERC2771ContextUpgradeable(trustedForwarder_) {
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

        // Set initial daily volume limit (50 million tokens per day)
        dailyVolumeLimit = 50_000_000 * 1e18;
        // solhint-disable-next-line not-rely-on-time
        currentDayStart = block.timestamp;

        // Grant roles to deployer
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);
    }

    // ========================================================================
    // CONVERSION FUNCTIONS
    // ========================================================================

    /**
     * @notice Convert public XOM to public pXOM
     * @dev User must approve bridge contract before calling.
     *      Charges 0.5% fee. User can then call
     *      PrivateOmniCoin.convertToPrivate() to make pXOM private.
     *      Fee XOM is held separately and withdrawable by admin.
     * @param amount Amount of XOM to convert
     */
    function convertXOMtoPXOM(
        uint256 amount
    ) external nonReentrant whenNotPaused {
        address caller = _msgSender();

        // Input validation
        if (amount == 0) revert ZeroAmount();
        if (amount < MIN_CONVERSION_AMOUNT) revert BelowMinimum();
        if (amount > maxConversionLimit) revert ExceedsConversionLimit();

        // Enforce daily volume limit
        _checkAndUpdateDailyVolume(amount);

        // Calculate fee and amount after fee
        uint256 fee =
            (amount * PRIVACY_FEE_BPS) / BPS_DENOMINATOR;
        uint256 amountAfterFee = amount - fee;

        // Transfer XOM from user to bridge (locks tokens)
        omniCoin.safeTransferFrom(
            caller, address(this), amount
        );

        // Update tracking: only lock the backed amount, track fees separately
        totalLocked += amountAfterFee;
        totalFeesCollected += fee;
        totalConvertedToPrivate += amount;

        // Mint public pXOM to user (bridge needs MINTER_ROLE on pXOM)
        privateOmniCoin.mint(caller, amountAfterFee);

        // Track bridge-minted pXOM (excludes genesis supply)
        bridgeMintedPXOM += amountAfterFee;

        emit ConvertedToPrivate(caller);
    }

    /**
     * @notice Convert public pXOM back to public XOM
     * @dev No fee charged for this direction. User must approve
     *      bridge to spend pXOM. If user has encrypted pXOM
     *      balance, they must first call
     *      PrivateOmniCoin.convertToPublic(). Only bridge-minted
     *      pXOM can be redeemed (not genesis supply).
     * @param amount Amount of pXOM to convert
     */
    function convertPXOMtoXOM(
        uint256 amount
    ) external nonReentrant whenNotPaused {
        address caller = _msgSender();

        // Input validation
        if (amount == 0) revert ZeroAmount();
        if (amount < MIN_CONVERSION_AMOUNT) revert BelowMinimum();
        if (amount > maxConversionLimit) revert ExceedsConversionLimit();

        // Enforce daily volume limit
        _checkAndUpdateDailyVolume(amount);

        // Only allow redemption of bridge-minted pXOM, not genesis supply
        if (amount > bridgeMintedPXOM) revert InsufficientLockedFunds();

        // Check if we have enough locked XOM to release
        if (amount > totalLocked) revert InsufficientLockedFunds();

        // Update tracking (CEI: state changes before external calls)
        totalLocked -= amount;
        bridgeMintedPXOM -= amount;
        totalConvertedToPublic += amount;

        // Burn pXOM from user (bridge needs BURNER_ROLE or approval)
        privateOmniCoin.burnFrom(caller, amount);

        // Transfer XOM tokens to the user
        omniCoin.safeTransfer(caller, amount);

        emit ConvertedToPublic(caller);
    }

    // ========================================================================
    // ADMIN FUNCTIONS
    // ========================================================================

    /**
     * @notice Update maximum single conversion limit
     * @dev M-01 audit fix: restricted to OPERATOR_ROLE (not
     *      DEFAULT_ADMIN_ROLE) to separate routine parameter
     *      tuning from critical admin operations.
     *      There is no upper bound other than uint256 max;
     *      operator should set prudent limits.
     * @param newLimit New maximum conversion amount
     */
    function setMaxConversionLimit(
        uint256 newLimit
    ) external onlyRole(OPERATOR_ROLE) {
        if (newLimit == 0) revert ZeroAmount();

        uint256 oldLimit = maxConversionLimit;
        maxConversionLimit = newLimit;

        emit MaxConversionLimitUpdated(oldLimit, newLimit);
    }

    /**
     * @notice Update the daily volume limit for conversions
     * @dev M-01 audit fix: restricted to OPERATOR_ROLE (not
     *      DEFAULT_ADMIN_ROLE) to separate routine parameter
     *      tuning from critical admin operations.
     *      Set to 0 to disable the daily limit (unlimited
     *      conversions).
     * @param newLimit New daily volume limit (0 = unlimited)
     */
    function setDailyVolumeLimit(
        uint256 newLimit
    ) external onlyRole(OPERATOR_ROLE) {
        uint256 oldLimit = dailyVolumeLimit;
        dailyVolumeLimit = newLimit;
        emit DailyVolumeLimitUpdated(oldLimit, newLimit);
    }

    /**
     * @notice Pause all conversions
     * @dev M-01 audit fix: restricted to OPERATOR_ROLE (not
     *      DEFAULT_ADMIN_ROLE) so that routine operational
     *      controls are separated from critical admin functions.
     */
    function pause() external onlyRole(OPERATOR_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause conversions
     * @dev M-01 audit fix: restricted to OPERATOR_ROLE (not
     *      DEFAULT_ADMIN_ROLE) so that routine operational
     *      controls are separated from critical admin functions.
     */
    function unpause() external onlyRole(OPERATOR_ROLE) {
        _unpause();
    }

    /**
     * @notice Emergency withdrawal of tokens
     * @dev Only admin can withdraw. Pauses contract on XOM
     *      withdrawal to prevent redemptions against depleted
     *      reserves. Use only in emergency situations.
     *      SECURITY: Admin MUST be a multi-sig wallet with
     *      timelock. Emergency withdraw supersedes normal fee
     *      withdrawal: totalFeesCollected is zeroed
     *      proportionally when XOM is withdrawn.
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

        // If withdrawing the locked XOM token, update solvency
        // tracking and pause to prevent redemptions
        if (token == address(omniCoin)) {
            // M-01: Safely handle totalLocked underflow.
            // Cap amount at totalLocked to prevent underflow.
            if (amount > totalLocked) {
                // Withdrawing more than locked means we are also
                // taking fee XOM; zero out fees proportionally
                uint256 excessOverLocked = amount - totalLocked;
                if (excessOverLocked > totalFeesCollected) {
                    totalFeesCollected = 0;
                } else {
                    totalFeesCollected -= excessOverLocked;
                }
                totalLocked = 0;
            } else {
                totalLocked -= amount;
            }
            // Pause the bridge to prevent redemptions
            _pause();
        }

        IERC20(token).safeTransfer(to, amount);

        emit EmergencyWithdrawal(token, to, amount);
    }

    /**
     * @notice Withdraw accumulated conversion fees
     * @dev Only admin can withdraw fees. Fees are held
     *      separately from locked funds and do not affect
     *      solvency of the bridge.
     * @param recipient Address to receive fees
     */
    function withdrawFees(
        address recipient
    ) external onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {
        if (recipient == address(0)) revert ZeroAddress();
        uint256 fees = totalFeesCollected;
        if (fees == 0) revert ZeroAmount();

        totalFeesCollected = 0;
        omniCoin.safeTransfer(recipient, fees);

        emit FeesWithdrawn(recipient, fees);
    }

    /**
     * @notice Request ossification (starts 48-hour delay)
     * @dev Two-phase ossification prevents accidental or malicious
     *      irreversible lockout. Once confirmed after
     *      OSSIFICATION_DELAY, the contract becomes permanently
     *      non-upgradeable. Only callable by DEFAULT_ADMIN_ROLE.
     */
    function requestOssification()
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (ossificationRequestedAt != 0) {
            revert OssificationAlreadyRequested();
        }
        // solhint-disable-next-line not-rely-on-time
        ossificationRequestedAt = block.timestamp;
        // solhint-disable-next-line not-rely-on-time
        emit OssificationRequested(block.timestamp);
    }

    /**
     * @notice Confirm and execute ossification after delay
     * @dev Requires OSSIFICATION_DELAY (48 hours) to have elapsed
     *      since requestOssification() was called. Once executed,
     *      no further proxy upgrades are possible (irreversible).
     */
    function ossify() external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (ossificationRequestedAt == 0) {
            revert OssificationNotRequested();
        }
        if (
            // solhint-disable-next-line not-rely-on-time
            block.timestamp
                < ossificationRequestedAt + OSSIFICATION_DELAY
        ) {
            revert OssificationDelayNotMet();
        }
        delete ossificationRequestedAt;
        _ossified = true;
        emit ContractOssified(address(this));
        // solhint-disable-next-line not-rely-on-time
        emit OssificationExecuted(block.timestamp);
    }

    /**
     * @notice Check if the contract has been permanently ossified
     * @return True if ossified (no further upgrades possible)
     */
    function isOssified() external view returns (bool) {
        return _ossified;
    }

    // ========================================================================
    // VIEW FUNCTIONS
    // ========================================================================

    /**
     * @notice Get bridge statistics
     * @return _totalLocked Current amount of XOM locked
     * @return _totalConvertedToPrivate Cumulative to private
     * @return _totalConvertedToPublic Cumulative to public
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
        return (
            totalLocked,
            totalConvertedToPrivate,
            totalConvertedToPublic
        );
    }

    /**
     * @notice Get conversion rate (always 1:1, but fees apply)
     * @dev Fee is 0.5% for XOM to pXOM, 0% for pXOM to XOM
     * @return rate Conversion rate (always 1e18 for 1:1)
     */
    function getConversionRate()
        external
        pure
        returns (uint256 rate)
    {
        return 1e18; // 1:1 conversion rate
    }

    /**
     * @notice Calculate output for XOM to pXOM conversion
     * @param amountIn Amount of XOM to convert
     * @return amountOut pXOM received (after 0.5% fee)
     * @return fee Fee charged
     */
    function previewConvertToPrivate(
        uint256 amountIn
    )
        external
        pure
        returns (uint256 amountOut, uint256 fee)
    {
        fee = (amountIn * PRIVACY_FEE_BPS) / BPS_DENOMINATOR;
        amountOut = amountIn - fee;
    }

    /**
     * @notice Calculate output for pXOM to XOM conversion
     * @param amountIn Amount of pXOM to convert
     * @return amountOut Amount of XOM received (no fee)
     */
    function previewConvertToPublic(
        uint256 amountIn
    ) external pure returns (uint256 amountOut) {
        return amountIn; // No fee for this direction
    }

    // ========================================================================
    // INTERNAL FUNCTIONS
    // ========================================================================

    /**
     * @notice Check and update the daily volume counter
     * @dev M-02: Uses calendar-day boundaries (midnight UTC) to prevent
     *      period drift. Resets the counter when a new day begins.
     *      Uses `currentDayStart + 1 days` (not `block.timestamp`)
     *      for the new period start, ensuring consistent 24-hour windows.
     *      Reverts if the daily volume limit would be exceeded.
     *      If dailyVolumeLimit is 0, no limit is enforced.
     * @param amount The conversion amount to add to today's volume
     */
    function _checkAndUpdateDailyVolume(
        uint256 amount
    ) internal {
        if (dailyVolumeLimit == 0) return; // Unlimited

        // M-02: Reset counter using fixed-period boundaries (no drift).
        // Advance currentDayStart by full 1-day increments until current.
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp >= currentDayStart + 1 days) {
            currentDayVolume = 0;
            // Advance to the start of the current calendar day
            // to prevent accumulating drift from block.timestamp
            // solhint-disable-next-line not-rely-on-time
            currentDayStart += (
                ((block.timestamp - currentDayStart) / 1 days) *
                1 days
            );
        }

        if (currentDayVolume + amount > dailyVolumeLimit) {
            revert DailyVolumeLimitExceeded();
        }
        currentDayVolume += amount;
    }

    /**
     * @notice Authorize contract upgrades (UUPS pattern)
     * @dev Only admin can authorize upgrades to new
     *      implementation. Reverts if contract is ossified.
     *      The newImplementation parameter is required by the
     *      UUPS interface but not used in authorization logic.
     * @param newImplementation Address of new implementation
     *        (unused -- required by UUPSUpgradeable interface)
     */
    function _authorizeUpgrade(
        address newImplementation // solhint-disable-line no-unused-vars
    )
        internal
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (_ossified) revert ContractIsOssified();
    }

    // ========================================================================
    // ERC-2771 Meta-Transaction Overrides
    // ========================================================================

    /**
     * @notice Resolve the real sender for ERC-2771 meta-transactions
     * @dev Delegates to ERC2771ContextUpgradeable to extract the
     *      original sender from the trusted forwarder's calldata suffix.
     * @return The address of the original transaction sender
     */
    function _msgSender()
        internal
        view
        override(ContextUpgradeable, ERC2771ContextUpgradeable)
        returns (address)
    {
        return ERC2771ContextUpgradeable._msgSender();
    }

    /**
     * @notice Resolve the real calldata for ERC-2771 meta-transactions
     * @dev Delegates to ERC2771ContextUpgradeable to strip the
     *      sender-suffix appended by the trusted forwarder.
     * @return The original calldata without the appended sender address
     */
    function _msgData()
        internal
        view
        override(ContextUpgradeable, ERC2771ContextUpgradeable)
        returns (bytes calldata)
    {
        return ERC2771ContextUpgradeable._msgData();
    }

    /**
     * @notice Return the context suffix length for ERC-2771
     * @dev Delegates to ERC2771ContextUpgradeable (returns 20 when
     *      a trusted forwarder is configured, 0 otherwise).
     * @return Length in bytes of the calldata suffix (20 for ERC-2771)
     */
    function _contextSuffixLength()
        internal
        view
        override(ContextUpgradeable, ERC2771ContextUpgradeable)
        returns (uint256)
    {
        return ERC2771ContextUpgradeable._contextSuffixLength();
    }
}
