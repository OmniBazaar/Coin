# Reference Contracts

This directory contains deprecated contracts that are kept for reference purposes only. These contracts should not be deployed or modified.

## Deprecated Contracts

### OmniCoinCore.sol
- **Deprecated Date**: 2025-07-28
- **Reason**: Replaced by dual-token architecture (OmniCoin.sol and PrivateOmniCoin.sol)
- **Replacement**: 
  - Public token: `OmniCoin.sol`
  - Private token: `PrivateOmniCoin.sol`
  - Bridge: `OmniCoinPrivacyBridge.sol`
- **Notes**: The original single-token design has been replaced with a dual-token system that allows users to choose between public (XOM) and private (pXOM) transactions.

## Migration Notes

When referencing old code:
1. `OmniCoinCore` → `OmniCoin` (for public operations)
2. Privacy features → `PrivateOmniCoin` (for private operations)
3. All contracts now use `RegistryAware` base class for dynamic contract discovery
4. Decimals changed from 18 to 6 across all tokens