// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./OmniCoin.sol";

/**
 * @title LegacyBalanceClaim
 * @notice Allows legacy OmniCoin V1 users to claim their balances in V2
 * @dev This is a TEMPORARY contract for migration purposes only
 *      Will be deprecated after migration period (~2 years)
 *
 * Architecture:
 * - Stores 4,735 legacy user balances indexed by username hash
 * - Backend validator validates username/password off-chain
 * - Only authorized validator can call claim() after validation
 * - Each username can only claim once
 * - Reserved usernames cannot be used for new signups
 *
 * Security:
 * - Passwords NEVER sent to blockchain (validated off-chain)
 * - Validator backend signs validation proof
 * - ReentrancyGuard protects against reentrancy attacks
 * - One-time claiming enforced
 */
contract LegacyBalanceClaim is Ownable, ReentrancyGuard {
    /// @notice Reference to OmniCoin token contract
    OmniCoin public immutable omniCoin;

    /// @notice Authorized validator backend service address
    address public validator;

    /// @notice Mapping from username hash to legacy balance (in Wei)
    mapping(bytes32 => uint256) public legacyBalances;

    /// @notice Mapping from username hash to claiming ETH address (0x0 if unclaimed)
    mapping(bytes32 => address) public claimedBy;

    /// @notice Mapping from username hash to reserved status
    mapping(bytes32 => bool) public reserved;

    /// @notice Total amount of XOM claimed so far
    uint256 public totalClaimed;

    /// @notice Total amount of XOM reserved for legacy users
    uint256 public totalReserved;

    /// @notice Whether migration has been finalized (no more claims allowed)
    bool public migrationFinalized;

    /// @notice Number of unique users who have claimed
    uint256 public uniqueClaimants;

    /// @notice Number of legacy usernames reserved
    uint256 public reservedCount;

    /// @notice Emitted when a legacy balance is successfully claimed
    event BalanceClaimed(
        string indexed username,
        address indexed ethAddress,
        uint256 amount,
        uint256 timestamp
    );

    /// @notice Emitted when migration is finalized
    event MigrationFinalized(
        uint256 totalClaimed,
        uint256 totalUnclaimed,
        address unclaimedRecipient,
        uint256 timestamp
    );

    /// @notice Emitted when validator address is updated
    event ValidatorUpdated(address indexed oldValidator, address indexed newValidator);

    /// @notice Emitted when contract is initialized with legacy balances
    event Initialized(uint256 userCount, uint256 totalAmount);

    /**
     * @notice Contract constructor
     * @param _omniCoin Address of the OmniCoin token contract
     */
    constructor(address _omniCoin) {
        require(_omniCoin != address(0), "Invalid OmniCoin address");
        omniCoin = OmniCoin(_omniCoin);
    }

    /**
     * @notice Initialize contract with legacy balances
     * @dev Can only be called once, before any claims
     * @param usernames Array of legacy usernames
     * @param balances Array of balances (in Wei, 18 decimals)
     */
    function initialize(
        string[] calldata usernames,
        uint256[] calldata balances
    ) external onlyOwner {
        require(reservedCount == 0, "Already initialized");
        require(usernames.length == balances.length, "Length mismatch");
        require(usernames.length > 0, "Empty arrays");

        uint256 total = 0;

        for (uint256 i = 0; i < usernames.length; i++) {
            require(bytes(usernames[i]).length > 0, "Empty username");
            require(balances[i] > 0, "Zero balance");

            bytes32 usernameHash = keccak256(bytes(usernames[i]));

            // Prevent duplicate usernames in initialization
            require(legacyBalances[usernameHash] == 0, "Duplicate username");

            legacyBalances[usernameHash] = balances[i];
            reserved[usernameHash] = true;
            total += balances[i];
            reservedCount++;
        }

        totalReserved = total;

        emit Initialized(usernames.length, total);
    }

    /**
     * @notice Claim legacy balance
     * @dev Only callable by authorized validator backend after password validation
     * @param username Legacy username
     * @param ethAddress New Ethereum address to receive tokens
     * @param validationProof Signature from validator backend proving password validation
     * @return success Whether the claim was successful
     */
    function claim(
        string calldata username,
        address ethAddress,
        bytes calldata validationProof
    ) external onlyValidator nonReentrant returns (bool success) {
        require(!migrationFinalized, "Migration finalized");
        require(bytes(username).length > 0, "Empty username");
        require(ethAddress != address(0), "Invalid address");

        bytes32 usernameHash = keccak256(bytes(username));

        require(legacyBalances[usernameHash] > 0, "No balance");
        require(claimedBy[usernameHash] == address(0), "Already claimed");

        // Verify validation proof (signed by validator backend)
        _verifyProof(username, ethAddress, validationProof);

        uint256 amount = legacyBalances[usernameHash];

        // Update state before external call (CEI pattern)
        claimedBy[usernameHash] = ethAddress;
        totalClaimed += amount;
        uniqueClaimants++;

        // Mint tokens to user's new Ethereum address
        omniCoin.mint(ethAddress, amount);

        emit BalanceClaimed(username, ethAddress, amount, block.timestamp);

        return true;
    }

    /**
     * @notice Check if username has unclaimed balance
     * @param username Username to check
     * @return balance Unclaimed balance (0 if already claimed or no balance)
     */
    function getUnclaimedBalance(string calldata username) external view returns (uint256 balance) {
        bytes32 usernameHash = keccak256(bytes(username));
        if (claimedBy[usernameHash] != address(0)) {
            return 0;
        }
        return legacyBalances[usernameHash];
    }

    /**
     * @notice Check if username is reserved (legacy user)
     * @param username Username to check
     * @return isReserved True if username belongs to a legacy user
     */
    function isReserved(string calldata username) external view returns (bool isReserved) {
        bytes32 usernameHash = keccak256(bytes(username));
        return reserved[usernameHash];
    }

    /**
     * @notice Check if username has already been claimed
     * @param username Username to check
     * @return isClaimed True if balance has been claimed
     * @return claimant Address that claimed the balance (0x0 if not claimed)
     */
    function getClaimed(string calldata username) external view returns (bool isClaimed, address claimant) {
        bytes32 usernameHash = keccak256(bytes(username));
        address claimer = claimedBy[usernameHash];
        return (claimer != address(0), claimer);
    }

    /**
     * @notice Get migration statistics
     * @return stats Struct containing migration statistics
     */
    function getStats() external view returns (
        uint256 _totalReserved,
        uint256 _totalClaimed,
        uint256 _totalUnclaimed,
        uint256 _uniqueClaimants,
        uint256 _reservedCount,
        uint256 _percentClaimed,
        bool _finalized
    ) {
        uint256 unclaimed = totalReserved - totalClaimed;
        uint256 percent = totalReserved > 0 ? (totalClaimed * 10000) / totalReserved : 0;

        return (
            totalReserved,
            totalClaimed,
            unclaimed,
            uniqueClaimants,
            reservedCount,
            percent, // Basis points (e.g., 7500 = 75.00%)
            migrationFinalized
        );
    }

    /**
     * @notice Finalize migration and handle unclaimed balances
     * @dev Can only be called by owner after migration period (~2 years)
     * @param unclaimedRecipient Address to send unclaimed balances (ODDAO or burn)
     */
    function finalizeMigration(address unclaimedRecipient) external onlyOwner {
        require(!migrationFinalized, "Already finalized");
        require(unclaimedRecipient != address(0), "Invalid recipient");

        uint256 unclaimed = totalReserved - totalClaimed;

        migrationFinalized = true;

        if (unclaimed > 0) {
            // Mint unclaimed balance to specified recipient (ODDAO or burn address)
            omniCoin.mint(unclaimedRecipient, unclaimed);
        }

        emit MigrationFinalized(totalClaimed, unclaimed, unclaimedRecipient, block.timestamp);
    }

    /**
     * @notice Set authorized validator backend address
     * @param _validator New validator address
     */
    function setValidator(address _validator) external onlyOwner {
        require(_validator != address(0), "Invalid validator");
        address oldValidator = validator;
        validator = _validator;
        emit ValidatorUpdated(oldValidator, _validator);
    }

    /**
     * @notice Verify validation proof from validator backend
     * @dev Uses ECDSA signature verification
     * @param username Username being claimed
     * @param ethAddress Ethereum address receiving tokens
     * @param validationProof Signature from validator backend
     */
    function _verifyProof(
        string calldata username,
        address ethAddress,
        bytes calldata validationProof
    ) internal view {
        // Create message hash
        bytes32 message = keccak256(abi.encodePacked(username, ethAddress, address(this)));
        bytes32 ethSignedMessage = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", message)
        );

        // Recover signer from signature
        address signer = _recoverSigner(ethSignedMessage, validationProof);
        require(signer == validator, "Invalid proof");
    }

    /**
     * @notice Recover signer address from signature
     * @param message Signed message hash
     * @param signature ECDSA signature
     * @return signer Address that signed the message
     */
    function _recoverSigner(
        bytes32 message,
        bytes memory signature
    ) internal pure returns (address signer) {
        require(signature.length == 65, "Invalid signature length");

        bytes32 r;
        bytes32 s;
        uint8 v;

        assembly {
            r := mload(add(signature, 32))
            s := mload(add(signature, 64))
            v := byte(0, mload(add(signature, 96)))
        }

        // Handle EIP-2 (homestead) signature malleability
        if (v < 27) {
            v += 27;
        }

        require(v == 27 || v == 28, "Invalid signature v value");

        return ecrecover(message, v, r, s);
    }

    /**
     * @notice Modifier to restrict function to validator backend only
     */
    modifier onlyValidator() {
        require(msg.sender == validator, "Not validator");
        _;
    }
}
