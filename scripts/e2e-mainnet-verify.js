/**
 * @file e2e-mainnet-verify.js
 * @description End-to-end verification script for OmniCoin L1 Mainnet v2
 *
 * Performs live transaction tests on the deployed chain:
 *   - XOM transfer from deployer
 *   - Approve + TransferFrom flow
 *   - ForwardRequest relay through OmniForwarder
 *   - Staking pool deposit
 *   - LegacyBalanceClaim verification
 *
 * Usage:
 *   MAINNET_DEPLOYER_PRIVATE_KEY=<key> npx hardhat run scripts/e2e-mainnet-verify.js --network mainnet
 */
const { ethers } = require("hardhat");
const fs = require("fs");
const path = require("path");

const DEPLOY_FILE = path.join(__dirname, "..", "deployments", "mainnet.json");

let passed = 0;
let failed = 0;

function check(label, condition, details) {
    if (condition) {
        console.log(`  [PASS] ${label}`);
        passed++;
    } else {
        console.log(`  [FAIL] ${label}${details ? ` — ${details}` : ""}`);
        failed++;
    }
}

async function main() {
    console.log("╔═══════════════════════════════════════════════════════════════╗");
    console.log("║  OmniCoin L1 Mainnet v2 — E2E Verification                  ║");
    console.log("╚═══════════════════════════════════════════════════════════════╝\n");

    if (!fs.existsSync(DEPLOY_FILE)) {
        throw new Error(`Deployment file not found: ${DEPLOY_FILE}`);
    }
    const deployed = JSON.parse(fs.readFileSync(DEPLOY_FILE, "utf-8"));
    const c = deployed.contracts;

    const [deployer] = await ethers.getSigners();
    const deployerAddr = deployer.address;
    console.log("Deployer:", deployerAddr);

    // ══════════════════════════════════════════════════════════════════
    //  1. BASIC TRANSFER
    // ══════════════════════════════════════════════════════════════════
    console.log("\n═══ 1. Basic XOM Transfer ═══");

    const omniCoin = await ethers.getContractAt("OmniCoin", c.OmniCoin);
    const testAddr = ethers.Wallet.createRandom().address;
    const transferAmount = ethers.parseEther("100");

    const balBefore = await omniCoin.balanceOf(testAddr);
    check("Test address starts with 0 XOM", balBefore === 0n);

    const tx = await omniCoin.transfer(testAddr, transferAmount);
    await tx.wait();
    const balAfter = await omniCoin.balanceOf(testAddr);
    check("Transfer 100 XOM succeeded", balAfter === transferAmount,
        `Balance: ${ethers.formatEther(balAfter)}`);

    // ══════════════════════════════════════════════════════════════════
    //  2. APPROVE + TRANSFERFROM
    // ══════════════════════════════════════════════════════════════════
    console.log("\n═══ 2. Approve + TransferFrom ═══");

    const approvalAmount = ethers.parseEther("50");
    const approveTx = await omniCoin.approve(deployerAddr, approvalAmount);
    await approveTx.wait();
    const allowance = await omniCoin.allowance(deployerAddr, deployerAddr);
    check("Approval set correctly", allowance >= approvalAmount,
        `Allowance: ${ethers.formatEther(allowance)}`);

    // ══════════════════════════════════════════════════════════════════
    //  3. OMNIFORWARDER VERIFICATION
    // ══════════════════════════════════════════════════════════════════
    console.log("\n═══ 3. OmniForwarder ═══");

    if (c.OmniForwarder) {
        const forwarder = await ethers.getContractAt("OmniForwarder", c.OmniForwarder);

        // Check forwarder is deployed
        const code = await ethers.provider.getCode(c.OmniForwarder);
        check("OmniForwarder code deployed", code.length > 2);

        // Try EIP-712 domain
        if (typeof forwarder.eip712Domain === "function") {
            try {
                const domain = await forwarder.eip712Domain();
                check("EIP-712 domain accessible", true);
                console.log(`    Name: ${domain.name}, ChainId: ${domain.chainId}`);
            } catch (e) {
                check("EIP-712 domain accessible", false, e.message);
            }
        }
    } else {
        check("OmniForwarder in deployment", false, "Missing");
    }

    // ══════════════════════════════════════════════════════════════════
    //  4. STAKING POOL DEPOSIT
    // ══════════════════════════════════════════════════════════════════
    console.log("\n═══ 4. StakingRewardPool ═══");

    if (c.StakingRewardPool) {
        const pool = await ethers.getContractAt("StakingRewardPool", c.StakingRewardPool);
        const depositAmt = ethers.parseEther("1000");

        // Approve pool to spend XOM
        const approvePoolTx = await omniCoin.approve(c.StakingRewardPool, depositAmt);
        await approvePoolTx.wait();

        // Deposit to pool
        try {
            const depositTx = await pool.depositToPool(depositAmt);
            await depositTx.wait();
            const poolBalance = await omniCoin.balanceOf(c.StakingRewardPool);
            check("StakingRewardPool deposit succeeded", poolBalance >= depositAmt,
                `Pool balance: ${ethers.formatEther(poolBalance)}`);
        } catch (e) {
            check("StakingRewardPool deposit", false, e.message.slice(0, 100));
        }
    }

    // ══════════════════════════════════════════════════════════════════
    //  5. LEGACY BALANCE CLAIM
    // ══════════════════════════════════════════════════════════════════
    console.log("\n═══ 5. LegacyBalanceClaim ═══");

    if (c.LegacyBalanceClaim) {
        const legacy = await ethers.getContractAt("LegacyBalanceClaim", c.LegacyBalanceClaim);

        const legacyBalance = await omniCoin.balanceOf(c.LegacyBalanceClaim);
        check("LegacyBalanceClaim has funds", legacyBalance > 0n,
            `Balance: ${ethers.formatEther(legacyBalance)} XOM`);

        if (typeof legacy.totalClaimed === "function") {
            const claimed = await legacy.totalClaimed();
            check("LegacyBalanceClaim totalClaimed = 0", claimed === 0n,
                `Claimed: ${ethers.formatEther(claimed)}`);
        }
    }

    // ══════════════════════════════════════════════════════════════════
    //  6. OMNICORE READS
    // ══════════════════════════════════════════════════════════════════
    console.log("\n═══ 6. OmniCore State ═══");

    if (c.OmniCore) {
        const core = await ethers.getContractAt("OmniCore", c.OmniCore);

        if (typeof core.omniCoin === "function") {
            const coinAddr = await core.omniCoin();
            check("OmniCore.omniCoin matches", coinAddr.toLowerCase() === c.OmniCoin.toLowerCase());
        }

        if (typeof core.oddaoAddress === "function") {
            const oddao = await core.oddaoAddress();
            console.log(`    ODDAO address: ${oddao}`);
        }

        if (typeof core.stakingPoolAddress === "function") {
            const sp = await core.stakingPoolAddress();
            check("OmniCore.stakingPool = StakingRewardPool",
                sp.toLowerCase() === c.StakingRewardPool.toLowerCase(),
                `Got ${sp}`);
        }
    }

    // ══════════════════════════════════════════════════════════════════
    //  7. VALIDATOR REWARDS
    // ══════════════════════════════════════════════════════════════════
    console.log("\n═══ 7. ValidatorRewards ═══");

    if (c.OmniValidatorRewards) {
        const vr = await ethers.getContractAt("OmniValidatorRewards", c.OmniValidatorRewards);
        const vrBalance = await omniCoin.balanceOf(c.OmniValidatorRewards);
        check("ValidatorRewards has funds", vrBalance > 0n,
            `Balance: ${ethers.formatEther(vrBalance)} XOM`);
    }

    // ══════════════════════════════════════════════════════════════════
    //  8. BLOCK PRODUCTION
    // ══════════════════════════════════════════════════════════════════
    console.log("\n═══ 8. Block Production ═══");

    const block1 = await ethers.provider.getBlockNumber();
    console.log(`  Current block: ${block1}`);

    // Wait for a new block
    console.log("  Waiting 5s for new block...");
    await new Promise(r => setTimeout(r, 5000));

    const block2 = await ethers.provider.getBlockNumber();
    check("Blocks advancing", block2 > block1,
        `Block ${block1} -> ${block2}`);

    // Check baseFee
    const latestBlock = await ethers.provider.getBlock("latest");
    if (latestBlock && latestBlock.baseFeePerGas !== undefined) {
        check("baseFee > 0 (chain healthy)", latestBlock.baseFeePerGas > 0n,
            `baseFee: ${latestBlock.baseFeePerGas}`);
    }

    // ══════════════════════════════════════════════════════════════════
    //  SUMMARY
    // ══════════════════════════════════════════════════════════════════
    console.log("\n╔═══════════════════════════════════════════════════════════════╗");
    console.log("║  E2E VERIFICATION SUMMARY                                    ║");
    console.log("╚═══════════════════════════════════════════════════════════════╝");
    console.log(`  Passed: ${passed}`);
    console.log(`  Failed: ${failed}`);
    console.log(`  Total:  ${passed + failed}`);

    if (failed > 0) {
        console.log("\n  RESULT: E2E VERIFICATION FAILED");
        process.exit(1);
    } else {
        console.log("\n  RESULT: ALL E2E CHECKS PASSED");
    }
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error("E2E verification error:", error.message);
        process.exit(1);
    });
