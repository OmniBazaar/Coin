/**
 * Deploy EscrowV2 to OmniCoin L1 mainnet (chain 88008).
 *
 * EscrowV2 is a FRESH contract, never an upgrade: v1 `MinimalEscrow` stays live
 * for in-flight escrows (30-day maximum duration) while new escrows use this
 * instance. Run order matters — the constructor allowlist call and the dispute
 * path both depend on state that must already exist:
 *
 *   1. deploy EscrowV2 (omniCoin, privateOmniCoin, registry, feeVault, 100 bps,
 *      OmniForwarder)
 *   2. grant DEPOSITOR_ROLE on UnifiedFeeVault to the new escrow (fee split)
 *   3. seed at least one arbitrator, or `revealDispute` reverts and an internal
 *      dispute can never be resolved
 *   4. re-read deployed state and verify the constructor arguments
 *   5. write the address into Coin/deployments/mainnet.json
 *
 * Preflight probes every external selector the contract calls on an
 * already-deployed address, because a counterparty compiled from an older
 * commit can silently lack it (the deploy runbook records a router incident
 * caused by exactly that).
 *
 * Usage (the key is read from the file, never printed):
 *   MAINNET_DEPLOYER_PRIVATE_KEY=$(cat ~/.avalanche-cli/key/deployer.pk) \
 *     npx hardhat run scripts/deploy-escrowv2.cjs --network mainnet
 */
const fs = require("fs");
const path = require("path");
const hre = require("hardhat");

/** The only key permitted to sign a mainnet deploy (Pioneer-phase admin). */
const EXPECTED_DEPLOYER = "0x021868f2E3D49C059EF52B539AAa933B437e0321";

/** Canonical 1% marketplace fee, pinned by the constructor. */
const MARKETPLACE_FEE_BPS = 100n;

/** Deployment manifest, updated in place. */
const MANIFEST = path.join(__dirname, "..", "deployments", "mainnet.json");

/**
 * Resolve the deployment manifest's `contracts` map.
 * @returns {Record<string, string>} Contract name → address.
 */
function loadContracts() {
  const json = JSON.parse(fs.readFileSync(MANIFEST, "utf8"));
  return json;
}

/**
 * Probe one selector on a deployed address.
 * @param {object} provider - ethers provider.
 * @param {string} to - Contract address.
 * @param {string} signature - Human-readable function signature.
 * @param {string[]} args - ABI-encoded argument types rendered as zero values.
 * @returns {Promise<boolean>} True when the selector exists.
 */
async function selectorExists(provider, to, signature, args) {
  const { ethers } = hre;
  const iface = new ethers.Interface([`function ${signature}`]);
  const fragment = iface.getFunction(signature.split("(")[0]);
  const data = iface.encodeFunctionData(fragment, args);
  try {
    await provider.call({ to, data });
    return true;
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    // A revert from the function body still proves the selector exists.
    if (/reverted|execution reverted/i.test(message)) return true;
    return false;
  }
}

