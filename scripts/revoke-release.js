/**
 * ODDAO Release Revocation Tool
 *
 * Signs and submits a revokeRelease transaction to the UpdateRegistry.
 * Revoked releases trigger mandatory update warnings on all nodes.
 *
 * Usage:
 *   npx hardhat run scripts/revoke-release.js --network fuji -- \
 *     --component validator --version 1.2.0 --reason "CVE-2026-XXXX"
 *
 * For multi-sig: each signer runs sign-revoke.js, then the admin submits
 * with collected signatures. For testnet (threshold=1), this script handles
 * both signing and submission.
 *
 * @module scripts/revoke-release
 */

const { ethers } = require("hardhat");
const fs = require("fs");
const path = require("path");

// ── CLI argument parsing ────────────────────────────────────────────────

function parseArgs() {
  const args = process.argv.slice(2);
  const parsed = {};
  // Skip hardhat args (before --)
  let skipHardhat = true;
  for (let i = 0; i < args.length; i++) {
    if (args[i] === "--") {
      skipHardhat = false;
      continue;
    }
    if (skipHardhat && !args[i].startsWith("--component") && !args[i].startsWith("--version") && !args[i].startsWith("--reason")) {
      continue;
    }
    if (args[i].startsWith("--") && i + 1 < args.length) {
      const key = args[i].replace(/^--/, "").replace(/-([a-z])/g, (_, c) => c.toUpperCase());
      parsed[key] = args[i + 1];
      i++;
    }
  }
  return parsed;
}

// ── Configuration ───────────────────────────────────────────────────────

const DEPLOYMENT_FILE = path.join(__dirname, "../deployments/fuji.json");

// ── Main ────────────────────────────────────────────────────────────────

async function main() {
  const args = parseArgs();
  const component = args.component;
  const version = args.version;
  const reason = args.reason;

  if (!component || !version || !reason) {
    console.error("Usage: npx hardhat run scripts/revoke-release.js --network fuji -- \\");
    console.error("  --component <name> --version <semver> --reason <text>");
    process.exit(1);
  }

  console.log("=== ODDAO Release Revocation ===\n");

  const [deployer] = await ethers.getSigners();
  console.log("Submitter:", deployer.address);

  // Verify chain
  const network = await ethers.provider.getNetwork();
  if (network.chainId !== 131313n) {
    throw new Error(`Expected chainId 131313, got ${network.chainId}`);
  }

  // Load contract
  const deployment = JSON.parse(fs.readFileSync(DEPLOYMENT_FILE, "utf8"));
  const registryAddress = deployment.contracts.UpdateRegistry;
  if (!registryAddress || registryAddress === "0x0000000000000000000000000000000000000000") {
    throw new Error("UpdateRegistry not deployed");
  }

  const UpdateRegistry = await ethers.getContractFactory("UpdateRegistry");
  const registry = UpdateRegistry.attach(registryAddress);

  // Verify release exists and is not already revoked
  const release = await registry.getRelease(component, version);
  if (release.publishedAt === 0n) {
    throw new Error(`Release ${component} v${version} not found on-chain`);
  }
  if (release.revoked) {
    throw new Error(`Release ${component} v${version} is already revoked`);
  }

  const nonce = await registry.operationNonce();
  const threshold = await registry.signerThreshold();
  const chainId = network.chainId;

  console.log("Registry:       ", registryAddress);
  console.log("Component:      ", component);
  console.log("Version:        ", version);
  console.log("Reason:         ", reason);
  console.log("Operation Nonce:", nonce.toString());
  console.log("Threshold:      ", threshold.toString());

  // Build the REVOKE message hash (must match contract)
  const messageHash = ethers.keccak256(
    ethers.AbiCoder.defaultAbiCoder().encode(
      ["string", "string", "string", "string", "uint256", "uint256", "address"],
      ["REVOKE", component, version, reason, nonce, chainId, registryAddress]
    )
  );

  // Sign (for testnet with threshold=1, deployer is the sole signer)
  const signature = await deployer.signMessage(ethers.getBytes(messageHash));
  console.log("\nSignature generated.");

  // Submit revocation
  console.log("\n=== Submitting revokeRelease Transaction ===");
  const tx = await registry.revokeRelease(
    component,
    version,
    reason,
    nonce,
    [signature]
  );

  console.log("Transaction hash:", tx.hash);
  console.log("Waiting for confirmation...");

  const receipt = await tx.wait();
  console.log("Confirmed in block:", receipt.blockNumber);

  // Verify on-chain
  const updated = await registry.getRelease(component, version);
  console.log("\n=== On-Chain Verification ===");
  console.log("Revoked:       ", updated.revoked);
  console.log("Revoke reason: ", updated.revokeReason);

  console.log(`\n${component} v${version} has been revoked.`);
  console.log("Nodes running this version will receive mandatory update warnings.");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("\nRevocation failed:", error.message ?? error);
    process.exit(1);
  });
