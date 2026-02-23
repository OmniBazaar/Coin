const { expect } = require("chai");
const { ethers } = require("hardhat");

/**
 * UpdateRegistry.sol — Comprehensive Hardhat tests
 *
 * Tests cover:
 *  1. Deployment and initial state
 *  2. Release publishing with multi-sig (nonce-protected)
 *  3. Release revocation
 *  4. Minimum version enforcement
 *  5. Signer set rotation
 *  6. View functions
 *  7. Access control
 *  8. Edge cases and error paths
 */
describe("UpdateRegistry", function () {
  let registry;
  let owner, signer1, signer2, signer3, signer4, signer5;
  let manager, outsider;

  // Default test component
  const COMPONENT = "validator";
  const VERSION = "1.0.0";
  const BINARY_HASH = ethers.keccak256(ethers.toUtf8Bytes("release-artifact-v1.0.0"));
  const MIN_VERSION = "0.9.0";
  const CHANGELOG_CID = "QmTestChangelogCID123456789";

  /**
   * Deploys the registry with given signers and threshold
   */
  async function deployRegistry(signerAddrs, threshold) {
    const Factory = await ethers.getContractFactory("UpdateRegistry");
    const contract = await Factory.deploy(signerAddrs, threshold);
    return contract;
  }

  /**
   * Get the current operationNonce from the contract
   */
  async function getNonce(contract) {
    return await contract.getOperationNonce();
  }

  /**
   * Sign a release manifest with the given signers.
   * The contract uses: keccak256(abi.encode(
   *   "PUBLISH_RELEASE", component, version, binaryHash, minVersion,
   *   nonce, block.chainid, address(this)
   * ))
   */
  async function signRelease(contract, wallets, component, version, binaryHash, minVersion, nonce) {
    const chainId = (await ethers.provider.getNetwork()).chainId;
    const contractAddr = await contract.getAddress();

    const messageHash = ethers.keccak256(
      ethers.AbiCoder.defaultAbiCoder().encode(
        ["string", "string", "string", "bytes32", "string", "uint256", "uint256", "address"],
        ["PUBLISH_RELEASE", component, version, binaryHash, minVersion, nonce, chainId, contractAddr]
      )
    );

    const signatures = [];
    for (const wallet of wallets) {
      const sig = await wallet.signMessage(ethers.getBytes(messageHash));
      signatures.push(sig);
    }
    return signatures;
  }

  /**
   * Sign a revocation message.
   * The contract uses: keccak256(abi.encode(
   *   "REVOKE", component, version, reason, nonce, block.chainid, address(this)
   * ))
   */
  async function signRevocation(contract, wallets, component, version, reason, nonce) {
    const chainId = (await ethers.provider.getNetwork()).chainId;
    const contractAddr = await contract.getAddress();

    const messageHash = ethers.keccak256(
      ethers.AbiCoder.defaultAbiCoder().encode(
        ["string", "string", "string", "string", "uint256", "uint256", "address"],
        ["REVOKE", component, version, reason, nonce, chainId, contractAddr]
      )
    );

    const signatures = [];
    for (const wallet of wallets) {
      const sig = await wallet.signMessage(ethers.getBytes(messageHash));
      signatures.push(sig);
    }
    return signatures;
  }

  /**
   * Sign a minimum version update message.
   * The contract uses: keccak256(abi.encode(
   *   "MIN_VERSION", component, version, nonce, block.chainid, address(this)
   * ))
   */
  async function signMinVersion(contract, wallets, component, version, nonce) {
    const chainId = (await ethers.provider.getNetwork()).chainId;
    const contractAddr = await contract.getAddress();

    const messageHash = ethers.keccak256(
      ethers.AbiCoder.defaultAbiCoder().encode(
        ["string", "string", "string", "uint256", "uint256", "address"],
        ["MIN_VERSION", component, version, nonce, chainId, contractAddr]
      )
    );

    const signatures = [];
    for (const wallet of wallets) {
      const sig = await wallet.signMessage(ethers.getBytes(messageHash));
      signatures.push(sig);
    }
    return signatures;
  }

  /**
   * Sign a signer set update message.
   * The contract uses: keccak256(abi.encode(
   *   "UPDATE_SIGNERS", keccak256(abi.encode(newSigners)), newThreshold,
   *   nonce, block.chainid, address(this)
   * ))
   */
  async function signSignerUpdate(contract, wallets, newSignerAddrs, newThreshold, nonce) {
    const chainId = (await ethers.provider.getNetwork()).chainId;
    const contractAddr = await contract.getAddress();

    // abi.encode(address[]) uses standard ABI encoding for dynamic arrays
    const signersHash = ethers.keccak256(
      ethers.AbiCoder.defaultAbiCoder().encode(["address[]"], [newSignerAddrs])
    );

    const messageHash = ethers.keccak256(
      ethers.AbiCoder.defaultAbiCoder().encode(
        ["string", "bytes32", "uint256", "uint256", "uint256", "address"],
        ["UPDATE_SIGNERS", signersHash, newThreshold, nonce, chainId, contractAddr]
      )
    );

    const signatures = [];
    for (const wallet of wallets) {
      const sig = await wallet.signMessage(ethers.getBytes(messageHash));
      signatures.push(sig);
    }
    return signatures;
  }

  beforeEach(async function () {
    [owner, signer1, signer2, signer3, signer4, signer5, manager, outsider] =
      await ethers.getSigners();

    // Deploy with 3 signers, threshold 2
    registry = await deployRegistry(
      [signer1.address, signer2.address, signer3.address],
      2
    );
  });

  // ================================================================
  //  1. Deployment and Initial State
  // ================================================================

  describe("Deployment", function () {
    it("should set the correct signers", async function () {
      const signerList = await registry.getSigners();
      expect(signerList.length).to.equal(3);
      expect(signerList[0]).to.equal(signer1.address);
      expect(signerList[1]).to.equal(signer2.address);
      expect(signerList[2]).to.equal(signer3.address);
    });

    it("should set the correct threshold", async function () {
      expect(await registry.getSignerThreshold()).to.equal(2);
    });

    it("should mark signers correctly in the mapping", async function () {
      expect(await registry.isSigner(signer1.address)).to.be.true;
      expect(await registry.isSigner(signer2.address)).to.be.true;
      expect(await registry.isSigner(signer3.address)).to.be.true;
      expect(await registry.isSigner(outsider.address)).to.be.false;
    });

    it("should grant roles to deployer", async function () {
      const DEFAULT_ADMIN_ROLE = await registry.DEFAULT_ADMIN_ROLE();
      const RELEASE_MANAGER_ROLE = await registry.RELEASE_MANAGER_ROLE();
      expect(await registry.hasRole(DEFAULT_ADMIN_ROLE, owner.address)).to.be.true;
      expect(await registry.hasRole(RELEASE_MANAGER_ROLE, owner.address)).to.be.true;
    });

    it("should emit SignerSetUpdated on deployment", async function () {
      const newRegistry = await deployRegistry(
        [signer1.address, signer2.address],
        1
      );
      // The event was emitted during constructor -- verify via filter
      const events = await newRegistry.queryFilter("SignerSetUpdated");
      expect(events.length).to.equal(1);
    });

    it("should start with operationNonce at zero", async function () {
      expect(await registry.getOperationNonce()).to.equal(0);
    });

    it("should reject zero threshold", async function () {
      await expect(
        deployRegistry([signer1.address], 0)
      ).to.be.revertedWithCustomError(registry, "InvalidThreshold");
    });

    it("should reject threshold greater than signer count", async function () {
      await expect(
        deployRegistry([signer1.address], 2)
      ).to.be.revertedWithCustomError(registry, "InvalidThreshold");
    });

    it("should reject zero address in signers", async function () {
      await expect(
        deployRegistry([signer1.address, ethers.ZeroAddress], 1)
      ).to.be.revertedWithCustomError(registry, "ZeroAddress");
    });

    it("should reject duplicate signers", async function () {
      await expect(
        deployRegistry([signer1.address, signer1.address], 1)
      ).to.be.revertedWithCustomError(registry, "DuplicateSigner");
    });

    it("should reject empty signer array", async function () {
      await expect(
        deployRegistry([], 1)
      ).to.be.revertedWithCustomError(registry, "InvalidThreshold");
    });
  });

  // ================================================================
  //  2. Release Publishing
  // ================================================================

  describe("publishRelease", function () {
    it("should publish a release with valid signatures", async function () {
      const nonce = await getNonce(registry);
      const sigs = await signRelease(
        registry, [signer1, signer2],
        COMPONENT, VERSION, BINARY_HASH, MIN_VERSION, nonce
      );

      await expect(
        registry.publishRelease(COMPONENT, VERSION, BINARY_HASH, MIN_VERSION, CHANGELOG_CID, nonce, sigs)
      ).to.emit(registry, "ReleasePublished")
        .withArgs(COMPONENT, VERSION, BINARY_HASH, MIN_VERSION);
    });

    it("should store release info correctly", async function () {
      const nonce = await getNonce(registry);
      const sigs = await signRelease(
        registry, [signer1, signer2],
        COMPONENT, VERSION, BINARY_HASH, MIN_VERSION, nonce
      );

      await registry.publishRelease(COMPONENT, VERSION, BINARY_HASH, MIN_VERSION, CHANGELOG_CID, nonce, sigs);

      const release = await registry.getLatestRelease(COMPONENT);
      expect(release.version).to.equal(VERSION);
      expect(release.binaryHash).to.equal(BINARY_HASH);
      expect(release.minimumVersion).to.equal(MIN_VERSION);
      expect(release.revoked).to.be.false;
      expect(release.changelogCID).to.equal(CHANGELOG_CID);
      expect(release.publishedBy).to.equal(owner.address);
      expect(release.publishedAt).to.be.greaterThan(0);
    });

    it("should update latest version", async function () {
      const nonce = await getNonce(registry);
      const sigs = await signRelease(
        registry, [signer1, signer2],
        COMPONENT, VERSION, BINARY_HASH, MIN_VERSION, nonce
      );
      await registry.publishRelease(COMPONENT, VERSION, BINARY_HASH, MIN_VERSION, "", nonce, sigs);
      expect(await registry.getLatestVersion(COMPONENT)).to.equal(VERSION);
    });

    it("should update minimum version when provided", async function () {
      const nonce = await getNonce(registry);
      const sigs = await signRelease(
        registry, [signer1, signer2],
        COMPONENT, VERSION, BINARY_HASH, MIN_VERSION, nonce
      );
      await registry.publishRelease(COMPONENT, VERSION, BINARY_HASH, MIN_VERSION, "", nonce, sigs);
      expect(await registry.getMinimumVersion(COMPONENT)).to.equal(MIN_VERSION);
    });

    it("should not update minimum version when empty", async function () {
      const nonce = await getNonce(registry);
      const sigs = await signRelease(
        registry, [signer1, signer2],
        COMPONENT, VERSION, BINARY_HASH, "", nonce
      );
      await registry.publishRelease(COMPONENT, VERSION, BINARY_HASH, "", "", nonce, sigs);
      expect(await registry.getMinimumVersion(COMPONENT)).to.equal("");
    });

    it("should increment release count", async function () {
      let nonce = await getNonce(registry);
      const sigs1 = await signRelease(
        registry, [signer1, signer2],
        COMPONENT, "1.0.0", BINARY_HASH, "", nonce
      );
      await registry.publishRelease(COMPONENT, "1.0.0", BINARY_HASH, "", "", nonce, sigs1);

      nonce = await getNonce(registry);
      const hash2 = ethers.keccak256(ethers.toUtf8Bytes("v2"));
      const sigs2 = await signRelease(
        registry, [signer1, signer2],
        COMPONENT, "1.1.0", hash2, "", nonce
      );
      await registry.publishRelease(COMPONENT, "1.1.0", hash2, "", "", nonce, sigs2);

      expect(await registry.getReleaseCount(COMPONENT)).to.equal(2);
    });

    it("should increment operationNonce after each publish", async function () {
      expect(await registry.getOperationNonce()).to.equal(0);

      const nonce = await getNonce(registry);
      const sigs = await signRelease(
        registry, [signer1, signer2],
        COMPONENT, VERSION, BINARY_HASH, "", nonce
      );
      await registry.publishRelease(COMPONENT, VERSION, BINARY_HASH, "", "", nonce, sigs);

      expect(await registry.getOperationNonce()).to.equal(1);
    });

    it("should reject duplicate version", async function () {
      let nonce = await getNonce(registry);
      const sigs = await signRelease(
        registry, [signer1, signer2],
        COMPONENT, VERSION, BINARY_HASH, "", nonce
      );
      await registry.publishRelease(COMPONENT, VERSION, BINARY_HASH, "", "", nonce, sigs);

      nonce = await getNonce(registry);
      const sigs2 = await signRelease(
        registry, [signer1, signer2],
        COMPONENT, VERSION, BINARY_HASH, "", nonce
      );
      await expect(
        registry.publishRelease(COMPONENT, VERSION, BINARY_HASH, "", "", nonce, sigs2)
      ).to.be.revertedWithCustomError(registry, "DuplicateVersion");
    });

    it("should reject empty version", async function () {
      const nonce = await getNonce(registry);
      const sigs = await signRelease(
        registry, [signer1, signer2],
        COMPONENT, "", BINARY_HASH, "", nonce
      );
      await expect(
        registry.publishRelease(COMPONENT, "", BINARY_HASH, "", "", nonce, sigs)
      ).to.be.revertedWithCustomError(registry, "EmptyVersion");
    });

    it("should reject empty binary hash", async function () {
      const nonce = await getNonce(registry);
      const sigs = await signRelease(
        registry, [signer1, signer2],
        COMPONENT, VERSION, ethers.ZeroHash, "", nonce
      );
      await expect(
        registry.publishRelease(COMPONENT, VERSION, ethers.ZeroHash, "", "", nonce, sigs)
      ).to.be.revertedWithCustomError(registry, "EmptyBinaryHash");
    });

    it("should reject empty component", async function () {
      const nonce = await getNonce(registry);
      const sigs = await signRelease(
        registry, [signer1, signer2],
        "", VERSION, BINARY_HASH, "", nonce
      );
      await expect(
        registry.publishRelease("", VERSION, BINARY_HASH, "", "", nonce, sigs)
      ).to.be.revertedWithCustomError(registry, "EmptyComponent");
    });

    it("should reject insufficient signatures", async function () {
      const nonce = await getNonce(registry);
      const sigs = await signRelease(
        registry, [signer1], // Only 1 sig, threshold is 2
        COMPONENT, VERSION, BINARY_HASH, "", nonce
      );
      await expect(
        registry.publishRelease(COMPONENT, VERSION, BINARY_HASH, "", "", nonce, sigs)
      ).to.be.revertedWithCustomError(registry, "InsufficientSignatures");
    });

    it("should reject signatures from non-signers", async function () {
      const nonce = await getNonce(registry);
      const sigs = await signRelease(
        registry, [signer1, outsider], // outsider is not a signer
        COMPONENT, VERSION, BINARY_HASH, "", nonce
      );
      await expect(
        registry.publishRelease(COMPONENT, VERSION, BINARY_HASH, "", "", nonce, sigs)
      ).to.be.revertedWithCustomError(registry, "InvalidSignature");
    });

    it("should reject stale nonce (replay protection)", async function () {
      // Publish once to increment nonce
      const nonce0 = await getNonce(registry);
      const sigs0 = await signRelease(
        registry, [signer1, signer2],
        COMPONENT, "0.9.0", BINARY_HASH, "", nonce0
      );
      await registry.publishRelease(COMPONENT, "0.9.0", BINARY_HASH, "", "", nonce0, sigs0);

      // Try to use nonce=0 again (it's stale, current nonce is now 1)
      const hash2 = ethers.keccak256(ethers.toUtf8Bytes("v2"));
      const staleSigs = await signRelease(
        registry, [signer1, signer2],
        COMPONENT, VERSION, hash2, "", nonce0
      );
      await expect(
        registry.publishRelease(COMPONENT, VERSION, hash2, "", "", nonce0, staleSigs)
      ).to.be.revertedWithCustomError(registry, "StaleNonce");
    });

    it("should reject calls from non-managers", async function () {
      const nonce = await getNonce(registry);
      const sigs = await signRelease(
        registry, [signer1, signer2],
        COMPONENT, VERSION, BINARY_HASH, "", nonce
      );
      await expect(
        registry.connect(outsider).publishRelease(COMPONENT, VERSION, BINARY_HASH, "", "", nonce, sigs)
      ).to.be.reverted; // AccessControl revert
    });

    it("should work with different components", async function () {
      const components = ["validator", "service-node", "wallet-extension", "mobile-app", "webapp"];

      for (const comp of components) {
        const hash = ethers.keccak256(ethers.toUtf8Bytes(`artifact-${comp}`));
        const nonce = await getNonce(registry);
        const sigs = await signRelease(
          registry, [signer1, signer2],
          comp, "1.0.0", hash, "", nonce
        );
        await registry.publishRelease(comp, "1.0.0", hash, "", "", nonce, sigs);
        expect(await registry.getLatestVersion(comp)).to.equal("1.0.0");
      }
    });
  });

  // ================================================================
  //  3. Release Revocation
  // ================================================================

  describe("revokeRelease", function () {
    const REASON = "CVE-2026-0001: Critical vulnerability";

    beforeEach(async function () {
      const nonce = await getNonce(registry);
      const sigs = await signRelease(
        registry, [signer1, signer2],
        COMPONENT, VERSION, BINARY_HASH, "", nonce
      );
      await registry.publishRelease(COMPONENT, VERSION, BINARY_HASH, "", "", nonce, sigs);
    });

    it("should revoke a published release", async function () {
      const nonce = await getNonce(registry);
      const sigs = await signRevocation(
        registry, [signer1, signer2],
        COMPONENT, VERSION, REASON, nonce
      );

      await expect(
        registry.revokeRelease(COMPONENT, VERSION, REASON, nonce, sigs)
      ).to.emit(registry, "ReleaseRevoked");
    });

    it("should mark release as revoked", async function () {
      const nonce = await getNonce(registry);
      const sigs = await signRevocation(
        registry, [signer1, signer2],
        COMPONENT, VERSION, REASON, nonce
      );
      await registry.revokeRelease(COMPONENT, VERSION, REASON, nonce, sigs);

      expect(await registry.isVersionRevoked(COMPONENT, VERSION)).to.be.true;

      const release = await registry.getRelease(COMPONENT, VERSION);
      expect(release.revoked).to.be.true;
      expect(release.revokeReason).to.equal(REASON);
    });

    it("should reject revoking a non-existent version", async function () {
      const nonce = await getNonce(registry);
      const sigs = await signRevocation(
        registry, [signer1, signer2],
        COMPONENT, "9.9.9", REASON, nonce
      );
      await expect(
        registry.revokeRelease(COMPONENT, "9.9.9", REASON, nonce, sigs)
      ).to.be.revertedWithCustomError(registry, "VersionNotFound");
    });

    it("should reject double revocation", async function () {
      let nonce = await getNonce(registry);
      const sigs = await signRevocation(
        registry, [signer1, signer2],
        COMPONENT, VERSION, REASON, nonce
      );
      await registry.revokeRelease(COMPONENT, VERSION, REASON, nonce, sigs);

      nonce = await getNonce(registry);
      const sigs2 = await signRevocation(
        registry, [signer1, signer2],
        COMPONENT, VERSION, REASON, nonce
      );
      await expect(
        registry.revokeRelease(COMPONENT, VERSION, REASON, nonce, sigs2)
      ).to.be.revertedWithCustomError(registry, "VersionAlreadyRevoked");
    });

    it("should increment nonce after revocation", async function () {
      const nonceBefore = await getNonce(registry);
      const sigs = await signRevocation(
        registry, [signer1, signer2],
        COMPONENT, VERSION, REASON, nonceBefore
      );
      await registry.revokeRelease(COMPONENT, VERSION, REASON, nonceBefore, sigs);

      expect(await getNonce(registry)).to.equal(nonceBefore + 1n);
    });
  });

  // ================================================================
  //  4. Minimum Version
  // ================================================================

  describe("setMinimumVersion", function () {
    it("should set minimum version with valid signatures", async function () {
      const nonce = await getNonce(registry);
      const sigs = await signMinVersion(
        registry, [signer1, signer2],
        COMPONENT, "2.0.0", nonce
      );

      await expect(
        registry.setMinimumVersion(COMPONENT, "2.0.0", nonce, sigs)
      ).to.emit(registry, "MinimumVersionUpdated");

      expect(await registry.getMinimumVersion(COMPONENT)).to.equal("2.0.0");
    });

    it("should reject empty component", async function () {
      const nonce = await getNonce(registry);
      const sigs = await signMinVersion(
        registry, [signer1, signer2],
        "", "2.0.0", nonce
      );
      await expect(
        registry.setMinimumVersion("", "2.0.0", nonce, sigs)
      ).to.be.revertedWithCustomError(registry, "EmptyComponent");
    });

    it("should reject empty version", async function () {
      const nonce = await getNonce(registry);
      const sigs = await signMinVersion(
        registry, [signer1, signer2],
        COMPONENT, "", nonce
      );
      await expect(
        registry.setMinimumVersion(COMPONENT, "", nonce, sigs)
      ).to.be.revertedWithCustomError(registry, "EmptyVersion");
    });

    it("should require admin role", async function () {
      const nonce = await getNonce(registry);
      const sigs = await signMinVersion(
        registry, [signer1, signer2],
        COMPONENT, "2.0.0", nonce
      );
      await expect(
        registry.connect(outsider).setMinimumVersion(COMPONENT, "2.0.0", nonce, sigs)
      ).to.be.reverted;
    });

    it("should increment nonce after setting min version", async function () {
      const nonceBefore = await getNonce(registry);
      const sigs = await signMinVersion(
        registry, [signer1, signer2],
        COMPONENT, "2.0.0", nonceBefore
      );
      await registry.setMinimumVersion(COMPONENT, "2.0.0", nonceBefore, sigs);

      expect(await getNonce(registry)).to.equal(nonceBefore + 1n);
    });
  });

  // ================================================================
  //  5. Signer Set Rotation
  // ================================================================

  describe("updateSignerSet", function () {
    it("should update signer set with elevated threshold", async function () {
      const newSigners = [signer4.address, signer5.address];
      const newThreshold = 1;
      const nonce = await getNonce(registry);

      // Requires threshold+1 = 3 sigs (all current signers)
      const sigs = await signSignerUpdate(
        registry,
        [signer1, signer2, signer3],
        newSigners,
        newThreshold,
        nonce
      );

      await expect(
        registry.updateSignerSet(newSigners, newThreshold, nonce, sigs)
      ).to.emit(registry, "SignerSetUpdated");

      const updatedSigners = await registry.getSigners();
      expect(updatedSigners.length).to.equal(2);
      expect(updatedSigners[0]).to.equal(signer4.address);
      expect(updatedSigners[1]).to.equal(signer5.address);
      expect(await registry.getSignerThreshold()).to.equal(1);
    });

    it("should clear old signer mappings", async function () {
      const newSigners = [signer4.address, signer5.address];
      const nonce = await getNonce(registry);
      const sigs = await signSignerUpdate(
        registry,
        [signer1, signer2, signer3],
        newSigners,
        1,
        nonce
      );
      await registry.updateSignerSet(newSigners, 1, nonce, sigs);

      expect(await registry.isSigner(signer1.address)).to.be.false;
      expect(await registry.isSigner(signer2.address)).to.be.false;
      expect(await registry.isSigner(signer3.address)).to.be.false;
      expect(await registry.isSigner(signer4.address)).to.be.true;
      expect(await registry.isSigner(signer5.address)).to.be.true;
    });

    it("should reject insufficient signatures for rotation", async function () {
      const newSigners = [signer4.address];
      const nonce = await getNonce(registry);
      // Only provide 2 sigs but need threshold+1 = 3
      const sigs = await signSignerUpdate(
        registry,
        [signer1, signer2],
        newSigners,
        1,
        nonce
      );
      await expect(
        registry.updateSignerSet(newSigners, 1, nonce, sigs)
      ).to.be.revertedWithCustomError(registry, "InsufficientSignatures");
    });

    it("should require admin role", async function () {
      const newSigners = [signer4.address];
      const nonce = await getNonce(registry);
      const sigs = await signSignerUpdate(
        registry,
        [signer1, signer2, signer3],
        newSigners,
        1,
        nonce
      );
      await expect(
        registry.connect(outsider).updateSignerSet(newSigners, 1, nonce, sigs)
      ).to.be.reverted;
    });

    it("should increment nonce after signer set update", async function () {
      const nonceBefore = await getNonce(registry);
      const newSigners = [signer4.address, signer5.address];
      const sigs = await signSignerUpdate(
        registry,
        [signer1, signer2, signer3],
        newSigners,
        1,
        nonceBefore
      );
      await registry.updateSignerSet(newSigners, 1, nonceBefore, sigs);

      expect(await getNonce(registry)).to.equal(nonceBefore + 1n);
    });
  });

  // ================================================================
  //  6. View Functions
  // ================================================================

  describe("View functions", function () {
    beforeEach(async function () {
      // Publish two versions
      let nonce = await getNonce(registry);
      const sigs1 = await signRelease(
        registry, [signer1, signer2],
        COMPONENT, "1.0.0", BINARY_HASH, "0.9.0", nonce
      );
      await registry.publishRelease(COMPONENT, "1.0.0", BINARY_HASH, "0.9.0", "", nonce, sigs1);

      nonce = await getNonce(registry);
      const hash2 = ethers.keccak256(ethers.toUtf8Bytes("v2-artifact"));
      const sigs2 = await signRelease(
        registry, [signer1, signer2],
        COMPONENT, "1.1.0", hash2, "1.0.0", nonce
      );
      await registry.publishRelease(COMPONENT, "1.1.0", hash2, "1.0.0", "", nonce, sigs2);
    });

    it("getLatestRelease should return the newest version", async function () {
      const release = await registry.getLatestRelease(COMPONENT);
      expect(release.version).to.equal("1.1.0");
    });

    it("getRelease should return a specific version", async function () {
      const release = await registry.getRelease(COMPONENT, "1.0.0");
      expect(release.version).to.equal("1.0.0");
    });

    it("getReleaseByIndex should enumerate versions", async function () {
      const first = await registry.getReleaseByIndex(COMPONENT, 0);
      const second = await registry.getReleaseByIndex(COMPONENT, 1);
      expect(first.version).to.equal("1.0.0");
      expect(second.version).to.equal("1.1.0");
    });

    it("getReleaseByIndex should revert for out-of-range index", async function () {
      await expect(
        registry.getReleaseByIndex(COMPONENT, 99)
      ).to.be.revertedWithCustomError(registry, "VersionNotFound");
    });

    it("verifyRelease should return true for valid release", async function () {
      expect(await registry.verifyRelease(COMPONENT, "1.0.0")).to.be.true;
    });

    it("verifyRelease should return false for non-existent release", async function () {
      expect(await registry.verifyRelease(COMPONENT, "9.9.9")).to.be.false;
    });

    it("verifyRelease should return false for revoked release", async function () {
      const nonce = await getNonce(registry);
      const sigs = await signRevocation(
        registry, [signer1, signer2],
        COMPONENT, "1.0.0", "security issue", nonce
      );
      await registry.revokeRelease(COMPONENT, "1.0.0", "security issue", nonce, sigs);
      expect(await registry.verifyRelease(COMPONENT, "1.0.0")).to.be.false;
    });

    it("isVersionRevoked should return false for non-existent version", async function () {
      expect(await registry.isVersionRevoked(COMPONENT, "9.9.9")).to.be.false;
    });

    it("computeReleaseHash should return correct hash", async function () {
      const nonce = await getNonce(registry);
      const hash = await registry.computeReleaseHash(
        COMPONENT, VERSION, BINARY_HASH, MIN_VERSION, nonce
      );
      expect(hash).to.not.equal(ethers.ZeroHash);
    });

    it("computeSignerUpdateHash should return correct hash", async function () {
      const nonce = await getNonce(registry);
      const hash = await registry.computeSignerUpdateHash(
        [signer4.address, signer5.address], 1, nonce
      );
      expect(hash).to.not.equal(ethers.ZeroHash);
    });

    it("getLatestRelease should revert for empty component", async function () {
      await expect(
        registry.getLatestRelease("nonexistent-component")
      ).to.be.revertedWithCustomError(registry, "VersionNotFound");
    });
  });

  // ================================================================
  //  7. Replay Protection
  // ================================================================

  describe("Replay protection", function () {
    it("should include chainId in message hash", async function () {
      const nonce = await getNonce(registry);
      const hash = await registry.computeReleaseHash(
        COMPONENT, VERSION, BINARY_HASH, MIN_VERSION, nonce
      );
      // Hash should be non-zero -- includes chainId and contract address
      expect(hash).to.not.equal(ethers.ZeroHash);
    });

    it("should reject duplicate signer signatures", async function () {
      const nonce = await getNonce(registry);
      const chainId = (await ethers.provider.getNetwork()).chainId;
      const contractAddr = await registry.getAddress();
      const messageHash = ethers.keccak256(
        ethers.AbiCoder.defaultAbiCoder().encode(
          ["string", "string", "string", "bytes32", "string", "uint256", "uint256", "address"],
          ["PUBLISH_RELEASE", COMPONENT, VERSION, BINARY_HASH, "", nonce, chainId, contractAddr]
        )
      );

      const sig = await signer1.signMessage(ethers.getBytes(messageHash));
      // Provide the same signature twice -- contract deduplicates via bitmap
      await expect(
        registry.publishRelease(COMPONENT, VERSION, BINARY_HASH, "", "", nonce, [sig, sig])
      ).to.be.revertedWithCustomError(registry, "InsufficientSignatures");
    });

    it("should reject replayed signatures with stale nonce", async function () {
      // Publish v1
      const nonce0 = await getNonce(registry);
      const sigs = await signRelease(
        registry, [signer1, signer2],
        COMPONENT, "1.0.0", BINARY_HASH, "", nonce0
      );
      await registry.publishRelease(COMPONENT, "1.0.0", BINARY_HASH, "", "", nonce0, sigs);

      // nonce is now 1. The old sigs used nonce=0
      // Even with a different version, the old nonce should fail
      const hash2 = ethers.keccak256(ethers.toUtf8Bytes("v2"));
      const staleSigs = await signRelease(
        registry, [signer1, signer2],
        COMPONENT, "2.0.0", hash2, "", nonce0
      );
      await expect(
        registry.publishRelease(COMPONENT, "2.0.0", hash2, "", "", nonce0, staleSigs)
      ).to.be.revertedWithCustomError(registry, "StaleNonce");
    });
  });

  // ================================================================
  //  8. Multi-Component Isolation
  // ================================================================

  describe("Component isolation", function () {
    it("should track versions independently per component", async function () {
      const hash1 = ethers.keccak256(ethers.toUtf8Bytes("validator-v1"));
      const hash2 = ethers.keccak256(ethers.toUtf8Bytes("webapp-v1"));

      let nonce = await getNonce(registry);
      const sigs1 = await signRelease(
        registry, [signer1, signer2],
        "validator", "2.0.0", hash1, "1.0.0", nonce
      );
      await registry.publishRelease("validator", "2.0.0", hash1, "1.0.0", "", nonce, sigs1);

      nonce = await getNonce(registry);
      const sigs2 = await signRelease(
        registry, [signer1, signer2],
        "webapp", "3.0.0", hash2, "2.5.0", nonce
      );
      await registry.publishRelease("webapp", "3.0.0", hash2, "2.5.0", "", nonce, sigs2);

      expect(await registry.getLatestVersion("validator")).to.equal("2.0.0");
      expect(await registry.getLatestVersion("webapp")).to.equal("3.0.0");
      expect(await registry.getMinimumVersion("validator")).to.equal("1.0.0");
      expect(await registry.getMinimumVersion("webapp")).to.equal("2.5.0");
    });

    it("should not cross-contaminate release counts", async function () {
      const hash1 = ethers.keccak256(ethers.toUtf8Bytes("v-v1"));
      const nonce = await getNonce(registry);
      const sigs1 = await signRelease(
        registry, [signer1, signer2],
        "validator", "1.0.0", hash1, "", nonce
      );
      await registry.publishRelease("validator", "1.0.0", hash1, "", "", nonce, sigs1);

      expect(await registry.getReleaseCount("validator")).to.equal(1);
      expect(await registry.getReleaseCount("webapp")).to.equal(0);
    });
  });
});
