require("@nomicfoundation/hardhat-toolbox");
require("@openzeppelin/hardhat-upgrades");
require("hardhat-contract-sizer");
require("@typechain/hardhat");
require("dotenv").config();

// Exclude test/deprecated/ from test runs — Hardhat resolves files before
// passing to Mocha, so mocha.ignore alone does not work.
const { subtask } = require("hardhat/config");
const { TASK_TEST_GET_TEST_FILES } = require("hardhat/builtin-tasks/task-names");

subtask(TASK_TEST_GET_TEST_FILES).setAction(async (args, hre, runSuper) => {
  const files = await runSuper(args);
  return files.filter((f) => !f.includes("/deprecated/"));
});

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: {
    compilers: [
      {
        version: "0.8.19",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200,
            details: {
              yul: true
            }
          },
          viaIR: true
        }
      },
      {
        version: "0.8.20",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200,
            details: {
              yul: true
            }
          },
          viaIR: true
        }
      },
      {
        version: "0.8.24",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200,
            details: {
              yul: true
            }
          },
          viaIR: true
        }
      },
      {
        version: "0.8.25",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200,
            details: {
              yul: true
            }
          },
          viaIR: true
        }
      }
    ]
  },
  networks: {
    hardhat: {
      chainId: 1337
    },
    localhost: {
      url: "http://127.0.0.1:8545",
      chainId: 1337
    },
    fuji: {
      url: "http://127.0.0.1:40681/ext/bc/2TEeYGdsqvS3eLBk8vrd9bedJiPR7uyeUo1YChM75HtCf9TzFk/rpc",
      chainId: 131313,
      accounts: process.env.DEPLOYER_PRIVATE_KEY
        ? [process.env.DEPLOYER_PRIVATE_KEY]
        : [],
      gasPrice: 25000000000,
      timeout: 60000
    },
    // Alias for backwards compatibility
    omnicoinFuji: {
      url: "http://127.0.0.1:40681/ext/bc/2TEeYGdsqvS3eLBk8vrd9bedJiPR7uyeUo1YChM75HtCf9TzFk/rpc",
      chainId: 131313,
      accounts: process.env.DEPLOYER_PRIVATE_KEY
        ? [process.env.DEPLOYER_PRIVATE_KEY]
        : [],
      gasPrice: 25000000000,
      timeout: 60000
    },
    // Avalanche Fuji C-Chain (for Bootstrap.sol deployment)
    // Bootstrap.sol is deployed on C-Chain so clients can discover validators
    // without needing access to the OmniCoin L1 subnet
    "fuji-c-chain": {
      url: "https://api.avax-test.network/ext/bc/C/rpc",
      chainId: 43113,
      accounts: process.env.DEPLOYER_PRIVATE_KEY
        ? [process.env.DEPLOYER_PRIVATE_KEY]
        : [],
      gasPrice: 25000000000, // 25 Gwei
      timeout: 60000
    },
    // Avalanche Mainnet Subnet-EVM (Production)
    mainnet: {
      url: process.env.MAINNET_RPC_URL || "https://rpc.omnicoin.net",
      chainId: 88008,
      accounts: process.env.MAINNET_DEPLOYER_PRIVATE_KEY
        ? [process.env.MAINNET_DEPLOYER_PRIVATE_KEY]
        : [],
      gasPrice: 25000000000,
      timeout: 120000
    },
    // Avalanche Mainnet C-Chain (for Bootstrap.sol on mainnet)
    "mainnet-c-chain": {
      url: "https://api.avax.network/ext/bc/C/rpc",
      chainId: 43114,
      accounts: process.env.MAINNET_DEPLOYER_PRIVATE_KEY
        ? [process.env.MAINNET_DEPLOYER_PRIVATE_KEY]
        : [],
      gasPrice: 25000000000,
      timeout: 120000
    },
    cotiTestnet: {
      url: "https://testnet.coti.io/rpc",
      chainId: 7082400, // COTI Testnet (verified from network)
      accounts: process.env.COTI_DEPLOYER_PRIVATE_KEY
        ? [process.env.COTI_DEPLOYER_PRIVATE_KEY]
        : [],
      gas: "auto", // Auto estimate gas
      gasPrice: 5000000000, // 5 Gwei base fee
      timeout: 180000, // 3 minutes for MPC operations
      confirmations: 2,
      // Fix for COTI RPC "pending block not available" issue
      blockGasLimit: 30000000,
      allowUnlimitedContractSize: false
    }
  },
  paths: {
    sources: "./contracts",
    tests: "./test",
    cache: "./cache",
    artifacts: "./artifacts"
  },
  contractSizer: {
    alphaSort: true,
    runOnCompile: true,
    disambiguatePaths: false
  },
  mocha: {
    timeout: 100000,
    ignore: [
      "test/deprecated/**/*.js",
      "test/deprecated/**/*.test.js"
    ]
  },
  gasReporter: {
    enabled: process.env.REPORT_GAS !== undefined,
    currency: "USD",
    gasPrice: 30
  }
};