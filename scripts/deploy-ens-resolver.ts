/**
 * @file deploy-ens-resolver.ts
 * @description Deployment script for OmniBazaarResolver contract
 *
 * Deploys the ENSIP-10 + ERC-3668 wildcard resolver for *.omnibazaar.eth.
 * This contract is deployed on Ethereum mainnet (or testnet for testing).
 *
 * Usage:
 *   npx hardhat run scripts/deploy-ens-resolver.ts --network localhost
 *   npx hardhat run scripts/deploy-ens-resolver.ts --network ethereum_mainnet
 *
 * Environment Variables:
 *   ENS_CCIP_SIGNER_ADDRESS - Address of the CCIP-Read gateway signer
 *   ENS_GATEWAY_URL - Gateway URL template (default: https://ens-gateway.omnibazaar.com/ccip/{sender}/{data}.json)
 *   ENS_RESPONSE_TTL - Response TTL in seconds (default: 300)
 */

import { ethers } from 'hardhat';
import * as fs from 'fs';
import * as path from 'path';

interface DeploymentResult {
    contractAddress: string;
    network: string;
    timestamp: string;
    blockNumber: number;
    transactionHash: string;
    gatewayURLs: string[];
    signerAddress: string;
    responseTTL: number;
}

/**
 * Load existing deployment configuration
 * @param network - Network name (e.g., "localhost", "ethereum_mainnet")
 * @returns Existing deployment config object
 */
function loadDeploymentConfig(network: string): Record<string, unknown> {
    const deploymentPath = path.join(__dirname, '..', 'deployments', `${network}.json`);

    if (fs.existsSync(deploymentPath)) {
        const content = fs.readFileSync(deploymentPath, 'utf-8');
        return JSON.parse(content);
    }

    return {};
}

/**
 * Save deployment result to configuration
 * @param network - Network name
 * @param result - Deployment result to save
 */
function saveDeploymentConfig(network: string, result: DeploymentResult): void {
    const deploymentPath = path.join(__dirname, '..', 'deployments', `${network}.json`);

    // Load existing config
    const config = loadDeploymentConfig(network);

    // Update with new contract
    config.OmniBazaarResolver = result.contractAddress;

    // Ensure directory exists
    const dir = path.dirname(deploymentPath);
    if (!fs.existsSync(dir)) {
        fs.mkdirSync(dir, { recursive: true });
    }

    // Save
    fs.writeFileSync(deploymentPath, JSON.stringify(config, null, 2));
    console.log(`\nSaved deployment to ${deploymentPath}`);
}

/**
 * Main deployment function
 */
async function main(): Promise<void> {
    console.log('========================================');
    console.log('OmniBazaarResolver Deployment');
    console.log('ENSIP-10 + ERC-3668 Wildcard Resolver');
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

    // Configuration
    const gatewayURL = process.env.ENS_GATEWAY_URL
        || 'https://ens-gateway.omnibazaar.com/ccip/{sender}/{data}.json';
    const signerAddress = process.env.ENS_CCIP_SIGNER_ADDRESS || deployerAddress;
    const responseTTL = parseInt(process.env.ENS_RESPONSE_TTL || '300', 10);

    console.log('--- Configuration ---');
    console.log(`Gateway URL: ${gatewayURL}`);
    console.log(`Signer: ${signerAddress}`);
    console.log(`Response TTL: ${responseTTL}s\n`);

    // Deploy OmniBazaarResolver
    console.log('--- Deploying OmniBazaarResolver ---');

    const OmniBazaarResolver = await ethers.getContractFactory('OmniBazaarResolver');

    console.log('Deploying...');
    const resolver = await OmniBazaarResolver.deploy(
        [gatewayURL],
        signerAddress,
        responseTTL
    );

    await resolver.waitForDeployment();
    const resolverAddress = await resolver.getAddress();
    console.log(`OmniBazaarResolver deployed to: ${resolverAddress}`);

    // Get deployment receipt
    const deploymentTx = resolver.deploymentTransaction();
    const receipt = deploymentTx ? await deploymentTx.wait() : null;

    // Prepare result
    const result: DeploymentResult = {
        contractAddress: resolverAddress,
        network: networkName,
        timestamp: new Date().toISOString(),
        blockNumber: receipt?.blockNumber || 0,
        transactionHash: receipt?.hash || '',
        gatewayURLs: [gatewayURL],
        signerAddress,
        responseTTL
    };

    // Save deployment
    saveDeploymentConfig(networkName, result);

    // Print summary
    console.log('\n========================================');
    console.log('Deployment Complete');
    console.log('========================================');
    console.log(`OmniBazaarResolver: ${resolverAddress}`);
    console.log(`Owner: ${deployerAddress}`);
    console.log(`Signer: ${signerAddress}`);
    console.log(`Gateway: ${gatewayURL}`);
    console.log(`TTL: ${responseTTL}s`);
    console.log(`Block: ${result.blockNumber}`);
    console.log(`Tx: ${result.transactionHash}`);

    // Print next steps
    console.log('\n--- Next Steps ---');
    console.log('1. Set this resolver for omnibazaar.eth on ENS:');
    console.log(`   ENS Registry.setResolver(namehash("omnibazaar.eth"), ${resolverAddress})`);
    console.log('\n2. Configure DNS: ens-gateway.omnibazaar.com -> validator IP');
    console.log('\n3. Set up TLS (HTTPS required for CCIP-Read)');
    console.log('========================================\n');
}

// Execute
main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error('Deployment failed:', error);
        process.exit(1);
    });
