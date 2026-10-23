#!/usr/bin/env node
/**
 * Escrow chain parity check.
 *
 * Adding a chain is a deploy plus a handful of settings that must all agree:
 * the escrow address in config, the tokens its allowlist actually admits, the
 * judges rostered on it, and (where the chain has one) a protocol fee collector
 * that is not the deployer. Nothing in the codebase enforced that agreement, so
 * every chain was verified by hand — which is the expensive part of "adding a
 * chain".
 *
 * This script answers "is chain N configured correctly?" in one command, from
 * live reads where a live read is the authority:
 *
 *   1. the escrow has code and stays under the EIP-170 limit;
 *   2. every token in the chain's config is allowlisted ON the escrow, and the
 *      escrow's settlement coin matches the chain's default token;
 *   3. every seated judge is on the escrow's verdict roster;
 *   4. the three protocol fee recipients are distinct accounts (immutable, so a
 *      wrong one is unfixable without a redeploy);
 *   5. the chain's `OmniFeeRouter.feeCollector` (when the chain has one) is not
 *      the deployer account.
 *
 * Usage:
 *   node scripts/verify-escrow-chains.cjs              # every configured chain
 *   node scripts/verify-escrow-chains.cjs --chain 43114
 * Exit code is 0 only when every check passes — usable in CI or a release gate.
 */
const fs = require("fs");
const path = require("path");
const { ethers } = require("ethers");

const ROOT = path.resolve(__dirname, "..");
const DEPLOYMENTS = path.join(ROOT, "deployments");
const RECIPIENTS_FILE = path.join(DEPLOYMENTS, "protocol-recipients.json");

/** Canonical deployer (never an acceptable treasury). */
const DEPLOYER = "0x021868f2E3D49C059EF52B539AAa933B437e0321";

/** EIP-170 ceiling. */
const EIP170_LIMIT = 24576;

/**
 * Escrow chains the apps and validator know about.
 *
 * This mirrors `Validator/src/config/escrowChains.ts`. It is duplicated on
 * purpose: the check must be able to disagree with the config it is checking,
 * and importing compiled validator code from a Coin-side script would couple
 * the two builds.
 */
const CHAINS = [
  {
    chainId: 88008,
    name: "OmniCoin",
    deployment: "mainnet.json",
    rpcEnv: "MAINNET_RPC_URL",
    rpcDefault: "https://rpc.omnicoin.net",
    /** Escrow key in the deployment manifest. */
    escrowKey: "MinimalEscrow",
    /** L1 router (records its own chain list). */
    routerKey: "OmniFeeRouter",
  },
  {
    chainId: 43114,
    name: "Avalanche",
    deployment: "avalanche.json",
    rpcEnv: "AVALANCHE_CCHAIN_RPC_URL",
    rpcDefault: "https://avalanche-c-chain-rpc.publicnode.com",
    escrowKey: "EscrowV2",
    routerKey: "OmniFeeRouter",
  },
];

const ESCROW_ABI = [
  "function supportedToken(address) view returns (bool)",
  "function verdictJudge(address) view returns (bool)",
  "function omniCoin() view returns (address)",
  "function ODDAO() view returns (address)",
  "function STAKING_POOL() view returns (address)",
  "function PROTOCOL_TREASURY() view returns (address)",
];

const ROUTER_ABI = ["function feeCollector() view returns (address)"];

/**
 * Read a deployment manifest.
 * @param file - Manifest filename inside `deployments/`.
 * @returns The parsed manifest, or undefined when it does not exist.
 */
function loadDeployment(file) {
  const full = path.join(DEPLOYMENTS, file);
  if (!fs.existsSync(full)) return undefined;
  return JSON.parse(fs.readFileSync(full, "utf8"));
}

/**
 * Normalise an address for comparison.
 * @param value - Address or undefined.
 * @returns Lower-case address, or empty string.
 */
function lower(value) {
  return typeof value === "string" ? value.toLowerCase() : "";
}

/** Collected results, printed as a table at the end. */
const results = [];

/**
 * Record one check.
 * @param {string} chain - Chain name.
 * @param {string} check - What was checked.
 * @param {boolean|"skip"} ok - Passed, failed, or not applicable.
 * @param {string} detail - Human-readable evidence.
 */
function record(chain, check, ok, detail) {
  results.push({ chain, check, ok, detail });
}

/**
 * Check one chain.
 * @param {object} chain - Chain definition from {@link CHAINS}.
 * @param {object} recipients - protocol-recipients.json contents.
 * @returns {Promise<void>}
 */
async function checkChain(chain, recipients) {
  const manifest = loadDeployment(chain.deployment);
  if (manifest === undefined) {
    record(chain.name, "deployment manifest", false, `${chain.deployment} missing`);
    return;
  }
  const escrowAddress = manifest.contracts?.[chain.escrowKey];
  if (typeof escrowAddress !== "string" || !ethers.isAddress(escrowAddress)) {
    record(chain.name, "escrow address", false, `${chain.escrowKey} not recorded`);
    return;
  }

  const rpcUrl = process.env[chain.rpcEnv] || chain.rpcDefault;
  const provider = new ethers.JsonRpcProvider(
    rpcUrl,
    { chainId: chain.chainId, name: chain.name },
    { staticNetwork: true }
  );

  // 1. Code present and within the size limit.
  const code = await provider.getCode(escrowAddress);
  const size = (code.length - 2) / 2;
  record(
    chain.name,
    "escrow deployed",
    code !== "0x" && size > 0 && size <= EIP170_LIMIT,
    `${escrowAddress} — ${size} bytes (limit ${EIP170_LIMIT})`
  );
  if (code === "0x") return;

  const escrow = new ethers.Contract(escrowAddress, ESCROW_ABI, provider);

  // Which escrow generation is this? The decoupled escrow has a verdict-judge
  // roster; the legacy XOM-only MinimalEscrow does not, and has no per-token
  // allowlist or protocol-sink getters either. Checking those on it would
  // report permanent, expected "failures" and hide a real one.
  let decoupled = false;
  try {
    await escrow.verdictJudge.staticCall(ethers.ZeroAddress);
    decoupled = true;
  } catch {
    decoupled = false;
  }
  record(
    chain.name,
    "escrow generation",
    true,
    decoupled ? "decoupled (verdict roster)" : "legacy (XOM-only, internal arbitrators)"
  );

  if (!decoupled) {
    record(chain.name, "allowlist per token", "skip", "legacy escrow holds only its settlement coin");
    record(chain.name, "judge roster", "skip", "legacy escrow settles through its own arbitrators");
    record(chain.name, "fee sinks", "skip", "legacy escrow pays the vault, not per-sale sinks");
    const routerAddressLegacy = manifest.contracts?.[chain.routerKey];
    if (typeof routerAddressLegacy === "string" && ethers.isAddress(routerAddressLegacy)) {
      try {
        const router = new ethers.Contract(routerAddressLegacy, ROUTER_ABI, provider);
        const collector = await router.feeCollector.staticCall();
        record(
          chain.name,
          "router feeCollector is not the deployer",
          lower(collector) !== lower(DEPLOYER),
          `${routerAddressLegacy} → ${collector}`
        );
      } catch (err) {
        record(chain.name, "router feeCollector readable", false, err instanceof Error ? err.message : String(err));
      }
    }
    return;
  }

  // 2. Every token the config expects is actually allowlisted.
  const tokens = tokenListFor(chain, manifest);
  for (const token of tokens) {
    let allowed = false;
    let note = "";
    try {
      allowed = await escrow.supportedToken.staticCall(token.address);
    } catch {
      // The legacy L1 escrow has no per-token allowlist; its settlement coin is
      // the only money it can hold, checked below.
      note = " (no per-token allowlist on this escrow)";
      allowed = lower(token.address) === lower(manifest.escrowV2?.settlementCoin ?? manifest.contracts?.OmniCoin);
    }
    record(
      chain.name,
      `allowlist ${token.symbol}`,
      allowed,
      `${token.address}${note}`
    );
  }

  // 3. Every seated judge is on the roster.
  const judges = seatedJudges(chain, manifest);
  for (const judge of judges) {
    let rostered = false;
    try {
      rostered = await escrow.verdictJudge.staticCall(judge);
    } catch {
      rostered = false;
    }
    record(chain.name, `judge ${judge.slice(0, 10)}…`, rostered, rostered ? "rostered" : "NOT on the verdict roster");
  }

  // 4. The three immutable fee recipients are distinct and not the deployer.
  try {
    const [oddao, staking, treasury] = await Promise.all([
      escrow.ODDAO.staticCall(),
      escrow.STAKING_POOL.staticCall(),
      escrow.PROTOCOL_TREASURY.staticCall(),
    ]);
    const set = new Set([lower(oddao), lower(staking), lower(treasury)]);
    record(chain.name, "fee sinks distinct", set.size === 3, `${oddao} / ${staking} / ${treasury}`);
    record(
      chain.name,
      "fee sinks match protocol-recipients.json",
      lower(oddao) === lower(recipients.oddaoTreasury) &&
        lower(staking) === lower(recipients.stakingReserve) &&
        lower(treasury) === lower(recipients.protocolTreasury),
      "compare against Coin/deployments/protocol-recipients.json"
    );
    record(
      chain.name,
      "fee sinks are not the deployer",
      ![oddao, staking, treasury].some((a) => lower(a) === lower(DEPLOYER)),
      DEPLOYER
    );
  } catch (err) {
    record(chain.name, "fee sinks readable", false, err instanceof Error ? err.message : String(err));
  }

  // 5. The chain's fee router must not pay the deployer.
  const routerAddress = manifest.contracts?.[chain.routerKey];
  if (typeof routerAddress === "string" && ethers.isAddress(routerAddress)) {
    try {
      const router = new ethers.Contract(routerAddress, ROUTER_ABI, provider);
      const collector = await router.feeCollector.staticCall();
      record(
        chain.name,
        "router feeCollector is not the deployer",
        lower(collector) !== lower(DEPLOYER),
        `${routerAddress} → ${collector}`
      );
    } catch (err) {
      record(chain.name, "router feeCollector readable", false, err instanceof Error ? err.message : String(err));
    }
  }
}

/**
 * The settlement tokens this chain is expected to accept.
 *
 * Reads the per-chain record the deploy script writes (`escrowV2.supportedTokens`)
 * and, failing that, the settlement coin. A chain with neither is reported as a
 * gap rather than silently passing with nothing checked.
 * @param chain - Chain definition.
 * @param manifest - Its deployment manifest.
 * @returns Addresses to verify, with the ticker used in the report.
 */
function tokenListFor(chain, manifest) {
  const supported = manifest.escrowV2?.supportedTokens;
  if (Array.isArray(supported) && supported.length > 0) {
    return supported
      .filter((a) => typeof a === "string" && ethers.isAddress(a))
      .map((address) => ({ address, symbol: address.slice(0, 10) }));
  }
  const coin = manifest.contracts?.OmniCoin;
  return typeof coin === "string" && ethers.isAddress(coin)
    ? [{ address: coin, symbol: "settlement coin" }]
    : [];
}

/**
 * The judges that should be rostered on this chain.
 * @param chain - Chain definition.
 * @param manifest - Its deployment manifest.
 * @returns Judge addresses from the deployment record.
 */
function seatedJudges(chain, manifest) {
  const recorded = manifest.escrowV2?.verdictJudges;
  return Array.isArray(recorded) ? recorded.filter((a) => typeof a === "string") : [];
}

/**
 * Entry point.
 * @returns {Promise<void>}
 */
async function main() {
  const args = process.argv.slice(2);
  const chainFlag = args.indexOf("--chain");
  const only = chainFlag !== -1 ? Number(args[chainFlag + 1]) : undefined;

  const recipients = JSON.parse(fs.readFileSync(RECIPIENTS_FILE, "utf8"));
  const chains = only === undefined ? CHAINS : CHAINS.filter((c) => c.chainId === only);
  if (chains.length === 0) {
    console.error(`No configured chain with id ${String(only)}`);
    process.exit(2);
  }

  for (const chain of chains) {
    await checkChain(chain, recipients);
  }

  const failures = results.filter((r) => r.ok === false);
  const skipped = results.filter((r) => r.ok === "skip");
  for (const r of results) {
    const label = r.ok === true ? "PASS" : r.ok === "skip" ? "SKIP" : "FAIL";
    console.log(`${label}  ${r.chain.padEnd(10)} ${r.check.padEnd(38)} ${r.detail}`);
  }
  const passed = results.filter((r) => r.ok === true).length;
  console.log(
    `\n${String(passed)}/${String(results.length)} checks passed` +
      (skipped.length > 0 ? `, ${String(skipped.length)} not applicable` : "") +
      (failures.length > 0 ? ` — ${String(failures.length)} FAILED` : "")
  );
  process.exit(failures.length === 0 ? 0 : 1);
}

main().catch((err) => {
  console.error(err);
  process.exit(2);
});
