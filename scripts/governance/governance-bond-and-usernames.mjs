#!/usr/bin/env node
/**
 * governance-bond-and-usernames.mjs — one script that carries the first
 * incident-remediation proposal from creation to execution, using your own key
 * on your own machine.
 *
 * WHAT THE PROPOSAL DOES (three actions, one transaction to create)
 *   1. OmniBonding.acceptOwnership() — takes ownership of the bonding contract
 *      away from the retired treasury wallet, where it has been pending since
 *      2026-11-18. Until this lands, a compromised key can still call
 *      setXomPrice and pause, and the 25,000,000 XOM inside is unreachable.
 *   2. OmniRegistration.adminUnregister(<old omnirick>) — frees the username
 *      "omnirick". It is bound to a wallet whose key the intruder copied, and
 *      an on-chain name can never be moved, only cleared.
 *   3. OmniRegistration.adminUnregister(<old rickcrites>) — frees "rickcrites"
 *      for the same reason, and removes the intruder's judge registration.
 *
 * None of the three selectors is on the timelock's critical list (checked on
 * chain 2026-11-18), so this is a ROUTINE proposal: 48 hours before voting
 * opens, 7 days of voting, then the 48-hour timelock before execution.
 *
 * HOW TO RUN IT (PowerShell, in a folder that has `ethers` installed)
 *
 *   $env:TREASURY_KEY_FILE = "C:\Users\rickc\keys\treasury.pk"
 *   node .\governance-bond-and-usernames.mjs status     # what is legal right now
 *   node .\governance-bond-and-usernames.mjs propose    # create it (once)
 *   node .\governance-bond-and-usernames.mjs vote       # after 48 h
 *   node .\governance-bond-and-usernames.mjs queue      # after voting ends
 *   node .\governance-bond-and-usernames.mjs execute    # 48 h after queueing
 *
 * `run` does whichever of those steps is legal at the moment you run it and
 * tells you when to run it next, so you can run the same command each day:
 *
 *   node .\governance-bond-and-usernames.mjs run
 *
 * The key is only ever read from the file named by TREASURY_KEY_FILE (or from
 * TREASURY_PK). It is never printed. The script refuses to sign unless the key
 * derives the treasury address exactly, and refuses to propose unless that
 * address holds at least the on-chain proposal threshold.
 */

import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { JsonRpcProvider, Wallet, Contract, keccak256, toUtf8Bytes } from "ethers";

// ─── Constants, verified on chain 2026-11-18 ─────────────────────────────────

const RPC_URL = "https://rpc.omnicoin.net";
const CHAIN_ID = 88008;
const GOVERNOR = "0xa812904860c615FeCE377F17F87670EcA0E0899c";
const TIMELOCK = "0x4f78386cA05E333639151fe0508b21D893CaD222";
const BONDING = "0xdC6F422daF15575D8FDbB633B929C0333212f168";
const REGISTRATION = "0x2B05cbA7740EE483f6151Fa40CF5D48C45A1AD88";

/** Treasury successor: the address holding the capped voting power. */
const TREASURY = "0x5169ce023c76f516710395BDad053d935C054aa2";

/** Wallets the intruder copied on 2026-11-15; their usernames are to be freed. */
const OLD_OMNIRICK = "0x213490a7c0e1681ad4239fbbe829994aeeecd193";
const OLD_RICKCRITES = "0xB475206e51E99a4D4905751a02A12eA5E052B94d";

const DESCRIPTION =
  "Incident remediation 2026-11: accept OmniBonding ownership from the retired treasury wallet, " +
  "and clear the usernames bound to the two wallets whose keys were copied on 2026-11-15.";

const PROPOSAL_TYPE_ROUTINE = 0;
const SUPPORT_FOR = 1;
const GAS_PRICE = 2n;

const STATE_NAMES = ["Pending", "Active", "Defeated", "Succeeded", "Queued", "Executed", "Cancelled", "Expired"];

