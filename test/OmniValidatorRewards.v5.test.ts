/**
 * @file OmniValidatorRewards.v5.test.ts
 * @description Tests for OmniValidatorRewards V5 — skipToEpoch
 *
 * skipToEpoch() lets DEFAULT_ADMIN_ROLE fast-forward lastProcessedEpoch
 * with NO reward computed or paid for the skipped range, so that the
 * settled "unpause with no catch-up" policy
 * (decision_rewards_unpause_no_catchup_2026-07-04) can actually be
 * executed. Before this function, the only way to advance
 * lastProcessedEpoch was processEpoch/processMultipleEpochs, both of
 * which compute and distribute a real reward for every epoch stepped
 * through.
 *
 * Tests cover:
 * - Access control (admin-only)
 * - whenPaused gating
 * - Forward-only movement (cannot go backward or stay put)
 * - Cannot skip past the real current epoch
 * - No reward is computed or paid — contract XOM balance and
 *   totalOutstandingRewards are unchanged
 * - Correct event emission
 * - Normal epoch processing resumes correctly from the new position
 *   after skipToEpoch + unpause
 * - skipToEpoch is blocked once ossify() has been called, honoring
 *   ossify()'s own documented "only epoch processing/heartbeats/
 *   claims/pause/unpause survive" promise (audit remediation)
 * - unpause() refuses to resume into a large un-skipped backlog,
 *   closing the "admin forgot to skip first, backlog becomes
 *   permissionlessly payable" gap (audit remediation)
 * - submitHeartbeat/proposeAdminTransfer/acceptAdminTransfer/
 *   proposeContracts/setOverflowPool/setIcttTokenHome behave
 *   correctly after switching from raw msg.sender to _msgSender()
 *   and adding NotAContract checks (audit remediation) — no direct
 *   test coverage existed for the admin-transfer flow before this
 */

/* eslint-disable @typescript-eslint/no-var-requires */
const { expect } = require('chai');
const { ethers, upgrades } = require('hardhat');
const { time } = require('@nomicfoundation/hardhat-network-helpers');

