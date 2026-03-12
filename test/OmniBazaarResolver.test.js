/**
 * @file OmniBazaarResolver.test.js
 * @description Tests for OmniBazaarResolver — ENSIP-10 + ERC-3668 wildcard resolver
 *
 * Tests cover:
 *  - Constructor validation (zero signer, empty URLs)
 *  - resolve() always reverts with OffchainLookup
 *  - resolveWithProof() accepts valid ECDSA signatures
 *  - resolveWithProof() rejects wrong signer (InvalidSignature)
 *  - resolveWithProof() rejects expired responses (ResponseExpired)
 *  - Admin functions (setGatewayURLs, setSigner, setResponseTTL) — owner only
 *  - supportsInterface returns correct values
 *  - Ownable2Step ownership transfer
 */

const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

/** ABI coder instance for encoding/decoding */
const abiCoder = ethers.AbiCoder.defaultAbiCoder();

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
 * Sign a CCIP-Read gateway response using EIP-191 personal sign
 * @param {import('ethers').Signer} signerWallet - The ethers signer to use
 * @param {string} result - ABI-encoded result bytes (hex)
 * @param {bigint} expires - Expiration timestamp (uint64)
 * @param {string} extraData - Extra data bytes (hex) from resolve()
 * @returns {Promise<string>} The ECDSA signature bytes (hex)
 */
async function signResponse(signerWallet, result, expires, extraData) {
  // Pack: result || expires || extraData (matches contract's abi.encodePacked)
  const packed = ethers.solidityPacked(
    ["bytes", "uint64", "bytes"],
    [result, expires, extraData]
  );
  const innerHash = ethers.keccak256(packed);

  // ethers.signMessage(bytes) computes:
  //   sign(keccak256("\x19Ethereum Signed Message:\n32" + bytes))
  // The contract computes:
  //   ECDSA.recover(keccak256("\x19Ethereum Signed Message:\n32" + innerHash), sig)
  // These match when we pass the raw 32-byte innerHash as the message.
  const signature = await signerWallet.signMessage(ethers.getBytes(innerHash));
  return signature;
}

