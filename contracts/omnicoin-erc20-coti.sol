// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20CappedUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts/utils/Address.sol";

/**
 * @title OmniCoin
 * @dev OmniCoin is an ERC20 token with COTI integration, featuring:
 * - Upgradeable contract
 * - Capped supply
 * - Pausable functionality
 * - Staking capabilities
 * - Privacy features
 * - Cross-chain bridging support
 * - Account abstraction
 * - DAO governance
 */
contract OmniCoin is 
    Initializable,
    ERC20Upgradeable,
    ERC20CappedUpgradeable,
    ERC20PausableUpgradeable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable
{
    using Address for address;

    // Constants
    uint256 public constant MAX_CAP = 1_000_000_000 * 10**18; // 1 billion tokens with 18 decimals
    uint256 public constant MIN_STAKE_AMOUNT = 1000 * 10**18; // 1000 tokens minimum stake
    uint256 public constant STAKE_LOCK_PERIOD = 30 days;
    
    // Staking structures
    struct Stake {
        uint256 amount;
        uint256 startTime;
        uint256 lockPeriod;
        bool isActive;
    }

    // Privacy structures
    struct PrivacySettings {
        bool isPrivate;
        address encryptionAddress;
    }

    // State variables
    mapping(address => Stake) public stakes;
    mapping(address => PrivacySettings) public privacySettings;
    mapping(address => uint256) public reputationScores;
    mapping(address => bool) public validators;
    mapping(string => address) public usernameToAddress;
    mapping(address => string) public addressToUsername;

    // Events
    event Staked(address indexed user, uint256 amount, uint256 lockPeriod);
    event Unstaked(address indexed user, uint256 amount);
    event ValidatorAdded(address indexed validator);
    event ValidatorRemoved(address indexed validator);
    event PrivacySettingsUpdated(address indexed user, bool isPrivate);
    event UsernameRegistered(address indexed user, string username);
    event ReputationUpdated(address indexed user, uint256 newScore);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Initializes the contract with the token name and symbol
     */
    function initialize() public initializer {
        __ERC20_init("OmniCoin", "OMNI");
        __ERC20Capped_init(MAX_CAP);
        __ERC20Pausable_init();
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();
    }

    /**
     * @dev Mints new tokens. Only callable by owner
     */
    function mint(address to, uint256 amount) public onlyOwner {
        _mint(to, amount);
    }

    /**
     * @dev Pauses all token transfers
     */
    function pause() public onlyOwner {
        _pause();
    }

    /**
     * @dev Unpauses all token transfers
     */
    function unpause() public onlyOwner {
        _unpause();
    }

    /**
     * @dev Stakes tokens for a specified period
     */
    function stake(uint256 amount, uint256 lockPeriod) external nonReentrant {
        require(amount >= MIN_STAKE_AMOUNT, "Stake amount too low");
        require(lockPeriod >= STAKE_LOCK_PERIOD, "Lock period too short");
        require(balanceOf(msg.sender) >= amount, "Insufficient balance");

        // Transfer tokens to contract
        _transfer(msg.sender, address(this), amount);

        // Create or update stake
        stakes[msg.sender] = Stake({
            amount: amount,
            startTime: block.timestamp,
            lockPeriod: lockPeriod,
            isActive: true
        });

        emit Staked(msg.sender, amount, lockPeriod);
    }

    /**
     * @dev Unstakes tokens after lock period
     */
    function unstake() external nonReentrant {
        Stake storage userStake = stakes[msg.sender];
        require(userStake.isActive, "No active stake");
        require(
            block.timestamp >= userStake.startTime + userStake.lockPeriod,
            "Stake still locked"
        );

        uint256 amount = userStake.amount;
        userStake.isActive = false;

        // Transfer tokens back to user
        _transfer(address(this), msg.sender, amount);

        emit Unstaked(msg.sender, amount);
    }

    /**
     * @dev Updates privacy settings for an address
     */
    function updatePrivacySettings(bool isPrivate, address encryptionAddress) external {
        privacySettings[msg.sender] = PrivacySettings({
            isPrivate: isPrivate,
            encryptionAddress: encryptionAddress
        });

        emit PrivacySettingsUpdated(msg.sender, isPrivate);
    }

    /**
     * @dev Registers a username for an address
     */
    function registerUsername(string calldata username) external {
        require(bytes(username).length > 0, "Username cannot be empty");
        require(usernameToAddress[username] == address(0), "Username already taken");
        require(bytes(addressToUsername[msg.sender]).length == 0, "Address already has username");

        usernameToAddress[username] = msg.sender;
        addressToUsername[msg.sender] = username;

        emit UsernameRegistered(msg.sender, username);
    }

    /**
     * @dev Updates reputation score for an address
     */
    function updateReputation(address user, uint256 newScore) external onlyOwner {
        reputationScores[user] = newScore;
        emit ReputationUpdated(user, newScore);
    }

    /**
     * @dev Adds a validator
     */
    function addValidator(address validator) external onlyOwner {
        validators[validator] = true;
        emit ValidatorAdded(validator);
    }

    /**
     * @dev Removes a validator
     */
    function removeValidator(address validator) external onlyOwner {
        validators[validator] = false;
        emit ValidatorRemoved(validator);
    }

    function _update(
        address from,
        address to,
        uint256 value
    ) internal virtual override(ERC20Upgradeable, ERC20CappedUpgradeable, ERC20PausableUpgradeable) {
        if (from != address(0)) { // Not a mint
            require(!paused(), "Token transfer while paused");
        }
        super._update(from, to, value);
    }

    /**
     * @dev Returns the current stake amount for an address
     */
    function getStakeAmount(address user) external view returns (uint256) {
        return stakes[user].amount;
    }

    /**
     * @dev Returns the reputation score for an address
     */
    function getReputationScore(address user) external view returns (uint256) {
        return reputationScores[user];
    }

    /**
     * @dev Returns whether an address is a validator
     */
    function isValidator(address user) external view returns (bool) {
        return validators[user];
    }
}
