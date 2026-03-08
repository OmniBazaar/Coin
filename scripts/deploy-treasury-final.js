/**
 * @file deploy-treasury-final.js
 * @description Final continuation: C4 (FeeSwapAdapter), D (setters),
 *   E (vault recipients), F (verify). Also re-attempts UUPS upgrade
 *   if the implementation hasn't changed.
 *
 * Completed in prior runs:
 *   Phase A:  OmniTreasury deployed
 *   Phase B1: OmniSwapRouter redeployed
 *   Phase B2: OmniFeeRouter redeployed
 *   Phase B3: OmniPredictionRouter redeployed
 *   Phase B4: DEXSettlement redeployed
 *   Phase B5: UnifiedFeeVault upgrade attempted (verify)
 *   Phase C1: OmniENS redeployed
 *   Phase C2: OmniYieldFeeCollector redeployed
 *   Phase C3: MinimalEscrow redeployed
 *
 * Usage:
 *   npx hardhat run scripts/deploy-treasury-final.js --network mainnet
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
  console.log("  Final: C4 + UUPS verify + D + E + F");
  console.log("═══════════════════════════════════════════════════════\n");

  const [deployer] = await ethers.getSigners();
  console.log("Deployer:", deployer.address);

  const network = await ethers.provider.getNetwork();
  if (network.chainId !== 88008n) {
    throw new Error(`Wrong network! Expected 88008, got ${network.chainId}`);
  }

  // Load mainnet.json
  const deploymentFile = path.join(__dirname, "../deployments/mainnet.json");
  const deployments = JSON.parse(fs.readFileSync(deploymentFile, "utf-8"));

  const XOM = deployments.contracts.OmniCoin;
  const TREASURY = deployments.contracts.OmniTreasury;
  const SWAP_ROUTER = deployments.contracts.OmniSwapRouter;

  function save() {
    deployments.deployedAt = new Date().toISOString();
    fs.writeFileSync(deploymentFile, JSON.stringify(deployments, null, 2));
  }

  let tx;

  // ════════════════════════════════════════════════════════════════════
  // Check / force UUPS upgrade
  // ════════════════════════════════════════════════════════════════════
  console.log("── Verify/force UUPS upgrade ─────────────────────────\n");

  const vault = await ethers.getContractAt(
    "UnifiedFeeVault", UNIFIED_FEE_VAULT
  );

  // Test if setRecipients exists (new function from upgraded code)
  try {
    // Dry-run: staticCall won't revert if the function exists
    await vault.setRecipients.staticCall(STAKING_POOL, TREASURY);
    console.log("  setRecipients() exists → upgrade is live\n");
  } catch (err) {
    console.log("  setRecipients() missing → forcing UUPS upgrade...");
    const UnifiedFeeVault = await ethers.getContractFactory("UnifiedFeeVault");

    // Force deploy a new implementation even if OZ thinks it matches
    const newImpl = await UnifiedFeeVault.deploy();
    await newImpl.waitForDeployment();
    const newImplAddr = await newImpl.getAddress();
    console.log("  New implementation deployed:", newImplAddr);

    // Call upgradeToAndCall on the proxy directly
    tx = await vault.upgradeToAndCall(newImplAddr, "0x");
    await tx.wait();
    console.log("  Proxy upgraded to:", newImplAddr);

    deployments.contracts.UnifiedFeeVaultImplementation = newImplAddr;
    save();

    // Verify the upgrade worked
    await vault.setRecipients.staticCall(STAKING_POOL, TREASURY);
    console.log("  setRecipients() now works → upgrade confirmed\n");
  }

  // ════════════════════════════════════════════════════════════════════
  // PHASE C4: FeeSwapAdapter
  // ════════════════════════════════════════════════════════════════════
  console.log("── Phase C4: FeeSwapAdapter ──────────────────────────\n");

  const defaultSource = ethers.keccak256(ethers.toUtf8Bytes("INTERNAL_AMM"));
  const FeeSwap = await ethers.getContractFactory("FeeSwapAdapter");
  const feeSwap = await FeeSwap.deploy(SWAP_ROUTER, defaultSource, deployer.address);
  await feeSwap.waitForDeployment();
  const feeSwapAddr = await feeSwap.getAddress();
  deployments.contracts.FeeSwapAdapter = feeSwapAddr;
  save();
  console.log("  FeeSwapAdapter:", feeSwapAddr, "(using new SwapRouter)\n");

  // ════════════════════════════════════════════════════════════════════
  // PHASE D: Setter calls on mutable contracts
  // ════════════════════════════════════════════════════════════════════
  console.log("── Phase D: Wire mutable contracts ───────────────────\n");

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

  console.log("E1. UnifiedFeeVault.setRecipients...");
  tx = await vault.setRecipients(STAKING_POOL, TREASURY);
  await tx.wait();
  console.log("  stakingPool →", STAKING_POOL);
  console.log("  protocolTreasury →", TREASURY, "\n");

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

  // OmniTreasury
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
  const ens = await ethers.getContractAt(
    "OmniENS", deployments.contracts.OmniENS
  );
  await verify("OmniENS.protocolTreasury",
    await ens.protocolTreasury(), TREASURY);

  // OmniYieldFeeCollector
  const yieldFee = await ethers.getContractAt(
    "OmniYieldFeeCollector", deployments.contracts.OmniYieldFeeCollector
  );
  await verify("OmniYieldFeeCollector.protocolTreasury",
    await yieldFee.protocolTreasury(), TREASURY);

  // MinimalEscrow
  const escrow = await ethers.getContractAt(
    "MinimalEscrow", deployments.contracts.MinimalEscrow
  );
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

  // Save deployment note
  const swapRouterAddr = deployments.contracts.OmniSwapRouter;
  const feeRouterAddr = deployments.contracts.OmniFeeRouter;
  const predRouterAddr = deployments.contracts.OmniPredictionRouter;
  const settlementAddr = deployments.contracts.DEXSettlement;
  const ensAddr = deployments.contracts.OmniENS;
  const yieldFeeAddr = deployments.contracts.OmniYieldFeeCollector;
  const escrowAddr = deployments.contracts.MinimalEscrow;
  const vaultImpl = deployments.contracts.UnifiedFeeVaultImplementation;
  deployments.notes.push(
    `OmniTreasury deployed: ${TREASURY}. ` +
    `Redeployed (new code): OmniSwapRouter (${swapRouterAddr}), ` +
    `OmniFeeRouter (${feeRouterAddr}), ` +
    `OmniPredictionRouter (${predRouterAddr}), ` +
    `DEXSettlement (${settlementAddr}). ` +
    `UnifiedFeeVault UUPS upgraded: impl → ${vaultImpl}. ` +
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
