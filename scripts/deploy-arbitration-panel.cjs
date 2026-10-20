/**
 * Deploy the hardened arbitration panel as a FRESH proxy (2026-10-20).
 *
 * Founder decision 1: the hardened OmniArbitration ships as a new ERC1967
 * proxy wired to the PRODUCTION escrow (MinimalEscrow), NOT as an upgrade of
 * the live proxy — that proxy's OpenZeppelin manifest record diverges and an
 * upgrade would need the timelock. The deployer is the sole admin of the new
 * proxy, so the qualification wiring is a deployer action.
 *
 * WHAT THIS SCRIPT DOES
 *   1. deploys the OmniArbitration implementation;
 *   2. deploys an ERC1967 proxy and initializes it with
 *      (participation, escrow, xom, feeVault);
 *   3. verifies: admin is the deployer, escrow/participation/xom/feeVault read
 *      back, implementation <= 24,576 bytes, dispute counter empty;
 *   4. records the new address (and keeps the previous one under
 *      `OmniArbitrationLegacy`) in deployments/mainnet.json.
 *
 * WHAT IT DOES NOT DO (run scripts/post-revision-wiring.cjs afterwards):
 *   setRegistration, setFounderArbitrator ×3, and pointing the production
 *   escrow at the new panel. Those change live arbitration routing, so they are
 *   a separate, explicit step.
 *
 * Usage:
 *   MAINNET_DEPLOYER_PRIVATE_KEY=$(cat ~/.avalanche-cli/key/deployer.pk) \
 *     npx hardhat run scripts/deploy-arbitration-panel.cjs --network mainnet
 */
const fs = require("fs");
const path = require("path");
const hre = require("hardhat");

/** The only key permitted to sign a mainnet deploy (Pioneer-phase admin). */
const EXPECTED_DEPLOYER = "0x021868f2E3D49C059EF52B539AAa933B437e0321";

/** EIP-170 deployed-code ceiling. */
const EIP170_LIMIT = 24576;

const MANIFEST = path.join(__dirname, "..", "deployments", "mainnet.json");

