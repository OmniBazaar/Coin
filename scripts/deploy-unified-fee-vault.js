/**
 * @file deploy-unified-fee-vault.js
 * @description Deployment script for UnifiedFeeVault contract as UUPS proxy
 *
 * Usage:
 *   npx hardhat run scripts/deploy-unified-fee-vault.js --network fuji
 *   npx hardhat run scripts/deploy-unified-fee-vault.js --network localhost
 *
 * Environment Variables:
 *   STAKING_POOL_ADDRESS     - Override StakingRewardPool address
 *   PROTOCOL_TREASURY_ADDRESS - Override Protocol Treasury address
 *
 * This script:
 *   1. Deploys UnifiedFeeVault as UUPS proxy
 *   2. Grants DEPOSITOR_ROLE to existing fee-generating contracts
 *   3. Updates Coin/deployments/fuji.json with new addresses
 */

const { ethers, upgrades } = require('hardhat');
const fs = require('fs');
const path = require('path');

/**
 * Load existing deployment configuration for the given network
 * @param {string} network - Network name (e.g., 'fuji', 'localhost')
 * @returns {object} Parsed deployment JSON, or empty object
 */
function loadDeploymentConfig(network) {
    const deploymentPath = path.join(
        __dirname, '..', 'deployments', `${network}.json`
    );

    if (fs.existsSync(deploymentPath)) {
        const content = fs.readFileSync(deploymentPath, 'utf-8');
        return JSON.parse(content);
    }

    return {};
}

/**
 * Save updated deployment configuration with UnifiedFeeVault addresses
 * @param {string} network - Network name
 * @param {string} proxyAddress - UnifiedFeeVault proxy address
 * @param {string} implAddress - Implementation address
 */
function saveDeploymentConfig(network, proxyAddress, implAddress) {
    const deploymentPath = path.join(
        __dirname, '..', 'deployments', `${network}.json`
    );

    let config = {};
    if (fs.existsSync(deploymentPath)) {
        const content = fs.readFileSync(deploymentPath, 'utf-8');
        config = JSON.parse(content);
    }

    if (!config.contracts) {
        config.contracts = {};
    }

    config.contracts.UnifiedFeeVault = proxyAddress;
    config.contracts.UnifiedFeeVaultImplementation = implAddress;
    config.upgradedAt = new Date().toISOString();

    fs.writeFileSync(deploymentPath, JSON.stringify(config, null, 2));
    console.log(`Saved deployment to ${deploymentPath}`);
}

/**
 * Main deployment function for UnifiedFeeVault
 */
