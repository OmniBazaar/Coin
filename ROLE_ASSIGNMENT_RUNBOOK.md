# Role Assignment Runbook

**Last Updated:** 2026-03-11
**Chain:** OmniBazaar Mainnet (Chain ID 88008)
**Deployer:** `0xaDAD7751DcDd2E30015C173F2c35a56e467CD9ba`
**ODDAO Treasury:** `0x664B6347a69A22b35348D42E4640CA92e1609378`

---

## Overview

Every OmniBazaar smart contract uses OpenZeppelin AccessControl (or AccessControlDefaultAdminRules for OmniCoin). Roles gate who can mint, pause, upgrade, distribute rewards, settle trades, and perform other privileged operations. Misassigning a role can result in loss of funds, bricked upgrades, or unauthorized minting.

This runbook lists every role defined across all deployed contracts, explains what each role controls, documents who should hold it, and provides verification commands.

### Role Simplification (2026-03-11)

The following roles were **eliminated** by merging into DEFAULT_ADMIN_ROLE or replacing with direct address checks:
- `FEE_MANAGER_ROLE` on UnifiedFeeVault (dead code — never used in access checks)
- `ADMIN_ROLE` on OmniBridge (merged into DEFAULT_ADMIN_ROLE)
- `ADMIN_ROLE` on OmniGovernance (merged into DEFAULT_ADMIN_ROLE)
- `ADMIN_ROLE` on PrivateDEX (merged into DEFAULT_ADMIN_ROLE)
- `ADMIN_ROLE` on PrivateDEXSettlement (merged into DEFAULT_ADMIN_ROLE)
- `MARKETPLACE_ADMIN_ROLE` on OmniMarketplace (merged into DEFAULT_ADMIN_ROLE)
- `ORACLE_ADMIN_ROLE` on OmniPriceOracle (merged into DEFAULT_ADMIN_ROLE)
- `BOOTSTRAP_ADMIN_ROLE` on Bootstrap (merged into DEFAULT_ADMIN_ROLE)
- `RELEASE_MANAGER_ROLE` on UpdateRegistry (merged into DEFAULT_ADMIN_ROLE)
- `OPERATOR_ROLE` on OmniPrivacyBridge (merged into DEFAULT_ADMIN_ROLE)
- `FEE_MANAGER_ROLE` on OmniPrivacyBridge (merged into DEFAULT_ADMIN_ROLE)
- `BONUS_MARKER_ROLE` on OmniRegistration (replaced with `omniRewardManagerAddress` state variable)
- `TRANSACTION_RECORDER_ROLE` on OmniRegistration (replaced with `authorizedRecorders` mapping)

New additions:
- `PROVISIONER_ROLE` on OmniCore (for ValidatorProvisioner contract)
- `ValidatorProvisioner.sol` contract for automated validator onboarding/offboarding
- `setXxxRoleAdmin()` functions on 6 contracts for delegating validator role admin to Provisioner

---

## Role Definitions

### OmniCoin (XOM Token)

| Role | Constant | Purpose |
|------|----------|---------|
| `DEFAULT_ADMIN_ROLE` | `0x00` | Grant/revoke all other roles. 48-hour two-step transfer via AccessControlDefaultAdminRules. |
| `MINTER_ROLE` | `keccak256("MINTER_ROLE")` | Mint new XOM tokens. **PERMANENTLY REVOKED** after genesis funding. |
| `BURNER_ROLE` | `keccak256("BURNER_ROLE")` | Burn XOM tokens on behalf of holders. |

**Security note:** MINTER_ROLE has been revoked from all addresses. No entity can mint new XOM. The 16.8B supply is final.

### OmniCore (Core Settlement & Registry)

| Role | Constant | Purpose |
|------|----------|---------|
| `DEFAULT_ADMIN_ROLE` | `0x00` | Grant/revoke roles, pause/unpause, authorize UUPS upgrades. |
| `ADMIN_ROLE` | `keccak256("ADMIN_ROLE")` | Set service addresses, manage validator registry, set ODDAO/staking addresses, configure multi-sig thresholds. Uses two-step transfer with 48h delay (`proposeAdminTransfer`/`acceptAdminTransfer`). |
| `AVALANCHE_VALIDATOR_ROLE` | `keccak256("AVALANCHE_VALIDATOR_ROLE")` | Submit settlement batches, submit master root hashes, sign multi-validator transactions. Granted/revoked via `setValidator()` or `provisionValidator()`/`deprovisionValidator()`. |
| `PROVISIONER_ROLE` | `keccak256("PROVISIONER_ROLE")` | Provision/deprovision validators via `provisionValidator()`/`deprovisionValidator()`. Held by ValidatorProvisioner contract. |

