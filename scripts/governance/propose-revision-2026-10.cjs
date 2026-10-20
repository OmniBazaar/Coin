/**
 * Build (and optionally submit) the 2026-10 governance proposal.
 *
 * Four actions, executed atomically by the timelock after the vote and the
 * 48-hour delay:
 *
 *   1. UnifiedFeeVault.grantRole(DEPOSITOR_ROLE, newEscrow)
 *      → escrow releases take the referral-aware 9-way split (referrers and
 *        both nodes paid) instead of the plain-transfer fallback.
 *   2. OmniParticipation proxy `upgradeToAndCall(newImpl, 0x)`
 *      → listing node == service node (score ≥ 25 + KYC tier 2), and all
 *        three role gates honour the pioneer founder allowlist.
 *   3. OmniArbitration proxy `upgradeToAndCall(newImpl, 0x)`
 *      → arbitrators use the node standard; createDispute refuses a panel it
 *        cannot seat; cancelDispute refunds a stuck fee.
 *   4. OmniArbitration.updateContracts(participation, newEscrow)
 *      → the panel adjudicates the marketplace escrow, not the legacy one.
 *
 * EscrowV2's own `setArbitrationContract` is a deployer-admin action and is
 * NOT part of the proposal (run scripts/post-revision-wiring.cjs after
 * execution).
 *
 * Usage:
 *   MAINNET_DEPLOYER_PRIVATE_KEY=$(cat ~/.avalanche-cli/key/deployer.pk) \
 *     npx hardhat run scripts/governance/propose-revision-2026-10.cjs --network mainnet
 * Add DRY_RUN=1 to print the calldata without submitting.
 */
const fs = require("fs");
const path = require("path");
const hre = require("hardhat");

const DRY_RUN = process.env.DRY_RUN === "1";
const EXPECTED_DEPLOYER = "0x021868f2E3D49C059EF52B539AAa933B437e0321";
const REVISION = path.join(__dirname, "..", "..", "deployments", "revision-2026-10.json");
const MANIFEST = path.join(__dirname, "..", "..", "deployments", "mainnet.json");

async function main() {
  const { ethers } = hre;
  const [deployer] = await ethers.getSigners();
  if (deployer.address.toLowerCase() !== EXPECTED_DEPLOYER.toLowerCase()) {
    throw new Error(`wrong signer: ${deployer.address}`);
  }
  const network = await ethers.provider.getNetwork();
  if (network.chainId !== 88008n) throw new Error("wrong chain");

  if (!fs.existsSync(REVISION)) {
    throw new Error(`missing ${REVISION} — run scripts/deploy-revision-2026-10.cjs first`);
  }
  const rev = JSON.parse(fs.readFileSync(REVISION, "utf8"));
  const c = JSON.parse(fs.readFileSync(MANIFEST, "utf8")).contracts;

  const vault = c.UnifiedFeeVault;
  const participationProxy = c.OmniParticipation;
  const arbitrationProxy = c.OmniArbitration;
  const governance = c.OmniGovernance;
  for (const [k, v] of Object.entries({ vault, participationProxy, arbitrationProxy, governance })) {
    if (!v || !ethers.isAddress(v)) throw new Error(`manifest missing ${k}`);
  }

  const vaultIface = new ethers.Interface([
    "function DEPOSITOR_ROLE() view returns (bytes32)",
    "function grantRole(bytes32 role, address account)",
  ]);
  const proxyIface = new ethers.Interface([
    "function upgradeToAndCall(address newImplementation, bytes data) payable",
  ]);
  const arbitrationIface = new ethers.Interface([
    "function updateContracts(address participation, address escrow)",
  ]);

  const depositorRole = await new ethers.Contract(vault, vaultIface, ethers.provider).DEPOSITOR_ROLE();

  const targets = [vault, participationProxy, arbitrationProxy, arbitrationProxy];
  const values = [0n, 0n, 0n, 0n];
  const calldatas = [
    vaultIface.encodeFunctionData("grantRole", [depositorRole, rev.escrowV2]),
    proxyIface.encodeFunctionData("upgradeToAndCall", [rev.participationImpl, "0x"]),
    proxyIface.encodeFunctionData("upgradeToAndCall", [rev.arbitrationImpl, "0x"]),
    arbitrationIface.encodeFunctionData("updateContracts", [participationProxy, rev.escrowV2]),
  ];

  console.log("== proposal actions ==");
  targets.forEach((t, i) => console.log(`${i + 1}. ${t} ${calldatas[i]}`));

  if (DRY_RUN) {
    console.log("\nDRY_RUN=1 — nothing submitted");
    return;
  }

  const description =
    "2026-10 marketplace fee + arbitration revision: grant DEPOSITOR_ROLE to " +
    `EscrowV2 ${rev.escrowV2}; upgrade OmniParticipation and OmniArbitration ` +
    "implementations; point the arbiters at the marketplace escrow.";

  const gov = await ethers.getContractAt(
    ["function propose(uint8 proposalType,address[] targets,uint256[] values,bytes[] calldatas,string description) returns (uint256)"],
    governance,
  );
  const tx = await gov.propose(1 /* CRITICAL */, targets, values, calldatas, description);
  const receipt = await tx.wait();
  console.log("\nproposal tx:", tx.hash, "block", receipt.blockNumber);

  const events = receipt.logs
    .map((l) => {
      try {
        return gov.interface.parseLog(l);
      } catch {
        return null;
      }
    })
    .filter(Boolean);
  for (const e of events) {
    if (e && e.name === "ProposalCreated") console.log("proposalId:", e.args[0].toString());
  }
  console.log("\nNext: vote (see scripts/governance/README-revision-2026-10.md),");
  console.log("then execute after the 48h timelock; then run scripts/post-revision-wiring.cjs");
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
