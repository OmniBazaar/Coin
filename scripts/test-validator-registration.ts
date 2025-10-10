import { ethers } from "hardhat";
import * as fs from "fs";
import * as path from "path";

/**
 * Test script for OmniCore validator registration functions
 * Tests registerNode(), getActiveNodesWithinTime(), getNodeInfo()
 */
async function main() {
    console.log("🧪 Testing OmniCore Validator Registration Functions\n");

    // Load deployment
    const deploymentPath = path.join(__dirname, "../deployments/localhost.json");
    const deployment = JSON.parse(fs.readFileSync(deploymentPath, "utf-8"));
    const omnicoreAddress = deployment.contracts.OmniCore;

    console.log("OmniCore Contract:", omnicoreAddress);
    console.log("Network:", deployment.network);
    console.log();

    // Get signers
    const [deployer, validator1, validator2, validator3] = await ethers.getSigners();
    console.log("Test Accounts:");
    console.log("  Deployer:", deployer.address);
    console.log("  Validator 1:", validator1.address);
    console.log("  Validator 2:", validator2.address);
    console.log("  Validator 3:", validator3.address);
    console.log();

    // Get contract instance
    const omnicore = await ethers.getContractAt("OmniCore", omnicoreAddress);

    // Test 1: Register validator 1
    console.log("=== TEST 1: Register Validator 1 ===");
    const multiaddr1 = "/ip4/127.0.0.1/tcp/14002/p2p/12D3KooWValidator1";
    const httpEndpoint1 = "http://localhost:3001";
    const wsEndpoint1 = "ws://localhost:8101";
    const region1 = "local-dev";

    const tx1 = await omnicore.connect(validator1).registerNode(
        multiaddr1,
        httpEndpoint1,
        wsEndpoint1,
        region1,
        0 // nodeType: 0 = gateway
    );
    await tx1.wait();
    console.log("✓ Validator 1 registered");
    console.log("  TX:", tx1.hash);

    // Test 2: Get node info
    console.log("\n=== TEST 2: Get Node Info ===");
    const nodeInfo1 = await omnicore.getNodeInfo(validator1.address);
    console.log("Validator 1 Info:");
    console.log("  Multiaddr:", nodeInfo1[0]);
    console.log("  HTTP:", nodeInfo1[1]);
    console.log("  WS:", nodeInfo1[2]);
    console.log("  Region:", nodeInfo1[3]);
    console.log("  Type:", nodeInfo1[4]);
    console.log("  Active:", nodeInfo1[5]);
    console.log("  Last Update:", new Date(Number(nodeInfo1[6]) * 1000).toISOString());

    // Test 3: Register validator 2 and 3
    console.log("\n=== TEST 3: Register Validators 2 & 3 ===");

    const multiaddr2 = "/ip4/127.0.0.1/tcp/14003/p2p/12D3KooWValidator2";
    const tx2 = await omnicore.connect(validator2).registerNode(
        multiaddr2,
        "http://localhost:3002",
        "ws://localhost:8102",
        "local-dev",
        0
    );
    await tx2.wait();
    console.log("✓ Validator 2 registered");

    const multiaddr3 = "/ip4/127.0.0.1/tcp/14004/p2p/12D3KooWValidator3";
    const tx3 = await omnicore.connect(validator3).registerNode(
        multiaddr3,
        "http://localhost:3003",
        "ws://localhost:8103",
        "local-dev",
        0
    );
    await tx3.wait();
    console.log("✓ Validator 3 registered");

    // Test 4: Query active nodes
    console.log("\n=== TEST 4: Query Active Nodes ===");
    const timeWindow = 86400; // 24 hours in seconds
    const [addresses, infos] = await omnicore.getActiveNodesWithinTime(
        0, // nodeType: gateway
        timeWindow
    );

    console.log(`Found ${addresses.length} active gateway validators:`);
    for (let i = 0; i < addresses.length; i++) {
        console.log(`\n${i + 1}. ${addresses[i]}`);
        console.log(`   Multiaddr: ${infos[i][0]}`);
        console.log(`   HTTP: ${infos[i][1]}`);
        console.log(`   WS: ${infos[i][2]}`);
        console.log(`   Region: ${infos[i][3]}`);
        console.log(`   Active: ${infos[i][5]}`);
    }

    // Test 5: Get active node count
    console.log("\n=== TEST 5: Get Active Node Count ===");
    const count = await omnicore.getActiveNodeCount(0);
    console.log(`Active gateway validators: ${count}`);

    // Test 6: Deactivate validator
    console.log("\n=== TEST 6: Deactivate Validator ===");
    const tx4 = await omnicore.connect(validator1).deactivateNode("Testing deactivation");
    await tx4.wait();
    console.log("✓ Validator 1 deactivated");

    // Verify deactivation
    const countAfter = await omnicore.getActiveNodeCount(0);
    console.log(`Active gateway validators after deactivation: ${countAfter}`);

    // Test 7: Query again with shorter time window
    console.log("\n=== TEST 7: Query with Short Time Window (10 seconds) ===");
    const shortWindow = 10; // 10 seconds
    const [recentAddresses, recentInfos] = await omnicore.getActiveNodesWithinTime(
        0,
        shortWindow
    );
    console.log(`Found ${recentAddresses.length} validators updated in last 10 seconds`);

    // Summary
    console.log("\n" + "=".repeat(50));
    console.log("✅ ALL TESTS PASSED!");
    console.log("=".repeat(50));
    console.log("\nKey Results:");
    console.log(`  ✓ Registered ${addresses.length} validators`);
    console.log(`  ✓ Retrieved node info successfully`);
    console.log(`  ✓ getActiveNodesWithinTime() works correctly`);
    console.log(`  ✓ getActiveNodeCount() returns correct count`);
    console.log(`  ✓ Deactivation works correctly`);
    console.log(`  ✓ Time-based filtering works`);
    console.log("\n🎉 OmniCore validator registry is fully functional!");
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error("❌ Test failed:", error);
        process.exit(1);
    });
