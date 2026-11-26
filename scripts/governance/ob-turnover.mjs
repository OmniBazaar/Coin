#!/usr/bin/env node
/**
 * ob-turnover.mjs — finish the 2026-11 deployer retirement.
 *
 * Windows PowerShell usage (Node 18+ and ethers already installed in the same
 * folder — the founder's C:\Users\rickc\ob-keys):
 *   Set-Location C:\Users\rickc\ob-keys
 *   node ob-turnover.mjs identify           --key-dir .
 *   node ob-turnover.mjs audit
 *   node ob-turnover.mjs judge-accept       --key-dir . --execute
 *   node ob-turnover.mjs coti-handover      --key-dir . --execute
 *   node ob-turnover.mjs coti-accept-ownership --key-dir . --execute
 *
 * Subcommands
 *   identify       which key file is which, by DERIVED ADDRESS. File names are
 *                  not trusted: the folder's names are inverted relative to the
 *                  ledger, so the address decides.
 *   audit          read-only. What the retired deployer still controls, and the
 *                  exact plan coti-handover would run.
 *   judge-accept   EscrowV2.acceptJudgeRemoval(). Needs the SUCCESSOR key
 *                  (0x68d002Bb…), which is the EscrowV2 admin. The deployer key
 *                  cannot do this.
 *   coti-handover  Moves COTI admin/ownership to the successor. Needs the
 *                  RETIRED DEPLOYER key. Dry run unless --execute.
 *   coti-accept-ownership  Successor completes a pending Ownable2Step transfer.
 *
 * Key selection: --key-file <path> pinpoints one file; --key-dir <path> scans
 * the folder and picks the file whose address matches the role. Both print the
 * address and file name, never the key.
 *
 * Design rules
 *   - The key is read from a file and never printed, logged or echoed.
 *   - Every call is simulated (eth_call from the signer) before it is sent.
 *   - Order is grants first, renounces last, and a DEFAULT_ADMIN renounce is
 *     refused unless the successor already holds the role (verified on chain).
 *   - Roles other than DEFAULT_ADMIN / ARBITRATOR_ROLE are REPORTED, never
 *     revoked: they belong to live operating keys (relayer, settler, oracle),
 *     and revoking one on a wrong role model would break the service. A
 *     destroyed key holding them is inert.
 */
import { ethers } from "ethers";
import { readFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";

const L1_RPC = process.env.OB_L1_RPC ?? "https://rpc.omnicoin.net";
const L1_CHAIN_ID = 88008n;
const COTI_RPC = process.env.OB_COTI_RPC ?? "https://mainnet.coti.io/rpc";
const COTI_CHAIN_ID = 2632500n;

const ESCROW_V2 = "0x7144B011ce241eecA38CD0c4948777B761985864";
const DEPLOYER = "0x021868f2E3D49C059EF52B539AAa933B437e0321";
const SUCCESSOR = "0x68d002Bb315E8310c1344EeA707f9C36DdC33e1e";

const DEFAULT_ADMIN = "0x" + "00".repeat(32);

const COTI_TARGETS = [
  { name: "pXOM (PrivateOmniCoin)", address: "0x958b07d5C302338C8302c6b5a1Bff49bbF9aa934", kind: "acl",
    roles: ["MINTER_ROLE", "DEFAULT_ADMIN_ROLE"] },
  { name: "PrivateMarketplaceEscrow", address: "0x43d216073D3c7B494FA3626C0607FfF14758A670", kind: "acl",
    roles: ["RELAYER_ROLE", "ARBITRATOR_ROLE", "DEFAULT_ADMIN_ROLE"] },
  { name: "PrivateYieldVault", address: "0x95e461f65157D7B1504B6c7901aEb01f34f29DCf", kind: "acl",
    roles: ["RELAYER_ROLE", "DEFAULT_ADMIN_ROLE"] },
  { name: "PrivateRWAAMM", address: "0xe6380a2A3e548150c37505237Fe1203eC6905fa2", kind: "acl",
    roles: ["RELAYER_ROLE", "DEFAULT_ADMIN_ROLE"] },
  { name: "PrivatePredictionMarket", address: "0xFcC6Cda5784D1532704ACBc0ec555b10Cb96BD28", kind: "acl",
    roles: ["RELAYER_ROLE", "ESCROW_ORACLE_ROLE", "DEFAULT_ADMIN_ROLE"] },
  { name: "PrivateLimitDEXSettlement", address: "0xCCe8f6b93d2aDa98eA0a66C8230BCf1B6FFa8A5C", kind: "acl",
    roles: ["SETTLER_ROLE", "COMMITTEE_ROLE", "FEE_MANAGER_ROLE", "DEFAULT_ADMIN_ROLE"] },
  { name: "HypXomSynthetic", address: "0x71A765c59C3cdE31b6F0b5d501a9500b0FF667A0", kind: "ownable", roles: [] },
  { name: "OmniPrivacyShield", address: "0x7208B56f3B6aF20FA1817f460D5eFcaA217f09a6", kind: "ownable2step", roles: [] },
];

/** Roles the successor is meant to hold. */
const SUCCESSOR_ROLES = new Set(["DEFAULT_ADMIN_ROLE", "ARBITRATOR_ROLE"]);

const ABI = [
  "function hasRole(bytes32 role, address account) view returns (bool)",
  "function grantRole(bytes32 role, address account)",
  "function renounceRole(bytes32 role, address account)",
  "function admin() view returns (address)",
  "function pendingJudgeRemoval() view returns (address)",
  "function judgeRemovalAt() view returns (uint256)",
  "function acceptJudgeRemoval()",
  "function getVerdictJudges(uint256 offset, uint256 limit) view returns (address[])",
  "function owner() view returns (address)",
  "function pendingOwner() view returns (address)",
  "function transferOwnership(address newOwner)",
  "function acceptOwnership()",
];

const arg = (n) => { const i = process.argv.indexOf(`--${n}`); return i < 0 ? undefined : process.argv[i + 1]; };
const flag = (n) => process.argv.includes(`--${n}`);
const same = (a, b) => a.toLowerCase() === b.toLowerCase();
const roleHash = (n) => (n === "DEFAULT_ADMIN_ROLE" ? DEFAULT_ADMIN : ethers.id(n));

function parseKeyText(raw) {
  let s = String(raw).trim();
  if (s.startsWith('"') && s.endsWith('"')) s = s.slice(1, -1).trim();
  if (!s.startsWith("0x")) s = "0x" + s;
  return /^0x[0-9a-fA-F]{64}$/.test(s) ? s : null;
}

/** Every key-looking file in a folder, with its derived address. Keys stay in
 *  memory; only the address and the path are ever printed. */
function scanDir(dir) {
  const found = [];
  for (const entry of readdirSync(dir)) {
    const path = join(dir, entry);
    let st;
    try { st = statSync(path); } catch { continue; }
    if (!st.isFile() || st.size > 4096) continue;
    let raw;
    try { raw = readFileSync(path, "utf8"); } catch { continue; }
    const key = parseKeyText(raw);
    if (!key) continue;
    let address;
    try { address = new ethers.Wallet(key).address; } catch { continue; }
    found.push({ path, key, address });
  }
  return found;
}

const KNOWN_ADDRESSES = {
  [DEPLOYER.toLowerCase()]: "RETIRED DEPLOYER — compromised 2026-11-15, shredded on the server",
  [SUCCESSOR.toLowerCase()]: "SUCCESSOR — EscrowV2 admin, COTI settlement admin",
  "0x7f9dab90dd756863d9b4abef1b10f363e08d3fa8": "node gas faucet (server; not a turnover key)",
};

/** Pick the key for a specific address. File names are never trusted — the
 *  derived address decides, and the choice is printed. */
function resolveKey(wantAddress, label) {
  const file = arg("key-file");
  let entries;
  if (file) {
    const key = parseKeyText(readFileSync(file, "utf8"));
    if (!key) throw new Error(`${file} does not contain a 32-byte hex private key`);
    entries = [{ path: file, key, address: new ethers.Wallet(key).address }];
  } else {
    const dir = arg("key-dir");
    if (!dir) throw new Error("pass --key-dir <folder> (your key folder) or --key-file <path>");
    entries = scanDir(dir);
  }
  if (entries.length === 1 && !same(entries[0].address, wantAddress) && file) {
    throw new Error(`this key is ${entries[0].address}, not ${wantAddress}${label ? ` (${label})` : ""}`);
  }
  const match = entries.find((e) => same(e.address, wantAddress));
  if (!match) {
    const seen = entries.map((e) => `\n   ${e.address}  ${e.path}`).join("");
    throw new Error(`no key here derives ${wantAddress}${label ? ` (${label})` : ""}; keys found:${seen || " none"}`);
  }
  console.log(`key:     ${match.address}  (${match.path})`);
  return match;
}

async function connect(url, chainId) {
  const provider = new ethers.JsonRpcProvider(url, Number(chainId), { staticNetwork: true });
  const net = await provider.getNetwork();
  if (net.chainId !== chainId) throw new Error(`wrong chain: expected ${chainId}, got ${net.chainId}`);
  return provider;
}

/** Build the ordered COTI plan from live state. Pure read; no signing. */
async function buildCotiPlan(provider) {
  const plan = [];
  const inert = [];
  for (const t of COTI_TARGETS) {
    const c = new ethers.Contract(t.address, ABI, provider);
    if (t.kind === "ownable" || t.kind === "ownable2step") {
      const owner = await c.owner();
      if (!same(owner, DEPLOYER)) continue;
      const step = { t, call: "transferOwnership", args: [SUCCESSOR],
        why: t.kind === "ownable2step" ? "owner → successor (then the successor calls acceptOwnership)" : "owner → successor" };
      plan.push(step);
      continue;
    }
    const grants = [];
    for (const role of t.roles) {
      const h = roleHash(role);
      const [d, s] = await Promise.all([c.hasRole(h, DEPLOYER), c.hasRole(h, SUCCESSOR)]);
      if (d && !s && SUCCESSOR_ROLES.has(role)) grants.push(role);
      if (d && !SUCCESSOR_ROLES.has(role)) inert.push(`${t.name}: ${role} (left in place — operational role)`);
    }
    for (const role of grants) plan.push({ t, call: "grantRole", args: [roleHash(role), SUCCESSOR], why: `grant ${role} → successor` });
    if (!grants.includes("DEFAULT_ADMIN_ROLE")) {
      const [d, s] = await Promise.all([c.hasRole(DEFAULT_ADMIN, DEPLOYER), c.hasRole(DEFAULT_ADMIN, SUCCESSOR)]);
      if (d && s) plan.push({ t, call: "renounceRole", args: [DEFAULT_ADMIN, DEPLOYER], why: "renounce DEFAULT_ADMIN from deployer" });
      continue;
    }
    plan.push({ t, call: "renounceRole", args: [DEFAULT_ADMIN, DEPLOYER], why: "renounce DEFAULT_ADMIN from deployer" });
  }
  return { plan, inert };
}

async function identify() {
  const dir = arg("key-dir");
  if (!dir) throw new Error("pass --key-dir <folder>");
  const entries = scanDir(dir);
  if (!entries.length) throw new Error(`no private key files found in ${dir}`);
  console.log(`keys in ${dir}\n`);
  for (const e of entries) {
    const label = KNOWN_ADDRESSES[e.address.toLowerCase()] ?? "unrecognised";
    console.log(`  ${e.address}  ${e.path}`);
    console.log(`     ${label}`);
  }
  const have = (a) => entries.some((e) => same(e.address, a));
  console.log(`\ndeployer key present:  ${have(DEPLOYER)}`);
  console.log(`successor key present: ${have(SUCCESSOR)}`);
  if (!have(SUCCESSOR)) console.log("→ judge-accept and coti-accept-ownership cannot run from this folder");
  if (!have(DEPLOYER)) console.log("→ coti-handover cannot run from this folder");
}

async function audit() {
  const coti = await connect(COTI_RPC, COTI_CHAIN_ID);
  console.log(`COTI mainnet (chain ${COTI_CHAIN_ID}) — retired deployer ${DEPLOYER}\n`);
  for (const t of COTI_TARGETS) {
    const c = new ethers.Contract(t.address, ABI, coti);
    console.log(`${t.name}  ${t.address}`);
    if (t.kind === "acl") {
      for (const role of t.roles) {
        const [d, s] = await Promise.all([c.hasRole(roleHash(role), DEPLOYER), c.hasRole(roleHash(role), SUCCESSOR)]);
        if (d || s) console.log(`   ${role.padEnd(20)} deployer=${d} successor=${s}`);
      }
    } else {
      console.log(`   owner=${await c.owner()}${t.kind === "ownable2step" ? ` pendingOwner=${await c.pendingOwner()}` : ""}`);
    }
  }
  const { plan, inert } = await buildCotiPlan(coti);
  console.log("\nPLAN for coti-handover");
  if (!plan.length) console.log("   (nothing to do)");
  for (const s of plan) console.log(`   ${s.t.name.padEnd(26)} ${s.call.padEnd(18)} ${s.why}`);
  if (inert.length) {
    console.log("\nREPORTED, NOT TOUCHED (a destroyed key holding these is inert)");
    for (const line of inert) console.log(`   ${line}`);
  }

  const l1 = await connect(L1_RPC, L1_CHAIN_ID);
  const esc = new ethers.Contract(ESCROW_V2, ABI, l1);
  const [admin, pending, at, roster] = await Promise.all([
    esc.admin(), esc.pendingJudgeRemoval(), esc.judgeRemovalAt(), esc.getVerdictJudges(0, 10),
  ]);
  const now = Math.floor(Date.now() / 1000);
  console.log(`\nchain ${L1_CHAIN_ID} — EscrowV2 ${ESCROW_V2}`);
  console.log(`   admin=${admin}`);
  console.log(`   pendingJudgeRemoval=${pending}`);
  console.log(`   judgeRemovalAt=${at} (${at ? new Date(Number(at) * 1000).toISOString() : "-"}) ${at && now >= Number(at) ? "MATURE" : "not yet mature"}`);
  console.log(`   roster=[${roster.join(", ")}]`);
  console.log(`\njudge-accept needs the key for ${admin} — the successor. The deployer key cannot do it.`);
}

async function judgeAccept() {
  const provider = await connect(L1_RPC, L1_CHAIN_ID);
  const escRead = new ethers.Contract(ESCROW_V2, ABI, provider);
  const [admin, pending, at] = await Promise.all([escRead.admin(), escRead.pendingJudgeRemoval(), escRead.judgeRemovalAt()]);
  const chosen = resolveKey(admin, "EscrowV2 admin — the successor");
  const wallet = new ethers.Wallet(chosen.key, provider);
  const esc = new ethers.Contract(ESCROW_V2, ABI, wallet);
  console.log(`admin:   ${admin}`);
  console.log(`pending: ${pending || "(none)"}  mature at ${at ? new Date(Number(at) * 1000).toISOString() : "-"}`);
  if (!same(wallet.address, admin)) throw new Error(`this key is NOT the EscrowV2 admin — nothing it signs will be accepted (admin is ${admin})`);
  if (pending === ethers.ZeroAddress) throw new Error("no pending judge removal");
  if (BigInt(at) > BigInt(Math.floor(Date.now() / 1000))) throw new Error("48h clock has not matured yet");
  await wallet.call({ to: ESCROW_V2, data: esc.interface.encodeFunctionData("acceptJudgeRemoval") });
  console.log("simulation: OK");
  if (!flag("execute")) { console.log("\nDRY RUN — re-run with --execute to broadcast."); return; }
  const tx = await esc.acceptJudgeRemoval();
  console.log(`sent ${tx.hash}`);
  const rc = await tx.wait();
  console.log(`mined in block ${rc.blockNumber}, status ${rc.status}`);
  const [p2, roster] = await Promise.all([esc.pendingJudgeRemoval(), esc.getVerdictJudges(0, 10)]);
  console.log(`after: pendingJudgeRemoval=${p2}`);
  console.log(`after: roster=[${roster.join(", ")}]`);
  if (p2 !== ethers.ZeroAddress || roster.map((a) => a.toLowerCase()).includes(pending.toLowerCase())) {
    throw new Error("post-check FAILED — pending removal or roster entry still present");
  }
  console.log("verified: the retired judge is off the roster");
}

async function cotiHandover() {
  const provider = await connect(COTI_RPC, COTI_CHAIN_ID);
  const chosen = resolveKey(DEPLOYER, "the retired deployer");
  const wallet = new ethers.Wallet(chosen.key, provider);
  console.log(`deployer:  ${wallet.address}`);
  console.log(`successor: ${SUCCESSOR}`);
  console.log(`native balance: ${ethers.formatEther(await provider.getBalance(wallet.address))} COTI\n`);
  const { plan, inert } = await buildCotiPlan(provider);
  if (!plan.length) { console.log("nothing to do"); return; }
  console.log("PLAN");
  for (const s of plan) console.log(`  ${s.t.name.padEnd(26)} ${s.call.padEnd(18)} ${s.why}`);
  if (inert.length) { console.log("\nREPORTED, NOT TOUCHED"); for (const l of inert) console.log(`  ${l}`); }

  const execute = flag("execute");
  for (const s of plan) {
    const c = new ethers.Contract(s.t.address, ABI, wallet);
    const fn = flag("skip-simulate") ? null : c.interface.encodeFunctionData(s.call, s.args);
    if (fn) await wallet.call({ to: s.t.address, data: fn });
    if (!execute) continue;
    const tx = await c[s.call](...s.args);
    const rc = await tx.wait();
    console.log(`  ${s.call} on ${s.t.name}: block ${rc.blockNumber} status ${rc.status} ${tx.hash}`);
    if (rc.status !== 1) throw new Error(`${s.call} on ${s.t.name} FAILED`);
  }
  if (!execute) { console.log("\nDRY RUN — every call simulated; re-run with --execute to broadcast."); return; }
  console.log("\npost-check (live)");
  for (const t of COTI_TARGETS) {
    const c = new ethers.Contract(t.address, ABI, provider);
    if (t.kind !== "acl") {
      console.log(`  ${t.name.padEnd(26)} owner=${await c.owner()} pendingOwner=${t.kind === "ownable2step" ? await c.pendingOwner() : "n/a"}`);
      continue;
    }
    const held = [];
    for (const role of t.roles) if (await c.hasRole(roleHash(role), DEPLOYER)) held.push(role);
    const succAdmin = await c.hasRole(DEFAULT_ADMIN, SUCCESSOR);
    console.log(`  ${t.name.padEnd(26)} deployer roles left: ${held.length ? held.join(",") : "none"} | successor admin: ${succAdmin}`);
  }
}

async function cotiAcceptOwnership() {
  const provider = await connect(COTI_RPC, COTI_CHAIN_ID);
  const chosen = resolveKey(SUCCESSOR, "the successor");
  const wallet = new ethers.Wallet(chosen.key, provider);
  const steps = [];
  for (const t of COTI_TARGETS) {
    if (t.kind !== "ownable2step") continue;
    const c = new ethers.Contract(t.address, ABI, provider);
    const pending = await c.pendingOwner();
    if (same(pending, wallet.address)) steps.push({ t, c });
  }
  if (!steps.length) { console.log(`no pending ownership transfer waiting for ${wallet.address}`); return; }
  for (const { t, c } of steps) {
    await wallet.call({ to: t.address, data: c.interface.encodeFunctionData("acceptOwnership") });
    if (!flag("execute")) { console.log(`  ${t.name.padEnd(26)} acceptOwnership — simulated OK`); continue; }
    const tx = await c.connect(wallet).acceptOwnership();
    const rc = await tx.wait();
    console.log(`  ${t.name.padEnd(26)} block ${rc.blockNumber} status ${rc.status} ${tx.hash}`);
    if (rc.status !== 1) throw new Error(`acceptOwnership on ${t.name} FAILED`);
  }
  if (!flag("execute")) { console.log("\nDRY RUN — re-run with --execute to broadcast."); return; }
  for (const { t } of steps) {
    const owner = await new ethers.Contract(t.address, ABI, provider).owner();
    console.log(`  ${t.name.padEnd(26)} owner now ${owner}`);
    if (!same(owner, wallet.address)) throw new Error(`${t.name}: ownership did not move`);
  }
}

const cmd = process.argv[2];
try {
  if (cmd === "identify") await identify();
  else if (cmd === "audit") await audit();
  else if (cmd === "judge-accept") await judgeAccept();
  else if (cmd === "coti-handover") await cotiHandover();
  else if (cmd === "coti-accept-ownership") await cotiAcceptOwnership();
  else { console.log("usage: node ob-turnover.mjs <identify|audit|judge-accept|coti-handover|coti-accept-ownership> --key-dir <folder> [--execute]   (or --key-file <path>)"); process.exit(2); }
} catch (err) {
  console.error(`ERROR: ${err.message}`);
  process.exit(1);
}
