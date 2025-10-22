const { ethers } = require("hardhat");

async function main() {
  const omnicoreAddress = "0x5FC8d32690cc91D4c39d9d3abcBD16989F875707";

  // Get contract ABI
  const OmniCore = await ethers.getContractFactory("OmniCore");
  const omniCore = OmniCore.attach(omnicoreAddress);

  console.log("Querying OmniCore contract at:", omnicoreAddress);

  // Try to get registered nodes
  try {
    // Get all node multiaddrs from events
    const filter = omniCore.filters.NodeRegistered();
    const events = await omniCore.queryFilter(filter, 0, 'latest');

    console.log("\nRegistered Nodes:", events.length);
    for (const event of events) {
      console.log("  Node:", {
        multiaddr: event.args[0],
        httpEndpoint: event.args[1],
        wsEndpoint: event.args[2],
        region: event.args[3],
        nodeType: event.args[4]
      });
    }
  } catch (error) {
    console.error("Error querying nodes:", error.message);
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
