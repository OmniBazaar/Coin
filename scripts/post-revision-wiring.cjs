/**
 * Post-governance wiring (deployer-admin actions, NOT part of the proposal).
 *
 * Run AFTER the 2026-10 proposal has executed:
 *   1. point the new EscrowV2 at the arbitration proxy (so XOM panel disputes
 *      work — the currently deployed escrow was shipped with this unset);
 *   2. seed EscrowV2's internal arbitrator list with the three founder
 *      accounts (covers private pXOM escrows and any internal-path use);
 *   3. print the state that proves each step.
 *
 * Usage:
 *   MAINNET_DEPLOYER_PRIVATE_KEY=$(cat ~/.avalanche-cli/key/deployer.pk) \
 *     npx hardhat run scripts/post-revision-wiring.cjs --network mainnet
 */
const fs = require("fs");
const path = require("path");
const hre = require("hardhat");

const EXPECTED_DEPLOYER = "0x021868f2E3D49C059EF52B539AAa933B437e0321";
const REVISION = path.join(__dirname, "..", "deployments", "revision-2026-10.json");
const MANIFEST = path.join(__dirname, "..", "deployments", "mainnet.json");

/** Founder accounts that must be able to judge (allowlisted or KYC-qualified). */
const ARBITRATORS = {
  omnirick: "0x213490a7C0E1681ad4239FBbE829994aeEecd193",
  rickcrites: "0xB475206e51E99a4D4905751a02A12eA5E052B94d",
  omnibazaar_marketing: "0x824b6b38E7ab95d3Cb6B132481985BAc9BD52683",
};

async function main() {
  const { ethers } = hre;
  const [deployer] = await ethers.getSigners();
  if (deployer.address.toLowerCase() !== EXPECTED_DEPLOYER.toLowerCase()) {
    throw new Error(`wrong signer: ${deployer.address}`);
  }
  const rev = JSON.parse(fs.readFileSync(REVISION, "utf8"));
  const c = JSON.parse(fs.readFileSync(MANIFEST, "utf8")).contracts;
  const escrow = await ethers.getContractAt("EscrowV2", rev.escrowV2);

  // 1. Point the escrow at the arbitration proxy.
  const current = await escrow.arbitrationContract();
  if (current.toLowerCase() !== c.OmniArbitration.toLowerCase()) {
    const tx = await escrow.setArbitrationContract(c.OmniArbitration);
    await tx.wait();
    console.log("setArbitrationContract:", tx.hash);
  } else {
    console.log("escrow already points at the arbitration proxy");
  }

  // 2. Internal arbitrator list.
  for (const [name, addr] of Object.entries(ARBITRATORS)) {
    if (await escrow.isRegisteredArbitrator(addr)) {
      console.log(name, "already an internal arbitrator");
      continue;
    }
    const tx = await escrow.addArbitrator(addr);
    await tx.wait();
    console.log(name, "added as internal arbitrator:", tx.hash);
  }

  // 3. Arbitration qualification source + founder allowlist.
  //
  // The hardened panel reads KYC straight from OmniRegistration and trusts a
  // local founder allowlist. Without this step every judge is unqualified and
  // the first registration prunes the whole pool (audit H-03).
  const arbitration = await ethers.getContractAt("OmniArbitration", c.OmniArbitration);
  const currentRegistration = await arbitration.registration();
  if (currentRegistration.toLowerCase() !== c.OmniRegistration.toLowerCase()) {
    const tx = await arbitration.setRegistration(c.OmniRegistration);
    await tx.wait();
    console.log("setRegistration:", tx.hash);
  } else {
    console.log("registration already set");
  }
  for (const [name, addr] of Object.entries(ARBITRATORS)) {
    if (await arbitration.founderArbitrator(addr)) {
      console.log(name, "already a founder arbitrator");
      continue;
    }
    const tx = await arbitration.setFounderArbitrator(addr, true);
    await tx.wait();
    console.log(name, "allowlisted as founder arbitrator:", tx.hash);
  }

  // 4. Proof.
  console.log("\n== state ==");
  console.log("escrow.arbitrationContract:", await escrow.arbitrationContract());
  console.log("escrow.arbitratorCount:", (await escrow.arbitratorCount()).toString());
  const vault = await ethers.getContractAt(
    ["function DEPOSITOR_ROLE() view returns (bytes32)", "function hasRole(bytes32,address) view returns (bool)"],
    c.UnifiedFeeVault,
  );
  console.log(
    "escrow holds DEPOSITOR_ROLE:",
    await vault.hasRole(await vault.DEPOSITOR_ROLE(), rev.escrowV2),
  );
  console.log("arbitration.registration:", await arbitration.registration());
  for (const [name, addr] of Object.entries(ARBITRATORS)) {
    console.log(`canBeArbitrator(${name}):`, await arbitration.canBeArbitrator(addr));
  }
  console.log("arbitratorPoolSize:", (await arbitration.arbitratorPoolSize()).toString());
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
