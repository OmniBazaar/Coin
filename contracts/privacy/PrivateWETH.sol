// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {
    AccessControlUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
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
 * @title PrivateWETH
 * @author OmniCoin Development Team
 * @notice Privacy-preserving WETH wrapper using COTI V2 MPC
 * @dev WETH uses 18 decimals; scaled down by 1e12 for MPC storage
 *      (6-decimal precision in MPC). Scaling factor matches
 *      PrivateOmniCoin.sol.
 *
 * Max private balance: type(uint64).max * 1e12 = ~18,446 ETH
 * (sufficient for all practical DEX trades).
 *
 * Features:
 * - Bridge mint/burn for cross-chain WETH deposits
 * - Public to private conversion (scales 18 -> 6 decimals)
 * - Private to public conversion (scales 6 -> 18 decimals)
 * - Privacy-preserving transfers
 * - Shadow ledger for emergency recovery
 * - UUPS upgradeable with ossification
 */
contract PrivateWETH is
    Initializable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    using MpcCore for gtUint64;
    using MpcCore for ctUint64;
    using MpcCore for gtBool;

    // ====================================================================
    // CONSTANTS
    // ====================================================================

    /// @notice Role identifier for bridge operations
    bytes32 public constant BRIDGE_ROLE = keccak256("BRIDGE_ROLE");

    /// @notice Scaling factor: 18 decimals to 6 decimals for MPC
    uint256 public constant SCALING_FACTOR = 1e12;

    /// @notice Token name
    string public constant TOKEN_NAME = "Private WETH";

    /// @notice Token symbol
    string public constant TOKEN_SYMBOL = "pWETH";

    /// @notice Token decimals (public representation)
    uint8 public constant TOKEN_DECIMALS = 18;

    // ====================================================================
    // STATE VARIABLES
    // ====================================================================

    /// @notice Encrypted private balances (6-decimal precision)
    mapping(address => ctUint64) private encryptedBalances;

    /// @notice Total public supply (bridged in)
    uint256 public totalPublicSupply;

    /// @notice Shadow ledger for emergency recovery (scaled units)
    mapping(address => uint256) public privateDepositLedger;

    /// @notice Whether contract is ossified
    bool private _ossified;

    /// @dev Storage gap for future upgrades
    uint256[46] private __gap;

    // ====================================================================
    // EVENTS
    // ====================================================================

    /// @notice Emitted when tokens are bridged in
    /// @param to Recipient
    /// @param amount Amount (18 decimals)
    event BridgeMint(address indexed to, uint256 indexed amount);

    /// @notice Emitted when tokens are bridged out
    /// @param from Sender
    /// @param amount Amount (18 decimals)
    event BridgeBurn(address indexed from, uint256 indexed amount);

    /// @notice Emitted when converted to private
    /// @param user User address
    /// @param publicAmount Amount (18 decimals)
    event ConvertedToPrivate(
        address indexed user,
        uint256 indexed publicAmount
    );

    /// @notice Emitted when converted to public
    /// @param user User address
    /// @param publicAmount Amount (18 decimals)
    event ConvertedToPublic(
        address indexed user,
        uint256 indexed publicAmount
    );

    /// @notice Emitted on private transfer
    /// @param from Sender
    /// @param to Recipient
    event PrivateTransfer(
        address indexed from,
        address indexed to
    );

    /// @notice Emitted when permanently ossified
    /// @param contractAddress This contract
    event ContractOssified(address indexed contractAddress);

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

    // ====================================================================
    // CONSTRUCTOR & INITIALIZATION
    // ====================================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize PrivateWETH
     * @param admin Admin address for role management
     */
    function initialize(address admin) external initializer {
        if (admin == address(0)) revert ZeroAddress();

        __AccessControl_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(BRIDGE_ROLE, admin);
    }

    // ====================================================================
    // BRIDGE FUNCTIONS
    // ====================================================================

    /**
     * @notice Mint tokens from bridge deposit
     * @param to Recipient address
     * @param amount Amount in wei (18 decimals)
     */
    function bridgeMint(
        address to,
        uint256 amount
    ) external onlyRole(BRIDGE_ROLE) {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        totalPublicSupply += amount;
        emit BridgeMint(to, amount);
    }

    /**
     * @notice Burn tokens for bridge withdrawal
     * @param from Address to burn from
     * @param amount Amount in wei (18 decimals)
     */
    function bridgeBurn(
        address from,
        uint256 amount
    ) external onlyRole(BRIDGE_ROLE) {
        if (from == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (amount > totalPublicSupply) {
            revert InsufficientPublicBalance();
        }

        totalPublicSupply -= amount;
        emit BridgeBurn(from, amount);
    }

    // ====================================================================
    // PRIVACY CONVERSION
    // ====================================================================

    /**
     * @notice Convert public WETH to private pWETH
     * @dev Scales 18 decimals down to 6 decimals for MPC storage.
     *      Rounding dust (up to ~0.000001 ETH) is acceptable.
     * @param amount Amount of WETH in wei (18 decimals)
     */
    function convertToPrivate(
        uint256 amount
    ) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        // Scale down: 18 decimals -> 6 decimals
        uint256 scaledAmount = amount / SCALING_FACTOR;
        if (scaledAmount == 0) revert ZeroAmount();
        if (scaledAmount > type(uint64).max) revert AmountTooLarge();

        // Encrypt and add to balance
        gtUint64 gtAmount = MpcCore.setPublic64(
            uint64(scaledAmount)
        );
        gtUint64 gtCurrent = MpcCore.onBoard(
            encryptedBalances[msg.sender]
        );
        gtUint64 gtNew = MpcCore.add(gtCurrent, gtAmount);
        encryptedBalances[msg.sender] = MpcCore.offBoard(gtNew);

        // Shadow ledger (scaled units)
        privateDepositLedger[msg.sender] += scaledAmount;

        emit ConvertedToPrivate(msg.sender, amount);
    }

    /**
     * @notice Convert private pWETH back to public WETH
     * @param encryptedAmount Encrypted amount (6-decimal precision)
     */
    function convertToPublic(
        gtUint64 encryptedAmount
    ) external nonReentrant {
        gtUint64 gtBalance = MpcCore.onBoard(
            encryptedBalances[msg.sender]
        );
        gtBool hasSufficient = MpcCore.ge(gtBalance, encryptedAmount);
        if (!MpcCore.decrypt(hasSufficient)) {
            revert InsufficientPrivateBalance();
        }

        gtUint64 gtNew = MpcCore.sub(gtBalance, encryptedAmount);
        encryptedBalances[msg.sender] = MpcCore.offBoard(gtNew);

        uint64 plainAmount = MpcCore.decrypt(encryptedAmount);
        if (plainAmount == 0) revert ZeroAmount();

        // Scale back to 18 decimals
        uint256 publicAmount = uint256(plainAmount) * SCALING_FACTOR;

        // Update shadow ledger
        if (uint256(plainAmount) > privateDepositLedger[msg.sender]) {
            privateDepositLedger[msg.sender] = 0;
        } else {
            privateDepositLedger[msg.sender] -= uint256(plainAmount);
        }

        emit ConvertedToPublic(msg.sender, publicAmount);
    }

    // ====================================================================
    // PRIVATE TRANSFER
    // ====================================================================

    /**
     * @notice Transfer private pWETH to another address
     * @param to Recipient address
     * @param encryptedAmount Encrypted amount to transfer
     */
    function privateTransfer(
        address to,
        gtUint64 encryptedAmount
    ) external nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (to == msg.sender) revert SelfTransfer();

        gtUint64 gtSender = MpcCore.onBoard(
            encryptedBalances[msg.sender]
        );
        gtBool hasSufficient = MpcCore.ge(gtSender, encryptedAmount);
        if (!MpcCore.decrypt(hasSufficient)) {
            revert InsufficientPrivateBalance();
        }

        gtUint64 gtNewSender = MpcCore.sub(gtSender, encryptedAmount);
        encryptedBalances[msg.sender] = MpcCore.offBoard(gtNewSender);

        gtUint64 gtRecipient = MpcCore.onBoard(
            encryptedBalances[to]
        );
        gtUint64 gtNewRecipient = MpcCore.add(
            gtRecipient, encryptedAmount
        );
        encryptedBalances[to] = MpcCore.offBoard(gtNewRecipient);

        emit PrivateTransfer(msg.sender, to);
    }

    // ====================================================================
    // VIEW FUNCTIONS
    // ====================================================================

    /**
     * @notice Get encrypted private balance
     * @param account Address to query
     * @return Encrypted balance (ctUint64, 6-decimal precision)
     */
    function privateBalanceOf(
        address account
    ) external view returns (ctUint64) {
        return encryptedBalances[account];
    }

    // ====================================================================
    // ADMIN & UPGRADE
    // ====================================================================

    /**
     * @notice Permanently disable upgrades
     */
    function ossify() external onlyRole(DEFAULT_ADMIN_ROLE) { // solhint-disable-line ordering
        _ossified = true;
        emit ContractOssified(address(this));
    }

    /**
     * @notice Check if ossified
     * @return True if no more upgrades
     */
    function isOssified() external view returns (bool) {
        return _ossified;
    }

    /**
     * @notice UUPS upgrade authorization
     * @param newImplementation New implementation address
     */
    function _authorizeUpgrade(
        address newImplementation // solhint-disable-line no-unused-vars
    ) internal override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_ossified) revert ContractIsOssified();
    }
}
