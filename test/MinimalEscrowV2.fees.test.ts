/**
 * MinimalEscrow V2 — Fee-path test suite (2026-06-12 redeploy)
 *
 * Covers ONLY the v2 additions (the ~100 pre-existing tests in
 * MinimalEscrow.test.js / .comprehensive / .adversarial cover the rest):
 *
 * 1. Anti-fee-wash referrer validation at createEscrowWithReferrers
 * 2. Referred release → real UnifiedFeeVault split (0.50% referral
 *    70/20/10 referrer/referrer2/ODDAO; 0.25% tx; 0.25% listing→ODDAO)
 *    with exact-wei accounting summing to the 1% fee
 * 3. Unreferred release (legacy createEscrow) → referral component to ODDAO
 * 4. Vault-revert fallback (paused vault / missing DEPOSITOR_ROLE) →
 *    release still succeeds, full fee direct to vault, allowance zeroed
 * 5. Internal commit-reveal arbitration → 5% fee capped at stakes,
 *    70% to resolving arbitrator (claimable), 30% to vault, exact wei
 * 6. External OmniArbitration path (mock) → 100% of stake fee to vault
 *
 * Integration-first: deploys the REAL UnifiedFeeVault (UUPS proxy with
 * linked MarketplaceFeeSplitter) — no fee-splitting mocks.
 */

/* eslint-disable @typescript-eslint/no-var-requires */
const { expect } = require('chai');
const { ethers, upgrades } = require('hardhat');
const { time } = require('@nomicfoundation/hardhat-network-helpers');

