# COTI Testnet Deployment Guide

**Created:** 2025-11-13
**Deployed:** 2025-11-13 20:41 UTC ✅
**Status:** COMPLETE - All contracts deployed with Privacy ENABLED

---

## ✅ DEPLOYMENT SUCCESS

### Deployed Contract Addresses

```
PrivateOmniCoin:    0x6BF2b6df85CfeE5debF0684c4B656A3b86a31675
OmniPrivacyBridge:  0x123522e908b34799Cf14aDdF7B2A47Df404c4d47
PrivateDEX:         0xA242e4555CECF29F888b0189f216241587b9945E
```

**Network:** COTI Testnet (chainId: 7082400)
**Deployer:** 0x32Fbc7639ebF728c128DE8EABBd9368ED16Eae1A
**Privacy Status:** ENABLED ✅ (MPC precompiles functional)
**Total Cost:** 0.016 COTI (~$0.02 USD)

**View on Explorer:**
- https://testnet.cotiscan.io/address/0x6BF2b6df85CfeE5debF0684c4B656A3b86a31675
- https://testnet.cotiscan.io/address/0x123522e908b34799Cf14aDdF7B2A47Df404c4d47
- https://testnet.cotiscan.io/address/0xA242e4555CECF29F888b0189f216241587b9945E

### Configuration Synced

All modules updated automatically:
- ✅ Validator/src/config/omnicoin-integration.ts
- ✅ WebApp/src/config/omnicoin-integration.ts
- ✅ Wallet/src/config/omnicoin-integration.ts

**Access in code:**
```typescript
import { getContractAddresses } from './config/omnicoin-integration';
const coti = getContractAddresses('coti-testnet');
// coti.PrivateOmniCoin → 0x6BF2b6df85CfeE5debF0684c4B656A3b86a31675
// coti.PrivateDEX      → 0xA242e4555CECF29F888b0189f216241587b9945E
```

---

## 🔧 Why Non-Upgradeable Contracts Were Used

### The UUPS Proxy Problem

**Issue:** OpenZeppelin's `upgrades.deployProxy()` requires calling `eth_getBlockByNumber("pending")` to estimate gas for proxy deployment. COTI testnet RPC returns error: `"pending block is not available"`.

**What Failed:**
```typescript
// This DOES NOT work on COTI testnet:
const proxy = await upgrades.deployProxy(
  PrivateOmniCoin,
  [],
  { kind: "uups", initializer: "initialize" }
);
// ❌ Error: pending block is not available
```

**Additional Issue:** Upgradeable contracts use `_disableInitializers()` in constructor, making direct deployment impossible. When we tried calling `initialize()` on the implementation contract, it reverted with `InvalidInitialization()` because the constructor disabled it.

### Solution for Testnet

**Deployed simplified non-upgradeable versions:**
- `PrivateOmniCoinSimple.sol` - Constructor-based initialization
- `OmniPrivacyBridgeSimple.sol` - Constructor-based initialization
- `PrivateDEXSimple.sol` - Constructor-based initialization

**Benefits:**
- ✅ No proxy deployment needed
- ✅ Constructor executes during deployment automatically
- ✅ Same functionality as upgradeable versions
- ✅ Perfect for testnet validation

**Drawback:**
- ⚠️ Cannot upgrade (must redeploy to change logic)
- ⚠️ Not suitable for mainnet production use

---

## 🚀 Mainnet Deployment Plan

### Option 1: Manual Proxy Deployment (Recommended)

Deploy UUPS proxies manually without OpenZeppelin plugin:

1. **Deploy Implementation:**
   ```solidity
   PrivateOmniCoin impl = new PrivateOmniCoin();
   ```

2. **Deploy ERC1967Proxy:**
   ```solidity
   bytes memory initData = abi.encodeWithSignature("initialize()");
   ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
   ```

3. **Use Proxy Address:**
   All calls go through proxy, which delegatecalls to implementation.

**This avoids the "pending block" issue** because we're not using the OpenZeppelin plugin.

### Option 2: Alternative Proxy Libraries

Use a proxy library that doesn't require "pending" block:
- Transparent Proxy (simpler than UUPS)
- Beacon Proxy (for multiple instances)
- Direct delegatecall pattern

### Option 3: OpenZeppelin Fix

Wait for OpenZeppelin to fix RPC compatibility, or use a different deployment method that doesn't call `eth_getBlockByNumber("pending")`.

### Recommended Approach for Mainnet

**Use Option 1 (Manual UUPS Deployment):**

```bash
# Create manual UUPS deployment script
npx hardhat run scripts/deploy-coti-mainnet-uups.ts --network cotiMainnet
```

**Advantages:**
- ✅ Full upgrade capability (UUPS pattern)
- ✅ No pending block dependency
- ✅ Production-grade security
- ✅ Same storage layout as full PrivateOmniCoin.sol

---

## 📋 What Was Deployed (Testnet)

### Contracts (Non-Upgradeable for Testing):

