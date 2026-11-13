/**
 * Upgrade PrivateMarketplaceEscrow on COTI mainnet to the 5 % arbitration fee
 * build (ARBITRATION_FEE_BPS 250 -> 500, founder decision 2026-11-13).
 *
 * TWO MODES:
 *   (default) --dry-run  Read-only. Reads the live proxy's implementation,
 *                        admin role, TIMELOCK_DELAY, ossification flag, pending
 *                        upgrade and live ARBITRATION_FEE_BPS, prints the size
 *                        of the build that WOULD be deployed, and prints the
 *                        exact command to broadcast. Sends nothing.
 *   --broadcast          Deploy the new implementation (linked to the deployed
 *                        CommitteeAttestorLib), then run the contract's
 *                        two-step UUPS gate on the proxy:
 *                          requestUpgrade(newImpl)      (queues effectiveAt)
 *                          upgradeToAndCall(newImpl,"0x") after TIMELOCK_DELAY
 *                        TIMELOCK_DELAY is 0 under the Pioneer-Phase rule, so
 *                        effectiveAt is the request block's timestamp and no
 *                        wait is needed.
 *
 * The deployment record (deployments/coti-mainnet.json,
 * `privacyV2.PrivateMarketplaceEscrow`) is NOT written here. The script prints
 * the exact patch; the record is written only after the upgrade lands and the
 * new implementation is verified on-chain.
 *
 * 🛑 The proxy's DEFAULT_ADMIN_ROLE hash is bytes32(0) — NOT
 * keccak256("DEFAULT_ADMIN_ROLE"). Probing the hashed value reports "not
 * admin" on a contract the deployer fully controls, so this script reads the
 * canonical constant from the contract and cross-checks it equals 0x00.
 *
 * Usage (dry run, the only mode you should run by hand):
 *   cd Coin
 *   NODE_PATH=/home/omnirick/OmniBazaar/node_modules \
 *     npx hardhat run scripts/upgrade-private-escrow-arbitration-fee.cjs \
 *     --network cotiMainnet
 *
 * Broadcast (orchestrator only):
 *   add `--broadcast` after the script path.
 */
const fs = require("fs");
const hre = require("hardhat");

const PROXY = "0x43d216073D3c7B494FA3626C0607FfF14758A670";
const LIBRARY = "0x782fB33b895B229AcCB34970E73840DcF07f4108";
const EXPECTED_DEPLOYER = "0x021868f2E3D49C059EF52B539AAa933B437e0321";
const KEY_PATH = "/home/omnirick/.avalanche-cli/key/deployer.pk";
const CHAIN_ID = 2632500n;
const EIP170_LIMIT = 24576;
const EXPECTED_ARBITRATION_FEE_BPS = 500n;
const CONTRACT = "PrivateMarketplaceEscrow";
const RECORD = JSON.parse(
  fs.readFileSync(
    require("path").join(__dirname, "..", "deployments", "coti-mainnet.json"),
    "utf8",
  ),
);

/** ERC-1967 implementation slot. */
const IMPL_SLOT =
  "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";

const PROXY_ABI = [
  "function DEFAULT_ADMIN_ROLE() view returns (bytes32)",
  "function hasRole(bytes32 role, address account) view returns (bool)",
  "function TIMELOCK_DELAY() view returns (uint256)",
  "function ARBITRATION_FEE_BPS() view returns (uint64)",
  "function BASIS_POINTS_DIVISOR() view returns (uint256)",
  "function isOssified() view returns (bool)",
  "function pendingUpgrade() view returns (address newImplementation, uint256 effectiveAt)",
  "function privateToken() view returns (address)",
  "function feeVault() view returns (address)",
  "function requestUpgrade(address newImplementation)",
  "function cancelUpgrade()",
  "function upgradeToAndCall(address newImplementation, bytes data) payable",
];

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function parseArgs(argv) {
  const broadcast = argv.includes("--broadcast");
  const dryRun = argv.includes("--dry-run");
  if (broadcast && dryRun) {
    throw new Error("pass either --dry-run or --broadcast, not both");
  }
  return { broadcast };
}

/** Load the deployer key and prove it is the expected address. */
function loadDeployer(provider) {
  const envKey = process.env.COTI_MAINNET_DEPLOYER_PRIVATE_KEY;
  let key = envKey;
  if (!key) {
    if (!fs.existsSync(KEY_PATH)) {
      throw new Error(`deployer key not found: ${KEY_PATH}`);
    }
    key = fs.readFileSync(KEY_PATH, "utf8").trim();
  }
  const normalised = key.startsWith("0x") ? key : `0x${key}`;
  const wallet = new hre.ethers.Wallet(normalised, provider);
  if (wallet.address.toLowerCase() !== EXPECTED_DEPLOYER.toLowerCase()) {
    throw new Error(
      `wrong signer: ${wallet.address} (expected ${EXPECTED_DEPLOYER})`,
    );
  }
  return wallet;
}

