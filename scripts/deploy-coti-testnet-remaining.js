/**
 * @file deploy-coti-testnet-remaining.js
 * @description Deploy remaining 4 privacy contracts on COTI testnet (chain 7082400).
 *
 * Already deployed on COTI testnet (2025-11-13):
 *   - PrivateOmniCoin (proxy): 0x6BF2b6df85CfeE5debF0684c4B656A3b86a31675
 *   - OmniPrivacyBridge (proxy): 0x123522e908b34799Cf14aDdF7B2A47Df404c4d47
 *   - PrivateDEX (proxy): 0xA242e4555CECF29F888b0189f216241587b9945E
 *
 * This script deploys:
 *   1. PrivateDEXSettlement (UUPS) — encrypted bilateral settlement
 *   2. PrivateUSDC (UUPS) — privacy-preserving USDC wrapper
 *   3. PrivateWBTC (UUPS) — privacy-preserving WBTC wrapper
 *   4. PrivateWETH (UUPS) — privacy-preserving WETH wrapper
 *
 * Note: PrivateUSDC/WBTC/WETH each need an underlying token address.
 * On COTI testnet there are no real USDC/WBTC/WETH contracts, so
 * we deploy simple ERC20 test tokens as stand-ins. These test tokens
 * are deployed inline (not counted as separate contracts in the 51 total).
 *
 * Prerequisites:
 *   - COTI_DEPLOYER_PRIVATE_KEY set in .env
 *   - COTI testnet deployer funded with COTI native tokens
 *
 * Usage:
 *   npx hardhat run scripts/deploy-coti-testnet-remaining.js --network cotiTestnet
 */
const { ethers, upgrades } = require("hardhat");
const fs = require("fs");
const path = require("path");

