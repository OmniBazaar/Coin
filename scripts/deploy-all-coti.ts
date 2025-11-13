#!/usr/bin/env node
/**
 * Deploy All Three Privacy Contracts to COTI Testnet
 *
 * Deploys simplified non-upgradeable versions:
 * - PrivateOmniCoinSimple
 * - OmniPrivacyBridgeSimple
 * - PrivateDEXSimple
 */

import { ethers } from "hardhat";
import * as fs from "fs";
import * as path from "path";

async function main() {
  console.log("\n🚀 Deploying All Privacy Contracts to COTI Testnet");
  console.log("═".repeat(70));

  const [deployer] = await ethers.getSigners();
  const provider = ethers.provider;
  const network = await provider.getNetwork();

  console.log("\n🌐 Network:", network.name);
  console.log("   Chain ID:", network.chainId.toString());
  console.log("\n📍 Deployer:", deployer.address);

  const balance = await provider.getBalance(deployer.address);
  console.log("💰 Balance:", ethers.formatEther(balance), "COTI\n");

  console.log("═".repeat(70));

  const deployedContracts: any = {
    network: "coti-testnet",
    chainId: Number(network.chainId),
    timestamp: new Date().toISOString(),
    deployer: deployer.address,
    contracts: {},
    rpcUrl: "https://testnet.coti.io/rpc",
    gasUsed: {}
  };

  // ========================================================================
  // 1. PrivateOmniCoinSimple
  // ========================================================================

  console.log("\n1️⃣  PrivateOmniCoinSimple");
  console.log("─".repeat(70));

  const PrivateOmniCoin = await ethers.getContractFactory("PrivateOmniCoinSimple");
  const pxom = await PrivateOmniCoin.deploy({ gasLimit: 10000000 });
  await pxom.waitForDeployment();

  const pxomAddr = await pxom.getAddress();
  console.log("   ✅ Deployed:", pxomAddr);

  const privacyAvail = await pxom.privacyAvailable();
  console.log("   🔒 Privacy:", privacyAvail ? "ENABLED ✅" : "DISABLED ⚠️");

  const supply = await pxom.totalSupply();
  console.log("   💰 Supply:", ethers.formatEther(supply), "pXOM");

  deployedContracts.contracts.PrivateOmniCoin = {
    proxy: pxomAddr,
    implementation: pxomAddr
  };

  // ========================================================================
  // 2. OmniPrivacyBridgeSimple
  // ========================================================================

  console.log("\n2️⃣  OmniPrivacyBridgeSimple");
  console.log("─".repeat(70));

  const OmniPrivacyBridge = await ethers.getContractFactory("OmniPrivacyBridgeSimple");
  const bridge = await OmniPrivacyBridge.deploy(
    pxomAddr,
    "0x5FC8d32690cc91D4c39d9d3abcBD16989F875707", // OmniCoin on Avalanche Fuji
    ethers.parseEther("1000000"), // 1M max conversion
    { gasLimit: 8000000 }
  );
  await bridge.waitForDeployment();

  const bridgeAddr = await bridge.getAddress();
  console.log("   ✅ Deployed:", bridgeAddr);

  deployedContracts.contracts.OmniPrivacyBridge = {
    proxy: bridgeAddr,
    implementation: bridgeAddr
  };

  // ========================================================================
  // 3. PrivateDEXSimple
  // ========================================================================

  console.log("\n3️⃣  PrivateDEXSimple");
  console.log("─".repeat(70));

  const PrivateDEX = await ethers.getContractFactory("PrivateDEXSimple");
  const dex = await PrivateDEX.deploy({ gasLimit: 12000000 });
  await dex.waitForDeployment();

  const dexAddr = await dex.getAddress();
  console.log("   ✅ Deployed:", dexAddr);

  const stats = await dex.getPrivacyStats();
  console.log("   📊 Orders:", stats[0].toString(), "| Trades:", stats[1].toString());

  deployedContracts.contracts.PrivateDEX = {
    proxy: dexAddr,
    implementation: dexAddr
  };

  // ========================================================================
  // Save
  // ========================================================================

  console.log("\n" + "═".repeat(70));
  console.log("\n📝 Deployment Summary:");
  console.log(JSON.stringify(deployedContracts, null, 2));

  const deploymentsDir = path.join(__dirname, "..", "deployments");
  if (!fs.existsSync(deploymentsDir)) {
    fs.mkdirSync(deploymentsDir, { recursive: true });
  }

  const outputPath = path.join(deploymentsDir, "coti-testnet.json");
  fs.writeFileSync(outputPath, JSON.stringify(deployedContracts, null, 2));
  console.log("\n✅ Saved to:", outputPath);

  const finalBalance = await provider.getBalance(deployer.address);
  const spent = balance - finalBalance;
  console.log("\n💰 Final Balance:", ethers.formatEther(finalBalance), "COTI");
  console.log("   Total Spent:", ethers.formatEther(spent), "COTI");

  console.log("\n" + "═".repeat(70));
  console.log("\n🎉 ALL CONTRACTS DEPLOYED!");
  console.log("\n📋 Next: Sync addresses to all modules");
  console.log("   cd /home/rickc/OmniBazaar");
  console.log("   ./scripts/sync-contract-addresses.sh coti-testnet");
  console.log("\n" + "═".repeat(70) + "\n");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("\n❌ Failed:", error.message);
    process.exit(1);
  });
