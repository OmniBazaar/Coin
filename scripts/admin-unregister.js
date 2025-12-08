const { ethers } = require("hardhat");

async function main() {
    const REGISTRATION_PROXY = "0x0E4E697317117B150481a827f1e5029864aAe781";
    const USER_ADDRESS = "0xe89d532934D7771976Ae3530292c9a854ef6449D";

    console.log("=".repeat(60));
    console.log("Admin Unregister User");
    console.log("=".repeat(60));
    console.log("\nUser to unregister:", USER_ADDRESS);

    const [admin] = await ethers.getSigners();
    console.log("Admin address:", admin.address);

    const reg = await ethers.getContractAt("OmniRegistration", REGISTRATION_PROXY);

    // Check if registered first
    const isRegistered = await reg.isRegistered(USER_ADDRESS);
    console.log("\nCurrently registered:", isRegistered);

    if (!isRegistered) {
        console.log("User is not registered - nothing to do!");
        return;
    }

    // Get registration data before unregistering
    const regData = await reg.getRegistration(USER_ADDRESS);
    console.log("\nRegistration data to be cleared:");
    console.log("  phoneHash:", regData.phoneHash);
    console.log("  emailHash:", regData.emailHash);
    console.log("  referrer:", regData.referrer);
    console.log("  kycTier:", regData.kycTier);

    // Unregister
    console.log("\nCalling adminUnregister...");
    const tx = await reg.adminUnregister(USER_ADDRESS);
    console.log("Transaction hash:", tx.hash);
    await tx.wait();
    console.log("Transaction confirmed!");

    // Verify unregistration
    const isStillRegistered = await reg.isRegistered(USER_ADDRESS);
    console.log("\nAfter unregister:");
    console.log("  isRegistered:", isStillRegistered);

    if (!isStillRegistered) {
        console.log("\n✅ User successfully unregistered!");
        console.log("User can now re-register through the new trustless verification flow.");
    } else {
        console.log("\n❌ Unregistration may have failed - user still registered!");
    }
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error("Error:", error);
        process.exit(1);
    });
