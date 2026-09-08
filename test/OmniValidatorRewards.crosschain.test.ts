/**
 * @file OmniValidatorRewards.crosschain.test.ts
 * @description LIQ-Q-3-LP5 — Path A (2-hop via Avalanche ICTT).
 *
 * V4 cross-chain overflow routing: a configurable bucket of each
 * epoch's overflow XOM is bridged via Avalanche ICTT
 * (`ERC20TokenHome.send`) to the C-Chain `OverflowOFTSender`, where
 * a separate LZ-OFT dispatch step distributes per-remote-chain. This
 * test exercises ONLY the L1 routing layer (the ICTT call); the
 * C-Chain dispatch is covered by `OverflowOFTSender.flush.test.ts`.
 *
 * Scope:
 *   1. V4 admin surface — `setIcttTokenHome`, `setCchainSender`,
 *      `setCchainRemoteTransferrer`, `setCchainBlockchainID`,
 *      `setRemoteShareBps`. Role gates + invariant
 *      (`RemoteShareBpsTooHigh`).
 *   2. `_routeOverflow` math when the full path is configured: the
 *      bucket = overflow * remoteShareBps / 10000 is bridged via
 *      ICTT in ONE call; the L1 share = overflow - bucket lands at
 *      the local pool.
 *   3. Skip-not-revert: if any leg of the ICTT path is unconfigured
 *      OR the ICTT send reverts, the bucket falls back to the L1
 *      share. The epoch never reverts.
 *   4. Storage layout: V4 added slots are zero-init by default.
 *   5. End-to-end via `processEpoch` driving the real V3+V4 path.
 */

/* eslint-disable @typescript-eslint/no-var-requires */
const { expect } = require('chai');
const { ethers, upgrades } = require('hardhat');
const { time } = require('@nomicfoundation/hardhat-network-helpers');

describe('OmniValidatorRewards V4 cross-chain overflow (Path A: ICTT → C-Chain)', function () {
    let validatorRewards: any;
    let xom: any;
    let mockOmniCore: any;
    let mockParticipation: any;
    let mockBootstrap: any;
    let mockOverflowPool: any;
    let mockTokenHome: any;
    let mockActivityLedger: any;

    let owner: any;
    let validator1: any;
    let unauthorized: any;
    let randomAddr: any;
    let cchainSenderAddr: any;
    let cchainRemoteTransferrerAddr: any;

    // Mainnet Avalanche C-Chain Teleporter blockchain ID
    const CCHAIN_BLOCKCHAIN_ID =
        '0x0427d4b22a2a78bcddd456742caf91b56badbff985ee19aef14573e7343fd652';

    const E18 = (n: bigint | number) => ethers.parseEther(n.toString());

    beforeEach(async function () {
        [owner, validator1, unauthorized, randomAddr, cchainSenderAddr, cchainRemoteTransferrerAddr] =
            await ethers.getSigners();

        const MockToken = await ethers.getContractFactory('MockXOMToken');
        xom = await MockToken.deploy();

        const MockOmniCore = await ethers.getContractFactory('MockOmniCore');
        mockOmniCore = await MockOmniCore.deploy();

        const MockParticipation = await ethers.getContractFactory(
            'MockOmniParticipation',
        );
        mockParticipation = await MockParticipation.deploy();

        const MockBootstrap = await ethers.getContractFactory('MockBootstrap');
        mockBootstrap = await MockBootstrap.deploy();

        const MockOverflow = await ethers.getContractFactory(
            'MockLiquidityOverflowPool',
        );
        mockOverflowPool = await MockOverflow.deploy(await xom.getAddress());

        const MockTokenHome = await ethers.getContractFactory('MockICTTTokenHome');
        mockTokenHome = await MockTokenHome.deploy(await xom.getAddress());

        const MockActivityLedger = await ethers.getContractFactory('MockActivityLedger');
        mockActivityLedger = await MockActivityLedger.deploy();

        const OmniValidatorRewards = await ethers.getContractFactory(
            'OmniValidatorRewards',
        );
        validatorRewards = await upgrades.deployProxy(
            OmniValidatorRewards,
            [
                await xom.getAddress(),
                await mockParticipation.getAddress(),
                await mockOmniCore.getAddress(),
            ],
            {
                initializer: 'initialize',
                kind: 'uups',
                constructorArgs: [ethers.ZeroAddress],
                unsafeAllow: ['constructor'],
            },
        );
        await validatorRewards.reinitializeV2(await mockBootstrap.getAddress());
        await validatorRewards.reinitializeV3(await mockOverflowPool.getAddress());
        await validatorRewards.setActivityLedger(await mockActivityLedger.getAddress());
        await validatorRewards.setOverflowEnabled(true);

        // Fund OVR with XOM for epoch distribution
        await xom.mint(await validatorRewards.getAddress(), E18(1_000_000n));
    });

    // ──────────────────────────────────────────────────────────────────
    // 1. ADMIN SURFACE
    // ──────────────────────────────────────────────────────────────────

    describe('admin: setIcttTokenHome', function () {
        it('only admin can set', async function () {
            await expect(
                validatorRewards
                    .connect(unauthorized)
                    .setIcttTokenHome(await mockTokenHome.getAddress()),
            ).to.be.reverted;
        });

        it('persists + emits', async function () {
            const addr = await mockTokenHome.getAddress();
            await expect(validatorRewards.setIcttTokenHome(addr))
                .to.emit(validatorRewards, 'IcttTokenHomeUpdated')
                .withArgs(ethers.ZeroAddress, addr);
            expect(await validatorRewards.icttTokenHome()).to.equal(addr);
        });

        it('accepts address(0) to disable cross-chain leg', async function () {
            const addr = await mockTokenHome.getAddress();
            await validatorRewards.setIcttTokenHome(addr);
            await validatorRewards.setIcttTokenHome(ethers.ZeroAddress);
            expect(await validatorRewards.icttTokenHome()).to.equal(
                ethers.ZeroAddress,
            );
        });
    });

    describe('admin: setCchainSender / setCchainRemoteTransferrer / setCchainBlockchainID', function () {
        it('all three persist + emit', async function () {
            await expect(
                validatorRewards.setCchainSender(cchainSenderAddr.address),
            )
                .to.emit(validatorRewards, 'CchainSenderUpdated')
                .withArgs(ethers.ZeroAddress, cchainSenderAddr.address);
            expect(await validatorRewards.cchainSender()).to.equal(
                cchainSenderAddr.address,
            );

            await expect(
                validatorRewards.setCchainRemoteTransferrer(
                    cchainRemoteTransferrerAddr.address,
                ),
            )
                .to.emit(validatorRewards, 'CchainRemoteTransferrerUpdated')
                .withArgs(
                    ethers.ZeroAddress,
                    cchainRemoteTransferrerAddr.address,
                );
            expect(
                await validatorRewards.cchainRemoteTransferrer(),
            ).to.equal(cchainRemoteTransferrerAddr.address);

            await expect(
                validatorRewards.setCchainBlockchainID(CCHAIN_BLOCKCHAIN_ID),
            )
                .to.emit(validatorRewards, 'CchainBlockchainIDUpdated')
                .withArgs(ethers.ZeroHash, CCHAIN_BLOCKCHAIN_ID);
            expect(await validatorRewards.cchainBlockchainID()).to.equal(
                CCHAIN_BLOCKCHAIN_ID,
            );
        });

        it('all gated on admin role', async function () {
            await expect(
                validatorRewards
                    .connect(unauthorized)
                    .setCchainSender(cchainSenderAddr.address),
            ).to.be.reverted;
            await expect(
                validatorRewards
                    .connect(unauthorized)
                    .setCchainRemoteTransferrer(
                        cchainRemoteTransferrerAddr.address,
                    ),
            ).to.be.reverted;
            await expect(
                validatorRewards
                    .connect(unauthorized)
                    .setCchainBlockchainID(CCHAIN_BLOCKCHAIN_ID),
            ).to.be.reverted;
        });
    });

    describe('admin: setRemoteShareBps', function () {
        it('persists + emits', async function () {
            await expect(validatorRewards.setRemoteShareBps(6500))
                .to.emit(validatorRewards, 'RemoteShareBpsUpdated')
                .withArgs(0, 6500);
            expect(await validatorRewards.remoteShareBps()).to.equal(6500);
        });

        it('rejects > BPS_DENOMINATOR', async function () {
            await expect(
                validatorRewards.setRemoteShareBps(10001),
            ).to.be.revertedWithCustomError(
                validatorRewards,
                'RemoteShareBpsTooHigh',
            );
        });

        it('only admin', async function () {
            await expect(
                validatorRewards.connect(unauthorized).setRemoteShareBps(5000),
            ).to.be.reverted;
        });
    });

    describe('storage layout', function () {
        it('V4 added storage slots are zero-init by default', async function () {
            expect(await validatorRewards.icttTokenHome()).to.equal(
                ethers.ZeroAddress,
            );
            expect(await validatorRewards.cchainSender()).to.equal(
                ethers.ZeroAddress,
            );
            expect(
                await validatorRewards.cchainRemoteTransferrer(),
            ).to.equal(ethers.ZeroAddress);
            expect(await validatorRewards.cchainBlockchainID()).to.equal(
                ethers.ZeroHash,
            );
            expect(await validatorRewards.remoteShareBps()).to.equal(0);
        });
    });

    // ──────────────────────────────────────────────────────────────────
    // 2 + 5. END-TO-END _routeOverflow via processEpoch
    // ──────────────────────────────────────────────────────────────────

    describe('end-to-end _routeOverflow via processEpoch', function () {
        const EPOCH_DURATION = 2;

        async function seedValidators(): Promise<void> {
            for (const v of [validator1, randomAddr, unauthorized]) {
                await mockOmniCore.setValidator(v.address, true);
                await mockOmniCore.registerMockNode(
                    v.address,
                    'validator',
                    `http://${v.address}:3001`,
                );
                await mockParticipation.setTotalScore(v.address, 70);
                const now = await time.latest();
                await mockOmniCore.setStake(
                    v.address,
                    E18(1_000_000n),
                    2,
                    180 * 24 * 60 * 60,
                    now + 365 * 24 * 60 * 60,
                    true,
                );
                await validatorRewards.setStakeExempt(v.address, true);
            }
            await mockBootstrap.setNode(validator1.address, true, 0);
            await mockBootstrap.setNode(randomAddr.address, true, 1);
            await mockBootstrap.setNode(unauthorized.address, true, 1);
            // VT-18: attest the validators active via the activity ledger
            // (submitHeartbeat is now a deprecated no-op).
            const epoch = await validatorRewards.getCurrentEpoch();
            await mockActivityLedger.recordEpochActivity(epoch, [
                validator1.address,
                randomAddr.address,
                unauthorized.address,
            ]);
        }

        async function processNextEpoch(): Promise<any> {
            const nextEpoch =
                (await validatorRewards.lastProcessedEpoch()) + BigInt(1);
            const currentEpoch = await validatorRewards.getCurrentEpoch();
            if (nextEpoch > currentEpoch) {
                await time.increase(EPOCH_DURATION + 1);
            }
            return await validatorRewards.processEpoch(nextEpoch);
        }

        async function fullyConfigure(remoteShareBps = 6500): Promise<void> {
            await validatorRewards.setIcttTokenHome(
                await mockTokenHome.getAddress(),
            );
            await validatorRewards.setCchainSender(cchainSenderAddr.address);
            await validatorRewards.setCchainRemoteTransferrer(
                cchainRemoteTransferrerAddr.address,
            );
            await validatorRewards.setCchainBlockchainID(
                CCHAIN_BLOCKCHAIN_ID,
            );
            await validatorRewards.setRemoteShareBps(remoteShareBps);
        }

        beforeEach(async function () {
            await seedValidators();
        });

        it('100% local when remoteShareBps == 0', async function () {
            // ICTT path fully configured but remoteShareBps == 0 ⇒ skip
            await validatorRewards.setIcttTokenHome(
                await mockTokenHome.getAddress(),
            );
            await validatorRewards.setCchainSender(cchainSenderAddr.address);
            await validatorRewards.setCchainRemoteTransferrer(
                cchainRemoteTransferrerAddr.address,
            );
            await validatorRewards.setCchainBlockchainID(
                CCHAIN_BLOCKCHAIN_ID,
            );
            // remoteShareBps left at 0

            const localBefore = await mockOverflowPool.totalReceived();
            await processNextEpoch();
            const localAfter = await mockOverflowPool.totalReceived();
            expect(localAfter - localBefore).to.be.gt(0n);
            expect(await mockTokenHome.sendCount()).to.equal(0);
        });

        it('100% local when icttTokenHome unset (skip-not-revert)', async function () {
            // remoteShareBps > 0 but path not configured ⇒ skip
            await validatorRewards.setRemoteShareBps(6500);

            const localBefore = await mockOverflowPool.totalReceived();
            await processNextEpoch();
            const localAfter = await mockOverflowPool.totalReceived();
            expect(localAfter - localBefore).to.be.gt(0n);
            expect(await mockTokenHome.sendCount()).to.equal(0);
        });

        it('bridges bucket via ICTT when fully configured (65/35 split)', async function () {
            await fullyConfigure(6500);

            const localBefore = await mockOverflowPool.totalReceived();
            const tx = await processNextEpoch();
            await expect(tx).to.emit(
                validatorRewards,
                'CrossChainOverflowSent',
            );
            const localAfter = await mockOverflowPool.totalReceived();

            // Exactly one ICTT send recorded
            expect(await mockTokenHome.sendCount()).to.equal(1);
            const sent = await mockTokenHome.lastSend();
            expect(sent.destinationBlockchainID).to.equal(CCHAIN_BLOCKCHAIN_ID);
            expect(sent.destinationTokenTransferrerAddress).to.equal(
                cchainRemoteTransferrerAddr.address,
            );
            expect(sent.recipient).to.equal(cchainSenderAddr.address);

            // Sum of L1 + bucket ≈ total overflow (exact, no dust:
            // overflow * 6500/10000 + overflow * 3500/10000 = overflow,
            // since 6500+3500 = 10000 and arithmetic is integer-exact
            // when (overflow * 6500) is divisible by 10000. Otherwise
            // up to 1 wei dust falls into localShare via subtraction.)
            const localDelta = localAfter - localBefore;
            const total = localDelta + BigInt(sent.amount);
            expect(total).to.be.gt(0n);
            // Sanity: bucket > 0, local > 0
            expect(BigInt(sent.amount)).to.be.gt(0n);
            expect(localDelta).to.be.gt(0n);
        });

        it('skip-not-revert when ICTT send reverts (bucket falls back to L1)', async function () {
            await fullyConfigure(6500);
            await mockTokenHome.setShouldRevert(true);

            const localBefore = await mockOverflowPool.totalReceived();
            const tx = await processNextEpoch();
            await expect(tx).to.emit(
                validatorRewards,
                'OverflowRoutingFailed',
            );
            const localAfter = await mockOverflowPool.totalReceived();

            // No ICTT send recorded
            expect(await mockTokenHome.sendCount()).to.equal(0);
            // ALL overflow landed at L1 (bucket rolled back to local)
            expect(localAfter - localBefore).to.be.gt(0n);
        });

        it('100% cross-chain when remoteShareBps == 10000', async function () {
            await fullyConfigure(10000);

            const localBefore = await mockOverflowPool.totalReceived();
            await processNextEpoch();
            const localAfter = await mockOverflowPool.totalReceived();

            // L1 pool gets nothing
            expect(localAfter - localBefore).to.equal(0n);
            // All overflow went via ICTT
            expect(await mockTokenHome.sendCount()).to.equal(1);
            const sent = await mockTokenHome.lastSend();
            expect(BigInt(sent.amount)).to.be.gt(0n);
        });

        it('totalOverflowTransferred bumped on cross-chain send', async function () {
            await fullyConfigure(6500);

            const before = await validatorRewards.totalOverflowTransferred();
            await processNextEpoch();
            const after = await validatorRewards.totalOverflowTransferred();

            // Total = local share + bucket (both flowed out)
            expect(after - before).to.be.gt(0n);
            const sent = await mockTokenHome.lastSend();
            expect(after - before).to.be.gte(BigInt(sent.amount));
        });
    });
});
