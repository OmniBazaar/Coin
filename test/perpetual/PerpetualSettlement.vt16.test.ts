/**
 * @file PerpetualSettlement.vt16.test.ts
 * @description VT-16 hardening tests for `PerpetualSettlement` — the
 * medianized mark price (§5.1) and the liquidation challenge + bond (§5.3).
 *
 * Two layers:
 *   1. Logic tests driven by a `MockBridgeVerifier` (operator-settable
 *      verify outcome) — cover the quorum gate, monotonic round, first-price
 *      anchor gap, deviation breaker, and the full provisional-liquidation
 *      challenge/finalize state machine.
 *   2. An end-to-end oracle-wiring test against the real
 *      `RandomCommitteeVerifierV2` + attestation mocks, proving the signed
 *      digest `keccak256(abi.encode(ORACLE_PRICE_DOMAIN, address(this),
 *      market, price, round))` is byte-exact end to end.
 */
/* eslint-disable @typescript-eslint/no-var-requires */
const { expect } = require('chai');
const { ethers, upgrades } = require('hardhat');

const BPS = 10_000n;
const HOUR = 3600n;
const FORWARDER = ethers.ZeroAddress; // ERC-2771 meta-tx disabled
const MARKET = ethers.id('XOM-USD');

const keccak256: (b: any) => string = ethers.keccak256;
const toUtf8Bytes: (s: string) => Uint8Array = ethers.toUtf8Bytes;
const concat: (a: any[]) => string = ethers.concat;
const getBytes: (v: any) => Uint8Array = ethers.getBytes;
const SigningKey = ethers.SigningKey;
const ETH_SIGNED_PREFIX = '\x19Ethereum Signed Message:\n32';

// Market config (100x max leverage; maintenance 0.5% < initial 1%).
const MAINT_BPS = 50n;
const INIT_BPS = 100n;
const TAKER_BPS = 10n;
const MAKER_BPS = 5n;
const MAX_LEVERAGE = 100n;
const MAX_POSITION_SIZE = ethers.parseEther('1000000');

async function deployFixture() {
    const [admin, liquidator, challenger, treasury] = await ethers.getSigners();

    const Collateral = await ethers.getContractFactory('MockERC20');
    const collateral = await Collateral.deploy('Collateral', 'COL');
    await collateral.waitForDeployment();

    const Verifier = await ethers.getContractFactory('MockBridgeVerifier');
    const verifier = await Verifier.deploy();
    await verifier.waitForDeployment();
    await verifier.setVerify(true, [admin.address]);

    const Factory = await ethers.getContractFactory('PerpetualSettlement');
    const ps = (await upgrades.deployProxy(
        Factory,
        [
            await collateral.getAddress(),
            admin.address,
            treasury.address,
            10n,
            MAINT_BPS,
            INIT_BPS,
            MAX_LEVERAGE,
        ],
        { kind: 'uups', constructorArgs: [FORWARDER], initializer: 'initialize' },
    )) as any;
    await ps.waitForDeployment();

    await ps.connect(admin).grantRole(await ps.ORACLE_ROLE(), admin.address);
    await ps.connect(admin).grantRole(await ps.LIQUIDATOR_ROLE(), liquidator.address);
    await ps.connect(admin).reinitializeVT16(await verifier.getAddress(), HOUR, 1000n);
    await ps.connect(admin).configureMarket(
        MARKET,
        'XOM-USD',
        await collateral.getAddress(),
        MAINT_BPS,
        INIT_BPS,
        TAKER_BPS,
        MAKER_BPS,
        MAX_LEVERAGE,
        MAX_POSITION_SIZE,
    );

    return { ps, collateral, verifier, admin, liquidator, challenger, treasury };
}

async function domain(ps: any) {
    return {
        name: 'PerpetualSettlement',
        version: '1',
        chainId: (await ethers.provider.getNetwork()).chainId,
        verifyingContract: await ps.getAddress(),
    };
}

async function fundEth(wallet: any) {
    const [deployer] = await ethers.getSigners();
    await deployer.sendTransaction({ to: wallet.address, value: ethers.parseEther('1') });
}

