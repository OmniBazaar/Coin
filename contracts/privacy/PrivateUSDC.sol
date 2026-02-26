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
 * @title PrivateUSDC
 * @author OmniCoin Development Team
 * @notice Privacy-preserving USDC wrapper using COTI V2 MPC
 * @dev USDC uses 6 decimals natively, so the scaling factor is 1
 *      (no precision loss during MPC operations).
 *
 * Max private balance: type(uint64).max / 1e6 = ~18.4 trillion USDC
 * (effectively unlimited for practical purposes).
 *
 * Features:
 * - Bridge mint/burn for cross-chain deposits
 * - Public to private conversion (no fee here; bridge charges 0.5%)
 * - Private to public conversion
 * - Privacy-preserving transfers (encrypted amounts)
 * - Shadow ledger for emergency recovery
 * - UUPS upgradeable with ossification
 */
contract PrivateUSDC is
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

    /// @notice Role identifier for bridge operations (mint/burn)
    bytes32 public constant BRIDGE_ROLE = keccak256("BRIDGE_ROLE");

    /// @notice Scaling factor: USDC 6 decimals to MPC 6 decimals
    /// @dev No scaling needed since USDC natively uses 6 decimals
    uint256 public constant SCALING_FACTOR = 1;

    /// @notice Token name
    string public constant TOKEN_NAME = "Private USDC";

    /// @notice Token symbol
    string public constant TOKEN_SYMBOL = "pUSDC";

    /// @notice Token decimals (matches USDC)
    uint8 public constant TOKEN_DECIMALS = 6;

    // ====================================================================
    // STATE VARIABLES
    // ====================================================================

    /// @notice Encrypted private balances
    mapping(address => ctUint64) private encryptedBalances;

    /// @notice Total public supply (bridged in, not yet privatized)
    uint256 public totalPublicSupply;

    /// @notice Shadow ledger for emergency recovery
    mapping(address => uint256) public privateDepositLedger;

    /// @notice Whether contract is ossified
    bool private _ossified;

    /// @dev Storage gap for future upgrades
    uint256[46] private __gap;

    // ====================================================================
    // EVENTS
    // ====================================================================

    /// @notice Emitted when tokens are bridged in (minted)
    /// @param to Recipient address
    /// @param amount Amount minted
    event BridgeMint(address indexed to, uint256 indexed amount);

    /// @notice Emitted when tokens are bridged out (burned)
    /// @param from Sender address
    /// @param amount Amount burned
    event BridgeBurn(address indexed from, uint256 indexed amount);

    /// @notice Emitted when tokens converted to private mode
    /// @param user User address
    /// @param amount Amount converted (6-decimal USDC units)
    event ConvertedToPrivate(
        address indexed user,
        uint256 indexed amount
    );

    /// @notice Emitted when tokens converted back to public
    /// @param user User address
    /// @param amount Amount converted (6-decimal USDC units)
    event ConvertedToPublic(
        address indexed user,
        uint256 indexed amount
    );

    /// @notice Emitted on private transfer (amount hidden)
    /// @param from Sender address
    /// @param to Recipient address
    event PrivateTransfer(
        address indexed from,
        address indexed to
    );

    /// @notice Emitted when the contract is permanently ossified
    /// @param contractAddress Address of this contract
    event ContractOssified(address indexed contractAddress);

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

    // ====================================================================
    // CONSTRUCTOR & INITIALIZATION
    // ====================================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize PrivateUSDC
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
     * @param amount Amount in USDC units (6 decimals)
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
     * @param amount Amount in USDC units (6 decimals)
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
     * @notice Convert public USDC to private pUSDC
     * @dev No scaling needed — USDC is already 6 decimals.
     * @param amount Amount of USDC to convert (6 decimals)
     */
    function convertToPrivate(
        uint256 amount
    ) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (amount > type(uint64).max) revert AmountTooLarge();

        // Create encrypted amount
        gtUint64 gtAmount = MpcCore.setPublic64(uint64(amount));

        // Add to encrypted balance
        gtUint64 gtCurrent = MpcCore.onBoard(
            encryptedBalances[msg.sender]
        );
        gtUint64 gtNew = MpcCore.add(gtCurrent, gtAmount);
        encryptedBalances[msg.sender] = MpcCore.offBoard(gtNew);

        // Update shadow ledger
        privateDepositLedger[msg.sender] += amount;

        emit ConvertedToPrivate(msg.sender, amount);
    }

    /**
     * @notice Convert private pUSDC back to public USDC
     * @param encryptedAmount Encrypted amount to convert
     */
    function convertToPublic(
        gtUint64 encryptedAmount
    ) external nonReentrant {
        // Verify sufficient balance
        gtUint64 gtBalance = MpcCore.onBoard(
            encryptedBalances[msg.sender]
        );
        gtBool hasSufficient = MpcCore.ge(gtBalance, encryptedAmount);
        if (!MpcCore.decrypt(hasSufficient)) {
            revert InsufficientPrivateBalance();
        }

        // Subtract from encrypted balance
        gtUint64 gtNew = MpcCore.sub(gtBalance, encryptedAmount);
        encryptedBalances[msg.sender] = MpcCore.offBoard(gtNew);

        // Decrypt to get public amount
        uint64 plainAmount = MpcCore.decrypt(encryptedAmount);
        if (plainAmount == 0) revert ZeroAmount();

        // Update shadow ledger
        if (uint256(plainAmount) > privateDepositLedger[msg.sender]) {
            privateDepositLedger[msg.sender] = 0;
        } else {
            privateDepositLedger[msg.sender] -= uint256(plainAmount);
        }

        emit ConvertedToPublic(msg.sender, uint256(plainAmount));
    }

    // ====================================================================
    // PRIVATE TRANSFER
    // ====================================================================

    /**
     * @notice Transfer private pUSDC to another address
     * @param to Recipient address
     * @param encryptedAmount Encrypted amount to transfer
     */
    function privateTransfer(
        address to,
        gtUint64 encryptedAmount
    ) external nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (to == msg.sender) revert SelfTransfer();

        // Verify sender balance
        gtUint64 gtSender = MpcCore.onBoard(
            encryptedBalances[msg.sender]
        );
        gtBool hasSufficient = MpcCore.ge(gtSender, encryptedAmount);
        if (!MpcCore.decrypt(hasSufficient)) {
            revert InsufficientPrivateBalance();
        }

        // Update sender balance
        gtUint64 gtNewSender = MpcCore.sub(gtSender, encryptedAmount);
        encryptedBalances[msg.sender] = MpcCore.offBoard(gtNewSender);

        // Update recipient balance
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
     * @return Encrypted balance (ctUint64)
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
     * @return True if no more upgrades possible
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
