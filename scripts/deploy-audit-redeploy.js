/**
 * @file deploy-audit-redeploy.js
 * @description Redeploy 4 contracts modified by security audit on mainnet (chain 88008).
 *
 * The following contracts were deployed before the audit, then their Solidity
 * source was updated. They must be redeployed with the corrected constructor/
 * initialize signatures:
 *
 *   1. OmniENS (Immutable) — added stakingPool + protocolTreasury params
 *   2. OmniChatFee (Immutable) — added protocolTreasury param
 *   3. DEXSettlement (Immutable) — changed to 3-recipient fee split
 *   4. OmniArbitration (UUPS) — added protocolTreasury to initialize
 *
 * The old deployed addresses remain on-chain but are superseded.
 * mainnet.json is updated with the new addresses.
 *
 * Usage:
 *   npx hardhat run scripts/deploy-audit-redeploy.js --network mainnet
 */
const { ethers, upgrades } = require("hardhat");
const fs = require("fs");
const path = require("path");

/** Real ODDAO treasury address */
const ODDAO_TREASURY = "0x664B6347a69A22b35348D42E4640CA92e1609378";

/** Protocol treasury address (Pioneer Phase: deployer) */
const PROTOCOL_TREASURY = "0xaDAD7751DcDd2E30015C173F2c35a56e467CD9ba";

