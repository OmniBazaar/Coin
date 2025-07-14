const { ethers, upgrades } = require("hardhat");
const fs = require("fs");
const path = require("path");

// Deployment configuration
const DEPLOYMENT_CONFIG = {
    testnet: {
        name: "COTI Testnet",
        chainId: 13068200,
        rpcUrl: "https://testnet-rpc.coti.io",
        explorer: "https://testnet-explorer.coti.io",
        gasPrice: "100000000000", // 100 gwei
        gasLimit: "10000000",
        confirmations: 2
    },
    mainnet: {
        name: "COTI Mainnet",
        chainId: 7701,
        rpcUrl: "https://mainnet-rpc.coti.io",
        explorer: "https://explorer.coti.io",
        gasPrice: "50000000000", // 50 gwei
        gasLimit: "8000000",
        confirmations: 5
    }
};

class OmniCoinDeployer {
    constructor(network = 'testnet') {
        this.network = network;
        this.config = DEPLOYMENT_CONFIG[network];
        this.deployedContracts = {};
        this.deploymentLog = [];
        this.deployer = null;
    }

    async initialize() {
        console.log(`\n=== Initializing OmniCoin Deployment for ${this.config.name} ===`);
        
        // Get deployer account
        const [deployer] = await ethers.getSigners();
        this.deployer = deployer;
        
        console.log(`Deployer address: ${deployer.address}`);
        console.log(`Deployer balance: ${ethers.utils.formatEther(await deployer.getBalance())} ETH`);
        
        // Validate network
        const network = await ethers.provider.getNetwork();
        if (network.chainId !== this.config.chainId) {
            throw new Error(`Network mismatch. Expected ${this.config.chainId}, got ${network.chainId}`);
        }
        
        console.log(`Connected to ${this.config.name} (Chain ID: ${network.chainId})`);
    }

    async deployCore() {
        console.log("\n=== Phase 1: Deploying Core Contracts ===");
        
        // Deploy OmniCoin main contract
        await this.deployContract("OmniCoin", [], {
            initialSupply: ethers.utils.parseEther("1000000000"), // 1B tokens
            name: "OmniCoin",
            symbol: "XOM"
        });
        
        // Deploy configuration contract
        await this.deployContract("OmniCoinConfig", [this.deployer.address]);
        
        // Deploy reputation system
        await this.deployContract("OmniCoinReputation", [this.deployer.address]);
        
        // Deploy staking contract
        await this.deployContract("OmniCoinStaking", [this.deployer.address]);
        
        // Deploy validator registry
        await this.deployContract("ValidatorRegistry", [this.deployer.address]);
        
        console.log("✅ Core contracts deployed successfully");
    }

    async deployGovernance() {
        console.log("\n=== Phase 2: Deploying Governance Contracts ===");
        
        // Deploy multisig wallet
        await this.deployContract("OmniCoinMultisig", [this.deployer.address]);
        
        // Deploy governance contract
        await this.deployContract("OmniCoinGovernor", [this.deployer.address]);
        
        console.log("✅ Governance contracts deployed successfully");
    }

    async deployPrivacy() {
        console.log("\n=== Phase 3: Deploying Privacy Contracts ===");
        
        // Deploy privacy contract
        await this.deployContract("OmniCoinPrivacy", [this.deployer.address]);
        
        // Deploy garbled circuits contract
        await this.deployContract("OmniCoinGarbledCircuit", [this.deployer.address]);
        
        console.log("✅ Privacy contracts deployed successfully");
    }

    async deployIntegration() {
        console.log("\n=== Phase 4: Deploying Integration Contracts ===");
        
        // Deploy bridge contract
        await this.deployContract("OmniCoinBridge", [this.deployer.address]);
        
        // Deploy escrow contract
        await this.deployContract("OmniCoinEscrow", [this.deployer.address]);
        
        // Deploy payment contract (upgradeable)
        await this.deployUpgradeableContract("OmniCoinPayment", [this.deployedContracts.OmniCoin.address]);
        
        // Deploy account abstraction contract (upgradeable)
        await this.deployUpgradeableContract("OmniCoinAccount", [
            this.deployer.address, // entry point
            this.deployedContracts.OmniCoin.address
        ]);
        
        // Deploy wallet provider (upgradeable)
        await this.deployUpgradeableContract("OmniWalletProvider", [
            this.deployedContracts.OmniCoin.address
        ]);
        
        // Deploy wallet recovery (upgradeable)
        await this.deployUpgradeableContract("OmniWalletRecovery", [
            this.deployedContracts.OmniCoin.address
        ]);
        
        // Deploy batch transactions (upgradeable)
        await this.deployUpgradeableContract("OmniBatchTransactions", [
            this.deployedContracts.OmniCoin.address
        ]);
        
        console.log("✅ Integration contracts deployed successfully");
    }

