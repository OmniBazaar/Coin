const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

describe("OmniArbitration", function () {
  // ─────────────────────────────────────────────────────────────────────
  //                           SHARED STATE
  // ─────────────────────────────────────────────────────────────────────
  let arbitration;
  let participation;
  let mockEscrow;
  let xom;
  let owner, oddao;

  // Arbitrators: signers[2..11]  (10 arbitrators)
  // Buyer:  signers[12]
  // Seller: signers[13]
  // Other:  signers[14]
  let arbitrators;
  let buyer, seller, other;

  const STAKE_AMOUNT = ethers.parseEther("10000");
  const ESCROW_AMOUNT = ethers.parseEther("1000");
  const SEVEN_DAYS = 7 * 24 * 60 * 60;
  const FIVE_DAYS = 5 * 24 * 60 * 60;

  // VoteType enum values
  const VoteType = { None: 0, Release: 1, Refund: 2 };

  // DisputeStatus enum values (must match contract enum order)
  const DisputeStatus = { Active: 0, Resolved: 1, Appealed: 2, DefaultResolved: 3, PendingSelection: 4 };

  /**
   * Helper: create a dispute AND finalize arbitrator selection.
   * The contract uses two-phase commit: createDispute() sets status to
   * PendingSelection, then finalizeArbitratorSelection() (2+ blocks later)
   * assigns arbitrators and sets status to Active.
   */
  async function createAndFinalizeDispute(caller, escrowId) {
    await arbitration.connect(caller).createDispute(escrowId);
    // Mine 2 blocks so finalizeArbitratorSelection passes the block check
    await ethers.provider.send("evm_mine", []);
    await ethers.provider.send("evm_mine", []);
    const disputeId = (await arbitration.nextDisputeId()) - 1n;
    await arbitration.connect(caller).finalizeArbitratorSelection(disputeId);
    return disputeId;
  }

  // ─────────────────────────────────────────────────────────────────────
  //                      SETUP (runs before each test)
  // ─────────────────────────────────────────────────────────────────────
  beforeEach(async function () {
    const signers = await ethers.getSigners();
    owner = signers[0];
    oddao = signers[1];
    arbitrators = signers.slice(2, 12); // 10 arbitrators
    buyer = signers[12];
    seller = signers[13];
    other = signers[14];

    // ── Deploy MockERC20 (XOM) ──
    const MockERC20 = await ethers.getContractFactory("MockERC20");
    xom = await MockERC20.deploy("OmniCoin", "XOM");

    // ── Deploy MockArbitrationParticipation ──
    const MockParticipation = await ethers.getContractFactory("MockArbitrationParticipation");
    participation = await MockParticipation.deploy();

    // ── Deploy MockArbitrationEscrow ──
    const MockEscrow = await ethers.getContractFactory("MockArbitrationEscrow");
    mockEscrow = await MockEscrow.deploy();

    // ── Deploy OmniArbitration via UUPS proxy ──
    const OmniArbitration = await ethers.getContractFactory("OmniArbitration");
    arbitration = await upgrades.deployProxy(
      OmniArbitration,
      [
        await participation.getAddress(),
        await mockEscrow.getAddress(),
        await xom.getAddress(),
        oddao.address
      ],
      { initializer: "initialize", kind: "uups" }
    );

    // ── Register 10 arbitrators ──
    for (const arb of arbitrators) {
      await participation.setCanBeValidator(arb.address, true);
      await participation.setTotalScore(arb.address, 75);
      await xom.mint(arb.address, ethers.parseEther("20000"));
      await xom.connect(arb).approve(await arbitration.getAddress(), ethers.parseEther("20000"));
      await arbitration.connect(arb).registerArbitrator(STAKE_AMOUNT);
    }

    // ── Configure mock escrow (id=1) ──
    await mockEscrow.setEscrow(1, buyer.address, seller.address, ESCROW_AMOUNT);

    // ── Give buyer/seller XOM for appeal stakes ──
    await xom.mint(buyer.address, ethers.parseEther("10000"));
    await xom.mint(seller.address, ethers.parseEther("10000"));
    await xom.connect(buyer).approve(await arbitration.getAddress(), ethers.parseEther("10000"));
    await xom.connect(seller).approve(await arbitration.getAddress(), ethers.parseEther("10000"));
  });

  // ═══════════════════════════════════════════════════════════════════════
  //  1. INITIALIZATION
  // ═══════════════════════════════════════════════════════════════════════
  describe("Initialization", function () {
    it("should set DEFAULT_ADMIN_ROLE to deployer", async function () {
      const DEFAULT_ADMIN = await arbitration.DEFAULT_ADMIN_ROLE();
      expect(await arbitration.hasRole(DEFAULT_ADMIN, owner.address)).to.be.true;
    });

    it("should set DISPUTE_ADMIN_ROLE to deployer", async function () {
      const DISPUTE_ADMIN = await arbitration.DISPUTE_ADMIN_ROLE();
      expect(await arbitration.hasRole(DISPUTE_ADMIN, owner.address)).to.be.true;
    });

    it("should set nextDisputeId to 1", async function () {
      expect(await arbitration.nextDisputeId()).to.equal(1);
    });

    it("should set minArbitratorStake to 10000 ether", async function () {
      expect(await arbitration.minArbitratorStake()).to.equal(ethers.parseEther("10000"));
    });

    it("should set ODDAO treasury address correctly", async function () {
      expect(await arbitration.oddaoTreasury()).to.equal(oddao.address);
    });

    it("should set contract references correctly", async function () {
      expect(await arbitration.participation()).to.equal(await participation.getAddress());
      expect(await arbitration.escrow()).to.equal(await mockEscrow.getAddress());
      expect(await arbitration.xomToken()).to.equal(await xom.getAddress());
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  //  2. ARBITRATOR REGISTRATION
  // ═══════════════════════════════════════════════════════════════════════
  describe("Arbitrator Registration", function () {
    it("should register a qualified arbitrator with sufficient stake", async function () {
      // Use a fresh signer to test registration from scratch
      const signers = await ethers.getSigners();
      const newArb = signers[15];
      await participation.setCanBeValidator(newArb.address, true);
      await xom.mint(newArb.address, ethers.parseEther("20000"));
      await xom.connect(newArb).approve(await arbitration.getAddress(), ethers.parseEther("20000"));

      await expect(arbitration.connect(newArb).registerArbitrator(STAKE_AMOUNT))
        .to.emit(arbitration, "ArbitratorRegistered")
        .withArgs(newArb.address, STAKE_AMOUNT);

      expect(await arbitration.arbitratorStakes(newArb.address)).to.equal(STAKE_AMOUNT);
      expect(await arbitration.isInArbitratorPool(newArb.address)).to.be.true;
    });

    it("should reject registration from non-qualified address", async function () {
      const signers = await ethers.getSigners();
      const unqualified = signers[16];
      await xom.mint(unqualified.address, ethers.parseEther("20000"));
      await xom.connect(unqualified).approve(await arbitration.getAddress(), ethers.parseEther("20000"));

      await expect(
        arbitration.connect(unqualified).registerArbitrator(STAKE_AMOUNT)
      ).to.be.revertedWithCustomError(arbitration, "NotQualifiedArbitrator");
    });

    it("should reject registration with insufficient stake", async function () {
      const signers = await ethers.getSigners();
      const newArb = signers[17];
      await participation.setCanBeValidator(newArb.address, true);
      const lowStake = ethers.parseEther("5000");
      await xom.mint(newArb.address, lowStake);
      await xom.connect(newArb).approve(await arbitration.getAddress(), lowStake);

      await expect(
        arbitration.connect(newArb).registerArbitrator(lowStake)
      ).to.be.revertedWithCustomError(arbitration, "InsufficientArbitratorStake");
    });

    it("should show correct pool size after registrations", async function () {
      // 10 arbitrators registered in beforeEach
      expect(await arbitration.arbitratorPoolSize()).to.equal(10);
    });

    it("should allow arbitrator to withdraw full stake", async function () {
      const arb = arbitrators[0];
      const balanceBefore = await xom.balanceOf(arb.address);

      await expect(arbitration.connect(arb).withdrawArbitratorStake(STAKE_AMOUNT))
        .to.emit(arbitration, "ArbitratorWithdrawn")
        .withArgs(arb.address, STAKE_AMOUNT);

      expect(await xom.balanceOf(arb.address)).to.equal(balanceBefore + STAKE_AMOUNT);
      // Below minimum, should be removed from active pool flag
      expect(await arbitration.isInArbitratorPool(arb.address)).to.be.false;
    });

    it("should reject withdraw exceeding stake balance", async function () {
      const arb = arbitrators[0];
      const excess = ethers.parseEther("99999");

      await expect(
        arbitration.connect(arb).withdrawArbitratorStake(excess)
      ).to.be.revertedWithCustomError(arbitration, "InsufficientArbitratorStake");
    });

    it("should allow adding more stake with additional registration call", async function () {
      const arb = arbitrators[0];
      const additionalStake = ethers.parseEther("5000");
      // Arbitrator already has 10000 staked; mint more and approve
      await xom.mint(arb.address, additionalStake);
      await xom.connect(arb).approve(await arbitration.getAddress(), additionalStake);

      // Re-register doesn't need minArbitratorStake on the new amount;
      // however the contract requires amount >= minArbitratorStake, so
      // we provide exactly minArbitratorStake
      await xom.mint(arb.address, STAKE_AMOUNT);
      await xom.connect(arb).approve(await arbitration.getAddress(), STAKE_AMOUNT);

      await arbitration.connect(arb).registerArbitrator(STAKE_AMOUNT);
      expect(await arbitration.arbitratorStakes(arb.address)).to.equal(STAKE_AMOUNT * 2n);
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  //  3. DISPUTE CREATION
  // ═══════════════════════════════════════════════════════════════════════
  describe("Dispute Creation", function () {
    it("should allow buyer to create a dispute", async function () {
      const tx = await arbitration.connect(buyer).createDispute(1);
      const receipt = await tx.wait();

      const event = receipt.logs.find(
        (log) => log.fragment && log.fragment.name === "DisputeCreated"
      );
      expect(event).to.not.be.undefined;
      expect(event.args.disputeId).to.equal(1);
      expect(event.args.escrowId).to.equal(1);
      expect(event.args.buyer).to.equal(buyer.address);
      expect(event.args.seller).to.equal(seller.address);
      expect(event.args.amount).to.equal(ESCROW_AMOUNT);
    });

    it("should allow seller to create a dispute", async function () {
      await expect(arbitration.connect(seller).createDispute(1))
        .to.emit(arbitration, "DisputeCreated");
    });

    it("should reject dispute creation by non-party", async function () {
      await expect(
        arbitration.connect(other).createDispute(1)
      ).to.be.revertedWithCustomError(arbitration, "NotEscrowParty");
    });

    it("should set dispute status to PendingSelection after createDispute", async function () {
      await arbitration.connect(buyer).createDispute(1);
      const dispute = await arbitration.getDispute(1);
      expect(dispute.status).to.equal(DisputeStatus.PendingSelection);
    });

    it("should select exactly 3 arbitrators after finalization", async function () {
      await createAndFinalizeDispute(buyer, 1);

      const dispute = await arbitration.getDispute(1);
      const selectedArbs = dispute.arbitrators;
      expect(selectedArbs.length).to.equal(3);

      // All selected should be addresses in the pool
      const poolAddresses = arbitrators.map((a) => a.address);
      for (const addr of selectedArbs) {
        expect(poolAddresses).to.include(addr);
      }
    });

    it("should set dispute status to Active after finalization", async function () {
      await createAndFinalizeDispute(buyer, 1);
      const dispute = await arbitration.getDispute(1);
      expect(dispute.status).to.equal(DisputeStatus.Active);
    });

    it("should set deadline to now + 7 days after finalization", async function () {
      await createAndFinalizeDispute(buyer, 1);
      const dispute = await arbitration.getDispute(1);
      const latest = await time.latest();
      expect(dispute.deadline).to.be.closeTo(latest + SEVEN_DAYS, 5);
    });

    it("should increment nextDisputeId", async function () {
      await arbitration.connect(buyer).createDispute(1);
      expect(await arbitration.nextDisputeId()).to.equal(2);
    });

    it("should not select buyer or seller as arbitrators", async function () {
      await arbitration.connect(buyer).createDispute(1);
      const dispute = await arbitration.getDispute(1);
      for (const addr of dispute.arbitrators) {
        expect(addr).to.not.equal(buyer.address);
        expect(addr).to.not.equal(seller.address);
      }
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  //  4. EVIDENCE SUBMISSION
  // ═══════════════════════════════════════════════════════════════════════
  describe("Evidence Submission", function () {
    let disputeArbs;

    beforeEach(async function () {
      await createAndFinalizeDispute(buyer, 1);
      const dispute = await arbitration.getDispute(1);
      disputeArbs = dispute.arbitrators;
    });

    it("should allow buyer to submit evidence", async function () {
      const cid = ethers.id("buyer-evidence-1");
      await expect(arbitration.connect(buyer).submitEvidence(1, cid))
        .to.emit(arbitration, "EvidenceSubmitted")
        .withArgs(1, buyer.address, cid);
    });

    it("should allow seller to submit evidence", async function () {
      const cid = ethers.id("seller-evidence-1");
      await expect(arbitration.connect(seller).submitEvidence(1, cid))
        .to.emit(arbitration, "EvidenceSubmitted")
        .withArgs(1, seller.address, cid);
    });

    it("should allow assigned arbitrator to submit evidence", async function () {
      const cid = ethers.id("arb-evidence-1");
      // Find the signer that matches the first assigned arbitrator
      const arbSigner = arbitrators.find((a) => a.address === disputeArbs[0]);
      if (!arbSigner) {
        // If the selected arbitrator is not found in our array, skip gracefully
        this.skip();
      }
      await expect(arbitration.connect(arbSigner).submitEvidence(1, cid))
        .to.emit(arbitration, "EvidenceSubmitted");
    });

    it("should reject evidence from unauthorized address", async function () {
      const cid = ethers.id("unauthorized-evidence");
      await expect(
        arbitration.connect(other).submitEvidence(1, cid)
      ).to.be.revertedWithCustomError(arbitration, "NotAssignedArbitrator");
    });

    it("should record multiple evidence CIDs", async function () {
      const cid1 = ethers.id("evidence-1");
      const cid2 = ethers.id("evidence-2");
      await arbitration.connect(buyer).submitEvidence(1, cid1);
      await arbitration.connect(seller).submitEvidence(1, cid2);

      const evidence = await arbitration.getEvidence(1);
      expect(evidence.length).to.equal(2);
      expect(evidence[0]).to.equal(cid1);
      expect(evidence[1]).to.equal(cid2);
    });

    it("should reject evidence for non-existent dispute", async function () {
      const cid = ethers.id("evidence-ghost");
      await expect(
        arbitration.connect(buyer).submitEvidence(999, cid)
      ).to.be.revertedWithCustomError(arbitration, "DisputeNotFound");
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  //  5. VOTING
  // ═══════════════════════════════════════════════════════════════════════
  describe("Voting", function () {
    let disputeArbs;
    let arbSigners;

    beforeEach(async function () {
      await createAndFinalizeDispute(buyer, 1);
      const dispute = await arbitration.getDispute(1);
      disputeArbs = dispute.arbitrators;

      // Map selected addresses back to signers
      arbSigners = disputeArbs.map((addr) =>
        arbitrators.find((a) => a.address === addr)
      );
    });

    it("should allow assigned arbitrator to cast Release vote", async function () {
      await expect(arbitration.connect(arbSigners[0]).castVote(1, VoteType.Release))
        .to.emit(arbitration, "VoteCast")
        .withArgs(1, arbSigners[0].address, VoteType.Release);
    });

    it("should allow assigned arbitrator to cast Refund vote", async function () {
      await expect(arbitration.connect(arbSigners[0]).castVote(1, VoteType.Refund))
        .to.emit(arbitration, "VoteCast")
        .withArgs(1, arbSigners[0].address, VoteType.Refund);
    });

    it("should reject VoteType.None", async function () {
      await expect(
        arbitration.connect(arbSigners[0]).castVote(1, VoteType.None)
      ).to.be.revertedWithCustomError(arbitration, "InvalidVoteType");
    });

    it("should reject vote from non-assigned arbitrator", async function () {
      await expect(
        arbitration.connect(other).castVote(1, VoteType.Release)
      ).to.be.revertedWithCustomError(arbitration, "NotAssignedArbitrator");
    });

    it("should reject duplicate vote from same arbitrator", async function () {
      await arbitration.connect(arbSigners[0]).castVote(1, VoteType.Release);

      await expect(
        arbitration.connect(arbSigners[0]).castVote(1, VoteType.Refund)
      ).to.be.revertedWithCustomError(arbitration, "AlreadyVoted");
    });

    it("should resolve dispute with 2-of-3 Release majority", async function () {
      await arbitration.connect(arbSigners[0]).castVote(1, VoteType.Release);
      const tx = await arbitration.connect(arbSigners[1]).castVote(1, VoteType.Release);

      await expect(tx)
        .to.emit(arbitration, "DisputeResolved")
        .withArgs(1, VoteType.Release, 2, 0);

      const dispute = await arbitration.getDispute(1);
      expect(dispute.status).to.equal(DisputeStatus.Resolved);
    });

    it("should resolve dispute with 2-of-3 Refund majority", async function () {
      await arbitration.connect(arbSigners[0]).castVote(1, VoteType.Refund);
      const tx = await arbitration.connect(arbSigners[1]).castVote(1, VoteType.Refund);

      await expect(tx)
        .to.emit(arbitration, "DisputeResolved")
        .withArgs(1, VoteType.Refund, 0, 2);

      const dispute = await arbitration.getDispute(1);
      expect(dispute.status).to.equal(DisputeStatus.Resolved);
    });

    it("should not resolve with only 1 vote (no majority)", async function () {
      const tx = await arbitration.connect(arbSigners[0]).castVote(1, VoteType.Release);
      const receipt = await tx.wait();

      // Should not have DisputeResolved event
      const resolvedEvent = receipt.logs.find(
        (log) => log.fragment && log.fragment.name === "DisputeResolved"
      );
      expect(resolvedEvent).to.be.undefined;

      const dispute = await arbitration.getDispute(1);
      expect(dispute.status).to.equal(DisputeStatus.Active);
    });

    it("should reject vote on already resolved dispute", async function () {
      await arbitration.connect(arbSigners[0]).castVote(1, VoteType.Release);
      await arbitration.connect(arbSigners[1]).castVote(1, VoteType.Release);
      // Dispute is now resolved

      await expect(
        arbitration.connect(arbSigners[2]).castVote(1, VoteType.Release)
      ).to.be.revertedWithCustomError(arbitration, "DisputeAlreadyResolved");
    });

    it("should track vote counts correctly with mixed votes", async function () {
      await arbitration.connect(arbSigners[0]).castVote(1, VoteType.Release);
      await arbitration.connect(arbSigners[1]).castVote(1, VoteType.Refund);

      const dispute = await arbitration.getDispute(1);
      expect(dispute.releaseVotes).to.equal(1);
      expect(dispute.refundVotes).to.equal(1);
      expect(dispute.status).to.equal(DisputeStatus.Active);
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  //  6. APPEALS
  // ═══════════════════════════════════════════════════════════════════════
  describe("Appeals", function () {
    let arbSigners;

    beforeEach(async function () {
      await createAndFinalizeDispute(buyer, 1);
      const dispute = await arbitration.getDispute(1);
      arbSigners = dispute.arbitrators.map((addr) =>
        arbitrators.find((a) => a.address === addr)
      );

      // Resolve with 2-of-3 Release
      await arbitration.connect(arbSigners[0]).castVote(1, VoteType.Release);
      await arbitration.connect(arbSigners[1]).castVote(1, VoteType.Release);
    });

    it("should allow buyer to file an appeal after resolution", async function () {
      const tx = await arbitration.connect(buyer).fileAppeal(1);
      await expect(tx).to.emit(arbitration, "AppealFiled");
    });

    it("should allow seller to file an appeal after resolution", async function () {
      const tx = await arbitration.connect(seller).fileAppeal(1);
      await expect(tx).to.emit(arbitration, "AppealFiled");
    });

    it("should reject appeal by non-party", async function () {
      await expect(
        arbitration.connect(other).fileAppeal(1)
      ).to.be.revertedWithCustomError(arbitration, "NotEscrowParty");
    });

    it("should reject appeal on non-resolved dispute", async function () {
      // Create a new dispute (escrowId=2) that stays active
      await mockEscrow.setEscrow(2, buyer.address, seller.address, ESCROW_AMOUNT);
      await createAndFinalizeDispute(buyer, 2);

      await expect(
        arbitration.connect(buyer).fileAppeal(2)
      ).to.be.revertedWithCustomError(arbitration, "DisputeAlreadyResolved");
    });

    it("should reject double appeal on same dispute", async function () {
      await arbitration.connect(buyer).fileAppeal(1);

      // After first appeal, status is Appealed (not Resolved), so the
      // contract's first guard (status != Resolved) triggers before the
      // AlreadyAppealed guard
      await expect(
        arbitration.connect(seller).fileAppeal(1)
      ).to.be.revertedWithCustomError(arbitration, "DisputeAlreadyResolved");
    });

    it("should transfer appeal stake from appellant", async function () {
      // Appeal stake = (amount * 500 / 10000) * 5000 / 10000 = amount * 2.5%
      const fee = (ESCROW_AMOUNT * 500n) / 10000n;
      const expectedStake = (fee * 5000n) / 10000n;

      const balanceBefore = await xom.balanceOf(buyer.address);
      await arbitration.connect(buyer).fileAppeal(1);
      const balanceAfter = await xom.balanceOf(buyer.address);

      expect(balanceBefore - balanceAfter).to.equal(expectedStake);
    });

    it("should select 5 new arbitrators for appeal panel", async function () {
      const tx = await arbitration.connect(buyer).fileAppeal(1);
      const receipt = await tx.wait();

      const event = receipt.logs.find(
        (log) => log.fragment && log.fragment.name === "AppealFiled"
      );
      expect(event).to.not.be.undefined;
      const appealArbs = event.args.arbitrators;
      expect(appealArbs.length).to.equal(5);

      // Appeal arbitrators should not include original 3
      const dispute = await arbitration.getDispute(1);
      for (const appealAddr of appealArbs) {
        for (const origAddr of dispute.arbitrators) {
          expect(appealAddr).to.not.equal(origAddr);
        }
      }
    });

    it("should set dispute status to Appealed", async function () {
      await arbitration.connect(buyer).fileAppeal(1);
      const dispute = await arbitration.getDispute(1);
      expect(dispute.status).to.equal(DisputeStatus.Appealed);
    });

    it("should resolve appeal with 3-of-5 majority", async function () {
      const tx = await arbitration.connect(buyer).fileAppeal(1);
      const receipt = await tx.wait();
      const event = receipt.logs.find(
        (log) => log.fragment && log.fragment.name === "AppealFiled"
      );
      const appealArbAddrs = event.args.arbitrators;

      // Map appeal arbitrator addresses to signers
      const appealSigners = appealArbAddrs.map((addr) =>
        arbitrators.find((a) => a.address === addr)
      );

      // Cast 3 Refund votes to overturn original Release decision
      await arbitration.connect(appealSigners[0]).castAppealVote(1, VoteType.Refund);
      await arbitration.connect(appealSigners[1]).castAppealVote(1, VoteType.Refund);
      const resolveTx = await arbitration.connect(appealSigners[2]).castAppealVote(1, VoteType.Refund);

      await expect(resolveTx)
        .to.emit(arbitration, "AppealResolved")
        .withArgs(1, VoteType.Refund, true); // overturned = true
    });

    it("should return appeal stake when appeal overturns original decision", async function () {
      const fee = (ESCROW_AMOUNT * 500n) / 10000n;
      const appealStake = (fee * 5000n) / 10000n;

      const tx = await arbitration.connect(buyer).fileAppeal(1);
      const receipt = await tx.wait();
      const event = receipt.logs.find(
        (log) => log.fragment && log.fragment.name === "AppealFiled"
      );
      const appealSigners = event.args.arbitrators.map((addr) =>
        arbitrators.find((a) => a.address === addr)
      );

      // Get buyer balance after filing appeal (stake deducted)
      const balanceAfterFiling = await xom.balanceOf(buyer.address);

      // Overturn: vote Refund (original was Release)
      await arbitration.connect(appealSigners[0]).castAppealVote(1, VoteType.Refund);
      await arbitration.connect(appealSigners[1]).castAppealVote(1, VoteType.Refund);
      await arbitration.connect(appealSigners[2]).castAppealVote(1, VoteType.Refund);

      const balanceAfterResolve = await xom.balanceOf(buyer.address);
      expect(balanceAfterResolve - balanceAfterFiling).to.equal(appealStake);
    });

    it("should not return appeal stake when appeal upholds original decision", async function () {
      const tx = await arbitration.connect(buyer).fileAppeal(1);
      const receipt = await tx.wait();
      const event = receipt.logs.find(
        (log) => log.fragment && log.fragment.name === "AppealFiled"
      );
      const appealSigners = event.args.arbitrators.map((addr) =>
        arbitrators.find((a) => a.address === addr)
      );

      // Uphold: vote Release (same as original)
      const balanceBefore = await xom.balanceOf(buyer.address);
      await arbitration.connect(appealSigners[0]).castAppealVote(1, VoteType.Release);
      await arbitration.connect(appealSigners[1]).castAppealVote(1, VoteType.Release);
      await arbitration.connect(appealSigners[2]).castAppealVote(1, VoteType.Release);
      const balanceAfter = await xom.balanceOf(buyer.address);

      // No stake returned
      expect(balanceAfter).to.equal(balanceBefore);
    });

    it("should reject appeal vote with VoteType.None", async function () {
      const tx = await arbitration.connect(buyer).fileAppeal(1);
      const receipt = await tx.wait();
      const event = receipt.logs.find(
        (log) => log.fragment && log.fragment.name === "AppealFiled"
      );
      const appealSigner = arbitrators.find(
        (a) => a.address === event.args.arbitrators[0]
      );

      await expect(
        arbitration.connect(appealSigner).castAppealVote(1, VoteType.None)
      ).to.be.revertedWithCustomError(arbitration, "InvalidVoteType");
    });

    it("should reject duplicate appeal vote", async function () {
      const tx = await arbitration.connect(buyer).fileAppeal(1);
      const receipt = await tx.wait();
      const event = receipt.logs.find(
        (log) => log.fragment && log.fragment.name === "AppealFiled"
      );
      const appealSigner = arbitrators.find(
        (a) => a.address === event.args.arbitrators[0]
      );

      await arbitration.connect(appealSigner).castAppealVote(1, VoteType.Release);
      await expect(
        arbitration.connect(appealSigner).castAppealVote(1, VoteType.Refund)
      ).to.be.revertedWithCustomError(arbitration, "AlreadyVoted");
    });

    it("should reject appeal vote from non-assigned arbitrator", async function () {
      await arbitration.connect(buyer).fileAppeal(1);

      await expect(
        arbitration.connect(other).castAppealVote(1, VoteType.Release)
      ).to.be.revertedWithCustomError(arbitration, "NotAssignedArbitrator");
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  //  7. DEFAULT RESOLUTION (TIMEOUT)
  // ═══════════════════════════════════════════════════════════════════════
  describe("Default Resolution", function () {
    beforeEach(async function () {
      await createAndFinalizeDispute(buyer, 1);
    });

    it("should allow default resolution after deadline", async function () {
      await time.increase(SEVEN_DAYS + 1);

      const tx = await arbitration.connect(buyer).triggerDefaultResolution(1);
      await expect(tx).to.emit(arbitration, "DisputeDefaultResolved").withArgs(1, buyer.address);
      await expect(tx)
        .to.emit(arbitration, "DisputeResolved")
        .withArgs(1, VoteType.Refund, 0, 0);
    });

    it("should set status to DefaultResolved", async function () {
      await time.increase(SEVEN_DAYS + 1);
      await arbitration.connect(buyer).triggerDefaultResolution(1);

      const dispute = await arbitration.getDispute(1);
      expect(dispute.status).to.equal(DisputeStatus.DefaultResolved);
    });

    it("should reject default resolution before deadline", async function () {
      await expect(
        arbitration.connect(buyer).triggerDefaultResolution(1)
      ).to.be.revertedWithCustomError(arbitration, "DeadlineNotReached");
    });

    it("should reject default resolution on already resolved dispute", async function () {
      // Resolve via votes first
      const dispute = await arbitration.getDispute(1);
      const arbSigners = dispute.arbitrators.map((addr) =>
        arbitrators.find((a) => a.address === addr)
      );
      await arbitration.connect(arbSigners[0]).castVote(1, VoteType.Release);
      await arbitration.connect(arbSigners[1]).castVote(1, VoteType.Release);

      await time.increase(SEVEN_DAYS + 1);
      await expect(
        arbitration.connect(buyer).triggerDefaultResolution(1)
      ).to.be.revertedWithCustomError(arbitration, "DisputeAlreadyResolved");
    });

    it("should allow anyone to trigger default resolution", async function () {
      await time.increase(SEVEN_DAYS + 1);

      // Even 'other' (non-party) can trigger default resolution
      const tx = await arbitration.connect(other).triggerDefaultResolution(1);
      await expect(tx).to.emit(arbitration, "DisputeDefaultResolved").withArgs(1, other.address);
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  //  8. FEE CALCULATION
  // ═══════════════════════════════════════════════════════════════════════
  describe("Fee Calculation", function () {
    it("should calculate 5% total fee", async function () {
      const amount = ethers.parseEther("1000");
      const result = await arbitration.calculateFee(amount);

      const expectedTotal = (amount * 500n) / 10000n; // 50 XOM
      expect(result.totalFee).to.equal(expectedTotal);
    });

    it("should split fee 70/20/10", async function () {
      const amount = ethers.parseEther("1000");
      const result = await arbitration.calculateFee(amount);

      const totalFee = result.totalFee;
      const expectedArb = (totalFee * 7000n) / 10000n;       // 70%
      const expectedValidator = (totalFee * 2000n) / 10000n;  // 20%
      const expectedOddao = totalFee - expectedArb - expectedValidator; // 10%

      expect(result.arbitratorShare).to.equal(expectedArb);
      expect(result.validatorShare).to.equal(expectedValidator);
      expect(result.oddaoShare).to.equal(expectedOddao);
    });

    it("should return zero fees for zero amount", async function () {
      const result = await arbitration.calculateFee(0);
      expect(result.totalFee).to.equal(0);
      expect(result.arbitratorShare).to.equal(0);
      expect(result.validatorShare).to.equal(0);
      expect(result.oddaoShare).to.equal(0);
    });

    it("should handle large amounts correctly", async function () {
      const amount = ethers.parseEther("1000000"); // 1M XOM
      const result = await arbitration.calculateFee(amount);
      const expectedTotal = ethers.parseEther("50000"); // 5%
      expect(result.totalFee).to.equal(expectedTotal);
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  //  9. ACCESS CONTROL & ADMIN
  // ═══════════════════════════════════════════════════════════════════════
  describe("Access Control", function () {
    it("should allow admin to pause the contract", async function () {
      await arbitration.connect(owner).pause();
      // Registering should fail while paused
      const signers = await ethers.getSigners();
      const newArb = signers[18];
      await participation.setCanBeValidator(newArb.address, true);
      await xom.mint(newArb.address, ethers.parseEther("20000"));
      await xom.connect(newArb).approve(await arbitration.getAddress(), ethers.parseEther("20000"));

      await expect(
        arbitration.connect(newArb).registerArbitrator(STAKE_AMOUNT)
      ).to.be.revertedWithCustomError(arbitration, "EnforcedPause");
    });

    it("should allow admin to unpause the contract", async function () {
      await arbitration.connect(owner).pause();
      await arbitration.connect(owner).unpause();

      // Should work again after unpause
      const signers = await ethers.getSigners();
      const newArb = signers[18];
      await participation.setCanBeValidator(newArb.address, true);
      await xom.mint(newArb.address, ethers.parseEther("20000"));
      await xom.connect(newArb).approve(await arbitration.getAddress(), ethers.parseEther("20000"));
      await expect(arbitration.connect(newArb).registerArbitrator(STAKE_AMOUNT)).to.not.be.reverted;
    });

    it("should reject pause from non-admin", async function () {
      await expect(
        arbitration.connect(other).pause()
      ).to.be.reverted;
    });

    it("should reject unpause from non-admin", async function () {
      await arbitration.connect(owner).pause();
      await expect(
        arbitration.connect(other).unpause()
      ).to.be.reverted;
    });

    it("should allow admin to update contract references", async function () {
      const MockParticipation = await ethers.getContractFactory("MockArbitrationParticipation");
      const newParticipation = await MockParticipation.deploy();

      await arbitration.connect(owner).updateContracts(
        await newParticipation.getAddress(),
        ethers.ZeroAddress // don't change escrow
      );

      expect(await arbitration.participation()).to.equal(await newParticipation.getAddress());
      // Escrow should be unchanged
      expect(await arbitration.escrow()).to.equal(await mockEscrow.getAddress());
    });

    it("should reject updateContracts from non-admin", async function () {
      await expect(
        arbitration.connect(other).updateContracts(ethers.ZeroAddress, ethers.ZeroAddress)
      ).to.be.reverted;
    });

    it("should allow admin to update minArbitratorStake", async function () {
      const newMin = ethers.parseEther("5000");
      await arbitration.connect(owner).setMinArbitratorStake(newMin);
      expect(await arbitration.minArbitratorStake()).to.equal(newMin);
    });

    it("should reject setMinArbitratorStake from non-admin", async function () {
      await expect(
        arbitration.connect(other).setMinArbitratorStake(ethers.parseEther("1"))
      ).to.be.reverted;
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  //  10. EDGE CASES
  // ═══════════════════════════════════════════════════════════════════════
  describe("Edge Cases", function () {
    it("should reject vote for non-existent dispute", async function () {
      await expect(
        arbitration.connect(arbitrators[0]).castVote(999, VoteType.Release)
      ).to.be.revertedWithCustomError(arbitration, "DisputeNotFound");
    });

    it("should reject creating dispute when paused", async function () {
      await arbitration.connect(owner).pause();
      await expect(
        arbitration.connect(buyer).createDispute(1)
      ).to.be.revertedWithCustomError(arbitration, "EnforcedPause");
    });

    it("should reject evidence submission when paused", async function () {
      await createAndFinalizeDispute(buyer, 1);
      await arbitration.connect(owner).pause();
      const cid = ethers.id("evidence-paused");
      await expect(
        arbitration.connect(buyer).submitEvidence(1, cid)
      ).to.be.revertedWithCustomError(arbitration, "EnforcedPause");
    });

    it("should reject casting vote when paused", async function () {
      await createAndFinalizeDispute(buyer, 1);
      const dispute = await arbitration.getDispute(1);
      const arbSigner = arbitrators.find((a) => a.address === dispute.arbitrators[0]);

      await arbitration.connect(owner).pause();
      await expect(
        arbitration.connect(arbSigner).castVote(1, VoteType.Release)
      ).to.be.revertedWithCustomError(arbitration, "EnforcedPause");
    });

    it("should handle multiple disputes concurrently", async function () {
      // Create second escrow
      await mockEscrow.setEscrow(2, buyer.address, seller.address, ethers.parseEther("500"));

      await createAndFinalizeDispute(buyer, 1);
      await createAndFinalizeDispute(seller, 2);

      expect(await arbitration.nextDisputeId()).to.equal(3);

      const d1 = await arbitration.getDispute(1);
      const d2 = await arbitration.getDispute(2);
      expect(d1.escrowId).to.equal(1);
      expect(d2.escrowId).to.equal(2);

      // Verify amounts via DisputeCreated events (disputedAmount is not
      // in getDispute return tuple, but is in the struct storage)
      // Access the disputes mapping directly -- the auto-generated getter
      // for the struct returns individual fields
      const d1Full = await arbitration.disputes(1);
      const d2Full = await arbitration.disputes(2);
      expect(d1Full.disputedAmount).to.equal(ESCROW_AMOUNT);
      expect(d2Full.disputedAmount).to.equal(ethers.parseEther("500"));
    });

    it("should reject evidence after dispute is resolved", async function () {
      await createAndFinalizeDispute(buyer, 1);
      const dispute = await arbitration.getDispute(1);
      const arbSigners = dispute.arbitrators.map((addr) =>
        arbitrators.find((a) => a.address === addr)
      );

      // Resolve with 2-of-3
      await arbitration.connect(arbSigners[0]).castVote(1, VoteType.Release);
      await arbitration.connect(arbSigners[1]).castVote(1, VoteType.Release);

      const cid = ethers.id("late-evidence");
      await expect(
        arbitration.connect(buyer).submitEvidence(1, cid)
      ).to.be.revertedWithCustomError(arbitration, "EvidencePeriodClosed");
    });

    it("should still allow evidence during appeal phase", async function () {
      await createAndFinalizeDispute(buyer, 1);
      const dispute = await arbitration.getDispute(1);
      const arbSigners = dispute.arbitrators.map((addr) =>
        arbitrators.find((a) => a.address === addr)
      );

      // Resolve, then appeal
      await arbitration.connect(arbSigners[0]).castVote(1, VoteType.Release);
      await arbitration.connect(arbSigners[1]).castVote(1, VoteType.Release);
      await arbitration.connect(buyer).fileAppeal(1);

      // Evidence during appeal should be allowed (status = Appealed)
      const cid = ethers.id("appeal-evidence");
      await expect(arbitration.connect(buyer).submitEvidence(1, cid))
        .to.emit(arbitration, "EvidenceSubmitted");
    });
  });
});