async function main() {
  const { ethers } = hre;
  const [deployer] = await ethers.getSigners();

  console.log("=== OmniArbitration fresh panel deployment ===");
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

  const manifest = JSON.parse(fs.readFileSync(MANIFEST, "utf8"));
  const c = manifest.contracts;
  const participation = c.OmniParticipation;
  const productionEscrow = c.MinimalEscrow;
  const xom = c.OmniCoin;
  const feeVault = c.UnifiedFeeVault;
  const forwarder = c.OmniForwarder;
  for (const [name, addr] of Object.entries({
    participation,
    productionEscrow,
    xom,
    feeVault,
  })) {
    if (!addr || !ethers.isAddress(addr)) throw new Error(`manifest missing ${name}`);
    if ((await ethers.provider.getCode(addr)) === "0x") {
      throw new Error(`${name} has no code at ${addr}`);
    }
  }
  console.log("\n-- constructor / initializer inputs --");
  console.log("participation:", participation);
  console.log("escrow       :", productionEscrow, "(the escrow the Validator uses)");
  console.log("xom          :", xom);
  console.log("feeVault     :", feeVault);
  console.log("forwarder    :", forwarder || "(none)");

  // ── Implementation ─────────────────────────────────────────────────────
  const Arbitration = await ethers.getContractFactory("OmniArbitration");
  const impl = await Arbitration.deploy(forwarder || ethers.ZeroAddress);
  await impl.waitForDeployment();
  const implAddress = await impl.getAddress();
  console.log("\nimplementation:", implAddress, "tx:", impl.deploymentTransaction()?.hash);
  manifest.contracts.OmniArbitrationImplementation = implAddress;
  manifest.contracts.OmniArbitrationImplementationDeployedAt = new Date().toISOString();
  fs.writeFileSync(MANIFEST, `${JSON.stringify(manifest, null, 2)}\n`);

  const implCode = await ethers.provider.getCode(implAddress);
  if (implCode === "0x") throw new Error(`no code at implementation ${implAddress}`);
  const implSize = (implCode.length - 2) / 2;
  if (implSize > EIP170_LIMIT) {
    throw new Error(`implementation is ${implSize} bytes — over ${EIP170_LIMIT}`);
  }
  console.log("implementation bytes:", implSize, "of", EIP170_LIMIT);

  // ── Proxy ──────────────────────────────────────────────────────────────
  const initData = Arbitration.interface.encodeFunctionData("initialize", [
    participation,
    productionEscrow,
    xom,
    feeVault,
  ]);
  const Proxy = await ethers.getContractFactory(
    "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy",
  );
  const proxy = await Proxy.deploy(implAddress, initData);
  await proxy.waitForDeployment();
  const proxyAddress = await proxy.getAddress();
  console.log("\nproxy:", proxyAddress, "tx:", proxy.deploymentTransaction()?.hash);

  const panel = Arbitration.attach(proxyAddress);

  // ── Verify ─────────────────────────────────────────────────────────────
  const adminRole = await panel.DEFAULT_ADMIN_ROLE();
  const reads = {
    admin_holds_default_admin: await panel.hasRole(adminRole, deployer.address),
    escrow: await panel.escrow(),
    participation: await panel.participation(),
    xomToken: await panel.xomToken(),
    feeVault: await panel.feeVault(),
    nextDisputeId: (await panel.nextDisputeId()).toString(),
    minArbitratorStake: ethers.formatEther(await panel.minArbitratorStake()),
    arbitratorPoolSize: (await panel.arbitratorPoolSize()).toString(),
    // 0 means running; `pausedAt` is the timestamp the panel was paused.
    pausedAt: (await panel.pausedAt()).toString(),
  };
  console.log("\n-- deployed state --");
  for (const [k, v] of Object.entries(reads)) console.log(`${k}: ${v}`);

  if (!reads.admin_holds_default_admin) {
    throw new Error("deployer does not hold DEFAULT_ADMIN_ROLE on the new panel");
  }
  if (reads.escrow.toLowerCase() !== productionEscrow.toLowerCase()) {
    throw new Error("panel escrow is not the production escrow");
  }
  if (reads.participation.toLowerCase() !== participation.toLowerCase()) {
    throw new Error("panel participation mismatch");
  }
  if (reads.xomToken.toLowerCase() !== xom.toLowerCase()) {
    throw new Error("panel XOM address mismatch");
  }
  if (reads.nextDisputeId !== "0") {
    throw new Error(`fresh panel has nextDisputeId ${reads.nextDisputeId}`);
  }
  if (reads.pausedAt !== "0") throw new Error("fresh panel is paused");

  // ── Record ─────────────────────────────────────────────────────────────
  if (c.OmniArbitration && c.OmniArbitration.toLowerCase() !== proxyAddress.toLowerCase()) {
    manifest.contracts.OmniArbitrationLegacy = c.OmniArbitration;
  }
  manifest.contracts.OmniArbitration = proxyAddress;
  manifest.contracts.OmniArbitrationDeployedAt = new Date().toISOString();
  manifest.contracts.OmniArbitrationDeployTx = proxy.deploymentTransaction()?.hash ?? "";
  fs.writeFileSync(MANIFEST, `${JSON.stringify(manifest, null, 2)}\n`);
  console.log("\nmanifest updated:", MANIFEST);

  console.log("\n-- next (scripts/post-revision-wiring.cjs) --");
  console.log("  1. panel.setRegistration(OmniRegistration)");
  console.log("  2. panel.setFounderArbitrator(<founder>, true)  × 3");
  console.log("  3. MinimalEscrow.setArbitrationContract(newPanel)  [live routing change]");
  console.log("  4. verify canBeArbitrator(addr) == true for all three founders");
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
