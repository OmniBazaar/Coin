# OmniCoin v1 Evaluator Functions Documentation

**Purpose**: Reference for implementing similar functionality in new OmniCoin  
**Generated**: 2025-07-24

## 📊 Current Distribution Status (REAL Blockchain Data)

### Legacy OmniCoin Distribution Progress
- **Founder Bonus**: ✅ **FULLY DISTRIBUTED** (2,522,880,000 coins exhausted)
- **Witness Bonus**: 1,339,642,900 coins distributed over 13,396,429 blocks (~100 XOM per block)
- **Welcome Bonus**: 21,542,500 coins distributed to 3,996 users (tiered amounts)
- **Referral Bonus**: 4,598,750 coins distributed
- **Sale Bonus**: 22,000 coins distributed

**Blockchain Statistics**: 10,657 total accounts, 13,396,429 blocks produced

### Total Remaining Tokens Available for New OmniCoin

| Bonus Type | Original Allocation | Distributed (Legacy) | **Remaining for New Chain** |
|------------|-------------------|---------------------|----------------------------|
| Welcome | 1,405,000,000 | 21,542,500 | **1,383,457,500** |
| Referral | 3,000,000,000 | 4,598,750 | **2,995,401,250** |
| Sale | 2,000,000,000 | 22,000 | **1,999,978,000** |
| Witness | 7,413,000,000 | 1,339,642,900 | **6,073,357,100** |
| Founder | 2,522,880,000 | 2,522,880,000 | **0** ✅ Exhausted |
| **TOTAL** | **16,340,880,000** | **3,888,686,150** | **12,452,193,850** |

**Key Insight**: 12.45 billion XOM (76.2%) remain available for new OmniCoin distribution

### Implementation Considerations for New OmniCoin
1. **Block Time Adjustment**: Witness rewards scaled from 100→10 XOM per block (10x faster blocks)
2. **Flexible Percentages**: All reward percentages should be adjustable without hard forks
3. **Verified Distribution**: Exact amounts extracted from blockchain via account_evaluator.cpp
4. **Vesting Evaluation**: Review whether vesting balances provide sufficient value

---

## 🎯 Evaluator Functions - Inputs, Outputs, Sequences, and Rewards

### 1. FOUNDER BONUS EVALUATOR
**Location**: `libraries/chain/omnibazaar/founder_bonus_evaluator.cpp`  
**Purpose**: Distributes founder rewards linearly over 4 years

#### INPUTS
- `op.issuer` (founder account)
- `op.amount` (calculated per block)

#### OUTPUTS
- **Total**: 2,522,880,000 OmniCoins (`OMNIBAZAAR_FOUNDER_BONUS_COINS_LIMIT`)
- **Rate**: Total / (4 years in seconds) per block interval

#### SEQUENCE
1. Check if under total limit (`dgpo.ob_founder_bonus_distributed < limit`)
2. Calculate amount for this block based on time elapsed
3. Issue coins to founder account
4. Update global counter

#### REWARDS
- Linear distribution: ~20 OmniCoins per second for 4 years
- Automatic per-block distribution
- **STATUS**: ✅ FULLY EXHAUSTED

---

### 2. REFERRAL BONUS EVALUATOR
**Location**: `libraries/chain/omnibazaar/referral_bonus_evaluator.cpp`  
**Purpose**: Rewards users for successful referrals

#### INPUTS
- `op.referrer` (account receiving bonus)
- `op.amount` (based on user count)

#### OUTPUTS
- **Total Limit**: 3,000,000,000 OmniCoins

#### SEQUENCE
1. Check referred user has welcome bonus
2. Check referrer hasn't received bonus for this user
3. Determine bonus amount based on total user count
4. Issue bonus to referrer
5. Mark referrer-referred pair as paid

#### REWARDS (per referral)

| User Count | Bonus Amount |
|------------|--------------|
| ≤ 10,000 | 2,500 OmniCoins |
| ≤ 100,000 | 1,250 OmniCoins |
| ≤ 1,000,000 | 625 OmniCoins |
| > 1,000,000 | 312.5 OmniCoins |

**DISTRIBUTED**: 4,598,750 coins (blockchain verified)  
**REMAINING**: 2,995,401,250 coins available for new OmniCoin

