import { getDefaultProvider, CotiNetwork, Wallet } from '@coti-io/coti-ethers';
import { Contract, formatUnits } from 'ethers';

// Define the contract details
// const COTI_TESTNET_RPC_URL = 'https://testnet.coti.io/rpc'; // No longer needed, getDefaultProvider handles it
const CONTRACT_ADDRESS = '0xebe3cD114c9B0cD3ab7e6436B8E468031Af6fe83';
const ACCOUNT_TO_CHECK = '0xfAF7e0962B79675cd046C4c0bF41beEb27FCc5C8'; // Example: the pre-mint receiver

// --- IMPORTANT: Replace with the actual private key of ACCOUNT_TO_CHECK ---
const ACCOUNT_PRIVATE_KEY = '0xc36c70ce2dfa1a6773371180f5b551d9b2620d80c1a96d57e3872ec49d2ee9c3'; 
// Ensure this private key corresponds to ACCOUNT_TO_CHECK for decryption to work.
// Example: If ACCOUNT_TO_CHECK is 0xfAF7e0962B79675cd046C4c0bF41beEb27FCc5C8,
// then ACCOUNT_PRIVATE_KEY must be the private key of 0xfAF7e0962B79675cd046C4c0bF41beEb27FCc5C8.

const AES_KEY = '919beb03f125ba8a4835467aa166926f';

// Updated ABI
const contractAbi = [
  { // balanceOf(address) - for displaying the raw encrypted value if needed
    "inputs": [
      {
        "internalType": "address",
        "name": "account",
        "type": "address"
      }
    ],
    "name": "balanceOf",
    "outputs": [
      {
        "internalType": "uint256", // This is the raw ciphertext, not directly decryptable with user AES key alone
        "name": "",
        "type": "uint256"
      }
    ],
    "stateMutability": "view",
    "type": "function"
  },
  { // balanceOf() - for the connected account to get its decryptable balance
    "inputs": [],
    "name": "balanceOf",
    "outputs": [
      { // This should be ItUint64StructOutput or similar based on PrivateERC20.sol
        // Assuming it returns the structure needed for decryption
        // Based on IPrivateERC20.ts, the type is actually just bigint for the non-view version.
        // This is unusual. PrivateERC20.sol might have a different internal function that returns the struct,
        // or the SDK handles this by intercepting the call.
        // Let's check PrivateERC20.ts typechain output.
        // The IPrivateERC20.ts shows: "balanceOf()": TypedContractMethod<[], [bigint], "nonpayable">;
        // This implies it still returns a bigint, but perhaps the SDK's Wallet.call automatically decrypts if possible.
        // For now, let's assume it returns a type that wallet.decryptValue can handle.
        // The PrivateERC20.ts (not IPrivateERC20.ts) might have more specific return types for SDK interaction.
        // The `wallet.decryptValue` seems to take a ciphertext (bigint or string).
        "internalType": "uint256", // Or ItUint64Struct if that's what it actually returns
        "name": "",
        "type": "uint256" // Let's keep this as uint256 and see if decryptValue can handle it
      }
    ],
    "stateMutability": "nonpayable", // As per IPrivateERC20.ts
    "type": "function"
  },
  {
    "inputs": [],
    "name": "decimals",
    "outputs": [
        {
            "internalType": "uint8",
            "name": "",
            "type": "uint8"
        }
    ],
    "stateMutability": "view",
    "type": "function"
  }
];

async function main() {
  if (ACCOUNT_PRIVATE_KEY === 'YOUR_PRIVATE_KEY_FOR_ACCOUNT_TO_CHECK') {
    console.error("Please replace 'YOUR_PRIVATE_KEY_FOR_ACCOUNT_TO_CHECK' with the actual private key.");
    return;
  }

  const provider = getDefaultProvider(CotiNetwork.Testnet);
  
  // Create a wallet instance for the account whose balance we want to decrypt
  const wallet = new Wallet(ACCOUNT_PRIVATE_KEY, provider);
  
  // Set the AES key for this wallet.
  // The SDK might require the AES key to be in a specific format (e.g., Uint8Array or hex string without 0x)
  // Assuming hex string is fine, but may need adjustment.
  wallet.setAesKey(AES_KEY); 
  // Alternatively, if onboarding info (RSA keys, txHash) is available and preferred:
  // wallet.setRsaKeyPair({publicKey: ..., privateKey: ...});
  // wallet.setOnboardTxHash(...);
  // await wallet.generateOrRecoverAes(); // This would recover the AES key

  console.log(`Wallet address: ${wallet.address}`);
  if (wallet.address.toLowerCase() !== ACCOUNT_TO_CHECK.toLowerCase()) {
      console.warn(`WARNING: The private key provided does not correspond to ACCOUNT_TO_CHECK (${ACCOUNT_TO_CHECK}). Decryption will likely fail or be incorrect.`);
  }

  const contract = new Contract(CONTRACT_ADDRESS, contractAbi, wallet); // Use wallet as signer for non-view calls

  try {
    console.log(`Fetching and attempting to decrypt balance for ${ACCOUNT_TO_CHECK} from contract ${CONTRACT_ADDRESS}...`);

    // Call the balanceOf() function (no arguments)
    // This should be called by the owner of the balance (the wallet)
    // The return type from IPrivateERC20.ts is `bigint`.
    // Let's assume the `wallet.decryptValue` method can handle this.
    const encryptedBalanceStruct = await contract.balanceOf(); // Calls balanceOf()
    console.log(`Encrypted balance data from balanceOf(): ${encryptedBalanceStruct.toString()}`);

    // Decrypt the balance
    // The `decryptValue` in `wallet.test.ts` took `inputText.ciphertext`.
    // If `encryptedBalanceStruct` is already just the ciphertext (bigint), this might work.
    const decryptedBalance = await wallet.decryptValue(encryptedBalanceStruct);
    // If encryptedBalanceStruct is an object like { ciphertext: '...' }, use encryptedBalanceStruct.ciphertext

    console.log(`Decrypted (raw, numeric): ${decryptedBalance}`);

    let decimals = 6;
    try {
        const tokenDecimals = await contract.decimals(); // Use the contract instance connected to the wallet
        decimals = Number(tokenDecimals);
        console.log(`Token decimals: ${decimals}`);
    } catch (e) {
        console.warn(`Could not fetch decimals, defaulting to ${decimals}. Error: ${e}`);
    }
    
    // The decryptedBalance from `wallet.decryptValue` is usually a string representing the number.
    console.log(`Formatted decrypted balance: ${formatUnits(decryptedBalance, decimals)} PERCI`);

  } catch (error) {
    console.error('Error fetching or decrypting balance:', error);
    console.log("Please ensure ACCOUNT_PRIVATE_KEY is correct and corresponds to ACCOUNT_TO_CHECK, and that the AES_KEY is correct for that account.");
    console.log("Also, ensure the account has been properly onboarded on the COTI network.");
  }
}

main().catch(console.error); 