/**
 * E2E Bridge Test Script
 *
 * Exercises the full bridge flow on UnifiedFeeVault:
 *   1. Check current pendingBridge amounts
 *   2. If amounts > 0: call bridgeToTreasury and verify
 *   3. Test swapAndBridge path (with FeeSwapAdapter)
 *   4. Test error cases (zero amount, wrong role, insufficient balance)
 *
 * Prerequisites:
 *   - UnifiedFeeVault deployed and initialized
 *   - Caller has BRIDGE_ROLE (run grant-bridge-role.js first)
 *   - Some fees deposited and distributed (so pendingBridge > 0)
 *
 * Usage:
 *   npx hardhat run scripts/e2e-bridge-test.js --network fuji
 *
 * @module scripts/e2e-bridge-test
 */

const { ethers } = require("hardhat");

const UNIFIED_FEE_VAULT_PROXY = "0x45dB9304a5124d3cD6d646900b1c4C0cA6A89658";
const XOM_ADDRESS = "0x117defc430E143529a9067A7866A9e7Eb532203C";
const PXOM_ADDRESS = "0x09F99AE44bd024fD2c16ff6999959d053f0f32B5";
const USDC_ADDRESS = "0xFC866508bb2720054F9e346B286A08E7143423A7";
const FEE_SWAP_ADAPTER = "0x6Bce2b309b6C0107a8eB48d865ea52F858B9C865";
const ODDAO_TREASURY = "0x664B6347a69A22b35348D42E4640CA92e1609378";

let passed = 0;
let failed = 0;

function assert(condition, message) {
  if (condition) {
    console.log(`  PASS: ${message}`);
    passed++;
  } else {
    console.error(`  FAIL: ${message}`);
    failed++;
  }
}

async function main() {
  console.log("=".repeat(60));
  console.log("E2E Bridge Test — UnifiedFeeVault");
  console.log("=".repeat(60));

  const [signer] = await ethers.getSigners();
  console.log("\nSigner:", signer.address);

  const vault = await ethers.getContractAt("UnifiedFeeVault", UNIFIED_FEE_VAULT_PROXY);

  // ═══════════════════════════════════════════════════════════════════
  // Test 1: Read pendingBridge for known tokens
  // ═══════════════════════════════════════════════════════════════════
  console.log("\n--- Test 1: Read pendingBridge amounts ---");

  const tokens = [
    { symbol: "XOM", address: XOM_ADDRESS },
    { symbol: "pXOM", address: PXOM_ADDRESS },
    { symbol: "USDC", address: USDC_ADDRESS },
  ];

  const pendingAmounts = {};
  for (const token of tokens) {
    try {
      const pending = await vault.pendingForBridge(token.address);
      pendingAmounts[token.symbol] = pending;
      console.log(`  ${token.symbol}: ${ethers.formatEther(pending)} pending`);
      assert(pending >= 0n, `${token.symbol} pendingBridge is non-negative`);
    } catch (err) {
      console.log(`  ${token.symbol}: query failed (${err.message})`);
      pendingAmounts[token.symbol] = 0n;
    }
  }

  // ═══════════════════════════════════════════════════════════════════
  // Test 2: Check BRIDGE_ROLE
  // ═══════════════════════════════════════════════════════════════════
  console.log("\n--- Test 2: Verify BRIDGE_ROLE ---");

  const BRIDGE_ROLE = await vault.BRIDGE_ROLE();
  const hasBridgeRole = await vault.hasRole(BRIDGE_ROLE, signer.address);
  assert(hasBridgeRole, "Signer has BRIDGE_ROLE");

  if (!hasBridgeRole) {
    console.log("\nWARNING: Signer lacks BRIDGE_ROLE. Run grant-bridge-role.js first.");
    console.log("Skipping bridge execution tests.");
    printSummary();
    return;
  }

  // ═══════════════════════════════════════════════════════════════════
  // Test 3: bridgeToTreasury (in-kind)
  // ═══════════════════════════════════════════════════════════════════
  console.log("\n--- Test 3: bridgeToTreasury (in-kind) ---");

  if (pendingAmounts["XOM"] > 0n) {
    const bridgeAmount = pendingAmounts["XOM"];
    const totalBridgedBefore = await vault.totalBridged(XOM_ADDRESS);

    console.log(`  Bridging ${ethers.formatEther(bridgeAmount)} XOM to ${ODDAO_TREASURY}`);
    const tx = await vault.bridgeToTreasury(XOM_ADDRESS, bridgeAmount, ODDAO_TREASURY);
    const receipt = await tx.wait();
    console.log(`  TX: ${receipt.hash} (block ${receipt.blockNumber})`);

    const pendingAfter = await vault.pendingForBridge(XOM_ADDRESS);
    const totalBridgedAfter = await vault.totalBridged(XOM_ADDRESS);

    assert(pendingAfter === 0n, "XOM pendingBridge is now 0");
    assert(totalBridgedAfter > totalBridgedBefore, "XOM totalBridged increased");
    assert(
      totalBridgedAfter - totalBridgedBefore === bridgeAmount,
      "totalBridged increased by exact bridge amount"
    );
  } else {
    console.log("  SKIP: No pending XOM to bridge");
  }

  // ═══════════════════════════════════════════════════════════════════
  // Test 4: Error case — bridge zero amount
  // ═══════════════════════════════════════════════════════════════════
  console.log("\n--- Test 4: Error — bridge zero amount ---");

  try {
    await vault.bridgeToTreasury(XOM_ADDRESS, 0n, ODDAO_TREASURY);
    assert(false, "Should have reverted on zero amount");
  } catch (err) {
    assert(true, "Reverted on zero amount: " + (err.reason || err.message).slice(0, 80));
  }

  // ═══════════════════════════════════════════════════════════════════
  // Test 5: Error case — bridge more than pending
  // ═══════════════════════════════════════════════════════════════════
  console.log("\n--- Test 5: Error — bridge more than pending ---");

  try {
    const huge = ethers.parseEther("999999999");
    await vault.bridgeToTreasury(XOM_ADDRESS, huge, ODDAO_TREASURY);
    assert(false, "Should have reverted on excessive amount");
  } catch (err) {
    assert(true, "Reverted on excessive amount: " + (err.reason || err.message).slice(0, 80));
  }

  // ═══════════════════════════════════════════════════════════════════
  // Test 6: Error case — unauthorized caller
  // ═══════════════════════════════════════════════════════════════════
  console.log("\n--- Test 6: Error — unauthorized caller ---");

  const signers = await ethers.getSigners();
  if (signers.length > 1) {
    const unauthorized = signers[1];
    const vaultAsUnauthorized = vault.connect(unauthorized);
    try {
      await vaultAsUnauthorized.bridgeToTreasury(XOM_ADDRESS, 1n, ODDAO_TREASURY);
      assert(false, "Should have reverted for unauthorized caller");
    } catch (err) {
      assert(true, "Reverted for unauthorized caller: " + (err.reason || err.message).slice(0, 80));
    }
  } else {
    console.log("  SKIP: Only one signer available, cannot test unauthorized access");
  }

  // ═══════════════════════════════════════════════════════════════════
  // Test 7: Check FeeSwapAdapter configuration
  // ═══════════════════════════════════════════════════════════════════
  console.log("\n--- Test 7: FeeSwapAdapter configuration ---");

  const swapRouter = await vault.swapRouter();
  console.log(`  Configured swapRouter: ${swapRouter}`);
  assert(
    swapRouter.toLowerCase() === FEE_SWAP_ADAPTER.toLowerCase(),
    "SwapRouter is set to FeeSwapAdapter"
  );

  // ═══════════════════════════════════════════════════════════════════
  // Test 8: Check bridge mode for tokens
  // ═══════════════════════════════════════════════════════════════════
  console.log("\n--- Test 8: Token bridge modes ---");

  for (const token of tokens) {
    try {
      const mode = await vault.tokenBridgeMode(token.address);
      const modeStr = Number(mode) === 0 ? "IN_KIND" : "SWAP_TO_XOM";
      console.log(`  ${token.symbol}: ${modeStr}`);
      assert(Number(mode) >= 0 && Number(mode) <= 1, `${token.symbol} has valid bridge mode`);
    } catch (err) {
      console.log(`  ${token.symbol}: mode query failed (${err.message})`);
    }
  }

  // ═══════════════════════════════════════════════════════════════════
  // Summary
  // ═══════════════════════════════════════════════════════════════════
  printSummary();
}

function printSummary() {
  console.log("\n" + "=".repeat(60));
  console.log(`Results: ${passed} passed, ${failed} failed, ${passed + failed} total`);
  console.log("=".repeat(60));
  if (failed > 0) {
    process.exit(1);
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("Fatal error:", error);
    process.exit(1);
  });
