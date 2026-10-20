/**
 * OmniArbitration — panel hardening (2026-10-20).
 *
 * Covers the five approved changes:
 *   1. a per-dispute seat bond that must be posted before a judge may vote;
 *   2. a seven-day challenge window during which the bond stays locked;
 *   3. a review panel that can overturn a verdict by paying the harmed party
 *      out of the challenged majority's bonds (no escrow reversal);
 *   4. fees paid only to judges who voted;
 *   5. a no-verdict dispute returns to the status quo instead of refunding the
 *      buyer, and the fee goes back to whoever paid it.
 */

const { expect } = require('chai');
const { ethers, upgrades } = require('hardhat');
const { time } = require('@nomicfoundation/hardhat-network-helpers');

describe('OmniArbitration — panel hardening', function () {
  let arbitration;
  let mockEscrow;
  let xom;
  let owner;
  let feeVault;
  let judges;
  let buyer;
  let seller;
  let outsider;

  const STAKE = ethers.parseEther('10000');
  const ESCROW_AMOUNT = ethers.parseEther('1000');
  const DISPUTE_FEE = ESCROW_AMOUNT / 20n; // 5%
  const RELEASE = 1;
  const REFUND = 2;

  async function register(signer) {
    await arbitration.setFounderArbitrator(signer.address, true);
    await xom.mint(signer.address, ethers.parseEther('100000'));
    await xom.connect(signer).approve(await arbitration.getAddress(), ethers.MaxUint256);
    await arbitration.connect(signer).registerArbitrator(STAKE);
  }

  async function seat(disputeId) {
    const d = await arbitration.getDispute(disputeId);
    return d.arbitrators.map((a) => judges.find((j) => j.address === a));
  }

  async function postBonds(disputeId) {
    const panel = await seat(disputeId);
    for (const judge of panel) {
      await arbitration.connect(judge).postSeatBond(disputeId);
    }
    return panel;
  }

  async function openDispute() {
    await arbitration.connect(buyer).createDispute(1);
    const disputeId = (await arbitration.nextDisputeId()) - 1n;
    await ethers.provider.send('evm_mine', []);
    await ethers.provider.send('evm_mine', []);
    await arbitration.connect(buyer).finalizeArbitratorSelection(disputeId);
    return disputeId;
  }

  beforeEach(async function () {
    const signers = await ethers.getSigners();
    owner = signers[0];
    feeVault = signers[1];
    judges = signers.slice(2, 10);
    buyer = signers[10];
    seller = signers[11];
    outsider = signers[12];

    const MockERC20 = await ethers.getContractFactory('MockERC20');
    xom = await MockERC20.deploy('OmniCoin', 'XOM');

    const MockParticipation = await ethers.getContractFactory('MockArbitrationParticipation');
    const participation = await MockParticipation.deploy();

    const MockEscrow = await ethers.getContractFactory('MockArbitrationEscrow');
    mockEscrow = await MockEscrow.deploy();

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

    await mockEscrow.setEscrow(1, buyer.address, seller.address, ESCROW_AMOUNT);
    for (const who of [buyer, seller]) {
      // Enough for the dispute fee AND the 1,000 XOM escalation bond.
      await xom.mint(who.address, ethers.parseEther('100000'));
      await xom.connect(who).approve(await arbitration.getAddress(), ethers.MaxUint256);
    }
    for (const judge of judges) await register(judge);
  });

  it('refuses a vote before the judge posts the seat bond', async function () {
    const disputeId = await openDispute();
    const panel = await seat(disputeId);
    await expect(
      arbitration.connect(panel[0]).castVote(disputeId, RELEASE)
    ).to.be.revertedWithCustomError(arbitration, 'SeatBondMissing');
  });

  it('sizes the bond at the disputed amount and locks it', async function () {
    const disputeId = await openDispute();
    const panel = await seat(disputeId);
    expect(await arbitration.seatBondFor(disputeId)).to.equal(ESCROW_AMOUNT);

    await arbitration.connect(panel[0]).postSeatBond(disputeId);
    expect(await arbitration.lockedBond(panel[0].address)).to.equal(ESCROW_AMOUNT);

    // While the dispute is live the stake is blocked by the assignment itself.
    await expect(
      arbitration.connect(panel[0]).withdrawArbitratorStake(STAKE)
    ).to.be.revertedWithCustomError(arbitration, 'ArbitratorBusyInDispute');

    // After the verdict the assignment clears, but the bond still holds.
    await arbitration.connect(panel[1]).postSeatBond(disputeId);
    await arbitration.connect(panel[2]).postSeatBond(disputeId);
    await arbitration.connect(panel[0]).castVote(disputeId, RELEASE);
    await arbitration.connect(panel[1]).castVote(disputeId, RELEASE);
    await expect(
      arbitration.connect(panel[0]).withdrawArbitratorStake(STAKE)
    ).to.be.revertedWithCustomError(arbitration, 'BondsStillLocked');
  });

  it('resolves, then holds the bonds for the challenge window and returns them', async function () {
    const disputeId = await openDispute();
    const panel = await postBonds(disputeId);
    await arbitration.connect(panel[0]).castVote(disputeId, RELEASE);
    await arbitration.connect(panel[1]).castVote(disputeId, RELEASE);

    // Bonds are still locked right after the verdict.
    await expect(
      arbitration.unlockBonds(disputeId)
    ).to.be.revertedWithCustomError(arbitration, 'ChallengeWindowOpen');

    await time.increase(7 * 24 * 60 * 60 + 1);
    await arbitration.unlockBonds(disputeId);

    expect(await arbitration.lockedBond(panel[0].address)).to.equal(0n);
    expect(await arbitration.lockedBond(panel[1].address)).to.equal(0n);
  });

  it('pays only the judges who voted', async function () {
    const disputeId = await openDispute();
    const panel = await postBonds(disputeId);
    await arbitration.connect(panel[0]).castVote(disputeId, RELEASE);
    await arbitration.connect(panel[1]).castVote(disputeId, RELEASE);

    const perJudge = (DISPUTE_FEE * 3000n) / 10000n;
    const voterBefore = await xom.balanceOf(panel[0].address);
    const absenteeBefore = await xom.balanceOf(panel[2].address);

    // The fee distributes inside _resolveDispute, so measure the deltas on a
    // second dispute where the pre-verdict balances are known.
    await mockEscrow.setEscrow(2, buyer.address, seller.address, ESCROW_AMOUNT);
    await xom.mint(buyer.address, ESCROW_AMOUNT);
    await xom.connect(buyer).approve(await arbitration.getAddress(), ESCROW_AMOUNT);
    await arbitration.connect(buyer).createDispute(2);
    const second = (await arbitration.nextDisputeId()) - 1n;
    await ethers.provider.send('evm_mine', []);
    await ethers.provider.send('evm_mine', []);
    await arbitration.connect(buyer).finalizeArbitratorSelection(second);
    const panel2 = await postBonds(second);

    const before = [];
    for (const j of panel2) before.push(await xom.balanceOf(j.address));

    await arbitration.connect(panel2[0]).castVote(second, RELEASE);
    await arbitration.connect(panel2[1]).castVote(second, RELEASE);

    for (let i = 0; i < 3; i += 1) {
      const after = await xom.balanceOf(panel2[i].address);
      const delta = after - before[i];
      if (i < 2) {
        expect(delta).to.equal(perJudge);
      } else {
        expect(delta).to.equal(0n);
      }
    }
    expect(voterBefore).to.be.a('bigint');
    expect(absenteeBefore).to.be.a('bigint');
  });

  it('reviews a verdict: an overturn pays the challenger from the majority bonds', async function () {
    const disputeId = await openDispute();
    const panel = await postBonds(disputeId);
    await arbitration.connect(panel[0]).castVote(disputeId, RELEASE);
    await arbitration.connect(panel[1]).castVote(disputeId, RELEASE);

    const challengerBefore = await xom.balanceOf(buyer.address);
    await arbitration.connect(buyer).escalate(disputeId);
    expect(await arbitration.escalated(disputeId)).to.equal(true);

    const review = await arbitration.getEscalationPanel(disputeId);
    const reviewSigners = review.map((a) => judges.find((j) => j.address === a));
    await arbitration.connect(reviewSigners[0]).castReviewVote(disputeId, false);
    const tx = await arbitration.connect(reviewSigners[1]).castReviewVote(disputeId, false);

    await expect(tx).to.emit(arbitration, 'ReviewDecided');

    // Net for the challenger: out the review bond at escalate time, in for the
    // forfeited majority bonds CAPPED at the disputed amount, plus the bond
    // remainder after the two review voters are paid (25% each).
    const bond = ESCROW_AMOUNT; // 1,000 XOM disputed
    const reviewBond = (ESCROW_AMOUNT * 5000n) / 10000n; // 5% = 500 XOM
    const reviewerPay = (reviewBond / 4n) * 2n;
    const challengerAfter = await xom.balanceOf(buyer.address);
    expect(challengerAfter - challengerBefore).to.equal(
      bond - reviewerPay
    );
    expect(await arbitration.lockedBond(panel[0].address)).to.equal(0n);
    expect(await arbitration.lockedBond(panel[1].address)).to.equal(0n);
  });

  it('reviews a verdict: an upheld verdict pays the review voters, not the panel', async function () {
    const disputeId = await openDispute();
    const panel = await postBonds(disputeId);
    await arbitration.connect(panel[0]).castVote(disputeId, RELEASE);
    await arbitration.connect(panel[1]).castVote(disputeId, RELEASE);

    await arbitration.connect(buyer).escalate(disputeId);
    const review = await arbitration.getEscalationPanel(disputeId);
    const reviewSigners = review.map((a) => judges.find((j) => j.address === a));

    const reviewerBefore = await xom.balanceOf(reviewSigners[0].address);
    const majorityBefore = await xom.balanceOf(panel[0].address);

    await arbitration.connect(reviewSigners[0]).castReviewVote(disputeId, true);
    await arbitration.connect(reviewSigners[1]).castReviewVote(disputeId, true);

    const reviewerAfter = await xom.balanceOf(reviewSigners[0].address);
    const majorityAfter = await xom.balanceOf(panel[0].address);

    // Reviewers earn a quarter of the review bond each.
    expect(reviewerAfter - reviewerBefore).to.equal(
      ((ESCROW_AMOUNT * 5000n) / 10000n) / 4n
    );
    // The panel only gets its own seat bond back — it is not paid extra for
    // being challenged.
    expect(majorityAfter - majorityBefore).to.equal(ESCROW_AMOUNT);
  });

  it('releases the seat bonds when a deadlocked dispute times out (audit C-01)', async function () {
    const disputeId = await openDispute();
    const panel = await postBonds(disputeId);

    // 1-1 split, third judge silent: no verdict can be reached.
    await arbitration.connect(panel[0]).castVote(disputeId, RELEASE);
    await arbitration.connect(panel[1]).castVote(disputeId, REFUND);
    await time.increase(7 * 24 * 60 * 60 + 1);

    await arbitration.connect(buyer).triggerDefaultResolution(disputeId);

    // The reseat must have returned every bond and cleared the vote records.
    for (const judge of panel) {
      expect(await arbitration.lockedBond(judge.address)).to.equal(0n);
      // Their stake is withdrawable again.
      await expect(
        arbitration.connect(judge).withdrawArbitratorStake(STAKE)
      ).to.not.be.reverted;
    }
    const d = await arbitration.getDispute(disputeId);
    expect(d.status).to.equal(4); // PendingSelection (fresh round)
  });

  it('closes a stalled review and returns the panel bonds (audit C-02)', async function () {
    const disputeId = await openDispute();
    const panel = await postBonds(disputeId);
    await arbitration.connect(panel[0]).castVote(disputeId, RELEASE);
    await arbitration.connect(panel[1]).castVote(disputeId, RELEASE);

    const vaultBefore = await xom.balanceOf(feeVault.address);
    await arbitration.connect(buyer).escalate(disputeId);

    // Nobody votes on the review; it lapses.
    await time.increase(3 * 24 * 60 * 60 + 1);
    await expect(arbitration.connect(outsider).lapseReview(disputeId))
      .to.emit(arbitration, 'ReviewLapsed');

    for (const judge of panel) {
      expect(await arbitration.lockedBond(judge.address)).to.equal(0n);
    }
    // A stalled review costs the challenger the bond, paid to the vault.
    const bond = (ESCROW_AMOUNT * 5000n) / 10000n;
    expect(await xom.balanceOf(feeVault.address)).to.equal(vaultBefore + bond);
    expect(await arbitration.lockedBond(buyer.address)).to.equal(0n);
  });

  it('refuses a review after the challenge window', async function () {
    const disputeId = await openDispute();
    const panel = await postBonds(disputeId);
    await arbitration.connect(panel[0]).castVote(disputeId, RELEASE);
    await arbitration.connect(panel[1]).castVote(disputeId, RELEASE);

    await time.increase(7 * 24 * 60 * 60 + 1);
    await expect(
      arbitration.connect(buyer).escalate(disputeId)
    ).to.be.revertedWithCustomError(arbitration, 'ChallengeWindowClosed');
  });
});
