const hre = require("hardhat");

async function main() {
  console.log("\n=== Checking Pre-Deployed Validator Manager ===\n");

  const VALIDATOR_MANAGER = "0x0Feedc0de0000000000000000000000000000000";
  const SPECIALIZED_MANAGER = "0x100c0De1C0FFEe00000000000000000000000000";

  // Get code at both addresses
  const vmCode = await hre.ethers.provider.getCode(VALIDATOR_MANAGER);
  const specCode = await hre.ethers.provider.getCode(SPECIALIZED_MANAGER);

  console.log("ValidatorManager (0x0Feedc0de...):");
  console.log("  Code size:", vmCode.length, "bytes");
  console.log("  Has code:", vmCode !== "0x");

  console.log("\nSpecializedValidatorManager (0x100c0De1...):");
  console.log("  Code size:", specCode.length, "bytes");
  console.log("  Has code:", specCode !== "0x");

  if (vmCode !== "0x") {
    // Try to interact with it
    const abi = [
      "function validatorCount() view returns (uint64)",
      "function weightToValueFactor() view returns (uint64)",
      "function registrationExpiry() view returns (uint64)",
      "function initializationComplete() view returns (bool)"
    ];
    
    try {
      const vm = new hre.ethers.Contract(VALIDATOR_MANAGER, abi, hre.ethers.provider);
      
      const initComplete = await vm.initializationComplete();
      console.log("\n✓ Initialization complete:", initComplete);
      
      const count = await vm.validatorCount();
      console.log("✓ Validator count:", count.toString());
    } catch (e) {
      console.log("\n⚠️ Could not query contract methods:", e.message);
    }
  }
}

main().catch(console.error);