const GOVERNOR_ABI = [
  "function propose(uint8 proposalType, address[] targets, uint256[] values, bytes[] calldatas, string description) returns (uint256)",
  "function castVote(uint256 proposalId, uint8 support)",
  "function queue(uint256 proposalId)",
  "function execute(uint256 proposalId)",
  "function state(uint256 proposalId) view returns (uint8)",
  "function proposalCount() view returns (uint256)",
  "function proposalThreshold() view returns (uint256)",
  "function votingDelay() view returns (uint256)",
  "function votingPeriod() view returns (uint256)",
  "function voteableSupply() view returns (uint256)",
  "function proposals(uint256 proposalId) view returns (address proposer, uint8 proposalType, bool executed, bool cancelled, bool queued, bytes32 descriptionHash, uint256 snapshotBlock, uint256 snapshotTotalSupply, uint256 voteStart, uint256 voteEnd, uint256 forVotes, uint256 againstVotes, uint256 abstainVotes, uint256 snapshotQuorumBps)",
  "function hasVoted(uint256 proposalId, address account) view returns (bool)",
];
const TIMELOCK_ABI = ["function getMinDelay() view returns (uint256)"];
const ERC20_VOTES_ABI = [
  "function getVotes(address account) view returns (uint256)",
  "function delegates(address account) view returns (address)",
];
const BONDING_ABI = ["function owner() view returns (address)", "function pendingOwner() view returns (address)"];
const REGISTRATION_ABI = ["function resolveUsername(string name) view returns (address)"];

const XOM = "0x1eE61487F08F715055358A1F020A86c9E571ED78";

/**
 * 🛑 The proposal this script manages, recorded by `propose`. It is a file, not
 * "the newest proposal on the chain": the governor already holds 17 proposals,
 * the last of which sits in Succeeded and would be executed by a script that
 * guessed. Every later step also re-checks that the proposal's recorded
 * description hash equals keccak256 of DESCRIPTION, so a wrong or tampered
 * state file cannot make this script act on somebody else's proposal.
 */
const STATE_FILE = process.env.GOV_STATE_FILE ?? join(dirname(fileURLToPath(import.meta.url)), "governance-bond-and-usernames.state.json");

// ─── Helpers ────────────────────────────────────────────────────────────────

/** Print one timestamped line. */
function log(message) {
  console.log(`[${new Date().toISOString()}] ${message}`);
}

/** Load the treasury key from file or environment; never log it. */
function loadSigner(provider) {
  const filePath = process.env.TREASURY_KEY_FILE;
  const inline = process.env.TREASURY_PK;
  if ((filePath === undefined || filePath.trim() === "") && (inline === undefined || inline.trim() === "")) {
    throw new Error("set TREASURY_KEY_FILE to a file holding the treasury private key, or TREASURY_PK to the key itself");
  }
  const raw = filePath !== undefined && filePath.trim() !== "" ? readFileSync(filePath, "utf8").trim() : inline.trim();
  if (!/^(0x)?[0-9a-fA-F]{64}$/.test(raw)) {
    throw new Error("the supplied treasury key is not a bare 64-character hex private key");
  }
  return new Wallet(raw, provider);
}

/**
 * Build the three action arrays once, so propose/status cannot disagree.
 * @returns {{targets: string[], values: string[], calldatas: string[]}} Actions.
 */
function buildActions() {
  const bonding = new Contract(BONDING, ["function acceptOwnership()"]);
  const registration = new Contract(REGISTRATION, ["function adminUnregister(address user)"]);
  return {
    targets: [BONDING, REGISTRATION, REGISTRATION],
    values: ["0", "0", "0"],
    calldatas: [
      bonding.interface.encodeFunctionData("acceptOwnership", []),
      registration.interface.encodeFunctionData("adminUnregister", [OLD_OMNIRICK]),
      registration.interface.encodeFunctionData("adminUnregister", [OLD_RICKCRITES]),
    ],
  };
}

/**
 * Read the proposal id this script created, or 0 when it has not created one.
 * @returns {bigint} Proposal id, or 0n.
 */
function readManagedProposalId() {
  if (!existsSync(STATE_FILE)) return 0n;
  try {
    const parsed = JSON.parse(readFileSync(STATE_FILE, "utf8"));
    return BigInt(parsed.proposalId ?? 0);
  } catch {
    return 0n;
  }
}