async function main() {
    console.log("=== Deploy Privacy Contracts on COTI Testnet ===\n");

    const [deployer] = await ethers.getSigners();
    console.log("Deployer:", deployer.address);

    const network = await ethers.provider.getNetwork();
    if (network.chainId !== 7082400n) {
        throw new Error(`Wrong network! Expected 7082400, got ${network.chainId}`);
    }

    const balance = await ethers.provider.getBalance(deployer.address);
    console.log("Native balance:", ethers.formatEther(balance), "COTI\n");

    // Load COTI testnet deployment file
    const deploymentFile = path.join(__dirname, "../deployments/coti-testnet.json");
    const deployments = JSON.parse(fs.readFileSync(deploymentFile, "utf-8"));

    // Existing deployed addresses
    const privateOmniCoinProxy = deployments.contracts.PrivateOmniCoin.proxy;
    const privacyBridgeProxy = deployments.contracts.OmniPrivacyBridge.proxy;
    const privateDEXProxy = deployments.contracts.PrivateDEX.proxy;

    console.log("Existing deployments:");
    console.log("  PrivateOmniCoin:", privateOmniCoinProxy);
    console.log("  OmniPrivacyBridge:", privacyBridgeProxy);
    console.log("  PrivateDEX:", privateDEXProxy);
    console.log("");

    // ODDAO and StakingPool on COTI testnet — deployer as placeholder
    const oddaoAddress = deployer.address;
    const stakingPoolAddress = deployer.address;

    let deployed = 0;

    // Helper to save progress
    function save() {
        deployments.timestamp = new Date().toISOString();
        fs.writeFileSync(deploymentFile, JSON.stringify(deployments, null, 2));
    }

    // ================================================================
    // Deploy test underlying tokens (USDC, WBTC, WETH stand-ins)
    // These are simple ERC20s for testing privacy wrappers.
    // ================================================================
    console.log("--- Deploying test underlying tokens ---");

    // Deploy underlying token stand-ins for privacy wrapper testing.
    //
    // TestUSDC (from contracts/test/) has correct 6 decimals for USDC.
    // MockERC20 (from contracts/test/) defaults to 18 decimals, which is
    // correct for WETH but not for WBTC (should be 8). This is acceptable
    // for COTI testnet testing — the MPC privacy layer is the focus, not
    // the decimal scaling precision. Production WBTC wrapping would use
    // the real WBTC contract on COTI mainnet.

    // TestUSDC — 6 decimals (correct for USDC)
    const TestUSDC = await ethers.getContractFactory("TestUSDC");
    const testUSDC = await TestUSDC.deploy();
    await testUSDC.waitForDeployment();
    const testUSDCAddr = await testUSDC.getAddress();
    console.log("Test USDC (underlying, 6 dec):", testUSDCAddr);

    // MockERC20 for WBTC — 18 decimals (real WBTC is 8; testnet-only)
    const MockERC20 = await ethers.getContractFactory("MockERC20");
    const testWBTC = await MockERC20.deploy("Test WBTC", "tWBTC");
    await testWBTC.waitForDeployment();
    const testWBTCAddr = await testWBTC.getAddress();
    console.log("Test WBTC (underlying, 18 dec — testnet approximation):", testWBTCAddr);

    // MockERC20 for WETH — 18 decimals (correct)
    const testWETH = await MockERC20.deploy("Test WETH", "tWETH");
    await testWETH.waitForDeployment();
    const testWETHAddr = await testWETH.getAddress();
    console.log("Test WETH (underlying, 18 dec):", testWETHAddr);

    deployments.contracts.TestUSDC_COTI = testUSDCAddr;
    deployments.contracts.TestWBTC_COTI = testWBTCAddr;
    deployments.contracts.TestWETH_COTI = testWETHAddr;
    save();

    // ================================================================
    // 1. PrivateDEXSettlement (UUPS)
    // initialize(admin, oddao, stakingPool)
    // ================================================================
    console.log("\n--- 1. PrivateDEXSettlement (UUPS) ---");
    const PrivateDEXSettlement = await ethers.getContractFactory("PrivateDEXSettlement");
    const dexSettlementProxy = await upgrades.deployProxy(
        PrivateDEXSettlement,
        [deployer.address, oddaoAddress, stakingPoolAddress],
        { initializer: "initialize", kind: "uups" }
    );
    await dexSettlementProxy.waitForDeployment();
    const dexSettlementAddr = await dexSettlementProxy.getAddress();
    const dexSettlementImpl = await upgrades.erc1967.getImplementationAddress(dexSettlementAddr);
    deployments.contracts.PrivateDEXSettlement = {
        proxy: dexSettlementAddr,
        implementation: dexSettlementImpl
    };
    console.log("PrivateDEXSettlement proxy:", dexSettlementAddr);
    console.log("PrivateDEXSettlement impl:", dexSettlementImpl);
    save();
    deployed++;

    // ================================================================
    // 2. PrivateUSDC (UUPS)
    // initialize(admin, underlyingToken)
    // ================================================================
    console.log("\n--- 2. PrivateUSDC (UUPS) ---");
    const PrivateUSDC = await ethers.getContractFactory("PrivateUSDC");
    const pusdcProxy = await upgrades.deployProxy(
        PrivateUSDC,
        [deployer.address, testUSDCAddr],
        { initializer: "initialize", kind: "uups" }
    );
    await pusdcProxy.waitForDeployment();
    const pusdcAddr = await pusdcProxy.getAddress();
    const pusdcImpl = await upgrades.erc1967.getImplementationAddress(pusdcAddr);
    deployments.contracts.PrivateUSDC = {
        proxy: pusdcAddr,
        implementation: pusdcImpl
    };
    console.log("PrivateUSDC proxy:", pusdcAddr);
    console.log("PrivateUSDC impl:", pusdcImpl);
    save();
    deployed++;

    // ================================================================
    // 3. PrivateWBTC (UUPS)
    // initialize(admin, underlyingToken)
    // ================================================================
    console.log("\n--- 3. PrivateWBTC (UUPS) ---");
    const PrivateWBTC = await ethers.getContractFactory("PrivateWBTC");
    const pwbtcProxy = await upgrades.deployProxy(
        PrivateWBTC,
        [deployer.address, testWBTCAddr],
        { initializer: "initialize", kind: "uups" }
    );
    await pwbtcProxy.waitForDeployment();
    const pwbtcAddr = await pwbtcProxy.getAddress();
    const pwbtcImpl = await upgrades.erc1967.getImplementationAddress(pwbtcAddr);
    deployments.contracts.PrivateWBTC = {
        proxy: pwbtcAddr,
        implementation: pwbtcImpl
    };
    console.log("PrivateWBTC proxy:", pwbtcAddr);
    console.log("PrivateWBTC impl:", pwbtcImpl);
    save();
    deployed++;

    // ================================================================
    // 4. PrivateWETH (UUPS)
    // initialize(admin, underlyingToken)
    // ================================================================
    console.log("\n--- 4. PrivateWETH (UUPS) ---");
    const PrivateWETH = await ethers.getContractFactory("PrivateWETH");
    const pwethProxy = await upgrades.deployProxy(
        PrivateWETH,
        [deployer.address, testWETHAddr],
        { initializer: "initialize", kind: "uups" }
    );
    await pwethProxy.waitForDeployment();
    const pwethAddr = await pwethProxy.getAddress();
    const pwethImpl = await upgrades.erc1967.getImplementationAddress(pwethAddr);
    deployments.contracts.PrivateWETH = {
        proxy: pwethAddr,
        implementation: pwethImpl
    };
    console.log("PrivateWETH proxy:", pwethAddr);
    console.log("PrivateWETH impl:", pwethImpl);
    save();
    deployed++;

    // ================================================================
    // Summary
    // ================================================================
    deployments.notes = deployments.notes || [];
    deployments.notes.push(
        `${deployed} privacy contracts deployed on COTI testnet: ` +
        `PrivateDEXSettlement, PrivateUSDC, PrivateWBTC, PrivateWETH. ` +
        `Test underlying tokens (tUSDC, tWBTC, tWETH) deployed for wrapper testing. ` +
        `All use deployer as admin. ODDAO/StakingPool set to deployer (Pioneer Phase).`
    );
    save();

    const blockNum = await ethers.provider.getBlockNumber();
    console.log("\n=== COTI TESTNET DEPLOYMENT COMPLETE ===");
    console.log("Total new deployments:", deployed, "(+ 3 test underlying tokens)");
    console.log("Current block:", blockNum);

    const nativeBalance = await ethers.provider.getBalance(deployer.address);
    console.log("Deployer native balance remaining:", ethers.formatEther(nativeBalance), "COTI");

    console.log("\nAll 51 contracts accounted for:");
    console.log("  Mainnet (88008): 14 Phase 1-2 + 10 Phase 3a + 20 Phase 3b = 44");
    console.log("  COTI testnet (7082400): 3 existing + 4 new = 7");
    console.log("  Total: 51");
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error("FAILED:", error);
        process.exit(1);
    });
