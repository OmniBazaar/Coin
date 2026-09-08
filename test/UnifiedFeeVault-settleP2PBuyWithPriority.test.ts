/**
 * UnifiedFeeVault.settleP2PBuyWithPriority — Sale-time Priority Surcharge
 *
 * Exercises the NEW backward-compatible priority-placement settle path:
 * `settleP2PBuyWithPriority(BuyP2PWithPriorityIntent, signature,
 *  sellerPriorityAttestation, swapPath[], swapSources[])`.
 *
 * The surcharge (`priorityFeeBps`, 0–300 = 0–3% of receive-side gross)
 * is skimmed from the SELLER's proceeds and routed 70/20/10
 * listingNode / sellingNode / ODDAO AFTER the normal 1% fee split. The
 * seller MUST co-sign a `SellerPriorityAttestation` binding
 * (listingContentHash, listingNode, sellingNode, priorityFeeBps), so a
 * buyer can neither inflate the surcharge nor redirect the node shares.
 *
 * Coverage (per task spec):
 *   - priority buy settles + surcharge routed 70/20/10 (attested nodes)
 *   - surcharge 100% to ODDAO when both nodes are zero
 *   - priorityFeeBps > 300 reverts (PriorityFeeTooHigh)
 *   - missing / wrong seller attestation reverts (BadSellerAttestation)
 *   - a buyer signature over the OLD BuyP2P typehash does NOT verify on
 *     the new function (distinct typehash → BadSigner)
 *   - the existing settleP2PBuy is unaffected (sellerPay = gross - 1%)
 */

/* eslint-disable @typescript-eslint/no-var-requires, @typescript-eslint/no-explicit-any */
const { expect } = require('chai');
const { ethers, upgrades } = require('hardhat');
const { time } = require('@nomicfoundation/hardhat-network-helpers');

// ═════════════════════════════════════════════════════════════════════
//                           TYPES / HELPERS
// ═════════════════════════════════════════════════════════════════════

interface BuyP2PIntent {
  buyer: string;
  seller: string;
  listingContentHash: string;
  listingId: bigint;
  paymentToken: string;
  paymentAmount: bigint;
  receiveToken: string;
  minReceiveAmount: bigint;
  swapPathHash: string;
  referrer: string;
  referrer2: string;
  listingNode: string;
  sellingNode: string;
  expiresAt: bigint;
  nonce: bigint;
}

interface BuyP2PWithPriorityIntent extends BuyP2PIntent {
  priorityFeeBps: bigint;
}

// EIP-712 type for the existing plain BuyP2P (used to prove the
// old-typehash signature does NOT verify on the new function).
const EIP712_P2P_TYPES = {
  BuyP2P: [
    { name: 'buyer', type: 'address' },
    { name: 'seller', type: 'address' },
    { name: 'listingContentHash', type: 'bytes32' },
    { name: 'listingId', type: 'uint256' },
    { name: 'paymentToken', type: 'address' },
    { name: 'paymentAmount', type: 'uint256' },
    { name: 'receiveToken', type: 'address' },
    { name: 'minReceiveAmount', type: 'uint256' },
    { name: 'swapPathHash', type: 'bytes32' },
    { name: 'referrer', type: 'address' },
    { name: 'referrer2', type: 'address' },
    { name: 'listingNode', type: 'address' },
    { name: 'sellingNode', type: 'address' },
    { name: 'expiresAt', type: 'uint256' },
    { name: 'nonce', type: 'uint256' },
  ],
};

// NEW: priority intent type — plain BuyP2P fields plus trailing
// priorityFeeBps; type name BuyP2PWithPriority.
const EIP712_PRIORITY_TYPES = {
  BuyP2PWithPriority: [
    { name: 'buyer', type: 'address' },
    { name: 'seller', type: 'address' },
    { name: 'listingContentHash', type: 'bytes32' },
    { name: 'listingId', type: 'uint256' },
    { name: 'paymentToken', type: 'address' },
    { name: 'paymentAmount', type: 'uint256' },
    { name: 'receiveToken', type: 'address' },
    { name: 'minReceiveAmount', type: 'uint256' },
    { name: 'swapPathHash', type: 'bytes32' },
    { name: 'referrer', type: 'address' },
    { name: 'referrer2', type: 'address' },
    { name: 'listingNode', type: 'address' },
    { name: 'sellingNode', type: 'address' },
    { name: 'expiresAt', type: 'uint256' },
    { name: 'nonce', type: 'uint256' },
    { name: 'priorityFeeBps', type: 'uint256' },
  ],
};

// NEW: seller priority attestation type.
const EIP712_PRIORITY_ATTESTATION_TYPES = {
  SellerPriorityAttestation: [
    { name: 'listingContentHash', type: 'bytes32' },
    { name: 'listingNode', type: 'address' },
    { name: 'sellingNode', type: 'address' },
    { name: 'priorityFeeBps', type: 'uint256' },
  ],
};

const ZERO_PATH_HASH = ethers.ZeroHash;
const TIMELOCK_DELAY = 48 * 60 * 60;

/**
 * Deploy the vault's seven external libraries once per run and return a
 * `UnifiedFeeVault` factory with all of them linked. The priority
 * surcharge feature added {CoinAgnosticSettlement}, {PrioritySettlement},
 * and {BuyIntentValidator} alongside the existing
 * {MarketplaceFeeSplitter}, {RoyaltyResolver}, and {SwapExecutor}; all
 * keep the vault under the 24 KiB EIP-170 limit.
 *
 * @returns A linked `ContractFactory` for `UnifiedFeeVault`.
 */
const libCache: Record<string, string> = {};
async function deployLibrary(name: string): Promise<string> {
  if (libCache[name] !== undefined) return libCache[name];
  const factory = await ethers.getContractFactory(name);
  const lib = await factory.deploy();
  await lib.waitForDeployment();
  libCache[name] = await lib.getAddress();
  return libCache[name];
}

/**
 * Build the `UnifiedFeeVault` factory with every external library
 * linked. {CoinAgnosticSettlement} and {PrioritySettlement} themselves
 * link to the leaf libraries, so those must be deployed first.
 *
 * @returns The linked vault `ContractFactory`.
 */
async function getVaultFactory(): Promise<any> {
  const marketplaceFeeSplitter = await deployLibrary('MarketplaceFeeSplitter');
  const royaltyResolver = await deployLibrary('RoyaltyResolver');
  const swapExecutor = await deployLibrary('SwapExecutor');
  const buyIntentValidator = await deployLibrary('BuyIntentValidator');
  // CoinAgnosticSettlement links MarketplaceFeeSplitter/RoyaltyResolver/
  // SwapExecutor; deploy it with those linked.
  const cas = await ethers.getContractFactory('CoinAgnosticSettlement', {
    libraries: {
      MarketplaceFeeSplitter: marketplaceFeeSplitter,
      RoyaltyResolver: royaltyResolver,
      SwapExecutor: swapExecutor,
    },
  });
  const casLib = await cas.deploy();
  await casLib.waitForDeployment();
  const coinAgnosticSettlement = await casLib.getAddress();
  // PrioritySettlement links CoinAgnosticSettlement + BuyIntentValidator.
  const ps = await ethers.getContractFactory('PrioritySettlement', {
    libraries: {
      CoinAgnosticSettlement: coinAgnosticSettlement,
      BuyIntentValidator: buyIntentValidator,
    },
  });
  const psLib = await ps.deploy();
  await psLib.waitForDeployment();
  const prioritySettlement = await psLib.getAddress();

  const nftSellerConsent = await deployLibrary('NftSellerConsent');
  const bridgeDestinationLib = await deployLibrary('BridgeDestinationLib');
  return ethers.getContractFactory('UnifiedFeeVault', {
    libraries: {
      MarketplaceFeeSplitter: marketplaceFeeSplitter,
      CoinAgnosticSettlement: coinAgnosticSettlement,
      PrioritySettlement: prioritySettlement,
      NftSellerConsent: nftSellerConsent,
      BridgeDestinationLib: bridgeDestinationLib,
    },
  });
}

// ═════════════════════════════════════════════════════════════════════

