import { ethers } from 'hardhat';

const OMNICOIN = '0x117defc430E143529a9067A7866A9e7Eb532203C';
const OMNIRICK = '0xD0F9115e4a95b1d57F3fAb95e812F195c8989c8a';
const RICKCRITES = '0xe89d532934D7771976Ae3530292c9a854ef6449D';
const AMOUNT = ethers.parseEther('100000000');

async function main() {
    const [deployer] = await ethers.getSigners();
    const OmniCoin = await ethers.getContractFactory('OmniCoin');
    const coin = OmniCoin.attach(OMNICOIN);

    console.log('Deployer:', await deployer.getAddress());
    console.log('Balance:', ethers.formatEther(await coin.balanceOf(await deployer.getAddress())), 'XOM\n');

    console.log('Transfer to omnirick:', OMNIRICK);
    const tx1 = await coin.transfer(OMNIRICK, AMOUNT);
    await tx1.wait();
    console.log('  TX:', tx1.hash);
    console.log('  Balance:', ethers.formatEther(await coin.balanceOf(OMNIRICK)), 'XOM ✓\n');

    console.log('Transfer to rickcrites:', RICKCRITES);
    const tx2 = await coin.transfer(RICKCRITES, AMOUNT);
    await tx2.wait();
    console.log('  TX:', tx2.hash);
    console.log('  Balance:', ethers.formatEther(await coin.balanceOf(RICKCRITES)), 'XOM ✓');
}

main().catch(console.error);