/** Print the state of the world and of the managed proposal. */
async function report(governor, timelock, xom, treasury) {
  const [threshold, delay, period, supply] = await Promise.all([
    governor.proposalThreshold(),
    governor.votingDelay(),
    governor.votingPeriod(),
    governor.voteableSupply(),
  ]);
  const [votes, delegate, minDelay, bondingOwner, bondingPending] = await Promise.all([
    xom.getVotes(treasury),
    xom.delegates(treasury),
    timelock.getMinDelay(),
    new Contract(BONDING, BONDING_ABI, governor.runner).owner(),
    new Contract(BONDING, BONDING_ABI, governor.runner).pendingOwner(),
  ]);
  log(`proposal threshold ${threshold.toString()} wei, treasury votes ${votes.toString()} wei`);
  log(`treasury delegates to ${delegate}`);
  log(`voting delay ${Number(delay) / 3600} h, voting period ${Number(period) / 86400} days, timelock ${Number(minDelay) / 3600} h`);
  log(`voteable supply ${supply.toString()} wei; quorum is 4% = ${(supply * 4n / 100n).toString()} wei`);
  log(`OmniBonding owner = ${bondingOwner}, pending owner = ${bondingPending}`);

  const proposalId = readManagedProposalId();
  if (proposalId === 0n) {
    log(`this script has not created a proposal yet (state file ${STATE_FILE} absent)`);
    log(`for context only, the chain holds ${(await governor.proposalCount()).toString()} proposal(s); this script will not touch them`);
    return { proposalId: 0n, stateIndex: -1 };
  }
  const stateIndex = Number(await governor.state(proposalId));
  log(`proposal ${proposalId} state = ${STATE_NAMES[stateIndex]}`);
  // The deployed contract exposes the `proposals` public mapping, not a
  // getProposal getter (checked on chain 2026-11-18: getProposal reverts).
  const proposal = await governor.proposals(proposalId);
  const expectedHash = keccak256(toUtf8Bytes(DESCRIPTION));
  if (String(proposal.descriptionHash).toLowerCase() !== expectedHash.toLowerCase()) {
    throw new Error(
      `proposal ${proposalId} carries description hash ${proposal.descriptionHash}, expected ${expectedHash}. ` +
        "That is not this script's proposal; refusing to act on it.",
    );
  }
  if (Number(proposal.voteStart) > 0) {
    log(`  vote opens ${new Date(Number(proposal.voteStart) * 1000).toISOString()}, closes ${new Date(Number(proposal.voteEnd) * 1000).toISOString()}`);
  }
  log(`  for ${proposal.forVotes.toString()}, against ${proposal.againstVotes.toString()}, abstain ${proposal.abstainVotes.toString()}`);
  log(`  you have voted: ${await governor.hasVoted(proposalId, treasury)}`);
  return { proposalId, stateIndex };
}

// ─── Steps ──────────────────────────────────────────────────────────────────

