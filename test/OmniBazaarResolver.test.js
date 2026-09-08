/**
 * @file OmniBazaarResolver.test.js
 * @description Tests for OmniBazaarResolver — ENSIP-10 + ERC-3668 wildcard resolver
 *              with M-of-N ECDSA threshold signature verification.
 *
 * Tests cover:
 *  - Constructor validation (empty signer set, zero signer, unsorted/duplicate
 *    signers, out-of-range threshold, empty URLs)
 *  - resolve() always reverts with OffchainLookup
 *  - resolveWithProof() accepts a valid M-of-N signature (4-of-5)
 *  - resolveWithProof() rejects: below-threshold, wrong signer, duplicate
 *    signature, unsorted signatures, expired response, tampered result,
 *    tampered extraData
 *  - Admin functions (setGatewayURLs, setSigners, setResponseTTL) — owner only
 *  - supportsInterface returns correct values
 *  - Ownable2Step ownership transfer
 */

const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

/** ABI coder instance for encoding/decoding */
const abiCoder = ethers.AbiCoder.defaultAbiCoder();

/** Number of distinct gateway signers in the test committee. */
const NUM_SIGNERS = 5;
/** Minimum distinct signatures required (4-of-5). */
const REQUIRED_SIGNATURES = 4;

/**
 * Encode a human-readable domain name to DNS wire format
 * @param {string} name - Domain name (e.g., "alice.omnibazaar.eth")
 * @returns {string} Hex string of DNS-encoded name
 */
function encodeDNSName(name) {
  const labels = name.split(".");
  let result = "0x";
  for (const label of labels) {
    const length = label.length.toString(16).padStart(2, "0");
    const hex = Buffer.from(label, "utf8").toString("hex");
    result += length + hex;
  }
  result += "00"; // null terminator
  return result;
}

/**
 * Sort signer accounts ascending by address, mirroring the resolver's
 * sorted-unique storage + verification assumption.
 * @param {Array<import('ethers').Signer>} signers - Signer accounts
 * @returns {Array<import('ethers').Signer>} Sorted copy
 */
function sortSignersByAddress(signers) {
  return [...signers].sort((a, b) =>
    BigInt(a.address) < BigInt(b.address)
      ? -1
      : BigInt(a.address) > BigInt(b.address)
        ? 1
        : 0,
  );
}

/**
 * Sign a CCIP-Read gateway response using EIP-191 personal sign
 * Signs the chain-bound digest: keccak256(abi.encode(chainid, resolver,
 * result, expires, extraData)). Mirrors the deployed resolver's
 * resolveWithProof AND the live CCIPReadGateway signer byte-for-byte.
 * @param {import('ethers').Signer} signerWallet - The ethers signer to use
 * @param {string} resolverAddress - The resolver the digest is bound to
 * @param {number|bigint} chainId - The chain the digest is bound to
 * @param {string} result - ABI-encoded result bytes (hex)
 * @param {bigint} expires - Expiration timestamp (uint64)
 * @param {string} extraData - Extra data bytes (hex) from resolve()
 * @returns {Promise<string>} The ECDSA signature bytes (hex)
 */
async function signResponse(
  signerWallet,
  resolverAddress,
  chainId,
  result,
  expires,
  extraData,
) {
  const packed = abiCoder.encode(
    ["uint256", "address", "bytes", "uint64", "bytes"],
    [chainId, resolverAddress, result, expires, extraData],
  );
  const innerHash = ethers.keccak256(packed);
  const signature = await signerWallet.signMessage(ethers.getBytes(innerHash));
  return signature;
}

/**
 * Build a concatenated M-of-N signature blob from a set of signer accounts.
 * Each signer produces one 65-byte signature; the blob is ordered by
 * ascending recovered signer address (required by the resolver).
 * @param {Array<import('ethers').Signer>} signers - Signers to include
 * @param {string} resolverAddress - The resolver the digest is bound to
 * @param {number|bigint} chainId - The chain the digest is bound to
 * @param {string} result - ABI-encoded result bytes
 * @param {bigint} expires - Expiration timestamp
 * @param {string} extraData - Extra data bytes
 * @returns {Promise<string>} Concatenated signature bytes (hex)
 */
async function signThreshold(
  signers,
  resolverAddress,
  chainId,
  result,
  expires,
  extraData,
) {
  const sorted = sortSignersByAddress(signers);
  let blob = "0x";
  for (const s of sorted) {
    const sig = await signResponse(
      s,
      resolverAddress,
      chainId,
      result,
      expires,
      extraData,
    );
    blob += sig.slice(2);
  }
  return blob;
}

describe("OmniBazaarResolver", function () {
  this.timeout(60000);

  const GATEWAY_URL =
    "https://ens-gateway.omnibazaar.com/ccip/{sender}/{data}.json";
  const RESPONSE_TTL = 300; // 5 minutes

  let owner, committee, user;
  let resolver;
  /** Sorted signer accounts (ascending address) used for deployment. */
  let sortedCommittee;
  /** The deployed resolver's address (digest binding). */
  let resolverAddress;
  /** The chain id the resolver runs on (digest binding). */
  let chainId;

  beforeEach(async function () {
    const all = await ethers.getSigners();
    owner = all[0];
    user = all[NUM_SIGNERS + 1];
    committee = all.slice(1, 1 + NUM_SIGNERS);
    sortedCommittee = sortSignersByAddress(committee);

    const OmniBazaarResolver =
      await ethers.getContractFactory("OmniBazaarResolver");
    resolver = await OmniBazaarResolver.deploy(
      [GATEWAY_URL],
      sortedCommittee.map((s) => s.address),
      REQUIRED_SIGNATURES,
      RESPONSE_TTL,
    );
    await resolver.waitForDeployment();
    resolverAddress = await resolver.getAddress();
    chainId = Number((await ethers.provider.getNetwork()).chainId);
  });

  // ================================================================
  //  Constructor
  // ================================================================

  describe("Constructor", function () {
    it("should set gateway URLs correctly", async function () {
      const urls = await resolver.getGatewayURLs();
      expect(urls).to.have.lengthOf(1);
      expect(urls[0]).to.equal(GATEWAY_URL);
    });

    it("should set the signer set correctly (sorted ascending)", async function () {
      const signers = await resolver.getSigners();
      expect(signers).to.have.lengthOf(NUM_SIGNERS);
      const expected = sortedCommittee.map((s) => s.address);
      expect(signers).to.deep.equal(expected);
    });

    it("should set requiredSignatures correctly", async function () {
      expect(await resolver.requiredSignatures()).to.equal(
        REQUIRED_SIGNATURES,
      );
    });

    it("should set responseTTL correctly", async function () {
      expect(await resolver.responseTTL()).to.equal(RESPONSE_TTL);
    });

    it("should set owner to deployer", async function () {
      expect(await resolver.owner()).to.equal(owner.address);
    });

    it("should revert if gateway URLs are empty", async function () {
      const Factory = await ethers.getContractFactory("OmniBazaarResolver");
      await expect(
        Factory.deploy(
          [],
          sortedCommittee.map((s) => s.address),
          REQUIRED_SIGNATURES,
          RESPONSE_TTL,
        ),
      ).to.be.revertedWithCustomError(resolver, "NoGatewayURLs");
    });

    it("should revert if signer set is empty", async function () {
      const Factory = await ethers.getContractFactory("OmniBazaarResolver");
      await expect(
        Factory.deploy([GATEWAY_URL], [], 1, RESPONSE_TTL),
      ).to.be.revertedWithCustomError(resolver, "ZeroSigner");
    });

    it("should revert if a signer is the zero address", async function () {
      const Factory = await ethers.getContractFactory("OmniBazaarResolver");
      const bad = [ethers.ZeroAddress, ...sortedCommittee.slice(1).map((s) => s.address)];
      await expect(
        Factory.deploy([GATEWAY_URL], bad, REQUIRED_SIGNATURES, RESPONSE_TTL),
      ).to.be.revertedWithCustomError(resolver, "ZeroSigner");
    });

    it("should revert if requiredSignatures is zero", async function () {
      const Factory = await ethers.getContractFactory("OmniBazaarResolver");
      await expect(
        Factory.deploy(
          [GATEWAY_URL],
          sortedCommittee.map((s) => s.address),
          0,
          RESPONSE_TTL,
        ),
      ).to.be.revertedWithCustomError(resolver, "RequiredSignaturesOutOfRange");
    });

    it("should revert if requiredSignatures exceeds the set length", async function () {
      const Factory = await ethers.getContractFactory("OmniBazaarResolver");
      await expect(
        Factory.deploy(
          [GATEWAY_URL],
          sortedCommittee.map((s) => s.address),
          NUM_SIGNERS + 1,
          RESPONSE_TTL,
        ),
      ).to.be.revertedWithCustomError(resolver, "RequiredSignaturesOutOfRange");
    });

    it("should revert if signers are not sorted ascending", async function () {
      const Factory = await ethers.getContractFactory("OmniBazaarResolver");
      const reversed = sortedCommittee.map((s) => s.address).reverse();
      await expect(
        Factory.deploy([GATEWAY_URL], reversed, REQUIRED_SIGNATURES, RESPONSE_TTL),
      ).to.be.revertedWithCustomError(resolver, "InvalidSignerOrder");
    });

    it("should revert on duplicate signer", async function () {
      const Factory = await ethers.getContractFactory("OmniBazaarResolver");
      const dup = [sortedCommittee[0].address, ...sortedCommittee.map((s) => s.address)];
      await expect(
        Factory.deploy([GATEWAY_URL], dup, REQUIRED_SIGNATURES, RESPONSE_TTL),
      ).to.be.revertedWithCustomError(resolver, "InvalidSignerOrder");
    });

    it("should accept zero TTL", async function () {
      const Factory = await ethers.getContractFactory("OmniBazaarResolver");
      const r = await Factory.deploy(
        [GATEWAY_URL],
        sortedCommittee.map((s) => s.address),
        REQUIRED_SIGNATURES,
        0,
      );
      await r.waitForDeployment();
      expect(await r.responseTTL()).to.equal(0);
    });
  });

  // ================================================================
  //  resolve() — always reverts with OffchainLookup
  // ================================================================

  describe("resolve()", function () {
    it("should revert with OffchainLookup", async function () {
      const dnsName = encodeDNSName("alice.omnibazaar.eth");
      const addrSelector = "0x3b3b57de";
      const node = ethers.namehash("alice.omnibazaar.eth");
      const resolverCalldata = addrSelector + node.slice(2);

      const resolverAddress = await resolver.getAddress();

      try {
        await resolver.resolve(dnsName, resolverCalldata);
        expect.fail("Should have reverted");
      } catch (err) {
        expect(err.data).to.not.be.undefined;

        const offchainLookupSelector = "0x556f1830";
        expect(err.data.slice(0, 10)).to.equal(offchainLookupSelector);

        const decoded = abiCoder.decode(
          ["address", "string[]", "bytes", "bytes4", "bytes"],
          "0x" + err.data.slice(10),
        );

        expect(decoded[0].toLowerCase()).to.equal(
          resolverAddress.toLowerCase(),
        );

        expect(decoded[1]).to.have.lengthOf(1);
        expect(decoded[1][0]).to.equal(GATEWAY_URL);

        const resolveWithProofSelector =
          resolver.interface.getFunction("resolveWithProof").selector;
        expect(decoded[3]).to.equal(resolveWithProofSelector);
      }
    });
  });

  // ================================================================
  //  resolveWithProof() — M-of-N signature verification
  // ================================================================

  describe("resolveWithProof()", function () {
    const ADDR_RESULT = () => abiCoder.encode(["address"], [user.address]);
    const EXTRA_DATA = () => abiCoder.encode(["bytes", "bytes"], ["0x00", "0x00"]);
    async function expiresAt(ttl = RESPONSE_TTL) {
      const latest = await time.latest();
      return BigInt(latest) + BigInt(ttl);
    }
    async function validResponse(signers, ttl = RESPONSE_TTL) {
      const result = ADDR_RESULT();
      const expires = await expiresAt(ttl);
      const extraData = EXTRA_DATA();
      const sigs = await signThreshold(
        signers,
        resolverAddress,
        chainId,
        result,
        expires,
        extraData,
      );
      return {
        response: abiCoder.encode(["bytes", "uint64", "bytes"], [result, expires, sigs]),
        extraData,
        result,
      };
    }

    it("should accept a valid M-of-N signature (4-of-5)", async function () {
      const { response, extraData, result } = await validResponse(
        committee.slice(0, REQUIRED_SIGNATURES),
      );
      const decoded = await resolver.resolveWithProof(response, extraData);
      expect(decoded).to.equal(result);
    });

    it("should accept all five signatures", async function () {
      const { response, extraData, result } = await validResponse(committee);
      const decoded = await resolver.resolveWithProof(response, extraData);
      expect(decoded).to.equal(result);
    });

    it("should accept a single signature when threshold is 1", async function () {
      const Factory = await ethers.getContractFactory("OmniBazaarResolver");
      const r = await Factory.deploy(
        [GATEWAY_URL],
        sortedCommittee.map((s) => s.address),
        1,
        RESPONSE_TTL,
      );
      await r.waitForDeployment();
      const rAddress = await r.getAddress();
      const result = ADDR_RESULT();
      const expires = await expiresAt();
      const extraData = EXTRA_DATA();
      const sigs = await signThreshold(
        [committee[0]],
        rAddress,
        chainId,
        result,
        expires,
        extraData,
      );
      const response = abiCoder.encode(
        ["bytes", "uint64", "bytes"],
        [result, expires, sigs],
      );
      expect(await r.resolveWithProof(response, extraData)).to.equal(result);
    });

    it("should reject a signature bound to a different chainid", async function () {
      const result = ADDR_RESULT();
      const expires = await expiresAt();
      const extraData = EXTRA_DATA();
      // Sign with a foreign chain id (chainId + 1). The digest binds
      // block.chainid, so recovery yields a different address and the
      // response must be rejected.
      const sigs = await signThreshold(
        committee.slice(0, 4),
        resolverAddress,
        chainId + 1,
        result,
        expires,
        extraData,
      );
      const response = abiCoder.encode(
        ["bytes", "uint64", "bytes"],
        [result, expires, sigs],
      );
      await expect(
        resolver.resolveWithProof(response, extraData),
      ).to.be.revertedWithCustomError(resolver, "InvalidSignature");
    });

    it("should reject a signature bound to a different resolver address", async function () {
      const result = ADDR_RESULT();
      const expires = await expiresAt();
      const extraData = EXTRA_DATA();
      // Sign the digest against a foreign resolver address (deadbeef). The
      // digest binds address(this), so recovery yields a different address
      // and the response must be rejected.
      const foreignResolver = "0x000000000000000000000000000000000000dEaD";
      const sigs = await signThreshold(
        committee.slice(0, 4),
        foreignResolver,
        chainId,
        result,
        expires,
        extraData,
      );
      const response = abiCoder.encode(
        ["bytes", "uint64", "bytes"],
        [result, expires, sigs],
      );
      await expect(
        resolver.resolveWithProof(response, extraData),
      ).to.be.revertedWithCustomError(resolver, "InvalidSignature");
    });

    it("should reject below-threshold signatures (3-of-5)", async function () {
      const { response, extraData } = await validResponse(
        committee.slice(0, REQUIRED_SIGNATURES - 1),
      );
      await expect(
        resolver.resolveWithProof(response, extraData),
      ).to.be.revertedWithCustomError(resolver, "InvalidSignature");
    });

    it("should reject signatures from a wrong (non-signer) account", async function () {
      const result = ADDR_RESULT();
      const expires = await expiresAt();
      const extraData = EXTRA_DATA();
      // Use the `other` (non-signer) account plus three legit signers.
      const sigs = await signThreshold(
        [user, ...committee.slice(0, REQUIRED_SIGNATURES - 1)],
        resolverAddress,
        chainId,
        result,
        expires,
        extraData,
      );
      const response = abiCoder.encode(
        ["bytes", "uint64", "bytes"],
        [result, expires, sigs],
      );
      await expect(
        resolver.resolveWithProof(response, extraData),
      ).to.be.revertedWithCustomError(resolver, "InvalidSignature");
    });

    it("should reject a duplicate signature (same signer twice)", async function () {
      const result = ADDR_RESULT();
      const expires = await expiresAt();
      const extraData = EXTRA_DATA();
      const sortedSigners = sortSignersByAddress(committee.slice(0, 4));
      // Sign the same first signer four times (duplicate recovered address).
      let blob = "0x";
      for (let i = 0; i < REQUIRED_SIGNATURES; i++) {
        const sig = await signResponse(
          sortedSigners[0],
          resolverAddress,
          chainId,
          result,
          expires,
          extraData,
        );
        blob += sig.slice(2);
      }
      const response = abiCoder.encode(
        ["bytes", "uint64", "bytes"],
        [result, expires, blob],
      );
      await expect(
        resolver.resolveWithProof(response, extraData),
      ).to.be.revertedWithCustomError(resolver, "InvalidSignature");
    });

    it("should reject unsorted signatures", async function () {
      const result = ADDR_RESULT();
      const expires = await expiresAt();
      const extraData = EXTRA_DATA();
      // Reverse the signer order so recovered addresses are descending.
      const reversed = sortSignersByAddress(committee.slice(0, 4)).reverse();
      let blob = "0x";
      for (const s of reversed) {
        const sig = await signResponse(
          s,
          resolverAddress,
          chainId,
          result,
          expires,
          extraData,
        );
        blob += sig.slice(2);
      }
      const response = abiCoder.encode(
        ["bytes", "uint64", "bytes"],
        [result, expires, blob],
      );
      await expect(
        resolver.resolveWithProof(response, extraData),
      ).to.be.revertedWithCustomError(resolver, "InvalidSignature");
    });

    it("should reject a malformed signature blob (not a multiple of 65)", async function () {
      const result = ADDR_RESULT();
      const expires = await expiresAt();
      const extraData = EXTRA_DATA();
      const good = await signThreshold(
        committee.slice(0, 4),
        resolverAddress,
        chainId,
        result,
        expires,
        extraData,
      );
      const malformed = good + "00"; // 1 trailing byte
      const response = abiCoder.encode(
        ["bytes", "uint64", "bytes"],
        [result, expires, malformed],
      );
      await expect(
        resolver.resolveWithProof(response, extraData),
      ).to.be.revertedWithCustomError(resolver, "InvalidSignature");
    });

    it("should reject an empty signature blob", async function () {
      const result = ADDR_RESULT();
      const expires = await expiresAt();
      const extraData = EXTRA_DATA();
      const response = abiCoder.encode(
        ["bytes", "uint64", "bytes"],
        [result, expires, "0x"],
      );
      await expect(
        resolver.resolveWithProof(response, extraData),
      ).to.be.revertedWithCustomError(resolver, "InvalidSignature");
    });

    it("should reject expired response", async function () {
      const result = ADDR_RESULT();
      const latest = await time.latest();
      const expires = BigInt(latest) - BigInt(100);
      const extraData = EXTRA_DATA();
      const sigs = await signThreshold(
        committee.slice(0, 4),
        resolverAddress,
        chainId,
        result,
        expires,
        extraData,
      );
      const response = abiCoder.encode(
        ["bytes", "uint64", "bytes"],
        [result, expires, sigs],
      );
      await expect(
        resolver.resolveWithProof(response, extraData),
      ).to.be.revertedWithCustomError(resolver, "ResponseExpired");
    });

    it("should reject a response whose expiry exceeds the TTL ceiling", async function () {
      const result = ADDR_RESULT();
      const latest = await time.latest();
      const expires = BigInt(latest) + BigInt(RESPONSE_TTL) + BigInt(100);
      const extraData = EXTRA_DATA();
      const sigs = await signThreshold(
        committee.slice(0, 4),
        resolverAddress,
        chainId,
        result,
        expires,
        extraData,
      );
      const response = abiCoder.encode(
        ["bytes", "uint64", "bytes"],
        [result, expires, sigs],
      );
      await expect(
        resolver.resolveWithProof(response, extraData),
      ).to.be.revertedWithCustomError(resolver, "ResponseExpired");
    });

    it("should reject tampered result", async function () {
      const result = ADDR_RESULT();
      const expires = await expiresAt();
      const extraData = EXTRA_DATA();
      const sigs = await signThreshold(
        committee.slice(0, 4),
        resolverAddress,
        chainId,
        result,
        expires,
        extraData,
      );
      const tamperedResult = abiCoder.encode(["address"], [owner.address]);
      const response = abiCoder.encode(
        ["bytes", "uint64", "bytes"],
        [tamperedResult, expires, sigs],
      );
      await expect(
        resolver.resolveWithProof(response, extraData),
      ).to.be.revertedWithCustomError(resolver, "InvalidSignature");
    });

    it("should reject tampered extraData", async function () {
      const result = ADDR_RESULT();
      const expires = await expiresAt();
      const extraData = EXTRA_DATA();
      const sigs = await signThreshold(
        committee.slice(0, 4),
        resolverAddress,
        chainId,
        result,
        expires,
        extraData,
      );
      const tamperedExtraData = abiCoder.encode(
        ["bytes", "bytes"],
        ["0x01", "0x01"],
      );
      const response = abiCoder.encode(
        ["bytes", "uint64", "bytes"],
        [result, expires, sigs],
      );
      await expect(
        resolver.resolveWithProof(response, tamperedExtraData),
      ).to.be.revertedWithCustomError(resolver, "InvalidSignature");
    });
  });

  // ================================================================
  //  supportsInterface()
  // ================================================================

  describe("supportsInterface()", function () {
    it("should support ENSIP-10 (0x9061b923)", async function () {
      expect(await resolver.supportsInterface("0x9061b923")).to.be.true;
    });

    it("should support ERC-165 (0x01ffc9a7)", async function () {
      expect(await resolver.supportsInterface("0x01ffc9a7")).to.be.true;
    });

    it("should not support random interface", async function () {
      expect(await resolver.supportsInterface("0xdeadbeef")).to.be.false;
    });

    it("should not support ERC-721 (0x80ac58cd)", async function () {
      expect(await resolver.supportsInterface("0x80ac58cd")).to.be.false;
    });
  });

  // ================================================================
  //  Admin Functions
  // ================================================================

  describe("Admin Functions", function () {
    describe("setGatewayURLs()", function () {
      it("should update gateway URLs as owner", async function () {
        const newURLs = [
          "https://gw1.omnibazaar.com/{sender}/{data}.json",
          "https://gw2.omnibazaar.com/{sender}/{data}.json",
        ];
        await expect(resolver.setGatewayURLs(newURLs))
          .to.emit(resolver, "GatewayURLsUpdated")
          .withArgs(newURLs);

        const urls = await resolver.getGatewayURLs();
        expect(urls).to.have.lengthOf(2);
        expect(urls[0]).to.equal(newURLs[0]);
        expect(urls[1]).to.equal(newURLs[1]);
      });

      it("should revert if empty array", async function () {
        await expect(
          resolver.setGatewayURLs([]),
        ).to.be.revertedWithCustomError(resolver, "NoGatewayURLs");
      });

      it("should revert if not owner", async function () {
        await expect(
          resolver.connect(user).setGatewayURLs([GATEWAY_URL]),
        ).to.be.revertedWithCustomError(
          resolver,
          "OwnableUnauthorizedAccount",
        );
      });
    });

    describe("setSigners()", function () {
      it("should update the signer set + threshold as owner", async function () {
        const newSet = sortSignersByAddress([owner, user, committee[0]]);
        const newAddresses = newSet.map((s) => s.address);
        await expect(resolver.setSigners(newAddresses, 2))
          .to.emit(resolver, "SignersUpdated")
          .withArgs(newAddresses, 2);

        expect(await resolver.getSigners()).to.deep.equal(newAddresses);
        expect(await resolver.requiredSignatures()).to.equal(2);
        expect(await resolver.isSigner(owner.address)).to.be.true;
        expect(await resolver.isSigner(committee[4].address)).to.be.false;
      });

      it("should revert if empty set", async function () {
        await expect(resolver.setSigners([], 1)).to.be.revertedWithCustomError(
          resolver,
          "ZeroSigner",
        );
      });

      it("should revert if threshold out of range", async function () {
        await expect(
          resolver.setSigners(sortedCommittee.map((s) => s.address), 0),
        ).to.be.revertedWithCustomError(
          resolver,
          "RequiredSignaturesOutOfRange",
        );
      });

      it("should revert if not owner", async function () {
        await expect(
          resolver
            .connect(user)
            .setSigners([owner.address], 1),
        ).to.be.revertedWithCustomError(
          resolver,
          "OwnableUnauthorizedAccount",
        );
      });
    });

    describe("setResponseTTL()", function () {
      it("should update TTL as owner", async function () {
        const newTTL = 600;
        await expect(resolver.setResponseTTL(newTTL))
          .to.emit(resolver, "ResponseTTLUpdated")
          .withArgs(RESPONSE_TTL, newTTL);

        expect(await resolver.responseTTL()).to.equal(newTTL);
      });

      it("should allow setting TTL to zero", async function () {
        await resolver.setResponseTTL(0);
        expect(await resolver.responseTTL()).to.equal(0);
      });

      it("should revert if not owner", async function () {
        await expect(
          resolver.connect(user).setResponseTTL(600),
        ).to.be.revertedWithCustomError(
          resolver,
          "OwnableUnauthorizedAccount",
        );
      });
    });
  });

  // ================================================================
  //  Ownership Transfer (Ownable2Step)
  // ================================================================

  describe("Ownership Transfer", function () {
    it("should allow two-step transfer", async function () {
      await resolver.transferOwnership(user.address);
      expect(await resolver.owner()).to.equal(owner.address);
      expect(await resolver.pendingOwner()).to.equal(user.address);

      await resolver.connect(user).acceptOwnership();
      expect(await resolver.owner()).to.equal(user.address);
    });

    it("should revert if non-pending-owner tries to accept", async function () {
      await resolver.transferOwnership(user.address);
      await expect(
        resolver.connect(committee[0]).acceptOwnership(),
      ).to.be.revertedWithCustomError(
        resolver,
        "OwnableUnauthorizedAccount",
      );
    });
  });
});
