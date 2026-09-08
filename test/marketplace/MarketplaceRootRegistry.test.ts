/**
 * @file MarketplaceRootRegistry.test.ts
 * @description Hardhat tests for the FIX_TRUSTLESS_DATA T3 anchor contract —
 * the registry that stores one Merkle root per epoch of the off-chain
 * marketplace log so that what a node serves can be checked against something
 * the node does not control.
 *
 * The suite is in two halves, deliberately.
 *
 * Against a controllable mock verifier: every rule the registry enforces on the
 * SHAPE of the history — epoch ordering, the chain of roots, the continuity of
 * sequence ranges, the refusal of an empty range or a zero root, and the fact
 * that the commitment is recomputed from the arguments rather than accepted
 * from the caller. Using a mock here means a failure in an ordering test can
 * never be blamed on signature assembly.
 *
 * Against the real `RandomCommitteeVerifier`: the end-to-end path with genuine
 * committee signatures in the commit-block-bound form that production uses
 * (`legacySignaturesAccepted` is already false on mainnet), proving the proof
 * blob the validator fleet assembles is the blob this contract accepts.
 */

/* eslint-disable @typescript-eslint/no-var-requires */
const { expect } = require("chai");
const { ethers } = require("hardhat");

const keccak256: (bytes: any) => string = ethers.keccak256;
const toUtf8Bytes: (s: string) => Uint8Array = ethers.toUtf8Bytes;
const concat: (arr: any[]) => string = ethers.concat;
const getBytes: (v: any) => Uint8Array = ethers.getBytes;
const SigningKey = ethers.SigningKey;
const abi = ethers.AbiCoder.defaultAbiCoder();

/** EIP-191 prefix the verifier wraps the signed digest with. */
const ETH_SIGNED_PREFIX = "\x19Ethereum Signed Message:\n32";

/** The namespace the marketplace log uses: `keccak256("marketplace")`. */
const NAMESPACE = keccak256(toUtf8Bytes("marketplace"));

/** The 32 zero bytes standing in for "no previous epoch". */
const ZERO_ROOT = `0x${"00".repeat(32)}`;

/** The domain tag the contract mixes into every commitment. */
const COMMITMENT_DOMAIN = keccak256(
  toUtf8Bytes("omnibazaar.marketplace.root.v1"),
);

/** Chain id the tests run against; filled in once the provider is reachable. */
let chainId = 0n;

/**
 * Recompute the commitment exactly as the contract does.
 *
 * Including the domain, the chain and the registry's own address — a commitment
 * that omitted them would be valid at every registry sharing the verifier, and
 * at epoch 1, where there is no predecessor root to force two registries to
 * share a history, that is enough to brick somebody else's namespace.
 * @param params - The epoch's identity.
 * @param params.registry - The registry the commitment is for.
 * @param params.epoch - Epoch number.
 * @param params.root - Merkle root over the epoch's leaves.
 * @param params.firstSeq - First sequence number, inclusive.
 * @param params.lastSeq - Last sequence number, inclusive.
 * @param params.prevRoot - The predecessor epoch's root.
 * @param params.namespace - The log family.
 * @returns The commitment hash.
 */
function commitmentFor(params: {
  registry: string;
  epoch: number;
  root: string;
  firstSeq: number;
  lastSeq: number;
  prevRoot: string;
  namespace?: string;
}): string {
  return keccak256(
    abi.encode(
      [
        "bytes32",
        "uint256",
        "address",
        "bytes32",
        "uint256",
        "bytes32",
        "uint64",
        "uint64",
        "bytes32",
      ],
      [
        COMMITMENT_DOMAIN,
        chainId,
        params.registry,
        params.namespace ?? NAMESPACE,
        params.epoch,
        params.root,
        params.firstSeq,
        params.lastSeq,
        params.prevRoot,
      ],
    ),
  );
}

/**
 * A stand-in Merkle root, distinct per label so a mixed-up root is visible.
 * @param label - Anything that names this root.
 * @returns A non-zero 32-byte value.
 */
function rootFor(label: string): string {
  return keccak256(toUtf8Bytes(`root:${label}`));
}

