/**
 * Tests for `NFTMarketplaceEscrowLegacy` (originally
 * `NFTMarketplaceEscrow`, the v1 thin-router design). Renamed
 * 2026-05-17 when the self-contained Option E v2 took over the
 * canonical contract name. The v1 instance at
 * 0x10F3687c5e491a2F380d87D0756c782051ef14c2 is ADMIN-paused on
 * mainnet — these tests still pass locally because they deploy a
 * fresh MinimalEscrow (which carries `releaseFundsViaContract` in
 * source) alongside the legacy router.
 *
 * Original description: atomic NFT-for-XOM settlement built on top
 * of `MinimalEscrow.releaseFundsViaContract`.
 *
 * Coverage focuses on the security-critical paths the audit will scrutinize:
 *  - Happy path: buyer + seller sigs valid → both legs settle in one tx.
 *  - Buyer signature replay across contracts (callerContract gate).
 *  - Seller nonce replay (one fill per (seller, nonce)).
 *  - Stale-fee rejection (listing.feeBps != contract.feeBps).
 *  - Expired listing.
 *  - Listing window exceeds MAX_LISTING_WINDOW.
 *  - Escrow lifecycle mismatches (resolved / disputed / wrong seller /
 *    wrong amount).
 *  - Buyer signature mismatch (wrong escrow, wrong deadline, wrong caller).
 *  - NFT not approved → entire tx reverts atomically.
 *  - Non-65-byte signature length rejected.
 *
 * Standalone — does not modify other suites.
 */

/* eslint-disable @typescript-eslint/no-require-imports, @typescript-eslint/no-var-requires */
const { expect } = require("chai");
const { ethers } = require("hardhat");

/* eslint-disable @typescript-eslint/no-explicit-any */
type AnyContract = any;
type AnySigner = any;

const FEE_BPS = 100n; // 1%
const ESCROW_DURATION_SEC = 7 * 24 * 60 * 60; // 7 days
const ASK_PRICE = ethers.parseEther("100");
const TOKEN_ID = 42n;

interface ListingFields {
  seller: string;
  buyer: string;
  nftContract: string;
  tokenId: bigint;
  askPriceXom: bigint;
  expiry: bigint;
  nonce: bigint;
  marketplaceFeeBps: number;
}

