import { CotiSDK, NetworkConfig } from '@coti-io/coti-sdk-typescript';
import { ethers } from 'ethers';

export interface TransactionResult {
  hash: string;
  receipt: ethers.providers.TransactionReceipt;
}

export class CotiService {
  private sdk: CotiSDK;
  private provider: ethers.providers.Provider;
  private signer?: ethers.Signer;
  
  constructor(network: 'testnet' | 'mainnet' = 'testnet') {
    const config: NetworkConfig = {
      network,
      apiKey: process.env.REACT_APP_COTI_API_KEY || '',
      rpcUrl: network === 'testnet' 
        ? process.env.REACT_APP_COTI_TESTNET_URL || 'https://testnet.coti.io'
        : process.env.REACT_APP_COTI_MAINNET_URL || 'https://mainnet.coti.io'
    };
    
    this.sdk = new CotiSDK(config);
    this.provider = this.sdk.getProvider();
  }
  
  /**
   * Connect wallet and return the connected address
   */
  async connectWallet(): Promise<string> {
    try {
      this.signer = await this.sdk.connectWallet();
      const address = await this.signer.getAddress();
      console.log('Wallet connected:', address);
      return address;
    } catch (error) {
      console.error('Failed to connect wallet:', error);
      throw error;
    }
  }
  
  /**
   * Disconnect wallet
   */
  async disconnectWallet(): Promise<void> {
    this.signer = undefined;
    await this.sdk.disconnect();
  }
  
  /**
   * Get current block number
   */
  async getBlockNumber(): Promise<number> {
    return await this.provider.getBlockNumber();
  }
  
  /**
   * Get account balance
   */
  async getBalance(address: string): Promise<ethers.BigNumber> {
    return await this.provider.getBalance(address);
  }
  
  /**
   * Execute a transaction with optional privacy
   */
  async executeTransaction(
    contractAddress: string,
    abi: any[],
    method: string,
    params: any[],
    options: {
      usePrivacy?: boolean;
      value?: ethers.BigNumber;
      gasLimit?: ethers.BigNumber;
    } = {}
  ): Promise<TransactionResult> {
    if (!this.signer) {
      throw new Error('Wallet not connected');
    }
    
    const contract = new ethers.Contract(contractAddress, abi, this.signer);
    
    // Determine method name based on privacy option
    const methodName = options.usePrivacy ? `${method}WithPrivacy` : method;
    
    // Check if method exists
    if (!contract[methodName]) {
      throw new Error(`Method ${methodName} not found in contract`);
    }
    
    // Prepare transaction options
    const txOptions: any = {};
    if (options.value) txOptions.value = options.value;
    if (options.gasLimit) txOptions.gasLimit = options.gasLimit;
    
    // Execute transaction
    const tx = await contract[methodName](...params, txOptions);
    console.log('Transaction sent:', tx.hash);
    
    // Wait for confirmation
    const receipt = await tx.wait();
    console.log('Transaction confirmed:', receipt.transactionHash);
    
    return {
      hash: tx.hash,
      receipt
    };
  }
  
  /**
   * Read contract data
   */
  async readContract(
    contractAddress: string,
    abi: any[],
    method: string,
    params: any[] = []
  ): Promise<any> {
    const contract = new ethers.Contract(contractAddress, abi, this.provider);
    return await contract[method](...params);
  }
  
  /**
   * Get contract instance
   */
  getContract(contractAddress: string, abi: any[]): ethers.Contract {
    const signerOrProvider = this.signer || this.provider;
    return new ethers.Contract(contractAddress, abi, signerOrProvider);
  }
  
  /**
   * Estimate gas for a transaction
   */
  async estimateGas(
    contractAddress: string,
    abi: any[],
    method: string,
    params: any[],
    options: {
      usePrivacy?: boolean;
      value?: ethers.BigNumber;
    } = {}
  ): Promise<ethers.BigNumber> {
    if (!this.signer) {
      throw new Error('Wallet not connected');
    }
    
    const contract = new ethers.Contract(contractAddress, abi, this.signer);
    const methodName = options.usePrivacy ? `${method}WithPrivacy` : method;
    
    const txOptions: any = {};
    if (options.value) txOptions.value = options.value;
    
    return await contract.estimateGas[methodName](...params, txOptions);
  }
  
  /**
   * Subscribe to events
   */
  subscribeToEvent(
    contractAddress: string,
    abi: any[],
    eventName: string,
    callback: (event: any) => void
  ): ethers.Contract {
    const contract = this.getContract(contractAddress, abi);
    contract.on(eventName, callback);
    return contract;
  }
  
  /**
   * Unsubscribe from events
   */
  unsubscribeFromEvent(contract: ethers.Contract, eventName: string): void {
    contract.removeAllListeners(eventName);
  }
  
  /**
   * Format units for display
   */
  formatUnits(value: ethers.BigNumber, decimals: number = 18): string {
    return ethers.formatUnits(value, decimals);
  }
  
  /**
   * Parse units from string
   */
  parseUnits(value: string, decimals: number = 18): ethers.BigNumber {
    return ethers.parseUnits(value, decimals);
  }
  
  /**
   * Get current gas price
   */
  async getGasPrice(): Promise<ethers.BigNumber> {
    return await this.provider.getGasPrice();
  }
  
  /**
   * Wait for transaction
   */
  async waitForTransaction(
    txHash: string,
    confirmations: number = 1
  ): Promise<ethers.providers.TransactionReceipt> {
    return await this.provider.waitForTransaction(txHash, confirmations);
  }
}