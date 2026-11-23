#!/usr/bin/env node
/**
 * Finish the COTI side from Windows, with both keys local, so neither ever goes
 * to the server.
 *
 *   1. Move all but 1 COTI from the old deployer to the successor.
 *   2. Bind the settlement committee as the successor.
 *
 * Files, in the folder you run this from:
 *   deployer.pk   the OLD deployer key  (0x021868f2…)
 *   successor.pk  the successor key     (0x68d002…)
 *
 *   node .\finish-coti.mjs check   # read-only, needs no keys
 *   node .\finish-coti.mjs run     # does both steps, skipping anything done
 *
 * Safe to re-run: the sweep is skipped when the successor already has funds and
 * the committee call is skipped when a committee is already bound.
 */
import fs from "node:fs";
import path from "node:path";
import { ethers } from "ethers";

const RPC = process.env.COTI_RPC_URL || "https://mainnet.coti.io/rpc";
const CHAIN_ID = 2_632_500;
const PROXY = "0xf8b980dd9C4ea1d60304b1d842Fce74d5dBaEc86";
const OLD_DEPLOYER = "0x021868f2E3D49C059EF52B539AAa933B437e0321";
const SUCCESSOR = "0x68d002Bb315E8310c1344EeA707f9C36DdC33e1e";
const KEEP = ethers.parseEther("1");

const COMMITTEE_SIZE = 5;
const QUORUM_M = 4;
const SET = [
  "0x089948585d60Db0ddaE397f5bc78Bab212ACAD28",
  "0x88f67429e159725B455340dd7b8c5b793E634f63",
  "0xA511E4750F794299935d684BF8998CD4580BD30f",
  "0xBB24FF22bB1025700390A709430a997216F73725",
  "0xC54192D251beDE25F8C6b0983FdAB78eB38ee288",
];

const ABI = [
  "function hasRole(bytes32 role, address account) view returns (bool)",
  "function committeeSize() view returns (uint256)",
  "function quorumM() view returns (uint256)",
  "function eligibleSnapshotLength() view returns (uint256)",
  "function eligibleSnapshotSequence() view returns (uint256)",
  "function initializeV2(uint256 committeeSize_, uint256 quorumM_, address[] bootstrapSet, uint256 l1Block)",
];

function log(message) {
  console.log(`[coti] ${message}`);
}

function load(file, expected) {
  const full = path.join(process.cwd(), file);
  if (!fs.existsSync(full)) throw new Error(`missing ${full}`);
  const raw = fs.readFileSync(full, "utf8").trim();
  const wallet = new ethers.Wallet(raw.startsWith("0x") ? raw : `0x${raw}`);
  if (wallet.address.toLowerCase() !== expected.toLowerCase()) {
    throw new Error(`${file} derives ${wallet.address}, expected ${expected}`);
  }
  return wallet;
}

async function main() {
  const command = process.argv[2] || "check";
  const provider = new ethers.JsonRpcProvider(RPC, CHAIN_ID, { staticNetwork: true });
  const network = await provider.getNetwork();
  if (Number(network.chainId) !== CHAIN_ID) throw new Error(`chain ${network.chainId}, expected ${CHAIN_ID}`);

  const settlement = new ethers.Contract(PROXY, ABI, provider);
  const DEFAULT_ADMIN = "0x" + "00".repeat(32);

  const [oldBalance, newBalance, committeeSize, block] = await Promise.all([
    provider.getBalance(OLD_DEPLOYER),
    provider.getBalance(SUCCESSOR),
    settlement.committeeSize(),
    provider.getBlockNumber(),
  ]);

  log(`old deployer ${ethers.formatEther(oldBalance)} COTI`);
  log(`successor    ${ethers.formatEther(newBalance)} COTI`);
  log(`settlement committee size ${committeeSize}`);
  log(`successor holds the settlement admin role: ${await settlement.hasRole(DEFAULT_ADMIN, SUCCESSOR)}`);

  if (command === "check") {
    const movable = oldBalance > KEEP ? oldBalance - KEEP : 0n;
    log(`would move ${ethers.formatEther(movable)} COTI to the successor, keeping 1 COTI`);
    log(committeeSize === 0n ? "would bind the committee of 5 at quorum 4" : "committee already bound; would skip");
    log("check only; nothing signed");
    return;
  }
  if (command !== "run") throw new Error(`unknown command ${command}`);

  const fee = await provider.getFeeData();
  const gasPrice = fee.maxFeePerGas ?? fee.gasPrice ?? undefined;

  // Step 1: sweep, keeping 1 COTI plus a gas reserve.
  if (oldBalance > KEEP) {
    const deployer = load("deployer.pk", OLD_DEPLOYER).connect(provider);
    const gasLimit = 21_000n;
    const reserve = (gasPrice ?? 20_000_000_000n) * gasLimit;
    const value = oldBalance - KEEP - reserve;
    if (value <= 0n) throw new Error("nothing left to move after the gas reserve");
    log(`moving ${ethers.formatEther(value)} COTI to the successor (keeping 1 plus gas)`);
    const tx = await deployer.sendTransaction({ to: SUCCESSOR, value, gasLimit, gasPrice });
    log(`sweep sent ${tx.hash}`);
    const receipt = await tx.wait();
    if (!receipt || receipt.status !== 1) throw new Error(`sweep failed in ${tx.hash}`);
    log(`sweep mined in block ${receipt.blockNumber}`);
  } else {
    log("old deployer holds no excess COTI; skipping the sweep");
  }

  // Step 2: committee binding.
  if ((await settlement.committeeSize()) > 0n) {
    log("committee already bound; skipping");
  } else {
    const successor = load("successor.pk", SUCCESSOR).connect(provider);
    const signer = new ethers.Contract(PROXY, ABI, successor);
    const l1Block = await provider.getBlockNumber();
    log(`binding committee of ${SET.length} at quorum ${QUORUM_M}, l1 block ${l1Block}`);
    const tx = await signer.initializeV2(COMMITTEE_SIZE, QUORUM_M, SET, l1Block, {
      gasLimit: 2_000_000n,
      gasPrice,
    });
    log(`committee tx sent ${tx.hash}`);
    const receipt = await tx.wait();
    if (!receipt || receipt.status !== 1) throw new Error(`initializeV2 failed in ${tx.hash}`);
    log(`committee bound in block ${receipt.blockNumber}`);
  }

  log(`committee size now ${await settlement.committeeSize()}`);
  log(`quorum now ${await settlement.quorumM()}`);
  log(`eligible set size now ${await settlement.eligibleSnapshotLength()}`);
  log(`sequence now ${await settlement.eligibleSnapshotSequence()}`);
  log(`successor balance now ${ethers.formatEther(await provider.getBalance(SUCCESSOR))} COTI`);
  log("done. Rotation and expansion of the committee no longer need the admin key.");
}

main().catch((error) => {
  console.error(`[coti] FAILED: ${error.message}`);
  process.exit(1);
});
