/**
 * Verification for the brand-release admin path added to {OmniRegistration}:
 *   - {releaseReservedUsername} — clears the reserved flag on hashes.
 *   - {bindReservedUsernameFor} — binds a reserved brand to a Tier-4-verified
 *     account, bypassing the reserved check while keeping every other binding
 *     guard, and WITHOUT un-reserving the name (the brand stays protected).
 *
 * These are the on-chain leg of the brand-claim flow: a business proves bona
 * fides via Tier-4 KYC + off-chain ownership review, then admin/ODDAO binds the
 * brand to their account. Reserved/prohibited names that are never claimed stay
 * reserved forever.
 */
const { expect } = require('chai');
const { ethers, upgrades } = require('hardhat');

describe('OmniRegistration — brand-release admin path', function () {
  let registration: any;
  let owner: any;
  let validator1: any;
  let business: any; // registered + Tier 4, no name → bind succeeds
  let lowTier: any; // registered + Tier 1 → KycTier4Required
  let namedTier4: any; // registered + Tier 4 + already owns a name → UserAlreadyHasUsername
  let otherTier4: any; // registered + Tier 4, used for the UsernameTaken race
  let unregistered: any; // never registered → NotRegistered
  let stranger: any; // lacks DEFAULT_ADMIN_ROLE
  let digestLibAddr: string;

  const VALIDATOR_ROLE = ethers.keccak256(ethers.toUtf8Bytes('VALIDATOR_ROLE'));
  const KYCTIERS_ROLE = ethers.keccak256(ethers.toUtf8Bytes('KYCTIERS_ROLE'));

  /** keccak256 of the lowercased username — must match the contract + clients. */
  function nameHash(name: string): string {
    return ethers.keccak256(ethers.toUtf8Bytes(name.toLowerCase()));
  }

  /** Register `who` via the VALIDATOR_ROLE path (no email/phone hashes). */
  async function register(who: any): Promise<void> {
    await registration
      .connect(validator1)
      .registerUser(who.address, ethers.ZeroAddress, ethers.ZeroHash, ethers.ZeroHash, ethers.ZeroHash);
  }

  beforeEach(async function () {
    [owner, validator1, business, lowTier, namedTier4, otherTier4, unregistered, stranger] =
      await ethers.getSigners();

    const DigestLib = await ethers.getContractFactory('OmniRegistrationDigestLib');
    const digestLib = await DigestLib.deploy();
    await digestLib.waitForDeployment();
    digestLibAddr = await digestLib.getAddress();

    const OmniRegistration = await ethers.getContractFactory('OmniRegistration', {
      libraries: { OmniRegistrationDigestLib: digestLibAddr },
    });
    registration = await upgrades.deployProxy(OmniRegistration, [], {
      initializer: 'initialize',
      kind: 'uups',
      constructorArgs: [ethers.ZeroAddress],
      unsafeAllowLinkedLibraries: true,
    });
    await registration.waitForDeployment();

    // Roles: validator1 registers; owner (admin) bumps KYC tiers directly
    // (kycTiersContract is unbound on a fresh proxy, so a KYCTIERS_ROLE holder
    // can call bumpKycTier).
    await registration.grantRole(VALIDATOR_ROLE, validator1.address);
    await registration.grantRole(KYCTIERS_ROLE, owner.address);

    // Cohorts.
    await register(business);
    await registration.bumpKycTier(business.address, 4);

    await register(lowTier); // stays Tier 1

    await register(namedTier4);
    await registration.bumpKycTier(namedTier4.address, 4);

    await register(otherTier4);
    await registration.bumpKycTier(otherTier4.address, 4);

    // A reserved brand to claim and one to release.
    await registration.seedReservedUsernames([nameHash('nike'), nameHash('acme')]);
  });

  describe('releaseReservedUsername', function () {
    it('clears the reserved flag and emits ReservedUsernamesReleased', async function () {
      expect(await registration.reservedUsername(nameHash('acme'))).to.equal(true);

      await expect(registration.releaseReservedUsername([nameHash('acme')]))
        .to.emit(registration, 'ReservedUsernamesReleased')
        .withArgs(1);

      expect(await registration.reservedUsername(nameHash('acme'))).to.equal(false);
      // Untouched reservation is unaffected.
      expect(await registration.reservedUsername(nameHash('nike'))).to.equal(true);
    });

    it('is idempotent — releasing an unreserved hash is a no-op', async function () {
      await expect(registration.releaseReservedUsername([nameHash('never-reserved')]))
        .to.emit(registration, 'ReservedUsernamesReleased')
        .withArgs(1);
      expect(await registration.reservedUsername(nameHash('never-reserved'))).to.equal(false);
    });

    it('reverts for a caller without DEFAULT_ADMIN_ROLE', async function () {
      await expect(registration.connect(stranger).releaseReservedUsername([nameHash('acme')])).to.be
        .reverted;
    });
  });

  describe('bindReservedUsernameFor', function () {
    it('binds a reserved brand to a Tier-4 account WITHOUT un-reserving it', async function () {
      await expect(registration.bindReservedUsernameFor(business.address, nameHash('nike')))
        .to.emit(registration, 'UsernameBound')
        .withArgs(business.address, nameHash('nike'));

      // Forward + reverse resolution now point at the business account.
      expect(await registration.resolveUsername('nike')).to.equal(business.address);
      expect(await registration.usernameOwner(nameHash('nike'))).to.equal(business.address);
      expect(await registration.registeredUsernameHash(business.address)).to.equal(nameHash('nike'));

      // Key invariant: the brand stays reserved (protected against squatters).
      expect(await registration.reservedUsername(nameHash('nike'))).to.equal(true);
    });

    it('reverts NotRegistered for an unregistered account', async function () {
      await expect(
        registration.bindReservedUsernameFor(unregistered.address, nameHash('nike')),
      ).to.be.revertedWithCustomError(registration, 'NotRegistered');
    });

    it('reverts KycTier4Required for a registered account below Tier 4', async function () {
      await expect(registration.bindReservedUsernameFor(lowTier.address, nameHash('nike')))
        .to.be.revertedWithCustomError(registration, 'KycTier4Required')
        .withArgs(lowTier.address);
    });

    it('reverts InvalidUsername for the zero hash', async function () {
      await expect(
        registration.bindReservedUsernameFor(business.address, ethers.ZeroHash),
      ).to.be.revertedWithCustomError(registration, 'InvalidUsername');
    });

    it('reverts NotReserved for a name that was never reserved', async function () {
      await expect(registration.bindReservedUsernameFor(business.address, nameHash('not-a-brand')))
        .to.be.revertedWithCustomError(registration, 'NotReserved')
        .withArgs(nameHash('not-a-brand'));
    });

    it('reverts UserAlreadyHasUsername when the account already owns a name', async function () {
      await registration.bindReservedUsernameFor(namedTier4.address, nameHash('nike'));
      // 'acme' is a second reserved brand; same account cannot take a second name.
      await expect(registration.bindReservedUsernameFor(namedTier4.address, nameHash('acme')))
        .to.be.revertedWithCustomError(registration, 'UserAlreadyHasUsername')
        .withArgs(namedTier4.address);
    });

    it('reverts UsernameTaken when the brand is already bound to someone else', async function () {
      await registration.bindReservedUsernameFor(business.address, nameHash('nike'));
      await expect(registration.bindReservedUsernameFor(otherTier4.address, nameHash('nike')))
        .to.be.revertedWithCustomError(registration, 'UsernameTaken')
        .withArgs(nameHash('nike'));
    });

    it('reverts for a caller without DEFAULT_ADMIN_ROLE', async function () {
      await expect(
        registration.connect(stranger).bindReservedUsernameFor(business.address, nameHash('nike')),
      ).to.be.reverted;
    });

    it('a released name can no longer be bound via the brand path (reserved gate)', async function () {
      // releaseReservedUsername retires a name back to the public pool. After
      // release the brand path must refuse it — it is bound (if at all) only via
      // the normal owner-signed trustless path, not by admin.
      await registration.releaseReservedUsername([nameHash('acme')]);
      expect(await registration.reservedUsername(nameHash('acme'))).to.equal(false);
      await expect(registration.bindReservedUsernameFor(business.address, nameHash('acme')))
        .to.be.revertedWithCustomError(registration, 'NotReserved')
        .withArgs(nameHash('acme'));
    });
  });
});
