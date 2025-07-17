const { ethers } = require("hardhat");
const fs = require("fs");
const path = require("path");

// Monitoring configuration
const MONITORING_CONFIG = {
    checkInterval: 60000, // 1 minute
    alertThresholds: {
        gasPrice: ethers.utils.parseUnits("100", "gwei"),
        blockTime: 30000, // 30 seconds
        failedTransactions: 5,
        suspiciousActivity: 10
    },
    notifications: {
        email: process.env.ALERT_EMAIL || "admin@omnicoin.com",
        webhook: process.env.ALERT_WEBHOOK || null,
        slack: process.env.SLACK_WEBHOOK || null
    }
};

class OmniCoinMonitor {
    constructor(network = 'testnet') {
        this.network = network;
        this.deployedContracts = {};
        this.monitoringData = {
            startTime: new Date().toISOString(),
            alerts: [],
            metrics: {
                transactions: 0,
                failedTransactions: 0,
                totalGasUsed: 0,
                avgGasPrice: 0,
                activeUsers: new Set(),
                contractCalls: {}
            }
        };
        this.isRunning = false;
    }

    async initialize() {
        console.log(`\n=== Initializing OmniCoin Monitor for ${this.network} ===`);
        
        // Load deployment info
        await this.loadDeploymentInfo();
        
        // Initialize contract instances
        await this.initializeContracts();
        
        console.log(`Monitor initialized for ${Object.keys(this.deployedContracts).length} contracts`);
    }

    async loadDeploymentInfo() {
        try {
            const deploymentPath = path.join(__dirname, '..', 'deployments', `latest-${this.network}.json`);
            if (fs.existsSync(deploymentPath)) {
                const deploymentInfo = JSON.parse(fs.readFileSync(deploymentPath, 'utf8'));
                this.deployedContracts = deploymentInfo.contracts;
                console.log(`Loaded deployment info for ${Object.keys(this.deployedContracts).length} contracts`);
            } else {
                console.warn(`No deployment info found for ${this.network}`);
            }
        } catch (error) {
            console.error("Error loading deployment info:", error);
        }
    }

    async initializeContracts() {
        this.contracts = {};
        
        for (const [name, info] of Object.entries(this.deployedContracts)) {
            try {
                this.contracts[name] = await ethers.getContractAt(name, info.address);
                console.log(`✅ Connected to ${name} at ${info.address}`);
            } catch (error) {
                console.warn(`⚠️  Could not connect to ${name}:`, error.message);
            }
        }
    }

    async monitorSystemHealth() {
        console.log("\n=== System Health Check ===");
        
        // Check network connectivity
        const network = await ethers.provider.getNetwork();
        const blockNumber = await ethers.provider.getBlockNumber();
        const gasPrice = await ethers.provider.getGasPrice();
        
        console.log(`Network: ${network.name} (${network.chainId})`);
        console.log(`Block: ${blockNumber}`);
        console.log(`Gas Price: ${ethers.utils.formatUnits(gasPrice, 'gwei')} gwei`);
        
        // Check if gas price is too high
        if (gasPrice.gt(MONITORING_CONFIG.alertThresholds.gasPrice)) {
            this.sendAlert("HIGH_GAS_PRICE", `Gas price is ${ethers.utils.formatUnits(gasPrice, 'gwei')} gwei`);
        }
        
        // Check contract balances
        await this.checkContractBalances();
        
        // Check for contract upgrades
        await this.checkContractUpgrades();
        
        return { network, blockNumber, gasPrice };
    }

    async checkContractBalances() {
        console.log("\n=== Contract Balance Check ===");
        
        for (const [name, contract] of Object.entries(this.contracts)) {
            try {
                const balance = await ethers.provider.getBalance(contract.address);
                const formattedBalance = ethers.utils.formatEther(balance);
                
                console.log(`${name}: ${formattedBalance} ETH`);
                
                // Alert if balance is too low for operational contracts
                if (balance.lt(ethers.utils.parseEther("0.1")) && 
                    ['OmniCoinPayment', 'OmniCoinBridge', 'OmniCoinEscrow'].includes(name)) {
                    this.sendAlert("LOW_BALANCE", `${name} balance is ${formattedBalance} ETH`);
                }
                
            } catch (error) {
                console.warn(`Could not check balance for ${name}:`, error.message);
            }
        }
    }

    async checkContractUpgrades() {
        console.log("\n=== Upgrade Status Check ===");
        
        const upgradeableContracts = Object.entries(this.deployedContracts)
            .filter(([name, info]) => info.isUpgradeable);
        
        for (const [name, info] of upgradeableContracts) {
            try {
                // Check if contract is still upgradeable
                const contract = this.contracts[name];
                if (contract && typeof contract.proxiableUUID === 'function') {
                    const uuid = await contract.proxiableUUID();
                    console.log(`${name} UUID: ${uuid}`);
                }
            } catch (error) {
                console.warn(`Could not check upgrade status for ${name}:`, error.message);
            }
        }
    }

