/**
 * @file AMMPermissionlessGuardian.test.ts
 * @description Tests for the AMMPermissionless emergency-guardian rotation
 *              (audit H-02 remediation: EMERGENCY_GUARDIAN was immutable;
 *              now a two-step, guardian-admin-gated setter).
 *
 * Tests cover:
 * - Constructor initializes guardian + guardianAdmin = deployer
 * - emergencyGuardian() getter reflects current guardian
 * - Two-step propose/apply swaps the guardian + emits events
 * - Access control: only guardianAdmin may propose/apply/transfer
 * - Input validation: zero address, EOA (no code), same-guardian, no-pending
 * - transferGuardianAdmin rotates the admin
 */

/* eslint-disable @typescript-eslint/no-var-requires */
const { expect } = require('chai');
const { ethers } = require('hardhat');

describe('AMMPermissionless — guardian rotation (H-02)', function () {
    let amm: any;
    let oldGuardian: any;
    let newGuardian: any;
    let feeVault: any;

    let deployer: any;
    let admin: any;
    let other: any;
    let guardian1: any;
    let guardian2: any;

    beforeEach(async function () {
        [deployer, admin, other, guardian1, guardian2] = await ethers.getSigners();

        const MockToken = await ethers.getContractFactory('MockXOMToken');
        feeVault = await MockToken.deploy();

        // Two real PermissionlessGuardian instances (the guardian the AMM
        // delegates isGuardian() to on external chains).
        const GuardianFactory = await ethers.getContractFactory('PermissionlessGuardian');
        const guardians = [deployer.address, guardian1.address, guardian2.address];
        oldGuardian = await GuardianFactory.deploy(deployer.address, guardians);
        newGuardian = await GuardianFactory.deploy(deployer.address, guardians);

        const AMMFactory = await ethers.getContractFactory('AMMPermissionless');
        amm = await AMMFactory.deploy(
            oldGuardian.getAddress(),
            feeVault.getAddress(),
            feeVault.getAddress(),
            ethers.ZeroAddress
        );
    });

    it('initializes guardian + guardianAdmin to the deployer', async function () {
        expect(await amm.emergencyGuardian()).to.equal(await oldGuardian.getAddress());
        expect(await amm.guardianAdmin()).to.equal(deployer.address);
    });

    it('completes a two-step guardian swap and emits both events', async function () {
        await expect(amm.proposeEmergencyGuardian(await newGuardian.getAddress()))
            .to.emit(amm, 'EmergencyGuardianProposed')
            .withArgs(await newGuardian.getAddress());

        // Not applied yet — still old.
        expect(await amm.emergencyGuardian()).to.equal(await oldGuardian.getAddress());

        await expect(amm.applyEmergencyGuardian())
            .to.emit(amm, 'EmergencyGuardianUpdated')
            .withArgs(await oldGuardian.getAddress(), await newGuardian.getAddress());

        expect(await amm.emergencyGuardian()).to.equal(await newGuardian.getAddress());
    });

    it('reverts propose when called by a non-admin', async function () {
        await expect(
            amm.connect(other).proposeEmergencyGuardian(await newGuardian.getAddress())
        ).to.be.revertedWithCustomError(amm, 'NotGuardianAdmin');
    });

    it('reverts apply when called by a non-admin', async function () {
        await expect(
            amm.connect(other).applyEmergencyGuardian()
        ).to.be.revertedWithCustomError(amm, 'NotGuardianAdmin');
    });

    it('reverts apply with no pending change', async function () {
        await expect(amm.applyEmergencyGuardian())
            .to.be.revertedWithCustomError(amm, 'NoPendingGuardianChange');
    });

    it('reverts propose of a zero address', async function () {
        await expect(amm.proposeEmergencyGuardian(ethers.ZeroAddress))
            .to.be.revertedWithCustomError(amm, 'ZeroAddress');
    });

    it('reverts propose of an EOA (no deployed code)', async function () {
        await expect(amm.proposeEmergencyGuardian(other.address))
            .to.be.revertedWithCustomError(amm, 'GuardianNotContract');
    });

    it('reverts propose of the guardian already set', async function () {
        await expect(amm.proposeEmergencyGuardian(await oldGuardian.getAddress()))
            .to.be.revertedWithCustomError(amm, 'GuardianAlreadySet');
    });

    it('rotates guardianAdmin and revokes the old admin', async function () {
        await expect(amm.transferGuardianAdmin(admin.address))
            .to.emit(amm, 'GuardianAdminTransferred')
            .withArgs(deployer.address, admin.address);

        expect(await amm.guardianAdmin()).to.equal(admin.address);

        // Old admin can no longer propose.
        await expect(
            amm.proposeEmergencyGuardian(await newGuardian.getAddress())
        ).to.be.revertedWithCustomError(amm, 'NotGuardianAdmin');

        // New admin can.
        await amm.connect(admin).proposeEmergencyGuardian(await newGuardian.getAddress());
        await amm.connect(admin).applyEmergencyGuardian();
        expect(await amm.emergencyGuardian()).to.equal(await newGuardian.getAddress());
    });

    it('reverts transferGuardianAdmin to a zero address', async function () {
        await expect(amm.transferGuardianAdmin(ethers.ZeroAddress))
            .to.be.revertedWithCustomError(amm, 'ZeroAddress');
    });
});
