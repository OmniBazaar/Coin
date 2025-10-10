import { ethers } from "hardhat";
import * as fs from "fs";
import * as path from "path";

/**
 * Deploy ValidatorRegistry contract to Fuji testnet or mainnet
 * @dev This script deploys the validator registry for blockchain-based bootstrap
 */
async function main() {
    console.log("========================================");
    console.log("ValidatorRegistry Deployment Script");
    console.log("========================================");

    // Get network information
    const network = await ethers.provider.getNetwork();
    const networkName = network.name || "unknown";
    const chainId = network.chainId;

    console.log(`Network: ${networkName} (Chain ID: ${chainId})`);

    // Verify we're on the correct network
    if (chainId !== 43113n && chainId !== 43114n) {
        console.error(`Error: Wrong network! Expected Fuji (43113) or Mainnet (43114), got ${chainId}`);

        if (chainId === 31337n) {
            console.error("You're connected to Hardhat local network.");
            console.error("To deploy to Fuji testnet, run:");
            console.error("  npx hardhat run scripts/deploy-validator-registry.ts --network fuji");
        }

        throw new Error(`Wrong network! Expected Avalanche network, got chain ID ${chainId}`);
    }

    const isMainnet = chainId === 43114n;
    const networkDisplayName = isMainnet ? "Avalanche Mainnet" : "Fuji Testnet";

    console.log(`Deploying to: ${networkDisplayName}`);
    console.log("");

    // Get deployer account
    const [deployer] = await ethers.getSigners();
    const deployerAddress = await deployer.getAddress();

    console.log("Deployer address:", deployerAddress);

    // Check deployer balance
    const balance = await ethers.provider.getBalance(deployerAddress);
    const balanceInAvax = ethers.formatEther(balance);

    console.log("Deployer balance:", balanceInAvax, "AVAX");

    if (balance < ethers.parseEther("0.1")) {
        console.error("Error: Insufficient AVAX balance!");
        console.error("You need at least 0.1 AVAX to deploy the contract.");

        if (!isMainnet) {
            console.error("");
            console.error("Get test AVAX from the faucet:");
            console.error("  https://faucet.avax.network/");
        }

        throw new Error("Insufficient AVAX balance for deployment");
    }

    console.log("");
    console.log("Deploying ValidatorRegistry contract...");
    console.log("========================================");

    try {
        // Get the contract factory
        const ValidatorRegistry = await ethers.getContractFactory("ValidatorRegistry");

        // Estimate deployment gas
        const deployTransaction = ValidatorRegistry.getDeployTransaction();
        const estimatedGas = await ethers.provider.estimateGas({
            ...deployTransaction,
            from: deployerAddress
        });

        // Get current gas price
        const feeData = await ethers.provider.getFeeData();
        const gasPrice = feeData.gasPrice || ethers.parseUnits("25", "gwei");

        // Calculate deployment cost
        const deploymentCost = estimatedGas * gasPrice;
        const costInAvax = ethers.formatEther(deploymentCost);

        console.log("Estimated gas:", estimatedGas.toString());
        console.log("Gas price:", ethers.formatUnits(gasPrice, "gwei"), "gwei");
        console.log("Estimated deployment cost:", costInAvax, "AVAX");
        console.log("");

        // Deploy the contract
        console.log("Sending deployment transaction...");
        const registry = await ValidatorRegistry.deploy();

        // Wait for deployment
        console.log("Waiting for deployment confirmation...");
        await registry.waitForDeployment();

        const contractAddress = await registry.getAddress();
        const deploymentReceipt = await registry.deploymentTransaction()?.wait();

        console.log("");
        console.log("✅ ValidatorRegistry deployed successfully!");
        console.log("========================================");
        console.log("Contract address:", contractAddress);

        if (deploymentReceipt) {
            console.log("Transaction hash:", deploymentReceipt.hash);
            console.log("Block number:", deploymentReceipt.blockNumber);
            console.log("Gas used:", deploymentReceipt.gasUsed.toString());

            const actualCost = deploymentReceipt.gasUsed * deploymentReceipt.gasPrice;
            console.log("Actual cost:", ethers.formatEther(actualCost), "AVAX");
        }

        // Save deployment information
        const deploymentInfo = {
            network: isMainnet ? "mainnet" : "fuji",
            chainId: chainId.toString(),
            address: contractAddress,
            deployer: deployerAddress,
            deployedAt: new Date().toISOString(),
            blockNumber: deploymentReceipt?.blockNumber || 0,
            transactionHash: deploymentReceipt?.hash || "",
            gasUsed: deploymentReceipt?.gasUsed.toString() || "0",
            gasPrice: deploymentReceipt?.gasPrice.toString() || "0"
        };

        // Create deployments directory if it doesn't exist
        const deploymentsDir = path.join(__dirname, "../deployments");
        if (!fs.existsSync(deploymentsDir)) {
            fs.mkdirSync(deploymentsDir, { recursive: true });
        }

        // Save deployment file
        const deploymentFileName = isMainnet
            ? "mainnet-validator-registry.json"
            : "fuji-validator-registry.json";
        const deploymentPath = path.join(deploymentsDir, deploymentFileName);

        fs.writeFileSync(deploymentPath, JSON.stringify(deploymentInfo, null, 2));

        console.log("");
        console.log("Deployment info saved to:", deploymentPath);
        console.log("");

        // Provide verification instructions
        console.log("========================================");
        console.log("Next Steps:");
        console.log("========================================");
        console.log("");
        console.log("1. Verify the contract on Snowtrace:");
        console.log(`   npx hardhat verify --network ${isMainnet ? "mainnet" : "fuji"} ${contractAddress}`);
        console.log("");
        console.log("2. View on Snowtrace:");

        if (isMainnet) {
            console.log(`   https://snowtrace.io/address/${contractAddress}`);
        } else {
            console.log(`   https://testnet.snowtrace.io/address/${contractAddress}`);
        }

        console.log("");
        console.log("3. Update environment variables:");
        console.log(`   export VALIDATOR_REGISTRY_ADDRESS=${contractAddress}`);
        console.log(`   export AVALANCHE_NETWORK=${isMainnet ? "mainnet" : "fuji"}`);
        console.log("");
        console.log("4. Configure validators to use this registry:");
        console.log("   - Set ENABLE_BLOCKCHAIN_BOOTSTRAP=true");
        console.log(`   - Set VALIDATOR_REGISTRY_ADDRESS=${contractAddress}`);
        console.log("");
        console.log("========================================");
        console.log("Deployment Complete!");
        console.log("========================================");

        return contractAddress;

    } catch (error) {
        console.error("");
        console.error("❌ Deployment failed!");
        console.error("Error:", error);
        throw error;
    }
}

// Execute deployment
main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });