#!/usr/bin/env node
/**
 * check-update-registry-health.cjs — can we publish a release at all?
 *
 * WHY THIS EXISTS
 *   On 2026-11-26 a 1.0.17 release was built, signed for the stores, and could
 *   not be attested: UpdateRegistry had DEFAULT_ADMIN = the primary timelock
 *   only, and its single ODDAO signer was a shredded key. Nobody noticed when
 *   that happened — the discovery happened at release time, 30 minutes after the
 *   builds were done, and it costs two weeks of governance to undo.
 *
 *   So this asks the question continuously rather than at the worst moment:
 *   "with the keys the operator actually holds, could publishRelease succeed?"
 *   It is a pure read. It never signs and never writes.
 *
 * THE RULE
 *   publishRelease needs BOTH:
 *     (a) the caller holds DEFAULT_ADMIN_ROLE, and
 *     (b) `threshold` signatures from the CURRENT signer set.
 *   So a release is publishable only when at least one operator key is an admin
 *   AND at least `threshold` operator keys are in the signer set.
 *
 * USAGE
 *   node Coin/scripts/check-update-registry-health.cjs            # human report
 *   node Coin/scripts/check-update-registry-health.cjs --json     # machine
 *   node Coin/scripts/check-update-registry-health.cjs --quiet    # exit code only
 *
 *   Exit 0 = publishable, 1 = NOT publishable, 2 = could not read the chain.
 */

const { JsonRpcProvider, Contract, getAddress } = require("ethers");

const RPC = process.env.OB_L1_RPC ?? "https://rpc.omnicoin.net";
const CHAIN_ID = 88008;
const REGISTRY = "0xd8E2a242dd344BE4A61c3DdD4332717766EB648B";
const TIMELOCK = "0x4f78386cA05E333639151fe0508b21D893CaD222";
const DEFAULT_ADMIN = "0x" + "00".repeat(32);

/**
 * Addresses whose private keys the operator can actually produce. Kept as an
 * explicit list on purpose: "an EOA somewhere holds admin" is precisely the
 * false comfort that let this break. These are the founder's key folder plus
 * the timelock (which is not a key — it is listed so the report can say why a
 * timelock-only admin still blocks a release).
 */
const OPERATOR_KEYS = [
  { address: "0x68d002Bb315E8310c1344EeA707f9C36DdC33e1e", label: "successor (deployer.pk, founder's folder)" },
  { address: "0x021868f2E3D49C059EF52B539AAa933B437e0321", label: "retired deployer (.deployer-temp.pk, founder's folder)" },
  { address: "0x5169ce023c76f516710395bdad053d935c054aa2", label: "treasury (treasury.pk, founder's folder)" },
  { address: "0xEFc0015487b4fF046981bB427553496d14D0873A", label: "rick (rick.pk, founder's folder)" },
  { address: "0x062A30E755cC3633EeCd3cDa505725aa50ef222C", label: "president (president.pk, founder's folder)" },
];

const ABI = [
  "function hasRole(bytes32 role, address account) view returns (bool)",
  "function getSigners() view returns (address[])",
  "function signerThreshold() view returns (uint256)",
  "function getLatestVersion(string component) view returns (string)",
];

async function main() {
  const json = process.argv.includes("--json");
  const quiet = process.argv.includes("--quiet");

  const provider = new JsonRpcProvider(RPC, CHAIN_ID, { staticNetwork: true });
  const net = await provider.getNetwork();
  if (net.chainId !== BigInt(CHAIN_ID)) {
    console.error(`wrong chain: ${net.chainId}`);
    process.exit(2);
  }
  const registry = new Contract(REGISTRY, ABI, provider);

  let signers, threshold;
  try {
    [signers, threshold] = await Promise.all([registry.getSigners(), registry.signerThreshold()]);
  } catch (err) {
    if (!quiet) console.error(`cannot read the registry: ${err.message}`);
    process.exit(2);
  }

  const admins = [];
  for (const key of OPERATOR_KEYS) {
    if (await registry.hasRole(DEFAULT_ADMIN, key.address)) admins.push(key);
  }
  const timelockIsAdmin = await registry.hasRole(DEFAULT_ADMIN, TIMELOCK);

  const signerSet = signers.map((a) => getAddress(a));
  const knownSigners = OPERATOR_KEYS.filter((k) => signerSet.includes(getAddress(k.address)));
  const thr = Number(threshold);

  const canPublish = admins.length > 0 && knownSigners.length >= thr;

  let reason = "";
  if (admins.length === 0) {
    reason = timelockIsAdmin
      ? "DEFAULT_ADMIN is held only by the primary timelock — every grant or release needs a full governance cycle"
      : "no operator key holds DEFAULT_ADMIN and the timelock does not either";
  } else if (knownSigners.length < thr) {
    reason = `only ${knownSigners.length} of the required ${thr} signer signatures can be produced`;
  }

  const versions = {};
  for (const c of ["wallet", "mobile", "webapp"]) {
    versions[c] = await registry.getLatestVersion(c).catch(() => "?");
  }

  const report = {
    publishable: canPublish,
    reason,
    admins: admins.map((a) => a.label),
    timelockIsAdmin,
    signers: signerSet,
    threshold: thr,
    signersAvailableToOperator: knownSigners.map((k) => k.label),
    attestedVersions: versions,
  };

  if (json) {
    process.stdout.write(JSON.stringify(report, null, 2) + "\n");
  } else if (!quiet) {
    console.log(`UpdateRegistry ${REGISTRY} — can we publish? ${canPublish ? "YES" : "NO"}`);
    console.log(`  admins available to us: ${admins.length ? admins.map((a) => a.label).join(", ") : "none"}`);
    console.log(`  timelock also admin:    ${timelockIsAdmin}`);
    console.log(`  signer set:             [${signerSet.join(", ")}] threshold ${thr}`);
    console.log(`  signers we can sign with: ${knownSigners.length ? knownSigners.map((k) => k.label).join(", ") : "none"}`);
    console.log(`  attested versions:      wallet=${versions.wallet} mobile=${versions.mobile} webapp=${versions.webapp}`);
    if (!canPublish) console.log(`  BLOCKER: ${reason}`);
  }

  // A monitor that only alerts on a broken state is silent about the recovery;
  // print the offending line to the journal unconditionally so `--quiet` still
  // leaves a trail for the watchdog to page on.
  if (!canPublish) {
    console.error(`sentryAlert: release.registry.unpublishable - ${reason}`);
    process.exit(1);
  }
  process.exit(0);
}

main().catch((err) => {
  console.error(`check-update-registry-health: ${err instanceof Error ? err.message : String(err)}`);
  process.exit(2);
});
