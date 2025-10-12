# Making OmniCore Upgradeable - Simplified Guide

**Document Version:** 2.0.0
**Created:** 2025-01-10
**Updated:** 2025-01-12
**Purpose:** Transform OmniCore from a non-upgradeable contract to an upgradeable proxy-based contract
**Context:** Local HardHat testing only - no state preservation needed
**Priority:** HIGH - Must be done before mainnet deployment

---

## 🚨 IMPORTANT CONTEXT

### Current Situation
- OmniCore is **only deployed on local HardHat** for testing
- **No production state exists** that needs to be preserved
- We can make breaking changes without migration concerns
- This is a **code refactoring task**, not a live migration

### Required Reading
1. `/home/rickc/OmniBazaar/Coin/contracts/OmniCore.sol` - Current implementation
2. `/home/rickc/OmniBazaar/Coin/SOLIDITY_CODING_STANDARDS.md` - Coding standards
3. OpenZeppelin UUPS Proxy documentation

### Why Make It Upgradeable?
- Future bug fixes without redeployment
- Add new features without losing contract address
- Mainnet readiness

---

## 📊 What Needs to Change

### Key Changes Required

1. **Contract Inheritance**
   - Change from: `AccessControl, ReentrancyGuard`
   - Change to: `AccessControlUpgradeable, ReentrancyGuardUpgradeable, UUPSUpgradeable`

2. **Constructor → Initialize Function**
   - Remove constructor
   - Add `initialize()` function with `initializer` modifier
   - Add empty constructor with `_disableInitializers()`

3. **Immutable Variables**
   - Convert `IERC20 public immutable OMNI_COIN` to regular storage variable
   - Initialize in `initialize()` function instead of constructor

4. **Storage Gap**
   - Add `uint256[50] private __gap;` for future upgrade compatibility

5. **Upgrade Authorization**
   - Add `_authorizeUpgrade()` function to control who can upgrade

---

## 🎯 Implementation Steps

### Step 1: Install Dependencies

```bash
cd /home/rickc/OmniBazaar/Coin
npm install @openzeppelin/contracts-upgradeable@^4.9.0
npm install @openzeppelin/hardhat-upgrades
```

Update `hardhat.config.ts`:

```typescript
import '@openzeppelin/hardhat-upgrades';
```

### Step 2: Create Upgradeable Version

**Create:** `OmniCoreUpgradeable.sol` (or modify existing `OmniCore.sol`)

**Key Code Changes:**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

// Change imports to upgradeable versions
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract OmniCoreUpgradeable is
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    // CHANGE 1: Remove "immutable" keyword
    IERC20 public OMNI_COIN;  // Was: IERC20 public immutable OMNI_COIN;

    // ... all other state variables stay the same ...

    // CHANGE 2: Add storage gap at the end
    uint256[50] private __gap;

    // CHANGE 3: Add empty constructor
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // CHANGE 4: Replace constructor with initialize
    function initialize(
        address admin,
        address _omniCoin,
        address _oddaoAddress,
        address _stakingPoolAddress
    ) public initializer {
        require(admin != address(0), "Invalid admin");
        require(_omniCoin != address(0), "Invalid token");
        require(_oddaoAddress != address(0), "Invalid ODDAO");
        require(_stakingPoolAddress != address(0), "Invalid staking pool");

        // Initialize inherited contracts
        __AccessControl_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        // Set up roles
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);

        // Initialize state (was in constructor)
        OMNI_COIN = IERC20(_omniCoin);
        oddaoAddress = _oddaoAddress;
        stakingPoolAddress = _stakingPoolAddress;
    }

    // CHANGE 5: Add upgrade authorization
    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyRole(ADMIN_ROLE)
    {}

    // All other functions remain EXACTLY the same
    // Just copy them from OmniCore.sol
}
```

### Step 3: Basic Testing

**Create Basic Test:** `test/OmniCoreUpgradeable.test.ts`

```typescript
import { expect } from "chai";
import { ethers, upgrades } from "hardhat";

