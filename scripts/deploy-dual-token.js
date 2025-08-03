const hre = require("hardhat");

async function main() {
    console.log("Deploying dual-token OmniCoin system...");
    
    const [deployer] = await hre.ethers.getSigners();
    console.log("Deploying with account:", deployer.address);
    
    // 1. Deploy Registry
    const Registry = await hre.ethers.getContractFactory("OmniCoinRegistry");
    const registry = await Registry.deploy(deployer.address);
    await registry.deployed();
    console.log("Registry deployed to:", registry.address);
    
    // 2. Deploy OmniCoin (public)
    const OmniCoin = await hre.ethers.getContractFactory("OmniCoin");
    const omniCoin = await OmniCoin.deploy(registry.address);
    await omniCoin.deployed();
    console.log("OmniCoin (XOM) deployed to:", omniCoin.address);
    
    // 3. Deploy PrivateOmniCoin
    const PrivateOmniCoin = await hre.ethers.getContractFactory("PrivateOmniCoin");
    const privateOmniCoin = await PrivateOmniCoin.deploy(registry.address);
    await privateOmniCoin.deployed();
    console.log("PrivateOmniCoin (pXOM) deployed to:", privateOmniCoin.address);
    
    // 4. Deploy PrivacyFeeManager
    const treasury = deployer.address; // For testing
    const PrivacyFeeManager = await hre.ethers.getContractFactory("PrivacyFeeManager");
    const feeManager = await PrivacyFeeManager.deploy(
        omniCoin.address,
        privateOmniCoin.address,
        treasury,
        deployer.address
    );
    await feeManager.deployed();
    console.log("PrivacyFeeManager deployed to:", feeManager.address);
    
    // 5. Deploy Bridge
    const Bridge = await hre.ethers.getContractFactory("OmniCoinPrivacyBridge");
    const bridge = await Bridge.deploy(
        omniCoin.address,
        privateOmniCoin.address,
        feeManager.address,
        registry.address
    );
    await bridge.deployed();
    console.log("OmniCoinPrivacyBridge deployed to:", bridge.address);
    
    // 6. Register contracts in registry
    console.log("\nRegistering contracts...");
    await registry.registerContract(
        hre.ethers.utils.keccak256(hre.ethers.utils.toUtf8Bytes("OMNICOIN")),
        omniCoin.address,
        "OmniCoin public token"
    );
    
    await registry.registerContract(
        hre.ethers.utils.keccak256(hre.ethers.utils.toUtf8Bytes("PRIVATE_OMNICOIN")),
        privateOmniCoin.address,
        "PrivateOmniCoin encrypted token"
    );
    
    await registry.registerContract(
        hre.ethers.utils.keccak256(hre.ethers.utils.toUtf8Bytes("OMNICOIN_BRIDGE")),
        bridge.address,
        "Privacy bridge"
    );
    
    // 7. Configure permissions
    console.log("\nConfiguring permissions...");
    
    // Grant bridge role on private token
    await privateOmniCoin.grantRole(
        hre.ethers.utils.keccak256(hre.ethers.utils.toUtf8Bytes("BRIDGE_ROLE")),
        bridge.address
    );
    
    // Grant bridge role on public token for burnFrom
    await omniCoin.grantRole(
        hre.ethers.utils.keccak256(hre.ethers.utils.toUtf8Bytes("BRIDGE_ROLE")),
        bridge.address
    );
    
    // Grant fee manager role to bridge
    await feeManager.grantRole(
        hre.ethers.utils.keccak256(hre.ethers.utils.toUtf8Bytes("FEE_MANAGER_ROLE")),
        bridge.address
    );
    
    console.log("\nDeployment complete!");
    console.log("=====================");
    console.log("Registry:", registry.address);
    console.log("OmniCoin (XOM):", omniCoin.address);
    console.log("PrivateOmniCoin (pXOM):", privateOmniCoin.address);
    console.log("PrivacyFeeManager:", feeManager.address);
    console.log("OmniCoinPrivacyBridge:", bridge.address);
    console.log("=====================");
    
    // Test the system
    console.log("\nTesting basic operations...");
    
    // Check balances
    const deployerBalance = await omniCoin.balanceOf(deployer.address);
    console.log("Deployer XOM balance:", hre.ethers.utils.formatUnits(deployerBalance, 6));
    
    // Test conversion to private
    const convertAmount = hre.ethers.utils.parseUnits("100", 6); // 100 XOM
    
    // Approve bridge
    await omniCoin.approve(bridge.address, convertAmount);
    console.log("Approved bridge to spend", hre.ethers.utils.formatUnits(convertAmount, 6), "XOM");
    
    // Convert to private
    const tx = await bridge.convertToPrivate(convertAmount);
    await tx.wait();
    console.log("Converted to private!");
    
    // Check fee
    const fee = await bridge.bridgeFee();
    const expectedPrivate = convertAmount.mul(10000 - fee).div(10000);
    console.log("Expected pXOM received:", hre.ethers.utils.formatUnits(expectedPrivate, 6));
    
    console.log("\n✅ Dual-token system deployed and tested successfully!");
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });