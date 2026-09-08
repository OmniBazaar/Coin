/**
 * CommitteeMessageIdMultisigIsm — committee-backed Hyperlane ISM tests.
 *
 * Secures the XOM↔COTI Hyperlane Warp Route using OmniBazaar's OWN scaling
 * validator set (the inherited CommitteeAttestor eligible-set snapshot) instead
 * of a static validator list. These tests build a REAL Hyperlane checkpoint
 * digest (CheckpointLib.digest over a real Message) and sign it with eligible
 * validator keys, then assert the inherited Hyperlane verifier accepts a
 * BFT-supermajority quorum and rejects everything else.
 *
 * No MPC / COTI precompile involved — pure ECDSA + message-id multisig — so
 * this runs on plain Hardhat (default chain id, no HARDHAT_CHAIN_ID guard).
 *
 * Decision: memory/decision_privacy_bridge_hyperlane_2026-05-30.md
 */

const { expect } = require("chai");
const { ethers } = require("hardhat");
const { committeeAttestorLibraries } = require("./utils/committeeAttestorLib");
type Signer = import("ethers").Signer;
type Wallet = import("ethers").HDNodeWallet;

const ORIGIN = 88008; // OmniCoin L1 — the Warp Route origin domain.
const MERKLE_TREE_HOOK = ethers.zeroPadValue(
  "0x6D48135b7584E8Bf828B6e23110Bc0Da4252704f",
  32
); // COTI MerkleTreeHook (any consistent bytes32 works for the digest).
const ROOT = ethers.id("test-checkpoint-root");
const INDEX = 0;

/** Generate `k` random wallets sorted ascending by address (numeric order). */
function sortedWallets(k: number): Wallet[] {
  const ws: Wallet[] = [];
  for (let i = 0; i < k; i++) ws.push(ethers.Wallet.createRandom());
  // 40-hex fixed-length addresses → lowercase lexicographic == numeric order,
  // matching CommitteeAttestor's `a <= prev` address comparison.
  ws.sort((a: Wallet, b: Wallet) =>
    a.address.toLowerCase() < b.address.toLowerCase() ? -1 : 1
  );
  return ws;
}

/** BFT supermajority floor(2n/3)+1 — mirrors the contract. */
function bft(n: number): number {
  return Math.floor((n * 2) / 3) + 1;
}

/** Build a real Hyperlane message with the given origin domain. */
function buildMessage(origin: number): string {
  const version = 3;
  const nonce = 1;
  const sender = ethers.zeroPadValue("0x01", 32);
  const destination = 2632500;
  const recipient = ethers.zeroPadValue("0x02", 32);
  const body = "0x";
  return ethers.solidityPacked(
    ["uint8", "uint32", "uint32", "bytes32", "uint32", "bytes32", "bytes"],
    [version, nonce, origin, sender, destination, recipient, body]
  );
}

/** The inner checkpoint hash (pre eth-signed envelope) that validators sign. */
function checkpointInnerHash(messageId: string): string {
  const domainHash = ethers.keccak256(
    ethers.solidityPacked(
      ["uint32", "bytes32", "string"],
      [ORIGIN, MERKLE_TREE_HOOK, "HYPERLANE"]
    )
  );
  return ethers.keccak256(
    ethers.solidityPacked(
      ["bytes32", "bytes32", "uint32", "bytes32"],
      [domainHash, ROOT, INDEX, messageId]
    )
  );
}

/**
 * Build Hyperlane MessageIdMultisigIsm metadata:
 *   [0:32] merkleTreeHook | [32:64] root | [64:68] index | [68:] signatures.
 * Signers sign the eth-signed envelope of the inner hash (signMessage), which
 * is exactly what CheckpointLib.digest reconstructs + ECDSA.recover checks.
 */
