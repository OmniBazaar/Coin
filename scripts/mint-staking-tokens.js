const hre = require("hardhat");

/**
 * @dev Mint additional XOM tokens for computation node staking
 * The computation nodes require 10,000 XOM each for staking
 */
async function main() {
  const [deployer, user1, user2, validator] = await hre.ethers.getSigners();
  
  console.log("Minting additional XOM for staking requirements...");
  console.log("=================================================");
  
  // Get contract address
  const omniCoinAddress = process.env.OMNICOIN_ADDRESS || "0x610178dA211FEF7D417bC0e6FeD39F05609AD788";
  const omniCoin = await hre.ethers.getContractAt("OmniCoin", omniCoinAddress);
  
  // Staking requirement from config
  const stakingRequirement = hre.ethers.parseEther("10000"); // 10,000 XOM
  
  // User1 and User2 are the computation node operators
  console.log("\nChecking current balances...");
  const user1Balance = await omniCoin.balanceOf(user1.address);
  const user2Balance = await omniCoin.balanceOf(user2.address);
  
  console.log("User1 current balance:", hre.ethers.formatEther(user1Balance), "XOM");
  console.log("User2 current balance:", hre.ethers.formatEther(user2Balance), "XOM");
  console.log("Required for staking:", hre.ethers.formatEther(stakingRequirement), "XOM");
  
  try {
    // Mint additional tokens if needed
    if (user1Balance < stakingRequirement) {
      const needed = stakingRequirement - user1Balance;
      console.log("\nMinting", hre.ethers.formatEther(needed), "XOM to user1 for staking");
      await omniCoin.mint(user1.address, needed);
    }
    
    if (user2Balance < stakingRequirement) {
      const needed = stakingRequirement - user2Balance;
      console.log("Minting", hre.ethers.formatEther(needed), "XOM to user2 for staking");
      await omniCoin.mint(user2.address, needed);
    }
    
    // Verify final balances
    console.log("\n✅ Staking tokens minted!");
    console.log("\nFinal balances:");
    console.log("User1:", hre.ethers.formatEther(await omniCoin.balanceOf(user1.address)), "XOM");
    console.log("User2:", hre.ethers.formatEther(await omniCoin.balanceOf(user2.address)), "XOM");
    
  } catch (error) {
    console.error("❌ Error minting tokens:", error.message);
    process.exit(1);
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });