require("@nomicfoundation/hardhat-toolbox");
require("@openzeppelin/hardhat-upgrades");
require("hardhat-contract-sizer");
require("@typechain/hardhat");
require("dotenv").config();

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
    omnicoinFuji: {
      url: "http://127.0.0.1:9650/ext/bc/kSSQjR4DYyYNV3jrdPu39fR3niVJXCAgQw38FTurFMCdPve8u/rpc",
      chainId: 131313,
      accounts: [
        // omnicoin-control-1 (from genesis, has funds)
        "0x5145d2bcf3710ae4143b95aab6a7ff5cd954f78ddb9956b28ce86e4c7855e74b"
      ],
      gasPrice: 25000000000,
      timeout: 60000
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
    timeout: 100000
  },
  gasReporter: {
    enabled: process.env.REPORT_GAS !== undefined,
    currency: "USD",
    gasPrice: 30
  }
};