/**
 * Deploy RWA (Real World Asset) Contracts
 *
 * Deploys the RWA AMM system for compliant RWA token trading.
 * Deployment order:
 *   1. RWAComplianceOracle - Compliance verification system
 *   2. RWAAMM - Core AMM contract (immutable)
 *   3. RWARouter - User-facing router
 *
 * @notice RWAAMM is intentionally NON-UPGRADEABLE for legal defensibility
 */

import { ethers } from "hardhat";
import * as fs from "fs";
import * as path from "path";

interface RWADeploymentConfig {
  /** 5 emergency multi-sig signers for RWAAMM pause functionality */
  emergencySigners: [string, string, string, string, string];
  /** Staking pool address for fee distribution (20%) */
  stakingPool: string;
  /** Liquidity pool address for fee distribution (10%) */
  liquidityPool: string;
  /** Wrapped native token (WAVAX on Avalanche) */
  wrappedNative: string;
}

/**
 * Get deployment configuration for the network
 * @param deployer Deployer address (used as fallback for test deployments)
 * @returns Configuration object
 */
function getConfig(deployer: string): RWADeploymentConfig {
  // For testnet, use deployer address as placeholders
  // In production, these would be actual multi-sig and pool addresses
  return {
    emergencySigners: [
      deployer, // Emergency signer 1
      deployer, // Emergency signer 2 (use different addresses in production)
      deployer, // Emergency signer 3
      deployer, // Emergency signer 4
      deployer, // Emergency signer 5
    ],
    stakingPool: deployer, // Staking pool (placeholder for testnet)
    liquidityPool: deployer, // Liquidity pool (placeholder for testnet)
    wrappedNative: "0xd00ae08403B9bbb9124bB305C09058E32C39A48c", // WAVAX on Fuji
  };
}

async function main(): Promise<void> {
  console.log("\n=== Deploying RWA Contracts ===\n");

  const [deployer] = await ethers.getSigners();
  console.log(`Deployer: ${deployer.address}`);
  console.log(
    `Balance: ${ethers.formatEther(await ethers.provider.getBalance(deployer.address))} AVAX\n`
  );

  // Load deployment config
  const deploymentPath = path.join(__dirname, "../deployments/fuji.json");
  const deployment = JSON.parse(fs.readFileSync(deploymentPath, "utf8"));

  const xomTokenAddress = deployment.contracts.OmniCoin;

  if (
    !xomTokenAddress ||
    xomTokenAddress === "0x0000000000000000000000000000000000000000"
  ) {
    throw new Error("OmniCoin not deployed. Deploy it first.");
  }

  console.log(`XOM Token: ${xomTokenAddress}`);

  const config = getConfig(deployer.address);

  // ==========================================================================
  // 1. Deploy RWAComplianceOracle
  // ==========================================================================

  console.log("\n1. Deploying RWAComplianceOracle...");

  const RWAComplianceOracle = await ethers.getContractFactory(
    "RWAComplianceOracle"
  );
  const complianceOracle = await RWAComplianceOracle.deploy(deployer.address);
  await complianceOracle.waitForDeployment();
  const complianceOracleAddress = await complianceOracle.getAddress();

  console.log(`   RWAComplianceOracle deployed: ${complianceOracleAddress}`);

  // ==========================================================================
  // 2. Deploy RWAAMM (with deployer as temporary fee collector)
  // ==========================================================================

  console.log("\n2. Deploying RWAAMM...");

  // Note: We use deployer as FEE_VAULT temporarily
  // In production, deploy with UnifiedFeeVault address
  const RWAAMM = await ethers.getContractFactory("RWAAMM");
  const rwaamm = await RWAAMM.deploy(
    config.emergencySigners,
    deployer.address, // Temporary fee vault (will receive fees for now)
    xomTokenAddress,
    complianceOracleAddress
  );
  await rwaamm.waitForDeployment();
  const rwaammAddress = await rwaamm.getAddress();

  console.log(`   RWAAMM deployed: ${rwaammAddress}`);

  // Verify RWAAMM configuration
  const protocolFeeBps = await rwaamm.PROTOCOL_FEE_BPS();
  console.log(`   Protocol Fee: ${protocolFeeBps} bps (${Number(protocolFeeBps) / 100}%)`);

  // ==========================================================================
  // 3. Deploy RWARouter
  // ==========================================================================

  console.log("\n3. Deploying RWARouter...");

  const RWARouter = await ethers.getContractFactory("RWARouter");
  const router = await RWARouter.deploy(rwaammAddress, config.wrappedNative);
  await router.waitForDeployment();
  const routerAddress = await router.getAddress();

  console.log(`   RWARouter deployed: ${routerAddress}`);

  // ==========================================================================
  // Update deployment file
  // ==========================================================================

  console.log("\n4. Updating deployment file...");

  // Add RWA contracts to deployment
  if (!deployment.contracts.rwa) {
    deployment.contracts.rwa = {};
  }

  deployment.contracts.rwa = {
    RWAComplianceOracle: complianceOracleAddress,
    RWAAMM: rwaammAddress,
    RWARouter: routerAddress,
    deployedAt: new Date().toISOString(),
    note: "RWAAMM uses deployer as fee vault temporarily. Redeploy for production with UnifiedFeeVault address.",
  };

  fs.writeFileSync(deploymentPath, JSON.stringify(deployment, null, 2));
  console.log("   Updated deployments/fuji.json");

  // ==========================================================================
  // Summary
  // ==========================================================================

  console.log("\n=== RWA Deployment Summary ===\n");
  console.log("Contracts deployed:");
  console.log(`  RWAComplianceOracle: ${complianceOracleAddress}`);
  console.log(`  RWAAMM:              ${rwaammAddress}`);
  console.log(`  RWARouter:           ${routerAddress}`);
  console.log("\nConfiguration:");
  console.log(`  XOM Token:           ${xomTokenAddress}`);
  console.log(`  Protocol Fee:        ${Number(protocolFeeBps) / 100}%`);
  console.log(`  Emergency Signers:   ${config.emergencySigners[0]} (and 4 more)`);
  console.log("\n⚠️  NOTE: RWAAMM uses deployer as fee vault.");
  console.log("   For production, redeploy with UnifiedFeeVault address.");
  console.log("\nRemember to sync contract addresses:");
  console.log("  ./scripts/sync-contract-addresses.sh fuji");

  console.log("\n=== RWA Deployment Complete ===\n");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("\nDeployment failed:", error);
    process.exitCode = 1;
  });
