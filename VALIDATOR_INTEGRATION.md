# OmniCoin Validator Integration

This document outlines the integration between the OmniCoin module and the OmniBazaar Validator services.

## Overview

The OmniCoin module now integrates with the Validator services to provide:
- Blockchain transaction processing
- Staking operations
- Fee distribution
- Network consensus participation

## Architecture

```
OmniCoin Module
├── src/
│   ├── services/
│   │   ├── ValidatorBlockchain.ts    # Blockchain operations
│   │   └── ValidatorStaking.ts       # Staking operations
│   ├── utils/
│   │   └── ValidatorClient.ts        # Main validator client
│   └── index.ts                      # Updated exports
└── test/
    └── validator-blockchain-integration.test.ts  # Integration tests
```

## Services

### ValidatorClient

The main client for interacting with Validator services:

```typescript
import { OmniCoinValidatorClient } from '@omnicoin/validator-client';

const client = new OmniCoinValidatorClient({
  validatorEndpoint: 'https://validator.omnicoin.network',
  networkId: 'omnibazaar-mainnet',
  enableStaking: true,
  enableFeeDistribution: true
});

await client.initialize();
```

### ValidatorBlockchainService

Provides blockchain operations through the Validator:

```typescript
import { ValidatorBlockchainService } from '@omnicoin/validator-blockchain';

const blockchain = new ValidatorBlockchainService({
  validatorEndpoint: 'https://validator.omnicoin.network',
  networkId: 'omnibazaar-mainnet',
  rpcUrl: 'https://rpc.omnicoin.network',
  chainId: 1
});

// Submit transactions
const tx = await blockchain.submitTransaction({
  to: '0x...',
  value: '1000000000000000000', // 1 OMNI
  gasLimit: 21000
});

// Get account balance
const balance = await blockchain.getBalance('0x...');
```

### ValidatorStakingService

Manages staking operations:

```typescript
import { ValidatorStakingService } from '@omnicoin/validator-staking';

const staking = new ValidatorStakingService({
  validatorEndpoint: 'https://validator.omnicoin.network',
  networkId: 'omnibazaar-mainnet',
  minimumStake: '100',
  maximumStake: '1000000',
  stakingReward: 10.0
});

// Stake tokens
const result = await staking.stakeTokens('1000', validatorAddress);

// Get staking info
const info = await staking.getStakingInfo(userAddress);

// Claim rewards
const rewards = await staking.claimRewards(validatorAddress);
```

## Usage Examples

### Basic Transaction

```typescript
import { 
  OmniCoinValidatorClient, 
  ValidatorBlockchainService 
} from '@omnicoin/core';

const client = new OmniCoinValidatorClient({
  validatorEndpoint: 'localhost',
  networkId: 'test-network'
});

await client.initialize();

const result = await client.submitTransaction({
  to: '0x1234567890abcdef1234567890abcdef12345678',
  value: '1000000000000000000',
  gasLimit: 21000
});

console.log('Transaction hash:', result.txHash);
```

### Staking Operations

```typescript
import { ValidatorStakingService } from '@omnicoin/validator-staking';

const staking = new ValidatorStakingService({
  validatorEndpoint: 'localhost',
  networkId: 'test-network',
  minimumStake: '100',
  maximumStake: '1000000',
  stakingReward: 10.0
});

await staking.initialize();

// Get available validators
const validators = await staking.getValidators();

// Stake with a validator
const stakeResult = await staking.stakeTokens('1000', validators[0].address);

// Check rewards
const rewards = await staking.getRewardsHistory(userAddress);
```

### Fee Distribution

```typescript
import { OmniCoinValidatorClient } from '@omnicoin/validator-client';

const client = new OmniCoinValidatorClient({
  validatorEndpoint: 'localhost',
  networkId: 'test-network',
  enableFeeDistribution: true
});

await client.initialize();

const feeInfo = await client.getFeeDistribution();
console.log('Validator share:', feeInfo.validatorShare); // 70%
console.log('Company share:', feeInfo.companyShare);     // 20%
console.log('Development share:', feeInfo.developmentShare); // 10%
```

## Configuration

### Environment Variables

```bash
# Validator Configuration
VALIDATOR_ENDPOINT=https://validator.omnicoin.network
OMNICOIN_NETWORK_ID=omnibazaar-mainnet
OMNICOIN_RPC_URL=https://rpc.omnicoin.network
OMNICOIN_CHAIN_ID=1

# Staking Configuration
MINIMUM_STAKE=100
MAXIMUM_STAKE=1000000
STAKING_REWARD=10.0
UNSTAKING_PERIOD=604800

# Fee Distribution
VALIDATOR_FEE_SHARE=0.70
COMPANY_FEE_SHARE=0.20
DEVELOPMENT_FEE_SHARE=0.10
```

### Network Configuration

```typescript
const config = {
  validatorEndpoint: process.env.VALIDATOR_ENDPOINT || 'localhost',
  networkId: process.env.OMNICOIN_NETWORK_ID || 'test-network',
  rpcUrl: process.env.OMNICOIN_RPC_URL || 'http://localhost:8545',
  chainId: parseInt(process.env.OMNICOIN_CHAIN_ID || '1'),
  blockTime: parseInt(process.env.OMNICOIN_BLOCK_TIME || '6'),
  maxBlockSize: parseInt(process.env.OMNICOIN_MAX_BLOCK_SIZE || '1000000'),
  maxTransactions: parseInt(process.env.OMNICOIN_MAX_TRANSACTIONS || '5000')
};
```

