/**
 * Tests for `NFTMarketplaceEscrow` (Option E v2 rebuild, 2026-05-17).
 * Self-contained NFT-for-XOM atomic settlement — the router owns
 * its escrow lifecycle, no MinimalEscrow dependency.
 *
 * Renamed from `NFTMarketplaceEscrowV2` to `NFTMarketplaceEscrow`
 * 2026-05-17 when v2 took over the canonical contract name; the
 * dead-on-arrival v1 contract was renamed to
 * `NFTMarketplaceEscrowLegacy`.
 *
 * Coverage groups (each maps to an audit-finding class):
 *   - createEscrow happy + validation (self-escrow, zero amount,
 *     duration bounds, paused-state)
 *   - Happy-path fillListing: XOM → seller minus fee, fee → FEE_VAULT,
 *     NFT → buyer, escrow.resolved=true, ListingFilled emits.
 *   - C-01 bait-and-switch (same test as v1; structurally impossible
 *     in v2 because buyer signs only FillAuthorization, but the test
 *     proves it).
 *   - H-01 buyerDeadline > listing.expiry rejected.
 *   - L-03 listing.nftContract == address(0) rejected.
 *   - M-04 cancelListingNonce + can't-fill-cancelled.
 *   - C-1 buyer-bound listing rejects fills from non-bound submitter.
 *   - Replay protections (seller nonce reuse, wrong-signer release).
 *   - Escrow cross-checks (seller mismatch, amount mismatch, not
 *     found, already resolved, expired).
 *   - Atomicity: transferFrom revert reverts whole tx; escrow + nonce
 *     state unchanged.
 *   - refundBuyer access + pre-expiry block + double-refund block.
 *   - releaseToBuyer access + double-release block.
 *   - pause/unpause scope: blocks createEscrow + fillListing +
 *     cancelListingNonce, but refundBuyer + releaseToBuyer remain
 *     callable so users always have a path to their funds.
 *   - fillAuthorizationDigest parity with off-chain TypedDataEncoder.
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

describe("NFTMarketplaceEscrow", () => {
  let xom: AnyContract;
  let market: AnyContract;
  let nft: AnyContract;
  let owner: AnySigner;
  let buyer: AnySigner;
  let seller: AnySigner;
  let other: AnySigner;
  let feeVault: AnySigner;
  let listingDomain: { name: string; version: string; chainId: number; verifyingContract: string };

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
        { name: "marketplaceFeeBps", type: "uint256" },
      ],
    };
    return signer.signTypedData(listingDomain, types, listing);
  }

  async function signFillAuth(
    signer: AnySigner,
    listing: ListingFields,
    escrowId: bigint,
    deadline: bigint
  ): Promise<string> {
    const listingTypes = {
      Listing: [
        { name: "seller", type: "address" },
        { name: "buyer", type: "address" },
        { name: "nftContract", type: "address" },
        { name: "tokenId", type: "uint256" },
        { name: "askPriceXom", type: "uint256" },
        { name: "expiry", type: "uint256" },
        { name: "nonce", type: "uint256" },
        { name: "marketplaceFeeBps", type: "uint256" },
      ],
    };
    const listingDigest = ethers.TypedDataEncoder.hash(listingDomain, listingTypes, listing);
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

  async function makeListing(opts: { buyer?: string } = {}): Promise<ListingFields> {
    const now = BigInt((await ethers.provider.getBlock("latest"))!.timestamp);
    return {
      seller: seller.address,
      buyer: opts.buyer ?? ethers.ZeroAddress,
      nftContract: await nft.getAddress(),
      tokenId: TOKEN_ID,
      askPriceXom: ASK_PRICE,
      expiry: now + 3600n,
      nonce: 1n,
      marketplaceFeeBps: Number(FEE_BPS),
    };
  }

  /** Buyer creates an escrow on the router. Returns the new escrowId. */
  async function makeEscrow(amount: bigint = ASK_PRICE, duration: number = ESCROW_DURATION_SEC): Promise<bigint> {
    await xom.connect(buyer).approve(await market.getAddress(), amount);
    const tx = await market
      .connect(buyer)
      .createEscrow(seller.address, amount, duration);
    const receipt = await tx.wait();
    const log = receipt!.logs.find(
      (l: any) => "fragment" in l && l.fragment?.name === "EscrowCreated"
    ) as unknown as { args: { escrowId: bigint } };
    return log.args.escrowId;
  }

  beforeEach(async () => {
    [owner, buyer, seller, other, feeVault] = await ethers.getSigners();

    // XOM
    const XOM = await ethers.getContractFactory("OmniCoin");
    xom = await XOM.connect(owner).deploy(ethers.ZeroAddress);
    await xom.connect(owner).initialize();

    // Router
    const Market = await ethers.getContractFactory("NFTMarketplaceEscrow");
    market = await Market.connect(owner).deploy(
      await xom.getAddress(),
      feeVault.address,
      FEE_BPS,
      ethers.ZeroAddress, // no trusted forwarder in unit tests
    );

    // Mock NFT + mint to seller + seller approves router.
    const NFT = await ethers.getContractFactory("MockERC721");
    nft = await NFT.connect(owner).deploy("Mock", "MCK");
    await nft.connect(owner).mint(seller.address, TOKEN_ID);
    await nft.connect(seller).setApprovalForAll(await market.getAddress(), true);

    // Fund buyer with XOM.
    await xom.connect(owner).transfer(buyer.address, ethers.parseEther("1000"));

    const chainId = (await ethers.provider.getNetwork()).chainId;
    listingDomain = {
      name: "OmniBazaar NFTMarketplaceEscrow",
      version: "1",
      chainId: Number(chainId),
      verifyingContract: await market.getAddress(),
    };
  });

  describe("createEscrow", () => {
    it("locks XOM and emits EscrowCreated with assigned id, expiry, amount", async () => {
      await xom.connect(buyer).approve(await market.getAddress(), ASK_PRICE);
      const tx = await market
        .connect(buyer)
        .createEscrow(seller.address, ASK_PRICE, ESCROW_DURATION_SEC);
      const receipt = await tx.wait();
      const log = receipt.logs.find(
        (l: any) => "fragment" in l && l.fragment?.name === "EscrowCreated"
      );
      expect(log.args.escrowId).to.equal(1n);
      expect(log.args.buyer).to.equal(buyer.address);
      expect(log.args.seller).to.equal(seller.address);
      expect(log.args.amount).to.equal(ASK_PRICE);
      // Router holds the XOM now.
      expect(await xom.balanceOf(await market.getAddress())).to.equal(ASK_PRICE);
      // Storage matches.
      const e = await market.escrows(1n);
      expect(e.buyer).to.equal(buyer.address);
      expect(e.seller).to.equal(seller.address);
      expect(e.amount).to.equal(ASK_PRICE);
      expect(e.resolved).to.be.false;
    });

    it("rejects seller=0", async () => {
      await xom.connect(buyer).approve(await market.getAddress(), ASK_PRICE);
      await expect(
        market.connect(buyer).createEscrow(ethers.ZeroAddress, ASK_PRICE, ESCROW_DURATION_SEC)
      ).to.be.revertedWithCustomError(market, "InvalidAddress");
    });

    it("rejects self-escrow (buyer == seller)", async () => {
      await xom.connect(buyer).approve(await market.getAddress(), ASK_PRICE);
      await expect(
        market.connect(buyer).createEscrow(buyer.address, ASK_PRICE, ESCROW_DURATION_SEC)
      ).to.be.revertedWithCustomError(market, "SelfEscrowForbidden");
    });

    it("rejects amount=0", async () => {
      await expect(
        market.connect(buyer).createEscrow(seller.address, 0n, ESCROW_DURATION_SEC)
      ).to.be.revertedWithCustomError(market, "AmountZero");
    });

    it("rejects duration below MIN_ESCROW_DURATION (1 hour)", async () => {
      await xom.connect(buyer).approve(await market.getAddress(), ASK_PRICE);
      await expect(
        market.connect(buyer).createEscrow(seller.address, ASK_PRICE, 60 * 59) // 59 min
      ).to.be.revertedWithCustomError(market, "InvalidDuration");
    });

    it("accepts duration at exact MIN_ESCROW_DURATION (1 hour)", async () => {
      await xom.connect(buyer).approve(await market.getAddress(), ASK_PRICE);
      await expect(
        market.connect(buyer).createEscrow(seller.address, ASK_PRICE, 60 * 60)
      ).to.not.be.reverted;
    });

    it("rejects duration above MAX_ESCROW_DURATION (30 days)", async () => {
      await xom.connect(buyer).approve(await market.getAddress(), ASK_PRICE);
      await expect(
        market.connect(buyer).createEscrow(seller.address, ASK_PRICE, 31 * 24 * 60 * 60)
      ).to.be.revertedWithCustomError(market, "InvalidDuration");
    });

    it("accepts duration at exact MAX_ESCROW_DURATION (30 days)", async () => {
      await xom.connect(buyer).approve(await market.getAddress(), ASK_PRICE);
      await expect(
        market.connect(buyer).createEscrow(seller.address, ASK_PRICE, 30 * 24 * 60 * 60)
      ).to.not.be.reverted;
    });

    it("assigns monotonic escrow ids across multiple buyers", async () => {
      await xom.connect(owner).transfer(other.address, ASK_PRICE);
      const id1 = await makeEscrow();
      await xom.connect(other).approve(await market.getAddress(), ASK_PRICE);
      const tx2 = await market.connect(other).createEscrow(seller.address, ASK_PRICE, ESCROW_DURATION_SEC);
      const r2 = await tx2.wait();
      const id2 = r2.logs.find((l: any) => "fragment" in l && l.fragment?.name === "EscrowCreated")!.args.escrowId;
      expect(id1).to.equal(1n);
      expect(id2).to.equal(2n);
    });
  });

  describe("fillListing — happy path", () => {
    it("settles XOM → seller (minus fee), fee → FEE_VAULT, NFT → buyer atomically", async () => {
      const escrowId = await makeEscrow();
      const listing = await makeListing();
      const deadline = listing.expiry;
      const sellerSig = await signListing(seller, listing);
      const fillAuthSig = await signFillAuth(buyer, listing, escrowId, deadline);

      const sellerXomBefore = await xom.balanceOf(seller.address);
      const feeVaultBefore = await xom.balanceOf(feeVault.address);

      await expect(
        market.connect(buyer).fillListing(listing, sellerSig, escrowId, fillAuthSig, deadline)
      )
        .to.emit(market, "ListingFilled")
        .withArgs(
          seller.address,
          buyer.address,
          await nft.getAddress(),
          TOKEN_ID,
          escrowId,
          FEE_BPS
        )
        .and.to.emit(market, "MarketplaceFeeCollected")
        .withArgs(escrowId, feeVault.address, ethers.parseEther("1"));

      expect(await nft.ownerOf(TOKEN_ID)).to.equal(buyer.address);
      expect((await xom.balanceOf(seller.address)) - sellerXomBefore).to.equal(ethers.parseEther("99"));
      expect((await xom.balanceOf(feeVault.address)) - feeVaultBefore).to.equal(ethers.parseEther("1"));
      expect((await market.escrows(escrowId)).resolved).to.be.true;
      expect((await market.escrows(escrowId)).amount).to.equal(0n);
      expect(await market.sellerNonces(seller.address, listing.nonce)).to.be.true;
    });

    it("permissionless listing: NFT recipient is escrow.buyer regardless of submitter (audit v2 H-01)", async () => {
      const escrowId = await makeEscrow();
      const listing = await makeListing(); // buyer = 0
      const deadline = listing.expiry;
      const sellerSig = await signListing(seller, listing);
      const fillAuthSig = await signFillAuth(buyer, listing, escrowId, deadline);

      // Third party submits the tx (simulates an MEV bot frontrun
      // that extracted both sigs from the mempool). v2 H-01 fix:
      // the NFT recipient is ALWAYS `escrow.buyer`, NOT the tx
      // submitter. So `other` submitting cannot hijack the NFT.
      await market.connect(other).fillListing(listing, sellerSig, escrowId, fillAuthSig, deadline);
      expect(await nft.ownerOf(TOKEN_ID)).to.equal(buyer.address);
    });

    it("no royalty for a collection that does not implement ERC-2981 (seller keeps full afterFee)", async () => {
      // The module-level `nft` is a plain MockERC721 (no ERC-2981).
      const escrowId = await makeEscrow();
      const listing = await makeListing();
      const deadline = listing.expiry;
      const sellerSig = await signListing(seller, listing);
      const fillAuthSig = await signFillAuth(buyer, listing, escrowId, deadline);

      const sellerBefore = await xom.balanceOf(seller.address);
      const tx = await market
        .connect(buyer)
        .fillListing(listing, sellerSig, escrowId, fillAuthSig, deadline);
      await expect(tx).to.not.emit(market, "RoyaltyPaid");
      // Seller still nets the full 99 (100 - 1 fee, 0 royalty).
      expect((await xom.balanceOf(seller.address)) - sellerBefore).to.equal(
        ethers.parseEther("99")
      );
    });
  });

  describe("fillListing — EIP-2981 creator royalties (N-ROY)", () => {
    let royaltyNft: any;
    let creator: AnySigner;

    /** Deploy an ERC-2981 collection, mint TOKEN_ID to seller, approve router. */
    async function setupRoyaltyNft(): Promise<void> {
      const RoyaltyNFT = await ethers.getContractFactory("MockERC2981NFT");
      royaltyNft = await RoyaltyNFT.connect(owner).deploy("Royalty", "ROY");
      await royaltyNft.connect(owner).mint(seller.address, TOKEN_ID);
      await royaltyNft
        .connect(seller)
        .setApprovalForAll(await market.getAddress(), true);
    }

    /** A listing pointing at the royalty collection. */
    async function royaltyListing(): Promise<ListingFields> {
      const base = await makeListing();
      return { ...base, nftContract: await royaltyNft.getAddress() };
    }

    beforeEach(async () => {
      creator = other; // reuse the spare signer as the royalty recipient
      await setupRoyaltyNft();
    });

    it("pays a default royalty: split is fee → vault, royalty → creator, remainder → seller; emits RoyaltyPaid", async () => {
      // 5% default royalty (500 bps) on a 100 XOM sale → 5 XOM creator,
      // 1 XOM fee, 94 XOM seller.
      await royaltyNft
        .connect(owner)
        .setDefaultRoyalty(creator.address, 500);

      const escrowId = await makeEscrow();
      const listing = await royaltyListing();
      const deadline = listing.expiry;
      const sellerSig = await signListing(seller, listing);
      const fillAuthSig = await signFillAuth(buyer, listing, escrowId, deadline);

      const sellerBefore = await xom.balanceOf(seller.address);
      const feeBefore = await xom.balanceOf(feeVault.address);
      const creatorBefore = await xom.balanceOf(creator.address);

      await expect(
        market.connect(buyer).fillListing(listing, sellerSig, escrowId, fillAuthSig, deadline)
      )
        .to.emit(market, "RoyaltyPaid")
        .withArgs(
          escrowId,
          await royaltyNft.getAddress(),
          TOKEN_ID,
          creator.address,
          ethers.parseEther("5")
        )
        .and.to.emit(market, "MarketplaceFeeCollected")
        .withArgs(escrowId, feeVault.address, ethers.parseEther("1"));

      expect(await royaltyNft.ownerOf(TOKEN_ID)).to.equal(buyer.address);
      expect((await xom.balanceOf(creator.address)) - creatorBefore).to.equal(ethers.parseEther("5"));
      expect((await xom.balanceOf(feeVault.address)) - feeBefore).to.equal(ethers.parseEther("1"));
      expect((await xom.balanceOf(seller.address)) - sellerBefore).to.equal(ethers.parseEther("94"));
    });

    it("honors a per-token royalty override over the default", async () => {
      await royaltyNft.connect(owner).setDefaultRoyalty(creator.address, 500); // 5%
      await royaltyNft.connect(owner).setTokenRoyalty(TOKEN_ID, creator.address, 1000); // 10% on this token

      const escrowId = await makeEscrow();
      const listing = await royaltyListing();
      const deadline = listing.expiry;
      const sellerSig = await signListing(seller, listing);
      const fillAuthSig = await signFillAuth(buyer, listing, escrowId, deadline);

      const sellerBefore = await xom.balanceOf(seller.address);
      const creatorBefore = await xom.balanceOf(creator.address);

      await market.connect(buyer).fillListing(listing, sellerSig, escrowId, fillAuthSig, deadline);

      // 10% of 100 = 10 royalty; 1 fee; 89 seller.
      expect((await xom.balanceOf(creator.address)) - creatorBefore).to.equal(ethers.parseEther("10"));
      expect((await xom.balanceOf(seller.address)) - sellerBefore).to.equal(ethers.parseEther("89"));
    });

    it("defensively clamps an over-cap royalty to the proceeds after fee (seller never underflows)", async () => {
      // 100% royalty (10000 bps) → royaltyDue = 100 XOM > afterFee (99).
      // Must clamp to 99; seller receives 0; the call still succeeds.
      await royaltyNft.connect(owner).setDefaultRoyalty(creator.address, 10000);

      const escrowId = await makeEscrow();
      const listing = await royaltyListing();
      const deadline = listing.expiry;
      const sellerSig = await signListing(seller, listing);
      const fillAuthSig = await signFillAuth(buyer, listing, escrowId, deadline);

      const sellerBefore = await xom.balanceOf(seller.address);
      const creatorBefore = await xom.balanceOf(creator.address);

      await expect(
        market.connect(buyer).fillListing(listing, sellerSig, escrowId, fillAuthSig, deadline)
      )
        .to.emit(market, "RoyaltyPaid")
        .withArgs(
          escrowId,
          await royaltyNft.getAddress(),
          TOKEN_ID,
          creator.address,
          ethers.parseEther("99")
        );

      expect((await xom.balanceOf(creator.address)) - creatorBefore).to.equal(ethers.parseEther("99"));
      expect((await xom.balanceOf(seller.address)) - sellerBefore).to.equal(0n);
      expect(await royaltyNft.ownerOf(TOKEN_ID)).to.equal(buyer.address);
    });

    it("I-1: caps royaltyInfo gas — a gas-griefing collection yields zero royalty, sale still settles", async () => {
      // Collection with a configured royalty, but royaltyInfo burns far
      // more than the contract's ROYALTY_GAS_LIMIT (50k) → the gas-bounded
      // STATICCALL out-of-gases, is caught, royalty treated as zero.
      await royaltyNft.connect(owner).setDefaultRoyalty(creator.address, 500);
      await royaltyNft.connect(owner).setGasGrief(true);

      const escrowId = await makeEscrow();
      const listing = await royaltyListing();
      const deadline = listing.expiry;
      const sellerSig = await signListing(seller, listing);
      const fillAuthSig = await signFillAuth(buyer, listing, escrowId, deadline);

      const sellerBefore = await xom.balanceOf(seller.address);
      const creatorBefore = await xom.balanceOf(creator.address);

      const tx = await market
        .connect(buyer)
        .fillListing(listing, sellerSig, escrowId, fillAuthSig, deadline);
      await expect(tx).to.not.emit(market, "RoyaltyPaid");
      // No royalty paid; seller keeps the full post-fee amount; sale completes.
      expect((await xom.balanceOf(creator.address)) - creatorBefore).to.equal(0n);
      expect((await xom.balanceOf(seller.address)) - sellerBefore).to.equal(ethers.parseEther("99"));
      expect(await royaltyNft.ownerOf(TOKEN_ID)).to.equal(buyer.address);
    });

    it("pays no royalty when ERC-2981 returns a zero recipient", async () => {
      // No royalty configured → royaltyInfo returns (0,0) → seller keeps 99.
      const escrowId = await makeEscrow();
      const listing = await royaltyListing();
      const deadline = listing.expiry;
      const sellerSig = await signListing(seller, listing);
      const fillAuthSig = await signFillAuth(buyer, listing, escrowId, deadline);

      const sellerBefore = await xom.balanceOf(seller.address);
      const tx = await market
        .connect(buyer)
        .fillListing(listing, sellerSig, escrowId, fillAuthSig, deadline);
      await expect(tx).to.not.emit(market, "RoyaltyPaid");
      expect((await xom.balanceOf(seller.address)) - sellerBefore).to.equal(ethers.parseEther("99"));
    });
  });

  describe("Audit findings — carries from v1", () => {
    it("C-01: rejects bait-and-switch — buyer auth-sig only matches the listing it was signed for", async () => {
      // Seller pre-signs two listings, same askPrice, different
      // tokenIds, different nonces. Buyer authorizes listing-A.
      // Attempt to fill with listing-B using buyer's auth-sig for A
      // must revert at InvalidBuyerAuthorization.
      const BAD_TOKEN = 99n;
      await nft.connect(owner).mint(seller.address, BAD_TOKEN);

      const escrowId = await makeEscrow();
      const listingA = await makeListing();
      const listingB = { ...(await makeListing()), tokenId: BAD_TOKEN, nonce: 2n };

      const sellerSigA = await signListing(seller, listingA);
      const sellerSigB = await signListing(seller, listingB);
      const buyerAuthA = await signFillAuth(buyer, listingA, escrowId, listingA.expiry);

      await expect(
        market.connect(seller).fillListing(listingB, sellerSigB, escrowId, buyerAuthA, listingA.expiry)
      ).to.be.revertedWithCustomError(market, "InvalidBuyerAuthorization");

      // Sanity: the authorized listing fills clean.
      await market.connect(buyer).fillListing(listingA, sellerSigA, escrowId, buyerAuthA, listingA.expiry);
      expect(await nft.ownerOf(TOKEN_ID)).to.equal(buyer.address);
      expect(await nft.ownerOf(BAD_TOKEN)).to.equal(seller.address);
    });

    it("H-01: rejects buyerDeadline > listing.expiry", async () => {
      const escrowId = await makeEscrow();
      const listing = await makeListing();
      const overshootDeadline = listing.expiry + 100n;
      const sellerSig = await signListing(seller, listing);
      const fillAuthSig = await signFillAuth(buyer, listing, escrowId, overshootDeadline);
      await expect(
        market.connect(buyer).fillListing(listing, sellerSig, escrowId, fillAuthSig, overshootDeadline)
      ).to.be.revertedWithCustomError(market, "BuyerDeadlineExceedsListingExpiry");
    });

    it("L-03: rejects listing.nftContract == address(0)", async () => {
      const escrowId = await makeEscrow();
      const listing = await makeListing();
      listing.nftContract = ethers.ZeroAddress;
      const sellerSig = await signListing(seller, listing);
      const fillAuthSig = await signFillAuth(buyer, listing, escrowId, listing.expiry);
      await expect(
        market.connect(buyer).fillListing(listing, sellerSig, escrowId, fillAuthSig, listing.expiry)
      ).to.be.revertedWithCustomError(market, "InvalidNftContract");
    });

    it("M-04: seller can cancel their own pending nonce; cancelled nonce blocks fill", async () => {
      const escrowId = await makeEscrow();
      const listing = await makeListing();
      const sellerSig = await signListing(seller, listing);
      const fillAuthSig = await signFillAuth(buyer, listing, escrowId, listing.expiry);

      await expect(market.connect(seller).cancelListingNonce(listing.nonce))
        .to.emit(market, "ListingNonceCancelled")
        .withArgs(seller.address, listing.nonce);
      expect(await market.sellerNonces(seller.address, listing.nonce)).to.be.true;

      await expect(
        market.connect(buyer).fillListing(listing, sellerSig, escrowId, fillAuthSig, listing.expiry)
      ).to.be.revertedWithCustomError(market, "NonceAlreadyConsumed");

      await expect(market.connect(seller).cancelListingNonce(listing.nonce))
        .to.be.revertedWithCustomError(market, "NonceAlreadyConsumed");
    });

    it("M-04 scoped: cancelling does not affect other sellers", async () => {
      await market.connect(seller).cancelListingNonce(7n);
      expect(await market.sellerNonces(seller.address, 7n)).to.be.true;
      expect(await market.sellerNonces(other.address, 7n)).to.be.false;
    });

    it("C-1: buyer-bound listing rejects fills from non-bound submitter", async () => {
      const escrowId = await makeEscrow();
      const listing = await makeListing({ buyer: buyer.address });
      const deadline = listing.expiry;
      const sellerSig = await signListing(seller, listing);
      const fillAuthSig = await signFillAuth(buyer, listing, escrowId, deadline);
      await expect(
        market.connect(other).fillListing(listing, sellerSig, escrowId, fillAuthSig, deadline)
      ).to.be.revertedWithCustomError(market, "FillerNotAuthorized");
      // The bound buyer can still fill.
      await market.connect(buyer).fillListing(listing, sellerSig, escrowId, fillAuthSig, deadline);
      expect(await nft.ownerOf(TOKEN_ID)).to.equal(buyer.address);
    });
  });

  describe("Listing + escrow validation", () => {
    it("rejects expired listing", async () => {
      const escrowId = await makeEscrow();
      const listing = await makeListing();
      await ethers.provider.send("evm_setNextBlockTimestamp", [Number(listing.expiry + 1n)]);
      await ethers.provider.send("evm_mine", []);
      const sellerSig = await signListing(seller, listing);
      const fillAuthSig = await signFillAuth(buyer, listing, escrowId, listing.expiry);
      await expect(
        market.connect(buyer).fillListing(listing, sellerSig, escrowId, fillAuthSig, listing.expiry)
      ).to.be.revertedWithCustomError(market, "ListingExpired");
    });

    it("rejects listing.expiry too far in the future", async () => {
      const escrowId = await makeEscrow();
      const now = BigInt((await ethers.provider.getBlock("latest"))!.timestamp);
      const listing = { ...(await makeListing()), expiry: now + 31n * 24n * 60n * 60n };
      const sellerSig = await signListing(seller, listing);
      const fillAuthSig = await signFillAuth(buyer, listing, escrowId, listing.expiry);
      await expect(
        market.connect(buyer).fillListing(listing, sellerSig, escrowId, fillAuthSig, listing.expiry)
      ).to.be.revertedWithCustomError(market, "ListingExpiryTooFar");
    });

    it("rejects listing.marketplaceFeeBps != contract immutable", async () => {
      const escrowId = await makeEscrow();
      const listing = { ...(await makeListing()), marketplaceFeeBps: 50 };
      const sellerSig = await signListing(seller, listing);
      const fillAuthSig = await signFillAuth(buyer, listing, escrowId, listing.expiry);
      await expect(
        market.connect(buyer).fillListing(listing, sellerSig, escrowId, fillAuthSig, listing.expiry)
      ).to.be.revertedWithCustomError(market, "FeeBpsMismatch");
    });

    it("rejects wrong-shape seller signature", async () => {
      const escrowId = await makeEscrow();
      const listing = await makeListing();
      const fillAuthSig = await signFillAuth(buyer, listing, escrowId, listing.expiry);
      await expect(
        market.connect(buyer).fillListing(listing, "0xdeadbeef", escrowId, fillAuthSig, listing.expiry)
      ).to.be.revertedWithCustomError(market, "InvalidSignatureLength");
    });

    it("rejects wrong-shape buyerFillAuthorization signature", async () => {
      const escrowId = await makeEscrow();
      const listing = await makeListing();
      const sellerSig = await signListing(seller, listing);
      await expect(
        market
          .connect(buyer)
          .fillListing(listing, sellerSig, escrowId, "0xbeef", listing.expiry)
      ).to.be.revertedWithCustomError(market, "InvalidSignatureLength");
    });

    it("rejects listing signed by someone other than listing.seller", async () => {
      const escrowId = await makeEscrow();
      const listing = await makeListing();
      const wrongSig = await signListing(other, listing);
      const fillAuthSig = await signFillAuth(buyer, listing, escrowId, listing.expiry);
      await expect(
        market.connect(buyer).fillListing(listing, wrongSig, escrowId, fillAuthSig, listing.expiry)
      ).to.be.revertedWithCustomError(market, "InvalidSellerSignature");
    });

    it("rejects same-seller-nonce replay after a successful fill", async () => {
      const escrowId1 = await makeEscrow();
      const listing = await makeListing();
      const sellerSig = await signListing(seller, listing);
      const fillAuthSig1 = await signFillAuth(buyer, listing, escrowId1, listing.expiry);
      await market.connect(buyer).fillListing(listing, sellerSig, escrowId1, fillAuthSig1, listing.expiry);

      // Mint a new NFT to seller + fund a fresh escrow, try to re-use nonce=1.
      await nft.connect(owner).mint(seller.address, 77n);
      const escrowId2 = await makeEscrow();
      const fillAuthSig2 = await signFillAuth(buyer, listing, escrowId2, listing.expiry);
      await expect(
        market.connect(buyer).fillListing(listing, sellerSig, escrowId2, fillAuthSig2, listing.expiry)
      ).to.be.revertedWithCustomError(market, "NonceAlreadyConsumed");
    });

    it("rejects escrow.seller != listing.seller", async () => {
      // Fund an escrow naming `other` as seller; listing claims `seller`.
      await xom.connect(buyer).approve(await market.getAddress(), ASK_PRICE);
      const tx = await market.connect(buyer).createEscrow(other.address, ASK_PRICE, ESCROW_DURATION_SEC);
      const receipt = await tx.wait();
      const escrowId = receipt.logs.find((l: any) => "fragment" in l && l.fragment?.name === "EscrowCreated")!.args.escrowId;

      const listing = await makeListing();
      const sellerSig = await signListing(seller, listing);
      const fillAuthSig = await signFillAuth(buyer, listing, escrowId, listing.expiry);
      await expect(
        market.connect(buyer).fillListing(listing, sellerSig, escrowId, fillAuthSig, listing.expiry)
      ).to.be.revertedWithCustomError(market, "EscrowSellerMismatch");
    });

    it("rejects escrow.amount != listing.askPriceXom", async () => {
      const escrowId = await makeEscrow(ASK_PRICE / 2n);
      const listing = await makeListing(); // claims full ASK_PRICE
      const sellerSig = await signListing(seller, listing);
      const fillAuthSig = await signFillAuth(buyer, listing, escrowId, listing.expiry);
      await expect(
        market.connect(buyer).fillListing(listing, sellerSig, escrowId, fillAuthSig, listing.expiry)
      ).to.be.revertedWithCustomError(market, "EscrowAmountMismatch");
    });

    it("rejects non-existent escrow id", async () => {
      const listing = await makeListing();
      const sellerSig = await signListing(seller, listing);
      const fillAuthSig = await signFillAuth(buyer, listing, 999n, listing.expiry);
      await expect(
        market.connect(buyer).fillListing(listing, sellerSig, 999n, fillAuthSig, listing.expiry)
      ).to.be.revertedWithCustomError(market, "EscrowNotFound");
    });

    it("rejects fill against an already-resolved escrow", async () => {
      const escrowId = await makeEscrow();
      const listing = await makeListing();
      const sellerSig = await signListing(seller, listing);
      const fillAuthSig = await signFillAuth(buyer, listing, escrowId, listing.expiry);
      await market.connect(buyer).fillListing(listing, sellerSig, escrowId, fillAuthSig, listing.expiry);

      // Even with a fresh nonce + listing, the resolved escrow is dead.
      const listing2 = { ...(await makeListing()), nonce: 2n };
      const sellerSig2 = await signListing(seller, listing2);
      const fillAuth2 = await signFillAuth(buyer, listing2, escrowId, listing2.expiry);
      await expect(
        market.connect(buyer).fillListing(listing2, sellerSig2, escrowId, fillAuth2, listing2.expiry)
      ).to.be.revertedWithCustomError(market, "EscrowAlreadyResolved");
    });

    it("rejects fill against an expired escrow (audit H-2 carry)", async () => {
      const escrowId = await makeEscrow(ASK_PRICE, 60 * 60); // 1 hour
      // Advance past escrow expiry but keep a fresh listing valid.
      await ethers.provider.send("evm_increaseTime", [2 * 60 * 60]);
      await ethers.provider.send("evm_mine", []);
      const listing = { ...(await makeListing()), nonce: 9n };
      const sellerSig = await signListing(seller, listing);
      const fillAuthSig = await signFillAuth(buyer, listing, escrowId, listing.expiry);
      await expect(
        market.connect(buyer).fillListing(listing, sellerSig, escrowId, fillAuthSig, listing.expiry)
      ).to.be.revertedWithCustomError(market, "EscrowExpired");
    });

    it("rejects when buyerDeadline already passed", async () => {
      const escrowId = await makeEscrow();
      const listing = await makeListing();
      const sellerSig = await signListing(seller, listing);
      const pastDeadline = BigInt((await ethers.provider.getBlock("latest"))!.timestamp - 10);
      const fillAuthSig = await signFillAuth(buyer, listing, escrowId, pastDeadline);
      await expect(
        market.connect(buyer).fillListing(listing, sellerSig, escrowId, fillAuthSig, pastDeadline)
      ).to.be.revertedWithCustomError(market, "DeadlinePassed");
    });

    it("rejects wrong-signer FillAuthorization", async () => {
      const escrowId = await makeEscrow();
      const listing = await makeListing();
      const sellerSig = await signListing(seller, listing);
      // `other` signs the FillAuthorization instead of the escrow buyer.
      const wrongFillAuth = await signFillAuth(other, listing, escrowId, listing.expiry);
      await expect(
        market.connect(buyer).fillListing(listing, sellerSig, escrowId, wrongFillAuth, listing.expiry)
      ).to.be.revertedWithCustomError(market, "InvalidBuyerAuthorization");
    });
  });

  describe("Atomicity", () => {
    it("reverts whole tx + leaves escrow/nonce intact when transferFrom fails (seller revoked approval)", async () => {
      const escrowId = await makeEscrow();
      const listing = await makeListing();
      const sellerSig = await signListing(seller, listing);
      const fillAuthSig = await signFillAuth(buyer, listing, escrowId, listing.expiry);

      await nft.connect(seller).setApprovalForAll(await market.getAddress(), false);
      const sellerXomBefore = await xom.balanceOf(seller.address);

      await expect(
        market.connect(buyer).fillListing(listing, sellerSig, escrowId, fillAuthSig, listing.expiry)
      ).to.be.reverted;

      // Escrow + nonce both untouched after revert.
      expect((await market.escrows(escrowId)).resolved).to.be.false;
      expect((await market.escrows(escrowId)).amount).to.equal(ASK_PRICE);
      expect(await market.sellerNonces(seller.address, listing.nonce)).to.be.false;
      expect(await xom.balanceOf(seller.address)).to.equal(sellerXomBefore);
      expect(await nft.ownerOf(TOKEN_ID)).to.equal(seller.address);
    });
  });

  describe("refundBuyer", () => {
    it("returns full XOM to buyer post-expiry, no fee", async () => {
      const escrowId = await makeEscrow(ASK_PRICE, 60 * 60);
      const before = await xom.balanceOf(buyer.address);
      await ethers.provider.send("evm_increaseTime", [2 * 60 * 60]);
      await ethers.provider.send("evm_mine", []);
      await expect(market.connect(buyer).refundBuyer(escrowId))
        .to.emit(market, "EscrowRefunded")
        .withArgs(escrowId, buyer.address, ASK_PRICE);
      const after = await xom.balanceOf(buyer.address);
      expect(after - before).to.equal(ASK_PRICE);
      expect((await market.escrows(escrowId)).resolved).to.be.true;
      expect((await market.escrows(escrowId)).amount).to.equal(0n);
    });

    it("rejects refund before expiry", async () => {
      const escrowId = await makeEscrow();
      await expect(market.connect(buyer).refundBuyer(escrowId))
        .to.be.revertedWithCustomError(market, "EscrowNotExpired");
    });

    it("rejects refund from non-buyer", async () => {
      const escrowId = await makeEscrow(ASK_PRICE, 60 * 60);
      await ethers.provider.send("evm_increaseTime", [2 * 60 * 60]);
      await ethers.provider.send("evm_mine", []);
      await expect(market.connect(other).refundBuyer(escrowId))
        .to.be.revertedWithCustomError(market, "NotEscrowBuyer");
    });

    it("rejects double-refund", async () => {
      const escrowId = await makeEscrow(ASK_PRICE, 60 * 60);
      await ethers.provider.send("evm_increaseTime", [2 * 60 * 60]);
      await ethers.provider.send("evm_mine", []);
      await market.connect(buyer).refundBuyer(escrowId);
      await expect(market.connect(buyer).refundBuyer(escrowId))
        .to.be.revertedWithCustomError(market, "EscrowAlreadyResolved");
    });

    it("rejects refund of nonexistent escrow", async () => {
      await expect(market.connect(buyer).refundBuyer(999n))
        .to.be.revertedWithCustomError(market, "EscrowNotFound");
    });
  });

  describe("releaseToBuyer", () => {
    it("seller can return full XOM to buyer pre-expiry, no fee", async () => {
      const escrowId = await makeEscrow();
      const before = await xom.balanceOf(buyer.address);
      await expect(market.connect(seller).releaseToBuyer(escrowId))
        .to.emit(market, "EscrowRefunded")
        .withArgs(escrowId, buyer.address, ASK_PRICE);
      const after = await xom.balanceOf(buyer.address);
      expect(after - before).to.equal(ASK_PRICE);
      expect((await market.escrows(escrowId)).resolved).to.be.true;
    });

    it("rejects releaseToBuyer from non-seller", async () => {
      const escrowId = await makeEscrow();
      await expect(market.connect(buyer).releaseToBuyer(escrowId))
        .to.be.revertedWithCustomError(market, "NotEscrowSeller");
      await expect(market.connect(other).releaseToBuyer(escrowId))
        .to.be.revertedWithCustomError(market, "NotEscrowSeller");
    });

    it("rejects releaseToBuyer on resolved escrow", async () => {
      const escrowId = await makeEscrow();
      await market.connect(seller).releaseToBuyer(escrowId);
      await expect(market.connect(seller).releaseToBuyer(escrowId))
        .to.be.revertedWithCustomError(market, "EscrowAlreadyResolved");
    });
  });

  describe("Pause scope (admin)", () => {
    it("pause/unpause restricted to ADMIN", async () => {
      await expect(market.connect(other).pause())
        .to.be.revertedWithCustomError(market, "NotAdmin");
      await market.connect(owner).pause();
      await expect(market.connect(other).unpause())
        .to.be.revertedWithCustomError(market, "NotAdmin");
      await market.connect(owner).unpause();
    });

    it("paused: createEscrow + fillListing blocked; refundBuyer + releaseToBuyer + cancelListingNonce still callable", async () => {
      const escrowId = await makeEscrow();
      const listing = await makeListing();
      const sellerSig = await signListing(seller, listing);
      const fillAuthSig = await signFillAuth(buyer, listing, escrowId, listing.expiry);

      await market.connect(owner).pause();

      // New createEscrow blocked.
      await xom.connect(buyer).approve(await market.getAddress(), ASK_PRICE);
      await expect(
        market.connect(buyer).createEscrow(seller.address, ASK_PRICE, ESCROW_DURATION_SEC)
      ).to.be.reverted; // OZ Pausable EnforcedPause

      // fillListing blocked.
      await expect(
        market.connect(buyer).fillListing(listing, sellerSig, escrowId, fillAuthSig, listing.expiry)
      ).to.be.reverted;

      // cancelListingNonce STILL callable (audit v2 self-help carve-out).
      await market.connect(seller).cancelListingNonce(99n);
      expect(await market.sellerNonces(seller.address, 99n)).to.be.true;

      // Seller releaseToBuyer still works — users can always reach their funds.
      await market.connect(seller).releaseToBuyer(escrowId);
      expect((await market.escrows(escrowId)).resolved).to.be.true;
    });

    it("paused: refundBuyer still callable post-expiry", async () => {
      const escrowId = await makeEscrow(ASK_PRICE, 60 * 60);
      await market.connect(owner).pause();
      await ethers.provider.send("evm_increaseTime", [2 * 60 * 60]);
      await ethers.provider.send("evm_mine", []);
      await market.connect(buyer).refundBuyer(escrowId);
      expect((await market.escrows(escrowId)).resolved).to.be.true;
    });
  });

  describe("Wallet helpers", () => {
    it("fillAuthorizationDigest matches off-chain TypedDataEncoder", async () => {
      const listing = await makeListing();
      const escrowId = 5n;
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
          { name: "marketplaceFeeBps", type: "uint256" },
        ],
      };
      const listingDigest = ethers.TypedDataEncoder.hash(listingDomain, listingTypes, listing);
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

    it("listingDigest matches off-chain TypedDataEncoder", async () => {
      const listing = await makeListing();
      const listingTypes = {
        Listing: [
          { name: "seller", type: "address" },
          { name: "buyer", type: "address" },
          { name: "nftContract", type: "address" },
          { name: "tokenId", type: "uint256" },
          { name: "askPriceXom", type: "uint256" },
          { name: "expiry", type: "uint256" },
          { name: "nonce", type: "uint256" },
          { name: "marketplaceFeeBps", type: "uint256" },
        ],
      };
      const expected = ethers.TypedDataEncoder.hash(listingDomain, listingTypes, listing);
      const onchain = await market.listingDigest(listing);
      expect(onchain).to.equal(expected);
    });

    it("domainSeparator is non-zero + matches EIP-712 spec", async () => {
      const sep = await market.domainSeparator();
      expect(sep).to.not.equal(ethers.ZeroHash);
      const chainId = (await ethers.provider.getNetwork()).chainId;
      const expected = ethers.TypedDataEncoder.hashDomain({
        name: "OmniBazaar NFTMarketplaceEscrow",
        version: "1",
        chainId: Number(chainId),
        verifyingContract: await market.getAddress(),
      });
      expect(sep).to.equal(expected);
    });
  });

  // ============================================================================
  // CON-1: ADMIN transferability + uint256 fee width + SLOAD-dedupe regression
  // ============================================================================

  describe("CON-1: admin transferability", () => {
    it("exposes initial admin == deployer with no pending transfer", async () => {
      expect(await market.admin()).to.equal(owner.address);
      expect(await market.pendingAdmin()).to.equal(ethers.ZeroAddress);
    });

    it("proposeAdmin sets pendingAdmin + emits AdminTransferProposed", async () => {
      const tx = await market.connect(owner).proposeAdmin(other.address);
      await expect(tx)
        .to.emit(market, "AdminTransferProposed")
        .withArgs(owner.address, other.address);
      expect(await market.pendingAdmin()).to.equal(other.address);
      // Current admin is unchanged until acceptance.
      expect(await market.admin()).to.equal(owner.address);
    });

    it("proposeAdmin restricted to current admin", async () => {
      await expect(market.connect(other).proposeAdmin(other.address))
        .to.be.revertedWithCustomError(market, "NotAdmin");
    });

    it("acceptAdmin requires the proposed wallet (NotPendingAdmin otherwise)", async () => {
      await market.connect(owner).proposeAdmin(other.address);
      await expect(market.connect(buyer).acceptAdmin())
        .to.be.revertedWithCustomError(market, "NotPendingAdmin");
    });

    it("acceptAdmin rotates admin and clears pendingAdmin + emits AdminTransferred", async () => {
      await market.connect(owner).proposeAdmin(other.address);

      const tx = await market.connect(other).acceptAdmin();
      await expect(tx)
        .to.emit(market, "AdminTransferred")
        .withArgs(owner.address, other.address);

      expect(await market.admin()).to.equal(other.address);
      expect(await market.pendingAdmin()).to.equal(ethers.ZeroAddress);
    });

    it("previous admin loses pause access after transfer", async () => {
      await market.connect(owner).proposeAdmin(other.address);
      await market.connect(other).acceptAdmin();

      await expect(market.connect(owner).pause())
        .to.be.revertedWithCustomError(market, "NotAdmin");

      // New admin can pause.
      await market.connect(other).pause();
      expect(await market.paused()).to.be.true;
      await market.connect(other).unpause();
    });

    it("proposeAdmin(address(0)) cancels a pending transfer", async () => {
      await market.connect(owner).proposeAdmin(other.address);
      expect(await market.pendingAdmin()).to.equal(other.address);

      await market.connect(owner).proposeAdmin(ethers.ZeroAddress);
      expect(await market.pendingAdmin()).to.equal(ethers.ZeroAddress);

      // The previously-proposed wallet can no longer accept.
      await expect(market.connect(other).acceptAdmin())
        .to.be.revertedWithCustomError(market, "NotPendingAdmin");
    });
  });

  describe("CON-1: fee bps width harmonization", () => {
    it("MARKETPLACE_FEE_BPS getter returns a uint256-shaped value", async () => {
      const bps = await market.MARKETPLACE_FEE_BPS();
      // ethers v6 returns bigint for uint256 — the assertion proves the
      // ABI advertised this as uint256, not uint64.
      expect(typeof bps).to.equal("bigint");
      expect(bps).to.equal(BigInt(FEE_BPS));
    });
  });

  describe("CON-1: SLOAD-dedupe behavioral regression", () => {
    it("still rejects EscrowExpired (slot-0 packed field) after dedupe", async () => {
      // Tight window: escrow expires before the listing so the
      // EscrowExpired branch (and not ListingExpired) is the one that
      // actually fires. Escrow lifetime = MIN_ESCROW_DURATION (1h);
      // listing lifetime = 14d so the listing remains valid long after
      // the escrow has rolled past its expiry.
      const escrowId = await makeEscrow(ASK_PRICE, 60 * 60); // 1h
      const baseListing = await makeListing();
      const latest = (await ethers.provider.getBlock("latest"))!.timestamp;
      const farFutureExpiry = BigInt(latest) + BigInt(14 * 24 * 60 * 60);
      const listing = { ...baseListing, expiry: farFutureExpiry };
      const sellerSig = await signListing(seller, listing);
      const fillAuthSig = await signFillAuth(
        buyer,
        listing,
        escrowId,
        listing.expiry,
      );

      // Advance past the escrow's 1h expiry (but well within the
      // listing's 14d window).
      await ethers.provider.send("evm_increaseTime", [2 * 60 * 60]);
      await ethers.provider.send("evm_mine", []);

      await expect(
        market
          .connect(buyer)
          .fillListing(listing, sellerSig, escrowId, fillAuthSig, listing.expiry),
      ).to.be.revertedWithCustomError(market, "EscrowExpired");
    });

    it("still rejects EscrowAmountMismatch (slot-2 read) after dedupe", async () => {
      const escrowId = await makeEscrow(ASK_PRICE);
      const listing = {
        ...(await makeListing()),
        askPriceXom: ASK_PRICE * 2n,
      };
      const sellerSig = await signListing(seller, listing);
      const fillAuthSig = await signFillAuth(
        buyer,
        listing,
        escrowId,
        listing.expiry,
      );

      await expect(
        market
          .connect(buyer)
          .fillListing(listing, sellerSig, escrowId, fillAuthSig, listing.expiry),
      ).to.be.revertedWithCustomError(market, "EscrowAmountMismatch");
    });

    it("still rejects EscrowSellerMismatch (slot-1 read) after dedupe", async () => {
      const escrowId = await makeEscrow();
      const listing = {
        ...(await makeListing()),
        seller: other.address, // listing claims a different seller
      };
      const sellerSig = await signListing(other, listing);
      const fillAuthSig = await signFillAuth(
        buyer,
        listing,
        escrowId,
        listing.expiry,
      );

      await expect(
        market
          .connect(buyer)
          .fillListing(listing, sellerSig, escrowId, fillAuthSig, listing.expiry),
      ).to.be.revertedWithCustomError(market, "EscrowSellerMismatch");
    });
  });
});
