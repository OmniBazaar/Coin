import { ethers } from "hardhat";
import { Contract } from "ethers";

async function main() {
    const [deployer] = await ethers.getSigners();
    console.log("Deploying contracts with the account:", deployer.address);

    // Deploy OmniCoinConfig
    const OmniCoinConfig = await ethers.getContractFactory("OmniCoinConfig");
    const config = await OmniCoinConfig.deploy();
    await config.deployed();
    console.log("OmniCoinConfig deployed to:", config.address);

    // Deploy OmniCoin
    const OmniCoin = await ethers.getContractFactory("OmniCoin");
    const omniCoin = await OmniCoin.deploy(
        "OmniCoin",
        "OMNI",
        config.address
    );
    await omniCoin.deployed();
    console.log("OmniCoin deployed to:", omniCoin.address);

    // Set up initial configuration
    console.log("Setting up initial configuration...");

    // Set token economics
    await config.setTokenEconomics(
        ethers.utils.parseUnits("1000000000", 6), // 1 billion tokens
        ethers.utils.parseUnits("1000", 6), // 1000 tokens per block
        ethers.utils.parseUnits("2000000000", 6) // 2 billion max supply
    );

    // Add staking tiers
    await config.addStakingTier(
        ethers.utils.parseUnits("1000", 6),
        100, // 1x multiplier
        30 * 24 * 60 * 60, // 30 days
        10 // 10% penalty
    );

    await config.addStakingTier(
        ethers.utils.parseUnits("10000", 6),
        150, // 1.5x multiplier
        90 * 24 * 60 * 60, // 90 days
        15 // 15% penalty
    );

    await config.addStakingTier(
        ethers.utils.parseUnits("100000", 6),
        200, // 2x multiplier
        180 * 24 * 60 * 60, // 180 days
        20 // 20% penalty
    );

    // Set governance parameters
    await config.setGovernanceParams(
        ethers.utils.parseUnits("10000", 6), // 10k tokens for governance
        50, // 50 participation score
        ethers.utils.parseUnits("100000", 6), // 100k tokens for proposal
        3 * 24 * 60 * 60, // 3 days voting period
        20 // 20% quorum
    );

    // Set participation score parameters
    await config.setParticipationScoreParams(
        true, // Enable participation score
        10 // 10% multiplier
    );

    console.log("Initial configuration completed");

    // Verify contracts on Etherscan
    if (process.env.ETHERSCAN_API_KEY) {
        console.log("Verifying contracts on Etherscan...");
        await hre.run("verify:verify", {
            address: config.address,
            constructorArguments: [],
        });

        await hre.run("verify:verify", {
            address: omniCoin.address,
            constructorArguments: ["OmniCoin", "OMNI", config.address],
        });
    }
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });