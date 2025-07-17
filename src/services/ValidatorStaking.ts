/**
 * Validator Staking Service for OmniCoin
 * 
 * Provides staking operations through the Validator service
 */

import { OmniCoinValidatorClient, StakingInfo, TransactionResult } from '../utils/ValidatorClient';
import { logger } from '../../../Validator/src/utils/Logger';
import { TransactionRequest } from 'ethers';

export interface StakingConfig {
  validatorEndpoint: string;
  networkId: string;
  minimumStake: string;
  maximumStake: string;
  stakingReward: number;
  unstakingPeriod: number;
  slashingRate: number;
}

export interface ValidatorInfo {
  address: string;
  name: string;
  commission: number;
  totalStaked: string;
  participationScore: number;
  uptime: number;
  lastSeen: number;
  isActive: boolean;
}

export interface StakingReward {
  amount: string;
  validatorAddress: string;
  period: string;
  timestamp: number;
  claimed: boolean;
}

export interface StakingStats {
  totalStaked: string;
  totalRewards: string;
  activeValidators: number;
  averageReward: string;
  networkParticipation: number;
}

export class ValidatorStakingService {
  private validatorClient: OmniCoinValidatorClient;
  private config: StakingConfig;
  private isInitialized = false;

  constructor(config: StakingConfig) {
    this.config = config;
    this.validatorClient = new OmniCoinValidatorClient({
      validatorEndpoint: config.validatorEndpoint,
      networkId: config.networkId,
      enableStaking: true,
      enableFeeDistribution: true
    });
  }

  /**
   * Initialize the staking service
   */
  async initialize(): Promise<void> {
    try {
      logger.info('Initializing Validator Staking Service', {
        networkId: this.config.networkId,
        minimumStake: this.config.minimumStake
      });

      await this.validatorClient.initialize();
      this.isInitialized = true;
      
      logger.info('Validator Staking Service initialized successfully');
    } catch (error) {
      logger.error('Failed to initialize Validator Staking Service:', error);
      throw error;
    }
  }

  /**
   * Stake tokens with a validator
   */
  async stakeTokens(amount: string, validatorAddress: string): Promise<TransactionResult> {
    this.ensureInitialized();
    
    try {
      // Validate staking amount
      const amountBN = BigInt(amount);
      const minStakeBN = BigInt(this.config.minimumStake);
      const maxStakeBN = BigInt(this.config.maximumStake);

      if (amountBN < minStakeBN) {
        throw new Error(`Minimum staking amount is ${this.config.minimumStake}`);
      }

      if (amountBN > maxStakeBN) {
        throw new Error(`Maximum staking amount is ${this.config.maximumStake}`);
      }

      // Validate validator
      const validator = await this.getValidator(validatorAddress);
      if (!validator.isActive) {
        throw new Error('Validator is not active');
      }

      const result = await this.validatorClient.stakeTokens(amount, validatorAddress);
      
      if (result.success) {
        logger.info('Staking successful', {
          amount,
          validatorAddress,
          txHash: result.txHash
        });
      }

      return result;
    } catch (error) {
      logger.error('Staking failed:', error);
      throw error;
    }
  }

  /**
   * Unstake tokens from a validator
   */
  async unstakeTokens(amount: string, validatorAddress: string): Promise<TransactionResult> {
    this.ensureInitialized();
    
    try {
      // Check staking info
      const stakingInfo = await this.getStakingInfo(validatorAddress);
      const userStake = stakingInfo.find(stake => stake.validatorAddress === validatorAddress);
      
      if (!userStake) {
        throw new Error('No staking found with this validator');
      }

      const amountBN = BigInt(amount);
      const stakedBN = BigInt(userStake.amount);

      if (amountBN > stakedBN) {
        throw new Error('Insufficient staked amount');
      }

      // Check if unstaking period has passed
      if (userStake.lockedUntil > Date.now()) {
        throw new Error('Tokens are still locked');
      }

      const result = await this.validatorClient.unstakeTokens(amount, validatorAddress);
      
      if (result.success) {
        logger.info('Unstaking successful', {
          amount,
          validatorAddress,
          txHash: result.txHash
        });
      }

      return result;
    } catch (error) {
      logger.error('Unstaking failed:', error);
      throw error;
    }
  }

  /**
   * Get staking information for an address
   */
  async getStakingInfo(address: string): Promise<StakingInfo[]> {
    this.ensureInitialized();
    
    try {
      return await this.validatorClient.getStakingInfo(address);
    } catch (error) {
      logger.error('Failed to get staking info:', error);
      throw error;
    }
  }

  /**
   * Claim staking rewards
   */
  async claimRewards(validatorAddress: string): Promise<TransactionResult> {
    this.ensureInitialized();
    
    try {
      // Check if there are rewards to claim
      const stakingInfo = await this.getStakingInfo(validatorAddress);
      const userStake = stakingInfo.find(stake => stake.validatorAddress === validatorAddress);
      
      if (!userStake) {
        throw new Error('No staking found with this validator');
      }

      const rewardsBN = BigInt(userStake.rewards);
      if (rewardsBN === 0n) {
        throw new Error('No rewards to claim');
      }

      const result = await this.validatorClient.claimRewards(validatorAddress);
      
      if (result.success) {
        logger.info('Reward claiming successful', {
          validatorAddress,
          rewards: userStake.rewards,
          txHash: result.txHash
        });
      }

      return result;
    } catch (error) {
      logger.error('Reward claiming failed:', error);
      throw error;
    }
  }

