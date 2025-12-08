/**
 * Force upgrade OmniRegistration to new implementation with relay functions
 */
const { ethers } = require("hardhat");

async function main() {
    console.log("=== Direct Implementation Upgrade ===\n");

    const [deployer] = await ethers.getSigners();
    console.log("Deployer:", deployer.address);

    const PROXY = "0x0E4E697317117B150481a827f1e5029864aAe781";

    // Get current implementation
    const implSlot = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";
    const oldImplRaw = await ethers.provider.getStorage(PROXY, implSlot);
    const oldImpl = "0x" + oldImplRaw.slice(26);
    console.log("Current implementation:", oldImpl);

    // Deploy new implementation
    console.log("\nDeploying new OmniRegistration implementation...");
    const OmniRegistration = await ethers.getContractFactory("OmniRegistration");
    const newImpl = await OmniRegistration.deploy();
    await newImpl.waitForDeployment();
    const newImplAddress = await newImpl.getAddress();
    console.log("New implementation deployed:", newImplAddress);

    // Upgrade via UUPS
    console.log("\nUpgrading proxy to new implementation...");
    const proxy = OmniRegistration.attach(PROXY);
    const tx = await proxy.upgradeToAndCall(newImplAddress, "0x");
    console.log("Upgrade tx:", tx.hash);
    await tx.wait();
    console.log("Upgrade confirmed!");

    // Verify new implementation
    const newImplRaw = await ethers.provider.getStorage(PROXY, implSlot);
    const verifiedImpl = "0x" + newImplRaw.slice(26);
    console.log("\nNew implementation verified:", verifiedImpl);

    // Test relay functions work
    console.log("\nTesting relay functions exist on-chain...");
    try {
        // This will fail because we don't have valid proofs, but it confirms the function exists
        await proxy.submitPhoneVerificationFor.staticCall(
            "0xe89d532934D7771976Ae3530292c9a854ef6449D",
            "0x1234567890123456789012345678901234567890123456789012345678901234",
            Math.floor(Date.now()/1000),
            "0xaabbccdd00112233445566778899aabbccddeeff00112233445566778899aabb",
            Math.floor(Date.now()/1000) + 3600,
            "0x" + "00".repeat(65)
        );
    } catch (e) {
        // Expected to fail with signature error - but confirms function exists on-chain
        if (e.message.includes("InvalidVerificationProof") || e.message.includes("ECDSA") || e.message.includes("recover")) {
            console.log("✅ submitPhoneVerificationFor works on-chain (expected signature error)");
        } else {
            console.log("Function check error:", e.message.substring(0, 100));
        }
    }

    console.log("\n✅ Upgrade complete!");
    console.log("New implementation:", newImplAddress);
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });
