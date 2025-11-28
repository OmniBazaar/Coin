/**
 * @file deploy-reward-manager.ts
 * @description Deployment script for OmniRewardManager contract
 *
 * Usage:
 *   npx hardhat run scripts/deploy-reward-manager.ts --network fuji
 *   npx hardhat run scripts/deploy-reward-manager.ts --network localhost
 *
 * Environment Variables:
 *   PRIVATE_KEY - Deployer private key
 *   OMNICOIN_ADDRESS - Address of deployed OmniCoin contract
 *   ADMIN_ADDRESS - Address to receive admin roles (defaults to deployer)
 *
 * For Fuji Testing:
 *   - Uses 100M XOM per pool (400M total)
 *   - Deploys UUPS proxy with implementation
 *   - Grants all roles to admin address
 */

import { ethers, upgrades } from 'hardhat';
import { Contract, Signer } from 'ethers';
import * as fs from 'fs';
import * as path from 'path';

// Production pool sizes (in XOM with 18 decimals)
const PRODUCTION_POOLS = {
    welcomeBonus: ethers.parseEther('1383457500'),      // 1,383,457,500 XOM
    referralBonus: ethers.parseEther('2995000000'),     // 2,995,000,000 XOM
    firstSaleBonus: ethers.parseEther('2000000000'),    // 2,000,000,000 XOM
    validatorRewards: ethers.parseEther('6089000000'),  // 6,089,000,000 XOM
};

// Test pool sizes (smaller for Fuji testing)
const TEST_POOLS = {
    welcomeBonus: ethers.parseEther('100000000'),       // 100,000,000 XOM
    referralBonus: ethers.parseEther('100000000'),      // 100,000,000 XOM
    firstSaleBonus: ethers.parseEther('100000000'),     // 100,000,000 XOM
    validatorRewards: ethers.parseEther('100000000'),   // 100,000,000 XOM
};

interface DeploymentResult {
    proxyAddress: string;
    implementationAddress: string;
    omniCoinAddress: string;
    adminAddress: string;
    poolSizes: {
        welcomeBonus: string;
        referralBonus: string;
        firstSaleBonus: string;
        validatorRewards: string;
        total: string;
    };
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
    config.OmniRewardManager = result.proxyAddress;
    config.OmniRewardManagerImpl = result.implementationAddress;

    // Save
    fs.writeFileSync(deploymentPath, JSON.stringify(config, null, 2));
    console.log(`\nSaved deployment to ${deploymentPath}`);
}

/**
 * Main deployment function
 */
