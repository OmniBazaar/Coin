import hre from "hardhat";
import { setupAccounts } from "./utils/accounts"; // Assuming you have this utility

async function main() {
    const [owner] = await setupAccounts(); // Assuming setupAccounts returns an array of signers

    const PERCIFactory = await hre.ethers.getContractFactory("PERCI");

    // Placeholder for the MPC-encrypted initial supply.
    // You MUST replace these with the actual encrypted value and signature.
    const encryptedPredefinedSupply = {
        ciphertext: "0x01", // Placeholder: Replace with actual ctUint64 (uint256 like) value
        signature: "0x"     // Placeholder: Replace with actual bytes signature
    };

    // Deploy the PERCI contract
    const perciToken = await PERCIFactory
        .connect(owner)
        .deploy(encryptedPredefinedSupply);

    await perciToken.waitForDeployment();

    console.log("PERCI Token deployed to:", await perciToken.getAddress());
}

main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
