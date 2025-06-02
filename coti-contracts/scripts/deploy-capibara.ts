import hre from "hardhat";
import { setupAccounts } from "./utils/accounts"; // Assuming you have this utility

async function main() {
    const [owner] = await setupAccounts(); // Assuming setupAccounts returns an array of signers

    const CAPIBARAFactory = await hre.ethers.getContractFactory("CAPIBARA");

    // Deploy the CAPIBARA contract
    // The CAPIBARA constructor does not take any arguments
    const capibaraToken = await CAPIBARAFactory
        .connect(owner)
        .deploy();

    await capibaraToken.waitForDeployment();

    console.log("CAPIBARA Token deployed to:", await capibaraToken.getAddress());
}

main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