async function main() {
  const { ethers } = hre;
  const [deployer] = await ethers.getSigners();

  console.log("=== EscrowV2 mainnet deployment ===");
  console.log("deployer:", deployer.address);
  if (deployer.address.toLowerCase() !== EXPECTED_DEPLOYER.toLowerCase()) {
    throw new Error(
      `Refusing to deploy: signer ${deployer.address} is not the canonical deployer ${EXPECTED_DEPLOYER}`,
    );
  }
  const network = await ethers.provider.getNetwork();
  if (network.chainId !== 88008n) {
    throw new Error(`Wrong chain: ${network.chainId}, expected 88008`);
  }
  console.log("gas balance:", ethers.formatEther(await ethers.provider.getBalance(deployer.address)), "XOM");

  const manifest = loadContracts();
  const c = manifest.contracts;
  const omniCoin = c.OmniCoin;
  const privateOmniCoin = c.PrivateOmniCoin;
  const registry = c.OmniRegistration;
  const feeVault = c.UnifiedFeeVault;
  const forwarder = c.OmniForwarder;
  const v1Escrow = c.MinimalEscrow;
  for (const [name, addr] of Object.entries({ omniCoin, privateOmniCoin, registry, feeVault, forwarder })) {
    if (!addr || !ethers.isAddress(addr)) throw new Error(`manifest missing ${name}`);
  }

  // ── Preflight: every external selector EscrowV2 calls must exist ────────
  console.log("\n-- selector probes --");
  const probes = [
    [feeVault, "supportedPaymentTokens(address)", [omniCoin], "vault allowlist read"],
    [feeVault, "depositMarketplaceFee(address,uint256,address,address,address,address)", [omniCoin, 1n, ethers.ZeroAddress, ethers.ZeroAddress, ethers.ZeroAddress, ethers.ZeroAddress], "vault fee deposit"],
    [feeVault, "DEPOSITOR_ROLE()", [], "vault role constant"],
    [feeVault, "grantRole(bytes32,address)", [ethers.ZeroHash, ethers.ZeroAddress], "vault role grant"],
    [registry, "hasCompletedFirstSale(address)", [ethers.ZeroAddress], "registry first-sale read"],
    [registry, "markFirstSaleCompleted(address,uint256,address)", [ethers.ZeroAddress, 1n, ethers.ZeroAddress], "registry first-sale write"],
  ];
  for (const [to, sig, args, label] of probes) {
    const ok = await selectorExists(ethers.provider, to, sig, args);
    console.log(`${ok ? "OK  " : "MISS"} ${label.padEnd(24)} ${sig}`);
    if (!ok) throw new Error(`Missing selector on ${to}: ${sig}`);
  }

  // ── Deploy ─────────────────────────────────────────────────────────────
  console.log("\n-- deploy --");
  // EscrowV2 links two external libraries (fee routing + privacy entry
  // points) — they are deployed once and shared, and hold no state.
  const libs = {};
  for (const name of ["EscrowFeeRouter", "EscrowPrivacyOps"]) {
    const L = await ethers.getContractFactory(name);
    const l = await L.deploy();
    await l.waitForDeployment();
    libs[name] = await l.getAddress();
    console.log(`${name}:`, libs[name]);
  }
  const Escrow = await ethers.getContractFactory("EscrowV2", { libraries: libs });
  const escrow = await Escrow.deploy(
    omniCoin,
    privateOmniCoin,
    registry,
    feeVault,
    MARKETPLACE_FEE_BPS,
    forwarder,
  );
  const deployTx = escrow.deploymentTransaction();
  console.log("tx:", deployTx ? deployTx.hash : "(unknown)");
  await escrow.waitForDeployment();
  const address = await escrow.getAddress();
  console.log("EscrowV2:", address);
  const receipt = await deployTx.wait();
  console.log("mined in block", receipt.blockNumber, "gas used", receipt.gasUsed.toString());

  // ── Post-deploy reads (subnet RPC is eventually consistent) ────────────
  console.log("\n-- verify deployed state --");
  const reads = {
    OMNI_COIN: await escrow.OMNI_COIN(),
    PRIVATE_OMNI_COIN: await escrow.PRIVATE_OMNI_COIN(),
    REGISTRY: await escrow.REGISTRY(),
    FEE_VAULT: await escrow.FEE_VAULT(),
    MARKETPLACE_FEE_BPS: (await escrow.MARKETPLACE_FEE_BPS()).toString(),
    admin: await escrow.admin(),
  };
  for (const [k, v] of Object.entries(reads)) console.log(`${k}: ${v}`);
  if (reads.MARKETPLACE_FEE_BPS !== "100") throw new Error("fee bps not pinned to 100");
  if (reads.admin.toLowerCase() !== deployer.address.toLowerCase()) throw new Error("admin is not the deployer");

  // ── Allowlist visibility for both settlement tokens ────────────────────
  const vault = await ethers.getContractAt(
    ["function supportedPaymentTokens(address) view returns (bool)", "function DEPOSITOR_ROLE() view returns (bytes32)", "function grantRole(bytes32,address)", "function hasRole(bytes32,address) view returns (bool)"],
    feeVault,
  );
  const xomAllowed = await vault.supportedPaymentTokens(omniCoin);
  const usdcAllowed = await vault.supportedPaymentTokens(c.ERC20TokenRemote || c.BridgedUSDC);
  console.log("vault allowlist — XOM:", xomAllowed, "USDC:", usdcAllowed);
  if (!xomAllowed) throw new Error("vault does not allowlist XOM; every escrow create would fail");

  // ── DEPOSITOR_ROLE, so releases can use the canonical 70/20/10 split ───
  const role = await vault.DEPOSITOR_ROLE();
  const already = await vault.hasRole(role, address);
  if (!already) {
    const tx = await vault.grantRole(role, address);
    await tx.wait();
    console.log("granted DEPOSITOR_ROLE:", tx.hash);
  } else {
    console.log("DEPOSITOR_ROLE already held");
  }

  // ── Seed an arbitrator (internal disputes are unrevertable without one) ─
  console.log("\n-- arbitrators --");
  let count = await escrow.arbitratorCount();
  if (count === 0n) {
    // v1 has none either; the admin EOA is the Pioneer-phase arbitrator until
    // a panel is appointed. Disputes need at least one eligible address.
    const tx = await escrow.addArbitrator(deployer.address);
    await tx.wait();
    count = await escrow.arbitratorCount();
    console.log("seeded arbitrator:", deployer.address, "tx:", tx.hash);
  }
  console.log("arbitratorCount:", count.toString());
  for (let i = 0n; i < count; i += 1n) {
    console.log("  ", i.toString(), await escrow.arbitratorList(i));
  }

  // ── Manifest ───────────────────────────────────────────────────────────
  manifest.contracts.EscrowV2 = address;
  manifest.contracts.EscrowV2DeployedAt = new Date().toISOString();
  manifest.contracts.EscrowV2DeployTx = deployTx ? deployTx.hash : "";
  fs.writeFileSync(MANIFEST, `${JSON.stringify(manifest, null, 2)}\n`);
  console.log("\nmanifest updated:", MANIFEST);

  console.log("\nNext: node scripts/sync-contract-addresses.js mainnet");
  console.log("v1 MinimalEscrow stays live for in-flight escrows:", v1Escrow);
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
