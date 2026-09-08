/**
 * @file OmniAgentPermissions.fuzz.test.js
 * @description PRO-tier invariant-fuzzing harness for OmniAgentPermissions
 * (red-team-fuzz hardening pass 2026-08-27). Randomized-input property tests
 * over the grant/permission lifecycle. LOCAL HARDHAT ONLY.
 */

/* eslint-disable @typescript-eslint/no-var-requires */
const { expect } = require('chai');
const { ethers } = require('hardhat');

const DAY = 24 * 60 * 60;

const SCOPE_MARKETPLACE = 0;
const SCOPE_DEX = 1;
const SCOPE_PREDICTIONS = 3;
const SCOPE_RWA = 4;

// Deterministic PRNG (mulberry32) so runs are reproducible.
function mulberry32(seed) {
    return function () {
        let t = (seed += 0x6d2b79f5);
        t = Math.imul(t ^ (t >>> 15), t | 1);
        t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
        return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
}

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

const REVOKE_TYPES = {
    RevokeGrant: [{ name: 'grantId', type: 'bytes32' }],
};

function randBytes32(rng) {
    const b = new Uint8Array(32);
    for (let i = 0; i < 32; i++) b[i] = Math.floor(rng() * 256);
    return ethers.hexlify(b);
}

function randBigInt(rng, max) {
    if (max <= 0n) return 0n;
    const bytes = new Uint8Array(32);
    for (let i = 0; i < 32; i++) bytes[i] = Math.floor(rng() * 256);
    return BigInt('0x' + Buffer.from(bytes).toString('hex')) % (max + 1n);
}

function randAddress(rng) {
    const b = new Uint8Array(20);
    for (let i = 0; i < 20; i++) b[i] = Math.floor(rng() * 256);
    return ethers.getAddress('0x' + Buffer.from(b).toString('hex'));
}

describe('OmniAgentPermissions Fuzz (pro-tier)', function () {
    this.timeout(300000);

    let permissions, token, forwarder;
    let deployer, user, seller, feeVault, stranger;
    let agent;
    let chainId;

    async function now() {
        return (await ethers.provider.getBlock('latest')).timestamp;
    }

    async function advanceTime(seconds) {
        await ethers.provider.send('evm_increaseTime', [seconds]);
        await ethers.provider.send('evm_mine', []);
    }

    function domain() {
        return {
            name: 'OmniAgentPermissions',
            version: '1',
            chainId,
            verifyingContract: permissions.target,
        };
    }

    // Build a single-token grant with random caps and 1-4 counterparties.
    async function buildGrant(rng, overrides = {}) {
        const t = await now();
        const perTx = 100n + randBigInt(rng, 10000n);
        const daily = perTx + randBigInt(rng, 10000n);
        const lifetime = daily + randBigInt(rng, 100000n);
        const nCps = 1 + Math.floor(rng() * 4);
        const cps = [seller.address];
        for (let i = 1; i < nCps; i++) cps.push(randAddress(rng));
        return {
            owner: user.address,
            agentKey: agent.address,
            featureScopeMask: 1 << SCOPE_MARKETPLACE,
            validAfter: 0,
            validUntil: t + 365 * DAY,
            salt: randBytes32(rng),
            tokenCaps: [
                {
                    token: await token.getAddress(),
                    perTxCap: perTx,
                    dailyCap: daily,
                    lifetimeCap: lifetime,
                },
            ],
            counterparties: cps,
            ...overrides,
        };
    }

    async function signGrant(params, signer = user) {
        return signer.signTypedData(domain(), GRANT_TYPES, params);
    }

    async function register(params, sig) {
        const s = sig ?? (await signGrant(params));
        const id = await permissions.hashGrant(params);
        await permissions.connect(stranger).registerGrant(params, s);
        return id;
    }

    async function buildIntent(rng, grantId, overrides = {}) {
        const t = await now();
        return {
            grantId,
            token: await token.getAddress(),
            amount: 0n,
            payTo: seller.address,
            feeAmount: 0n,
            feeRecipient: feeVault.address,
            featureCode: SCOPE_MARKETPLACE,
            nonce: randBytes32(rng),
            deadline: t + 3600,
            ...overrides,
        };
    }

    async function signIntent(intent, signer = agent) {
        return signer.signTypedData(domain(), INTENT_TYPES, intent);
    }

    before(async function () {
        [deployer, user, seller, feeVault, stranger] = await ethers.getSigners();
        agent = ethers.Wallet.createRandom().connect(ethers.provider);
        chainId = (await ethers.provider.getNetwork()).chainId;

        const F = await ethers.getContractFactory('TrustedRelayForwarder');
        forwarder = await F.deploy();
        await forwarder.waitForDeployment();

        const P = await ethers.getContractFactory('OmniAgentPermissions');
        permissions = await P.deploy(
            await forwarder.getAddress(),
            feeVault.address,
            deployer.address,
        );
        await permissions.waitForDeployment();

        const T = await ethers.getContractFactory('ERC20Mock');
        token = await T.deploy('Fuzz USD', 'FUSD');

        await token.mint(user.address, ethers.parseEther('1000000000'));
        await token
            .connect(user)
            .approve(permissions.target, ethers.MaxUint256);
    });

    // ════════════════════════════════════════════════════════════════════
    // INV-01: EIP-712 digest consistency (multi-token / multi-counterparty)
    // ════════════════════════════════════════════════════════════════════
    describe('INV-01: on-chain hashGrant == off-chain EIP-712 digest', function () {
        it('matches ethers TypedDataEncoder for 200 random multi-element grants', async function () {
            const rng = mulberry32(0xc0ffee01);
            for (let i = 0; i < 200; i++) {
                const t = await now();
                // Random multi-token (distinct addresses) + multi-counterparty.
                const nTokens = 1 + Math.floor(rng() * 4);
                const tokenCaps = [];
                for (let j = 0; j < nTokens; j++) {
                    const perTx = 1n + randBigInt(rng, 10000n);
                    const daily = perTx + randBigInt(rng, 10000n);
                    const lifetime = daily + randBigInt(rng, 100000n);
                    tokenCaps.push({
                        token: randAddress(rng),
                        perTxCap: perTx,
                        dailyCap: daily,
                        lifetimeCap: lifetime,
                    });
                }
                const nCps = 1 + Math.floor(rng() * 6);
                const cps = [];
                for (let j = 0; j < nCps; j++) cps.push(randAddress(rng));
                const params = {
                    owner: user.address,
                    agentKey: agent.address,
                    featureScopeMask: 1 << SCOPE_MARKETPLACE,
                    validAfter: 0,
                    validUntil: t + 365 * DAY,
                    salt: randBytes32(rng),
                    tokenCaps,
                    counterparties: cps,
                };
                const onChain = await permissions.hashGrant(params);
                const offChain = ethers.TypedDataEncoder.hash(
                    domain(),
                    GRANT_TYPES,
                    params,
                );
                expect(onChain).to.equal(offChain);
            }
        });
    });

    // ════════════════════════════════════════════════════════════════════
    // INV-02: Revoke digest consistency
    // ════════════════════════════════════════════════════════════════════
    describe('INV-02: revokeGrantBySig digest consistency', function () {
        it('recovers the owner for a spec-conformant signature', async function () {
            const rng = mulberry32(0xbeef02);
            const params = await buildGrant(rng);
            const id = await register(params);
            const sig = await user.signTypedData(domain(), REVOKE_TYPES, {
                grantId: id,
            });
            const recovered = ethers.verifyTypedData(
                domain(),
                REVOKE_TYPES,
                { grantId: id },
                sig,
            );
            expect(recovered).to.equal(user.address);
            await permissions.connect(stranger).revokeGrantBySig(id, sig);
            expect((await permissions.getGrant(id)).revoked).to.equal(true);
        });
    });

    // ════════════════════════════════════════════════════════════════════
    // INV-03: only the stated owner's signature can register a grant
    // ════════════════════════════════════════════════════════════════════
    describe('INV-03: registration requires the owner signature', function () {
        it('rejects 150 random forged owner signatures', async function () {
            const rng = mulberry32(0xbeef03);
            for (let i = 0; i < 150; i++) {
                const params = await buildGrant(rng);
                const wrong = ethers.Wallet.createRandom();
                const sig = await signGrant(params, wrong);
                await expect(
                    permissions.connect(stranger).registerGrant(params, sig),
                ).to.be.revertedWithCustomError(permissions, 'BadOwnerSignature');
            }
        });
    });

    // ════════════════════════════════════════════════════════════════════
    // INV-04: agent-signature authorization + cross-grant isolation
    // ════════════════════════════════════════════════════════════════════
    describe('INV-04: only the grant agent key can execute; no cross-grant spend', function () {
        it('rejects 150 random non-agent signers and cross-grant intents', async function () {
            const rng = mulberry32(0xbeef04);
            const params = await buildGrant(rng);
            const id = await register(params);
            const otherAgent = ethers.Wallet.createRandom();
            const otherParams = await buildGrant(rng, {
                agentKey: otherAgent.address,
            });
            const otherId = await register(otherParams);

            for (let i = 0; i < 150; i++) {
                const intent = await buildIntent(rng, id, {
                    amount: 1n,
                    feeAmount: 0n,
                });
                if (i % 2 === 0) {
                    const wrong = ethers.Wallet.createRandom();
                    const sig = await signIntent(intent, wrong);
                    await expect(
                        permissions.executeWithPermission(intent, sig),
                    ).to.be.revertedWithCustomError(
                        permissions,
                        'BadAgentSignature',
                    );
                } else {
                    const sig = await signIntent(intent, otherAgent);
                    await expect(
                        permissions.executeWithPermission(intent, sig),
                    ).to.be.revertedWithCustomError(
                        permissions,
                        'BadAgentSignature',
                    );
                }
            }
            const crossIntent = await buildIntent(rng, otherId, {
                amount: 1n,
                feeAmount: 0n,
            });
            const crossSig = await signIntent(crossIntent, agent);
            await expect(
                permissions.executeWithPermission(crossIntent, crossSig),
            ).to.be.revertedWithCustomError(permissions, 'BadAgentSignature');
        });
    });

    // ════════════════════════════════════════════════════════════════════
    // INV-05: cap accounting — total = amount + fee, perTx/daily/lifetime
    // ════════════════════════════════════════════════════════════════════
    describe('INV-05: caps never exceeded (perTx/daily/lifetime)', function () {
        it('600 randomized spends never violate caps and match a local model', async function () {
            const rng = mulberry32(0xcafe05);
            const PER_TX = 1000n;
            const DAILY = 3000n;
            const LIFETIME = 10000n;
            const params = await buildGrant(rng, {
                tokenCaps: [
                    {
                        token: await token.getAddress(),
                        perTxCap: PER_TX,
                        dailyCap: DAILY,
                        lifetimeCap: LIFETIME,
                    },
                ],
                counterparties: [seller.address],
            });
            const id = await register(params);

            const model = { dayStart: 0, spentToday: 0n, spentTotal: 0n };

            for (let i = 0; i < 600; i++) {
                const amount = randBigInt(rng, 1200n);
                const fee = randBigInt(rng, 200n);
                const total = amount + fee;
                const nonce = randBytes32(rng);
                const intent = await buildIntent(rng, id, {
                    amount,
                    feeAmount: fee,
                    nonce,
                });

                const ts = await now();
                const windowElapsed =
                    model.dayStart === 0 || ts - model.dayStart >= DAY;
                let expectedFail = null;
                if (total > PER_TX) expectedFail = 'PerTxCapExceeded';
                else if ((windowElapsed ? 0n : model.spentToday) + total > DAILY)
                    expectedFail = 'DailyCapExceeded';
                else if (model.spentTotal + total > LIFETIME)
                    expectedFail = 'LifetimeCapExceeded';

                if (expectedFail) {
                    await expect(
                        permissions.executeWithPermission(
                            intent,
                            await signIntent(intent),
                        ),
                    ).to.be.revertedWithCustomError(permissions, expectedFail);
                } else {
                    const sig = await signIntent(intent);
                    await permissions.executeWithPermission(intent, sig);
                    if (windowElapsed) {
                        model.dayStart = ts;
                        model.spentToday = 0n;
                    }
                    model.spentToday += total;
                    model.spentTotal += total;

                    const [, remainingToday, remainingLifetime] =
                        await permissions.remainingCaps(
                            id,
                            await token.getAddress(),
                        );
                    const expectedToday =
                        DAILY > model.spentToday ? DAILY - model.spentToday : 0n;
                    const expectedLifetime =
                        LIFETIME > model.spentTotal
                            ? LIFETIME - model.spentTotal
                            : 0n;
                    expect(remainingToday).to.equal(expectedToday);
                    expect(remainingLifetime).to.equal(expectedLifetime);
                    expect(await permissions.usedNonces(id, nonce)).to.equal(
                        true,
                    );
                }

                if (i % 37 === 0)
                    await advanceTime(1 + Math.floor(rng() * 20000));
            }
        });
    });

    // ════════════════════════════════════════════════════════════════════
    // INV-06: nonce single-use (replay rejection)
    // ════════════════════════════════════════════════════════════════════
    describe('INV-06: intent nonce is single-use', function () {
        it('rejects replay of 50 random intents', async function () {
            const rng = mulberry32(0xbeef06);
            const params = await buildGrant(rng);
            const id = await register(params);
            for (let i = 0; i < 50; i++) {
                const intent = await buildIntent(rng, id, {
                    amount: 1n,
                    feeAmount: 0n,
                });
                const sig = await signIntent(intent);
                await permissions.executeWithPermission(intent, sig);
                await expect(
                    permissions.executeWithPermission(intent, sig),
                ).to.be.revertedWithCustomError(
                    permissions,
                    'NonceAlreadyUsed',
                );
            }
        });
    });

    // ════════════════════════════════════════════════════════════════════
    // INV-07: scope / restricted-vertical / counterparty / fee-recipient
    // ════════════════════════════════════════════════════════════════════
    describe('INV-07: scope / restricted / counterparty / feeVault enforcement', function () {
        it('rejects 400 random out-of-scope payments', async function () {
            const rng = mulberry32(0xbeef07);
            const params = await buildGrant(rng);
            const id = await register(params);

            for (let i = 0; i < 400; i++) {
                const kind = i % 5;
                let intent;
                let err;
                if (kind === 0) {
                    intent = await buildIntent(rng, id, {
                        amount: 1n,
                        featureCode: SCOPE_DEX,
                    });
                    err = 'FeatureNotGranted';
                } else if (kind === 1) {
                    intent = await buildIntent(rng, id, {
                        amount: 1n,
                        featureCode: SCOPE_PREDICTIONS,
                    });
                    err = 'RestrictedScope';
                } else if (kind === 2) {
                    intent = await buildIntent(rng, id, {
                        amount: 1n,
                        featureCode: SCOPE_RWA,
                    });
                    err = 'RestrictedScope';
                } else if (kind === 3) {
                    intent = await buildIntent(rng, id, {
                        amount: 1n,
                        payTo: randAddress(rng),
                    });
                    err = 'CounterpartyNotAllowed';
                } else {
                    intent = await buildIntent(rng, id, {
                        amount: 1n,
                        feeRecipient: randAddress(rng),
                    });
                    err = 'BadFeeRecipient';
                }
                await expect(
                    permissions.executeWithPermission(
                        intent,
                        await signIntent(intent),
                    ),
                ).to.be.revertedWithCustomError(permissions, err);
            }
        });
    });

    // ════════════════════════════════════════════════════════════════════
    // INV-08: restricted verticals can never be registered
    // ════════════════════════════════════════════════════════════════════
    describe('INV-08: restricted verticals rejected at registration', function () {
        it('rejects grants carrying bits 3/4 (50 random mixes)', async function () {
            const rng = mulberry32(0xbeef08);
            for (let i = 0; i < 50; i++) {
                const bit = i % 2 === 0 ? SCOPE_PREDICTIONS : SCOPE_RWA;
                const mask = (1 << SCOPE_MARKETPLACE) | (1 << bit);
                const params = await buildGrant(rng, {
                    featureScopeMask: mask,
                });
                await expect(
                    permissions.registerGrant(params, await signGrant(params)),
                ).to.be.revertedWithCustomError(permissions, 'RestrictedScope');
            }
        });
    });

    // ════════════════════════════════════════════════════════════════════
    // INV-09: revocation — owner-only, idempotent, irreversible
    // ════════════════════════════════════════════════════════════════════
    describe('INV-09: revocation access control + irreversibility', function () {
        it('non-owner cannot revoke; owner revoke is idempotent (50 grants)', async function () {
            const rng = mulberry32(0xbeef09);
            for (let i = 0; i < 50; i++) {
                const params = await buildGrant(rng);
                const id = await register(params);

                await expect(
                    permissions.connect(stranger).revokeGrant(id),
                ).to.be.revertedWithCustomError(permissions, 'NotGrantOwner');

                await permissions.connect(user).revokeGrant(id);
                expect((await permissions.getGrant(id)).revoked).to.equal(true);

                await expect(
                    permissions.connect(user).revokeGrant(id),
                ).to.not.emit(permissions, 'GrantRevoked');

                const intent = await buildIntent(rng, id, {
                    amount: 1n,
                    feeAmount: 0n,
                });
                await expect(
                    permissions.executeWithPermission(
                        intent,
                        await signIntent(intent),
                    ),
                ).to.be.revertedWithCustomError(
                    permissions,
                    'GrantRevokedError',
                );
            }
        });
    });

    // ════════════════════════════════════════════════════════════════════
    // INV-10: non-custodial — the contract never holds a balance
    // ════════════════════════════════════════════════════════════════════
    describe('INV-10: contract balance stays zero', function () {
        it('after 100 random payments the contract holds 0 tokens', async function () {
            const rng = mulberry32(0xbeef10);
            const params = await buildGrant(rng);
            const id = await register(params);
            for (let i = 0; i < 100; i++) {
                const intent = await buildIntent(rng, id, {
                    amount: 1n + randBigInt(rng, 50n),
                    feeAmount: randBigInt(rng, 5n),
                });
                await permissions.executeWithPermission(
                    intent,
                    await signIntent(intent),
                );
                expect(await token.balanceOf(permissions.target)).to.equal(0n);
            }
        });
    });

    // ════════════════════════════════════════════════════════════════════
    // INV-11: admin setFeeVault — owner-only, zero-address guard
    // ════════════════════════════════════════════════════════════════════
    describe('INV-11: admin surface access control', function () {
        it('only deployer can set feeVault; zero address rejected', async function () {
            const rng = mulberry32(0xbeef11);
            for (let i = 0; i < 50; i++) {
                await expect(
                    permissions.connect(stranger).setFeeVault(randAddress(rng)),
                ).to.be.revertedWithCustomError(
                    permissions,
                    'OwnableUnauthorizedAccount',
                );
            }
            await expect(
                permissions.connect(deployer).setFeeVault(ethers.ZeroAddress),
            ).to.be.revertedWithCustomError(permissions, 'ZeroAddress');
        });
    });
});
