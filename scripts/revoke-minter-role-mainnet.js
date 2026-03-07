/**
 * @file revoke-minter-role-mainnet.js
 * @description Revoke MINTER_ROLE from deployer on OmniCoin.
 *
 * Per trustless tokenomics: all 16.6B XOM are pre-minted and distributed.
 * No entity retains minting authority after deployment.
 *
 * Usage:
 *   npx hardhat run scripts/revoke-minter-role-mainnet.js --network mainnet
 */
const { ethers } = require("hardhat");
const fs = require("fs");
const path = require("path");

async function main() {
    console.log("=== Revoke MINTER_ROLE (Mainnet) ===\n");

    const [deployer] = await ethers.getSigners();
    console.log("Deployer:", deployer.address);

    const network = await ethers.provider.getNetwork();
    if (network.chainId !== 88008n) {
        throw new Error(`Wrong network! Expected 88008, got ${network.chainId}`);
    }

    // Load addresses from mainnet.json
    const deploymentFile = path.join(__dirname, "../deployments/mainnet.json");
    const deployments = JSON.parse(fs.readFileSync(deploymentFile, "utf-8"));

    const omniCoinAddress = deployments.contracts.OmniCoin;
    if (!omniCoinAddress) {
        throw new Error("OmniCoin not found in mainnet.json!");
    }

    const omniCoin = await ethers.getContractAt("OmniCoin", omniCoinAddress);
    const MINTER_ROLE = await omniCoin.MINTER_ROLE();

    // Check current state
    const hasMinter = await omniCoin.hasRole(MINTER_ROLE, deployer.address);
    console.log("Deployer has MINTER_ROLE:", hasMinter);

    if (!hasMinter) {
        console.log("MINTER_ROLE already revoked. Nothing to do.");
        return;
    }

    // Verify deployer balance is 0 (all tokens distributed)
    const balance = await omniCoin.balanceOf(deployer.address);
    console.log("Deployer XOM balance:", ethers.formatEther(balance), "XOM");

    if (balance !== 0n) {
        console.log("WARNING: Deployer still has", ethers.formatEther(balance), "XOM!");
        console.log("Ensure all distributions are complete before revoking MINTER_ROLE.");
    }

    // Verify total supply
    const totalSupply = await omniCoin.totalSupply();
    console.log("Total supply:", ethers.formatEther(totalSupply), "XOM");

    // Revoke MINTER_ROLE
    console.log("\n--- Revoking MINTER_ROLE from deployer ---");
    const revokeTx = await omniCoin.revokeRole(MINTER_ROLE, deployer.address);
    await revokeTx.wait();

    // Verify
    const hasMinterAfter = await omniCoin.hasRole(MINTER_ROLE, deployer.address);
    console.log("Deployer has MINTER_ROLE after revoke:", hasMinterAfter);

    if (hasMinterAfter) {
        throw new Error("MINTER_ROLE not revoked!");
    }

    // Update mainnet.json
    deployments.deployedAt = new Date().toISOString();
    deployments.notes.push(
        "MINTER_ROLE revoked from deployer. No entity can mint new XOM. " +
        "Trustless tokenomics enforced: 16.6B XOM total supply is final."
    );
    fs.writeFileSync(deploymentFile, JSON.stringify(deployments, null, 2));
    console.log("\nUpdated mainnet.json");

    console.log("\n=== MINTER_ROLE Revoked ===");
    console.log("Trustless tokenomics: 16,600,000,000 XOM total supply is FINAL.");
    console.log("No entity can mint new tokens.");
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error("FAILED:", error);
        process.exit(1);
    });
