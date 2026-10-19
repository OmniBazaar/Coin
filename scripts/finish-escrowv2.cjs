/**
 * Finish the EscrowV2 deployment recorded by scripts/deploy-escrowv2.cjs.
 *
 * The first run deployed the contract but stopped at `grantRole` because the
 * deployer does not hold DEFAULT_ADMIN_ROLE on UnifiedFeeVault (verified
 * on-chain: neither does the v1 escrow, so fee deposits have always used the
 * direct-transfer fallback). That is recorded, not fatal.
 *
 * This script is idempotent: manifest entry, arbitrator seed, and verification.
 */
const fs = require("fs");
const path = require("path");
const hre = require("hardhat");

const ESCROW = process.env.ESCROW_ADDRESS || "0x07aE62cFfe705e004bAbdECE2a336b0F548f230b";
const EXPECTED_DEPLOYER = "0x021868f2E3D49C059EF52B539AAa933B437e0321";
const MANIFEST = path.join(__dirname, "..", "deployments", "mainnet.json");

async function main() {
  const { ethers } = hre;
  const [deployer] = await ethers.getSigners();
  if (deployer.address.toLowerCase() !== EXPECTED_DEPLOYER.toLowerCase()) {
    throw new Error(`wrong signer: ${deployer.address}`);
  }
  const network = await ethers.provider.getNetwork();
  if (network.chainId !== 88008n) throw new Error("wrong chain");

  const escrow = await ethers.getContractAt("EscrowV2", ESCROW);
  const manifest = JSON.parse(fs.readFileSync(MANIFEST, "utf8"));
  const c = manifest.contracts;

  console.log("EscrowV2:", ESCROW);
  console.log("admin:", await escrow.admin());
  console.log("fee bps:", (await escrow.MARKETPLACE_FEE_BPS()).toString());

  // 1. Manifest.
  if (c.EscrowV2 !== ESCROW) {
    manifest.contracts.EscrowV2 = ESCROW;
    manifest.contracts.EscrowV2DeployedAt = manifest.contracts.EscrowV2DeployedAt ||
      new Date().toISOString();
    manifest.contracts.EscrowV2DeployTx = manifest.contracts.EscrowV2DeployTx ||
      "0x3a0feb1fe28831551b91b112af08f0f111df02f5e510423b8855556dd413aeb1";
    fs.writeFileSync(MANIFEST, `${JSON.stringify(manifest, null, 2)}\n`);
    console.log("manifest updated");
  } else {
    console.log("manifest already contains EscrowV2");
  }

  // 2. Arbitrator seed — without one, every revealDispute reverts.
  let count = await escrow.arbitratorCount();
  if (count === 0n) {
    const tx = await escrow.addArbitrator(deployer.address);
    await tx.wait();
    console.log("arbitrator seeded:", deployer.address, "tx:", tx.hash);
    count = await escrow.arbitratorCount();
  }
  console.log("arbitratorCount:", count.toString());
  for (let i = 0n; i < count; i += 1n) {
    console.log("  ", i.toString(), await escrow.arbitratorList(i));
  }

  // 3. DEPOSITOR_ROLE status (informational — the fallback keeps releases live).
  const vault = await ethers.getContractAt(
    ["function DEPOSITOR_ROLE() view returns (bytes32)", "function hasRole(bytes32,address) view returns (bool)"],
    c.UnifiedFeeVault,
  );
  const role = await vault.DEPOSITOR_ROLE();
  console.log(
    "escrow holds DEPOSITOR_ROLE:",
    await vault.hasRole(role, ESCROW),
    "(false => the 1% goes to the vault via the direct-transfer fallback, same as v1)",
  );

  console.log("\nDONE");
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
