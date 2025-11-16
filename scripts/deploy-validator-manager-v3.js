const hre = require("hardhat");
const fs = require("fs");
const path = require("path");

/**
 * Deploy OmniValidatorManager V3 and QualificationOracle
 *
 * This script deploys the V3 validator manager that bypasses the WARP
 * signature aggregation bug by sending validator registrations directly
 * to P-Chain without requiring initializeValidatorSet.
 */
async function main() {
  console.log("\n===========================================");
  console.log("🚀 Deploying OmniValidatorManager V3");
  console.log("===========================================\n");

  // Get deployer account
  const [deployer] = await hre.ethers.getSigners();
  console.log("📍 Deployer address:", deployer.address);

  // Get balance
  const balance = await hre.ethers.provider.getBalance(deployer.address);
  console.log("💰 Deployer balance:", hre.ethers.formatEther(balance), "AVAX\n");

  // Check network
  const network = await hre.ethers.provider.getNetwork();
  console.log("🌐 Network:", network.name);
  console.log("⛓️  Chain ID:", network.chainId.toString());

  // Verify we're on Fuji L1
  if (network.chainId !== 131313n) {
    console.error("❌ Wrong network! Expected chainId 131313 (OmniCoin Fuji L1)");
    console.error("   Current chainId:", network.chainId.toString());
    process.exit(1);
  }

  console.log("\n-------------------------------------------");
  console.log("Step 1: Deploying QualificationOracle");
  console.log("-------------------------------------------\n");

  // Check if QualificationOracle already exists
  let oracleAddress;
  const fujiPath = path.join(__dirname, "..", "deployments", "fuji.json");

  if (fs.existsSync(fujiPath)) {
    const fujiDeployment = JSON.parse(fs.readFileSync(fujiPath, "utf8"));
    if (fujiDeployment.QualificationOracle) {
      oracleAddress = fujiDeployment.QualificationOracle;
      console.log("✅ Using existing QualificationOracle:", oracleAddress);
    }
  }

  // Use the recently deployed one if available
  if (!oracleAddress) {
    oracleAddress = "0xbae62140111D1B620D70494A5eF11c2b5Aa1d053";
    console.log("✅ Using recently deployed QualificationOracle:", oracleAddress);
  }

  // Get QualificationOracle contract instance
  const qualificationOracle = await hre.ethers.getContractAt("QualificationOracle", oracleAddress);

  // Set initial qualified addresses (validator operators)
  console.log("\n📋 Setting initial qualified validators...");

  // These should be the actual operator addresses for validators 1-5
  const qualifiedAddresses = [
    deployer.address, // Validator 1 operator (current deployer)
  ];

  for (const addr of qualifiedAddresses) {
    try {
      const tx = await qualificationOracle.setQualified(addr, true);
      await tx.wait();
      console.log(`   ✓ Qualified: ${addr}`);
    } catch (error) {
      console.log(`   ⚠️ Could not qualify ${addr} (may already be qualified)`);
    }
  }

  console.log("\n-------------------------------------------");
  console.log("Step 2: Deploying OmniValidatorManager V3");
  console.log("-------------------------------------------\n");

  // Deploy OmniValidatorManager V3
  const OmniValidatorManager = await hre.ethers.getContractFactory("OmniValidatorManager");
  const validatorManager = await OmniValidatorManager.deploy(oracleAddress);
  await validatorManager.waitForDeployment();

  const managerAddress = await validatorManager.getAddress();
  console.log("✅ OmniValidatorManager V3 deployed to:", managerAddress);

  // Verify configuration
  console.log("\n📊 Verifying configuration...");
  const warpPrecompile = await validatorManager.WARP_PRECOMPILE();
  const validatorWeight = await validatorManager.VALIDATOR_WEIGHT();
  const maxValidators = await validatorManager.MAX_VALIDATORS();
  const registrationsEnabled = await validatorManager.registrationsEnabled();

  console.log("   WARP Precompile:", warpPrecompile);
  console.log("   Validator Weight:", validatorWeight.toString());
  console.log("   Max Validators:", maxValidators.toString());
  console.log("   Registrations Enabled:", registrationsEnabled);

  console.log("\n-------------------------------------------");
  console.log("Step 3: Saving Deployment Addresses");
  console.log("-------------------------------------------\n");

  // Create deployment info
  const deployment = {
    network: "fuji",
    chainId: 131313,
    deployedAt: new Date().toISOString(),
    contracts: {
      QualificationOracle: oracleAddress,
      OmniValidatorManager: managerAddress,
    },
    configuration: {
      warpPrecompile: warpPrecompile,
      validatorWeight: Number(validatorWeight),
      maxValidators: Number(maxValidators),
      registrationsEnabled: registrationsEnabled,
      qualifiedAddresses: qualifiedAddresses,
    },
    notes: {
      version: "V3",
      description: "Direct P-Chain registration without initializeValidatorSet",
      bypassesWarpBug: true,
    }
  };

  // Save to file
  const deploymentPath = path.join(__dirname, "..", "deployments", "validator-manager-v3.json");
  fs.mkdirSync(path.dirname(deploymentPath), { recursive: true });
  fs.writeFileSync(deploymentPath, JSON.stringify(deployment, null, 2));

  console.log("💾 Deployment info saved to:", deploymentPath);

  // Update main deployment file
  const mainDeploymentPath = path.join(__dirname, "..", "deployments", "fuji.json");
  if (fs.existsSync(mainDeploymentPath)) {
    const mainDeployment = JSON.parse(fs.readFileSync(mainDeploymentPath, "utf8"));
    mainDeployment.QualificationOracle = oracleAddress;
    mainDeployment.OmniValidatorManager = managerAddress;
    mainDeployment.validatorManagerVersion = "V3";
    fs.writeFileSync(mainDeploymentPath, JSON.stringify(mainDeployment, null, 2));
    console.log("📝 Updated main deployment file:", mainDeploymentPath);
  }

  console.log("\n===========================================");
  console.log("✅ DEPLOYMENT COMPLETE!");
  console.log("===========================================\n");

  console.log("📋 Summary:");
  console.log("   QualificationOracle:", oracleAddress);
  console.log("   OmniValidatorManager V3:", managerAddress);

  console.log("\n🎯 Next Steps:");
  console.log("1. Run: npx ts-node scripts/register-validator-v3.ts 2");
  console.log("2. Register validators 3, 4, 5 similarly");
  console.log("3. Complete registrations after P-Chain acknowledgment");
  console.log("4. Verify multi-validator consensus\n");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("❌ Deployment failed:", error);
    process.exit(1);
  });