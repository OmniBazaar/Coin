/**
 * Deploy OmniNFT Factory contracts to Fuji testnet
 *
 * Usage:
 *   npx hardhat run scripts/deploy-nft-factory.js --network fuji
 *   npx hardhat run scripts/deploy-nft-factory.js --network localhost
 */
const { ethers } = require("hardhat");
const fs = require("fs");
const path = require("path");

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying NFT Factory contracts with account:", deployer.address);
  console.log("Balance:", ethers.formatEther(await ethers.provider.getBalance(deployer.address)));

  // 1. Deploy OmniNFTCollection (implementation)
  console.log("\n1. Deploying OmniNFTCollection implementation...");
  const Collection = await ethers.getContractFactory("OmniNFTCollection");
  const collection = await Collection.deploy();
  await collection.waitForDeployment();
  const collectionAddr = await collection.getAddress();
  console.log("   OmniNFTCollection (impl):", collectionAddr);

  // 2. Deploy OmniNFTFactory
  console.log("\n2. Deploying OmniNFTFactory...");
  const Factory = await ethers.getContractFactory("OmniNFTFactory");
  const factory = await Factory.deploy(collectionAddr);
  await factory.waitForDeployment();
  const factoryAddr = await factory.getAddress();
  console.log("   OmniNFTFactory:", factoryAddr);
  console.log("   Platform fee:", (await factory.platformFeeBps()).toString(), "bps (2.5%)");

  // 3. Deploy OmniNFTRoyalty
  console.log("\n3. Deploying OmniNFTRoyalty...");
  const Royalty = await ethers.getContractFactory("OmniNFTRoyalty");
  const royalty = await Royalty.deploy();
  await royalty.waitForDeployment();
  const royaltyAddr = await royalty.getAddress();
  console.log("   OmniNFTRoyalty:", royaltyAddr);

  // 4. Save deployment info
  const network = await ethers.provider.getNetwork();
  const deployment = {
    network: network.name,
    chainId: Number(network.chainId),
    deployer: deployer.address,
    timestamp: new Date().toISOString(),
    contracts: {
      OmniNFTCollection: collectionAddr,
      OmniNFTFactory: factoryAddr,
      OmniNFTRoyalty: royaltyAddr,
    },
  };

  const deploymentsDir = path.join(__dirname, "..", "deployments");
  if (!fs.existsSync(deploymentsDir)) {
    fs.mkdirSync(deploymentsDir, { recursive: true });
  }

  const filename = path.join(deploymentsDir, `nft-factory-${network.name || "local"}.json`);
  fs.writeFileSync(filename, JSON.stringify(deployment, null, 2));
  console.log("\nDeployment saved to:", filename);

  console.log("\n--- Summary ---");
  console.log("OmniNFTCollection (impl):", collectionAddr);
  console.log("OmniNFTFactory:          ", factoryAddr);
  console.log("OmniNFTRoyalty:          ", royaltyAddr);
  console.log("\nUpdate omnicoin-integration.ts with these addresses.");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