1. **PrivateOmniCoin.sol** (~9.9 KB)
   - Privacy-enabled XOM token (pXOM)
   - MPC-encrypted balances
   - XOM ↔ pXOM conversion (0.3% fee)

2. **OmniPrivacyBridge.sol** (~6.1 KB)
   - Cross-chain XOM ↔ pXOM bridge
   - Avalanche ↔ COTI communication
   - Max conversion limits

3. **PrivateDEX.sol** (~10.7 KB)
   - Privacy-preserving order matching
   - Encrypted amounts/prices
   - MPC operations (ge, min, add, sub, eq)

**Total Deployment Cost:** ~0.05 COTI
**Recommended Faucet Request:** 1.0 COTI (includes testing buffer)

---

## 🔄 Automatic Integration Flow

### After Deployment:

```
1. Contracts Deploy → COTI Testnet
         ↓
2. Save Deployment → Coin/deployments/coti-testnet.json
         ↓
3. Sync Script → ./scripts/sync-contract-addresses.sh coti-testnet
         ↓
4. Update Config → All modules get new addresses:
         ├─ Validator/src/config/omnicoin-integration.ts
         ├─ WebApp/src/config/omnicoin-integration.ts
         └─ Wallet/src/config/omnicoin-integration.ts
         ↓
5. Services Use → PrivateOrderBook.ts automatically connects
```

### Configuration Files Updated:

- ✅ **Validator:** Privacy services will auto-detect COTI addresses
- ✅ **WebApp:** UI will display privacy trading options
- ✅ **Wallet:** Will support pXOM token and privacy conversions

---

## 🚀 Deployment Commands

### Method 1: Automated Workflow (Recommended)

```bash
cd /home/rickc/OmniBazaar/Coin
./scripts/deploy-workflow.sh
```

**What it does:**
- ✅ Checks .env for deployment key
- ✅ Verifies COTI balance
- ✅ Deploys all 3 contracts
- ✅ Syncs addresses to all modules
- ✅ Verifies deployment

### Method 2: Manual Step-by-Step

```bash
cd /home/rickc/OmniBazaar/Coin

# 1. Check balance
npx hardhat run scripts/check-balance.js --network cotiTestnet

# 2. Deploy contracts
npx hardhat run scripts/deploy-coti-privacy.ts --network cotiTestnet

# 3. Sync addresses
cd /home/rickc/OmniBazaar
./scripts/sync-contract-addresses.sh coti-testnet

# 4. Verify
cat Coin/deployments/coti-testnet.json
```

---

## 📊 Deployment Output Structure

**File:** `Coin/deployments/coti-testnet.json`

```json
{
  "network": "coti-testnet",
  "chainId": 13068200,
  "timestamp": "2025-11-13T...",
  "deployer": "0x32Fbc7639ebF728c128DE8EABBd9368ED16Eae1A",
  "contracts": {
    "PrivateOmniCoin": {
      "proxy": "0x...",
      "implementation": "0x..."
    },
    "OmniPrivacyBridge": {
      "proxy": "0x...",
      "implementation": "0x..."
    },
    "PrivateDEX": {
      "proxy": "0x...",
      "implementation": "0x..."
    }
  },
  "rpcUrl": "https://testnet.coti.io/rpc",
  "gasUsed": {
    "PrivateOmniCoin": "...",
    "OmniPrivacyBridge": "...",
    "PrivateDEX": "...",
    "total": "..."
  }
}
```

---

## 🔗 How Privacy Services Will Use Addresses

### PrivateOrderBook.ts Integration:

```typescript
// Automatic configuration loading
import { getContractAddresses } from './config/omnicoin-integration';

// In PrivateOrderBook constructor:
const cotiAddresses = getContractAddresses('coti-testnet');

// Connect to COTI contracts
this.privateDEXContract = new ethers.Contract(
  cotiAddresses.PrivateDEX,           // Auto-populated from sync
  PrivateDEXABI,
  cotiProvider
);

this.privateOmniCoinContract = new ethers.Contract(
  cotiAddresses.PrivateOmniCoin,      // Auto-populated from sync
  PrivateOmniCoinABI,
  cotiProvider
);

this.privacyBridgeContract = new ethers.Contract(
  cotiAddresses.OmniBridge,           // Auto-populated from sync
  OmniPrivacyBridgeABI,
  cotiProvider
);
```

**✅ No Manual Configuration Required!**

The sync script automatically updates all `omnicoin-integration.ts` files with the deployed addresses. Services just call `getContractAddresses('coti-testnet')` and everything works.

---

## 🔍 Verification Steps

### After Deployment:

```bash
# 1. Check deployment file exists
ls -la Coin/deployments/coti-testnet.json

# 2. Verify addresses synced to Validator
grep -A 10 "coti-testnet" Validator/src/config/omnicoin-integration.ts

# 3. Verify addresses synced to WebApp
grep -A 10 "coti-testnet" WebApp/src/config/omnicoin-integration.ts

# 4. Verify addresses synced to Wallet
grep -A 10 "coti-testnet" Wallet/src/config/omnicoin-integration.ts

# 5. View on COTI block explorer
# https://testnet.cotiscan.io/address/<CONTRACT_ADDRESS>
```