### OmniRegistration (User Registration & KYC)

| Role | Constant | Purpose |
|------|----------|---------|
| `DEFAULT_ADMIN_ROLE` | `0x00` | Grant/revoke roles, manage KYC providers, set verification key, admin unregister users, authorize UUPS upgrades, configure contract-to-contract addresses. |
| `VALIDATOR_ROLE` | `keccak256("VALIDATOR_ROLE")` | Register new users on-chain, process registrations submitted by users. Admin can be delegated to PROVISIONER_ROLE via `setValidatorRoleAdmin()`. |
| `KYC_ATTESTOR_ROLE` | `keccak256("KYC_ATTESTOR_ROLE")` | Attest KYC tier upgrades for users. Requires 3-of-5 attestation threshold for each upgrade. Admin can be delegated via `setValidatorRoleAdmin()`. |

**Contract-to-contract authorization (no longer AccessControl roles):**

| Authorization | Setter Function | Purpose |
|---------------|-----------------|---------|
| `omniRewardManagerAddress` | `setOmniRewardManagerAddress(address)` | Mark welcome bonus and first sale bonus as claimed. Set to OmniRewardManager contract address. |
| `authorizedRecorders` mapping | `setAuthorizedRecorder(address, bool)` | Record marketplace/DEX transactions for KYC volume tracking. Mark first sale completed. Set for MinimalEscrow and DEXSettlement. |

### OmniRewardManager (Bonus Distribution)

| Role | Constant | Purpose |
|------|----------|---------|
| `DEFAULT_ADMIN_ROLE` | `0x00` | Grant/revoke roles, set registration contract, set ODDAO address, authorize UUPS upgrades, pause/unpause. |
| `BONUS_DISTRIBUTOR_ROLE` | `keccak256("BONUS_DISTRIBUTOR_ROLE")` | Distribute welcome, referral, and first sale bonuses to users. |
| `UPGRADER_ROLE` | `keccak256("UPGRADER_ROLE")` | Authorize UUPS implementation upgrades. |
| `PAUSER_ROLE` | `keccak256("PAUSER_ROLE")` | Emergency pause of all bonus distribution. |

### OmniValidatorRewards (Block Reward Distribution)

| Role | Constant | Purpose |
|------|----------|---------|
| `DEFAULT_ADMIN_ROLE` | `0x00` | Grant/revoke roles, set contract references, authorize UUPS upgrades, propose/apply/cancel contract updates. |
| `BLOCKCHAIN_ROLE` | `keccak256("BLOCKCHAIN_ROLE")` | Record block production for reward calculation. Admin can be delegated to PROVISIONER_ROLE via `setBlockchainRoleAdmin()`. |
| `PENALTY_ROLE` | `keccak256("PENALTY_ROLE")` | Apply reward penalties to misbehaving validators. |
| `ROLE_MANAGER_ROLE` | `keccak256("ROLE_MANAGER_ROLE")` | Set gateway/service-node role multipliers for reward distribution. |

### OmniParticipation (100-Point Scoring)

| Role | Constant | Purpose |
|------|----------|---------|
| `DEFAULT_ADMIN_ROLE` | `0x00` | Grant/revoke roles, set contract references, ossify contract, authorize UUPS upgrades. |
| `VERIFIER_ROLE` | `keccak256("VERIFIER_ROLE")` | Verify and submit participation score claims on behalf of users. Admin can be delegated to PROVISIONER_ROLE via `setVerifierRoleAdmin()`. |

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

### OmniBridge (Cross-Chain Bridge)

| Role | Constant | Purpose |
|------|----------|---------|
| `DEFAULT_ADMIN_ROLE` | `0x00` | Grant/revoke roles, set fee vault, configure bridge parameters, manage supported chains, ossify contract, authorize UUPS upgrades. |

### OmniPrivacyBridge (XOM/pXOM Privacy Bridge)

| Role | Constant | Purpose |
|------|----------|---------|
| `DEFAULT_ADMIN_ROLE` | `0x00` | Grant/revoke roles, set limits, pause/unpause, withdraw fees, ossify contract, emergency token rescue, authorize UUPS upgrades. |

### OmniGovernance (DAO Governance)

| Role | Constant | Purpose |
|------|----------|---------|
| `DEFAULT_ADMIN_ROLE` | `0x00` | Grant/revoke roles, configure governance parameters, ossify contract, authorize UUPS upgrades. `transferAdminToTimelock()` permanently transfers DEFAULT_ADMIN_ROLE to a timelock. |

### OmniArbitration (Dispute Resolution)

