/**
 * Grant BRIDGE_ROLE on UnifiedFeeVault
 *
 * Grants the BRIDGE_ROLE to an operator wallet so it can call
 * bridgeToTreasury(), swapAndBridge(), and convertPXOMAndBridge().
 *
 * Usage:
 *   npx hardhat run scripts/grant-bridge-role.js --network fuji
 *
 * Defaults to granting the role to the deployer wallet (first signer).
 * Override by setting BRIDGE_OPERATOR_ADDRESS environment variable.
 *
 * @module scripts/grant-bridge-role
 */

const { ethers } = require("hardhat");

const UNIFIED_FEE_VAULT_PROXY = "0x45dB9304a5124d3cD6d646900b1c4C0cA6A89658";

async function main() {
  console.log("=".repeat(60));
  console.log("Grant BRIDGE_ROLE on UnifiedFeeVault");
  console.log("=".repeat(60));

  const [admin] = await ethers.getSigners();
  console.log("\nAdmin (caller):", admin.address);

  const operatorAddress = process.env.BRIDGE_OPERATOR_ADDRESS || admin.address;
  console.log("Operator (grantee):", operatorAddress);
  console.log("Vault:", UNIFIED_FEE_VAULT_PROXY);

  // Connect to vault
  const vault = await ethers.getContractAt("UnifiedFeeVault", UNIFIED_FEE_VAULT_PROXY);

  // Get the BRIDGE_ROLE bytes32
  const BRIDGE_ROLE = await vault.BRIDGE_ROLE();
  console.log("\nBRIDGE_ROLE:", BRIDGE_ROLE);

  // Check if already granted
  const alreadyHas = await vault.hasRole(BRIDGE_ROLE, operatorAddress);
  if (alreadyHas) {
    console.log("\nOperator already has BRIDGE_ROLE - nothing to do.");
    return;
  }

  // Verify caller has admin rights
  const DEFAULT_ADMIN_ROLE = await vault.DEFAULT_ADMIN_ROLE();
  const callerIsAdmin = await vault.hasRole(DEFAULT_ADMIN_ROLE, admin.address);
  if (!callerIsAdmin) {
    const ADMIN_ROLE = await vault.ADMIN_ROLE();
    const callerIsAdminRole = await vault.hasRole(ADMIN_ROLE, admin.address);
    if (!callerIsAdminRole) {
      console.error("\nERROR: Caller does not have DEFAULT_ADMIN_ROLE or ADMIN_ROLE.");
      console.error("Only admins can grant roles.");
      process.exit(1);
    }
  }

  // Grant the role
  console.log("\nGranting BRIDGE_ROLE...");
  const tx = await vault.grantRole(BRIDGE_ROLE, operatorAddress);
  console.log("TX hash:", tx.hash);
  const receipt = await tx.wait();
  console.log("Confirmed in block:", receipt.blockNumber);

  // Verify
  const hasRole = await vault.hasRole(BRIDGE_ROLE, operatorAddress);
  if (hasRole) {
    console.log("\nBRIDGE_ROLE granted successfully to", operatorAddress);
  } else {
    console.error("\nERROR: Role grant verification failed!");
    process.exit(1);
  }

  console.log("\n" + "=".repeat(60));
  console.log("Done.");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("Error:", error);
    process.exit(1);
  });
