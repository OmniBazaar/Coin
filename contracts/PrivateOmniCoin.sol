// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ERC20BurnableUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import {ERC20PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PausableUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {MpcCore, gtUint64, ctUint64, gtBool} from "../coti-contracts/contracts/utils/mpc/MpcCore.sol";

/**
 * @title PrivateOmniCoin
 * @author OmniCoin Development Team
 * @notice Privacy-enabled ERC20 token using COTI V2 MPC technology
 * @dev Full MPC integration for privacy-preserving transactions
 *
 * Features:
 * - Public balance management (standard ERC20)
 * - Private balance management (MPC-encrypted)
 * - XOM ↔ pXOM conversion with 0.3% fee
 * - Privacy-preserving transfers
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
    UUPSUpgradeable
{
    // Use MpcCore library for type operations
    using MpcCore for gtUint64;
    using MpcCore for ctUint64;
    using MpcCore for gtBool;
    // ========================================================================
    // CONSTANTS
    // ========================================================================

    /// @notice Role identifier for minting permissions
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    /// @notice Role identifier for burning permissions
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");

    /// @notice Role identifier for bridge operations
    bytes32 public constant BRIDGE_ROLE = keccak256("BRIDGE_ROLE");

    /// @notice Initial token supply (1 billion tokens with 18 decimals)
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 * 10**18;

    /// @notice Privacy conversion fee in basis points (30 = 0.3%)
    uint16 public constant PRIVACY_FEE_BPS = 30;

    /// @notice Basis points denominator (10000 = 100%)
    uint16 public constant BPS_DENOMINATOR = 10000;

    // ========================================================================
    // STATE VARIABLES
    // ========================================================================

    /// @notice Encrypted private balances (ct = ciphertext for storage)
    /// @dev Maps address to encrypted balance using MPC ctUint64 type
    mapping(address => ctUint64) private encryptedBalances;

    /// @notice Total private supply (encrypted)
    /// @dev Total amount of tokens in private mode
    ctUint64 private totalPrivateSupply;

    /// @notice Privacy fee recipient address
    address private feeRecipient;

    /// @notice Whether privacy features are enabled on this network
    bool private privacyEnabled;

    /**
     * @dev Storage gap for future upgrades
     * @notice Reserves storage slots to allow adding new variables in upgrades
     * without shifting down inherited contract storage
     * Current storage: 4 variables (encryptedBalances, totalPrivateSupply, feeRecipient, privacyEnabled)
     * Gap size: 50 - 4 = 46 slots reserved
     */
    uint256[46] private __gap;

    // ========================================================================
    // EVENTS
    // ========================================================================

    /// @notice Emitted when tokens are converted to private mode
    /// @param user Address converting tokens
    /// @param publicAmount Amount converted (public)
    /// @param fee Fee charged for conversion
    event ConvertedToPrivate(address indexed user, uint256 indexed publicAmount, uint256 indexed fee);

    /// @notice Emitted when tokens are converted from private to public
    /// @param user Address converting tokens
    /// @param publicAmount Amount converted (public)
    event ConvertedToPublic(address indexed user, uint256 indexed publicAmount);

    /// @notice Emitted when a private transfer occurs
    /// @param from Sender address
    /// @param to Recipient address
    /// @dev Amount is not revealed for privacy
    event PrivateTransfer(address indexed from, address indexed to);

    /// @notice Emitted when privacy features are enabled/disabled
    /// @param enabled Whether privacy is now enabled
    event PrivacyStatusChanged(bool indexed enabled);

    /// @notice Emitted when fee recipient is updated
    /// @param newRecipient New fee recipient address
    event FeeRecipientUpdated(address indexed newRecipient);

    // ========================================================================
    // CUSTOM ERRORS
    // ========================================================================

    /// @notice Thrown when contract is already initialized
    error AlreadyInitialized();

    /// @notice Thrown when privacy features are not available
    error PrivacyNotAvailable();

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

    // ========================================================================
    // CONSTRUCTOR & INITIALIZATION
    // ========================================================================

    /**
     * @notice Constructor for PrivateOmniCoin (upgradeable pattern)
     * @dev Disables initializers to prevent implementation contract from being initialized
     * @custom:oz-upgrades-unsafe-allow constructor
     */
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize PrivateOmniCoin token (replaces constructor)
     * @dev Initializes all inherited contracts and sets up roles. Can only be called once.
     */
    function initialize() external initializer {
        // Initialize all inherited contracts
        __ERC20_init("Private OmniCoin", "pXOM");
        __ERC20Burnable_init();
        __ERC20Pausable_init();
        __AccessControl_init();
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

        // NOTE: totalPrivateSupply is initialized to zero by default
        // MPC operations are NOT performed during initialization to avoid deployment issues
        // MPC values will be initialized lazily when first privacy conversion occurs
    }

    /**
     * @notice Initialize MPC storage (deprecated - now inline in initialize())
     * @dev Kept for compatibility but should not be called
     */
    function _initializeMpcStorage() external view {
        revert Unauthorized();
    }

    // ========================================================================
    // PRIVACY CONVERSION FUNCTIONS
    // ========================================================================

    /**
     * @notice Convert public XOM tokens to private pXOM
     * @dev Charges 0.3% conversion fee, burns public tokens, credits private balance
     * @param amount Amount of public tokens to convert (must fit in uint64)
     */
    function convertToPrivate(uint256 amount) external whenNotPaused {
        if (!privacyEnabled) revert PrivacyNotAvailable();
        if (amount == 0) revert ZeroAmount();
        if (amount > type(uint64).max) revert AmountTooLarge();

        // Calculate fee (0.3%)
        uint256 fee = (amount * PRIVACY_FEE_BPS) / BPS_DENOMINATOR;
        uint256 amountAfterFee = amount - fee;

        // Burn public tokens from user
        _burn(msg.sender, amount);

        // Transfer fee to fee recipient
        if (fee > 0 && feeRecipient != address(0)) {
            _mint(feeRecipient, fee);
        }

        // Create encrypted amount
        gtUint64 gtAmount = MpcCore.setPublic64(uint64(amountAfterFee));

        // Load current encrypted balance
        gtUint64 gtCurrentBalance = MpcCore.onBoard(encryptedBalances[msg.sender]);

        // Add to encrypted balance
        gtUint64 gtNewBalance = MpcCore.add(gtCurrentBalance, gtAmount);

        // Store updated encrypted balance
        encryptedBalances[msg.sender] = MpcCore.offBoard(gtNewBalance);

        // Update total private supply
        gtUint64 gtTotalPrivate = MpcCore.onBoard(totalPrivateSupply);
        gtUint64 gtNewTotalPrivate = MpcCore.add(gtTotalPrivate, gtAmount);
        totalPrivateSupply = MpcCore.offBoard(gtNewTotalPrivate);

        emit ConvertedToPrivate(msg.sender, amount, fee);
    }

    /**
     * @notice Convert private pXOM tokens back to public XOM
     * @dev No fee charged for conversion to public, mints public tokens
     * @param encryptedAmount Encrypted amount to convert
     */
    function convertToPublic(gtUint64 encryptedAmount) external whenNotPaused {
        if (!privacyEnabled) revert PrivacyNotAvailable();

        // Load current encrypted balance
        gtUint64 gtCurrentBalance = MpcCore.onBoard(encryptedBalances[msg.sender]);

        // Check if balance is sufficient (compare encrypted values)
        gtBool hasSufficientBalance = MpcCore.ge(gtCurrentBalance, encryptedAmount);
        if (!MpcCore.decrypt(hasSufficientBalance)) {
            revert InsufficientPrivateBalance();
        }

        // Subtract from encrypted balance
        gtUint64 gtNewBalance = MpcCore.sub(gtCurrentBalance, encryptedAmount);
        encryptedBalances[msg.sender] = MpcCore.offBoard(gtNewBalance);

        // Update total private supply
        gtUint64 gtTotalPrivate = MpcCore.onBoard(totalPrivateSupply);
        gtUint64 gtNewTotalPrivate = MpcCore.sub(gtTotalPrivate, encryptedAmount);
        totalPrivateSupply = MpcCore.offBoard(gtNewTotalPrivate);

        // Decrypt amount for public minting
        uint64 plainAmount = MpcCore.decrypt(encryptedAmount);

        // Mint public tokens to user
        _mint(msg.sender, uint256(plainAmount));

        emit ConvertedToPublic(msg.sender, uint256(plainAmount));
    }

    // ========================================================================
    // PRIVATE TRANSFER FUNCTIONS
    // ========================================================================

    /**
     * @notice Transfer private tokens to another address
     * @dev Transfers encrypted balance without revealing amount
     * @param to Recipient address
     * @param encryptedAmount Encrypted amount to transfer
     */
    function privateTransfer(address to, gtUint64 encryptedAmount) external whenNotPaused {
        if (!privacyEnabled) revert PrivacyNotAvailable();
        if (to == address(0)) revert ZeroAddress();

        // Load sender's encrypted balance
        gtUint64 gtSenderBalance = MpcCore.onBoard(encryptedBalances[msg.sender]);

        // Check if sender has sufficient balance
        gtBool hasSufficientBalance = MpcCore.ge(gtSenderBalance, encryptedAmount);
        if (!MpcCore.decrypt(hasSufficientBalance)) {
            revert InsufficientPrivateBalance();
        }

        // Subtract from sender
        gtUint64 gtNewSenderBalance = MpcCore.sub(gtSenderBalance, encryptedAmount);
        encryptedBalances[msg.sender] = MpcCore.offBoard(gtNewSenderBalance);

        // Add to recipient
        gtUint64 gtRecipientBalance = MpcCore.onBoard(encryptedBalances[to]);
        gtUint64 gtNewRecipientBalance = MpcCore.add(gtRecipientBalance, encryptedAmount);
        encryptedBalances[to] = MpcCore.offBoard(gtNewRecipientBalance);

        emit PrivateTransfer(msg.sender, to);
    }

    // ========================================================================
    // ADMIN FUNCTIONS (EXTERNAL - NON-VIEW)
    // ========================================================================

    /**
     * @notice Update fee recipient address
     * @dev Only admin can update
     * @param newRecipient New fee recipient address
     */
    function setFeeRecipient(address newRecipient) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newRecipient == address(0)) revert ZeroAddress();
        feeRecipient = newRecipient;
        emit FeeRecipientUpdated(newRecipient);
    }

    /**
     * @notice Enable or disable privacy features
     * @dev Only admin can change, useful for network upgrades
     * @param enabled Whether to enable privacy
     */
    function setPrivacyEnabled(bool enabled) external onlyRole(DEFAULT_ADMIN_ROLE) {
        privacyEnabled = enabled;
        emit PrivacyStatusChanged(enabled);
    }

    /**
     * @notice Mint new public tokens
     * @dev Only MINTER_ROLE can mint
     * @param to Address to mint tokens to
     * @param amount Amount to mint
     */
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        _mint(to, amount);
    }

    /**
     * @notice Pause all token transfers
     * @dev Only admin can pause
     */
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause token transfers
     * @dev Only admin can unpause
     */
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    // ========================================================================
    // BALANCE QUERY FUNCTIONS
    // ========================================================================

    /**
     * @notice Get decrypted private balance (owner only)
     * @dev Only the account owner can decrypt their balance. Not a view function due to MPC operations.
     * @param account Address to query
     * @return balance Decrypted balance
     */
    function decryptedPrivateBalanceOf(address account) external returns (uint256 balance) {
        if (!privacyEnabled) return 0;
        if (msg.sender != account && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            revert Unauthorized();
        }

        gtUint64 gtBalance = MpcCore.onBoard(encryptedBalances[account]);
        uint64 decryptedBalance = MpcCore.decrypt(gtBalance);
        return uint256(decryptedBalance);
    }

    /**
     * @notice Get encrypted private balance for an address
     * @dev Returns ciphertext that can only be decrypted by authorized parties
     * @param account Address to query
     * @return balance Encrypted balance (ctUint64)
     */
    function privateBalanceOf(address account) external view returns (ctUint64 balance) {
        return encryptedBalances[account];
    }

    /**
     * @notice Get total private supply (encrypted)
     * @return supply Encrypted total private supply
     */
    function getTotalPrivateSupply() external view returns (ctUint64 supply) {
        return totalPrivateSupply;
    }

    // ========================================================================
    // PUBLIC FUNCTIONS (NON-VIEW)
    // ========================================================================

    /**
     * @notice Burn tokens from an address
     * @dev Only BURNER_ROLE can burn from others. Must be public to override parent.
     * @param from Address to burn from
     * @param amount Amount to burn
     */
    function burnFrom(address from, uint256 amount) public override onlyRole(BURNER_ROLE) {
        _burn(from, amount);
    }

    // ========================================================================
    // PUBLIC VIEW FUNCTIONS
    // ========================================================================

    /**
     * @notice Check if privacy features are available
     * @dev Returns true on COTI V2 network, false otherwise
     * @return available Whether privacy features are available
     */
    function privacyAvailable() public view returns (bool available) {
        return privacyEnabled;
    }

    /**
     * @notice Get current fee recipient
     * @return recipient Current fee recipient address
     */
    function getFeeRecipient() public view returns (address recipient) {
        return feeRecipient;
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
    // INTERNAL OVERRIDES
    // ========================================================================

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
    ) internal override(ERC20Upgradeable, ERC20PausableUpgradeable) {
        super._update(from, to, amount);
    }

    // ========================================================================
    // PRIVATE HELPER FUNCTIONS
    // ========================================================================

    /**
     * @notice Detect if privacy features are available on current network
     * @dev Internal function to check for COTI V2 MPC support
     * @return enabled Whether privacy is supported
     */
    function _detectPrivacyAvailability() private view returns (bool enabled) {
        // On COTI V2 network, MPC precompiles are available
        // COTI Devnet: Chain ID 13068200
        // COTI Testnet: Chain ID 7082400
        // COTI Mainnet: Chain ID 1353
        // For testing in Hardhat/Avalanche, return false (MPC not available)
        return (
            block.chainid == 13068200 ||  // COTI Devnet
            block.chainid == 7082400 ||   // COTI Testnet (verified)
            block.chainid == 7082 ||      // COTI Testnet (alternative)
            block.chainid == 1353         // COTI Mainnet
        );
    }
}