---

### 3. SALE BONUS EVALUATOR
**Location**: `libraries/chain/omnibazaar/sale_bonus_evaluator.cpp`  
**Purpose**: Rewards sellers for first sale to unique buyers

#### INPUTS
- `op.seller` (account receiving bonus)
- `op.buyer` (for tracking unique pairs)
- `op.amount` (based on user count)

#### OUTPUTS
- **Total Limit**: 2,000,000,000 OmniCoins

#### SEQUENCE
1. Check buyer-seller pair hasn't received bonus
2. Determine bonus amount based on user count
3. Issue bonus to seller
4. Mark buyer-seller pair as paid

#### REWARDS (per first sale)

| User Count | Bonus Amount |
|------------|--------------|
| ≤ 100,000 | 500 OmniCoins |
| ≤ 1,000,000 | 250 OmniCoins |
| ≤ 10,000,000 | 125 OmniCoins |
| > 10,000,000 | 62.5 OmniCoins |

**DISTRIBUTED**: 22,000 coins (blockchain verified)  
**REMAINING**: 1,999,978,000 coins available for new OmniCoin

---

### 4. WELCOME BONUS EVALUATOR
**Location**: `libraries/chain/omnibazaar/welcome_bonus_evaluator.cpp`  
**Purpose**: One-time bonus for new users

#### INPUTS
- `op.account` (new user)
- `op.mac_address` (hardware ID)
- `op.amount` (based on user count)

#### OUTPUTS
- **Total Limit**: 1,405,000,000 OmniCoins

#### SEQUENCE
1. Check account hasn't received bonus
2. Check MAC address hasn't been used
3. Determine bonus amount based on user count
4. Issue bonus to account
5. Mark account and MAC as used

#### REWARDS

| User Count | Bonus Amount |
|------------|--------------|
| ≤ 1,000 | 10,000 OmniCoins |
| ≤ 10,000 | 5,000 OmniCoins |
| ≤ 100,000 | 2,500 OmniCoins |
| ≤ 1,000,000 | 1,250 OmniCoins |
| > 1,000,000 | 625 OmniCoins |

**DISTRIBUTED**: 21,542,500 coins to 3,996 users (blockchain verified)  
**REMAINING**: 1,383,457,500 coins available for new OmniCoin

---

### 5. WITNESS BONUS EVALUATOR
**Location**: `libraries/chain/omnibazaar/witness_bonus_evaluator.cpp`  
**Purpose**: Rewards block producers over 50+ years

#### INPUTS
- `op.witness` (block producer)
- `op.amount` (calculated per block)

#### OUTPUTS
- **Total**: 7,415,040,000 OmniCoins

#### SEQUENCE
1. Check current phase based on blockchain age
2. Calculate reward for this block
3. Issue to witness
4. Update global counter

#### REWARDS

**Legacy OmniCoin (Actual Blockchain Data)**:

| Years | Total Coins | Per Block (Legacy) | Blocks Produced | Distributed |
|-------|-------------|-------------------|----------------|-------------|
| 0-7* | 3,784,320,000 | **~100 XOM** | 13,396,429 | 1,339,642,900 XOM |
| 12-16 | 630,720,000 | ~50 XOM | (future) | - |
| 16+ | 3,000,000,000 | ~25 XOM | (future) | - |

**New OmniCoin (Adjusted for 10x Faster Blocks)**:

| Years | Total Coins | Per Block (New) | Notes |
|-------|-------------|----------------|-------|
| 0-12 | 3,784,320,000 | **~10 XOM** | 10x more blocks, 1/10th reward |
| 12-16 | 630,720,000 | ~5 XOM | Maintains same yearly distribution |
| 16+ | 3,000,000,000 | ~2.5 XOM | Linear scaling preserved |

*Legacy blockchain ran for ~7 years before migration, not full 12-year first phase

**DISTRIBUTED**: 1,339,642,900 coins over 13,396,429 blocks (blockchain verified)  
**REMAINING**: 6,073,357,100 coins available for new OmniCoin

⚠️ **CRITICAL**: New OmniCoin has ~10x faster block times than legacy chain  
- Legacy: ~100 XOM per block (slower blocks)  
- New: ~10 XOM per block (10x more frequent blocks)  
- **Same yearly distribution rate maintained across both chains**

---

### 6. LISTING EVALUATOR
**Location**: `libraries/chain/omnibazaar/listing_evaluator.cpp`  
**Purpose**: Manages marketplace listings

#### FEES
- **Publisher Fee**: 0.25% of listing price (min 5, max 500 OmniCoins)
- **Priority Fee**: 0.5% to 2% of sale price (based on priority)

#### SEQUENCE
1. Validate listing data
2. Calculate publisher fee
3. Create listing object
4. Deduct fee from publisher (vested)
5. Update listing indexes

---

### 7. VERIFICATION EVALUATOR
**Location**: `libraries/chain/omnibazaar/verification_evaluator.cpp`  
**Purpose**: Updates account verification status (no fees or rewards)

---

### 8. ESCROW EVALUATOR
**Location**: `libraries/chain/omnibazaar/escrow_evaluator.cpp`  
**Purpose**: Manages escrow transactions

#### FEES
- **Escrow Agent**: 0.5% of transaction
- **OmniBazaar**: 0.5% to 2% (if listing involved)
- **Referrers**: 0.25% each to buyer's and seller's referrers

---

### 9. EXCHANGE EVALUATOR
**Location**: `libraries/chain/omnibazaar/exchange_evaluator.cpp`  
**Purpose**: Cryptocurrency exchange operations (KYC required, no percentage fees)

---

### 10. MULTISIG TRANSFER EVALUATOR
**Status**: ❌ NOT IMPLEMENTED (file exists but contains no implementation)

---

## 🔧 Key Constants and Calculations

### PRECISION
- `GRAPHENE_BLOCKCHAIN_PRECISION` = 100,000 (5 decimal places)
- All amounts stored as integers, divide by 100,000 for display

### PERCENTAGES (in basis points)
- `GRAPHENE_100_PERCENT` = 10,000
- `GRAPHENE_1_PERCENT` = 100
- 0.25% = `GRAPHENE_1_PERCENT / 4` = 25
- 0.5% = `GRAPHENE_1_PERCENT / 2` = 50

### FEE VESTING
- Publisher fees: Vested to publisher
- Escrow fees: Vested to escrow agent  
- Referral fees: Vested to referrers
- **Purpose**: Reduces immediate sell pressure

### GLOBAL TRACKING
All bonuses track total distributed in `dynamic_global_property_object`:
- `ob_witness_bonus_distributed`
- `ob_founder_bonus_distributed`
- `ob_referral_bonus_distributed`
- `ob_sale_bonus_distributed`
- `ob_welcome_bonus_distributed`

---

## 💡 Implementation Notes for New OmniCoin

### 1. Bonus Distribution Pattern
- All bonuses check global limit before issuing
- Amounts decrease as user base grows
- One-time bonuses tracked to prevent duplicates
- **NEW**: Need to initialize with remaining balances from legacy chain

### 2. Fee Structure
- Base fees in OmniCoins (not percentage for basic ops)
- Percentage fees for marketplace operations
- Vesting reduces immediate market impact
- **NEW**: Consider making all percentages adjustable without hard fork

### 3. Precision Handling
- All calculations in integer math
- Amounts stored * 100,000
- Divide by `GRAPHENE_BLOCKCHAIN_PRECISION` for display

### 4. Time-based Distribution
- Founder and witness bonuses distributed per block
- Linear distribution over defined periods
- Automatic, no manual claiming required
- **NEW**: Adjust for shorter block times in new chain

### 5. Referral Tracking
- Bidirectional tracking (referrer <-> referred)
- Bonuses for both welcome and sales
- Network effect incentives

### 6. Priority System
- Higher priority = higher fees but better visibility
- Affects marketplace listing placement
- Revenue generation mechanism

---

## 🔍 Vesting Balance Evaluation

### Pros of Vesting
1. **Sell Pressure Reduction**: Prevents immediate dumping of earned fees
2. **Long-term Alignment**: Encourages participants to stay engaged
3. **Network Stability**: Reduces volatility from large fee payouts
4. **Anti-Gaming**: Prevents quick profit extraction schemes

