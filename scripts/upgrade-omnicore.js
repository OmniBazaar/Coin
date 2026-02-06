const { ethers, upgrades } = require("hardhat");

/**
 * Upgrades OmniCore UUPS proxy to the latest implementation.
 *
 * Network: omnicoinFuji (chainId 131313)
 */
async function main() {
    console.log("Upgrading OmniCore on Fuji Subnet...\n");

    const [deployer] = await ethers.getSigners();
    console.log("Deployer:", deployer.address);

    const network = await ethers.provider.getNetwork();
    if (network.chainId !== 131313n) {
        throw new Error(`Wrong network: chainId ${network.chainId}, expected 131313`);
    }
    console.log("Network: OmniCoin Fuji Subnet (chainId 131313)\n");

    const PROXY_ADDRESS = "0x0Ef606683222747738C04b4b00052F5357AC6c8b";

    // Get old implementation address
    const oldImpl = await upgrades.erc1967.getImplementationAddress(PROXY_ADDRESS);
    console.log("Current implementation:", oldImpl);

    // Upgrade
    console.log("Deploying new implementation and upgrading proxy...");
    const OmniCore = await ethers.getContractFactory("OmniCore");
    const upgraded = await upgrades.upgradeProxy(PROXY_ADDRESS, OmniCore);
    await upgraded.waitForDeployment();

    const newImpl = await upgrades.erc1967.getImplementationAddress(PROXY_ADDRESS);
    console.log("New implementation:", newImpl);

    // Verify core functions exist
    const contract = await ethers.getContractAt("OmniCore", PROXY_ADDRESS);
    const hasStake = contract.interface.getFunction("stake") !== null;
    const hasUnlock = contract.interface.getFunction("unlock") !== null;
    console.log("\nstake() available:", hasStake);
    console.log("unlock() available:", hasUnlock);

    // Update fuji.json
    const fs = require("fs");
    const path = require("path");
    const fujiPath = path.join(__dirname, "../deployments/fuji.json");
    const fuji = JSON.parse(fs.readFileSync(fujiPath, "utf8"));
    fuji.contracts.OmniCoreImplementation = newImpl;
    fuji.upgradedAt = new Date().toISOString();
    fs.writeFileSync(fujiPath, JSON.stringify(fuji, null, 2));
    console.log("Updated deployments/fuji.json");

    console.log("\nOmniCore upgrade complete!");
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error("Upgrade failed:", error);
        process.exit(1);
    });
