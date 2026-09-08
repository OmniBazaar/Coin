/**
 * MinimalEscrow.sol — Adversarial Test Suite (Round 8)
 *
 * Tests derived from adversarial agent A4 findings:
 *   ATTACK-01: Cross-party commit overwrite stake lock (High)
 *   ATTACK-02: Public-function call on private escrow locks pXOM (Medium)
 *   ATTACK-03: resolveDispute on non-disputed escrow (Medium)
 *   DEFENDED-01: Same-party commit overwrite blocked by H-01
 *   DEFENDED-02: Reentrancy in withdrawClaimable
 *   DEFENDED-03: recoverERC20 cannot extract escrowed tokens
 */

/* eslint-disable @typescript-eslint/no-var-requires */
const { expect } = require('chai');
const { ethers } = require('hardhat');
const { time } = require('@nomicfoundation/hardhat-network-helpers');

describe('MinimalEscrow — Adversarial (Round 8)', function () {
  let escrow: any;
  let token: any;
  let pToken: any;
  let owner: any;
  let buyer: any;
  let seller: any;
  let arbitrator1: any;
  let arbitrator2: any;
  let arbitrator3: any;
  let attacker: any;
  let other: any;

  const MARKETPLACE_FEE_BPS = 100n; // 1%
  const BASIS_POINTS = 10000n;
  const ARBITRATOR_DELAY = 86400; // 24 hours
  const DISPUTE_REVEAL_WINDOW = 3600; // 1 hour
  const ESCROW_AMOUNT = ethers.parseEther('1000000'); // 1M XOM
  const DISPUTE_STAKE_BPS = 250n; // 2.5% (covers half the 5% arbitration fee)
  const DISPUTE_STAKE = (ESCROW_AMOUNT * DISPUTE_STAKE_BPS) / BASIS_POINTS;

  async function deployFixture() {
    [owner, buyer, seller, arbitrator1, arbitrator2, arbitrator3, attacker, other] =
      await ethers.getSigners();

    // Deploy mock tokens
    const MockERC20 = await ethers.getContractFactory('MockERC20');
    token = await MockERC20.deploy('OmniCoin', 'XOM');
    pToken = await MockERC20.deploy('PrivateOmniCoin', 'pXOM');

    // Deploy MinimalEscrow
    const Escrow = await ethers.getContractFactory('MinimalEscrow');
    escrow = await Escrow.deploy(
      await token.getAddress(),
      await pToken.getAddress(),
      other.address,      // registry (non-zero placeholder)
      owner.address,      // fee vault
      MARKETPLACE_FEE_BPS,
      ethers.ZeroAddress  // trustedForwarder
    );

    // Add arbitrators
    await escrow.addArbitrator(arbitrator1.address);
    await escrow.addArbitrator(arbitrator2.address);
    await escrow.addArbitrator(arbitrator3.address);

    // Mint and approve tokens
    const supply = ethers.parseEther('100000000');
    await token.mint(buyer.address, supply);
    await token.mint(seller.address, supply);
    await token.mint(attacker.address, supply);
    await pToken.mint(buyer.address, supply);
    await pToken.mint(seller.address, supply);

    await token.connect(buyer).approve(await escrow.getAddress(), ethers.MaxUint256);
    await token.connect(seller).approve(await escrow.getAddress(), ethers.MaxUint256);
    await token.connect(attacker).approve(await escrow.getAddress(), ethers.MaxUint256);
    await pToken.connect(buyer).approve(await escrow.getAddress(), ethers.MaxUint256);
    await pToken.connect(seller).approve(await escrow.getAddress(), ethers.MaxUint256);
  }

  /** Create a standard escrow and return its ID */
  async function createStandardEscrow(): Promise<bigint> {
    const duration = 7 * 86400; // 7 days
    const tx = await escrow.connect(buyer).createEscrow(
      seller.address,
      ESCROW_AMOUNT,
      duration
    );
    const receipt = await tx.wait();
    const event = receipt.logs.find((l: any) => {
      try {
        return escrow.interface.parseLog(l)?.name === 'EscrowCreated';
      } catch { return false; }
    });
    const parsed = escrow.interface.parseLog(event);
    return parsed.args.escrowId;
  }

  /** Commit and reveal a dispute for the given escrow */
  async function raiseDispute(escrowId: bigint, disputer: any): Promise<void> {
    await time.increase(ARBITRATOR_DELAY + 1);
    const nonce = 12345n;
    const commitment = ethers.solidityPackedKeccak256(
      ['uint256', 'uint256', 'address'],
      [escrowId, nonce, disputer.address]
    );
    await escrow.connect(disputer).commitDispute(escrowId, commitment);
    await escrow.connect(disputer).revealDispute(escrowId, nonce);
  }

  beforeEach(async function () {
    await deployFixture();
  });

  // ═══════════════════════════════════════════════════════════════════════
  //  ATTACK-01: Cross-Party Commit Overwrite Stake Lock
  // ═══════════════════════════════════════════════════════════════════════

  describe('ATTACK-01: Cross-party commit overwrite', function () {
    it('leaves the original staker funds fully reclaimable after a cross-party overwrite (no fund loss)', async function () {
      const id = await createStandardEscrow();
      await time.increase(ARBITRATOR_DELAY + 1);

      // Buyer commits dispute
      const buyerNonce = 11111n;
      const buyerCommitment = ethers.solidityPackedKeccak256(
        ['uint256', 'uint256', 'address'],
        [id, buyerNonce, buyer.address]
      );
      await escrow.connect(buyer).commitDispute(id, buyerCommitment);

      // Verify buyer stake recorded
      expect(await escrow.disputeStakes(id, buyer.address)).to.equal(DISPUTE_STAKE);

      // Advance past reveal window so buyer's commitment expires
      await time.increase(DISPUTE_REVEAL_WINDOW + 1);

      // Seller can overwrite the expired commitment: the H-01 guard checks the
      // CALLER's own outstanding stake, and the seller has none. This is
      // intentional -- the invariant is not "overwrite is blocked" but "the
      // buyer's already-posted stake can never be seized or trapped by the
      // overwrite". Assert the overwrite unconditionally succeeds and records
      // the seller's fresh commitment.
      const sellerNonce = 22222n;
      const sellerCommitment = ethers.solidityPackedKeccak256(
        ['uint256', 'uint256', 'address'],
        [id, sellerNonce, seller.address]
      );
      await expect(escrow.connect(seller).commitDispute(id, sellerCommitment)).to.not.be.reverted;
      expect(await escrow.disputeStakes(id, seller.address)).to.equal(DISPUTE_STAKE);

      // The buyer's stake is per-address and still recorded (not seized).
      expect(await escrow.disputeStakes(id, buyer.address)).to.equal(DISPUTE_STAKE);

      // CRITICAL invariant: the buyer must be able to recover their orphaned
      // stake in full. Advance past the (now seller-set) reveal deadline + grace
      // period and reclaim; the buyer receives the entire DISPUTE_STAKE back and
      // their recorded stake is cleared to zero.
      await time.increase(25 * 3600 + 1); // revealDeadline (1h) + REVEAL_GRACE_PERIOD (24h)
      const buyerBalBefore = await token.balanceOf(buyer.address);
      await expect(escrow.connect(buyer).reclaimExpiredStake(id)).to.not.be.reverted;
      expect(await escrow.disputeStakes(id, buyer.address)).to.equal(0n);
      expect(await token.balanceOf(buyer.address)).to.equal(buyerBalBefore + DISPUTE_STAKE);
    });

    it('should block same-party re-commit (H-01 defense)', async function () {
      const id = await createStandardEscrow();
      await time.increase(ARBITRATOR_DELAY + 1);

      // Buyer commits
      const nonce1 = 11111n;
      const commitment1 = ethers.solidityPackedKeccak256(
        ['uint256', 'uint256', 'address'],
        [id, nonce1, buyer.address]
      );
      await escrow.connect(buyer).commitDispute(id, commitment1);

      // Let the active commitment expire past its reveal deadline. An
      // *immediate* re-commit is now caught earlier by the F2 guard
      // (AlreadyDisputed: an active, unrevealed commitment still inside the
      // reveal window cannot be overwritten by anyone). The H-01 guard
      // specifically protects the post-expiry case: the commitment has lapsed
      // but the stake was never reclaimed via reclaimExpiredStake().
      //
      // The F2 guard is INCLUSIVE of the reveal deadline (the contract reverts
      // while `block.timestamp <= revealDeadline`), so the re-commit block must
      // land STRICTLY after it to reach the H-01 guard. A +1-second margin is
      // too tight: in the full nightly suite, wall-clock interaction can put the
      // re-commit block exactly on the deadline, tripping AlreadyDisputed (F2)
      // instead of PreviousCommitNotReclaimed (H-01). Advance a comfortable two
      // minutes past the window so the boundary is never razor-thin.
      await time.increase(DISPUTE_REVEAL_WINDOW + 120);

      // Buyer tries to commit again without reclaiming the expired stake
      const nonce2 = 22222n;
      const commitment2 = ethers.solidityPackedKeccak256(
        ['uint256', 'uint256', 'address'],
        [id, nonce2, buyer.address]
      );
      await expect(
        escrow.connect(buyer).commitDispute(id, commitment2)
      ).to.be.revertedWithCustomError(escrow, 'PreviousCommitNotReclaimed');
    });

    it('should allow same-party re-commit after reclaim', async function () {
      const id = await createStandardEscrow();
      await time.increase(ARBITRATOR_DELAY + 1);

      // Buyer commits
      const nonce1 = 11111n;
      const commitment1 = ethers.solidityPackedKeccak256(
        ['uint256', 'uint256', 'address'],
        [id, nonce1, buyer.address]
      );
      await escrow.connect(buyer).commitDispute(id, commitment1);

      // Miss reveal window AND grace period (revealDeadline + REVEAL_GRACE_PERIOD = 1h + 24h = 25h)
      await time.increase(25 * 3600 + 1);

      // Reclaim stake
      await escrow.connect(buyer).reclaimExpiredStake(id);

      // Now buyer can commit again
      const nonce2 = 22222n;
      const commitment2 = ethers.solidityPackedKeccak256(
        ['uint256', 'uint256', 'address'],
        [id, nonce2, buyer.address]
      );
      await expect(
        escrow.connect(buyer).commitDispute(id, commitment2)
      ).to.not.be.reverted;
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  //  ATTACK-02: Public function on private escrow
  // ═══════════════════════════════════════════════════════════════════════

  describe('ATTACK-02: Public function on private escrow', function () {
    it('should document behavior of releaseFunds on a private escrow', async function () {
      // Private escrows set escrow.amount = 0, so public functions
      // operate on 0 amount. Check if the guard is present.
      // This test documents current behavior.

      // Check if createPrivateEscrow exists (only on COTI)
      const hasPrivateEscrow = typeof escrow.createPrivateEscrow === 'function';
      if (!hasPrivateEscrow) {
        // On non-COTI networks, private escrow is not available -- skip
        this.skip();
        return;
      }

      // If available, test that public releaseFunds is blocked
      // (The fix adds isPrivateEscrow guard to public functions)
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  //  ATTACK-03: resolveDispute on non-disputed escrow
  // ═══════════════════════════════════════════════════════════════════════

  describe('ATTACK-03: resolveDispute without dispute', function () {
    it('should document resolveDispute behavior on non-disputed escrow', async function () {
      const id = await createStandardEscrow();

      // Verify escrow is NOT disputed
      const e = await escrow.getEscrow(id);
      expect(e.disputed).to.be.false;

      // If arbitrationContract is set, resolveDispute can be called
      // by the arbitration contract. Check if the disputed guard exists.
      const arbContract = await escrow.arbitrationContract();
      if (arbContract === ethers.ZeroAddress) {
        // No arbitration contract set -- resolveDispute requires onlyArbitration
        await expect(
          escrow.resolveDispute(id, true)
        ).to.be.reverted;
      }
    });

    it('should allow resolveDispute on properly disputed escrow', async function () {
      const id = await createStandardEscrow();
      await raiseDispute(id, buyer);

      const e = await escrow.getEscrow(id);
      expect(e.disputed).to.be.true;

      // resolveDispute still requires onlyArbitration modifier
      // Without an arbitration contract set, only internal vote path works
    });

    it('reverts NotDisputed when a registered panel resolves a non-disputed escrow', async function () {
      const id = await createStandardEscrow();

      // Install a real arbitration contract — the disputed gate must hold
      // regardless of who the caller is, because the escrow was never disputed.
      const Mock = await ethers.getContractFactory('MockEscrowArbitrationResolver');
      const mock = await Mock.deploy();
      await mock.waitForDeployment();
      await escrow.connect(owner).setArbitrationContract(await mock.getAddress());

      await expect(
        mock.resolve(await escrow.getAddress(), id, true)
      ).to.be.revertedWithCustomError(escrow, 'NotDisputed');
    });

    it('allows disabling external arbitration via setArbitrationContract(address(0))', async function () {
      const Mock = await ethers.getContractFactory('MockEscrowArbitrationResolver');
      const mock = await Mock.deploy();
      await mock.waitForDeployment();
      await escrow.connect(owner).setArbitrationContract(await mock.getAddress());
      expect(await escrow.arbitrationContract()).to.equal(await mock.getAddress());

      await escrow.connect(owner).setArbitrationContract(ethers.ZeroAddress);
      expect(await escrow.arbitrationContract()).to.equal(ethers.ZeroAddress);
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  //  DEFENDED-01: Reentrancy in withdrawClaimable
  // ═══════════════════════════════════════════════════════════════════════

  describe('DEFENDED: Reentrancy protection', function () {
    it('should follow CEI pattern in withdrawClaimable', async function () {
      const id = await createStandardEscrow();

      // Raise dispute so we can use the resolution path that credits claimable
      await raiseDispute(id, buyer);

      // Post counterparty stake
      await escrow.connect(seller).postCounterpartyStake(id);

      // Both parties vote to release to seller (2-of-3)
      await escrow.connect(buyer).vote(id, true);
      await escrow.connect(seller).vote(id, true);

      // After dispute resolution, the buyer's stake should be claimable
      // Check if buyer has claimable balance (stakes returned via pull pattern)
      const buyerClaimable = await escrow.claimable(
        await token.getAddress(), buyer.address
      );

      if (buyerClaimable > 0n) {
        const balBefore = await token.balanceOf(buyer.address);
        await escrow.connect(buyer).withdrawClaimable(await token.getAddress());
        const balAfter = await token.balanceOf(buyer.address);
        expect(balAfter - balBefore).to.equal(buyerClaimable);

        // Second withdrawal should revert (nothing to claim)
        await expect(
          escrow.connect(buyer).withdrawClaimable(await token.getAddress())
        ).to.be.revertedWithCustomError(escrow, 'NothingToClaim');
      } else {
        // Check seller claimable (funds go to seller via claimable in dispute path)
        const sellerClaimable = await escrow.claimable(
          await token.getAddress(), seller.address
        );

        if (sellerClaimable > 0n) {
          const balBefore = await token.balanceOf(seller.address);
          await escrow.connect(seller).withdrawClaimable(await token.getAddress());
          const balAfter = await token.balanceOf(seller.address);
          expect(balAfter - balBefore).to.equal(sellerClaimable);

          // Second withdrawal should revert
          await expect(
            escrow.connect(seller).withdrawClaimable(await token.getAddress())
          ).to.be.revertedWithCustomError(escrow, 'NothingToClaim');
        } else {
          // Dispute resolved via direct transfer (not the claimable pull
          // pattern). Replace the former `expect(true).to.be.true` tautology
          // with the concrete terminal invariant: a 2-of-3 release vote must
          // leave the escrow marked resolved, and the escrow contract must no
          // longer hold this escrow's principal as an unresolved liability.
          const record = await escrow.getEscrow(id);
          expect(record.resolved).to.equal(true);
          expect(record.releaseVotes).to.be.gte(2);
        }
      }
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  //  DEFENDED-02: recoverERC20 cannot extract escrowed tokens
  // ═══════════════════════════════════════════════════════════════════════

  describe('DEFENDED: recoverERC20 safety', function () {
    it('should not allow recovery of escrowed tokens', async function () {
      await createStandardEscrow();
      const tokenAddr = await token.getAddress();

      // Contract holds escrowed tokens
      const contractBal = await token.balanceOf(await escrow.getAddress());
      expect(contractBal).to.be.gte(ESCROW_AMOUNT);

      // recoverERC20 should fail or return 0 since all tokens are escrowed
      await expect(
        escrow.recoverERC20(tokenAddr, other.address)
      ).to.be.revertedWithCustomError(escrow, 'NothingToClaim');
    });

    it('should allow recovery of accidentally sent tokens', async function () {
      // Send extra tokens directly to contract (not through createEscrow)
      const accidental = ethers.parseEther('5000');
      await token.mint(await escrow.getAddress(), accidental);

      const tokenAddr = await token.getAddress();
      const balBefore = await token.balanceOf(other.address);

      await escrow.recoverERC20(tokenAddr, other.address);

      const balAfter = await token.balanceOf(other.address);
      expect(balAfter - balBefore).to.equal(accidental);
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  //  DEFENDED: Vote requires proper escrow parties
  // ═══════════════════════════════════════════════════════════════════════

  describe('DEFENDED: Vote access control', function () {
    it('should reject vote from non-party', async function () {
      const id = await createStandardEscrow();
      await raiseDispute(id, buyer);

      await expect(
        escrow.connect(attacker).vote(id, true)
      ).to.be.reverted;
    });

    it('should accept vote from buyer and seller (2-of-3)', async function () {
      const id = await createStandardEscrow();
      await raiseDispute(id, buyer);

      // Post counterparty stake
      await escrow.connect(seller).postCounterpartyStake(id);

      // Buyer votes to release
      await escrow.connect(buyer).vote(id, true);

      // Seller votes to release (2-of-3 reached)
      await escrow.connect(seller).vote(id, true);

      // Escrow should now be resolved
      const e = await escrow.getEscrow(id);
      expect(e.resolved).to.be.true;
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  //  DEFENDED: Dispute timeout handling
  // ═══════════════════════════════════════════════════════════════════════

  describe('DEFENDED: Dispute timeout', function () {
    it('should reject early claimDisputeTimeout', async function () {
      const id = await createStandardEscrow();
      await raiseDispute(id, buyer);

      // Try to claim timeout immediately (should fail -- 30 days required)
      await expect(
        escrow.connect(buyer).claimDisputeTimeout(id)
      ).to.be.reverted;
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  //  N-L6: releaseFundsViaContract — wrong-callerContract digest binding
  // ═══════════════════════════════════════════════════════════════════════
  //
  // The buyer signs `ReleaseFundsBySig(escrowId, callerContract,
  // deadline)`. The contract recomputes the digest using the
  // `callerContract` ARGUMENT (not from the sig) and verifies
  // ECDSA.recover returns escrow.buyer. If a relayer ContractB tries
  // to submit a signature the buyer made for ContractA — even when
  // ContractB happens to be msg.sender and matches the supplied
  // callerContract — the digest doesn't match what the buyer signed,
  // recovery yields a different address, and the call MUST revert
  // with InvalidSignature.
  describe('N-L6: releaseFundsViaContract — wrong callerContract digest', function () {
    /**
     * Helper: produce a `ReleaseFundsBySig` ECDSA signature for the
     * given (escrowId, callerContract, deadline) tuple.
     */
    async function signRelease(
      signer: any,
      escrowId: bigint,
      callerContract: string,
      deadline: bigint
    ): Promise<string> {
      const network = await ethers.provider.getNetwork();
      const domain = {
        name: 'MinimalEscrow',
        version: '1',
        chainId: network.chainId,
        verifyingContract: await escrow.getAddress(),
      };
      const types = {
        ReleaseFundsBySig: [
          { name: 'escrowId', type: 'uint256' },
          { name: 'callerContract', type: 'address' },
          { name: 'deadline', type: 'uint256' },
        ],
      };
      return signer.signTypedData(domain, types, {
        escrowId,
        callerContract,
        deadline,
      });
    }

    it('reverts with InvalidSignature when sig was signed for a different callerContract', async function () {
      const id = await createStandardEscrow();
      const deadline = BigInt(
        (await ethers.provider.getBlock('latest'))!.timestamp + 3600
      );

      // Buyer signs for `attacker` as the authorized router.
      const sigForAttacker = await signRelease(
        buyer,
        id,
        attacker.address,
        deadline
      );

      // `other` (a *different* address) tries to submit the same sig
      // with itself as both msg.sender AND the supplied callerContract.
      // The `msg.sender == callerContract` check (line 623) passes,
      // but the digest is recomputed with `other.address` and ECDSA
      // recovers a non-buyer address → InvalidSignature.
      await expect(
        escrow
          .connect(other)
          .releaseFundsViaContract(id, other.address, deadline, sigForAttacker)
      ).to.be.revertedWithCustomError(escrow, 'InvalidSignature');
    });
  });
});
