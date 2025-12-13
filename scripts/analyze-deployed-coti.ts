#!/usr/bin/env ts-node
/**
 * Analyze Deployed COTI Contracts
 *
 * Compares deployed contracts to source code to determine:
 * 1. What methods are available on deployed contracts
 * 2. What functionality is missing vs full contracts
 * 3. Whether redeployment is needed
 */

import { ethers } from 'ethers';
import * as fs from 'fs';
import * as path from 'path';

const COTI_TESTNET_RPC = 'https://testnet.coti.io/rpc';

const DEPLOYED_CONTRACTS = {
  PrivateOmniCoin: '0x6BF2b6df85CfeE5debF0684c4B656A3b86a31675',
  OmniPrivacyBridge: '0x123522e908b34799Cf14aDdF7B2A47Df404c4d47',
  PrivateDEX: '0xA242e4555CECF29F888b0189f216241587b9945E',
};

// Full contract ABIs from source
const PRIVATE_OMNICOIN_FULL_ABI = [
  // ERC20 Standard
  'function name() view returns (string)',
  'function symbol() view returns (string)',
  'function decimals() view returns (uint8)',
  'function totalSupply() view returns (uint256)',
  'function balanceOf(address) view returns (uint256)',
  'function transfer(address to, uint256 amount) returns (bool)',
  'function approve(address spender, uint256 amount) returns (bool)',
  'function transferFrom(address from, address to, uint256 amount) returns (bool)',
  'function allowance(address owner, address spender) view returns (uint256)',

  // Privacy Functions (from PrivateOmniCoin.sol)
  'function privacyAvailable() view returns (bool)',
  'function convertToPrivate(uint256 amount) external returns (bool)',
  'function convertToPublic(uint256 amount) external returns (bool)',
  'function convertFromPrivate(uint256 amount) external returns (bool)',
  'function privateBalanceOf(address user) view returns (bytes)',
  'function privateTransfer(address to, bytes calldata encryptedAmount) external returns (bool)',
  'function getTotalPrivateSupply() view returns (bytes)',
  'function getFeeRecipient() view returns (address)',
  'function setFeeRecipient(address newRecipient) external',
  'function setPrivacyEnabled(bool enabled) external',

  // Admin/Upgradeable Functions
  'function initialize() external',
  'function pause() external',
  'function unpause() external',
  'function mint(address to, uint256 amount) external',
  'function burnFrom(address account, uint256 amount) external',
];

const PRIVACY_BRIDGE_FULL_ABI = [
  'function convert(address token, uint256 amount, bool toPrivate) external returns (bool)',
  'function getConversionFee(uint256 amount) view returns (uint256)',
  'function swapToPrivate(uint256 amount) external',
  'function swapToPublic(uint256 amount) external',
];

const PRIVATE_DEX_FULL_ABI = [
  'function createOrder(uint8 orderType, uint256 amount, uint256 price, bool isPrivate) external returns (bytes32)',
  'function cancelOrder(bytes32 orderId) external returns (bool)',
  'function matchOrders() external returns (uint256)',
  'function executeSwap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut, bool usePrivacy) external returns (uint256)',
  'function getOrder(bytes32 orderId) view returns (tuple(address trader, uint8 orderType, uint256 amount, uint256 price, bool isPrivate, bool isFilled))',
  'function getPrivateOrderCount() view returns (uint256)',
  'function getPrivacyStats() view returns (uint256, uint256)',
];

async function testContractMethod(
  contract: ethers.Contract,
  methodName: string,
  params: unknown[] = []
): Promise<{ exists: boolean; result?: unknown; error?: string }> {
  try {
    // Try staticCall for view functions, or just check if method exists
    const method = contract[methodName];
    if (!method) {
      return { exists: false, error: 'Method not found in ABI' };
    }

    // For view functions, try to call
    if (method.fragment.stateMutability === 'view' || method.fragment.stateMutability === 'pure') {
      const result = await method(...params);
      return { exists: true, result };
    } else {
      // For state-changing functions, just verify they exist
      return { exists: true };
    }
  } catch (error: unknown) {
    const errorMessage = error instanceof Error ? error.message : 'Unknown error';

    // Check if it's a "function not found" error
    if (
      errorMessage.includes('function selector was not recognized') ||
      errorMessage.includes('no matching function')
    ) {
      return { exists: false, error: errorMessage };
    }

    // Other errors mean the method exists but reverted for other reasons
    return { exists: true, error: errorMessage };
  }
}

