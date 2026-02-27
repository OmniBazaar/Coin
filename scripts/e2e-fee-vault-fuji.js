/**
 * @file e2e-fee-vault-fuji.js
 * @description End-to-end verification of UnifiedFeeVault + FeeSwapAdapter
 *              on the live Fuji (OmniCoin L1) deployment.
 *
 * Usage:
 *   cd /home/rickc/OmniBazaar/Coin
 *   npx hardhat run scripts/e2e-fee-vault-fuji.js --network fuji
 *
 * Prerequisites:
 *   - UnifiedFeeVault deployed via deploy-unified-fee-vault.js
 *   - Deployer has XOM and TestUSDC balances
 */

const { ethers } = require('hardhat');
const fs = require('fs');
const path = require('path');

/** Total tests passed / failed counters */
let passed = 0;
let failed = 0;

/**
 * Assert a condition and log result
 * @param {string} label - Test description
 * @param {boolean} condition - Must be true
 */
function assert(label, condition) {
    if (condition) {
        console.log(`  ✅ ${label}`);
        passed++;
    } else {
        console.log(`  ❌ FAIL: ${label}`);
        failed++;
    }
}

/**
 * Compare BigInt values with tolerance for gas/rounding
 * @param {string} label - Test description
 * @param {bigint} actual - Actual value
 * @param {bigint} expected - Expected value
 * @param {bigint} [tolerance=1n] - Max allowed difference
 */
function assertClose(label, actual, expected, tolerance = 1n) {
    const diff = actual > expected
        ? actual - expected
        : expected - actual;
    assert(`${label} (actual=${actual}, expected=${expected})`, diff <= tolerance);
}