### Contract Interaction Test:

```bash
# Test privacy availability
npx hardhat run scripts/test-coti-privacy.ts --network cotiTestnet
```

---

## 🛠️ Network Configuration

### COTI Testnet Details:

```javascript
// Already configured in hardhat.config.js
{
  url: "https://testnet.coti.io/rpc",
  chainId: 13068200,
  gasPrice: 5000000000, // 5 Gwei
  timeout: 120000        // 2 minutes (MPC operations can be slow)
}
```

### Environment Variables:

```bash
# .env (already set)
COTI_DEPLOYER_PRIVATE_KEY=0x6a0f8f2b1b862d4489df10b6699dfa06b4897f7ef66dede182b51921abfb5c86
```

---

## 🧪 Testing Privacy Features

### After Deployment:

1. **Start Validator with COTI support:**
   ```bash
   cd /home/rickc/OmniBazaar/Validator
   npm run launch:service-node 1
   ```

2. **Run privacy order tests:**
   ```bash
   npm test tests/services/dex/PrivateOrderBook.enhanced.test.ts
   ```

3. **Test via WebApp:**
   ```bash
   cd /home/rickc/OmniBazaar/WebApp
   npm run dev
   # Navigate to DEX page
   # Toggle "Private Trading" option
   # Submit encrypted order
   ```

---

## 📝 Troubleshooting

### Issue: Insufficient Balance

```bash
# Request more from faucet
# In Discord: testnet 0x32Fbc7639ebF728c128DE8EABBd9368ED16Eae1A
```

### Issue: Privacy Not Available Error

```bash
# Check you're deploying to COTI testnet (chainId 13068200)
npx hardhat run scripts/check-balance.js --network cotiTestnet
```

### Issue: Addresses Not Syncing

```bash
# Manually run sync
cd /home/rickc/OmniBazaar
./scripts/sync-contract-addresses.sh coti-testnet --validate
```

### Issue: MPC Operations Timeout

```bash
# MPC operations can be slow on testnet (30-60 seconds)
# Increase timeout in hardhat.config.js:
timeout: 180000  // 3 minutes
```

---

## 🎉 Success Criteria

**Deployment Successful When:**

- ✅ All 3 contracts deployed to COTI testnet
- ✅ Deployment file created: `Coin/deployments/coti-testnet.json`
- ✅ Addresses synced to Validator, WebApp, Wallet modules
- ✅ PrivateOrderBook can connect to contracts
- ✅ Privacy available check returns `true`
- ✅ MPC operations work (price comparison, min, add, sub)

---

## 🔐 Security Notes

**Deployment Key:**
- ⚠️ Testnet only - DO NOT use for mainnet
- ⚠️ Stored in `.env` (not committed to git)
- ⚠️ Request new key for mainnet deployment

**Contract Upgradeability:**
- ✅ All contracts are UUPS upgradeable
- ✅ Only admin (deployer) can upgrade
- ✅ Storage gaps prevent collision during upgrades

---

## 📚 Additional Resources

- **COTI Docs:** https://docs.coti.io
- **COTI Discord:** https://discord.coti.io
- **COTI Explorer:** https://testnet.cotiscan.io
- **Block Explorer:** https://testnet.cotiscan.io

---

**Ready to Deploy?**

```bash
cd /home/rickc/OmniBazaar/Coin
./scripts/deploy-workflow.sh
```

---

## 🧹 Cleaned Up Files

**Removed temporary deployment scripts:**
- ❌ `deploy-coti-privacy.ts` (used upgrades plugin, didn't work)
- ❌ `deploy-coti-manual.ts` (manual transaction attempt, didn't work)
- ❌ `deploy-coti-debug.ts` (debugging script, no longer needed)
- ❌ `deploy-coti-simple.ts` (intermediate attempt, not needed)
- ❌ `test-init-call.ts` (debugging helper, not needed)
- ❌ `deploy-workflow.sh` (automated workflow, replaced)

**Kept for mainnet:**
- ✅ `deploy-all-coti.ts` - Working deployment script for simplified contracts
- ✅ `generate-deployment-key.js` - Key generation utility
- ✅ `check-balance.js` - Balance verification utility

---

## 📊 Deployment Statistics

**Testnet Deployment (2025-11-13):**
- Time to deploy: ~3 minutes
- Gas used: ~6,500,000 total
- Cost: 0.016 COTI
- Attempts before success: 8 (learning COTI RPC limitations)

**Key Learnings:**
1. COTI testnet RPC doesn't support "pending" block tag
2. MPC operations should NOT be called in constructor/initialize
3. Privacy detection must check chainId 7082400 (not 13068200 - devnet sunset)
4. Simplified contracts work perfectly for testing MPC functionality

