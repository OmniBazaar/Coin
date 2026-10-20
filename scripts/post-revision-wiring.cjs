/**
 * Post-deploy wiring for the 2026-10 arbitration revision (deployer-admin
 * actions, NOT part of the governance proposal).
 *
 * Founder decisions 1 and 3 (2026-10-20):
 *   - the hardened panel is a FRESH proxy (scripts/deploy-arbitration-panel.cjs),
 *     so every qualification input is set here, by the deployer that owns it;
 *   - the escrow the Validator uses is the PRODUCTION MinimalEscrow, and it is
 *     pointed at the new panel here. That is the step that makes a public
 *     dispute openable end to end.
 *
 * STEPS
 *   1. panel.setRegistration(OmniRegistration)      — KYC source for the gate
 *   2. panel.setFounderArbitrator(founder, true) ×3 — pioneer allowlist
 *   3. MinimalEscrow.addArbitrator(founder) ×3      — internal/pXOM disputes
 *   4. MinimalEscrow.setArbitrationContract(panel)  — LIVE routing change
 *   5. prove it: canBeArbitrator(founder) for all three, escrow pointer, and
 *      that the panel can seat a panel (arbitratorPoolSize >= 1).
 *
 * 🛑 Reaching step 4 while an internal XOM dispute is open is forbidden (M-04):
 * check `escrowToDisputeId` is empty for the production escrow first. The
 * script refuses to move the pointer if it cannot confirm the escrow has no
 * recorded dispute.
 *
 * Usage:
 *   MAINNET_DEPLOYER_PRIVATE_KEY=$(cat ~/.avalanche-cli/key/deployer.pk) \
 *     npx hardhat run scripts/post-revision-wiring.cjs --network mainnet
 */
const fs = require("fs");
const path = require("path");
const hre = require("hardhat");

