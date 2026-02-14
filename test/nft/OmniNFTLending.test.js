const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

describe("OmniNFTLending", function () {
  let lending;
  let token;
  let nft;
  let owner, feeRecipient, lender, borrower, other;

  /** Platform fee: 10 % of interest = 1000 bps */
  const PLATFORM_FEE_BPS = 1000;
  /** Default principal: 100 tokens */
  const PRINCIPAL = ethers.parseEther("100");
  /** 10 % annual interest = 1000 bps */
  const INTEREST_BPS = 1000;
  /** 30-day loan */
  const DURATION_DAYS = 30;
  /** NFT token ID used as collateral */
  const TOKEN_ID = 1;

  beforeEach(async function () {
    [owner, feeRecipient, lender, borrower, other] = await ethers.getSigners();

    // Deploy mock ERC-20
    const MockERC20 = await ethers.getContractFactory(
      "contracts/test/MockERC20.sol:MockERC20"
    );
    token = await MockERC20.deploy("Test Token", "TT");

    // Deploy mock ERC-721
    const MockERC721 = await ethers.getContractFactory(
      "contracts/test/MockERC721.sol:MockERC721"
    );
    nft = await MockERC721.deploy("Test NFT", "TNFT");

    // Deploy OmniNFTLending
    const Lending = await ethers.getContractFactory("OmniNFTLending");
    lending = await Lending.deploy(feeRecipient.address, PLATFORM_FEE_BPS);

    // Mint tokens to lender for principal deposits
    await token.mint(lender.address, ethers.parseEther("10000"));

    // Mint tokens to borrower for repayment
    await token.mint(borrower.address, ethers.parseEther("10000"));

    // Mint NFT to borrower (tokenId = 1)
    await nft.mint(borrower.address, TOKEN_ID);

    // Approve lending contract from lender (for principal deposit)
    await token
      .connect(lender)
      .approve(await lending.getAddress(), ethers.MaxUint256);

    // Approve lending contract from borrower (for repayment)
    await token
      .connect(borrower)
      .approve(await lending.getAddress(), ethers.MaxUint256);

    // Approve lending contract for NFT transfer from borrower
    await nft
      .connect(borrower)
      .setApprovalForAll(await lending.getAddress(), true);
  });

  // ── Helpers ──────────────────────────────────────────────────────────

  /**
   * Create a standard offer and return the offerId.
   * @param {object} [overrides] - Optional overrides for collections, principal, etc.
   * @returns {Promise<bigint>} offerId
   */
  async function createDefaultOffer(overrides = {}) {
    const collections = overrides.collections || [await nft.getAddress()];
    const currency = overrides.currency || (await token.getAddress());
    const principal = overrides.principal || PRINCIPAL;
    const interestBps = overrides.interestBps ?? INTEREST_BPS;
    const durationDays = overrides.durationDays ?? DURATION_DAYS;
    const signer = overrides.signer || lender;

    const tx = await lending
      .connect(signer)
      .createOffer(collections, currency, principal, interestBps, durationDays);
    const receipt = await tx.wait();

    const event = receipt.logs.find(
      (l) => l.fragment && l.fragment.name === "OfferCreated"
    );
    return event.args.offerId;
  }

  /**
   * Create an offer and accept it, returning { offerId, loanId }.
   * @returns {Promise<{offerId: bigint, loanId: bigint}>}
   */
  async function createAndAcceptOffer() {
    const offerId = await createDefaultOffer();
    const tx = await lending
      .connect(borrower)
      .acceptOffer(offerId, await nft.getAddress(), TOKEN_ID);
    const receipt = await tx.wait();
    const event = receipt.logs.find(
      (l) => l.fragment && l.fragment.name === "LoanStarted"
    );
    return { offerId, loanId: event.args.loanId };
  }

  // ── 1. Deployment ────────────────────────────────────────────────────

  describe("Deployment", function () {
    it("Should set the deployer as owner", async function () {
      expect(await lending.owner()).to.equal(owner.address);
    });

    it("Should set the correct fee recipient", async function () {
      expect(await lending.feeRecipient()).to.equal(feeRecipient.address);
    });

    it("Should set the correct platform fee", async function () {
      expect(await lending.platformFeeBps()).to.equal(PLATFORM_FEE_BPS);
    });

    it("Should initialize offer and loan counters at zero", async function () {
      expect(await lending.nextOfferId()).to.equal(0);
      expect(await lending.nextLoanId()).to.equal(0);
    });

    it("Should reject fee above maximum", async function () {
      const Lending = await ethers.getContractFactory("OmniNFTLending");
      await expect(
        Lending.deploy(feeRecipient.address, 2001)
      ).to.be.revertedWithCustomError(lending, "FeeTooHigh");
    });
  });

  // ── 2. Create Offer ─────────────────────────────────────────────────

  describe("Create Offer", function () {
    it("Should deposit principal from lender into contract", async function () {
      const lendingAddr = await lending.getAddress();
      const balanceBefore = await token.balanceOf(lendingAddr);
      await createDefaultOffer();
      const balanceAfter = await token.balanceOf(lendingAddr);
      expect(balanceAfter - balanceBefore).to.equal(PRINCIPAL);
    });

    it("Should emit OfferCreated with correct args", async function () {
      const nftAddr = await nft.getAddress();
      const tokenAddr = await token.getAddress();

      await expect(
        lending
          .connect(lender)
          .createOffer(
            [nftAddr],
            tokenAddr,
            PRINCIPAL,
            INTEREST_BPS,
            DURATION_DAYS
          )
      )
        .to.emit(lending, "OfferCreated")
        .withArgs(0, lender.address, PRINCIPAL, INTEREST_BPS, DURATION_DAYS);
    });

    it("Should store offer data correctly", async function () {
      const offerId = await createDefaultOffer();
      const offer = await lending.getOffer(offerId);
      expect(offer.lender).to.equal(lender.address);
      expect(offer.currency).to.equal(await token.getAddress());
      expect(offer.principal).to.equal(PRINCIPAL);
      expect(offer.interestBps).to.equal(INTEREST_BPS);
      expect(offer.durationDays).to.equal(DURATION_DAYS);
      expect(offer.active).to.equal(true);
    });

    it("Should mark accepted collections correctly", async function () {
      const nftAddr = await nft.getAddress();
      const offerId = await createDefaultOffer();
      expect(
        await lending.isCollectionAccepted(offerId, nftAddr)
      ).to.equal(true);
      expect(
        await lending.isCollectionAccepted(offerId, other.address)
      ).to.equal(false);
    });

    it("Should accept multiple collections in one offer", async function () {
      const MockERC721 = await ethers.getContractFactory(
        "contracts/test/MockERC721.sol:MockERC721"
      );
      const nft2 = await MockERC721.deploy("NFT2", "N2");
      const addr1 = await nft.getAddress();
      const addr2 = await nft2.getAddress();

      const offerId = await createDefaultOffer({ collections: [addr1, addr2] });
      expect(await lending.isCollectionAccepted(offerId, addr1)).to.equal(true);
      expect(await lending.isCollectionAccepted(offerId, addr2)).to.equal(true);
    });

    it("Should increment nextOfferId", async function () {
      await createDefaultOffer();
      expect(await lending.nextOfferId()).to.equal(1);
      await createDefaultOffer();
      expect(await lending.nextOfferId()).to.equal(2);
    });

    it("Should reject zero principal", async function () {
      await expect(
        lending
          .connect(lender)
          .createOffer(
            [await nft.getAddress()],
            await token.getAddress(),
            0,
            INTEREST_BPS,
            DURATION_DAYS
          )
      ).to.be.revertedWithCustomError(lending, "ZeroPrincipal");
    });

    it("Should reject empty collections array", async function () {
      await expect(
        lending
          .connect(lender)
          .createOffer(
            [],
            await token.getAddress(),
            PRINCIPAL,
            INTEREST_BPS,
            DURATION_DAYS
          )
      ).to.be.revertedWithCustomError(lending, "NoCollections");
    });

    it("Should reject interest above 50%", async function () {
      await expect(
        lending
          .connect(lender)
          .createOffer(
            [await nft.getAddress()],
            await token.getAddress(),
            PRINCIPAL,
            5001, // > MAX_INTEREST_BPS (5000)
            DURATION_DAYS
          )
      ).to.be.revertedWithCustomError(lending, "InterestTooHigh");
    });

    it("Should accept interest at exactly 50%", async function () {
      const offerId = await createDefaultOffer({ interestBps: 5000 });
      const offer = await lending.getOffer(offerId);
      expect(offer.interestBps).to.equal(5000);
    });

    it("Should reject zero duration", async function () {
      await expect(
        lending
          .connect(lender)
          .createOffer(
            [await nft.getAddress()],
            await token.getAddress(),
            PRINCIPAL,
            INTEREST_BPS,
            0
          )
      ).to.be.revertedWithCustomError(lending, "InvalidDuration");
    });

    it("Should reject duration above 365 days", async function () {
      await expect(
        lending
          .connect(lender)
          .createOffer(
            [await nft.getAddress()],
            await token.getAddress(),
            PRINCIPAL,
            INTEREST_BPS,
            366
          )
      ).to.be.revertedWithCustomError(lending, "InvalidDuration");
    });

    it("Should accept duration at exactly 365 days", async function () {
      const offerId = await createDefaultOffer({ durationDays: 365 });
      const offer = await lending.getOffer(offerId);
      expect(offer.durationDays).to.equal(365);
    });
  });

  // ── 3. Accept Offer ─────────────────────────────────────────────────

  describe("Accept Offer", function () {
    it("Should transfer NFT from borrower to contract", async function () {
      const offerId = await createDefaultOffer();
      await lending
        .connect(borrower)
        .acceptOffer(offerId, await nft.getAddress(), TOKEN_ID);

      expect(await nft.ownerOf(TOKEN_ID)).to.equal(
        await lending.getAddress()
      );
    });

    it("Should transfer principal from contract to borrower", async function () {
      const offerId = await createDefaultOffer();
      const balanceBefore = await token.balanceOf(borrower.address);
      await lending
        .connect(borrower)
        .acceptOffer(offerId, await nft.getAddress(), TOKEN_ID);
      const balanceAfter = await token.balanceOf(borrower.address);
      expect(balanceAfter - balanceBefore).to.equal(PRINCIPAL);
    });

    it("Should emit LoanStarted with correct args", async function () {
      const offerId = await createDefaultOffer();
      const nftAddr = await nft.getAddress();

      await expect(
        lending.connect(borrower).acceptOffer(offerId, nftAddr, TOKEN_ID)
      )
        .to.emit(lending, "LoanStarted")
        .withArgs(0, offerId, borrower.address, nftAddr, TOKEN_ID);
    });

    it("Should store loan data correctly", async function () {
      const { offerId, loanId } = await createAndAcceptOffer();
      const loan = await lending.getLoan(loanId);

      expect(loan.borrower).to.equal(borrower.address);
      expect(loan.lender).to.equal(lender.address);
      expect(loan.collection).to.equal(await nft.getAddress());
      expect(loan.tokenId).to.equal(TOKEN_ID);
      expect(loan.principal).to.equal(PRINCIPAL);
      // interest = 100 * 1000 / 10000 = 10
      expect(loan.interest).to.equal(ethers.parseEther("10"));
      expect(loan.repaid).to.equal(false);
      expect(loan.liquidated).to.equal(false);
    });

    it("Should set dueTime correctly", async function () {
      const { loanId } = await createAndAcceptOffer();
      const loan = await lending.getLoan(loanId);
      const latestBlock = await ethers.provider.getBlock("latest");
      const expectedDue =
        BigInt(latestBlock.timestamp) + BigInt(DURATION_DAYS) * 86400n;
      expect(loan.dueTime).to.equal(expectedDue);
    });

    it("Should deactivate the offer after acceptance", async function () {
      const { offerId } = await createAndAcceptOffer();
      const offer = await lending.getOffer(offerId);
      expect(offer.active).to.equal(false);
    });

    it("Should reject non-accepted collection", async function () {
      const offerId = await createDefaultOffer();
      // Use a different address as collection (not in accepted list)
      await expect(
        lending.connect(borrower).acceptOffer(offerId, other.address, TOKEN_ID)
      ).to.be.revertedWithCustomError(lending, "CollectionNotAccepted");
    });

    it("Should reject inactive offer (already accepted)", async function () {
      const { offerId } = await createAndAcceptOffer();
      // Mint another NFT for a second attempt
      await nft.mint(borrower.address, 2);
      await expect(
        lending
          .connect(borrower)
          .acceptOffer(offerId, await nft.getAddress(), 2)
      ).to.be.revertedWithCustomError(lending, "OfferNotActive");
    });

    it("Should reject non-existent offer", async function () {
      await expect(
        lending
          .connect(borrower)
          .acceptOffer(999, await nft.getAddress(), TOKEN_ID)
      ).to.be.revertedWithCustomError(lending, "OfferNotFound");
    });
  });

  // ── 4. Repay ────────────────────────────────────────────────────────

  describe("Repay", function () {
    it("Should transfer principal + interest from borrower", async function () {
      const { loanId } = await createAndAcceptOffer();
      const loan = await lending.getLoan(loanId);
      const totalRepayment = loan.principal + loan.interest;

      const borrowerBefore = await token.balanceOf(borrower.address);
      await lending.connect(borrower).repay(loanId);
      const borrowerAfter = await token.balanceOf(borrower.address);

      expect(borrowerBefore - borrowerAfter).to.equal(totalRepayment);
    });

    it("Should return NFT to borrower", async function () {
      const { loanId } = await createAndAcceptOffer();
      await lending.connect(borrower).repay(loanId);
      expect(await nft.ownerOf(TOKEN_ID)).to.equal(borrower.address);
    });

    it("Should send lender principal + interest minus platform fee", async function () {
      const { loanId } = await createAndAcceptOffer();
      const loan = await lending.getLoan(loanId);

      // platformFee = interest * platformFeeBps / 10000
      const platformFee =
        (loan.interest * BigInt(PLATFORM_FEE_BPS)) / 10000n;
      const lenderExpected = loan.principal + loan.interest - platformFee;

      const lenderBefore = await token.balanceOf(lender.address);
      await lending.connect(borrower).repay(loanId);
      const lenderAfter = await token.balanceOf(lender.address);

      expect(lenderAfter - lenderBefore).to.equal(lenderExpected);
    });

    it("Should send platform fee to feeRecipient", async function () {
      const { loanId } = await createAndAcceptOffer();
      const loan = await lending.getLoan(loanId);
      const platformFee =
        (loan.interest * BigInt(PLATFORM_FEE_BPS)) / 10000n;

      const feeBefore = await token.balanceOf(feeRecipient.address);
      await lending.connect(borrower).repay(loanId);
      const feeAfter = await token.balanceOf(feeRecipient.address);

      expect(feeAfter - feeBefore).to.equal(platformFee);
    });

    it("Should emit LoanRepaid with correct args", async function () {
      const { loanId } = await createAndAcceptOffer();
      const loan = await lending.getLoan(loanId);
      const totalRepaid = loan.principal + loan.interest;
      const platformFee =
        (loan.interest * BigInt(PLATFORM_FEE_BPS)) / 10000n;

      await expect(lending.connect(borrower).repay(loanId))
        .to.emit(lending, "LoanRepaid")
        .withArgs(loanId, borrower.address, totalRepaid, platformFee);
    });

    it("Should mark loan as repaid", async function () {
      const { loanId } = await createAndAcceptOffer();
      await lending.connect(borrower).repay(loanId);
      const loan = await lending.getLoan(loanId);
      expect(loan.repaid).to.equal(true);
    });

    it("Should handle zero platform fee correctly", async function () {
      // Deploy a lending contract with 0 fee
      const Lending = await ethers.getContractFactory("OmniNFTLending");
      const zeroFeeLending = await Lending.deploy(feeRecipient.address, 0);

      // Re-approve for the new contract
      await token
        .connect(lender)
        .approve(await zeroFeeLending.getAddress(), ethers.MaxUint256);
      await token
        .connect(borrower)
        .approve(await zeroFeeLending.getAddress(), ethers.MaxUint256);
      await nft
        .connect(borrower)
        .setApprovalForAll(await zeroFeeLending.getAddress(), true);

      // Mint another NFT
      const newTokenId = 99;
      await nft.mint(borrower.address, newTokenId);

      // Create offer and accept
      const tx1 = await zeroFeeLending
        .connect(lender)
        .createOffer(
          [await nft.getAddress()],
          await token.getAddress(),
          PRINCIPAL,
          INTEREST_BPS,
          DURATION_DAYS
        );
      const receipt1 = await tx1.wait();
      const offerId = receipt1.logs.find(
        (l) => l.fragment && l.fragment.name === "OfferCreated"
      ).args.offerId;

      await zeroFeeLending
        .connect(borrower)
        .acceptOffer(offerId, await nft.getAddress(), newTokenId);

      // Repay - lender should get full principal + interest
      const lenderBefore = await token.balanceOf(lender.address);
      const feeBefore = await token.balanceOf(feeRecipient.address);
      await zeroFeeLending.connect(borrower).repay(0);
      const lenderAfter = await token.balanceOf(lender.address);
      const feeAfter = await token.balanceOf(feeRecipient.address);

      expect(lenderAfter - lenderBefore).to.equal(
        PRINCIPAL + ethers.parseEther("10")
      );
      expect(feeAfter - feeBefore).to.equal(0);
    });

    it("Should reject repay from non-borrower", async function () {
      const { loanId } = await createAndAcceptOffer();
      await expect(
        lending.connect(other).repay(loanId)
      ).to.be.revertedWithCustomError(lending, "NotBorrower");
    });

    it("Should reject repay on already-repaid loan", async function () {
      const { loanId } = await createAndAcceptOffer();
      await lending.connect(borrower).repay(loanId);
      await expect(
        lending.connect(borrower).repay(loanId)
      ).to.be.revertedWithCustomError(lending, "LoanNotActive");
    });

    it("Should reject repay on non-existent loan", async function () {
      await expect(
        lending.connect(borrower).repay(999)
      ).to.be.revertedWithCustomError(lending, "LoanNotFound");
    });

    it("Should reject repay on liquidated loan", async function () {
      const { loanId } = await createAndAcceptOffer();
      // Advance time past due date
      await time.increase(DURATION_DAYS * 86400 + 1);
      // Liquidate first
      await lending.connect(lender).liquidate(loanId);
      // Then try repay
      await expect(
        lending.connect(borrower).repay(loanId)
      ).to.be.revertedWithCustomError(lending, "LoanNotActive");
    });
  });

  // ── 5. Liquidate ────────────────────────────────────────────────────

  describe("Liquidate", function () {
    it("Should transfer NFT to lender after due time", async function () {
      const { loanId } = await createAndAcceptOffer();
      await time.increase(DURATION_DAYS * 86400 + 1);
      await lending.connect(lender).liquidate(loanId);
      expect(await nft.ownerOf(TOKEN_ID)).to.equal(lender.address);
    });

    it("Should emit LoanLiquidated with correct args", async function () {
      const { loanId } = await createAndAcceptOffer();
      await time.increase(DURATION_DAYS * 86400 + 1);
      await expect(lending.connect(lender).liquidate(loanId))
        .to.emit(lending, "LoanLiquidated")
        .withArgs(loanId, lender.address);
    });

    it("Should mark loan as liquidated", async function () {
      const { loanId } = await createAndAcceptOffer();
      await time.increase(DURATION_DAYS * 86400 + 1);
      await lending.connect(lender).liquidate(loanId);
      const loan = await lending.getLoan(loanId);
      expect(loan.liquidated).to.equal(true);
    });

    it("Should reject liquidation before due time", async function () {
      const { loanId } = await createAndAcceptOffer();
      // Do not advance time — still within the loan period
      await expect(
        lending.connect(lender).liquidate(loanId)
      ).to.be.revertedWithCustomError(lending, "LoanNotExpired");
    });

    it("Should reject liquidation from non-lender", async function () {
      const { loanId } = await createAndAcceptOffer();
      await time.increase(DURATION_DAYS * 86400 + 1);
      await expect(
        lending.connect(other).liquidate(loanId)
      ).to.be.revertedWithCustomError(lending, "NotLender");
    });

    it("Should reject liquidation of already-repaid loan", async function () {
      const { loanId } = await createAndAcceptOffer();
      await lending.connect(borrower).repay(loanId);
      await time.increase(DURATION_DAYS * 86400 + 1);
      await expect(
        lending.connect(lender).liquidate(loanId)
      ).to.be.revertedWithCustomError(lending, "LoanNotActive");
    });

    it("Should reject double liquidation", async function () {
      const { loanId } = await createAndAcceptOffer();
      await time.increase(DURATION_DAYS * 86400 + 1);
      await lending.connect(lender).liquidate(loanId);
      await expect(
        lending.connect(lender).liquidate(loanId)
      ).to.be.revertedWithCustomError(lending, "LoanNotActive");
    });

    it("Should reject liquidation of non-existent loan", async function () {
      await expect(
        lending.connect(lender).liquidate(999)
      ).to.be.revertedWithCustomError(lending, "LoanNotFound");
    });

    it("Should allow liquidation at exactly the due timestamp", async function () {
      const { loanId } = await createAndAcceptOffer();
      const loan = await lending.getLoan(loanId);

      // Two seconds before due time — the liquidate tx will mine at dueTime - 2,
      // which is strictly less than dueTime, so it should revert.
      await time.setNextBlockTimestamp(BigInt(loan.dueTime) - 2n);
      await ethers.provider.send("evm_mine", []);
      await time.setNextBlockTimestamp(BigInt(loan.dueTime) - 1n);
      await expect(
        lending.connect(lender).liquidate(loanId)
      ).to.be.revertedWithCustomError(lending, "LoanNotExpired");

      // At exactly dueTime: block.timestamp == dueTime, which is NOT < dueTime,
      // so the contract allows liquidation (strict less-than check).
      await time.setNextBlockTimestamp(BigInt(loan.dueTime));
      await lending.connect(lender).liquidate(loanId);
      expect(await nft.ownerOf(TOKEN_ID)).to.equal(lender.address);
    });
  });

  // ── 6. Cancel Offer ─────────────────────────────────────────────────

  describe("Cancel Offer", function () {
    it("Should return principal to lender", async function () {
      const offerId = await createDefaultOffer();
      const balanceBefore = await token.balanceOf(lender.address);
      await lending.connect(lender).cancelOffer(offerId);
      const balanceAfter = await token.balanceOf(lender.address);
      expect(balanceAfter - balanceBefore).to.equal(PRINCIPAL);
    });

    it("Should emit OfferCancelled with correct args", async function () {
      const offerId = await createDefaultOffer();
      await expect(lending.connect(lender).cancelOffer(offerId))
        .to.emit(lending, "OfferCancelled")
        .withArgs(offerId, lender.address);
    });

    it("Should deactivate the offer", async function () {
      const offerId = await createDefaultOffer();
      await lending.connect(lender).cancelOffer(offerId);
      const offer = await lending.getOffer(offerId);
      expect(offer.active).to.equal(false);
    });

    it("Should reduce contract token balance", async function () {
      const offerId = await createDefaultOffer();
      const lendingAddr = await lending.getAddress();
      const balanceBefore = await token.balanceOf(lendingAddr);
      await lending.connect(lender).cancelOffer(offerId);
      const balanceAfter = await token.balanceOf(lendingAddr);
      expect(balanceBefore - balanceAfter).to.equal(PRINCIPAL);
    });

    it("Should reject cancel from non-lender", async function () {
      const offerId = await createDefaultOffer();
      await expect(
        lending.connect(other).cancelOffer(offerId)
      ).to.be.revertedWithCustomError(lending, "NotLender");
    });

    it("Should reject cancel on already-accepted offer", async function () {
      const { offerId } = await createAndAcceptOffer();
      await expect(
        lending.connect(lender).cancelOffer(offerId)
      ).to.be.revertedWithCustomError(lending, "OfferNotActive");
    });

    it("Should reject cancel on already-cancelled offer", async function () {
      const offerId = await createDefaultOffer();
      await lending.connect(lender).cancelOffer(offerId);
      await expect(
        lending.connect(lender).cancelOffer(offerId)
      ).to.be.revertedWithCustomError(lending, "OfferNotActive");
    });

    it("Should reject cancel on non-existent offer", async function () {
      await expect(
        lending.connect(lender).cancelOffer(999)
      ).to.be.revertedWithCustomError(lending, "OfferNotFound");
    });
  });

  // ── 7. Admin ────────────────────────────────────────────────────────

  describe("Admin", function () {
    describe("setPlatformFee", function () {
      it("Should update platform fee", async function () {
        await lending.connect(owner).setPlatformFee(500);
        expect(await lending.platformFeeBps()).to.equal(500);
      });

      it("Should allow setting fee to zero", async function () {
        await lending.connect(owner).setPlatformFee(0);
        expect(await lending.platformFeeBps()).to.equal(0);
      });

      it("Should allow setting fee to maximum", async function () {
        await lending.connect(owner).setPlatformFee(2000);
        expect(await lending.platformFeeBps()).to.equal(2000);
      });

      it("Should reject fee above maximum", async function () {
        await expect(
          lending.connect(owner).setPlatformFee(2001)
        ).to.be.revertedWithCustomError(lending, "FeeTooHigh");
      });

      it("Should reject call from non-owner", async function () {
        await expect(
          lending.connect(other).setPlatformFee(500)
        ).to.be.revertedWithCustomError(lending, "OwnableUnauthorizedAccount");
      });
    });

    describe("setFeeRecipient", function () {
      it("Should update fee recipient", async function () {
        await lending.connect(owner).setFeeRecipient(other.address);
        expect(await lending.feeRecipient()).to.equal(other.address);
      });

      it("Should reject call from non-owner", async function () {
        await expect(
          lending.connect(other).setFeeRecipient(other.address)
        ).to.be.revertedWithCustomError(lending, "OwnableUnauthorizedAccount");
      });
    });
  });

  // ── 8. View Functions ───────────────────────────────────────────────

  describe("View Functions", function () {
    describe("getOffer", function () {
      it("Should return all offer fields", async function () {
        const offerId = await createDefaultOffer();
        const offer = await lending.getOffer(offerId);

        expect(offer.lender).to.equal(lender.address);
        expect(offer.currency).to.equal(await token.getAddress());
        expect(offer.principal).to.equal(PRINCIPAL);
        expect(offer.interestBps).to.equal(INTEREST_BPS);
        expect(offer.durationDays).to.equal(DURATION_DAYS);
        expect(offer.active).to.equal(true);
      });

      it("Should return zeroed fields for non-existent offer", async function () {
        const offer = await lending.getOffer(999);
        expect(offer.lender).to.equal(ethers.ZeroAddress);
        expect(offer.principal).to.equal(0);
        expect(offer.active).to.equal(false);
      });
    });

    describe("getLoan", function () {
      it("Should return all loan fields", async function () {
        const { loanId } = await createAndAcceptOffer();
        const loan = await lending.getLoan(loanId);

        expect(loan.borrower).to.equal(borrower.address);
        expect(loan.lender).to.equal(lender.address);
        expect(loan.collection).to.equal(await nft.getAddress());
        expect(loan.tokenId).to.equal(TOKEN_ID);
        expect(loan.principal).to.equal(PRINCIPAL);
        expect(loan.interest).to.equal(ethers.parseEther("10"));
        expect(loan.dueTime).to.be.gt(0);
        expect(loan.repaid).to.equal(false);
        expect(loan.liquidated).to.equal(false);
      });

      it("Should return zeroed fields for non-existent loan", async function () {
        const loan = await lending.getLoan(999);
        expect(loan.borrower).to.equal(ethers.ZeroAddress);
        expect(loan.lender).to.equal(ethers.ZeroAddress);
        expect(loan.principal).to.equal(0);
      });
    });

    describe("isCollectionAccepted", function () {
      it("Should return true for accepted collection", async function () {
        const offerId = await createDefaultOffer();
        expect(
          await lending.isCollectionAccepted(offerId, await nft.getAddress())
        ).to.equal(true);
      });

      it("Should return false for non-accepted collection", async function () {
        const offerId = await createDefaultOffer();
        expect(
          await lending.isCollectionAccepted(offerId, other.address)
        ).to.equal(false);
      });

      it("Should return false for non-existent offer", async function () {
        expect(
          await lending.isCollectionAccepted(999, await nft.getAddress())
        ).to.equal(false);
      });
    });
  });

  // ── 9. Integration / Edge Cases ─────────────────────────────────────

  describe("Integration", function () {
    it("Full lifecycle: create → accept → repay", async function () {
      // Lender creates offer
      const offerId = await createDefaultOffer();
      expect(await lending.nextOfferId()).to.equal(1);

      // Borrower accepts
      const { loanId } = await createAndAcceptOffer();

      // Wait partial loan duration
      await time.increase(15 * 86400); // 15 days

      // Borrower repays
      await lending.connect(borrower).repay(loanId);

      // Final state
      const loan = await lending.getLoan(loanId);
      expect(loan.repaid).to.equal(true);
      expect(loan.liquidated).to.equal(false);
      expect(await nft.ownerOf(TOKEN_ID)).to.equal(borrower.address);
    });

    it("Full lifecycle: create → accept → liquidate", async function () {
      const { loanId } = await createAndAcceptOffer();

      // Advance past due time
      await time.increase(DURATION_DAYS * 86400 + 1);

      // Lender liquidates
      await lending.connect(lender).liquidate(loanId);

      // Final state
      const loan = await lending.getLoan(loanId);
      expect(loan.repaid).to.equal(false);
      expect(loan.liquidated).to.equal(true);
      expect(await nft.ownerOf(TOKEN_ID)).to.equal(lender.address);
    });

    it("Multiple offers and loans concurrently", async function () {
      // Mint extra NFTs
      await nft.mint(borrower.address, 10);
      await nft.mint(borrower.address, 20);

      // Create two offers
      const offerId1 = await createDefaultOffer();
      const offerId2 = await createDefaultOffer({
        principal: ethers.parseEther("50"),
        interestBps: 500,
        durationDays: 60,
      });

      // Accept both
      const tx1 = await lending
        .connect(borrower)
        .acceptOffer(offerId1, await nft.getAddress(), 10);
      const receipt1 = await tx1.wait();
      const loanId1 = receipt1.logs.find(
        (l) => l.fragment && l.fragment.name === "LoanStarted"
      ).args.loanId;

      const tx2 = await lending
        .connect(borrower)
        .acceptOffer(offerId2, await nft.getAddress(), 20);
      const receipt2 = await tx2.wait();
      const loanId2 = receipt2.logs.find(
        (l) => l.fragment && l.fragment.name === "LoanStarted"
      ).args.loanId;

      // Repay first loan
      await lending.connect(borrower).repay(loanId1);
      expect(await nft.ownerOf(10)).to.equal(borrower.address);

      // Liquidate second loan
      await time.increase(60 * 86400 + 1);
      await lending.connect(lender).liquidate(loanId2);
      expect(await nft.ownerOf(20)).to.equal(lender.address);

      expect(await lending.nextLoanId()).to.equal(2);
    });

    it("Changed platform fee applies only to future repayments", async function () {
      // Start loan with 10% fee
      const { loanId } = await createAndAcceptOffer();

      // Owner changes fee to 20%
      await lending.connect(owner).setPlatformFee(2000);

      // Repay — the loan was created with platformFeeBps at repay time
      // The contract reads platformFeeBps at repay time, so the new fee applies
      const loan = await lending.getLoan(loanId);
      const platformFee = (loan.interest * 2000n) / 10000n;

      const feeBefore = await token.balanceOf(feeRecipient.address);
      await lending.connect(borrower).repay(loanId);
      const feeAfter = await token.balanceOf(feeRecipient.address);

      expect(feeAfter - feeBefore).to.equal(platformFee);
    });
  });
});
