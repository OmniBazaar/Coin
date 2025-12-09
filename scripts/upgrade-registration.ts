/**
 * @file upgrade-registration.ts
 * @description Upgrade script for OmniRegistration contract (UUPS proxy pattern)
 *
 * This script upgrades an existing OmniRegistration proxy to a new implementation.
 * Uses prepareUpgrade with redeployImplementation: 'always' to ensure fresh deployment.
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
 *   - Verify EMAIL_VERIFICATION_TYPEHASH is accessible
 *   - Test selfRegisterTrustless() with email proof + user signature
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

    // First, register the proxy in OpenZeppelin manifest if not already registered
    // This is needed before we can call upgradeProxy
    try {
        await upgrades.forceImport(proxyAddress, OmniRegistration, { kind: 'uups' });
        console.log('Proxy registered in OpenZeppelin manifest');
    } catch (importError: unknown) {
        const errorMessage = importError instanceof Error ? importError.message : String(importError);
        if (errorMessage.includes('already imported') || errorMessage.includes('already registered')) {
            console.log('Proxy already registered in manifest');
        } else {
            throw importError;
        }
    }

    // Now upgrade with redeployImplementation: 'always' to force new deployment
    console.log('Deploying new implementation and upgrading proxy...');
    const upgraded = await upgrades.upgradeProxy(proxyAddress, OmniRegistration, {
        kind: 'uups',
        redeployImplementation: 'always', // Force deploy even if bytecode seems unchanged
    });
    await upgraded.waitForDeployment();

    // Verify the upgrade
    const newImpl = await upgrades.erc1967.getImplementationAddress(proxyAddress);
    console.log(`\nNew implementation: ${newImpl}`);

    if (newImpl === currentImpl) {
        console.log('WARNING: Implementation address unchanged - upgrade may not have occurred');
    } else {
        console.log('Implementation successfully upgraded');
    }

    // Verify DOMAIN_SEPARATOR is still set
    const domainSeparator = await upgraded.DOMAIN_SEPARATOR();
    console.log(`DOMAIN_SEPARATOR: ${domainSeparator}`);

    if (domainSeparator === ethers.ZeroHash) {
        console.error('WARNING: DOMAIN_SEPARATOR not set - may need reinitialize!');
    } else {
        console.log('DOMAIN_SEPARATOR verified OK');
    }

    // Verify selfRegisterTrustless function exists (new trustless registration)
    try {
        const functionFragment = upgraded.interface.getFunction('selfRegisterTrustless');
        if (functionFragment) {
            console.log('selfRegisterTrustless function available');
        }
    } catch {
        console.error('WARNING: selfRegisterTrustless function not found!');
    }

    // Verify EMAIL_VERIFICATION_TYPEHASH is accessible
    try {
        const typehash = await upgraded.EMAIL_VERIFICATION_TYPEHASH();
        console.log(`EMAIL_VERIFICATION_TYPEHASH: ${typehash.slice(0, 20)}...`);
    } catch {
        console.error('WARNING: EMAIL_VERIFICATION_TYPEHASH not accessible!');
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
    console.log('1. Verify implementation on explorer:');
    console.log(`   npx hardhat verify --network ${networkName} ${newImpl}`);
    console.log('\n2. Test selfRegisterTrustless() with email proof + user signature');
    console.log('\n3. Ensure existing registrations are preserved');
    console.log('\n4. Verify selfRegister() is no longer callable (removed)');
    console.log('========================================\n');
}

// Execute
main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error('Upgrade failed:', error);
        process.exit(1);
    });
