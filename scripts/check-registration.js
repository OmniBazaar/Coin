const { ethers } = require("hardhat");

async function main() {
    const REGISTRATION_PROXY = "0x0E4E697317117B150481a827f1e5029864aAe781";
    const [deployer] = await ethers.getSigners();

    console.log("Deployer:", deployer.address);

    const reg = await ethers.getContractAt("OmniRegistration", REGISTRATION_PROXY);

    // Check if function exists
    console.log("\nChecking functions...");

    // Check DEFAULT_ADMIN_ROLE
    const DEFAULT_ADMIN_ROLE = ethers.ZeroHash; // bytes32(0)
    const hasAdminRole = await reg.hasRole(DEFAULT_ADMIN_ROLE, deployer.address);
    console.log("Deployer has DEFAULT_ADMIN_ROLE:", hasAdminRole);

    // Try to read trustedVerificationKey
    try {
        const key = await reg.trustedVerificationKey();
        console.log("trustedVerificationKey:", key);
    } catch (e) {
        console.log("trustedVerificationKey() error:", e.message);
    }

    // Try to read hasKycTier1
    try {
        const hasKyc = await reg.hasKycTier1(deployer.address);
        console.log("hasKycTier1(deployer):", hasKyc);
    } catch (e) {
        console.log("hasKycTier1() error:", e.message);
    }

    // Check implementation slot
    const implSlot = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";
    const implRaw = await ethers.provider.getStorage(REGISTRATION_PROXY, implSlot);
    console.log("\nImplementation address:", "0x" + implRaw.slice(26));

    // Check who was initial admin
    const roleAdmin = await reg.getRoleAdmin(DEFAULT_ADMIN_ROLE);
    console.log("Role admin for DEFAULT_ADMIN_ROLE:", roleAdmin);
}

main().then(() => process.exit(0)).catch(e => { console.error(e); process.exit(1); });
