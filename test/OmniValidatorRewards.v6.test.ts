/**
 * @file OmniValidatorRewards.v6.test.ts
 * @description V6 — LP-5 hop-1 flood fix (Option C): batch the
 *              cross-chain overflow bucket.
 *
 * Scope:
 *   1. `reinitializeV5` — wires `bootstrapContract` (node-type caps
 *      restoration) + folds the batch threshold into the upgrade
 *      payload. Access control, validation, double-init.
 *   2. Byte-identity: at the legacy 0.01 XOM threshold, V6 behaves
 *      exactly like V4 — ONE ICTT send per epoch, same amounts, same
 *      counters (the live-config equivalence the upgrade promises).
 *   3. Batching: with a raised threshold the 65% bucket accumulates in
 *      `pendingCrossChainOverflow` and ONE ICTT message is sent when the
 *      accumulator crosses the threshold; the L1-pool 35% leg flows
 *      EVERY epoch, unchanged.
 *   4. Skip-not-revert preserved: an unconfigured leg rolls each epoch's
 *      bucket to the L1 share without accumulating; a failed batched
 *      send rolls the whole pending bucket to the L1 share (nothing
 *      parks in OVR).
 *   5. Node-type caps restoration: with `bootstrapContract` wired, active
 *      gateway nodes (nodeType 0) resolve to `gatewayRewardCap` instead
 *      of every validator falling back to the 1-wei service cap.
 *   6. Solvency: the pending bucket is excluded from the distribution
 *      solvency picture — it is never double-spent as validator rewards,
 *      and `totalDistributed` bumps at commit, not at accumulation.
 */

/* eslint-disable @typescript-eslint/no-var-requires */
const { expect } = require('chai');
const { ethers, upgrades } = require('hardhat');
const { time } = require('@nomicfoundation/hardhat-network-helpers');

