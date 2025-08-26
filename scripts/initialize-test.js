const hre = require("hardhat");

/**
 * @dev Initialize OmniCoin for testing - Ultra-lean architecture version
 * This script:
 * 1. Checks if OmniCoin is initialized
 * 2. Initializes if needed (grants roles and mints initial supply)
 * 3. Mints additional tokens to test accounts
 * 4. Grants MINTER_ROLE to OmniCore for future operations
 */
async function main() {
  const [deployer, user1, user2, validator] = await hre.ethers.getSigners();
  
  console.log("OmniBazaar Ultra-lean Architecture - Token Initialization");
  console.log("========================================================");
  console.log("Deployer:", deployer.address);
  console.log("User1:", user1.address);
  console.log("User2:", user2.address);
  console.log("Validator:", validator.address);
  
  // Get contract addresses with fallback to known addresses
  const omniCoinAddress = process.env.OMNICOIN_ADDRESS || "0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512";
  const omniCoreAddress = process.env.OMNICORE_ADDRESS || "0xA51c1fc2f0D1a1b8494Ed1FE312d7C3a78Ed91C0";
  
  console.log("\nContract addresses:");
  console.log("OmniCoin:", omniCoinAddress);
  console.log("OmniCore:", omniCoreAddress);
  
  // Load OmniCoin contract
  const omniCoin = await hre.ethers.getContractAt("OmniCoin", omniCoinAddress);
  
  // Check if initialized
  const totalSupply = await omniCoin.totalSupply();
  console.log("\nCurrent total supply:", hre.ethers.formatEther(totalSupply), "XOM");
  
  // Initialize if needed
  if (totalSupply === 0n) {
    console.log("\nOmniCoin not initialized. Initializing now...");
    try {
      const tx = await omniCoin.initialize();
      await tx.wait();
      console.log("✅ OmniCoin initialized successfully!");
      
      const newSupply = await omniCoin.totalSupply();
      console.log("Initial supply minted:", hre.ethers.formatEther(newSupply), "XOM");
    } catch (error) {
      console.error("❌ Failed to initialize:", error.message);
      process.exit(1);
    }
  } else {
    console.log("\nOmniCoin already initialized.");
  }
  
  // Check roles
  const MINTER_ROLE = await omniCoin.MINTER_ROLE();
  const hasMinterRole = await omniCoin.hasRole(MINTER_ROLE, deployer.address);
  console.log("\nDeployer has MINTER_ROLE:", hasMinterRole);
  
  if (!hasMinterRole) {
    console.log("❌ Deployer doesn't have MINTER_ROLE. Cannot mint additional tokens.");
    console.log("This may happen if OmniCoin was initialized by a different account.");
    process.exit(1);
  }
  
  // Mint tokens for test accounts
  console.log("\nMinting tokens for test accounts...");
  
  try {
    // Define amounts
    const userAmount = hre.ethers.parseEther("1000000"); // 1M XOM
    const validatorAmount = hre.ethers.parseEther("2000000"); // 2M XOM
    
    // Check current balances
    const deployerBalance = await omniCoin.balanceOf(deployer.address);
    const user1Balance = await omniCoin.balanceOf(user1.address);
    const user2Balance = await omniCoin.balanceOf(user2.address);
    const validatorBalance = await omniCoin.balanceOf(validator.address);
    
    // Only mint if accounts don't have sufficient balance
    if (user1Balance < userAmount) {
      console.log("Minting", hre.ethers.formatEther(userAmount), "XOM to user1");
      await omniCoin.mint(user1.address, userAmount);
    }
    
    if (user2Balance < userAmount) {
      console.log("Minting", hre.ethers.formatEther(userAmount), "XOM to user2");
      await omniCoin.mint(user2.address, userAmount);
    }
    
    if (validatorBalance < validatorAmount) {
      console.log("Minting", hre.ethers.formatEther(validatorAmount), "XOM to validator");
      await omniCoin.mint(validator.address, validatorAmount);
    }
    
    // Grant MINTER_ROLE to OmniCore if not already granted
    const coreHasMinterRole = await omniCoin.hasRole(MINTER_ROLE, omniCoreAddress);
    if (!coreHasMinterRole) {
      console.log("\nGranting MINTER_ROLE to OmniCore contract...");
      await omniCoin.grantRole(MINTER_ROLE, omniCoreAddress);
      console.log("✅ MINTER_ROLE granted to OmniCore");
    }
    
    // Display final balances
    console.log("\n✅ Token initialization complete!");
    console.log("\nFinal balances:");
    console.log("Deployer:", hre.ethers.formatEther(await omniCoin.balanceOf(deployer.address)), "XOM");
    console.log("User1:", hre.ethers.formatEther(await omniCoin.balanceOf(user1.address)), "XOM");
    console.log("User2:", hre.ethers.formatEther(await omniCoin.balanceOf(user2.address)), "XOM");
    console.log("Validator:", hre.ethers.formatEther(await omniCoin.balanceOf(validator.address)), "XOM");
    console.log("\nTotal supply:", hre.ethers.formatEther(await omniCoin.totalSupply()), "XOM");
    
  } catch (error) {
    console.error("❌ Error during token minting:", error.message);
    process.exit(1);
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });