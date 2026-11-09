/**
 * Propose authorising the new L1 EscrowV2 as a first-sale recorder.
 *
 * ONE action, ROUTINE (48-hour timelock):
 *
 *   OmniRegistration.setAuthorizedRecorder(EscrowV2, true)
 *
 * Why it needs governance: `DEFAULT_ADMIN_ROLE` on OmniRegistration is held by
 * OmniTimelockController, not the deployer (verified on chain 2026-11-09), and
 * `setAuthorizedRecorder` is not a critical selector, so this is a ROUTINE
 * proposal. Without it `markFirstSaleCompleted` reverts from the escrow and the
 * first-sale bonus is simply never recorded — settlement is unaffected because
 * `EscrowFeeRouter.recordFirstSale` swallows the failure.
 *
 * Usage:
 *   MAINNET_DEPLOYER_PRIVATE_KEY=$(cat ~/.avalanche-cli/key/iceberg-omnibazaar.pk) \
 *     npx hardhat run scripts/governance/propose-escrowv2-recorder.cjs --network mainnet
 *   DRY_RUN=1   print the calldata and the state, broadcast nothing.
 *
 * The proposer must clear `proposalThreshold` (1.7M XOM at the prior block);
 * the deployer holds no voting power, so the governance-weight account proposes.
 */
const fs = require("fs");
const path = require("path");
const hre = require("hardhat");

const DRY_RUN = process.env.DRY_RUN === "1";
const MANIFEST = path.join(__dirname, "..", "..", "deployments", "mainnet.json");

/** ProposalType.Routine — the timelock's ROUTINE delay is 48 hours. */
const PROPOSAL_TYPE_ROUTINE = 0;

/** ProposalState enum order, as the contract declares it. */
const STATE = [
  "Pending",
  "Active",
  "Defeated",
  "Succeeded",
  "Queued",
  "Executed",
  "Cancelled",
  "Expired",
];

async function main() {
  const { ethers } = hre;
  const [signer] = await ethers.getSigners();
  const network = await ethers.provider.getNetwork();
  if (network.chainId !== 88008n) throw new Error("wrong chain");

  const c = JSON.parse(fs.readFileSync(MANIFEST, "utf8")).contracts;
  const registry = c.OmniRegistration;
  const escrow = c.EscrowV2;
  const governance = c.OmniGovernance;
  for (const [label, value] of Object.entries({ registry, escrow, governance })) {
    if (!value || !ethers.isAddress(value)) throw new Error(`manifest missing ${label}`);
  }

  const registryIface = new ethers.Interface([
    "function setAuthorizedRecorder(address recorder, bool authorized)",
    "function authorizedRecorders(address) view returns (bool)",
  ]);
  const registryContract = new ethers.Contract(registry, registryIface, ethers.provider);
  const already = await registryContract.authorizedRecorders(escrow);
  if (already) {
    console.log("escrow", escrow, "is ALREADY an authorized recorder — nothing to propose");
    return;
  }

  const calldata = registryIface.encodeFunctionData("setAuthorizedRecorder", [escrow, true]);
  const targets = [registry];
  const values = [0n];
  const calldatas = [calldata];
  const description =
    `Authorise EscrowV2 ${escrow} as a first-sale recorder on OmniRegistration ` +
    "(setAuthorizedRecorder). The L1 escrow moved to this audited build on " +
    "2026-11-09; without the role the first-sale bonus is never recorded.";

  console.log("proposer:", signer.address);
  console.log("registry:", registry);
  console.log("escrow  :", escrow);
  console.log("action  :", calldata);
  console.log("type    : ROUTINE (48h timelock)");

  if (DRY_RUN) {
    console.log("\nDRY_RUN=1 — nothing submitted");
    return;
  }

  const gov = await ethers.getContractAt(
    [
      "function propose(uint8 proposalType,address[] targets,uint256[] values,bytes[] calldatas,string description) returns (uint256)",
      "function state(uint256 proposalId) view returns (uint8)",
      "function proposalCount() view returns (uint256)",
      "function proposals(uint256) view returns (address proposer,uint8 proposalType,bool executed,bool cancelled,bool queued,bytes32 descriptionHash,uint256 snapshotBlock,uint256 snapshotTotalSupply,uint256 voteStart,uint256 voteEnd,uint256 forVotes,uint256 againstVotes,uint256 abstainVotes,uint256 snapshotQuorumBps)",
    ],
    governance,
    signer,
  );

  const tx = await gov.propose(PROPOSAL_TYPE_ROUTINE, targets, values, calldatas, description);
  const receipt = await tx.wait();
  const id = await gov.proposalCount();
  const p = await gov.proposals(id);
  console.log("propose tx:", tx.hash, "block", receipt.blockNumber);
  console.log("proposal id:", id.toString());
  console.log("state:", STATE[Number(await gov.state(id))]);
  console.log(
    "voting opens:",
    new Date(Number(p.voteStart) * 1000).toISOString(),
    "closes:",
    new Date(Number(p.voteEnd) * 1000).toISOString(),
  );
}

main().catch((err) => {
  console.error(err.shortMessage || err.message || err);
  process.exitCode = 1;
});
