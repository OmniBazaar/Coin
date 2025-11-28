const { ethers } = require('hardhat');
async function main() {
  const [deployer] = await ethers.getSigners();
  const balance = await ethers.provider.getBalance(deployer.address);
  console.log('Deployer:', deployer.address);
  console.log('AVAX Balance:', ethers.formatEther(balance));
  const omniCoin = await ethers.getContractAt('OmniCoin', '0x117defc430E143529a9067A7866A9e7Eb532203C');
  const xomBalance = await omniCoin.balanceOf(deployer.address);
  console.log('XOM Balance:', ethers.formatEther(xomBalance));
}
main().catch(console.error);
