const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

/**
 * @title Trustless Architecture — Cross-Contract Integration Tests
 * @notice Validates that trustless contracts work together correctly
 *         across the full lifecycle of marketplace, escrow, arbitration,
 *         oracle, ENS, and chat fee subsystems.
 *
 * @dev Contracts under test:
 *   - OmniMarketplace (UUPS) — EIP-712 listing registration
 *   - OmniArbitration (UUPS)  — 3-arbitrator dispute resolution
 *   - OmniPriceOracle (UUPS)  — multi-validator price consensus + TWAP
 *   - OmniENS                 — trustless username registry
 *   - OmniChatFee             — free-tier + paid messaging fees
 *
 * Mock dependencies:
 *   - MockOmniCore             — validator status oracle
 *   - MockArbitrationParticipation — arbitrator qualification
 *   - MockArbitrationEscrow    — escrow buyer/seller/amount
 *   - MockERC20               — XOM token
 */
describe("Trustless Architecture — Cross-Contract Integration", function () {
  // ════════════════════════════════════════════════════════════════════════
  //  Shared helpers
  // ════════════════════════════════════════════════════════════════════════

  /** Generate a random bytes32 value */
  function randomBytes32() {
    return ethers.hexlify(ethers.randomBytes(32));
  }

  // ════════════════════════════════════════════════════════════════════════
  //  1. FULL MARKETPLACE → ESCROW → ARBITRATION FLOW
  // ════════════════════════════════════════════════════════════════════════

  describe("Full Marketplace → Escrow → Arbitration Flow", function () {
    let marketplace, arbitration, participation, mockEscrow, xom;
    let owner, oddao;
    let arbitrators; // 10 signers for the arbitration pool
    let buyer, seller, other;

    const STAKE_AMOUNT = ethers.parseEther("10000");
    const ESCROW_AMOUNT = ethers.parseEther("500");
    const LISTING_PRICE = ethers.parseEther("500");
    const ONE_DAY = 86400;
    const SIXTY_DAYS = 60 * ONE_DAY;
    const SEVEN_DAYS = 7 * 24 * 60 * 60;

    const VoteType = { None: 0, Release: 1, Refund: 2 };
    const DisputeStatus = { Active: 0, Resolved: 1, Appealed: 2, DefaultResolved: 3 };

    // EIP-712 types for marketplace listing
    const LISTING_TYPES = {
      Listing: [
        { name: "ipfsCID", type: "bytes32" },
        { name: "contentHash", type: "bytes32" },
        { name: "price", type: "uint256" },
        { name: "expiry", type: "uint256" },
        { name: "nonce", type: "uint256" },
      ],
    };

    /** Build the EIP-712 domain for the deployed marketplace instance */
    async function getMarketplaceDomain() {
      return {
        name: "OmniMarketplace",
        version: "1",
        chainId: (await ethers.provider.getNetwork()).chainId,
        verifyingContract: await marketplace.getAddress(),
      };
    }

    /** Sign a listing with EIP-712 using a specific signer */
    async function signListing(signer, ipfsCID, contentHash, price, expiry) {
      const domain = await getMarketplaceDomain();
      const nonce = await marketplace.getNonce(signer.address);
      const value = { ipfsCID, contentHash, price, expiry, nonce };
      return signer.signTypedData(domain, LISTING_TYPES, value);
    }

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

      // ── Deploy OmniMarketplace (UUPS proxy) ──
      const MarketplaceFactory = await ethers.getContractFactory("OmniMarketplace");
      marketplace = await upgrades.deployProxy(MarketplaceFactory, [], {
        initializer: "initialize",
        kind: "uups",
      });
      await marketplace.waitForDeployment();

      // ── Deploy MockArbitrationParticipation ──
      const MockParticipation = await ethers.getContractFactory("MockArbitrationParticipation");
      participation = await MockParticipation.deploy();

      // ── Deploy MockArbitrationEscrow ──
      const MockEscrow = await ethers.getContractFactory("MockArbitrationEscrow");
      mockEscrow = await MockEscrow.deploy();

      // ── Deploy OmniArbitration (UUPS proxy) ──
      const ArbitrationFactory = await ethers.getContractFactory("OmniArbitration");
      arbitration = await upgrades.deployProxy(
        ArbitrationFactory,
        [
          await participation.getAddress(),
          await mockEscrow.getAddress(),
          await xom.getAddress(),
          oddao.address,
        ],
        { initializer: "initialize", kind: "uups" }
      );

      // ── Register 10 arbitrators with stakes ──
      for (const arb of arbitrators) {
        await participation.setCanBeValidator(arb.address, true);
        await participation.setTotalScore(arb.address, 75);
        await xom.mint(arb.address, ethers.parseEther("20000"));
        await xom.connect(arb).approve(await arbitration.getAddress(), ethers.parseEther("20000"));
        await arbitration.connect(arb).registerArbitrator(STAKE_AMOUNT);
      }

      // ── Give buyer and seller XOM (for appeal stakes) ──
      await xom.mint(buyer.address, ethers.parseEther("10000"));
      await xom.mint(seller.address, ethers.parseEther("10000"));
      await xom.connect(buyer).approve(await arbitration.getAddress(), ethers.parseEther("10000"));
      await xom.connect(seller).approve(await arbitration.getAddress(), ethers.parseEther("10000"));
    });

    it("should register a listing, simulate escrow, create dispute, and resolve via 3 arbitrator votes", async function () {
      // ── Step 1: Seller registers a listing with EIP-712 signature ──
      const ipfsCID = randomBytes32();
      const contentHash = randomBytes32();
      const expiry = (await time.latest()) + SIXTY_DAYS;
      const sig = await signListing(seller, ipfsCID, contentHash, LISTING_PRICE, expiry);

      const listingTx = await marketplace
        .connect(seller)
        .registerListing(ipfsCID, contentHash, LISTING_PRICE, expiry, sig);
      await expect(listingTx)
        .to.emit(marketplace, "ListingRegistered")
        .withArgs(1, seller.address, ipfsCID, contentHash, LISTING_PRICE, expiry);

      // Verify listing is valid on-chain
      expect(await marketplace.isListingValid(1)).to.be.true;
      const listing = await marketplace.listings(1);
      expect(listing.creator).to.equal(seller.address);
      expect(listing.price).to.equal(LISTING_PRICE);

      // Verify content integrity
      expect(await marketplace.verifyContent(1, contentHash)).to.be.true;
      expect(await marketplace.verifyContent(1, randomBytes32())).to.be.false;

      // ── Step 2: Buyer purchases via escrow (simulated) ──
      const escrowId = 1;
      await mockEscrow.setEscrow(escrowId, buyer.address, seller.address, ESCROW_AMOUNT);

      // ── Step 3: Buyer creates a dispute ──
      const disputeTx = await arbitration.connect(buyer).createDispute(escrowId);
      const disputeReceipt = await disputeTx.wait();

      const createEvent = disputeReceipt.logs.find(
        (log) => log.fragment && log.fragment.name === "DisputeCreated"
      );
      expect(createEvent).to.not.be.undefined;
      expect(createEvent.args.disputeId).to.equal(1);
      expect(createEvent.args.buyer).to.equal(buyer.address);
      expect(createEvent.args.seller).to.equal(seller.address);
      expect(createEvent.args.amount).to.equal(ESCROW_AMOUNT);

      // ── Step 4: Retrieve assigned arbitrators ──
      const dispute = await arbitration.getDispute(1);
      expect(dispute.arbitrators.length).to.equal(3);
      expect(dispute.status).to.equal(DisputeStatus.Active);

      // None of the selected arbitrators should be buyer or seller
      for (const addr of dispute.arbitrators) {
        expect(addr).to.not.equal(buyer.address);
        expect(addr).to.not.equal(seller.address);
      }

      // Map addresses back to signers
      const arbSigners = dispute.arbitrators.map((addr) =>
        arbitrators.find((a) => a.address === addr)
      );

      // ── Step 5: Submit evidence from both parties ──
      const buyerEvidence = ethers.id("buyer-proof-of-payment");
      const sellerEvidence = ethers.id("seller-proof-of-shipment");
      await expect(arbitration.connect(buyer).submitEvidence(1, buyerEvidence))
        .to.emit(arbitration, "EvidenceSubmitted")
        .withArgs(1, buyer.address, buyerEvidence);
      await expect(arbitration.connect(seller).submitEvidence(1, sellerEvidence))
        .to.emit(arbitration, "EvidenceSubmitted")
        .withArgs(1, seller.address, sellerEvidence);

      const evidence = await arbitration.getEvidence(1);
      expect(evidence.length).to.equal(2);

      // ── Step 6: Three arbitrators vote (2 Refund, 1 Release) ──
      await arbitration.connect(arbSigners[0]).castVote(1, VoteType.Refund);
      await arbitration.connect(arbSigners[1]).castVote(1, VoteType.Refund);

      // 2-of-3 Refund majority reached — dispute should auto-resolve
      const resolvedDispute = await arbitration.getDispute(1);
      expect(resolvedDispute.status).to.equal(DisputeStatus.Resolved);
      expect(resolvedDispute.refundVotes).to.equal(2);

      // Third vote should be rejected since dispute is already resolved
      await expect(
        arbitration.connect(arbSigners[2]).castVote(1, VoteType.Release)
      ).to.be.revertedWithCustomError(arbitration, "DisputeAlreadyResolved");
    });

    it("should support the full lifecycle: listing → escrow → dispute → appeal → overturn", async function () {
      // ── Register listing directly ──
      const ipfsCID = randomBytes32();
      const contentHash = randomBytes32();
      await marketplace
        .connect(seller)
        .registerListingDirect(ipfsCID, contentHash, LISTING_PRICE, 0);
      expect(await marketplace.isListingValid(1)).to.be.true;

      // ── Simulate escrow creation ──
      const escrowId = 42;
      await mockEscrow.setEscrow(escrowId, buyer.address, seller.address, ESCROW_AMOUNT);

      // ── Buyer opens dispute ──
      await arbitration.connect(buyer).createDispute(escrowId);
      const dispute = await arbitration.getDispute(1);
      const arbSigners = dispute.arbitrators.map((addr) =>
        arbitrators.find((a) => a.address === addr)
      );

      // ── Resolve with Release (2-of-3) ──
      await arbitration.connect(arbSigners[0]).castVote(1, VoteType.Release);
      await arbitration.connect(arbSigners[1]).castVote(1, VoteType.Release);

      const resolvedDispute = await arbitration.getDispute(1);
      expect(resolvedDispute.status).to.equal(DisputeStatus.Resolved);
      expect(resolvedDispute.releaseVotes).to.equal(2);

      // ── Buyer appeals the Release decision ──
      const appealTx = await arbitration.connect(buyer).fileAppeal(1);
      const appealReceipt = await appealTx.wait();
      const appealEvent = appealReceipt.logs.find(
        (log) => log.fragment && log.fragment.name === "AppealFiled"
      );
      expect(appealEvent).to.not.be.undefined;

      const appealArbAddrs = appealEvent.args.arbitrators;
      expect(appealArbAddrs.length).to.equal(5);

      // Appeal arbitrators must not overlap with original 3
      for (const appealAddr of appealArbAddrs) {
        for (const origAddr of dispute.arbitrators) {
          expect(appealAddr).to.not.equal(origAddr);
        }
      }

      // ── Appeal panel votes 3 Refund → overturns original Release ──
      const appealSigners = appealArbAddrs.map((addr) =>
        arbitrators.find((a) => a.address === addr)
      );

      await arbitration.connect(appealSigners[0]).castAppealVote(1, VoteType.Refund);
      await arbitration.connect(appealSigners[1]).castAppealVote(1, VoteType.Refund);
      const overturnTx = await arbitration.connect(appealSigners[2]).castAppealVote(1, VoteType.Refund);

      await expect(overturnTx)
        .to.emit(arbitration, "AppealResolved")
        .withArgs(1, VoteType.Refund, true); // overturned = true

      // Final dispute status
      const finalDispute = await arbitration.getDispute(1);
      expect(finalDispute.status).to.equal(DisputeStatus.Resolved);
    });

    it("should handle default resolution after timeout when no arbitrators vote", async function () {
      // ── Simulate escrow and create dispute ──
      await mockEscrow.setEscrow(5, buyer.address, seller.address, ESCROW_AMOUNT);
      await arbitration.connect(buyer).createDispute(5);

      // Verify deadline is ~7 days from now
      const dispute = await arbitration.getDispute(1);
      const latest = await time.latest();
      expect(dispute.deadline).to.be.closeTo(latest + SEVEN_DAYS, 5);

      // ── Fast-forward past deadline ──
      await time.increase(SEVEN_DAYS + 100);

      // ── Trigger default resolution (refund to buyer) ──
      const defaultTx = await arbitration.connect(other).triggerDefaultResolution(1);

      await expect(defaultTx)
        .to.emit(arbitration, "DisputeDefaultResolved")
        .withArgs(1, other.address);
      await expect(defaultTx)
        .to.emit(arbitration, "DisputeResolved")
        .withArgs(1, VoteType.Refund, 0, 0);

      const resolved = await arbitration.getDispute(1);
      expect(resolved.status).to.equal(DisputeStatus.DefaultResolved);
    });
  });

  // ════════════════════════════════════════════════════════════════════════
  //  2. ORACLE PRICE CONSENSUS → MULTI-ROUND
  // ════════════════════════════════════════════════════════════════════════

  describe("Oracle Price Consensus → Multi-Round", function () {
    let oracle, mockOmniCore, tokenA;
    let owner, validator1, validator2, validator3, nonValidator;

    const PRICE_1000 = ethers.parseEther("1000");
    const PRICE_1010 = ethers.parseEther("1010");
    const PRICE_1020 = ethers.parseEther("1020");
    const PRICE_1005 = ethers.parseEther("1005");
    const PRICE_1015 = ethers.parseEther("1015");
    const PRICE_1025 = ethers.parseEther("1025");

    beforeEach(async function () {
      [owner, validator1, validator2, validator3, nonValidator] =
        await ethers.getSigners();

      // ── Deploy MockOmniCore ──
      const MockOmniCore = await ethers.getContractFactory("MockOmniCore");
      mockOmniCore = await MockOmniCore.deploy();
      await mockOmniCore.setValidator(validator1.address, true);
      await mockOmniCore.setValidator(validator2.address, true);
      await mockOmniCore.setValidator(validator3.address, true);

      // ── Deploy OmniPriceOracle (UUPS proxy) ──
      const OracleFactory = await ethers.getContractFactory("OmniPriceOracle");
      oracle = await upgrades.deployProxy(
        OracleFactory,
        [await mockOmniCore.getAddress()],
        { initializer: "initialize", kind: "uups" }
      );

      // ── Deploy a mock token to use as the price feed target ──
      const MockERC20 = await ethers.getContractFactory("MockERC20");
      tokenA = await MockERC20.deploy("Token A", "TKA");

      // ── Register the token for tracking ──
      await oracle.registerToken(await tokenA.getAddress());
    });

    it("should reach consensus after 3 validators submit and finalize the round", async function () {
      const tokenAddr = await tokenA.getAddress();

      // Verify token is registered
      expect(await oracle.isRegisteredToken(tokenAddr)).to.be.true;
      expect(await oracle.currentRound(tokenAddr)).to.equal(0);

      // ── Validators submit prices ──
      await expect(oracle.connect(validator1).submitPrice(tokenAddr, PRICE_1000))
        .to.emit(oracle, "PriceSubmitted")
        .withArgs(tokenAddr, validator1.address, PRICE_1000, 0);

      await oracle.connect(validator2).submitPrice(tokenAddr, PRICE_1010);

      // Third submission triggers auto-finalization (minValidators = 3)
      const finalizeTx = await oracle.connect(validator3).submitPrice(tokenAddr, PRICE_1020);

      await expect(finalizeTx)
        .to.emit(oracle, "RoundFinalized");

      // ── Verify consensus price (median of 1000, 1010, 1020 = 1010) ──
      expect(await oracle.latestConsensusPrice(tokenAddr)).to.equal(PRICE_1010);

      // Round advanced to 1
      expect(await oracle.currentRound(tokenAddr)).to.equal(1);

      // ── TWAP should be available ──
      const twap = await oracle.getTWAP(tokenAddr);
      expect(twap).to.be.gt(0);
      // With only one observation, TWAP should equal the consensus price
      expect(twap).to.equal(PRICE_1010);
    });

    it("should reject price submissions from non-validators", async function () {
      const tokenAddr = await tokenA.getAddress();

      await expect(
        oracle.connect(nonValidator).submitPrice(tokenAddr, PRICE_1000)
      ).to.be.revertedWithCustomError(oracle, "NotValidator");
    });

    it("should reject duplicate submission in the same round", async function () {
      const tokenAddr = await tokenA.getAddress();

      await oracle.connect(validator1).submitPrice(tokenAddr, PRICE_1000);
      await expect(
        oracle.connect(validator1).submitPrice(tokenAddr, PRICE_1010)
      ).to.be.revertedWithCustomError(oracle, "AlreadySubmitted");
    });

    it("should compute a different TWAP after a second round with shifted prices", async function () {
      const tokenAddr = await tokenA.getAddress();

      // ── Round 0: prices around 1000-1020, median = 1010 ──
      await oracle.connect(validator1).submitPrice(tokenAddr, PRICE_1000);
      await oracle.connect(validator2).submitPrice(tokenAddr, PRICE_1010);
      await oracle.connect(validator3).submitPrice(tokenAddr, PRICE_1020);

      const twapAfterRound0 = await oracle.getTWAP(tokenAddr);
      expect(twapAfterRound0).to.equal(PRICE_1010);

      // Advance time slightly so the TWAP window catches both observations
      await time.increase(60);

      // ── Round 1: prices around 1005-1025, median = 1015 ──
      await oracle.connect(validator1).submitPrice(tokenAddr, PRICE_1005);
      await oracle.connect(validator2).submitPrice(tokenAddr, PRICE_1015);
      await oracle.connect(validator3).submitPrice(tokenAddr, PRICE_1025);

      // Latest consensus should be the round 1 median
      expect(await oracle.latestConsensusPrice(tokenAddr)).to.equal(PRICE_1015);

      // Round advanced to 2
      expect(await oracle.currentRound(tokenAddr)).to.equal(2);

      // TWAP should now be a weighted average of 1010 and 1015
      const twapAfterRound1 = await oracle.getTWAP(tokenAddr);
      expect(twapAfterRound1).to.be.gt(0);
      // TWAP is time-weighted: the more recent observation (1015) has higher
      // weight, so TWAP should be between 1010 and 1015 (closer to 1015)
      expect(twapAfterRound1).to.be.gte(PRICE_1010);
      expect(twapAfterRound1).to.be.lte(PRICE_1015);
    });

    it("should handle price staleness detection correctly", async function () {
      const tokenAddr = await tokenA.getAddress();

      // No price submitted yet — should be stale
      expect(await oracle.isStale(tokenAddr)).to.be.true;

      // Submit prices to finalize a round
      await oracle.connect(validator1).submitPrice(tokenAddr, PRICE_1000);
      await oracle.connect(validator2).submitPrice(tokenAddr, PRICE_1010);
      await oracle.connect(validator3).submitPrice(tokenAddr, PRICE_1020);

      // Now should not be stale
      expect(await oracle.isStale(tokenAddr)).to.be.false;

      // Advance past the staleness threshold (1 hour)
      await time.increase(3601);

      // Now should be stale
      expect(await oracle.isStale(tokenAddr)).to.be.true;
    });

    it("should reject submissions for unregistered tokens", async function () {
      const fakeToken = ethers.Wallet.createRandom().address;

      await expect(
        oracle.connect(validator1).submitPrice(fakeToken, PRICE_1000)
      ).to.be.revertedWithCustomError(oracle, "ZeroTokenAddress");
    });
  });

  // ════════════════════════════════════════════════════════════════════════
  //  3. ENS REGISTRATION → RESOLUTION
  // ════════════════════════════════════════════════════════════════════════

  describe("ENS Registration → Resolution", function () {
    let ens, xom;
    let owner, oddaoTreasury, user1, user2, user3;

    const MIN_DURATION = 30 * 24 * 60 * 60; // 30 days
    const MAX_DURATION = 365 * 24 * 60 * 60; // 365 days
    const FEE_PER_YEAR = ethers.parseEther("10"); // 10 XOM/year

    beforeEach(async function () {
      [owner, oddaoTreasury, user1, user2, user3] = await ethers.getSigners();

      // ── Deploy MockERC20 (XOM) ──
      const MockERC20 = await ethers.getContractFactory("MockERC20");
      xom = await MockERC20.deploy("OmniCoin", "XOM");
      await xom.waitForDeployment();

      // ── Deploy OmniENS ──
      const OmniENS = await ethers.getContractFactory("OmniENS");
      ens = await OmniENS.deploy(
        await xom.getAddress(),
        oddaoTreasury.address
      );
      await ens.waitForDeployment();

      // ── Fund users ──
      const mintAmount = ethers.parseEther("10000");
      for (const user of [user1, user2, user3]) {
        await xom.mint(user.address, mintAmount);
        await xom.connect(user).approve(await ens.getAddress(), mintAmount);
      }
    });

    it("should register a name, resolve forward, resolve reverse, and collect fee to ODDAO", async function () {
      const name = "alice";
      const duration = MIN_DURATION; // 30 days
      const expectedFee = (FEE_PER_YEAR * BigInt(duration)) / BigInt(MAX_DURATION);

      // Record ODDAO balance before
      const oddaoBalanceBefore = await xom.balanceOf(oddaoTreasury.address);

      // ── Register name ──
      const tx = await ens.connect(user1).register(name, duration);
      await expect(tx).to.emit(ens, "NameRegistered");

      // ── Forward resolution (name → address) ──
      const resolvedAddress = await ens.resolve(name);
      expect(resolvedAddress).to.equal(user1.address);

      // ── Reverse resolution (address → name) ──
      const resolvedName = await ens.reverseResolve(user1.address);
      expect(resolvedName).to.equal(name);

      // ── Verify fee was collected to ODDAO ──
      const oddaoBalanceAfter = await xom.balanceOf(oddaoTreasury.address);
      expect(oddaoBalanceAfter - oddaoBalanceBefore).to.equal(expectedFee);
    });

    it("should prevent duplicate name registration until expiry", async function () {
      const name = "bob";

      await ens.connect(user1).register(name, MIN_DURATION);

      // Second user tries same name — should fail
      await expect(
        ens.connect(user2).register(name, MIN_DURATION)
      ).to.be.revertedWithCustomError(ens, "NameTaken");

      // Fast-forward past expiry
      await time.increase(MIN_DURATION + 1);

      // Name should now resolve to address(0)
      expect(await ens.resolve(name)).to.equal(ethers.ZeroAddress);

      // Should be available
      expect(await ens.isAvailable(name)).to.be.true;

      // Second user can now register
      await expect(
        ens.connect(user2).register(name, MIN_DURATION)
      ).to.not.be.reverted;

      expect(await ens.resolve(name)).to.equal(user2.address);
    });

    it("should support name transfer and update reverse records", async function () {
      const name = "charlie";
      await ens.connect(user1).register(name, MIN_DURATION);

      // ── Transfer from user1 to user2 ──
      await expect(ens.connect(user1).transfer(name, user2.address))
        .to.emit(ens, "NameTransferred")
        .withArgs(name, user1.address, user2.address);

      // Forward resolution now points to user2
      expect(await ens.resolve(name)).to.equal(user2.address);

      // Reverse resolution: user2 should resolve to "charlie"
      expect(await ens.reverseResolve(user2.address)).to.equal(name);

      // user1's reverse record was cleared
      expect(await ens.reverseResolve(user1.address)).to.equal("");
    });

    it("should enforce name validation rules", async function () {
      // Too short (< 3 chars)
      await expect(
        ens.connect(user1).register("ab", MIN_DURATION)
      ).to.be.revertedWithCustomError(ens, "InvalidNameLength");

      // Invalid character (uppercase)
      await expect(
        ens.connect(user1).register("Alice", MIN_DURATION)
      ).to.be.revertedWithCustomError(ens, "InvalidNameCharacter");

      // Leading hyphen
      await expect(
        ens.connect(user1).register("-alice", MIN_DURATION)
      ).to.be.revertedWithCustomError(ens, "InvalidNameCharacter");

      // Trailing hyphen
      await expect(
        ens.connect(user1).register("alice-", MIN_DURATION)
      ).to.be.revertedWithCustomError(ens, "InvalidNameCharacter");

      // Valid name with hyphen in middle
      await expect(
        ens.connect(user1).register("alice-bob", MIN_DURATION)
      ).to.not.be.reverted;
    });

    it("should correctly calculate proportional fees for different durations", async function () {
      const oddaoBalanceBefore = await xom.balanceOf(oddaoTreasury.address);

      // Register for full year (365 days)
      await ens.connect(user1).register("yearlong", MAX_DURATION);

      const oddaoBalanceAfter = await xom.balanceOf(oddaoTreasury.address);
      const feeCollected = oddaoBalanceAfter - oddaoBalanceBefore;

      // Full year should cost exactly 10 XOM (FEE_PER_YEAR)
      expect(feeCollected).to.equal(FEE_PER_YEAR);
    });
  });

  // ════════════════════════════════════════════════════════════════════════
  //  4. CHAT FEE → FREE TIER → PAID TIER
  // ════════════════════════════════════════════════════════════════════════

  describe("Chat Fee → Free Tier → Paid Tier", function () {
    let chatFee, xom;
    let owner, stakingPool, oddaoTreasury, validator1;
    let user1, user2;

    const BASE_FEE = ethers.parseEther("0.001"); // 0.001 XOM per message
    const FREE_TIER_LIMIT = 20;

    beforeEach(async function () {
      [owner, stakingPool, oddaoTreasury, validator1, user1, user2] =
        await ethers.getSigners();

      // ── Deploy MockERC20 (XOM) ──
      const MockERC20 = await ethers.getContractFactory("MockERC20");
      xom = await MockERC20.deploy("OmniCoin", "XOM");
      await xom.waitForDeployment();

      // ── Deploy OmniChatFee ──
      const OmniChatFee = await ethers.getContractFactory("OmniChatFee");
      chatFee = await OmniChatFee.deploy(
        await xom.getAddress(),
        stakingPool.address,
        oddaoTreasury.address,
        BASE_FEE
      );
      await chatFee.waitForDeployment();

      // ── Fund users and approve ──
      const mintAmount = ethers.parseEther("100");
      await xom.mint(user1.address, mintAmount);
      await xom.mint(user2.address, mintAmount);
      await xom.connect(user1).approve(await chatFee.getAddress(), mintAmount);
      await xom.connect(user2).approve(await chatFee.getAddress(), mintAmount);

      // Fund contract for validator claims
      await xom.mint(await chatFee.getAddress(), ethers.parseEther("10"));
    });

    it("should allow 20 free messages with no fee deducted", async function () {
      const channelId = ethers.id("general-chat");
      const userBalanceBefore = await xom.balanceOf(user1.address);

      // ── Send 20 free messages ──
      for (let i = 0; i < FREE_TIER_LIMIT; i++) {
        const tx = await chatFee
          .connect(user1)
          .payMessageFee(channelId, validator1.address);

        if (i < FREE_TIER_LIMIT - 1) {
          await expect(tx)
            .to.emit(chatFee, "FreeMessageUsed")
            .withArgs(
              user1.address,
              channelId,
              i,      // messageIndex
              FREE_TIER_LIMIT - i - 1 // remaining
            );
        } else {
          // Last free message: remaining = 0
          await expect(tx)
            .to.emit(chatFee, "FreeMessageUsed")
            .withArgs(user1.address, channelId, i, 0);
        }
      }

      // ── Verify no XOM was spent ──
      const userBalanceAfter = await xom.balanceOf(user1.address);
      expect(userBalanceAfter).to.equal(userBalanceBefore);

      // ── Verify free tier is exhausted ──
      expect(await chatFee.freeMessagesRemaining(user1.address)).to.equal(0);

      // ── Verify all 20 messages have valid payment proofs ──
      for (let i = 0; i < FREE_TIER_LIMIT; i++) {
        expect(
          await chatFee.hasValidPayment(user1.address, channelId, i)
        ).to.be.true;
      }
    });

    it("should charge the 21st message and distribute fees 70/20/10", async function () {
      const channelId = ethers.id("general-chat");

      // ── Exhaust free tier (20 messages) ──
      for (let i = 0; i < FREE_TIER_LIMIT; i++) {
        await chatFee.connect(user1).payMessageFee(channelId, validator1.address);
      }

      // Record balances before paid message
      const userBalBefore = await xom.balanceOf(user1.address);
      const stakingBalBefore = await xom.balanceOf(stakingPool.address);
      const oddaoBalBefore = await xom.balanceOf(oddaoTreasury.address);
      const validatorPendingBefore = await chatFee.pendingValidatorFees(validator1.address);

      // ── Send 21st message (should be paid) ──
      const paidTx = await chatFee
        .connect(user1)
        .payMessageFee(channelId, validator1.address);

      await expect(paidTx)
        .to.emit(chatFee, "MessageFeePaid")
        .withArgs(
          user1.address,
          channelId,
          FREE_TIER_LIMIT, // messageIndex = 20
          BASE_FEE,
          validator1.address
        );

      // ── Verify fee was deducted from user ──
      const userBalAfter = await xom.balanceOf(user1.address);
      expect(userBalBefore - userBalAfter).to.equal(BASE_FEE);

      // ── Verify 70/20/10 fee distribution ──
      const expectedValidatorShare = (BASE_FEE * 7000n) / 10000n;
      const expectedStakingShare = (BASE_FEE * 2000n) / 10000n;
      const expectedOddaoShare = BASE_FEE - expectedValidatorShare - expectedStakingShare;

      // Validator fee is accumulated (pull pattern)
      const validatorPendingAfter = await chatFee.pendingValidatorFees(validator1.address);
      expect(validatorPendingAfter - validatorPendingBefore).to.equal(expectedValidatorShare);

      // Staking pool received 20%
      const stakingBalAfter = await xom.balanceOf(stakingPool.address);
      expect(stakingBalAfter - stakingBalBefore).to.equal(expectedStakingShare);

      // ODDAO received 10%
      const oddaoBalAfter = await xom.balanceOf(oddaoTreasury.address);
      expect(oddaoBalAfter - oddaoBalBefore).to.equal(expectedOddaoShare);

      // ── Verify payment proof for the 21st message ──
      expect(
        await chatFee.hasValidPayment(user1.address, channelId, FREE_TIER_LIMIT)
      ).to.be.true;
    });

    it("should allow validator to claim accumulated fees", async function () {
      const channelId = ethers.id("support-chat");

      // Exhaust free tier
      for (let i = 0; i < FREE_TIER_LIMIT; i++) {
        await chatFee.connect(user1).payMessageFee(channelId, validator1.address);
      }

      // Send 5 paid messages
      for (let i = 0; i < 5; i++) {
        await chatFee.connect(user1).payMessageFee(channelId, validator1.address);
      }

      // Verify accumulated validator fees
      const expectedValidatorFees = (BASE_FEE * 7000n * 5n) / 10000n;
      expect(await chatFee.pendingValidatorFees(validator1.address)).to.equal(expectedValidatorFees);

      // ── Validator claims fees ──
      const validatorBalBefore = await xom.balanceOf(validator1.address);
      await expect(chatFee.connect(validator1).claimValidatorFees())
        .to.emit(chatFee, "ValidatorFeesClaimed")
        .withArgs(validator1.address, expectedValidatorFees);

      const validatorBalAfter = await xom.balanceOf(validator1.address);
      expect(validatorBalAfter - validatorBalBefore).to.equal(expectedValidatorFees);

      // Pending fees should be zero after claim
      expect(await chatFee.pendingValidatorFees(validator1.address)).to.equal(0);
    });

    it("should track separate free tier counts for different users", async function () {
      const channelId = ethers.id("marketplace-chat");

      // user1 sends 10 messages
      for (let i = 0; i < 10; i++) {
        await chatFee.connect(user1).payMessageFee(channelId, validator1.address);
      }

      // user2 sends 5 messages
      for (let i = 0; i < 5; i++) {
        await chatFee.connect(user2).payMessageFee(channelId, validator1.address);
      }

      // Both should still have free messages remaining
      expect(await chatFee.freeMessagesRemaining(user1.address)).to.equal(10);
      expect(await chatFee.freeMessagesRemaining(user2.address)).to.equal(15);
    });

    it("should charge 10x fee for bulk messages regardless of free tier", async function () {
      const channelId = ethers.id("broadcast-channel");

      const userBalBefore = await xom.balanceOf(user1.address);

      // Bulk message always costs 10x base fee (even if free tier is available)
      const expectedBulkFee = BASE_FEE * 10n;

      await expect(
        chatFee.connect(user1).payBulkMessageFee(channelId, validator1.address)
      )
        .to.emit(chatFee, "MessageFeePaid")
        .withArgs(user1.address, channelId, 0, expectedBulkFee, validator1.address);

      const userBalAfter = await xom.balanceOf(user1.address);
      expect(userBalBefore - userBalAfter).to.equal(expectedBulkFee);
    });

    it("should reject zero channel ID", async function () {
      await expect(
        chatFee.connect(user1).payMessageFee(ethers.ZeroHash, validator1.address)
      ).to.be.revertedWithCustomError(chatFee, "InvalidChannelId");
    });

    it("should reject zero validator address", async function () {
      const channelId = ethers.id("test-channel");
      await expect(
        chatFee.connect(user1).payMessageFee(channelId, ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(chatFee, "ZeroChatAddress");
    });
  });

  // ════════════════════════════════════════════════════════════════════════
  //  5. CROSS-SYSTEM: Oracle + Marketplace + ENS + Chat Working Together
  // ════════════════════════════════════════════════════════════════════════

  describe("Cross-System Integration: Multiple Trustless Contracts", function () {
    let marketplace, oracle, ens, chatFee, xom, mockOmniCore;
    let owner, oddaoTreasury, stakingPool;
    let validator1, validator2, validator3;
    let user1, user2;

    const BASE_FEE = ethers.parseEther("0.001");
    const MIN_DURATION = 30 * 24 * 60 * 60;
    const LISTING_PRICE = ethers.parseEther("100");

    beforeEach(async function () {
      const signers = await ethers.getSigners();
      owner = signers[0];
      oddaoTreasury = signers[1];
      stakingPool = signers[2];
      validator1 = signers[3];
      validator2 = signers[4];
      validator3 = signers[5];
      user1 = signers[6];
      user2 = signers[7];

      // ── Deploy MockERC20 (XOM) ──
      const MockERC20 = await ethers.getContractFactory("MockERC20");
      xom = await MockERC20.deploy("OmniCoin", "XOM");

      // ── Deploy MockOmniCore ──
      const MockOmniCore = await ethers.getContractFactory("MockOmniCore");
      mockOmniCore = await MockOmniCore.deploy();
      await mockOmniCore.setValidator(validator1.address, true);
      await mockOmniCore.setValidator(validator2.address, true);
      await mockOmniCore.setValidator(validator3.address, true);

      // ── Deploy OmniMarketplace ──
      const MarketplaceFactory = await ethers.getContractFactory("OmniMarketplace");
      marketplace = await upgrades.deployProxy(MarketplaceFactory, [], {
        initializer: "initialize",
        kind: "uups",
      });

      // ── Deploy OmniPriceOracle ──
      const OracleFactory = await ethers.getContractFactory("OmniPriceOracle");
      oracle = await upgrades.deployProxy(
        OracleFactory,
        [await mockOmniCore.getAddress()],
        { initializer: "initialize", kind: "uups" }
      );

      // ── Deploy OmniENS ──
      const OmniENS = await ethers.getContractFactory("OmniENS");
      ens = await OmniENS.deploy(
        await xom.getAddress(),
        oddaoTreasury.address
      );

      // ── Deploy OmniChatFee ──
      const OmniChatFee = await ethers.getContractFactory("OmniChatFee");
      chatFee = await OmniChatFee.deploy(
        await xom.getAddress(),
        stakingPool.address,
        oddaoTreasury.address,
        BASE_FEE
      );

      // ── Fund users ──
      const mintAmount = ethers.parseEther("100000");
      for (const user of [user1, user2]) {
        await xom.mint(user.address, mintAmount);
        await xom.connect(user).approve(await ens.getAddress(), mintAmount);
        await xom.connect(user).approve(await chatFee.getAddress(), mintAmount);
      }

      // Fund chat contract for validator claims
      await xom.mint(await chatFee.getAddress(), ethers.parseEther("100"));
    });

    it("should support user registering an ENS name, creating a listing, chatting about it, and receiving an oracle price", async function () {
      // ── Step 1: User1 registers an ENS name ──
      await ens.connect(user1).register("seller-alice", MIN_DURATION);
      expect(await ens.resolve("seller-alice")).to.equal(user1.address);
      expect(await ens.reverseResolve(user1.address)).to.equal("seller-alice");

      // ── Step 2: User1 creates a marketplace listing ──
      const ipfsCID = randomBytes32();
      const contentHash = randomBytes32();
      await marketplace
        .connect(user1)
        .registerListingDirect(ipfsCID, contentHash, LISTING_PRICE, 0);

      expect(await marketplace.isListingValid(1)).to.be.true;
      expect(await marketplace.listingCount(user1.address)).to.equal(1);

      // ── Step 3: User2 sends chat messages about the listing ──
      const channelId = ethers.id("dm-alice-bob");
      for (let i = 0; i < 5; i++) {
        await chatFee.connect(user2).payMessageFee(channelId, validator1.address);
      }
      expect(await chatFee.freeMessagesRemaining(user2.address)).to.equal(15);

      // ── Step 4: Oracle provides price data for the XOM token ──
      // Register the XOM token address in the oracle
      const xomAddr = await xom.getAddress();
      await oracle.registerToken(xomAddr);

      // 3 validators submit prices
      const price1 = ethers.parseEther("0.05");
      const price2 = ethers.parseEther("0.051");
      const price3 = ethers.parseEther("0.049");

      await oracle.connect(validator1).submitPrice(xomAddr, price1);
      await oracle.connect(validator2).submitPrice(xomAddr, price2);
      await oracle.connect(validator3).submitPrice(xomAddr, price3);

      // Consensus should be median = 0.05
      const consensus = await oracle.latestConsensusPrice(xomAddr);
      expect(consensus).to.equal(price1); // median of [0.049, 0.05, 0.051] = 0.05

      // ── Step 5: Verify all systems report consistent state ──
      expect(await ens.resolve("seller-alice")).to.equal(user1.address);
      expect(await marketplace.isListingValid(1)).to.be.true;
      expect(await chatFee.freeMessagesRemaining(user2.address)).to.equal(15);
      expect(await oracle.isStale(xomAddr)).to.be.false;
    });

    it("should isolate failures: pausing marketplace does not affect ENS or chat", async function () {
      // Pause marketplace
      await marketplace.connect(owner).pause();

      // ENS should still work
      await expect(
        ens.connect(user1).register("still-works", MIN_DURATION)
      ).to.not.be.reverted;

      // Chat should still work
      const channelId = ethers.id("unaffected-chat");
      await expect(
        chatFee.connect(user1).payMessageFee(channelId, validator1.address)
      ).to.not.be.reverted;

      // Oracle should still work
      const xomAddr = await xom.getAddress();
      await oracle.registerToken(xomAddr);
      await expect(
        oracle.connect(validator1).submitPrice(xomAddr, ethers.parseEther("1"))
      ).to.not.be.reverted;

      // Marketplace is paused
      await expect(
        marketplace
          .connect(user1)
          .registerListingDirect(randomBytes32(), randomBytes32(), LISTING_PRICE, 0)
      ).to.be.revertedWithCustomError(marketplace, "EnforcedPause");
    });
  });
});
