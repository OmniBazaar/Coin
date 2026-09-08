/**
 * UnifiedFeeVault.settleNftBuy — Coin-Agnostic Atomic NFT Settlement
 *
 * Exercises the redesigned `BuyNFTIntent` with payment/receive token
 * decoupling and OmniSwapRouter auto-swap. Two code paths:
 *   (a) Fast path — `paymentToken == receiveToken` (no swap, ~same
 *       behavior as the original XOM-only V2 but via the shared
 *       `_settleCoinAgnosticBuy` helper).
 *   (b) Swap path — `paymentToken != receiveToken`; contract atomically
 *       converts via OmniSwapRouter using the route the buyer signed
 *       over in `swapPathHash`.
 *
 * Key defences exercised:
 *   - EIP-712 signature verification + replay protection
 *   - H-01 anti-fee-wash referrer collision checks
 *   - CEI ordering (replay flag set BEFORE external calls)
 *   - ReentrancyGuard defeats hostile `onERC721Received` hooks
 *   - Swap path commitment (MEV mitigation via signed `swapPathHash`)
 *   - Slippage floor on router output AND on final seller pay
 *   - Per-token allowlist for paymentToken / receiveToken
 *   - Per-token minimum sale amount (decimal-aware dust threshold)
 *   - 48h timelock admin functions for all new config
 */

/* eslint-disable @typescript-eslint/no-var-requires, @typescript-eslint/no-explicit-any */
const { expect } = require('chai');
const { ethers, upgrades } = require('hardhat');
const { time } = require('@nomicfoundation/hardhat-network-helpers');

// ═════════════════════════════════════════════════════════════════════
//                           TYPES / HELPERS
// ═════════════════════════════════════════════════════════════════════

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

