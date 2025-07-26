# COTI V2 MPC Integration Guide

**Created**: 2025-07-24  
**Purpose**: Document the correct usage of COTI V2 MPC (Multi-Party Computation) functions for privacy-enabled smart contracts

---

## 🔐 Overview

COTI V2 uses MPC (Multi-Party Computation) with Garbled Circuits to provide privacy for smart contract data. This guide documents the correct function usage patterns discovered during the FeeDistribution.sol privacy integration.

---

## 📚 Key Concepts

### Data Types

COTI V2 uses different types for different stages of encrypted data:

1. **`gtUint64`** (Garbled Type) - Used for computations within functions
2. **`ctUint64`** (Ciphertext Type) - Used for storage in contract state
3. **`itUint64`** (Input Type) - Used for external encrypted inputs
4. **`utUint64`** (User Type) - Struct containing both ciphertext and user-specific ciphertext

### The MpcCore Library

All MPC functions are accessed through the `MpcCore` library, which must be imported:

```solidity
import "../coti-contracts/contracts/utils/mpc/MpcCore.sol";
```

The contract must also inherit from `MpcCore`:

```solidity
contract MyContract is MpcCore {
    // contract code
}
```

---

## 🛠️ Essential Functions

### 1. Creating Encrypted Values from Public Values

```solidity
// For 64-bit unsigned integers
gtUint64 encrypted = MpcCore.setPublic64(uint64(plainValue));

// For booleans
gtBool encrypted = MpcCore.setPublic(boolValue);

// For other sizes
gtUint8 encrypted = MpcCore.setPublic8(uint8(plainValue));
gtUint16 encrypted = MpcCore.setPublic16(uint16(plainValue));
gtUint32 encrypted = MpcCore.setPublic32(uint32(plainValue));
```

### 2. Converting Between Computation and Storage Types

```solidity
// From computation type (gt) to storage type (ct)
ctUint64 forStorage = MpcCore.offBoard(gtValue);

// From storage type (ct) to computation type (gt)
gtUint64 forComputation = MpcCore.onBoard(ctValue);

// To user-specific ciphertext (for specific address)
ctUint64 userCiphertext = MpcCore.offBoardToUser(gtValue, userAddress);
```

### 3. Arithmetic Operations

All operations work on `gt` types and return `gt` types:

```solidity
gtUint64 sum = MpcCore.add(gtA, gtB);
gtUint64 difference = MpcCore.sub(gtA, gtB);
gtUint64 product = MpcCore.mul(gtA, gtB);
gtUint64 quotient = MpcCore.div(gtA, gtB);
gtUint64 remainder = MpcCore.rem(gtA, gtB);
```

### 4. Comparison Operations

Comparisons return `gtBool` type:

```solidity
gtBool isEqual = MpcCore.eq(gtA, gtB);
gtBool isNotEqual = MpcCore.ne(gtA, gtB);
gtBool isGreater = MpcCore.gt(gtA, gtB);
gtBool isGreaterOrEqual = MpcCore.ge(gtA, gtB);
gtBool isLess = MpcCore.lt(gtA, gtB);
gtBool isLessOrEqual = MpcCore.le(gtA, gtB);
```

### 5. Decrypting Values

```solidity
// Decrypt to plain value (only for authorized parties)
uint64 plainValue = MpcCore.decrypt(gtValue);
bool plainBool = MpcCore.decrypt(gtBool);
```

---

## 💡 Common Patterns

### Pattern 1: Initializing Encrypted Storage

```solidity
// Create encrypted zero
gtUint64 gtZero = MpcCore.setPublic64(uint64(0));
ctUint64 ctZero = MpcCore.offBoard(gtZero);

// Store in state variable
mapping(address => ctUint64) private encryptedBalances;
encryptedBalances[user] = ctZero;
```

### Pattern 2: Checking if Encrypted Value is Zero

```solidity
// Load from storage
gtUint64 gtValue = MpcCore.onBoard(encryptedBalance);

// Create zero for comparison
gtUint64 gtZero = MpcCore.setPublic64(uint64(0));

// Compare
gtBool isZero = MpcCore.eq(gtValue, gtZero);

// Use in conditional
if (MpcCore.decrypt(isZero)) {
    // Value is zero
}
```

