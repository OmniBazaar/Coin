import { ethers } from 'hardhat';

const OMNICOIN_ADDRESS = '0x117defc430E143529a9067A7866A9e7Eb532203C';
const OMNIRICK_ADDRESS = '0xD0F9115e4a95b1d57F3fAb95e812F195c8989c8a';
const RICKCRITES_ADDRESS = '0xe89d532934D7771976Ae3530292c9a854ef6449D';
const AMOUNT = ethers.parseEther('500000000'); // 500 million XOM

async function main() {
    const [deployer] = await ethers.getSigners();
    console.log('Deployer:', await deployer.getAddress());

    const OmniCoin = await ethers.getContractFactory('OmniCoin');
    const omniCoin = OmniCoin.attach(OMNICOIN_ADDRESS);

    // Check deployer balance
    const deployerBalance = await omniCoin.balanceOf(await deployer.getAddress());
    console.log('Deployer balance:', ethers.formatEther(deployerBalance), 'XOM');
    console.log('Amount to transfer (each):', ethers.formatEther(AMOUNT), 'XOM');
    console.log('Total to transfer:', ethers.formatEther(AMOUNT * 2n), 'XOM\n');

    // Transfer to omnirick
    console.log('Transferring to omnirick:', OMNIRICK_ADDRESS);
    const tx1 = await omniCoin.transfer(OMNIRICK_ADDRESS, AMOUNT);
    const receipt1 = await tx1.wait();
    console.log('  TX:', receipt1?.hash);
    const omnirickBalance = await omniCoin.balanceOf(OMNIRICK_ADDRESS);
    console.log('  omnirick balance:', ethers.formatEther(omnirickBalance), 'XOM ✓\n');

    // Transfer to rickcrites
    console.log('Transferring to rickcrites:', RICKCRITES_ADDRESS);
    const tx2 = await omniCoin.transfer(RICKCRITES_ADDRESS, AMOUNT);
    const receipt2 = await tx2.wait();
    console.log('  TX:', receipt2?.hash);
    const rickBalance = await omniCoin.balanceOf(RICKCRITES_ADDRESS);
    console.log('  rickcrites balance:', ethers.formatEther(rickBalance), 'XOM ✓\n');

    console.log('✓ Transfers complete!');
}

main().catch(console.error);
