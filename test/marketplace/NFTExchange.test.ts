/**
 * Behavioural tests for `NFTExchange` and `OmniConduit`.
 *
 * The contract exists to fix four measured defects in
 * `NFTMarketplaceEscrow`, so the suite is organised around proving each
 * one is actually gone rather than around the source file's layout:
 *
 *   1. The buyer's money was escrowed inside the contract for a whole
 *      transaction. Here nothing is held — every fill asserts the
 *      exchange's own balance is zero before and after.
 *   2. One payment token, fixed at deployment. Here the token is inside
 *      the signed order, and the same order shape settles in an ERC-20 or
 *      in the chain's own currency.
 *   3. No `payable` function anywhere, so ETH could not be accepted.
 *   4. ERC-721 only, while the importer discovers ERC-1155.
 *
 * Then: bulk signing at several tree depths, both cancellation routes,
 * the auction-extensibility fields, and the adversarial cases —
 * re-entrancy, replay, over- and under-payment, a payout recipient that
 * refuses money, and a collection that tries to burn the caller's gas in
 * `royaltyInfo`.
 */

// Hardhat, chai and the network helpers are all CommonJS, so they are
// pulled in through their default export rather than by named import —
// this file is otherwise a module, because the bulk-signing helper it
// shares with the client is one.
import chai from "chai";
import hre from "hardhat";
import networkHelpers from "@nomicfoundation/hardhat-network-helpers";
import {
  type Order,
  SINGLE_ORDER_TYPES,
  assertTreeMatchesTypedData,
  buildBulkOrderTree,
  bulkOrderTypehash,
  bulkOrderTypes,
  encodeBulkSignature,
  hashOrder,
  merkleProof,
  merkleRoot,
  rootFromProof,
} from "../../scripts/lib/bulkOrderTree.ts";

const { expect } = chai;
const { ethers } = hre as unknown as { ethers: any };
const { time } = networkHelpers;

/* eslint-disable @typescript-eslint/no-explicit-any */
type AnyContract = any;
type AnySigner = any;

const ZERO = "0x0000000000000000000000000000000000000000";
const FEE_BPS = 100n; // 1%
const BASIS_POINTS = 10_000n;
const TOKEN_ID = 42n;
const PRICE = ethers.parseEther("10");
const ONE_DAY = 24 * 60 * 60;

const KIND_FIXED = 0;
const KIND_DUTCH = 1;
const ITEM_ERC721 = 0;
const ITEM_ERC1155 = 1;

interface World {
  deployer: AnySigner;
  seller: AnySigner;
  buyer: AnySigner;
  other: AnySigner;
  feeVault: AnySigner;
  creator: AnySigner;
  conduit: AnyContract;
  exchange: AnyContract;
  erc721: AnyContract;
  erc1155: AnyContract;
  royaltyNft: AnyContract;
  payToken: AnyContract;
  exchangeAddress: string;
  conduitAddress: string;
  domain: {
    name: string;
    version: string;
    chainId: bigint;
    verifyingContract: string;
  };
}

/**
 * Deploy a complete exchange with a conduit, three collections and an
 * ERC-20, all approved and funded.
 *
 * @returns Everything a test needs, already wired together.
 */
async function deployWorld(): Promise<World> {
  const [deployer, seller, buyer, other, feeVault, creator] =
    await ethers.getSigners();

  const conduit = await (await ethers.getContractFactory("OmniConduit")).deploy();
  await conduit.waitForDeployment();
  const conduitAddress = await conduit.getAddress();

  const exchange = await (
    await ethers.getContractFactory("NFTExchange")
  ).deploy(conduitAddress, feeVault.address, FEE_BPS, ZERO);
  await exchange.waitForDeployment();
  const exchangeAddress = await exchange.getAddress();

  await conduit.connect(deployer).updateChannel(exchangeAddress, true);

  const erc721 = await (
    await ethers.getContractFactory("MockERC721")
  ).deploy("Mock", "MOCK");
  await erc721.waitForDeployment();

  const erc1155 = await (
    await ethers.getContractFactory("MockERC1155")
  ).deploy();
  await erc1155.waitForDeployment();

  const royaltyNft = await (
    await ethers.getContractFactory("MockERC2981NFT")
  ).deploy("Royal", "ROY");
  await royaltyNft.waitForDeployment();

  const payToken = await (
    await ethers.getContractFactory("ERC20Mock")
  ).deploy("Pay", "PAY");
  await payToken.waitForDeployment();

  await erc721.mint(seller.address, TOKEN_ID);
  await erc1155.mint(seller.address, TOKEN_ID, 100n);
  await royaltyNft.mint(seller.address, TOKEN_ID);
  await payToken.mint(buyer.address, ethers.parseEther("1000"));

  await erc721.connect(seller).setApprovalForAll(conduitAddress, true);
  await erc1155.connect(seller).setApprovalForAll(conduitAddress, true);
  await royaltyNft.connect(seller).setApprovalForAll(conduitAddress, true);
  await payToken
    .connect(buyer)
    .approve(conduitAddress, ethers.MaxUint256);

  const { chainId } = await ethers.provider.getNetwork();

  return {
    deployer,
    seller,
    buyer,
    other,
    feeVault,
    creator,
    conduit,
    exchange,
    erc721,
    erc1155,
    royaltyNft,
    payToken,
    exchangeAddress,
    conduitAddress,
    domain: {
      name: "OmniBazaar NFTExchange",
      version: "1",
      chainId,
      verifyingContract: exchangeAddress,
    },
  };
}

/**
 * Build a fixed-price ERC-721 order, open to anyone, priced in the chain's
 * own currency and running for a day.
 *
 * @param world     The deployed world.
 * @param overrides Fields to change.
 * @returns The order.
 */
async function makeOrder(
  world: World,
  overrides: Partial<Order> = {},
): Promise<Order> {
  const now = await time.latest();
  return {
    kind: KIND_FIXED,
    itemType: ITEM_ERC721,
    offerer: world.seller.address,
    taker: ZERO,
    nftContract: await world.erc721.getAddress(),
    tokenId: TOKEN_ID,
    amount: 1n,
    paymentToken: ZERO,
    startPrice: PRICE,
    endPrice: PRICE,
    startTime: now - 60,
    endTime: now + ONE_DAY,
    counter: 0n,
    salt: 1n,
    marketplaceFeeBps: FEE_BPS,
    maxRoyaltyBps: BASIS_POINTS,
    referrer: ZERO,
    referrer2: ZERO,
    ...overrides,
  };
}

/**
 * Sign one order the ordinary way.
 *
 * @param world  The deployed world.
 * @param signer Who signs.
 * @param order  The order.
 * @returns A 65-byte signature.
 */
async function signOrder(
  world: World,
  signer: AnySigner,
  order: Order,
): Promise<string> {
  return signer.signTypedData(world.domain, SINGLE_ORDER_TYPES, order);
}

/**
 * Split a price the way the contract does, so a test can assert against
 * numbers derived independently of the contract's own arithmetic.
 *
 * @param total   Gross price.
 * @param royalty Royalty owed, if any.
 * @returns Fee, royalty and seller proceeds.
 */
function split(
  total: bigint,
  royalty = 0n,
): { fee: bigint; royalty: bigint; seller: bigint } {
  const fee = (total * FEE_BPS) / BASIS_POINTS;
  const afterFee = total - fee;
  const cappedRoyalty = royalty > afterFee ? afterFee : royalty;
  return { fee, royalty: cappedRoyalty, seller: afterFee - cappedRoyalty };
}

describe("NFTExchange", () => {
  describe("typed data is in lockstep with the off-chain signer", () => {
    it("publishes an order type string that hashes to its own type hash", async () => {
      const world = await deployWorld();
      const typeString = await world.exchange.ORDER_TYPE_STRING();
      expect(ethers.id(typeString)).to.equal(
        await world.exchange.ORDER_TYPEHASH(),
      );
    });

    it("agrees with ethers on the order type hash", async () => {
      const world = await deployWorld();
      const encoded = ethers.TypedDataEncoder.from(
        SINGLE_ORDER_TYPES,
      ).encodeType("Order");
      expect(encoded).to.equal(await world.exchange.ORDER_TYPE_STRING());
    });

    it("agrees with ethers on an order's struct hash and full digest", async () => {
      const world = await deployWorld();
      const order = await makeOrder(world);
      expect(await world.exchange.hashOrder(order)).to.equal(hashOrder(order));
      expect(await world.exchange.orderDigest(order)).to.equal(
        ethers.TypedDataEncoder.hash(world.domain, SINGLE_ORDER_TYPES, order),
      );
      expect(await world.exchange.domainSeparator()).to.equal(
        ethers.TypedDataEncoder.hashDomain(world.domain),
      );
    });

    it("derives the same bulk order type hash as ethers at every depth", async () => {
      const world = await deployWorld();
      for (let height = 1; height <= 24; height += 1) {
        expect(await world.exchange.bulkOrderTypehash(height)).to.equal(
          bulkOrderTypehash(height),
          `depth ${height}`,
        );
      }
    });
  });

  describe("a sale in the chain's own currency", () => {
    it("pays fee, seller and buyer in one transaction and holds nothing", async () => {
      const world = await deployWorld();
      const order = await makeOrder(world);
      const signature = await signOrder(world, world.seller, order);
      const { fee, seller } = split(PRICE);

      expect(
        await ethers.provider.getBalance(world.exchangeAddress),
      ).to.equal(0n);

      const before = {
        seller: await ethers.provider.getBalance(world.seller.address),
        vault: await ethers.provider.getBalance(world.feeVault.address),
      };

      await expect(
        world.exchange
          .connect(world.buyer)
          .fulfillOrder(order, signature, 1n, { value: PRICE }),
      ).to.emit(world.exchange, "OrderFulfilled");

      expect(
        await ethers.provider.getBalance(world.seller.address),
      ).to.equal(before.seller + seller);
      expect(
        await ethers.provider.getBalance(world.feeVault.address),
      ).to.equal(before.vault + fee);
      expect(await world.erc721.ownerOf(TOKEN_ID)).to.equal(
        world.buyer.address,
      );
      expect(
        await ethers.provider.getBalance(world.exchangeAddress),
      ).to.equal(0n);
    });

    it("records a referrer named in the order", async () => {
      const world = await deployWorld();
      const order = await makeOrder(world, { referrer: world.other.address });
      const signature = await signOrder(world, world.seller, order);

      await expect(
        world.exchange
          .connect(world.buyer)
          .fulfillOrder(order, signature, 1n, { value: PRICE }),
      )
        .to.emit(world.exchange, "ReferralRecorded")
        .withArgs(hashOrder(order), world.other.address, ZERO);
    });

    it("refunds an overpaying buyer the difference", async () => {
      const world = await deployWorld();
      const order = await makeOrder(world);
      const signature = await signOrder(world, world.seller, order);
      const overpay = PRICE + ethers.parseEther("3");

      const before = await ethers.provider.getBalance(world.buyer.address);
      const tx = await world.exchange
        .connect(world.buyer)
        .fulfillOrder(order, signature, 1n, { value: overpay });
      const receipt = await tx.wait();
      const gas = receipt.gasUsed * receipt.gasPrice;

      expect(await ethers.provider.getBalance(world.buyer.address)).to.equal(
        before - PRICE - gas,
      );
      expect(
        await ethers.provider.getBalance(world.exchangeAddress),
      ).to.equal(0n);
    });

    it("refuses a buyer who sends less than the price", async () => {
      const world = await deployWorld();
      const order = await makeOrder(world);
      const signature = await signOrder(world, world.seller, order);

      await expect(
        world.exchange
          .connect(world.buyer)
          .fulfillOrder(order, signature, 1n, { value: PRICE - 1n }),
      ).to.be.revertedWithCustomError(
        world.exchange,
        "InsufficientNativeValue",
      );
    });

    it("fails the whole sale when a payout recipient refuses the money", async () => {
      const world = await deployWorld();
      const refuser = await (
        await ethers.getContractFactory("ReentrantNativeSeller")
      ).deploy();
      await refuser.waitForDeployment();
      await refuser.setRefuse(true);

      const exchange = await (
        await ethers.getContractFactory("NFTExchange")
      ).deploy(
        world.conduitAddress,
        await refuser.getAddress(),
        FEE_BPS,
        ZERO,
      );
      await exchange.waitForDeployment();
      await world.conduit
        .connect(world.deployer)
        .updateChannel(await exchange.getAddress(), true);

      const domain = { ...world.domain, verifyingContract: await exchange.getAddress() };
      const order = await makeOrder(world);
      const signature = await world.seller.signTypedData(
        domain,
        SINGLE_ORDER_TYPES,
        order,
      );

      await expect(
        exchange
          .connect(world.buyer)
          .fulfillOrder(order, signature, 1n, { value: PRICE }),
      ).to.be.revertedWithCustomError(exchange, "NativeTransferFailed");
      expect(await world.erc721.ownerOf(TOKEN_ID)).to.equal(
        world.seller.address,
      );
    });
  });

  describe("a sale in an ERC-20 named by the seller", () => {
    it("moves the money straight from buyer to recipients", async () => {
      const world = await deployWorld();
      const order = await makeOrder(world, {
        paymentToken: await world.payToken.getAddress(),
      });
      const signature = await signOrder(world, world.seller, order);
      const { fee, seller } = split(PRICE);

      await world.exchange
        .connect(world.buyer)
        .fulfillOrder(order, signature, 1n);

      expect(await world.payToken.balanceOf(world.seller.address)).to.equal(
        seller,
      );
      expect(await world.payToken.balanceOf(world.feeVault.address)).to.equal(
        fee,
      );
      expect(await world.payToken.balanceOf(world.exchangeAddress)).to.equal(
        0n,
      );
      expect(await world.erc721.ownerOf(TOKEN_ID)).to.equal(
        world.buyer.address,
      );
    });

    it("refuses native currency sent alongside an ERC-20 order", async () => {
      const world = await deployWorld();
      const order = await makeOrder(world, {
        paymentToken: await world.payToken.getAddress(),
      });
      const signature = await signOrder(world, world.seller, order);

      await expect(
        world.exchange
          .connect(world.buyer)
          .fulfillOrder(order, signature, 1n, { value: 1n }),
      ).to.be.revertedWithCustomError(world.exchange, "UnexpectedNativeValue");
    });

    it("fails when the buyer has not approved the conduit", async () => {
      const world = await deployWorld();
      await world.payToken.connect(world.buyer).approve(world.conduitAddress, 0);
      const order = await makeOrder(world, {
        paymentToken: await world.payToken.getAddress(),
      });
      const signature = await signOrder(world, world.seller, order);

      await expect(
        world.exchange.connect(world.buyer).fulfillOrder(order, signature, 1n),
      ).to.be.reverted;
    });
  });

  describe("creator royalties", () => {
    it("pays an EIP-2981 royalty out of the seller's proceeds", async () => {
      const world = await deployWorld();
      await world.royaltyNft.setDefaultRoyalty(world.creator.address, 500); // 5%
      const order = await makeOrder(world, {
        nftContract: await world.royaltyNft.getAddress(),
        paymentToken: await world.payToken.getAddress(),
      });
      const signature = await signOrder(world, world.seller, order);

      const royalty = (PRICE * 500n) / BASIS_POINTS;
      const expected = split(PRICE, royalty);

      await expect(
        world.exchange.connect(world.buyer).fulfillOrder(order, signature, 1n),
      ).to.emit(world.exchange, "RoyaltyPaid");

      expect(await world.payToken.balanceOf(world.creator.address)).to.equal(
        expected.royalty,
      );
      expect(await world.payToken.balanceOf(world.seller.address)).to.equal(
        expected.seller,
      );
      expect(await world.payToken.balanceOf(world.feeVault.address)).to.equal(
        expected.fee,
      );
    });

    it("pays a royalty in the chain's own currency too", async () => {
      const world = await deployWorld();
      await world.royaltyNft.setDefaultRoyalty(world.creator.address, 250);
      const order = await makeOrder(world, {
        nftContract: await world.royaltyNft.getAddress(),
      });
      const signature = await signOrder(world, world.seller, order);

      const royalty = (PRICE * 250n) / BASIS_POINTS;
      const before = await ethers.provider.getBalance(world.creator.address);

      await world.exchange
        .connect(world.buyer)
        .fulfillOrder(order, signature, 1n, { value: PRICE });

      expect(await ethers.provider.getBalance(world.creator.address)).to.equal(
        before + royalty,
      );
    });

    it("treats a collection that burns gas in royaltyInfo as owing nothing", async () => {
      const world = await deployWorld();
      await world.royaltyNft.setDefaultRoyalty(world.creator.address, 500);
      await world.royaltyNft.setGasGrief(true);
      const order = await makeOrder(world, {
        nftContract: await world.royaltyNft.getAddress(),
        paymentToken: await world.payToken.getAddress(),
      });
      const signature = await signOrder(world, world.seller, order);
      const { fee, seller } = split(PRICE);

      await world.exchange
        .connect(world.buyer)
        .fulfillOrder(order, signature, 1n);

      expect(await world.payToken.balanceOf(world.creator.address)).to.equal(
        0n,
      );
      expect(await world.payToken.balanceOf(world.seller.address)).to.equal(
        seller,
      );
      expect(await world.payToken.balanceOf(world.feeVault.address)).to.equal(
        fee,
      );
    });

    it("pays nothing to a collection with no royalty standard at all", async () => {
      const world = await deployWorld();
      const order = await makeOrder(world, {
        paymentToken: await world.payToken.getAddress(),
      });
      const signature = await signOrder(world, world.seller, order);

      await expect(
        world.exchange.connect(world.buyer).fulfillOrder(order, signature, 1n),
      ).to.not.emit(world.exchange, "RoyaltyPaid");
    });
  });

  describe("ERC-1155", () => {
    it("sells part of an order and leaves the rest available", async () => {
      const world = await deployWorld();
      const order = await makeOrder(world, {
        itemType: ITEM_ERC1155,
        nftContract: await world.erc1155.getAddress(),
        amount: 10n,
        startPrice: PRICE,
        endPrice: PRICE,
        paymentToken: await world.payToken.getAddress(),
      });
      const signature = await signOrder(world, world.seller, order);
      const orderHash = hashOrder(order);

      await world.exchange
        .connect(world.buyer)
        .fulfillOrder(order, signature, 4n);

      expect(
        await world.erc1155.balanceOf(world.buyer.address, TOKEN_ID),
      ).to.equal(4n);
      const status = await world.exchange.getOrderStatus(
        world.seller.address,
        orderHash,
      );
      expect(status[0]).to.equal(false);
      expect(status[1]).to.equal(4n);

      const share = (PRICE * 4n) / 10n;
      const expected = split(share);
      expect(await world.payToken.balanceOf(world.seller.address)).to.equal(
        expected.seller,
      );
    });

    it("rounds a partial price up, so parts never undercut the whole", async () => {
      const world = await deployWorld();
      // 3 units of a 10-unit order priced at 10 wei: 10 * 3 / 10 = 3 exactly,
      // so use a price that does not divide evenly.
      const odd = 1001n;
      const order = await makeOrder(world, {
        itemType: ITEM_ERC1155,
        nftContract: await world.erc1155.getAddress(),
        amount: 10n,
        startPrice: odd,
        endPrice: odd,
        paymentToken: await world.payToken.getAddress(),
      });
      const signature = await signOrder(world, world.seller, order);

      await world.exchange
        .connect(world.buyer)
        .fulfillOrder(order, signature, 3n);

      // ceil(1001 * 3 / 10) = ceil(300.3) = 301
      const expected = split(301n);
      expect(await world.payToken.balanceOf(world.seller.address)).to.equal(
        expected.seller,
      );
      expect(await world.payToken.balanceOf(world.feeVault.address)).to.equal(
        expected.fee,
      );
    });

    it("refuses to sell more units than the order offers", async () => {
      const world = await deployWorld();
      const order = await makeOrder(world, {
        itemType: ITEM_ERC1155,
        nftContract: await world.erc1155.getAddress(),
        amount: 5n,
        paymentToken: await world.payToken.getAddress(),
      });
      const signature = await signOrder(world, world.seller, order);

      await world.exchange
        .connect(world.buyer)
        .fulfillOrder(order, signature, 3n);
      await expect(
        world.exchange.connect(world.buyer).fulfillOrder(order, signature, 3n),
      ).to.be.revertedWithCustomError(world.exchange, "InvalidFillAmount");
    });

    it("refuses an ERC-721 order that offers or sells other than one", async () => {
      const world = await deployWorld();
      const many = await makeOrder(world, { amount: 2n });
      const manySignature = await signOrder(world, world.seller, many);
      await expect(
        world.exchange
          .connect(world.buyer)
          .fulfillOrder(many, manySignature, 1n, { value: PRICE }),
      ).to.be.revertedWithCustomError(world.exchange, "InvalidOrderAmount");

      const one = await makeOrder(world);
      const oneSignature = await signOrder(world, world.seller, one);
      await expect(
        world.exchange
          .connect(world.buyer)
          .fulfillOrder(one, oneSignature, 2n, { value: PRICE }),
      ).to.be.revertedWithCustomError(world.exchange, "InvalidFillAmount");
    });
  });

  describe("bulk signing", () => {
    /**
     * Build a set of orders over distinct tokens, all signed at once.
     *
     * @param world The deployed world.
     * @param count How many orders.
     * @returns The orders, the tree and the one signature covering them.
     */
    async function bulkListing(world: World, count: number) {
      const orders: Order[] = [];
      for (let i = 0; i < count; i += 1) {
        const tokenId = 1000n + BigInt(i);
        await world.erc721.mint(world.seller.address, tokenId);
        orders.push(
          await makeOrder(world, {
            tokenId,
            salt: BigInt(i + 1),
            paymentToken: await world.payToken.getAddress(),
          }),
        );
      }
      const tree = buildBulkOrderTree(orders);
      assertTreeMatchesTypedData(tree);
      const signature = await world.seller.signTypedData(
        world.domain,
        tree.types,
        tree.value,
      );
      return { orders, tree, signature };
    }

    it("lets one signature settle every order in the tree", async () => {
      const world = await deployWorld();
      const { orders, tree, signature } = await bulkListing(world, 3);

      for (let i = 0; i < orders.length; i += 1) {
        const proof = merkleProof(tree.leaves, i);
        expect(rootFromProof(tree.leaves[i], i, proof)).to.equal(tree.root);
        await world.exchange
          .connect(world.buyer)
          .fulfillOrder(
            orders[i],
            encodeBulkSignature(signature, i, proof),
            1n,
          );
        expect(await world.erc721.ownerOf(orders[i].tokenId)).to.equal(
          world.buyer.address,
        );
      }
    });

    it("works at a tree depth of one and of four", async () => {
      for (const count of [2, 16]) {
        const world = await deployWorld();
        const { orders, tree, signature } = await bulkListing(world, count);
        const last = orders.length - 1;
        await world.exchange
          .connect(world.buyer)
          .fulfillOrder(
            orders[last],
            encodeBulkSignature(signature, last, merkleProof(tree.leaves, last)),
            1n,
          );
        expect(await world.erc721.ownerOf(orders[last].tokenId)).to.equal(
          world.buyer.address,
        );
      }
    });

    it("uses a leaf byte-identical to the single-order hash", async () => {
      const world = await deployWorld();
      const { orders, tree } = await bulkListing(world, 3);
      for (let i = 0; i < orders.length; i += 1) {
        expect(tree.leaves[i]).to.equal(
          await world.exchange.hashOrder(orders[i]),
        );
      }
    });

    it("rejects a proof for the wrong leaf", async () => {
      const world = await deployWorld();
      const { orders, tree, signature } = await bulkListing(world, 3);
      const wrongProof = merkleProof(tree.leaves, 1);

      await expect(
        world.exchange
          .connect(world.buyer)
          .fulfillOrder(orders[0], encodeBulkSignature(signature, 0, wrongProof), 1n),
      ).to.be.revertedWithCustomError(
        world.exchange,
        "InvalidSellerSignature",
      );
    });

    it("rejects a leaf index the tree cannot hold", async () => {
      const world = await deployWorld();
      const { orders, tree, signature } = await bulkListing(world, 3);
      const proof = merkleProof(tree.leaves, 0);
      // Depth 2 holds indices 0 to 3; hand it 7.
      const forged = ethers.concat([
        signature,
        ethers.toBeHex(7, 3),
        ...proof,
      ]);

      await expect(
        world.exchange.connect(world.buyer).fulfillOrder(orders[0], forged, 1n),
      ).to.be.revertedWithCustomError(
        world.exchange,
        "BulkOrderIndexOutOfRange",
      );
    });

    it("rejects a signature of a length that is neither plain nor bulk", async () => {
      const world = await deployWorld();
      const order = await makeOrder(world);
      const signature = await signOrder(world, world.seller, order);

      await expect(
        world.exchange
          .connect(world.buyer)
          .fulfillOrder(order, signature + "00", 1n, { value: PRICE }),
      ).to.be.revertedWithCustomError(world.exchange, "InvalidSellerSignature");
    });

    it("pads to a power of two rather than duplicating a trailing node", async () => {
      const world = await deployWorld();
      const { tree } = await bulkListing(world, 3);
      expect(tree.paddedOrders.length).to.equal(4);
      expect(tree.paddedOrders[3].nftContract).to.equal(ZERO);
      // The padded leaf is a real leaf with a real sibling — the case
      // merkletreejs gets wrong under duplicateOdd.
      const proof = merkleProof(tree.leaves, 3);
      expect(proof.length).to.equal(2);
      expect(rootFromProof(tree.leaves[3], 3, proof)).to.equal(tree.root);
      expect(merkleRoot(tree.leaves)).to.equal(tree.root);
    });

    it("cannot be used to sell the all-zero padding order", async () => {
      const world = await deployWorld();
      const { tree, signature } = await bulkListing(world, 3);
      const padding = tree.paddedOrders[3];
      const encoded = encodeBulkSignature(
        signature,
        3,
        merkleProof(tree.leaves, 3),
      );

      await expect(
        world.exchange.connect(world.buyer).fulfillOrder(padding, encoded, 1n),
      ).to.be.revertedWithCustomError(world.exchange, "InvalidNftContract");
    });

    it("refuses a bulk tree deeper than the contract accepts", async () => {
      const world = await deployWorld();
      const order = await makeOrder(world);
      const signature = await signOrder(world, world.seller, order);
      // 68 + 32 * 25 bytes: one level past the limit, so it is read as a
      // plain signature of an odd length and fails signature recovery
      // rather than being walked as a 25-deep proof.
      const tooDeep = ethers.concat([
        signature,
        ethers.toBeHex(0, 3),
        ...Array(25).fill(ethers.ZeroHash),
      ]);
      await expect(
        world.exchange
          .connect(world.buyer)
          .fulfillOrder(order, tooDeep, 1n, { value: PRICE }),
      ).to.be.revertedWithCustomError(world.exchange, "InvalidSellerSignature");
    });

    it("refuses to quote a bulk type hash for a depth it cannot verify", async () => {
      const world = await deployWorld();
      await expect(
        world.exchange.bulkOrderTypehash(0),
      ).to.be.revertedWithCustomError(
        world.exchange,
        "InvalidBulkOrderHeight",
      );
      await expect(
        world.exchange.bulkOrderTypehash(25),
      ).to.be.revertedWithCustomError(
        world.exchange,
        "InvalidBulkOrderHeight",
      );
    });

    it("builds the same types ethers does for every depth we sign at", () => {
      for (let height = 1; height <= 4; height += 1) {
        const types = bulkOrderTypes(height);
        expect(types.BulkOrder[0].type).to.equal(
          `Order${"[2]".repeat(height)}`,
        );
      }
    });
  });

  describe("cancelling", () => {
    it("kills a named order", async () => {
      const world = await deployWorld();
      const order = await makeOrder(world);
      const signature = await signOrder(world, world.seller, order);
      const orderHash = hashOrder(order);

      await expect(
        world.exchange.connect(world.seller).cancelOrders([orderHash]),
      )
        .to.emit(world.exchange, "OrderCancelled")
        .withArgs(world.seller.address, orderHash);

      await expect(
        world.exchange
          .connect(world.buyer)
          .fulfillOrder(order, signature, 1n, { value: PRICE }),
      ).to.be.revertedWithCustomError(world.exchange, "OrderIsCancelled");
    });

    it("cannot cancel somebody else's order", async () => {
      const world = await deployWorld();
      const order = await makeOrder(world);
      const signature = await signOrder(world, world.seller, order);

      await world.exchange
        .connect(world.other)
        .cancelOrders([hashOrder(order)]);

      await world.exchange
        .connect(world.buyer)
        .fulfillOrder(order, signature, 1n, { value: PRICE });
      expect(await world.erc721.ownerOf(TOKEN_ID)).to.equal(
        world.buyer.address,
      );
    });

    it("kills everything a seller has signed, by a jump of more than one", async () => {
      const world = await deployWorld();
      const order = await makeOrder(world);
      const signature = await signOrder(world, world.seller, order);

      await expect(
        world.exchange.connect(world.seller).incrementCounter(),
      ).to.emit(world.exchange, "CounterIncremented");

      const counter = await world.exchange.counters(world.seller.address);
      expect(counter).to.be.greaterThan(0n);

      await expect(
        world.exchange
          .connect(world.buyer)
          .fulfillOrder(order, signature, 1n, { value: PRICE }),
      ).to.be.revertedWithCustomError(world.exchange, "CounterOutOfDate");
    });

    it("always moves the counter, never by zero", async () => {
      const world = await deployWorld();
      let previous = 0n;
      for (let i = 0; i < 5; i += 1) {
        await world.exchange.connect(world.seller).incrementCounter();
        const now = await world.exchange.counters(world.seller.address);
        expect(now).to.be.greaterThan(previous);
        previous = now;
      }
    });

    it("still lets a seller cancel while the exchange is paused", async () => {
      const world = await deployWorld();
      const order = await makeOrder(world);
      await world.exchange.connect(world.deployer).pause();

      await world.exchange.connect(world.seller).cancelOrders([hashOrder(order)]);
      await world.exchange.connect(world.seller).incrementCounter();
    });
  });

  describe("who may buy, and when", () => {
    it("lets only the named taker fill a private sale", async () => {
      const world = await deployWorld();
      const order = await makeOrder(world, { taker: world.buyer.address });
      const signature = await signOrder(world, world.seller, order);

      await expect(
        world.exchange
          .connect(world.other)
          .fulfillOrder(order, signature, 1n, { value: PRICE }),
      ).to.be.revertedWithCustomError(world.exchange, "FillerNotAuthorized");

      await world.exchange
        .connect(world.buyer)
        .fulfillOrder(order, signature, 1n, { value: PRICE });
      expect(await world.erc721.ownerOf(TOKEN_ID)).to.equal(
        world.buyer.address,
      );
    });

    it("refuses a seller trying to buy their own order", async () => {
      const world = await deployWorld();
      const order = await makeOrder(world);
      const signature = await signOrder(world, world.seller, order);

      await expect(
        world.exchange
          .connect(world.seller)
          .fulfillOrder(order, signature, 1n, { value: PRICE }),
      ).to.be.revertedWithCustomError(world.exchange, "SelfFillForbidden");
    });

    it("refuses an order before it starts and after it ends", async () => {
      const world = await deployWorld();
      const now = await time.latest();

      const future = await makeOrder(world, {
        startTime: now + 1000,
        endTime: now + 2000,
      });
      await expect(
        world.exchange
          .connect(world.buyer)
          .fulfillOrder(future, await signOrder(world, world.seller, future), 1n, {
            value: PRICE,
          }),
      ).to.be.revertedWithCustomError(world.exchange, "OrderNotStarted");

      const past = await makeOrder(world, {
        startTime: now - 2000,
        endTime: now - 1000,
      });
      await expect(
        world.exchange
          .connect(world.buyer)
          .fulfillOrder(past, await signOrder(world, world.seller, past), 1n, {
            value: PRICE,
          }),
      ).to.be.revertedWithCustomError(world.exchange, "OrderExpired");
    });

    it("refuses an order that would still be live in more than six months", async () => {
      const world = await deployWorld();
      const now = await time.latest();
      const order = await makeOrder(world, {
        endTime: now + 181 * ONE_DAY,
      });
      await expect(
        world.exchange
          .connect(world.buyer)
          .fulfillOrder(order, await signOrder(world, world.seller, order), 1n, {
            value: PRICE,
          }),
      ).to.be.revertedWithCustomError(world.exchange, "OrderWindowTooLong");
    });

    it("refuses an order whose window runs backwards", async () => {
      const world = await deployWorld();
      const now = await time.latest();
      const order = await makeOrder(world, {
        startTime: now + 500,
        endTime: now + 100,
      });
      await expect(
        world.exchange
          .connect(world.buyer)
          .fulfillOrder(order, await signOrder(world, world.seller, order), 1n, {
            value: PRICE,
          }),
      ).to.be.revertedWithCustomError(world.exchange, "InvalidOrderWindow");
    });

    it("refuses an order signed against a different fee", async () => {
      const world = await deployWorld();
      const order = await makeOrder(world, { marketplaceFeeBps: 50n });
      await expect(
        world.exchange
          .connect(world.buyer)
          .fulfillOrder(order, await signOrder(world, world.seller, order), 1n, {
            value: PRICE,
          }),
      ).to.be.revertedWithCustomError(world.exchange, "FeeBpsMismatch");
    });
  });

  describe("signatures cannot be reused or forged", () => {
    it("refuses to fill the same ERC-721 order twice", async () => {
      const world = await deployWorld();
      const order = await makeOrder(world);
      const signature = await signOrder(world, world.seller, order);

      await world.exchange
        .connect(world.buyer)
        .fulfillOrder(order, signature, 1n, { value: PRICE });
      await expect(
        world.exchange
          .connect(world.other)
          .fulfillOrder(order, signature, 1n, { value: PRICE }),
      ).to.be.revertedWithCustomError(world.exchange, "InvalidFillAmount");
    });

    it("refuses a signature from anyone but the offerer", async () => {
      const world = await deployWorld();
      const order = await makeOrder(world);
      const signature = await signOrder(world, world.other, order);

      await expect(
        world.exchange
          .connect(world.buyer)
          .fulfillOrder(order, signature, 1n, { value: PRICE }),
      ).to.be.revertedWithCustomError(world.exchange, "InvalidSellerSignature");
    });

    it("refuses a signature made for a different price", async () => {
      const world = await deployWorld();
      const signed = await makeOrder(world);
      const signature = await signOrder(world, world.seller, signed);
      const cheaper = { ...signed, startPrice: 1n, endPrice: 1n };

      await expect(
        world.exchange
          .connect(world.buyer)
          .fulfillOrder(cheaper, signature, 1n, { value: 1n }),
      ).to.be.revertedWithCustomError(world.exchange, "InvalidSellerSignature");
    });

    it("refuses a signature made for a different payment token", async () => {
      const world = await deployWorld();
      const signed = await makeOrder(world, {
        paymentToken: await world.payToken.getAddress(),
      });
      const signature = await signOrder(world, world.seller, signed);
      const substituted = { ...signed, paymentToken: ZERO };

      await expect(
        world.exchange
          .connect(world.buyer)
          .fulfillOrder(substituted, signature, 1n, { value: PRICE }),
      ).to.be.revertedWithCustomError(world.exchange, "InvalidSellerSignature");
    });

    it("refuses a signature made for a different exchange", async () => {
      const world = await deployWorld();
      const order = await makeOrder(world);
      const foreignDomain = {
        ...world.domain,
        verifyingContract: world.conduitAddress,
      };
      const signature = await world.seller.signTypedData(
        foreignDomain,
        SINGLE_ORDER_TYPES,
        order,
      );

      await expect(
        world.exchange
          .connect(world.buyer)
          .fulfillOrder(order, signature, 1n, { value: PRICE }),
      ).to.be.revertedWithCustomError(world.exchange, "InvalidSellerSignature");
    });
  });

  describe("a payment token cannot be an NFT collection in disguise", () => {
    it("refuses a payment token that declares itself an ERC-721", async () => {
      const world = await deployWorld();

      // ERC-20 and ERC-721 share the `transferFrom(address,address,uint256)`
      // selector, and SafeERC20 accepts a contract that returns nothing —
      // so without a guard, naming a collection as the payment token turns
      // the payment leg into `collection.transferFrom(buyer, seller, price)`
      // and the "price" is a token id.
      //
      // The victim is a buyer who has approved the conduit for a collection
      // of their own, which every seller has. Price 7 makes the 1% fee
      // round to zero, so the whole payment is a single leg.
      const collection = await world.erc721.getAddress();
      await world.erc721.mint(world.buyer.address, 7n);
      await world.erc721
        .connect(world.buyer)
        .setApprovalForAll(world.conduitAddress, true);

      await world.erc1155.mint(world.seller.address, 999n, 1n);
      const order = await makeOrder(world, {
        itemType: ITEM_ERC1155,
        nftContract: await world.erc1155.getAddress(),
        tokenId: 999n,
        amount: 1n,
        paymentToken: collection,
        startPrice: 7_000n,
        endPrice: 7_000n,
      });
      const signature = await signOrder(world, world.seller, order);

      await expect(
        world.exchange.connect(world.buyer).fulfillOrder(order, signature, 1n),
      ).to.be.revertedWithCustomError(world.conduit, "NotAPaymentToken");

      expect(await world.erc721.ownerOf(7n)).to.equal(world.buyer.address);
    });

    it("refuses a sale too small for the fee to exist", async () => {
      const world = await deployWorld();
      // Below 100 smallest units the 1% fee rounds away to nothing, which
      // both loses the fee and collapses the payment to a single transfer
      // — the shape a payment-token confusion attack needs.
      const order = await makeOrder(world, {
        paymentToken: await world.payToken.getAddress(),
        startPrice: 99n,
        endPrice: 99n,
      });
      const signature = await signOrder(world, world.seller, order);

      await expect(
        world.exchange.connect(world.buyer).fulfillOrder(order, signature, 1n),
      ).to.be.revertedWithCustomError(world.exchange, "PriceTooSmall");
    });

    it("refuses an order paid for in the very collection it sells", async () => {
      const world = await deployWorld();
      const order = await makeOrder(world, {
        paymentToken: await world.erc721.getAddress(),
      });
      const signature = await signOrder(world, world.seller, order);

      await expect(
        world.exchange.connect(world.buyer).fulfillOrder(order, signature, 1n),
      ).to.be.revertedWithCustomError(world.exchange, "InvalidPaymentToken");
    });

    it("still accepts an ordinary ERC-20 that knows nothing of ERC-165", async () => {
      const world = await deployWorld();
      const order = await makeOrder(world, {
        paymentToken: await world.payToken.getAddress(),
      });
      const signature = await signOrder(world, world.seller, order);

      await world.exchange
        .connect(world.buyer)
        .fulfillOrder(order, signature, 1n);
      expect(await world.erc721.ownerOf(TOKEN_ID)).to.equal(
        world.buyer.address,
      );
    });
  });

  describe("re-entrancy", () => {
    it("blocks a payout recipient that re-enters mid-fill, and says why", async () => {
      const world = await deployWorld();
      const hostile = await (
        await ethers.getContractFactory("ReentrantNativeSeller")
      ).deploy();
      await hostile.waitForDeployment();
      const hostileAddress = await hostile.getAddress();

      // Fund the hostile contract first, while its callback is unarmed, so
      // the re-entrant call it later makes is fully paid for. Without this
      // the inner call would fail for want of money and prove nothing.
      await world.deployer.sendTransaction({
        to: hostileAddress,
        value: ethers.parseEther("50"),
      });

      // An exchange whose fee vault is the hostile contract, so paying the
      // fee hands it control in the middle of a fill.
      const exchange = await (
        await ethers.getContractFactory("NFTExchange")
      ).deploy(world.conduitAddress, hostileAddress, FEE_BPS, ZERO);
      await exchange.waitForDeployment();
      const exchangeAddress = await exchange.getAddress();
      await world.conduit
        .connect(world.deployer)
        .updateChannel(exchangeAddress, true);

      const domain = { ...world.domain, verifyingContract: exchangeAddress };
      const sale = await makeOrder(world);
      const saleSignature = await world.seller.signTypedData(
        domain,
        SINGLE_ORDER_TYPES,
        sale,
      );

      const replay = exchange.interface.encodeFunctionData("fulfillOrder", [
        sale,
        saleSignature,
        1n,
      ]);
      await hostile.arm(exchangeAddress, replay, PRICE);

      await expect(
        exchange
          .connect(world.buyer)
          .fulfillOrder(sale, saleSignature, 1n, { value: PRICE }),
      )
        .to.emit(hostile, "ReentryAttempted")
        .withArgs(false);

      // Name the reason: OpenZeppelin's ReentrancyGuardReentrantCall, not
      // a shortage of funds and not a signature problem.
      expect(await hostile.reentryAttempts()).to.equal(1n);
      const revertData = await hostile.lastRevertData();
      expect(revertData.slice(0, 10)).to.equal(
        ethers.id("ReentrancyGuardReentrantCall()").slice(0, 10),
      );

      // The outer sale still completed exactly once.
      expect(await world.erc721.ownerOf(TOKEN_ID)).to.equal(
        world.buyer.address,
      );
      expect(await ethers.provider.getBalance(exchangeAddress)).to.equal(0n);
    });

    it("blocks a creator royalty recipient that re-enters mid-fill", async () => {
      const world = await deployWorld();
      const hostile = await (
        await ethers.getContractFactory("ReentrantNativeSeller")
      ).deploy();
      await hostile.waitForDeployment();
      const hostileAddress = await hostile.getAddress();
      await world.deployer.sendTransaction({
        to: hostileAddress,
        value: ethers.parseEther("50"),
      });

      // Same shape, but the money leg pays the hostile contract as the
      // creator, which is the other place a fill hands control away.
      await world.royaltyNft.setDefaultRoyalty(hostileAddress, 1000);
      const exchange = await (
        await ethers.getContractFactory("NFTExchange")
      ).deploy(world.conduitAddress, world.feeVault.address, FEE_BPS, ZERO);
      await exchange.waitForDeployment();
      const exchangeAddress = await exchange.getAddress();
      await world.conduit
        .connect(world.deployer)
        .updateChannel(exchangeAddress, true);

      const domain = { ...world.domain, verifyingContract: exchangeAddress };
      const sale = await makeOrder(world, {
        nftContract: await world.royaltyNft.getAddress(),
      });
      const saleSignature = await world.seller.signTypedData(
        domain,
        SINGLE_ORDER_TYPES,
        sale,
      );
      const replay = exchange.interface.encodeFunctionData("fulfillOrder", [
        sale,
        saleSignature,
        1n,
      ]);
      await hostile.arm(exchangeAddress, replay, PRICE);

      await exchange
        .connect(world.buyer)
        .fulfillOrder(sale, saleSignature, 1n, { value: PRICE });

      expect(await hostile.reentryAttempts()).to.equal(1n);
      const revertData = await hostile.lastRevertData();
      expect(revertData.slice(0, 10)).to.equal(
        ethers.id("ReentrancyGuardReentrantCall()").slice(0, 10),
      );
      expect(await world.royaltyNft.ownerOf(TOKEN_ID)).to.equal(
        world.buyer.address,
      );
      expect(await ethers.provider.getBalance(exchangeAddress)).to.equal(0n);
    });

    it("blocks an ERC-1155 buyer re-entering from onERC1155Received", async () => {
      const world = await deployWorld();
      const hostile = await (
        await ethers.getContractFactory("ReentrantNativeSeller")
      ).deploy();
      await hostile.waitForDeployment();
      const hostileAddress = await hostile.getAddress();
      await world.deployer.sendTransaction({
        to: hostileAddress,
        value: ethers.parseEther("50"),
      });

      // The ERC-1155 receiver hook is the one callback a fill cannot
      // avoid, and it fires after every payment leg has already landed —
      // the most dangerous moment in the whole transaction.
      const order = await makeOrder(world, {
        itemType: ITEM_ERC1155,
        nftContract: await world.erc1155.getAddress(),
        amount: 10n,
      });
      const signature = await signOrder(world, world.seller, order);
      const call = world.exchange.interface.encodeFunctionData("fulfillOrder", [
        order,
        signature,
        2n,
      ]);
      const price = (PRICE * 2n) / 10n;
      await hostile.arm(world.exchangeAddress, call, price);

      await hostile.buy(call, price);

      expect(await hostile.reentryAttempts()).to.equal(1n);
      const revertData = await hostile.lastRevertData();
      expect(revertData.slice(0, 10)).to.equal(
        ethers.id("ReentrancyGuardReentrantCall()").slice(0, 10),
      );
      // Exactly one fill happened: 2 units moved, not 4.
      expect(
        await world.erc1155.balanceOf(hostileAddress, TOKEN_ID),
      ).to.equal(2n);
      const status = await world.exchange.getOrderStatus(
        world.seller.address,
        hashOrder(order),
      );
      expect(status[1]).to.equal(2n);
    });
  });

  describe("auctions are designed for but not built", () => {
    it("refuses an order kind other than a fixed price", async () => {
      const world = await deployWorld();
      const order = await makeOrder(world, { kind: KIND_DUTCH });
      await expect(
        world.exchange
          .connect(world.buyer)
          .fulfillOrder(order, await signOrder(world, world.seller, order), 1n, {
            value: PRICE,
          }),
      ).to.be.revertedWithCustomError(world.exchange, "OrderKindNotSupported");
    });

    it("refuses a fixed-price order whose start and end prices differ", async () => {
      const world = await deployWorld();
      const order = await makeOrder(world, { endPrice: PRICE / 2n });
      await expect(
        world.exchange
          .connect(world.buyer)
          .fulfillOrder(order, await signOrder(world, world.seller, order), 1n, {
            value: PRICE,
          }),
      ).to.be.revertedWithCustomError(world.exchange, "PriceNotFixed");
    });

    it("quotes the current price of a whole order", async () => {
      const world = await deployWorld();
      const order = await makeOrder(world);
      expect(await world.exchange.currentPrice(order)).to.equal(PRICE);
    });
  });

  describe("pausing and the admin role", () => {
    it("stops fills while paused and resumes after", async () => {
      const world = await deployWorld();
      const order = await makeOrder(world);
      const signature = await signOrder(world, world.seller, order);

      await world.exchange.connect(world.deployer).pause();
      await expect(
        world.exchange
          .connect(world.buyer)
          .fulfillOrder(order, signature, 1n, { value: PRICE }),
      ).to.be.revertedWithCustomError(world.exchange, "EnforcedPause");

      await world.exchange.connect(world.deployer).unpause();
      await world.exchange
        .connect(world.buyer)
        .fulfillOrder(order, signature, 1n, { value: PRICE });
    });

    it("gives the deployer the admin role and nobody else", async () => {
      const world = await deployWorld();
      expect(await world.exchange.admin()).to.equal(world.deployer.address);
      await expect(
        world.exchange.connect(world.other).pause(),
      ).to.be.revertedWithCustomError(world.exchange, "NotAdmin");
    });

    it("hands the role on in two steps with no waiting", async () => {
      const world = await deployWorld();
      await world.exchange
        .connect(world.deployer)
        .proposeAdmin(world.other.address);
      expect(await world.exchange.admin()).to.equal(world.deployer.address);

      await expect(
        world.exchange.connect(world.buyer).acceptAdmin(),
      ).to.be.revertedWithCustomError(world.exchange, "NotPendingAdmin");

      await world.exchange.connect(world.other).acceptAdmin();
      expect(await world.exchange.admin()).to.equal(world.other.address);
      await expect(
        world.exchange.connect(world.deployer).pause(),
      ).to.be.revertedWithCustomError(world.exchange, "NotAdmin");
    });

    it("lets the admin, and only the admin, move the fee recipient", async () => {
      const world = await deployWorld();
      await expect(
        world.exchange.connect(world.other).setFeeVault(world.other.address),
      ).to.be.revertedWithCustomError(world.exchange, "NotAdmin");
      await expect(
        world.exchange.connect(world.deployer).setFeeVault(ZERO),
      ).to.be.revertedWithCustomError(world.exchange, "InvalidAddress");

      await expect(
        world.exchange.connect(world.deployer).setFeeVault(world.other.address),
      )
        .to.emit(world.exchange, "FeeVaultUpdated")
        .withArgs(world.feeVault.address, world.other.address);
      expect(await world.exchange.feeVault()).to.equal(world.other.address);
    });

    it("refuses to open a conduit channel for an address with no code", async () => {
      const world = await deployWorld();
      await expect(
        world.conduit
          .connect(world.deployer)
          .updateChannel(world.other.address, true),
      ).to.be.revertedWithCustomError(world.conduit, "InvalidAddress");
    });

    it("refuses to deploy with a fee of a hundred per cent", async () => {
      const world = await deployWorld();
      const factory = await ethers.getContractFactory("NFTExchange");
      await expect(
        factory.deploy(
          world.conduitAddress,
          world.feeVault.address,
          10_000n,
          ZERO,
        ),
      ).to.be.revertedWithCustomError(factory, "InvalidFeeBps");
    });
  });
});

