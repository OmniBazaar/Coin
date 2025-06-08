import { ethers, formatUnits } from "ethers";
import hre from "hardhat";
// import { Wallet, getDefaultProvider, CotiNetwork } from "@coti-io/coti-sdk-typescript";
import Wallet from "@coti-io/coti-sdk-typescript";
import * as FullCotiSDK from "@coti-io/coti-sdk-typescript";

// Attempt to import low-level crypto functions directly from the SDK's likely build path
import { decryptUint, encodeKey } from "@coti-io/coti-sdk-typescript/dist/crypto_utils";
// If the above fails, we might need to log the entire import of "@coti-io/coti-sdk-typescript"
// or "@coti-io/coti-sdk-typescript/dist" to see its structure.

// Import Wallet, getDefaultProvider, CotiNetwork from @coti-io/coti-ethers
import * as CotiEthers from "@coti-io/coti-ethers";

// --- Configuration ---
const CONTRACT_ADDRESS = '0xebe3cD114c9B0cD3ab7e6436B8E468031Af6fe83';
const ACCOUNT_TO_CHECK = '0xfAF7e0962B79675cd046C4c0bF41beEb27FCc5C8';

// --- IMPORTANT: Replace with the actual private key of ACCOUNT_TO_CHECK ---
const ACCOUNT_PRIVATE_KEY = '0xc36c70ce2dfa1a6773371180f5b551d9b2620d80c1a96d57e3872ec49d2ee9c3'; 
// Ensure this private key corresponds to ACCOUNT_TO_CHECK for decryption to work.

const AES_KEY = '919beb03f125ba8a4835467aa166926f';

// ABI based on IPrivateERC20__factory.ts
const balanceOfAddressReturnsCtUint64Fragment = {
    "inputs": [
      {
        "internalType": "address",
        "name": "account", // Parameter name from factory
        "type": "address"
      }
    ],
    "name": "balanceOf",
    "outputs": [
      { 
        "internalType": "ctUint64", // As per IPrivateERC20__factory.ts
        "name": "",    // Output is unnamed in factory
        "type": "uint256" // ctUint64 is an alias for uint256
      }
    ],
    "stateMutability": "view", 
    "type": "function"
};

const decimalsAbiFragment = {
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
};

const focusedAbi = [
    balanceOfAddressReturnsCtUint64Fragment,
    decimalsAbiFragment
];

async function main() {
  const provider = CotiEthers.getDefaultProvider(CotiEthers.CotiNetwork.Testnet);
  const cotiWallet = new CotiEthers.Wallet(ACCOUNT_PRIVATE_KEY, provider);
  cotiWallet.setAesKey(AES_KEY); 

  console.log(`COTI Wallet address: ${cotiWallet.address}`);
  const perciToken = new ethers.Contract(CONTRACT_ADDRESS, focusedAbi, cotiWallet); 

  try {
    console.log(`Fetching ctUint64 balance for ${ACCOUNT_TO_CHECK} from contract ${CONTRACT_ADDRESS}...`);

    // This call should return a BigInt (representing the ctUint64)
    const ctBalance_uint256: bigint = await perciToken["balanceOf(address)"](ACCOUNT_TO_CHECK);
    
    console.log("Returned ctBalance (uint256 representing ctUint64) from balanceOf(address):", ctBalance_uint256.toString());

    let numericDecryptedBalance: bigint | undefined;

    if (typeof (cotiWallet as any).decryptValue === 'function') {
        console.log("Attempting decryption with cotiWallet.decryptValue()...");
        try {
            // Pass the raw result from the contract call DIRECTLY to decryptValue, like in the test.
            const decryptedResult = await (cotiWallet as any).decryptValue(ctBalance_uint256);
            
            if (typeof decryptedResult === 'bigint') {
                numericDecryptedBalance = decryptedResult;
            } else if (typeof decryptedResult === 'string' && decryptedResult.match(/^\d+$/)) { // Check if it's a string of digits
                numericDecryptedBalance = BigInt(decryptedResult);
            } else if (typeof decryptedResult === 'number') { // Should not happen for large balances
                 numericDecryptedBalance = BigInt(decryptedResult);
            } else {
                console.log("decryptValue returned an unexpected type or non-numeric string:", typeof decryptedResult, decryptedResult);
            }
            console.log(`Value from cotiWallet.decryptValue(): ${numericDecryptedBalance !== undefined ? numericDecryptedBalance.toString() : 'undefined'}`);
        } catch (decryptionError) {
            console.error("Error during cotiWallet.decryptValue():", decryptionError);
        }
    } else {
        if (!ctBalance_uint256) console.log("ctBalance_uint256 is null or undefined.");
        if (typeof (cotiWallet as any).decryptValue !== 'function') console.log("decryptValue method not found on cotiWallet.");
    }

    if (numericDecryptedBalance === undefined) {
        throw new Error("Failed to obtain and decrypt balance. Check logs for ctBalance_uint256 and decryption errors.");
    }

    let decimals = 6; 
    try {
        const tokenDecimalsBigInt = await perciToken.decimals();
        decimals = Number(tokenDecimalsBigInt);
        console.log(`Token decimals from contract: ${decimals}`);
    } catch (e) {
        console.warn(`Could not fetch decimals from contract, defaulting to ${decimals}. Error: ${(e as Error).message}`);
    }
    
    console.log(`Formatted decrypted balance: ${formatUnits(numericDecryptedBalance, decimals)} PERCI`);

  } catch (error) {
    console.error('Error in main process:', error);
    if (error instanceof Error) {
        console.error("Error Details:", error.message, (error as any).data ? (error as any).data : "");
    }
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("Unhandled error in main:", error);
    process.exit(1);
  });