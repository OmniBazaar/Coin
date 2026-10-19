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
 * 4. dispute stakes STAY in XOM even for a non-XOM escrow (anti-spam
 *    collateral, not sale proceeds) — and the XOM-denominated first-sale
 *    bonus is not credited for a non-XOM sale.
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

    const Escrow = await ethers.getContractFactory('EscrowV2');
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
    await escrow.connect(buyer).createEscrow(seller.address, await usdc.getAddress(), USDC(100), 7 * DAY);
    const id = await escrow.escrowCounter();

    expect(await escrow.getToken(id)).to.equal(await usdc.getAddress());
    expect((await escrow.getEscrow(id)).token).to.equal(await usdc.getAddress());
    expect((await escrow.getEscrow(id)).amount).to.equal(USDC(100));
    expect(await usdc.balanceOf(await escrow.getAddress())).to.equal(USDC(100));
    expect(await escrow.totalEscrowed(await usdc.getAddress())).to.equal(USDC(100));
  });

  it('refuses a token the fee vault will not settle', async function () {
    await expect(
      escrow.connect(buyer).createEscrow(seller.address, await other.getAddress(), USDC(10), 7 * DAY)
    ).to.be.revertedWithCustomError(escrow, 'TokenNotSupported');
  });

  it('refuses the zero address and a token without code', async function () {
    await expect(
      escrow.connect(buyer).createEscrow(seller.address, ethers.ZeroAddress, 1000, 7 * DAY)
    ).to.be.revertedWithCustomError(escrow, 'InvalidAddress');
    await expect(
      escrow.connect(buyer).createEscrow(seller.address, seller.address, 1000, 7 * DAY)
    ).to.be.revertedWithCustomError(escrow, 'InvalidAddress');
  });

  it('releases in the escrow token and takes the 1% fee in that token', async function () {
    await escrow
      .connect(buyer)
      .createEscrowWithReferrers(seller.address, await usdc.getAddress(), USDC(100), 7 * DAY, ethers.ZeroAddress, ethers.ZeroAddress);
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
    await escrow.connect(buyer).createEscrow(seller.address, await usdc.getAddress(), USDC(50), 7 * DAY);
    const id = await escrow.escrowCounter();
    const before = await usdc.balanceOf(buyer.address);

    await escrow.connect(seller).refundBuyer(id);

    expect(await usdc.balanceOf(buyer.address)).to.equal(before + USDC(50));
    expect(await escrow.totalEscrowed(await usdc.getAddress())).to.equal(0n);
  });

  it('keeps dispute stakes in XOM for a USDC escrow', async function () {
    await escrow.connect(buyer).createEscrow(seller.address, await usdc.getAddress(), USDC(100), 7 * DAY);
    const id = await escrow.escrowCounter();
    await time.increase(25 * 60 * 60);

    const commitment = ethers.solidityPackedKeccak256(
      ['uint256', 'uint256', 'address'],
      [id, 12345n, buyer.address]
    );
    const xomBefore = await xom.balanceOf(buyer.address);
    const usdcBefore = await usdc.balanceOf(buyer.address);
    await escrow.connect(buyer).commitDispute(id, commitment);

    // Stake came out of XOM, not out of the escrowed USDC.
    expect(await xom.balanceOf(buyer.address)).to.be.lt(xomBefore);
    expect(await usdc.balanceOf(buyer.address)).to.equal(usdcBefore);
    expect(await escrow.totalEscrowed(await xom.getAddress())).to.be.gt(0n);
  });

  it('still settles a plain XOM escrow end to end', async function () {
    const amount = ethers.parseEther('100');
    await escrow.connect(buyer).createEscrow(seller.address, await xom.getAddress(), amount, 7 * DAY);
    const id = await escrow.escrowCounter();

    const before = await xom.balanceOf(seller.address);
    await escrow.connect(buyer).releaseFunds(id);

    expect(await xom.balanceOf(seller.address)).to.equal(before + amount - amount / 100n);
    expect(await escrow.getToken(id)).to.equal(await xom.getAddress());
  });

  it('records the first-sale bonus for XOM sales only', async function () {
    // XOM: recorded.
    await escrow
      .connect(buyer)
      .createEscrow(seller.address, await xom.getAddress(), ethers.parseEther('10'), 7 * DAY);
    await escrow.connect(buyer).releaseFunds(await escrow.escrowCounter());
    expect(await registry.callCount()).to.equal(1n);

    // USDC: the registry's anti-Sybil minimum is an XOM figure, so a USDC
    // sale is deliberately NOT recorded.
    await escrow
      .connect(buyer)
      .createEscrow(seller.address, await usdc.getAddress(), USDC(10), 7 * DAY);
    await escrow.connect(buyer).releaseFunds(await escrow.escrowCounter());
    expect(await registry.callCount()).to.equal(1n);
  });

  it('does not let the private entry point run on a non-COTI chain', async function () {
    // pXOM escrows are unchanged in V2; on a chain without MPC they stay
    // unreachable rather than silently falling through to a public path.
    await expect(
      escrow.connect(buyer).createPrivateEscrow(seller.address, 0n, 7 * DAY)
    ).to.be.revertedWithCustomError(escrow, 'PrivacyNotAvailable');
  });
});
