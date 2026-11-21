#!/usr/bin/env node
/**
 * Governance batch: make the replacement guardian able to pause, and shorten the
 * delay on the primary timelock from 48 hours to 12.
 *
 * Actions, in order:
 *   1        primary timelock      updateDelay(43200)
 *   2-4      treasury V2, treasury V1, POL manager   grant GUARDIAN_ROLE -> new guardian
 *   5        reward manager        grant PAUSER_ROLE -> new guardian
 *   6-8      the same three        revoke GUARDIAN_ROLE from the OLD guardian
 *   9-12     new guardian          registerPausable(target) for all four
 *
 * The order is deliberate: the new grant lands before the old one is revoked, so
 * there is never a window with no stop, and registration happens after the grants
 * so the first pause attempt cannot fail on a role that has not moved.
 *
 * Commands: status (default) | simulate | propose | vote | queue | execute
 * "propose" and "vote" need the recovery treasury key, which is cold. This script
 * never generates or prints a secret.
 */
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { ethers } from "ethers";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const RPC_URL = process.env.OMNICOIN_RPC_URL || "https://rpc.omnicoin.net";
const CHAIN_ID = 88008;
const GAS_PRICE = BigInt(process.env.OB_GAS_PRICE_WEI || "2");

const GOVERNOR = "0xa812904860c615FeCE377F17F87670EcA0E0899c";
const TIMELOCK = "0x4f78386cA05E333639151fe0508b21D893CaD222";
const TREASURY = "0x5169ce023c76f516710395BDad053d935C054aa2";
const OLD_GUARDIAN = "0x60752E5762C4eC606730bad3806a1139825BC2e6";

const TREASURIES = {
  "treasury V2": "0x17624a2DCCc71E4c35DA97d633025fE2badD3477",
  "treasury V1": "0xc17A75266474aE62B9449A029A1Da7DC0D5bdA23",
  "POL manager": "0xBdc9687DF650B8eF5Bc7a9d9a9ABE5A18a6DbAF8",
};
const REWARD_MANAGER = "0x3138855f8EdAA2D41f1a2Ae5Cc0C0052b61e9de3";

const NEW_DELAY_SECONDS = 43_200;
const PROPOSAL_TYPE_ROUTINE = 0;
const SUPPORT_FOR = 1;

const DESCRIPTION =
  "PAUSE-1: make the replacement EmergencyGuardian able to pause, retire the old " +
  "guardian's pause roles, register the four pausable targets, and reduce the " +
  "primary timelock delay from 48 hours to 12 hours. No value moves.";

const STATE_FILE = path.join(__dirname, "..", "..", "deployments", "emergency-guardian.json");

const GOVERNOR_ABI = [
  "function state(uint256) view returns (uint8)",
  "function proposalCount() view returns (uint256)",
  "function proposals(uint256) view returns (address proposer, uint8 proposalType, bool executed, bool cancelled, bool queued, bytes32 descriptionHash, uint256 snapshotBlock, uint256 snapshotTotalSupply, uint256 voteStart, uint256 voteEnd, uint256 forVotes, uint256 againstVotes, uint256 abstainVotes, uint256 snapshotQuorumBps)",
  "function getActions(uint256) view returns (address[] targets, uint256[] values, bytes[] calldatas)",
  "function propose(uint8 proposalType, address[] targets, uint256[] values, bytes[] calldatas, string description) returns (uint256)",
  "function castVote(uint256 proposalId, uint8 support) returns (uint256)",
  "function queue(uint256 proposalId) returns (uint256)",
  "function execute(uint256 proposalId) payable returns (uint256)",
  "function hasVoted(uint256,address) view returns (bool)",
  "function proposalThreshold() view returns (uint256)",
];
const TIMELOCK_ABI = [
  "function getMinDelay() view returns (uint256)",
  "function hashOperationBatch(address[],uint256[],bytes[],bytes32,bytes32) view returns (bytes32)",
  "function isOperationPending(bytes32) view returns (bool)",
  "function isOperationReady(bytes32) view returns (bool)",
  "function isOperationDone(bytes32) view returns (bool)",
];
const ROLE_ABI = [
  "function hasRole(bytes32,address) view returns (bool)",
  "function grantRole(bytes32,address)",
  "function revokeRole(bytes32,address)",
  "function registerPausable(address)",
  "function updateDelay(uint256)",
];

const GUARDIAN_ROLE = ethers.keccak256(ethers.toUtf8Bytes("GUARDIAN_ROLE"));
const PAUSER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("PAUSER_ROLE"));

function log(message) {
  console.log(`[pause-batch] ${message}`);
}

