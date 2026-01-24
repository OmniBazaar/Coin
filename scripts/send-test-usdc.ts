import { ethers } from "hardhat";
import * as fs from "fs";
import * as path from "path";

/**
 * Send TestUSDC to a recipient address
 *
 * Usage:
 *   npx hardhat run scripts/send-test-usdc.ts --network omnicoinFuji
 *
 * Set recipient and amount via environment variables:
 *   RECIPIENT=0x... AMOUNT=5000000 npx hardhat run scripts/send-test-usdc.ts --network omnicoinFuji
 *
 * Or modify the defaults below.
 */

// Default recipient - SET YOUR ADDRESS HERE
const DEFAULT_RECIPIENT = process.env.RECIPIENT ?? "0x0000000000000000000000000000000000000000";

// Amount in whole TestUSDC (not wei) - default 5 million
const DEFAULT_AMOUNT = process.env.AMOUNT ?? "5000000";

interface DeploymentFile {
  contracts: Record<string, string | Record<string, string>>;
  [key: string]: unknown;
}

const ERC20_ABI = [
  "function transfer(address to, uint256 amount) external returns (bool)",
  "function balanceOf(address account) external view returns (uint256)",
  "function decimals() external view returns (uint8)",
  "function symbol() external view returns (string)",
];

async function main(): Promise<void> {
  const recipient = DEFAULT_RECIPIENT;
  const amount = DEFAULT_AMOUNT;

  if (recipient === "0x0000000000000000000000000000000000000000") {
    console.error("❌ ERROR: No recipient specified!");
    console.log("\nUsage:");
    console.log("  RECIPIENT=0xYourAddress AMOUNT=5000000 npx hardhat run scripts/send-test-usdc.ts --network omnicoinFuji");
    console.log("\nOr edit the DEFAULT_RECIPIENT in the script.");
    process.exit(1);
  }

  console.log("🚀 Sending TestUSDC\n");

  // Get deployer account
  const [deployer] = await ethers.getSigners();
  console.log("Sender (Deployer):", deployer.address);
  console.log("Recipient:", recipient);
  console.log("Amount:", amount, "TestUSDC");

  // Load deployment file
  const deploymentPath = path.join(__dirname, "../deployments/fuji.json");
  if (!fs.existsSync(deploymentPath)) {
    throw new Error("Fuji deployment file not found");
  }

  const deployment = JSON.parse(fs.readFileSync(deploymentPath, "utf-8")) as DeploymentFile;
  const testUsdcAddress = deployment.contracts.TestUSDC as string;

  if (!testUsdcAddress) {
    throw new Error("TestUSDC not deployed");
  }

  console.log("TestUSDC Contract:", testUsdcAddress);

  // Create contract instance
  const testUsdc = new ethers.Contract(testUsdcAddress, ERC20_ABI, deployer);

  // Check balances before
  const decimals = await testUsdc.decimals();
  const senderBalanceBefore = await testUsdc.balanceOf(deployer.address);
  const recipientBalanceBefore = await testUsdc.balanceOf(recipient);

  console.log("\nBalances Before:");
  console.log(`  Sender: ${ethers.formatUnits(senderBalanceBefore, decimals)} TestUSDC`);
  console.log(`  Recipient: ${ethers.formatUnits(recipientBalanceBefore, decimals)} TestUSDC`);

  // Convert amount to wei (6 decimals for USDC)
  const amountWei = ethers.parseUnits(amount, decimals);

  if (senderBalanceBefore < amountWei) {
    throw new Error(`Insufficient balance. Have: ${ethers.formatUnits(senderBalanceBefore, decimals)}, Need: ${amount}`);
  }

  // Send tokens
  console.log("\nSending tokens...");
  const tx = await testUsdc.transfer(recipient, amountWei);
  console.log("Transaction hash:", tx.hash);

  const receipt = await tx.wait();
  console.log("✓ Transaction confirmed in block:", receipt?.blockNumber);

  // Check balances after
  const senderBalanceAfter = await testUsdc.balanceOf(deployer.address);
  const recipientBalanceAfter = await testUsdc.balanceOf(recipient);

  console.log("\nBalances After:");
  console.log(`  Sender: ${ethers.formatUnits(senderBalanceAfter, decimals)} TestUSDC`);
  console.log(`  Recipient: ${ethers.formatUnits(recipientBalanceAfter, decimals)} TestUSDC`);

  console.log("\n✅ Successfully sent", amount, "TestUSDC to", recipient);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("Transfer failed:", error);
    process.exit(1);
  });
