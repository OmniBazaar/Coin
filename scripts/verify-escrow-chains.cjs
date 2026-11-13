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
 *      the deployer account;
 *   6. every settlement token's arbitration floor equals its committed
 *      expectation in {@link FEE_FLOOR_EXPECTATIONS}, and is not zero.
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
 * Committed arbitration floors, per chain and per settlement token.
 *
 * SET 2026-11-13 (deployer-direct `setMinArbitrationFee`, no delay). The floors
 * are a FLOOR on the arbitration payout in token units, so each one is worth
 * the same few dollars across chains:
 *
 *   - stablecoins (USDC, USDT): 2.5 units of a US-dollar stable;
 *   - XOM: 600 XOM ≈ $2.40 at the reference price used for the policy (XOM
 *     $0.004) — the five XOM-settling chains all use this number;
 *   - WAVAX / WBNB: $2.50 of the wrapped native, computed from a live price
 *     when the floors were set (AVAX ≈ $8.06 → 0.31 WAVAX; BNB ≈ $625 → 0.004
 *     WBNB). Avalanche and BSC have no XOM token, so their primary coin is the
 *     wrapped native. A floor is a MINIMUM, so native appreciation only makes
 *     these stricter; re-derive if AVAX or BNB falls far below those prices.
 *
 * Why this table exists: the previous check reported "per-token fee floors" as
 * PASS unconditionally while iterating only the chain config's token list —
 * WAVAX/WBNB are allowlisted on their escrows without appearing in
 * `escrowV2.supportedTokens`, so a missing floor there was invisible. The
 * check now compares every configured token AND every token listed here against
 * the live `minArbitrationFee`, and fails on zero or on any drift.
 *
 * Keys are lower-case addresses (that is how they compare); the values are the
 * decimal string of the expected floor, in the token's own base units.
 */
const FEE_FLOOR_EXPECTATIONS = {
  // OmniCoin L1 — XOM settles, USDC is the allowlisted stable.
  88008: {
    "0x1ee61487f08f715055358a1f020a86c9e571ed78": { symbol: "XOM", floor: "600000000000000000000" },
    "0x81f4072fcca24d373ffcb34c248995dfc6c1219c": { symbol: "USDC", floor: "2500000" },
  },
  // Avalanche — BridgedXOM is the settlement coin, WAVAX the wrapped native.
  43114: {
    "0xaf72f6caf76775daeabaf5c82ce05d97359c8fa1": { symbol: "XOM", floor: "600000000000000000000" },
    "0xb31f66aa3c1e785363f0875a1b74e27b85fd66c7": { symbol: "WAVAX", floor: "310000000000000000" },
    "0xb97ef9ef8734c71904d8002f8b6bc66dd9c48a6e": { symbol: "USDC", floor: "2500000" },
  },
  // Ethereum — XOM + USDC.
  1: {
    "0x2e37f5a6d09d575e287a742062dafeeb1a0721a2": { symbol: "XOM", floor: "600000000000000000000" },
    "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48": { symbol: "USDC", floor: "2500000" },
  },
  // Arbitrum One — XOM + USDC.
  42161: {
    "0x79b7480feeb8fd4509993c78ef8dde9786fc9ded": { symbol: "XOM", floor: "600000000000000000000" },
    "0xaf88d065e77c8cc2239327c5edb3a432268e5831": { symbol: "USDC", floor: "2500000" },
  },
  // Base — XOM + USDC.
  8453: {
    "0x79b7480feeb8fd4509993c78ef8dde9786fc9ded": { symbol: "XOM", floor: "600000000000000000000" },
    "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913": { symbol: "USDC", floor: "2500000" },
  },
  // Polygon — XOM + USDC.
  137: {
    "0x4aa156f02bd5edd0c1ed2719e525998b4ba8fa17": { symbol: "XOM", floor: "600000000000000000000" },
    "0x3c499c542cef5e3811e1192ce70d8cc03d5c3359": { symbol: "USDC", floor: "2500000" },
  },
  // BNB Smart Chain — WBNB is the primary coin (no XOM token on BSC); USDC and
  // USDT both carry 18 decimals there, so both floors are 2.5e18.
  56: {
    "0xbb4cdb9cbd36b01bd1cbaebf2de08d9173bc095c": { symbol: "WBNB", floor: "4000000000000000" },
    "0x8ac76a51cc950d9822d68b83fe1ad97b32cd580d": { symbol: "USDC", floor: "2500000000000000000" },
    "0x55d398326f99059ff775485246999027b3197955": { symbol: "USDT", floor: "2500000000000000000" },
  },
};

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
    /** Escrow key in the deployment manifest. L1 cut over on 2026-11-09; the
     *  record-only 0x4602… build and MinimalEscrow are no longer the route. */
    escrowKey: "EscrowV2",
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
  // Deployed 2026-10-24 — the chains the Early LP mesh already runs on, so a
  // seller there can take escrowed payment without bridging the token.
  {
    chainId: 1,
    name: "Ethereum",
    deployment: "ethereum-mainnet.json",
    rpcEnv: "ETH_RPC_URL",
    rpcDefault: "https://ethereum.publicnode.com",
    escrowKey: "EscrowV2",
    routerKey: "OmniFeeRouter",
  },
  {
    chainId: 42161,
    name: "Arbitrum One",
    deployment: "arbitrum.json",
    rpcEnv: "ARBITRUM_RPC_URL",
    rpcDefault: "https://arbitrum-one-rpc.publicnode.com",
    escrowKey: "EscrowV2",
    routerKey: "OmniFeeRouter",
  },
  {
    chainId: 8453,
    name: "Base",
    deployment: "base.json",
    rpcEnv: "BASE_RPC_URL",
    rpcDefault: "https://base-rpc.publicnode.com",
    escrowKey: "EscrowV2",
    routerKey: "OmniFeeRouter",
  },
  {
    chainId: 137,
    name: "Polygon",
    deployment: "polygon.json",
    rpcEnv: "POLYGON_RPC_URL",
    rpcDefault: "https://polygon-bor-rpc.publicnode.com",
    escrowKey: "EscrowV2",
    routerKey: "OmniFeeRouter",
  },
  {
    chainId: 56,
    name: "BNB Smart Chain",
    deployment: "bsc.json",
    rpcEnv: "BSC_RPC_URL",
    rpcDefault: "https://bsc-dataseed.binance.org",
    escrowKey: "EscrowV2",
    routerKey: "OmniFeeRouter",
  },
];

