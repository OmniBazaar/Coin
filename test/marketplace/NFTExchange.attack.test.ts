/**
 * Adversarial regression suite for `NFTExchange` / `OmniConduit`.
 *
 * Every test here started life as a working exploit written during the
 * pre-deployment audit, and each one PASSED against the first version of
 * the contract. They have been turned round: each now asserts the attack
 * is refused, and each keeps the original attack narrative in its comments
 * so a future change that reopens the hole fails loudly and legibly rather
 * than quietly.
 *
 * The six:
 *   E-1  A collection raises its royalty to 99% after the seller signed,
 *        then buys every open listing for the price of the 1% fee.
 *   E-2  An ERC-20 named as an order's `nftContract` — the delivery leg
 *        becomes an arbitrary `transferFrom` on the seller's allowance.
 *   E-3  A pre-ERC-165 collection named as an order's `paymentToken` —
 *        the payment leg walks off with the buyer's own NFT.
 *   E-4  A 4-of-N Safe signature is 260 bytes, which is exactly the bulk
 *        shape, so every 4-owner Safe was unable to sell anything.
 *   E-5  One depth-24 bulk tree covers every counter `incrementCounter`
 *        could reach, defeating cancel-everything.
 *   E-6  A fee vault that cannot receive the chain's own currency bricks
 *        every native sale — and the vault the L1 deploy would have used
 *        is exactly such a contract.
 */

import chai from "chai";
import hre from "hardhat";
import networkHelpers from "@nomicfoundation/hardhat-network-helpers";
import {
  type Order,
  SINGLE_ORDER_TYPES,
} from "../../scripts/lib/bulkOrderTree.ts";

const { expect } = chai;
const { ethers } = hre as unknown as { ethers: any };
const { time } = networkHelpers;

/* eslint-disable @typescript-eslint/no-explicit-any */
type AnyContract = any;
type AnySigner = any;

const ZERO = "0x0000000000000000000000000000000000000000";
const FEE_BPS = 100n;
const BASIS_POINTS = 10_000n;
const TOKEN_ID = 42n;
const PRICE = ethers.parseEther("10");
const ONE_DAY = 24 * 60 * 60;
const KIND_FIXED = 0;
const ITEM_ERC721 = 0;
const ITEM_ERC1155 = 1;

