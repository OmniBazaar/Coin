#!/usr/bin/env node
/**
 * coti-private-escrow-fee-proof.cjs — the two private-escrow fee proofs that
 * only a real COTI chain can produce:
 *
 *   LEG 1  a private escrow RELEASED at `escrowFeeBps() == 0` — the seller is
 *          paid the whole price and the fee vault receives nothing.
 *   LEG 2  a private escrow DISPUTED and ARBITRATED, so `_settleArbitration`
 *          runs at `ARBITRATION_FEE_BPS() == 500` — the vault takes 5 % of the
 *          disputed amount and the winner takes the remaining 95 %.
 *
 * Target: COTI testnet, chain id 7082400, `https://testnet.coti.io/rpc`.
 *
 * ════════════════════════════════════════════════════════════════════════
 *  WHY THIS CANNOT BE SIMULATED, AND WHY EVERY ASSERTION IS A RECEIPT
 * ════════════════════════════════════════════════════════════════════════
 * The MPC precompile at 0x0000000000000000000000000000000000000064 is not an
 * `eth_call` target: a read-only call to it is rejected by the node (verified
 * 2026-11-13 — 0x64 fails while 0x60/0x63/0x65 return "0x"). Every MPC
 * operation in this flow (transferFromGT on create, transferGT on release, the
 * encrypted fee split on arbitration) therefore has to run as a real
 * transaction and be proven from its receipt plus the state it changed.
 * NOTHING here is proven by `staticCall` simulation of an MPC path; the only
 * read-only calls are plain getters (statuses, fee bps, balances) that the node
 * serves normally.
 *
 * ════════════════════════════════════════════════════════════════════════
 *  WHICH CREATE PATH THIS USES, AND WHY NOT THE RELAYER ONE
 * ════════════════════════════════════════════════════════════════════════
 * `createEscrow(...)` (the RELAYER_ROLE path) stores the price via
 * `MpcCore.onBoard(encPrice)`, and `onBoard` only accepts a ciphertext the MPC
 * network itself produced with `offBoard` (system key) — not a buyer's
 * user-key ciphertext. The contract says so at `createEscrowWithCommittee`
 * ("the raw client input ciphertext is user-key encrypted and is NOT
 * onBoard-able"), and COTI's documentation says the same of `onBoard` vs
 * `validateCiphertext`. So this script uses `createEscrowWithCommittee`, the
 * only path that accepts a buyer input ciphertext (`itUint256` +
 * `MpcCore.validateCiphertext`, which binds the signature to msg.sender ==
 * buyer, to this proxy and to this selector).
 *
 * That path needs an M-of-N committee attestation over the same EIP-712
 * digest. Rather than depend on a validator network, the script bootstraps its
 * own committee: `initializeV2(3, 3, pool, 0)` seeds a THREE-member eligible
 * set from keys we hold, so the committee for any digest is exactly that pool
 * (a Fisher-Yates sample of N = 3 from a pool of 3 always returns all three)
 * and all three sign. The script still asks the proxy for
 * `committeeFor(digest, commitBlock)` and refuses to sign unless the answer
 * equals the sorted pool — the selection algorithm is never re-implemented
 * off-chain, so a change to it is caught before a revert.
 *
 * ════════════════════════════════════════════════════════════════════════
 *  GATE, IDEMPOTENCY, AND THE 24-HOUR DISPUTE DELAY
 * ════════════════════════════════════════════════════════════════════════
 *   - Refuses to run (exit 2, nothing deployed, no transaction sent) unless
 *     COTI_TESTNET_PROOF=1, COTI_DEPLOYER_PRIVATE_KEY is set, the connected
 *     chain is 7082400, and the deployer holds a non-zero balance. Every
 *     missing precondition is printed together, so there is never a partial
 *     deploy. The ABI-vs-source check runs before the gate, so an operator
 *     with no gas still gets that self-test.
 *   - Idempotent: every address, escrow id, AES key and step receipt lands in
 *     `deployments/coti-testnet-private-escrow-proof.json`, and a re-run skips
 *     what already exists (address has code, escrow status already advanced,
 *     step already recorded). Escrow ids are derived deterministically from
 *     (buyer, seller, listingRef, fee bps), so a re-run adopts its own escrow
 *     instead of creating a second one.
 *   - `MIN_DISPUTE_DELAY` is 24 hours, so leg 2 cannot finish in the same run
 *     as its create. The first run creates both escrows, releases leg 1, then
 *     either waits (COTI_TESTNET_PROOF_WAIT=1) or exits 3 with the earliest
 *     dispute time and the exact re-run command. The second run disputes,
 *     arbitrates and finishes the proof.
 *
 * Usage (once the deployer is funded — see the faucet note the gate prints):
 *   COTI_DEPLOYER_PRIVATE_KEY=0x… COTI_TESTNET_PROOF=1 \
 *     NODE_PATH=/home/omnirick/OmniBazaar/node_modules \
 *     npx hardhat run scripts/coti-private-escrow-fee-proof.cjs --network cotiTestnet
 *
 * Secrets: the deployer's AES key (needed to decrypt the fee vault's balance)
 * is kept OUT of the repo at ~/.config/omnibazaar/coti-testnet-deployer-aes.json
 * with mode 0600. Buyer/seller AES keys are recorded in the state file; their
 * private keys are already in deployments/coti-testnet-validator-keys.json.
 * TESTNET ONLY — the gate pins chain id 7082400 and never runs on mainnet.
 */
"use strict";

const fs = require("fs");
const path = require("path");
const os = require("os");
const hre = require("hardhat");
const { ethers } = hre;
const {
  Wallet: CotiWallet,
  getDefaultProvider,
  CotiNetwork,
} = require("@coti-io/coti-ethers");
const {
  prepareIT256,
  decryptUint256,
} = require("@coti-io/coti-sdk-typescript");

// ════════════════════════════════════════════════════════════════════════════
//                                CONSTANTS
// ════════════════════════════════════════════════════════════════════════════

const ROOT = path.resolve(__dirname, "..");
const DEPLOYMENTS = path.join(ROOT, "deployments");
const KEYS_FILE = path.join(DEPLOYMENTS, "coti-testnet-validator-keys.json");
const STATE_FILE = path.join(DEPLOYMENTS, "coti-testnet-private-escrow-proof.json");
const DEPLOYER_AES_FILE = path.join(
  os.homedir(),
  ".config",
  "omnibazaar",
  "coti-testnet-deployer-aes.json"
);

/** COTI testnet. Pinned: this script only runs against these values. */
const CHAIN_ID = 7082400;
const RPC_URL = "https://testnet.coti.io/rpc";
const EXPLORER_TX = "https://testnet.coti.io/explorer/tx/";

/** Price per escrow: 1 pXOM (18 decimals). Small enough to be cheap, large
 *  enough that 5 % of it is a non-zero integer. */
const PRICE = 10n ** 18n;
/** Gas the deployer sends each working actor so it can onboard + transact. */
const FUND_WEI = ethers.parseEther("0.5");
/** Top an actor up again below this on a re-run. */
const FUND_TOPUP_BELOW = ethers.parseEther("0.05");

/** EIP-712 domain — must match `__EIP712_init` in the contract. */
const EIP712_DOMAIN_NAME = "OmniBazaar PrivateMarketplaceEscrow";
const EIP712_DOMAIN_VERSION = "1";
const CREATE_ESCROW_TYPES = {
  CreateEscrowIntent: [
    { name: "escrowId", type: "bytes32" },
    { name: "buyer", type: "address" },
    { name: "seller", type: "address" },
    { name: "arbitrator", type: "address" },
    { name: "listingRef", type: "bytes32" },
    { name: "priceCommit", type: "bytes32" },
    { name: "escrowFeeBps", type: "uint64" },
    { name: "deadline", type: "uint256" },
  ],
};

/** EscrowStatus enum, in declaration order. */
const STATUS = {
  EMPTY: 0,
  ACTIVE: 1,
  DISPUTED: 2,
  RELEASED: 3,
  REFUNDED: 4,
  ARBITRATED_TO_SELLER: 5,
  ARBITRATED_TO_BUYER: 6,
};

/** COTI rejects `eth_blockNumber("pending")` during gas estimation, so every
 *  transaction carries an explicit gas limit (the rule the 2026 COTI deploy
 *  scripts were written under). Receipts still report the real gas used. */
const GAS = {
  deployPxom: 5_000_000n,
  deployLibrary: 2_000_000n,
  deployImpl: 6_000_000n,
  deployProxy: 1_500_000n,
  initV2: 2_000_000n,
  initV3: 500_000n,
  grantRole: 250_000n,
  fund: 100_000n,
  mint: 2_000_000n,
  approveReset: 1_500_000n,
  approveEncrypted: 2_500_000n,
  createEscrow: 6_000_000n,
  release: 6_000_000n,
  dispute: 1_500_000n,
  arbitrate: 6_000_000n,
};

/** The two legs. `listing` doubles as the human label in the JSON. */
const LEGS = {
  releaseFeeZero: {
    key: "releaseFeeZero",
    label: "release at escrowFeeBps() = 0",
    listing: "coti-proof-release-fee-0",
  },
  disputeArbitration: {
    key: "disputeArbitration",
    label: "dispute settled at ARBITRATION_FEE_BPS() = 500",
    listing: "coti-proof-dispute-5pct",
  },
};

/** Minimal ABIs, written with explicit signatures so ethers never has to
 *  disambiguate the token's overloaded `approve`/`balanceOf`/`mint`. Each one
 *  is asserted against the compiled artifact in {@link assertAbisMatchSource}. */
const PXOM_ABI = [
  "function balanceOf(address) view returns ((uint256 ciphertextHigh,uint256 ciphertextLow))",
  "function approve(address spender,uint256 value)",
  "function approve(address spender,((uint256 ciphertextHigh,uint256 ciphertextLow) ciphertext,bytes signature) value)",
  "function mint(address to,uint256 amount)",
  "function MINTER_ROLE() view returns (bytes32)",
  "function hasRole(bytes32 role,address account) view returns (bool)",
];

const ESCROW_ABI = [
  "function initialize(address admin,address[] relayers,address[] arbitrators,address feeVault_,address trustedForwarder_)",
  "function initializeV2(uint256 committeeSize_,uint256 quorumM_,address[] bootstrapSet,uint256 l1Block)",
  "function initializeV3(address pxom_)",
  "function createEscrowWithCommittee(bytes32 escrowId,address buyer,address seller,address arbitrator,bytes32 listingRef,((uint256 ciphertextHigh,uint256 ciphertextLow) ciphertext,bytes signature) encPrice,uint64 expectedFeeBps,uint256 deadline,bytes buyerSignature,bytes committeeProof)",
  "function release(bytes32 escrowId)",
  "function dispute(bytes32 escrowId)",
  "function arbitrate(bytes32 escrowId,address winner)",
  "function escrows(bytes32) view returns (address buyer,address seller,address arbitrator,bytes32 listingRef,(uint256 ciphertextHigh,uint256 ciphertextLow) encPrice,uint256 createdAt,uint256 deadline,uint256 disputeRaisedAt,uint64 escrowFeeBpsAtCreate,uint8 status)",
  "function escrowFeeBps() view returns (uint64)",
  "function ARBITRATION_FEE_BPS() view returns (uint64)",
  "function MIN_DISPUTE_DELAY() view returns (uint256)",
  "function feeVault() view returns (address)",
  "function privateToken() view returns (address)",
  "function ARBITRATOR_ROLE() view returns (bytes32)",
  "function hasRole(bytes32 role,address account) view returns (bool)",
  "function grantRole(bytes32 role,address account)",
  "function committeeFor(bytes32 digest,uint256 commitBlock) view returns (address[])",
];

const PROXY_ARTIFACT =
  "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy";

// ════════════════════════════════════════════════════════════════════════════
//                              SMALL HELPERS
// ════════════════════════════════════════════════════════════════════════════

const log = (...args) => console.log(...args);

function fail(message) {
  throw new Error(message);
}

/** Print an address without ever echoing key material. */
function short(address) {
  return `${address.slice(0, 10)}…${address.slice(-6)}`;
}

/** Chunked sleep so a 24-hour wait logs progress instead of going silent. */
async function sleep(seconds, label) {
  const end = Date.now() + seconds * 1000;
  let announced = Number.POSITIVE_INFINITY;
  while (Date.now() < end) {
    const remaining = Math.ceil((end - Date.now()) / 1000);
    const minutes = Math.ceil(remaining / 60);
    if (minutes < announced) {
      log(`    … ${label}: ${minutes} min remaining`);
      announced = minutes;
    }
    const slice = Math.max(1_000, Math.min(30_000, end - Date.now()));
    await new Promise((resolve) => setTimeout(resolve, slice));
  }
}

function readJson(file) {
  if (!fs.existsSync(file)) return undefined;
  return JSON.parse(fs.readFileSync(file, "utf8"));
}

function writeJson(file, value) {
  fs.writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`);
  if (file === DEPLOYER_AES_FILE) fs.chmodSync(file, 0o600);
}

/** Load (or create) the proof/deployment state file. */
function loadState() {
  const state = readJson(STATE_FILE);
  if (state !== undefined) {
    if (state.chainId !== CHAIN_ID) {
      fail(
        `${STATE_FILE} is for chain ${String(state.chainId)}, not ${String(CHAIN_ID)} — refusing to reuse it`
      );
    }
    state.accounts ??= {};
    state.deployments ??= {};
    state.legs ??= {};
    return state;
  }
  return {
    chainId: CHAIN_ID,
    network: "coti-testnet",
    rpc: RPC_URL,
    startedAt: new Date().toISOString(),
    accounts: {},
    deployments: {},
    legs: {},
  };
}

/**
 * Assert the minimal ABIs used here still match the compiled contracts.
 *
 * This is the offline half of "the script is correct": if a future edit
 * changes `initialize`, the committee create signature or the fee getters, the
 * script refuses before it spends gas. `node --check` proves the syntax; this
 * proves the interface and the library link.
 * @returns {Promise<void>}
 */
async function assertAbisMatchSource() {
  const escrowArtifact = await hre.artifacts.readArtifact("PrivateMarketplaceEscrow");
  const pxomArtifact = await hre.artifacts.readArtifact("PrivateOmniCoin");
  const libArtifact = await hre.artifacts.readArtifact("CommitteeAttestorLib");
  const escrowIface = new ethers.Interface(escrowArtifact.abi);
  const pxomIface = new ethers.Interface(pxomArtifact.abi);

  const requiredEscrow = [
    "initialize(address,address[],address[],address,address)",
    "initializeV2(uint256,uint256,address[],uint256)",
    "initializeV3(address)",
    "createEscrowWithCommittee(bytes32,address,address,address,bytes32,((uint256,uint256),bytes),uint64,uint256,bytes,bytes)",
    "release(bytes32)",
    "dispute(bytes32)",
    "arbitrate(bytes32,address)",
    "escrowFeeBps()",
    "ARBITRATION_FEE_BPS()",
    "escrows(bytes32)",
  ];
  const requiredPxom = [
    "balanceOf(address)",
    "approve(address,((uint256,uint256),bytes))",
    "approve(address,uint256)",
    "mint(address,uint256)",
  ];
  for (const signature of requiredEscrow) {
    try {
      escrowIface.getFunction(signature);
    } catch {
      fail(`ABI drift: PrivateMarketplaceEscrow has no ${signature}`);
    }
  }
  for (const signature of requiredPxom) {
    try {
      pxomIface.getFunction(signature);
    } catch {
      fail(`ABI drift: PrivateOmniCoin has no ${signature}`);
    }
  }
  const linkRefs = escrowArtifact.linkReferences ?? {};
  const linked = Object.keys(linkRefs).some((source) =>
    Object.keys(linkRefs[source]).includes("CommitteeAttestorLib")
  );
  if (!linked) {
    fail(
      "PrivateMarketplaceEscrow no longer links CommitteeAttestorLib — this script's deploy path expects that link"
    );
  }
  if (libArtifact.bytecode === "0x") {
    fail("CommitteeAttestorLib has no bytecode to deploy");
  }
  log("  ABI check: escrow initializer, committee create, fee getters and the");
  log("             CommitteeAttestorLib link all match the compiled source.");
}

/** Decode a receipt's logs against a known interface (our own events only). */
function decodeEvents(receipt, iface) {
  if (iface === undefined) return undefined;
  const events = [];
  for (const log of receipt.logs) {
    try {
      const parsed = iface.parseLog({ topics: [...log.topics], data: log.data });
      if (parsed === null) continue;
      const args = {};
      parsed.fragment.inputs.forEach((input, index) => {
        const value = parsed.args[index];
        args[input.name !== "" ? input.name : String(index)] =
          typeof value === "bigint" ? value.toString() : String(value);
      });
      events.push({ name: parsed.name, args });
    } catch {
      // Not one of ours (e.g. an ERC1967 admin event) — ignore.
    }
  }
  return events.length > 0 ? events : undefined;
}

/** Record one transaction step (hash, block, real gas used, decoded events). */
async function step(name, txPromise, gasLimit, iface) {
  const tx = await txPromise;
  const receipt = await tx.wait();
  if (receipt === null || receipt.status !== 1) {
    fail(`${name}: transaction ${tx.hash} failed (status ${String(receipt?.status)})`);
  }
  const record = {
    txHash: tx.hash,
    blockNumber: receipt.blockNumber,
    gasUsed: receipt.gasUsed.toString(),
    gasLimit: gasLimit !== undefined ? gasLimit.toString() : undefined,
    explorer: `${EXPLORER_TX}${tx.hash}`,
    events: decodeEvents(receipt, iface),
  };
  log(
    `  ${name}: tx ${tx.hash} · block ${String(receipt.blockNumber)} · gasUsed ${receipt.gasUsed.toString()}`
  );
  if (record.events !== undefined) {
    log(`    events: ${record.events.map((e) => e.name).join(", ")}`);
  }
  return record;
}

/** Build a COTI `itUint256` bound to (wallet, contract, selector). */
function it256(wallet, value, contractAddress, functionSelector) {
  const aesKey = wallet.getUserOnboardInfo()?.aesKey;
  if (aesKey === undefined) fail(`account ${short(wallet.address)} has no AES key`);
  const prepared = prepareIT256(value, { wallet, userKey: aesKey }, contractAddress, functionSelector);
  return {
    ciphertext: {
      ciphertextHigh: prepared.ciphertext.ciphertextHigh,
      ciphertextLow: prepared.ciphertext.ciphertextLow,
    },
    signature: prepared.signature,
  };
}

/** keccak256(abi.encode(high, low)) — matches the contract's `_commit`. */
function commitOf(encPrice) {
  return ethers.keccak256(
    ethers.AbiCoder.defaultAbiCoder().encode(
      ["uint256", "uint256"],
      [encPrice.ciphertextHigh, encPrice.ciphertextLow]
    )
  );
}

/**
 * Read (and decrypt when possible) an account's pXOM balance.
 *
 * `balanceOf(address)` returns the account's own ciphertext, encrypted under
 * that account's AES key, so a wallet that onboarded itself can decrypt it.
 * When decryption is impossible the ciphertext is kept and reported — no leg's
 * pass/fail depends on a decrypt, only on receipts and statuses.
 * @param pxom - pXOM contract bound to any provider.
 * @param account - Account whose balance to read.
 * @returns `{ plaintext: bigint|undefined, ciphertext: string }`.
 */
async function readBalance(pxom, account) {
  const ct = await pxom.getFunction("balanceOf(address)")(account.address);
  const ciphertext = `${ct.ciphertextHigh.toString(16)}:${ct.ciphertextLow.toString(16)}`;
  try {
    const aesKey = account.getUserOnboardInfo()?.aesKey;
    if (aesKey === undefined) return { plaintext: undefined, ciphertext };
    const plaintext = decryptUint256(
      {
        ciphertextHigh: BigInt(ct.ciphertextHigh),
        ciphertextLow: BigInt(ct.ciphertextLow),
      },
      aesKey
    );
    return { plaintext: BigInt(plaintext), ciphertext };
  } catch {
    return { plaintext: undefined, ciphertext };
  }
}

// ════════════════════════════════════════════════════════════════════════════
//                            ACCOUNTS AND BALANCES
// ════════════════════════════════════════════════════════════════════════════

/** Deployer AES key (fee vault decryption) lives outside the repo, 0600. */
function loadDeployerAes(address) {
  const saved = readJson(DEPLOYER_AES_FILE);
  if (saved?.address?.toLowerCase() === address.toLowerCase() && typeof saved.aesKey === "string") {
    return saved.aesKey;
  }
  return undefined;
}

function storeDeployerAes(address, aesKey) {
  fs.mkdirSync(path.dirname(DEPLOYER_AES_FILE), { recursive: true });
  writeJson(DEPLOYER_AES_FILE, {
    address,
    aesKey,
    note: "COTI testnet AES key for the deployer / fee vault — never commit, testnet only",
  });
}

/**
 * Build the actor set.
 *
 * Roles come from `deployments/coti-testnet-validator-keys.json` (five testnet
 * validator keys) plus the deployer:
 *   buyer      = key 0
 *   seller     = key 1
 *   arbitrator = key 2 (granted ARBITRATOR_ROLE on the fresh proxy)
 *   committee  = key 3, key 4, deployer — disjoint from every named party,
 *                because the contract reverts SubjectInCommittee when an
 *                attester is the buyer, seller or arbitrator.
 * With a pool of exactly three and N = 3 the committee is the whole pool.
 * @param state - Proof state, for AES keys recorded by an earlier run.
 * @param deployerAddress - The hardhat signer's address.
 * @returns Actor map.
 */
function buildActors(state, deployerAddress) {
  const keys = readJson(KEYS_FILE);
  if (!Array.isArray(keys) || keys.length < 5) {
    fail(`${KEYS_FILE} must hold at least five {address, privateKey} entries`);
  }
  const provider = getDefaultProvider(CotiNetwork.Testnet);
  const make = (name, privateKey, address) => {
    const wallet = new CotiWallet(privateKey, provider);
    if (address !== undefined && wallet.address.toLowerCase() !== address.toLowerCase()) {
      fail(`derived address for ${name} does not match ${address}`);
    }
    const recorded = state.accounts?.[name]?.aesKey;
    if (typeof recorded === "string" && recorded.length > 0) wallet.setAesKey(recorded);
    return { name, wallet, address: wallet.address };
  };

  const deployerKey = process.env.COTI_DEPLOYER_PRIVATE_KEY;
  const actors = {
    buyer: make("buyer", keys[0].privateKey, keys[0].address),
    seller: make("seller", keys[1].privateKey, keys[1].address),
    arbitrator: make("arbitrator", keys[2].privateKey, keys[2].address),
    committeeB: make("committeeB", keys[3].privateKey, keys[3].address),
    committeeC: make("committeeC", keys[4].privateKey, keys[4].address),
    deployer: make("deployer", deployerKey, deployerAddress),
  };
  const deployerAes = loadDeployerAes(actors.deployer.address);
  if (deployerAes !== undefined) actors.deployer.wallet.setAesKey(deployerAes);

  const addresses = Object.values(actors).map((a) => a.address.toLowerCase());
  if (new Set(addresses).size !== addresses.length) {
    fail("actor addresses are not distinct — refusing to build a self-attesting committee");
  }
  return actors;
}

/**
 * The preflight gate. Collects EVERY missing precondition before a single
 * transaction, so a failed gate never leaves a half-built deployment.
 * @param actors - Actor map.
 * @returns {Promise<void>}
 */
async function preflight(actors) {
  const missing = [];
  const provider = hre.ethers.provider;

  const chainId = Number((await provider.getNetwork()).chainId);
  if (chainId !== CHAIN_ID) {
    missing.push(
      `connected chain is ${String(chainId)}, expected ${String(CHAIN_ID)} — pass --network cotiTestnet`
    );
  }
  if (chainId === CHAIN_ID) {
    const balance = await provider.getBalance(actors.deployer.address);
    if (balance === 0n) {
      missing.push(
        `deployer ${actors.deployer.address} holds 0 wei on COTI testnet; deploy, proxy, committee init, mint and both legs all pay gas from it`
      );
    }
    for (const name of ["buyer", "seller", "arbitrator"]) {
      const actorBalance = await provider.getBalance(actors[name].address);
      log(
        `  ${name.padEnd(10)} ${actors[name].address} · ${ethers.formatEther(actorBalance)} COTI`
      );
    }
  } else {
    const balance = await provider.getBalance(actors.deployer.address).catch(() => 0n);
    if (balance === 0n) {
      missing.push(`deployer ${actors.deployer.address} holds 0 wei on chain ${String(chainId)}`);
    }
  }

  if (missing.length > 0) {
    printRefusal(missing);
    process.exit(2);
  }
}

/** The refusal message: exactly what is missing and how to clear it. */
function printRefusal(missing) {
  console.error(
    [
      "",
      "REFUSING TO RUN — nothing was deployed and no transaction was sent.",
      "",
      "Missing:",
      ...missing.map((item) => `  - ${item}`),
      "",
      "How to clear it:",
      "  1. Fund the deployer EOA on COTI testnet. NOTE: the public faucet at",
      "     https://faucet.testnet.coti.io is a client-side app whose bundle",
      "     reports \"Faucet sender is offline\" and exposes no API, so the",
      "     funding must come from a funded operator account, a bridge",
      "     withdrawal, or a faucet that is actually online.",
      "  2. Re-run with the gate open:",
      "     COTI_DEPLOYER_PRIVATE_KEY=0x… COTI_TESTNET_PROOF=1 \\",
      "       NODE_PATH=/home/omnirick/OmniBazaar/node_modules \\",
      "       npx hardhat run scripts/coti-private-escrow-fee-proof.cjs --network cotiTestnet",
      "",
    ].join("\n")
  );
}

/** Persist AES keys so a re-run reuses them instead of onboarding a second
 *  time (a second onboarding replaces the key and orphans every stored balance
 *  ciphertext). The deployer's key goes outside the repo. */
function rememberKeys(state, actors) {
  for (const [name, actor] of Object.entries(actors)) {
    const aesKey = actor.wallet.getUserOnboardInfo()?.aesKey;
    if (aesKey === undefined) continue;
    if (name === "deployer") {
      storeDeployerAes(actor.address, aesKey);
    } else {
      state.accounts[name] = { address: actor.address, aesKey };
    }
  }
  writeJson(STATE_FILE, state);
}

/** Onboard (or reuse) the accounts that must encrypt or decrypt pXOM. */
async function onboardForMpc(actors, names) {
  for (const name of names) {
    const actor = actors[name];
    if (actor.wallet.getUserOnboardInfo()?.aesKey !== undefined) {
      log(`  ${name}: AES key present (no onboarding tx)`);
      continue;
    }
    const balance = await hre.ethers.provider.getBalance(actor.address);
    if (balance === 0n) {
      fail(`${name} has no gas for onboarding — the deployer top-up cannot have run`);
    }
    log(`  ${name}: onboarding (registers the AES key with the MPC network)…`);
    await actor.wallet.generateOrRecoverAes();
    if (actor.wallet.getUserOnboardInfo()?.aesKey === undefined) {
      fail(`${name}: onboarding produced no AES key`);
    }
  }
}

/** Top the working actors up from the deployer when they are low. */
async function fundActors(actors, deployerSigner, names) {
  for (const name of names) {
    const actor = actors[name];
    const balance = await hre.ethers.provider.getBalance(actor.address);
    if (balance >= FUND_TOPUP_BELOW) {
      log(`  ${name}: ${ethers.formatEther(balance)} COTI (no top-up)`);
      continue;
    }
    await step(
      `fund ${name}`,
      deployerSigner.sendTransaction({
        to: actor.address,
        value: FUND_WEI,
        gasLimit: GAS.fund,
      }),
      GAS.fund
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
//                               DEPLOYMENT
// ════════════════════════════════════════════════════════════════════════════

/** Deploy one contract unless its recorded address already has code. */
async function deployOnce(state, slot, label, factory, args, gasLimit) {
  const recorded = state.deployments[slot];
  if (recorded?.address !== undefined) {
    const code = await hre.ethers.provider.getCode(recorded.address);
    if (code !== "0x") {
      log(`  ${label}: already deployed at ${recorded.address} (skip)`);
      return recorded.address;
    }
    log(`  ${label}: recorded ${recorded.address} has no code — redeploying`);
  }
  const contract = await factory.deploy(...args, { gasLimit });
  await contract.waitForDeployment();
  const address = await contract.getAddress();
  const tx = contract.deploymentTransaction();
  const receipt = tx !== null ? await tx.wait() : null;
  state.deployments[slot] = {
    address,
    txHash: tx?.hash,
    blockNumber: receipt?.blockNumber,
    gasUsed: receipt?.gasUsed?.toString(),
  };
  writeJson(STATE_FILE, state);
  log(`  ${label}: ${address} (tx ${tx?.hash ?? "n/a"})`);
  return address;
}

/**
 * Deploy (or reuse) the whole stack: pXOM, the committee library, the escrow
 * implementation, the ERC1967 proxy, and its initializers.
 * @param state - Proof state.
 * @param actors - Actor map.
 * @param deployerSigner - Hardhat signer for the deployer.
 * @returns The bound contracts and the committee pool.
 */
async function deployStack(state, actors, deployerSigner) {
  log("\n[1/4] Deployments");

  // pXOM. `bridge_` is the deployer: PrivateOmniCoin grants MINTER_ROLE to
  // `bridge_` in the constructor and forbids granting it later, and testnet has
  // no privacy bridge to act as the minter. Testnet-only deviation, and the
  // only way to mint the pXOM this proof spends.
  const pxomAddress = await deployOnce(
    state,
    "privateOmniCoin",
    "PrivateOmniCoin (pXOM)",
    await hre.ethers.getContractFactory("PrivateOmniCoin"),
    [actors.deployer.address],
    GAS.deployPxom
  );

  // CommitteeAttestorLib is DELEGATECALL-linked into the escrow.
  const libraryAddress = await deployOnce(
    state,
    "committeeAttestorLib",
    "CommitteeAttestorLib",
    await hre.ethers.getContractFactory("CommitteeAttestorLib"),
    [],
    GAS.deployLibrary
  );

  const escrowFactory = await hre.ethers.getContractFactory("PrivateMarketplaceEscrow", {
    libraries: { CommitteeAttestorLib: libraryAddress },
  });

  // Implementation: `_disableInitializers()` in the constructor, so it holds no
  // state; the proxy below is the live contract.
  const implAddress = await deployOnce(
    state,
    "escrowImplementation",
    "PrivateMarketplaceEscrow (implementation)",
    escrowFactory,
    [],
    GAS.deployImpl
  );

  // Proxy: ERC1967Proxy(impl, initialize(admin, [relayer], [arbitrator],
  // feeVault, address(0))). Admin = deployer; feeVault = deployer so the vault's
  // 0 % / 5 % payout is decryptable in this proof; no ERC-2771 forwarder.
  const proxyFactory = await hre.ethers.getContractFactory(PROXY_ARTIFACT);
  let proxyAddress = state.deployments.escrowProxy?.address;
  if (
    proxyAddress === undefined ||
    (await hre.ethers.provider.getCode(proxyAddress)) === "0x"
  ) {
    const initData = escrowFactory.interface.encodeFunctionData("initialize", [
      actors.deployer.address,
      [actors.deployer.address],
      [actors.arbitrator.address],
      actors.deployer.address,
      ethers.ZeroAddress,
    ]);
    proxyAddress = await deployOnce(
      state,
      "escrowProxy",
      "ERC1967Proxy(PrivateMarketplaceEscrow)",
      proxyFactory,
      [implAddress, initData],
      GAS.deployProxy
    );
  } else {
    log(`  ERC1967Proxy(PrivateMarketplaceEscrow): already deployed at ${proxyAddress} (skip)`);
  }

  const escrowAsDeployer = new ethers.Contract(proxyAddress, ESCROW_ABI, deployerSigner);

  // initializeV2(3, 3, pool, 0): the self-hosted committee. Pool of three with
  // N = 3 means committeeFor() is always the whole pool, so all three sign.
  const committee = [
    actors.committeeB.address,
    actors.committeeC.address,
    actors.deployer.address,
  ]
    .map((a) => ethers.getAddress(a))
    .sort((a, b) => (BigInt(a) < BigInt(b) ? -1 : BigInt(a) > BigInt(b) ? 1 : 0));

  const boundToken = await escrowAsDeployer.privateToken().catch(() => ethers.ZeroAddress);
  if (boundToken.toLowerCase() !== pxomAddress.toLowerCase()) {
    if (boundToken !== ethers.ZeroAddress) {
      fail(
        `proxy ${proxyAddress} is already bound to token ${boundToken}, not ${pxomAddress} — refusing to mix a proof against an unknown token`
      );
    }
    await step(
      "initializeV2(3, 3, pool, 0)",
      escrowAsDeployer.initializeV2(3, 3, committee, 0, { gasLimit: GAS.initV2 }),
      GAS.initV2
    );
    await step(
      `initializeV3(${short(pxomAddress)})`,
      escrowAsDeployer.initializeV3(pxomAddress, { gasLimit: GAS.initV3 }),
      GAS.initV3
    );
  } else {
    log("  committee + pXOM already bound on the proxy (skip both initializers)");
  }
  state.deployments.committee = committee;
  state.deployments.committeeSize = 3;
  state.deployments.quorumM = 3;
  writeJson(STATE_FILE, state);

  // The arbitrator needs ARBITRATOR_ROLE to call arbitrate().
  const arbRole = await escrowAsDeployer.ARBITRATOR_ROLE();
  if (!(await escrowAsDeployer.hasRole(arbRole, actors.arbitrator.address))) {
    await step(
      "grantRole(ARBITRATOR_ROLE, arbitrator)",
      escrowAsDeployer.grantRole(arbRole, actors.arbitrator.address, {
        gasLimit: GAS.grantRole,
      }),
      GAS.grantRole
    );
  } else {
    log("  ARBITRATOR_ROLE: already granted (skip)");
  }

  // The live fees must be the values this proof is about.
  const liveFee = await escrowAsDeployer.escrowFeeBps();
  const liveArb = await escrowAsDeployer.ARBITRATION_FEE_BPS();
  if (liveFee !== 0n) {
    fail(
      `escrowFeeBps() is ${liveFee.toString()} on the fresh proxy, expected 0 — the release leg would not be a zero-fee proof`
    );
  }
  if (liveArb !== 500n) {
    fail(`ARBITRATION_FEE_BPS() is ${liveArb.toString()}, expected 500`);
  }
  state.deployments.liveEscrowFeeBps = liveFee.toString();
  state.deployments.liveArbitrationFeeBps = liveArb.toString();
  writeJson(STATE_FILE, state);
  log(
    `  live escrowFeeBps() = ${liveFee.toString()} · ARBITRATION_FEE_BPS() = ${liveArb.toString()}`
  );

  // Seed the buyer with pXOM (10x the two prices).
  const pxomAsDeployer = new ethers.Contract(pxomAddress, PXOM_ABI, deployerSigner);
  const buyerBalance = await readBalance(pxomAsDeployer, actors.buyer);
  if (buyerBalance.plaintext === undefined || buyerBalance.plaintext < PRICE * 4n) {
    await step(
      `mint ${ethers.formatUnits(PRICE * 10n, 18)} pXOM → buyer`,
      pxomAsDeployer.mint(actors.buyer.address, PRICE * 10n, { gasLimit: GAS.mint }),
      GAS.mint
    );
  } else {
    log(`  buyer already holds ${ethers.formatUnits(buyerBalance.plaintext, 18)} pXOM (skip mint)`);
  }

  return {
    pxom: pxomAddress,
    pxomAsBuyer: new ethers.Contract(pxomAddress, PXOM_ABI, actors.buyer.wallet),
    pxomAsDeployer,
    escrow: proxyAddress,
    escrowAsBuyer: new ethers.Contract(proxyAddress, ESCROW_ABI, actors.buyer.wallet),
    escrowAsSeller: new ethers.Contract(proxyAddress, ESCROW_ABI, actors.seller.wallet),
    escrowAsArbitrator: new ethers.Contract(proxyAddress, ESCROW_ABI, actors.arbitrator.wallet),
    escrowAsDeployer,
    committee,
  };
}

// ════════════════════════════════════════════════════════════════════════════
//                            COMMITTEE + CREATE
// ════════════════════════════════════════════════════════════════════════════

/**
 * Build a committee proof `commitBlock(32) || sig0(65) || sig1(65) || sig2(65)`.
 *
 * Signers sign the eth-signed envelope of the EIP-712 digest
 * (`toEthSignedMessageHash` in CommitteeAttestorLib) and must appear in
 * ascending address order. The proxy's own `committeeFor` is consulted first,
 * so a change to the selection algorithm fails here with a message instead of
 * a bare revert.
 * @param escrowReadOnly - Escrow contract bound to a provider.
 * @param actors - Actor map.
 * @param committee - The sorted committee pool recorded at deploy time.
 * @param digest - EIP-712 digest of the create intent.
 * @returns {Promise<string>} proof bytes.
 */
async function buildCommitteeProof(escrowReadOnly, actors, committee, digest) {
  const head = await hre.ethers.provider.getBlockNumber();
  const commitBlock = head - 3; // inside the 256-block blockhash window
  const block = await hre.ethers.provider.getBlock(commitBlock);
  const previous = await hre.ethers.provider.getBlock(commitBlock - 1);
  if (block?.hash == null || previous?.hash == null) {
    fail(`blockhash unavailable for commitBlock ${String(commitBlock)}`);
  }

  const onChain = await escrowReadOnly.committeeFor(digest, commitBlock);
  const expected = [...committee];
  if (
    onChain.length !== expected.length ||
    onChain.some((a, i) => a.toLowerCase() !== expected[i].toLowerCase())
  ) {
    fail(
      `committeeFor(${digest}, ${String(commitBlock)}) returned [${onChain.join(", ")}] but the pool is [${expected.join(", ")}] — the selection algorithm changed; refusing to sign a proof this script cannot verify`
    );
  }

  const signatures = [];
  for (const signer of [actors.committeeB, actors.committeeC, actors.deployer]) {
    const signature = await signer.wallet.signMessage(ethers.getBytes(digest));
    const recovered = ethers.verifyMessage(ethers.getBytes(digest), signature);
    if (recovered.toLowerCase() !== signer.address.toLowerCase()) {
      fail(`committee signature did not recover to ${signer.address}`);
    }
    signatures.push({ address: recovered.toLowerCase(), signature });
  }
  signatures.sort((a, b) => (BigInt(a.address) < BigInt(b.address) ? -1 : 1));
  return ethers.concat([
    ethers.toBeHex(commitBlock, 32),
    ...signatures.map((s) => s.signature),
  ]);
}

/**
 * Create one escrow, or adopt the one a previous run created.
 * @returns The escrow id, its create-time fee snapshot, and the custody
 *          evidence gathered around the create (when it ran now).
 */
async function createLeg(state, actors, stack, leg) {
  log(`\n[leg ${leg.key}] create`);
  const listingRef = ethers.zeroPadValue(ethers.toUtf8Bytes(leg.listing), 32);
  const feeBps = await stack.escrowAsDeployer.escrowFeeBps();
  const deadline = BigInt(Math.floor(Date.now() / 1000) + 30 * 24 * 3600);
  // Deterministic id: a re-run adopts its own escrow instead of creating one.
  const escrowId = ethers.keccak256(
    ethers.AbiCoder.defaultAbiCoder().encode(
      ["address", "address", "bytes32", "uint64"],
      [actors.buyer.address, actors.seller.address, listingRef, feeBps]
    )
  );
  const recorded = state.legs[leg.key];
  if (recorded?.escrowId !== undefined && recorded.escrowId !== escrowId) {
    fail(
      `leg ${leg.key}: recorded escrow id ${recorded.escrowId} differs from the deterministic id ${escrowId} — refusing to overwrite a recorded proof`
    );
  }

  const existing = await stack.escrowAsDeployer.escrows(escrowId);
  if (Number(existing.status) !== STATUS.EMPTY) {
    log(
      `  escrow ${escrowId.slice(0, 12)}… already exists (status ${String(Number(existing.status))}) — reusing`
    );
    return {
      escrowId,
      createdAt: existing.createdAt,
      feeBpsAtCreate: existing.escrowFeeBpsAtCreate,
      created: false,
      custody: undefined,
    };
  }

  const buyerBefore = await readBalance(stack.pxomAsBuyer, actors.buyer);

  // 1. Buyer approves the escrow for the encrypted price. Reset to zero first:
  //    PrivateERC20 refuses a non-zero → non-zero approve.
  try {
    await step(
      "approve(escrow, 0)",
      stack.pxomAsBuyer
        .getFunction("approve(address,uint256)")(stack.escrow, 0n, {
          gasLimit: GAS.approveReset,
        }),
      GAS.approveReset
    );
  } catch (err) {
    log(
      `  approve(escrow, 0): skipped (${
        err instanceof Error ? err.shortMessage ?? err.message : String(err)
      })`
    );
  }

  const approveSelector = stack.pxomAsBuyer.interface.getFunction(
    "approve(address,((uint256,uint256),bytes))"
  ).selector;
  const encryptedApprove = it256(actors.buyer.wallet, PRICE, stack.pxom, approveSelector);
  const approveStep = await step(
    "approve(escrow, itUint256(price))",
    stack.pxomAsBuyer.getFunction("approve(address,((uint256,uint256),bytes))")(
      stack.escrow,
      encryptedApprove,
      { gasLimit: GAS.approveEncrypted }
    ),
    GAS.approveEncrypted
  );

  // 2. Buyer encrypts the price as a signed input ciphertext for the create.
  const createSelector = stack.escrowAsDeployer.interface.getFunction(
    "createEscrowWithCommittee"
  ).selector;
  const encryptedPrice = it256(actors.buyer.wallet, PRICE, stack.escrow, createSelector);
  const commit = commitOf(encryptedPrice);

  // 3. Buyer signs the EIP-712 intent; the committee attests the same digest.
  const domain = {
    name: EIP712_DOMAIN_NAME,
    version: EIP712_DOMAIN_VERSION,
    chainId: CHAIN_ID,
    verifyingContract: stack.escrow,
  };
  const message = {
    escrowId,
    buyer: actors.buyer.address,
    seller: actors.seller.address,
    arbitrator: actors.arbitrator.address,
    listingRef,
    priceCommit: commit,
    escrowFeeBps: feeBps,
    deadline,
  };
  const buyerSignature = await actors.buyer.wallet.signTypedData(
    domain,
    CREATE_ESCROW_TYPES,
    message
  );
  const digest = ethers.TypedDataEncoder.hash(domain, CREATE_ESCROW_TYPES, message);
  const proof = await buildCommitteeProof(
    stack.escrowAsDeployer,
    actors,
    stack.committee,
    digest
  );

  // 4. Buyer broadcasts: validateCiphertext binds the ciphertext to msg.sender,
  //    so the buyer (not the deployer) must be the caller.
  const createStep = await step(
    "createEscrowWithCommittee",
    stack.escrowAsBuyer.createEscrowWithCommittee(
      escrowId,
      actors.buyer.address,
      actors.seller.address,
      actors.arbitrator.address,
      listingRef,
      encryptedPrice,
      feeBps,
      deadline,
      buyerSignature,
      proof,
      { gasLimit: GAS.createEscrow }
    ),
    GAS.createEscrow,
    stack.escrowAsDeployer.interface
  );

  const created = await stack.escrowAsDeployer.escrows(escrowId);
  if (Number(created.status) !== STATUS.ACTIVE) {
    fail(`escrow ${escrowId} was created with status ${String(Number(created.status))}, expected ACTIVE`);
  }
  if (created.escrowFeeBpsAtCreate !== feeBps) {
    fail(
      `escrow ${escrowId} snapshotted fee ${created.escrowFeeBpsAtCreate.toString()}, expected ${feeBps.toString()}`
    );
  }

  const buyerAfter = await readBalance(stack.pxomAsBuyer, actors.buyer);
  const custody = {
    price: PRICE.toString(),
    buyerBefore: buyerBefore.plaintext?.toString(),
    buyerAfter: buyerAfter.plaintext?.toString(),
    buyerDelta:
      buyerBefore.plaintext !== undefined && buyerAfter.plaintext !== undefined
        ? (buyerAfter.plaintext - buyerBefore.plaintext).toString()
        : undefined,
  };

  const prior = state.legs[leg.key] ?? {};
  state.legs[leg.key] = {
    ...prior,
    escrowId,
    price: PRICE.toString(),
    feeBpsAtCreate: created.escrowFeeBpsAtCreate.toString(),
    deadline: created.deadline.toString(),
    createdAt: created.createdAt.toString(),
    digest,
    custody,
    steps: {
      ...(prior.steps ?? {}),
      approve: approveStep,
      create: createStep,
    },
  };
  writeJson(STATE_FILE, state);
  return {
    escrowId,
    createdAt: created.createdAt,
    feeBpsAtCreate: created.escrowFeeBpsAtCreate,
    created: true,
    custody,
  };
}

// ════════════════════════════════════════════════════════════════════════════
//                                 THE LEGS
// ════════════════════════════════════════════════════════════════════════════

/** Snapshot the three balances a settlement moves. */
async function snapshot(stack, actors) {
  return {
    buyer: await readBalance(stack.pxomAsDeployer, actors.buyer),
    seller: await readBalance(stack.pxomAsDeployer, actors.seller),
    vault: await readBalance(stack.pxomAsDeployer, actors.deployer),
  };
}

/** Compare two snapshots into plaintext deltas + ciphertext-change flags. */
function deltas(before, after) {
  const result = {};
  for (const who of ["buyer", "seller", "vault"]) {
    const b = before[who];
    const a = after[who];
    result[who] = {
      before: b.plaintext?.toString(),
      after: a.plaintext?.toString(),
      delta:
        b.plaintext !== undefined && a.plaintext !== undefined
          ? (a.plaintext - b.plaintext).toString()
          : undefined,
      ciphertextChanged: b.ciphertext !== a.ciphertext,
    };
  }
  return result;
}

/** Assert a decrypted delta when decryption worked; note it when it did not. */
function assertDelta(label, observed, expected, notes) {
  if (observed === undefined) {
    notes.push(
      `${label}: balance could not be decrypted with our AES key — this leg rests on the receipt and the escrow status`
    );
    return;
  }
  if (BigInt(observed) !== expected) {
    fail(`${label}: delta ${observed} != expected ${expected.toString()}`);
  }
  notes.push(`${label}: delta ${observed} == expected ${expected.toString()}`);
}

/** Leg 1 — release at fee 0. */
async function runReleaseLeg(state, actors, stack) {
  const leg = LEGS.releaseFeeZero;
  log(`\n[leg ${leg.key}] ${leg.label}`);
  const created = await createLeg(state, actors, stack, leg);
  if (created.custody?.buyerDelta !== undefined) {
    // The encrypted custody pull happened at create; assert it before the leg's
    // own deltas so a failed pull can never hide behind a successful release.
    assertDelta("buyer (custody pull at create)", created.custody.buyerDelta, -PRICE, []);
    log(`  custody: buyer paid ${created.custody.buyerDelta} base units at create (encrypted pull)`);
  }

  let current = await stack.escrowAsDeployer.escrows(created.escrowId);
  if (current.escrowFeeBpsAtCreate !== 0n) {
    fail(`leg 1: escrow snapshotted fee ${current.escrowFeeBpsAtCreate.toString()}, expected 0`);
  }
  if (Number(current.status) === STATUS.RELEASED) {
    log("  already released — nothing to send");
    const settled = await stack.escrowAsDeployer.escrows(created.escrowId);
    const prior = state.legs[leg.key] ?? {};
    state.legs[leg.key] = { ...prior, status: "RELEASED", verified: true };
    writeJson(STATE_FILE, state);
    return state.legs[leg.key];
  }
  if (Number(current.status) !== STATUS.ACTIVE) {
    fail(`leg 1: status ${String(Number(current.status))} is not ACTIVE — cannot release`);
  }

  const before = await snapshot(stack, actors);
  const releaseStep = await step(
    "release(escrowId)  [buyer, fee 0]",
    stack.escrowAsBuyer.release(created.escrowId, { gasLimit: GAS.release }),
    GAS.release,
    stack.escrowAsDeployer.interface
  );
  const after = await snapshot(stack, actors);

  const settled = await stack.escrowAsDeployer.escrows(created.escrowId);
  if (Number(settled.status) !== STATUS.RELEASED) {
    fail(`leg 1: release left status ${String(Number(settled.status))}, expected RELEASED`);
  }

  const notes = [];
  const diff = deltas(before, after);
  assertDelta("seller (full price)", diff.seller.delta, PRICE, notes);
  assertDelta("vault (escrow fee)", diff.vault.delta, 0n, notes);
  assertDelta("buyer (release pays nothing)", diff.buyer.delta, 0n, notes);

  const prior = state.legs[leg.key] ?? {};
  state.legs[leg.key] = {
    ...prior,
    status: "RELEASED",
    txHash: releaseStep.txHash,
    blockNumber: releaseStep.blockNumber,
    gasUsed: releaseStep.gasUsed,
    balanceDeltas: diff,
    notes,
    verified: true,
    verifiedAt: new Date().toISOString(),
    steps: { ...(prior.steps ?? {}), release: releaseStep },
  };
  writeJson(STATE_FILE, state);
  log("  ✓ released at fee 0: seller paid in full, fee vault moved nothing");
  return state.legs[leg.key];
}

/** Leg 2 — dispute settles at the 5 % arbitration rate. */
async function runDisputeLeg(state, actors, stack) {
  const leg = LEGS.disputeArbitration;
  log(`\n[leg ${leg.key}] ${leg.label}`);
  const created = await createLeg(state, actors, stack, leg);

  let current = await stack.escrowAsDeployer.escrows(created.escrowId);
  const disputeAfter =
    BigInt(created.createdAt) + (await stack.escrowAsDeployer.MIN_DISPUTE_DELAY());

  if (Number(current.status) === STATUS.ACTIVE) {
    const now = BigInt(Math.floor(Date.now() / 1000));
    if (now < disputeAfter) {
      const wait = Number(disputeAfter - now);
      const when = new Date(Number(disputeAfter) * 1000).toISOString();
      if (process.env.COTI_TESTNET_PROOF_WAIT === "1") {
        log(`  waiting ${Math.ceil(wait / 3600)} h for MIN_DISPUTE_DELAY (until ${when})…`);
        await sleep(wait + 5, "dispute window");
      } else {
        const prior = state.legs[leg.key] ?? {};
        state.legs[leg.key] = {
          ...prior,
          status: "ACTIVE (waiting for MIN_DISPUTE_DELAY)",
          disputeAfter: disputeAfter.toString(),
          disputeAfterUtc: when,
          verified: false,
        };
        writeJson(STATE_FILE, state);
        console.error(
          [
            "",
            "NEXT STEP IS TIME-BLOCKED — the dispute leg needs MIN_DISPUTE_DELAY (24 h) after create.",
            `  escrow ${created.escrowId}`,
            `  dispute opens at ${when}`,
            "",
            "Re-run the same command after that time (it resumes at the dispute):",
            "  COTI_DEPLOYER_PRIVATE_KEY=0x… COTI_TESTNET_PROOF=1 \\",
            "    NODE_PATH=/home/omnirick/OmniBazaar/node_modules \\",
            "    npx hardhat run scripts/coti-private-escrow-fee-proof.cjs --network cotiTestnet",
            "  (add COTI_TESTNET_PROOF_WAIT=1 to sleep through the window instead)",
            "",
          ].join("\n")
        );
        process.exit(3);
      }
    }

    const prior = state.legs[leg.key] ?? {};
    const disputeStep = await step(
      "dispute(escrowId)  [seller]",
      stack.escrowAsSeller.dispute(created.escrowId, { gasLimit: GAS.dispute }),
      GAS.dispute,
      stack.escrowAsDeployer.interface
    );
    state.legs[leg.key] = {
      ...prior,
      steps: { ...(prior.steps ?? {}), dispute: disputeStep },
    };
    writeJson(STATE_FILE, state);
    current = await stack.escrowAsDeployer.escrows(created.escrowId);
  }

  if (Number(current.status) === STATUS.DISPUTED) {
    const before = await snapshot(stack, actors);
    const arbitrateStep = await step(
      "arbitrate(escrowId, seller)  [arbitrator, 5 %]",
      stack.escrowAsArbitrator.arbitrate(created.escrowId, actors.seller.address, {
        gasLimit: GAS.arbitrate,
      }),
      GAS.arbitrate,
      stack.escrowAsDeployer.interface
    );
    const after = await snapshot(stack, actors);

    const settled = await stack.escrowAsDeployer.escrows(created.escrowId);
    if (Number(settled.status) !== STATUS.ARBITRATED_TO_SELLER) {
      fail(
        `leg 2: arbitrate left status ${String(Number(settled.status))}, expected ARBITRATED_TO_SELLER`
      );
    }
    const arbitrationFee = (PRICE * 500n) / 10_000n;
    const winnerShare = PRICE - arbitrationFee;
    const notes = [];
    const diff = deltas(before, after);
    assertDelta("vault (5 % arbitration fee)", diff.vault.delta, arbitrationFee, notes);
    assertDelta("seller (winner, 95 %)", diff.seller.delta, winnerShare, notes);

    const prior = state.legs[leg.key] ?? {};
    state.legs[leg.key] = {
      ...prior,
      status: "ARBITRATED_TO_SELLER",
      arbitrationFeeBps: "500",
      expectedArbitrationFee: arbitrationFee.toString(),
      expectedWinnerShare: winnerShare.toString(),
      txHash: arbitrateStep.txHash,
      blockNumber: arbitrateStep.blockNumber,
      gasUsed: arbitrateStep.gasUsed,
      balanceDeltas: diff,
      notes,
      verified: true,
      verifiedAt: new Date().toISOString(),
      steps: { ...(prior.steps ?? {}), arbitrate: arbitrateStep },
    };
    writeJson(STATE_FILE, state);
    log("  ✓ arbitration settled at 5 %: vault took 5 %, the winner 95 %");
    return state.legs[leg.key];
  }

  if (
    Number(current.status) === STATUS.ARBITRATED_TO_SELLER ||
    Number(current.status) === STATUS.ARBITRATED_TO_BUYER
  ) {
    log("  already arbitrated — nothing to send");
    const prior = state.legs[leg.key] ?? {};
    state.legs[leg.key] = {
      ...prior,
      // Keep the summary printable when an earlier run arbitrated on chain but
      // stopped before it could write the receipt (the constant is a getter, so
      // its value is still a fact of the deployed contract).
      arbitrationFeeBps: prior.arbitrationFeeBps ?? "500",
      expectedArbitrationFee: prior.expectedArbitrationFee ?? ((PRICE * 500n) / 10_000n).toString(),
      expectedWinnerShare: prior.expectedWinnerShare ?? (PRICE - (PRICE * 500n) / 10_000n).toString(),
      verified: true,
    };
    writeJson(STATE_FILE, state);
    return state.legs[leg.key];
  }

  fail(`leg 2: unexpected status ${String(Number(current.status))}`);
}

// ════════════════════════════════════════════════════════════════════════════
//                                  ENTRY
// ════════════════════════════════════════════════════════════════════════════

async function main() {
  log("COTI testnet private-escrow fee proof (chain 7082400)");
  log("Every assertion is a real transaction + receipt; the MPC precompile at");
  log("0x…0064 cannot be simulated with eth_call, so nothing here is proven by one.\n");

  await assertAbisMatchSource();

  const gateMissing = [];
  if (process.env.COTI_TESTNET_PROOF !== "1") {
    gateMissing.push(
      "COTI_TESTNET_PROOF=1 is not set — the broadcast gate; without it this script must not deploy or send"
    );
  }
  if (
    process.env.COTI_DEPLOYER_PRIVATE_KEY === undefined ||
    process.env.COTI_DEPLOYER_PRIVATE_KEY.length === 0
  ) {
    gateMissing.push(
      "COTI_DEPLOYER_PRIVATE_KEY is not set — hardhat builds no signer for --network cotiTestnet without it"
    );
  }
  if (gateMissing.length > 0) {
    printRefusal(gateMissing);
    process.exit(2);
  }

  const state = loadState();
  const [deployerSigner] = await hre.ethers.getSigners();
  const actors = buildActors(state, await deployerSigner.getAddress());
  log(`  buyer      ${actors.buyer.address}`);
  log(`  seller     ${actors.seller.address}`);
  log(`  arbitrator ${actors.arbitrator.address}`);
  log(
    `  committee  ${actors.committeeB.address} ${actors.committeeC.address} ${actors.deployer.address}`
  );
  log(`  feeVault   ${actors.deployer.address}`);
  log(`  state file ${STATE_FILE}`);

  await preflight(actors);
  rememberKeys(state, actors);

  log("\n[0/4] Funding + onboarding");
  await fundActors(actors, deployerSigner, ["buyer", "seller", "arbitrator"]);
  await onboardForMpc(actors, ["buyer", "seller", "deployer"]);
  rememberKeys(state, actors);

  const stack = await deployStack(state, actors, deployerSigner);
  writeJson(STATE_FILE, state);

  const release = await runReleaseLeg(state, actors, stack);
  const dispute = await runDisputeLeg(state, actors, stack);

  state.completedAt = new Date().toISOString();
  state.summary = {
    releaseFeeBps: release.feeBpsAtCreate,
    releaseTx: release.txHash,
    releaseBlock: release.blockNumber,
    releaseGasUsed: release.gasUsed,
    arbitrationFeeBps: dispute.arbitrationFeeBps,
    arbitrationTx: dispute.txHash,
    arbitrationBlock: dispute.blockNumber,
    arbitrationGasUsed: dispute.gasUsed,
  };
  writeJson(STATE_FILE, state);

  log("\n═══ RESULT ═══");
  log(
    `  leg 1  release @ ${release.feeBpsAtCreate} bps      tx ${release.txHash} · block ${String(release.blockNumber)} · gas ${release.gasUsed}`
  );
  log(
    `  leg 2  arbitration @ ${dispute.arbitrationFeeBps} bps    tx ${dispute.txHash} · block ${String(dispute.blockNumber)} · gas ${dispute.gasUsed}`
  );
  log(`  summary written to ${STATE_FILE}`);
}

main().catch((err) => {
  console.error(`\nPROOF FAILED: ${err instanceof Error ? err.message : String(err)}`);
  if (err instanceof Error && err.stack !== undefined) {
    console.error(err.stack.split("\n").slice(1, 4).join("\n"));
  }
  process.exitCode = 1;
});