const ESCROW_ABI = [
  "function supportedToken(address) view returns (bool)",
  "function verdictJudge(address) view returns (bool)",
  // The 2026-10 revision's settable fee schedule. Without these in the ABI the
  // "judges are paid" assertion below silently reports "no settable fee" and
  // every chain passes the check by skipping it.
  "function arbitrationFeeBps() view returns (uint256)",
  "function maxArbitrationFeeBps() view returns (uint256)",
  "function judgePoolBps2() view returns (uint256)",
  "function judgePoolBps3() view returns (uint256)",
  "function submitterBps2() view returns (uint256)",
  "function submitterBps3() view returns (uint256)",
  "function verdictJudgeCount() view returns (uint256)",
  // 2026-11-12 panel revision: an unbounded roster and three seats drawn per
  // dispute. The presence of these getters is how the check knows the deployed
  // escrow is the seat-aware build rather than the fixed-three one.
  "function getVerdictJudges(uint256,uint256) view returns (address[])",
  "function getPanel(uint256) view returns (address[3],uint8,uint64)",
  "function PANEL_SEATS() view returns (uint256)",
  "function SEAT_WINDOW_BLOCKS() view returns (uint256)",
  "function minArbitrationFee(address) view returns (uint256)",
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

  // 6. 🛑 THE ARBITRATION FEE ACTUALLY REACHES THE JUDGES.
  // The 2026-10 defect was not a missing sink but a SPLIT: the escrow asserted
  // the fee was paid, and the judges received zero. Fee sinks were checked;
  // fee SHARES were not, so a 100%-to-ODDAO split passed every check. This
  // reads the deployed schedule and fails loudly if a judge share is zero.
  if (escrow.arbitrationFeeBps !== undefined) {
    // A pre-2026-10 escrow has none of these; that is inapplicable, not a
    // failure — but the check must never hide a zero judge share on a new one.
    const preRevision = await escrow.verdictJudgeCount
      .staticCall()
      .then(() => false)
      .catch(() => true);
    if (preRevision) {
      record(chain.name, "arbitration fee split", "skip", "pre-2026-10 escrow (no settable fee)");
      // fall through to the next chain section
    } else {
    try {
      const [feeBps, maxOfAmount, pool2, pool3, sub2, sub3, judges] =
        await Promise.all([
          escrow.arbitrationFeeBps.staticCall(),
          escrow.maxArbitrationFeeBps.staticCall(),
          escrow.judgePoolBps2.staticCall(),
          escrow.judgePoolBps3.staticCall(),
          escrow.submitterBps2.staticCall(),
          escrow.submitterBps3.staticCall(),
          escrow.verdictJudgeCount.staticCall(),
        ]);
      const j2 = Number(pool2);
      const j3 = Number(pool3);
      const s2 = Number(sub2);
      const s3 = Number(sub3);
      // A judge share of zero is the exact 2026-10 defect: fail, never skip.
      record(chain.name, "verdict judges are paid", j2 > 0 && j3 > 0, `judge pools ${String(j2)} / ${String(j3)} bps`);
      record(
        chain.name,
        "fee split fits in 100%",
        j2 + s2 <= 10000 && j3 + s3 <= 10000 && 10000 - j2 - s2 >= 500 && 10000 - j3 - s3 >= 500,
        `2 judges: ${String(j2)}+${String(s2)}+${String(10000 - j2 - s2)} · 3 judges: ${String(j3)}+${String(s3)}+${String(10000 - j3 - s3)}`
      );
      record(
        chain.name,
        "arbitration fee is sane",
        Number(feeBps) > 0 && Number(feeBps) <= 1000 && Number(maxOfAmount) > 0 && Number(maxOfAmount) <= 5000,
        `fee ${String(feeBps)} bps, capped at ${String(maxOfAmount)} bps of the amount`
      );
      record(
        chain.name,
        "verdict roster can seat a panel",
        Number(judges) >= 3,
        `${String(judges)} rostered (at least 3 to seat a panel of 3)`
      );
      // 🛑 The seat-aware build must be the one deployed. A fixed-three escrow
      // passes every other check in this file and still cannot expand the
      // panel, so the absence of these getters is a FAILURE, never a skip.
      try {
        const [panelSeats, seatWindow, roster] = await Promise.all([
          escrow.PANEL_SEATS.staticCall(),
          escrow.SEAT_WINDOW_BLOCKS.staticCall(),
          escrow.getVerdictJudges.staticCall(0, 100),
        ]);
        record(
          chain.name,
          "seat-aware panel revision",
          Number(panelSeats) === 3 &&
            Number(seatWindow) === 256 &&
            Array.isArray(roster) &&
            roster.length === Number(judges),
          `seats ${String(panelSeats)} · window ${String(seatWindow)} blocks · roster enumerates ${String(Array.isArray(roster) ? roster.length : 0)}`
        );
      } catch (err) {
        record(
          chain.name,
          "seat-aware panel revision",
          false,
          `not the 2026-11-12 build: ${err instanceof Error ? err.message : String(err)}`
        );
      }
      } catch (err) {
        record(chain.name, "arbitration fee split readable", false, err instanceof Error ? err.message : String(err));
      }
    }
  } else {
    record(chain.name, "arbitration fee split", "skip", "escrow has no settable arbitration fee");
  }

  // 7. 🛑 THE PER-TOKEN ARBITRATION FLOORS ARE THE COMMITTED ONES.
  // This check used to record PASS unconditionally while iterating only the
  // chain config's token list — so a settlement token the allowlist accepts but
  // the config does not list (WAVAX on Avalanche, WBNB on BSC) could sit at a
  // floor of 0 forever, and a new token could be allowlisted with no floor, and
  // both would read as green. Now it compares against FEE_FLOOR_EXPECTATIONS and
  // fails on a zero floor as well as on drift.
  await checkFeeFloors(chain, escrow, tokens);

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
 * Assert the committed per-token arbitration floor on one escrow.
 *
 * Checks the union of the tokens the chain config lists and the tokens
 * {@link FEE_FLOOR_EXPECTATIONS} holds a floor for — the second set matters
 * because WAVAX and WBNB are allowlisted settlement coins that never appear in
 * `escrowV2.supportedTokens` (they sit in the primary-coin slot). An allowlisted
 * token with no committed floor is a FAILURE: it would settle arbitration at
 * whatever the chain drifted to, including zero.
 *
 * @param {object} chain - Chain definition from {@link CHAINS}.
 * @param {ethers.Contract} escrow - Escrow contract bound to a provider.
 * @param {Array<{address: string, symbol: string}>} tokens - Config token list.
 * @returns {Promise<void>}
 */
async function checkFeeFloors(chain, escrow, tokens) {
  const expected = FEE_FLOOR_EXPECTATIONS[chain.chainId];
  if (expected === undefined) {
    record(
      chain.name,
      "per-token fee floors",
      false,
      `no committed expectations for chain ${String(chain.chainId)} — add them to FEE_FLOOR_EXPECTATIONS`
    );
    return;
  }

  // Union, keyed lower-case: config tokens first (their manifest symbol is only
  // an address prefix), then any expectation token the config did not list.
  const wanted = new Map();
  for (const token of tokens) {
    wanted.set(lower(token.address), { address: token.address, symbol: null });
  }
  for (const [address, exp] of Object.entries(expected)) {
    if (!wanted.has(address)) wanted.set(address, { address, symbol: exp.symbol });
  }

  for (const [address, entry] of wanted) {
    const exp = expected[address];
    const label = exp !== undefined ? exp.symbol : entry.symbol ?? address.slice(0, 10);

    let supported;
    try {
      supported = await escrow.supportedToken.staticCall(entry.address);
    } catch {
      supported = undefined;
    }

    if (exp === undefined) {
      record(
        chain.name,
        `fee floor ${label}`,
        supported === true ? false : "skip",
        supported === true
          ? `${entry.address} is allowlisted but has NO committed floor — add it to FEE_FLOOR_EXPECTATIONS`
          : `${entry.address} not allowlisted and no committed floor — nothing to assert`
      );
      continue;
    }

    const want = BigInt(exp.floor);
    let actual;
    try {
      actual = await escrow.minArbitrationFee.staticCall(entry.address);
    } catch (err) {
      record(
        chain.name,
        `fee floor ${label}`,
        false,
        `expected ${exp.floor} · actual UNREADABLE (${err instanceof Error ? err.message : String(err)})`
      );
      continue;
    }
    record(
      chain.name,
      `fee floor ${label}`,
      supported === true && actual === want && actual > 0n,
      `expected ${exp.floor} · actual ${String(actual)}${supported === true ? "" : " (NOT allowlisted)"}`
    );
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