async function main() {
    console.log("=== Audit Redeployment — 4 Modified Contracts ===\n");

    const [deployer] = await ethers.getSigners();
    console.log("Deployer:", deployer.address);

    const network = await ethers.provider.getNetwork();
    if (network.chainId !== 88008n) {
        throw new Error(`Wrong network! Expected 88008, got ${network.chainId}`);
    }

    const balance = await ethers.provider.getBalance(deployer.address);
    console.log("Native balance:", ethers.formatEther(balance), "tokens\n");

    // Load mainnet.json
    const deploymentFile = path.join(__dirname, "../deployments/mainnet.json");
    const deployments = JSON.parse(fs.readFileSync(deploymentFile, "utf-8"));

    const xomAddress = deployments.contracts.OmniCoin;
    const stakingPoolAddress = deployments.contracts.StakingRewardPool;
    const participationAddress = deployments.contracts.OmniParticipation;
    const escrowAddress = deployments.contracts.MinimalEscrow;

    console.log("OmniCoin:", xomAddress);
    console.log("StakingRewardPool:", stakingPoolAddress);
    console.log("ODDAO:", ODDAO_TREASURY);
    console.log("PROTOCOL_TREASURY:", PROTOCOL_TREASURY);
    console.log("");

    let redeployed = 0;

    function save() {
        deployments.deployedAt = new Date().toISOString();
        fs.writeFileSync(deploymentFile, JSON.stringify(deployments, null, 2));
    }

    // ================================================================
    // 1. OmniENS (Immutable) — audit added stakingPool + protocolTreasury
    // Old: constructor(xomToken, oddaoTreasury)
    // New: constructor(xomToken, oddaoTreasury, stakingPool, protocolTreasury)
    // ================================================================
    console.log("--- 1. OmniENS (Immutable) — REDEPLOY ---");
    const oldENS = deployments.contracts.OmniENS;
    console.log("  Old address:", oldENS);

    const OmniENS = await ethers.getContractFactory("OmniENS");
    const omniENS = await OmniENS.deploy(
        xomAddress, ODDAO_TREASURY, stakingPoolAddress, PROTOCOL_TREASURY
    );
    await omniENS.waitForDeployment();
    const ensAddr = await omniENS.getAddress();
    deployments.contracts.OmniENS = ensAddr;
    console.log("  New address:", ensAddr);
    save();
    redeployed++;

    // ================================================================
    // 2. OmniChatFee (Immutable) — audit added protocolTreasury
    // Old: constructor(xomToken, stakingPool, oddaoTreasury, baseFee)
    // New: constructor(xomToken, stakingPool, oddaoTreasury, protocolTreasury, baseFee)
    // ================================================================
    console.log("--- 2. OmniChatFee (Immutable) — REDEPLOY ---");
    const oldChatFee = deployments.contracts.OmniChatFee;
    console.log("  Old address:", oldChatFee);

    const baseFee = ethers.parseEther("1"); // 1 XOM base fee per message
    const OmniChatFee = await ethers.getContractFactory("OmniChatFee");
    const chatFee = await OmniChatFee.deploy(
        xomAddress, stakingPoolAddress, ODDAO_TREASURY, PROTOCOL_TREASURY, baseFee
    );
    await chatFee.waitForDeployment();
    const chatFeeAddr = await chatFee.getAddress();
    deployments.contracts.OmniChatFee = chatFeeAddr;
    console.log("  New address:", chatFeeAddr);
    save();
    redeployed++;

    // ================================================================
    // 3. DEXSettlement (Immutable) — audit changed fee structure
    // Old: constructor(oddao, stakingPool) — 2 recipients
    // New: constructor(liquidityPool, oddao, protocolTreasury) — 3 recipients
    // Fee split: 70% LP, 20% ODDAO, 10% Protocol
    // Pioneer Phase: liquidityPool = StakingRewardPool
    // ================================================================
    console.log("--- 3. DEXSettlement (Immutable) — REDEPLOY ---");
    const oldDEX = deployments.contracts.DEXSettlement;
    console.log("  Old address:", oldDEX);

    const DEXSettlement = await ethers.getContractFactory("DEXSettlement");
    const dexSettlement = await DEXSettlement.deploy(
        stakingPoolAddress,   // liquidityPool (70% of net fees)
        ODDAO_TREASURY,       // ODDAO treasury (20% of net fees)
        PROTOCOL_TREASURY     // protocol treasury (10%)
    );
    await dexSettlement.waitForDeployment();
    const dexAddr = await dexSettlement.getAddress();
    deployments.contracts.DEXSettlement = dexAddr;
    console.log("  New address:", dexAddr);
    save();
    redeployed++;

    // ================================================================
    // 4. OmniArbitration (UUPS) — audit added protocolTreasury
    // Old: initialize(participation, escrow, xomToken, oddaoTreasury)
    // New: initialize(participation, escrow, xomToken, oddaoTreasury, protocolTreasury)
    // Redeploy fresh proxy (no state to preserve — just deployed)
    // ================================================================
    console.log("--- 4. OmniArbitration (UUPS) — REDEPLOY ---");
    const oldArb = deployments.contracts.OmniArbitration;
    console.log("  Old proxy:", oldArb);

    const OmniArbitration = await ethers.getContractFactory("OmniArbitration");
    const arbitrationProxy = await upgrades.deployProxy(
        OmniArbitration,
        [participationAddress, escrowAddress, xomAddress, ODDAO_TREASURY, PROTOCOL_TREASURY],
        { initializer: "initialize", kind: "uups" }
    );
    await arbitrationProxy.waitForDeployment();
    const arbitrationAddr = await arbitrationProxy.getAddress();
    const arbitrationImpl = await upgrades.erc1967.getImplementationAddress(arbitrationAddr);
    deployments.contracts.OmniArbitration = arbitrationAddr;
    deployments.contracts.OmniArbitrationImplementation = arbitrationImpl;
    console.log("  New proxy:", arbitrationAddr);
    console.log("  New impl:", arbitrationImpl);
    save();
    redeployed++;

    // ================================================================
    // Summary
    // ================================================================
    deployments.notes.push(
        `Audit redeployment: ${redeployed} contracts redeployed with audit fixes. ` +
        `OmniENS: ${oldENS} → ${ensAddr} (added stakingPool+protocolTreasury). ` +
        `OmniChatFee: ${oldChatFee} → ${chatFeeAddr} (added protocolTreasury). ` +
        `DEXSettlement: ${oldDEX} → ${dexAddr} (3-recipient fee split: LP 70%, ODDAO 20%, Protocol 10%). ` +
        `OmniArbitration: ${oldArb} → ${arbitrationAddr} (added protocolTreasury). ` +
        `Old addresses are superseded. Pioneer Phase: protocolTreasury = deployer.`
    );
    save();

    console.log("\n=== AUDIT REDEPLOYMENT COMPLETE ===");
    console.log("Contracts redeployed:", redeployed);

    const nativeBalance = await ethers.provider.getBalance(deployer.address);
    console.log("Deployer native balance remaining:", ethers.formatEther(nativeBalance), "tokens");
    console.log("\nNext: Run deploy-remaining-phase3b-mainnet.js for 20 remaining contracts");
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error("FAILED:", error);
        process.exit(1);
    });
