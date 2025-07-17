const { ethers, upgrades } = require("hardhat");

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying contracts with the account:", deployer.address);

  // Get the deployed token and bridge addresses
  const tokenAddress = process.env.TOKEN_ADDRESS;
  const bridgeAddress = process.env.BRIDGE_ADDRESS;

  if (!tokenAddress || !bridgeAddress) {
    throw new Error("TOKEN_ADDRESS and BRIDGE_ADDRESS must be set in environment variables");
  }

  // Deploy TimelockController
  const TimelockController = await ethers.getContractFactory("TimelockController");
  const timelock = await TimelockController.deploy(
    2 * 24 * 60 * 60, // 2 days min delay
    [deployer.address], // proposers
    [deployer.address]  // executors
  );
  await timelock.deployed();
  console.log("TimelockController deployed to:", timelock.address);

  // Deploy OmniCoinGovernor
  const OmniCoinGovernor = await ethers.getContractFactory("OmniCoinGovernor");
  const governor = await upgrades.deployProxy(OmniCoinGovernor, [
    tokenAddress,
    bridgeAddress,
    timelock.address,
    1, // voting delay (1 block)
    45818, // voting period (1 week)
    ethers.utils.parseEther("100000"), // proposal threshold (100k tokens)
    4 // quorum numerator (4%)
  ], {
    initializer: "initialize",
  });
  await governor.deployed();
  console.log("OmniCoinGovernor deployed to:", governor.address);

  // Grant governor role in timelock
  const proposerRole = await timelock.PROPOSER_ROLE();
  const executorRole = await timelock.EXECUTOR_ROLE();
  await timelock.grantRole(proposerRole, governor.address);
  await timelock.grantRole(executorRole, governor.address);
  console.log("Granted governor roles in timelock");

  // Revoke deployer's roles
  await timelock.revokeRole(proposerRole, deployer.address);
  await timelock.revokeRole(executorRole, deployer.address);
  console.log("Revoked deployer's roles in timelock");

  // Transfer ownership of token and bridge to timelock
  const token = await ethers.getContractAt("OmniCoin", tokenAddress);
  const bridge = await ethers.getContractAt("OmniCoinBridge", bridgeAddress);
  
  await token.transferOwnership(timelock.address);
  await bridge.transferOwnership(timelock.address);
  console.log("Transferred ownership of token and bridge to timelock");

  // Log deployment info
  console.log("\nDeployment Summary:");
  console.log("-------------------");
  console.log("Token Address:", tokenAddress);
  console.log("Bridge Address:", bridgeAddress);
  console.log("Timelock Address:", timelock.address);
  console.log("Governor Address:", governor.address);
  console.log("\nNext steps:");
  console.log("1. Verify contracts on block explorer");
  console.log("2. Create initial governance proposal to set up protocol parameters");
  console.log("3. Transfer governance tokens to community members");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  }); 