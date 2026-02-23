// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {OmniCoin} from "./OmniCoin.sol";

/**
 * @title LegacyBalanceClaim
 * @author OmniCoin Development Team
 * @notice Allows legacy OmniCoin V1 users to claim their balances in V2
 * @dev This is a TEMPORARY contract for migration purposes only.
 *      Will be deprecated after the migration period (2 years from deployment).
 *
 * Architecture:
 * - Stores 4,735 legacy user balances indexed by username hash
 * - Backend validator validates username/password off-chain
 * - Validator signs a proof that is verified on-chain via ECDSA
 * - Each username can only claim once
 * - Reserved usernames cannot be used for new signups
 *
 * Security:
 * - Passwords NEVER sent to blockchain (validated off-chain)
 * - Validator backend signs validation proof including chainId to prevent
 *   cross-chain replay attacks
 * - Uses OpenZeppelin ECDSA for signature verification (prevents ecrecover
 *   returning address(0) and signature malleability)
 * - ReentrancyGuard protects against reentrancy attacks
 * - One-time claiming enforced
 * - Migration finalization requires a 2-year timelock
 */
contract LegacyBalanceClaim is Ownable, ReentrancyGuard {
    // ──────────────────────────────────────────────────────────────
    // Constants
    // ──────────────────────────────────────────────────────────────

    /// @notice Duration of the migration period before finalization is allowed
    /// @dev 730 days = 2 years
    uint256 public constant MIGRATION_DURATION = 730 days;

    /// @notice Maximum total XOM that can be minted through legacy migration
    /// @dev 4.13 billion XOM (genesis circulating supply) with 18 decimals.
    ///      This caps total minting via this contract to prevent unbounded inflation
    ///      even if the owner loads more balances than expected.
    uint256 public constant MAX_MIGRATION_SUPPLY = 4_130_000_000e18;

    // ──────────────────────────────────────────────────────────────
    // Immutable variables
    // ──────────────────────────────────────────────────────────────

    /// @notice Reference to OmniCoin token contract
    OmniCoin public immutable OMNI_COIN;

    /// @notice Timestamp when this contract was deployed
    /// @dev Used to enforce the migration timelock
    uint256 public immutable DEPLOYED_AT;

    // ──────────────────────────────────────────────────────────────
    // Public state variables
    // ──────────────────────────────────────────────────────────────

    /// @notice Authorized validator backend service address
    address public validator;

    /// @notice Mapping from username hash to legacy balance (in Wei)
    mapping(bytes32 => uint256) public legacyBalances;

    /// @notice Mapping from username hash to claiming ETH address
    /// @dev address(0) indicates unclaimed
    mapping(bytes32 => address) public claimedBy;

    /// @notice Mapping from username hash to reserved status
    mapping(bytes32 => bool) public reserved;

    /// @notice Total amount of XOM claimed so far
    uint256 public totalClaimed;

    /// @notice Total amount of XOM reserved for legacy users
    uint256 public totalReserved;

    /// @notice Whether migration has been finalized
    bool public migrationFinalized;

    /// @notice Number of unique users who have claimed
    uint256 public uniqueClaimants;

    /// @notice Number of legacy usernames reserved
    uint256 public reservedCount;

    /// @notice Total amount of XOM actually minted through this contract
    /// @dev Tracked separately from totalClaimed to enforce MAX_MIGRATION_SUPPLY
    uint256 public totalMinted;

    // ──────────────────────────────────────────────────────────────
    // Events
    // ──────────────────────────────────────────────────────────────

    /// @notice Emitted when a legacy balance is successfully claimed
    /// @param username The legacy username that was claimed
    /// @param ethAddress The Ethereum address receiving the tokens
    /// @param amount The amount of XOM tokens claimed (in Wei)
    event BalanceClaimed(
        string indexed username,
        address indexed ethAddress,
        uint256 indexed amount
    );

    /// @notice Emitted when migration is finalized
    /// @param totalClaimedAmount Total XOM claimed by users
    /// @param totalUnclaimedAmount Total XOM remaining unclaimed
    /// @param unclaimedRecipient Address receiving unclaimed balances
    event MigrationFinalized(
        uint256 indexed totalClaimedAmount,
        uint256 indexed totalUnclaimedAmount,
        address indexed unclaimedRecipient
    );

    /// @notice Emitted when validator address is updated
    /// @param oldValidator Previous validator address
    /// @param newValidator New validator address
    event ValidatorUpdated(
        address indexed oldValidator,
        address indexed newValidator
    );

    /// @notice Emitted when contract is initialized with legacy balances
    /// @param userCount Number of legacy users loaded
    /// @param totalAmount Total XOM reserved for those users
    event LegacyInitialized(
        uint256 indexed userCount,
        uint256 indexed totalAmount
    );

    /// @notice Emitted when additional legacy users are added
    /// @param userCount Number of users in this batch
    /// @param batchAmount Total XOM in this batch
    /// @param newTotalReserved Updated total reserved amount
    event LegacyUsersAdded(
        uint256 indexed userCount,
        uint256 indexed batchAmount,
        uint256 indexed newTotalReserved
    );

    // ──────────────────────────────────────────────────────────────
    // Custom Errors
    // ──────────────────────────────────────────────────────────────

    /// @notice Thrown when an address parameter is the zero address
    error ZeroAddress();

    /// @notice Thrown when the contract has already been initialized
    error AlreadyInitialized();

    /// @notice Thrown when input arrays have mismatched lengths
    /// @param usernamesLength Length of usernames array
    /// @param balancesLength Length of balances array
    error LengthMismatch(
        uint256 usernamesLength,
        uint256 balancesLength
    );

    /// @notice Thrown when an input array is empty
    error EmptyArray();

    /// @notice Thrown when a username string is empty
    error EmptyUsername();

    /// @notice Thrown when a balance value is zero
    error ZeroBalance();

    /// @notice Thrown when a duplicate username is found during loading
    /// @param usernameHash Hash of the duplicate username
    error DuplicateUsername(bytes32 usernameHash);

    /// @notice Thrown when the migration has already been finalized
    error MigrationAlreadyFinalized();

    /// @notice Thrown when no legacy balance exists for the username
    error NoLegacyBalance();

    /// @notice Thrown when the balance has already been claimed
    /// @param claimant Address that previously claimed
    error AlreadyClaimed(address claimant);

    /// @notice Thrown when the signature verification fails
    error InvalidProof();

    /// @notice Thrown when the caller is not the authorized validator
    /// @param caller The unauthorized caller address
    /// @param expected The expected validator address
    error NotValidator(address caller, address expected);

    /// @notice Thrown when finalization is attempted before the deadline
    /// @param currentTime Current block timestamp
    /// @param deadline Earliest allowed finalization time
    error MigrationPeriodNotEnded(
        uint256 currentTime,
        uint256 deadline
    );

    /// @notice Thrown when minting would exceed the migration supply cap
    /// @param requested Amount of XOM requested to mint
    /// @param remaining Remaining mintable amount under the cap
    error MigrationSupplyExceeded(
        uint256 requested,
        uint256 remaining
    );

    // ──────────────────────────────────────────────────────────────
    // Modifiers
    // ──────────────────────────────────────────────────────────────

    /**
     * @notice Restricts function to the authorized validator backend
     * @dev Reverts with NotValidator if caller is not the validator
     */
    modifier onlyValidator() {
        if (msg.sender != validator) {
            revert NotValidator(msg.sender, validator);
        }
        _;
    }

    // ──────────────────────────────────────────────────────────────
    // Constructor
    // ──────────────────────────────────────────────────────────────

    /**
     * @notice Deploy the legacy balance claim contract
     * @dev Sets the OmniCoin reference, initial owner, and validator.
     *      Records the deployment timestamp for migration timelock.
     * @param _omniCoin Address of the OmniCoin token contract
     * @param initialOwner Address of the contract owner
     * @param _validator Address of the authorized validator backend
     */
    constructor(
        address _omniCoin,
        address initialOwner,
        address _validator
    ) Ownable(initialOwner) {
        if (_omniCoin == address(0)) revert ZeroAddress();
        if (_validator == address(0)) revert ZeroAddress();

        OMNI_COIN = OmniCoin(_omniCoin);
        validator = _validator;
        DEPLOYED_AT = block.timestamp; // solhint-disable-line not-rely-on-time
    }

    // ──────────────────────────────────────────────────────────────
    // External functions (state-changing)
    // ──────────────────────────────────────────────────────────────

    /**
     * @notice Initialize contract with legacy balances
     * @dev Can only be called once, before any claims. Owner only.
     * @param usernames Array of legacy usernames
     * @param balances Array of balances (in Wei, 18 decimals)
     */
    function initialize(
        string[] calldata usernames,
        uint256[] calldata balances
    ) external onlyOwner {
        if (reservedCount != 0) revert AlreadyInitialized();
        _validateBatchInputs(usernames, balances);

        uint256 total = _loadLegacyBatch(usernames, balances);

        // M-01: Enforce supply cap at initialization
        if (total > MAX_MIGRATION_SUPPLY) {
            revert MigrationSupplyExceeded(total, MAX_MIGRATION_SUPPLY);
        }

        totalReserved = total;

        emit LegacyInitialized(usernames.length, total);
    }

    /**
     * @notice Add more legacy users after initial deployment
     * @dev Allows batch additions for large user sets that exceed
     *      gas limits. Owner only. Cannot be called after finalization.
     * @param usernames Array of legacy usernames to add
     * @param balances Array of balances (in Wei, 18 decimals)
     */
    function addLegacyUsers(
        string[] calldata usernames,
        uint256[] calldata balances
    ) external onlyOwner {
        if (migrationFinalized) revert MigrationAlreadyFinalized();
        _validateBatchInputs(usernames, balances);

        uint256 total = _loadLegacyBatch(usernames, balances);

        uint256 newTotalReserved = totalReserved + total;
        // M-01: Enforce supply cap on additional batches
        if (newTotalReserved > MAX_MIGRATION_SUPPLY) {
            revert MigrationSupplyExceeded(
                total,
                MAX_MIGRATION_SUPPLY - totalReserved
            );
        }

        totalReserved = newTotalReserved;

        emit LegacyUsersAdded(
            usernames.length,
            total,
            totalReserved
        );
    }

    /**
     * @notice Claim legacy balance after off-chain password validation
     * @dev Only callable by the authorized validator backend. The validator
     *      signs a proof after verifying the user's legacy credentials.
     *      Uses CEI pattern: state updates before external mint call.
     * @param username Legacy username
     * @param ethAddress New Ethereum address to receive tokens
     * @param validationProof Signature from validator backend
     * @return success Whether the claim was successful
     */
    function claim(
        string calldata username,
        address ethAddress,
        bytes calldata validationProof
    ) external onlyValidator nonReentrant returns (bool success) {
        if (migrationFinalized) revert MigrationAlreadyFinalized();
        if (bytes(username).length == 0) revert EmptyUsername();
        if (ethAddress == address(0)) revert ZeroAddress();

        bytes32 usernameHash = keccak256(bytes(username));

        if (legacyBalances[usernameHash] == 0) revert NoLegacyBalance();
        if (claimedBy[usernameHash] != address(0)) {
            revert AlreadyClaimed(claimedBy[usernameHash]);
        }

        // Verify validation proof (signed by validator backend)
        _verifyProof(username, ethAddress, validationProof);

        uint256 amount = legacyBalances[usernameHash];

        // M-01: Enforce migration supply cap before minting
        uint256 newTotalMinted = totalMinted + amount;
        if (newTotalMinted > MAX_MIGRATION_SUPPLY) {
            revert MigrationSupplyExceeded(
                amount,
                MAX_MIGRATION_SUPPLY - totalMinted
            );
        }

        // Update state before external call (CEI pattern)
        claimedBy[usernameHash] = ethAddress;
        totalClaimed += amount;
        totalMinted = newTotalMinted;
        ++uniqueClaimants;

        // Mint tokens to user's new Ethereum address
        OMNI_COIN.mint(ethAddress, amount);

        emit BalanceClaimed(username, ethAddress, amount);

        return true;
    }

    /**
     * @notice Finalize migration and handle unclaimed balances
     * @dev Can only be called by owner after the migration period
     *      (MIGRATION_DURATION from deployment). Unclaimed balances
     *      are minted to the specified recipient (ODDAO or burn).
     * @param unclaimedRecipient Address to send unclaimed balances
     */
    function finalizeMigration(
        address unclaimedRecipient
    ) external onlyOwner {
        if (migrationFinalized) revert MigrationAlreadyFinalized();
        if (unclaimedRecipient == address(0)) revert ZeroAddress();

        uint256 deadline = DEPLOYED_AT + MIGRATION_DURATION;
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp < deadline) {
            revert MigrationPeriodNotEnded(
                block.timestamp, // solhint-disable-line not-rely-on-time
                deadline
            );
        }

        uint256 unclaimed = totalReserved - totalClaimed;

        migrationFinalized = true;

        if (unclaimed > 0) {
            // M-01: Enforce migration supply cap on finalization mint
            uint256 newTotalMinted = totalMinted + unclaimed;
            if (newTotalMinted > MAX_MIGRATION_SUPPLY) {
                revert MigrationSupplyExceeded(
                    unclaimed,
                    MAX_MIGRATION_SUPPLY - totalMinted
                );
            }
            totalMinted = newTotalMinted;

            // Mint unclaimed balance to specified recipient
            OMNI_COIN.mint(unclaimedRecipient, unclaimed);
        }

        emit MigrationFinalized(
            totalClaimed,
            unclaimed,
            unclaimedRecipient
        );
    }

    /**
     * @notice Set authorized validator backend address
     * @dev Only callable by contract owner. Cannot set to zero address.
     * @param _validator New validator address
     */
    function setValidator(address _validator) external onlyOwner {
        if (_validator == address(0)) revert ZeroAddress();
        address oldValidator = validator;
        validator = _validator;
        emit ValidatorUpdated(oldValidator, _validator);
    }

    // ──────────────────────────────────────────────────────────────
    // External view functions
    // ──────────────────────────────────────────────────────────────

    /**
     * @notice Check if username has unclaimed balance
     * @param username Username to check
     * @return balance Unclaimed balance (0 if already claimed or none)
     */
    function getUnclaimedBalance(
        string calldata username
    ) external view returns (uint256 balance) {
        bytes32 usernameHash = keccak256(bytes(username));
        if (claimedBy[usernameHash] != address(0)) {
            return 0;
        }
        return legacyBalances[usernameHash];
    }

    /**
     * @notice Check if username is reserved (legacy user)
     * @param username Username to check
     * @return isReservedUser True if username belongs to a legacy user
     */
    function isReserved(
        string calldata username
    ) external view returns (bool isReservedUser) {
        bytes32 usernameHash = keccak256(bytes(username));
        return reserved[usernameHash];
    }

    /**
     * @notice Check if username has already been claimed
     * @param username Username to check
     * @return isClaimed True if balance has been claimed
     * @return claimant Address that claimed the balance
     */
    function getClaimed(
        string calldata username
    ) external view returns (bool isClaimed, address claimant) {
        bytes32 usernameHash = keccak256(bytes(username));
        address claimer = claimedBy[usernameHash];
        return (claimer != address(0), claimer);
    }

    /**
     * @notice Get migration statistics
     * @return _totalReserved Total XOM reserved for migration
     * @return _totalClaimed Total XOM claimed by users
     * @return _totalUnclaimed Total XOM remaining unclaimed
     * @return _uniqueClaimants Number of unique claimants
     * @return _reservedCount Number of reserved usernames
     * @return _percentClaimed Percentage claimed (basis points)
     * @return _finalized Whether migration period has ended
     */
    function getStats()
        external
        view
        returns (
            uint256 _totalReserved,
            uint256 _totalClaimed,
            uint256 _totalUnclaimed,
            uint256 _uniqueClaimants,
            uint256 _reservedCount,
            uint256 _percentClaimed,
            bool _finalized
        )
    {
        uint256 unclaimed = totalReserved - totalClaimed;
        uint256 percent = totalReserved > 0
            ? (totalClaimed * 10000) / totalReserved
            : 0;

        return (
            totalReserved,
            totalClaimed,
            unclaimed,
            uniqueClaimants,
            reservedCount,
            percent,
            migrationFinalized
        );
    }

    /**
     * @notice Get the earliest timestamp when finalization is allowed
     * @return deadline Timestamp after which finalizeMigration can be called
     */
    function getFinalizationDeadline()
        external
        view
        returns (uint256 deadline)
    {
        return DEPLOYED_AT + MIGRATION_DURATION;
    }

    // ──────────────────────────────────────────────────────────────
    // Internal functions
    // ──────────────────────────────────────────────────────────────

    /**
     * @notice Verify validation proof from validator backend
     * @dev Uses OpenZeppelin ECDSA.recover which reverts on invalid
     *      signatures and prevents address(0) recovery. The signed
     *      message includes block.chainid to prevent cross-chain replay.
     * @param username Username being claimed
     * @param ethAddress Ethereum address receiving tokens
     * @param validationProof Signature from validator backend
     */
    function _verifyProof(
        string calldata username,
        address ethAddress,
        bytes calldata validationProof
    ) internal view {
        bytes32 message = keccak256(
            abi.encodePacked(
                username,
                ethAddress,
                address(this),
                block.chainid
            )
        );
        bytes32 ethSignedMessage =
            MessageHashUtils.toEthSignedMessageHash(message);
        address signer =
            ECDSA.recover(ethSignedMessage, validationProof);
        if (signer != validator) revert InvalidProof();
    }

    // ──────────────────────────────────────────────────────────────
    // Private functions
    // ──────────────────────────────────────────────────────────────

    /**
     * @notice Load a batch of legacy users into storage
     * @dev Validates each entry, stores balance and reserved flag.
     *      Reverts on empty usernames, zero balances, or duplicates.
     * @param usernames Array of legacy usernames to store
     * @param balances Array of corresponding balances (Wei)
     * @return total Total XOM amount loaded in this batch
     */
    function _loadLegacyBatch(
        string[] calldata usernames,
        uint256[] calldata balances
    ) private returns (uint256 total) {
        total = 0;

        for (uint256 i = 0; i < usernames.length; ++i) {
            _storeLegacyUser(usernames[i], balances[i]);
            total += balances[i];
        }
    }

    /**
     * @notice Store a single legacy user's balance and reserved flag
     * @dev Validates the username and balance, checks for duplicates
     * @param username Legacy username to store
     * @param balance Balance amount in Wei
     */
    function _storeLegacyUser(
        string calldata username,
        uint256 balance
    ) private {
        if (bytes(username).length == 0) revert EmptyUsername();
        if (balance == 0) revert ZeroBalance();

        bytes32 usernameHash = keccak256(bytes(username));

        if (legacyBalances[usernameHash] != 0) {
            revert DuplicateUsername(usernameHash);
        }

        legacyBalances[usernameHash] = balance;
        reserved[usernameHash] = true;
        ++reservedCount;
    }

    /**
     * @notice Validate batch input arrays for legacy user loading
     * @dev Checks length match and non-empty arrays. Pure function.
     * @param usernames Array of legacy usernames
     * @param balances Array of balances
     */
    function _validateBatchInputs(
        string[] calldata usernames,
        uint256[] calldata balances
    ) private pure {
        if (usernames.length != balances.length) {
            revert LengthMismatch(
                usernames.length,
                balances.length
            );
        }
        if (usernames.length == 0) revert EmptyArray();
    }
}