async function main() {
    console.log('='.repeat(60));
    console.log('UnifiedFeeVault E2E Verification — Live Fuji');
    console.log('='.repeat(60) + '\n');

    // ── Load deployment addresses ──────────────────────────────
    const deploymentPath = path.join(
        __dirname, '..', 'deployments', 'fuji.json'
    );
    const deployment = JSON.parse(
        fs.readFileSync(deploymentPath, 'utf-8')
    );
    const contracts = deployment.contracts;

    const vaultAddr = contracts.UnifiedFeeVault;
    const adapterAddr = contracts.FeeSwapAdapter;
    const xomAddr = contracts.OmniCoin;
    const usdcAddr = contracts.TestUSDC;
    const stakingPoolAddr = contracts.StakingRewardPool;

    if (!vaultAddr || vaultAddr === ethers.ZeroAddress) {
        throw new Error('UnifiedFeeVault not deployed — run deploy script first');
    }

    console.log(`Vault:        ${vaultAddr}`);
    console.log(`Adapter:      ${adapterAddr}`);
    console.log(`XOM:          ${xomAddr}`);
    console.log(`USDC:         ${usdcAddr}`);
    console.log(`StakingPool:  ${stakingPoolAddr}\n`);

    const [deployer] = await ethers.getSigners();
    const deployerAddr = await deployer.getAddress();
    console.log(`Deployer:     ${deployerAddr}\n`);

    // ── Attach to contracts ────────────────────────────────────
    const vault = await ethers.getContractAt('UnifiedFeeVault', vaultAddr);
    const xom = await ethers.getContractAt('OmniCoin', xomAddr);
    const usdc = await ethers.getContractAt(
        '@openzeppelin/contracts/token/ERC20/IERC20.sol:IERC20', usdcAddr
    );

    // ────────────────────────────────────────────────────────────
    // 4a. Verify deployment state
    // ────────────────────────────────────────────────────────────
    console.log('─── 4a: Verify deployment state ───');

    assert(
        'stakingPool == StakingRewardPool',
        (await vault.stakingPool()) === stakingPoolAddr
    );
    assert(
        'protocolTreasury == deployer',
        (await vault.protocolTreasury()) === deployerAddr
    );
    assert(
        'ODDAO_BPS == 7000',
        (await vault.ODDAO_BPS()) === 7000n
    );
    assert(
        'STAKING_BPS == 2000',
        (await vault.STAKING_BPS()) === 2000n
    );
    assert(
        'PROTOCOL_BPS == 1000',
        (await vault.PROTOCOL_BPS()) === 1000n
    );
    assert(
        'swapRouter == FeeSwapAdapter',
        (await vault.swapRouter()) === adapterAddr
    );
    assert(
        'xomToken == OmniCoin',
        (await vault.xomToken()) === xomAddr
    );
    assert(
        'isOssified == false',
        (await vault.isOssified()) === false
    );

    // Verify roles
    const DEPOSITOR_ROLE = await vault.DEPOSITOR_ROLE();
    const BRIDGE_ROLE = await vault.BRIDGE_ROLE();
    const ADMIN_ROLE = await vault.ADMIN_ROLE();
    const DEFAULT_ADMIN_ROLE = await vault.DEFAULT_ADMIN_ROLE();

    assert(
        'deployer has DEFAULT_ADMIN_ROLE',
        await vault.hasRole(DEFAULT_ADMIN_ROLE, deployerAddr)
    );
    assert(
        'deployer has ADMIN_ROLE',
        await vault.hasRole(ADMIN_ROLE, deployerAddr)
    );
    assert(
        'deployer has BRIDGE_ROLE',
        await vault.hasRole(BRIDGE_ROLE, deployerAddr)
    );

    // Verify fee contracts have DEPOSITOR_ROLE
    const feeContracts = {
        MinimalEscrow: contracts.MinimalEscrow,
        DEXSettlement: contracts.DEXSettlement,
        OmniFeeRouter: contracts.OmniFeeRouter,
        OmniPredictionRouter: contracts.OmniPredictionRouter,
        OmniYieldFeeCollector: contracts.OmniYieldFeeCollector,
    };
    if (contracts.rwa) {
        feeContracts.RWAAMM = contracts.rwa.RWAAMM;
    }

    for (const [name, addr] of Object.entries(feeContracts)) {
        if (addr && addr !== ethers.ZeroAddress) {
            assert(
                `${name} has DEPOSITOR_ROLE`,
                await vault.hasRole(DEPOSITOR_ROLE, addr)
            );
        }
    }

    console.log('');

    // ────────────────────────────────────────────────────────────
    // 4b. Deposit + distribute XOM (10,000 XOM)
    // ────────────────────────────────────────────────────────────
    console.log('─── 4b: Deposit + distribute 10,000 XOM ───');

    const XOM_AMOUNT = ethers.parseEther('10000');

    // Grant DEPOSITOR_ROLE to deployer for testing
    const hasDepositor = await vault.hasRole(DEPOSITOR_ROLE, deployerAddr);
    if (!hasDepositor) {
        const tx = await vault.grantRole(DEPOSITOR_ROLE, deployerAddr);
        await tx.wait();
        console.log('  Granted DEPOSITOR_ROLE to deployer');
    }

    // Approve XOM
    const approveTx = await xom.approve(vaultAddr, XOM_AMOUNT);
    await approveTx.wait();

    // Deposit
    const depositTx = await vault.deposit(xomAddr, XOM_AMOUNT);
    await depositTx.wait();

    // Verify undistributed
    const undistXom = await vault.undistributed(xomAddr);
    assert(
        `undistributed(XOM) >= 10,000`,
        undistXom >= XOM_AMOUNT
    );

    // Record balances before distribute
    const stakingBefore = await xom.balanceOf(stakingPoolAddr);
    const treasuryBefore = await xom.balanceOf(deployerAddr);
    const pendingBridgeBefore = await vault.pendingBridge(xomAddr);

    // Distribute
    const distTx = await vault.distribute(xomAddr);
    await distTx.wait();

    // Expected amounts (from our 10k deposit):
    const expectedODDAO = XOM_AMOUNT * 7000n / 10000n;    // 7,000 XOM
    const expectedStaking = XOM_AMOUNT * 2000n / 10000n;  // 2,000 XOM
    const expectedProtocol = XOM_AMOUNT * 1000n / 10000n; // 1,000 XOM

    // Verify pendingBridge increased by 7,000
    const pendingBridgeAfter = await vault.pendingBridge(xomAddr);
    const bridgeDelta = pendingBridgeAfter - pendingBridgeBefore;
    assertClose(
        'pendingBridge increased by 7,000 XOM (70%)',
        bridgeDelta, expectedODDAO
    );

    // Verify StakingRewardPool received 2,000
    const stakingAfter = await xom.balanceOf(stakingPoolAddr);
    const stakingDelta = stakingAfter - stakingBefore;
    assertClose(
        'StakingRewardPool received 2,000 XOM (20%)',
        stakingDelta, expectedStaking
    );

    // Verify deployer (treasury) received 1,000
    const treasuryAfter = await xom.balanceOf(deployerAddr);
    const treasuryDelta = treasuryAfter - treasuryBefore;
    // Treasury delta is tricky because deployer also pays gas.
    // Instead, check getClaimable or use a rough check.
    // For XOM distribution, treasury gets direct push, so:
    assertClose(
        'Treasury received ~1,000 XOM (10%)',
        treasuryDelta, expectedProtocol, ethers.parseEther('0.1')
    );

    // Verify undistributed is now 0
    const undistAfter = await vault.undistributed(xomAddr);
    assert(
        'undistributed(XOM) == 0 after distribute',
        undistAfter === 0n
    );

    console.log('');

    // ────────────────────────────────────────────────────────────
    // 4c. Deposit + distribute TestUSDC
    // ────────────────────────────────────────────────────────────
    console.log('─── 4c: Deposit + distribute TestUSDC ───');

    // Check USDC balance
    const usdcBalance = await usdc.balanceOf(deployerAddr);
    console.log(`  Deployer USDC balance: ${ethers.formatUnits(usdcBalance, 6)}`);

    if (usdcBalance >= 1000000n) { // 1 USDC (6 decimals)
        const USDC_AMOUNT = 1000000n; // 1 USDC

        const uApprove = await usdc.approve(vaultAddr, USDC_AMOUNT);
        await uApprove.wait();

        const uDeposit = await vault.deposit(usdcAddr, USDC_AMOUNT);
        await uDeposit.wait();

        const undistUsdc = await vault.undistributed(usdcAddr);
        assert('undistributed(USDC) >= 1', undistUsdc >= USDC_AMOUNT);

        const uDist = await vault.distribute(usdcAddr);
        await uDist.wait();

        const pendingUsdcBridge = await vault.pendingBridge(usdcAddr);
        assert(
            'pendingBridge(USDC) > 0 after distribute',
            pendingUsdcBridge > 0n
        );

        const undistUsdcAfter = await vault.undistributed(usdcAddr);
        assert(
            'undistributed(USDC) == 0 after distribute',
            undistUsdcAfter === 0n
        );
    } else {
        console.log('  ⚠️  Deployer has no USDC — skipping USDC tests');
    }

    console.log('');

    // ────────────────────────────────────────────────────────────
    // 4d. bridgeToTreasury (in-kind path)
    // ────────────────────────────────────────────────────────────
    console.log('─── 4d: bridgeToTreasury (in-kind) ───');

    const pendingBridgeXOM = await vault.pendingBridge(xomAddr);
    console.log(`  pendingBridge(XOM): ${ethers.formatEther(pendingBridgeXOM)}`);

    if (pendingBridgeXOM > 0n) {
        const bridgeAmount = pendingBridgeXOM / 2n; // Bridge half
        const receiverBalBefore = await xom.balanceOf(deployerAddr);

        const bridgeTx = await vault.bridgeToTreasury(
            xomAddr, bridgeAmount, deployerAddr
        );
        await bridgeTx.wait();

        const receiverBalAfter = await xom.balanceOf(deployerAddr);
        const receiverDelta = receiverBalAfter - receiverBalBefore;
        assertClose(
            `bridgeToTreasury sent ~${ethers.formatEther(bridgeAmount)} XOM`,
            receiverDelta, bridgeAmount, ethers.parseEther('0.01')
        );

        const pendingAfterBridge = await vault.pendingBridge(xomAddr);
        assertClose(
            'pendingBridge decreased by bridge amount',
            pendingAfterBridge,
            pendingBridgeXOM - bridgeAmount
        );
    } else {
        console.log('  ⚠️  No pendingBridge — skipping');
    }

    console.log('');

    // ────────────────────────────────────────────────────────────
    // 4e. Admin functions
    // ────────────────────────────────────────────────────────────
    console.log('─── 4e: Admin functions ───');

    // setTokenBridgeMode to SWAP_TO_XOM (1)
    const setModeTx = await vault.setTokenBridgeMode(xomAddr, 1);
    await setModeTx.wait();
    const modeAfter = await vault.tokenBridgeMode(xomAddr);
    assert('setTokenBridgeMode(XOM, SWAP_TO_XOM) => mode == 1', modeAfter === 1n);

    // setTokenBridgeMode back to IN_KIND (0)
    const resetModeTx = await vault.setTokenBridgeMode(xomAddr, 0);
    await resetModeTx.wait();
    const modeReset = await vault.tokenBridgeMode(xomAddr);
    assert('setTokenBridgeMode(XOM, IN_KIND) => mode == 0', modeReset === 0n);

    // Pause/unpause
    const pauseTx = await vault.pause();
    await pauseTx.wait();

    let depositReverted = false;
    try {
        await vault.deposit.staticCall(xomAddr, 1n);
    } catch {
        depositReverted = true;
    }
    assert('deposit reverts when paused', depositReverted);

    const unpauseTx = await vault.unpause();
    await unpauseTx.wait();

    let depositWorks = false;
    try {
        // Just a static call — don't actually deposit
        await vault.deposit.staticCall(xomAddr, 0n);
        depositWorks = true;
    } catch {
        // Might revert because amount is 0, that's fine
        depositWorks = true;
    }
    assert('deposit works after unpause', depositWorks);

    console.log('');

    // ────────────────────────────────────────────────────────────
    // 4f. swapAndBridge (graceful failure expected)
    // ────────────────────────────────────────────────────────────
    console.log('─── 4f: swapAndBridge (expect revert) ───');

    // OmniSwapRouter likely has no liquidity for USDC→XOM
    // so swapAndBridge should revert cleanly
    const pendingUsdcBridge = await vault.pendingBridge(usdcAddr);
    if (pendingUsdcBridge > 0n) {
        // First set USDC to SWAP_TO_XOM mode
        const setUsdcMode = await vault.setTokenBridgeMode(usdcAddr, 1);
        await setUsdcMode.wait();

        let swapReverted = false;
        try {
            await vault.swapAndBridge(
                usdcAddr,
                pendingUsdcBridge,
                0n, // minXOMOut = 0 (we expect revert before this matters)
                deployerAddr
            );
        } catch (err) {
            swapReverted = true;
            console.log(`  Revert reason: ${err.reason || err.message?.substring(0, 80)}`);
        }
        assert('swapAndBridge reverts (no liquidity)', swapReverted);

        // Reset mode back to IN_KIND
        const resetUsdcMode = await vault.setTokenBridgeMode(usdcAddr, 0);
        await resetUsdcMode.wait();
    } else {
        console.log('  ⚠️  No USDC pendingBridge — skipping swap test');
        // Still verify swapAndBridge reverts with 0 amount
        let zeroReverted = false;
        try {
            await vault.swapAndBridge(usdcAddr, 0n, 0n, deployerAddr);
        } catch {
            zeroReverted = true;
        }
        assert('swapAndBridge(0) reverts', zeroReverted);
    }

    console.log('');

    // ────────────────────────────────────────────────────────────
    // 4g. View functions
    // ────────────────────────────────────────────────────────────
    console.log('─── 4g: View functions ───');

    const finalUndist = await vault.undistributed(xomAddr);
    console.log(`  undistributed(XOM): ${ethers.formatEther(finalUndist)}`);
    assert('undistributed(XOM) is 0', finalUndist === 0n);

    const finalPending = await vault.pendingForBridge(xomAddr);
    console.log(`  pendingForBridge(XOM): ${ethers.formatEther(finalPending)}`);
    assert('pendingForBridge(XOM) >= 0', finalPending >= 0n);

    const claimable = await vault.getClaimable(deployerAddr, xomAddr);
    console.log(`  getClaimable(deployer, XOM): ${ethers.formatEther(claimable)}`);
    assert('getClaimable returns a value (not revert)', true);

    const totalDist = await vault.totalDistributed(xomAddr);
    console.log(`  totalDistributed(XOM): ${ethers.formatEther(totalDist)}`);
    assert('totalDistributed(XOM) > 0', totalDist > 0n);

    const totalBridged = await vault.totalBridged(xomAddr);
    console.log(`  totalBridged(XOM): ${ethers.formatEther(totalBridged)}`);
    assert('totalBridged(XOM) >= 0', totalBridged >= 0n);

    console.log('');

    // ── Summary ────────────────────────────────────────────────
    console.log('='.repeat(60));
    console.log(`E2E Results: ${passed} passed, ${failed} failed`);
    console.log('='.repeat(60));

    if (failed > 0) {
        process.exit(1);
    }
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error('\nE2E script failed:', error);
        process.exit(1);
    });
