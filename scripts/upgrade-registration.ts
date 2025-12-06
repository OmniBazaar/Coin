/**
 * @file upgrade-registration.ts
 * @description Upgrade script for OmniRegistration contract (UUPS proxy pattern)
 *
 * This script upgrades an existing OmniRegistration proxy to a new implementation
 * and calls reinitialize() to set up the DOMAIN_SEPARATOR for EIP-712 attestations.
 *
 * Usage:
 *   npx hardhat run scripts/upgrade-registration.ts --network fuji
 *   npx hardhat run scripts/upgrade-registration.ts --network localhost
 *
 * Environment Variables:
 *   PRIVATE_KEY - Deployer private key (must be admin of proxy)
 *
 * Post-Upgrade:
 *   - Verify DOMAIN_SEPARATOR is set
 *   - Test selfRegister function with EIP-712 attestation
 */

import { ethers, upgrades } from 'hardhat';
import * as fs from 'fs';
import * as path from 'path';

interface DeploymentConfig {
    network: string;
    chainId: number;
    contracts: {
        OmniRegistration: string;
        OmniRegistrationImplementation: string;
        [key: string]: string;
    };
    [key: string]: unknown;
}

/**
 * Load existing deployment configuration
 * @param network - Network name
 * @returns Deployment configuration object
 */
function loadDeploymentConfig(network: string): DeploymentConfig | null {
    const deploymentPath = path.join(__dirname, '..', 'deployments', `${network}.json`);

    if (fs.existsSync(deploymentPath)) {
        const content = fs.readFileSync(deploymentPath, 'utf-8');
        return JSON.parse(content) as DeploymentConfig;
    }

    return null;
}

/**
 * Save updated deployment configuration
 * @param network - Network name
 * @param config - Updated configuration
 */
function saveDeploymentConfig(network: string, config: DeploymentConfig): void {
    const deploymentPath = path.join(__dirname, '..', 'deployments', `${network}.json`);
    fs.writeFileSync(deploymentPath, JSON.stringify(config, null, 2));
    console.log(`Saved updated deployment to ${deploymentPath}`);
}

/**
 * Main upgrade function
 */
async function main(): Promise<void> {
    console.log('========================================');
    console.log('OmniRegistration Upgrade');
    console.log('========================================\n');

    // Get network info
    const network = await ethers.provider.getNetwork();
    const networkName = network.name === 'unknown' ? 'localhost' : network.name;
    console.log(`Network: ${networkName} (chainId: ${network.chainId})`);

    // Load deployment config
    const config = loadDeploymentConfig(networkName === 'localhost' ? 'localhost' : 'fuji');
    if (!config) {
        throw new Error(`No deployment config found for network: ${networkName}`);
    }

    const proxyAddress = config.contracts?.OmniRegistration;
    if (!proxyAddress) {
        throw new Error('OmniRegistration proxy address not found in deployment config');
    }

    console.log(`Proxy address: ${proxyAddress}`);

    // Get upgrader
    const [upgrader] = await ethers.getSigners();
    const upgraderAddress = await upgrader.getAddress();
    console.log(`Upgrader: ${upgraderAddress}`);

    const balance = await ethers.provider.getBalance(upgraderAddress);
    console.log(`Balance: ${ethers.formatEther(balance)} ETH\n`);

    // Get current implementation
    const currentImpl = await upgrades.erc1967.getImplementationAddress(proxyAddress);
    console.log(`Current implementation: ${currentImpl}`);

    // Deploy new implementation and upgrade
    console.log('\n--- Upgrading OmniRegistration ---');

    const OmniRegistration = await ethers.getContractFactory('OmniRegistration');

    // Force import the proxy if not registered (handles case where contract was upgraded outside hardhat)
    try {
        await upgrades.forceImport(proxyAddress, OmniRegistration, { kind: 'uups' });
        console.log('Proxy force-imported into OpenZeppelin manifest');
    } catch (importError: unknown) {
        // If already imported, this will throw - that's OK
        const errorMessage = importError instanceof Error ? importError.message : String(importError);
        if (!errorMessage.includes('already imported') && !errorMessage.includes('already registered')) {
            console.log('Note: Proxy import skipped (may already be registered)');
        }
    }

    // Simple upgrade without reinitialize - adminUnregister doesn't need state init
    console.log('Deploying new implementation and upgrading proxy...');
    console.log('Note: Simple upgrade without reinitialize (adminUnregister has no new state)');

    const upgraded = await upgrades.upgradeProxy(
        proxyAddress,
        OmniRegistration
    );

    await upgraded.waitForDeployment();

    // Get new implementation address
    const newImpl = await upgrades.erc1967.getImplementationAddress(proxyAddress);
    console.log(`\nNew implementation: ${newImpl}`);

    // Verify DOMAIN_SEPARATOR is still set
    const domainSeparator = await upgraded.DOMAIN_SEPARATOR();
    console.log(`DOMAIN_SEPARATOR: ${domainSeparator}`);

    if (domainSeparator === ethers.ZeroHash) {
        console.error('WARNING: DOMAIN_SEPARATOR not set - may need reinitialize!');
    } else {
        console.log('DOMAIN_SEPARATOR verified OK');
    }

    // Verify adminUnregister function exists
    try {
        // Just check the function selector exists (don't call it)
        const functionFragment = upgraded.interface.getFunction('adminUnregister');
        if (functionFragment) {
            console.log('adminUnregister function available');
        }
    } catch {
        console.error('WARNING: adminUnregister function not found in new implementation!');
    }

    // Update deployment config
    config.contracts.OmniRegistrationImplementation = newImpl;
    saveDeploymentConfig(networkName === 'localhost' ? 'localhost' : 'fuji', config);

    // Print summary
    console.log('\n========================================');
    console.log('Upgrade Complete');
    console.log('========================================');
    console.log(`OmniRegistration (Proxy): ${proxyAddress}`);
    console.log(`Old Implementation: ${currentImpl}`);
    console.log(`New Implementation: ${newImpl}`);
    console.log(`DOMAIN_SEPARATOR: ${domainSeparator}`);

    // Print verification steps
    console.log('\n--- Verification Steps ---');
    console.log('1. Verify the upgrade was successful:');
    console.log(`   npx hardhat verify --network ${networkName} ${newImpl}`);
    console.log('\n2. Test selfRegister with EIP-712 attestation');
    console.log('\n3. Ensure existing registrations are preserved');
    console.log('========================================\n');
}

// Execute
main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error('Upgrade failed:', error);
        process.exit(1);
    });
