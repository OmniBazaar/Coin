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
 * @title PrivateWETH
 * @author OmniCoin Development Team
 * @notice Privacy-preserving WETH wrapper using COTI V2 MPC
 * @dev Wraps real WETH tokens into MPC-encrypted private balances
 *      (pWETH) using COTI V2 garbled circuits. WETH uses 18 decimals;
 *      amounts are scaled down by 1e12 for MPC storage (6-decimal
 *      precision in MPC). Scaling factor matches PrivateOmniCoin.
 *
 * Token custody model:
 * - bridgeMint: Receives real WETH via safeTransferFrom and credits
 *   the recipient's publicBalances mapping.
 * - bridgeBurn: Debits the user's publicBalances and transfers real
 *   WETH back via safeTransfer.
 * - convertToPrivate: Debits publicBalances (full 18-dec amount),
 *   scales to 6-dec, creates encrypted MPC balance. Dust (remainder
 *   after scaling) is tracked in dustBalances for user refund.
 * - convertToPublic: Decrypts MPC balance, scales back to 18-dec,
 *   and credits publicBalances.
 *
 * Scaling precision:
 * - Maximum rounding dust per conversion: 999,999,999,999 wei
 *   (~0.000000999999 ETH, ~$0.002 at $2000/ETH).
 * - Minimum convertible amount: 1e12 wei (0.000001 ETH).
 * - Dust is tracked per user and refundable via claimDust().
 *
 * Max private balance: type(uint64).max * 1e12 = ~18,446 ETH
 * (sufficient for all practical DEX trades).
 *
 * Features:
 * - Real WETH custody via SafeERC20 transfers
 * - Per-user public balance tracking
 * - Dust tracking and refund mechanism
 * - Public to private conversion (scales 18 -> 6 decimals)
 * - Private to public conversion (scales 6 -> 18 decimals)
 * - Privacy-preserving transfers (encrypted amounts)
 * - Shadow ledger for emergency recovery (scaled units)
 * - Privacy toggle with auto-detection of COTI chains
 * - Emergency recovery function using shadow ledger
 * - Pausable for emergency stops
 * - UUPS upgradeable with ossification
 */
