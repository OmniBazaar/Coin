const hre = require("hardhat");

/**
 * @dev Debug script to check actual balances vs staking requirements
 */
async function main() {
  const [deployer, user1, user2] = await hre.ethers.getSigners();
  
  console.log("Debug: Balance Check");
  console.log("===================");
  
  // Contract addresses
  const omniCoinAddress = "0x610178dA211FEF7D417bC0e6FeD39F05609AD788";
  const omniCoreAddress = "0xA51c1fc2f0D1a1b8494Ed1FE312d7C3a78Ed91C0";
  
  // Load contracts
  const omniCoin = await hre.ethers.getContractAt("OmniCoin", omniCoinAddress);
  const omniCore = await hre.ethers.getContractAt("OmniCore", omniCoreAddress);
  
  // Config values from computation nodes
  const stakingRequirement = "10000000000000000000000"; // From config file
  
  console.log("\nStaking requirement from config:", stakingRequirement);
  console.log("Staking requirement in XOM:", hre.ethers.formatEther(stakingRequirement));
  
  // Check balances
  const user1Balance = await omniCoin.balanceOf(user1.address);
  const user2Balance = await omniCoin.balanceOf(user2.address);
  
  console.log("\nUser1 (Computation Node 1):");
  console.log("  Address:", user1.address);
  console.log("  Balance (wei):", user1Balance.toString());
  console.log("  Balance (XOM):", hre.ethers.formatEther(user1Balance));
  console.log("  Has enough?:", user1Balance >= BigInt(stakingRequirement));
  
  console.log("\nUser2 (Computation Node 2):");
  console.log("  Address:", user2.address);
  console.log("  Balance (wei):", user2Balance.toString());
  console.log("  Balance (XOM):", hre.ethers.formatEther(user2Balance));
  console.log("  Has enough?:", user2Balance >= BigInt(stakingRequirement));
  
  // Check if already staked
  try {
    const stake1 = await omniCore.getStake(user1.address);
    console.log("\nUser1 existing stake:", {
      amount: hre.ethers.formatEther(stake1.amount),
      active: stake1.active
    });
  } catch (e) {
    console.log("\nUser1 stake check failed:", e.message);
  }
  
  try {
    const stake2 = await omniCore.getStake(user2.address);
    console.log("User2 existing stake:", {
      amount: hre.ethers.formatEther(stake2.amount),
      active: stake2.active
    });
  } catch (e) {
    console.log("User2 stake check failed:", e.message);
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });