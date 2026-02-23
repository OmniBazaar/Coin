/**
 * @file deploy-governance-system.ts
 * @description Deployment script for the OmniBazaar governance system
 *
 * Deploys OmniTimelockController, EmergencyGuardian, and OmniGovernance
 * in the correct order, then wires up all access control roles.
 *
 * This script implements Step 9 of FIX_UUPS.md - the final deployment
 * phase of the UUPS upgradeability and governance strategy.
 *
 * Deployment order (CRITICAL — must be sequential):
 *   1. Deploy OmniTimelockController (immutable, two-tier delay)
 *   2. Deploy EmergencyGuardian (immutable, pause + cancel)
 *   3. Deploy OmniGovernance (UUPS proxy, full on-chain governance)
 *   4. Wire timelock roles (proposer, canceller, admin renounce)
 *   5. Transfer ADMIN_ROLE on GovernanceV2 to timelock
 *   6. (Optional) Transfer ADMIN_ROLE on OmniCore to timelock
 *   7. Save deployment addresses
 *
 * Usage:
 *   npx hardhat run scripts/deploy-governance-system.ts --network fuji
 *   npx hardhat run scripts/deploy-governance-system.ts --network localhost
 *
 * Environment Variables:
 *   GUARDIAN_ADDRESSES   - Comma-separated list of 5+ guardian addresses (REQUIRED for mainnet)
 *   ADMIN_ADDRESS        - Override admin address (defaults to deployer)
 *   SKIP_CORE_TRANSFER   - Set to "true" to skip OmniCore admin transfer (default: false on testnet)
 *   KEEP_DEPLOYER_PROPOSER - Set to "true" to keep deployer as proposer (Phase 1, default: true)
 *
 * Post-Deployment:
 *   - Register pausable contracts via governance proposals
 *   - Phase 2: Revoke deployer's PROPOSER_ROLE from timelock
 *   - Phase 3: Remove all team special roles
 *   - Phase 4: Evaluate contracts for ossification
 */

import { ethers, upgrades } from 'hardhat';
import * as fs from 'fs';
import * as path from 'path';

/** Result of the full governance system deployment */
interface GovernanceDeploymentResult {
    timelockAddress: string;
    guardianAddress: string;
    governorProxyAddress: string;
    governorImplAddress: string;
    omniCoinAddress: string;
    omniCoreAddress: string;
    adminAddress: string;
    guardianAddresses: string[];
    network: string;
    chainId: bigint;
    timestamp: string;
    phase: string;
}

/**
 * Load existing deployment configuration from deployments/{network}.json
 * @param network Network name (e.g., "fuji", "localhost")
 * @returns Parsed deployment config or empty object
 */
function loadDeploymentConfig(network: string): Record<string, unknown> {
    const deploymentPath = path.join(__dirname, '..', 'deployments', `${network}.json`);
    if (fs.existsSync(deploymentPath)) {
        return JSON.parse(fs.readFileSync(deploymentPath, 'utf-8'));
    }
    return {};
}

/**
 * Save governance deployment addresses into deployments/{network}.json
 * @param network Network name
 * @param result Deployment result containing all addresses
 */
function saveDeploymentConfig(
    network: string,
    result: GovernanceDeploymentResult
): void {
    const deploymentPath = path.join(__dirname, '..', 'deployments', `${network}.json`);

    const config: Record<string, unknown> = loadDeploymentConfig(network);
    const contracts = (config.contracts as Record<string, unknown>) ?? {};

    contracts.OmniTimelockController = result.timelockAddress;
    contracts.EmergencyGuardian = result.guardianAddress;
    contracts.OmniGovernance = result.governorProxyAddress;
    contracts.OmniGovernanceImplementation = result.governorImplAddress;

    config.contracts = contracts;
    config.upgradedAt = result.timestamp;

    fs.writeFileSync(deploymentPath, JSON.stringify(config, null, 2));
    console.log(`\nSaved deployment to ${deploymentPath}`);
}

/**
 * Resolve guardian addresses from environment or generate testnet defaults
 * @param signers Available hardhat signers
 * @returns Array of 5+ unique guardian addresses
 */