| Role | Constant | Purpose |
|------|----------|---------|
| `DEFAULT_ADMIN_ROLE` | `0x00` | Grant/revoke roles, set contract references, set treasury addresses, configure stakes, schedule upgrades. |
| `DISPUTE_ADMIN_ROLE` | `keccak256("DISPUTE_ADMIN_ROLE")` | Manage dispute lifecycle, assign arbitrators, override dispute outcomes in emergencies. |

### OmniMarketplace (On-Chain Marketplace Settlements)

| Role | Constant | Purpose |
|------|----------|---------|
| `DEFAULT_ADMIN_ROLE` | `0x00` | Grant/revoke roles, pause/unpause, configure marketplace parameters, manage listing rules, schedule/cancel/authorize UUPS upgrades. |

### OmniPriceOracle

| Role | Constant | Purpose |
|------|----------|---------|
| `DEFAULT_ADMIN_ROLE` | `0x00` | Grant/revoke roles, set OmniCore reference, pause/unpause, configure oracle parameters, schedule/cancel UUPS upgrades. |

### UpdateRegistry (Software Version Management)

| Role | Constant | Purpose |
|------|----------|---------|
| `DEFAULT_ADMIN_ROLE` | `0x00` | Grant/revoke roles, submit new software releases (with valid ODDAO signatures). |

### Bootstrap (Network Bootstrap Registry)

| Role | Constant | Purpose |
|------|----------|---------|
| `DEFAULT_ADMIN_ROLE` | `0x00` | Grant/revoke roles, emergency node management in bootstrap registry. |

### OmniTreasury (Protocol Treasury)

| Role | Constant | Purpose |
|------|----------|---------|
| `DEFAULT_ADMIN_ROLE` | `0x00` | Grant/revoke roles. |
| `GOVERNANCE_ROLE` | `keccak256("GOVERNANCE_ROLE")` | Transfer tokens from treasury, set daily/per-tx limits, manage allowlists, approve token types. Designed for TimelockController. |
| `GUARDIAN_ROLE` | `keccak256("GUARDIAN_ROLE")` | Emergency pause of all treasury operations. Designed for EmergencyGuardian multi-sig. |

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
| `DEFAULT_ADMIN_ROLE` | `0x00` | Grant/revoke roles, pause/unpause, grant/revoke MATCHER_ROLE, ossify contract, authorize UUPS upgrades. |
| `MATCHER_ROLE` | `keccak256("MATCHER_ROLE")` | Match privacy-preserving DEX orders. Admin can be delegated to PROVISIONER_ROLE via `setMatcherRoleAdmin()`. |

### PrivateDEXSettlement (Privacy DEX Settlement -- COTI Network)

| Role | Constant | Purpose |
|------|----------|---------|
| `DEFAULT_ADMIN_ROLE` | `0x00` | Grant/revoke roles, pause/unpause, update fee recipients, grant/revoke SETTLER_ROLE, ossify contract, authorize UUPS upgrades. |
| `SETTLER_ROLE` | `keccak256("SETTLER_ROLE")` | Execute privacy trade settlements. Held by validator nodes. Admin can be delegated to PROVISIONER_ROLE via `setSettlerRoleAdmin()`. |

### ValidatorProvisioner (Automated Validator Onboarding)

| Auth | Type | Purpose |
|------|------|---------|
| `owner` | Ownable2Step | Set thresholds, update contract references, force provision/deprovision validators, authorize UUPS upgrades. |
| permissionless | — | `provisionValidator(addr)` if all qualifications met; `deprovisionValidator(addr)` if any qualification lapsed. |

**Qualification requirements (configurable):**
- Participation score >= 50 (from OmniParticipation)
- KYC tier >= 4 (from OmniRegistration)
- Active stake >= 1,000,000 XOM (from OmniCore)

### OmniSybilGuard (INACTIVE — available for reactivation)

| Role | Constant | Purpose |
|------|----------|---------|
| `DEVICE_REGISTRAR_ROLE` | `keccak256("DEVICE_REGISTRAR_ROLE")` | Device fingerprint registration. |
| `JUDGE_ROLE` | `keccak256("JUDGE_ROLE")` | Sybil report adjudication. |

**Note:** OmniSybilGuard is not deployed but the code is available for future reactivation if needed.

### Ownable/Ownable2Step Contracts

These contracts use OpenZeppelin `Ownable` or `Ownable2Step` instead of AccessControl:

