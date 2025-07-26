const { ethers } = require("hardhat");

/**
 * Deployment Script for OmniCoin with Registry Pattern
 * 
 * This script demonstrates:
 * 1. Optimal deployment order
 * 2. Gas cost tracking
 * 3. Registry initialization
 * 4. COTI fee estimation
 */

async function main() {
    console.log("🚀 Starting OmniCoin deployment with Registry pattern...\n");

    const [deployer] = await ethers.getSigners();
    console.log("Deploying contracts with account:", deployer.address);
    console.log("Account balance:", ethers.formatEther(await ethers.provider.getBalance(deployer.address)), "ETH\n");

    // Track deployment costs
    const deploymentCosts = {};
    let totalGasUsed = 0n;

    // Helper function to deploy and track gas
    async function deployContract(name, factory, ...args) {
        console.log(`📦 Deploying ${name}...`);
        const Contract = await ethers.getContractFactory(factory);
        const contract = await Contract.deploy(...args);
        const receipt = await contract.deploymentTransaction().wait();
        
        const gasUsed = receipt.gasUsed;
        const gasPrice = receipt.gasPrice;
        const cost = gasUsed * gasPrice;
        
        deploymentCosts[name] = {
            gasUsed: gasUsed.toString(),
            costInWei: cost.toString(),
            costInEth: ethers.formatEther(cost),
            address: await contract.getAddress()
        };
        
        totalGasUsed += gasUsed;
        
        console.log(`✅ ${name} deployed to:`, await contract.getAddress());
        console.log(`   Gas used: ${gasUsed.toString()}`);
        console.log(`   Cost: ${ethers.formatEther(cost)} ETH\n`);
        
        return contract;
    }

    try {
        // =============================================================================
        // PHASE 1: Deploy Core Infrastructure
        // =============================================================================
        console.log("=== PHASE 1: Core Infrastructure ===\n");

        // 1. Deploy Registry FIRST
        const registry = await deployContract(
            "OmniCoinRegistry",
            "OmniCoinRegistry",
            deployer.address
        );

        // 2. Deploy Config
        const config = await deployContract(
            "OmniCoinConfig",
            "OmniCoinConfig",
            deployer.address
        );

        // =============================================================================
        // PHASE 2: Deploy Core Token
        // =============================================================================
        console.log("=== PHASE 2: Core Token ===\n");

        // 3. Deploy OmniCoinCore
        const omniCoinCore = await deployContract(
            "OmniCoinCore",
            "OmniCoinCore",
            "OmniCoin",
            "OMNI",
            6, // decimals
            await config.getAddress()
        );

        // =============================================================================
        // PHASE 3: Deploy Reputation System
        // =============================================================================
        console.log("=== PHASE 3: Reputation System ===\n");

        // 4. Deploy Reputation Core first (needs module addresses)
        const reputationCore = await deployContract(
            "OmniCoinReputationCore",
            "OmniCoinReputationCore",
            deployer.address,
            await config.getAddress(),
            ethers.ZeroAddress, // identity - will update
            ethers.ZeroAddress, // trust - will update
            ethers.ZeroAddress  // referral - will update
        );

        // 5. Deploy Identity Module
        const identityModule = await deployContract(
            "OmniCoinIdentityVerification",
            "OmniCoinIdentityVerification",
            deployer.address,
            await reputationCore.getAddress()
        );

        // 6. Deploy Trust Module
        const trustModule = await deployContract(
            "OmniCoinTrustSystem",
            "OmniCoinTrustSystem",
            deployer.address,
            await reputationCore.getAddress()
        );

        // 7. Deploy Referral Module
        const referralModule = await deployContract(
            "OmniCoinReferralSystem",
            "OmniCoinReferralSystem",
            deployer.address,
            await reputationCore.getAddress()
        );

        // Update reputation core with modules
        console.log("🔗 Linking reputation modules...");
        await reputationCore.updateIdentityModule(await identityModule.getAddress());
        await reputationCore.updateTrustModule(await trustModule.getAddress());
        await reputationCore.updateReferralModule(await referralModule.getAddress());
        console.log("✅ Reputation modules linked\n");

        // =============================================================================
        // PHASE 4: Deploy Financial Contracts
        // =============================================================================
        console.log("=== PHASE 4: Financial Contracts ===\n");

        // 8. Deploy Escrow V2
        const escrow = await deployContract(
            "OmniCoinEscrowV2",
            "OmniCoinEscrowV2",
            deployer.address,
            await omniCoinCore.getAddress(),
            await reputationCore.getAddress(),
            await config.getAddress()
        );

        // 9. Deploy Payment V2
        const payment = await deployContract(
            "OmniCoinPaymentV2",
            "OmniCoinPaymentV2",
            deployer.address,
            await omniCoinCore.getAddress(),
            await config.getAddress()
        );

        // 10. Deploy Staking V2
        const staking = await deployContract(
            "OmniCoinStakingV2",
            "OmniCoinStakingV2",
            await omniCoinCore.getAddress(),
            await reputationCore.getAddress(),
            await config.getAddress()
        );

        // =============================================================================
        // PHASE 5: Deploy Governance & Utilities
        // =============================================================================
        console.log("=== PHASE 5: Governance & Utilities ===\n");

        // 11. Deploy Arbitration
        const arbitration = await deployContract(
            "OmniCoinArbitration",
            "OmniCoinArbitration",
            await omniCoinCore.getAddress(),
            await reputationCore.getAddress(),
            await escrow.getAddress()
        );

        // 12. Deploy Fee Distribution
        const feeDistribution = await deployContract(
            "FeeDistribution",
            "FeeDistribution",
            await omniCoinCore.getAddress()
        );

        // =============================================================================
        // PHASE 6: Register All Contracts
        // =============================================================================
        console.log("=== PHASE 6: Registry Configuration ===\n");

        // Prepare batch registration data
        const identifiers = [
            ethers.id("OMNICOIN_CORE"),
            ethers.id("OMNICOIN_CONFIG"),
            ethers.id("REPUTATION_CORE"),
            ethers.id("IDENTITY_VERIFICATION"),
            ethers.id("TRUST_SYSTEM"),
            ethers.id("REFERRAL_SYSTEM"),
            ethers.id("ESCROW"),
            ethers.id("PAYMENT"),
            ethers.id("STAKING"),
            ethers.id("ARBITRATION"),
            ethers.id("FEE_DISTRIBUTION")
        ];

        const addresses = [
            await omniCoinCore.getAddress(),
            await config.getAddress(),
            await reputationCore.getAddress(),
            await identityModule.getAddress(),
            await trustModule.getAddress(),
            await referralModule.getAddress(),
            await escrow.getAddress(),
            await payment.getAddress(),
            await staking.getAddress(),
            await arbitration.getAddress(),
            await feeDistribution.getAddress()
        ];

        const descriptions = [
            "Main OmniCoin token contract",
            "Configuration and parameters",
            "Reputation system coordinator",
            "KYC and identity verification",
            "DPoS voting and trust scores",
            "Referral tracking and rewards",
            "Escrow service for trades",
            "Payment streams and subscriptions",
            "Token staking and rewards",
            "Dispute resolution system",
            "Fee collection and distribution"
        ];

        console.log("📝 Registering all contracts...");
        await registry.batchRegister(identifiers, addresses, descriptions);
        console.log("✅ All contracts registered\n");

        // =============================================================================
        // DEPLOYMENT SUMMARY
        // =============================================================================
        console.log("=== DEPLOYMENT SUMMARY ===\n");
        console.log("📊 Gas Usage Report:");
        console.log("-".repeat(80));
        
        let totalCostEth = 0;
        for (const [name, data] of Object.entries(deploymentCosts)) {
            console.log(`${name.padEnd(30)} Gas: ${data.gasUsed.padEnd(10)} Cost: ${data.costInEth} ETH`);
            totalCostEth += parseFloat(data.costInEth);
        }
        
        console.log("-".repeat(80));
        console.log(`${"TOTAL".padEnd(30)} Gas: ${totalGasUsed.toString().padEnd(10)} Cost: ${totalCostEth.toFixed(6)} ETH\n`);

        // COTI Cost Estimation
        const cotiPrice = 0.12; // USD per COTI
        const ethPrice = 2000; // USD per ETH
        const totalCostUsd = totalCostEth * ethPrice;
        const totalCostCoti = totalCostUsd / cotiPrice;

        console.log("💰 COTI Deployment Cost Estimate:");
        console.log(`   Total USD: $${totalCostUsd.toFixed(2)}`);
        console.log(`   Total COTI: ${totalCostCoti.toFixed(2)} COTI`);
        console.log(`   (Assuming COTI = $${cotiPrice}, ETH = $${ethPrice})\n`);

        // Save deployment addresses
        const deployment = {
            network: (await ethers.provider.getNetwork()).name,
            timestamp: new Date().toISOString(),
            deployer: deployer.address,
            registry: await registry.getAddress(),
            contracts: deploymentCosts,
            totalGasUsed: totalGasUsed.toString(),
            totalCostEth: totalCostEth.toFixed(6),
            estimatedCotiCost: totalCostCoti.toFixed(2)
        };

        const fs = require('fs');
        fs.writeFileSync(
            'deployment-' + Date.now() + '.json',
            JSON.stringify(deployment, null, 2)
        );

        console.log("✅ Deployment complete! Addresses saved to deployment file.");

    } catch (error) {
        console.error("❌ Deployment failed:", error);
        process.exit(1);
    }
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });