import { ethers, formatUnits } from "ethers";
import hre from "hardhat";
// Import Wallet, getDefaultProvider, CotiNetwork from @coti-io/coti-ethers
import * as CotiEthers from "@coti-io/coti-ethers";

// --- Configuration ---
const CONTRACT_ADDRESS = '0x3b8424dEB61C5c7c0AfE70749B580DD39Ee6807F'; // CAPIBARA contract address
const ACCOUNT_TO_CHECK = '0xfAF7e0962B79675cd046C4c0bF41beEb27FCc5C8'; // _PRE_MINT_RECEIVER from CAPIBARA.sol

// --- IMPORTANT: Replace with the actual private key of ACCOUNT_TO_CHECK ---
// This private key MUST correspond to ACCOUNT_TO_CHECK for decryption to work.
const ACCOUNT_PRIVATE_KEY = '0xc36c70ce2dfa1a6773371180f5b551d9b2620d80c1a96d57e3872ec49d2ee9c3'; 

// --- IMPORTANT: Replace with the AES key used for the cotiWallet ---
// This key should be the one associated with the wallet derived from ACCOUNT_PRIVATE_KEY
const AES_KEY = '919beb03f125ba8a4835467aa166926f'; // Replace with your actual AES key

// ABI for balanceOf(address) -> ctUint64 and decimals -> uint8
// These are consistent with IPrivateERC20 and CAPIBARA.sol which inherits it.
const balanceOfAddressReturnsCtUint64Fragment = {
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
        "internalType": "ctUint64", 
        "name": "",    
        "type": "uint256" // ctUint64 is represented as uint256 in ABI
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
  // The CotiEthers.Wallet needs the private key of the account that will be making calls AND decrypting its own balance.
  const cotiWallet = new CotiEthers.Wallet(ACCOUNT_PRIVATE_KEY, provider);
  cotiWallet.setAesKey(AES_KEY); 

  console.log(`Using COTI Wallet address: ${cotiWallet.address} (derived from provided private key)`);
  if (cotiWallet.address.toLowerCase() !== ACCOUNT_TO_CHECK.toLowerCase()) {
    console.warn(`WARNING: The private key provided derives wallet address ${cotiWallet.address}, which is different from ACCOUNT_TO_CHECK ${ACCOUNT_TO_CHECK}. Decryption of balance for ACCOUNT_TO_CHECK might fail if this wallet (${cotiWallet.address}) does not have decryption permissions or the correct keys.`);
  }

  const capibaraToken = new ethers.Contract(CONTRACT_ADDRESS, focusedAbi, cotiWallet); 

  try {
    console.log(`Fetching encrypted CAPIBARA balance for ${ACCOUNT_TO_CHECK} from contract ${CONTRACT_ADDRESS}...`);

    // This call returns a BigInt (representing the ctUint64 ciphertext)
    const ctBalance_uint256: bigint = await capibaraToken["balanceOf(address)"](ACCOUNT_TO_CHECK);
    
    console.log("Returned encrypted balance (ctUint64 as uint256) from balanceOf(address):", ctBalance_uint256.toString());

    let numericDecryptedBalance: bigint | undefined;

    // The cotiWallet instance, initialized with the private key of ACCOUNT_TO_CHECK,
    // should be able to decrypt its own balance.
    if (typeof (cotiWallet as any).decryptValue === 'function') {
        console.log("Attempting decryption with cotiWallet.decryptValue()...");
        try {
            const decryptedResult = await (cotiWallet as any).decryptValue(ctBalance_uint256);
            
            if (typeof decryptedResult === 'bigint') {
                numericDecryptedBalance = decryptedResult;
            } else if (typeof decryptedResult === 'string' && /^\d+$/.test(decryptedResult)) { // Check if it's a string of digits
                numericDecryptedBalance = BigInt(decryptedResult);
            } else if (typeof decryptedResult === 'number') { 
                 numericDecryptedBalance = BigInt(decryptedResult);
            } else {
                console.log("cotiWallet.decryptValue returned an unexpected type or non-numeric string:", typeof decryptedResult, decryptedResult);
            }
            console.log(`Decrypted balance from cotiWallet.decryptValue(): ${numericDecryptedBalance !== undefined ? numericDecryptedBalance.toString() : 'undefined'}`);
        } catch (decryptionError) {
            console.error("Error during cotiWallet.decryptValue():", decryptionError);
            console.error("Ensure ACCOUNT_PRIVATE_KEY and AES_KEY are correct for ACCOUNT_TO_CHECK and that the associated wallet has permissions.");
        }
    } else {
        console.log("cotiWallet.decryptValue method not found. Ensure @coti-io/coti-ethers is correctly installed and wallet is initialized.");
    }

    if (numericDecryptedBalance === undefined) {
        throw new Error("Failed to obtain and/or decrypt CAPIBARA balance. Check logs for encrypted balance and any decryption errors.");
    }

    let decimals = 6; // Default CAPIBARA decimals, as per PrivateERC20.sol and CAPIBARA.sol constructor
    try {
        const tokenDecimalsBigInt = await capibaraToken.decimals();
        decimals = Number(tokenDecimalsBigInt);
        console.log(`Token decimals from CAPIBARA contract: ${decimals}`);
    } catch (e) {
        console.warn(`Could not fetch decimals from CAPIBARA contract, defaulting to ${decimals}. Error: ${(e as Error).message}`);
    }
    
    console.log(`Formatted decrypted CAPIBARA balance: ${formatUnits(numericDecryptedBalance, decimals)} CAPI`);

  } catch (error) {
    console.error('Error in main CAPIBARA balance script:', error);
    if (error instanceof Error) {
        console.error("Error Details:", error.message, (error as any).data ? (error as any).data : "");
    }
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("Unhandled error in CAPIBARA balance script:", error);
    process.exit(1);
  }); 