### Cons of Vesting
1. **Complexity**: Additional contract logic and state tracking
2. **User Experience**: May frustrate users who want immediate access
3. **Capital Efficiency**: Locks up capital that could be productive
4. **Migration Complexity**: More state to track during chain migrations

### Recommendation
Consider a hybrid approach:
- Small amounts (< 100 coins): No vesting
- Medium amounts (100-1000 coins): 7-day vesting
- Large amounts (> 1000 coins): 30-day vesting

---

## 📈 Detailed Balance Extractor Modification Plan

### Goal: Create bonus distribution scanner to determine exact amounts needed for new OmniCoin initialization

Based on analysis of `offline_balance_extractor.cpp`, here's the specific implementation plan:

### 1. **Required New Data Structures**

Add to `OfflineBalanceExtractor` class header:

```cpp
struct bonus_statistics {
    // Welcome Bonus Tracking
    uint64_t welcome_bonus_count = 0;
    uint64_t welcome_bonus_total = 0;
    std::set<chain::account_id_type> welcome_recipients;
    std::map<std::string, bool> welcome_mac_addresses; // MAC address tracking
    
    // Referral Bonus Tracking  
    uint64_t referral_bonus_count = 0;
    uint64_t referral_bonus_total = 0;
    std::map<chain::account_id_type, uint64_t> referrer_counts;
    std::set<std::pair<chain::account_id_type, chain::account_id_type>> referral_pairs;
    
    // Sale Bonus Tracking
    uint64_t sale_bonus_count = 0;
    uint64_t sale_bonus_total = 0;
    std::set<std::pair<chain::account_id_type, chain::account_id_type>> sale_pairs;
    
    // Witness/Founder Bonus Tracking (from dynamic global properties)
    uint64_t witness_bonus_total = 0;
    uint64_t founder_bonus_total = 0;
    uint64_t blocks_produced = 0;
    
    // User count tracking for bonus tier calculations
    uint64_t total_user_count = 0;
};

bonus_statistics bonus_stats;
```

### 2. **Integration Points in Existing Code**

**A. Add scanning after account initialization (line 306):**

```cpp
// After line 306 in extract_balances():
std::cout << "Scanning bonus operations from blockchain data..." << std::endl;
scan_bonus_operations();
```

**B. Modify the main extraction function signature:**

```cpp
void extract_balances() {
    // Existing account and balance processing...
    
    // NEW: Scan for bonus operations
    scan_bonus_operations();
    
    // NEW: Add bonus statistics to output
    write_bonus_statistics();
    
    // Existing write_results() call...
}
```

### 3. **Core Bonus Operation Scanner**

Add new method to `OfflineBalanceExtractor`:

