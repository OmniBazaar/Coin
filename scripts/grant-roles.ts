/**
 * @file grant-roles.ts
 * @description Script to grant roles on OmniRegistration and OmniSybilGuard contracts
 *
 * Usage:
 *   npx hardhat run scripts/grant-roles.ts --network fuji
 *
 * This script grants:
 *   - VALIDATOR_ROLE and KYC_ATTESTOR_ROLE on OmniRegistration
 *   - REPORTER_ROLE and JUDGE_ROLE on OmniSybilGuard
 *
 * The roles are granted to the deployer address (which acts as the gateway validator)
 * In production, these would be granted to actual validator addresses.
 */

import { ethers } from 'hardhat';
import * as fs from 'fs';
import * as path from 'path';

interface DeploymentConfig {
    contracts: {
        OmniRegistration: string;
        OmniSybilGuard: string;
        [key: string]: string;
    };
}

/**
 * Load deployment configuration
 */
function loadDeploymentConfig(network: string): DeploymentConfig {
    const deploymentPath = path.join(__dirname, '..', 'deployments', `${network}.json`);

    if (!fs.existsSync(deploymentPath)) {
        throw new Error(`Deployment file not found: ${deploymentPath}`);
    }

    const content = fs.readFileSync(deploymentPath, 'utf-8');
    return JSON.parse(content);
}

/**
 * Main function to grant roles
 */
