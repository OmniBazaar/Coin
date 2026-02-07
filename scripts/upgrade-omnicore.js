const { ethers, upgrades } = require("hardhat");

/**
 * Upgrades OmniCore UUPS proxy to V2 implementation.
 *
 * Changes in V2:
 * - Removed: unlockWithRewards(), updateMasterRoot(), verifyProof()
 * - Added: requiredSignatures for multi-sig legacy claims
 * - Added: setRequiredSignatures() admin function
 * - Modified: claimLegacyBalance() accepts bytes[] signatures
 * - Deprecated: DEX settlement functions (use DEXSettlement.sol)
 *
 * Network: omnicoinFuji (chainId 131313)
 */
async function main() {
    console.log("Upgrading OmniCore V2 on Fuji Subnet...\n");

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

    // Upgrade proxy (initializeV2 already ran in prior upgrade)
    console.log("Deploying new implementation and upgrading proxy...");
    const OmniCore = await ethers.getContractFactory("OmniCore");
    const upgraded = await upgrades.upgradeProxy(PROXY_ADDRESS, OmniCore);
    await upgraded.waitForDeployment();

    const newImpl = await upgrades.erc1967.getImplementationAddress(PROXY_ADDRESS);
    console.log("New implementation:", newImpl);

    if (oldImpl === newImpl) {
        console.log("\n⚠️  Implementation address unchanged — contract may already be up to date");
    } else {
        console.log("\n✅ Implementation upgraded:", oldImpl, "→", newImpl);
    }

    // Verify V2 changes
    const contract = await ethers.getContractAt("OmniCore", PROXY_ADDRESS);

    console.log("\n--- V2 Verification ---");

    // Check requiredSignatures was initialized
    const reqSigs = await contract.requiredSignatures();
    console.log("requiredSignatures:", reqSigs.toString(), reqSigs === 1n ? "✅" : "❌");

    // Check core functions still exist
    const hasStake = contract.interface.getFunction("stake") !== null;
    const hasUnlock = contract.interface.getFunction("unlock") !== null;
    const hasClaimLegacy = contract.interface.getFunction("claimLegacyBalance") !== null;
    const hasSetReqSigs = contract.interface.getFunction("setRequiredSignatures") !== null;
    console.log("stake() available:", hasStake ? "✅" : "❌");
    console.log("unlock() available:", hasUnlock ? "✅" : "❌");
    console.log("claimLegacyBalance() available:", hasClaimLegacy ? "✅" : "❌");
    console.log("setRequiredSignatures() available:", hasSetReqSigs ? "✅" : "❌");

    // Verify removed functions are gone (ethers v6 getFunction returns null, not throws)
    const removedFunctions = [
        "unlockWithRewards",
        "updateMasterRoot",
        "verifyProof",
    ];
    for (const fn of removedFunctions) {
        const found = contract.interface.getFunction(fn);
        if (found) {
            console.log(`${fn}() still present: ❌ (should be removed)`);
        } else {
            console.log(`${fn}() removed: ✅`);
        }
    }

    // Verify deprecated DEX functions still exist (storage layout safety)
    const dexFunctions = ["settleDEXTrade", "batchSettleDEX", "distributeDEXFees"];
    for (const fn of dexFunctions) {
        const exists = contract.interface.getFunction(fn) !== null;
        console.log(`${fn}() present (deprecated): ${exists ? "✅" : "❌"}`);
    }

    // Verify storage layout preserved
    const totalStaked = await contract.totalStaked();
    const oddao = await contract.oddaoAddress();
    console.log("\ntotalStaked:", ethers.formatEther(totalStaked), "XOM");
    console.log("oddaoAddress:", oddao);

    // Update fuji.json
    const fs = require("fs");
    const path = require("path");
    const fujiPath = path.join(__dirname, "../deployments/fuji.json");
    const fuji = JSON.parse(fs.readFileSync(fujiPath, "utf8"));
    fuji.contracts.OmniCoreImplementation = newImpl;
    fuji.upgradedAt = new Date().toISOString();
    fs.writeFileSync(fujiPath, JSON.stringify(fuji, null, 2));
    console.log("\nUpdated deployments/fuji.json");

    console.log("\n✅ OmniCore V2 upgrade complete!");
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error("Upgrade failed:", error);
        process.exit(1);
    });
