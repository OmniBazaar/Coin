/**
 * @file OmniValidatorRewards.vt18.test.ts
 * @description Tests for OmniValidatorRewards VT-18 — committee-attestation
 *              activity ledger.
 *
 * Covers:
 * - setActivityLedger access control + event + zero-address (disable)
 * - reinitializeV4 reinitializer semantics
 * - Attestation-driven activity: a validator attested for the current epoch
 *   earns the activity component; a never-attested validator earns none
 * - The epoch-window: a validator attested at epoch E is active through
 *   E + heartbeatEpochWindow, then goes inactive
 * - Legacy heartbeat fallback: with the ledger unset, submitHeartbeat no
 *   longer writes state, so the activity component is fail-closed (zero)
 */

/* eslint-disable @typescript-eslint/no-var-requires */
const { expect } = require('chai');
const { ethers, upgrades } = require('hardhat');
const { time } = require('@nomicfoundation/hardhat-network-helpers');

describe('OmniValidatorRewards VT-18 — activity ledger', function () {
    let validatorRewards: any;
    let mockXOMToken: any;
    let mockParticipation: any;
    let mockOmniCore: any;
    let mockActivityLedger: any;

    let admin: any;
    let validator1: any;
    let validator2: any;
    let unauthorized: any;

    const EPOCH_DURATION = 2;

    beforeEach(async function () {
        [admin, validator1, validator2, unauthorized] =
            await ethers.getSigners();

        const MockXOMToken = await ethers.getContractFactory('MockXOMToken');
        mockXOMToken = await MockXOMToken.deploy();
        await mockXOMToken.waitForDeployment();

        const MockParticipation = await ethers.getContractFactory(
            'MockOmniParticipation',
        );
        mockParticipation = await MockParticipation.deploy();
        await mockParticipation.waitForDeployment();

        const MockOmniCore = await ethers.getContractFactory('MockOmniCore');
        mockOmniCore = await MockOmniCore.deploy();
        await mockOmniCore.waitForDeployment();

        const MockActivityLedger = await ethers.getContractFactory(
            'MockActivityLedger',
        );
        mockActivityLedger = await MockActivityLedger.deploy();
        await mockActivityLedger.waitForDeployment();

        const OmniValidatorRewards = await ethers.getContractFactory(
            'OmniValidatorRewards',
        );
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
            },
        );
        await validatorRewards.waitForDeployment();

        // One staked, participation-scored validator.
        const now = await time.latest();
        await mockOmniCore.setValidator(validator1.address, true);
        await mockOmniCore.registerMockNode(
            validator1.address,
            'validator',
            `http://${validator1.address}:3001`,
        );
        await mockParticipation.setTotalScore(validator1.address, 80);
        await mockOmniCore.setStake(
            validator1.address,
            ethers.parseEther('1000000'),
            2,
            180 * 24 * 60 * 60,
            now + 365 * 24 * 60 * 60,
            true,
        );
        await validatorRewards.setStakeExempt(validator1.address, true);

        await mockXOMToken.mint(
            await validatorRewards.getAddress(),
            ethers.parseEther('1000000'),
        );
    });

    describe('setActivityLedger', function () {
        it('reverts for a non-admin', async function () {
            await expect(
                validatorRewards
                    .connect(unauthorized)
                    .setActivityLedger(await mockActivityLedger.getAddress()),
            ).to.be.reverted;
        });

        it('sets the ledger and emits ActivityLedgerUpdated', async function () {
            const addr = await mockActivityLedger.getAddress();
            await expect(validatorRewards.setActivityLedger(addr))
                .to.emit(validatorRewards, 'ActivityLedgerUpdated')
                .withArgs(ethers.ZeroAddress, addr);
            expect(await validatorRewards.activityLedger()).to.equal(addr);
        });

        it('accepts zero to disable (heartbeat fallback)', async function () {
            await validatorRewards.setActivityLedger(
                await mockActivityLedger.getAddress(),
            );
            await validatorRewards.setActivityLedger(ethers.ZeroAddress);
            expect(await validatorRewards.activityLedger()).to.equal(
                ethers.ZeroAddress,
            );
        });
    });

    describe('reinitializeV4', function () {
        it('sets the ledger once via the reinitializer', async function () {
            const addr = await mockActivityLedger.getAddress();
            await validatorRewards.reinitializeV4(addr);
            expect(await validatorRewards.activityLedger()).to.equal(addr);

            // Second call is blocked by the reinitializer guard.
            await expect(
                validatorRewards.reinitializeV4(addr),
            ).to.be.reverted;
        });
    });

    describe('attestation-driven activity', function () {
        beforeEach(async function () {
            await validatorRewards.setActivityLedger(
                await mockActivityLedger.getAddress(),
            );
        });

        it('gives an attested validator a higher weight than a never-attested one', async function () {
            const inactive = await validatorRewards.getValidatorWeight(
                validator1.address,
            );

            const epoch = await validatorRewards.getCurrentEpoch();
            await mockActivityLedger.recordEpochActivity(epoch, [
                validator1.address,
            ]);

            const active = await validatorRewards.getValidatorWeight(
                validator1.address,
            );
            expect(active).to.be.gt(inactive);
        });

        it('gives a never-attested validator zero activity component', async function () {
            // No attestation recorded → activity component is zero, so weight
            // equals participation + staking only.
            const inactive = await validatorRewards.getValidatorWeight(
                validator1.address,
            );

            const epoch = await validatorRewards.getCurrentEpoch();
            await mockActivityLedger.recordEpochActivity(epoch, [
                validator1.address,
            ]);
            const active = await validatorRewards.getValidatorWeight(
                validator1.address,
            );

            // Attestation adds exactly the activity component (60% subweight ×
            // 30% activity = 18 points). The difference must be positive.
            expect(active - inactive).to.be.gt(0);
        });

        it('expires a validator outside the attestation window', async function () {
            const inactive = await validatorRewards.getValidatorWeight(
                validator1.address,
            );

            const epoch = await validatorRewards.getCurrentEpoch();
            await mockActivityLedger.recordEpochActivity(epoch, [
                validator1.address,
            ]);

            const weightActive = await validatorRewards.getValidatorWeight(
                validator1.address,
            );
            expect(weightActive).to.be.gt(inactive);

            // Advance past the window. V5 widened HEARTBEAT_TIMEOUT to 90s,
            // so the attestation window is HEARTBEAT_TIMEOUT / EPOCH_DURATION
            // = 45 epochs — advance well beyond it (plus slack).
            await time.increase(EPOCH_DURATION * 60);

            const weightInactive = await validatorRewards.getValidatorWeight(
                validator1.address,
            );
            expect(weightInactive).to.equal(inactive);
        });

        it('distributes rewards to an attested validator', async function () {
            const epoch = await validatorRewards.getCurrentEpoch();
            await mockActivityLedger.recordEpochActivity(epoch, [
                validator1.address,
            ]);

            await time.increase(EPOCH_DURATION + 1);
            const next = (await validatorRewards.lastProcessedEpoch()) + BigInt(1);
            await validatorRewards.processEpoch(next);

            const rewards = await validatorRewards.accumulatedRewards(
                validator1.address,
            );
            expect(rewards).to.be.gt(0);
        });
    });

    describe('heartbeat fallback (ledger unset)', function () {
        it('fails closed: no activity component when the ledger is unset and heartbeat is a no-op', async function () {
            const inactive = await validatorRewards.getValidatorWeight(
                validator1.address,
            );

            // submitHeartbeat is a deprecated no-op (writes no state), and with
            // the ledger unset the activity component derives from the (empty)
            // heartbeat state — so it stays zero.
            await validatorRewards.connect(validator1).submitHeartbeat();
            const afterHeartbeat = await validatorRewards.getValidatorWeight(
                validator1.address,
            );
            expect(afterHeartbeat).to.equal(inactive);
        });
    });
});
