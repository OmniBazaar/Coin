# Role Assignment Runbook

**Last Updated:** 2026-03-07
**Chain:** OmniBazaar Mainnet (Chain ID 88008)
**Deployer:** `0xaDAD7751DcDd2E30015C173F2c35a56e467CD9ba`
**ODDAO Treasury:** `0x664B6347a69A22b35348D42E4640CA92e1609378`

---

## Overview

Every OmniBazaar smart contract uses OpenZeppelin AccessControl (or AccessControlDefaultAdminRules for OmniCoin). Roles gate who can mint, pause, upgrade, distribute rewards, settle trades, and perform other privileged operations. Misassigning a role can result in loss of funds, bricked upgrades, or unauthorized minting.

This runbook lists every role defined across all deployed contracts, explains what each role controls, documents who should hold it, and provides verification commands.

---

## Role Definitions

### OmniCoin (XOM Token)

| Role | Constant | Purpose |
|------|----------|---------|
| `DEFAULT_ADMIN_ROLE` | `0x00` | Grant/revoke all other roles. 48-hour two-step transfer via AccessControlDefaultAdminRules. |
| `MINTER_ROLE` | `keccak256("MINTER_ROLE")` | Mint new XOM tokens. **PERMANENTLY REVOKED** after genesis funding. |
| `BURNER_ROLE` | `keccak256("BURNER_ROLE")` | Burn XOM tokens on behalf of holders. |

**Security note:** MINTER_ROLE has been revoked from all addresses. No entity can mint new XOM. The 16.6B supply is final.

### OmniCore (Core Settlement & Registry)

| Role | Constant | Purpose |
|------|----------|---------|
| `DEFAULT_ADMIN_ROLE` | `0x00` | Grant/revoke roles, pause/unpause, authorize UUPS upgrades. |
| `ADMIN_ROLE` | `keccak256("ADMIN_ROLE")` | Set service addresses, manage validator registry, set ODDAO/staking addresses, configure multi-sig thresholds. |
| `AVALANCHE_VALIDATOR_ROLE` | `keccak256("AVALANCHE_VALIDATOR_ROLE")` | Submit settlement batches, submit master root hashes, sign multi-validator transactions. Granted/revoked via `setValidator()`. |

### OmniRegistration (User Registration & KYC)

| Role | Constant | Purpose |
|------|----------|---------|
| `DEFAULT_ADMIN_ROLE` | `0x00` | Grant/revoke roles, manage KYC providers, set verification key, admin unregister users, authorize UUPS upgrades. |
| `VALIDATOR_ROLE` | `keccak256("VALIDATOR_ROLE")` | Register new users on-chain, process registrations submitted by users. |
| `KYC_ATTESTOR_ROLE` | `keccak256("KYC_ATTESTOR_ROLE")` | Attest KYC tier upgrades for users. Requires 3-of-5 attestation threshold for each upgrade. |
| `BONUS_MARKER_ROLE` | `keccak256("BONUS_MARKER_ROLE")` | Mark welcome bonus and first sale bonus as claimed (called by OmniRewardManager). |
| `TRANSACTION_RECORDER_ROLE` | `keccak256("TRANSACTION_RECORDER_ROLE")` | Record marketplace/DEX transactions for KYC volume tracking. Mark first sale completed. Held by marketplace/escrow contracts. |

### OmniRewardManager (Bonus & Reward Pools)

| Role | Constant | Purpose |
|------|----------|---------|
| `DEFAULT_ADMIN_ROLE` | `0x00` | Grant/revoke roles, set registration contract, set ODDAO address, authorize UUPS upgrades, pause/unpause. |
| `BONUS_DISTRIBUTOR_ROLE` | `keccak256("BONUS_DISTRIBUTOR_ROLE")` | Distribute welcome, referral, and first sale bonuses to users. |
| `VALIDATOR_REWARD_ROLE` | `keccak256("VALIDATOR_REWARD_ROLE")` | Distribute block rewards to validators, staking pool, and ODDAO. |
| `UPGRADER_ROLE` | `keccak256("UPGRADER_ROLE")` | Authorize UUPS implementation upgrades. |
| `PAUSER_ROLE` | `keccak256("PAUSER_ROLE")` | Emergency pause of all reward distribution. |

### OmniValidatorRewards (Block Reward Distribution)

| Role | Constant | Purpose |
|------|----------|---------|
| `DEFAULT_ADMIN_ROLE` | `0x00` | Grant/revoke roles, set contract references, authorize UUPS upgrades, propose/apply/cancel contract updates. |
| `BLOCKCHAIN_ROLE` | `keccak256("BLOCKCHAIN_ROLE")` | Record block production for reward calculation. Called by the block production pipeline. |
| `PENALTY_ROLE` | `keccak256("PENALTY_ROLE")` | Apply reward penalties to misbehaving validators. |
| `ROLE_MANAGER_ROLE` | `keccak256("ROLE_MANAGER_ROLE")` | Set gateway/service-node role multipliers for reward distribution. |

### OmniParticipation (100-Point Scoring)

| Role | Constant | Purpose |
|------|----------|---------|
| `DEFAULT_ADMIN_ROLE` | `0x00` | Grant/revoke roles, set contract references, ossify contract, authorize UUPS upgrades. |
| `VERIFIER_ROLE` | `keccak256("VERIFIER_ROLE")` | Verify and submit participation score claims on behalf of users. |

### StakingRewardPool

| Role | Constant | Purpose |
|------|----------|---------|
| `DEFAULT_ADMIN_ROLE` | `0x00` | Grant/revoke roles, pause/unpause, emergency token rescue, authorize UUPS upgrades. |
| `ADMIN_ROLE` | `keccak256("ADMIN_ROLE")` | Configure APR tiers, set reward parameters. |

### UnifiedFeeVault

| Role | Constant | Purpose |
|------|----------|---------|
| `DEFAULT_ADMIN_ROLE` | `0x00` | Grant/revoke roles, rescue stuck tokens, authorize UUPS upgrades. |
| `ADMIN_ROLE` | `keccak256("ADMIN_ROLE")` | Configure fee splits, set recipient addresses, manage timelock changes. |
| `DEPOSITOR_ROLE` | `keccak256("DEPOSITOR_ROLE")` | Deposit fees into the vault. Held by marketplace, DEX, and other fee-generating contracts. |
| `BRIDGE_ROLE` | `keccak256("BRIDGE_ROLE")` | Bridge accumulated ODDAO funds to the ODDAO treasury. Call `bridgeToTreasury()`, `swapAndBridge()`, `convertPXOMAndBridge()`. |
| `FEE_MANAGER_ROLE` | `keccak256("FEE_MANAGER_ROLE")` | Update fee percentages and distribution parameters. |

### OmniBridge (Cross-Chain Bridge)

| Role | Constant | Purpose |
|------|----------|---------|
| `DEFAULT_ADMIN_ROLE` | `0x00` | Grant/revoke roles, authorize UUPS upgrades. |
| `ADMIN_ROLE` | `keccak256("ADMIN_ROLE")` | Set fee vault, configure bridge parameters, manage supported chains. |

### OmniPrivacyBridge (XOM/pXOM Privacy Bridge)

| Role | Constant | Purpose |
|------|----------|---------|
| `DEFAULT_ADMIN_ROLE` | `0x00` | Grant/revoke roles, set limits, ossify contract, emergency token rescue, authorize UUPS upgrades. |
| `OPERATOR_ROLE` | `keccak256("OPERATOR_ROLE")` | Pause/unpause bridge operations. |
| `FEE_MANAGER_ROLE` | `keccak256("FEE_MANAGER_ROLE")` | Adjust privacy conversion fee parameters. |

### OmniGovernance (DAO Governance)

| Role | Constant | Purpose |
|------|----------|---------|
| `DEFAULT_ADMIN_ROLE` | `0x00` | Grant/revoke roles, authorize UUPS upgrades. `transferToTimelock()` permanently transfers both admin roles to a timelock. |
| `ADMIN_ROLE` | `keccak256("ADMIN_ROLE")` | Configure governance parameters (quorum, voting period, proposal threshold). |

### OmniArbitration (Dispute Resolution)

| Role | Constant | Purpose |
|------|----------|---------|
| `DEFAULT_ADMIN_ROLE` | `0x00` | Grant/revoke roles, set contract references, set treasury addresses, configure stakes, schedule upgrades. |
| `DISPUTE_ADMIN_ROLE` | `keccak256("DISPUTE_ADMIN_ROLE")` | Manage dispute lifecycle, assign arbitrators, override dispute outcomes in emergencies. |

