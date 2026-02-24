/**
 * ODDAO Release Publishing Tool
 *
 * Collects signed release attestations from ODDAO signers and submits the
 * publishRelease transaction to the UpdateRegistry on-chain contract.
 *
 * Prerequisites:
 *   1. Each ODDAO signer runs sign-release.js to create signature files
 *   2. Signature files are placed in Coin/signatures/
 *   3. The submitter must have RELEASE_MANAGER_ROLE on UpdateRegistry
 *
 * Usage:
 *   npx hardhat run scripts/publish-release.js --network fuji
 *
 * The script automatically discovers signature files matching the current
 * operation nonce.
 *
 * @module scripts/publish-release
 */

const { ethers } = require("hardhat");
const fs = require("fs");
const path = require("path");

// ── Configuration ───────────────────────────────────────────────────────

const DEPLOYMENT_FILE = path.join(__dirname, "../deployments/fuji.json");
const SIGNATURES_DIR = path.join(__dirname, "../signatures");

// ── Main ────────────────────────────────────────────────────────────────

async function main() {
  console.log("=== ODDAO Release Publisher ===\n");

  // Get deployer (must have RELEASE_MANAGER_ROLE)
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

  // Get current nonce
  const nonce = await registry.operationNonce();
  const threshold = await registry.signerThreshold();
  console.log("Registry:       ", registryAddress);
  console.log("Operation Nonce:", nonce.toString());
  console.log("Threshold:      ", threshold.toString());

  // Discover signature files
  if (!fs.existsSync(SIGNATURES_DIR)) {
    console.error("\nNo signatures directory found. Run sign-release.js first.");
    process.exit(1);
  }

  const sigFiles = fs.readdirSync(SIGNATURES_DIR)
    .filter(f => f.endsWith(".json"))
    .map(f => {
      const data = JSON.parse(fs.readFileSync(path.join(SIGNATURES_DIR, f), "utf8"));
      return { file: f, ...data };
    })
    .filter(s => s.nonce === nonce.toString());

  if (sigFiles.length === 0) {
    console.error(`\nNo signatures found for nonce ${nonce}. Run sign-release.js first.`);
    process.exit(1);
  }

  // Verify all signatures are for the same release
  const component = sigFiles[0].component;
  const version = sigFiles[0].version;
  const binaryHash = sigFiles[0].binaryHash;
  const minVersion = sigFiles[0].minVersion ?? "";
  const changelogCID = sigFiles[0].changelogCID ?? "";

  const mismatch = sigFiles.find(
    s => s.component !== component || s.version !== version || s.binaryHash !== binaryHash
  );
  if (mismatch) {
    console.error(`\nSignature mismatch: ${mismatch.file} differs from ${sigFiles[0].file}`);
    console.error("All signatures must be for the same component, version, and binary hash.");
    process.exit(1);
  }

  console.log("\n=== Release Details ===");
  console.log("Component:     ", component);
  console.log("Version:       ", version);
  console.log("Binary Hash:   ", binaryHash);
  console.log("Min Version:   ", minVersion || "(unchanged)");
  console.log("Changelog CID: ", changelogCID || "(none)");
  console.log("Signatures:    ", sigFiles.length, "of", threshold.toString(), "required");

  // Deduplicate by signer address (take first occurrence)
  const seen = new Set();
  const uniqueSigs = [];
  for (const s of sigFiles) {
    const addr = s.signer.toLowerCase();
    if (!seen.has(addr)) {
      seen.add(addr);
      uniqueSigs.push(s);
    }
  }

  if (uniqueSigs.length < Number(threshold)) {
    console.error(`\nInsufficient signatures: ${uniqueSigs.length} unique of ${threshold} required.`);
    console.error("Collect more signatures from ODDAO signers.");
    process.exit(1);
  }

  // Sort signatures by signer address (ascending) for deterministic ordering
  uniqueSigs.sort((a, b) => a.signer.toLowerCase().localeCompare(b.signer.toLowerCase()));
  const signatures = uniqueSigs.map(s => s.signature);

  console.log("\nSigners:");
  for (const s of uniqueSigs) {
    console.log(`  ${s.signer} (from ${s.file})`);
  }

  // Submit the transaction
  console.log("\n=== Submitting publishRelease Transaction ===");
  const tx = await registry.publishRelease(
    component,
    version,
    binaryHash,
    minVersion,
    changelogCID,
    nonce,
    signatures
  );

  console.log("Transaction hash:", tx.hash);
  console.log("Waiting for confirmation...");

  const receipt = await tx.wait();
  console.log("Confirmed in block:", receipt.blockNumber);

  // Verify on-chain
  const release = await registry.getRelease(component, version);
  console.log("\n=== On-Chain Verification ===");
  console.log("Published at:  ", new Date(Number(release.publishedAt) * 1000).toISOString());
  console.log("Binary hash:   ", release.binaryHash);
  console.log("Published by:  ", release.publishedBy);
  console.log("Revoked:       ", release.revoked);

  // Clean up used signature files
  console.log("\n=== Cleanup ===");
  for (const s of sigFiles) {
    const sigPath = path.join(SIGNATURES_DIR, s.file);
    fs.unlinkSync(sigPath);
    console.log("Removed:", s.file);
  }

  console.log("\nRelease published successfully!");
  console.log(`${component} v${version} is now on-chain.`);
  console.log("Validators will detect the new version within 30 minutes.");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("\nPublish failed:", error.message ?? error);
    process.exit(1);
  });
