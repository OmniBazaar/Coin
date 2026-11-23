#!/usr/bin/env node
/**
 * Bind the committee on the replacement COTI private settlement, from Windows.
 *
 * Run it in the folder that holds your key file. By default it reads
 * .\deployer.pk; override with DEPLOYER_KEY_FILE. The key must be the CURRENT
 * settlement admin, which is the cold successor.
 *
 *   node .\sign-committee.mjs status    # read-only, no key needed
 *   node .\sign-committee.mjs run       # performs the one-time committee binding
 *
 * The set below is five fresh ceremony keys that were never installed anywhere:
 * perps-liquidator, escrow-relayer, judge, icm-relayer, verification-signer, in
 * the ascending order the contract requires. Size 5, quorum 4.
 *
 * After this call, the committee can rotate or expand WITHOUT the admin key:
 * pushEligibleSetUpdate accepts a new sorted set carrying four signatures from
 * the current set. Only the size/quorum parameters and the seed-pinning latch
 * remain admin-only.
 */
import fs from "node:fs";
import path from "node:path";
import { ethers } from "ethers";

const RPC = process.env.COTI_RPC_URL || "https://mainnet.coti.io/rpc";
const CHAIN_ID = 2_632_500;
const PROXY = "0xf8b980dd9C4ea1d60304b1d842Fce74d5dBaEc86";
const ADMIN = "0x68d002Bb315E8310c1344EeA707f9C36DdC33e1e";

const COMMITTEE_SIZE = 5;
const QUORUM_M = 4;
const SET = [
  "0x089948585d60Db0ddaE397f5bc78Bab212ACAD28", // perps-liquidator
  "0x88f67429e159725B455340dd7b8c5b793E634f63", // escrow-relayer
  "0xA511E4750F794299935d684BF8998CD4580BD30f", // judge
  "0xBB24FF22bB1025700390A709430a997216F73725", // icm-relayer
  "0xC54192D251beDE25F8C6b0983FdAB78eB38ee288", // verification-signer
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
  console.log(`[committee] ${message}`);
}

function checkAddress(label, address) {
  if (!ethers.isAddress(address)) throw new Error(`${label} is not an address: ${address}`);
  const canonical = ethers.getAddress(address.toLowerCase());
  if (canonical !== address) throw new Error(`${label} fails its checksum: ${address} should be ${canonical}`);
  return address;
}

async function main() {
  const command = process.argv[2] || "status";
  if (!["status", "run"].includes(command)) throw new Error(`unknown command ${command}`);

  SET.forEach((a) => checkAddress("committee member", a));
  for (let i = 1; i < SET.length; i += 1) {
    if (BigInt(SET[i]) <= BigInt(SET[i - 1])) throw new Error("committee set is not ascending");
  }

  const provider = new ethers.JsonRpcProvider(RPC, CHAIN_ID, { staticNetwork: true });
  const network = await provider.getNetwork();
  if (Number(network.chainId) !== CHAIN_ID) throw new Error(`connected to chain ${network.chainId}, expected ${CHAIN_ID}`);

  const settlement = new ethers.Contract(PROXY, ABI, provider);
  const DEFAULT_ADMIN = "0x" + "00".repeat(32);
  const successorIsAdmin = await settlement.hasRole(DEFAULT_ADMIN, ADMIN);
  const size = Number(await settlement.committeeSize());

  log(`settlement ${PROXY}`);
  log(`successor holds the admin role: ${successorIsAdmin}`);
  log(`committee size ${size}`);
  if (size > 0) {
    log(`quorum ${await settlement.quorumM()}, eligible set size ${await settlement.eligibleSnapshotLength()}, sequence ${await settlement.eligibleSnapshotSequence()}`);
    log("committee already bound; nothing to do");
    return;
  }

  const block = await provider.getBlockNumber();
  log(`committee would be bound to ${SET.length} members with quorum ${QUORUM_M}, l1 block ${block}`);
  SET.forEach((a) => log(`  ${a}`));

  if (command === "status") {
    log("status only; nothing signed. Run with \"run\" to bind the committee.");
    return;
  }

  const keyFile = (process.env.DEPLOYER_KEY_FILE || path.join(process.cwd(), "deployer.pk")).replace(/^~/, "");
  if (!fs.existsSync(keyFile)) throw new Error(`no key file at ${keyFile}`);
  const raw = fs.readFileSync(keyFile, "utf8").trim();
  const wallet = new ethers.Wallet(raw.startsWith("0x") ? raw : `0x${raw}`, provider);
  const me = await wallet.getAddress();
  if (!(await settlement.hasRole(DEFAULT_ADMIN, me))) {
    throw new Error(`the key at ${keyFile} derives ${me}, which does not hold the settlement admin role`);
  }
  if (!successorIsAdmin) throw new Error(`the recorded successor ${ADMIN} does not hold the admin role; stopping`);
  log(`signing as the settlement admin ${me}`);

  const signer = new ethers.Contract(PROXY, ABI, wallet);
  const fee = await provider.getFeeData();
  const gasPrice = fee.maxFeePerGas ?? fee.gasPrice ?? undefined;

  log("binding the committee");
  const tx = await signer.initializeV2(COMMITTEE_SIZE, QUORUM_M, SET, block, { gasLimit: 2_000_000n, gasPrice });
  log(`sent ${tx.hash}`);
  const receipt = await tx.wait();
  if (!receipt || receipt.status !== 1) throw new Error(`initializeV2 reverted in ${tx.hash}`);

  log(`mined in block ${receipt.blockNumber}`);
  log(`committee size ${await settlement.committeeSize()}`);
  log(`quorum ${await settlement.quorumM()}`);
  log(`eligible set size ${await settlement.eligibleSnapshotLength()}`);
  log(`sequence ${await settlement.eligibleSnapshotSequence()}`);
  log("committee binding complete. Rotation no longer needs this key.");
}

main().catch((error) => {
  console.error(`[committee] FAILED: ${error.message}`);
  process.exit(1);
});
