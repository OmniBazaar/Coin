// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {
    AccessControlUpgradeable
} from
    "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {
    ReentrancyGuardUpgradeable
} from
    "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {
    PausableUpgradeable
} from
    "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {
    Initializable
} from
    "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    UUPSUpgradeable
} from
    "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {
    IERC20
} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    MpcCore,
    gtUint64,
    ctUint64,
    gtBool
} from "../../coti-contracts/contracts/utils/mpc/MpcCore.sol";

/**
 * @title PrivateUSDC
 * @author OmniCoin Development Team
 * @notice Privacy-preserving USDC wrapper using COTI V2 MPC
 * @dev Wraps real USDC tokens into MPC-encrypted private balances
 *      (pUSDC) using COTI V2 garbled circuits. USDC uses 6 decimals
 *      natively, matching MPC uint64 precision with no scaling needed
 *      (SCALING_FACTOR = 1, identity).
 *
 * Token custody model:
 * - bridgeMint: Receives real USDC via safeTransferFrom and credits
 *   the recipient's publicBalances mapping.
 * - bridgeBurn: Debits the user's publicBalances and transfers real
 *   USDC back via safeTransfer.
 * - convertToPrivate: Debits publicBalances and creates encrypted
 *   MPC balance.
 * - convertToPublic: Decrypts MPC balance and credits publicBalances.
 *
 * Max private balance: type(uint64).max / 1e6 = ~18.4 trillion USDC
 * (effectively unlimited for practical purposes).
 *
 * Features:
 * - Real USDC custody via SafeERC20 transfers
 * - Per-user public balance tracking
 * - Public to private conversion (no fee; bridge charges 0.5%)
 * - Private to public conversion
 * - Privacy-preserving transfers (encrypted amounts)
 * - Shadow ledger for emergency recovery when MPC unavailable
 * - Privacy toggle with auto-detection of COTI chains
 * - Emergency recovery function using shadow ledger
 * - Pausable for emergency stops
 * - UUPS upgradeable with ossification
 */