describe('MinimalEscrow V2 — referral + arbitration fee paths', function () {
  let escrow: any;
  let vault: any;
  let xom: any;
  let pxom: any;
  let owner: any;
  let buyer: any;
  let seller: any;
  let referrer: any;
  let referrer2: any;
  let arbitrator: any;
  let stakingPool: any;
  let protocolTreasury: any;

  const FEE_BPS = 100n; // 1%
  const BPS = 10_000n;
  const DAY = 24 * 60 * 60;

  /** Compute the expected vault-side split of a 1% fee. */
  function splitFee(fee: bigint): {
    txStaking: bigint;
    txProtocol: bigint;
    refPrimary: bigint;
    refSecondary: bigint;
    expectedBridge: bigint;
  } {
    const txFee = fee / 4n;
    const refFee = fee / 2n;
    const listFee = fee - txFee - refFee;
    const txOddao = (txFee * 7000n) / BPS;
    const txStaking = (txFee * 2000n) / BPS;
    const txProtocol = txFee - txOddao - txStaking;
    const refPrimary = (refFee * 7000n) / BPS;
    const refSecondary = (refFee * 2000n) / BPS;
    const refOddao = refFee - refPrimary - refSecondary;
    return {
      txStaking,
      txProtocol,
      refPrimary,
      refSecondary,
      // listing nodes are zero at escrow level → whole listFee to ODDAO
      expectedBridge: txOddao + refOddao + listFee
    };
  }

  beforeEach(async function () {
    [
      owner,
      buyer,
      seller,
      referrer,
      referrer2,
      arbitrator,
      stakingPool,
      protocolTreasury
    ] = await ethers.getSigners();

    // Real-ish tokens with open mint for fixtures
    const MockERC20 = await ethers.getContractFactory('MockERC20');
    xom = await MockERC20.deploy('OmniCoin', 'XOM');
    await xom.waitForDeployment();
    pxom = await MockERC20.deploy('Private OmniCoin', 'pXOM');
    await pxom.waitForDeployment();

    // REAL UnifiedFeeVault behind a UUPS proxy with all linked libraries.
    // The vault links MarketplaceFeeSplitter + CoinAgnosticSettlement +
    // PrioritySettlement; the leaf libraries (RoyaltyResolver,
    // SwapExecutor, BuyIntentValidator) link INTO the settlement
    // libraries (sale-time priority-surcharge refactor, EIP-170 budget).
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const deployLib = async (name: string, opts?: any): Promise<string> => {
      const f = await ethers.getContractFactory(name, opts);
      const lib = await f.deploy();
      await lib.waitForDeployment();
      return lib.getAddress();
    };
    const marketplaceFeeSplitter = await deployLib('MarketplaceFeeSplitter');
    const coinAgnosticSettlement = await deployLib('CoinAgnosticSettlement', {
      libraries: {
        MarketplaceFeeSplitter: marketplaceFeeSplitter,
        RoyaltyResolver: await deployLib('RoyaltyResolver'),
        SwapExecutor: await deployLib('SwapExecutor'),
      },
    });
    const prioritySettlement = await deployLib('PrioritySettlement', {
      libraries: {
        CoinAgnosticSettlement: coinAgnosticSettlement,
        BuyIntentValidator: await deployLib('BuyIntentValidator'),
      },
    });
    const Vault = await ethers.getContractFactory('UnifiedFeeVault', {
      libraries: {
        MarketplaceFeeSplitter: marketplaceFeeSplitter,
        CoinAgnosticSettlement: coinAgnosticSettlement,
        PrioritySettlement: prioritySettlement,
        NftSellerConsent: await deployLib('NftSellerConsent'),
        BridgeDestinationLib: await deployLib('BridgeDestinationLib'),
      },
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

    // Escrow under test (registry = EOA → first-sale bridge short-circuits)
    const MinimalEscrow = await ethers.getContractFactory('MinimalEscrow');
    escrow = await MinimalEscrow.connect(owner).deploy(
      await xom.getAddress(),
      await pxom.getAddress(),
      owner.address, // registry (codeless → _recordFirstSale no-op)
      await vault.getAddress(),
      FEE_BPS,
      ethers.ZeroAddress // no forwarder in unit tests
    );
    await escrow.waitForDeployment();

    // The deploy script grants the escrow DEPOSITOR_ROLE on the vault
    const DEPOSITOR_ROLE = await vault.DEPOSITOR_ROLE();
    await vault
      .connect(owner)
      .grantRole(DEPOSITOR_ROLE, await escrow.getAddress());

    await escrow.connect(owner).addArbitrator(arbitrator.address);

    // Fund + approve buyer and seller
    await xom.mint(buyer.address, ethers.parseEther('10000'));
    await xom.mint(seller.address, ethers.parseEther('10000'));
    await xom
      .connect(buyer)
      .approve(await escrow.getAddress(), ethers.MaxUint256);
    await xom
      .connect(seller)
      .approve(await escrow.getAddress(), ethers.MaxUint256);
  });

  /** Create a referred escrow and return its id. */
  async function createReferred(amount: bigint): Promise<bigint> {
    await escrow
      .connect(buyer)
      .createEscrowWithReferrers(
        seller.address,
        amount,
        7 * DAY,
        referrer.address,
        referrer2.address
      );
    return escrow.escrowCounter();
  }

  /** Raise + fully stake a dispute on `escrowId` (buyer commits). */
  async function raiseDispute(escrowId: bigint): Promise<void> {
    await time.increase(25 * 60 * 60); // past ARBITRATOR_DELAY
    const nonce = 12345n;
    const commitment = ethers.solidityPackedKeccak256(
      ['uint256', 'uint256', 'address'],
      [escrowId, nonce, buyer.address]
    );
    await escrow.connect(buyer).commitDispute(escrowId, commitment);
    await escrow.connect(buyer).revealDispute(escrowId, nonce);
    await escrow.connect(seller).postCounterpartyStake(escrowId);
  }

  // ──────────────────────────────────────────────────────────────────
  // 1. Anti-fee-wash validation
  // ──────────────────────────────────────────────────────────────────

  describe('createEscrowWithReferrers anti-fee-wash', function () {
    const A = ethers.parseEther('10');

    it('rejects referrer == buyer', async function () {
      await expect(
        escrow
          .connect(buyer)
          .createEscrowWithReferrers(
            seller.address, A, 7 * DAY, buyer.address, ethers.ZeroAddress
          )
      ).to.be.revertedWithCustomError(escrow, 'BadReferrer');
    });

    it('rejects referrer == seller', async function () {
      await expect(
        escrow
          .connect(buyer)
          .createEscrowWithReferrers(
            seller.address, A, 7 * DAY, seller.address, ethers.ZeroAddress
          )
      ).to.be.revertedWithCustomError(escrow, 'BadReferrer');
    });

    it('rejects referrer2 == buyer / seller / referrer', async function () {
      for (const bad of [buyer.address, seller.address, referrer.address]) {
        await expect(
          escrow
            .connect(buyer)
            .createEscrowWithReferrers(
              seller.address, A, 7 * DAY, referrer.address, bad
            )
        ).to.be.revertedWithCustomError(escrow, 'BadReferrer');
      }
    });

    it('allows zero referrers and records non-zero ones', async function () {
      // both zero — no event, no storage
      await escrow
        .connect(buyer)
        .createEscrowWithReferrers(
          seller.address, A, 7 * DAY, ethers.ZeroAddress, ethers.ZeroAddress
        );
      const id0 = await escrow.escrowCounter();
      const refs0 = await escrow.escrowReferrers(id0);
      expect(refs0.referrer).to.equal(ethers.ZeroAddress);
      expect(refs0.referrer2).to.equal(ethers.ZeroAddress);

      // both set — event + storage
      await expect(
        escrow
          .connect(buyer)
          .createEscrowWithReferrers(
            seller.address, A, 7 * DAY, referrer.address, referrer2.address
          )
      )
        .to.emit(escrow, 'EscrowReferrersSet')
        .withArgs(id0 + 1n, referrer.address, referrer2.address);
      const refs1 = await escrow.escrowReferrers(id0 + 1n);
      expect(refs1.referrer).to.equal(referrer.address);
      expect(refs1.referrer2).to.equal(referrer2.address);
    });
  });

  // ──────────────────────────────────────────────────────────────────
  // 2. Referred release → vault split, exact wei
  // ──────────────────────────────────────────────────────────────────

  describe('referred release', function () {
    it('splits the 1% fee via the vault with exact wei accounting', async function () {
      // Odd amount to exercise rounding paths
      const A = ethers.parseEther('123') + 7n;
      const fee = A / 100n;
      const sellerNet = A - fee;
      const s = splitFee(fee);

      const id = await createReferred(A);
      const sellerBefore = await xom.balanceOf(seller.address);
      const stakingBefore = await xom.balanceOf(stakingPool.address);
      const protocolBefore = await xom.balanceOf(protocolTreasury.address);

      await expect(escrow.connect(buyer).releaseFunds(id))
        .to.emit(escrow, 'MarketplaceFeeCollected')
        .withArgs(id, await vault.getAddress(), fee);

      // Seller paid exactly amount - 1%
      expect(await xom.balanceOf(seller.address)).to.equal(
        sellerBefore + sellerNet
      );

      // Referral component: 0.50% of sale → 70/20/10
      const xomAddr = await xom.getAddress();
      expect(await vault.pendingClaims(referrer.address, xomAddr)).to.equal(
        s.refPrimary
      );
      expect(await vault.pendingClaims(referrer2.address, xomAddr)).to.equal(
        s.refSecondary
      );

      // Transaction component pushes: staking + protocol
      expect(await xom.balanceOf(stakingPool.address)).to.equal(
        stakingBefore + s.txStaking
      );
      expect(await xom.balanceOf(protocolTreasury.address)).to.equal(
        protocolBefore + s.txProtocol
      );

      // ODDAO bridge accrual: tx 70% + referral 10% + full listing 0.25%
      expect(await vault.pendingForBridge(xomAddr)).to.equal(s.expectedBridge);

      // Exact-sum invariant: every leg of the fee accounted, no dust lost
      expect(
        s.refPrimary +
          s.refSecondary +
          s.txStaking +
          s.txProtocol +
          s.expectedBridge
      ).to.equal(fee);
      expect(fee + sellerNet).to.equal(A);

      // Escrow retains zero allowance toward the vault
      expect(
        await xom.allowance(await escrow.getAddress(), await vault.getAddress())
      ).to.equal(0n);

      // No XOM stranded in the escrow contract
      expect(await xom.balanceOf(await escrow.getAddress())).to.equal(0n);
    });

    it('routes the referrer2 share to ODDAO when only referrer is set', async function () {
      const A = ethers.parseEther('100');
      const fee = A / 100n;
      const s = splitFee(fee);

      await escrow
        .connect(buyer)
        .createEscrowWithReferrers(
          seller.address, A, 7 * DAY, referrer.address, ethers.ZeroAddress
        );
      const id = await escrow.escrowCounter();
      await escrow.connect(buyer).releaseFunds(id);

      const xomAddr = await xom.getAddress();
      expect(await vault.pendingClaims(referrer.address, xomAddr)).to.equal(
        s.refPrimary
      );
      // referrer2 share (0.50% * 20%) joins ODDAO bridge
      expect(await vault.pendingForBridge(xomAddr)).to.equal(
        s.expectedBridge + s.refSecondary
      );
    });
  });

  // ──────────────────────────────────────────────────────────────────
  // 3. Unreferred release (legacy ABI)
  // ──────────────────────────────────────────────────────────────────

  describe('unreferred release (legacy createEscrow)', function () {
    it('routes the whole referral component to ODDAO', async function () {
      const A = ethers.parseEther('50');
      const fee = A / 100n;
      const s = splitFee(fee);

      await escrow.connect(buyer).createEscrow(seller.address, A, 7 * DAY);
      const id = await escrow.escrowCounter();
      await escrow.connect(buyer).releaseFunds(id);

      const xomAddr = await xom.getAddress();
      expect(await vault.pendingClaims(referrer.address, xomAddr)).to.equal(0n);
      expect(await vault.pendingClaims(referrer2.address, xomAddr)).to.equal(0n);
      // referral 70% + 20% + 10% all land in ODDAO bridge
      expect(await vault.pendingForBridge(xomAddr)).to.equal(
        s.expectedBridge + s.refPrimary + s.refSecondary
      );
      expect(await xom.balanceOf(seller.address)).to.equal(
        ethers.parseEther('10000') + A - fee
      );
    });
  });

  // ──────────────────────────────────────────────────────────────────
  // 4. Vault-revert fallback
  // ──────────────────────────────────────────────────────────────────

  describe('vault fallback', function () {
    it('release succeeds with direct fee transfer when the vault is paused', async function () {
      const A = ethers.parseEther('20');
      const fee = A / 100n;
      const id = await createReferred(A);

      await vault.connect(owner).pause();
      const vaultBefore = await xom.balanceOf(await vault.getAddress());

      await expect(escrow.connect(buyer).releaseFunds(id))
        .to.emit(escrow, 'MarketplaceFeeCollected')
        .withArgs(id, await vault.getAddress(), fee);

      const xomAddr = await xom.getAddress();
      // Fee arrived as a raw transfer (undistributed) — no claims created
      expect(await xom.balanceOf(await vault.getAddress())).to.equal(
        vaultBefore + fee
      );
      expect(await vault.pendingClaims(referrer.address, xomAddr)).to.equal(0n);
      expect(await vault.pendingForBridge(xomAddr)).to.equal(0n);
      // Allowance cleaned up after the failed deposit attempt
      expect(
        await xom.allowance(await escrow.getAddress(), await vault.getAddress())
      ).to.equal(0n);
    });

    it('release succeeds with direct fee transfer when DEPOSITOR_ROLE is missing', async function () {
      const A = ethers.parseEther('20');
      const fee = A / 100n;
      const id = await createReferred(A);

      const DEPOSITOR_ROLE = await vault.DEPOSITOR_ROLE();
      await vault
        .connect(owner)
        .revokeRole(DEPOSITOR_ROLE, await escrow.getAddress());
      const vaultBefore = await xom.balanceOf(await vault.getAddress());

      await escrow.connect(buyer).releaseFunds(id);

      expect(await xom.balanceOf(await vault.getAddress())).to.equal(
        vaultBefore + fee
      );
      expect(
        await xom.allowance(await escrow.getAddress(), await vault.getAddress())
      ).to.equal(0n);
    });
  });

  // ──────────────────────────────────────────────────────────────────
  // 5. Internal commit-reveal arbitration → 70/30
  // ──────────────────────────────────────────────────────────────────

  describe('internal arbitration fee split', function () {
    it('pays 70% to the resolving arbitrator and 30% to the vault, exact wei', async function () {
      const A = ethers.parseEther('100');
      const fee = A / 100n; // marketplace fee on release-to-seller
      const stake = (A * 250n) / BPS; // 2.5% per party
      const id = await createReferred(A);

      await raiseDispute(id);

      // 5% arbitration fee (5 XOM) == stakes (2.5 + 2.5) → not capped
      const totalCollected = stake * 2n;
      const arbShare = (totalCollected * 7000n) / BPS;
      const vaultShare = totalCollected - arbShare;

      const vaultBalBefore = await xom.balanceOf(await vault.getAddress());

      // 2-of-3: seller + arbitrator vote release
      await escrow.connect(seller).vote(id, true);
      await expect(escrow.connect(arbitrator).vote(id, true))
        .to.emit(escrow, 'ArbitrationFeeCollected')
        .withArgs(id, totalCollected, arbShare);

      const xomAddr = await xom.getAddress();

      // Arbitrator share is pull-pattern claimable
      expect(await escrow.claimable(xomAddr, arbitrator.address)).to.equal(
        arbShare
      );

      // Vault received: 30% arbitration share + the 1% marketplace fee
      // (referral-aware deposit pulls the fee into the vault too)
      expect(await xom.balanceOf(await vault.getAddress())).to.equal(
        vaultBalBefore +
          vaultShare +
          fee -
          // staking + protocol pushes leave the vault immediately
          splitFee(fee).txStaking -
          splitFee(fee).txProtocol
      );

      // Seller proceeds (pull pattern) = A - 1% fee
      expect(await escrow.claimable(xomAddr, seller.address)).to.equal(
        A - fee
      );

      // Stakes fully consumed — nothing left to return
      expect(await escrow.disputeStakes(id, buyer.address)).to.equal(0n);
      expect(await escrow.disputeStakes(id, seller.address)).to.equal(0n);

      // Exact-sum invariant on the arbitration fee
      expect(arbShare + vaultShare).to.equal(totalCollected);

      // Arbitrator can actually withdraw
      await escrow.connect(arbitrator).withdrawClaimable(xomAddr);
      expect(await xom.balanceOf(arbitrator.address)).to.equal(arbShare);
    });

    it('caps the fee at posted stakes when only the disputer staked', async function () {
      const A = ethers.parseEther('100');
      const stake = (A * 250n) / BPS;
      const id = await createReferred(A);

      // Buyer commits + reveals but seller never posts a counter-stake
      await time.increase(25 * 60 * 60);
      const nonce = 999n;
      const commitment = ethers.solidityPackedKeccak256(
        ['uint256', 'uint256', 'address'],
        [id, nonce, buyer.address]
      );
      await escrow.connect(buyer).commitDispute(id, commitment);
      await escrow.connect(buyer).revealDispute(id, nonce);

      const totalCollected = stake; // only buyer's stake available
      const arbShare = (totalCollected * 7000n) / BPS;

      await escrow.connect(buyer).vote(id, false);
      await expect(escrow.connect(arbitrator).vote(id, false))
        .to.emit(escrow, 'ArbitrationFeeCollected')
        .withArgs(id, totalCollected, arbShare);

      const xomAddr = await xom.getAddress();
      expect(await escrow.claimable(xomAddr, arbitrator.address)).to.equal(
        arbShare
      );
      // Refund to buyer: full principal, no marketplace fee
      expect(await escrow.claimable(xomAddr, buyer.address)).to.equal(A);
    });
  });

  // ──────────────────────────────────────────────────────────────────
  // 6. External OmniArbitration path → 100% to vault
  // ──────────────────────────────────────────────────────────────────

  describe('external arbitration (resolveDispute)', function () {
    it('routes the full stake fee to the vault (panel paid by OmniArbitration)', async function () {
      const A = ethers.parseEther('100');
      const fee = A / 100n;
      const stake = (A * 250n) / BPS;
      const id = await createReferred(A);
      await raiseDispute(id);

      const Mock = await ethers.getContractFactory(
        'MockEscrowArbitrationResolver'
      );
      const mock = await Mock.deploy();
      await mock.waitForDeployment();
      await escrow
        .connect(owner)
        .setArbitrationContract(await mock.getAddress());

      const totalCollected = stake * 2n;
      const vaultBalBefore = await xom.balanceOf(await vault.getAddress());

      await expect(mock.resolve(await escrow.getAddress(), id, true))
        .to.emit(escrow, 'ArbitrationFeeCollected')
        .withArgs(id, totalCollected, 0n); // arbitratorShare == 0

      const xomAddr = await xom.getAddress();
      // Internal arbitrator gets nothing on the external path
      expect(await escrow.claimable(xomAddr, arbitrator.address)).to.equal(0n);

      // Vault got 100% of the stake fee + the 1% marketplace fee
      // (minus the staking/protocol pushes that exit immediately)
      expect(await xom.balanceOf(await vault.getAddress())).to.equal(
        vaultBalBefore +
          totalCollected +
          fee -
          splitFee(fee).txStaking -
          splitFee(fee).txProtocol
      );

      // Referral attribution still applied on the released marketplace fee
      expect(
        await vault.pendingClaims(referrer.address, xomAddr)
      ).to.equal(splitFee(fee).refPrimary);
    });
  });
});
