/**
 * Vote on the 2026-10 governance revision.
 *
 * The proposer and the voter are the governance-weight account, because the
 * deployer account holds no voting power at all: `propose` reverts
 * `InsufficientVotingPower` below 1.7M XOM and a vote would carry zero weight.
 *
 * Usage:
 *   MAINNET_DEPLOYER_PRIVATE_KEY=$(cat ~/.avalanche-cli/key/iceberg-omnibazaar.pk) \
 *     npx hardhat run scripts/governance/vote-revision-2026-10.cjs --network mainnet
 * Options (env): PROPOSAL_ID (default 16), VOTE_SUPPORT (0 against, 1 for, 2 abstain; default 1)
 */
const fs = require("fs");
const path = require("path");
const hre = require("hardhat");

const MANIFEST = path.join(__dirname, "..", "..", "deployments", "mainnet.json");
const PROPOSAL_ID = BigInt(process.env.PROPOSAL_ID || "16");
const SUPPORT = Number(process.env.VOTE_SUPPORT || "1");

const PROPOSAL_STATE = [
  "Pending",
  "Active",
  "Cancelled",
  "Defeated",
  "Succeeded",
  "Queued",
  "Expired",
  "Executed",
];

async function main() {
  const { ethers } = hre;
  const [signer] = await ethers.getSigners();
  const network = await ethers.provider.getNetwork();
  if (network.chainId !== 88008n) throw new Error("wrong chain");

  const governance = JSON.parse(fs.readFileSync(MANIFEST, "utf8")).contracts.OmniGovernance;
  const gov = await ethers.getContractAt(
    [
      "function vote(uint256 proposalId, uint8 support)",
      "function state(uint256 proposalId) view returns (uint8)",
      "function getVotingPower(address account) view returns (uint256)",
      "function proposals(uint256) view returns (address proposer,uint8 proposalType,bool executed,bool cancelled,bool queued,bytes32 descriptionHash,uint256 snapshotBlock,uint256 snapshotTotalSupply,uint256 voteStart,uint256 voteEnd,uint256 forVotes,uint256 againstVotes,uint256 abstainVotes,uint256 snapshotQuorumBps)",
    ],
    governance,
    signer,
  );

  const power = await gov.getVotingPower(signer.address);
  const p = await gov.proposals(PROPOSAL_ID);
  console.log("voter:", signer.address, "voting power:", ethers.formatEther(power));
  console.log(
    "window:",
    new Date(Number(p.voteStart) * 1000).toISOString(),
    "→",
    new Date(Number(p.voteEnd) * 1000).toISOString(),
  );
  const before = await gov.state(PROPOSAL_ID);
  console.log("state before:", PROPOSAL_STATE[Number(before)] ?? before.toString());
  if (Number(before) !== 1) {
    throw new Error(
      `proposal ${PROPOSAL_ID} is not Active (state ${before}) — voting has not opened or has closed`,
    );
  }

  const tx = await gov.vote(PROPOSAL_ID, SUPPORT);
  const receipt = await tx.wait();
  console.log("vote tx:", tx.hash, "block", receipt.blockNumber);

  const after = await gov.proposals(PROPOSAL_ID);
  console.log(
    "tally — for:",
    after.forVotes.toString(),
    "against:",
    after.againstVotes.toString(),
    "abstain:",
    after.abstainVotes.toString(),
  );
  console.log(
    "quorum bar:",
    ((Number(after.snapshotQuorumBps) / 10_000) * Number(ethers.formatEther(after.snapshotTotalSupply))).toLocaleString("en-US"),
    "XOM",
  );
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