contract PrivateUSDC is
    Initializable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    using MpcCore for gtUint64;
    using MpcCore for ctUint64;
    using SafeERC20 for IERC20;

    // ====================================================================
    // CONSTANTS
    // ====================================================================

    /// @notice Role identifier for bridge operations (mint/burn)
    bytes32 public constant BRIDGE_ROLE = keccak256("BRIDGE_ROLE");

    /// @notice Scaling factor: USDC 6 decimals to MPC 6 decimals
    /// @dev Value is 1 (identity) because USDC natively uses 6 decimals,
    ///      matching MPC uint64 precision without any conversion.
    ///      Exists for API parity with PrivateWETH (1e12) and
    ///      PrivateWBTC (1e2). Not used in any calculation.
    uint256 public constant SCALING_FACTOR = 1;

    /// @notice Token name for wallet/explorer display
    string public constant TOKEN_NAME = "Private USDC";

    /// @notice Token symbol for wallet/explorer display
    string public constant TOKEN_SYMBOL = "pUSDC";

    /// @notice Token decimals (matches USDC native 6 decimals)
    uint8 public constant TOKEN_DECIMALS = 6;

    // ====================================================================
    // STATE VARIABLES
    // ====================================================================

    /// @notice The underlying USDC token contract held in custody
    /// @dev Set once during initialization; immutable by convention
    IERC20 public underlyingToken;

    /// @notice Encrypted private balances (6-decimal precision)
    mapping(address => ctUint64) private encryptedBalances;

    /// @notice Total public supply (bridged in, not yet privatized)
    uint256 public totalPublicSupply;

    /// @notice Per-user public balance tracking for bridge deposits
    /// @dev Credited by bridgeMint, debited by convertToPrivate
    ///      and bridgeBurn. Ensures users can only convert tokens
    ///      that were actually deposited for them.
    mapping(address => uint256) public publicBalances;

    /// @notice Shadow ledger for emergency recovery (native units)
    /// @dev Tracks total private deposits per user. Used by
    ///      emergencyRecoverPrivateBalance when MPC is unavailable.
    ///      Only deposits via convertToPrivate are tracked; amounts
    ///      received via privateTransfer are NOT recoverable.
    mapping(address => uint256) private _shadowLedger;

    /// @notice Whether privacy features are enabled on this network
    /// @dev Must be true for MPC operations. Set during initialize
    ///      via auto-detection, or toggled by admin.
    bool public privacyEnabled;

    /// @notice Whether contract is permanently non-upgradeable
    bool private _ossified;

    /// @dev Storage gap for future upgrades.
    /// Current state variables: 7 (underlyingToken, encryptedBalances,
    /// totalPublicSupply, publicBalances, _shadowLedger,
    /// privacyEnabled, _ossified).
    /// Gap size: 50 - 7 = 43 slots reserved.
    uint256[43] private __gap;

    // ====================================================================
    // EVENTS
    // ====================================================================

    /* solhint-disable gas-indexed-events */

    /// @notice Emitted when tokens are bridged in (minted)
    /// @param to Recipient address
    /// @param amount Amount of USDC minted (6-decimal units)
    event BridgeMint(address indexed to, uint256 amount);

    /// @notice Emitted when tokens are bridged out (burned)
    /// @param from Sender address
    /// @param amount Amount of USDC burned (6-decimal units)
    event BridgeBurn(address indexed from, uint256 amount);

    /// @notice Emitted when tokens converted to private mode
    /// @param user User address
    /// @param amount Amount converted (6-decimal USDC units)
    event ConvertedToPrivate(
        address indexed user, uint256 amount
    );

    /// @notice Emitted when tokens converted back to public
    /// @param user User address
    /// @param amount Amount converted (6-decimal USDC units)
    event ConvertedToPublic(
        address indexed user, uint256 amount
    );

    /// @notice Emitted on private transfer (amount hidden)
    /// @param from Sender address
    /// @param to Recipient address
    event PrivateTransfer(
        address indexed from,
        address indexed to
    );

    /// @notice Emitted when privacy features are enabled/disabled
    /// @param enabled Whether privacy is now enabled
    event PrivacyStatusChanged(bool indexed enabled);

    /// @notice Emitted when an emergency private balance recovery occurs
    /// @param user Address whose private balance was recovered
    /// @param amount Amount credited back to publicBalances
    event EmergencyPrivateRecovery(
        address indexed user, uint256 amount
    );

    /// @notice Emitted when the contract is permanently ossified
    /// @param contractAddress Address of this contract
    event ContractOssified(address indexed contractAddress);

    /* solhint-enable gas-indexed-events */

    // ====================================================================
    // CUSTOM ERRORS
    // ====================================================================

    /// @notice Thrown when amount is zero
    error ZeroAmount();

    /// @notice Thrown when address is zero
    error ZeroAddress();

    /// @notice Thrown when amount exceeds uint64 max
    error AmountTooLarge();

    /// @notice Thrown when insufficient private balance
    error InsufficientPrivateBalance();

    /// @notice Thrown when insufficient public balance
    error InsufficientPublicBalance();

    /// @notice Thrown when sender and recipient are the same
    error SelfTransfer();

    /// @notice Thrown when contract is ossified
    error ContractIsOssified();

    /// @notice Thrown when privacy features are not available
    error PrivacyNotAvailable();

    /// @notice Thrown when privacy must be disabled for this operation
    error PrivacyMustBeDisabled();

    /// @notice Thrown when caller is not authorized
    error Unauthorized();

    /// @notice Thrown when shadow ledger has no balance to recover
    error NoBalanceToRecover();

    // ====================================================================
    // CONSTRUCTOR & INITIALIZATION
    // ====================================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize PrivateUSDC with admin and underlying token
     * @dev Sets up access control, pausable, reentrancy guard, and
     *      UUPS. Auto-detects COTI chain for privacy availability.
     * @param admin Admin address for role management
     * @param _underlyingToken Address of the USDC token contract
     */
    function initialize(
        address admin,
        address _underlyingToken
    ) external initializer {
        if (admin == address(0)) revert ZeroAddress();
        if (_underlyingToken == address(0)) revert ZeroAddress();

        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(BRIDGE_ROLE, admin);

        underlyingToken = IERC20(_underlyingToken);
        privacyEnabled = _detectPrivacyAvailability();
    }

    // ====================================================================
    // BRIDGE FUNCTIONS
    // ====================================================================

    /**
     * @notice Mint tokens from bridge deposit with real USDC custody
     * @dev Transfers USDC from msg.sender (bridge) into this contract
     *      and credits the recipient's publicBalances. Requires prior
     *      USDC approval from msg.sender to this contract.
     * @param to Recipient address
     * @param amount Amount in USDC units (6 decimals)
     */
    function bridgeMint(
        address to,
        uint256 amount
    ) external onlyRole(BRIDGE_ROLE) whenNotPaused {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        underlyingToken.safeTransferFrom(
            msg.sender, address(this), amount
        );

        publicBalances[to] += amount;
        totalPublicSupply += amount;

        emit BridgeMint(to, amount);
    }

    /**
     * @notice Burn tokens for bridge withdrawal with real USDC release
     * @dev Debits the user's publicBalances and transfers real USDC
     *      to the specified address.
     * @param from Address to burn from (must have sufficient balance)
     * @param amount Amount in USDC units (6 decimals)
     */
    function bridgeBurn(
        address from,
        uint256 amount
    ) external onlyRole(BRIDGE_ROLE) whenNotPaused {
        if (from == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (amount > publicBalances[from]) {
            revert InsufficientPublicBalance();
        }

        publicBalances[from] -= amount;
        totalPublicSupply -= amount;

        underlyingToken.safeTransfer(from, amount);

        emit BridgeBurn(from, amount);
    }

    // ====================================================================
    // PRIVACY CONVERSION
    // ====================================================================

    /**
     * @notice Convert public USDC to private pUSDC
     * @dev No scaling needed -- USDC is already 6 decimals matching
     *      MPC uint64 precision. Debits publicBalances and creates
     *      MPC-encrypted balance. Uses checkedAdd for overflow safety.
     * @param amount Amount of USDC to convert (6 decimals)
     */
    function convertToPrivate(
        uint256 amount
    ) external nonReentrant whenNotPaused {
        if (!privacyEnabled) revert PrivacyNotAvailable();
        if (amount == 0) revert ZeroAmount();
        if (amount > type(uint64).max) revert AmountTooLarge();
        if (amount > publicBalances[msg.sender]) {
            revert InsufficientPublicBalance();
        }

        // Debit public balance
        publicBalances[msg.sender] -= amount;
        totalPublicSupply -= amount;

        // Create encrypted amount
        gtUint64 gtAmount = MpcCore.setPublic64(uint64(amount));

        // Add to encrypted balance with overflow protection
        gtUint64 gtCurrent = MpcCore.onBoard(
            encryptedBalances[msg.sender]
        );
        gtUint64 gtNew = MpcCore.checkedAdd(gtCurrent, gtAmount);
        encryptedBalances[msg.sender] = MpcCore.offBoard(gtNew);

        // Update shadow ledger for emergency recovery
        _shadowLedger[msg.sender] += amount;

        emit ConvertedToPrivate(msg.sender, amount);
    }

    /**
     * @notice Convert private pUSDC back to public USDC
     * @dev Decrypts MPC amount and credits publicBalances. No scaling
     *      needed since USDC natively uses 6 decimals.
     * @param encryptedAmount Encrypted amount to convert
     */
    function convertToPublic(
        gtUint64 encryptedAmount
    ) external nonReentrant whenNotPaused {
        if (!privacyEnabled) revert PrivacyNotAvailable();

        // Verify sufficient balance
        gtUint64 gtBalance = MpcCore.onBoard(
            encryptedBalances[msg.sender]
        );
        gtBool hasSufficient = MpcCore.ge(
            gtBalance, encryptedAmount
        );
        if (!MpcCore.decrypt(hasSufficient)) {
            revert InsufficientPrivateBalance();
        }

        // Subtract from encrypted balance
        gtUint64 gtNew = MpcCore.sub(gtBalance, encryptedAmount);
        encryptedBalances[msg.sender] = MpcCore.offBoard(gtNew);

        // Decrypt to get public amount
        uint64 plainAmount = MpcCore.decrypt(encryptedAmount);
        if (plainAmount == 0) revert ZeroAmount();

        // Credit public balance
        uint256 publicAmount = uint256(plainAmount);
        publicBalances[msg.sender] += publicAmount;
        totalPublicSupply += publicAmount;

        // Update shadow ledger
        if (publicAmount > _shadowLedger[msg.sender]) {
            _shadowLedger[msg.sender] = 0;
        } else {
            _shadowLedger[msg.sender] -= publicAmount;
        }

        emit ConvertedToPublic(msg.sender, publicAmount);
    }

    // ====================================================================
    // PRIVATE TRANSFER
    // ====================================================================

    /**
     * @notice Transfer private pUSDC to another address
     * @dev Amount remains encrypted. Uses checkedAdd for recipient
     *      balance to prevent silent uint64 overflow. Shadow ledger
     *      is NOT updated for transfers (only deposits/withdrawals).
     * @param to Recipient address
     * @param encryptedAmount Encrypted amount to transfer
     */
    function privateTransfer(
        address to,
        gtUint64 encryptedAmount
    ) external nonReentrant whenNotPaused {
        if (!privacyEnabled) revert PrivacyNotAvailable();
        if (to == address(0)) revert ZeroAddress();
        if (to == msg.sender) revert SelfTransfer();

        // Verify sender balance
        gtUint64 gtSender = MpcCore.onBoard(
            encryptedBalances[msg.sender]
        );
        gtBool hasSufficient = MpcCore.ge(
            gtSender, encryptedAmount
        );
        if (!MpcCore.decrypt(hasSufficient)) {
            revert InsufficientPrivateBalance();
        }

        // Update sender balance
        gtUint64 gtNewSender = MpcCore.sub(
            gtSender, encryptedAmount
        );
        encryptedBalances[msg.sender] =
            MpcCore.offBoard(gtNewSender);

        // Update recipient balance with overflow protection
        gtUint64 gtRecipient = MpcCore.onBoard(
            encryptedBalances[to]
        );
        gtUint64 gtNewRecipient = MpcCore.checkedAdd(
            gtRecipient, encryptedAmount
        );
        encryptedBalances[to] =
            MpcCore.offBoard(gtNewRecipient);

        // Note: Shadow ledger is NOT updated for private transfers
        // because the amount is encrypted. Only deposits via
        // convertToPrivate are tracked. In emergency recovery,
        // amounts received via privateTransfer are not recoverable.

        emit PrivateTransfer(msg.sender, to);
    }

    // ====================================================================
    // ADMIN FUNCTIONS
    // ====================================================================

    /**
     * @notice Enable or disable privacy features
     * @dev Only admin can change. Disabling privacy is required
     *      before emergency recovery can be used.
     * @param enabled Whether to enable privacy
     */
    function setPrivacyEnabled(
        bool enabled
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        privacyEnabled = enabled;
        emit PrivacyStatusChanged(enabled);
    }

    /**
     * @notice Emergency recover private balance when MPC unavailable
     * @dev Only callable by admin when privacy is disabled. Uses the
     *      shadow ledger to determine the user's recoverable balance
     *      and credits it back to their publicBalances.
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

        uint256 balance = _shadowLedger[user];
        if (balance == 0) revert NoBalanceToRecover();

        // Clear the shadow ledger entry
        _shadowLedger[user] = 0;

        // Credit public balance (backed by USDC already in contract)
        publicBalances[user] += balance;
        totalPublicSupply += balance;

        emit EmergencyPrivateRecovery(user, balance);
    }

    /**
     * @notice Pause all state-changing operations
     * @dev Only admin can pause. Halts bridgeMint, bridgeBurn,
     *      convertToPrivate, convertToPublic, and privateTransfer.
     */
    function pause()
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _pause();
    }

    /**
     * @notice Unpause all operations
     * @dev Only admin can unpause.
     */
    function unpause()
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _unpause();
    }

    /**
     * @notice Permanently disable upgrades
     * @dev Once ossified, the contract can never be upgraded again.
     *      This is irreversible.
     */
    function ossify()
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _ossified = true;
        emit ContractOssified(address(this));
    }

    // ====================================================================
    // VIEW FUNCTIONS
    // ====================================================================

    /**
     * @notice Get encrypted private balance (owner or admin only)
     * @dev Restricted to prevent balance fingerprinting and change
     *      tracking that could erode privacy guarantees. Only the
     *      account owner or admin can query encrypted balances.
     * @param account Address to query
     * @return Encrypted balance (ctUint64)
     */
    function privateBalanceOf(
        address account
    ) external view returns (ctUint64) {
        if (
            msg.sender != account &&
            !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)
        ) {
            revert Unauthorized();
        }
        return encryptedBalances[account];
    }

    /**
     * @notice Get shadow ledger balance (owner or admin only)
     * @dev Restricted to prevent leaking plaintext deposit amounts
     *      that would undermine privacy. Only tracks direct deposits
     *      via convertToPrivate; not updated by privateTransfer.
     * @param account Address to query
     * @return Shadow ledger balance in USDC units (6 decimals)
     */
    function getShadowLedgerBalance(
        address account
    ) external view returns (uint256) {
        if (
            msg.sender != account &&
            !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)
        ) {
            revert Unauthorized();
        }
        return _shadowLedger[account];
    }

    /**
     * @notice Check if contract is permanently non-upgradeable
     * @return True if no more upgrades are possible
     */
    function isOssified() external view returns (bool) {
        return _ossified;
    }

    // ====================================================================
    // PURE FUNCTIONS
    // ====================================================================

    /**
     * @notice Returns the token name for wallet/explorer compatibility
     * @return Token name string
     */
    function name() external pure returns (string memory) {
        return TOKEN_NAME;
    }

    /**
     * @notice Returns the token symbol for wallet/explorer compatibility
     * @return Token symbol string
     */
    function symbol() external pure returns (string memory) {
        return TOKEN_SYMBOL;
    }

    /**
     * @notice Returns the token decimals for wallet/explorer compat
     * @return Number of decimals (6, matching USDC)
     */
    function decimals() external pure returns (uint8) {
        return TOKEN_DECIMALS;
    }

    // ====================================================================
    // INTERNAL FUNCTIONS
    // ====================================================================

    /**
     * @notice UUPS upgrade authorization check
     * @dev Reverts if contract is ossified or caller lacks admin role.
     * @param newImplementation New implementation address (unused)
     */
    function _authorizeUpgrade(
        address newImplementation // solhint-disable-line no-unused-vars
    ) internal override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_ossified) revert ContractIsOssified();
    }

    /**
     * @notice Detect if COTI MPC privacy is available on this chain
     * @dev Checks chain ID against known COTI and OmniCoin networks
     *      where the MPC precompile at address 0x64 exists.
     * @return available True if MPC operations are supported
     */
    function _detectPrivacyAvailability()
        private
        view
        returns (bool available)
    {
        uint256 id = block.chainid;
        available = (
            id == 13068200 || // COTI Devnet
            id == 7082400 ||  // COTI Testnet
            id == 7082 ||     // COTI Testnet (alt)
            id == 1353 ||     // COTI Mainnet
            id == 131313      // OmniCoin L1
        );
    }
}
