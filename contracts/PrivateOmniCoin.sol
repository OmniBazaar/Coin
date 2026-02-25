// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {
    ERC20Upgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {
    ERC20BurnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import {
    ERC20PausableUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PausableUpgradeable.sol";
import {
    AccessControlUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {
    Initializable
} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    UUPSUpgradeable
} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {
    ReentrancyGuardUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {
    MpcCore,
    gtUint64,
    ctUint64,
    gtBool
} from "../coti-contracts/contracts/utils/mpc/MpcCore.sol";

/**
 * @title PrivateOmniCoin
 * @author OmniCoin Development Team
 * @notice Privacy-enabled ERC20 token using COTI V2 MPC technology
 * @dev Full MPC integration for privacy-preserving transactions.
 *
 * Uses a scaling factor approach to work within uint64 MPC limits:
 * - Public amounts use 18 decimals (standard ERC20)
 * - Private (MPC) amounts use 6 decimals (scaled by 1e12)
 * - Max private balance: ~18,446,744 XOM (18.4M XOM)
 * - Scaling dust (up to ~0.000001 XOM) is acceptable rounding loss
 *
 * Features:
 * - Public balance management (standard ERC20)
 * - Private balance management (MPC-encrypted, 6-decimal precision)
 * - XOM to pXOM conversion (no fee here; bridge charges 0.3%)
 * - Privacy-preserving transfers
 * - Shadow ledger for emergency recovery if MPC becomes unavailable
 * - Role-based access control
 * - Pausable for emergency stops
 * - Upgradeable via UUPS proxy pattern
 *
 * Privacy Operations:
 * - onBoard: Convert from storage (ct) to computation (gt) type
 * - offBoard: Convert from computation (gt) to storage (ct) type
 * - setPublic64: Create encrypted value from plain value
 * - decrypt: Reveal encrypted value (authorized only)
 */
contract PrivateOmniCoin is
    Initializable,
    ERC20Upgradeable,
    ERC20BurnableUpgradeable,
    ERC20PausableUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    // Use MpcCore library for type operations
    using MpcCore for gtUint64;
    using MpcCore for ctUint64;
    using MpcCore for gtBool;

    // ====================================================================
    // CONSTANTS
    // ====================================================================

    /// @notice Role identifier for minting permissions
    bytes32 public constant MINTER_ROLE =
        keccak256("MINTER_ROLE");

    /// @notice Role identifier for burning permissions
    bytes32 public constant BURNER_ROLE =
        keccak256("BURNER_ROLE");

    /// @notice Role identifier for bridge operations
    bytes32 public constant BRIDGE_ROLE =
        keccak256("BRIDGE_ROLE");

    /// @notice Initial token supply (1 billion tokens with 18 decimals)
    uint256 public constant INITIAL_SUPPLY =
        1_000_000_000 * 10 ** 18;

    /// @notice Privacy conversion fee in basis points (30 = 0.3%)
    /// @dev Retained for reference; fee is charged by OmniPrivacyBridge,
    /// not by this contract. See H-01 fix notes.
    uint16 public constant PRIVACY_FEE_BPS = 30;

    /// @notice Basis points denominator (10000 = 100%)
    uint16 public constant BPS_DENOMINATOR = 10000;

    /// @notice Scaling factor: 18 decimals to 6 decimals for MPC storage
    /// @dev Divides public amounts by 1e12 before MPC storage,
    /// multiplies by 1e12 on retrieval.
    /// Max private balance: type(uint64).max / 1e6 = 18,446,744 XOM
    uint256 public constant PRIVACY_SCALING_FACTOR = 1e12;

    /// @notice Maximum lifetime supply: 16.6 billion XOM
    /// @dev Defense-in-depth cap matching OmniCoin.MAX_SUPPLY to prevent
    ///      compromised minter from inflating pXOM beyond intended limits.
    uint256 public constant MAX_SUPPLY = 16_600_000_000 * 10 ** 18;

    // ====================================================================
    // STATE VARIABLES
    // ====================================================================

    /// @notice Encrypted private balances (ct = ciphertext for storage)
    /// @dev Maps address to encrypted balance using MPC ctUint64 type.
    /// Stored in 6-decimal (scaled) precision.
    mapping(address => ctUint64) private encryptedBalances;

    /// @notice Total private supply (encrypted)
    /// @dev Total amount of tokens in private mode (scaled precision)
    ctUint64 private totalPrivateSupply;

    /// @notice Privacy fee recipient address
    /// @dev Retained for storage layout compatibility with deployed proxy
    address private feeRecipient;

    /// @notice Whether privacy features are enabled on this network
    bool private privacyEnabled;

    /// @notice Shadow ledger tracking private deposits for emergency recovery
    /// @dev Tracks total scaled private balance per user (in MPC-scaled
    /// units, i.e., 6-decimal precision). Used only when MPC is
    /// unavailable and admin triggers emergencyRecoverPrivateBalance.
    mapping(address => uint256) public privateDepositLedger;

    /// @notice Whether contract is ossified (permanently non-upgradeable)
    bool private _ossified;

    /**
     * @dev Storage gap for future upgrades.
     * @notice Reserves storage slots for adding new variables in upgrades
     * without shifting inherited contract storage.
     * Current storage: 6 variables (encryptedBalances, totalPrivateSupply,
     * feeRecipient, privacyEnabled, privateDepositLedger, _ossified)
     * Gap size: 50 - 6 = 44 slots reserved
     */
    uint256[44] private __gap;

    // ====================================================================
    // EVENTS
    // ====================================================================

    /// @notice Emitted when tokens are converted to private mode
    /// @param user Address converting tokens
    /// @param publicAmount Amount converted (18-decimal public amount)
    /// @param fee Fee charged for conversion (always 0 in this contract)
    event ConvertedToPrivate(
        address indexed user,
        uint256 indexed publicAmount,
        uint256 indexed fee
    );

    /// @notice Emitted when tokens are converted from private to public
    /// @param user Address converting tokens
    /// @param publicAmount Amount converted (18-decimal public amount)
    event ConvertedToPublic(
        address indexed user,
        uint256 indexed publicAmount
    );

    /// @notice Emitted when a private transfer occurs
    /// @param from Sender address
    /// @param to Recipient address
    /// @dev Amount is not revealed for privacy
    event PrivateTransfer(
        address indexed from,
        address indexed to
    );

    /// @notice Emitted when privacy features are enabled/disabled
    /// @param enabled Whether privacy is now enabled
    event PrivacyStatusChanged(bool indexed enabled);

    /// @notice Emitted when fee recipient is updated
    /// @param newRecipient New fee recipient address
    event FeeRecipientUpdated(address indexed newRecipient);

    /// @notice Emitted when an emergency private balance recovery occurs
    /// @param user Address whose private balance was recovered
    /// @param publicAmount Amount minted back (18-decimal)
    event EmergencyPrivateRecovery(
        address indexed user,
        uint256 indexed publicAmount
    );

    /// @notice Emitted when the contract is permanently ossified
    /// @param contractAddress Address of this contract
    event ContractOssified(address indexed contractAddress);

    // ====================================================================
    // CUSTOM ERRORS
    // ====================================================================

    /// @notice Thrown when contract is already initialized
    error AlreadyInitialized();

    /// @notice Thrown when privacy features are not available
    error PrivacyNotAvailable();

    /// @notice Thrown when privacy must be disabled for this operation
    error PrivacyMustBeDisabled();

    /// @notice Thrown when insufficient private balance
    error InsufficientPrivateBalance();

    /// @notice Thrown when amount is zero
    error ZeroAmount();

    /// @notice Thrown when address is zero
    error ZeroAddress();

    /// @notice Thrown when amount exceeds maximum for MPC (2^64-1)
    error AmountTooLarge();

    /// @notice Thrown when caller is not authorized
    error Unauthorized();

    /// @notice Thrown when shadow ledger has no balance to recover
    error NoBalanceToRecover();

    /// @notice Thrown when minting would exceed the maximum supply cap
    error ExceedsMaxSupply();

    /// @notice Thrown when sender and recipient are the same address
    error SelfTransfer();

    /// @notice Thrown when contract is ossified and upgrade attempted
    error ContractIsOssified();

    // ====================================================================
    // CONSTRUCTOR & INITIALIZATION
    // ====================================================================

    /**
     * @notice Constructor for PrivateOmniCoin (upgradeable pattern)
     * @dev Disables initializers to prevent implementation contract
     * from being initialized directly.
     * @custom:oz-upgrades-unsafe-allow constructor
     */
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize PrivateOmniCoin token (replaces constructor)
     * @dev Initializes all inherited contracts and sets up roles.
     * Can only be called once via the proxy.
     */
    function initialize() external initializer {
        // Initialize all inherited contracts
        __ERC20_init("Private OmniCoin", "pXOM");
        __ERC20Burnable_init();
        __ERC20Pausable_init();
        __AccessControl_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        // Grant roles to deployer
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MINTER_ROLE, msg.sender);
        _grantRole(BURNER_ROLE, msg.sender);
        _grantRole(BRIDGE_ROLE, msg.sender);

        // Set initial fee recipient to deployer
        feeRecipient = msg.sender;

        // Detect if privacy is available (COTI network check)
        privacyEnabled = _detectPrivacyAvailability();

        // Mint initial supply
        _mint(msg.sender, INITIAL_SUPPLY);

        // NOTE: totalPrivateSupply initialized to zero by default.
        // MPC values initialized lazily on first privacy conversion.
    }

    // ====================================================================
    // PRIVACY CONVERSION FUNCTIONS
    // ====================================================================

    /**
     * @notice Convert public XOM tokens to private pXOM
     * @dev Burns public tokens and credits scaled private balance via MPC.
     * No fee is charged here; the OmniPrivacyBridge charges 0.3%.
     *
     * Scaling: The 18-decimal public amount is divided by
     * PRIVACY_SCALING_FACTOR (1e12) to produce a 6-decimal value
     * that fits within uint64. Rounding dust (up to ~0.000001 XOM)
     * is acceptable loss.
     *
     * Max convertible amount per call:
     * type(uint64).max * 1e12 = ~18,446,744 XOM
     *
     * @param amount Amount of public tokens to convert (18 decimals)
     */
    function convertToPrivate(
        uint256 amount
    ) external nonReentrant whenNotPaused {
        if (!privacyEnabled) revert PrivacyNotAvailable();
        if (amount == 0) revert ZeroAmount();

        // Scale down from 18 decimals to 6 decimals for MPC storage
        uint256 scaledAmount = amount / PRIVACY_SCALING_FACTOR;
        if (scaledAmount == 0) revert ZeroAmount();
        if (scaledAmount > type(uint64).max) {
            revert AmountTooLarge();
        }

        // Burn the full public amount from user
        _burn(msg.sender, amount);

        // Create encrypted amount from scaled value
        gtUint64 gtAmount =
            MpcCore.setPublic64(uint64(scaledAmount));

        // Load current encrypted balance and add
        gtUint64 gtCurrentBalance =
            MpcCore.onBoard(encryptedBalances[msg.sender]);
        gtUint64 gtNewBalance =
            MpcCore.add(gtCurrentBalance, gtAmount);

        // Store updated encrypted balance
        encryptedBalances[msg.sender] =
            MpcCore.offBoard(gtNewBalance);

        // Update total private supply
        gtUint64 gtTotalPrivate =
            MpcCore.onBoard(totalPrivateSupply);
        gtUint64 gtNewTotalPrivate =
            MpcCore.add(gtTotalPrivate, gtAmount);
        totalPrivateSupply =
            MpcCore.offBoard(gtNewTotalPrivate);

        // Update shadow ledger for emergency recovery
        privateDepositLedger[msg.sender] += scaledAmount;

        emit ConvertedToPrivate(msg.sender, amount, 0);
    }

    /**
     * @notice Convert private pXOM tokens back to public XOM
     * @dev Decrypts the MPC amount, scales it back to 18 decimals,
     * and mints public tokens. No fee charged.
     * @param encryptedAmount Encrypted amount to convert (6-decimal
     * scaled precision within MPC)
     */
    function convertToPublic(
        gtUint64 encryptedAmount
    ) external nonReentrant whenNotPaused {
        if (!privacyEnabled) revert PrivacyNotAvailable();

        // Load current encrypted balance
        gtUint64 gtCurrentBalance =
            MpcCore.onBoard(encryptedBalances[msg.sender]);

        // Check if balance is sufficient (compare encrypted values)
        gtBool hasSufficientBalance =
            MpcCore.ge(gtCurrentBalance, encryptedAmount);
        if (!MpcCore.decrypt(hasSufficientBalance)) {
            revert InsufficientPrivateBalance();
        }

        // Subtract from encrypted balance
        gtUint64 gtNewBalance =
            MpcCore.sub(gtCurrentBalance, encryptedAmount);
        encryptedBalances[msg.sender] =
            MpcCore.offBoard(gtNewBalance);

        // Update total private supply
        gtUint64 gtTotalPrivate =
            MpcCore.onBoard(totalPrivateSupply);
        gtUint64 gtNewTotalPrivate =
            MpcCore.sub(gtTotalPrivate, encryptedAmount);
        totalPrivateSupply =
            MpcCore.offBoard(gtNewTotalPrivate);

        // Decrypt amount and scale back to 18 decimals
        // M-02: Check for zero after decryption to prevent no-op
        // conversions that waste gas and emit misleading events.
        uint64 plainAmount = MpcCore.decrypt(encryptedAmount);
        if (plainAmount == 0) revert ZeroAmount();
        uint256 publicAmount =
            uint256(plainAmount) * PRIVACY_SCALING_FACTOR;

        // Update shadow ledger (strict inequality for gas opt)
        if (uint256(plainAmount) > privateDepositLedger[msg.sender]) {
            // Edge case: ledger may be less if private transfers
            // occurred. Zero it out rather than underflow.
            privateDepositLedger[msg.sender] = 0;
        } else {
            privateDepositLedger[msg.sender] -=
                uint256(plainAmount);
        }

        // Mint public tokens to user
        _mint(msg.sender, publicAmount);

        emit ConvertedToPublic(msg.sender, publicAmount);
    }

    // ====================================================================
    // PRIVATE TRANSFER FUNCTIONS
    // ====================================================================

    /**
     * @notice Transfer private tokens to another address
     * @dev Transfers encrypted balance without revealing amount.
     * Updates shadow ledgers for both sender and recipient.
     * @param to Recipient address
     * @param encryptedAmount Encrypted amount to transfer (6-decimal
     * scaled precision within MPC)
     */
    function privateTransfer(
        address to,
        gtUint64 encryptedAmount
    ) external nonReentrant whenNotPaused {
        if (!privacyEnabled) revert PrivacyNotAvailable();
        if (to == address(0)) revert ZeroAddress();
        // M-01: Prevent self-transfers that waste gas and may
        // corrupt MPC state via same-slot read/write ordering.
        if (to == msg.sender) revert SelfTransfer();

        // Load sender's encrypted balance
        gtUint64 gtSenderBalance =
            MpcCore.onBoard(encryptedBalances[msg.sender]);

        // Check if sender has sufficient balance
        gtBool hasSufficientBalance =
            MpcCore.ge(gtSenderBalance, encryptedAmount);
        if (!MpcCore.decrypt(hasSufficientBalance)) {
            revert InsufficientPrivateBalance();
        }

        // Subtract from sender
        gtUint64 gtNewSenderBalance =
            MpcCore.sub(gtSenderBalance, encryptedAmount);
        encryptedBalances[msg.sender] =
            MpcCore.offBoard(gtNewSenderBalance);

        // Add to recipient
        gtUint64 gtRecipientBalance =
            MpcCore.onBoard(encryptedBalances[to]);
        gtUint64 gtNewRecipientBalance =
            MpcCore.add(gtRecipientBalance, encryptedAmount);
        encryptedBalances[to] =
            MpcCore.offBoard(gtNewRecipientBalance);

        // Note: Shadow ledger is NOT updated for private transfers
        // because the amount is encrypted. The ledger only tracks
        // deposits/withdrawals for emergency recovery purposes.
        // In emergency recovery, users who received private transfers
        // would not have their received amounts in the ledger; only
        // their own deposits are recoverable. This is documented
        // behavior and an acceptable trade-off for emergency recovery.

        emit PrivateTransfer(msg.sender, to);
    }

    // ====================================================================
    // ADMIN FUNCTIONS
    // ====================================================================

    /**
     * @notice Update fee recipient address
     * @dev Only admin can update. Retained for storage layout
     * compatibility and potential future use.
     * @param newRecipient New fee recipient address
     */
    function setFeeRecipient(
        address newRecipient
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newRecipient == address(0)) revert ZeroAddress();
        feeRecipient = newRecipient;
        emit FeeRecipientUpdated(newRecipient);
    }

    /**
     * @notice Enable or disable privacy features
     * @dev Only admin can change. Disabling privacy is required
     * before emergency recovery can be used.
     * @param enabled Whether to enable privacy
     */
    function setPrivacyEnabled(
        bool enabled
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        privacyEnabled = enabled;
        emit PrivacyStatusChanged(enabled);
    }

    /**
     * @notice Emergency recover private balance when MPC is unavailable
     * @dev Only callable by admin when privacy is disabled. Uses
     * the shadow ledger to determine the user's recoverable balance.
     * Mints the scaled-up public amount back to the user.
     *
     * Limitations: Only deposits made via convertToPrivate are
     * recoverable. Amounts received via privateTransfer are NOT
     * tracked in the shadow ledger and cannot be recovered this way.
     *
     * @param user Address to recover balance for
     */
    function emergencyRecoverPrivateBalance(
        address user
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (privacyEnabled) revert PrivacyMustBeDisabled();
        if (user == address(0)) revert ZeroAddress();

        uint256 scaledBalance = privateDepositLedger[user];
        if (scaledBalance == 0) revert NoBalanceToRecover();

        // Clear the shadow ledger entry
        privateDepositLedger[user] = 0;

        // Scale back to 18-decimal public amount and mint
        uint256 publicAmount =
            scaledBalance * PRIVACY_SCALING_FACTOR;
        _mint(user, publicAmount);

        emit EmergencyPrivateRecovery(user, publicAmount);
    }

    /**
     * @notice Mint new public tokens
     * @dev Only MINTER_ROLE can mint. Enforces MAX_SUPPLY cap as
     *      defense-in-depth against compromised minter keys (M-03).
     * @param to Address to mint tokens to
     * @param amount Amount to mint (18 decimals)
     */
    function mint(
        address to,
        uint256 amount
    ) external onlyRole(MINTER_ROLE) {
        if (totalSupply() + amount > MAX_SUPPLY) {
            revert ExceedsMaxSupply();
        }
        _mint(to, amount);
    }

    /**
     * @notice Pause all token transfers and privacy operations
     * @dev Only admin can pause
     */
    function pause()
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _pause();
    }

    /**
     * @notice Unpause token transfers and privacy operations
     * @dev Only admin can unpause
     */
    function unpause()
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _unpause();
    }

    // ====================================================================
    // BALANCE QUERY FUNCTIONS
    // ====================================================================

    /**
     * @notice Get decrypted private balance (owner or admin only)
     * @dev Only the account owner or admin can decrypt the balance.
     * Not a view function due to MPC decrypt operations.
     * Returns the 18-decimal public-equivalent amount.
     * @param account Address to query
     * @return balance Decrypted balance scaled to 18 decimals
     */
    function decryptedPrivateBalanceOf(
        address account
    ) external returns (uint256 balance) {
        if (!privacyEnabled) return 0;
        if (
            msg.sender != account &&
            !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)
        ) {
            revert Unauthorized();
        }

        gtUint64 gtBalance =
            MpcCore.onBoard(encryptedBalances[account]);
        uint64 decryptedBalance = MpcCore.decrypt(gtBalance);

        // Scale back to 18 decimals for the caller
        return uint256(decryptedBalance) * PRIVACY_SCALING_FACTOR;
    }

    /**
     * @notice Get encrypted private balance for an address
     * @dev Returns ciphertext that can only be decrypted by
     * authorized parties. The encrypted value is in 6-decimal
     * (scaled) precision.
     * @param account Address to query
     * @return balance Encrypted balance (ctUint64)
     */
    function privateBalanceOf(
        address account
    ) external view returns (ctUint64 balance) {
        return encryptedBalances[account];
    }

    /**
     * @notice Get total private supply (encrypted)
     * @dev The encrypted value is in 6-decimal (scaled) precision.
     * @return supply Encrypted total private supply
     */
    function getTotalPrivateSupply()
        external
        view
        returns (ctUint64 supply)
    {
        return totalPrivateSupply;
    }

    // ====================================================================
    // PUBLIC FUNCTIONS (NON-VIEW)
    // ====================================================================

    /**
     * @notice Burn tokens from an address
     * @dev Only BURNER_ROLE can burn from others.
     * Overrides parent to enforce role-based access.
     * @param from Address to burn from
     * @param amount Amount to burn (18 decimals)
     */
    function burnFrom(
        address from,
        uint256 amount
    ) public override onlyRole(BURNER_ROLE) {
        _burn(from, amount);
    }

    // ====================================================================
    // PUBLIC VIEW FUNCTIONS
    // ====================================================================

    /**
     * @notice Check if privacy features are available
     * @dev Returns true on COTI V2 or OmniCoin network when enabled
     * @return available Whether privacy features are available
     */
    function privacyAvailable()
        public
        view
        returns (bool available)
    {
        return privacyEnabled;
    }

    /**
     * @notice Get current fee recipient
     * @dev Retained for storage layout compatibility
     * @return recipient Current fee recipient address
     */
    function getFeeRecipient()
        public
        view
        returns (address recipient)
    {
        return feeRecipient;
    }

    // ====================================================================
    // UUPS UPGRADE AUTHORIZATION
    // ====================================================================

    /**
     * @notice Permanently remove upgrade capability (one-way, irreversible)
     * @dev Can only be called by admin (through timelock). Once ossified,
     *      the contract can never be upgraded again.
     */
    function ossify() external onlyRole(DEFAULT_ADMIN_ROLE) {
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
     * @dev Only admin can authorize upgrades to new implementation.
     *      Reverts if contract is ossified.
     * @param newImplementation Address of new implementation contract
     */
    function _authorizeUpgrade(
        address newImplementation
    )
        internal
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (_ossified) revert ContractIsOssified();
    }

    // ====================================================================
    // INTERNAL OVERRIDES
    // ====================================================================

    /**
     * @notice Override required for multiple inheritance
     * @dev Applies pausable check before transfers
     * @param from Address tokens are transferred from
     * @param to Address tokens are transferred to
     * @param amount Amount of tokens to transfer
     */
    function _update(
        address from,
        address to,
        uint256 amount
    )
        internal
        override(ERC20Upgradeable, ERC20PausableUpgradeable)
    {
        super._update(from, to, amount);
    }

    // ====================================================================
    // PRIVATE HELPER FUNCTIONS
    // ====================================================================

    /**
     * @notice Detect if privacy features are available on current
     * network
     * @dev Checks chain ID for COTI V2 MPC support or OmniCoin L1.
     * On other networks (Hardhat, Avalanche), returns false.
     * @return enabled Whether privacy is supported
     */
    function _detectPrivacyAvailability()
        private
        view
        returns (bool enabled)
    {
        return (
            block.chainid == 13068200 || // COTI Devnet
            block.chainid == 7082400 ||  // COTI Testnet (verified)
            block.chainid == 7082 ||     // COTI Testnet (alt)
            block.chainid == 1353 ||     // COTI Mainnet
            block.chainid == 131313      // OmniCoin L1
        );
    }
}
