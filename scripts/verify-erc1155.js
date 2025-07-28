const { ethers, run } = require("hardhat");
const chalk = require('chalk');

async function main() {
  console.log(chalk.bold.cyan("ERC-1155 Contract Verification Script"));
  console.log(chalk.cyan("=====================================\n"));

  // Load deployment info
  const deploymentFile = process.argv[2];
  if (!deploymentFile) {
    console.error(chalk.red("ERROR: Please provide deployment file as argument"));
    console.log(chalk.yellow("Usage: npx hardhat run scripts/verify-erc1155.js deployment-erc1155-XXX.json"));
    process.exit(1);
  }

  const fs = require('fs');
  let deployment;
  try {
    deployment = JSON.parse(fs.readFileSync(deploymentFile, 'utf8'));
  } catch (error) {
    console.error(chalk.red("ERROR: Cannot read deployment file"), error.message);
    process.exit(1);
  }

  console.log(chalk.yellow("Network:"), deployment.network);
  console.log(chalk.yellow("Deployed at:"), deployment.timestamp);
  console.log(chalk.yellow("Registry:"), deployment.registry);
  console.log();

  // Verify each contract
  const contracts = [
    {
      name: "OmniERC1155",
      address: deployment.contracts.OmniERC1155,
      constructorArgs: [deployment.registry, deployment.config.baseURI]
    },
    {
      name: "OmniUnifiedMarketplace",
      address: deployment.contracts.OmniUnifiedMarketplace,
      constructorArgs: [deployment.registry]
    },
    {
      name: "OmniERC1155Bridge",
      address: deployment.contracts.OmniERC1155Bridge,
      constructorArgs: [deployment.registry, deployment.contracts.OmniERC1155]
    },
    {
      name: "ServiceTokenExamples",
      address: deployment.contracts.ServiceTokenExamples,
      constructorArgs: [deployment.contracts.OmniERC1155]
    }
  ];

  for (const contract of contracts) {
    console.log(chalk.blue(`\nVerifying ${contract.name} at ${contract.address}...`));
    
    try {
      await run("verify:verify", {
        address: contract.address,
        constructorArguments: contract.constructorArgs,
      });
      console.log(chalk.green(`✓ ${contract.name} verified successfully`));
    } catch (error) {
      if (error.message.includes("Already Verified")) {
        console.log(chalk.yellow(`⚠ ${contract.name} already verified`));
      } else {
        console.error(chalk.red(`✗ ${contract.name} verification failed:`), error.message);
      }
    }
  }

  console.log(chalk.green.bold("\n✅ Verification process complete!"));
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(chalk.red("\nVerification failed:"), error);
    process.exit(1);
  });