    async deployMarketplace() {
        console.log("\n=== Phase 5: Deploying Marketplace Contracts ===");
        
        // Deploy NFT marketplace
        await this.deployUpgradeableContract("OmniNFTMarketplace", [
            this.deployedContracts.OmniCoin.address
        ]);
        
        // Deploy listing NFT contract
        await this.deployContract("ListingNFT", []);
        
        // Deploy DEX settlement
        await this.deployContract("DEXSettlement", []);
        
        // Deploy fee distribution
        await this.deployContract("FeeDistribution", []);
        
        console.log("✅ Marketplace contracts deployed successfully");
    }

    async deployUtilities() {
        console.log("\n=== Phase 6: Deploying Utility Contracts ===");
        
        // Deploy factory contract
        await this.deployContract("OmniCoinFactory", [this.deployer.address]);
        
        // Deploy secure send
        await this.deployContract("SecureSend", []);
        
        console.log("✅ Utility contracts deployed successfully");
    }

    async deployContract(contractName, constructorArgs = [], options = {}) {
        try {
            console.log(`\nDeploying ${contractName}...`);
            
            const ContractFactory = await ethers.getContractFactory(contractName);
            const contract = await ContractFactory.deploy(...constructorArgs, {
                gasPrice: this.config.gasPrice,
                gasLimit: this.config.gasLimit,
                ...options
            });
            
            await contract.deployed();
            
            // Wait for confirmations
            await contract.deployTransaction.wait(this.config.confirmations);
            
            this.deployedContracts[contractName] = {
                address: contract.address,
                txHash: contract.deployTransaction.hash,
                constructorArgs,
                timestamp: new Date().toISOString()
            };
            
            console.log(`✅ ${contractName} deployed at: ${contract.address}`);
            console.log(`   Transaction: ${contract.deployTransaction.hash}`);
            
            this.logDeployment(contractName, contract.address, contract.deployTransaction.hash);
            
            return contract;
            
        } catch (error) {
            console.error(`❌ Failed to deploy ${contractName}:`, error.message);
            throw error;
        }
    }

    async deployUpgradeableContract(contractName, initArgs = []) {
        try {
            console.log(`\nDeploying ${contractName} (Upgradeable)...`);
            
            const ContractFactory = await ethers.getContractFactory(contractName);
            const contract = await upgrades.deployProxy(ContractFactory, initArgs, {
                kind: 'uups',
                gasPrice: this.config.gasPrice,
                gasLimit: this.config.gasLimit
            });
            
            await contract.deployed();
            
            // Wait for confirmations
            await contract.deployTransaction.wait(this.config.confirmations);
            
            this.deployedContracts[contractName] = {
                address: contract.address,
                txHash: contract.deployTransaction.hash,
                isUpgradeable: true,
                initArgs,
                timestamp: new Date().toISOString()
            };
            
            console.log(`✅ ${contractName} (Upgradeable) deployed at: ${contract.address}`);
            console.log(`   Transaction: ${contract.deployTransaction.hash}`);
            
            this.logDeployment(contractName, contract.address, contract.deployTransaction.hash, true);
            
            return contract;
            
        } catch (error) {
            console.error(`❌ Failed to deploy ${contractName} (Upgradeable):`, error.message);
            throw error;
        }
    }

    async configureContracts() {
        console.log("\n=== Phase 7: Configuring Contracts ===");
        
        // Configure OmniCoin with deployed contracts
        const omniCoin = await ethers.getContractAt("OmniCoin", this.deployedContracts.OmniCoin.address);
        
        // Set contract addresses
        if (this.deployedContracts.OmniCoinStaking) {
            await omniCoin.setStakingContract(this.deployedContracts.OmniCoinStaking.address);
            console.log("✅ Staking contract configured");
        }
        
        if (this.deployedContracts.OmniCoinGovernor) {
            await omniCoin.setGovernorContract(this.deployedContracts.OmniCoinGovernor.address);
            console.log("✅ Governor contract configured");
        }
        
        if (this.deployedContracts.OmniCoinPrivacy) {
            await omniCoin.setPrivacyContract(this.deployedContracts.OmniCoinPrivacy.address);
            console.log("✅ Privacy contract configured");
        }
        
        if (this.deployedContracts.OmniCoinBridge) {
            await omniCoin.setBridgeContract(this.deployedContracts.OmniCoinBridge.address);
            console.log("✅ Bridge contract configured");
        }
        
        console.log("✅ Contract configuration completed");
    }

