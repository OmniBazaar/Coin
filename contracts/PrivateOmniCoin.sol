// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {
    ERC20Upgradeable
} from
    "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {
    ERC20BurnableUpgradeable
} from
    "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import {
    ERC20PausableUpgradeable
} from
    "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PausableUpgradeable.sol";
import {
    AccessControlUpgradeable
} from
    "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {
    Initializable
} from
    "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    UUPSUpgradeable
} from
    "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {
    ReentrancyGuardUpgradeable
} from
    "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
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
 * - Scaling dust is refunded to the user's public balance
 *   (only the cleanly-scaled portion is burned)
 *
 * Privacy Fee:
 * - No fee is charged in this contract.
 * - The OmniPrivacyBridge charges a 0.5% fee (50 basis points)
 *   when users convert XOM to pXOM via the bridge entry point.
 * - Example: User sends 1000 XOM to bridge. Bridge deducts 5 XOM
 *   (0.5%) as fee, calls this contract to mint 995 pXOM.
 *
 * Features:
 * - Public balance management (standard ERC20)
 * - Private balance management (MPC-encrypted, 6-decimal precision)
 * - XOM to pXOM conversion (no fee here; bridge charges 0.5%)
 * - Privacy-preserving transfers
 * - Shadow ledger for emergency recovery if MPC becomes unavailable
 * - Role-based access control
 * - Pausable for emergency stops
 * - Upgradeable via UUPS proxy pattern with ossification
 * - Checked MPC arithmetic (checkedAdd/checkedSub) to revert on
 *   overflow instead of silently wrapping
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

    /// @notice Privacy conversion fee in basis points (50 = 0.5%)
    /// @dev This constant is retained for reference and external
    ///      integrator queries. The fee is NOT charged by this
    ///      contract; it is charged by OmniPrivacyBridge on the
    ///      XOM-to-pXOM entry path.
    ///
    ///      Fee example (0.5% = 50 BPS):
    ///        User converts 1000 XOM via bridge.
    ///        Bridge deducts 1000 * 50 / 10000 = 5 XOM as fee.
    ///        Bridge calls this contract to mint 995 pXOM.
    uint16 public constant PRIVACY_FEE_BPS = 50;

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

    /// @notice Timelock delay for privacy disable (7 days)
    /// @dev ATK-H07: Gives users time to exit private positions
    ///      before privacy is disabled and emergency recovery
    ///      becomes possible.
    uint256 public constant PRIVACY_DISABLE_DELAY = 7 days;

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

    /// @notice VESTIGIAL: Fee recipient address (no longer used for
    ///         fee routing)
    /// @dev Retained solely for storage layout compatibility with
    ///      deployed proxy. DO NOT rely on this value for fee
    ///      configuration. See OmniPrivacyBridge for actual fee
    ///      management.
    address private feeRecipient;

    /// @notice Whether privacy features are enabled on this network
    bool private privacyEnabled;

    /// @notice Shadow ledger tracking private deposits for emergency
    ///         recovery
    /// @dev Tracks total scaled private balance per user (in
    ///      MPC-scaled units, i.e., 6-decimal precision). Used only
    ///      when MPC is unavailable and admin triggers
    ///      emergencyRecoverPrivateBalance.
    mapping(address => uint256) public privateDepositLedger;

    /// @notice Whether contract is ossified (permanently
    ///         non-upgradeable)
    bool private _ossified;

    /// @notice Timestamp when privacy disable becomes executable
    /// @dev ATK-H07: Requires 7-day delay before privacy can be
    ///      disabled, giving users time to exit private positions.
    ///      Zero means no disable is pending.
    uint256 public privacyDisableScheduledAt;

    /**
     * @dev Storage gap for future upgrades.
     * @notice Reserves storage slots for adding new variables in
     *         upgrades without shifting inherited contract storage.
     *
     * Current named sequential state variables:
     *   - encryptedBalances        (mapping, no seq. slot)
     *   - totalPrivateSupply       (1 slot)
     *   - feeRecipient             (1 slot)
     *   - privacyEnabled           (1 slot)
     *   - privateDepositLedger     (mapping, no seq. slot)
     *   - _ossified                (1 slot)
     *   - privacyDisableScheduledAt (1 slot)
     *
     * Sequential slots used: 5
     * Gap = 50 - 5 = 45 slots reserved
     * (mappings excluded per OZ convention)
     */
    uint256[45] private __gap;

    // ====================================================================
    // EVENTS
    // ====================================================================

    /// @notice Emitted when tokens are converted to private mode
    /// @param user Address converting tokens
    /// @param publicAmount Amount burned (18-decimal, after dust
    ///        refund -- only the cleanly-scaled portion)
    // solhint-disable-next-line gas-indexed-events
    event ConvertedToPrivate(
        address indexed user,
        uint256 publicAmount
    );

    /// @notice Emitted when tokens are converted from private to public
    /// @param user Address converting tokens
    /// @param publicAmount Amount converted (18-decimal public amount)
    // solhint-disable-next-line gas-indexed-events
    event ConvertedToPublic(
        address indexed user,
        uint256 publicAmount
    );

    /// @notice Emitted when a private transfer occurs
    /// @param from Sender address
    /// @param to Recipient address
    /// @dev ATK-H06 PRIVACY LIMITATION: PrivateTransfer events expose
    ///      sender and receiver addresses on-chain. While amounts are
    ///      encrypted via COTI MPC garbled circuits, the transaction
    ///      graph (who transacts with whom) is publicly visible. For
    ///      full relationship privacy, use the relayer service
    ///      (RelayerSelectionService) which adds an intermediary
    ///      layer. Future versions may use COTI's encrypted events
    ///      when available on COTI L2.
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
    // solhint-disable-next-line gas-indexed-events
    event EmergencyPrivateRecovery(
        address indexed user,
        uint256 publicAmount
    );

    /// @notice Emitted when the contract is permanently ossified
    /// @param contractAddress Address of this contract
    event ContractOssified(address indexed contractAddress);

    /// @notice Emitted when privacy disable is proposed (7-day delay)
    /// @param executeAfter Timestamp after which disable can execute
    event PrivacyDisableProposed(uint256 executeAfter);

    /// @notice Emitted when privacy is disabled after timelock
    event PrivacyDisabled();

    /// @notice Emitted when a pending privacy disable is cancelled
    event PrivacyDisableCancelled();

    /// @notice Emitted when shadow ledger is updated during transfer
    /// @param from Sender whose ledger was debited
    /// @param to Recipient whose ledger was credited
    /// @param scaledAmount Amount transferred (6-decimal scaled)
    event PrivateLedgerUpdated(
        address indexed from,
        address indexed to,
        uint256 scaledAmount
    );

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

    /// @notice Thrown when caller is not the account owner
    error OnlyAccountOwner();

    /// @notice Thrown when no privacy disable has been proposed
    error NoPendingChange();

    /// @notice Thrown when the timelock delay has not elapsed
    error TimelockActive();

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
     * @dev Burns public tokens and credits scaled private balance
     *      via MPC. No fee is charged here; the OmniPrivacyBridge
     *      charges 0.5%.
     *
     * Scaling: The 18-decimal public amount is divided by
     * PRIVACY_SCALING_FACTOR (1e12) to produce a 6-decimal value
     * that fits within uint64.
     *
     * M-03 fix: Only the cleanly-scaled portion (scaledAmount *
     * PRIVACY_SCALING_FACTOR) is burned. Any sub-1e12 remainder
     * ("scaling dust") stays in the user's public balance, preventing
     * permanent token destruction.
     *
     * Max convertible amount per call:
     * type(uint64).max * 1e12 = ~18,446,744 XOM
     *
     * M-01 fix: Uses MpcCore.checkedAdd() instead of unchecked
     * MpcCore.add() to revert on overflow.
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

        // M-03: Only burn the cleanly-scaled portion;
        // sub-1e12 dust stays in user's public balance
        uint256 actualBurnAmount =
            scaledAmount * PRIVACY_SCALING_FACTOR;
        _burn(msg.sender, actualBurnAmount);

        // Create encrypted amount from scaled value
        gtUint64 gtAmount =
            MpcCore.setPublic64(uint64(scaledAmount));

        // M-01: Use checkedAdd to revert on overflow
        gtUint64 gtCurrentBalance =
            MpcCore.onBoard(encryptedBalances[msg.sender]);
        gtUint64 gtNewBalance =
            MpcCore.checkedAdd(gtCurrentBalance, gtAmount);

        // Store updated encrypted balance
        encryptedBalances[msg.sender] =
            MpcCore.offBoard(gtNewBalance);

        // L-01: Check that total private supply does not exceed
        // the uint64 boundary (defense-in-depth for encrypted supply)
        gtUint64 gtTotalPrivate =
            MpcCore.onBoard(totalPrivateSupply);
        gtUint64 gtNewTotalPrivate =
            MpcCore.checkedAdd(gtTotalPrivate, gtAmount);
        totalPrivateSupply =
            MpcCore.offBoard(gtNewTotalPrivate);

        // Update shadow ledger for emergency recovery
        privateDepositLedger[msg.sender] += scaledAmount;

        emit ConvertedToPrivate(msg.sender, actualBurnAmount);
    }

    /**
     * @notice Convert private pXOM tokens back to public XOM
     * @dev Decrypts the MPC amount, scales it back to 18 decimals,
     * and mints public tokens. No fee charged.
     *
     * M-01 fix: Uses MpcCore.checkedSub() instead of unchecked
     * MpcCore.sub() to revert on underflow.
     *
     * L-01/L-02: Enforces MAX_SUPPLY on the mint path as
     * defense-in-depth.
     *
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

        // M-01: Use checkedSub for defense-in-depth
        gtUint64 gtNewBalance =
            MpcCore.checkedSub(gtCurrentBalance, encryptedAmount);
        encryptedBalances[msg.sender] =
            MpcCore.offBoard(gtNewBalance);

        // Update total private supply
        gtUint64 gtTotalPrivate =
            MpcCore.onBoard(totalPrivateSupply);
        gtUint64 gtNewTotalPrivate =
            MpcCore.checkedSub(gtTotalPrivate, encryptedAmount);
        totalPrivateSupply =
            MpcCore.offBoard(gtNewTotalPrivate);

        // Decrypt amount and scale back to 18 decimals
        uint64 plainAmount = MpcCore.decrypt(encryptedAmount);
        if (plainAmount == 0) revert ZeroAmount();
        uint256 publicAmount =
            uint256(plainAmount) * PRIVACY_SCALING_FACTOR;

        // Update shadow ledger (strict inequality for gas opt)
        if (
            uint256(plainAmount) >
            privateDepositLedger[msg.sender]
        ) {
            // Edge case: ledger may be less if private transfers
            // occurred. Zero it out rather than underflow.
            privateDepositLedger[msg.sender] = 0;
        } else {
            privateDepositLedger[msg.sender] -=
                uint256(plainAmount);
        }

        // L-01: Defense-in-depth MAX_SUPPLY check on mint
        if (totalSupply() + publicAmount > MAX_SUPPLY) {
            revert ExceedsMaxSupply();
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
     *
     *      M-01 fix: Uses MpcCore.checkedSub() and
     *      MpcCore.checkedAdd() for defense-in-depth overflow/
     *      underflow protection.
     *
     *      ATK-H08 fix: Shadow ledger is now updated during
     *      private transfers by decrypting the transfer amount.
     *      This ensures emergency recovery correctly reflects all
     *      balances, including those received via privateTransfer.
     *      Note: The decrypt call reveals the amount to the
     *      contract/node but not to external observers (amount
     *      is not emitted in events).
     *
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
        // Prevent self-transfers that waste gas and may
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

        // M-01: checkedSub reverts on underflow
        gtUint64 gtNewSenderBalance =
            MpcCore.checkedSub(gtSenderBalance, encryptedAmount);
        encryptedBalances[msg.sender] =
            MpcCore.offBoard(gtNewSenderBalance);

        // M-01: checkedAdd reverts on overflow
        gtUint64 gtRecipientBalance =
            MpcCore.onBoard(encryptedBalances[to]);
        gtUint64 gtNewRecipientBalance =
            MpcCore.checkedAdd(gtRecipientBalance, encryptedAmount);
        encryptedBalances[to] =
            MpcCore.offBoard(gtNewRecipientBalance);

        // ATK-H08: Update shadow ledger so emergency recovery
        // correctly reflects transferred balances. We must decrypt
        // the amount to update the plaintext ledger.
        uint64 plainAmount = MpcCore.decrypt(encryptedAmount);
        uint256 transferAmount = uint256(plainAmount);

        if (privateDepositLedger[msg.sender] >= transferAmount) {
            privateDepositLedger[msg.sender] -= transferAmount;
        } else {
            // Edge case: ledger may be less than transfer amount
            // (e.g., partial deposits). Zero it out rather than
            // underflow.
            privateDepositLedger[msg.sender] = 0;
        }
        privateDepositLedger[to] += transferAmount;

        emit PrivateLedgerUpdated(
            msg.sender, to, transferAmount
        );
        emit PrivateTransfer(msg.sender, to);
    }

    // ====================================================================
    // ADMIN FUNCTIONS
    // ====================================================================

    /**
     * @notice Update fee recipient address
     * @dev Only admin can update. VESTIGIAL: Retained solely for
     *      storage layout compatibility with deployed proxy. This
     *      value is not used by any fee logic in this contract.
     *      See OmniPrivacyBridge for actual fee management.
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
     * @notice Instantly enable privacy features
     * @dev Only admin can enable. Enabling privacy does not require
     *      a timelock because it does not put user funds at risk.
     *      Disabling privacy requires the timelock flow below.
     */
    function enablePrivacy()
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        privacyEnabled = true;
        emit PrivacyStatusChanged(true);
    }

    /**
     * @notice Propose disabling privacy (starts 7-day timelock)
     * @dev ATK-H07 fix: Privacy cannot be disabled instantly.
     *      Admin must propose, wait 7 days, then execute. This
     *      gives users time to convertToPublic() and exit their
     *      private positions before emergency recovery becomes
     *      possible. Enabling privacy remains instant.
     */
    function proposePrivacyDisable()
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        privacyDisableScheduledAt = // solhint-disable-line not-rely-on-time
            block.timestamp + PRIVACY_DISABLE_DELAY;
        emit PrivacyDisableProposed(privacyDisableScheduledAt);
    }

    /**
     * @notice Execute privacy disable after timelock delay
     * @dev Can only be called after PRIVACY_DISABLE_DELAY has
     *      elapsed since proposePrivacyDisable() was called.
     */
    function executePrivacyDisable()
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (privacyDisableScheduledAt == 0) {
            revert NoPendingChange();
        }
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp < privacyDisableScheduledAt) {
            revert TimelockActive();
        }
        privacyEnabled = false;
        delete privacyDisableScheduledAt;
        emit PrivacyDisabled();
    }

    /**
     * @notice Cancel a pending privacy disable proposal
     * @dev Allows admin to abort the privacy disable before the
     *      timelock expires.
     */
    function cancelPrivacyDisable()
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        delete privacyDisableScheduledAt;
        emit PrivacyDisableCancelled();
    }

    /**
     * @notice Emergency recover private balance when MPC is
     *         unavailable
     * @dev Only callable by admin when privacy is disabled. Uses
     * the shadow ledger to determine the user's recoverable balance.
     * Mints the scaled-up public amount back to the user.
     *
     * L-01/L-02: Enforces MAX_SUPPLY cap on the mint as
     * defense-in-depth, even though the recovered amounts correspond
     * to previously burned tokens.
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

        // Scale back to 18-decimal public amount
        uint256 publicAmount =
            scaledBalance * PRIVACY_SCALING_FACTOR;

        // L-01: Defense-in-depth MAX_SUPPLY check
        if (totalSupply() + publicAmount > MAX_SUPPLY) {
            revert ExceedsMaxSupply();
        }

        _mint(user, publicAmount);

        emit EmergencyPrivateRecovery(user, publicAmount);
    }

    /**
     * @notice Mint new public tokens
     * @dev Only MINTER_ROLE can mint. Enforces MAX_SUPPLY cap as
     *      defense-in-depth against compromised minter keys.
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

    /**
     * @notice Permanently remove upgrade capability (one-way,
     *         irreversible)
     * @dev Can only be called by admin (through timelock). Once
     *      ossified, the contract can never be upgraded again.
     */
    function ossify() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _ossified = true;
        emit ContractOssified(address(this));
    }

    // ====================================================================
    // EXTERNAL NON-VIEW QUERY FUNCTIONS
    // ====================================================================

    /**
     * @notice Get decrypted private balance (account owner only)
     * @dev ATK-H05 fix: Only the account owner can decrypt their own
     *      balance. The previous admin override was REMOVED because it
     *      allowed any admin to silently view any user's private
     *      balance, defeating the purpose of privacy. Admins who need
     *      to verify balances for compliance should use off-chain
     *      processes with user consent.
     *
     *      Not a view function due to MPC decrypt operations.
     *      Returns the 18-decimal public-equivalent amount.
     *
     * @param account Address to query (must equal msg.sender)
     * @return balance Decrypted balance scaled to 18 decimals
     */
    function decryptedPrivateBalanceOf(
        address account
    ) external returns (uint256 balance) {
        if (!privacyEnabled) return 0;
        // ATK-H05: Only the account owner can decrypt
        if (msg.sender != account) revert OnlyAccountOwner();

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
     * @dev VESTIGIAL: Retained for storage layout compatibility.
     *      This value is not used by any fee logic in this contract.
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
     * @notice Authorize contract upgrades (UUPS pattern)
     * @dev Only admin can authorize upgrades to new implementation.
     *      Reverts if contract is ossified.
     *      The newImplementation address is validated by
     *      UUPSUpgradeable._upgradeToAndCallUUPS which checks
     *      ERC1967 implementation slot consistency.
     * @param newImplementation Address of new implementation contract
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