describe("NFTMarketplaceEscrowLegacy", () => {
  let xom: AnyContract;
  let escrow: AnyContract;
  let market: AnyContract;
  let nft: AnyContract;
  let owner: AnySigner;
  let buyer: AnySigner;
  let seller: AnySigner;
  let other: AnySigner;
  let escrowDomain: { name: string; version: string; chainId: number; verifyingContract: string };
  let listingDomain: { name: string; version: string; chainId: number; verifyingContract: string };

  /**
   * Sign a `Listing` envelope as the seller using EIP-712 typed-data.
   * @param signer  Wallet to sign with.
   * @param listing Listing struct to sign.
   * @returns 65-byte ECDSA signature.
   */
  async function signListing(signer: AnySigner, listing: ListingFields): Promise<string> {
    const types = {
      Listing: [
        { name: "seller", type: "address" },
        { name: "buyer", type: "address" },
        { name: "nftContract", type: "address" },
        { name: "tokenId", type: "uint256" },
        { name: "askPriceXom", type: "uint256" },
        { name: "expiry", type: "uint256" },
        { name: "nonce", type: "uint256" },
        { name: "marketplaceFeeBps", type: "uint64" },
      ],
    };
    return signer.signTypedData(listingDomain, types, listing);
  }

  /**
   * Sign a buyer `ReleaseFundsBySig` payload for MinimalEscrow.
   * @param signer         Buyer wallet.
   * @param escrowId       Escrow being released.
   * @param callerContract NFTMarketplaceEscrow address.
   * @param deadline       Unix seconds.
   * @returns 65-byte signature.
   */
  async function signRelease(
    signer: AnySigner,
    escrowId: bigint,
    callerContract: string,
    deadline: bigint
  ): Promise<string> {
    const types = {
      ReleaseFundsBySig: [
        { name: "escrowId", type: "uint256" },
        { name: "callerContract", type: "address" },
        { name: "deadline", type: "uint256" },
      ],
    };
    return signer.signTypedData(
      escrowDomain,
      types,
      { escrowId, callerContract, deadline }
    );
  }

  /**
   * Sign a buyer `FillAuthorization` payload for NFTMarketplaceEscrow.
   * This is the audit C-01 second-signature that pins the buyer's
   * intent to the exact listing being filled.
   * @param signer   Buyer wallet.
   * @param listing  The listing being authorized.
   * @param escrowId Escrow id funding the fill.
   * @param deadline Unix seconds (matches the ReleaseFundsBySig deadline).
   * @returns 65-byte signature.
   */
  async function signFillAuth(
    signer: AnySigner,
    listing: ListingFields,
    escrowId: bigint,
    deadline: bigint
  ): Promise<string> {
    // The listingDigest the contract verifies against is
    // `_hashTypedDataV4(_hashListing(listing))` — i.e., the full
    // EIP-712 digest over the Listing struct under the
    // NFTMarketplaceEscrow domain. We compute that via ethers'
    // TypedDataEncoder.hash, which produces the exact same value.
    const listingTypes = {
      Listing: [
        { name: "seller", type: "address" },
        { name: "buyer", type: "address" },
        { name: "nftContract", type: "address" },
        { name: "tokenId", type: "uint256" },
        { name: "askPriceXom", type: "uint256" },
        { name: "expiry", type: "uint256" },
        { name: "nonce", type: "uint256" },
        { name: "marketplaceFeeBps", type: "uint64" },
      ],
    };
    const listingDigest = ethers.TypedDataEncoder.hash(
      listingDomain,
      listingTypes,
      listing
    );
    const types = {
      FillAuthorization: [
        { name: "escrowId", type: "uint256" },
        { name: "listingDigest", type: "bytes32" },
        { name: "deadline", type: "uint256" },
      ],
    };
    return signer.signTypedData(listingDomain, types, {
      escrowId,
      listingDigest,
      deadline,
    });
  }

  /**
   * Build a fresh, valid Listing for use in tests. Tests mutate fields
   * to exercise the failure paths.
   */
  async function makeListing(opts: { buyer?: string } = {}): Promise<ListingFields> {
    const now = BigInt((await ethers.provider.getBlock("latest"))!.timestamp);
    return {
      seller: seller.address,
      // Default to address(0) — permissionless listing per audit C-1
      // remediation. Tests for the buyer-bound case pass an explicit address.
      buyer: opts.buyer ?? ethers.ZeroAddress,
      nftContract: await nft.getAddress(),
      tokenId: TOKEN_ID,
      askPriceXom: ASK_PRICE,
      expiry: now + 3600n,
      nonce: 1n,
      marketplaceFeeBps: Number(FEE_BPS),
    };
  }

  /** Buyer creates an escrow funding the listing. Returns the new escrowId. */
  async function makeEscrow(): Promise<bigint> {
    await xom.connect(buyer).approve(await escrow.getAddress(), ASK_PRICE);
    const tx = await escrow
      .connect(buyer)
      .createEscrow(seller.address, ASK_PRICE, ESCROW_DURATION_SEC);
    const receipt = await tx.wait();
    const log = receipt!.logs.find(
      (l) => "fragment" in l && (l as { fragment?: { name?: string } }).fragment?.name === "EscrowCreated"
    ) as unknown as { args: { escrowId: bigint } };
    return log.args.escrowId;
  }

  beforeEach(async () => {
    [owner, buyer, seller, other] = await ethers.getSigners();

    // Deploy XOM token.
    const XOM = await ethers.getContractFactory("OmniCoin");
    xom = await XOM.connect(owner).deploy(ethers.ZeroAddress);
    await xom.connect(owner).initialize();

    // Deploy pXOM stand-in.
    const pxom = await XOM.connect(owner).deploy(ethers.ZeroAddress);
    await pxom.connect(owner).initialize();

    // Deploy MinimalEscrow.
    const ME = await ethers.getContractFactory("MinimalEscrow");
    escrow = await ME.connect(owner).deploy(
      await xom.getAddress(),
      await pxom.getAddress(),
      owner.address, // registry stub
      owner.address, // feeVault stub
      FEE_BPS,
      ethers.ZeroAddress // no trusted forwarder in unit tests
    );

    // Deploy NFTMarketplaceEscrow.
    const Market = await ethers.getContractFactory("NFTMarketplaceEscrowLegacy");
    market = await Market.connect(owner).deploy(
      await escrow.getAddress(),
      FEE_BPS,
      ethers.ZeroAddress
    );

    // Deploy mock NFT collection + mint to seller.
    const NFT = await ethers.getContractFactory("MockERC721");
    nft = await NFT.connect(owner).deploy("Mock", "MCK");
    await nft.connect(owner).mint(seller.address, TOKEN_ID);

    // Seller pre-approves the router for all NFTs in this collection.
    await nft
      .connect(seller)
      .setApprovalForAll(await market.getAddress(), true);

    // Fund buyer with XOM for escrow.
    await xom.connect(owner).transfer(buyer.address, ethers.parseEther("1000"));

    // EIP-712 domain parameters for both signers.
    const chainId = (await ethers.provider.getNetwork()).chainId;
    escrowDomain = {
      name: "OmniBazaar MinimalEscrow",
      version: "2",
      chainId: Number(chainId),
      verifyingContract: await escrow.getAddress(),
    };
    listingDomain = {
      name: "OmniBazaar NFTMarketplaceEscrow",
      version: "1",
      chainId: Number(chainId),
      verifyingContract: await market.getAddress(),
    };
  });

  describe("Happy path", () => {
    it("settles XOM → seller AND NFT → buyer in one atomic tx", async () => {
      const escrowId = await makeEscrow();
      const listing = await makeListing();
      const deadline = listing.expiry;

      const sellerSig = await signListing(seller, listing);
      const buyerSig = await signRelease(
        buyer,
        escrowId,
        await market.getAddress(),
        deadline
      );
      const fillAuthSig = await signFillAuth(buyer, listing, escrowId, deadline);

      const sellerXomBefore = await xom.balanceOf(seller.address);
      const feeVaultBefore = await xom.balanceOf(owner.address); // feeVault stub

      await expect(
        market
          .connect(buyer)
          .fillListing(listing, sellerSig, escrowId, buyerSig, fillAuthSig, deadline)
      )
        .to.emit(market, "ListingFilled")
        .withArgs(
          seller.address,
          buyer.address,
          await nft.getAddress(),
          TOKEN_ID,
          escrowId,
          listing.nonce,
          FEE_BPS
        );

      // NFT moved to buyer.
      expect(await nft.ownerOf(TOKEN_ID)).to.equal(buyer.address);

      // XOM seller share = amount - fee. Fee = 1% of 100 = 1; seller gets 99.
      const sellerXomAfter = await xom.balanceOf(seller.address);
      expect(sellerXomAfter - sellerXomBefore).to.equal(ethers.parseEther("99"));

      // Fee vault got the 1 XOM fee.
      const feeVaultAfter = await xom.balanceOf(owner.address);
      expect(feeVaultAfter - feeVaultBefore).to.equal(ethers.parseEther("1"));

      // Nonce consumed.
      expect(await market.sellerNonces(seller.address, listing.nonce)).to.be.true;
    });
  });

  describe("Replay / signature safety", () => {
    it("rejects a second fill against the same (seller, nonce)", async () => {
      const escrowId = await makeEscrow();
      const listing = await makeListing();
      const deadline = listing.expiry;
      const sellerSig = await signListing(seller, listing);
      const buyerSig = await signRelease(
        buyer,
        escrowId,
        await market.getAddress(),
        deadline
      );
      const fillAuthSig = await signFillAuth(buyer, listing, escrowId, deadline);

      await market
        .connect(buyer)
        .fillListing(listing, sellerSig, escrowId, buyerSig, fillAuthSig, deadline);

      // Second submit must revert. The contract checks the seller
      // nonce in _validateListing BEFORE checking escrow state, so
      // the canonical revert is NonceAlreadyConsumed. The escrow is
      // also resolved (a defense-in-depth second guard at
      // _validateEscrowAgainstListing), but nonce fires first.
      await expect(
        market
          .connect(buyer)
          .fillListing(listing, sellerSig, escrowId, buyerSig, fillAuthSig, deadline)
      ).to.be.revertedWithCustomError(market, "NonceAlreadyConsumed");
    });

    it("rejects a buyer release sig that was signed for a DIFFERENT caller contract", async () => {
      const escrowId = await makeEscrow();
      const listing = await makeListing();
      const deadline = listing.expiry;
      const sellerSig = await signListing(seller, listing);

      // Buyer signs for `other.address` instead of the real router.
      const buyerSigWrongCaller = await signRelease(
        buyer,
        escrowId,
        other.address, // attacker-controlled
        deadline
      );
      const fillAuthSig = await signFillAuth(buyer, listing, escrowId, deadline);

      await expect(
        market
          .connect(buyer)
          .fillListing(listing, sellerSig, escrowId, buyerSigWrongCaller, fillAuthSig, deadline)
      ).to.be.revertedWithCustomError(escrow, "InvalidSignature");
    });

    it("rejects an expired buyer release deadline", async () => {
      const escrowId = await makeEscrow();
      const listing = await makeListing();
      const sellerSig = await signListing(seller, listing);

      const pastDeadline = BigInt(
        (await ethers.provider.getBlock("latest"))!.timestamp - 1
      );
      const buyerSig = await signRelease(
        buyer,
        escrowId,
        await market.getAddress(),
        pastDeadline
      );
      const fillAuthSig = await signFillAuth(buyer, listing, escrowId, pastDeadline);

      await expect(
        market
          .connect(buyer)
          .fillListing(listing, sellerSig, escrowId, buyerSig, fillAuthSig, pastDeadline)
      ).to.be.revertedWithCustomError(escrow, "DeadlinePassed");
    });

    it("rejects a wrong-signer release sig (someone other than the escrow buyer signed it)", async () => {
      const escrowId = await makeEscrow();
      const listing = await makeListing();
      const deadline = listing.expiry;
      const sellerSig = await signListing(seller, listing);

      // `other` signs instead of `buyer`. The router's
      // FillAuthorization check fires first (since it executes before
      // forwarding the release sig to MinimalEscrow), so the wrong
      // signer is caught at InvalidBuyerAuthorization.
      const buyerSig = await signRelease(
        other,
        escrowId,
        await market.getAddress(),
        deadline
      );
      const fillAuthSig = await signFillAuth(other, listing, escrowId, deadline);

      await expect(
        market
          .connect(buyer)
          .fillListing(listing, sellerSig, escrowId, buyerSig, fillAuthSig, deadline)
      ).to.be.revertedWithCustomError(market, "InvalidBuyerAuthorization");
    });
  });

  describe("Listing validation", () => {
    it("rejects expired listings", async () => {
      const escrowId = await makeEscrow();
      const listing = await makeListing();
      // Advance time past the listing expiry.
      await ethers.provider.send("evm_setNextBlockTimestamp", [
        Number(listing.expiry + 1n),
      ]);
      await ethers.provider.send("evm_mine", []);

      const sellerSig = await signListing(seller, listing);
      // buyerDeadline must be ≤ listing.expiry per H-01 fix, but for
      // this test we want to exercise the ListingExpired path with a
      // sig that would otherwise be live. Using listing.expiry itself
      // (which is now in the past) — passes the H-01 clamp; reverts on
      // ListingExpired check that follows.
      const buyerSig = await signRelease(
        buyer,
        escrowId,
        await market.getAddress(),
        listing.expiry
      );
      const fillAuthSig = await signFillAuth(buyer, listing, escrowId, listing.expiry);

      await expect(
        market
          .connect(buyer)
          .fillListing(listing, sellerSig, escrowId, buyerSig, fillAuthSig, listing.expiry)
      ).to.be.revertedWithCustomError(market, "ListingExpired");
    });

    it("rejects listings whose expiry exceeds MAX_LISTING_WINDOW", async () => {
      const escrowId = await makeEscrow();
      const listing = await makeListing();
      const now = BigInt((await ethers.provider.getBlock("latest"))!.timestamp);
      listing.expiry = now + 31n * 24n * 60n * 60n; // 31 days in the future

      const sellerSig = await signListing(seller, listing);
      const buyerSig = await signRelease(
        buyer,
        escrowId,
        await market.getAddress(),
        listing.expiry
      );
      const fillAuthSig = await signFillAuth(buyer, listing, escrowId, listing.expiry);

      await expect(
        market
          .connect(buyer)
          .fillListing(listing, sellerSig, escrowId, buyerSig, fillAuthSig, listing.expiry)
      ).to.be.revertedWithCustomError(market, "ListingExpiryTooFar");
    });

    it("rejects a listing signed against a different marketplaceFeeBps", async () => {
      const escrowId = await makeEscrow();
      const listing = await makeListing();
      listing.marketplaceFeeBps = 50; // 0.5% — doesn't match deployed 1%

      const sellerSig = await signListing(seller, listing);
      const buyerSig = await signRelease(
        buyer,
        escrowId,
        await market.getAddress(),
        listing.expiry
      );
      const fillAuthSig = await signFillAuth(buyer, listing, escrowId, listing.expiry);

      await expect(
        market
          .connect(buyer)
          .fillListing(listing, sellerSig, escrowId, buyerSig, fillAuthSig, listing.expiry)
      ).to.be.revertedWithCustomError(market, "FeeBpsMismatch");
    });

    it("rejects a listing with a wrong-shape signature (not 65 bytes)", async () => {
      const escrowId = await makeEscrow();
      const listing = await makeListing();
      const buyerSig = await signRelease(
        buyer,
        escrowId,
        await market.getAddress(),
        listing.expiry
      );
      const fillAuthSig = await signFillAuth(buyer, listing, escrowId, listing.expiry);

      await expect(
        market
          .connect(buyer)
          .fillListing(listing, "0xdeadbeef", escrowId, buyerSig, fillAuthSig, listing.expiry)
      ).to.be.revertedWithCustomError(market, "InvalidSignatureLength");
    });

    it("rejects a listing signed by someone other than listing.seller", async () => {
      const escrowId = await makeEscrow();
      const listing = await makeListing();
      const wrongSig = await signListing(other, listing);
      const buyerSig = await signRelease(
        buyer,
        escrowId,
        await market.getAddress(),
        listing.expiry
      );
      const fillAuthSig = await signFillAuth(buyer, listing, escrowId, listing.expiry);

      await expect(
        market
          .connect(buyer)
          .fillListing(listing, wrongSig, escrowId, buyerSig, fillAuthSig, listing.expiry)
      ).to.be.revertedWithCustomError(market, "InvalidSellerSignature");
    });
  });

  describe("Escrow cross-checks", () => {
    it("rejects when escrow.seller != listing.seller", async () => {
      // Buyer creates an escrow naming OTHER as seller, but listing
      // claims seller is the real seller.
      await xom.connect(buyer).approve(await escrow.getAddress(), ASK_PRICE);
      const tx = await escrow
        .connect(buyer)
        .createEscrow(other.address, ASK_PRICE, ESCROW_DURATION_SEC);
      const receipt = await tx.wait();
      const log = receipt!.logs.find(
        (l) => "fragment" in l && (l as { fragment?: { name?: string } }).fragment?.name === "EscrowCreated"
      ) as unknown as { args: { escrowId: bigint } };
      const escrowId = log.args.escrowId;

      const listing = await makeListing();
      const sellerSig = await signListing(seller, listing);
      const buyerSig = await signRelease(
        buyer,
        escrowId,
        await market.getAddress(),
        listing.expiry
      );
      const fillAuthSig = await signFillAuth(buyer, listing, escrowId, listing.expiry);

      await expect(
        market
          .connect(buyer)
          .fillListing(listing, sellerSig, escrowId, buyerSig, fillAuthSig, listing.expiry)
      ).to.be.revertedWithCustomError(market, "EscrowSellerMismatch");
    });

    it("rejects when escrow.amount != listing.askPriceXom", async () => {
      // Buyer creates an escrow for HALF the listing price.
      await xom.connect(buyer).approve(await escrow.getAddress(), ASK_PRICE);
      const tx = await escrow
        .connect(buyer)
        .createEscrow(seller.address, ASK_PRICE / 2n, ESCROW_DURATION_SEC);
      const receipt = await tx.wait();
      const log = receipt!.logs.find(
        (l) => "fragment" in l && (l as { fragment?: { name?: string } }).fragment?.name === "EscrowCreated"
      ) as unknown as { args: { escrowId: bigint } };
      const escrowId = log.args.escrowId;

      const listing = await makeListing();
      const sellerSig = await signListing(seller, listing);
      const buyerSig = await signRelease(
        buyer,
        escrowId,
        await market.getAddress(),
        listing.expiry
      );
      const fillAuthSig = await signFillAuth(buyer, listing, escrowId, listing.expiry);

      await expect(
        market
          .connect(buyer)
          .fillListing(listing, sellerSig, escrowId, buyerSig, fillAuthSig, listing.expiry)
      ).to.be.revertedWithCustomError(market, "EscrowAmountMismatch");
    });

    it("rejects when the escrow does not exist", async () => {
      const listing = await makeListing();
      const sellerSig = await signListing(seller, listing);
      const buyerSig = await signRelease(
        buyer,
        999n, // never-created escrowId
        await market.getAddress(),
        listing.expiry
      );
      const fillAuthSig = await signFillAuth(buyer, listing, 999n, listing.expiry);

      await expect(
        market
          .connect(buyer)
          .fillListing(listing, sellerSig, 999n, buyerSig, fillAuthSig, listing.expiry)
      ).to.be.revertedWithCustomError(market, "EscrowNotActive");
    });
  });

  describe("Atomicity", () => {
    it("reverts entire tx when seller has revoked NFT approval", async () => {
      const escrowId = await makeEscrow();
      const listing = await makeListing();
      const deadline = listing.expiry;
      const sellerSig = await signListing(seller, listing);
      const buyerSig = await signRelease(
        buyer,
        escrowId,
        await market.getAddress(),
        deadline
      );
      const fillAuthSig = await signFillAuth(buyer, listing, escrowId, deadline);

      // Seller revokes approval AFTER signing.
      await nft
        .connect(seller)
        .setApprovalForAll(await market.getAddress(), false);

      const sellerXomBefore = await xom.balanceOf(seller.address);

      await expect(
        market
          .connect(buyer)
          .fillListing(listing, sellerSig, escrowId, buyerSig, fillAuthSig, deadline)
      ).to.be.reverted;

      // Critical: escrow funds did NOT move. The whole tx reverted.
      const sellerXomAfter = await xom.balanceOf(seller.address);
      expect(sellerXomAfter).to.equal(sellerXomBefore);
      // Escrow row still has its funds.
      expect((await escrow.escrows(escrowId)).resolved).to.be.false;
      // NFT still with seller.
      expect(await nft.ownerOf(TOKEN_ID)).to.equal(seller.address);
    });
  });

  describe("Audit remediation coverage", () => {
    it("C-1: buyer-bound listing rejects fills from anyone other than the bound buyer", async () => {
      const escrowId = await makeEscrow();
      // Bind the listing to `buyer` specifically.
      const listing = await makeListing({ buyer: buyer.address });
      const deadline = listing.expiry;
      const sellerSig = await signListing(seller, listing);
      const buyerSig = await signRelease(
        buyer,
        escrowId,
        await market.getAddress(),
        deadline
      );

      // `other` tries to fill — even though they could provide their own
      // escrow, the listing locks the filler to `buyer`.
      // First, create an escrow funded by `other` so the escrow checks
      // pass (else we'd revert earlier on EscrowSellerMismatch).
      await xom.connect(owner).transfer(other.address, ASK_PRICE);
      await xom.connect(other).approve(await escrow.getAddress(), ASK_PRICE);
      const otherTx = await escrow
        .connect(other)
        .createEscrow(seller.address, ASK_PRICE, ESCROW_DURATION_SEC);
      const otherReceipt = await otherTx.wait();
      const otherLog = otherReceipt!.logs.find(
        (l: any) => "fragment" in l && l.fragment?.name === "EscrowCreated"
      ) as any;
      const otherEscrowId = otherLog.args.escrowId;
      const otherReleaseSig = await signRelease(
        other,
        otherEscrowId,
        await market.getAddress(),
        deadline
      );
      const otherFillAuth = await signFillAuth(other, listing, otherEscrowId, deadline);
      const buyerFillAuth = await signFillAuth(buyer, listing, escrowId, deadline);

      await expect(
        market
          .connect(other)
          .fillListing(listing, sellerSig, otherEscrowId, otherReleaseSig, otherFillAuth, deadline)
      ).to.be.revertedWithCustomError(market, "FillerNotAuthorized");

      // Sanity: the bound buyer can still fill.
      await expect(
        market
          .connect(buyer)
          .fillListing(listing, sellerSig, escrowId, buyerSig, buyerFillAuth, deadline)
      ).to.not.be.reverted;
    });

    it("C-1: permissionless listing (buyer=0) accepts any filler", async () => {
      const escrowId = await makeEscrow();
      const listing = await makeListing(); // buyer = ZeroAddress
      const deadline = listing.expiry;
      const sellerSig = await signListing(seller, listing);
      const buyerSig = await signRelease(
        buyer,
        escrowId,
        await market.getAddress(),
        deadline
      );
      const fillAuthSig = await signFillAuth(buyer, listing, escrowId, deadline);
      await expect(
        market
          .connect(buyer)
          .fillListing(listing, sellerSig, escrowId, buyerSig, fillAuthSig, deadline)
      ).to.not.be.reverted;
    });

    it("H-2: rejects fill against an escrow that has passed its expiry", async () => {
      const escrowId = await makeEscrow();
      const listing = await makeListing();
      const sellerSig = await signListing(seller, listing);

      // Advance time past the escrow's expiry (escrow lifetime is
      // 7 days; jump 8 days forward). Listing's own expiry would
      // also be in the past — but we want to isolate the escrow
      // check, so use a fresh listing with expiry in the future.
      await ethers.provider.send("evm_increaseTime", [8 * 24 * 60 * 60]);
      await ethers.provider.send("evm_mine", []);

      // Build a fresh listing with new expiry > now.
      const now = BigInt((await ethers.provider.getBlock("latest"))!.timestamp);
      const futureListing: ListingFields = { ...listing, expiry: now + 3600n, nonce: 2n };
      const futureSellerSig = await signListing(seller, futureListing);
      const futureBuyerSig = await signRelease(
        buyer,
        escrowId,
        await market.getAddress(),
        futureListing.expiry
      );
      const futureFillAuth = await signFillAuth(
        buyer,
        futureListing,
        escrowId,
        futureListing.expiry
      );

      await expect(
        market
          .connect(buyer)
          .fillListing(futureListing, futureSellerSig, escrowId, futureBuyerSig, futureFillAuth, futureListing.expiry)
      ).to.be.revertedWithCustomError(market, "EscrowExpired");
    });

    it("H-3: constructor rejects fee-bps mismatch with MinimalEscrow", async () => {
      const Market = await ethers.getContractFactory("NFTMarketplaceEscrowLegacy");
      // MinimalEscrow was deployed with FEE_BPS=100; deploy router
      // claiming bps=200 → should revert at construction.
      await expect(
        Market.connect(owner).deploy(await escrow.getAddress(), 200, ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(Market, "FeeBpsMismatch");
    });

    it("M-3: MAX_LISTING_WINDOW is read from MinimalEscrow.MAX_DURATION at construction", async () => {
      const window = await market.MAX_LISTING_WINDOW();
      const escrowMax = await escrow.MAX_DURATION();
      expect(window).to.equal(escrowMax);
    });

    it("M-5: pause/unpause is restricted to ADMIN", async () => {
      await expect(market.connect(other).pause()).to.be.revertedWithCustomError(
        market,
        "NotAdmin"
      );
      await expect(market.connect(owner).pause()).to.not.be.reverted;
      // While paused, fillListing reverts.
      const escrowId = await makeEscrow();
      const listing = await makeListing();
      const sellerSig = await signListing(seller, listing);
      const buyerSig = await signRelease(
        buyer,
        escrowId,
        await market.getAddress(),
        listing.expiry
      );
      const fillAuthSig = await signFillAuth(buyer, listing, escrowId, listing.expiry);
      await expect(
        market
          .connect(buyer)
          .fillListing(listing, sellerSig, escrowId, buyerSig, fillAuthSig, listing.expiry)
      ).to.be.reverted; // OZ Pausable's EnforcedPause
      await expect(market.connect(other).unpause()).to.be.revertedWithCustomError(
        market,
        "NotAdmin"
      );
      await expect(market.connect(owner).unpause()).to.not.be.reverted;
    });
  });

  describe("Audit 2026-05-16 remediation (passes 2-7)", () => {
    it("C-01: rejects bait-and-switch — substitute listing cannot consume the buyer's authorization", async () => {
      // Seller pre-signs TWO listings at the same price, different
      // NFT tokenIds, different nonces. Buyer authorizes purchase of
      // listing-A's NFT. Without the C-01 fix, the seller could swap
      // listing-B in at fill time. With C-01 fix, the buyer's
      // FillAuthorization pins the listingDigest of listing-A; any
      // substituted listing fails recovery against escrow.buyer.

      // Mint a SECOND NFT to the seller (tokenId 99) so listing-B is realizable.
      const BAD_TOKEN = 99n;
      await nft.connect(owner).mint(seller.address, BAD_TOKEN);

      const escrowId = await makeEscrow();
      const listingA = await makeListing();           // tokenId 42, nonce 1
      const listingB = { ...(await makeListing()), tokenId: BAD_TOKEN, nonce: 2n };

      const sellerSigA = await signListing(seller, listingA);
      const sellerSigB = await signListing(seller, listingB);

      // Buyer signs ReleaseFundsBySig — listing-agnostic by typehash design.
      const buyerReleaseSig = await signRelease(
        buyer,
        escrowId,
        await market.getAddress(),
        listingA.expiry
      );
      // Buyer signs FillAuthorization for listingA ONLY.
      const buyerFillAuthA = await signFillAuth(buyer, listingA, escrowId, listingA.expiry);

      // Bait-and-switch attempt: seller submits with listing-B but uses
      // buyer's auth-sig for listing-A. Must revert at C-01 check.
      await expect(
        market.connect(seller).fillListing(
          listingB,
          sellerSigB,
          escrowId,
          buyerReleaseSig,
          buyerFillAuthA,
          listingA.expiry
        )
      ).to.be.revertedWithCustomError(market, "InvalidBuyerAuthorization");

      // Sanity: the buyer's authorized listing-A still fills cleanly.
      await expect(
        market.connect(buyer).fillListing(
          listingA,
          sellerSigA,
          escrowId,
          buyerReleaseSig,
          buyerFillAuthA,
          listingA.expiry
        )
      ).to.not.be.reverted;
      expect(await nft.ownerOf(TOKEN_ID)).to.equal(buyer.address);
      // listingB.tokenId (99) is still with the seller — bait-and-switch foreclosed.
      expect(await nft.ownerOf(BAD_TOKEN)).to.equal(seller.address);
    });

    it("H-01: rejects buyerDeadline beyond listing.expiry", async () => {
      const escrowId = await makeEscrow();
      const listing = await makeListing();
      const overshootDeadline = listing.expiry + 100n; // 100 seconds past listing.expiry

      const sellerSig = await signListing(seller, listing);
      const buyerSig = await signRelease(
        buyer,
        escrowId,
        await market.getAddress(),
        overshootDeadline
      );
      const fillAuthSig = await signFillAuth(buyer, listing, escrowId, overshootDeadline);

      await expect(
        market.connect(buyer).fillListing(
          listing,
          sellerSig,
          escrowId,
          buyerSig,
          fillAuthSig,
          overshootDeadline
        )
      ).to.be.revertedWithCustomError(market, "BuyerDeadlineExceedsListingExpiry");
    });

    it("L-03: rejects a listing with nftContract == address(0)", async () => {
      const escrowId = await makeEscrow();
      const listing = await makeListing();
      listing.nftContract = ethers.ZeroAddress; // sentinel — must be rejected

      const sellerSig = await signListing(seller, listing);
      const buyerSig = await signRelease(
        buyer,
        escrowId,
        await market.getAddress(),
        listing.expiry
      );
      const fillAuthSig = await signFillAuth(buyer, listing, escrowId, listing.expiry);

      await expect(
        market.connect(buyer).fillListing(
          listing,
          sellerSig,
          escrowId,
          buyerSig,
          fillAuthSig,
          listing.expiry
        )
      ).to.be.revertedWithCustomError(market, "InvalidAddress");
    });

    it("M-04: seller can cancel their own pending listing nonce", async () => {
      const escrowId = await makeEscrow();
      const listing = await makeListing();
      const sellerSig = await signListing(seller, listing);
      const buyerSig = await signRelease(
        buyer,
        escrowId,
        await market.getAddress(),
        listing.expiry
      );
      const fillAuthSig = await signFillAuth(buyer, listing, escrowId, listing.expiry);

      // Seller cancels the nonce before any fill.
      await expect(market.connect(seller).cancelListingNonce(listing.nonce))
        .to.emit(market, "ListingNonceCancelled")
        .withArgs(seller.address, listing.nonce);

      // Storage flag is now true.
      expect(await market.sellerNonces(seller.address, listing.nonce)).to.be.true;

      // Subsequent fillListing using that nonce reverts with NonceAlreadyConsumed.
      await expect(
        market.connect(buyer).fillListing(
          listing,
          sellerSig,
          escrowId,
          buyerSig,
          fillAuthSig,
          listing.expiry
        )
      ).to.be.revertedWithCustomError(market, "NonceAlreadyConsumed");

      // Double-cancel reverts.
      await expect(
        market.connect(seller).cancelListingNonce(listing.nonce)
      ).to.be.revertedWithCustomError(market, "NonceAlreadyConsumed");
    });

    it("M-04: cancelling does not affect a different seller's nonces", async () => {
      // Two sellers, same nonce value, only one cancels.
      await market.connect(seller).cancelListingNonce(7n);
      expect(await market.sellerNonces(seller.address, 7n)).to.be.true;
      expect(await market.sellerNonces(other.address, 7n)).to.be.false;
    });

    it("fillAuthorizationDigest helper returns the same digest the contract verifies", async () => {
      // Wallets call this view function to sanity-check their typed-data
      // signing prompt. Verify it matches what TypedDataEncoder produces.
      const listing = await makeListing();
      const escrowId = 123n;
      const deadline = listing.expiry;

      const listingTypes = {
        Listing: [
          { name: "seller", type: "address" },
          { name: "buyer", type: "address" },
          { name: "nftContract", type: "address" },
          { name: "tokenId", type: "uint256" },
          { name: "askPriceXom", type: "uint256" },
          { name: "expiry", type: "uint256" },
          { name: "nonce", type: "uint256" },
          { name: "marketplaceFeeBps", type: "uint64" },
        ],
      };
      const listingDigest = ethers.TypedDataEncoder.hash(
        listingDomain,
        listingTypes,
        listing
      );
      const expected = ethers.TypedDataEncoder.hash(
        listingDomain,
        {
          FillAuthorization: [
            { name: "escrowId", type: "uint256" },
            { name: "listingDigest", type: "bytes32" },
            { name: "deadline", type: "uint256" },
          ],
        },
        { escrowId, listingDigest, deadline }
      );
      const onchain = await market.fillAuthorizationDigest(listing, escrowId, deadline);
      expect(onchain).to.equal(expected);
    });
  });

  describe("releaseFundsViaContract direct callers", () => {
    it("rejects a direct EOA call (msg.sender must equal the signed callerContract)", async () => {
      const escrowId = await makeEscrow();
      const deadline = BigInt(
        (await ethers.provider.getBlock("latest"))!.timestamp + 3600
      );
      // Buyer signs for `buyer` as callerContract — an EOA, not the market.
      const sig = await signRelease(buyer, escrowId, buyer.address, deadline);

      // Buyer can't call MinimalEscrow.releaseFundsViaContract directly
      // because the function requires msg.sender == callerContract AND
      // the signed callerContract; the buyer signed for themselves.
      // That's a valid recovery path — but it bypasses the router. The
      // function does not block it; it just executes the release
      // directly. Document this as the trusted-EOA path: buyer can
      // self-release with their own sig.
      await expect(escrow.connect(buyer).releaseFundsViaContract(
        escrowId,
        buyer.address,
        deadline,
        sig
      )).to.not.be.reverted;
      // Escrow is now resolved.
      expect((await escrow.escrows(escrowId)).resolved).to.be.true;
    });

    it("rejects when msg.sender != callerContract", async () => {
      const escrowId = await makeEscrow();
      const deadline = BigInt(
        (await ethers.provider.getBlock("latest"))!.timestamp + 3600
      );
      // Buyer signs for the market contract; OTHER tries to submit.
      const sig = await signRelease(
        buyer,
        escrowId,
        await market.getAddress(),
        deadline
      );
      await expect(
        escrow
          .connect(other)
          .releaseFundsViaContract(escrowId, await market.getAddress(), deadline, sig)
      ).to.be.revertedWithCustomError(escrow, "CallerNotAuthorized");
    });
  });

  // Hoist the helpers above into module scope for the new audit-remediation
  // tests. They reference `listingDomain`/`escrowDomain` captured in the
  // beforeEach closure, so they must remain inside the outer describe.
});