## Testing

### Running Tests

```bash
# Run validator integration tests
npm run test:validator

# Run all tests
npm test

# Run with coverage
npm run coverage
```

### Test Structure

```
test/
└── validator-blockchain-integration.test.ts
    ├── Validator Client Tests
    ├── Blockchain Service Tests
    ├── Staking Service Tests
    ├── Error Handling Tests
    └── Configuration Tests
```

## Integration Points

### With Validator Module

- **Blockchain Service**: Direct integration with `OmniCoinBlockchain`
- **Fee Distribution**: Uses `FeeDistributionEngine` for validator rewards
- **Staking**: Integrates with validator participation scoring
- **Consensus**: Participates in Proof of Participation consensus

### With Other Modules

- **Wallet Module**: Provides transaction signing and broadcasting
- **DEX Module**: Handles settlement and fee collection
- **Bazaar Module**: Processes marketplace payments
- **KYC Module**: Manages compliance and identity verification

## API Reference

### ValidatorClient

```typescript
class OmniCoinValidatorClient {
  constructor(config: OmniCoinValidatorConfig)
  
  async initialize(): Promise<void>
  async submitTransaction(tx: TransactionRequest): Promise<TransactionResult>
  async getBalance(address: string): Promise<string>
  async getAccount(address: string): Promise<any>
  async stakeTokens(amount: string, validator: string): Promise<TransactionResult>
  async unstakeTokens(amount: string, validator: string): Promise<TransactionResult>
  async claimRewards(validator: string): Promise<TransactionResult>
  async getStakingInfo(address: string): Promise<StakingInfo[]>
  async getFeeDistribution(): Promise<any>
  async getNetworkStatus(): Promise<any>
  async disconnect(): Promise<void>
}
```

### BlockchainService

```typescript
class ValidatorBlockchainService {
  constructor(config: BlockchainConfig)
  
  async initialize(): Promise<void>
  async submitTransaction(tx: TransactionRequest): Promise<TransactionResponse>
  async getTransactionReceipt(txHash: string): Promise<TransactionReceipt>
  async getBalance(address: string): Promise<string>
  async getLatestBlock(): Promise<BlockInfo>
  async getBlock(number: number): Promise<BlockInfo>
  async estimateGas(tx: TransactionRequest): Promise<string>
  async getGasPrice(): Promise<string>
  async shutdown(): Promise<void>
}
```

### StakingService

```typescript
class ValidatorStakingService {
  constructor(config: StakingConfig)
  
  async initialize(): Promise<void>
  async stakeTokens(amount: string, validator: string): Promise<TransactionResult>
  async unstakeTokens(amount: string, validator: string): Promise<TransactionResult>
  async claimRewards(validator: string): Promise<TransactionResult>
  async getStakingInfo(address: string): Promise<StakingInfo[]>
  async getValidators(): Promise<ValidatorInfo[]>
  async getRewardsHistory(address: string): Promise<StakingReward[]>
  async getStakingStats(): Promise<StakingStats>
  async calculateRewards(amount: string, validator: string, duration: number): Promise<string>
  async shutdown(): Promise<void>
}
```

## Error Handling

All services implement comprehensive error handling:

```typescript
try {
  const result = await client.submitTransaction(tx);
  if (result.success) {
    console.log('Transaction successful:', result.txHash);
  } else {
    console.error('Transaction failed:', result.error);
  }
} catch (error) {
  console.error('Service error:', error.message);
}
```

## Performance Considerations

- **Connection Pooling**: Services maintain persistent connections to the Validator
- **Caching**: Frequently accessed data is cached for improved performance
- **Batching**: Multiple operations can be batched for efficiency
- **Async Operations**: All operations are asynchronous and non-blocking

## Security Features

- **Authentication**: All requests are authenticated with the Validator
- **Encryption**: Sensitive data is encrypted in transit and at rest
- **Validation**: Input validation prevents malicious transactions
- **Rate Limiting**: Built-in rate limiting prevents abuse

## Monitoring

The integration includes comprehensive monitoring:

- **Health Checks**: Regular health checks ensure service availability
- **Metrics**: Performance metrics are collected and reported
- **Alerts**: Automated alerts for service failures or anomalies
- **Logging**: Detailed logging for debugging and audit trails

## Deployment

### Docker Deployment

```dockerfile
FROM node:18-alpine

WORKDIR /app
COPY package*.json ./
RUN npm ci --only=production

COPY . .
RUN npm run build

EXPOSE 3000
CMD ["npm", "start"]
```

### Environment Setup

```bash
# Install dependencies
npm install

# Build the project
npm run build

# Start the service
npm start
```

## Support

For issues or questions:
- Check the [documentation](https://docs.omnicoin.io)
- Review the [integration tests](test/validator-blockchain-integration.test.ts)
- Submit issues to the [GitHub repository](https://github.com/omnibazaar/omnicoin)

## License

This integration is licensed under the MIT License. See [LICENSE](LICENSE) for details.