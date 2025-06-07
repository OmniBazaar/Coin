# OmniCoin Smart Contracts

This repository contains the smart contracts for the OmniCoin project, a comprehensive blockchain solution built on the C.O.T.I. platform.

## Features

- ERC20 token with upgradeable functionality
- Privacy-preserving transactions
- Staking and validator system
- Reputation tracking
- Cross-chain bridging
- Dispute resolution and arbitration
- DAO governance

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

1. Install dependencies:

```bash
npm install
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
npx hardhat test
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
1. Validators earn rewards for maintaining the network
1. Privacy features allow for private transactions
1. Reputation system tracks user behavior
1. Bridge enables cross-chain transfers
1. Arbitration system handles disputes

## Security

- All contracts are upgradeable using OpenZeppelin's upgradeability pattern
- Comprehensive test coverage
- Access control using OpenZeppelin's roles
- Reentrancy protection
- Pausable functionality for emergency situations

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

## Contributing

1. Fork the repository
1. Create your feature branch
1. Commit your changes
1. Push to the branch
1. Create a new Pull Request

## Support

For support, please open an issue in the GitHub repository or contact the development team.