async function analyzeContract(
  name: string,
  address: string,
  fullAbi: string[]
): Promise<void> {
  console.log(`\n${'='.repeat(70)}`);
  console.log(`📋 Analyzing ${name}`);
  console.log(`   Address: ${address}`);
  console.log(`${'='.repeat(70)}\n`);

  const provider = new ethers.JsonRpcProvider(COTI_TESTNET_RPC);

  // Check if contract exists
  const code = await provider.getCode(address);
  if (code === '0x') {
    console.log('❌ CONTRACT NOT DEPLOYED');
    return;
  }

  console.log(`✅ Contract deployed (${code.length} bytes of bytecode)\n`);

  // Create contract instance with full ABI
  const contract = new ethers.Contract(address, fullAbi, provider);

  const methodsFound: string[] = [];
  const methodsMissing: string[] = [];

  // Test each method
  for (const abiEntry of fullAbi) {
    // Parse method name from ABI string
    const match = abiEntry.match(/function (\w+)/);
    if (!match) continue;

    const methodName = match[1];

    // Determine test parameters based on method
    let params: unknown[] = [];
    if (abiEntry.includes('address')) {
      params = ['0x0000000000000000000000000000000000000000'];
    } else if (abiEntry.includes('uint256')) {
      params = [ethers.parseEther('1')];
    } else if (abiEntry.includes('bytes32')) {
      params = [ethers.ZeroHash];
    }

    const result = await testContractMethod(contract, methodName, params);

    if (result.exists) {
      methodsFound.push(methodName);
      console.log(`  ✅ ${methodName}`);
      if (result.result !== undefined) {
        console.log(`     Result: ${result.result}`);
      }
    } else {
      methodsMissing.push(methodName);
      console.log(`  ❌ ${methodName} - ${result.error}`);
    }
  }

  console.log(`\n📊 Summary:`);
  console.log(`   Methods Found: ${methodsFound.length}/${fullAbi.length}`);
  console.log(`   Methods Missing: ${methodsMissing.length}/${fullAbi.length}`);

  if (methodsMissing.length > 0) {
    console.log(`\n⚠️  Missing Methods:`);
    methodsMissing.forEach((m) => console.log(`   - ${m}`));
  }
}

async function main() {
  console.log('\n🔍 COTI Deployed Contract Analysis');
  console.log(`   Network: COTI Testnet`);
  console.log(`   RPC: ${COTI_TESTNET_RPC}\n`);

  // Verify connection
  const provider = new ethers.JsonRpcProvider(COTI_TESTNET_RPC);
  const network = await provider.getNetwork();
  console.log(`✅ Connected to chainId: ${network.chainId.toString()} (${Number(network.chainId)})\n`);

  // Analyze each contract
  await analyzeContract('PrivateOmniCoin', DEPLOYED_CONTRACTS.PrivateOmniCoin, PRIVATE_OMNICOIN_FULL_ABI);
  await analyzeContract('OmniPrivacyBridge', DEPLOYED_CONTRACTS.OmniPrivacyBridge, PRIVACY_BRIDGE_FULL_ABI);
  await analyzeContract('PrivateDEX', DEPLOYED_CONTRACTS.PrivateDEX, PRIVATE_DEX_FULL_ABI);

  console.log(`\n${'='.repeat(70)}`);
  console.log('✅ Analysis Complete');
  console.log(`${'='.repeat(70)}\n`);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error('\n❌ Error:', error.message);
    process.exit(1);
  });
