import { ethers } from "hardhat";
import * as fs from "fs";
import * as path from "path";

/**
 * @notice Deploys the OmniForwarder (ERC-2771 trusted forwarder) contract.
 * @dev This MUST be run first, before all other deployment scripts.
 *      The forwarder address is required by every user-facing contract constructor.
 */
async function saveDeploymentAddresses(addresses: Record<string, string>) {
  const deploymentPath = path.join(__dirname, "../../deployments");
  if (!fs.existsSync(deploymentPath)) {
    fs.mkdirSync(deploymentPath, { recursive: true });
  }

  const network = process.env.HARDHAT_NETWORK || "localhost";
  const filePath = path.join(deploymentPath, `${network}.json`);

  let existing: Record<string, unknown> = {};
  if (fs.existsSync(filePath)) {
    existing = JSON.parse(fs.readFileSync(filePath, "utf8"));
  }

  const updated = { ...existing, ...addresses, timestamp: new Date().toISOString() };
  fs.writeFileSync(filePath, JSON.stringify(updated, null, 2));

  console.log(`Deployment addresses saved to ${filePath}`);
}

async function main() {
  console.log("=== OmniForwarder Deployment ===\n");

  const [deployer] = await ethers.getSigners();
  console.log("Deployer:", deployer.address);

  const balance = await ethers.provider.getBalance(deployer.address);
  console.log("Balance:", ethers.formatEther(balance), "AVAX\n");

  // Deploy OmniForwarder (ERC2771Forwarder wrapper)
  console.log("1. Deploying OmniForwarder...");
  const OmniForwarder = await ethers.getContractFactory("OmniForwarder");
  const forwarder = await OmniForwarder.deploy();
  await forwarder.waitForDeployment();

  const forwarderAddress = await forwarder.getAddress();
  console.log("   OmniForwarder deployed to:", forwarderAddress);

  // Verify EIP-712 domain
  console.log("\n2. Verifying EIP-712 domain...");
  const eip712Domain = await forwarder.eip712Domain();
  console.log("   Name:", eip712Domain.name);
  console.log("   Version:", eip712Domain.version);
  console.log("   Chain ID:", eip712Domain.chainId.toString());
  console.log("   Verifying Contract:", eip712Domain.verifyingContract);

  // Save to deployment file
  console.log("\n3. Saving deployment address...");
  await saveDeploymentAddresses({
    OmniForwarder: forwarderAddress,
  });

  console.log("\n=== OmniForwarder deployment complete ===");
  console.log("\nIMPORTANT: Pass this address to ALL user-facing contract constructors:");
  console.log(`  trustedForwarder_: ${forwarderAddress}`);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("Deployment failed:", error);
    process.exit(1);
  });
