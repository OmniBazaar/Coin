const { ethers } = require("hardhat");

async function main() {
  const OmniCore = await ethers.getContractAt("OmniCore", "0x5FC8d32690cc91D4c39d9d3abcBD16989F875707");
  const count = await OmniCore.getValidatorCount();
  console.log("Validator count:", count.toString());

  if (count > 0) {
    for (let i = 0; i < count; i++) {
      const validators = await OmniCore.getActiveValidators(0, count);
      console.log("Active validators:", validators);
      break;
    }
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
