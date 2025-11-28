/**
 * Transfer XOM tokens from deployer to target address
 * Usage: npx hardhat run scripts/transfer-xom.js --network omnicoinFuji
 */
const hre = require("hardhat");

// OmniCoin contract ABI (ERC20 standard methods)
const ERC20_ABI = [
  "function balanceOf(address account) view returns (uint256)",
  "function transfer(address to, uint256 amount) returns (bool)",
  "function decimals() view returns (uint8)",
  "function symbol() view returns (string)",
  "function name() view returns (string)",
  "function totalSupply() view returns (uint256)"
];

async function main() {
  // Configuration
  const OMNICOIN_ADDRESS = "0x117defc430E143529a9067A7866A9e7Eb532203C";
  const TARGET_ADDRESS = "0xBA2Da0AE3C4E37d79501A350d987D8DDa0d93E83"; // omnirick
  const AMOUNT = "100000000"; // 100 million XOM

  console.log("\n🔧 XOM Token Transfer Script");
  console.log("================================");

  // Get signer (deployer)
  const [deployer] = await hre.ethers.getSigners();
  console.log("\n📋 Transfer Details:");
  console.log("  From (Deployer):", deployer.address);
  console.log("  To (omnirick):", TARGET_ADDRESS);
  console.log("  Amount:", AMOUNT, "XOM");
  console.log("  OmniCoin Contract:", OMNICOIN_ADDRESS);

  // Connect to OmniCoin contract
  const omniCoin = new hre.ethers.Contract(OMNICOIN_ADDRESS, ERC20_ABI, deployer);

  // Get token info
  const symbol = await omniCoin.symbol();
  const decimals = await omniCoin.decimals();
  const name = await omniCoin.name();

  console.log("\n💰 Token Info:");
  console.log("  Name:", name);
  console.log("  Symbol:", symbol);
  console.log("  Decimals:", decimals);

  // Check balances before transfer
  const sourceBalanceBefore = await omniCoin.balanceOf(deployer.address);
  const targetBalanceBefore = await omniCoin.balanceOf(TARGET_ADDRESS);

  console.log("\n📊 Balances Before Transfer:");
  console.log("  Source (Deployer):", hre.ethers.formatUnits(sourceBalanceBefore, decimals), symbol);
  console.log("  Target (omnirick):", hre.ethers.formatUnits(targetBalanceBefore, decimals), symbol);

  // Calculate transfer amount with decimals
  const transferAmount = hre.ethers.parseUnits(AMOUNT, decimals);
  console.log("\n  Transfer Amount (wei):", transferAmount.toString());

  // Check if source has enough balance
  if (sourceBalanceBefore < transferAmount) {
    console.error("\n❌ ERROR: Insufficient balance!");
    console.error("  Required:", hre.ethers.formatUnits(transferAmount, decimals), symbol);
    console.error("  Available:", hre.ethers.formatUnits(sourceBalanceBefore, decimals), symbol);
    process.exit(1);
  }

  console.log("\n✅ Sufficient balance confirmed");
  console.log("\n🚀 Executing transfer...");

  // Execute transfer
  const tx = await omniCoin.transfer(TARGET_ADDRESS, transferAmount);
  console.log("  Transaction hash:", tx.hash);
  console.log("  Waiting for confirmation...");

  // Wait for confirmation
  const receipt = await tx.wait();
  console.log("  ✅ Confirmed in block:", receipt.blockNumber);
  console.log("  Gas used:", receipt.gasUsed.toString());

  // Check balances after transfer
  const sourceBalanceAfter = await omniCoin.balanceOf(deployer.address);
  const targetBalanceAfter = await omniCoin.balanceOf(TARGET_ADDRESS);

  console.log("\n📊 Balances After Transfer:");
  console.log("  Source (Deployer):", hre.ethers.formatUnits(sourceBalanceAfter, decimals), symbol);
  console.log("  Target (omnirick):", hre.ethers.formatUnits(targetBalanceAfter, decimals), symbol);

  console.log("\n✅ Transfer completed successfully!");
  console.log("=====================================\n");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("\n❌ Transfer failed:", error.message);
    process.exit(1);
  });