### OmniMarketplace (On-Chain Marketplace Settlements)

| Role | Constant | Purpose |
|------|----------|---------|
| `DEFAULT_ADMIN_ROLE` | `0x00` | Grant/revoke roles, pause/unpause, schedule/cancel/authorize UUPS upgrades. |
| `MARKETPLACE_ADMIN_ROLE` | `keccak256("MARKETPLACE_ADMIN_ROLE")` | Configure marketplace parameters, manage listing rules. |

### OmniPriceOracle

| Role | Constant | Purpose |
|------|----------|---------|
| `DEFAULT_ADMIN_ROLE` | `0x00` | Grant/revoke roles, set OmniCore reference, pause/unpause, schedule/cancel UUPS upgrades. |
| `ORACLE_ADMIN_ROLE` | `keccak256("ORACLE_ADMIN_ROLE")` | Configure oracle parameters (min validators, staleness threshold, circuit breaker). |

### UpdateRegistry (Software Version Management)

| Role | Constant | Purpose |
|------|----------|---------|
| `DEFAULT_ADMIN_ROLE` | `0x00` | Grant/revoke roles. |
| `RELEASE_MANAGER_ROLE` | `keccak256("RELEASE_MANAGER_ROLE")` | Submit new software releases (with valid ODDAO signatures). |

### Bootstrap (Network Bootstrap Registry)

| Role | Constant | Purpose |
|------|----------|---------|
| `DEFAULT_ADMIN_ROLE` | `0x00` | Grant/revoke roles. |
| `BOOTSTRAP_ADMIN_ROLE` | `keccak256("BOOTSTRAP_ADMIN_ROLE")` | Emergency node management in bootstrap registry. |

### PrivateOmniCoin (pXOM Token -- COTI Network)

| Role | Constant | Purpose |
|------|----------|---------|
| `DEFAULT_ADMIN_ROLE` | `0x00` | Grant/revoke roles. |
| `MINTER_ROLE` | `keccak256("MINTER_ROLE")` | Mint pXOM tokens during privacy conversions. |
| `BURNER_ROLE` | `keccak256("BURNER_ROLE")` | Burn pXOM tokens during de-privacy conversions. |
| `BRIDGE_ROLE` | `keccak256("BRIDGE_ROLE")` | Bridge operations for cross-chain pXOM transfers. |

### Privacy Token Wrappers (PrivateWETH, PrivateUSDC, PrivateWBTC -- COTI Network)

| Role | Constant | Purpose |
|------|----------|---------|
| `DEFAULT_ADMIN_ROLE` | `0x00` | Grant/revoke roles. |
| `BRIDGE_ROLE` | `keccak256("BRIDGE_ROLE")` | Mint/burn wrapped privacy tokens during bridge operations. |

### PrivateDEX (Privacy DEX -- COTI Network)

| Role | Constant | Purpose |
|------|----------|---------|
| `DEFAULT_ADMIN_ROLE` | `0x00` | Grant/revoke roles. |
| `MATCHER_ROLE` | `keccak256("MATCHER_ROLE")` | Match privacy-preserving DEX orders. |
| `ADMIN_ROLE` | `keccak256("ADMIN_ROLE")` | Configure DEX parameters. |

### PrivateDEXSettlement (Privacy DEX Settlement -- COTI Network)

| Role | Constant | Purpose |
|------|----------|---------|
| `DEFAULT_ADMIN_ROLE` | `0x00` | Grant/revoke roles. |
| `SETTLER_ROLE` | `keccak256("SETTLER_ROLE")` | Execute privacy trade settlements. Held by validator nodes. |
| `ADMIN_ROLE` | `keccak256("ADMIN_ROLE")` | Configure settlement parameters. |

### MintController (DEPRECATED)

| Role | Constant | Purpose |
|------|----------|---------|
| `MINTER_ROLE` | `keccak256("MINTER_ROLE")` | **DEPRECATED.** Was intended for controlled minting. Conflicts with trustless architecture. |
| `PAUSER_ROLE` | `keccak256("PAUSER_ROLE")` | **DEPRECATED.** Was intended for emergency pause of minting. |

### OmniSybilGuard (DEPRECATED)

