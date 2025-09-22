import { ethers } from "hardhat";
import * as fs from "fs";
import * as path from "path";

async function loadDeploymentAddresses() {
  const network = process.env.HARDHAT_NETWORK || "localhost";
  const filePath = path.join(__dirname, "../../deployments", `${network}.json`);
  
  if (!fs.existsSync(filePath)) {
    throw new Error(`No deployment file found for network ${network}`);
  }
  
  return JSON.parse(fs.readFileSync(filePath, "utf8"));
}

async function saveDeploymentAddresses(addresses: any) {
  const network = process.env.HARDHAT_NETWORK || "localhost";
  const filePath = path.join(__dirname, "../../deployments", `${network}.json`);
  
  const existing = JSON.parse(fs.readFileSync(filePath, "utf8"));
  const updated = { ...existing, ...addresses, timestamp: new Date().toISOString() };
  
  fs.writeFileSync(filePath, JSON.stringify(updated, null, 2));
  console.log(`Deployment addresses updated in ${filePath}`);
}

async function main() {
  console.log("Starting Financial Contracts Deployment...");
  const [deployer] = await ethers.getSigners();
  console.log("Deploying with account:", deployer.address);
  
  // Load existing addresses
  const addresses = await loadDeploymentAddresses();
  console.log("\nLoaded addresses:");
  console.log("- Registry:", addresses.Registry);
  console.log("- OmniCoinCore:", addresses.OmniCoinCore);
  console.log("- PrivacyFeeManager:", addresses.PrivacyFeeManager);
  
  // Get registry contract
  const registry = await ethers.getContractAt("OmniCoinRegistry", addresses.Registry);
  
  // Deploy FinancialDeploymentHelper
  console.log("\n1. Deploying FinancialDeploymentHelper...");
  const FinancialHelper = await ethers.getContractFactory("FinancialDeploymentHelper");
  const helper = await FinancialHelper.deploy(addresses.Registry);
  await helper.deployed();
  console.log("FinancialDeploymentHelper deployed to:", helper.address);
  
  // Deploy all financial contracts
  console.log("\n2. Deploying financial contracts...");
  const tx = await helper.deployAll();
  const receipt = await tx.wait();
  console.log("Transaction hash:", receipt.transactionHash);
  
  // Get deployed addresses from helper
  console.log("\n3. Getting deployed contract addresses...");
  const escrowAddress = await helper.escrow();
  const paymentAddress = await helper.payment();
  const stakingAddress = await helper.staking();
  const bridgeAddress = await helper.bridge();
  const arbitrationAddress = await helper.arbitration();
  
  console.log("- Escrow:", escrowAddress);
  console.log("- Payment:", paymentAddress);
  console.log("- Staking:", stakingAddress);
  console.log("- Bridge:", bridgeAddress);
  console.log("- Arbitration:", arbitrationAddress);
  
  // Update registry
  console.log("\n4. Updating registry...");
  
  const updates = [
    { name: "ESCROW", address: escrowAddress },
    { name: "PAYMENT", address: paymentAddress },
    { name: "STAKING", address: stakingAddress },
    { name: "BRIDGE", address: bridgeAddress },
    { name: "ARBITRATION", address: arbitrationAddress }
  ];
  
  for (const update of updates) {
    const tx = await registry.setContract(
      ethers.id(update.name),
      update.address
    );
    await tx.wait();
    console.log(`- Set ${update.name} in registry`);
  }
  
  // Configure contracts
  console.log("\n5. Configuring contracts...");
  
  // Configure Staking
  const staking = await ethers.getContractAt("OmniCoinStaking", stakingAddress);
  let configTx = await staking.setRewardRate(100); // 100 basis points = 1%
  await configTx.wait();
  console.log("- Set staking reward rate to 1%");
  
  configTx = await staking.setMinStakingAmount(ethers.parseUnits("100", 6)); // 100 XOM minimum
  await configTx.wait();
  console.log("- Set minimum staking amount to 100 XOM");
  
  // Save addresses
  console.log("\n6. Saving deployment addresses...");
  await saveDeploymentAddresses({
    FinancialDeploymentHelper: helper.address,
    OmniCoinEscrow: escrowAddress,
    OmniCoinPayment: paymentAddress,
    OmniCoinStaking: stakingAddress,
    OmniCoinBridge: bridgeAddress,
    OmniCoinArbitration: arbitrationAddress
  });
  
  console.log("\n✅ Financial contracts deployment completed successfully!");
  
  // Verify deployment
  console.log("\n7. Verifying deployment...");
  
  for (const update of updates) {
    const registered = await registry.getContract(ethers.id(update.name));
    console.log(`- Registry has ${update.name}:`, registered === update.address ? "✓" : "✗");
  }
  
  // Test basic functionality
  console.log("\n8. Testing basic functionality...");
  
  // Test escrow creation (will fail without approval, but tests deployment)
  try {
    const escrow = await ethers.getContractAt("OmniCoinEscrow", escrowAddress);
    const minDeposit = await escrow.minEscrowAmount();
    console.log("- Escrow minimum deposit:", ethers.formatUnits(minDeposit, 6), "XOM ✓");
  } catch (error) {
    console.log("- Escrow test failed:", error.message);
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("Deployment failed:", error);
    process.exit(1);
  });