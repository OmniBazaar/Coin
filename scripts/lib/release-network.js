/**
 * Network resolver for the ODDAO release tooling (sign / publish / revoke /
 * deploy). Centralises the per-network chain id, RPC URL, and deployment file so
 * the scripts default to MAINNET (chain 88008) rather than the retired fuji
 * testnet (chain 131313). The chain id is load-bearing: it is encoded into the
 * EIP-191 message the ODDAO signers sign, and must equal the chain the
 * UpdateRegistry lives on or signatures will not verify on-chain.
 *
 * @module scripts/lib/release-network
 */

const path = require("path");

const DEPLOYMENTS_DIR = path.join(__dirname, "..", "..", "deployments");

/**
 * Known release networks. Mainnet RPC defaults to the public gateway but can be
 * overridden with MAINNET_RPC_URL (e.g. a local validator RPC) for the
 * standalone signer.
 * @type {Record<string, { chainId: bigint, rpcUrl: string, deploymentFile: string }>}
 */
const NETWORKS = {
  mainnet: {
    chainId: 88008n,
    rpcUrl: process.env.MAINNET_RPC_URL || "https://rpc.omnicoin.net",
    deploymentFile: path.join(DEPLOYMENTS_DIR, "mainnet.json"),
  },
  fuji: {
    chainId: 131313n,
    rpcUrl:
      process.env.FUJI_RPC_URL ||
      "http://127.0.0.1:40681/ext/bc/2TEeYGdsqvS3eLBk8vrd9bedJiPR7uyeUo1YChM75HtCf9TzFk/rpc",
    deploymentFile: path.join(DEPLOYMENTS_DIR, "fuji.json"),
  },
};

/**
 * Map a hardhat network name (from `hre.network.name`) to a release-network key.
 * Anything that is not an OmniCoin L1 mainnet network resolves to fuji so the
 * scripts never silently assume mainnet on an unknown network.
 * @param {string} hardhatNetworkName - The `--network` name hardhat connected to.
 * @returns {"mainnet"|"fuji"} The release-network key.
 */
function releaseNetworkKey(hardhatNetworkName) {
  return hardhatNetworkName === "mainnet" ? "mainnet" : "fuji";
}

/**
 * Resolve a release-network configuration by key.
 * @param {string} [name] - "mainnet" (default) or "fuji".
 * @returns {{ name: string, chainId: bigint, rpcUrl: string, deploymentFile: string }}
 *   The resolved configuration.
 * @throws {Error} When the name is not a known network.
 */
function resolveReleaseNetwork(name) {
  const key = name || process.env.RELEASE_NETWORK || "mainnet";
  const cfg = NETWORKS[key];
  if (!cfg) {
    throw new Error(
      `Unknown release network "${key}". Known: ${Object.keys(NETWORKS).join(", ")}`,
    );
  }
  return { name: key, ...cfg };
}

module.exports = { resolveReleaseNetwork, releaseNetworkKey };
