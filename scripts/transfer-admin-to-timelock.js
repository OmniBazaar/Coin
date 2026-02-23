/**
 * Transfer admin roles from deployer to TimelockController
 *
 * For each contract: GRANT roles to timelock, VERIFY, then REVOKE from deployer.
 * Supports --dry-run mode to simulate without executing.
 *
 * Usage:
 *   npx hardhat run scripts/transfer-admin-to-timelock.js --network localhost
 *   DRY_RUN=true npx hardhat run scripts/transfer-admin-to-timelock.js --network localhost
 *
 * Environment variables:
 *   TIMELOCK_ADDRESS  - Address of the deployed TimelockController
 *   DRY_RUN           - Set to "true" to simulate without executing
 *
 * IMPORTANT: This script is meant for MAINNET deployment. Running it on testnet
 * will lock out the deployer from admin actions (72-hour delay for everything).
 */
const { ethers } = require("hardhat");

// Contract ABIs (only the role management functions we need)
const ACCESS_CONTROL_ABI = [
  "function grantRole(bytes32 role, address account) external",
  "function revokeRole(bytes32 role, address account) external",
  "function hasRole(bytes32 role, address account) external view returns (bool)",
  "function DEFAULT_ADMIN_ROLE() external view returns (bytes32)",
  "function ADMIN_ROLE() external view returns (bytes32)",
  "function getRoleAdmin(bytes32 role) external view returns (bytes32)",
];

const OWNABLE_ABI = [
  "function owner() external view returns (address)",
  "function transferOwnership(address newOwner) external",
];

