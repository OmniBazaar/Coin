const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("Bootstrap", function () {
  let bootstrap;
  let owner, admin, node1, node2, node3;

  const FUJI_OMNICORE_ADDRESS = "0x322813Fd9A801c5507c9de605d63CEA4f2CE6c44";
  const FUJI_CHAIN_ID = 131313;
  const FUJI_RPC_URL = "http://127.0.0.1:44969/ext/bc/wFWtK4stScGVipRgh9em1aqY7TZ94rRBdV95BbGkjQFwh6wCS/rpc";

  beforeEach(async function () {
    [owner, admin, node1, node2, node3] = await ethers.getSigners();

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

      await expect(
        bootstrap.connect(node1).updateOmniCore(newAddress, FUJI_CHAIN_ID, FUJI_RPC_URL)
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

  describe("Node Self-Registration", function () {
    const multiaddr1 = "/ip4/127.0.0.1/tcp/14001/p2p/QmNode1";
    const httpEndpoint1 = "http://127.0.0.1:3001";
    const wsEndpoint1 = "ws://127.0.0.1:8101";
    const region1 = "us-east-1";

    const multiaddr2 = "/ip4/127.0.0.1/tcp/14002/p2p/QmNode2";
    const httpEndpoint2 = "http://127.0.0.1:3002";
    const wsEndpoint2 = "ws://127.0.0.1:8102";
    const region2 = "eu-west-1";

    it("Should register a computation node (self-registration)", async function () {
      // nodeType 1 = computation node
      await expect(
        bootstrap.connect(node1).registerNode(
          multiaddr1,
          httpEndpoint1,
          wsEndpoint1,
          region1,
          1 // computation node
        )
      )
        .to.emit(bootstrap, "NodeRegistered")
        .withArgs(node1.address, 1, httpEndpoint1, true);

      const info = await bootstrap.getNodeInfo(node1.address);
      expect(info.active).to.be.true;
      expect(info.multiaddr).to.equal(multiaddr1);
      expect(info.httpEndpoint).to.equal(httpEndpoint1);
      expect(info.wsEndpoint).to.equal(wsEndpoint1);
      expect(info.region).to.equal(region1);
      expect(info.nodeType).to.equal(1);
    });

    it("Should register a gateway node with peer discovery info", async function () {
      await expect(
        bootstrap.connect(node1).registerGatewayNode(
          multiaddr1,
          httpEndpoint1,
          wsEndpoint1,
          region1,
          "http://127.0.0.1:40681/ext/bc/L1/rpc",
          35579,
          "203.0.113.1",
          "NodeID-testnode1"
        )
      )
        .to.emit(bootstrap, "NodeRegistered")
        .withArgs(node1.address, 0, httpEndpoint1, true);

      const info = await bootstrap.getNodeInfo(node1.address);
      expect(info.active).to.be.true;
      expect(info.nodeType).to.equal(0);
    });

    it("Should reject gateway node via registerNode (must use registerGatewayNode)", async function () {
      await expect(
        bootstrap.connect(node1).registerNode(
          multiaddr1,
          httpEndpoint1,
          wsEndpoint1,
          region1,
          0 // gateway type
        )
      ).to.be.revertedWithCustomError(bootstrap, "GatewayMustUseRegisterGatewayNode");
    });

    it("Should reject invalid registration parameters", async function () {
      // Empty HTTP endpoint
      await expect(
        bootstrap.connect(node1).registerNode(
          multiaddr1,
          "",
          wsEndpoint1,
          region1,
          1
        )
      ).to.be.revertedWithCustomError(bootstrap, "InvalidParameter");
    });

    it("Should update node info when re-registering", async function () {
      // Register first
      await bootstrap.connect(node1).registerNode(
        multiaddr1,
        httpEndpoint1,
        wsEndpoint1,
        region1,
        1
      );

      // Re-register with updated info (emits isNew=false)
      await expect(
        bootstrap.connect(node1).registerNode(
          multiaddr2,
          httpEndpoint2,
          wsEndpoint2,
          region2,
          1
        )
      )
        .to.emit(bootstrap, "NodeRegistered")
        .withArgs(node1.address, 1, httpEndpoint2, false);

      const info = await bootstrap.getNodeInfo(node1.address);
      expect(info.httpEndpoint).to.equal(httpEndpoint2);
      expect(info.region).to.equal(region2);
    });

    it("Should allow node to update its own endpoints", async function () {
      // Register first
      await bootstrap.connect(node1).registerNode(
        multiaddr1,
        httpEndpoint1,
        wsEndpoint1,
        region1,
        1
      );

      const newMultiaddr = "/ip4/10.0.0.1/tcp/14001/p2p/QmNode1Updated";
      const newHttpEndpoint = "http://10.0.0.1:3001";
      const newWsEndpoint = "ws://10.0.0.1:8101";
      const newRegion = "ap-south-1";

      await bootstrap.connect(node1).updateNode(
        newMultiaddr,
        newHttpEndpoint,
        newWsEndpoint,
        newRegion
      );

      const info = await bootstrap.getNodeInfo(node1.address);
      expect(info.multiaddr).to.equal(newMultiaddr);
      expect(info.httpEndpoint).to.equal(newHttpEndpoint);
      expect(info.wsEndpoint).to.equal(newWsEndpoint);
      expect(info.region).to.equal(newRegion);
    });

    it("Should reject updating inactive node", async function () {
      await expect(
        bootstrap.connect(node1).updateNode(
          multiaddr1,
          httpEndpoint1,
          wsEndpoint1,
          region1
        )
      ).to.be.revertedWithCustomError(bootstrap, "NodeNotActive");
    });

    it("Should allow node to self-deactivate", async function () {
      // Register first
      await bootstrap.connect(node1).registerNode(
        multiaddr1,
        httpEndpoint1,
        wsEndpoint1,
        region1,
        1
      );

      await expect(
        bootstrap.connect(node1).deactivateNode("Maintenance shutdown")
      )
        .to.emit(bootstrap, "NodeDeactivated")
        .withArgs(node1.address, "Maintenance shutdown");

      const info = await bootstrap.getNodeInfo(node1.address);
      expect(info.active).to.be.false;

      // Should not count as active
      const count = await bootstrap.getActiveNodeCount(1);
      expect(count).to.equal(0);
    });

    it("Should reject deactivating already inactive node", async function () {
      await expect(
        bootstrap.connect(node1).deactivateNode("test")
      ).to.be.revertedWithCustomError(bootstrap, "NodeNotActive");
    });
  });

  describe("Admin Functions", function () {
    const multiaddr1 = "/ip4/127.0.0.1/tcp/14001/p2p/QmNode1";
    const httpEndpoint1 = "http://127.0.0.1:3001";
    const wsEndpoint1 = "ws://127.0.0.1:8101";
    const region1 = "us-east-1";

    it("Should allow admin to force-deactivate a node", async function () {
      // Register node first
      await bootstrap.connect(node1).registerNode(
        multiaddr1,
        httpEndpoint1,
        wsEndpoint1,
        region1,
        1
      );

      await expect(
        bootstrap.connect(admin).adminDeactivateNode(node1.address, "Misbehaving node")
      )
        .to.emit(bootstrap, "NodeAdminDeactivated")
        .withArgs(node1.address, admin.address, "Misbehaving node");

      const info = await bootstrap.getNodeInfo(node1.address);
      expect(info.active).to.be.false;
    });

    it("Should prevent non-admin from force-deactivating a node", async function () {
      // Register node first
      await bootstrap.connect(node1).registerNode(
        multiaddr1,
        httpEndpoint1,
        wsEndpoint1,
        region1,
        1
      );

      await expect(
        bootstrap.connect(node2).adminDeactivateNode(node1.address, "Unauthorized")
      ).to.be.revertedWithCustomError(bootstrap, "AccessControlUnauthorizedAccount");
    });

    it("Should reject deactivating already inactive node", async function () {
      await expect(
        bootstrap.connect(admin).adminDeactivateNode(node1.address, "test")
      ).to.be.revertedWithCustomError(bootstrap, "NodeNotActive");
    });
  });

  describe("Query Functions", function () {
    beforeEach(async function () {
      // Register 3 computation nodes
      await bootstrap.connect(node1).registerNode(
        "/ip4/127.0.0.1/tcp/14001/p2p/QmVal1",
        "http://127.0.0.1:3001",
        "ws://127.0.0.1:8101",
        "us-east-1",
        1
      );

      await bootstrap.connect(node2).registerNode(
        "/ip4/127.0.0.1/tcp/14002/p2p/QmVal2",
        "http://127.0.0.1:3002",
        "ws://127.0.0.1:8102",
        "eu-west-1",
        1
      );

      await bootstrap.connect(node3).registerNode(
        "/ip4/127.0.0.1/tcp/14003/p2p/QmVal3",
        "http://127.0.0.1:3003",
        "ws://127.0.0.1:8103",
        "ap-south-1",
        1
      );
    });

    it("Should return correct active node count", async function () {
      const count = await bootstrap.getActiveNodeCount(1); // computation nodes
      expect(count).to.equal(3);
    });

    it("Should return total node count", async function () {
      const count = await bootstrap.getTotalNodeCount();
      expect(count).to.equal(3);
    });

    it("Should return active nodes", async function () {
      const nodes = await bootstrap.getActiveNodes(1, 50); // type 1, limit 50

      expect(nodes.length).to.equal(3);
      expect(nodes[0]).to.equal(node1.address);
      expect(nodes[1]).to.equal(node2.address);
      expect(nodes[2]).to.equal(node3.address);
    });

    it("Should return all active nodes with info", async function () {
      const [addresses, infos] = await bootstrap.getAllActiveNodes(0, 50);

      expect(addresses.length).to.equal(3);
      expect(addresses[0]).to.equal(node1.address);
      expect(addresses[1]).to.equal(node2.address);
      expect(addresses[2]).to.equal(node3.address);

      expect(infos[0].active).to.be.true;
      expect(infos[0].multiaddr).to.equal("/ip4/127.0.0.1/tcp/14001/p2p/QmVal1");
      expect(infos[0].region).to.equal("us-east-1");
    });

    it("Should exclude inactive nodes from active list", async function () {
      // Deactivate node2
      await bootstrap.connect(node2).deactivateNode("Going offline");

      const nodes = await bootstrap.getActiveNodes(1, 50);
      expect(nodes.length).to.equal(2);

      // node2 should not be in the list
      for (const addr of nodes) {
        expect(addr).to.not.equal(node2.address);
      }

      const count = await bootstrap.getActiveNodeCount(1);
      expect(count).to.equal(2);
    });

    it("Should handle empty active list", async function () {
      // Deactivate all nodes
      await bootstrap.connect(node1).deactivateNode("shutdown");
      await bootstrap.connect(node2).deactivateNode("shutdown");
      await bootstrap.connect(node3).deactivateNode("shutdown");

      const count = await bootstrap.getActiveNodeCount(1);
      expect(count).to.equal(0);

      const [addresses, infos] = await bootstrap.getAllActiveNodes(0, 50);
      expect(addresses.length).to.equal(0);
      expect(infos.length).to.equal(0);
    });

    it("Should return node info", async function () {
      const info = await bootstrap.getNodeInfo(node1.address);

      expect(info.active).to.be.true;
      expect(info.nodeType).to.equal(1);
      expect(info.multiaddr).to.equal("/ip4/127.0.0.1/tcp/14001/p2p/QmVal1");
      expect(info.httpEndpoint).to.equal("http://127.0.0.1:3001");
      expect(info.wsEndpoint).to.equal("ws://127.0.0.1:8101");
      expect(info.region).to.equal("us-east-1");
    });

    it("Should check node active status", async function () {
      const [isActive, nodeType] = await bootstrap.isNodeActive(node1.address);
      expect(isActive).to.be.true;
      expect(nodeType).to.equal(1);
    });
  });

  describe("Access Control", function () {
    it("Should prevent non-admin from force-deactivating", async function () {
      // Register node first
      await bootstrap.connect(node1).registerNode(
        "/ip4/127.0.0.1/tcp/14001/p2p/QmVal1",
        "http://127.0.0.1:3001",
        "ws://127.0.0.1:8101",
        "us-east-1",
        1
      );

      await expect(
        bootstrap.connect(node2).adminDeactivateNode(node1.address, "Unauthorized")
      ).to.be.revertedWithCustomError(bootstrap, "AccessControlUnauthorizedAccount");
    });

    it("Should prevent non-admin from updating OmniCore", async function () {
      await expect(
        bootstrap.connect(node1).updateOmniCore(
          FUJI_OMNICORE_ADDRESS, FUJI_CHAIN_ID, FUJI_RPC_URL
        )
      ).to.be.revertedWithCustomError(bootstrap, "AccessControlUnauthorizedAccount");
    });
  });

  describe("Integration Scenarios", function () {
    it("Should handle full lifecycle: register, update, deactivate, re-register", async function () {
      // Register
      await bootstrap.connect(node1).registerNode(
        "/ip4/127.0.0.1/tcp/14001/p2p/QmVal1",
        "http://127.0.0.1:3001",
        "ws://127.0.0.1:8101",
        "us-east-1",
        1
      );

      let count = await bootstrap.getActiveNodeCount(1);
      expect(count).to.equal(1);

      // Update
      await bootstrap.connect(node1).updateNode(
        "/ip4/10.0.0.1/tcp/14001/p2p/QmVal1",
        "http://10.0.0.1:3001",
        "ws://10.0.0.1:8101",
        "ap-south-1"
      );

      const updatedInfo = await bootstrap.getNodeInfo(node1.address);
      expect(updatedInfo.region).to.equal("ap-south-1");

      // Deactivate
      await bootstrap.connect(node1).deactivateNode("Maintenance");
      count = await bootstrap.getActiveNodeCount(1);
      expect(count).to.equal(0);

      // Re-register (comes back online)
      await bootstrap.connect(node1).registerNode(
        "/ip4/127.0.0.1/tcp/14001/p2p/QmVal1",
        "http://127.0.0.1:3001",
        "ws://127.0.0.1:8101",
        "us-east-1",
        1
      );
      count = await bootstrap.getActiveNodeCount(1);
      expect(count).to.equal(1);
    });

    it("Should handle multiple nodes efficiently", async function () {
      // Register multiple nodes
      await bootstrap.connect(node1).registerNode(
        "/ip4/127.0.0.1/tcp/14001/p2p/QmVal1",
        "http://127.0.0.1:3001",
        "ws://127.0.0.1:8101",
        "us-east-1",
        1
      );

      await bootstrap.connect(node2).registerNode(
        "/ip4/127.0.0.1/tcp/14002/p2p/QmVal2",
        "http://127.0.0.1:3002",
        "ws://127.0.0.1:8102",
        "eu-west-1",
        1
      );

      await bootstrap.connect(node3).registerNode(
        "/ip4/127.0.0.1/tcp/14003/p2p/QmVal3",
        "http://127.0.0.1:3003",
        "ws://127.0.0.1:8103",
        "ap-south-1",
        1
      );

      // Query all active
      const nodes = await bootstrap.getActiveNodes(1, 50);
      expect(nodes.length).to.equal(3);

      // Verify order matches registration
      expect(nodes[0]).to.equal(node1.address);
      expect(nodes[1]).to.equal(node2.address);
      expect(nodes[2]).to.equal(node3.address);

      // Get full info
      const [addresses, infos] = await bootstrap.getAllActiveNodes(0, 50);
      expect(infos[0].region).to.equal("us-east-1");
      expect(infos[1].region).to.equal("eu-west-1");
      expect(infos[2].region).to.equal("ap-south-1");
    });

    it("Should handle heartbeat for liveness tracking", async function () {
      await bootstrap.connect(node1).registerNode(
        "/ip4/127.0.0.1/tcp/14001/p2p/QmVal1",
        "http://127.0.0.1:3001",
        "ws://127.0.0.1:8101",
        "us-east-1",
        1
      );

      // Heartbeat should update lastUpdate timestamp
      await bootstrap.connect(node1).heartbeat();

      const info = await bootstrap.getNodeInfo(node1.address);
      expect(info.lastUpdate).to.be.gt(0);
    });
  });
});
