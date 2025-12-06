/**
 * Fund Validator Wallets on Fuji C-Chain
 *
 * This script sends AVAX from the Deployer to all validator wallets
 * so they can pay gas for Bootstrap.sol registration.
 */

const { ethers } = require("hardhat");

async function main() {
  console.log("Funding validator wallets on Fuji C-Chain...\n");

  // Deployer account (funded with AVAX from faucet)
  const [deployer] = await ethers.getSigners();
  console.log("Deployer address:", deployer.address);

  const deployerBalance = await ethers.provider.getBalance(deployer.address);
  console.log("Deployer balance:", ethers.formatEther(deployerBalance), "AVAX\n");

  // Validator addresses (Hardhat test accounts 0-4)
  const validators = [
    { name: "Validator 1", address: "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266" },
    { name: "Validator 2", address: "0x70997970C51812dc3A010C7d01b50e0d17dc79C8" },
    { name: "Validator 3", address: "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC" },
    { name: "Validator 4", address: "0x90F79bf6EB2c4f870365E785982E1f101E93b906" },
    { name: "Validator 5", address: "0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65" },
  ];

  // Amount to send to each validator (0.05 AVAX - enough for many registrations)
  const amountToSend = ethers.parseEther("0.05");
  const totalNeeded = amountToSend * BigInt(validators.length);

  console.log(`Sending ${ethers.formatEther(amountToSend)} AVAX to each validator`);
  console.log(`Total needed: ${ethers.formatEther(totalNeeded)} AVAX\n`);

  if (deployerBalance < totalNeeded) {
    console.error(`ERROR: Insufficient balance. Need ${ethers.formatEther(totalNeeded)} AVAX but only have ${ethers.formatEther(deployerBalance)} AVAX`);
    process.exit(1);
  }

  // Send to each validator
  for (const validator of validators) {
    try {
      // Check current balance
      const currentBalance = await ethers.provider.getBalance(validator.address);
      console.log(`${validator.name} (${validator.address})`);
      console.log(`  Current balance: ${ethers.formatEther(currentBalance)} AVAX`);

      // Only send if balance is below threshold
      if (currentBalance < ethers.parseEther("0.01")) {
        console.log(`  Sending ${ethers.formatEther(amountToSend)} AVAX...`);

        const tx = await deployer.sendTransaction({
          to: validator.address,
          value: amountToSend,
        });

        await tx.wait();
        console.log(`  ✅ Transaction confirmed: ${tx.hash}`);

        // Verify new balance
        const newBalance = await ethers.provider.getBalance(validator.address);
        console.log(`  New balance: ${ethers.formatEther(newBalance)} AVAX`);
      } else {
        console.log(`  ⏭️  Skipping - already has sufficient balance`);
      }
      console.log("");
    } catch (error) {
      console.error(`  ❌ Error funding ${validator.name}:`, error.message);
    }
  }

  // Final deployer balance
  const finalBalance = await ethers.provider.getBalance(deployer.address);
  console.log(`\nDeployer final balance: ${ethers.formatEther(finalBalance)} AVAX`);
  console.log("\n✅ All validators funded!");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
