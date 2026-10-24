#!/usr/bin/env node
/**
 * Push every qualified arbitrator all the way through to the escrow contracts.
 *
 * 🛑 THE GAP THIS CLOSES. Two different panels decide disputes, and joining one
 * does not join the other:
 *
 *   - the **OmniArbitration** pool on OmniCoin (chain 88008) — what the webapp's
 *     "Become a Dispute Judge" action joins, by staking XOM;
 *   - each **EscrowV2**'s own `verdictJudge` mapping — what decides whether a
 *     signed verdict on a frozen escrow counts. It is an admin-only mapping with
 *     no enumerator and no webapp surface.
 *
 * So a judge could register, pay the stake, be told they are a judge — and be
 * unable to sign a single verdict. That happened on 2026-10-24 with
 * omnibazaar_marketing. This script closes it permanently: the pool IS the
 * roster, and every run copies pool members onto every escrow chain.
 *
 * DESIGN RULES, deliberate:
 *   - **Add-only.** Removal stays an explicit admin decision: an automatic
 *     removal could silently shrink a panel to one judge, and a judge who is
 *     merely slow is not unqualified.
 *   - **The pool is the authority**, not a list in a file. `canBeArbitrator`
 *     filters out members who no longer qualify (withdrew stake, lost KYC).
 *   - **Idempotent.** A member already rostered costs one read, no gas.
 *   - **Bounded.** At most `MAX_ADDITIONS` per chain per run, so a runaway pool
 *     cannot burn the deployer's gas in one pass; the next run continues.
 *
 * Usage:
 *   node Coin/scripts/sync-verdict-judges.cjs              # sync every chain
 *   node Coin/scripts/sync-verdict-judges.cjs --dry-run    # print the plan
 *   node Coin/scripts/sync-verdict-judges.cjs --chain 43114
 *   EXTRA_VERDICT_JUDGES=0xabc,0xdef node …/sync-verdict-judges.cjs
 *
 * The signer comes from VERDICT_SYNC_PRIVATE_KEY, else the deployer key file
 * `~/.avalanche-cli/key/deployer.pk` (the same store the allowlist stepper uses).
 *
 * Exit codes: 0 = everything already correct or fixed; 1 = something failed.
 */

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { ethers } = require("ethers");

const ROOT = path.join(__dirname, "..");
const DEPLOYMENTS = path.join(ROOT, "deployments");

/** The canonical deployer — the only account these escrows accept admin writes from. */
const EXPECTED_ADMIN = "0x021868f2E3D49C059EF52B539AAa933B437e0321";

/** At most this many roster additions per chain per run. */
const MAX_ADDITIONS = 10;

/** Cap on how many pool slots are scanned (the array only grows by registration). */
const MAX_POOL_SCAN = 500;

/**
 * Chains to sync. Any chain whose manifest names an EscrowV2 is included; the
 * legacy OmniCoin `MinimalEscrow` is not, because it settles through its own
 * on-chain arbitrators and has no verdict roster at all.
 */
const CHAINS = [
  // The L1's decoupled escrow. The validator currently serves chain 88008
  // through the legacy `MinimalEscrow`, which has no verdict roster, but the
  // EscrowV2 at `0x4602…a84D` is deployed on the same chain and is what settles
  // a frozen escrow there — so its roster is synced too.
  { chainId: 88008, name: "OmniCoin", deployment: "mainnet.json", rpcEnv: "MAINNET_RPC_URL", rpcDefault: "https://rpc.omnicoin.net" },
  { chainId: 43114, name: "Avalanche", deployment: "avalanche.json", rpcEnv: "AVALANCHE_CCHAIN_RPC_URL", rpcDefault: "https://avalanche-c-chain-rpc.publicnode.com" },
  { chainId: 1, name: "Ethereum", deployment: "ethereum-mainnet.json", rpcEnv: "ETH_RPC_URL", rpcDefault: "https://ethereum.publicnode.com" },
  { chainId: 42161, name: "Arbitrum One", deployment: "arbitrum.json", rpcEnv: "ARBITRUM_RPC_URL", rpcDefault: "https://arbitrum-one-rpc.publicnode.com" },
  { chainId: 8453, name: "Base", deployment: "base.json", rpcEnv: "BASE_RPC_URL", rpcDefault: "https://base-rpc.publicnode.com" },
  { chainId: 137, name: "Polygon", deployment: "polygon.json", rpcEnv: "POLYGON_RPC_URL", rpcDefault: "https://polygon-bor-rpc.publicnode.com" },
  { chainId: 56, name: "BNB Smart Chain", deployment: "bsc.json", rpcEnv: "BSC_RPC_URL", rpcDefault: "https://bsc-dataseed.binance.org" },
];

