/**
 * @file deploy-all-mainnet-v2.js
 * @description Unified deployment script for OmniCoin L1 Mainnet v2 (chain 88008)
 *
 * Deploys ALL ~55 contracts in dependency order, performs role assignments,
 * cross-contract wiring, token funding, and seed validator provisioning.
 *
 * Usage:
 *   MAINNET_DEPLOYER_PRIVATE_KEY=<key> npx hardhat run scripts/deploy-all-mainnet-v2.js --network mainnet
 *
 * Prerequisites:
 *   - MAINNET_DEPLOYER_PRIVATE_KEY in .env (with 0x prefix)
 *   - Deployer has native tokens for gas on the L1 (100M allocated at genesis)
 *   - All 5 avalanchego validators healthy and producing blocks
 *   - minBaseFee > 0 (verified BEFORE running this script)
 *
 * This script is idempotent-ish: it saves addresses after each step to
 * deployments/mainnet.json. If it fails mid-way, you can inspect the JSON
 * and manually resume from the last successful step.
 *
 * Constructor signatures verified against actual Solidity source on 2026-03-14.
 */
const { ethers, upgrades } = require("hardhat");
const fs = require("fs");
const path = require("path");

// ════════════════════════════════════════════════════════════════════════
//  CONSTANTS
// ════════════════════════════════════════════════════════════════════════

/** ODDAO Treasury address (multi-sig in production) */
const ODDAO_TREASURY = "0x664B6347a69A22b35348D42E4640CA92e1609378";

/** Token pool allocations */
const LEGACY_CLAIM_FUNDING  = ethers.parseEther("4320000000");   // 4.32B XOM
const REWARD_MANAGER_WELCOME  = ethers.parseEther("1383000000"); // 1.383B XOM
const REWARD_MANAGER_REFERRAL = ethers.parseEther("2995000000"); // 2.995B XOM
const REWARD_MANAGER_FIRSTSALE = ethers.parseEther("2000000000"); // 2.0B XOM
const VALIDATOR_REWARDS_FUNDING = ethers.parseEther("6088809316"); // 6.089B XOM

/** Seed validator Ethereum addresses — from prod-validator-{1-5} keystores */
// Fill in after extracting from prod-validator-{1-5}/staking keystore files
const SEED_VALIDATORS = [];

/** Validator IPs (one per validator, matching SEED_VALIDATORS order) */
const VALIDATOR_IPS = [
    "65.108.205.116",
    "65.108.205.92",
    "65.108.205.99",
    "65.108.205.100",
    "65.108.205.101",
];

/** Deployment output file */
const DEPLOY_FILE = path.join(__dirname, "..", "deployments", "mainnet.json");

// ════════════════════════════════════════════════════════════════════════
//  HELPERS
// ════════════════════════════════════════════════════════════════════════

let deployed = {};
let txCount = 0;
let totalGasUsed = 0n;

function saveDeployment() {
    const dir = path.dirname(DEPLOY_FILE);
    if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(DEPLOY_FILE, JSON.stringify(deployed, null, 2));
}

async function logGas(label, tx) {
    const receipt = await tx.wait();
    const gas = receipt.gasUsed;
    totalGasUsed += gas;
    txCount++;
    console.log(`  ${label}: gas=${gas.toString()}, tx=${receipt.hash.slice(0, 10)}...`);
    return receipt;
}

async function deployContract(name, factory, args = []) {
    console.log(`\n--- Deploying ${name} ---`);
    const contract = await factory.deploy(...args);
    await contract.waitForDeployment();
    const addr = await contract.getAddress();
    deployed.contracts[name] = addr;
    txCount++;
    console.log(`  ${name}: ${addr}`);
    saveDeployment();
    return contract;
}

async function deployProxy(name, factory, initArgs = [], opts = {}) {
    console.log(`\n--- Deploying ${name} (UUPS Proxy) ---`);
    const proxy = await upgrades.deployProxy(factory, initArgs, {
        kind: "uups",
        ...opts,
    });
    await proxy.waitForDeployment();
    const proxyAddr = await proxy.getAddress();
    const implAddr = await upgrades.erc1967.getImplementationAddress(proxyAddr);
    deployed.contracts[name] = proxyAddr;
    deployed.contracts[`${name}Implementation`] = implAddr;
    txCount += 2; // proxy + impl
    console.log(`  ${name} proxy: ${proxyAddr}`);
    console.log(`  ${name} impl:  ${implAddr}`);
    saveDeployment();
    return proxy;
}

// ════════════════════════════════════════════════════════════════════════
//  MAIN
// ════════════════════════════════════════════════════════════════════════

async function main() {
    console.log("╔═══════════════════════════════════════════════════════════════╗");
    console.log("║  OmniCoin L1 Mainnet v2 — Unified Deployment                ║");
    console.log("╚═══════════════════════════════════════════════════════════════╝\n");

    const [deployer] = await ethers.getSigners();
    const deployerAddr = deployer.address;
    console.log("Deployer:", deployerAddr);

    const balance = await ethers.provider.getBalance(deployerAddr);
    console.log("Native balance:", ethers.formatEther(balance), "tokens");

    // Verify correct network
    const network = await ethers.provider.getNetwork();
    if (network.chainId !== 88008n) {
        throw new Error(`Wrong network! Expected chain 88008, got ${network.chainId}`);
    }
    console.log("Network: OmniCoin L1 Mainnet (chain 88008)");

    // Verify baseFee > 0 (CRITICAL safety check)
    const feeData = await ethers.provider.getFeeData();
    if (!feeData.gasPrice || feeData.gasPrice === 0n) {
        throw new Error("FATAL: baseFee is 0! Chain will halt. Do NOT proceed.");
    }
    console.log("Base fee:", feeData.gasPrice.toString(), "wei (OK — non-zero)\n");

    // Initialize deployment state
    deployed = {
        network: "mainnet",
        chainId: 88008,
        deployer: deployerAddr,
        oddaoTreasury: ODDAO_TREASURY,
        deployedAt: new Date().toISOString(),
        contracts: {},
        notes: [],
    };

    // ══════════════════════════════════════════════════════════════════
    //  TIER 1: No dependencies
    // ══════════════════════════════════════════════════════════════════
    console.log("\n═══ TIER 1: No Dependencies ═══");

    // 1. OmniForwarder — constructor()
    const OmniForwarder = await ethers.getContractFactory("OmniForwarder");
    const forwarder = await deployContract("OmniForwarder", OmniForwarder);
    const forwarderAddr = await forwarder.getAddress();

    // 2. OmniTimelockController — constructor(address[] proposers, address[] executors, address admin)
    const OmniTimelockController = await ethers.getContractFactory("OmniTimelockController");
    const timelock = await deployContract("OmniTimelockController", OmniTimelockController, [
        [deployerAddr],  // proposers (Pioneer: deployer only)
        [deployerAddr],  // executors (Pioneer: deployer only)
        deployerAddr,    // admin
    ]);
    const timelockAddr = await timelock.getAddress();

    // 3. OmniEntryPoint — constructor()
    const OmniEntryPoint = await ethers.getContractFactory("OmniEntryPoint");
    const entryPoint = await deployContract("OmniEntryPoint", OmniEntryPoint);
    const entryPointAddr = await entryPoint.getAddress();

    // 4. TestUSDC — constructor()
    const TestUSDC = await ethers.getContractFactory("TestUSDC");
    const testUSDC = await deployContract("TestUSDC", TestUSDC);
    const testUSDCAddr = await testUSDC.getAddress();

    // ══════════════════════════════════════════════════════════════════
    //  TIER 2: Depend on OmniForwarder / Timelock
    // ══════════════════════════════════════════════════════════════════
    console.log("\n═══ TIER 2: Core Tokens & Admin ═══");

    // 5. OmniCoin — constructor(address trustedForwarder_)
    const OmniCoin = await ethers.getContractFactory("OmniCoin");
    const omniCoin = await deployContract("OmniCoin", OmniCoin, [forwarderAddr]);
    const omniCoinAddr = await omniCoin.getAddress();

    // Initialize OmniCoin — mints 16.8B XOM to deployer
    console.log("  Initializing OmniCoin (minting 16.8B XOM)...");
    await logGas("initialize", await omniCoin.initialize());
    const totalSupply = await omniCoin.totalSupply();
    console.log(`  Total supply: ${ethers.formatEther(totalSupply)} XOM`);

    // 6. PrivateOmniCoin — constructor() (NOT initialized on non-COTI chain)
    const PrivateOmniCoin = await ethers.getContractFactory("PrivateOmniCoin");
    const pxom = await deployContract("PrivateOmniCoin", PrivateOmniCoin);
    const pxomAddr = await pxom.getAddress();
    deployed.notes.push("PrivateOmniCoin deployed but NOT initialized (requires COTI MPC precompiles)");

    // 7. OmniTreasury — constructor(address admin)
    const OmniTreasury = await ethers.getContractFactory("OmniTreasury");
    const treasury = await deployContract("OmniTreasury", OmniTreasury, [deployerAddr]);
    const treasuryAddr = await treasury.getAddress();

    // 8. EmergencyGuardian — constructor(address timelock, address[] initialGuardians)
    const EmergencyGuardian = await ethers.getContractFactory("EmergencyGuardian");
    const guardian = await deployContract("EmergencyGuardian", EmergencyGuardian, [
        timelockAddr,
        [deployerAddr, deployerAddr, deployerAddr, deployerAddr, deployerAddr],
    ]);
    const guardianAddr = await guardian.getAddress();

    // ══════════════════════════════════════════════════════════════════
    //  TIER 3: Core Protocol (OmniCore, LegacyBalanceClaim)
    // ══════════════════════════════════════════════════════════════════
    console.log("\n═══ TIER 3: Core Protocol ═══");

    // 9. OmniCore (UUPS proxy)
    // constructor(address trustedForwarder_)
    // initialize(address admin, address _omniCoin, address _oddaoAddress, address _stakingPoolAddress, address _protocolTreasuryAddress)
    // Note: stakingPoolAddress is temporary (deployer), updated after StakingRewardPool deploys
    const OmniCore = await ethers.getContractFactory("OmniCore");
    const omniCore = await deployProxy("OmniCore", OmniCore, [
        deployerAddr,     // admin
        omniCoinAddr,     // omniCoin
        ODDAO_TREASURY,   // oddaoAddress
        deployerAddr,     // stakingPoolAddress (temporary — updated after StakingRewardPool)
        treasuryAddr,     // protocolTreasuryAddress
    ], { constructorArgs: [forwarderAddr] });
    const omniCoreAddr = await omniCore.getAddress();

    // 10. LegacyBalanceClaim
    // constructor(address _omniCoin, address initialOwner, address[] _validators, uint256 _requiredSignatures, address trustedForwarder_)
    const LegacyBalanceClaim = await ethers.getContractFactory("LegacyBalanceClaim");
    const legacyClaim = await deployContract("LegacyBalanceClaim", LegacyBalanceClaim, [
        omniCoinAddr,       // _omniCoin
        deployerAddr,       // initialOwner
        [deployerAddr],     // _validators (Pioneer: just deployer)
        1,                  // _requiredSignatures
        forwarderAddr,      // trustedForwarder_
    ]);
    const legacyClaimAddr = await legacyClaim.getAddress();

    // ══════════════════════════════════════════════════════════════════
    //  TIER 4: Governance & Staking (depend on OmniCoin + OmniCore)
    // ══════════════════════════════════════════════════════════════════
    console.log("\n═══ TIER 4: Governance & Staking ═══");

    // 11. OmniRegistration (UUPS proxy)
    // constructor(address trustedForwarder_)
    // initialize() — no params, msg.sender gets admin roles
    const OmniRegistration = await ethers.getContractFactory("OmniRegistration");
    const registration = await deployProxy("OmniRegistration", OmniRegistration, [],
        { constructorArgs: [forwarderAddr] });
    const registrationAddr = await registration.getAddress();

    // 12. StakingRewardPool (UUPS proxy)
    // constructor(address trustedForwarder_)
    // initialize(address omniCoreAddr, address xomTokenAddr)
    const StakingRewardPool = await ethers.getContractFactory("StakingRewardPool");
    const stakingPool = await deployProxy("StakingRewardPool", StakingRewardPool, [
        omniCoreAddr,    // omniCoreAddr
        omniCoinAddr,    // xomTokenAddr
    ], { constructorArgs: [forwarderAddr] });
    const stakingPoolAddr = await stakingPool.getAddress();

    // Update OmniCore with real StakingRewardPool address
    console.log("  Updating OmniCore stakingPoolAddress...");
    await logGas("setStakingPoolAddress", await omniCore.setStakingPoolAddress(stakingPoolAddr));

    // 13. OmniGovernance (UUPS proxy)
    // constructor(address trustedForwarder_)
    // initialize(address _omniCoin, address _omniCore, address _timelock, address admin)
    const OmniGovernance = await ethers.getContractFactory("OmniGovernance");
    const governance = await deployProxy("OmniGovernance", OmniGovernance, [
        omniCoinAddr,    // _omniCoin
        omniCoreAddr,    // _omniCore
        timelockAddr,    // _timelock
        deployerAddr,    // admin
    ], { constructorArgs: [forwarderAddr] });
    const governanceAddr = await governance.getAddress();

    // 14. OmniPriceOracle (UUPS proxy — NO forwarder in constructor)
    // constructor() — bare
    // initialize(address _omniCore)
    const OmniPriceOracle = await ethers.getContractFactory("OmniPriceOracle");
    const priceOracle = await deployProxy("OmniPriceOracle", OmniPriceOracle, [
        omniCoreAddr,    // _omniCore
    ]);
    const priceOracleAddr = await priceOracle.getAddress();

    // ══════════════════════════════════════════════════════════════════
    //  TIER 5: Participation & Rewards
    // ══════════════════════════════════════════════════════════════════
    console.log("\n═══ TIER 5: Participation & Rewards ═══");

    // 15. OmniParticipation (UUPS proxy)
    // constructor(address trustedForwarder_)
    // initialize(address registrationAddr, address omniCoreAddr)
    const OmniParticipation = await ethers.getContractFactory("OmniParticipation");
    const participation = await deployProxy("OmniParticipation", OmniParticipation, [
        registrationAddr,  // registrationAddr
        omniCoreAddr,      // omniCoreAddr
    ], { constructorArgs: [forwarderAddr] });
    const participationAddr = await participation.getAddress();

    // 16. OmniRewardManager (UUPS proxy)
    // constructor(address trustedForwarder_)
    // initialize(address _omniCoin, uint256 _welcomeBonusPool, uint256 _referralBonusPool, uint256 _firstSaleBonusPool, address _admin)
    const OmniRewardManager = await ethers.getContractFactory("OmniRewardManager");
    const rewardManager = await deployProxy("OmniRewardManager", OmniRewardManager, [
        omniCoinAddr,               // _omniCoin
        REWARD_MANAGER_WELCOME,     // _welcomeBonusPool
        REWARD_MANAGER_REFERRAL,    // _referralBonusPool
        REWARD_MANAGER_FIRSTSALE,   // _firstSaleBonusPool
        deployerAddr,               // _admin
    ], { constructorArgs: [forwarderAddr] });
    const rewardManagerAddr = await rewardManager.getAddress();

    // ══════════════════════════════════════════════════════════════════
    //  TIER 6: Fee Infrastructure (ValidatorRewards + UnifiedFeeVault)
    // ══════════════════════════════════════════════════════════════════
    console.log("\n═══ TIER 6: Fee Infrastructure ═══");

    // 17. OmniValidatorRewards (UUPS proxy)
    // constructor(address trustedForwarder_)
    // initialize(address xomTokenAddr, address participationAddr, address omniCoreAddr)
    const OmniValidatorRewards = await ethers.getContractFactory("OmniValidatorRewards");
    const validatorRewards = await deployProxy("OmniValidatorRewards", OmniValidatorRewards, [
        omniCoinAddr,        // xomTokenAddr
        participationAddr,   // participationAddr
        omniCoreAddr,        // omniCoreAddr
    ], { constructorArgs: [forwarderAddr] });
    const validatorRewardsAddr = await validatorRewards.getAddress();

    // 18. UnifiedFeeVault (UUPS proxy)
    // constructor(address trustedForwarder_)
    // initialize(address admin, address _stakingPool, address _protocolTreasury)
    const UnifiedFeeVault = await ethers.getContractFactory("UnifiedFeeVault");
    const feeVault = await deployProxy("UnifiedFeeVault", UnifiedFeeVault, [
        deployerAddr,        // admin
        stakingPoolAddr,     // _stakingPool
        treasuryAddr,        // _protocolTreasury
    ], { constructorArgs: [forwarderAddr] });
    const feeVaultAddr = await feeVault.getAddress();

    // ══════════════════════════════════════════════════════════════════
    //  TIER 7: Fee-dependent contracts (need feeVault address)
    // ══════════════════════════════════════════════════════════════════
    console.log("\n═══ TIER 7: Fee-Dependent Contracts ═══");

    // 19. MinimalEscrow
    // constructor(address _omniCoin, address _privateOmniCoin, address _registry, address _feeVault, uint256 _marketplaceFeeBps, address trustedForwarder_)
    const MinimalEscrow = await ethers.getContractFactory("MinimalEscrow");
    const escrow = await deployContract("MinimalEscrow", MinimalEscrow, [
        omniCoinAddr,        // _omniCoin
        pxomAddr,            // _privateOmniCoin
        registrationAddr,    // _registry (OmniRegistration)
        feeVaultAddr,        // _feeVault (UnifiedFeeVault)
        100,                 // _marketplaceFeeBps (1%)
        forwarderAddr,       // trustedForwarder_
    ]);
    const escrowAddr = await escrow.getAddress();

    // 20. DEXSettlement
    // constructor(address _liquidityPool, address _feeVault, address trustedForwarder_)
    const DEXSettlement = await ethers.getContractFactory("DEXSettlement");
    const dexSettlement = await deployContract("DEXSettlement", DEXSettlement, [
        deployerAddr,    // _liquidityPool (Pioneer: deployer collects LP share — redeploy when LP pool exists)
        feeVaultAddr,    // _feeVault (UnifiedFeeVault)
        forwarderAddr,   // trustedForwarder_
    ]);
    const dexSettlementAddr = await dexSettlement.getAddress();
    deployed.notes.push("DEXSettlement: _liquidityPool=deployer (Pioneer placeholder, redeploy when LP pool exists)");

    // 21. OmniSwapRouter
    // constructor(address _feeVault, uint256 _swapFeeBps, address trustedForwarder_)
    const OmniSwapRouter = await ethers.getContractFactory("OmniSwapRouter");
    const swapRouter = await deployContract("OmniSwapRouter", OmniSwapRouter, [
        feeVaultAddr,    // _feeVault (UnifiedFeeVault)
        30,              // _swapFeeBps (0.3%)
        forwarderAddr,   // trustedForwarder_
    ]);
    const swapRouterAddr = await swapRouter.getAddress();

    // 22. OmniFeeRouter
    // constructor(address _feeCollector, uint256 _maxFeeBps, address trustedForwarder_)
    const OmniFeeRouter = await ethers.getContractFactory("OmniFeeRouter");
    const feeRouter = await deployContract("OmniFeeRouter", OmniFeeRouter, [
        feeVaultAddr,    // _feeCollector (UnifiedFeeVault)
        300,             // _maxFeeBps (3%)
        forwarderAddr,   // trustedForwarder_
    ]);
    const feeRouterAddr = await feeRouter.getAddress();

    // 23. OmniChatFee
    // constructor(address _xomToken, address _feeVault, uint256 _baseFee, address trustedForwarder_)
    const OmniChatFee = await ethers.getContractFactory("OmniChatFee");
    const chatFee = await deployContract("OmniChatFee", OmniChatFee, [
        omniCoinAddr,               // _xomToken
        feeVaultAddr,               // _feeVault (UnifiedFeeVault)
        ethers.parseEther("1"),     // _baseFee (1 XOM per message)
        forwarderAddr,              // trustedForwarder_
    ]);
    const chatFeeAddr = await chatFee.getAddress();

    // 24. OmniENS
    // constructor(address _xomToken, address _feeVault, address trustedForwarder_)
    const OmniENS = await ethers.getContractFactory("OmniENS");
    const ens = await deployContract("OmniENS", OmniENS, [
        omniCoinAddr,    // _xomToken
        feeVaultAddr,    // _feeVault (UnifiedFeeVault)
        forwarderAddr,   // trustedForwarder_
    ]);
    const ensAddr = await ens.getAddress();

    // 25. FeeSwapAdapter — NO trustedForwarder
    // constructor(address _router, bytes32 _defaultSource, address _owner)
    const FeeSwapAdapter = await ethers.getContractFactory("FeeSwapAdapter");
    const feeSwapAdapter = await deployContract("FeeSwapAdapter", FeeSwapAdapter, [
        swapRouterAddr,      // _router
        ethers.ZeroHash,     // _defaultSource (no default source)
        deployerAddr,        // _owner
    ]);
    const feeSwapAdapterAddr = await feeSwapAdapter.getAddress();

    // 26. OmniPredictionRouter
    // constructor(address feeVault_, uint256 maxFeeBps_, address trustedForwarder_)
    const OmniPredictionRouter = await ethers.getContractFactory("OmniPredictionRouter");
    const predictionRouter = await deployContract("OmniPredictionRouter", OmniPredictionRouter, [
        feeVaultAddr,    // feeVault_ (UnifiedFeeVault)
        200,             // maxFeeBps_ (2%)
        forwarderAddr,   // trustedForwarder_
    ]);
    const predictionRouterAddr = await predictionRouter.getAddress();

    // 27. LiquidityMining
    // constructor(address _xom, address _protocolTreasury, address _stakingPool, address trustedForwarder_)
    const LiquidityMining = await ethers.getContractFactory("LiquidityMining");
    const liquidityMining = await deployContract("LiquidityMining", LiquidityMining, [
        omniCoinAddr,      // _xom
        treasuryAddr,      // _protocolTreasury
        stakingPoolAddr,   // _stakingPool
        forwarderAddr,     // trustedForwarder_
    ]);
    const liquidityMiningAddr = await liquidityMining.getAddress();

    // 28. OmniBonding
    // constructor(address _xom, address _treasury, uint256 _initialXomPrice, address trustedForwarder_)
    const OmniBonding = await ethers.getContractFactory("OmniBonding");
    const bonding = await deployContract("OmniBonding", OmniBonding, [
        omniCoinAddr,               // _xom
        treasuryAddr,               // _treasury
        ethers.parseEther("0.001"), // _initialXomPrice (0.001 USD equivalent)
        forwarderAddr,              // trustedForwarder_
    ]);
    const bondingAddr = await bonding.getAddress();

    // 29. LiquidityBootstrappingPool
    // constructor(address _xom, address _counterAsset, uint8 _counterAssetDecimals, address _treasury, address trustedForwarder_)
    const LiquidityBootstrappingPool = await ethers.getContractFactory("LiquidityBootstrappingPool");
    const lbp = await deployContract("LiquidityBootstrappingPool", LiquidityBootstrappingPool, [
        omniCoinAddr,    // _xom
        testUSDCAddr,    // _counterAsset (TestUSDC)
        6,               // _counterAssetDecimals (USDC = 6 decimals)
        treasuryAddr,    // _treasury
        forwarderAddr,   // trustedForwarder_
    ]);
    const lbpAddr = await lbp.getAddress();

    // 30. OmniPaymaster — NO trustedForwarder
    // constructor(address entryPoint_, address xomToken_, address owner_)
    const OmniPaymaster = await ethers.getContractFactory("OmniPaymaster");
    const paymaster = await deployContract("OmniPaymaster", OmniPaymaster, [
        entryPointAddr,  // entryPoint_
        omniCoinAddr,    // xomToken_
        deployerAddr,    // owner_
    ]);
    const paymasterAddr = await paymaster.getAddress();

    // 31. OmniYieldFeeCollector — NO trustedForwarder
    // constructor(address _feeVault, uint256 _performanceFeeBps)
    const OmniYieldFeeCollector = await ethers.getContractFactory("OmniYieldFeeCollector");
    const yieldCollector = await deployContract("OmniYieldFeeCollector", OmniYieldFeeCollector, [
        feeVaultAddr,    // _feeVault
        1000,            // _performanceFeeBps (10%)
    ]);
    const yieldCollectorAddr = await yieldCollector.getAddress();

    // ══════════════════════════════════════════════════════════════════
    //  TIER 8: Dispute, Marketplace, & Remaining Core
    // ══════════════════════════════════════════════════════════════════
    console.log("\n═══ TIER 8: Dispute & Marketplace ═══");

    // 32. OmniArbitration (UUPS proxy)
    // constructor(address trustedForwarder_)
    // initialize(address _participation, address _escrow, address _xomToken, address _feeVault)
    const OmniArbitration = await ethers.getContractFactory("OmniArbitration");
    const arbitration = await deployProxy("OmniArbitration", OmniArbitration, [
        participationAddr,   // _participation
        escrowAddr,          // _escrow
        omniCoinAddr,        // _xomToken
        feeVaultAddr,        // _feeVault
    ], { constructorArgs: [forwarderAddr] });
    const arbitrationAddr = await arbitration.getAddress();

    // 33. OmniMarketplace (UUPS proxy)
    // constructor(address trustedForwarder_)
    // initialize() — no params
    const OmniMarketplace = await ethers.getContractFactory("OmniMarketplace");
    const marketplace = await deployProxy("OmniMarketplace", OmniMarketplace, [],
        { constructorArgs: [forwarderAddr] });
    const marketplaceAddr = await marketplace.getAddress();

    // ══════════════════════════════════════════════════════════════════
    //  TIER 9: Privacy contracts
    // ══════════════════════════════════════════════════════════════════
    console.log("\n═══ TIER 9: Privacy contracts ═══");

    // 34. OmniPrivacyBridge (UUPS proxy)
    // constructor(address trustedForwarder_)
    // initialize(address _omniCoin, address _privateOmniCoin)
    const OmniPrivacyBridge = await ethers.getContractFactory("OmniPrivacyBridge");
    const privacyBridge = await deployProxy("OmniPrivacyBridge", OmniPrivacyBridge, [
        omniCoinAddr,    // _omniCoin
        pxomAddr,        // _privateOmniCoin
    ], { constructorArgs: [forwarderAddr] });
    const privacyBridgeAddr = await privacyBridge.getAddress();

    // 35. OmniBridge (UUPS proxy)
    // constructor(address trustedForwarder_)
    // initialize(address _core, address admin)
    const OmniBridge = await ethers.getContractFactory("OmniBridge");
    const bridge = await deployProxy("OmniBridge", OmniBridge, [
        omniCoreAddr,    // _core
        deployerAddr,    // admin
    ], { constructorArgs: [forwarderAddr] });
    const bridgeAddr = await bridge.getAddress();

    // 36. PrivateDEX — constructor(address trustedForwarder_) — NOT initialized (requires COTI)
    const PrivateDEX = await ethers.getContractFactory("PrivateDEX");
    const privateDEX = await deployContract("PrivateDEX", PrivateDEX, [forwarderAddr]);
    const privateDEXAddr = await privateDEX.getAddress();
    deployed.notes.push("PrivateDEX deployed but NOT initialized (requires COTI MPC precompiles)");

    // 37. PrivateDEXSettlement — constructor(address trustedForwarder_) — NOT initialized (requires COTI)
    const PrivateDEXSettlement = await ethers.getContractFactory("PrivateDEXSettlement");
    const privateDEXSettlement = await deployContract("PrivateDEXSettlement", PrivateDEXSettlement, [forwarderAddr]);
    const privateDEXSettlementAddr = await privateDEXSettlement.getAddress();
    deployed.notes.push("PrivateDEXSettlement deployed but NOT initialized (requires COTI MPC precompiles)");

    // 38-40. Private token wrappers — constructor() — NOT initialized (require COTI)
    const PrivateUSDC = await ethers.getContractFactory("PrivateUSDC");
    const privateUSDC = await deployContract("PrivateUSDC", PrivateUSDC);
    deployed.notes.push("PrivateUSDC deployed but NOT initialized (requires COTI)");

    const PrivateWETH = await ethers.getContractFactory("PrivateWETH");
    const privateWETH = await deployContract("PrivateWETH", PrivateWETH);
    deployed.notes.push("PrivateWETH deployed but NOT initialized (requires COTI)");

    const PrivateWBTC = await ethers.getContractFactory("PrivateWBTC");
    const privateWBTC = await deployContract("PrivateWBTC", PrivateWBTC);
    deployed.notes.push("PrivateWBTC deployed but NOT initialized (requires COTI)");

    // ══════════════════════════════════════════════════════════════════
    //  TIER 10: ValidatorProvisioner + Bootstrap
    // ══════════════════════════════════════════════════════════════════
    console.log("\n═══ TIER 10: ValidatorProvisioner + Bootstrap ═══");

    // 41. ValidatorProvisioner (UUPS proxy)
    // constructor() — bare
    // initialize(address _owner, address _omniRegistration, address _omniParticipation, address _omniCore, address _omniValidatorRewards)
    const ValidatorProvisioner = await ethers.getContractFactory("ValidatorProvisioner");
    const provisioner = await deployProxy("ValidatorProvisioner", ValidatorProvisioner, [
        deployerAddr,          // _owner
        registrationAddr,      // _omniRegistration
        participationAddr,     // _omniParticipation
        omniCoreAddr,          // _omniCore
        validatorRewardsAddr,  // _omniValidatorRewards
    ]);
    const provisionerAddr = await provisioner.getAddress();

    // 42. Bootstrap — constructor(address _omniCoreAddress, uint256 _omniCoreChainId, string _omniCoreRpcUrl)
    const Bootstrap = await ethers.getContractFactory("Bootstrap");
    const bootstrap = await deployContract("Bootstrap", Bootstrap, [
        omniCoreAddr,    // _omniCoreAddress
        88008,           // _omniCoreChainId
        "https://rpc.omnicoin.net",  // _omniCoreRpcUrl
    ]);
    const bootstrapAddr = await bootstrap.getAddress();

    // Wire OmniCore -> Bootstrap via reinitializeV3
    console.log("  Wiring OmniCore -> Bootstrap (reinitializeV3)...");
    await logGas("reinitializeV3", await omniCore.reinitializeV3(bootstrapAddr));

    // ══════════════════════════════════════════════════════════════════
    //  TIER 11: NFT contracts
    // ══════════════════════════════════════════════════════════════════
    console.log("\n═══ TIER 11: NFT contracts ═══");

    // 43. OmniNFTCollection (implementation — clone target)
    // constructor(address trustedForwarder_)
    const OmniNFTCollection = await ethers.getContractFactory("OmniNFTCollection");
    const nftCollectionImpl = await deployContract("OmniNFTCollection", OmniNFTCollection, [forwarderAddr]);
    const nftCollectionImplAddr = await nftCollectionImpl.getAddress();

    // 44. OmniNFTFactory
    // constructor(address _implementation, address trustedForwarder_)
    const OmniNFTFactory = await ethers.getContractFactory("OmniNFTFactory");
    const nftFactory = await deployContract("OmniNFTFactory", OmniNFTFactory, [
        nftCollectionImplAddr,  // _implementation
        forwarderAddr,          // trustedForwarder_
    ]);
    const nftFactoryAddr = await nftFactory.getAddress();

    // 45. OmniNFTStaking — constructor(address trustedForwarder_)
    const OmniNFTStaking = await ethers.getContractFactory("OmniNFTStaking");
    const nftStaking = await deployContract("OmniNFTStaking", OmniNFTStaking, [forwarderAddr]);
    const nftStakingAddr = await nftStaking.getAddress();

    // 46. OmniNFTLending
    // constructor(address initialFeeVault, uint16 initialFeeBps, address trustedForwarder_)
    const OmniNFTLending = await ethers.getContractFactory("OmniNFTLending");
    const nftLending = await deployContract("OmniNFTLending", OmniNFTLending, [
        feeVaultAddr,    // initialFeeVault (UnifiedFeeVault)
        250,             // initialFeeBps (2.5%)
        forwarderAddr,   // trustedForwarder_
    ]);
    const nftLendingAddr = await nftLending.getAddress();

    // 47. OmniFractionalNFT (vault contract)
    // constructor(address initialFeeVault, uint16 initialFeeBps, address trustedForwarder_)
    const OmniFractionalNFT = await ethers.getContractFactory("OmniFractionalNFT");
    const fractionalNFT = await deployContract("OmniFractionalNFT", OmniFractionalNFT, [
        feeVaultAddr,    // initialFeeVault (UnifiedFeeVault)
        250,             // initialFeeBps (2.5%)
        forwarderAddr,   // trustedForwarder_
    ]);
    const fractionalNFTAddr = await fractionalNFT.getAddress();

    // ══════════════════════════════════════════════════════════════════
    //  TIER 12: RWA contracts
    // ══════════════════════════════════════════════════════════════════
    console.log("\n═══ TIER 12: RWA contracts ═══");

    // 48. RWAComplianceOracle — constructor(address _registrar)
    const RWAComplianceOracle = await ethers.getContractFactory("RWAComplianceOracle");
    const rwaOracle = await deployContract("RWAComplianceOracle", RWAComplianceOracle, [
        deployerAddr,    // _registrar
    ]);
    const rwaOracleAddr = await rwaOracle.getAddress();

    // 49. RWAAMM
    // constructor(address[5] _emergencyMultisig, address _feeVault, address _xomToken, address _complianceOracle, address trustedForwarder_)
    const RWAAMM = await ethers.getContractFactory("RWAAMM");
    const rwaAMM = await deployContract("RWAAMM", RWAAMM, [
        [deployerAddr, deployerAddr, deployerAddr, deployerAddr, deployerAddr], // _emergencyMultisig (Pioneer: all deployer)
        feeVaultAddr,        // _feeVault
        omniCoinAddr,        // _xomToken
        rwaOracleAddr,       // _complianceOracle
        forwarderAddr,       // trustedForwarder_
    ]);
    const rwaAMMAddr = await rwaAMM.getAddress();

    // 50. RWARouter — constructor(address _amm, address trustedForwarder_)
    const RWARouter = await ethers.getContractFactory("RWARouter");
    const rwaRouter = await deployContract("RWARouter", RWARouter, [
        rwaAMMAddr,      // _amm
        forwarderAddr,   // trustedForwarder_
    ]);
    const rwaRouterAddr = await rwaRouter.getAddress();
    // Note: RWAPool is created by RWAAMM.createPool(), not deployed directly

    // ══════════════════════════════════════════════════════════════════
    //  TIER 13: Remaining contracts
    // ══════════════════════════════════════════════════════════════════
    console.log("\n═══ TIER 13: Remaining contracts ═══");

    // 51. UpdateRegistry — constructor(address[] _signers, uint256 _threshold)
    const UpdateRegistry = await ethers.getContractFactory("UpdateRegistry");
    const updateRegistry = await deployContract("UpdateRegistry", UpdateRegistry, [
        [deployerAddr],  // _signers (Pioneer: deployer only)
        1,               // _threshold (1-of-1 for Pioneer)
    ]);
    const updateRegistryAddr = await updateRegistry.getAddress();

    // 52. ReputationCredential — constructor(address _authorizedUpdater)
    const ReputationCredential = await ethers.getContractFactory("ReputationCredential");
    const repCredential = await deployContract("ReputationCredential", ReputationCredential, [
        deployerAddr,    // _authorizedUpdater
    ]);
    const repCredentialAddr = await repCredential.getAddress();

    // 53. OmniAccountFactory — constructor(address entryPoint_)
    // NOTE: This contract creates OmniAccount internally, no separate deployment needed
    const OmniAccountFactory = await ethers.getContractFactory("OmniAccountFactory");
    const accountFactory = await deployContract("OmniAccountFactory", OmniAccountFactory, [
        entryPointAddr,  // entryPoint_
    ]);
    const accountFactoryAddr = await accountFactory.getAddress();

    console.log(`\n  All ${Object.keys(deployed.contracts).length} contracts deployed!`);
    console.log(`   Total transactions: ${txCount}`);
    saveDeployment();

    // ══════════════════════════════════════════════════════════════════
    //  PHASE B: Role Assignments (Pioneer Phase)
    // ══════════════════════════════════════════════════════════════════
    console.log("\n═══ PHASE B: Role Assignments ═══");

    // B.1 OmniCoin roles
    console.log("\n  [B.1] OmniCoin roles...");
    // MINTER_ROLE and BURNER_ROLE already granted to deployer via initialize()
    // MINTER_ROLE will be revoked AFTER funding (Phase D)

    // B.2 OmniCore roles
    console.log("  [B.2] OmniCore roles...");
    const PROVISIONER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("PROVISIONER_ROLE"));

    // Grant PROVISIONER_ROLE to ValidatorProvisioner
    await logGas("OmniCore.grantRole(PROVISIONER)", await omniCore.grantRole(PROVISIONER_ROLE, provisionerAddr));

    // B.3-B.7: OmniRegistration, OmniRewardManager, OmniValidatorRewards, OmniParticipation, StakingRewardPool
    // All deployer roles already granted via their respective initialize() calls

    // B.8 UnifiedFeeVault roles
    console.log("  [B.8] UnifiedFeeVault roles...");
    const DEPOSITOR_ROLE = await feeVault.DEPOSITOR_ROLE();
    const BRIDGE_ROLE = await feeVault.BRIDGE_ROLE();

    // Grant BRIDGE_ROLE to deployer (Pioneer)
    await logGas("UFV.grantRole(BRIDGE)", await feeVault.grantRole(BRIDGE_ROLE, deployerAddr));

    // Grant DEPOSITOR_ROLE to 7 fee-generating contracts
    console.log("  [B.8] Granting DEPOSITOR_ROLE to fee-generating contracts...");
    const feeGenerators = [
        { name: "OmniMarketplace", addr: marketplaceAddr },
        { name: "DEXSettlement", addr: dexSettlementAddr },
        { name: "OmniChatFee", addr: chatFeeAddr },
        { name: "OmniENS", addr: ensAddr },
        { name: "MinimalEscrow", addr: escrowAddr },
        { name: "OmniArbitration", addr: arbitrationAddr },
        { name: "OmniSwapRouter", addr: swapRouterAddr },
    ];
    for (const fg of feeGenerators) {
        await logGas(`UFV.DEPOSITOR->${fg.name}`, await feeVault.grantRole(DEPOSITOR_ROLE, fg.addr));
    }

    // B.9 OmniArbitration roles
    console.log("  [B.9] OmniArbitration roles...");
    const DISPUTE_ADMIN_ROLE = await arbitration.DISPUTE_ADMIN_ROLE();
    await logGas("Arb.grantRole(DISPUTE_ADMIN)", await arbitration.grantRole(DISPUTE_ADMIN_ROLE, deployerAddr));

    // B.10 OmniTreasury roles (deployer already has GOVERNANCE + GUARDIAN from constructor)

    console.log("  All Pioneer Phase roles assigned");

    // ══════════════════════════════════════════════════════════════════
    //  PHASE C: Cross-Contract Wiring
    // ══════════════════════════════════════════════════════════════════
    console.log("\n═══ PHASE C: Cross-Contract Wiring ═══");

    // C.1 OmniRegistration -> OmniRewardManager
    console.log("  [C.1] OmniRegistration -> OmniRewardManager...");
    await logGas("setOmniRewardManagerAddress",
        await registration.setOmniRewardManagerAddress(rewardManagerAddr));

    // C.2 OmniRegistration authorized recorders
    console.log("  [C.2] OmniRegistration authorized recorders...");
    await logGas("setAuthorizedRecorder(escrow)",
        await registration.setAuthorizedRecorder(escrowAddr, true));
    await logGas("setAuthorizedRecorder(dex)",
        await registration.setAuthorizedRecorder(dexSettlementAddr, true));

    // C.3 Set trusted verification key on OmniRegistration
    const VERIFICATION_KEY = "0xE13a2D66736805Fd57F765E82370C5d7b0FBdE54";
    console.log("  [C.3] Setting trusted verification key...");
    if (typeof registration.setTrustedVerificationKey === "function") {
        await logGas("setTrustedVerificationKey",
            await registration.setTrustedVerificationKey(VERIFICATION_KEY));
    } else {
        console.log("  (setTrustedVerificationKey not found — may need manual call)");
    }

    // C.4 ValidatorProvisioner role admin delegation
    console.log("  [C.4] ValidatorProvisioner role admin delegation...");

    // Delegate VALIDATOR_ROLE admin to PROVISIONER_ROLE on OmniRegistration
    await logGas("Reg.setValidatorRoleAdmin(PROVISIONER)",
        await registration.setValidatorRoleAdmin(PROVISIONER_ROLE));

    // Delegate VERIFIER_ROLE admin to PROVISIONER_ROLE on OmniParticipation
    await logGas("Part.setVerifierRoleAdmin(PROVISIONER)",
        await participation.setVerifierRoleAdmin(PROVISIONER_ROLE));

    // Delegate BLOCKCHAIN_ROLE admin to PROVISIONER_ROLE on OmniValidatorRewards
    await logGas("VR.setBlockchainRoleAdmin(PROVISIONER)",
        await validatorRewards.setBlockchainRoleAdmin(PROVISIONER_ROLE));

    // C.5 Set privacy contracts on ValidatorProvisioner (even though not initialized)
    console.log("  [C.5] ValidatorProvisioner privacy contracts...");
    await logGas("Provisioner.setPrivacyContracts",
        await provisioner.setPrivacyContracts(privateDEXAddr, privateDEXSettlementAddr));

    // C.6 OmniPaymaster registration (if applicable)
    if (typeof paymaster.setRegistration === "function") {
        console.log("  [C.6] OmniPaymaster -> OmniRegistration...");
        await logGas("Paymaster.setRegistration",
            await paymaster.setRegistration(registrationAddr));
    }

    console.log("  Cross-contract wiring complete");

    // ══════════════════════════════════════════════════════════════════
    //  PHASE D: Token Funding
    // ══════════════════════════════════════════════════════════════════
    console.log("\n═══ PHASE D: Token Funding ═══");

    const deployerBalance = await omniCoin.balanceOf(deployerAddr);
    console.log(`  Deployer XOM balance: ${ethers.formatEther(deployerBalance)} XOM`);

    const totalFunding = LEGACY_CLAIM_FUNDING + REWARD_MANAGER_WELCOME +
        REWARD_MANAGER_REFERRAL + REWARD_MANAGER_FIRSTSALE + VALIDATOR_REWARDS_FUNDING;
    console.log(`  Total to distribute: ${ethers.formatEther(totalFunding)} XOM`);

    if (deployerBalance < totalFunding) {
        throw new Error(`Insufficient XOM! Need ${ethers.formatEther(totalFunding)}, have ${ethers.formatEther(deployerBalance)}`);
    }

    // D.1 Fund LegacyBalanceClaim
    console.log("  [D.1] Funding LegacyBalanceClaim with 4.32B XOM...");
    await logGas("transfer->LegacyClaim",
        await omniCoin.transfer(legacyClaimAddr, LEGACY_CLAIM_FUNDING));

    // D.2 Fund OmniRewardManager (Welcome + Referral + FirstSale pools)
    const rewardManagerTotal = REWARD_MANAGER_WELCOME + REWARD_MANAGER_REFERRAL + REWARD_MANAGER_FIRSTSALE;
    console.log(`  [D.2] Funding OmniRewardManager with ${ethers.formatEther(rewardManagerTotal)} XOM...`);
    await logGas("transfer->RewardManager",
        await omniCoin.transfer(rewardManagerAddr, rewardManagerTotal));

    // D.3 Fund OmniValidatorRewards
    console.log(`  [D.3] Funding OmniValidatorRewards with ${ethers.formatEther(VALIDATOR_REWARDS_FUNDING)} XOM...`);
    await logGas("transfer->ValidatorRewards",
        await omniCoin.transfer(validatorRewardsAddr, VALIDATOR_REWARDS_FUNDING));

    // D.4 Verify remaining balance
    const remainder = await omniCoin.balanceOf(deployerAddr);
    console.log(`  Deployer remainder: ${ethers.formatEther(remainder)} XOM`);
    deployed.deployerRemainder = ethers.formatEther(remainder);

    // D.5 Permanently revoke MINTER_ROLE from deployer
    console.log("  [D.5] Revoking MINTER_ROLE from deployer (PERMANENT)...");
    const MINTER_ROLE = await omniCoin.MINTER_ROLE();
    await logGas("revokeRole(MINTER)", await omniCoin.revokeRole(MINTER_ROLE, deployerAddr));

    // Verify revocation
    const hasMinter = await omniCoin.hasRole(MINTER_ROLE, deployerAddr);
    if (hasMinter) {
        throw new Error("CRITICAL: MINTER_ROLE was NOT revoked!");
    }
    console.log("  MINTER_ROLE permanently revoked. No entity can mint new XOM.");

    deployed.notes.push(`Token funding: LegacyClaim=${ethers.formatEther(LEGACY_CLAIM_FUNDING)}, RewardManager=${ethers.formatEther(rewardManagerTotal)}, ValidatorRewards=${ethers.formatEther(VALIDATOR_REWARDS_FUNDING)}`);
    deployed.notes.push("MINTER_ROLE permanently revoked. 16.8B XOM total supply is FINAL.");
    saveDeployment();

    // ══════════════════════════════════════════════════════════════════
    //  PHASE E: Seed Validator Provisioning
    // ══════════════════════════════════════════════════════════════════
    console.log("\n═══ PHASE E: Seed Validator Provisioning ═══");

    if (SEED_VALIDATORS.length === 0) {
        console.log("  No seed validator addresses configured.");
        console.log("  Fill in SEED_VALIDATORS array with addresses from prod-validator-{1-5} keystores.");
        console.log("  Then run scripts/provision-seed-validators.js separately.");
        deployed.notes.push("Seed validators NOT provisioned — addresses need to be filled in");
    } else {
        for (let i = 0; i < SEED_VALIDATORS.length; i++) {
            const valAddr = SEED_VALIDATORS[i];
            console.log(`\n  [E.${i + 1}] Provisioning validator ${i + 1}: ${valAddr}`);

            // Force-provision via ValidatorProvisioner
            await logGas(`forceProvision(v${i + 1})`, await provisioner.forceProvision(valAddr));

            // Set stake exempt on OmniValidatorRewards
            await logGas(`setStakeExempt(v${i + 1})`,
                await validatorRewards.setStakeExempt(valAddr, true));

            // Register in Bootstrap
            await logGas(`Bootstrap.registerNode(v${i + 1})`,
                await bootstrap.registerNode(
                    "",                              // multiaddr (filled by validator)
                    `http://${VALIDATOR_IPS[i] || "65.108.205.116"}:9650/ext/bc/${deployed.blockchainId || "TBD"}/rpc`,
                    "",                              // wsEndpoint
                    "eu-central",                    // region
                    0,                               // nodeType 0 = gateway
                ));
        }
        deployed.notes.push(`${SEED_VALIDATORS.length} seed validators force-provisioned with stake exemption`);
    }

    saveDeployment();

    // ══════════════════════════════════════════════════════════════════
    //  SUMMARY
    // ══════════════════════════════════════════════════════════════════
    console.log("\n╔═══════════════════════════════════════════════════════════════╗");
    console.log("║  DEPLOYMENT COMPLETE                                         ║");
    console.log("╚═══════════════════════════════════════════════════════════════╝\n");
    console.log(`  Contracts deployed: ${Object.keys(deployed.contracts).length}`);
    console.log(`  Total transactions: ${txCount}`);
    console.log(`  Deployment file:    ${DEPLOY_FILE}`);
    console.log(`  Deployer remainder: ${deployed.deployerRemainder} XOM`);
    console.log(`\n  Key addresses:`);
    console.log(`    OmniCoin:         ${omniCoinAddr}`);
    console.log(`    OmniForwarder:    ${forwarderAddr}`);
    console.log(`    OmniCore:         ${omniCoreAddr}`);
    console.log(`    UnifiedFeeVault:  ${feeVaultAddr}`);
    console.log(`    OmniRegistration: ${registrationAddr}`);
    console.log(`    ValidatorProv.:   ${provisionerAddr}`);
    console.log(`    Bootstrap:        ${bootstrapAddr}`);

    console.log("\n  Next steps:");
    console.log("  1. Run scripts/verify-deployment.js --network mainnet");
    console.log("  2. Run scripts/sync-contract-addresses.sh mainnet");
    console.log("  3. Fill in SEED_VALIDATORS if not done already");
    console.log("  4. Rebuild Validator and WebApp");
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error("\n DEPLOYMENT FAILED:", error.message);
        console.error(error);
        // Save whatever was deployed so far
        if (Object.keys(deployed.contracts || {}).length > 0) {
            deployed.notes.push(`FAILED at tx ${txCount}: ${error.message}`);
            saveDeployment();
            console.error(`\n  Partial deployment saved to ${DEPLOY_FILE}`);
        }
        process.exit(1);
    });
