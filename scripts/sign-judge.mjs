#!/usr/bin/env node
/**
 * Restart or complete the removal of the retired judge, from a Windows machine.
 *
 * Run it in the folder that holds your key file. By default it reads
 * .\deployer.pk; override with the DEPLOYER_KEY_FILE environment variable.
 *
 * It refuses to sign unless the loaded key is the CURRENT escrow admin, and it
 * tells you which address the key produced and which address is required. The
 * escrow admin is now the successor, not the old deployer.
 *
 *   node .\sign-judge.mjs status    # read-only, needs no key
 *   node .\sign-judge.mjs run       # signs what is needed, if anything
 *
 * Removal has two stages: setVerdictJudge(judge, false) starts a 48-hour clock,
 * then acceptJudgeRemoval() completes it after the clock. The script does
 * whichever stage is due, and running it twice is safe.
 */
import fs from "node:fs";
import path from "node:path";
import { ethers } from "ethers";

const RPC = process.env.OMNICOIN_RPC_URL || "https://rpc.omnicoin.net";
const CHAIN_ID = 88008;
const ESCROW = "0x7144B011ce241eecA38CD0c4948777B761985864";
const RETIRED_JUDGE = "0xB475206e51E99a4D4905751a02A12eA5E052B94d";
const GAS_PRICE = 2n;

const ABI = [
  "function admin() view returns (address)",
  "function pendingJudgeRemoval() view returns (address)",
  "function judgeRemovalAt() view returns (uint256)",
  "function verdictJudgeCount() view returns (uint256)",
  "function getVerdictJudges(uint256 offset, uint256 limit) view returns (address[])",
  "function setVerdictJudge(address judge, bool allowed)",
  "function acceptJudgeRemoval()",
];

function log(message) {
  console.log(`[judge] ${message}`);
}

async function state(escrow, provider) {
  const roster = Array.from(await escrow.getVerdictJudges(0, 50)).map((a) => ethers.getAddress(a));
  const pending = ethers.getAddress(await escrow.pendingJudgeRemoval());
  const removalAt = Number(await escrow.judgeRemovalAt());
  const block = await provider.getBlock("latest");
  return { roster, pending, removalAt, now: block.timestamp };
}

async function main() {
  const command = process.argv[2] || "status";
  if (!["status", "run"].includes(command)) throw new Error(`unknown command ${command}`);

  const provider = new ethers.JsonRpcProvider(RPC, CHAIN_ID, { staticNetwork: true });
  const network = await provider.getNetwork();
  if (Number(network.chainId) !== CHAIN_ID) throw new Error(`connected to chain ${network.chainId}, expected ${CHAIN_ID}`);

  const escrow = new ethers.Contract(ESCROW, ABI, provider);
  const admin = ethers.getAddress(await escrow.admin());
  const snapshot = await state(escrow, provider);
  const retired = ethers.getAddress(RETIRED_JUDGE);
  const seated = snapshot.roster.some((a) => a.toLowerCase() === retired.toLowerCase());

  log(`escrow admin ${admin}`);
  log(`retired judge seated: ${seated}`);
  log(`roster (${snapshot.roster.length}): ${snapshot.roster.join(", ")}`);

  if (!seated) {
    log("the retired judge is not on the roster; nothing to do");
    return;
  }

  if (snapshot.pending.toLowerCase() === retired.toLowerCase()) {
    const legalAt = new Date(snapshot.removalAt * 1000).toISOString();
    const secs = snapshot.removalAt - snapshot.now;
    log(`removal of ${retired} is pending; legal at ${legalAt}` + (secs > 0 ? ` (${Math.ceil(secs / 3600)} hours away)` : " (legal now)"));
  } else if (snapshot.pending === ethers.ZeroAddress) {
    log("no removal is pending");
  } else {
    log(`a DIFFERENT removal is pending: ${snapshot.pending} at ${new Date(snapshot.removalAt * 1000).toISOString()}`);
    log("refusing to overwrite another judge's pending removal");
    return;
  }

  if (command === "status") {
    log("status only; nothing signed. Run with \"run\" to act.");
    return;
  }

  const keyFile = (process.env.DEPLOYER_KEY_FILE || path.join(process.cwd(), "deployer.pk")).replace(/^~/, "");
  if (!fs.existsSync(keyFile)) throw new Error(`no key file at ${keyFile}`);
  const raw = fs.readFileSync(keyFile, "utf8").trim();
  const wallet = new ethers.Wallet(raw.startsWith("0x") ? raw : `0x${raw}`, provider);
  const me = await wallet.getAddress();

  if (me.toLowerCase() !== admin.toLowerCase()) {
    throw new Error(
      `the key at ${keyFile} derives ${me}, but the escrow admin is ${admin}. ` +
        "The escrow admin is now the successor, so this action needs the successor key.",
    );
  }
  log(`signing as the current escrow admin ${me}`);

  const signer = new ethers.Contract(ESCROW, ABI, wallet);

  if (snapshot.pending.toLowerCase() === retired.toLowerCase() && snapshot.removalAt <= snapshot.now) {
    const tx = await signer.acceptJudgeRemoval({ gasLimit: 300_000n, gasPrice: GAS_PRICE });
    log(`accept sent ${tx.hash}`);
    const receipt = await tx.wait();
    if (!receipt || receipt.status !== 1) throw new Error(`accept reverted in ${tx.hash}`);
    log(`accepted in block ${receipt.blockNumber}`);
  } else if (snapshot.pending === ethers.ZeroAddress) {
    const tx = await signer.setVerdictJudge(retired, false, { gasLimit: 300_000n, gasPrice: GAS_PRICE });
    log(`removal proposal sent ${tx.hash}`);
    const receipt = await tx.wait();
    if (!receipt || receipt.status !== 1) throw new Error(`proposal reverted in ${tx.hash}`);
    const legalAt = Number(await escrow.judgeRemovalAt());
    log(`proposed in block ${receipt.blockNumber}`);
    log(`acceptance becomes legal at ${new Date(legalAt * 1000).toISOString()}`);
    log("run this script again after that time, with the same key, to complete the removal");
  } else {
    log("the pending removal is not yet legal; nothing sent. Run again after the time above.");
  }

  const after = await state(escrow, provider);
  log(`roster now (${after.roster.length}): ${after.roster.join(", ")}`);
}

main().catch((error) => {
  console.error(`[judge] FAILED: ${error.message}`);
  process.exit(1);
});
