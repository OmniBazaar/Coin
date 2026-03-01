/**
 * @file OmniParticipation.test.ts
 * @description Comprehensive tests for OmniParticipation contract
 *
 * Tests cover:
 * - Initialization and role setup
 * - Marketplace reviews (submit, verify, reputation calculation)
 * - Service node heartbeats
 * - Transaction claims and verification
 * - Community policing reports
 * - Forum contributions
 * - Validator reliability tracking
 * - Score calculation and qualification checks
 */

/* eslint-disable @typescript-eslint/no-var-requires */
const { expect } = require('chai');
const { ethers, upgrades } = require('hardhat');
const { keccak256, toUtf8Bytes, ZeroAddress } = require('ethers');
const { time } = require('@nomicfoundation/hardhat-network-helpers');

describe('OmniParticipation', function () {
    // Contract instances
    let participation: any;
    let mockRegistration: any;
    let mockOmniCore: any;

    // Signers
    let owner: any;
    let verifier: any;
    let user1: any;
    let user2: any;
    let user3: any;
    let validator1: any;
    let validator2: any;
    let unauthorized: any;

    // Role constants
    const DEFAULT_ADMIN_ROLE = ethers.ZeroHash;
    const VERIFIER_ROLE = keccak256(toUtf8Bytes('VERIFIER_ROLE'));

    // Constants from contract
    const MIN_VALIDATOR_SCORE = 50;
    const MIN_LISTING_NODE_SCORE = 25;
    const SERVICE_NODE_TIMEOUT = 300;
    const VALIDATOR_TIMEOUT = 30;

    /**
     * Generate a unique transaction hash for testing
     */
    function generateTxHash(): string {
        return keccak256(toUtf8Bytes(`tx-${Date.now()}-${Math.random()}`));
    }

    /**
     * Generate a unique content hash for testing
     */
    function generateContentHash(): string {
        return keccak256(toUtf8Bytes(`content-${Date.now()}-${Math.random()}`));
    }

    beforeEach(async function () {
        // Get signers
        [owner, verifier, user1, user2, user3, validator1, validator2, unauthorized] =
            await ethers.getSigners();

        // Deploy mock OmniRegistration
        const MockRegistration = await ethers.getContractFactory('MockOmniRegistration');
        mockRegistration = await MockRegistration.deploy();
        await mockRegistration.waitForDeployment();

        // Deploy mock OmniCore
        const MockOmniCore = await ethers.getContractFactory('MockOmniCore');
        mockOmniCore = await MockOmniCore.deploy();
        await mockOmniCore.waitForDeployment();

        // Deploy OmniParticipation as proxy
        const OmniParticipation = await ethers.getContractFactory('OmniParticipation');
        participation = await upgrades.deployProxy(
            OmniParticipation,
            [await mockRegistration.getAddress(), await mockOmniCore.getAddress()],
            {
                initializer: 'initialize',
                kind: 'uups',
            }
        );
        await participation.waitForDeployment();

        // Grant verifier role
        await participation.grantRole(VERIFIER_ROLE, verifier.address);

        // Setup mock registration - register users
        await mockRegistration.setRegistered(user1.address, true);
        await mockRegistration.setRegistered(user2.address, true);
        await mockRegistration.setRegistered(user3.address, true);
        await mockRegistration.setRegistered(validator1.address, true);
        await mockRegistration.setRegistered(validator2.address, true);

        // Setup mock OmniCore - set validators
        await mockOmniCore.setValidator(validator1.address, true);
        await mockOmniCore.setValidator(validator2.address, true);
    });

    describe('Initialization', function () {
        it('should initialize with correct admin', async function () {
            expect(await participation.hasRole(DEFAULT_ADMIN_ROLE, owner.address)).to.be.true;
        });

        it('should initialize with correct verifier', async function () {
            expect(await participation.hasRole(VERIFIER_ROLE, owner.address)).to.be.true;
        });

        it('should set correct contract references', async function () {
            expect(await participation.registration()).to.equal(await mockRegistration.getAddress());
            expect(await participation.omniCore()).to.equal(await mockOmniCore.getAddress());
        });

        it('should have correct constants', async function () {
            expect(await participation.MIN_VALIDATOR_SCORE()).to.equal(MIN_VALIDATOR_SCORE);
            expect(await participation.MIN_LISTING_NODE_SCORE()).to.equal(MIN_LISTING_NODE_SCORE);
            expect(await participation.SERVICE_NODE_TIMEOUT()).to.equal(SERVICE_NODE_TIMEOUT);
            expect(await participation.VALIDATOR_TIMEOUT()).to.equal(VALIDATOR_TIMEOUT);
        });

        it('should reject zero address for registration', async function () {
            const OmniParticipation = await ethers.getContractFactory('OmniParticipation');
            await expect(
                upgrades.deployProxy(
                    OmniParticipation,
                    [ZeroAddress, await mockOmniCore.getAddress()],
                    { initializer: 'initialize', kind: 'uups' }
                )
            ).to.be.revertedWithCustomError(OmniParticipation, 'ZeroAddress');
        });

        it('should reject zero address for omniCore', async function () {
            const OmniParticipation = await ethers.getContractFactory('OmniParticipation');
            await expect(
                upgrades.deployProxy(
                    OmniParticipation,
                    [await mockRegistration.getAddress(), ZeroAddress],
                    { initializer: 'initialize', kind: 'uups' }
                )
            ).to.be.revertedWithCustomError(OmniParticipation, 'ZeroAddress');
        });
    });

    describe('Marketplace Reviews', function () {
        describe('submitReview', function () {
            it('should submit review with valid data', async function () {
                const txHash = generateTxHash();

                const tx = await participation.connect(user1).submitReview(
                    user2.address,
                    5, // 5 stars
                    txHash
                );

                await expect(tx)
                    .to.emit(participation, 'ReviewSubmitted')
                    .withArgs(user1.address, user2.address, 5, txHash);

                expect(await participation.getReviewHistoryLength(user2.address)).to.equal(1);
            });

            it('should reject invalid star rating (0)', async function () {
                await expect(
                    participation.connect(user1).submitReview(user2.address, 0, generateTxHash())
                ).to.be.revertedWithCustomError(participation, 'InvalidStars');
            });

            it('should reject invalid star rating (6)', async function () {
                await expect(
                    participation.connect(user1).submitReview(user2.address, 6, generateTxHash())
                ).to.be.revertedWithCustomError(participation, 'InvalidStars');
            });

            it('should reject duplicate transaction hash', async function () {
                const txHash = generateTxHash();

                await participation.connect(user1).submitReview(user2.address, 5, txHash);

                await expect(
                    participation.connect(user1).submitReview(user3.address, 4, txHash)
                ).to.be.revertedWithCustomError(participation, 'TransactionAlreadyUsed');
            });

            it('should reject unregistered reviewer', async function () {
                await expect(
                    participation.connect(unauthorized).submitReview(user2.address, 5, generateTxHash())
                ).to.be.revertedWithCustomError(participation, 'NotRegistered');
            });

            it('should reject review of unregistered user', async function () {
                await expect(
                    participation.connect(user1).submitReview(unauthorized.address, 5, generateTxHash())
                ).to.be.revertedWithCustomError(participation, 'NotRegistered');
            });
        });

        describe('verifyReview', function () {
            beforeEach(async function () {
                // Submit a review first
                await participation.connect(user1).submitReview(user2.address, 5, generateTxHash());
            });

            it('should verify review', async function () {
                const tx = await participation.connect(verifier).verifyReview(user2.address, 0);

                await expect(tx)
                    .to.emit(participation, 'ReviewVerified')
                    .withArgs(user2.address, 0);
            });

            it('should update reputation after verification', async function () {
                // Verify the 5-star review
                await participation.connect(verifier).verifyReview(user2.address, 0);

                // Check reputation updated
                const comp = await participation.components(user2.address);
                expect(comp.marketplaceReputation).to.equal(10); // 5 stars = +10
            });

            it('should reject invalid review index', async function () {
                await expect(
                    participation.connect(verifier).verifyReview(user2.address, 99)
                ).to.be.revertedWithCustomError(participation, 'InvalidReviewIndex');
            });

            it('should reject already verified review', async function () {
                await participation.connect(verifier).verifyReview(user2.address, 0);

                await expect(
                    participation.connect(verifier).verifyReview(user2.address, 0)
                ).to.be.revertedWithCustomError(participation, 'AlreadyVerified');
            });

            it('should reject unauthorized verifier', async function () {
                await expect(
                    participation.connect(unauthorized).verifyReview(user2.address, 0)
                ).to.be.reverted;
            });
        });

        describe('Reputation Calculation', function () {
            it('should calculate correct reputation for 1-star average', async function () {
                await participation.connect(user1).submitReview(user2.address, 1, generateTxHash());
                await participation.connect(verifier).verifyReview(user2.address, 0);

                const comp = await participation.components(user2.address);
                expect(comp.marketplaceReputation).to.equal(-10);
            });

            it('should calculate correct reputation for 2-star average', async function () {
                await participation.connect(user1).submitReview(user2.address, 2, generateTxHash());
                await participation.connect(verifier).verifyReview(user2.address, 0);

                const comp = await participation.components(user2.address);
                expect(comp.marketplaceReputation).to.equal(-5);
            });

            it('should calculate correct reputation for 3-star average', async function () {
                await participation.connect(user1).submitReview(user2.address, 3, generateTxHash());
                await participation.connect(verifier).verifyReview(user2.address, 0);

                const comp = await participation.components(user2.address);
                expect(comp.marketplaceReputation).to.equal(0);
            });

            it('should calculate correct reputation for 4-star average', async function () {
                await participation.connect(user1).submitReview(user2.address, 4, generateTxHash());
                await participation.connect(verifier).verifyReview(user2.address, 0);

                const comp = await participation.components(user2.address);
                expect(comp.marketplaceReputation).to.equal(5);
            });

            it('should calculate correct reputation for 5-star average', async function () {
                await participation.connect(user1).submitReview(user2.address, 5, generateTxHash());
                await participation.connect(verifier).verifyReview(user2.address, 0);

                const comp = await participation.components(user2.address);
                expect(comp.marketplaceReputation).to.equal(10);
            });

            it('should only count verified reviews in average', async function () {
                // Submit two reviews but only verify one
                await participation.connect(user1).submitReview(user2.address, 5, generateTxHash());
                await participation.connect(user3).submitReview(user2.address, 1, generateTxHash());

                // Only verify the 5-star review
                await participation.connect(verifier).verifyReview(user2.address, 0);

                const comp = await participation.components(user2.address);
                expect(comp.marketplaceReputation).to.equal(10); // Only 5-star counted
            });
        });
    });

    describe('Service Node Heartbeat', function () {
        it('should submit heartbeat', async function () {
            // ATK-M22: Only validators can submit service node heartbeats
            const tx = await participation.connect(validator1).submitServiceNodeHeartbeat();

            await expect(tx).to.emit(participation, 'ServiceNodeHeartbeat');
        });

        it('should update publisher activity to 4', async function () {
            // M-02: Graduated scoring requires >= 100,000 listings for 4 points
            // ATK-H04: Must increment in steps of MAX_LISTING_COUNT_DELTA (1000)
            // ATK-H04: Daily limit is 50 verifier changes, so we need multiple days
            // Day 1: set count from 0 -> 50,000 (50 increments of 1000)
            for (let i = 1; i <= 50; i++) {
                await participation.connect(verifier).setPublisherListingCount(validator1.address, i * 1000);
            }
            // Advance to next day to reset daily limit
            await time.increase(86401);
            // Day 2: set count from 50,000 -> 100,000 (50 increments of 1000)
            for (let i = 51; i <= 100; i++) {
                await participation.connect(verifier).setPublisherListingCount(validator1.address, i * 1000);
            }
            await participation.connect(validator1).submitServiceNodeHeartbeat();

            const comp = await participation.components(validator1.address);
            expect(comp.publisherActivity).to.equal(4);
        });

        it('should mark service node as operational', async function () {
            // ATK-M22: Only validators can submit service node heartbeats
            await participation.connect(validator1).submitServiceNodeHeartbeat();

            expect(await participation.isServiceNodeOperational(validator1.address)).to.be.true;
        });

        it('should become non-operational after timeout', async function () {
            // ATK-M22: Only validators can submit service node heartbeats
            await participation.connect(validator1).submitServiceNodeHeartbeat();

            // Advance time past timeout (300 seconds + 1)
            await time.increase(301);

            expect(await participation.isServiceNodeOperational(validator1.address)).to.be.false;
        });

        it('should reject unregistered user', async function () {
            await expect(
                participation.connect(unauthorized).submitServiceNodeHeartbeat()
            ).to.be.revertedWithCustomError(participation, 'NotRegistered');
        });

        it('should reject non-validator registered user (ATK-M22)', async function () {
            // user1 is registered but not a validator
            await expect(
                participation.connect(user1).submitServiceNodeHeartbeat()
            ).to.be.revertedWithCustomError(participation, 'NotServiceNode');
        });

        it('should update publisher activity based on operational status', async function () {
            // ATK-M22: Only validators can submit service node heartbeats
            await participation.connect(validator1).submitServiceNodeHeartbeat();

            // Wait for timeout
            await time.increase(301);

            // Update publisher activity
            await participation.updatePublisherActivity(validator1.address);

            const comp = await participation.components(validator1.address);
            expect(comp.publisherActivity).to.equal(0);
        });
    });

    describe('Transaction Claims', function () {
        describe('claimMarketplaceTransactions', function () {
            it('should claim transactions', async function () {
                const hashes = [generateTxHash(), generateTxHash()];

                const tx = await participation.connect(user1).claimMarketplaceTransactions(hashes);

                await expect(tx)
                    .to.emit(participation, 'TransactionsClaimed')
                    .withArgs(user1.address, 2);

                expect(await participation.getTransactionClaimsLength(user1.address)).to.equal(2);
            });

            it('should reject duplicate transaction hash', async function () {
                const hash = generateTxHash();

                await participation.connect(user1).claimMarketplaceTransactions([hash]);

                await expect(
                    participation.connect(user1).claimMarketplaceTransactions([hash])
                ).to.be.revertedWithCustomError(participation, 'TransactionAlreadyUsed');
            });

            it('should reject unregistered user', async function () {
                await expect(
                    participation.connect(unauthorized).claimMarketplaceTransactions([generateTxHash()])
                ).to.be.revertedWithCustomError(participation, 'NotRegistered');
            });
        });

        describe('verifyTransactionClaim', function () {
            beforeEach(async function () {
                await participation.connect(user1).claimMarketplaceTransactions([generateTxHash()]);
            });

            it('should verify transaction claim', async function () {
                const tx = await participation.connect(verifier).verifyTransactionClaim(user1.address, 0);

                await expect(tx)
                    .to.emit(participation, 'TransactionClaimVerified')
                    .withArgs(user1.address, 0);
            });

            it('should reject invalid claim index', async function () {
                await expect(
                    participation.connect(verifier).verifyTransactionClaim(user1.address, 99)
                ).to.be.revertedWithCustomError(participation, 'InvalidClaimIndex');
            });

            it('should reject already verified claim', async function () {
                await participation.connect(verifier).verifyTransactionClaim(user1.address, 0);

                await expect(
                    participation.connect(verifier).verifyTransactionClaim(user1.address, 0)
                ).to.be.revertedWithCustomError(participation, 'AlreadyVerified');
            });
        });

        describe('Marketplace Activity Scoring', function () {
            it('should give 0 points for less than 5 verified transactions', async function () {
                // Claim and verify 4 transactions
                for (let i = 0; i < 4; i++) {
                    await participation.connect(user1).claimMarketplaceTransactions([generateTxHash()]);
                    await participation.connect(verifier).verifyTransactionClaim(user1.address, i);
                }

                const comp = await participation.components(user1.address);
                expect(comp.marketplaceActivity).to.equal(0);
            });

            it('should give 1 point for 5+ verified transactions', async function () {
                for (let i = 0; i < 5; i++) {
                    await participation.connect(user1).claimMarketplaceTransactions([generateTxHash()]);
                    await participation.connect(verifier).verifyTransactionClaim(user1.address, i);
                }

                const comp = await participation.components(user1.address);
                expect(comp.marketplaceActivity).to.equal(1);
            });

            it('should give 2 points for 10+ verified transactions', async function () {
                for (let i = 0; i < 10; i++) {
                    await participation.connect(user1).claimMarketplaceTransactions([generateTxHash()]);
                    await participation.connect(verifier).verifyTransactionClaim(user1.address, i);
                }

                const comp = await participation.components(user1.address);
                expect(comp.marketplaceActivity).to.equal(2);
            });
        });
    });

    describe('Community Policing Reports', function () {
        describe('submitReport', function () {
            it('should submit report', async function () {
                const listingHash = generateContentHash();
                const reason = 'This is an illegal listing that violates our terms';

                const tx = await participation.connect(user1).submitReport(listingHash, reason);

                await expect(tx)
                    .to.emit(participation, 'ReportSubmitted')
                    .withArgs(user1.address, listingHash, reason);

                expect(await participation.getReportHistoryLength(user1.address)).to.equal(1);
            });

            it('should reject reason that is too short', async function () {
                await expect(
                    participation.connect(user1).submitReport(generateContentHash(), 'Short')
                ).to.be.revertedWithCustomError(participation, 'ReasonTooShort');
            });

            it('should reject unregistered user', async function () {
                await expect(
                    participation.connect(unauthorized).submitReport(generateContentHash(), 'This is a valid reason')
                ).to.be.revertedWithCustomError(participation, 'NotRegistered');
            });
        });

        describe('validateReport', function () {
            beforeEach(async function () {
                await participation.connect(user1).submitReport(
                    generateContentHash(),
                    'This is an illegal listing that violates our terms'
                );
            });

            it('should validate report as valid', async function () {
                const tx = await participation.connect(verifier).validateReport(user1.address, 0, true);

                await expect(tx)
                    .to.emit(participation, 'ReportValidated')
                    .withArgs(user1.address, 0, true);
            });

            it('should validate report as invalid', async function () {
                await participation.connect(verifier).validateReport(user1.address, 0, false);

                // Valid count should be 0
                const comp = await participation.components(user1.address);
                expect(comp.communityPolicing).to.equal(0);
            });

            it('should update community policing score for valid reports', async function () {
                await participation.connect(verifier).validateReport(user1.address, 0, true);

                const comp = await participation.components(user1.address);
                expect(comp.communityPolicing).to.equal(1);
            });

            it('should reject invalid report index', async function () {
                await expect(
                    participation.connect(verifier).validateReport(user1.address, 99, true)
                ).to.be.revertedWithCustomError(participation, 'InvalidReportIndex');
            });

            it('should reject already validated report', async function () {
                await participation.connect(verifier).validateReport(user1.address, 0, true);

                await expect(
                    participation.connect(verifier).validateReport(user1.address, 0, false)
                ).to.be.revertedWithCustomError(participation, 'AlreadyValidated');
            });
        });
    });

    describe('Forum Contributions', function () {
        describe('claimForumContribution', function () {
            it('should claim thread contribution', async function () {
                const contentHash = generateContentHash();

                const tx = await participation.connect(user1).claimForumContribution('thread', contentHash);

                await expect(tx)
                    .to.emit(participation, 'ForumContributionClaimed')
                    .withArgs(user1.address, 'thread', contentHash);
            });

            it('should claim reply contribution', async function () {
                await participation.connect(user1).claimForumContribution('reply', generateContentHash());
                expect(await participation.getForumContributionsLength(user1.address)).to.equal(1);
            });

            it('should claim documentation contribution', async function () {
                await participation.connect(user1).claimForumContribution('documentation', generateContentHash());
                expect(await participation.getForumContributionsLength(user1.address)).to.equal(1);
            });

            it('should claim support contribution', async function () {
                await participation.connect(user1).claimForumContribution('support', generateContentHash());
                expect(await participation.getForumContributionsLength(user1.address)).to.equal(1);
            });

            it('should reject invalid contribution type', async function () {
                await expect(
                    participation.connect(user1).claimForumContribution('invalid', generateContentHash())
                ).to.be.revertedWithCustomError(participation, 'InvalidContributionType');
            });

            it('should reject unregistered user', async function () {
                await expect(
                    participation.connect(unauthorized).claimForumContribution('thread', generateContentHash())
                ).to.be.revertedWithCustomError(participation, 'NotRegistered');
            });
        });

        describe('verifyForumContribution', function () {
            beforeEach(async function () {
                await participation.connect(user1).claimForumContribution('thread', generateContentHash());
            });

            it('should verify contribution', async function () {
                const tx = await participation.connect(verifier).verifyForumContribution(user1.address, 0);

                await expect(tx)
                    .to.emit(participation, 'ForumContributionVerified')
                    .withArgs(user1.address, 0);
            });

            it('should update forum activity score', async function () {
                await participation.connect(verifier).verifyForumContribution(user1.address, 0);

                const comp = await participation.components(user1.address);
                expect(comp.forumActivity).to.equal(1);
            });

            it('should reject invalid contribution index', async function () {
                await expect(
                    participation.connect(verifier).verifyForumContribution(user1.address, 99)
                ).to.be.revertedWithCustomError(participation, 'InvalidContributionIndex');
            });

            it('should reject already verified contribution', async function () {
                await participation.connect(verifier).verifyForumContribution(user1.address, 0);

                await expect(
                    participation.connect(verifier).verifyForumContribution(user1.address, 0)
                ).to.be.revertedWithCustomError(participation, 'AlreadyVerified');
            });
        });
    });

    describe('Validator Reliability', function () {
        it('should submit validator heartbeat', async function () {
            const tx = await participation.connect(validator1).submitValidatorHeartbeat();

            await expect(tx).to.emit(participation, 'ValidatorHeartbeat');
        });

        it('should reject non-validator heartbeat', async function () {
            await expect(
                participation.connect(user1).submitValidatorHeartbeat()
            ).to.be.revertedWithCustomError(participation, 'NotValidator');
        });

        it('should track uptime blocks', async function () {
            // First heartbeat
            await participation.connect(validator1).submitValidatorHeartbeat();

            // Wait some time (within timeout)
            await time.increase(20);

            // Second heartbeat
            await participation.connect(validator1).submitValidatorHeartbeat();

            // Check that blocks are tracked
            const totalBlocks = await participation.totalBlocks(validator1.address);
            expect(totalBlocks).to.be.gt(0);
        });

        it('should update reliability based on uptime', async function () {
            // Multiple heartbeats within timeout should give good reliability
            await participation.connect(validator1).submitValidatorHeartbeat();
            await time.increase(15);
            await participation.connect(validator1).submitValidatorHeartbeat();
            await time.increase(15);
            await participation.connect(validator1).submitValidatorHeartbeat();

            const comp = await participation.components(validator1.address);
            // Should have positive reliability with good uptime
            expect(comp.reliability).to.be.gte(0);
        });
    });

    describe('Score Calculation', function () {
        describe('getScore', function () {
            it('should return zero score for unregistered user', async function () {
                const [totalScore] = await participation.getScore(unauthorized.address);
                expect(totalScore).to.equal(0);
            });

            it('should calculate score with KYC tier 1', async function () {
                await mockRegistration.setKycTier1(user1.address, true);

                const [totalScore, kycTrust] = await participation.getScore(user1.address);
                expect(kycTrust).to.equal(5);
                expect(totalScore).to.equal(5);
            });

            it('should calculate score with KYC tier 2', async function () {
                await mockRegistration.setKycTier2(user1.address, true);

                const [totalScore, kycTrust] = await participation.getScore(user1.address);
                expect(kycTrust).to.equal(10);
            });

            it('should calculate score with KYC tier 3', async function () {
                await mockRegistration.setKycTier3(user1.address, true);

                const [totalScore, kycTrust] = await participation.getScore(user1.address);
                // Per spec: Tier 3 (Enhanced) = 15 points, Tier 4 (Full) = 20 points
                expect(kycTrust).to.equal(15);
            });

            it('should calculate score with KYC tier 4', async function () {
                await mockRegistration.setKycTier4(user1.address, true);

                const [totalScore, kycTrust] = await participation.getScore(user1.address);
                expect(kycTrust).to.equal(20);
            });

            it('should calculate staking score', async function () {
                // Set 10M XOM stake with 180 days duration
                await mockOmniCore.setStake(
                    user1.address,
                    ethers.parseEther('10000000'), // 10M XOM
                    3,
                    180 * 24 * 60 * 60, // 180 days in seconds
                    0,
                    true
                );

                const [totalScore, , , stakingScore] = await participation.getScore(user1.address);
                // Tier 3 staking (10M) = 9 points, Duration tier 2 (180 days) = 6 points
                expect(stakingScore).to.equal(15);
            });

            it('should calculate referral activity', async function () {
                await mockRegistration.setReferralCount(user1.address, 5);

                const [totalScore, , , , referralActivity] = await participation.getScore(user1.address);
                expect(referralActivity).to.equal(5);
            });

            it('should cap referral activity at 10', async function () {
                await mockRegistration.setReferralCount(user1.address, 100);

                const [, , , , referralActivity] = await participation.getScore(user1.address);
                expect(referralActivity).to.equal(10);
            });
        });

        describe('getTotalScore', function () {
            it('should return total score', async function () {
                await mockRegistration.setKycTier1(user1.address, true);

                const totalScore = await participation.getTotalScore(user1.address);
                expect(totalScore).to.equal(5);
            });
        });
    });

    describe('Qualification Checks', function () {
        describe('canBeValidator', function () {
            it('should return false for low score', async function () {
                // Score < 50
                expect(await participation.canBeValidator(user1.address)).to.be.false;
            });

            it('should return false without KYC tier 4', async function () {
                // High score but no KYC tier 4
                await mockRegistration.setKycTier3(user1.address, true);
                await mockRegistration.setReferralCount(user1.address, 10);
                await mockOmniCore.setStake(
                    user1.address,
                    ethers.parseEther('100000000'),
                    4,
                    730 * 24 * 60 * 60,
                    0,
                    true
                );

                expect(await participation.canBeValidator(user1.address)).to.be.false;
            });

            it('should return true with high score and KYC tier 4', async function () {
                await mockRegistration.setKycTier4(user1.address, true);
                await mockRegistration.setReferralCount(user1.address, 10);
                await mockOmniCore.setStake(
                    user1.address,
                    ethers.parseEther('100000000'),
                    4,
                    730 * 24 * 60 * 60,
                    0,
                    true
                );

                // KYC = 20, Referral = 10, Staking = 24 = 54 points
                expect(await participation.canBeValidator(user1.address)).to.be.true;
            });
        });

        describe('canBeListingNode', function () {
            it('should return false for low score', async function () {
                // Score < 25
                expect(await participation.canBeListingNode(user1.address)).to.be.false;
            });

            it('should return true for score >= 25', async function () {
                await mockRegistration.setKycTier2(user1.address, true);
                await mockRegistration.setReferralCount(user1.address, 10);
                await mockOmniCore.setStake(
                    user1.address,
                    ethers.parseEther('1000000'),
                    2,
                    30 * 24 * 60 * 60,
                    0,
                    true
                );

                // KYC = 10, Referral = 10, Staking = 9 = 29 points
                expect(await participation.canBeListingNode(user1.address)).to.be.true;
            });
        });
    });

    describe('Admin Functions', function () {
        describe('setContracts', function () {
            it('should update contract references', async function () {
                const newRegistration = user1.address;
                const newOmniCore = user2.address;

                const tx = await participation.connect(owner).setContracts(newRegistration, newOmniCore);

                await expect(tx)
                    .to.emit(participation, 'ContractsUpdated')
                    .withArgs(newRegistration, newOmniCore);

                expect(await participation.registration()).to.equal(newRegistration);
                expect(await participation.omniCore()).to.equal(newOmniCore);
            });

            it('should reject zero address for registration', async function () {
                await expect(
                    participation.connect(owner).setContracts(ZeroAddress, user2.address)
                ).to.be.revertedWithCustomError(participation, 'ZeroAddress');
            });

            it('should reject zero address for omniCore', async function () {
                await expect(
                    participation.connect(owner).setContracts(user1.address, ZeroAddress)
                ).to.be.revertedWithCustomError(participation, 'ZeroAddress');
            });

            it('should reject unauthorized caller', async function () {
                await expect(
                    participation.connect(unauthorized).setContracts(user1.address, user2.address)
                ).to.be.reverted;
            });
        });
    });

    // ═══════════════════════════════════════════════════════════════════
    //  ATK-H04: Verifier Rate Limit & Delta Check Tests
    // ═══════════════════════════════════════════════════════════════════

    describe('ATK-H04: Verifier Rate Limits', function () {
        it('should enforce daily verifier limit (50 changes/day)', async function () {
            // Use up the 50 daily allowance with verifyTransactionClaim calls
            for (let i = 0; i < 50; i++) {
                await participation.connect(user1).claimMarketplaceTransactions([generateTxHash()]);
                await participation.connect(verifier).verifyTransactionClaim(user1.address, i);
            }

            // The 51st call should revert
            await participation.connect(user1).claimMarketplaceTransactions([generateTxHash()]);
            await expect(
                participation.connect(verifier).verifyTransactionClaim(user1.address, 50)
            ).to.be.revertedWithCustomError(participation, 'DailyVerifierLimitExceeded');
        });

        it('should reset verifier limit after day boundary', async function () {
            // Use up 50 changes
            for (let i = 0; i < 50; i++) {
                await participation.connect(user1).claimMarketplaceTransactions([generateTxHash()]);
                await participation.connect(verifier).verifyTransactionClaim(user1.address, i);
            }

            // Advance time past day boundary
            await time.increase(86401);

            // Should succeed after day rolls over
            await participation.connect(user2).claimMarketplaceTransactions([generateTxHash()]);
            await expect(
                participation.connect(verifier).verifyTransactionClaim(user2.address, 0)
            ).not.to.be.reverted;
        });

        it('should enforce listing count delta check', async function () {
            // Try to jump from 0 to 5000 (delta = 5000 > MAX_LISTING_COUNT_DELTA = 1000)
            await expect(
                participation.connect(verifier).setPublisherListingCount(user1.address, 5000)
            ).to.be.revertedWithCustomError(participation, 'ListingCountDeltaTooLarge');
        });

        it('should allow listing count increment within delta', async function () {
            // Jump from 0 to 1000 (delta = 1000 = MAX_LISTING_COUNT_DELTA)
            await expect(
                participation.connect(verifier).setPublisherListingCount(user1.address, 1000)
            ).not.to.be.reverted;

            expect(await participation.publisherListingCount(user1.address)).to.equal(1000);
        });

        it('should emit PublisherListingCountUpdated event', async function () {
            const tx = await participation.connect(verifier).setPublisherListingCount(user1.address, 500);

            await expect(tx)
                .to.emit(participation, 'PublisherListingCountUpdated')
                .withArgs(user1.address, 0, 500, verifier.address);
        });

        it('should enforce delta check on decreases too', async function () {
            // Set to 1000 first
            await participation.connect(verifier).setPublisherListingCount(user1.address, 1000);

            // Try to decrease by more than MAX_LISTING_COUNT_DELTA
            await expect(
                participation.connect(verifier).setPublisherListingCount(user1.address, 0)
            ).not.to.be.reverted; // delta = 1000, exactly at limit

            // Set back to 1000
            await participation.connect(verifier).setPublisherListingCount(user1.address, 1000);

            // Now set to 2000
            await participation.connect(verifier).setPublisherListingCount(user1.address, 2000);

            // Try to go from 2000 to 0 (delta 2000 > 1000)
            await expect(
                participation.connect(verifier).setPublisherListingCount(user1.address, 0)
            ).to.be.revertedWithCustomError(participation, 'ListingCountDeltaTooLarge');
        });
    });

    // ═══════════════════════════════════════════════════════════════════
    //  ATK-H12/K01: Unbounded Array Cap Tests
    // ═══════════════════════════════════════════════════════════════════

    describe('ATK-H12/K01: Array Caps', function () {
        it('should expose MAX_REVIEWS_PER_USER constant', async function () {
            expect(await participation.MAX_REVIEWS_PER_USER()).to.equal(1000);
        });

        it('should expose MAX_CLAIMS_PER_USER constant', async function () {
            expect(await participation.MAX_CLAIMS_PER_USER()).to.equal(1000);
        });

        it('should expose MAX_REPORTS_PER_USER constant', async function () {
            expect(await participation.MAX_REPORTS_PER_USER()).to.equal(500);
        });

        it('should expose MAX_FORUM_CONTRIBUTIONS_PER_USER constant', async function () {
            expect(await participation.MAX_FORUM_CONTRIBUTIONS_PER_USER()).to.equal(500);
        });
    });

    // ═══════════════════════════════════════════════════════════════════
    //  ATK-M22: Service Node Validator Check Tests
    // ═══════════════════════════════════════════════════════════════════

    describe('ATK-M22: Service Node Validator Check', function () {
        it('should accept validator service node heartbeat', async function () {
            await expect(
                participation.connect(validator1).submitServiceNodeHeartbeat()
            ).not.to.be.reverted;
        });

        it('should reject non-validator registered user', async function () {
            await expect(
                participation.connect(user1).submitServiceNodeHeartbeat()
            ).to.be.revertedWithCustomError(participation, 'NotServiceNode');
        });

        it('should reject unregistered non-validator', async function () {
            await expect(
                participation.connect(unauthorized).submitServiceNodeHeartbeat()
            ).to.be.revertedWithCustomError(participation, 'NotRegistered');
        });
    });
});
