/**
 * OmniVotingPowerCap — unit tests.
 *
 * Covers:
 *   - constructor (zero admin reject; initial event)
 *   - setCap: admin-only, zero-voter reject, cap > MAX reject, event
 *   - effectiveWeight: uncapped pass-through, capped clamp, edge cases
 *   - admin rotation (2-step propose/accept)
 *   - one-cap-removes-another via setCap(voter, 0)
 */

const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("OmniVotingPowerCap", function () {
  let cap, admin, attacker, founder, otherVoter, pending;

  beforeEach(async () => {
    [admin, attacker, founder, otherVoter, pending] = await ethers.getSigners();
    const Factory = await ethers.getContractFactory("OmniVotingPowerCap");
    cap = await Factory.deploy(admin.address);
  });

  describe("constructor", () => {
    it("reverts on zero admin", async () => {
      const Factory = await ethers.getContractFactory("OmniVotingPowerCap");
      await expect(Factory.deploy(ethers.ZeroAddress)).to.be.revertedWithCustomError(
        cap,
        "ZeroAdmin",
      );
    });

    it("sets admin at deploy", async () => {
      expect(await cap.admin()).to.equal(admin.address);
      expect(await cap.pendingAdmin()).to.equal(ethers.ZeroAddress);
    });
  });

  describe("setCap", () => {
    it("rejects non-admin", async () => {
      await expect(
        cap.connect(attacker).setCap(founder.address, 700),
      ).to.be.revertedWithCustomError(cap, "NotAdmin");
    });

    it("rejects zero voter", async () => {
      await expect(
        cap.connect(admin).setCap(ethers.ZeroAddress, 700),
      ).to.be.revertedWithCustomError(cap, "ZeroVoter");
    });

    it("rejects cap above MAX_CAP_BPS (1000 post-audit)", async () => {
      await expect(
        cap.connect(admin).setCap(founder.address, 1001),
      ).to.be.revertedWithCustomError(cap, "CapTooHigh");
    });

    it("rejects no-op setCap (audit L-1)", async () => {
      await cap.connect(admin).setCap(founder.address, 700);
      await expect(
        cap.connect(admin).setCap(founder.address, 700),
      ).to.be.revertedWithCustomError(cap, "NoChange");
    });

    it("emits CapSet on initial set", async () => {
      await expect(cap.connect(admin).setCap(founder.address, 700))
        .to.emit(cap, "CapSet")
        .withArgs(founder.address, 0, 700);
      expect(await cap.capBps(founder.address)).to.equal(700);
    });

    it("setting cap=0 clears", async () => {
      await cap.connect(admin).setCap(founder.address, 700);
      await expect(cap.connect(admin).setCap(founder.address, 0))
        .to.emit(cap, "CapSet")
        .withArgs(founder.address, 700, 0);
      expect(await cap.capBps(founder.address)).to.equal(0);
    });

    it("MAX_CAP_BPS at 1000 (10%) is the boundary", async () => {
      await cap.connect(admin).setCap(founder.address, 1000);
      expect(await cap.capBps(founder.address)).to.equal(1000);
    });
  });

  describe("effectiveWeight", () => {
    const SNAPSHOT_SUPPLY = ethers.parseEther("16600000000"); // 16.6B XOM

    it("uncapped voter passes through unchanged", async () => {
      const raw = ethers.parseEther("1000");
      expect(
        await cap.effectiveWeight(otherVoter.address, raw, SNAPSHOT_SUPPLY),
      ).to.equal(raw);
    });

    it("capped voter clamps to snapshot * capBps / 10000", async () => {
      await cap.connect(admin).setCap(founder.address, 700); // 7%
      const raw = ethers.parseEther("2500000000"); // 2.5B raw weight
      const expected = (SNAPSHOT_SUPPLY * 700n) / 10000n; // 1.162B
      const actual = await cap.effectiveWeight(
        founder.address,
        raw,
        SNAPSHOT_SUPPLY,
      );
      expect(actual).to.equal(expected);
    });

    it("capped voter with weight below cap passes through unchanged", async () => {
      await cap.connect(admin).setCap(founder.address, 700);
      const raw = ethers.parseEther("100000"); // way below 1.162B cap
      expect(
        await cap.effectiveWeight(founder.address, raw, SNAPSHOT_SUPPLY),
      ).to.equal(raw);
    });

    it("clear cap restores pass-through", async () => {
      await cap.connect(admin).setCap(founder.address, 700);
      await cap.connect(admin).setCap(founder.address, 0);
      const raw = ethers.parseEther("2500000000");
      expect(
        await cap.effectiveWeight(founder.address, raw, SNAPSHOT_SUPPLY),
      ).to.equal(raw);
    });

    // ---- Audit F1: denominator semantics + rounding + overflow ----

    it("cap tracks the VOTEABLE supply passed by governance, not nominal 16.6B (audit F1)", async () => {
      // OmniGovernance passes voteableSupply() = totalSupply - excluded, which
      // at launch is far below 16.6B. The cap must be 7% of THAT value.
      await cap.connect(admin).setCap(founder.address, 700);
      const voteable = ethers.parseEther("4130000000"); // ~4.13B circulating
      const raw = ethers.parseEther("2500000000"); // 2.5B, above the cap
      const expected = (voteable * 700n) / 10000n; // ~289.1M — well below the
      // 1.162B a total-supply denominator would have produced
      expect(
        await cap.effectiveWeight(founder.address, raw, voteable),
      ).to.equal(expected);
      // Sanity: the voteable-denominated cap is strictly tighter (smaller).
      expect(expected).to.be.lessThan((SNAPSHOT_SUPPLY * 700n) / 10000n);
    });

    it("floors the cap DOWN (safe direction — never grants more than capBps)", async () => {
      // Choose values where snapshot*capBps is not divisible by 10000 so the
      // integer division truncates. capBps=1 => supply/10000.
      await cap.connect(admin).setCap(founder.address, 1);
      const supply = 199999n; // 199999 * 1 / 10000 = 19 (floored from 19.9999)
      const raw = 10n ** 30n; // huge, forces clamp to the cap
      expect(await cap.effectiveWeight(founder.address, raw, supply)).to.equal(19n);
    });

    it("no overflow at max cap and full nominal supply", async () => {
      // Worst case: capBps = MAX_CAP_BPS (1000) and the full 16.6B*1e18 supply.
      await cap.connect(admin).setCap(founder.address, 1000);
      const raw = 10n ** 40n; // above any plausible cap, forces the clamp
      const expected = (SNAPSHOT_SUPPLY * 1000n) / 10000n; // 10% of 16.6B
      expect(
        await cap.effectiveWeight(founder.address, raw, SNAPSHOT_SUPPLY),
      ).to.equal(expected);
    });

    it("zero voteable supply yields a zero cap for capped voters (no div-by-zero)", async () => {
      await cap.connect(admin).setCap(founder.address, 700);
      expect(
        await cap.effectiveWeight(founder.address, ethers.parseEther("1000"), 0n),
      ).to.equal(0n);
      // Uncapped voters are unaffected by a zero supply.
      expect(
        await cap.effectiveWeight(otherVoter.address, ethers.parseEther("1000"), 0n),
      ).to.equal(ethers.parseEther("1000"));
    });
  });

  describe("admin rotation (2-step)", () => {
    it("transferAdmin proposes, acceptAdmin finalizes", async () => {
      await expect(cap.connect(admin).transferAdmin(pending.address))
        .to.emit(cap, "AdminProposed")
        .withArgs(admin.address, pending.address);
      expect(await cap.pendingAdmin()).to.equal(pending.address);
      expect(await cap.admin()).to.equal(admin.address); // not yet
      await expect(cap.connect(pending).acceptAdmin())
        .to.emit(cap, "AdminTransferred")
        .withArgs(admin.address, pending.address);
      expect(await cap.admin()).to.equal(pending.address);
      expect(await cap.pendingAdmin()).to.equal(ethers.ZeroAddress);
    });

    it("non-pending cannot accept", async () => {
      await cap.connect(admin).transferAdmin(pending.address);
      await expect(cap.connect(attacker).acceptAdmin()).to.be.revertedWithCustomError(
        cap,
        "NotPendingAdmin",
      );
    });

    it("only current admin can propose", async () => {
      await expect(
        cap.connect(attacker).transferAdmin(pending.address),
      ).to.be.revertedWithCustomError(cap, "NotAdmin");
    });

    it("can clear pending by proposing address(0)", async () => {
      await cap.connect(admin).transferAdmin(pending.address);
      await cap.connect(admin).transferAdmin(ethers.ZeroAddress);
      expect(await cap.pendingAdmin()).to.equal(ethers.ZeroAddress);
      // Original admin still in control
      expect(await cap.admin()).to.equal(admin.address);
    });

    it("after rotation, new admin can setCap", async () => {
      await cap.connect(admin).transferAdmin(pending.address);
      await cap.connect(pending).acceptAdmin();
      await cap.connect(pending).setCap(founder.address, 700);
      expect(await cap.capBps(founder.address)).to.equal(700);
      // Old admin loses authority
      await expect(
        cap.connect(admin).setCap(founder.address, 800),
      ).to.be.revertedWithCustomError(cap, "NotAdmin");
    });
  });
});
