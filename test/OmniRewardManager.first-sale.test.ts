/**
 * @file OmniRewardManager.first-sale.test.ts
 * @description On-chain E2E coverage for the first-sale-bonus claim path
 * (TODO #6-H, closed 2026-05-17). Walks the full register → KYC →
 * mark-first-sale-completed → claim-first-sale-bonus → markFirstSaleBonusClaimed
 * cycle, verifying the cross-contract callback into OmniRegistration fires
 * and the user's `firstSaleBonusClaimed` flag flips.
 *
 * Sybil guards exercised (so production regressions surface here):
 * - `MIN_FIRST_SALE_AMOUNT` (100 XOM minimum sale)
 * - `MIN_FIRST_SALE_AGE` (7 days between registration and first sale)
 * - `authorizedRecorders[]` gating on `markFirstSaleCompleted`
 * - Double-claim revert via `firstSaleBonusClaimed[user]`
 */

/* eslint-disable @typescript-eslint/no-var-requires */
const { expect } = require('chai');
const { ethers, upgrades } = require('hardhat');
const { time } = require('@nomicfoundation/hardhat-network-helpers');

const keccak256: (bytes: any) => string = ethers.keccak256;
const ZeroAddress: string = ethers.ZeroAddress;

describe('OmniRewardManager — first-sale bonus E2E', function () {
    // Contract instances
    let omniCoin: any;
    let rewardManager: any;
    let omniRegistration: any;

    // Signers
    let owner: any;
    let admin: any;
    let validator: any;
    let recorder: any;

    // Pool sizes
    const WELCOME_BONUS_POOL = ethers.parseEther('10000000');
    const REFERRAL_BONUS_POOL = ethers.parseEther('10000000');
    const FIRST_SALE_BONUS_POOL = ethers.parseEther('10000000');
    const TOTAL_POOL_SIZE = WELCOME_BONUS_POOL + REFERRAL_BONUS_POOL + FIRST_SALE_BONUS_POOL;

    // Post-cutover: attestations route through the (mocked) attestation
    // gateway, which accepts this 65-byte placeholder signature. The legacy
    // trusted-key signing path (setTrustedVerificationKey) now reverts
    // LegacyTrustedKeyRetired.
    const MOCK_SIG: string = '0x' + '00'.repeat(65);

    const CLAIM_FIRST_SALE_BONUS_TYPES = {
        ClaimFirstSaleBonus: [
            { name: 'user', type: 'address' },
            { name: 'nonce', type: 'uint256' },
            { name: 'deadline', type: 'uint256' },
        ],
    };

    /**
     * Sign a first-sale-bonus claim request (EIP-712).
     */
    async function signFirstSaleBonusClaim(
        signer: any,
        user: string,
        nonce: bigint,
        deadline: number,
    ): Promise<string> {
        const chainId = (await ethers.provider.getNetwork()).chainId;
        return signer.signTypedData(
            {
                name: 'OmniRewardManager',
                version: '1',
                chainId,
                verifyingContract: await rewardManager.getAddress(),
            },
            CLAIM_FIRST_SALE_BONUS_TYPES,
            { user, nonce, deadline },
        );
    }

    async function futureDeadline(): Promise<number> {
        const latest = await ethers.provider.getBlock('latest');
        return latest!.timestamp + 3600;
    }

    /**
     * Register a fresh wallet, complete KYC Tier 1, and fund it for gas.
     * Note: KYC Tier 1 is NOT a requirement of `claimFirstSaleBonus`, but
     * we attach it so the user could also claim welcome / referral bonuses
     * — this mirrors a real-world account state.
     */
    async function registerKycTier1User(): Promise<any> {
        const wallet = ethers.Wallet.createRandom().connect(ethers.provider);
        await owner.sendTransaction({
            to: wallet.address,
            value: ethers.parseEther('0.5'),
        });

        const phoneHash = keccak256(ethers.randomBytes(32));
        const emailHash = keccak256(ethers.randomBytes(32));
        await omniRegistration.connect(admin).registerUser(
            wallet.address, ZeroAddress, phoneHash, emailHash,
        ethers.ZeroHash,
        );

        const platform = 'twitter';
        const socialHash = keccak256(ethers.randomBytes(32));
        const latest = await ethers.provider.getBlock('latest');
        const socialTimestamp = latest!.timestamp;
        const socialNonce = '0x' + Buffer.from(ethers.randomBytes(32)).toString('hex');
        const socialDeadline = socialTimestamp + 3600;

        // Social attestation via the (mocked) gateway; supersedes = 0 (first).
        await omniRegistration.connect(wallet).submitSocialVerificationFor(
            wallet.address, socialHash, platform, ethers.ZeroHash,
            socialTimestamp, socialNonce, socialDeadline, MOCK_SIG,
        );

        return wallet;
    }

    beforeEach(async function () {
        [owner, admin, , , , , validator, recorder] = await ethers.getSigners();

        // OmniCoin
        const OmniCoinFactory = await ethers.getContractFactory('OmniCoin');
        omniCoin = await OmniCoinFactory.deploy(ethers.ZeroAddress);
        await omniCoin.waitForDeployment();
        await omniCoin.initialize();

        // OmniRewardManager (M-02: transfer tokens before initialize)
        const RewardMgrFactory = await ethers.getContractFactory('OmniRewardManager');
        const proxy = await upgrades.deployProxy(
            RewardMgrFactory,
            [
                await omniCoin.getAddress(),
                WELCOME_BONUS_POOL,
                REFERRAL_BONUS_POOL,
                FIRST_SALE_BONUS_POOL,
                admin.address,
            ],
            { initializer: false, kind: 'uups', constructorArgs: [ethers.ZeroAddress] },
        );
        await proxy.waitForDeployment();
        rewardManager = RewardMgrFactory.attach(await proxy.getAddress());

        await omniCoin.transfer(await rewardManager.getAddress(), TOTAL_POOL_SIZE);
        await rewardManager.initialize(
            await omniCoin.getAddress(),
            WELCOME_BONUS_POOL, REFERRAL_BONUS_POOL, FIRST_SALE_BONUS_POOL,
            admin.address,
        );

        // OmniRegistration (links OmniRegistrationDigestLib, extracted for EIP-170)
        const DigestLib = await ethers.getContractFactory('OmniRegistrationDigestLib');
        const digestLib = await DigestLib.deploy();
        await digestLib.waitForDeployment();
        const RegFactory = await ethers.getContractFactory('OmniRegistration', {
            libraries: { OmniRegistrationDigestLib: await digestLib.getAddress() },
        });
        const regProxy = await upgrades.deployProxy(
            RegFactory, [],
            {
                initializer: 'initialize',
                kind: 'uups',
                constructorArgs: [ethers.ZeroAddress],
                unsafeAllowLinkedLibraries: true,
            },
        );
        await regProxy.waitForDeployment();
        omniRegistration = RegFactory.attach(await regProxy.getAddress());

        // Wire the (mocked) attestation gateway — replaces the retired
        // setTrustedVerificationKey path (now reverts LegacyTrustedKeyRetired).
        const MockGateway = await ethers.getContractFactory('MockGatewayForDecent');
        const mockGateway = await MockGateway.deploy();
        await mockGateway.waitForDeployment();
        const MockVerifier = await ethers.getContractFactory('MockBridgeVerifier');
        const mockVerifier = await MockVerifier.deploy();
        await mockVerifier.waitForDeployment();
        await mockVerifier.setVerify(true, []);
        await mockGateway.setCommitteeVerifier(await mockVerifier.getAddress());

        const VALIDATOR_ROLE = keccak256(ethers.toUtf8Bytes('VALIDATOR_ROLE'));
        await omniRegistration.connect(owner).grantRole(VALIDATOR_ROLE, admin.address);
        await omniRegistration.connect(owner).setAttestationGateway(await mockGateway.getAddress());
        await rewardManager.connect(admin).setRegistrationContract(await omniRegistration.getAddress());
        await omniRegistration.connect(owner).setOmniRewardManagerAddress(await rewardManager.getAddress());

        // Authorize the recorder so it can call markFirstSaleCompleted.
        await omniRegistration.connect(owner).setAuthorizedRecorder(recorder.address, true);
    });

    /**
     * Happy path — register, age account, record first sale, claim bonus,
     * verify the cross-contract `markFirstSaleBonusClaimed` callback fires.
     */
    it('claims the first-sale bonus and marks the registration as claimed', async function () {
        this.timeout(120_000);

        const user = await registerKycTier1User();

        // Sybil guard: account must be MIN_FIRST_SALE_AGE old (7 days) before
        // a first sale is recordable. Advance time + add a buffer.
        await time.increase(7 * 86400 + 60);

        // Record a real first sale (saleAmount ≥ MIN_FIRST_SALE_AMOUNT = 100 XOM).
        const saleAmount = ethers.parseEther('150');
        await omniRegistration.connect(recorder).markFirstSaleCompleted(
            user.address, saleAmount, ZeroAddress,
        );
        expect(await omniRegistration.hasCompletedFirstSale(user.address)).to.be.true;

        // Pre-claim: not yet marked.
        let reg = await omniRegistration.getRegistration(user.address);
        expect(reg.firstSaleBonusClaimed).to.be.false;

        // User signs claim; relayer (validator) submits.
        const nonce = await rewardManager.getClaimNonce(user.address);
        const deadline = await futureDeadline();
        const sig = await signFirstSaleBonusClaim(user, user.address, nonce, deadline);

        const balanceBefore = await omniCoin.balanceOf(user.address);
        const tx = await rewardManager.connect(validator).claimFirstSaleBonus(
            user.address, nonce, deadline, sig,
        );

        // Both events emit.
        await expect(tx).to.emit(rewardManager, 'FirstSaleBonusClaimedRelayed');
        await expect(tx).to.emit(rewardManager, 'FirstSaleBonusClaimed');

        // User received tokens.
        const balanceAfter = await omniCoin.balanceOf(user.address);
        expect(balanceAfter - balanceBefore).to.be.greaterThan(0n);

        // Cross-contract callback flipped the flag on OmniRegistration.
        reg = await omniRegistration.getRegistration(user.address);
        expect(reg.firstSaleBonusClaimed).to.be.true;

        // Daily counter incremented.
        const today = BigInt(
            Math.floor((await ethers.provider.getBlock('latest'))!.timestamp / 86400),
        );
        expect(await rewardManager.dailyFirstSaleBonusCount(today)).to.equal(1n);
    });

    it('reverts the claim when the user has not completed a first sale', async function () {
        this.timeout(60_000);

        const user = await registerKycTier1User();

        const nonce = await rewardManager.getClaimNonce(user.address);
        const deadline = await futureDeadline();
        const sig = await signFirstSaleBonusClaim(user, user.address, nonce, deadline);

        await expect(
            rewardManager.connect(validator).claimFirstSaleBonus(
                user.address, nonce, deadline, sig,
            ),
        )
            .to.be.revertedWithCustomError(rewardManager, 'FirstSaleNotCompleted')
            .withArgs(user.address);
    });

    it('reverts a double-claim with BonusAlreadyClaimed', async function () {
        this.timeout(120_000);

        const user = await registerKycTier1User();
        await time.increase(7 * 86400 + 60);
        await omniRegistration.connect(recorder).markFirstSaleCompleted(
            user.address, ethers.parseEther('150'), ZeroAddress,
        );

        // First claim succeeds.
        const nonce1 = await rewardManager.getClaimNonce(user.address);
        const deadline = await futureDeadline();
        const sig1 = await signFirstSaleBonusClaim(user, user.address, nonce1, deadline);
        await rewardManager.connect(validator).claimFirstSaleBonus(
            user.address, nonce1, deadline, sig1,
        );

        // Second claim must revert with BonusAlreadyClaimed (PoolType.FirstSaleBonus = 2).
        const nonce2 = await rewardManager.getClaimNonce(user.address);
        const sig2 = await signFirstSaleBonusClaim(user, user.address, nonce2, deadline);
        await expect(
            rewardManager.connect(validator).claimFirstSaleBonus(
                user.address, nonce2, deadline, sig2,
            ),
        )
            .to.be.revertedWithCustomError(rewardManager, 'BonusAlreadyClaimed')
            .withArgs(user.address, 2);
    });

    it('rejects markFirstSaleCompleted from an unauthorized recorder', async function () {
        this.timeout(60_000);

        const user = await registerKycTier1User();
        await time.increase(7 * 86400 + 60);

        // `validator` is NOT in the authorizedRecorders set — must revert.
        await expect(
            omniRegistration.connect(validator).markFirstSaleCompleted(
                user.address, ethers.parseEther('150'), ZeroAddress,
            ),
        )
            .to.be.revertedWithCustomError(omniRegistration, 'UnauthorizedTransactionRecorder');
    });

    it('rejects markFirstSaleCompleted when sale amount is below the minimum', async function () {
        this.timeout(60_000);

        const user = await registerKycTier1User();
        await time.increase(7 * 86400 + 60);

        // MIN_FIRST_SALE_AMOUNT is 100 XOM — try 99 XOM.
        await expect(
            omniRegistration.connect(recorder).markFirstSaleCompleted(
                user.address, ethers.parseEther('99'), ZeroAddress,
            ),
        )
            .to.be.revertedWithCustomError(omniRegistration, 'FirstSaleRequirementsNotMet');
    });

    it('rejects markFirstSaleCompleted when account is younger than the minimum age', async function () {
        this.timeout(60_000);

        const user = await registerKycTier1User();
        // Do NOT advance time — account < 7 days old.

        await expect(
            omniRegistration.connect(recorder).markFirstSaleCompleted(
                user.address, ethers.parseEther('150'), ZeroAddress,
            ),
        )
            .to.be.revertedWithCustomError(omniRegistration, 'FirstSaleRequirementsNotMet');
    });
});
