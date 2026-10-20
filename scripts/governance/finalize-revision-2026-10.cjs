/**
 * Finalise the 2026-10 governance revision: queue after the vote, execute after
 * the timelock. Idempotent — it reads the on-chain state and does the ONE next
 * legal step, so running it early or twice is harmless.
 *
 * Usage:
 *   MAINNET_DEPLOYER_PRIVATE_KEY=$(cat ~/.avalanche-cli/key/iceberg-omnibazaar.pk) \
 *     npx hardhat run scripts/governance/finalize-revision-2026-10.cjs --network mainnet
 * Options (env): PROPOSAL_ID (default 16), DRY_RUN=1 to only report the state.
 */
const fs = require("fs");
const path = require("path");
const hre = require("hardhat");

const MANIFEST = path.join(__dirname, "..", "..", "deployments", "mainnet.json");
const PROPOSAL_ID = BigInt(process.env.PROPOSAL_ID || "16");
const DRY_RUN = process.env.DRY_RUN === "1";

/** ProposalState enum order as the contract declares it. */
const STATE = [
  "Pending",
  "Active",
  "Cancelled",
  "Succeeded",
  "Queued",
  "Executed",
  "Defeated",
  "Expired",
];

async function main() {
  const { ethers } = hre;
  const [signer] = await ethers.getSigners();
  const network = await ethers.provider.getNetwork();
  if (network.chainId !== 88008n) throw new Error("wrong chain");

  const governance = JSON.parse(fs.readFileSync(MANIFEST, "utf8")).contracts.OmniGovernance;
  const gov = await ethers.getContractAt(
    [
      "function queue(uint256 proposalId)",
      "function execute(uint256 proposalId)",
      "function state(uint256 proposalId) view returns (uint8)",
      "function getVotingPower(address account) view returns (uint256)",
    ],
    governance,
    signer,
  );

  const state = Number(await gov.state(PROPOSAL_ID));
  const name = STATE[state] ?? state.toString();
  console.log("proposal", PROPOSAL_ID.toString(), "state:", name, "signer:", signer.address);
  console.log("voting power:", ethers.formatEther(await gov.getVotingPower(signer.address)));

  if (DRY_RUN) return;

  if (name === "Succeeded") {
    const tx = await gov.queue(PROPOSAL_ID);
    const receipt = await tx.wait();
    console.log("queued:", tx.hash, "block", receipt.blockNumber);
    console.log("now state:", STATE[Number(await gov.state(PROPOSAL_ID))]);
    return;
  }
  if (name === "Queued") {
    const tx = await gov.execute(PROPOSAL_ID);
    const receipt = await tx.wait();
    console.log("executed:", tx.hash, "block", receipt.blockNumber);
    console.log("now state:", STATE[Number(await gov.state(PROPOSAL_ID))]);
    return;
  }
  console.log(`nothing to do in state "${name}" (Active: wait for the vote to end)`);
}

main().catch((err) => {
  console.error(err.shortMessage || err.message || err);
  process.exitCode = 1;
});