describe('UnifiedFeeVault.settleP2PBuyWithPriority — Sale-time Priority', function () {
  let vault: any;
  let xom: any;
  let admin: any;
  let stakingPool: any;
  let protocolTreasury: any;
  let buyer: any;
  let seller: any;
  let referrer1: any;
  let referrer2: any;
  let listingNode: any;
  let sellingNode: any;
  let outsider: any;
  let vaultAddr: string;
  let xomAddr: string;
  let routerAddr: string;

  async function deployFixture(): Promise<void> {
    [
      admin,
      stakingPool,
      protocolTreasury,
      buyer,
      seller,
      referrer1,
      referrer2,
      listingNode,
      sellingNode,
      outsider,
    ] = await ethers.getSigners();

    const MockERC20 = await ethers.getContractFactory('MockERC20');
    xom = await MockERC20.deploy('OmniCoin', 'XOM');
    xomAddr = await xom.getAddress();

    const MockRouter = await ethers.getContractFactory('MockOmniSwapRouter');
    const router = await MockRouter.deploy(ethers.parseEther('1'));
    routerAddr = await router.getAddress();

    const UnifiedFeeVault = await getVaultFactory();
    vault = await upgrades.deployProxy(
      UnifiedFeeVault,
      [admin.address, stakingPool.address, protocolTreasury.address],
      {
        initializer: 'initialize',
        kind: 'uups',
        constructorArgs: [ethers.ZeroAddress],
        unsafeAllow: ['constructor', 'external-library-linking'],
      }
    );
    vaultAddr = await vault.getAddress();
    await vault.connect(admin).initializeV2(routerAddr, xomAddr);

    await xom.mint(buyer.address, ethers.parseEther('1000000'));
    await xom.connect(buyer).approve(vaultAddr, ethers.MaxUint256);
  }

  /** Build a default priority intent (same-token XOM fast path). */
  async function buildIntent(
    overrides: Partial<BuyP2PWithPriorityIntent> = {}
  ): Promise<BuyP2PWithPriorityIntent> {
    const now = await time.latest();
    return {
      buyer: buyer.address,
      seller: seller.address,
      listingContentHash: ethers.id('priority-listing-v1'),
      listingId: 7n,
      paymentToken: xomAddr,
      paymentAmount: ethers.parseEther('100'),
      receiveToken: xomAddr,
      minReceiveAmount: ethers.parseEther('96'),
      swapPathHash: ZERO_PATH_HASH,
      referrer: ethers.ZeroAddress,
      referrer2: ethers.ZeroAddress,
      listingNode: ethers.ZeroAddress,
      sellingNode: ethers.ZeroAddress,
      expiresAt: BigInt(now + 3600),
      nonce: 0n,
      priorityFeeBps: 200n,
      ...overrides,
    };
  }

  async function domain(): Promise<any> {
    const { chainId } = await ethers.provider.getNetwork();
    return {
      name: 'OmniBazaar',
      version: '1',
      chainId,
      verifyingContract: vaultAddr,
    };
  }

  /** Sign a priority intent (new BuyP2PWithPriority typehash). */
  async function signIntent(
    signer: any,
    intent: BuyP2PWithPriorityIntent
  ): Promise<string> {
    return signer.signTypedData(await domain(), EIP712_PRIORITY_TYPES, intent);
  }

  /** Sign a plain BuyP2P intent (OLD typehash) for the negative test. */
  async function signOldP2P(
    signer: any,
    intent: BuyP2PWithPriorityIntent
  ): Promise<string> {
    const { priorityFeeBps: _drop, ...plain } = intent;
    return signer.signTypedData(await domain(), EIP712_P2P_TYPES, plain);
  }

  /** Sign the seller priority attestation. */
  async function signPriorityAttestation(
    signer: any,
    intent: BuyP2PWithPriorityIntent
  ): Promise<string> {
    return signer.signTypedData(
      await domain(),
      EIP712_PRIORITY_ATTESTATION_TYPES,
      {
        listingContentHash: intent.listingContentHash,
        listingNode: intent.listingNode,
        sellingNode: intent.sellingNode,
        priorityFeeBps: intent.priorityFeeBps,
      }
    );
  }

  beforeEach(async function () {
    await deployFixture();
  });

  // ═══════════════════════════════════════════════════════════════════
  //   Happy path — surcharge routed 70/20/10 with attested nodes
  // ═══════════════════════════════════════════════════════════════════

  it('settles a priority buy and skims the surcharge from the seller', async function () {
    const intent = await buildIntent({ priorityFeeBps: 200n }); // 2%
    const sig = await signIntent(buyer, intent);
    const att = await signPriorityAttestation(seller, intent);

    // The `P2PBuyWithPrioritySettled` event is declared in the
    // DELEGATECALL-linked {PrioritySettlement} library and emitted from
    // the vault's address; attach the library interface at the vault
    // address to decode it (the vault ABI does not carry the event).
    const asPriority = await ethers.getContractAt(
      'PrioritySettlement',
      vaultAddr
    );

    await expect(
      vault
        .connect(outsider)
        .settleP2PBuyWithPriority(intent, sig, att, [], [])
    ).to.emit(asPriority, 'P2PBuyWithPrioritySettled');

    const gross = intent.paymentAmount;
    const fee = gross / 100n; // 1%
    const surcharge = (gross * intent.priorityFeeBps) / 10000n; // 2%
    // Seller nets gross - fee - surcharge (= 97% here).
    expect(await xom.balanceOf(seller.address)).to.equal(
      gross - fee - surcharge
    );
  });

  it('routes the surcharge 70/20/10 listingNode/sellingNode/ODDAO (attested nodes)', async function () {
    const intent = await buildIntent({
      priorityFeeBps: 300n, // 3% max
      listingNode: listingNode.address,
      sellingNode: sellingNode.address,
    });
    const sig = await signIntent(buyer, intent);
    const att = await signPriorityAttestation(seller, intent);

    const oddaoBefore = await vault.pendingBridge(xomAddr);

    await vault
      .connect(outsider)
      .settleP2PBuyWithPriority(intent, sig, att, [], []);

    const gross = intent.paymentAmount;
    const surcharge = (gross * intent.priorityFeeBps) / 10000n;
    const pList = (surcharge * 7000n) / 10000n;
    const pSell = (surcharge * 2000n) / 10000n;
    const pOddao = surcharge - pList - pSell;

    // Node shares are pull-claimable; they accrue ON TOP of the normal
    // 1% listing-fee split, so assert the delta from the surcharge.
    // listingNode also earns 70% of the 0.25% listing sub-fee; compute
    // the full expectation: priority pList + listing-fee listShare.
    const fee = gross / 100n;
    const listFee = fee - fee / 4n - fee / 2n; // 0.25%
    const listShare = (listFee * 7000n) / 10000n;
    const sellShare = (listFee * 2000n) / 10000n;

    expect(await vault.pendingClaims(listingNode.address, xomAddr)).to.equal(
      listShare + pList
    );
    expect(await vault.pendingClaims(sellingNode.address, xomAddr)).to.equal(
      sellShare + pSell
    );
    // ODDAO got its 1%-fee remainders plus the surcharge remainder.
    expect((await vault.pendingBridge(xomAddr)) - oddaoBefore).to.be.gte(
      pOddao
    );
  });

  it('routes 100% of the surcharge to ODDAO when both nodes are zero', async function () {
    const intent = await buildIntent({
      priorityFeeBps: 100n, // 1%
      listingNode: ethers.ZeroAddress,
      sellingNode: ethers.ZeroAddress,
    });
    const sig = await signIntent(buyer, intent);
    const att = await signPriorityAttestation(seller, intent);

    const oddaoBefore = await vault.pendingBridge(xomAddr);
    await vault
      .connect(outsider)
      .settleP2PBuyWithPriority(intent, sig, att, [], []);

    const gross = intent.paymentAmount;
    const fee = gross / 100n;
    const surcharge = (gross * intent.priorityFeeBps) / 10000n;
    // ODDAO receives: full 1% fee (no referrers/nodes) + full surcharge.
    // The 1% fee fully routes to ODDAO when all recipients are zero
    // EXCEPT the 0.20% + 0.10% pushed to staking/protocol pools.
    const txFee = fee / 4n;
    const stakingShare = (txFee * 2000n) / 10000n;
    const protocolShare = txFee - (txFee * 7000n) / 10000n - stakingShare;
    const feeToOddao = fee - stakingShare - protocolShare;
    expect((await vault.pendingBridge(xomAddr)) - oddaoBefore).to.equal(
      feeToOddao + surcharge
    );
  });

  // ═══════════════════════════════════════════════════════════════════
  //   Cap + attestation security
  // ═══════════════════════════════════════════════════════════════════

  it('reverts PriorityFeeTooHigh when priorityFeeBps > 300', async function () {
    const intent = await buildIntent({ priorityFeeBps: 301n });
    const sig = await signIntent(buyer, intent);
    const att = await signPriorityAttestation(seller, intent);

    await expect(
      vault
        .connect(outsider)
        .settleP2PBuyWithPriority(intent, sig, att, [], [])
    ).to.be.revertedWithCustomError(vault, 'PriorityFeeTooHigh');
  });

  it('reverts BadSellerAttestation when the attestation is signed by a non-seller', async function () {
    const intent = await buildIntent({ priorityFeeBps: 200n });
    const sig = await signIntent(buyer, intent);
    // outsider (not the seller) signs the attestation.
    const att = await signPriorityAttestation(outsider, intent);

    await expect(
      vault
        .connect(outsider)
        .settleP2PBuyWithPriority(intent, sig, att, [], [])
    ).to.be.revertedWithCustomError(vault, 'BadSellerAttestation');
  });

  it('reverts BadSellerAttestation when the seller signed a DIFFERENT rate', async function () {
    const intent = await buildIntent({ priorityFeeBps: 200n });
    const sig = await signIntent(buyer, intent);
    // Seller attests to 100 bps, but the intent carries 200 bps.
    const att = await signPriorityAttestation(seller, {
      ...intent,
      priorityFeeBps: 100n,
    });

    await expect(
      vault
        .connect(outsider)
        .settleP2PBuyWithPriority(intent, sig, att, [], [])
    ).to.be.revertedWithCustomError(vault, 'BadSellerAttestation');
  });

  it('reverts when the seller attestation is empty/garbage', async function () {
    const intent = await buildIntent({ priorityFeeBps: 200n });
    const sig = await signIntent(buyer, intent);
    // 65-byte zero signature recovers to address(0) != seller.
    const garbage = '0x' + '00'.repeat(65);

    await expect(
      vault
        .connect(outsider)
        .settleP2PBuyWithPriority(intent, sig, garbage, [], [])
    ).to.be.reverted; // ECDSA rejects v=0, or recovers != seller
  });

  // ═══════════════════════════════════════════════════════════════════
  //   Typehash isolation — old BuyP2P signature must NOT verify
  // ═══════════════════════════════════════════════════════════════════

  it('rejects a buyer signature made over the OLD BuyP2P typehash', async function () {
    const intent = await buildIntent({ priorityFeeBps: 200n });
    // Buyer signs the plain BuyP2P (no priorityFeeBps) typed data.
    const oldSig = await signOldP2P(buyer, intent);
    const att = await signPriorityAttestation(seller, intent);

    await expect(
      vault
        .connect(outsider)
        .settleP2PBuyWithPriority(intent, oldSig, att, [], [])
    ).to.be.revertedWithCustomError(vault, 'BadSigner');
  });

  // ═══════════════════════════════════════════════════════════════════
  //   Backward compatibility — existing settleP2PBuy unaffected
  // ═══════════════════════════════════════════════════════════════════

  it('leaves the existing settleP2PBuy path at exactly 1% fee (no surcharge)', async function () {
    const now = await time.latest();
    const plain: BuyP2PIntent = {
      buyer: buyer.address,
      seller: seller.address,
      listingContentHash: ethers.id('plain-listing'),
      listingId: 1n,
      paymentToken: xomAddr,
      paymentAmount: ethers.parseEther('100'),
      receiveToken: xomAddr,
      minReceiveAmount: ethers.parseEther('99'),
      swapPathHash: ZERO_PATH_HASH,
      referrer: ethers.ZeroAddress,
      referrer2: ethers.ZeroAddress,
      listingNode: ethers.ZeroAddress,
      sellingNode: ethers.ZeroAddress,
      expiresAt: BigInt(now + 3600),
      nonce: 0n,
    };
    const sig = await buyer.signTypedData(
      await domain(),
      EIP712_P2P_TYPES,
      plain
    );

    // `P2PBuySettled` is likewise emitted from the {PrioritySettlement}
    // library (DELEGATECALL) at the vault address.
    const asPriority = await ethers.getContractAt(
      'PrioritySettlement',
      vaultAddr
    );
    await expect(
      vault.connect(outsider).settleP2PBuy(plain, sig, [], [])
    ).to.emit(asPriority, 'P2PBuySettled');

    const fee = plain.paymentAmount / 100n; // exactly 1%, NO surcharge
    expect(await xom.balanceOf(seller.address)).to.equal(
      plain.paymentAmount - fee
    );
  });
});
