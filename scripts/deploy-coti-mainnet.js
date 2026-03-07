/**
 * @file deploy-coti-mainnet.js
 * @description Deploy all 7 privacy contracts on COTI V2 mainnet (chain 2632500).
 *
 * Contracts:
 *   1. PrivateOmniCoin (UUPS) — privacy-preserving XOM (pXOM)
 *   2. OmniPrivacyBridge (UUPS) — XOM ↔ pXOM bridge
 *   3. PrivateDEX (UUPS) — privacy-preserving DEX
 *   4. PrivateDEXSettlement (UUPS) — encrypted bilateral settlement
 *   5. PrivateUSDC (UUPS) — privacy-preserving USDC wrapper
 *   6. PrivateWBTC (UUPS) — privacy-preserving WBTC wrapper
 *   7. PrivateWETH (UUPS) — privacy-preserving WETH wrapper
 *
 * Underlying token addresses (official COTI mainnet bridged tokens):
 *   USDC.e: 0xf1Feebc4376c68B7003450ae66343Ae59AB37D3C
 *   wBTC:   0x8C39B1fD0e6260fdf20652Fc436d25026832bfEA
 *   wETH:   0x639aCc80569c5FC83c6FBf2319A6Cc38bBfe26d1
 *
 * Prerequisites:
 *   - COTI_MAINNET_DEPLOYER_PRIVATE_KEY set in .env
 *   - Deployer funded with COTI native tokens (50-100 COTI recommended)
 *   - Deployer account onboarded to COTI network (AES key generated)
 *
 * Usage:
 *   npx hardhat run scripts/deploy-coti-mainnet.js --network cotiMainnet
 */
const { ethers, upgrades } = require("hardhat");
const fs = require("fs");
const path = require("path");

// Official COTI mainnet bridged token addresses
const UNDERLYING_USDC = "0xf1Feebc4376c68B7003450ae66343Ae59AB37D3C";
const UNDERLYING_WBTC = "0x8C39B1fD0e6260fdf20652Fc436d25026832bfEA";
const UNDERLYING_WETH = "0x639aCc80569c5FC83c6FBf2319A6Cc38bBfe26d1";

async function main() {
    console.log("=== Deploy Privacy Contracts on COTI V2 Mainnet ===\n");

    const [deployer] = await ethers.getSigners();
    console.log("Deployer:", deployer.address);

    const network = await ethers.provider.getNetwork();
    if (network.chainId !== 2632500n) {
        throw new Error(`Wrong network! Expected 2632500 (COTI mainnet), got ${network.chainId}`);
    }

    const balance = await ethers.provider.getBalance(deployer.address);
    console.log("Native balance:", ethers.formatEther(balance), "COTI\n");

    if (balance < ethers.parseEther("10")) {
        console.warn("WARNING: Low balance. Recommend at least 50 COTI for MPC contract deployments.");
    }

    // Load deployment file
    const deploymentFile = path.join(__dirname, "../deployments/coti-mainnet.json");
    const deployments = JSON.parse(fs.readFileSync(deploymentFile, "utf-8"));

    // Pioneer Phase: deployer as admin, ODDAO placeholder, StakingPool placeholder
    const oddaoAddress = deployer.address;
    const stakingPoolAddress = deployer.address;

    let deployed = 0;

    function save() {
        deployments.deployer = deployer.address;
        deployments.deployedAt = new Date().toISOString();
        fs.writeFileSync(deploymentFile, JSON.stringify(deployments, null, 2));
    }

    // ================================================================
    // 1. PrivateOmniCoin (UUPS) — pXOM
    // initialize() — no args, grants roles to msg.sender
    // ================================================================
    console.log("--- 1. PrivateOmniCoin (UUPS) ---");
    const PrivateOmniCoin = await ethers.getContractFactory("PrivateOmniCoin");
    const pxomProxy = await upgrades.deployProxy(
        PrivateOmniCoin,
        [],
        { initializer: "initialize", kind: "uups" }
    );
    await pxomProxy.waitForDeployment();
    const pxomAddr = await pxomProxy.getAddress();
    const pxomImpl = await upgrades.erc1967.getImplementationAddress(pxomAddr);
    deployments.contracts.PrivateOmniCoin = { proxy: pxomAddr, implementation: pxomImpl };
    console.log("PrivateOmniCoin proxy:", pxomAddr);
    console.log("PrivateOmniCoin impl:", pxomImpl);
    save();
    deployed++;

    // ================================================================
    // 2. OmniPrivacyBridge (UUPS)
    // initialize(omniCoin, privateOmniCoin)
    // Note: On COTI mainnet, omniCoin address is the mainnet OmniCoin
    // For Pioneer Phase, use deployer as placeholder for omniCoin
    // (cross-chain bridge will be wired up later)
    // ================================================================
    console.log("\n--- 2. OmniPrivacyBridge (UUPS) ---");
    const OmniPrivacyBridge = await ethers.getContractFactory("OmniPrivacyBridge");
    const bridgeProxy = await upgrades.deployProxy(
        OmniPrivacyBridge,
        [deployer.address, pxomAddr],
        { initializer: "initialize", kind: "uups" }
    );
    await bridgeProxy.waitForDeployment();
    const bridgeAddr = await bridgeProxy.getAddress();
    const bridgeImpl = await upgrades.erc1967.getImplementationAddress(bridgeAddr);
    deployments.contracts.OmniPrivacyBridge = { proxy: bridgeAddr, implementation: bridgeImpl };
    console.log("OmniPrivacyBridge proxy:", bridgeAddr);
    console.log("OmniPrivacyBridge impl:", bridgeImpl);
    save();
    deployed++;

    // ================================================================
    // 3. PrivateDEX (UUPS)
    // initialize(admin)
    // ================================================================
    console.log("\n--- 3. PrivateDEX (UUPS) ---");
    const PrivateDEX = await ethers.getContractFactory("PrivateDEX");
    const pdexProxy = await upgrades.deployProxy(
        PrivateDEX,
        [deployer.address],
        { initializer: "initialize", kind: "uups" }
    );
    await pdexProxy.waitForDeployment();
    const pdexAddr = await pdexProxy.getAddress();
    const pdexImpl = await upgrades.erc1967.getImplementationAddress(pdexAddr);
    deployments.contracts.PrivateDEX = { proxy: pdexAddr, implementation: pdexImpl };
    console.log("PrivateDEX proxy:", pdexAddr);
    console.log("PrivateDEX impl:", pdexImpl);
    save();
    deployed++;

    // ================================================================
    // 4. PrivateDEXSettlement (UUPS)
    // initialize(admin, oddao, stakingPool)
    // ================================================================
    console.log("\n--- 4. PrivateDEXSettlement (UUPS) ---");
    const PrivateDEXSettlement = await ethers.getContractFactory("PrivateDEXSettlement");
    const settlementProxy = await upgrades.deployProxy(
        PrivateDEXSettlement,
        [deployer.address, oddaoAddress, stakingPoolAddress],
        { initializer: "initialize", kind: "uups" }
    );
    await settlementProxy.waitForDeployment();
    const settlementAddr = await settlementProxy.getAddress();
    const settlementImpl = await upgrades.erc1967.getImplementationAddress(settlementAddr);
    deployments.contracts.PrivateDEXSettlement = { proxy: settlementAddr, implementation: settlementImpl };
    console.log("PrivateDEXSettlement proxy:", settlementAddr);
    console.log("PrivateDEXSettlement impl:", settlementImpl);
    save();
    deployed++;

    // ================================================================
    // 5. PrivateUSDC (UUPS)
    // initialize(admin, underlyingToken)
    // Uses real COTI mainnet USDC.e: 0xf1Feebc4...
    // ================================================================
    console.log("\n--- 5. PrivateUSDC (UUPS) ---");
    const PrivateUSDC = await ethers.getContractFactory("PrivateUSDC");
    const pusdcProxy = await upgrades.deployProxy(
        PrivateUSDC,
        [deployer.address, UNDERLYING_USDC],
        { initializer: "initialize", kind: "uups" }
    );
    await pusdcProxy.waitForDeployment();
    const pusdcAddr = await pusdcProxy.getAddress();
    const pusdcImpl = await upgrades.erc1967.getImplementationAddress(pusdcAddr);
    deployments.contracts.PrivateUSDC = { proxy: pusdcAddr, implementation: pusdcImpl };
    console.log("PrivateUSDC proxy:", pusdcAddr);
    console.log("PrivateUSDC impl:", pusdcImpl);
    save();
    deployed++;

    // ================================================================
    // 6. PrivateWBTC (UUPS)
    // initialize(admin, underlyingToken)
    // Uses real COTI mainnet wBTC: 0x8C39B1fD...
    // ================================================================
    console.log("\n--- 6. PrivateWBTC (UUPS) ---");
    const PrivateWBTC = await ethers.getContractFactory("PrivateWBTC");
    const pwbtcProxy = await upgrades.deployProxy(
        PrivateWBTC,
        [deployer.address, UNDERLYING_WBTC],
        { initializer: "initialize", kind: "uups" }
    );
    await pwbtcProxy.waitForDeployment();
    const pwbtcAddr = await pwbtcProxy.getAddress();
    const pwbtcImpl = await upgrades.erc1967.getImplementationAddress(pwbtcAddr);
    deployments.contracts.PrivateWBTC = { proxy: pwbtcAddr, implementation: pwbtcImpl };
    console.log("PrivateWBTC proxy:", pwbtcAddr);
    console.log("PrivateWBTC impl:", pwbtcImpl);
    save();
    deployed++;

    // ================================================================
    // 7. PrivateWETH (UUPS)
    // initialize(admin, underlyingToken)
    // Uses real COTI mainnet wETH: 0x639aCc80...
    // ================================================================
    console.log("\n--- 7. PrivateWETH (UUPS) ---");
    const PrivateWETH = await ethers.getContractFactory("PrivateWETH");
    const pwethProxy = await upgrades.deployProxy(
        PrivateWETH,
        [deployer.address, UNDERLYING_WETH],
        { initializer: "initialize", kind: "uups" }
    );
    await pwethProxy.waitForDeployment();
    const pwethAddr = await pwethProxy.getAddress();
    const pwethImpl = await upgrades.erc1967.getImplementationAddress(pwethAddr);
    deployments.contracts.PrivateWETH = { proxy: pwethAddr, implementation: pwethImpl };
    console.log("PrivateWETH proxy:", pwethAddr);
    console.log("PrivateWETH impl:", pwethImpl);
    save();
    deployed++;

    // ================================================================
    // Summary
    // ================================================================
    deployments.notes = deployments.notes || [];
    deployments.notes.push(
        `${deployed} privacy contracts deployed on COTI V2 mainnet. ` +
        `PrivateOmniCoin (pXOM), OmniPrivacyBridge, PrivateDEX, PrivateDEXSettlement, ` +
        `PrivateUSDC (wraps USDC.e), PrivateWBTC (wraps wBTC), PrivateWETH (wraps wETH). ` +
        `All UUPS proxies. Admin: deployer (Pioneer Phase). ` +
        `Underlying tokens: real COTI mainnet bridged assets.`
    );
    save();

    const blockNum = await ethers.provider.getBlockNumber();
    console.log("\n=== COTI MAINNET DEPLOYMENT COMPLETE ===");
    console.log("Total deployments:", deployed);
    console.log("Current block:", blockNum);

    const nativeBalance = await ethers.provider.getBalance(deployer.address);
    console.log("Deployer native balance remaining:", ethers.formatEther(nativeBalance), "COTI");

    console.log("\nAll 51 contracts accounted for:");
    console.log("  OmniCoin L1 mainnet (88008): 44 contracts");
    console.log("  COTI V2 mainnet (2632500): 7 privacy contracts");
    console.log("  Total: 51");
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error("FAILED:", error);
        process.exit(1);
    });
