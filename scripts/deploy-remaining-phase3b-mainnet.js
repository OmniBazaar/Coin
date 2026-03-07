/**
 * @file deploy-remaining-phase3b-mainnet.js
 * @description Deploy the remaining 20 contracts on mainnet (chain 88008).
 *
 * Phase 3a deployed 10 contracts (UnifiedFeeVault through RWAComplianceOracle).
 * This script deploys the remaining 20:
 *
 *   11. RWAAMM (Immutable) — 5 unique emergency signers required
 *   12. RWARouter (Immutable)
 *   13. OmniYieldFeeCollector (Immutable)
 *   14. OmniNFTCollection (Implementation template)
 *   15. OmniNFTFactory (Immutable)
 *   16. OmniFractionalNFT (Immutable)
 *   17. OmniNFTLending (Immutable)
 *   18. OmniNFTStaking (Immutable)
 *   19. OmniBridge (UUPS)
 *   20. OmniEntryPoint (Immutable)
 *   21. OmniAccount (Implementation template)
 *   22. OmniAccountFactory (Immutable)
 *   23. OmniPaymaster (Immutable)
 *   24. OmniPredictionRouter (Immutable)
 *   25. ReputationCredential (Immutable)
 *   26. OmniFeeRouter (Immutable)
 *   27. FeeSwapAdapter (Immutable)
 *   28. OmniPrivacyBridge (UUPS)
 *   29. TestUSDC (Immutable)
 *   30. LiquidityBootstrappingPool (Immutable)
 *
 * Usage:
 *   npx hardhat run scripts/deploy-remaining-phase3b-mainnet.js --network mainnet
 */
const { ethers, upgrades } = require("hardhat");
const fs = require("fs");
const path = require("path");

/** Real ODDAO treasury address */
const ODDAO_TREASURY = "0x664B6347a69A22b35348D42E4640CA92e1609378";

async function main() {
    console.log("=== Deploy Phase 3b — Remaining 20 Contracts (Mainnet) ===\n");

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

    // Already-deployed addresses needed as constructor args
    const xomAddress = deployments.contracts.OmniCoin;
    const omniCoreAddress = deployments.contracts.OmniCore;
    const stakingPoolAddress = deployments.contracts.StakingRewardPool;
    const participationAddress = deployments.contracts.OmniParticipation;
    const escrowAddress = deployments.contracts.MinimalEscrow;
    const privateOmniCoinAddress = deployments.contracts.PrivateOmniCoin;
    const swapRouterAddr = deployments.contracts.OmniSwapRouter;

    // Phase 3a addresses (deployed earlier today)
    const feeVaultAddr = deployments.contracts.UnifiedFeeVault;
    const rwaOracleAddr = deployments.contracts.RWAComplianceOracle;

    console.log("OmniCoin:", xomAddress);
    console.log("OmniCore:", omniCoreAddress);
    console.log("StakingRewardPool:", stakingPoolAddress);
    console.log("UnifiedFeeVault:", feeVaultAddr);
    console.log("RWAComplianceOracle:", rwaOracleAddr);
    console.log("ODDAO:", ODDAO_TREASURY);
    console.log("");

    let deployed = 0;

    // Helper to save progress after each deployment
    function save() {
        deployments.deployedAt = new Date().toISOString();
        fs.writeFileSync(deploymentFile, JSON.stringify(deployments, null, 2));
    }

    // ================================================================
    // 11. RWAAMM (Immutable)
    // Requires 5 UNIQUE emergency multisig addresses.
    // Pioneer Phase: deployer + 4 deterministic Pioneer-phase signers.
    // These 4 addresses are derived but not controlled by anyone —
    // effectively disabling the 3-of-5 emergency multisig until
    // real signers are configured post-Pioneer.
    // ================================================================
    console.log("--- 11. RWAAMM (Immutable) ---");
    const pioneerSigners = [
        deployer.address,
        ethers.Wallet.createRandom().address,
        ethers.Wallet.createRandom().address,
        ethers.Wallet.createRandom().address,
        ethers.Wallet.createRandom().address,
    ];
    console.log("Emergency multisig signers (Pioneer Phase):");
    pioneerSigners.forEach((s, i) => console.log(`  Signer ${i + 1}: ${s}`));

    const RWAAMM = await ethers.getContractFactory("RWAAMM");
    const rwaAMM = await RWAAMM.deploy(
        pioneerSigners,
        feeVaultAddr,
        xomAddress,
        rwaOracleAddr
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
        stakingPoolAddress,   // staking pool (20%)
        deployer.address,     // validator recipient (10%, deployer for Pioneer)
        performanceFeeBps     // 10% performance fee
    );
    await yieldFee.waitForDeployment();
    const yieldFeeAddr = await yieldFee.getAddress();
    deployments.contracts.OmniYieldFeeCollector = yieldFeeAddr;
    console.log("OmniYieldFeeCollector:", yieldFeeAddr);
    save();
    deployed++;

    // ================================================================
    // 14. OmniNFTCollection (Implementation template for clones)
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
    // 15. OmniNFTFactory (uses OmniNFTCollection implementation)
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
    // 16. OmniFractionalNFT (Immutable)
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
    // 17. OmniNFTLending (Immutable)
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
    // 18. OmniNFTStaking (Immutable)
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
    save();
    deployed++;

    // ================================================================
    // 20. OmniEntryPoint (Immutable, no constructor args)
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
    // 21. OmniAccount (Implementation template, needs entryPoint)
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
    // 22. OmniAccountFactory (Immutable, needs OmniAccount impl)
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
    // 23. OmniPaymaster (Immutable)
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
    // ================================================================
    console.log("--- 27. FeeSwapAdapter (Immutable) ---");
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
    // Mints 100M TestUSDC to deployer
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
    // Final summary
    // ================================================================
    deployments.notes.push(
        `Phase 3b deployed: ${deployed} additional contracts. ` +
        `RWA (AMM+router), yield, NFT (factory+collection+fractional+lending+staking), ` +
        `bridge, AA (entrypoint+account+factory+paymaster), predictions, reputation, ` +
        `fee routing, privacy bridge, TestUSDC, LBP. ` +
        `Pioneer Phase: deployer used as placeholder for multi-sig/validator addresses. ` +
        `RWAAMM emergency multisig uses deployer + 4 random addresses (effectively disabled).`
    );
    save();

    const blockNum = await ethers.provider.getBlockNumber();
    console.log("\n=== PHASE 3b COMPLETE ===");
    console.log("Total new deployments:", deployed);
    console.log("Current block:", blockNum);

    const nativeBalance = await ethers.provider.getBalance(deployer.address);
    console.log("Deployer native balance remaining:", ethers.formatEther(nativeBalance), "tokens");

    console.log("\nNext: Deploy COTI testnet privacy contracts (4 remaining)");
    console.log("Next: Run sync-contract-addresses.sh mainnet");
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error("FAILED:", error);
        process.exit(1);
    });
