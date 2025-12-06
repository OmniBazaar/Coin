/**
 * Test Bootstrap.sol Node Registration
 *
 * This script tests the self-registration functionality of Bootstrap.sol
 * on Fuji C-Chain.
 */

const { ethers } = require("hardhat");

// Bootstrap contract address on Fuji C-Chain
const BOOTSTRAP_ADDRESS = "0x09F99AE44bd024fD2c16ff6999959d053f0f32B5";

async function main() {
  console.log("Testing Bootstrap.sol Node Registration on Fuji C-Chain...\n");

  // Get the first test account (Validator 1)
  const [validator1] = await ethers.getSigners();
  console.log("Test validator address:", validator1.address);

  const balance = await ethers.provider.getBalance(validator1.address);
  console.log("Validator balance:", ethers.formatEther(balance), "AVAX\n");

  // Connect to Bootstrap contract
  const Bootstrap = await ethers.getContractFactory("Bootstrap");
  const bootstrap = Bootstrap.attach(BOOTSTRAP_ADDRESS);

  console.log("Bootstrap contract:", BOOTSTRAP_ADDRESS);

  // Get OmniCore info - returns (address, uint256, string)
  const [omniCoreAddress, omniCoreChainId, omniCoreRpcUrl] = await bootstrap.getOmniCoreInfo();
  console.log("OmniCore address:", omniCoreAddress);
  console.log("OmniCore chain ID:", omniCoreChainId.toString());
  console.log("OmniCore RPC URL:", omniCoreRpcUrl);
  console.log("");

  // Check current registered nodes
  console.log("=== Current Registered Nodes ===");
  const nodeCount = await bootstrap.getTotalNodeCount();
  console.log("Total registered nodes:", nodeCount.toString());

  // Get active gateway nodes (type 0, limit 100)
  try {
    const activeGateways = await bootstrap.getActiveNodes(0, 100); // 0 = Gateway, limit 100
    console.log("Active gateway nodes:", activeGateways.length);

    for (let i = 0; i < activeGateways.length; i++) {
      // getNodeInfo returns: (multiaddr, httpEndpoint, wsEndpoint, region, nodeType, active, lastUpdate)
      const [multiaddr, httpEndpoint, wsEndpoint, region, nodeType, active, lastUpdate] =
        await bootstrap.getNodeInfo(activeGateways[i]);
      console.log(`\nGateway ${i + 1}:`);
      console.log("  Address:", activeGateways[i]);
      console.log("  HTTP Endpoint:", httpEndpoint);
      console.log("  WS Endpoint:", wsEndpoint);
      console.log("  Multiaddr:", multiaddr);
      console.log("  Region:", region);
      console.log("  Is Active:", active);
    }
  } catch (e) {
    console.log("No active gateway nodes yet");
  }
  console.log("");

  // Test registration
  console.log("=== Testing Node Registration ===");

  // Check if this validator is already registered
  // getNodeInfo returns: (multiaddr, httpEndpoint, wsEndpoint, region, nodeType, active, lastUpdate)
  const [existingMultiaddr, existingHttp, existingWs, existingRegion, existingType, isActive, lastUpdate] =
    await bootstrap.getNodeInfo(validator1.address);

  if (isActive) {
    console.log("This validator is already registered. Updating...");

    // Update existing registration
    // updateNode(multiaddr, httpEndpoint, wsEndpoint, region)
    const updateTx = await bootstrap.updateNode(
      "/ip4/127.0.0.1/tcp/14001/p2p/QmTest123",  // multiaddr
      "https://validator1.test.omnibazaar.com",   // HTTP
      "wss://validator1.test.omnibazaar.com",     // WS
      "us-west"                                    // region
    );
    console.log("Update transaction:", updateTx.hash);
    await updateTx.wait();
    console.log("Registration updated!\n");
  } else {
    console.log("Registering new node...");

    // Register new node
    // registerNode(multiaddr, httpEndpoint, wsEndpoint, region, nodeType)
    const registerTx = await bootstrap.registerNode(
      "/ip4/127.0.0.1/tcp/14001/p2p/QmTest123",  // multiaddr
      "https://validator1.test.omnibazaar.com",   // HTTP
      "wss://validator1.test.omnibazaar.com",     // WS
      "us-west",                                   // region
      0                                            // nodeType: 0 = Gateway
    );
    console.log("Registration transaction:", registerTx.hash);
    const receipt = await registerTx.wait();
    console.log("Node registered! Gas used:", receipt.gasUsed.toString());
    console.log("");
  }

  // Verify registration status immediately after registering
  console.log("=== Verify Registration Status ===");
  const [postMulti, postHttp, postWs, postRegion, postType, postActive, postLastUpdate] =
    await bootstrap.getNodeInfo(validator1.address);
  console.log("Node is active:", postActive);
  console.log("Node type:", postType);
  console.log("Last update:", new Date(Number(postLastUpdate) * 1000).toISOString());
  console.log("");

  if (!postActive) {
    console.log("ERROR: Node registration did not activate the node!");
    console.log("Skipping heartbeat test...");
    process.exit(1);
  }

  // Send heartbeat
  console.log("=== Sending Heartbeat ===");
  const heartbeatTx = await bootstrap.heartbeat();
  console.log("Heartbeat transaction:", heartbeatTx.hash);
  await heartbeatTx.wait();
  console.log("Heartbeat sent!\n");

  // Verify registration
  console.log("=== Verifying Registration ===");
  const newNodeCount = await bootstrap.getTotalNodeCount();
  console.log("Total registered nodes:", newNodeCount.toString());

  // getNodeInfo returns: (multiaddr, httpEndpoint, wsEndpoint, region, nodeType, active, lastUpdate)
  const [multiaddr, httpEndpoint, wsEndpoint, region, nodeType, active, nodeLastUpdate] =
    await bootstrap.getNodeInfo(validator1.address);
  console.log("\nRegistered node info:");
  console.log("  HTTP Endpoint:", httpEndpoint);
  console.log("  WS Endpoint:", wsEndpoint);
  console.log("  Multiaddr:", multiaddr);
  console.log("  Region:", region);
  console.log("  Node Type:", nodeType, "(0=Gateway, 1=Computation, 2=Listing)");
  console.log("  Is Active:", active);
  console.log("  Last Update:", new Date(Number(nodeLastUpdate) * 1000).toISOString());

  // Test isNodeActive
  const [nodeIsActive, nodeActiveType] = await bootstrap.isNodeActive(validator1.address);
  console.log("\nNode status check:");
  console.log("  Is Active:", nodeIsActive);
  console.log("  Node Type:", nodeActiveType);

  console.log("\n Bootstrap registration test complete!");
  console.log("\nValidators can now use Bootstrap.sol for discovery.");
  console.log("Each validator should call registerNode() on startup.");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
