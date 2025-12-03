import { ethers } from 'hardhat';

const REWARD_MANAGER_ADDRESS = '0xE2e1b926AE798647DDfD7E5A95862C6C2E3C6F67';

async function main() {
  console.log('Checking OmniRewardManager storage slots...\n');

  // Check several storage slots to understand layout
  for (let i = 0; i < 20; i++) {
    const slot = '0x' + i.toString(16).padStart(64, '0');
    const value = await ethers.provider.getStorage(REWARD_MANAGER_ADDRESS, slot);
    if (value !== '0x' + '0'.repeat(64)) {
      console.log(`Slot ${i}: ${value}`);
    }
  }

  // Try a raw call to registrationContract
  console.log('\n\nTrying raw call to registrationContract...');
  const registrationContractSelector = ethers.id('registrationContract()').slice(0, 10);
  console.log('Function selector:', registrationContractSelector);

  try {
    const result = await ethers.provider.call({
      to: REWARD_MANAGER_ADDRESS,
      data: registrationContractSelector
    });
    console.log('Raw result:', result);
    if (result !== '0x') {
      const address = '0x' + result.slice(-40);
      console.log('Decoded address:', address);
    }
  } catch (e) {
    console.log('Error:', (e as Error).message);
  }

  // Try a raw call to oddaoAddress
  console.log('\nTrying raw call to oddaoAddress...');
  const oddaoSelector = ethers.id('oddaoAddress()').slice(0, 10);
  console.log('Function selector:', oddaoSelector);

  try {
    const result = await ethers.provider.call({
      to: REWARD_MANAGER_ADDRESS,
      data: oddaoSelector
    });
    console.log('Raw result:', result);
    if (result !== '0x') {
      const address = '0x' + result.slice(-40);
      console.log('Decoded address:', address);
    }
  } catch (e) {
    console.log('Error:', (e as Error).message);
  }

  // Check if maybe there's a different getter name
  console.log('\nChecking contract bytecode for function selectors...');
  const bytecode = await ethers.provider.getCode(REWARD_MANAGER_ADDRESS);
  console.log('Bytecode length:', bytecode.length);

  // Check for selector presence
  const selectors = [
    { name: 'registrationContract()', selector: ethers.id('registrationContract()').slice(2, 10) },
    { name: 'oddaoAddress()', selector: ethers.id('oddaoAddress()').slice(2, 10) },
    { name: 'omniCoin()', selector: ethers.id('omniCoin()').slice(2, 10) },
    { name: 'paused()', selector: ethers.id('paused()').slice(2, 10) }
  ];

  for (const { name, selector } of selectors) {
    const found = bytecode.toLowerCase().includes(selector.toLowerCase());
    console.log(`${name}: ${selector} - ${found ? 'FOUND' : 'NOT FOUND'}`);
  }
}

main().catch(console.error);
