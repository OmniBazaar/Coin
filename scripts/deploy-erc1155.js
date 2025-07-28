const { ethers } = require("hardhat");
const chalk = require('chalk');

// Configuration
const CONFIG = {
  baseURI: "https://omnibazaar.com/metadata/",
  registryIdentifiers: {
    OMNI_ERC1155: ethers.utils.keccak256(ethers.utils.toUtf8Bytes("OMNI_ERC1155")),
    UNIFIED_NFT_MARKETPLACE: ethers.utils.keccak256(ethers.utils.toUtf8Bytes("UNIFIED_NFT_MARKETPLACE")),
    ERC1155_BRIDGE: ethers.utils.keccak256(ethers.utils.toUtf8Bytes("ERC1155_BRIDGE")),
    SERVICE_TOKEN_EXAMPLES: ethers.utils.keccak256(ethers.utils.toUtf8Bytes("SERVICE_TOKEN_EXAMPLES"))
  }
};

async function main() {
  console.log(chalk.bold.cyan("OmniCoin ERC-1155 Deployment Script"));
  console.log(chalk.cyan("====================================\n"));

  // Get deployer account
  const [deployer] = await ethers.getSigners();
  console.log(chalk.yellow("Deploying contracts with account:"), deployer.address);
  
  const balance = await deployer.getBalance();
  console.log(chalk.yellow("Account balance:"), ethers.utils.formatEther(balance), "ETH\n");

  // Step 1: Get Registry address
  const registryAddress = process.env.REGISTRY_ADDRESS;
  if (!registryAddress) {
    console.error(chalk.red("ERROR: REGISTRY_ADDRESS environment variable not set"));
    console.log(chalk.yellow("Please set: export REGISTRY_ADDRESS=0x..."));
    process.exit(1);
  }

  console.log(chalk.green("Using Registry at:"), registryAddress);
  const registry = await ethers.getContractAt("OmniCoinRegistry", registryAddress);

  // Verify registry is accessible
  try {
    const omniCoinAddress = await registry.getContract(await registry.OMNICOIN());
    console.log(chalk.green("✓ Registry accessible, OmniCoin at:"), omniCoinAddress);
  } catch (error) {
    console.error(chalk.red("ERROR: Cannot access registry"), error.message);
    process.exit(1);
  }

  console.log(chalk.cyan("\n--- Deploying ERC-1155 Contracts ---\n"));

  // Deploy OmniERC1155
  console.log(chalk.blue("1. Deploying OmniERC1155..."));
  const OmniERC1155 = await ethers.getContractFactory("OmniERC1155");
  const omniERC1155 = await OmniERC1155.deploy(registryAddress, CONFIG.baseURI);
  await omniERC1155.deployed();
  console.log(chalk.green("✓ OmniERC1155 deployed to:"), omniERC1155.address);

  // Deploy OmniUnifiedMarketplace
  console.log(chalk.blue("\n2. Deploying OmniUnifiedMarketplace..."));
  const OmniUnifiedMarketplace = await ethers.getContractFactory("OmniUnifiedMarketplace");
  const marketplace = await OmniUnifiedMarketplace.deploy(registryAddress);
  await marketplace.deployed();
  console.log(chalk.green("✓ OmniUnifiedMarketplace deployed to:"), marketplace.address);

  // Deploy OmniERC1155Bridge
  console.log(chalk.blue("\n3. Deploying OmniERC1155Bridge..."));
  const OmniERC1155Bridge = await ethers.getContractFactory("OmniERC1155Bridge");
  const bridge = await OmniERC1155Bridge.deploy(registryAddress, omniERC1155.address);
  await bridge.deployed();
  console.log(chalk.green("✓ OmniERC1155Bridge deployed to:"), bridge.address);

  // Deploy ServiceTokenExamples (optional)
  console.log(chalk.blue("\n4. Deploying ServiceTokenExamples..."));
  const ServiceTokenExamples = await ethers.getContractFactory("ServiceTokenExamples");
  const examples = await ServiceTokenExamples.deploy(omniERC1155.address);
  await examples.deployed();
  console.log(chalk.green("✓ ServiceTokenExamples deployed to:"), examples.address);

  console.log(chalk.cyan("\n--- Configuring Contracts ---\n"));

  // Grant roles
  console.log(chalk.blue("5. Configuring roles..."));
  
  // Grant minting role to bridge
  const MINTER_ROLE = await omniERC1155.MINTER_ROLE();
  await omniERC1155.grantRole(MINTER_ROLE, bridge.address);
  console.log(chalk.green("✓ Granted MINTER_ROLE to bridge"));

  // Allow contracts in marketplace
  await marketplace.updateContractAllowlist(omniERC1155.address, true);
  console.log(chalk.green("✓ Added OmniERC1155 to marketplace allowlist"));

  // Also allow existing NFT contracts if they exist
  try {
    const nftMarketplaceId = await registry.NFT_MARKETPLACE();
    const nftAddress = await registry.getContract(nftMarketplaceId);
    if (nftAddress !== ethers.constants.AddressZero) {
      await marketplace.updateContractAllowlist(nftAddress, true);
      console.log(chalk.green("✓ Added existing NFT contract to allowlist"));
    }
  } catch (e) {
    console.log(chalk.yellow("⚠ No existing NFT contract found"));
  }

  console.log(chalk.cyan("\n--- Registering in Registry ---\n"));

  // Check if deployer has updater role
  const UPDATER_ROLE = await registry.UPDATER_ROLE();
  const hasUpdaterRole = await registry.hasRole(UPDATER_ROLE, deployer.address);
  
  if (!hasUpdaterRole) {
    console.log(chalk.yellow("⚠ Deployer does not have UPDATER_ROLE"));
    console.log(chalk.yellow("Please ask admin to register contracts:"));
    console.log(chalk.gray(`
    await registry.registerContract(
      "${CONFIG.registryIdentifiers.OMNI_ERC1155}",
      "${omniERC1155.address}",
      "OmniERC1155 Multi-Token"
    );
    
    await registry.registerContract(
      "${CONFIG.registryIdentifiers.UNIFIED_NFT_MARKETPLACE}",
      "${marketplace.address}",
      "Unified NFT Marketplace"
    );
    
    await registry.registerContract(
      "${CONFIG.registryIdentifiers.ERC1155_BRIDGE}",
      "${bridge.address}",
      "ERC1155 Import Bridge"
    );
    
    await registry.registerContract(
      "${CONFIG.registryIdentifiers.SERVICE_TOKEN_EXAMPLES}",
      "${examples.address}",
      "Service Token Examples"
    );
    `));
  } else {
    // Register contracts
    console.log(chalk.blue("6. Registering contracts..."));
    
    await registry.registerContract(
      CONFIG.registryIdentifiers.OMNI_ERC1155,
      omniERC1155.address,
      "OmniERC1155 Multi-Token"
    );
    console.log(chalk.green("✓ Registered OmniERC1155"));

    await registry.registerContract(
      CONFIG.registryIdentifiers.UNIFIED_NFT_MARKETPLACE,
      marketplace.address,
      "Unified NFT Marketplace"
    );
    console.log(chalk.green("✓ Registered OmniUnifiedMarketplace"));

    await registry.registerContract(
      CONFIG.registryIdentifiers.ERC1155_BRIDGE,
      bridge.address,
      "ERC1155 Import Bridge"
    );
    console.log(chalk.green("✓ Registered OmniERC1155Bridge"));

    await registry.registerContract(
      CONFIG.registryIdentifiers.SERVICE_TOKEN_EXAMPLES,
      examples.address,
      "Service Token Examples"
    );
    console.log(chalk.green("✓ Registered ServiceTokenExamples"));
  }

  console.log(chalk.cyan("\n--- Deployment Summary ---\n"));
  console.log(chalk.bold("Contract Addresses:"));
  console.log(chalk.white("OmniERC1155:"), omniERC1155.address);
  console.log(chalk.white("OmniUnifiedMarketplace:"), marketplace.address);
  console.log(chalk.white("OmniERC1155Bridge:"), bridge.address);
  console.log(chalk.white("ServiceTokenExamples:"), examples.address);

  // Save deployment info
  const deploymentInfo = {
    network: network.name,
    timestamp: new Date().toISOString(),
    deployer: deployer.address,
    contracts: {
      OmniERC1155: omniERC1155.address,
      OmniUnifiedMarketplace: marketplace.address,
      OmniERC1155Bridge: bridge.address,
      ServiceTokenExamples: examples.address
    },
    registry: registryAddress,
    config: CONFIG
  };

  const fs = require('fs');
  const filename = `deployment-erc1155-${network.name}-${Date.now()}.json`;
  fs.writeFileSync(filename, JSON.stringify(deploymentInfo, null, 2));
  console.log(chalk.gray(`\nDeployment info saved to ${filename}`));

  console.log(chalk.green.bold("\n✅ ERC-1155 deployment complete!"));
}

// Error handling
main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(chalk.red("\nDeployment failed:"), error);
    process.exit(1);
  });