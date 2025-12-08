/**
 * @file upgrade-omni-registration.js
 * @description Upgrades OmniRegistration contract to add trustless verification functions
 *
 * This script:
 * 1. Deploys new OmniRegistration implementation
 * 2. Upgrades the UUPS proxy to point to new implementation
 * 3. Calls reinitialize() to set DOMAIN_SEPARATOR if needed
 * 4. Sets the trustedVerificationKey
 *
 * Run with: npx hardhat run scripts/upgrade-omni-registration.js --network fuji
 */
const { ethers, upgrades } = require("hardhat");

// Contract addresses from fuji.json
const REGISTRATION_PROXY = "0x0E4E697317117B150481a827f1e5029864aAe781";

// Verification key address (generated from VERIFICATION_PRIVATE_KEY)
const VERIFICATION_KEY_ADDRESS = "0xE13a2D66736805Fd57F765E82370C5d7b0FBdE54";

async function main() {
    console.log("=".repeat(60));
    console.log("OmniRegistration Contract Upgrade");
    console.log("=".repeat(60));

    const [deployer] = await ethers.getSigners();
    console.log("\nDeployer:", deployer.address);

    const balance = await ethers.provider.getBalance(deployer.address);
    console.log("Balance:", ethers.formatEther(balance), "AVAX\n");

    // Step 1: Get current implementation info
    console.log("Step 1: Checking current contract state...");

    // Try to read trustedVerificationKey to confirm upgrade is needed
    const OmniRegistration = await ethers.getContractFactory("OmniRegistration");
    const currentContract = OmniRegistration.attach(REGISTRATION_PROXY);

    let needsUpgrade = false;
    try {
        const currentKey = await currentContract.trustedVerificationKey();
        console.log("trustedVerificationKey() exists:", currentKey);
        console.log("Contract may already be upgraded - checking...");
    } catch (error) {
        console.log("trustedVerificationKey() not found - upgrade needed");
        needsUpgrade = true;
    }

    // Step 2: Upgrade the contract
    console.log("\nStep 2: Upgrading OmniRegistration implementation...");

    let upgraded;
    try {
        // Force import the existing proxy (in case it wasn't originally deployed with upgrades plugin)
        try {
            await upgrades.forceImport(REGISTRATION_PROXY, OmniRegistration, {
                kind: "uups"
            });
            console.log("Proxy imported into upgrades manifest");
        } catch (importError) {
            // May already be imported
            console.log("Proxy may already be in manifest:", importError.message);
        }

        // Upgrade to new implementation
        upgraded = await upgrades.upgradeProxy(REGISTRATION_PROXY, OmniRegistration, {
            kind: "uups",
            redeployImplementation: "always"
        });

        await upgraded.waitForDeployment();
        const newAddress = await upgraded.getAddress();
        console.log("Upgrade successful!");
        console.log("Proxy address:", newAddress);

        // Get new implementation address
        const implSlot = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";
        const implAddressRaw = await ethers.provider.getStorage(REGISTRATION_PROXY, implSlot);
        const implAddress = "0x" + implAddressRaw.slice(26);
        console.log("New implementation:", implAddress);

    } catch (upgradeError) {
        console.error("Upgrade failed:", upgradeError.message);
        console.log("\nTrying alternative approach...");

        // If upgrades plugin fails, try direct upgrade call
        // This works if the deployer has DEFAULT_ADMIN_ROLE
        try {
            // Deploy new implementation manually
            console.log("Deploying new implementation directly...");
            const NewImpl = await ethers.getContractFactory("OmniRegistration");
            const newImpl = await NewImpl.deploy();
            await newImpl.waitForDeployment();
            const newImplAddress = await newImpl.getAddress();
            console.log("New implementation deployed at:", newImplAddress);

            // Get the proxy contract interface for the upgrade call
            const proxyWithUpgrade = await ethers.getContractAt(
                "ITransparentUpgradeableProxy",
                REGISTRATION_PROXY
            );

            // For UUPS, call upgradeToAndCall directly on the proxy
            const UUPSProxy = OmniRegistration.attach(REGISTRATION_PROXY);
            console.log("Calling upgradeToAndCall...");
            const tx = await UUPSProxy.upgradeToAndCall(newImplAddress, "0x");
            await tx.wait();
            console.log("Direct upgrade successful!");

            upgraded = UUPSProxy;
        } catch (directError) {
            console.error("Direct upgrade also failed:", directError.message);
            throw directError;
        }
    }

    // Step 3: Reinitialize if needed (to set DOMAIN_SEPARATOR)
    console.log("\nStep 3: Checking DOMAIN_SEPARATOR...");

    try {
        const domainSep = await upgraded.DOMAIN_SEPARATOR();
        if (domainSep === "0x0000000000000000000000000000000000000000000000000000000000000000") {
            console.log("DOMAIN_SEPARATOR is not set, calling reinitialize...");
            const tx = await upgraded.reinitialize(2); // Version 2 for first reinitialize
            await tx.wait();
            console.log("reinitialize() completed");
        } else {
            console.log("DOMAIN_SEPARATOR already set:", domainSep.slice(0, 20) + "...");
        }
    } catch (err) {
        console.log("DOMAIN_SEPARATOR check/set failed:", err.message);
    }

    // Step 4: Set trustedVerificationKey
    console.log("\nStep 4: Setting trustedVerificationKey...");

    try {
        // Check current key
        const currentKey = await upgraded.trustedVerificationKey();
        console.log("Current trustedVerificationKey:", currentKey);

        if (currentKey === VERIFICATION_KEY_ADDRESS) {
            console.log("Key already set correctly!");
        } else if (currentKey === "0x0000000000000000000000000000000000000000") {
            console.log("Setting trustedVerificationKey to:", VERIFICATION_KEY_ADDRESS);
            const tx = await upgraded.setTrustedVerificationKey(VERIFICATION_KEY_ADDRESS);
            console.log("Transaction hash:", tx.hash);
            await tx.wait();

            // Verify
            const newKey = await upgraded.trustedVerificationKey();
            console.log("trustedVerificationKey set to:", newKey);
        } else {
            console.log("Key already set to a different value!");
            console.log("To change it, run: setTrustedVerificationKey(", VERIFICATION_KEY_ADDRESS, ")");
        }
    } catch (keyError) {
        console.error("Failed to set trustedVerificationKey:", keyError.message);
    }

    // Step 5: Verify the upgrade
    console.log("\nStep 5: Verifying upgrade...");

    try {
        // Test all new functions exist
        const hasKycTier1 = await upgraded.hasKycTier1(deployer.address);
        console.log("hasKycTier1() works:", hasKycTier1);

        const verKey = await upgraded.trustedVerificationKey();
        console.log("trustedVerificationKey():", verKey);

        console.log("\n✅ Upgrade completed successfully!");
        console.log("=".repeat(60));
        console.log("OmniRegistration is now ready for trustless verification");
        console.log("=".repeat(60));

    } catch (verifyError) {
        console.error("Verification failed:", verifyError.message);
    }
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error("Fatal error:", error);
        process.exit(1);
    });
