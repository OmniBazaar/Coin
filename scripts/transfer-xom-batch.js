/**
 * Batch transfer XOM tokens from deployer to multiple addresses
 * Usage: npx hardhat run scripts/transfer-xom-batch.js --network omnicoinFuji
 */
const hre = require("hardhat");

// OmniCoin contract ABI (ERC20 standard methods)
const ERC20_ABI = [
  "function balanceOf(address account) view returns (uint256)",
  "function transfer(address to, uint256 amount) returns (bool)",
  "function decimals() view returns (uint8)",
  "function symbol() view returns (string)",
  "function name() view returns (string)"
];

async function main() {
  // Configuration
  const OMNICOIN_ADDRESS = "0x117defc430E143529a9067A7866A9e7Eb532203C";

  // Recipients: [address, amount, username]
  const TRANSFERS = [
    ["0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266", "2000000", "validator-1-staking"]
  ];

  console.log("\n🔧 XOM Batch Transfer Script");
  console.log("================================");

  // Get signer (deployer)
  const [deployer] = await hre.ethers.getSigners();
  console.log("\n📋 From (Deployer):", deployer.address);

  // Connect to OmniCoin contract
  const omniCoin = new hre.ethers.Contract(OMNICOIN_ADDRESS, ERC20_ABI, deployer);

  // Get token info
  const symbol = await omniCoin.symbol();
  const decimals = await omniCoin.decimals();

  // Check deployer balance
  const deployerBalance = await omniCoin.balanceOf(deployer.address);
  console.log("  Balance:", hre.ethers.formatUnits(deployerBalance, decimals), symbol);

  // Calculate total needed
  let totalNeeded = 0n;
  for (const [, amount] of TRANSFERS) {
    totalNeeded += hre.ethers.parseUnits(amount, decimals);
  }
  console.log("  Total to transfer:", hre.ethers.formatUnits(totalNeeded, decimals), symbol);

  if (deployerBalance < totalNeeded) {
    console.error("\n❌ ERROR: Insufficient balance!");
    process.exit(1);
  }

  console.log("\n🚀 Executing transfers...\n");

  for (const [address, amount, username] of TRANSFERS) {
    const transferAmount = hre.ethers.parseUnits(amount, decimals);

    // Get balance before
    const balanceBefore = await omniCoin.balanceOf(address);

    console.log(`📤 Transferring ${amount} ${symbol} to ${username}`);
    console.log(`   Address: ${address}`);
    console.log(`   Balance before: ${hre.ethers.formatUnits(balanceBefore, decimals)} ${symbol}`);

    // Execute transfer
    const tx = await omniCoin.transfer(address, transferAmount);
    console.log(`   Tx hash: ${tx.hash}`);

    // Wait for confirmation
    const receipt = await tx.wait();
    console.log(`   ✅ Confirmed in block ${receipt.blockNumber} (gas: ${receipt.gasUsed})`);

    // Get balance after
    const balanceAfter = await omniCoin.balanceOf(address);
    console.log(`   Balance after: ${hre.ethers.formatUnits(balanceAfter, decimals)} ${symbol}\n`);
  }

  // Final deployer balance
  const finalBalance = await omniCoin.balanceOf(deployer.address);
  console.log("📊 Deployer final balance:", hre.ethers.formatUnits(finalBalance, decimals), symbol);
  console.log("\n✅ All transfers completed successfully!");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("\n❌ Transfer failed:", error.message);
    process.exit(1);
  });