contract PrivateWETH is
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

    /// @notice Scaling factor: 18 decimals to 6 decimals for MPC
    /// @dev WETH amounts divided by 1e12 before MPC encryption.
    ///      Maximum rounding dust per conversion: 999,999,999,999 wei.
    ///      Minimum convertible amount: 1e12 wei (0.000001 ETH).
    uint256 public constant SCALING_FACTOR = 1e12;

    /// @notice Token name for wallet/explorer display
    string public constant TOKEN_NAME = "Private WETH";

    /// @notice Token symbol for wallet/explorer display
    string public constant TOKEN_SYMBOL = "pWETH";

    /// @notice Token decimals (public representation, matches WETH)
    uint8 public constant TOKEN_DECIMALS = 18;

    // ====================================================================
    // STATE VARIABLES
    // ====================================================================

    /// @notice The underlying WETH token contract held in custody
    /// @dev Set once during initialization; immutable by convention
    IERC20 public underlyingToken;

    /// @notice Encrypted private balances (6-decimal precision)
    mapping(address => ctUint64) private encryptedBalances;

    /// @notice Total public supply (bridged in, 18-decimal units)
    uint256 public totalPublicSupply;

    /// @notice Per-user public balance tracking for bridge deposits
    /// @dev Credited by bridgeMint (18-dec), debited by
    ///      convertToPrivate and bridgeBurn.
    mapping(address => uint256) public publicBalances;

    /// @notice Shadow ledger for emergency recovery (scaled units)
    /// @dev Tracks deposits in 6-decimal MPC-scaled units. Only
    ///      deposits via convertToPrivate are tracked; amounts
    ///      received via privateTransfer are NOT recoverable.
    mapping(address => uint256) private _shadowLedger;

    /// @notice Accumulated dust per user from scaling truncation
    /// @dev Dust = amount - (scaledAmount * SCALING_FACTOR) during
    ///      convertToPrivate. Users can claim via claimDust().
    mapping(address => uint256) public dustBalances;

    /// @notice Whether privacy features are enabled on this network
    /// @dev Must be true for MPC operations. Set during initialize
    ///      via auto-detection, or toggled by admin.
    bool public privacyEnabled;

    /// @notice Whether contract is permanently non-upgradeable
    bool private _ossified;

    /// @dev Storage gap for future upgrades.
    /// Current state variables: 9 (underlyingToken, encryptedBalances,
    /// totalPublicSupply, publicBalances, _shadowLedger, dustBalances,
    /// privacyEnabled, _ossified, + inherited).
    /// Gap size: 50 - 9 = 41 slots reserved.
    /// When adding new state variables, decrease __gap by the same
    /// count. Track gap changes independently from sibling contracts
    /// (PrivateUSDC, PrivateWBTC).
    uint256[41] private __gap;

    // ====================================================================
    // EVENTS
    // ====================================================================

    /* solhint-disable gas-indexed-events */

    /// @notice Emitted when tokens are bridged in
    /// @param to Recipient address
    /// @param amount Amount in wei (18 decimals)
    event BridgeMint(address indexed to, uint256 amount);

    /// @notice Emitted when tokens are bridged out
    /// @param from Sender address
    /// @param amount Amount in wei (18 decimals)
    event BridgeBurn(address indexed from, uint256 amount);

    /// @notice Emitted when converted to private
    /// @param user User address
    /// @param publicAmount Amount in wei (18 decimals)
    event ConvertedToPrivate(
        address indexed user, uint256 publicAmount
    );

    /// @notice Emitted when converted to public
    /// @param user User address
    /// @param publicAmount Amount in wei (18 decimals)
    event ConvertedToPublic(
        address indexed user, uint256 publicAmount
    );

    /// @notice Emitted on private transfer (amount hidden)
    /// @param from Sender address
    /// @param to Recipient address
    event PrivateTransfer(
        address indexed from,
        address indexed to
    );

    /// @notice Emitted when dust is claimed by a user
    /// @param user User address
    /// @param amount Dust amount in wei
    event DustClaimed(address indexed user, uint256 amount);

    /// @notice Emitted when privacy features are enabled/disabled
    /// @param enabled Whether privacy is now enabled
    event PrivacyStatusChanged(bool indexed enabled);

    /// @notice Emitted when an emergency private balance recovery occurs
    /// @param user Address whose private balance was recovered
    /// @param publicAmount Amount credited (18-decimal)
    event EmergencyPrivateRecovery(
        address indexed user, uint256 publicAmount
    );

    /// @notice Emitted when permanently ossified
    /// @param contractAddress This contract address
    event ContractOssified(address indexed contractAddress);

    /* solhint-enable gas-indexed-events */

    // ====================================================================
    // CUSTOM ERRORS
    // ====================================================================

    /// @notice Thrown when amount is zero
    error ZeroAmount();

    /// @notice Thrown when address is zero
    error ZeroAddress();

    /// @notice Thrown when amount exceeds uint64 after scaling
    error AmountTooLarge();

    /// @notice Thrown when insufficient private balance
    error InsufficientPrivateBalance();

    /// @notice Thrown when insufficient public balance
    error InsufficientPublicBalance();

    /// @notice Thrown when sender equals recipient
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

    /// @notice Thrown when user has no dust to claim
    error NoDustToClaim();

    // ====================================================================
    // CONSTRUCTOR & INITIALIZATION
    // ====================================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize PrivateWETH with admin and underlying token
     * @dev Sets up access control, pausable, reentrancy guard, and
     *      UUPS. Auto-detects COTI chain for privacy availability.
     * @param admin Admin address for role management
     * @param _underlyingToken Address of the WETH token contract
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
     * @notice Mint tokens from bridge deposit with real WETH custody
     * @dev Transfers WETH from msg.sender (bridge) into this contract
     *      and credits the recipient's publicBalances. Requires prior
     *      WETH approval from msg.sender to this contract.
     * @param to Recipient address
     * @param amount Amount in wei (18 decimals)
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
     * @notice Burn tokens for bridge withdrawal with real WETH release
     * @dev Debits the user's publicBalances and transfers real WETH
     *      to the specified address.
     * @param from Address to burn from (must have sufficient balance)
     * @param amount Amount in wei (18 decimals)
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
     * @notice Convert public WETH to private pWETH
     * @dev Scales 18 decimals down to 6 decimals for MPC storage.
     *      Dust (remainder after integer division by SCALING_FACTOR)
     *      is tracked in dustBalances and refundable via claimDust().
     *      Uses checkedAdd for MPC overflow safety.
     * @param amount Amount of WETH in wei (18 decimals)
     */
    function convertToPrivate(
        uint256 amount
    ) external nonReentrant whenNotPaused {
        if (!privacyEnabled) revert PrivacyNotAvailable();
        if (amount == 0) revert ZeroAmount();
        if (amount > publicBalances[msg.sender]) {
            revert InsufficientPublicBalance();
        }

        // Scale down: 18 decimals -> 6 decimals
        uint256 scaledAmount = amount / SCALING_FACTOR;
        if (scaledAmount == 0) revert ZeroAmount();
        if (scaledAmount > type(uint64).max) {
            revert AmountTooLarge();
        }

        // Track dust from scaling truncation
        uint256 usedAmount = scaledAmount * SCALING_FACTOR;
        uint256 dust = amount - usedAmount;

        // Debit the actual amount used (excluding refundable dust)
        publicBalances[msg.sender] -= usedAmount;
        totalPublicSupply -= usedAmount;

        // Track dust for later refund
        if (dust > 0) {
            dustBalances[msg.sender] += dust;
        }

        // Encrypt and add to balance with overflow protection
        gtUint64 gtAmount = MpcCore.setPublic64(
            uint64(scaledAmount)
        );
        gtUint64 gtCurrent = MpcCore.onBoard(
            encryptedBalances[msg.sender]
        );
        gtUint64 gtNew = MpcCore.checkedAdd(gtCurrent, gtAmount);
        encryptedBalances[msg.sender] = MpcCore.offBoard(gtNew);

        // Shadow ledger (scaled units)
        _shadowLedger[msg.sender] += scaledAmount;

        emit ConvertedToPrivate(msg.sender, usedAmount);
    }

    /**
     * @notice Convert private pWETH back to public WETH
     * @dev Decrypts MPC amount and scales back to 18 decimals.
     *      Credits publicBalances with the scaled-up amount.
     * @param encryptedAmount Encrypted amount (6-decimal precision)
     */
    function convertToPublic(
        gtUint64 encryptedAmount
    ) external nonReentrant whenNotPaused {
        if (!privacyEnabled) revert PrivacyNotAvailable();

        gtUint64 gtBalance = MpcCore.onBoard(
            encryptedBalances[msg.sender]
        );
        gtBool hasSufficient = MpcCore.ge(
            gtBalance, encryptedAmount
        );
        if (!MpcCore.decrypt(hasSufficient)) {
            revert InsufficientPrivateBalance();
        }

        gtUint64 gtNew = MpcCore.sub(gtBalance, encryptedAmount);
        encryptedBalances[msg.sender] = MpcCore.offBoard(gtNew);

        uint64 plainAmount = MpcCore.decrypt(encryptedAmount);
        if (plainAmount == 0) revert ZeroAmount();

        // Scale back to 18 decimals
        uint256 publicAmount =
            uint256(plainAmount) * SCALING_FACTOR;

        // Credit public balance
        publicBalances[msg.sender] += publicAmount;
        totalPublicSupply += publicAmount;

        // Update shadow ledger
        if (
            uint256(plainAmount) > _shadowLedger[msg.sender]
        ) {
            _shadowLedger[msg.sender] = 0;
        } else {
            _shadowLedger[msg.sender] -= uint256(plainAmount);
        }

        emit ConvertedToPublic(msg.sender, publicAmount);
    }

    /**
     * @notice Claim accumulated dust from scaling truncation
     * @dev Dust is the sub-SCALING_FACTOR remainder from each
     *      convertToPrivate call. Credits publicBalances.
     */
    function claimDust() external nonReentrant {
        uint256 dust = dustBalances[msg.sender];
        if (dust == 0) revert NoDustToClaim();

        dustBalances[msg.sender] = 0;
        publicBalances[msg.sender] += dust;
        totalPublicSupply += dust;

        emit DustClaimed(msg.sender, dust);
    }

    // ====================================================================
    // PRIVATE TRANSFER
    // ====================================================================

    /**
     * @notice Transfer private pWETH to another address
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

        gtUint64 gtSender = MpcCore.onBoard(
            encryptedBalances[msg.sender]
        );
        gtBool hasSufficient = MpcCore.ge(
            gtSender, encryptedAmount
        );
        if (!MpcCore.decrypt(hasSufficient)) {
            revert InsufficientPrivateBalance();
        }

        gtUint64 gtNewSender = MpcCore.sub(
            gtSender, encryptedAmount
        );
        encryptedBalances[msg.sender] =
            MpcCore.offBoard(gtNewSender);

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
     *      shadow ledger to determine the user's recoverable balance,
     *      scales it back to 18 decimals, and credits publicBalances.
     *
     * Limitations: Only deposits via convertToPrivate are recoverable.
     * Amounts received via privateTransfer are NOT tracked in the
     * shadow ledger and cannot be recovered this way.
     *
     * @param user Address to recover balance for
     */
    function emergencyRecoverPrivateBalance(
        address user
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (privacyEnabled) revert PrivacyMustBeDisabled();
        if (user == address(0)) revert ZeroAddress();

        uint256 scaledBalance = _shadowLedger[user];
        if (scaledBalance == 0) revert NoBalanceToRecover();

        // Clear the shadow ledger entry
        _shadowLedger[user] = 0;

        // Scale back to 18-decimal and credit public balance
        uint256 publicAmount = scaledBalance * SCALING_FACTOR;
        publicBalances[user] += publicAmount;
        totalPublicSupply += publicAmount;

        emit EmergencyPrivateRecovery(user, publicAmount);
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
     *      tracking that could erode privacy guarantees.
     * @param account Address to query
     * @return Encrypted balance (ctUint64, 6-decimal precision)
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
     * @dev Restricted to prevent leaking plaintext deposit amounts.
     *      Only tracks deposits via convertToPrivate (scaled units).
     * @param account Address to query
     * @return Shadow ledger balance in MPC-scaled units (6 decimals)
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
     * @return Number of decimals (18, matching WETH)
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
