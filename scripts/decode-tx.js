const { ethers } = require("hardhat");

// The raw transaction from the error message
const rawTx = "0x02f9025382053980843b9aca0084596983b883045a44945fc8d32690cc91d4c39d9d3abcbd16989f87570780b901e46689327100000000000000000000000000000000000000000000000000000000000000a00000000000000000000000000000000000000000000000000000000000000120000000000000000000000000000000000000000000000000000000000000016000000000000000000000000000000000000000000000000000000000000001a00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000004c2f6970342f6c6f63616c686f73742f7463702f31343030352f7032702f4e6f646549442d3637363534323437393037663635326636363738646634646564326538626365333663633065376500000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000015687474703a2f2f6c6f63616c686f73743a343030310000000000000000000000000000000000000000000000000000000000000000000000000000000000001377733a2f2f6c6f63616c686f73743a383230310000000000000000000000000000000000000000000000000000000000000000000000000000000000000000096c6f63616c2d6465760000000000000000000000000000000000000000000000c080a063ca8c36e0e5ab401dd51765537c8a795ffa23b665775db8b775c826fa04d333a030e59f118aede565f3f3e5992b6b859c971998bab8d010033728d1b6a490d70a";

try {
  // Parse the transaction
  const tx = ethers.Transaction.from(rawTx);

  console.log("Transaction Details:");
  console.log("From:", tx.from);
  console.log("To:", tx.to);
  console.log("Value:", ethers.formatEther(tx.value), "ETH");
  console.log("Gas Limit:", tx.gasLimit.toString());
  console.log("Max Fee Per Gas:", ethers.formatUnits(tx.maxFeePerGas, "gwei"), "gwei");
  console.log("Max Priority Fee:", ethers.formatUnits(tx.maxPriorityFeePerGas, "gwei"), "gwei");

  // Calculate max upfront cost
  const maxCost = tx.gasLimit * tx.maxFeePerGas;
  console.log("\nMax Upfront Cost:", maxCost.toString(), "wei");
  console.log("Max Upfront Cost:", ethers.formatEther(maxCost), "ETH");

  // Decode the function call
  const iface = new ethers.Interface([
    "function registerNode(string calldata multiaddr, string calldata httpEndpoint, string calldata wsEndpoint, string calldata region, uint8 nodeType) external"
  ]);

  const decoded = iface.parseTransaction({ data: tx.data });
  console.log("\nFunction:", decoded.name);
  console.log("Parameters:");
  console.log("- multiaddr:", decoded.args[0]);
  console.log("- httpEndpoint:", decoded.args[1]);
  console.log("- wsEndpoint:", decoded.args[2]);
  console.log("- region:", decoded.args[3]);
  console.log("- nodeType:", decoded.args[4].toString());

} catch (error) {
  console.error("Error decoding transaction:", error.message);
}