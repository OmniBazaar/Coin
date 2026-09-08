/**
 * @file AttestationFraudHandler.test.ts
 * @description Tests for the AttestationFraudHandler (VT-09).
 *
 * Covers:
 * - Tier-1 equivocation: full slash, bounty to reporter, escrow of remainder
 * - Tier-2 outcome-overturned: pending 50% slash, challenge window, finalize
 * - Access control (reportEquivocation is permissionless; governanceReverse is
 *   admin-only)
 * - Post-slash lock: burnEscrow reverts before ESCROW_LOCK, succeeds after
 * - Dedup: the same evidence cannot be slashed twice
 */

/* eslint-disable @typescript-eslint/no-var-requires */
const { expect } = require('chai');
const { ethers } = require('hardhat');
const { time } = require('@nomicfoundation/hardhat-network-helpers');

describe('AttestationFraudHandler', function () {
    let handler: any;
    let omniCore: any;
    let verifier: any;
    let xom: any;

    let admin: any;
    let reporter: any;
    let target: any;
    let other: any;

    const STAKE = ethers.parseEther('1000000');

    beforeEach(async function () {
        [admin, reporter, target, other] = await ethers.getSigners();

        const MockXOMToken = await ethers.getContractFactory('MockXOMToken');
        xom = await MockXOMToken.deploy();
        await xom.waitForDeployment();

        const MockOmniCoreSlash = await ethers.getContractFactory('MockOmniCoreSlash');
        omniCore = await MockOmniCoreSlash.deploy(await xom.getAddress());
        await omniCore.waitForDeployment();

        const MockBridgeVerifier = await ethers.getContractFactory('MockBridgeVerifier');
        verifier = await MockBridgeVerifier.deploy();
        await verifier.waitForDeployment();

        const AttestationFraudHandler = await ethers.getContractFactory('AttestationFraudHandler');
        handler = await AttestationFraudHandler.deploy(
            admin.address,
            await omniCore.getAddress(),
            await verifier.getAddress(),
        );
        await handler.waitForDeployment();

        // Fund the OmniCore mock so slash can transfer XOM to the handler.
        await xom.mint(await omniCore.getAddress(), STAKE);

        // Target holds a stake.
        await omniCore.setStake(target.address, STAKE, true);
    });

    async function configureVerifier(attesters: string[]): Promise<void> {
        await verifier.setVerify(true, attesters);
    }

    describe('Tier 1: reportEquivocation', function () {
        it('slashes the target, pays the reporter a bounty, and escrows the rest', async function () {
            await configureVerifier([target.address]);

            const reporterBefore = await xom.balanceOf(reporter.address);

            await expect(
                handler.connect(reporter).reportEquivocation(
                    ethers.id('digestA'),
                    '0x1111111111111111111111111111111111111111111111111111111111111111aa',
                    ethers.id('digestB'),
                    '0x1111111111111111111111111111111111111111111111111111111111111111bb',
                    target.address,
                ),
            ).to.emit(handler, 'Slashed');

            // Full stake slashed → stake reduced to 0.
            const stake = await omniCore.getStake(target.address);
            expect(stake.amount).to.equal(0);

            // Reporter received the 5% bounty.
            expect(await xom.balanceOf(reporter.address)).to.equal(
                reporterBefore + (STAKE * 500n) / 10000n,
            );

            // Remainder escrowed in the handler.
            const escrow = await handler.escrows(0);
            expect(escrow.amount).to.equal(STAKE - (STAKE * 500n) / 10000n);
            expect(escrow.target).to.equal(target.address);
        });

        it('reverts when the target is not a common attester', async function () {
            await configureVerifier([other.address]);
            await expect(
                handler.reportEquivocation(
                    ethers.id('digestA'),
                    '0x1111111111111111111111111111111111111111111111111111111111111111aa',
                    ethers.id('digestB'),
                    '0x1111111111111111111111111111111111111111111111111111111111111111bb',
                    target.address,
                ),
            ).to.be.revertedWithCustomError(handler, 'NotCommonAttester');
        });

        it('reverts when the digests are identical', async function () {
            await configureVerifier([target.address]);
            await expect(
                handler.reportEquivocation(
                    ethers.id('digestA'),
                    '0x1111111111111111111111111111111111111111111111111111111111111111aa',
                    ethers.id('digestA'),
                    '0x1111111111111111111111111111111111111111111111111111111111111111bb',
                    target.address,
                ),
            ).to.be.revertedWithCustomError(handler, 'DigestsIdentical');
        });

        it('dedups the same evidence', async function () {
            await configureVerifier([target.address]);
            await handler.reportEquivocation(
                ethers.id('digestA'), '0x1111111111111111111111111111111111111111111111111111111111111111aa', ethers.id('digestB'), '0x1111111111111111111111111111111111111111111111111111111111111111bb', target.address,
            );
            await expect(
                handler.reportEquivocation(
                    ethers.id('digestA'), '0x1111111111111111111111111111111111111111111111111111111111111111aa', ethers.id('digestB'), '0x1111111111111111111111111111111111111111111111111111111111111111bb', target.address,
                ),
            ).to.be.revertedWithCustomError(handler, 'EvidenceAlreadySlashed');
        });
    });

    describe('Tier 2: reportOutcomeOverturned', function () {
        it('records a pending 50% slash that finalizes after the challenge window', async function () {
            await configureVerifier([target.address]);

            await expect(
                handler.reportOutcomeOverturned(
                    ethers.id('digestA'), '0x1111111111111111111111111111111111111111111111111111111111111111aa', ethers.id('digestB'), '0x1111111111111111111111111111111111111111111111111111111111111111bb', target.address,
                ),
            )
                .to.emit(handler, 'OutcomeOverturnReported')
                .withArgs(target.address, 0, STAKE / 2n, (await time.latest()) + 24 * 60 * 60);

            // Before the window, finalize reverts.
            await expect(
                handler.finalizeSlash(0),
            ).to.be.revertedWithCustomError(handler, 'NotFinalizable');

            await time.increase(24 * 60 * 60 + 1);
            await handler.finalizeSlash(0);

            // 50% slashed.
            const stake = await omniCore.getStake(target.address);
            expect(stake.amount).to.equal(STAKE / 2n);
        });

        it('lets the target challenge within the window', async function () {
            await configureVerifier([target.address]);
            await handler.reportOutcomeOverturned(
                ethers.id('digestA'), '0x1111111111111111111111111111111111111111111111111111111111111111aa', ethers.id('digestB'), '0x1111111111111111111111111111111111111111111111111111111111111111bb', target.address,
            );

            await expect(handler.connect(target).challengeSlash(0))
                .to.emit(handler, 'SlashChallenged')
                .withArgs(0, target.address);

            // A challenged slash can no longer finalize.
            await time.increase(24 * 60 * 60 + 1);
            await expect(
                handler.finalizeSlash(0),
            ).to.be.revertedWithCustomError(handler, 'NotFinalizable');
        });
    });

    describe('post-slash lock', function () {
        beforeEach(async function () {
            await configureVerifier([target.address]);
            await handler.reportEquivocation(
                ethers.id('digestA'), '0x1111111111111111111111111111111111111111111111111111111111111111aa', ethers.id('digestB'), '0x1111111111111111111111111111111111111111111111111111111111111111bb', target.address,
            );
        });

        it('reverts burnEscrow before ESCROW_LOCK elapses', async function () {
            await expect(
                handler.burnEscrow(0),
            ).to.be.revertedWithCustomError(handler, 'EscrowLocked');
        });

        it('burns after ESCROW_LOCK elapses', async function () {
            const burnBefore = await xom.balanceOf(handler.BURN_ADDRESS());
            await time.increase(14 * 24 * 60 * 60 + 1);
            await expect(handler.burnEscrow(0))
                .to.emit(handler, 'EscrowBurned');
            const escrow = await handler.escrows(0);
            expect(await xom.balanceOf(handler.BURN_ADDRESS())).to.equal(
                burnBefore + escrow.amount,
            );
        });

        it('lets governance reverse the escrow before burn', async function () {
            const targetBefore = await xom.balanceOf(target.address);
            await expect(handler.governanceReverse(0))
                .to.emit(handler, 'EscrowReversed');
            const escrow = await handler.escrows(0);
            expect(await xom.balanceOf(target.address)).to.equal(
                targetBefore + escrow.amount,
            );
        });

        it('restricts governanceReverse to DEFAULT_ADMIN_ROLE', async function () {
            await expect(
                handler.connect(other).governanceReverse(0),
            ).to.be.reverted;
        });
    });
});