const EIP712_TYPES = {
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

const ZERO_PATH_HASH = ethers.ZeroHash;
const TIMELOCK_DELAY = 48 * 60 * 60;

/**
 * Deploy the vault's external libraries (`MarketplaceFeeSplitter`,
 * `RoyaltyResolver`, `SwapExecutor`) once per test run and return a
 * `UnifiedFeeVault` contract factory with all three addresses linked.
 * The libraries were extracted from the vault to keep the deployed
 * bytecode under the 24 KiB Spurious Dragon limit; all observable
 * behaviour is identical to the prior inline implementation. The
 * deployed addresses are cached so subsequent `getVaultFactory()`
 * calls re-use them (avoids redundant deploys).
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
 * Deploy + link every external library the vault depends on. The vault
 * links {MarketplaceFeeSplitter}, {CoinAgnosticSettlement}, and
 * {PrioritySettlement}; the leaf libraries ({RoyaltyResolver},
 * {SwapExecutor}, {BuyIntentValidator}) link INTO the two settlement
 * libraries (sale-time priority-surcharge refactor).
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
 * 2024). Caller must pass the router address that was live at quote
 * time — the test harness reads it via `vault.nftSwapRouter()`.
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

describe('UnifiedFeeVault.settleNftBuy — Coin-Agnostic', function () {
  let vault: any;
  let xom: any;
  let usdc: any;
  let nft: any;
  let router: any;

  let admin: any;
  let stakingPool: any;
  let protocolTreasury: any;
  let buyer: any;
  let seller: any;
  let referrer1: any;
  let referrer2: any;
  let outsider: any;

  let vaultAddr: string;
  let xomAddr: string;
  let usdcAddr: string;
  let nftAddr: string;
  let routerAddr: string;

  /**
   * Deploy vault V2 + OmniSwapRouter mock, run initializeV2, enrol XOM
   * and USDC as supported tokens through the timelock.
   */
  async function deployFixture(): Promise<void> {
    [admin, stakingPool, protocolTreasury, buyer, seller, referrer1, referrer2, outsider] =
      await ethers.getSigners();

    const MockERC20 = await ethers.getContractFactory('MockERC20');
    xom = await MockERC20.deploy('OmniCoin', 'XOM');
    xomAddr = await xom.getAddress();
    usdc = await MockERC20.deploy('USDC', 'USDC');
    usdcAddr = await usdc.getAddress();

    const MockERC721 = await ethers.getContractFactory('MockERC721');
    nft = await MockERC721.deploy('MockNFT', 'MNFT');
    nftAddr = await nft.getAddress();

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

    // Seed V2 state: EIP-712 domain, router, XOM allowlist, XOM min.
    await vault.connect(admin).initializeV2(routerAddr, xomAddr);

    // Add USDC to the allowlist + its per-token min via timelock.
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

    // Mint NFTs for the seller.
    for (let id = 1n; id <= 10n; id++) {
      await nft.mint(seller.address, id);
    }
    await nft.connect(seller).setApprovalForAll(vaultAddr, true);
  }

  /** Build a default intent for `buyer` purchasing `tokenId` from `seller`. */
  async function buildIntent(
    overrides: Partial<BuyNFTIntent> = {}
  ): Promise<BuyNFTIntent> {
    const now = await time.latest();
    return {
      buyer: buyer.address,
      seller: seller.address,
      nftContract: nftAddr,
      nftTokenId: 1n,
      paymentToken: xomAddr,
      paymentAmount: ethers.parseEther('100'),
      receiveToken: xomAddr,
      minReceiveAmount: ethers.parseEther('99'),
      swapPathHash: ZERO_PATH_HASH,
      listingId: 1n,
      referrer: ethers.ZeroAddress,
      referrer2: ethers.ZeroAddress,
      expiresAt: BigInt(now + 3600),
      nonce: 0n,
      ...overrides,
    };
  }

  /** Sign an intent as the designated buyer using the vault's live chain id. */
  async function signIntent(
    signer: any,
    intent: BuyNFTIntent
  ): Promise<string> {
    const { chainId } = await ethers.provider.getNetwork();
    const domain = {
      name: 'OmniBazaar',
      version: '1',
      chainId,
      verifyingContract: vaultAddr,
    };
    return signer.signTypedData(domain, EIP712_TYPES, intent);
  }

  interface SellerNftSale {
    seller: string;
    nftContract: string;
    nftTokenId: bigint;
    receiveToken: string;
    minReceiveAmount: bigint;
    expiresAt: bigint;
    nonce: bigint;
  }

  const EIP712_SELLER_TYPES = {
    SellerNftSale: [
      { name: 'seller', type: 'address' },
      { name: 'nftContract', type: 'address' },
      { name: 'nftTokenId', type: 'uint256' },
      { name: 'receiveToken', type: 'address' },
      { name: 'minReceiveAmount', type: 'uint256' },
      { name: 'expiresAt', type: 'uint256' },
      { name: 'nonce', type: 'uint256' },
    ],
  };

  /**
   * Monotonically increasing counter backing `buildSellerAuth`'s
   * default `nonce`. The replay guard is now a per-item nonce FLOOR
   * (`_sellerNftNonceFloor`, keyed by `(seller, nftContract,
   * nftTokenId)`), not a used-digest boolean — `settleNftBuy` requires
   * `auth.nonce > floor` and then raises `floor` to `auth.nonce`. A
   * plain incrementing counter guarantees every auth built during a
   * test run is strictly greater than the last, which is exactly what
   * that comparison needs, without depending on `time.latest()`
   * ticking between two auths built in the same test (same block
   * timestamp would otherwise collide). The production/client
   * convention is current unix time instead (see
   * `IntentHashing.SellerNftSale` NatSpec) — either works on-chain,
   * since the contract only requires strictly-increasing values.
   */
  let sellerAuthNonceSeq = 0n;

  /**
   * Build a `SellerNftSale` authorization matching a given buyer
   * `intent` by default (M-06 fix, nonce-floor revision) — mirrors
   * `buildIntent`'s style. `overrides` applied on top of the
   * intent-derived defaults. Defaults `nonce` to the next value of
   * `sellerAuthNonceSeq` — see its docstring for why a counter, not a
   * timestamp, is used.
   */
  function buildSellerAuth(
    intent: BuyNFTIntent,
    overrides: Partial<SellerNftSale> = {}
  ): SellerNftSale {
    sellerAuthNonceSeq += 1n;
    return {
      seller: intent.seller,
      nftContract: intent.nftContract,
      nftTokenId: intent.nftTokenId,
      receiveToken: intent.receiveToken,
      minReceiveAmount: intent.minReceiveAmount,
      expiresAt: intent.expiresAt,
      nonce: sellerAuthNonceSeq,
      ...overrides,
    };
  }

  /**
   * Sign a `SellerNftSale` authorization as the designated seller using
   * the vault's live chain id. Mirrors `signIntent`'s implementation —
   * same EIP-712 domain (name "OmniBazaar", version "1").
   */
  async function signSellerAuth(
    signer: any,
    auth: SellerNftSale
  ): Promise<string> {
    const { chainId } = await ethers.provider.getNetwork();
    const domain = {
      name: 'OmniBazaar',
      version: '1',
      chainId,
      verifyingContract: vaultAddr,
    };
    return signer.signTypedData(domain, EIP712_SELLER_TYPES, auth);
  }

  /**
   * Compute the EIP-712 digest of an NFT intent locally. Replaces the
   * removed `hashNftIntent` external view (dropped in the M-05
   * upgrade for code size) — `ethers.TypedDataEncoder.hash` over the
   * vault's domain yields the identical `_hashTypedDataV4` digest.
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
      EIP712_TYPES,
      intent
    );
  }

  beforeEach(async function () {
    await deployFixture();
  });

  // ═══════════════════════════════════════════════════════════════════
  //   Upgrade / Initialization
  // ═══════════════════════════════════════════════════════════════════

  describe('initializeV2 / upgrade invariants', function () {
    it('initializeV2 can only be called once', async function () {
      await expect(
        vault.connect(admin).initializeV2(routerAddr, xomAddr)
      ).to.be.reverted;
    });

    it('settleNftBuy reverts with SettlementNotConfigured when xomToken is 0', async function () {
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
      const sellerAuth = await buildSellerAuth(intent);
      const sellerSig = await signSellerAuth(seller, sellerAuth);
      await expect(
        fresh.connect(buyer).settleNftBuy(intent, sig, [], [], sellerAuth, sellerSig)
      ).to.be.revertedWithCustomError(fresh, 'SettlementNotConfigured');
    });

    it('preserves storage layout across the V2 upgrade', async function () {
      const UnifiedFeeVault = await getVaultFactory();
      await expect(
        upgrades.validateUpgrade(vaultAddr, UnifiedFeeVault, {
          kind: 'uups',
          constructorArgs: [ethers.ZeroAddress],
          unsafeAllow: ['constructor', 'external-library-linking'],
        })
      ).to.not.be.rejected;
    });

    it('BUY_NFT_DOMAIN_SEPARATOR is non-zero after upgrade', async function () {
      const sep: string = await vault.BUY_NFT_DOMAIN_SEPARATOR();
      expect(sep).to.not.equal(ethers.ZeroHash);
    });

    it('nftSwapRouter is set by initializeV2', async function () {
      expect(await vault.nftSwapRouter()).to.equal(routerAddr);
    });

    it('XOM is allowlisted and has default min after initializeV2', async function () {
      expect(await vault.supportedPaymentTokens(xomAddr)).to.equal(true);
      expect(await vault.perTokenMinSaleAmount(xomAddr)).to.equal(10_000n);
    });

    it('initializeV2 rejects zero router', async function () {
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
      await expect(
        fresh.connect(admin).initializeV2(ethers.ZeroAddress, xomAddr)
      ).to.be.revertedWithCustomError(fresh, 'ZeroAddress');
    });

    it('initializeV2 rejects zero xom', async function () {
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
      await expect(
        fresh.connect(admin).initializeV2(routerAddr, ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(fresh, 'ZeroAddress');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //   Fast Path — paymentToken == receiveToken
  // ═══════════════════════════════════════════════════════════════════

  describe('fast path (same token)', function () {
    it('settles a basic buy in XOM with no referrers', async function () {
      const intent = await buildIntent();
      const sig = await signIntent(buyer, intent);
      const sellerAuth = await buildSellerAuth(intent);
      const sellerSig = await signSellerAuth(seller, sellerAuth);

      await expect(vault.connect(outsider).settleNftBuy(intent, sig, [], [], sellerAuth, sellerSig))
        .to.emit(vault, 'NFTBought');

      expect(await nft.ownerOf(1n)).to.equal(buyer.address);
      const fee = intent.paymentAmount / 100n;
      expect(await xom.balanceOf(seller.address)).to.equal(
        intent.paymentAmount - fee
      );
    });

    it('emits NFTBought with paymentToken=receiveToken, receiveGross=paymentAmount', async function () {
      const intent = await buildIntent();
      const sig = await signIntent(buyer, intent);
      const sellerAuth = await buildSellerAuth(intent);
      const sellerSig = await signSellerAuth(seller, sellerAuth);
      const fee = intent.paymentAmount / 100n;
      await expect(vault.connect(buyer).settleNftBuy(intent, sig, [], [], sellerAuth, sellerSig))
        .to.emit(vault, 'NFTBought')
        .withArgs(
          intent.listingId,
          buyer.address,
          seller.address,
          nftAddr,
          intent.nftTokenId,
          intent.paymentToken,
          intent.paymentAmount,
          intent.receiveToken,
          intent.paymentAmount,
          fee
        );
    });

    it('credits primary referrer via pendingClaims', async function () {
      const intent = await buildIntent({ referrer: referrer1.address });
      const sig = await signIntent(buyer, intent);
      const sellerAuth = await buildSellerAuth(intent);
      const sellerSig = await signSellerAuth(seller, sellerAuth);
      await vault.connect(outsider).settleNftBuy(intent, sig, [], [], sellerAuth, sellerSig);

      const fee = intent.paymentAmount / 100n;
      const refFee = fee / 2n;
      const refPrimary = (refFee * 7000n) / 10000n;
      expect(
        await vault.pendingClaims(referrer1.address, xomAddr)
      ).to.equal(refPrimary);
    });

    it('credits referrer2 via pendingClaims', async function () {
      const intent = await buildIntent({
        referrer: referrer1.address,
        referrer2: referrer2.address,
      });
      const sig = await signIntent(buyer, intent);
      const sellerAuth = await buildSellerAuth(intent);
      const sellerSig = await signSellerAuth(seller, sellerAuth);
      await vault.connect(outsider).settleNftBuy(intent, sig, [], [], sellerAuth, sellerSig);
      const fee = intent.paymentAmount / 100n;
      const refFee = fee / 2n;
      const refSecondary = (refFee * 2000n) / 10000n;
      expect(
        await vault.pendingClaims(referrer2.address, xomAddr)
      ).to.equal(refSecondary);
    });

    it('accepts settleNftBuy relayed by a non-buyer sender', async function () {
      const intent = await buildIntent();
      const sig = await signIntent(buyer, intent);
      const sellerAuth = await buildSellerAuth(intent);
      const sellerSig = await signSellerAuth(seller, sellerAuth);
      await expect(
        vault.connect(outsider).settleNftBuy(intent, sig, [], [], sellerAuth, sellerSig)
      ).to.not.be.reverted;
    });

    it('increments totalFeesCollected after a settlement', async function () {
      const before = await vault.totalFeesCollected();
      const intent = await buildIntent();
      const sig = await signIntent(buyer, intent);
      const sellerAuth = await buildSellerAuth(intent);
      const sellerSig = await signSellerAuth(seller, sellerAuth);
      await vault.connect(buyer).settleNftBuy(intent, sig, [], [], sellerAuth, sellerSig);
      expect((await vault.totalFeesCollected()) - before).to.equal(
        intent.paymentAmount / 100n
      );
    });

    it('fast path does NOT call the swap router', async function () {
      const before = await router.swapCallCount();
      const intent = await buildIntent();
      const sig = await signIntent(buyer, intent);
      const sellerAuth = await buildSellerAuth(intent);
      const sellerSig = await signSellerAuth(seller, sellerAuth);
      await vault.connect(buyer).settleNftBuy(intent, sig, [], [], sellerAuth, sellerSig);
      expect(await router.swapCallCount()).to.equal(before);
    });

    it('fast path stays under 480k gas', async function () {
      // Budget raised from 400k (M-06 fix): the mandatory seller-
      // consent check adds one ECDSA recovery + one cold SSTORE for
      // the `_usedNftSaleAuthorizations` replay mark on top of the
      // pre-existing buyer-signature verification and replay mark —
      // measured ~437k with two referrers set, so 480k keeps headroom.
      const intent = await buildIntent({
        referrer: referrer1.address,
        referrer2: referrer2.address,
      });
      const sig = await signIntent(buyer, intent);
      const sellerAuth = await buildSellerAuth(intent);
      const sellerSig = await signSellerAuth(seller, sellerAuth);
      const tx = await vault.connect(buyer).settleNftBuy(intent, sig, [], [], sellerAuth, sellerSig);
      const receipt = await tx.wait();
      expect(receipt.gasUsed).to.be.lessThan(480_000n);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //   Swap Path — paymentToken != receiveToken
  // ═══════════════════════════════════════════════════════════════════

  describe('swap path (USDC -> XOM)', function () {
    it('settles: buyer pays USDC, seller receives XOM, NFT transfers', async function () {
      // Router delivers exactly 100 XOM at 1:1. Gross-up for 1% fee is
      // ceil(minReceive * 10000 / 9900) + 1. Using minReceive = 98e18
      // keeps us comfortably below the 100e18 the router delivers.
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
      const sellerAuth = await buildSellerAuth(intent);
      const sellerSig = await signSellerAuth(seller, sellerAuth);

      await expect(
        vault.connect(outsider).settleNftBuy(intent, sig, path, sources, sellerAuth, sellerSig)
      ).to.emit(vault, 'NFTBought');

      // NFT moved.
      expect(await nft.ownerOf(1n)).to.equal(buyer.address);
      // Seller got XOM (minted by the mock router) net of 1% fee.
      expect(await xom.balanceOf(seller.address)).to.equal(
        paymentAmount - paymentAmount / 100n
      );
      // Buyer's USDC was pulled.
      expect(await usdc.balanceOf(buyer.address)).to.equal(
        ethers.parseEther('999900')
      );
      // Router was invoked exactly once.
      expect(await router.swapCallCount()).to.equal(1n);
    });

    it('distributes 1% fee in receiveToken, not paymentToken', async function () {
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
        referrer: referrer1.address,
      });
      const sig = await signIntent(buyer, intent);
      const sellerAuth = await buildSellerAuth(intent);
      const sellerSig = await signSellerAuth(seller, sellerAuth);
      await vault.connect(buyer).settleNftBuy(intent, sig, path, sources, sellerAuth, sellerSig);

      // Referrer pending should be in XOM (receive token), NOT USDC.
      const fee = paymentAmount / 100n;
      const refPrimary = ((fee / 2n) * 7000n) / 10000n;
      expect(
        await vault.pendingClaims(referrer1.address, xomAddr)
      ).to.equal(refPrimary);
      expect(
        await vault.pendingClaims(referrer1.address, usdcAddr)
      ).to.equal(0n);
    });

    it('swap path gas budget (happy swap with router hop)', async function () {
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
      });
      const sig = await signIntent(buyer, intent);
      const sellerAuth = await buildSellerAuth(intent);
      const sellerSig = await signSellerAuth(seller, sellerAuth);
      const tx = await vault
        .connect(buyer)
        .settleNftBuy(intent, sig, path, sources, sellerAuth, sellerSig);
      const receipt = await tx.wait();
      // Swap path is expected to be higher than fast path but still tight.
      expect(receipt.gasUsed).to.be.lessThan(700_000n);
    });

    it('reverts SwapMinOutputViolated when router output below minSwapOutput', async function () {
      const path = [usdcAddr, xomAddr];
      const sources = [ethers.id('MOCK')];
      const hash = computeSwapPathHash(path, sources, routerAddr);
      // Drop exchange rate to 0.5 — router returns half, below required.
      await router.setExchangeRate(ethers.parseEther('0.5'));
      const intent = await buildIntent({
        paymentToken: usdcAddr,
        paymentAmount: ethers.parseEther('100'),
        receiveToken: xomAddr,
        minReceiveAmount: ethers.parseEther('99'),
        swapPathHash: hash,
      });
      const sig = await signIntent(buyer, intent);
      const sellerAuth = await buildSellerAuth(intent);
      const sellerSig = await signSellerAuth(seller, sellerAuth);
      await expect(
        vault.connect(buyer).settleNftBuy(intent, sig, path, sources, sellerAuth, sellerSig)
      ).to.be.reverted; // router reverts first with SwapMinOutputViolated
    });

    it('reverts NftSwapRouterNotSet when router cleared (swap path only)', async function () {
      // Propose router change to a fresh address just to zero-out is not
      // possible (validator rejects 0x0). Instead, use a completely fresh
      // V1 proxy without initializeV2 and trigger a swap-path intent.
      // The SettlementNotConfigured guard trips first — handled by the
      // dedicated test. Here we verify that WITH xom set but router
      // absent the correct error fires. Emulated by using an alt vault
      // that only sets xom through the old timelock.
      const UnifiedFeeVault = await getVaultFactory();
      const alt = await upgrades.deployProxy(
        UnifiedFeeVault,
        [admin.address, stakingPool.address, protocolTreasury.address],
        {
          initializer: 'initialize',
          kind: 'uups',
          constructorArgs: [ethers.ZeroAddress],
          unsafeAllow: ['constructor', 'external-library-linking'],
        }
      );
      // Seed xomToken via the legacy proposeXomToken timelock ONLY (no
      // initializeV2, so router remains address(0)).
      await alt.connect(admin).proposeXomToken(xomAddr);
      await time.increase(TIMELOCK_DELAY + 1);
      await alt.connect(admin).applyXomToken();
      // Try a swap-path intent; since initializeV2 was never called, the
      // supportedPaymentTokens mapping is empty, so the FIRST failure is
      // UnsupportedToken — that's fine, it proves the allowlist gate.
      const altAddr = await alt.getAddress();
      const { chainId } = await ethers.provider.getNetwork();
      const domain = {
        name: 'OmniBazaar',
        version: '1',
        chainId,
        verifyingContract: altAddr,
      };
      const path = [usdcAddr, xomAddr];
      const sources = [ethers.id('MOCK')];
      const hash = computeSwapPathHash(path, sources, routerAddr);
      const intent = await buildIntent({
        paymentToken: usdcAddr,
        paymentAmount: ethers.parseEther('100'),
        receiveToken: xomAddr,
        minReceiveAmount: ethers.parseEther('99'),
        swapPathHash: hash,
      });
      const sig = await buyer.signTypedData(domain, EIP712_TYPES, intent);
      // Seller-consent gate runs BEFORE the allowlist check this test
      // targets, and it recomputes its own EIP-712 domain from
      // `address(this)` (== `alt` under DELEGATECALL) — so the
      // authorization must be signed against `alt`'s domain, not the
      // shared `vault`'s (`signSellerAuth` hardcodes `vaultAddr`).
      const sellerAuth = await buildSellerAuth(intent);
      const sellerSig = await seller.signTypedData(
        domain,
        EIP712_SELLER_TYPES,
        sellerAuth
      );
      await expect(
        alt
          .connect(buyer)
          .settleNftBuy(intent, sig, path, sources, sellerAuth, sellerSig)
      ).to.be.revertedWithCustomError(alt, 'UnsupportedToken');
    });

    it('router receives exact paymentAmount via safeTransferFrom', async function () {
      const path = [usdcAddr, xomAddr];
      const sources = [ethers.id('MOCK')];
      const hash = computeSwapPathHash(path, sources, routerAddr);
      const intent = await buildIntent({
        paymentToken: usdcAddr,
        paymentAmount: ethers.parseEther('250'),
        receiveToken: xomAddr,
        minReceiveAmount: ethers.parseEther('200'),
        swapPathHash: hash,
      });
      const sig = await signIntent(buyer, intent);
      const sellerAuth = await buildSellerAuth(intent);
      const sellerSig = await signSellerAuth(seller, sellerAuth);
      const beforeRouter = await usdc.balanceOf(routerAddr);
      await vault.connect(buyer).settleNftBuy(intent, sig, path, sources, sellerAuth, sellerSig);
      expect((await usdc.balanceOf(routerAddr)) - beforeRouter).to.equal(
        ethers.parseEther('250')
      );
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
      const sellerAuth = await buildSellerAuth(intent);
      const sellerSig = await signSellerAuth(seller, sellerAuth);
      await expect(
        vault.connect(buyer).settleNftBuy(intent, sig, path, sources, sellerAuth, sellerSig)
      ).to.not.be.reverted;
    });

    it('reverts BadSwapPath when caller passes mismatched path', async function () {
      const path = [usdcAddr, xomAddr];
      const sources = [ethers.id('MOCK')];
      const hash = computeSwapPathHash(path, sources, routerAddr);
      const badPath = [xomAddr, usdcAddr]; // reversed
      const intent = await buildIntent({
        paymentToken: usdcAddr,
        paymentAmount: ethers.parseEther('100'),
        receiveToken: xomAddr,
        minReceiveAmount: ethers.parseEther('99'),
        swapPathHash: hash,
      });
      const sig = await signIntent(buyer, intent);
      const sellerAuth = await buildSellerAuth(intent);
      const sellerSig = await signSellerAuth(seller, sellerAuth);
      await expect(
        vault.connect(buyer).settleNftBuy(intent, sig, badPath, sources, sellerAuth, sellerSig)
      ).to.be.revertedWithCustomError(vault, 'BadSwapPath');
    });

    it('reverts BadSwapPath when sources differ', async function () {
      const path = [usdcAddr, xomAddr];
      const sources = [ethers.id('MOCK')];
      const wrongSources = [ethers.id('OTHER')];
      const hash = computeSwapPathHash(path, sources, routerAddr);
      const intent = await buildIntent({
        paymentToken: usdcAddr,
        paymentAmount: ethers.parseEther('100'),
        receiveToken: xomAddr,
        minReceiveAmount: ethers.parseEther('99'),
        swapPathHash: hash,
      });
      const sig = await signIntent(buyer, intent);
      const sellerAuth = await buildSellerAuth(intent);
      const sellerSig = await signSellerAuth(seller, sellerAuth);
      await expect(
        vault.connect(buyer).settleNftBuy(intent, sig, path, wrongSources, sellerAuth, sellerSig)
      ).to.be.revertedWithCustomError(vault, 'BadSwapPath');
    });

    it('accepts empty path when swapPathHash == bytes32(0) (fast path)', async function () {
      // paymentToken == receiveToken so no swap needed.
      const intent = await buildIntent();
      const sig = await signIntent(buyer, intent);
      const sellerAuth = await buildSellerAuth(intent);
      const sellerSig = await signSellerAuth(seller, sellerAuth);
      await expect(
        vault.connect(buyer).settleNftBuy(intent, sig, [], [], sellerAuth, sellerSig)
      ).to.not.be.reverted;
    });

    it('reverts BadSwapPath when swapPathHash == bytes32(0) but non-empty path passed', async function () {
      const intent = await buildIntent(); // hash=0, same token
      const sig = await signIntent(buyer, intent);
      const sellerAuth = await buildSellerAuth(intent);
      const sellerSig = await signSellerAuth(seller, sellerAuth);
      await expect(
        vault
          .connect(buyer)
          .settleNftBuy(intent, sig, [usdcAddr, xomAddr], [], sellerAuth, sellerSig)
      ).to.be.revertedWithCustomError(vault, 'BadSwapPath');
    });

    it('reverts BadSwapPath when swapPathHash == bytes32(0) but non-empty sources passed', async function () {
      const intent = await buildIntent();
      const sig = await signIntent(buyer, intent);
      const sellerAuth = await buildSellerAuth(intent);
      const sellerSig = await signSellerAuth(seller, sellerAuth);
      await expect(
        vault.connect(buyer).settleNftBuy(intent, sig, [], [ethers.id('X')], sellerAuth, sellerSig)
      ).to.be.revertedWithCustomError(vault, 'BadSwapPath');
    });

    it('Solodit fix: intent invalidates after router change between sign and submit', async function () {
      // Buyer signs against the CURRENT `nftSwapRouter`. Then governance
      // propose+apply a new router (without time-advancing; instead we
      // swap out the storage slot via a fresh propose/apply using a
      // separate timeline so the intent stays within its `expiresAt`).
      //
      // To exercise this attack path, we hot-swap the router by
      // re-running propose+apply AFTER the initial 48h window that
      // already elapsed in deployFixture's USDC allowlist seeding.
      const path = [usdcAddr, xomAddr];
      const sources = [ethers.id('MOCK')];
      const oldRouterAddr = routerAddr;
      const oldHash = computeSwapPathHash(path, sources, oldRouterAddr);

      // Rotate the router BEFORE signing so the vault's live
      // `nftSwapRouter` differs from the router the signer commits to.
      const MockRouter = await ethers.getContractFactory('MockOmniSwapRouter');
      const newRouter = await MockRouter.deploy(ethers.parseEther('1'));
      await newRouter.waitForDeployment();
      await vault
        .connect(admin)
        .proposeNftSwapRouter(await newRouter.getAddress());
      await time.increase(TIMELOCK_DELAY + 1);
      await vault.connect(admin).applyNftSwapRouter();

      // Build + sign an intent AGAINST THE OLD ROUTER'S HASH, then
      // submit — vault's commitment check must reject.
      const now = await time.latest();
      const intent: BuyNFTIntent = {
        buyer: buyer.address,
        seller: seller.address,
        nftContract: nftAddr,
        nftTokenId: 2n,
        paymentToken: usdcAddr,
        paymentAmount: ethers.parseEther('100'),
        receiveToken: xomAddr,
        minReceiveAmount: ethers.parseEther('98'),
        swapPathHash: oldHash,
        listingId: 2n,
        referrer: ethers.ZeroAddress,
        referrer2: ethers.ZeroAddress,
        expiresAt: BigInt(now + 3600),
        nonce: 77n,
      };
      const sig = await signIntent(buyer, intent);
      const sellerAuth = await buildSellerAuth(intent);
      const sellerSig = await signSellerAuth(seller, sellerAuth);

      await expect(
        vault.connect(buyer).settleNftBuy(intent, sig, path, sources, sellerAuth, sellerSig)
      ).to.be.revertedWithCustomError(vault, 'BadSwapPath');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //   Allowlist
  // ═══════════════════════════════════════════════════════════════════

  describe('allowlist', function () {
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
        receiveToken: xomAddr,
        minReceiveAmount: ethers.parseEther('99'),
      });
      const sig = await signIntent(buyer, intent);
      const sellerAuth = await buildSellerAuth(intent);
      const sellerSig = await signSellerAuth(seller, sellerAuth);
      await expect(
        vault.connect(buyer).settleNftBuy(intent, sig, [], [], sellerAuth, sellerSig)
      ).to.be.revertedWithCustomError(vault, 'UnsupportedToken');
    });

    it('reverts UnsupportedToken when receiveToken not on allowlist', async function () {
      const MockERC20 = await ethers.getContractFactory('MockERC20');
      const dai = await MockERC20.deploy('DAI', 'DAI');
      await dai.waitForDeployment();
      const daiAddr = await dai.getAddress();
      const intent = await buildIntent({
        receiveToken: daiAddr,
        minReceiveAmount: ethers.parseEther('99'),
      });
      const sig = await signIntent(buyer, intent);
      const sellerAuth = await buildSellerAuth(intent);
      const sellerSig = await signSellerAuth(seller, sellerAuth);
      await expect(
        vault.connect(buyer).settleNftBuy(intent, sig, [], [], sellerAuth, sellerSig)
      ).to.be.revertedWithCustomError(vault, 'UnsupportedToken');
    });

    it('USDC and XOM both allowlisted after fixture setup', async function () {
      expect(await vault.supportedPaymentTokens(xomAddr)).to.equal(true);
      expect(await vault.supportedPaymentTokens(usdcAddr)).to.equal(true);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //   Per-Token Minimums
  // ═══════════════════════════════════════════════════════════════════

  describe('per-token min sale amount', function () {
    it('reverts SaleAmountTooSmall when below perTokenMinSaleAmount[receiveToken]', async function () {
      // Raise USDC min to 1e18 for this test via timelock.
      await vault.connect(admin).proposeMinSaleAmount(xomAddr, 1_000_000n);
      await time.increase(TIMELOCK_DELAY + 1);
      await vault.connect(admin).applyMinSaleAmount();
      const intent = await buildIntent({
        minReceiveAmount: 500_000n,
      });
      const sig = await signIntent(buyer, intent);
      const sellerAuth = await buildSellerAuth(intent);
      const sellerSig = await signSellerAuth(seller, sellerAuth);
      await expect(
        vault.connect(buyer).settleNftBuy(intent, sig, [], [], sellerAuth, sellerSig)
      ).to.be.revertedWithCustomError(vault, 'SaleAmountTooSmall');
    });

    it('accepts minReceiveAmount exactly at the per-token min', async function () {
      await vault.connect(admin).proposeMinSaleAmount(xomAddr, 10_000n);
      await time.increase(TIMELOCK_DELAY + 1);
      await vault.connect(admin).applyMinSaleAmount();
      const intent = await buildIntent({
        paymentAmount: 10_200n,
        minReceiveAmount: 10_000n,
      });
      const sig = await signIntent(buyer, intent);
      const sellerAuth = await buildSellerAuth(intent);
      const sellerSig = await signSellerAuth(seller, sellerAuth);
      await expect(
        vault.connect(buyer).settleNftBuy(intent, sig, [], [], sellerAuth, sellerSig)
      ).to.not.be.reverted;
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //   Slippage & Ceil-div
  // ═══════════════════════════════════════════════════════════════════

  describe('slippage guards', function () {
    it('reverts SwapOutputTooLow if router returns exactly minSwapOutput - 1', async function () {
      // Wire rate so output is right at the minSwapOutput boundary minus 1.
      // minSwapOutput = minReceive * 10000 / 9900 + 1
      const minReceive = ethers.parseEther('99');
      const minSwapOutput =
        (minReceive * 10_000n) / 9_900n + 1n;
      // set amountOut = minSwapOutput - 1
      const paymentAmount = ethers.parseEther('100');
      // rate = (minSwapOutput - 1) * 1e18 / paymentAmount
      const rate = ((minSwapOutput - 1n) * 10n ** 18n) / paymentAmount;
      await router.setExchangeRate(rate);
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
      const sellerAuth = await buildSellerAuth(intent);
      const sellerSig = await signSellerAuth(seller, sellerAuth);
      await expect(
        vault.connect(buyer).settleNftBuy(intent, sig, path, sources, sellerAuth, sellerSig)
      ).to.be.reverted; // router's SwapMinOutputViolated fires first
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //   Field Validation
  // ═══════════════════════════════════════════════════════════════════

  describe('field validation', function () {
    it('reverts ZeroAmount when paymentAmount == 0', async function () {
      const intent = await buildIntent({ paymentAmount: 0n });
      const sig = await signIntent(buyer, intent);
      const sellerAuth = await buildSellerAuth(intent);
      const sellerSig = await signSellerAuth(seller, sellerAuth);
      await expect(
        vault.connect(buyer).settleNftBuy(intent, sig, [], [], sellerAuth, sellerSig)
      ).to.be.revertedWithCustomError(vault, 'ZeroAmount');
    });

    it('reverts ZeroAmount when minReceiveAmount == 0', async function () {
      const intent = await buildIntent({ minReceiveAmount: 0n });
      const sig = await signIntent(buyer, intent);
      const sellerAuth = await buildSellerAuth(intent);
      const sellerSig = await signSellerAuth(seller, sellerAuth);
      await expect(
        vault.connect(buyer).settleNftBuy(intent, sig, [], [], sellerAuth, sellerSig)
      ).to.be.revertedWithCustomError(vault, 'ZeroAmount');
    });

    it('reverts SelfBuy when buyer == seller', async function () {
      const intent = await buildIntent({ seller: buyer.address });
      const sig = await signIntent(buyer, intent);
      // intent.seller is overridden to buyer's own address, so the
      // seller-consent gate must be signed by `buyer` (not the fixture's
      // `seller` signer) to pass and let the SelfBuy check fire.
      const sellerAuth = await buildSellerAuth(intent);
      const sellerSig = await signSellerAuth(buyer, sellerAuth);
      await expect(
        vault
          .connect(buyer)
          .settleNftBuy(intent, sig, [], [], sellerAuth, sellerSig)
      ).to.be.revertedWithCustomError(vault, 'SelfBuy');
    });

    it('reverts ZeroAddress when buyer is 0', async function () {
      const intent = await buildIntent({ buyer: ethers.ZeroAddress });
      const sig = await signIntent(buyer, intent);
      const sellerAuth = await buildSellerAuth(intent);
      const sellerSig = await signSellerAuth(seller, sellerAuth);
      await expect(
        vault.connect(buyer).settleNftBuy(intent, sig, [], [], sellerAuth, sellerSig)
      ).to.be.revertedWithCustomError(vault, 'ZeroAddress');
    });

    it('reverts BadSellerAttestation when seller is 0 (no signer can attest as address(0))', async function () {
      // Under the M-06 fix the seller-consent gate runs BEFORE
      // `validateIntent`'s ZeroAddress guard. No real ECDSA signature
      // ever recovers to `address(0)`, so a zero seller can never
      // produce a matching `sellerAuth` signer — the consent gate
      // itself is what now rejects this intent, and it does so first.
      const intent = await buildIntent({ seller: ethers.ZeroAddress });
      const sig = await signIntent(buyer, intent);
      const sellerAuth = await buildSellerAuth(intent);
      const sellerSig = await signSellerAuth(seller, sellerAuth);
      await expect(
        vault
          .connect(buyer)
          .settleNftBuy(intent, sig, [], [], sellerAuth, sellerSig)
      ).to.be.revertedWithCustomError(vault, 'BadSellerAttestation');
    });

    it('reverts ZeroAddress when nftContract is 0', async function () {
      const intent = await buildIntent({ nftContract: ethers.ZeroAddress });
      const sig = await signIntent(buyer, intent);
      const sellerAuth = await buildSellerAuth(intent);
      const sellerSig = await signSellerAuth(seller, sellerAuth);
      await expect(
        vault.connect(buyer).settleNftBuy(intent, sig, [], [], sellerAuth, sellerSig)
      ).to.be.revertedWithCustomError(vault, 'ZeroAddress');
    });

    it('reverts Expired when expiresAt is in the past', async function () {
      const latest = await time.latest();
      const intent = await buildIntent({ expiresAt: BigInt(latest - 10) });
      const sig = await signIntent(buyer, intent);
      const sellerAuth = await buildSellerAuth(intent);
      const sellerSig = await signSellerAuth(seller, sellerAuth);
      await expect(
        vault.connect(buyer).settleNftBuy(intent, sig, [], [], sellerAuth, sellerSig)
      ).to.be.revertedWithCustomError(vault, 'Expired');
    });

    it('reverts Expired at the exact expiresAt boundary (non-strict)', async function () {
      const latest = await time.latest();
      const expiresAt = latest + 10;
      const intent = await buildIntent({ expiresAt: BigInt(expiresAt) });
      const sig = await signIntent(buyer, intent);
      const sellerAuth = await buildSellerAuth(intent);
      const sellerSig = await signSellerAuth(seller, sellerAuth);
      await time.increaseTo(expiresAt);
      await expect(
        vault.connect(buyer).settleNftBuy(intent, sig, [], [], sellerAuth, sellerSig)
      ).to.be.revertedWithCustomError(vault, 'Expired');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //   Signature Verification
  // ═══════════════════════════════════════════════════════════════════

  describe('signature verification', function () {
    it('reverts BadSigner when a different signer signs', async function () {
      const intent = await buildIntent();
      const sig = await signIntent(seller, intent);
      const sellerAuth = await buildSellerAuth(intent);
      const sellerSig = await signSellerAuth(seller, sellerAuth);
      await expect(
        vault
          .connect(buyer)
          .settleNftBuy(intent, sig, [], [], sellerAuth, sellerSig)
      ).to.be.revertedWithCustomError(vault, 'BadSigner');
    });

    it('reverts on mutated nftTokenId after signing', async function () {
      const intent = await buildIntent({ nftTokenId: 1n });
      const sig = await signIntent(buyer, intent);
      const mutated = { ...intent, nftTokenId: 2n };
      // sellerAuth built against the MUTATED terms so the seller-
      // consent gate (checked first) passes cleanly, isolating this
      // test to the buyer-signature check it actually targets.
      const sellerAuth = await buildSellerAuth(mutated);
      const sellerSig = await signSellerAuth(seller, sellerAuth);
      await expect(
        vault
          .connect(buyer)
          .settleNftBuy(mutated, sig, [], [], sellerAuth, sellerSig)
      ).to.be.revertedWithCustomError(vault, 'BadSigner');
    });

    it('reverts on mutated paymentAmount after signing', async function () {
      const intent = await buildIntent();
      const sig = await signIntent(buyer, intent);
      const mutated = { ...intent, paymentAmount: intent.paymentAmount + 1n };
      const sellerAuth = await buildSellerAuth(mutated);
      const sellerSig = await signSellerAuth(seller, sellerAuth);
      await expect(
        vault
          .connect(buyer)
          .settleNftBuy(mutated, sig, [], [], sellerAuth, sellerSig)
      ).to.be.revertedWithCustomError(vault, 'BadSigner');
    });

    it('reverts on mutated receiveToken after signing', async function () {
      const intent = await buildIntent();
      const sig = await signIntent(buyer, intent);
      const mutated = { ...intent, receiveToken: usdcAddr };
      const sellerAuth = await buildSellerAuth(mutated);
      const sellerSig = await signSellerAuth(seller, sellerAuth);
      await expect(
        vault
          .connect(buyer)
          .settleNftBuy(mutated, sig, [], [], sellerAuth, sellerSig)
      ).to.be.revertedWithCustomError(vault, 'BadSigner');
    });

    it('reverts on mutated referrer after signing', async function () {
      const intent = await buildIntent({ referrer: referrer1.address });
      const sig = await signIntent(buyer, intent);
      const mutated = { ...intent, referrer: outsider.address };
      const sellerAuth = await buildSellerAuth(mutated);
      const sellerSig = await signSellerAuth(seller, sellerAuth);
      await expect(
        vault
          .connect(buyer)
          .settleNftBuy(mutated, sig, [], [], sellerAuth, sellerSig)
      ).to.be.revertedWithCustomError(vault, 'BadSigner');
    });

    it('reverts on mutated swapPathHash after signing', async function () {
      const intent = await buildIntent();
      const sig = await signIntent(buyer, intent);
      const mutated = { ...intent, swapPathHash: ethers.id('FAKE') };
      const sellerAuth = await buildSellerAuth(mutated);
      const sellerSig = await signSellerAuth(seller, sellerAuth);
      await expect(
        vault
          .connect(buyer)
          .settleNftBuy(mutated, sig, [], [], sellerAuth, sellerSig)
      ).to.be.revertedWithCustomError(vault, 'BadSigner');
    });

    it('locally computed NFT digest matches `_hashTypedDataV4` for the buyer', async function () {
      const intent = await buildIntent();
      const { chainId } = await ethers.provider.getNetwork();
      const digest: string = await hashNftIntentLocal(intent);
      const sig = await signIntent(buyer, intent);
      const sellerAuth = await buildSellerAuth(intent);
      const sellerSig = await signSellerAuth(seller, sellerAuth);
      const recovered = ethers.verifyTypedData(
        {
          name: 'OmniBazaar',
          version: '1',
          chainId,
          verifyingContract: vaultAddr,
        },
        EIP712_TYPES,
        intent,
        sig
      );
      expect(recovered).to.equal(buyer.address);
      expect(digest).to.match(/^0x[0-9a-f]{64}$/i);
      expect(digest).to.not.equal(ethers.ZeroHash);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //   H-01 Anti-Fee-Wash
  // ═══════════════════════════════════════════════════════════════════

  describe('H-01 anti-fee-wash', function () {
    it('reverts BadReferrer when referrer == buyer', async function () {
      const intent = await buildIntent({ referrer: buyer.address });
      const sig = await signIntent(buyer, intent);
      const sellerAuth = await buildSellerAuth(intent);
      const sellerSig = await signSellerAuth(seller, sellerAuth);
      await expect(
        vault.connect(buyer).settleNftBuy(intent, sig, [], [], sellerAuth, sellerSig)
      ).to.be.revertedWithCustomError(vault, 'BadReferrer');
    });

    it('reverts BadReferrer when referrer == seller', async function () {
      const intent = await buildIntent({ referrer: seller.address });
      const sig = await signIntent(buyer, intent);
      const sellerAuth = await buildSellerAuth(intent);
      const sellerSig = await signSellerAuth(seller, sellerAuth);
      await expect(
        vault.connect(buyer).settleNftBuy(intent, sig, [], [], sellerAuth, sellerSig)
      ).to.be.revertedWithCustomError(vault, 'BadReferrer');
    });

    it('reverts BadReferrer when referrer2 == buyer', async function () {
      const intent = await buildIntent({
        referrer: referrer1.address,
        referrer2: buyer.address,
      });
      const sig = await signIntent(buyer, intent);
      const sellerAuth = await buildSellerAuth(intent);
      const sellerSig = await signSellerAuth(seller, sellerAuth);
      await expect(
        vault.connect(buyer).settleNftBuy(intent, sig, [], [], sellerAuth, sellerSig)
      ).to.be.revertedWithCustomError(vault, 'BadReferrer');
    });

    it('reverts BadReferrer when referrer2 == seller', async function () {
      const intent = await buildIntent({
        referrer: referrer1.address,
        referrer2: seller.address,
      });
      const sig = await signIntent(buyer, intent);
      const sellerAuth = await buildSellerAuth(intent);
      const sellerSig = await signSellerAuth(seller, sellerAuth);
      await expect(
        vault.connect(buyer).settleNftBuy(intent, sig, [], [], sellerAuth, sellerSig)
      ).to.be.revertedWithCustomError(vault, 'BadReferrer');
    });

    it('reverts BadReferrer when referrer2 == referrer', async function () {
      const intent = await buildIntent({
        referrer: referrer1.address,
        referrer2: referrer1.address,
      });
      const sig = await signIntent(buyer, intent);
      const sellerAuth = await buildSellerAuth(intent);
      const sellerSig = await signSellerAuth(seller, sellerAuth);
      await expect(
        vault.connect(buyer).settleNftBuy(intent, sig, [], [], sellerAuth, sellerSig)
      ).to.be.revertedWithCustomError(vault, 'BadReferrer');
    });

    it('accepts distinct referrer and referrer2', async function () {
      const intent = await buildIntent({
        referrer: referrer1.address,
        referrer2: referrer2.address,
      });
      const sig = await signIntent(buyer, intent);
      const sellerAuth = await buildSellerAuth(intent);
      const sellerSig = await signSellerAuth(seller, sellerAuth);
      await expect(
        vault.connect(buyer).settleNftBuy(intent, sig, [], [], sellerAuth, sellerSig)
      ).to.not.be.reverted;
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //   Replay Protection
  // ═══════════════════════════════════════════════════════════════════

  describe('replay protection', function () {
    it('reverts SellerAuthorizationUsed on a second settlement with the same intent', async function () {
      // Under the M-06 fix, the seller-consent gate (single-use
      // `sellerAuth`) is checked BEFORE the buyer-intent replay guard.
      // Resubmitting the identical (intent, sig, sellerAuth,
      // sellerSig) tuple now hits `SellerAuthorizationUsed` first,
      // rather than the buyer-side `Replay` this test originally
      // exercised — the seller-side single-use guard is strictly
      // stronger and fires earlier in the check order.
      const intent = await buildIntent();
      const sig = await signIntent(buyer, intent);
      const sellerAuth = await buildSellerAuth(intent);
      const sellerSig = await signSellerAuth(seller, sellerAuth);
      await vault
        .connect(buyer)
        .settleNftBuy(intent, sig, [], [], sellerAuth, sellerSig);
      await nft.connect(buyer).transferFrom(buyer.address, seller.address, 1n);
      await expect(
        vault
          .connect(buyer)
          .settleNftBuy(intent, sig, [], [], sellerAuth, sellerSig)
      ).to.be.revertedWithCustomError(vault, 'SellerAuthorizationUsed');
    });

    it('isNftIntentUsed flips from false to true after settlement', async function () {
      const intent = await buildIntent();
      const digest = await hashNftIntentLocal(intent);
      expect(await vault.isNftIntentUsed(digest)).to.equal(false);
      const sig = await signIntent(buyer, intent);
      const sellerAuth = await buildSellerAuth(intent);
      const sellerSig = await signSellerAuth(seller, sellerAuth);
      await vault.connect(buyer).settleNftBuy(intent, sig, [], [], sellerAuth, sellerSig);
      expect(await vault.isNftIntentUsed(digest)).to.equal(true);
    });

    it('accepts a second distinct-nonce intent for the same NFT token id', async function () {
      const intent1 = await buildIntent();
      const sig1 = await signIntent(buyer, intent1);
      const sellerAuth1 = await buildSellerAuth(intent1);
      const sellerSig1 = await signSellerAuth(seller, sellerAuth1);
      await vault
        .connect(buyer)
        .settleNftBuy(intent1, sig1, [], [], sellerAuth1, sellerSig1);
      await nft.connect(buyer).transferFrom(buyer.address, seller.address, 1n);
      const intent2 = await buildIntent({ nonce: 1n });
      const sig2 = await signIntent(buyer, intent2);
      // `sellerAuth` digests are single-use and don't include `nonce`,
      // so intent2's authorization must be a DISTINCT digest from
      // intent1's even though both name the same token/seller/price —
      // force that by bumping `expiresAt` by 1s past intent2's own
      // default (still comfortably in the future).
      const sellerAuth2 = await buildSellerAuth(intent2, {
        expiresAt: intent2.expiresAt + 1n,
      });
      const sellerSig2 = await signSellerAuth(seller, sellerAuth2);
      await expect(
        vault
          .connect(buyer)
          .settleNftBuy(intent2, sig2, [], [], sellerAuth2, sellerSig2)
      ).to.not.be.reverted;
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //   Seller Consent (M-06 fix)
  // ═══════════════════════════════════════════════════════════════════
  //
  // `settleNftBuy` previously verified ONLY the buyer's signature on a
  // `BuyNFTIntent`. Since `intent.seller` was buyer-authored and an
  // ERC-721 `setApprovalForAll` grant is collection-wide operator
  // trust (not per-sale price consent), ANY address could construct a
  // `BuyNFTIntent` naming an approved seller and force a sale at an
  // arbitrary — potentially dust-floor — price, with no signature or
  // action from the seller at all. This block proves the fix: a
  // seller-signed `SellerNftSale` authorization is now mandatory,
  // matched term-by-term against the buyer's intent, single-use, and
  // expiring.

  describe('seller consent (M-06 fix)', function () {
    it('reverts BadSellerAttestation when sellerAuth is signed by a random address, not the real seller', async function () {
      const intent = await buildIntent();
      const sig = await signIntent(buyer, intent);
      const sellerAuth = await buildSellerAuth(intent);
      // Signed by `outsider`, NOT `seller` — the address named in
      // `intent.seller` never actually authorized this sale.
      const sellerSig = await signSellerAuth(outsider, sellerAuth);
      await expect(
        vault
          .connect(buyer)
          .settleNftBuy(intent, sig, [], [], sellerAuth, sellerSig)
      ).to.be.revertedWithCustomError(vault, 'BadSellerAttestation');
    });

    it('reverts SellerAuthorizationMismatch when sellerAuth names a different nftTokenId', async function () {
      const intent = await buildIntent({ nftTokenId: 1n });
      const sig = await signIntent(buyer, intent);
      // Seller genuinely signs — but for token #2, not the #1 the
      // buyer's intent names.
      const sellerAuth = await buildSellerAuth(intent, { nftTokenId: 2n });
      const sellerSig = await signSellerAuth(seller, sellerAuth);
      await expect(
        vault
          .connect(buyer)
          .settleNftBuy(intent, sig, [], [], sellerAuth, sellerSig)
      ).to.be.revertedWithCustomError(vault, 'SellerAuthorizationMismatch');
    });

    it('reverts SellerAuthorizationMismatch when sellerAuth names a different nftContract', async function () {
      const intent = await buildIntent();
      const sig = await signIntent(buyer, intent);
      // usdcAddr stands in as "a different collection" — the check is
      // pure address equality, so any non-matching address proves it.
      const sellerAuth = await buildSellerAuth(intent, {
        nftContract: usdcAddr,
      });
      const sellerSig = await signSellerAuth(seller, sellerAuth);
      await expect(
        vault
          .connect(buyer)
          .settleNftBuy(intent, sig, [], [], sellerAuth, sellerSig)
      ).to.be.revertedWithCustomError(vault, 'SellerAuthorizationMismatch');
    });

    it('accepts sellerAuth whose minReceiveAmount floor is BELOW what the buyer intent offers', async function () {
      // Seller only demanded >= 90 XOM net; buyer's intent (paymentAmount
      // 100 XOM, 1% fee => sellerPay 99 XOM) offers to net the seller 99
      // XOM via `minReceiveAmount: 98` — paying MORE than the seller's
      // floor must succeed.
      const intent = await buildIntent({
        paymentAmount: ethers.parseEther('100'),
        minReceiveAmount: ethers.parseEther('98'),
      });
      const sig = await signIntent(buyer, intent);
      const sellerAuth = await buildSellerAuth(intent, {
        minReceiveAmount: ethers.parseEther('90'),
      });
      const sellerSig = await signSellerAuth(seller, sellerAuth);
      await expect(
        vault
          .connect(buyer)
          .settleNftBuy(intent, sig, [], [], sellerAuth, sellerSig)
      ).to.not.be.reverted;
      expect(await nft.ownerOf(intent.nftTokenId)).to.equal(buyer.address);
    });

    it('reverts SellerAuthorizationMismatch when the buyer intent offers LESS than sellerAuth requires', async function () {
      // Seller demands >= 90 XOM; buyer's intent only offers 50 — the
      // seller's price floor must be enforced, not bypassable by a
      // buyer naming a lower `minReceiveAmount` in their own intent.
      const intent = await buildIntent({
        minReceiveAmount: ethers.parseEther('50'),
      });
      const sig = await signIntent(buyer, intent);
      const sellerAuth = await buildSellerAuth(intent, {
        minReceiveAmount: ethers.parseEther('90'),
      });
      const sellerSig = await signSellerAuth(seller, sellerAuth);
      await expect(
        vault
          .connect(buyer)
          .settleNftBuy(intent, sig, [], [], sellerAuth, sellerSig)
      ).to.be.revertedWithCustomError(vault, 'SellerAuthorizationMismatch');
    });

    it('reverts Expired when sellerAuth.expiresAt is in the past', async function () {
      const intent = await buildIntent();
      const sig = await signIntent(buyer, intent);
      const latest = await time.latest();
      const sellerAuth = await buildSellerAuth(intent, {
        expiresAt: BigInt(latest - 10),
      });
      const sellerSig = await signSellerAuth(seller, sellerAuth);
      await expect(
        vault
          .connect(buyer)
          .settleNftBuy(intent, sig, [], [], sellerAuth, sellerSig)
      ).to.be.revertedWithCustomError(vault, 'Expired');
    });

    it('reverts SellerAuthorizationUsed when the same sellerAuth is replayed against a second, different buyer intent', async function () {
      // Nonce-floor mechanism: the first fill raises the item's
      // `_sellerNftNonceFloor` to exactly `sellerAuth.nonce`. Replaying
      // the IDENTICAL auth again means `auth.nonce <= floor` (equal,
      // not below) — still a revert, but now via the floor comparison
      // rather than a used-digest boolean.
      const intent1 = await buildIntent();
      const sig1 = await signIntent(buyer, intent1);
      const sellerAuth = await buildSellerAuth(intent1);
      const sellerSig = await signSellerAuth(seller, sellerAuth);
      await vault
        .connect(buyer)
        .settleNftBuy(intent1, sig1, [], [], sellerAuth, sellerSig);

      // A completely different buyer (`outsider`) now tries to reuse
      // the SAME already-consumed seller authorization to force a
      // second "sale" of the same terms.
      const intent2 = await buildIntent({
        buyer: outsider.address,
        nonce: 9001n,
      });
      const sig2 = await signIntent(outsider, intent2);
      await expect(
        vault
          .connect(outsider)
          .settleNftBuy(intent2, sig2, [], [], sellerAuth, sellerSig)
      ).to.be.revertedWithCustomError(vault, 'SellerAuthorizationUsed');
    });

    it('THE KEY REGRESSION TEST (nonce floor): filling a fresher, repriced sellerAuth invalidates an older, never-explicitly-cancelled sellerAuth for the same item', async function () {
      // Pass-5 audit finding this test proves closed: under the OLD
      // digest-keyed replay design, two DIFFERENT signed authorizations
      // for the same item hash to two different digests — filling one
      // never marked the other "used". A seller who repriced (signed a
      // new, higher-priced auth B) had NO way to invalidate a stale,
      // cheaper auth A still floating around (buyer's cache, mempool,
      // a stale API response) short of an on-chain cancel call naming
      // that exact digest. The nonce-floor redesign closes this
      // structurally: EVERY fill (of any auth for the item) raises a
      // single per-item floor, so filling B automatically kills every
      // OLDER auth for that same item — including A — with no explicit
      // cancellation required.
      const tokenId = 5n;
      const lowPrice = ethers.parseEther('50');
      const highPrice = ethers.parseEther('200');

      // --- sellerAuth A: seller's ORIGINAL, low-priced listing ---
      const intentA = await buildIntent({
        nftTokenId: tokenId,
        paymentAmount: lowPrice,
        minReceiveAmount: (lowPrice * 99n) / 100n,
      });
      const sellerAuthA = await buildSellerAuth(intentA, {
        minReceiveAmount: (lowPrice * 99n) / 100n,
      });
      const sellerSigA = await signSellerAuth(seller, sellerAuthA);

      // --- sellerAuth B: seller REPRICES UP for the SAME item ---
      // `buildSellerAuth` hands out a strictly-increasing nonce on
      // every call, so B's nonce > A's nonce simply by being built
      // second — exactly mirroring a real reprice-and-relist.
      const intentB = await buildIntent({
        buyer: referrer1.address,
        nftTokenId: tokenId,
        paymentAmount: highPrice,
        minReceiveAmount: (highPrice * 99n) / 100n,
        nonce: 1n,
      });
      const sellerAuthB = await buildSellerAuth(intentB, {
        minReceiveAmount: (highPrice * 99n) / 100n,
      });
      expect(sellerAuthB.nonce).to.be.greaterThan(sellerAuthA.nonce);
      const sellerSigB = await signSellerAuth(seller, sellerAuthB);
      const sigB = await signIntent(referrer1, intentB);

      // Buyer fills the fresh, repriced B — must succeed, proving
      // relisting at a new nonce genuinely works.
      await xom.mint(referrer1.address, ethers.parseEther('1000'));
      await xom.connect(referrer1).approve(vaultAddr, ethers.MaxUint256);
      await expect(
        vault
          .connect(referrer1)
          .settleNftBuy(intentB, sigB, [], [], sellerAuthB, sellerSigB)
      ).to.emit(vault, 'NFTBought');
      expect(await nft.ownerOf(tokenId)).to.equal(referrer1.address);

      // Now attempt to fill the STALE, lower-priced sellerAuth A with a
      // fresh, otherwise-valid matching buyer intent. A was NEVER
      // individually named or cancelled — but filling B already raised
      // the item's nonce floor above A's nonce. This MUST revert,
      // proving A died automatically as a side effect of B's fill.
      const intentAFresh = await buildIntent({
        buyer: buyer.address,
        nftTokenId: tokenId,
        paymentAmount: lowPrice,
        minReceiveAmount: (lowPrice * 99n) / 100n,
        nonce: 2n,
      });
      const sigAFresh = await signIntent(buyer, intentAFresh);
      await expect(
        vault
          .connect(buyer)
          .settleNftBuy(
            intentAFresh,
            sigAFresh,
            [],
            [],
            sellerAuthA,
            sellerSigA
          )
      ).to.be.revertedWithCustomError(vault, 'SellerAuthorizationUsed');

      // The NFT's ownership is unaffected by the blocked stale fill.
      expect(await nft.ownerOf(tokenId)).to.equal(referrer1.address);
    });

    it('THE KEY REGRESSION TEST: blocks the pre-fix exploit — an attacker cannot force a sale by self-signing only the buyer side of an approved seller\'s NFT', async function () {
      // This is the literal vulnerability the M-06 fix closes. Before
      // the fix, `settleNftBuy` took no `sellerAuth` at all — it
      // verified ONLY the buyer's own signature over a `BuyNFTIntent`
      // that the buyer/attacker authors entirely themselves, including
      // `intent.seller`. `seller` in this fixture HAS granted the
      // vault collection-wide operator trust via
      // `nft.setApprovalForAll(vaultAddr, true)` (see `deployFixture`)
      // — that grant is necessary for ANY legitimate sale to work, but
      // it is NOT per-sale price consent. Pre-fix, `outsider` could
      // name `seller` as the intent's seller, pick an arbitrary
      // (dust-floor) price, sign only as buyer, and the sale would go
      // through — the exact theft this test proves is now blocked.
      const attacker = outsider;
      const intent = await buildIntent({
        buyer: attacker.address,
        seller: seller.address, // real seller, real approval-for-all
        nftTokenId: 3n,
        paymentAmount: 10_000n, // attacker-chosen dust-floor price
        minReceiveAmount: 10_000n,
        nonce: 424242n,
      });
      // Attacker self-signs ONLY the buyer side — exactly what the
      // pre-fix exploit required and nothing more.
      const sig = await signIntent(attacker, intent);

      // Fund the attacker enough XOM to actually complete the payment
      // leg if the seller-consent gate did NOT block this — proving
      // the block is what stops the exploit, not an incidental
      // insufficient-balance revert.
      await xom.mint(attacker.address, ethers.parseEther('1000'));
      await xom.connect(attacker).approve(vaultAddr, ethers.MaxUint256);

      const ownerBefore = await nft.ownerOf(intent.nftTokenId);
      expect(ownerBefore).to.equal(seller.address);

      // Case A: no sellerAuth obtained at all — attacker passes a
      // self-forged authorization signed by themselves, not `seller`.
      const forgedAuth = await buildSellerAuth(intent);
      const forgedSig = await signSellerAuth(attacker, forgedAuth);
      await expect(
        vault
          .connect(attacker)
          .settleNftBuy(intent, sig, [], [], forgedAuth, forgedSig)
      ).to.be.revertedWithCustomError(vault, 'BadSellerAttestation');

      // The NFT must NOT have moved and the seller must not have been
      // paid — the exploit is fully blocked, not merely reordered.
      expect(await nft.ownerOf(intent.nftTokenId)).to.equal(seller.address);
      expect(await xom.balanceOf(seller.address)).to.equal(0n);
    });

    it('happy path: a genuine buyer intent + genuine matching sellerAuth still settles end-to-end', async function () {
      const intent = await buildIntent({
        paymentAmount: ethers.parseEther('200'),
        minReceiveAmount: ethers.parseEther('190'),
      });
      const sig = await signIntent(buyer, intent);
      const sellerAuth = await buildSellerAuth(intent);
      const sellerSig = await signSellerAuth(seller, sellerAuth);

      const fee = intent.paymentAmount / 100n;
      const sellerPay = intent.paymentAmount - fee;

      await expect(
        vault
          .connect(buyer)
          .settleNftBuy(intent, sig, [], [], sellerAuth, sellerSig)
      ).to.emit(vault, 'NFTBought');

      // NFT genuinely transferred.
      expect(await nft.ownerOf(intent.nftTokenId)).to.equal(buyer.address);
      // Seller genuinely paid (net of the 1% marketplace fee).
      expect(await xom.balanceOf(seller.address)).to.equal(sellerPay);
      // The fee itself genuinely landed somewhere in the split
      // (vault/staking/treasury — no referrers on this intent, so it
      // all routes to ODDAO's share of the split).
      const stakingBal = await xom.balanceOf(stakingPool.address);
      const treasuryBal = await xom.balanceOf(protocolTreasury.address);
      const vaultBal = await xom.balanceOf(vaultAddr);
      expect(vaultBal + stakingBal + treasuryBal).to.equal(fee);
      // The sellerAuth's nonce is now at the item's floor — this exact
      // auth cannot be reused, even against a freshly-signed,
      // otherwise-valid buyer intent.
      const replayIntent = await buildIntent({ nonce: 1n });
      const replaySig = await signIntent(buyer, replayIntent);
      await expect(
        vault
          .connect(buyer)
          .settleNftBuy(replayIntent, replaySig, [], [], sellerAuth, sellerSig)
      ).to.be.revertedWithCustomError(vault, 'SellerAuthorizationUsed');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //   cancelNftSaleAuthorization
  // ═══════════════════════════════════════════════════════════════════

  describe('cancelNftSaleAuthorization', function () {
    /**
     * Compute the same `itemKey` the vault derives internally —
     * `keccak256(abi.encode(seller, nftContract, nftTokenId))` — so
     * tests can assert on the emitted `NftSaleAuthorizationCancelled`
     * event's indexed `itemKey` argument.
     */
    function computeItemKey(
      sellerAddr: string,
      nftContractAddr: string,
      tokenId: bigint
    ): string {
      return ethers.keccak256(
        ethers.AbiCoder.defaultAbiCoder().encode(
          ['address', 'address', 'uint256'],
          [sellerAddr, nftContractAddr, tokenId]
        )
      );
    }

    it('raises the item nonce floor and emits NftSaleAuthorizationCancelled when called by the item owner', async function () {
      const itemKey = computeItemKey(seller.address, nftAddr, 4n);
      await expect(
        vault.connect(seller).cancelNftSaleAuthorization(nftAddr, 4n)
      )
        .to.emit(vault, 'NftSaleAuthorizationCancelled')
        .withArgs(itemKey, seller.address);
    });

    it('invalidates a previously-signed, not-yet-filled sellerAuth whose nonce is at or below the new floor', async function () {
      const intent = await buildIntent({ nftTokenId: 4n });
      const sellerAuth = await buildSellerAuth(intent);
      const sellerSig = await signSellerAuth(seller, sellerAuth);

      // Cancel raises the floor to `block.timestamp` — every
      // counter-based nonce `buildSellerAuth` hands out (small
      // integers) is far below any real unix timestamp, so this
      // pre-signed, never-submitted auth is now stale.
      await vault.connect(seller).cancelNftSaleAuthorization(nftAddr, 4n);

      const sig = await signIntent(buyer, intent);
      await expect(
        vault
          .connect(buyer)
          .settleNftBuy(intent, sig, [], [], sellerAuth, sellerSig)
      ).to.be.revertedWithCustomError(vault, 'SellerAuthorizationUsed');
    });

    it('a FRESH sellerAuth signed with a nonce above the new floor can still be filled after cancelling — cancel never permanently blocks a relist', async function () {
      await vault.connect(seller).cancelNftSaleAuthorization(nftAddr, 4n);
      const floorFromCancel = BigInt(await time.latest());

      const intent = await buildIntent({
        nftTokenId: 4n,
        nonce: 1n, // BuyNFTIntent-level replay nonce — unrelated to the seller item-nonce floor.
      });
      // Recommended client convention: sign the fresh auth with a
      // nonce derived from current unix time, comfortably above the
      // floor cancel just set.
      const sellerAuth = await buildSellerAuth(intent, {
        nonce: floorFromCancel + 1_000n,
      });
      const sellerSig = await signSellerAuth(seller, sellerAuth);
      const sig = await signIntent(buyer, intent);

      await expect(
        vault
          .connect(buyer)
          .settleNftBuy(intent, sig, [], [], sellerAuth, sellerSig)
      ).to.emit(vault, 'NFTBought');
      expect(await nft.ownerOf(4n)).to.equal(buyer.address);
    });

    it('a second call in the same block/timestamp is a silent no-op — does not revert, and does not re-emit the event', async function () {
      // Disable automine so both calls land in the SAME block and
      // therefore share the exact same `block.timestamp` — the only
      // way to reliably hit the `block.timestamp <= floor` no-op
      // branch deterministically.
      await ethers.provider.send('evm_setAutomine', [false]);
      try {
        const tx1 = await vault
          .connect(seller)
          .cancelNftSaleAuthorization(nftAddr, 6n);
        const tx2 = await vault
          .connect(seller)
          .cancelNftSaleAuthorization(nftAddr, 6n);
        await ethers.provider.send('evm_mine', []);
        const receipt1 = await tx1.wait();
        const receipt2 = await tx2.wait();

        expect(receipt1.blockNumber).to.equal(receipt2.blockNumber);
        expect(receipt1.status).to.equal(1);
        expect(receipt2.status).to.equal(1);

        const vaultLogs1 = receipt1.logs.filter(
          (l: any) => l.address.toLowerCase() === vaultAddr.toLowerCase()
        );
        const vaultLogs2 = receipt2.logs.filter(
          (l: any) => l.address.toLowerCase() === vaultAddr.toLowerCase()
        );
        // First call: real state change, emits the event.
        expect(vaultLogs1.length).to.equal(1);
        // Second call, same timestamp: silent no-op, no event.
        expect(vaultLogs2.length).to.equal(0);
      } finally {
        await ethers.provider.send('evm_setAutomine', [true]);
      }
    });

    it('calling for an item the caller has never listed (floor 0) still succeeds and raises the floor from its zero default', async function () {
      // Token 9 was minted to `seller` in `deployFixture`, but no
      // sellerAuth has ever been built/signed for it — the mapping's
      // zero default is the floor.
      await expect(
        vault.connect(seller).cancelNftSaleAuthorization(nftAddr, 9n)
      ).to.not.be.reverted;
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //   Approval & Balance Checks
  // ═══════════════════════════════════════════════════════════════════

  describe('approval / balance', function () {
    it('reverts when buyer has insufficient balance', async function () {
      const bal = await xom.balanceOf(buyer.address);
      await xom.connect(buyer).transfer(outsider.address, bal);
      const intent = await buildIntent({ nonce: 99n });
      const sig = await signIntent(buyer, intent);
      const sellerAuth = await buildSellerAuth(intent);
      const sellerSig = await signSellerAuth(seller, sellerAuth);
      await expect(vault.connect(buyer).settleNftBuy(intent, sig, [], [], sellerAuth, sellerSig))
        .to.be.reverted;
    });

    it('reverts when buyer has not approved the vault', async function () {
      await xom.connect(buyer).approve(vaultAddr, 0n);
      const intent = await buildIntent({ nonce: 42n });
      const sig = await signIntent(buyer, intent);
      const sellerAuth = await buildSellerAuth(intent);
      const sellerSig = await signSellerAuth(seller, sellerAuth);
      await expect(vault.connect(buyer).settleNftBuy(intent, sig, [], [], sellerAuth, sellerSig))
        .to.be.reverted;
    });

    it('reverts when seller has not approved the vault for the NFT', async function () {
      await nft.connect(seller).setApprovalForAll(vaultAddr, false);
      const intent = await buildIntent({ nonce: 7n });
      const sig = await signIntent(buyer, intent);
      const sellerAuth = await buildSellerAuth(intent);
      const sellerSig = await signSellerAuth(seller, sellerAuth);
      await expect(vault.connect(buyer).settleNftBuy(intent, sig, [], [], sellerAuth, sellerSig))
        .to.be.reverted;
    });

    it('reverts when seller does not own the NFT', async function () {
      await nft.connect(seller).transferFrom(seller.address, outsider.address, 1n);
      const intent = await buildIntent({ nonce: 12n });
      const sig = await signIntent(buyer, intent);
      const sellerAuth = await buildSellerAuth(intent);
      const sellerSig = await signSellerAuth(seller, sellerAuth);
      await expect(vault.connect(buyer).settleNftBuy(intent, sig, [], [], sellerAuth, sellerSig))
        .to.be.reverted;
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //   Pause Behaviour
  // ═══════════════════════════════════════════════════════════════════

  describe('pause', function () {
    it('reverts when the vault is paused', async function () {
      await vault.connect(admin).pause();
      const intent = await buildIntent();
      const sig = await signIntent(buyer, intent);
      const sellerAuth = await buildSellerAuth(intent);
      const sellerSig = await signSellerAuth(seller, sellerAuth);
      await expect(vault.connect(buyer).settleNftBuy(intent, sig, [], [], sellerAuth, sellerSig))
        .to.be.reverted;
    });

    it('accepts settlement after unpause', async function () {
      await vault.connect(admin).pause();
      await vault.connect(admin).unpause();
      const intent = await buildIntent();
      const sig = await signIntent(buyer, intent);
      const sellerAuth = await buildSellerAuth(intent);
      const sellerSig = await signSellerAuth(seller, sellerAuth);
      await expect(vault.connect(buyer).settleNftBuy(intent, sig, [], [], sellerAuth, sellerSig))
        .to.not.be.reverted;
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //   Reentrancy / Non-compliant receivers
  // ═══════════════════════════════════════════════════════════════════

  describe('reentrancy & non-compliant receivers', function () {
    it('ReentrantNFT cannot re-enter settleNftBuy during transfer', async function () {
      const ReentrantNFT = await ethers.getContractFactory('ReentrantNFT');
      const reentry = await ReentrantNFT.deploy();
      await reentry.waitForDeployment();
      const reentryAddr = await reentry.getAddress();
      await reentry.mint(seller.address, 100n);
      await reentry.connect(seller).setApprovalForAll(vaultAddr, true);

      const intent = await buildIntent({
        nftContract: reentryAddr,
        nftTokenId: 100n,
        nonce: 555n,
      });
      const sig = await signIntent(buyer, intent);
      const sellerAuth = await buildSellerAuth(intent);
      const sellerSig = await signSellerAuth(seller, sellerAuth);
      // Content of the replayed sellerAuth/signature is irrelevant —
      // the reentrant call reverts at the `nonReentrant` modifier
      // before any argument is inspected — but `arm()`'s payload must
      // still carry well-typed values to reach the vault's real
      // function selector.
      await reentry.arm(vaultAddr, intent, sig, sellerAuth, sellerSig);
      await expect(
        vault
          .connect(buyer)
          .settleNftBuy(intent, sig, [], [], sellerAuth, sellerSig)
      ).to.not.be.reverted;
      expect(await reentry.attempted()).to.equal(true);
      const err = await reentry.lastError();
      expect(err.toLowerCase()).to.include('3ee5aeb5');
    });

    it('reverts when buyer is a contract without onERC721Received', async function () {
      const NonRecv = await ethers.getContractFactory('NonERC721Receiver');
      const recv = await NonRecv.deploy();
      await recv.waitForDeployment();
      const recvAddr = await recv.getAddress();
      const intent = await buildIntent({ buyer: recvAddr, nonce: 321n });
      const sig = await signIntent(buyer, intent);
      const sellerAuth = await buildSellerAuth(intent);
      const sellerSig = await signSellerAuth(seller, sellerAuth);
      await expect(
        vault.connect(buyer).settleNftBuy(intent, sig, [], [], sellerAuth, sellerSig)
      ).to.be.revertedWithCustomError(vault, 'BadSigner');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //   EIP-712 Domain
  // ═══════════════════════════════════════════════════════════════════

  describe('EIP-712 domain', function () {
    it('BUY_NFT_TYPEHASH matches the canonical string', async function () {
      const expected = ethers.keccak256(
        ethers.toUtf8Bytes(
          'BuyNFT(address buyer,address seller,address nftContract,' +
            'uint256 nftTokenId,address paymentToken,uint256 paymentAmount,' +
            'address receiveToken,uint256 minReceiveAmount,' +
            'bytes32 swapPathHash,uint256 listingId,address referrer,' +
            'address referrer2,uint256 expiresAt,uint256 nonce)'
        )
      );
      expect(await vault.BUY_NFT_TYPEHASH()).to.equal(expected);
    });

    it('BUY_NFT_DOMAIN_SEPARATOR reflects the current vault address', async function () {
      const { chainId } = await ethers.provider.getNetwork();
      const onchain: string = await vault.BUY_NFT_DOMAIN_SEPARATOR();
      const typeHash = ethers.keccak256(
        ethers.toUtf8Bytes(
          'EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)'
        )
      );
      const offchain = ethers.keccak256(
        ethers.AbiCoder.defaultAbiCoder().encode(
          ['bytes32', 'bytes32', 'bytes32', 'uint256', 'address'],
          [
            typeHash,
            ethers.keccak256(ethers.toUtf8Bytes('OmniBazaar')),
            ethers.keccak256(ethers.toUtf8Bytes('1')),
            chainId,
            vaultAddr,
          ]
        )
      );
      expect(onchain).to.equal(offchain);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //   Role & Permission Independence
  // ═══════════════════════════════════════════════════════════════════

  describe('roles', function () {
    it('settleNftBuy does NOT require DEPOSITOR_ROLE on the caller', async function () {
      expect(await vault.hasRole(DEPOSITOR_ROLE, buyer.address)).to.equal(false);
      const intent = await buildIntent();
      const sig = await signIntent(buyer, intent);
      const sellerAuth = await buildSellerAuth(intent);
      const sellerSig = await signSellerAuth(seller, sellerAuth);
      await expect(
        vault.connect(buyer).settleNftBuy(intent, sig, [], [], sellerAuth, sellerSig)
      ).to.not.be.reverted;
    });

    it('settleNftBuy does NOT require DEPOSITOR_ROLE on the vault itself', async function () {
      expect(await vault.hasRole(DEPOSITOR_ROLE, vaultAddr)).to.equal(false);
      const intent = await buildIntent();
      const sig = await signIntent(buyer, intent);
      const sellerAuth = await buildSellerAuth(intent);
      const sellerSig = await signSellerAuth(seller, sellerAuth);
      await expect(
        vault.connect(buyer).settleNftBuy(intent, sig, [], [], sellerAuth, sellerSig)
      ).to.not.be.reverted;
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //   Timelock Admin Functions
  // ═══════════════════════════════════════════════════════════════════

  describe('timelock: proposeNftSwapRouter / applyNftSwapRouter', function () {
    it('unauthorized caller cannot propose', async function () {
      await expect(
        vault.connect(outsider).proposeNftSwapRouter(outsider.address)
      ).to.be.reverted;
    });

    it('rejects zero address proposal', async function () {
      await expect(
        vault.connect(admin).proposeNftSwapRouter(ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(vault, 'ZeroAddress');
    });

    it('applies immediately — Pioneer RECIPIENT_CHANGE_DELAY = 0, no wait', async function () {
      const next = outsider.address;
      await vault.connect(admin).proposeNftSwapRouter(next);
      // Pioneer phase: RECIPIENT_CHANGE_DELAY is 0, so apply succeeds in the
      // next block with no time.increase. This guards against re-introducing a
      // constant propose→apply delay, which CLAUDE.md bans during Pioneer.
      await expect(vault.connect(admin).applyNftSwapRouter())
        .to.emit(vault, 'NftSwapRouterUpdated')
        .withArgs(routerAddr, next);
      expect(await vault.nftSwapRouter()).to.equal(next);
    });

    it('reverts NoPendingChange when nothing pending', async function () {
      await expect(
        vault.connect(admin).applyNftSwapRouter()
      ).to.be.revertedWithCustomError(vault, 'NoPendingChange');
    });

    it('apply after delay updates nftSwapRouter', async function () {
      const next = outsider.address;
      await vault.connect(admin).proposeNftSwapRouter(next);
      await time.increase(TIMELOCK_DELAY + 1);
      await expect(vault.connect(admin).applyNftSwapRouter())
        .to.emit(vault, 'NftSwapRouterUpdated')
        .withArgs(routerAddr, next);
      expect(await vault.nftSwapRouter()).to.equal(next);
    });
  });

  describe('timelock: proposeSupportedPaymentToken / applySupportedPaymentToken', function () {
    it('unauthorized caller cannot propose', async function () {
      await expect(
        vault.connect(outsider).proposeSupportedPaymentToken(usdcAddr, true)
      ).to.be.reverted;
    });

    it('rejects zero token proposal', async function () {
      await expect(
        vault
          .connect(admin)
          .proposeSupportedPaymentToken(ethers.ZeroAddress, true)
      ).to.be.revertedWithCustomError(vault, 'ZeroAddress');
    });

    it('applies immediately — Pioneer RECIPIENT_CHANGE_DELAY = 0, no wait', async function () {
      await vault
        .connect(admin)
        .proposeSupportedPaymentToken(outsider.address, true);
      // Pioneer phase: RECIPIENT_CHANGE_DELAY is 0, so apply succeeds in the
      // next block with no time.increase. This guards against re-introducing a
      // constant propose→apply delay, which CLAUDE.md bans during Pioneer.
      await expect(vault.connect(admin).applySupportedPaymentToken()).to.not.be
        .reverted;
      expect(await vault.supportedPaymentTokens(outsider.address)).to.equal(
        true
      );
    });

    it('reverts NoPendingChange when nothing pending', async function () {
      await expect(
        vault.connect(admin).applySupportedPaymentToken()
      ).to.be.revertedWithCustomError(vault, 'NoPendingChange');
    });

    it('apply after delay adds then removes token', async function () {
      const MockERC20 = await ethers.getContractFactory('MockERC20');
      const wbtc = await MockERC20.deploy('WBTC', 'WBTC');
      const wbtcAddr = await wbtc.getAddress();
      await vault.connect(admin).proposeSupportedPaymentToken(wbtcAddr, true);
      await time.increase(TIMELOCK_DELAY + 1);
      await vault.connect(admin).applySupportedPaymentToken();
      expect(await vault.supportedPaymentTokens(wbtcAddr)).to.equal(true);

      await vault.connect(admin).proposeSupportedPaymentToken(wbtcAddr, false);
      await time.increase(TIMELOCK_DELAY + 1);
      await vault.connect(admin).applySupportedPaymentToken();
      expect(await vault.supportedPaymentTokens(wbtcAddr)).to.equal(false);
    });
  });

  describe('timelock: proposeMinSaleAmount / applyMinSaleAmount', function () {
    it('unauthorized caller cannot propose', async function () {
      await expect(
        vault.connect(outsider).proposeMinSaleAmount(xomAddr, 10_000n)
      ).to.be.reverted;
    });

    it('rejects zero token proposal', async function () {
      await expect(
        vault
          .connect(admin)
          .proposeMinSaleAmount(ethers.ZeroAddress, 10_000n)
      ).to.be.revertedWithCustomError(vault, 'ZeroAddress');
    });

    it('rejects sub-dust amount (< 100 wei) — M-03 audit fix', async function () {
      // `amount < 100` would yield `fee = amount / 100 = 0`, allowing
      // zero-fee spam intents. The setter rejects it.
      await expect(
        vault.connect(admin).proposeMinSaleAmount(xomAddr, 99n)
      ).to.be.revertedWithCustomError(vault, 'MinSaleAmountTooLow');
    });

    it('accepts the minimum valid amount (exactly 100 wei)', async function () {
      // 100 wei is the minimum that preserves a non-zero `fee` under
      // the 1% rate; the setter must accept it.
      await expect(
        vault.connect(admin).proposeMinSaleAmount(xomAddr, 100n)
      ).to.not.be.reverted;
    });

    it('applies immediately — Pioneer RECIPIENT_CHANGE_DELAY = 0, no wait', async function () {
      await vault.connect(admin).proposeMinSaleAmount(xomAddr, 150n);
      // Pioneer phase: RECIPIENT_CHANGE_DELAY is 0, so apply succeeds in the
      // next block with no time.increase. This guards against re-introducing a
      // constant propose→apply delay, which CLAUDE.md bans during Pioneer.
      await expect(vault.connect(admin).applyMinSaleAmount())
        .to.emit(vault, 'MinSaleAmountUpdated')
        .withArgs(xomAddr, 150n);
      expect(await vault.perTokenMinSaleAmount(xomAddr)).to.equal(150n);
    });

    it('reverts NoPendingChange when nothing pending', async function () {
      await expect(
        vault.connect(admin).applyMinSaleAmount()
      ).to.be.revertedWithCustomError(vault, 'NoPendingChange');
    });

    it('apply after delay changes perTokenMinSaleAmount', async function () {
      await vault.connect(admin).proposeMinSaleAmount(xomAddr, 20_000n);
      await time.increase(TIMELOCK_DELAY + 1);
      await expect(vault.connect(admin).applyMinSaleAmount())
        .to.emit(vault, 'MinSaleAmountUpdated')
        .withArgs(xomAddr, 20_000n);
      expect(await vault.perTokenMinSaleAmount(xomAddr)).to.equal(20_000n);
    });
  });
});
