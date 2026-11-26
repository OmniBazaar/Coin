#!/usr/bin/env node
/**
 * publish-release-direct.mjs — attest a release on the UpdateRegistry without
 * hardhat, so it runs on the founder's Windows machine with Node + ethers only.
 *
 * Why this exists: `Coin/scripts/publish-release.js` is a hardhat script
 * (`npx hardhat run … --network mainnet`). `release-path-monitor.sh` proved the
 * cost of that on 2026-11-26: the publish path was broken for two weeks and the
 * first anybody knew was a failed release. When the registry-repair proposal
 * (governance proposal 20) executes, attestation is the very next step, and it
 * must not need a repository checkout, a hardhat install, or foundry. The
 * founder's folder (C:\Users\rickc\ob-keys) holds the keys and ethers; that is
 * all this file needs.
 *
 * Usage (PowerShell, from the folder that holds your key files):
 *
 *   # 1. what the chain says right now (read-only)
 *   node publish-release-direct.mjs status
 *
 *   # 2. sign with every key in the folder that is in the current signer set.
 *   #    One run produces all signatures you can produce locally.
 *   node publish-release-direct.mjs sign --key-dir . `
 *       --component wallet --version 1.0.17 `
 *       --hash <binaryHash from the release record> `
 *       --changelog-cid <ipfs cid from the release record>
 *
 *   # 3. simulate, then send. It refuses to send unless the admin key is really
 *   #    DEFAULT_ADMIN and the signature set really meets the threshold.
 *   node publish-release-direct.mjs publish --key-dir . `
 *       --component wallet --version 1.0.17 `
 *       --hash <same hash> --changelog-cid <same cid> --execute
 *
 * The two facts you need (`binaryHash`, `changelogCID`) are in
 * `releases/<component>-<version>/release-info.json`, written by publish-build.
 * On a machine without that folder, copy them from the release report.
 *
 * Rules this file keeps:
 *   - Keys are chosen by DERIVED ADDRESS, never by file name. The founder's
 *     folder is named backwards (`deployer.pk` holds the successor,
 *     `.deployer-temp.pk` holds the retired deployer), so trusting a name has
 *     already cost this project a session.
 *   - The key is never printed, logged or echoed.
 *   - `publish` simulates with eth_call first and refuses to broadcast without
 *     `--execute`.
 *   - Every signature is recovered locally and must both match the address it
 *     claims and belong to the current on-chain signer set. The hardhat script
 *     trusts the JSON files; this one does not.
 *   - The nonce is read live and must match every signature file. Publishing
 *     consumes a nonce, so a second component needs a fresh `sign` run.
 *
 * Committed 2026-11-26 with the release path frozen at 1.0.16; not exercised
 * against a live publish until proposal 20 executes.
 */
