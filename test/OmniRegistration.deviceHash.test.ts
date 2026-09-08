/**
 * @file OmniRegistration.deviceHash.test.ts
 * @description SYBIL-Q-10 — same-device referral block.
 *
 * Coverage:
 *   • registerUser records `userDeviceHash` only for non-zero hashes
 *   • emits `DeviceHashRecorded` when a non-zero hash lands
 *   • registerUser reverts `SameDeviceReferral` when the referrer
 *     already carries the same non-zero device hash
 *   • permitted when the referrer has a DIFFERENT recorded hash
 *   • permitted when the referrer has NO recorded hash (back-compat
 *     with pre-upgrade registrations)
 *
 * Patterned after `attestation/OmniRegistration.committee.test.ts` so
 * the file loads cleanly under both ethers v5 and v6 (we go through
 * the hardhat-ethers helper rather than destructured `require('ethers')`
 * named exports which are missing in v5).
 */

/* eslint-disable @typescript-eslint/no-var-requires */
const { expect } = require('chai');
const { ethers, upgrades } = require('hardhat');

const keccak256: (bytes: any) => string = ethers.keccak256;
const toUtf8Bytes: (s: string) => Uint8Array = ethers.toUtf8Bytes;

describe('OmniRegistration — SYBIL-Q-10 device-hash referral block', function () {
    let registration: any;
    let owner: any;
    let admin: any;
    let referrerWallet: any;
    let newUser: any;
    let secondUser: any;

    const DEVICE_A = keccak256(toUtf8Bytes('device-fingerprint-A'));
    const DEVICE_B = keccak256(toUtf8Bytes('device-fingerprint-B'));

    beforeEach(async function () {
        [owner, admin, referrerWallet, newUser, secondUser] =
            await ethers.getSigners();

        const DigestLib = await ethers.getContractFactory('OmniRegistrationDigestLib');
        const digestLib = await DigestLib.deploy();
        await digestLib.waitForDeployment();
        const Registration = await ethers.getContractFactory('OmniRegistration', {
            libraries: { OmniRegistrationDigestLib: await digestLib.getAddress() },
        });
        registration = await upgrades.deployProxy(Registration, [], {
            kind: 'uups',
            initializer: 'initialize',
            constructorArgs: [ethers.ZeroAddress],
            unsafeAllowLinkedLibraries: true,
        });
        await registration.waitForDeployment();

        const VALIDATOR_ROLE = keccak256(toUtf8Bytes('VALIDATOR_ROLE'));
        await registration.grantRole(VALIDATOR_ROLE, admin.address);
    });

    // ────────────────────────────────────────────────── storage / event ──

    it('records userDeviceHash on registerUser when deviceHash is non-zero', async () => {
        await registration
            .connect(admin)
            .registerUser(
                newUser.address,
                ethers.ZeroAddress,
                ethers.ZeroHash,
                keccak256(toUtf8Bytes('store-test@example.com')),
                DEVICE_A,
            );

        expect(await registration.userDeviceHash(newUser.address)).to.equal(
            DEVICE_A,
        );
    });

    it('does NOT record userDeviceHash when deviceHash is zero (back-compat)', async () => {
        await registration
            .connect(admin)
            .registerUser(
                newUser.address,
                ethers.ZeroAddress,
                ethers.ZeroHash,
                keccak256(toUtf8Bytes('nodevice@example.com')),
                ethers.ZeroHash,
            );

        expect(await registration.userDeviceHash(newUser.address)).to.equal(
            ethers.ZeroHash,
        );
    });

    it('emits DeviceHashRecorded when a non-zero hash lands', async () => {
        const tx = await registration
            .connect(admin)
            .registerUser(
                newUser.address,
                ethers.ZeroAddress,
                ethers.ZeroHash,
                keccak256(toUtf8Bytes('event-test@example.com')),
                DEVICE_A,
            );

        await expect(tx)
            .to.emit(registration, 'DeviceHashRecorded')
            .withArgs(newUser.address, DEVICE_A);
    });

    it('does NOT emit DeviceHashRecorded when deviceHash is zero', async () => {
        const tx = await registration
            .connect(admin)
            .registerUser(
                newUser.address,
                ethers.ZeroAddress,
                ethers.ZeroHash,
                keccak256(toUtf8Bytes('no-emit@example.com')),
                ethers.ZeroHash,
            );

        await expect(tx).to.not.emit(registration, 'DeviceHashRecorded');
    });

    // ────────────────────────────────────────────── referral collision ──
    //
    // The `SameDeviceReferral` revert sits behind `ReferrerKycRequired`,
    // and Tier-1 promotion requires either a wired attestation gateway
    // (see `attestation/OmniRegistration.committee.test.ts`) or a direct
    // storage write to `kycTier1CompletedAt[referrer]`. We promote the
    // referrer via `hardhat_setStorageAt` so this file remains a focused
    // unit test for the SYBIL-Q-10 surface.
    //
    // Mapping-slot derivation: `kycTier1CompletedAt` is the 11th
    // declared state variable (verified via the existing ordering in
    // `OmniRegistration.sol`); its slot is `10` (zero-indexed). For a
    // `mapping(address => uint256)` the per-key slot is
    // `keccak256(abi.encode(key, slot))`. If the OmniRegistration
    // storage layout shifts in a future upgrade, this constant must
    // move with it (caught by the `precondition` assertion below).
    const KYC_TIER1_COMPLETED_AT_SLOT = 10n;

    function tier1MappingSlot(addr: string): string {
        // ethers.solidityPackedKeccak256 takes ['address','uint256'] tuple
        // matching abi.encode(address,uint256).
        return ethers.keccak256(
            ethers.solidityPacked(
                ['uint256', 'uint256'],
                [
                    BigInt(addr),
                    KYC_TIER1_COMPLETED_AT_SLOT,
                ],
            ),
        );
    }

    async function promoteToTier1(addr: string) {
        // Bootstrap kycTier1CompletedAt[addr] = 1 via direct storage write.
        // Any non-zero value satisfies the contract's `!= 0` check.
        const slot = tier1MappingSlot(addr);
        await ethers.provider.send('hardhat_setStorageAt', [
            await registration.getAddress(),
            slot,
            '0x' + '01'.padStart(64, '0'),
        ]);
        // Precondition: confirm the slot we wrote is actually the one
        // the contract reads. If this fails, the storage layout
        // assumption is wrong and the whole file needs review.
        expect(await registration.kycTier1CompletedAt(addr)).to.equal(1n);
    }

    it('rejects registerUser when referrer carries the same deviceHash', async () => {
        // Step 1: register the referrer with DEVICE_A.
        await registration
            .connect(admin)
            .registerUser(
                referrerWallet.address,
                ethers.ZeroAddress,
                ethers.ZeroHash,
                keccak256(toUtf8Bytes('refdev@example.com')),
                DEVICE_A,
            );
        await promoteToTier1(referrerWallet.address);

        // Step 2: try to register `newUser` referred by `referrerWallet`
        // with the SAME deviceHash. The contract should revert
        // `SameDeviceReferral`.
        await expect(
            registration
                .connect(admin)
                .registerUser(
                    newUser.address,
                    referrerWallet.address,
                    ethers.ZeroHash,
                    keccak256(toUtf8Bytes('attacker@example.com')),
                    DEVICE_A,
                ),
        ).to.be.revertedWithCustomError(registration, 'SameDeviceReferral');
    });

    it('allows registerUser when referrer carries a DIFFERENT deviceHash', async () => {
        await registration
            .connect(admin)
            .registerUser(
                referrerWallet.address,
                ethers.ZeroAddress,
                ethers.ZeroHash,
                keccak256(toUtf8Bytes('refdev2@example.com')),
                DEVICE_A,
            );
        await promoteToTier1(referrerWallet.address);

        await registration
            .connect(admin)
            .registerUser(
                newUser.address,
                referrerWallet.address,
                ethers.ZeroHash,
                keccak256(toUtf8Bytes('legit-user@example.com')),
                DEVICE_B,
            );

        expect(await registration.userDeviceHash(newUser.address)).to.equal(
            DEVICE_B,
        );
    });

    it('allows registerUser when referrer has NO recorded deviceHash (legacy back-compat)', async () => {
        // Register the referrer WITHOUT a device hash (pre-upgrade flow).
        await registration
            .connect(admin)
            .registerUser(
                referrerWallet.address,
                ethers.ZeroAddress,
                ethers.ZeroHash,
                keccak256(toUtf8Bytes('legacy-ref@example.com')),
                ethers.ZeroHash,
            );
        await promoteToTier1(referrerWallet.address);
        expect(
            await registration.userDeviceHash(referrerWallet.address),
        ).to.equal(ethers.ZeroHash);

        // New user CAN register against this referrer with any device hash.
        await registration
            .connect(admin)
            .registerUser(
                newUser.address,
                referrerWallet.address,
                ethers.ZeroHash,
                keccak256(toUtf8Bytes('legacy-newuser@example.com')),
                DEVICE_A,
            );
        expect(await registration.userDeviceHash(newUser.address)).to.equal(
            DEVICE_A,
        );
    });

    it('records and reads independently for two distinct users', async () => {
        // Two users with distinct device hashes should each have their
        // own recorded value, with no cross-pollution between rows.
        await registration
            .connect(admin)
            .registerUser(
                newUser.address,
                ethers.ZeroAddress,
                ethers.ZeroHash,
                keccak256(toUtf8Bytes('user-a@example.com')),
                DEVICE_A,
            );
        await registration
            .connect(admin)
            .registerUser(
                secondUser.address,
                ethers.ZeroAddress,
                ethers.ZeroHash,
                keccak256(toUtf8Bytes('user-b@example.com')),
                DEVICE_B,
            );

        expect(await registration.userDeviceHash(newUser.address)).to.equal(
            DEVICE_A,
        );
        expect(await registration.userDeviceHash(secondUser.address)).to.equal(
            DEVICE_B,
        );
    });
});
