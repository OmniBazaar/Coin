# Solidity Coding Standards for Claude

## MANDATORY: Always Follow These Rules When Writing Solidity Code

### 1. NatSpec Documentation (REQUIRED for ALL elements)

#### Contracts
```solidity
/**
 * @title ContractName
 * @author OmniCoin Development Team
 * @notice Brief description of what the contract does
 * @dev Technical details about implementation
 */
contract ContractName {
```

#### State Variables
```solidity
/// @notice Description of what this variable stores
uint256 public someVariable;

/// @notice Mapping of user addresses to their balances
/// @dev Used for tracking user funds in the system
mapping(address => uint256) public balances;
```

#### Constants
```solidity
/// @notice Basis points for percentage calculations (100% = 10000)
uint256 public constant BASIS_POINTS = 10000;
```

#### Events
```solidity
/// @notice Emitted when a transfer occurs
/// @param from Address sending the tokens
/// @param to Address receiving the tokens
/// @param amount Number of tokens transferred
/// @param timestamp Block timestamp of transfer
event Transfer(
    address indexed from,
    address indexed to,
    uint256 indexed amount,
    uint256 timestamp
);
```

#### Functions
```solidity
/**
 * @notice Transfer tokens from sender to recipient
 * @dev Includes safety checks and emits Transfer event
 * @param recipient Address to receive the tokens
 * @param amount Number of tokens to transfer
 * @return success Whether the transfer succeeded
 */
function transfer(address recipient, uint256 amount) external returns (bool success) {
```

#### Modifiers
```solidity
/**
 * @notice Ensures caller has the specified role
 * @param role The role identifier to check
 */
modifier onlyRole(bytes32 role) {
```

### 2. Ordering (Follow Solidity Style Guide)

1. Pragma statements
2. Import statements
3. Interfaces
4. Libraries
5. Contracts
   - Type declarations (enums, structs)
   - State variables
     - Constants (with NatSpec)
     - Immutable variables (with NatSpec)
     - Public variables (with NatSpec)
     - Internal variables (with NatSpec)
     - Private variables (with NatSpec)
   - Events (with full NatSpec including all @param tags)
   - Errors
   - Modifiers (with NatSpec)
   - Constructor (with NatSpec)
   - External functions
   - Public functions
   - Internal functions
   - Private functions

### 3. Gas Optimizations

#### Events
- Index up to 3 parameters that will be used for filtering
- Prioritize: addresses, IDs, and key values
- Don't index strings or bytes (too expensive)

```solidity
event Transfer(
    address indexed from,    // ✓ Indexed for filtering
    address indexed to,      // ✓ Indexed for filtering
    uint256 indexed tokenId, // ✓ Indexed for filtering
    uint256 amount,         // Not indexed (4th parameter)
    uint256 timestamp       // Not indexed
);
```

#### Custom Errors (Use instead of require)
```solidity
// ❌ OLD WAY
require(balance >= amount, "Insufficient balance");

// ✅ NEW WAY
error InsufficientBalance(uint256 required, uint256 available);
if (balance < amount) revert InsufficientBalance(amount, balance);
```

#### Struct Packing
```solidity
// ❌ BAD: Uses 3 storage slots
struct User {
    uint256 balance;    // 32 bytes (slot 1)
    bool active;        // 1 byte  (slot 2)
    address wallet;     // 20 bytes (slot 3)
}

// ✅ GOOD: Uses 2 storage slots
struct User {
    uint256 balance;    // 32 bytes (slot 1)
    address wallet;     // 20 bytes (slot 2)
    bool active;        // 1 byte  (slot 2)
    // 11 bytes padding in slot 2
}
```

### 4. Time Dependencies

When using block.timestamp:
```solidity
// If business logic requires it, disable the warning with explanation
uint256 deadline = block.timestamp + 7 days; // solhint-disable-line not-rely-on-time
```

### 5. Line Length

