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

  // Hardhat only discovers .ts files when the config is hardhat.config.ts.
  // Since ours is .js, manually discover .ts test files.
  // Only do this for full-suite runs (no specific files passed).
  let allFiles = files;
  if (!args.testFiles || args.testFiles.length === 0) {
    const { getAllFilesMatching } = require("hardhat/internal/util/fs-utils");
    const tsFiles = await getAllFilesMatching(
      hre.config.paths.tests,
      (f) => f.endsWith(".ts")
    );
    allFiles = [...new Set([...files, ...tsFiles])];
  }

  const filtered = allFiles.filter((f) => {
    // Exclude deprecated tests
    if (f.includes("/deprecated/")) return false;
    // Only include files matching *.test.{js,ts} pattern
    if (!/\.test\.(js|ts)$/.test(f)) return false;
    // Exclude COTI V2 framework tests (require COTI testnet, not Hardhat)
    if (f.includes("/access/")) return false;
    if (f.includes("/onboard/")) return false;
    if (f.includes("/token/")) return false;
    if (f.includes("/utils/mpc/")) return false;
    // Exclude external-system tests (Jest/COTI wallet, validator infra)
    if (f.endsWith("wallet.test.ts")) return false;
    if (f.endsWith("validator-blockchain-integration.test.ts")) return false;
    // Exclude legacy TS variants that import non-existent typechain-types
    if (f.endsWith("OmniCoin-simple.test.ts")) return false;
    if (f.endsWith("OmniCoinArbitration.test.ts")) return false;
    if (/\/OmniCoin\.test\.ts$/.test(f)) return false;
    return true;
  });
  if (process.env.DEBUG_TEST_FILES) {
    console.log("TEST FILES DISCOVERED:", filtered.length);
    filtered.forEach(f => console.log("  ", f));
  }
  return filtered;
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
      chainId: 1337,
      allowUnlimitedContractSize: true
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
      url: process.env.MAINNET_RPC_URL || "http://65.108.205.116:9650/ext/bc/2PuAuG7y7B94YXu13dsuwc9cR5EdUjFS24AULeWL5Lm1AtPcKj/rpc",
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
    },
    // Ethereum Mainnet (for OmniBazaarResolver ENS deployment)
    "ethereum-mainnet": {
      url: process.env.ETH_RPC_URL || "https://ethereum-rpc.publicnode.com",
      chainId: 1,
      accounts: process.env.ETH_DEPLOYER_PRIVATE_KEY
        ? [process.env.ETH_DEPLOYER_PRIVATE_KEY]
        : [],
      gasPrice: "auto",
      timeout: 120000
    },
    // COTI V2 Mainnet — MPC privacy contracts
    cotiMainnet: {
      url: "https://mainnet.coti.io/rpc",
      chainId: 2632500,
      accounts: process.env.COTI_MAINNET_DEPLOYER_PRIVATE_KEY
        ? [process.env.COTI_MAINNET_DEPLOYER_PRIVATE_KEY]
        : [],
      gas: "auto",
      gasPrice: 5000000000, // 5 Gwei
      timeout: 180000, // 3 minutes for MPC operations
      confirmations: 2,
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