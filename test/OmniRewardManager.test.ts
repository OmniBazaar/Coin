/**
 * @file OmniRewardManager.test.ts
 * @description Comprehensive tests for OmniRewardManager contract
 *
 * Tests cover:
 * - Initialization and role setup
 * - Welcome bonus claims (gasless relay with EIP-712 signatures)
 * - Referral bonus claims (gasless relay)
 * - First sale bonus claims (gasless relay)
 * - Admin functions (pause/unpause)
 * - Pool depletion scenarios
 * - Access control
 * - Upgrade functionality
 */

/* eslint-disable @typescript-eslint/no-var-requires */
const { expect } = require('chai');
const { ethers, upgrades } = require('hardhat');
const { keccak256, ZeroAddress } = require('ethers');

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

    // Role constants
    const DEFAULT_ADMIN_ROLE = ethers.ZeroHash;
    const UPGRADER_ROLE = keccak256(ethers.toUtf8Bytes('UPGRADER_ROLE'));
    const PAUSER_ROLE = keccak256(ethers.toUtf8Bytes('PAUSER_ROLE'));

    // Pool types enum
    const PoolType = {
        WelcomeBonus: 0,
        ReferralBonus: 1,
        FirstSaleBonus: 2,
    };

    // EIP-712 typehashes (must match contract constants)
    const CLAIM_WELCOME_BONUS_TYPEHASH = keccak256(
        ethers.toUtf8Bytes('ClaimWelcomeBonus(address user,uint256 nonce,uint256 deadline)')
    );
    const CLAIM_REFERRAL_BONUS_TYPEHASH = keccak256(
        ethers.toUtf8Bytes('ClaimReferralBonus(address user,uint256 nonce,uint256 deadline)')
    );
    const CLAIM_FIRST_SALE_BONUS_TYPEHASH = keccak256(
        ethers.toUtf8Bytes('ClaimFirstSaleBonus(address user,uint256 nonce,uint256 deadline)')
    );

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

        // Transfer tokens to reward manager BEFORE initialization (M-02 balance check)
        await omniCoin.transfer(await rewardManager.getAddress(), TOTAL_POOL_SIZE);

        // Now initialize the proxy with the required parameters
        await rewardManager.initialize(
            await omniCoin.getAddress(),
            WELCOME_BONUS_POOL,
            REFERRAL_BONUS_POOL,
            FIRST_SALE_BONUS_POOL,
            admin.address
        );

        // Grant operational roles to admin (audit reduced _setupRoles to DEFAULT_ADMIN_ROLE only)
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

        it('should set up roles correctly', async function () {
            expect(await rewardManager.hasRole(DEFAULT_ADMIN_ROLE, admin.address)).to.be.true;
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
    // Admin Functions Tests
    // ========================================

    describe('Admin Functions', function () {
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
            expect(await upgraded.hasClaimedWelcomeBonus(user1.address)).to.be.false;
        });
    });

    // ========================================
    // Role Management Tests
    // ========================================

    describe('Role Management', function () {
        it('should allow admin to grant roles', async function () {
            await rewardManager.connect(admin).grantRole(
                UPGRADER_ROLE,
                user1.address
            );

            expect(await rewardManager.hasRole(UPGRADER_ROLE, user1.address))
                .to.be.true;
        });

        it('should allow admin to revoke roles', async function () {
            // First grant
            await rewardManager.connect(admin).grantRole(
                UPGRADER_ROLE,
                user1.address
            );

            // Then revoke
            await rewardManager.connect(admin).revokeRole(
                UPGRADER_ROLE,
                user1.address
            );

            expect(await rewardManager.hasRole(UPGRADER_ROLE, user1.address))
                .to.be.false;
        });

        it('should reject role management from non-admin', async function () {
            await expect(
                rewardManager.connect(unauthorized).grantRole(
                    UPGRADER_ROLE,
                    user1.address
                )
            ).to.be.revertedWithCustomError(rewardManager, 'AccessControlUnauthorizedAccount');
        });
    });

    // ========================================
    // Gasless Relay Welcome Bonus Tests
    // ========================================

    describe('Welcome Bonus (claimWelcomeBonus - gasless relay)', function () {
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

        /**
         * Sign a welcome bonus claim request (EIP-712)
         */
        async function signWelcomeBonusClaim(
            signer: any,
            user: string,
            nonce: bigint,
            deadline: number
        ): Promise<string> {
            const network = await ethers.provider.getNetwork();
            const domain = {
                name: 'OmniRewardManager',
                version: '1',
                chainId: network.chainId,
                verifyingContract: await rewardManager.getAddress(),
            };

            const types = {
                ClaimWelcomeBonus: [
                    { name: 'user', type: 'address' },
                    { name: 'nonce', type: 'uint256' },
                    { name: 'deadline', type: 'uint256' },
                ],
            };

            const value = { user, nonce, deadline };
            return signer.signTypedData(domain, types, value);
        }

        /**
         * Sign a referral bonus claim request (EIP-712)
         */
        async function signReferralBonusClaim(
            signer: any,
            user: string,
            nonce: bigint,
            deadline: number
        ): Promise<string> {
            const network = await ethers.provider.getNetwork();
            const domain = {
                name: 'OmniRewardManager',
                version: '1',
                chainId: network.chainId,
                verifyingContract: await rewardManager.getAddress(),
            };

            const types = {
                ClaimReferralBonus: [
                    { name: 'user', type: 'address' },
                    { name: 'nonce', type: 'uint256' },
                    { name: 'deadline', type: 'uint256' },
                ],
            };

            const value = { user, nonce, deadline };
            return signer.signTypedData(domain, types, value);
        }

        /**
         * Sign a first sale bonus claim request (EIP-712)
         */
        async function signFirstSaleBonusClaim(
            signer: any,
            user: string,
            nonce: bigint,
            deadline: number
        ): Promise<string> {
            const network = await ethers.provider.getNetwork();
            const domain = {
                name: 'OmniRewardManager',
                version: '1',
                chainId: network.chainId,
                verifyingContract: await rewardManager.getAddress(),
            };

            const types = {
                ClaimFirstSaleBonus: [
                    { name: 'user', type: 'address' },
                    { name: 'nonce', type: 'uint256' },
                    { name: 'deadline', type: 'uint256' },
                ],
            };

            const value = { user, nonce, deadline };
            return signer.signTypedData(domain, types, value);
        }

        /**
         * Get a future deadline timestamp
         */
        async function getFutureDeadline(): Promise<number> {
            const latestBlock = await ethers.provider.getBlock('latest');
            return latestBlock!.timestamp + 3600;
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
            await omniRegistration.connect(userSigner).submitSocialVerificationFor(
                userAddr,
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

        it('should allow claiming after KYC Tier 1 completion (relayed)', async function () {
            // Register user with KYC Tier 1 using helper function
            await registerUserWithKycTier1(user1.address);

            // Verify KYC Tier 1 is complete
            expect(await omniRegistration.hasKycTier1(user1.address)).to.be.true;

            // Create EIP-712 signed claim
            const nonce = await rewardManager.getClaimNonce(user1.address);
            const deadline = await getFutureDeadline();
            const signature = await signWelcomeBonusClaim(user1, user1.address, nonce, deadline);

            // Relay the claim (validator pays gas)
            const balanceBefore = await omniCoin.balanceOf(user1.address);
            await rewardManager.connect(validator).claimWelcomeBonus(
                user1.address, nonce, deadline, signature
            );
            const balanceAfter = await omniCoin.balanceOf(user1.address);

            // Verify user received tokens (10000 XOM for first 1000 users)
            expect(balanceAfter).to.be.greaterThan(balanceBefore);
            const received = balanceAfter - balanceBefore;
            expect(received).to.equal(ethers.parseEther('10000'));
        });

        it('should emit WelcomeBonusClaimedRelayed event', async function () {
            await registerUserWithKycTier1(user1.address);

            const nonce = await rewardManager.getClaimNonce(user1.address);
            const deadline = await getFutureDeadline();
            const signature = await signWelcomeBonusClaim(user1, user1.address, nonce, deadline);

            await expect(rewardManager.connect(validator).claimWelcomeBonus(
                user1.address, nonce, deadline, signature
            ))
                .to.emit(rewardManager, 'WelcomeBonusClaimedRelayed');
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

            // Try to claim via relay
            const nonce = await rewardManager.getClaimNonce(user1.address);
            const deadline = await getFutureDeadline();
            const signature = await signWelcomeBonusClaim(user1, user1.address, nonce, deadline);

            await expect(rewardManager.connect(validator).claimWelcomeBonus(
                user1.address, nonce, deadline, signature
            ))
                .to.be.revertedWithCustomError(rewardManager, 'KycTier1Required')
                .withArgs(user1.address);
        });

        it('should reject when user is not registered', async function () {
            const nonce = await rewardManager.getClaimNonce(user1.address);
            const deadline = await getFutureDeadline();
            const signature = await signWelcomeBonusClaim(user1, user1.address, nonce, deadline);

            await expect(rewardManager.connect(validator).claimWelcomeBonus(
                user1.address, nonce, deadline, signature
            ))
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

            // Don't set registration contract — try to claim
            const nonce = BigInt(0);
            const deadline = await getFutureDeadline();
            const signature = await signWelcomeBonusClaim(user1, user1.address, nonce, deadline);

            await expect(newRewardManager.connect(validator).claimWelcomeBonus(
                user1.address, nonce, deadline, signature
            ))
                .to.be.revertedWithCustomError(newRewardManager, 'RegistrationContractNotSet');
        });

        it('should reject double claims', async function () {
            await registerUserWithKycTier1(user1.address);

            // First claim should succeed
            const nonce1 = await rewardManager.getClaimNonce(user1.address);
            const deadline = await getFutureDeadline();
            const sig1 = await signWelcomeBonusClaim(user1, user1.address, nonce1, deadline);
            await rewardManager.connect(validator).claimWelcomeBonus(
                user1.address, nonce1, deadline, sig1
            );

            // Second claim should fail
            const nonce2 = await rewardManager.getClaimNonce(user1.address);
            const sig2 = await signWelcomeBonusClaim(user1, user1.address, nonce2, deadline);
            await expect(rewardManager.connect(validator).claimWelcomeBonus(
                user1.address, nonce2, deadline, sig2
            ))
                .to.be.revertedWithCustomError(rewardManager, 'BonusAlreadyClaimed')
                .withArgs(user1.address, PoolType.WelcomeBonus);
        });

        it('should block claims when paused', async function () {
            await registerUserWithKycTier1(user1.address);
            await rewardManager.connect(admin).pause();

            const nonce = await rewardManager.getClaimNonce(user1.address);
            const deadline = await getFutureDeadline();
            const signature = await signWelcomeBonusClaim(user1, user1.address, nonce, deadline);

            await expect(rewardManager.connect(validator).claimWelcomeBonus(
                user1.address, nonce, deadline, signature
            ))
                .to.be.revertedWithCustomError(rewardManager, 'EnforcedPause');
        });

        it('should reject expired deadline', async function () {
            await registerUserWithKycTier1(user1.address);

            const nonce = await rewardManager.getClaimNonce(user1.address);
            const deadline = 1; // Expired timestamp
            const signature = await signWelcomeBonusClaim(user1, user1.address, nonce, deadline);

            await expect(rewardManager.connect(validator).claimWelcomeBonus(
                user1.address, nonce, deadline, signature
            ))
                .to.be.revertedWithCustomError(rewardManager, 'ClaimDeadlineExpired');
        });

        it('should reject invalid nonce', async function () {
            await registerUserWithKycTier1(user1.address);

            const wrongNonce = BigInt(999);
            const deadline = await getFutureDeadline();
            const signature = await signWelcomeBonusClaim(user1, user1.address, wrongNonce, deadline);

            await expect(rewardManager.connect(validator).claimWelcomeBonus(
                user1.address, wrongNonce, deadline, signature
            ))
                .to.be.revertedWithCustomError(rewardManager, 'InvalidClaimNonce');
        });

        it('should reject wrong signer', async function () {
            await registerUserWithKycTier1(user1.address);

            const nonce = await rewardManager.getClaimNonce(user1.address);
            const deadline = await getFutureDeadline();
            // Sign with user2's key but claim for user1
            const signature = await signWelcomeBonusClaim(user2, user1.address, nonce, deadline);

            await expect(rewardManager.connect(validator).claimWelcomeBonus(
                user1.address, nonce, deadline, signature
            ))
                .to.be.revertedWithCustomError(rewardManager, 'InvalidUserSignature');
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

            // Claim welcome bonus via relay
            const nonce = await rewardManager.getClaimNonce(user1.address);
            const deadline = await getFutureDeadline();
            const signature = await signWelcomeBonusClaim(user1, user1.address, nonce, deadline);
            await rewardManager.connect(validator).claimWelcomeBonus(
                user1.address, nonce, deadline, signature
            );

            // Referral bonus should be ACCUMULATED (not transferred immediately)
            const pendingAfter = await rewardManager.getPendingReferralBonus(referrer.address);
            expect(pendingAfter).to.be.greaterThan(0);

            // Verify referrer can claim the accumulated bonus via relay
            const referrerNonce = await rewardManager.getClaimNonce(referrer.address);
            const referrerDeadline = await getFutureDeadline();
            const referrerSig = await signReferralBonusClaim(
                referrer, referrer.address, referrerNonce, referrerDeadline
            );

            const referrerBalanceBefore = await omniCoin.balanceOf(referrer.address);
            await rewardManager.connect(validator).claimReferralBonus(
                referrer.address, referrerNonce, referrerDeadline, referrerSig
            );
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

            // Complete KYC Tier 1 for referrer (needed to pass registerUser referrer check)
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
            await omniRegistration.connect(referrer).submitSocialVerificationFor(
                referrer.address, socialHash1, 'twitter', socialTimestamp1, socialNonce1, socialDeadline1, socialSig1
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

            // user1 claims welcome bonus via relay → referral bonus should be SKIPPED
            const pendingBefore = await rewardManager.getPendingReferralBonus(referrer.address);
            expect(pendingBefore).to.equal(0);

            const nonce = await rewardManager.getClaimNonce(user1.address);
            const deadline = await getFutureDeadline();
            const signature = await signWelcomeBonusClaim(user1, user1.address, nonce, deadline);
            await rewardManager.connect(validator).claimWelcomeBonus(
                user1.address, nonce, deadline, signature
            );

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

            // 7. user1 claims welcome bonus via relay
            const nonce = await rewardManager.getClaimNonce(user1.address);
            const deadline = await getFutureDeadline();
            const signature = await signWelcomeBonusClaim(user1, user1.address, nonce, deadline);
            await rewardManager.connect(validator).claimWelcomeBonus(
                user1.address, nonce, deadline, signature
            );

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

            // user1 claims welcome bonus via relay
            const nonce = await rewardManager.getClaimNonce(user1.address);
            const deadline = await getFutureDeadline();
            const signature = await signWelcomeBonusClaim(user1, user1.address, nonce, deadline);
            await rewardManager.connect(validator).claimWelcomeBonus(
                user1.address, nonce, deadline, signature
            );

            // Both referrer and secondLevelReferrer should have accumulated bonuses
            const referrerPending = await rewardManager.getPendingReferralBonus(referrer.address);
            expect(referrerPending).to.be.greaterThan(0);

            const l2Pending = await rewardManager.getPendingReferralBonus(secondLevelReferrer.address);
            expect(l2Pending).to.be.greaterThan(0);

            // Verify the 70/20 split
            // referrerPending / l2Pending ≈ 70/20 = 3.5
            const ratio = Number(referrerPending) / Number(l2Pending);
            expect(ratio).to.be.closeTo(3.5, 0.1);
        });

        it('should correctly calculate bonus based on effective registrations', async function () {
            // Set legacy bonus claims count to simulate existing users
            await rewardManager.connect(admin).setLegacyBonusClaimsCount(3996);

            await registerUserWithKycTier1(user1.address);

            const nonce = await rewardManager.getClaimNonce(user1.address);
            const deadline = await getFutureDeadline();
            const signature = await signWelcomeBonusClaim(user1, user1.address, nonce, deadline);

            const balanceBefore = await omniCoin.balanceOf(user1.address);
            await rewardManager.connect(validator).claimWelcomeBonus(
                user1.address, nonce, deadline, signature
            );
            const balanceAfter = await omniCoin.balanceOf(user1.address);

            const bonusReceived = balanceAfter - balanceBefore;

            // With ~3997 effective registrations, should be in tier 2 (5000 XOM)
            expect(bonusReceived).to.equal(ethers.parseEther('5000'));
        });

        it('should increment nonce after claim', async function () {
            await registerUserWithKycTier1(user1.address);

            const nonceBefore = await rewardManager.getClaimNonce(user1.address);
            expect(nonceBefore).to.equal(0);

            const deadline = await getFutureDeadline();
            const signature = await signWelcomeBonusClaim(user1, user1.address, nonceBefore, deadline);
            await rewardManager.connect(validator).claimWelcomeBonus(
                user1.address, nonceBefore, deadline, signature
            );

            const nonceAfter = await rewardManager.getClaimNonce(user1.address);
            expect(nonceAfter).to.equal(1);
        });

        it('should mark user as claimed', async function () {
            await registerUserWithKycTier1(user1.address);

            expect(await rewardManager.hasClaimedWelcomeBonus(user1.address)).to.be.false;

            const nonce = await rewardManager.getClaimNonce(user1.address);
            const deadline = await getFutureDeadline();
            const signature = await signWelcomeBonusClaim(user1, user1.address, nonce, deadline);
            await rewardManager.connect(validator).claimWelcomeBonus(
                user1.address, nonce, deadline, signature
            );

            expect(await rewardManager.hasClaimedWelcomeBonus(user1.address)).to.be.true;
        });

        it('should update pool statistics correctly', async function () {
            await registerUserWithKycTier1(user1.address);

            const nonce = await rewardManager.getClaimNonce(user1.address);
            const deadline = await getFutureDeadline();
            const signature = await signWelcomeBonusClaim(user1, user1.address, nonce, deadline);
            await rewardManager.connect(validator).claimWelcomeBonus(
                user1.address, nonce, deadline, signature
            );

            const [initialAmounts, remainingAmounts, distributedAmounts] =
                await rewardManager.getPoolStatistics();

            const bonusAmount = ethers.parseEther('10000'); // Tier 1 bonus
            expect(initialAmounts[0]).to.equal(WELCOME_BONUS_POOL);
            expect(remainingAmounts[0]).to.equal(WELCOME_BONUS_POOL - bonusAmount);
            expect(distributedAmounts[0]).to.equal(bonusAmount);
        });
    });
});
