#!/usr/bin/env node
/**
 * registry-repair.mjs — restore the release registry's ability to attest a
 * release, and stop it depending on a single key.
 *
 * THE PROBLEM (measured 2026-11-25/26)
 *   UpdateRegistry 0xd8E2a242… has DEFAULT_ADMIN = the primary timelock only
 *   (the deployer was renounced) and signers = [retired deployer], threshold 1.
 *   publishRelease needs BOTH the admin role and `threshold` signatures from the
 *   current signer set, and updateSignerSet needs signatures from that same set.
 *   So the contract can neither publish a release nor rotate its signers. Every
 *   client build since is unattestable, which freezes the download page.
 *
 * THE PROPOSAL (one CRITICAL proposal, two actions, executed by the timelock)
 *   1. UpdateRegistry.grantRole(DEFAULT_ADMIN_ROLE, successor)
 *      — so future repairs never need a governance round trip.
 *   2. UpdateRegistry.updateSignerSet(<new signers>, <threshold>, <nonce>,
 *      [<retired deployer's signature>])
 *      — the timelock is already an admin, and this is the signature the
 *        contract demands from its CURRENT signer set. After this, the retired
 *        key has no power in the registry at all.
 *
 * grantRole is a critical selector, so the whole batch must be CRITICAL:
 * 48 h before voting opens, 7 days of voting, then a 7-day timelock.
 *
 * USAGE (Windows PowerShell, in a folder that has ethers installed — the
 * founder's C:\Users\rickc\ob-keys):
 *
 *   node .\registry-repair.mjs status
 *   node .\registry-repair.mjs prepare --key-dir .        # sign, print, send nothing
 *   node .\registry-repair.mjs propose --key-dir .        # create it (once)
 *   node .\registry-repair.mjs vote --key-dir .           # after voting opens
 *   node .\registry-repair.mjs run --key-dir .            # do whatever is legal now
 *
 * Keys are selected by DERIVED ADDRESS from --key-dir: the treasury for propose
 * and vote, the retired deployer only to sign the signer-set message. Neither is
 * ever printed. Overrides: --signers 0x..,0x.. --threshold 2.
 */

import { readFileSync, writeFileSync, existsSync, readdirSync, statSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { JsonRpcProvider, Wallet, Contract, keccak256, toUtf8Bytes, getBytes, verifyMessage } from "ethers";

// ─── Constants, verified on chain 2026-11-26 ────────────────────────────────

const RPC_URL = process.env.OB_L1_RPC ?? "https://rpc.omnicoin.net";
const CHAIN_ID = 88008;
const GOVERNOR = "0xa812904860c615FeCE377F17F87670EcA0E0899c";
const TIMELOCK = "0x4f78386cA05E333639151fe0508b21D893CaD222";
const REGISTRY = "0xd8E2a242dd344BE4A61c3DdD4332717766EB648B";
const TREASURY = "0x5169ce023c76f516710395bdad053d935c054aa2";
const SUCCESSOR = "0x68d002Bb315E8310c1344EeA707f9C36DdC33e1e";

/** Default new signer set: the successor plus two keys the founder holds on his
 *  own machine. Nothing here is a server key. */
const DEFAULT_SIGNERS = [
  SUCCESSOR,
  "0xEFc0015487b4fF046981bB427553496d14D0873A",
  "0x062A30E755cC3633EeCd3cDa505725aa50ef222C",
];
const DEFAULT_THRESHOLD = 2;
const RETIRED_DEPLOYER = "0x021868f2E3D49C059EF52B539AAa933B437e0321";
const DEFAULT_ADMIN = "0x" + "00".repeat(32);

const DESCRIPTION =
  "Registry repair 2026-11-26: grant UpdateRegistry DEFAULT_ADMIN to the successor, then rotate the " +
  "ODDAO signer set off the retired deployer with that signer's own signature, restoring release " +
  "attestation and removing the single-key dependency.";

const PROPOSAL_TYPE_CRITICAL = 1;
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
const REGISTRY_ABI = [
  "function hasRole(bytes32 role, address account) view returns (bool)",
  "function getSigners() view returns (address[])",
  "function signerThreshold() view returns (uint256)",
  "function getOperationNonce() view returns (uint256)",
  "function computeSignerUpdateHash(address[] newSigners, uint256 newThreshold, uint256 nonce) view returns (bytes32)",
  "function grantRole(bytes32 role, address account)",
  "function updateSignerSet(address[] newSigners, uint256 newThreshold, uint256 nonce, bytes[] signatures)",
  "function getLatestVersion(string component) view returns (string)",
];
const XOM_ABI = ["function getVotes(address account) view returns (uint256)", "function delegates(address account) view returns (address)"];
const XOM = "0x1eE61487F08F715055358A1F020A86c9E571ED78";

const STATE_FILE = process.env.GOV_STATE_FILE ?? join(dirname(fileURLToPath(import.meta.url)), "registry-repair.state.json");

// ─── Helpers ────────────────────────────────────────────────────────────────

const log = (m) => console.log(`[${new Date().toISOString()}] ${m}`);
const same = (a, b) => a.toLowerCase() === b.toLowerCase();
const arg = (n) => { const i = process.argv.indexOf(`--${n}`); return i < 0 ? undefined : process.argv[i + 1]; };

function newSigners() {
  const raw = arg("signers");
  if (!raw) return DEFAULT_SIGNERS;
  const list = raw.split(",").map((s) => s.trim()).filter(Boolean);
  if (!list.every((a) => /^0x[0-9a-fA-F]{40}$/.test(a))) throw new Error("--signers must be comma-separated 0x addresses");
  return list;
}
function newThreshold(signers) {
  const raw = arg("threshold");
  const t = raw === undefined ? DEFAULT_THRESHOLD : Number(raw);
  if (!Number.isInteger(t) || t < 1 || t > signers.length) throw new Error(`threshold must be 1..${signers.length}`);
  return t;
}

/** Every key-looking file under --key-dir, with its derived address. */
function scanKeys(dir) {
  const out = [];
  for (const entry of readdirSync(dir)) {
    const path = join(dir, entry);
    let st;
    try { st = statSync(path); } catch { continue; }
    if (!st.isFile() || st.size > 4096) continue;
    let raw;
    try { raw = readFileSync(path, "utf8"); } catch { continue; }
    let s = raw.trim();
    if (s.startsWith('"') && s.endsWith('"')) s = s.slice(1, -1).trim();
    if (!/^(0x)?[0-9a-fA-F]{64}$/.test(s)) continue;
    if (!s.startsWith("0x")) s = "0x" + s;
    out.push({ path, key: s, address: new Wallet(s).address });
  }
  return out;
}

function keyFor(address, label) {
  const dir = arg("key-dir");
  const file = arg("key-file");
  let entries;
  if (file) {
    let raw = readFileSync(file, "utf8").trim();
    if (raw.startsWith('"') && raw.endsWith('"')) raw = raw.slice(1, -1).trim();
    if (!raw.startsWith("0x")) raw = "0x" + raw;
    entries = [{ path: file, key: raw, address: new Wallet(raw).address }];
  } else if (dir) {
    entries = scanKeys(dir);
  } else {
    throw new Error("pass --key-dir <folder> (your key folder) or --key-file <path>");
  }
  const match = entries.find((e) => same(e.address, address));
  if (!match) {
    throw new Error(`no key here derives ${address}${label ? ` (${label})` : ""}; found:\n` +
      (entries.map((e) => `   ${e.address}  ${e.path}`).join("\n") || " none"));
  }
  log(`key ${match.address} from ${match.path}`);
  return match;
}

// ─── Reads ──────────────────────────────────────────────────────────────────

async function readState(provider) {
  const registry = new Contract(REGISTRY, REGISTRY_ABI, provider);
  const governor = new Contract(GOVERNOR, GOVERNOR_ABI, provider);
  const xom = new Contract(XOM, XOM_ABI, provider);
  const signers = newSigners();
  const threshold = newThreshold(signers);
  const [currentSigners, currentThreshold, nonce, adminTl, adminSucc, adminDep] = await Promise.all([
    registry.getSigners(),
    registry.signerThreshold(),
    registry.getOperationNonce(),
    registry.hasRole(DEFAULT_ADMIN, TIMELOCK),
    registry.hasRole(DEFAULT_ADMIN, SUCCESSOR),
    registry.hasRole(DEFAULT_ADMIN, RETIRED_DEPLOYER),
  ]);
  const messageHash = await registry.computeSignerUpdateHash(signers, threshold, nonce);
  const [votes, delegate, propThreshold, delay, period, supply, count] = await Promise.all([
    xom.getVotes(TREASURY),
    xom.delegates(TREASURY),
    governor.proposalThreshold(),
    governor.votingDelay(),
    governor.votingPeriod(),
    governor.voteableSupply(),
    governor.proposalCount(),
  ]);
  const versions = {};
  for (const c of ["wallet", "mobile", "webapp"]) versions[c] = await registry.getLatestVersion(c).catch(() => "?");
  return {
    signers, threshold, currentSigners, currentThreshold, nonce, messageHash,
    adminTl, adminSucc, adminDep, votes, delegate, propThreshold, delay, period, supply, count, versions,
  };
}

function report(s) {
  log(`registry ${REGISTRY}`);
  log(`  DEFAULT_ADMIN  timelock=${s.adminTl} successor=${s.adminSucc} retiredDeployer=${s.adminDep}`);
  log(`  current signers [${s.currentSigners.join(", ")}] threshold ${s.currentThreshold}`);
  log(`  operation nonce ${s.nonce}`);
  log(`  proposed new signers [${s.signers.join(", ")}] threshold ${s.threshold}`);
  log(`  message hash to sign ${s.messageHash}`);
  log(`  attested versions wallet=${s.versions.wallet} mobile=${s.versions.mobile} webapp=${s.versions.webapp}`);
  log(`governor: proposals so far ${s.count}, threshold ${s.propThreshold} wei, treasury votes ${s.votes} (delegates to ${s.delegate})`);
  log(`  voting delay ${Number(s.delay) / 3600} h, voting period ${Number(s.period) / 86400} d, quorum ${(s.supply * 4n / 100n)} wei`);
}

// ─── Signing ────────────────────────────────────────────────────────────────

/** Sign the signer-set message with the retired deployer key and prove recovery. */
async function deployerSignature(provider, s) {
  const entry = keyFor(RETIRED_DEPLOYER, "the retired deployer — must sign the signer-set message");
  const wallet = new Wallet(entry.key, provider);
  const signature = await wallet.signMessage(getBytes(s.messageHash));
  const recovered = verifyMessage(getBytes(s.messageHash), signature);
  if (!same(recovered, RETIRED_DEPLOYER)) {
    throw new Error(`signature recovers ${recovered}, expected ${RETIRED_DEPLOYER}; refusing to continue`);
  }
  log(`  signature recovers ${recovered} — correct`);
  return signature;
}

function buildActions(s, signature) {
  const registry = new Contract(REGISTRY, REGISTRY_ABI);
  return {
    targets: [REGISTRY, REGISTRY],
    values: ["0", "0"],
    calldatas: [
      registry.interface.encodeFunctionData("grantRole", [DEFAULT_ADMIN, SUCCESSOR]),
      registry.interface.encodeFunctionData("updateSignerSet", [s.signers, s.threshold, s.nonce, [signature]]),
    ],
  };
}

// ─── Steps ──────────────────────────────────────────────────────────────────

function managedProposalId() {
  if (!existsSync(STATE_FILE)) return 0n;
  try { return BigInt(JSON.parse(readFileSync(STATE_FILE, "utf8")).proposalId ?? 0); } catch { return 0n; }
}

async function statusStep(provider) {
  const s = await readState(provider);
  report(s);
  const id = managedProposalId();
  if (id === 0n) { log("this script has not created a proposal yet"); return; }
  const governor = new Contract(GOVERNOR, GOVERNOR_ABI, provider);
  const proposal = await governor.proposals(id);
  const expected = keccak256(toUtf8Bytes(DESCRIPTION));
  if (!same(proposal.descriptionHash, expected)) throw new Error(`proposal ${id} is not this script's — description hash mismatch`);
  const idx = Number(await governor.state(id));
  log(`proposal ${id} state ${STATE_NAMES[idx]}`);
  if (Number(proposal.voteStart) > 0) {
    log(`  voting ${new Date(Number(proposal.voteStart) * 1000).toISOString()} → ${new Date(Number(proposal.voteEnd) * 1000).toISOString()}`);
  }
  log(`  for ${proposal.forVotes}, against ${proposal.againstVotes}; you voted: ${await governor.hasVoted(id, TREASURY)}`);
}

async function prepareStep(provider) {
  const s = await readState(provider);
  report(s);
  log("signing the signer-set message with the deployer key (nothing is broadcast)");
  const signature = await deployerSignature(provider, s);
  const actions = buildActions(s, signature);
  log(`  action 1 → ${actions.targets[0]} ${actions.calldatas[0]}`);
  log(`  action 2 → ${actions.targets[1]} ${actions.calldatas[1]}`);
  log("prepare only: run `propose --key-dir .` to create the proposal");
}

async function proposeStep(provider) {
  const s = await readState(provider);
  report(s);
  const treasury = keyFor(TREASURY, "the treasury, which holds the voting power");
  if (s.votes < s.propThreshold) throw new Error(`treasury has ${s.votes} votes, threshold ${s.propThreshold} — delegate first`);
  const signature = await deployerSignature(provider, s);
  const actions = buildActions(s, signature);
  const signer = new Wallet(treasury.key, provider);
  const governor = new Contract(GOVERNOR, GOVERNOR_ABI, signer);
  // Simulate first: a reverting propose must not cost a transaction.
  await governor.propose.staticCall(PROPOSAL_TYPE_CRITICAL, actions.targets, actions.values, actions.calldatas, DESCRIPTION);
  log("  simulation of propose: OK");
  const tx = await governor.propose(PROPOSAL_TYPE_CRITICAL, actions.targets, actions.values, actions.calldatas, DESCRIPTION,
    { gasLimit: 3_000_000n, gasPrice: GAS_PRICE });
  log(`propose sent ${tx.hash}`);
  const receipt = await tx.wait();
  if (!receipt || receipt.status !== 1) throw new Error(`propose reverted in ${tx.hash}`);
  const id = await governor.proposalCount();
  writeFileSync(STATE_FILE, JSON.stringify({
    proposalId: id.toString(), txHash: tx.hash, createdAt: new Date().toISOString(),
    description: DESCRIPTION, signers: s.signers, threshold: s.threshold, nonce: s.nonce.toString(),
  }, null, 2));
  const proposal = await governor.proposals(id);
  log(`proposal ${id} created in block ${receipt.blockNumber}`);
  log(`  voting opens ${new Date(Number(proposal.voteStart) * 1000).toISOString()}; run \`vote\` after that`);
}

async function voteStep(provider) {
  const id = managedProposalId();
  if (id === 0n) throw new Error("no proposal recorded; run propose first");
  const governor = new Contract(GOVERNOR, GOVERNOR_ABI, provider);
  const idx = Number(await governor.state(id));
  if (idx !== 1) throw new Error(`proposal ${id} is ${STATE_NAMES[idx]}, not Active — nothing to vote on`);
  if (await governor.hasVoted(id, TREASURY)) { log("already voted"); return; }
  const treasury = keyFor(TREASURY, "the treasury");
  const tx = await new Contract(GOVERNOR, GOVERNOR_ABI, new Wallet(treasury.key, provider))
    .castVote(id, SUPPORT_FOR, { gasLimit: 500_000n, gasPrice: GAS_PRICE });
  log(`vote sent ${tx.hash}`);
  const receipt = await tx.wait();
  if (!receipt || receipt.status !== 1) throw new Error(`vote reverted in ${tx.hash}`);
  log(`voted in favour in block ${receipt.blockNumber}`);
}

async function runStep(provider) {
  const id = managedProposalId();
  if (id === 0n) return proposeStep(provider);
  const governor = new Contract(GOVERNOR, GOVERNOR_ABI, provider);
  const idx = Number(await governor.state(id));
  log(`proposal ${id} state ${STATE_NAMES[idx]}`);
  if (idx === 0) { log("Pending — come back after the vote-start time"); return; }
  if (idx === 1 && !(await governor.hasVoted(id, TREASURY))) return voteStep(provider);
  if (idx === 3 || idx === 4) {
    log("queue and execute are permissionless and already armed locally (cron on the server); nothing to do here");
    return;
  }
  log(`state ${STATE_NAMES[idx]} needs no action from this script`);
}

async function main() {
  const command = process.argv[2] ?? "status";
  const provider = new JsonRpcProvider(RPC_URL, CHAIN_ID, { staticNetwork: true });
  const net = await provider.getNetwork();
  if (net.chainId !== BigInt(CHAIN_ID)) throw new Error(`wrong chain: ${net.chainId}`);
  if (command === "status") return statusStep(provider);
  if (command === "prepare") return prepareStep(provider);
  if (command === "propose") return proposeStep(provider);
  if (command === "vote") return voteStep(provider);
  if (command === "run") return runStep(provider);
  throw new Error(`unknown command "${command}". Use status, prepare, propose, vote or run.`);
}

main().catch((e) => { log(`STOPPED: ${e instanceof Error ? e.message : String(e)}`); process.exit(1); });
