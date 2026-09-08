/**
 * Verification for the one-time admin name backfill (OmniRegistrationTempAdmin).
 *
 * Runs the exact three-step flow the operational scripts perform — upgrade the
 * proxy to the temp admin impl, backfill names, revert to the original impl —
 * and asserts the "five guardrails" for a safe revert:
 *   1. Storage layout intact: after reverting, every pre-existing slot
 *      (DOMAIN_SEPARATOR, totalRegistrations) is unchanged and the backfilled
 *      bindings still resolve through the ORIGINAL logic.
 *   2. UUPS machinery intact: while on the temp impl, the proxy upgrades BACK
 *      to the original (the revert tx itself succeeds).
 *   3. No initializer run on upgrade (empty call data) — state untouched.
 *   4. Capability removed: after revert the temp-only selector is gone.
 *   5. Bindings persist in proxy storage across the revert.
 *
 * Plus the function-level guards (registered/reserved/taken/access-control).
 */
const { expect } = require('chai');
const { ethers, upgrades } = require('hardhat');

describe('OmniRegistration — temp-admin backfill flow', function () {
  let registration: any;
  let owner: any;
  let validator1: any;
  let userA: any; // off-chain-only → adminRegisterWithName
  let userB: any; // registered-but-unbound → adminBindUsername
  let userC: any; // unregistered control
  let stranger: any;
  let digestLibAddr: string;
  let originalImpl: string;

  const VALIDATOR_ROLE = ethers.keccak256(ethers.toUtf8Bytes('VALIDATOR_ROLE'));

  /** keccak256 of the lowercased username — must match the contract + clients. */
  function nameHash(name: string): string {
    return ethers.keccak256(ethers.toUtf8Bytes(name.toLowerCase()));
  }

  beforeEach(async function () {
    [owner, validator1, userA, userB, userC, stranger] = await ethers.getSigners();

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
    originalImpl = await upgrades.erc1967.getImplementationAddress(await registration.getAddress());

    // userB: registered on-chain but no name bound (the WebApp cohort).
    await registration.grantRole(VALIDATOR_ROLE, validator1.address);
    await registration
      .connect(validator1)
      .registerUser(
        userB.address,
        ethers.ZeroAddress,
        ethers.ZeroHash,
        nameHash('b@x.io'),
        ethers.ZeroHash,
      );

    // Reserve a name so the reserved-set guard is exercised.
    await registration.seedReservedUsernames([nameHash('admin')]);
  });

  it('upgrade → backfill (register+bind, bind) → revert, preserving state and removing the capability', async function () {
    const proxyAddr = await registration.getAddress();
    const totalBefore: bigint = await registration.totalRegistrations();
    const domainBefore: string = await registration.DOMAIN_SEPARATOR();

    // ── Step 1: upgrade to the temp admin impl (raw upgradeToAndCall, as the script does) ──
    const Temp = await ethers.getContractFactory('OmniRegistrationTempAdmin', {
      libraries: { OmniRegistrationDigestLib: digestLibAddr },
    });
    const temp = await Temp.deploy(ethers.ZeroAddress);
    await temp.waitForDeployment();
    const tempImpl = await temp.getAddress();
    expect(tempImpl).to.not.equal(originalImpl);

    await registration.upgradeToAndCall(tempImpl, '0x');
    const proxy = await ethers.getContractAt('OmniRegistrationTempAdmin', proxyAddr);
    expect(await proxy.isTempAdminImpl()).to.equal(true); // guardrail 2/4: temp live

    // ── Step 2: backfill ──
    // Off-chain-only account: register + bind in one tx.
    await proxy.adminRegisterWithName(userA.address, nameHash('alice'));
    expect(await proxy.isRegistered(userA.address)).to.equal(true);
    expect(await proxy.resolveUsername('alice')).to.equal(userA.address);

    // Already-registered-but-unbound account: bind only.
    await proxy.adminBindUsername(userB.address, nameHash('bob'));
    expect(await proxy.resolveUsername('bob')).to.equal(userB.address);

    // Function-level guards.
    await expect(
      proxy.adminBindUsername(userC.address, nameHash('carol')),
    ).to.be.revertedWithCustomError(proxy, 'NotRegistered');
    await expect(
      proxy.adminRegisterWithName(userA.address, nameHash('alice2')),
    ).to.be.revertedWithCustomError(proxy, 'AlreadyRegistered');
    await expect(
      proxy.adminRegisterWithName(userC.address, nameHash('admin')),
    ).to.be.revertedWithCustomError(proxy, 'UsernameReserved');
    await expect(
      proxy.connect(stranger).adminBindUsername(userB.address, nameHash('x')),
    ).to.be.reverted; // AccessControl: caller lacks DEFAULT_ADMIN_ROLE

    // ── Step 3: revert to the exact original implementation ──
    await registration.upgradeToAndCall(originalImpl, '0x'); // guardrail 2: UUPS revert works

    // guardrail 4: temp-only capability is gone.
    await expect(proxy.isTempAdminImpl()).to.be.reverted;

    // guardrails 1 + 5: state persists + storage layout intact, read via ORIGINAL logic.
    const orig = await ethers.getContractAt('OmniRegistration', proxyAddr);
    expect(await orig.resolveUsername('alice')).to.equal(userA.address);
    expect(await orig.resolveUsername('bob')).to.equal(userB.address);
    expect(await orig.registeredUsernameHash(userA.address)).to.equal(nameHash('alice'));
    // userA's base registration is real + persists (isRegistered true) even
    // though the temp impl intentionally does NOT bump the cosmetic counter.
    expect(await orig.isRegistered(userA.address)).to.equal(true);
    expect(await orig.totalRegistrations()).to.equal(totalBefore); // counter intentionally unchanged by the temp impl
    expect(await orig.DOMAIN_SEPARATOR()).to.equal(domainBefore);
  });

  it('the original implementation has NO admin bind path (so the capability only exists during the temp window)', async function () {
    // Sanity: on the original impl, the temp selector must not exist.
    const proxyAsTemp = await ethers.getContractAt(
      'OmniRegistrationTempAdmin',
      await registration.getAddress(),
    );
    await expect(proxyAsTemp.isTempAdminImpl()).to.be.reverted;
    await expect(
      proxyAsTemp.adminBindUsername(userB.address, nameHash('bob')),
    ).to.be.reverted;
  });
});
