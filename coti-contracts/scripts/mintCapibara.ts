import { ethers } from "hardhat";

async function main() {
  const contractAddress = "0x3b8424dEB61C5c7c0AfE70749B580DD39Ee6807F"; // CAPIBARA Contract
  const [deployer] = await ethers.getSigners();

  // This is the account that will receive the minted tokens.
  // We are using the deployer's address.
  const recipientAddress = deployer.address;

  // CAPIBARA.sol mint function takes uint64 amount.
  // CAPIBARA token has 6 decimals (from PrivateERC20 and constructor logic).
  // To mint 5,000 whole tokens: 5000 * 10^6
  const amountToMint = 10000; // Number of whole tokens
  const decimals = 6;
  const mintValue = BigInt(amountToMint) * BigInt(10**decimals); // Value in smallest units

  const functionName = "mint"; // The mint function in CAPIBARA.sol

  console.log(`Attempting to call ${functionName} on CAPIBARA contract at ${contractAddress}`);
  console.log(`Minting tokens to: ${recipientAddress}`);
  console.log(`Value (smallest units): ${mintValue.toString()}`);
  console.log(`Value (whole tokens): ${amountToMint}`);

  console.log(`Using deployer account (owner and recipient for minting): ${deployer.address}`);

  // Ensure you have the correct ABI in your artifacts (CAPIBARA.json)
  // If CAPIBARA.json does not include your mint function,
  // you need to recompile your contracts: npx hardhat compile
  const capibaraContract = await ethers.getContractAt("CAPIBARA", contractAddress, deployer);

  try {
    // Call the mint function: mint(address account, uint64 amount)
    const tx = await capibaraContract[functionName](recipientAddress, mintValue, { gasLimit: 2000000 });

    console.log(`Transaction sent: ${tx.hash}`);
    await tx.wait();
    console.log(`Transaction confirmed: ${tx.hash}`);
    console.log(`${functionName} called successfully! ${amountToMint} CAPI tokens (value: ${mintValue.toString()}) minted to ${recipientAddress}.`);

    // Optionally, you can try to read the balance if there's a public balance viewing function
    // that works with FHE. For now, we'll rely on the getBalanceCapibara.ts script.
    // Example:
    // if (typeof (capibaraContract as any).balanceOf === 'function') {
    //   console.log(`Note: balanceOf on an FHE token typically returns an encrypted value.`);
    //   // const balance = await capibaraContract.balanceOf(recipientAddress);
    //   // console.log(`Encrypted balance of ${recipientAddress} after minting: ${balance.toString()}`);
    // }


  } catch (error) {
    console.error(`Error calling ${functionName}:`, error);
    process.exitCode = 1;
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