const EXPECTED_DEPLOYER = "0x021868f2E3D49C059EF52B539AAa933B437e0321";
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
  const network = await ethers.provider.getNetwork();
  if (network.chainId !== 88008n) throw new Error("wrong chain");

  const c = JSON.parse(fs.readFileSync(MANIFEST, "utf8")).contracts;
  const panelAddress = c.OmniArbitration;
  const escrowAddress = c.MinimalEscrow;
  const registration = c.OmniRegistration;
  for (const [name, addr] of Object.entries({ panelAddress, escrowAddress, registration })) {
    if (!addr || !ethers.isAddress(addr)) throw new Error(`manifest missing ${name}`);
  }

  const panel = await ethers.getContractAt("OmniArbitration", panelAddress);
  const escrow = await ethers.getContractAt("MinimalEscrow", escrowAddress);

  // The new panel must already point at this escrow; a mismatch means the
  // deploy script was run against the wrong escrow constant.
  const panelEscrow = await panel.escrow();
  if (panelEscrow.toLowerCase() !== escrowAddress.toLowerCase()) {
    throw new Error(
      `panel escrow ${panelEscrow} != production escrow ${escrowAddress}; re-run deploy-arbitration-panel.cjs`,
    );
  }

  // ── 1. KYC source ──────────────────────────────────────────────────────
  console.log("== qualification source ==");
  const currentRegistration = await panel.registration();
  if (currentRegistration.toLowerCase() !== registration.toLowerCase()) {
    const tx = await panel.setRegistration(registration);
    await tx.wait();
    console.log("setRegistration:", tx.hash);
  } else {
    console.log("registration already set");
  }

  // ── 2. Founder arbitrators on the panel ────────────────────────────────
  for (const [name, addr] of Object.entries(ARBITRATORS)) {
    if (await panel.founderArbitrator(addr)) {
      console.log(name, "already a founder arbitrator");
      continue;
    }
    const tx = await panel.setFounderArbitrator(addr, true);
    await tx.wait();
    console.log(name, "allowlisted as founder arbitrator:", tx.hash);
  }

  // ── 3. Internal arbitrators on the production escrow ───────────────────
  // Needed for private (pXOM) escrows, which never reach the panel.
  console.log("\n== production escrow internal arbitrators ==");
  for (const [name, addr] of Object.entries(ARBITRATORS)) {
    if (await escrow.isRegisteredArbitrator(addr)) {
      console.log(name, "already an internal arbitrator");
      continue;
    }
    const tx = await escrow.addArbitrator(addr);
    await tx.wait();
    console.log(name, "added as internal arbitrator:", tx.hash);
  }

  // ── 4. Point the production escrow at the new panel ─────────────────────
  console.log("\n== live routing change ==");
  const current = await escrow.arbitrationContract();
  if (current.toLowerCase() === panelAddress.toLowerCase()) {
    console.log("escrow already points at the new panel");
  } else {
    // M-04: never move the pointer under an open dispute — and the disputes
    // live on the CURRENT panel, not the fresh one.
    if (current.toLowerCase() === ethers.ZeroAddress) {
      console.log("escrow has no panel wired yet");
    } else {
      const oldPanel = await ethers.getContractAt("OmniArbitration", current);
      const escrowCounter = await escrow.escrowCounter();
      let openDisputes = 0n;
      for (let id = 1n; id <= escrowCounter; id += 1n) {
        const disputeId = await oldPanel.escrowToDisputeId(id);
        if (disputeId === 0n) continue;
        const d = await oldPanel.disputes(disputeId);
        // 0 Active, 3 DefaultResolved, 4 PendingSelection are all "live".
        const status = Number(d.status ?? d[10]);
        if (status === 0 || status === 3 || status === 4) openDisputes += 1n;
      }
      if (openDisputes > 0n) {
        throw new Error(
          `${openDisputes} open dispute(s) on the production escrow — refusing to re-point the panel (M-04)`,
        );
      }
    }
    const tx = await escrow.setArbitrationContract(panelAddress);
    await tx.wait();
    console.log("setArbitrationContract:", tx.hash, "->", panelAddress);
  }

  // ── 5. Proof ───────────────────────────────────────────────────────────
  console.log("\n== state ==");
  console.log("escrow.arbitrationContract:", await escrow.arbitrationContract());
  console.log("escrow.arbitratorCount:", (await escrow.arbitratorCount()).toString());
  console.log("panel.registration:", await panel.registration());
  console.log("panel.arbitratorPoolSize:", (await panel.arbitratorPoolSize()).toString());
  // `canBeArbitrator` also requires the stake, which only arrives when the
  // judge calls registerArbitrator itself. The deployer can prove the IDENTITY
  // half here; the stake half is the judge's own transaction.
  let qualified = 0;
  for (const [name, addr] of Object.entries(ARBITRATORS)) {
    const allowlisted = await panel.founderArbitrator(addr);
    const registered = (await panel.arbitratorStakes(addr)) > 0n;
    const eligible = await panel.canBeArbitrator(addr);
    console.log(
      `${name}: founder-allowlisted=${allowlisted} registered=${registered} canBeArbitrator=${eligible}`,
    );
    if (allowlisted) qualified += 1;
  }
  const vault = await ethers.getContractAt(
    [
      "function DEPOSITOR_ROLE() view returns (bytes32)",
      "function hasRole(bytes32,address) view returns (bool)",
    ],
    c.UnifiedFeeVault,
  );
  console.log(
    "production escrow holds DEPOSITOR_ROLE:",
    await vault.hasRole(await vault.DEPOSITOR_ROLE(), escrowAddress),
  );
  if (qualified === 0) {
    throw new Error("no founder is allowlisted on the new panel — registration will fail");
  }
  console.log(
    `\n${qualified}/3 founders are allowlisted. Registration (10,000 XOM stake) is a party action: Wallet → Settings → Marketplace → Arbitrator.`,
  );
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
