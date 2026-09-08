/**
 * @file RandomCommitteeVerifierV2GatewaySwap.test.ts
 * @description LOCAL mechanics proof of the exact contract-call sequence
 * `scripts/deploy-swap-random-committee-verifier-v2.ts` performs against
 * `OmniAttestationGateway` on real mainnet: deploy `RandomCommitteeVerifierV2`,
 * refresh its eligible-validator snapshot, whitelist its version string
 * (M-1), and swap it in via `setCommitteeVerifier` (subject to the H-4
 * pool-size brick-prevention gate).
 *
 * `Coin/soak/` (the project's mainnet-fork harness for chain 88008) turns
 * out to be unable to execute ANY call against a forked OmniCoin L1 in this
 * environment — confirmed empirically 2026-08-02: both the NEW
 * `hardhat.config.js` `chains: { 88008: {...} }` entry added for this task
 * AND the pre-existing `chains: { 137: {...} }` entry (supposedly already
 * fixing this for the unrelated Polygon fork suite,
 * `test/RouterAdapters.fork.test.js`) fail identically —
 * `ProviderError: No known hardfork for execution on historical block N ...
 * The node was not configured with a hardfork activation history.` This is
 * a genuine pre-existing Hardhat/EDR limitation in this dependency version
 * for "unusual" (non-built-in) forked chains, not something introduced by
 * this change — see the file's own follow-up notes for the exact repro.
 *
 * So — following the SAME "local mechanics dry-run" convention this project
 * already uses for the COTI-side privacy contracts (which can't be forked
 * at all, for an unrelated reason: COTI's public RPC doesn't support
 * hardhat's fork chainId handshake) — this reproduces the live interaction
 * SHAPE locally instead: the real `OmniAttestationGateway.sol` +
 * `RandomCommitteeVerifierV2.sol` contracts, deployed fresh, driven through
 * the identical sequence the real script runs, using the same
 * `MockBootstrapForAttestation` / `MockOmniCoreForAttestation` /
 * `MockOmniRegistrationForAttestation` fixtures
 * `test/attestation/RandomCommitteeVerifierV2.test.ts` already established
 * for V2's own dependency reads.
 *
 * This does NOT re-prove V2's committee-selection / pinning logic itself —
 * that's `test/attestation/RandomCommitteeVerifierV2.test.ts` (incl. the
 * adversarial grinding proof). This proves the GATEWAY WIRING: that the
 * swap script's calls succeed in the right order, that the M-1 whitelist
 * and H-4 pool gates behave as the script's pre-flight checks assume, and
 * that `gateway.committeeVerifier()` ends up pointing at V2 with the
 * expected version string.
 */

/* eslint-disable @typescript-eslint/no-var-requires */
const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("RandomCommitteeVerifierV2 <-> OmniAttestationGateway swap mechanics", function () {
    const N = 5;
    const M = 4;
    const MIN_TIER = 3;
    const MIN_STAKE = ethers.parseEther("1000000");
    const V2_VERSION = "random-committee-ecdsa-v3-pinned";

    async function setEligible(mocks: any, validator: any): Promise<void> {
        await mocks.bootstrap.setNodeActive(validator.address, true, 0);
        await mocks.registration.setKycTier(validator.address, MIN_TIER);
        await mocks.omniCore.setStake(validator.address, MIN_STAKE, true);
    }

    async function deployFixture() {
        const [deployer, guardian, trustedKeyStandIn] = await ethers.getSigners();

        const MockBootstrap = await ethers.getContractFactory("MockBootstrapForAttestation");
        const bootstrap = await MockBootstrap.deploy();
        await bootstrap.waitForDeployment();

        const MockOmniCore = await ethers.getContractFactory("MockOmniCoreForAttestation");
        const omniCore = await MockOmniCore.deploy();
        await omniCore.waitForDeployment();

        const MockOmniRegistration = await ethers.getContractFactory(
            "MockOmniRegistrationForAttestation",
        );
        const registration = await MockOmniRegistration.deploy();
        await registration.waitForDeployment();

        const Gateway = await ethers.getContractFactory("OmniAttestationGateway");
        const gateway = await Gateway.deploy(
            deployer.address,
            guardian.address,
            trustedKeyStandIn.address,
        );
        await gateway.waitForDeployment();

        const VerifierV2 = await ethers.getContractFactory("RandomCommitteeVerifierV2");
        const verifierV2 = await VerifierV2.deploy(
            deployer.address,
            await bootstrap.getAddress(),
            await omniCore.getAddress(),
            await registration.getAddress(),
            N,
            M,
            MIN_TIER,
            MIN_STAKE,
        );
        await verifierV2.waitForDeployment();

        const mocks = { bootstrap, omniCore, registration };
        const validators = Array.from({ length: N }, () =>
            ethers.Wallet.createRandom().connect(ethers.provider),
        );
        for (const v of validators) await setEligible(mocks, v);

        return { deployer, gateway, verifierV2, mocks, validators };
    }

    it("mirrors the swap script's pre-flight owner check: gateway.owner() is the deployer", async function () {
        const { deployer, gateway } = await deployFixture();
        expect(await gateway.owner()).to.equal(deployer.address);
    });

    it("refreshEligibleSet + setApprovedVerifierVersion + setCommitteeVerifier — the swap script's exact sequence — lands V2 as the active verifier", async function () {
        const { gateway, verifierV2 } = await deployFixture();

        // Starts unset (legacy-only path).
        expect(await gateway.committeeVerifier()).to.equal(ethers.ZeroAddress);

        // Step 1: refresh the eligible-validator snapshot (starts empty).
        await (await verifierV2.refreshEligibleSet()).wait();
        expect(await verifierV2.eligibleSnapshotLength()).to.equal(BigInt(N));

        // Step 2: whitelist the version string (M-1 gate).
        await (await gateway.setApprovedVerifierVersion(V2_VERSION, true)).wait();

        // Step 3: swap.
        const verifierV2Addr = await verifierV2.getAddress();
        await expect(gateway.setCommitteeVerifier(verifierV2Addr))
            .to.emit(gateway, "CommitteeVerifierSet");

        expect(await gateway.committeeVerifier()).to.equal(verifierV2Addr);
        expect(await verifierV2.verifierVersion()).to.equal(V2_VERSION);
    });

    it("M-1: setCommitteeVerifier reverts if the version was never whitelisted", async function () {
        const { gateway, verifierV2 } = await deployFixture();
        await (await verifierV2.refreshEligibleSet()).wait();

        // Deliberately skip setApprovedVerifierVersion.
        await expect(gateway.setCommitteeVerifier(await verifierV2.getAddress())).to.be.reverted;
        expect(await gateway.committeeVerifier()).to.equal(ethers.ZeroAddress);
    });

    it("H-4: setCommitteeVerifier reverts if the eligible pool is smaller than the verifier's committeeSize (brick-prevention)", async function () {
        const { gateway, verifierV2 } = await deployFixture();
        // Deliberately skip refreshEligibleSet — pool stays 0 < N.
        await (await gateway.setApprovedVerifierVersion(V2_VERSION, true)).wait();

        await expect(gateway.setCommitteeVerifier(await verifierV2.getAddress())).to.be.reverted;
        expect(await gateway.committeeVerifier()).to.equal(ethers.ZeroAddress);
    });

    it("idempotency check: verifierVersion() readable post-swap matches what the script probes to skip a re-run", async function () {
        const { gateway, verifierV2 } = await deployFixture();
        await (await verifierV2.refreshEligibleSet()).wait();
        await (await gateway.setApprovedVerifierVersion(V2_VERSION, true)).wait();
        await (await gateway.setCommitteeVerifier(await verifierV2.getAddress())).wait();

        const activeVerifierAddr: string = await gateway.committeeVerifier();
        const active = await ethers.getContractAt(
            "contracts/bridge/IBridgeVerifier.sol:IBridgeVerifier",
            activeVerifierAddr,
        );
        expect(await active.verifierVersion()).to.equal(V2_VERSION);
    });
});
