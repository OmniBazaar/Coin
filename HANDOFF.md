# Coin Module - Handoff Document

**Last Updated:** 2025-12-06 21:20 UTC
**Current Task:** Bootstrap.sol C-Chain Deployment Complete
**Status:** All tasks complete, ready for production use

---

## DO NOT REMOVE. RETAIN THESE AT THE TOP OF THIS FILE

### Module Overview
The Coin module contains all Solidity smart contracts for the OmniBazaar platform:
- **OmniCoin.sol** - XOM token (ERC20 with privacy features)
- **PrivateOmniCoin.sol** - pXOM privacy token (COTI V2)
- **OmniCore.sol** - Core logic, settlement, merkle roots
- **Bootstrap.sol** - Node discovery on Avalanche C-Chain (NEW - deployed 2025-12-06)
- **OmniRewardManager.sol** - Unified reward pool management
- **OmniGovernance.sol** - DAO governance
- **MinimalEscrow.sol** - Marketplace escrow (2-of-3 multisig)
- **OmniBridge.sol** - Cross-chain bridges
- **DEXSettlement.sol** - Trade settlement
- **LegacyBalanceClaim.sol** - Migration for legacy users

### Critical Paths
- **Contracts:** `/home/rickc/OmniBazaar/Coin/contracts/`
- **Tests:** `/home/rickc/OmniBazaar/Coin/test/`
- **Scripts:** `/home/rickc/OmniBazaar/Coin/scripts/`
- **Deployments:** `/home/rickc/OmniBazaar/Coin/deployments/`

### Build & Test Commands
```bash
cd /home/rickc/OmniBazaar/Coin
npx hardhat compile          # Compile all contracts
npx solhint contracts/*.sol  # Lint contracts
npm test                     # Run all tests (156 tests)
```

### Deployment Commands
```bash
# Deploy to OmniCoin L1 (Fuji subnet)
npx hardhat run scripts/deploy.ts --network fuji

# Deploy Bootstrap.sol to Avalanche C-Chain
npx hardhat run scripts/deploy-bootstrap.js --network fuji-c-chain

# Fund validators on C-Chain
npx hardhat run scripts/fund-validators.js --network fuji-c-chain

# Test Bootstrap registration
npx hardhat run scripts/test-bootstrap-registration.js --network fuji-c-chain

# Sync addresses after deployment (REQUIRED)
cd /home/rickc/OmniBazaar && ./scripts/sync-contract-addresses.sh fuji
```

### Network Configuration

**OmniCoin L1 (Fuji Subnet):**
- Chain ID: 131313
- RPC: `http://127.0.0.1:40681/ext/bc/2TEeYGdsqvS3eLBk8vrd9bedJiPR7uyeUo1YChM75HtCf9TzFk/rpc`
- Deployment file: `Coin/deployments/fuji.json`

**Avalanche C-Chain (Fuji Testnet):**
- Chain ID: 43113
- RPC: `https://api.avax-test.network/ext/bc/C/rpc`
- Deployment file: `Coin/deployments/fuji-c-chain.json`
- Bootstrap contract: `0x09F99AE44bd024fD2c16ff6999959d053f0f32B5`

---

## CURRENT WORK

### Bootstrap.sol C-Chain Deployment (2025-12-06) - COMPLETE

**Purpose:** Deploy Bootstrap.sol on Avalanche C-Chain so clients can discover validators without needing access to the OmniCoin L1 subnet.

**Completed Tasks:**
1. ✅ Bootstrap.sol deployed to Fuji C-Chain
2. ✅ hardhat.config.js updated with `fuji-c-chain` network
3. ✅ sync-contract-addresses.sh updated to auto-sync C_CHAIN_BOOTSTRAP
4. ✅ All modules synced (Wallet, WebApp, Validator)
5. ✅ Validators funded with C-Chain AVAX
6. ✅ Node registration tested successfully

### Deployment Details

**Contract Address:** `0x09F99AE44bd024fD2c16ff6999959d053f0f32B5`

**Deployer:** `0xf8C9057d9649daCB06F14A7763233618Cc280663`

**OmniCore Reference (stored in Bootstrap):**
- Address: `0x0Ef606683222747738C04b4b00052F5357AC6c8b`
- Chain ID: 131313
- RPC URL: `http://127.0.0.1:40681/ext/bc/2TEeYGdsqvS3eLBk8vrd9bedJiPR7uyeUo1YChM75HtCf9TzFk/rpc`

