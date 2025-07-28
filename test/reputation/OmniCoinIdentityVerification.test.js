const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("OmniCoinIdentityVerification", function () {
    let identityModule;
    let reputationCore;
    let registry;
    let owner, verifier, kycProvider, user1, user2;

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
        [owner, verifier, kycProvider, user1, user2] = await ethers.getSigners();

        // Deploy actual OmniCoinRegistry
        const OmniCoinRegistry = await ethers.getContractFactory("OmniCoinRegistry");
        registry = await OmniCoinRegistry.deploy(await owner.getAddress());
        await registry.waitForDeployment();

        // Deploy actual OmniCoinReputationCore
        const ReputationCore = await ethers.getContractFactory("OmniCoinReputationCore");
        reputationCore = await ReputationCore.deploy(
            await registry.getAddress(),
            await owner.getAddress()
        );
        await reputationCore.waitForDeployment();

        // Set up registry
        await registry.setContract(
            ethers.keccak256(ethers.toUtf8Bytes("REPUTATION_CORE")),
            await reputationCore.getAddress()
        );

        // Deploy identity module
        const Identity = await ethers.getContractFactory("OmniCoinIdentityVerification");
        identityModule = await Identity.deploy(
            await owner.getAddress(),
            await reputationCore.getAddress()
        );
        await identityModule.waitForDeployment();

        // Grant MODULE_ROLE on reputation core
        const MODULE_ROLE = await reputationCore.MODULE_ROLE();
        await reputationCore.grantRole(MODULE_ROLE, await identityModule.getAddress());

        // Grant roles
        const IDENTITY_VERIFIER_ROLE = await identityModule.IDENTITY_VERIFIER_ROLE();
        const KYC_PROVIDER_ROLE = await identityModule.KYC_PROVIDER_ROLE();
        
        await identityModule.grantRole(IDENTITY_VERIFIER_ROLE, await verifier.getAddress());
        await identityModule.grantRole(KYC_PROVIDER_ROLE, await kycProvider.getAddress());
    });

    describe("Deployment", function () {
        it("Should set correct admin", async function () {
            const ADMIN_ROLE = await identityModule.ADMIN_ROLE();
            expect(await identityModule.hasRole(ADMIN_ROLE, await owner.getAddress())).to.be.true;
        });

        it("Should set correct reputation core", async function () {
            expect(await identityModule.reputationCore()).to.equal(await reputationCore.getAddress());
        });

        it("Should initialize with correct default weight", async function () {
            const weight = await identityModule.getComponentWeight(10); // IDENTITY_VERIFICATION
            expect(weight).to.equal(1500); // 15%
        });

        it("Should start with MPC disabled", async function () {
            expect(await identityModule.isMpcAvailable()).to.be.false;
        });
    });

    describe("Identity Verification", function () {
        const proofHash = ethers.keccak256(ethers.toUtf8Bytes("proof"));
        const dummyScore = {
            ciphertext: 0n,
            signature: ethers.randomBytes(32)
        };

        it("Should verify identity at different tiers", async function () {
            await identityModule.connect(verifier).verifyIdentity(
                await user1.getAddress(),
                IDENTITY_TIERS.BASIC_ID,
                proofHash,
                dummyScore
            );

            const tier = await identityModule.getIdentityTier(await user1.getAddress());
            expect(tier).to.equal(IDENTITY_TIERS.BASIC_ID);
        });

        it("Should update user counts correctly", async function () {
            // Verify first user
            await identityModule.connect(verifier).verifyIdentity(
                await user1.getAddress(),
                IDENTITY_TIERS.BASIC_ID,
                proofHash,
                dummyScore
            );

            // Verify second user at same tier
            await identityModule.connect(verifier).verifyIdentity(
                await user2.getAddress(),
                IDENTITY_TIERS.BASIC_ID,
                proofHash,
                dummyScore
            );

            const counts = await identityModule.getTierStatistics();
            expect(counts[IDENTITY_TIERS.BASIC_ID]).to.equal(2);
            expect(await identityModule.totalVerifiedUsers()).to.equal(2);
        });

        it("Should handle tier upgrades", async function () {
            // Start with EMAIL tier
            await identityModule.connect(verifier).verifyIdentity(
                await user1.getAddress(),
                IDENTITY_TIERS.EMAIL,
                proofHash,
                dummyScore
            );

            let counts = await identityModule.getTierStatistics();
            expect(counts[IDENTITY_TIERS.EMAIL]).to.equal(1);

            // Upgrade to ENHANCED_ID
            await identityModule.connect(verifier).verifyIdentity(
                await user1.getAddress(),
                IDENTITY_TIERS.ENHANCED_ID,
                proofHash,
                dummyScore
            );

            counts = await identityModule.getTierStatistics();
            expect(counts[IDENTITY_TIERS.EMAIL]).to.equal(0);
            expect(counts[IDENTITY_TIERS.ENHANCED_ID]).to.equal(1);
        });

        it("Should reject invalid tiers", async function () {
            await expect(
                identityModule.connect(verifier).verifyIdentity(
                    await user1.getAddress(),
                    0, // UNVERIFIED - invalid
                    proofHash,
                    dummyScore
                )
            ).to.be.revertedWith("IdentityVerification: Invalid tier");

            await expect(
                identityModule.connect(verifier).verifyIdentity(
                    await user1.getAddress(),
                    9, // Beyond max
                    proofHash,
                    dummyScore
                )
            ).to.be.revertedWith("IdentityVerification: Invalid tier");
        });

        it("Should reject non-verifier calls", async function () {
            await expect(
                identityModule.connect(user1).verifyIdentity(
                    await user1.getAddress(),
                    IDENTITY_TIERS.BASIC_ID,
                    proofHash,
                    dummyScore
                )
            ).to.be.revertedWithCustomError(identityModule, "AccessControlUnauthorizedAccount");
        });
    });

    describe("Identity Downgrade", function () {
        beforeEach(async function () {
            // Verify user first
            const proofHash = ethers.keccak256(ethers.toUtf8Bytes("proof"));
            const dummyScore = {
                ciphertext: 0n,
                signature: ethers.randomBytes(32)
            };
            
            await identityModule.connect(verifier).verifyIdentity(
                await user1.getAddress(),
                IDENTITY_TIERS.BASIC_ID,
                proofHash,
                dummyScore
            );
        });

        it("Should downgrade identity", async function () {
            await identityModule.connect(verifier).downgradeIdentity(
                await user1.getAddress(),
                "Fraudulent documents"
            );

            const tier = await identityModule.getIdentityTier(await user1.getAddress());
            expect(tier).to.equal(IDENTITY_TIERS.UNVERIFIED);
        });

        it("Should update counts on downgrade", async function () {
            const countsBefore = await identityModule.getTierStatistics();
            expect(countsBefore[IDENTITY_TIERS.BASIC_ID]).to.equal(1);

            await identityModule.connect(verifier).downgradeIdentity(
                await user1.getAddress(),
                "Fraudulent documents"
            );

            const countsAfter = await identityModule.getTierStatistics();
            expect(countsAfter[IDENTITY_TIERS.BASIC_ID]).to.equal(0);
            expect(await identityModule.totalVerifiedUsers()).to.equal(0);
        });

        it("Should emit downgrade event", async function () {
            await expect(
                identityModule.connect(verifier).downgradeIdentity(
                    await user1.getAddress(),
                    "Fraudulent documents"
                )
            ).to.emit(identityModule, "IdentityDowngraded")
            .withArgs(await user1.getAddress(), "Fraudulent documents", await ethers.provider.getBlock('latest').then(b => b.timestamp + 1));
        });
    });

    describe("Identity Renewal", function () {
        const proofHash = ethers.keccak256(ethers.toUtf8Bytes("proof"));
        const newProofHash = ethers.keccak256(ethers.toUtf8Bytes("newproof"));

        beforeEach(async function () {
            const dummyScore = {
                ciphertext: 0n,
                signature: ethers.randomBytes(32)
            };
            
            await identityModule.connect(verifier).verifyIdentity(
                await user1.getAddress(),
                IDENTITY_TIERS.BASIC_ID,
                proofHash,
                dummyScore
            );
        });

        it("Should renew identity", async function () {
            await identityModule.connect(verifier).renewIdentity(
                await user1.getAddress(),
                newProofHash
            );

            const details = await identityModule.getIdentityDetails(await user1.getAddress());
            expect(details.tier).to.equal(IDENTITY_TIERS.BASIC_ID);
            expect(details.isActive).to.be.true;
        });

        it("Should update timestamps on renewal", async function () {
            const detailsBefore = await identityModule.getIdentityDetails(await user1.getAddress());
            
            // Wait a bit
            await ethers.provider.send("evm_increaseTime", [100]);
            await ethers.provider.send("evm_mine");

            await identityModule.connect(verifier).renewIdentity(
                await user1.getAddress(),
                newProofHash
            );

            const detailsAfter = await identityModule.getIdentityDetails(await user1.getAddress());
            expect(detailsAfter.verificationTime).to.be.gt(detailsBefore.verificationTime);
            expect(detailsAfter.expirationTime).to.be.gt(detailsBefore.expirationTime);
        });

        it("Should reject renewal of unverified users", async function () {
            await expect(
                identityModule.connect(verifier).renewIdentity(
                    await user2.getAddress(), // Never verified
                    newProofHash
                )
            ).to.be.revertedWith("IdentityVerification: Not verified");
        });
    });

    describe("Identity Expiration", function () {
        it("Should check expiration correctly", async function () {
            const proofHash = ethers.keccak256(ethers.toUtf8Bytes("proof"));
            const dummyScore = {
                ciphertext: 0n,
                signature: ethers.randomBytes(32)
            };
            
            // Verify with EMAIL tier (180 days expiration)
            await identityModule.connect(verifier).verifyIdentity(
                await user1.getAddress(),
                IDENTITY_TIERS.EMAIL,
                proofHash,
                dummyScore
            );

            expect(await identityModule.isIdentityExpired(await user1.getAddress())).to.be.false;

            // Fast forward 181 days
            await ethers.provider.send("evm_increaseTime", [181 * 24 * 60 * 60]);
            await ethers.provider.send("evm_mine");

            expect(await identityModule.isIdentityExpired(await user1.getAddress())).to.be.true;
        });

        it("Should return unverified tier for expired identities", async function () {
            const proofHash = ethers.keccak256(ethers.toUtf8Bytes("proof"));
            const dummyScore = {
                ciphertext: 0n,
                signature: ethers.randomBytes(32)
            };
            
            await identityModule.connect(verifier).verifyIdentity(
                await user1.getAddress(),
                IDENTITY_TIERS.EMAIL,
                proofHash,
                dummyScore
            );

            // Fast forward past expiration
            await ethers.provider.send("evm_increaseTime", [181 * 24 * 60 * 60]);
            await ethers.provider.send("evm_mine");

            const tier = await identityModule.getIdentityTier(await user1.getAddress());
            expect(tier).to.equal(IDENTITY_TIERS.UNVERIFIED);
        });
    });

    describe("KYC Provider Management", function () {
        it("Should add KYC provider", async function () {
            const newProvider = ethers.Wallet.createRandom().address;
            await identityModule.addKYCProvider(newProvider);
            
            expect(await identityModule.kycProviders(newProvider)).to.be.true;
            
            const KYC_PROVIDER_ROLE = await identityModule.KYC_PROVIDER_ROLE();
            expect(await identityModule.hasRole(KYC_PROVIDER_ROLE, newProvider)).to.be.true;
        });

        it("Should remove KYC provider", async function () {
            await identityModule.removeKYCProvider(kycProvider.address);
            
            expect(await identityModule.kycProviders(kycProvider.address)).to.be.false;
            
            const KYC_PROVIDER_ROLE = await identityModule.KYC_PROVIDER_ROLE();
            expect(await identityModule.hasRole(KYC_PROVIDER_ROLE, kycProvider.address)).to.be.false;
        });

        it("Should emit events", async function () {
            const newProvider = ethers.Wallet.createRandom().address;
            
            await expect(identityModule.addKYCProvider(newProvider))
                .to.emit(identityModule, "KYCProviderAdded")
                .withArgs(newProvider);
                
            await expect(identityModule.removeKYCProvider(newProvider))
                .to.emit(identityModule, "KYCProviderRemoved")
                .withArgs(newProvider);
        });
    });

    describe("Admin Functions", function () {
        it("Should update tier scores", async function () {
            await identityModule.updateTierScore(IDENTITY_TIERS.EMAIL, 1500);
            
            const scores = await identityModule.tierScores(IDENTITY_TIERS.EMAIL);
            expect(scores).to.equal(1500);
        });

        it("Should update tier expiration periods", async function () {
            const newPeriod = 365 * 24 * 60 * 60; // 1 year
            await identityModule.updateTierExpiration(IDENTITY_TIERS.EMAIL, newPeriod);
            
            const period = await identityModule.tierExpirationPeriods(IDENTITY_TIERS.EMAIL);
            expect(period).to.equal(newPeriod);
        });

        it("Should reject non-admin updates", async function () {
            await expect(
                identityModule.connect(user1).updateTierScore(IDENTITY_TIERS.EMAIL, 1500)
            ).to.be.revertedWithCustomError(identityModule, "AccessControlUnauthorizedAccount");
        });
    });

    describe("Pausable", function () {
        it("Should pause and unpause", async function () {
            await identityModule.pause();
            expect(await identityModule.paused()).to.be.true;

            await identityModule.unpause();
            expect(await identityModule.paused()).to.be.false;
        });

        it("Should prevent verification when paused", async function () {
            await identityModule.pause();
            
            const proofHash = ethers.keccak256(ethers.toUtf8Bytes("proof"));
            const dummyScore = {
                ciphertext: 0n,
                signature: ethers.randomBytes(32)
            };
            
            await expect(
                identityModule.connect(verifier).verifyIdentity(
                    await user1.getAddress(),
                    IDENTITY_TIERS.BASIC_ID,
                    proofHash,
                    dummyScore
                )
            ).to.be.revertedWithCustomError(identityModule, "EnforcedPause");
        });
    });
});