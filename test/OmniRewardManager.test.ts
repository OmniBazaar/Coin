/**
 * @file OmniRewardManager.test.ts
 * @description Comprehensive tests for OmniRewardManager contract
 *
 * Tests cover:
 * - Initialization and role setup
 * - Welcome bonus claims (with merkle proofs)
 * - Referral bonus distribution (two-level)
 * - First sale bonus claims
 * - Admin functions (merkle roots, pause/unpause)
 * - Pool depletion scenarios
 * - Access control
 * - Upgrade functionality
 */

/* eslint-disable @typescript-eslint/no-var-requires */
const { expect } = require('chai');
const { ethers, upgrades } = require('hardhat');
const { keccak256, solidityPacked, ZeroAddress } = require('ethers');
const { MerkleTree } = require('merkletreejs');

describe('OmniRewardManager', function () {
    // Contract instances
    let omniCoin: any;
    let rewardManager: any;

    // Signers
    let owner: any;
    let admin: any;
    let user1: any;
    let user2: any;
    let referrer: any;
    let secondLevelReferrer: any;
    let validator: any;
    let stakingPool: any;
    let oddao: any;
    let unauthorized: any;

    // Pool sizes (test amounts)
    const WELCOME_BONUS_POOL = ethers.parseEther('10000000');       // 10M XOM
    const REFERRAL_BONUS_POOL = ethers.parseEther('10000000');      // 10M XOM
    const FIRST_SALE_BONUS_POOL = ethers.parseEther('10000000');    // 10M XOM
    const TOTAL_POOL_SIZE = WELCOME_BONUS_POOL + REFERRAL_BONUS_POOL +
                           FIRST_SALE_BONUS_POOL;

    // Test amounts
    const WELCOME_BONUS_AMOUNT = ethers.parseEther('10000');    // 10,000 XOM
    const REFERRAL_PRIMARY = ethers.parseEther('2500');         // 2,500 XOM (70%)
    const REFERRAL_SECONDARY = ethers.parseEther('714');        // ~714 XOM (20%)
    const FIRST_SALE_AMOUNT = ethers.parseEther('500');         // 500 XOM

    // Role constants
    const DEFAULT_ADMIN_ROLE = ethers.ZeroHash;
    const BONUS_DISTRIBUTOR_ROLE = keccak256(ethers.toUtf8Bytes('BONUS_DISTRIBUTOR_ROLE'));
    const UPGRADER_ROLE = keccak256(ethers.toUtf8Bytes('UPGRADER_ROLE'));
    const PAUSER_ROLE = keccak256(ethers.toUtf8Bytes('PAUSER_ROLE'));

    // Pool types enum
    const PoolType = {
        WelcomeBonus: 0,
        ReferralBonus: 1,
        FirstSaleBonus: 2,
    };

    /**
     * Generate merkle tree and proof for a user/amount claim
     */
    function generateMerkleProof(
        user: string,
        amount: bigint,
        additionalLeaves: string[] = []
    ): { root: string; proof: string[] } {
        // Create leaf for the target user
        const leaf = keccak256(solidityPacked(['address', 'uint256'], [user, amount]));

        // Create additional leaves for a valid tree
        const leaves = [leaf, ...additionalLeaves.map((l: string) => keccak256(ethers.toUtf8Bytes(l)))];

        // Build merkle tree
        const tree = new MerkleTree(leaves, keccak256, { sortPairs: true });
        const root = tree.getHexRoot();
        const proof = tree.getHexProof(leaf);

        return { root, proof };
    }

    /**
     * Generate merkle proof for referral claims (4 parameters)
     */
    function generateReferralMerkleProof(
        referrerAddr: string,
        secondLevelAddr: string,
        primaryAmt: bigint,
        secondaryAmt: bigint,
        additionalLeaves: string[] = []
    ): { root: string; proof: string[] } {
        const leaf = keccak256(solidityPacked(
            ['address', 'address', 'uint256', 'uint256'],
            [referrerAddr, secondLevelAddr, primaryAmt, secondaryAmt]
        ));

        const leaves = [leaf, ...additionalLeaves.map((l: string) => keccak256(ethers.toUtf8Bytes(l)))];
        const tree = new MerkleTree(leaves, keccak256, { sortPairs: true });

        return {
            root: tree.getHexRoot(),
            proof: tree.getHexProof(leaf),
        };
    }

    beforeEach(async function () {
        // Get signers
        [
            owner, admin, user1, user2, referrer, secondLevelReferrer,
            validator, stakingPool, oddao, unauthorized
        ] = await ethers.getSigners();

        // Deploy OmniCoin
        const OmniCoinFactory = await ethers.getContractFactory('OmniCoin');
        omniCoin = await OmniCoinFactory.deploy(ethers.ZeroAddress);
        await omniCoin.waitForDeployment();

        // Initialize OmniCoin to mint initial supply to deployer
        await omniCoin.initialize();

        // Deploy OmniRewardManager proxy without initializer (M-02 balance check
        // requires tokens at the contract address before initialize is called).
        const OmniRewardManagerFactory = await ethers.getContractFactory('OmniRewardManager');
        const proxy = await upgrades.deployProxy(
            OmniRewardManagerFactory,
            [
                await omniCoin.getAddress(),
                WELCOME_BONUS_POOL,
                REFERRAL_BONUS_POOL,
                FIRST_SALE_BONUS_POOL,
                admin.address,
            ],
            {
                initializer: false,
                kind: 'uups',
                constructorArgs: [ethers.ZeroAddress],
            }
        );
        await proxy.waitForDeployment();

        rewardManager = OmniRewardManagerFactory.attach(await proxy.getAddress());

        // Transfer tokens to reward manager BEFORE initialization (M-02 audit fix)
        await omniCoin.transfer(await rewardManager.getAddress(), TOTAL_POOL_SIZE);

        // Now initialize the proxy with the required parameters
        await rewardManager.initialize(
            await omniCoin.getAddress(),
            WELCOME_BONUS_POOL,
            REFERRAL_BONUS_POOL,
            FIRST_SALE_BONUS_POOL,
            admin.address
        );

        // Grant operational roles to admin (audit M-02 reduced _setupRoles to only DEFAULT_ADMIN_ROLE)
        await rewardManager.connect(admin).grantRole(BONUS_DISTRIBUTOR_ROLE, admin.address);
        await rewardManager.connect(admin).grantRole(UPGRADER_ROLE, admin.address);
        await rewardManager.connect(admin).grantRole(PAUSER_ROLE, admin.address);
    });

    // ========================================
    // Initialization Tests
    // ========================================

    describe('Initialization', function () {
        it('should initialize with correct pool sizes', async function () {
            const [welcome, referral, firstSale] =
                await rewardManager.getPoolBalances();

            expect(welcome).to.equal(WELCOME_BONUS_POOL);
            expect(referral).to.equal(REFERRAL_BONUS_POOL);
            expect(firstSale).to.equal(FIRST_SALE_BONUS_POOL);
        });

        it('should set up all roles correctly', async function () {
            expect(await rewardManager.hasRole(DEFAULT_ADMIN_ROLE, admin.address)).to.be.true;
            expect(await rewardManager.hasRole(BONUS_DISTRIBUTOR_ROLE, admin.address)).to.be.true;
            expect(await rewardManager.hasRole(UPGRADER_ROLE, admin.address)).to.be.true;
            expect(await rewardManager.hasRole(PAUSER_ROLE, admin.address)).to.be.true;
        });

        it('should set OmniCoin address correctly', async function () {
            expect(await rewardManager.omniCoin()).to.equal(await omniCoin.getAddress());
        });

        it('should have correct total undistributed amount', async function () {
            const total = await rewardManager.getTotalUndistributed();
            expect(total).to.equal(TOTAL_POOL_SIZE);
        });

        it('should have zero distributed initially', async function () {
            const distributed = await rewardManager.getTotalDistributed();
            expect(distributed).to.equal(0);
        });

        it('should reject zero OmniCoin address', async function () {
            const OmniRewardManagerFactory = await ethers.getContractFactory('OmniRewardManager');

            await expect(
                upgrades.deployProxy(
                    OmniRewardManagerFactory,
                    [
                        ZeroAddress,
                        WELCOME_BONUS_POOL,
                        REFERRAL_BONUS_POOL,
                        FIRST_SALE_BONUS_POOL,
                        admin.address,
                    ],
                    { initializer: 'initialize', kind: 'uups', constructorArgs: [ethers.ZeroAddress] }
                )
            ).to.be.revertedWithCustomError(rewardManager, 'ZeroAddressNotAllowed');
        });

        it('should reject zero admin address', async function () {
            const OmniRewardManagerFactory = await ethers.getContractFactory('OmniRewardManager');

            await expect(
                upgrades.deployProxy(
                    OmniRewardManagerFactory,
                    [
                        await omniCoin.getAddress(),
                        WELCOME_BONUS_POOL,
                        REFERRAL_BONUS_POOL,
                        FIRST_SALE_BONUS_POOL,
                        ZeroAddress,
                    ],
                    { initializer: 'initialize', kind: 'uups', constructorArgs: [ethers.ZeroAddress] }
                )
            ).to.be.revertedWithCustomError(rewardManager, 'ZeroAddressNotAllowed');
        });

        it('should prevent double initialization', async function () {
            await expect(
                rewardManager.initialize(
                    await omniCoin.getAddress(),
                    WELCOME_BONUS_POOL,
                    REFERRAL_BONUS_POOL,
                    FIRST_SALE_BONUS_POOL,
                    admin.address
                )
            ).to.be.revertedWithCustomError(rewardManager, 'InvalidInitialization');
        });
    });

    // ========================================
    // Welcome Bonus Tests
    // ========================================

    describe('Welcome Bonus', function () {
        let merkleRoot: string;
        let merkleProof: string[];

        beforeEach(async function () {
            // Generate merkle tree for user1's welcome bonus
            const result = generateMerkleProof(
                user1.address,
                WELCOME_BONUS_AMOUNT,
                ['dummy1', 'dummy2']
            );
            merkleRoot = result.root;
            merkleProof = result.proof;

            // Set merkle root
            await rewardManager.connect(admin).updateMerkleRoot(
                PoolType.WelcomeBonus,
                merkleRoot
            );
        });

        it('should allow claiming with valid merkle proof', async function () {
            const balanceBefore = await omniCoin.balanceOf(user1.address);

            await rewardManager.connect(admin).claimWelcomeBonus(
                user1.address,
                WELCOME_BONUS_AMOUNT,
                merkleProof
            );

            const balanceAfter = await omniCoin.balanceOf(user1.address);
            expect(balanceAfter - balanceBefore).to.equal(WELCOME_BONUS_AMOUNT);
        });

        it('should emit WelcomeBonusClaimed event', async function () {
            const expectedRemaining = WELCOME_BONUS_POOL - WELCOME_BONUS_AMOUNT;

            await expect(
                rewardManager.connect(admin).claimWelcomeBonus(
                    user1.address,
                    WELCOME_BONUS_AMOUNT,
                    merkleProof
                )
            )
                .to.emit(rewardManager, 'WelcomeBonusClaimed')
                .withArgs(user1.address, WELCOME_BONUS_AMOUNT, expectedRemaining);
        });

        it('should mark user as claimed', async function () {
            await rewardManager.connect(admin).claimWelcomeBonus(
                user1.address,
                WELCOME_BONUS_AMOUNT,
                merkleProof
            );

            expect(await rewardManager.hasClaimedWelcomeBonus(user1.address)).to.be.true;
        });

        it('should reject double claims', async function () {
            await rewardManager.connect(admin).claimWelcomeBonus(
                user1.address,
                WELCOME_BONUS_AMOUNT,
                merkleProof
            );

            await expect(
                rewardManager.connect(admin).claimWelcomeBonus(
                    user1.address,
                    WELCOME_BONUS_AMOUNT,
                    merkleProof
                )
            )
                .to.be.revertedWithCustomError(rewardManager, 'BonusAlreadyClaimed')
                .withArgs(user1.address, PoolType.WelcomeBonus);
        });

        it('should reject invalid merkle proofs', async function () {
            // First set a valid merkle root (for user2)
            // When merkle root is 0x0, verification is skipped (open claims)
            const user2Result = generateMerkleProof(
                user2.address,
                WELCOME_BONUS_AMOUNT,
                ['dummy1', 'dummy2']
            );

            // Set the merkle root
            await rewardManager.connect(admin).updateMerkleRoot(
                PoolType.WelcomeBonus,
                user2Result.root
            );

            // Try to claim for user1 using user2's proof - should fail
            await expect(
                rewardManager.connect(admin).claimWelcomeBonus(
                    user1.address, // Trying to claim for user1 with user2's proof
                    WELCOME_BONUS_AMOUNT,
                    user2Result.proof
                )
            ).to.be.revertedWithCustomError(rewardManager, 'InvalidMerkleProof');
        });

        it('should reject zero user address', async function () {
            await expect(
                rewardManager.connect(admin).claimWelcomeBonus(
                    ZeroAddress,
                    WELCOME_BONUS_AMOUNT,
                    merkleProof
                )
            ).to.be.revertedWithCustomError(rewardManager, 'ZeroAddressNotAllowed');
        });

        it('should reject zero amount', async function () {
            await expect(
                rewardManager.connect(admin).claimWelcomeBonus(
                    user1.address,
                    0,
                    merkleProof
                )
            ).to.be.revertedWithCustomError(rewardManager, 'ZeroAmountNotAllowed');
        });

        it('should reject unauthorized callers', async function () {
            await expect(
                rewardManager.connect(unauthorized).claimWelcomeBonus(
                    user1.address,
                    WELCOME_BONUS_AMOUNT,
                    merkleProof
                )
            ).to.be.revertedWithCustomError(rewardManager, 'AccessControlUnauthorizedAccount');
        });

        it('should work without merkle root (open claims)', async function () {
            // Reset merkle root to zero (allow all claims)
            await rewardManager.connect(admin).updateMerkleRoot(
                PoolType.WelcomeBonus,
                ethers.ZeroHash
            );

            // Should succeed with empty proof
            await expect(
                rewardManager.connect(admin).claimWelcomeBonus(
                    user2.address,
                    WELCOME_BONUS_AMOUNT,
                    []
                )
            ).to.not.be.reverted;
        });

        it('should update pool statistics correctly', async function () {
            await rewardManager.connect(admin).claimWelcomeBonus(
                user1.address,
                WELCOME_BONUS_AMOUNT,
                merkleProof
            );

            const [initialAmounts, remainingAmounts, distributedAmounts] =
                await rewardManager.getPoolStatistics();

            expect(initialAmounts[0]).to.equal(WELCOME_BONUS_POOL);
            expect(remainingAmounts[0]).to.equal(WELCOME_BONUS_POOL - WELCOME_BONUS_AMOUNT);
            expect(distributedAmounts[0]).to.equal(WELCOME_BONUS_AMOUNT);
        });
    });

    // ========================================
    // Referral Bonus Tests
    // ========================================

    describe('Referral Bonus', function () {
        let merkleRoot: string;
        let merkleProof: string[];

        beforeEach(async function () {
            const result = generateReferralMerkleProof(
                referrer.address,
                secondLevelReferrer.address,
                REFERRAL_PRIMARY,
                REFERRAL_SECONDARY,
                ['dummy1', 'dummy2']
            );
            merkleRoot = result.root;
            merkleProof = result.proof;

            await rewardManager.connect(admin).updateMerkleRoot(
                PoolType.ReferralBonus,
                merkleRoot
            );
        });

        it('should distribute to both referrers', async function () {
            const referrerBalanceBefore = await omniCoin.balanceOf(referrer.address);
            const secondLevelBalanceBefore = await omniCoin.balanceOf(secondLevelReferrer.address);

            await rewardManager.connect(admin).claimReferralBonus(
                {
                    referrer: referrer.address,
                    secondLevelReferrer: secondLevelReferrer.address,
                    primaryAmount: REFERRAL_PRIMARY,
                    secondaryAmount: REFERRAL_SECONDARY,
                },
                merkleProof
            );

            const referrerBalanceAfter = await omniCoin.balanceOf(referrer.address);
            const secondLevelBalanceAfter = await omniCoin.balanceOf(secondLevelReferrer.address);

            expect(referrerBalanceAfter - referrerBalanceBefore).to.equal(REFERRAL_PRIMARY);
            expect(secondLevelBalanceAfter - secondLevelBalanceBefore).to.equal(REFERRAL_SECONDARY);
        });

        it('should emit ReferralBonusClaimed event', async function () {
            // Total includes ODDAO share: (referrerTotal * 10) / 90 when secondLevelReferrer != 0
            const referrerTotal = REFERRAL_PRIMARY + REFERRAL_SECONDARY;
            const oddaoShare = (referrerTotal * BigInt(10)) / BigInt(90);
            const totalAmount = referrerTotal + oddaoShare;

            await expect(
                rewardManager.connect(admin).claimReferralBonus(
                    {
                        referrer: referrer.address,
                        secondLevelReferrer: secondLevelReferrer.address,
                        primaryAmount: REFERRAL_PRIMARY,
                        secondaryAmount: REFERRAL_SECONDARY,
                    },
                    merkleProof
                )
            )
                .to.emit(rewardManager, 'ReferralBonusClaimed')
                .withArgs(referrer.address, secondLevelReferrer.address, totalAmount);
        });

        it('should handle missing second-level referrer', async function () {
            // Generate proof with zero address for second level
            const result = generateReferralMerkleProof(
                referrer.address,
                ZeroAddress,
                REFERRAL_PRIMARY,
                BigInt(0), // No secondary amount
                ['dummy1', 'dummy2']
            );

            await rewardManager.connect(admin).updateMerkleRoot(
                PoolType.ReferralBonus,
                result.root
            );

            const referrerBalanceBefore = await omniCoin.balanceOf(referrer.address);

            await rewardManager.connect(admin).claimReferralBonus(
                {
                    referrer: referrer.address,
                    secondLevelReferrer: ZeroAddress,
                    primaryAmount: REFERRAL_PRIMARY,
                    secondaryAmount: BigInt(0),
                },
                result.proof
            );

            const referrerBalanceAfter = await omniCoin.balanceOf(referrer.address);
            expect(referrerBalanceAfter - referrerBalanceBefore).to.equal(REFERRAL_PRIMARY);
        });

        it('should track cumulative earnings', async function () {
            // First referral claim
            await rewardManager.connect(admin).claimReferralBonus(
                {
                    referrer: referrer.address,
                    secondLevelReferrer: secondLevelReferrer.address,
                    primaryAmount: REFERRAL_PRIMARY,
                    secondaryAmount: REFERRAL_SECONDARY,
                },
                merkleProof
            );

            expect(await rewardManager.getReferralBonusesEarned(referrer.address))
                .to.equal(REFERRAL_PRIMARY);
            expect(await rewardManager.getReferralBonusesEarned(secondLevelReferrer.address))
                .to.equal(REFERRAL_SECONDARY);

            // Second referral claim (new user)
            const result2 = generateReferralMerkleProof(
                referrer.address,
                secondLevelReferrer.address,
                REFERRAL_PRIMARY,
                REFERRAL_SECONDARY,
                ['dummy3', 'dummy4']
            );

            await rewardManager.connect(admin).updateMerkleRoot(
                PoolType.ReferralBonus,
                result2.root
            );

            await rewardManager.connect(admin).claimReferralBonus(
                {
                    referrer: referrer.address,
                    secondLevelReferrer: secondLevelReferrer.address,
                    primaryAmount: REFERRAL_PRIMARY,
                    secondaryAmount: REFERRAL_SECONDARY,
                },
                result2.proof
            );

            expect(await rewardManager.getReferralBonusesEarned(referrer.address))
                .to.equal(REFERRAL_PRIMARY * BigInt(2));
            expect(await rewardManager.getReferralBonusesEarned(secondLevelReferrer.address))
                .to.equal(REFERRAL_SECONDARY * BigInt(2));
        });

        it('should reject zero referrer address', async function () {
            await expect(
                rewardManager.connect(admin).claimReferralBonus(
                    {
                        referrer: ZeroAddress,
                        secondLevelReferrer: secondLevelReferrer.address,
                        primaryAmount: REFERRAL_PRIMARY,
                        secondaryAmount: REFERRAL_SECONDARY,
                    },
                    merkleProof
                )
            ).to.be.revertedWithCustomError(rewardManager, 'ZeroAddressNotAllowed');
        });

        it('should reject zero total amount', async function () {
            await expect(
                rewardManager.connect(admin).claimReferralBonus(
                    {
                        referrer: referrer.address,
                        secondLevelReferrer: secondLevelReferrer.address,
                        primaryAmount: BigInt(0),
                        secondaryAmount: BigInt(0),
                    },
                    merkleProof
                )
            ).to.be.revertedWithCustomError(rewardManager, 'ZeroAmountNotAllowed');
        });
    });

    // ========================================
    // First Sale Bonus Tests
    // ========================================

    describe('First Sale Bonus', function () {
        let merkleRoot: string;
        let merkleProof: string[];

        beforeEach(async function () {
            const result = generateMerkleProof(
                user1.address,
                FIRST_SALE_AMOUNT,
                ['dummy1', 'dummy2']
            );
            merkleRoot = result.root;
            merkleProof = result.proof;

            await rewardManager.connect(admin).updateMerkleRoot(
                PoolType.FirstSaleBonus,
                merkleRoot
            );
        });

        it('should allow claiming with valid proof', async function () {
            const balanceBefore = await omniCoin.balanceOf(user1.address);

            await rewardManager.connect(admin).claimFirstSaleBonus(
                user1.address,
                FIRST_SALE_AMOUNT,
                merkleProof
            );

            const balanceAfter = await omniCoin.balanceOf(user1.address);
            expect(balanceAfter - balanceBefore).to.equal(FIRST_SALE_AMOUNT);
        });

        it('should emit FirstSaleBonusClaimed event', async function () {
            const expectedRemaining = FIRST_SALE_BONUS_POOL - FIRST_SALE_AMOUNT;

            await expect(
                rewardManager.connect(admin).claimFirstSaleBonus(
                    user1.address,
                    FIRST_SALE_AMOUNT,
                    merkleProof
                )
            )
                .to.emit(rewardManager, 'FirstSaleBonusClaimed')
                .withArgs(user1.address, FIRST_SALE_AMOUNT, expectedRemaining);
        });

        it('should mark seller as claimed', async function () {
            await rewardManager.connect(admin).claimFirstSaleBonus(
                user1.address,
                FIRST_SALE_AMOUNT,
                merkleProof
            );

            expect(await rewardManager.hasClaimedFirstSaleBonus(user1.address)).to.be.true;
        });

        it('should reject double claims', async function () {
            await rewardManager.connect(admin).claimFirstSaleBonus(
                user1.address,
                FIRST_SALE_AMOUNT,
                merkleProof
            );

            await expect(
                rewardManager.connect(admin).claimFirstSaleBonus(
                    user1.address,
                    FIRST_SALE_AMOUNT,
                    merkleProof
                )
            )
                .to.be.revertedWithCustomError(rewardManager, 'BonusAlreadyClaimed')
                .withArgs(user1.address, PoolType.FirstSaleBonus);
        });

        it('should reject invalid merkle proofs', async function () {
            // First set a valid merkle root (for user2)
            // When merkle root is 0x0, verification is skipped (open claims)
            const user2Result = generateMerkleProof(
                user2.address,
                FIRST_SALE_AMOUNT,
                ['dummy1', 'dummy2']
            );

            // Set the merkle root
            await rewardManager.connect(admin).updateMerkleRoot(
                PoolType.FirstSaleBonus,
                user2Result.root
            );

            // Try to claim for user1 using user2's proof - should fail
            await expect(
                rewardManager.connect(admin).claimFirstSaleBonus(
                    user1.address,
                    FIRST_SALE_AMOUNT,
                    user2Result.proof
                )
            ).to.be.revertedWithCustomError(rewardManager, 'InvalidMerkleProof');
        });
    });

    // ========================================
    // Admin Functions Tests
    // ========================================

    describe('Admin Functions', function () {
        describe('Merkle Root Updates', function () {
            it('should allow merkle root updates for welcome bonus', async function () {
                const newRoot = keccak256(ethers.toUtf8Bytes('new-merkle-root'));

                await expect(
                    rewardManager.connect(admin).updateMerkleRoot(
                        PoolType.WelcomeBonus,
                        newRoot
                    )
                )
                    .to.emit(rewardManager, 'MerkleRootUpdated')
                    .withArgs(PoolType.WelcomeBonus, ethers.ZeroHash, newRoot);
            });

            it('should allow merkle root updates for referral bonus', async function () {
                const newRoot = keccak256(ethers.toUtf8Bytes('new-merkle-root'));

                await expect(
                    rewardManager.connect(admin).updateMerkleRoot(
                        PoolType.ReferralBonus,
                        newRoot
                    )
                )
                    .to.emit(rewardManager, 'MerkleRootUpdated')
                    .withArgs(PoolType.ReferralBonus, ethers.ZeroHash, newRoot);
            });

            it('should allow merkle root updates for first sale bonus', async function () {
                const newRoot = keccak256(ethers.toUtf8Bytes('new-merkle-root'));

                await expect(
                    rewardManager.connect(admin).updateMerkleRoot(
                        PoolType.FirstSaleBonus,
                        newRoot
                    )
                )
                    .to.emit(rewardManager, 'MerkleRootUpdated')
                    .withArgs(PoolType.FirstSaleBonus, ethers.ZeroHash, newRoot);
            });

            it('should reject unauthorized merkle root updates', async function () {
                const newRoot = keccak256(ethers.toUtf8Bytes('new-merkle-root'));

                await expect(
                    rewardManager.connect(unauthorized).updateMerkleRoot(
                        PoolType.WelcomeBonus,
                        newRoot
                    )
                ).to.be.revertedWithCustomError(rewardManager, 'AccessControlUnauthorizedAccount');
            });
        });

        describe('Pause/Unpause', function () {
            it('should allow pausing by PAUSER_ROLE', async function () {
                await rewardManager.connect(admin).pause();
                expect(await rewardManager.paused()).to.be.true;
            });

            it('should allow unpausing by PAUSER_ROLE', async function () {
                await rewardManager.connect(admin).pause();
                await rewardManager.connect(admin).unpause();
                expect(await rewardManager.paused()).to.be.false;
            });

            it('should block claims when paused', async function () {
                await rewardManager.connect(admin).pause();

                // Set up valid merkle proof
                const result = generateMerkleProof(
                    user1.address,
                    WELCOME_BONUS_AMOUNT,
                    ['dummy1', 'dummy2']
                );

                await expect(
                    rewardManager.connect(admin).claimWelcomeBonus(
                        user1.address,
                        WELCOME_BONUS_AMOUNT,
                        result.proof
                    )
                ).to.be.revertedWithCustomError(rewardManager, 'EnforcedPause');
            });

            it('should reject unauthorized pause', async function () {
                await expect(
                    rewardManager.connect(unauthorized).pause()
                ).to.be.revertedWithCustomError(rewardManager, 'AccessControlUnauthorizedAccount');
            });

            it('should reject unauthorized unpause', async function () {
                await rewardManager.connect(admin).pause();

                await expect(
                    rewardManager.connect(unauthorized).unpause()
                ).to.be.revertedWithCustomError(rewardManager, 'AccessControlUnauthorizedAccount');
            });
        });
    });

    // ========================================
    // View Functions Tests
    // ========================================

    describe('View Functions', function () {
        it('should return correct pool balances', async function () {
            const [welcome, referral, firstSale] =
                await rewardManager.getPoolBalances();

            expect(welcome).to.equal(WELCOME_BONUS_POOL);
            expect(referral).to.equal(REFERRAL_BONUS_POOL);
            expect(firstSale).to.equal(FIRST_SALE_BONUS_POOL);
        });

        it('should return correct pool statistics', async function () {
            const [initialAmounts, remainingAmounts, distributedAmounts] =
                await rewardManager.getPoolStatistics();

            // Check initial amounts (3 pools)
            expect(initialAmounts[0]).to.equal(WELCOME_BONUS_POOL);
            expect(initialAmounts[1]).to.equal(REFERRAL_BONUS_POOL);
            expect(initialAmounts[2]).to.equal(FIRST_SALE_BONUS_POOL);

            // Check remaining (should equal initial since nothing distributed)
            expect(remainingAmounts[0]).to.equal(WELCOME_BONUS_POOL);
            expect(remainingAmounts[1]).to.equal(REFERRAL_BONUS_POOL);
            expect(remainingAmounts[2]).to.equal(FIRST_SALE_BONUS_POOL);

            // Check distributed (should be zero)
            expect(distributedAmounts[0]).to.equal(0);
            expect(distributedAmounts[1]).to.equal(0);
            expect(distributedAmounts[2]).to.equal(0);
        });

        it('should return correct total undistributed', async function () {
            expect(await rewardManager.getTotalUndistributed())
                .to.equal(TOTAL_POOL_SIZE);
        });

        it('should return correct total distributed', async function () {
            expect(await rewardManager.getTotalDistributed()).to.equal(0);
        });

        it('should correctly report claim status', async function () {
            expect(await rewardManager.hasClaimedWelcomeBonus(user1.address)).to.be.false;
            expect(await rewardManager.hasClaimedFirstSaleBonus(user1.address)).to.be.false;
        });
    });

    // ========================================
    // Pool Depletion Tests
    // ========================================

    describe('Pool Depletion', function () {
        it('should emit PoolLowWarning when threshold crossed', async function () {
            // Create a new reward manager with small pool for testing threshold
            const smallPool = ethers.parseEther('100'); // 100 XOM
            const OmniRewardManagerFactory = await ethers.getContractFactory('OmniRewardManager');

            const proxy = await upgrades.deployProxy(
                OmniRewardManagerFactory,
                [
                    await omniCoin.getAddress(),
                    smallPool,
                    smallPool,
                    smallPool,
                    admin.address,
                ],
                { initializer: false, kind: 'uups', constructorArgs: [ethers.ZeroAddress] }
            );
            await proxy.waitForDeployment();

            const smallRewardManager = OmniRewardManagerFactory.attach(await proxy.getAddress());

            // Fund the contract before initialization (M-02 balance check)
            const totalSmall = smallPool * BigInt(3);
            await omniCoin.transfer(await smallRewardManager.getAddress(), totalSmall);

            // Initialize after funding
            await smallRewardManager.initialize(
                await omniCoin.getAddress(), smallPool, smallPool, smallPool, admin.address
            );
            // Grant roles (audit reduced _setupRoles to DEFAULT_ADMIN_ROLE only)
            await smallRewardManager.connect(admin).grantRole(BONUS_DISTRIBUTOR_ROLE, admin.address);

            // Claim 99% of the pool (threshold is 1%)
            const largeClaimAmount = ethers.parseEther('99'); // 99 XOM out of 100

            // Set up merkle proof
            const result = generateMerkleProof(
                user1.address,
                largeClaimAmount,
                ['dummy1', 'dummy2']
            );

            await smallRewardManager.connect(admin).updateMerkleRoot(
                PoolType.WelcomeBonus,
                result.root
            );

            // This should emit PoolLowWarning since remaining (1 XOM) < threshold (1 XOM)
            const threshold = smallPool / BigInt(100); // 1% = 1 XOM

            await expect(
                smallRewardManager.connect(admin).claimWelcomeBonus(
                    user1.address,
                    largeClaimAmount,
                    result.proof
                )
            )
                .to.emit(smallRewardManager, 'PoolLowWarning')
                .withArgs(PoolType.WelcomeBonus, smallPool - largeClaimAmount, threshold);
        });

        it('should reject claims when pool depleted', async function () {
            // Create reward manager with exact amount needed
            const exactPool = WELCOME_BONUS_AMOUNT;
            const OmniRewardManagerFactory = await ethers.getContractFactory('OmniRewardManager');

            const proxy = await upgrades.deployProxy(
                OmniRewardManagerFactory,
                [
                    await omniCoin.getAddress(),
                    exactPool,
                    exactPool,
                    exactPool,
                    admin.address,
                ],
                { initializer: false, kind: 'uups', constructorArgs: [ethers.ZeroAddress] }
            );
            await proxy.waitForDeployment();

            const smallRewardManager = OmniRewardManagerFactory.attach(await proxy.getAddress());

            // Fund before initialization (M-02 balance check)
            await omniCoin.transfer(await smallRewardManager.getAddress(), exactPool * BigInt(3));

            // Initialize after funding
            await smallRewardManager.initialize(
                await omniCoin.getAddress(), exactPool, exactPool, exactPool, admin.address
            );
            // Grant roles (audit reduced _setupRoles to DEFAULT_ADMIN_ROLE only)
            await smallRewardManager.connect(admin).grantRole(BONUS_DISTRIBUTOR_ROLE, admin.address);

            // First claim should succeed
            const result1 = generateMerkleProof(user1.address, exactPool, ['d1', 'd2']);
            await smallRewardManager.connect(admin).updateMerkleRoot(PoolType.WelcomeBonus, result1.root);
            await smallRewardManager.connect(admin).claimWelcomeBonus(user1.address, exactPool, result1.proof);

            // Second claim should fail (pool empty)
            const result2 = generateMerkleProof(user2.address, exactPool, ['d3', 'd4']);
            await smallRewardManager.connect(admin).updateMerkleRoot(PoolType.WelcomeBonus, result2.root);

            await expect(
                smallRewardManager.connect(admin).claimWelcomeBonus(user2.address, exactPool, result2.proof)
            )
                .to.be.revertedWithCustomError(smallRewardManager, 'InsufficientPoolBalance')
                .withArgs(PoolType.WelcomeBonus, exactPool, 0);
        });
    });

    // ========================================
    // Upgrade Tests
    // ========================================

    describe('Upgrade Functionality', function () {
        beforeEach(async function () {
            // Grant UPGRADER_ROLE to owner (who is used by upgrades.upgradeProxy)
            await rewardManager.connect(admin).grantRole(UPGRADER_ROLE, owner.address);
            // Grant PAUSER_ROLE for the upgrade test that calls pause()
            await rewardManager.connect(admin).grantRole(PAUSER_ROLE, owner.address);
        });

        it('should allow upgrades by UPGRADER_ROLE', async function () {
            const OmniRewardManagerV2 = await ethers.getContractFactory('OmniRewardManager');

            // This should not revert (just deploys new implementation)
            const upgraded = await upgrades.upgradeProxy(
                await rewardManager.getAddress(),
                OmniRewardManagerV2,
                { call: { fn: 'pause', args: [] }, constructorArgs: [ethers.ZeroAddress] } // Call pause during upgrade as a test
            );

            expect(await upgraded.getAddress()).to.equal(await rewardManager.getAddress());
            expect(await upgraded.paused()).to.be.true;
        });

        it('should preserve state after upgrade', async function () {
            // Distribute some rewards first (claim a welcome bonus)
            const result = generateMerkleProof(user1.address, WELCOME_BONUS_AMOUNT, ['w1']);
            await rewardManager.connect(admin).updateMerkleRoot(PoolType.WelcomeBonus, result.root);
            await rewardManager.connect(admin).claimWelcomeBonus(
                user1.address, WELCOME_BONUS_AMOUNT, result.proof
            );

            const distributedBefore = await rewardManager.getTotalDistributed();

            // Upgrade
            const OmniRewardManagerV2 = await ethers.getContractFactory('OmniRewardManager');
            const upgraded = await upgrades.upgradeProxy(
                await rewardManager.getAddress(),
                OmniRewardManagerV2,
                { constructorArgs: [ethers.ZeroAddress] }
            );

            // Verify state preserved
            expect(await upgraded.getTotalDistributed()).to.equal(distributedBefore);
            expect(await upgraded.hasClaimedWelcomeBonus(user1.address)).to.be.true;
        });
    });

    // ========================================
    // Role Management Tests
    // ========================================

    describe('Role Management', function () {
        it('should allow admin to grant roles', async function () {
            await rewardManager.connect(admin).grantRole(
                BONUS_DISTRIBUTOR_ROLE,
                user1.address
            );

            expect(await rewardManager.hasRole(BONUS_DISTRIBUTOR_ROLE, user1.address))
                .to.be.true;
        });

        it('should allow admin to revoke roles', async function () {
            // First grant
            await rewardManager.connect(admin).grantRole(
                BONUS_DISTRIBUTOR_ROLE,
                user1.address
            );

            // Then revoke
            await rewardManager.connect(admin).revokeRole(
                BONUS_DISTRIBUTOR_ROLE,
                user1.address
            );

            expect(await rewardManager.hasRole(BONUS_DISTRIBUTOR_ROLE, user1.address))
                .to.be.false;
        });

        it('should reject role management from non-admin', async function () {
            await expect(
                rewardManager.connect(unauthorized).grantRole(
                    BONUS_DISTRIBUTOR_ROLE,
                    user1.address
                )
            ).to.be.revertedWithCustomError(rewardManager, 'AccessControlUnauthorizedAccount');
        });
    });

    // ========================================
    // Edge Cases and Security Tests
    // ========================================

    describe('Edge Cases and Security', function () {
        it('should handle multiple users claiming different bonuses', async function () {
            // User1 claims welcome bonus
            const welcome1 = generateMerkleProof(user1.address, WELCOME_BONUS_AMOUNT, ['w1']);
            await rewardManager.connect(admin).updateMerkleRoot(PoolType.WelcomeBonus, welcome1.root);
            await rewardManager.connect(admin).claimWelcomeBonus(user1.address, WELCOME_BONUS_AMOUNT, welcome1.proof);

            // User2 claims first sale bonus
            const firstSale2 = generateMerkleProof(user2.address, FIRST_SALE_AMOUNT, ['fs1']);
            await rewardManager.connect(admin).updateMerkleRoot(PoolType.FirstSaleBonus, firstSale2.root);
            await rewardManager.connect(admin).claimFirstSaleBonus(user2.address, FIRST_SALE_AMOUNT, firstSale2.proof);

            // Verify balances
            expect(await omniCoin.balanceOf(user1.address)).to.equal(WELCOME_BONUS_AMOUNT);
            expect(await omniCoin.balanceOf(user2.address)).to.equal(FIRST_SALE_AMOUNT);
        });

        it('should handle same user claiming different bonus types', async function () {
            // User1 claims welcome bonus
            const welcome = generateMerkleProof(user1.address, WELCOME_BONUS_AMOUNT, ['w1']);
            await rewardManager.connect(admin).updateMerkleRoot(PoolType.WelcomeBonus, welcome.root);
            await rewardManager.connect(admin).claimWelcomeBonus(user1.address, WELCOME_BONUS_AMOUNT, welcome.proof);

            // Same user claims first sale bonus
            const firstSale = generateMerkleProof(user1.address, FIRST_SALE_AMOUNT, ['fs1']);
            await rewardManager.connect(admin).updateMerkleRoot(PoolType.FirstSaleBonus, firstSale.root);
            await rewardManager.connect(admin).claimFirstSaleBonus(user1.address, FIRST_SALE_AMOUNT, firstSale.proof);

            // Verify total balance
            expect(await omniCoin.balanceOf(user1.address))
                .to.equal(WELCOME_BONUS_AMOUNT + FIRST_SALE_AMOUNT);
        });

        it('should correctly track distributed amounts across pools', async function () {
            // Claim from multiple pools
            const welcome = generateMerkleProof(user1.address, WELCOME_BONUS_AMOUNT, ['w1']);
            await rewardManager.connect(admin).updateMerkleRoot(PoolType.WelcomeBonus, welcome.root);
            await rewardManager.connect(admin).claimWelcomeBonus(user1.address, WELCOME_BONUS_AMOUNT, welcome.proof);

            const firstSale = generateMerkleProof(user2.address, FIRST_SALE_AMOUNT, ['fs1']);
            await rewardManager.connect(admin).updateMerkleRoot(PoolType.FirstSaleBonus, firstSale.root);
            await rewardManager.connect(admin).claimFirstSaleBonus(user2.address, FIRST_SALE_AMOUNT, firstSale.proof);

            const totalDistributed = await rewardManager.getTotalDistributed();
            const expectedTotal = WELCOME_BONUS_AMOUNT + FIRST_SALE_AMOUNT;

            expect(totalDistributed).to.equal(expectedTotal);
        });
    });

    // ========================================
    // Trustless Welcome Bonus Tests
    // ========================================

    describe('Trustless Welcome Bonus (claimWelcomeBonusTrustless)', function () {
        let omniRegistration: any;
        let verificationSigner: any;

        // EIP-712 domain and types for verification proofs
        const PHONE_VERIFICATION_TYPES = {
            PhoneVerification: [
                { name: 'user', type: 'address' },
                { name: 'phoneHash', type: 'bytes32' },
                { name: 'timestamp', type: 'uint256' },
                { name: 'nonce', type: 'bytes32' },
                { name: 'deadline', type: 'uint256' },
            ],
        };

        const SOCIAL_VERIFICATION_TYPES = {
            SocialVerification: [
                { name: 'user', type: 'address' },
                { name: 'socialHash', type: 'bytes32' },
                { name: 'platform', type: 'string' },
                { name: 'timestamp', type: 'uint256' },
                { name: 'nonce', type: 'bytes32' },
                { name: 'deadline', type: 'uint256' },
            ],
        };

        /**
         * Generate phone verification signature
         */
        async function signPhoneVerification(
            signer: any,
            user: string,
            phoneHash: string,
            timestamp: number,
            nonce: string,
            deadline: number,
            contractAddr: string,
            chainId: bigint
        ): Promise<string> {
            const domain = {
                name: 'OmniRegistration',
                version: '1',
                chainId: chainId,
                verifyingContract: contractAddr,
            };

            const value = {
                user,
                phoneHash,
                timestamp,
                nonce,
                deadline,
            };

            return signer.signTypedData(domain, PHONE_VERIFICATION_TYPES, value);
        }

        /**
         * Generate social verification signature
         */
        async function signSocialVerification(
            signer: any,
            user: string,
            socialHash: string,
            platform: string,
            timestamp: number,
            nonce: string,
            deadline: number,
            contractAddr: string,
            chainId: bigint
        ): Promise<string> {
            const domain = {
                name: 'OmniRegistration',
                version: '1',
                chainId: chainId,
                verifyingContract: contractAddr,
            };

            const value = {
                user,
                socialHash,
                platform,
                timestamp,
                nonce,
                deadline,
            };

            return signer.signTypedData(domain, SOCIAL_VERIFICATION_TYPES, value);
        }

        beforeEach(async function () {
            // Create a verification signer (trusted verification key)
            verificationSigner = ethers.Wallet.createRandom().connect(ethers.provider);
            // Fund the signer for gas
            await owner.sendTransaction({
                to: verificationSigner.address,
                value: ethers.parseEther('1'),
            });

            // Deploy OmniRegistration contract (no parameters needed for initialize)
            const OmniRegistrationFactory = await ethers.getContractFactory('OmniRegistration');
            const registrationProxy = await upgrades.deployProxy(
                OmniRegistrationFactory,
                [],
                { initializer: 'initialize', kind: 'uups', constructorArgs: [ethers.ZeroAddress] }
            );
            await registrationProxy.waitForDeployment();
            omniRegistration = OmniRegistrationFactory.attach(await registrationProxy.getAddress());

            // Grant VALIDATOR_ROLE to admin for registration
            const VALIDATOR_ROLE = keccak256(ethers.toUtf8Bytes('VALIDATOR_ROLE'));
            await omniRegistration.connect(owner).grantRole(VALIDATOR_ROLE, admin.address);

            // Set trusted verification key
            await omniRegistration.connect(owner).setTrustedVerificationKey(verificationSigner.address);

            // Set registration contract in reward manager
            await rewardManager.connect(admin).setRegistrationContract(await omniRegistration.getAddress());

            // Set reward manager address so it can mark bonuses as claimed
            // (BONUS_MARKER_ROLE replaced by omniRewardManagerAddress)
            await omniRegistration.connect(owner).setOmniRewardManagerAddress(await rewardManager.getAddress());
        });

        /**
         * Helper to register a user and complete KYC Tier 1
         * When registered with phoneHash, phone is already verified.
         * We only need to submit social verification for KYC Tier 1.
         */
        async function registerUserWithKycTier1(userAddr: string, referrerAddr: string = ZeroAddress) {
            // Generate unique phone hash for this user
            const phoneNumber = '+1555' + Math.floor(Math.random() * 10000000).toString().padStart(7, '0');
            const phoneHash = keccak256(ethers.toUtf8Bytes(phoneNumber));

            // Generate unique email hash
            const email = `user${Math.random().toString(36).substring(7)}@test.com`;
            const emailHash = keccak256(ethers.toUtf8Bytes(email));

            // Register user with phone hash - this marks phone as verified
            await omniRegistration.connect(admin).registerUser(
                userAddr,
                referrerAddr,
                phoneHash,
                emailHash
            );

            // Get chain ID and registration address for social verification
            const network = await ethers.provider.getNetwork();
            const chainId = network.chainId;
            const regAddr = await omniRegistration.getAddress();

            // Generate and submit social verification proof (required for KYC Tier 1)
            const platform = 'twitter';
            const handle = 'testuser' + Math.floor(Math.random() * 100000);
            const socialHash = keccak256(ethers.toUtf8Bytes(`${platform}:${handle}`));
            const latestBlock = await ethers.provider.getBlock('latest');
            const socialTimestamp = latestBlock!.timestamp;
            const socialNonce = '0x' + Buffer.from(ethers.randomBytes(32)).toString('hex');
            const socialDeadline = socialTimestamp + 3600;

            const socialSignature = await signSocialVerification(
                verificationSigner,
                userAddr,
                socialHash,
                platform,
                socialTimestamp,
                socialNonce,
                socialDeadline,
                regAddr,
                chainId
            );

            // Submit social verification (as the user)
            const userSigner = await ethers.getSigner(userAddr);
            await omniRegistration.connect(userSigner).submitSocialVerification(
                socialHash,
                platform,
                socialTimestamp,
                socialNonce,
                socialDeadline,
                socialSignature
            );

            return { phoneHash, emailHash, socialHash };
        }

        it('should have correct registration contract set', async function () {
            // Verify registration contract is set
            const regContractAddr = await rewardManager.registrationContract();
            expect(regContractAddr).to.equal(await omniRegistration.getAddress());
        });

        it('should be able to call getRegistration via interface', async function () {
            // Register user first
            const phoneHash = keccak256(ethers.toUtf8Bytes('+15551234567'));
            const emailHash = keccak256(ethers.toUtf8Bytes('test@test.com'));
            await omniRegistration.connect(admin).registerUser(
                user1.address,
                ZeroAddress,
                phoneHash,
                emailHash
            );

            // Try to get registration - this tests the interface call
            const reg = await omniRegistration.getRegistration(user1.address);
            expect(reg.timestamp).to.be.greaterThan(0);
        });

        it('should be able to call hasKycTier1 via interface', async function () {
            // Try hasKycTier1 for non-registered user
            const hasKyc = await omniRegistration.hasKycTier1(user1.address);
            expect(hasKyc).to.be.false;
        });

        it('should allow claiming after KYC Tier 1 completion', async function () {
            // Register user with KYC Tier 1 using helper function
            await registerUserWithKycTier1(user1.address);

            // Verify KYC Tier 1 is complete
            expect(await omniRegistration.hasKycTier1(user1.address)).to.be.true;

            // Claim trustless welcome bonus
            const balanceBefore = await omniCoin.balanceOf(user1.address);
            await rewardManager.connect(user1).claimWelcomeBonusTrustless();
            const balanceAfter = await omniCoin.balanceOf(user1.address);

            // Verify user received tokens (10000 XOM for first 1000 users)
            expect(balanceAfter).to.be.greaterThan(balanceBefore);
            const received = balanceAfter - balanceBefore;
            expect(received).to.equal(ethers.parseEther('10000'));
        });

        it('should emit TrustlessWelcomeBonusClaimed event', async function () {
            await registerUserWithKycTier1(user1.address);

            await expect(rewardManager.connect(user1).claimWelcomeBonusTrustless())
                .to.emit(rewardManager, 'TrustlessWelcomeBonusClaimed');
        });

        it('should reject when user has not completed KYC Tier 1', async function () {
            // Register user with phone but without social verification
            const phoneHash = keccak256(ethers.toUtf8Bytes('+15551234567'));
            const emailHash = keccak256(ethers.toUtf8Bytes('test@test.com'));

            await omniRegistration.connect(admin).registerUser(
                user1.address,
                ZeroAddress,
                phoneHash,
                emailHash
            );

            // Verify user is registered but NOT KYC Tier 1 (missing social)
            expect(await omniRegistration.isRegistered(user1.address)).to.be.true;
            expect(await omniRegistration.hasKycTier1(user1.address)).to.be.false;

            // Try to claim without KYC Tier 1
            await expect(rewardManager.connect(user1).claimWelcomeBonusTrustless())
                .to.be.revertedWithCustomError(rewardManager, 'KycTier1Required')
                .withArgs(user1.address);
        });

        it('should reject when user is not registered', async function () {
            // Try to claim without registration
            await expect(rewardManager.connect(user1).claimWelcomeBonusTrustless())
                .to.be.revertedWithCustomError(rewardManager, 'UserNotRegistered')
                .withArgs(user1.address);
        });

        it('should reject when registration contract is not set', async function () {
            // Deploy new reward manager without registration contract
            const OmniRewardManagerFactory = await ethers.getContractFactory('OmniRewardManager');
            const newProxy = await upgrades.deployProxy(
                OmniRewardManagerFactory,
                [
                    await omniCoin.getAddress(),
                    WELCOME_BONUS_POOL,
                    REFERRAL_BONUS_POOL,
                    FIRST_SALE_BONUS_POOL,
                    admin.address,
                ],
                { initializer: false, kind: 'uups', constructorArgs: [ethers.ZeroAddress] }
            );
            await newProxy.waitForDeployment();
            const newRewardManager = OmniRewardManagerFactory.attach(await newProxy.getAddress());

            // Fund and initialize (M-02 balance check requires tokens before init)
            await omniCoin.transfer(await newRewardManager.getAddress(), TOTAL_POOL_SIZE);
            await newRewardManager.initialize(
                await omniCoin.getAddress(),
                WELCOME_BONUS_POOL,
                REFERRAL_BONUS_POOL,
                FIRST_SALE_BONUS_POOL,
                admin.address
            );

            // Don't set registration contract
            await expect(newRewardManager.connect(user1).claimWelcomeBonusTrustless())
                .to.be.revertedWithCustomError(newRewardManager, 'RegistrationContractNotSet');
        });

        it('should reject double claims', async function () {
            await registerUserWithKycTier1(user1.address);

            // First claim should succeed
            await rewardManager.connect(user1).claimWelcomeBonusTrustless();

            // Second claim should fail
            await expect(rewardManager.connect(user1).claimWelcomeBonusTrustless())
                .to.be.revertedWithCustomError(rewardManager, 'BonusAlreadyClaimed')
                .withArgs(user1.address, PoolType.WelcomeBonus);
        });

        it('should block claims when paused', async function () {
            await registerUserWithKycTier1(user1.address);
            await rewardManager.connect(admin).pause();

            await expect(rewardManager.connect(user1).claimWelcomeBonusTrustless())
                .to.be.revertedWithCustomError(rewardManager, 'EnforcedPause');
        });

        it('should auto-trigger referral bonus if referrer exists', async function () {
            // First register referrer with KYC Tier 1
            await registerUserWithKycTier1(referrer.address);

            // Then register user1 with referrer
            await registerUserWithKycTier1(user1.address, referrer.address);

            // Set ODDAO address for referral distribution
            await rewardManager.connect(admin).setOddaoAddress(oddao.address);

            // Check pending bonus before
            const pendingBefore = await rewardManager.getPendingReferralBonus(referrer.address);
            expect(pendingBefore).to.equal(0);

            // Claim welcome bonus (should auto-accumulate referral bonus)
            await rewardManager.connect(user1).claimWelcomeBonusTrustless();

            // Referral bonus should be ACCUMULATED (not transferred immediately)
            // This is the trustless design - referrer must claim via claimReferralBonusPermissionless()
            const pendingAfter = await rewardManager.getPendingReferralBonus(referrer.address);
            expect(pendingAfter).to.be.greaterThan(0);

            // Verify referrer can claim the accumulated bonus
            const referrerBalanceBefore = await omniCoin.balanceOf(referrer.address);
            await rewardManager.connect(referrer).claimReferralBonusPermissionless();
            const referrerBalanceAfter = await omniCoin.balanceOf(referrer.address);

            // Referrer should have received the accumulated bonus (70% of referral amount)
            expect(referrerBalanceAfter).to.be.greaterThan(referrerBalanceBefore);
            expect(referrerBalanceAfter - referrerBalanceBefore).to.equal(pendingAfter);
        });

        it('SYBIL-H02: should skip referral bonus when referrer lacks KYC Tier 1', async function () {
            // Register referrer WITHOUT KYC Tier 1 (phone+email only, no social)
            const referrerPhone = keccak256(ethers.toUtf8Bytes('+15559990001'));
            const referrerEmail = keccak256(ethers.toUtf8Bytes('no-kyc-referrer@test.com'));
            await omniRegistration.connect(admin).registerUser(
                referrer.address,
                ZeroAddress,
                referrerPhone,
                referrerEmail
            );
            // Verify referrer does NOT have KYC Tier 1
            expect(await omniRegistration.hasKycTier1(referrer.address)).to.be.false;

            // Register user1 with KYC Tier 1 and referrer who lacks KYC Tier 1
            // Note: registerUser now requires referrer KYC Tier 1 (SYBIL-H02),
            // so we need to register user1 without referrer first, then the
            // referral link would already be set. But actually, registering with
            // a Tier 0 referrer will revert now. So let's test via a referrer
            // who completes KYC Tier 1 AFTER registering, and use the legacy
            // admin claim path for the test.
            //
            // Actually, _distributeAutoReferralBonus is called from
            // claimWelcomeBonusTrustless, so we need a valid registration with
            // a referrer. The referrer KYC check in registerUser blocks Tier 0
            // referrers. For this test, we need to:
            // 1. Register referrer with KYC Tier 1 (so registerUser passes)
            // 2. Then somehow make them lose KYC Tier 1 OR
            // 3. Use a mock registration
            //
            // Simpler approach: Register user1 before our new check was applied.
            // Since we can't do that in the contract, we'll register user1 with
            // referrer who HAS KYC Tier 1, then remove referrer's social hash
            // via admin unregister + re-register without social.
            //
            // Simplest approach: use the admin claimWelcomeBonus which doesn't
            // go through registerUser. We can set up the registration data
            // manually by registering the referrer first, then the user.
            // But claimWelcomeBonus (admin) doesn't call _distributeAutoReferralBonus.
            // Only the trustless/permissionless paths do.
            //
            // Best approach: register referrer with full KYC, register user1
            // with referrer, then admin-unregister referrer (removes kycTier1CompletedAt),
            // then re-register referrer without social → kycTier1CompletedAt = 0.

            // OK, let's take a different approach: register user1 without referrer
            // via admin, then manually set the referrer in the registration contract.
            // Actually, the referrer is immutable once set. Let's use the simplest
            // possible approach:
            //
            // 1. Complete KYC Tier 1 for referrer (so registerUser doesn't revert)
            // 2. Register user1 with referrer (passes KYC check)
            // 3. Admin-unregister referrer (clears kycTier1CompletedAt)
            // 4. Re-register referrer without social (no KYC Tier 1)
            // 5. user1 claims welcome bonus → referral bonus should be SKIPPED

            // Step: Complete KYC Tier 1 for referrer
            // referrer already registered above, just needs social verification
            const network = await ethers.provider.getNetwork();
            const chainId = network.chainId;
            const regAddr = await omniRegistration.getAddress();
            const socialHash1 = keccak256(ethers.toUtf8Bytes('twitter:noreferrer1'));
            const latestBlock1 = await ethers.provider.getBlock('latest');
            const socialTimestamp1 = latestBlock1!.timestamp;
            const socialNonce1 = '0x' + Buffer.from(ethers.randomBytes(32)).toString('hex');
            const socialDeadline1 = socialTimestamp1 + 3600;
            const socialSig1 = await signSocialVerification(
                verificationSigner, referrer.address, socialHash1, 'twitter',
                socialTimestamp1, socialNonce1, socialDeadline1, regAddr, chainId
            );
            await omniRegistration.connect(referrer).submitSocialVerification(
                socialHash1, 'twitter', socialTimestamp1, socialNonce1, socialDeadline1, socialSig1
            );
            expect(await omniRegistration.hasKycTier1(referrer.address)).to.be.true;

            // Register user1 with referrer (referrer has KYC Tier 1 so this passes)
            await registerUserWithKycTier1(user1.address, referrer.address);

            // Admin-unregister referrer (clears kycTier1CompletedAt, hashes, etc.)
            await omniRegistration.connect(owner).adminUnregister(referrer.address);
            // Re-register referrer without social verification
            const referrerPhone2 = keccak256(ethers.toUtf8Bytes('+15559990002'));
            const referrerEmail2 = keccak256(ethers.toUtf8Bytes('no-kyc-referrer2@test.com'));
            await omniRegistration.connect(admin).registerUser(
                referrer.address, ZeroAddress, referrerPhone2, referrerEmail2
            );
            // Referrer now lacks KYC Tier 1 (no social verification)
            expect(await omniRegistration.hasKycTier1(referrer.address)).to.be.false;

            // Set ODDAO address
            await rewardManager.connect(admin).setOddaoAddress(oddao.address);

            // user1 claims welcome bonus → referral bonus should be SKIPPED
            const pendingBefore = await rewardManager.getPendingReferralBonus(referrer.address);
            expect(pendingBefore).to.equal(0);

            await rewardManager.connect(user1).claimWelcomeBonusTrustless();

            // Referral bonus should NOT have accumulated (referrer lacks KYC Tier 1)
            const pendingAfter = await rewardManager.getPendingReferralBonus(referrer.address);
            expect(pendingAfter).to.equal(0);
        });

        it('SYBIL-H02: should redirect L2 referrer share to ODDAO when L2 lacks KYC', async function () {
            // Set up: referrer has KYC Tier 1, secondLevelReferrer does NOT

            // 1. Register secondLevelReferrer WITH KYC Tier 1 (needed for registerUser)
            await registerUserWithKycTier1(secondLevelReferrer.address);
            expect(await omniRegistration.hasKycTier1(secondLevelReferrer.address)).to.be.true;

            // 2. Register referrer with secondLevelReferrer as their referrer
            await registerUserWithKycTier1(referrer.address, secondLevelReferrer.address);
            expect(await omniRegistration.hasKycTier1(referrer.address)).to.be.true;

            // 3. Admin-unregister secondLevelReferrer and re-register without social
            await omniRegistration.connect(owner).adminUnregister(secondLevelReferrer.address);
            const l2Phone = keccak256(ethers.toUtf8Bytes('+15559990003'));
            const l2Email = keccak256(ethers.toUtf8Bytes('l2-no-kyc@test.com'));
            await omniRegistration.connect(admin).registerUser(
                secondLevelReferrer.address, ZeroAddress, l2Phone, l2Email
            );
            expect(await omniRegistration.hasKycTier1(secondLevelReferrer.address)).to.be.false;

            // 4. Register user1 with referrer
            await registerUserWithKycTier1(user1.address, referrer.address);

            // 5. Set ODDAO address
            await rewardManager.connect(admin).setOddaoAddress(oddao.address);

            // 6. Track ODDAO balance before
            const oddaoBalanceBefore = await omniCoin.balanceOf(oddao.address);

            // 7. user1 claims welcome bonus
            await rewardManager.connect(user1).claimWelcomeBonusTrustless();

            // 8. Referrer should have accumulated bonus (has KYC Tier 1)
            const referrerPending = await rewardManager.getPendingReferralBonus(referrer.address);
            expect(referrerPending).to.be.greaterThan(0);

            // 9. SecondLevelReferrer should NOT have accumulated bonus (lacks KYC Tier 1)
            const l2Pending = await rewardManager.getPendingReferralBonus(secondLevelReferrer.address);
            expect(l2Pending).to.equal(0);

            // 10. ODDAO should have received the L2 share (since L2 referrer has no KYC,
            //     secondLevelReferrer is treated as address(0), so the 20% goes to ODDAO)
            const oddaoBalanceAfter = await omniCoin.balanceOf(oddao.address);
            const oddaoReceived = oddaoBalanceAfter - oddaoBalanceBefore;
            // ODDAO gets 10% (normal) + 20% (L2 redirect) = 30% of referral amount
            // vs normal 10% when L2 has KYC
            expect(oddaoReceived).to.be.greaterThan(0);
        });

        it('SYBIL-H02: should accumulate normally when both referrers have KYC Tier 1', async function () {
            // Set up: both referrer and secondLevelReferrer have KYC Tier 1
            await registerUserWithKycTier1(secondLevelReferrer.address);
            await registerUserWithKycTier1(referrer.address, secondLevelReferrer.address);
            await registerUserWithKycTier1(user1.address, referrer.address);

            // Set ODDAO address
            await rewardManager.connect(admin).setOddaoAddress(oddao.address);

            // user1 claims welcome bonus
            await rewardManager.connect(user1).claimWelcomeBonusTrustless();

            // Both referrer and secondLevelReferrer should have accumulated bonuses
            const referrerPending = await rewardManager.getPendingReferralBonus(referrer.address);
            expect(referrerPending).to.be.greaterThan(0);

            const l2Pending = await rewardManager.getPendingReferralBonus(secondLevelReferrer.address);
            expect(l2Pending).to.be.greaterThan(0);

            // Verify the 70/20 split
            // referrerPending should be 70% of total, l2Pending should be 20%
            // referrerPending / l2Pending ≈ 70/20 = 3.5
            const ratio = Number(referrerPending) / Number(l2Pending);
            expect(ratio).to.be.closeTo(3.5, 0.1);
        });

        it('should correctly calculate bonus based on effective registrations', async function () {
            // Set legacy bonus claims count to simulate existing users
            await rewardManager.connect(admin).setLegacyBonusClaimsCount(3996);

            await registerUserWithKycTier1(user1.address);

            const balanceBefore = await omniCoin.balanceOf(user1.address);
            await rewardManager.connect(user1).claimWelcomeBonusTrustless();
            const balanceAfter = await omniCoin.balanceOf(user1.address);

            const bonusReceived = balanceAfter - balanceBefore;

            // With ~3997 effective registrations, should be in tier 2 (5000 XOM)
            // But the exact tier depends on totalRegistrations() + legacyCount
            expect(bonusReceived).to.equal(ethers.parseEther('5000'));
        });
    });
});
