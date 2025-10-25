const { ethers } = require("hardhat");

async function main() {
  // The address from the failed transaction
  const addressFromTx = "0xC909Cf4EC86FF811F6Cdf6b6D07d0394a1dEa92D";

  // Check if this matches any known private key
  const testPrivateKey = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";
  const testWallet = new ethers.Wallet(testPrivateKey);

  console.log("Hardhat Test Account #1:");
  console.log("Private Key:", testPrivateKey);
  console.log("Address:", testWallet.address);
  console.log("Matches transaction sender:", testWallet.address === addressFromTx);

  // Try to derive the private key that would generate the tx sender address
  // (This is not possible without the private key, but we can check if it's a known pattern)
  console.log("\nTransaction Sender:");
  console.log("Address:", addressFromTx);

  // Check if the address has any balance
  const provider = ethers.provider;
  const balance = await provider.getBalance(addressFromTx);
  console.log("Balance:", ethers.formatEther(balance), "ETH");

  // Let's also create a random wallet to see if the pattern matches
  const randomWallet = ethers.Wallet.createRandom();
  console.log("\nRandom Wallet Example:");
  console.log("Address:", randomWallet.address);
  console.log("Private Key:", randomWallet.privateKey);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });