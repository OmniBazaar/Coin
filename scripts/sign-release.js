/**
 * ODDAO Release Signing Tool
 *
 * Signs a release message hash that can be submitted to the UpdateRegistry
 * contract via publish-release.js. Each ODDAO signer runs this script locally,
 * then the release manager collects all signatures and submits the transaction.
 *
 * Usage:
 *   node scripts/sign-release.js \
 *     --component validator \
 *     --version 1.2.0 \
 *     --hash 0x<sha256-of-binary> \
 *     --min-version 1.1.0 \
 *     [--key <private-key>]
 *
 * The private key can also be provided via ODDAO_SIGNER_KEY environment variable.
 *
 * @module scripts/sign-release
 */

const { ethers } = require("ethers");
const fs = require("fs");
const path = require("path");

// ── CLI argument parsing ────────────────────────────────────────────────

function parseArgs() {
  const args = process.argv.slice(2);
  const parsed = {};

  for (let i = 0; i < args.length; i += 2) {
    const key = args[i].replace(/^--/, "").replace(/-([a-z])/g, (_, c) => c.toUpperCase());
    parsed[key] = args[i + 1];
  }

  return parsed;
}

// ── Contract configuration ──────────────────────────────────────────────

const DEPLOYMENT_FILE = path.join(__dirname, "../deployments/fuji.json");
const CHAIN_ID = 131313n;
const RPC_URL = "http://127.0.0.1:40681/ext/bc/2TEeYGdsqvS3eLBk8vrd9bedJiPR7uyeUo1YChM75HtCf9TzFk/rpc";

const REGISTRY_ABI = [
  "function operationNonce() view returns (uint256)",
  "function getSigners() view returns (address[])",
  "function signerThreshold() view returns (uint256)",
];

// ── Main ────────────────────────────────────────────────────────────────

async function main() {
  const args = parseArgs();

  const component = args.component;
  const version = args.version;
  const binaryHash = args.hash;
  const minVersion = args.minVersion ?? "";
  const changelogCID = args.changelogCid ?? "";
  const privateKey = args.key ?? process.env.ODDAO_SIGNER_KEY;

  // Validate inputs
  if (!component || !version || !binaryHash) {
    console.error("Usage: node sign-release.js --component <name> --version <semver> --hash <0x...>");
    console.error("       [--min-version <semver>] [--changelog-cid <ipfs-cid>] [--key <private-key>]");
    process.exit(1);
  }

  if (!privateKey) {
    console.error("Error: Provide signer key via --key or ODDAO_SIGNER_KEY environment variable");
    process.exit(1);
  }

  if (!/^0x[0-9a-fA-F]{64}$/.test(binaryHash)) {
    console.error("Error: --hash must be a 32-byte hex string (0x + 64 hex chars)");
    process.exit(1);
  }

  // Load contract address
  const deployment = JSON.parse(fs.readFileSync(DEPLOYMENT_FILE, "utf8"));
  const registryAddress = deployment.contracts.UpdateRegistry;
  if (!registryAddress || registryAddress === "0x0000000000000000000000000000000000000000") {
    console.error("Error: UpdateRegistry not deployed. Run deploy-update-registry.js first.");
    process.exit(1);
  }

  // Connect to chain
  const provider = new ethers.JsonRpcProvider(RPC_URL, Number(CHAIN_ID), {
    staticNetwork: true,
  });
  const wallet = new ethers.Wallet(privateKey, provider);
  const registry = new ethers.Contract(registryAddress, REGISTRY_ABI, provider);

  console.log("=== ODDAO Release Signing ===");
  console.log("Signer:        ", wallet.address);
  console.log("Registry:      ", registryAddress);
  console.log("Component:     ", component);
  console.log("Version:       ", version);
  console.log("Binary Hash:   ", binaryHash);
  console.log("Min Version:   ", minVersion || "(none)");
  console.log("Changelog CID: ", changelogCID || "(none)");

  // Fetch current nonce
  const nonce = await registry.operationNonce();
  console.log("Operation Nonce:", nonce.toString());

  // Verify signer is in the signer set
  const signers = await registry.getSigners();
  const threshold = await registry.signerThreshold();

  if (!signers.map(s => s.toLowerCase()).includes(wallet.address.toLowerCase())) {
    console.error(`\nError: ${wallet.address} is NOT an authorized ODDAO signer.`);
    console.error("Authorized signers:", signers.join(", "));
    process.exit(1);
  }

  console.log("Threshold:     ", threshold.toString());
  console.log("Authorized:     YES\n");

  // Build the message hash (must match contract's _verifySignatures)
  const messageHash = ethers.keccak256(
    ethers.AbiCoder.defaultAbiCoder().encode(
      ["string", "string", "string", "bytes32", "string", "uint256", "uint256", "address"],
      ["PUBLISH_RELEASE", component, version, binaryHash, minVersion, nonce, CHAIN_ID, registryAddress]
    )
  );

  // Sign with EIP-191 prefix (ethSignedMessageHash)
  const signature = await wallet.signMessage(ethers.getBytes(messageHash));

  console.log("=== Signature ===");
  console.log(signature);

  // Write signature to file for collection
  const sigDir = path.join(__dirname, "../signatures");
  if (!fs.existsSync(sigDir)) {
    fs.mkdirSync(sigDir, { recursive: true });
  }

  const sigFile = path.join(sigDir, `${component}-${version}-${wallet.address.slice(0, 8)}.json`);
  const sigData = {
    signer: wallet.address,
    component,
    version,
    binaryHash,
    minVersion,
    changelogCID,
    nonce: nonce.toString(),
    chainId: CHAIN_ID.toString(),
    registry: registryAddress,
    signature,
    signedAt: new Date().toISOString(),
  };

  fs.writeFileSync(sigFile, JSON.stringify(sigData, null, 2));
  console.log("\nSignature saved to:", sigFile);
  console.log(`\nCollect ${threshold} signatures and run publish-release.js to submit.`);
}

main().catch((error) => {
  console.error("Signing failed:", error.message ?? error);
  process.exit(1);
});
