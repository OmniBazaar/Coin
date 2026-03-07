/**
 * @file deploy-participation-mainnet.js
 * @description Deploy OmniParticipation (UUPS proxy) on mainnet (chain 88008).
 *
 * Requires OmniRegistration and OmniCore to be already deployed.
 *
 * Usage:
 *   npx hardhat run scripts/deploy-participation-mainnet.js --network mainnet
 */
const { ethers, upgrades } = require("hardhat");
const fs = require("fs");
const path = require("path");

async function main() {
    console.log("=== Deploy OmniParticipation (Mainnet) ===\n");

    const [deployer] = await ethers.getSigners();
    console.log("Deployer:", deployer.address);

    const network = await ethers.provider.getNetwork();
    if (network.chainId !== 88008n) {
        throw new Error(`Wrong network! Expected 88008, got ${network.chainId}`);
    }

    // Load addresses from mainnet.json
    const deploymentFile = path.join(__dirname, "../deployments/mainnet.json");
    const deployments = JSON.parse(fs.readFileSync(deploymentFile, "utf-8"));

    const registrationAddress = deployments.contracts.OmniRegistration;
    const omniCoreAddress = deployments.contracts.OmniCore;

    if (!registrationAddress) {
        throw new Error("OmniRegistration not found in mainnet.json!");
    }
    if (!omniCoreAddress) {
        throw new Error("OmniCore not found in mainnet.json!");
    }

    console.log("OmniRegistration:", registrationAddress);
    console.log("OmniCore:", omniCoreAddress);

    // Verify contracts exist on-chain
    const regCode = await ethers.provider.getCode(registrationAddress);
    if (regCode === "0x") {
        throw new Error("OmniRegistration not found on-chain!");
    }
    const coreCode = await ethers.provider.getCode(omniCoreAddress);
    if (coreCode === "0x") {
        throw new Error("OmniCore not found on-chain!");
    }
    console.log("Both contracts verified on-chain\n");

    // --- Deploy OmniParticipation ---
    console.log("--- Deploying OmniParticipation (UUPS Proxy) ---");
    const OmniParticipation = await ethers.getContractFactory("OmniParticipation");
    const proxy = await upgrades.deployProxy(
        OmniParticipation,
        [registrationAddress, omniCoreAddress],
        {
            initializer: "initialize",
            kind: "uups"
        }
    );
    await proxy.waitForDeployment();

    const proxyAddress = await proxy.getAddress();
    const implAddress = await upgrades.erc1967.getImplementationAddress(proxyAddress);
    console.log("OmniParticipation proxy:", proxyAddress);
    console.log("OmniParticipation implementation:", implAddress);

    // Verify deployment
    const participation = await ethers.getContractAt("OmniParticipation", proxyAddress);
    const minValidatorScore = await participation.MIN_VALIDATOR_SCORE();
    const minListingNodeScore = await participation.MIN_LISTING_NODE_SCORE();
    console.log("MIN_VALIDATOR_SCORE:", Number(minValidatorScore));
    console.log("MIN_LISTING_NODE_SCORE:", Number(minListingNodeScore));

    // --- Update mainnet.json ---
    deployments.contracts.OmniParticipation = proxyAddress;
    deployments.contracts.OmniParticipationImplementation = implAddress;
    deployments.deployedAt = new Date().toISOString();
    deployments.notes.push(
        `OmniParticipation deployed: proxy ${proxyAddress}. ` +
        `Trustless participation scoring (100-point system).`
    );
    fs.writeFileSync(deploymentFile, JSON.stringify(deployments, null, 2));
    console.log("\nUpdated mainnet.json");

    const blockNum = await ethers.provider.getBlockNumber();
    console.log("Current block:", blockNum);

    console.log("\n=== OmniParticipation Deployed ===");
    console.log("Next: Deploy OmniValidatorRewards");
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error("FAILED:", error);
        process.exit(1);
    });