function loadGuardian() {
  const override = process.argv.indexOf("--guardian");
  if (override !== -1) {
    const address = process.argv[override + 1];
    if (!ethers.isAddress(address)) throw new Error("--guardian needs an address");
    return { guardian: ethers.getAddress(address) };
  }
  if (!fs.existsSync(STATE_FILE)) {
    throw new Error(`no replacement guardian recorded at ${STATE_FILE}; run deploy-emergency-guardian.cjs --send first`);
  }
  const state = JSON.parse(fs.readFileSync(STATE_FILE, "utf8"));
  if (!ethers.isAddress(state.guardian)) throw new Error(`bad guardian address in ${STATE_FILE}`);
  return state;
}

function buildActions(guardian) {
  const targets = [];
  const values = [];
  const calldatas = [];
  const labels = [];
  const roles = new ethers.Interface(ROLE_ABI);

  const push = (label, target, data) => {
    targets.push(target);
    values.push(0n);
    calldatas.push(data);
    labels.push(label);
  };

  push("timelock.updateDelay(12h)", TIMELOCK, roles.encodeFunctionData("updateDelay", [NEW_DELAY_SECONDS]));

  for (const [name, address] of Object.entries(TREASURIES)) {
    push(`${name}: grant guardian role to new guardian`, address, roles.encodeFunctionData("grantRole", [GUARDIAN_ROLE, guardian]));
  }
  push("reward manager: grant pauser role to new guardian", REWARD_MANAGER, roles.encodeFunctionData("grantRole", [PAUSER_ROLE, guardian]));

  for (const [name, address] of Object.entries(TREASURIES)) {
    push(`${name}: revoke guardian role from old guardian`, address, roles.encodeFunctionData("revokeRole", [GUARDIAN_ROLE, OLD_GUARDIAN]));
  }

  for (const [name, address] of Object.entries(TREASURIES)) {
    push(`new guardian: registerPausable(${name})`, guardian, roles.encodeFunctionData("registerPausable", [address]));
  }
  push("new guardian: registerPausable(reward manager)", guardian, roles.encodeFunctionData("registerPausable", [REWARD_MANAGER]));

  return { targets, values, calldatas, labels };
}

async function preflight(provider, guardian, actions) {
  const roles = new ethers.Interface(ROLE_ABI);
  log(`replacement guardian ${guardian}`);
  log(`old guardian ${OLD_GUARDIAN}`);

  for (const [name, address] of Object.entries(TREASURIES)) {
    const c = new ethers.Contract(address, ROLE_ABI, provider);
    const oldHolds = await c.hasRole(GUARDIAN_ROLE, OLD_GUARDIAN);
    const newHolds = await c.hasRole(GUARDIAN_ROLE, guardian);
    log(`  ${name}: old holds ${oldHolds}, new holds ${newHolds}`);
  }
  const reward = new ethers.Contract(REWARD_MANAGER, ROLE_ABI, provider);
  log(`  reward manager: new holds pauser ${await reward.hasRole(PAUSER_ROLE, guardian)}`);

  const guardianExists = (await provider.getCode(guardian)) !== "0x";
  if (guardianExists) {
    const guardianContract = new ethers.Contract(guardian, ["function pausableCount() view returns (uint256)", "function guardianCount() view returns (uint256)"], provider);
    log(`  new guardian: ${await guardianContract.guardianCount()} guardians, ${await guardianContract.pausableCount()} pausable targets`);
  } else {
    log("  new guardian has no code yet: the four registerPausable actions cannot be simulated until it is deployed");
  }

  // Simulate every action as the timelock would execute it.
  let simulated = 0;
  for (const [index, target] of actions.targets.entries()) {
    if (!guardianExists && target.toLowerCase() === guardian.toLowerCase()) {
      log(`  skip  ${index + 1}/${actions.targets.length} (guardian not deployed) — ${actions.labels[index]}`);
      continue;
    }
    await provider.call({ from: TIMELOCK, to: target, data: actions.calldatas[index], value: 0 });
    simulated += 1;
    log(`  simulate ${index + 1}/${actions.targets.length} ok — ${actions.labels[index]}`);
  }
  log(`${simulated} of ${actions.targets.length} actions simulate under the timelock`);
  void roles;
}

async function loadSigner(provider) {
  const keyFile = process.env.GOV_KEY_FILE || path.join(os.homedir(), ".avalanche-cli", "key", "iceberg-omnibazaar.pk");
  const key = fs.readFileSync(keyFile.replace(/^~/, os.homedir()), "utf8").trim();
  const wallet = new ethers.Wallet(key.startsWith("0x") ? key : `0x${key}`, provider);
  const address = await wallet.getAddress();
  if (address.toLowerCase() !== TREASURY.toLowerCase()) {
    throw new Error(`the loaded key derives ${address}, expected the recovery treasury. Nothing sent.`);
  }
  return wallet;
}

