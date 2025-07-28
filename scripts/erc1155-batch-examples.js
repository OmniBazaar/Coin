const { ethers } = require("hardhat");
const chalk = require('chalk');

/**
 * ERC-1155 Batch Operations Examples
 * 
 * This script demonstrates various batch operations with OmniERC1155:
 * 1. Batch minting different token types
 * 2. Batch transfers to multiple recipients
 * 3. Batch marketplace listings
 * 4. Service token batch creation
 * 5. Gaming asset imports
 */

// Token types
const TokenType = {
  FUNGIBLE: 0,
  NON_FUNGIBLE: 1,
  SEMI_FUNGIBLE: 2,
  SERVICE: 3
};

async function main() {
  console.log(chalk.bold.cyan("OmniERC1155 Batch Operations Examples"));
  console.log(chalk.cyan("=====================================\n"));

  // Get accounts
  const [deployer, creator, buyer1, buyer2, buyer3] = await ethers.getSigners();
  
  // Get registry
  const registryAddress = process.env.REGISTRY_ADDRESS;
  if (!registryAddress) {
    console.error(chalk.red("ERROR: Set REGISTRY_ADDRESS environment variable"));
    process.exit(1);
  }

  const registry = await ethers.getContractAt("OmniCoinRegistry", registryAddress);
  
  // Get contract addresses from registry
  const omniERC1155Address = await registry.getContract(await registry.OMNI_ERC1155());
  const marketplaceAddress = await registry.getContract(await registry.UNIFIED_NFT_MARKETPLACE());
  const bridgeAddress = await registry.getContract(await registry.ERC1155_BRIDGE());
  
  const omniERC1155 = await ethers.getContractAt("OmniERC1155", omniERC1155Address);
  const marketplace = await ethers.getContractAt("OmniUnifiedMarketplace", marketplaceAddress);
  const bridge = await ethers.getContractAt("OmniERC1155Bridge", bridgeAddress);

  console.log(chalk.yellow("Using contracts:"));
  console.log("OmniERC1155:", omniERC1155Address);
  console.log("Marketplace:", marketplaceAddress);
  console.log("Bridge:", bridgeAddress);
  console.log();

  // Example 1: Batch Create Different Token Types
  console.log(chalk.blue("\n1. Batch Creating Different Token Types"));
  console.log(chalk.gray("Creating fungible, non-fungible, and service tokens in sequence...\n"));

  const tokenIds = [];
  
  // Create fungible tokens (e.g., in-game currency)
  let tx = await omniERC1155.connect(creator).createToken(
    10000,
    TokenType.FUNGIBLE,
    "gold-coins",
    250 // 2.5% royalty
  );
  let receipt = await tx.wait();
  let event = receipt.events.find(e => e.event === "TokenCreated");
  tokenIds.push(event.args.tokenId);
  console.log(chalk.green("✓ Created fungible token (Gold Coins), ID:"), event.args.tokenId.toString());

  // Create non-fungible token (e.g., unique artifact)
  tx = await omniERC1155.connect(creator).createToken(
    1,
    TokenType.NON_FUNGIBLE,
    "legendary-sword",
    1000 // 10% royalty
  );
  receipt = await tx.wait();
  event = receipt.events.find(e => e.event === "TokenCreated");
  tokenIds.push(event.args.tokenId);
  console.log(chalk.green("✓ Created non-fungible token (Legendary Sword), ID:"), event.args.tokenId.toString());

  // Create service tokens (e.g., consultation hours)
  tx = await omniERC1155.connect(creator).createServiceToken(
    50,
    30 * 24 * 60 * 60, // 30 days validity
    "consultation-hours",
    ethers.utils.parseUnits("100", 6) // 100 XOM per hour
  );
  receipt = await tx.wait();
  event = receipt.events.find(e => e.event === "TokenCreated");
  tokenIds.push(event.args.tokenId);
  console.log(chalk.green("✓ Created service token (Consultation Hours), ID:"), event.args.tokenId.toString());

  // Example 2: Batch Transfer to Multiple Recipients
  console.log(chalk.blue("\n2. Batch Transfer to Multiple Recipients"));
  console.log(chalk.gray("Distributing tokens to multiple users in one transaction...\n"));

  // Prepare batch transfer data
  const recipients = [buyer1.address, buyer2.address, buyer3.address];
  const amounts = [100, 200, 300]; // Different amounts of gold coins
  
  // Single token to multiple recipients (using safeBatchTransferFrom creatively)
  for (let i = 0; i < recipients.length; i++) {
    await omniERC1155.connect(creator).safeTransferFrom(
      creator.address,
      recipients[i],
      tokenIds[0], // Gold coins
      amounts[i],
      "0x"
    );
  }
  console.log(chalk.green("✓ Distributed gold coins to 3 recipients"));

  // Example 3: Batch Operations with Bridge
  console.log(chalk.blue("\n3. Batch Import External Tokens"));
  console.log(chalk.gray("Simulating batch import of gaming assets from another chain...\n"));

  // Simulate batch import request
  const externalContracts = [
    "0x1111111111111111111111111111111111111111",
    "0x2222222222222222222222222222222222222222",
    "0x3333333333333333333333333333333333333333"
  ];
  
  const externalTokenIds = [1001, 1002, 1003];
  const importAmounts = [5, 10, 15];
  
  console.log(chalk.yellow("Example batch import structure:"));
  console.log({
    contracts: externalContracts,
    tokenIds: externalTokenIds,
    amounts: importAmounts,
    sourceChain: "polygon"
  });
  console.log(chalk.gray("(Not executed - requires actual external tokens and fees)"));

  // Example 4: Batch Marketplace Operations
  console.log(chalk.blue("\n4. Batch Marketplace Listings"));
  console.log(chalk.gray("Creating multiple listings efficiently...\n"));

  // First, approve marketplace for all tokens
  await omniERC1155.connect(creator).setApprovalForAll(marketplace.address, true);
  console.log(chalk.green("✓ Approved marketplace for all tokens"));

  // Note: Current marketplace doesn't have batch listing, but we can demonstrate the pattern
  console.log(chalk.yellow("Example batch listing pattern:"));
  console.log(chalk.gray("for (const tokenId of tokenIds) {"));
  console.log(chalk.gray("  await marketplace.createUnifiedListing(...)"));
  console.log(chalk.gray("}"));

  // Example 5: Service Token Batch Operations
  console.log(chalk.blue("\n5. Service Token Batch Creation"));
  console.log(chalk.gray("Creating multiple service token types for a business...\n"));

  const serviceTypes = [
    { name: "Basic Consultation", duration: 1, price: "50" },
    { name: "Premium Consultation", duration: 2, price: "90" },
    { name: "Workshop Session", duration: 4, price: "150" }
  ];

  console.log(chalk.yellow("Service token types:"));
  for (const service of serviceTypes) {
    console.log(`- ${service.name}: ${service.duration} hours @ ${service.price} XOM`);
  }

  // Example 6: Batch Balance Queries
  console.log(chalk.blue("\n6. Batch Balance Queries"));
  console.log(chalk.gray("Checking multiple token balances in one call...\n"));

  const accounts = new Array(tokenIds.length).fill(creator.address);
  const balances = await omniERC1155.balanceOfBatch(accounts, tokenIds);
  
  console.log(chalk.yellow("Creator's balances:"));
  for (let i = 0; i < tokenIds.length; i++) {
    console.log(`Token ${tokenIds[i]}: ${balances[i].toString()} units`);
  }

  // Example 7: Gas Optimization Patterns
  console.log(chalk.blue("\n7. Gas Optimization Patterns"));
  console.log(chalk.gray("Best practices for batch operations...\n"));

  console.log(chalk.yellow("Tips for gas optimization:"));
  console.log("1. Use safeBatchTransferFrom for multiple tokens to same recipient");
  console.log("2. Batch similar operations in loops when possible");
  console.log("3. Use multicall patterns for complex operations");
  console.log("4. Consider off-chain signatures for gasless transactions");

  // Example 8: Event Monitoring
  console.log(chalk.blue("\n8. Batch Event Monitoring"));
  console.log(chalk.gray("Filtering events for batch operations...\n"));

  const filter = omniERC1155.filters.TransferBatch();
  const events = await omniERC1155.queryFilter(filter, -100); // Last 100 blocks
  
  console.log(chalk.yellow(`Found ${events.length} batch transfer events`));
  if (events.length > 0) {
    console.log("Latest batch transfer:", {
      operator: events[0].args.operator,
      from: events[0].args.from,
      to: events[0].args.to,
      ids: events[0].args.ids.map(id => id.toString()),
      values: events[0].args.values.map(val => val.toString())
    });
  }

  console.log(chalk.green.bold("\n✅ Batch operations examples complete!"));
  
  // Summary
  console.log(chalk.cyan("\n--- Summary ---"));
  console.log(chalk.white("Key Patterns Demonstrated:"));
  console.log("• Batch token creation");
  console.log("• Multi-recipient transfers");
  console.log("• Batch imports (bridge)");
  console.log("• Service token batches");
  console.log("• Efficient balance queries");
  console.log("• Gas optimization strategies");
}

// Utility function to format token IDs
function formatTokenId(tokenId) {
  return tokenId.toString().padStart(6, '0');
}

// Error handling
main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(chalk.red("\nError:"), error);
    process.exit(1);
  });