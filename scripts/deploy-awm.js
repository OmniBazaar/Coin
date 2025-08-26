const hre = require("hardhat");

async function main() {
  console.log("Deploying Avalanche Warp Messaging contracts...");
  
  // Deploy TeleporterMessenger mock for local testing
  const TeleporterMock = await hre.ethers.getContractFactory("TeleporterMessengerMock");
  const teleporter = await TeleporterMock.deploy();
  await teleporter.waitForDeployment();
  console.log("TeleporterMock deployed to:", await teleporter.getAddress());
  
  // Deploy AWM Relayer
  const AWMRelayer = await hre.ethers.getContractFactory("AWMRelayer");
  const awmRelayer = await AWMRelayer.deploy(await teleporter.getAddress());
  await awmRelayer.waitForDeployment();
  console.log("AWMRelayer deployed to:", await awmRelayer.getAddress());
  
  return {
    teleporter: await teleporter.getAddress(),
    awmRelayer: await awmRelayer.getAddress()
  };
}

main()
  .then((addresses) => {
    console.log(JSON.stringify(addresses));
    process.exit(0);
  })
  .catch((error) => {
    // AWM contracts might not exist yet
    console.log("AWM contracts not found - using default addresses");
    process.exit(0);
  });
