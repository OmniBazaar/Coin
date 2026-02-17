const hre = require("hardhat");

async function main() {
  console.log("Deploying OmniBazaar contracts...");
  
  const [deployer] = await hre.ethers.getSigners();
  console.log("Deploying with account:", deployer.address);
  
  // Deploy MockWarpMessenger for testing (simulates Avalanche Warp)
  const MockWarpMessenger = await hre.ethers.getContractFactory("MockWarpMessenger");
  const mockWarpMessenger = await MockWarpMessenger.deploy();
  await mockWarpMessenger.waitForDeployment();
  console.log("MockWarpMessenger deployed to:", await mockWarpMessenger.getAddress());
  
  // Set the MockWarpMessenger at the expected precompile address for testing
  const WARP_PRECOMPILE_ADDRESS = "0x0200000000000000000000000000000000000005";
  const mockWarpMessengerCode = await hre.ethers.provider.getCode(await mockWarpMessenger.getAddress());
  await hre.network.provider.send("hardhat_setCode", [
    WARP_PRECOMPILE_ADDRESS,
    mockWarpMessengerCode
  ]);
  console.log("MockWarpMessenger code set at precompile address:", WARP_PRECOMPILE_ADDRESS);
  
  // Deploy OmniCoin
  const OmniCoin = await hre.ethers.getContractFactory("OmniCoin");
  const omniCoin = await OmniCoin.deploy();
  await omniCoin.waitForDeployment();
  console.log("OmniCoin deployed to:", await omniCoin.getAddress());
  
  // Deploy PrivateOmniCoin (no dependencies)
  const PrivateOmniCoin = await hre.ethers.getContractFactory("PrivateOmniCoin");
  const privateOmniCoin = await PrivateOmniCoin.deploy();
  await privateOmniCoin.waitForDeployment();
  console.log("PrivateOmniCoin deployed to:", await privateOmniCoin.getAddress());
  
  // Deploy OmniCore (needs admin, omniCoin, oddao, stakingPool)
  const OmniCore = await hre.ethers.getContractFactory("OmniCore");
  const omniCore = await OmniCore.deploy(
    deployer.address, // admin
    await omniCoin.getAddress(), // omniCoin
    deployer.address, // oddaoAddress (using deployer for testing)
    deployer.address  // stakingPoolAddress (using deployer for testing)
  );
  await omniCore.waitForDeployment();
  console.log("OmniCore deployed to:", await omniCore.getAddress());
  
  // Deploy OmniGovernance (needs core address)
  const OmniGovernance = await hre.ethers.getContractFactory("OmniGovernance");
  const omniGovernance = await OmniGovernance.deploy(await omniCore.getAddress());
  await omniGovernance.waitForDeployment();
  console.log("OmniGovernance deployed to:", await omniGovernance.getAddress());
  
  // Deploy OmniBridge (needs core address)
  // OmniBridge will now be able to access WARP_MESSENGER at the precompile address
  const OmniBridge = await hre.ethers.getContractFactory("OmniBridge");
  const omniBridge = await OmniBridge.deploy(await omniCore.getAddress());
  await omniBridge.waitForDeployment();
  console.log("OmniBridge deployed to:", await omniBridge.getAddress());
  
  // Deploy MinimalEscrow (needs omniCoin and registry)
  const MinimalEscrow = await hre.ethers.getContractFactory("MinimalEscrow");
  const minimalEscrow = await MinimalEscrow.deploy(
    await omniCoin.getAddress(),
    await omniCoin.getAddress(), // pXOM (reuse for testing)
    deployer.address, // registry
    deployer.address, // feeCollector
    100 // 1% marketplace fee
  );
  await minimalEscrow.waitForDeployment();
  console.log("MinimalEscrow deployed to:", await minimalEscrow.getAddress());
  
  // Initialize OmniCore services
  console.log("Initializing OmniCore services...");
  const OMNICOIN_SERVICE = hre.ethers.keccak256(hre.ethers.toUtf8Bytes("OMNICOIN"));
  const PRIVATE_OMNICOIN_SERVICE = hre.ethers.keccak256(hre.ethers.toUtf8Bytes("PRIVATE_OMNICOIN"));
  await omniCore.setService(OMNICOIN_SERVICE, await omniCoin.getAddress());
  await omniCore.setService(PRIVATE_OMNICOIN_SERVICE, await privateOmniCoin.getAddress());
  console.log("OmniCore services registered");
  
  // Return all addresses
  return {
    mockWarpMessenger: await mockWarpMessenger.getAddress(),
    omniCoin: await omniCoin.getAddress(),
    omniCore: await omniCore.getAddress(),
    omniGovernance: await omniGovernance.getAddress(),
    minimalEscrow: await minimalEscrow.getAddress(),
    omniBridge: await omniBridge.getAddress(),
    privateOmniCoin: await privateOmniCoin.getAddress()
  };
}

main()
  .then((addresses) => {
    console.log(JSON.stringify(addresses));
    process.exit(0);
  })
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
