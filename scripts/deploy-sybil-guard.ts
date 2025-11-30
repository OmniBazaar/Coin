/**
 * @file deploy-sybil-guard.ts
 * @description Deployment script for OmniSybilGuard contract
 *
 * Usage:
 *   npx hardhat run scripts/deploy-sybil-guard.ts --network fuji
 *   npx hardhat run scripts/deploy-sybil-guard.ts --network localhost
 *
 * Environment Variables:
 *   PRIVATE_KEY - Deployer private key
 *   ADMIN_ADDRESS - Address to receive admin roles (defaults to deployer)
 *   INITIAL_REWARD_POOL - Initial XOM to fund reward pool (in ETH units)
 *
 * Post-Deployment:
 *   - Grant REPORTER_ROLE to validators who can register devices
 *   - Grant JUDGE_ROLE to trusted arbitrators
 *   - Fund reward pool for Sybil reporter rewards
 */

import { ethers, upgrades } from 'hardhat';
import * as fs from 'fs';
import * as path from 'path';

interface DeploymentResult {
    proxyAddress: string;
    implementationAddress: string;
    adminAddress: string;
    initialRewardPool: string;
    network: string;
    timestamp: string;
    blockNumber: number;
    transactionHash: string;
}

/**
 * Load existing deployment configuration
 */
function loadDeploymentConfig(network: string): Record<string, string> {
    const deploymentPath = path.join(__dirname, '..', 'deployments', `${network}.json`);

    if (fs.existsSync(deploymentPath)) {
        const content = fs.readFileSync(deploymentPath, 'utf-8');
        return JSON.parse(content);
    }

    return {};
}

/**
 * Save deployment result to configuration
 */
function saveDeploymentConfig(network: string, result: DeploymentResult): void {
    const deploymentPath = path.join(__dirname, '..', 'deployments', `${network}.json`);

    // Load existing config
    let config: Record<string, unknown> = {};
    if (fs.existsSync(deploymentPath)) {
        const content = fs.readFileSync(deploymentPath, 'utf-8');
        config = JSON.parse(content);
    }

    // Update with new contract
    config.OmniSybilGuard = result.proxyAddress;
    config.OmniSybilGuardImpl = result.implementationAddress;

    // Save
    fs.writeFileSync(deploymentPath, JSON.stringify(config, null, 2));
    console.log(`\nSaved deployment to ${deploymentPath}`);
}

/**
 * Main deployment function
 */
async function main(): Promise<void> {
    console.log('========================================');
    console.log('OmniSybilGuard Deployment');
    console.log('========================================\n');

    // Get network info
    const network = await ethers.provider.getNetwork();
    const networkName = network.name === 'unknown' ? 'localhost' : network.name;
    console.log(`Network: ${networkName} (chainId: ${network.chainId})`);

    // Get deployer
    const [deployer] = await ethers.getSigners();
    const deployerAddress = await deployer.getAddress();
    console.log(`Deployer: ${deployerAddress}`);

    const balance = await ethers.provider.getBalance(deployerAddress);
    console.log(`Balance: ${ethers.formatEther(balance)} ETH\n`);

    // Admin address (use env or default to deployer)
    const adminAddress = process.env.ADMIN_ADDRESS || deployerAddress;
    console.log(`Admin: ${adminAddress}`);

    // Initial reward pool funding (optional)
    const initialRewardPool = process.env.INITIAL_REWARD_POOL
        ? ethers.parseEther(process.env.INITIAL_REWARD_POOL)
        : 0n;
    console.log(`Initial Reward Pool: ${ethers.formatEther(initialRewardPool)} ETH`);

    // Deploy OmniSybilGuard as UUPS proxy
    console.log('\n--- Deploying OmniSybilGuard ---');

    const OmniSybilGuard = await ethers.getContractFactory('OmniSybilGuard');

    console.log('Deploying proxy...');
    const proxy = await upgrades.deployProxy(
        OmniSybilGuard,
        [], // initialize() has no params
        {
            initializer: 'initialize',
            kind: 'uups',
        }
    );

    await proxy.waitForDeployment();
    const proxyAddress = await proxy.getAddress();
    console.log(`Proxy deployed to: ${proxyAddress}`);

    // Get implementation address
    const implementationAddress = await upgrades.erc1967.getImplementationAddress(proxyAddress);
    console.log(`Implementation: ${implementationAddress}`);

    // Grant admin role if different from deployer
    if (adminAddress.toLowerCase() !== deployerAddress.toLowerCase()) {
        console.log(`\nGranting DEFAULT_ADMIN_ROLE to ${adminAddress}...`);
        const DEFAULT_ADMIN_ROLE = await proxy.DEFAULT_ADMIN_ROLE();
        const tx = await proxy.grantRole(DEFAULT_ADMIN_ROLE, adminAddress);
        await tx.wait();
        console.log('Admin role granted');
    }

    // Fund reward pool if specified
    if (initialRewardPool > 0n) {
        console.log(`\nFunding reward pool with ${ethers.formatEther(initialRewardPool)} ETH...`);
        const tx = await proxy.fundRewardPool({ value: initialRewardPool });
        await tx.wait();
        console.log('Reward pool funded');
    }

    // Get deployment receipt
    const deploymentTx = proxy.deploymentTransaction();
    const receipt = deploymentTx ? await deploymentTx.wait() : null;

    // Prepare result
    const result: DeploymentResult = {
        proxyAddress,
        implementationAddress,
        adminAddress,
        initialRewardPool: ethers.formatEther(initialRewardPool),
        network: networkName,
        timestamp: new Date().toISOString(),
        blockNumber: receipt?.blockNumber || 0,
        transactionHash: receipt?.hash || '',
    };

    // Save deployment
    saveDeploymentConfig(networkName, result);

    // Print summary
    console.log('\n========================================');
    console.log('Deployment Complete');
    console.log('========================================');
    console.log(`OmniSybilGuard (Proxy): ${proxyAddress}`);
    console.log(`Implementation: ${implementationAddress}`);
    console.log(`Admin: ${adminAddress}`);
    console.log(`Reward Pool: ${ethers.formatEther(initialRewardPool)} ETH`);
    console.log(`Block: ${result.blockNumber}`);
    console.log(`Tx: ${result.transactionHash}`);

    // Print next steps
    console.log('\n--- Next Steps ---');
    console.log('1. Grant REPORTER_ROLE to validators (for device registration):');
    console.log(`   const REPORTER_ROLE = await contract.REPORTER_ROLE();`);
    console.log(`   await contract.grantRole(REPORTER_ROLE, validatorAddress);`);
    console.log('\n2. Grant JUDGE_ROLE to trusted arbitrators:');
    console.log(`   const JUDGE_ROLE = await contract.JUDGE_ROLE();`);
    console.log(`   await contract.grantRole(JUDGE_ROLE, judgeAddress);`);
    console.log('\n3. Fund reward pool for Sybil reporter rewards:');
    console.log(`   await contract.fundRewardPool({ value: ethers.parseEther("10000") });`);
    console.log('========================================\n');
}

// Execute
main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error('Deployment failed:', error);
        process.exit(1);
    });