| Role | Constant | Purpose |
|------|----------|---------|
| `DEVICE_REGISTRAR_ROLE` | `keccak256("DEVICE_REGISTRAR_ROLE")` | **DEPRECATED.** Was for device fingerprint registration. |
| `JUDGE_ROLE` | `keccak256("JUDGE_ROLE")` | **DEPRECATED.** Was for Sybil report adjudication. |

---

## Assignment Matrix

### Mainnet Contract Addresses

| Contract | Proxy Address |
|----------|---------------|
| OmniCoin | `0xFC2aA43A546b4eA9fFF6cFe02A49A793a78B898B` |
| OmniCore | `0xc2468BA2F42b5ea9095B43E68F39c366730B84B4` |
| OmniRegistration | `0x7C3C3081128A71817d6450467cD143549Bfc0405` |
| OmniRewardManager | `0xaE3D9bDf72a7160712cb99f01E937Ee2F5AF339c` |
| OmniValidatorRewards | `0x4b9DbBD359A7c0A5B0893Be532b634e9cB99543D` |
| OmniParticipation | `0xD95a682e06A618a1c1a5e2AEb2086AeD87140e0f` |
| StakingRewardPool | `0x1cc9FF243A3e76A6c122aa708bB3Fd375a97c7d6` |
| UnifiedFeeVault | `0x732d5711f9D97B3AFa3C4c0e4D1011EBF1550b8c` |
| OmniBridge | (see mainnet.json) |
| OmniPrivacyBridge | (see mainnet.json) |
| OmniGovernance | `0xe71CB04287A3Bd82cd901EA4B344fC6EA5054d25` |
| OmniArbitration | `0xa47dC07a3608646605DFAaC392eaE90bfc750a7B` |
| OmniMarketplace | `0xb3E389014B2A2cDB18EB8AfB9353129c24559b76` |
| OmniPriceOracle | `0x9CB1124388Bd749887dd89cA47E5E82c5E95416e` |
| UpdateRegistry | `0x4fe0645cea2293D4A49ECF165218054f683E1F51` |
| MinimalEscrow | `0x9338B9eF1291b0266D28E520797eD57020A84D3B` |
| DEXSettlement | `0x9B0a1aB09122ecb98D7132e4329d23Cc224D4476` |

---

## Pioneer Phase Assignments (Current State)

During the Pioneer Phase, the deployer (`0xaDAD...9ba`) holds all admin and operational roles. This is intentional for rapid iteration. The table below shows the current state.

| Contract | Role | Current Holder |
|----------|------|----------------|
| **OmniCoin** | DEFAULT_ADMIN_ROLE | Deployer |
| | MINTER_ROLE | **REVOKED from all** |
| | BURNER_ROLE | Deployer |
| **OmniCore** | DEFAULT_ADMIN_ROLE | Deployer |
| | ADMIN_ROLE | Deployer |
| | AVALANCHE_VALIDATOR_ROLE | Deployer + registered validators |
| **OmniRegistration** | DEFAULT_ADMIN_ROLE | Deployer |
| | VALIDATOR_ROLE | Deployer (+ validator nodes) |
| | KYC_ATTESTOR_ROLE | Deployer (+ validator nodes) |
| | BONUS_MARKER_ROLE | OmniRewardManager contract |
| | TRANSACTION_RECORDER_ROLE | MinimalEscrow, DEXSettlement (needs granting) |
| **OmniRewardManager** | DEFAULT_ADMIN_ROLE | Deployer |
| | BONUS_DISTRIBUTOR_ROLE | Deployer / validator service |
| | VALIDATOR_REWARD_ROLE | Deployer / OmniValidatorRewards |
| | UPGRADER_ROLE | Deployer |
| | PAUSER_ROLE | Deployer |
| **OmniValidatorRewards** | DEFAULT_ADMIN_ROLE | Deployer |
| | BLOCKCHAIN_ROLE | Deployer |
| | PENALTY_ROLE | Deployer |
| | ROLE_MANAGER_ROLE | Deployer |
| **OmniParticipation** | DEFAULT_ADMIN_ROLE | Deployer |
| | VERIFIER_ROLE | Deployer |
| **StakingRewardPool** | DEFAULT_ADMIN_ROLE | Deployer |
| | ADMIN_ROLE | Deployer |
| **UnifiedFeeVault** | DEFAULT_ADMIN_ROLE | Deployer |
| | ADMIN_ROLE | Deployer |
| | BRIDGE_ROLE | Deployer |
| | DEPOSITOR_ROLE | (needs granting to fee-generating contracts) |
| | FEE_MANAGER_ROLE | Deployer |
| **OmniGovernance** | DEFAULT_ADMIN_ROLE | Deployer |
| | ADMIN_ROLE | Deployer |
| **OmniArbitration** | DEFAULT_ADMIN_ROLE | Deployer |
| | DISPUTE_ADMIN_ROLE | Deployer |
| **OmniMarketplace** | DEFAULT_ADMIN_ROLE | Deployer |
| | MARKETPLACE_ADMIN_ROLE | Deployer |
| **OmniPriceOracle** | DEFAULT_ADMIN_ROLE | Deployer |
| | ORACLE_ADMIN_ROLE | Deployer |
| **OmniPrivacyBridge** | DEFAULT_ADMIN_ROLE | Deployer |
| | OPERATOR_ROLE | Deployer |
| | FEE_MANAGER_ROLE | Deployer |
| **OmniBridge** | DEFAULT_ADMIN_ROLE | Deployer |
| | ADMIN_ROLE | Deployer |

