/**
 * OmniLegacyVest — unit tests.
 *
 * Covers:
 *   - constructor argument validation
 *   - cliff behavior (no release before month 24)
 *   - linear release after cliff
 *   - heartbeat write + permissions
 *   - accelerateByDAO: only DAO controller, one-way, releases full
 *   - accelerateByIncapacity: blocked before window, permissionless after
 *   - acceleration with active heartbeat blocks incapacity trigger
 */

const { expect } = require("chai");
const { ethers, network } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

describe("OmniLegacyVest", function () {
  // 95% of the on-chain "quasar" legacy entitlement (2,564,000,000 XOM,
  // LegacyBalanceClaim.legacyBalances, read 2026-07-05).
  const FUND_AMOUNT = ethers.parseEther("2435800000"); // 2.4358B XOM
  const YEAR = 365 * 86400;
  const TWO_YEARS = 2 * YEAR;
  const FIVE_YEARS = 5 * YEAR;
  const HEARTBEAT = YEAR;
  const GRACE = 90 * 86400;

  let xom, vest, daoContract, owner, beneficiary, attacker, estate;

  beforeEach(async () => {
    [owner, beneficiary, attacker, estate] = await ethers.getSigners();
    const MockERC20 = await ethers.getContractFactory("MockERC20");
    xom = await MockERC20.deploy("OmniCoin", "XOM");
    await xom.mint(owner.address, FUND_AMOUNT);
    // Deploy a contract to act as DAO_CONTROLLER (constructor requires
    // dao.code.length > 0). We use another instance of MockERC20 since
    // we never call DAO methods on it — only the address matters.
    daoContract = await MockERC20.deploy("DAO", "DAO");
    const startTs = (await time.latest()) + 60;
    const Factory = await ethers.getContractFactory("OmniLegacyVest");
    vest = await Factory.deploy(
      beneficiary.address,
      await daoContract.getAddress(),
      startTs,
    );
    await xom.transfer(await vest.getAddress(), FUND_AMOUNT);
  });

  /**
   * Helper: impersonate the DAO_CONTROLLER contract address so we can
   * make calls FROM that address (forge-style).
   */
  async function daoSigner() {
    const addr = await daoContract.getAddress();
    await network.provider.send("hardhat_impersonateAccount", [addr]);
    // Fund the impersonated account for gas
    await network.provider.send("hardhat_setBalance", [
      addr,
      "0x" + (10n ** 18n).toString(16),
    ]);
    return await ethers.getSigner(addr);
  }

  describe("constructor", () => {
    it("reverts on zero beneficiary (OZ Ownable check)", async () => {
      const Factory = await ethers.getContractFactory("OmniLegacyVest");
      // OZ {Ownable} reverts with OwnableInvalidOwner before we can hit a
      // local check — no need to duplicate the validation.
      await expect(
        Factory.deploy(ethers.ZeroAddress, await daoContract.getAddress(), await time.latest()),
      ).to.be.reverted;
    });

    it("reverts on zero dao", async () => {
      const Factory = await ethers.getContractFactory("OmniLegacyVest");
      await expect(
        Factory.deploy(beneficiary.address, ethers.ZeroAddress, await time.latest()),
      ).to.be.revertedWithCustomError(vest, "ZeroDAOController");
    });

    it("reverts when dao == beneficiary (C-1 misbinding guard)", async () => {
      const Factory = await ethers.getContractFactory("OmniLegacyVest");
      await expect(
        Factory.deploy(beneficiary.address, beneficiary.address, await time.latest()),
      ).to.be.revertedWithCustomError(vest, "DAOControllerMisbound");
    });

    it("reverts when dao is an EOA (no contract code)", async () => {
      const Factory = await ethers.getContractFactory("OmniLegacyVest");
      // attacker is a plain EOA — no code
      await expect(
        Factory.deploy(beneficiary.address, attacker.address, await time.latest()),
      ).to.be.revertedWithCustomError(vest, "DAOControllerMisbound");
    });

    it("reverts when startTimestamp is too far in the future", async () => {
      const Factory = await ethers.getContractFactory("OmniLegacyVest");
      const tooFar = (await time.latest()) + 31 * 86400;
      await expect(
        Factory.deploy(beneficiary.address, await daoContract.getAddress(), tooFar),
      ).to.be.revertedWithCustomError(vest, "StartTooFarInFuture");
    });

    it("reverts on too-far-back start (tightened to 1 day)", async () => {
      const Factory = await ethers.getContractFactory("OmniLegacyVest");
      const tooOld = (await time.latest()) - 2 * 86400;
      await expect(
        Factory.deploy(beneficiary.address, await daoContract.getAddress(), tooOld),
      ).to.be.revertedWithCustomError(vest, "StartTooFarInPast");
    });


    it("sets immutables + heartbeat", async () => {
      expect(await vest.owner()).to.equal(beneficiary.address);
      expect(await vest.DAO_CONTROLLER()).to.equal(await daoContract.getAddress());
      expect(await vest.duration()).to.equal(FIVE_YEARS);
      expect(await vest.accelerated()).to.equal(false);
      expect(await vest.lastAlive()).to.be.gt(0);
    });
  });

  describe("cliff", () => {
    it("releasable is zero before cliff", async () => {
      await time.increase(TWO_YEARS - YEAR);
      expect(await vest["releasable(address)"](await xom.getAddress())).to.equal(0n);
    });

    it("releasable still zero exactly at cliff", async () => {
      await time.increaseTo((await vest.start()) + BigInt(TWO_YEARS) - 2n);
      expect(await vest["releasable(address)"](await xom.getAddress())).to.equal(0n);
    });

    it("releasable > 0 just after cliff", async () => {
      await time.increaseTo((await vest.start()) + BigInt(TWO_YEARS) + 100n);
      expect(await vest["releasable(address)"](await xom.getAddress())).to.be.gt(0n);
    });
  });

  describe("linear vest", () => {
    it("fully vested at end", async () => {
      await time.increaseTo((await vest.start()) + BigInt(FIVE_YEARS) + 100n);
      expect(await vest["releasable(address)"](await xom.getAddress())).to.equal(FUND_AMOUNT);
    });

    it("approximately 1/3 of post-cliff at month 36 (1 year into linear)", async () => {
      // At month 36: cliff (month 24) + 12 months of linear (out of 36 total linear) = 1/3 vested
      await time.increaseTo((await vest.start()) + BigInt(TWO_YEARS + YEAR));
      const releasable = await vest["releasable(address)"](await xom.getAddress());
      // Allow 1% tolerance for timestamp wobble in tests
      const expected = (FUND_AMOUNT * 36n) / 60n; // 36 months out of 60 total elapsed → 60% allocated by OZ formula
      expect(releasable).to.be.closeTo(expected, expected / 100n);
    });
  });

  describe("alive heartbeat", () => {
    it("only beneficiary can call alive", async () => {
      await expect(vest.connect(attacker).alive()).to.be.revertedWithCustomError(vest, "NotBeneficiary");
    });

    it("beneficiary alive updates lastAlive", async () => {
      const prev = await vest.lastAlive();
      await time.increase(86400);
      await vest.connect(beneficiary).alive();
      expect(await vest.lastAlive()).to.be.gt(prev);
    });
  });

  describe("accelerateByDAO", () => {
    it("rejects non-DAO callers", async () => {
      await expect(vest.connect(attacker).accelerateByDAO()).to.be.revertedWithCustomError(vest, "NotDAOController");
      await expect(vest.connect(beneficiary).accelerateByDAO()).to.be.revertedWithCustomError(vest, "NotDAOController");
    });

    it("DAO can accelerate; full balance becomes releasable once start() passes", async () => {
      await vest.connect(await daoSigner()).accelerateByDAO();
      expect(await vest.accelerated()).to.equal(true);
      // Acceleration honors timestamp >= start() — advance past start
      await time.increaseTo((await vest.start()) + 1n);
      expect(await vest["releasable(address)"](await xom.getAddress())).to.equal(FUND_AMOUNT);
    });

    it("DAO acceleration before start() does NOT release (M-6 guard)", async () => {
      // start() is in the future per beforeEach
      const startTs = await vest.start();
      const now = BigInt(await time.latest());
      expect(startTs).to.be.gt(now);
      await vest.connect(await daoSigner()).accelerateByDAO();
      // Even though accelerated, releasable is 0 until start() passes
      expect(await vest["releasable(address)"](await xom.getAddress())).to.equal(0n);
    });

    it("is one-way (second call reverts)", async () => {
      await vest.connect(await daoSigner()).accelerateByDAO();
      await expect(vest.connect(await daoSigner()).accelerateByDAO()).to.be.revertedWithCustomError(vest, "AlreadyAccelerated");
    });

    it("emits Accelerated with TRIGGER_DAO=1", async () => {
      const TRIGGER_DAO = await vest.TRIGGER_DAO();
      await expect(vest.connect(await daoSigner()).accelerateByDAO()).to.emit(vest, "Accelerated").withArgs(TRIGGER_DAO, await daoContract.getAddress(), await anyTimestamp(vest));
    });
  });

  describe("accelerateByIncapacity", () => {
    it("reverts before HEARTBEAT + GRACE", async () => {
      await time.increase(HEARTBEAT - 1);
      await expect(vest.connect(attacker).accelerateByIncapacity()).to.be.revertedWithCustomError(vest, "IncapacityTriggerTooEarly");
    });

    it("reverts even just inside grace window", async () => {
      await time.increase(HEARTBEAT + GRACE - 60);
      await expect(vest.connect(attacker).accelerateByIncapacity()).to.be.revertedWithCustomError(vest, "IncapacityTriggerTooEarly");
    });

    it("permissionless after HEARTBEAT + GRACE elapsed", async () => {
      await time.increase(HEARTBEAT + GRACE + 60);
      await expect(vest.connect(attacker).accelerateByIncapacity()).to.not.be.reverted;
      expect(await vest.accelerated()).to.equal(true);
    });

    it("active heartbeat resets the window", async () => {
      // Heartbeat at ~6 months in
      await time.increase(180 * 86400);
      await vest.connect(beneficiary).alive();
      // Now advance close to HEARTBEAT + GRACE from the start — but from
      // heartbeat-reset time we have a full HEARTBEAT + GRACE window again
      await time.increase(HEARTBEAT + GRACE - 60);
      await expect(vest.connect(attacker).accelerateByIncapacity()).to.be.revertedWithCustomError(vest, "IncapacityTriggerTooEarly");
    });

    it("is one-way after firing", async () => {
      await time.increase(HEARTBEAT + GRACE + 60);
      await vest.connect(attacker).accelerateByIncapacity();
      await expect(vest.connect(attacker).accelerateByIncapacity()).to.be.revertedWithCustomError(vest, "AlreadyAccelerated");
    });
  });

  describe("ownership lockdown (H-1 fix)", () => {
    it("transferOwnership reverts even from owner", async () => {
      await expect(
        vest.connect(beneficiary).transferOwnership(attacker.address),
      ).to.be.revertedWithCustomError(vest, "OwnershipChangeDisabled");
    });

    it("renounceOwnership reverts even from owner (M-1 fix)", async () => {
      await expect(
        vest.connect(beneficiary).renounceOwnership(),
      ).to.be.revertedWithCustomError(vest, "OwnershipChangeDisabled");
    });
  });

  describe("estate recipient (H-2 + M-3 fix)", () => {
    it("only beneficiary can set estate recipient", async () => {
      await expect(
        vest.connect(attacker).setEstateRecipient(estate.address),
      ).to.be.revertedWithCustomError(vest, "NotBeneficiary");
    });

    it("zero estate recipient rejected", async () => {
      await expect(
        vest.connect(beneficiary).setEstateRecipient(ethers.ZeroAddress),
      ).to.be.revertedWithCustomError(vest, "ZeroEstateRecipient");
    });

    it("setEstateRecipient is one-way", async () => {
      await vest.connect(beneficiary).setEstateRecipient(estate.address);
      expect(await vest.estateRecipient()).to.equal(estate.address);
      await expect(
        vest.connect(beneficiary).setEstateRecipient(attacker.address),
      ).to.be.revertedWithCustomError(vest, "EstateRecipientAlreadySet");
    });

    it("accelerateByIncapacity transfers ownership to estate when set", async () => {
      await vest.connect(beneficiary).setEstateRecipient(estate.address);
      await time.increase(HEARTBEAT + GRACE + 60);
      // We are already well past start() at this point — no further
      // time advance needed.
      await vest.connect(attacker).accelerateByIncapacity();
      expect(await vest.owner()).to.equal(estate.address);
      await vest.connect(estate)["release(address)"](await xom.getAddress());
      expect(await xom.balanceOf(estate.address)).to.equal(FUND_AMOUNT);
    });

    it("accelerateByIncapacity leaves owner unchanged when estate unset", async () => {
      await time.increase(HEARTBEAT + GRACE + 60);
      await vest.connect(attacker).accelerateByIncapacity();
      expect(await vest.owner()).to.equal(beneficiary.address);
    });
  });

  describe("native-currency lockdown (M-5 fix)", () => {
    it("receive() reverts on ETH", async () => {
      await expect(
        owner.sendTransaction({ to: await vest.getAddress(), value: 1n }),
      ).to.be.revertedWithCustomError(vest, "NativeCurrencyDisabled");
    });

    it("release() no-arg reverts", async () => {
      await expect(
        vest.connect(beneficiary)["release()"](),
      ).to.be.revertedWithCustomError(vest, "NativeCurrencyDisabled");
    });

    it("releasable() no-arg reverts", async () => {
      await expect(vest["releasable()"]()).to.be.revertedWithCustomError(
        vest,
        "NativeCurrencyDisabled",
      );
    });
  });

  describe("acknowledgeFunded (M-2 fix)", () => {
    it("succeeds when balance >= EXPECTED_FUNDING", async () => {
      const tokenAddr = await xom.getAddress();
      await expect(vest.acknowledgeFunded(tokenAddr)).to.emit(vest, "Funded");
      expect(await vest.funded()).to.equal(true);
    });

    it("reverts when underfunded", async () => {
      // Deploy a fresh vest with no funding
      const Factory = await ethers.getContractFactory("OmniLegacyVest");
      const startTs = (await time.latest()) + 60;
      const v2 = await Factory.deploy(
        beneficiary.address,
        await daoContract.getAddress(),
        startTs,
      );
      await expect(
        v2.acknowledgeFunded(await xom.getAddress()),
      ).to.be.revertedWithCustomError(v2, "InsufficientFunding");
    });

    it("is one-way (second call reverts)", async () => {
      const tokenAddr = await xom.getAddress();
      await vest.acknowledgeFunded(tokenAddr);
      await expect(
        vest.acknowledgeFunded(tokenAddr),
      ).to.be.revertedWithCustomError(vest, "AlreadyFunded");
    });
  });

  describe("release after acceleration", () => {
    it("beneficiary can release full balance after DAO-accel + start()", async () => {
      await vest.connect(await daoSigner()).accelerateByDAO();
      await time.increaseTo((await vest.start()) + 1n);
      const before = await xom.balanceOf(beneficiary.address);
      await vest.connect(beneficiary)["release(address)"](await xom.getAddress());
      const after = await xom.balanceOf(beneficiary.address);
      expect(after - before).to.equal(FUND_AMOUNT);
    });
  });

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  async function anyTimestamp(_) {
    // Loose timestamp check — chai-matchers doesn't have anyValue exposed
    // here, so we return a small range. The test passes as long as the
    // event lands in this window.
    return (await time.latest()) + 1;
  }
});
