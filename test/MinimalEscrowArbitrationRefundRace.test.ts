/**
 * MinimalEscrow ↔ OmniArbitration — refund-race integration suite
 * (2026-07-04 fix)
 *
 * Reproduces and proves the fix for the live L1 public-escrow refund race:
 *
 *   Before the fix, opening a judge-panel dispute in
 *   OmniArbitration.createDispute did NOT mark MinimalEscrow.disputed, so a
 *   buyer could self-refund an expired escrow WHILE the panel deliberated.
 *   The eventual resolveDispute() callback then reverted (swallowed as the
 *   unmonitored ResolutionCallFailed event) and a winning seller lost
 *   principal.
 *
 *   The fix wires createDispute → escrow.markDisputed(escrowId), which sets
 *   `disputed` and makes refundBuyer (and the other party-unilateral exits)
 *   revert until the panel resolves.
 *
 * Integration-first: deploys the REAL MinimalEscrow + REAL OmniArbitration
 * (UUPS) with the real OmniCoin token; only OmniParticipation is mocked.
 */

/* eslint-disable @typescript-eslint/no-var-requires */
const { expect } = require('chai');
const { ethers, upgrades } = require('hardhat');
const { time } = require('@nomicfoundation/hardhat-network-helpers');

describe('MinimalEscrow ↔ OmniArbitration — refund race', function () {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  let escrow: any;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  let arbitration: any;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  let xom: any;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  let pxom: any;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  let participation: any;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  let owner: any;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  let feeVault: any;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  let registry: any;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  let buyer: any;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  let seller: any;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  let other: any;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  let arbitrators: any[];
  // Map arbitrator address → signer, to vote as the selected panel.
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const bySigner: Record<string, any> = {};

  const ESCROW_AMOUNT = ethers.parseEther('1000');
  const STAKE = ethers.parseEther('10000');
  const FEE_BPS = 100n; // 1% marketplace fee
  const BPS = 10_000n;
  const HOUR = 3600;
  const DAY = 24 * HOUR;
  // Duration long enough that ARBITRATOR_DELAY (24h) elapses before expiry,
  // so absent a dispute the buyer's post-expiry self-refund WOULD succeed.
  const DURATION = 25 * HOUR;

  const VoteType = { None: 0, Release: 1, Refund: 2 };

  /** Create a public XOM escrow as `buyer`; return its id. */
  async function createEscrow(): Promise<bigint> {
    const tx = await escrow
      .connect(buyer)
      .createEscrow(seller.address, ESCROW_AMOUNT, DURATION);
    const receipt = await tx.wait();
    const ev = receipt.logs.find(
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      (l: any) => l.fragment && l.fragment.name === 'EscrowCreated'
    );
    return ev.args.escrowId;
  }

  /**
   * Finalize arbitrator selection for a dispute and return the selected
   * 3-member panel addresses (read from the emitted event).
   */
  async function finalizeSelection(disputeId: bigint): Promise<string[]> {
    // Two-phase commit: mine 2 blocks so the blockhash seed is available.
    await ethers.provider.send('evm_mine', []);
    await ethers.provider.send('evm_mine', []);
    const tx = await arbitration
      .connect(buyer)
      .finalizeArbitratorSelection(disputeId);
    const receipt = await tx.wait();
    const ev = receipt.logs.find(
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      (l: any) =>
        l.fragment && l.fragment.name === 'ArbitratorSelectionFinalized'
    );
    return ev.args.arbitrators;
  }

  beforeEach(async function () {
    const signers = await ethers.getSigners();
    [owner, feeVault, registry, buyer, seller, other] = signers;
    arbitrators = signers.slice(6, 11); // 5 arbitrators
    for (const a of arbitrators) {
      bySigner[a.address] = a;
    }

    // ── Real OmniCoin tokens (all supply minted to owner on initialize) ──
    const Token = await ethers.getContractFactory('OmniCoin');
    xom = await Token.deploy(ethers.ZeroAddress);
    await xom.initialize();
    pxom = await Token.deploy(ethers.ZeroAddress);
    await pxom.initialize();

    // ── Real MinimalEscrow (feeVault is an EOA → fee routing hits the
    //    documented direct-transfer fallback; forwarder disabled) ──
    const Escrow = await ethers.getContractFactory('MinimalEscrow');
    escrow = await Escrow.deploy(
      xom.target,
      pxom.target,
      registry.address,
      feeVault.address,
      FEE_BPS,
      ethers.ZeroAddress
    );

    // ── Mock participation + real OmniArbitration (UUPS) ──
    const Participation = await ethers.getContractFactory(
      'MockArbitrationParticipation'
    );
    participation = await Participation.deploy();

    const Arbitration = await ethers.getContractFactory('OmniArbitration');
    arbitration = await upgrades.deployProxy(
      Arbitration,
      [
        participation.target,
        escrow.target,
        xom.target,
        feeVault.address
      ],
      {
        initializer: 'initialize',
        kind: 'uups',
        constructorArgs: [ethers.ZeroAddress]
      }
    );

    // ── B4 connect: authorize the panel to drive this escrow ──
    await escrow.setArbitrationContract(arbitration.target);

    // ── Register 5 qualified arbitrators ──
    for (const a of arbitrators) {
      await participation.setCanBeValidator(a.address, true);
      await participation.setTotalScore(a.address, 75);
      await xom.transfer(a.address, STAKE);
      await xom.connect(a).approve(arbitration.target, STAKE);
      await arbitration.connect(a).registerArbitrator(STAKE);
    }

    // ── Fund buyer (escrow principal + 5% dispute fee) ──
    await xom.transfer(buyer.address, ethers.parseEther('2000'));
    await xom.connect(buyer).approve(escrow.target, ethers.MaxUint256);
    await xom.connect(buyer).approve(arbitration.target, ethers.MaxUint256);
  });

  it('createDispute marks the escrow disputed (closes the race window)', async function () {
    const id = await createEscrow();

    await expect(arbitration.connect(buyer).createDispute(id))
      .to.emit(escrow, 'EscrowMarkedDisputed')
      .withArgs(id);

    const e = await escrow.getEscrow(id);
    expect(e.disputed).to.equal(true);
    expect(e.resolved).to.equal(false);
  });

  it('blocks the buyer refund race, then the panel pays the winning seller', async function () {
    const id = await createEscrow();

    // Open a panel dispute → escrow is now marked disputed.
    await arbitration.connect(buyer).createDispute(id);
    const disputeId = (await arbitration.nextDisputeId()) - 1n;

    // Advance past expiry AND ARBITRATOR_DELAY — absent the dispute the
    // buyer's self-refund would now succeed.
    await time.increase(26 * HOUR);

    // THE FIX: buyer cannot drain the escrow while the panel deliberates.
    await expect(
      escrow.connect(buyer).refundBuyer(id)
    ).to.be.revertedWithCustomError(escrow, 'AlreadyDisputed');

    // Principal is still safely held by the escrow contract.
    expect(await xom.balanceOf(escrow.target)).to.equal(ESCROW_AMOUNT);

    // Panel resolves RELEASE (seller wins).
    const panel = await finalizeSelection(disputeId);
    await arbitration
      .connect(bySigner[panel[0]])
      .castVote(disputeId, VoteType.Release);
    await arbitration
      .connect(bySigner[panel[1]])
      .castVote(disputeId, VoteType.Release);

    // 2-of-3 majority resolves and moves the escrow immediately (no appeal).

    // Seller receives principal minus the 1% marketplace fee, via pull.
    const fee = (ESCROW_AMOUNT * FEE_BPS) / BPS;
    const expectedSeller = ESCROW_AMOUNT - fee;

    const before = await xom.balanceOf(seller.address);
    await escrow.connect(seller).withdrawClaimable(xom.target);
    const after = await xom.balanceOf(seller.address);

    expect(after - before).to.equal(expectedSeller);
    expect((await escrow.getEscrow(id)).resolved).to.equal(true);
  });

  it('reverts createDispute against an already-settled escrow', async function () {
    const id = await createEscrow();
    // Buyer releases to seller (happy path) → escrow resolved, amount zeroed.
    await escrow.connect(buyer).releaseFunds(id);

    // No panel dispute can open against settled funds: getAmount() is now 0,
    // so createDispute's zero-fee guard fires first. (markDisputed's own
    // AlreadyResolved check is defense-in-depth behind this first-line guard.)
    await expect(
      arbitration.connect(buyer).createDispute(id)
    ).to.be.revertedWithCustomError(arbitration, 'DisputedAmountTooSmall');
  });

  it('markDisputed is callable only by the authorized arbitration contract', async function () {
    const id = await createEscrow();
    await expect(
      escrow.connect(other).markDisputed(id)
    ).to.be.revertedWithCustomError(escrow, 'OnlyArbitrationContract');
    await expect(
      escrow.connect(buyer).markDisputed(id)
    ).to.be.revertedWithCustomError(escrow, 'OnlyArbitrationContract');
  });

  it('defers the internal counterparty-stake path to the panel', async function () {
    const id = await createEscrow();
    await arbitration.connect(buyer).createDispute(id);
    await time.increase(60 * DAY);

    // The counterparty-stake action must defer to OmniArbitration for a public
    // panel escrow (the panel tracks no escrow-side stakes) — else it would
    // re-open a unilateral-exit surface.
    await expect(
      escrow.connect(seller).postCounterpartyStake(id)
    ).to.be.revertedWithCustomError(escrow, 'UseArbitrationContract');
  });

  it('rejects a unilateral release on a disputed escrow (parity fix)', async function () {
    const id = await createEscrow();
    await arbitration.connect(buyer).createDispute(id);

    // releaseFunds must reject a disputed escrow with an explicit, actionable
    // error — mirroring refundBuyer / releaseFundsViaContract — rather than
    // silently succeeding as a no-op. Principal stays held by the escrow.
    await expect(
      escrow.connect(buyer).releaseFunds(id)
    ).to.be.revertedWithCustomError(escrow, 'AlreadyDisputed');
    expect(await xom.balanceOf(escrow.target)).to.equal(ESCROW_AMOUNT);
  });

  it('blocks releaseExpiredToSeller once a panel dispute is opened, even past the inspection window', async function () {
    // A1 (FIX_LAUNCH.md Lane A): the permissionless seller-release path must
    // defer to the dispute path the moment a panel dispute is opened, exactly
    // like releaseFunds / refundBuyer above — it must not become a fourth way
    // to bypass an active dispute. Seller marks delivered, THEN a dispute is
    // opened before the inspection window elapses, and the window is left to
    // elapse anyway to prove the guard is `disputed`, not merely `!delivered`.
    const id = await createEscrow();
    await escrow.connect(seller).markDelivered(id);
    await arbitration.connect(buyer).createDispute(id);

    const e = await escrow.getEscrow(id);
    expect(e.disputed).to.equal(true);
    expect(e.delivered).to.equal(true);

    // Past both the inspection period AND the escrow's own expiry — absent
    // the dispute, releaseExpiredToSeller would now succeed.
    await time.increase(7 * DAY + HOUR);

    await expect(
      escrow.connect(other).releaseExpiredToSeller(id)
    ).to.be.revertedWithCustomError(escrow, 'AlreadyDisputed');

    // Principal is still safely held by the escrow contract.
    expect(await xom.balanceOf(escrow.target)).to.equal(ESCROW_AMOUNT);
  });

  it('claimDisputeTimeout is the trustless backstop when the panel never resolves', async function () {
    // Simulates the F1 fund-freeze case: a panel dispute is opened (escrow is
    // now marked disputed, and refundBuyer is blocked) but the panel is never
    // seated/resolved — e.g. no eligible arbitrator committee, so
    // OmniArbitration stays in PendingSelection and its own default-resolution
    // is unreachable. The escrow-side 30-day timeout must remain the trustless,
    // permissionless exit so funds can never be frozen with no recovery.
    const id = await createEscrow();
    await arbitration.connect(buyer).createDispute(id);

    // refundBuyer is closed (the race is still fixed)...
    await time.increase(26 * HOUR); // past expiry + ARBITRATOR_DELAY
    await expect(
      escrow.connect(buyer).refundBuyer(id)
    ).to.be.revertedWithCustomError(escrow, 'AlreadyDisputed');

    // ...and the 30-day backstop is not yet claimable (no longer hard-deferred
    // to the panel — it now reverts on the timeout gate, not
    // UseArbitrationContract).
    await expect(
      escrow.connect(buyer).claimDisputeTimeout(id)
    ).to.be.revertedWithCustomError(escrow, 'EscrowNotExpired');

    // After DISPUTE_TIMEOUT (30 days) past expiry, the buyer recovers the
    // full principal (no marketplace fee on a timeout refund) via pull.
    await time.increase(30 * DAY);
    await expect(escrow.connect(buyer).claimDisputeTimeout(id))
      .to.emit(escrow, 'EscrowResolved')
      .withArgs(id, buyer.address, ESCROW_AMOUNT);
    expect((await escrow.getEscrow(id)).resolved).to.equal(true);

    const before = await xom.balanceOf(buyer.address);
    await escrow.connect(buyer).withdrawClaimable(xom.target);
    const after = await xom.balanceOf(buyer.address);
    expect(after - before).to.equal(ESCROW_AMOUNT);
  });
});