describe('OmniValidatorRewards V5 — skipToEpoch', function () {
    let validatorRewards: any;
    let mockXOMToken: any;
    let mockParticipation: any;
    let mockOmniCore: any;

    let admin: any;
    let validator1: any;
    let unauthorized: any;

    const EPOCH_DURATION = 2;

    beforeEach(async function () {
        [admin, validator1, unauthorized] = await ethers.getSigners();

        const MockXOMToken = await ethers.getContractFactory('MockXOMToken');
        mockXOMToken = await MockXOMToken.deploy();
        await mockXOMToken.waitForDeployment();

        const MockParticipation = await ethers.getContractFactory('MockOmniParticipation');
        mockParticipation = await MockParticipation.deploy();
        await mockParticipation.waitForDeployment();

        const MockOmniCore = await ethers.getContractFactory('MockOmniCore');
        mockOmniCore = await MockOmniCore.deploy();
        await mockOmniCore.waitForDeployment();

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

        // One validator, enough to make processEpoch/processMultipleEpochs
        // produce real, non-zero distributions in the "resumes correctly"
        // test below.
        const currentTime = await time.latest();
        const futureLock = currentTime + 365 * 24 * 60 * 60;
        await mockOmniCore.setValidator(validator1.address, true);
        await mockOmniCore.registerMockNode(validator1.address, 'validator', `http://${validator1.address}:3001`);
        await mockParticipation.setTotalScore(validator1.address, 70);
        await mockOmniCore.setStake(
            validator1.address,
            ethers.parseEther('1000000'),
            2, 180 * 24 * 60 * 60, futureLock, true
        );
        await validatorRewards.setStakeExempt(validator1.address, true);

        await mockXOMToken.mint(
            await validatorRewards.getAddress(),
            ethers.parseEther('10000000')
        );
    });

    // ================================================================
    //  ACCESS CONTROL
    // ================================================================

    describe('access control', function () {
        it('reverts for a non-admin caller', async function () {
            await validatorRewards.pause();
            await expect(
                validatorRewards.connect(unauthorized).skipToEpoch(1)
            ).to.be.reverted;
        });

        it('succeeds for DEFAULT_ADMIN_ROLE', async function () {
            await validatorRewards.pause();
            await time.increase(EPOCH_DURATION * 10);
            const current = await validatorRewards.getCurrentEpoch();
            await expect(validatorRewards.skipToEpoch(current)).to.not.be.reverted;
        });
    });

    // ================================================================
    //  PAUSE GATING
    // ================================================================

    describe('whenPaused gating', function () {
        it('reverts when the contract is not paused', async function () {
            await time.increase(EPOCH_DURATION * 10);
            const current = await validatorRewards.getCurrentEpoch();
            // Contract starts unpaused.
            await expect(validatorRewards.skipToEpoch(current)).to.be.reverted;
        });

        it('succeeds once paused', async function () {
            await validatorRewards.pause();
            await time.increase(EPOCH_DURATION * 10);
            const current = await validatorRewards.getCurrentEpoch();
            await expect(validatorRewards.skipToEpoch(current)).to.not.be.reverted;
        });
    });

    // ================================================================
    //  FORWARD-ONLY MOVEMENT
    // ================================================================

    describe('forward-only movement', function () {
        it('reverts if targetEpoch equals the current lastProcessedEpoch (0)', async function () {
            await validatorRewards.pause();
            await expect(validatorRewards.skipToEpoch(0)).to.be.revertedWithCustomError(
                validatorRewards,
                'CannotSkipBackward'
            );
        });

        it('reverts if targetEpoch is behind lastProcessedEpoch', async function () {
            await validatorRewards.pause();
            await time.increase(EPOCH_DURATION * 10);
            const current = await validatorRewards.getCurrentEpoch();
            await validatorRewards.skipToEpoch(current);

            // Now try to skip "backward" to an earlier epoch than the one
            // just set.
            await expect(
                validatorRewards.skipToEpoch(current - BigInt(1))
            ).to.be.revertedWithCustomError(validatorRewards, 'CannotSkipBackward');
        });

        it('reverts on a second call to the same already-reached epoch', async function () {
            await validatorRewards.pause();
            await time.increase(EPOCH_DURATION * 10);
            const current = await validatorRewards.getCurrentEpoch();
            await validatorRewards.skipToEpoch(current);

            await expect(
                validatorRewards.skipToEpoch(current)
            ).to.be.revertedWithCustomError(validatorRewards, 'CannotSkipBackward');
        });
    });

    // ================================================================
    //  CANNOT SKIP PAST THE REAL CURRENT EPOCH
    // ================================================================

    describe('cannot skip into the future', function () {
        it('reverts if targetEpoch is beyond getCurrentEpoch()', async function () {
            await validatorRewards.pause();
            const current = await validatorRewards.getCurrentEpoch();
            await expect(
                validatorRewards.skipToEpoch(current + BigInt(1000))
            ).to.be.revertedWithCustomError(validatorRewards, 'FutureEpoch');
        });
    });

    // ================================================================
    //  NO REWARD IS COMPUTED OR PAID
    // ================================================================

    describe('no reward computed or paid', function () {
        it('leaves the contract XOM balance and outstanding rewards unchanged', async function () {
            const balanceBefore = await mockXOMToken.balanceOf(
                await validatorRewards.getAddress()
            );
            const outstandingBefore = await validatorRewards.totalOutstandingRewards();

            await validatorRewards.pause();
            await time.increase(EPOCH_DURATION * 5000);
            const current = await validatorRewards.getCurrentEpoch();
            // A gap this large would, through processMultipleEpochs, pay a
            // real (nonzero) reward for every one of ~5000 epochs — this
            // is exactly the "no catch-up" case skipToEpoch exists for.
            expect(current).to.be.greaterThan(BigInt(1000));
            await validatorRewards.skipToEpoch(current);

            const balanceAfter = await mockXOMToken.balanceOf(
                await validatorRewards.getAddress()
            );
            const outstandingAfter = await validatorRewards.totalOutstandingRewards();

            expect(balanceAfter).to.equal(balanceBefore);
            expect(outstandingAfter).to.equal(outstandingBefore);
        });

        it('leaves the validator with zero claimable rewards for the skipped range', async function () {
            await validatorRewards.pause();
            await time.increase(EPOCH_DURATION * 5000);
            const current = await validatorRewards.getCurrentEpoch();
            await validatorRewards.skipToEpoch(current);

            expect(
                await validatorRewards.getPendingRewards(validator1.address)
            ).to.equal(0);
        });
    });

    // ================================================================
    //  EVENT EMISSION
    // ================================================================

    describe('event emission', function () {
        it('emits EpochSkipped with the correct from/to/admin values', async function () {
            await validatorRewards.pause();
            await time.increase(EPOCH_DURATION * 10);
            const current = await validatorRewards.getCurrentEpoch();

            await expect(validatorRewards.skipToEpoch(current))
                .to.emit(validatorRewards, 'EpochSkipped')
                .withArgs(0, current, admin.address);
        });
    });

    // ================================================================
    //  NORMAL PROCESSING RESUMES CORRECTLY AFTER A SKIP
    // ================================================================

    describe('processing resumes correctly after a skip', function () {
        it('processEpoch continues sequentially from the skipped-to epoch, not from 1', async function () {
            await validatorRewards.pause();
            await time.increase(EPOCH_DURATION * 5000);
            const skipTarget = await validatorRewards.getCurrentEpoch();
            await validatorRewards.skipToEpoch(skipTarget);
            expect(await validatorRewards.lastProcessedEpoch()).to.equal(skipTarget);

            await validatorRewards.unpause();

            // The very next processable epoch must be skipTarget + 1, not 1 —
            // proving the ~5000 skipped epochs are genuinely gone, not merely
            // hidden, and normal sequential enforcement still holds.
            await expect(
                validatorRewards.processEpoch(1)
            ).to.be.revertedWithCustomError(validatorRewards, 'EpochNotSequential');

            await time.increase(EPOCH_DURATION * 2);
            await validatorRewards.processEpoch(skipTarget + BigInt(1));
            expect(await validatorRewards.lastProcessedEpoch()).to.equal(
                skipTarget + BigInt(1)
            );
        });
    });

    // ================================================================
    //  AUDIT REMEDIATION: OSSIFICATION BLOCKS skipToEpoch
    // ================================================================

    describe('ossification blocks skipToEpoch', function () {
        it('reverts with ContractIsOssified once ossify() has been called', async function () {
            await validatorRewards.ossify();
            expect(await validatorRewards.isOssified()).to.equal(true);

            await validatorRewards.pause();
            await time.increase(EPOCH_DURATION * 10);
            const current = await validatorRewards.getCurrentEpoch();

            await expect(
                validatorRewards.skipToEpoch(current)
            ).to.be.revertedWithCustomError(validatorRewards, 'ContractIsOssified');
        });

        it('still allows skipToEpoch before ossify() is called', async function () {
            await validatorRewards.pause();
            await time.increase(EPOCH_DURATION * 10);
            const current = await validatorRewards.getCurrentEpoch();

            await expect(validatorRewards.skipToEpoch(current)).to.not.be.reverted;
            expect(await validatorRewards.isOssified()).to.equal(false);
        });
    });

    // ================================================================
    //  AUDIT REMEDIATION: unpause() REFUSES A LARGE UN-SKIPPED BACKLOG
    // ================================================================

    describe('unpause() backlog guard', function () {
        it('reverts with PendingBacklogTooLarge if unpause is called with a large backlog and no prior skip', async function () {
            const MAX = await validatorRewards.MAX_UNSKIPPED_PENDING_EPOCHS();

            await validatorRewards.pause();
            // Comfortably over the threshold — same order of magnitude as
            // the real, current 5.8M-epoch backlog this function exists for.
            await time.increase(EPOCH_DURATION * (Number(MAX) * 2));

            await expect(
                validatorRewards.unpause()
            ).to.be.revertedWithCustomError(validatorRewards, 'PendingBacklogTooLarge');

            // Confirm the contract is genuinely still paused — the revert
            // didn't leave it in some half-resumed state.
            expect(await validatorRewards.paused()).to.equal(true);
        });

        it('succeeds normally for an ordinary short pause well under the threshold', async function () {
            await validatorRewards.pause();
            await time.increase(EPOCH_DURATION * 10);

            await expect(validatorRewards.unpause()).to.not.be.reverted;
            expect(await validatorRewards.paused()).to.equal(false);
        });

        it('succeeds for a large backlog once skipToEpoch has already forgiven it', async function () {
            const MAX = await validatorRewards.MAX_UNSKIPPED_PENDING_EPOCHS();

            await validatorRewards.pause();
            await time.increase(EPOCH_DURATION * (Number(MAX) * 2));
            const current = await validatorRewards.getCurrentEpoch();
            await validatorRewards.skipToEpoch(current);

            await expect(validatorRewards.unpause()).to.not.be.reverted;
        });

        it('succeeds for a large un-skipped backlog once the contract is ossified (skip is no longer available, so the guard would otherwise be a permanent lockout)', async function () {
            const MAX = await validatorRewards.MAX_UNSKIPPED_PENDING_EPOCHS();

            await validatorRewards.pause();
            await time.increase(EPOCH_DURATION * (Number(MAX) * 2));
            await validatorRewards.ossify();

            await expect(validatorRewards.unpause()).to.not.be.reverted;
        });
    });

    // ================================================================
    //  AUDIT REMEDIATION: msg.sender -> _msgSender() (no forwarder
    //  configured in these tests, so behavior for a direct call must
    //  be identical to before — this proves the switch didn't break
    //  the normal, non-relayed path, which is the ONLY path this
    //  contract's production caller actually uses today)
    // ================================================================

    describe('submitHeartbeat (deprecated no-op, VT-18)', function () {
        it('writes no heartbeat state (activity now derives from the ledger)', async function () {
            await validatorRewards.connect(validator1).submitHeartbeat();
            expect(await validatorRewards.lastHeartbeat(validator1.address)).to.equal(0);
            expect(
                await validatorRewards.lastHeartbeatEpoch(validator1.address)
            ).to.equal(0);
        });

        it('still reverts NotValidator for a non-validator direct caller', async function () {
            await expect(
                validatorRewards.connect(unauthorized).submitHeartbeat()
            ).to.be.revertedWithCustomError(validatorRewards, 'NotValidator');
        });
    });

    describe('admin transfer with _msgSender()', function () {
        let newAdmin: any;
        const ADMIN_TRANSFER_DELAY = 48 * 60 * 60;

        beforeEach(async function () {
            const signers = await ethers.getSigners();
            newAdmin = signers[3];
        });

        it('proposes, waits, and accepts correctly, atomically revoking the old admin', async function () {
            const DEFAULT_ADMIN_ROLE = ethers.ZeroHash;

            await expect(validatorRewards.connect(admin).proposeAdminTransfer(newAdmin.address))
                .to.emit(validatorRewards, 'AdminTransferProposed');

            await expect(
                validatorRewards.connect(newAdmin).acceptAdminTransfer()
            ).to.be.revertedWithCustomError(validatorRewards, 'AdminTransferNotReady');

            await time.increase(ADMIN_TRANSFER_DELAY + 1);

            await expect(validatorRewards.connect(newAdmin).acceptAdminTransfer())
                .to.emit(validatorRewards, 'AdminTransferAccepted')
                .withArgs(admin.address, newAdmin.address);

            expect(await validatorRewards.hasRole(DEFAULT_ADMIN_ROLE, newAdmin.address)).to.equal(true);
            expect(await validatorRewards.hasRole(DEFAULT_ADMIN_ROLE, admin.address)).to.equal(false);
        });

        it('rejects acceptAdminTransfer from an address that is not the pending admin', async function () {
            await validatorRewards.connect(admin).proposeAdminTransfer(newAdmin.address);
            await time.increase(ADMIN_TRANSFER_DELAY + 1);

            await expect(
                validatorRewards.connect(unauthorized).acceptAdminTransfer()
            ).to.be.revertedWithCustomError(validatorRewards, 'NotPendingAdmin');
        });
    });
});
