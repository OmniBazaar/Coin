import { ethers } from 'hardhat';
const PROXY = '0xE2e1b926AE798647DDfD7E5A95862C6C2E3C6F67';
async function main() {
    const [admin] = await ethers.getSigners();
    const addr = process.env.USER_ADDRESS || '';
    const amt = process.env.AMOUNT || '1750';
    const amount = ethers.parseEther(amt);
    
    const RewardManager = await ethers.getContractFactory('OmniRewardManager');
    const contract = RewardManager.attach(PROXY);
    
    console.log('Setting pending bonus for:', addr);
    console.log('Amount:', amt, 'XOM');
    
    const tx = await contract.setPendingReferralBonus(addr, amount);
    const receipt = await tx.wait();
    console.log('Set in tx:', receipt?.hash);
    
    const pending = await contract.getPendingReferralBonus(addr);
    console.log('Verified pending:', ethers.formatEther(pending), 'XOM');
}
main().catch(console.error);