### Registration Test Results

```
Total registered nodes: 1
Active gateway nodes: 1
Node is active: true
Node type: 0 (Gateway)
HTTP: https://validator1.test.omnibazaar.com
WS: wss://validator1.test.omnibazaar.com
Multiaddr: /ip4/127.0.0.1/tcp/14001/p2p/QmTest123
Region: us-west
```

### Key Files Created

1. **`scripts/deploy-bootstrap.js`** - Deploys Bootstrap.sol to C-Chain
2. **`scripts/fund-validators.js`** - Funds validators with C-Chain AVAX
3. **`scripts/test-bootstrap-registration.js`** - Tests registration flow
4. **`deployments/fuji-c-chain.json`** - C-Chain deployment record

### Bootstrap.sol Function Signatures

| Function | Parameters | Notes |
|----------|------------|-------|
| `registerNode()` | multiaddr, httpEndpoint, wsEndpoint, region, nodeType | Called once on startup |
| `updateNode()` | multiaddr, httpEndpoint, wsEndpoint, region | Updates existing registration |
| `heartbeat()` | none | **OPTIONAL** - just updates timestamp |
| `deactivateNode()` | reason | Voluntary deactivation |
| `getOmniCoreInfo()` | none | Returns (address, chainId, rpcUrl) |
| `getNodeInfo()` | nodeAddress | Returns node details tuple |
| `getActiveNodes()` | nodeType, limit | Returns address[] of active nodes |
| `isNodeActive()` | nodeAddress | Returns (bool, uint8 nodeType) |

**Important:** Heartbeat is OPTIONAL and will NOT drain gas automatically. No automatic deactivation for stale timestamps.

---

## SYNC SCRIPT UPDATES

The `scripts/sync-contract-addresses.sh` now automatically:
1. Reads `Coin/deployments/fuji-c-chain.json` for C-Chain Bootstrap address
2. Updates `C_CHAIN_BOOTSTRAP` section in all modules:
   - `Wallet/src/config/omnicoin-integration.ts`
   - `WebApp/src/config/omnicoin-integration.ts`
   - `Validator/src/config/omnicoin-integration.ts`

**Usage:**
```bash
cd /home/rickc/OmniBazaar
./scripts/sync-contract-addresses.sh fuji            # Sync all addresses
./scripts/sync-contract-addresses.sh fuji --validate # Verify consistency
```

---

## REMAINING TASKS

### Immediate (Next Session)
- [ ] Write tests for OmniRewardManager (from previous session)
- [ ] Deploy OmniRewardManager to Fuji testnet
- [ ] Configure validator private keys for C-Chain registration

### For Production
- [ ] Update Bootstrap OmniCore RPC URL for production (currently localhost)
- [ ] Deploy to mainnet C-Chain when ready
- [ ] Configure real validator endpoints

---

## KNOWN ISSUES

### None Currently Blocking

All Bootstrap.sol functionality tested and working:
- Registration: Working
- Update: Working
- Heartbeat: Working (optional)
- Node lookup: Working

---

## TODO LIST (Completed Session)

```
[completed] Read Bootstrap.sol contract
[completed] Add fuji-c-chain network to hardhat.config.js
[completed] Create deploy-bootstrap.js script for C-Chain
[completed] Deploy Bootstrap.sol to Fuji C-Chain
[completed] Update omnicoin-integration.ts with Bootstrap address
[completed] Modify sync-contract-addresses.sh for Bootstrap
[completed] Sync contract addresses to all modules
[completed] Check validator wallets have C-Chain AVAX
[completed] Fund validators from Deployer if needed
[completed] Test node registration on Bootstrap.sol
```

---

## RESOURCES

### Deployment Files
- `Coin/deployments/fuji.json` - OmniCoin L1 contracts
- `Coin/deployments/fuji-c-chain.json` - C-Chain Bootstrap
- `Coin/deployments/localhost.json` - Local development

### Reference Documentation
- Bootstrap.sol: `Coin/contracts/Bootstrap.sol` (560 lines)
- Node discovery design: `/home/rickc/OmniBazaar/BOOTSTRAP_DISCOVERY_REFERENCE.md`

---

**Document Status:** Complete for handoff
**Next Developer Action:** Write OmniRewardManager tests or configure production validators
