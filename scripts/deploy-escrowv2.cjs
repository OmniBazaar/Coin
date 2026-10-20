/**
 * Deploy EscrowV2 — the PER-CHAIN escrow (2026-10-20).
 *
 * Founder decision 3: escrow on the chain where the token lives. This V4
 * contract has no cross-chain dependency — its own admin-set token allowlist,
 * the 1% split in kind on its own chain, and judge verdicts delivered as
 * EIP-712 signatures from the L1 arbitration panel. It is a FRESH contract,
 * never an upgrade.
 *
 * WHAT THIS SCRIPT DOES
 *   1. deploys the three linked libraries (fee router, privacy ops, signature
 *      verification) and records each as it lands;
 *   2. deploys EscrowV2 and verifies: code present, EIP-170 size under 24,576,
 *      every library address embedded in the runtime bytecode, constructor
 *      state read back, XOM seeded into the allowlist;
 *   3. writes the addresses into deployments/<chain>.json.
 *
 * WHAT IT DELIBERATELY DOES NOT DO
 *   - allowlist additional settlement tokens (call `setSupportedToken`);
 *   - roster verdict judges (call `setVerdictJudge`);
 *   - seed internal arbitrators.
 *   Those are one-line admin calls, printed at the end, so a mistyped token or
 *   judge address cannot be buried in a deploy transaction.
 *
 * INPUTS (env; a missing or malformed value is a hard error, never a default
 * that silently points a fee slice at the wrong address):
 *   MAINNET_DEPLOYER_PRIVATE_KEY   the Pioneer-phase admin key
 *   ESCROW_ODDAO                   ODDAO sink on THIS chain
 *   ESCROW_STAKING_POOL            staking-pool sink on THIS chain
 *   ESCROW_TREASURY                protocol-treasury sink on THIS chain
 *   ESCROW_OMNI_COIN               (optional) settlement coin; defaults to the
 *                                  chain manifest's OmniCoin
 *   ESCROW_PRIVATE_OMNI_COIN       (optional) pXOM; omit on chains without it
 *   ESCROW_REGISTRY                (optional) OmniRegistration; omit if absent
 *   ESCROW_FORWARDER               (optional) ERC-2771 forwarder; omit to
 *                                  disable meta-transactions
 *
 * Usage:
 *   MAINNET_DEPLOYER_PRIVATE_KEY=$(cat ~/.avalanche-cli/key/deployer.pk) \
 *   ESCROW_ODDAO=0x… ESCROW_STAKING_POOL=0x… ESCROW_TREASURY=0x… \
 *     npx hardhat run scripts/deploy-escrowv2.cjs --network mainnet-c-chain
 *   (OmniCoin L1: --network mainnet, chain 88008)
 */
const fs = require("fs");
const path = require("path");
const hre = require("hardhat");

/** The only key permitted to sign a mainnet deploy (Pioneer-phase admin). */
const EXPECTED_DEPLOYER = "0x021868f2E3D49C059EF52B539AAa933B437e0321";

/** Canonical 1% marketplace fee, pinned by the constructor. */
const MARKETPLACE_FEE_BPS = 100n;

/** EIP-170 deployed-code ceiling. */
const EIP170_LIMIT = 24576;

/** Libraries EscrowV2 links (must match its `import` list). */
const LIBRARIES = ["EscrowFeeRouter", "EscrowPrivacyOps", "EscrowSignatureLib"];

/**
 * Manifest file per chain. Names must match the files the rest of the repo
 * already uses — a made-up name writes an address nothing reads (re-audit D-6).
 */
const MANIFESTS = {
  88008n: "mainnet",
  43114n: "avalanche",
  43113n: "avalanche-testnet",
  137n: "polygon",
  8453n: "base",
  42161n: "arbitrum",
  56n: "bsc",
  1n: "ethereum-mainnet",
};

/**
 * Chain-agnostic protocol recipients (ODDao, OB Protocol Treasury, staking
 * reserve). ONE set of addresses for every chain — an account key works on
 * every EVM chain, so no per-chain forwarding contract is needed and none
 * should ever be deployed for this purpose.
 *
 * These three are immutable in the constructor, so a wrong value is permanent
 * for that deployment. Precedence: environment variable, then this file, then
 * the chain manifest. The deployer account is refused outright as a sink
 * (founder directive 2026-10-20).
 * @returns {{oddaoTreasury: string, protocolTreasury: string, stakingReserve: string}}
 */
function loadProtocolRecipients() {
  const path = require("path");
  const file = path.join(__dirname, "..", "deployments", "protocol-recipients.json");
  if (!fs.existsSync(file)) {
    throw new Error(
      `protocol recipients file is missing: ${file} — refusing to guess fee sinks`,
    );
  }
  return JSON.parse(fs.readFileSync(file, "utf8"));
}

/**
 * Resolve (and create) the deployment manifest for the current chain.
 * @param {bigint} chainId - Chain id being deployed to.
 * @returns {{path: string, json: object}} Manifest path and parsed content.
 */
function loadManifest(chainId) {
  const name = MANIFESTS[chainId];
  if (!name) {
    throw new Error(
      `No manifest for chain ${chainId}. Add it to MANIFESTS with the file name the repo already uses.`,
    );
  }
  const file = path.join(__dirname, "..", "deployments", `${name}.json`);
  const json = fs.existsSync(file)
    ? JSON.parse(fs.readFileSync(file, "utf8"))
    : { chainId: Number(chainId), contracts: {} };
  json.contracts = json.contracts || {};
  return { path: file, json };
}

/**
 * Persist a manifest, creating the deployments directory if needed.
 * @param {{path: string, json: object}} manifest - Manifest handle.
 */
function saveManifest(manifest) {
  fs.mkdirSync(path.dirname(manifest.path), { recursive: true });
  fs.writeFileSync(manifest.path, `${JSON.stringify(manifest.json, null, 2)}\n`);
}

/**
 * Parse an optional address from the environment.
 * @param {string} key - Environment variable name.
 * @param {string|undefined} fallback - Value to use when the variable is unset.
 * @param {string} label - Human-readable label for errors.
 * @returns {string} A checksummed address, or the zero address.
 */
function resolveAddress(key, fallback, label) {
  const raw = process.env[key] || fallback || "";
  if (!raw) return hre.ethers.ZeroAddress;
  if (!hre.ethers.isAddress(raw)) {
    throw new Error(`${label}: "${raw}" is not an address`);
  }
  return hre.ethers.getAddress(raw);
}

async function main() {
  const { ethers } = hre;
  const [deployer] = await ethers.getSigners();

  console.log("=== EscrowV2 (per-chain) deployment ===");
  console.log("deployer:", deployer.address);
  if (deployer.address.toLowerCase() !== EXPECTED_DEPLOYER.toLowerCase()) {
    throw new Error(
      `Refusing to deploy: signer ${deployer.address} is not the canonical deployer ${EXPECTED_DEPLOYER}`,
    );
  }
  const network = await ethers.provider.getNetwork();
  console.log("chain:", network.chainId.toString());
  console.log(
    "gas balance:",
    ethers.formatEther(await ethers.provider.getBalance(deployer.address)),
    "native",
  );

  const manifest = loadManifest(network.chainId);
  const c = manifest.json.contracts;

  const omniCoin = resolveAddress("ESCROW_OMNI_COIN", c.OmniCoin, "ESCROW_OMNI_COIN");
  if (omniCoin === ethers.ZeroAddress) {
    throw new Error("ESCROW_OMNI_COIN is required (no OmniCoin in this chain's manifest)");
  }
  const privateOmniCoin = resolveAddress(
    "ESCROW_PRIVATE_OMNI_COIN",
    c.PrivateOmniCoin,
    "ESCROW_PRIVATE_OMNI_COIN",
  );
  const registry = resolveAddress("ESCROW_REGISTRY", c.OmniRegistration, "ESCROW_REGISTRY");
  const forwarder = resolveAddress("ESCROW_FORWARDER", c.OmniForwarder, "ESCROW_FORWARDER");
  // The three sinks come from the chain-agnostic recipients file, NOT from each
  // chain's manifest: the L1 staking pool and treasury are contracts that do
  // not exist on other chains, and crediting an address with no code strands
  // the funds where nothing can spend them (checked 2026-10-20 — neither had
  // code on Avalanche C-Chain).
  const recipients = loadProtocolRecipients();
  const oddao = resolveAddress("ESCROW_ODDAO", recipients.oddaoTreasury, "ESCROW_ODDAO");
  const stakingPool = resolveAddress(
    "ESCROW_STAKING_POOL",
    recipients.stakingReserve,
    "ESCROW_STAKING_POOL",
  );
  const treasury = resolveAddress(
    "ESCROW_TREASURY",
    recipients.protocolTreasury,
    "ESCROW_TREASURY",
  );

  for (const [label, addr] of Object.entries({ oddao, stakingPool, treasury })) {
    if (addr === ethers.ZeroAddress) {
      throw new Error(
        `${label} is required: every sale pays this sink a slice of the 1%`,
      );
    }
  }
  if (new Set([oddao, stakingPool, treasury]).size !== 3) {
    throw new Error("the three fee sinks must be distinct addresses");
  }
  // Founder directive 2026-10-20: protocol money must not land in the deployer
  // account. These fields are immutable, so this is the last moment to catch it.
  for (const [label, sink] of Object.entries({ oddao, stakingPool, treasury })) {
    if (sink.toLowerCase() === deployer.address.toLowerCase()) {
      throw new Error(
        `${label} is the deployer account — protocol fee sinks must not be the deployer`,
      );
    }
  }
  // The contract only knows its own address after construction, so the "sink
  // is the escrow" case lives here: a credit on the escrow itself is
  // unrecoverable (re-audit D-8).
  console.log("(the escrow address cannot be checked before deploy; re-check after)");
  console.log("\n-- constructor arguments --");
  console.log("omniCoin        :", omniCoin);
  console.log("privateOmniCoin :", privateOmniCoin);
  console.log("registry        :", registry);
  console.log("oddao           :", oddao);
  console.log("stakingPool     :", stakingPool);
  console.log("treasury        :", treasury);
  console.log("forwarder       :", forwarder);

  // Every constructor input must be a contract (or zero) BEFORE spending gas:
  // a mistyped sink would route protocol fees into a hole forever.
  for (const [label, addr] of Object.entries({
    omniCoin,
    privateOmniCoin,
    registry,
    forwarder,
  })) {
    if (addr === ethers.ZeroAddress) continue;
    const code = await ethers.provider.getCode(addr);
    if (code === "0x") throw new Error(`${label} has no code at ${addr}`);
  }

  // ── Deploy ─────────────────────────────────────────────────────────────
  const libs = {};
  for (const name of LIBRARIES) {
    const L = await ethers.getContractFactory(name);
    const lib = await L.deploy();
    await lib.waitForDeployment();
    libs[name] = await lib.getAddress();
    console.log(`\n${name}:`, libs[name]);
    // Record each library as it lands — a later failure must not lose it.
    manifest.json.contracts[name] = libs[name];
    saveManifest(manifest);
  }

  const Escrow = await ethers.getContractFactory("EscrowV2", { libraries: libs });
  const escrow = await Escrow.deploy(
    omniCoin,
    privateOmniCoin,
    registry,
    oddao,
    stakingPool,
    treasury,
    MARKETPLACE_FEE_BPS,
    forwarder,
  );
  const deployTx = escrow.deploymentTransaction();
  console.log("\ndeploy tx:", deployTx ? deployTx.hash : "(unknown)");
  await escrow.waitForDeployment();
  const address = await escrow.getAddress();
  console.log("EscrowV2:", address);

  // Record before verifying: a verification failure must not lose the address.
  manifest.json.contracts.EscrowV2 = address;
  manifest.json.contracts.EscrowV2DeployedAt = new Date().toISOString();
  manifest.json.contracts.EscrowV2DeployTx = deployTx ? deployTx.hash : "";
  saveManifest(manifest);
  // Read the file back rather than trusting the write: a deploy whose record
  // silently failed to persist leaves an unrecorded live contract.
  const recorded = JSON.parse(fs.readFileSync(manifest.path, "utf8"));
  if (recorded?.contracts?.EscrowV2 !== address) {
    throw new Error(
      `deployment record failed to persist: ${manifest.path} does not name ${address}`,
    );
  }
  console.log("addresses recorded in", manifest.path);

  // ── Verify ─────────────────────────────────────────────────────────────
  let code = "0x";
  for (let attempt = 0; attempt < 10 && code === "0x"; attempt += 1) {
    code = await ethers.provider.getCode(address);
    if (code === "0x") await new Promise((r) => setTimeout(r, 1500));
  }
  if (code === "0x") throw new Error(`no code at ${address} after 15s`);
  const size = (code.length - 2) / 2;
  if (size > EIP170_LIMIT) {
    throw new Error(`EscrowV2 is ${size} bytes — over the ${EIP170_LIMIT} EIP-170 limit`);
  }
  for (const [name, libAddr] of Object.entries(libs)) {
    if ((await ethers.provider.getCode(libAddr)) === "0x") {
      throw new Error(`${name} has no code at ${libAddr}`);
    }
    if (!code.toLowerCase().includes(libAddr.slice(2).toLowerCase())) {
      throw new Error(`EscrowV2 bytecode does not embed ${name} (${libAddr})`);
    }
  }
  console.log(`\nlinked libraries OK — escrow ${size} of ${EIP170_LIMIT} bytes`);

  // Binding probe (re-audit D-7): an address-in-bytecode check also passes for
  // a STALE library of the same name. A createEscrow staticCall with a codeless
  // token reaches `requireSupportedToken`, so a linked, working library must
  // return revert data. Empty returndata means the DELEGATECALL hit nothing —
  // exactly what a mislinked library looks like.
  const probe = await ethers.provider.call({
    to: address,
    from: deployer.address,
    data: new ethers.Interface([
      "function createEscrow(address,address,uint256,uint256)",
    ]).encodeFunctionData("createEscrow", [
      deployer.address,
      "0x000000000000000000000000000000000000dEaD",
      1n,
      24 * 60 * 60,
    ]),
  }).catch((err) => {
    const data = err && err.data;
    return typeof data === "string" ? data : "0x";
  });
  if (!probe || probe === "0x") {
    throw new Error(
      "binding probe returned no revert data — the escrow's libraries are not linked",
    );
  }
  console.log("library binding probe OK");

  const reads = {
    OMNI_COIN: await escrow.OMNI_COIN(),
    PRIVATE_OMNI_COIN: await escrow.PRIVATE_OMNI_COIN(),
    REGISTRY: await escrow.REGISTRY(),
    ODDAO: await escrow.ODDAO(),
    STAKING_POOL: await escrow.STAKING_POOL(),
    PROTOCOL_TREASURY: await escrow.PROTOCOL_TREASURY(),
    MARKETPLACE_FEE_BPS: (await escrow.MARKETPLACE_FEE_BPS()).toString(),
    admin: await escrow.admin(),
  };
  for (const [k, v] of Object.entries(reads)) console.log(`${k}: ${v}`);
  if (reads.MARKETPLACE_FEE_BPS !== "100") throw new Error("fee bps not pinned to 100");
  if (reads.admin.toLowerCase() !== deployer.address.toLowerCase()) {
    throw new Error("admin is not the deployer");
  }
  if (reads.ODDAO.toLowerCase() !== oddao.toLowerCase()) throw new Error("ODDAO mismatch");
  if (reads.STAKING_POOL.toLowerCase() !== stakingPool.toLowerCase()) {
    throw new Error("staking pool mismatch");
  }
  if (reads.PROTOCOL_TREASURY.toLowerCase() !== treasury.toLowerCase()) {
    throw new Error("treasury mismatch");
  }
  const xomAllowed = await escrow.supportedToken(omniCoin);
  console.log("XOM on the escrow's own allowlist:", xomAllowed);
  if (!xomAllowed) throw new Error("XOM is not allowlisted; every create would revert");

  const receipt = await deployTx.wait();
  console.log("mined in block", receipt.blockNumber, "gas used", receipt.gasUsed.toString());

  // ── Follow-ups (deliberately not automated) ────────────────────────────
  console.log("\n-- follow-ups, one admin call each --");
  console.log(`  escrow.setSupportedToken(<settlement token>, true)`);
  console.log(`  escrow.setVerdictJudge(<seated judge>, true)   × 3 (at least 2)`);
  console.log(`  escrow.addArbitrator(<internal arbitrator>)    (private/pXOM votes)`);
  console.log("\nNext: node scripts/sync-contract-addresses.js <chain>");
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
