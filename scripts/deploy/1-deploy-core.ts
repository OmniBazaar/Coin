import { ethers } from "hardhat";
import * as fs from "fs";
import * as path from "path";

interface DeploymentAddresses {
  OmniCoinCore: string;
  Registry: string;
  PrivacyFeeManager: string;
}

async function saveDeploymentAddresses(addresses: DeploymentAddresses) {
  const deploymentPath = path.join(__dirname, "../../deployments");
  if (!fs.existsSync(deploymentPath)) {
    fs.mkdirSync(deploymentPath, { recursive: true });
  }
  
  const network = process.env.HARDHAT_NETWORK || "localhost";
  const filePath = path.join(deploymentPath, `${network}.json`);
  
  let existing = {};
  if (fs.existsSync(filePath)) {
    existing = JSON.parse(fs.readFileSync(filePath, "utf8"));
  }
  
  const updated = { ...existing, ...addresses, timestamp: new Date().toISOString() };
  fs.writeFileSync(filePath, JSON.stringify(updated, null, 2));
  
  console.log(`Deployment addresses saved to ${filePath}`);
}

async function main() {
  console.log("Starting Core Infrastructure Deployment...");
  const [deployer] = await ethers.getSigners();
  console.log("Deploying with account:", deployer.address);
  
  const balance = await deployer.getBalance();
  console.log("Account balance:", ethers.utils.formatEther(balance));
  
  // 1. Deploy OmniCoinCore
  console.log("\n1. Deploying OmniCoinCore...");
  const OmniCoinCore = await ethers.getContractFactory("OmniCoinCore");
  const omniCoin = await OmniCoinCore.deploy(
    "OmniCoin",
    "XOM",
    1000000000, // 1B tokens
    6 // decimals
  );
  await omniCoin.deployed();
  console.log("OmniCoinCore deployed to:", omniCoin.address);
  
  // 2. Deploy Registry
  console.log("\n2. Deploying OmniCoinRegistry...");
  const Registry = await ethers.getContractFactory("OmniCoinRegistry");
  const registry = await Registry.deploy(deployer.address);
  await registry.deployed();
  console.log("Registry deployed to:", registry.address);
  
  // 3. Deploy PrivacyFeeManager
  console.log("\n3. Deploying PrivacyFeeManager...");
  const PrivacyFeeManager = await ethers.getContractFactory("PrivacyFeeManager");
  const privacyFeeManager = await PrivacyFeeManager.deploy(
    omniCoin.address,
    deployer.address
  );
  await privacyFeeManager.deployed();
  console.log("PrivacyFeeManager deployed to:", privacyFeeManager.address);
  
  // 4. Configure Registry
  console.log("\n4. Configuring Registry...");
  
  // Set core contracts in registry
  let tx = await registry.setContract(
    ethers.utils.id("OMNICOIN_CORE"),
    omniCoin.address
  );
  await tx.wait();
  console.log("- Set OMNICOIN_CORE in registry");
  
  tx = await registry.setContract(
    ethers.utils.id("PRIVACY_FEE_MANAGER"),
    privacyFeeManager.address
  );
  await tx.wait();
  console.log("- Set PRIVACY_FEE_MANAGER in registry");
  
  // 5. Configure OmniCoinCore
  console.log("\n5. Configuring OmniCoinCore...");
  tx = await omniCoin.setRegistry(registry.address);
  await tx.wait();
  console.log("- Set registry in OmniCoinCore");
  
  // 6. Save deployment addresses
  console.log("\n6. Saving deployment addresses...");
  await saveDeploymentAddresses({
    OmniCoinCore: omniCoin.address,
    Registry: registry.address,
    PrivacyFeeManager: privacyFeeManager.address
  });
  
  console.log("\n✅ Core deployment completed successfully!");
  console.log("\nDeployed addresses:");
  console.log("- OmniCoinCore:", omniCoin.address);
  console.log("- Registry:", registry.address);
  console.log("- PrivacyFeeManager:", privacyFeeManager.address);
  
  // Verify deployment
  console.log("\n7. Verifying deployment...");
  const registeredCore = await registry.getContract(ethers.utils.id("OMNICOIN_CORE"));
  console.log("- Registry has OmniCoinCore:", registeredCore === omniCoin.address ? "✓" : "✗");
  
  const registeredPFM = await registry.getContract(ethers.utils.id("PRIVACY_FEE_MANAGER"));
  console.log("- Registry has PrivacyFeeManager:", registeredPFM === privacyFeeManager.address ? "✓" : "✗");
  
  const totalSupply = await omniCoin.totalSupply();
  console.log("- OmniCoin total supply:", ethers.utils.formatUnits(totalSupply, 6), "XOM");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("Deployment failed:", error);
    process.exit(1);
  });