async function buildMetadata(
  signers: Wallet[],
  innerHash: string
): Promise<string> {
  const sigs: string[] = [];
  for (const w of signers) {
    sigs.push(await w.signMessage(ethers.getBytes(innerHash)));
  }
  const indexBytes = ethers.zeroPadValue(ethers.toBeHex(INDEX), 4);
  return ethers.concat([MERKLE_TREE_HOOK, ROOT, indexBytes, ...sigs]);
}

describe("CommitteeMessageIdMultisigIsm", function () {
  let owner: Signer;
  let stranger: Signer;
  let ownerAddr: string;

  let validators: Wallet[];
  let ism: any;

  async function deployWith(vs: Wallet[], n: number, m: number): Promise<any> {
    const libraries = await committeeAttestorLibraries();
    const Ism = await ethers.getContractFactory(
      "CommitteeMessageIdMultisigIsm",
      { libraries }
    );
    const c = await Ism.deploy(
      ownerAddr,
      vs.map((w) => w.address),
      n,
      m,
      0
    );
    await c.waitForDeployment();
    return c;
  }

  beforeEach(async function () {
    [owner, stranger] = await ethers.getSigners();
    ownerAddr = await owner.getAddress();
    validators = sortedWallets(5);
    ism = await deployWith(validators, 5, 4);
  });

  describe("Deployment + ISM surface", function () {
    it("reports MESSAGE_ID_MULTISIG module type (5)", async function () {
      expect(await ism.moduleType()).to.equal(5);
    });

    it("sets the deployer as owner and bootstraps the eligible set", async function () {
      expect(await ism.owner()).to.equal(ownerAddr);
      expect(await ism.eligibleSnapshotLength()).to.equal(5n);
      const snap: string[] = await ism.eligibleSnapshot();
      expect(snap.map((a) => a.toLowerCase())).to.deep.equal(
        validators.map((w) => w.address.toLowerCase())
      );
    });

    it("derives a BFT supermajority threshold (4-of-5)", async function () {
      expect(await ism.bridgeThreshold()).to.equal(4);
      const [vset, threshold] = await ism.validatorsAndThreshold("0x");
      expect(vset.length).to.equal(5);
      expect(threshold).to.equal(4);
    });
  });

  describe("verify() — quorum acceptance", function () {
    it("accepts a BFT-supermajority of eligible validator signatures", async function () {
      const message = buildMessage(ORIGIN);
      const messageId = ethers.keccak256(message);
      const inner = checkpointInnerHash(messageId);
      // Lowest-4 validators (ascending) — matches Hyperlane's two-pointer order.
      const quorum = validators.slice(0, bft(5));
      const metadata = await buildMetadata(quorum, inner);
      expect(await ism.verify(metadata, message)).to.equal(true);
    });

    it("accepts when ALL validators sign (extra sigs beyond threshold ignored)", async function () {
      const message = buildMessage(ORIGIN);
      const inner = checkpointInnerHash(ethers.keccak256(message));
      const metadata = await buildMetadata(validators, inner);
      expect(await ism.verify(metadata, message)).to.equal(true);
    });
  });

  describe("verify() — rejection", function () {
    it("reverts below threshold (only 3 of required 4 signatures)", async function () {
      const message = buildMessage(ORIGIN);
      const inner = checkpointInnerHash(ethers.keccak256(message));
      const tooFew = validators.slice(0, bft(5) - 1);
      const metadata = await buildMetadata(tooFew, inner);
      await expect(ism.verify(metadata, message)).to.be.reverted;
    });

    it("reverts when signatures come from non-eligible signers", async function () {
      const message = buildMessage(ORIGIN);
      const inner = checkpointInnerHash(ethers.keccak256(message));
      const outsiders = sortedWallets(bft(5));
      const metadata = await buildMetadata(outsiders, inner);
      await expect(ism.verify(metadata, message)).to.be.revertedWith(
        "!threshold"
      );
    });

    it("reverts when one signature in the quorum is from a non-member", async function () {
      const message = buildMessage(ORIGIN);
      const inner = checkpointInnerHash(ethers.keccak256(message));
      // 3 genuine lowest members + 1 outsider, kept ascending for the two-pointer.
      const genuine = validators.slice(0, 3);
      const outsider = ethers.Wallet.createRandom();
      const mixed = [...genuine, outsider].sort((a: Wallet, b: Wallet) =>
        a.address.toLowerCase() < b.address.toLowerCase() ? -1 : 1
      );
      const metadata = await buildMetadata(mixed, inner);
      await expect(ism.verify(metadata, message)).to.be.reverted;
    });
  });

  describe("Scaling — threshold tracks the eligible-set size", function () {
    it("4-of-5 → 5-of-7 → 7-of-10 with no redeploy logic change", async function () {
      const five = await deployWith(sortedWallets(5), 5, 4);
      const seven = await deployWith(sortedWallets(7), 7, 5);
      const ten = await deployWith(sortedWallets(10), 10, 7);
      expect(await five.bridgeThreshold()).to.equal(bft(5)); // 4
      expect(await seven.bridgeThreshold()).to.equal(bft(7)); // 5
      expect(await ten.bridgeThreshold()).to.equal(bft(10)); // 7
    });

    it("a larger live set verifies with its larger quorum", async function () {
      const vs = sortedWallets(7);
      const big = await deployWith(vs, 7, 5);
      const message = buildMessage(ORIGIN);
      const inner = checkpointInnerHash(ethers.keccak256(message));
      const quorum = vs.slice(0, bft(7)); // 5 of 7
      const metadata = await buildMetadata(quorum, inner);
      expect(await big.verify(metadata, message)).to.equal(true);
    });
  });

  describe("Admin escape hatches", function () {
    it("owner can override the snapshot; threshold re-derives", async function () {
      const next = sortedWallets(7);
      await ism.adminBootstrapSnapshot(
        next.map((w) => w.address),
        100,
        2
      );
      expect(await ism.eligibleSnapshotLength()).to.equal(7n);
      expect(await ism.bridgeThreshold()).to.equal(bft(7));
    });

    it("non-owner cannot override the snapshot", async function () {
      const next = sortedWallets(7);
      await expect(
        ism.connect(stranger).adminBootstrapSnapshot(
          next.map((w) => w.address),
          100,
          2
        )
      ).to.be.revertedWithCustomError(ism, "OwnableUnauthorizedAccount");
    });

    it("rejects a stale (non-monotonic) snapshot sequence", async function () {
      const next = sortedWallets(7);
      await expect(
        ism.adminBootstrapSnapshot(
          next.map((w) => w.address),
          100,
          1 // not greater than the bootstrap sequence (1)
        )
      ).to.be.revertedWithCustomError(ism, "StaleSnapshotSequence");
    });
  });

  describe("Minimum snapshot size floor (H-02)", function () {
    it("rejects shrinking the live set below MIN_COMMITTEE_SIZE (3)", async function () {
      // Deploy a 3-member ISM (committeeSize=3, quorumM=3 satisfies 3*3>=3*2).
      const three = sortedWallets(3);
      const small = await deployWith(three, 3, 3);
      expect(await small.bridgeThreshold()).to.equal(3);

      // Rotating the live snapshot DOWN to 2 members is now rejected at write
      // time (H-02) — a 1-2 member set would collapse the BFT threshold to 0
      // and halt the bridge, so the shrink is prevented instead.
      const two = sortedWallets(2);
      await expect(
        small.adminBootstrapSnapshot(
          two.map((w) => w.address),
          50,
          2
        )
      ).to.be.revertedWithCustomError(small, "SnapshotBelowMinimum");

      // The live set is unchanged and the bridge still functions.
      expect(await small.eligibleSnapshotLength()).to.equal(3n);
      expect(await small.bridgeThreshold()).to.equal(3);
    });
  });
});