describe("MarketplaceRootRegistry", function () {
  let registry: any;
  let mockVerifier: any;
  let admin: any;
  let stranger: any;
  let attesterA: any;
  let attesterB: any;

  /**
   * Deploy the registry against the mock verifier, with a passing verdict and
   * a four-address attester list by default.
   */
  async function deployWithMock(): Promise<void> {
    const Mock = await ethers.getContractFactory(
      "MockRootAttestationVerifier",
    );
    mockVerifier = await Mock.deploy();
    await mockVerifier.waitForDeployment();

    const attesters = [
      attesterA.address,
      attesterB.address,
      stranger.address,
      admin.address,
    ];
    await mockVerifier.setAttesters(attesters);
    await mockVerifier.setThreshold(4);
    await mockVerifier.setValid(true);

    const Registry = await ethers.getContractFactory(
      "MarketplaceRootRegistry",
    );
    registry = await Registry.deploy(
      admin.address,
      await mockVerifier.getAddress(),
    );
    await registry.waitForDeployment();
  }

  /**
   * Publish one epoch through the registry with the mock verifier passing.
   * @param params - The epoch to publish.
   * @param params.epoch - Epoch number.
   * @param params.root - Merkle root.
   * @param params.firstSeq - First sequence number, inclusive.
   * @param params.lastSeq - Last sequence number, inclusive.
   * @param params.prevRoot - The predecessor epoch's root.
   * @returns The transaction.
   */
  async function publish(params: {
    epoch: number;
    root: string;
    firstSeq: number;
    lastSeq: number;
    prevRoot: string;
  }): Promise<any> {
    return registry.publishRoot(
      NAMESPACE,
      params.epoch,
      params.root,
      params.firstSeq,
      params.lastSeq,
      params.prevRoot,
      "0xdeadbeef",
    );
  }

  beforeEach(async function () {
    chainId = (await ethers.provider.getNetwork()).chainId;
    const signers = await ethers.getSigners();
    admin = signers[0];
    stranger = signers[1];
    attesterA = signers[2];
    attesterB = signers[3];
    await deployWithMock();
  });

  // ───────────────────────────────────────────────────── construction ──

  describe("construction", () => {
    it("records the admin and the verifier", async () => {
      expect(await registry.admin()).to.equal(admin.address);
      expect(await registry.verifier()).to.equal(
        await mockVerifier.getAddress(),
      );
    });

    it("starts every namespace at epoch 1", async () => {
      expect(await registry.expectedEpoch(NAMESPACE)).to.equal(1n);
      expect(await registry.latestEpoch(NAMESPACE)).to.equal(0n);
      expect(await registry.rootAt(NAMESPACE, 1)).to.equal(ZERO_ROOT);
    });

    it("refuses a zero admin or a zero verifier", async () => {
      const Registry = await ethers.getContractFactory(
        "MarketplaceRootRegistry",
      );
      await expect(
        Registry.deploy(ethers.ZeroAddress, await mockVerifier.getAddress()),
      ).to.be.revertedWithCustomError(registry, "ZeroAddress");
      await expect(
        Registry.deploy(admin.address, ethers.ZeroAddress),
      ).to.be.revertedWithCustomError(registry, "ZeroAddress");
    });
  });

  // ─────────────────────────────────────────────────────── publishing ──

  describe("publishing the first epoch", () => {
    it("anchors epoch 1 and records the range", async () => {
      const root = rootFor("e1");
      await expect(
        publish({
          epoch: 1,
          root,
          firstSeq: 1,
          lastSeq: 10,
          prevRoot: ZERO_ROOT,
        }),
      ).to.emit(registry, "RootPublished");

      expect(await registry.rootAt(NAMESPACE, 1)).to.equal(root);
      expect(await registry.latestEpoch(NAMESPACE)).to.equal(1n);
      expect(await registry.expectedEpoch(NAMESPACE)).to.equal(2n);

      const stored = await registry.epochAt(NAMESPACE, 1);
      expect(stored.root).to.equal(root);
      expect(stored.firstSeq).to.equal(1n);
      expect(stored.lastSeq).to.equal(10n);
      expect(stored.publishedAt).to.be.greaterThan(0n);
    });

    it("is permissionless — a stranger may pay for the anchor", async () => {
      await expect(
        registry
          .connect(stranger)
          .publishRoot(
            NAMESPACE,
            1,
            rootFor("e1"),
            1,
            10,
            ZERO_ROOT,
            "0xdeadbeef",
          ),
      ).to.emit(registry, "RootPublished");
    });

    it("requires epoch 1 to chain to the zero root", async () => {
      await expect(
        publish({
          epoch: 1,
          root: rootFor("e1"),
          firstSeq: 1,
          lastSeq: 10,
          prevRoot: rootFor("invented"),
        }),
      ).to.be.revertedWithCustomError(registry, "RootChainBroken");
    });

    it("requires epoch 1 to begin at sequence 1", async () => {
      await expect(
        publish({
          epoch: 1,
          root: rootFor("e1"),
          firstSeq: 5,
          lastSeq: 10,
          prevRoot: ZERO_ROOT,
        }),
      ).to.be.revertedWithCustomError(registry, "SequenceGap");
    });

    it("refuses to start at any epoch but 1", async () => {
      await expect(
        publish({
          epoch: 2,
          root: rootFor("e2"),
          firstSeq: 1,
          lastSeq: 10,
          prevRoot: ZERO_ROOT,
        }),
      )
        .to.be.revertedWithCustomError(registry, "EpochOutOfOrder")
        .withArgs(2n, 1n);
    });
  });

  describe("the chain of epochs", () => {
    const rootOne = rootFor("e1");
    const rootTwo = rootFor("e2");

    beforeEach(async () => {
      await publish({
        epoch: 1,
        root: rootOne,
        firstSeq: 1,
        lastSeq: 10,
        prevRoot: ZERO_ROOT,
      });
    });

    it("accepts epoch 2 when it chains and resumes correctly", async () => {
      await publish({
        epoch: 2,
        root: rootTwo,
        firstSeq: 11,
        lastSeq: 25,
        prevRoot: rootOne,
      });
      expect(await registry.rootAt(NAMESPACE, 2)).to.equal(rootTwo);
      expect(await registry.latestEpoch(NAMESPACE)).to.equal(2n);
    });

    it("refuses a re-parented epoch — prevRoot must be the stored predecessor", async () => {
      await expect(
        publish({
          epoch: 2,
          root: rootTwo,
          firstSeq: 11,
          lastSeq: 25,
          prevRoot: rootFor("some other history"),
        }),
      )
        .to.be.revertedWithCustomError(registry, "RootChainBroken")
        .withArgs(rootFor("some other history"), rootOne);
    });

    it("refuses a gap in the sequence range", async () => {
      // Entries 11 and 12 would be committed to no root at all. A root
      // comparison cannot see this; the range check is what catches it.
      await expect(
        publish({
          epoch: 2,
          root: rootTwo,
          firstSeq: 13,
          lastSeq: 25,
          prevRoot: rootOne,
        }),
      )
        .to.be.revertedWithCustomError(registry, "SequenceGap")
        .withArgs(13n, 11n);
    });

    it("refuses an overlapping range", async () => {
      // Entries 8 to 10 would be committed to two roots.
      await expect(
        publish({
          epoch: 2,
          root: rootTwo,
          firstSeq: 8,
          lastSeq: 25,
          prevRoot: rootOne,
        }),
      )
        .to.be.revertedWithCustomError(registry, "SequenceGap")
        .withArgs(8n, 11n);
    });

    it("refuses to republish an epoch, even with the same root", async () => {
      await expect(
        publish({
          epoch: 1,
          root: rootOne,
          firstSeq: 1,
          lastSeq: 10,
          prevRoot: ZERO_ROOT,
        }),
      )
        .to.be.revertedWithCustomError(registry, "EpochOutOfOrder")
        .withArgs(1n, 2n);
    });

    it("refuses to skip an epoch", async () => {
      await expect(
        publish({
          epoch: 3,
          root: rootFor("e3"),
          firstSeq: 11,
          lastSeq: 25,
          prevRoot: rootOne,
        }),
      )
        .to.be.revertedWithCustomError(registry, "EpochOutOfOrder")
        .withArgs(3n, 2n);
    });

    it("keeps namespaces independent", async () => {
      const other = keccak256(toUtf8Bytes("some-other-log"));
      expect(await registry.expectedEpoch(other)).to.equal(1n);
      await registry.publishRoot(
        other,
        1,
        rootFor("other-e1"),
        1,
        3,
        ZERO_ROOT,
        "0xdeadbeef",
      );
      expect(await registry.rootAt(other, 1)).to.equal(rootFor("other-e1"));
      // The marketplace namespace is untouched.
      expect(await registry.latestEpoch(NAMESPACE)).to.equal(1n);
    });
  });

  describe("the range itself", () => {
    it("refuses an inverted range", async () => {
      await expect(
        publish({
          epoch: 1,
          root: rootFor("e1"),
          firstSeq: 10,
          lastSeq: 4,
          prevRoot: ZERO_ROOT,
        }),
      ).to.be.revertedWithCustomError(registry, "EmptyRange");
    });

    it("accepts a single-entry epoch", async () => {
      await publish({
        epoch: 1,
        root: rootFor("e1"),
        firstSeq: 1,
        lastSeq: 1,
        prevRoot: ZERO_ROOT,
      });
      const stored = await registry.epochAt(NAMESPACE, 1);
      expect(stored.firstSeq).to.equal(1n);
      expect(stored.lastSeq).to.equal(1n);
    });

    it("refuses a lastSeq at the uint64 maximum", async () => {
      // Accepting it would make every later epoch's `previous.lastSeq + 1`
      // trap on overflow, bricking the namespace behind an unlabelled panic
      // with no admin path back.
      // Passed as a bigint: 2^64 − 1 is not representable as a JS number, and
      // rounding it would test a different value than the one that matters.
      await expect(
        registry.publishRoot(
          NAMESPACE,
          1,
          rootFor("e1"),
          1n,
          2n ** 64n - 1n,
          ZERO_ROOT,
          "0xdeadbeef",
        ),
      ).to.be.revertedWithCustomError(registry, "SequenceExhausted");
    });

    it("refuses a zero root", async () => {
      await expect(
        publish({
          epoch: 1,
          root: ZERO_ROOT,
          firstSeq: 1,
          lastSeq: 10,
          prevRoot: ZERO_ROOT,
        }),
      ).to.be.revertedWithCustomError(registry, "ZeroRoot");
    });
  });

  // ───────────────────────────────────────────────── the commitment ──

  describe("the commitment", () => {
    it("is recomputed from the arguments, not taken from the caller", async () => {
      const root = rootFor("e1");
      // The verifier will refuse anything but this exact commitment, computed
      // here independently of the contract. If the registry derived the
      // commitment any other way, the publish below could not succeed.
      await mockVerifier.expectMessageHash(
        commitmentFor({
          registry: await registry.getAddress(),
          epoch: 1,
          root,
          firstSeq: 1,
          lastSeq: 10,
          prevRoot: ZERO_ROOT,
        }),
      );
      await publish({
        epoch: 1,
        root,
        firstSeq: 1,
        lastSeq: 10,
        prevRoot: ZERO_ROOT,
      });
      expect(await registry.rootAt(NAMESPACE, 1)).to.equal(root);
    });

    it("does not compute the commitment over some other epoch's fields", async () => {
      const root = rootFor("e1");
      // A commitment over the same root but a different range. The registry
      // must not produce it, so the verifier must never be asked about it.
      await mockVerifier.expectMessageHash(
        commitmentFor({
          registry: await registry.getAddress(),
          epoch: 1,
          root,
          firstSeq: 1,
          lastSeq: 99,
          prevRoot: ZERO_ROOT,
        }),
      );
      await expect(
        publish({
          epoch: 1,
          root,
          firstSeq: 1,
          lastSeq: 10,
          prevRoot: ZERO_ROOT,
        }),
      ).to.be.revertedWithCustomError(registry, "AttestationRejected");
    });

    it("changes when any single field changes", async () => {
      const base = {
        registry: await registry.getAddress(),
        epoch: 1,
        root: rootFor("e1"),
        firstSeq: 1,
        lastSeq: 10,
        prevRoot: ZERO_ROOT,
      };
      const baseline = commitmentFor(base);
      const variants = [
        { ...base, epoch: 2 },
        { ...base, root: rootFor("different") },
        { ...base, firstSeq: 2 },
        { ...base, lastSeq: 11 },
        { ...base, prevRoot: rootFor("different-parent") },
        { ...base, namespace: keccak256(toUtf8Bytes("other")) },
      ];
      for (const variant of variants) {
        expect(commitmentFor(variant)).to.not.equal(baseline);
      }
    });

    it("agrees with the contract's own commitmentFor view", async () => {
      const root = rootFor("e1");
      expect(
        await registry.commitmentFor(NAMESPACE, 1, root, 1, 10, ZERO_ROOT),
      ).to.equal(
        commitmentFor({
          registry: await registry.getAddress(),
          epoch: 1,
          root,
          firstSeq: 1,
          lastSeq: 10,
          prevRoot: ZERO_ROOT,
        }),
      );
    });

    it("is bound to THIS registry, so a sibling's proof cannot be replayed", async () => {
      // 🛑 The hole this closes. Two registries pointed at the same verifier
      // both sit at epoch 1, where there is no predecessor root to force them
      // to share a history — so without the domain, an attestation for one
      // registry's epoch 1 could be replayed into the other, permanently
      // anchoring the wrong root and bricking a namespace that had never been
      // used. That is exactly the independent-operator case this design exists
      // to make safe.
      const Registry = await ethers.getContractFactory(
        "MarketplaceRootRegistry",
      );
      const sibling = await Registry.deploy(
        admin.address,
        await mockVerifier.getAddress(),
      );
      await sibling.waitForDeployment();

      const root = rootFor("e1");
      const args = [NAMESPACE, 1, root, 1, 10, ZERO_ROOT, "0xdeadbeef"];

      // The two registries do not even ask the verifier the same question.
      expect(
        await sibling.commitmentFor(NAMESPACE, 1, root, 1, 10, ZERO_ROOT),
      ).to.not.equal(
        await registry.commitmentFor(NAMESPACE, 1, root, 1, 10, ZERO_ROOT),
      );

      // Attest exactly what the sibling needs, and nothing else.
      await mockVerifier.expectMessageHash(
        await sibling.commitmentFor(NAMESPACE, 1, root, 1, 10, ZERO_ROOT),
      );
      await sibling.publishRoot(...args);
      expect(await sibling.rootAt(NAMESPACE, 1)).to.equal(root);

      // The same proof, the same calldata, replayed at this registry: refused,
      // and this registry's epoch 1 is still free.
      await expect(registry.publishRoot(...args)).to.be.revertedWithCustomError(
        registry,
        "AttestationRejected",
      );
      expect(await registry.rootAt(NAMESPACE, 1)).to.equal(ZERO_ROOT);
      expect(await registry.expectedEpoch(NAMESPACE)).to.equal(1n);
    });

    it("passes the proof blob through untouched", async () => {
      await mockVerifier.expectProof("0x0102030405");
      await registry.publishRoot(
        NAMESPACE,
        1,
        rootFor("e1"),
        1,
        10,
        ZERO_ROOT,
        "0x0102030405",
      );
      expect(await registry.rootAt(NAMESPACE, 1)).to.equal(rootFor("e1"));

      // And a different blob is not silently substituted.
      await mockVerifier.expectProof("0x0102030405");
      await expect(
        registry.publishRoot(
          NAMESPACE,
          2,
          rootFor("e2"),
          11,
          12,
          rootFor("e1"),
          "0x99",
        ),
      ).to.be.revertedWithCustomError(registry, "AttestationRejected");
    });
  });

  // ─────────────────────────────────────────────────── the attestation ──

  describe("the attestation", () => {
    it("refuses a proof the verifier rejects", async () => {
      await mockVerifier.setValid(false);
      await expect(
        publish({
          epoch: 1,
          root: rootFor("e1"),
          firstSeq: 1,
          lastSeq: 10,
          prevRoot: ZERO_ROOT,
        }),
      ).to.be.revertedWithCustomError(registry, "AttestationRejected");
    });

    it("refuses a proof carrying fewer attesters than the quorum", async () => {
      await mockVerifier.setAttesters([attesterA.address, attesterB.address]);
      await expect(
        publish({
          epoch: 1,
          root: rootFor("e1"),
          firstSeq: 1,
          lastSeq: 10,
          prevRoot: ZERO_ROOT,
        }),
      )
        .to.be.revertedWithCustomError(registry, "QuorumNotMet")
        .withArgs(2n, 4n);
    });

    it("keeps the quorum floor it was deployed with, even if the verifier lowers its own", async () => {
      // The runtime check alone compares a verifier against itself, so it can
      // never catch a verifier that simply declares a lower bar. The frozen
      // floor is what actually stops the bar dropping.
      expect(await registry.MIN_ATTESTERS()).to.equal(4n);
      await mockVerifier.setThreshold(1);
      await mockVerifier.setAttesters([attesterA.address]);
      await expect(
        publish({
          epoch: 1,
          root: rootFor("e1"),
          firstSeq: 1,
          lastSeq: 10,
          prevRoot: ZERO_ROOT,
        }),
      )
        .to.be.revertedWithCustomError(registry, "QuorumNotMet")
        .withArgs(1n, 4n);
    });

    it("follows the verifier upward when the committee grows", async () => {
      await mockVerifier.setThreshold(6);
      await expect(
        publish({
          epoch: 1,
          root: rootFor("e1"),
          firstSeq: 1,
          lastSeq: 10,
          prevRoot: ZERO_ROOT,
        }),
      )
        .to.be.revertedWithCustomError(registry, "QuorumNotMet")
        .withArgs(4n, 6n);
    });

    it("leaves nothing behind when the attestation fails", async () => {
      await mockVerifier.setValid(false);
      await expect(
        publish({
          epoch: 1,
          root: rootFor("e1"),
          firstSeq: 1,
          lastSeq: 10,
          prevRoot: ZERO_ROOT,
        }),
      ).to.be.reverted;
      expect(await registry.expectedEpoch(NAMESPACE)).to.equal(1n);
      expect(await registry.rootAt(NAMESPACE, 1)).to.equal(ZERO_ROOT);
    });
  });

  // ──────────────────────────────────────────────────────────── admin ──

  describe("administration", () => {
    it("lets the admin repoint the verifier, with no delay", async () => {
      const Mock = await ethers.getContractFactory(
        "MockRootAttestationVerifier",
      );
      const replacement = await Mock.deploy();
      await replacement.waitForDeployment();
      await expect(registry.setVerifier(await replacement.getAddress()))
        .to.emit(registry, "VerifierUpdated")
        .withArgs(
          await mockVerifier.getAddress(),
          await replacement.getAddress(),
        );
      expect(await registry.verifier()).to.equal(
        await replacement.getAddress(),
      );
    });

    it("refuses a verifier that does not answer as one", async () => {
      // An address with no code would otherwise make every publish revert on
      // the compiler's own extcodesize guard, with nothing naming the cause,
      // until somebody noticed the marketplace had stopped being provable.
      await expect(
        registry.setVerifier(stranger.address),
      ).to.be.revertedWithCustomError(registry, "NotAVerifier");
    });

    it("refuses a verifier change from anyone else", async () => {
      await expect(
        registry.connect(stranger).setVerifier(stranger.address),
      ).to.be.revertedWithCustomError(registry, "NotAdmin");
    });

    it("transfers administration in one call", async () => {
      await expect(registry.transferAdmin(stranger.address))
        .to.emit(registry, "AdminTransferred")
        .withArgs(admin.address, stranger.address);
      expect(await registry.admin()).to.equal(stranger.address);
      await expect(
        registry.setVerifier(stranger.address),
      ).to.be.revertedWithCustomError(registry, "NotAdmin");
    });

    it("refuses zero addresses", async () => {
      await expect(
        registry.setVerifier(ethers.ZeroAddress),
      ).to.be.revertedWithCustomError(registry, "ZeroAddress");
      await expect(
        registry.transferAdmin(ethers.ZeroAddress),
      ).to.be.revertedWithCustomError(registry, "ZeroAddress");
    });

    it("cannot alter a root that has already been published", async () => {
      const root = rootFor("e1");
      await publish({
        epoch: 1,
        root,
        firstSeq: 1,
        lastSeq: 10,
        prevRoot: ZERO_ROOT,
      });
      // Even a verifier that approves everything cannot get epoch 1 rewritten:
      // the monotonic check rejects it before the verifier is consulted.
      await expect(
        publish({
          epoch: 1,
          root: rootFor("rewritten"),
          firstSeq: 1,
          lastSeq: 10,
          prevRoot: ZERO_ROOT,
        }),
      ).to.be.revertedWithCustomError(registry, "EpochOutOfOrder");
      expect(await registry.rootAt(NAMESPACE, 1)).to.equal(root);
    });
  });

  // ──────────────────────────── end to end, against the real verifier ──

  describe("against the real RandomCommitteeVerifier", () => {
    let verifier: any;
    let realRegistry: any;
    let validators: any[];

    /**
     * Sign a digest under the EIP-191 envelope the verifier recovers with.
     * @param wallet - The signing wallet.
     * @param digest - The 32-byte digest.
     * @returns The 65-byte signature.
     */
    function signEthMessage(wallet: any, digest: string): string {
      const ethSigned = keccak256(
        concat([toUtf8Bytes(ETH_SIGNED_PREFIX), getBytes(digest)]),
      );
      return new SigningKey(wallet.privateKey).sign(ethSigned).serialized;
    }

    /**
     * Assemble the proof blob in the commit-block-bound form that mainnet
     * requires — `legacySignaturesAccepted` is already false there, so the
     * unbound form the migration window allowed is no longer accepted.
     * @param commitBlock - The committee-selection block.
     * @param signers - The wallets contributing signatures.
     * @param messageHash - The commitment being attested.
     * @returns `commitBlock(32) || sig0(65) || ...` with signers sorted.
     */
    function buildBoundProof(
      commitBlock: number,
      signers: any[],
      messageHash: string,
    ): string {
      const bound = keccak256(
        abi.encode(["bytes32", "uint256"], [messageHash, commitBlock]),
      );
      const sorted = [...signers].sort((a, b) =>
        a.address.toLowerCase() < b.address.toLowerCase() ? -1 : 1,
      );
      return concat([
        ethers.toBeHex(commitBlock, 32),
        ...sorted.map((w) => signEthMessage(w, bound)),
      ]);
    }

    beforeEach(async () => {
      validators = [];
      for (let i = 0; i < 5; i++) {
        validators.push(ethers.Wallet.createRandom().connect(ethers.provider));
      }

      const MockBootstrap = await ethers.getContractFactory(
        "MockBootstrapForAttestation",
      );
      const bootstrap = await MockBootstrap.deploy();
      await bootstrap.waitForDeployment();

      const MockOmniCore = await ethers.getContractFactory(
        "MockOmniCoreForAttestation",
      );
      const omniCore = await MockOmniCore.deploy();
      await omniCore.waitForDeployment();

      const MockRegistration = await ethers.getContractFactory(
        "MockOmniRegistrationForAttestation",
      );
      const registration = await MockRegistration.deploy();
      await registration.waitForDeployment();

      for (const v of validators) {
        await bootstrap.setNodeActive(v.address, true, 0);
        await registration.setKycTier(v.address, 3);
        await omniCore.setStake(v.address, ethers.parseEther("1000000"), true);
      }

      const Verifier = await ethers.getContractFactory(
        "RandomCommitteeVerifier",
      );
      verifier = await Verifier.deploy(
        admin.address,
        await bootstrap.getAddress(),
        await omniCore.getAddress(),
        await registration.getAddress(),
        5,
        4,
        3,
        ethers.parseEther("1000000"),
      );
      await verifier.waitForDeployment();
      await verifier.refreshEligibleSet();
      // Mainnet has the migration window closed; test the form that is live.
      await verifier.disableLegacySignatures();

      const Registry = await ethers.getContractFactory(
        "MarketplaceRootRegistry",
      );
      realRegistry = await Registry.deploy(
        admin.address,
        await verifier.getAddress(),
      );
      await realRegistry.waitForDeployment();
    });

    it("anchors an epoch attested by a real four-of-five committee", async () => {
      const root = rootFor("real-e1");
      const commitment = commitmentFor({
        registry: await realRegistry.getAddress(),
        epoch: 1,
        root,
        firstSeq: 1,
        lastSeq: 7,
        prevRoot: ZERO_ROOT,
      });

      await ethers.provider.send("evm_mine", []);
      const commitBlock = (await ethers.provider.getBlockNumber()) - 1;
      const committee = await verifier.committeeFor(commitment, commitBlock);
      expect(committee.length).to.equal(5);

      // Take four of the five committee members, as the coordinator does.
      const byAddress = new Map(
        validators.map((v: any) => [v.address.toLowerCase(), v]),
      );
      const signers = committee
        .slice(0, 4)
        .map((addr: string) => byAddress.get(addr.toLowerCase()));
      expect(signers.every((s: any) => s !== undefined)).to.equal(true);

      const proof = buildBoundProof(commitBlock, signers, commitment);
      await expect(
        realRegistry.publishRoot(
          NAMESPACE,
          1,
          root,
          1,
          7,
          ZERO_ROOT,
          proof,
        ),
      ).to.emit(realRegistry, "RootPublished");

      expect(await realRegistry.rootAt(NAMESPACE, 1)).to.equal(root);
    });

    it("refuses a root the committee did not attest to", async () => {
      const honestRoot = rootFor("honest");
      const commitment = commitmentFor({
        registry: await realRegistry.getAddress(),
        epoch: 1,
        root: honestRoot,
        firstSeq: 1,
        lastSeq: 7,
        prevRoot: ZERO_ROOT,
      });

      await ethers.provider.send("evm_mine", []);
      const commitBlock = (await ethers.provider.getBlockNumber()) - 1;
      const committee = await verifier.committeeFor(commitment, commitBlock);
      const byAddress = new Map(
        validators.map((v: any) => [v.address.toLowerCase(), v]),
      );
      const signers = committee
        .slice(0, 4)
        .map((addr: string) => byAddress.get(addr.toLowerCase()));
      const proof = buildBoundProof(commitBlock, signers, commitment);

      // The proof is genuine — for a different root. Swapping the root makes
      // the registry recompute a different commitment, which the committee
      // never signed, so the signatures recover to nobody in the committee.
      await expect(
        realRegistry.publishRoot(
          NAMESPACE,
          1,
          rootFor("substituted"),
          1,
          7,
          ZERO_ROOT,
          proof,
        ),
      ).to.be.revertedWithCustomError(realRegistry, "AttestationRejected");
    });

    it("refuses a sub-quorum committee", async () => {
      const root = rootFor("real-e1");
      const commitment = commitmentFor({
        registry: await realRegistry.getAddress(),
        epoch: 1,
        root,
        firstSeq: 1,
        lastSeq: 7,
        prevRoot: ZERO_ROOT,
      });
      await ethers.provider.send("evm_mine", []);
      const commitBlock = (await ethers.provider.getBlockNumber()) - 1;
      const committee = await verifier.committeeFor(commitment, commitBlock);
      const byAddress = new Map(
        validators.map((v: any) => [v.address.toLowerCase(), v]),
      );
      const signers = committee
        .slice(0, 3)
        .map((addr: string) => byAddress.get(addr.toLowerCase()));
      const proof = buildBoundProof(commitBlock, signers, commitment);

      await expect(
        realRegistry.publishRoot(
          NAMESPACE,
          1,
          root,
          1,
          7,
          ZERO_ROOT,
          proof,
        ),
      ).to.be.revertedWithCustomError(realRegistry, "AttestationRejected");
    });
  });
});
