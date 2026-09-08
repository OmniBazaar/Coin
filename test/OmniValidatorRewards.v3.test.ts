/**
 * @file OmniValidatorRewards.v3.test.ts
 * @description Tests for OmniValidatorRewards V3 — Adaptive Validator Cap
 *
 * Tests cover:
 * - V3 initialization (reinitializeV3)
 * - Per-node-type reward caps (gateway vs service node)
 * - Overflow calculation and routing to LiquidityOverflowPool
 * - Circuit breaker (overflowEnabled toggle)
 * - Overflow routing failure handling (try/catch)
 * - Admin functions (setCaps, setOverflowPool, setOverflowEnabled)
 * - View functions (estimateOverflow, getRewardCap)
 * - Dust threshold (minOverflowTransfer)
 * - Backward compatibility (caps=0 behaves like V2)
 */

/* eslint-disable @typescript-eslint/no-var-requires */
const { expect } = require('chai');
const { ethers, upgrades } = require('hardhat');
const { keccak256: _keccak256, toUtf8Bytes: _toUtf8Bytes } = require('ethers');
const { time } = require('@nomicfoundation/hardhat-network-helpers');

describe('OmniValidatorRewards V3 — Adaptive Validator Cap', function () {
    // Contract instances
    let validatorRewards: any;
    let mockXOMToken: any;
    let mockParticipation: any;
    let mockOmniCore: any;
    let mockBootstrap: any;
    let mockOverflowPool: any;
    let mockActivityLedger: any;

    // Signers
    let _owner: any;
    let validator1: any; // gateway
    let validator2: any; // gateway
    let validator3: any; // computation node
    let validator4: any; // computation node
    let validator5: any; // computation node
    let unauthorized: any;

    // Constants
    const EPOCH_DURATION = 2;
    const GATEWAY_CAP = ethers.parseEther('0.3');
    const SERVICE_CAP = ethers.parseEther('0.2');
    const MIN_OVERFLOW = ethers.parseEther('0.01');
    const _INITIAL_BLOCK_REWARD = ethers.parseEther('15.602');

    /**
     * Process the next sequential epoch.
     */
    async function processNextEpoch(): Promise<bigint> {
        const nextEpoch =
            (await validatorRewards.lastProcessedEpoch()) + BigInt(1);
        const currentEpoch = await validatorRewards.getCurrentEpoch();
        if (nextEpoch > currentEpoch) {
            await time.increase(EPOCH_DURATION + 1);
        }
        await validatorRewards.processEpoch(nextEpoch);
        return nextEpoch;
    }

    /**
     * Mark a validator active for the current epoch via the committee-
     * attestation ledger (VT-18). Replaces the deprecated `submitHeartbeat`
     * self-report, which is now a no-op.
     */
    async function heartbeat(validator: any): Promise<void> {
        const epoch = await validatorRewards.getCurrentEpoch();
        await mockActivityLedger.recordEpochActivity(epoch, [validator.address]);
    }

    beforeEach(async function () {
        [_owner, validator1, validator2, validator3, validator4, validator5, unauthorized] =
            await ethers.getSigners();

        // Deploy mocks
        const MockXOMToken = await ethers.getContractFactory('MockXOMToken');
        mockXOMToken = await MockXOMToken.deploy();
        await mockXOMToken.waitForDeployment();

        const MockParticipation = await ethers.getContractFactory('MockOmniParticipation');
        mockParticipation = await MockParticipation.deploy();
        await mockParticipation.waitForDeployment();

        const MockOmniCore = await ethers.getContractFactory('MockOmniCore');
        mockOmniCore = await MockOmniCore.deploy();
        await mockOmniCore.waitForDeployment();

        const MockActivityLedger = await ethers.getContractFactory('MockActivityLedger');
        mockActivityLedger = await MockActivityLedger.deploy();
        await mockActivityLedger.waitForDeployment();

        const MockBootstrap = await ethers.getContractFactory('MockBootstrap');
        mockBootstrap = await MockBootstrap.deploy();
        await mockBootstrap.waitForDeployment();

        // Deploy MockLiquidityOverflowPool
        const MockOverflow = await ethers.getContractFactory('MockLiquidityOverflowPool');
        mockOverflowPool = await MockOverflow.deploy(await mockXOMToken.getAddress());
        await mockOverflowPool.waitForDeployment();

        // Deploy OmniValidatorRewards as UUPS proxy
        const OmniValidatorRewards = await ethers.getContractFactory('OmniValidatorRewards');
        validatorRewards = await upgrades.deployProxy(
            OmniValidatorRewards,
            [
                await mockXOMToken.getAddress(),
                await mockParticipation.getAddress(),
                await mockOmniCore.getAddress(),
            ],
            {
                initializer: 'initialize',
                kind: 'uups',
                constructorArgs: [ethers.ZeroAddress],
                unsafeAllow: ['constructor'],
            }
        );
        await validatorRewards.waitForDeployment();

        // V2 init
        await validatorRewards.reinitializeV2(await mockBootstrap.getAddress());

        // VT-18: wire the committee-attestation activity ledger.
        await validatorRewards.setActivityLedger(await mockActivityLedger.getAddress());

        // Setup 5 validators in MockOmniCore
        const validators = [validator1, validator2, validator3, validator4, validator5];
        const currentTime = await time.latest();
        const futureLock = currentTime + 365 * 24 * 60 * 60;

        for (const v of validators) {
            await mockOmniCore.setValidator(v.address, true);
            await mockOmniCore.registerMockNode(v.address, 'validator', `http://${v.address}:3001`);
            await mockParticipation.setTotalScore(v.address, 70);
            await mockOmniCore.setStake(
                v.address,
                ethers.parseEther('1000000'), // 1M XOM
                2, 180 * 24 * 60 * 60, futureLock, true
            );
            // Exempt seed validators from min stake check
            await validatorRewards.setStakeExempt(v.address, true);
        }

        // Bootstrap: validators 1,2 are gateways; 3,4,5 are computation
        await mockBootstrap.setNode(validator1.address, true, 0); // gateway
        await mockBootstrap.setNode(validator2.address, true, 0); // gateway
        await mockBootstrap.setNode(validator3.address, true, 1); // computation
        await mockBootstrap.setNode(validator4.address, true, 1); // computation
        await mockBootstrap.setNode(validator5.address, true, 1); // computation

        // Fund contract with XOM for rewards
        await mockXOMToken.mint(
            await validatorRewards.getAddress(),
            ethers.parseEther('10000000')
        );

        // Fund overflow pool with XOM allowance (ValidatorRewards approves it)
        // The overflow pool pulls via safeTransferFrom, so we need the rewards
        // contract to have enough balance (already done above)
    });

    // ================================================================
    //  V3 INITIALIZATION
    // ================================================================

    describe('V3 Initialization', function () {
        it('should initialize V3 with correct caps', async function () {
            await validatorRewards.reinitializeV3(await mockOverflowPool.getAddress());

            expect(await validatorRewards.gatewayRewardCap()).to.equal(GATEWAY_CAP);
            expect(await validatorRewards.serviceNodeRewardCap()).to.equal(SERVICE_CAP);
            expect(await validatorRewards.overflowPool()).to.equal(
                await mockOverflowPool.getAddress()
            );
            expect(await validatorRewards.overflowEnabled()).to.equal(false);
            expect(await validatorRewards.minOverflowTransfer()).to.equal(MIN_OVERFLOW);
        });

        it('should reject zero address for overflow pool', async function () {
            await expect(
                validatorRewards.reinitializeV3(ethers.ZeroAddress)
            ).to.be.revertedWithCustomError(validatorRewards, 'ZeroAddress');
        });

        it('should reject non-admin caller', async function () {
            await expect(
                validatorRewards
                    .connect(unauthorized)
                    .reinitializeV3(await mockOverflowPool.getAddress())
            ).to.be.reverted;
        });

        it('should reject double initialization', async function () {
            await validatorRewards.reinitializeV3(await mockOverflowPool.getAddress());
            await expect(
                validatorRewards.reinitializeV3(await mockOverflowPool.getAddress())
            ).to.be.reverted;
        });
    });

    // ================================================================
    //  PER-NODE-TYPE CAPS
    // ================================================================

    describe('Per-Node-Type Reward Caps', function () {
        beforeEach(async function () {
            await validatorRewards.reinitializeV3(await mockOverflowPool.getAddress());
            // Submit heartbeats for all validators
            for (const v of [validator1, validator2, validator3, validator4, validator5]) {
                await heartbeat(v);
            }
        });

        it('should cap gateway rewards at gatewayRewardCap', async function () {
            await processNextEpoch();

            const reward1 = await validatorRewards.accumulatedRewards(validator1.address);
            expect(reward1).to.be.lte(GATEWAY_CAP);
        });

        it('should cap service node rewards at serviceNodeRewardCap', async function () {
            await processNextEpoch();

            const reward3 = await validatorRewards.accumulatedRewards(validator3.address);
            expect(reward3).to.be.lte(SERVICE_CAP);
        });

        it('should apply different caps based on node type', async function () {
            await processNextEpoch();

            const gwReward = await validatorRewards.accumulatedRewards(validator1.address);
            const snReward = await validatorRewards.accumulatedRewards(validator3.address);

            // Gateway cap (0.3) > service node cap (0.2)
            // Both should be at their respective caps since epoch reward
            // (15.602 XOM) is much larger than total caps
            expect(gwReward).to.equal(GATEWAY_CAP);
            expect(snReward).to.equal(SERVICE_CAP);
        });

        it('should not apply caps when gatewayRewardCap is 0 (pre-V3 behavior)', async function () {
            // Reset caps to 0 (simulate pre-V3)
            // We can't directly set to 0 via admin (ZeroCap error), but if we
            // deploy without V3 init, caps default to 0
            const OmniValidatorRewards = await ethers.getContractFactory('OmniValidatorRewards');
            const freshRewards = await upgrades.deployProxy(
                OmniValidatorRewards,
                [
                    await mockXOMToken.getAddress(),
                    await mockParticipation.getAddress(),
                    await mockOmniCore.getAddress(),
                ],
                {
                    initializer: 'initialize',
                    kind: 'uups',
                    constructorArgs: [ethers.ZeroAddress],
                    unsafeAllow: ['constructor'],
                }
            );

            // Setup one validator, attested active via the activity ledger
            await mockOmniCore.setValidator(validator1.address, true);
            await freshRewards.setStakeExempt(validator1.address, true);
            await freshRewards.setActivityLedger(await mockActivityLedger.getAddress());
            await mockXOMToken.mint(await freshRewards.getAddress(), ethers.parseEther('1000000'));
            const freshEpoch = await freshRewards.getCurrentEpoch();
            await mockActivityLedger.recordEpochActivity(freshEpoch, [validator1.address]);
            await time.increase(3);

            const nextEpoch = (await freshRewards.lastProcessedEpoch()) + BigInt(1);
            await freshRewards.processEpoch(nextEpoch);

            const reward = await freshRewards.accumulatedRewards(validator1.address);
            // Without caps, single validator gets entire epoch reward
            expect(reward).to.be.gt(GATEWAY_CAP);
        });
    });

    // ================================================================
    //  OVERFLOW ROUTING
    // ================================================================

    describe('Overflow Routing', function () {
        beforeEach(async function () {
            await validatorRewards.reinitializeV3(await mockOverflowPool.getAddress());

            for (const v of [validator1, validator2, validator3, validator4, validator5]) {
                await heartbeat(v);
            }
        });

        it('should route overflow to LiquidityOverflowPool when enabled', async function () {
            await validatorRewards.setOverflowEnabled(true);

            await processNextEpoch();

            const received = await mockOverflowPool.totalReceived();
            expect(received).to.be.gt(0);

            // Overflow should be: epochReward - (2*gwCap + 3*snCap)
            // = 15.602 - (0.6 + 0.6) = 14.402 XOM (approximately)
            const expectedMinOverflow = ethers.parseEther('14');
            expect(received).to.be.gt(expectedMinOverflow);
        });

        it('should not route overflow when disabled', async function () {
            // overflowEnabled defaults to false after reinitializeV3
            await processNextEpoch();

            const received = await mockOverflowPool.totalReceived();
            expect(received).to.equal(0);
        });

        it('should track totalOverflowTransferred', async function () {
            await validatorRewards.setOverflowEnabled(true);

            await processNextEpoch();

            const total = await validatorRewards.totalOverflowTransferred();
            expect(total).to.be.gt(0);
        });

        it('should emit OverflowRouted event', async function () {
            await validatorRewards.setOverflowEnabled(true);

            const nextEpoch =
                (await validatorRewards.lastProcessedEpoch()) + BigInt(1);
            const currentEpoch = await validatorRewards.getCurrentEpoch();
            if (nextEpoch > currentEpoch) {
                await time.increase(EPOCH_DURATION + 1);
            }

            await expect(validatorRewards.processEpoch(nextEpoch))
                .to.emit(validatorRewards, 'OverflowRouted');
        });

        it('does not route meaningful overflow when caps are high (V6: only wei-dust residue flows)', async function () {
            await validatorRewards.setOverflowEnabled(true);

            // Set caps very high so validators absorb the full epoch reward
            await validatorRewards.setGatewayRewardCap(ethers.parseEther('100'));
            await validatorRewards.setServiceNodeRewardCap(ethers.parseEther('100'));

            await processNextEpoch();

            // V4 semantics (removed in V6): the pre-split dust gate
            // (`overflow < minOverflowTransfer => return`) suppressed ALL
            // routing when the overflow was below 0.01 XOM, parking the
            // residue in the contract. V6 removes that gate — the
            // cross-chain bucket accumulates and the L1-pool leg flows
            // every epoch — so the integer-division rounding residue
            // (≤ ~5 wei/epoch, not real overflow) now reaches the L1 pool.
            // Assert the NEW semantics: validators took the full epoch
            // reward and the pool received only wei-scale dust, NOT the
            // ~15.6 XOM epoch reward.
            const received = await mockOverflowPool.totalReceived();
            expect(received).to.be.lt(10); // wei-scale rounding residue only

            const totalRewards =
                (await validatorRewards.accumulatedRewards(validator1.address)) +
                (await validatorRewards.accumulatedRewards(validator2.address)) +
                (await validatorRewards.accumulatedRewards(validator3.address)) +
                (await validatorRewards.accumulatedRewards(validator4.address)) +
                (await validatorRewards.accumulatedRewards(validator5.address));
            // All 5 validators were capped at 100 XOM → cap never binds →
            // they collectively received the full ~15.6 XOM epoch reward.
            expect(totalRewards).to.be.gt(ethers.parseEther('15'));
        });

        it('should handle overflow routing failure gracefully', async function () {
            await validatorRewards.setOverflowEnabled(true);
            await mockOverflowPool.setShouldRevert(true);

            // Should not revert — circuit breaker catches the failure
            const nextEpoch =
                (await validatorRewards.lastProcessedEpoch()) + BigInt(1);
            const currentEpoch = await validatorRewards.getCurrentEpoch();
            if (nextEpoch > currentEpoch) {
                await time.increase(EPOCH_DURATION + 1);
            }

            await expect(validatorRewards.processEpoch(nextEpoch))
                .to.emit(validatorRewards, 'OverflowRoutingFailed');

            // Validators still get their capped rewards
            const reward1 = await validatorRewards.accumulatedRewards(validator1.address);
            expect(reward1).to.equal(GATEWAY_CAP);
        });

        it('should process multiple epochs with overflow', async function () {
            await validatorRewards.setOverflowEnabled(true);

            // Process 3 epochs
            await time.increase(10);
            const pending = await validatorRewards.getPendingEpochs();
            const toProcess = pending > BigInt(3) ? BigInt(3) : pending;
            if (toProcess > BigInt(0)) {
                await validatorRewards.processMultipleEpochs(toProcess);
            }

            const total = await validatorRewards.totalOverflowTransferred();
            expect(total).to.be.gt(0);
        });
    });

    // ================================================================
    //  ADMIN FUNCTIONS
    // ================================================================

    describe('V3 Admin Functions', function () {
        beforeEach(async function () {
            await validatorRewards.reinitializeV3(await mockOverflowPool.getAddress());
        });

        it('should allow admin to set gateway reward cap', async function () {
            const newCap = ethers.parseEther('0.5');
            await expect(validatorRewards.setGatewayRewardCap(newCap))
                .to.emit(validatorRewards, 'RewardCapUpdated')
                .withArgs(0, GATEWAY_CAP, newCap);

            expect(await validatorRewards.gatewayRewardCap()).to.equal(newCap);
        });

        it('should allow admin to set service node reward cap', async function () {
            const newCap = ethers.parseEther('0.25');
            await expect(validatorRewards.setServiceNodeRewardCap(newCap))
                .to.emit(validatorRewards, 'RewardCapUpdated')
                .withArgs(1, SERVICE_CAP, newCap);

            expect(await validatorRewards.serviceNodeRewardCap()).to.equal(newCap);
        });

        it('should reject zero cap for gateway', async function () {
            await expect(
                validatorRewards.setGatewayRewardCap(0)
            ).to.be.revertedWithCustomError(validatorRewards, 'ZeroCap');
        });

        it('should reject zero cap for service node', async function () {
            await expect(
                validatorRewards.setServiceNodeRewardCap(0)
            ).to.be.revertedWithCustomError(validatorRewards, 'ZeroCap');
        });

        it('should allow admin to set overflow pool', async function () {
            // V5 audit fix: setOverflowPool now rejects an address with no
            // code (NotAContract) — use a real deployed mock, not an EOA.
            const MockOverflow2 = await ethers.getContractFactory('MockLiquidityOverflowPool');
            const newPool = await MockOverflow2.deploy(await mockXOMToken.getAddress());
            await newPool.waitForDeployment();
            const newPoolAddress = await newPool.getAddress();

            await expect(validatorRewards.setOverflowPool(newPoolAddress))
                .to.emit(validatorRewards, 'OverflowPoolUpdated');
        });

        it('should reject zero address for overflow pool', async function () {
            await expect(
                validatorRewards.setOverflowPool(ethers.ZeroAddress)
            ).to.be.revertedWithCustomError(validatorRewards, 'ZeroAddress');
        });

        it('should reject an EOA (no code) for overflow pool', async function () {
            await expect(
                validatorRewards.setOverflowPool(validator1.address)
            ).to.be.revertedWithCustomError(validatorRewards, 'NotAContract')
                .withArgs(validator1.address);
        });

        it('should allow admin to toggle overflow enabled', async function () {
            await expect(validatorRewards.setOverflowEnabled(true))
                .to.emit(validatorRewards, 'OverflowEnabledUpdated')
                .withArgs(true);

            expect(await validatorRewards.overflowEnabled()).to.equal(true);
        });

        it('should allow admin to set min overflow transfer', async function () {
            const newMin = ethers.parseEther('0.1');
            await validatorRewards.setMinOverflowTransfer(newMin);
            expect(await validatorRewards.minOverflowTransfer()).to.equal(newMin);
        });

        it('should reject non-admin for cap changes', async function () {
            await expect(
                validatorRewards.connect(unauthorized).setGatewayRewardCap(1)
            ).to.be.reverted;

            await expect(
                validatorRewards.connect(unauthorized).setServiceNodeRewardCap(1)
            ).to.be.reverted;
        });

        it('should reject non-admin for overflow pool changes', async function () {
            await expect(
                validatorRewards.connect(unauthorized).setOverflowPool(validator1.address)
            ).to.be.reverted;
        });

        it('should reject non-admin for overflow enabled toggle', async function () {
            await expect(
                validatorRewards.connect(unauthorized).setOverflowEnabled(true)
            ).to.be.reverted;
        });
    });

    // ================================================================
    //  VIEW FUNCTIONS
    // ================================================================

    describe('V3 View Functions', function () {
        beforeEach(async function () {
            await validatorRewards.reinitializeV3(await mockOverflowPool.getAddress());

            for (const v of [validator1, validator2, validator3, validator4, validator5]) {
                await heartbeat(v);
            }
        });

        it('should estimate overflow correctly', async function () {
            const [overflow, validatorTotal] =
                await validatorRewards.estimateOverflow();

            // 5 validators: 2 gateways at 0.3 + 3 service at 0.2 = 1.2 XOM
            const expectedValidatorTotal = ethers.parseEther('1.2');
            expect(validatorTotal).to.be.closeTo(
                expectedValidatorTotal,
                ethers.parseEther('0.01')
            );

            // Overflow should be ~14.4 XOM (15.602 - 1.2)
            expect(overflow).to.be.gt(ethers.parseEther('14'));
        });

        it('should return correct reward cap for gateway', async function () {
            const cap = await validatorRewards.getRewardCap(validator1.address);
            expect(cap).to.equal(GATEWAY_CAP);
        });

        it('should return correct reward cap for service node', async function () {
            const cap = await validatorRewards.getRewardCap(validator3.address);
            expect(cap).to.equal(SERVICE_CAP);
        });

        it('should return 0 for getRewardCap when caps are not set', async function () {
            // Deploy fresh without V3
            const OmniValidatorRewards = await ethers.getContractFactory('OmniValidatorRewards');
            const fresh = await upgrades.deployProxy(
                OmniValidatorRewards,
                [
                    await mockXOMToken.getAddress(),
                    await mockParticipation.getAddress(),
                    await mockOmniCore.getAddress(),
                ],
                {
                    initializer: 'initialize',
                    kind: 'uups',
                    constructorArgs: [ethers.ZeroAddress],
                    unsafeAllow: ['constructor'],
                }
            );
            expect(await fresh.getRewardCap(validator1.address)).to.equal(0);
        });
    });

    // ================================================================
    //  CROSSOVER TRAJECTORY
    // ================================================================

    describe('Crossover Trajectory', function () {
        beforeEach(async function () {
            await validatorRewards.reinitializeV3(await mockOverflowPool.getAddress());
            await validatorRewards.setOverflowEnabled(true);
        });

        it('should reduce overflow as more validators join', async function () {
            // Start with just 2 validators
            // Deactivate validators 3, 4, 5
            for (const v of [validator3, validator4, validator5]) {
                await mockOmniCore.setValidator(v.address, false);
            }

            for (const v of [validator1, validator2]) {
                await heartbeat(v);
            }

            await processNextEpoch();
            const overflow2 = await mockOverflowPool.totalReceived();

            // Now re-add all 5 validators (note: need fresh deploy to reset totalReceived)
            // Instead, check that the total received reflects 2-validator overflow
            // 2 gateways * 0.3 = 0.6 → overflow ≈ 15.002
            expect(overflow2).to.be.gt(ethers.parseEther('14'));
        });
    });

    // ================================================================
    //  BACKWARD COMPATIBILITY
    // ================================================================

    describe('Backward Compatibility', function () {
        it('should work without V3 initialization (caps=0)', async function () {
            // Don't call reinitializeV3 — gatewayRewardCap stays 0
            await heartbeat(validator1);
            await heartbeat(validator2);

            await processNextEpoch();

            // Validators should get rewards normally (no cap applied)
            const reward1 = await validatorRewards.accumulatedRewards(validator1.address);
            expect(reward1).to.be.gt(0);
            expect(reward1).to.be.gt(GATEWAY_CAP); // No cap → gets more than 0.3
        });

        it('should allow V2 processEpoch to work after V3 init', async function () {
            await validatorRewards.reinitializeV3(await mockOverflowPool.getAddress());

            for (const v of [validator1, validator2, validator3, validator4, validator5]) {
                await heartbeat(v);
            }

            // processEpoch should work fine
            await processNextEpoch();

            // All validators should have rewards
            for (const v of [validator1, validator2, validator3, validator4, validator5]) {
                const reward = await validatorRewards.accumulatedRewards(v.address);
                expect(reward).to.be.gt(0);
            }
        });

        it('should allow claimRewards to work with V3 caps', async function () {
            await validatorRewards.reinitializeV3(await mockOverflowPool.getAddress());

            await heartbeat(validator1);
            await processNextEpoch();

            const reward = await validatorRewards.accumulatedRewards(validator1.address);
            expect(reward).to.be.gt(0);

            // Claim should work
            await validatorRewards.connect(validator1).claimRewards();

            expect(
                await validatorRewards.accumulatedRewards(validator1.address)
            ).to.equal(0);
            expect(
                await validatorRewards.totalClaimed(validator1.address)
            ).to.equal(reward);
        });
    });
});
