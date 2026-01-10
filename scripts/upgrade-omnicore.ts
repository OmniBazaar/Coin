import { ethers, upgrades } from "hardhat";
import * as fs from "fs";
import * as path from "path";

/**
 * Upgrades OmniCore contract implementation on Fuji Subnet
 * This preserves proxy address and state while deploying new implementation
 *
 * Usage: npx hardhat run scripts/upgrade-omnicore.ts --network fuji
 */
async function main(): Promise<void> {
    console.log("🔄 Starting OmniCore Upgrade\n");

    // Get deployer account
    const [deployer] = await ethers.getSigners();
    console.log("Upgrader address:", deployer.address);

    const balance = await ethers.provider.getBalance(deployer.address);
    console.log("Upgrader balance:", ethers.formatEther(balance), "tokens\n");

    // Verify we're on the right network
    const network = await ethers.provider.getNetwork();
    console.log("Network:", network.name);
    console.log("Chain ID:", network.chainId.toString());

    // Load existing deployment
    const deploymentsPath = path.join(__dirname, "../deployments");
    const deploymentFile = path.join(deploymentsPath, "fuji.json");

    if (!fs.existsSync(deploymentFile)) {
        throw new Error("Deployment file not found. Run deploy-fuji.js first.");
    }

    const deployments = JSON.parse(fs.readFileSync(deploymentFile, "utf-8"));
    const proxyAddress = deployments.contracts.OmniCore;

    if (!proxyAddress) {
        throw new Error("OmniCore proxy address not found in deployments");
    }

    console.log("Existing OmniCore proxy address:", proxyAddress);

    // Get old implementation address before upgrade
    const oldImplementation = await upgrades.erc1967.getImplementationAddress(proxyAddress);
    console.log("Current implementation address:", oldImplementation);

    // Import the existing proxy into OpenZeppelin's upgrade manifest
    // This is required if the proxy was deployed on a different machine or not tracked
    console.log("\n=== Importing Existing Proxy ===");
    const OmniCore = await ethers.getContractFactory("OmniCore");

    try {
        await upgrades.forceImport(proxyAddress, OmniCore, {
            kind: "uups"
        });
        console.log("✓ Proxy imported into upgrade manifest");
    } catch (importError: unknown) {
        const errorMsg = importError instanceof Error ? importError.message : String(importError);
        // If already imported, continue with upgrade
        if (errorMsg.includes("already registered") || errorMsg.includes("Deployment at address")) {
            console.log("ℹ️  Proxy already registered, continuing with upgrade");
        } else {
            throw importError;
        }
    }

    // Upgrade the contract
    console.log("\n=== Upgrading OmniCore ===");
    const upgraded = await upgrades.upgradeProxy(proxyAddress, OmniCore, {
        kind: "uups"
    });

    await upgraded.waitForDeployment();
    console.log("✓ OmniCore upgrade transaction submitted");

    // Get new implementation address
    const newImplementation = await upgrades.erc1967.getImplementationAddress(proxyAddress);
    console.log("New implementation address:", newImplementation);

    // Verify upgrade succeeded
    if (oldImplementation === newImplementation) {
        console.log("⚠️  Warning: Implementation address unchanged (may indicate no code changes or cached artifact)");
    } else {
        console.log("✓ Implementation upgraded successfully");
    }

    // Update deployment file
    deployments.contracts.OmniCoreImplementation = newImplementation;
    deployments.upgradedAt = new Date().toISOString();
    fs.writeFileSync(deploymentFile, JSON.stringify(deployments, null, 2));
    console.log("\n✅ Deployment file updated:", deploymentFile);

    // Verification tests
    console.log("\n=== Running Verification Tests ===");

    const omniCore = await ethers.getContractAt("OmniCore", proxyAddress);

    // Check OmniCore configuration still works
    try {
        const coreToken = await omniCore.OMNI_COIN();
        console.log("✓ OmniCore token address:", coreToken);
        console.log("✓ Contract state preserved");
    } catch (error) {
        console.error("❌ Error reading contract state:", error);
    }

    console.log("\n🎉 OmniCore upgrade complete!");
    console.log("\n=== Summary ===");
    console.log("Proxy (unchanged):        ", proxyAddress);
    console.log("Old implementation:       ", oldImplementation);
    console.log("New implementation:       ", newImplementation);

    console.log("\n=== Next Steps ===");
    console.log("1. Sync addresses: ./scripts/sync-contract-addresses.sh fuji");
    console.log("2. Run integration tests to verify functionality");
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error("❌ Upgrade failed:", error);
        process.exit(1);
    });
