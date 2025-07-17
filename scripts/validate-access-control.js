const { ethers } = require("hardhat");

async function main() {
  console.log("🔐 Validating Access Control Configuration...");

  const [owner, attacker] = await ethers.getSigners();

  // Deploy a minimal OmniCoin setup for testing
  const Config = await ethers.getContractFactory("OmniCoinConfig");
  const config = await Config.deploy(owner.address);
  await config.waitForDeployment();

  const Reputation = await ethers.getContractFactory("OmniCoinReputation");
  const reputation = await Reputation.deploy(await config.getAddress(), owner.address);
  await reputation.waitForDeployment();

  const Staking = await ethers.getContractFactory("OmniCoinStaking");
  const staking = await Staking.deploy(await config.getAddress(), owner.address);
  await staking.waitForDeployment();

  // Deploy minimal dependencies
  const Validator = await ethers.getContractFactory("OmniCoinValidator");
  const validator = await Validator.deploy(ethers.ZeroAddress, owner.address);
  await validator.waitForDeployment();

  const Multisig = await ethers.getContractFactory("OmniCoinMultisig");
  const multisig = await Multisig.deploy(owner.address);
  await multisig.waitForDeployment();

  const Privacy = await ethers.getContractFactory("OmniCoinPrivacy");
  const privacy = await Privacy.deploy(ethers.ZeroAddress, owner.address);
  await privacy.waitForDeployment();

  const GarbledCircuit = await ethers.getContractFactory("OmniCoinGarbledCircuit");
  const garbledCircuit = await GarbledCircuit.deploy(owner.address);
  await garbledCircuit.waitForDeployment();

  const Governor = await ethers.getContractFactory("OmniCoinGovernor");
  const governor = await Governor.deploy(ethers.ZeroAddress, owner.address);
  await governor.waitForDeployment();

  const Escrow = await ethers.getContractFactory("OmniCoinEscrow");
  const escrow = await Escrow.deploy(ethers.ZeroAddress, owner.address);
  await escrow.waitForDeployment();

  const Bridge = await ethers.getContractFactory("OmniCoinBridge");
  const bridge = await Bridge.deploy(ethers.ZeroAddress, owner.address);
  await bridge.waitForDeployment();

  // Deploy main contract
  const OmniCoin = await ethers.getContractFactory("contracts/OmniCoin.sol:OmniCoin");
  const omniCoin = await OmniCoin.deploy(
    owner.address,
    await config.getAddress(),
    await reputation.getAddress(),
    await staking.getAddress(),
    await validator.getAddress(),
    await multisig.getAddress(),
    await privacy.getAddress(),
    await garbledCircuit.getAddress(),
    await governor.getAddress(),
    await escrow.getAddress(),
    await bridge.getAddress()
  );
  await omniCoin.waitForDeployment();

  // Test 1: Owner should be able to mint
  try {
    await omniCoin.mint(owner.address, ethers.parseEther("1000"));
    console.log("✅ Owner can mint (correct)");
  } catch (error) {
    throw new Error("Owner should be able to mint");
  }

  // Test 2: Attacker should NOT be able to mint
  try {
    await omniCoin.connect(attacker).mint(attacker.address, ethers.parseEther("1000"));
    throw new Error("Attacker should not be able to mint");
  } catch (error) {
    if (error.message.includes("AccessControlUnauthorizedAccount")) {
      console.log("✅ Attacker cannot mint (correct)");
    } else {
      throw new Error("Wrong error type for unauthorized minting");
    }
  }

  // Test 3: Owner should be able to pause
  try {
    await omniCoin.pause();
    console.log("✅ Owner can pause (correct)");
  } catch (error) {
    throw new Error("Owner should be able to pause");
  }

  // Test 4: Attacker should NOT be able to unpause
  try {
    await omniCoin.connect(attacker).unpause();
    throw new Error("Attacker should not be able to unpause");
  } catch (error) {
    if (error.message.includes("AccessControlUnauthorizedAccount")) {
      console.log("✅ Attacker cannot unpause (correct)");
    } else {
      throw new Error("Wrong error type for unauthorized unpausing");
    }
  }

  console.log("🎉 Access control validated successfully!");
  console.log("Access control validated"); // Required by monitor
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("❌ Access control validation failed:", error);
    process.exit(1);
  }); 