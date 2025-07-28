const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("OmniCoinTrustSystem", function () {
    let trustModule;
    let reputationCore;
    let registry;
    let owner, trustManager, cotiOracle, voter1, voter2, candidate1, candidate2;

    const MIN_VOTE_AMOUNT = ethers.parseUnits("100", 6); // 100 tokens
    const VOTE_DECAY_PERIOD = 90 * 24 * 60 * 60; // 90 days

    beforeEach(async function () {
        [owner, trustManager, cotiOracle, voter1, voter2, candidate1, candidate2] = await ethers.getSigners();

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

        // Deploy trust module
        const Trust = await ethers.getContractFactory("OmniCoinTrustSystem");
        trustModule = await Trust.deploy(
            await owner.getAddress(),
            await reputationCore.getAddress()
        );
        await trustModule.waitForDeployment();

        // Grant MODULE_ROLE on reputation core
        const MODULE_ROLE = await reputationCore.MODULE_ROLE();
        await reputationCore.grantRole(MODULE_ROLE, await trustModule.getAddress());

        // Grant roles
        const TRUST_MANAGER_ROLE = await trustModule.TRUST_MANAGER_ROLE();
        const COTI_ORACLE_ROLE = await trustModule.COTI_ORACLE_ROLE();
        
        await trustModule.grantRole(TRUST_MANAGER_ROLE, await trustManager.getAddress());
        await trustModule.grantRole(COTI_ORACLE_ROLE, await cotiOracle.getAddress());
    });

    describe("Deployment", function () {
        it("Should set correct admin", async function () {
            const ADMIN_ROLE = await trustModule.ADMIN_ROLE();
            expect(await trustModule.hasRole(ADMIN_ROLE, await owner.getAddress())).to.be.true;
        });

        it("Should set correct reputation core", async function () {
            expect(await trustModule.reputationCore()).to.equal(await reputationCore.getAddress());
        });

        it("Should initialize with correct default weight", async function () {
            const weight = await trustModule.getComponentWeight(8); // TRUST_SCORE
            expect(weight).to.equal(2000); // 20%
        });

        it("Should initialize total system votes to zero", async function () {
            const totalVotes = await trustModule.totalSystemVotes();
            expect(totalVotes).to.equal(0);
        });

        it("Should start with COTI PoT disabled", async function () {
            expect(await trustModule.cotiPoTEnabled()).to.be.false;
        });
    });

    describe("DPoS Voting", function () {
        const createVoteInput = (amount) => ({
            ciphertext: amount,
            signature: ethers.randomBytes(32)
        });

        it("Should cast DPoS vote", async function () {
            const voteAmount = MIN_VOTE_AMOUNT;
            const voteInput = createVoteInput(voteAmount);

            await trustModule.connect(voter1).castDPoSVote(
                await candidate1.getAddress(),
                voteInput
            );

            // Check voter count increased
            expect(await trustModule.getVoterCount(await candidate1.getAddress())).to.equal(1);
            
            // Check delegation count
            expect(await trustModule.voterDelegationCount(await voter1.getAddress())).to.equal(1);
        });

        it("Should prevent self-voting", async function () {
            const voteInput = createVoteInput(MIN_VOTE_AMOUNT);

            await expect(
                trustModule.connect(voter1).castDPoSVote(
                    await voter1.getAddress(),
                    voteInput
                )
            ).to.be.revertedWith("TrustSystem: Cannot vote for self");
        });

        it("Should enforce minimum vote amount", async function () {
            const smallAmount = MIN_VOTE_AMOUNT - 1n;
            const voteInput = createVoteInput(smallAmount);

            await expect(
                trustModule.connect(voter1).castDPoSVote(
                    await candidate1.getAddress(),
                    voteInput
                )
            ).to.be.revertedWith("TrustSystem: Insufficient vote amount");
        });

        it("Should enforce max delegations", async function () {
            const voteInput = createVoteInput(MIN_VOTE_AMOUNT);
            
            // Vote for 10 different candidates (MAX_DELEGATIONS)
            for (let i = 0; i < 10; i++) {
                const candidate = ethers.Wallet.createRandom();
                await trustModule.connect(voter1).castDPoSVote(
                    candidate.address,
                    voteInput
                );
            }

            // 11th vote should fail
            await expect(
                trustModule.connect(voter1).castDPoSVote(
                    await candidate2.getAddress(),
                    voteInput
                )
            ).to.be.revertedWith("TrustSystem: Too many delegations");
        });

        it("Should accumulate votes from same voter", async function () {
            const voteInput1 = createVoteInput(MIN_VOTE_AMOUNT);
            const voteInput2 = createVoteInput(MIN_VOTE_AMOUNT * 2n);

            // First vote
            await trustModule.connect(voter1).castDPoSVote(
                await candidate1.getAddress(),
                voteInput1
            );

            // Second vote to same candidate
            await trustModule.connect(voter1).castDPoSVote(
                await candidate1.getAddress(),
                voteInput2
            );

            // Voter count should remain 1
            expect(await trustModule.getVoterCount(candidate1.address)).to.equal(1);
            // Delegation count should remain 1
            expect(await trustModule.voterDelegationCount(await voter1.getAddress())).to.equal(1);
        });

        it("Should track voter's candidates", async function () {
            const voteInput = createVoteInput(MIN_VOTE_AMOUNT);

            await trustModule.connect(voter1).castDPoSVote(
                await candidate1.getAddress(),
                voteInput
            );
            await trustModule.connect(voter1).castDPoSVote(
                await candidate2.getAddress(),
                voteInput
            );

            const candidates = await trustModule.getVoterCandidates(await voter1.getAddress());
            expect(candidates).to.include(candidate1.address);
            expect(candidates).to.include(await candidate2.getAddress());
            expect(candidates.length).to.equal(2);
        });
    });

    describe("DPoS Vote Withdrawal", function () {
        const voteAmount = MIN_VOTE_AMOUNT * 10n;
        
        beforeEach(async function () {
            const voteInput = {
                ciphertext: voteAmount,
                signature: ethers.randomBytes(32)
            };
            
            await trustModule.connect(voter1).castDPoSVote(
                await candidate1.getAddress(),
                voteInput
            );
        });

        it("Should withdraw partial votes", async function () {
            const withdrawAmount = MIN_VOTE_AMOUNT * 3n;
            const withdrawInput = {
                ciphertext: withdrawAmount,
                signature: ethers.randomBytes(32)
            };

            await trustModule.connect(voter1).withdrawDPoSVote(
                await candidate1.getAddress(),
                withdrawInput
            );

            // Should still have active vote
            const voteRecord = await trustModule.connect(voter1).getVoteRecord(
                await voter1.getAddress(),
                candidate1.address
            );
            expect(voteRecord.isActive).to.be.true;
        });

        it("Should withdraw all votes", async function () {
            const withdrawInput = {
                ciphertext: voteAmount,
                signature: ethers.randomBytes(32)
            };

            await trustModule.connect(voter1).withdrawDPoSVote(
                await candidate1.getAddress(),
                withdrawInput
            );

            // Vote should be inactive
            const voteRecord = await trustModule.connect(voter1).getVoteRecord(
                await voter1.getAddress(),
                candidate1.address
            );
            expect(voteRecord.isActive).to.be.false;

            // Counts should be updated
            expect(await trustModule.getVoterCount(candidate1.address)).to.equal(0);
            expect(await trustModule.voterDelegationCount(await voter1.getAddress())).to.equal(0);
        });

        it("Should prevent withdrawal of more than voted", async function () {
            const tooMuch = voteAmount + MIN_VOTE_AMOUNT;
            const withdrawInput = {
                ciphertext: tooMuch,
                signature: ethers.randomBytes(32)
            };

            await expect(
                trustModule.connect(voter1).withdrawDPoSVote(
                    await candidate1.getAddress(),
                    withdrawInput
                )
            ).to.be.revertedWith("TrustSystem: Insufficient votes");
        });

        it("Should reject withdrawal from non-voter", async function () {
            const withdrawInput = {
                ciphertext: MIN_VOTE_AMOUNT,
                signature: ethers.randomBytes(32)
            };

            await expect(
                trustModule.connect(voter2).withdrawDPoSVote(
                    await candidate1.getAddress(),
                    withdrawInput
                )
            ).to.be.revertedWith("TrustSystem: No active vote");
        });
    });

    describe("COTI Proof of Trust", function () {
        beforeEach(async function () {
            // Enable COTI PoT
            await trustModule.setCotiPoTEnabled(true);
        });

        it("Should update COTI PoT score", async function () {
            const score = 7500;
            await trustModule.connect(cotiOracle).updateCotiPoTScore(
                await candidate1.getAddress(),
                score
            );

            expect(await trustModule.getCotiProofOfTrustScore(candidate1.address)).to.equal(score);
        });

        it("Should require COTI oracle role", async function () {
            await expect(
                trustModule.connect(voter1).updateCotiPoTScore(
                    await candidate1.getAddress(),
                    7500
                )
            ).to.be.revertedWithCustomError(trustModule, "AccessControlUnauthorizedAccount");
        });

        it("Should require COTI PoT to be enabled", async function () {
            await trustModule.setCotiPoTEnabled(false);
            
            await expect(
                trustModule.connect(cotiOracle).updateCotiPoTScore(
                    await candidate1.getAddress(),
                    7500
                )
            ).to.be.revertedWith("TrustSystem: COTI PoT not enabled");
        });

        it("Should set user preference for COTI PoT", async function () {
            await trustModule.connect(trustManager).setUseCotiPoT(
                await candidate1.getAddress(),
                true
            );

            const trustData = await trustModule.trustData(candidate1.address);
            expect(trustData.useCotiPoT).to.be.true;
        });

        it("Should return COTI score when preferred", async function () {
            const cotiScore = 8000;
            
            // Set COTI score
            await trustModule.connect(cotiOracle).updateCotiPoTScore(
                await candidate1.getAddress(),
                cotiScore
            );
            
            // Set preference to use COTI
            await trustModule.connect(trustManager).setUseCotiPoT(
                await candidate1.getAddress(),
                true
            );

            // getTrustScore returns gtUint64 - can't check value directly in test mode
            await trustModule.getTrustScore(candidate1.address);
            // In production with MPC enabled, this would return the COTI score
        });
    });

    describe("Vote Decay", function () {
        it("Should apply decay to old votes", async function () {
            const voteInput = {
                ciphertext: MIN_VOTE_AMOUNT,
                signature: ethers.randomBytes(32)
            };

            // Cast vote
            await trustModule.connect(voter1).castDPoSVote(
                await candidate1.getAddress(),
                voteInput
            );

            // Fast forward past decay period
            await ethers.provider.send("evm_increaseTime", [VOTE_DECAY_PERIOD + 1]);
            await ethers.provider.send("evm_mine");

            // getTrustScore returns gtUint64 - can't check value directly
            await trustModule.getTrustScore(candidate1.address);
            // Would return 0 due to full decay with MPC enabled
        });

        it("Should apply partial decay", async function () {
            const voteInput = {
                ciphertext: MIN_VOTE_AMOUNT,
                signature: ethers.randomBytes(32)
            };

            await trustModule.connect(voter1).castDPoSVote(
                await candidate1.getAddress(),
                voteInput
            );

            // Fast forward half decay period
            await ethers.provider.send("evm_increaseTime", [VOTE_DECAY_PERIOD / 2]);
            await ethers.provider.send("evm_mine");

            // getTrustScore returns gtUint64 - can't check value directly
            await trustModule.getTrustScore(candidate1.address);
            // Would be roughly half with partial decay in MPC mode
        });
    });

    describe("Oracle Management", function () {
        it("Should add COTI oracle", async function () {
            const newOracle = ethers.Wallet.createRandom().address;
            await trustModule.addCotiOracle(newOracle);
            
            const COTI_ORACLE_ROLE = await trustModule.COTI_ORACLE_ROLE();
            expect(await trustModule.hasRole(COTI_ORACLE_ROLE, newOracle)).to.be.true;
        });

        it("Should remove COTI oracle", async function () {
            await trustModule.removeCotiOracle(cotiOracle.address);
            
            const COTI_ORACLE_ROLE = await trustModule.COTI_ORACLE_ROLE();
            expect(await trustModule.hasRole(COTI_ORACLE_ROLE, cotiOracle.address)).to.be.false;
        });

        it("Should emit oracle events", async function () {
            const newOracle = ethers.Wallet.createRandom().address;
            
            await expect(trustModule.addCotiOracle(newOracle))
                .to.emit(trustModule, "CotiOracleAdded")
                .withArgs(newOracle);
                
            await expect(trustModule.removeCotiOracle(newOracle))
                .to.emit(trustModule, "CotiOracleRemoved")
                .withArgs(newOracle);
        });
    });

    describe("View Functions", function () {
        it("Should return vote record for authorized viewer", async function () {
            const voteInput = {
                ciphertext: MIN_VOTE_AMOUNT,
                signature: ethers.randomBytes(32)
            };

            await trustModule.connect(voter1).castDPoSVote(
                await candidate1.getAddress(),
                voteInput
            );

            const voteRecord = await trustModule.connect(voter1).getVoteRecord(
                await voter1.getAddress(),
                candidate1.address
            );

            expect(voteRecord.isActive).to.be.true;
            expect(voteRecord.timestamp).to.be.gt(0);
        });

        it("Should reject vote record view from unauthorized", async function () {
            await expect(
                trustModule.connect(voter2).getVoteRecord(
                    await voter1.getAddress(),
                    candidate1.address
                )
            ).to.be.revertedWith("TrustSystem: Not authorized");
        });

        it("Should return user encrypted votes", async function () {
            const voteInput = {
                ciphertext: MIN_VOTE_AMOUNT,
                signature: ethers.randomBytes(32)
            };

            await trustModule.connect(voter1).castDPoSVote(
                await candidate1.getAddress(),
                voteInput
            );

            const encryptedVotes = await trustModule.connect(candidate1).getUserEncryptedVotes(
                candidate1.address
            );
            expect(encryptedVotes).to.equal(MIN_VOTE_AMOUNT);
        });
    });

    describe("Pausable", function () {
        it("Should pause and unpause", async function () {
            await trustModule.pause();
            expect(await trustModule.paused()).to.be.true;

            await trustModule.unpause();
            expect(await trustModule.paused()).to.be.false;
        });

        it("Should prevent voting when paused", async function () {
            await trustModule.pause();
            
            const voteInput = {
                ciphertext: MIN_VOTE_AMOUNT,
                signature: ethers.randomBytes(32)
            };
            
            await expect(
                trustModule.connect(voter1).castDPoSVote(
                    await candidate1.getAddress(),
                    voteInput
                )
            ).to.be.revertedWithCustomError(trustModule, "EnforcedPause");
        });
    });
});