require("@nomicfoundation/hardhat-toolbox");
require("@openzeppelin/hardhat-upgrades");
require("hardhat-contract-sizer");
require("@typechain/hardhat");
require("dotenv").config();

// Per-chain gas-price override for deploys, in wei. Some public RPCs return an
// inflated `eth_gasPrice` that makes a perfectly affordable deploy fail at
// "insufficient funds"; setting this pins what is actually paid.
const GAS_PRICE_OVERRIDE =
  process.env.GAS_PRICE_WEI !== undefined && process.env.GAS_PRICE_WEI !== ""
    ? Number(process.env.GAS_PRICE_WEI)
    : undefined;

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
          viaIR: true,
          evmVersion: "paris"
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
          viaIR: true,
          evmVersion: "paris"
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
          viaIR: true,
          evmVersion: "paris"
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
          viaIR: true,
          evmVersion: "paris"
        }
      },
      {
        // Required by contracts/external/Multicall3.sol (pragma solidity 0.8.12).
        // Settings mirror mds1/multicall foundry.toml so the runtime bytecode
        // matches the canonical Multicall3 deployed on every other EVM chain.
        // NB: solc 0.8.12 predates The Merge — its evmVersion enum has no
        // "paris" entry; default (london) is correct here, and Multicall3
        // isn't a COTI-targeted contract anyway.
        version: "0.8.12",
        settings: {
          optimizer: {
            enabled: true,
            runs: 10000000
          }
        }
      }
    ],
    // Per-contract overrides. UnifiedFeeVault sits close to the 24 KiB
    // Spurious Dragon deployment limit because it owns the entire NFT
    // + P2P settlement surface. Use `runs: 1` to aggressively minimise
    // deployed bytecode (trades per-call gas cost for bytecode size).
    overrides: {
      // EscrowV2 crossed the 24,576-byte EIP-170 limit with the 2026-10
      // governance revision (node attribution, unmarkDisputed, per-escrow
      // token) — 27,290 bytes at runs: 200. Two changes fit it: the
      // marketplace-fee routing + first-sale bridge moved to the linked
      // library contracts/libraries/EscrowFeeRouter.sol, and `runs: 1` here.
      // Same trade-off as UnifiedFeeVault / OmniRegistration below: slightly
      // higher per-call gas for a much smaller runtime. `bytecodeHash: none`
      // strips the 53-byte CBOR metadata trailer.
      "contracts/EscrowV2.sol": {
        version: "0.8.24",
        settings: {
          optimizer: {
            enabled: true,
            runs: 1,
            details: {
              yul: true
            }
          },
          viaIR: true,
          evmVersion: "paris",
          metadata: {
            bytecodeHash: "none"
          }
        }
      },
      // The two linked libraries. Same settings as EscrowV2 so the artifact
      // used for linking and the standalone artifact review are one build.
      "contracts/libraries/EscrowFeeRouter.sol": {
        version: "0.8.24",
        settings: {
          optimizer: {
            enabled: true,
            runs: 1,
            details: {
              yul: true
            }
          },
          viaIR: true,
          evmVersion: "paris",
          metadata: {
            bytecodeHash: "none"
          }
        }
      },
      // The privacy half of the escrow (pXOM create/release/refund). Declared
      // here for the same reason: EscrowV2 imports it, so it is also built
      // inside EscrowV2's job — without this override the standalone artifact
      // would be built at runs: 200 and the escrow could link a different
      // build than the one that was reviewed.
      // The signature library is built inside EscrowV2's job, so it carries
      // the same settings as the escrow: one artifact for linking and review.
      "contracts/libraries/EscrowSignatureLib.sol": {
        version: "0.8.24",
        settings: {
          optimizer: {
            enabled: true,
            runs: 1,
            details: {
              yul: true
            }
          },
          viaIR: true,
          evmVersion: "paris",
          metadata: {
            bytecodeHash: "none"
          }
        }
      },
      // The arbitration panel reached 24,462 of the 24,576-byte EIP-170 limit
      // after cross-chain dispute support (2026-10-20). `runs: 1` minimises
      // deployed bytecode instead of splitting another library out; dispute
      // entry points and voting are human-scale, so the extra per-call gas is
      // an acceptable trade for headroom. `bytecodeHash: none` strips the
      // ~53-byte CBOR metadata trailer.
      "contracts/arbitration/OmniArbitration.sol": {
        version: "0.8.24",
        settings: {
          optimizer: {
            enabled: true,
            runs: 1,
            details: {
              yul: true
            }
          },
          viaIR: true,
          evmVersion: "paris",
          metadata: {
            bytecodeHash: "none"
          }
        }
      },
      "contracts/UnifiedFeeVault.sol": {
        version: "0.8.24",
        settings: {
          optimizer: {
            enabled: true,
            runs: 1,
            details: {
              yul: true
            }
          },
          viaIR: true,
          evmVersion: "paris",
          // Strips the ~53-byte CBOR metadata hash appended to deployed
          // bytecode by default. Zero functional risk (only affects
          // automatic Sourcify-style source matching by hash, not
          // Etherscan-style verify-by-recompile, which this repo already
          // uses); freed as part of fitting the M-06 seller-consent fix
          // (SellerNftSale / NftSellerConsent) under the 24 KiB EIP-170
          // limit alongside `runs: 1` + the library extraction.
          metadata: {
            bytecodeHash: "none"
          }
        }
      },
      // OmniRegistration sits right at the 24 KiB Spurious Dragon limit
      // after the Phase 2 attestation diff (2026-05-18). `runs: 1`
      // aggressively minimises deployed bytecode. Trade-off: per-call gas
      // cost increases ~10-15% on hot paths (registerUser, submitX...
      // verifications). Acceptable because (a) attestations happen at
      // human-scale (~thousands/day at peak), not high-frequency, and
      // (b) the cutover happens once at deploy; if we revisit later we
      // can split logic into a library to recover headroom.
      "contracts/OmniRegistration.sol": {
        version: "0.8.24",
        settings: {
          optimizer: {
            enabled: true,
            runs: 1,
            details: {
              yul: true
            }
          },
          viaIR: true,
          evmVersion: "paris"
        }
      },
      // PrivatePredictionMarket + PrivateRWAAMM crossed the 24 KiB EIP-170
      // limit after the itUint256/validateCiphertext retrofit (2026-06-19) —
      // the nested itUint256 calldata decoder added ~1.5 KiB. `runs: 1`
      // minimises deployed bytecode to fit; per-call gas rises modestly,
      // acceptable for human-scale committee txs. Version 0.8.25 matches the
      // default-selected compiler for these `^0.8.19` files (only `runs`
      // differs from the default), evmVersion paris (COTI Helium).
      "contracts/privacy/PrivatePredictionMarket.sol": {
        version: "0.8.25",
        settings: {
          optimizer: {
            enabled: true,
            runs: 1,
            details: {
              yul: true
            }
          },
          viaIR: true,
          evmVersion: "paris",
          metadata: {
            bytecodeHash: "none"
          }
        }
      },
      "contracts/privacy/PrivateRWAAMM.sol": {
        version: "0.8.25",
        settings: {
          optimizer: {
            enabled: true,
            runs: 1,
            details: {
              yul: true
            }
          },
          viaIR: true,
          evmVersion: "paris",
          metadata: {
            bytecodeHash: "none"
          }
        }
      },
      "contracts/privacy/PrivateMarketplaceEscrow.sol": {
        version: "0.8.25",
        settings: {
          optimizer: {
            enabled: true,
            runs: 1,
            details: {
              yul: true
            }
          },
          viaIR: true,
          evmVersion: "paris",
          metadata: {
            bytecodeHash: "none"
          }
        }
      },
      "contracts/privacy/PrivateDEXSettlement.sol": {
        version: "0.8.25",
        settings: {
          optimizer: {
            enabled: true,
            runs: 1,
            details: {
              yul: true
            }
          },
          viaIR: true,
          evmVersion: "paris",
          metadata: {
            bytecodeHash: "none"
          }
        }
      },
      "contracts/privacy/PrivateYieldVault.sol": {
        version: "0.8.25",
        settings: {
          optimizer: {
            enabled: true,
            runs: 1,
            details: {
              yul: true
            }
          },
          viaIR: true,
          evmVersion: "paris",
          metadata: {
            bytecodeHash: "none"
          }
        }
      }
    }
  },
  // Sourcify is OFF, and this is not a preference. Sourcify's v1 API — the
  // only one @nomicfoundation/hardhat-verify 2.1.3 speaks — is in a scheduled
  // brownout from 2026-07-07 to 2027-01-08 and answers every request with
  // HTTP 503 "API v1 is temporarily unavailable ... Please migrate to API v2".
  // Left enabled it fails on every single verify, turning a successful
  // Etherscan submission into a non-zero exit. Re-enable when hardhat-verify
  // ships Sourcify v2 support, or after the brownout window closes.
  sourcify: {
    enabled: false
  },
  // ONE Etherscan.io key covers Ethereum, Polygon AND Base — including
  // Basescan, which needs no separate key and no paid plan. `apiKey` MUST be a
  // plain string to get that: the plugin picks the v2 unified endpoint only
  // when the value is a string, and silently falls back to the per-network v1
  // endpoints (deprecated, and with no Base entry) when it is an object. See
  // @nomicfoundation/hardhat-verify internal/etherscan.js, where
  // `isV2 = typeof apiKey === "string"` chooses the URL.
  //
  // POLYGONSCAN_API_KEY is deliberately gone: under v2 a Polygonscan-issued
  // key is not what Polygon verification wants — the Etherscan.io key is.
  //
  // Do NOT conclude from a "Free API access is not supported for this chain"
  // error that Base needs a paid plan. That refusal comes from the `stats`
  // module only; the `contract` module — the one verification uses — answers
  // chain 8453 on a free key. Measured 2026-07-27, after the wrong conclusion
  // cost an afternoon.
  etherscan: {
    enabled: process.env.ETHERSCAN_API_KEY !== undefined && process.env.ETHERSCAN_API_KEY !== "",
    apiKey: process.env.ETHERSCAN_API_KEY || ""
  },
  networks: {
    hardhat: {
      // chainId default 1337; override via HARDHAT_CHAIN_ID for tests that
      // exercise constructor-time `block.chainid` guards (bridges + V2 tokens).
      chainId: Number(process.env.HARDHAT_CHAIN_ID ?? 1337),
      allowUnlimitedContractSize: true,
      // Env-gated mainnet fork (no-op unless FORK_POLYGON_URL is set). Used by
      // scripts/prove-crosschain-nft-buy-fork.cjs to exercise the REAL deployed
      // NFTMarketplaceEscrow + native USDC bytecode against forked Polygon state
      // (TODO #11). Set HARDHAT_CHAIN_ID=137 so the EIP-712 domain matches live.
      ...(process.env.FORK_POLYGON_URL !== undefined && process.env.FORK_POLYGON_URL !== ""
        ? {
            forking: {
              url: process.env.FORK_POLYGON_URL,
              ...(process.env.FORK_POLYGON_BLOCK !== undefined && process.env.FORK_POLYGON_BLOCK !== ""
                ? { blockNumber: Number(process.env.FORK_POLYGON_BLOCK) }
                : {})
            }
          }
        : {}),
      // Polygon (137) hardfork history — hardhat has no built-in schedule for it,
      // so forking 137 fails with "No known hardfork for execution" without this.
      // Shanghai-from-genesis is safe: the forked mainnet contracts (native USDC,
      // Aave) + our paris-compiled escrow use no cancun-only opcodes.
      //
      // OmniCoin L1 (88008, Avalanche Subnet-EVM) — added the analogous entry
      // 2026-08-02 while building the COMMITTEE-GRINDING fix's fork test. 🛑
      // EMPIRICALLY VERIFIED this alone does NOT fix execution against a fork
      // of chain 88008 in the currently-pinned hardhat/EDR version — AND,
      // re-testing to isolate the cause, the pre-existing 137 entry above
      // (`test/RouterAdapters.fork.test.js`, `FORK_TEST=1`) fails with the
      // IDENTICAL "No known hardfork for execution ... The node was not
      // configured with a hardfork activation history" error even though its
      // config looks correct per Hardhat's own docs. This is a genuine,
      // pre-existing Hardhat/EDR limitation for "unusual" (non-built-in)
      // forked chains in this dependency version — see
      // github.com/NomicFoundation/hardhat/issues/2396 and .../edr/issues/447
      // for the same class of report elsewhere. Left in place (harmless,
      // matches Hardhat's documented pattern, and unblocks a plain
      // `eth_blockNumber`/balance-style probe against either fork) but do
      // NOT trust it to make `soak/` produce a working execution-capable
      // fork of 88008 or 137 without further root-causing — that's a
      // pre-existing infrastructure gap, out of scope for this task. The
      // COMMITTEE-GRINDING L1 verifier-swap script is instead proven via a
      // LOCAL mechanics test against the real contracts (fresh local deploy,
      // not a fork) — see `test/RandomCommitteeVerifierV2GatewaySwap.test.ts`.
      chains: {
        137: { hardforkHistory: { shanghai: 0 } },
        88008: { hardforkHistory: { shanghai: 0 } }
      }
    },
    localhost: {
      // Default 8545 for normal `npx hardhat node` use; the e2e harness on V1
      // overrides via HARDHAT_RPC_URL because 8545 (and 8546) are permanently
      // owned by Reth (Ethereum mainnet archive) there.
      url: process.env.HARDHAT_RPC_URL || "http://127.0.0.1:8545",
      chainId: 1337
    },
    // Hardhat-network fork of OmniCoin L1 mainnet (chain id 88008) used by
    // the OmniRegistration-split soak harness in `soak/`. Spun up by
    // `soak/fork-runner.ts` on 127.0.0.1:18546 — chosen from the private/
    // test range to stay clear of Reth (8545 + 8546), Validator (3001),
    // and IPFS (5001). The fork preserves real mainnet contract state +
    // the deployer EOA balance, but writes never leave the local node.
    // See soak/README.md for the full rig.
    fork: {
      url: "http://127.0.0.1:18546",
      chainId: 88008,
      timeout: 120000
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
    // Wallet-agnostic migration network — same chain as `mainnet`, but reads
    // the key from MIGRATION_PRIVATE_KEY (NOT the deployer key). Whoever runs
    // an LP migration sets their OWN key here; the script acts as that address.
    // Kept separate from `mainnet` so a migration can never silently fall back
    // to the deployer's MAINNET_DEPLOYER_PRIVATE_KEY.
    "mainnet-migrate": {
      url: process.env.MAINNET_RPC_URL || "http://65.108.205.116:9650/ext/bc/B5gLCyeRWScxf1CeGHfXjEkcp5au8dQYQjtSV6cRammsLjsbK/rpc",
      chainId: 88008,
      accounts: process.env.MIGRATION_PRIVATE_KEY
        ? [process.env.MIGRATION_PRIVATE_KEY]
        : [],
      gasPrice: 25000000000,
      timeout: 120000
    },
    // Avalanche Mainnet C-Chain (for Bootstrap.sol on mainnet)
    "mainnet-c-chain": {
      // Overridable: the public endpoint is not reachable from every host (it
      // timed out from the validator host on 2026-10-20, which is also why the
      // validators' own Avalanche circuit breakers kept opening). Set
      // AVALANCHE_CCHAIN_RPC_URL to any C-Chain endpoint to deploy.
      url:
        process.env.AVALANCHE_CCHAIN_RPC_URL ||
        "https://api.avax.network/ext/bc/C/rpc",
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
    // Ethereum Mainnet (for OmniBazaarResolver ENS deployment + XOM OFT)
    "ethereum-mainnet": {
      url: process.env.ETH_RPC_URL || "https://ethereum-rpc.publicnode.com",
      chainId: 1,
      accounts: process.env.ETH_DEPLOYER_PRIVATE_KEY
        ? [process.env.ETH_DEPLOYER_PRIVATE_KEY]
        : [],
      gasPrice: GAS_PRICE_OVERRIDE ?? "auto",
      timeout: 120000
    },
    // Arbitrum One (XOM OFT + permissionless AMM stack)
    arbitrum: {
      url: process.env.ARBITRUM_RPC_URL || "https://arb1.arbitrum.io/rpc",
      chainId: 42161,
      accounts: process.env.MULTICHAIN_DEPLOYER_PRIVATE_KEY
        ? [process.env.MULTICHAIN_DEPLOYER_PRIVATE_KEY]
        : [],
      gasPrice: GAS_PRICE_OVERRIDE ?? "auto",
      timeout: 120000
    },
    // Base (XOM OFT + permissionless AMM stack)
    base: {
      url: process.env.BASE_RPC_URL || "https://mainnet.base.org",
      chainId: 8453,
      accounts: process.env.MULTICHAIN_DEPLOYER_PRIVATE_KEY
        ? [process.env.MULTICHAIN_DEPLOYER_PRIVATE_KEY]
        : [],
      gasPrice: GAS_PRICE_OVERRIDE ?? "auto",
      timeout: 120000
    },
    // Polygon (XOM OFT + permissionless AMM stack)
    polygon: {
      url: process.env.POLYGON_RPC_URL || "https://polygon-rpc.com",
      chainId: 137,
      accounts: process.env.MULTICHAIN_DEPLOYER_PRIVATE_KEY
        ? [process.env.MULTICHAIN_DEPLOYER_PRIVATE_KEY]
        : [],
      gasPrice: GAS_PRICE_OVERRIDE ?? "auto",
      timeout: 120000
    },
    // Gnosis Chain (chain 100) — prediction-market fee settlement (WXDAI).
    // Native gas token is xDAI. BridgedFeeCollector deploy target.
    gnosis: {
      url: process.env.GNOSIS_RPC_URL || "https://rpc.gnosischain.com",
      chainId: 100,
      accounts: process.env.MULTICHAIN_DEPLOYER_PRIVATE_KEY
        ? [process.env.MULTICHAIN_DEPLOYER_PRIVATE_KEY]
        : [],
      gasPrice: "auto",
      timeout: 120000
    },
    // BNB Smart Chain (OmniFeeRouter wraps PancakeSwap)
    bsc: {
      url: process.env.BSC_RPC_URL || "https://bsc-dataseed.binance.org",
      chainId: 56,
      accounts: process.env.MULTICHAIN_DEPLOYER_PRIVATE_KEY
        ? [process.env.MULTICHAIN_DEPLOYER_PRIVATE_KEY]
        : [],
      gasPrice: GAS_PRICE_OVERRIDE ?? "auto",
      timeout: 120000
    },
    // Avalanche C-Chain alias for OmniFeeRouter deploy (same as mainnet-c-chain).
    // Kept distinct so cross-chain scripts can use a consistent name.
    avalanche: {
      url: process.env.AVALANCHE_RPC_URL || "https://api.avax.network/ext/bc/C/rpc",
      chainId: 43114,
      accounts: process.env.MULTICHAIN_DEPLOYER_PRIVATE_KEY
        ? [process.env.MULTICHAIN_DEPLOYER_PRIVATE_KEY]
        : [],
      gasPrice: GAS_PRICE_OVERRIDE ?? "auto",
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