### Pattern 3: Adding to Encrypted Balance

```solidity
// Load current balance
gtUint64 gtCurrentBalance = MpcCore.onBoard(encryptedBalances[user]);

// Create amount to add
gtUint64 gtAmount = MpcCore.setPublic64(uint64(amount));

// Add
gtUint64 gtNewBalance = MpcCore.add(gtCurrentBalance, gtAmount);

// Store back
encryptedBalances[user] = MpcCore.offBoard(gtNewBalance);
```

### Pattern 4: Conditional Operations with Mux

```solidity
// Mux allows conditional selection without revealing the condition
gtUint64 result = MpcCore.mux(
    condition,  // gtBool
    valueIfTrue,  // gtUint64
    valueIfFalse  // gtUint64
);
```

---

## ⚠️ Important Notes

1. **Always use `gt` types for computations** - Never try to perform operations directly on `ct` types
2. **Convert before storing** - Always use `offBoard()` to convert `gt` to `ct` before storage
3. **Convert after loading** - Always use `onBoard()` to convert `ct` to `gt` for computation
4. **Decryption is revealing** - Only decrypt when absolutely necessary and ensure proper access control
5. **No direct encryption** - There's no `encrypt()` function; use `setPublic64()` + `offBoard()`

---

## 🔧 Example: Privacy-Enabled Reward Distribution

```solidity
function distributePrivateReward(address validator, uint256 rewardAmount) internal {
    // 1. Convert plain amount to encrypted
    gtUint64 gtReward = MpcCore.setPublic64(uint64(rewardAmount));
    
    // 2. Load current encrypted balance
    gtUint64 gtCurrentBalance = MpcCore.onBoard(privateRewards[validator]);
    
    // 3. Add reward to balance
    gtUint64 gtNewBalance = MpcCore.add(gtCurrentBalance, gtReward);
    
    // 4. Store updated encrypted balance
    privateRewards[validator] = MpcCore.offBoard(gtNewBalance);
    
    // 5. Emit event with privacy (hash instead of actual amount)
    bytes32 rewardHash = keccak256(abi.encode(validator, block.timestamp));
    emit PrivateRewardDistributed(validator, rewardHash);
}
```

---

## 🐛 Common Errors and Solutions

### Error: "Undeclared identifier MPC"
**Solution**: Use `MpcCore.functionName()` not `MPC.functionName()`

### Error: "Cannot convert ctUint64 to gtUint64"
**Solution**: Use `MpcCore.onBoard()` to convert storage type to computation type

### Error: Operations on ct types
**Solution**: Always convert to gt types before operations:
```solidity
// Wrong
ctUint64 result = ctA + ctB;

// Correct
gtUint64 gtA = MpcCore.onBoard(ctA);
gtUint64 gtB = MpcCore.onBoard(ctB);
gtUint64 gtResult = MpcCore.add(gtA, gtB);
ctUint64 result = MpcCore.offBoard(gtResult);
```

---

## 📋 Function Reference

### Type Conversion
- `setPublic64(uint64)` → `gtUint64`
- `onBoard(ctUint64)` → `gtUint64`
- `offBoard(gtUint64)` → `ctUint64`
- `offBoardToUser(gtUint64, address)` → `ctUint64`
- `decrypt(gtUint64)` → `uint64`

### Arithmetic
- `add(gtUint64, gtUint64)` → `gtUint64`
- `sub(gtUint64, gtUint64)` → `gtUint64`
- `mul(gtUint64, gtUint64)` → `gtUint64`
- `div(gtUint64, gtUint64)` → `gtUint64`

### Comparison
- `eq(gtUint64, gtUint64)` → `gtBool`
- `gt(gtUint64, gtUint64)` → `gtBool`
- `lt(gtUint64, gtUint64)` → `gtBool`

### Boolean Operations
- `and(gtBool, gtBool)` → `gtBool`
- `or(gtBool, gtBool)` → `gtBool`
- `not(gtBool)` → `gtBool`

---

This guide should be referenced whenever implementing privacy features using COTI V2's MPC functionality.