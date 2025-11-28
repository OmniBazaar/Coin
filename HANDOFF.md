# Coin Module - Handoff Document

**Last Updated:** 2025-11-28 19:45 UTC
**Current Task:** OmniRewardManager Implementation
**Status:** ✅ Implementation Complete, Tests Pending

---

## DO NOT REMOVE. RETAIN THESE AT THE TOP OF THIS FILE

### Module Overview
The Coin module contains all Solidity smart contracts for the OmniBazaar platform:
- **OmniCoin.sol** - XOM token (ERC20 with privacy features)
- **PrivateOmniCoin.sol** - pXOM privacy token (COTI V2)
- **OmniCore.sol** - Core logic, settlement, merkle roots
- **OmniRewardManager.sol** - Unified reward pool management (NEW)
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
# Deploy to Fuji testnet
npx hardhat run scripts/deploy.ts --network fuji

# Deploy OmniRewardManager
npx hardhat run scripts/deploy-reward-manager.ts --network fuji

# Sync addresses after deployment
cd /home/rickc/OmniBazaar && ./scripts/sync-contract-addresses.sh fuji
```

### Network Configuration
- **Fuji RPC:** See `Coin/deployments/fuji.json`
- **Chain ID:** 131313 (OmniCoin L1)
- **All deployed contracts:** `Coin/deployments/fuji.json`

---

## CURRENT WORK

### OmniRewardManager Implementation (2025-11-28)

**Background:**
User requested implementation of a unified reward pool management system. The legacy approach minted tokens on-demand, but the new design uses pre-minted pools for security and transparency.

**Decision Made:**
- ✅ Use pre-minted pools (not mint-on-demand) for all rewards
- ✅ Start fresh with ~16.6B effective supply (8.4B historical burn documented as constants)
- ✅ Use UUPS upgradeable proxy pattern
- ✅ Validator rewards decoupled from block production (2-second intervals via VirtualRewardScheduler)

### Files Created

1. **`/home/rickc/OmniBazaar/Validator/FIX_POOLS.md`** (700+ lines)
   - Comprehensive plan document
   - Token allocation breakdown
   - Smart contract architecture
   - Integration points with Validator services
   - Deployment steps

2. **`/home/rickc/OmniBazaar/Coin/contracts/OmniRewardManager.sol`** (775 lines)
   - UUPS upgradeable contract
   - Manages 4 pre-minted pools:
     - Welcome Bonus: 1,383,457,500 XOM
     - Referral Bonus: 2,995,000,000 XOM
     - First Sale Bonus: 2,000,000,000 XOM
     - Validator Rewards: 6,089,000,000 XOM
   - Merkle proof verification for claims
   - Role-based access control (BONUS_DISTRIBUTOR_ROLE, VALIDATOR_REWARD_ROLE, etc.)
   - Uses structs for complex parameters (ReferralParams, ValidatorRewardParams)
   - Properly ordered functions (external → view → internal → internal view → internal pure)

3. **`/home/rickc/OmniBazaar/Coin/contracts/interfaces/IOmniRewardManager.sol`** (233 lines)
   - Complete interface with NatSpec
   - Struct definitions for ReferralParams and ValidatorRewardParams
   - All events with indexed parameters

4. **`/home/rickc/OmniBazaar/Coin/scripts/deploy-reward-manager.ts`** (277 lines)
   - UUPS proxy deployment
   - Test pools: 100M XOM each (for Fuji)
   - Production pools: Full allocations
   - Auto-saves to deployments/{network}.json

### Code Quality Status

**Solhint Results:** 0 errors, 1 warning (false positive)
- The `import-path-check` warning is a false positive due to monorepo structure
- OpenZeppelin contracts are installed at root level: `/home/rickc/OmniBazaar/node_modules/@openzeppelin/`
- MerkleProof.sol exists and compiles correctly

**Compilation:** ✅ Successful
- Contract size: 9.3 KB deployment / 9.5 KB full
- All 30+ contracts compile with 0 errors

### Key Design Decisions

1. **State Variable Consolidation:** Reduced from 21 to 9 state variables using `PoolState` structs
   ```solidity
   struct PoolState {
       uint256 initial;
       uint256 remaining;
       uint256 distributed;
       bytes32 merkleRoot;
   }
   ```

2. **Event Optimization:** All events have exactly 3 indexed parameters (maximum allowed)

3. **Function Complexity:** Extracted validation logic into helper functions:
   - `_validateClaimParams()`, `_validatePoolBalance()`, `_validateNotClaimed()`
   - `_verifyMerkleProof()`, `_verifyReferralMerkleProof()`
   - `_distributeReferralRewards()`, `_distributeValidatorRewards()`

4. **Struct-based Parameters:** Complex functions use structs for cleaner interfaces:
   ```solidity
   function claimReferralBonus(ReferralParams calldata params, bytes32[] calldata merkleProof)
   function distributeValidatorReward(ValidatorRewardParams calldata params)
   ```

---

## REMAINING TASKS

### Immediate (This Session)
- [ ] Write comprehensive tests for OmniRewardManager
  - Test all 4 claim functions
  - Test pool depletion scenarios
  - Test access control
  - Test merkle proof verification
  - Test pause/unpause
  - Test upgrade functionality

### After Tests Pass
- [ ] Deploy to Fuji testnet with 100M XOM test pools
- [ ] Update `Coin/deployments/fuji.json` with addresses
- [ ] Run sync script: `./scripts/sync-contract-addresses.sh fuji`
- [ ] Update Validator services to call OmniRewardManager:
  - `BlockRewardService.ts` → call `distributeValidatorReward()`
  - `WelcomeBonusService.ts` → call `claimWelcomeBonus()`
  - `ReferralService.ts` → call `claimReferralBonus()`
  - `BonusService.ts` → call `claimFirstSaleBonus()`

### Future Enhancements
- [ ] Create `OmniRewardManagerService.ts` TypeScript wrapper in Validator module
- [ ] Add merkle tree generation for eligible users
- [ ] Integrate with WebApp for bonus claiming UI

---

## INTEGRATION POINTS

### Validator Services That Will Use OmniRewardManager

1. **VirtualRewardScheduler.ts** (`Validator/src/services/`)
   - Calls `distributeValidatorReward()` every 2 seconds
   - Passes validator, staking pool, and ODDAO addresses
   - Uses BlockProductionService for fair validator selection

2. **BlockRewardService.ts** (`Validator/src/services/`)
   - Contains reward calculation logic (15.228 XOM initial, 1% reduction schedule)
   - Will need to interact with OmniRewardManager for on-chain distribution

3. **WelcomeBonusService.ts** (`Validator/src/services/`)
   - Currently records claims but doesn't transfer tokens
   - Will call `claimWelcomeBonus()` with merkle proofs

4. **ReferralService.ts** (`Validator/src/services/`)
   - Two-level referral tracking
   - Will call `claimReferralBonus()` with referrer addresses

### Contract Addresses (After Deployment)
Update these in `Coin/deployments/fuji.json`:
```json
{
  "OmniRewardManager": "0x...",
  "OmniRewardManagerImpl": "0x..."
}
```

---

## KNOWN ISSUES

### Solhint False Positive
The `import-path-check` warning for MerkleProof.sol is a false positive:
- Monorepo structure places node_modules at root
- Hardhat resolves the import correctly
- Contract compiles and deploys successfully
- No action needed

### Interface Sync
If modifying OmniRewardManager.sol function signatures, remember to update:
1. `contracts/interfaces/IOmniRewardManager.sol`
2. `scripts/deploy-reward-manager.ts`
3. Any TypeScript services calling the contract

---

## TEST PLAN

### Unit Tests (`test/OmniRewardManager.test.ts`)

```typescript
describe('OmniRewardManager', () => {
  describe('Initialization', () => {
    it('should initialize with correct pool sizes');
    it('should set up roles correctly');
    it('should reject zero addresses');
  });

  describe('Welcome Bonus', () => {
    it('should allow claiming with valid merkle proof');
    it('should reject double claims');
    it('should reject invalid merkle proofs');
    it('should emit WelcomeBonusClaimed event');
    it('should emit PoolLowWarning when threshold crossed');
  });

  describe('Referral Bonus', () => {
    it('should distribute to both referrers');
    it('should handle missing second-level referrer');
    it('should track cumulative earnings');
  });

  describe('First Sale Bonus', () => {
    it('should allow claiming with valid proof');
    it('should reject double claims');
  });

  describe('Validator Rewards', () => {
    it('should distribute to validator, staking, and oddao');
    it('should increment virtual block height');
    it('should reject insufficient pool balance');
  });

  describe('Admin Functions', () => {
    it('should allow merkle root updates');
    it('should allow pausing/unpausing');
    it('should allow upgrades by UPGRADER_ROLE');
  });

  describe('View Functions', () => {
    it('should return correct pool balances');
    it('should return correct statistics');
  });
});
```

---

## RESOURCES

### Reference Files
- `Validator/FIX_POOLS.md` - Comprehensive plan document
- `Validator/src/services/VirtualRewardScheduler.ts` - 2-second reward intervals
- `Validator/src/services/BlockRewardService.ts` - Reward calculation logic
- `Validator/src/services/ParticipationScoreService.ts` - Proof of Participation scoring
- `CLAUDE.md` - Project coding standards

### External Documentation
- OpenZeppelin UUPS: https://docs.openzeppelin.com/contracts/5.x/api/proxy#UUPSUpgradeable
- OpenZeppelin MerkleProof: https://docs.openzeppelin.com/contracts/5.x/api/utils#MerkleProof
- Hardhat Upgrades: https://docs.openzeppelin.com/upgrades-plugins/hardhat-upgrades

---

## TODO LIST (Current Session)

```
[completed] Create FIX_POOLS.md comprehensive plan document
[completed] Implement OmniRewardManager.sol contract
[completed] Create deployment script for test pools
[completed] Run solhint and fix any issues
[completed] Compile and verify contract builds
[pending] Write tests for OmniRewardManager
```

---

**Document Status:** Complete for handoff
**Next Developer Action:** Write and run tests for OmniRewardManager