async function main(): Promise<void> {
    console.log('========================================');
    console.log('Grant Roles Script');
    console.log('========================================\n');

    // Get network info
    const network = await ethers.provider.getNetwork();
    const networkName = network.name === 'unknown' ? 'fuji' : network.name;
    console.log(`Network: ${networkName} (chainId: ${network.chainId})`);

    // Get deployer (admin)
    const [admin] = await ethers.getSigners();
    const adminAddress = await admin.getAddress();
    console.log(`Admin: ${adminAddress}`);

    const balance = await ethers.provider.getBalance(adminAddress);
    console.log(`Balance: ${ethers.formatEther(balance)} ETH\n`);

    // Load deployment config
    const config = loadDeploymentConfig(networkName);
    console.log('Loaded deployment config');

    // Get contract addresses
    const registrationAddress = config.contracts.OmniRegistration;
    const sybilGuardAddress = config.contracts.OmniSybilGuard;

    if (!registrationAddress || registrationAddress === '0x0000000000000000000000000000000000000000') {
        throw new Error('OmniRegistration address not found in deployment config');
    }

    if (!sybilGuardAddress || sybilGuardAddress === '0x0000000000000000000000000000000000000000') {
        throw new Error('OmniSybilGuard address not found in deployment config');
    }

    console.log(`OmniRegistration: ${registrationAddress}`);
    console.log(`OmniSybilGuard: ${sybilGuardAddress}\n`);

    // Get contract instances
    const OmniRegistration = await ethers.getContractFactory('OmniRegistration');
    const registration = OmniRegistration.attach(registrationAddress);

    const OmniSybilGuard = await ethers.getContractFactory('OmniSybilGuard');
    const sybilGuard = OmniSybilGuard.attach(sybilGuardAddress);

    // Determine which address to grant roles to
    // In development, grant to deployer (gateway validator)
    // In production, this would be a list of validator addresses
    const validatorAddresses = [adminAddress];

    console.log('--- Granting OmniRegistration Roles ---');

    // Get role constants
    const VALIDATOR_ROLE = await registration.VALIDATOR_ROLE();
    const KYC_ATTESTOR_ROLE = await registration.KYC_ATTESTOR_ROLE();

    console.log(`VALIDATOR_ROLE: ${VALIDATOR_ROLE}`);
    console.log(`KYC_ATTESTOR_ROLE: ${KYC_ATTESTOR_ROLE}`);

    for (const validatorAddr of validatorAddresses) {
        // Check if already has VALIDATOR_ROLE
        const hasValidatorRole = await registration.hasRole(VALIDATOR_ROLE, validatorAddr);
        if (hasValidatorRole) {
            console.log(`${validatorAddr} already has VALIDATOR_ROLE`);
        } else {
            console.log(`Granting VALIDATOR_ROLE to ${validatorAddr}...`);
            const tx1 = await registration.grantRole(VALIDATOR_ROLE, validatorAddr);
            await tx1.wait();
            console.log(`  Tx: ${tx1.hash}`);
        }

        // Check if already has KYC_ATTESTOR_ROLE
        const hasKycRole = await registration.hasRole(KYC_ATTESTOR_ROLE, validatorAddr);
        if (hasKycRole) {
            console.log(`${validatorAddr} already has KYC_ATTESTOR_ROLE`);
        } else {
            console.log(`Granting KYC_ATTESTOR_ROLE to ${validatorAddr}...`);
            const tx2 = await registration.grantRole(KYC_ATTESTOR_ROLE, validatorAddr);
            await tx2.wait();
            console.log(`  Tx: ${tx2.hash}`);
        }
    }

    console.log('\n--- Granting OmniSybilGuard Roles ---');

    // Get role constants
    const REPORTER_ROLE = await sybilGuard.REPORTER_ROLE();
    const JUDGE_ROLE = await sybilGuard.JUDGE_ROLE();

    console.log(`REPORTER_ROLE: ${REPORTER_ROLE}`);
    console.log(`JUDGE_ROLE: ${JUDGE_ROLE}`);

    for (const validatorAddr of validatorAddresses) {
        // Check if already has REPORTER_ROLE
        const hasReporterRole = await sybilGuard.hasRole(REPORTER_ROLE, validatorAddr);
        if (hasReporterRole) {
            console.log(`${validatorAddr} already has REPORTER_ROLE`);
        } else {
            console.log(`Granting REPORTER_ROLE to ${validatorAddr}...`);
            const tx3 = await sybilGuard.grantRole(REPORTER_ROLE, validatorAddr);
            await tx3.wait();
            console.log(`  Tx: ${tx3.hash}`);
        }

        // Check if already has JUDGE_ROLE
        const hasJudgeRole = await sybilGuard.hasRole(JUDGE_ROLE, validatorAddr);
        if (hasJudgeRole) {
            console.log(`${validatorAddr} already has JUDGE_ROLE`);
        } else {
            console.log(`Granting JUDGE_ROLE to ${validatorAddr}...`);
            const tx4 = await sybilGuard.grantRole(JUDGE_ROLE, validatorAddr);
            await tx4.wait();
            console.log(`  Tx: ${tx4.hash}`);
        }
    }

    // Verify roles
    console.log('\n--- Verification ---');

    for (const validatorAddr of validatorAddresses) {
        console.log(`\nValidator: ${validatorAddr}`);

        const regRoles = [
            { name: 'VALIDATOR_ROLE', value: VALIDATOR_ROLE },
            { name: 'KYC_ATTESTOR_ROLE', value: KYC_ATTESTOR_ROLE },
        ];

        for (const role of regRoles) {
            const hasRole = await registration.hasRole(role.value, validatorAddr);
            console.log(`  OmniRegistration.${role.name}: ${hasRole ? '✅' : '❌'}`);
        }

        const sgRoles = [
            { name: 'REPORTER_ROLE', value: REPORTER_ROLE },
            { name: 'JUDGE_ROLE', value: JUDGE_ROLE },
        ];

        for (const role of sgRoles) {
            const hasRole = await sybilGuard.hasRole(role.value, validatorAddr);
            console.log(`  OmniSybilGuard.${role.name}: ${hasRole ? '✅' : '❌'}`);
        }
    }

    console.log('\n========================================');
    console.log('Role Granting Complete');
    console.log('========================================\n');
}

// Execute
main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error('Role granting failed:', error);
        process.exit(1);
    });
