async function main() {
  const [signer0, signer1, signer2] = await ethers.getSigners();
  
  const omniCore = await ethers.getContractAt('OmniCore', '0x70e0bA845a1A0F2DA3359C97E0285013525FFC49');
  
  console.log('Registering validators in OmniCore...');
  
  // Register validator-1 (using account 0)
  const tx1 = await omniCore.connect(signer0).registerNode(
    '/ip4/localhost/tcp/14001/p2p/NodeID-f2ecdaf6f715acb4918d34d9dc611e7bbfd37e9c',
    'http://localhost:3001',
    'ws://localhost:8101',
    'local-dev',
    0 // gateway node
  );
  await tx1.wait();
  console.log('✓ Validator-1 registered');
  
  // Register validator-2 (using account 1)  
  const tx2 = await omniCore.connect(signer1).registerNode(
    '/ip4/localhost/tcp/14002/p2p/NodeID-9810a686d9541bb01b40ae2a6d208127e234ad8c',
    'http://localhost:3002',
    'ws://localhost:8102',
    'local-dev',
    0 // gateway node
  );
  await tx2.wait();
  console.log('✓ Validator-2 registered');
  
  // Register validator-3 (using account 2)
  const tx3 = await omniCore.connect(signer2).registerNode(
    '/ip4/localhost/tcp/14003/p2p/NodeID-05fbe176488c462881502c150ee0ea336f44d162',
    'http://localhost:3003',
    'ws://localhost:8103',
    'local-dev',
    0 // gateway node
  );
  await tx3.wait();
  console.log('✓ Validator-3 registered');
  
  // Check registered nodes
  const count = await omniCore.getActiveNodeCount(0);
  console.log('\nTotal gateway nodes registered:', count.toString());
}

main()
  .then(() => process.exit(0))
  .catch(error => {
    console.error(error);
    process.exit(1);
  });