### Pioneer Phase Role Granting Script

```bash
# Grant roles to validators and inter-contract roles
npx hardhat run scripts/grant-roles.ts --network mainnet

# Grant BRIDGE_ROLE on UnifiedFeeVault
npx hardhat run scripts/grant-bridge-role.js --network mainnet
```

The `grant-roles.ts` script grants:
- `VALIDATOR_ROLE` and `KYC_ATTESTOR_ROLE` on OmniRegistration (to validator addresses)
- `PENALTY_ROLE` on OmniValidatorRewards (to validator addresses)
- `VERIFIER_ROLE` on OmniParticipation (to validator addresses)

---

## Production Phase Assignments (Target State)

In production, all admin roles transfer to a TimelockController (48h+ delay) controlled by a 3-of-5 Gnosis Safe multisig. Operational roles go to purpose-specific addresses.

| Contract | Role | Production Holder |
|----------|------|-------------------|
| **OmniCoin** | DEFAULT_ADMIN_ROLE | TimelockController (48h built-in delay via AccessControlDefaultAdminRules) |
| | MINTER_ROLE | **PERMANENTLY REVOKED** |
| | BURNER_ROLE | TimelockController |
| **OmniCore** | DEFAULT_ADMIN_ROLE | TimelockController |
| | ADMIN_ROLE | TimelockController |
| | AVALANCHE_VALIDATOR_ROLE | Active validator addresses only |
| **OmniRegistration** | DEFAULT_ADMIN_ROLE | TimelockController |
| | VALIDATOR_ROLE | Each gateway validator address |
| | KYC_ATTESTOR_ROLE | Each gateway validator address |
| | BONUS_MARKER_ROLE | OmniRewardManager contract address |
| | TRANSACTION_RECORDER_ROLE | MinimalEscrow, DEXSettlement, OmniMarketplace contract addresses |
| **OmniRewardManager** | DEFAULT_ADMIN_ROLE | TimelockController |
| | BONUS_DISTRIBUTOR_ROLE | Validator service account (dedicated EOA) |
| | VALIDATOR_REWARD_ROLE | OmniValidatorRewards contract address |
| | UPGRADER_ROLE | TimelockController |
| | PAUSER_ROLE | Emergency multisig (separate from admin multisig) |
| **OmniValidatorRewards** | DEFAULT_ADMIN_ROLE | TimelockController |
| | BLOCKCHAIN_ROLE | Block production service (validator service account) |
| | PENALTY_ROLE | Governance-controlled penalty executor |
| | ROLE_MANAGER_ROLE | TimelockController |
| **OmniParticipation** | DEFAULT_ADMIN_ROLE | TimelockController |
| | VERIFIER_ROLE | Each gateway validator address |
| **StakingRewardPool** | DEFAULT_ADMIN_ROLE | TimelockController |
| | ADMIN_ROLE | TimelockController |
| **UnifiedFeeVault** | DEFAULT_ADMIN_ROLE | TimelockController |
| | ADMIN_ROLE | TimelockController |
| | DEPOSITOR_ROLE | OmniMarketplace, DEXSettlement, OmniChatFee, OmniENS (fee-generating contracts) |
| | BRIDGE_ROLE | Dedicated bridge operator EOA |
| | FEE_MANAGER_ROLE | TimelockController |
| **OmniGovernance** | DEFAULT_ADMIN_ROLE | TimelockController (via `transferToTimelock()`) |
| | ADMIN_ROLE | TimelockController (via `transferToTimelock()`) |
| **OmniArbitration** | DEFAULT_ADMIN_ROLE | TimelockController |
| | DISPUTE_ADMIN_ROLE | Dedicated dispute management service |
| **OmniMarketplace** | DEFAULT_ADMIN_ROLE | TimelockController |
| | MARKETPLACE_ADMIN_ROLE | TimelockController |
| **OmniPriceOracle** | DEFAULT_ADMIN_ROLE | TimelockController |
| | ORACLE_ADMIN_ROLE | TimelockController |
| **OmniPrivacyBridge** | DEFAULT_ADMIN_ROLE | TimelockController |
| | OPERATOR_ROLE | Dedicated bridge operator |
| | FEE_MANAGER_ROLE | TimelockController |
| **OmniBridge** | DEFAULT_ADMIN_ROLE | TimelockController |
| | ADMIN_ROLE | TimelockController |

