#!/usr/bin/env node
/**
 * Deploy a replacement EmergencyGuardian.
 *
 * Why a replacement: the live guardian's TIMELOCK immutable is the SECOND
 * timelock, where the deployer holds proposer/executor/admin, and its guardian set
 * is the deployer plus four placeholder addresses. Its pausable registry is empty.
 * The replacement points at the PRIMARY timelock, so guardian changes and pausable
 * registrations are governance actions.
 *
 * The constructor takes (timelock, initialGuardians[5]). It does NOT take pausable
 * targets: registration is onlyTimelock, so it is part of the governance batch in
 * governance-pause-and-guardian.mjs.
 *
 * Default is SIMULATE. Nothing is sent without --send, and --send refuses the
 * retired deployer key unless --i-understand-retired-key is also passed.
 *
 *   node scripts/deploy-emergency-guardian.cjs                    # simulate
 *   node scripts/deploy-emergency-guardian.cjs --send \
 *        --key-file ~/.avalanche-cli/key/deployer-nopfx.pk --i-understand-retired-key
 */
"use strict";

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { ethers } = require("ethers");

const RPC_URL = process.env.OMNICOIN_RPC_URL || "https://rpc.omnicoin.net";
const CHAIN_ID = 88008;
const GAS_PRICE = BigInt(process.env.OB_GAS_PRICE_WEI || "2");

const PRIMARY_TIMELOCK = "0x4f78386cA05E333639151fe0508b21D893CaD222";
const OLD_GUARDIAN = "0x60752E5762C4eC606730bad3806a1139825BC2e6";

/** The five agreed signers: marketing, president, rick, and the two new wallets. */
const SIGNERS = [
  "0x824b6b38E7ab95d3Cb6B132481985BAc9BD52683", // marketing
  "0x062A30E755cC3633EeCd3cDa505725aa50ef222C", // president
  "0xEFc0015487b4fF046981bB427553496d14D0873A", // rick
  "0xCD7535F841A0FA884534D3Aad312b57B747b9957", // new signer A
  "0x0c734cB4D875Bb94e4AB95a590552d71DF56f09F", // new signer B
];

/** Addresses whose keys were copied on 2026-11-15. */
const RETIRED_FILE = path.join(__dirname, "..", "..", "Validator", "scripts", "lib", "retired-signers.json");
const RETIRED = new Set(
  Object.keys(JSON.parse(fs.readFileSync(RETIRED_FILE, "utf8"))).map((address) => address.toLowerCase()),
);

const ARTIFACT = path.join(
  __dirname,
  "..",
  "artifacts",
  "contracts",
  "EmergencyGuardian.sol",
  "EmergencyGuardian.json",
);
const SOURCE = path.join(__dirname, "..", "contracts", "EmergencyGuardian.sol");
const STATE_FILE = path.join(__dirname, "..", "deployments", "emergency-guardian.json");

function arg(flag) {
  const index = process.argv.indexOf(flag);
  return index === -1 ? null : process.argv[index + 1];
}

function log(message) {
  console.log(`[deploy-guardian] ${message}`);
}

async function main() {
  const send = process.argv.includes("--send");
  const timelock = ethers.getAddress(arg("--timelock") || PRIMARY_TIMELOCK);
  const signers = (arg("--signers") ? arg("--signers").split(",") : SIGNERS).map((s) => ethers.getAddress(s.trim()));

  if (signers.length !== 5) throw new Error(`need exactly 5 guardians, got ${signers.length}`);
  if (new Set(signers.map((s) => s.toLowerCase())).size !== 5) throw new Error("duplicate guardian address");

  const artifact = JSON.parse(fs.readFileSync(ARTIFACT, "utf8"));
  // The artifact must be newer than the source, or it may not reflect the code we
  // reviewed. Run "npm run compile" in Coin/ first if this trips.
  const artifactTime = fs.statSync(ARTIFACT).mtimeMs;
  const sourceTime = fs.statSync(SOURCE).mtimeMs;
  if (sourceTime > artifactTime) {
    throw new Error(
      `contracts/EmergencyGuardian.sol is newer than its artifact; run "npm run compile" in Coin/ before deploying`,
    );
  }
  log(`artifact ${new Date(artifactTime).toISOString()}, source ${new Date(sourceTime).toISOString()} — artifact is current`);
  if (!artifact.bytecode || artifact.bytecode === "0x") throw new Error(`no creation bytecode in ${ARTIFACT}`);

  const iface = new ethers.Interface(artifact.abi);
  const deployData = ethers.concat([
    artifact.bytecode,
    iface.encodeDeploy([timelock, signers]),
  ]);

  const provider = new ethers.JsonRpcProvider(RPC_URL, CHAIN_ID, { staticNetwork: true });
  const block = await provider.getBlockNumber();

  log(`chain ${CHAIN_ID} at block ${block}`);
  log(`timelock ${timelock}`);
  for (const signer of signers) log(`  guardian ${signer}`);

  if ((await provider.getCode(timelock)) === "0x") throw new Error(`timelock ${timelock} has no code`);
  if (timelock.toLowerCase() === PRIMARY_TIMELOCK.toLowerCase()) {
    log("timelock is the primary timelock: guardian changes will be governance-only (intended)");
  } else {
    log("WARNING — timelock is not the primary timelock; record why before sending");
  }

  for (const signer of signers) {
    const [code, nonce] = await Promise.all([
      provider.getCode(signer),
      provider.getTransactionCount(signer),
    ]);
    if (code !== "0x") throw new Error(`guardian ${signer} has bytecode; a guardian must be a plain key`);
    log(`  ${signer} fresh: no code, nonce ${nonce}`);
  }

  // Simulate the creation call. A revert here means the deploy would revert.
  await provider.call({ data: deployData });
  log("simulation passed: construction does not revert");

  const origin = arg("--from") || process.env.OB_DEPLOY_FROM;
  if (origin) {
    const predicted = ethers.getCreateAddress({
      from: ethers.getAddress(origin),
      nonce: await provider.getTransactionCount(ethers.getAddress(origin)),
    });
    log(`would deploy at ${predicted} if sent from ${origin}`);
  } else {
    log("deployment address depends on the sending key; pass --from or OB_DEPLOY_FROM to predict it");
  }

  if (!send) {
    log("SIMULATION ONLY — rerun with --send to broadcast");
    return;
  }

  const keyFile = arg("--key-file") || path.join(os.homedir(), ".avalanche-cli", "key", "deployer-nopfx.pk");
  const key = fs.readFileSync(keyFile.replace(/^~/, os.homedir()), "utf8").trim();
  const wallet = new ethers.Wallet(key.startsWith("0x") ? key : `0x${key}`, provider);
  const from = await wallet.getAddress();
  const isRetired = RETIRED.has(from.toLowerCase());

  log(`signing as ${from}${isRetired ? " (RETIRED KEY — copied on 2026-11-15)" : ""}`);
  if (isRetired && !process.argv.includes("--i-understand-retired-key")) {
    throw new Error(
      "this key is on the retired-signers list. The guardian hands all authority to the timelock and holds no funds, " +
        "so using it for this deployment is acceptable, but it must be a deliberate choice: pass --i-understand-retired-key.",
    );
  }

  const balance = await provider.getBalance(from);
  log(`native balance ${ethers.formatEther(balance)}`);
  if (balance === 0n) throw new Error("deployer holds no native XOM for gas");

  const tx = await wallet.sendTransaction({ data: deployData, gasLimit: 3_000_000n, gasPrice: GAS_PRICE });
  log(`deploy sent ${tx.hash}`);
  const receipt = await tx.wait();
  if (receipt === null || receipt.status !== 1) throw new Error(`deploy reverted in ${tx.hash}`);

  const guardian = receipt.contractAddress;
  const deployed = new ethers.Contract(guardian, artifact.abi, provider);
  const guardianCount = await deployed.guardianCount();
  const pausableCount = await deployed.pausableCount();
  const deployedTimelock = await deployed.TIMELOCK();

  log(`deployed ${guardian} in block ${receipt.blockNumber}`);
  log(`  guardianCount ${guardianCount}, pausableCount ${pausableCount}, TIMELOCK ${deployedTimelock}`);
  log(`  old guardian ${OLD_GUARDIAN} still holds its roles until the governance batch runs`);

  fs.writeFileSync(
    STATE_FILE,
    JSON.stringify(
      {
        guardian,
        timelock: deployedTimelock,
        signers,
        deployedAt: new Date().toISOString(),
        block: receipt.blockNumber,
        txHash: tx.hash,
        pausableTargets: [],
      },
      null,
      2,
    ),
  );
  log(`recorded in ${STATE_FILE}`);
  log("next: edit CODE_NOTES in governance-pause-and-guardian.mjs if needed, then run its status command");
}

main().catch((error) => {
  console.error(`[deploy-guardian] FAILED: ${error.message}`);
  process.exit(1);
});
