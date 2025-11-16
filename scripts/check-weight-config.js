const hre = require("hardhat");

async function main() {
  console.log("\n=== Checking Weight Configuration ===\n");

  const VALIDATOR_MANAGER = "0x0Feedc0de0000000000000000000000000000000";

  // Try to query weight-related functions
  const abi = [
    "function weightToValueFactor() view returns (uint64)",
    "function minimumStakeAmount() view returns (uint256)",
    "function maximumStakeAmount() view returns (uint256)",
    "function minimumStakeDuration() view returns (uint64)",
    "function totalWeight() view returns (uint64)"
  ];

  const [signer] = await hre.ethers.getSigners();

  try {
    const vm = new hre.ethers.Contract(VALIDATOR_MANAGER, abi, signer);

    // Try each function
    try {
      const factor = await vm.weightToValueFactor();
      console.log("Weight to Value Factor:", factor.toString());
    } catch (e) {
      console.log("weightToValueFactor: Not available");
    }

    // Check the actual weight limit calculation
    console.log("\n💡 Weight Analysis:");
    console.log("- Validator 1 has weight: 100");
    console.log("- CLI limits new validators to: 20");
    console.log("- This appears to be 20% of current total weight");
    console.log("\n🔍 Possible Explanations:");
    console.log("1. Anti-centralization: Prevents any single addition from gaining >20% control");
    console.log("2. Security: Gradual weight increases for safety");
    console.log("3. The limit might increase as total weight increases");

    console.log("\n📊 For Equal 5-Validator Setup:");
    console.log("- If we want equal weights, each should have 20% of total");
    console.log("- Current: V1=100 (100%)");
    console.log("- Target: V1=100, V2=100, V3=100, V4=100, V5=100 (each 20%)");
    console.log("- But CLI only allows adding 20 at a time!");

    console.log("\n🎯 Possible Solutions:");
    console.log("1. Add validators with weight 20 each (unequal, but functional)");
    console.log("2. Add V2 with 20, then increase weight later");
    console.log("3. Use 5-validator genesis to start with equal weights");
    console.log("4. Modify the pre-deployed validator manager (if possible)");

  } catch (error) {
    console.log("Error:", error.message);
  }
}

main().catch(console.error);