async function main(): Promise<void> {
    console.log('========================================');
    console.log('OmniRewardManager Deployment');
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
    console.log(`Balance: ${ethers.formatEther(balance)} AVAX\n`);

    // Determine pool sizes based on network
    const isTestnet = networkName === 'localhost' ||
                      networkName === 'fuji' ||
                      network.chainId === 31337n ||
                      network.chainId === 131313n;

    const pools = isTestnet ? TEST_POOLS : PRODUCTION_POOLS;
    const totalPoolSize = pools.welcomeBonus + pools.referralBonus +
                         pools.firstSaleBonus + pools.validatorRewards;

    console.log(`Pool Configuration (${isTestnet ? 'TESTNET' : 'PRODUCTION'}):`);
    console.log(`  Welcome Bonus:     ${ethers.formatEther(pools.welcomeBonus)} XOM`);
    console.log(`  Referral Bonus:    ${ethers.formatEther(pools.referralBonus)} XOM`);
    console.log(`  First Sale Bonus:  ${ethers.formatEther(pools.firstSaleBonus)} XOM`);
    console.log(`  Validator Rewards: ${ethers.formatEther(pools.validatorRewards)} XOM`);
    console.log(`  TOTAL:             ${ethers.formatEther(totalPoolSize)} XOM\n`);

    // Get OmniCoin address
    const existingConfig = loadDeploymentConfig(networkName);
    const omniCoinAddress = process.env.OMNICOIN_ADDRESS ??
                           existingConfig.OmniCoin ??
                           '';

    if (!omniCoinAddress) {
        throw new Error('OmniCoin address not found. Set OMNICOIN_ADDRESS or deploy OmniCoin first.');
    }
    console.log(`OmniCoin Address: ${omniCoinAddress}`);

    // Get admin address (defaults to deployer)
    const adminAddress = process.env.ADMIN_ADDRESS ?? deployerAddress;
    console.log(`Admin Address: ${adminAddress}\n`);

    // Verify OmniCoin contract exists
    const omniCoin = await ethers.getContractAt('OmniCoin', omniCoinAddress);
    const tokenName = await omniCoin.name();
    const tokenSymbol = await omniCoin.symbol();
    console.log(`Verified OmniCoin: ${tokenName} (${tokenSymbol})`);

    // Check deployer's token balance
    const tokenBalance = await omniCoin.balanceOf(deployerAddress);
    console.log(`Deployer XOM Balance: ${ethers.formatEther(tokenBalance)} XOM`);

    if (tokenBalance < totalPoolSize) {
        throw new Error(
            `Insufficient XOM balance. ` +
            `Need ${ethers.formatEther(totalPoolSize)} XOM, ` +
            `have ${ethers.formatEther(tokenBalance)} XOM`
        );
    }

    console.log('\nDeploying OmniRewardManager...');

    // Deploy the contract using UUPS proxy
    const OmniRewardManager = await ethers.getContractFactory('OmniRewardManager');

    const proxy = await upgrades.deployProxy(
        OmniRewardManager,
        [
            omniCoinAddress,
            pools.welcomeBonus,
            pools.referralBonus,
            pools.firstSaleBonus,
            pools.validatorRewards,
            adminAddress,
        ],
        {
            initializer: 'initialize',
            kind: 'uups',
        }
    );

    await proxy.waitForDeployment();
    const proxyAddress = await proxy.getAddress();

    // Get implementation address
    const implementationAddress = await upgrades.erc1967.getImplementationAddress(proxyAddress);

    console.log(`\nProxy Address: ${proxyAddress}`);
    console.log(`Implementation Address: ${implementationAddress}`);

    // Transfer tokens to the contract
    console.log(`\nTransferring ${ethers.formatEther(totalPoolSize)} XOM to OmniRewardManager...`);

    const transferTx = await omniCoin.transfer(proxyAddress, totalPoolSize);
    const transferReceipt = await transferTx.wait();

    console.log(`Transfer tx: ${transferReceipt?.hash}`);

    // Verify contract balance
    const contractBalance = await omniCoin.balanceOf(proxyAddress);
    console.log(`Contract XOM Balance: ${ethers.formatEther(contractBalance)} XOM`);

    if (contractBalance !== totalPoolSize) {
        console.warn('WARNING: Contract balance does not match expected pool size!');
    }

    // Verify pool balances
    const rewardManager = await ethers.getContractAt('OmniRewardManager', proxyAddress);
    const [welcomeRemaining, referralRemaining, firstSaleRemaining, validatorRemaining] =
        await rewardManager.getPoolBalances();

    console.log('\nVerified Pool Balances:');
    console.log(`  Welcome Bonus:     ${ethers.formatEther(welcomeRemaining)} XOM`);
    console.log(`  Referral Bonus:    ${ethers.formatEther(referralRemaining)} XOM`);
    console.log(`  First Sale Bonus:  ${ethers.formatEther(firstSaleRemaining)} XOM`);
    console.log(`  Validator Rewards: ${ethers.formatEther(validatorRemaining)} XOM`);

    // Get deployment transaction details
    const deploymentTx = proxy.deploymentTransaction();
    const receipt = await deploymentTx?.wait();

    // Create deployment result
    const result: DeploymentResult = {
        proxyAddress,
        implementationAddress,
        omniCoinAddress,
        adminAddress,
        poolSizes: {
            welcomeBonus: ethers.formatEther(pools.welcomeBonus),
            referralBonus: ethers.formatEther(pools.referralBonus),
            firstSaleBonus: ethers.formatEther(pools.firstSaleBonus),
            validatorRewards: ethers.formatEther(pools.validatorRewards),
            total: ethers.formatEther(totalPoolSize),
        },
        network: networkName,
        timestamp: new Date().toISOString(),
        blockNumber: receipt?.blockNumber ?? 0,
        transactionHash: receipt?.hash ?? '',
    };

    // Save deployment
    saveDeploymentConfig(networkName, result);

    // Print summary
    console.log('\n========================================');
    console.log('Deployment Complete!');
    console.log('========================================');
    console.log(`\nProxy Address:          ${proxyAddress}`);
    console.log(`Implementation Address: ${implementationAddress}`);
    console.log(`Block Number:           ${result.blockNumber}`);
    console.log(`Transaction Hash:       ${result.transactionHash}`);

    // Verification reminder
    if (networkName !== 'localhost' && networkName !== 'hardhat') {
        console.log('\n========================================');
        console.log('Verification Commands');
        console.log('========================================');
        console.log(`\n# Verify implementation contract:`);
        console.log(`npx hardhat verify --network ${networkName} ${implementationAddress}`);
        console.log(`\n# Sync addresses to all modules:`);
        console.log(`cd /home/rickc/OmniBazaar && ./scripts/sync-contract-addresses.sh ${networkName}`);
    }
}

// Execute
main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error('Deployment failed:', error);
        process.exit(1);
    });