async function nowTs(): Promise<bigint> {
    return BigInt((await ethers.provider.getBlock('latest'))!.timestamp);
}

async function mintApproveDeposit(collateral: any, ps: any, to: any, amount: bigint) {
    await fundEth(to);
    await collateral.mint(to.address, amount);
    await collateral.connect(to).approve(await ps.getAddress(), amount);
    await ps.connect(to).depositMargin(amount);
}

async function openLong(ps: any, trader: any, size: bigint, leverage: bigint, nonce: bigint) {
    const deadline = (await nowTs()) + 3600n;
    const sig = await trader.signTypedData(
        await domain(ps),
        {
            OpenPosition: [
                { name: 'trader', type: 'address' },
                { name: 'market', type: 'bytes32' },
                { name: 'side', type: 'uint8' },
                { name: 'size', type: 'uint256' },
                { name: 'entryPrice', type: 'uint256' },
                { name: 'leverage', type: 'uint256' },
                { name: 'deadline', type: 'uint256' },
                { name: 'nonce', type: 'uint256' },
            ],
        },
        { trader: trader.address, market: MARKET, side: 0, size, entryPrice: ethers.parseEther('1'), leverage, deadline, nonce },
    );
    await ps.connect(trader).openPosition(MARKET, 0, size, ethers.parseEther('1'), leverage, deadline, nonce, sig);
}

async function timeTravel(seconds: number) {
    await ethers.provider.send('evm_increaseTime', [seconds]);
    await ethers.provider.send('evm_mine', []);
}

