# Making OmniCore Upgradeable - Complete Implementation Guide

**Document Version:** 1.0.0
**Created:** 2025-01-10
**Purpose:** Transform OmniCore from a non-upgradeable contract to an upgradeable proxy-based contract
**Estimated Time:** 3-5 days
**Priority:** HIGH - Must be done before mainnet deployment

---

## 🚨 CRITICAL CONTEXT FOR IMPLEMENTERS

### Required Reading BEFORE Starting

1. **Read these files first (in order):**
   - `/home/rickc/OmniBazaar/Coin/UPGRADE_STRATEGY.md` - Understand the overall upgrade strategy
   - `/home/rickc/OmniBazaar/Coin/contracts/OmniCore.sol` - Current non-upgradeable implementation
   - `/home/rickc/OmniBazaar/CLAUDE.md` - Project coding standards
   - `/home/rickc/OmniBazaar/Coin/SOLIDITY_CODING_STANDARDS.md` - Solidity specific standards

2. **Understand the current state:**
   - OmniCore uses a `constructor` (line 250-266)
   - It inherits from non-upgradeable OpenZeppelin contracts
   - It contains critical state that must be preserved
   - It was recently extended with multiaddr support (2025-01-10)

3. **Why this change is critical:**
   - OmniCore manages high-value state (stakes, DEX balances, node registry)
   - Bug fixes would require complex migrations without upgradeability
   - New features (like multiaddr) could be added without redeployment
   - Contract address stability is crucial for integrations

---

## 📊 Current State Analysis

### What OmniCore Currently Does

```solidity
// Current inheritance (non-upgradeable)
contract OmniCore is AccessControl, ReentrancyGuard {
    // State variables that MUST be preserved:
    mapping(bytes32 => address) public services;           // Service registry
    mapping(address => bool) public validators;            // Validator registry
    bytes32 public masterRoot;                             // Master merkle root
    mapping(address => Stake) public stakes;               // User stakes
    uint256 public totalStaked;                            // Total staked amount
    mapping(address => mapping(address => uint256)) public dexBalances; // DEX balances
    mapping(address => NodeInfo) public nodeRegistry;      // Node discovery (NEW)
    address[] public registeredNodes;                      // Node list (NEW)
    mapping(bytes32 => bool) public legacyUsernames;       // Legacy migration
    mapping(bytes32 => uint256) public legacyBalances;     // Legacy balances

    // Immutable variable that must become storage:
    IERC20 public immutable OMNI_COIN;  // <-- This is the main challenge
}
```

### Storage Layout Challenges

**CRITICAL:** The contract has an `immutable` variable (`OMNI_COIN`) which cannot exist in upgradeable contracts. This must be converted to a regular storage variable.

---

## 🎯 Implementation Plan

### Stage 1: Create Upgradeable Version (Day 1)

#### Step 1.1: Create OmniCoreV2Upgradeable.sol

**File:** `/home/rickc/OmniBazaar/Coin/contracts/OmniCoreV2Upgradeable.sol`

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title OmniCoreV2Upgradeable
 * @author OmniCoin Development Team
 * @notice Upgradeable version of OmniCore with UUPS proxy pattern
 * @dev All immutable variables converted to storage, maintains exact same functionality
 */