import { ethers } from "ethers";
import { readFileSync, readdirSync, statSync, writeFileSync, mkdirSync, existsSync } from "node:fs";
import { join, dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const RPC = process.env.OB_L1_RPC ?? "https://rpc.omnicoin.net";
const CHAIN_ID = 88008n;
const DEFAULT_ADMIN = "0x" + "00".repeat(32);

/** The registry address is read from the deployment file so there is one
 *  source of truth, with a fallback for a folder that has no repo checkout. */
const ADDRESS_RE = /^0x[0-9a-fA-F]{40}$/;

function registryAddress() {
  // An explicit address wins outright. (This is also how the self-test points
  // the tool at a throwaway deployment; it must not be mistaken for a file.)
  const fromEnv = process.env.OB_UPDATE_REGISTRY;
  if (fromEnv && ADDRESS_RE.test(fromEnv)) return fromEnv;

  const file = process.env.OB_DEPLOYMENT_FILE ?? resolve(HERE, "..", "..", "deployments", "mainnet.json");
  if (existsSync(file)) {
    try {
      const j = JSON.parse(readFileSync(file, "utf8"));
      const addr = j?.contracts?.UpdateRegistry ?? j?.UpdateRegistry;
      if (addr && ADDRESS_RE.test(addr)) return addr;
    } catch { /* fall through to the known address */ }
  }
  return "0xd8E2a242dd344BE4A61c3DdD4332717766EB648B";
}

const ABI = [
  "function operationNonce() view returns (uint256)",
  "function signerThreshold() view returns (uint256)",
  "function getSigners() view returns (address[])",
  "function getLatestVersion(string) view returns (string)",
  "function getRelease(string component, string version) view returns (tuple(uint256 publishedAt, bytes32 binaryHash, address publishedBy, bool revoked, string version_, string minimumVersion, string revokeReason, string changelogCID))",
  "function hasRole(bytes32 role, address account) view returns (bool)",
  "function publishRelease(string component, string version, bytes32 binaryHash, string minVersion, string changelogCID, uint256 nonce, bytes[] signatures)",
];

const arg = (n) => { const i = process.argv.indexOf(`--${n}`); return i < 0 ? undefined : process.argv[i + 1]; };
const flag = (n) => process.argv.includes(`--${n}`);
const same = (a, b) => String(a).toLowerCase() === String(b).toLowerCase();

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

function keyEntries() {
  const file = arg("key-file");
  if (file) {
    const key = parseKeyText(readFileSync(file, "utf8"));
    if (!key) throw new Error(`${file} does not contain a 32-byte hex private key`);
    return [{ path: file, key, address: new ethers.Wallet(key).address }];
  }
  const dir = arg("key-dir");
  if (!dir) throw new Error("pass --key-dir <folder> (your key folder) or --key-file <path>");
  const entries = scanDir(dir);
  if (entries.length === 0) throw new Error(`no key files found in ${dir}`);
  return entries;
}

async function connect() {
  const provider = new ethers.JsonRpcProvider(RPC, Number(CHAIN_ID), { staticNetwork: true });
  const net = await provider.getNetwork();
  if (net.chainId !== CHAIN_ID) throw new Error(`wrong chain: expected ${CHAIN_ID}, got ${net.chainId}`);
  return provider;
}

function releaseArgs() {
  const component = arg("component");
  const version = arg("version");
  const hash = arg("hash");
  const minVersion = arg("min-version") ?? "";
  const changelogCID = arg("changelog-cid") ?? "";
  if (!component || !version || !hash) {
    throw new Error("pass --component <name> --version <semver> --hash <0x + 64 hex>, plus --min-version and --changelog-cid");
  }
  if (!/^0x[0-9a-fA-F]{64}$/.test(hash)) throw new Error("--hash must be 0x followed by 64 hex characters");
  return { component, version, hash: hash.toLowerCase(), minVersion, changelogCID };
}

/** The exact EIP-191 hash the contract builds in _verifySignatures. */
function messageHash({ component, version, hash, minVersion }, nonce, registry) {
  return ethers.keccak256(
    ethers.AbiCoder.defaultAbiCoder().encode(
      ["string", "string", "string", "bytes32", "string", "uint256", "uint256", "address"],
      ["PUBLISH_RELEASE", component, version, hash, minVersion, nonce, CHAIN_ID, registry],
    ),
  );
}

function signaturesDir() {
  const explicit = arg("sig-dir");
  if (explicit) return resolve(explicit);
  const fallback = resolve(HERE, "..", "..", "signatures");
  return fallback;
}

async function status() {
  const provider = await connect();
  const registry = new ethers.Contract(registryAddress(), ABI, provider);
  const [nonce, threshold, signers] = await Promise.all([
    registry.operationNonce(), registry.signerThreshold(), registry.getSigners(),
  ]);
  console.log(`registry:   ${registryAddress()}`);
  console.log(`chain:      ${CHAIN_ID}`);
  console.log(`nonce:      ${nonce}`);
  console.log(`threshold:  ${threshold}`);
  console.log(`signers:    ${signers.join(", ")}`);
  for (const component of ["wallet", "mobile", "webapp", "validator", "service-node", "listing-node"]) {
    const latest = await registry.getLatestVersion(component);
    console.log(`  ${component.padEnd(13)} latest on chain: ${latest || "(none)"}`);
  }
  const admins = [];
  for (const s of signers) if (await registry.hasRole(DEFAULT_ADMIN, s)) admins.push(s);
  const timelock = "0x4f78386cA05E333639151fe0508b21D893CaD222";
  const tlAdmin = await registry.hasRole(DEFAULT_ADMIN, timelock);
  console.log(`\nadmin (needed to publish): ${admins.length ? admins.join(", ") : "NO SIGNER HOLDS IT"}`);
  console.log(`primary timelock is admin: ${tlAdmin}`);
  if (admins.length === 0) {
    console.log("\nYou cannot publish yet. DEFAULT_ADMIN is held by the timelock only, which means the");
    console.log("registry-repair proposal must execute first. Proposal 20 grants it to the successor");
    console.log("(0x68d002Bb…) and installs the 2-of-3 signer set.");
  }
}

async function signRelease() {
  const provider = await connect();
  const registry = new ethers.Contract(registryAddress(), ABI, provider);
  const rel = releaseArgs();
  const nonce = await registry.operationNonce();
  const threshold = await registry.signerThreshold();
  const signers = (await registry.getSigners()).map((s) => s.toLowerCase());

  console.log(`registry:   ${registryAddress()}`);
  console.log(`nonce:      ${nonce}   (every signature below is bound to it)`);
  console.log(`threshold:  ${threshold}   signers: ${signers.join(", ")}`);
  console.log(`release:    ${rel.component} ${rel.version} hash ${rel.hash}\n`);

  const hash = messageHash(rel, nonce, registryAddress());
  const outDir = signaturesDir();
  mkdirSync(outDir, { recursive: true });

  const made = [];
  for (const entry of keyEntries()) {
    if (!signers.includes(entry.address.toLowerCase())) {
      console.log(`skip  ${entry.address}  not in the current signer set`);
      continue;
    }
    const wallet = new ethers.Wallet(entry.key);
    const signature = await wallet.signMessage(ethers.getBytes(hash));
    const recovered = ethers.verifyMessage(ethers.getBytes(hash), signature);
    if (!same(recovered, entry.address)) throw new Error("signature does not recover to the signing address");

    const file = join(outDir, `${rel.component}-${rel.version}-${entry.address.slice(0, 8)}.json`);
    writeFileSync(file, JSON.stringify({
      signer: entry.address,
      component: rel.component,
      version: rel.version,
      binaryHash: rel.hash,
      minVersion: rel.minVersion,
      changelogCID: rel.changelogCID,
      nonce: nonce.toString(),
      chainId: CHAIN_ID.toString(),
      registry: registryAddress(),
      signature,
      signedAt: new Date().toISOString(),
    }, null, 2));
    made.push(entry.address);
    console.log(`sign  ${entry.address}  -> ${file}`);
  }

  console.log(`\n${made.length} of ${threshold} required signatures written to ${outDir}`);
  if (made.length < Number(threshold)) {
    console.log("You need more signatures from other signers before publish will succeed.");
  } else {
    console.log("Next: publish --execute with the same release arguments.");
  }
}

async function publish() {
  const provider = await connect();
  const rel = releaseArgs();
  const registryAddressValue = registryAddress();
  const registry = new ethers.Contract(registryAddressValue, ABI, provider);

  const [nonce, threshold, signerList] = await Promise.all([
    registry.operationNonce(), registry.signerThreshold(), registry.getSigners(),
  ]);
  const signers = signerList.map((s) => s.toLowerCase());
  const expectedHash = messageHash(rel, nonce, registryAddressValue);

  console.log(`registry:   ${registryAddressValue}`);
  console.log(`nonce:      ${nonce}   threshold: ${threshold}`);
  console.log(`release:    ${rel.component} ${rel.version} hash ${rel.hash}`);

  const dir = signaturesDir();
  if (!existsSync(dir)) throw new Error(`no signature folder at ${dir}; run "sign" first`);

  const files = readdirSync(dir).filter((f) => f.endsWith(".json"));
  const usable = [];
  const seen = new Set();
  for (const f of files) {
    let data;
    try { data = JSON.parse(readFileSync(join(dir, f), "utf8")); } catch { continue; }
    if (!data.signature || !data.signer) continue;
    if (String(data.nonce) !== nonce.toString()) continue;             // stale nonce
    if (data.component !== rel.component || data.version !== rel.version) continue;
    if (!same(data.binaryHash, rel.hash)) continue;
    if ((data.minVersion ?? "") !== rel.minVersion) continue;
    const recovered = ethers.verifyMessage(ethers.getBytes(expectedHash), data.signature);
    if (!same(recovered, data.signer)) {
      console.log(`skip  ${f}  signature recovers to ${recovered}, file claims ${data.signer}`);
      continue;
    }
    if (!signers.includes(recovered.toLowerCase())) {
      console.log(`skip  ${f}  ${recovered} is not in the current signer set`);
      continue;
    }
    const key = recovered.toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    usable.push({ file: f, signer: recovered, signature: data.signature });
  }

  usable.sort((a, b) => a.signer.toLowerCase().localeCompare(b.signer.toLowerCase()));
  console.log(`signatures: ${usable.length} of ${threshold} required`);
  for (const s of usable) console.log(`  ${s.signer}  (${s.file})`);
  if (usable.length < Number(threshold)) {
    throw new Error(`not enough valid signatures for nonce ${nonce}; run "sign" in the other key folders`);
  }

  // The submitter must hold DEFAULT_ADMIN. Choose it by derived address.
  const entries = keyEntries();
  const admin = [];
  for (const e of entries) {
    if (await registry.hasRole(DEFAULT_ADMIN, e.address)) admin.push(e);
  }
  if (admin.length === 0) {
    throw new Error(
      "none of your keys holds DEFAULT_ADMIN on the registry, so the transaction would revert. " +
      "The registry-repair proposal must execute first; check with: publish-release-direct.mjs status",
    );
  }
  const submitter = admin[0];
  console.log(`submitter:  ${submitter.address}  (holds DEFAULT_ADMIN)`);

  const sigs = usable.map((s) => s.signature);
  const call = () => registry.connect(new ethers.Wallet(submitter.key, provider)).publishRelease(
    rel.component, rel.version, rel.hash, rel.minVersion, rel.changelogCID, nonce, sigs,
  );

  // Simulate before broadcasting, always.
  await registry.publishRelease.staticCall(
    rel.component, rel.version, rel.hash, rel.minVersion, rel.changelogCID, nonce, sigs,
    { from: submitter.address },
  ).catch((e) => { throw new Error(`simulation reverted: ${e.shortMessage ?? e.message}`); });
  console.log("simulation: OK");

  if (!flag("execute")) {
    console.log("\nDry run only. Add --execute to broadcast.");
    return;
  }

  const tx = await call();
  console.log(`sent:       ${tx.hash}`);
  const receipt = await tx.wait();
  console.log(`confirmed:  block ${receipt.blockNumber}`);

  const after = await registry.getRelease(rel.component, rel.version);
  console.log(`\non chain:   ${rel.component} ${after.version_}`);
  console.log(`  hash:     ${after.binaryHash}`);
  console.log(`  by:       ${after.publishedBy}`);
  console.log(`  revoked:  ${after.revoked}`);
  console.log(`  latest:   ${await registry.getLatestVersion(rel.component)}`);
  console.log(`  nonce:    ${await registry.operationNonce()}  (advanced by one)`);
}

async function main() {
  const command = process.argv[2] ?? "status";
  if (command === "status") return status();
  if (command === "sign") return signRelease();
  if (command === "publish") return publish();
  throw new Error(`unknown command "${command}". Use status, sign or publish.`);
}

main().catch((e) => {
  console.error(`\nFailed: ${e.shortMessage ?? e.message}`);
  process.exit(1);
});