async function resolveGuardianAddresses(
    signers: Awaited<ReturnType<typeof ethers.getSigners>>
): Promise<string[]> {
    const envGuardians = process.env.GUARDIAN_ADDRESSES;

    if (envGuardians) {
        const addresses = envGuardians
            .split(',')
            .map(s => s.trim())
            .filter(s => s.length > 0);

        if (addresses.length < 5) {
            throw new Error(
                `GUARDIAN_ADDRESSES must contain at least 5 addresses, got ${addresses.length}`
            );
        }

        // Verify uniqueness
        const unique = new Set(addresses.map(a => a.toLowerCase()));
        if (unique.size !== addresses.length) {
            throw new Error('GUARDIAN_ADDRESSES must all be unique');
        }

        return addresses;
    }

    // Testnet default: use hardhat signers 1-5 (index 0 is deployer)
    if (signers.length < 6) {
        throw new Error(
            'Need at least 6 signers (1 deployer + 5 guardians). ' +
            'Set GUARDIAN_ADDRESSES env var or run with more hardhat accounts.'
        );
    }

    const guardians: string[] = [];
    for (let i = 1; i <= 5; i++) {
        guardians.push(await signers[i].getAddress());
    }
    console.log('  Using testnet default guardians (signers 1-5)');
    return guardians;
}

/**
 * Verify that a contract exists on-chain at the given address
 * @param address Contract address to check
 * @param label Human-readable label for error messages
 */
async function verifyContractExists(
    address: string,
    label: string
): Promise<void> {
    const code = await ethers.provider.getCode(address);
    if (code === '0x' || code === '0x0') {
        throw new Error(
            `${label} at ${address} has no deployed code. ` +
            'Deploy prerequisite contracts first.'
        );
    }
}

/**
 * Main deployment function — deploys and configures the full governance system
 */
async function main(): Promise<void> {
    console.log('================================================================');
    console.log('  OmniBazaar Governance System Deployment');
    console.log('  (OmniTimelockController + EmergencyGuardian + OmniGovernance)');
    console.log('================================================================\n');

    // =====================================================================
    // Phase 0: Environment Setup
    // =====================================================================
    const network = await ethers.provider.getNetwork();
    const networkName = network.chainId === 131313n ? 'fuji' :
        network.name === 'unknown' ? 'localhost' : network.name;
    const isTestnet = network.chainId === 31337n || network.chainId === 131313n;

    console.log(`Network: ${networkName} (chainId: ${network.chainId})`);
    console.log(`Testnet: ${isTestnet}`);

    const signers = await ethers.getSigners();
    const deployer = signers[0];
    const deployerAddress = await deployer.getAddress();
    const balance = await ethers.provider.getBalance(deployerAddress);
    console.log(`Deployer: ${deployerAddress}`);
    console.log(`Balance: ${ethers.formatEther(balance)} native tokens\n`);

    if (balance === 0n) {
        throw new Error('Deployer has zero balance — cannot pay for gas');
    }

    const adminAddress = process.env.ADMIN_ADDRESS || deployerAddress;
    const keepDeployerProposer = process.env.KEEP_DEPLOYER_PROPOSER !== 'false';
    const skipCoreTransfer = process.env.SKIP_CORE_TRANSFER === 'true';

    console.log(`Admin: ${adminAddress}`);
    console.log(`Keep deployer as proposer (Phase 1): ${keepDeployerProposer}`);
    console.log(`Skip OmniCore admin transfer: ${skipCoreTransfer}\n`);

    // =====================================================================
    // Phase 1: Load Prerequisites (OmniCoin + OmniCore)
    // =====================================================================
    console.log('--- Phase 1: Verify Prerequisites ---\n');

    const config = loadDeploymentConfig(networkName);
    const contracts = (config.contracts as Record<string, string>) ?? {};

    const omniCoinAddress = process.env.OMNICOIN_ADDRESS || contracts.OmniCoin;
    const omniCoreAddress = process.env.OMNICORE_ADDRESS || contracts.OmniCore;

    if (!omniCoinAddress) {
        throw new Error(
            'OmniCoin address not found. Deploy OmniCoin first or set OMNICOIN_ADDRESS'
        );
    }
    if (!omniCoreAddress) {
        throw new Error(
            'OmniCore address not found. Deploy OmniCore first or set OMNICORE_ADDRESS'
        );
    }

    await verifyContractExists(omniCoinAddress, 'OmniCoin');
    await verifyContractExists(omniCoreAddress, 'OmniCore');

    console.log(`  OmniCoin: ${omniCoinAddress}`);
    console.log(`  OmniCore: ${omniCoreAddress}`);
    console.log('  Both contracts verified on-chain\n');

    // =====================================================================
    // Phase 2: Deploy OmniTimelockController (Immutable)
    // =====================================================================
    console.log('--- Phase 2: Deploy OmniTimelockController ---\n');

    // Deployer starts as proposer so it can configure roles.
    // In Phase 1, deployer keeps proposer alongside governance.
    // In Phase 2 (months 6-12), deployer proposer role is revoked.
    const initialProposers = [deployerAddress];
    const initialExecutors = [ethers.ZeroAddress]; // anyone can execute

    const OmniTimelockController = await ethers.getContractFactory(
        'OmniTimelockController'
    );
    console.log('  Deploying OmniTimelockController...');
    const timelock = await OmniTimelockController.deploy(
        initialProposers,
        initialExecutors,
        adminAddress
    );
    await timelock.waitForDeployment();
    const timelockAddress = await timelock.getAddress();
    console.log(`  Deployed: ${timelockAddress}`);

    // Verify deployment
    const routineDelay = await timelock.ROUTINE_DELAY();
    const criticalDelay = await timelock.CRITICAL_DELAY();
    console.log(`  Routine delay: ${routineDelay / 3600n}h`);
    console.log(`  Critical delay: ${criticalDelay / 3600n / 24n}d`);
    console.log(`  Critical selectors: ${await timelock.criticalSelectorCount()}\n`);

    // =====================================================================
    // Phase 3: Deploy EmergencyGuardian (Immutable)
    // =====================================================================
    console.log('--- Phase 3: Deploy EmergencyGuardian ---\n');

    const guardianAddresses = await resolveGuardianAddresses(signers);
    console.log(`  Guardian addresses (${guardianAddresses.length}):`);
    for (const addr of guardianAddresses) {
        console.log(`    - ${addr}`);
    }

    const EmergencyGuardian = await ethers.getContractFactory('EmergencyGuardian');
    console.log('\n  Deploying EmergencyGuardian...');
    const guardian = await EmergencyGuardian.deploy(timelockAddress, guardianAddresses);
    await guardian.waitForDeployment();
    const guardianContractAddress = await guardian.getAddress();
    console.log(`  Deployed: ${guardianContractAddress}`);
    console.log(`  Guardian count: ${await guardian.guardianCount()}`);
    console.log(`  Cancel threshold: ${await guardian.CANCEL_THRESHOLD()}\n`);

    // =====================================================================
    // Phase 4: Deploy OmniGovernance (UUPS Proxy)
    // =====================================================================
    console.log('--- Phase 4: Deploy OmniGovernance ---\n');

    const OmniGovernance = await ethers.getContractFactory('OmniGovernance');
    console.log('  Deploying OmniGovernance proxy...');
    const governorProxy = await upgrades.deployProxy(
        OmniGovernance,
        [omniCoinAddress, omniCoreAddress, timelockAddress, adminAddress],
        { initializer: 'initialize', kind: 'uups' }
    );
    await governorProxy.waitForDeployment();
    const governorProxyAddress = await governorProxy.getAddress();
    const governorImplAddress = await upgrades.erc1967.getImplementationAddress(
        governorProxyAddress
    );
    console.log(`  Proxy: ${governorProxyAddress}`);
    console.log(`  Implementation: ${governorImplAddress}`);

    // Verify governance parameters
    const votingDelay = await governorProxy.VOTING_DELAY();
    const votingPeriod = await governorProxy.VOTING_PERIOD();
    const quorumBps = await governorProxy.QUORUM_BPS();
    const threshold = await governorProxy.PROPOSAL_THRESHOLD();
    console.log(`  Voting delay: ${votingDelay / 86400n}d`);
    console.log(`  Voting period: ${votingPeriod / 86400n}d`);
    console.log(`  Quorum: ${quorumBps / 100n}%`);
    console.log(`  Proposal threshold: ${ethers.formatEther(threshold)} XOM\n`);

    // =====================================================================
    // Phase 5: Wire Timelock Roles
    // =====================================================================
    console.log('--- Phase 5: Wire Timelock Roles ---\n');

    const PROPOSER_ROLE = await timelock.PROPOSER_ROLE();
    const CANCELLER_ROLE = await timelock.CANCELLER_ROLE();
    const TL_ADMIN_ROLE = await timelock.DEFAULT_ADMIN_ROLE();

    // 5a. Grant OmniGovernance the PROPOSER_ROLE
    console.log('  5a. Granting PROPOSER_ROLE to OmniGovernance...');
    let tx = await timelock.grantRole(PROPOSER_ROLE, governorProxyAddress);
    await tx.wait();
    console.log(`      Tx: ${tx.hash}`);

    // 5b. Grant EmergencyGuardian the CANCELLER_ROLE
    console.log('  5b. Granting CANCELLER_ROLE to EmergencyGuardian...');
    tx = await timelock.grantRole(CANCELLER_ROLE, guardianContractAddress);
    await tx.wait();
    console.log(`      Tx: ${tx.hash}`);

    // 5c. Optionally revoke deployer's PROPOSER_ROLE (Phase 2+)
    if (!keepDeployerProposer) {
        console.log('  5c. Revoking deployer PROPOSER_ROLE (Phase 2 mode)...');
        tx = await timelock.revokeRole(PROPOSER_ROLE, deployerAddress);
        await tx.wait();
        console.log(`      Tx: ${tx.hash}`);
    } else {
        console.log(
            '  5c. SKIPPED — deployer keeps PROPOSER_ROLE (Phase 1 mode)'
        );
        console.log(
            '      Revoke later via: timelock.revokeRole(PROPOSER_ROLE, deployer)'
        );
    }

    // 5d. Renounce timelock admin role so timelock becomes self-administered
    console.log('  5d. Renouncing TIMELOCK_ADMIN_ROLE from deployer...');
    tx = await timelock.renounceRole(TL_ADMIN_ROLE, deployerAddress);
    await tx.wait();
    console.log(`      Tx: ${tx.hash}\n`);

    // =====================================================================
    // Phase 6: Transfer GovernanceV2 Admin to Timelock
    // =====================================================================
    console.log('--- Phase 6: Transfer GovernanceV2 Admin to Timelock ---\n');

    const GOV_ADMIN_ROLE = await governorProxy.ADMIN_ROLE();
    const GOV_DEFAULT_ADMIN = await governorProxy.DEFAULT_ADMIN_ROLE();

    // 6a. Grant ADMIN_ROLE to timelock
    console.log('  6a. Granting ADMIN_ROLE to timelock...');
    tx = await governorProxy.grantRole(GOV_ADMIN_ROLE, timelockAddress);
    await tx.wait();
    console.log(`      Tx: ${tx.hash}`);

    // 6b. Grant DEFAULT_ADMIN_ROLE to timelock
    console.log('  6b. Granting DEFAULT_ADMIN_ROLE to timelock...');
    tx = await governorProxy.grantRole(GOV_DEFAULT_ADMIN, timelockAddress);
    await tx.wait();
    console.log(`      Tx: ${tx.hash}`);

    // 6c. Revoke deployer's ADMIN_ROLE (timelock is now the admin)
    console.log('  6c. Revoking ADMIN_ROLE from deployer...');
    tx = await governorProxy.revokeRole(GOV_ADMIN_ROLE, deployerAddress);
    await tx.wait();
    console.log(`      Tx: ${tx.hash}`);

    // 6d. Revoke deployer's DEFAULT_ADMIN_ROLE
    console.log('  6d. Revoking DEFAULT_ADMIN_ROLE from deployer...');
    tx = await governorProxy.renounceRole(GOV_DEFAULT_ADMIN, deployerAddress);
    await tx.wait();
    console.log(`      Tx: ${tx.hash}\n`);

    // =====================================================================
    // Phase 7: (Optional) Transfer OmniCore Admin to Timelock
    // =====================================================================
    if (!skipCoreTransfer) {
        console.log('--- Phase 7: Transfer OmniCore Admin to Timelock ---\n');

        const omniCore = await ethers.getContractAt('OmniCore', omniCoreAddress);
        const CORE_ADMIN_ROLE = await omniCore.ADMIN_ROLE();
        const CORE_DEFAULT_ADMIN = await omniCore.DEFAULT_ADMIN_ROLE();

        // 7a. Grant ADMIN_ROLE to timelock
        console.log('  7a. Granting ADMIN_ROLE on OmniCore to timelock...');
        tx = await omniCore.grantRole(CORE_ADMIN_ROLE, timelockAddress);
        await tx.wait();
        console.log(`      Tx: ${tx.hash}`);

        // 7b. Grant DEFAULT_ADMIN_ROLE to timelock
        console.log('  7b. Granting DEFAULT_ADMIN_ROLE on OmniCore to timelock...');
        tx = await omniCore.grantRole(CORE_DEFAULT_ADMIN, timelockAddress);
        await tx.wait();
        console.log(`      Tx: ${tx.hash}`);

        if (isTestnet) {
            console.log(
                '  7c. SKIPPED — keeping deployer admin on testnet for debugging'
            );
            console.log(
                '      Revoke in production via: omniCore.revokeRole(ADMIN_ROLE, deployer)\n'
            );
        } else {
            // Production: revoke deployer's roles
            console.log('  7c. Revoking deployer ADMIN_ROLE on OmniCore...');
            tx = await omniCore.revokeRole(CORE_ADMIN_ROLE, deployerAddress);
            await tx.wait();
            console.log(`      Tx: ${tx.hash}`);

            console.log('  7d. Renouncing deployer DEFAULT_ADMIN_ROLE on OmniCore...');
            tx = await omniCore.renounceRole(CORE_DEFAULT_ADMIN, deployerAddress);
            await tx.wait();
            console.log(`      Tx: ${tx.hash}\n`);
        }
    } else {
        console.log('--- Phase 7: SKIPPED (SKIP_CORE_TRANSFER=true) ---\n');
    }

    // =====================================================================
    // Phase 8: Save Deployment & Print Summary
    // =====================================================================
    const timestamp = new Date().toISOString();
    const phase = keepDeployerProposer ? 'Phase 1 (deployer + governance)' :
        'Phase 2 (governance only)';

    const result: GovernanceDeploymentResult = {
        timelockAddress,
        guardianAddress: guardianContractAddress,
        governorProxyAddress,
        governorImplAddress,
        omniCoinAddress,
        omniCoreAddress,
        adminAddress,
        guardianAddresses,
        network: networkName,
        chainId: network.chainId,
        timestamp,
        phase,
    };

    saveDeploymentConfig(networkName, result);

    // =====================================================================
    // Verification Summary
    // =====================================================================
    console.log('================================================================');
    console.log('  Deployment Complete — Verification Summary');
    console.log('================================================================\n');

    console.log('  Contracts Deployed:');
    console.log(`    OmniTimelockController: ${timelockAddress}`);
    console.log(`    EmergencyGuardian:      ${guardianContractAddress}`);
    console.log(`    OmniGovernance:       ${governorProxyAddress}`);
    console.log(`    GovernanceV2 Impl:      ${governorImplAddress}\n`);

    console.log('  Prerequisites (existing):');
    console.log(`    OmniCoin:               ${omniCoinAddress}`);
    console.log(`    OmniCore:               ${omniCoreAddress}\n`);

    // Role verification
    console.log('  Role Verification:');
    const govHasProposer = await timelock.hasRole(PROPOSER_ROLE, governorProxyAddress);
    const guardianHasCanceller = await timelock.hasRole(
        CANCELLER_ROLE,
        guardianContractAddress
    );
    const deployerHasProposer = await timelock.hasRole(PROPOSER_ROLE, deployerAddress);
    const timelockHasGovAdmin = await governorProxy.hasRole(
        GOV_ADMIN_ROLE,
        timelockAddress
    );

    console.log(
        `    GovernanceV2 → PROPOSER_ROLE on Timelock:  ${govHasProposer ? 'YES' : 'MISSING!'}`
    );
    console.log(
        `    Guardian → CANCELLER_ROLE on Timelock:     ${guardianHasCanceller ? 'YES' : 'MISSING!'}`
    );
    console.log(
        `    Deployer → PROPOSER_ROLE on Timelock:      ${deployerHasProposer ? 'YES (Phase 1)' : 'NO (Phase 2+)'}`
    );
    console.log(
        `    Timelock → ADMIN_ROLE on GovernanceV2:     ${timelockHasGovAdmin ? 'YES' : 'MISSING!'}`
    );

    if (!skipCoreTransfer) {
        const omniCore = await ethers.getContractAt('OmniCore', omniCoreAddress);
        const coreAdminRole = await omniCore.ADMIN_ROLE();
        const timelockHasCoreAdmin = await omniCore.hasRole(
            coreAdminRole,
            timelockAddress
        );
        console.log(
            `    Timelock → ADMIN_ROLE on OmniCore:        ${timelockHasCoreAdmin ? 'YES' : 'MISSING!'}`
        );
    }

    console.log(`\n  Phase: ${phase}`);
    console.log(`  Timestamp: ${timestamp}`);

    // Next steps
    console.log('\n  --- Post-Deployment Next Steps ---');
    console.log('  1. Register pausable contracts with EmergencyGuardian:');
    console.log('     Schedule via timelock: guardian.registerPausable(contractAddr)');
    console.log('  2. Transfer ADMIN_ROLE on remaining UUPS contracts to timelock');
    console.log('  3. Run sync-contract-addresses.sh to update all modules');
    console.log('  4. Run security audits (see FIX_UUPS.md Step 10)');

    if (keepDeployerProposer) {
        console.log('  5. Phase 2 transition: Revoke deployer PROPOSER_ROLE');
        console.log('     timelock.revokeRole(PROPOSER_ROLE, deployerAddress)');
    }

    console.log('\n================================================================\n');
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error('\nDeployment failed:', error);
        process.exit(1);
    });
