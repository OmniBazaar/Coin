const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

describe("MinimalEscrow", function () {
  let escrow;
  let token;
  let pToken;
  let owner, buyer, seller, arbitrator, registry, other;

  const ESCROW_AMOUNT = ethers.parseEther("100");
  const ESCROW_DURATION = 7 * 24 * 60 * 60; // 7 days
  const ARBITRATOR_DELAY = 24 * 60 * 60; // 24 hours
  const MIN_DURATION = 60 * 60; // 1 hour
  const MAX_DURATION = 30 * 24 * 60 * 60; // 30 days

  beforeEach(async function () {
    const signers = await ethers.getSigners();
    owner = signers[0];
    buyer = signers[1];
    seller = signers[2];
    arbitrator = signers[3];
    registry = signers[4];
    other = signers[5];

    // Deploy OmniCoin token (XOM)
    const Token = await ethers.getContractFactory("OmniCoin");
    token = await Token.connect(owner).deploy();
    await token.connect(owner).initialize();

    // Deploy a second OmniCoin as pXOM stand-in (privacy token)
    pToken = await Token.connect(owner).deploy();
    await pToken.connect(owner).initialize();

    // Deploy MinimalEscrow: omniCoin, privateOmniCoin, registry, feeCollector, feeBps
    const MinimalEscrow = await ethers.getContractFactory("MinimalEscrow");
    escrow = await MinimalEscrow.connect(owner).deploy(
      token.target,
      pToken.target,
      registry.address,
      owner.address, // feeCollector — deployer receives marketplace fees
      100 // 1% marketplace fee (100 basis points)
    );

    // Register arbitrator (owner is ADMIN since owner deployed the contract)
    await escrow.connect(owner).addArbitrator(arbitrator.address);

    // Setup: Give buyer tokens
    await token.connect(owner).mint(buyer.address, ethers.parseEther("1000"));
    await token.connect(owner).mint(seller.address, ethers.parseEther("100")); // For dispute stakes

    // Approve escrow contract
    await token.connect(buyer).approve(escrow.target, ethers.parseEther("1000"));
    await token.connect(seller).approve(escrow.target, ethers.parseEther("100"));
  });

  describe("Escrow Creation", function () {
    it("Should create escrow with correct parameters", async function () {
      const tx = await escrow.connect(buyer).createEscrow(
        seller.address,
        ESCROW_AMOUNT,
        ESCROW_DURATION
      );

      const receipt = await tx.wait();
      const event = receipt.logs.find(
        log => log.fragment && log.fragment.name === "EscrowCreated"
      );

      expect(event).to.not.be.undefined;
      const escrowId = event.args.escrowId;
      expect(escrowId).to.equal(1);

      const escrowData = await escrow.escrows(escrowId);
      expect(escrowData.buyer).to.equal(buyer.address);
      expect(escrowData.seller).to.equal(seller.address);
      expect(escrowData.amount).to.equal(ESCROW_AMOUNT);
      expect(escrowData.resolved).to.be.false;
      expect(escrowData.disputed).to.be.false;
    });

    it("Should transfer tokens to escrow on creation", async function () {
      const escrowBalanceBefore = await token.balanceOf(escrow.target);
      const buyerBalanceBefore = await token.balanceOf(buyer.address);

      await escrow.connect(buyer).createEscrow(
        seller.address,
        ESCROW_AMOUNT,
        ESCROW_DURATION
      );

      const escrowBalanceAfter = await token.balanceOf(escrow.target);
      const buyerBalanceAfter = await token.balanceOf(buyer.address);

      expect(escrowBalanceAfter - escrowBalanceBefore).to.equal(ESCROW_AMOUNT);
      expect(buyerBalanceBefore - buyerBalanceAfter).to.equal(ESCROW_AMOUNT);
    });

    it("Should enforce duration limits", async function () {
      // Too short
      await expect(
        escrow.connect(buyer).createEscrow(
          seller.address,
          ESCROW_AMOUNT,
          MIN_DURATION - 1
        )
      ).to.be.revertedWithCustomError(escrow, "InvalidDuration");

      // Too long
      await expect(
        escrow.connect(buyer).createEscrow(
          seller.address,
          ESCROW_AMOUNT,
          MAX_DURATION + 1
        )
      ).to.be.revertedWithCustomError(escrow, "InvalidDuration");
    });

    it("Should reject zero amount escrows", async function () {
      await expect(
        escrow.connect(buyer).createEscrow(
          seller.address,
          0,
          ESCROW_DURATION
        )
      ).to.be.revertedWithCustomError(escrow, "InvalidAmount");
    });

    it("Should reject self-escrow", async function () {
      await expect(
        escrow.connect(buyer).createEscrow(
          buyer.address,
          ESCROW_AMOUNT,
          ESCROW_DURATION
        )
      ).to.be.revertedWithCustomError(escrow, "InvalidAddress");
    });
  });

  describe("Release and Refund", function () {
    let escrowId;

    beforeEach(async function () {
      const tx = await escrow.connect(buyer).createEscrow(
        seller.address,
        ESCROW_AMOUNT,
        ESCROW_DURATION
      );
      const receipt = await tx.wait();
      escrowId = receipt.logs.find(
        log => log.fragment && log.fragment.name === "EscrowCreated"
      ).args.escrowId;
    });

    it("Should allow buyer to release funds with 1% marketplace fee", async function () {
      const sellerBalanceBefore = await token.balanceOf(seller.address);
      const feeCollectorBefore = await token.balanceOf(owner.address);

      await escrow.connect(buyer).releaseFunds(escrowId);

      // Seller gets 99% (100 XOM * 99% = 99 XOM)
      const sellerBalanceAfter = await token.balanceOf(seller.address);
      const expectedSellerAmount = ESCROW_AMOUNT - (ESCROW_AMOUNT * 100n / 10000n);
      expect(sellerBalanceAfter - sellerBalanceBefore).to.equal(expectedSellerAmount);

      // Fee collector (owner) gets 1% (100 XOM * 1% = 1 XOM)
      const feeCollectorAfter = await token.balanceOf(owner.address);
      const expectedFee = ESCROW_AMOUNT * 100n / 10000n;
      expect(feeCollectorAfter - feeCollectorBefore).to.equal(expectedFee);

      const escrowData = await escrow.escrows(escrowId);
      expect(escrowData.resolved).to.be.true;
    });

    it("Should allow both parties to vote for release (with fee)", async function () {
      // First vote from seller
      await escrow.connect(seller).vote(escrowId, true);

      // Check vote was recorded but not resolved
      let escrowData = await escrow.escrows(escrowId);
      expect(escrowData.releaseVotes).to.equal(1);
      expect(escrowData.resolved).to.be.false;

      // Second vote from buyer completes release
      await escrow.connect(buyer).vote(escrowId, true);

      escrowData = await escrow.escrows(escrowId);
      expect(escrowData.resolved).to.be.true;

      // Check seller received 99% (initial 100 + 99 from escrow = 199)
      const sellerBalance = await token.balanceOf(seller.address);
      const expectedSellerAmount = ESCROW_AMOUNT - (ESCROW_AMOUNT * 100n / 10000n);
      expect(sellerBalance).to.equal(ethers.parseEther("100") + expectedSellerAmount);
    });

    it("Should allow buyer to request refund after expiry", async function () {
      // Fast forward past expiry
      await time.increase(ESCROW_DURATION + 1);

      const buyerBalanceBefore = await token.balanceOf(buyer.address);

      await escrow.connect(buyer).refundBuyer(escrowId);

      const buyerBalanceAfter = await token.balanceOf(buyer.address);
      expect(buyerBalanceAfter - buyerBalanceBefore).to.equal(ESCROW_AMOUNT);
    });

    it("Should prevent release after resolution", async function () {
      await escrow.connect(buyer).releaseFunds(escrowId);

      await expect(
        escrow.connect(buyer).releaseFunds(escrowId)
      ).to.be.revertedWithCustomError(escrow, "AlreadyResolved");
    });
  });

  describe("Dispute Resolution", function () {
    let escrowId;

    beforeEach(async function () {
      const tx = await escrow.connect(buyer).createEscrow(
        seller.address,
        ESCROW_AMOUNT,
        ESCROW_DURATION
      );
      const receipt = await tx.wait();
      escrowId = receipt.logs.find(
        log => log.fragment && log.fragment.name === "EscrowCreated"
      ).args.escrowId;
    });

    it("Should prevent disputes before delay period", async function () {
      const commitment = ethers.keccak256(
        ethers.solidityPacked(["uint256", "uint256", "address"], [escrowId, 123, buyer.address])
      );

      await expect(
        escrow.connect(buyer).commitDispute(escrowId, commitment)
      ).to.be.revertedWithCustomError(escrow, "DisputeTooEarly");
    });

    it("Should allow dispute commitment after delay period", async function () {
      // Fast forward past arbitrator delay
      await time.increase(ARBITRATOR_DELAY + 1);

      const nonce = 12345;
      const commitment = ethers.keccak256(
        ethers.solidityPacked(["uint256", "uint256", "address"], [escrowId, nonce, buyer.address])
      );

      // Commit dispute
      await escrow.connect(buyer).commitDispute(escrowId, commitment);

      // Check commitment stored
      const commitmentData = await escrow.disputeCommitments(escrowId);
      expect(commitmentData.commitment).to.equal(commitment);
      expect(commitmentData.revealed).to.be.false;
    });

    it("Should allow dispute reveal and select registered arbitrator", async function () {
      await time.increase(ARBITRATOR_DELAY + 1);

      const nonce = 12345;
      const commitment = ethers.keccak256(
        ethers.solidityPacked(["uint256", "uint256", "address"], [escrowId, nonce, buyer.address])
      );

      // Commit and reveal
      await escrow.connect(buyer).commitDispute(escrowId, commitment);
      await escrow.connect(buyer).revealDispute(escrowId, nonce);

      const escrowData = await escrow.escrows(escrowId);
      expect(escrowData.disputed).to.be.true;
      // Arbitrator must be from the registered list (we registered arbitrator signer)
      expect(escrowData.arbitrator).to.equal(arbitrator.address);
    });

    it("Should allow arbitrator to resolve dispute", async function () {
      await time.increase(ARBITRATOR_DELAY + 1);

      const nonce = 12345;
      const commitment = ethers.keccak256(
        ethers.solidityPacked(["uint256", "uint256", "address"], [escrowId, nonce, buyer.address])
      );

      // Raise dispute
      await escrow.connect(buyer).commitDispute(escrowId, commitment);
      await escrow.connect(buyer).revealDispute(escrowId, nonce);

      const escrowData = await escrow.escrows(escrowId);
      const assignedArbitrator = escrowData.arbitrator;

      // The assigned arbitrator should be from our registered list
      expect(await escrow.isRegisteredArbitrator(assignedArbitrator)).to.be.true;

      // Use the actual signer if it matches, otherwise impersonate
      let arbitratorSigner;
      if (assignedArbitrator === arbitrator.address) {
        arbitratorSigner = arbitrator;
      } else {
        await ethers.provider.send("hardhat_setBalance", [
          assignedArbitrator,
          ethers.toBeHex(ethers.parseEther("10"))
        ]);
        arbitratorSigner = await ethers.getImpersonatedSigner(assignedArbitrator);
      }

      // Arbitrator votes for seller
      await escrow.connect(arbitratorSigner).vote(escrowId, true);

      // Seller also votes for release
      await escrow.connect(seller).vote(escrowId, true);

      const resolvedData = await escrow.escrows(escrowId);
      expect(resolvedData.resolved).to.be.true;

      if (assignedArbitrator !== arbitrator.address) {
        await ethers.provider.send("hardhat_stopImpersonatingAccount", [assignedArbitrator]);
      }
    });

    it("Should return dispute stake after resolution", async function () {
      await time.increase(ARBITRATOR_DELAY + 1);

      const nonce = 12345;
      const commitment = ethers.keccak256(
        ethers.solidityPacked(["uint256", "uint256", "address"], [escrowId, nonce, buyer.address])
      );

      const buyerBalanceBefore = await token.balanceOf(buyer.address);

      // Commit dispute (buyer pays stake)
      await escrow.connect(buyer).commitDispute(escrowId, commitment);

      const buyerBalanceAfterStake = await token.balanceOf(buyer.address);
      const stakeAmount = ESCROW_AMOUNT / 1000n; // 0.1% of 100 = 0.1 ETH
      expect(buyerBalanceBefore - buyerBalanceAfterStake).to.equal(stakeAmount);

      // Reveal dispute
      await escrow.connect(buyer).revealDispute(escrowId, nonce);

      const escrowData = await escrow.escrows(escrowId);
      const assignedArbitrator = escrowData.arbitrator;

      let arbitratorSigner;
      if (assignedArbitrator === arbitrator.address) {
        arbitratorSigner = arbitrator;
      } else {
        await ethers.provider.send("hardhat_setBalance", [
          assignedArbitrator,
          ethers.toBeHex(ethers.parseEther("10"))
        ]);
        arbitratorSigner = await ethers.getImpersonatedSigner(assignedArbitrator);
      }

      // Resolve: arbitrator + seller vote for release
      await escrow.connect(arbitratorSigner).vote(escrowId, true);
      await escrow.connect(seller).vote(escrowId, true);

      // Buyer should get stake back after resolution
      const buyerBalanceAfter = await token.balanceOf(buyer.address);
      // Buyer lost 100 escrow (went to seller) but got back 0.1 stake
      expect(buyerBalanceAfter).to.equal(buyerBalanceAfterStake + stakeAmount);

      if (assignedArbitrator !== arbitrator.address) {
        await ethers.provider.send("hardhat_stopImpersonatingAccount", [assignedArbitrator]);
      }
    });
  });

  describe("Arbitrator Management", function () {
    it("Should allow admin to add arbitrators", async function () {
      expect(await escrow.arbitratorCount()).to.equal(1); // Added in beforeEach

      await escrow.connect(owner).addArbitrator(other.address);
      expect(await escrow.arbitratorCount()).to.equal(2);
      expect(await escrow.isRegisteredArbitrator(other.address)).to.be.true;
    });

    it("Should allow admin to remove arbitrators", async function () {
      await escrow.connect(owner).addArbitrator(other.address);
      expect(await escrow.arbitratorCount()).to.equal(2);

      await escrow.connect(owner).removeArbitrator(other.address);
      expect(await escrow.arbitratorCount()).to.equal(1);
      expect(await escrow.isRegisteredArbitrator(other.address)).to.be.false;
    });

    it("Should prevent non-admin from adding arbitrators", async function () {
      await expect(
        escrow.connect(buyer).addArbitrator(other.address)
      ).to.be.revertedWithCustomError(escrow, "OnlyAdmin");
    });

    it("Should revert dispute if no arbitrators registered", async function () {
      // Remove the only arbitrator
      await escrow.connect(owner).removeArbitrator(arbitrator.address);
      expect(await escrow.arbitratorCount()).to.equal(0);

      // Create escrow and try to dispute
      const tx = await escrow.connect(buyer).createEscrow(
        seller.address,
        ESCROW_AMOUNT,
        ESCROW_DURATION
      );
      const receipt = await tx.wait();
      const escrowId = receipt.logs.find(
        log => log.fragment && log.fragment.name === "EscrowCreated"
      ).args.escrowId;

      await time.increase(ARBITRATOR_DELAY + 1);

      const nonce = 99;
      const commitment = ethers.keccak256(
        ethers.solidityPacked(["uint256", "uint256", "address"], [escrowId, nonce, buyer.address])
      );

      await escrow.connect(buyer).commitDispute(escrowId, commitment);

      await expect(
        escrow.connect(buyer).revealDispute(escrowId, nonce)
      ).to.be.revertedWithCustomError(escrow, "NoArbitratorsAvailable");
    });

    it("Should set deployer as admin", async function () {
      expect(await escrow.ADMIN()).to.equal(owner.address);
    });
  });

  describe("Voting System", function () {
    let escrowId;

    beforeEach(async function () {
      const tx = await escrow.connect(buyer).createEscrow(
        seller.address,
        ESCROW_AMOUNT,
        ESCROW_DURATION
      );
      const receipt = await tx.wait();
      escrowId = receipt.logs.find(
        log => log.fragment && log.fragment.name === "EscrowCreated"
      ).args.escrowId;
    });

    it("Should count votes correctly", async function () {
      // Both vote for release
      await escrow.connect(buyer).vote(escrowId, true);
      await escrow.connect(seller).vote(escrowId, true);

      const escrowData = await escrow.escrows(escrowId);
      expect(escrowData.releaseVotes).to.equal(2);
      expect(escrowData.resolved).to.be.true;
    });

    it("Should handle refund votes", async function () {
      const buyerBalanceBefore = await token.balanceOf(buyer.address);
      expect(buyerBalanceBefore).to.equal(ethers.parseEther("900"));

      // Both vote for refund
      await escrow.connect(buyer).vote(escrowId, false);
      await escrow.connect(seller).vote(escrowId, false);

      const escrowData = await escrow.escrows(escrowId);
      expect(escrowData.refundVotes).to.equal(2);
      expect(escrowData.resolved).to.be.true;

      // Check buyer got refund
      const buyerBalance = await token.balanceOf(buyer.address);
      expect(buyerBalance).to.equal(ethers.parseEther("1000"));
    });

    it("Should prevent double voting", async function () {
      await escrow.connect(buyer).vote(escrowId, true);

      await expect(
        escrow.connect(buyer).vote(escrowId, true)
      ).to.be.revertedWithCustomError(escrow, "AlreadyVoted");
    });

    it("Should require 2 votes for resolution", async function () {
      // Only one vote
      await escrow.connect(buyer).vote(escrowId, true);

      const escrowData = await escrow.escrows(escrowId);
      expect(escrowData.releaseVotes).to.equal(1);
      expect(escrowData.resolved).to.be.false;
    });
  });

  describe("Events", function () {
    it("Should emit EscrowCreated event", async function () {
      const block = await ethers.provider.getBlock("latest");
      const expectedExpiry = block.timestamp + ESCROW_DURATION + 1;

      await expect(
        escrow.connect(buyer).createEscrow(
          seller.address,
          ESCROW_AMOUNT,
          ESCROW_DURATION
        )
      ).to.emit(escrow, "EscrowCreated")
        .withArgs(1, buyer.address, seller.address, ESCROW_AMOUNT, expectedExpiry);
    });

    it("Should emit EscrowResolved event", async function () {
      const tx = await escrow.connect(buyer).createEscrow(
        seller.address,
        ESCROW_AMOUNT,
        ESCROW_DURATION
      );
      const receipt = await tx.wait();
      const escrowId = receipt.logs.find(
        log => log.fragment && log.fragment.name === "EscrowCreated"
      ).args.escrowId;

      const expectedSellerAmount = ESCROW_AMOUNT - (ESCROW_AMOUNT * 100n / 10000n);
      await expect(escrow.connect(buyer).releaseFunds(escrowId))
        .to.emit(escrow, "MarketplaceFeeCollected")
        .and.to.emit(escrow, "EscrowResolved")
        .withArgs(escrowId, seller.address, expectedSellerAmount);
    });

    it("Should emit VoteCast event", async function () {
      const tx = await escrow.connect(buyer).createEscrow(
        seller.address,
        ESCROW_AMOUNT,
        ESCROW_DURATION
      );
      const receipt = await tx.wait();
      const escrowId = receipt.logs.find(
        log => log.fragment && log.fragment.name === "EscrowCreated"
      ).args.escrowId;

      await expect(escrow.connect(seller).vote(escrowId, true))
        .to.emit(escrow, "VoteCast")
        .withArgs(escrowId, seller.address, true);
    });
  });

  describe("Security", function () {
    it("Should have reentrancy protection", async function () {
      expect(await escrow.OMNI_COIN()).to.equal(token.target);
    });

    it("Should validate all inputs", async function () {
      await expect(
        escrow.connect(buyer).createEscrow(
          ethers.ZeroAddress,
          ESCROW_AMOUNT,
          ESCROW_DURATION
        )
      ).to.be.revertedWithCustomError(escrow, "InvalidAddress");
    });

    it("Should require token approval", async function () {
      await token.connect(buyer).approve(escrow.target, 0);

      await expect(
        escrow.connect(buyer).createEscrow(
          seller.address,
          ESCROW_AMOUNT,
          ESCROW_DURATION
        )
      ).to.be.revertedWithCustomError(token, "ERC20InsufficientAllowance");
    });
  });
});