async function main() {
  const command = process.argv[2] ?? "status";
  const provider = new JsonRpcProvider(RPC_URL, CHAIN_ID, { staticNetwork: true });
  const readOnly = new Contract(GOVERNOR, GOVERNOR_ABI, provider);
  const timelock = new Contract(TIMELOCK, TIMELOCK_ABI, provider);
  const xom = new Contract(XOM, ERC20_VOTES_ABI, provider);

  // status needs no key at all.
  if (command === "status") {
    await report(readOnly, timelock, xom, TREASURY);
    return;
  }

  const signer = await loadSigner(provider);
  const address = await signer.getAddress();
  if (address.toLowerCase() !== TREASURY.toLowerCase()) {
    throw new Error(`the loaded key derives ${address}, expected the treasury ${TREASURY}. Nothing sent.`);
  }
  const governor = new Contract(GOVERNOR, GOVERNOR_ABI, signer);
  log(`signing as treasury ${address}`);

  const current = await report(governor, timelock, xom, address);

  /** Create the proposal if none exists. */
  const proposeStep = async () => {
    const threshold = await governor.proposalThreshold();
    const votes = await xom.getVotes(address);
    if (votes < threshold) {
      throw new Error(`treasury has ${votes.toString()} votes, threshold is ${threshold.toString()}; delegate votes first`);
    }
    const actions = buildActions();
    log(`proposing ${actions.targets.length} actions`);
    for (const [index, target] of actions.targets.entries()) {
      log(`  ${index + 1}. ${target} calldata ${actions.calldatas[index]}`);
    }
    const tx = await governor.propose(
      PROPOSAL_TYPE_ROUTINE,
      actions.targets,
      actions.values,
      actions.calldatas,
      DESCRIPTION,
      { gasLimit: 2_000_000n, gasPrice: GAS_PRICE },
    );
    log(`propose sent ${tx.hash}`);
    const receipt = await tx.wait();
    if (receipt === null || receipt.status !== 1) throw new Error(`propose reverted in ${tx.hash}`);
    const proposalId = await governor.proposalCount();
    writeFileSync(
      STATE_FILE,
      JSON.stringify({ proposalId: proposalId.toString(), txHash: tx.hash, createdAt: new Date().toISOString(), description: DESCRIPTION }, null, 2),
    );
    log(`proposal ${proposalId} created in block ${receipt.blockNumber}; recorded in ${STATE_FILE}`);
    const proposal = await governor.proposals(proposalId);
    log(`voting opens ${new Date(Number(proposal.voteStart) * 1000).toISOString()} — run "vote" after that`);
  };

  /** Vote in favour once voting is open. */
  const voteStep = async (proposalId) => {
    if (await governor.hasVoted(proposalId, address)) {
      log("already voted on this proposal");
      return;
    }
    const tx = await governor.castVote(proposalId, SUPPORT_FOR, { gasLimit: 500_000n, gasPrice: GAS_PRICE });
    log(`vote sent ${tx.hash}`);
    const receipt = await tx.wait();
    if (receipt === null || receipt.status !== 1) throw new Error(`vote reverted in ${tx.hash}`);
    log(`voted in favour in block ${receipt.blockNumber}`);
  };

  /** Queue it in the timelock once it has succeeded. */
  const queueStep = async (proposalId) => {
    const tx = await governor.queue(proposalId, { gasLimit: 1_000_000n, gasPrice: GAS_PRICE });
    log(`queue sent ${tx.hash}`);
    const receipt = await tx.wait();
    if (receipt === null || receipt.status !== 1) throw new Error(`queue reverted in ${tx.hash}`);
    log(`queued in block ${receipt.blockNumber}; executable after the timelock delay`);
  };

  /** Execute the queued actions. */
  const executeStep = async (proposalId) => {
    const tx = await governor.execute(proposalId, { gasLimit: 3_000_000n, gasPrice: GAS_PRICE });
    log(`execute sent ${tx.hash}`);
    const receipt = await tx.wait();
    if (receipt === null || receipt.status !== 1) throw new Error(`execute reverted in ${tx.hash}`);
    log(`executed in block ${receipt.blockNumber}`);
    const bonding = new Contract(BONDING, BONDING_ABI, provider);
    const registration = new Contract(REGISTRATION, REGISTRATION_ABI, provider);
    log(`OmniBonding owner is now ${await bonding.owner()} (expected the timelock ${TIMELOCK})`);
    log(`"omnirick" now resolves to ${await registration.resolveUsername("omnirick")}`);
    log(`"rickcrites" now resolves to ${await registration.resolveUsername("rickcrites")}`);
  };

  if (command === "propose") return proposeStep();
  if (command === "vote") return voteStep(current.proposalId);
  if (command === "queue") return queueStep(current.proposalId);
  if (command === "execute") return executeStep(current.proposalId);

  if (command !== "run") {
    throw new Error(`unknown command "${command}". Use status, propose, vote, queue, execute or run.`);
  }

  // `run`: do whatever is legal now, and say when to come back.
  const { proposalId, stateIndex } = current;
  if (proposalId === 0n) return proposeStep();
  if (stateIndex === 0) {
    log("state Pending — voting has not opened yet; run this again after the vote-start time above");
    return;
  }
  if (stateIndex === 1) return voteStep(proposalId);
  if (stateIndex === 3) return queueStep(proposalId);
  if (stateIndex === 4) return executeStep(proposalId);
  log(`state ${STATE_NAMES[stateIndex]} needs no action from this script`);
}

main().catch((error) => {
  log(`STOPPED: ${error instanceof Error ? error.message : String(error)}`);
  process.exit(1);
});
