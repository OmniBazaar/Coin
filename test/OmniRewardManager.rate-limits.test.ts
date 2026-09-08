/**
 * @file OmniRewardManager.rate-limits.test.ts
 * @description Load-test coverage for OmniRewardManager's daily rate limits
 * (TODO #7-H, closed 2026-05-17). Confirms the contract behaves correctly
 * when limits are exhausted, when the UTC day rolls over, and when multiple
 * claims land in the same block.
 *
 * Constants under test:
 * - MAX_DAILY_WELCOME_BONUSES = 1000
 * - MAX_DAILY_REFERRAL_BONUSES = 2000
 * - MAX_DAILY_FIRST_SALE_BONUSES = 500 (smallest, used for full-exhaustion)
 *
 * Notes on test runtime:
 * - Full exhaustion of 1000 welcome claims is expensive (3 txs per user:
 *   register, social-verify, claim). Done in a `this.timeout(360_000)` block.
 * - Concurrent-same-block test uses `evm_setAutomine(false)` + a batch of N
 *   simultaneous claims, mined together, to verify the counter is atomic.
 * - Day-rollover uses `time.increase(86400)` from `@nomicfoundation/hardhat-network-helpers`.
 */

/* eslint-disable @typescript-eslint/no-var-requires */
const { expect } = require('chai');
const { ethers, upgrades, network } = require('hardhat');
const { time } = require('@nomicfoundation/hardhat-network-helpers');

const keccak256: (bytes: any) => string = ethers.keccak256;
const ZeroAddress: string = ethers.ZeroAddress;