    async verifyContracts() {
        console.log("\n=== Phase 8: Verifying Contracts ===");
        
        for (const [name, contract] of Object.entries(this.deployedContracts)) {
            try {
                if (contract.isUpgradeable) {
                    console.log(`Skipping verification for upgradeable contract: ${name}`);
                    continue;
                }
                
                await hre.run("verify:verify", {
                    address: contract.address,
                    constructorArguments: contract.constructorArgs || [],
                });
                
                console.log(`✅ ${name} verified at ${contract.address}`);
                
            } catch (error) {
                console.log(`⚠️  ${name} verification failed: ${error.message}`);
            }
        }
        
        console.log("✅ Contract verification completed");
    }

    async saveDeploymentInfo() {
        const deploymentInfo = {
            network: this.network,
            config: this.config,
            deployer: this.deployer.address,
            timestamp: new Date().toISOString(),
            contracts: this.deployedContracts,
            deploymentLog: this.deploymentLog
        };
        
        const fileName = `deployment-${this.network}-${Date.now()}.json`;
        const filePath = path.join(__dirname, '..', 'deployments', fileName);
        
        // Create deployments directory if it doesn't exist
        const deploymentDir = path.dirname(filePath);
        if (!fs.existsSync(deploymentDir)) {
            fs.mkdirSync(deploymentDir, { recursive: true });
        }
        
        fs.writeFileSync(filePath, JSON.stringify(deploymentInfo, null, 2));
        
        console.log(`\n✅ Deployment information saved to: ${filePath}`);
        
        // Also save to a latest file for easy access
        const latestPath = path.join(deploymentDir, `latest-${this.network}.json`);
        fs.writeFileSync(latestPath, JSON.stringify(deploymentInfo, null, 2));
        
        return filePath;
    }

    logDeployment(contractName, address, txHash, isUpgradeable = false) {
        this.deploymentLog.push({
            contractName,
            address,
            txHash,
            isUpgradeable,
            timestamp: new Date().toISOString(),
            explorerUrl: `${this.config.explorer}/tx/${txHash}`
        });
    }

    async estimateGasCosts() {
        console.log("\n=== Gas Cost Estimation ===");
        
        // This is a simplified estimation - in real deployment, you'd want more accurate estimates
        const estimatedGasUsage = {
            "Core Contracts": 5000000,
            "Governance": 2000000,
            "Privacy": 3000000,
            "Integration": 8000000,
            "Marketplace": 4000000,
            "Utilities": 2000000,
            "Configuration": 1000000
        };
        
        const totalGas = Object.values(estimatedGasUsage).reduce((sum, gas) => sum + gas, 0);
        const gasPrice = parseInt(this.config.gasPrice);
        const totalCost = (totalGas * gasPrice) / 1e18;
        
        console.log("Estimated gas costs:");
        Object.entries(estimatedGasUsage).forEach(([category, gas]) => {
            const cost = (gas * gasPrice) / 1e18;
            console.log(`  ${category}: ${gas.toLocaleString()} gas (~${cost.toFixed(6)} ETH)`);
        });
        
        console.log(`\nTotal estimated cost: ${totalGas.toLocaleString()} gas (~${totalCost.toFixed(6)} ETH)`);
        
        return { totalGas, totalCost, gasPrice };
    }

    async runDeployment() {
        try {
            console.log("🚀 Starting OmniCoin Deployment Pipeline");
            
            await this.initialize();
            await this.estimateGasCosts();
            
            // Deploy in phases
            await this.deployCore();
            await this.deployGovernance();
            await this.deployPrivacy();
            await this.deployIntegration();
            await this.deployMarketplace();
            await this.deployUtilities();
            
            // Configure contracts
            await this.configureContracts();
            
            // Verify contracts (optional for testnet)
            if (this.network === 'mainnet') {
                await this.verifyContracts();
            }
            
            // Save deployment info
            await this.saveDeploymentInfo();
            
            console.log("\n🎉 Deployment completed successfully!");
            console.log(`\n📋 Deployment Summary:`);
            console.log(`Network: ${this.config.name}`);
            console.log(`Deployer: ${this.deployer.address}`);
            console.log(`Contracts deployed: ${Object.keys(this.deployedContracts).length}`);
            console.log(`\n📖 Contract addresses:`);
            
            Object.entries(this.deployedContracts).forEach(([name, info]) => {
                console.log(`  ${name}: ${info.address}`);
            });
            
        } catch (error) {
            console.error("❌ Deployment failed:", error);
            throw error;
        }
    }
}

// Main deployment function
async function main() {
    const network = process.env.NETWORK || 'testnet';
    const deployer = new OmniCoinDeployer(network);
    await deployer.runDeployment();
}

// Export for testing
module.exports = { OmniCoinDeployer, DEPLOYMENT_CONFIG };

// Run if called directly
if (require.main === module) {
    main()
        .then(() => process.exit(0))
        .catch((error) => {
            console.error(error);
            process.exit(1);
        });
} 