    async monitorTransactions() {
        console.log("\n=== Transaction Monitoring ===");
        
        // Get recent blocks
        const latestBlock = await ethers.provider.getBlockNumber();
        const blocks = [];
        
        for (let i = 0; i < 10; i++) {
            const blockNumber = latestBlock - i;
            const block = await ethers.provider.getBlockWithTransactions(blockNumber);
            blocks.push(block);
        }
        
        // Analyze transactions
        let totalTransactions = 0;
        let failedTransactions = 0;
        let totalGasUsed = 0;
        let contractInteractions = 0;
        
        for (const block of blocks) {
            totalTransactions += block.transactions.length;
            
            for (const tx of block.transactions) {
                // Check if transaction is to our contracts
                const isOurContract = Object.values(this.deployedContracts)
                    .some(info => info.address.toLowerCase() === tx.to?.toLowerCase());
                
                if (isOurContract) {
                    contractInteractions++;
                    
                    // Get transaction receipt
                    try {
                        const receipt = await ethers.provider.getTransactionReceipt(tx.hash);
                        totalGasUsed += receipt.gasUsed.toNumber();
                        
                        if (receipt.status === 0) {
                            failedTransactions++;
                        }
                        
                        // Track active users
                        this.monitoringData.metrics.activeUsers.add(tx.from);
                        
                    } catch (error) {
                        console.warn(`Could not get receipt for ${tx.hash}:`, error.message);
                    }
                }
            }
        }
        
        console.log(`Total transactions: ${totalTransactions}`);
        console.log(`Contract interactions: ${contractInteractions}`);
        console.log(`Failed transactions: ${failedTransactions}`);
        console.log(`Total gas used: ${totalGasUsed.toLocaleString()}`);
        console.log(`Active users: ${this.monitoringData.metrics.activeUsers.size}`);
        
        // Update metrics
        this.monitoringData.metrics.transactions = totalTransactions;
        this.monitoringData.metrics.failedTransactions = failedTransactions;
        this.monitoringData.metrics.totalGasUsed = totalGasUsed;
        
        // Check for alerts
        if (failedTransactions > MONITORING_CONFIG.alertThresholds.failedTransactions) {
            this.sendAlert("HIGH_FAILURE_RATE", `${failedTransactions} failed transactions detected`);
        }
        
        return {
            totalTransactions,
            contractInteractions,
            failedTransactions,
            totalGasUsed,
            activeUsers: this.monitoringData.metrics.activeUsers.size
        };
    }

    async monitorContractEvents() {
        console.log("\n=== Contract Event Monitoring ===");
        
        // Monitor key events from each contract
        for (const [name, contract] of Object.entries(this.contracts)) {
            try {
                // Get recent events
                const latestBlock = await ethers.provider.getBlockNumber();
                const fromBlock = latestBlock - 100; // Last 100 blocks
                
                const events = await contract.queryFilter("*", fromBlock, latestBlock);
                
                if (events.length > 0) {
                    console.log(`${name}: ${events.length} events`);
                    
                    // Analyze events for suspicious activity
                    const suspiciousEvents = events.filter(event => {
                        // Define suspicious patterns
                        return event.event === 'Transfer' && 
                               event.args && 
                               event.args.value && 
                               event.args.value.gt(ethers.utils.parseEther("1000000"));
                    });
                    
                    if (suspiciousEvents.length > 0) {
                        this.sendAlert("SUSPICIOUS_ACTIVITY", 
                            `${suspiciousEvents.length} large transfers detected in ${name}`);
                    }
                }
                
            } catch (error) {
                console.warn(`Could not monitor events for ${name}:`, error.message);
            }
        }
    }

    async monitorSecurity() {
        console.log("\n=== Security Monitoring ===");
        
        // Check for ownership changes
        for (const [name, contract] of Object.entries(this.contracts)) {
            try {
                if (typeof contract.owner === 'function') {
                    const owner = await contract.owner();
                    console.log(`${name} owner: ${owner}`);
                    
                    // Store initial owner for comparison
                    if (!this.initialOwners) {
                        this.initialOwners = {};
                    }
                    
                    if (!this.initialOwners[name]) {
                        this.initialOwners[name] = owner;
                    } else if (this.initialOwners[name] !== owner) {
                        this.sendAlert("OWNERSHIP_CHANGED", 
                            `${name} owner changed from ${this.initialOwners[name]} to ${owner}`);
                        this.initialOwners[name] = owner;
                    }
                }
                
                // Check paused status
                if (typeof contract.paused === 'function') {
                    const isPaused = await contract.paused();
                    if (isPaused) {
                        this.sendAlert("CONTRACT_PAUSED", `${name} is paused`);
                    }
                }
                
            } catch (error) {
                console.warn(`Could not check security for ${name}:`, error.message);
            }
        }
    }

    async sendAlert(type, message) {
        const alert = {
            type,
            message,
            timestamp: new Date().toISOString(),
            network: this.network
        };
        
        console.log(`🚨 ALERT [${type}]: ${message}`);
        
        this.monitoringData.alerts.push(alert);
        
        // Send notifications
        if (MONITORING_CONFIG.notifications.webhook) {
            await this.sendWebhookNotification(alert);
        }
        
        if (MONITORING_CONFIG.notifications.slack) {
            await this.sendSlackNotification(alert);
        }
        
        // Save alert to file
        this.saveAlerts();
    }

    async sendWebhookNotification(alert) {
        try {
            const response = await fetch(MONITORING_CONFIG.notifications.webhook, {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                },
                body: JSON.stringify({
                    title: `OmniCoin Alert: ${alert.type}`,
                    message: alert.message,
                    timestamp: alert.timestamp,
                    network: alert.network
                }),
            });
            
            if (!response.ok) {
                console.warn('Failed to send webhook notification');
            }
        } catch (error) {
            console.warn('Error sending webhook notification:', error.message);
        }
    }

    async sendSlackNotification(alert) {
        try {
            const response = await fetch(MONITORING_CONFIG.notifications.slack, {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                },
                body: JSON.stringify({
                    text: `🚨 *OmniCoin Alert*\n*Type:* ${alert.type}\n*Message:* ${alert.message}\n*Network:* ${alert.network}\n*Time:* ${alert.timestamp}`
                }),
            });
            
            if (!response.ok) {
                console.warn('Failed to send Slack notification');
            }
        } catch (error) {
            console.warn('Error sending Slack notification:', error.message);
        }
    }

    saveAlerts() {
        const alertsPath = path.join(__dirname, '..', 'monitoring', `alerts-${this.network}.json`);
        
        // Create monitoring directory if it doesn't exist
        const monitoringDir = path.dirname(alertsPath);
        if (!fs.existsSync(monitoringDir)) {
            fs.mkdirSync(monitoringDir, { recursive: true });
        }
        
        fs.writeFileSync(alertsPath, JSON.stringify(this.monitoringData, null, 2));
    }

    async generateReport() {
        console.log("\n=== Generating Monitoring Report ===");
        
        const report = {
            network: this.network,
            timestamp: new Date().toISOString(),
            uptime: Date.now() - new Date(this.monitoringData.startTime).getTime(),
            contracts: Object.keys(this.deployedContracts).length,
            alerts: this.monitoringData.alerts.length,
            metrics: {
                ...this.monitoringData.metrics,
                activeUsers: this.monitoringData.metrics.activeUsers.size
            },
            recentAlerts: this.monitoringData.alerts.slice(-10)
        };
        
        const reportPath = path.join(__dirname, '..', 'monitoring', `report-${this.network}-${Date.now()}.json`);
        fs.writeFileSync(reportPath, JSON.stringify(report, null, 2));
        
        console.log(`Report saved to: ${reportPath}`);
        return report;
    }

    async runMonitoringCycle() {
        console.log(`\n🔍 Running monitoring cycle at ${new Date().toISOString()}`);
        
        try {
            // Run all monitoring checks
            await this.monitorSystemHealth();
            await this.monitorTransactions();
            await this.monitorContractEvents();
            await this.monitorSecurity();
            
            console.log("✅ Monitoring cycle completed");
            
        } catch (error) {
            console.error("❌ Monitoring cycle failed:", error);
            this.sendAlert("MONITORING_ERROR", `Monitoring cycle failed: ${error.message}`);
        }
    }

    async startMonitoring() {
        console.log("🚀 Starting OmniCoin Monitoring System");
        
        await this.initialize();
        
        this.isRunning = true;
        
        // Run initial cycle
        await this.runMonitoringCycle();
        
        // Set up periodic monitoring
        this.monitoringInterval = setInterval(async () => {
            if (this.isRunning) {
                await this.runMonitoringCycle();
            }
        }, MONITORING_CONFIG.checkInterval);
        
        console.log(`✅ Monitoring system started (checking every ${MONITORING_CONFIG.checkInterval / 1000} seconds)`);
        
        // Generate periodic reports
        this.reportInterval = setInterval(async () => {
            if (this.isRunning) {
                await this.generateReport();
            }
        }, 300000); // Every 5 minutes
        
        return this;
    }

    async stopMonitoring() {
        console.log("🛑 Stopping monitoring system");
        
        this.isRunning = false;
        
        if (this.monitoringInterval) {
            clearInterval(this.monitoringInterval);
        }
        
        if (this.reportInterval) {
            clearInterval(this.reportInterval);
        }
        
        // Generate final report
        await this.generateReport();
        
        console.log("✅ Monitoring system stopped");
    }
}

// Main function
async function main() {
    const network = process.env.NETWORK || 'testnet';
    const monitor = new OmniCoinMonitor(network);
    
    // Handle graceful shutdown
    process.on('SIGINT', async () => {
        console.log('\nReceived SIGINT, stopping monitoring...');
        await monitor.stopMonitoring();
        process.exit(0);
    });
    
    process.on('SIGTERM', async () => {
        console.log('\nReceived SIGTERM, stopping monitoring...');
        await monitor.stopMonitoring();
        process.exit(0);
    });
    
    await monitor.startMonitoring();
}

// Export for testing
module.exports = { OmniCoinMonitor, MONITORING_CONFIG };

// Run if called directly
if (require.main === module) {
    main().catch(console.error);
} 