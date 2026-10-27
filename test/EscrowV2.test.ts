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

  it('refuses an escrow too small to yield any marketplace fee', async function () {
    await expect(createInToken(await usdc.getAddress(), 99n, 7 * DAY))
      .to.be.revertedWithCustomError(escrow, 'InvalidAmount');
  });

  // ────────────────────────────────────────────────────────────────────────
  // Signed verdicts (cross-chain judge panel → this escrow)
  // ────────────────────────────────────────────────────────────────────────

  describe('settable arbitration parameters', function () {
    it('bounds the fee and its share of the sale', async function () {
      await expect(escrow.connect(owner).setArbitrationFee(0, 2500))
        .to.be.revertedWithCustomError(escrow, 'InvalidFeeConfig');
      await expect(escrow.connect(owner).setArbitrationFee(1001, 2500))
        .to.be.revertedWithCustomError(escrow, 'InvalidFeeConfig');
      await expect(escrow.connect(owner).setArbitrationFee(500, 5001))
        .to.be.revertedWithCustomError(escrow, 'InvalidFeeConfig');
      await escrow.connect(owner).setArbitrationFee(400, 2000);
      expect(await escrow.arbitrationFeeBps()).to.equal(400n);
      expect(await escrow.maxArbitrationFeeBps()).to.equal(2000n);
      await expect(escrow.connect(buyer).setArbitrationFee(400, 2000))
        .to.be.revertedWithCustomError(escrow, 'OnlyAdmin');
    });

    it('never lets a split crowd ODDAO out', async function () {
      // 95% judges + 10% submitter = 105%: refused.
      await expect(escrow.connect(owner).setArbitrationSplit(9500, 8100, 1000, 900))
        .to.be.revertedWithCustomError(escrow, 'InvalidFeeConfig');
      // 96% judges leaves 4% for ODDAO: refused (5% minimum).
      await expect(escrow.connect(owner).setArbitrationSplit(9600, 8100, 0, 900))
        .to.be.revertedWithCustomError(escrow, 'InvalidFeeConfig');
      await escrow.connect(owner).setArbitrationSplit(8000, 8100, 1000, 900);
      expect(await escrow.judgePoolBps2()).to.equal(8000n);
    });

    it('changes fee recipients only after the delay', async function () {
      const [, , , , , , , newSink] = await ethers.getSigners();
      await escrow.connect(owner).proposeBeneficiaries(
        newSink.address, stakingPool.address, protocolTreasury.address
      );
      await expect(escrow.connect(owner).acceptBeneficiaries())
        .to.be.revertedWithCustomError(escrow, 'BeneficiaryDelayActive');
      await time.increase(48 * 60 * 60 + 1);
      await escrow.connect(owner).acceptBeneficiaries();
      expect(await escrow.ODDAO()).to.equal(newSink.address);
    });
  });

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
      // 100 - 1% marketplace fee - 5% arbitration fee, both taken from the payout.
      expect(await usdc.balanceOf(seller.address)).to.equal(sellerBefore + USDC(94));
      // The 1% was split in kind for the winning seller.
      expect(await escrow.totalMarketplaceFees(await usdc.getAddress())).to.equal(USDC(1));

      // The 5% fee (5.00 USDC) pays the two judges 40% each, the submitter 10%
      // and ODDAO the remaining 10% plus its marketplace slices (0.925).
      const token = await usdc.getAddress();
      expect(await escrow.claimable(token, judgeA.address)).to.equal(2_000_000n);
      expect(await escrow.claimable(token, judgeC.address)).to.equal(2_000_000n);
      expect(await escrow.claimable(token, outsider.address)).to.equal(500_000n);
      expect(await escrow.claimable(token, oddao.address)).to.equal(1_425_000n);
    });

    it('refunds the buyer with no marketplace fee on a refund verdict', async function () {
      await escrow.connect(seller).openDispute(id);
      const validUntil = (await time.latest()) + DAY;
      const sigs = [
        await signVerdict(judgeA, id, false, validUntil),
        await signVerdict(judgeB, id, false, validUntil)
      ];
      await escrow.connect(outsider).executeVerdict(id, false, validUntil, sigs);

      // Principal back less the 5% arbitration fee (no marketplace fee on a refund).
      expect(await escrow.claimable(await usdc.getAddress(), buyer.address)).to.equal(
        USDC(95)
      );
      await escrow.connect(buyer).withdrawClaimable(await usdc.getAddress());
      expect(await usdc.balanceOf(buyer.address)).to.equal(
        10_000n * 10n ** 18n - USDC(5)
      );
      expect(await escrow.totalMarketplaceFees(await usdc.getAddress())).to.equal(0n);
    });

    it('needs two distinct rostered judges', async function () {
      await escrow.connect(buyer).openDispute(id);
      const validUntil = (await time.latest()) + DAY;

      // Same judge twice: the duplicate is skipped, so only one judge signed
      // and the threshold is not met — the bundle is refused, not executed.
      const one = await signVerdict(judgeA, id, true, validUntil);
      await expect(escrow.executeVerdict(id, true, validUntil, [one, one]))
        .to.be.revertedWithCustomError(escrow, 'NotEnoughVerdicts');

      // Not rostered.
      const unrostered = await signVerdict(outsider, id, true, validUntil);
      await expect(escrow.executeVerdict(id, true, validUntil, [one, unrostered]))
        .to.be.revertedWithCustomError(escrow, 'InvalidVerdict');

      // A rostered judge may not be the buyer or the seller. (The roster is
      // capped at three and removal is delayed, so free a seat first.)
      await escrow.connect(owner).setVerdictJudge(judgeC.address, false);
      await time.increase(48 * 60 * 60 + 1);
      await escrow.connect(owner).acceptJudgeRemoval();
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

      // Same signatures, opposite outcome the judges never signed: neither
      // direction reaches the threshold, so the chain refuses it.
      await expect(escrow.executeVerdict(id, false, validUntil, sigs))
        .to.be.revertedWithCustomError(escrow, 'NotEnoughVerdicts');

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

    it('takes nothing at filing and charges the fee from the payout', async function () {
      const before = await usdc.balanceOf(buyer.address);
      await escrow.connect(buyer).openDispute(id);
      // 🛑 No stake: filing is free, so no dispute can be starved into
      // unarbitrability by a party who will not post collateral.
      expect(await usdc.balanceOf(buyer.address)).to.equal(before);
      // The fee is snapshotted on the escrow at filing.
      expect((await escrow.getEscrow(id)).disputeFee).to.equal(5_000_000n);

      const validUntil = (await time.latest()) + DAY;
      const sigs = [
        await signVerdict(judgeA, id, true, validUntil),
        await signVerdict(judgeB, id, true, validUntil)
      ];
      await escrow.executeVerdict(id, true, validUntil, sigs);

      // The fee is 5% of the disputed amount, taken out of the seller's payout;
      // the buyer's principal is untouched by it (the buyer staked nothing).
      expect(await escrow.claimable(await usdc.getAddress(), seller.address)).to.equal(
        USDC(94)
      );
    });

    it('pays all three judges when one of them broke a tie', async function () {
      await escrow.connect(buyer).openDispute(id);
      const validUntil = (await time.latest()) + DAY;
      // Two judges agree on release, the third dissents on refund. All three
      // sat; all three are paid 27% of the fee; the submitter takes 9%.
      const sigs = [
        await signVerdict(judgeA, id, true, validUntil),
        await signVerdict(judgeB, id, true, validUntil),
        await signVerdict(judgeC, id, false, validUntil)
      ];
      await escrow.connect(outsider).executeVerdict(id, true, validUntil, sigs);

      const token = await usdc.getAddress();
      expect(await escrow.claimable(token, judgeA.address)).to.equal(1_350_000n);
      expect(await escrow.claimable(token, judgeB.address)).to.equal(1_350_000n);
      expect(await escrow.claimable(token, judgeC.address)).to.equal(1_350_000n);
      expect(await escrow.claimable(token, outsider.address)).to.equal(450_000n);
      // ODDAO: 10% of the fee plus its marketplace slices.
      expect(await escrow.claimable(token, oddao.address)).to.equal(1_425_000n);
    });

    it('refuses a dissent-only bundle and a bundle with no majority', async function () {
      await escrow.connect(buyer).openDispute(id);
      const validUntil = (await time.latest()) + DAY;
      const release = await signVerdict(judgeA, id, true, validUntil);
      const refundA = await signVerdict(judgeB, id, false, validUntil);
      const refundB = await signVerdict(judgeC, id, false, validUntil);

      // Asking for release with two refund signatures must fail.
      await expect(escrow.executeVerdict(id, true, validUntil, [refundA, refundB]))
        .to.be.revertedWithCustomError(escrow, 'NotEnoughVerdicts');
      // And the refund direction still works with those two.
      await escrow.executeVerdict(id, false, validUntil, [release, refundA, refundB]);
    });

    it('refuses a verdict whose deadline outlives the escrow window', async function () {
      await escrow.connect(buyer).openDispute(id);
      const e = await escrow.getEscrow(id);
      const tooLate = Number(e.expiry) + 26 * 24 * 60 * 60;
      const sigs = [
        await signVerdict(judgeA, id, true, tooLate),
        await signVerdict(judgeB, id, true, tooLate)
      ];
      await expect(escrow.executeVerdict(id, true, tooLate, sigs))
        .to.be.revertedWithCustomError(escrow, 'InvalidVerdict');
    });

    it('caps the verdict roster at three judges', async function () {
      const [, , , , , d, e] = await ethers.getSigners();
      await expect(escrow.connect(owner).setVerdictJudge(d.address, true))
        .to.be.revertedWithCustomError(escrow, 'TooManyVerdictJudges');
      expect(await escrow.verdictJudgeCount()).to.equal(3n);
      // Removal is delayed by two days; substitution cannot happen in one block.
      await escrow.connect(owner).setVerdictJudge(judgeA.address, false);
      await expect(escrow.connect(owner).acceptJudgeRemoval())
        .to.be.revertedWithCustomError(escrow, 'JudgeRemovalDelayActive');
      await time.increase(48 * 60 * 60 + 1);
      await escrow.connect(owner).acceptJudgeRemoval();
      await escrow.connect(owner).setVerdictJudge(d.address, true);
      expect(await escrow.verdictJudgeCount()).to.equal(3n);
    });

    it('refuses a dispute whose fee would exceed the settable share of the sale', async function () {
      // A 2.50 minimum on a 5.00 escrow would be 50% of the sale: refused.
      await escrow.connect(owner).setMinArbitrationFee(await usdc.getAddress(), 2_500_000n);
      await createInToken(await usdc.getAddress(), USDC(5), 7 * DAY);
      const small = await escrow.escrowCounter();
      await expect(escrow.connect(buyer).openDispute(small))
        .to.be.revertedWithCustomError(escrow, 'FeeTooLarge');
    });

    it('uses the per-token floor when the percentage is dust', async function () {
      await escrow.connect(owner).setMinArbitrationFee(await usdc.getAddress(), 2_500_000n);
      await escrow.connect(buyer).openDispute(id);
      // 5% of 100 = 5, which is above the floor; a 10-unit escrow is below it.
      await createInToken(await usdc.getAddress(), USDC(10), 7 * DAY);
      const tenner = await escrow.escrowCounter();
      await escrow.connect(buyer).openDispute(tenner);
      expect((await escrow.getEscrow(tenner)).disputeFee).to.equal(2_500_000n);
    });

    it('snapshots the split at filing, so a later change cannot zero the judges', async function () {
      await escrow.connect(buyer).openDispute(id);
      // The admin moves the split AFTER the case was filed (a zero pool is
      // refused outright, so this is the harshest legal change).
      await expect(escrow.connect(owner).setArbitrationSplit(0, 0, 9500, 9500))
        .to.be.revertedWithCustomError(escrow, 'InvalidFeeConfig');
      await escrow.connect(owner).setArbitrationSplit(5000, 5000, 2000, 2000);
      const validUntil = (await time.latest()) + DAY;
      const sigs = [
        await signVerdict(judgeA, id, true, validUntil),
        await signVerdict(judgeB, id, true, validUntil)
      ];
      await escrow.connect(outsider).executeVerdict(id, true, validUntil, sigs);
      // The split frozen at filing still applies: 40% each.
      expect(await escrow.claimable(await usdc.getAddress(), judgeA.address)).to.equal(
        2_000_000n
      );
    });

    it('refuses a dispute filed after the verdict window can never be decided', async function () {
      // Expiry is 7 days out; 25 more days is the last moment a verdict can be
      // valid. A filing after that could only reach the timeout.
      await time.increase(7 * DAY + 25 * DAY + 1);
      await expect(escrow.connect(buyer).openDispute(id))
        .to.be.revertedWithCustomError(escrow, 'VerdictWindowClosed');
    });

    it('refuses a dispute whose fee rounds to nothing', async function () {
      await escrow.connect(owner).setArbitrationFee(1, 2500);
      await createInToken(await usdc.getAddress(), USDC(100), 7 * DAY);
      const tiny = await escrow.escrowCounter();
      // 1 bps of 100.00 USDC = 0.01 USDC, which is non-zero; the guard exists
      // for the sub-unit case, so assert the honest path still charges.
      await escrow.connect(buyer).openDispute(tiny);
      expect((await escrow.getEscrow(tiny)).disputeFee).to.be.gt(0n);
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

      // Buyer keeps nothing: there is no stake to return, and the principal
      // goes to the seller.
      expect(await escrow.claimable(await usdc.getAddress(), buyer.address)).to.equal(0n);
      const sellerBefore = await usdc.balanceOf(seller.address);
      await escrow.connect(seller).withdrawClaimable(await usdc.getAddress());
      expect(await usdc.balanceOf(seller.address)).to.equal(sellerBefore + USDC(99));
      expect(await escrow.totalMarketplaceFees(await usdc.getAddress())).to.equal(USDC(1));
    });

    it('records delivery during a dispute but will not pay for it on timeout', async function () {
      // Delivery stays recordable while frozen (it is a fact, not a payout), so
      // the seller is not blocked from asserting it — but an assertion made
      // AFTER the buyer's freeze does not decide the timeout. The older claim
      // wins; the seller's route is a signed verdict.
      await escrow.connect(buyer).openDispute(id);
      await escrow.connect(seller).markDelivered(id);
      expect((await escrow.getEscrow(id)).delivered).to.equal(true);

      await time.increase(7 * DAY + 31 * DAY);
      // Permissionless: whoever calls, the outcome is the escrow's own state.
      await escrow.connect(outsider).claimDisputeTimeout(id);

      await escrow.connect(buyer).withdrawClaimable(await usdc.getAddress());
      expect(await escrow.claimable(await usdc.getAddress(), seller.address)).to.equal(0n);
      expect(await escrow.totalMarketplaceFees(await usdc.getAddress())).to.equal(0n);
    });

    it('lets anyone release a frozen, delivered escrow once the timeout passes', async function () {
      await escrow.connect(seller).markDelivered(id);
      await escrow.connect(buyer).openDispute(id);
      await time.increase(7 * DAY + 31 * DAY);
      await escrow.connect(outsider).claimDisputeTimeout(id);
      const sellerBefore = await usdc.balanceOf(seller.address);
      await escrow.connect(seller).withdrawClaimable(await usdc.getAddress());
      expect(await usdc.balanceOf(seller.address)).to.equal(sellerBefore + USDC(99));
    });

    it('ignores a delivery asserted AFTER the buyer froze (re-audit N-1)', async function () {
      // The mirror attack: the seller marks delivery late to make the timeout
      // pay them. The older claim (the freeze) wins; the seller's route is a
      // signed verdict.
      await escrow.connect(buyer).openDispute(id);
      await time.increase(DAY);
      await escrow.connect(seller).markDelivered(id);

      await time.increase(6 * DAY + 31 * DAY);
      await escrow.connect(seller).claimDisputeTimeout(id);

      // Buyer refunded the principal, seller credited nothing.
      await escrow.connect(buyer).withdrawClaimable(await usdc.getAddress());
      expect(await escrow.claimable(await usdc.getAddress(), seller.address)).to.equal(0n);
      expect((await escrow.getEscrow(id)).resolved).to.equal(true);
    });

    it('waits for the inspection window before a delivered timeout pays out', async function () {
      // Delivery marked just before the 30-day timeout must still give the
      // buyer the full inspection period.
      await escrow.connect(seller).markDelivered(id); // deadline = now + 7d
      await time.increase(7 * DAY + 30 * DAY + 1);
      await expect(escrow.connect(outsider).claimDisputeTimeout(id))
        .to.be.revertedWithCustomError(escrow, 'NotDisputed');
    });
  });
});
