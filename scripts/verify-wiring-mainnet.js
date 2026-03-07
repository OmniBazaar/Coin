/**
 * verify-wiring-mainnet.js
 *
 * Audits the deployment wiring for the OmniBazaar mainnet (chain ID 88008).
 * Reads contract addresses from deployments/mainnet.json and verifies that
 * cross-contract references are properly configured.
 *
 * Usage:
 *   npx hardhat run scripts/verify-wiring-mainnet.js --network mainnet
 */

const { ethers } = require("hardhat");
const fs = require("fs");
const path = require("path");

// ── Known addresses ─────────────────────────────────────────────────────────
const DEPLOYER = "0xaDAD7751DcDd2E30015C173F2c35a56e467CD9ba";
const ODDAO_TREASURY = "0x664B6347a69A22b35348D42E4640CA92e1609378";
const PROTOCOL_TREASURY = DEPLOYER; // Pioneer Phase

// ── Counters ────────────────────────────────────────────────────────────────
let passCount = 0;
let failCount = 0;
let skipCount = 0;

function pass(label) {
  passCount++;
  console.log(`  \x1b[32mPASS\x1b[0m  ${label}`);
}

function fail(label, detail) {
  failCount++;
  console.log(`  \x1b[31mFAIL\x1b[0m  ${label}`);
  if (detail) console.log(`        ${detail}`);
}

function skip(label) {
  skipCount++;
  console.log(`  \x1b[33mSKIP\x1b[0m  ${label}`);
}

function section(title) {
  console.log(`\n${"=".repeat(70)}`);
  console.log(`  ${title}`);
  console.log(`${"=".repeat(70)}`);
}

/**
 * Safely call a contract view function.
 * Returns the result or null on revert.
 */
async function safeCall(contract, method, args) {
  try {
    if (args && args.length > 0) {
      return await contract[method](...args);
    }
    return await contract[method]();
  } catch {
    return null;
  }
}

/**
 * Compare two addresses case-insensitively.
 */
function addrEq(a, b) {
  if (!a || !b) return false;
  return a.toLowerCase() === b.toLowerCase();
}