contract OmniCoreV2Upgradeable is
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    // ============================================
    // CRITICAL: Storage Layout (DO NOT REORDER!)
    // ============================================
    // The order here MUST match future versions exactly

    // Type declarations (same as original)
    struct Stake {
        uint256 amount;
        uint256 tier;
        uint256 duration;
        uint256 lockTime;
        bool active;
    }

    struct NodeInfo {
        string multiaddr;
        string httpEndpoint;
        string wsEndpoint;
        string region;
        uint8 nodeType;
        bool active;
        uint256 lastUpdate;
    }

    // Constants (same values as original)
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant AVALANCHE_VALIDATOR_ROLE = keccak256("AVALANCHE_VALIDATOR_ROLE");
    uint256 public constant ODDAO_FEE_BPS = 7000;
    uint256 public constant STAKING_FEE_BPS = 2000;
    uint256 public constant VALIDATOR_FEE_BPS = 1000;
    uint256 public constant BASIS_POINTS = 10000;

    // ============================================
    // Storage Variables (EXACT ORDER MATTERS!)
    // ============================================

    // Slot 0-1: Was immutable, now storage
    IERC20 public OMNI_COIN;  // Changed from immutable to storage

    // Existing storage variables (preserve exact order)
    mapping(bytes32 => address) public services;
    mapping(address => bool) public validators;
    bytes32 public masterRoot;
    uint256 public lastRootUpdate;
    mapping(address => Stake) public stakes;
    uint256 public totalStaked;
    mapping(address => mapping(address => uint256)) public dexBalances;
    address public oddaoAddress;
    address public stakingPoolAddress;

    // Node Discovery Registry State
    mapping(address => NodeInfo) public nodeRegistry;
    mapping(uint8 => uint256) public activeNodeCounts;
    address[] public registeredNodes;
    mapping(address => uint256) public nodeIndex;

    // Legacy Migration State
    mapping(bytes32 => bool) public legacyUsernames;
    mapping(bytes32 => uint256) public legacyBalances;
    mapping(bytes32 => address) public legacyClaimed;
    uint256 public totalLegacySupply;
    uint256 public totalLegacyClaimed;

    // ============================================
    // Storage Gap for Future Upgrades
    // ============================================
    // Reserve 50 slots for future variables
    uint256[50] private __gap;

    // Events (same as original - copy all from OmniCore.sol)
    // ... [Include all events from original]

    // Custom errors (same as original)
    error InvalidAddress();
    error InvalidAmount();
    error InvalidSignature();
    error StakeNotFound();
    error StakeLocked();
    error InvalidProof();
    error Unauthorized();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the upgradeable OmniCore
     * @dev Replaces constructor, can only be called once
     * @param admin Address to grant admin role
     * @param _omniCoin Address of OmniCoin token
     * @param _oddaoAddress ODDAO fee recipient
     * @param _stakingPoolAddress Staking pool fee recipient
     */
    function initialize(
        address admin,
        address _omniCoin,
        address _oddaoAddress,
        address _stakingPoolAddress
    ) public initializer {
        // Validate inputs
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
    {}

    // ============================================
    // Copy ALL functions from OmniCore.sol
    // ============================================
    // IMPORTANT: Copy every single function from the original
    // Do not modify any function logic, only the contract structure

    // [Copy all functions here...]
}
```

#### Step 1.2: Install Required Dependencies

```bash
cd /home/rickc/OmniBazaar/Coin
npm install @openzeppelin/contracts-upgradeable@^4.9.0
npm install @openzeppelin/hardhat-upgrades
```

Update `hardhat.config.ts`:
```typescript
import '@openzeppelin/hardhat-upgrades';