- Maximum 120 characters per line
- Break long function calls:
```solidity
// ❌ TOO LONG
require(hasRole(ADMIN_ROLE, msg.sender) || hasRole(MODERATOR_ROLE, msg.sender), "Unauthorized");

// ✅ BETTER
require(
    hasRole(ADMIN_ROLE, msg.sender) || 
    hasRole(MODERATOR_ROLE, msg.sender), 
    "Unauthorized"
);
```

### 6. Function Complexity

Break complex functions into smaller pieces:
```solidity
// ❌ TOO COMPLEX
function processPayment(uint256 amount, address recipient) external {
    // 50 lines of validation
    // 30 lines of calculation
    // 20 lines of transfers
}

// ✅ BETTER
function processPayment(uint256 amount, address recipient) external {
    _validatePayment(amount, recipient);
    uint256 fee = _calculateFee(amount);
    _executeTransfer(amount, fee, recipient);
}
```

## Checklist Before Submitting Code

- [ ] Every contract has @title, @author, @notice, @dev
- [ ] Every state variable has @notice
- [ ] Every function has @notice, @dev (if needed), @param (all params), @return (if applicable)
- [ ] Every event has @notice and @param for ALL parameters
- [ ] Events have up to 3 indexed parameters for key fields
- [ ] Using custom errors instead of require statements
- [ ] Structs are packed efficiently
- [ ] Code follows correct ordering
- [ ] Lines are under 120 characters
- [ ] Complex functions are broken into smaller pieces
- [ ] block.timestamp usage is justified with solhint-disable-line if needed

## Example: Fully Compliant Contract

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title ExampleVault
 * @author OmniCoin Development Team
 * @notice Secure vault for storing user funds with time-locked withdrawals
 * @dev Implements role-based access control and emergency pause functionality
 */
contract ExampleVault is AccessControl {
    // Type declarations
    struct Deposit {
        uint256 amount;
        uint256 unlockTime;
        address owner;
        bool withdrawn;
    }

    // State variables
    /// @notice Role identifier for vault managers
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    
    /// @notice Minimum lock period for deposits (7 days)
    uint256 public constant MIN_LOCK_PERIOD = 7 days;
    
    /// @notice Mapping of deposit ID to deposit data
    mapping(uint256 => Deposit) public deposits;
    
    /// @notice Counter for generating unique deposit IDs
    uint256 public nextDepositId;

    // Events
    /// @notice Emitted when a new deposit is created
    /// @param depositId Unique identifier for the deposit
    /// @param owner Address that made the deposit
    /// @param amount Value deposited
    /// @param unlockTime When the deposit can be withdrawn
    event DepositCreated(
        uint256 indexed depositId,
        address indexed owner,
        uint256 indexed amount,
        uint256 unlockTime
    );

    // Errors
    error InvalidAmount();
    error DepositLocked(uint256 unlockTime, uint256 currentTime);
    error AlreadyWithdrawn();
    error Unauthorized();

    /**
     * @notice Initialize the vault with an admin
     * @param admin Address to grant admin role
     */
    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(MANAGER_ROLE, admin);
    }

    /**
     * @notice Create a new time-locked deposit
     * @dev Locks funds for at least MIN_LOCK_PERIOD
     * @param lockDuration How long to lock the funds (in seconds)
     * @return depositId Unique identifier for this deposit
     */
    function deposit(uint256 lockDuration) external payable returns (uint256 depositId) {
        if (msg.value == 0) revert InvalidAmount();
        if (lockDuration < MIN_LOCK_PERIOD) lockDuration = MIN_LOCK_PERIOD;
        
        depositId = nextDepositId++;
        deposits[depositId] = Deposit({
            amount: msg.value,
            unlockTime: block.timestamp + lockDuration, // solhint-disable-line not-rely-on-time
            owner: msg.sender,
            withdrawn: false
        });
        
        emit DepositCreated(depositId, msg.sender, msg.value, deposits[depositId].unlockTime);
    }
}
```

## Running Solhint

Always check your code before submitting:
```bash
npx solhint contracts/YourContract.sol
```

Fix ALL warnings except:
- `not-rely-on-time` IF business logic requires timestamps (add disable comment)
- Config warnings about missing rules (contract-name-camelcase, event-name-camelcase)