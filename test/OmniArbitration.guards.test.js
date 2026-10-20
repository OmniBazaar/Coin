/**
 * OmniArbitration — qualification and panel-seating guards (2026-10-20).
 *
 * Two changes are covered here:
 *
 * 1. Arbitrator qualification is its OWN gate (2026-10-20): a stake at or
 *    above the minimum AND (KYC tier 2 from OmniRegistration OR the pioneer
 *    founder allowlist). It no longer rides the validator or service-node
 *    standard, so a node-role change can never re-qualify the judge panel.
 * 2. `createDispute` refuses BEFORE pulling the 5% fee when the pool cannot
 *    seat a committee for that escrow (3 judges, plus one for each of the
 *    buyer/seller who is himself a judge). Previously the fee was taken and
 *    the dispute stuck in PendingSelection with no cancel path.
 */

const { expect } = require('chai');
const { ethers, upgrades } = require('hardhat');

describe('OmniArbitration — qualification + seating guards', function () {
  let arbitration;
  let participation;
  let mockEscrow;
  let xom;
  let owner;
  let feeVault;
  let alice;
  let bob;
  let carol;
  let buyer;
  let seller;
  let registration;

  const STAKE = ethers.parseEther('10000');
  const ESCROW_AMOUNT = ethers.parseEther('1000');

  /**
   * Register a judge with the given eligibility flags.
   * @param signer - Signer to register.
   * @param flags - Which qualifications to grant.
   * @param flags.validator - Grant the validator flag.
   * @param flags.node - Grant the service-node flag.
   */
  async function register(signer, flags) {
    if (flags.validator) {
      await participation.setCanBeValidator(signer.address, true);
    }
    if (flags.node) {
      await participation.setCanBeServiceNode(signer.address, true);
    }
    if (flags.founder) {
      await arbitration.setFounderArbitrator(signer.address, true);
    }
    if (flags.kyc) {
      await registration.setKycTier2(signer.address, true);
    }
    await participation.setTotalScore(signer.address, 60);
    await xom.mint(signer.address, STAKE);
    await xom.connect(signer).approve(await arbitration.getAddress(), STAKE);
    return arbitration.connect(signer).registerArbitrator(STAKE);
  }

  beforeEach(async function () {
    const signers = await ethers.getSigners();
    [owner] = signers;
    feeVault = signers[1];
    alice = signers[2];
    bob = signers[3];
    carol = signers[4];
    buyer = signers[5];
    seller = signers[6];

    const MockERC20 = await ethers.getContractFactory('MockERC20');
    xom = await MockERC20.deploy('OmniCoin', 'XOM');

    const MockParticipation = await ethers.getContractFactory('MockArbitrationParticipation');
    participation = await MockParticipation.deploy();

    const MockEscrow = await ethers.getContractFactory('MockArbitrationEscrow');
    mockEscrow = await MockEscrow.deploy();

    const MockRegistration = await ethers.getContractFactory('MockOmniRegistration');
    registration = await MockRegistration.deploy();

    const OmniArbitration = await ethers.getContractFactory('OmniArbitration');
    arbitration = await upgrades.deployProxy(
      OmniArbitration,
      [
        await participation.getAddress(),
        await mockEscrow.getAddress(),
        await xom.getAddress(),
        feeVault.address,
      ],
      { initializer: 'initialize', kind: 'uups', constructorArgs: [ethers.ZeroAddress] }
    );

    // The panel reads KYC directly from the registration contract.
    await arbitration.setRegistration(await registration.getAddress());

    await mockEscrow.setEscrow(1, buyer.address, seller.address, ESCROW_AMOUNT);

    for (const who of [buyer, seller]) {
      await xom.mint(who.address, ESCROW_AMOUNT);
      await xom.connect(who).approve(await arbitration.getAddress(), ESCROW_AMOUNT);
    }
  });

  it('rejects an account that is only validator-qualified', async function () {
    await expect(
      register(alice, { validator: true, node: false })
    ).to.be.revertedWithCustomError(arbitration, 'NotQualifiedArbitrator');
  });

  it('accepts an account that meets the arbitrator gate on KYC', async function () {
    await register(alice, { kyc: true });
    expect(await arbitration.isInArbitratorPool(alice.address)).to.equal(true);
    expect(await arbitration.canBeArbitrator(alice.address)).to.equal(true);
  });

  it('accepts a founder-allowlisted account without on-chain KYC', async function () {
    await register(alice, { founder: true });
    expect(await arbitration.isInArbitratorPool(alice.address)).to.equal(true);
  });

  it('drops the qualification when KYC is revoked', async function () {
    await register(alice, { kyc: true });
    await registration.setKycTier2(alice.address, false);
    expect(await arbitration.canBeArbitrator(alice.address)).to.equal(false);
  });

  it('refuses a dispute before taking the fee when the pool cannot seat a panel', async function () {
    await register(alice, { founder: true });
    await register(bob, { founder: true }); // 2 judges, need 3

    const before = await xom.balanceOf(buyer.address);
    await expect(
      arbitration.connect(buyer).createDispute(1)
    ).to.be.revertedWithCustomError(arbitration, 'ArbitrationPoolNotSeated');
    expect(await xom.balanceOf(buyer.address)).to.equal(before);
  });

  it('does not count a pooled judge who lost the qualification', async function () {
    // Registration succeeded, but eligibility is read live: a judge whose KYC
    // or allowlist entry lapses is skipped by selection. The guard must not count them,
    // or the fee is taken for a dispute that can never be seated.
    await register(alice, { founder: true });
    await register(bob, { founder: true });
    await arbitration.setFounderArbitrator(alice.address, false);

    await expect(
      arbitration.connect(buyer).createDispute(1)
    ).to.be.revertedWithCustomError(arbitration, 'ArbitrationPoolNotSeated');
  });

  it('lets a party cancel an unseatable dispute and unfreezes the escrow', async function () {
    await register(alice, { founder: true });
    await register(bob, { founder: true });
    await register(carol, { founder: true });

    await arbitration.connect(buyer).createDispute(1);
    const disputeId = (await arbitration.nextDisputeId()) - 1n;
    expect(await mockEscrow.disputed(1)).to.equal(true);

    // A judge is disqualified before selection: finalize can no longer seat.
    await arbitration.setFounderArbitrator(alice.address, false);
    await ethers.provider.send('evm_mine', []);
    await ethers.provider.send('evm_mine', []);
    await expect(
      arbitration.connect(buyer).finalizeArbitratorSelection(disputeId)
    ).to.be.revertedWithCustomError(arbitration, 'NotEnoughArbitrators');

    const before = await xom.balanceOf(buyer.address);
    await expect(arbitration.connect(buyer).cancelDispute(disputeId))
      .to.emit(arbitration, 'DisputeCancelled');
    expect(await xom.balanceOf(buyer.address)).to.equal(before + ESCROW_AMOUNT / 20n);
    expect(await mockEscrow.disputed(1)).to.equal(false);
    expect(await arbitration.escrowToDisputeId(1)).to.equal(0n);
  });

  it('refunds a seller-paid dispute fee to the seller on cancel', async function () {
    await register(alice, { founder: true });
    await register(bob, { founder: true });
    await register(carol, { founder: true });

    // The SELLER opens the dispute, so the seller paid the fee.
    await xom.connect(seller).approve(await arbitration.getAddress(), ESCROW_AMOUNT);
    await arbitration.connect(seller).createDispute(1);
    const disputeId = (await arbitration.nextDisputeId()) - 1n;

    const buyerBefore = await xom.balanceOf(buyer.address);
    const sellerBefore = await xom.balanceOf(seller.address);
    await arbitration.connect(seller).cancelDispute(disputeId);

    expect(await xom.balanceOf(seller.address)).to.equal(sellerBefore + ESCROW_AMOUNT / 20n);
    expect(await xom.balanceOf(buyer.address)).to.equal(buyerBefore);
  });

  it('refuses to default-resolve a cancelled dispute', async function () {
    await register(alice, { founder: true });
    await register(bob, { founder: true });
    await register(carol, { founder: true });

    await arbitration.connect(buyer).createDispute(1);
    const disputeId = (await arbitration.nextDisputeId()) - 1n;
    await arbitration.connect(buyer).cancelDispute(disputeId);

    await expect(
      arbitration.connect(buyer).triggerDefaultResolution(disputeId)
    ).to.be.revertedWithCustomError(arbitration, 'DisputeAlreadyResolved');
  });

  it('requires one extra judge when the buyer is himself a judge', async function () {
    // Three judges, but one of them is the buyer, who is excluded from the
    // panel — so only two are seatable and a third non-party judge is needed.
    await register(alice, { founder: true });
    await register(bob, { founder: true });
    await register(buyer, { founder: true });
    // Registering spent the buyer's 10,000 stake allowance; re-approve for the
    // dispute fee itself.
    await xom.connect(buyer).approve(await arbitration.getAddress(), ESCROW_AMOUNT);
    await mockEscrow.setEscrow(1, buyer.address, seller.address, ESCROW_AMOUNT);

    await expect(
      arbitration.connect(buyer).createDispute(1)
    ).to.be.revertedWithCustomError(arbitration, 'ArbitrationPoolNotSeated');

    await register(carol, { founder: true });
    await expect(arbitration.connect(buyer).createDispute(1)).to.not.be.reverted;
  });
});
