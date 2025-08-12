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
  console.log("Starting Marketplace & DEX Deployment...");
  const [deployer] = await ethers.getSigners();
  console.log("Deploying with account:", deployer.address);
  
  // Load existing addresses
  const addresses = await loadDeploymentAddresses();
  console.log("\nLoaded addresses:");
  console.log("- Registry:", addresses.Registry);
  console.log("- OmniCoinCore:", addresses.OmniCoinCore);
  console.log("- Escrow:", addresses.OmniCoinEscrow);
  
  // Get registry contract
  const registry = await ethers.getContractAt("OmniCoinRegistry", addresses.Registry);
  
  // Deploy MarketplaceDeploymentHelper
  console.log("\n1. Deploying MarketplaceDeploymentHelper...");
  const MarketplaceHelper = await ethers.getContractFactory("MarketplaceDeploymentHelper");
  const helper = await MarketplaceHelper.deploy(addresses.Registry);
  await helper.deployed();
  console.log("MarketplaceDeploymentHelper deployed to:", helper.address);
  
  // Deploy all marketplace contracts
  console.log("\n2. Deploying marketplace contracts...");
  const tx = await helper.deployAll();
  const receipt = await tx.wait();
  console.log("Transaction hash:", receipt.transactionHash);
  
  // Get deployed addresses
  console.log("\n3. Getting deployed contract addresses...");
  const marketplaceAddress = await helper.marketplace();
  const dexSettlementAddress = await helper.dexSettlement();
  const listingNFTAddress = await helper.listingNFT();
  const reputationAddress = await helper.reputation();
  
  console.log("- Marketplace:", marketplaceAddress);
  console.log("- DEXSettlement:", dexSettlementAddress);
  console.log("- ListingNFT:", listingNFTAddress);
  console.log("- ReputationSystem:", reputationAddress);
  
  // Update registry
  console.log("\n4. Updating registry...");
  
  const updates = [
    { name: "MARKETPLACE", address: marketplaceAddress },
    { name: "DEX_SETTLEMENT", address: dexSettlementAddress },
    { name: "LISTING_NFT", address: listingNFTAddress },
    { name: "REPUTATION", address: reputationAddress },
    { name: "NFT_MARKETPLACE", address: marketplaceAddress } // Alias
  ];
  
  for (const update of updates) {
    const tx = await registry.setContract(
      ethers.utils.id(update.name),
      update.address
    );
    await tx.wait();
    console.log(`- Set ${update.name} in registry`);
  }
  
  // Configure contracts
  console.log("\n5. Configuring contracts...");
  
  // Configure ListingNFT
  const listingNFT = await ethers.getContractAt("ListingNFT", listingNFTAddress);
  let configTx = await listingNFT.setApprovedMinter(marketplaceAddress, true);
  await configTx.wait();
  console.log("- Set marketplace as approved minter for ListingNFT");
  
  // Configure Marketplace
  const marketplace = await ethers.getContractAt("OmniNFTMarketplace", marketplaceAddress);
  
  // Set fee recipient (could be a treasury address)
  configTx = await marketplace.setFeeRecipient(deployer.address);
  await configTx.wait();
  console.log("- Set marketplace fee recipient");
  
  // Set marketplace fee (250 basis points = 2.5%)
  configTx = await marketplace.setMarketplaceFee(250);
  await configTx.wait();
  console.log("- Set marketplace fee to 2.5%");
  
  // Configure DEXSettlement
  const dexSettlement = await ethers.getContractAt("DEXSettlement", dexSettlementAddress);
  
  // Add supported trading pairs (example: XOM/USDC)
  // Note: In production, you'd add actual token addresses
  console.log("- DEX Settlement configured (add trading pairs after token deployment)");
  
  // Configure ReputationSystem
  const reputation = await ethers.getContractAt("ReputationSystem", reputationAddress);
  
  // Grant updater role to marketplace
  const REPUTATION_UPDATER_ROLE = await reputation.REPUTATION_UPDATER_ROLE();
  configTx = await reputation.grantRole(REPUTATION_UPDATER_ROLE, marketplaceAddress);
  await configTx.wait();
  console.log("- Granted reputation updater role to marketplace");
  
  // Save addresses
  console.log("\n6. Saving deployment addresses...");
  await saveDeploymentAddresses({
    MarketplaceDeploymentHelper: helper.address,
    OmniNFTMarketplace: marketplaceAddress,
    DEXSettlement: dexSettlementAddress,
    ListingNFT: listingNFTAddress,
    ReputationSystem: reputationAddress
  });
  
  console.log("\n✅ Marketplace & DEX deployment completed successfully!");
  
  // Verify deployment
  console.log("\n7. Verifying deployment...");
  
  for (const update of updates) {
    const registered = await registry.getContract(ethers.utils.id(update.name));
    const isCorrect = registered === update.address;
    console.log(`- Registry has ${update.name}:`, isCorrect ? "✓" : "✗");
    if (!isCorrect) {
      console.log(`  Expected: ${update.address}`);
      console.log(`  Found: ${registered}`);
    }
  }
  
  // Test basic functionality
  console.log("\n8. Testing basic functionality...");
  
  try {
    // Check marketplace configuration
    const marketplaceFee = await marketplace.marketplaceFee();
    console.log("- Marketplace fee:", marketplaceFee.toNumber() / 100, "% ✓");
    
    // Check NFT minter approval
    const isMinterApproved = await listingNFT.approvedMinters(marketplaceAddress);
    console.log("- Marketplace is approved NFT minter:", isMinterApproved ? "✓" : "✗");
    
    // Check reputation system
    const hasRole = await reputation.hasRole(REPUTATION_UPDATER_ROLE, marketplaceAddress);
    console.log("- Marketplace has reputation updater role:", hasRole ? "✓" : "✗");
    
  } catch (error) {
    console.log("- Functionality test failed:", error.message);
  }
  
  console.log("\n📝 Next steps:");
  console.log("1. Deploy any additional tokens for DEX trading pairs");
  console.log("2. Configure DEX settlement with trading pairs");
  console.log("3. Set up IPFS for marketplace metadata storage");
  console.log("4. Deploy validator infrastructure contracts");
  console.log("5. Initialize liquidity pools for DEX");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("Deployment failed:", error);
    process.exit(1);
  });