// Add to config
module.exports = {
    // ... existing config
};
```

### Stage 2: Create Migration Contract (Day 1-2)

#### Step 2.1: Create OmniCoreMigrator.sol

**File:** `/home/rickc/OmniBazaar/Coin/contracts/migration/OmniCoreMigrator.sol`

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../OmniCore.sol";
import "../OmniCoreV2Upgradeable.sol";

/**
 * @title OmniCoreMigrator
 * @notice Handles state migration from old to new OmniCore
 * @dev One-time use contract for migration
 */
contract OmniCoreMigrator {
    OmniCore public immutable oldCore;
    OmniCoreV2Upgradeable public immutable newCore;
    address public immutable admin;

    // Track migration progress
    mapping(address => bool) public nodesMigrated;
    mapping(address => bool) public stakesMigrated;
    uint256 public nodesProcessed;
    uint256 public stakesProcessed;

    modifier onlyAdmin() {
        require(msg.sender == admin, "Not admin");
        _;
    }

    constructor(
        address _oldCore,
        address _newCore,
        address _admin
    ) {
        oldCore = OmniCore(_oldCore);
        newCore = OmniCoreV2Upgradeable(_newCore);
        admin = _admin;
    }

    /**
     * @notice Migrate node registry in batches
     * @param nodeAddresses Batch of node addresses to migrate
     */
    function migrateNodes(address[] calldata nodeAddresses) external onlyAdmin {
        for (uint256 i = 0; i < nodeAddresses.length; i++) {
            address nodeAddr = nodeAddresses[i];

            if (nodesMigrated[nodeAddr]) continue;

            // Get node info from old contract
            (
                string memory multiaddr,
                string memory httpEndpoint,
                string memory wsEndpoint,
                string memory region,
                uint8 nodeType,
                bool active,
                uint256 lastUpdate
            ) = oldCore.getNodeInfo(nodeAddr);

            // Skip if not registered
            if (bytes(httpEndpoint).length == 0) continue;

            // Register in new contract (would need admin function)
            // newCore.adminRegisterNode(nodeAddr, multiaddr, httpEndpoint, wsEndpoint, region, nodeType);

            nodesMigrated[nodeAddr] = true;
            nodesProcessed++;
        }
    }

    /**
     * @notice Migrate stakes in batches
     * @param userAddresses Batch of user addresses to migrate
     */
    function migrateStakes(address[] calldata userAddresses) external onlyAdmin {
        for (uint256 i = 0; i < userAddresses.length; i++) {
            address user = userAddresses[i];

            if (stakesMigrated[user]) continue;

            // Get stake from old contract
            OmniCore.Stake memory stake = oldCore.getStake(user);

            // Skip if no active stake
            if (!stake.active) continue;

            // Recreate stake in new contract (would need admin function)
            // newCore.adminSetStake(user, stake);

            stakesMigrated[user] = true;
            stakesProcessed++;
        }
    }

    // Add more migration functions for:
    // - DEX balances
    // - Legacy usernames and balances
    // - Service registry
    // - Validators
}
```

### Stage 3: Create Deployment Scripts (Day 2)

#### Step 3.1: Create Deployment Script

**File:** `/home/rickc/OmniBazaar/Coin/scripts/deploy-upgradeable-omnicore.ts`

```typescript
import { ethers, upgrades } from "hardhat";
import * as fs from "fs";
import * as path from "path";

async function main() {
    console.log("========================================");
    console.log("Deploying Upgradeable OmniCore");
    console.log("========================================");

    // Get deployment parameters
    const [deployer] = await ethers.getSigners();
    console.log("Deploying with account:", deployer.address);

    // Check if we're on the right network
    const network = await ethers.provider.getNetwork();
    console.log("Network:", network.name, "Chain ID:", network.chainId);

    // Load existing contract addresses
    const omniCoinAddress = process.env.OMNICOIN_ADDRESS || "0x...";
    const oddaoAddress = process.env.ODDAO_ADDRESS || deployer.address;
    const stakingPoolAddress = process.env.STAKING_POOL_ADDRESS || deployer.address;

    // Deploy implementation and proxy
    const OmniCoreV2 = await ethers.getContractFactory("OmniCoreV2Upgradeable");

    console.log("Deploying proxy and implementation...");
    const omniCore = await upgrades.deployProxy(
        OmniCoreV2,
        [
            deployer.address,    // admin
            omniCoinAddress,      // token
            oddaoAddress,         // oddao
            stakingPoolAddress    // staking pool
        ],
        {
            initializer: "initialize",
            kind: "uups" // or "transparent" for TransparentProxy
        }
    );

    await omniCore.waitForDeployment();

    const proxyAddress = await omniCore.getAddress();
    const implementationAddress = await upgrades.erc1967.getImplementationAddress(proxyAddress);

    console.log("✅ OmniCore Proxy deployed to:", proxyAddress);
    console.log("✅ OmniCore Implementation deployed to:", implementationAddress);

    // Save deployment info
    const deploymentInfo = {
        network: network.name,
        chainId: network.chainId.toString(),
        proxyAddress,
        implementationAddress,
        admin: deployer.address,
        omniCoin: omniCoinAddress,
        oddaoAddress,
        stakingPoolAddress,
        deployedAt: new Date().toISOString(),
        blockNumber: await ethers.provider.getBlockNumber()
    };

    const deploymentsDir = path.join(__dirname, "../deployments");
    if (!fs.existsSync(deploymentsDir)) {
        fs.mkdirSync(deploymentsDir, { recursive: true });
    }

    const deploymentPath = path.join(
        deploymentsDir,
        `${network.name}-omnicore-v2.json`
    );
    fs.writeFileSync(deploymentPath, JSON.stringify(deploymentInfo, null, 2));

    console.log("\nDeployment info saved to:", deploymentPath);

    // Verify implementation on Etherscan/Snowtrace
    console.log("\nTo verify on Etherscan/Snowtrace:");
    console.log(`npx hardhat verify --network ${network.name} ${implementationAddress}`);

    return proxyAddress;
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });
```

