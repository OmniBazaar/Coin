/**
 * MinimalEscrow — permissionless seller-release after delivery (CSW2).
 *
 * Proves the seller-protection path that closes the silent-buyer gap: a seller
 * marks the escrow delivered (opening the buyer's inspection window), and after
 * that window elapses anyone may release the funds to the seller. Also proves
 * that marking delivered closes the buyer's post-expiry self-refund path, so a
 * passive buyer can no longer strand a delivering seller.
 *
 * Integration-first: deploys the REAL MinimalEscrow + REAL OmniCoin. The fee
 * vault is an EOA, so fee routing takes the documented direct-transfer path.
 */

/* eslint-disable @typescript-eslint/no-var-requires */
const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

describe("MinimalEscrow — permissionless seller-release", function () {
  /* eslint-disable @typescript-eslint/no-explicit-any */
  let escrow: any;
  let xom: any;
  let owner: any;
  let feeVault: any;
  let registry: any;
  let buyer: any;
  let seller: any;
  let other: any;
  /* eslint-enable @typescript-eslint/no-explicit-any */

  const ESCROW_AMOUNT = ethers.parseEther("1000");
  const FEE_BPS = 100n; // 1% marketplace fee
  const HOUR = 3600;
  const DAY = 24 * HOUR;
  const DURATION = 25 * HOUR; // > ARBITRATOR_DELAY so a post-expiry refund is otherwise valid
  const INSPECTION_PERIOD = 7 * DAY;

  /** Create a public XOM escrow as `buyer`; return its id. */
  async function createEscrow(): Promise<bigint> {
    const tx = await escrow
      .connect(buyer)
      .createEscrow(seller.address, ESCROW_AMOUNT, DURATION);
    const receipt = await tx.wait();
    const ev = receipt.logs.find(
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      (l: any) => l.fragment && l.fragment.name === "EscrowCreated",
    );
    return ev.args.escrowId;
  }

  beforeEach(async function () {
    [owner, feeVault, registry, buyer, seller, other] =
      await ethers.getSigners();

    const Token = await ethers.getContractFactory("OmniCoin");
    xom = await Token.deploy(ethers.ZeroAddress);
    await xom.initialize();
    const pxom = await Token.deploy(ethers.ZeroAddress);
    await pxom.initialize();

    const Escrow = await ethers.getContractFactory("MinimalEscrow");
    escrow = await Escrow.deploy(
      xom.target,
      pxom.target,
      registry.address,
      feeVault.address,
      FEE_BPS,
      ethers.ZeroAddress,
    );

    await xom.transfer(buyer.address, ethers.parseEther("2000"));
    await xom.connect(buyer).approve(escrow.target, ethers.MaxUint256);
  });

  it("lets the seller mark delivered and opens the inspection window", async function () {
    const id = await createEscrow();
    await expect(escrow.connect(seller).markDelivered(id)).to.emit(
      escrow,
      "DeliveryMarked",
    );
    const e = await escrow.escrows(id);
    expect(e.delivered).to.equal(true);
    expect(e.inspectionDeadline).to.be.gt(0n);
  });

  it("rejects markDelivered from a non-seller and double-marking", async function () {
    const id = await createEscrow();
    await expect(
      escrow.connect(buyer).markDelivered(id),
    ).to.be.revertedWithCustomError(escrow, "NotParticipant");
    await escrow.connect(seller).markDelivered(id);
    await expect(
      escrow.connect(seller).markDelivered(id),
    ).to.be.revertedWithCustomError(escrow, "AlreadyDelivered");
  });

  it("reverts releaseExpiredToSeller when not delivered", async function () {
    const id = await createEscrow();
    await expect(
      escrow.connect(other).releaseExpiredToSeller(id),
    ).to.be.revertedWithCustomError(escrow, "NotDelivered");
  });

  it("reverts releaseExpiredToSeller during the inspection window", async function () {
    const id = await createEscrow();
    await escrow.connect(seller).markDelivered(id);
    await expect(
      escrow.connect(other).releaseExpiredToSeller(id),
    ).to.be.revertedWithCustomError(escrow, "InspectionPending");
  });

  it("permissionlessly releases to the seller after the inspection window", async function () {
    const id = await createEscrow();
    await escrow.connect(seller).markDelivered(id);
    await time.increase(INSPECTION_PERIOD + HOUR);

    const before = await xom.balanceOf(seller.address);
    // Called by an unrelated third party (`other`) — permissionless.
    const tx = await escrow.connect(other).releaseExpiredToSeller(id);
    const receipt = await tx.wait();
    const ev = receipt.logs.find(
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      (l: any) => l.fragment && l.fragment.name === "EscrowResolved",
    );
    const paid = ev.args.amount as bigint;

    // Seller receives amount minus the 1% marketplace fee.
    const expectedFee = (ESCROW_AMOUNT * FEE_BPS) / 10_000n;
    expect(paid).to.equal(ESCROW_AMOUNT - expectedFee);
    expect(await xom.balanceOf(seller.address)).to.equal(before + paid);

    const e = await escrow.escrows(id);
    expect(e.resolved).to.equal(true);
    // Double-release reverts.
    await expect(
      escrow.connect(other).releaseExpiredToSeller(id),
    ).to.be.revertedWithCustomError(escrow, "AlreadyResolved");
  });

  it("blocks the buyer's post-expiry self-refund once delivered", async function () {
    const id = await createEscrow();
    await escrow.connect(seller).markDelivered(id);
    // Move past the escrow expiry (25h) — but the buyer must no longer be able
    // to reclaim, because delivery was asserted.
    await time.increase(DURATION + HOUR);

    const buyerBefore = await xom.balanceOf(buyer.address);
    await escrow.connect(buyer).refundBuyer(id); // no-op for a delivered escrow
    expect(await xom.balanceOf(buyer.address)).to.equal(buyerBefore);
    const e = await escrow.escrows(id);
    expect(e.resolved).to.equal(false);

    // And the seller can still be paid after the inspection window.
    await time.increase(INSPECTION_PERIOD);
    await escrow.connect(seller).releaseExpiredToSeller(id);
    expect((await escrow.escrows(id)).resolved).to.equal(true);
  });
});