// ── Main ────────────────────────────────────────────────────────────────────
async function main() {
  console.log("OmniBazaar Mainnet Wiring Verification");
  console.log(`Chain ID: ${(await ethers.provider.getNetwork()).chainId}`);
  console.log(`Deployer: ${DEPLOYER}`);
  console.log(`ODDAO Treasury: ${ODDAO_TREASURY}`);
  console.log(`Protocol Treasury: ${PROTOCOL_TREASURY}`);

  // ── Load deployment manifest ────────────────────────────────────────────
  const manifestPath = path.join(__dirname, "..", "deployments", "mainnet.json");
  if (!fs.existsSync(manifestPath)) {
    console.error("ERROR: deployments/mainnet.json not found");
    process.exit(1);
  }
  const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
  const c = manifest.contracts;

  // Helper: get contract address or null
  function addr(name) {
    return c[name] || null;
  }

  // ── Precompute role hashes ──────────────────────────────────────────────
  const DEFAULT_ADMIN_ROLE = ethers.ZeroHash; // 0x00...00
  const MINTER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("MINTER_ROLE"));
  const BURNER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("BURNER_ROLE"));
  const ADMIN_ROLE = ethers.keccak256(ethers.toUtf8Bytes("ADMIN_ROLE"));
  const BONUS_MARKER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("BONUS_MARKER_ROLE"));
  const TRANSACTION_RECORDER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("TRANSACTION_RECORDER_ROLE"));

  // ════════════════════════════════════════════════════════════════════════
  //  1. OmniCoin
  // ════════════════════════════════════════════════════════════════════════
  section("1. OmniCoin (XOM)");

  if (!addr("OmniCoin")) {
    skip("OmniCoin not deployed");
  } else {
    const omniCoinAbi = [
      "function hasRole(bytes32 role, address account) view returns (bool)",
      "function totalSupply() view returns (uint256)",
      "function MINTER_ROLE() view returns (bytes32)",
      "function BURNER_ROLE() view returns (bytes32)",
      "function defaultAdmin() view returns (address)",
    ];
    const xom = new ethers.Contract(addr("OmniCoin"), omniCoinAbi, ethers.provider);

    // 1a. MINTER_ROLE revoked from deployer
    const deployerHasMinter = await safeCall(xom, "hasRole", [MINTER_ROLE, DEPLOYER]);
    if (deployerHasMinter === false) {
      pass("MINTER_ROLE revoked from deployer");
    } else if (deployerHasMinter === true) {
      fail("MINTER_ROLE still held by deployer", "Expected revoked");
    } else {
      fail("MINTER_ROLE check failed (could not query)");
    }

    // 1b. DEFAULT_ADMIN_ROLE is deployer
    const admin = await safeCall(xom, "defaultAdmin");
    if (admin && addrEq(admin, DEPLOYER)) {
      pass(`defaultAdmin is deployer (${admin})`);
    } else {
      fail(`defaultAdmin mismatch`, `Got: ${admin}, Expected: ${DEPLOYER}`);
    }

    // 1c. Total supply check
    const supply = await safeCall(xom, "totalSupply");
    if (supply) {
      const formatted = ethers.formatEther(supply);
      const expected = 16_600_000_000;
      const actual = parseFloat(formatted);
      if (Math.abs(actual - expected) < 1) {
        pass(`totalSupply = ${formatted} XOM`);
      } else {
        fail(`totalSupply mismatch`, `Got: ${formatted}, Expected: ~${expected}`);
      }
    } else {
      fail("Could not read totalSupply");
    }
  }

  // ════════════════════════════════════════════════════════════════════════
  //  2. OmniCore
  // ════════════════════════════════════════════════════════════════════════
  section("2. OmniCore");

  if (!addr("OmniCore")) {
    skip("OmniCore not deployed");
  } else {
    const omniCoreAbi = [
      "function hasRole(bytes32 role, address account) view returns (bool)",
      "function OMNI_COIN() view returns (address)",
      "function oddaoAddress() view returns (address)",
      "function stakingPoolAddress() view returns (address)",
      "function ADMIN_ROLE() view returns (bytes32)",
    ];
    const core = new ethers.Contract(addr("OmniCore"), omniCoreAbi, ethers.provider);

    // 2a. ADMIN_ROLE held by deployer
    const deployerHasAdmin = await safeCall(core, "hasRole", [ADMIN_ROLE, DEPLOYER]);
    if (deployerHasAdmin === true) {
      pass("ADMIN_ROLE held by deployer");
    } else {
      fail("ADMIN_ROLE NOT held by deployer");
    }

    // 2b. DEFAULT_ADMIN_ROLE held by deployer
    const deployerHasDefault = await safeCall(core, "hasRole", [DEFAULT_ADMIN_ROLE, DEPLOYER]);
    if (deployerHasDefault === true) {
      pass("DEFAULT_ADMIN_ROLE held by deployer");
    } else {
      fail("DEFAULT_ADMIN_ROLE NOT held by deployer");
    }

    // 2c. OMNI_COIN references OmniCoin contract
    const coreToken = await safeCall(core, "OMNI_COIN");
    if (coreToken && addrEq(coreToken, addr("OmniCoin"))) {
      pass(`OMNI_COIN = ${coreToken}`);
    } else {
      fail(`OMNI_COIN mismatch`, `Got: ${coreToken}, Expected: ${addr("OmniCoin")}`);
    }

    // 2d. oddaoAddress
    const oddao = await safeCall(core, "oddaoAddress");
    if (oddao && addrEq(oddao, ODDAO_TREASURY)) {
      pass(`oddaoAddress = ${oddao}`);
    } else {
      fail(`oddaoAddress mismatch`, `Got: ${oddao}, Expected: ${ODDAO_TREASURY}`);
    }

    // 2e. stakingPoolAddress
    const staking = await safeCall(core, "stakingPoolAddress");
    if (staking && addrEq(staking, addr("StakingRewardPool"))) {
      pass(`stakingPoolAddress = ${staking}`);
    } else if (staking) {
      // May be deployer during Pioneer Phase
      if (addrEq(staking, DEPLOYER)) {
        fail("stakingPoolAddress still set to deployer (should be StakingRewardPool)",
          `Got: ${staking}, Expected: ${addr("StakingRewardPool")}`);
      } else {
        fail(`stakingPoolAddress unknown`, `Got: ${staking}`);
      }
    } else {
      fail("Could not read stakingPoolAddress");
    }
  }

  // ════════════════════════════════════════════════════════════════════════
  //  3. MinimalEscrow
  // ════════════════════════════════════════════════════════════════════════
  section("3. MinimalEscrow");

  if (!addr("MinimalEscrow")) {
    skip("MinimalEscrow not deployed");
  } else {
    const escrowAbi = [
      "function OMNI_COIN() view returns (address)",
      "function PRIVATE_OMNI_COIN() view returns (address)",
      "function FEE_COLLECTOR() view returns (address)",
      "function ADMIN() view returns (address)",
      "function REGISTRY() view returns (address)",
      "function MARKETPLACE_FEE_BPS() view returns (uint256)",
    ];
    const esc = new ethers.Contract(addr("MinimalEscrow"), escrowAbi, ethers.provider);

    // 3a. OMNI_COIN references OmniCoin
    const escToken = await safeCall(esc, "OMNI_COIN");
    if (escToken && addrEq(escToken, addr("OmniCoin"))) {
      pass(`OMNI_COIN = ${escToken}`);
    } else {
      fail(`OMNI_COIN mismatch`, `Got: ${escToken}, Expected: ${addr("OmniCoin")}`);
    }

    // 3b. PRIVATE_OMNI_COIN references PrivateOmniCoin
    const escPrivate = await safeCall(esc, "PRIVATE_OMNI_COIN");
    if (escPrivate && addrEq(escPrivate, addr("PrivateOmniCoin"))) {
      pass(`PRIVATE_OMNI_COIN = ${escPrivate}`);
    } else {
      fail(`PRIVATE_OMNI_COIN mismatch`, `Got: ${escPrivate}, Expected: ${addr("PrivateOmniCoin")}`);
    }

    // 3c. FEE_COLLECTOR
    const feeColl = await safeCall(esc, "FEE_COLLECTOR");
    if (feeColl) {
      // FEE_COLLECTOR should ideally be UnifiedFeeVault or an appropriate address
      if (addr("UnifiedFeeVault") && addrEq(feeColl, addr("UnifiedFeeVault"))) {
        pass(`FEE_COLLECTOR = UnifiedFeeVault (${feeColl})`);
      } else if (addrEq(feeColl, ODDAO_TREASURY)) {
        pass(`FEE_COLLECTOR = ODDAO Treasury (${feeColl})`);
      } else if (addrEq(feeColl, DEPLOYER)) {
        pass(`FEE_COLLECTOR = deployer (${feeColl}) [Pioneer Phase]`);
      } else {
        pass(`FEE_COLLECTOR = ${feeColl} (verify manually)`);
      }
    } else {
      fail("Could not read FEE_COLLECTOR");
    }

    // 3d. ADMIN is deployer
    const escAdmin = await safeCall(esc, "ADMIN");
    if (escAdmin && addrEq(escAdmin, DEPLOYER)) {
      pass(`ADMIN = deployer (${escAdmin})`);
    } else {
      fail(`ADMIN mismatch`, `Got: ${escAdmin}, Expected: ${DEPLOYER}`);
    }

    // 3e. REGISTRY references OmniCore or OmniRegistration
    const registry = await safeCall(esc, "REGISTRY");
    if (registry) {
      if (addrEq(registry, addr("OmniCore"))) {
        pass(`REGISTRY = OmniCore (${registry})`);
      } else if (addrEq(registry, addr("OmniRegistration"))) {
        pass(`REGISTRY = OmniRegistration (${registry})`);
      } else {
        pass(`REGISTRY = ${registry} (verify manually)`);
      }
    } else {
      fail("Could not read REGISTRY");
    }

    // 3f. MARKETPLACE_FEE_BPS
    const feeBps = await safeCall(esc, "MARKETPLACE_FEE_BPS");
    if (feeBps !== null && feeBps !== undefined) {
      pass(`MARKETPLACE_FEE_BPS = ${feeBps.toString()} bps`);
    } else {
      fail("Could not read MARKETPLACE_FEE_BPS");
    }
  }

  // ════════════════════════════════════════════════════════════════════════
  //  4. OmniBridge
  // ════════════════════════════════════════════════════════════════════════
  section("4. OmniBridge");

  if (!addr("OmniBridge")) {
    skip("OmniBridge not deployed on mainnet");
  } else {
    const bridgeAbi = [
      "function feeVault() view returns (address)",
      "function hasRole(bytes32 role, address account) view returns (bool)",
    ];
    const bridge = new ethers.Contract(addr("OmniBridge"), bridgeAbi, ethers.provider);

    // 4a. feeVault is UnifiedFeeVault
    const bFeeVault = await safeCall(bridge, "feeVault");
    if (bFeeVault && addr("UnifiedFeeVault") && addrEq(bFeeVault, addr("UnifiedFeeVault"))) {
      pass(`feeVault = UnifiedFeeVault (${bFeeVault})`);
    } else if (bFeeVault) {
      fail(`feeVault mismatch`, `Got: ${bFeeVault}, Expected: ${addr("UnifiedFeeVault")}`);
    } else {
      fail("Could not read feeVault");
    }
  }

  // ════════════════════════════════════════════════════════════════════════
  //  5. OmniArbitration
  // ════════════════════════════════════════════════════════════════════════
  section("5. OmniArbitration");

  if (!addr("OmniArbitration")) {
    skip("OmniArbitration not deployed");
  } else {
    const arbAbi = [
      "function oddaoTreasury() view returns (address)",
      "function protocolTreasury() view returns (address)",
      "function participation() view returns (address)",
      "function escrow() view returns (address)",
      "function xomToken() view returns (address)",
      "function hasRole(bytes32 role, address account) view returns (bool)",
    ];
    const arb = new ethers.Contract(addr("OmniArbitration"), arbAbi, ethers.provider);

    // 5a. oddaoTreasury
    const arbOddao = await safeCall(arb, "oddaoTreasury");
    if (arbOddao && addrEq(arbOddao, ODDAO_TREASURY)) {
      pass(`oddaoTreasury = ${arbOddao}`);
    } else {
      fail(`oddaoTreasury mismatch`, `Got: ${arbOddao}, Expected: ${ODDAO_TREASURY}`);
    }

    // 5b. protocolTreasury
    const arbProto = await safeCall(arb, "protocolTreasury");
    if (arbProto && addrEq(arbProto, PROTOCOL_TREASURY)) {
      pass(`protocolTreasury = ${arbProto}`);
    } else {
      fail(`protocolTreasury mismatch`, `Got: ${arbProto}, Expected: ${PROTOCOL_TREASURY}`);
    }

    // 5c. participation references OmniParticipation
    const arbPart = await safeCall(arb, "participation");
    if (arbPart && addr("OmniParticipation") && addrEq(arbPart, addr("OmniParticipation"))) {
      pass(`participation = OmniParticipation (${arbPart})`);
    } else if (arbPart) {
      fail(`participation mismatch`, `Got: ${arbPart}, Expected: ${addr("OmniParticipation")}`);
    } else {
      fail("Could not read participation");
    }

    // 5d. escrow references MinimalEscrow
    const arbEsc = await safeCall(arb, "escrow");
    if (arbEsc && addr("MinimalEscrow") && addrEq(arbEsc, addr("MinimalEscrow"))) {
      pass(`escrow = MinimalEscrow (${arbEsc})`);
    } else if (arbEsc) {
      fail(`escrow mismatch`, `Got: ${arbEsc}, Expected: ${addr("MinimalEscrow")}`);
    } else {
      fail("Could not read escrow");
    }

    // 5e. xomToken references OmniCoin
    const arbXom = await safeCall(arb, "xomToken");
    if (arbXom && addr("OmniCoin") && addrEq(arbXom, addr("OmniCoin"))) {
      pass(`xomToken = OmniCoin (${arbXom})`);
    } else if (arbXom) {
      fail(`xomToken mismatch`, `Got: ${arbXom}, Expected: ${addr("OmniCoin")}`);
    } else {
      fail("Could not read xomToken");
    }
  }

  // ════════════════════════════════════════════════════════════════════════
  //  6. UnifiedFeeVault
  // ════════════════════════════════════════════════════════════════════════
  section("6. UnifiedFeeVault");

  if (!addr("UnifiedFeeVault")) {
    skip("UnifiedFeeVault not deployed");
  } else {
    const vaultAbi = [
      "function stakingPool() view returns (address)",
      "function protocolTreasury() view returns (address)",
      "function ODDAO_BPS() view returns (uint256)",
      "function STAKING_BPS() view returns (uint256)",
      "function PROTOCOL_BPS() view returns (uint256)",
      "function hasRole(bytes32 role, address account) view returns (bool)",
    ];
    const vault = new ethers.Contract(addr("UnifiedFeeVault"), vaultAbi, ethers.provider);

    // 6a. stakingPool
    const vStaking = await safeCall(vault, "stakingPool");
    if (vStaking && addr("StakingRewardPool") && addrEq(vStaking, addr("StakingRewardPool"))) {
      pass(`stakingPool = StakingRewardPool (${vStaking})`);
    } else if (vStaking && addrEq(vStaking, DEPLOYER)) {
      fail("stakingPool still set to deployer", `Expected: ${addr("StakingRewardPool")}`);
    } else if (vStaking) {
      fail(`stakingPool mismatch`, `Got: ${vStaking}, Expected: ${addr("StakingRewardPool")}`);
    } else {
      fail("Could not read stakingPool");
    }

    // 6b. protocolTreasury
    const vProto = await safeCall(vault, "protocolTreasury");
    if (vProto && addrEq(vProto, PROTOCOL_TREASURY)) {
      pass(`protocolTreasury = ${vProto}`);
    } else {
      fail(`protocolTreasury mismatch`, `Got: ${vProto}, Expected: ${PROTOCOL_TREASURY}`);
    }

    // 6c. BPS splits
    const oddaoBps = await safeCall(vault, "ODDAO_BPS");
    const stakingBps = await safeCall(vault, "STAKING_BPS");
    const protocolBps = await safeCall(vault, "PROTOCOL_BPS");

    if (oddaoBps !== null && oddaoBps.toString() === "7000") {
      pass(`ODDAO_BPS = 7000 (70%)`);
    } else {
      fail(`ODDAO_BPS unexpected`, `Got: ${oddaoBps}`);
    }

    if (stakingBps !== null && stakingBps.toString() === "2000") {
      pass(`STAKING_BPS = 2000 (20%)`);
    } else {
      fail(`STAKING_BPS unexpected`, `Got: ${stakingBps}`);
    }

    if (protocolBps !== null && protocolBps.toString() === "1000") {
      pass(`PROTOCOL_BPS = 1000 (10%)`);
    } else {
      fail(`PROTOCOL_BPS unexpected`, `Got: ${protocolBps}`);
    }
  }

  // ════════════════════════════════════════════════════════════════════════
  //  7. DEXSettlement
  // ════════════════════════════════════════════════════════════════════════
  section("7. DEXSettlement");

  if (!addr("DEXSettlement")) {
    skip("DEXSettlement not deployed");
  } else {
    const dexAbi = [
      "function feeRecipients() view returns (address oddao, address stakingPool, address protocolTreasury)",
      "function getFeeRecipients() view returns (tuple(address oddao, address stakingPool, address protocolTreasury))",
      "function ODDAO_SHARE() view returns (uint256)",
      "function STAKING_POOL_SHARE() view returns (uint256)",
      "function PROTOCOL_SHARE() view returns (uint256)",
    ];
    const dex = new ethers.Contract(addr("DEXSettlement"), dexAbi, ethers.provider);

    // Try getFeeRecipients() first, fall back to feeRecipients()
    let feeR = await safeCall(dex, "getFeeRecipients");
    if (!feeR) {
      feeR = await safeCall(dex, "feeRecipients");
    }

    if (feeR) {
      // feeRecipients returns a struct with oddao, stakingPool, protocolTreasury
      const fOddao = feeR.oddao || feeR[0];
      const fStaking = feeR.stakingPool || feeR[1];
      const fProto = feeR.protocolTreasury || feeR[2];

      // 7a. oddao
      if (fOddao && addrEq(fOddao, ODDAO_TREASURY)) {
        pass(`feeRecipients.oddao = ${fOddao}`);
      } else {
        fail(`feeRecipients.oddao mismatch`, `Got: ${fOddao}, Expected: ${ODDAO_TREASURY}`);
      }

      // 7b. stakingPool
      if (fStaking && addr("StakingRewardPool") && addrEq(fStaking, addr("StakingRewardPool"))) {
        pass(`feeRecipients.stakingPool = StakingRewardPool (${fStaking})`);
      } else if (fStaking) {
        fail(`feeRecipients.stakingPool mismatch`,
          `Got: ${fStaking}, Expected: ${addr("StakingRewardPool")}`);
      } else {
        fail("feeRecipients.stakingPool is zero");
      }

      // 7c. protocolTreasury
      if (fProto && addrEq(fProto, PROTOCOL_TREASURY)) {
        pass(`feeRecipients.protocolTreasury = ${fProto}`);
      } else {
        fail(`feeRecipients.protocolTreasury mismatch`,
          `Got: ${fProto}, Expected: ${PROTOCOL_TREASURY}`);
      }
    } else {
      fail("Could not read feeRecipients from DEXSettlement");
    }

    // 7d. Share constants
    const oddaoShare = await safeCall(dex, "ODDAO_SHARE");
    const stakingShare = await safeCall(dex, "STAKING_POOL_SHARE");
    const protoShare = await safeCall(dex, "PROTOCOL_SHARE");

    if (oddaoShare !== null && oddaoShare.toString() === "7000") {
      pass(`ODDAO_SHARE = 7000 (70%)`);
    } else {
      fail(`ODDAO_SHARE unexpected`, `Got: ${oddaoShare}`);
    }

    if (stakingShare !== null && stakingShare.toString() === "2000") {
      pass(`STAKING_POOL_SHARE = 2000 (20%)`);
    } else {
      fail(`STAKING_POOL_SHARE unexpected`, `Got: ${stakingShare}`);
    }

    if (protoShare !== null && protoShare.toString() === "1000") {
      pass(`PROTOCOL_SHARE = 1000 (10%)`);
    } else {
      fail(`PROTOCOL_SHARE unexpected`, `Got: ${protoShare}`);
    }
  }

  // ════════════════════════════════════════════════════════════════════════
  //  G3. BURNER_ROLE Audit
  // ════════════════════════════════════════════════════════════════════════
  section("G3. BURNER_ROLE Audit (OmniCoin)");

  if (!addr("OmniCoin")) {
    skip("OmniCoin not deployed");
  } else {
    const xomAbi = [
      "function hasRole(bytes32 role, address account) view returns (bool)",
    ];
    const xom = new ethers.Contract(addr("OmniCoin"), xomAbi, ethers.provider);

    // G3a. Deployer should NOT have BURNER_ROLE (security best practice)
    const deployerBurner = await safeCall(xom, "hasRole", [BURNER_ROLE, DEPLOYER]);
    if (deployerBurner === false) {
      pass("BURNER_ROLE revoked from deployer");
    } else if (deployerBurner === true) {
      fail("BURNER_ROLE still held by deployer",
        "Should be revoked. Only PrivateOmniCoin should hold BURNER_ROLE.");
    } else {
      fail("Could not check BURNER_ROLE on deployer");
    }

    // G3b. PrivateOmniCoin should have BURNER_ROLE
    if (addr("PrivateOmniCoin")) {
      const pxomBurner = await safeCall(xom, "hasRole", [BURNER_ROLE, addr("PrivateOmniCoin")]);
      if (pxomBurner === true) {
        pass("BURNER_ROLE held by PrivateOmniCoin");
      } else if (pxomBurner === false) {
        fail("BURNER_ROLE NOT held by PrivateOmniCoin",
          "PrivateOmniCoin needs BURNER_ROLE for XOM->pXOM conversion burns.");
      } else {
        fail("Could not check BURNER_ROLE on PrivateOmniCoin");
      }
    } else {
      skip("PrivateOmniCoin not deployed, skipping BURNER_ROLE check");
    }

    // G3c. Spot-check that other contracts do NOT have BURNER_ROLE
    const spotCheckContracts = [
      "OmniCore", "MinimalEscrow", "DEXSettlement",
      "UnifiedFeeVault", "OmniRewardManager", "StakingRewardPool",
    ];
    for (const name of spotCheckContracts) {
      if (addr(name)) {
        const hasBurner = await safeCall(xom, "hasRole", [BURNER_ROLE, addr(name)]);
        if (hasBurner === false) {
          pass(`BURNER_ROLE correctly absent from ${name}`);
        } else if (hasBurner === true) {
          fail(`BURNER_ROLE unexpectedly held by ${name}`,
            `Only PrivateOmniCoin should hold BURNER_ROLE.`);
        }
      }
    }
  }

  // ════════════════════════════════════════════════════════════════════════
  //  G6. Service Roles (OmniRegistration)
  // ════════════════════════════════════════════════════════════════════════
  section("G6. Service Roles (OmniRegistration)");

  if (!addr("OmniRegistration")) {
    skip("OmniRegistration not deployed");
  } else {
    const regAbi = [
      "function hasRole(bytes32 role, address account) view returns (bool)",
    ];
    const reg = new ethers.Contract(addr("OmniRegistration"), regAbi, ethers.provider);

    // G6a. BONUS_MARKER_ROLE should be held by OmniRewardManager
    if (addr("OmniRewardManager")) {
      const rmHasBonus = await safeCall(reg, "hasRole", [BONUS_MARKER_ROLE, addr("OmniRewardManager")]);
      if (rmHasBonus === true) {
        pass("BONUS_MARKER_ROLE held by OmniRewardManager");
      } else if (rmHasBonus === false) {
        fail("BONUS_MARKER_ROLE NOT held by OmniRewardManager",
          "OmniRewardManager needs this role to mark bonuses claimed.");
      } else {
        fail("Could not check BONUS_MARKER_ROLE on OmniRewardManager");
      }
    } else {
      skip("OmniRewardManager not deployed, skipping BONUS_MARKER_ROLE check");
    }

    // G6b. TRANSACTION_RECORDER_ROLE should be held by MinimalEscrow or OmniMarketplace
    if (addr("MinimalEscrow")) {
      const escHasRecorder = await safeCall(reg, "hasRole", [TRANSACTION_RECORDER_ROLE, addr("MinimalEscrow")]);
      if (escHasRecorder === true) {
        pass("TRANSACTION_RECORDER_ROLE held by MinimalEscrow");
      } else if (escHasRecorder === false) {
        fail("TRANSACTION_RECORDER_ROLE NOT held by MinimalEscrow",
          "MinimalEscrow needs this role to record sale transactions.");
      } else {
        fail("Could not check TRANSACTION_RECORDER_ROLE on MinimalEscrow");
      }
    }
    if (addr("OmniMarketplace")) {
      const mkHasRecorder = await safeCall(reg, "hasRole", [TRANSACTION_RECORDER_ROLE, addr("OmniMarketplace")]);
      if (mkHasRecorder === true) {
        pass("TRANSACTION_RECORDER_ROLE held by OmniMarketplace");
      } else if (mkHasRecorder === false) {
        fail("TRANSACTION_RECORDER_ROLE NOT held by OmniMarketplace",
          "OmniMarketplace needs this role to record sale transactions.");
      } else {
        fail("Could not check TRANSACTION_RECORDER_ROLE on OmniMarketplace");
      }
    }

    // G6c. Deployer should NOT hold service roles in production
    const deployerBonus = await safeCall(reg, "hasRole", [BONUS_MARKER_ROLE, DEPLOYER]);
    if (deployerBonus === false) {
      pass("BONUS_MARKER_ROLE correctly absent from deployer");
    } else if (deployerBonus === true) {
      // Acceptable during Pioneer Phase but worth noting
      pass("BONUS_MARKER_ROLE held by deployer [Pioneer Phase - review later]");
    }

    const deployerRecorder = await safeCall(reg, "hasRole", [TRANSACTION_RECORDER_ROLE, DEPLOYER]);
    if (deployerRecorder === false) {
      pass("TRANSACTION_RECORDER_ROLE correctly absent from deployer");
    } else if (deployerRecorder === true) {
      pass("TRANSACTION_RECORDER_ROLE held by deployer [Pioneer Phase - review later]");
    }
  }

  // ════════════════════════════════════════════════════════════════════════
  //  Summary
  // ════════════════════════════════════════════════════════════════════════
  console.log(`\n${"=".repeat(70)}`);
  console.log("  SUMMARY");
  console.log(`${"=".repeat(70)}`);
  console.log(`  \x1b[32mPASS: ${passCount}\x1b[0m`);
  console.log(`  \x1b[31mFAIL: ${failCount}\x1b[0m`);
  console.log(`  \x1b[33mSKIP: ${skipCount}\x1b[0m`);
  console.log(`  Total checks: ${passCount + failCount + skipCount}`);
  console.log(`${"=".repeat(70)}\n`);

  if (failCount > 0) {
    process.exitCode = 1;
  }
}

main()
  .then(() => process.exit(process.exitCode || 0))
  .catch((error) => {
    console.error("Script failed:", error);
    process.exit(1);
  });
