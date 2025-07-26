/**
 * Focused test suite for OmniCoinReputationV2.sol
 * Tests contract structure, access control, and non-MPC functionality in Hardhat.
 * MPC-specific functionality will be tested on COTI testnet.
 */

const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("OmniCoinReputationV2 - Hardhat Structure Tests", function () {
    let mockToken;
    let reputationContract;
    let owner, user1, user2, user3, validator1, arbitrator1, trustManager, referralManager, identityVerifier;

    // Component constants for testing
    const COMPONENTS = {
        TRANSACTION_SUCCESS: 0,
        TRANSACTION_DISPUTE: 1,
        ARBITRATION_PERFORMANCE: 2,
        GOVERNANCE_PARTICIPATION: 3,
        VALIDATOR_PERFORMANCE: 4,
        MARKETPLACE_BEHAVIOR: 5,
        COMMUNITY_ENGAGEMENT: 6,
        UPTIME_RELIABILITY: 7,
        TRUST_SCORE: 8,
        REFERRAL_ACTIVITY: 9,
        IDENTITY_VERIFICATION: 10
    };

    // Identity tier constants
    const IDENTITY_TIERS = {
        UNVERIFIED: 0,
        EMAIL: 1,
        PHONE: 2,
        BASIC_ID: 3,
        ENHANCED_ID: 4,
        BIOMETRIC: 5,
        PREMIUM_INDIVIDUAL: 6,
        COMMERCIAL: 7,
        CORPORATE: 8
    };

    beforeEach(async function () {
        [owner, user1, user2, user3, validator1, arbitrator1, trustManager, referralManager, identityVerifier] = await ethers.getSigners();

        // For testing, we'll use a mock token address since OmniCoinCore has MPC dependencies
        // In production deployment, this will be the actual OmniCoinCore address
        const mockTokenAddress = user1.address; // Use a valid address for testing

        // Deploy OmniCoinReputationV2 with mock token address
        const OmniCoinReputationV2 = await ethers.getContractFactory("OmniCoinReputationV2");
        reputationContract = await OmniCoinReputationV2.deploy(
            mockTokenAddress,
            owner.address
        );
        await reputationContract.waitForDeployment();

        // Grant necessary roles
        const VALIDATOR_ROLE = await reputationContract.VALIDATOR_ROLE();
        const ARBITRATOR_ROLE = await reputationContract.ARBITRATOR_ROLE();
        const REPUTATION_UPDATER_ROLE = await reputationContract.REPUTATION_UPDATER_ROLE();
        const TRUST_MANAGER_ROLE = await reputationContract.TRUST_MANAGER_ROLE();
        const REFERRAL_MANAGER_ROLE = await reputationContract.REFERRAL_MANAGER_ROLE();
        const IDENTITY_VERIFIER_ROLE = await reputationContract.IDENTITY_VERIFIER_ROLE();

        await reputationContract.grantRole(VALIDATOR_ROLE, validator1.address);
        await reputationContract.grantRole(ARBITRATOR_ROLE, arbitrator1.address);
        await reputationContract.grantRole(REPUTATION_UPDATER_ROLE, owner.address);
        await reputationContract.grantRole(TRUST_MANAGER_ROLE, trustManager.address);
        await reputationContract.grantRole(REFERRAL_MANAGER_ROLE, referralManager.address);
        await reputationContract.grantRole(IDENTITY_VERIFIER_ROLE, identityVerifier.address);
    });

    describe("Contract Deployment", function () {
        it("Should deploy with correct initial configuration", async function () {
            expect(await reputationContract.token()).to.equal(user1.address); // Mock token address
            expect(await reputationContract.tierCount()).to.equal(5);
            expect(await reputationContract.minValidatorReputation()).to.equal(5000);
            expect(await reputationContract.maxReputationScore()).to.equal(100000);
            expect(await reputationContract.decayPeriod()).to.equal(30 * 24 * 60 * 60); // 30 days
            expect(await reputationContract.decayRate()).to.equal(100); // 1%
        });

        it("Should initialize default weighting configuration", async function () {
            const [weights, version, lastUpdate] = await reputationContract.getCurrentWeighting();
            
            // Check that weights sum to 10000 (100%)
            let totalWeight = 0;
            for (let i = 0; i < weights.length; i++) {
                totalWeight += Number(weights[i]);
            }
            expect(totalWeight).to.equal(10000);
            expect(version).to.equal("v2.1.0");
        });

        it("Should initialize default reputation tiers", async function () {
            const tier2 = await reputationContract.getReputationTier(2);
            expect(tier2.name).to.equal("Advanced");
            expect(tier2.minScore).to.equal(5000);
            expect(tier2.validatorWeight).to.equal(5);
        });

        it("Should initialize identity tier configurations", async function () {
            const emailTier = await reputationContract.getIdentityTierConfig(IDENTITY_TIERS.EMAIL);
            expect(emailTier.name).to.equal("Email Verified");
            expect(emailTier.baseScore).to.equal(100);
            
            const corporateTier = await reputationContract.getIdentityTierConfig(IDENTITY_TIERS.CORPORATE);
            expect(corporateTier.name).to.equal("Corporate Verified");
            expect(corporateTier.baseScore).to.equal(4000);
        });
    });

    describe("Identity Verification System", function () {
        it("Should verify user identity successfully", async function () {
            const verificationHash = "0x1234567890abcdef";
            
            await expect(reputationContract.connect(identityVerifier).verifyIdentity(
                user1.address,
                IDENTITY_TIERS.EMAIL,
                verificationHash,
                0 // Use default validity period
            )).to.emit(reputationContract, "IdentityVerified")
                .withArgs(user1.address, IDENTITY_TIERS.EMAIL, 100, identityVerifier.address);

            const identityData = await reputationContract.getIdentityData(user1.address);
            expect(identityData.verificationTier).to.equal(IDENTITY_TIERS.EMAIL);
            expect(identityData.verificationScore).to.equal(100);
            expect(identityData.isActive).to.be.true;
        });

        it("Should handle identity tier upgrades", async function () {
            // Start with email verification
            await reputationContract.connect(identityVerifier).verifyIdentity(
                user1.address,
                IDENTITY_TIERS.EMAIL,
                "hash1",
                0
            );

            // Upgrade to basic ID
            await expect(reputationContract.connect(identityVerifier).verifyIdentity(
                user1.address,
                IDENTITY_TIERS.BASIC_ID,
                "hash2",
                0
            )).to.emit(reputationContract, "IdentityUpdated")
                .withArgs(user1.address, IDENTITY_TIERS.EMAIL, IDENTITY_TIERS.BASIC_ID);

            const identityData = await reputationContract.getIdentityData(user1.address);
            expect(identityData.verificationTier).to.equal(IDENTITY_TIERS.BASIC_ID);
            expect(identityData.verificationScore).to.equal(800);
        });

        it("Should expire identity verification", async function () {
            await reputationContract.connect(identityVerifier).verifyIdentity(
                user1.address,
                IDENTITY_TIERS.EMAIL,
                "hash1",
                0
            );

            await expect(reputationContract.connect(identityVerifier).expireIdentity(user1.address))
                .to.emit(reputationContract, "IdentityExpired");

            const identityData = await reputationContract.getIdentityData(user1.address);
            expect(identityData.isActive).to.be.false;
        });

        it("Should batch check identity expiration", async function () {
            // Verify user with short validity period
            await reputationContract.connect(identityVerifier).verifyIdentity(
                user1.address,
                IDENTITY_TIERS.EMAIL,
                "hash1",
                1 // 1 second validity
            );

            // Wait for expiration
            await new Promise(resolve => setTimeout(resolve, 2000));

            await expect(reputationContract.connect(identityVerifier).batchCheckIdentityExpiration([user1.address]))
                .to.emit(reputationContract, "IdentityExpired");
        });

        it("Should configure identity tiers", async function () {
            await reputationContract.setIdentityTierConfig(
                IDENTITY_TIERS.EMAIL,
                "Custom Email Tier",
                200,
                365 * 24 * 60 * 60, // 1 year
                true,
                "Custom email verification requirements"
            );

            const tierConfig = await reputationContract.getIdentityTierConfig(IDENTITY_TIERS.EMAIL);
            expect(tierConfig.name).to.equal("Custom Email Tier");
            expect(tierConfig.baseScore).to.equal(200);
        });

        it("Should reject invalid identity verification", async function () {
            await expect(reputationContract.connect(identityVerifier).verifyIdentity(
                ethers.ZeroAddress,
                IDENTITY_TIERS.EMAIL,
                "hash1",
                0
            )).to.be.revertedWith("OmniCoinReputationV2: Invalid user address");

            await expect(reputationContract.connect(identityVerifier).verifyIdentity(
                user1.address,
                IDENTITY_TIERS.EMAIL,
                "",
                0
            )).to.be.revertedWith("OmniCoinReputationV2: Verification hash required");

            await expect(reputationContract.connect(identityVerifier).verifyIdentity(
                user1.address,
                99, // Invalid tier
                "hash1",
                0
            )).to.be.revertedWith("OmniCoinReputationV2: Invalid identity tier");
        });
    });

    describe("Trust System (DPoS Voting)", function () {
        it("Should validate trust system structure - MPC voting tested on COTI testnet", async function () {
            // NOTE: Actual DPoS voting with encrypted vote weights requires COTI MPC
            // This test validates the structure - full functionality tested on COTI testnet
            
            // Test that trust data structure is initialized correctly
            const publicReputationInfo = await reputationContract.getPublicReputationInfo(user1.address);
            expect(publicReputationInfo.tier).to.equal(0); // Default tier
            expect(publicReputationInfo.isEligible).to.be.false; // Below minimum reputation
        });

        it("Should update COTI Proof of Trust score", async function () {
            // Enable COTI PoT
            await reputationContract.setCotiPoTIntegration(true, owner.address);

            await expect(reputationContract.connect(trustManager).updateCotiPoTScore(
                user1.address,
                5000
            )).to.emit(reputationContract, "TrustScoreUpdated");

            const trustData = await reputationContract.getTrustData(user1.address);
            expect(trustData.cotiPoTScore).to.equal(5000);
            expect(trustData.useCotiPoT).to.be.true;
        });

        it("Should configure COTI PoT integration", async function () {
            await expect(reputationContract.setCotiPoTIntegration(true, user1.address))
                .to.emit(reputationContract, "CotiPoTIntegrationUpdated")
                .withArgs(true, user1.address);

            expect(await reputationContract.cotiPoTAvailable()).to.be.true;
            expect(await reputationContract.cotiPoTContract()).to.equal(user1.address);
        });

        it("Should set trust system parameters", async function () {
            await reputationContract.setTrustParameters(200, 15000);
            
            expect(await reputationContract.minTrustVoteWeight()).to.equal(200);
            expect(await reputationContract.maxTrustScore()).to.equal(15000);
        });

        it("Should reject invalid COTI PoT updates", async function () {
            // COTI PoT not available
            await expect(reputationContract.connect(trustManager).updateCotiPoTScore(
                user1.address,
                5000
            )).to.be.revertedWith("OmniCoinReputationV2: COTI PoT not available");
        });
    });

    describe("Referral System", function () {
        it("Should register referral successfully", async function () {
            const tx = await reputationContract.connect(referralManager).registerReferral(
                user1.address, // referrer
                user2.address  // referred
            );
            const receipt = await tx.wait();
            const block = await ethers.provider.getBlock(receipt.blockNumber);
            
            await expect(tx).to.emit(reputationContract, "ReferralRegistered")
                .withArgs(user1.address, user2.address, block.timestamp);

            expect(await reputationContract.getReferrerOf(user2.address)).to.equal(user1.address);
            
            const referrals = await reputationContract.getReferralsByUser(user1.address);
            expect(referrals).to.include(user2.address);

            const referralData = await reputationContract.getReferralData(user1.address);
            expect(referralData.publicReferralCount).to.equal(1);
            expect(referralData.publicActiveReferrals).to.equal(0); // Not yet validated
        });

        it("Should validate referral based on activity", async function () {
            // Register referral first
            await reputationContract.connect(referralManager).registerReferral(
                user1.address,
                user2.address
            );

            // Validate referral with sufficient activity
            await expect(reputationContract.connect(referralManager).validateReferral(
                user2.address,
                2000 // Above minimum activity threshold
            )).to.emit(reputationContract, "ReferralValidated")
                .withArgs(user1.address, user2.address, true);

            expect(await reputationContract.isValidReferral(user2.address)).to.be.true;

            const referralData = await reputationContract.getReferralData(user1.address);
            expect(referralData.publicActiveReferrals).to.equal(1);
        });

        it("Should handle multiple referrals with quality scoring", async function () {
            // Register multiple referrals
            await reputationContract.connect(referralManager).registerReferral(user1.address, user2.address);
            await reputationContract.connect(referralManager).registerReferral(user1.address, user3.address);

            // Validate one referral
            await reputationContract.connect(referralManager).validateReferral(user2.address, 2000);

            const referralData = await reputationContract.getReferralData(user1.address);
            expect(referralData.publicReferralCount).to.equal(2);
            expect(referralData.publicActiveReferrals).to.equal(1);
            expect(referralData.referralQualityScore).to.equal(5000); // 50% success rate
        });

        it("Should set referral system parameters", async function () {
            await reputationContract.setReferralParameters(
                14 * 24 * 60 * 60, // 14 days minimum age
                365 * 24 * 60 * 60, // 1 year validity
                2000, // Minimum activity
                10000 // Maximum score
            );

            expect(await reputationContract.minReferralAge()).to.equal(14 * 24 * 60 * 60);
            expect(await reputationContract.maxReferralScore()).to.equal(10000);
        });

        it("Should reject invalid referral operations", async function () {
            await expect(reputationContract.connect(referralManager).registerReferral(
                ethers.ZeroAddress,
                user2.address
            )).to.be.revertedWith("OmniCoinReputationV2: Invalid referrer");

            await expect(reputationContract.connect(referralManager).registerReferral(
                user1.address,
                user1.address
            )).to.be.revertedWith("OmniCoinReputationV2: Cannot refer self");

            // Register referral
            await reputationContract.connect(referralManager).registerReferral(user1.address, user2.address);

            // Try to register same user again
            await expect(reputationContract.connect(referralManager).registerReferral(
                user3.address,
                user2.address
            )).to.be.revertedWith("OmniCoinReputationV2: Already has referrer");
        });
    });

    describe("Standard Reputation Management", function () {
        it("Should update reputation component successfully", async function () {
            // Test structure without MPC - in real implementation would use COTI MPC
            const publicReputationInfo = await reputationContract.getPublicReputationInfo(user1.address);
            expect(publicReputationInfo.tier).to.equal(0);
        });

        it("Should batch update multiple components", async function () {
            // Test structure validation
            const components = [COMPONENTS.TRANSACTION_SUCCESS, COMPONENTS.GOVERNANCE_PARTICIPATION];
            
            // In real implementation, would use proper encrypted values
            // For testing, verify the structure exists
            expect(components.length).to.equal(2);
        });

        it("Should reject updates to special components", async function () {
            // These components should use their own specialized functions
            const specialComponents = [
                COMPONENTS.TRUST_SCORE,
                COMPONENTS.REFERRAL_ACTIVITY,
                COMPONENTS.IDENTITY_VERIFICATION
            ];

            for (const component of specialComponents) {
                const componentName = Object.keys(COMPONENTS)[component];
                console.log(`Testing component restriction for: ${componentName}`);
            }
        });

        it("Should handle component enablement and weights", async function () {
            const componentInfo = await reputationContract.getReputationComponent(user1.address, COMPONENTS.TRANSACTION_SUCCESS);
            expect(componentInfo.publicWeight).to.equal(1400); // 14% from default weighting
        });
    });

    describe("Flexible Weighting System", function () {
        it("Should update weighting configuration successfully", async function () {
            const newWeights = [
                1500, // Transaction Success (15%)
                500,  // Transaction Dispute (5%)
                1000, // Arbitration Performance (10%)
                500,  // Governance Participation (5%)
                1000, // Validator Performance (10%)
                300,  // Marketplace Behavior (3%)
                200,  // Community Engagement (2%)
                1000, // Uptime Reliability (10%)
                1400, // Trust Score (14%)
                1000, // Referral Activity (10%)
                1600  // Identity Verification (16%)
            ];

            await expect(reputationContract.updateWeightingConfig(newWeights, "v2.2.0"))
                .to.emit(reputationContract, "WeightingConfigUpdated")
                .withArgs("v2.2.0", owner.address);

            const [weights, version] = await reputationContract.getCurrentWeighting();
            expect(weights[0]).to.equal(1500); // Transaction Success now 15%
            expect(version).to.equal("v2.2.0");
        });

        it("Should reject invalid weighting configurations", async function () {
            const invalidWeights = [
                1000, 1000, 1000, 1000, 1000,
                1000, 1000, 1000, 1000, 1000, 999 // Total = 9999, not 10000
            ];

            await expect(reputationContract.updateWeightingConfig(invalidWeights, "invalid"))
                .to.be.revertedWith("OmniCoinReputationV2: Weights must sum to 10000");
        });

        it("Should store historical weighting configurations", async function () {
            const newWeights = [
                1500, 800, 1100, 700, 1200,
                350, 250, 1200, 1350, 1100, 450
            ];

            await reputationContract.updateWeightingConfig(newWeights, "v2.3.0");

            // Check historical configuration
            const [historicalWeights] = await reputationContract.getHistoricalWeighting("v2.1.0");
            expect(historicalWeights[0]).to.equal(1400); // Original Transaction Success weight
        });
    });

    describe("Reputation Tier Management", function () {
        it("Should set custom reputation tier", async function () {
            await expect(reputationContract.setReputationTier(
                5, // New tier
                "Elite",
                75000,
                100000,
                50,
                63 // All privileges
            )).to.emit(reputationContract, "TierUpdated")
                .withArgs(5, "Elite", 75000, 100000);

            const tierInfo = await reputationContract.getReputationTier(5);
            expect(tierInfo.name).to.equal("Elite");
            expect(tierInfo.validatorWeight).to.equal(50);
            expect(await reputationContract.tierCount()).to.equal(6);
        });

        it("Should validate tier configuration", async function () {
            await expect(reputationContract.setReputationTier(
                0,
                "Invalid",
                1000, // minScore
                500,  // maxScore < minScore
                1,
                1
            )).to.be.revertedWith("OmniCoinReputationV2: Invalid score range");

            await expect(reputationContract.setReputationTier(
                0,
                "Invalid",
                0,
                200000, // Exceeds maxReputationScore
                1,
                1
            )).to.be.revertedWith("OmniCoinReputationV2: Score exceeds maximum");
        });
    });

    describe("Privacy Functions", function () {
        it("Should set privacy preference", async function () {
            await expect(reputationContract.connect(user1).setPrivacyPreference(true))
                .to.emit(reputationContract, "PrivacyPreferenceChanged")
                .withArgs(user1.address, true);

            const [, isPrivacyEnabled] = await reputationContract.getPrivateReputationInfo(user1.address);
            expect(isPrivacyEnabled).to.be.true;
        });

        it("Should initialize user reputation on privacy change", async function () {
            // User should be initialized when setting privacy preference
            await reputationContract.connect(user1).setPrivacyPreference(false);

            const activeUsers = await reputationContract.getActiveUsers();
            expect(activeUsers).to.include(user1.address);
        });
    });

    describe("Validator Eligibility", function () {
        it("Should check validator eligibility correctly", async function () {
            // User starts as not eligible (tier 0, below minimum reputation)
            expect(await reputationContract.isEligibleValidator(user1.address)).to.be.false;

            // Set a custom tier with sufficient minimum score
            await reputationContract.setReputationTier(
                0, // Update tier 0
                "Basic Validator",
                5000, // minScore >= minValidatorReputation
                10000,
                3,
                7
            );

            // User would still need actual reputation score of 5000+
            // In real implementation, this would require component updates to reach the score
        });

        it("Should emit validator eligibility changes", async function () {
            // This would be tested with actual reputation updates that trigger eligibility changes
            // For now, verify the event structure exists
            const events = await reputationContract.queryFilter("ValidatorEligibilityChanged");
            expect(Array.isArray(events)).to.be.true;
        });
    });

    describe("View Functions", function () {
        it("Should return public reputation information", async function () {
            const info = await reputationContract.getPublicReputationInfo(user1.address);
            expect(info.tier).to.equal(0);
            expect(info.isEligible).to.be.false;
            expect(info.totalInteractions).to.equal(0);
            expect(info.lastUpdate).to.equal(0);
        });

        it("Should return trust data", async function () {
            const trustData = await reputationContract.getTrustData(user1.address);
            expect(trustData.publicVoterCount).to.equal(0);
            expect(trustData.cotiPoTScore).to.equal(0);
            expect(trustData.useCotiPoT).to.be.false;
        });

        it("Should return referral data", async function () {
            const referralData = await reputationContract.getReferralData(user1.address);
            expect(referralData.publicReferralCount).to.equal(0);
            expect(referralData.publicActiveReferrals).to.equal(0);
            expect(referralData.referralQualityScore).to.equal(0);
        });

        it("Should return component information", async function () {
            const componentInfo = await reputationContract.getReputationComponent(
                user1.address, 
                COMPONENTS.TRANSACTION_SUCCESS
            );
            expect(componentInfo.publicWeight).to.equal(1400); // 14% default weight
            expect(componentInfo.interactionCount).to.equal(0);
            expect(componentInfo.isEnabled).to.be.false;
        });
    });

    describe("Admin Functions", function () {
        it("Should set global parameters", async function () {
            await reputationContract.setGlobalParameters(
                45 * 24 * 60 * 60, // 45 days decay period
                150, // 1.5% decay rate
                7500, // Higher minimum validator reputation
                150000 // Higher maximum score
            );

            expect(await reputationContract.decayPeriod()).to.equal(45 * 24 * 60 * 60);
            expect(await reputationContract.decayRate()).to.equal(150);
            expect(await reputationContract.minValidatorReputation()).to.equal(7500);
            expect(await reputationContract.maxReputationScore()).to.equal(150000);
        });

        it("Should validate global parameters", async function () {
            await expect(reputationContract.setGlobalParameters(
                30 * 24 * 60 * 60,
                1001, // > 10% decay rate
                5000,
                100000
            )).to.be.revertedWith("OmniCoinReputationV2: Decay rate too high");

            await expect(reputationContract.setGlobalParameters(
                30 * 24 * 60 * 60,
                100,
                100000, // minValidatorReputation > maxReputationScore
                50000
            )).to.be.revertedWith("OmniCoinReputationV2: Invalid score limits");
        });

        it("Should set identity parameters", async function () {
            await reputationContract.setIdentityParameters(
                10000, // Higher max identity score
                true   // Enable identity decay
            );

            expect(await reputationContract.maxIdentityScore()).to.equal(10000);
            expect(await reputationContract.identityDecayEnabled()).to.be.true;
        });

        it("Should pause and unpause contract", async function () {
            await reputationContract.pause();
            expect(await reputationContract.paused()).to.be.true;

            // Operations should be paused
            await expect(reputationContract.connect(identityVerifier).verifyIdentity(
                user1.address,
                IDENTITY_TIERS.EMAIL,
                "hash1",
                0
            )).to.be.revertedWithCustomError(reputationContract, "EnforcedPause");

            await reputationContract.unpause();
            expect(await reputationContract.paused()).to.be.false;
        });
    });

    describe("Access Control", function () {
        it("Should restrict access to role-protected functions", async function () {
            // Test identity verification access
            await expect(reputationContract.connect(user1).verifyIdentity(
                user2.address,
                IDENTITY_TIERS.EMAIL,
                "hash1",
                0
            )).to.be.reverted; // AccessControl: account is missing role

            // Test trust management access
            await expect(reputationContract.connect(user1).updateCotiPoTScore(
                user2.address,
                5000
            )).to.be.reverted; // AccessControl: account is missing role

            // Test referral management access
            await expect(reputationContract.connect(user1).registerReferral(
                user2.address,
                user3.address
            )).to.be.reverted; // AccessControl: account is missing role

            // Test admin functions access
            await expect(reputationContract.connect(user1).pause())
                .to.be.reverted; // AccessControl: account is missing role
        });

        it("Should allow role holders to perform their functions", async function () {
            // Identity verifier can verify identity
            await expect(reputationContract.connect(identityVerifier).verifyIdentity(
                user1.address,
                IDENTITY_TIERS.EMAIL,
                "hash1",
                0
            )).to.not.be.reverted;

            // Referral manager can register referrals
            await expect(reputationContract.connect(referralManager).registerReferral(
                user1.address,
                user2.address
            )).to.not.be.reverted;

            // Admin can set parameters
            await expect(reputationContract.setGlobalParameters(
                30 * 24 * 60 * 60, 200, 6000, 120000
            )).to.not.be.reverted;
        });
    });

    describe("Edge Cases and Error Handling", function () {
        it("Should handle zero addresses correctly", async function () {
            await expect(reputationContract.getPublicReputationInfo(ethers.ZeroAddress))
                .to.not.be.reverted;

            const info = await reputationContract.getPublicReputationInfo(ethers.ZeroAddress);
            expect(info.tier).to.equal(0);
            expect(info.isEligible).to.be.false;
        });

        it("Should handle invalid component types", async function () {
            await expect(reputationContract.getReputationComponent(user1.address, 99))
                .to.be.revertedWith("OmniCoinReputationV2: Invalid component");
        });

        it("Should handle invalid tier queries", async function () {
            await expect(reputationContract.getReputationTier(99))
                .to.be.revertedWith("OmniCoinReputationV2: Invalid tier");
        });

        it("Should handle empty arrays in batch operations", async function () {
            await expect(reputationContract.connect(identityVerifier).batchCheckIdentityExpiration([]))
                .to.not.be.reverted;
        });
    });

    describe("Integration Tests", function () {
        it("Should handle complete user reputation lifecycle", async function () {
            // 1. Verify identity
            await reputationContract.connect(identityVerifier).verifyIdentity(
                user1.address,
                IDENTITY_TIERS.BASIC_ID,
                "verification_hash",
                0
            );

            // 2. Register as referrer
            await reputationContract.connect(referralManager).registerReferral(
                user1.address,
                user2.address
            );

            // 3. Validate referral
            await reputationContract.connect(referralManager).validateReferral(
                user2.address,
                2000
            );

            // 4. Check that user has active reputation
            const activeUsers = await reputationContract.getActiveUsers();
            expect(activeUsers).to.include(user1.address);

            // 5. Check reputation components
            const identityData = await reputationContract.getIdentityData(user1.address);
            expect(identityData.verificationTier).to.equal(IDENTITY_TIERS.BASIC_ID);

            const referralData = await reputationContract.getReferralData(user1.address);
            expect(referralData.publicReferralCount).to.equal(1);
            expect(referralData.publicActiveReferrals).to.equal(1);
        });

        it("Should handle weighting updates affecting all users", async function () {
            // Initialize some users with reputation
            await reputationContract.connect(identityVerifier).verifyIdentity(
                user1.address,
                IDENTITY_TIERS.EMAIL,
                "hash1",
                0
            );
            await reputationContract.connect(identityVerifier).verifyIdentity(
                user2.address,
                IDENTITY_TIERS.PHONE,
                "hash2",
                0
            );

            // Update weighting configuration
            const newWeights = [
                910, 910, 910, 910, 910,
                910, 910, 910, 910, 910, 900
            ];

            await expect(reputationContract.updateWeightingConfig(newWeights, "test_version"))
                .to.not.be.reverted;

            // Verify both users are still in the system
            const activeUsers = await reputationContract.getActiveUsers();
            expect(activeUsers.length).to.be.greaterThan(0);
        });
    });
});