async function main() {
  const [deployer] = await ethers.getSigners();
  const dryRun = process.env.DRY_RUN === "true";
  const timelockAddress = process.env.TIMELOCK_ADDRESS;

  if (!timelockAddress) {
    console.error("ERROR: TIMELOCK_ADDRESS environment variable required");
    console.error("  Set it to the deployed TimelockController address");
    process.exit(1);
  }

  console.log("=".repeat(60));
  console.log(dryRun ? "  DRY RUN — No transactions will be sent" : "  LIVE RUN — Transactions will be sent");
  console.log("=".repeat(60));
  console.log("Deployer:  ", deployer.address);
  console.log("Timelock:  ", timelockAddress);
  console.log();

  // Load deployed addresses from fuji.json
  const fs = require("fs");
  const path = require("path");
  const deploymentPath = path.join(__dirname, "..", "deployments", "fuji.json");

  let deployment;
  try {
    deployment = JSON.parse(fs.readFileSync(deploymentPath, "utf8"));
  } catch {
    console.error("ERROR: Cannot read deployments/fuji.json");
    process.exit(1);
  }

  const contracts = deployment.contracts;

  // ─────────────────────────────────────────────────────────
  // AccessControl contracts (grantRole / revokeRole pattern)
  // ─────────────────────────────────────────────────────────

  const accessControlContracts = [
    { name: "OmniCoin", address: contracts.OmniCoin },
    { name: "OmniCore (proxy)", address: contracts.OmniCore },
    { name: "OmniRegistration (proxy)", address: contracts.OmniRegistration },
    { name: "OmniRewardManager (proxy)", address: contracts.OmniRewardManager },
    { name: "OmniValidatorRewards (proxy)", address: contracts.OmniValidatorRewards },
    { name: "StakingRewardPool (proxy)", address: contracts.StakingRewardPool },
    { name: "OmniParticipation (proxy)", address: contracts.OmniParticipation },
    { name: "OmniSybilGuard (proxy)", address: contracts.OmniSybilGuard },
  ];

  // Filter out contracts with missing addresses
  const validACContracts = accessControlContracts.filter(c => {
    if (!c.address || c.address === ethers.ZeroAddress) {
      console.log(`SKIP: ${c.name} — no deployed address`);
      return false;
    }
    return true;
  });

  console.log(`\nProcessing ${validACContracts.length} AccessControl contracts...\n`);

  let successCount = 0;
  let skipCount = 0;
  let errorCount = 0;
  const txHashes = [];

  for (const contractInfo of validACContracts) {
    console.log(`── ${contractInfo.name} (${contractInfo.address}) ──`);

    try {
      const contract = new ethers.Contract(
        contractInfo.address,
        ACCESS_CONTROL_ABI,
        deployer
      );

      const DEFAULT_ADMIN_ROLE = await contract.DEFAULT_ADMIN_ROLE();

      // Check if deployer currently has admin role
      const deployerHasAdmin = await contract.hasRole(DEFAULT_ADMIN_ROLE, deployer.address);
      if (!deployerHasAdmin) {
        console.log("  SKIP: Deployer does not have DEFAULT_ADMIN_ROLE");
        skipCount++;
        continue;
      }

      // Check if timelock already has admin role
      const timelockHasAdmin = await contract.hasRole(DEFAULT_ADMIN_ROLE, timelockAddress);

      if (dryRun) {
        console.log("  [DRY RUN] Would grant DEFAULT_ADMIN_ROLE to timelock");
        if (!timelockHasAdmin) {
          console.log("  [DRY RUN] Timelock does not yet have admin — grant needed");
        }
        console.log("  [DRY RUN] Would revoke DEFAULT_ADMIN_ROLE from deployer");

        // Check ADMIN_ROLE in dry-run too
        try {
          const ADMIN_ROLE_DRY = await contract.ADMIN_ROLE();
          const deployerHasAdminDry = await contract.hasRole(ADMIN_ROLE_DRY, deployer.address);
          if (deployerHasAdminDry) {
            console.log("  [DRY RUN] Would grant ADMIN_ROLE to timelock");
            console.log("  [DRY RUN] Would revoke ADMIN_ROLE from deployer");
          } else {
            console.log("  [DRY RUN] Deployer does not have ADMIN_ROLE (N/A)");
          }
        } catch {
          console.log("  [DRY RUN] Contract does not expose ADMIN_ROLE (skipping)");
        }

        successCount++;
        continue;
      }

      // Step 1: Grant admin to timelock (if not already granted)
      if (!timelockHasAdmin) {
        const grantTx = await contract.grantRole(DEFAULT_ADMIN_ROLE, timelockAddress);
        const grantReceipt = await grantTx.wait();
        console.log("  GRANTED admin to timelock  tx:", grantReceipt.hash);
        txHashes.push({ action: "grant", contract: contractInfo.name, hash: grantReceipt.hash });
      } else {
        console.log("  Timelock already has admin — skipping grant");
      }

      // Step 2: Verify timelock has admin
      const verified = await contract.hasRole(DEFAULT_ADMIN_ROLE, timelockAddress);
      if (!verified) {
        console.error("  ERROR: Verification failed — timelock does not have admin after grant");
        errorCount++;
        continue;
      }
      console.log("  VERIFIED: Timelock has DEFAULT_ADMIN_ROLE");

      // Step 3: Revoke admin from deployer
      const revokeTx = await contract.revokeRole(DEFAULT_ADMIN_ROLE, deployer.address);
      const revokeReceipt = await revokeTx.wait();
      console.log("  REVOKED admin from deployer tx:", revokeReceipt.hash);
      txHashes.push({ action: "revoke", contract: contractInfo.name, hash: revokeReceipt.hash });

      // Step 4: Final verification
      const deployerStillHas = await contract.hasRole(DEFAULT_ADMIN_ROLE, deployer.address);
      if (deployerStillHas) {
        console.error("  WARNING: Deployer still has admin after revoke!");
        errorCount++;
      } else {
        console.log("  CONFIRMED: Deployer no longer has DEFAULT_ADMIN_ROLE");
        successCount++;
      }

      // ── ADMIN_ROLE transfer (H-06 audit fix) ──
      // Some contracts (StakingRewardPool, OmniCore, etc.) have an ADMIN_ROLE
      // that controls APR changes, contract references, and upgrades.
      // Without transferring this role, the deployer retains full control
      // even after DEFAULT_ADMIN_ROLE is moved to the timelock.
      try {
        const ADMIN_ROLE = await contract.ADMIN_ROLE();
        const deployerHasAdminRole = await contract.hasRole(ADMIN_ROLE, deployer.address);

        if (deployerHasAdminRole) {
          const timelockHasAdminRole = await contract.hasRole(ADMIN_ROLE, timelockAddress);

          if (dryRun) {
            console.log("  [DRY RUN] Would grant ADMIN_ROLE to timelock");
            console.log("  [DRY RUN] Would revoke ADMIN_ROLE from deployer");
          } else {
            // Grant ADMIN_ROLE to timelock
            if (!timelockHasAdminRole) {
              const grantAdminTx = await contract.grantRole(ADMIN_ROLE, timelockAddress);
              const grantAdminReceipt = await grantAdminTx.wait();
              console.log("  GRANTED ADMIN_ROLE to timelock  tx:", grantAdminReceipt.hash);
              txHashes.push({
                action: "grant ADMIN_ROLE",
                contract: contractInfo.name,
                hash: grantAdminReceipt.hash,
              });
            } else {
              console.log("  Timelock already has ADMIN_ROLE — skipping grant");
            }

            // Verify timelock has ADMIN_ROLE
            const adminVerified = await contract.hasRole(ADMIN_ROLE, timelockAddress);
            if (!adminVerified) {
              console.error("  ERROR: Timelock does not have ADMIN_ROLE after grant");
              errorCount++;
            } else {
              console.log("  VERIFIED: Timelock has ADMIN_ROLE");

              // Revoke ADMIN_ROLE from deployer
              const revokeAdminTx = await contract.revokeRole(ADMIN_ROLE, deployer.address);
              const revokeAdminReceipt = await revokeAdminTx.wait();
              console.log("  REVOKED ADMIN_ROLE from deployer tx:", revokeAdminReceipt.hash);
              txHashes.push({
                action: "revoke ADMIN_ROLE",
                contract: contractInfo.name,
                hash: revokeAdminReceipt.hash,
              });

              // Final verification
              const deployerStillHasAdmin = await contract.hasRole(ADMIN_ROLE, deployer.address);
              if (deployerStillHasAdmin) {
                console.error("  WARNING: Deployer still has ADMIN_ROLE after revoke!");
                errorCount++;
              } else {
                console.log("  CONFIRMED: Deployer no longer has ADMIN_ROLE");
              }
            }
          }
        } else {
          console.log("  INFO: Deployer does not have ADMIN_ROLE (already transferred or N/A)");
        }
      } catch {
        // Contract does not have ADMIN_ROLE() function — this is expected
        // for contracts that only use DEFAULT_ADMIN_ROLE
        console.log("  INFO: Contract does not expose ADMIN_ROLE (skipping)");
      }
    } catch (error) {
      console.error(`  ERROR: ${error.message}`);
      errorCount++;
    }
    console.log();
  }

  // ─────────────────────────────────────────────────────────
  // Ownable contract (transferOwnership pattern)
  // ─────────────────────────────────────────────────────────

  if (contracts.DEXSettlement && contracts.DEXSettlement !== ethers.ZeroAddress) {
    console.log(`── DEXSettlement (${contracts.DEXSettlement}) ──`);

    try {
      const dexContract = new ethers.Contract(
        contracts.DEXSettlement,
        OWNABLE_ABI,
        deployer
      );

      const currentOwner = await dexContract.owner();
      console.log("  Current owner:", currentOwner);

      if (currentOwner.toLowerCase() !== deployer.address.toLowerCase()) {
        console.log("  SKIP: Deployer is not the current owner");
        skipCount++;
      } else if (dryRun) {
        console.log("  [DRY RUN] Would transferOwnership to timelock");
        successCount++;
      } else {
        const tx = await dexContract.transferOwnership(timelockAddress);
        const receipt = await tx.wait();
        console.log("  TRANSFERRED ownership to timelock  tx:", receipt.hash);
        txHashes.push({ action: "transferOwnership", contract: "DEXSettlement", hash: receipt.hash });

        const newOwner = await dexContract.owner();
        if (newOwner.toLowerCase() === timelockAddress.toLowerCase()) {
          console.log("  CONFIRMED: Timelock is now the owner");
          successCount++;
        } else {
          console.error("  WARNING: Ownership transfer verification failed");
          errorCount++;
        }
      }
    } catch (error) {
      console.error(`  ERROR: ${error.message}`);
      errorCount++;
    }
    console.log();
  }

  // ─────────────────────────────────────────────────────────
  // Skipped contracts (documented reasons)
  // ─────────────────────────────────────────────────────────

  console.log("── Skipped Contracts ──");
  console.log("  MinimalEscrow:  Immutable ADMIN — arbitrator list only (low risk)");
  console.log("  Bootstrap.sol:  Deployed on C-Chain — separate chain, Phase 2");
  if (contracts.MintController) {
    console.log("  MintController:  Will be included after deployment");
  }
  console.log();

  // ─────────────────────────────────────────────────────────
  // Summary
  // ─────────────────────────────────────────────────────────

  console.log("=".repeat(60));
  console.log("  SUMMARY");
  console.log("=".repeat(60));
  console.log(`  Success: ${successCount}`);
  console.log(`  Skipped: ${skipCount}`);
  console.log(`  Errors:  ${errorCount}`);
  if (dryRun) {
    console.log("  Mode:    DRY RUN (no transactions sent)");
  }
  console.log("=".repeat(60));

  if (txHashes.length > 0) {
    console.log("\n  Transaction Log:");
    for (const tx of txHashes) {
      console.log(`    ${tx.action.padEnd(20)} ${tx.contract.padEnd(30)} ${tx.hash}`);
    }
  }

  if (errorCount > 0) {
    console.log("\nWARNING: Some operations failed. Review errors above before proceeding.");
    process.exit(1);
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
