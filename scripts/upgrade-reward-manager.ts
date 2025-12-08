/**
 * @file upgrade-reward-manager.ts
 * @description Upgrade script for OmniRewardManager contract (UUPS proxy pattern)
 *
 * This script upgrades an existing OmniRewardManager proxy to a new implementation
 * that includes registration integration features (registrationContract, oddaoAddress,
 * claimWelcomeBonusPermissionless, etc.)
 *
 * Usage:
 *   npx hardhat run scripts/upgrade-reward-manager.ts --network fuji
 *   npx hardhat run scripts/upgrade-reward-manager.ts --network localhost
 *
 * Environment Variables:
 *   PRIVATE_KEY - Deployer private key (must be admin of proxy)
 *
 * Post-Upgrade:
 *   - Call setRegistrationContract to link with OmniRegistration
 *   - Call setOddaoAddress if needed
 *   - Test claimWelcomeBonusPermissionless
 */

import { ethers, upgrades } from 'hardhat';
import * as fs from 'fs';
import * as path from 'path';

interface DeploymentConfig {
    network: string;
    chainId: number;
    contracts: {
        OmniRewardManager: string;
        OmniRewardManagerImplementation: string;
        OmniRegistration: string;
        [key: string]: string;
    };
    [key: string]: unknown;
}

/**
 * Load existing deployment configuration
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
    console.log('OmniRewardManager Upgrade');
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

    const proxyAddress = config.contracts?.OmniRewardManager;
    if (!proxyAddress) {
        throw new Error('OmniRewardManager proxy address not found in deployment config');
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
    console.log('\n--- Upgrading OmniRewardManager ---');

    const OmniRewardManager = await ethers.getContractFactory('OmniRewardManager');

    console.log('Deploying new implementation and upgrading proxy...');

    // Use unsafeSkipStorageCheck since we're adding new variables at the end
    const upgraded = await upgrades.upgradeProxy(
        proxyAddress,
        OmniRewardManager,
        {
            unsafeSkipStorageCheck: true,
        }
    );

    await upgraded.waitForDeployment();

    // Get new implementation address
    const newImpl = await upgrades.erc1967.getImplementationAddress(proxyAddress);
    console.log(`\nNew implementation: ${newImpl}`);

    // Call reinitializeV2 to initialize EIP-712 domain
    console.log('\n--- Calling reinitializeV2 for EIP-712 initialization ---');
    try {
        const tx = await upgraded.reinitializeV2();
        await tx.wait();
        console.log('reinitializeV2() completed successfully ✓');
    } catch (e) {
        const error = e as Error;
        // If already initialized, that's ok
        if (error.message.includes('InvalidInitialization')) {
            console.log('reinitializeV2() already called (skipped)');
        } else {
            console.error('reinitializeV2() failed:', error.message);
        }
    }

    // Test that new functions are available
    console.log('\n--- Verifying Upgrade ---');

    // Check paused (should still work)
    try {
        const paused = await upgraded.paused();
        console.log(`paused(): ${paused} ✓`);
    } catch (e) {
        console.log(`paused(): ERROR - ${(e as Error).message}`);
    }

    // Check registrationContract (should now exist)
    try {
        const regContract = await upgraded.registrationContract();
        console.log(`registrationContract(): ${regContract} ✓`);
    } catch (e) {
        console.log(`registrationContract(): ERROR - ${(e as Error).message}`);
    }

    // Check oddaoAddress (should now exist)
    try {
        const oddao = await upgraded.oddaoAddress();
        console.log(`oddaoAddress(): ${oddao} ✓`);
    } catch (e) {
        console.log(`oddaoAddress(): ERROR - ${(e as Error).message}`);
    }

    // Check getClaimNonce (new V2 function for trustless relay)
    try {
        const nonce = await upgraded.getClaimNonce(upgraderAddress);
        console.log(`getClaimNonce(): ${nonce} ✓`);
    } catch (e) {
        console.log(`getClaimNonce(): ERROR - ${(e as Error).message}`);
    }

    // Check CLAIM_WELCOME_BONUS_TYPEHASH (EIP-712 typehash)
    try {
        const typehash = await upgraded.CLAIM_WELCOME_BONUS_TYPEHASH();
        console.log(`CLAIM_WELCOME_BONUS_TYPEHASH(): ${typehash} ✓`);
    } catch (e) {
        console.log(`CLAIM_WELCOME_BONUS_TYPEHASH(): ERROR - ${(e as Error).message}`);
    }

    // Update deployment config
    config.contracts.OmniRewardManagerImplementation = newImpl;
    saveDeploymentConfig(networkName === 'localhost' ? 'localhost' : 'fuji', config);

    // Print summary
    console.log('\n========================================');
    console.log('Upgrade Complete');
    console.log('========================================');
    console.log(`OmniRewardManager (Proxy): ${proxyAddress}`);
    console.log(`Old Implementation: ${currentImpl}`);
    console.log(`New Implementation: ${newImpl}`);

    // Print next steps
    console.log('\n--- Next Steps ---');
    console.log('1. Configure the reward manager with registration contract:');
    console.log(`   npx hardhat run scripts/configure-reward-manager-registration.ts --network ${networkName}`);
    console.log('\n2. Verify the upgrade was successful:');
    console.log(`   npx hardhat verify --network ${networkName} ${newImpl}`);
    console.log('========================================\n');
}

// Execute
main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error('Upgrade failed:', error);
        process.exit(1);
    });
