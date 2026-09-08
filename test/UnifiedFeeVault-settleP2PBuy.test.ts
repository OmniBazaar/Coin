/**
 * UnifiedFeeVault.settleP2PBuy — Coin-Agnostic Atomic P2P Settlement
 *
 * Exercises the sibling `BuyP2PIntent` flow: payment-only atomic
 * settlement of off-chain listings (goods / services). Mirrors the
 * NFT suite's shape but additionally verifies the listingNode /
 * sellingNode anti-fee-wash guards and the listing-fee sub-split
 * routing (70% listing / 20% selling / 10% ODDAO).
 *
 * Key defences exercised:
 *   - EIP-712 signature verification + replay protection
 *   - H-01 anti-fee-wash referrer collision checks (shared primitive)
 *   - Anti-fee-wash listingNode / sellingNode collision checks (NEW)
 *   - Typehash byte-stability (canonical string match)
 *   - Cross-flow replay isolation: same logical payload produces
 *     distinct NFT vs P2P digests
 *   - CEI ordering (replay flag set BEFORE external calls)
 *   - Swap-path commitment (Solodit router-rotation fix)
 *   - Slippage floor on router output AND on final seller pay
 *   - Per-token allowlist for paymentToken / receiveToken
 *   - Per-token minimum sale amount (decimal-aware dust threshold)
 *   - Listing-fee routing: listingNode / sellingNode zero-address
 *     routing to ODDAO identical to prior NFT-flow behavior
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

interface BuyNFTIntent {
  buyer: string;
  seller: string;
  nftContract: string;
  nftTokenId: bigint;
  paymentToken: string;
  paymentAmount: bigint;
  receiveToken: string;
  minReceiveAmount: bigint;
  swapPathHash: string;
  listingId: bigint;
  referrer: string;
  referrer2: string;
  expiresAt: bigint;
  nonce: bigint;
}

const DEPOSITOR_ROLE = ethers.keccak256(ethers.toUtf8Bytes('DEPOSITOR_ROLE'));

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

const EIP712_NFT_TYPES = {
  BuyNFT: [
    { name: 'buyer', type: 'address' },
    { name: 'seller', type: 'address' },
    { name: 'nftContract', type: 'address' },
    { name: 'nftTokenId', type: 'uint256' },
    { name: 'paymentToken', type: 'address' },
    { name: 'paymentAmount', type: 'uint256' },
    { name: 'receiveToken', type: 'address' },
    { name: 'minReceiveAmount', type: 'uint256' },
    { name: 'swapPathHash', type: 'bytes32' },
    { name: 'listingId', type: 'uint256' },
    { name: 'referrer', type: 'address' },
    { name: 'referrer2', type: 'address' },
    { name: 'expiresAt', type: 'uint256' },
    { name: 'nonce', type: 'uint256' },
  ],
};

/**
 * EIP-712 types for the M-05 seller node attestation. The SELLER
 * co-signs the node fee recipients bound to the listing content hash;
 * `settleP2PBuyAttested` recovers the signer and requires it to equal
 * `intent.seller`. Must match `SELLER_NODE_ATTESTATION_TYPEHASH`
 * byte-for-byte.
 */
const EIP712_ATTESTATION_TYPES = {
  SellerNodeAttestation: [
    { name: 'listingContentHash', type: 'bytes32' },
    { name: 'listingNode', type: 'address' },
    { name: 'sellingNode', type: 'address' },
  ],
};

const ZERO_PATH_HASH = ethers.ZeroHash;
const TIMELOCK_DELAY = 48 * 60 * 60;

/**
 * Deploy the vault's external libraries (`MarketplaceFeeSplitter`,
 * `RoyaltyResolver`, `SwapExecutor`) once per test run and return a
 * `UnifiedFeeVault` contract factory with all three addresses linked.
 * The libraries were extracted from the vault to keep the deployed
 * bytecode under the 24 KiB Spurious Dragon limit; all observable
 * behaviour is identical to the prior inline implementation.
 *
 * @returns A `ContractFactory` for `UnifiedFeeVault` with the
 *          `MarketplaceFeeSplitter`, `RoyaltyResolver`, and
 *          `SwapExecutor` library addresses linked.
 */
const libAddrCache: Record<string, string> = {};
async function deployLibrary(name: string): Promise<string> {
  if (libAddrCache[name] !== undefined) return libAddrCache[name];
  const factory = await ethers.getContractFactory(name);
  const lib = await factory.deploy();
  await lib.waitForDeployment();
  libAddrCache[name] = await lib.getAddress();
  return libAddrCache[name];
}
/**
 * Deploy + link every external library the vault depends on. After the
 * sale-time priority-surcharge refactor the vault links
 * {MarketplaceFeeSplitter}, {CoinAgnosticSettlement}, and
 * {PrioritySettlement}; the leaf libraries ({RoyaltyResolver},
 * {SwapExecutor}, {BuyIntentValidator}) are linked INTO the two
 * settlement libraries, not the vault directly.
 *
 * @returns A linked `UnifiedFeeVault` `ContractFactory`.
 */
async function getVaultFactory(): Promise<any> {
  const marketplaceFeeSplitter = await deployLibrary('MarketplaceFeeSplitter');
  const royaltyResolver = await deployLibrary('RoyaltyResolver');
  const swapExecutor = await deployLibrary('SwapExecutor');
  const buyIntentValidator = await deployLibrary('BuyIntentValidator');
  if (libAddrCache['CoinAgnosticSettlement'] === undefined) {
    const cas = await ethers.getContractFactory('CoinAgnosticSettlement', {
      libraries: {
        MarketplaceFeeSplitter: marketplaceFeeSplitter,
        RoyaltyResolver: royaltyResolver,
        SwapExecutor: swapExecutor,
      },
    });
    const casLib = await cas.deploy();
    await casLib.waitForDeployment();
    libAddrCache['CoinAgnosticSettlement'] = await casLib.getAddress();
  }
  if (libAddrCache['PrioritySettlement'] === undefined) {
    const ps = await ethers.getContractFactory('PrioritySettlement', {
      libraries: {
        CoinAgnosticSettlement: libAddrCache['CoinAgnosticSettlement'],
        BuyIntentValidator: buyIntentValidator,
      },
    });
    const psLib = await ps.deploy();
    await psLib.waitForDeployment();
    libAddrCache['PrioritySettlement'] = await psLib.getAddress();
  }
  const nftSellerConsent = await deployLibrary('NftSellerConsent');
  const bridgeDestinationLib = await deployLibrary('BridgeDestinationLib');
  return ethers.getContractFactory('UnifiedFeeVault', {
    libraries: {
      MarketplaceFeeSplitter: marketplaceFeeSplitter,
      CoinAgnosticSettlement: libAddrCache['CoinAgnosticSettlement'],
      PrioritySettlement: libAddrCache['PrioritySettlement'],
      NftSellerConsent: nftSellerConsent,
      BridgeDestinationLib: bridgeDestinationLib,
    },
  });
}

