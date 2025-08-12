/**
 * Coin Module Validator Integration Tests
 * 
 * Tests the integration between the Coin module and Validator blockchain services
 */

import { describe, it, expect, beforeAll, afterAll } from '@jest/globals';
import { OmniCoinValidatorClient } from '../src/utils/ValidatorClient';
import { ValidatorBlockchainService } from '../src/services/ValidatorBlockchain';
import { ValidatorStakingService } from '../src/services/ValidatorStaking';
import { TransactionRequest } from 'ethers';

describe('Coin Module Validator Integration', () => {
  let validatorClient: OmniCoinValidatorClient;
  let blockchainService: ValidatorBlockchainService;
  let stakingService: ValidatorStakingService;

  beforeAll(async () => {
    // Initialize services for testing
    validatorClient = new OmniCoinValidatorClient({
      validatorEndpoint: 'localhost',
      networkId: 'test-network',
      enableStaking: true,
      enableFeeDistribution: true
    });

    blockchainService = new ValidatorBlockchainService({
      validatorEndpoint: 'localhost',
      networkId: 'test-network',
      rpcUrl: 'http://localhost:8545',
      chainId: 1,
      blockTime: 6,
      maxBlockSize: 1000000,
      maxTransactions: 5000
    });

    stakingService = new ValidatorStakingService({
      validatorEndpoint: 'localhost',
      networkId: 'test-network',
      minimumStake: '100',
      maximumStake: '1000000',
      stakingReward: 10.0,
      unstakingPeriod: 604800,
      slashingRate: 5.0
    });

    // Initialize services
    await validatorClient.initialize();
    await blockchainService.initialize();
    await stakingService.initialize();
  });

  afterAll(async () => {
    if (validatorClient) {
      await validatorClient.disconnect();
    }
    if (blockchainService) {
      await blockchainService.shutdown();
    }
    if (stakingService) {
      await stakingService.shutdown();
    }
  });

  describe('Validator Client', () => {
    it('should initialize successfully', async () => {
      expect(validatorClient.isClientInitialized()).toBe(true);
    });

    it('should submit transactions', async () => {
      const transaction: TransactionRequest = {
        to: '0x1234567890abcdef1234567890abcdef12345678',
        value: '1000000000000000000', // 1 ETH
        gasLimit: 21000
      };

      const result = await validatorClient.submitTransaction(transaction);
      
      expect(result.success).toBe(true);
      expect(result.txHash).toBeDefined();
    });

    it('should get account balance', async () => {
      const address = '0x1234567890abcdef1234567890abcdef12345678';
      const balance = await validatorClient.getBalance(address);
      
      expect(typeof balance).toBe('string');
      expect(balance).toMatch(/^\d+$/);
    });

    it('should get account information', async () => {
      const address = '0x1234567890abcdef1234567890abcdef12345678';
      const account = await validatorClient.getAccount(address);
      
      expect(account).toBeDefined();
    });

    it('should get network status', async () => {
      const status = await validatorClient.getNetworkStatus();
      
      expect(status).toBeDefined();
      expect(status.networkId).toBe('test-network');
    });

    it('should get transaction history', async () => {
      const address = '0x1234567890abcdef1234567890abcdef12345678';
      const history = await validatorClient.getTransactionHistory(address, 10);
      
      expect(Array.isArray(history)).toBe(true);
    });

    it('should get fee distribution info', async () => {
      const feeInfo = await validatorClient.getFeeDistribution();
      
      expect(feeInfo).toBeDefined();
      expect(feeInfo.validatorShare).toBe('70%');
    });
  });

  describe('Blockchain Service', () => {
    it('should initialize successfully', async () => {
      expect(blockchainService.isServiceInitialized()).toBe(true);
    });

    it('should submit transactions', async () => {
      const transaction: TransactionRequest = {
        to: '0x1234567890abcdef1234567890abcdef12345678',
        value: '1000000000000000000', // 1 ETH
        gasLimit: 21000
      };

      const response = await blockchainService.submitTransaction(transaction);
      
      expect(response.hash).toBeDefined();
      expect(typeof response.hash).toBe('string');
    });

    it('should get transaction receipts', async () => {
      const txHash = '0xabcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890';
      const receipt = await blockchainService.getTransactionReceipt(txHash);
      
      expect(receipt).toBeDefined();
      expect(receipt?.transactionHash).toBe(txHash);
    });

    it('should get account balance', async () => {
      const address = '0x1234567890abcdef1234567890abcdef12345678';
      const balance = await blockchainService.getBalance(address);
      
      expect(typeof balance).toBe('string');
      expect(balance).toMatch(/^\d+$/);
    });

    it('should get latest block', async () => {
      const block = await blockchainService.getLatestBlock();
      
      expect(block).toBeDefined();
      expect(block.number).toBeGreaterThan(0);
      expect(block.hash).toBeDefined();
    });

    it('should get block by number', async () => {
      const blockNumber = 12345;
      const block = await blockchainService.getBlock(blockNumber);
      
      expect(block).toBeDefined();
      expect(block?.number).toBe(blockNumber);
    });

    it('should estimate gas', async () => {
      const transaction: TransactionRequest = {
        to: '0x1234567890abcdef1234567890abcdef12345678',
        value: '1000000000000000000'
      };

      const gasEstimate = await blockchainService.estimateGas(transaction);
      
      expect(typeof gasEstimate).toBe('string');
      expect(gasEstimate).toMatch(/^\d+$/);
    });

    it('should get gas price', async () => {
      const gasPrice = await blockchainService.getGasPrice();
      
      expect(typeof gasPrice).toBe('string');
      expect(gasPrice).toMatch(/^\d+$/);
    });
  });

  describe('Staking Service', () => {
    const testAddress = '0x1234567890abcdef1234567890abcdef12345678';
    const validatorAddress = '0x1234567890abcdef1234567890abcdef12345678';

    it('should initialize successfully', async () => {
      expect(stakingService.isServiceInitialized()).toBe(true);
    });

    it('should get available validators', async () => {
      const validators = await stakingService.getValidators();
      
      expect(Array.isArray(validators)).toBe(true);
      expect(validators.length).toBeGreaterThan(0);
      expect(validators[0]).toHaveProperty('address');
      expect(validators[0]).toHaveProperty('name');
      expect(validators[0]).toHaveProperty('commission');
    });

    it('should get validator by address', async () => {
      const validator = await stakingService.getValidator(validatorAddress);
      
      expect(validator).toBeDefined();
      expect(validator.address).toBe(validatorAddress);
      expect(validator.isActive).toBe(true);
    });

    it('should stake tokens', async () => {
      const amount = '1000';
      const result = await stakingService.stakeTokens(amount, validatorAddress);
      
      expect(result.success).toBe(true);
      expect(result.txHash).toBeDefined();
    });

    it('should get staking info', async () => {
      const stakingInfo = await stakingService.getStakingInfo(testAddress);
      
      expect(Array.isArray(stakingInfo)).toBe(true);
    });

    it('should calculate rewards', async () => {
      const amount = '1000';
      const duration = 86400; // 1 day
      const rewards = await stakingService.calculateRewards(amount, validatorAddress, duration);
      
      expect(typeof rewards).toBe('string');
      expect(rewards).toMatch(/^\d+$/);
    });

    it('should get rewards history', async () => {
      const history = await stakingService.getRewardsHistory(testAddress);
      
      expect(Array.isArray(history)).toBe(true);
    });

    it('should get staking stats', async () => {
      const stats = await stakingService.getStakingStats();
      
      expect(stats).toBeDefined();
      expect(stats.totalStaked).toBeDefined();
      expect(stats.totalRewards).toBeDefined();
      expect(stats.activeValidators).toBeGreaterThan(0);
    });

    it('should claim rewards', async () => {
      const result = await stakingService.claimRewards(validatorAddress);
      
      expect(result.success).toBe(true);
      expect(result.txHash).toBeDefined();
    });

    it('should unstake tokens', async () => {
      const amount = '500';
      const result = await stakingService.unstakeTokens(amount, validatorAddress);
      
      expect(result.success).toBe(true);
      expect(result.txHash).toBeDefined();
    });
  });

  describe('Error Handling', () => {
    it('should handle invalid transactions', async () => {
      const invalidTransaction: TransactionRequest = {
        to: 'invalid-address',
        value: '1000000000000000000'
      };

      await expect(blockchainService.submitTransaction(invalidTransaction))
        .rejects
        .toThrow();
    });

    it('should handle staking with insufficient amount', async () => {
      const amount = '10'; // Below minimum
      const validatorAddress = '0x1234567890abcdef1234567890abcdef12345678';

      await expect(stakingService.stakeTokens(amount, validatorAddress))
        .rejects
        .toThrow('Minimum staking amount');
    });

    it('should handle staking with inactive validator', async () => {
      const amount = '1000';
      const inactiveValidatorAddress = '0x9999999999999999999999999999999999999999';

      await expect(stakingService.stakeTokens(amount, inactiveValidatorAddress))
        .rejects
        .toThrow();
    });

    it('should handle non-existent validator', async () => {
      const nonExistentAddress = '0x0000000000000000000000000000000000000000';

      await expect(stakingService.getValidator(nonExistentAddress))
        .rejects
        .toThrow('Validator not found');
    });
  });

  describe('Configuration', () => {
    it('should return correct blockchain config', () => {
      const config = blockchainService.getConfig();
      
      expect(config.networkId).toBe('test-network');
      expect(config.chainId).toBe(1);
      expect(config.blockTime).toBe(6);
    });

    it('should return correct staking config', () => {
      const config = stakingService.getConfig();
      
      expect(config.minimumStake).toBe('100');
      expect(config.maximumStake).toBe('1000000');
      expect(config.stakingReward).toBe(10.0);
    });
  });
});