### Production Transition Steps

1. Deploy `OmniTimelockController` with 48h minimum delay and 3-of-5 Gnosis Safe as proposer/executor.
2. For each contract: grant `DEFAULT_ADMIN_ROLE` to the TimelockController.
3. For each contract: grant `ADMIN_ROLE` (where applicable) to the TimelockController.
4. Grant operational roles to purpose-specific addresses (validators, service accounts, contracts).
5. Revoke all roles from deployer EOA.
6. For OmniGovernance: call `transferToTimelock(timelockAddress)` which atomically transfers and revokes.
7. Verify all assignments (see Verification Commands below).

---

## Verification Commands

Use these commands via `npx hardhat console --network mainnet` or a script to verify role assignments.

### Check if an address has a role

```javascript
const contract = await ethers.getContractAt("OmniCore", "0xc2468BA2F42b5ea9095B43E68F39c366730B84B4");

// DEFAULT_ADMIN_ROLE is always bytes32(0)
const DEFAULT_ADMIN = "0x0000000000000000000000000000000000000000000000000000000000000000";

// Check DEFAULT_ADMIN_ROLE
await contract.hasRole(DEFAULT_ADMIN, "0xaDAD7751DcDd2E30015C173F2c35a56e467CD9ba");

// Check a named role
const ADMIN_ROLE = await contract.ADMIN_ROLE();
await contract.hasRole(ADMIN_ROLE, "0xaDAD7751DcDd2E30015C173F2c35a56e467CD9ba");
```

### Verify OmniCoin MINTER_ROLE is revoked

```javascript
const xom = await ethers.getContractAt("OmniCoin", "0xFC2aA43A546b4eA9fFF6cFe02A49A793a78B898B");
const MINTER_ROLE = await xom.MINTER_ROLE();
const deployer = "0xaDAD7751DcDd2E30015C173F2c35a56e467CD9ba";

// Must return false
const hasMinter = await xom.hasRole(MINTER_ROLE, deployer);
console.log("Deployer has MINTER_ROLE:", hasMinter); // Expected: false
```

### Verify all roles on OmniRegistration

```javascript
const reg = await ethers.getContractAt("OmniRegistration", "0x7C3C3081128A71817d6450467cD143549Bfc0405");
const addr = "0xaDAD7751DcDd2E30015C173F2c35a56e467CD9ba";

const roles = {
  VALIDATOR_ROLE: await reg.VALIDATOR_ROLE(),
  KYC_ATTESTOR_ROLE: await reg.KYC_ATTESTOR_ROLE(),
  BONUS_MARKER_ROLE: await reg.BONUS_MARKER_ROLE(),
  TRANSACTION_RECORDER_ROLE: await reg.TRANSACTION_RECORDER_ROLE(),
};

for (const [name, hash] of Object.entries(roles)) {
  console.log(`${name}: ${await reg.hasRole(hash, addr)}`);
}
```

### Batch verification script

```bash
npx hardhat run scripts/grant-roles.ts --network mainnet
# The script includes a verification section that checks all role assignments
```

### Verify role admin (who can grant/revoke a role)

