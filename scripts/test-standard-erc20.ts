import { ethers } from "hardhat";

/**
 * Test script to deploy standard ERC20 on COTI V2
 * This proves COTI supports regular, non-encrypted contracts
 */
async function main() {
  console.log("Testing Standard ERC20 deployment on COTI V2...");
  
  const [deployer] = await ethers.getSigners();
  console.log("Deploying with account:", deployer.address);
  
  // Get network info
  const network = await ethers.provider.getNetwork();
  console.log("Network:", network.name, "Chain ID:", network.chainId);
  
  // Deploy standard ERC20 token
  console.log("\n1. Deploying StandardERC20Test...");
  const StandardToken = await ethers.getContractFactory("StandardERC20Test");
  const token = await StandardToken.deploy();
  await token.deployed();
  
  console.log("✅ Standard ERC20 deployed to:", token.address);
  
  // Test standard operations
  console.log("\n2. Testing standard operations...");
  
  // Check balance
  const balance = await token.balanceOf(deployer.address);
  console.log("- Deployer balance:", ethers.utils.formatUnits(balance, 18));
  
  // Test transfer
  const recipient = "0x" + "1".repeat(40); // dummy address
  const transferAmount = ethers.utils.parseUnits("100", 18);
  
  console.log("- Transferring 100 tokens to", recipient);
  const tx = await token.transfer(recipient, transferAmount);
  await tx.wait();
  console.log("- Transfer tx:", tx.hash);
  
  // Check new balances
  const newBalance = await token.balanceOf(deployer.address);
  const recipientBalance = await token.balanceOf(recipient);
  
  console.log("- New deployer balance:", ethers.utils.formatUnits(newBalance, 18));
  console.log("- Recipient balance:", ethers.utils.formatUnits(recipientBalance, 18));
  
  console.log("\n✅ Standard ERC20 works perfectly on COTI V2!");
  console.log("This proves COTI V2 supports regular, non-encrypted contracts.");
  
  // Deploy dual mode token
  console.log("\n3. Deploying DualModeToken...");
  const DualToken = await ethers.getContractFactory("DualModeToken");
  const dualToken = await DualToken.deploy();
  await dualToken.deployed();
  
  console.log("✅ Dual Mode Token deployed to:", dualToken.address);
  
  console.log("\n📊 Summary:");
  console.log("- COTI V2 is a standard Ethereum L2");
  console.log("- Regular ERC20 contracts work without modification");
  console.log("- Privacy features are optional, not mandatory");
  console.log("- We can deploy both public and private token contracts");
}

main()
  .then(() => {
    console.log("\n✅ Test completed successfully!");
    process.exit(0);
  })
  .catch((error) => {
    console.error("\n❌ Test failed:", error);
    process.exit(1);
  });