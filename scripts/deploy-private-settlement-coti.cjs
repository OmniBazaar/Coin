#!/usr/bin/env node
/**
 * Deploy the replacement PrivateDEXSettlement on COTI mainnet (chain 2,632,500).
 *
 * Why: the live instance has the compromised deployer as its only DEFAULT_ADMIN
 * and its only SETTLER, and both fee recipients point at the deployer EOA. The
 * admin can authorise an implementation upgrade, so the key can replace the
 * settlement logic at will. COTI has no timelock, so the only way to remove that
 * authority is a new instance.
 *
 * Shape: UUPS implementation + ERC1967 proxy + initialize(admin, settlers,
 * liquidityPool, feeVault, trustedForwarder).
 *
 * Defaults are a dry plan. --send broadcasts. The script refuses to deploy if the
 * admin, a settler, or a fee recipient is the compromised deployer, if any address
 * fails its EIP-55 checksum, or if the artifact is older than its source.
 *
 * Environment:
 *   OB_RPC_URL     default https://mainnet.coti.io/rpc
 *   OB_KEY_FILE    default ~/.avalanche-cli/key/deployer-nopfx.pk
 *   OB_GAS_PRICE   default 10 gwei
 *
 *   node scripts/deploy-private-settlement-coti.cjs            # plan only
 *   node scripts/deploy-private-settlement-coti.cjs --send     # broadcast
 */
"use strict";

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { ethers } = require("ethers");

const RPC_URL = process.env.OB_RPC_URL || "https://mainnet.coti.io/rpc";
const CHAIN_ID = 2_632_500;

/** New admin: the cold deployer-successor. Never the compromised deployer. */
const ADMIN = "0x68d002Bb315E8310c1344EeA707f9C36DdC33e1e";
/** Settler: the escrow-relayer successor. The legacy settle path is deprecated. */
const SETTLERS = ["0x88f67429e159725B455340dd7b8c5b793E634f63"];
/** Fees: the cold successor, not the deployer EOA the live instance points at. */
const LIQUIDITY_POOL = "0x68d002Bb315E8310c1344EeA707f9C36DdC33e1e";
const FEE_VAULT = "0x68d002Bb315E8310c1344EeA707f9C36DdC33e1e";
const TRUSTED_FORWARDER = "0x0000000000000000000000000000000000000000";

/** The compromised key. Nothing in the new instance may point at it. */
const DEPLOYER = "0x021868f2E3D49C059EF52B539AAa933B437e0321";
/** The live instance being replaced. */
const LIVE = "0x1CF276D04257785062A6C7A99897F4913386E486";

/** Libraries the implementation links against, deployed on COTI. */
const LIBRARIES = {
  CommitteeAttestorLib: "0x782fB33b895B229AcCB34970E73840DcF07f4108",
};

const IMPL_ARTIFACT = path.join(__dirname, "..", "artifacts", "contracts", "privacy", "PrivateDEXSettlement.sol", "PrivateDEXSettlement.json");
const PROXY_ARTIFACT = path.join(__dirname, "..", "artifacts", "@openzeppelin", "contracts", "proxy", "ERC1967", "ERC1967Proxy.sol", "ERC1967Proxy.json");
const SOURCE = path.join(__dirname, "..", "contracts", "privacy", "PrivateDEXSettlement.sol");
const IS_MAINNET = new URL(RPC_URL).host === "mainnet.coti.io";
const STATE_FILE = path.join(__dirname, "..", "deployments", `private-settlement-coti${IS_MAINNET ? "" : "-rehearsal"}.json`);

function log(message) {
  console.log(`[coti-settlement] ${message}`);
}

function arg(flag) {
  const index = process.argv.indexOf(flag);
  return index === -1 ? null : process.argv[index + 1];
}

function checkAddress(label, address) {
  if (!ethers.isAddress(address)) throw new Error(`${label} is not an address: ${address}`);
  const canonical = ethers.getAddress(address.toLowerCase());
  if (canonical !== address) throw new Error(`${label} fails its checksum: ${address} should be ${canonical}`);
  return address;
}

