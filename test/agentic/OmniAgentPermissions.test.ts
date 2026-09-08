/**
 * @file OmniAgentPermissions.test.ts
 * @description Reference-slice test suite for the agentic delegated-spend
 * contract (ADD_AGENTIC.md §4.1). Covers grant registration (direct +
 * signature), scoped execution with per-tx/daily/lifetime caps and fee split,
 * revocation (direct, by-signature, relayed ERC-2771), expiry boundaries,
 * UTC-day cap roll, and the full adversarial matrix (every typed error), plus
 * an ERC-2771 spoof probe and a reentrancy probe via a malicious ERC-20.
 *
 * LOCAL HARDHAT ONLY — no mainnet artifacts. SECURITY REVIEW REQUIRED
 * (ADD_AGENTIC.md §7) before any mainnet use.
 */

/* eslint-disable @typescript-eslint/no-var-requires */
const { expect } = require('chai');
const { ethers } = require('hardhat');

const DAY = 24 * 60 * 60;

/** Feature scope bit indices (ADD_AGENTIC.md §2.6). */
const SCOPE_MARKETPLACE_DIGITAL = 0;
const SCOPE_DEX_SWAP = 1;
const SCOPE_PREDICTIONS = 3;

describe('OmniAgentPermissions', function () {
    let permissions: any;
    let token: any;
    let otherToken: any;
    let forwarder: any;

    let deployer: any; // contract admin (Pioneer deployer-direct)
    let user: any; // grant owner (funds source)
    let seller: any; // payTo counterparty
    let feeVault: any; // fee recipient
    let stranger: any; // unauthorized EOA
    let agent: any; // dedicated agent key (ethers.Wallet)

    let chainId: bigint;

    const GRANT_TYPES = {
        Grant: [
            { name: 'owner', type: 'address' },
            { name: 'agentKey', type: 'address' },
            { name: 'featureScopeMask', type: 'uint32' },
            { name: 'validAfter', type: 'uint48' },
            { name: 'validUntil', type: 'uint48' },
            { name: 'salt', type: 'bytes32' },
            { name: 'tokenCaps', type: 'TokenCapInput[]' },
            { name: 'counterparties', type: 'address[]' },
        ],
        TokenCapInput: [
            { name: 'token', type: 'address' },
            { name: 'perTxCap', type: 'uint256' },
            { name: 'dailyCap', type: 'uint256' },
            { name: 'lifetimeCap', type: 'uint256' },
        ],
    };

    const INTENT_TYPES = {
        PaymentIntent: [
            { name: 'grantId', type: 'bytes32' },
            { name: 'token', type: 'address' },
            { name: 'amount', type: 'uint256' },
            { name: 'payTo', type: 'address' },
            { name: 'feeAmount', type: 'uint256' },
            { name: 'feeRecipient', type: 'address' },
            { name: 'featureCode', type: 'uint8' },
            { name: 'nonce', type: 'bytes32' },
            { name: 'deadline', type: 'uint256' },
        ],
    };

    /**
     * EIP-712 domain for the deployed permissions contract.
     *
     * @returns Domain object for signTypedData.
     */
    async function domain(): Promise<Record<string, unknown>> {
        return {
            name: 'OmniAgentPermissions',
            version: '1',
            chainId,
            verifyingContract: await permissions.getAddress(),
        };
    }

    /**
     * Latest block timestamp.
     *
     * @returns Current chain time in seconds.
     */
    async function now(): Promise<number> {
        const block = await ethers.provider.getBlock('latest');
        return block.timestamp;
    }

    /**
     * Advance chain time and mine a block.
     *
     * @param seconds Seconds to advance.
     */
    async function advanceTime(seconds: number): Promise<void> {
        await ethers.provider.send('evm_increaseTime', [seconds]);
        await ethers.provider.send('evm_mine', []);
    }

    /**
     * Build default grant params (marketplace scope, single token, seller
     * counterparty, 30-day validity) with optional overrides.
     *
     * @param overrides Partial param overrides.
     * @returns GrantParams struct object.
     */
    async function buildGrant(
        overrides: Record<string, unknown> = {},
    ): Promise<Record<string, unknown>> {
        const t = await now();
        return {
            owner: user.address,
            agentKey: agent.address,
            featureScopeMask: 1 << SCOPE_MARKETPLACE_DIGITAL,
            validAfter: 0,
            validUntil: t + 30 * DAY,
            salt: ethers.hexlify(ethers.randomBytes(32)),
            tokenCaps: [
                {
                    token: await token.getAddress(),
                    perTxCap: ethers.parseEther('100'),
                    dailyCap: ethers.parseEther('250'),
                    lifetimeCap: ethers.parseEther('1000'),
                },
            ],
            counterparties: [seller.address],
            ...overrides,
        };
    }

    /**
     * Owner-sign a grant struct (EIP-712).
     *
     * @param params GrantParams object.
     * @param signer Owner signer (defaults to user).
     * @returns Signature hex string.
     */
    async function signGrant(
        params: Record<string, unknown>,
        signer: any = user,
    ): Promise<string> {
        return signer.signTypedData(await domain(), GRANT_TYPES, params);
    }

    /**
     * Register a grant on-chain and return its id.
     *
     * @param params GrantParams object.
     * @param sig Owner signature (defaults to user-signed).
     * @returns The grantId.
     */
    async function register(
        params: Record<string, unknown>,
        sig?: string,
    ): Promise<string> {
        const signature = sig ?? (await signGrant(params));
        const grantId = await permissions.hashGrant(params);
        await permissions.connect(stranger).registerGrant(params, signature);
        return grantId;
    }

    /**
     * Build a default payment intent against a grant with optional overrides.
     *
     * @param grantId Target grant id.
     * @param overrides Partial intent overrides.
     * @returns PaymentIntent struct object.
     */
    async function buildIntent(
        grantId: string,
        overrides: Record<string, unknown> = {},
    ): Promise<Record<string, unknown>> {
        const t = await now();
        return {
            grantId,
            token: await token.getAddress(),
            amount: ethers.parseEther('10'),
            payTo: seller.address,
            feeAmount: ethers.parseEther('0.1'),
            feeRecipient: feeVault.address,
            featureCode: SCOPE_MARKETPLACE_DIGITAL,
            nonce: ethers.hexlify(ethers.randomBytes(32)),
            deadline: t + 3600,
            ...overrides,
        };
    }

    /**
     * Agent-sign a payment intent (EIP-712).
     *
     * @param intent PaymentIntent object.
     * @param signer Agent signer (defaults to the grant agent wallet).
     * @returns Signature hex string.
     */
    async function signIntent(
        intent: Record<string, unknown>,
        signer: any = agent,
    ): Promise<string> {
        return signer.signTypedData(await domain(), INTENT_TYPES, intent);
    }

    beforeEach(async function () {
        [deployer, user, seller, feeVault, stranger] = await ethers.getSigners();
        agent = ethers.Wallet.createRandom().connect(ethers.provider);
        chainId = (await ethers.provider.getNetwork()).chainId;

        const Forwarder = await ethers.getContractFactory('TrustedRelayForwarder');
        forwarder = await Forwarder.deploy();
        await forwarder.waitForDeployment();

        const Permissions = await ethers.getContractFactory('OmniAgentPermissions');
        permissions = await Permissions.deploy(
            await forwarder.getAddress(),
            feeVault.address,
            deployer.address,
        );
        await permissions.waitForDeployment();

        const Token = await ethers.getContractFactory('ERC20Mock');
        token = await Token.deploy('Test USD', 'TUSD');
        otherToken = await Token.deploy('Other', 'OTH');

        await token.mint(user.address, ethers.parseEther('10000'));
        await token
            .connect(user)
            .approve(await permissions.getAddress(), ethers.parseEther('1000'));
    });

    // -----------------------------------------------------------------
    // Registration
    // -----------------------------------------------------------------

    describe('registerGrant', function () {
        it('registers a grant with owner signature and exposes state', async function () {
            const params = await buildGrant();
            const grantId = await register(params);

            const g = await permissions.getGrant(grantId);
            expect(g.owner).to.equal(user.address);
            expect(g.agentKey).to.equal(agent.address);
            expect(g.revoked).to.equal(false);
            expect(g.featureScopeMask).to.equal(1 << SCOPE_MARKETPLACE_DIGITAL);

            const [tokens, counterparties] = await permissions.getGrantLists(grantId);
            expect(tokens).to.deep.equal([await token.getAddress()]);
            expect(counterparties).to.deep.equal([seller.address]);

            const [perTx, remainingToday, remainingLifetime] =
                await permissions.remainingCaps(grantId, await token.getAddress());
            expect(perTx).to.equal(ethers.parseEther('100'));
            expect(remainingToday).to.equal(ethers.parseEther('250'));
            expect(remainingLifetime).to.equal(ethers.parseEther('1000'));
        });

        it('emits GrantRegistered', async function () {
            const params = await buildGrant();
            const sig = await signGrant(params);
            const grantId = await permissions.hashGrant(params);
            await expect(permissions.registerGrant(params, sig))
                .to.emit(permissions, 'GrantRegistered')
                .withArgs(
                    grantId,
                    user.address,
                    agent.address,
                    1 << SCOPE_MARKETPLACE_DIGITAL,
                    0,
                    params.validUntil,
                );
        });

        it('rejects a signature from anyone but the stated owner', async function () {
            const params = await buildGrant();
            const badSig = await signGrant(params, stranger);
            await expect(
                permissions.registerGrant(params, badSig),
            ).to.be.revertedWithCustomError(permissions, 'BadOwnerSignature');
        });

        it('rejects double registration of the same grant', async function () {
            const params = await buildGrant();
            const sig = await signGrant(params);
            await permissions.registerGrant(params, sig);
            await expect(
                permissions.registerGrant(params, sig),
            ).to.be.revertedWithCustomError(permissions, 'GrantAlreadyRegistered');
        });

        it('rejects expired validity, empty scopes lists, and malformed caps', async function () {
            const t = await now();
            const expired = await buildGrant({ validUntil: t - 1 });
            await expect(
                permissions.registerGrant(expired, await signGrant(expired)),
            ).to.be.revertedWithCustomError(permissions, 'InvalidGrantParams');

            const noTokens = await buildGrant({ tokenCaps: [] });
            await expect(
                permissions.registerGrant(noTokens, await signGrant(noTokens)),
            ).to.be.revertedWithCustomError(permissions, 'InvalidGrantParams');

            const noCounterparties = await buildGrant({ counterparties: [] });
            await expect(
                permissions.registerGrant(
                    noCounterparties,
                    await signGrant(noCounterparties),
                ),
            ).to.be.revertedWithCustomError(permissions, 'InvalidGrantParams');

            const badCaps = await buildGrant({
                tokenCaps: [
                    {
                        token: await token.getAddress(),
                        perTxCap: ethers.parseEther('100'),
                        dailyCap: ethers.parseEther('50'), // perTx > daily
                        lifetimeCap: ethers.parseEther('1000'),
                    },
                ],
            });
            await expect(
                permissions.registerGrant(badCaps, await signGrant(badCaps)),
            ).to.be.revertedWithCustomError(permissions, 'InvalidGrantParams');
        });

        it('rejects a grant carrying a restricted vertical bit (predictions/RWA)', async function () {
            const SCOPE_RWA = 4;
            for (const bit of [SCOPE_PREDICTIONS, SCOPE_RWA]) {
                const restricted = await buildGrant({ featureScopeMask: 1 << bit });
                await expect(
                    permissions.registerGrant(restricted, await signGrant(restricted)),
                ).to.be.revertedWithCustomError(permissions, 'RestrictedScope');
            }
            // A grant mixing an allowed bit with a restricted bit is still refused.
            const mixed = await buildGrant({
                featureScopeMask: (1 << SCOPE_MARKETPLACE_DIGITAL) | (1 << SCOPE_PREDICTIONS),
            });
            await expect(
                permissions.registerGrant(mixed, await signGrant(mixed)),
            ).to.be.revertedWithCustomError(permissions, 'RestrictedScope');
        });
    });

    // -----------------------------------------------------------------
    // Execution — happy paths
    // -----------------------------------------------------------------

    describe('executeWithPermission', function () {
        let grantId: string;

        beforeEach(async function () {
            grantId = await register(await buildGrant());
        });

        it('pays the counterparty and routes the fee to the vault', async function () {
            const intent = await buildIntent(grantId);
            const sig = await signIntent(intent);

            const sellerBefore = await token.balanceOf(seller.address);
            const vaultBefore = await token.balanceOf(feeVault.address);
            const userBefore = await token.balanceOf(user.address);

            await expect(permissions.connect(stranger).executeWithPermission(intent, sig))
                .to.emit(permissions, 'PaymentExecuted')
                .withArgs(
                    grantId,
                    await token.getAddress(),
                    seller.address,
                    intent.amount,
                    intent.feeAmount,
                    SCOPE_MARKETPLACE_DIGITAL,
                    intent.nonce,
                );

            expect(await token.balanceOf(seller.address)).to.equal(
                sellerBefore + (intent.amount as bigint),
            );
            expect(await token.balanceOf(feeVault.address)).to.equal(
                vaultBefore + (intent.feeAmount as bigint),
            );
            expect(await token.balanceOf(user.address)).to.equal(
                userBefore - (intent.amount as bigint) - (intent.feeAmount as bigint),
            );
            expect(
                await token.balanceOf(await permissions.getAddress()),
            ).to.equal(0n); // never custodial
        });

        it('decrements remaining caps and marks the nonce used', async function () {
            const intent = await buildIntent(grantId);
            await permissions.executeWithPermission(intent, await signIntent(intent));

            const total = (intent.amount as bigint) + (intent.feeAmount as bigint);
            const [, remainingToday, remainingLifetime] =
                await permissions.remainingCaps(grantId, await token.getAddress());
            expect(remainingToday).to.equal(ethers.parseEther('250') - total);
            expect(remainingLifetime).to.equal(ethers.parseEther('1000') - total);
            expect(await permissions.usedNonces(grantId, intent.nonce)).to.equal(true);
        });

        it('tracks caps independently per token', async function () {
            const params = await buildGrant({
                tokenCaps: [
                    {
                        token: await token.getAddress(),
                        perTxCap: ethers.parseEther('100'),
                        dailyCap: ethers.parseEther('250'),
                        lifetimeCap: ethers.parseEther('1000'),
                    },
                    {
                        token: await otherToken.getAddress(),
                        perTxCap: ethers.parseEther('5'),
                        dailyCap: ethers.parseEther('5'),
                        lifetimeCap: ethers.parseEther('5'),
                    },
                ],
            });
            const id = await register(params);
            await otherToken.mint(user.address, ethers.parseEther('10'));
            await otherToken
                .connect(user)
                .approve(await permissions.getAddress(), ethers.parseEther('10'));

            const intentA = await buildIntent(id);
            await permissions.executeWithPermission(intentA, await signIntent(intentA));

            const intentB = await buildIntent(id, {
                token: await otherToken.getAddress(),
                amount: ethers.parseEther('4'),
                feeAmount: ethers.parseEther('0.5'),
            });
            await permissions.executeWithPermission(intentB, await signIntent(intentB));

            const [, remainingB] = await permissions.remainingCaps(
                id,
                await otherToken.getAddress(),
            );
            expect(remainingB).to.equal(ethers.parseEther('0.5'));
        });

        it('rolls the daily window at the UTC day boundary', async function () {
            // Exhaust the daily cap (250) with two 100+0 and one 50+0 payments.
            for (const amount of ['100', '100', '50']) {
                const intent = await buildIntent(grantId, {
                    amount: ethers.parseEther(amount),
                    feeAmount: 0n,
                });
                await permissions.executeWithPermission(
                    intent,
                    await signIntent(intent),
                );
            }
            const over = await buildIntent(grantId, {
                amount: ethers.parseEther('1'),
                feeAmount: 0n,
            });
            await expect(
                permissions.executeWithPermission(over, await signIntent(over)),
            ).to.be.revertedWithCustomError(permissions, 'DailyCapExceeded');

            await advanceTime(DAY + 1);

            const fresh = await buildIntent(grantId, {
                amount: ethers.parseEther('1'),
                feeAmount: 0n,
            });
            await permissions.executeWithPermission(fresh, await signIntent(fresh));
            const [, remainingToday] = await permissions.remainingCaps(
                grantId,
                await token.getAddress(),
            );
            expect(remainingToday).to.equal(ethers.parseEther('249'));
        });

        it('does NOT allow 2× dailyCap across a short window (rolling, not calendar — M1)', async function () {
            // Exhaust the daily cap (250).
            for (const amount of ['100', '100', '50']) {
                const intent = await buildIntent(grantId, {
                    amount: ethers.parseEther(amount),
                    feeAmount: 0n,
                });
                await permissions.executeWithPermission(
                    intent,
                    await signIntent(intent),
                );
            }
            // 12 hours later — well inside the 24h rolling window — a further
            // spend must still be refused (a fixed UTC-midnight window would
            // have reset and allowed a second full dailyCap).
            await advanceTime(12 * 60 * 60);
            const stillOver = await buildIntent(grantId, {
                amount: ethers.parseEther('1'),
                feeAmount: 0n,
            });
            await expect(
                permissions.executeWithPermission(stillOver, await signIntent(stillOver)),
            ).to.be.revertedWithCustomError(permissions, 'DailyCapExceeded');

            // Past the full 24h from the first spend, the window resets.
            await advanceTime(13 * 60 * 60);
            const afterReset = await buildIntent(grantId, {
                amount: ethers.parseEther('1'),
                feeAmount: 0n,
            });
            await permissions.executeWithPermission(
                afterReset,
                await signIntent(afterReset),
            );
        });

        it('exhausts the lifetime cap terminally across days', async function () {
            // lifetime 1000, daily 250 → 4 days of 250, then nothing.
            for (let day = 0; day < 4; day++) {
                for (const amount of ['100', '100', '50']) {
                    const intent = await buildIntent(grantId, {
                        amount: ethers.parseEther(amount),
                        feeAmount: 0n,
                    });
                    await permissions.executeWithPermission(
                        intent,
                        await signIntent(intent),
                    );
                }
                await advanceTime(DAY + 1);
            }
            const over = await buildIntent(grantId, {
                amount: ethers.parseEther('1'),
                feeAmount: 0n,
            });
            await expect(
                permissions.executeWithPermission(over, await signIntent(over)),
            ).to.be.revertedWithCustomError(permissions, 'LifetimeCapExceeded');
        });
    });

    // -----------------------------------------------------------------
    // Execution — adversarial matrix
    // -----------------------------------------------------------------

    describe('executeWithPermission — adversarial', function () {
        let grantId: string;

        beforeEach(async function () {
            grantId = await register(await buildGrant());
        });

        it('GrantNotFound for an unregistered grant id', async function () {
            const bogus = ethers.hexlify(ethers.randomBytes(32));
            const intent = await buildIntent(bogus);
            await expect(
                permissions.executeWithPermission(intent, await signIntent(intent)),
            ).to.be.revertedWithCustomError(permissions, 'GrantNotFound');
        });

        it('BadAgentSignature for a non-agent signer', async function () {
            const intent = await buildIntent(grantId);
            const sig = await signIntent(intent, stranger);
            await expect(
                permissions.executeWithPermission(intent, sig),
            ).to.be.revertedWithCustomError(permissions, 'BadAgentSignature');
        });

        it("BadAgentSignature when another grant's agent signs (cross-grant isolation)", async function () {
            const otherAgent = ethers.Wallet.createRandom();
            const otherParams = await buildGrant({ agentKey: otherAgent.address });
            await register(otherParams);

            const intent = await buildIntent(grantId);
            const sig = await signIntent(intent, otherAgent);
            await expect(
                permissions.executeWithPermission(intent, sig),
            ).to.be.revertedWithCustomError(permissions, 'BadAgentSignature');
        });

        it('GrantRevokedError after revocation', async function () {
            await permissions.connect(user).revokeGrant(grantId);
            const intent = await buildIntent(grantId);
            await expect(
                permissions.executeWithPermission(intent, await signIntent(intent)),
            ).to.be.revertedWithCustomError(permissions, 'GrantRevokedError');
        });

        it('GrantNotYetValid before validAfter', async function () {
            const t = await now();
            const params = await buildGrant({
                validAfter: t + DAY,
                validUntil: t + 30 * DAY,
            });
            const id = await register(params);
            const intent = await buildIntent(id);
            await expect(
                permissions.executeWithPermission(intent, await signIntent(intent)),
            ).to.be.revertedWithCustomError(permissions, 'GrantNotYetValid');
        });

        it('GrantExpired after validUntil', async function () {
            await advanceTime(31 * DAY);
            const intent = await buildIntent(grantId);
            await expect(
                permissions.executeWithPermission(intent, await signIntent(intent)),
            ).to.be.revertedWithCustomError(permissions, 'GrantExpired');
        });

        it('FeatureNotGranted for an out-of-scope feature code', async function () {
            const intent = await buildIntent(grantId, {
                featureCode: SCOPE_DEX_SWAP,
            });
            await expect(
                permissions.executeWithPermission(intent, await signIntent(intent)),
            ).to.be.revertedWithCustomError(permissions, 'FeatureNotGranted');
        });

        it('RestrictedScope for restricted verticals (predictions/RWA), even at settle', async function () {
            // The contract refuses these codes before the mask check — the
            // on-chain regulatory backstop (§2.6 layer 3).
            for (const bit of [SCOPE_PREDICTIONS, 4]) {
                const intent = await buildIntent(grantId, { featureCode: bit });
                await expect(
                    permissions.executeWithPermission(intent, await signIntent(intent)),
                ).to.be.revertedWithCustomError(permissions, 'RestrictedScope');
            }
        });

        it('TokenNotAllowed for an unlisted token', async function () {
            const intent = await buildIntent(grantId, {
                token: await otherToken.getAddress(),
            });
            await expect(
                permissions.executeWithPermission(intent, await signIntent(intent)),
            ).to.be.revertedWithCustomError(permissions, 'TokenNotAllowed');
        });

        it('PerTxCapExceeded above the per-transaction cap', async function () {
            const intent = await buildIntent(grantId, {
                amount: ethers.parseEther('100'),
                feeAmount: ethers.parseEther('1'), // 101 > 100
            });
            await expect(
                permissions.executeWithPermission(intent, await signIntent(intent)),
            ).to.be.revertedWithCustomError(permissions, 'PerTxCapExceeded');
        });

        it('CounterpartyNotAllowed for an unlisted payTo', async function () {
            const intent = await buildIntent(grantId, { payTo: stranger.address });
            await expect(
                permissions.executeWithPermission(intent, await signIntent(intent)),
            ).to.be.revertedWithCustomError(permissions, 'CounterpartyNotAllowed');
        });

        it('BadFeeRecipient when the fee leg points anywhere but the vault', async function () {
            const intent = await buildIntent(grantId, {
                feeRecipient: stranger.address,
            });
            await expect(
                permissions.executeWithPermission(intent, await signIntent(intent)),
            ).to.be.revertedWithCustomError(permissions, 'BadFeeRecipient');
        });

        it('NonceAlreadyUsed on intent replay', async function () {
            const intent = await buildIntent(grantId);
            const sig = await signIntent(intent);
            await permissions.executeWithPermission(intent, sig);
            await expect(
                permissions.executeWithPermission(intent, sig),
            ).to.be.revertedWithCustomError(permissions, 'NonceAlreadyUsed');
        });

        it('IntentExpired past the deadline', async function () {
            const t = await now();
            const intent = await buildIntent(grantId, { deadline: t - 1 });
            await expect(
                permissions.executeWithPermission(intent, await signIntent(intent)),
            ).to.be.revertedWithCustomError(permissions, 'IntentExpired');
        });

        it('reverts on insufficient allowance (funds stay owner-custodied)', async function () {
            await token.connect(user).approve(await permissions.getAddress(), 0);
            const intent = await buildIntent(grantId);
            await expect(
                permissions.executeWithPermission(intent, await signIntent(intent)),
            ).to.be.reverted;
        });

        it('blocks reentrancy from a malicious token', async function () {
            const Evil = await ethers.getContractFactory('ReentrantAgentPaymentToken');
            const evil = await Evil.deploy();
            await evil.mint(user.address, ethers.parseEther('100'));

            const params = await buildGrant({
                tokenCaps: [
                    {
                        token: await evil.getAddress(),
                        perTxCap: ethers.parseEther('100'),
                        dailyCap: ethers.parseEther('100'),
                        lifetimeCap: ethers.parseEther('100'),
                    },
                ],
            });
            const id = await register(params);
            await evil
                .connect(user)
                .approve(await permissions.getAddress(), ethers.parseEther('100'));

            const intent = await buildIntent(id, {
                token: await evil.getAddress(),
                amount: ethers.parseEther('1'),
                feeAmount: 0n,
            });
            const sig = await signIntent(intent);
            // Re-enter with a DIFFERENT (fresh-nonce) intent so the probe hits
            // the ReentrancyGuard itself rather than the nonce check.
            const reentrant = await buildIntent(id, {
                token: await evil.getAddress(),
                amount: ethers.parseEther('1'),
                feeAmount: 0n,
            });
            const reentrantSig = await signIntent(reentrant);
            await evil.arm(await permissions.getAddress(), reentrant, reentrantSig);

            await expect(
                permissions.executeWithPermission(intent, sig),
            ).to.be.revertedWithCustomError(
                permissions,
                'ReentrancyGuardReentrantCall',
            );
        });
    });

    // -----------------------------------------------------------------
    // Revocation
    // -----------------------------------------------------------------

    describe('revocation', function () {
        let grantId: string;

        beforeEach(async function () {
            grantId = await register(await buildGrant());
        });

        it('owner revokes directly and revocation is idempotent', async function () {
            await expect(permissions.connect(user).revokeGrant(grantId))
                .to.emit(permissions, 'GrantRevoked')
                .withArgs(grantId, user.address);
            // Second revoke: no revert, no second event.
            await expect(
                permissions.connect(user).revokeGrant(grantId),
            ).to.not.emit(permissions, 'GrantRevoked');
            expect((await permissions.getGrant(grantId)).revoked).to.equal(true);
        });

        it('NotGrantOwner for anyone else', async function () {
            await expect(
                permissions.connect(stranger).revokeGrant(grantId),
            ).to.be.revertedWithCustomError(permissions, 'NotGrantOwner');
        });

        it('owner revokes by signature via any submitter', async function () {
            const sig = await user.signTypedData(
                await domain(),
                { RevokeGrant: [{ name: 'grantId', type: 'bytes32' }] },
                { grantId },
            );
            await permissions.connect(stranger).revokeGrantBySig(grantId, sig);
            expect((await permissions.getGrant(grantId)).revoked).to.equal(true);
        });

        it('rejects revokeGrantBySig with a non-owner signature', async function () {
            const sig = await stranger.signTypedData(
                await domain(),
                { RevokeGrant: [{ name: 'grantId', type: 'bytes32' }] },
                { grantId },
            );
            await expect(
                permissions.revokeGrantBySig(grantId, sig),
            ).to.be.revertedWithCustomError(permissions, 'BadOwnerSignature');
        });

        it('owner revokes gaslessly through the trusted forwarder (ERC-2771)', async function () {
            const data = permissions.interface.encodeFunctionData('revokeGrant', [
                grantId,
            ]);
            const suffixed = ethers.concat([data, user.address]);
            await forwarder
                .connect(stranger)
                .relay(await permissions.getAddress(), suffixed);
            expect((await permissions.getGrant(grantId)).revoked).to.equal(true);
        });

        it('ignores a forged ERC-2771 suffix from a non-forwarder caller', async function () {
            const data = permissions.interface.encodeFunctionData('revokeGrant', [
                grantId,
            ]);
            const suffixed = ethers.concat([data, user.address]);
            // Direct call (not via trusted forwarder): suffix must be ignored,
            // _msgSender() = stranger → NotGrantOwner.
            await expect(
                stranger.sendTransaction({
                    to: await permissions.getAddress(),
                    data: suffixed,
                }),
            ).to.be.revertedWithCustomError(permissions, 'NotGrantOwner');
        });
    });

    // -----------------------------------------------------------------
    // Admin
    // -----------------------------------------------------------------

    describe('admin', function () {
        it('deployer swaps the fee vault; others cannot', async function () {
            await expect(permissions.connect(deployer).setFeeVault(stranger.address))
                .to.emit(permissions, 'FeeVaultChanged')
                .withArgs(feeVault.address, stranger.address);
            expect(await permissions.feeVault()).to.equal(stranger.address);

            await expect(
                permissions.connect(user).setFeeVault(user.address),
            ).to.be.revertedWithCustomError(
                permissions,
                'OwnableUnauthorizedAccount',
            );
        });
    });
});