interface World {
  deployer: AnySigner;
  seller: AnySigner;
  buyer: AnySigner;
  attacker: AnySigner;
  feeVault: AnySigner;
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
 * Deploy a full exchange and conduit, with collections and an ERC-20.
 *
 * @returns The wired world.
 */
async function deployWorld(): Promise<World> {
  const [deployer, seller, buyer, attacker, feeVault] =
    await ethers.getSigners();

  const conduit = await (
    await ethers.getContractFactory("OmniConduit")
  ).deploy();
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
  const erc1155 = await (
    await ethers.getContractFactory("MockERC1155")
  ).deploy();
  const royaltyNft = await (
    await ethers.getContractFactory("MockERC2981NFT")
  ).deploy("Royal", "ROY");
  const payToken = await (
    await ethers.getContractFactory("ERC20Mock")
  ).deploy("Pay", "PAY");
  await Promise.all([
    erc721.waitForDeployment(),
    erc1155.waitForDeployment(),
    royaltyNft.waitForDeployment(),
    payToken.waitForDeployment(),
  ]);

  await erc721.mint(seller.address, TOKEN_ID);
  await erc1155.mint(seller.address, TOKEN_ID, 100n);
  await royaltyNft.mint(seller.address, TOKEN_ID);
  await payToken.mint(buyer.address, ethers.parseEther("1000"));
  await payToken.connect(buyer).approve(conduitAddress, ethers.MaxUint256);
  await erc721.connect(seller).setApprovalForAll(conduitAddress, true);
  await erc1155.connect(seller).setApprovalForAll(conduitAddress, true);
  await royaltyNft.connect(seller).setApprovalForAll(conduitAddress, true);

  const { chainId } = await ethers.provider.getNetwork();
  return {
    deployer,
    seller,
    buyer,
    attacker,
    feeVault,
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
 * Build a fixed-price ERC-721 order priced in the chain's own currency.
 *
 * @param world     The world.
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
 * Sign an order.
 *
 * @param world  The world.
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

describe("NFTExchange — adversarial regressions", () => {
  // ────────────────────────────────────────────────────────────────
  // E-1  The royalty is read at fill time and the collection controls it.
  // ────────────────────────────────────────────────────────────────
  it("E-1: a collection cannot raise its royalty after the seller signed", async () => {
    const world = await deployWorld();

    // The seller lists honestly. At signing time the collection declares
    // no royalty at all, and the seller signs a cap of 10% — the most they
    // are prepared to give a creator.
    const order = await makeOrder(world, {
      nftContract: await world.royaltyNft.getAddress(),
      maxRoyaltyBps: 1_000n,
    });
    const signature = await signOrder(world, world.seller, order);
    expect((await world.royaltyNft.royaltyInfo(TOKEN_ID, PRICE))[1]).to.equal(
      0n,
    );

    // The collection's owner — `setDefaultRoyalty` is the ordinary
    // owner-settable setter every OpenZeppelin collection ships — now
    // points the royalty at themselves at 100%. Before the cap existed
    // this let them buy the NFT back for the price of the 1% fee and
    // leave the seller with nothing.
    await world.royaltyNft.setDefaultRoyalty(world.attacker.address, 10_000);

    await expect(
      world.exchange
        .connect(world.attacker)
        .fulfillOrder(order, signature, 1n, { value: PRICE }),
    ).to.be.revertedWithCustomError(world.exchange, "RoyaltyExceedsCap");

    expect(await world.royaltyNft.ownerOf(TOKEN_ID)).to.equal(
      world.seller.address,
    );
  });

  it("E-1b: a royalty within the signed cap is still paid", async () => {
    const world = await deployWorld();
    await world.royaltyNft.setDefaultRoyalty(world.attacker.address, 500);
    const order = await makeOrder(world, {
      nftContract: await world.royaltyNft.getAddress(),
      maxRoyaltyBps: 1_000n,
    });
    const signature = await signOrder(world, world.seller, order);

    const before = await ethers.provider.getBalance(world.attacker.address);
    await world.exchange
      .connect(world.buyer)
      .fulfillOrder(order, signature, 1n, { value: PRICE });

    expect(await ethers.provider.getBalance(world.attacker.address)).to.equal(
      before + (PRICE * 500n) / BASIS_POINTS,
    );
  });

  // ────────────────────────────────────────────────────────────────
  // E-2  `nftContract` was never checked to be a collection.
  // ────────────────────────────────────────────────────────────────
  it("E-2: an ERC-20 named as nftContract cannot drain the seller's allowance", async () => {
    const world = await deployWorld();
    const payAddress = await world.payToken.getAddress();

    // The seller is also a buyer elsewhere on the marketplace, so they
    // have approved the conduit for the ERC-20 the exchange settles in.
    // That is the ordinary, documented buyer flow — not a mistake.
    await world.payToken.mint(world.seller.address, ethers.parseEther("1000"));
    await world.payToken
      .connect(world.seller)
      .approve(world.conduitAddress, ethers.MaxUint256);

    // The order looks like a free listing. `nftContract` is the ERC-20 and
    // `tokenId` is the balance to steal — `IERC721.transferFrom` and
    // `IERC20.transferFrom` are the same selector, so the delivery leg
    // used to move money instead of an item. Realistically this reaches a
    // seller as one leaf of a bulk tree their wallet cannot render.
    const loot = ethers.parseEther("1000");
    const order = await makeOrder(world, {
      nftContract: payAddress,
      tokenId: loot,
      startPrice: 0n,
      endPrice: 0n,
    });
    const signature = await signOrder(world, world.seller, order);

    await expect(
      world.exchange
        .connect(world.attacker)
        .fulfillOrder(order, signature, 1n, { value: 0n }),
    ).to.be.revertedWithCustomError(world.conduit, "NotAnNftCollection");

    expect(await world.payToken.balanceOf(world.attacker.address)).to.equal(
      0n,
    );
    expect(await world.payToken.balanceOf(world.seller.address)).to.equal(
      ethers.parseEther("1000"),
    );
  });

  // ────────────────────────────────────────────────────────────────
  // E-3  The payment-token guard knew only about declared ERC-721s.
  // ────────────────────────────────────────────────────────────────
  it("E-3: a pre-ERC-165 collection cannot be named as a payment token", async () => {
    const world = await deployWorld();

    const legacy = await (
      await ethers.getContractFactory("LegacyNftNoErc165")
    ).deploy();
    await legacy.waitForDeployment();
    const legacyAddress = await legacy.getAddress();

    // The victim owns token 7 in the legacy collection and has approved
    // the conduit for it, exactly as they would to list it for sale. Many
    // valuable 2017-18 collections predate ERC-165 and answer nothing.
    await legacy.mint(world.buyer.address, 7n);
    await legacy
      .connect(world.buyer)
      .setApprovalForAll(world.conduitAddress, true);

    // The attacker lists a worthless ERC-1155 "priced" at 7 units of the
    // legacy collection. 7 is below 100, so the 1% fee used to round to
    // zero and the payment collapsed to a single leg — one call that read
    // the price as a token id and handed over the buyer's own NFT.
    await world.erc1155.mint(world.attacker.address, 999n, 1n);
    await world.erc1155
      .connect(world.attacker)
      .setApprovalForAll(world.conduitAddress, true);

    const order = await makeOrder(world, {
      offerer: world.attacker.address,
      itemType: ITEM_ERC1155,
      nftContract: await world.erc1155.getAddress(),
      tokenId: 999n,
      amount: 1n,
      paymentToken: legacyAddress,
      startPrice: 7n,
      endPrice: 7n,
    });
    const signature = await signOrder(world, world.attacker, order);

    // Now refused twice over: the price is too small for the fee to exist
    // at all, which is what made the single-leg collapse possible.
    await expect(
      world.exchange.connect(world.buyer).fulfillOrder(order, signature, 1n),
    ).to.be.revertedWithCustomError(world.exchange, "PriceTooSmall");

    // And at a price where the fee does exist, the conduit refuses the
    // collection as money — because it keeps no ERC-20 allowances.
    const dearer = await makeOrder(world, {
      offerer: world.attacker.address,
      itemType: ITEM_ERC1155,
      nftContract: await world.erc1155.getAddress(),
      tokenId: 999n,
      amount: 1n,
      paymentToken: legacyAddress,
      startPrice: 7_000n,
      endPrice: 7_000n,
      salt: 2n,
    });
    await expect(
      world.exchange
        .connect(world.buyer)
        .fulfillOrder(
          dearer,
          await signOrder(world, world.attacker, dearer),
          1n,
        ),
    ).to.be.revertedWithCustomError(world.conduit, "NotAPaymentToken");

    expect(await legacy.ownerOf(7n)).to.equal(world.buyer.address);
  });

  // ────────────────────────────────────────────────────────────────
  // E-4  Contract-wallet signature length collided with the bulk shape.
  // ────────────────────────────────────────────────────────────────
  it("E-4: a 4-owner Safe-shaped signature still sells", async () => {
    // Concatenated 65-byte owner signatures land on the bulk shape
    // (68 + 32h, 1 <= h <= 24) at exactly four owners, and nowhere else in
    // any realistic range. 4-of-N Safes hold a lot of valuable inventory.
    const bulkShaped: number[] = [];
    for (let n = 1; n <= 40; n += 1) {
      const len = n * 65;
      if (len >= 100 && len <= 68 + 24 * 32 && (len - 68) % 32 === 0) {
        bulkShaped.push(n);
      }
    }
    expect(bulkShaped).to.deep.equal([4]);

    const world = await deployWorld();
    const wallet = await (
      await ethers.getContractFactory("StrictErc1271Wallet")
    ).deploy();
    await wallet.waitForDeployment();
    const walletAddress = await wallet.getAddress();

    await world.erc721.mint(walletAddress, 778n);
    await wallet.setApprovalForAll(
      await world.erc721.getAddress(),
      world.conduitAddress,
    );

    const order = await makeOrder(world, {
      offerer: walletAddress,
      tokenId: 778n,
    });
    await wallet.approve(await world.exchange.orderDigest(order));

    // 260 bytes — the bulk shape. Because the offerer has code, the
    // exchange no longer routes by length; it goes straight to ERC-1271
    // with the single-order digest, which is what the wallet approved.
    const fourOwners = "0x" + "ab".repeat(65) + "000000" + "cd".repeat(192);
    expect((fourOwners.length - 2) / 2).to.equal(260);

    await world.exchange
      .connect(world.buyer)
      .fulfillOrder(order, fourOwners, 1n, { value: PRICE });
    expect(await world.erc721.ownerOf(778n)).to.equal(world.buyer.address);
  });

  // ────────────────────────────────────────────────────────────────
  // E-5  Cancel-everything could not outrun a deep bulk tree.
  // ────────────────────────────────────────────────────────────────
  it("E-5: the counter jump is far wider than the deepest bulk tree", async () => {
    const world = await deployWorld();

    // The jump must have many more possible values than a bulk tree has
    // leaves. If it did not, one bulk signature could carry a pre-signed
    // order for every counter the cancel could reach, and cancelling
    // everything would hand the attacker a live order in the same
    // transaction. The jump takes the top 128 bits of the block hash;
    // the deepest tree holds 2**24 orders.
    const jumps: bigint[] = [];
    let previous = 0n;
    for (let i = 0; i < 12; i += 1) {
      await world.exchange.connect(world.seller).incrementCounter();
      const now = await world.exchange.counters(world.seller.address);
      jumps.push(now - previous);
      previous = now;
    }

    const treeCapacity = 2n ** 24n;
    const above = jumps.filter((j) => j > treeCapacity).length;
    // With a 128-bit jump, landing at or below 2**24 has probability
    // 2**-104; every sample should be far above it.
    expect(above).to.equal(jumps.length);
    for (const jump of jumps) {
      expect(jump).to.be.greaterThan(0n);
    }
  });

  // ────────────────────────────────────────────────────────────────
  // E-6  The fee vault the L1 deploy would have used cannot take XOM.
  // ────────────────────────────────────────────────────────────────
  it("E-6: a fee vault that cannot receive native currency is recoverable", async () => {
    const [deployer, seller, buyer] = await ethers.getSigners();

    // `UnifiedFeeVault` — the canonical fee recipient on OmniCoin L1 — has
    // no `receive` and no payable `fallback`. Its ABI proves it.
    const vaultArtifact = await hre.artifacts.readArtifact("UnifiedFeeVault");
    const acceptsNative = vaultArtifact.abi.some(
      (entry: any) => entry.type === "receive" || entry.type === "fallback",
    );
    expect(acceptsNative).to.equal(false);

    const conduit = await (
      await ethers.getContractFactory("OmniConduit")
    ).deploy();
    await conduit.waitForDeployment();
    const conduitAddress = await conduit.getAddress();

    // Stand in for such a vault with any contract that has no receive.
    const deafVault = await (
      await ethers.getContractFactory("ERC20Mock")
    ).deploy("Deaf", "DEAF");
    await deafVault.waitForDeployment();

    const exchange = await (
      await ethers.getContractFactory("NFTExchange")
    ).deploy(conduitAddress, await deafVault.getAddress(), FEE_BPS, ZERO);
    await exchange.waitForDeployment();
    const exchangeAddress = await exchange.getAddress();
    await conduit.connect(deployer).updateChannel(exchangeAddress, true);

    const erc721 = await (
      await ethers.getContractFactory("MockERC721")
    ).deploy("M", "M");
    await erc721.waitForDeployment();
    await erc721.mint(seller.address, 5n);
    await erc721.connect(seller).setApprovalForAll(conduitAddress, true);

    const { chainId } = await ethers.provider.getNetwork();
    const domain = {
      name: "OmniBazaar NFTExchange",
      version: "1",
      chainId,
      verifyingContract: exchangeAddress,
    };
    const now = await time.latest();
    const order: Order = {
      kind: KIND_FIXED,
      itemType: ITEM_ERC721,
      offerer: seller.address,
      taker: ZERO,
      nftContract: await erc721.getAddress(),
      tokenId: 5n,
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
    };
    const signature = await seller.signTypedData(
      domain,
      SINGLE_ORDER_TYPES,
      order,
    );

    // Every native sale fails, exactly as predicted.
    await expect(
      exchange
        .connect(buyer)
        .fulfillOrder(order, signature, 1n, { value: PRICE }),
    ).to.be.revertedWithCustomError(exchange, "NativeTransferFailed");

    // The point of the fix: this is one admin transaction to recover, not
    // a redeploy that would invalidate every signature outstanding.
    await exchange.connect(deployer).setFeeVault(buyer.address);
    await exchange
      .connect(buyer)
      .fulfillOrder(order, signature, 1n, { value: PRICE });
    expect(await erc721.ownerOf(5n)).to.equal(buyer.address);
  });
});