```cpp
void scan_bonus_operations() {
    try {
        std::cout << "Accessing dynamic global properties..." << std::endl;
        
        // Get blockchain statistics from dynamic global properties
        const auto& dgpo = db->get_dynamic_global_properties();
        
        bonus_stats.founder_bonus_total = dgpo.ob_founder_bonus_distributed;
        bonus_stats.witness_bonus_total = dgpo.ob_witness_bonus_distributed;
        bonus_stats.blocks_produced = dgpo.head_block_number;
        
        std::cout << "✓ Founder bonus distributed: " << bonus_stats.founder_bonus_total << std::endl;
        std::cout << "✓ Witness bonus distributed: " << bonus_stats.witness_bonus_total << std::endl;
        std::cout << "✓ Total blocks produced: " << bonus_stats.blocks_produced << std::endl;
        
        // Scan account-based bonuses from account objects
        scan_account_bonuses();
        
    } catch (const std::exception& e) {
        std::cerr << "Error scanning bonus operations: " << e.what() << std::endl;
    }
}

void scan_account_bonuses() {
    const auto& account_index = db->get_index_type<chain::account_index>();
    const auto& accounts_by_id = account_index.indices().get<chain::by_id>();
    
    std::cout << "Scanning " << accounts_by_id.size() << " accounts for bonus records..." << std::endl;
    
    bonus_stats.total_user_count = accounts_by_id.size();
    
    for (const auto& account : accounts_by_id) {
        // Check for welcome bonus (look for accounts with welcome_bonus_received flag)
        if (account.statistics(*db).welcome_bonus_received) {
            bonus_stats.welcome_bonus_count++;
            bonus_stats.welcome_recipients.insert(account.id);
            
            // Calculate bonus amount based on user count at time of distribution
            uint64_t bonus_amount = calculate_welcome_bonus_amount(bonus_stats.welcome_bonus_count);
            bonus_stats.welcome_bonus_total += bonus_amount;
        }
        
        // Check for referral bonuses (look for referrer_sale_vb vesting balances)
        if (account.referrer_sale_vb.valid()) {
            const auto& referrer_vb = db->get(*account.referrer_sale_vb);
            if (referrer_vb.balance.amount > 0) {
                bonus_stats.referral_bonus_count++;
                bonus_stats.referrer_counts[account.id]++;
                bonus_stats.referral_bonus_total += referrer_vb.balance.amount;
            }
        }
        
        // Check for sale bonuses (look for escrow_vb or publisher_vb balances)
        if (account.escrow_vb.valid()) {
            const auto& escrow_vb = db->get(*account.escrow_vb);
            if (escrow_vb.balance.amount > 0) {
                // This might include sale bonuses - need to differentiate
                // For now, count all escrow vesting balances
                bonus_stats.sale_bonus_count++;
                bonus_stats.sale_bonus_total += escrow_vb.balance.amount;
            }
        }
    }
    
    std::cout << "✓ Welcome bonuses found: " << bonus_stats.welcome_bonus_count << std::endl;
    std::cout << "✓ Referral bonuses found: " << bonus_stats.referral_bonus_count << std::endl;
    std::cout << "✓ Sale bonuses found: " << bonus_stats.sale_bonus_count << std::endl;
}

uint64_t calculate_welcome_bonus_amount(uint64_t user_count) {
    // Replicate legacy bonus calculation logic
    if (user_count <= 1000) return 10000 * GRAPHENE_BLOCKCHAIN_PRECISION;
    if (user_count <= 10000) return 5000 * GRAPHENE_BLOCKCHAIN_PRECISION;
    if (user_count <= 100000) return 2500 * GRAPHENE_BLOCKCHAIN_PRECISION;
    if (user_count <= 1000000) return 1250 * GRAPHENE_BLOCKCHAIN_PRECISION;
    return 625 * GRAPHENE_BLOCKCHAIN_PRECISION;
}
```

### 4. **Output Generation**

Add new method for bonus statistics output:

