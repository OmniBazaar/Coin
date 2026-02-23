const { expect } = require("chai");
const { ethers } = require("hardhat");

/**
 * @title ReputationCredential Test Suite
 * @notice Tests for the soulbound ERC-721 reputation credential contract.
 * @dev Validates minting, soulbound transfer blocking, reputation updates,
 *      on-chain metadata, ERC-5192 locked() behaviour, and access control.
 */
describe("ReputationCredential", function () {
  let owner;
  let updater;
  let userA;
  let userB;
  let credential;

  /**
   * Helper that builds a ReputationData struct tuple matching the Solidity ordering:
   *   { totalTransactions, averageRating, accountAgeDays, kycTier,
   *     disputeWins, disputeLosses, participationScore, lastUpdated }
   *
   * @param {object} [overrides] - Optional field overrides.
   * @returns {Array} Ordered tuple suitable for contract calls.
   */
  function makeReputationData(overrides = {}) {
    return [
      overrides.totalTransactions ?? 150,    // uint32
      overrides.averageRating ?? 450,        // uint16 (4.50 stars)
      overrides.accountAgeDays ?? 365,       // uint16
      overrides.kycTier ?? 3,                // uint8
      overrides.disputeWins ?? 5,            // uint16
      overrides.disputeLosses ?? 1,          // uint16
      overrides.participationScore ?? 72,    // uint16
      overrides.lastUpdated ?? 0             // uint64 (overwritten by contract)
    ];
  }

  before(async function () {
    const signers = await ethers.getSigners();
    owner = signers[0];
    updater = signers[1];
    userA = signers[2];
    userB = signers[3];
  });

  beforeEach(async function () {
    const Credential = await ethers.getContractFactory("ReputationCredential");
    credential = await Credential.deploy(updater.address);
    await credential.waitForDeployment();
  });

  // ---------------------------------------------------------------------------
  // Constructor & getters
  // ---------------------------------------------------------------------------

  describe("Constructor", function () {
    it("should set the authorizedUpdater correctly", async function () {
      // M-02: authorizedUpdater is now a mutable state variable
      // (supports two-step transfer), not an immutable constant.
      expect(await credential.authorizedUpdater()).to.equal(updater.address);
    });

    it("should set the ERC-721 name to 'OmniBazaar Reputation'", async function () {
      expect(await credential.name()).to.equal("OmniBazaar Reputation");
    });

    it("should set the ERC-721 symbol to 'OMNI-REP'", async function () {
      expect(await credential.symbol()).to.equal("OMNI-REP");
    });
  });

  // ---------------------------------------------------------------------------
  // Mint
  // ---------------------------------------------------------------------------

  describe("mint", function () {
    it("should mint a reputation token and assign it to the user", async function () {
      const data = makeReputationData();
      await credential.connect(updater).mint(userA.address, data);

      expect(await credential.ownerOf(1)).to.equal(userA.address);
      expect(await credential.hasReputation(userA.address)).to.equal(true);
      expect(await credential.getTokenId(userA.address)).to.equal(1);
    });

    it("should emit Locked and ReputationUpdated events on mint", async function () {
      const data = makeReputationData({ participationScore: 85 });

      await expect(credential.connect(updater).mint(userA.address, data))
        .to.emit(credential, "Locked")
        .withArgs(1)
        .and.to.emit(credential, "ReputationUpdated")
        .withArgs(1, 85);
    });

    it("should store the reputation data correctly", async function () {
      const data = makeReputationData({
        totalTransactions: 200,
        averageRating: 490,
        accountAgeDays: 730,
        kycTier: 4,
        disputeWins: 10,
        disputeLosses: 2,
        participationScore: 95
      });

      await credential.connect(updater).mint(userA.address, data);

      const rep = await credential.getReputation(userA.address);
      expect(rep.totalTransactions).to.equal(200);
      expect(rep.averageRating).to.equal(490);
      expect(rep.accountAgeDays).to.equal(730);
      expect(rep.kycTier).to.equal(4);
      expect(rep.disputeWins).to.equal(10);
      expect(rep.disputeLosses).to.equal(2);
      expect(rep.participationScore).to.equal(95);
      // lastUpdated is set to block.timestamp by the contract, so just verify nonzero
      expect(rep.lastUpdated).to.be.gt(0);
    });

    it("should revert with AlreadyMinted when minting twice for the same user", async function () {
      const data = makeReputationData();
      await credential.connect(updater).mint(userA.address, data);

      await expect(
        credential.connect(updater).mint(userA.address, data)
      ).to.be.revertedWithCustomError(credential, "AlreadyMinted");
    });

    it("should revert with NotAuthorized when a non-updater calls mint", async function () {
      const data = makeReputationData();
      await expect(
        credential.connect(userA).mint(userA.address, data)
      ).to.be.revertedWithCustomError(credential, "NotAuthorized");
    });
  });

  // ---------------------------------------------------------------------------
  // Soulbound transfer blocking
  // ---------------------------------------------------------------------------

  describe("Soulbound transfers", function () {
    it("should revert with Soulbound when attempting to transfer the token", async function () {
      const data = makeReputationData();
      await credential.connect(updater).mint(userA.address, data);

      await expect(
        credential.connect(userA).transferFrom(userA.address, userB.address, 1)
      ).to.be.revertedWithCustomError(credential, "Soulbound");
    });
  });

  // ---------------------------------------------------------------------------
  // updateReputation
  // ---------------------------------------------------------------------------

  describe("updateReputation", function () {
    it("should update reputation data for an existing token", async function () {
      const initial = makeReputationData({ participationScore: 50 });
      await credential.connect(updater).mint(userA.address, initial);

      const updated = makeReputationData({
        totalTransactions: 300,
        averageRating: 475,
        participationScore: 88
      });
      await credential.connect(updater).updateReputation(userA.address, updated);

      const rep = await credential.getReputation(userA.address);
      expect(rep.totalTransactions).to.equal(300);
      expect(rep.averageRating).to.equal(475);
      expect(rep.participationScore).to.equal(88);
    });

    it("should emit ReputationUpdated on update", async function () {
      const initial = makeReputationData();
      await credential.connect(updater).mint(userA.address, initial);

      const updated = makeReputationData({ participationScore: 99 });
      await expect(
        credential.connect(updater).updateReputation(userA.address, updated)
      )
        .to.emit(credential, "ReputationUpdated")
        .withArgs(1, 99);
    });

    it("should revert with TokenNotFound when user has no token", async function () {
      const data = makeReputationData();
      await expect(
        credential.connect(updater).updateReputation(userB.address, data)
      ).to.be.revertedWithCustomError(credential, "TokenNotFound");
    });
  });

  // ---------------------------------------------------------------------------
  // locked (ERC-5192)
  // ---------------------------------------------------------------------------

  describe("locked (ERC-5192)", function () {
    it("should return true for a minted token", async function () {
      const data = makeReputationData();
      await credential.connect(updater).mint(userA.address, data);

      expect(await credential.locked(1)).to.equal(true);
    });

    it("should revert with TokenNotFound for a non-existent token", async function () {
      await expect(
        credential.locked(999)
      ).to.be.revertedWithCustomError(credential, "TokenNotFound");
    });
  });

  // ---------------------------------------------------------------------------
  // tokenURI
  // ---------------------------------------------------------------------------

  describe("tokenURI", function () {
    it("should return a data URI with base64-encoded JSON metadata", async function () {
      const data = makeReputationData({ participationScore: 72 });
      await credential.connect(updater).mint(userA.address, data);

      const uri = await credential.tokenURI(1);
      expect(uri).to.match(/^data:application\/json;base64,/);

      // Decode and verify the JSON structure
      const base64Payload = uri.replace("data:application/json;base64,", "");
      const json = JSON.parse(Buffer.from(base64Payload, "base64").toString("utf-8"));

      expect(json.name).to.equal("OmniBazaar Reputation #1");
      expect(json.description).to.include("Soulbound reputation credential");
      expect(json.attributes).to.be.an("array").that.has.lengthOf(7);

      // Verify the Participation Score attribute
      const psAttr = json.attributes.find(
        (a) => a.trait_type === "Participation Score"
      );
      expect(psAttr).to.not.be.undefined;
      expect(psAttr.value).to.equal(72);
    });
  });
});
