const { ethers, upgrades } = require("hardhat");

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying contracts with the account:", deployer.address);

  // Deploy OmniCoin
  const OmniCoin = await ethers.getContractFactory("OmniCoin");
  const omniCoin = await upgrades.deployProxy(OmniCoin, [], {
    initializer: "initialize",
  });
  await omniCoin.waitForDeployment();
  console.log("OmniCoin deployed to:", await omniCoin.getAddress());

  // Deploy OmniCoinReputation
  const OmniCoinReputation = await ethers.getContractFactory("OmniCoinReputation");
  const reputation = await upgrades.deployProxy(
    OmniCoinReputation,
    [
      await omniCoin.getAddress(),
      1000, // minReputationForValidator
      30 days, // reputationDecayPeriod
      5 // reputationDecayFactor (5% per period)
    ],
    { initializer: "initialize" }
  );
  await reputation.waitForDeployment();
  console.log("OmniCoinReputation deployed to:", await reputation.getAddress());

  // Deploy OmniCoinStaking
  const OmniCoinStaking = await ethers.getContractFactory("OmniCoinStaking");
  const staking = await upgrades.deployProxy(
    OmniCoinStaking,
    [await omniCoin.getAddress()],
    { initializer: "initialize" }
  );
  await staking.waitForDeployment();
  console.log("OmniCoinStaking deployed to:", await staking.getAddress());

  // Deploy OmniCoinValidator
  const OmniCoinValidator = await ethers.getContractFactory("OmniCoinValidator");
  const validator = await upgrades.deployProxy(
    OmniCoinValidator,
    [
      await omniCoin.getAddress(),
      await reputation.getAddress(),
      await staking.getAddress(),
      ethers.parseEther("10000"), // minStakeAmount
      100, // maxValidators
      1 days, // rewardInterval
      1 hours, // heartbeatInterval
      10 // slashingPenalty (10%)
    ],
    { initializer: "initialize" }
  );
  await validator.waitForDeployment();
  console.log("OmniCoinValidator deployed to:", await validator.getAddress());

  // Deploy OmniCoinPrivacy
  const OmniCoinPrivacy = await ethers.getContractFactory("OmniCoinPrivacy");
  const privacy = await upgrades.deployProxy(
    OmniCoinPrivacy,
    [
      await omniCoin.getAddress(),
      await omniCoin.getAddress(), // Using OmniCoin as account contract for now
      ethers.parseEther("0.1"), // basePrivacyFee
      3, // maxPrivacyLevel
      1 hours // minCooldownPeriod
    ],
    { initializer: "initialize" }
  );
  await privacy.waitForDeployment();
  console.log("OmniCoinPrivacy deployed to:", await privacy.getAddress());

  // Deploy OmniCoinArbitration
  const OmniCoinArbitration = await ethers.getContractFactory("OmniCoinArbitration");
  const arbitration = await upgrades.deployProxy(
    OmniCoinArbitration,
    [
      await omniCoin.getAddress(),
      await reputation.getAddress(),
      ethers.parseEther("100"), // minArbitrationFee
      7 days, // maxArbitrationPeriod
      3 // maxArbitrators
    ],
    { initializer: "initialize" }
  );
  await arbitration.waitForDeployment();
  console.log("OmniCoinArbitration deployed to:", await arbitration.getAddress());

  // Deploy OmniCoinBridge
  const OmniCoinBridge = await ethers.getContractFactory("OmniCoinBridge");
  const bridge = await upgrades.deployProxy(
    OmniCoinBridge,
    [
      await omniCoin.getAddress(),
      ethers.parseEther("0.01"), // bridgeFee
      1 hours // bridgeTimeout
    ],
    { initializer: "initialize" }
  );
  await bridge.waitForDeployment();
  console.log("OmniCoinBridge deployed to:", await bridge.getAddress());

  // Set up permissions and roles
  await omniCoin.grantRole(await omniCoin.MINTER_ROLE(), await validator.getAddress());
  await omniCoin.grantRole(await omniCoin.MINTER_ROLE(), await bridge.getAddress());
  
  // Transfer ownership of contracts to governance
  await omniCoin.transferOwnership(await validator.getAddress());
  await reputation.transferOwnership(await validator.getAddress());
  await staking.transferOwnership(await validator.getAddress());
  await privacy.transferOwnership(await validator.getAddress());
  await arbitration.transferOwnership(await validator.getAddress());
  await bridge.transferOwnership(await validator.getAddress());

  console.log("Deployment completed!");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  }); 