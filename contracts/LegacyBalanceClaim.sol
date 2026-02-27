// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
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
 * - M-of-N multi-sig validation: requires multiple validator signatures
 *   to authorize each claim, preventing single-key compromise
 * - Signature includes chainId and per-user nonce to prevent cross-chain
 *   and intra-chain replay attacks
 * - Uses OpenZeppelin ECDSA for signature verification (prevents ecrecover
 *   returning address(0) and signature malleability)
 * - Uses abi.encode (not abi.encodePacked) to prevent hash collisions
 *   with the dynamic-length username string
 * - ReentrancyGuard protects against reentrancy attacks
 * - Pausable emergency brake allows owner to halt claims instantly
 * - One-time claiming enforced
 * - Migration finalization requires a 2-year timelock
 */
contract LegacyBalanceClaim is Ownable, ReentrancyGuard, Pausable {
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

    /// @notice Maximum number of validators allowed in the set
    uint256 public constant MAX_VALIDATORS = 20;

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

    /// @notice Array of authorized validator addresses for M-of-N multi-sig
    address[] public validators;

    /// @notice Quick lookup for validator membership
    mapping(address => bool) public isValidator;

    /// @notice Number of valid signatures required to approve a claim
    uint256 public requiredSignatures;

    /// @notice Whether the contract has been initialized with legacy balances
    bool public initialized;

    /// @notice Per-user nonce for claim signature replay protection
    mapping(address => uint256) public claimNonces;

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

    /// @notice Emitted when the validator set is updated
    /// @param validatorCount Number of validators in the new set
    /// @param requiredSigs Number of signatures required
    event ValidatorSetUpdated(
        uint256 indexed validatorCount,
        uint256 indexed requiredSigs
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

    /// @notice Thrown when not enough valid signatures are provided
    /// @param required Number of signatures required
    /// @param provided Number of valid signatures provided
    error InsufficientSignatures(
        uint256 required,
        uint256 provided
    );

    /// @notice Thrown when a recovered signer is not an authorized validator
    /// @param recovered The recovered signer address
    error InvalidSigner(address recovered);

    /// @notice Thrown when an invalid validator set is provided
    /// @param threshold Required signatures count
    /// @param validatorCount Number of validators provided
    error InvalidValidatorSet(
        uint256 threshold,
        uint256 validatorCount
    );

    /// @notice Thrown when a duplicate validator address is found
    /// @param validator The duplicate validator address
    error DuplicateValidator(address validator);

    /// @notice Thrown when the contract has not been initialized yet
    error NotInitialized();

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

    // ──────────────────────────────────────────────────────────────
    // Constructor
    // ──────────────────────────────────────────────────────────────

    /**
     * @notice Deploy the legacy balance claim contract
     * @dev Sets the OmniCoin reference, initial owner, and M-of-N validator set.
     *      Records the deployment timestamp for migration timelock.
     *      Validates that the validator set has no duplicates, no zero addresses,
     *      and that the threshold is valid (1 <= threshold <= validators.length).
     * @param _omniCoin Address of the OmniCoin token contract
     * @param initialOwner Address of the contract owner
     * @param _validators Array of authorized validator backend addresses
     * @param _requiredSignatures Number of signatures required (M in M-of-N)
     */
    constructor(
        address _omniCoin,
        address initialOwner,
        address[] memory _validators,
        uint256 _requiredSignatures
    ) Ownable(initialOwner) {
        if (_omniCoin == address(0)) revert ZeroAddress();

        _validateValidatorSet(_validators, _requiredSignatures);

        OMNI_COIN = OmniCoin(_omniCoin);
        DEPLOYED_AT = block.timestamp; // solhint-disable-line not-rely-on-time

        for (uint256 i = 0; i < _validators.length; ++i) {
            validators.push(_validators[i]);
            isValidator[_validators[i]] = true;
        }
        requiredSignatures = _requiredSignatures;

        emit ValidatorSetUpdated(
            _validators.length,
            _requiredSignatures
        );
    }

    // ──────────────────────────────────────────────────────────────
    // External functions (state-changing)
    // ──────────────────────────────────────────────────────────────

    /**
     * @notice Initialize contract with legacy balances
     * @dev Can only be called once, before any claims or addLegacyUsers calls.
     *      Uses a dedicated boolean flag to prevent the ordering vulnerability
     *      where addLegacyUsers() could make initialize() permanently unreachable.
     *      Owner only.
     * @param usernames Array of legacy usernames
     * @param balances Array of balances (in Wei, 18 decimals)
     */
    function initialize(
        string[] calldata usernames,
        uint256[] calldata balances
    ) external onlyOwner {
        if (initialized) revert AlreadyInitialized();
        initialized = true;

        _validateBatchInputs(usernames, balances);

        uint256 total = _loadLegacyBatch(usernames, balances);

        // Enforce supply cap at initialization
        if (total > MAX_MIGRATION_SUPPLY) {
            revert MigrationSupplyExceeded(
                total,
                MAX_MIGRATION_SUPPLY
            );
        }

        totalReserved = total;

        emit LegacyInitialized(usernames.length, total);
    }

    /**
     * @notice Add more legacy users after initial deployment
     * @dev Allows batch additions for large user sets that exceed
     *      gas limits. Owner only. Requires initialize() to have been
     *      called first. Cannot be called after finalization.
     * @param usernames Array of legacy usernames to add
     * @param balances Array of balances (in Wei, 18 decimals)
     */
    function addLegacyUsers(
        string[] calldata usernames,
        uint256[] calldata balances
    ) external onlyOwner {
        if (!initialized) revert NotInitialized();
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
     * @dev Requires M-of-N multi-sig validation proofs from authorized
     *      validators. Each validator independently verifies the user's
     *      legacy credentials off-chain, then signs a proof. The signed
     *      message includes a per-user nonce to prevent replay attacks.
     *      Uses CEI pattern: state updates before external mint call.
     *      Protected by Pausable for emergency halting and ReentrancyGuard.
     * @param username Legacy username
     * @param ethAddress New Ethereum address to receive tokens
     * @param nonce Per-user nonce (must match current claimNonces[ethAddress])
     * @param validationProofs Array of signatures from validator backends
     * @return success Whether the claim was successful
     */
    function claim(
        string calldata username,
        address ethAddress,
        uint256 nonce,
        bytes[] calldata validationProofs
    ) external nonReentrant whenNotPaused returns (bool success) {
        bytes32 usernameHash = _validateClaim(
            username,
            ethAddress,
            nonce
        );

        // Verify M-of-N validation proofs (signed by validator backends)
        _verifyMultiSigProof(
            username,
            ethAddress,
            nonce,
            validationProofs
        );

        uint256 amount = legacyBalances[usernameHash];

        // Enforce migration supply cap before minting
        uint256 newTotalMinted = totalMinted + amount;
        if (newTotalMinted > MAX_MIGRATION_SUPPLY) {
            revert MigrationSupplyExceeded(
                amount,
                MAX_MIGRATION_SUPPLY - totalMinted
            );
        }

        // Update state before external call (CEI pattern)
        claimedBy[usernameHash] = ethAddress;
        legacyBalances[usernameHash] = 0; // Gas refund
        totalClaimed += amount;
        totalMinted = newTotalMinted;
        ++uniqueClaimants;
        ++claimNonces[ethAddress]; // Consume the nonce

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
     * @notice Update the authorized validator set and threshold
     * @dev Only callable by contract owner. Validates that the new set
     *      has no duplicates, no zero addresses, and a valid threshold.
     *      Clears the old validator set before applying the new one.
     * @param _validators New array of validator addresses
     * @param _requiredSigs New number of required signatures
     */
    function updateValidatorSet(
        address[] calldata _validators,
        uint256 _requiredSigs
    ) external onlyOwner {
        _validateValidatorSet(_validators, _requiredSigs);

        // Clear old validator set
        for (uint256 i = 0; i < validators.length; ++i) {
            isValidator[validators[i]] = false;
        }
        delete validators;

        // Set new validator set
        for (uint256 i = 0; i < _validators.length; ++i) {
            validators.push(_validators[i]);
            isValidator[_validators[i]] = true;
        }
        requiredSignatures = _requiredSigs;

        emit ValidatorSetUpdated(
            _validators.length,
            _requiredSigs
        );
    }

    /**
     * @notice Pause the contract, halting all claim operations
     * @dev Only callable by contract owner. Use in emergency situations
     *      such as suspected validator key compromise.
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause the contract, resuming claim operations
     * @dev Only callable by contract owner.
     */
    function unpause() external onlyOwner {
        _unpause();
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

    /**
     * @notice Get the full list of authorized validators
     * @return validatorList Array of validator addresses
     */
    function getValidators()
        external
        view
        returns (address[] memory validatorList)
    {
        return validators;
    }

    /**
     * @notice Get the current claim nonce for an address
     * @dev Used by off-chain tools to construct correctly signed messages
     * @param ethAddress The address to check
     * @return nonce Current nonce value
     */
    function getClaimNonce(
        address ethAddress
    ) external view returns (uint256 nonce) {
        return claimNonces[ethAddress];
    }

    // ──────────────────────────────────────────────────────────────
    // Internal functions
    // ──────────────────────────────────────────────────────────────

    /**
     * @notice Validate all preconditions for a claim
     * @dev Checks migration status, input validity, balance existence,
     *      claim uniqueness, and nonce correctness.
     * @param username Legacy username to claim
     * @param ethAddress Address to receive tokens
     * @param nonce Expected per-user nonce
     * @return usernameHash Keccak256 hash of the username
     */
    function _validateClaim(
        string calldata username,
        address ethAddress,
        uint256 nonce
    ) internal view returns (bytes32 usernameHash) {
        if (migrationFinalized) revert MigrationAlreadyFinalized();
        if (bytes(username).length == 0) revert EmptyUsername();
        if (ethAddress == address(0)) revert ZeroAddress();

        usernameHash = keccak256(bytes(username));

        if (legacyBalances[usernameHash] == 0) {
            revert NoLegacyBalance();
        }
        if (claimedBy[usernameHash] != address(0)) {
            revert AlreadyClaimed(claimedBy[usernameHash]);
        }
        if (nonce != claimNonces[ethAddress]) {
            revert InvalidProof();
        }
    }

    /**
     * @notice Verify M-of-N validation proofs from validator backends
     * @dev Uses OpenZeppelin ECDSA.recover which reverts on invalid
     *      signatures and prevents address(0) recovery. The signed
     *      message includes block.chainid, address(this), and a per-user
     *      nonce to prevent cross-chain, cross-contract, and intra-chain
     *      replay attacks. Uses abi.encode (not abi.encodePacked) to
     *      prevent hash collisions with the dynamic-length username.
     *      Uses a bitmap to detect duplicate signers efficiently.
     * @param username Username being claimed
     * @param ethAddress Ethereum address receiving tokens
     * @param nonce Per-user replay protection nonce
     * @param proofs Array of ECDSA signatures from validators
     */
    function _verifyMultiSigProof(
        string calldata username,
        address ethAddress,
        uint256 nonce,
        bytes[] calldata proofs
    ) internal view {
        if (proofs.length < requiredSignatures) {
            revert InsufficientSignatures(
                requiredSignatures,
                proofs.length
            );
        }

        // Use abi.encode to prevent hash collision with dynamic string
        bytes32 message = keccak256(
            abi.encode(
                username,
                ethAddress,
                nonce,
                address(this),
                block.chainid
            )
        );
        bytes32 ethSignedMessage =
            MessageHashUtils.toEthSignedMessageHash(message);

        uint256 validCount = 0;
        // Bitmap for duplicate detection (supports up to 256 validators)
        uint256 seenBitmap = 0;

        for (
            uint256 i = 0;
            i < proofs.length && validCount < requiredSignatures;
            ++i
        ) {
            address signer =
                ECDSA.recover(ethSignedMessage, proofs[i]);

            if (!isValidator[signer]) {
                revert InvalidSigner(signer);
            }

            // Find signer index for bitmap
            uint256 idx = _getValidatorIndex(signer);
            uint256 bit = 1 << idx;

            // Skip duplicate signatures from the same validator
            if ((seenBitmap & bit) != 0) continue;
            seenBitmap |= bit;

            ++validCount;
        }

        if (validCount < requiredSignatures) {
            revert InsufficientSignatures(
                requiredSignatures,
                validCount
            );
        }
    }

    /**
     * @notice Get the index of a validator in the validators array
     * @dev Used for bitmap-based duplicate detection. Reverts if the
     *      validator is not found (should not happen after isValidator check).
     * @param _validator Address to find
     * @return idx Index in the validators array
     */
    function _getValidatorIndex(
        address _validator
    ) internal view returns (uint256 idx) {
        for (uint256 i = 0; i < validators.length; ++i) {
            if (validators[i] == _validator) return i;
        }
        // Should not reach here if isValidator check passed
        revert InvalidSigner(_validator);
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

    /**
     * @notice Validate a validator set and required signature threshold
     * @dev Checks for zero addresses, duplicates, valid threshold range,
     *      and MAX_VALIDATORS limit. Uses O(n^2) duplicate detection
     *      which is acceptable given MAX_VALIDATORS = 20.
     * @param _validators Array of validator addresses to validate
     * @param _requiredSigs Signature threshold to validate
     */
    function _validateValidatorSet(
        address[] memory _validators,
        uint256 _requiredSigs
    ) private pure {
        if (
            _validators.length == 0 ||
            _validators.length > MAX_VALIDATORS
        ) {
            revert InvalidValidatorSet(
                _requiredSigs,
                _validators.length
            );
        }
        if (
            _requiredSigs == 0 ||
            _requiredSigs > _validators.length
        ) {
            revert InvalidValidatorSet(
                _requiredSigs,
                _validators.length
            );
        }

        // Check for zero addresses and duplicates
        for (uint256 i = 0; i < _validators.length; ++i) {
            if (_validators[i] == address(0)) revert ZeroAddress();
            for (
                uint256 j = i + 1;
                j < _validators.length;
                ++j
            ) {
                if (_validators[i] == _validators[j]) {
                    revert DuplicateValidator(_validators[i]);
                }
            }
        }
    }
}
