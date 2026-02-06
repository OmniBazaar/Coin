/**
 * @file deploy-staking-pool.js
 * @description Deployment script for StakingRewardPool contract as UUPS proxy
 *
 * Usage:
 *   npx hardhat run scripts/deploy-staking-pool.js --network fuji
 *   npx hardhat run scripts/deploy-staking-pool.js --network localhost
 *
 * Environment Variables:
 *   PRIVATE_KEY      - Deployer private key (optional, uses hardhat default signer)
 *   OMNICORE_ADDRESS - Override OmniCore proxy address (optional, reads from fuji.json)
 *   OMNICOIN_ADDRESS - Override OmniCoin token address (optional, reads from fuji.json)
 *
 * This script:
 *   1. Deploys StakingRewardPool implementation contract
 *   2. Deploys ERC1967Proxy with initialize(omniCoreAddress, xomTokenAddress)
 *   3. Grants ADMIN_ROLE to the deployer
 *   4. Funds the pool with 1,000,000 XOM if deployer has sufficient balance
 *   5. Updates Coin/deployments/fuji.json with the new contract addresses
 *   6. Logs all deployed addresses for verification
 */

const { ethers, upgrades } = require('hardhat');
const fs = require('fs');
const path = require('path');

/** Initial pool funding amount: 1,000,000 XOM (18 decimals) */
const INITIAL_FUNDING = ethers.parseEther('1000000');

/**
 * Load existing deployment configuration for the given network
 * @param {string} network - Network name (e.g., 'fuji', 'localhost')
 * @returns {object} Parsed deployment JSON, or empty object if not found
 */
function loadDeploymentConfig(network) {
    const deploymentPath = path.join(__dirname, '..', 'deployments', `${network}.json`);

    if (fs.existsSync(deploymentPath)) {
        const content = fs.readFileSync(deploymentPath, 'utf-8');
        return JSON.parse(content);
    }

    return {};
}

/**
 * Save updated deployment configuration to disk
 * @param {string} network - Network name
 * @param {string} proxyAddress - StakingRewardPool proxy address
 * @param {string} implementationAddress - StakingRewardPool implementation address
 */
function saveDeploymentConfig(network, proxyAddress, implementationAddress) {
    const deploymentPath = path.join(__dirname, '..', 'deployments', `${network}.json`);

    let config = {};
    if (fs.existsSync(deploymentPath)) {
        const content = fs.readFileSync(deploymentPath, 'utf-8');
        config = JSON.parse(content);
    }

    // Ensure contracts object exists
    if (!config.contracts) {
        config.contracts = {};
    }

    // Add StakingRewardPool entry
    config.contracts.StakingRewardPool = proxyAddress;
    config.contracts.StakingRewardPoolImplementation = implementationAddress;

    // Update timestamp
    config.upgradedAt = new Date().toISOString();

    fs.writeFileSync(deploymentPath, JSON.stringify(config, null, 2));
    console.log(`Saved deployment to ${deploymentPath}`);
}

/**
 * Main deployment function for StakingRewardPool
 */