describe('OmniValidatorRewards V6 — batched hop-1 cross-chain overflow (Option C)', function () {
    let validatorRewards: any;
    let xom: any;
    let mockOmniCore: any;
    let mockParticipation: any;
    let mockBootstrap: any;
    let mockOverflowPool: any;
    let mockTokenHome: any;
    let mockActivityLedger: any;

    let owner: any;
    let validators: any[];
    let unauthorized: any;
    let cchainSenderAddr: any;
    let cchainRemoteTransferrerAddr: any;

    const EPOCH_DURATION = 2;
    const E18 = (n: bigint | number) => ethers.parseEther(n.toString());

    // Mainnet-mirroring per-node-type caps (set via reinitializeV3 caps +
    // explicit setters, as on live).
    const GATEWAY_CAP = ethers.parseEther('0.225');
    const SERVICE_CAP = 1n; // 1 wei ≈ 0 (live value)

    const CCHAIN_BLOCKCHAIN_ID =
        '0x0427d4b22a2a78bcddd456742caf91b56badbff985ee19aef14573e7343fd652';

    // 5 equal-weight gateway validators (all nodeType 0, all capped at
    // GATEWAY_CAP): epochReward 15.602 − 5 × 0.225 = 14.477 overflow.
    // bucket = 14.477 × 6500/10000 = 9.41005; local = 14.477 × 3500/10000
    // = 5.06695. Exact (integer-division clean at these magnitudes).
    const OVERFLOW_PER_EPOCH = ethers.parseEther('14.477');
    const BUCKET_PER_EPOCH = ethers.parseEther('9.41005');
    const LOCAL_PER_EPOCH = ethers.parseEther('5.06695');
    const VALIDATOR_TOTAL_PER_EPOCH = ethers.parseEther('1.125');

    async function seedValidators(allGateway = true): Promise<void> {
        for (const v of validators) {
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
            // All five are gateways (nodeType 0), mirroring the live set.
            await mockBootstrap.setNode(v.address, true, allGateway ? 0 : 1);
        }
        // Attest all validators at the current epoch (VT-18 activity gate).
        const epoch = await validatorRewards.getCurrentEpoch();
        await mockActivityLedger.recordEpochActivity(
            epoch,
            validators.map((v) => v.address),
        );
    }

    async function configureCrossChain(): Promise<void> {
        await validatorRewards.setIcttTokenHome(
            await mockTokenHome.getAddress(),
        );
        await validatorRewards.setCchainSender(cchainSenderAddr.address);
        await validatorRewards.setCchainRemoteTransferrer(
            cchainRemoteTransferrerAddr.address,
        );
        await validatorRewards.setCchainBlockchainID(CCHAIN_BLOCKCHAIN_ID);
        await validatorRewards.setRemoteShareBps(6500);
    }

    // Minted into OVR before each test.
    async function processNextEpoch(): Promise<any> {
        const nextEpoch =
            (await validatorRewards.lastProcessedEpoch()) + BigInt(1);
        const currentEpoch = await validatorRewards.getCurrentEpoch();
        if (nextEpoch > currentEpoch) {
            await time.increase(EPOCH_DURATION + 1);
        }
        return await validatorRewards.processEpoch(nextEpoch);
    }

    async function processNEpochs(n: number): Promise<void> {
        for (let i = 0; i < n; i++) {
            await processNextEpoch();
        }
    }

    beforeEach(async function () {
        const signers = await ethers.getSigners();
        owner = signers[0];
        validators = [signers[1], signers[2], signers[3], signers[4], signers[5]];
        unauthorized = signers[6];
        cchainSenderAddr = signers[7];
        cchainRemoteTransferrerAddr = signers[8];

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

        // V3 baseline: overflow pool + per-node-type caps (as live).
        await validatorRewards.reinitializeV3(await mockOverflowPool.getAddress());
        await validatorRewards.setGatewayRewardCap(GATEWAY_CAP);
        await validatorRewards.setServiceNodeRewardCap(SERVICE_CAP);
        // VT-18: wire the committee-attestation activity ledger.
        await validatorRewards.setActivityLedger(
            await mockActivityLedger.getAddress(),
        );
        await validatorRewards.setOverflowEnabled(true);

        await seedValidators();

        // Fund OVR with XOM for epoch distribution.
        await xom.mint(await validatorRewards.getAddress(), E18(1_000_000n));
    });

    // ──────────────────────────────────────────────────────────────────
    // 1. reinitializeV5
    // ──────────────────────────────────────────────────────────────────

    describe('reinitializeV5', function () {
        it('wires bootstrapContract + folds the batch threshold into the payload', async function () {
            // Pre-V5 live-equivalent: bootstrapContract unset → every
            // validator resolves to the 1-wei service cap.
            expect(await validatorRewards.bootstrapContract()).to.equal(
                ethers.ZeroAddress,
            );
            expect(await validatorRewards.getRewardCap(validators[0].address)).to.equal(SERVICE_CAP);

            const bootstrapAddr = await mockBootstrap.getAddress();
            const threshold = E18(400_000n);
            await expect(
                validatorRewards.reinitializeV5(bootstrapAddr, threshold),
            )
                .to.emit(validatorRewards, 'MinOverflowTransferUpdated')
                .withArgs(ethers.parseEther('0.01'), threshold);

            expect(await validatorRewards.bootstrapContract()).to.equal(
                bootstrapAddr,
            );
            expect(await validatorRewards.minOverflowTransfer()).to.equal(
                threshold,
            );
            // Caps now resolve: gateways → gatewayRewardCap.
            expect(
                await validatorRewards.getRewardCap(validators[0].address),
            ).to.equal(GATEWAY_CAP);
            // Pending bucket starts empty.
            expect(await validatorRewards.pendingCrossChainOverflow()).to.equal(0n);
        });

        it('reverts for a non-admin caller', async function () {
            await expect(
                validatorRewards
                    .connect(unauthorized)
                    .reinitializeV5(
                        await mockBootstrap.getAddress(),
                        E18(100n),
                    ),
            ).to.be.reverted;
        });

        it('reverts on a zero bootstrap address', async function () {
            await expect(
                validatorRewards.reinitializeV5(ethers.ZeroAddress, E18(100n)),
            ).to.be.revertedWithCustomError(validatorRewards, 'ZeroAddress');
        });

        it('reverts on an EOA bootstrap (no code)', async function () {
            await expect(
                validatorRewards.reinitializeV5(unauthorized.address, E18(100n)),
            )
                .to.be.revertedWithCustomError(validatorRewards, 'NotAContract')
                .withArgs(unauthorized.address);
        });

        it('reverts on a zero threshold', async function () {
            await expect(
                validatorRewards.reinitializeV5(
                    await mockBootstrap.getAddress(),
                    0,
                ),
            ).to.be.revertedWithCustomError(validatorRewards, 'ZeroAmount');
        });

        it('blocks a second call (reinitializer guard)', async function () {
            await validatorRewards.reinitializeV5(
                await mockBootstrap.getAddress(),
                E18(100n),
            );
            await expect(
                validatorRewards.reinitializeV5(
                    await mockBootstrap.getAddress(),
                    E18(200n),
                ),
            ).to.be.reverted;
        });
    });

    // ──────────────────────────────────────────────────────────────────
    // 2. Byte-identity at the legacy 0.01 threshold
    // ──────────────────────────────────────────────────────────────────

    describe('byte-identity at the legacy 0.01 XOM threshold', function () {
        beforeEach(async function () {
            await configureCrossChain();
            await validatorRewards.reinitializeV5(
                await mockBootstrap.getAddress(),
                ethers.parseEther('0.01'),
            );
        });

        it('sends ONE ICTT message per epoch with identical amounts and counters', async function () {
            const tdBefore = await validatorRewards.totalDistributed();
            const totBefore = await validatorRewards.totalOverflowTransferred();
            const localBefore = await mockOverflowPool.totalReceived();

            const tx = await processNextEpoch();

            await expect(tx).to.emit(
                validatorRewards,
                'CrossChainOverflowSent',
            );
            expect(await mockTokenHome.sendCount()).to.equal(1);

            const sent = await mockTokenHome.lastSend();
            expect(BigInt(sent.amount)).to.equal(BUCKET_PER_EPOCH);
            expect(sent.destinationBlockchainID).to.equal(CCHAIN_BLOCKCHAIN_ID);
            expect(sent.recipient).to.equal(cchainSenderAddr.address);

            // Local 35% leg flowed to the L1 pool.
            expect(
                (await mockOverflowPool.totalReceived()) - localBefore,
            ).to.equal(LOCAL_PER_EPOCH);

            // The whole epoch's overflow left the contract this epoch:
            // totalOverflowTransferred += bucket + local = overflow.
            expect(
                (await validatorRewards.totalOverflowTransferred()) - totBefore,
            ).to.equal(OVERFLOW_PER_EPOCH);

            // totalDistributed += validator rewards + full overflow = the
            // full epoch reward, exactly as V4 did.
            expect(
                (await validatorRewards.totalDistributed()) - tdBefore,
            ).to.equal(VALIDATOR_TOTAL_PER_EPOCH + OVERFLOW_PER_EPOCH);

            // No pending residue after a per-epoch send.
            expect(await validatorRewards.pendingCrossChainOverflow()).to.equal(0n);
        });

        it('stays per-epoch across several epochs (no accumulation drift)', async function () {
            await processNEpochs(5);
            expect(await mockTokenHome.sendCount()).to.equal(5);
            expect(await validatorRewards.pendingCrossChainOverflow()).to.equal(0n);

            // Local pool received 5 × local share.
            expect(await mockOverflowPool.totalReceived()).to.equal(
                ethers.parseEther('5.06695') * 5n,
            );
        });
    });

    // ──────────────────────────────────────────────────────────────────
    // 3. Batching (the V6 change)
    // ──────────────────────────────────────────────────────────────────

    describe('batching: accumulate then send ONE message ≥ threshold', function () {
        const THRESHOLD = E18(100n);

        beforeEach(async function () {
            await configureCrossChain();
            await validatorRewards.reinitializeV5(
                await mockBootstrap.getAddress(),
                THRESHOLD,
            );
        });

        it('accumulates the bucket below the threshold while the L1 leg flows every epoch', async function () {
            const localBefore = await mockOverflowPool.totalReceived();

            // 10 epochs × 9.41005 = 94.1005 < 100 → no send yet.
            await processNEpochs(10);

            expect(await mockTokenHome.sendCount()).to.equal(0);
            expect(await validatorRewards.pendingCrossChainOverflow()).to.equal(
                BUCKET_PER_EPOCH * 10n,
            );

            // The L1-pool leg did NOT skip a beat: 10 × local share.
            expect(
                (await mockOverflowPool.totalReceived()) - localBefore,
            ).to.equal(LOCAL_PER_EPOCH * 10n);

            // totalOverflowTransferred tracks only the XOM that actually
            // left the contract (local pushes). The pending bucket is
            // still held, not counted as transferred.
            expect(
                await validatorRewards.totalOverflowTransferred(),
            ).to.equal(LOCAL_PER_EPOCH * 10n);

            // totalDistributed counts validator rewards + local pushes at
            // commit; the parked bucket is NOT yet counted.
            expect(
                await validatorRewards.totalDistributed(),
            ).to.equal((VALIDATOR_TOTAL_PER_EPOCH + LOCAL_PER_EPOCH) * 10n);
        });

        it('sends ONE batched ICTT message when the accumulator crosses the threshold, then resets', async function () {
            // 10 epochs accumulate 94.1005; epoch 11 pushes it to 103.51055
            // ≥ 100 → one send of the full accumulated bucket.
            await processNEpochs(10);
            expect(await mockTokenHome.sendCount()).to.equal(0);

            const tx = await processNextEpoch();
            await expect(tx).to.emit(
                validatorRewards,
                'CrossChainOverflowSent',
            );

            // ONE message carrying the ENTIRE accumulated bucket.
            expect(await mockTokenHome.sendCount()).to.equal(1);
            const sent = await mockTokenHome.lastSend();
            expect(BigInt(sent.amount)).to.equal(BUCKET_PER_EPOCH * 11n);

            // Accumulator reset to 0 after the send.
            expect(await validatorRewards.pendingCrossChainOverflow()).to.equal(0n);

            // Local leg flowed in the crossing epoch too (unchanged cadence).
            expect(await mockOverflowPool.totalReceived()).to.equal(
                LOCAL_PER_EPOCH * 11n,
            );

            // totalOverflowTransferred now includes the batched send.
            expect(
                await validatorRewards.totalOverflowTransferred(),
            ).to.equal((LOCAL_PER_EPOCH + BUCKET_PER_EPOCH) * 11n);

            // totalDistributed caught up: validator rewards + local + the
            // batched cross-chain send (bump at commit).
            expect(
                await validatorRewards.totalDistributed(),
            ).to.equal(
                VALIDATOR_TOTAL_PER_EPOCH * 11n
                    + (LOCAL_PER_EPOCH + BUCKET_PER_EPOCH) * 11n,
            );
        });

        it('messages-per-epoch drops to ~1 per 11 epochs at this threshold', async function () {
            // 22 epochs → exactly two batched sends (at epochs 11 and 22).
            await processNEpochs(22);
            expect(await mockTokenHome.sendCount()).to.equal(2);
            expect(await validatorRewards.pendingCrossChainOverflow()).to.equal(0n);
        });

        it('rolls the whole pending bucket to the L1 pool when the batched send fails (skip-not-revert)', async function () {
            await mockTokenHome.setShouldRevert(true);

            // Accumulate to 10 epochs (94.1005), then the crossing send fails.
            await processNEpochs(10);
            expect(await mockTokenHome.sendCount()).to.equal(0);
            expect(await validatorRewards.pendingCrossChainOverflow()).to.equal(
                BUCKET_PER_EPOCH * 10n,
            );

            const tx = await processNextEpoch();
            await expect(tx).to.emit(
                validatorRewards,
                'OverflowRoutingFailed',
            );
            // No send was recorded.
            expect(await mockTokenHome.sendCount()).to.equal(0);

            // The whole accumulated bucket (10 × 9.41005) + this epoch's
            // bucket AND this epoch's own local share fell back to the L1
            // pool in the crossing epoch; the accumulator is empty —
            // nothing parks in OVR.
            expect(await validatorRewards.pendingCrossChainOverflow()).to.equal(0n);
            expect(await mockOverflowPool.totalReceived()).to.equal(
                (LOCAL_PER_EPOCH + BUCKET_PER_EPOCH) * 11n,
            );
        });
    });

    // ──────────────────────────────────────────────────────────────────
    // 4. Unconfigured leg — no accumulation, per-epoch roll to L1
    // ──────────────────────────────────────────────────────────────────

    describe('unconfigured cross-chain leg (high threshold)', function () {
        it('rolls each epoch bucket to the L1 pool without accumulating', async function () {
            // Path NOT configured; high threshold would otherwise park the
            // bucket for ~11 epochs.
            await validatorRewards.setRemoteShareBps(6500);
            await validatorRewards.reinitializeV5(
                await mockBootstrap.getAddress(),
                E18(100n),
            );

            await processNEpochs(10);

            // Zero sends, zero parked accumulation.
            expect(await mockTokenHome.sendCount()).to.equal(0);
            expect(await validatorRewards.pendingCrossChainOverflow()).to.equal(0n);

            // 100% of every epoch's overflow flowed to the L1 pool.
            expect(await mockOverflowPool.totalReceived()).to.equal(
                ethers.parseEther('14.477') * 10n,
            );
        });

        it('drains the PARKED accumulator when the leg is torn down (no stranding)', async function () {
            // Configured at threshold 100 → 10 epochs park 94.1005.
            await configureCrossChain();
            await validatorRewards.reinitializeV5(
                await mockBootstrap.getAddress(),
                E18(100n),
            );
            await processNEpochs(10);
            expect(await validatorRewards.pendingCrossChainOverflow()).to.equal(
                BUCKET_PER_EPOCH * 10n,
            );
            expect(await mockOverflowPool.totalReceived()).to.equal(
                LOCAL_PER_EPOCH * 10n,
            );

            // Ops tears the leg down (documented disable path).
            await validatorRewards.setIcttTokenHome(ethers.ZeroAddress);

            // The next epoch drains the WHOLE parked accumulator (10 ×
            // bucket) plus this epoch's own bucket and local share to the
            // L1 pool. Nothing may strand in the accumulator.
            const tx = await processNextEpoch();
            await expect(tx).to.emit(
                validatorRewards,
                'CrossChainOverflowSkipped',
            );
            expect(await validatorRewards.pendingCrossChainOverflow()).to.equal(0n);
            expect(await mockOverflowPool.totalReceived()).to.equal(
                // 10 accumulation epochs' local shares + the drain epoch's
                // own local share + its bucket + the 10 parked buckets.
                (LOCAL_PER_EPOCH + BUCKET_PER_EPOCH) * 10n + LOCAL_PER_EPOCH + BUCKET_PER_EPOCH,
            );
        });

        it('drains the PARKED accumulator when remoteShareBps is zeroed', async function () {
            await configureCrossChain();
            await validatorRewards.reinitializeV5(
                await mockBootstrap.getAddress(),
                E18(100n),
            );
            await processNEpochs(10);
            expect(await validatorRewards.pendingCrossChainOverflow()).to.equal(
                BUCKET_PER_EPOCH * 10n,
            );

            // Governance turns the cross-chain share off entirely.
            await validatorRewards.setRemoteShareBps(0);

            // Next epoch: bucket == 0, but the parked 94.1005 must drain to
            // the L1 pool (it can never be sent while shareBps == 0).
            await processNextEpoch();
            expect(await validatorRewards.pendingCrossChainOverflow()).to.equal(0n);
            // 10 parked buckets + this epoch's full local overflow.
            expect(await mockOverflowPool.totalReceived()).to.equal(
                LOCAL_PER_EPOCH * 10n + BUCKET_PER_EPOCH * 10n + OVERFLOW_PER_EPOCH,
            );
        });

        it('re-credits a rolled batch to the accumulator when BOTH legs fail (no surplus conversion)', async function () {
            await configureCrossChain();
            await validatorRewards.reinitializeV5(
                await mockBootstrap.getAddress(),
                E18(100n),
            );
            await processNEpochs(10); // park 94.1005
            expect(await validatorRewards.pendingCrossChainOverflow()).to.equal(
                BUCKET_PER_EPOCH * 10n,
            );

            // Both legs down at the crossing epoch: ICTT send reverts AND
            // the L1 pool push reverts.
            await mockTokenHome.setShouldRevert(true);
            await mockOverflowPool.setShouldRevert(true);
            const tx = await processNextEpoch();
            await expect(tx).to.emit(validatorRewards, 'OverflowRoutingFailed');

            // The rolled batch (parked + this epoch's bucket) is re-credited
            // to the accumulator — NOT silently left as claimable surplus.
            expect(await validatorRewards.pendingCrossChainOverflow()).to.equal(
                BUCKET_PER_EPOCH * 11n,
            );
            // The pool only received the 10 pre-failure epochs.
            expect(await mockOverflowPool.totalReceived()).to.equal(
                LOCAL_PER_EPOCH * 10n,
            );

            // Both legs recover: the re-credited batch crosses the next
            // epoch and is sent in ONE ICTT message.
            await mockTokenHome.setShouldRevert(false);
            await mockOverflowPool.setShouldRevert(false);
            const tx2 = await processNextEpoch();
            await expect(tx2).to.emit(
                validatorRewards,
                'CrossChainOverflowSent',
            );
            expect(await mockTokenHome.sendCount()).to.equal(1);
            const sent = await mockTokenHome.lastSend();
            expect(BigInt(sent.amount)).to.equal(BUCKET_PER_EPOCH * 12n);
            expect(await validatorRewards.pendingCrossChainOverflow()).to.equal(0n);
        });

        it('remoteShareBps == 0 with a configured path pushes 100% locally (V4 parity)', async function () {
            await configureCrossChain();
            await validatorRewards.setRemoteShareBps(0);
            await validatorRewards.reinitializeV5(
                await mockBootstrap.getAddress(),
                E18(100n),
            );

            await processNEpochs(3);

            expect(await mockTokenHome.sendCount()).to.equal(0);
            expect(await validatorRewards.pendingCrossChainOverflow()).to.equal(0n);
            expect(await mockOverflowPool.totalReceived()).to.equal(
                OVERFLOW_PER_EPOCH * 3n,
            );
        });
    });

    // ──────────────────────────────────────────────────────────────────
    // 5. Node-type caps restoration (bootstrapContract wired by V5)
    // ──────────────────────────────────────────────────────────────────

    describe('node-type caps restoration', function () {
        it('gateways resolve to gatewayRewardCap and service nodes to the 1-wei service cap', async function () {
            // Live pre-V6 state: bootstrapContract == 0 → 1-wei cap for ALL.
            expect(await validatorRewards.getRewardCap(validators[0].address)).to.equal(SERVICE_CAP);

            await validatorRewards.reinitializeV5(
                await mockBootstrap.getAddress(),
                E18(100n),
            );

            // Gateway nodeType 0 → gatewayRewardCap.
            expect(await validatorRewards.getRewardCap(validators[0].address)).to.equal(GATEWAY_CAP);

            // A service node (nodeType 1) still resolves to the 1-wei cap.
            await mockBootstrap.setNode(unauthorized.address, true, 1);
            expect(await validatorRewards.getRewardCap(unauthorized.address)).to.equal(SERVICE_CAP);
        });

        it('a node absent from Bootstrap (inactive) resolves to the service cap', async function () {
            // unauthorized is a valid gateway candidate but NOT registered
            // in Bootstrap at all → inactive → service cap (graceful).
            await validatorRewards.reinitializeV5(
                await mockBootstrap.getAddress(),
                E18(100n),
            );
            expect(await validatorRewards.getRewardCap(unauthorized.address)).to.equal(SERVICE_CAP);
        });

        it('pays gateways their cap instead of 1 wei once wired (money-path behavior)', async function () {
            // Before V5, every "reward" was 1 wei.
            await configureCrossChain();
            await validatorRewards.reinitializeV5(
                await mockBootstrap.getAddress(),
                E18(100n),
            );

            await processNextEpoch();

            for (const v of validators) {
                expect(
                    await validatorRewards.accumulatedRewards(v.address),
                ).to.equal(GATEWAY_CAP);
            }
            // Overflow = 15.602 − 5 × 0.225, split 65/35 as configured.
            expect(await validatorRewards.pendingCrossChainOverflow()).to.equal(BUCKET_PER_EPOCH);
            expect(await mockOverflowPool.totalReceived()).to.equal(LOCAL_PER_EPOCH);
        });
    });

    // ──────────────────────────────────────────────────────────────────
    // 6. Solvency: pending bucket excluded from distribution
    // ──────────────────────────────────────────────────────────────────

    describe('solvency: the pending bucket is never double-spent', function () {
        it('keeps balance ≥ outstanding + pending across epochs and stops distributing before spending the bucket', async function () {
            // Self-contained deployment funded with only ~60 XOM so the
            // free (non-pending) balance runs out inside the test. Each
            // epoch commits ~15.6 XOM (validator promises + L1 push + the
            // parked bucket), so the distribution cap MUST fire within a
            // handful of epochs — proving the parked bucket was not spent
            // to keep paying validators.
            const OmniValidatorRewards = await ethers.getContractFactory(
                'OmniValidatorRewards',
            );
            const small = await upgrades.deployProxy(
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
            await small.reinitializeV3(await mockOverflowPool.getAddress());
            await small.setGatewayRewardCap(GATEWAY_CAP);
            await small.setServiceNodeRewardCap(SERVICE_CAP);
            await small.setActivityLedger(await mockActivityLedger.getAddress());
            await small.setOverflowEnabled(true);
            for (const v of validators) {
                await small.setStakeExempt(v.address, true);
            }
            // Cross-chain configured; threshold never crossed → pending grows.
            await small.setIcttTokenHome(await mockTokenHome.getAddress());
            await small.setCchainSender(cchainSenderAddr.address);
            await small.setCchainRemoteTransferrer(
                cchainRemoteTransferrerAddr.address,
            );
            await small.setCchainBlockchainID(CCHAIN_BLOCKCHAIN_ID);
            await small.setRemoteShareBps(6500);
            await small.reinitializeV5(
                await mockBootstrap.getAddress(),
                E18(100_000n),
            );
            await xom.mint(await small.getAddress(), E18(60n));

            const processEpochOn = async () => {
                const nextEpoch = (await small.lastProcessedEpoch()) + 1n;
                const currentEpoch = await small.getCurrentEpoch();
                if (nextEpoch > currentEpoch) {
                    await time.increase(EPOCH_DURATION + 1);
                }
                return await small.processEpoch(nextEpoch);
            };

            // Track: (a) the invariant balance ≥ outstanding + pending
            // after EVERY epoch, and (b) EpochRewardCapped fires once the
            // free balance is exhausted — proving the parked bucket was
            // not spent to keep paying validators.
            const capTopic = small.interface.getEvent('EpochRewardCapped').topicHash;
            let sawCap = false;
            for (let i = 0; i < 8; i++) {
                const tx = await processEpochOn();
                const rcpt = await tx.wait();
                sawCap = sawCap || rcpt.logs.some(
                    (l: any) => l.topics[0] === capTopic,
                );
                const bal = await xom.balanceOf(await small.getAddress());
                const outstanding = await small.totalOutstandingRewards();
                const pending = await small.pendingCrossChainOverflow();
                expect(bal).to.be.gte(outstanding + pending);
            }

            // With only 60 XOM funded and ~15.6 XOM/epoch committed, the
            // free balance is gone within ~4 epochs → the cap MUST have
            // fired (availableForRewards excludes the parked bucket).
            expect(sawCap).to.equal(true);

            // The bucket parked during the run is still fully held.
            const pending = await small.pendingCrossChainOverflow();
            expect(pending).to.be.gt(0n);
            const bal = await xom.balanceOf(await small.getAddress());
            const outstanding = await small.totalOutstandingRewards();
            expect(bal).to.be.gte(outstanding + pending);
        });
    });
});