#### Step 3.2: Create Upgrade Script

**File:** `/home/rickc/OmniBazaar/Coin/scripts/upgrade-omnicore.ts`

```typescript
import { ethers, upgrades } from "hardhat";

async function main() {
    const proxyAddress = process.env.OMNICORE_PROXY_ADDRESS;
    if (!proxyAddress) {
        throw new Error("OMNICORE_PROXY_ADDRESS not set");
    }

    console.log("Upgrading OmniCore at:", proxyAddress);

    // Deploy new implementation
    const OmniCoreV3 = await ethers.getContractFactory("OmniCoreV3Upgradeable");

    console.log("Deploying new implementation...");
    const upgraded = await upgrades.upgradeProxy(proxyAddress, OmniCoreV3);

    const newImplementation = await upgrades.erc1967.getImplementationAddress(
        proxyAddress
    );

    console.log("✅ Upgraded to new implementation:", newImplementation);
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });
```

### Stage 4: Testing Suite (Day 2-3)

#### Step 4.1: Unit Tests for Upgradeability

**File:** `/home/rickc/OmniBazaar/Coin/test/OmniCoreV2Upgradeable.test.ts`

```typescript
import { expect } from "chai";
import { ethers, upgrades } from "hardhat";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import { OmniCoreV2Upgradeable } from "../typechain-types";

describe("OmniCoreV2Upgradeable", function () {
    let omniCore: OmniCoreV2Upgradeable;
    let omniCoin: any; // Mock token
    let owner: SignerWithAddress;
    let addr1: SignerWithAddress;
    let addr2: SignerWithAddress;

    beforeEach(async function () {
        [owner, addr1, addr2] = await ethers.getSigners();

        // Deploy mock OmniCoin
        const MockToken = await ethers.getContractFactory("MockERC20");
        omniCoin = await MockToken.deploy("OmniCoin", "XOM");

        // Deploy upgradeable OmniCore
        const OmniCoreV2 = await ethers.getContractFactory("OmniCoreV2Upgradeable");
        omniCore = await upgrades.deployProxy(
            OmniCoreV2,
            [
                owner.address,
                await omniCoin.getAddress(),
                addr1.address, // oddao
                addr2.address  // staking pool
            ],
            { initializer: "initialize" }
        );
    });

    describe("Initialization", function () {
        it("Should initialize with correct values", async function () {
            expect(await omniCore.OMNI_COIN()).to.equal(await omniCoin.getAddress());
            expect(await omniCore.oddaoAddress()).to.equal(addr1.address);
            expect(await omniCore.stakingPoolAddress()).to.equal(addr2.address);
        });

        it("Should not allow re-initialization", async function () {
            await expect(
                omniCore.initialize(
                    owner.address,
                    await omniCoin.getAddress(),
                    addr1.address,
                    addr2.address
                )
            ).to.be.revertedWith("Initializable: contract is already initialized");
        });

        it("Should set up roles correctly", async function () {
            const ADMIN_ROLE = await omniCore.ADMIN_ROLE();
            expect(await omniCore.hasRole(ADMIN_ROLE, owner.address)).to.be.true;
        });
    });

    describe("Upgradeability", function () {
        it("Should upgrade to V3", async function () {
            // Deploy V3 implementation
            const OmniCoreV3 = await ethers.getContractFactory("OmniCoreV3Mock");
            const upgraded = await upgrades.upgradeProxy(
                await omniCore.getAddress(),
                OmniCoreV3
            );

            // Check that state is preserved
            expect(await upgraded.OMNI_COIN()).to.equal(await omniCoin.getAddress());

            // Check new functionality (mock V3 would have new function)
            // expect(await upgraded.newV3Function()).to.equal(something);
        });

        it("Should only allow admin to upgrade", async function () {
            const OmniCoreV3 = await ethers.getContractFactory("OmniCoreV3Mock");

            // Try to upgrade as non-admin (should fail)
            await expect(
                upgrades.upgradeProxy(
                    await omniCore.getAddress(),
                    OmniCoreV3,
                    { call: { fn: "_authorizeUpgrade", args: [addr1.address] } }
                )
            ).to.be.reverted;
        });
    });

    describe("Node Registry", function () {
        it("Should register nodes correctly", async function () {
            const multiaddr = "/ip4/127.0.0.1/tcp/14002/p2p/QmXyz...";
            const httpEndpoint = "http://localhost:3001";
            const wsEndpoint = "ws://localhost:8101";
            const region = "us-east";
            const nodeType = 0; // gateway

            await omniCore.connect(addr1).registerNode(
                multiaddr,
                httpEndpoint,
                wsEndpoint,
                region,
                nodeType
            );

            const nodeInfo = await omniCore.getNodeInfo(addr1.address);
            expect(nodeInfo.multiaddr).to.equal(multiaddr);
            expect(nodeInfo.httpEndpoint).to.equal(httpEndpoint);
            expect(nodeInfo.nodeType).to.equal(nodeType);
        });

        it("Should query active nodes within time window", async function () {
            // Register multiple nodes
            for (let i = 0; i < 3; i++) {
                await omniCore.connect(await ethers.getSigner(i)).registerNode(
                    `/ip4/127.0.0.1/tcp/1400${i}/p2p/Qm${i}`,
                    `http://localhost:300${i}`,
                    `ws://localhost:810${i}`,
                    "us-east",
                    0
                );
            }

            const [addresses, infos] = await omniCore.getActiveNodesWithinTime(
                0, // gateway type
                86400 // 24 hours
            );

            expect(addresses.length).to.equal(3);
            expect(infos.length).to.equal(3);
        });
    });

    describe("State Preservation", function () {
        it("Should preserve all state after upgrade", async function () {
            // Set up some state
            await omniCore.connect(owner).setService(
                ethers.id("DEX"),
                addr1.address
            );

            // Register a node
            await omniCore.connect(addr1).registerNode(
                "/ip4/127.0.0.1/tcp/14002",
                "http://localhost:3001",
                "ws://localhost:8101",
                "us-east",
                0
            );

            // Get state before upgrade
            const serviceBefore = await omniCore.services(ethers.id("DEX"));
            const nodeCountBefore = await omniCore.getActiveNodeCount(0);

            // Upgrade
            const OmniCoreV3 = await ethers.getContractFactory("OmniCoreV3Mock");
            const upgraded = await upgrades.upgradeProxy(
                await omniCore.getAddress(),
                OmniCoreV3
            );

            // Check state after upgrade
            expect(await upgraded.services(ethers.id("DEX"))).to.equal(serviceBefore);
            expect(await upgraded.getActiveNodeCount(0)).to.equal(nodeCountBefore);
        });
    });
});
```

#### Step 4.2: Integration Tests

**File:** `/home/rickc/OmniBazaar/Coin/test/integration/OmniCore.migration.test.ts`

```typescript
import { expect } from "chai";
import { ethers, upgrades } from "hardhat";

describe("OmniCore Migration Integration", function () {
    let oldCore: any;
    let newCore: any;
    let migrator: any;

    beforeEach(async function () {
        const [owner] = await ethers.getSigners();

        // Deploy old OmniCore (non-upgradeable)
        const OldCore = await ethers.getContractFactory("OmniCore");
        oldCore = await OldCore.deploy(
            owner.address,
            "0x...", // token
            owner.address, // oddao
            owner.address  // staking
        );

        // Deploy new upgradeable OmniCore
        const NewCore = await ethers.getContractFactory("OmniCoreV2Upgradeable");
        newCore = await upgrades.deployProxy(NewCore, [
            owner.address,
            "0x...", // token
            owner.address,
            owner.address
        ]);

        // Deploy migrator
        const Migrator = await ethers.getContractFactory("OmniCoreMigrator");
        migrator = await Migrator.deploy(
            await oldCore.getAddress(),
            await newCore.getAddress(),
            owner.address
        );
    });

    it("Should migrate node registry", async function () {
        // Register nodes in old contract
        await oldCore.registerNode(
            "/ip4/127.0.0.1/tcp/14002",
            "http://localhost:3001",
            "ws://localhost:8101",
            "us-east",
            0
        );

        // Migrate via migrator
        const [owner] = await ethers.getSigners();
        await migrator.migrateNodes([owner.address]);

        // Verify in new contract
        const nodeInfo = await newCore.getNodeInfo(owner.address);
        expect(nodeInfo.httpEndpoint).to.equal("http://localhost:3001");
    });

    it("Should handle large batch migrations", async function () {
        // Register many nodes
        const signers = await ethers.getSigners();
        for (let i = 0; i < 10; i++) {
            await oldCore.connect(signers[i]).registerNode(
                `/ip4/127.0.0.1/tcp/1400${i}`,
                `http://localhost:300${i}`,
                `ws://localhost:810${i}`,
                "us-east",
                0
            );
        }

        // Migrate in batches
        const batch1 = signers.slice(0, 5).map(s => s.address);
        const batch2 = signers.slice(5, 10).map(s => s.address);

        await migrator.migrateNodes(batch1);
        await migrator.migrateNodes(batch2);

        // Verify all migrated
        expect(await newCore.getActiveNodeCount(0)).to.equal(10);
    });
});
```

### Stage 5: Migration Process (Day 3-4)

#### Step 5.1: Pre-Migration Checklist

Create `/home/rickc/OmniBazaar/Coin/MIGRATION_CHECKLIST.md`:

```markdown
# OmniCore Migration Checklist