async function main() {
    console.log('========================================');
    console.log('StakingRewardPool Deployment (UUPS Proxy)');
    console.log('========================================\n');

    // ---------------------------------------------------------------
    // 1. Network and deployer information
    // ---------------------------------------------------------------
    const network = await ethers.provider.getNetwork();
    const networkName = network.name === 'unknown' ? 'localhost' : network.name;
    console.log(`Network: ${networkName} (chainId: ${network.chainId})`);

    const [deployer] = await ethers.getSigners();
    const deployerAddress = await deployer.getAddress();
    console.log(`Deployer: ${deployerAddress}`);

    const nativeBalance = await ethers.provider.getBalance(deployerAddress);
    console.log(`Native balance: ${ethers.formatEther(nativeBalance)} AVAX\n`);

    // ---------------------------------------------------------------
    // 2. Resolve OmniCore and OmniCoin addresses
    // ---------------------------------------------------------------
    const existingConfig = loadDeploymentConfig(networkName === 'omnicoinFuji' ? 'fuji' : networkName);
    const contracts = existingConfig.contracts || existingConfig;

    const omniCoreAddress = process.env.OMNICORE_ADDRESS || contracts.OmniCore || '';
    if (!omniCoreAddress) {
        throw new Error(
            'OmniCore address not found. Set OMNICORE_ADDRESS env var or deploy OmniCore first.'
        );
    }
    console.log(`OmniCore address: ${omniCoreAddress}`);

    const omniCoinAddress = process.env.OMNICOIN_ADDRESS || contracts.OmniCoin || '';
    if (!omniCoinAddress) {
        throw new Error(
            'OmniCoin address not found. Set OMNICOIN_ADDRESS env var or deploy OmniCoin first.'
        );
    }
    console.log(`OmniCoin (XOM) address: ${omniCoinAddress}`);

    // Verify OmniCoin contract is reachable
    const omniCoin = await ethers.getContractAt('OmniCoin', omniCoinAddress);
    const tokenSymbol = await omniCoin.symbol();
    const tokenDecimals = await omniCoin.decimals();
    console.log(`Verified token: ${tokenSymbol} (${tokenDecimals} decimals)\n`);

    // ---------------------------------------------------------------
    // 3. Deploy StakingRewardPool as UUPS proxy
    // ---------------------------------------------------------------
    console.log('Deploying StakingRewardPool implementation + ERC1967Proxy...');

    const StakingRewardPool = await ethers.getContractFactory('StakingRewardPool');

    const proxy = await upgrades.deployProxy(
        StakingRewardPool,
        [omniCoreAddress, omniCoinAddress],
        {
            initializer: 'initialize',
            kind: 'uups',
        }
    );

    await proxy.waitForDeployment();
    const proxyAddress = await proxy.getAddress();

    // Retrieve the implementation address behind the proxy
    const implementationAddress = await upgrades.erc1967.getImplementationAddress(proxyAddress);

    console.log(`Proxy address:          ${proxyAddress}`);
    console.log(`Implementation address: ${implementationAddress}\n`);

    // ---------------------------------------------------------------
    // 4. Verify ADMIN_ROLE was granted to deployer during initialize
    // ---------------------------------------------------------------
    const stakingPool = await ethers.getContractAt('StakingRewardPool', proxyAddress);
    const ADMIN_ROLE = await stakingPool.ADMIN_ROLE();
    const hasAdminRole = await stakingPool.hasRole(ADMIN_ROLE, deployerAddress);

    if (hasAdminRole) {
        console.log(`ADMIN_ROLE granted to deployer: ${deployerAddress}`);
    } else {
        console.log('WARNING: Deployer does not have ADMIN_ROLE. Granting now...');
        const grantTx = await stakingPool.grantRole(ADMIN_ROLE, deployerAddress);
        await grantTx.wait();
        console.log(`ADMIN_ROLE granted to deployer: ${deployerAddress}`);
    }

    // ---------------------------------------------------------------
    // 5. Fund the pool with 1,000,000 XOM if deployer has enough
    // ---------------------------------------------------------------
    const deployerXOMBalance = await omniCoin.balanceOf(deployerAddress);
    console.log(`\nDeployer XOM balance: ${ethers.formatEther(deployerXOMBalance)} XOM`);

    if (deployerXOMBalance >= INITIAL_FUNDING) {
        console.log(`Funding pool with ${ethers.formatEther(INITIAL_FUNDING)} XOM...`);

        // Approve the staking pool to pull tokens
        const approveTx = await omniCoin.approve(proxyAddress, INITIAL_FUNDING);
        await approveTx.wait();
        console.log(`Approved ${ethers.formatEther(INITIAL_FUNDING)} XOM for pool`);

        // Deposit to pool
        const depositTx = await stakingPool.depositToPool(INITIAL_FUNDING);
        const depositReceipt = await depositTx.wait();
        console.log(`Deposit tx: ${depositReceipt.hash}`);

        // Verify pool balance
        const poolBalance = await stakingPool.getPoolBalance();
        console.log(`Pool balance: ${ethers.formatEther(poolBalance)} XOM`);
    } else {
        console.log(
            `Skipping pool funding: deployer has ${ethers.formatEther(deployerXOMBalance)} XOM, ` +
            `need ${ethers.formatEther(INITIAL_FUNDING)} XOM`
        );
    }

    // ---------------------------------------------------------------
    // 6. Verify contract state
    // ---------------------------------------------------------------
    console.log('\nVerifying contract state...');

    const tier1APR = await stakingPool.tierAPR(1);
    const tier5APR = await stakingPool.tierAPR(5);
    const durationBonus3 = await stakingPool.durationBonusAPR(3);
    const totalDep = await stakingPool.totalDeposited();
    const totalDist = await stakingPool.totalDistributed();

    console.log(`  Tier 1 APR: ${Number(tier1APR) / 100}%`);
    console.log(`  Tier 5 APR: ${Number(tier5APR) / 100}%`);
    console.log(`  Duration Bonus Tier 3: +${Number(durationBonus3) / 100}%`);
    console.log(`  Total deposited: ${ethers.formatEther(totalDep)} XOM`);
    console.log(`  Total distributed: ${ethers.formatEther(totalDist)} XOM`);

    // ---------------------------------------------------------------
    // 7. Update deployments/fuji.json
    // ---------------------------------------------------------------
    const saveNetworkName = networkName === 'omnicoinFuji' ? 'fuji' : networkName;
    saveDeploymentConfig(saveNetworkName, proxyAddress, implementationAddress);

    // ---------------------------------------------------------------
    // 8. Summary
    // ---------------------------------------------------------------
    console.log('\n========================================');
    console.log('Deployment Complete');
    console.log('========================================');
    console.log(`Proxy:          ${proxyAddress}`);
    console.log(`Implementation: ${implementationAddress}`);
    console.log(`OmniCore:       ${omniCoreAddress}`);
    console.log(`XOM Token:      ${omniCoinAddress}`);
    console.log(`Network:        ${saveNetworkName}`);

    if (saveNetworkName !== 'localhost' && saveNetworkName !== 'hardhat') {
        console.log('\n========================================');
        console.log('Next Steps');
        console.log('========================================');
        console.log(`\n# Verify implementation contract:`);
        console.log(`npx hardhat verify --network ${saveNetworkName} ${implementationAddress}`);
        console.log(`\n# Sync addresses to all modules:`);
        console.log(`cd /home/rickc/OmniBazaar && ./scripts/sync-contract-addresses.sh ${saveNetworkName}`);
    }
}

// Execute
main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error('Deployment failed:', error);
        process.exit(1);
    });