async function main() {
    console.log('='.repeat(50));
    console.log('UnifiedFeeVault Deployment (UUPS Proxy)');
    console.log('='.repeat(50) + '\n');

    // ─────────────────────────────────────────────────
    // 1. Network and deployer information
    // ─────────────────────────────────────────────────
    const network = await ethers.provider.getNetwork();
    const networkName = network.name === 'unknown'
        ? 'localhost'
        : network.name;
    console.log(`Network: ${networkName} (chainId: ${network.chainId})`);

    const [deployer] = await ethers.getSigners();
    const deployerAddress = await deployer.getAddress();
    console.log(`Deployer: ${deployerAddress}`);

    const nativeBalance = await ethers.provider.getBalance(
        deployerAddress
    );
    console.log(
        `Native balance: ${ethers.formatEther(nativeBalance)} AVAX\n`
    );

    // ─────────────────────────────────────────────────
    // 2. Resolve dependent contract addresses
    // ─────────────────────────────────────────────────
    const configKey = networkName === 'omnicoinFuji'
        ? 'fuji'
        : networkName;
    const existingConfig = loadDeploymentConfig(configKey);
    const contracts = existingConfig.contracts || existingConfig;

    const stakingPoolAddress =
        process.env.STAKING_POOL_ADDRESS ||
        contracts.StakingRewardPool ||
        '';
    if (!stakingPoolAddress) {
        throw new Error(
            'StakingRewardPool address not found. Deploy it first ' +
            'or set STAKING_POOL_ADDRESS env var.'
        );
    }
    console.log(`StakingRewardPool: ${stakingPoolAddress}`);

    // Protocol treasury defaults to deployer if not set
    const protocolTreasuryAddress =
        process.env.PROTOCOL_TREASURY_ADDRESS || deployerAddress;
    console.log(`Protocol Treasury: ${protocolTreasuryAddress}\n`);

    // ─────────────────────────────────────────────────
    // 3. Deploy UnifiedFeeVault as UUPS proxy
    // ─────────────────────────────────────────────────
    console.log(
        'Deploying UnifiedFeeVault implementation + ERC1967Proxy...'
    );

    const UnifiedFeeVault = await ethers.getContractFactory(
        'UnifiedFeeVault'
    );

    const proxy = await upgrades.deployProxy(
        UnifiedFeeVault,
        [deployerAddress, stakingPoolAddress, protocolTreasuryAddress],
        { initializer: 'initialize', kind: 'uups' }
    );
    await proxy.waitForDeployment();

    const proxyAddress = await proxy.getAddress();
    const implAddress =
        await upgrades.erc1967.getImplementationAddress(proxyAddress);

    console.log(`Proxy address:          ${proxyAddress}`);
    console.log(`Implementation address: ${implAddress}\n`);

    // ─────────────────────────────────────────────────
    // 4. Verify roles
    // ─────────────────────────────────────────────────
    const vault = await ethers.getContractAt(
        'UnifiedFeeVault',
        proxyAddress
    );
    const DEFAULT_ADMIN_ROLE = await vault.DEFAULT_ADMIN_ROLE();
    const ADMIN_ROLE = await vault.ADMIN_ROLE();
    const BRIDGE_ROLE = await vault.BRIDGE_ROLE();
    const DEPOSITOR_ROLE = await vault.DEPOSITOR_ROLE();

    console.log('Verifying roles...');
    console.log(
        `  DEFAULT_ADMIN_ROLE → deployer: ` +
        `${await vault.hasRole(DEFAULT_ADMIN_ROLE, deployerAddress)}`
    );
    console.log(
        `  ADMIN_ROLE         → deployer: ` +
        `${await vault.hasRole(ADMIN_ROLE, deployerAddress)}`
    );
    console.log(
        `  BRIDGE_ROLE        → deployer: ` +
        `${await vault.hasRole(BRIDGE_ROLE, deployerAddress)}`
    );

    // ─────────────────────────────────────────────────
    // 5. Grant DEPOSITOR_ROLE to fee-generating contracts
    // ─────────────────────────────────────────────────
    const feeContracts = {
        MinimalEscrow: contracts.MinimalEscrow,
        DEXSettlement: contracts.DEXSettlement,
        OmniFeeRouter: contracts.OmniFeeRouter,
        OmniPredictionRouter: contracts.OmniPredictionRouter,
        OmniYieldFeeCollector: contracts.OmniYieldFeeCollector,
    };

    // Add RWA contracts if present
    if (contracts.rwa) {
        if (contracts.rwa.RWAAMM) {
            feeContracts.RWAAMM = contracts.rwa.RWAAMM;
        }
        if (contracts.rwa.RWAFeeCollector) {
            feeContracts.RWAFeeCollector =
                contracts.rwa.RWAFeeCollector;
        }
    }

    console.log('\nGranting DEPOSITOR_ROLE to fee contracts...');
    for (const [name, addr] of Object.entries(feeContracts)) {
        if (addr) {
            const tx = await vault.grantRole(DEPOSITOR_ROLE, addr);
            await tx.wait();
            console.log(`  ${name}: ${addr} ✓`);
        } else {
            console.log(`  ${name}: not deployed (skipped)`);
        }
    }

    // ─────────────────────────────────────────────────
    // 6. Verify contract state
    // ─────────────────────────────────────────────────
    console.log('\nVerifying contract state...');
    console.log(
        `  stakingPool:       ${await vault.stakingPool()}`
    );
    console.log(
        `  protocolTreasury:  ${await vault.protocolTreasury()}`
    );
    console.log(
        `  isOssified:        ${await vault.isOssified()}`
    );
    console.log(
        `  ODDAO_BPS:         ${await vault.ODDAO_BPS()} (70%)`
    );
    console.log(
        `  STAKING_BPS:       ${await vault.STAKING_BPS()} (20%)`
    );
    console.log(
        `  PROTOCOL_BPS:      ${await vault.PROTOCOL_BPS()} (10%)`
    );

    // ─────────────────────────────────────────────────
    // 7. Update deployments/fuji.json
    // ─────────────────────────────────────────────────
    saveDeploymentConfig(configKey, proxyAddress, implAddress);

    // ─────────────────────────────────────────────────
    // 8. Summary
    // ─────────────────────────────────────────────────
    console.log('\n' + '='.repeat(50));
    console.log('Deployment Complete');
    console.log('='.repeat(50));
    console.log(`Proxy:          ${proxyAddress}`);
    console.log(`Implementation: ${implAddress}`);
    console.log(`StakingPool:    ${stakingPoolAddress}`);
    console.log(`Treasury:       ${protocolTreasuryAddress}`);
    console.log(`Network:        ${configKey}`);

    if (configKey !== 'localhost' && configKey !== 'hardhat') {
        console.log('\n' + '='.repeat(50));
        console.log('Next Steps');
        console.log('='.repeat(50));
        console.log('\n# Verify implementation contract:');
        console.log(
            `npx hardhat verify --network ${configKey} ${implAddress}`
        );
        console.log('\n# Sync addresses to all modules:');
        console.log(
            `cd /home/rickc/OmniBazaar && ` +
            `./scripts/sync-contract-addresses.sh ${configKey}`
        );
        console.log(
            '\n# Update fee-generating contracts to deposit to vault:'
        );
        console.log(
            '# (see FIX_FEE_PAYMENTS.md for migration steps)'
        );
    }
}

// Execute
main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error('Deployment failed:', error);
        process.exit(1);
    });