describe("OmniConduit", () => {
  it("lets only an open channel move tokens", async () => {
    const world = await deployWorld();
    await expect(
      world.conduit
        .connect(world.other)
        .transferERC721(
          await world.erc721.getAddress(),
          world.seller.address,
          world.other.address,
          TOKEN_ID,
        ),
    ).to.be.revertedWithCustomError(world.conduit, "ChannelClosed");
  });

  it("lets only the owner open a channel", async () => {
    const world = await deployWorld();
    await expect(
      world.conduit.connect(world.other).updateChannel(world.other.address, true),
    ).to.be.revertedWithCustomError(world.conduit, "NotOwner");
  });

  it("stops an exchange dead once its channel is closed", async () => {
    const world = await deployWorld();
    const order = await makeOrder(world);
    const signature = await signOrder(world, world.seller, order);

    await world.conduit
      .connect(world.deployer)
      .updateChannel(world.exchangeAddress, false);

    await expect(
      world.exchange
        .connect(world.buyer)
        .fulfillOrder(order, signature, 1n, { value: PRICE }),
    ).to.be.revertedWithCustomError(world.conduit, "ChannelClosed");
  });

  it("keeps a seller's approval working across an exchange upgrade", async () => {
    const world = await deployWorld();

    // The seller approved the conduit, not the exchange. Deploy a second
    // exchange, open its channel, and it can settle without the seller
    // touching their approvals again — the whole reason the conduit exists.
    const next = await (
      await ethers.getContractFactory("NFTExchange")
    ).deploy(world.conduitAddress, world.feeVault.address, FEE_BPS, ZERO);
    await next.waitForDeployment();
    const nextAddress = await next.getAddress();
    await world.conduit
      .connect(world.deployer)
      .updateChannel(nextAddress, true);

    const domain = { ...world.domain, verifyingContract: nextAddress };
    const order = await makeOrder(world);
    const signature = await world.seller.signTypedData(
      domain,
      SINGLE_ORDER_TYPES,
      order,
    );

    await next
      .connect(world.buyer)
      .fulfillOrder(order, signature, 1n, { value: PRICE });
    expect(await world.erc721.ownerOf(TOKEN_ID)).to.equal(world.buyer.address);
  });

  it("hands ownership on in two steps", async () => {
    const world = await deployWorld();
    await world.conduit.connect(world.deployer).proposeOwner(world.other.address);
    expect(await world.conduit.owner()).to.equal(world.deployer.address);
    await world.conduit.connect(world.other).acceptOwnership();
    expect(await world.conduit.owner()).to.equal(world.other.address);
  });
});