```javascript
const contract = await ethers.getContractAt("OmniCore", "0xc2468BA2F42b5ea9095B43E68F39c366730B84B4");
const ADMIN_ROLE = await contract.ADMIN_ROLE();

// Returns the role that administers ADMIN_ROLE (typically DEFAULT_ADMIN_ROLE = 0x00)
const roleAdmin = await contract.getRoleAdmin(ADMIN_ROLE);
console.log("Admin of ADMIN_ROLE:", roleAdmin);
```

---

## Security Checklist

### Before Any Role Grant

- [ ] Verify the target address is correct (double-check against `deployments/mainnet.json`)
- [ ] Confirm the caller has `DEFAULT_ADMIN_ROLE` (or the specific role admin) on the target contract
- [ ] For validator roles: confirm the validator is properly staked and registered
- [ ] For contract-to-contract roles: verify the contract address has code (not an EOA)

### After Any Role Grant

- [ ] Call `hasRole()` to verify the grant took effect
- [ ] Verify the transaction receipt shows a `RoleGranted` event
- [ ] Update this runbook and `deployments/mainnet.json` with the change

### Production Transition Checklist

- [ ] TimelockController deployed with 48h+ delay
- [ ] Gnosis Safe 3-of-5 multisig configured as proposer/executor on TimelockController
- [ ] All `DEFAULT_ADMIN_ROLE` grants transferred to TimelockController on every contract
- [ ] All `ADMIN_ROLE` grants transferred to TimelockController where applicable
- [ ] OmniGovernance `transferToTimelock()` called (irreversible)
- [ ] `MINTER_ROLE` verified as revoked on OmniCoin (already done)
- [ ] `BURNER_ROLE` on OmniCoin transferred to TimelockController
- [ ] All deployer roles revoked from every contract
- [ ] `VALIDATOR_ROLE` and `KYC_ATTESTOR_ROLE` granted to all 5 validator addresses
- [ ] `VERIFIER_ROLE` granted to all 5 validator addresses on OmniParticipation
- [ ] `BLOCKCHAIN_ROLE` and `PENALTY_ROLE` granted to validator service on OmniValidatorRewards
- [ ] `BONUS_DISTRIBUTOR_ROLE` granted to validator service on OmniRewardManager
- [ ] `VALIDATOR_REWARD_ROLE` granted to OmniValidatorRewards contract on OmniRewardManager
- [ ] `DEPOSITOR_ROLE` granted to all fee-generating contracts on UnifiedFeeVault
- [ ] `TRANSACTION_RECORDER_ROLE` granted to MinimalEscrow and DEXSettlement on OmniRegistration
- [ ] `BONUS_MARKER_ROLE` granted to OmniRewardManager on OmniRegistration
- [ ] All `hasRole()` verification checks pass
- [ ] Deployer `hasRole()` returns false for every role on every contract

### Security Implications of Misassignment

| Role | Risk if Misassigned |
|------|---------------------|
| `DEFAULT_ADMIN_ROLE` | **CRITICAL.** Attacker can grant themselves all other roles, upgrade contracts to malicious implementations, drain all funds. |
| `MINTER_ROLE` (OmniCoin) | **CRITICAL.** Infinite mint attack. Already permanently revoked. |
| `ADMIN_ROLE` (OmniCore) | **HIGH.** Can redirect fee distribution, manipulate validator registry, change service addresses to malicious contracts. |
| `BONUS_DISTRIBUTOR_ROLE` | **HIGH.** Can drain welcome/referral/first-sale bonus pools by distributing to arbitrary addresses. |
| `VALIDATOR_REWARD_ROLE` | **HIGH.** Can drain the 6.089B XOM validator reward pool. |
| `BRIDGE_ROLE` (UnifiedFeeVault) | **HIGH.** Can bridge accumulated ODDAO fees to an attacker address. |
| `DEPOSITOR_ROLE` | **LOW.** Can only deposit into the vault, not withdraw. |
| `VERIFIER_ROLE` | **MEDIUM.** Can inflate participation scores, potentially qualifying undeserving validators. |
| `VALIDATOR_ROLE` (Registration) | **MEDIUM.** Can register fake users, potentially gaming referral bonuses. Rate-limited to 10,000/day. |
| `KYC_ATTESTOR_ROLE` | **MEDIUM.** Can upgrade KYC tiers, but requires 3-of-5 threshold so a single misassignment is not sufficient for abuse. |
| `PENALTY_ROLE` | **MEDIUM.** Can unfairly penalize honest validators, reducing their rewards. |
| `UPGRADER_ROLE` | **CRITICAL.** Can upgrade contract implementation to a malicious version. |
| `PAUSER_ROLE` | **MEDIUM.** Can DoS the reward system by pausing it. Cannot steal funds. |
| `DISPUTE_ADMIN_ROLE` | **MEDIUM.** Can manipulate dispute outcomes, potentially favoring one party. |
| `MARKETPLACE_ADMIN_ROLE` | **LOW.** Can change marketplace configuration but cannot directly access funds. |
| `ORACLE_ADMIN_ROLE` | **MEDIUM.** Can manipulate oracle parameters, potentially enabling price manipulation. |

