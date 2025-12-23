/**
 * Initialize Transaction Limits for All Tiers
 *
 * Manually sets tier limits via updateTierLimits() since reinitialize(2) fails.
 * This is a one-time operation after v2 upgrade.
 */

import { ethers } from "hardhat";

async function main() {
  console.log("\n📊 Initializing tier limits...\n");

  const PROXY_ADDRESS = "0x0E4E697317117B150481a827f1e5029864aAe781";
  const registration = await ethers.getContractAt("OmniRegistration", PROXY_ADDRESS);
  const USD = ethers.parseEther("1");

  // Tier 0: Anonymous
  console.log("Setting Tier 0 limits...");
  const tx0 = await registration.updateTierLimits(0, {
    dailyLimit: 500n * USD,
    monthlyLimit: 5000n * USD,
    annualLimit: 25000n * USD,
    perTransactionLimit: 100n * USD,
    maxListings: 3,
    maxListingPrice: 100n * USD
  });
  await tx0.wait();
  console.log("✅ Tier 0");

  // Tier 1: Basic
  console.log("Setting Tier 1 limits...");
  const tx1 = await registration.updateTierLimits(1, {
    dailyLimit: 5000n * USD,
    monthlyLimit: 50000n * USD,
    annualLimit: 250000n * USD,
    perTransactionLimit: 2000n * USD,
    maxListings: 25,
    maxListingPrice: 2000n * USD
  });
  await tx1.wait();
  console.log("✅ Tier 1");

  // Tier 2: Verified Identity (Public RWA)
  console.log("Setting Tier 2 limits...");
  const tx2 = await registration.updateTierLimits(2, {
    dailyLimit: 25000n * USD,
    monthlyLimit: 250000n * USD,
    annualLimit: 0n,
    perTransactionLimit: 25000n * USD,
    maxListings: 250,
    maxListingPrice: 25000n * USD
  });
  await tx2.wait();
  console.log("✅ Tier 2");

  // Tier 3: Accredited Investor (Private RWA)
  console.log("Setting Tier 3 limits...");
  const tx3 = await registration.updateTierLimits(3, {
    dailyLimit: 100000n * USD,
    monthlyLimit: 1000000n * USD,
    annualLimit: 0n,
    perTransactionLimit: 100000n * USD,
    maxListings: 0,
    maxListingPrice: 0n
  });
  await tx3.wait();
  console.log("✅ Tier 3");

  // Tier 4: Institutional/Validator
  console.log("Setting Tier 4 limits...");
  const tx4 = await registration.updateTierLimits(4, {
    dailyLimit: 0n,
    monthlyLimit: 0n,
    annualLimit: 0n,
    perTransactionLimit: 0n,
    maxListings: 0,
    maxListingPrice: 0n
  });
  await tx4.wait();
  console.log("✅ Tier 4");

  // Verify
  console.log("\n📊 Verifying all tiers:");
  for (let tier = 0; tier <= 4; tier++) {
    const limits = await registration.tierLimits(tier);
    console.log(`\nTier ${tier}:`);
    console.log(`  Daily: $${ethers.formatEther(limits.dailyLimit)}`);
    console.log(`  Monthly: $${ethers.formatEther(limits.monthlyLimit)}`);
    console.log(`  Per-tx: $${ethers.formatEther(limits.perTransactionLimit)}`);
    console.log(`  Max listings: ${limits.maxListings}`);
  }

  console.log("\n✅ All tier limits initialized successfully!\n");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exitCode = 1;
  });