function linkBytecode(artifact, libraries) {
  let hex = artifact.bytecode;
  const references = artifact.linkReferences || {};
  for (const file of Object.keys(references)) {
    for (const name of Object.keys(references[file])) {
      const address = libraries[name];
      if (!address) throw new Error(`artifact needs library ${name} but no address is configured`);
      checkAddress(name, address);
      for (const ref of references[file][name]) {
        const start = 2 + ref.start * 2;
        hex = hex.slice(0, start) + address.slice(2).toLowerCase() + hex.slice(start + ref.length * 2);
      }
    }
  }
  if (hex.includes("__$")) throw new Error("bytecode still contains an unlinked library placeholder");
  return hex;
}

function loadArtifact(file, label) {
  const artifact = JSON.parse(fs.readFileSync(file, "utf8"));
  if (!artifact.bytecode || artifact.bytecode === "0x") throw new Error(`${label} has no creation bytecode`);
  return artifact;
}

async function main() {
  const send = process.argv.includes("--send");

  const admin = checkAddress("admin", ADMIN);
  const settlers = SETTLERS.map((s) => checkAddress("settler", s));
  const liquidityPool = checkAddress("liquidityPool", LIQUIDITY_POOL);
  const feeVault = checkAddress("feeVault", FEE_VAULT);
  const forwarder = checkAddress("trustedForwarder", TRUSTED_FORWARDER);

  const forbidden = [admin, ...settlers, liquidityPool, feeVault];
  if (forbidden.some((a) => a.toLowerCase() === DEPLOYER.toLowerCase())) {
    throw new Error("a role or fee recipient is still the compromised deployer");
  }
  if (settlers.length === 0) throw new Error("initialize requires at least one settler");

  const implTime = fs.statSync(IMPL_ARTIFACT).mtimeMs;
  const sourceTime = fs.statSync(SOURCE).mtimeMs;
  if (sourceTime > implTime) throw new Error("PrivateDEXSettlement.sol is newer than its artifact; compile first");
  log(`artifact current: impl ${new Date(implTime).toISOString()}, source ${new Date(sourceTime).toISOString()}`);

  const impl = loadArtifact(IMPL_ARTIFACT, "implementation");
  const proxyArtifact = loadArtifact(PROXY_ARTIFACT, "proxy");
  const implIface = new ethers.Interface(impl.abi);
  const proxyIface = new ethers.Interface(proxyArtifact.abi);

  const provider = new ethers.JsonRpcProvider(RPC_URL, CHAIN_ID, { staticNetwork: true });
  const network = await provider.getNetwork();
  if (Number(network.chainId) !== CHAIN_ID) throw new Error(`connected to chain ${network.chainId}, expected ${CHAIN_ID}`);

  log(`chain ${CHAIN_ID}, block ${await provider.getBlockNumber()}`);
  log(`admin ${admin}`);
  log(`settlers ${settlers.join(", ")}`);
  log(`liquidity pool and fee vault ${liquidityPool}`);
  log(`trusted forwarder ${forwarder}`);

  if ((await provider.getCode(admin)) !== "0x") log("note: the admin address has code; expected a plain cold key");
  if ((await provider.getCode(LIVE)) === "0x") throw new Error(`the live settlement ${LIVE} has no code; wrong chain or wrong address`);

  const initializeData = implIface.encodeFunctionData("initialize", [admin, settlers, liquidityPool, feeVault, forwarder]);

  for (const [name, address] of Object.entries(LIBRARIES)) {
    if ((await provider.getCode(address)) === "0x") throw new Error(`library ${name} at ${address} has no code on chain ${CHAIN_ID}`);
  }
  const implBytecode = linkBytecode(impl, LIBRARIES);

  if (!send) {
    log("PLAN ONLY — no transaction sent. The plan is:");
    log(`  1. deploy the implementation (${(implBytecode.length - 2) / 2} bytes), linked against ${Object.keys(LIBRARIES).join(", ")}`);
    log(`  2. deploy ERC1967Proxy(implementation, initialize(...))`);
    log(`  3. verify admin, settlers, fee recipients and forwarder on the proxy`);
    log("rerun with --send to broadcast");
    return;
  }

  const keyFile = (arg("--key-file") || process.env.OB_KEY_FILE || path.join(os.homedir(), ".avalanche-cli", "key", "deployer-nopfx.pk")).replace(/^~/, os.homedir());
  const raw = fs.readFileSync(keyFile, "utf8").trim();
  const wallet = new ethers.Wallet(raw.startsWith("0x") ? raw : `0x${raw}`, provider);
  const from = await wallet.getAddress();
  const balance = await provider.getBalance(from);
  log(`signing as ${from}, balance ${ethers.formatEther(balance)} COTI`);
  if (balance === 0n) throw new Error("deployer holds no COTI for gas");

  const gasPrice = BigInt(process.env.OB_GAS_PRICE || "10000000000");

  log("deploying the implementation");
  const implTx = await wallet.sendTransaction({ data: implBytecode, gasLimit: 8_000_000n, gasPrice });
  const implReceipt = await implTx.wait();
  if (!implReceipt || implReceipt.status !== 1) throw new Error(`implementation deploy failed in ${implTx.hash}`);
  const implAddress = implReceipt.contractAddress;
  log(`implementation ${implAddress} in block ${implReceipt.blockNumber}`);

  log("deploying the proxy and initializing");
  const proxyData = ethers.concat([proxyArtifact.bytecode, proxyIface.encodeDeploy([implAddress, initializeData])]);
  const proxyTx = await wallet.sendTransaction({ data: proxyData, gasLimit: 6_000_000n, gasPrice });
  const proxyReceipt = await proxyTx.wait();
  if (!proxyReceipt || proxyReceipt.status !== 1) throw new Error(`proxy deploy failed in ${proxyTx.hash}`);
  const proxyAddress = proxyReceipt.contractAddress;
  log(`proxy ${proxyAddress} in block ${proxyReceipt.blockNumber}`);

  const deployed = new ethers.Contract(proxyAddress, impl.abi, provider);
  const adminRead = await deployed.hasRole("0x" + "00".repeat(32), admin);
  const recipients = await deployed.feeRecipients();
  const settlerRole = await deployed.SETTLER_ROLE();
  const settlerRead = await deployed.hasRole(settlerRole, settlers[0]);
  const forwarderRead = await deployed.trustedForwarder();

  log(`verify: admin holds default admin ${adminRead}`);
  log(`verify: liquidity pool ${recipients[0]}, fee vault ${recipients[1]}`);
  log(`verify: settler holds settler role ${settlerRead}`);
  log(`verify: trusted forwarder ${forwarderRead}`);

  if (!adminRead || !settlerRead) throw new Error("post-deploy verification failed");
  if (recipients[0].toLowerCase() === DEPLOYER.toLowerCase() || recipients[1].toLowerCase() === DEPLOYER.toLowerCase()) {
    throw new Error("post-deploy verification found a compromised fee recipient");
  }

  fs.mkdirSync(path.dirname(STATE_FILE), { recursive: true });
  fs.writeFileSync(
    STATE_FILE,
    JSON.stringify(
      {
        chainId: CHAIN_ID,
        rehearsal: !IS_MAINNET,
        proxy: proxyAddress,
        implementation: implAddress,
        admin,
        settlers,
        liquidityPool: recipients[0],
        feeVault: recipients[1],
        trustedForwarder: forwarderRead,
        replaces: LIVE,
        deployedAt: new Date().toISOString(),
        implTx: implTx.hash,
        proxyTx: proxyTx.hash,
        block: proxyReceipt.blockNumber,
      },
      null,
      2,
    ),
  );
  log(`recorded in ${STATE_FILE}`);
  log("next: repoint the client config from the old proxy to the new one, then retire the old instance");
}

main().catch((error) => {
  console.error(`[coti-settlement] FAILED: ${error.message}`);
  process.exit(1);
});
