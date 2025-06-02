import { ethers } from "hardhat";

async function main() {
  const contractAddress = "0xAe88A375bA48A0dB0098840484d120a8519BF9EE"; // PERCI Contract
  const [deployer] = await ethers.getSigners();

  // This is the account that will receive the minted tokens.
  // We are changing this to be the deployer's address.
  const recipientAddress = deployer.address; 
  const mintValue = ethers.parseUnits("10000", 0); // This is a BigInt (plaintext)
                                                      // If PERCI has decimals (e.g., 18), use ethers.parseUnits("1000000000", DECIMALS_HERE)

  // IMPORTANT: Replace "publicMint" with the actual name of your public/external minting function
  // if it's different.
  const functionName = "publicMint";

  console.log(`Attempting to call ${functionName} on PERCI contract at ${contractAddress}`);
  console.log(`Minting tokens to: ${recipientAddress}`);
  console.log(`Value: ${mintValue.toString()}`);

  console.log(`Using deployer account (owner and recipient for minting): ${deployer.address}`);

  // Ensure you have the correct ABI in your artifacts
  // If PERCI.json does not include your public minting function,
  // you need to recompile your contracts.
  const perciContract = await ethers.getContractAt("PERCI", contractAddress, deployer);

  try {
    // IMPORTANT: Adjust the parameters if your publicMint function takes different inputs.
    // This assumes a function like: function publicMint(address to, uint256 amount) external { ... }
    const tx = await perciContract[functionName](recipientAddress, mintValue, { gasLimit: 2000000 }); // Added gasLimit back

    console.log(`Transaction sent: ${tx.hash}`);
    await tx.wait();
    console.log(`Transaction confirmed: ${tx.hash}`);
    console.log(`${functionName} called successfully! ${mintValue.toString()} tokens minted to ${recipientAddress}.`);

    // Optionally, you can try to read the balance if there's a public balance viewing function
    // const balance = await perciContract.balanceOf(recipientAddress);
    // console.log(`Balance of ${recipientAddress} after minting: ${balance.toString()}`);

  } catch (error) {
    console.error(`Error calling ${functionName}:`, error);
    process.exitCode = 1;
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
