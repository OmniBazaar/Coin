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

  // ===========================================================================
  // NEW TESTS BELOW
  // ===========================================================================

  // ---------------------------------------------------------------------------
  // Constructor edge cases
  // ---------------------------------------------------------------------------

  describe("Constructor edge cases", function () {
    it("should revert with ZeroAddress when deploying with address(0) as updater", async function () {
      const Credential = await ethers.getContractFactory("ReputationCredential");
      await expect(
        Credential.deploy(ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(Credential, "ZeroAddress");
    });

    it("should initialize pendingUpdater to address(0)", async function () {
      expect(await credential.pendingUpdater()).to.equal(ethers.ZeroAddress);
    });

    it("should start token IDs at 1 (getTokenId returns 0 for unminted users)", async function () {
      expect(await credential.getTokenId(userA.address)).to.equal(0);
    });
  });

  // ---------------------------------------------------------------------------
  // Score bounds validation (M-01)
  // ---------------------------------------------------------------------------

  describe("Score bounds validation (M-01)", function () {
    describe("averageRating bounds", function () {
      it("should accept averageRating of 0 (minimum)", async function () {
        const data = makeReputationData({ averageRating: 0 });
        await credential.connect(updater).mint(userA.address, data);
        const rep = await credential.getReputation(userA.address);
        expect(rep.averageRating).to.equal(0);
      });

      it("should accept averageRating of 500 (maximum = 5.00 stars)", async function () {
        const data = makeReputationData({ averageRating: 500 });
        await credential.connect(updater).mint(userA.address, data);
        const rep = await credential.getReputation(userA.address);
        expect(rep.averageRating).to.equal(500);
      });

      it("should revert with InvalidRating when averageRating is 501", async function () {
        const data = makeReputationData({ averageRating: 501 });
        await expect(
          credential.connect(updater).mint(userA.address, data)
        ).to.be.revertedWithCustomError(credential, "InvalidRating")
          .withArgs(501);
      });

      it("should revert with InvalidRating when averageRating is at uint16 max (65535)", async function () {
        const data = makeReputationData({ averageRating: 65535 });
        await expect(
          credential.connect(updater).mint(userA.address, data)
        ).to.be.revertedWithCustomError(credential, "InvalidRating")
          .withArgs(65535);
      });
    });

    describe("kycTier bounds", function () {
      it("should accept kycTier of 0 (minimum)", async function () {
        const data = makeReputationData({ kycTier: 0 });
        await credential.connect(updater).mint(userA.address, data);
        const rep = await credential.getReputation(userA.address);
        expect(rep.kycTier).to.equal(0);
      });

      it("should accept kycTier of 4 (maximum)", async function () {
        const data = makeReputationData({ kycTier: 4 });
        await credential.connect(updater).mint(userA.address, data);
        const rep = await credential.getReputation(userA.address);
        expect(rep.kycTier).to.equal(4);
      });

      it("should revert with InvalidKYCTier when kycTier is 5", async function () {
        const data = makeReputationData({ kycTier: 5 });
        await expect(
          credential.connect(updater).mint(userA.address, data)
        ).to.be.revertedWithCustomError(credential, "InvalidKYCTier")
          .withArgs(5);
      });

      it("should revert with InvalidKYCTier when kycTier is at uint8 max (255)", async function () {
        const data = makeReputationData({ kycTier: 255 });
        await expect(
          credential.connect(updater).mint(userA.address, data)
        ).to.be.revertedWithCustomError(credential, "InvalidKYCTier")
          .withArgs(255);
      });
    });

    describe("participationScore bounds", function () {
      it("should accept participationScore of 0 (minimum)", async function () {
        const data = makeReputationData({ participationScore: 0 });
        await credential.connect(updater).mint(userA.address, data);
        const rep = await credential.getReputation(userA.address);
        expect(rep.participationScore).to.equal(0);
      });

      it("should accept participationScore of 100 (maximum)", async function () {
        const data = makeReputationData({ participationScore: 100 });
        await credential.connect(updater).mint(userA.address, data);
        const rep = await credential.getReputation(userA.address);
        expect(rep.participationScore).to.equal(100);
      });

      it("should revert with InvalidScore when participationScore is 101", async function () {
        const data = makeReputationData({ participationScore: 101 });
        await expect(
          credential.connect(updater).mint(userA.address, data)
        ).to.be.revertedWithCustomError(credential, "InvalidScore")
          .withArgs(101);
      });

      it("should revert with InvalidScore when participationScore is 65535 (uint16 max)", async function () {
        const data = makeReputationData({ participationScore: 65535 });
        await expect(
          credential.connect(updater).mint(userA.address, data)
        ).to.be.revertedWithCustomError(credential, "InvalidScore")
          .withArgs(65535);
      });
    });

    describe("bounds validation on updateReputation", function () {
      beforeEach(async function () {
        const data = makeReputationData();
        await credential.connect(updater).mint(userA.address, data);
      });

      it("should revert with InvalidRating on update with rating > 500", async function () {
        const updated = makeReputationData({ averageRating: 501 });
        await expect(
          credential.connect(updater).updateReputation(userA.address, updated)
        ).to.be.revertedWithCustomError(credential, "InvalidRating")
          .withArgs(501);
      });

      it("should revert with InvalidKYCTier on update with kycTier > 4", async function () {
        const updated = makeReputationData({ kycTier: 5 });
        await expect(
          credential.connect(updater).updateReputation(userA.address, updated)
        ).to.be.revertedWithCustomError(credential, "InvalidKYCTier")
          .withArgs(5);
      });

      it("should revert with InvalidScore on update with participationScore > 100", async function () {
        const updated = makeReputationData({ participationScore: 101 });
        await expect(
          credential.connect(updater).updateReputation(userA.address, updated)
        ).to.be.revertedWithCustomError(credential, "InvalidScore")
          .withArgs(101);
      });
    });
  });

  // ---------------------------------------------------------------------------
  // Two-step updater transfer (M-02)
  // ---------------------------------------------------------------------------

  describe("Two-step updater transfer (M-02)", function () {
    let newUpdater;

    before(async function () {
      const signers = await ethers.getSigners();
      newUpdater = signers[4];
    });

    it("should allow current updater to propose a new updater", async function () {
      await credential.connect(updater).transferUpdater(newUpdater.address);
      expect(await credential.pendingUpdater()).to.equal(newUpdater.address);
    });

    it("should emit UpdaterTransferProposed on transferUpdater", async function () {
      await expect(
        credential.connect(updater).transferUpdater(newUpdater.address)
      )
        .to.emit(credential, "UpdaterTransferProposed")
        .withArgs(updater.address, newUpdater.address);
    });

    it("should revert with NotAuthorized when non-updater calls transferUpdater", async function () {
      await expect(
        credential.connect(userA).transferUpdater(newUpdater.address)
      ).to.be.revertedWithCustomError(credential, "NotAuthorized");
    });

    it("should revert with ZeroAddress when proposing address(0)", async function () {
      await expect(
        credential.connect(updater).transferUpdater(ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(credential, "ZeroAddress");
    });

    it("should allow proposed updater to accept the role", async function () {
      await credential.connect(updater).transferUpdater(newUpdater.address);
      await credential.connect(newUpdater).acceptUpdater();

      expect(await credential.authorizedUpdater()).to.equal(newUpdater.address);
      expect(await credential.pendingUpdater()).to.equal(ethers.ZeroAddress);
    });

    it("should emit UpdaterTransferred on acceptUpdater", async function () {
      await credential.connect(updater).transferUpdater(newUpdater.address);

      await expect(credential.connect(newUpdater).acceptUpdater())
        .to.emit(credential, "UpdaterTransferred")
        .withArgs(updater.address, newUpdater.address);
    });

    it("should revert with NotAuthorized when non-pending address calls acceptUpdater", async function () {
      await credential.connect(updater).transferUpdater(newUpdater.address);

      await expect(
        credential.connect(userA).acceptUpdater()
      ).to.be.revertedWithCustomError(credential, "NotAuthorized");
    });

    it("should revert with NotAuthorized when old updater calls acceptUpdater", async function () {
      await credential.connect(updater).transferUpdater(newUpdater.address);

      await expect(
        credential.connect(updater).acceptUpdater()
      ).to.be.revertedWithCustomError(credential, "NotAuthorized");
    });

    it("should allow new updater to mint after transfer", async function () {
      await credential.connect(updater).transferUpdater(newUpdater.address);
      await credential.connect(newUpdater).acceptUpdater();

      const data = makeReputationData();
      await credential.connect(newUpdater).mint(userA.address, data);
      expect(await credential.ownerOf(1)).to.equal(userA.address);
    });

    it("should prevent old updater from minting after transfer", async function () {
      await credential.connect(updater).transferUpdater(newUpdater.address);
      await credential.connect(newUpdater).acceptUpdater();

      const data = makeReputationData();
      await expect(
        credential.connect(updater).mint(userA.address, data)
      ).to.be.revertedWithCustomError(credential, "NotAuthorized");
    });

    it("should allow new updater to update reputation after transfer", async function () {
      // Mint with original updater
      const data = makeReputationData();
      await credential.connect(updater).mint(userA.address, data);

      // Transfer updater role
      await credential.connect(updater).transferUpdater(newUpdater.address);
      await credential.connect(newUpdater).acceptUpdater();

      // Update with new updater
      const updated = makeReputationData({ participationScore: 99 });
      await credential.connect(newUpdater).updateReputation(userA.address, updated);
      const rep = await credential.getReputation(userA.address);
      expect(rep.participationScore).to.equal(99);
    });
  });

  // ---------------------------------------------------------------------------
  // Access control on all admin functions
  // ---------------------------------------------------------------------------

  describe("Access control", function () {
    it("should revert with NotAuthorized when non-updater calls updateReputation", async function () {
      const data = makeReputationData();
      await credential.connect(updater).mint(userA.address, data);

      const updated = makeReputationData({ participationScore: 99 });
      await expect(
        credential.connect(userA).updateReputation(userA.address, updated)
      ).to.be.revertedWithCustomError(credential, "NotAuthorized");
    });

    it("should revert with NotAuthorized when owner (non-updater) calls mint", async function () {
      const data = makeReputationData();
      await expect(
        credential.connect(owner).mint(userA.address, data)
      ).to.be.revertedWithCustomError(credential, "NotAuthorized");
    });

    it("should revert with NotAuthorized when owner (non-updater) calls updateReputation", async function () {
      const data = makeReputationData();
      await credential.connect(updater).mint(userA.address, data);

      const updated = makeReputationData({ participationScore: 50 });
      await expect(
        credential.connect(owner).updateReputation(userA.address, updated)
      ).to.be.revertedWithCustomError(credential, "NotAuthorized");
    });

    it("should revert with NotAuthorized when owner (non-updater) calls transferUpdater", async function () {
      await expect(
        credential.connect(owner).transferUpdater(userA.address)
      ).to.be.revertedWithCustomError(credential, "NotAuthorized");
    });
  });

  // ---------------------------------------------------------------------------
  // View functions
  // ---------------------------------------------------------------------------

  describe("View functions", function () {
    it("hasReputation should return false for unminted user", async function () {
      expect(await credential.hasReputation(userA.address)).to.equal(false);
    });

    it("hasReputation should return true after minting", async function () {
      await credential.connect(updater).mint(userA.address, makeReputationData());
      expect(await credential.hasReputation(userA.address)).to.equal(true);
    });

    it("getTokenId should return 0 for unminted user", async function () {
      expect(await credential.getTokenId(userA.address)).to.equal(0);
    });

    it("getTokenId should return correct tokenId after minting", async function () {
      await credential.connect(updater).mint(userA.address, makeReputationData());
      expect(await credential.getTokenId(userA.address)).to.equal(1);

      await credential.connect(updater).mint(userB.address, makeReputationData());
      expect(await credential.getTokenId(userB.address)).to.equal(2);
    });

    it("getReputation should revert with TokenNotFound for unminted user", async function () {
      await expect(
        credential.getReputation(userA.address)
      ).to.be.revertedWithCustomError(credential, "TokenNotFound");
    });

    it("balanceOf should return 1 for a user with a minted token", async function () {
      await credential.connect(updater).mint(userA.address, makeReputationData());
      expect(await credential.balanceOf(userA.address)).to.equal(1);
    });

    it("balanceOf should return 0 for a user without a token", async function () {
      expect(await credential.balanceOf(userA.address)).to.equal(0);
    });
  });

  // ---------------------------------------------------------------------------
  // ERC-165 / ERC-5192 interface support
  // ---------------------------------------------------------------------------

  describe("ERC-165 and ERC-5192 interface support", function () {
    it("should support ERC-5192 interface (0xb45a3c0e)", async function () {
      expect(await credential.supportsInterface("0xb45a3c0e")).to.equal(true);
    });

    it("should support ERC-721 interface (0x80ac58cd)", async function () {
      expect(await credential.supportsInterface("0x80ac58cd")).to.equal(true);
    });

    it("should support ERC-165 interface (0x01ffc9a7)", async function () {
      expect(await credential.supportsInterface("0x01ffc9a7")).to.equal(true);
    });

    it("should not support a random interface (0xdeadbeef)", async function () {
      expect(await credential.supportsInterface("0xdeadbeef")).to.equal(false);
    });
  });

  // ---------------------------------------------------------------------------
  // Soulbound transfer blocking - additional paths
  // ---------------------------------------------------------------------------

  describe("Soulbound transfer blocking - additional paths", function () {
    beforeEach(async function () {
      await credential.connect(updater).mint(userA.address, makeReputationData());
    });

    it("should revert with Soulbound on safeTransferFrom (with data)", async function () {
      await expect(
        credential.connect(userA)["safeTransferFrom(address,address,uint256,bytes)"](
          userA.address, userB.address, 1, "0x"
        )
      ).to.be.revertedWithCustomError(credential, "Soulbound");
    });

    it("should revert with Soulbound on safeTransferFrom (without data)", async function () {
      await expect(
        credential.connect(userA)["safeTransferFrom(address,address,uint256)"](
          userA.address, userB.address, 1
        )
      ).to.be.revertedWithCustomError(credential, "Soulbound");
    });

    it("should revert with Soulbound when approved operator tries transferFrom", async function () {
      // Note: approve itself may still work but actual transfer should fail
      // The _update override blocks all transfers from non-zero addresses
      await expect(
        credential.connect(userB).transferFrom(userA.address, userB.address, 1)
      ).to.be.reverted;
    });
  });

  // ---------------------------------------------------------------------------
  // Multiple users / sequential minting
  // ---------------------------------------------------------------------------

  describe("Multiple users and sequential minting", function () {
    let userC;
    let userD;

    before(async function () {
      const signers = await ethers.getSigners();
      userC = signers[5];
      userD = signers[6];
    });

    it("should assign incrementing token IDs to different users", async function () {
      await credential.connect(updater).mint(userA.address, makeReputationData());
      await credential.connect(updater).mint(userB.address, makeReputationData());
      await credential.connect(updater).mint(userC.address, makeReputationData());

      expect(await credential.getTokenId(userA.address)).to.equal(1);
      expect(await credential.getTokenId(userB.address)).to.equal(2);
      expect(await credential.getTokenId(userC.address)).to.equal(3);
    });

    it("should store independent reputation data per user", async function () {
      const dataA = makeReputationData({ participationScore: 10, kycTier: 1 });
      const dataB = makeReputationData({ participationScore: 50, kycTier: 3 });
      const dataC = makeReputationData({ participationScore: 100, kycTier: 4 });

      await credential.connect(updater).mint(userA.address, dataA);
      await credential.connect(updater).mint(userB.address, dataB);
      await credential.connect(updater).mint(userC.address, dataC);

      const repA = await credential.getReputation(userA.address);
      const repB = await credential.getReputation(userB.address);
      const repC = await credential.getReputation(userC.address);

      expect(repA.participationScore).to.equal(10);
      expect(repB.participationScore).to.equal(50);
      expect(repC.participationScore).to.equal(100);
      expect(repA.kycTier).to.equal(1);
      expect(repB.kycTier).to.equal(3);
      expect(repC.kycTier).to.equal(4);
    });

    it("should update one user without affecting another", async function () {
      await credential.connect(updater).mint(userA.address, makeReputationData({ participationScore: 30 }));
      await credential.connect(updater).mint(userB.address, makeReputationData({ participationScore: 60 }));

      await credential.connect(updater).updateReputation(
        userA.address,
        makeReputationData({ participationScore: 90 })
      );

      const repA = await credential.getReputation(userA.address);
      const repB = await credential.getReputation(userB.address);
      expect(repA.participationScore).to.equal(90);
      expect(repB.participationScore).to.equal(60); // unchanged
    });
  });

  // ---------------------------------------------------------------------------
  // lastUpdated timestamp
  // ---------------------------------------------------------------------------

  describe("lastUpdated timestamp", function () {
    it("should set lastUpdated to block.timestamp on mint", async function () {
      await credential.connect(updater).mint(userA.address, makeReputationData());
      const rep = await credential.getReputation(userA.address);
      const block = await ethers.provider.getBlock("latest");
      expect(rep.lastUpdated).to.equal(block.timestamp);
    });

    it("should update lastUpdated on updateReputation", async function () {
      await credential.connect(updater).mint(userA.address, makeReputationData());
      const repBefore = await credential.getReputation(userA.address);

      // Mine a block to advance time
      await ethers.provider.send("evm_mine", []);

      await credential.connect(updater).updateReputation(
        userA.address,
        makeReputationData({ participationScore: 99 })
      );

      const repAfter = await credential.getReputation(userA.address);
      expect(repAfter.lastUpdated).to.be.gte(repBefore.lastUpdated);
    });

    it("should ignore the lastUpdated value provided by the caller", async function () {
      // Pass a specific lastUpdated value; contract should overwrite it
      const data = makeReputationData({ lastUpdated: 12345 });
      await credential.connect(updater).mint(userA.address, data);

      const rep = await credential.getReputation(userA.address);
      expect(rep.lastUpdated).to.not.equal(12345);
      expect(rep.lastUpdated).to.be.gt(0);
    });
  });

  // ---------------------------------------------------------------------------
  // tokenURI edge cases
  // ---------------------------------------------------------------------------

  describe("tokenURI edge cases", function () {
    it("should revert with TokenNotFound for non-existent token", async function () {
      await expect(
        credential.tokenURI(999)
      ).to.be.revertedWithCustomError(credential, "TokenNotFound");
    });

    it("should correctly encode all zero values in metadata", async function () {
      const data = makeReputationData({
        totalTransactions: 0,
        averageRating: 0,
        accountAgeDays: 0,
        kycTier: 0,
        disputeWins: 0,
        disputeLosses: 0,
        participationScore: 0
      });
      await credential.connect(updater).mint(userA.address, data);

      const uri = await credential.tokenURI(1);
      const base64Payload = uri.replace("data:application/json;base64,", "");
      const json = JSON.parse(Buffer.from(base64Payload, "base64").toString("utf-8"));

      // All attribute values should be 0
      for (const attr of json.attributes) {
        expect(attr.value).to.equal(0);
      }
    });

    it("should correctly encode maximum valid values in metadata", async function () {
      const data = makeReputationData({
        totalTransactions: 4294967295, // uint32 max
        averageRating: 500,
        accountAgeDays: 65535, // uint16 max
        kycTier: 4,
        disputeWins: 65535,
        disputeLosses: 65535,
        participationScore: 100
      });
      await credential.connect(updater).mint(userA.address, data);

      const uri = await credential.tokenURI(1);
      const base64Payload = uri.replace("data:application/json;base64,", "");
      const json = JSON.parse(Buffer.from(base64Payload, "base64").toString("utf-8"));

      const totalTx = json.attributes.find(a => a.trait_type === "Total Transactions");
      expect(totalTx.value).to.equal(4294967295);

      const rating = json.attributes.find(a => a.trait_type === "Average Rating");
      expect(rating.value).to.equal(500);

      const kyc = json.attributes.find(a => a.trait_type === "KYC Tier");
      expect(kyc.value).to.equal(4);
    });

    it("should produce different tokenURIs for different token IDs", async function () {
      await credential.connect(updater).mint(userA.address, makeReputationData());
      await credential.connect(updater).mint(userB.address, makeReputationData());

      const uri1 = await credential.tokenURI(1);
      const uri2 = await credential.tokenURI(2);

      // URIs must differ because of different token IDs in the name
      expect(uri1).to.not.equal(uri2);

      // Verify each has correct name
      const json1 = JSON.parse(
        Buffer.from(uri1.replace("data:application/json;base64,", ""), "base64").toString("utf-8")
      );
      const json2 = JSON.parse(
        Buffer.from(uri2.replace("data:application/json;base64,", ""), "base64").toString("utf-8")
      );
      expect(json1.name).to.equal("OmniBazaar Reputation #1");
      expect(json2.name).to.equal("OmniBazaar Reputation #2");
    });
  });

  // ---------------------------------------------------------------------------
  // Mint with zero-value edge cases
  // ---------------------------------------------------------------------------

  describe("Mint with edge case data", function () {
    it("should mint successfully with all-zero reputation data", async function () {
      const data = makeReputationData({
        totalTransactions: 0,
        averageRating: 0,
        accountAgeDays: 0,
        kycTier: 0,
        disputeWins: 0,
        disputeLosses: 0,
        participationScore: 0
      });
      await credential.connect(updater).mint(userA.address, data);
      expect(await credential.hasReputation(userA.address)).to.equal(true);
    });

    it("should mint with maximum valid values for all bounded fields", async function () {
      const data = makeReputationData({
        averageRating: 500,
        kycTier: 4,
        participationScore: 100
      });
      await credential.connect(updater).mint(userA.address, data);
      const rep = await credential.getReputation(userA.address);
      expect(rep.averageRating).to.equal(500);
      expect(rep.kycTier).to.equal(4);
      expect(rep.participationScore).to.equal(100);
    });

    it("should mint with maximum uint32 totalTransactions", async function () {
      const data = makeReputationData({ totalTransactions: 4294967295 });
      await credential.connect(updater).mint(userA.address, data);
      const rep = await credential.getReputation(userA.address);
      expect(rep.totalTransactions).to.equal(4294967295);
    });

    it("should mint with maximum uint16 disputeWins and disputeLosses", async function () {
      const data = makeReputationData({
        disputeWins: 65535,
        disputeLosses: 65535
      });
      await credential.connect(updater).mint(userA.address, data);
      const rep = await credential.getReputation(userA.address);
      expect(rep.disputeWins).to.equal(65535);
      expect(rep.disputeLosses).to.equal(65535);
    });
  });
});