## Pre-Migration
- [ ] All tests passing for OmniCoreV2Upgradeable
- [ ] Deployment scripts tested on local network
- [ ] Migration scripts tested with sample data
- [ ] Backup of all current state data
- [ ] Gas cost estimation completed
- [ ] Emergency pause plan ready

## Migration Steps
1. [ ] Deploy OmniCoreV2Upgradeable proxy and implementation
2. [ ] Deploy OmniCoreMigrator contract
3. [ ] Grant migrator necessary permissions
4. [ ] Export current state from old OmniCore
5. [ ] Migrate in batches:
   - [ ] Service registry
   - [ ] Validators
   - [ ] Node registry (in batches of 50)
   - [ ] Stakes (in batches of 100)
   - [ ] DEX balances (in batches of 100)
   - [ ] Legacy migration data
6. [ ] Verify all state migrated correctly
7. [ ] Update all references to new proxy address
8. [ ] Test all functionality
9. [ ] Remove old contract permissions

## Post-Migration
- [ ] Monitor for 24 hours
- [ ] Address any issues
- [ ] Document lessons learned
```

### Stage 6: Common Pitfalls & Solutions (CRITICAL)

#### Pitfall 1: Storage Collision

**Problem:** Reordering storage variables breaks upgrade
**Solution:** NEVER reorder existing variables, only add new ones at the end

```solidity
// ❌ WRONG - Reordered variables
contract V2 {
    uint256 public totalStaked;  // Was after stakes
    mapping(address => Stake) public stakes;  // Was before totalStaked
}

