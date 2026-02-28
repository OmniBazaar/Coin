/**
 * @file deploy-trustless-tier3.js
 * @description Deployment script for Trustless Tier 3 contracts:
 *   OmniPriceOracle (UUPS), OmniArbitration (UUPS), OmniMarketplace (UUPS),
 *   OmniENS (direct), OmniChatFee (direct)
 *
 * Usage:
 *   npx hardhat run scripts/deploy-trustless-tier3.js --network fuji
 *
 * Prerequisites:
 *   - OmniCore, OmniParticipation, MinimalEscrow, OmniCoin, StakingRewardPool
 *     must already be deployed (addresses read from Coin/deployments/*.json)
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
        return JSON.parse(fs.readFileSync(deploymentPath, 'utf-8'));
    }
    return {};
}

/**
 * Save updated deployment configuration with new contract addresses
 * @param {string} network - Network name
 * @param {object} newContracts - Map of contract name to address
 */
function saveDeploymentConfig(network, newContracts) {
    const deploymentPath = path.join(
        __dirname, '..', 'deployments', `${network}.json`
    );
    let config = {};
    if (fs.existsSync(deploymentPath)) {
        config = JSON.parse(fs.readFileSync(deploymentPath, 'utf-8'));
    }
    if (!config.contracts) {
        config.contracts = {};
    }
    for (const [name, address] of Object.entries(newContracts)) {
        config.contracts[name] = address;
    }
    config.upgradedAt = new Date().toISOString();
    fs.writeFileSync(deploymentPath, JSON.stringify(config, null, 2));
    console.log(`Saved deployment to ${deploymentPath}`);
}

/**
 * Require a contract address from existing config, throw if missing
 * @param {object} contracts - Existing contracts map
 * @param {string} name - Contract name
 * @returns {string} Contract address
 */
function requireAddress(contracts, name) {
    const addr = contracts[name];
    if (!addr || addr === ethers.ZeroAddress) {
        throw new Error(
            `${name} address not found in deployment config. Deploy it first.`
        );
    }
    return addr;
}

async function main() {
    console.log('='.repeat(60));
    console.log('Trustless Tier 3 Deployment');
    console.log('  OmniPriceOracle | OmniArbitration | OmniMarketplace');
    console.log('  OmniENS | OmniChatFee');
    console.log('='.repeat(60) + '\n');

    // ─── 1. Network info ───
    const network = await ethers.provider.getNetwork();
    const chainId = Number(network.chainId);
    let networkName = network.name;
    if (networkName === 'unknown') {
        networkName = chainId === 131313 ? 'fuji' : 'localhost';
    }
    console.log(`Network: ${networkName} (chainId: ${chainId})`);

    const [deployer] = await ethers.getSigners();
    const deployerAddr = await deployer.getAddress();
    console.log(`Deployer: ${deployerAddr}`);

    const bal = await ethers.provider.getBalance(deployerAddr);
    console.log(`Balance: ${ethers.formatEther(bal)} AVAX\n`);

    // ─── 2. Load existing config ───
    const configKey = networkName === 'omnicoinFuji' ? 'fuji' : networkName;
    const existing = loadDeploymentConfig(configKey);
    const contracts = existing.contracts || existing;

    const omniCoreAddr = requireAddress(contracts, 'OmniCore');
    const participationAddr = requireAddress(contracts, 'OmniParticipation');
    const escrowAddr = requireAddress(contracts, 'MinimalEscrow');
    const xomAddr = requireAddress(contracts, 'OmniCoin');
    const stakingPoolAddr = requireAddress(contracts, 'StakingRewardPool');
    const oddaoAddr = deployerAddr; // Deployer acts as ODDAO treasury for now

    console.log('Dependencies:');
    console.log(`  OmniCore:         ${omniCoreAddr}`);
    console.log(`  OmniParticipation:${participationAddr}`);
    console.log(`  MinimalEscrow:    ${escrowAddr}`);
    console.log(`  OmniCoin (XOM):   ${xomAddr}`);
    console.log(`  StakingRewardPool:${stakingPoolAddr}`);
    console.log(`  ODDAO Treasury:   ${oddaoAddr}\n`);

    const deployed = {};

    // ─── 3. Deploy OmniPriceOracle (UUPS) ───
    console.log('Deploying OmniPriceOracle (UUPS proxy)...');
    const OmniPriceOracle = await ethers.getContractFactory('OmniPriceOracle');
    const oracleProxy = await upgrades.deployProxy(
        OmniPriceOracle,
        [omniCoreAddr],
        { initializer: 'initialize', kind: 'uups' }
    );
    await oracleProxy.waitForDeployment();
    const oracleAddr = await oracleProxy.getAddress();
    const oracleImpl = await upgrades.erc1967.getImplementationAddress(oracleAddr);
    console.log(`  Proxy:          ${oracleAddr}`);
    console.log(`  Implementation: ${oracleImpl}`);
    deployed.OmniPriceOracle = oracleAddr;
    deployed.OmniPriceOracleImplementation = oracleImpl;

    // Grant VALIDATOR_ROLE to deployer for price submissions
    const oracle = await ethers.getContractAt('OmniPriceOracle', oracleAddr);
    const VALIDATOR_ROLE = await oracle.VALIDATOR_ROLE();
    const grantTx = await oracle.grantRole(VALIDATOR_ROLE, deployerAddr);
    await grantTx.wait();
    console.log(`  Granted VALIDATOR_ROLE to deployer\n`);

    // ─── 4. Deploy OmniArbitration (UUPS) ───
    console.log('Deploying OmniArbitration (UUPS proxy)...');
    const OmniArbitration = await ethers.getContractFactory('OmniArbitration');
    const arbProxy = await upgrades.deployProxy(
        OmniArbitration,
        [participationAddr, escrowAddr, xomAddr, oddaoAddr],
        { initializer: 'initialize', kind: 'uups' }
    );
    await arbProxy.waitForDeployment();
    const arbAddr = await arbProxy.getAddress();
    const arbImpl = await upgrades.erc1967.getImplementationAddress(arbAddr);
    console.log(`  Proxy:          ${arbAddr}`);
    console.log(`  Implementation: ${arbImpl}\n`);
    deployed.OmniArbitration = arbAddr;
    deployed.OmniArbitrationImplementation = arbImpl;

    // ─── 5. Deploy OmniMarketplace (UUPS) ───
    console.log('Deploying OmniMarketplace (UUPS proxy)...');
    const OmniMarketplace = await ethers.getContractFactory('OmniMarketplace');
    const mktProxy = await upgrades.deployProxy(
        OmniMarketplace,
        [],
        { initializer: 'initialize', kind: 'uups' }
    );
    await mktProxy.waitForDeployment();
    const mktAddr = await mktProxy.getAddress();
    const mktImpl = await upgrades.erc1967.getImplementationAddress(mktAddr);
    console.log(`  Proxy:          ${mktAddr}`);
    console.log(`  Implementation: ${mktImpl}\n`);
    deployed.OmniMarketplace = mktAddr;
    deployed.OmniMarketplaceImplementation = mktImpl;

    // ─── 6. Deploy OmniENS (direct) ───
    console.log('Deploying OmniENS...');
    const OmniENS = await ethers.getContractFactory('OmniENS');
    const ens = await OmniENS.deploy(xomAddr, oddaoAddr);
    await ens.waitForDeployment();
    const ensAddr = await ens.getAddress();
    console.log(`  Address: ${ensAddr}\n`);
    deployed.OmniENS = ensAddr;

    // ─── 7. Deploy OmniChatFee (direct) ───
    console.log('Deploying OmniChatFee...');
    const OmniChatFee = await ethers.getContractFactory('OmniChatFee');
    const baseFee = ethers.parseEther('0.001'); // 0.001 XOM per message
    const chatFee = await OmniChatFee.deploy(
        xomAddr, stakingPoolAddr, oddaoAddr, baseFee
    );
    await chatFee.waitForDeployment();
    const chatAddr = await chatFee.getAddress();
    console.log(`  Address: ${chatAddr}\n`);
    deployed.OmniChatFee = chatAddr;

    // ─── 8. Save deployment ───
    saveDeploymentConfig(configKey, deployed);

    // ─── 9. Summary ───
    console.log('='.repeat(60));
    console.log('Deployment Complete');
    console.log('='.repeat(60));
    for (const [name, addr] of Object.entries(deployed)) {
        console.log(`  ${name}: ${addr}`);
    }

    if (configKey !== 'localhost' && configKey !== 'hardhat') {
        console.log('\n# Next Steps:');
        console.log(`cd /home/rickc/OmniBazaar && ./scripts/sync-contract-addresses.sh ${configKey}`);
    }
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error('Deployment failed:', error);
        process.exit(1);
    });