async function main() {
  const { broadcast } = parseArgs(process.argv.slice(2));
  const { ethers } = hre;
  const network = await ethers.provider.getNetwork();
  if (network.chainId !== CHAIN_ID) {
    throw new Error(
      `wrong chain: ${network.chainId} (expected ${CHAIN_ID} — pass --network cotiMainnet)`,
    );
  }

  const provider = new ethers.JsonRpcProvider(
    hre.network.config.url,
    Number(CHAIN_ID),
  );
  const proxy = new ethers.Contract(PROXY, PROXY_ABI, provider);
  const implFactory = await ethers.getContractFactory(CONTRACT, {
    libraries: { CommitteeAttestorLib: LIBRARY },
  });

  // ---- Build size (the build that a broadcast would deploy) -------------
  const deployedBytes = implFactory.bytecode.length / 2 - 1;
  const art = await hre.artifacts.readArtifact(CONTRACT);
  const linkedDeployedBytes = art.deployedBytecode.length / 2 - 1;

  console.log("network:            ", network.name, network.chainId.toString());
  console.log("proxy:              ", PROXY);
  console.log("CommitteeAttestorLib", LIBRARY);
  console.log("new impl deployed bytes:", linkedDeployedBytes, `(limit ${EIP170_LIMIT})`);
  console.log("new impl creation bytes:", deployedBytes);
  if (linkedDeployedBytes >= EIP170_LIMIT) {
    throw new Error(
      `deployed bytecode ${linkedDeployedBytes} >= EIP-170 limit ${EIP170_LIMIT}`,
    );
  }

  // ---- Live proxy state -------------------------------------------------
  if ((await provider.getCode(PROXY)) === "0x") {
    throw new Error(`no code at proxy ${PROXY} — wrong chain or wrong address`);
  }
  const currentImpl = ethers.getAddress(
    `0x${(await provider.getStorage(PROXY, IMPL_SLOT)).slice(-40)}`,
  );
  const liveFeeBps = await proxy.ARBITRATION_FEE_BPS();
  const adminRole = await proxy.DEFAULT_ADMIN_ROLE();
  const timelockDelay = await proxy.TIMELOCK_DELAY();
  const ossified = await proxy.isOssified();
  const pending = await proxy.pendingUpgrade();
  const recordImpl = RECORD.privacyV2?.[CONTRACT]?.implementation;

  console.log("current impl:       ", currentImpl);
  console.log("record impl:        ", recordImpl, "(coti-mainnet.json)");
  console.log("live ARBITRATION_FEE_BPS:", liveFeeBps.toString());
  console.log("DEFAULT_ADMIN_ROLE: ", adminRole, "(bytes32(0) expected)");
  console.log("TIMELOCK_DELAY:     ", timelockDelay.toString(), "seconds");
  console.log("isOssified:         ", ossified);
  console.log(
    "pendingUpgrade:     ",
    pending[0],
    "effectiveAt",
    pending[1].toString(),
  );

  if (adminRole !== ethers.ZeroHash) {
    throw new Error(
      `DEFAULT_ADMIN_ROLE read back ${adminRole}, expected 0x${"0".repeat(64)} — aborting rather than probing a different role`,
    );
  }
  if (ossified) throw new Error("contract is ossified — upgrades are permanent-off");
  if (timelockDelay !== 0n) {
    console.log(
      `NOTE: TIMELOCK_DELAY is ${timelockDelay} s, not 0 — requestUpgrade will need a real wait`,
    );
  }
  if (pending[1] !== 0n) {
    throw new Error(
      `an upgrade is already queued to ${pending[0]} (effectiveAt ${pending[1]}) — cancelUpgrade() first or resume with that address`,
    );
  }
  if (liveFeeBps === EXPECTED_ARBITRATION_FEE_BPS) {
    console.log(
      "NOTE: the live constant already reads 500 — this build may already be deployed. Check the impl address before broadcasting.",
    );
  }

  // ---- Dry run ends here ------------------------------------------------
  if (!broadcast) {
    const deployer = loadDeployer(provider);
    const isAdmin = await proxy.hasRole(adminRole, deployer.address);
    console.log("\n[dry-run] signer:", deployer.address, "holds DEFAULT_ADMIN_ROLE:", isAdmin);
    if (!isAdmin) {
      throw new Error(
        "deployer does not hold DEFAULT_ADMIN_ROLE — requestUpgrade would revert",
      );
    }
    console.log("\n[dry-run] no transactions sent. Broadcast with:");
    console.log(
      `  cd Coin && NODE_PATH=/home/omnirick/OmniBazaar/node_modules npx hardhat run scripts/upgrade-private-escrow-arbitration-fee.cjs --network cotiMainnet --broadcast`,
    );
    console.log("\nPlanned broadcast steps:");
    console.log(
      `  1. deploy ${CONTRACT} impl + CommitteeAttestorLib ${LIBRARY} link + ARBITRATION_FEE_BPS() constructor-free check`,
    );
    console.log(`  2. requestUpgrade(<newImpl>) as ${EXPECTED_DEPLOYER}`);
    console.log(
      "  3. upgradeToAndCall(<newImpl>, \"0x\") on the proxy after TIMELOCK_DELAY (0 s)",
    );
    console.log("  4. verify ERC-1967 slot == <newImpl> and ARBITRATION_FEE_BPS() == 500");
    return;
  }

  // ---- Broadcast --------------------------------------------------------
  const deployer = loadDeployer(provider);
  const isAdmin = await proxy.hasRole(adminRole, deployer.address);
  if (!isAdmin) {
    throw new Error("deployer does not hold DEFAULT_ADMIN_ROLE — aborting");
  }
  console.log("\nBROADCAST as", deployer.address);

  console.log("1/4 deploying implementation...");
  const newImpl = await implFactory.connect(deployer).deploy();
  const deployTx = newImpl.deploymentTransaction();
  await newImpl.waitForDeployment();
  const newImplAddr = await newImpl.getAddress();
  await deployTx.wait();
  const code = await provider.getCode(newImplAddr);
  const codeSize = code.length / 2 - 1;
  console.log("    impl:", newImplAddr, "tx:", deployTx.hash);
  console.log("    deployed code size:", codeSize, "bytes");
  if (codeSize === 0 || codeSize >= EIP170_LIMIT) {
    throw new Error(`bad deployed code size ${codeSize} — refusing to upgrade`);
  }

  console.log("2/4 requestUpgrade...");
  const requestTx = await proxy
    .connect(deployer)
    .requestUpgrade(newImplAddr);
  await requestTx.wait();
  console.log("    tx:", requestTx.hash);
  const queued = await proxy.pendingUpgrade();
  const queuedImpl = ethers.getAddress(queued[0]);
  if (queuedImpl !== ethers.getAddress(newImplAddr)) {
    throw new Error(`queued ${queuedImpl} != deployed ${newImplAddr}`);
  }

  // TIMELOCK_DELAY is 0, but honour the contract's own gate if it is not.
  for (;;) {
    const latest = await provider.getBlock("latest");
    if (BigInt(latest.timestamp) >= queued[1]) break;
    const remaining = Number(queued[1] - BigInt(latest.timestamp));
    console.log(`    waiting ${remaining} s for effectiveAt ${queued[1]}`);
    await sleep(Math.min(remaining, 30) * 1000);
  }

  console.log("3/4 upgradeToAndCall...");
  const writeProxy = new ethers.Contract(PROXY, PROXY_ABI, deployer);
  const upgradeTx = await writeProxy.upgradeToAndCall(newImplAddr, "0x");
  await upgradeTx.wait();
  console.log("    tx:", upgradeTx.hash);

  console.log("4/4 verifying...");
  const liveImpl = ethers.getAddress(
    `0x${(await provider.getStorage(PROXY, IMPL_SLOT)).slice(-40)}`,
  );
  if (liveImpl !== ethers.getAddress(newImplAddr)) {
    throw new Error(`ERC-1967 slot reads ${liveImpl}, expected ${newImplAddr}`);
  }
  const newFeeBps = await proxy.ARBITRATION_FEE_BPS();
  if (newFeeBps !== EXPECTED_ARBITRATION_FEE_BPS) {
    throw new Error(`ARBITRATION_FEE_BPS reads ${newFeeBps}, expected 500`);
  }
  const postPending = await proxy.pendingUpgrade();
  if (postPending[1] !== 0n) throw new Error("pendingUpgrade not cleared");
  console.log("    ERC-1967 impl:", liveImpl);
  console.log("    ARBITRATION_FEE_BPS:", newFeeBps.toString());
  console.log("    privateToken:", await proxy.privateToken());
  console.log("    feeVault:", await proxy.feeVault());

  // ---- Record patch (printed, NOT written) ------------------------------
  const patch = {
    path: `privacyV2.${CONTRACT}.implementation`,
    previousImplementation: currentImpl,
    implementation: newImplAddr,
    deployedAt: new Date().toISOString(),
    deployer: deployer.address,
    upgradeReason:
      "Arbitration fee 250 -> 500 bps (5 %, founder decision 2026-11-13): the whole fee is deducted from the disputed amount at settlement, matching EscrowV2 DEFAULT_ARBITRATION_FEE_BPS",
    implDeployTx: deployTx.hash,
    upgradeTxRequest: requestTx.hash,
    upgradeTxApply: upgradeTx.hash,
    upgradesArrayEntry: {
      from: currentImpl,
      to: newImplAddr,
      reason:
        "Arbitration fee 250 -> 500 bps (founder decision 2026-11-13)",
      upgradedAt: new Date().toISOString(),
      requestUpgradeTx: requestTx.hash,
      upgradeToAndCallTx: upgradeTx.hash,
      implDeployTx: deployTx.hash,
    },
  };
  console.log("\ndeployment record patch (write after verification):");
  console.log(JSON.stringify(patch, null, 2));
  console.log("\nDONE");
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
