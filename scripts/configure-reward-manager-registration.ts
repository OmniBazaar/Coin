/**
 * @file configure-reward-manager-registration.ts
 * @description Configure OmniRewardManager with OmniRegistration integration
 *
 * Usage:
 *   npx hardhat run scripts/configure-reward-manager-registration.ts --network fuji
 *   npx hardhat run scripts/configure-reward-manager-registration.ts --network localhost
 *
 * Environment Variables:
 *   PRIVATE_KEY - Admin private key
 *   OMNI_REWARD_MANAGER - OmniRewardManager proxy address (or load from deployments)
 *   OMNI_REGISTRATION - OmniRegistration proxy address (or load from deployments)
 *   ODDAO_ADDRESS - ODDAO address for referral fee distribution
 *
 * Prerequisites:
 *   - OmniRewardManager deployed
 *   - OmniRegistration deployed
 *   - Caller must have DEFAULT_ADMIN_ROLE on OmniRewardManager
 */

import { ethers } from 'hardhat';
import * as fs from 'fs';
import * as path from 'path';

interface ConfigResult {
    rewardManagerAddress: string;
    registrationAddress: string;
    oddaoAddress: string;
    network: string;
    timestamp: string;
    transactionHashes: string[];
}

/**
 * Load deployment configuration
 */
function loadDeploymentConfig(network: string): Record<string, string> {
    const deploymentPath = path.join(__dirname, '..', 'deployments', `${network}.json`);

    if (fs.existsSync(deploymentPath)) {
        const content = fs.readFileSync(deploymentPath, 'utf-8');
        return JSON.parse(content);
    }

    throw new Error(`Deployment config not found: ${deploymentPath}`);
}

/**
 * Main configuration function
 */
async function main(): Promise<void> {
    console.log('========================================');
    console.log('OmniRewardManager Registration Config');
    console.log('========================================\n');

    // Get network info
    const network = await ethers.provider.getNetwork();
    const networkName = network.name === 'unknown' ? 'localhost' : network.name;
    console.log(`Network: ${networkName} (chainId: ${network.chainId})`);

    // Get signer
    const [signer] = await ethers.getSigners();
    const signerAddress = await signer.getAddress();
    console.log(`Signer: ${signerAddress}`);

    // Load deployment config
    const deployments = loadDeploymentConfig(networkName);

    // Get contract addresses
    const rewardManagerAddress = process.env.OMNI_REWARD_MANAGER || deployments.OmniRewardManager;
    const registrationAddress = process.env.OMNI_REGISTRATION || deployments.OmniRegistration;
    const oddaoAddress = process.env.ODDAO_ADDRESS || signerAddress; // Default to signer for testing

    if (!rewardManagerAddress) {
        throw new Error('OmniRewardManager address not found. Deploy it first.');
    }
    if (!registrationAddress) {
        throw new Error('OmniRegistration address not found. Deploy it first.');
    }

    console.log(`\nOmniRewardManager: ${rewardManagerAddress}`);
    console.log(`OmniRegistration: ${registrationAddress}`);
    console.log(`ODDAO Address: ${oddaoAddress}`);

    // Get contract instance
    const OmniRewardManager = await ethers.getContractFactory('OmniRewardManager');
    const rewardManager = OmniRewardManager.attach(rewardManagerAddress);

    // Track transaction hashes
    const txHashes: string[] = [];

    // Check if registration contract is already set
    const currentRegistration = await rewardManager.registrationContract();
    if (currentRegistration === ethers.ZeroAddress) {
        console.log('\n--- Setting Registration Contract ---');
        const tx1 = await rewardManager.setRegistrationContract(registrationAddress);
        await tx1.wait();
        txHashes.push(tx1.hash);
        console.log(`Set registration contract: ${tx1.hash}`);
    } else {
        console.log(`\nRegistration contract already set: ${currentRegistration}`);
        if (currentRegistration.toLowerCase() !== registrationAddress.toLowerCase()) {
            console.log('WARNING: Current registration contract differs from specified!');
        }
    }

    // Check if ODDAO address is already set
    const currentOddao = await rewardManager.oddaoAddress();
    if (currentOddao === ethers.ZeroAddress) {
        console.log('\n--- Setting ODDAO Address ---');
        const tx2 = await rewardManager.setOddaoAddress(oddaoAddress);
        await tx2.wait();
        txHashes.push(tx2.hash);
        console.log(`Set ODDAO address: ${tx2.hash}`);
    } else {
        console.log(`\nODDAO address already set: ${currentOddao}`);
        if (currentOddao.toLowerCase() !== oddaoAddress.toLowerCase()) {
            console.log('WARNING: Current ODDAO address differs from specified!');
        }
    }

    // Verify configuration
    console.log('\n--- Verifying Configuration ---');
    const finalRegistration = await rewardManager.registrationContract();
    const finalOddao = await rewardManager.oddaoAddress();
    console.log(`Registration Contract: ${finalRegistration}`);
    console.log(`ODDAO Address: ${finalOddao}`);

    // Print summary
    console.log('\n========================================');
    console.log('Configuration Complete');
    console.log('========================================');
    console.log(`Transactions: ${txHashes.length}`);
    txHashes.forEach((hash, i) => console.log(`  ${i + 1}. ${hash}`));

    // Print next steps
    console.log('\n--- Next Steps ---');
    console.log('1. Grant VALIDATOR_ROLE on OmniRegistration to gateway validators');
    console.log('2. Grant REPORTER_ROLE on OmniSybilGuard to validators');
    console.log('3. Test permissionless claiming flow:');
    console.log('   a. Register user via validator (selfRegister)');
    console.log('   b. User calls claimWelcomeBonusPermissionless() immediately');
    console.log('========================================\n');
}

// Execute
main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error('Configuration failed:', error);
        process.exit(1);
    });
