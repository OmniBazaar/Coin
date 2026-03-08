/**
 * @file deploy-treasury-continue.js
 * @description Continuation of deploy-treasury-mainnet.js.
 *   Phases A-B4 completed successfully. This script handles:
 *   B5. UUPS upgrade UnifiedFeeVault (with unsafeAllow for renames)
 *   C.  Redeploy immutable contracts (OmniENS, YieldFee, Escrow, FeeSwap)
 *   D.  Setter calls on mutable contracts
 *   E.  Wire UnifiedFeeVault recipients
 *   F.  Verification
 *
 * Usage:
 *   npx hardhat run scripts/deploy-treasury-continue.js --network mainnet
 */
const { ethers, upgrades } = require("hardhat");
const fs = require("fs");
const path = require("path");

// ── Known addresses ──────────────────────────────────────────────────
const ODDAO_TREASURY = "0x664B6347a69A22b35348D42E4640CA92e1609378";
const STAKING_POOL = "0x1cc9FF243A3e76A6c122aa708bB3Fd375a97c7d6";
const UNIFIED_FEE_VAULT = "0x732d5711f9D97B3AFa3C4c0e4D1011EBF1550b8c";

async function main() {
  console.log("═══════════════════════════════════════════════════════");
  console.log("  Continue: B5 → F (UUPS upgrade + redeploy + wire)");
  console.log("═══════════════════════════════════════════════════════\n");

  const [deployer] = await ethers.getSigners();
  console.log("Deployer:", deployer.address);

  const network = await ethers.provider.getNetwork();
  if (network.chainId !== 88008n) {
    throw new Error(`Wrong network! Expected 88008, got ${network.chainId}`);
  }

  // Load mainnet.json (already updated by Phases A-B4)
  const deploymentFile = path.join(__dirname, "../deployments/mainnet.json");
  const deployments = JSON.parse(fs.readFileSync(deploymentFile, "utf-8"));

  const XOM = deployments.contracts.OmniCoin;
  const pXOM = deployments.contracts.PrivateOmniCoin;
  const REGISTRATION = deployments.contracts.OmniRegistration;
  const TREASURY = deployments.contracts.OmniTreasury;
  const SWAP_ROUTER = deployments.contracts.OmniSwapRouter;

  console.log("OmniTreasury (Phase A):", TREASURY);
  console.log("OmniSwapRouter (Phase B1):", SWAP_ROUTER);
  console.log("OmniFeeRouter (Phase B2):", deployments.contracts.OmniFeeRouter);
  console.log("OmniPredictionRouter (Phase B3):",
    deployments.contracts.OmniPredictionRouter);
  console.log("DEXSettlement (Phase B4):",
    deployments.contracts.DEXSettlement, "\n");

  function save() {
    deployments.deployedAt = new Date().toISOString();
    fs.writeFileSync(deploymentFile, JSON.stringify(deployments, null, 2));
  }

  // ════════════════════════════════════════════════════════════════════
  // PHASE B5: UUPS upgrade UnifiedFeeVault
  // ════════════════════════════════════════════════════════════════════
  console.log("── Phase B5: UnifiedFeeVault UUPS upgrade ────────────\n");

  // The 3 deprecated variables were renamed (pendingStakingPool →
  // __deprecated_pendingStakingPool, etc.) to preserve UUPS storage
  // layout.  OpenZeppelin's upgrade checker flags renames as
  // incompatible by default.  We explicitly allow renames because
  // the storage slots are identical — only the Solidity names changed.
  // The visibility change (public → private) is also safe since it
  // only affects the ABI, not storage.
  console.log("B5. UnifiedFeeVault (UUPS upgrade)...");
  const UnifiedFeeVault = await ethers.getContractFactory("UnifiedFeeVault");
  const upgradedVault = await upgrades.upgradeProxy(
    UNIFIED_FEE_VAULT,
    UnifiedFeeVault,
    {
      kind: "uups",
      unsafeAllow: ["state-variable-renames"],
    }
  );
  await upgradedVault.waitForDeployment();
  const newVaultImpl = await upgrades.erc1967.getImplementationAddress(
    UNIFIED_FEE_VAULT
  );
  const oldVaultImpl = deployments.contracts.UnifiedFeeVaultImplementation;
  deployments.contracts.UnifiedFeeVaultImplementation = newVaultImpl;
  save();
  console.log("  Proxy unchanged:", UNIFIED_FEE_VAULT);
  console.log("  Old implementation:", oldVaultImpl);
  console.log("  New implementation:", newVaultImpl, "\n");

  // ════════════════════════════════════════════════════════════════════
  // PHASE C: Redeploy immutable contracts (new constructor args)
  // ════════════════════════════════════════════════════════════════════
  console.log("── Phase C: Redeploy immutable contracts ─────────────\n");

  // C1. OmniENS
  console.log("C1. OmniENS...");
  const OmniENS = await ethers.getContractFactory("OmniENS");
  const ens = await OmniENS.deploy(XOM, ODDAO_TREASURY, STAKING_POOL, TREASURY);
  await ens.waitForDeployment();
  const ensAddr = await ens.getAddress();
  deployments.contracts.OmniENS = ensAddr;
  save();
  console.log("  OmniENS:", ensAddr);

  // C2. OmniYieldFeeCollector (10% perf fee, standard 70/20/10)
  console.log("C2. OmniYieldFeeCollector...");
  const YieldFee = await ethers.getContractFactory("OmniYieldFeeCollector");
  const yieldFee = await YieldFee.deploy(
    ODDAO_TREASURY, STAKING_POOL, TREASURY, 1000
  );
  await yieldFee.waitForDeployment();
  const yieldFeeAddr = await yieldFee.getAddress();
  deployments.contracts.OmniYieldFeeCollector = yieldFeeAddr;
  save();
  console.log("  OmniYieldFeeCollector:", yieldFeeAddr, "(10% perf fee)");

  // C3. MinimalEscrow (FEE_COLLECTOR = UnifiedFeeVault)
  console.log("C3. MinimalEscrow...");
  const Escrow = await ethers.getContractFactory("MinimalEscrow");
  const escrow = await Escrow.deploy(
    XOM, pXOM, REGISTRATION, UNIFIED_FEE_VAULT, 100
  );
  await escrow.waitForDeployment();
  const escrowAddr = await escrow.getAddress();
  deployments.contracts.MinimalEscrow = escrowAddr;
  save();
  console.log("  MinimalEscrow:", escrowAddr);

  // C4. FeeSwapAdapter (uses NEW OmniSwapRouter address from Phase B1)
  console.log("C4. FeeSwapAdapter...");
  const defaultSource = ethers.keccak256(ethers.toUtf8Bytes("INTERNAL_AMM"));
  const FeeSwap = await ethers.getContractFactory("FeeSwapAdapter");
  const feeSwap = await FeeSwap.deploy(SWAP_ROUTER, defaultSource, deployer.address);
  await feeSwap.waitForDeployment();
  const feeSwapAddr = await feeSwap.getAddress();
  deployments.contracts.FeeSwapAdapter = feeSwapAddr;
  save();
  console.log("  FeeSwapAdapter:", feeSwapAddr, "(using new SwapRouter)\n");

  // ════════════════════════════════════════════════════════════════════
  // PHASE D: Setter calls on mutable contracts (Group D)
  // ════════════════════════════════════════════════════════════════════
  console.log("── Phase D: Wire mutable contracts ───────────────────\n");

  let tx;

  // D1. OmniChatFee.updateRecipients
  console.log("D1. OmniChatFee.updateRecipients...");
  const chatFee = await ethers.getContractAt(
    "OmniChatFee", deployments.contracts.OmniChatFee
  );
  tx = await chatFee.updateRecipients(
    ethers.ZeroAddress, ethers.ZeroAddress, TREASURY
  );
  await tx.wait();
  console.log("  protocolTreasury →", TREASURY);

  // D2. OmniArbitration.setProtocolTreasury
  console.log("D2. OmniArbitration.setProtocolTreasury...");
  const arbitration = await ethers.getContractAt(
    "OmniArbitration", deployments.contracts.OmniArbitration
  );
  tx = await arbitration.setProtocolTreasury(TREASURY);
  await tx.wait();
  console.log("  protocolTreasury →", TREASURY);

  // D3. OmniBonding.setTreasury
  console.log("D3. OmniBonding.setTreasury...");
  const bonding = await ethers.getContractAt(
    "OmniBonding", deployments.contracts.OmniBonding
  );
  tx = await bonding.setTreasury(TREASURY);
  await tx.wait();
  console.log("  treasury →", TREASURY);

  // D4. LiquidityMining.setTreasury + setValidatorFeeRecipient
  console.log("D4. LiquidityMining.setTreasury...");
  const liqMining = await ethers.getContractAt(
    "LiquidityMining", deployments.contracts.LiquidityMining
  );
  tx = await liqMining.setTreasury(TREASURY);
  await tx.wait();
  console.log("  treasury →", TREASURY);

  console.log("D4b. LiquidityMining.setValidatorFeeRecipient...");
  tx = await liqMining.setValidatorFeeRecipient(ODDAO_TREASURY);
  await tx.wait();
  console.log("  validatorFeeRecipient →", ODDAO_TREASURY);

  // D5. LiquidityBootstrappingPool.setTreasury
  console.log("D5. LiquidityBootstrappingPool.setTreasury...");
  const lbp = await ethers.getContractAt(
    "LiquidityBootstrappingPool",
    deployments.contracts.LiquidityBootstrappingPool
  );
  tx = await lbp.setTreasury(TREASURY);
  await tx.wait();
  console.log("  treasury →", TREASURY, "\n");

  // ════════════════════════════════════════════════════════════════════
  // PHASE E: Wire UnifiedFeeVault recipients
  // ════════════════════════════════════════════════════════════════════
  console.log("── Phase E: Update vault recipients ──────────────────\n");

  // E1. UnifiedFeeVault.setRecipients (new function from upgraded code)
  console.log("E1. UnifiedFeeVault.setRecipients...");
  const vault = await ethers.getContractAt(
    "UnifiedFeeVault", UNIFIED_FEE_VAULT
  );
  tx = await vault.setRecipients(STAKING_POOL, TREASURY);
  await tx.wait();
  console.log("  stakingPool →", STAKING_POOL);
  console.log("  protocolTreasury →", TREASURY, "\n");

  // Note: DEXSettlement was deployed in Phase B4 with constructor args
  // (STAKING_POOL, ODDAO_TREASURY, TREASURY) — no setter call needed.

  // ════════════════════════════════════════════════════════════════════
  // PHASE F: Verification
  // ════════════════════════════════════════════════════════════════════
  console.log("── Phase F: Verification ─────────────────────────────\n");

  let passed = 0;
  let failed = 0;

  async function verify(label, actual, expected) {
    const match = actual.toLowerCase() === expected.toLowerCase();
    const icon = match ? "✅" : "❌";
    console.log(`  ${icon} ${label}: ${actual}`);
    if (match) { passed++; } else {
      console.log(`     EXPECTED: ${expected}`);
      failed++;
    }
  }

  // OmniTreasury: deployer has admin role
  const treasury = await ethers.getContractAt("OmniTreasury", TREASURY);
  const adminRole = await treasury.DEFAULT_ADMIN_ROLE();
  const hasAdmin = await treasury.hasRole(adminRole, deployer.address);
  console.log(`  ${hasAdmin ? "✅" : "❌"} OmniTreasury: admin = deployer`);
  if (hasAdmin) { passed++; } else { failed++; }

  // OmniSwapRouter
  const swapRouter = await ethers.getContractAt(
    "OmniSwapRouter", deployments.contracts.OmniSwapRouter
  );
  await verify("OmniSwapRouter.feeRecipient",
    await swapRouter.feeRecipient(), UNIFIED_FEE_VAULT);
  await verify("OmniSwapRouter.owner",
    await swapRouter.owner(), deployer.address);

  // OmniFeeRouter
  const feeRouter = await ethers.getContractAt(
    "OmniFeeRouter", deployments.contracts.OmniFeeRouter
  );
  await verify("OmniFeeRouter.feeCollector",
    await feeRouter.feeCollector(), UNIFIED_FEE_VAULT);
  await verify("OmniFeeRouter.owner",
    await feeRouter.owner(), deployer.address);

  // OmniPredictionRouter
  const predRouter = await ethers.getContractAt(
    "OmniPredictionRouter", deployments.contracts.OmniPredictionRouter
  );
  await verify("OmniPredictionRouter.feeCollector",
    await predRouter.feeCollector(), UNIFIED_FEE_VAULT);
  await verify("OmniPredictionRouter.owner",
    await predRouter.owner(), deployer.address);

  // DEXSettlement
  const settlement = await ethers.getContractAt(
    "DEXSettlement", deployments.contracts.DEXSettlement
  );
  const feeRecips = await settlement.feeRecipients();
  await verify("DEXSettlement.protocolTreasury",
    feeRecips.protocolTreasury, TREASURY);
  await verify("DEXSettlement.oddao",
    feeRecips.oddao, ODDAO_TREASURY);
  await verify("DEXSettlement.liquidityPool",
    feeRecips.liquidityPool, STAKING_POOL);
  await verify("DEXSettlement.owner",
    await settlement.owner(), deployer.address);

  // UnifiedFeeVault
  await verify("UnifiedFeeVault.protocolTreasury",
    await vault.protocolTreasury(), TREASURY);
  await verify("UnifiedFeeVault.stakingPool",
    await vault.stakingPool(), STAKING_POOL);

  // OmniENS
  await verify("OmniENS.protocolTreasury",
    await ens.protocolTreasury(), TREASURY);

  // OmniYieldFeeCollector
  await verify("OmniYieldFeeCollector.protocolTreasury",
    await yieldFee.protocolTreasury(), TREASURY);

  // MinimalEscrow
  await verify("MinimalEscrow.FEE_COLLECTOR",
    await escrow.FEE_COLLECTOR(), UNIFIED_FEE_VAULT);

  // OmniChatFee
  await verify("OmniChatFee.protocolTreasury",
    await chatFee.protocolTreasury(), TREASURY);

  // OmniArbitration
  await verify("OmniArbitration.protocolTreasury",
    await arbitration.protocolTreasury(), TREASURY);

  // OmniBonding
  await verify("OmniBonding.treasury",
    await bonding.treasury(), TREASURY);

  // LiquidityMining
  await verify("LiquidityMining.treasury",
    await liqMining.treasury(), TREASURY);
  await verify("LiquidityMining.validatorFeeRecipient",
    await liqMining.validatorFeeRecipient(), ODDAO_TREASURY);

  // LBP
  await verify("LBP.treasury",
    await lbp.treasury(), TREASURY);

  console.log(`\n  Results: ${passed} passed, ${failed} failed\n`);

  if (failed > 0) {
    console.log("⚠️  Some verifications failed! Review above.\n");
  } else {
    console.log("✅ All verifications passed!\n");
  }

  // Save final state with deployment note
  const swapRouterAddr = deployments.contracts.OmniSwapRouter;
  const feeRouterAddr = deployments.contracts.OmniFeeRouter;
  const predRouterAddr = deployments.contracts.OmniPredictionRouter;
  const settlementAddr = deployments.contracts.DEXSettlement;
  deployments.notes.push(
    `OmniTreasury deployed: ${TREASURY}. ` +
    `Redeployed (new code): OmniSwapRouter (${swapRouterAddr}), ` +
    `OmniFeeRouter (${feeRouterAddr}), ` +
    `OmniPredictionRouter (${predRouterAddr}), ` +
    `DEXSettlement (${settlementAddr}). ` +
    `UnifiedFeeVault UUPS upgraded: impl ${oldVaultImpl} → ${newVaultImpl}. ` +
    `Redeployed (new args): OmniENS (${ensAddr}), ` +
    `OmniYieldFeeCollector (${yieldFeeAddr}), ` +
    `MinimalEscrow (${escrowAddr}), FeeSwapAdapter (${feeSwapAddr}). ` +
    `All fee contracts wired to OmniTreasury as protocolTreasury. ` +
    `OmniSwapRouter/OmniFeeRouter/OmniPredictionRouter → UnifiedFeeVault. ` +
    `UnifiedFeeVault recipients: StakingPool + OmniTreasury.`
  );
  save();

  console.log("═══════════════════════════════════════════════════════");
  console.log("  Deployment complete. Run sync script next:");
  console.log("  ./scripts/sync-contract-addresses.sh mainnet");
  console.log("═══════════════════════════════════════════════════════\n");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("Deployment failed:", error);
    process.exit(1);
  });
