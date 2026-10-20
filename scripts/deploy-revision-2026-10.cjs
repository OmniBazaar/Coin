/**
 * Deploy the 2026-10 governance-revision implementations (NO upgrade).
 *
 * This script only puts bytecode on chain and writes the addresses to
 * `deployments/revision-2026-10.json`. The proxies are upgraded by the
 * governance proposal built by `scripts/governance/propose-revision-2026-10.cjs`
 * and executed after the timelock delay. Nothing here changes live state
 * except the new, un-wired EscrowV2 instance.
 *
 * Usage:
 *   MAINNET_DEPLOYER_PRIVATE_KEY=$(cat ~/.avalanche-cli/key/deployer.pk) \
 *     npx hardhat run scripts/deploy-revision-2026-10.cjs --network mainnet
 */
const fs = require("fs");
const path = require("path");
const hre = require("hardhat");

const EXPECTED_DEPLOYER = "0x021868f2E3D49C059EF52B539AAa933B437e0321";
const OUT = path.join(__dirname, "..", "deployments", "revision-2026-10.json");
const MANIFEST = path.join(__dirname, "..", "deployments", "mainnet.json");

async function main() {
  const { ethers } = hre;
  const [deployer] = await ethers.getSigners();
  if (deployer.address.toLowerCase() !== EXPECTED_DEPLOYER.toLowerCase()) {
    throw new Error(`wrong signer: ${deployer.address}`);
  }
  const network = await ethers.provider.getNetwork();
  if (network.chainId !== 88008n) throw new Error("wrong chain");

  const manifest = JSON.parse(fs.readFileSync(MANIFEST, "utf8")).contracts;
  const xom = manifest.OmniCoin;
  const pxom = manifest.PrivateOmniCoin;
  const registry = manifest.OmniRegistration;
  const vault = manifest.UnifiedFeeVault;
  const forwarder = manifest.OmniForwarder;

  const out = { deployedAt: new Date().toISOString(), deployer: deployer.address };

  console.log("== EscrowV2 (revision) ==");
  const Escrow = await ethers.getContractFactory("EscrowV2");
  const escrow = await Escrow.deploy(xom, pxom, registry, vault, 100n, forwarder);
  await escrow.waitForDeployment();
  out.escrowV2 = await escrow.getAddress();
  out.escrowV2Tx = escrow.deploymentTransaction()?.hash ?? "";
  console.log(out.escrowV2, out.escrowV2Tx);

  console.log("== OmniParticipation implementation ==");
  const Participation = await ethers.getContractFactory("OmniParticipation");
  // Implementation constructor: trusted forwarder, then initializers are
  // disabled on the implementation itself.
  const participation = await Participation.deploy(forwarder);
  await participation.waitForDeployment();
  out.participationImpl = await participation.getAddress();
  out.participationTx = participation.deploymentTransaction()?.hash ?? "";
  console.log(out.participationImpl, out.participationTx);

  console.log("== OmniArbitration implementation ==");
  const Arbitration = await ethers.getContractFactory("OmniArbitration");
  const arbitration = await Arbitration.deploy(forwarder);
  await arbitration.waitForDeployment();
  out.arbitrationImpl = await arbitration.getAddress();
  out.arbitrationTx = arbitration.deploymentTransaction()?.hash ?? "";
  console.log(out.arbitrationImpl, out.arbitrationTx);

  fs.writeFileSync(OUT, `${JSON.stringify(out, null, 2)}\n`);
  console.log("\nwrote", OUT);
  console.log("Next: node scripts/governance/propose-revision-2026-10.cjs");
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
