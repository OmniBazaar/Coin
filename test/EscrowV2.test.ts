/**
 * EscrowV2 — multi-token escrow test suite (2026-10-19).
 *
 * The point of V2 is that an escrow holds the token the SELLER asked for, not
 * a token fixed at deploy. These tests pin the four things that could go wrong
 * when the asset becomes a variable:
 *
 * 1. the token is recorded and only the recorded token moves;
 * 2. a token the fee vault will not settle is refused at creation, so no
 *    escrow can be funded that could never be released with the fee paid;
 * 3. the marketplace fee is collected in the escrow's own token;
 * 4. dispute stakes are denominated in the escrow's own token (2.5% of the
 *    principal must be 2.5% of the principal's value); private pXOM escrows
 *    keep XOM stakes, and the XOM-denominated first-sale bonus is not
 *    credited for a non-XOM sale.
 *
 * Uses the REAL UnifiedFeeVault (UUPS proxy, linked libraries) so the
 * allowlist read and the referral-aware fee split are the production ones.
 */

/* eslint-disable @typescript-eslint/no-var-requires */
const { expect } = require('chai');
const { ethers, upgrades } = require('hardhat');
const { time } = require('@nomicfoundation/hardhat-network-helpers');

describe('EscrowV2 — per-escrow settlement token', function () {
  let escrow: any;
  let vault: any;
  let xom: any;
  let pxom: any;
  let usdc: any;
  let other: any;
  let registry: any;
  let owner: any;
  let buyer: any;
  let seller: any;
  let arbitrator: any;
  let stakingPool: any;
  let protocolTreasury: any;

  const FEE_BPS = 100n;
  const DAY = 24 * 60 * 60;
  const USDC = (n: number): bigint => BigInt(n) * 1_000_000n; // 6 decimals

  /**
   * Deploy a linked library and return its address.
   * @param name - Contract name.
   * @param opts - Optional factory overrides (nested library links).
   * @returns The deployed address.
   */
  const deployLib = async (name: string, opts?: any): Promise<string> => {
    const f = await ethers.getContractFactory(name, opts);
    const lib = await f.deploy();
    await lib.waitForDeployment();
    return lib.getAddress();
  };

  /**
   * Call the token-taking `createEscrow` overload explicitly. EscrowV2 keeps the
   * legacy 3-argument XOM signature, which makes the bare name ambiguous in
   * ethers v6 — exactly the ambiguity a client must resolve by full signature.
   * @param token - ERC-20 to escrow.
   * @param amount - Amount in the token's smallest unit.
   * @param duration - Escrow duration in seconds.
   * @returns The create transaction.
   */
  const createInToken = (
    token: string,
    amount: bigint,
    duration: number
  ): Promise<any> =>
    escrow
      .connect(buyer)
      ['createEscrow(address,address,uint256,uint256)'](seller.address, token, amount, duration);

  /** Call the legacy XOM-only createEscrow overload. */
  const createLegacyXom = (amount: bigint, duration: number): Promise<any> =>
    escrow.connect(buyer)['createEscrow(address,uint256,uint256)'](seller.address, amount, duration);

  beforeEach(async function () {
    [owner, buyer, seller, arbitrator, stakingPool, protocolTreasury] =
      await ethers.getSigners();

    const MockERC20 = await ethers.getContractFactory('MockERC20');
    xom = await MockERC20.deploy('OmniCoin', 'XOM');
    pxom = await MockERC20.deploy('Private OmniCoin', 'pXOM');
    usdc = await MockERC20.deploy('USD Coin', 'USDC');
    other = await MockERC20.deploy('Not Allowed', 'NOPE');
    for (const token of [xom, pxom, usdc, other]) {
      await token.waitForDeployment();
    }

    // Real vault with all linked libraries (same deployment shape as prod).
    const marketplaceFeeSplitter = await deployLib('MarketplaceFeeSplitter');
    const coinAgnosticSettlement = await deployLib('CoinAgnosticSettlement', {
      libraries: {
        MarketplaceFeeSplitter: marketplaceFeeSplitter,
        RoyaltyResolver: await deployLib('RoyaltyResolver'),
        SwapExecutor: await deployLib('SwapExecutor')
      }
    });
    const prioritySettlement = await deployLib('PrioritySettlement', {
      libraries: {
        CoinAgnosticSettlement: coinAgnosticSettlement,
        BuyIntentValidator: await deployLib('BuyIntentValidator')
      }
    });
    const Vault = await ethers.getContractFactory('UnifiedFeeVault', {
      libraries: {
        MarketplaceFeeSplitter: marketplaceFeeSplitter,
        CoinAgnosticSettlement: coinAgnosticSettlement,
        PrioritySettlement: prioritySettlement,
        NftSellerConsent: await deployLib('NftSellerConsent'),
        BridgeDestinationLib: await deployLib('BridgeDestinationLib')
      }
    });
    vault = await upgrades.deployProxy(
      Vault,
      [owner.address, stakingPool.address, protocolTreasury.address],
      {
        initializer: 'initialize',
        kind: 'uups',
        constructorArgs: [ethers.ZeroAddress],
        unsafeAllow: ['constructor', 'external-library-linking']
      }
    );
    await vault.waitForDeployment();

    // Production vaults run initializeV2, which seeds XOM into the allowlist
    // and sets the swap router. Reproduce that state here so the XOM paths
    // exercise the same allowlist as mainnet.
    await vault.initializeV2(ethers.Wallet.createRandom().address, await xom.getAddress());

    // Allowlist USDC the canonical way: propose → 48h timelock → apply.
    await vault.proposeSupportedPaymentToken(await usdc.getAddress(), true);
    await time.increase(48 * 60 * 60 + 1);
    await vault.applySupportedPaymentToken();
    expect(
      await vault.supportedPaymentTokens(await usdc.getAddress())
    ).to.equal(true);
    expect(
      await vault.supportedPaymentTokens(await other.getAddress())
    ).to.equal(false);

    const Registry = await ethers.getContractFactory('MockFirstSaleRegistry');
    registry = await Registry.deploy();

    const Escrow = await ethers.getContractFactory('EscrowV2', {
      libraries: {
        EscrowFeeRouter: await deployLib('EscrowFeeRouter'),
        EscrowPrivacyOps: await deployLib('EscrowPrivacyOps')
      }
    });
    escrow = await Escrow.deploy(
      await xom.getAddress(),
      await pxom.getAddress(),
      await registry.getAddress(),
      await vault.getAddress(),
      FEE_BPS,
      ethers.ZeroAddress // no trusted forwarder in unit tests
    );
    await escrow.waitForDeployment();

    const DEPOSITOR_ROLE = await vault.DEPOSITOR_ROLE();
    await vault
      .connect(owner)
      .grantRole(DEPOSITOR_ROLE, await escrow.getAddress());
    await escrow.connect(owner).addArbitrator(arbitrator.address);

    for (const token of [xom, usdc]) {
      await token.mint(buyer.address, 10_000n * 10n ** 18n);
      await token.connect(buyer).approve(await escrow.getAddress(), ethers.MaxUint256);
    }
  });

  it('records the token and escrows exactly that token', async function () {
    await createInToken(await usdc.getAddress(), USDC(100), 7 * DAY);
    const id = await escrow.escrowCounter();

    expect(await escrow.getToken(id)).to.equal(await usdc.getAddress());
    expect((await escrow.getEscrow(id)).token).to.equal(await usdc.getAddress());
    expect((await escrow.getEscrow(id)).amount).to.equal(USDC(100));
    expect(await usdc.balanceOf(await escrow.getAddress())).to.equal(USDC(100));
    expect(await escrow.totalEscrowed(await usdc.getAddress())).to.equal(USDC(100));
  });

  it('refuses a token the fee vault will not settle', async function () {
    await expect(
      createInToken(await other.getAddress(), USDC(10), 7 * DAY)
    ).to.be.revertedWithCustomError(escrow, 'TokenNotSupported');
  });

  it('refuses the zero address and a token without code', async function () {
    await expect(
      createInToken(ethers.ZeroAddress, 1000n, 7 * DAY)
    ).to.be.revertedWithCustomError(escrow, 'InvalidAddress');
    await expect(
      createInToken(seller.address, 1000n, 7 * DAY)
    ).to.be.revertedWithCustomError(escrow, 'InvalidAddress');
  });

  it('releases in the escrow token and takes the 1% fee in that token', async function () {
    await escrow
      .connect(buyer)
      ['createEscrowWithReferrers(address,address,uint256,uint256,address,address)'](
        seller.address,
        await usdc.getAddress(),
        USDC(100),
        7 * DAY,
        ethers.ZeroAddress,
        ethers.ZeroAddress
      );
    const id = await escrow.escrowCounter();

    const before = await usdc.balanceOf(seller.address);
    await escrow.connect(buyer).releaseFunds(id);

    // 1% fee leaves in USDC; the seller receives the other 99%.
    expect(await usdc.balanceOf(seller.address)).to.equal(before + USDC(99));
    // The vault distributes its split immediately, so it does not keep the
    // fee — the escrow's own accounting is what proves the fee was paid in
    // USDC rather than XOM.
    expect(await escrow.totalMarketplaceFees(await usdc.getAddress())).to.equal(USDC(1));
    expect(await usdc.balanceOf(await escrow.getAddress())).to.equal(0n);
    expect(await escrow.totalEscrowed(await usdc.getAddress())).to.equal(0n);
  });

  it('refunds in the escrow token', async function () {
    await createInToken(await usdc.getAddress(), USDC(50), 7 * DAY);
    const id = await escrow.escrowCounter();
    const before = await usdc.balanceOf(buyer.address);

    await escrow.connect(seller).refundBuyer(id);

    expect(await usdc.balanceOf(buyer.address)).to.equal(before + USDC(50));
    expect(await escrow.totalEscrowed(await usdc.getAddress())).to.equal(0n);
  });

  it('denominates the dispute stake in the escrow token', async function () {
    // 2.5% of a 100 USDC principal must be 2.5 USDC, not 2.5e6 wei of XOM.
    await createInToken(await usdc.getAddress(), USDC(100), 7 * DAY);
    const id = await escrow.escrowCounter();
    await time.increase(25 * 60 * 60);

    const commitment = ethers.solidityPackedKeccak256(
      ['uint256', 'uint256', 'address'],
      [id, 12345n, buyer.address]
    );
    const xomBefore = await xom.balanceOf(buyer.address);
    const usdcBefore = await usdc.balanceOf(buyer.address);
    await escrow.connect(buyer).commitDispute(id, commitment);
    expect(await xom.balanceOf(buyer.address)).to.equal(xomBefore);
    expect(await usdc.balanceOf(buyer.address)).to.equal(usdcBefore - 2_500_000n);
    expect(await escrow.totalEscrowed(await usdc.getAddress())).to.equal(USDC(100) + 2_500_000n);
  });

  it('still settles a plain XOM escrow end to end', async function () {
    const amount = ethers.parseEther('100');
    await createInToken(await xom.getAddress(), amount, 7 * DAY);
    const id = await escrow.escrowCounter();

    const before = await xom.balanceOf(seller.address);
    await escrow.connect(buyer).releaseFunds(id);

    expect(await xom.balanceOf(seller.address)).to.equal(before + amount - amount / 100n);
    expect(await escrow.getToken(id)).to.equal(await xom.getAddress());
  });

  it('records the first-sale bonus for XOM sales only', async function () {
    // XOM: recorded.
    await createInToken(await xom.getAddress(), ethers.parseEther('10'), 7 * DAY);
    await escrow.connect(buyer).releaseFunds(await escrow.escrowCounter());
    expect(await registry.callCount()).to.equal(1n);

    // USDC: the registry's anti-Sybil minimum is an XOM figure, so a USDC
    // sale is deliberately NOT recorded.
    await createInToken(await usdc.getAddress(), USDC(10), 7 * DAY);
    await escrow.connect(buyer).releaseFunds(await escrow.escrowCounter());
    expect(await registry.callCount()).to.equal(1n);
  });

  it('keeps the legacy XOM signature working', async function () {
    // A client that still encodes createEscrow(address,uint256,uint256) must
    // not be forced to upgrade the moment EscrowV2 goes live.
    await createLegacyXom(ethers.parseEther('5'), 7 * DAY);
    const id = await escrow.escrowCounter();
    expect(await escrow.getToken(id)).to.equal(await xom.getAddress());
    expect((await escrow.getEscrow(id)).amount).to.equal(ethers.parseEther('5'));
  });

  it('refuses a fee-on-transfer token instead of recording more than it holds', async function () {
    const FoT = await ethers.getContractFactory('MockFeeOnTransferToken');
    const fot = await FoT.deploy('Fee Token', 'FEE', 100); // 1% tax
    await fot.waitForDeployment();
    await vault.proposeSupportedPaymentToken(await fot.getAddress(), true);
    await time.increase(48 * 60 * 60 + 1);
    await vault.applySupportedPaymentToken();
    await fot.mint(buyer.address, USDC(100));
    await fot.connect(buyer).approve(await escrow.getAddress(), ethers.MaxUint256);

    await expect(
      createInToken(await fot.getAddress(), USDC(100), 7 * DAY)
    ).to.be.revertedWithCustomError(escrow, 'TokenTransferMismatch');
  });

  it('resolves a non-XOM dispute through the internal vote even when the panel is wired', async function () {
    // The judge panel prices a dispute deposit in XOM from getAmount(); a USDC
    // amount read as XOM would be dust. Non-XOM escrows therefore stay on the
    // internal 2-of-3 vote — and that vote must actually be reachable, or the
    // buyer would be the only party who could ever exit (claimDisputeTimeout).
    await escrow.connect(owner).setArbitrationContract(await registry.getAddress());

    await createInToken(await usdc.getAddress(), USDC(100), 7 * DAY);
    const usdcId = await escrow.escrowCounter();
    await createInToken(await xom.getAddress(), ethers.parseEther('100'), 7 * DAY);
    const xomId = await escrow.escrowCounter();
    await time.increase(25 * 60 * 60);

    const nonce = 12345n;
    const commitment = (id: bigint): string =>
      ethers.solidityPackedKeccak256(['uint256', 'uint256', 'address'], [id, nonce, buyer.address]);

    // Non-XOM: commit + reveal are allowed, and the internal vote resolves it.
    await escrow.connect(buyer).commitDispute(usdcId, commitment(usdcId));
    await escrow.connect(buyer).revealDispute(usdcId, nonce);
    await escrow.connect(buyer).vote(usdcId, true);
    const sellerBefore = await usdc.balanceOf(seller.address);
    await escrow.connect(seller).vote(usdcId, true);

    // Seller paid 99 USDC from claimable, dispute resolved.
    expect((await escrow.getEscrow(usdcId)).resolved).to.equal(true);
    await escrow.connect(seller).withdrawClaimable(await usdc.getAddress());
    expect(await usdc.balanceOf(seller.address)).to.equal(sellerBefore + USDC(99));

    // XOM: still defers to the panel.
    await expect(escrow.connect(buyer).commitDispute(xomId, commitment(xomId)))
      .to.be.revertedWithCustomError(escrow, 'UseArbitrationContract');
  });

  it('cannot reveal a dispute after the escrow has settled', async function () {
    // A commitment is not a dispute until it is revealed. If the parties settle
    // in between, revealing would flip `disputed` on a resolved escrow and
    // strand the committer's stake.
    await createInToken(await usdc.getAddress(), USDC(100), 7 * DAY);
    const id = await escrow.escrowCounter();
    await time.increase(25 * 60 * 60);
    const nonce = 777n;
    const commitment = ethers.solidityPackedKeccak256(
      ['uint256', 'uint256', 'address'],
      [id, nonce, buyer.address]
    );
    await escrow.connect(buyer).commitDispute(id, commitment);
    await escrow.connect(seller).refundBuyer(id);
    await expect(escrow.connect(buyer).revealDispute(id, nonce))
      .to.be.revertedWithCustomError(escrow, 'AlreadyResolved');
  });

  it('returns an unrevealed dispute stake after the grace period', async function () {
    await createInToken(await usdc.getAddress(), USDC(100), 7 * DAY);
    const id = await escrow.escrowCounter();
    await time.increase(25 * 60 * 60);
    const commitment = ethers.solidityPackedKeccak256(
      ['uint256', 'uint256', 'address'],
      [id, 999n, buyer.address]
    );
    const before = await usdc.balanceOf(buyer.address);
    await escrow.connect(buyer).commitDispute(id, commitment);
    await time.increase(60 * 60 + 24 * 60 * 60 + 1); // reveal deadline + grace
    await escrow.connect(buyer).reclaimExpiredStake(id);
    expect(await usdc.balanceOf(buyer.address)).to.equal(before);
  });

  it('routes the 1% to the referrers and both nodes when the vault accepts the fee', async function () {
    // Grant DEPOSITOR_ROLE (production does this by governance) so the escrow
    // takes the referral-aware split instead of the plain-transfer fallback.
    const role = await vault.DEPOSITOR_ROLE();
    await vault.connect(owner).grantRole(role, await escrow.getAddress());

    const listingNode = "0x1111111111111111111111111111111111111111";
    const sellingNode = "0x2222222222222222222222222222222222222222";
    const referrer = "0x3333333333333333333333333333333333333333";
    const referrer2 = "0x4444444444444444444444444444444444444444";

    await escrow
      .connect(buyer)
      ['createEscrowWithReferrersAndNodes(address,address,uint256,uint256,address,address,address,address)'](
        seller.address,
        await usdc.getAddress(),
        USDC(100),
        7 * DAY,
        referrer,
        referrer2,
        listingNode,
        sellingNode
      );
    const id = await escrow.escrowCounter();
    const e = await escrow.getEscrow(id);
    expect(e.listingNode).to.equal(listingNode);
    expect(e.sellingNode).to.equal(sellingNode);

    await escrow.connect(buyer).releaseFunds(id);

    // 1 USDC fee: referral 0.50% -> 0.35 referrer / 0.10 referrer2 / 0.05 ODDAO;
    // listing 0.25% -> 0.175 listing node / 0.05 selling node / 0.025 ODDAO.
    const claim = async (who: string): Promise<bigint> =>
      (await vault.pendingClaims(who, await usdc.getAddress())) as bigint;
    expect(await claim(referrer)).to.equal(350_000n);
    expect(await claim(referrer2)).to.equal(100_000n);
    expect(await claim(listingNode)).to.equal(175_000n);
    expect(await claim(sellingNode)).to.equal(50_000n);
  });

  it('refuses a node attribution that collides with a party', async function () {
    await expect(
      escrow
        .connect(buyer)
        ['createEscrowWithAttribution(address,address,uint256,uint256,address,address)'](
          seller.address,
          await usdc.getAddress(),
          USDC(10),
          7 * DAY,
          buyer.address,
          ethers.ZeroAddress
        )
    ).to.be.revertedWithCustomError(escrow, 'BadAttribution');
  });

  it('only the arbitration contract may clear a disputed flag', async function () {
    await createInToken(await usdc.getAddress(), USDC(100), 7 * DAY);
    const id = await escrow.escrowCounter();
    await expect(escrow.connect(buyer).unmarkDisputed(id)).to.be.revertedWithCustomError(
      escrow,
      'OnlyArbitrationContract'
    );
  });

  it('refuses an escrow too small to yield any marketplace fee', async function () {
    await expect(createInToken(await usdc.getAddress(), 99n, 7 * DAY))
      .to.be.revertedWithCustomError(escrow, 'InvalidAmount');
  });

  it('does not let the private entry point run on a non-COTI chain', async function () {
    // pXOM escrows are unchanged in V2; on a chain without MPC they stay
    // unreachable rather than silently falling through to a public path.
    await expect(
      escrow.connect(buyer).createPrivateEscrow(seller.address, 0n, 7 * DAY)
    ).to.be.revertedWithCustomError(escrow, 'PrivacyNotAvailable');
  });
});
