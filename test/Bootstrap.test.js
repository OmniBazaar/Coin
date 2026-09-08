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

    // BOOTSTRAP_ADMIN_ROLE was merged into DEFAULT_ADMIN_ROLE (bytes32(0))
    // Grant DEFAULT_ADMIN_ROLE to admin account
    await bootstrap.grantRole(ethers.ZeroHash, admin.address);
  });

  describe("Initialization", function () {
    it("Should initialize with correct OmniCore reference", async function () {
      expect(await bootstrap.omniCoreAddress()).to.equal(FUJI_OMNICORE_ADDRESS);
      expect(await bootstrap.omniCoreChainId()).to.equal(FUJI_CHAIN_ID);
      expect(await bootstrap.omniCoreRpcUrl()).to.equal(FUJI_RPC_URL);
    });

    it("Should grant DEFAULT_ADMIN_ROLE to deployer", async function () {
      // BOOTSTRAP_ADMIN_ROLE was merged into DEFAULT_ADMIN_ROLE (bytes32(0))
      const DEFAULT_ADMIN_ROLE = ethers.ZeroHash;

      expect(await bootstrap.hasRole(DEFAULT_ADMIN_ROLE, owner.address)).to.be.true;
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

  // =====================================================================
  //  NEW TESTS - Phase Transitions (Node Type Changes)
  // =====================================================================
  describe("Phase Transitions (Node Type Changes)", function () {
    const multiaddr = "/ip4/127.0.0.1/tcp/14001/p2p/QmNode1";
    const httpEndpoint = "http://127.0.0.1:3001";
    const wsEndpoint = "ws://127.0.0.1:8101";
    const region = "us-east-1";

    it("Should update active counts when node changes type via re-registration", async function () {
      // Register as computation node (type 1)
      await bootstrap.connect(node1).registerNode(
        multiaddr, httpEndpoint, wsEndpoint, region, 1
      );
      expect(await bootstrap.getActiveNodeCount(1)).to.equal(1);
      expect(await bootstrap.getActiveNodeCount(2)).to.equal(0);

      // Re-register as listing node (type 2)
      await bootstrap.connect(node1).registerNode(
        multiaddr, httpEndpoint, wsEndpoint, region, 2
      );
      expect(await bootstrap.getActiveNodeCount(1)).to.equal(0);
      expect(await bootstrap.getActiveNodeCount(2)).to.equal(1);
    });

    it("Should handle deactivation then re-registration with different type", async function () {
      // Register as computation (1)
      await bootstrap.connect(node1).registerNode(
        multiaddr, httpEndpoint, wsEndpoint, region, 1
      );
      expect(await bootstrap.getActiveNodeCount(1)).to.equal(1);

      // Deactivate
      await bootstrap.connect(node1).deactivateNode("switching");
      expect(await bootstrap.getActiveNodeCount(1)).to.equal(0);

      // Re-register as listing (2)
      await bootstrap.connect(node1).registerNode(
        multiaddr, httpEndpoint, wsEndpoint, region, 2
      );
      expect(await bootstrap.getActiveNodeCount(1)).to.equal(0);
      expect(await bootstrap.getActiveNodeCount(2)).to.equal(1);
    });

    it("Should not double-increment count on re-registration with same type", async function () {
      await bootstrap.connect(node1).registerNode(
        multiaddr, httpEndpoint, wsEndpoint, region, 1
      );
      expect(await bootstrap.getActiveNodeCount(1)).to.equal(1);

      // Re-register same type
      await bootstrap.connect(node1).registerNode(
        multiaddr, "http://updated:3001", wsEndpoint, region, 1
      );
      // Count should still be 1 (not incremented again)
      expect(await bootstrap.getActiveNodeCount(1)).to.equal(1);
    });
  });

  // =====================================================================
  //  NEW TESTS - Threshold Validation (String Length Limits)
  // =====================================================================
  describe("Threshold Validation (String Length Limits)", function () {
    it("Should reject multiaddr longer than 256 bytes", async function () {
      const longMultiaddr = "x".repeat(257);

      await expect(
        bootstrap.connect(node1).registerNode(
          longMultiaddr,
          "http://127.0.0.1:3001",
          "ws://127.0.0.1:8101",
          "us-east-1",
          1
        )
      ).to.be.revertedWithCustomError(bootstrap, "StringTooLong");
    });

    it("Should reject httpEndpoint longer than 256 bytes", async function () {
      const longEndpoint = "http://" + "x".repeat(250);

      await expect(
        bootstrap.connect(node1).registerNode(
          "/ip4/127.0.0.1/tcp/14001",
          longEndpoint,
          "",
          "us-east-1",
          1
        )
      ).to.be.revertedWithCustomError(bootstrap, "StringTooLong");
    });

    it("Should reject region longer than 64 bytes", async function () {
      const longRegion = "x".repeat(65);

      await expect(
        bootstrap.connect(node1).registerNode(
          "/ip4/127.0.0.1/tcp/14001",
          "http://127.0.0.1:3001",
          "",
          longRegion,
          1
        )
      ).to.be.revertedWithCustomError(bootstrap, "StringTooLong");
    });

    it("Should accept strings at exact limits (256, 256, 256, 64)", async function () {
      const maxMultiaddr = "x".repeat(256);
      const maxHttp = "x".repeat(256);
      const maxWs = "x".repeat(256);
      const maxRegion = "x".repeat(64);

      await expect(
        bootstrap.connect(node1).registerNode(
          maxMultiaddr, maxHttp, maxWs, maxRegion, 1
        )
      ).to.not.be.reverted;
    });

    it("Should reject updateNode with strings exceeding limits", async function () {
      // Register first
      await bootstrap.connect(node1).registerNode(
        "/ip4/127.0.0.1/tcp/14001",
        "http://127.0.0.1:3001",
        "ws://127.0.0.1:8101",
        "us-east-1",
        1
      );

      const longMultiaddr = "x".repeat(257);
      await expect(
        bootstrap.connect(node1).updateNode(
          longMultiaddr, "http://127.0.0.1:3001", "", "us-east-1"
        )
      ).to.be.revertedWithCustomError(bootstrap, "StringTooLong");
    });

    it("Should reject wsEndpoint longer than 256 bytes on updateNode", async function () {
      await bootstrap.connect(node1).registerNode(
        "/ip4/127.0.0.1/tcp/14001",
        "http://127.0.0.1:3001",
        "ws://127.0.0.1:8101",
        "us-east-1",
        1
      );

      const longWs = "x".repeat(257);
      await expect(
        bootstrap.connect(node1).updateNode(
          "/ip4/127.0.0.1/tcp/14001", "http://127.0.0.1:3001", longWs, "us-east-1"
        )
      ).to.be.revertedWithCustomError(bootstrap, "StringTooLong");
    });

    it("Should reject region longer than 64 bytes on updateNode", async function () {
      await bootstrap.connect(node1).registerNode(
        "/ip4/127.0.0.1/tcp/14001",
        "http://127.0.0.1:3001",
        "ws://127.0.0.1:8101",
        "us-east-1",
        1
      );

      const longRegion = "x".repeat(65);
      await expect(
        bootstrap.connect(node1).updateNode(
          "/ip4/127.0.0.1/tcp/14001", "http://127.0.0.1:3001", "", longRegion
        )
      ).to.be.revertedWithCustomError(bootstrap, "StringTooLong");
    });
  });

  // =====================================================================
  //  NEW TESTS - Validator Registration Edge Cases
  // =====================================================================
  describe("Validator Registration Edge Cases", function () {
    it("Should reject invalid node type (3 or higher)", async function () {
      await expect(
        bootstrap.connect(node1).registerNode(
          "/ip4/127.0.0.1/tcp/14001",
          "http://127.0.0.1:3001",
          "",
          "us-east-1",
          3
        )
      ).to.be.revertedWithCustomError(bootstrap, "InvalidNodeType");
    });

    it("Should register listing node (type 2)", async function () {
      await bootstrap.connect(node1).registerNode(
        "/ip4/127.0.0.1/tcp/14001",
        "http://127.0.0.1:3001",
        "",
        "us-east-1",
        2
      );

      expect(await bootstrap.getActiveNodeCount(2)).to.equal(1);
      const info = await bootstrap.getNodeInfo(node1.address);
      expect(info.nodeType).to.equal(2);
    });

    it("Should reject gateway registration without publicIp", async function () {
      await expect(
        bootstrap.connect(node1).registerGatewayNode(
          "/ip4/127.0.0.1/tcp/14001",
          "http://127.0.0.1:3001",
          "ws://127.0.0.1:8101",
          "us-east-1",
          "http://127.0.0.1:40681/ext/bc/L1/rpc",
          35579,
          "",  // empty publicIp
          "NodeID-test"
        )
      ).to.be.revertedWithCustomError(bootstrap, "InvalidParameter");
    });

    it("Should reject gateway registration without nodeId", async function () {
      await expect(
        bootstrap.connect(node1).registerGatewayNode(
          "/ip4/127.0.0.1/tcp/14001",
          "http://127.0.0.1:3001",
          "ws://127.0.0.1:8101",
          "us-east-1",
          "http://127.0.0.1:40681/ext/bc/L1/rpc",
          35579,
          "203.0.113.1",
          ""  // empty nodeId
        )
      ).to.be.revertedWithCustomError(bootstrap, "InvalidParameter");
    });

    it("Should reject gateway registration with zero stakingPort", async function () {
      await expect(
        bootstrap.connect(node1).registerGatewayNode(
          "/ip4/127.0.0.1/tcp/14001",
          "http://127.0.0.1:3001",
          "ws://127.0.0.1:8101",
          "us-east-1",
          "http://127.0.0.1:40681/ext/bc/L1/rpc",
          0,  // zero port
          "203.0.113.1",
          "NodeID-test"
        )
      ).to.be.revertedWithCustomError(bootstrap, "InvalidParameter");
    });

    it("Should reject gateway registration without multiaddr", async function () {
      await expect(
        bootstrap.connect(node1).registerGatewayNode(
          "",  // empty multiaddr
          "http://127.0.0.1:3001",
          "ws://127.0.0.1:8101",
          "us-east-1",
          "http://127.0.0.1:40681/ext/bc/L1/rpc",
          35579,
          "203.0.113.1",
          "NodeID-test"
        )
      ).to.be.revertedWithCustomError(bootstrap, "InvalidParameter");
    });

    it("Should reject publicIp containing forbidden characters (comma)", async function () {
      await expect(
        bootstrap.connect(node1).registerGatewayNode(
          "/ip4/127.0.0.1/tcp/14001",
          "http://127.0.0.1:3001",
          "",
          "us-east-1",
          "http://127.0.0.1:40681/ext/bc/L1/rpc",
          35579,
          "203.0.113.1,evil",  // comma injection
          "NodeID-test"
        )
      ).to.be.revertedWithCustomError(bootstrap, "ForbiddenCharacter");
    });

    it("Should reject publicIp containing forbidden characters (colon)", async function () {
      await expect(
        bootstrap.connect(node1).registerGatewayNode(
          "/ip4/127.0.0.1/tcp/14001",
          "http://127.0.0.1:3001",
          "",
          "us-east-1",
          "http://127.0.0.1:40681/ext/bc/L1/rpc",
          35579,
          "203.0.113.1:9999",  // colon injection
          "NodeID-test"
        )
      ).to.be.revertedWithCustomError(bootstrap, "ForbiddenCharacter");
    });

    it("Should reject nodeId containing forbidden characters", async function () {
      await expect(
        bootstrap.connect(node1).registerGatewayNode(
          "/ip4/127.0.0.1/tcp/14001",
          "http://127.0.0.1:3001",
          "",
          "us-east-1",
          "http://127.0.0.1:40681/ext/bc/L1/rpc",
          35579,
          "203.0.113.1",
          "NodeID-test,injected"  // comma injection
        )
      ).to.be.revertedWithCustomError(bootstrap, "ForbiddenCharacter");
    });

    it("Should reject heartbeat from inactive node", async function () {
      await expect(
        bootstrap.connect(node1).heartbeat()
      ).to.be.revertedWithCustomError(bootstrap, "NodeNotActive");
    });
  });

  // =====================================================================
  //  NEW TESTS - Discovery Functions
  // =====================================================================
  describe("Discovery Functions", function () {
    it("Should return active gateway validators", async function () {
      // Register 2 gateway nodes
      await bootstrap.connect(node1).registerGatewayNode(
        "/ip4/127.0.0.1/tcp/14001/p2p/Qm1",
        "http://127.0.0.1:3001",
        "ws://127.0.0.1:8101",
        "us-east-1",
        "http://127.0.0.1:40681/ext/bc/L1/rpc",
        35579,
        "203.0.113.1",
        "NodeID-gw1"
      );
      await bootstrap.connect(node2).registerGatewayNode(
        "/ip4/127.0.0.1/tcp/14002/p2p/Qm2",
        "http://127.0.0.1:3002",
        "ws://127.0.0.1:8102",
        "eu-west-1",
        "http://127.0.0.2:40681/ext/bc/L1/rpc",
        35579,
        "203.0.113.2",
        "NodeID-gw2"
      );

      const infos = await bootstrap.getActiveGatewayValidators(10);
      expect(infos.length).to.equal(2);
      expect(infos[0].nodeType).to.equal(0);
      expect(infos[1].nodeType).to.equal(0);
    });

    it("Should return empty for getActiveGatewayValidators when none exist", async function () {
      // Register only computation nodes, no gateways
      await bootstrap.connect(node1).registerNode(
        "/ip4/127.0.0.1/tcp/14001",
        "http://127.0.0.1:3001",
        "",
        "us-east-1",
        1
      );

      const infos = await bootstrap.getActiveGatewayValidators(10);
      expect(infos.length).to.equal(0);
    });

    it("Should return avalanche bootstrap peers in correct format", async function () {
      await bootstrap.connect(node1).registerGatewayNode(
        "/ip4/127.0.0.1/tcp/14001/p2p/Qm1",
        "http://127.0.0.1:3001",
        "ws://127.0.0.1:8101",
        "us-east-1",
        "http://127.0.0.1:40681/ext/bc/L1/rpc",
        35579,
        "203.0.113.1",
        "NodeID-gw1"
      );

      const [ips, ids, count] = await bootstrap.getAvalancheBootstrapPeers(10);
      expect(count).to.equal(1);
      expect(ips).to.equal("203.0.113.1:35579");
      expect(ids).to.equal("NodeID-gw1");
    });

    it("Should return comma-separated peers for multiple gateways", async function () {
      await bootstrap.connect(node1).registerGatewayNode(
        "/ip4/127.0.0.1/tcp/14001/p2p/Qm1",
        "http://127.0.0.1:3001",
        "",
        "us-east-1",
        "http://127.0.0.1:40681/ext/bc/L1/rpc",
        35579,
        "203.0.113.1",
        "NodeID-gw1"
      );
      await bootstrap.connect(node2).registerGatewayNode(
        "/ip4/127.0.0.1/tcp/14002/p2p/Qm2",
        "http://127.0.0.1:3002",
        "",
        "eu-west-1",
        "http://127.0.0.2:40681/ext/bc/L1/rpc",
        35580,
        "203.0.113.2",
        "NodeID-gw2"
      );

      const [ips, ids, count] = await bootstrap.getAvalancheBootstrapPeers(10);
      expect(count).to.equal(2);
      expect(ips).to.equal("203.0.113.1:35579,203.0.113.2:35580");
      expect(ids).to.equal("NodeID-gw1,NodeID-gw2");
    });

    it("Should return empty strings for bootstrap peers when none exist", async function () {
      const [ips, ids, count] = await bootstrap.getAvalancheBootstrapPeers(10);
      expect(count).to.equal(0);
      expect(ips).to.equal("");
      expect(ids).to.equal("");
    });

    it("Should return extended node info", async function () {
      await bootstrap.connect(node1).registerGatewayNode(
        "/ip4/127.0.0.1/tcp/14001/p2p/Qm1",
        "http://127.0.0.1:3001",
        "ws://127.0.0.1:8101",
        "us-east-1",
        "http://127.0.0.1:40681/ext/bc/L1/rpc",
        35579,
        "203.0.113.1",
        "NodeID-gw1"
      );

      const info = await bootstrap.getNodeInfoExtended(node1.address);
      expect(info.active).to.be.true;
      expect(info.nodeType).to.equal(0);
      expect(info.stakingPort).to.equal(35579);
      expect(info.publicIp).to.equal("203.0.113.1");
      expect(info.nodeId).to.equal("NodeID-gw1");
      expect(info.avalancheRpcEndpoint).to.equal("http://127.0.0.1:40681/ext/bc/L1/rpc");
    });

    it("Should respect limit parameter on getActiveNodes", async function () {
      await bootstrap.connect(node1).registerNode(
        "/ip4/127.0.0.1/tcp/14001", "http://127.0.0.1:3001", "", "us-east-1", 1
      );
      await bootstrap.connect(node2).registerNode(
        "/ip4/127.0.0.1/tcp/14002", "http://127.0.0.1:3002", "", "eu-west-1", 1
      );
      await bootstrap.connect(node3).registerNode(
        "/ip4/127.0.0.1/tcp/14003", "http://127.0.0.1:3003", "", "ap-south-1", 1
      );

      const nodes = await bootstrap.getActiveNodes(1, 2); // limit to 2
      expect(nodes.length).to.equal(2);
    });

    it("Should reject getActiveNodes with invalid nodeType", async function () {
      await expect(
        bootstrap.getActiveNodes(3, 50)
      ).to.be.revertedWithCustomError(bootstrap, "InvalidNodeType");
    });

    it("Should reject getActiveNodeCount with invalid nodeType", async function () {
      await expect(
        bootstrap.getActiveNodeCount(3)
      ).to.be.revertedWithCustomError(bootstrap, "InvalidNodeType");
    });

    it("Should handle pagination in getAllActiveNodes", async function () {
      await bootstrap.connect(node1).registerNode(
        "/ip4/127.0.0.1/tcp/14001", "http://127.0.0.1:3001", "", "us-east-1", 1
      );
      await bootstrap.connect(node2).registerNode(
        "/ip4/127.0.0.1/tcp/14002", "http://127.0.0.1:3002", "", "eu-west-1", 1
      );
      await bootstrap.connect(node3).registerNode(
        "/ip4/127.0.0.1/tcp/14003", "http://127.0.0.1:3003", "", "ap-south-1", 1
      );

      // First page
      const [addrs1, infos1] = await bootstrap.getAllActiveNodes(0, 2);
      expect(addrs1.length).to.equal(2);
      expect(addrs1[0]).to.equal(node1.address);
      expect(addrs1[1]).to.equal(node2.address);

      // Second page
      const [addrs2, infos2] = await bootstrap.getAllActiveNodes(2, 2);
      expect(addrs2.length).to.equal(1);
      expect(addrs2[0]).to.equal(node3.address);
    });

    it("Should return empty arrays when offset is beyond registeredNodes length", async function () {
      await bootstrap.connect(node1).registerNode(
        "/ip4/127.0.0.1/tcp/14001", "http://127.0.0.1:3001", "", "us-east-1", 1
      );

      const [addrs, infos] = await bootstrap.getAllActiveNodes(100, 50);
      expect(addrs.length).to.equal(0);
      expect(infos.length).to.equal(0);
    });

    it("Should handle getActiveNodesWithinTime query", async function () {
      await bootstrap.connect(node1).registerNode(
        "/ip4/127.0.0.1/tcp/14001", "http://127.0.0.1:3001", "", "us-east-1", 1
      );

      // Query with a large time window should find the node
      const nodes = await bootstrap.getActiveNodesWithinTime(1, 3600, 50);
      expect(nodes.length).to.equal(1);
      expect(nodes[0]).to.equal(node1.address);
    });

    it("Should reject getActiveNodesWithinTime with invalid nodeType", async function () {
      await expect(
        bootstrap.getActiveNodesWithinTime(5, 3600, 50)
      ).to.be.revertedWithCustomError(bootstrap, "InvalidNodeType");
    });
  });

  // =====================================================================
  //  NEW TESTS - Access Control Extended
  // =====================================================================
  describe("Access Control - Extended", function () {
    it("Should allow DEFAULT_ADMIN to grant DEFAULT_ADMIN_ROLE to others", async function () {
      // BOOTSTRAP_ADMIN_ROLE was merged into DEFAULT_ADMIN_ROLE (bytes32(0))
      await bootstrap.grantRole(ethers.ZeroHash, node1.address);
      expect(await bootstrap.hasRole(ethers.ZeroHash, node1.address)).to.be.true;
    });

    it("Should allow DEFAULT_ADMIN to revoke DEFAULT_ADMIN_ROLE from others", async function () {
      // BOOTSTRAP_ADMIN_ROLE was merged into DEFAULT_ADMIN_ROLE (bytes32(0))
      await bootstrap.revokeRole(ethers.ZeroHash, admin.address);
      expect(await bootstrap.hasRole(ethers.ZeroHash, admin.address)).to.be.false;
    });

    it("Should prevent non-admin from granting roles", async function () {
      // BOOTSTRAP_ADMIN_ROLE was merged into DEFAULT_ADMIN_ROLE (bytes32(0))
      await expect(
        bootstrap.connect(node1).grantRole(ethers.ZeroHash, node2.address)
      ).to.be.revertedWithCustomError(bootstrap, "AccessControlUnauthorizedAccount");
    });

    it("Should allow role renunciation", async function () {
      // BOOTSTRAP_ADMIN_ROLE was merged into DEFAULT_ADMIN_ROLE (bytes32(0))
      await bootstrap.connect(admin).renounceRole(ethers.ZeroHash, admin.address);
      expect(await bootstrap.hasRole(ethers.ZeroHash, admin.address)).to.be.false;
    });

    it("Should prevent non-admin from calling adminUnbanNode", async function () {
      await expect(
        bootstrap.connect(node1).adminUnbanNode(node2.address)
      ).to.be.revertedWithCustomError(bootstrap, "AccessControlUnauthorizedAccount");
    });
  });

  // =====================================================================
  //  NEW TESTS - Events Extended
  // =====================================================================
  describe("Events - Extended", function () {
    it("Should emit OmniCoreUpdated on construction", async function () {
      const Bootstrap = await ethers.getContractFactory("Bootstrap");
      const newBootstrap = await Bootstrap.deploy(FUJI_OMNICORE_ADDRESS, FUJI_CHAIN_ID, FUJI_RPC_URL);
      await newBootstrap.waitForDeployment();

      // Verify the constructor emitted OmniCoreUpdated by checking deployment tx receipt
      const deployTx = newBootstrap.deploymentTransaction();
      const receipt = await deployTx.wait();
      const iface = newBootstrap.interface;
      const eventTopic = iface.getEvent("OmniCoreUpdated").topicHash;
      const matchingLog = receipt.logs.find((log) => log.topics[0] === eventTopic);
      expect(matchingLog).to.not.be.undefined;
    });

    it("Should emit NodeRegistered with isNew=true for first registration", async function () {
      await expect(
        bootstrap.connect(node1).registerNode(
          "/ip4/127.0.0.1/tcp/14001",
          "http://127.0.0.1:3001",
          "",
          "us-east-1",
          1
        )
      ).to.emit(bootstrap, "NodeRegistered")
        .withArgs(node1.address, 1, "http://127.0.0.1:3001", true);
    });

    it("Should emit NodeRegistered with isNew=false for re-registration", async function () {
      await bootstrap.connect(node1).registerNode(
        "/ip4/127.0.0.1/tcp/14001",
        "http://127.0.0.1:3001",
        "",
        "us-east-1",
        1
      );

      await expect(
        bootstrap.connect(node1).registerNode(
          "/ip4/127.0.0.1/tcp/14001",
          "http://updated:3001",
          "",
          "us-east-1",
          1
        )
      ).to.emit(bootstrap, "NodeRegistered")
        .withArgs(node1.address, 1, "http://updated:3001", false);
    });

    it("Should emit NodeRegistered on updateNode", async function () {
      await bootstrap.connect(node1).registerNode(
        "/ip4/127.0.0.1/tcp/14001",
        "http://127.0.0.1:3001",
        "",
        "us-east-1",
        1
      );

      await expect(
        bootstrap.connect(node1).updateNode(
          "/ip4/10.0.0.1/tcp/14001",
          "http://10.0.0.1:3001",
          "",
          "ap-south-1"
        )
      ).to.emit(bootstrap, "NodeRegistered")
        .withArgs(node1.address, 1, "http://10.0.0.1:3001", false);
    });

    it("Should emit NodeDeactivated on self-deactivation", async function () {
      await bootstrap.connect(node1).registerNode(
        "/ip4/127.0.0.1/tcp/14001",
        "http://127.0.0.1:3001",
        "",
        "us-east-1",
        1
      );

      await expect(
        bootstrap.connect(node1).deactivateNode("Going offline")
      ).to.emit(bootstrap, "NodeDeactivated")
        .withArgs(node1.address, "Going offline");
    });

    it("Should emit NodeAdminDeactivated on admin deactivation", async function () {
      await bootstrap.connect(node1).registerNode(
        "/ip4/127.0.0.1/tcp/14001",
        "http://127.0.0.1:3001",
        "",
        "us-east-1",
        1
      );

      await expect(
        bootstrap.connect(admin).adminDeactivateNode(node1.address, "Violation")
      ).to.emit(bootstrap, "NodeAdminDeactivated")
        .withArgs(node1.address, admin.address, "Violation");
    });

    it("Should emit NodeUnbanned on unban", async function () {
      // First ban (via admin deactivate)
      await bootstrap.connect(node1).registerNode(
        "/ip4/127.0.0.1/tcp/14001",
        "http://127.0.0.1:3001",
        "",
        "us-east-1",
        1
      );
      await bootstrap.connect(admin).adminDeactivateNode(node1.address, "Ban");
      expect(await bootstrap.banned(node1.address)).to.be.true;

      // Unban
      await expect(
        bootstrap.connect(admin).adminUnbanNode(node1.address)
      ).to.emit(bootstrap, "NodeUnbanned")
        .withArgs(node1.address, admin.address);
    });
  });

  // =====================================================================
  //  NEW TESTS - Ban/Unban Functionality
  // =====================================================================
  describe("Ban and Unban Functionality", function () {
    it("Should ban node on admin deactivation", async function () {
      await bootstrap.connect(node1).registerNode(
        "/ip4/127.0.0.1/tcp/14001",
        "http://127.0.0.1:3001",
        "",
        "us-east-1",
        1
      );

      await bootstrap.connect(admin).adminDeactivateNode(node1.address, "Misbehaving");

      expect(await bootstrap.banned(node1.address)).to.be.true;
    });

    it("Should prevent banned node from re-registering", async function () {
      await bootstrap.connect(node1).registerNode(
        "/ip4/127.0.0.1/tcp/14001",
        "http://127.0.0.1:3001",
        "",
        "us-east-1",
        1
      );
      await bootstrap.connect(admin).adminDeactivateNode(node1.address, "Ban");

      await expect(
        bootstrap.connect(node1).registerNode(
          "/ip4/127.0.0.1/tcp/14001",
          "http://127.0.0.1:3001",
          "",
          "us-east-1",
          1
        )
      ).to.be.revertedWithCustomError(bootstrap, "NodeBanned");
    });

    it("Should allow unbanned node to re-register", async function () {
      await bootstrap.connect(node1).registerNode(
        "/ip4/127.0.0.1/tcp/14001",
        "http://127.0.0.1:3001",
        "",
        "us-east-1",
        1
      );
      await bootstrap.connect(admin).adminDeactivateNode(node1.address, "Ban");
      expect(await bootstrap.banned(node1.address)).to.be.true;

      // Unban
      await bootstrap.connect(admin).adminUnbanNode(node1.address);
      expect(await bootstrap.banned(node1.address)).to.be.false;

      // Should be able to re-register
      await bootstrap.connect(node1).registerNode(
        "/ip4/127.0.0.1/tcp/14001",
        "http://127.0.0.1:3001",
        "",
        "us-east-1",
        1
      );
      const info = await bootstrap.getNodeInfo(node1.address);
      expect(info.active).to.be.true;
    });

    it("Should reject adminUnbanNode with zero address", async function () {
      await expect(
        bootstrap.connect(admin).adminUnbanNode(ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(bootstrap, "InvalidAddress");
    });

    it("Self-deactivation should NOT ban the node", async function () {
      await bootstrap.connect(node1).registerNode(
        "/ip4/127.0.0.1/tcp/14001",
        "http://127.0.0.1:3001",
        "",
        "us-east-1",
        1
      );
      await bootstrap.connect(node1).deactivateNode("Maintenance");

      // Should not be banned
      expect(await bootstrap.banned(node1.address)).to.be.false;

      // Should be able to re-register
      await bootstrap.connect(node1).registerNode(
        "/ip4/127.0.0.1/tcp/14001",
        "http://127.0.0.1:3001",
        "",
        "us-east-1",
        1
      );
      const info = await bootstrap.getNodeInfo(node1.address);
      expect(info.active).to.be.true;
    });
  });

  // =====================================================================
  //  NEW TESTS - Constants
  // =====================================================================
  describe("Constants", function () {
    it("Should have MAX_NODES of 1000", async function () {
      expect(await bootstrap.MAX_NODES()).to.equal(1000);
    });

    it("Should have MIN_TIME_WINDOW of 60 seconds", async function () {
      expect(await bootstrap.MIN_TIME_WINDOW()).to.equal(60);
    });

    it("Should have MAX_TIME_WINDOW of 30 days", async function () {
      expect(await bootstrap.MAX_TIME_WINDOW()).to.equal(30 * 24 * 60 * 60);
    });

    it("Should have DEFAULT_ADMIN_ROLE as bytes32(0)", async function () {
      // BOOTSTRAP_ADMIN_ROLE was merged into DEFAULT_ADMIN_ROLE (bytes32(0))
      expect(await bootstrap.DEFAULT_ADMIN_ROLE()).to.equal(ethers.ZeroHash);
    });
  });
});
