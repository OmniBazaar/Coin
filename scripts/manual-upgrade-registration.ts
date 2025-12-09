/**
 * @file manual-upgrade-registration.ts
 * @description Manual upgrade script that bypasses OpenZeppelin upgrades plugin issues
 *
 * This script directly deploys a new implementation and upgrades the UUPS proxy.
 */

import { ethers } from 'hardhat';
import * as fs from 'fs';
import * as path from 'path';

interface DeploymentConfig {
    contracts: {
        OmniRegistration: string;
        OmniRegistrationImplementation: string;
        [key: string]: string;
    };
    [key: string]: unknown;
}

function loadDeploymentConfig(network: string): DeploymentConfig | null {
    const deploymentPath = path.join(__dirname, '..', 'deployments', `${network}.json`);
    if (fs.existsSync(deploymentPath)) {
        return JSON.parse(fs.readFileSync(deploymentPath, 'utf-8')) as DeploymentConfig;
    }
    return null;
}

function saveDeploymentConfig(network: string, config: DeploymentConfig): void {
    const deploymentPath = path.join(__dirname, '..', 'deployments', `${network}.json`);
    fs.writeFileSync(deploymentPath, JSON.stringify(config, null, 2));
    console.log(`Saved updated deployment to ${deploymentPath}`);
}

async function main(): Promise<void> {
    console.log('========================================');
    console.log('OmniRegistration Manual Upgrade');
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

    // Get deployer
    const [deployer] = await ethers.getSigners();
    const deployerAddress = await deployer.getAddress();
    console.log(`Deployer: ${deployerAddress}`);

    const balance = await ethers.provider.getBalance(deployerAddress);
    console.log(`Balance: ${ethers.formatEther(balance)} XOM\n`);

    // Get current implementation from ERC1967 storage slot
    const implSlot = '0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc';
    const currentImplRaw = await ethers.provider.getStorage(proxyAddress, implSlot);
    const currentImpl = ethers.getAddress('0x' + currentImplRaw.slice(26));
    console.log(`Current implementation: ${currentImpl}`);

    // Deploy new implementation
    console.log('\n--- Deploying New Implementation ---');
    const OmniRegistration = await ethers.getContractFactory('OmniRegistration');
    const newImpl = await OmniRegistration.deploy();
    await newImpl.waitForDeployment();
    const newImplAddress = await newImpl.getAddress();
    console.log(`New implementation deployed: ${newImplAddress}`);

    // Compare bytecode to verify it's different
    const oldBytecode = await ethers.provider.getCode(currentImpl);
    const newBytecode = await ethers.provider.getCode(newImplAddress);
    console.log(`Old implementation bytecode length: ${oldBytecode.length}`);
    console.log(`New implementation bytecode length: ${newBytecode.length}`);

    if (oldBytecode === newBytecode) {
        console.log('\nWARNING: Bytecodes are identical! No changes detected.');
        console.log('This may indicate the contract source was not modified.');
        return;
    }

    console.log('Bytecodes are different - proceeding with upgrade');

    // Upgrade proxy using UUPS upgradeToAndCall
    console.log('\n--- Upgrading Proxy ---');
    const proxy = OmniRegistration.attach(proxyAddress);
    const tx = await proxy.upgradeToAndCall(newImplAddress, '0x');
    console.log(`Upgrade transaction: ${tx.hash}`);
    await tx.wait();
    console.log('Upgrade transaction confirmed');

    // Verify the upgrade
    const verifyImplRaw = await ethers.provider.getStorage(proxyAddress, implSlot);
    const verifiedImpl = ethers.getAddress('0x' + verifyImplRaw.slice(26));
    console.log(`\nVerified implementation: ${verifiedImpl}`);

    if (verifiedImpl.toLowerCase() !== newImplAddress.toLowerCase()) {
        throw new Error('Upgrade verification failed - implementation mismatch');
    }

    // Verify new functions are accessible
    console.log('\n--- Verifying New Functions ---');

    try {
        const typehash = await proxy.EMAIL_VERIFICATION_TYPEHASH();
        console.log(`✅ EMAIL_VERIFICATION_TYPEHASH: ${typehash.slice(0, 20)}...`);
    } catch (e) {
        console.log('❌ EMAIL_VERIFICATION_TYPEHASH not accessible');
    }

    try {
        const typehash = await proxy.TRUSTLESS_REGISTRATION_TYPEHASH();
        console.log(`✅ TRUSTLESS_REGISTRATION_TYPEHASH: ${typehash.slice(0, 20)}...`);
    } catch (e) {
        console.log('❌ TRUSTLESS_REGISTRATION_TYPEHASH not accessible');
    }

    const domainSeparator = await proxy.DOMAIN_SEPARATOR();
    console.log(`✅ DOMAIN_SEPARATOR: ${domainSeparator}`);

    const trustedKey = await proxy.trustedVerificationKey();
    console.log(`trustedVerificationKey: ${trustedKey === ethers.ZeroAddress ? '(NOT SET)' : trustedKey}`);

    // Update deployment config
    config.contracts.OmniRegistrationImplementation = newImplAddress;
    saveDeploymentConfig(networkName === 'localhost' ? 'localhost' : 'fuji', config);

    // Print summary
    console.log('\n========================================');
    console.log('Upgrade Complete');
    console.log('========================================');
    console.log(`OmniRegistration (Proxy): ${proxyAddress}`);
    console.log(`Old Implementation: ${currentImpl}`);
    console.log(`New Implementation: ${newImplAddress}`);
    console.log('========================================\n');
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error('Upgrade failed:', error);
        process.exit(1);
    });