  /**
   * Get available validators
   */
  async getValidators(): Promise<ValidatorInfo[]> {
    this.ensureInitialized();
    
    try {
      // TODO: Implement actual validator retrieval
      // For now, return mock data
      return [
        {
          address: '0x1234567890abcdef1234567890abcdef12345678',
          name: 'OmniBazaar Validator 1',
          commission: 5.0,
          totalStaked: '1000000',
          participationScore: 95.5,
          uptime: 99.9,
          lastSeen: Date.now(),
          isActive: true
        },
        {
          address: '0x9876543210fedcba9876543210fedcba98765432',
          name: 'OmniBazaar Validator 2',
          commission: 3.5,
          totalStaked: '750000',
          participationScore: 92.3,
          uptime: 98.7,
          lastSeen: Date.now(),
          isActive: true
        }
      ];
    } catch (error) {
      logger.error('Failed to get validators:', error);
      throw error;
    }
  }

  /**
   * Get validator by address
   */
  async getValidator(address: string): Promise<ValidatorInfo> {
    this.ensureInitialized();
    
    try {
      const validators = await this.getValidators();
      const validator = validators.find(v => v.address === address);
      
      if (!validator) {
        throw new Error('Validator not found');
      }

      return validator;
    } catch (error) {
      logger.error('Failed to get validator:', error);
      throw error;
    }
  }

  /**
   * Get staking rewards history
   */
  async getRewardsHistory(address: string): Promise<StakingReward[]> {
    this.ensureInitialized();
    
    try {
      // TODO: Implement actual rewards history retrieval
      // For now, return mock data
      return [
        {
          amount: '25.50',
          validatorAddress: '0x1234567890abcdef1234567890abcdef12345678',
          period: '2024-01-01 to 2024-01-31',
          timestamp: Date.now() - 86400000,
          claimed: true
        },
        {
          amount: '30.25',
          validatorAddress: '0x1234567890abcdef1234567890abcdef12345678',
          period: '2024-02-01 to 2024-02-28',
          timestamp: Date.now() - 172800000,
          claimed: false
        }
      ];
    } catch (error) {
      logger.error('Failed to get rewards history:', error);
      throw error;
    }
  }

  /**
   * Get staking statistics
   */
  async getStakingStats(): Promise<StakingStats> {
    this.ensureInitialized();
    
    try {
      // TODO: Implement actual stats retrieval
      // For now, return mock data
      return {
        totalStaked: '10000000',
        totalRewards: '500000',
        activeValidators: 25,
        averageReward: '12.5',
        networkParticipation: 75.3
      };
    } catch (error) {
      logger.error('Failed to get staking stats:', error);
      throw error;
    }
  }

  /**
   * Calculate staking rewards
   */
  async calculateRewards(amount: string, validatorAddress: string, duration: number): Promise<string> {
    this.ensureInitialized();
    
    try {
      const validator = await this.getValidator(validatorAddress);
      
      // Calculate rewards based on amount, duration, and validator commission
      const amountBN = BigInt(amount);
      const rewardRate = BigInt(Math.floor(this.config.stakingReward * 100)); // Convert to basis points
      const commission = BigInt(Math.floor(validator.commission * 100)); // Convert to basis points
      const durationYears = BigInt(duration) / BigInt(365 * 24 * 3600); // Convert to years
      
      const grossRewards = (amountBN * rewardRate * durationYears) / BigInt(10000);
      const commissionAmount = (grossRewards * commission) / BigInt(10000);
      const netRewards = grossRewards - commissionAmount;
      
      return netRewards.toString();
    } catch (error) {
      logger.error('Failed to calculate rewards:', error);
      throw error;
    }
  }

  /**
   * Get staking configuration
   */
  getConfig(): StakingConfig {
    return this.config;
  }

  /**
   * Shutdown the staking service
   */
  async shutdown(): Promise<void> {
    if (this.validatorClient) {
      await this.validatorClient.disconnect();
    }
    this.isInitialized = false;
    logger.info('Validator Staking Service shutdown completed');
  }

  /**
   * Check if the service is initialized
   */
  isServiceInitialized(): boolean {
    return this.isInitialized;
  }

  // Private helper methods
  private ensureInitialized(): void {
    if (!this.isInitialized) {
      throw new Error('Validator Staking Service not initialized. Call initialize() first.');
    }
  }
}

// Export default instance for easy use
export const validatorStakingService = new ValidatorStakingService({
  validatorEndpoint: process.env.VALIDATOR_ENDPOINT || 'localhost',
  networkId: process.env.OMNICOIN_NETWORK_ID || 'omnibazaar-mainnet',
  minimumStake: process.env.MINIMUM_STAKE || '100',
  maximumStake: process.env.MAXIMUM_STAKE || '1000000',
  stakingReward: parseFloat(process.env.STAKING_REWARD || '10.0'),
  unstakingPeriod: parseInt(process.env.UNSTAKING_PERIOD || '604800'), // 7 days
  slashingRate: parseFloat(process.env.SLASHING_RATE || '5.0')
});

export default ValidatorStakingService;