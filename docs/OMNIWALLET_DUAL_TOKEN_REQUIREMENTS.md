# OmniWallet Dual Token Requirements

**Created:** 2025-07-26
**Purpose:** Document requirements for supporting both OmniCoin and PrivateOmniCoin in OmniWallet

## Overview

With the confirmed dual-token architecture on COTI V2, OmniWallet must support:
1. **OmniCoin (XOM)** - Standard ERC20 for public transactions
2. **PrivateOmniCoin (pXOM)** - COTI PrivateERC20 for private transactions

## User Experience Requirements

### 1. Token Display
```
Wallet Balance:
┌─────────────────────────────────┐
│ OmniCoin (XOM)                  │
│ Balance: 1,000.00 XOM           │
│ ≈ $1,000.00 USD                 │
├─────────────────────────────────┤
│ PrivateOmniCoin (pXOM) 🔒       │
│ Balance: [Hidden]               │
│ [Show Balance]                  │
└─────────────────────────────────┘
```

### 2. Bridge Interface
```
Convert Tokens:
┌─────────────────────────────────┐
│ From: OmniCoin (XOM)            │
│ To: PrivateOmniCoin (pXOM)      │
│                                 │
│ Amount: [___________] XOM       │
│ Bridge Fee: 1% (1.00 XOM)       │
│ You'll Receive: 99.00 pXOM      │
│                                 │
│ [Convert to Private] 🔒         │
└─────────────────────────────────┘
```

### 3. Transaction Selection
When sending tokens, users must choose:
- **Public Send** (default) - Uses OmniCoin
- **Private Send** - Uses PrivateOmniCoin

## Technical Requirements

### 1. Wallet Storage
```typescript
interface WalletState {
  // Public token
  omniCoinBalance: bigint;
  omniCoinAddress: string;
  
  // Private token
  privateOmniCoinBalance?: ctUint64; // Encrypted
  privateOmniCoinAddress: string;
  encryptionAddress?: string; // For COTI encryption
}
```

### 2. Contract Interactions
```typescript
class OmniWalletService {
  // Standard ERC20 operations
  async getPublicBalance(): Promise<bigint>
  async sendPublic(to: string, amount: bigint): Promise<TxHash>
  
  // Private token operations
  async getPrivateBalance(): Promise<ctUint64>
  async sendPrivate(to: string, amount: itUint64): Promise<gtBool>
  
  // Bridge operations
  async convertToPrivate(amount: bigint): Promise<TxHash>
  async convertToPublic(amount: bigint): Promise<TxHash>
}
```

### 3. Privacy Features
- Private balances shown only after user confirmation
- Transaction history segregated by token type
- Clear labeling of private vs public transactions
- Encryption key management for COTI types

## UI/UX Considerations

### 1. Token Switching
- Clear toggle between token views
- Visual distinction (colors/icons)
- Warnings when using private tokens

### 2. Fee Transparency
- Show bridge fees clearly
- Explain privacy benefits
- Display conversion rates

### 3. Educational Content
- Explain difference between tokens
- Privacy best practices
- When to use each token type

## Security Requirements

### 1. Key Management
- Separate keys for encryption addresses
- Secure storage of private token data
- Clear key derivation paths

### 2. Transaction Validation
- Verify bridge contract addresses
- Check conversion rates
- Validate fee calculations

### 3. Privacy Protection
- Don't log private transactions
- Secure memory for encrypted values
- Clear privacy indicators

## Integration Points

### 1. Marketplace Integration
When purchasing on OmniBazaar:
```
Payment Options:
○ Pay with OmniCoin (Public)
● Pay with PrivateOmniCoin (Private) 🔒
```

### 2. DEX Integration
- Show both token types in trading pairs
- Clear conversion paths
- Liquidity pool information

### 3. Staking Options
- Stake public tokens normally
- Private staking pools available

## Development Priority

### Phase 1: Basic Support
1. Display both token balances
2. Basic send functionality
3. Bridge interface

### Phase 2: Enhanced Features
1. Private balance viewing
2. Transaction history
3. Advanced privacy settings

### Phase 3: Full Integration
1. Marketplace integration
2. DEX trading support
3. Staking interfaces

## Migration Path

For existing OmniWallet users:
1. Automatic detection of OmniCoin balance
2. Prompt to learn about PrivateOmniCoin
3. Optional bridge tutorial
4. Gradual feature rollout

## Success Metrics

1. **Adoption Rate**: % of users with both tokens
2. **Bridge Usage**: Daily conversion volume
3. **Privacy Adoption**: % using private transactions
4. **User Satisfaction**: Clear understanding of dual system

## Conclusion

OmniWallet must evolve to support both public and private tokens seamlessly. This dual-token approach gives users the best of both worlds: speed for everyday transactions and privacy when needed. The wallet interface must make this choice clear and simple while maintaining security and usability.