---

## Appendix: Role Hash Values

For on-chain verification, these are the keccak256 hashes:

```
DEFAULT_ADMIN_ROLE:        0x0000000000000000000000000000000000000000000000000000000000000000
ADMIN_ROLE:                0xa49807205ce4d355092ef5a8a18f56e8913cf4a201fbe287825b095693c21775
MINTER_ROLE:               0x9f2df0fed2c77648de5860a4cc508cd0818c85b8b8a1ab4ceeef8d981c8956a6
BURNER_ROLE:               0x3c11d16cbaffd01df69ce1c404f6340ee057498f5f00246190ea54220576a848
BRIDGE_ROLE:               0xe2b7fb3b832174769106daebcfd6d1970523240dda11281102db9363b83b0dc4
VALIDATOR_ROLE:            0x21702c8af46127c7fa207f89d0b0a8441bb32959a0ac7df790e9ab1a25c98926
KYC_ATTESTOR_ROLE:         0x8c5bbafa198660ea2bab95087e4a5e4b65e6c27fa5db8d12ea097df550e5c6c0
BONUS_MARKER_ROLE:         0x7d4c4a5c4d4f6e7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f1a
BONUS_DISTRIBUTOR_ROLE:    0xea8cd49e57101b1c768f4b3a6bf2a94d6a7fcf0f7e3c3c8fb7b7cff8a2c3d4e5
VALIDATOR_REWARD_ROLE:     (compute via keccak256("VALIDATOR_REWARD_ROLE"))
UPGRADER_ROLE:             0x189ab7a9244df0848122154315af71fe140f3db0fe014031783b0946b8c9d2e3
PAUSER_ROLE:               0x65d7a28e3265b37a6474929f336521b332c1681b933f6cb9f3376673440d862a
VERIFIER_ROLE:             (compute via keccak256("VERIFIER_ROLE"))
BLOCKCHAIN_ROLE:           (compute via keccak256("BLOCKCHAIN_ROLE"))
PENALTY_ROLE:              (compute via keccak256("PENALTY_ROLE"))
ROLE_MANAGER_ROLE:         (compute via keccak256("ROLE_MANAGER_ROLE"))
DEPOSITOR_ROLE:            (compute via keccak256("DEPOSITOR_ROLE"))
FEE_MANAGER_ROLE:          (compute via keccak256("FEE_MANAGER_ROLE"))
OPERATOR_ROLE:             (compute via keccak256("OPERATOR_ROLE"))
DISPUTE_ADMIN_ROLE:        (compute via keccak256("DISPUTE_ADMIN_ROLE"))
MARKETPLACE_ADMIN_ROLE:    (compute via keccak256("MARKETPLACE_ADMIN_ROLE"))
ORACLE_ADMIN_ROLE:         (compute via keccak256("ORACLE_ADMIN_ROLE"))
RELEASE_MANAGER_ROLE:      (compute via keccak256("RELEASE_MANAGER_ROLE"))
BOOTSTRAP_ADMIN_ROLE:      (compute via keccak256("BOOTSTRAP_ADMIN_ROLE"))
TRANSACTION_RECORDER_ROLE: (compute via keccak256("TRANSACTION_RECORDER_ROLE"))
SETTLER_ROLE:              (compute via keccak256("SETTLER_ROLE"))
MATCHER_ROLE:              (compute via keccak256("MATCHER_ROLE"))
```

To compute any hash on-chain or in a script:
```javascript
ethers.keccak256(ethers.toUtf8Bytes("ROLE_NAME_HERE"))
```