/** The L1 panel whose pool defines the judge set. */
const L1 = { chainId: 88008, rpcEnv: "MAINNET_RPC_URL", rpcDefault: "https://rpc.omnicoin.net" };

/** Read-only view of the arbitration panel. */
const ARBITRATION_ABI = [
  "function arbitratorPoolSize() view returns (uint256)",
  "function arbitratorPool(uint256) view returns (address)",
  "function canBeArbitrator(address) view returns (bool)",
  "function isInArbitratorPool(address) view returns (bool)",
];

/** The escrow surface this script touches. */
const ESCROW_ABI = [
  "function admin() view returns (address)",
  "function verdictJudge(address) view returns (bool)",
  "function setVerdictJudge(address,bool)",
];

/**
 * Read a deployment manifest.
 * @param {string} file - Manifest filename inside `deployments/`.
 * @returns {object|undefined} Parsed manifest.
 */
function loadManifest(file) {
  const full = path.join(DEPLOYMENTS, file);
  if (!fs.existsSync(full)) return undefined;
  return JSON.parse(fs.readFileSync(full, "utf8"));
}

/**
 * Resolve the signer: explicit env key, else the deployer key file.
 * @returns {string} A 0x-prefixed private key.
 */
function signerKey() {
  const fromEnv = process.env.VERDICT_SYNC_PRIVATE_KEY;
  if (typeof fromEnv === "string" && fromEnv.trim() !== "") return fromEnv.trim();
  const file = path.join(os.homedir(), ".avalanche-cli", "key", "deployer.pk");
  if (!fs.existsSync(file)) {
    throw new Error(
      `no signer: set VERDICT_SYNC_PRIVATE_KEY or provide ${file}`,
    );
  }
  return `0x${fs.readFileSync(file, "utf8").trim()}`;
}

/**
 * Every qualified arbitrator in the L1 pool.
 *
 * Reading the pool is the whole point: a list in a file drifts from who
 * actually staked and passed KYC.
 * @param {ethers.JsonRpcProvider} provider - L1 provider.
 * @returns {Promise<{members: string[], skipped: Array<{address: string, reason: string}>}>}
 */
async function readQualifiedPool(provider) {
  const panel = new ethers.Contract(
    loadManifest("mainnet.json")?.contracts?.OmniArbitration ??
      "0x73d0Ea976850D2E8C0262255f1955B05973C0C38",
    ARBITRATION_ABI,
    provider,
  );
  const size = Number(await panel.arbitratorPoolSize());
  if (!Number.isFinite(size) || size <= 0) return { members: [], skipped: [] };
  const members = [];
  const skipped = [];
  for (let i = 0; i < Math.min(size, MAX_POOL_SCAN); i += 1) {
    const address = await panel.arbitratorPool(i);
    if (!ethers.isAddress(address)) continue;
    const pooled = await panel.isInArbitratorPool(address);
    if (!pooled) continue;
    // A pooled judge who no longer qualifies cannot be selected, so rostering
    // them would hand out a seat that cannot sign.
    const eligible = await panel.canBeArbitrator(address);
    if (!eligible) {
      skipped.push({ address, reason: "in pool but not currently qualified" });
      continue;
    }
    members.push(ethers.getAddress(address));
  }
  return { members, skipped };
}

/**
 * Sync one chain.
 * @param {object} chain - Chain definition.
 * @param {string[]} members - Qualified pool members to ensure are rostered.
 * @param {string[]} extras - Additional addresses to roster regardless of pool.
 * @param {boolean} dryRun - Report without writing.
 * @param {ethers.Wallet} wallet - Admin signer.
 * @returns {Promise<{added: string[], failed: string[], error?: string}>}
 */
async function syncChain(chain, members, extras, dryRun, wallet) {
  const manifest = loadManifest(chain.deployment);
  const escrowAddress = manifest?.contracts?.EscrowV2;
  if (typeof escrowAddress !== "string" || !ethers.isAddress(escrowAddress)) {
    return { added: [], failed: [], error: `${chain.deployment} names no EscrowV2` };
  }
  const rpcUrl = process.env[chain.rpcEnv] || chain.rpcDefault;
  const provider = new ethers.JsonRpcProvider(
    rpcUrl,
    { chainId: chain.chainId, name: chain.name },
    { staticNetwork: true },
  );
  const escrow = new ethers.Contract(escrowAddress, ESCROW_ABI, wallet.connect(provider));

  const admin = await escrow.admin();
  if (admin.toLowerCase() !== wallet.address.toLowerCase()) {
    return {
      added: [],
      failed: [],
      error: `signer ${wallet.address} is not the escrow admin (${admin})`,
    };
  }

  const wanted = [...new Set([...members, ...extras].map((a) => ethers.getAddress(a)))];
  const missing = [];
  for (const judge of wanted) {
    if (!(await escrow.verdictJudge(judge))) missing.push(judge);
  }
  if (missing.length === 0) {
    console.log(`  ${chain.name}: roster already complete (${String(wanted.length)} judges)`);
    return { added: [], failed: [] };
  }
  const batch = missing.slice(0, MAX_ADDITIONS);
  if (missing.length > batch.length) {
    console.log(
      `  ${chain.name}: ${String(missing.length)} missing, adding ${String(
        batch.length,
      )} this run (bounded by MAX_ADDITIONS)`,
    );
  }
  const added = [];
  const failed = [];
  for (const judge of batch) {
    if (dryRun) {
      console.log(`  ${chain.name}: DRY RUN would roster ${judge}`);
      continue;
    }
    try {
      const tx = await escrow.setVerdictJudge(judge, true);
      const receipt = await tx.wait();
      if (receipt === null || receipt.status !== 1) throw new Error("transaction failed");
      added.push(judge);
      console.log(`  ${chain.name}: rostered ${judge} — tx ${tx.hash}`);
    } catch (err) {
      failed.push(judge);
      console.error(
        `  ${chain.name}: FAILED to roster ${judge}: ${
          err instanceof Error ? err.message : String(err)
        }`,
      );
    }
  }
  return { added, failed };
}

async function main() {
  const args = process.argv.slice(2);
  const dryRun = args.includes("--dry-run");
  const chainFlag = args.indexOf("--chain");
  const only = chainFlag !== -1 ? Number(args[chainFlag + 1]) : undefined;
  const extras = (process.env.EXTRA_VERDICT_JUDGES ?? "")
    .split(",")
    .map((a) => a.trim())
    .filter((a) => a !== "");
  for (const extra of extras) {
    if (!ethers.isAddress(extra)) throw new Error(`EXTRA_VERDICT_JUDGES: not an address: ${extra}`);
  }

  const wallet = new ethers.Wallet(signerKey());
  if (wallet.address.toLowerCase() !== EXPECTED_ADMIN.toLowerCase()) {
    throw new Error(
      `refusing to run: signer ${wallet.address} is not the canonical deployer ${EXPECTED_ADMIN}`,
    );
  }

  const l1 = new ethers.JsonRpcProvider(
    process.env[L1.rpcEnv] || L1.rpcDefault,
    { chainId: L1.chainId, name: "OmniCoin" },
    { staticNetwork: true },
  );
  const { members, skipped } = await readQualifiedPool(l1);
  console.log(
    `qualified arbitrators in the L1 pool: ${String(members.length)}${
      extras.length > 0 ? ` (+${String(extras.length)} extra)` : ""
    }`,
  );
  for (const s of skipped) console.log(`  skipped ${s.address}: ${s.reason}`);

  const chains = only === undefined ? CHAINS : CHAINS.filter((c) => c.chainId === only);
  if (chains.length === 0) {
    console.error(`no configured chain with id ${String(only)}`);
    process.exitCode = 1;
    return;
  }

  let failures = 0;
  let additions = 0;
  for (const chain of chains) {
    try {
      const result = await syncChain(chain, members, extras, dryRun, wallet);
      if (result.error !== undefined) {
        console.error(`  ${chain.name}: ${result.error}`);
        failures += 1;
      }
      additions += result.added.length;
      failures += result.failed.length;
    } catch (err) {
      console.error(
        `  ${chain.name}: ${err instanceof Error ? err.message : String(err)}`,
      );
      failures += 1;
    }
  }
  console.log(
    `${dryRun ? "[dry run] " : ""}done — ${String(additions)} judge(s) added, ${String(
      failures,
    )} failure(s)`,
  );
  if (failures > 0) process.exitCode = 1;
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
