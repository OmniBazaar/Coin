// Query validator registrations from OmniCore contract
const { ethers } = require('ethers');

const OMNICORE_ADDRESS = '0x5FC8d32690cc91D4c39d9d3abcBD16989F875707';
const RPC_URL = 'http://localhost:8545';

const ABI = [
    "function getTotalNodeCount() external view returns (uint256)",
    "function getActiveNodeCount(uint8) external view returns (uint256)",
    "function getNodeInfo(address) external view returns (string memory multiaddr, string memory httpEndpoint, string memory wsEndpoint, string memory region, uint8 nodeType, bool active, uint256 lastUpdate)",
    "function getActiveNodesWithinTime(uint8 nodeType, uint256 timeWindowSeconds) external view returns (address[] addresses, tuple(string multiaddr, string httpEndpoint, string wsEndpoint, string region, uint8 nodeType, bool active, uint256 lastUpdate)[] infos)"
];

async function main() {
    const provider = new ethers.JsonRpcProvider(RPC_URL);
    const contract = new ethers.Contract(OMNICORE_ADDRESS, ABI, provider);

    console.log('==== OmniCore Validator Registry Query ====\n');

    // Query total nodes
    const totalNodes = await contract.getTotalNodeCount();
    console.log(`Total registered nodes: ${totalNodes}`);

    // Query active gateway nodes (type 0)
    const activeGateways = await contract.getActiveNodeCount(0);
    console.log(`Active gateway validators: ${activeGateways}\n`);

    // If there are nodes, query their info
    if (totalNodes > 0n) {
        console.log('==== Node Information ====');
        const validator1 = '0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266';

        try {
            const info = await contract.getNodeInfo(validator1);
            console.log(`\nValidator 1 (${validator1}):`);
            console.log(`  multiaddr: ${info[0]}`);
            console.log(`  httpEndpoint: ${info[1]}`);
            console.log(`  wsEndpoint: ${info[2]}`);
            console.log(`  region: ${info[3]}`);
            console.log(`  nodeType: ${info[4]}`);
            console.log(`  active: ${info[5]}`);
            console.log(`  lastUpdate: ${info[6]}`);
        } catch (error) {
            console.log(`\nNo info found for ${validator1}`);
        }
    }

    // Try querying active nodes within 7 days
    console.log('\n==== Querying Active Nodes (7 day window) ====');
    try {
        const [addresses, infos] = await contract.getActiveNodesWithinTime(0, 7 * 24 * 60 * 60);
        console.log(`Found ${addresses.length} active gateway validators:`);
        for (let i = 0; i < addresses.length; i++) {
            console.log(`\n${i + 1}. ${addresses[i]}`);
            console.log(`   HTTP: ${infos[i][1]}`);
            console.log(`   WS: ${infos[i][2]}`);
        }
    } catch (error) {
        console.log(`Query failed: ${error.message}`);
        if (error.data) {
            console.log(`Error data: ${error.data}`);
        }
    }
}

main().catch(console.error);