// ✅ CORRECT - Preserve order
contract V2 {
    mapping(address => Stake) public stakes;
    uint256 public totalStaked;
    uint256 public newVariable;  // New variables at end
}
```

#### Pitfall 2: Immutable to Storage Conversion

**Problem:** `immutable` variables can't exist in upgradeable contracts
**Solution:** Convert to regular storage in initializer

```solidity
// Old (non-upgradeable)
IERC20 public immutable OMNI_COIN;
constructor(address _token) {
    OMNI_COIN = IERC20(_token);
}

// New (upgradeable)
IERC20 public OMNI_COIN;  // Now storage variable
function initialize(address _token) initializer {
    OMNI_COIN = IERC20(_token);
}
```

#### Pitfall 3: Missing Initializer Protection

**Problem:** Constructor doesn't run in proxy pattern
**Solution:** Disable initializers in constructor

```solidity
/// @custom:oz-upgrades-unsafe-allow constructor
constructor() {
    _disableInitializers();  // CRITICAL - prevents implementation initialization
}
```

#### Pitfall 4: Forgetting Storage Gap

**Problem:** Can't add variables in future upgrades
**Solution:** Reserve storage slots

```solidity
uint256[50] private __gap;  // Reserve 50 slots for future variables
```

#### Pitfall 5: Wrong Upgrade Authorization

**Problem:** Anyone can upgrade the contract
**Solution:** Properly implement _authorizeUpgrade

```solidity
function _authorizeUpgrade(address newImplementation)
    internal
    override
    onlyRole(ADMIN_ROLE)  // Only admin can upgrade
{}
```

### Stage 7: Verification Steps

#### Step 7.1: Verify Storage Layout

```bash
npx hardhat compile
npx hardhat verify-storage-layout
```

#### Step 7.2: Test Upgrade Path

```typescript
// Test that V2 -> V3 upgrade works
const V3 = await ethers.getContractFactory("OmniCoreV3Test");
await upgrades.validateUpgrade(
    await omniCore.getAddress(),
    V3
);
```

#### Step 7.3: Gas Cost Analysis

```typescript
// Compare gas costs
const tx1 = await oldCore.registerNode(...);
const receipt1 = await tx1.wait();
console.log("Old gas:", receipt1.gasUsed);

