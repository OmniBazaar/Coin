const { ethers } = require("hardhat");

async function main() {
  // Hardhat's first test account
  const testAddress = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266";

  // Get balance
  const provider = ethers.provider;
  const balance = await provider.getBalance(testAddress);

  console.log(`Account: ${testAddress}`);
  console.log(`Balance: ${ethers.formatEther(balance)} ETH`);

  // Also check the OmniCore contract
  const omniCoreAddress = "0x5FC8d32690cc91D4c39d9d3abcBD16989F875707";
  const contractCode = await provider.getCode(omniCoreAddress);
  console.log(`\nOmniCore contract deployed: ${contractCode !== '0x' ? 'YES' : 'NO'}`);
  console.log(`OmniCore address: ${omniCoreAddress}`);

  // Try to estimate gas for a registerNode call
  if (contractCode !== '0x') {
    const omniCoreABI = [
      "function registerNode(string calldata multiaddr, string calldata httpEndpoint, string calldata wsEndpoint, string calldata region, uint8 nodeType) external"
    ];

    try {
      const signer = new ethers.Wallet("0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80", provider);
      const omniCore = new ethers.Contract(omniCoreAddress, omniCoreABI, signer);

      const gasEstimate = await omniCore.registerNode.estimateGas(
        "/ip4/localhost/tcp/14005/p2p/NodeID-test",
        "http://localhost:4001",
        "ws://localhost:8201",
        "local-dev",
        0 // gateway
      );

      console.log(`\nGas estimate for registerNode: ${gasEstimate.toString()}`);
      console.log(`Gas cost in ETH: ${ethers.formatEther(gasEstimate * BigInt("1000000000"))}`); // 1 gwei gas price
    } catch (error) {
      console.log(`\nError estimating gas: ${error.message}`);
    }
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });