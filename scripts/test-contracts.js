const hre = require("hardhat");

async function main() {
    const [deployer] = await hre.ethers.getSigners();
    
    try {
        // Test OmniCoin
        const omniCoin = await hre.ethers.getContractAt("OmniCoin", process.env.OMNICOIN_ADDRESS);
        const symbol = await omniCoin.symbol();
        const balance = await omniCoin.balanceOf(deployer.address);
        console.log(`OmniCoin: Symbol=${symbol}, Deployer Balance=${hre.ethers.formatEther(balance)} XOM`);
        
        // Test PrivateOmniCoin
        const privateOmniCoin = await hre.ethers.getContractAt("PrivateOmniCoin", process.env.PRIVATEOMNICOIN_ADDRESS);
        const pSymbol = await privateOmniCoin.symbol();
        const pBalance = await privateOmniCoin.balanceOf(deployer.address);
        console.log(`PrivateOmniCoin: Symbol=${pSymbol}, Deployer Balance=${hre.ethers.formatEther(pBalance)} pXOM`);
        
        // Test OmniCore
        const omniCore = await hre.ethers.getContractAt("OmniCore", process.env.OMNICORE_ADDRESS);
        const OMNICOIN_SERVICE = hre.ethers.keccak256(hre.ethers.toUtf8Bytes("OMNICOIN"));
        const omniCoinService = await omniCore.services(OMNICOIN_SERVICE);
        console.log(`OmniCore: OMNICOIN service registered at ${omniCoinService}`);
        
        console.log("SUCCESS");
    } catch (error) {
        console.error("ERROR:", error.message);
    }
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });
