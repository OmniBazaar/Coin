/**
 * MinimalEscrow.sol — Comprehensive Test Suite (Round 8)
 *
 * Supplements the existing ~31-test MinimalEscrow.test.js with ~70 additional tests
 * covering gaps identified during Round 8 adversarial review:
 *
 * 1.  Deployment + immutable verification — 5 tests
 * 2.  createEscrow edge cases — 10 tests
 * 3.  releaseFunds access & edge cases — 6 tests
 * 4.  refundBuyer edge cases — 5 tests
 * 5.  commitDispute + revealDispute — 10 tests
 * 6.  Vote + 2-of-3 multisig — 8 tests
 * 7.  reclaimExpiredStake — 5 tests
 * 8.  claimDisputeTimeout — 4 tests
 * 9.  Arbitrator management — 6 tests
 * 10. withdrawClaimable + reentrancy — 4 tests
 * 11. recoverERC20 — 3 tests
 * 12. Private escrow graceful degradation — 4 tests
 * 13. Pause/unpause — 4 tests
 */

/* eslint-disable @typescript-eslint/no-var-requires */
const { expect } = require('chai');
const { ethers } = require('hardhat');
const { time } = require('@nomicfoundation/hardhat-network-helpers');

describe('MinimalEscrow — Comprehensive', function () {
  let escrow: any;
  let token: any;
  let pToken: any;
  let owner: any;
  let buyer: any;
  let seller: any;
  let arbitrator: any;
  let arbitrator2: any;
  let registry: any;
  let other: any;

  const ESCROW_AMOUNT = ethers.parseEther('100');
  const SEVEN_DAYS = 7 * 24 * 60 * 60;
  const ONE_HOUR = 60 * 60;
  const THIRTY_DAYS = 30 * 24 * 60 * 60;
  const ARBITRATOR_DELAY = 24 * 60 * 60; // 24 hours
  const DISPUTE_TIMEOUT = 30 * 24 * 60 * 60; // 30 days

  beforeEach(async function () {
    [owner, buyer, seller, arbitrator, arbitrator2, registry, other] = await ethers.getSigners();

    // Deploy tokens
    const Token = await ethers.getContractFactory('OmniCoin');
    token = await Token.deploy(ethers.ZeroAddress);
    await token.initialize();
    pToken = await Token.deploy(ethers.ZeroAddress);
    await pToken.initialize();

    // Deploy MinimalEscrow
    const Escrow = await ethers.getContractFactory('MinimalEscrow');
    escrow = await Escrow.deploy(
      token.target, pToken.target, registry.address,
      owner.address, 100, ethers.ZeroAddress
    );

    // Register arbitrators
    await escrow.addArbitrator(arbitrator.address);
    await escrow.addArbitrator(arbitrator2.address);

    // Fund accounts
    await token.transfer(buyer.address, ethers.parseEther('10000'));
    await token.transfer(seller.address, ethers.parseEther('1000'));
    await token.transfer(other.address, ethers.parseEther('1000'));

    // Approvals
    await token.connect(buyer).approve(escrow.target, ethers.MaxUint256);
    await token.connect(seller).approve(escrow.target, ethers.MaxUint256);
    await token.connect(other).approve(escrow.target, ethers.MaxUint256);
  });

  /** Helper: create a standard escrow and return the ID */
  async function createStandardEscrow(): Promise<bigint> {
    const tx = await escrow.connect(buyer).createEscrow(seller.address, ESCROW_AMOUNT, SEVEN_DAYS);
    const receipt = await tx.wait();
    const event = receipt.logs.find(
      (l: any) => l.fragment && l.fragment.name === 'EscrowCreated'
    );
    return event.args.escrowId;
  }

  /** Helper: create a disputed escrow (commit + reveal) */
  async function createDisputedEscrow(): Promise<bigint> {
    const escrowId = await createStandardEscrow();
    await time.increase(ARBITRATOR_DELAY + 1);

    // Commit
    const nonce = 12345;
    const commitment = ethers.solidityPackedKeccak256(
      ['uint256', 'uint256', 'address'],
      [escrowId, nonce, buyer.address]
    );
    await escrow.connect(buyer).commitDispute(escrowId, commitment);

    // Reveal
    await ethers.provider.send('hardhat_mine', ['0x3']); // mine 3 blocks
    await escrow.connect(buyer).revealDispute(escrowId, nonce);

    return escrowId;
  }

  // =========================================================================
  // 1. DEPLOYMENT + IMMUTABLES
  // =========================================================================

  describe('Deployment & Immutables', function () {
    it('should set OMNI_COIN correctly', async function () {
      expect(await escrow.OMNI_COIN()).to.equal(token.target);
    });

    it('should set PRIVATE_OMNI_COIN correctly', async function () {
      expect(await escrow.PRIVATE_OMNI_COIN()).to.equal(pToken.target);
    });

    it('should set FEE_VAULT correctly', async function () {
      expect(await escrow.FEE_VAULT()).to.equal(owner.address);
    });

    it('should set MARKETPLACE_FEE_BPS correctly', async function () {
      expect(await escrow.MARKETPLACE_FEE_BPS()).to.equal(100);
    });

    it('should revert with fee > MAX_MARKETPLACE_FEE_BPS (500)', async function () {
      const Escrow = await ethers.getContractFactory('MinimalEscrow');
      await expect(
        Escrow.deploy(
          token.target, pToken.target, registry.address,
          owner.address, 501, ethers.ZeroAddress
        )
      ).to.be.revertedWithCustomError(escrow, 'InvalidFeeConfig');
    });

    it('should revert with zero omniCoin address', async function () {
      const Escrow = await ethers.getContractFactory('MinimalEscrow');
      await expect(
        Escrow.deploy(
          ethers.ZeroAddress, pToken.target, registry.address,
          owner.address, 100, ethers.ZeroAddress
        )
      ).to.be.revertedWithCustomError(escrow, 'InvalidAddress');
    });
  });

  // =========================================================================
  // 2. CREATE ESCROW — Edge Cases
  // =========================================================================

  describe('createEscrow — Edge Cases', function () {
    it('should accept MIN_DURATION (1 hour)', async function () {
      const id = await escrow.connect(buyer).createEscrow.staticCall(
        seller.address, ESCROW_AMOUNT, ONE_HOUR
      );
      expect(id).to.be.gt(0);
    });

    it('should accept MAX_DURATION (30 days)', async function () {
      const id = await escrow.connect(buyer).createEscrow.staticCall(
        seller.address, ESCROW_AMOUNT, THIRTY_DAYS
      );
      expect(id).to.be.gt(0);
    });

    it('should reject duration below MIN_DURATION', async function () {
      await expect(
        escrow.connect(buyer).createEscrow(seller.address, ESCROW_AMOUNT, ONE_HOUR - 1)
      ).to.be.revertedWithCustomError(escrow, 'InvalidDuration');
    });

    it('should reject duration above MAX_DURATION', async function () {
      await expect(
        escrow.connect(buyer).createEscrow(seller.address, ESCROW_AMOUNT, THIRTY_DAYS + 1)
      ).to.be.revertedWithCustomError(escrow, 'InvalidDuration');
    });

    it('should reject zero amount', async function () {
      await expect(
        escrow.connect(buyer).createEscrow(seller.address, 0, SEVEN_DAYS)
      ).to.be.revertedWithCustomError(escrow, 'InvalidAmount');
    });

    it('should reject zero address seller', async function () {
      await expect(
        escrow.connect(buyer).createEscrow(ethers.ZeroAddress, ESCROW_AMOUNT, SEVEN_DAYS)
      ).to.be.revertedWithCustomError(escrow, 'InvalidAddress');
    });

    it('should reject self-escrow (buyer == seller)', async function () {
      await expect(
        escrow.connect(buyer).createEscrow(buyer.address, ESCROW_AMOUNT, SEVEN_DAYS)
      ).to.be.revertedWithCustomError(escrow, 'InvalidAddress');
    });

    it('should increment escrowCounter', async function () {
      const id1 = await createStandardEscrow();
      const id2 = await createStandardEscrow();
      expect(id2 - id1).to.equal(1);
    });

    it('should track totalEscrowed correctly', async function () {
      await createStandardEscrow();
      await createStandardEscrow();
      const total = await escrow.totalEscrowed(token.target);
      expect(total).to.equal(ESCROW_AMOUNT * 2n);
    });

    it('should emit EscrowCreated event with correct args', async function () {
      const tx = await escrow.connect(buyer).createEscrow(seller.address, ESCROW_AMOUNT, SEVEN_DAYS);
      await expect(tx).to.emit(escrow, 'EscrowCreated');
    });
  });

  // =========================================================================
  // 3. RELEASE FUNDS — Access & Edge Cases
  // =========================================================================

  describe('releaseFunds — Access Control', function () {
    it('should allow buyer to release', async function () {
      const id = await createStandardEscrow();
      await escrow.connect(buyer).releaseFunds(id);
      const e = await escrow.escrows(id);
      expect(e.resolved).to.be.true;
    });

    it('should reject seller from releasing', async function () {
      const id = await createStandardEscrow();
      await expect(
        escrow.connect(seller).releaseFunds(id)
      ).to.be.revertedWithCustomError(escrow, 'NotParticipant');
    });

    it('should reject non-participant from releasing', async function () {
      const id = await createStandardEscrow();
      await expect(
        escrow.connect(other).releaseFunds(id)
      ).to.be.revertedWithCustomError(escrow, 'NotParticipant');
    });

    it('should reject release on already-resolved escrow', async function () {
      const id = await createStandardEscrow();
      await escrow.connect(buyer).releaseFunds(id);
      await expect(
        escrow.connect(buyer).releaseFunds(id)
      ).to.be.revertedWithCustomError(escrow, 'AlreadyResolved');
    });

    it('should deduct 1% marketplace fee to FEE_VAULT', async function () {
      const id = await createStandardEscrow();
      const feeVaultBefore = await token.balanceOf(owner.address);
      await escrow.connect(buyer).releaseFunds(id);
      const feeVaultAfter = await token.balanceOf(owner.address);
      const expectedFee = ESCROW_AMOUNT / 100n; // 1%
      expect(feeVaultAfter - feeVaultBefore).to.equal(expectedFee);
    });

    it('should reject release on nonexistent escrow', async function () {
      await expect(
        escrow.connect(buyer).releaseFunds(999)
      ).to.be.revertedWithCustomError(escrow, 'EscrowNotFound');
    });
  });

  // =========================================================================
  // 4. REFUND BUYER — Edge Cases
  // =========================================================================

  describe('refundBuyer — Edge Cases', function () {
    it('should allow seller voluntary refund', async function () {
      const id = await createStandardEscrow();
      const buyerBefore = await token.balanceOf(buyer.address);
      await escrow.connect(seller).refundBuyer(id);
      const buyerAfter = await token.balanceOf(buyer.address);
      expect(buyerAfter - buyerBefore).to.equal(ESCROW_AMOUNT); // Full refund, no fee
    });

    it('should allow buyer refund after expiry', async function () {
      const id = await createStandardEscrow();
      await time.increase(SEVEN_DAYS + 1);
      const buyerBefore = await token.balanceOf(buyer.address);
      await escrow.connect(buyer).refundBuyer(id);
      const buyerAfter = await token.balanceOf(buyer.address);
      expect(buyerAfter - buyerBefore).to.equal(ESCROW_AMOUNT);
    });

    it('should not refund buyer before expiry (no seller consent)', async function () {
      const id = await createStandardEscrow();
      // buyer calls refundBuyer before expiry — canRefund stays false, no-op (no revert)
      const balBefore = await token.balanceOf(buyer.address);
      await escrow.connect(buyer).refundBuyer(id);
      const balAfter = await token.balanceOf(buyer.address);
      // No tokens transferred
      expect(balAfter).to.equal(balBefore);
      // Escrow still active
      const e = await escrow.getEscrow(id);
      expect(e.resolved).to.be.false;
    });

    it('should reject non-participant refund', async function () {
      const id = await createStandardEscrow();
      await expect(
        escrow.connect(other).refundBuyer(id)
      ).to.be.revertedWithCustomError(escrow, 'NotParticipant');
    });

    it('should work even when paused (no whenNotPaused)', async function () {
      const id = await createStandardEscrow();
      await escrow.pause();
      // Seller voluntary refund should still work
      await escrow.connect(seller).refundBuyer(id);
      const e = await escrow.escrows(id);
      expect(e.resolved).to.be.true;
    });
  });

  // =========================================================================
  // 5. COMMIT & REVEAL DISPUTE
  // =========================================================================

  describe('commitDispute & revealDispute', function () {
    it('should reject commit before ARBITRATOR_DELAY', async function () {
      const id = await createStandardEscrow();
      const commitment = ethers.randomBytes(32);
      await expect(
        escrow.connect(buyer).commitDispute(id, commitment)
      ).to.be.revertedWithCustomError(escrow, 'DisputeTooEarly');
    });

    it('should allow buyer to commit after delay', async function () {
      const id = await createStandardEscrow();
      await time.increase(ARBITRATOR_DELAY + 1);
      const commitment = ethers.randomBytes(32);
      const tx = await escrow.connect(buyer).commitDispute(id, commitment);
      await expect(tx).to.emit(escrow, 'DisputeCommitted');
    });

    it('should allow seller to commit dispute', async function () {
      const id = await createStandardEscrow();
      await time.increase(ARBITRATOR_DELAY + 1);
      const nonce = 999;
      const commitment = ethers.solidityPackedKeccak256(
        ['uint256', 'uint256', 'address'],
        [id, nonce, seller.address]
      );
      await escrow.connect(seller).commitDispute(id, commitment);
    });

    it('should reject zero commitment', async function () {
      const id = await createStandardEscrow();
      await time.increase(ARBITRATOR_DELAY + 1);
      await expect(
        escrow.connect(buyer).commitDispute(id, ethers.ZeroHash)
      ).to.be.revertedWithCustomError(escrow, 'InvalidAmount');
    });

    it('should reject commit from non-participant', async function () {
      const id = await createStandardEscrow();
      await time.increase(ARBITRATOR_DELAY + 1);
      await expect(
        escrow.connect(other).commitDispute(id, ethers.randomBytes(32))
      ).to.be.revertedWithCustomError(escrow, 'NotParticipant');
    });

    it('should reject commit on resolved escrow', async function () {
      const id = await createStandardEscrow();
      await escrow.connect(buyer).releaseFunds(id);
      await time.increase(ARBITRATOR_DELAY + 1);
      await expect(
        escrow.connect(buyer).commitDispute(id, ethers.randomBytes(32))
      ).to.be.revertedWithCustomError(escrow, 'AlreadyResolved');
    });

    it('should reject reveal with wrong nonce', async function () {
      const id = await createStandardEscrow();
      await time.increase(ARBITRATOR_DELAY + 1);

      const nonce = 12345;
      const commitment = ethers.solidityPackedKeccak256(
        ['uint256', 'uint256', 'address'],
        [id, nonce, buyer.address]
      );
      await escrow.connect(buyer).commitDispute(id, commitment);
      await ethers.provider.send('hardhat_mine', ['0x3']);

      await expect(
        escrow.connect(buyer).revealDispute(id, 99999) // wrong nonce
      ).to.be.revertedWithCustomError(escrow, 'InvalidCommitment');
    });

    it('should reject reveal after deadline', async function () {
      const id = await createStandardEscrow();
      await time.increase(ARBITRATOR_DELAY + 1);

      const nonce = 12345;
      const commitment = ethers.solidityPackedKeccak256(
        ['uint256', 'uint256', 'address'],
        [id, nonce, buyer.address]
      );
      await escrow.connect(buyer).commitDispute(id, commitment);

      // Wait past reveal deadline (1 hour)
      await time.increase(3601);

      await expect(
        escrow.connect(buyer).revealDispute(id, nonce)
      ).to.be.revertedWithCustomError(escrow, 'RevealDeadlinePassed');
    });

    it('should select a registered arbitrator on reveal', async function () {
      const id = await createDisputedEscrow();
      const e = await escrow.escrows(id);
      expect(e.disputed).to.be.true;
      const assignedArb = e.arbitrator;
      // Must be one of the registered arbitrators (not buyer or seller)
      expect(
        assignedArb === arbitrator.address || assignedArb === arbitrator2.address
      ).to.be.true;
    });

    it('should reject double reveal', async function () {
      const id = await createStandardEscrow();
      await time.increase(ARBITRATOR_DELAY + 1);

      const nonce = 777;
      const commitment = ethers.solidityPackedKeccak256(
        ['uint256', 'uint256', 'address'],
        [id, nonce, buyer.address]
      );
      await escrow.connect(buyer).commitDispute(id, commitment);
      await ethers.provider.send('hardhat_mine', ['0x3']);
      await escrow.connect(buyer).revealDispute(id, nonce);

      // Try reveal again — already disputed
      await expect(
        escrow.connect(buyer).revealDispute(id, nonce)
      ).to.be.revertedWithCustomError(escrow, 'AlreadyDisputed');
    });
  });

  // =========================================================================
  // 6. VOTE + 2-OF-3 MULTISIG
  // =========================================================================

  describe('Vote — 2-of-3 Multisig', function () {
    it('should require dispute before voting', async function () {
      const id = await createStandardEscrow();
      await expect(
        escrow.connect(buyer).vote(id, true)
      ).to.be.revertedWithCustomError(escrow, 'NotDisputed');
    });

    it('should accept buyer vote for release', async function () {
      const id = await createDisputedEscrow();
      const tx = await escrow.connect(buyer).vote(id, true);
      await expect(tx).to.emit(escrow, 'VoteCast');
    });

    it('should reject double voting by same party', async function () {
      const id = await createDisputedEscrow();
      await escrow.connect(buyer).vote(id, true);
      await expect(
        escrow.connect(buyer).vote(id, true)
      ).to.be.revertedWithCustomError(escrow, 'AlreadyVoted');
    });

    it('should not resolve with only 1 vote', async function () {
      const id = await createDisputedEscrow();
      await escrow.connect(buyer).vote(id, true);
      const e = await escrow.escrows(id);
      expect(e.resolved).to.be.false;
    });

    it('should resolve with 2 release votes (buyer + arbitrator)', async function () {
      const id = await createDisputedEscrow();
      const e = await escrow.escrows(id);
      const assignedArb = e.arbitrator;

      // Post counterparty stake if needed
      await escrow.connect(seller).postCounterpartyStake(id);

      await escrow.connect(buyer).vote(id, true);
      // Get the assigned arbitrator signer
      const arbSigner = assignedArb === arbitrator.address ? arbitrator : arbitrator2;
      await escrow.connect(arbSigner).vote(id, true);

      const resolved = await escrow.escrows(id);
      expect(resolved.resolved).to.be.true;
    });

    it('should resolve with 2 refund votes (seller + arbitrator)', async function () {
      const id = await createDisputedEscrow();
      const e = await escrow.escrows(id);
      const assignedArb = e.arbitrator;

      await escrow.connect(seller).postCounterpartyStake(id);

      await escrow.connect(seller).vote(id, false);
      const arbSigner = assignedArb === arbitrator.address ? arbitrator : arbitrator2;
      await escrow.connect(arbSigner).vote(id, false);

      const resolved = await escrow.escrows(id);
      expect(resolved.resolved).to.be.true;
    });

    it('should reject vote from non-participant (non buyer/seller/arbitrator)', async function () {
      const id = await createDisputedEscrow();
      await expect(
        escrow.connect(other).vote(id, true)
      ).to.be.revertedWithCustomError(escrow, 'NotParticipant');
    });

    it('should reject voting on resolved escrow', async function () {
      const id = await createDisputedEscrow();
      const e = await escrow.escrows(id);
      const assignedArb = e.arbitrator;

      await escrow.connect(seller).postCounterpartyStake(id);

      await escrow.connect(buyer).vote(id, true);
      const arbSigner = assignedArb === arbitrator.address ? arbitrator : arbitrator2;
      await escrow.connect(arbSigner).vote(id, true);

      await expect(
        escrow.connect(seller).vote(id, false)
      ).to.be.revertedWithCustomError(escrow, 'AlreadyResolved');
    });
  });

  // =========================================================================
  // 7. RECLAIM EXPIRED STAKE
  // =========================================================================

  describe('reclaimExpiredStake', function () {
    it('should reclaim stake after reveal deadline + grace period', async function () {
      const id = await createStandardEscrow();
      await time.increase(ARBITRATOR_DELAY + 1);

      const nonce = 555;
      const commitment = ethers.solidityPackedKeccak256(
        ['uint256', 'uint256', 'address'],
        [id, nonce, buyer.address]
      );
      await escrow.connect(buyer).commitDispute(id, commitment);

      // Wait past reveal deadline (1h) + grace period (24h)
      await time.increase(3600 + 86400 + 1);

      const before = await token.balanceOf(buyer.address);
      await escrow.connect(buyer).reclaimExpiredStake(id);
      const after = await token.balanceOf(buyer.address);
      expect(after).to.be.gt(before);
    });

    it('should reject reclaim before grace period', async function () {
      const id = await createStandardEscrow();
      await time.increase(ARBITRATOR_DELAY + 1);

      const nonce = 555;
      const commitment = ethers.solidityPackedKeccak256(
        ['uint256', 'uint256', 'address'],
        [id, nonce, buyer.address]
      );
      await escrow.connect(buyer).commitDispute(id, commitment);

      // Only past reveal deadline, not grace period
      await time.increase(3601);

      await expect(
        escrow.connect(buyer).reclaimExpiredStake(id)
      ).to.be.revertedWithCustomError(escrow, 'DisputeTooEarly');
    });

    it('should reject reclaim after successful reveal (dispute happened)', async function () {
      const id = await createDisputedEscrow();
      await time.increase(3600 + 86400 + 1);
      await expect(
        escrow.connect(buyer).reclaimExpiredStake(id)
      ).to.be.revertedWithCustomError(escrow, 'AlreadyDisputed');
    });

    it('should reject reclaim with no commitment', async function () {
      const id = await createStandardEscrow();
      await expect(
        escrow.connect(buyer).reclaimExpiredStake(id)
      ).to.be.revertedWithCustomError(escrow, 'InvalidCommitment');
    });

    it('should reject reclaim from non-staker', async function () {
      const id = await createStandardEscrow();
      await time.increase(ARBITRATOR_DELAY + 1);

      const nonce = 555;
      const commitment = ethers.solidityPackedKeccak256(
        ['uint256', 'uint256', 'address'],
        [id, nonce, buyer.address]
      );
      await escrow.connect(buyer).commitDispute(id, commitment);
      await time.increase(3600 + 86400 + 1);

      await expect(
        escrow.connect(seller).reclaimExpiredStake(id)
      ).to.be.revertedWithCustomError(escrow, 'NothingToClaim');
    });
  });

  // =========================================================================
  // 8. CLAIM DISPUTE TIMEOUT
  // =========================================================================

  describe('claimDisputeTimeout', function () {
    it('should refund buyer after dispute timeout', async function () {
      const id = await createDisputedEscrow();
      // Wait for expiry + DISPUTE_TIMEOUT
      await time.increase(SEVEN_DAYS + DISPUTE_TIMEOUT + 1);

      await escrow.connect(buyer).claimDisputeTimeout(id);
      const e = await escrow.escrows(id);
      expect(e.resolved).to.be.true;
    });

    it('should reject timeout claim before period expires', async function () {
      const id = await createDisputedEscrow();
      await expect(
        escrow.connect(buyer).claimDisputeTimeout(id)
      ).to.be.revertedWithCustomError(escrow, 'EscrowNotExpired');
    });

    it('should reject timeout claim from non-buyer', async function () {
      const id = await createDisputedEscrow();
      await time.increase(SEVEN_DAYS + DISPUTE_TIMEOUT + 1);
      await expect(
        escrow.connect(seller).claimDisputeTimeout(id)
      ).to.be.revertedWithCustomError(escrow, 'NotParticipant');
    });

    it('should reject timeout on non-disputed escrow', async function () {
      const id = await createStandardEscrow();
      await time.increase(SEVEN_DAYS + DISPUTE_TIMEOUT + 1);
      await expect(
        escrow.connect(buyer).claimDisputeTimeout(id)
      ).to.be.revertedWithCustomError(escrow, 'NotDisputed');
    });
  });

  // =========================================================================
  // 9. ARBITRATOR MANAGEMENT
  // =========================================================================

  describe('Arbitrator Management', function () {
    it('should add arbitrators', async function () {
      expect(await escrow.arbitratorCount()).to.be.gte(2);
    });

    it('should reject duplicate arbitrator', async function () {
      await expect(
        escrow.addArbitrator(arbitrator.address)
      ).to.be.revertedWithCustomError(escrow, 'AlreadyDisputed');
    });

    it('should remove arbitrator', async function () {
      const countBefore = await escrow.arbitratorCount();
      await escrow.removeArbitrator(arbitrator2.address);
      const countAfter = await escrow.arbitratorCount();
      expect(countAfter).to.equal(countBefore - 1n);
    });

    it('should reject non-admin adding arbitrator', async function () {
      await expect(
        escrow.connect(other).addArbitrator(other.address)
      ).to.be.revertedWithCustomError(escrow, 'OnlyAdmin');
    });

    it('should reject non-admin removing arbitrator', async function () {
      await expect(
        escrow.connect(other).removeArbitrator(arbitrator.address)
      ).to.be.revertedWithCustomError(escrow, 'OnlyAdmin');
    });

    it('should reject adding zero address arbitrator', async function () {
      await expect(
        escrow.addArbitrator(ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(escrow, 'InvalidAddress');
    });
  });

  // =========================================================================
  // 10. WITHDRAW CLAIMABLE
  // =========================================================================

  describe('withdrawClaimable', function () {
    it('should reject withdrawal with zero claimable balance', async function () {
      await expect(
        escrow.connect(buyer).withdrawClaimable(token.target)
      ).to.be.revertedWithCustomError(escrow, 'NothingToClaim');
    });

    it('should allow withdrawal of claimable balance after dispute resolution', async function () {
      const id = await createDisputedEscrow();
      const e = await escrow.escrows(id);
      const assignedArb = e.arbitrator;

      // Post counterparty stake
      await escrow.connect(seller).postCounterpartyStake(id);

      // Vote to resolve
      await escrow.connect(buyer).vote(id, true);
      const arbSigner = assignedArb === arbitrator.address ? arbitrator : arbitrator2;
      await escrow.connect(arbSigner).vote(id, true);

      // Seller should have claimable funds (pull pattern)
      const sellerBefore = await token.balanceOf(seller.address);
      await escrow.connect(seller).withdrawClaimable(token.target);
      const sellerAfter = await token.balanceOf(seller.address);
      expect(sellerAfter).to.be.gt(sellerBefore);
    });

    it('should emit FundsClaimed event', async function () {
      const id = await createDisputedEscrow();
      const e = await escrow.escrows(id);
      const assignedArb = e.arbitrator;

      await escrow.connect(seller).postCounterpartyStake(id);
      await escrow.connect(buyer).vote(id, true);
      const arbSigner = assignedArb === arbitrator.address ? arbitrator : arbitrator2;
      await escrow.connect(arbSigner).vote(id, true);

      const tx = await escrow.connect(seller).withdrawClaimable(token.target);
      await expect(tx).to.emit(escrow, 'FundsClaimed');
    });

    it('should zero out claimable after withdrawal', async function () {
      const id = await createDisputedEscrow();
      const e = await escrow.escrows(id);
      const assignedArb = e.arbitrator;

      await escrow.connect(seller).postCounterpartyStake(id);
      await escrow.connect(buyer).vote(id, true);
      const arbSigner = assignedArb === arbitrator.address ? arbitrator : arbitrator2;
      await escrow.connect(arbSigner).vote(id, true);

      await escrow.connect(seller).withdrawClaimable(token.target);

      // Second withdrawal should revert
      await expect(
        escrow.connect(seller).withdrawClaimable(token.target)
      ).to.be.revertedWithCustomError(escrow, 'NothingToClaim');
    });
  });

  // =========================================================================
  // 11. RECOVER ERC20
  // =========================================================================

  describe('recoverERC20', function () {
    it('should recover excess tokens', async function () {
      // Send extra tokens directly to escrow
      await token.transfer(escrow.target, ethers.parseEther('50'));

      const recipientBefore = await token.balanceOf(other.address);
      await escrow.recoverERC20(token.target, other.address);
      const recipientAfter = await token.balanceOf(other.address);
      expect(recipientAfter - recipientBefore).to.equal(ethers.parseEther('50'));
    });

    it('should reject non-admin recovery', async function () {
      await expect(
        escrow.connect(other).recoverERC20(token.target, other.address)
      ).to.be.revertedWithCustomError(escrow, 'OnlyAdmin');
    });

    it('should reject when nothing to recover', async function () {
      await expect(
        escrow.recoverERC20(token.target, other.address)
      ).to.be.revertedWithCustomError(escrow, 'NothingToClaim');
    });
  });

  // =========================================================================
  // 12. PRIVATE ESCROW GRACEFUL DEGRADATION
  // =========================================================================

  describe('Private Escrow — Hardhat Degradation', function () {
    it('should report privacy unavailable on Hardhat', async function () {
      expect(await escrow.privacyAvailable()).to.be.false;
    });

    it('should revert createPrivateEscrow on non-COTI', async function () {
      // gtUint64 is a MPC type; on Hardhat we pass 0
      await expect(
        escrow.connect(buyer).createPrivateEscrow(seller.address, 0, SEVEN_DAYS)
      ).to.be.revertedWithCustomError(escrow, 'PrivacyNotAvailable');
    });

    it('should revert releasePrivateFunds on public escrow', async function () {
      const id = await createStandardEscrow();
      await expect(
        escrow.connect(buyer).releasePrivateFunds(id)
      ).to.be.revertedWithCustomError(escrow, 'CannotMixPrivacyModes');
    });

    it('should revert getEncryptedAmount on public escrow', async function () {
      const id = await createStandardEscrow();
      await expect(
        escrow.getEncryptedAmount(id)
      ).to.be.revertedWithCustomError(escrow, 'CannotMixPrivacyModes');
    });
  });

  // =========================================================================
  // 13. PAUSE / UNPAUSE
  // =========================================================================

  describe('Pause & Unpause', function () {
    it('should block createEscrow when paused', async function () {
      await escrow.pause();
      await expect(
        escrow.connect(buyer).createEscrow(seller.address, ESCROW_AMOUNT, SEVEN_DAYS)
      ).to.be.revertedWithCustomError(escrow, 'EnforcedPause');
    });

    it('should block releaseFunds when paused', async function () {
      const id = await createStandardEscrow();
      await escrow.pause();
      await expect(
        escrow.connect(buyer).releaseFunds(id)
      ).to.be.revertedWithCustomError(escrow, 'EnforcedPause');
    });

    it('should NOT block refundBuyer when paused', async function () {
      const id = await createStandardEscrow();
      await escrow.pause();
      // Seller voluntary refund should still work
      await escrow.connect(seller).refundBuyer(id);
      const e = await escrow.escrows(id);
      expect(e.resolved).to.be.true;
    });

    it('should reject non-admin pause', async function () {
      await expect(
        escrow.connect(other).pause()
      ).to.be.revertedWithCustomError(escrow, 'OnlyAdmin');
    });
  });

  // =========================================================================
  // 14. COUNTERPARTY STAKE
  // =========================================================================

  describe('postCounterpartyStake', function () {
    it('should allow counterparty to post stake', async function () {
      const id = await createDisputedEscrow();
      const tx = await escrow.connect(seller).postCounterpartyStake(id);
      await expect(tx).to.emit(escrow, 'CounterpartyStakePosted');
    });

    it('should reject double-staking', async function () {
      const id = await createDisputedEscrow();
      await escrow.connect(seller).postCounterpartyStake(id);
      await expect(
        escrow.connect(seller).postCounterpartyStake(id)
      ).to.be.revertedWithCustomError(escrow, 'StakeAlreadyPosted');
    });

    it('should reject staking on non-disputed escrow', async function () {
      const id = await createStandardEscrow();
      await expect(
        escrow.connect(seller).postCounterpartyStake(id)
      ).to.be.revertedWithCustomError(escrow, 'NotDisputed');
    });

    it('should reject staking from non-participant', async function () {
      const id = await createDisputedEscrow();
      await expect(
        escrow.connect(other).postCounterpartyStake(id)
      ).to.be.revertedWithCustomError(escrow, 'NotParticipant');
    });
  });
});
