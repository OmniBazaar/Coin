/**
 * Deploy the 2026-10 governance-revision implementations (NO upgrade).
 *
 * This script only puts bytecode on chain and writes the addresses to
 * `deployments/revision-2026-10.json`. The proxies are upgraded by the
 * governance proposal built by `scripts/governance/propose-revision-2026-10.cjs`
 * and executed after the timelock delay. Nothing here changes live state
 * except the new, un-wired EscrowV2 instance.
 *
 * Usage:
 *   MAINNET_DEPLOYER_PRIVATE_KEY=$(cat ~/.avalanche-cli/key/deployer.pk) \
 *     npx hardhat run scripts/deploy-revision-2026-10.cjs --network mainnet
 */
const fs = require("fs");
const path = require("path");
const hre = require("hardhat");

const EXPECTED_DEPLOYER = "0x021868f2E3D49C059EF52B539AAa933B437e0321";
const OUT = path.join(__dirname, "..", "deployments", "revision-2026-10.json");
const MANIFEST = path.join(__dirname, "..", "deployments", "mainnet.json");

async function main() {
  const { ethers } = hre;
  const [deployer] = await ethers.getSigners();
  if (deployer.address.toLowerCase() !== EXPECTED_DEPLOYER.toLowerCase()) {
    throw new Error(`wrong signer: ${deployer.address}`);
  }
  const network = await ethers.provider.getNetwork();
  if (network.chainId !== 88008n) throw new Error("wrong chain");

  const manifest = JSON.parse(fs.readFileSync(MANIFEST, "utf8")).contracts;
  const xom = manifest.OmniCoin;
  const pxom = manifest.PrivateOmniCoin;
  const registry = manifest.OmniRegistration;
  const vault = manifest.UnifiedFeeVault;
  const forwarder = manifest.OmniForwarder;

  const out = { deployedAt: new Date().toISOString(), deployer: deployer.address };

  console.log("== Escrow linked libraries ==");
  // EscrowV2 is under the EIP-170 limit only because its fee routing and
  // privacy entry points live in these two external libraries. Both are
  // deployed ONCE and shared by the escrow; they hold no state and are never
  // upgraded.
  const FeeRouter = await ethers.getContractFactory("EscrowFeeRouter");
  const feeRouter = await FeeRouter.deploy();
  await feeRouter.waitForDeployment();
  out.escrowFeeRouter = await feeRouter.getAddress();
  out.escrowFeeRouterTx = feeRouter.deploymentTransaction()?.hash ?? "";
  console.log(out.escrowFeeRouter, out.escrowFeeRouterTx);

  const PrivacyOps = await ethers.getContractFactory("EscrowPrivacyOps");
  const privacyOps = await PrivacyOps.deploy();
  await privacyOps.waitForDeployment();
  out.escrowPrivacyOps = await privacyOps.getAddress();
  out.escrowPrivacyOpsTx = privacyOps.deploymentTransaction()?.hash ?? "";
  console.log(out.escrowPrivacyOps, out.escrowPrivacyOpsTx);

  console.log("== EscrowV2 (revision) ==");
  const Escrow = await ethers.getContractFactory("EscrowV2", {
    libraries: {
      EscrowFeeRouter: out.escrowFeeRouter,
      EscrowPrivacyOps: out.escrowPrivacyOps,
    },
  });
  const escrow = await Escrow.deploy(xom, pxom, registry, vault, 100n, forwarder);
  await escrow.waitForDeployment();
  out.escrowV2 = await escrow.getAddress();
  out.escrowV2Tx = escrow.deploymentTransaction()?.hash ?? "";
  console.log(out.escrowV2, out.escrowV2Tx);

  // Record immediately: a guard failure or a later revert must not lose the
  // three deployed addresses.
  fs.writeFileSync(OUT, `${JSON.stringify(out, null, 2)}\n`);

  // ── Post-deploy guards ────────────────────────────────────────────────
  // EscrowV2 is only deployable because two libraries hold part of its code.
  // A resolved-but-wrong library address passes Hardhat's linker and would
  // ship a broken escrow, so assert what actually landed on chain.
  for (const [name, addr] of [
    ["EscrowFeeRouter", out.escrowFeeRouter],
    ["EscrowPrivacyOps", out.escrowPrivacyOps],
  ]) {
    const code = await ethers.provider.getCode(addr);
    if (code === "0x") throw new Error(`${name} has no code at ${addr}`);
  }
  const escrowCode = await ethers.provider.getCode(out.escrowV2);
  const escrowSize = (escrowCode.length - 2) / 2;
  if (escrowSize > 24576) {
    throw new Error(`EscrowV2 is ${escrowSize} bytes — over the 24,576 EIP-170 limit`);
  }
  out.escrowFeeRouterCodeHash = ethers.keccak256(
    await ethers.provider.getCode(out.escrowFeeRouter),
  );
  out.escrowPrivacyOpsCodeHash = ethers.keccak256(
    await ethers.provider.getCode(out.escrowPrivacyOps),
  );
  for (const lib of [out.escrowFeeRouter, out.escrowPrivacyOps]) {
    if (!escrowCode.toLowerCase().includes(lib.slice(2).toLowerCase())) {
      throw new Error(`EscrowV2 bytecode does not embed library ${lib}`);
    }
  }
  // Library-mediated call: createEscrow runs `requireSupportedToken` in
  // EscrowFeeRouter before anything else. A codeless (/mislinked) library
  // returns no data where a bool is expected, so the call reverts with EMPTY
  // revert data at the decode site; a correct link reverts with our own error
  // selector (InvalidAddress for a token with no code). That difference is the
  // link test — `getEscrow` is NOT library-mediated and proves nothing.
  const noCodeToken = "0x000000000000000000000000000000000000dEaD";
  let revertData = "";
  try {
    await escrow.createEscrow.staticCall(
      "0x000000000000000000000000000000000000bEEF", // seller
      noCodeToken,
      1000n,
      3600n,
    );
    throw new Error("createEscrow with a codeless token did not revert");
  } catch (err) {
    revertData = err?.data ?? err?.info?.error?.data ?? "";
  }
  if (typeof revertData !== "string" || revertData === "0x" || revertData === "") {
    throw new Error(
      "createEscrow reverted with no data — EscrowFeeRouter is not correctly linked",
    );
  }
  console.log(`guards OK — escrow ${escrowSize} bytes, both libraries linked (revert ${revertData.slice(0, 10)})`);

  // Record progress immediately: a later step failing (or a gas problem in the
  // last deployment) must not lose deployed addresses.
  fs.writeFileSync(OUT, `${JSON.stringify(out, null, 2)}\n`);

  console.log("== OmniParticipation implementation ==");
  const Participation = await ethers.getContractFactory("OmniParticipation");
  // Implementation constructor: trusted forwarder, then initializers are
  // disabled on the implementation itself.
  const participation = await Participation.deploy(forwarder);
  await participation.waitForDeployment();
  out.participationImpl = await participation.getAddress();
  out.participationTx = participation.deploymentTransaction()?.hash ?? "";
  console.log(out.participationImpl, out.participationTx);

  console.log("== OmniArbitration implementation ==");
  const Arbitration = await ethers.getContractFactory("OmniArbitration");
  const arbitration = await Arbitration.deploy(forwarder);
  await arbitration.waitForDeployment();
  out.arbitrationImpl = await arbitration.getAddress();
  out.arbitrationTx = arbitration.deploymentTransaction()?.hash ?? "";
  console.log(out.arbitrationImpl, out.arbitrationTx);

  fs.writeFileSync(OUT, `${JSON.stringify(out, null, 2)}\n`);
  console.log("\nwrote", OUT);
  console.log("Next: node scripts/governance/propose-revision-2026-10.cjs");
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
