const { ethers } = require("hardhat");

async function main() {
    const REGISTRATION_PROXY = "0x0E4E697317117B150481a827f1e5029864aAe781";
    const USER_ADDRESS = "0xe89d532934D7771976Ae3530292c9a854ef6449D";

    console.log("Checking registration for:", USER_ADDRESS);

    const reg = await ethers.getContractAt("OmniRegistration", REGISTRATION_PROXY);

    // Check if registered
    const isRegistered = await reg.isRegistered(USER_ADDRESS);
    console.log("\nisRegistered:", isRegistered);

    if (isRegistered) {
        // Get full registration data
        const regData = await reg.getRegistration(USER_ADDRESS);
        console.log("\nRegistration Data:");
        console.log("  timestamp:", regData.timestamp.toString());
        console.log("  referrer:", regData.referrer);
        console.log("  registeredBy:", regData.registeredBy);
        console.log("  phoneHash:", regData.phoneHash);
        console.log("  emailHash:", regData.emailHash);
        console.log("  kycTier:", regData.kycTier);
        console.log("  welcomeBonusClaimed:", regData.welcomeBonusClaimed);
        console.log("  firstSaleBonusClaimed:", regData.firstSaleBonusClaimed);
    }

    // Check KYC Tier 1 status
    const hasKyc = await reg.hasKycTier1(USER_ADDRESS);
    console.log("\nhasKycTier1:", hasKyc);

    // Check social hash
    const socialHash = await reg.userSocialHashes(USER_ADDRESS);
    console.log("userSocialHashes:", socialHash);

    // Check KYC Tier 1 completion time
    const kycTime = await reg.kycTier1CompletedAt(USER_ADDRESS);
    console.log("kycTier1CompletedAt:", kycTime.toString());

    // Check canClaimWelcomeBonus
    const canClaim = await reg.canClaimWelcomeBonus(USER_ADDRESS);
    console.log("\ncanClaimWelcomeBonus:", canClaim);
}

main().then(() => process.exit(0)).catch(e => { console.error(e); process.exit(1); });