| Contract | Ownership Model | Owner Controls |
|----------|-----------------|----------------|
| DEXSettlement | Ownable2Step | Fee recipients, pause/unpause, ossify, UUPS upgrades |
| OmniSwapRouter | Ownable2Step | Add/remove liquidity sources, set fee vault, pause/unpause |
| OmniFeeRouter | Ownable2Step | Set fee collector address, configure routing |
| FeeSwapAdapter | Ownable2Step | Set swap router, configure paths |
| OmniChatFee | Ownable2Step | Set fee parameters, tier pricing |
| OmniENS | Ownable2Step | Set fee parameters, manage TLDs |
| OmniBonding | Ownable2Step | Set curve parameters, configure vesting |
| LiquidityMining | Ownable2Step | Set reward rates, configure pools |
| OmniNFTFactory | Ownable2Step | Set platform fee, manage collections |
| OmniNFTStaking | Ownable2Step | Set reward rates |
| OmniNFTLending | Ownable2Step | Configure lending parameters |
| OmniFractionalNFT | Ownable2Step | Configure fractionalization |
| OmniPredictionRouter | Ownable2Step | Set fee parameters |
| ValidatorProvisioner | Ownable2Step | Set thresholds, contracts, force provision/deprovision |
| MinimalEscrow | Ownable | Set fee vault, pause/unpause, emergency token rescue |
| LegacyBalanceClaim | Ownable | Emergency token rescue |

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
| ValidatorProvisioner | (deploy pending) |
| OmniTreasury | (deploy pending) |

---

## Pioneer Phase Assignments (Current State)

During the Pioneer Phase, the deployer (`0xaDAD...9ba`) holds all admin and operational roles. This is intentional for rapid iteration.

### AccessControl Contracts

| Contract | Role | Current Holder |
|----------|------|----------------|
| **OmniCoin** | DEFAULT_ADMIN_ROLE | Deployer |
| | MINTER_ROLE | **REVOKED from all** |
| | BURNER_ROLE | Deployer |
| **OmniCore** | DEFAULT_ADMIN_ROLE | Deployer |
| | ADMIN_ROLE | Deployer |
| | AVALANCHE_VALIDATOR_ROLE | Deployer + registered validators |
| | PROVISIONER_ROLE | ValidatorProvisioner contract (after deployment) |
| **OmniRegistration** | DEFAULT_ADMIN_ROLE | Deployer |
| | VALIDATOR_ROLE | Deployer (+ validator nodes via Provisioner) |
| | KYC_ATTESTOR_ROLE | Deployer (+ validator nodes via Provisioner) |
| | `omniRewardManagerAddress` | OmniRewardManager contract address |
| | `authorizedRecorders` | MinimalEscrow, DEXSettlement |
| **OmniRewardManager** | DEFAULT_ADMIN_ROLE | Deployer |
| | BONUS_DISTRIBUTOR_ROLE | Deployer / validator service |
| | UPGRADER_ROLE | Deployer |
| | PAUSER_ROLE | Deployer |
| **OmniValidatorRewards** | DEFAULT_ADMIN_ROLE | Deployer |
| | BLOCKCHAIN_ROLE | Deployer (+ validators via Provisioner) |
| | PENALTY_ROLE | Deployer |
| | ROLE_MANAGER_ROLE | Deployer |
| **OmniParticipation** | DEFAULT_ADMIN_ROLE | Deployer |
| | VERIFIER_ROLE | Deployer (+ validators via Provisioner) |
| **StakingRewardPool** | DEFAULT_ADMIN_ROLE | Deployer |
| | ADMIN_ROLE | Deployer |
| **UnifiedFeeVault** | DEFAULT_ADMIN_ROLE | Deployer |
| | ADMIN_ROLE | Deployer |
| | BRIDGE_ROLE | Deployer |
| | DEPOSITOR_ROLE | (needs granting to fee-generating contracts) |
| **OmniGovernance** | DEFAULT_ADMIN_ROLE | Deployer |
| **OmniArbitration** | DEFAULT_ADMIN_ROLE | Deployer |
| | DISPUTE_ADMIN_ROLE | Deployer |
| **OmniMarketplace** | DEFAULT_ADMIN_ROLE | Deployer |
| **OmniPriceOracle** | DEFAULT_ADMIN_ROLE | Deployer |
| **OmniBridge** | DEFAULT_ADMIN_ROLE | Deployer |
| **OmniPrivacyBridge** | DEFAULT_ADMIN_ROLE | Deployer |
| **OmniTreasury** | DEFAULT_ADMIN_ROLE | Deployer |
| | GOVERNANCE_ROLE | Deployer (→ TimelockController in production) |
| | GUARDIAN_ROLE | Deployer (→ EmergencyGuardian in production) |
| **PrivateDEX** | DEFAULT_ADMIN_ROLE | Deployer |
| | MATCHER_ROLE | Validators (via Provisioner) |
| **PrivateDEXSettlement** | DEFAULT_ADMIN_ROLE | Deployer |
| | SETTLER_ROLE | Validators (via Provisioner) |

### Ownable/Ownable2Step Contracts

| Contract | Owner |
|----------|-------|
| DEXSettlement | Deployer |
| OmniSwapRouter | Deployer |
| OmniFeeRouter | Deployer |
| FeeSwapAdapter | Deployer |
| OmniChatFee | Deployer |
| OmniENS | Deployer |
| OmniBonding | Deployer |
| LiquidityMining | Deployer |
| OmniNFTFactory | Deployer |
| OmniNFTStaking | Deployer |
| OmniNFTLending | Deployer |
| OmniFractionalNFT | Deployer |
| OmniPredictionRouter | Deployer |
| ValidatorProvisioner | Deployer |
| MinimalEscrow | Deployer |
| LegacyBalanceClaim | Deployer |

### Pioneer Phase Role Granting Script

```bash
# Grant roles to validators and inter-contract roles
npx hardhat run scripts/grant-roles.ts --network mainnet

# Grant BRIDGE_ROLE on UnifiedFeeVault
npx hardhat run scripts/grant-bridge-role.js --network mainnet

# Deploy and activate ValidatorProvisioner
npx hardhat run scripts/deploy-validator-provisioner.ts --network mainnet
```

The `grant-roles.ts` script grants:
- `VALIDATOR_ROLE` and `KYC_ATTESTOR_ROLE` on OmniRegistration (to validator addresses)
- `PENALTY_ROLE` on OmniValidatorRewards (to validator addresses)
- `VERIFIER_ROLE` on OmniParticipation (to validator addresses)

After ValidatorProvisioner deployment, the admin must:
1. Call `setValidatorRoleAdmin(PROVISIONER_ROLE)` on OmniRegistration
2. Call `setVerifierRoleAdmin(PROVISIONER_ROLE)` on OmniParticipation
3. Call `setBlockchainRoleAdmin(PROVISIONER_ROLE)` on OmniValidatorRewards
4. Grant `PROVISIONER_ROLE` to ValidatorProvisioner on OmniCore
5. Grant `PROVISIONER_ROLE` to ValidatorProvisioner on OmniRegistration, OmniParticipation, OmniValidatorRewards
6. Optionally: call `setMatcherRoleAdmin(PROVISIONER_ROLE)` on PrivateDEX and `setSettlerRoleAdmin(PROVISIONER_ROLE)` on PrivateDEXSettlement

---

## Production Phase Assignments (Target State)

In production, all admin roles transfer to a TimelockController (48h+ delay) controlled by a 3-of-5 Gnosis Safe multisig. Operational roles go to purpose-specific addresses. Validator roles are managed by ValidatorProvisioner (permissionless qualification-based).

| Contract | Role | Production Holder |
|----------|------|-------------------|
| **OmniCoin** | DEFAULT_ADMIN_ROLE | TimelockController (48h built-in delay via AccessControlDefaultAdminRules) |
| | MINTER_ROLE | **PERMANENTLY REVOKED** |
| | BURNER_ROLE | TimelockController |
| **OmniCore** | DEFAULT_ADMIN_ROLE | TimelockController |
| | ADMIN_ROLE | TimelockController |
| | AVALANCHE_VALIDATOR_ROLE | Active validator addresses (managed by ValidatorProvisioner) |
| | PROVISIONER_ROLE | ValidatorProvisioner contract |
| **OmniRegistration** | DEFAULT_ADMIN_ROLE | TimelockController |
| | VALIDATOR_ROLE | Validators (managed by ValidatorProvisioner) |
| | KYC_ATTESTOR_ROLE | Validators (managed by ValidatorProvisioner) |
| | `omniRewardManagerAddress` | OmniRewardManager contract address |
| | `authorizedRecorders` | MinimalEscrow, DEXSettlement, OmniMarketplace |
| **OmniRewardManager** | DEFAULT_ADMIN_ROLE | TimelockController |
| | BONUS_DISTRIBUTOR_ROLE | Validator service account (dedicated EOA) |
| | UPGRADER_ROLE | TimelockController |
| | PAUSER_ROLE | EmergencyGuardian |
| **OmniValidatorRewards** | DEFAULT_ADMIN_ROLE | TimelockController |
| | BLOCKCHAIN_ROLE | Validators (managed by ValidatorProvisioner) |
| | PENALTY_ROLE | Governance-controlled penalty executor |
| | ROLE_MANAGER_ROLE | TimelockController |
| **OmniParticipation** | DEFAULT_ADMIN_ROLE | TimelockController |
| | VERIFIER_ROLE | Validators (managed by ValidatorProvisioner) |
| **StakingRewardPool** | DEFAULT_ADMIN_ROLE | TimelockController |
| | ADMIN_ROLE | TimelockController |
| **UnifiedFeeVault** | DEFAULT_ADMIN_ROLE | TimelockController |
| | ADMIN_ROLE | TimelockController |
| | DEPOSITOR_ROLE | OmniMarketplace, DEXSettlement, OmniChatFee, OmniENS, MinimalEscrow, OmniArbitration, OmniSwapRouter |
| | BRIDGE_ROLE | Dedicated bridge operator EOA |
| **OmniGovernance** | DEFAULT_ADMIN_ROLE | TimelockController (via `transferAdminToTimelock()`) |
| **OmniArbitration** | DEFAULT_ADMIN_ROLE | TimelockController |
| | DISPUTE_ADMIN_ROLE | Dedicated dispute management service |
| **OmniMarketplace** | DEFAULT_ADMIN_ROLE | TimelockController |
| **OmniPriceOracle** | DEFAULT_ADMIN_ROLE | TimelockController |
| **OmniBridge** | DEFAULT_ADMIN_ROLE | TimelockController |
| **OmniPrivacyBridge** | DEFAULT_ADMIN_ROLE | TimelockController |
| **OmniTreasury** | DEFAULT_ADMIN_ROLE | TimelockController |
| | GOVERNANCE_ROLE | TimelockController |
| | GUARDIAN_ROLE | EmergencyGuardian |
| **PrivateDEX** | DEFAULT_ADMIN_ROLE | TimelockController |
| | MATCHER_ROLE | Validators (managed by ValidatorProvisioner) |
| **PrivateDEXSettlement** | DEFAULT_ADMIN_ROLE | TimelockController |
| | SETTLER_ROLE | Validators (managed by ValidatorProvisioner) |
| **ValidatorProvisioner** | owner | TimelockController |

### Ownable/Ownable2Step Production Owners

All Ownable/Ownable2Step contracts transfer ownership to TimelockController:

| Contract | Production Owner |
|----------|-----------------|
| DEXSettlement | TimelockController |
| OmniSwapRouter | TimelockController |
| OmniFeeRouter | TimelockController |
| FeeSwapAdapter | TimelockController |
| OmniChatFee | TimelockController |
| OmniENS | TimelockController |
| OmniBonding | TimelockController |
| LiquidityMining | TimelockController |
| OmniNFTFactory | TimelockController |
| ValidatorProvisioner | TimelockController |
| MinimalEscrow | TimelockController |
| LegacyBalanceClaim | TimelockController |

### Production Transition Steps

1. Deploy `OmniTimelockController` with 48h minimum delay and 3-of-5 Gnosis Safe as proposer/executor.
2. Deploy `EmergencyGuardian` with 5+ guardian addresses.
3. For each AccessControl contract: grant `DEFAULT_ADMIN_ROLE` to the TimelockController.
4. For each AccessControl contract: grant remaining admin roles to TimelockController where applicable.
5. Grant operational roles to purpose-specific addresses (contracts, service accounts).
6. For Ownable2Step contracts: call `transferOwnership(timelock)`, then timelock calls `acceptOwnership()`.
7. For OmniGovernance: call `transferAdminToTimelock(timelockAddress)` (irreversible).
8. Revoke all roles from deployer EOA.
9. Verify all assignments (see Verification Commands below).

---

## Verification Commands

Use these commands via `npx hardhat console --network mainnet` or a script to verify role assignments.

### Check if an address has a role

```javascript
const contract = await ethers.getContractAt("OmniCore", "0xc2468BA2F42b5ea9095B43E68F39c366730B84B4");

// DEFAULT_ADMIN_ROLE is always bytes32(0)
const DEFAULT_ADMIN = ethers.ZeroHash;

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

### Verify OmniRegistration contract-to-contract authorization

```javascript
const reg = await ethers.getContractAt("OmniRegistration", "0x7C3C3081128A71817d6450467cD143549Bfc0405");

// Check omniRewardManagerAddress (replaces BONUS_MARKER_ROLE)
const rewardManager = await reg.omniRewardManagerAddress();
console.log("OmniRewardManager address:", rewardManager);

// Check authorizedRecorders (replaces TRANSACTION_RECORDER_ROLE)
const escrowAddr = "0x9338B9eF1291b0266D28E520797eD57020A84D3B";
const isRecorder = await reg.authorizedRecorders(escrowAddr);
console.log("MinimalEscrow is authorized recorder:", isRecorder);
```

### Verify ValidatorProvisioner setup

```javascript
const provisioner = await ethers.getContractAt("ValidatorProvisioner", provisionerAddress);
console.log("Min score:", await provisioner.minParticipationScore());
console.log("Min KYC tier:", await provisioner.minKYCTier());
console.log("Min stake:", ethers.formatEther(await provisioner.minStakeAmount()));
console.log("Provisioned count:", await provisioner.provisionedCount());
```

### Verify role admin delegation (after setXxxRoleAdmin calls)

```javascript
const reg = await ethers.getContractAt("OmniRegistration", regAddress);
const VALIDATOR_ROLE = await reg.VALIDATOR_ROLE();
const PROVISIONER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("PROVISIONER_ROLE"));

