#!/usr/bin/env node
/**
 * Generate COTI Testnet Deployment Account
 *
 * Creates a new Ethereum wallet for deploying contracts to COTI testnet.
 * Saves private key to .env file for use with Hardhat.
 */

const { ethers } = require("ethers");
const fs = require("fs");
const path = require("path");

async function main() {
  console.log("🔐 Generating new COTI Testnet deployment account...\n");

  // Generate new random wallet
  const wallet = ethers.Wallet.createRandom();

  console.log("✅ Account Generated Successfully!");
  console.log("═".repeat(70));
  console.log("\n📍 PUBLIC ADDRESS (request COTI from faucet):");
  console.log("   ", wallet.address);
  console.log("\n🔑 PRIVATE KEY (keep secret!):");
  console.log("   ", wallet.privateKey);
  console.log("\n═".repeat(70));

  // Update .env file
  const envPath = path.join(__dirname, "..", ".env");
  let envContent = "";

  // Read existing .env if it exists
  if (fs.existsSync(envPath)) {
    envContent = fs.readFileSync(envPath, "utf8");
  }

  // Check if COTI_DEPLOYER_PRIVATE_KEY already exists
  if (envContent.includes("COTI_DEPLOYER_PRIVATE_KEY=")) {
    console.log("\n⚠️  COTI_DEPLOYER_PRIVATE_KEY already exists in .env");
    console.log("    To update, manually edit .env file");
  } else {
    // Append new key
    const newLine = `\n# COTI Testnet Deployment Account (Generated ${new Date().toISOString()})\nCOTI_DEPLOYER_PRIVATE_KEY=${wallet.privateKey}\n`;
    fs.appendFileSync(envPath, newLine);
    console.log("\n✅ Private key saved to .env");
  }

  console.log("\n📋 NEXT STEPS:");
  console.log("   1. Join COTI Discord: https://discord.coti.io");
  console.log("   2. Go to faucet: https://faucet.coti.io/");
  console.log("   3. In Discord, send this message:");
  console.log(`      testnet ${wallet.address}`);
  console.log("   4. Wait for confirmation (1-2 minutes)");
  console.log("   5. Check balance:");
  console.log(`      npx hardhat run scripts/check-balance.js --network cotiTestnet`);
  console.log("   6. Deploy contracts:");
  console.log(`      npx hardhat run scripts/deploy-coti-privacy.ts --network cotiTestnet`);
  console.log("\n═".repeat(70));
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("❌ Error:", error);
    process.exit(1);
  });
