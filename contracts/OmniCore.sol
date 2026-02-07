// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title OmniCore
 * @author OmniCoin Development Team
 * @notice Upgradeable core contract with UUPS proxy pattern
 * @dev Ultra-lean core contract consolidating registry, validators, and minimal staking
 * @dev max-states-count disabled: Need 21+ states for comprehensive functionality
 * @dev ordering disabled: Upgradeable contracts follow specific ordering pattern
 */
// solhint-disable max-states-count, ordering
contract OmniCore is
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    // Type declarations
    /// @notice Minimal stake information
    struct Stake {
        uint256 amount;
        uint256 tier;
        uint256 duration;
        uint256 lockTime;
        bool active;
    }

    // Constants
    /// @notice Admin role for governance operations
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /// @notice Role for Avalanche validators
    bytes32 public constant AVALANCHE_VALIDATOR_ROLE = keccak256("AVALANCHE_VALIDATOR_ROLE");

    /// @notice Fee percentage for ODDAO (70% = 7000 basis points)
    uint256 public constant ODDAO_FEE_BPS = 7000;

    /// @notice Fee percentage for staking pool (20% = 2000 basis points)
    uint256 public constant STAKING_FEE_BPS = 2000;

    /// @notice Fee percentage for validator (10% = 1000 basis points)
    uint256 public constant VALIDATOR_FEE_BPS = 1000;

    /// @notice Total basis points for percentage calculations
    uint256 public constant BASIS_POINTS = 10000;

    /// @notice Maximum number of validator signatures for multi-sig
    uint256 public constant MAX_REQUIRED_SIGNATURES = 5;

    // State variables (STORAGE LAYOUT - DO NOT REORDER!)
    /// @notice OmniCoin token address (changed from immutable)
    /// @dev Variable name kept uppercase for backward compatibility
    // solhint-disable-next-line var-name-mixedcase
    IERC20 public OMNI_COIN;

    /// @notice Service registry mapping service names to addresses
    mapping(bytes32 => address) public services;

    /// @notice Validator registry for active validators
    mapping(address => bool) public validators;

    /// @notice DEPRECATED: kept for UUPS storage layout compatibility. Do not use.
    bytes32 public masterRoot;

    /// @notice DEPRECATED: kept for UUPS storage layout compatibility. Do not use.
    uint256 public lastRootUpdate;

    /// @notice User stakes - minimal on-chain data
    mapping(address => Stake) public stakes;

    /// @notice Total staked amount for security
    uint256 public totalStaked;

    /// @notice DEX balances for settlement (user => token => amount)
    mapping(address => mapping(address => uint256)) public dexBalances;

    /// @notice ODDAO address for receiving 70% of DEX fees
    address public oddaoAddress;

    /// @notice Staking pool address for receiving 20% of DEX fees
    address public stakingPoolAddress;

    // Legacy Migration State (added 2025-08-06)
    /// @notice Reserved legacy usernames (username hash => reserved)
    mapping(bytes32 => bool) public legacyUsernames;

    /// @notice Legacy balances to be claimed (username hash => amount in 18 decimals)
    mapping(bytes32 => uint256) public legacyBalances;

    /// @notice Claimed legacy accounts (username hash => claim address)
    mapping(bytes32 => address) public legacyClaimed;

    /// @notice Legacy user account public keys (username hash => public key)
    mapping(bytes32 => bytes) public legacyAccounts;

    /// @notice Total legacy tokens to distribute
    uint256 public totalLegacySupply;

    /// @notice Total legacy tokens claimed so far
    uint256 public totalLegacyClaimed;

    /// @notice Required validator signatures for legacy claims (M-of-N multi-sig)
    uint256 public requiredSignatures;

    /// @notice Storage gap for future upgrades (reserve 49 slots)
    /// @dev Reduced from 50 to 49 to accommodate requiredSignatures
    uint256[49] private __gap;

    // Events
    /// @notice Emitted when a service is registered or updated
    /// @param name Service identifier
    /// @param serviceAddress Address of the service contract
    /// @param timestamp Block timestamp of update
    event ServiceUpdated(
        bytes32 indexed name,
        address indexed serviceAddress,
        uint256 indexed timestamp
    );

    /// @notice Emitted when a validator is added or removed
    /// @param validator Address of the validator
    /// @param active Whether validator is active
    /// @param timestamp Block timestamp of change
    event ValidatorUpdated(
        address indexed validator,
        bool indexed active,
        uint256 indexed timestamp
    );

    /// @notice Emitted when a legacy balance is claimed
    /// @param username Legacy username being claimed
    /// @param claimAddress Address receiving the tokens
    /// @param amount Amount of tokens claimed (18 decimals)
    /// @param timestamp Block timestamp of claim
    event LegacyBalanceClaimed(
        string indexed username,
        address indexed claimAddress,
        uint256 indexed amount,
        uint256 timestamp
    );

    /// @notice Emitted when legacy users are registered
    /// @param count Number of users registered
    /// @param totalAmount Total amount reserved for distribution
    event LegacyUsersRegistered(
        uint256 indexed count,
        uint256 indexed totalAmount
    );

    /// @notice Emitted when tokens are staked
    /// @param user Address of the staker
    /// @param amount Amount of tokens staked
    /// @param tier Staking tier selected
    /// @param duration Lock duration in seconds
    event TokensStaked(
        address indexed user,
        uint256 indexed amount,
        uint256 indexed tier,
        uint256 duration
    );

    /// @notice Emitted when tokens are unlocked
    /// @param user Address of the staker
    /// @param amount Amount of tokens unlocked
    /// @param timestamp Block timestamp of unlock
    event TokensUnlocked(
        address indexed user,
        uint256 indexed amount,
        uint256 indexed timestamp
    );

    /// @notice Emitted when DEX trade is settled
    /// @param buyer Buyer address
    /// @param seller Seller address
    /// @param token Token traded
    /// @param amount Amount traded
    /// @param orderId Off-chain order ID
    event DEXSettlement(
        address indexed buyer,
        address indexed seller,
        address indexed token,
        uint256 amount,
        bytes32 orderId
    );

    /// @notice Emitted when batch settlement occurs
    /// @param batchId Batch identifier
    /// @param count Number of settlements
    event BatchSettlement(
        bytes32 indexed batchId,
        uint256 indexed count
    );

    /// @notice Emitted when private DEX trade is settled
    /// @param buyer Buyer address (public)
    /// @param seller Seller address (public)
    /// @param token Token address on COTI (pXOM)
    /// @param encryptedAmount Encrypted amount (ctUint64 as bytes32)
    /// @param cotiTxHash COTI transaction hash
    /// @param cotiBlockNumber COTI block number
    event PrivateDEXSettlement(
        address indexed buyer,
        address indexed seller,
        address indexed token,
        bytes32 encryptedAmount,
        bytes32 cotiTxHash,
        uint256 cotiBlockNumber
    );

    /// @notice Emitted when batch private settlement occurs
    /// @param batchId Batch identifier
    /// @param count Number of settlements
    /// @param cotiBlockNumber COTI block number
    event BatchPrivateSettlement(
        bytes32 indexed batchId,
        uint256 indexed count,
        uint256 cotiBlockNumber
    );

    /// @notice Emitted when required signatures count is updated
    /// @param newCount New required signature count
    event RequiredSignaturesUpdated(uint256 indexed newCount);

    // Custom errors
    error InvalidAddress();
    error InvalidAmount();
    error InvalidSignature();
    error StakeNotFound();
    error StakeLocked();
    error Unauthorized();
    error DuplicateSigner();
    error InsufficientSignatures();

    /**
     * @notice Constructor that disables initializers for the implementation contract
     * @dev Prevents the implementation contract from being initialized
     */
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the upgradeable OmniCore
     * @dev Replaces constructor, can only be called once
     * @param admin Address to grant admin role
     * @param _omniCoin Address of OmniCoin token
     * @param _oddaoAddress ODDAO fee recipient (70% of fees)
     * @param _stakingPoolAddress Staking pool fee recipient (20% of fees)
     */
    function initialize(
        address admin,
        address _omniCoin,
        address _oddaoAddress,
        address _stakingPoolAddress
    ) public initializer {
        if (admin == address(0) || _omniCoin == address(0) ||
            _oddaoAddress == address(0) || _stakingPoolAddress == address(0)) {
            revert InvalidAddress();
        }

        // Initialize inherited contracts
        __AccessControl_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        // Set up roles
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);

        // Initialize state
        OMNI_COIN = IERC20(_omniCoin);
        oddaoAddress = _oddaoAddress;
        stakingPoolAddress = _stakingPoolAddress;
        requiredSignatures = 1;
    }

    /**
     * @notice V2 initializer — sets new state added after initial deployment
     * @dev Called once after upgradeProxy to initialize requiredSignatures.
     *      reinitializer(2) ensures it can only run once and cannot re-run initialize().
     */
    function initializeV2() external reinitializer(2) {
        requiredSignatures = 1;
    }

    /**
     * @notice Authorize contract upgrades
     * @dev Required by UUPSUpgradeable, only admin can upgrade
     * @param newImplementation Address of new implementation
     */
    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyRole(ADMIN_ROLE)
    {} // solhint-disable-line no-empty-blocks

    // =============================================================================
    // Service Registry & Validator Management
    // =============================================================================

    /**
     * @notice Register or update a service in the registry
     * @dev Only admin can update services
     * @param name Service identifier
     * @param serviceAddress Address of the service contract
     */
    function setService(bytes32 name, address serviceAddress) external onlyRole(ADMIN_ROLE) {
        if (serviceAddress == address(0)) revert InvalidAddress();
        services[name] = serviceAddress;
        emit ServiceUpdated(name, serviceAddress, block.timestamp); // solhint-disable-line not-rely-on-time
    }

    /**
     * @notice Add or remove a validator
     * @dev Only admin can manage validators
     * @param validator Address of the validator
     * @param active Whether validator should be active
     */
    function setValidator(address validator, bool active) external onlyRole(ADMIN_ROLE) {
        if (validator == address(0)) revert InvalidAddress();
        validators[validator] = active;

        if (active) {
            _grantRole(AVALANCHE_VALIDATOR_ROLE, validator);
        } else {
            _revokeRole(AVALANCHE_VALIDATOR_ROLE, validator);
        }

        emit ValidatorUpdated(validator, active, block.timestamp); // solhint-disable-line not-rely-on-time
    }

    /**
     * @notice Set required number of validator signatures for legacy claims
     * @dev Only admin can change the multi-sig threshold
     * @param count Number of required signatures (1 to MAX_REQUIRED_SIGNATURES)
     */
    function setRequiredSignatures(uint256 count) external onlyRole(ADMIN_ROLE) {
        if (count == 0 || count > MAX_REQUIRED_SIGNATURES) revert InvalidAmount();
        requiredSignatures = count;
        emit RequiredSignaturesUpdated(count);
    }

    // =============================================================================
    // Staking Functions
    // =============================================================================

    /**
     * @notice Stake tokens with minimal on-chain data
     * @dev Locks tokens on-chain, reward calculation done by StakingRewardPool
     * @param amount Amount of tokens to stake
     * @param tier Staking tier (determines APR in StakingRewardPool)
     * @param duration Lock duration in seconds
     */
    function stake(
        uint256 amount,
        uint256 tier,
        uint256 duration
    ) external nonReentrant {
        if (amount == 0) revert InvalidAmount();
        if (stakes[msg.sender].active) revert InvalidAmount();

        // Transfer tokens from user
        OMNI_COIN.safeTransferFrom(msg.sender, address(this), amount);

        // Store minimal stake data
        stakes[msg.sender] = Stake({
            amount: amount,
            tier: tier,
            duration: duration,
            lockTime: block.timestamp + duration, // solhint-disable-line not-rely-on-time
            active: true
        });

        totalStaked += amount;

        emit TokensStaked(msg.sender, amount, tier, duration);
    }

    /**
     * @notice Unlock staked tokens after lock period
     * @dev Returns principal only. Rewards handled by StakingRewardPool contract.
     *      Call StakingRewardPool.snapshotRewards() BEFORE this to preserve rewards.
     */
    function unlock() external nonReentrant {
        Stake storage userStake = stakes[msg.sender];

        if (!userStake.active) revert StakeNotFound();
        if (block.timestamp < userStake.lockTime) revert StakeLocked(); // solhint-disable-line not-rely-on-time

        uint256 amount = userStake.amount;

        // Clear stake
        userStake.active = false;
        userStake.amount = 0;
        totalStaked -= amount;

        // Transfer tokens back
        OMNI_COIN.safeTransfer(msg.sender, amount);

        emit TokensUnlocked(msg.sender, amount, block.timestamp); // solhint-disable-line not-rely-on-time
    }

    // =============================================================================
    // DEX Settlement Functions
    // @deprecated Use DEXSettlement.sol for trustless EIP-712 settlement instead.
    //             These functions are kept for storage layout safety (dexBalances)
    //             and backward compatibility during migration.
    // =============================================================================

    /**
     * @notice Settle a DEX trade
     * @dev All order matching happens off-chain in validators
     * @param buyer Buyer address
     * @param seller Seller address
     * @param token Token being traded
     * @param amount Amount of tokens
     * @param orderId Off-chain order identifier
     * @dev DEPRECATED: Use DEXSettlement.sol settleTrade() with EIP-712 signatures
     */
    function settleDEXTrade(
        address buyer,
        address seller,
        address token,
        uint256 amount,
        bytes32 orderId
    ) external onlyRole(AVALANCHE_VALIDATOR_ROLE) {
        if (buyer == address(0) || seller == address(0) || token == address(0)) {
            revert InvalidAddress();
        }
        if (amount == 0) revert InvalidAmount();

        // Simple balance transfer
        if (dexBalances[seller][token] < amount) revert InvalidAmount();

        dexBalances[seller][token] -= amount;
        dexBalances[buyer][token] += amount;

        emit DEXSettlement(buyer, seller, token, amount, orderId);
    }

    /**
     * @notice Batch settle multiple DEX trades
     * @dev Efficient batch processing for gas optimization
     * @param buyers Array of buyer addresses
     * @param sellers Array of seller addresses
     * @param tokens Array of token addresses
     * @param amounts Array of amounts
     * @param batchId Batch identifier
     * @dev DEPRECATED: Use DEXSettlement.sol for trustless settlement
     */
    function batchSettleDEX(
        address[] calldata buyers,
        address[] calldata sellers,
        address[] calldata tokens,
        uint256[] calldata amounts,
        bytes32 batchId
    ) external onlyRole(AVALANCHE_VALIDATOR_ROLE) {
        uint256 length = buyers.length;
        if (length == 0 || length != sellers.length ||
            length != tokens.length || length != amounts.length) {
            revert InvalidAmount();
        }

        for (uint256 i = 0; i < length; ++i) {
            if (
                dexBalances[sellers[i]][tokens[i]] > amounts[i] ||
                dexBalances[sellers[i]][tokens[i]] == amounts[i]
            ) {
                dexBalances[sellers[i]][tokens[i]] -= amounts[i];
                dexBalances[buyers[i]][tokens[i]] += amounts[i];
            }
        }

        emit BatchSettlement(batchId, length);
    }

    /**
     * @notice Distribute DEX fees
     * @dev Called by validators to distribute fees according to tokenomics
     * @param token Fee token
     * @param totalFee Total fee amount
     * @param validator Validator processing the transaction
     * @dev DEPRECATED: Use DEXSettlement.sol for trustless fee distribution
     */
    function distributeDEXFees(
        address token,
        uint256 totalFee,
        address validator
    ) external onlyRole(AVALANCHE_VALIDATOR_ROLE) {
        if (totalFee == 0) return;

        // Calculate fee splits using basis points for precision
        uint256 oddaoFee = (totalFee * ODDAO_FEE_BPS) / BASIS_POINTS;
        uint256 stakingFee = (totalFee * STAKING_FEE_BPS) / BASIS_POINTS;
        uint256 validatorFee = totalFee - oddaoFee - stakingFee;

        if (oddaoFee > 0) {
            dexBalances[oddaoAddress][token] += oddaoFee;
        }
        if (stakingFee > 0) {
            dexBalances[stakingPoolAddress][token] += stakingFee;
        }
        if (validatorFee > 0) {
            dexBalances[validator][token] += validatorFee;
        }
    }

    // =============================================================================
    // Private DEX Settlement Functions (COTI V2 Integration)
    // @deprecated Use DEXSettlement.sol for trustless settlement
    // =============================================================================

    /**
     * @notice Settle a private DEX trade from COTI chain
     * @dev Called by validators after COTI PrivateDEX executes MPC matching
     * @param buyer Buyer address (public)
     * @param seller Seller address (public)
     * @param token Token address on COTI (pXOM)
     * @param encryptedAmount Encrypted trade amount from COTI MPC (ctUint64 as bytes32)
     * @param cotiTxHash Transaction hash on COTI chain (proof of execution)
     * @param cotiBlockNumber Block number on COTI chain
     * @dev DEPRECATED: Use DEXSettlement.sol for trustless settlement
     */
    function settlePrivateDEXTrade(
        address buyer,
        address seller,
        address token,
        bytes32 encryptedAmount,
        bytes32 cotiTxHash,
        uint256 cotiBlockNumber
    ) external onlyRole(AVALANCHE_VALIDATOR_ROLE) {
        if (buyer == address(0) || seller == address(0)) revert InvalidAddress();
        if (token == address(0)) revert InvalidAddress();
        if (cotiTxHash == bytes32(0)) revert InvalidSignature();

        emit PrivateDEXSettlement(
            buyer,
            seller,
            token,
            encryptedAmount,
            cotiTxHash,
            cotiBlockNumber
        );
    }

    /**
     * @notice Batch settle multiple private DEX trades from COTI
     * @dev Gas optimization for multiple private trades in one transaction
     * @param buyers Array of buyer addresses
     * @param sellers Array of seller addresses
     * @param tokens Array of token addresses
     * @param encryptedAmounts Array of encrypted amounts
     * @param cotiTxHashes Array of COTI transaction hashes
     * @param cotiBlockNumber COTI block number containing all trades
     * @dev DEPRECATED: Use DEXSettlement.sol for trustless settlement
     */
    function batchSettlePrivateDEX(
        address[] calldata buyers,
        address[] calldata sellers,
        address[] calldata tokens,
        bytes32[] calldata encryptedAmounts,
        bytes32[] calldata cotiTxHashes,
        uint256 cotiBlockNumber
    ) external onlyRole(AVALANCHE_VALIDATOR_ROLE) {
        uint256 count = buyers.length;
        if (
            sellers.length != count ||
            tokens.length != count ||
            encryptedAmounts.length != count ||
            cotiTxHashes.length != count
        ) revert InvalidAmount();

        for (uint256 i = 0; i < count; ++i) {
            if (buyers[i] == address(0) || sellers[i] == address(0)) revert InvalidAddress();
            if (tokens[i] == address(0)) revert InvalidAddress();

            emit PrivateDEXSettlement(
                buyers[i],
                sellers[i],
                tokens[i],
                encryptedAmounts[i],
                cotiTxHashes[i],
                cotiBlockNumber
            );
        }

        bytes32 batchId = keccak256(abi.encodePacked(
            block.number,
            cotiBlockNumber,
            count
        ));

        emit BatchPrivateSettlement(batchId, count, cotiBlockNumber);
    }

    /**
     * @notice Deposit tokens to DEX
     * @dev Simple deposit for trading
     * @param token Token to deposit
     * @param amount Amount to deposit
     */
    function depositToDEX(address token, uint256 amount) external nonReentrant {
        if (token == address(0) || amount == 0) revert InvalidAmount();

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        dexBalances[msg.sender][token] += amount;
    }

    /**
     * @notice Withdraw tokens from DEX
     * @dev Simple withdrawal
     * @param token Token to withdraw
     * @param amount Amount to withdraw
     */
    function withdrawFromDEX(address token, uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidAmount();
        if (dexBalances[msg.sender][token] < amount) revert InvalidAmount();

        dexBalances[msg.sender][token] -= amount;
        IERC20(token).safeTransfer(msg.sender, amount);
    }

    // =============================================================================
    // View Functions
    // =============================================================================

    /**
     * @notice Get service address by name
     * @param name Service identifier
     * @return serviceAddress Address of the service
     */
    function getService(bytes32 name) external view returns (address serviceAddress) {
        return services[name];
    }

    /**
     * @notice Check if an address is an active validator
     * @param validator Address to check
     * @return active Whether the address is an active validator
     */
    function isValidator(address validator) external view returns (bool active) {
        return validators[validator];
    }

    /**
     * @notice Get stake information for a user
     * @param user Address of the staker
     * @return Stake information
     */
    function getStake(address user) external view returns (Stake memory) {
        return stakes[user];
    }

    /**
     * @notice Get DEX balance for a user
     * @param user User address
     * @param token Token address
     * @return balance DEX balance
     */
    function getDEXBalance(address user, address token) external view returns (uint256 balance) {
        return dexBalances[user][token];
    }

    // =============================================================================
    // Legacy Migration Functions (Added 2025-08-06)
    // =============================================================================

    /**
     * @notice Register legacy users and their balances
     * @dev Only callable by admin during initialization
     * @param usernames Array of legacy usernames to reserve
     * @param balances Array of balances in 18 decimal precision
     * @param publicKeys Array of legacy user account public keys
     */
    function registerLegacyUsers(
        string[] calldata usernames,
        uint256[] calldata balances,
        bytes[] calldata publicKeys
    ) external onlyRole(ADMIN_ROLE) {
        if (usernames.length != balances.length || usernames.length != publicKeys.length) {
            revert InvalidAmount();
        }
        if (usernames.length > 100) revert InvalidAmount(); // Gas limit protection

        uint256 totalAmount = 0;

        for (uint256 i = 0; i < usernames.length; ++i) {
            bytes32 usernameHash = keccak256(abi.encodePacked(usernames[i]));

            // Skip if already registered
            if (legacyUsernames[usernameHash]) continue;

            // Reserve username and store balance and public key
            legacyUsernames[usernameHash] = true;
            legacyBalances[usernameHash] = balances[i];
            legacyAccounts[usernameHash] = publicKeys[i];
            totalAmount += balances[i];
        }

        totalLegacySupply += totalAmount;

        emit LegacyUsersRegistered(usernames.length, totalAmount);
    }

    /**
     * @notice Claim legacy balance with M-of-N validator signatures
     * @dev Validators verify legacy credentials off-chain; multiple signatures required
     * @param username Legacy username
     * @param claimAddress Address to receive the tokens
     * @param nonce Unique nonce to prevent replay
     * @param signatures Array of validator signatures authorizing the claim
     */
    function claimLegacyBalance(
        string calldata username,
        address claimAddress,
        bytes32 nonce,
        bytes[] calldata signatures
    ) external nonReentrant {
        if (claimAddress == address(0)) revert InvalidAddress();
        if (signatures.length < requiredSignatures) revert InsufficientSignatures();

        bytes32 usernameHash = keccak256(abi.encodePacked(username));

        // Check username is registered and not claimed
        if (!legacyUsernames[usernameHash]) revert InvalidAddress();
        if (legacyClaimed[usernameHash] != address(0)) revert InvalidAmount();

        // Compute message hash
        bytes32 messageHash = keccak256(abi.encodePacked(
            username,
            claimAddress,
            nonce,
            address(this),
            block.chainid
        ));

        bytes32 ethSignedMessageHash = keccak256(abi.encodePacked(
            "\x19Ethereum Signed Message:\n32",
            messageHash
        ));

        // Verify each signature is from a unique active validator
        uint256 sigCount = signatures.length;
        address[] memory signers = new address[](sigCount);

        for (uint256 i = 0; i < sigCount; ++i) {
            address signer = _recoverSigner(ethSignedMessageHash, signatures[i]);
            if (!validators[signer]) revert InvalidSignature();

            // Check for duplicate signers
            for (uint256 j = 0; j < i; ++j) {
                if (signers[j] == signer) revert DuplicateSigner();
            }
            signers[i] = signer;
        }

        // Get balance and mark as claimed
        uint256 amount = legacyBalances[usernameHash];
        legacyClaimed[usernameHash] = claimAddress;
        totalLegacyClaimed += amount;

        // Transfer tokens (must be pre-minted to this contract)
        OMNI_COIN.safeTransfer(claimAddress, amount);

        emit LegacyBalanceClaimed(
            username,
            claimAddress,
            amount,
            block.timestamp // solhint-disable-line not-rely-on-time
        );
    }

    /**
     * @notice Check if a legacy username is available
     * @param username Username to check
     * @return available True if not reserved by legacy system
     */
    function isUsernameAvailable(string calldata username) external view returns (bool available) {
        bytes32 usernameHash = keccak256(abi.encodePacked(username));
        return !legacyUsernames[usernameHash];
    }

    /**
     * @notice Get legacy migration status for a username
     * @param username Legacy username
     * @return reserved Whether username is reserved
     * @return balance Legacy balance to claim
     * @return claimed Whether balance has been claimed
     * @return claimAddress Address that claimed (if any)
     * @return publicKey Legacy account public key
     */
    function getLegacyStatus(string calldata username) external view returns (
        bool reserved,
        uint256 balance,
        bool claimed,
        address claimAddress,
        bytes memory publicKey
    ) {
        bytes32 usernameHash = keccak256(abi.encodePacked(username));
        reserved = legacyUsernames[usernameHash];
        balance = legacyBalances[usernameHash];
        claimAddress = legacyClaimed[usernameHash];
        claimed = (claimAddress != address(0));
        publicKey = legacyAccounts[usernameHash];
    }

    // =============================================================================
    // Internal Functions
    // =============================================================================

    /**
     * @notice Internal function to recover signer from signature
     * @param messageHash Hash of the signed message
     * @param signature Signature bytes (65 bytes: r + s + v)
     * @return Recovered signer address
     */
    function _recoverSigner(
        bytes32 messageHash,
        bytes memory signature
    ) internal pure returns (address) {
        if (signature.length != 65) revert InvalidSignature();

        bytes32 r;
        bytes32 s;
        uint8 v;

        // solhint-disable-next-line no-inline-assembly
        assembly {
            r := mload(add(signature, 32))
            s := mload(add(signature, 64))
            v := byte(0, mload(add(signature, 96)))
        }

        return ecrecover(messageHash, v, r, s);
    }
}