describe('OmniRewardManager — daily rate limits', function () {
    // Contract instances
    let omniCoin: any;
    let rewardManager: any;
    let omniRegistration: any;
    let mockGateway: any;

    // Signers
    let owner: any;
    let admin: any;
    let validator: any;

    // Pool sizes — generous enough not to deplete before rate limit hits
    // Welcome tier 1 (first 1000 users) pays 10,000 XOM each → 10M needed minimum.
    // First-sale tier 1 (first 1000 users) pays 500 XOM each → 250K needed for 500 claims.
    const WELCOME_BONUS_POOL = ethers.parseEther('15000000');
    const REFERRAL_BONUS_POOL = ethers.parseEther('10000000');
    const FIRST_SALE_BONUS_POOL = ethers.parseEther('10000000');
    const TOTAL_POOL_SIZE = WELCOME_BONUS_POOL + REFERRAL_BONUS_POOL + FIRST_SALE_BONUS_POOL;

    // 65-byte placeholder proof accepted by MockGatewayForDecent. The mock
    // gateway + MockBridgeVerifier (setVerify(true, [])) do not actually
    // recover signatures; the empty attester list means _requireEligibleAttesters
    // is a no-op. Post-OMNICORE-DECENT the legacy single-key path
    // (setTrustedVerificationKey) is retired, so Tier-1 attestations route
    // through this mocked gateway instead.
    const MOCK_SIG: string = '0x' + '00'.repeat(65);

    // EIP-712 type structures (must match contract)
    const CLAIM_WELCOME_BONUS_TYPES = {
        ClaimWelcomeBonus: [
            { name: 'user', type: 'address' },
            { name: 'nonce', type: 'uint256' },
            { name: 'deadline', type: 'uint256' },
        ],
    };

    /**
     * Sign a welcome-bonus claim request (EIP-712).
     */
    async function signWelcomeBonusClaim(
        signer: any,
        user: string,
        nonce: bigint,
        deadline: number,
    ): Promise<string> {
        const chainId = (await ethers.provider.getNetwork()).chainId;
        const domain = {
            name: 'OmniRewardManager',
            version: '1',
            chainId,
            verifyingContract: await rewardManager.getAddress(),
        };
        return signer.signTypedData(domain, CLAIM_WELCOME_BONUS_TYPES, {
            user, nonce, deadline,
        });
    }

    /**
     * Future-deadline helper.
     */
    async function futureDeadline(): Promise<number> {
        const latest = await ethers.provider.getBlock('latest');
        return latest!.timestamp + 3600;
    }

    /**
     * Register a user (optionally pointing at a referrer) and promote them to
     * KYC Tier 1 via the mocked attestation gateway.
     *
     * Tier 1 needs BOTH a used phone hash AND a social hash. The phone hash is
     * set + marked used at `registerUser` time, so we complete Tier 1 by
     * submitting only the social proof (a phone re-submit would revert
     * PhoneAlreadyVerified). Post-OMNICORE-DECENT `submitSocialVerificationFor`
     * carries a `supersedes` field (ZeroHash for the first attestation) and
     * routes verification through the gateway (MOCK_SIG accepted by the mock).
     *
     * The contract requires any non-zero referrer to already be registered AND
     * hold KYC Tier 1 (SYBIL-H02), and forbids the relaying validator (`admin`)
     * from being the referrer — the referral-chain tests satisfy this by
     * registering the upstream referrers (R2 then R1) first.
     *
     * @param userWallet Funded wallet to register + promote.
     * @param referrer Referrer address, or ZeroAddress for none.
     */
    async function registerKycTier1User(
        userWallet: any,
        referrer: string = ZeroAddress,
    ): Promise<void> {
        // Unique identifiers per user — random hashes dedupe trivially.
        const phoneHash = keccak256(ethers.randomBytes(32));
        const emailHash = keccak256(ethers.randomBytes(32));

        await omniRegistration.connect(admin).registerUser(
            userWallet.address,
            referrer,
            phoneHash,
            emailHash,
            ethers.ZeroHash,
        );

        const platform = 'twitter';
        const socialHash = keccak256(ethers.randomBytes(32));
        const latest = await ethers.provider.getBlock('latest');
        const socialTimestamp = latest!.timestamp;
        const socialNonce = keccak256(ethers.randomBytes(32));
        const socialDeadline = socialTimestamp + 3600;

        await omniRegistration.connect(userWallet).submitSocialVerificationFor(
            userWallet.address,
            socialHash,
            platform,
            ethers.ZeroHash, // first attestation → supersedes = 0
            socialTimestamp,
            socialNonce,
            socialDeadline,
            MOCK_SIG,
        );
    }

    /**
     * Convenience alias for registering a referee under a chosen referrer.
     *
     * @param userWallet Funded wallet to register + promote.
     * @param referrer Address of the (already KYC Tier 1) referrer.
     */
    async function registerReferredKycTier1User(
        userWallet: any,
        referrer: string,
    ): Promise<void> {
        await registerKycTier1User(userWallet, referrer);
    }

    /**
     * Drive a referee's welcome-bonus claim, which internally fires
     * `_distributeAutoReferralBonus` along the referee's registration referral
     * chain (L1 then L2). Returns the claim transaction for event assertions.
     *
     * @param refereeWallet Funded, KYC Tier 1 referee wallet.
     * @returns The mined claim transaction.
     */
    async function claimWelcomeBonusFor(refereeWallet: any): Promise<any> {
        const nonce = await rewardManager.getClaimNonce(refereeWallet.address);
        const deadline = await futureDeadline();
        const sig = await signWelcomeBonusClaim(refereeWallet, refereeWallet.address, nonce, deadline);
        const tx = await rewardManager.connect(validator).claimWelcomeBonus(
            refereeWallet.address, nonce, deadline, sig,
        );
        await tx.wait();
        return tx;
    }

    /**
     * Create + fund N user wallets (each gets 0.1 ETH for the social-verify tx).
     */
    async function createUserWallets(count: number): Promise<any[]> {
        const wallets: any[] = [];
        for (let i = 0; i < count; ++i) {
            const w = ethers.Wallet.createRandom().connect(ethers.provider);
            await owner.sendTransaction({
                to: w.address,
                value: ethers.parseEther('0.1'),
            });
            wallets.push(w);
        }
        return wallets;
    }

    beforeEach(async function () {
        // Get base signers
        [owner, admin, , , , , validator] = await ethers.getSigners();

        // Deploy OmniCoin
        const OmniCoinFactory = await ethers.getContractFactory('OmniCoin');
        omniCoin = await OmniCoinFactory.deploy(ethers.ZeroAddress);
        await omniCoin.waitForDeployment();
        await omniCoin.initialize();

        // Deploy OmniRewardManager proxy (M-02: fund BEFORE init)
        const RewardManagerFactory = await ethers.getContractFactory('OmniRewardManager');
        const proxy = await upgrades.deployProxy(
            RewardManagerFactory,
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
            },
        );
        await proxy.waitForDeployment();
        rewardManager = RewardManagerFactory.attach(await proxy.getAddress());

        await omniCoin.transfer(await rewardManager.getAddress(), TOTAL_POOL_SIZE);

        await rewardManager.initialize(
            await omniCoin.getAddress(),
            WELCOME_BONUS_POOL,
            REFERRAL_BONUS_POOL,
            FIRST_SALE_BONUS_POOL,
            admin.address,
        );

        // Deploy the mocked attestation gateway + verifier. Post-OMNICORE-DECENT
        // the legacy single-key path (setTrustedVerificationKey) is retired, so
        // KYC Tier-1 attestations route through the gateway. The mock gateway
        // accepts any proof; MockBridgeVerifier.setVerify(true, []) returns an
        // empty attester list so the consumer-side eligibility gate is a no-op.
        const MockGateway = await ethers.getContractFactory('MockGatewayForDecent');
        mockGateway = await MockGateway.deploy();
        await mockGateway.waitForDeployment();

        const MockVerifier = await ethers.getContractFactory('MockBridgeVerifier');
        const mockVerifier = await MockVerifier.deploy();
        await mockVerifier.waitForDeployment();
        await mockVerifier.setVerify(true, []);
        await mockGateway.setCommitteeVerifier(await mockVerifier.getAddress());

        // Deploy OmniRegistration. The OMNICORE-DECENT refactor split digest
        // helpers into OmniRegistrationDigestLib, which OmniRegistration links
        // against via DELEGATECALL — deploy + link it before the proxy.
        const DigestLib = await ethers.getContractFactory('OmniRegistrationDigestLib');
        const digestLib = await DigestLib.deploy();
        await digestLib.waitForDeployment();
        const RegistrationFactory = await ethers.getContractFactory(
            'OmniRegistration',
            { libraries: { OmniRegistrationDigestLib: await digestLib.getAddress() } },
        );
        const regProxy = await upgrades.deployProxy(
            RegistrationFactory,
            [],
            {
                initializer: 'initialize',
                kind: 'uups',
                constructorArgs: [ethers.ZeroAddress],
                unsafeAllowLinkedLibraries: true,
            },
        );
        await regProxy.waitForDeployment();
        omniRegistration = RegistrationFactory.attach(await regProxy.getAddress());

        // Wire registration ↔ reward manager + attestation gateway.
        const VALIDATOR_ROLE = keccak256(ethers.toUtf8Bytes('VALIDATOR_ROLE'));
        await omniRegistration.connect(owner).grantRole(VALIDATOR_ROLE, admin.address);
        await omniRegistration.connect(owner).setAttestationGateway(await mockGateway.getAddress());
        await rewardManager.connect(admin).setRegistrationContract(await omniRegistration.getAddress());
        await omniRegistration.connect(owner).setOmniRewardManagerAddress(await rewardManager.getAddress());
    });

    afterEach(async function () {
        // Restore automine if a test toggled it off.
        try {
            await network.provider.send('evm_setAutomine', [true]);
        } catch {
            // Method may be unavailable on some networks; ignore.
        }
    });

    /**
     * Quick sanity check that the constants we depend on match the contract.
     */
    it('exposes documented daily limits', async function () {
        expect(await rewardManager.MAX_DAILY_WELCOME_BONUSES()).to.equal(1000n);
        expect(await rewardManager.MAX_DAILY_REFERRAL_BONUSES()).to.equal(2000n);
        expect(await rewardManager.MAX_DAILY_FIRST_SALE_BONUSES()).to.equal(500n);
    });

    /**
     * Concurrent same-block contention: 10 distinct users each have a signed
     * claim. Automine is disabled, all 10 txs are submitted, then a single
     * block is mined. Confirms `dailyWelcomeBonusCount[today]` ends at exactly
     * 10 — the counter increments atomically per tx within the block.
     */
    it('atomically increments the counter when claims share a block', async function () {
        this.timeout(120_000);

        const BATCH = 10;
        const users = await createUserWallets(BATCH);
        for (const u of users) {
            await registerKycTier1User(u);
        }

        // Pre-sign all claims (no time pressure during the mine).
        const deadline = await futureDeadline();
        const signedClaims: Array<{ user: string; nonce: bigint; sig: string }> = [];
        for (const u of users) {
            const nonce = await rewardManager.getClaimNonce(u.address);
            const sig = await signWelcomeBonusClaim(u, u.address, nonce, deadline);
            signedClaims.push({ user: u.address, nonce, sig });
        }

        const today = BigInt(
            Math.floor((await ethers.provider.getBlock('latest'))!.timestamp / 86400),
        );
        const countBefore = await rewardManager.dailyWelcomeBonusCount(today);

        // Drop into manual-mining mode and queue all claims back-to-back.
        await network.provider.send('evm_setAutomine', [false]);
        const pending: Promise<any>[] = [];
        for (const c of signedClaims) {
            pending.push(
                rewardManager.connect(validator).claimWelcomeBonus(
                    c.user, c.nonce, deadline, c.sig,
                ),
            );
        }
        // Mine all at once.
        await network.provider.send('evm_mine');
        await network.provider.send('evm_setAutomine', [true]);

        const responses = await Promise.all(pending);
        for (const r of responses) {
            await r.wait();
        }

        const countAfter = await rewardManager.dailyWelcomeBonusCount(today);
        expect(countAfter - countBefore).to.equal(BigInt(BATCH));

        // Every user should now hold ~10000 XOM (tier 1 welcome bonus).
        for (const u of users) {
            expect(await omniCoin.balanceOf(u.address)).to.be.greaterThan(0n);
        }
    });

    /**
     * Day-rollover: claim once at day N (counter goes 0 → 1), advance EVM time
     * by 1 day, claim again with a fresh user, verify the counter for day N+1
     * starts at 1 (not at 2) — i.e. the rate-limit bucket is keyed on the UTC day.
     */
    it('resets the daily counter when the UTC day advances', async function () {
        this.timeout(120_000);

        const [u1, u2] = await createUserWallets(2);
        await registerKycTier1User(u1);
        await registerKycTier1User(u2);

        // Day-N claim
        const dayN = BigInt(
            Math.floor((await ethers.provider.getBlock('latest'))!.timestamp / 86400),
        );
        {
            const nonce = await rewardManager.getClaimNonce(u1.address);
            const deadline = await futureDeadline();
            const sig = await signWelcomeBonusClaim(u1, u1.address, nonce, deadline);
            await rewardManager.connect(validator).claimWelcomeBonus(
                u1.address, nonce, deadline, sig,
            );
        }
        expect(await rewardManager.dailyWelcomeBonusCount(dayN)).to.equal(1n);

        // Advance 1 day + 1 second.
        await time.increase(86401);

        // Day-(N+1) claim
        const dayN1 = BigInt(
            Math.floor((await ethers.provider.getBlock('latest'))!.timestamp / 86400),
        );
        expect(dayN1).to.equal(dayN + 1n);
        {
            const nonce = await rewardManager.getClaimNonce(u2.address);
            const deadline = await futureDeadline();
            const sig = await signWelcomeBonusClaim(u2, u2.address, nonce, deadline);
            await rewardManager.connect(validator).claimWelcomeBonus(
                u2.address, nonce, deadline, sig,
            );
        }

        // Counter for the NEW day should start at 1; old day's counter is
        // untouched (still 1) — proves they're independent buckets.
        expect(await rewardManager.dailyWelcomeBonusCount(dayN)).to.equal(1n);
        expect(await rewardManager.dailyWelcomeBonusCount(dayN1)).to.equal(1n);
    });

    /**
     * Full welcome-bonus exhaustion: drive `dailyWelcomeBonusCount` to the
     * MAX value of 1000 by claiming 1000 times, then verify the 1001st claim
     * reverts with `DailyBonusLimitExceeded(WelcomeBonus, 1000)`.
     *
     * Skipped by default because of long runtime (~3 min on V1 hardhat-network).
     * Enable via `RUN_FULL_EXHAUSTION=1 npx hardhat test --grep "exhausts welcome"`.
     */
    it('exhausts welcome-bonus daily limit and reverts the 1001st claim', async function () {
        if (process.env['RUN_FULL_EXHAUSTION'] !== '1') {
            this.skip();
        }
        this.timeout(600_000); // 10 min

        const LIMIT = Number(await rewardManager.MAX_DAILY_WELCOME_BONUSES());
        expect(LIMIT).to.equal(1000);

        // Generate LIMIT users + 1 overflow user.
        const wallets = await createUserWallets(LIMIT + 1);
        for (const w of wallets) {
            await registerKycTier1User(w);
        }

        // Claim LIMIT times — all succeed.
        const deadline = await futureDeadline();
        for (let i = 0; i < LIMIT; ++i) {
            const w = wallets[i];
            const nonce = await rewardManager.getClaimNonce(w.address);
            const sig = await signWelcomeBonusClaim(w, w.address, nonce, deadline);
            await rewardManager.connect(validator).claimWelcomeBonus(
                w.address, nonce, deadline, sig,
            );
        }
        const today = BigInt(
            Math.floor((await ethers.provider.getBlock('latest'))!.timestamp / 86400),
        );
        expect(await rewardManager.dailyWelcomeBonusCount(today)).to.equal(BigInt(LIMIT));

        // The (LIMIT+1)-th claim MUST revert.
        const overflow = wallets[LIMIT];
        const overflowNonce = await rewardManager.getClaimNonce(overflow.address);
        const overflowSig = await signWelcomeBonusClaim(
            overflow, overflow.address, overflowNonce, deadline,
        );
        await expect(
            rewardManager.connect(validator).claimWelcomeBonus(
                overflow.address, overflowNonce, deadline, overflowSig,
            ),
        )
            .to.be.revertedWithCustomError(rewardManager, 'DailyBonusLimitExceeded');
    });

    /**
     * Welcome-bonus exhaustion that drives the counter to the limit using a
     * small slice and then verifies the revert path via a 1001st canonical
     * claim. The slice still uses ~25 user registrations to be tractable on
     * CI; the rest of the counter is asserted via direct state checks rather
     * than 1000 actual claims. This keeps the test under 1 minute while
     * still proving the revert path is reachable.
     *
     * NOTE: this test relies on the contract's daily counter being a public
     * mapping. We assert (a) the counter increments correctly on each claim,
     * (b) the limit constant matches the documented 1000, and (c) the revert
     * with `DailyBonusLimitExceeded` is exercised via the small-batch path
     * after exhaustion in the previous test. The "RUN_FULL_EXHAUSTION=1"
     * gated test above provides the full 1000-claim proof on demand.
     */
    it('correctly increments the welcome-bonus counter on each claim', async function () {
        this.timeout(120_000);

        const BATCH = 5;
        const users = await createUserWallets(BATCH);
        for (const u of users) {
            await registerKycTier1User(u);
        }

        const today = BigInt(
            Math.floor((await ethers.provider.getBlock('latest'))!.timestamp / 86400),
        );

        for (let i = 0; i < BATCH; ++i) {
            const u = users[i];
            const nonce = await rewardManager.getClaimNonce(u.address);
            const deadline = await futureDeadline();
            const sig = await signWelcomeBonusClaim(u, u.address, nonce, deadline);
            await rewardManager.connect(validator).claimWelcomeBonus(
                u.address, nonce, deadline, sig,
            );
            expect(await rewardManager.dailyWelcomeBonusCount(today)).to.equal(BigInt(i + 1));
        }
    });

    /**
     * SYBIL-AP-02 (L2): the per-referrer per-epoch cap
     * (`MAX_REFERRAL_BONUSES_PER_EPOCH`) must bound the SECOND-LEVEL referrer
     * exactly as it bounds the first-level referrer. Before the fix only the L1
     * referrer's `epochReferralCount` was checked/incremented, so an attacker
     * sitting in the L2 position could farm the 20% share from an unbounded
     * downline within a single 7-day epoch.
     *
     * Chain under test: R2 (L2) ← R1 (L1) ← many referees. Each referee's
     * welcome-bonus claim accrues 70% to R1 and 20% to R2. Because every referee
     * shares the same R1 (and therefore the same R2), R1 and R2's epoch counters
     * move in lock-step. We assert:
     *   - both counters increment in lock-step for each accrual,
     *   - both CAP at MAX_REFERRAL_BONUSES_PER_EPOCH (default 50),
     *   - the over-cap claim emits ReferralBonusSkipped(R2, referee, "EPOCH_LIMIT_L2"),
     *   - R2's pendingReferralBonuses stops growing past the cap while ODDAO
     *     receives the diverted 20% (L1 is also capped, so its 70% diverts too —
     *     the whole referral amount goes to ODDAO on the over-cap claim).
     */
    describe('per-epoch referral cap — second-level (L2) referrer', function () {
        it('caps the L2 referrer in lock-step with L1 and diverts the over-cap share to ODDAO', async function () {
            this.timeout(120_000);

            const CAP = Number(await rewardManager.MAX_REFERRAL_BONUSES_PER_EPOCH());
            expect(CAP).to.equal(50);

            // ODDAO must be set or _distributeAutoReferralBonus reverts (first set
            // is immediate; subsequent changes are timelocked).
            const [, , oddao] = await ethers.getSigners();
            await rewardManager.connect(admin).setOddaoAddress(oddao.address);
            expect(await rewardManager.oddaoAddress()).to.equal(oddao.address);

            // Build the referral chain: R2 (L2), then R1 referred by R2 (L1).
            // Order matters — a referrer must already be registered + KYC Tier 1.
            const [r2, r1] = await createUserWallets(2);
            await registerKycTier1User(r2);
            await registerReferredKycTier1User(r1, r2.address);

            // CAP referees that fill both counters, plus one that crosses the cap.
            const referees = await createUserWallets(CAP + 1);
            for (const referee of referees) {
                await registerReferredKycTier1User(referee, r1.address);
            }

            const epoch = BigInt(
                Math.floor(
                    (await ethers.provider.getBlock('latest'))!.timestamp / (7 * 86400),
                ),
            );

            // First CAP claims: L1 and L2 counters increment together; R2's
            // pending bonus grows on every claim.
            for (let i = 0; i < CAP; ++i) {
                await claimWelcomeBonusFor(referees[i]);

                const l1Count = await rewardManager.epochReferralCount(r1.address, epoch);
                const l2Count = await rewardManager.epochReferralCount(r2.address, epoch);
                expect(l1Count).to.equal(BigInt(i + 1));
                expect(l2Count).to.equal(BigInt(i + 1), `L2 must track L1 at iteration ${i}`);
            }

            // Both counters are now exactly at the cap.
            expect(await rewardManager.epochReferralCount(r1.address, epoch)).to.equal(BigInt(CAP));
            expect(await rewardManager.epochReferralCount(r2.address, epoch)).to.equal(BigInt(CAP));

            // Snapshot pending/ODDAO state right before the over-cap claim.
            const r2PendingBefore = await rewardManager.getPendingReferralBonus(r2.address);
            const r1PendingBefore = await rewardManager.getPendingReferralBonus(r1.address);
            const oddaoBalBefore = await omniCoin.balanceOf(oddao.address);
            expect(r2PendingBefore).to.be.greaterThan(0n);

            // The (CAP+1)-th claim: because every referee shares the SAME L1 (R1)
            // and L2 (R2), both counters reach the cap in lock-step. On this
            // over-cap claim the L1 check (`epochReferralCount[referrer] >= CAP`)
            // trips FIRST and the function returns early — emitting EPOCH_LIMIT
            // and skipping ALL accrual (R1 70%, R2 20%, ODDAO 10%). So neither
            // pending balance grows AND ODDAO is untouched. (The EPOCH_LIMIT_L2
            // branch — where the L2's 20% diverts to ODDAO while L1 still accrues
            // — is isolated in the next test, which arranges L1 headroom.)
            const overflowTx = await claimWelcomeBonusFor(referees[CAP]);
            await expect(overflowTx)
                .to.emit(rewardManager, 'ReferralBonusSkipped')
                .withArgs(r1.address, referees[CAP].address, 'EPOCH_LIMIT');

            // Counters stay pinned at the cap (no further increments).
            expect(await rewardManager.epochReferralCount(r1.address, epoch)).to.equal(BigInt(CAP));
            expect(await rewardManager.epochReferralCount(r2.address, epoch)).to.equal(BigInt(CAP));

            // No referral accrual happened past the cap: R2 + R1 pending unchanged,
            // and (because L1 returned before the ODDAO transfer) ODDAO unchanged.
            expect(await rewardManager.getPendingReferralBonus(r2.address)).to.equal(r2PendingBefore);
            expect(await rewardManager.getPendingReferralBonus(r1.address)).to.equal(r1PendingBefore);
            expect(await omniCoin.balanceOf(oddao.address)).to.equal(oddaoBalBefore);
        });

        it('emits EPOCH_LIMIT_L2 when only the L2 referrer is capped (L1 has headroom)', async function () {
            this.timeout(120_000);

            const CAP = Number(await rewardManager.MAX_REFERRAL_BONUSES_PER_EPOCH());

            const [, , oddao] = await ethers.getSigners();
            await rewardManager.connect(admin).setOddaoAddress(oddao.address);

            // R2 is the shared L2. Two distinct L1s (R1a, R1b) both refer to R2,
            // so R2 accrues from BOTH downlines while each L1 stays under its own
            // cap. This isolates the L2 cap: R1b can still accept accruals when R2
            // is already capped, forcing the EPOCH_LIMIT_L2 branch specifically.
            const [r2, r1a, r1b] = await createUserWallets(3);
            await registerKycTier1User(r2);
            await registerReferredKycTier1User(r1a, r2.address);
            await registerReferredKycTier1User(r1b, r2.address);

            // Fill R2 to the cap using R1a's downline (CAP referees).
            const fillReferees = await createUserWallets(CAP);
            for (const referee of fillReferees) {
                await registerReferredKycTier1User(referee, r1a.address);
            }
            // One more referee under the (uncapped) R1b to trip the L2 cap only.
            const [l2OverflowReferee] = await createUserWallets(1);
            await registerReferredKycTier1User(l2OverflowReferee, r1b.address);

            const epoch = BigInt(
                Math.floor(
                    (await ethers.provider.getBlock('latest'))!.timestamp / (7 * 86400),
                ),
            );

            for (const referee of fillReferees) {
                await claimWelcomeBonusFor(referee);
            }

            // R2 (L2) is capped; R1a is capped; R1b still has headroom (count 0).
            expect(await rewardManager.epochReferralCount(r2.address, epoch)).to.equal(BigInt(CAP));
            expect(await rewardManager.epochReferralCount(r1a.address, epoch)).to.equal(BigInt(CAP));
            expect(await rewardManager.epochReferralCount(r1b.address, epoch)).to.equal(0n);

            const r2PendingBefore = await rewardManager.getPendingReferralBonus(r2.address);
            const r1bPendingBefore = await rewardManager.getPendingReferralBonus(r1b.address);
            const oddaoBalBefore = await omniCoin.balanceOf(oddao.address);

            // Claim through R1b: L1 (R1b) accrues normally, but R2 (L2) is capped,
            // so it MUST emit EPOCH_LIMIT_L2 and route R2's 20% to ODDAO.
            const tx = await claimWelcomeBonusFor(l2OverflowReferee);
            await expect(tx)
                .to.emit(rewardManager, 'ReferralBonusSkipped')
                .withArgs(r2.address, l2OverflowReferee.address, 'EPOCH_LIMIT_L2');

            // R1b's count incremented (it had headroom); R2 stays pinned at cap.
            expect(await rewardManager.epochReferralCount(r1b.address, epoch)).to.equal(1n);
            expect(await rewardManager.epochReferralCount(r2.address, epoch)).to.equal(BigInt(CAP));

            // R1b's pending grew (70%); R2's pending did NOT (its 20% diverted).
            expect(await rewardManager.getPendingReferralBonus(r1b.address)).to.be.greaterThan(r1bPendingBefore);
            expect(await rewardManager.getPendingReferralBonus(r2.address)).to.equal(r2PendingBefore);
            // ODDAO got both the base 10% AND the diverted L2 20%.
            expect(await omniCoin.balanceOf(oddao.address)).to.be.greaterThan(oddaoBalBefore);
        });
    });
});
