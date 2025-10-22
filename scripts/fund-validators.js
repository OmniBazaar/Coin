/**
 * Fund validator wallets from Hardhat test account
 * This allows validators to pay gas fees for registering in OmniCore
 */

const hre = require("hardhat");

async function main() {
  const [funder] = await hre.ethers.getSigners();

  console.log("Funding validators from account:", funder.address);
  console.log("Account balance:", hre.ethers.formatEther(await hre.ethers.provider.getBalance(funder.address)), "ETH");

  // Validator addresses (from launch-validators.ts - uses Hardhat test private keys)
  const validators = [
    "0x8D2738c35A708fcd0Bb747d636C0AA7A06BcD2Cf",  // validator-1 (Hardhat key #1)
    "0xEa19860Ca2Be7b75d8632443dc787650d05093c6",  // validator-2 (Hardhat key #2)
    "0xb0bf7f324458d031FA9622E0F83Ff8635F2d9023"   // validator-3 (Hardhat key #3)
  ];

  const fundAmount = hre.ethers.parseEther("10.0"); // 10 ETH each

  for (const validatorAddress of validators) {
    const balance = await hre.ethers.provider.getBalance(validatorAddress);
    console.log(`\nValidator ${validatorAddress}:`);
    console.log(`  Current balance: ${hre.ethers.formatEther(balance)} ETH`);

    if (balance < fundAmount) {
      console.log(`  Funding with ${hre.ethers.formatEther(fundAmount)} ETH...`);
      const tx = await funder.sendTransaction({
        to: validatorAddress,
        value: fundAmount
      });
      await tx.wait();
      const newBalance = await hre.ethers.provider.getBalance(validatorAddress);
      console.log(`  ✅ New balance: ${hre.ethers.formatEther(newBalance)} ETH`);
    } else {
      console.log(`  ✅ Already funded (${hre.ethers.formatEther(balance)} ETH)`);
    }
  }

  console.log("\n✅ All validators funded!");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
