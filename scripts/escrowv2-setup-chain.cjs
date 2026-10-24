/**
 * Finish the escrow setup on ONE chain after scripts/deploy-escrowv2.cjs.
 *
 * The deploy script stops at "follow-ups, one admin call each" because the
 * settlement token and the judge roster are decisions, not deployment
 * mechanics. This is that step, idempotent, so it can be re-run after a partial
 * failure or run again when a judge is added:
 *
 *   1. allowlist the chain's USDC as a settlement token (XOM is already on the
 *      escrow's own allowlist by construction);
 *   2. roster the verdict judges — the same EOAs that sit on the L1
 *      arbitration panel, because a verdict is signed off-chain by a human and
 *      the escrow only checks that the signer is rostered HERE.
 *
 * 🛑 Both are admin writes for the CURRENT chain only. Nothing here is safe to
 * run blind against a chain whose manifest does not name an EscrowV2, so the
 * script refuses that case instead of guessing an address.
 *
 * Usage (one chain at a time):
 *   export MULTICHAIN_DEPLOYER_PRIVATE_KEY=0x$(cat ~/.avalanche-cli/key/deployer.pk)
 *   ESCROW_USDC=0x… npx hardhat run scripts/escrowv2-setup-chain.cjs --network polygon
 *
 * Optional:
 *   ESCROW_VERDICT_JUDGES="0x…,0x…"  (defaults to the three seated judges)
 *   ESCROW_DRY_RUN=1                 (read the state, change nothing)
 */
const path = require("path");
const fs = require("fs");
const hre = require("hardhat");

/** Manifest file per chain — must match scripts/deploy-escrowv2.cjs. */
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

/** The canonical deployer; every escrow deployment is administered by it. */
const EXPECTED_DEPLOYER = "0x021868f2E3D49C059EF52B539AAa933B437e0321";

/**
 * The three seated judges (founder accounts), used when the environment names
 * none. Two of them settle a case; the third is the check on the other two.
 */
const DEFAULT_JUDGES = [
  "0x213490a7C0E1681ad4239FBbE829994aeEecd193",
  "0xB475206e51E99a4D4905751a02A12eA5E052B94d",
  "0x824b6b38E7ab95d3Cb6B132481985BAc9BD52683",
];

/**
 * Read the escrow address for a chain from its deployment record.
 * @param {bigint} chainId - Chain being set up.
 * @returns {{file: string, escrow: string}} Manifest path and escrow address.
 */
function loadEscrow(chainId) {
  const name = MANIFESTS[chainId];
  if (!name) throw new Error(`no manifest name for chain ${chainId}`);
  const file = path.join(__dirname, "..", "deployments", `${name}.json`);
  if (!fs.existsSync(file)) throw new Error(`manifest missing: ${file}`);
  const json = JSON.parse(fs.readFileSync(file, "utf8"));
  const escrow = json?.contracts?.EscrowV2;
  if (typeof escrow !== "string" || !hre.ethers.isAddress(escrow)) {
    throw new Error(`${file} names no deployed EscrowV2 — deploy it first`);
  }
  return { file, escrow };
}

async function main() {
  const { ethers } = hre;
  const [deployer] = await ethers.getSigners();
  if (deployer.address.toLowerCase() !== EXPECTED_DEPLOYER.toLowerCase()) {
    throw new Error(`wrong signer: ${deployer.address} is not ${EXPECTED_DEPLOYER}`);
  }
  const network = await ethers.provider.getNetwork();
  const { file, escrow: escrowAddress } = loadEscrow(network.chainId);
  console.log("=== escrow setup on chain", network.chainId.toString(), "===");
  console.log("manifest:", file);
  console.log("escrow  :", escrowAddress);

  const escrow = await ethers.getContractAt("EscrowV2", escrowAddress);
  if ((await escrow.admin()).toLowerCase() !== deployer.address.toLowerCase()) {
    throw new Error("this escrow's admin is not the deployer — refusing to write");
  }

  const usdc = process.env.ESCROW_USDC || "";
  if (!ethers.isAddress(usdc)) {
    throw new Error("ESCROW_USDC must be the settlement stablecoin on this chain");
  }
  const judgesRaw = process.env.ESCROW_VERDICT_JUDGES;
  const judges = (judgesRaw ? judgesRaw.split(",") : DEFAULT_JUDGES)
    .map((a) => a.trim())
    .filter((a) => a !== "");
  for (const judge of judges) {
    if (!ethers.isAddress(judge)) throw new Error(`not an address: ${judge}`);
  }
  if (judges.length < 2) throw new Error("at least two judges are required");
  const dryRun = process.env.ESCROW_DRY_RUN === "1";

  // ── Settlement token ───────────────────────────────────────────────────
  const alreadyAllowed = await escrow.supportedToken(usdc);
  if (alreadyAllowed) {
    console.log("USDC already allowlisted:", usdc);
  } else if (dryRun) {
    console.log("DRY RUN — would allowlist USDC", usdc);
  } else {
    const tx = await escrow.setSupportedToken(usdc, true);
    await tx.wait();
    console.log("allowlisted USDC:", usdc, "tx:", tx.hash);
  }

  // ── Judge roster ───────────────────────────────────────────────────────
  for (const judge of judges) {
    const rostered = await escrow.verdictJudge(judge);
    if (rostered) {
      console.log("judge already rostered:", judge);
      continue;
    }
    if (dryRun) {
      console.log("DRY RUN — would roster judge", judge);
      continue;
    }
    const tx = await escrow.setVerdictJudge(judge, true);
    await tx.wait();
    console.log("rostered judge:", judge, "tx:", tx.hash);
  }

  // ── Read back, from the contract ───────────────────────────────────────
  const code = await ethers.provider.getCode(escrowAddress);
  console.log("\n-- verified on chain --");
  console.log("escrow bytes    :", (code.length - 2) / 2);
  console.log("OMNI_COIN       :", await escrow.OMNI_COIN());
  console.log("MARKETPLACE_FEE :", (await escrow.MARKETPLACE_FEE_BPS()).toString(), "bps");
  console.log("USDC allowed    :", await escrow.supportedToken(usdc));
  for (const judge of judges) {
    console.log("judge           :", judge, await escrow.verdictJudge(judge));
  }
  console.log("\nDONE");
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
