/**
 * @file deploy-remaining-mainnet.js
 * @description Deploy ALL remaining contracts on mainnet (chain 88008).
 *
 * This deploys everything not yet deployed (excluding Bootstrap.sol,
 * EmergencyGuardian, OmniTimelockController, deprecated contracts,
 * and COTI privacy contracts which deploy on COTI testnet).
 *
 * Deployment groups (in dependency order):
 *   1. Fee infrastructure (UnifiedFeeVault)
 *   2. Marketplace & Social (OmniMarketplace, OmniENS, OmniChatFee)
 *   3. Oracle (OmniPriceOracle)
 *   4. Arbitration (OmniArbitration)
 *   5. Software updates (UpdateRegistry)
 *   6. Liquidity (LiquidityMining, LiquidityBootstrappingPool, OmniBonding)
 *   7. NFT (OmniNFTCollection, OmniNFTFactory, OmniFractionalNFT, OmniNFTLending, OmniNFTStaking)
 *   8. RWA (RWAComplianceOracle, RWAAMM, RWAPool factory, RWARouter)
 *   9. Yield (OmniYieldFeeCollector)
 *  10. Bridge (OmniBridge)
 *  11. Account Abstraction (OmniEntryPoint, OmniAccount, OmniAccountFactory, OmniPaymaster)
 *  12. Predictions (OmniPredictionRouter)
 *  13. Reputation (ReputationCredential)
 *  14. Fee routing (OmniFeeRouter, FeeSwapAdapter)
 *  15. Privacy bridge (OmniPrivacyBridge — on our chain, bridges to COTI)
 *  16. Stablecoin (TestUSDC — counter-asset for LBP and DEX testing)
 *  17. LBP (LiquidityBootstrappingPool — fair XOM distribution)
 *
 * Usage:
 *   npx hardhat run scripts/deploy-remaining-mainnet.js --network mainnet
 */
const { ethers, upgrades } = require("hardhat");
const fs = require("fs");
const path = require("path");

/** Real ODDAO treasury address */
const ODDAO_TREASURY = "0x664B6347a69A22b35348D42E4640CA92e1609378";

/** Protocol treasury address (Pioneer Phase: deployer; update for production) */
const PROTOCOL_TREASURY = "0xaDAD7751DcDd2E30015C173F2c35a56e467CD9ba";