async function main() {
  const command = process.argv[2] || "status";

  if (command === "build") {
    const guardianOverride = process.argv.indexOf("--guardian") !== -1 ? process.argv[process.argv.indexOf("--guardian") + 1] : null;
    const guardianAddress = guardianOverride ? ethers.getAddress(guardianOverride) : loadGuardian().guardian;
    const built = buildActions(guardianAddress);
    log(`${built.targets.length} actions for guardian ${guardianAddress}:`);
    built.labels.forEach((label, index) => log(`  ${index + 1}. ${label}\n     to ${built.targets[index]}\n     data ${built.calldatas[index].slice(0, 10)}`));
    return;
  }
  const provider = new ethers.JsonRpcProvider(RPC_URL, CHAIN_ID, { staticNetwork: true });
  const state = loadGuardian();
  const actions = buildActions(state.guardian);

  const governor = new ethers.Contract(GOVERNOR, GOVERNOR_ABI, provider);
  const timelock = new ethers.Contract(TIMELOCK, TIMELOCK_ABI, provider);
  const count = Number(await governor.proposalCount());

  log(`chain ${CHAIN_ID}, block ${await provider.getBlockNumber()}, proposalCount ${count}`);
  log(`timelock min delay ${await timelock.getMinDelay()} seconds`);

  if (command === "status") {
    if (count > 0) {
      const latest = await governor.proposals(count);
      log(`proposal ${count}: state ${await governor.state(count)}, vote ${new Date(Number(latest.voteStart) * 1000).toISOString()} -> ${new Date(Number(latest.voteEnd) * 1000).toISOString()}`);
    }
    log(`${actions.targets.length} actions prepared for the next proposal:`);
    actions.labels.forEach((label, index) => log(`  ${index + 1}. ${label}`));
    return;
  }

  await preflight(provider, state.guardian, actions);

  if (command === "simulate") {
    log("SIMULATION ONLY — nothing sent");
    return;
  }

  const signer = await loadSigner(provider);
  log(`signing as recovery treasury ${await signer.getAddress()}`);
  const asSigner = new ethers.Contract(GOVERNOR, GOVERNOR_ABI, signer);

  if (command === "propose") {
    const votes = await asSigner.proposalThreshold();
    log(`proposal threshold ${votes}`);
    const tx = await asSigner.propose(PROPOSAL_TYPE_ROUTINE, actions.targets, actions.values, actions.calldatas, DESCRIPTION, {
      gasLimit: 3_000_000n,
      gasPrice: GAS_PRICE,
    });
    log(`propose sent ${tx.hash}`);
    const receipt = await tx.wait();
    if (!receipt || receipt.status !== 1) throw new Error(`propose reverted in ${tx.hash}`);
    const id = await asSigner.proposalCount();
    log(`proposal ${id} created in block ${receipt.blockNumber}`);
    const readBack = await asSigner.getActions(id);
    if (readBack.targets.length !== actions.targets.length) throw new Error("action count mismatch after propose");
    log(`actions read back: ${readBack.targets.length}, first target ${readBack.targets[0]}`);
    return;
  }

  const id = BigInt(process.env.PROPOSAL_ID || count);
  log(`using proposal ${id}`);

  if (command === "vote") {
    if (await asSigner.hasVoted(id, await signer.getAddress())) throw new Error("already voted");
    const tx = await asSigner.castVote(id, SUPPORT_FOR, { gasLimit: 500_000n, gasPrice: GAS_PRICE });
    log(`vote sent ${tx.hash}`);
    await tx.wait();
    log("voted in favour");
    return;
  }

  if (command === "queue" || command === "execute") {
    const tx = await asSigner[command](id, { gasLimit: 5_000_000n, gasPrice: GAS_PRICE });
    log(`${command} sent ${tx.hash}`);
    const receipt = await tx.wait();
    if (!receipt || receipt.status !== 1) throw new Error(`${command} reverted in ${tx.hash}`);
    log(`${command} landed in block ${receipt.blockNumber}`);
    if (command === "execute") {
      const roles = new ethers.Interface(ROLE_ABI);
      void roles;
      const guardian = new ethers.Contract(state.guardian, ["function pausableCount() view returns (uint256)"], provider);
      log(`new guardian pausableCount ${await guardian.pausableCount()}`);
      log(`timelock min delay now ${await timelock.getMinDelay()} seconds`);
    }
    return;
  }

  throw new Error(`unknown command ${command}`);
}

main().catch((error) => {
  console.error(`[pause-batch] FAILED: ${error.message}`);
  process.exit(1);
});