describe("OmniCoreUpgradeable", function () {
    it("Should deploy and initialize", async function () {
        const [owner] = await ethers.getSigners();

        // Deploy mock token
        const MockToken = await ethers.getContractFactory("MockERC20");
        const token = await MockToken.deploy("OmniCoin", "XOM");

        // Deploy upgradeable OmniCore
        const OmniCore = await ethers.getContractFactory("OmniCoreUpgradeable");
        const omniCore = await upgrades.deployProxy(
            OmniCore,
            [owner.address, await token.getAddress(), owner.address, owner.address],
            { initializer: "initialize" }
        );

        // Verify initialization
        expect(await omniCore.OMNI_COIN()).to.equal(await token.getAddress());
    });

    it("Should not allow re-initialization", async function () {
        // ... test that initialize can't be called twice
    });

    it("Should preserve state after upgrade", async function () {
        // ... test upgrading to a V2 and verify state is preserved
    });
});
```

---

## ⚠️ Common Pitfalls & Solutions

### 1. Storage Collision
**Problem:** Reordering storage variables breaks upgrades
**Solution:** NEVER reorder existing variables, only add new ones at the end

```solidity
// ❌ WRONG
contract V2 {
    uint256 public totalStaked;  // Was after stakes
    mapping(address => Stake) public stakes;
}

// ✅ CORRECT
contract V2 {
    mapping(address => Stake) public stakes;
    uint256 public totalStaked;
    uint256 public newVariable;  // New variables at end only
}
```

### 2. Immutable Variables
**Problem:** `immutable` variables can't exist in upgradeable contracts
**Solution:** Convert to regular storage, initialize in `initialize()`

```solidity
// ❌ Old
IERC20 public immutable OMNI_COIN;

// ✅ New
IERC20 public OMNI_COIN;  // Regular storage variable
```

### 3. Missing Initializer Protection
**Problem:** Implementation can be hijacked without protection
**Solution:** Always disable initializers in constructor

```solidity
/// @custom:oz-upgrades-unsafe-allow constructor
constructor() {
    _disableInitializers();  // CRITICAL!
}
```

### 4. Forgetting Storage Gap
**Problem:** Can't add new variables in future upgrades
**Solution:** Reserve storage slots at the end

```solidity
uint256[50] private __gap;  // Reserve 50 slots
```

### 5. Missing Upgrade Authorization
**Problem:** Anyone could upgrade the contract
**Solution:** Restrict upgrades to admin only

```solidity
function _authorizeUpgrade(address newImplementation)
    internal
    override
    onlyRole(ADMIN_ROLE)  // Only admin
{}
```

---

## ✅ Verification Commands

```bash
# Compile
npx hardhat compile

# Run tests
npx hardhat test

# Validate upgrade compatibility (when upgrading)
npx hardhat run scripts/validate-upgrade.ts

# Deploy locally for testing
npx hardhat run scripts/deploy-upgradeable.ts --network localhost
```

---

## 📚 References

**OpenZeppelin Documentation:**
- [Upgradeable Contracts](https://docs.openzeppelin.com/contracts/4.x/upgradeable)
- [UUPS Proxies](https://docs.openzeppelin.com/contracts/4.x/api/proxy#UUPSUpgradeable)
- [Storage Gaps](https://docs.openzeppelin.com/upgrades-plugins/1.x/writing-upgradeable#storage-gaps)

**Project Files:**
- `/home/rickc/OmniBazaar/Coin/contracts/OmniCore.sol` - Current implementation
- `/home/rickc/OmniBazaar/Coin/SOLIDITY_CODING_STANDARDS.md` - Coding standards

---

## 🎯 Summary Checklist

Before considering this task complete:

- [ ] Installed `@openzeppelin/contracts-upgradeable` and `@openzeppelin/hardhat-upgrades`
- [ ] Changed contract inheritance to upgradeable versions
- [ ] Converted `immutable OMNI_COIN` to regular storage variable
- [ ] Added empty constructor with `_disableInitializers()`
- [ ] Created `initialize()` function to replace constructor
- [ ] Added `_authorizeUpgrade()` function with admin-only access
- [ ] Added `uint256[50] private __gap;` at the end of storage
- [ ] All existing functions copied unchanged
- [ ] Basic tests written and passing
- [ ] Contract compiles without errors
- [ ] Follows all Solidity coding standards

---

**Document Version:** 2.0.0
**Last Updated:** 2025-01-12
**Status:** Simplified for local testing
