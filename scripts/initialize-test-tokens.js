const hre = require("hardhat");

async function main() {
  const [deployer, user1, user2, validator] = await hre.ethers.getSigners();
  
  console.log("Initializing test environment with tokens...");
  console.log("Deployer:", deployer.address);
  console.log("User1:", user1.address);
  console.log("User2:", user2.address);
  console.log("Validator:", validator.address);
  
  // Get contract addresses from environment
  const omniCoinAddress = process.env.OMNICOIN_ADDRESS || "0x610178dA211FEF7D417bC0e6FeD39F05609AD788";
  const omniCoreAddress = process.env.OMNICORE_ADDRESS || "0xA51c1fc2f0D1a1b8494Ed1FE312d7C3a78Ed91C0";
  const privateOmniCoinAddress = process.env.PRIVATEOMNICOIN_ADDRESS || "0xB7f8BC63BbcaD18155201308C8f3540b07f84F5e";
  
  console.log("\nContract addresses:");
  console.log("OmniCoin:", omniCoinAddress);
  console.log("OmniCore:", omniCoreAddress);
  console.log("PrivateOmniCoin:", privateOmniCoinAddress);
  
  // Load deployed contracts - OmniBazaar ultra-lean architecture
  const omniCoin = await hre.ethers.getContractAt("OmniCoin", omniCoinAddress);
  const omniCore = await hre.ethers.getContractAt("OmniCore", omniCoreAddress);
  const privateOmniCoin = await hre.ethers.getContractAt("PrivateOmniCoin", privateOmniCoinAddress);
  
  // Check if deployer has MINTER_ROLE
  const MINTER_ROLE = await omniCoin.MINTER_ROLE();
  const hasMinterRole = await omniCoin.hasRole(MINTER_ROLE, deployer.address);
  console.log("\nDeployer has MINTER_ROLE:", hasMinterRole);
  
  if (!hasMinterRole) {
    console.log("❌ Deployer doesn't have MINTER_ROLE. Cannot mint tokens.");
    return;
  }
  
  // Mint initial tokens for testing
  const initialSupply = hre.ethers.parseEther("1000000"); // 1M XOM per account
  
  console.log("\nMinting XOM tokens...");
  
  try {
    // Mint to deployer
    console.log("Minting", hre.ethers.formatEther(initialSupply), "XOM to deployer");
    await omniCoin.mint(deployer.address, initialSupply);
    
    // Mint to test users
    console.log("Minting", hre.ethers.formatEther(initialSupply), "XOM to user1");
    await omniCoin.mint(user1.address, initialSupply);
    
    console.log("Minting", hre.ethers.formatEther(initialSupply), "XOM to user2");
    await omniCoin.mint(user2.address, initialSupply);
    
    // Mint extra for validator (needs to stake)
    const validatorSupply = hre.ethers.parseEther("2000000"); // 2M XOM for validator
    console.log("Minting", hre.ethers.formatEther(validatorSupply), "XOM to validator");
    await omniCoin.mint(validator.address, validatorSupply);
    
    // Also mint to computation node addresses if they exist
    const testUser1PrivKey = process.env.TEST_USER_1_PRIVATE_KEY || "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d";
    const testUser2PrivKey = process.env.TEST_USER_2_PRIVATE_KEY || "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a";
    
    if (testUser1PrivKey) {
      const computationNode1 = new hre.ethers.Wallet(testUser1PrivKey).address;
      console.log("Minting", hre.ethers.formatEther(validatorSupply), "XOM to computation node 1:", computationNode1);
      await omniCoin.mint(computationNode1, validatorSupply);
    }
    
    if (testUser2PrivKey) {
      const computationNode2 = new hre.ethers.Wallet(testUser2PrivKey).address;
      console.log("Minting", hre.ethers.formatEther(validatorSupply), "XOM to computation node 2:", computationNode2);
      await omniCoin.mint(computationNode2, validatorSupply);
    }
    
    // Grant MINTER_ROLE to OmniCore for future operations
    console.log("\nGranting MINTER_ROLE to OmniCore contract...");
    await omniCoin.grantRole(MINTER_ROLE, omniCoreAddress);
    
    // Check final balances
    console.log("\n✅ Token distribution complete!");
    console.log("\nFinal balances:");
    console.log("Deployer:", hre.ethers.formatEther(await omniCoin.balanceOf(deployer.address)), "XOM");
    console.log("User1:", hre.ethers.formatEther(await omniCoin.balanceOf(user1.address)), "XOM");
    console.log("User2:", hre.ethers.formatEther(await omniCoin.balanceOf(user2.address)), "XOM");
    console.log("Validator:", hre.ethers.formatEther(await omniCoin.balanceOf(validator.address)), "XOM");
    
    console.log("\nTotal supply:", hre.ethers.formatEther(await omniCoin.totalSupply()), "XOM");
    
  } catch (error) {
    console.error("Error during initialization:", error);
    throw error;
  }
  
  // TODO: Future production deployment tasks:
  // - Load legacy users from /home/rickc/OmniBazaar/Users/omnicoin_usernames_balances.json
  // - Mint tokens according to legacy balances
  // - Register legacy usernames in UsernameRegistry
  // - Set up ODDAO treasury address
  // - Configure fee distributions
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });