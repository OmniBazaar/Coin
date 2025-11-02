const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("Bootstrap", function () {
  let bootstrap;
  let owner, admin, validator1, validator2, validator3;

  const FUJI_OMNICORE_ADDRESS = "0x322813Fd9A801c5507c9de605d63CEA4f2CE6c44";
  const FUJI_CHAIN_ID = 131313;
  const FUJI_RPC_URL = "http://127.0.0.1:44969/ext/bc/wFWtK4stScGVipRgh9em1aqY7TZ94rRBdV95BbGkjQFwh6wCS/rpc";

  beforeEach(async function () {
    [owner, admin, validator1, validator2, validator3] = await ethers.getSigners();

    // Deploy Bootstrap contract
    const Bootstrap = await ethers.getContractFactory("Bootstrap");
    bootstrap = await Bootstrap.deploy(
      FUJI_OMNICORE_ADDRESS,
      FUJI_CHAIN_ID,
      FUJI_RPC_URL
    );

    // Grant BOOTSTRAP_ADMIN_ROLE to admin account
    const BOOTSTRAP_ADMIN_ROLE = await bootstrap.BOOTSTRAP_ADMIN_ROLE();
    await bootstrap.grantRole(BOOTSTRAP_ADMIN_ROLE, admin.address);
  });

  describe("Initialization", function () {
    it("Should initialize with correct OmniCore reference", async function () {
      expect(await bootstrap.omniCoreAddress()).to.equal(FUJI_OMNICORE_ADDRESS);
      expect(await bootstrap.omniCoreChainId()).to.equal(FUJI_CHAIN_ID);
      expect(await bootstrap.omniCoreRpcUrl()).to.equal(FUJI_RPC_URL);
    });

    it("Should grant admin roles to deployer", async function () {
      const DEFAULT_ADMIN_ROLE = await bootstrap.DEFAULT_ADMIN_ROLE();
      const BOOTSTRAP_ADMIN_ROLE = await bootstrap.BOOTSTRAP_ADMIN_ROLE();

      expect(await bootstrap.hasRole(DEFAULT_ADMIN_ROLE, owner.address)).to.be.true;
      expect(await bootstrap.hasRole(BOOTSTRAP_ADMIN_ROLE, owner.address)).to.be.true;
    });

    it("Should reject invalid constructor parameters", async function () {
      const Bootstrap = await ethers.getContractFactory("Bootstrap");

      // Invalid address
      await expect(
        Bootstrap.deploy(ethers.ZeroAddress, FUJI_CHAIN_ID, FUJI_RPC_URL)
      ).to.be.revertedWithCustomError(Bootstrap, "InvalidAddress");

      // Invalid chain ID
      await expect(
        Bootstrap.deploy(FUJI_OMNICORE_ADDRESS, 0, FUJI_RPC_URL)
      ).to.be.revertedWithCustomError(Bootstrap, "InvalidChainId");

      // Invalid RPC URL
      await expect(
        Bootstrap.deploy(FUJI_OMNICORE_ADDRESS, FUJI_CHAIN_ID, "")
      ).to.be.revertedWithCustomError(Bootstrap, "InvalidParameter");
    });
  });

  describe("OmniCore Reference Management", function () {
    it("Should allow admin to update OmniCore reference", async function () {
      const newAddress = "0x1234567890123456789012345678901234567890";
      const newChainId = 999999;
      const newRpcUrl = "http://new-rpc-url.example.com";

      await expect(
        bootstrap.connect(admin).updateOmniCore(newAddress, newChainId, newRpcUrl)
      )
        .to.emit(bootstrap, "OmniCoreUpdated")
        .withArgs(newAddress, newChainId, newRpcUrl);

      expect(await bootstrap.omniCoreAddress()).to.equal(newAddress);
      expect(await bootstrap.omniCoreChainId()).to.equal(newChainId);
      expect(await bootstrap.omniCoreRpcUrl()).to.equal(newRpcUrl);
    });

    it("Should prevent non-admin from updating OmniCore", async function () {
      const newAddress = "0x1234567890123456789012345678901234567890";
      const BOOTSTRAP_ADMIN_ROLE = await bootstrap.BOOTSTRAP_ADMIN_ROLE();

      await expect(
        bootstrap.connect(validator1).updateOmniCore(newAddress, FUJI_CHAIN_ID, FUJI_RPC_URL)
      ).to.be.revertedWithCustomError(bootstrap, "AccessControlUnauthorizedAccount");
    });

    it("Should reject invalid OmniCore updates", async function () {
      // Invalid address
      await expect(
        bootstrap.connect(admin).updateOmniCore(ethers.ZeroAddress, FUJI_CHAIN_ID, FUJI_RPC_URL)
      ).to.be.revertedWithCustomError(bootstrap, "InvalidAddress");

      // Invalid chain ID
      await expect(
        bootstrap.connect(admin).updateOmniCore(FUJI_OMNICORE_ADDRESS, 0, FUJI_RPC_URL)
      ).to.be.revertedWithCustomError(bootstrap, "InvalidChainId");

      // Invalid RPC URL
      await expect(
        bootstrap.connect(admin).updateOmniCore(FUJI_OMNICORE_ADDRESS, FUJI_CHAIN_ID, "")
      ).to.be.revertedWithCustomError(bootstrap, "InvalidParameter");
    });

    it("Should return OmniCore info", async function () {
      const [address, chainId, rpcUrl] = await bootstrap.getOmniCoreInfo();

      expect(address).to.equal(FUJI_OMNICORE_ADDRESS);
      expect(chainId).to.equal(FUJI_CHAIN_ID);
      expect(rpcUrl).to.equal(FUJI_RPC_URL);
    });
  });

  describe("Bootstrap Validator Management", function () {
    const multiaddr1 = "/ip4/127.0.0.1/tcp/14001/p2p/QmValidator1";
    const httpEndpoint1 = "http://127.0.0.1:3001";
    const wsEndpoint1 = "ws://127.0.0.1:8101";
    const region1 = "us-east-1";

    const multiaddr2 = "/ip4/127.0.0.1/tcp/14002/p2p/QmValidator2";
    const httpEndpoint2 = "http://127.0.0.1:3002";
    const wsEndpoint2 = "ws://127.0.0.1:8102";
    const region2 = "eu-west-1";

    it("Should add bootstrap validator", async function () {
      await expect(
        bootstrap.connect(admin).addBootstrapValidator(
          validator1.address,
          multiaddr1,
          httpEndpoint1,
          wsEndpoint1,
          region1
        )
      )
        .to.emit(bootstrap, "BootstrapValidatorAdded")
        .withArgs(validator1.address, multiaddr1, httpEndpoint1);

      const info = await bootstrap.validatorInfo(validator1.address);
      expect(info.active).to.be.true;
      expect(info.nodeAddress).to.equal(validator1.address);
      expect(info.multiaddr).to.equal(multiaddr1);
      expect(info.httpEndpoint).to.equal(httpEndpoint1);
      expect(info.wsEndpoint).to.equal(wsEndpoint1);
      expect(info.region).to.equal(region1);
    });

    it("Should prevent non-admin from adding validators", async function () {
      await expect(
        bootstrap.connect(validator1).addBootstrapValidator(
          validator2.address,
          multiaddr1,
          httpEndpoint1,
          wsEndpoint1,
          region1
        )
      ).to.be.revertedWithCustomError(bootstrap, "AccessControlUnauthorizedAccount");
    });

    it("Should reject invalid validator parameters", async function () {
      // Invalid address
      await expect(
        bootstrap.connect(admin).addBootstrapValidator(
          ethers.ZeroAddress,
          multiaddr1,
          httpEndpoint1,
          wsEndpoint1,
          region1
        )
      ).to.be.revertedWithCustomError(bootstrap, "InvalidAddress");

      // Invalid multiaddr
      await expect(
        bootstrap.connect(admin).addBootstrapValidator(
          validator1.address,
          "",
          httpEndpoint1,
          wsEndpoint1,
          region1
        )
      ).to.be.revertedWithCustomError(bootstrap, "InvalidParameter");

      // Invalid HTTP endpoint
      await expect(
        bootstrap.connect(admin).addBootstrapValidator(
          validator1.address,
          multiaddr1,
          "",
          wsEndpoint1,
          region1
        )
      ).to.be.revertedWithCustomError(bootstrap, "InvalidParameter");

      // Invalid WS endpoint
      await expect(
        bootstrap.connect(admin).addBootstrapValidator(
          validator1.address,
          multiaddr1,
          httpEndpoint1,
          "",
          region1
        )
      ).to.be.revertedWithCustomError(bootstrap, "InvalidParameter");
    });

    it("Should prevent adding duplicate validators", async function () {
      await bootstrap.connect(admin).addBootstrapValidator(
        validator1.address,
        multiaddr1,
        httpEndpoint1,
        wsEndpoint1,
        region1
      );

      await expect(
        bootstrap.connect(admin).addBootstrapValidator(
          validator1.address,
          multiaddr1,
          httpEndpoint1,
          wsEndpoint1,
          region1
        )
      ).to.be.revertedWithCustomError(bootstrap, "ValidatorAlreadyExists");
    });

    it("Should update bootstrap validator", async function () {
      // Add validator first
      await bootstrap.connect(admin).addBootstrapValidator(
        validator1.address,
        multiaddr1,
        httpEndpoint1,
        wsEndpoint1,
        region1
      );

      const newMultiaddr = "/ip4/10.0.0.1/tcp/14001/p2p/QmValidator1Updated";
      const newHttpEndpoint = "http://10.0.0.1:3001";
      const newWsEndpoint = "ws://10.0.0.1:8101";
      const newRegion = "ap-south-1";

      await expect(
        bootstrap.connect(admin).updateBootstrapValidator(
          validator1.address,
          newMultiaddr,
          newHttpEndpoint,
          newWsEndpoint,
          newRegion
        )
      )
        .to.emit(bootstrap, "BootstrapValidatorUpdated")
        .withArgs(validator1.address, newMultiaddr, newHttpEndpoint);

      const info = await bootstrap.validatorInfo(validator1.address);
      expect(info.multiaddr).to.equal(newMultiaddr);
      expect(info.httpEndpoint).to.equal(newHttpEndpoint);
      expect(info.wsEndpoint).to.equal(newWsEndpoint);
      expect(info.region).to.equal(newRegion);
    });

    it("Should reject updating inactive validator", async function () {
      await expect(
        bootstrap.connect(admin).updateBootstrapValidator(
          validator1.address,
          multiaddr1,
          httpEndpoint1,
          wsEndpoint1,
          region1
        )
      ).to.be.revertedWithCustomError(bootstrap, "ValidatorNotActive");
    });

    it("Should remove bootstrap validator", async function () {
      // Add validator first
      await bootstrap.connect(admin).addBootstrapValidator(
        validator1.address,
        multiaddr1,
        httpEndpoint1,
        wsEndpoint1,
        region1
      );

      await expect(
        bootstrap.connect(admin).removeBootstrapValidator(validator1.address)
      )
        .to.emit(bootstrap, "BootstrapValidatorRemoved")
        .withArgs(validator1.address);

      const info = await bootstrap.validatorInfo(validator1.address);
      expect(info.active).to.be.false;

      // Should not be in the active list
      const count = await bootstrap.getBootstrapValidatorCount();
      expect(count).to.equal(0);
    });

    it("Should reject removing already inactive validator", async function () {
      await expect(
        bootstrap.connect(admin).removeBootstrapValidator(validator1.address)
      ).to.be.revertedWithCustomError(bootstrap, "ValidatorNotActive");
    });

    it("Should set validator status", async function () {
      // Add validator first
      await bootstrap.connect(admin).addBootstrapValidator(
        validator1.address,
        multiaddr1,
        httpEndpoint1,
        wsEndpoint1,
        region1
      );

      await expect(
        bootstrap.connect(admin).setBootstrapValidatorStatus(validator1.address, false)
      )
        .to.emit(bootstrap, "BootstrapValidatorStatusChanged")
        .withArgs(validator1.address, false);

      const info = await bootstrap.validatorInfo(validator1.address);
      expect(info.active).to.be.false;

      // Reactivate
      await bootstrap.connect(admin).setBootstrapValidatorStatus(validator1.address, true);
      const reactivatedInfo = await bootstrap.validatorInfo(validator1.address);
      expect(reactivatedInfo.active).to.be.true;
    });

    it("Should reject setting status for non-existent validator", async function () {
      await expect(
        bootstrap.connect(admin).setBootstrapValidatorStatus(validator1.address, true)
      ).to.be.revertedWithCustomError(bootstrap, "ValidatorNotFound");
    });
  });

  describe("Query Functions", function () {
    beforeEach(async function () {
      // Add 3 validators
      await bootstrap.connect(admin).addBootstrapValidator(
        validator1.address,
        "/ip4/127.0.0.1/tcp/14001/p2p/QmVal1",
        "http://127.0.0.1:3001",
        "ws://127.0.0.1:8101",
        "us-east-1"
      );

      await bootstrap.connect(admin).addBootstrapValidator(
        validator2.address,
        "/ip4/127.0.0.1/tcp/14002/p2p/QmVal2",
        "http://127.0.0.1:3002",
        "ws://127.0.0.1:8102",
        "eu-west-1"
      );

      await bootstrap.connect(admin).addBootstrapValidator(
        validator3.address,
        "/ip4/127.0.0.1/tcp/14003/p2p/QmVal3",
        "http://127.0.0.1:3003",
        "ws://127.0.0.1:8103",
        "ap-south-1"
      );
    });

    it("Should return correct bootstrap validator count", async function () {
      const count = await bootstrap.getBootstrapValidatorCount();
      expect(count).to.equal(3);
    });

    it("Should return active bootstrap validators", async function () {
      const [addresses, infos] = await bootstrap.getActiveBootstrapValidators();

      expect(addresses.length).to.equal(3);
      expect(addresses[0]).to.equal(validator1.address);
      expect(addresses[1]).to.equal(validator2.address);
      expect(addresses[2]).to.equal(validator3.address);

      expect(infos[0].active).to.be.true;
      expect(infos[0].multiaddr).to.equal("/ip4/127.0.0.1/tcp/14001/p2p/QmVal1");
      expect(infos[0].region).to.equal("us-east-1");
    });

    it("Should exclude inactive validators from active list", async function () {
      // Deactivate validator2
      await bootstrap.connect(admin).setBootstrapValidatorStatus(validator2.address, false);

      const [addresses, infos] = await bootstrap.getActiveBootstrapValidators();

      expect(addresses.length).to.equal(2);
      expect(addresses).to.not.include(validator2.address);

      const count = await bootstrap.getBootstrapValidatorCount();
      expect(count).to.equal(2);
    });

    it("Should handle empty validator list", async function () {
      // Remove all validators
      await bootstrap.connect(admin).removeBootstrapValidator(validator1.address);
      await bootstrap.connect(admin).removeBootstrapValidator(validator2.address);
      await bootstrap.connect(admin).removeBootstrapValidator(validator3.address);

      const count = await bootstrap.getBootstrapValidatorCount();
      expect(count).to.equal(0);

      const [addresses, infos] = await bootstrap.getActiveBootstrapValidators();
      expect(addresses.length).to.equal(0);
      expect(infos.length).to.equal(0);
    });
  });

  describe("Access Control", function () {
    it("Should allow only admin to add validators", async function () {
      const BOOTSTRAP_ADMIN_ROLE = await bootstrap.BOOTSTRAP_ADMIN_ROLE();

      await expect(
        bootstrap.connect(validator1).addBootstrapValidator(
          validator2.address,
          "/ip4/127.0.0.1/tcp/14002/p2p/QmVal2",
          "http://127.0.0.1:3002",
          "ws://127.0.0.1:8102",
          "us-east-1"
        )
      ).to.be.revertedWithCustomError(bootstrap, "AccessControlUnauthorizedAccount");
    });

    it("Should allow only admin to remove validators", async function () {
      // Add validator first
      await bootstrap.connect(admin).addBootstrapValidator(
        validator1.address,
        "/ip4/127.0.0.1/tcp/14001/p2p/QmVal1",
        "http://127.0.0.1:3001",
        "ws://127.0.0.1:8101",
        "us-east-1"
      );

      await expect(
        bootstrap.connect(validator1).removeBootstrapValidator(validator1.address)
      ).to.be.revertedWithCustomError(bootstrap, "AccessControlUnauthorizedAccount");
    });

    it("Should allow only admin to update validators", async function () {
      // Add validator first
      await bootstrap.connect(admin).addBootstrapValidator(
        validator1.address,
        "/ip4/127.0.0.1/tcp/14001/p2p/QmVal1",
        "http://127.0.0.1:3001",
        "ws://127.0.0.1:8101",
        "us-east-1"
      );

      await expect(
        bootstrap.connect(validator1).updateBootstrapValidator(
          validator1.address,
          "/ip4/10.0.0.1/tcp/14001/p2p/QmVal1",
          "http://10.0.0.1:3001",
          "ws://10.0.0.1:8101",
          "ap-south-1"
        )
      ).to.be.revertedWithCustomError(bootstrap, "AccessControlUnauthorizedAccount");
    });
  });

  describe("Integration Scenarios", function () {
    it("Should handle full lifecycle: add, update, deactivate, reactivate, remove", async function () {
      // Add
      await bootstrap.connect(admin).addBootstrapValidator(
        validator1.address,
        multiaddr1 = "/ip4/127.0.0.1/tcp/14001/p2p/QmVal1",
        httpEndpoint1 = "http://127.0.0.1:3001",
        wsEndpoint1 = "ws://127.0.0.1:8101",
        region1 = "us-east-1"
      );

      let count = await bootstrap.getBootstrapValidatorCount();
      expect(count).to.equal(1);

      // Update
      await bootstrap.connect(admin).updateBootstrapValidator(
        validator1.address,
        "/ip4/10.0.0.1/tcp/14001/p2p/QmVal1",
        "http://10.0.0.1:3001",
        "ws://10.0.0.1:8101",
        "ap-south-1"
      );

      const updatedInfo = await bootstrap.validatorInfo(validator1.address);
      expect(updatedInfo.region).to.equal("ap-south-1");

      // Deactivate
      await bootstrap.connect(admin).setBootstrapValidatorStatus(validator1.address, false);
      count = await bootstrap.getBootstrapValidatorCount();
      expect(count).to.equal(0);

      // Reactivate
      await bootstrap.connect(admin).setBootstrapValidatorStatus(validator1.address, true);
      count = await bootstrap.getBootstrapValidatorCount();
      expect(count).to.equal(1);

      // Remove
      await bootstrap.connect(admin).removeBootstrapValidator(validator1.address);
      count = await bootstrap.getBootstrapValidatorCount();
      expect(count).to.equal(0);
    });

    it("Should handle multiple validators efficiently", async function () {
      // Add multiple validators
      await bootstrap.connect(admin).addBootstrapValidator(
        validator1.address,
        "/ip4/127.0.0.1/tcp/14001/p2p/QmVal1",
        "http://127.0.0.1:3001",
        "ws://127.0.0.1:8101",
        "us-east-1"
      );

      await bootstrap.connect(admin).addBootstrapValidator(
        validator2.address,
        "/ip4/127.0.0.1/tcp/14002/p2p/QmVal2",
        "http://127.0.0.1:3002",
        "ws://127.0.0.1:8102",
        "eu-west-1"
      );

      await bootstrap.connect(admin).addBootstrapValidator(
        validator3.address,
        "/ip4/127.0.0.1/tcp/14003/p2p/QmVal3",
        "http://127.0.0.1:3003",
        "ws://127.0.0.1:8103",
        "ap-south-1"
      );

      // Query all
      const [addresses, infos] = await bootstrap.getActiveBootstrapValidators();
      expect(addresses.length).to.equal(3);

      // Verify order matches insertion
      expect(addresses[0]).to.equal(validator1.address);
      expect(addresses[1]).to.equal(validator2.address);
      expect(addresses[2]).to.equal(validator3.address);

      // Verify regions
      expect(infos[0].region).to.equal("us-east-1");
      expect(infos[1].region).to.equal("eu-west-1");
      expect(infos[2].region).to.equal("ap-south-1");
    });
  });
});
