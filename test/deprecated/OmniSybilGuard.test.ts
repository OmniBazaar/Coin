/**
 * @file OmniSybilGuard.test.ts
 * @description Comprehensive tests for OmniSybilGuard contract
 *
 * Tests cover:
 * - Initialization and role setup
 * - Device fingerprint registration
 * - Device limit enforcement
 * - Sybil reporting with stake
 * - Challenge period enforcement
 * - Report resolution (valid/invalid)
 * - Reward pool management
 * - Account flagging/unflagging
 * - Access control
 */

/* eslint-disable @typescript-eslint/no-var-requires */
const { expect } = require('chai');
const { ethers, upgrades } = require('hardhat');
const { keccak256, toUtf8Bytes, ZeroAddress, solidityPacked } = require('ethers');
const { time, loadFixture } = require('@nomicfoundation/hardhat-network-helpers');

describe('OmniSybilGuard', function () {
    // Role constants
    const DEFAULT_ADMIN_ROLE = ethers.ZeroHash;
    const REPORTER_ROLE = keccak256(toUtf8Bytes('REPORTER_ROLE'));
    const JUDGE_ROLE = keccak256(toUtf8Bytes('JUDGE_ROLE'));

    // Constants from contract
    const REPORT_STAKE = ethers.parseEther('1000'); // 1000 XOM
    const REPORT_REWARD = ethers.parseEther('5000'); // 5000 XOM
    const CHALLENGE_PERIOD = 72 * 60 * 60; // 72 hours in seconds
    const MAX_USERS_PER_DEVICE = 2;

    /**
     * Generate device fingerprint hash
     */
    function fingerprintHash(fingerprint: string): string {
        return keccak256(toUtf8Bytes(fingerprint));
    }

    /**
     * Generate evidence hash (IPFS CID simulation)
     */
    function evidenceHash(evidence: string): string {
        return keccak256(toUtf8Bytes(evidence));
    }

    /**
     * Deploy fixture for test isolation
     */
    async function deployOmniSybilGuardFixture() {
        // Get signers
        const [owner, reporter, judge, user1, user2, user3, suspect, unauthorized] =
            await ethers.getSigners();

        // Deploy OmniSybilGuard as proxy
        const OmniSybilGuard = await ethers.getContractFactory('OmniSybilGuard');
        const sybilGuard = await upgrades.deployProxy(OmniSybilGuard, [], {
            initializer: 'initialize',
            kind: 'uups',
        });
        await sybilGuard.waitForDeployment();

        // Grant roles
        await sybilGuard.grantRole(REPORTER_ROLE, reporter.address);
        await sybilGuard.grantRole(JUDGE_ROLE, judge.address);

        // Fund reward pool with enough for stake refund (1000) + reward (5000) = 6000 ETH
        // Note: Contract constants are designed for XOM but we test with ETH
        await sybilGuard.fundRewardPool({ value: ethers.parseEther('7000') });

        return { sybilGuard, owner, reporter, judge, user1, user2, user3, suspect, unauthorized };
    }

    describe('Initialization', function () {
        it('should initialize with correct admin', async function () {
            const { sybilGuard, owner } = await loadFixture(deployOmniSybilGuardFixture);
            expect(await sybilGuard.hasRole(DEFAULT_ADMIN_ROLE, owner.address)).to.be.true;
        });

        it('should have correct constants', async function () {
            const { sybilGuard } = await loadFixture(deployOmniSybilGuardFixture);
            expect(await sybilGuard.REPORT_STAKE()).to.equal(REPORT_STAKE);
            expect(await sybilGuard.REPORT_REWARD()).to.equal(REPORT_REWARD);
            expect(await sybilGuard.CHALLENGE_PERIOD()).to.equal(CHALLENGE_PERIOD);
            expect(await sybilGuard.MAX_USERS_PER_DEVICE()).to.equal(MAX_USERS_PER_DEVICE);
        });

        it('should have funded reward pool', async function () {
            const { sybilGuard } = await loadFixture(deployOmniSybilGuardFixture);
            expect(await sybilGuard.rewardPool()).to.equal(ethers.parseEther('7000'));
        });
    });

    describe('Device Fingerprint Registration', function () {
        it('should register device for first user', async function () {
            const { sybilGuard, reporter, user1 } = await loadFixture(deployOmniSybilGuardFixture);
            const fingerprint = fingerprintHash('device-001');

            await expect(sybilGuard.connect(reporter).registerDevice(user1.address, fingerprint))
                .to.emit(sybilGuard, 'DeviceRegistered')
                .withArgs(fingerprint, user1.address);

            expect(await sybilGuard.getDeviceRegistrationCount(fingerprint)).to.equal(1);
        });

        it('should allow second user on same device', async function () {
            const { sybilGuard, reporter, user1, user2 } = await loadFixture(deployOmniSybilGuardFixture);
            const fingerprint = fingerprintHash('device-002');

            await sybilGuard.connect(reporter).registerDevice(user1.address, fingerprint);
            await sybilGuard.connect(reporter).registerDevice(user2.address, fingerprint);

            expect(await sybilGuard.getDeviceRegistrationCount(fingerprint)).to.equal(2);

            const users = await sybilGuard.getUsersForDevice(fingerprint);
            expect(users.length).to.equal(2);
            expect(users[0]).to.equal(user1.address);
            expect(users[1]).to.equal(user2.address);
        });

        it('should reject third user on same device', async function () {
            const { sybilGuard, reporter, user1, user2, user3 } = await loadFixture(deployOmniSybilGuardFixture);
            const fingerprint = fingerprintHash('device-003');

            await sybilGuard.connect(reporter).registerDevice(user1.address, fingerprint);
            await sybilGuard.connect(reporter).registerDevice(user2.address, fingerprint);

            await expect(
                sybilGuard.connect(reporter).registerDevice(user3.address, fingerprint)
            ).to.be.revertedWithCustomError(sybilGuard, 'DeviceLimitExceeded');
        });

        it('should reject flagged account registration', async function () {
            const { sybilGuard, reporter, judge, user1 } = await loadFixture(deployOmniSybilGuardFixture);
            // Flag the user first
            await sybilGuard.connect(judge).manualFlag(user1.address);

            const fingerprint = fingerprintHash('device-004');
            await expect(
                sybilGuard.connect(reporter).registerDevice(user1.address, fingerprint)
            ).to.be.revertedWithCustomError(sybilGuard, 'AccountIsFlagged');
        });

        it('should reject unauthorized caller', async function () {
            const { sybilGuard, unauthorized, user1 } = await loadFixture(deployOmniSybilGuardFixture);
            const fingerprint = fingerprintHash('device-005');
            await expect(
                sybilGuard.connect(unauthorized).registerDevice(user1.address, fingerprint)
            ).to.be.reverted;
        });
    });

    describe('Sybil Reporting', function () {
        it('should create report with sufficient stake', async function () {
            const { sybilGuard, user1, suspect } = await loadFixture(deployOmniSybilGuardFixture);
            const evidence = evidenceHash('ipfs://Qm...');

            const tx = await sybilGuard.connect(user1).reportSybil(suspect.address, evidence, {
                value: REPORT_STAKE,
            });

            const receipt = await tx.wait();
            const event = receipt.logs.find((log: any) => log.fragment?.name === 'SybilReported');

            expect(event).to.not.be.undefined;
            expect(await sybilGuard.totalReports()).to.equal(1);
        });

        it('should reject insufficient stake', async function () {
            const { sybilGuard, user1, suspect } = await loadFixture(deployOmniSybilGuardFixture);
            const evidence = evidenceHash('ipfs://Qm...');
            const insufficientStake = ethers.parseEther('500'); // Only 500 XOM

            await expect(
                sybilGuard.connect(user1).reportSybil(suspect.address, evidence, {
                    value: insufficientStake,
                })
            ).to.be.revertedWithCustomError(sybilGuard, 'InsufficientStake');
        });

        it('should reject self-report', async function () {
            const { sybilGuard, user1 } = await loadFixture(deployOmniSybilGuardFixture);
            const evidence = evidenceHash('ipfs://Qm...');

            await expect(
                sybilGuard.connect(user1).reportSybil(user1.address, evidence, {
                    value: REPORT_STAKE,
                })
            ).to.be.revertedWithCustomError(sybilGuard, 'CannotReportSelf');
        });

        it('should accept extra stake', async function () {
            const { sybilGuard, user1, suspect } = await loadFixture(deployOmniSybilGuardFixture);
            const evidence = evidenceHash('ipfs://Qm...');
            const extraStake = ethers.parseEther('2000'); // 2000 XOM

            await sybilGuard.connect(user1).reportSybil(suspect.address, evidence, {
                value: extraStake,
            });

            expect(await sybilGuard.totalReports()).to.equal(1);
        });
    });

    describe('Report Resolution', function () {
        /**
         * Helper to create a report and return the reportId
         */
        async function createReport(sybilGuard: any, user1: any, suspect: any) {
            const evidence = evidenceHash('ipfs://Qm-evidence');
            const tx = await sybilGuard.connect(user1).reportSybil(suspect.address, evidence, {
                value: REPORT_STAKE,
            });
            const receipt = await tx.wait();
            const event = receipt.logs.find((log: any) => log.fragment?.name === 'SybilReported');
            return event.args[0];
        }

        it('should reject resolution during challenge period', async function () {
            const { sybilGuard, judge, user1, suspect } = await loadFixture(deployOmniSybilGuardFixture);
            const reportId = await createReport(sybilGuard, user1, suspect);

            await expect(
                sybilGuard.connect(judge).resolveReport(reportId, true)
            ).to.be.revertedWithCustomError(sybilGuard, 'ChallengePeriodActive');
        });

        it('should resolve valid report after challenge period', async function () {
            const { sybilGuard, judge, user1, suspect } = await loadFixture(deployOmniSybilGuardFixture);
            const reportId = await createReport(sybilGuard, user1, suspect);

            // Advance time past challenge period
            await time.increase(CHALLENGE_PERIOD + 1);

            const reporterBalanceBefore = await ethers.provider.getBalance(user1.address);

            await sybilGuard.connect(judge).resolveReport(reportId, true);

            // Check account is flagged
            expect(await sybilGuard.isFlagged(suspect.address)).to.be.true;
            expect(await sybilGuard.confirmedSybilCases()).to.equal(1);

            // Check reporter received stake + reward
            const reporterBalanceAfter = await ethers.provider.getBalance(user1.address);
            const expectedPayout = REPORT_STAKE + REPORT_REWARD;
            expect(reporterBalanceAfter - reporterBalanceBefore).to.be.closeTo(
                expectedPayout,
                ethers.parseEther('0.01') // Allow for gas differences
            );
        });

        it('should resolve invalid report and slash reporter', async function () {
            const { sybilGuard, judge, user1, suspect } = await loadFixture(deployOmniSybilGuardFixture);
            const reportId = await createReport(sybilGuard, user1, suspect);

            await time.increase(CHALLENGE_PERIOD + 1);

            const suspectBalanceBefore = await ethers.provider.getBalance(suspect.address);

            await sybilGuard.connect(judge).resolveReport(reportId, false);

            // Check account is NOT flagged
            expect(await sybilGuard.isFlagged(suspect.address)).to.be.false;

            // Check suspect received stake as compensation
            const suspectBalanceAfter = await ethers.provider.getBalance(suspect.address);
            expect(suspectBalanceAfter - suspectBalanceBefore).to.equal(REPORT_STAKE);
        });

        it('should reject double resolution', async function () {
            const { sybilGuard, judge, user1, suspect } = await loadFixture(deployOmniSybilGuardFixture);
            const reportId = await createReport(sybilGuard, user1, suspect);

            await time.increase(CHALLENGE_PERIOD + 1);
            await sybilGuard.connect(judge).resolveReport(reportId, true);

            await expect(
                sybilGuard.connect(judge).resolveReport(reportId, true)
            ).to.be.revertedWithCustomError(sybilGuard, 'AlreadyResolved');
        });

        it('should reject unauthorized resolution', async function () {
            const { sybilGuard, judge, user1, suspect, unauthorized } = await loadFixture(deployOmniSybilGuardFixture);
            const reportId = await createReport(sybilGuard, user1, suspect);

            await time.increase(CHALLENGE_PERIOD + 1);

            await expect(sybilGuard.connect(unauthorized).resolveReport(reportId, true)).to.be.reverted;
        });
    });

    describe('Reward Pool Management', function () {
        it('should accept reward pool funding', async function () {
            const { sybilGuard } = await loadFixture(deployOmniSybilGuardFixture);
            // Use smaller amount to stay within test account limits
            const additionalFunds = ethers.parseEther('100');
            const initialPool = await sybilGuard.rewardPool();

            await sybilGuard.fundRewardPool({ value: additionalFunds });

            expect(await sybilGuard.rewardPool()).to.equal(initialPool + additionalFunds);
        });

        it('should reject zero funding', async function () {
            const { sybilGuard } = await loadFixture(deployOmniSybilGuardFixture);
            await expect(sybilGuard.fundRewardPool({ value: 0 })).to.be.revertedWithCustomError(
                sybilGuard,
                'MustSendFunds'
            );
        });

        it('should accept funding via receive function', async function () {
            const { sybilGuard, owner } = await loadFixture(deployOmniSybilGuardFixture);
            const initialPool = await sybilGuard.rewardPool();
            // Use smaller amount to stay within test account limits
            const funding = ethers.parseEther('50');

            // Send ETH directly to contract
            await owner.sendTransaction({
                to: await sybilGuard.getAddress(),
                value: funding,
            });

            expect(await sybilGuard.rewardPool()).to.equal(initialPool + funding);
        });
    });

    describe('Account Flagging', function () {
        it('should allow manual flag by judge', async function () {
            const { sybilGuard, judge, suspect } = await loadFixture(deployOmniSybilGuardFixture);
            await sybilGuard.connect(judge).manualFlag(suspect.address);

            expect(await sybilGuard.isFlagged(suspect.address)).to.be.true;
        });

        it('should allow unflag by admin', async function () {
            const { sybilGuard, owner, judge, suspect } = await loadFixture(deployOmniSybilGuardFixture);
            await sybilGuard.connect(judge).manualFlag(suspect.address);
            await sybilGuard.connect(owner).unflagAccount(suspect.address);

            expect(await sybilGuard.isFlagged(suspect.address)).to.be.false;
        });

        it('should reject manual flag by unauthorized', async function () {
            const { sybilGuard, unauthorized, suspect } = await loadFixture(deployOmniSybilGuardFixture);
            await expect(sybilGuard.connect(unauthorized).manualFlag(suspect.address)).to.be.reverted;
        });

        it('should reject unflag by non-admin', async function () {
            const { sybilGuard, judge, suspect } = await loadFixture(deployOmniSybilGuardFixture);
            await sybilGuard.connect(judge).manualFlag(suspect.address);
            await expect(sybilGuard.connect(judge).unflagAccount(suspect.address)).to.be.reverted;
        });
    });

    describe('View Functions', function () {
        it('should return correct challenge time remaining', async function () {
            const { sybilGuard, user1, suspect } = await loadFixture(deployOmniSybilGuardFixture);
            // Create a report
            const evidence = evidenceHash('ipfs://Qm-test');
            const tx = await sybilGuard.connect(user1).reportSybil(suspect.address, evidence, {
                value: REPORT_STAKE,
            });
            const receipt = await tx.wait();
            const event = receipt.logs.find((log: any) => log.fragment?.name === 'SybilReported');
            const reportId = event.args[0];

            // Check time remaining (should be close to CHALLENGE_PERIOD)
            const remaining = await sybilGuard.getChallengeTimeRemaining(reportId);
            expect(remaining).to.be.closeTo(BigInt(CHALLENGE_PERIOD), 10n);

            // Advance time
            await time.increase(CHALLENGE_PERIOD / 2);

            const remainingHalf = await sybilGuard.getChallengeTimeRemaining(reportId);
            expect(remainingHalf).to.be.closeTo(BigInt(CHALLENGE_PERIOD / 2), 10n);

            // Advance past challenge period
            await time.increase(CHALLENGE_PERIOD);

            const remainingAfter = await sybilGuard.getChallengeTimeRemaining(reportId);
            expect(remainingAfter).to.equal(0);
        });

        it('should correctly identify resolvable reports', async function () {
            const { sybilGuard, user1, suspect } = await loadFixture(deployOmniSybilGuardFixture);
            const evidence = evidenceHash('ipfs://Qm-resolve-test');
            const tx = await sybilGuard.connect(user1).reportSybil(suspect.address, evidence, {
                value: REPORT_STAKE,
            });
            const receipt = await tx.wait();
            const event = receipt.logs.find((log: any) => log.fragment?.name === 'SybilReported');
            const reportId = event.args[0];

            // Not resolvable during challenge period
            expect(await sybilGuard.canResolveReport(reportId)).to.be.false;

            // Resolvable after challenge period
            await time.increase(CHALLENGE_PERIOD + 1);
            expect(await sybilGuard.canResolveReport(reportId)).to.be.true;
        });
    });
});