describe('PerpetualSettlement VT-16 (mock verifier)', function () {
    it('rejects a mark price without a valid committee proof', async function () {
        const { ps, verifier, admin } = await deployFixture();
        await verifier.setVerify(false, []);
        await expect(
            ps.connect(admin).submitMarkPrice(MARKET, ethers.parseEther('1'), 1, '0x00'),
        ).to.be.revertedWithCustomError(ps, 'OracleProofInvalid');
    });

    it('accepts a quorum-signed median and advances the round', async function () {
        const { ps, admin } = await deployFixture();
        await expect(ps.connect(admin).submitMarkPrice(MARKET, ethers.parseEther('1'), 1, '0x00'))
            .to.emit(ps, 'MarkPriceSubmitted')
            .withArgs(MARKET, ethers.parseEther('1'), 1);
        const [price, , round] = await ps.getMarkPrice(MARKET);
        expect(price).to.equal(ethers.parseEther('1'));
        expect(round).to.equal(1);
    });

    it('rejects a stale / replayed oracle round', async function () {
        const { ps, admin } = await deployFixture();
        await ps.connect(admin).submitMarkPrice(MARKET, ethers.parseEther('1'), 1, '0x00');
        await expect(
            ps.connect(admin).submitMarkPrice(MARKET, ethers.parseEther('1'), 1, '0x00'),
        ).to.be.revertedWithCustomError(ps, 'StaleOracleRound');
    });

    it('closes the first-price anchor gap: opening reverts PriceZero until a median exists', async function () {
        const { ps, collateral, admin } = await deployFixture();
        const trader = ethers.Wallet.createRandom().connect(ethers.provider);
        await fundEth(trader);
        await mintApproveDeposit(collateral, ps, trader, ethers.parseEther('10'));

        const deadline = (await nowTs()) + 3600n;
        const sig = await trader.signTypedData(
            await domain(ps),
            {
                OpenPosition: [
                    { name: 'trader', type: 'address' },
                    { name: 'market', type: 'bytes32' },
                    { name: 'side', type: 'uint8' },
                    { name: 'size', type: 'uint256' },
                    { name: 'entryPrice', type: 'uint256' },
                    { name: 'leverage', type: 'uint256' },
                    { name: 'deadline', type: 'uint256' },
                    { name: 'nonce', type: 'uint256' },
                ],
            },
            { trader: trader.address, market: MARKET, side: 0, size: ethers.parseEther('1'), entryPrice: ethers.parseEther('1'), leverage: 10n, deadline, nonce: 1n },
        );
        await expect(
            ps.connect(trader).openPosition(MARKET, 0, ethers.parseEther('1'), ethers.parseEther('1'), 10n, deadline, 1n, sig),
        ).to.be.revertedWithCustomError(ps, 'PriceZero');

        await ps.connect(admin).submitMarkPrice(MARKET, ethers.parseEther('1'), 1, '0x00');
        await expect(
            ps.connect(trader).openPosition(MARKET, 0, ethers.parseEther('1'), ethers.parseEther('1'), 10n, deadline, 1n, sig),
        ).to.emit(ps, 'PositionOpened');
    });

    it('still enforces the deviation breaker across rounds', async function () {
        const { ps, admin } = await deployFixture();
        await ps.connect(admin).submitMarkPrice(MARKET, ethers.parseEther('1'), 1, '0x00');
        await expect(
            ps.connect(admin).submitMarkPrice(MARKET, ethers.parseEther('0.94'), 2, '0x00'),
        ).to.be.revertedWithCustomError(ps, 'PriceDeviationExceedsMax');
    });

    it('reinitializer is one-shot (reinitializer(2))', async function () {
        const { ps, verifier, admin } = await deployFixture();
        await expect(
            ps.connect(admin).reinitializeVT16(await verifier.getAddress(), HOUR, 1000n),
        ).to.be.reverted;
    });

    // ───────────────────────── liquidation challenge ──────────────────────

    /** A trader with one small (full-liquidation) 100x LONG, then mark 0.98. */
    async function liquidatableFixture() {
        const f = await deployFixture();
        const { ps, collateral, admin } = f;
        const trader = ethers.Wallet.createRandom().connect(ethers.provider);

        await ps.connect(admin).submitMarkPrice(MARKET, ethers.parseEther('1'), 1, '0x00');
        await mintApproveDeposit(collateral, ps, trader, ethers.parseEther('0.01'));
        await openLong(ps, trader, ethers.parseEther('0.5'), 100n, 1n);
        const positionId = (await ps.getUserPositions(trader.address))[0];

        await ps.connect(admin).submitMarkPrice(MARKET, ethers.parseEther('0.98'), 2, '0x00');
        return { ...f, trader, positionId };
    }

    async function postBond(f: any, positionId: string) {
        const bond = (ethers.parseEther('0.49') * 1000n) / BPS;
        await f.collateral.mint(f.liquidator.address, bond);
        await f.collateral.connect(f.liquidator).approve(await f.ps.getAddress(), bond);
        await f.ps.connect(f.liquidator).liquidatePosition(positionId);
        return bond;
    }

    it('liquidatePosition is provisional: posts bond, locks account, defers application', async function () {
        const f = await liquidatableFixture();
        const { ps, collateral, liquidator, trader, positionId } = f;
        const bond = await postBond(f, positionId);

        // Position still exists (not applied yet).
        const pos = await ps.getPosition(positionId);
        expect(pos.size).to.equal(ethers.parseEther('0.5'));

        // Account locked.
        await expect(ps.connect(trader).withdrawMargin(1n)).to.be.revertedWithCustomError(ps, 'AccountLiquidationLocked');

        const rec = await ps.provisionalLiquidations(positionId);
        expect(rec.bond).to.equal(bond);
        expect(rec.markRound).to.equal(2);
        expect(rec.liquidator).to.equal(liquidator.address);
    });

    it('cannot double-liquidate a position under a provisional liquidation', async function () {
        const f = await liquidatableFixture();
        const { ps, liquidator, positionId } = f;
        await postBond(f, positionId);
        await expect(ps.connect(liquidator).liquidatePosition(positionId)).to.be.revertedWithCustomError(ps, 'LiquidationPending');
    });

    it('finalizeLiquidation reverts before the window, applies after, and returns the bond', async function () {
        const f = await liquidatableFixture();
        const { ps, collateral, liquidator, trader, positionId } = f;
        const bond = await postBond(f, positionId);

        await expect(ps.finalizeLiquidation(positionId)).to.be.revertedWithCustomError(ps, 'LiquidationNotFinalizable');

        await timeTravel(3601);
        const before = await collateral.balanceOf(liquidator.address);
        await expect(ps.finalizeLiquidation(positionId)).to.emit(ps, 'LiquidationFinalized');
        expect((await ps.getPosition(positionId)).size).to.equal(0);
        // RT-02 (VT-16.1): this fixture liquidates a fully-underwater position
        // (trader equity == 0), so the liquidator receives its bond back and NO
        // reward — the reward is paid only from the trader's remaining
        // collateral, never the insurance backstop.
        expect(await collateral.balanceOf(liquidator.address)).to.equal(before + bond);
        // Unlocked: the revert is now about collateral, not the liquidation lock.
        await expect(ps.connect(trader).withdrawMargin(1n)).to.be.revertedWithCustomError(ps, 'InsufficientCollateral');
    });

    it('RT-01/RT-02 (VT-16.1): insurance fee debited from trader, reward paid only from collateral', async function () {
        const f = await deployFixture();
        const { ps, collateral, liquidator } = f;
        const t = ethers.Wallet.createRandom().connect(ethers.provider);

        // Small fee/reward (10bps) so a liquidatable-but-solvent position still
        // has equity > fee — the fee is debited without a shortfall (RT-01) and
        // the reward is paid from collateral (RT-02), never the insurance fund.
        await ps.connect(f.admin).setLiquidationParams(10n, 10n);

        // Trader deposits 0.02; at mark 0.964 the 100x LONG (size 0.5) has a
        // -0.018 unrealized PnL → equity 0.002 < maintenance 0.0025 (liquidatable)
        // but > fee 0.00049 (solvent).
        await ps.connect(f.admin).submitMarkPrice(MARKET, ethers.parseEther('1'), 1, '0x00');
        await mintApproveDeposit(collateral, ps, t, ethers.parseEther('0.02'));
        await openLong(ps, t, ethers.parseEther('0.5'), 100n, 1n);
        const positionId = (await ps.getUserPositions(t.address))[0];
        await ps.connect(f.admin).submitMarkPrice(MARKET, ethers.parseEther('0.964'), 2, '0x00');

        // Post the bond inline (the shared `postBond` helper hardcodes a 0.49
        // position value; here the value is 0.5 * 0.964 = 0.482).
        const positionValue =
            (ethers.parseEther('0.5') * ethers.parseEther('0.964')) / ethers.parseEther('1');
        const bond = (positionValue * 1000n) / BPS;
        await collateral.mint(liquidator.address, bond);
        await collateral.connect(liquidator).approve(await ps.getAddress(), bond);
        await ps.connect(liquidator).liquidatePosition(positionId);

        await timeTravel(3601);

        const fundBefore = (await ps.getInsuranceFund()).balance;
        const liqBefore = await collateral.balanceOf(liquidator.address);
        await ps.finalizeLiquidation(positionId);

        // fee == reward == 10bps of positionValue (0.482 XOM).
        const fee = (positionValue * 10n) / BPS;
        const reward = (positionValue * 10n) / BPS;

        // RT-01: no shortfall, so the insurance fund rises by exactly the debited
        // fee (real tokens) and the trader's collateral is debited by it.
        expect((await ps.getInsuranceFund()).balance).to.equal(fundBefore + fee);

        // RT-02: the trader has equity, so the reward is paid from collateral —
        // the liquidator receives bond + reward, and the fund is untouched by it.
        expect(await collateral.balanceOf(liquidator.address)).to.equal(liqBefore + bond + reward);
        expect((await ps.getInsuranceFund()).balance).to.equal(fundBefore + fee);
    });

    it('challengeLiquidation reverses + slashes the bond on an outlier mark price', async function () {
        const f = await liquidatableFixture();
        const { ps, collateral, challenger, positionId } = f;
        const bond = await postBond(f, positionId);

        const before = await collateral.balanceOf(challenger.address);
        await expect(ps.connect(challenger).challengeLiquidation(positionId, ethers.parseEther('0.90'), 2, '0x00'))
            .to.emit(ps, 'LiquidationChallenged')
            .withArgs(positionId, challenger.address, bond);
        expect(await collateral.balanceOf(challenger.address)).to.equal(before + bond);

        // Position restored.
        expect((await ps.getPosition(positionId)).size).to.equal(ethers.parseEther('0.5'));

        await timeTravel(3601);
        await expect(ps.finalizeLiquidation(positionId)).to.be.revertedWithCustomError(ps, 'LiquidationNotFound');
    });

    it('challengeLiquidation rejects a fair liquidation (no slashing)', async function () {
        const f = await liquidatableFixture();
        const { ps, challenger, positionId } = f;
        await postBond(f, positionId);
        await expect(
            ps.connect(challenger).challengeLiquidation(positionId, ethers.parseEther('0.985'), 2, '0x00'),
        ).to.be.revertedWithCustomError(ps, 'ChallengeRejected');
    });

    it('challengeLiquidation requires the SAME oracle round', async function () {
        const f = await liquidatableFixture();
        const { ps, challenger, positionId } = f;
        await postBond(f, positionId);
        await expect(
            ps.connect(challenger).challengeLiquidation(positionId, ethers.parseEther('0.90'), 3, '0x00'),
        ).to.be.revertedWithCustomError(ps, 'RoundMismatch');
    });

    it('challengeLiquidation reverts after the window elapses', async function () {
        const f = await liquidatableFixture();
        const { ps, challenger, positionId } = f;
        await postBond(f, positionId);
        await timeTravel(3601);
        await expect(
            ps.connect(challenger).challengeLiquidation(positionId, ethers.parseEther('0.90'), 2, '0x00'),
        ).to.be.revertedWithCustomError(ps, 'ChallengeWindowElapsed');
    });

    it('trader cannot close or add margin while under provisional liquidation', async function () {
        const f = await liquidatableFixture();
        const { ps, trader, positionId } = f;
        await postBond(f, positionId);
        const d = await domain(ps);
        const deadline = (await nowTs()) + 3600n;

        const closeSig = await trader.signTypedData(
            d,
            {
                ClosePosition: [
                    { name: 'trader', type: 'address' },
                    { name: 'positionId', type: 'bytes32' },
                    { name: 'exitPrice', type: 'uint256' },
                    { name: 'deadline', type: 'uint256' },
                    { name: 'nonce', type: 'uint256' },
                ],
            },
            { trader: trader.address, positionId, exitPrice: ethers.parseEther('0.98'), deadline, nonce: 2n },
        );
        await expect(
            ps.connect(trader).closePosition(positionId, ethers.parseEther('0.98'), deadline, 2n, closeSig),
        ).to.be.revertedWithCustomError(ps, 'AccountLiquidationLocked');

        const addSig = await trader.signTypedData(
            d,
            {
                AddMargin: [
                    { name: 'trader', type: 'address' },
                    { name: 'positionId', type: 'bytes32' },
                    { name: 'amount', type: 'uint256' },
                    { name: 'deadline', type: 'uint256' },
                    { name: 'nonce', type: 'uint256' },
                ],
            },
            { trader: trader.address, positionId, amount: ethers.parseEther('0.001'), deadline, nonce: 3n },
        );
        await expect(
            ps.connect(trader).addMarginToPosition(positionId, ethers.parseEther('0.001'), deadline, 3n, addSig),
        ).to.be.revertedWithCustomError(ps, 'AccountLiquidationLocked');
    });
});

