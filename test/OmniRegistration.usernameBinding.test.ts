/**
 * Functional tests for the trustless user-signed username binding added 2026-06-09:
 * selfRegisterTrustlessForWithName (covered indirectly via _bindUsername),
 * bindUsernameTrustless (standalone migration path), seedReservedUsernames, and
 * resolveUsername. Focus: the anti-squat core (reserved + first-come uniqueness +
 * one-name-per-account) and that the binding is authored ONLY by the user signature.
 */
const { expect } = require('chai');
const { ethers, upgrades } = require('hardhat');
const { time } = require('@nomicfoundation/hardhat-network-helpers');

describe('OmniRegistration — trustless username binding', function () {
  let registration: any;
  let owner: any;
  let validator1: any;
  let user1: any;
  let user2: any;
  let relayer: any;
  let chainId: bigint;

  const VALIDATOR_ROLE = ethers.keccak256(ethers.toUtf8Bytes('VALIDATOR_ROLE'));

  /** keccak256 of the lowercased username — must match the contract + clients. */
  function nameHash(name: string): string {
    return ethers.keccak256(ethers.toUtf8Bytes(name.toLowerCase()));
  }

  /** Sign the BindUsername EIP-712 payload as `signer`. */
  async function signBind(
    signer: any,
    user: string,
    usernameHash: string,
    deadline: number,
  ): Promise<string> {
    const domain = {
      name: 'OmniRegistration',
      version: '1',
      chainId,
      verifyingContract: await registration.getAddress(),
    };
    const types = {
      BindUsername: [
        { name: 'user', type: 'address' },
        { name: 'usernameHash', type: 'bytes32' },
        { name: 'deadline', type: 'uint256' },
      ],
    };
    return signer.signTypedData(domain, types, { user, usernameHash, deadline });
  }

  /** Register `user` on-chain via the validator path so bindUsernameTrustless is reachable. */
  async function register(user: any, phone: string, email: string): Promise<void> {
    await registration
      .connect(validator1)
      .registerUser(
        user.address,
        ethers.ZeroAddress,
        ethers.keccak256(ethers.toUtf8Bytes(phone)),
        ethers.keccak256(ethers.toUtf8Bytes(email)),
        ethers.ZeroHash,
      );
  }

  beforeEach(async function () {
    [owner, validator1, user1, user2, relayer] = await ethers.getSigners();
    chainId = (await ethers.provider.getNetwork()).chainId;

    const DigestLib = await ethers.getContractFactory('OmniRegistrationDigestLib');
    const digestLib = await DigestLib.deploy();
    await digestLib.waitForDeployment();

    const MockGateway = await ethers.getContractFactory('MockGatewayForDecent');
    const mockGateway = await MockGateway.deploy();
    await mockGateway.waitForDeployment();

    const OmniRegistration = await ethers.getContractFactory('OmniRegistration', {
      libraries: { OmniRegistrationDigestLib: await digestLib.getAddress() },
    });
    registration = await upgrades.deployProxy(OmniRegistration, [], {
      initializer: 'initialize',
      kind: 'uups',
      constructorArgs: [ethers.ZeroAddress],
      unsafeAllowLinkedLibraries: true,
    });
    await registration.waitForDeployment();

    await registration.grantRole(VALIDATOR_ROLE, validator1.address);
    await registration.connect(owner).setAttestationGateway(await mockGateway.getAddress());

    await register(user1, '+15550001111', 'a@x.io');
    await register(user2, '+15550002222', 'b@x.io');
  });

  it('binds a username under the user signature; resolveUsername returns the owner', async function () {
    const h = nameHash('Alice');
    const deadline = (await time.latest()) + 3600;
    const sig = await signBind(user1, user1.address, h, deadline);

    // Relayer submits — authority is the user signature, not the caller.
    await expect(registration.connect(relayer).bindUsernameTrustless(user1.address, h, deadline, sig))
      .to.emit(registration, 'UsernameBound')
      .withArgs(user1.address, h);

    expect(await registration.usernameOwner(h)).to.equal(user1.address);
    expect(await registration.registeredUsernameHash(user1.address)).to.equal(h);
    // The contract does NOT lowercase (audit INFO-2: normalization is the
    // client's job). The bound (lowercased) form resolves; the raw cased form
    // does not — clients MUST normalize identically on bind + resolve.
    expect(await registration.resolveUsername('alice')).to.equal(user1.address);
    expect(await registration.resolveUsername('Alice')).to.equal(ethers.ZeroAddress);
  });

  it('rejects a signature from anyone other than the user (no relayer/forgery)', async function () {
    const h = nameHash('bob');
    const deadline = (await time.latest()) + 3600;
    const forged = await signBind(user2, user1.address, h, deadline); // user2 signs for user1
    await expect(
      registration.connect(relayer).bindUsernameTrustless(user1.address, h, deadline, forged),
    ).to.be.revertedWithCustomError(registration, 'InvalidUserSignature');
  });

  it('blocks reserved names (anti-squat), and seedReservedUsernames is admin-only', async function () {
    const h = nameHash('coinbase');
    await expect(registration.connect(user1).seedReservedUsernames([h])).to.be.reverted; // not admin
    await registration.connect(owner).seedReservedUsernames([h]);

    const deadline = (await time.latest()) + 3600;
    const sig = await signBind(user1, user1.address, h, deadline);
    await expect(
      registration.connect(relayer).bindUsernameTrustless(user1.address, h, deadline, sig),
    ).to.be.revertedWithCustomError(registration, 'UsernameReserved');
  });

  it('blocks an already-taken name (first-come uniqueness)', async function () {
    const h = nameHash('shared');
    const d1 = (await time.latest()) + 3600;
    await registration
      .connect(relayer)
      .bindUsernameTrustless(user1.address, h, d1, await signBind(user1, user1.address, h, d1));

    const d2 = (await time.latest()) + 3600;
    await expect(
      registration
        .connect(relayer)
        .bindUsernameTrustless(user2.address, h, d2, await signBind(user2, user2.address, h, d2)),
    ).to.be.revertedWithCustomError(registration, 'UsernameTaken');
  });

  it('enforces one username per account', async function () {
    const h1 = nameHash('first');
    const d1 = (await time.latest()) + 3600;
    await registration
      .connect(relayer)
      .bindUsernameTrustless(user1.address, h1, d1, await signBind(user1, user1.address, h1, d1));

    const h2 = nameHash('second');
    const d2 = (await time.latest()) + 3600;
    await expect(
      registration
        .connect(relayer)
        .bindUsernameTrustless(user1.address, h2, d2, await signBind(user1, user1.address, h2, d2)),
    ).to.be.revertedWithCustomError(registration, 'UserAlreadyHasUsername');
  });

  it('rejects binding for an unregistered user and an expired deadline', async function () {
    const [, , , , , stranger] = await ethers.getSigners();
    const h = nameHash('ghost');
    const deadline = (await time.latest()) + 3600;
    await expect(
      registration
        .connect(relayer)
        .bindUsernameTrustless(stranger.address, h, deadline, await signBind(stranger, stranger.address, h, deadline)),
    ).to.be.revertedWithCustomError(registration, 'NotRegistered');

    const past = (await time.latest()) - 1;
    await expect(
      registration
        .connect(relayer)
        .bindUsernameTrustless(user1.address, h, past, await signBind(user1, user1.address, h, past)),
    ).to.be.revertedWithCustomError(registration, 'AttestationExpired');
  });
});
