const hre = require("hardhat");

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  const balance = await hre.ethers.provider.getBalance(deployer.address);
  
  console.log("\n💰 Account Balances:");
  console.log("  Deployer:", deployer.address);
  console.log("  Balance:", hre.ethers.formatEther(balance), "AVAX");
  
  const needed = hre.ethers.parseEther("0.1");
  if (balance.gte(needed)) {
    console.log("  ✅ Sufficient funds for ICM deployment");
  } else {
    const shortage = hre.ethers.formatEther(needed.sub(balance));
    console.log(`  ❌ Need ${shortage} more AVAX`);
    console.log("\n📋 To fund the account:");
    console.log("  1. Send AVAX from C-Chain to:", deployer.address);
    console.log("  2. Or use faucet: https://faucet.avax.network/");
  }
}

main().catch(console.error);
