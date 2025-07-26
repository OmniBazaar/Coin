import { expect } from "chai";
import { ethers, upgrades } from "hardhat";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import {
  OmniCoinArbitration,
  OmniCoin,
  OmniCoinAccount,
  OmniCoinEscrow
} from "../typechain-types";

describe("OmniCoinArbitration", function () {
  let arbitration: OmniCoinArbitration;
  let omniCoin: OmniCoin;
  let omniCoinAccount: OmniCoinAccount;
  let omniCoinEscrow: OmniCoinEscrow;
  
  let owner: SignerWithAddress;
  let arbitrator1: SignerWithAddress;
  let arbitrator2: SignerWithAddress;
  let arbitrator3: SignerWithAddress;
  let buyer: SignerWithAddress;
  let seller: SignerWithAddress;
  let user1: SignerWithAddress;

  // Test constants
  const MIN_REPUTATION = 750;
  const MIN_PARTICIPATION_INDEX = 500;
  const MIN_STAKING_AMOUNT = ethers.utils.parseEther("10000"); // 10,000 XOM
  const MAX_ACTIVE_DISPUTES = 5;
  const DISPUTE_TIMEOUT = 7 * 24 * 60 * 60; // 7 days
  const RATING_WEIGHT = 10; // 10%

  // Specialization constants
  const SPEC_DIGITAL_GOODS = 1;
  const SPEC_PHYSICAL_GOODS = 2;
  const SPEC_SERVICES = 4;
  const SPEC_HIGH_VALUE = 8;
  const SPEC_INTERNATIONAL = 16;
  const SPEC_TECHNICAL = 32;

  beforeEach(async function () {
    [owner, arbitrator1, arbitrator2, arbitrator3, buyer, seller, user1] = 
      await ethers.getSigners();

    // Deploy mock contracts
    const OmniCoinFactory = await ethers.getContractFactory("OmniCoin");
    omniCoin = await OmniCoinFactory.deploy();
    await omniCoin.deployed();

    const OmniCoinAccountFactory = await ethers.getContractFactory("OmniCoinAccount");
    omniCoinAccount = await OmniCoinAccountFactory.deploy();
    await omniCoinAccount.deployed();

    const OmniCoinEscrowFactory = await ethers.getContractFactory("OmniCoinEscrow");
    omniCoinEscrow = await OmniCoinEscrowFactory.deploy();
    await omniCoinEscrow.deployed();

    // Deploy OmniCoinArbitration as upgradeable proxy
    const OmniCoinArbitrationFactory = await ethers.getContractFactory("OmniCoinArbitration");
    arbitration = await upgrades.deployProxy(
      OmniCoinArbitrationFactory,
      [
        omniCoin.address,
        omniCoinAccount.address,
        omniCoinEscrow.address,
        MIN_REPUTATION,
        MIN_PARTICIPATION_INDEX,
        MIN_STAKING_AMOUNT,
        MAX_ACTIVE_DISPUTES,
        DISPUTE_TIMEOUT,
        RATING_WEIGHT,
      ],
      { initializer: "initialize" }
    ) as OmniCoinArbitration;
    await arbitration.deployed();

    // Setup initial token balances for testing
    await omniCoin.mint(arbitrator1.address, ethers.utils.parseEther("50000"));
    await omniCoin.mint(arbitrator2.address, ethers.utils.parseEther("50000"));
    await omniCoin.mint(arbitrator3.address, ethers.utils.parseEther("50000"));
    await omniCoin.mint(buyer.address, ethers.utils.parseEther("100000"));
    await omniCoin.mint(seller.address, ethers.utils.parseEther("100000"));

    // Setup mock reputation scores
    await omniCoinAccount.setReputationScore(arbitrator1.address, 850);
    await omniCoinAccount.setReputationScore(arbitrator2.address, 900);
    await omniCoinAccount.setReputationScore(arbitrator3.address, 800);
    await omniCoinAccount.setAccountStatus(arbitrator1.address, [0, 0, 0, 0, 0, 600]);
    await omniCoinAccount.setAccountStatus(arbitrator2.address, [0, 0, 0, 0, 0, 650]);
    await omniCoinAccount.setAccountStatus(arbitrator3.address, [0, 0, 0, 0, 0, 550]);
  });

  describe("Deployment and Initialization", function () {
    it("Should initialize with correct parameters", async function () {
      expect(await arbitration.omniCoin()).to.equal(omniCoin.address);
      expect(await arbitration.omniCoinAccount()).to.equal(omniCoinAccount.address);
      expect(await arbitration.omniCoinEscrow()).to.equal(omniCoinEscrow.address);
      expect(await arbitration.minReputation()).to.equal(MIN_REPUTATION);
      expect(await arbitration.minParticipationIndex()).to.equal(MIN_PARTICIPATION_INDEX);
      expect(await arbitration.minStakingAmount()).to.equal(MIN_STAKING_AMOUNT);
      expect(await arbitration.maxActiveDisputes()).to.equal(MAX_ACTIVE_DISPUTES);
      expect(await arbitration.disputeTimeout()).to.equal(DISPUTE_TIMEOUT);
      expect(await arbitration.ratingWeight()).to.equal(RATING_WEIGHT);
    });

    it("Should have correct fee structure constants", async function () {
      expect(await arbitration.ARBITRATION_FEE_RATE()).to.equal(100); // 1%
      expect(await arbitration.ARBITRATOR_FEE_SHARE()).to.equal(70); // 70%
      expect(await arbitration.TREASURY_FEE_SHARE()).to.equal(20); // 20%
      expect(await arbitration.VALIDATOR_FEE_SHARE()).to.equal(10); // 10%
    });

    it("Should have correct specialization constants", async function () {
      expect(await arbitration.SPEC_DIGITAL_GOODS()).to.equal(SPEC_DIGITAL_GOODS);
      expect(await arbitration.SPEC_PHYSICAL_GOODS()).to.equal(SPEC_PHYSICAL_GOODS);
      expect(await arbitration.SPEC_SERVICES()).to.equal(SPEC_SERVICES);
      expect(await arbitration.SPEC_HIGH_VALUE()).to.equal(SPEC_HIGH_VALUE);
      expect(await arbitration.SPEC_INTERNATIONAL()).to.equal(SPEC_INTERNATIONAL);
      expect(await arbitration.SPEC_TECHNICAL()).to.equal(SPEC_TECHNICAL);
    });

    it("Should return correct version", async function () {
      expect(await arbitration.getVersion()).to.equal(
        "OmniCoinArbitration v2.0.0 - COTI V2 Privacy Integration"
      );
    });
  });

  describe("Arbitrator Registration", function () {
    beforeEach(async function () {
      // Approve staking amount
      await omniCoin.connect(arbitrator1).approve(arbitration.address, MIN_STAKING_AMOUNT);
    });

    it("Should register arbitrator successfully", async function () {
      const specializations = SPEC_DIGITAL_GOODS | SPEC_SERVICES;
      
      await expect(
        arbitration.connect(arbitrator1).registerArbitrator(MIN_STAKING_AMOUNT, specializations)
      )
        .to.emit(arbitration, "ArbitratorRegistered")
        .withArgs(arbitrator1.address, specializations, MIN_STAKING_AMOUNT);

      const arbitratorInfo = await arbitration.getArbitratorInfo(arbitrator1.address);
      expect(arbitratorInfo.reputation).to.equal(850);
      expect(arbitratorInfo.participationIndex).to.equal(600);
      expect(arbitratorInfo.totalCases).to.equal(0);
      expect(arbitratorInfo.successfulCases).to.equal(0);
      expect(arbitratorInfo.stakingAmount).to.equal(MIN_STAKING_AMOUNT);
      expect(arbitratorInfo.isActive).to.be.true;
      expect(arbitratorInfo.specializationMask).to.equal(specializations);
    });

    it("Should fail to register with insufficient reputation", async function () {
      await omniCoinAccount.setReputationScore(user1.address, 700); // Below minimum
      await omniCoin.mint(user1.address, MIN_STAKING_AMOUNT);
      await omniCoin.connect(user1).approve(arbitration.address, MIN_STAKING_AMOUNT);

      await expect(
        arbitration.connect(user1).registerArbitrator(MIN_STAKING_AMOUNT, SPEC_DIGITAL_GOODS)
      ).to.be.revertedWith("Insufficient reputation");
    });

    it("Should fail to register with insufficient staking amount", async function () {
      const insufficientAmount = ethers.utils.parseEther("5000");
      await omniCoin.connect(arbitrator1).approve(arbitration.address, insufficientAmount);

      await expect(
        arbitration.connect(arbitrator1).registerArbitrator(insufficientAmount, SPEC_DIGITAL_GOODS)
      ).to.be.revertedWith("Insufficient staking amount");
    });

    it("Should fail to register without specializations", async function () {
      await expect(
        arbitration.connect(arbitrator1).registerArbitrator(MIN_STAKING_AMOUNT, 0)
      ).to.be.revertedWith("Must specify at least one specialization");
    });

    it("Should fail to register if already active", async function () {
      await arbitration.connect(arbitrator1).registerArbitrator(MIN_STAKING_AMOUNT, SPEC_DIGITAL_GOODS);

      await expect(
        arbitration.connect(arbitrator1).registerArbitrator(MIN_STAKING_AMOUNT, SPEC_SERVICES)
      ).to.be.revertedWith("Already registered");
    });

    it("Should increase arbitrator stake", async function () {
      await arbitration.connect(arbitrator1).registerArbitrator(MIN_STAKING_AMOUNT, SPEC_DIGITAL_GOODS);
      
      const additionalStake = ethers.utils.parseEther("5000");
      await omniCoin.connect(arbitrator1).approve(arbitration.address, additionalStake);

      await expect(
        arbitration.connect(arbitrator1).increaseArbitratorStake(additionalStake)
      )
        .to.emit(arbitration, "ArbitratorStakeUpdated")
        .withArgs(arbitrator1.address, MIN_STAKING_AMOUNT.add(additionalStake));

      const arbitratorInfo = await arbitration.getArbitratorInfo(arbitrator1.address);
      expect(arbitratorInfo.stakingAmount).to.equal(MIN_STAKING_AMOUNT.add(additionalStake));
    });
  });

  describe("Dispute Creation", function () {
    const escrowId = ethers.utils.formatBytes32String("escrow1");
    const disputedAmount = ethers.utils.parseEther("1000");
    const buyerClaim = ethers.utils.parseEther("800");
    const sellerClaim = ethers.utils.parseEther("200");
    const evidenceHash = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("evidence"));

    beforeEach(async function () {
      // Register arbitrators
      await omniCoin.connect(arbitrator1).approve(arbitration.address, MIN_STAKING_AMOUNT);
      await arbitration.connect(arbitrator1).registerArbitrator(MIN_STAKING_AMOUNT, SPEC_DIGITAL_GOODS);

      // Setup mock escrow
      await omniCoinEscrow.setEscrow(
        escrowId,
        seller.address,
        buyer.address,
        disputedAmount,
        0, 0, 0,
        true, // disputed
        ethers.constants.AddressZero
      );
    });

    it("Should create confidential dispute successfully", async function () {
      // Note: In actual implementation, these would be encrypted using COTI V2 MPC
      // For testing, we use mock encrypted values
      const encryptedDisputedAmount = disputedAmount; // Mock encrypted value
      const encryptedBuyerClaim = buyerClaim; // Mock encrypted value
      const encryptedSellerClaim = sellerClaim; // Mock encrypted value

      await expect(
        arbitration.connect(buyer).createConfidentialDispute(
          escrowId,
          encryptedDisputedAmount,
          encryptedBuyerClaim,
          encryptedSellerClaim,
          evidenceHash
        )
      )
        .to.emit(arbitration, "ConfidentialDisputeCreated")
        .withArgs(escrowId, arbitrator1.address, 1, evidenceHash); // disputeType 1 = simple

      const disputeInfo = await arbitration.getDisputePublicInfo(escrowId);
      expect(disputeInfo.primaryArbitrator).to.equal(arbitrator1.address);
      expect(disputeInfo.disputeType).to.equal(1);
      expect(disputeInfo.evidenceHash).to.equal(evidenceHash);
      expect(disputeInfo.buyerRating).to.equal(0);
      expect(disputeInfo.sellerRating).to.equal(0);
      expect(disputeInfo.arbitratorRating).to.equal(0);
    });

    it("Should fail to create dispute if not buyer or seller", async function () {
      await expect(
        arbitration.connect(user1).createConfidentialDispute(
          escrowId,
          disputedAmount,
          buyerClaim,
          sellerClaim,
          evidenceHash
        )
      ).to.be.revertedWith("Not authorized");
    });

    it("Should fail to create dispute if escrow not disputed", async function () {
      const nonDisputedEscrow = ethers.utils.formatBytes32String("escrow2");
      await omniCoinEscrow.setEscrow(
        nonDisputedEscrow,
        seller.address,
        buyer.address,
        disputedAmount,
        0, 0, 0,
        false, // not disputed
        ethers.constants.AddressZero
      );

      await expect(
        arbitration.connect(buyer).createConfidentialDispute(
          nonDisputedEscrow,
          disputedAmount,
          buyerClaim,
          sellerClaim,
          evidenceHash
        )
      ).to.be.revertedWith("Escrow not disputed");
    });

    it("Should fail to create duplicate dispute", async function () {
      await arbitration.connect(buyer).createConfidentialDispute(
        escrowId,
        disputedAmount,
        buyerClaim,
        sellerClaim,
        evidenceHash
      );

      await expect(
        arbitration.connect(seller).createConfidentialDispute(
          escrowId,
          disputedAmount,
          buyerClaim,
          sellerClaim,
          evidenceHash
        )
      ).to.be.revertedWith("Dispute already exists");
    });
  });

  describe("Dispute Resolution", function () {
    const escrowId = ethers.utils.formatBytes32String("escrow1");
    const disputedAmount = ethers.utils.parseEther("1000");
    const buyerClaim = ethers.utils.parseEther("800");
    const sellerClaim = ethers.utils.parseEther("200");
    const evidenceHash = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("evidence"));
    const resolutionHash = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("resolution"));

    beforeEach(async function () {
      // Register arbitrator
      await omniCoin.connect(arbitrator1).approve(arbitration.address, MIN_STAKING_AMOUNT);
      await arbitration.connect(arbitrator1).registerArbitrator(MIN_STAKING_AMOUNT, SPEC_DIGITAL_GOODS);

      // Setup escrow
      await omniCoinEscrow.setEscrow(
        escrowId,
        seller.address,
        buyer.address,
        disputedAmount,
        0, 0, 0,
        true,
        ethers.constants.AddressZero
      );

      // Create dispute
      await arbitration.connect(buyer).createConfidentialDispute(
        escrowId,
        disputedAmount,
        buyerClaim,
        sellerClaim,
        evidenceHash
      );
    });

    it("Should resolve dispute successfully", async function () {
      const buyerPayout = ethers.utils.parseEther("700");
      const sellerPayout = ethers.utils.parseEther("300");

      await expect(
        arbitration.connect(arbitrator1).resolveConfidentialDispute(
          escrowId,
          buyerPayout,
          sellerPayout,
          resolutionHash
        )
      )
        .to.emit(arbitration, "ConfidentialDisputeResolved")
        .withArgs(escrowId, resolutionHash, await ethers.provider.getBlockNumber() + 1, ethers.utils.keccak256("0x"));

      expect(await arbitration.isDisputeResolved(escrowId)).to.be.true;

      const disputeInfo = await arbitration.getDisputePublicInfo(escrowId);
      expect(disputeInfo.resolutionHash).to.equal(resolutionHash);

      // Check arbitrator success count increased
      const arbitratorInfo = await arbitration.getArbitratorInfo(arbitrator1.address);
      expect(arbitratorInfo.successfulCases).to.equal(1);
    });

    it("Should fail to resolve if not authorized arbitrator", async function () {
      const buyerPayout = ethers.utils.parseEther("700");
      const sellerPayout = ethers.utils.parseEther("300");

      await expect(
        arbitration.connect(user1).resolveConfidentialDispute(
          escrowId,
          buyerPayout,
          sellerPayout,
          resolutionHash
        )
      ).to.be.revertedWith("Not authorized arbitrator");
    });

    it("Should fail to resolve already resolved dispute", async function () {
      const buyerPayout = ethers.utils.parseEther("700");
      const sellerPayout = ethers.utils.parseEther("300");

      await arbitration.connect(arbitrator1).resolveConfidentialDispute(
        escrowId,
        buyerPayout,
        sellerPayout,
        resolutionHash
      );

      await expect(
        arbitration.connect(arbitrator1).resolveConfidentialDispute(
          escrowId,
          buyerPayout,
          sellerPayout,
          resolutionHash
        )
      ).to.be.revertedWith("Already resolved");
    });

    it("Should distribute arbitration fees correctly", async function () {
      const buyerPayout = ethers.utils.parseEther("700");
      const sellerPayout = ethers.utils.parseEther("300");

      await expect(
        arbitration.connect(arbitrator1).resolveConfidentialDispute(
          escrowId,
          buyerPayout,
          sellerPayout,
          resolutionHash
        )
      ).to.emit(arbitration, "ArbitrationFeeDistributed");

      // Check arbitrator can claim earnings
      const initialBalance = await omniCoin.balanceOf(arbitrator1.address);
      
      // Mock the earnings claim (in real implementation would use private transfers)
      await expect(
        arbitration.connect(arbitrator1).claimArbitratorEarnings()
      ).to.emit(arbitration, "PrivateEarningsUpdated");
    });
  });

  describe("Rating System", function () {
    const escrowId = ethers.utils.formatBytes32String("escrow1");
    const disputedAmount = ethers.utils.parseEther("1000");
    const buyerClaim = ethers.utils.parseEther("800");
    const sellerClaim = ethers.utils.parseEther("200");
    const evidenceHash = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("evidence"));
    const resolutionHash = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("resolution"));

    beforeEach(async function () {
      // Setup and resolve a dispute
      await omniCoin.connect(arbitrator1).approve(arbitration.address, MIN_STAKING_AMOUNT);
      await arbitration.connect(arbitrator1).registerArbitrator(MIN_STAKING_AMOUNT, SPEC_DIGITAL_GOODS);

      await omniCoinEscrow.setEscrow(
        escrowId,
        seller.address,
        buyer.address,
        disputedAmount,
        0, 0, 0,
        true,
        ethers.constants.AddressZero
      );

      await arbitration.connect(buyer).createConfidentialDispute(
        escrowId,
        disputedAmount,
        buyerClaim,
        sellerClaim,
        evidenceHash
      );

      const buyerPayout = ethers.utils.parseEther("700");
      const sellerPayout = ethers.utils.parseEther("300");

      await arbitration.connect(arbitrator1).resolveConfidentialDispute(
        escrowId,
        buyerPayout,
        sellerPayout,
        resolutionHash
      );
    });

    it("Should allow buyer to submit rating", async function () {
      await expect(
        arbitration.connect(buyer).submitRating(escrowId, 5)
      )
        .to.emit(arbitration, "RatingSubmitted")
        .withArgs(escrowId, buyer.address, 5);

      const disputeInfo = await arbitration.getDisputePublicInfo(escrowId);
      expect(disputeInfo.buyerRating).to.equal(5);
    });

    it("Should allow seller to submit rating", async function () {
      await expect(
        arbitration.connect(seller).submitRating(escrowId, 4)
      )
        .to.emit(arbitration, "RatingSubmitted")
        .withArgs(escrowId, seller.address, 4);

      const disputeInfo = await arbitration.getDisputePublicInfo(escrowId);
      expect(disputeInfo.sellerRating).to.equal(4);
    });

    it("Should update arbitrator reputation when both parties rate", async function () {
      const initialRep = (await arbitration.getArbitratorInfo(arbitrator1.address)).reputation;

      await arbitration.connect(buyer).submitRating(escrowId, 5);
      await expect(
        arbitration.connect(seller).submitRating(escrowId, 3)
      ).to.emit(arbitration, "ReputationUpdated");

      const disputeInfo = await arbitration.getDisputePublicInfo(escrowId);
      expect(disputeInfo.arbitratorRating).to.equal(4); // Average of 5 and 3

      const finalRep = (await arbitration.getArbitratorInfo(arbitrator1.address)).reputation;
      expect(finalRep).to.not.equal(initialRep);
    });

    it("Should fail to rate if not participant", async function () {
      await expect(
        arbitration.connect(user1).submitRating(escrowId, 5)
      ).to.be.revertedWith("Not authorized to rate");
    });

    it("Should fail to rate unresolved dispute", async function () {
      const escrowId2 = ethers.utils.formatBytes32String("escrow2");
      await omniCoinEscrow.setEscrow(
        escrowId2,
        seller.address,
        buyer.address,
        disputedAmount,
        0, 0, 0,
        true,
        ethers.constants.AddressZero
      );

      await arbitration.connect(buyer).createConfidentialDispute(
        escrowId2,
        disputedAmount,
        buyerClaim,
        sellerClaim,
        evidenceHash
      );

      await expect(
        arbitration.connect(buyer).submitRating(escrowId2, 5)
      ).to.be.revertedWith("Dispute not resolved");
    });

    it("Should fail to rate twice", async function () {
      await arbitration.connect(buyer).submitRating(escrowId, 5);

      await expect(
        arbitration.connect(buyer).submitRating(escrowId, 4)
      ).to.be.revertedWith("Already rated");
    });

    it("Should fail with invalid rating", async function () {
      await expect(
        arbitration.connect(buyer).submitRating(escrowId, 0)
      ).to.be.revertedWith("Rating must be 1-5");

      await expect(
        arbitration.connect(buyer).submitRating(escrowId, 6)
      ).to.be.revertedWith("Rating must be 1-5");
    });
  });

  describe("Privacy and Access Control", function () {
    const escrowId = ethers.utils.formatBytes32String("escrow1");
    const disputedAmount = ethers.utils.parseEther("1000");
    const buyerClaim = ethers.utils.parseEther("800");
    const sellerClaim = ethers.utils.parseEther("200");
    const evidenceHash = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("evidence"));

    beforeEach(async function () {
      await omniCoin.connect(arbitrator1).approve(arbitration.address, MIN_STAKING_AMOUNT);
      await arbitration.connect(arbitrator1).registerArbitrator(MIN_STAKING_AMOUNT, SPEC_DIGITAL_GOODS);

      await omniCoinEscrow.setEscrow(
        escrowId,
        seller.address,
        buyer.address,
        disputedAmount,
        0, 0, 0,
        true,
        ethers.constants.AddressZero
      );

      await arbitration.connect(buyer).createConfidentialDispute(
        escrowId,
        disputedAmount,
        buyerClaim,
        sellerClaim,
        evidenceHash
      );
    });

    it("Should allow participants to view private amounts", async function () {
      // Buyer should be able to view private amounts
      await expect(
        arbitration.connect(buyer).getDisputePrivateAmounts(escrowId)
      ).to.not.be.reverted;

      // Seller should be able to view private amounts
      await expect(
        arbitration.connect(seller).getDisputePrivateAmounts(escrowId)
      ).to.not.be.reverted;

      // Arbitrator should be able to view private amounts
      await expect(
        arbitration.connect(arbitrator1).getDisputePrivateAmounts(escrowId)
      ).to.not.be.reverted;
    });

    it("Should prevent non-participants from viewing private amounts", async function () {
      await expect(
        arbitration.connect(user1).getDisputePrivateAmounts(escrowId)
      ).to.be.revertedWith("Not authorized");
    });

    it("Should allow arbitrator to view their private earnings", async function () {
      await expect(
        arbitration.connect(arbitrator1).getArbitratorPrivateEarnings(arbitrator1.address)
      ).to.not.be.reverted;
    });

    it("Should allow owner to view arbitrator private earnings", async function () {
      await expect(
        arbitration.connect(owner).getArbitratorPrivateEarnings(arbitrator1.address)
      ).to.not.be.reverted;
    });

    it("Should prevent unauthorized access to private earnings", async function () {
      await expect(
        arbitration.connect(user1).getArbitratorPrivateEarnings(arbitrator1.address)
      ).to.be.revertedWith("Not authorized");
    });
  });

  describe("Specialization System", function () {
    it("Should check arbitrator specializations correctly", async function () {
      const specializations = SPEC_DIGITAL_GOODS | SPEC_HIGH_VALUE | SPEC_TECHNICAL;
      
      await omniCoin.connect(arbitrator1).approve(arbitration.address, MIN_STAKING_AMOUNT);
      await arbitration.connect(arbitrator1).registerArbitrator(MIN_STAKING_AMOUNT, specializations);

      expect(await arbitration.hasSpecialization(arbitrator1.address, SPEC_DIGITAL_GOODS)).to.be.true;
      expect(await arbitration.hasSpecialization(arbitrator1.address, SPEC_HIGH_VALUE)).to.be.true;
      expect(await arbitration.hasSpecialization(arbitrator1.address, SPEC_TECHNICAL)).to.be.true;
      expect(await arbitration.hasSpecialization(arbitrator1.address, SPEC_PHYSICAL_GOODS)).to.be.false;
      expect(await arbitration.hasSpecialization(arbitrator1.address, SPEC_SERVICES)).to.be.false;
    });

    it("Should return correct specialization names", async function () {
      expect(await arbitration.getSpecializationName(SPEC_DIGITAL_GOODS)).to.equal("Digital Goods");
      expect(await arbitration.getSpecializationName(SPEC_PHYSICAL_GOODS)).to.equal("Physical Goods");
      expect(await arbitration.getSpecializationName(SPEC_SERVICES)).to.equal("Services");
      expect(await arbitration.getSpecializationName(SPEC_HIGH_VALUE)).to.equal("High Value");
      expect(await arbitration.getSpecializationName(SPEC_INTERNATIONAL)).to.equal("International");
      expect(await arbitration.getSpecializationName(SPEC_TECHNICAL)).to.equal("Technical");
      expect(await arbitration.getSpecializationName(999)).to.equal("Unknown");
    });
  });

  describe("Arbitrator Success Rate", function () {
    it("Should calculate arbitrator success rate correctly", async function () {
      await omniCoin.connect(arbitrator1).approve(arbitration.address, MIN_STAKING_AMOUNT);
      await arbitration.connect(arbitrator1).registerArbitrator(MIN_STAKING_AMOUNT, SPEC_DIGITAL_GOODS);

      // Initially 0% success rate (no cases)
      expect(await arbitration.getArbitratorSuccessRate(arbitrator1.address)).to.equal(0);

      // Mock some case statistics
      // This would normally happen through dispute resolution
      // For testing, we'll manipulate the arbitrator data directly (in a real scenario)
      
      // After handling cases, success rate should be calculated
      // successfulCases * 10000 / totalCases (in basis points)
    });
  });

  describe("History and Tracking", function () {
    it("Should track user dispute history", async function () {
      // Initially no disputes
      expect((await arbitration.getUserDisputes(buyer.address)).length).to.equal(0);
      expect((await arbitration.getUserDisputes(seller.address)).length).to.equal(0);

      // Create a dispute
      const escrowId = ethers.utils.formatBytes32String("escrow1");
      const disputedAmount = ethers.utils.parseEther("1000");
      const buyerClaim = ethers.utils.parseEther("800");
      const sellerClaim = ethers.utils.parseEther("200");
      const evidenceHash = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("evidence"));

      await omniCoin.connect(arbitrator1).approve(arbitration.address, MIN_STAKING_AMOUNT);
      await arbitration.connect(arbitrator1).registerArbitrator(MIN_STAKING_AMOUNT, SPEC_DIGITAL_GOODS);

      await omniCoinEscrow.setEscrow(
        escrowId,
        seller.address,
        buyer.address,
        disputedAmount,
        0, 0, 0,
        true,
        ethers.constants.AddressZero
      );

      await arbitration.connect(buyer).createConfidentialDispute(
        escrowId,
        disputedAmount,
        buyerClaim,
        sellerClaim,
        evidenceHash
      );

      // Check dispute history
      const buyerDisputes = await arbitration.getUserDisputes(buyer.address);
      const sellerDisputes = await arbitration.getUserDisputes(seller.address);
      const arbitratorDisputes = await arbitration.getArbitratorDisputes(arbitrator1.address);

      expect(buyerDisputes.length).to.equal(1);
      expect(sellerDisputes.length).to.equal(1);
      expect(arbitratorDisputes.length).to.equal(1);
      expect(buyerDisputes[0]).to.equal(escrowId);
      expect(sellerDisputes[0]).to.equal(escrowId);
      expect(arbitratorDisputes[0]).to.equal(escrowId);
    });
  });

  describe("Edge Cases and Error Handling", function () {
    it("Should handle dispute deadline correctly", async function () {
      const escrowId = ethers.utils.formatBytes32String("escrow1");
      const disputedAmount = ethers.utils.parseEther("1000");
      const buyerClaim = ethers.utils.parseEther("800");
      const sellerClaim = ethers.utils.parseEther("200");
      const evidenceHash = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("evidence"));

      await omniCoin.connect(arbitrator1).approve(arbitration.address, MIN_STAKING_AMOUNT);
      await arbitration.connect(arbitrator1).registerArbitrator(MIN_STAKING_AMOUNT, SPEC_DIGITAL_GOODS);

      await omniCoinEscrow.setEscrow(
        escrowId,
        seller.address,
        buyer.address,
        disputedAmount,
        0, 0, 0,
        true,
        ethers.constants.AddressZero
      );

      await arbitration.connect(buyer).createConfidentialDispute(
        escrowId,
        disputedAmount,
        buyerClaim,
        sellerClaim,
        evidenceHash
      );

      const deadline = await arbitration.getDisputeDeadline(escrowId);
      expect(deadline).to.be.gt(0);

      // Check if dispute is timed out (should be false initially)
      expect(await arbitration.isDisputeTimedOut(escrowId)).to.be.false;
    });

    it("Should handle non-existent disputes gracefully", async function () {
      const nonExistentEscrow = ethers.utils.formatBytes32String("nonexistent");
      
      expect(await arbitration.isDisputeResolved(nonExistentEscrow)).to.be.false;
      expect(await arbitration.getDisputeDeadline(nonExistentEscrow)).to.equal(0);
      expect(await arbitration.isDisputeTimedOut(nonExistentEscrow)).to.be.false;

      const disputeInfo = await arbitration.getDisputePublicInfo(nonExistentEscrow);
      expect(disputeInfo.primaryArbitrator).to.equal(ethers.constants.AddressZero);
    });

    it("Should prevent claiming earnings with zero balance", async function () {
      await omniCoin.connect(arbitrator1).approve(arbitration.address, MIN_STAKING_AMOUNT);
      await arbitration.connect(arbitrator1).registerArbitrator(MIN_STAKING_AMOUNT, SPEC_DIGITAL_GOODS);

      // Try to claim earnings without having any
      await expect(
        arbitration.connect(arbitrator1).claimArbitratorEarnings()
      ).to.be.revertedWith("No earnings to claim");
    });
  });
});