// Should return PROVISIONER_ROLE after setValidatorRoleAdmin() is called
const roleAdmin = await reg.getRoleAdmin(VALIDATOR_ROLE);
console.log("Admin of VALIDATOR_ROLE:", roleAdmin);
console.log("Is PROVISIONER_ROLE:", roleAdmin === PROVISIONER_ROLE);
```

### Batch verification script

```bash
npx hardhat run scripts/grant-roles.ts --network mainnet
# The script includes a verification section that checks all role assignments
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
- [ ] EmergencyGuardian deployed with 5+ guardians
- [ ] Gnosis Safe 3-of-5 multisig configured as proposer on TimelockController
- [ ] All `DEFAULT_ADMIN_ROLE` grants transferred to TimelockController on every contract
- [ ] All `ADMIN_ROLE` grants (OmniCore, StakingRewardPool, UnifiedFeeVault) transferred to TimelockController
- [ ] OmniGovernance `transferAdminToTimelock()` called (irreversible)
- [ ] `MINTER_ROLE` verified as revoked on OmniCoin (already done)
- [ ] `BURNER_ROLE` on OmniCoin transferred to TimelockController
- [ ] ValidatorProvisioner deployed and activated
- [ ] `setValidatorRoleAdmin()` called on OmniRegistration (VALIDATOR_ROLE + KYC_ATTESTOR_ROLE)
- [ ] `setVerifierRoleAdmin()` called on OmniParticipation
- [ ] `setBlockchainRoleAdmin()` called on OmniValidatorRewards
- [ ] `PROVISIONER_ROLE` granted to ValidatorProvisioner on OmniCore and target contracts
- [ ] Seed validators force-provisioned via ValidatorProvisioner
- [ ] `OmniRegistration.setOmniRewardManagerAddress()` called with OmniRewardManager address
- [ ] `OmniRegistration.setAuthorizedRecorder()` called for MinimalEscrow and DEXSettlement
- [ ] `DEPOSITOR_ROLE` granted to all fee-generating contracts on UnifiedFeeVault
- [ ] `BONUS_DISTRIBUTOR_ROLE` granted to validator service on OmniRewardManager
- [ ] `PAUSER_ROLE` on OmniRewardManager granted to EmergencyGuardian
- [ ] OmniTreasury: `GOVERNANCE_ROLE` to TimelockController, `GUARDIAN_ROLE` to EmergencyGuardian
- [ ] All Ownable/Ownable2Step contracts: ownership transferred to TimelockController
- [ ] All deployer roles revoked from every contract
- [ ] All `hasRole()` verification checks pass
- [ ] Deployer `hasRole()` returns false for every role on every contract

### Security Implications of Misassignment

| Role | Risk if Misassigned |
|------|---------------------|
| `DEFAULT_ADMIN_ROLE` | **CRITICAL.** Attacker can grant themselves all other roles, upgrade contracts to malicious implementations, drain all funds. |
| `MINTER_ROLE` (OmniCoin) | **CRITICAL.** Infinite mint attack. Already permanently revoked. |
| `ADMIN_ROLE` (OmniCore) | **HIGH.** Can redirect fee distribution, manipulate validator registry, change service addresses to malicious contracts. |
| `PROVISIONER_ROLE` | **HIGH.** Can add/remove validators from all contracts atomically. Mitigated by on-chain qualification checks in ValidatorProvisioner. |
| `BONUS_DISTRIBUTOR_ROLE` | **HIGH.** Can drain welcome/referral/first-sale bonus pools by distributing to arbitrary addresses. |
| `BRIDGE_ROLE` (UnifiedFeeVault) | **HIGH.** Can bridge accumulated ODDAO fees to an attacker address. |
| `GOVERNANCE_ROLE` (Treasury) | **HIGH.** Can transfer funds from protocol treasury. |
| `DEPOSITOR_ROLE` | **LOW.** Can only deposit into the vault, not withdraw. |
| `VERIFIER_ROLE` | **MEDIUM.** Can inflate participation scores, potentially qualifying undeserving validators. Rate-limited to 50/day per verifier, 200/day global. |
| `VALIDATOR_ROLE` (Registration) | **MEDIUM.** Can register fake users, potentially gaming referral bonuses. Rate-limited to 10,000/day. |
| `KYC_ATTESTOR_ROLE` | **MEDIUM.** Can upgrade KYC tiers, but requires 3-of-5 threshold so a single misassignment is not sufficient for abuse. |
| `PENALTY_ROLE` | **MEDIUM.** Can unfairly penalize honest validators, reducing their rewards. |
| `UPGRADER_ROLE` | **CRITICAL.** Can upgrade contract implementation to a malicious version. |
| `PAUSER_ROLE` | **MEDIUM.** Can DoS the reward system by pausing it. Cannot steal funds. |
| `GUARDIAN_ROLE` (Treasury) | **MEDIUM.** Can pause treasury operations. Cannot steal funds. |
| `DISPUTE_ADMIN_ROLE` | **MEDIUM.** Can manipulate dispute outcomes, potentially favoring one party. |