describe('PerpetualSettlement VT-16 (real committee verifier, end-to-end)', function () {
    it('submits and verifies a real 4-of-5 committee-signed median', async function () {
        const [admin] = await ethers.getSigners();

        const MockBootstrap = await ethers.getContractFactory('MockBootstrapForAttestation');
        const mockBootstrap = await MockBootstrap.deploy();
        await mockBootstrap.waitForDeployment();
        const MockOmniCore = await ethers.getContractFactory('MockOmniCoreForAttestation');
        const mockOmniCore = await MockOmniCore.deploy();
        await mockOmniCore.waitForDeployment();
        const MockOmniRegistration = await ethers.getContractFactory('MockOmniRegistrationForAttestation');
        const mockOmniRegistration = await MockOmniRegistration.deploy();
        await mockOmniRegistration.waitForDeployment();

        const Verifier = await ethers.getContractFactory('RandomCommitteeVerifierV2');
        const verifier = await Verifier.deploy(
            admin.address,
            await mockBootstrap.getAddress(),
            await mockOmniCore.getAddress(),
            await mockOmniRegistration.getAddress(),
            5,
            4,
            3,
            ethers.parseEther('1000000'),
        );
        await verifier.waitForDeployment();

        const pool = [1, 2, 3, 4, 5].map(() => ethers.Wallet.createRandom().connect(ethers.provider));
        for (const v of pool) {
            await mockBootstrap.setNodeActive(v.address, true, 0);
            await mockOmniRegistration.setKycTier(v.address, 3);
            await mockOmniCore.setStake(v.address, ethers.parseEther('1000000'), true);
        }
        await verifier.refreshEligibleSet();

        const Collateral = await ethers.getContractFactory('MockERC20');
        const collateral = await Collateral.deploy('XOM', 'XOM');
        await collateral.waitForDeployment();
        const Factory = await ethers.getContractFactory('PerpetualSettlement');
        const ps = (await upgrades.deployProxy(
            Factory,
            [await collateral.getAddress(), admin.address, admin.address, 10n, MAINT_BPS, INIT_BPS, MAX_LEVERAGE],
            { kind: 'uups', constructorArgs: [FORWARDER], initializer: 'initialize' },
        )) as any;
        await ps.waitForDeployment();
        await ps.connect(admin).grantRole(await ps.ORACLE_ROLE(), admin.address);
        await ps.connect(admin).reinitializeVT16(await verifier.getAddress(), HOUR, 1000n);
        await ps.connect(admin).configureMarket(
            MARKET,
            'XOM-USD',
            await collateral.getAddress(),
            MAINT_BPS,
            INIT_BPS,
            TAKER_BPS,
            MAKER_BPS,
            MAX_LEVERAGE,
            MAX_POSITION_SIZE,
        );

        const price = ethers.parseEther('1');
        const round = 1n;
        const digest = keccak256(
            ethers.AbiCoder.defaultAbiCoder().encode(
                ['bytes32', 'address', 'bytes32', 'uint256', 'uint256'],
                [await ps.ORACLE_PRICE_DOMAIN(), await ps.getAddress(), MARKET, price, round],
            ),
        );

        await verifier.requestCommitteeSeed(digest);
        const [pinnedBn] = await verifier.pinnedCommitBlock(digest);
        while ((await ethers.provider.getBlockNumber()) <= Number(pinnedBn)) {
            await ethers.provider.send('evm_mine', []);
        }
        const pinnedBlock = Number(pinnedBn);
        const committee: string[] = await verifier.committeeFor(digest, pinnedBlock);
        expect(committee.length).to.equal(5);

        const chainId = (await ethers.provider.getNetwork()).chainId;
        const bound = keccak256(
            ethers.AbiCoder.defaultAbiCoder().encode(
                ['address', 'uint256', 'bytes32', 'uint256'],
                [await verifier.getAddress(), chainId, digest, pinnedBlock],
            ),
        );
        const signEth = (w: any, h: string): string => {
            const ethSigned = keccak256(concat([toUtf8Bytes(ETH_SIGNED_PREFIX), getBytes(h)]));
            return new SigningKey(w.privateKey).sign(ethSigned).serialized;
        };
        const signers = pool
            .filter((w) => committee.map((a) => a.toLowerCase()).includes(w.address.toLowerCase()))
            .sort((a, b) => (a.address.toLowerCase() < b.address.toLowerCase() ? -1 : 1));
        const proof = concat([ethers.toBeHex(pinnedBlock, 32), ...signers.slice(0, 4).map((w) => signEth(w, bound))]);

        await expect(ps.connect(admin).submitMarkPrice(MARKET, price, round, proof))
            .to.emit(ps, 'MarkPriceSubmitted')
            .withArgs(MARKET, price, round);
        expect((await ps.getMarkPrice(MARKET))[0]).to.equal(price);
    });
});
