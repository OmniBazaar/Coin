/**
 * OmniPrivacyShield — non-MPC vault + access-control tests.
 *
 * The shield's pXOM mint/burn ultimately runs through COTI's MPC precompile
 * (absent in Hardhat), so here we test the PUBLIC ERC20 vault accounting,
 * access control, pausing, the PUSH unshield (`pXOM.transferAndCall(shield,
 * amount)` → `onTokenReceived` releases wXOM), and the DEFERRED burn
 * (`onTokenReceived` accrues `pendingBurn`; `burnPending` burns it later)
 * against a guard-accurate MockPrivateXom stand-in. NOTE: the mock is a plain
 * ERC20 and does NOT reproduce two COTI MPC rules proven on mainnet 2026-06-17:
 * (1) `transferFrom` with a contract spender reverts (unshield tx 0x2a8bf038) —
 * which is why unshield is a user PUSH, not a contract pull; (2) a contract
 * cannot burn a balance it received in the same tx — which is why the burn is
 * deferred. These tests verify the LOGIC; the live MPC paths are verified on
 * COTI (per Coin/CLAUDE.md).
 *
 * MUST run with HARDHAT_CHAIN_ID=2632500 so the shield's COTI chain guard
 * passes (the npm script / invocation sets it).
 */

const { expect } = require("chai");
const { ethers } = require("hardhat");
type Signer = import("ethers").Signer;