async function main() {
    console.log("=== Deploy ALL Remaining Contracts (Mainnet) ===\n");

    const [deployer] = await ethers.getSigners();
    console.log("Deployer:", deployer.address);

    const network = await ethers.provider.getNetwork();
    if (network.chainId !== 88008n) {
        throw new Error(`Wrong network! Expected 88008, got ${network.chainId}`);
    }

    const balance = await ethers.provider.getBalance(deployer.address);
    console.log("Native balance:", ethers.formatEther(balance), "tokens");

    // Load mainnet.json
    const deploymentFile = path.join(__dirname, "../deployments/mainnet.json");
    const deployments = JSON.parse(fs.readFileSync(deploymentFile, "utf-8"));

    const xomAddress = deployments.contracts.OmniCoin;
    const omniCoreAddress = deployments.contracts.OmniCore;
    const stakingPoolAddress = deployments.contracts.StakingRewardPool;
    const participationAddress = deployments.contracts.OmniParticipation;
    const escrowAddress = deployments.contracts.MinimalEscrow;
    const privateOmniCoinAddress = deployments.contracts.PrivateOmniCoin;

    console.log("OmniCoin:", xomAddress);
    console.log("OmniCore:", omniCoreAddress);
    console.log("StakingRewardPool:", stakingPoolAddress);
    console.log("ODDAO:", ODDAO_TREASURY);
    console.log("");

    let deployed = 0;

    // Helper to save progress after each deployment
    function save() {
        deployments.deployedAt = new Date().toISOString();
        fs.writeFileSync(deploymentFile, JSON.stringify(deployments, null, 2));
    }

    // ================================================================
    // 1. UnifiedFeeVault (UUPS)
    // ================================================================
    console.log("--- 1. UnifiedFeeVault (UUPS) ---");
    const UnifiedFeeVault = await ethers.getContractFactory("UnifiedFeeVault");
    const feeVaultProxy = await upgrades.deployProxy(
        UnifiedFeeVault,
        [deployer.address, stakingPoolAddress, ODDAO_TREASURY],
        { initializer: "initialize", kind: "uups" }
    );
    await feeVaultProxy.waitForDeployment();
    const feeVaultAddr = await feeVaultProxy.getAddress();
    const feeVaultImpl = await upgrades.erc1967.getImplementationAddress(feeVaultAddr);
    deployments.contracts.UnifiedFeeVault = feeVaultAddr;
    deployments.contracts.UnifiedFeeVaultImplementation = feeVaultImpl;
    console.log("UnifiedFeeVault:", feeVaultAddr);
    save();
    deployed++;

    // ================================================================
    // 2. OmniMarketplace (UUPS)
    // ================================================================
    console.log("--- 2. OmniMarketplace (UUPS) ---");
    const OmniMarketplace = await ethers.getContractFactory("OmniMarketplace");
    const marketplaceProxy = await upgrades.deployProxy(
        OmniMarketplace,
        [],
        { initializer: "initialize", kind: "uups" }
    );
    await marketplaceProxy.waitForDeployment();
    const marketplaceAddr = await marketplaceProxy.getAddress();
    const marketplaceImpl = await upgrades.erc1967.getImplementationAddress(marketplaceAddr);
    deployments.contracts.OmniMarketplace = marketplaceAddr;
    deployments.contracts.OmniMarketplaceImplementation = marketplaceImpl;
    console.log("OmniMarketplace:", marketplaceAddr);
    save();
    deployed++;

    // ================================================================
    // 3. OmniENS (Immutable)
    // ================================================================
    console.log("--- 3. OmniENS (Immutable) ---");
    const OmniENS = await ethers.getContractFactory("OmniENS");
    const omniENS = await OmniENS.deploy(
        xomAddress, ODDAO_TREASURY, stakingPoolAddress, PROTOCOL_TREASURY
    );
    await omniENS.waitForDeployment();
    const ensAddr = await omniENS.getAddress();
    deployments.contracts.OmniENS = ensAddr;
    console.log("OmniENS:", ensAddr);
    save();
    deployed++;

    // ================================================================
    // 4. OmniChatFee (Immutable)
    // ================================================================
    console.log("--- 4. OmniChatFee (Immutable) ---");
    const baseFee = ethers.parseEther("1"); // 1 XOM base fee per message
    const OmniChatFee = await ethers.getContractFactory("OmniChatFee");
    const chatFee = await OmniChatFee.deploy(
        xomAddress, stakingPoolAddress, ODDAO_TREASURY, PROTOCOL_TREASURY, baseFee
    );
    await chatFee.waitForDeployment();
    const chatFeeAddr = await chatFee.getAddress();
    deployments.contracts.OmniChatFee = chatFeeAddr;
    console.log("OmniChatFee:", chatFeeAddr);
    save();
    deployed++;

    // ================================================================
    // 5. OmniPriceOracle (UUPS)
    // ================================================================
    console.log("--- 5. OmniPriceOracle (UUPS) ---");
    const OmniPriceOracle = await ethers.getContractFactory("OmniPriceOracle");
    const oracleProxy = await upgrades.deployProxy(
        OmniPriceOracle,
        [omniCoreAddress],
        { initializer: "initialize", kind: "uups" }
    );
    await oracleProxy.waitForDeployment();
    const oracleAddr = await oracleProxy.getAddress();
    const oracleImpl = await upgrades.erc1967.getImplementationAddress(oracleAddr);
    deployments.contracts.OmniPriceOracle = oracleAddr;
    deployments.contracts.OmniPriceOracleImplementation = oracleImpl;
    console.log("OmniPriceOracle:", oracleAddr);
    save();
    deployed++;

    // ================================================================
    // 6. OmniArbitration (UUPS)
    // ================================================================
    console.log("--- 6. OmniArbitration (UUPS) ---");
    const OmniArbitration = await ethers.getContractFactory("OmniArbitration");
    const arbitrationProxy = await upgrades.deployProxy(
        OmniArbitration,
        [participationAddress, escrowAddress, xomAddress, ODDAO_TREASURY, PROTOCOL_TREASURY],
        { initializer: "initialize", kind: "uups" }
    );
    await arbitrationProxy.waitForDeployment();
    const arbitrationAddr = await arbitrationProxy.getAddress();
    const arbitrationImpl = await upgrades.erc1967.getImplementationAddress(arbitrationAddr);
    deployments.contracts.OmniArbitration = arbitrationAddr;
    deployments.contracts.OmniArbitrationImplementation = arbitrationImpl;
    console.log("OmniArbitration:", arbitrationAddr);
    save();
    deployed++;

    // ================================================================
    // 7. UpdateRegistry (Immutable)
    // Pioneer Phase: deployer as sole signer, threshold 1
    // ================================================================
    console.log("--- 7. UpdateRegistry (Immutable) ---");
    const UpdateRegistry = await ethers.getContractFactory("UpdateRegistry");
    const updateRegistry = await UpdateRegistry.deploy([deployer.address], 1);
    await updateRegistry.waitForDeployment();
    const updateRegistryAddr = await updateRegistry.getAddress();
    deployments.contracts.UpdateRegistry = updateRegistryAddr;
    console.log("UpdateRegistry:", updateRegistryAddr);
    save();
    deployed++;

    // ================================================================
    // 8. LiquidityMining (Immutable)
    // ================================================================
    console.log("--- 8. LiquidityMining (Immutable) ---");
    const LiquidityMining = await ethers.getContractFactory("LiquidityMining");
    const liquidityMining = await LiquidityMining.deploy(
        xomAddress,           // XOM token
        ODDAO_TREASURY,       // treasury
        deployer.address,     // validator fee recipient (deployer for Pioneer)
        stakingPoolAddress    // staking pool fee recipient
    );
    await liquidityMining.waitForDeployment();
    const liqMiningAddr = await liquidityMining.getAddress();
    deployments.contracts.LiquidityMining = liqMiningAddr;
    console.log("LiquidityMining:", liqMiningAddr);
    save();
    deployed++;

    // ================================================================
    // 9. OmniBonding (Immutable)
    // ================================================================
    console.log("--- 9. OmniBonding (Immutable) ---");
    const initialXomPrice = ethers.parseEther("0.001"); // 0.001 native tokens per XOM
    const OmniBonding = await ethers.getContractFactory("OmniBonding");
    const omniBonding = await OmniBonding.deploy(xomAddress, ODDAO_TREASURY, initialXomPrice);
    await omniBonding.waitForDeployment();
    const bondingAddr = await omniBonding.getAddress();
    deployments.contracts.OmniBonding = bondingAddr;
    console.log("OmniBonding:", bondingAddr);
    save();
    deployed++;

    // ================================================================
    // 10. RWAComplianceOracle (Immutable)
    // ================================================================
    console.log("--- 10. RWAComplianceOracle (Immutable) ---");
    const RWAComplianceOracle = await ethers.getContractFactory("RWAComplianceOracle");
    const rwaOracle = await RWAComplianceOracle.deploy(deployer.address);
    await rwaOracle.waitForDeployment();
    const rwaOracleAddr = await rwaOracle.getAddress();
    deployments.contracts.RWAComplianceOracle = rwaOracleAddr;
    console.log("RWAComplianceOracle:", rwaOracleAddr);
    save();
    deployed++;

    // ================================================================
    // 11. RWAAMM (Immutable)
    // Pioneer Phase: deployer fills all 5 emergency multisig slots
    // ================================================================
    console.log("--- 11. RWAAMM (Immutable) ---");
    const RWAAMM = await ethers.getContractFactory("RWAAMM");
    const rwaAMM = await RWAAMM.deploy(
        [deployer.address, deployer.address, deployer.address, deployer.address, deployer.address],
        feeVaultAddr,       // fee vault
        xomAddress,         // XOM token
        rwaOracleAddr       // compliance oracle
    );
    await rwaAMM.waitForDeployment();
    const rwaAMMAddr = await rwaAMM.getAddress();
    deployments.contracts.RWAAMM = rwaAMMAddr;
    console.log("RWAAMM:", rwaAMMAddr);
    save();
    deployed++;

    // ================================================================
    // 12. RWARouter (Immutable)
    // ================================================================
    console.log("--- 12. RWARouter (Immutable) ---");
    const RWARouter = await ethers.getContractFactory("RWARouter");
    const rwaRouter = await RWARouter.deploy(rwaAMMAddr);
    await rwaRouter.waitForDeployment();
    const rwaRouterAddr = await rwaRouter.getAddress();
    deployments.contracts.RWARouter = rwaRouterAddr;
    console.log("RWARouter:", rwaRouterAddr);
    save();
    deployed++;

    // ================================================================
    // 13. OmniYieldFeeCollector (Immutable)
    // ================================================================
    console.log("--- 13. OmniYieldFeeCollector (Immutable) ---");
    const performanceFeeBps = 1000; // 10% performance fee
    const OmniYieldFeeCollector = await ethers.getContractFactory("OmniYieldFeeCollector");
    const yieldFee = await OmniYieldFeeCollector.deploy(
        ODDAO_TREASURY,       // primary recipient (70%)
        ODDAO_TREASURY,       // ODDAO treasury (20%)
        PROTOCOL_TREASURY,    // protocol treasury (10%)
        performanceFeeBps     // 10% performance fee
    );
    await yieldFee.waitForDeployment();
    const yieldFeeAddr = await yieldFee.getAddress();
    deployments.contracts.OmniYieldFeeCollector = yieldFeeAddr;
    console.log("OmniYieldFeeCollector:", yieldFeeAddr);
    save();
    deployed++;

    // ================================================================
    // 14. NFT: OmniNFTCollection (implementation template for clones)
    // ================================================================
    console.log("--- 14. OmniNFTCollection (Implementation) ---");
    const OmniNFTCollection = await ethers.getContractFactory("OmniNFTCollection");
    const nftCollectionImpl = await OmniNFTCollection.deploy();
    await nftCollectionImpl.waitForDeployment();
    const nftCollectionImplAddr = await nftCollectionImpl.getAddress();
    deployments.contracts.OmniNFTCollection = nftCollectionImplAddr;
    console.log("OmniNFTCollection (impl):", nftCollectionImplAddr);
    save();
    deployed++;

    // ================================================================
    // 15. NFT: OmniNFTFactory (uses implementation above)
    // ================================================================
    console.log("--- 15. OmniNFTFactory (Immutable) ---");
    const OmniNFTFactory = await ethers.getContractFactory("OmniNFTFactory");
    const nftFactory = await OmniNFTFactory.deploy(nftCollectionImplAddr);
    await nftFactory.waitForDeployment();
    const nftFactoryAddr = await nftFactory.getAddress();
    deployments.contracts.OmniNFTFactory = nftFactoryAddr;
    console.log("OmniNFTFactory:", nftFactoryAddr);
    save();
    deployed++;

    // ================================================================
    // 16. NFT: OmniFractionalNFT (Immutable)
    // ================================================================
    console.log("--- 16. OmniFractionalNFT (Immutable) ---");
    const OmniFractionalNFT = await ethers.getContractFactory("OmniFractionalNFT");
    const fractionalNFT = await OmniFractionalNFT.deploy(ODDAO_TREASURY, 250); // 2.5% fee
    await fractionalNFT.waitForDeployment();
    const fractionalNFTAddr = await fractionalNFT.getAddress();
    deployments.contracts.OmniFractionalNFT = fractionalNFTAddr;
    console.log("OmniFractionalNFT:", fractionalNFTAddr);
    save();
    deployed++;

    // ================================================================
    // 17. NFT: OmniNFTLending (Immutable)
    // ================================================================
    console.log("--- 17. OmniNFTLending (Immutable) ---");
    const OmniNFTLending = await ethers.getContractFactory("OmniNFTLending");
    const nftLending = await OmniNFTLending.deploy(ODDAO_TREASURY, 100); // 1% fee
    await nftLending.waitForDeployment();
    const nftLendingAddr = await nftLending.getAddress();
    deployments.contracts.OmniNFTLending = nftLendingAddr;
    console.log("OmniNFTLending:", nftLendingAddr);
    save();
    deployed++;

    // ================================================================
    // 18. NFT: OmniNFTStaking (Immutable)
    // ================================================================
    console.log("--- 18. OmniNFTStaking (Immutable) ---");
    const OmniNFTStaking = await ethers.getContractFactory("OmniNFTStaking");
    const nftStaking = await OmniNFTStaking.deploy();
    await nftStaking.waitForDeployment();
    const nftStakingAddr = await nftStaking.getAddress();
    deployments.contracts.OmniNFTStaking = nftStakingAddr;
    console.log("OmniNFTStaking:", nftStakingAddr);
    save();
    deployed++;

    // ================================================================
    // 19. OmniBridge (UUPS)
    // ================================================================
    console.log("--- 19. OmniBridge (UUPS) ---");
    const OmniBridge = await ethers.getContractFactory("OmniBridge");
    const bridgeProxy = await upgrades.deployProxy(
        OmniBridge,
        [omniCoreAddress, deployer.address],
        { initializer: "initialize", kind: "uups" }
    );
    await bridgeProxy.waitForDeployment();
    const bridgeAddr = await bridgeProxy.getAddress();
    const bridgeImpl = await upgrades.erc1967.getImplementationAddress(bridgeAddr);
    deployments.contracts.OmniBridge = bridgeAddr;
    deployments.contracts.OmniBridgeImplementation = bridgeImpl;
    console.log("OmniBridge:", bridgeAddr);

    // Wire bridge fees to UnifiedFeeVault (G4 audit remediation)
    const bridgeContract = OmniBridge.attach(bridgeAddr);
    await bridgeContract.setFeeVault(feeVaultAddr);
    console.log("  -> OmniBridge.setFeeVault() →", feeVaultAddr);
    save();
    deployed++;

    // ================================================================
    // 20. Account Abstraction: OmniEntryPoint (Immutable, no constructor)
    // ================================================================
    console.log("--- 20. OmniEntryPoint (Immutable) ---");
    const OmniEntryPoint = await ethers.getContractFactory("OmniEntryPoint");
    const entryPoint = await OmniEntryPoint.deploy();
    await entryPoint.waitForDeployment();
    const entryPointAddr = await entryPoint.getAddress();
    deployments.contracts.OmniEntryPoint = entryPointAddr;
    console.log("OmniEntryPoint:", entryPointAddr);
    save();
    deployed++;

    // ================================================================
    // 21. Account Abstraction: OmniAccount (implementation template)
    // ================================================================
    console.log("--- 21. OmniAccount (Implementation) ---");
    const OmniAccount = await ethers.getContractFactory("OmniAccount");
    const accountImpl = await OmniAccount.deploy(entryPointAddr);
    await accountImpl.waitForDeployment();
    const accountImplAddr = await accountImpl.getAddress();
    deployments.contracts.OmniAccount = accountImplAddr;
    console.log("OmniAccount (impl):", accountImplAddr);
    save();
    deployed++;

    // ================================================================
    // 22. Account Abstraction: OmniAccountFactory
    // ================================================================
    console.log("--- 22. OmniAccountFactory (Immutable) ---");
    const OmniAccountFactory = await ethers.getContractFactory("OmniAccountFactory");
    const accountFactory = await OmniAccountFactory.deploy(accountImplAddr);
    await accountFactory.waitForDeployment();
    const accountFactoryAddr = await accountFactory.getAddress();
    deployments.contracts.OmniAccountFactory = accountFactoryAddr;
    console.log("OmniAccountFactory:", accountFactoryAddr);
    save();
    deployed++;

    // ================================================================
    // 23. Account Abstraction: OmniPaymaster
    // ================================================================
    console.log("--- 23. OmniPaymaster (Immutable) ---");
    const OmniPaymaster = await ethers.getContractFactory("OmniPaymaster");
    const paymaster = await OmniPaymaster.deploy(entryPointAddr, xomAddress, deployer.address);
    await paymaster.waitForDeployment();
    const paymasterAddr = await paymaster.getAddress();
    deployments.contracts.OmniPaymaster = paymasterAddr;
    console.log("OmniPaymaster:", paymasterAddr);
    save();
    deployed++;

    // ================================================================
    // 24. OmniPredictionRouter (Immutable)
    // ================================================================
    console.log("--- 24. OmniPredictionRouter (Immutable) ---");
    const maxPredFeeBps = 300; // 3% max fee
    const OmniPredictionRouter = await ethers.getContractFactory("OmniPredictionRouter");
    const predRouter = await OmniPredictionRouter.deploy(ODDAO_TREASURY, maxPredFeeBps);
    await predRouter.waitForDeployment();
    const predRouterAddr = await predRouter.getAddress();
    deployments.contracts.OmniPredictionRouter = predRouterAddr;
    console.log("OmniPredictionRouter:", predRouterAddr);
    save();
    deployed++;

    // ================================================================
    // 25. ReputationCredential (Immutable)
    // ================================================================
    console.log("--- 25. ReputationCredential (Immutable) ---");
    const ReputationCredential = await ethers.getContractFactory("ReputationCredential");
    const repCredential = await ReputationCredential.deploy(deployer.address);
    await repCredential.waitForDeployment();
    const repCredentialAddr = await repCredential.getAddress();
    deployments.contracts.ReputationCredential = repCredentialAddr;
    console.log("ReputationCredential:", repCredentialAddr);
    save();
    deployed++;

    // ================================================================
    // 26. OmniFeeRouter (Immutable)
    // ================================================================
    console.log("--- 26. OmniFeeRouter (Immutable) ---");
    const maxFeeBps = 100; // 1% max
    const OmniFeeRouter = await ethers.getContractFactory("OmniFeeRouter");
    const feeRouter = await OmniFeeRouter.deploy(ODDAO_TREASURY, maxFeeBps);
    await feeRouter.waitForDeployment();
    const feeRouterAddr = await feeRouter.getAddress();
    deployments.contracts.OmniFeeRouter = feeRouterAddr;
    console.log("OmniFeeRouter:", feeRouterAddr);
    save();
    deployed++;

    // ================================================================
    // 27. FeeSwapAdapter (Immutable)
    // Uses OmniSwapRouter address from mainnet.json
    // ================================================================
    console.log("--- 27. FeeSwapAdapter (Immutable) ---");
    const swapRouterAddr = deployments.contracts.OmniSwapRouter;
    const defaultSource = ethers.keccak256(ethers.toUtf8Bytes("INTERNAL_AMM"));
    const FeeSwapAdapter = await ethers.getContractFactory("FeeSwapAdapter");
    const feeSwapAdapter = await FeeSwapAdapter.deploy(swapRouterAddr, defaultSource, deployer.address);
    await feeSwapAdapter.waitForDeployment();
    const feeSwapAdapterAddr = await feeSwapAdapter.getAddress();
    deployments.contracts.FeeSwapAdapter = feeSwapAdapterAddr;
    console.log("FeeSwapAdapter:", feeSwapAdapterAddr);
    save();
    deployed++;

    // ================================================================
    // 28. OmniPrivacyBridge (UUPS) — on our chain, bridges to COTI
    // ================================================================
    console.log("--- 28. OmniPrivacyBridge (UUPS) ---");
    const OmniPrivacyBridge = await ethers.getContractFactory("OmniPrivacyBridge");
    const privBridgeProxy = await upgrades.deployProxy(
        OmniPrivacyBridge,
        [xomAddress, privateOmniCoinAddress],
        { initializer: "initialize", kind: "uups" }
    );
    await privBridgeProxy.waitForDeployment();
    const privBridgeAddr = await privBridgeProxy.getAddress();
    const privBridgeImpl = await upgrades.erc1967.getImplementationAddress(privBridgeAddr);
    deployments.contracts.OmniPrivacyBridge = privBridgeAddr;
    deployments.contracts.OmniPrivacyBridgeImplementation = privBridgeImpl;
    console.log("OmniPrivacyBridge:", privBridgeAddr);
    save();
    deployed++;

    // ================================================================
    // 29. TestUSDC (Immutable) — stablecoin for LBP and DEX testing
    // ================================================================
    console.log("--- 29. TestUSDC (Immutable) ---");
    const TestUSDC = await ethers.getContractFactory("TestUSDC");
    const testUSDC = await TestUSDC.deploy();
    await testUSDC.waitForDeployment();
    const testUSDCAddr = await testUSDC.getAddress();
    deployments.contracts.TestUSDC = testUSDCAddr;
    console.log("TestUSDC:", testUSDCAddr);
    save();
    deployed++;

    // ================================================================
    // 30. LiquidityBootstrappingPool (Immutable)
    // Uses TestUSDC as counter-asset (6 decimals)
    // ================================================================
    console.log("--- 30. LiquidityBootstrappingPool (Immutable) ---");
    const LBP = await ethers.getContractFactory("LiquidityBootstrappingPool");
    const lbp = await LBP.deploy(
        xomAddress,       // XOM token
        testUSDCAddr,     // counter-asset (TestUSDC)
        6,                // counter-asset decimals (USDC = 6)
        ODDAO_TREASURY    // treasury
    );
    await lbp.waitForDeployment();
    const lbpAddr = await lbp.getAddress();
    deployments.contracts.LiquidityBootstrappingPool = lbpAddr;
    console.log("LiquidityBootstrappingPool:", lbpAddr);
    save();
    deployed++;

    // ================================================================
    // Final notes
    // ================================================================
    deployments.notes.push(
        `Phase 3 deployed: ${deployed} additional contracts. ` +
        `Fee vault, marketplace, ENS, chat, oracle, arbitration, update registry, ` +
        `liquidity (mining+bonding+LBP), NFT (factory+collection+fractional+lending+staking), ` +
        `RWA (compliance+AMM+router), yield, bridge, AA (entrypoint+account+factory+paymaster), ` +
        `predictions, reputation, fee routing, privacy bridge, TestUSDC. ` +
        `Pioneer Phase: deployer used as placeholder for multi-sig/validator addresses.`
    );
    save();

    const blockNum = await ethers.provider.getBlockNumber();
    console.log("\n=== ALL REMAINING CONTRACTS DEPLOYED ===");
    console.log("Total new deployments:", deployed);
    console.log("Current block:", blockNum);

    const nativeBalance = await ethers.provider.getBalance(deployer.address);
    console.log("Deployer native balance remaining:", ethers.formatEther(nativeBalance), "tokens");

    console.log("\nNext: Deploy/update COTI testnet privacy contracts");
    console.log("Next: Run sync-contract-addresses.sh mainnet");
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error("FAILED:", error);
        process.exit(1);
    });