/**
 * Compute the `swapPathHash` that the vault verifies. Binds the path,
 * sources, AND the current `nftSwapRouter` address so a governance
 * router change invalidates pre-signed intents (Solodit Spearbit/Uniswap
 * 2024). Caller must pass the router address live at quote time.
 *
 * @param path Ordered token path for the swap.
 * @param sources Liquidity source IDs per hop.
 * @param router Current `nftSwapRouter` address the buyer authorizes.
 * @returns The 32-byte commitment hash.
 */
function computeSwapPathHash(
  path: string[],
  sources: string[],
  router: string
): string {
  return ethers.keccak256(
    ethers.AbiCoder.defaultAbiCoder().encode(
      ['address[]', 'bytes32[]', 'address'],
      [path, sources, router]
    )
  );
}

// ═════════════════════════════════════════════════════════════════════

describe('UnifiedFeeVault.settleP2PBuy — Coin-Agnostic P2P', function () {
  let vault: any;
  let xom: any;
  let usdc: any;
  let router: any;

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
  let usdcAddr: string;
  let routerAddr: string;

  /**
   * Deploy vault V2 + OmniSwapRouter mock, run initializeV2, enrol XOM
   * and USDC as supported tokens through the timelock.
   */
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
    usdc = await MockERC20.deploy('USDC', 'USDC');
    usdcAddr = await usdc.getAddress();

    // OmniSwapRouter mock — exchange rate 1:1 by default.
    const MockRouter = await ethers.getContractFactory('MockOmniSwapRouter');
    router = await MockRouter.deploy(ethers.parseEther('1'));
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

    // Seed V2 state.
    await vault.connect(admin).initializeV2(routerAddr, xomAddr);

    // Add USDC via timelock.
    await vault.connect(admin).proposeSupportedPaymentToken(usdcAddr, true);
    await vault.connect(admin).proposeMinSaleAmount(usdcAddr, 10_000n);
    await time.increase(TIMELOCK_DELAY + 1);
    await vault.connect(admin).applySupportedPaymentToken();
    await vault.connect(admin).applyMinSaleAmount();

    // Bootstrap buyer balances + approvals.
    await xom.mint(buyer.address, ethers.parseEther('1000000'));
    await usdc.mint(buyer.address, ethers.parseEther('1000000'));
    await xom.connect(buyer).approve(vaultAddr, ethers.MaxUint256);
    await usdc.connect(buyer).approve(vaultAddr, ethers.MaxUint256);
  }

  /** Build a default P2P intent for `buyer` purchasing off-chain listing. */
  async function buildIntent(
    overrides: Partial<BuyP2PIntent> = {}
  ): Promise<BuyP2PIntent> {
    const now = await time.latest();
    return {
      buyer: buyer.address,
      seller: seller.address,
      listingContentHash: ethers.id('listing-content-v1'),
      listingId: 42n,
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
      ...overrides,
    };
  }

  /** Sign a P2P intent using the vault's live chain id. */
  async function signIntent(
    signer: any,
    intent: BuyP2PIntent
  ): Promise<string> {
    const { chainId } = await ethers.provider.getNetwork();
    const domain = {
      name: 'OmniBazaar',
      version: '1',
      chainId,
      verifyingContract: vaultAddr,
    };
    return signer.signTypedData(domain, EIP712_P2P_TYPES, intent);
  }

  /**
   * Sign the M-05 `SellerNodeAttestation` typed data binding the
   * intent's listing/selling node fee recipients to its listing
   * content hash, over the vault's live EIP-712 domain.
   *
   * @param sellerSigner Signer producing the attestation — the seller
   *        on the happy path; tests pass other signers to exercise
   *        `BadSellerAttestation`.
   * @param intent Intent whose `listingContentHash` / `listingNode` /
   *        `sellingNode` are attested.
   * @returns The 65-byte EIP-712 r/s/v signature.
   */
  async function signNodeAttestation(
    sellerSigner: any,
    intent: BuyP2PIntent
  ): Promise<string> {
    const { chainId } = await ethers.provider.getNetwork();
    const domain = {
      name: 'OmniBazaar',
      version: '1',
      chainId,
      verifyingContract: vaultAddr,
    };
    return sellerSigner.signTypedData(domain, EIP712_ATTESTATION_TYPES, {
      listingContentHash: intent.listingContentHash,
      listingNode: intent.listingNode,
      sellingNode: intent.sellingNode,
    });
  }

  /**
   * Compute the EIP-712 digest of a P2P intent locally. Replaces the
   * removed `hashP2PIntent` external view (dropped in the M-05
   * upgrade for code size) — `ethers.TypedDataEncoder.hash` over the
   * vault's domain yields the identical `_hashTypedDataV4` digest.
   *
   * @param intent Buyer intent to hash.
   * @returns The 32-byte EIP-712 digest.
   */
  async function hashP2PIntentLocal(intent: BuyP2PIntent): Promise<string> {
    const { chainId } = await ethers.provider.getNetwork();
    return ethers.TypedDataEncoder.hash(
      {
        name: 'OmniBazaar',
        version: '1',
        chainId,
        verifyingContract: vaultAddr,
      },
      EIP712_P2P_TYPES,
      intent
    );
  }

  /**
   * Compute the EIP-712 digest of an NFT intent locally. Replaces the
   * removed `hashNftIntent` external view (dropped in the M-05
   * upgrade for code size).
   *
   * @param intent Buyer NFT intent to hash.
   * @returns The 32-byte EIP-712 digest.
   */
  async function hashNftIntentLocal(intent: BuyNFTIntent): Promise<string> {
    const { chainId } = await ethers.provider.getNetwork();
    return ethers.TypedDataEncoder.hash(
      {
        name: 'OmniBazaar',
        version: '1',
        chainId,
        verifyingContract: vaultAddr,
      },
      EIP712_NFT_TYPES,
      intent
    );
  }

  beforeEach(async function () {
    await deployFixture();
  });

  // ═══════════════════════════════════════════════════════════════════
  //   Happy paths — fast path (same token)
  // ═══════════════════════════════════════════════════════════════════

  describe('fast path (same token)', function () {
    it('settles a basic buy in XOM with no referrers or nodes', async function () {
      const intent = await buildIntent();
      const sig = await signIntent(buyer, intent);

      await expect(vault.connect(outsider).settleP2PBuy(intent, sig, [], []))
        .to.emit(vault, 'P2PBuySettled');

      const fee = intent.paymentAmount / 100n;
      expect(await xom.balanceOf(seller.address)).to.equal(
        intent.paymentAmount - fee
      );
    });

    it('credits primary + secondary referrers via pendingClaims', async function () {
      const intent = await buildIntent({
        referrer: referrer1.address,
        referrer2: referrer2.address,
      });
      const sig = await signIntent(buyer, intent);
      await vault.connect(outsider).settleP2PBuy(intent, sig, [], []);

      const fee = intent.paymentAmount / 100n;
      const refFee = fee / 2n;
      const refPrimary = (refFee * 7000n) / 10000n;
      const refSecondary = (refFee * 2000n) / 10000n;
      expect(
        await vault.pendingClaims(referrer1.address, xomAddr)
      ).to.equal(refPrimary);
      expect(
        await vault.pendingClaims(referrer2.address, xomAddr)
      ).to.equal(refSecondary);
    });

    it('credits listingNode 70% + sellingNode 20% of listing-fee component', async function () {
      const intent = await buildIntent({
        listingNode: listingNode.address,
        sellingNode: sellingNode.address,
      });
      const sig = await signIntent(buyer, intent);
      const attestation = await signNodeAttestation(seller, intent);
      await vault
        .connect(outsider)
        .settleP2PBuyAttested(intent, sig, attestation, [], []);

      const fee = intent.paymentAmount / 100n;
      const txFee = fee / 4n;
      const refFee = fee / 2n;
      const listFee = fee - txFee - refFee;
      const listShare = (listFee * 7000n) / 10000n;
      const sellShare = (listFee * 2000n) / 10000n;
      expect(
        await vault.pendingClaims(listingNode.address, xomAddr)
      ).to.equal(listShare);
      expect(
        await vault.pendingClaims(sellingNode.address, xomAddr)
      ).to.equal(sellShare);
    });

    it('credits all 4 recipients (referrer/ref2/listingNode/sellingNode) simultaneously', async function () {
      const intent = await buildIntent({
        referrer: referrer1.address,
        referrer2: referrer2.address,
        listingNode: listingNode.address,
        sellingNode: sellingNode.address,
      });
      const sig = await signIntent(buyer, intent);
      const attestation = await signNodeAttestation(seller, intent);
      await vault
        .connect(outsider)
        .settleP2PBuyAttested(intent, sig, attestation, [], []);

      const fee = intent.paymentAmount / 100n;
      const txFee = fee / 4n;
      const refFee = fee / 2n;
      const listFee = fee - txFee - refFee;

      const refPrimary = (refFee * 7000n) / 10000n;
      const refSecondary = (refFee * 2000n) / 10000n;
      const listShare = (listFee * 7000n) / 10000n;
      const sellShare = (listFee * 2000n) / 10000n;

      expect(
        await vault.pendingClaims(referrer1.address, xomAddr)
      ).to.equal(refPrimary);
      expect(
        await vault.pendingClaims(referrer2.address, xomAddr)
      ).to.equal(refSecondary);
      expect(
        await vault.pendingClaims(listingNode.address, xomAddr)
      ).to.equal(listShare);
      expect(
        await vault.pendingClaims(sellingNode.address, xomAddr)
      ).to.equal(sellShare);
    });

    it('emits P2PBuySettled with correct payload fields', async function () {
      const intent = await buildIntent({
        listingNode: listingNode.address,
        sellingNode: sellingNode.address,
      });
      const sig = await signIntent(buyer, intent);
      const attestation = await signNodeAttestation(seller, intent);
      const fee = intent.paymentAmount / 100n;

      await expect(
        vault
          .connect(buyer)
          .settleP2PBuyAttested(intent, sig, attestation, [], [])
      )
        .to.emit(vault, 'P2PBuySettled')
        .withArgs(
          intent.listingId,
          intent.listingContentHash,
          buyer.address,
          seller.address,
          intent.paymentToken,
          intent.paymentAmount,
          intent.receiveToken,
          intent.paymentAmount,
          fee,
          intent.referrer,
          intent.referrer2,
          intent.listingNode,
          intent.sellingNode
        );
    });

    it('fast path does NOT call the swap router', async function () {
      const before = await router.swapCallCount();
      const intent = await buildIntent();
      const sig = await signIntent(buyer, intent);
      await vault.connect(buyer).settleP2PBuy(intent, sig, [], []);
      expect(await router.swapCallCount()).to.equal(before);
    });

    it('fast path stays under 450k gas', async function () {
      // The settlement orchestration moved into the DELEGATECALL-linked
      // {PrioritySettlement} library to keep the vault under the 24 KiB
      // EIP-170 limit (sale-time priority-surcharge refactor). The extra
      // delegatecall hop adds ~16k gas to the fast path; the budget was
      // bumped 400k → 450k to reflect the intentional architecture change.
      const intent = await buildIntent({
        referrer: referrer1.address,
        referrer2: referrer2.address,
        listingNode: listingNode.address,
        sellingNode: sellingNode.address,
      });
      const sig = await signIntent(buyer, intent);
      const attestation = await signNodeAttestation(seller, intent);
      const tx = await vault
        .connect(buyer)
        .settleP2PBuyAttested(intent, sig, attestation, [], []);
      const receipt = await tx.wait();
      expect(receipt.gasUsed).to.be.lessThan(450_000n);
    });

    it('increments totalFeesCollected after settlement', async function () {
      const before = await vault.totalFeesCollected();
      const intent = await buildIntent();
      const sig = await signIntent(buyer, intent);
      await vault.connect(buyer).settleP2PBuy(intent, sig, [], []);
      expect((await vault.totalFeesCollected()) - before).to.equal(
        intent.paymentAmount / 100n
      );
    });

    it('reverts SettlementNotConfigured when xomToken is 0', async function () {
      const UnifiedFeeVault = await getVaultFactory();
      const fresh = await upgrades.deployProxy(
        UnifiedFeeVault,
        [admin.address, stakingPool.address, protocolTreasury.address],
        {
          initializer: 'initialize',
          kind: 'uups',
          constructorArgs: [ethers.ZeroAddress],
          unsafeAllow: ['constructor', 'external-library-linking'],
        }
      );
      const intent = await buildIntent();
      const sig = await signIntent(buyer, intent);
      await expect(
        fresh.connect(buyer).settleP2PBuy(intent, sig, [], [])
      ).to.be.revertedWithCustomError(fresh, 'SettlementNotConfigured');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //   Swap path — paymentToken != receiveToken
  // ═══════════════════════════════════════════════════════════════════

  describe('swap path (USDC -> XOM)', function () {
    it('settles: buyer pays USDC, seller receives XOM net of fee', async function () {
      const paymentAmount = ethers.parseEther('100');
      const minReceive = ethers.parseEther('98');
      const path = [usdcAddr, xomAddr];
      const sources = [ethers.id('MOCK')];
      const hash = computeSwapPathHash(path, sources, routerAddr);

      const intent = await buildIntent({
        paymentToken: usdcAddr,
        paymentAmount,
        receiveToken: xomAddr,
        minReceiveAmount: minReceive,
        swapPathHash: hash,
      });
      const sig = await signIntent(buyer, intent);

      await expect(
        vault.connect(outsider).settleP2PBuy(intent, sig, path, sources)
      ).to.emit(vault, 'P2PBuySettled');

      expect(await xom.balanceOf(seller.address)).to.equal(
        paymentAmount - paymentAmount / 100n
      );
      expect(await usdc.balanceOf(buyer.address)).to.equal(
        ethers.parseEther('999900')
      );
      expect(await router.swapCallCount()).to.equal(1n);
    });

    it('swap path stays under 700k gas', async function () {
      const path = [usdcAddr, xomAddr];
      const sources = [ethers.id('MOCK')];
      const hash = computeSwapPathHash(path, sources, routerAddr);
      const intent = await buildIntent({
        paymentToken: usdcAddr,
        paymentAmount: ethers.parseEther('100'),
        receiveToken: xomAddr,
        minReceiveAmount: ethers.parseEther('98'),
        swapPathHash: hash,
        referrer: referrer1.address,
        referrer2: referrer2.address,
        listingNode: listingNode.address,
        sellingNode: sellingNode.address,
      });
      const sig = await signIntent(buyer, intent);
      const attestation = await signNodeAttestation(seller, intent);
      const tx = await vault
        .connect(buyer)
        .settleP2PBuyAttested(intent, sig, attestation, path, sources);
      const receipt = await tx.wait();
      expect(receipt.gasUsed).to.be.lessThan(700_000n);
    });

    it('distributes fee in receiveToken, not paymentToken', async function () {
      const paymentAmount = ethers.parseEther('100');
      const path = [usdcAddr, xomAddr];
      const sources = [ethers.id('MOCK')];
      const hash = computeSwapPathHash(path, sources, routerAddr);

      const intent = await buildIntent({
        paymentToken: usdcAddr,
        paymentAmount,
        receiveToken: xomAddr,
        minReceiveAmount: ethers.parseEther('98'),
        swapPathHash: hash,
        listingNode: listingNode.address,
      });
      const sig = await signIntent(buyer, intent);
      const attestation = await signNodeAttestation(seller, intent);
      await vault
        .connect(buyer)
        .settleP2PBuyAttested(intent, sig, attestation, path, sources);

      const fee = paymentAmount / 100n;
      const listFee = fee - fee / 2n - fee / 4n;
      const listShare = (listFee * 7000n) / 10000n;
      expect(
        await vault.pendingClaims(listingNode.address, xomAddr)
      ).to.equal(listShare);
      expect(
        await vault.pendingClaims(listingNode.address, usdcAddr)
      ).to.equal(0n);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //   EIP-712 Domain / Typehash
  // ═══════════════════════════════════════════════════════════════════

  describe('EIP-712 domain / typehash', function () {
    it('BUY_P2P_TYPEHASH matches the canonical string byte-for-byte', async function () {
      const expected = ethers.keccak256(
        ethers.toUtf8Bytes(
          'BuyP2P(address buyer,address seller,bytes32 listingContentHash,' +
            'uint256 listingId,address paymentToken,uint256 paymentAmount,' +
            'address receiveToken,uint256 minReceiveAmount,' +
            'bytes32 swapPathHash,address referrer,address referrer2,' +
            'address listingNode,address sellingNode,' +
            'uint256 expiresAt,uint256 nonce)'
        )
      );
      expect(await vault.BUY_P2P_TYPEHASH()).to.equal(expected);
    });

    it('BUY_P2P_TYPEHASH differs from BUY_NFT_TYPEHASH', async function () {
      const nftTh: string = await vault.BUY_NFT_TYPEHASH();
      const p2pTh: string = await vault.BUY_P2P_TYPEHASH();
      expect(p2pTh).to.not.equal(nftTh);
    });

    it('locally computed P2P digest recovers the original signer', async function () {
      const intent = await buildIntent();
      const { chainId } = await ethers.provider.getNetwork();
      const digest: string = await hashP2PIntentLocal(intent);
      const sig = await signIntent(buyer, intent);
      const recovered = ethers.verifyTypedData(
        {
          name: 'OmniBazaar',
          version: '1',
          chainId,
          verifyingContract: vaultAddr,
        },
        EIP712_P2P_TYPES,
        intent,
        sig
      );
      expect(recovered).to.equal(buyer.address);
      expect(digest).to.match(/^0x[0-9a-f]{64}$/i);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //   Signature / Replay
  // ═══════════════════════════════════════════════════════════════════

  describe('signature verification', function () {
    it('reverts BadSigner when a different signer signs', async function () {
      const intent = await buildIntent();
      const sig = await signIntent(seller, intent);
      await expect(
        vault.connect(buyer).settleP2PBuy(intent, sig, [], [])
      ).to.be.revertedWithCustomError(vault, 'BadSigner');
    });

    it('reverts on mutated paymentAmount after signing', async function () {
      const intent = await buildIntent();
      const sig = await signIntent(buyer, intent);
      const mutated = { ...intent, paymentAmount: intent.paymentAmount + 1n };
      await expect(
        vault.connect(buyer).settleP2PBuy(mutated, sig, [], [])
      ).to.be.revertedWithCustomError(vault, 'BadSigner');
    });

    it('reverts on mutated listingNode after signing', async function () {
      const intent = await buildIntent({
        listingNode: listingNode.address,
      });
      const sig = await signIntent(buyer, intent);
      // Mutate AFTER the buyer signed. The seller attestation is
      // signed over the MUTATED node values (it is verified BEFORE
      // the buyer signature in `settleP2PBuyAttested`), so the buyer
      // signature check is what catches the tamper — `BadSigner`.
      const mutated = { ...intent, listingNode: outsider.address };
      const attestation = await signNodeAttestation(seller, mutated);
      await expect(
        vault
          .connect(buyer)
          .settleP2PBuyAttested(mutated, sig, attestation, [], [])
      ).to.be.revertedWithCustomError(vault, 'BadSigner');
    });

    it('reverts on mutated sellingNode after signing', async function () {
      const intent = await buildIntent({
        sellingNode: sellingNode.address,
      });
      const sig = await signIntent(buyer, intent);
      // Same construction as the listingNode tamper test above:
      // attestation matches the mutated intent so the buyer-signature
      // check is the guard under test.
      const mutated = { ...intent, sellingNode: outsider.address };
      const attestation = await signNodeAttestation(seller, mutated);
      await expect(
        vault
          .connect(buyer)
          .settleP2PBuyAttested(mutated, sig, attestation, [], [])
      ).to.be.revertedWithCustomError(vault, 'BadSigner');
    });

    it('reverts on mutated listingContentHash after signing', async function () {
      const intent = await buildIntent();
      const sig = await signIntent(buyer, intent);
      const mutated = { ...intent, listingContentHash: ethers.id('DIFFERENT') };
      await expect(
        vault.connect(buyer).settleP2PBuy(mutated, sig, [], [])
      ).to.be.revertedWithCustomError(vault, 'BadSigner');
    });
  });

  describe('replay protection', function () {
    it('reverts Replay on a second settlement with the same intent', async function () {
      const intent = await buildIntent();
      const sig = await signIntent(buyer, intent);
      await vault.connect(buyer).settleP2PBuy(intent, sig, [], []);
      // Restore buyer's XOM so the retry isn't rejected for balance reasons.
      await xom.connect(seller).transfer(
        buyer.address,
        intent.paymentAmount - intent.paymentAmount / 100n
      );
      await expect(
        vault.connect(buyer).settleP2PBuy(intent, sig, [], [])
      ).to.be.revertedWithCustomError(vault, 'Replay');
    });

    it('isP2PIntentUsed flips from false to true after settlement', async function () {
      const intent = await buildIntent();
      const digest = await hashP2PIntentLocal(intent);
      expect(await vault.isP2PIntentUsed(digest)).to.equal(false);
      const sig = await signIntent(buyer, intent);
      await vault.connect(buyer).settleP2PBuy(intent, sig, [], []);
      expect(await vault.isP2PIntentUsed(digest)).to.equal(true);
    });

    it('cross-path isolation: same logical payload produces distinct NFT vs P2P digests', async function () {
      // Build a P2P intent and compute its digest.
      const p2pIntent = await buildIntent();
      const p2pDigest = await hashP2PIntentLocal(p2pIntent);

      // Build an NFT intent that shares as many fields as possible. Even
      // with overlapping values, different typehashes MUST yield
      // different digests — neither mapping should collide.
      const now = await time.latest();
      const nftIntent: BuyNFTIntent = {
        buyer: buyer.address,
        seller: seller.address,
        nftContract: xomAddr, // any non-zero; shape comparable
        nftTokenId: 99n,
        paymentToken: xomAddr,
        paymentAmount: ethers.parseEther('100'),
        receiveToken: xomAddr,
        minReceiveAmount: ethers.parseEther('99'),
        swapPathHash: ZERO_PATH_HASH,
        listingId: 42n,
        referrer: ethers.ZeroAddress,
        referrer2: ethers.ZeroAddress,
        expiresAt: BigInt(now + 3600),
        nonce: 0n,
      };
      const nftDigest = await hashNftIntentLocal(nftIntent);
      expect(p2pDigest).to.not.equal(nftDigest);

      // Consuming one path MUST NOT mark the other used.
      const sig = await signIntent(buyer, p2pIntent);
      await vault.connect(buyer).settleP2PBuy(p2pIntent, sig, [], []);
      expect(await vault.isP2PIntentUsed(p2pDigest)).to.equal(true);
      expect(await vault.isNftIntentUsed(nftDigest)).to.equal(false);
    });

    it('replays on a different chainId domain fail (chain-id binding)', async function () {
      // Sign with a DIFFERENT chainId than the vault's live one.
      const intent = await buildIntent();
      const domain = {
        name: 'OmniBazaar',
        version: '1',
        chainId: 9999,
        verifyingContract: vaultAddr,
      };
      const sig = await buyer.signTypedData(domain, EIP712_P2P_TYPES, intent);
      await expect(
        vault.connect(buyer).settleP2PBuy(intent, sig, [], [])
      ).to.be.revertedWithCustomError(vault, 'BadSigner');
    });

    it('replays on a different verifyingContract fail', async function () {
      const intent = await buildIntent();
      const { chainId } = await ethers.provider.getNetwork();
      const domain = {
        name: 'OmniBazaar',
        version: '1',
        chainId,
        verifyingContract: outsider.address,
      };
      const sig = await buyer.signTypedData(domain, EIP712_P2P_TYPES, intent);
      await expect(
        vault.connect(buyer).settleP2PBuy(intent, sig, [], [])
      ).to.be.revertedWithCustomError(vault, 'BadSigner');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //   Validation — basic fields (shared primitives)
  // ═══════════════════════════════════════════════════════════════════

  describe('field validation', function () {
    it('reverts SelfBuy when buyer == seller', async function () {
      const intent = await buildIntent({ seller: buyer.address });
      const sig = await signIntent(buyer, intent);
      await expect(
        vault.connect(buyer).settleP2PBuy(intent, sig, [], [])
      ).to.be.revertedWithCustomError(vault, 'SelfBuy');
    });

    it('reverts ZeroAddress when buyer is 0', async function () {
      const intent = await buildIntent({ buyer: ethers.ZeroAddress });
      const sig = await signIntent(buyer, intent);
      await expect(
        vault.connect(buyer).settleP2PBuy(intent, sig, [], [])
      ).to.be.revertedWithCustomError(vault, 'ZeroAddress');
    });

    it('reverts ZeroAddress when seller is 0', async function () {
      const intent = await buildIntent({ seller: ethers.ZeroAddress });
      const sig = await signIntent(buyer, intent);
      await expect(
        vault.connect(buyer).settleP2PBuy(intent, sig, [], [])
      ).to.be.revertedWithCustomError(vault, 'ZeroAddress');
    });

    it('reverts Expired when expiresAt is in the past', async function () {
      const latest = await time.latest();
      const intent = await buildIntent({ expiresAt: BigInt(latest - 10) });
      const sig = await signIntent(buyer, intent);
      await expect(
        vault.connect(buyer).settleP2PBuy(intent, sig, [], [])
      ).to.be.revertedWithCustomError(vault, 'Expired');
    });

    it('reverts UnsupportedToken when paymentToken not on allowlist', async function () {
      const MockERC20 = await ethers.getContractFactory('MockERC20');
      const dai = await MockERC20.deploy('DAI', 'DAI');
      await dai.waitForDeployment();
      const daiAddr = await dai.getAddress();
      await dai.mint(buyer.address, ethers.parseEther('1000'));
      await dai.connect(buyer).approve(vaultAddr, ethers.MaxUint256);
      const intent = await buildIntent({
        paymentToken: daiAddr,
        paymentAmount: ethers.parseEther('100'),
      });
      const sig = await signIntent(buyer, intent);
      await expect(
        vault.connect(buyer).settleP2PBuy(intent, sig, [], [])
      ).to.be.revertedWithCustomError(vault, 'UnsupportedToken');
    });

    it('reverts UnsupportedToken when receiveToken not on allowlist', async function () {
      const MockERC20 = await ethers.getContractFactory('MockERC20');
      const dai = await MockERC20.deploy('DAI', 'DAI');
      await dai.waitForDeployment();
      const daiAddr = await dai.getAddress();
      const intent = await buildIntent({ receiveToken: daiAddr });
      const sig = await signIntent(buyer, intent);
      await expect(
        vault.connect(buyer).settleP2PBuy(intent, sig, [], [])
      ).to.be.revertedWithCustomError(vault, 'UnsupportedToken');
    });

    it('reverts ZeroAmount when paymentAmount == 0', async function () {
      const intent = await buildIntent({ paymentAmount: 0n });
      const sig = await signIntent(buyer, intent);
      await expect(
        vault.connect(buyer).settleP2PBuy(intent, sig, [], [])
      ).to.be.revertedWithCustomError(vault, 'ZeroAmount');
    });

    it('reverts ZeroAmount when minReceiveAmount == 0', async function () {
      const intent = await buildIntent({ minReceiveAmount: 0n });
      const sig = await signIntent(buyer, intent);
      await expect(
        vault.connect(buyer).settleP2PBuy(intent, sig, [], [])
      ).to.be.revertedWithCustomError(vault, 'ZeroAmount');
    });

    it('reverts SaleAmountTooSmall when below perTokenMinSaleAmount', async function () {
      await vault.connect(admin).proposeMinSaleAmount(xomAddr, 1_000_000n);
      await time.increase(TIMELOCK_DELAY + 1);
      await vault.connect(admin).applyMinSaleAmount();
      const intent = await buildIntent({ minReceiveAmount: 500_000n });
      const sig = await signIntent(buyer, intent);
      await expect(
        vault.connect(buyer).settleP2PBuy(intent, sig, [], [])
      ).to.be.revertedWithCustomError(vault, 'SaleAmountTooSmall');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //   H-01 Anti-Fee-Wash — Referrers (shared primitive)
  // ═══════════════════════════════════════════════════════════════════

  describe('H-01 anti-fee-wash — referrers', function () {
    it('reverts BadReferrer when referrer == buyer', async function () {
      const intent = await buildIntent({ referrer: buyer.address });
      const sig = await signIntent(buyer, intent);
      await expect(
        vault.connect(buyer).settleP2PBuy(intent, sig, [], [])
      ).to.be.revertedWithCustomError(vault, 'BadReferrer');
    });

    it('reverts BadReferrer when referrer == seller', async function () {
      const intent = await buildIntent({ referrer: seller.address });
      const sig = await signIntent(buyer, intent);
      await expect(
        vault.connect(buyer).settleP2PBuy(intent, sig, [], [])
      ).to.be.revertedWithCustomError(vault, 'BadReferrer');
    });

    it('reverts BadReferrer when referrer2 == referrer', async function () {
      const intent = await buildIntent({
        referrer: referrer1.address,
        referrer2: referrer1.address,
      });
      const sig = await signIntent(buyer, intent);
      await expect(
        vault.connect(buyer).settleP2PBuy(intent, sig, [], [])
      ).to.be.revertedWithCustomError(vault, 'BadReferrer');
    });

    it('accepts distinct referrer and referrer2', async function () {
      const intent = await buildIntent({
        referrer: referrer1.address,
        referrer2: referrer2.address,
      });
      const sig = await signIntent(buyer, intent);
      await expect(
        vault.connect(buyer).settleP2PBuy(intent, sig, [], [])
      ).to.not.be.reverted;
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //   Anti-Fee-Wash — listingNode / sellingNode (NEW)
  // ═══════════════════════════════════════════════════════════════════

  describe('anti-fee-wash — listingNode', function () {
    // M-05: non-zero nodes only settle via `settleP2PBuyAttested`, so
    // every collision test routes through the attested path with a
    // valid seller attestation — the collision guard inside the shared
    // settlement primitive is still what reverts.
    it('reverts BadListingNode when listingNode == buyer', async function () {
      const intent = await buildIntent({ listingNode: buyer.address });
      const sig = await signIntent(buyer, intent);
      const attestation = await signNodeAttestation(seller, intent);
      await expect(
        vault
          .connect(buyer)
          .settleP2PBuyAttested(intent, sig, attestation, [], [])
      ).to.be.revertedWithCustomError(vault, 'BadListingNode');
    });

    it('ALLOWS listingNode == seller (merchant runs own node, change 2026-05-18)', async function () {
      // Per founder direction 2026-05-18: the intended use case is that a
      // merchant runs HER OWN listing node and imports her own listings to
      // it. In that flow the listing node IS the seller, and earning the
      // 70% listing-node share is the correct payout. The other anti-fee-
      // wash collisions (buyer / referrer / referrer2 / sellingNode) still
      // revert — see other tests in this describe block.
      const intent = await buildIntent({ listingNode: seller.address });
      const sig = await signIntent(buyer, intent);
      const attestation = await signNodeAttestation(seller, intent);
      await expect(
        vault
          .connect(buyer)
          .settleP2PBuyAttested(intent, sig, attestation, [], [])
      ).to.not.be.reverted;
    });

    it('reverts BadListingNode when listingNode == referrer', async function () {
      const intent = await buildIntent({
        referrer: referrer1.address,
        listingNode: referrer1.address,
      });
      const sig = await signIntent(buyer, intent);
      const attestation = await signNodeAttestation(seller, intent);
      await expect(
        vault
          .connect(buyer)
          .settleP2PBuyAttested(intent, sig, attestation, [], [])
      ).to.be.revertedWithCustomError(vault, 'BadListingNode');
    });

    it('reverts BadListingNode when listingNode == referrer2', async function () {
      const intent = await buildIntent({
        referrer: referrer1.address,
        referrer2: referrer2.address,
        listingNode: referrer2.address,
      });
      const sig = await signIntent(buyer, intent);
      const attestation = await signNodeAttestation(seller, intent);
      await expect(
        vault
          .connect(buyer)
          .settleP2PBuyAttested(intent, sig, attestation, [], [])
      ).to.be.revertedWithCustomError(vault, 'BadListingNode');
    });

    it('reverts BadListingNode when listingNode == sellingNode', async function () {
      const intent = await buildIntent({
        listingNode: listingNode.address,
        sellingNode: listingNode.address,
      });
      const sig = await signIntent(buyer, intent);
      const attestation = await signNodeAttestation(seller, intent);
      await expect(
        vault
          .connect(buyer)
          .settleP2PBuyAttested(intent, sig, attestation, [], [])
      ).to.be.revertedWithCustomError(vault, 'BadListingNode');
    });
  });

  describe('anti-fee-wash — sellingNode', function () {
    it('reverts BadSellingNode when sellingNode == buyer', async function () {
      const intent = await buildIntent({ sellingNode: buyer.address });
      const sig = await signIntent(buyer, intent);
      const attestation = await signNodeAttestation(seller, intent);
      await expect(
        vault
          .connect(buyer)
          .settleP2PBuyAttested(intent, sig, attestation, [], [])
      ).to.be.revertedWithCustomError(vault, 'BadSellingNode');
    });

    it('reverts BadSellingNode when sellingNode == seller', async function () {
      const intent = await buildIntent({ sellingNode: seller.address });
      const sig = await signIntent(buyer, intent);
      const attestation = await signNodeAttestation(seller, intent);
      await expect(
        vault
          .connect(buyer)
          .settleP2PBuyAttested(intent, sig, attestation, [], [])
      ).to.be.revertedWithCustomError(vault, 'BadSellingNode');
    });

    it('reverts BadSellingNode when sellingNode == referrer', async function () {
      const intent = await buildIntent({
        referrer: referrer1.address,
        sellingNode: referrer1.address,
      });
      const sig = await signIntent(buyer, intent);
      const attestation = await signNodeAttestation(seller, intent);
      await expect(
        vault
          .connect(buyer)
          .settleP2PBuyAttested(intent, sig, attestation, [], [])
      ).to.be.revertedWithCustomError(vault, 'BadSellingNode');
    });

    it('reverts BadSellingNode when sellingNode == referrer2', async function () {
      const intent = await buildIntent({
        referrer: referrer1.address,
        referrer2: referrer2.address,
        sellingNode: referrer2.address,
      });
      const sig = await signIntent(buyer, intent);
      const attestation = await signNodeAttestation(seller, intent);
      await expect(
        vault
          .connect(buyer)
          .settleP2PBuyAttested(intent, sig, attestation, [], [])
      ).to.be.revertedWithCustomError(vault, 'BadSellingNode');
    });

    it('accepts distinct listingNode and sellingNode', async function () {
      const intent = await buildIntent({
        listingNode: listingNode.address,
        sellingNode: sellingNode.address,
      });
      const sig = await signIntent(buyer, intent);
      const attestation = await signNodeAttestation(seller, intent);
      await expect(
        vault
          .connect(buyer)
          .settleP2PBuyAttested(intent, sig, attestation, [], [])
      ).to.not.be.reverted;
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //   Swap-path Commitment
  // ═══════════════════════════════════════════════════════════════════

  describe('swapPathHash commitment', function () {
    it('accepts matching path when hash is non-zero', async function () {
      const path = [usdcAddr, xomAddr];
      const sources = [ethers.id('MOCK')];
      const hash = computeSwapPathHash(path, sources, routerAddr);
      const intent = await buildIntent({
        paymentToken: usdcAddr,
        paymentAmount: ethers.parseEther('100'),
        receiveToken: xomAddr,
        minReceiveAmount: ethers.parseEther('98'),
        swapPathHash: hash,
      });
      const sig = await signIntent(buyer, intent);
      await expect(
        vault.connect(buyer).settleP2PBuy(intent, sig, path, sources)
      ).to.not.be.reverted;
    });

    it('reverts BadSwapPath when caller passes mismatched path', async function () {
      const path = [usdcAddr, xomAddr];
      const sources = [ethers.id('MOCK')];
      const hash = computeSwapPathHash(path, sources, routerAddr);
      const badPath = [xomAddr, usdcAddr];
      const intent = await buildIntent({
        paymentToken: usdcAddr,
        paymentAmount: ethers.parseEther('100'),
        receiveToken: xomAddr,
        minReceiveAmount: ethers.parseEther('99'),
        swapPathHash: hash,
      });
      const sig = await signIntent(buyer, intent);
      await expect(
        vault.connect(buyer).settleP2PBuy(intent, sig, badPath, sources)
      ).to.be.revertedWithCustomError(vault, 'BadSwapPath');
    });

    it('accepts empty path when swapPathHash == bytes32(0) (fast path)', async function () {
      const intent = await buildIntent();
      const sig = await signIntent(buyer, intent);
      await expect(
        vault.connect(buyer).settleP2PBuy(intent, sig, [], [])
      ).to.not.be.reverted;
    });

    it('reverts BadSwapPath when swapPathHash == 0 but non-empty path passed', async function () {
      const intent = await buildIntent();
      const sig = await signIntent(buyer, intent);
      await expect(
        vault
          .connect(buyer)
          .settleP2PBuy(intent, sig, [usdcAddr, xomAddr], [])
      ).to.be.revertedWithCustomError(vault, 'BadSwapPath');
    });

    it('Solodit fix: intent invalidates after router change between sign and submit', async function () {
      const path = [usdcAddr, xomAddr];
      const sources = [ethers.id('MOCK')];
      const oldRouterAddr = routerAddr;
      const oldHash = computeSwapPathHash(path, sources, oldRouterAddr);

      const MockRouter = await ethers.getContractFactory('MockOmniSwapRouter');
      const newRouter = await MockRouter.deploy(ethers.parseEther('1'));
      await newRouter.waitForDeployment();
      await vault
        .connect(admin)
        .proposeNftSwapRouter(await newRouter.getAddress());
      await time.increase(TIMELOCK_DELAY + 1);
      await vault.connect(admin).applyNftSwapRouter();

      const intent = await buildIntent({
        paymentToken: usdcAddr,
        paymentAmount: ethers.parseEther('100'),
        receiveToken: xomAddr,
        minReceiveAmount: ethers.parseEther('98'),
        swapPathHash: oldHash,
        nonce: 77n,
      });
      const sig = await signIntent(buyer, intent);

      await expect(
        vault.connect(buyer).settleP2PBuy(intent, sig, path, sources)
      ).to.be.revertedWithCustomError(vault, 'BadSwapPath');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //   Fee Routing — listingNode / sellingNode zero-address paths
  // ═══════════════════════════════════════════════════════════════════

  describe('fee routing: listingNode/sellingNode', function () {
    it('both zero → 100% listing-fee routes to ODDAO (matches NFT behavior)', async function () {
      const intent = await buildIntent();
      const sig = await signIntent(buyer, intent);
      const bridgeBefore = await vault.pendingBridge(xomAddr);
      await vault.connect(buyer).settleP2PBuy(intent, sig, [], []);
      const bridgeAfter = await vault.pendingBridge(xomAddr);

      const fee = intent.paymentAmount / 100n;
      const txFee = fee / 4n;
      const refFee = fee / 2n;
      const listFee = fee - txFee - refFee;
      // ODDAO collects: 70% tx + 100% ref (no referrers) + 100% list.
      const txOddao = (txFee * 7000n) / 10000n;
      const expectedBridgeDelta = txOddao + refFee + listFee;
      expect(bridgeAfter - bridgeBefore).to.equal(expectedBridgeDelta);
    });

    it('listingNode non-zero, sellingNode zero: 70% → listingNode, 20% + 10% → ODDAO', async function () {
      const intent = await buildIntent({
        listingNode: listingNode.address,
      });
      const sig = await signIntent(buyer, intent);
      const attestation = await signNodeAttestation(seller, intent);
      await vault
        .connect(buyer)
        .settleP2PBuyAttested(intent, sig, attestation, [], []);

      const fee = intent.paymentAmount / 100n;
      const txFee = fee / 4n;
      const refFee = fee / 2n;
      const listFee = fee - txFee - refFee;
      const listShare = (listFee * 7000n) / 10000n;
      expect(
        await vault.pendingClaims(listingNode.address, xomAddr)
      ).to.equal(listShare);
      expect(
        await vault.pendingClaims(sellingNode.address, xomAddr)
      ).to.equal(0n);
    });

    it('listingNode zero, sellingNode non-zero: 20% → sellingNode, 70% + 10% → ODDAO', async function () {
      const intent = await buildIntent({
        sellingNode: sellingNode.address,
      });
      const sig = await signIntent(buyer, intent);
      const attestation = await signNodeAttestation(seller, intent);
      await vault
        .connect(buyer)
        .settleP2PBuyAttested(intent, sig, attestation, [], []);

      const fee = intent.paymentAmount / 100n;
      const txFee = fee / 4n;
      const refFee = fee / 2n;
      const listFee = fee - txFee - refFee;
      const sellShare = (listFee * 2000n) / 10000n;
      expect(
        await vault.pendingClaims(sellingNode.address, xomAddr)
      ).to.equal(sellShare);
      expect(
        await vault.pendingClaims(listingNode.address, xomAddr)
      ).to.equal(0n);
    });

    it('both non-zero: 70% listing / 20% selling / 10% ODDAO', async function () {
      const intent = await buildIntent({
        listingNode: listingNode.address,
        sellingNode: sellingNode.address,
      });
      const sig = await signIntent(buyer, intent);
      const attestation = await signNodeAttestation(seller, intent);
      const bridgeBefore = await vault.pendingBridge(xomAddr);
      await vault
        .connect(buyer)
        .settleP2PBuyAttested(intent, sig, attestation, [], []);
      const bridgeAfter = await vault.pendingBridge(xomAddr);

      const fee = intent.paymentAmount / 100n;
      const txFee = fee / 4n;
      const refFee = fee / 2n;
      const listFee = fee - txFee - refFee;
      const listShare = (listFee * 7000n) / 10000n;
      const sellShare = (listFee * 2000n) / 10000n;
      const listOddao = listFee - listShare - sellShare;

      expect(
        await vault.pendingClaims(listingNode.address, xomAddr)
      ).to.equal(listShare);
      expect(
        await vault.pendingClaims(sellingNode.address, xomAddr)
      ).to.equal(sellShare);
      // ODDAO gets tx 70% + ref 100% (no referrers) + list 10%.
      const txOddao = (txFee * 7000n) / 10000n;
      expect(bridgeAfter - bridgeBefore).to.equal(
        txOddao + refFee + listOddao
      );
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //   M-05 — Seller node attestation
  // ═══════════════════════════════════════════════════════════════════

  describe('M-05 seller node attestation', function () {
    it('legacy settleP2PBuy reverts NodesRequireAttestation with non-zero listingNode', async function () {
      const intent = await buildIntent({
        listingNode: listingNode.address,
      });
      const sig = await signIntent(buyer, intent);
      await expect(
        vault.connect(buyer).settleP2PBuy(intent, sig, [], [])
      ).to.be.revertedWithCustomError(vault, 'NodesRequireAttestation');
    });

    it('legacy settleP2PBuy reverts NodesRequireAttestation with non-zero sellingNode only', async function () {
      const intent = await buildIntent({
        sellingNode: sellingNode.address,
      });
      const sig = await signIntent(buyer, intent);
      await expect(
        vault.connect(buyer).settleP2PBuy(intent, sig, [], [])
      ).to.be.revertedWithCustomError(vault, 'NodesRequireAttestation');
    });

    it('reverts BadSellerAttestation when the BUYER signs the attestation', async function () {
      const intent = await buildIntent({
        listingNode: listingNode.address,
        sellingNode: sellingNode.address,
      });
      const sig = await signIntent(buyer, intent);
      const attestation = await signNodeAttestation(buyer, intent);
      await expect(
        vault
          .connect(buyer)
          .settleP2PBuyAttested(intent, sig, attestation, [], [])
      ).to.be.revertedWithCustomError(vault, 'BadSellerAttestation');
    });

    it('reverts BadSellerAttestation when the attestation covers different nodes', async function () {
      const intent = await buildIntent({
        listingNode: listingNode.address,
        sellingNode: sellingNode.address,
      });
      const sig = await signIntent(buyer, intent);
      // Seller attests DIFFERENT node addresses than the intent
      // carries — recovery yields a non-seller address ⇒ revert.
      const attestation = await signNodeAttestation(seller, {
        ...intent,
        listingNode: outsider.address,
        sellingNode: ethers.ZeroAddress,
      });
      await expect(
        vault
          .connect(buyer)
          .settleP2PBuyAttested(intent, sig, attestation, [], [])
      ).to.be.revertedWithCustomError(vault, 'BadSellerAttestation');
    });

    it('settles with zero nodes + valid seller attestation (attested path accepts no-node listings)', async function () {
      const intent = await buildIntent();
      const sig = await signIntent(buyer, intent);
      const attestation = await signNodeAttestation(seller, intent);
      await expect(
        vault
          .connect(outsider)
          .settleP2PBuyAttested(intent, sig, attestation, [], [])
      ).to.emit(vault, 'P2PBuySettled');

      const fee = intent.paymentAmount / 100n;
      expect(await xom.balanceOf(seller.address)).to.equal(
        intent.paymentAmount - fee
      );
    });

    it('happy path credits listingNode 70% + sellingNode 20% via pendingClaims', async function () {
      const intent = await buildIntent({
        listingNode: listingNode.address,
        sellingNode: sellingNode.address,
      });
      const sig = await signIntent(buyer, intent);
      const attestation = await signNodeAttestation(seller, intent);
      await vault
        .connect(outsider)
        .settleP2PBuyAttested(intent, sig, attestation, [], []);

      const fee = intent.paymentAmount / 100n;
      const txFee = fee / 4n;
      const refFee = fee / 2n;
      const listFee = fee - txFee - refFee;
      const listShare = (listFee * 7000n) / 10000n;
      const sellShare = (listFee * 2000n) / 10000n;
      expect(
        await vault.pendingClaims(listingNode.address, xomAddr)
      ).to.equal(listShare);
      expect(
        await vault.pendingClaims(sellingNode.address, xomAddr)
      ).to.equal(sellShare);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //   Pause / Roles
  // ═══════════════════════════════════════════════════════════════════

  describe('pause & roles', function () {
    it('reverts when the vault is paused', async function () {
      await vault.connect(admin).pause();
      const intent = await buildIntent();
      const sig = await signIntent(buyer, intent);
      await expect(
        vault.connect(buyer).settleP2PBuy(intent, sig, [], [])
      ).to.be.reverted;
    });

    it('settleP2PBuy does NOT require DEPOSITOR_ROLE on the caller', async function () {
      expect(await vault.hasRole(DEPOSITOR_ROLE, buyer.address)).to.equal(false);
      const intent = await buildIntent();
      const sig = await signIntent(buyer, intent);
      await expect(
        vault.connect(buyer).settleP2PBuy(intent, sig, [], [])
      ).to.not.be.reverted;
    });
  });
});