describe("OmniPrivacyShield", function () {
  // COTI V2 MPC suite — the contract constructor reverts WrongChain off the
  // COTI network, so this suite cannot deploy on plain hardhat (chainId 1337).
  // Skip (report pending, not failing) unless on a COTI chain; the dedicated
  // COTI-testnet leg exercises these. See nightly-baseline.json.
  before(async function (this: Mocha.Context) {
    const { chainId } = await ethers.provider.getNetwork();
    if (chainId !== 2632500n && chainId !== 7082400n) this.skip();
  });
  let owner: Signer;
  let user: Signer;
  let stranger: Signer;
  let ownerAddr: string;
  let userAddr: string;

  let wxom: any;
  let pxom: any;
  let shield: any;

  const ONE = ethers.parseUnits("1", 18);
  const HUNDRED = ethers.parseUnits("100", 18);

  beforeEach(async function () {
    [owner, user, stranger] = await ethers.getSigners();
    ownerAddr = await owner.getAddress();
    userAddr = await user.getAddress();

    const ERC20Mock = await ethers.getContractFactory("ERC20Mock");
    wxom = await ERC20Mock.deploy("Wrapped XOM", "wXOM");
    await wxom.waitForDeployment();

    const MockPrivateXom = await ethers.getContractFactory("MockPrivateXom");
    pxom = await MockPrivateXom.deploy();
    await pxom.waitForDeployment();

    const Shield = await ethers.getContractFactory("OmniPrivacyShield");
    shield = await Shield.deploy(await wxom.getAddress(), await pxom.getAddress());
    await shield.waitForDeployment();

    // Fund the user with wXOM to shield.
    await wxom.mint(userAddr, HUNDRED);
  });

  describe("Deployment", function () {
    it("binds wXOM + pXOM and sets the deployer as owner", async function () {
      expect(await shield.wrappedXom()).to.equal(await wxom.getAddress());
      expect(await shield.pxom()).to.equal(await pxom.getAddress());
      expect(await shield.owner()).to.equal(ownerAddr);
      expect(await shield.collateralised()).to.equal(0n);
    });

    it("reverts on zero-address constructor args", async function () {
      const Shield = await ethers.getContractFactory("OmniPrivacyShield");
      await expect(
        Shield.deploy(ethers.ZeroAddress, await pxom.getAddress())
      ).to.be.revertedWithCustomError(shield, "ZeroAddress");
      await expect(
        Shield.deploy(await wxom.getAddress(), ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(shield, "ZeroAddress");
    });
  });

  describe("Shield (public wXOM → encrypted pXOM)", function () {
    it("pulls wXOM, mints pXOM 1:1, books collateral, emits", async function () {
      await wxom.connect(user).approve(await shield.getAddress(), HUNDRED);
      await expect(shield.connect(user).shield(HUNDRED))
        .to.emit(shield, "Shielded")
        .withArgs(userAddr, HUNDRED);

      expect(await wxom.balanceOf(await shield.getAddress())).to.equal(HUNDRED);
      expect(await wxom.balanceOf(userAddr)).to.equal(0n);
      expect(await pxom.balanceOf(userAddr)).to.equal(HUNDRED);
      expect(await shield.collateralised()).to.equal(HUNDRED);
    });

    it("reverts on zero amount", async function () {
      await expect(shield.connect(user).shield(0n)).to.be.revertedWithCustomError(
        shield,
        "ZeroAmount"
      );
    });

    it("reverts without approval", async function () {
      await expect(shield.connect(user).shield(HUNDRED)).to.be.reverted;
    });
  });

  describe("Unshield (encrypted pXOM → public wXOM via pXOM.transferAndCall push)", function () {
    beforeEach(async function () {
      await wxom.connect(user).approve(await shield.getAddress(), HUNDRED);
      await shield.connect(user).shield(HUNDRED);
    });

    it("receives pushed pXOM (deferred burn), releases wXOM 1:1, decrements collateral, accrues pendingBurn, emits", async function () {
      const shieldAddr = await shield.getAddress();
      await expect(pxom.connect(user).transferAndCall(shieldAddr, HUNDRED, "0x"))
        .to.emit(shield, "Unshielded")
        .withArgs(userAddr, HUNDRED);

      // pXOM pushed to the shield but NOT burned in this tx (COTI MPC forbids a
      // contract burning a balance it received in the same tx); held as pendingBurn.
      // wXOM returned to the user, collateral decremented.
      expect(await pxom.balanceOf(userAddr)).to.equal(0n);
      expect(await pxom.balanceOf(shieldAddr)).to.equal(HUNDRED);
      expect(await pxom.totalSupply()).to.equal(HUNDRED); // not burned yet
      expect(await wxom.balanceOf(userAddr)).to.equal(HUNDRED);
      expect(await shield.collateralised()).to.equal(0n);
      expect(await shield.pendingBurn()).to.equal(HUNDRED);
    });

    it("supports partial unshield (accrues partial pendingBurn)", async function () {
      const shieldAddr = await shield.getAddress();
      await pxom.connect(user).transferAndCall(shieldAddr, ONE, "0x");
      expect(await shield.collateralised()).to.equal(HUNDRED - ONE);
      expect(await shield.pendingBurn()).to.equal(ONE);
      expect(await wxom.balanceOf(userAddr)).to.equal(ONE);
      expect(await pxom.balanceOf(userAddr)).to.equal(HUNDRED - ONE);
      expect(await pxom.balanceOf(shieldAddr)).to.equal(ONE);
    });

    it("reverts a zero-amount push (onTokenReceived ZeroAmount)", async function () {
      await expect(
        pxom.connect(user).transferAndCall(await shield.getAddress(), 0n, "0x")
      ).to.be.revertedWithCustomError(shield, "ZeroAmount");
    });

    it("rejects onTokenReceived from any caller other than the pXOM token", async function () {
      // A direct call (caller = user EOA, not the pXOM token) must revert OnlyPxom,
      // so no one can spoof a receipt to drain wXOM without pushing pXOM.
      await expect(
        shield.connect(user).onTokenReceived(userAddr, ONE, "0x")
      ).to.be.revertedWithCustomError(shield, "OnlyPxom");
    });
  });

  describe("burnPending (deferred burn of accumulated pXOM)", function () {
    beforeEach(async function () {
      // Shield then unshield (push) so the shield holds HUNDRED pendingBurn pXOM.
      await wxom.connect(user).approve(await shield.getAddress(), HUNDRED);
      await shield.connect(user).shield(HUNDRED);
      await pxom.connect(user).transferAndCall(await shield.getAddress(), HUNDRED, "0x");
    });

    it("burns accumulated pXOM in a separate tx, clears pendingBurn, emits", async function () {
      await expect(shield.connect(owner).burnPending(HUNDRED))
        .to.emit(shield, "PendingBurned")
        .withArgs(HUNDRED, 0n);
      expect(await shield.pendingBurn()).to.equal(0n);
      expect(await pxom.balanceOf(await shield.getAddress())).to.equal(0n);
      expect(await pxom.totalSupply()).to.equal(0n);
    });

    it("supports partial burn of the pending amount", async function () {
      await shield.connect(owner).burnPending(ONE);
      expect(await shield.pendingBurn()).to.equal(HUNDRED - ONE);
      expect(await pxom.balanceOf(await shield.getAddress())).to.equal(HUNDRED - ONE);
    });

    it("is owner-only", async function () {
      await expect(shield.connect(user).burnPending(HUNDRED)).to.be.reverted;
      await expect(shield.connect(stranger).burnPending(HUNDRED)).to.be.reverted;
    });

    it("reverts a zero amount", async function () {
      await expect(
        shield.connect(owner).burnPending(0n)
      ).to.be.revertedWithCustomError(shield, "ZeroAmount");
    });

    it("reverts burning more than pendingBurn", async function () {
      await expect(
        shield.connect(owner).burnPending(HUNDRED + ONE)
      ).to.be.revertedWithCustomError(shield, "InsufficientPending");
    });
  });

  describe("Re-entrancy regression (why onTokenReceived must not call pXOM)", function () {
    it("burn() inside a transferAndCall callback reverts on the guard-accurate mock", async function () {
      // A receiver that calls pXOM.burn inside onTokenReceived re-enters the
      // (nonReentrant) transferAndCall guard and reverts — which is why the
      // shield's onTokenReceived releases wXOM only and defers the pXOM burn to
      // burnPending (a separate tx, no pXOM call inside the callback).
      const Receiver = await ethers.getContractFactory("ReentrantBurnReceiver");
      const receiver = await Receiver.deploy(await pxom.getAddress());
      await receiver.waitForDeployment();
      await pxom.mint(userAddr, HUNDRED);
      await expect(
        pxom.connect(user).transferAndCall(await receiver.getAddress(), HUNDRED, "0x")
      ).to.be.reverted; // ReentrancyGuardReentrantCall
    });
  });

  describe("Collateral safety", function () {
    it("reverts an unshield that exceeds booked collateral (donation cannot be drained)", async function () {
      await wxom.connect(user).approve(await shield.getAddress(), ONE);
      await shield.connect(user).shield(ONE); // collateralised = 1

      // Donate extra wXOM directly to the shield (not via shield()).
      await wxom.mint(await shield.getAddress(), HUNDRED);

      // Mint the user enough mock pXOM to attempt to over-draw.
      await pxom.mint(userAddr, HUNDRED);

      // Push 1 + donation worth: onTokenReceived must cap at booked collateral.
      await expect(
        pxom.connect(user).transferAndCall(await shield.getAddress(), HUNDRED, "0x")
      ).to.be.revertedWithCustomError(shield, "InsufficientCollateral");
    });
  });

  describe("Pausable", function () {
    it("blocks shield + unshield when paused; only owner pauses", async function () {
      // Give the user pXOM + collateral so an unshield push is possible.
      await wxom.connect(user).approve(await shield.getAddress(), HUNDRED);
      await shield.connect(user).shield(HUNDRED);

      await expect(shield.connect(user).pause()).to.be.reverted;
      await shield.connect(owner).pause();

      await wxom.mint(userAddr, ONE);
      await wxom.connect(user).approve(await shield.getAddress(), ONE);
      await expect(shield.connect(user).shield(ONE)).to.be.revertedWithCustomError(
        shield,
        "EnforcedPause"
      );
      // Unshield (push via transferAndCall → onTokenReceived) is also blocked.
      await expect(
        pxom.connect(user).transferAndCall(await shield.getAddress(), HUNDRED, "0x")
      ).to.be.revertedWithCustomError(shield, "EnforcedPause");

      await shield.connect(owner).unpause();
      await expect(
        pxom.connect(user).transferAndCall(await shield.getAddress(), HUNDRED, "0x")
      ).to.emit(shield, "Unshielded");
    });
  });
});