describe("OmniBazaarResolver", function () {
  this.timeout(60000);

  const GATEWAY_URL =
    "https://ens-gateway.omnibazaar.com/ccip/{sender}/{data}.json";
  const RESPONSE_TTL = 300; // 5 minutes

  let owner, signerAccount, user, other;
  let resolver;

  beforeEach(async function () {
    [owner, signerAccount, user, other] = await ethers.getSigners();

    const OmniBazaarResolver =
      await ethers.getContractFactory("OmniBazaarResolver");
    resolver = await OmniBazaarResolver.deploy(
      [GATEWAY_URL],
      signerAccount.address,
      RESPONSE_TTL
    );
    await resolver.waitForDeployment();
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

    it("should set signer correctly", async function () {
      expect(await resolver.signer()).to.equal(signerAccount.address);
    });

    it("should set responseTTL correctly", async function () {
      expect(await resolver.responseTTL()).to.equal(RESPONSE_TTL);
    });

    it("should set owner to deployer", async function () {
      expect(await resolver.owner()).to.equal(owner.address);
    });

    it("should revert if gateway URLs are empty", async function () {
      const Factory =
        await ethers.getContractFactory("OmniBazaarResolver");
      await expect(
        Factory.deploy([], signerAccount.address, RESPONSE_TTL)
      ).to.be.revertedWithCustomError(resolver, "NoGatewayURLs");
    });

    it("should revert if signer is zero address", async function () {
      const Factory =
        await ethers.getContractFactory("OmniBazaarResolver");
      await expect(
        Factory.deploy([GATEWAY_URL], ethers.ZeroAddress, RESPONSE_TTL)
      ).to.be.revertedWithCustomError(resolver, "ZeroSigner");
    });

    it("should accept zero TTL", async function () {
      const Factory =
        await ethers.getContractFactory("OmniBazaarResolver");
      const r = await Factory.deploy([GATEWAY_URL], signerAccount.address, 0);
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
        // Decode the OffchainLookup revert data
        expect(err.data).to.not.be.undefined;

        // The error selector for OffchainLookup
        const offchainLookupSelector = "0x556f1830";
        expect(err.data.slice(0, 10)).to.equal(offchainLookupSelector);

        // Decode the OffchainLookup parameters
        const decoded = abiCoder.decode(
          ["address", "string[]", "bytes", "bytes4", "bytes"],
          "0x" + err.data.slice(10)
        );

        // sender should be the resolver address
        expect(decoded[0].toLowerCase()).to.equal(
          resolverAddress.toLowerCase()
        );

        // urls should match gateway URLs
        expect(decoded[1]).to.have.lengthOf(1);
        expect(decoded[1][0]).to.equal(GATEWAY_URL);

        // callbackFunction should be resolveWithProof selector
        const resolveWithProofSelector =
          resolver.interface.getFunction("resolveWithProof").selector;
        expect(decoded[3]).to.equal(resolveWithProofSelector);
      }
    });
  });

  // ================================================================
  //  resolveWithProof() — signature verification
  // ================================================================

  describe("resolveWithProof()", function () {
    it("should accept a valid signature", async function () {
      const resolvedAddress = user.address;
      const result = abiCoder.encode(["address"], [resolvedAddress]);

      const latestTime = await time.latest();
      const expires = BigInt(latestTime) + BigInt(RESPONSE_TTL);

      const dnsName = encodeDNSName("alice.omnibazaar.eth");
      const node = ethers.namehash("alice.omnibazaar.eth");
      const resolverCalldata = "0x3b3b57de" + node.slice(2);
      const extraData = abiCoder.encode(
        ["bytes", "bytes"],
        [dnsName, resolverCalldata]
      );

      const sig = await signResponse(signerAccount, result, expires, extraData);

      const response = abiCoder.encode(
        ["bytes", "uint64", "bytes"],
        [result, expires, sig]
      );

      const decoded = await resolver.resolveWithProof(response, extraData);
      expect(decoded).to.equal(result);
    });

    it("should reject signature from wrong signer", async function () {
      const result = abiCoder.encode(["address"], [user.address]);
      const latestTime = await time.latest();
      const expires = BigInt(latestTime) + BigInt(RESPONSE_TTL);
      const extraData = abiCoder.encode(
        ["bytes", "bytes"],
        ["0x00", "0x00"]
      );

      // Sign with wrong account
      const sig = await signResponse(other, result, expires, extraData);

      const response = abiCoder.encode(
        ["bytes", "uint64", "bytes"],
        [result, expires, sig]
      );

      await expect(
        resolver.resolveWithProof(response, extraData)
      ).to.be.revertedWithCustomError(resolver, "InvalidSignature");
    });

    it("should reject expired response", async function () {
      const result = abiCoder.encode(["address"], [user.address]);
      const latestTime = await time.latest();
      const expires = BigInt(latestTime) - BigInt(100);
      const extraData = abiCoder.encode(
        ["bytes", "bytes"],
        ["0x00", "0x00"]
      );

      const sig = await signResponse(signerAccount, result, expires, extraData);

      const response = abiCoder.encode(
        ["bytes", "uint64", "bytes"],
        [result, expires, sig]
      );

      await expect(
        resolver.resolveWithProof(response, extraData)
      ).to.be.revertedWithCustomError(resolver, "ResponseExpired");
    });

    it("should reject tampered result", async function () {
      const result = abiCoder.encode(["address"], [user.address]);
      const latestTime = await time.latest();
      const expires = BigInt(latestTime) + BigInt(RESPONSE_TTL);
      const extraData = abiCoder.encode(
        ["bytes", "bytes"],
        ["0x00", "0x00"]
      );

      const sig = await signResponse(signerAccount, result, expires, extraData);

      // Tamper
      const tamperedResult = abiCoder.encode(["address"], [other.address]);

      const response = abiCoder.encode(
        ["bytes", "uint64", "bytes"],
        [tamperedResult, expires, sig]
      );

      await expect(
        resolver.resolveWithProof(response, extraData)
      ).to.be.revertedWithCustomError(resolver, "InvalidSignature");
    });

    it("should reject tampered extraData", async function () {
      const result = abiCoder.encode(["address"], [user.address]);
      const latestTime = await time.latest();
      const expires = BigInt(latestTime) + BigInt(RESPONSE_TTL);
      const extraData = abiCoder.encode(
        ["bytes", "bytes"],
        ["0x00", "0x00"]
      );

      const sig = await signResponse(signerAccount, result, expires, extraData);

      const tamperedExtraData = abiCoder.encode(
        ["bytes", "bytes"],
        ["0x01", "0x01"]
      );

      const response = abiCoder.encode(
        ["bytes", "uint64", "bytes"],
        [result, expires, sig]
      );

      await expect(
        resolver.resolveWithProof(response, tamperedExtraData)
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
          resolver.setGatewayURLs([])
        ).to.be.revertedWithCustomError(resolver, "NoGatewayURLs");
      });

      it("should revert if not owner", async function () {
        await expect(
          resolver.connect(user).setGatewayURLs([GATEWAY_URL])
        ).to.be.revertedWithCustomError(
          resolver,
          "OwnableUnauthorizedAccount"
        );
      });
    });

    describe("setSigner()", function () {
      it("should update signer as owner", async function () {
        await expect(resolver.setSigner(other.address))
          .to.emit(resolver, "SignerUpdated")
          .withArgs(signerAccount.address, other.address);

        expect(await resolver.signer()).to.equal(other.address);
      });

      it("should revert if zero address", async function () {
        await expect(
          resolver.setSigner(ethers.ZeroAddress)
        ).to.be.revertedWithCustomError(resolver, "ZeroSigner");
      });

      it("should revert if not owner", async function () {
        await expect(
          resolver.connect(user).setSigner(other.address)
        ).to.be.revertedWithCustomError(
          resolver,
          "OwnableUnauthorizedAccount"
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
          resolver.connect(user).setResponseTTL(600)
        ).to.be.revertedWithCustomError(
          resolver,
          "OwnableUnauthorizedAccount"
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
        resolver.connect(other).acceptOwnership()
      ).to.be.revertedWithCustomError(
        resolver,
        "OwnableUnauthorizedAccount"
      );
    });
  });
});