---

## Appendix: Role Hash Values

For on-chain verification, these are the keccak256 hashes of active roles:

```
DEFAULT_ADMIN_ROLE:        0x0000000000000000000000000000000000000000000000000000000000000000
ADMIN_ROLE:                0xa49807205ce4d355092ef5a8a18f56e8913cf4a201fbe287825b095693c21775
MINTER_ROLE:               0x9f2df0fed2c77648de5860a4cc508cd0818c85b8b8a1ab4ceeef8d981c8956a6
BURNER_ROLE:               0x3c11d16cbaffd01df69ce1c404f6340ee057498f5f00246190ea54220576a848
BRIDGE_ROLE:               0xe2b7fb3b832174769106daebcfd6d1970523240dda11281102db9363b83b0dc4
VALIDATOR_ROLE:            0x21702c8af46127c7fa207f89d0b0a8441bb32959a0ac7df790e9ab1a25c98926
KYC_ATTESTOR_ROLE:         0x8c5bbafa198660ea2bab95087e4a5e4b65e6c27fa5db8d12ea097df550e5c6c0
AVALANCHE_VALIDATOR_ROLE:  (compute via keccak256("AVALANCHE_VALIDATOR_ROLE"))
PROVISIONER_ROLE:          (compute via keccak256("PROVISIONER_ROLE"))
BONUS_DISTRIBUTOR_ROLE:    (compute via keccak256("BONUS_DISTRIBUTOR_ROLE"))
UPGRADER_ROLE:             0x189ab7a9244df0848122154315af71fe140f3db0fe014031783b0946b8c9d2e3
PAUSER_ROLE:               0x65d7a28e3265b37a6474929f336521b332c1681b933f6cb9f3376673440d862a
VERIFIER_ROLE:             (compute via keccak256("VERIFIER_ROLE"))
BLOCKCHAIN_ROLE:           (compute via keccak256("BLOCKCHAIN_ROLE"))
PENALTY_ROLE:              (compute via keccak256("PENALTY_ROLE"))
ROLE_MANAGER_ROLE:         (compute via keccak256("ROLE_MANAGER_ROLE"))
DEPOSITOR_ROLE:            (compute via keccak256("DEPOSITOR_ROLE"))
GOVERNANCE_ROLE:           (compute via keccak256("GOVERNANCE_ROLE"))
GUARDIAN_ROLE:             (compute via keccak256("GUARDIAN_ROLE"))
DISPUTE_ADMIN_ROLE:        (compute via keccak256("DISPUTE_ADMIN_ROLE"))
SETTLER_ROLE:              (compute via keccak256("SETTLER_ROLE"))
MATCHER_ROLE:              (compute via keccak256("MATCHER_ROLE"))
```

**Eliminated roles (no longer in any contract):**
```
BONUS_MARKER_ROLE          → replaced by omniRewardManagerAddress on OmniRegistration
TRANSACTION_RECORDER_ROLE  → replaced by authorizedRecorders mapping on OmniRegistration
FEE_MANAGER_ROLE           → removed from UnifiedFeeVault (dead code) and OmniPrivacyBridge (merged)
OPERATOR_ROLE              → removed from OmniPrivacyBridge (merged into DEFAULT_ADMIN_ROLE)
MARKETPLACE_ADMIN_ROLE     → removed from OmniMarketplace (merged into DEFAULT_ADMIN_ROLE)
ORACLE_ADMIN_ROLE          → removed from OmniPriceOracle (merged into DEFAULT_ADMIN_ROLE)
BOOTSTRAP_ADMIN_ROLE       → removed from Bootstrap (merged into DEFAULT_ADMIN_ROLE)
RELEASE_MANAGER_ROLE       → removed from UpdateRegistry (merged into DEFAULT_ADMIN_ROLE)
```

To compute any hash on-chain or in a script:
```javascript
ethers.keccak256(ethers.toUtf8Bytes("ROLE_NAME_HERE"))
```
