/**
 * Deploy NFT DeFi Phase 5 contracts: Lending, Fractional, Staking
 *
 * Usage: npx hardhat run scripts/deploy-nft-defi.js --network <network>
 */

const { ethers } = require("hardhat");

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying NFT DeFi contracts with:", deployer.address);
  console.log("Balance:", ethers.formatEther(await ethers.provider.getBalance(deployer.address)));

  // ── OmniNFTLending ────────────────────────────────────────────────
  console.log("\n--- Deploying OmniNFTLending ---");
  const Lending = await ethers.getContractFactory("OmniNFTLending");
  // 10% of interest as platform fee (1000 bps)
  const lending = await Lending.deploy(deployer.address, 1000);
  await lending.waitForDeployment();
  const lendingAddr = await lending.getAddress();
  console.log("OmniNFTLending deployed to:", lendingAddr);

  // ── OmniFractionalNFT ─────────────────────────────────────────────
  console.log("\n--- Deploying OmniFractionalNFT ---");
  const Fractional = await ethers.getContractFactory("OmniFractionalNFT");
  // 1% creation fee (100 bps)
  const fractional = await Fractional.deploy(deployer.address, 100);
  await fractional.waitForDeployment();
  const fractionalAddr = await fractional.getAddress();
  console.log("OmniFractionalNFT deployed to:", fractionalAddr);

  // ── OmniNFTStaking ────────────────────────────────────────────────
  console.log("\n--- Deploying OmniNFTStaking ---");
  const Staking = await ethers.getContractFactory("OmniNFTStaking");
  const staking = await Staking.deploy();
  await staking.waitForDeployment();
  const stakingAddr = await staking.getAddress();
  console.log("OmniNFTStaking deployed to:", stakingAddr);

  // ── Summary ───────────────────────────────────────────────────────
  console.log("\n=== NFT DeFi Deployment Summary ===");
  console.log("OmniNFTLending:    ", lendingAddr);
  console.log("OmniFractionalNFT: ", fractionalAddr);
  console.log("OmniNFTStaking:    ", stakingAddr);
  console.log("\nUpdate omnicoin-integration.ts with these addresses.");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("Deployment failed:", error);
    process.exit(1);
  });
