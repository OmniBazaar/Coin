#!/usr/bin/env node
/**
 * Check COTI Testnet Balance
 *
 * Displays the balance of the deployment account on COTI testnet.
 */

require("dotenv").config();
const { ethers } = require("hardhat");

async function main() {
  const [deployer] = await ethers.getSigners();
  const provider = ethers.provider;

  console.log("\n💰 Checking COTI Testnet Balance");
  console.log("═".repeat(70));

  // Get network info
  const network = await provider.getNetwork();
  console.log("\n🌐 Network Information:");
  console.log("   Name:", network.name);
  console.log("   Chain ID:", network.chainId.toString());

  // Get account info
  console.log("\n📍 Account Information:");
  console.log("   Address:", deployer.address);

  // Get balance
  const balance = await provider.getBalance(deployer.address);
  const balanceInCOTI = ethers.formatEther(balance);

  console.log("\n💵 Balance:");
  console.log("   ", balanceInCOTI, "COTI");
  console.log("   ", balance.toString(), "wei");

  // Check if sufficient for deployment
  const minRequired = ethers.parseEther("0.05");
  const isEnough = balance >= minRequired;

  console.log("\n📊 Deployment Readiness:");
  console.log("   Minimum Required:", ethers.formatEther(minRequired), "COTI");
  console.log("   Status:", isEnough ? "✅ READY" : "❌ INSUFFICIENT");

  if (!isEnough) {
    console.log("\n⚠️  You need to request tokens from the COTI faucet:");
    console.log("   1. Join Discord: https://discord.coti.io");
    console.log("   2. In faucet channel, send:");
    console.log(`      testnet ${deployer.address}`);
  } else {
    console.log("\n✅ Sufficient balance for deployment!");
    console.log("   Ready to deploy privacy contracts.");
  }

  console.log("\n" + "═".repeat(70) + "\n");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("❌ Error:", error.message);
    process.exit(1);
  });
