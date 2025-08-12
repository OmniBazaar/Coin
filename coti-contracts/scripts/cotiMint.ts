import { ethers } from "hardhat";
import { Wallet as CotiWallet } from "@coti-io/coti-ethers"; // Assuming 'coti-ethers' is the package name

async function main() {
  // 1. Configuration
  const contractAddress = "0xebe3cD114c9B0cD3ab7e6436B8E468031Af6fe83"; // Replace with your PERCI contract address
  const recipientAddress = "0xfAF7e0962B79675cd046C4c0bF41beEb27FCc5C8"; // Replace with recipient (e.g., deployer or another account)
  const mintAmount = 1000000000; // Plaintext amount to mint (e.g., 1 billion tokens)

  // Ensure you have your private key and RPC URL set up, possibly via environment variables or a config file
  // For Hardhat, it often uses the accounts configured in hardhat.config.ts
  const [deployerSigner] = await ethers.getSigners(); // This is an ethers.js Signer

  if (!deployerSigner) {
    throw new Error("Deployer signer not found. Check Hardhat configuration.");
  }
  console.log(`Using signer address: ${deployerSigner.address}`);


  // 2. Set up COTI Wallet
  // We'll use the private key from the Hardhat signer.
  // NOTE: In a real scenario, you might get the private key from an environment variable for security.
  // For this example, we are deriving it from the Hardhat signer, which is fine for local development.
  // The CotiWallet needs a Provider. We can use the one from the Hardhat environment.
  const cotiProvider = ethers.provider; // Hardhat's ethers environment provides a provider
  
  // The private key from Hardhat's SignerWithAddress is not directly exposed.
  // For this example, we'll assume the first Hardhat account's private key is known
  // or use a placeholder. In a real script, you'd securely provide this.
  // For local Hardhat node, the first account's private key is usually:
  // 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
  // IMPORTANT: DO NOT hardcode private keys in production scripts. Use environment variables.
  // const deployerPrivateKey = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"; // Example private key
  
  // FIXME: Replace this with the actual private key of the contract owner 
  // (signer address: 0xfAF7e0962B79675cd046C4c0bF41beEb27FCc5C8 for coti-testnet)
  // It's highly recommended to use an environment variable for this:
  // const deployerPrivateKey = process.env.COTI_TESTNET_OWNER_PRIVATE_KEY;
  // if (!deployerPrivateKey) {
  //   throw new Error("COTI_TESTNET_OWNER_PRIVATE_KEY environment variable not set.");
  // }
  const deployerPrivateKey = "0xc36c70ce2dfa1a6773371180f5b551d9b2620d80c1a96d57e3872ec49d2ee9c3"; // <<< REPLACE THIS

  const cotiWallet = new CotiWallet(deployerPrivateKey, cotiProvider);
  console.log(`COTI Wallet address: ${await cotiWallet.getAddress()}`);

  // 3. Get Contract Instance
  // The ABI for "PERCI" should be available in your Hardhat artifacts
  const perciContract = await ethers.getContractAt("PERCI", contractAddress, cotiWallet);
  console.log(`PERCI contract loaded at ${await perciContract.getAddress()}`);

  // 4. Call mint
  console.log(`Attempting to call mint on PERCI contract at ${contractAddress}`);
  console.log(`Minting ${mintAmount} tokens to: ${recipientAddress}`);

  try {
    // The mint function in PERCI.sol expects (address, uint64)
    // uint64 can be represented as a number or BigInt in JavaScript/TypeScript
    // ethers.js will handle the conversion to the appropriate type for the transaction.
    const tx = await perciContract.mint(recipientAddress, mintAmount, {
      gasLimit: 2000000, // Adjust gas limit as needed
    });

    console.log(`Transaction sent: ${tx.hash}`);
    await tx.wait();
    console.log(`Transaction confirmed: ${tx.hash}`);
    console.log(
      `mint called successfully! ${mintAmount} tokens minted to ${recipientAddress}.`
    );

    // Optional: Verify balance (if your contract has a suitable public balance viewing function)
    // Since PERCI inherits PrivateERC20, direct balanceOf might return an encrypted value
    // or might not be directly viewable as a plaintext number without decryption.
    // For a public, plaintext balance, you'd need a specific view function in PERCI.sol.
    // Example: const balance = await perciContract.plaintextBalanceOf(recipientAddress);
    // console.log(`Balance of ${recipientAddress}: ${balance.toString()}`);

  } catch (error) {
    console.error("Error calling mint:", error);
    process.exitCode = 1;
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
}); 