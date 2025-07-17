const { ethers, upgrades } = require("hardhat");

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying contracts with the account:", deployer.address);

  // Deploy OmniCoin first if not already deployed
  const OmniCoin = await ethers.getContractFactory("OmniCoin");
  const omniCoin = await upgrades.deployProxy(OmniCoin, [], {
    initializer: "initialize",
  });
  await omniCoin.deployed();
  console.log("OmniCoin deployed to:", omniCoin.address);

  // Deploy OmniCoinBridge
  const OmniCoinBridge = await ethers.getContractFactory("OmniCoinBridge");
  const bridge = await upgrades.deployProxy(OmniCoinBridge, [
    "0x66A71Dcef29A0fFBDBE3c6a460a3B5BC225Cd675", // LayerZero Endpoint (Ethereum Mainnet)
    omniCoin.address
  ], {
    initializer: "initialize",
  });
  await bridge.deployed();
  console.log("OmniCoinBridge deployed to:", bridge.address);

  // Grant bridge contract permission to mint/burn tokens
  await omniCoin.grantRole(await omniCoin.MINTER_ROLE(), bridge.address);
  console.log("Granted MINTER_ROLE to bridge contract");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  }); 