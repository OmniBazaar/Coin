const { ethers, upgrades } = require("hardhat");

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying contracts with the account:", deployer.address);

  // Get entry point address from environment
  const entryPoint = process.env.ENTRY_POINT_ADDRESS;
  if (!entryPoint) {
    throw new Error("ENTRY_POINT_ADDRESS must be set in environment variables");
  }

  // Deploy Garbled Circuit
  console.log("\nDeploying OmniCoinGarbledCircuit...");
  const OmniCoinGarbledCircuit = await ethers.getContractFactory("OmniCoinGarbledCircuit");
  const garbledCircuit = await upgrades.deployProxy(OmniCoinGarbledCircuit, [
    ethers.utils.parseEther("0.01") // verificationFee: 0.01 ETH
  ], {
    initializer: "initialize",
  });
  await garbledCircuit.deployed();
  console.log("OmniCoinGarbledCircuit deployed to:", garbledCircuit.address);

  // Deploy Account Abstraction
  console.log("\nDeploying OmniCoinAccount...");
  const OmniCoinAccount = await ethers.getContractFactory("OmniCoinAccount");
  const account = await upgrades.deployProxy(OmniCoinAccount, [
    entryPoint
  ], {
    initializer: "initialize",
  });
  await account.deployed();
  console.log("OmniCoinAccount deployed to:", account.address);

  // Log deployment info
  console.log("\nDeployment Summary:");
  console.log("-------------------");
  console.log("Garbled Circuit Address:", garbledCircuit.address);
  console.log("Account Abstraction Address:", account.address);
  console.log("Entry Point Address:", entryPoint);
  console.log("\nNext steps:");
  console.log("1. Verify contracts on block explorer");
  console.log("2. Set up monitoring for circuit verifications");
  console.log("3. Configure account abstraction parameters");
  console.log("4. Test privacy features with sample circuits");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  }); 