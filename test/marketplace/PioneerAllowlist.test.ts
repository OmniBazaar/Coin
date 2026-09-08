/**
 * @file PioneerAllowlist.test.ts
 * @description Hardhat tests for the VT-15 Pioneer founder-allowlist pin — the
 * contract that stores the hash of the canonical `PIONEER_FOUNDER_ALLOWLIST`
 * list so no operator can silently diverge the list their validator trusts.
 *
 * The contract is intentionally minimal: an admin-only `setHash`, a public
 * `allowlistHash` reader, and an admin transfer for the post-Pioneer handover
 * to governance. The rules worth pinning down in tests are exactly that
 * surface: only the admin may pin, the event is emitted on every change, a
 * zero-address admin is refused at construction, and control can move so the
 * post-Pioneer handover is a single transaction.
 */

/* eslint-disable @typescript-eslint/no-var-requires */
const { expect } = require("chai");
const { ethers } = require("hardhat");

const keccak256 = ethers.keccak256;
const toUtf8Bytes = ethers.toUtf8Bytes;

/** The canonical hash of a two-address list, pinned in most tests. */
function hashForList(entries) {
  const cleaned = entries
    .map((entry) => entry.trim().toLowerCase())
    .filter((entry) => entry !== "");
  const unique = Array.from(new Set(cleaned));
  unique.sort();
  return keccak256(toUtf8Bytes(unique.join(",")));
}

describe("PioneerAllowlist", function () {
  let deployer;
  let admin;
  let stranger;

  before(async function () {
    [deployer, admin, stranger] = await ethers.getSigners();
  });

  /** Deploy a fresh contract with `admin` as the admin. */
  async function deploy() {
    const PioneerAllowlist = await ethers.getContractFactory(
      "PioneerAllowlist",
    );
    const contract = await PioneerAllowlist.deploy(admin.address);
    await contract.waitForDeployment();
    return contract;
  }

  it("refuses a zero-address admin at construction", async function () {
    const PioneerAllowlist = await ethers.getContractFactory(
      "PioneerAllowlist",
    );
    await expect(
      PioneerAllowlist.deploy(ethers.ZeroAddress),
    ).to.be.revertedWithCustomError(PioneerAllowlist, "ZeroAddress");
  });

  it("starts with the deployer as admin and an unpinned (zero) hash", async function () {
    const contract = await deploy();
    expect(await contract.admin()).to.equal(admin.address);
    expect(await contract.allowlistHash()).to.equal(
      ethers.ZeroHash,
    );
  });

  it("lets the admin pin a hash and emits AllowlistHashUpdated", async function () {
    const contract = await deploy();
    const pinned = hashForList([
      "0xaaaaaAaAAaAaAaaAAaAAaAAaaaAaaAAAaAaaaaa",
      "0xBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
    ]);
    await expect(contract.connect(admin).setHash(pinned))
      .to.emit(contract, "AllowlistHashUpdated")
      .withArgs(ethers.ZeroHash, pinned);
    expect(await contract.allowlistHash()).to.equal(pinned);
  });

  it("rejects a setHash from anyone but the admin", async function () {
    const contract = await deploy();
    await expect(
      contract.connect(stranger).setHash(keccak256(toUtf8Bytes("x"))),
    ).to.be.revertedWithCustomError(contract, "NotAdmin").withArgs(
      stranger.address,
    );
    // The hash is untouched.
    expect(await contract.allowlistHash()).to.equal(ethers.ZeroHash);
  });

  it("allows the pinned hash to change and to be unpinned again", async function () {
    const contract = await deploy();
    const first = hashForList(["0x1111111111111111111111111111111111111111"]);
    const second = hashForList([
      "0x1111111111111111111111111111111111111111",
      "0x2222222222222222222222222222222222222222",
    ]);
    await contract.connect(admin).setHash(first);
    await contract.connect(admin).setHash(second);
    expect(await contract.allowlistHash()).to.equal(second);
    await contract.connect(admin).setHash(ethers.ZeroHash);
    expect(await contract.allowlistHash()).to.equal(ethers.ZeroHash);
  });

  it("hands control to a new admin, who may then pin", async function () {
    const contract = await deploy();
    await expect(contract.connect(admin).transferAdmin(stranger.address))
      .to.emit(contract, "AdminTransferred")
      .withArgs(admin.address, stranger.address);

    // The old admin is now locked out.
    await expect(
      contract.connect(admin).setHash(keccak256(toUtf8Bytes("y"))),
    ).to.be.revertedWithCustomError(contract, "NotAdmin").withArgs(
      admin.address,
    );

    // The new admin can pin.
    const pinned = hashForList(["0x3333333333333333333333333333333333333333"]);
    await expect(contract.connect(stranger).setHash(pinned)).to.emit(
      contract,
      "AllowlistHashUpdated",
    );
    expect(await contract.allowlistHash()).to.equal(pinned);
  });

  it("refuses to transfer admin to the zero address", async function () {
    const contract = await deploy();
    await expect(
      contract.connect(admin).transferAdmin(ethers.ZeroAddress),
    ).to.be.revertedWithCustomError(contract, "ZeroAddress");
  });
});
