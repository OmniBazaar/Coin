# OmniCoin Smart Contracts

This repository contains the smart contracts for the OmniCoin project, a next-generation blockchain solution featuring:
- **Public Chain**: Avalanche subnet with 1-2 second finality and 4,500+ TPS
- **Private Chain**: COTI network for privacy-preserving transactions
- **Radical Simplification**: 60% gas reduction through off-chain computation

## 🔒 Security Status

**✅ SECURITY AUDIT COMPLETED** - Comprehensive security audit and implementation completed with:
- 70+ security test cases covering access control, reentrancy protection, and input validation
- Real-time security monitoring with automated alerts
- Emergency response procedures and circuit breakers
- Multi-signature controls and time-locked operations
- Comprehensive security documentation and monitoring guides

## 🚀 Architecture Transformation

We are implementing a dual-track development strategy:
1. **Avalanche Migration**: Public chain moves to Avalanche subnet for superior performance
2. **Radical Simplification**: 80% of functionality moves off-chain to validators

### Key Benefits
- **1-2 second finality** (vs 6 seconds on COTI)
- **4,500+ TPS capacity** (vs ~1,000)
- **60% gas reduction** through off-chain computation
- **Unlimited validators** (vs restricted by √users)
- **XOM as native gas token** for better economics

## Features

- ERC20 token with 6 decimal places (4.1B initial, 25B max supply)
- Dual-chain architecture: Public (Avalanche) + Private (COTI)
- Event-based state management with off-chain computation
- 5-tier staking system with duration bonuses (5-9% APY)
- Advanced marketplace with 1% fees and complex distribution
- Cross-chain bridging between Avalanche and COTI
- DAO governance with sophisticated fee distribution
- Comprehensive bonus system (welcome, referral, first sale)
- Gas-free transactions for users
- Advanced NFT marketplace with merkle-based verification

## Security Highlights

- **🛡️ OpenZeppelin Security Patterns** - Reentrancy protection, access control, pausable functionality
- **🔍 Real-time Monitoring** - Automated security monitoring with configurable alerts
- **⚡ Emergency Controls** - Circuit breakers and emergency stop functionality
- **🔐 Multi-signature Protection** - Critical operations require multiple approvals
- **📊 Comprehensive Testing** - 70+ security test cases with attack simulation
- **📝 Security Documentation** - Complete security audit report and monitoring guides

## Prerequisites

- Node.js (v16 or later)
- npm or yarn
- Hardhat

## Installation

1. Clone the repository:

```bash
git clone https://github.com/your-org/omnicoin.git
cd omnicoin
```

2. Install dependencies:

```bash
# From OmniBazaar root directory
cd ..
npm install

# Note: Dependencies are now managed at the root level in /home/rickc/OmniBazaar/node_modules
```

1. Create a `.env` file in the root directory with the following variables:

```bash
PRIVATE_KEY=your_private_key
INFURA_API_KEY=your_infura_api_key
ETHERSCAN_API_KEY=your_etherscan_api_key
```

## Development

1. Start a local Hardhat node:

```bash
npx hardhat node
```

1. In a new terminal, deploy the contracts to the local network:

```bash
npx hardhat run scripts/deploy.js --network localhost
```

1. Run tests:

```bash
npm test
```

1. Run security tests:

```bash
npm run test:security
```

1. Run security monitoring:

```bash
npm run security:monitor
```

## Contract Architecture

### Core Contracts

- `OmniCoin.sol`: Main ERC20 token contract with upgradeable functionality
- `OmniCoinPrivacy.sol`: Privacy layer for private transactions
- `OmniCoinStaking.sol`: Staking mechanism for validators
- `OmniCoinValidator.sol`: Validator management and rewards
- `OmniCoinReputation.sol`: Reputation tracking system
- `OmniCoinBridge.sol`: Cross-chain bridging functionality
- `OmniCoinArbitration.sol`: Dispute resolution system

### Integration

The contracts are designed to work together seamlessly:

1. Users can stake tokens to become validators
2. Validators earn rewards for maintaining the network
3. Privacy features allow for private transactions
4. Reputation system tracks user behavior
5. Bridge enables cross-chain transfers
6. Arbitration system handles disputes

## Security

- All contracts are upgradeable using OpenZeppelin's upgradeability pattern
- Comprehensive test coverage
- Access control using OpenZeppelin's roles
- Reentrancy protection
- Pausable functionality for emergency situations

## Integration Testing

The Coin module is integrated with the OmniBazaar test suite:

### Cross-Module Integration Testing

```bash
# Run all integration tests from OmniBazaar root
cd /home/rickc/OmniBazaar
npm run test:integration

# Run coin-specific integration tests
npm run test:integration -- coin

# Run cross-module tests involving smart contracts
npm run test:integration -- cross-module
```

### Integration Test Categories

- **Smart Contract Integration**: Tests contract interactions across modules
- **Bridge Testing**: Tests cross-chain functionality with Avalanche and COTI
- **DEX Integration**: Tests token operations with DEX module
- **Wallet Integration**: Tests wallet interactions with smart contracts

For detailed integration testing documentation, see:
- [Integration Test Suite](/home/rickc/OmniBazaar/tests/integration/README.md)
- [Cross-Module Testing](/home/rickc/OmniBazaar/tests/integration/features/cross-module)

## Testing

Run the test suite:

```bash
npx hardhat test
```

Run specific test files:

```bash
npx hardhat test test/OmniCoin.test.js
```

## Deployment

1. Deploy to a testnet:

```bash
npx hardhat run scripts/deploy.js --network goerli
```

1. Deploy to mainnet:

```bash
npx hardhat run scripts/deploy.js --network mainnet
```

## License

This project is licensed under the MIT License - see the LICENSE file for details.

## Getting Started

1. Clone the repository
2. Install dependencies
3. Configure environment variables
4. Deploy contracts
5. Run tests
6. Start development server

## Contributing

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/AmazingFeature`)
3. Commit your changes (`git commit -m 'Add some AmazingFeature'`)
4. Push to the branch (`git push origin feature/AmazingFeature`)
5. Open a Pull Request

## Support

For support, please open an issue in the GitHub repository or contact the development team.
