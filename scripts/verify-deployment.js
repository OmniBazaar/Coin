/**
 * @file verify-deployment.js
 * @description Post-deployment verification script for OmniCoin L1 Mainnet v2
 *
 * Checks all contracts, roles, funding, and cross-contract wiring against
 * the deployment JSON file (deployments/mainnet.json).
 *
 * Usage:
 *   npx hardhat run scripts/verify-deployment.js --network mainnet
 */
const { ethers } = require("hardhat");
const fs = require("fs");
const path = require("path");

const DEPLOY_FILE = path.join(__dirname, "..", "deployments", "mainnet.json");
const ODDAO_TREASURY = "0x664B6347a69A22b35348D42E4640CA92e1609378";

let passed = 0;
let failed = 0;
let warnings = 0;

function check(label, condition, details) {
    if (condition) {
        console.log(`  [PASS] ${label}`);
        passed++;
    } else {
        console.log(`  [FAIL] ${label}${details ? ` — ${details}` : ""}`);
        failed++;
    }
}

function warn(label, details) {
    console.log(`  [WARN] ${label}${details ? ` — ${details}` : ""}`);
    warnings++;
}

async function main() {
    console.log("╔═══════════════════════════════════════════════════════════════╗");
    console.log("║  OmniCoin L1 Mainnet v2 — Deployment Verification           ║");
    console.log("╚═══════════════════════════════════════════════════════════════╝\n");

    // Load deployment JSON
    if (!fs.existsSync(DEPLOY_FILE)) {
        throw new Error(`Deployment file not found: ${DEPLOY_FILE}`);
    }
    const deployed = JSON.parse(fs.readFileSync(DEPLOY_FILE, "utf-8"));
    const c = deployed.contracts;
    const deployerAddr = deployed.deployer;

    console.log("Deployer:", deployerAddr);
    console.log("Network:", deployed.network, "Chain:", deployed.chainId);
    console.log(`Contracts in deployment: ${Object.keys(c).length}\n`);

    // ══════════════════════════════════════════════════════════════════
    //  1. NETWORK CHECKS
    // ══════════════════════════════════════════════════════════════════
    console.log("═══ 1. Network Checks ═══");

    const network = await ethers.provider.getNetwork();
    check("Chain ID = 88008", network.chainId === 88008n, `Got ${network.chainId}`);

    const feeData = await ethers.provider.getFeeData();
    check("baseFee > 0", feeData.gasPrice > 0n, `gasPrice=${feeData.gasPrice}`);

    const blockNum = await ethers.provider.getBlockNumber();
    check("Blocks advancing", blockNum > 0, `Current block: ${blockNum}`);

    // ══════════════════════════════════════════════════════════════════
    //  2. TOKEN SUPPLY
    // ══════════════════════════════════════════════════════════════════
    console.log("\n═══ 2. Token Supply ═══");

    const omniCoin = await ethers.getContractAt("OmniCoin", c.OmniCoin);
    const totalSupply = await omniCoin.totalSupply();
    const expected16_8B = ethers.parseEther("16800000000");
    check("OmniCoin totalSupply = 16.8B", totalSupply === expected16_8B,
        `Got ${ethers.formatEther(totalSupply)}`);

    // ══════════════════════════════════════════════════════════════════
    //  3. TOKEN FUNDING
    // ══════════════════════════════════════════════════════════════════
    console.log("\n═══ 3. Token Funding ═══");

    const legacyBalance = await omniCoin.balanceOf(c.LegacyBalanceClaim);
    check("LegacyBalanceClaim funded 4.32B", legacyBalance === ethers.parseEther("4320000000"),
        `Got ${ethers.formatEther(legacyBalance)}`);

    const rmBalance = await omniCoin.balanceOf(c.OmniRewardManager);
    const expectedRM = ethers.parseEther("6378000000"); // 1.383B + 2.995B + 2.0B
    check("OmniRewardManager funded 6.378B", rmBalance === expectedRM,
        `Got ${ethers.formatEther(rmBalance)}`);

    const vrBalance = await omniCoin.balanceOf(c.OmniValidatorRewards);
    check("OmniValidatorRewards funded 6.089B", vrBalance === ethers.parseEther("6088809316"),
        `Got ${ethers.formatEther(vrBalance)}`);

    const deployerXOM = await omniCoin.balanceOf(deployerAddr);
    console.log(`  Deployer remainder: ${ethers.formatEther(deployerXOM)} XOM`);

    // ══════════════════════════════════════════════════════════════════
    //  4. MINTER_ROLE REVOKED
    // ══════════════════════════════════════════════════════════════════
    console.log("\n═══ 4. MINTER_ROLE Revoked ═══");

    const MINTER_ROLE = await omniCoin.MINTER_ROLE();
    const deployerHasMinter = await omniCoin.hasRole(MINTER_ROLE, deployerAddr);
    check("MINTER_ROLE revoked from deployer", !deployerHasMinter,
        deployerHasMinter ? "CRITICAL: MINTER_ROLE still active!" : "");

    // ══════════════════════════════════════════════════════════════════
    //  5. UUPS PROXY VERIFICATION
    // ══════════════════════════════════════════════════════════════════
    console.log("\n═══ 5. UUPS Proxy Verification ═══");

    const proxyContracts = [
        "OmniCore", "OmniRegistration", "StakingRewardPool", "OmniGovernance",
        "OmniPriceOracle", "OmniParticipation", "OmniRewardManager",
        "OmniValidatorRewards", "UnifiedFeeVault", "OmniArbitration",
        "OmniMarketplace", "OmniPrivacyBridge", "OmniBridge", "ValidatorProvisioner",
    ];

    for (const name of proxyContracts) {
        if (c[name] && c[`${name}Implementation`]) {
            const implSlot = await ethers.provider.getStorage(
                c[name],
                "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc"
            );
            const implAddr = "0x" + implSlot.slice(26);
            const matches = implAddr.toLowerCase() === c[`${name}Implementation`].toLowerCase();
            check(`${name} proxy -> impl`, matches,
                matches ? "" : `Expected ${c[`${name}Implementation`]}, got ${implAddr}`);
        } else if (c[name]) {
            warn(`${name} has no implementation address recorded`);
        }
    }

    // ══════════════════════════════════════════════════════════════════
    //  6. ROLE ASSIGNMENTS
    // ══════════════════════════════════════════════════════════════════
    console.log("\n═══ 6. Role Assignments ═══");

    // OmniCore — PROVISIONER_ROLE to ValidatorProvisioner
    if (c.OmniCore && c.ValidatorProvisioner) {
        const omniCore = await ethers.getContractAt("OmniCore", c.OmniCore);
        const PROVISIONER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("PROVISIONER_ROLE"));
        const provHasRole = await omniCore.hasRole(PROVISIONER_ROLE, c.ValidatorProvisioner);
        check("OmniCore: PROVISIONER_ROLE -> ValidatorProvisioner", provHasRole);
    }

    // UnifiedFeeVault — DEPOSITOR_ROLE to 7 fee-generating contracts
    if (c.UnifiedFeeVault) {
        const feeVault = await ethers.getContractAt("UnifiedFeeVault", c.UnifiedFeeVault);
        const DEPOSITOR_ROLE = await feeVault.DEPOSITOR_ROLE();
        const BRIDGE_ROLE = await feeVault.BRIDGE_ROLE();

        const depositors = [
            "OmniMarketplace", "DEXSettlement", "OmniChatFee", "OmniENS",
            "MinimalEscrow", "OmniArbitration", "OmniSwapRouter",
        ];
        for (const name of depositors) {
            if (c[name]) {
                const hasRole = await feeVault.hasRole(DEPOSITOR_ROLE, c[name]);
                check(`UFV DEPOSITOR_ROLE -> ${name}`, hasRole);
            }
        }

        const deployerHasBridge = await feeVault.hasRole(BRIDGE_ROLE, deployerAddr);
        check("UFV BRIDGE_ROLE -> deployer", deployerHasBridge);
    }

    // OmniArbitration — DISPUTE_ADMIN_ROLE to deployer
    if (c.OmniArbitration) {
        const arb = await ethers.getContractAt("OmniArbitration", c.OmniArbitration);
        const DISPUTE_ADMIN_ROLE = await arb.DISPUTE_ADMIN_ROLE();
        const hasRole = await arb.hasRole(DISPUTE_ADMIN_ROLE, deployerAddr);
        check("OmniArbitration: DISPUTE_ADMIN_ROLE -> deployer", hasRole);
    }

    // ══════════════════════════════════════════════════════════════════
    //  7. CROSS-CONTRACT WIRING
    // ══════════════════════════════════════════════════════════════════
    console.log("\n═══ 7. Cross-Contract Wiring ═══");

    // OmniRegistration -> OmniRewardManager
    if (c.OmniRegistration && c.OmniRewardManager) {
        const reg = await ethers.getContractAt("OmniRegistration", c.OmniRegistration);
        if (typeof reg.omniRewardManagerAddress === "function") {
            const rmAddr = await reg.omniRewardManagerAddress();
            check("OmniRegistration -> OmniRewardManager",
                rmAddr.toLowerCase() === c.OmniRewardManager.toLowerCase(),
                `Set to ${rmAddr}`);
        }
    }

    // OmniRegistration authorized recorders
    if (c.OmniRegistration && c.MinimalEscrow) {
        const reg = await ethers.getContractAt("OmniRegistration", c.OmniRegistration);
        if (typeof reg.authorizedRecorders === "function") {
            const escrowAuth = await reg.authorizedRecorders(c.MinimalEscrow);
            check("OmniRegistration: MinimalEscrow is authorized recorder", escrowAuth);
        }
        if (c.DEXSettlement && typeof reg.authorizedRecorders === "function") {
            const dexAuth = await reg.authorizedRecorders(c.DEXSettlement);
            check("OmniRegistration: DEXSettlement is authorized recorder", dexAuth);
        }
    }

    // OmniCore -> Bootstrap (reinitializeV3)
    if (c.OmniCore && c.Bootstrap) {
        const core = await ethers.getContractAt("OmniCore", c.OmniCore);
        if (typeof core.bootstrap === "function") {
            const bsAddr = await core.bootstrap();
            check("OmniCore -> Bootstrap (reinitializeV3)",
                bsAddr.toLowerCase() === c.Bootstrap.toLowerCase(),
                `Set to ${bsAddr}`);
        }
    }

    // ══════════════════════════════════════════════════════════════════
    //  8. VALIDATOR PROVISIONER
    // ══════════════════════════════════════════════════════════════════
    console.log("\n═══ 8. Validator Provisioner ═══");

    if (c.ValidatorProvisioner) {
        const prov = await ethers.getContractAt("ValidatorProvisioner", c.ValidatorProvisioner);
        if (typeof prov.provisionedCount === "function") {
            const count = await prov.provisionedCount();
            console.log(`  Provisioned validators: ${count}`);
            if (count === 0n) {
                warn("No validators provisioned yet — fill in SEED_VALIDATORS array");
            } else {
                check("Seed validators provisioned", count >= 5n, `Count: ${count}`);
            }
        }
    }

    // ══════════════════════════════════════════════════════════════════
    //  9. OMNIFORWARDER
    // ══════════════════════════════════════════════════════════════════
    console.log("\n═══ 9. OmniForwarder ═══");

    if (c.OmniForwarder) {
        const code = await ethers.provider.getCode(c.OmniForwarder);
        check("OmniForwarder has code deployed", code.length > 2);
    }

    // ══════════════════════════════════════════════════════════════════
    //  10. CONTRACT CODE VERIFICATION
    // ══════════════════════════════════════════════════════════════════
    console.log("\n═══ 10. Contract Code Exists ═══");

    const criticalContracts = [
        "OmniCoin", "OmniCore", "OmniForwarder", "OmniRegistration",
        "StakingRewardPool", "UnifiedFeeVault", "OmniValidatorRewards",
        "ValidatorProvisioner", "Bootstrap", "MinimalEscrow",
        "OmniRewardManager", "LegacyBalanceClaim", "OmniGovernance",
    ];

    for (const name of criticalContracts) {
        if (c[name]) {
            const code = await ethers.provider.getCode(c[name]);
            check(`${name} has contract code`, code.length > 2,
                code.length <= 2 ? "NO CODE — deployment may have failed" : "");
        } else {
            check(`${name} in deployment JSON`, false, "Missing from deployment");
        }
    }

    // ══════════════════════════════════════════════════════════════════
    //  SUMMARY
    // ══════════════════════════════════════════════════════════════════
    console.log("\n╔═══════════════════════════════════════════════════════════════╗");
    console.log("║  VERIFICATION SUMMARY                                        ║");
    console.log("╚═══════════════════════════════════════════════════════════════╝");
    console.log(`  Passed:   ${passed}`);
    console.log(`  Failed:   ${failed}`);
    console.log(`  Warnings: ${warnings}`);
    console.log(`  Total:    ${passed + failed + warnings}`);

    if (failed > 0) {
        console.log("\n  RESULT: VERIFICATION FAILED — Fix issues above before proceeding");
        process.exit(1);
    } else if (warnings > 0) {
        console.log("\n  RESULT: PASSED with warnings — Review warnings above");
    } else {
        console.log("\n  RESULT: ALL CHECKS PASSED");
    }
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error("Verification error:", error.message);
        process.exit(1);
    });
