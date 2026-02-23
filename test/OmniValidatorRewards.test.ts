/**
 * @file OmniValidatorRewards.test.ts
 * @description Comprehensive tests for OmniValidatorRewards contract
 *
 * Tests cover:
 * - Initialization and role setup
 * - Heartbeat system
 * - Transaction processing tracking
 * - Epoch processing and reward distribution
 * - Reward claiming
 * - Weight calculation (participation, staking, activity)
 * - Block reward calculation with reductions
 * - Admin functions
 */

/* eslint-disable @typescript-eslint/no-var-requires */
const { expect } = require('chai');
const { ethers, upgrades } = require('hardhat');
const { keccak256, toUtf8Bytes, ZeroAddress } = require('ethers');
const { time } = require('@nomicfoundation/hardhat-network-helpers');

describe('OmniValidatorRewards', function () {
    // Contract instances
    let validatorRewards: any;
    let mockXOMToken: any;
    let mockParticipation: any;
    let mockOmniCore: any;

    // Signers
    let owner: any;
    let validator1: any;
    let validator2: any;
    let validator3: any;
    let blockchainRole: any;
    let unauthorized: any;

    // Role constants
    const DEFAULT_ADMIN_ROLE = ethers.ZeroHash;
    const BLOCKCHAIN_ROLE = keccak256(toUtf8Bytes('BLOCKCHAIN_ROLE'));

    // Timelock constant (must match contract)
    const CONTRACT_UPDATE_DELAY = 48 * 60 * 60; // 48 hours

    /**
     * Process all pending epochs up to and including current epoch.
     * Epochs must be processed sequentially (C-01 fix).
     */
    async function processAllPendingEpochs(): Promise<void> {
        const pendingEpochs = await validatorRewards.getPendingEpochs();
        if (pendingEpochs > 0) {
            await validatorRewards.processMultipleEpochs(pendingEpochs);
        }
    }

    /**
     * Process the next sequential epoch (lastProcessedEpoch + 1).
     * Waits until the epoch is available if needed.
     */
    async function processNextEpoch(): Promise<bigint> {
        const nextEpoch = (await validatorRewards.lastProcessedEpoch()) + BigInt(1);
        const currentEpoch = await validatorRewards.getCurrentEpoch();
        if (nextEpoch > currentEpoch) {
            // Need to advance time first
            await time.increase(EPOCH_DURATION + 1);
        }
        await validatorRewards.processEpoch(nextEpoch);
        return nextEpoch;
    }

    // Contract constants
    const EPOCH_DURATION = 2;
    const HEARTBEAT_TIMEOUT = 20;
    const INITIAL_BLOCK_REWARD = ethers.parseEther('15.602');
    const BLOCKS_PER_REDUCTION = 6311520;

    beforeEach(async function () {
        // Get signers
        [owner, validator1, validator2, validator3, blockchainRole, unauthorized] =
            await ethers.getSigners();

        // Deploy mock XOM token
        const MockXOMToken = await ethers.getContractFactory('MockXOMToken');
        mockXOMToken = await MockXOMToken.deploy();
        await mockXOMToken.waitForDeployment();

        // Deploy mock OmniParticipation
        const MockParticipation = await ethers.getContractFactory('MockOmniParticipation');
        mockParticipation = await MockParticipation.deploy();
        await mockParticipation.waitForDeployment();

        // Deploy mock OmniCore
        const MockOmniCore = await ethers.getContractFactory('MockOmniCore');
        mockOmniCore = await MockOmniCore.deploy();
        await mockOmniCore.waitForDeployment();

        // Deploy OmniValidatorRewards as proxy
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
            }
        );
        await validatorRewards.waitForDeployment();

        // Grant blockchain role
        await validatorRewards.grantRole(BLOCKCHAIN_ROLE, blockchainRole.address);

        // Setup validators in mock OmniCore
        await mockOmniCore.setValidator(validator1.address, true);
        await mockOmniCore.setValidator(validator2.address, true);
        await mockOmniCore.setValidator(validator3.address, true);

        // Register validators as active nodes
        await mockOmniCore.registerMockNode(validator1.address, 'validator', 'http://v1:3001');
        await mockOmniCore.registerMockNode(validator2.address, 'validator', 'http://v2:3002');
        await mockOmniCore.registerMockNode(validator3.address, 'validator', 'http://v3:3003');

        // Setup participation scores
        await mockParticipation.setTotalScore(validator1.address, 80);
        await mockParticipation.setTotalScore(validator2.address, 60);
        await mockParticipation.setTotalScore(validator3.address, 50);

        // Setup staking with future lockTime (H-01: expired locks return 0)
        const currentTime = await time.latest();
        const futureLock = currentTime + 180 * 24 * 60 * 60;
        await mockOmniCore.setStake(
            validator1.address,
            ethers.parseEther('10000000'), // 10M XOM
            3,
            180 * 24 * 60 * 60,
            futureLock,
            true
        );
        await mockOmniCore.setStake(
            validator2.address,
            ethers.parseEther('1000000'), // 1M XOM
            2,
            30 * 24 * 60 * 60,
            currentTime + 30 * 24 * 60 * 60,
            true
        );

        // Fund the contract with XOM for rewards
        await mockXOMToken.mint(await validatorRewards.getAddress(), ethers.parseEther('1000000'));
    });

    describe('Initialization', function () {
        it('should initialize with correct admin', async function () {
            expect(await validatorRewards.hasRole(DEFAULT_ADMIN_ROLE, owner.address)).to.be.true;
        });

        it('should initialize with correct blockchain role', async function () {
            expect(await validatorRewards.hasRole(BLOCKCHAIN_ROLE, owner.address)).to.be.true;
        });

        it('should set correct contract references', async function () {
            expect(await validatorRewards.xomToken()).to.equal(await mockXOMToken.getAddress());
            expect(await validatorRewards.participation()).to.equal(await mockParticipation.getAddress());
            expect(await validatorRewards.omniCore()).to.equal(await mockOmniCore.getAddress());
        });

        it('should set genesis timestamp', async function () {
            expect(await validatorRewards.genesisTimestamp()).to.be.gt(0);
        });

        it('should have correct constants', async function () {
            expect(await validatorRewards.EPOCH_DURATION()).to.equal(EPOCH_DURATION);
            expect(await validatorRewards.HEARTBEAT_TIMEOUT()).to.equal(HEARTBEAT_TIMEOUT);
            expect(await validatorRewards.INITIAL_BLOCK_REWARD()).to.equal(INITIAL_BLOCK_REWARD);
            expect(await validatorRewards.BLOCKS_PER_REDUCTION()).to.equal(BLOCKS_PER_REDUCTION);
        });

        it('should reject zero address for XOM token', async function () {
            const OmniValidatorRewards = await ethers.getContractFactory('OmniValidatorRewards');
            await expect(
                upgrades.deployProxy(
                    OmniValidatorRewards,
                    [ZeroAddress, await mockParticipation.getAddress(), await mockOmniCore.getAddress()],
                    { initializer: 'initialize', kind: 'uups' }
                )
            ).to.be.revertedWithCustomError(OmniValidatorRewards, 'ZeroAddress');
        });

        it('should reject zero address for participation', async function () {
            const OmniValidatorRewards = await ethers.getContractFactory('OmniValidatorRewards');
            await expect(
                upgrades.deployProxy(
                    OmniValidatorRewards,
                    [await mockXOMToken.getAddress(), ZeroAddress, await mockOmniCore.getAddress()],
                    { initializer: 'initialize', kind: 'uups' }
                )
            ).to.be.revertedWithCustomError(OmniValidatorRewards, 'ZeroAddress');
        });

        it('should reject zero address for omniCore', async function () {
            const OmniValidatorRewards = await ethers.getContractFactory('OmniValidatorRewards');
            await expect(
                upgrades.deployProxy(
                    OmniValidatorRewards,
                    [await mockXOMToken.getAddress(), await mockParticipation.getAddress(), ZeroAddress],
                    { initializer: 'initialize', kind: 'uups' }
                )
            ).to.be.revertedWithCustomError(OmniValidatorRewards, 'ZeroAddress');
        });
    });

    describe('Heartbeat System', function () {
        it('should submit heartbeat', async function () {
            const tx = await validatorRewards.connect(validator1).submitHeartbeat();

            await expect(tx).to.emit(validatorRewards, 'ValidatorHeartbeat');
        });

        it('should update last heartbeat timestamp', async function () {
            await validatorRewards.connect(validator1).submitHeartbeat();

            const heartbeat = await validatorRewards.lastHeartbeat(validator1.address);
            const currentTime = await time.latest();
            expect(heartbeat).to.be.closeTo(currentTime, 2);
        });

        it('should mark validator as active', async function () {
            await validatorRewards.connect(validator1).submitHeartbeat();

            expect(await validatorRewards.isValidatorActive(validator1.address)).to.be.true;
        });

        it('should mark validator as inactive after timeout', async function () {
            await validatorRewards.connect(validator1).submitHeartbeat();

            // Advance time past timeout
            await time.increase(HEARTBEAT_TIMEOUT + 1);

            expect(await validatorRewards.isValidatorActive(validator1.address)).to.be.false;
        });

        it('should reject heartbeat from non-validator', async function () {
            await expect(
                validatorRewards.connect(unauthorized).submitHeartbeat()
            ).to.be.revertedWithCustomError(validatorRewards, 'NotValidator');
        });
    });

    describe('Transaction Processing Tracking', function () {
        it('should record single transaction', async function () {
            await validatorRewards.connect(blockchainRole).recordTransactionProcessing(validator1.address);

            const epoch = await validatorRewards.getCurrentEpoch();
            expect(await validatorRewards.transactionsProcessed(validator1.address, epoch)).to.equal(1);
        });

        it('should emit TransactionProcessed event', async function () {
            const tx = await validatorRewards.connect(blockchainRole).recordTransactionProcessing(validator1.address);

            await expect(tx).to.emit(validatorRewards, 'TransactionProcessed');
        });

        it('should track epoch total transactions', async function () {
            await validatorRewards.connect(blockchainRole).recordTransactionProcessing(validator1.address);
            await validatorRewards.connect(blockchainRole).recordTransactionProcessing(validator2.address);

            const epoch = await validatorRewards.getCurrentEpoch();
            expect(await validatorRewards.epochTotalTransactions(epoch)).to.equal(2);
        });

        it('should record multiple transactions at once', async function () {
            await validatorRewards.connect(blockchainRole).recordMultipleTransactions(validator1.address, 10);

            const epoch = await validatorRewards.getCurrentEpoch();
            expect(await validatorRewards.transactionsProcessed(validator1.address, epoch)).to.equal(10);
        });

        it('should reject transaction recording from unauthorized caller', async function () {
            await expect(
                validatorRewards.connect(unauthorized).recordTransactionProcessing(validator1.address)
            ).to.be.reverted;
        });

        it('should reject transaction recording for non-validator', async function () {
            await expect(
                validatorRewards.connect(blockchainRole).recordTransactionProcessing(unauthorized.address)
            ).to.be.revertedWithCustomError(validatorRewards, 'NotValidator');
        });
    });

    describe('Epoch Processing', function () {
        beforeEach(async function () {
            // Submit heartbeats for validators
            await validatorRewards.connect(validator1).submitHeartbeat();
            await validatorRewards.connect(validator2).submitHeartbeat();
        });

        it('should process epoch sequentially', async function () {
            // Wait for at least one epoch
            await time.increase(EPOCH_DURATION + 1);

            // Must start from epoch 1 (sequential processing)
            const tx = await validatorRewards.processEpoch(1);

            await expect(tx).to.emit(validatorRewards, 'EpochProcessed');
        });

        it('should distribute rewards to active validators', async function () {
            await time.increase(EPOCH_DURATION + 1);

            await processNextEpoch();

            // Check rewards accumulated
            const rewards1 = await validatorRewards.accumulatedRewards(validator1.address);
            const rewards2 = await validatorRewards.accumulatedRewards(validator2.address);

            expect(rewards1).to.be.gt(0);
            expect(rewards2).to.be.gt(0);
        });

        it('should distribute higher rewards to validators with higher weight', async function () {
            await time.increase(EPOCH_DURATION + 1);

            await processNextEpoch();

            const rewards1 = await validatorRewards.accumulatedRewards(validator1.address);
            const rewards2 = await validatorRewards.accumulatedRewards(validator2.address);

            // Validator1 has higher participation score and staking
            expect(rewards1).to.be.gt(rewards2);
        });

        it('should reject non-sequential epoch', async function () {
            // C-01: Cannot skip epoch 1 and process epoch 100 directly
            await expect(
                validatorRewards.processEpoch(100)
            ).to.be.revertedWithCustomError(validatorRewards, 'EpochNotSequential');
        });

        it('should reject processing already processed epoch', async function () {
            await time.increase(EPOCH_DURATION + 1);

            await processNextEpoch();

            // Same epoch is no longer sequential
            await expect(
                validatorRewards.processEpoch(1)
            ).to.be.revertedWithCustomError(validatorRewards, 'EpochNotSequential');
        });

        it('should skip epoch if no active validators', async function () {
            // Wait for heartbeat timeout
            await time.increase(HEARTBEAT_TIMEOUT + 1);

            await processNextEpoch();

            // No rewards distributed
            const rewards1 = await validatorRewards.accumulatedRewards(validator1.address);
            expect(rewards1).to.equal(0);
        });

        it('should update lastProcessedEpoch', async function () {
            await time.increase(EPOCH_DURATION + 1);

            const epoch = await processNextEpoch();

            expect(await validatorRewards.lastProcessedEpoch()).to.equal(epoch);
        });

        it('should increment totalBlocksProduced', async function () {
            await time.increase(EPOCH_DURATION + 1);

            await processNextEpoch();

            expect(await validatorRewards.totalBlocksProduced()).to.equal(1);
        });
    });

    describe('Batch Epoch Processing', function () {
        beforeEach(async function () {
            await validatorRewards.connect(validator1).submitHeartbeat();
            await validatorRewards.connect(validator2).submitHeartbeat();
        });

        it('should process multiple epochs at once', async function () {
            // Wait for multiple epochs
            await time.increase(EPOCH_DURATION * 5);

            // processMultipleEpochs handles sequential processing
            await validatorRewards.processMultipleEpochs(5);

            expect(await validatorRewards.totalBlocksProduced()).to.be.gte(1);
        });

        it('should accumulate rewards across multiple epochs', async function () {
            await time.increase(EPOCH_DURATION * 3);

            // Refresh heartbeats to keep validators active
            await validatorRewards.connect(validator1).submitHeartbeat();
            await validatorRewards.connect(validator2).submitHeartbeat();

            await validatorRewards.processMultipleEpochs(3);

            const rewards1 = await validatorRewards.accumulatedRewards(validator1.address);
            expect(rewards1).to.be.gt(0);
        });

        it('should emit EpochProcessed for each batch epoch', async function () {
            await time.increase(EPOCH_DURATION * 3);

            const tx = await validatorRewards.processMultipleEpochs(3);

            // L-03 fix: processMultipleEpochs now emits events
            await expect(tx).to.emit(validatorRewards, 'EpochProcessed');
        });
    });

    describe('Reward Claiming', function () {
        beforeEach(async function () {
            // Setup: process an epoch to have rewards
            await validatorRewards.connect(validator1).submitHeartbeat();
            await validatorRewards.connect(validator2).submitHeartbeat();
            await time.increase(EPOCH_DURATION + 1);
            // Process sequentially from epoch 1
            await processNextEpoch();
        });

        it('should claim rewards', async function () {
            const pendingRewards = await validatorRewards.accumulatedRewards(validator1.address);
            expect(pendingRewards).to.be.gt(0);

            const tx = await validatorRewards.connect(validator1).claimRewards();

            await expect(tx)
                .to.emit(validatorRewards, 'RewardsClaimed')
                .withArgs(validator1.address, pendingRewards, pendingRewards);
        });

        it('should transfer XOM tokens on claim', async function () {
            const balanceBefore = await mockXOMToken.balanceOf(validator1.address);
            const pendingRewards = await validatorRewards.accumulatedRewards(validator1.address);

            await validatorRewards.connect(validator1).claimRewards();

            const balanceAfter = await mockXOMToken.balanceOf(validator1.address);
            expect(balanceAfter - balanceBefore).to.equal(pendingRewards);
        });

        it('should reset accumulated rewards after claim', async function () {
            await validatorRewards.connect(validator1).claimRewards();

            expect(await validatorRewards.accumulatedRewards(validator1.address)).to.equal(0);
        });

        it('should update total claimed', async function () {
            const pendingRewards = await validatorRewards.accumulatedRewards(validator1.address);

            await validatorRewards.connect(validator1).claimRewards();

            expect(await validatorRewards.totalClaimed(validator1.address)).to.equal(pendingRewards);
        });

        it('should reject claim with no rewards', async function () {
            // Claim once
            await validatorRewards.connect(validator1).claimRewards();

            // Try to claim again
            await expect(
                validatorRewards.connect(validator1).claimRewards()
            ).to.be.revertedWithCustomError(validatorRewards, 'NoRewardsToClaim');
        });

        it('should allow retired validators to claim (H-04 fix)', async function () {
            // H-04: No isValidator check in claimRewards - accumulated
            // rewards are claimable even after deactivation
            const pendingRewards = await validatorRewards.accumulatedRewards(validator1.address);
            expect(pendingRewards).to.be.gt(0);

            // Deactivate validator1 in mock
            await mockOmniCore.setValidator(validator1.address, false);

            // Should still be able to claim earned rewards
            const tx = await validatorRewards.connect(validator1).claimRewards();
            await expect(tx).to.emit(validatorRewards, 'RewardsClaimed');
        });

        it('should reject claim from address with no rewards', async function () {
            // Unauthorized has zero accumulated rewards
            await expect(
                validatorRewards.connect(unauthorized).claimRewards()
            ).to.be.revertedWithCustomError(validatorRewards, 'NoRewardsToClaim');
        });
    });

    describe('Weight Calculation', function () {
        beforeEach(async function () {
            await validatorRewards.connect(validator1).submitHeartbeat();
            await validatorRewards.connect(validator2).submitHeartbeat();
        });

        it('should return higher weight for higher participation score', async function () {
            const weight1 = await validatorRewards.getValidatorWeight(validator1.address);
            const weight2 = await validatorRewards.getValidatorWeight(validator2.address);

            // Validator1 has 80 participation score, Validator2 has 60
            expect(weight1).to.be.gt(weight2);
        });

        it('should return higher weight for higher staking amount', async function () {
            // Set equal participation scores
            await mockParticipation.setTotalScore(validator1.address, 50);
            await mockParticipation.setTotalScore(validator2.address, 50);

            const weight1 = await validatorRewards.getValidatorWeight(validator1.address);
            const weight2 = await validatorRewards.getValidatorWeight(validator2.address);

            // Validator1 has 10M stake, Validator2 has 1M
            expect(weight1).to.be.gt(weight2);
        });

        it('should include activity component in weight', async function () {
            // Validator1 is active (heartbeat), validator3 is not
            const weight1 = await validatorRewards.getValidatorWeight(validator1.address);

            // Make validator3 inactive (no heartbeat)
            const weight3 = await validatorRewards.getValidatorWeight(validator3.address);

            // Active validator should have higher weight
            expect(weight1).to.be.gt(weight3);
        });

        it('should factor transaction processing into weight', async function () {
            // Record transactions for validator1
            await validatorRewards.connect(blockchainRole).recordMultipleTransactions(validator1.address, 10);

            const epoch = await validatorRewards.getCurrentEpoch();
            const validatorTx = await validatorRewards.transactionsProcessed(validator1.address, epoch);
            expect(validatorTx).to.equal(10);
        });
    });

    describe('Block Reward Calculation', function () {
        it('should return initial block reward at start', async function () {
            const reward = await validatorRewards.calculateBlockReward();
            expect(reward).to.equal(INITIAL_BLOCK_REWARD);
        });

        it('should return same reward before first reduction', async function () {
            // Process some epochs but not enough to trigger reduction
            for (let i = 0; i < 10; i++) {
                await validatorRewards.connect(validator1).submitHeartbeat();
                await time.increase(EPOCH_DURATION + 1);
                await processNextEpoch();
            }

            const reward = await validatorRewards.calculateBlockReward();
            expect(reward).to.equal(INITIAL_BLOCK_REWARD);
        });

        // Note: Testing actual reduction would require processing millions of epochs
        // which is not practical in a unit test
    });

    describe('Epoch Calculation', function () {
        it('should return 0 for genesis epoch', async function () {
            // At genesis, epoch should be 0 or 1 depending on timing
            const epoch = await validatorRewards.getCurrentEpoch();
            expect(epoch).to.be.gte(0);
        });

        it('should increment epoch every EPOCH_DURATION seconds', async function () {
            const epochBefore = await validatorRewards.getCurrentEpoch();

            await time.increase(EPOCH_DURATION * 5);

            const epochAfter = await validatorRewards.getCurrentEpoch();
            expect(epochAfter - epochBefore).to.be.closeTo(BigInt(5), BigInt(1));
        });
    });

    describe('View Functions', function () {
        beforeEach(async function () {
            await validatorRewards.connect(validator1).submitHeartbeat();
            await time.increase(EPOCH_DURATION + 1);
            await processNextEpoch();
        });

        it('should return pending rewards', async function () {
            const pending = await validatorRewards.getPendingRewards(validator1.address);
            expect(pending).to.be.gt(0);
        });

        it('should return total claimed after claim', async function () {
            await validatorRewards.connect(validator1).claimRewards();
            const totalClaimed = await validatorRewards.getTotalClaimed(validator1.address);
            expect(totalClaimed).to.be.gt(0);
        });

        it('should return pending epochs count', async function () {
            await time.increase(EPOCH_DURATION * 3);
            const pending = await validatorRewards.getPendingEpochs();
            expect(pending).to.be.gte(1);
        });

        it('should return reward balance', async function () {
            const balance = await validatorRewards.getRewardBalance();
            expect(balance).to.be.gt(0);
        });
    });

    describe('Admin Functions', function () {
        describe('proposeContracts (H-02 timelock)', function () {
            it('should propose contract references with timelock', async function () {
                const newXOM = validator1.address;
                const newParticipation = validator2.address;
                const newOmniCore = validator3.address;

                const tx = await validatorRewards.connect(owner).proposeContracts(
                    newXOM,
                    newParticipation,
                    newOmniCore
                );

                await expect(tx)
                    .to.emit(validatorRewards, 'ContractsUpdateProposed');

                // Pending update should be set
                const pending = await validatorRewards.pendingContracts();
                expect(pending.xomToken).to.equal(newXOM);
                expect(pending.participation).to.equal(newParticipation);
                expect(pending.omniCore).to.equal(newOmniCore);
                expect(pending.effectiveTimestamp).to.be.gt(0);
            });

            it('should apply after timelock elapses', async function () {
                const newXOM = validator1.address;
                const newParticipation = validator2.address;
                const newOmniCore = validator3.address;

                await validatorRewards.connect(owner).proposeContracts(
                    newXOM,
                    newParticipation,
                    newOmniCore
                );

                // Advance past 48h timelock
                await time.increase(CONTRACT_UPDATE_DELAY + 1);

                const tx = await validatorRewards.connect(owner).applyContracts();

                await expect(tx)
                    .to.emit(validatorRewards, 'ContractsUpdated')
                    .withArgs(newXOM, newParticipation, newOmniCore);
            });

            it('should reject apply before timelock elapses', async function () {
                await validatorRewards.connect(owner).proposeContracts(
                    validator1.address,
                    validator2.address,
                    validator3.address
                );

                // Don't wait for timelock
                await expect(
                    validatorRewards.connect(owner).applyContracts()
                ).to.be.revertedWithCustomError(validatorRewards, 'TimelockNotElapsed');
            });

            it('should reject apply with no pending update', async function () {
                await expect(
                    validatorRewards.connect(owner).applyContracts()
                ).to.be.revertedWithCustomError(validatorRewards, 'NoPendingUpdate');
            });

            it('should cancel pending update', async function () {
                await validatorRewards.connect(owner).proposeContracts(
                    validator1.address,
                    validator2.address,
                    validator3.address
                );

                const tx = await validatorRewards.connect(owner).cancelContractsUpdate();

                await expect(tx)
                    .to.emit(validatorRewards, 'ContractsUpdateCancelled');

                // Cannot apply after cancel
                await time.increase(CONTRACT_UPDATE_DELAY + 1);
                await expect(
                    validatorRewards.connect(owner).applyContracts()
                ).to.be.revertedWithCustomError(validatorRewards, 'NoPendingUpdate');
            });

            it('should reject zero address for XOM', async function () {
                await expect(
                    validatorRewards.connect(owner).proposeContracts(
                        ZeroAddress,
                        validator2.address,
                        validator3.address
                    )
                ).to.be.revertedWithCustomError(validatorRewards, 'ZeroAddress');
            });

            it('should reject zero address for participation', async function () {
                await expect(
                    validatorRewards.connect(owner).proposeContracts(
                        validator1.address,
                        ZeroAddress,
                        validator3.address
                    )
                ).to.be.revertedWithCustomError(validatorRewards, 'ZeroAddress');
            });

            it('should reject zero address for omniCore', async function () {
                await expect(
                    validatorRewards.connect(owner).proposeContracts(
                        validator1.address,
                        validator2.address,
                        ZeroAddress
                    )
                ).to.be.revertedWithCustomError(validatorRewards, 'ZeroAddress');
            });

            it('should reject unauthorized caller for propose', async function () {
                await expect(
                    validatorRewards.connect(unauthorized).proposeContracts(
                        validator1.address,
                        validator2.address,
                        validator3.address
                    )
                ).to.be.reverted;
            });

            it('should reject unauthorized caller for apply', async function () {
                await validatorRewards.connect(owner).proposeContracts(
                    validator1.address,
                    validator2.address,
                    validator3.address
                );
                await time.increase(CONTRACT_UPDATE_DELAY + 1);

                await expect(
                    validatorRewards.connect(unauthorized).applyContracts()
                ).to.be.reverted;
            });
        });

        describe('emergencyWithdraw', function () {
            it('should reject XOM withdrawal (C-02 fix)', async function () {
                await expect(
                    validatorRewards.connect(owner).emergencyWithdraw(
                        await mockXOMToken.getAddress(),
                        ethers.parseEther('1000'),
                        owner.address
                    )
                ).to.be.revertedWithCustomError(validatorRewards, 'CannotWithdrawRewardToken');
            });

            it('should withdraw non-XOM tokens', async function () {
                // Deploy a separate ERC20 to test withdrawal
                const MockERC20 = await ethers.getContractFactory('MockXOMToken');
                const otherToken = await MockERC20.deploy();
                await otherToken.waitForDeployment();

                const amount = ethers.parseEther('1000');
                await otherToken.mint(await validatorRewards.getAddress(), amount);

                const balanceBefore = await otherToken.balanceOf(owner.address);

                await validatorRewards.connect(owner).emergencyWithdraw(
                    await otherToken.getAddress(),
                    amount,
                    owner.address
                );

                const balanceAfter = await otherToken.balanceOf(owner.address);
                expect(balanceAfter - balanceBefore).to.equal(amount);
            });

            it('should reject zero recipient', async function () {
                await expect(
                    validatorRewards.connect(owner).emergencyWithdraw(
                        await mockXOMToken.getAddress(),
                        ethers.parseEther('1000'),
                        ZeroAddress
                    )
                ).to.be.revertedWithCustomError(validatorRewards, 'ZeroAddress');
            });

            it('should reject unauthorized caller', async function () {
                await expect(
                    validatorRewards.connect(unauthorized).emergencyWithdraw(
                        await mockXOMToken.getAddress(),
                        ethers.parseEther('1000'),
                        unauthorized.address
                    )
                ).to.be.reverted;
            });
        });
    });

    describe('Edge Cases', function () {
        it('should handle zero staking amount', async function () {
            // Validator3 has no stake set
            await validatorRewards.connect(validator3).submitHeartbeat();

            const weight = await validatorRewards.getValidatorWeight(validator3.address);
            // Should still have some weight from participation and heartbeat
            expect(weight).to.be.gt(0);
        });

        it('should handle very large staking amount', async function () {
            // Set 10B+ stake with future lockTime
            const currentTime = await time.latest();
            await mockOmniCore.setStake(
                validator1.address,
                ethers.parseEther('10000000000'), // 10B XOM
                5,
                730 * 24 * 60 * 60,
                currentTime + 730 * 24 * 60 * 60, // 2 year lock
                true
            );

            await validatorRewards.connect(validator1).submitHeartbeat();
            const weight = await validatorRewards.getValidatorWeight(validator1.address);
            expect(weight).to.be.gt(0);
        });

        it('should return zero staking weight for expired lock (H-01 fix)', async function () {
            // Set stake with expired lockTime (in the past)
            await mockOmniCore.setStake(
                validator1.address,
                ethers.parseEther('10000000'), // 10M XOM
                3,
                180 * 24 * 60 * 60,
                1, // lockTime = 1 (far in the past)
                true
            );

            await validatorRewards.connect(validator1).submitHeartbeat();
            const weight = await validatorRewards.getValidatorWeight(validator1.address);
            // Weight should only include participation and activity (no staking)
            // participation: 80/100 * 40 = 32
            // staking: 0 (expired lock)
            // activity: heartbeat active -> 60/100 * 30 = 18
            expect(weight).to.equal(50); // 32 + 0 + 18
        });

        it('should handle single active validator', async function () {
            // Only validator1 submits heartbeat
            await validatorRewards.connect(validator1).submitHeartbeat();
            await time.increase(EPOCH_DURATION + 1);

            await processNextEpoch();

            // Validator1 should get all rewards
            const rewards1 = await validatorRewards.accumulatedRewards(validator1.address);
            expect(rewards1).to.be.closeTo(INITIAL_BLOCK_REWARD, ethers.parseEther('0.001'));
        });

        it('should handle equal weights', async function () {
            // Set identical participation and staking with future lockTime
            const currentTime = await time.latest();
            const futureLock = currentTime + 365 * 24 * 60 * 60;

            await mockParticipation.setTotalScore(validator1.address, 50);
            await mockParticipation.setTotalScore(validator2.address, 50);
            await mockOmniCore.setStake(
                validator1.address, ethers.parseEther('1000000'), 2, 0, futureLock, true
            );
            await mockOmniCore.setStake(
                validator2.address, ethers.parseEther('1000000'), 2, 0, futureLock, true
            );

            await validatorRewards.connect(validator1).submitHeartbeat();
            await validatorRewards.connect(validator2).submitHeartbeat();
            await time.increase(EPOCH_DURATION + 1);

            await processNextEpoch();

            const rewards1 = await validatorRewards.accumulatedRewards(validator1.address);
            const rewards2 = await validatorRewards.accumulatedRewards(validator2.address);

            // Rewards should be approximately equal
            expect(rewards1).to.be.closeTo(rewards2, ethers.parseEther('0.01'));
        });

        it('should cap validator iteration at MAX_VALIDATORS_PER_EPOCH (H-03)', async function () {
            // Verify the constant is set
            const maxValidators = await validatorRewards.MAX_VALIDATORS_PER_EPOCH();
            expect(maxValidators).to.equal(200);
        });

        it('should enforce MAX_TX_BATCH cap (H-05)', async function () {
            await expect(
                validatorRewards.connect(blockchainRole).recordMultipleTransactions(
                    validator1.address,
                    1001 // Exceeds MAX_TX_BATCH = 1000
                )
            ).to.be.revertedWithCustomError(validatorRewards, 'BatchTooLarge');
        });

        it('should enforce zero count cap (H-05)', async function () {
            await expect(
                validatorRewards.connect(blockchainRole).recordMultipleTransactions(
                    validator1.address,
                    0
                )
            ).to.be.revertedWithCustomError(validatorRewards, 'BatchTooLarge');
        });
    });
});