const tx2 = await newCore.registerNode(...);
const receipt2 = await tx2.wait();
console.log("New gas (with proxy):", receipt2.gasUsed);
console.log("Overhead:", Number(receipt2.gasUsed - receipt1.gasUsed));
```

### Stage 8: Environment Variables

Add to `.env`:

```bash
# OmniCore Upgrade Configuration
OMNICORE_PROXY_ADDRESS=0x...        # After deployment
OMNICORE_OLD_ADDRESS=0x...          # Current OmniCore
OMNICOIN_ADDRESS=0x...              # OmniCoin token
ODDAO_ADDRESS=0x...                 # ODDAO recipient
STAKING_POOL_ADDRESS=0x...          # Staking pool
MIGRATION_BATCH_SIZE=50             # Batch size for migration
```

---

## 🎯 Success Criteria

### Must Have
- [ ] All existing functionality preserved
- [ ] All state successfully migrated
- [ ] Upgrade mechanism tested and working
- [ ] No increase in gas costs > 15%
- [ ] All tests passing

### Should Have
- [ ] Migration completed in < 1 hour
- [ ] Automatic verification on Etherscan/Snowtrace
- [ ] Monitoring dashboard for migration progress
- [ ] Rollback plan documented

### Nice to Have
- [ ] Gas optimization in new version
- [ ] Additional features added during upgrade
- [ ] Improved event emissions

---

## 📚 Additional Resources

### Required OpenZeppelin Documentation
- [Upgradeable Contracts](https://docs.openzeppelin.com/contracts/4.x/upgradeable)
- [UUPS Proxies](https://docs.openzeppelin.com/contracts/4.x/api/proxy#UUPSUpgradeable)
- [Storage Gaps](https://docs.openzeppelin.com/upgrades-plugins/1.x/writing-upgradeable#storage-gaps)
- [Initialization](https://docs.openzeppelin.com/upgrades-plugins/1.x/writing-upgradeable#initializers)

### Project Files to Reference
- `/home/rickc/OmniBazaar/Coin/UPGRADE_STRATEGY.md` - Overall upgrade strategy
- `/home/rickc/OmniBazaar/Coin/contracts/OmniCore.sol` - Current implementation
- `/home/rickc/OmniBazaar/Coin/SOLIDITY_CODING_STANDARDS.md` - Coding standards
- `/home/rickc/OmniBazaar/Coin/scripts/deploy.js` - Current deployment approach

### Commands Reference

```bash
# Compile contracts
npx hardhat compile

# Run tests
npx hardhat test test/OmniCoreV2Upgradeable.test.ts

# Deploy to local
npx hardhat run scripts/deploy-upgradeable-omnicore.ts --network localhost

# Deploy to testnet
npx hardhat run scripts/deploy-upgradeable-omnicore.ts --network fuji

# Verify on Etherscan/Snowtrace
npx hardhat verify --network fuji IMPLEMENTATION_ADDRESS

# Upgrade contract
npx hardhat run scripts/upgrade-omnicore.ts --network fuji
```

---

## 🚨 Emergency Procedures

### If Migration Fails

1. **Pause old contract** (if pausable)
2. **Stop migration script**
3. **Investigate issue**
4. **Fix and restart from last checkpoint**
5. **If critical, deploy fresh and restart**

### Rollback Plan

```solidity
// Emergency rollback function in migrator
function emergencyRollback() external onlyAdmin {
    // Point all services back to old OmniCore
    // Document state at failure point
    // Plan recovery
}
```

---

## 📋 Final Implementation Order

### Day 1: Setup
1. Create OmniCoreV2Upgradeable.sol
2. Install dependencies
3. Write deployment scripts
4. Start unit tests

### Day 2: Testing
1. Complete unit tests
2. Write integration tests
3. Test migration scripts
4. Gas analysis

### Day 3: Migration Prep
1. Deploy to testnet
2. Test upgrade mechanism
3. Prepare migration data
4. Final review

### Day 4: Execute Migration
1. Deploy new contracts
2. Migrate state in batches
3. Verify all data
4. Update integrations

### Day 5: Monitoring
1. Monitor for issues
2. Address any problems
3. Document lessons learned
4. Plan future upgrades

---

**Document Version:** 1.0.0
**Last Updated:** 2025-01-10
**Next Review:** Before testnet deployment
**Status:** Ready for implementation

## Implementation Notes for AI Assistant

When implementing this plan:

1. **Start with Stage 1** - Create the upgradeable contract first
2. **Test locally** before any testnet deployment
3. **Never skip the storage gap** - It's critical for future upgrades
4. **Preserve storage order** exactly as shown
5. **Run all tests** before proceeding to next stage
6. **Ask for clarification** if any step is unclear

The most critical parts are:
- Converting `immutable` to storage variables
- Preserving exact storage layout order
- Including storage gaps for future upgrades
- Proper initialization function
- Authorization for upgrades

This plan provides everything needed to successfully convert OmniCore to an upgradeable contract. Follow it step by step, and the upgrade will be successful.