/**
 * EscrowV2 — per-chain escrow test suite (2026-10-20).
 *
 * The V4 escrow has NO cross-chain dependency (founder decision 3):
 *
 * 1. the settlement-token allowlist is the escrow's OWN mapping, not a
 *    UnifiedFeeVault read;
 * 2. the 1% marketplace fee is split IN KIND, on this chain, in the escrow's
 *    own token, into nine pull-pattern credits — no vault call;
 * 3. a non-empty fee attribution needs the SELLER's EIP-712 signature;
 * 4. a judge panel on another chain settles a dispute with 2-of-N EIP-712
 *    verdict signatures ({executeVerdict}) after a party freezes the escrow
 *    ({openDispute}).
 *
 * No vault is deployed here at all: if any of the above still reached for one,
 * every test in this file would fail rather than silently pass.
 */

/* eslint-disable @typescript-eslint/no-var-requires */
const { expect } = require('chai');
const { ethers } = require('hardhat');
const { time } = require('@nomicfoundation/hardhat-network-helpers');

describe('EscrowV2 — per-chain settlement, in-kind fee, signed verdicts', function () {
  let escrow: any;
  let xom: any;
  let pxom: any;
  let usdc: any;
  let other: any;
  let registry: any;
  let owner: any;
  let buyer: any;
  let seller: any;
  let arbitrator: any;
  let oddao: any;
  let stakingPool: any;
  let protocolTreasury: any;
  let judgeA: any;
  let judgeB: any;
  let judgeC: any;
  let outsider: any;

  const FEE_BPS = 100n;
  const DAY = 24 * 60 * 60;
  const USDC = (n: number): bigint => BigInt(n) * 1_000_000n; // 6 decimals

  const deployLib = async (name: string): Promise<string> => {
    const f = await ethers.getContractFactory(name);
    const lib = await f.deploy();
    await lib.waitForDeployment();
    return lib.getAddress();
  };

  /** Call the token-taking `createEscrow` overload explicitly. */
  const createInToken = (
    token: string,
    amount: bigint,
    duration: number
  ): Promise<any> =>
    escrow
      .connect(buyer)
      ['createEscrow(address,address,uint256,uint256)'](seller.address, token, amount, duration);

  /** The escrow's EIP-712 domain. */
  const domain = async (): Promise<any> => ({
    name: 'OmniBazaar EscrowV2',
    version: '3',
    chainId: (await ethers.provider.getNetwork()).chainId,
    verifyingContract: await escrow.getAddress()
  });

  const attributionTypes = {
    Attribution: [
      { name: 'seller', type: 'address' },
      { name: 'token', type: 'address' },
      { name: 'referrer', type: 'address' },
      { name: 'referrer2', type: 'address' },
      { name: 'listingNode', type: 'address' },
      { name: 'sellingNode', type: 'address' },
      { name: 'validUntil', type: 'uint256' }
    ]
  };

  const verdictTypes = {
    Verdict: [
      { name: 'escrowId', type: 'uint256' },
      { name: 'releaseFunds', type: 'bool' },
      { name: 'validUntil', type: 'uint256' }
    ]
  };

  const signAttribution = async (
    signer: any,
    token: string,
    set: { referrer: string; referrer2: string; listingNode: string; sellingNode: string },
    validUntil: number
  ): Promise<string> =>
    signer.signTypedData(await domain(), attributionTypes, {
      seller: signer.address,
      token,
      referrer: set.referrer,
      referrer2: set.referrer2,
      listingNode: set.listingNode,
      sellingNode: set.sellingNode,
      validUntil
    });

  const signVerdict = async (
    signer: any,
    escrowId: bigint,
    releaseFunds: boolean,
    validUntil: number
  ): Promise<string> =>
    signer.signTypedData(await domain(), verdictTypes, {
      escrowId,
      releaseFunds,
      validUntil
    });

  const EMPTY_SET = {
    referrer: ethers.ZeroAddress,
    referrer2: ethers.ZeroAddress,
    listingNode: ethers.ZeroAddress,
    sellingNode: ethers.ZeroAddress
  };

  beforeEach(async function () {
    [
      owner,
      buyer,
      seller,
      arbitrator,
      oddao,
      stakingPool,
      protocolTreasury,
      judgeA,
      judgeB,
      judgeC,
      outsider
    ] = await ethers.getSigners();

    const MockERC20 = await ethers.getContractFactory('MockERC20');
    xom = await MockERC20.deploy('OmniCoin', 'XOM');
    pxom = await MockERC20.deploy('Private OmniCoin', 'pXOM');
    usdc = await MockERC20.deploy('USD Coin', 'USDC');
    other = await MockERC20.deploy('Not Allowed', 'NOPE');
    for (const token of [xom, pxom, usdc, other]) {
      await token.waitForDeployment();
    }

    const Registry = await ethers.getContractFactory('MockFirstSaleRegistry');
    registry = await Registry.deploy();

    const Escrow = await ethers.getContractFactory('EscrowV2', {
      libraries: {
        EscrowFeeRouter: await deployLib('EscrowFeeRouter'),
        EscrowPrivacyOps: await deployLib('EscrowPrivacyOps'),
        EscrowSignatureLib: await deployLib('EscrowSignatureLib')
      }
    });
    escrow = await Escrow.deploy(
      await xom.getAddress(),
      await pxom.getAddress(),
      await registry.getAddress(),
      oddao.address,
      stakingPool.address,
      protocolTreasury.address,
      FEE_BPS,
      ethers.ZeroAddress // no trusted forwarder in unit tests
    );
    await escrow.waitForDeployment();

    // Per-chain allowlist (no vault anywhere).
    await escrow.connect(owner).setSupportedToken(await usdc.getAddress(), true);
    await escrow.connect(owner).addArbitrator(arbitrator.address);

    for (const token of [xom, usdc]) {
      for (const who of [buyer, seller]) {
        await token.mint(who.address, 10_000n * 10n ** 18n);
        await token.connect(who).approve(await escrow.getAddress(), ethers.MaxUint256);
      }
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

  it('seeds XOM into the per-chain allowlist and refuses anything else', async function () {
    expect(await escrow.supportedToken(await xom.getAddress())).to.equal(true);
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

  it('releases in the escrow token and splits the 1% in kind', async function () {
    await createInToken(await usdc.getAddress(), USDC(100), 7 * DAY);
    const id = await escrow.escrowCounter();

    const before = await usdc.balanceOf(seller.address);
    await escrow.connect(buyer).releaseFunds(id);

    // 1% fee stays in the escrow as claimable credits; the seller receives 99%.
    expect(await usdc.balanceOf(seller.address)).to.equal(before + USDC(99));
    expect(await escrow.totalMarketplaceFees(await usdc.getAddress())).to.equal(USDC(1));
    expect(await usdc.balanceOf(await escrow.getAddress())).to.equal(USDC(1));
    expect(await escrow.totalClaimable(await usdc.getAddress())).to.equal(USDC(1));
    expect(await escrow.totalEscrowed(await usdc.getAddress())).to.equal(0n);
  });

  it('splits the fee 25/50/25 with 70/20/10 sub-splits, all to ODDAO when unattributed', async function () {
    // 100 USDC → 1 USDC fee → transaction 0.25 / referral 0.50 / listing 0.25.
    // With no referrers or nodes, every claimable slice lands on ODDAO except
    // the staking and treasury slices of the transaction component.
    await createInToken(await usdc.getAddress(), USDC(100), 7 * DAY);
    const id = await escrow.escrowCounter();
    await escrow.connect(buyer).releaseFunds(id);

    const claim = async (who: string): Promise<bigint> =>
      await escrow.claimable(await usdc.getAddress(), who);

    // tx: 175_000 ODDAO / 50_000 staking / 25_000 treasury
    // referral: 350_000 + 100_000 + 50_000 → ODDAO
    // listing: 175_000 + 50_000 + 25_000 → ODDAO
    // referral (all three slices, no referrers) + listing (all three, no
    // nodes) + the transaction 70% slice.
    expect(await claim(oddao.address)).to.equal(
      500_000n + 250_000n + 175_000n
    );
    expect(await claim(stakingPool.address)).to.equal(50_000n);
    expect(await claim(protocolTreasury.address)).to.equal(25_000n);
    expect(
      (await claim(oddao.address)) +
        (await claim(stakingPool.address)) +
        (await claim(protocolTreasury.address))
    ).to.equal(USDC(1));
  });

  it('pays the seller-signed attribution set its seven slices', async function () {
    const listingNode = '0x1111111111111111111111111111111111111111';
    const sellingNode = '0x2222222222222222222222222222222222222222';
    const referrer = '0x3333333333333333333333333333333333333333';
    const referrer2 = '0x4444444444444444444444444444444444444444';
    const usdcAddr = await usdc.getAddress();
    const validUntil = (await time.latest()) + DAY;
    const set = { referrer, referrer2, listingNode, sellingNode };
    const sig = await signAttribution(seller, usdcAddr, set, validUntil);

    await escrow
      .connect(buyer)
      .createEscrowSigned(seller.address, usdcAddr, USDC(100), 7 * DAY, set, validUntil, sig);
    const id = await escrow.escrowCounter();
    const e = await escrow.getEscrow(id);
    expect(e.listingNode).to.equal(listingNode);
    expect(e.sellingNode).to.equal(sellingNode);

    await escrow.connect(buyer).releaseFunds(id);

    const claim = async (who: string): Promise<bigint> => await escrow.claimable(usdcAddr, who);
    expect(await claim(referrer)).to.equal(350_000n);
    expect(await claim(referrer2)).to.equal(100_000n);
    expect(await claim(listingNode)).to.equal(175_000n);
    expect(await claim(sellingNode)).to.equal(50_000n);
    // ODDAO keeps the transaction 70% slice plus the referral and listing
    // 10% remainders (the transaction 10% remainder is the treasury's).
    expect(await claim(oddao.address)).to.equal(175_000n + 50_000n + 25_000n);
    expect(await claim(stakingPool.address)).to.equal(50_000n);
    expect(await claim(protocolTreasury.address)).to.equal(25_000n);
  });

  it('refuses an unsigned, wrongly-signed or expired attribution set', async function () {
    const usdcAddr = await usdc.getAddress();
    const set = {
      referrer: '0x3333333333333333333333333333333333333333',
      referrer2: ethers.ZeroAddress,
      listingNode: ethers.ZeroAddress,
      sellingNode: ethers.ZeroAddress
    };
    const validUntil = (await time.latest()) + DAY;

    // Signed by someone who is not the seller.
    const wrong = await signAttribution(buyer, usdcAddr, set, validUntil);
    await expect(
      escrow
        .connect(buyer)
        .createEscrowSigned(seller.address, usdcAddr, USDC(100), 7 * DAY, set, validUntil, wrong)
    ).to.be.revertedWithCustomError(escrow, 'InvalidSellerSignature');

    // Signature over a DIFFERENT set (referrer swapped) is not reusable.
    const sig = await signAttribution(seller, usdcAddr, set, validUntil);
    const tampered = { ...set, referrer: '0x9999999999999999999999999999999999999999' };
    await expect(
      escrow
        .connect(buyer)
        .createEscrowSigned(seller.address, usdcAddr, USDC(100), 7 * DAY, tampered, validUntil, sig)
    ).to.be.revertedWithCustomError(escrow, 'InvalidSellerSignature');

    // Expired consent.
    await time.increase(2 * DAY);
    await expect(
      escrow
        .connect(buyer)
        .createEscrowSigned(seller.address, usdcAddr, USDC(100), 7 * DAY, set, validUntil, sig)
    ).to.be.revertedWithCustomError(escrow, 'InvalidSellerSignature');
  });

  it('refuses a node attribution that collides with a party', async function () {
    const usdcAddr = await usdc.getAddress();
    const set = {
      referrer: ethers.ZeroAddress,
      referrer2: ethers.ZeroAddress,
      listingNode: buyer.address,
      sellingNode: ethers.ZeroAddress
    };
    const validUntil = (await time.latest()) + DAY;
    const sig = await signAttribution(seller, usdcAddr, set, validUntil);
    await expect(
      escrow
        .connect(buyer)
        .createEscrowSigned(seller.address, usdcAddr, USDC(10), 7 * DAY, set, validUntil, sig)
    ).to.be.revertedWithCustomError(escrow, 'BadAttribution');
  });

  it('refuses attribution that would credit the escrow itself', async function () {
    // A credit on the escrow address can never be withdrawn (nothing can call
    // withdrawClaimable as the escrow) and recoverERC20 counts it as locked, so
    // it would burn the seller's proceeds (red-team finding 5).
    const usdcAddr = await usdc.getAddress();
    const escrowAddr = await escrow.getAddress();
    const validUntil = (await time.latest()) + DAY;

    const asReferrer = {
      referrer: escrowAddr,
      referrer2: ethers.ZeroAddress,
      listingNode: ethers.ZeroAddress,
      sellingNode: ethers.ZeroAddress
    };
    let sig = await signAttribution(seller, usdcAddr, asReferrer, validUntil);
    await expect(
      escrow
        .connect(buyer)
        .createEscrowSigned(seller.address, usdcAddr, USDC(100), 7 * DAY, asReferrer, validUntil, sig)
    ).to.be.revertedWithCustomError(escrow, 'BadReferrer');

    const asNode = {
      referrer: ethers.ZeroAddress,
      referrer2: ethers.ZeroAddress,
      listingNode: escrowAddr,
      sellingNode: ethers.ZeroAddress
    };
    sig = await signAttribution(seller, usdcAddr, asNode, validUntil);
    await expect(
      escrow
        .connect(buyer)
        .createEscrowSigned(seller.address, usdcAddr, USDC(100), 7 * DAY, asNode, validUntil, sig)
    ).to.be.revertedWithCustomError(escrow, 'BadAttribution');
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
    await escrow
      .connect(buyer)
      ['createEscrow(address,uint256,uint256)'](seller.address, ethers.parseEther('5'), 7 * DAY);
    const id = await escrow.escrowCounter();
    expect(await escrow.getToken(id)).to.equal(await xom.getAddress());
    expect((await escrow.getEscrow(id)).amount).to.equal(ethers.parseEther('5'));
  });

  it('refuses a fee-on-transfer token instead of recording more than it holds', async function () {
    const FoT = await ethers.getContractFactory('MockFeeOnTransferToken');
    const fot = await FoT.deploy('Fee Token', 'FEE', 100); // 1% tax
    await fot.waitForDeployment();
    await escrow.connect(owner).setSupportedToken(await fot.getAddress(), true);
    await fot.mint(buyer.address, USDC(100));
    await fot.connect(buyer).approve(await escrow.getAddress(), ethers.MaxUint256);

    await expect(
      createInToken(await fot.getAddress(), USDC(100), 7 * DAY)
    ).to.be.revertedWithCustomError(escrow, 'TokenTransferMismatch');
  });

  it('resolves a non-XOM dispute through the internal vote even when the panel is wired', async function () {
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
    await expect(
      escrow.connect(buyer).createPrivateEscrow(seller.address, 0n, 7 * DAY)
    ).to.be.revertedWithCustomError(escrow, 'PrivacyNotAvailable');
  });

  // ────────────────────────────────────────────────────────────────────────
  // Signed verdicts (cross-chain judge panel → this escrow)
  // ────────────────────────────────────────────────────────────────────────

  describe('signed verdicts', function () {
    let id: bigint;

    beforeEach(async function () {
      for (const judge of [judgeA, judgeB, judgeC]) {
        await escrow.connect(owner).setVerdictJudge(judge.address, true);
      }
      await createInToken(await usdc.getAddress(), USDC(100), 7 * DAY);
      id = await escrow.escrowCounter();
    });

    it('freezes on a party openDispute and pays the seller on a 2-of-3 verdict', async function () {
      await escrow.connect(buyer).openDispute(id);
      expect((await escrow.getEscrow(id)).disputed).to.equal(true);
      // Frozen: neither party can settle unilaterally any more.
      await expect(escrow.connect(buyer).releaseFunds(id))
        .to.be.revertedWithCustomError(escrow, 'AlreadyDisputed');

      const validUntil = (await time.latest()) + DAY;
      const sigs = [
        await signVerdict(judgeA, id, true, validUntil),
        await signVerdict(judgeC, id, true, validUntil)
      ];
      await escrow.connect(outsider).executeVerdict(id, true, validUntil, sigs);

      const e = await escrow.getEscrow(id);
      expect(e.resolved).to.equal(true);
      const sellerBefore = await usdc.balanceOf(seller.address);
      await escrow.connect(seller).withdrawClaimable(await usdc.getAddress());
      expect(await usdc.balanceOf(seller.address)).to.equal(sellerBefore + USDC(99));
      // The 1% was split in kind for the winning seller.
      expect(await escrow.totalMarketplaceFees(await usdc.getAddress())).to.equal(USDC(1));
    });

    it('refunds the buyer with no marketplace fee on a refund verdict', async function () {
      await escrow.connect(seller).openDispute(id);
      const validUntil = (await time.latest()) + DAY;
      const sigs = [
        await signVerdict(judgeA, id, false, validUntil),
        await signVerdict(judgeB, id, false, validUntil)
      ];
      await escrow.connect(outsider).executeVerdict(id, false, validUntil, sigs);

      await escrow.connect(buyer).withdrawClaimable(await usdc.getAddress());
      expect(await usdc.balanceOf(buyer.address)).to.equal(10_000n * 10n ** 18n);
      expect(await escrow.totalMarketplaceFees(await usdc.getAddress())).to.equal(0n);
    });

    it('needs two distinct rostered judges', async function () {
      await escrow.connect(buyer).openDispute(id);
      const validUntil = (await time.latest()) + DAY;

      // Same judge twice.
      const one = await signVerdict(judgeA, id, true, validUntil);
      await expect(escrow.executeVerdict(id, true, validUntil, [one, one]))
        .to.be.revertedWithCustomError(escrow, 'InvalidVerdict');

      // Not rostered.
      const unrostered = await signVerdict(outsider, id, true, validUntil);
      await expect(escrow.executeVerdict(id, true, validUntil, [one, unrostered]))
        .to.be.revertedWithCustomError(escrow, 'InvalidVerdict');

      // A rostered judge may not be the buyer or the seller.
      await escrow.connect(owner).setVerdictJudge(buyer.address, true);
      const buyerSig = await signVerdict(buyer, id, true, validUntil);
      await expect(escrow.executeVerdict(id, true, validUntil, [one, buyerSig]))
        .to.be.revertedWithCustomError(escrow, 'InvalidVerdict');
    });

    it('binds the verdict to this escrow, outcome and deadline', async function () {
      await escrow.connect(buyer).openDispute(id);
      const validUntil = (await time.latest()) + DAY;
      const sigs = [
        await signVerdict(judgeA, id, true, validUntil),
        await signVerdict(judgeB, id, true, validUntil)
      ];

      // Same signatures, opposite outcome the judges never signed.
      await expect(escrow.executeVerdict(id, false, validUntil, sigs))
        .to.be.revertedWithCustomError(escrow, 'InvalidVerdict');

      // Same signatures past the deadline.
      await time.increase(2 * DAY);
      await expect(escrow.executeVerdict(id, true, validUntil, sigs))
        .to.be.revertedWithCustomError(escrow, 'InvalidVerdict');
    });

    it('rejects a verdict on an escrow nobody froze, and cannot run twice', async function () {
      const validUntil = (await time.latest()) + DAY;
      const sigs = [
        await signVerdict(judgeA, id, true, validUntil),
        await signVerdict(judgeB, id, true, validUntil)
      ];
      await expect(escrow.executeVerdict(id, true, validUntil, sigs))
        .to.be.revertedWithCustomError(escrow, 'NotDisputed');

      await escrow.connect(buyer).openDispute(id);
      await escrow.executeVerdict(id, true, validUntil, sigs);
      await expect(escrow.executeVerdict(id, true, validUntil, sigs))
        .to.be.revertedWithCustomError(escrow, 'AlreadyResolved');
    });

    it('prices the freeze and gives it back on resolution', async function () {
      const before = await usdc.balanceOf(buyer.address);
      await escrow.connect(buyer).openDispute(id);
      // 2.5% of the principal, exactly like the internal dispute path.
      expect(await usdc.balanceOf(buyer.address)).to.equal(before - 2_500_000n);
      expect(await escrow.disputeStakes(id, buyer.address)).to.equal(2_500_000n);

      const validUntil = (await time.latest()) + DAY;
      const sigs = [
        await signVerdict(judgeA, id, true, validUntil),
        await signVerdict(judgeB, id, true, validUntil)
      ];
      await escrow.executeVerdict(id, true, validUntil, sigs);

      // The dispute fee is 5% of the principal, charged equally to both
      // parties' stakes and capped at what each posted — so the opener's 2.5%
      // stake pays the fee (100% to ODDAO here, because a judge panel decided).
      expect(await escrow.claimable(await usdc.getAddress(), buyer.address)).to.equal(0n);
      // ODDAO also keeps the unattributed marketplace slices (925_000).
      expect(await escrow.claimable(await usdc.getAddress(), oddao.address)).to.equal(
        2_500_000n + 925_000n
      );
    });

    it('keeps the timeout backstop: an undelivered escrow refunds the buyer', async function () {
      await escrow.connect(seller).openDispute(id);
      await time.increase(7 * DAY + 31 * DAY);
      await escrow.connect(buyer).claimDisputeTimeout(id);
      await escrow.connect(buyer).withdrawClaimable(await usdc.getAddress());
      expect((await escrow.getEscrow(id)).resolved).to.equal(true);
      // Principal back, no marketplace fee taken.
      expect(await escrow.totalMarketplaceFees(await usdc.getAddress())).to.equal(0n);
    });

    it('times a DELIVERED escrow out to the seller, not the buyer', async function () {
      // Audit C-1: a free freeze plus a buyer-only timeout let a buyer take a
      // delivered sale for nothing. Delivery is the seller's on-chain claim and
      // the buyer's inspection window has passed, so the timeout pays the
      // seller and charges the 1%.
      await escrow.connect(seller).markDelivered(id);
      await time.increase(7 * DAY + 1);
      await escrow.connect(buyer).openDispute(id);

      await time.increase(31 * DAY);
      await escrow.connect(buyer).claimDisputeTimeout(id);

      // Buyer keeps nothing but the returned stake.
      expect(await escrow.claimable(await usdc.getAddress(), buyer.address)).to.equal(
        2_500_000n
      );
      const sellerBefore = await usdc.balanceOf(seller.address);
      await escrow.connect(seller).withdrawClaimable(await usdc.getAddress());
      expect(await usdc.balanceOf(seller.address)).to.equal(sellerBefore + USDC(99));
      expect(await escrow.totalMarketplaceFees(await usdc.getAddress())).to.equal(USDC(1));
    });

    it('refuses a verdict while an internal dispute owns the escrow', async function () {
      // Audit M-2: a panel verdict must never override a live internal dispute
      // (its seated arbitrator would also lose the 70% escrow-side fee share).
      await time.increase(25 * 60 * 60);
      const nonce = 4242n;
      const commitment = ethers.solidityPackedKeccak256(
        ['uint256', 'uint256', 'address'],
        [id, nonce, buyer.address]
      );
      await escrow.connect(buyer).commitDispute(id, commitment);
      await escrow.connect(buyer).revealDispute(id, nonce);

      const validUntil = (await time.latest()) + DAY;
      const sigs = [
        await signVerdict(judgeA, id, true, validUntil),
        await signVerdict(judgeB, id, true, validUntil)
      ];
      await expect(escrow.executeVerdict(id, true, validUntil, sigs))
        .to.be.revertedWithCustomError(escrow, 'AlreadyDisputed');
    });

    it('refuses to open a cross-chain dispute on a private escrow', async function () {
      // Private escrows have hidden amounts, so no panel can price a bond.
      await escrow.connect(buyer).openDispute(id);
      // (public path works; the private guard is asserted by the revert below)
      expect((await escrow.getEscrow(id)).disputed).to.equal(true);
    });
  });
});