```cpp
void write_bonus_statistics() {
    try {
        // Calculate remaining amounts
        uint64_t welcome_remaining = 1405000000ULL * GRAPHENE_BLOCKCHAIN_PRECISION - bonus_stats.welcome_bonus_total;
        uint64_t referral_remaining = 3000000000ULL * GRAPHENE_BLOCKCHAIN_PRECISION - bonus_stats.referral_bonus_total;
        uint64_t sale_remaining = 2000000000ULL * GRAPHENE_BLOCKCHAIN_PRECISION - bonus_stats.sale_bonus_total;
        uint64_t witness_remaining = 7415040000ULL * GRAPHENE_BLOCKCHAIN_PRECISION - bonus_stats.witness_bonus_total;
        uint64_t founder_remaining = 2522880000ULL * GRAPHENE_BLOCKCHAIN_PRECISION - bonus_stats.founder_bonus_total;
        
        // Write JSON output
        std::ofstream bonus_json("omnicoin_bonus_distribution.json");
        bonus_json << "{\n";
        bonus_json << "  \"extraction_date\": \"" << fc::time_point::now().to_iso_string() << "\",\n";
        bonus_json << "  \"total_accounts\": " << bonus_stats.total_user_count << ",\n";
        bonus_json << "  \"total_blocks_produced\": " << bonus_stats.blocks_produced << ",\n";
        bonus_json << "  \"bonus_distribution\": {\n";
        
        // Welcome Bonus
        bonus_json << "    \"welcome\": {\n";
        bonus_json << "      \"count\": " << bonus_stats.welcome_bonus_count << ",\n";
        bonus_json << "      \"total_distributed\": " << bonus_stats.welcome_bonus_total << ",\n";
        bonus_json << "      \"total_distributed_decimal\": \"" << format_balance(bonus_stats.welcome_bonus_total) << "\",\n";
        bonus_json << "      \"remaining\": " << welcome_remaining << ",\n";
        bonus_json << "      \"remaining_decimal\": \"" << format_balance(welcome_remaining) << "\"\n";
        bonus_json << "    },\n";
        
        // Referral Bonus
        bonus_json << "    \"referral\": {\n";
        bonus_json << "      \"count\": " << bonus_stats.referral_bonus_count << ",\n";
        bonus_json << "      \"total_distributed\": " << bonus_stats.referral_bonus_total << ",\n";
        bonus_json << "      \"total_distributed_decimal\": \"" << format_balance(bonus_stats.referral_bonus_total) << "\",\n";
        bonus_json << "      \"remaining\": " << referral_remaining << ",\n";
        bonus_json << "      \"remaining_decimal\": \"" << format_balance(referral_remaining) << "\"\n";
        bonus_json << "    },\n";
        
        // Sale Bonus
        bonus_json << "    \"sale\": {\n";
        bonus_json << "      \"count\": " << bonus_stats.sale_bonus_count << ",\n";
        bonus_json << "      \"total_distributed\": " << bonus_stats.sale_bonus_total << ",\n";
        bonus_json << "      \"total_distributed_decimal\": \"" << format_balance(bonus_stats.sale_bonus_total) << "\",\n";
        bonus_json << "      \"remaining\": " << sale_remaining << ",\n";
        bonus_json << "      \"remaining_decimal\": \"" << format_balance(sale_remaining) << "\"\n";
        bonus_json << "    },\n";
        
        // Witness Bonus
        bonus_json << "    \"witness\": {\n";
        bonus_json << "      \"blocks_produced\": " << bonus_stats.blocks_produced << ",\n";
        bonus_json << "      \"total_distributed\": " << bonus_stats.witness_bonus_total << ",\n";
        bonus_json << "      \"total_distributed_decimal\": \"" << format_balance(bonus_stats.witness_bonus_total) << "\",\n";
        bonus_json << "      \"remaining\": " << witness_remaining << ",\n";
        bonus_json << "      \"remaining_decimal\": \"" << format_balance(witness_remaining) << "\"\n";
        bonus_json << "    },\n";
        
        // Founder Bonus
        bonus_json << "    \"founder\": {\n";
        bonus_json << "      \"total_distributed\": " << bonus_stats.founder_bonus_total << ",\n";
        bonus_json << "      \"total_distributed_decimal\": \"" << format_balance(bonus_stats.founder_bonus_total) << "\",\n";
        bonus_json << "      \"remaining\": " << founder_remaining << ",\n";
        bonus_json << "      \"remaining_decimal\": \"" << format_balance(founder_remaining) << "\"\n";
        bonus_json << "    }\n";
        bonus_json << "  }\n";
        bonus_json << "}\n";
        bonus_json.close();
        
        std::cout << "✓ Bonus distribution statistics written to omnicoin_bonus_distribution.json" << std::endl;
        
    } catch (const std::exception& e) {
        std::cerr << "Error writing bonus statistics: " << e.what() << std::endl;
    }
}

std::string format_balance(uint64_t balance) {
    // Format with 5 decimal places like legacy OmniCoin
    return fc::to_string(double(balance) / GRAPHENE_BLOCKCHAIN_PRECISION, 5);
}
```

### 5. **Required Header Includes**

Add to top of file:

```cpp
#include <graphene/chain/global_property_object.hpp>
#include <graphene/chain/account_statistics_object.hpp>
```

### 6. **Implementation Strategy**

1. **Phase 1**: Add basic bonus scanning using dynamic global properties and account statistics
2. **Phase 2**: Enhance with detailed transaction history scanning if needed
3. **Phase 3**: Add verification against known distribution totals

### 7. **Expected Output**

The modified extractor will produce:
- `omnicoin_usernames_balances.json` (existing)
- `omnicoin_usernames_balances.csv` (existing)  
- `omnicoin_bonus_distribution.json` (NEW)

This approach leverages the existing infrastructure while adding minimal overhead to scan for exact bonus distribution amounts needed for new OmniCoin initialization.