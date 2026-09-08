/**
 * @file ValidatorActivityLedger.test.ts
 * @description Tests for the ValidatorActivityLedger contract (VT-18).
 *
 * Covers:
 * - Construction grants DEFAULT_ADMIN_ROLE + RECORDER_ROLE to the deployer
 * - recordEpochActivity is RECORDER_ROLE-gated
 * - Idempotency: recording the same (epoch, validator) twice counts once
 * - Monotonicity: an older epoch is never written over a newer one
 * - Zero-address entries are skipped
 * - lastAttestationEpoch / attestationCount update and ActivityRecorded fires
 */

/* eslint-disable @typescript-eslint/no-var-requires */
const { expect } = require('chai');
const { ethers } = require('hardhat');

describe('ValidatorActivityLedger', function () {
    let ledger: any;
    let admin: any;
    let recorder: any;
    let unauthorized: any;
    let validatorA: any;
    let validatorB: any;

    const DEFAULT_ADMIN_ROLE = ethers.ZeroHash;

    beforeEach(async function () {
        [admin, recorder, unauthorized, validatorA, validatorB] =
            await ethers.getSigners();

        const ValidatorActivityLedger = await ethers.getContractFactory(
            'ValidatorActivityLedger',
        );
        ledger = await ValidatorActivityLedger.deploy(admin.address);
        await ledger.waitForDeployment();
    });

    describe('construction', function () {
        it('grants DEFAULT_ADMIN_ROLE and RECORDER_ROLE to the deployer admin', async function () {
            const RECORDER_ROLE = await ledger.RECORDER_ROLE();
            expect(await ledger.hasRole(DEFAULT_ADMIN_ROLE, admin.address)).to.be.true;
            expect(await ledger.hasRole(RECORDER_ROLE, admin.address)).to.be.true;
        });

        it('rejects a zero admin', async function () {
            const ValidatorActivityLedger = await ethers.getContractFactory(
                'ValidatorActivityLedger',
            );
            await expect(
                ValidatorActivityLedger.deploy(ethers.ZeroAddress),
            ).to.be.revertedWithCustomError(ledger, 'ZeroAddress');
        });
    });

    describe('access control', function () {
        it('allows an authorized recorder to record activity', async function () {
            const RECORDER_ROLE = await ledger.RECORDER_ROLE();
            await ledger.grantRole(RECORDER_ROLE, recorder.address);

            await expect(
                ledger
                    .connect(recorder)
                    .recordEpochActivity(5, [validatorA.address]),
            ).to.not.be.reverted;
        });

        it('reverts for a non-recorder', async function () {
            await expect(
                ledger
                    .connect(unauthorized)
                    .recordEpochActivity(5, [validatorA.address]),
            ).to.be.reverted;
        });
    });

    describe('recording', function () {
        it('records lastAttestationEpoch and attestationCount', async function () {
            await ledger.recordEpochActivity(7, [validatorA.address]);

            expect(
                await ledger.lastAttestationEpoch(validatorA.address),
            ).to.equal(7);
            expect(
                await ledger.attestationCount(validatorA.address),
            ).to.equal(1);
        });

        it('emits ActivityRecorded with the updated count', async function () {
            await expect(
                ledger.recordEpochActivity(7, [validatorA.address]),
            )
                .to.emit(ledger, 'ActivityRecorded')
                .withArgs(validatorA.address, 7, 1);
        });

        it('is idempotent per (epoch, validator)', async function () {
            await ledger.recordEpochActivity(7, [validatorA.address]);
            await ledger.recordEpochActivity(7, [validatorA.address]);

            expect(
                await ledger.attestationCount(validatorA.address),
            ).to.equal(1);
            expect(
                await ledger.lastAttestationEpoch(validatorA.address),
            ).to.equal(7);
        });

        it('is monotonic — an older epoch is not written over a newer one', async function () {
            await ledger.recordEpochActivity(7, [validatorA.address]);
            await ledger.recordEpochActivity(3, [validatorA.address]);

            expect(
                await ledger.lastAttestationEpoch(validatorA.address),
            ).to.equal(7);
            expect(
                await ledger.attestationCount(validatorA.address),
            ).to.equal(1);
        });

        it('skips zero-address entries', async function () {
            await ledger.recordEpochActivity(7, [ethers.ZeroAddress]);

            expect(
                await ledger.lastAttestationEpoch(ethers.ZeroAddress),
            ).to.equal(0);
            expect(
                await ledger.attestationCount(ethers.ZeroAddress),
            ).to.equal(0);
        });

        it('records multiple validators in one call', async function () {
            await ledger.recordEpochActivity(7, [
                validatorA.address,
                validatorB.address,
            ]);

            expect(
                await ledger.attestationCount(validatorA.address),
            ).to.equal(1);
            expect(
                await ledger.attestationCount(validatorB.address),
            ).to.equal(1);
        });

        it('rejects a far-future epoch (bounded clock, audit VT-18 F1)', async function () {
            await expect(
                ledger.recordEpochActivity(
                    BigInt(2) ** BigInt(200),
                    [validatorA.address],
                ),
            ).to.be.revertedWithCustomError(
                ledger,
                'EpochTooFarInFuture',
            );
        });
    });
});
