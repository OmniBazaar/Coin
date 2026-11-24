#!/usr/bin/env node
/**
 * Point the L1 specialization proxy at the removal forwarder, and put the real
 * staking manager back afterwards.
 *
 *   node scripts/upgrade-specialization-proxy.cjs             # dry run: install forwarder
 *   node scripts/upgrade-specialization-proxy.cjs --send      # broadcast once
 *   node scripts/upgrade-specialization-proxy.cjs --restore   # dry run: put the manager back
 *   node scripts/upgrade-specialization-proxy.cjs --restore --send
 *
 * Signed by the ProxyAdmin owner 0xaDAD7751 (deployer-nopfx.pk, on this host).
 * The upgrade is a single call to upgrade(address,address) (0x99a88ec4) on the
 * OZ ProxyAdmin. Both directions use the same code path, so the restore is not a
 * separate, unrehearsed mechanism.
 *
 * While the forwarder is installed, the staking manager's own entry points are
 * unreachable through the proxy. Nothing in Validator/, WebApp/, Wallet/ or
 * Mobile/ calls them, so this affects only the rotation itself.
 */
const { ethers } = require('ethers');
const fs = require('fs');
const path = require('path');

const RPC = process.env.RPC_URL || 'https://rpc.omnicoin.net';
const KEY_FILE =
  process.env.OWNER_KEY_FILE || path.join(process.env.HOME, '.avalanche-cli/key/deployer-nopfx.pk');

const OWNER = '0xaDAD7751DcDd2E30015C173F2c35a56e467CD9ba';
const PROXY_ADMIN = '0x97a35a4a2a8a56256de7a32160819c7b3f4c9da6';
const PROXY = '0x100c0De1C0FFEe00000000000000000000000000';

// Full addresses measured from the proxy's ERC-1967 slot on 2026-11-24.
const FORWARDER = '0x99080Bb402949ef3D69f6773e2Cc252655Abd43f';
const STAKING_MANAGER = '0x9338b9ef1291b0266d28e520797ed57020a84d3b';

const IMPL_SLOT = '0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc';
const ADMIN_SLOT = '0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103';
const MAX_FEE_WEI = 100n;

const ADMIN_ABI = [
  'function upgrade(address proxy, address implementation)',
  'function owner() view returns (address)',
];

async function main() {
  const send = process.argv.includes('--send');
  const restore = process.argv.includes('--restore');
  const target = restore ? STAKING_MANAGER : FORWARDER;

  const provider = new ethers.JsonRpcProvider(RPC, undefined, { staticNetwork: true });
  const net = await provider.getNetwork();
  if (Number(net.chainId) !== 88008) throw new Error(`expected chain 88008, got ${net.chainId}`);

  const raw = fs.readFileSync(KEY_FILE, 'utf8').trim().replace(/^0x/, '');
  const wallet = new ethers.Wallet(raw, provider);
  if (wallet.address.toLowerCase() !== OWNER.toLowerCase()) {
    throw new Error(`key file derives ${wallet.address}, expected owner ${OWNER}`);
  }

  const implSlot = await provider.getStorage(PROXY, IMPL_SLOT);
  const currentImpl = ethers.getAddress('0x' + implSlot.slice(-40));
  const adminSlot = await provider.getStorage(PROXY, ADMIN_SLOT);
  const adminFromSlot = ethers.getAddress('0x' + adminSlot.slice(-40));

  const admin = new ethers.Contract(PROXY_ADMIN, ADMIN_ABI, wallet);
  const adminOwner = await admin.owner();
  const code = await provider.getCode(currentImpl);
  const targetCode = await provider.getCode(target);

  const fee = await provider.getFeeData();
  const quoted = fee.maxFeePerGas ?? fee.gasPrice ?? 0n;
  const gasPrice = quoted > MAX_FEE_WEI ? MAX_FEE_WEI : quoted < 10n ? 10n : quoted;

  console.log(`# chain            ${net.chainId}  ${RPC}`);
  console.log(`# signer           ${wallet.address}`);
  console.log(`# ProxyAdmin       ${PROXY_ADMIN}`);
  console.log(`# admin owner()    ${adminOwner}${adminOwner.toLowerCase() === OWNER.toLowerCase() ? '  OK' : '  NOT THE SIGNER'}`);
  console.log(`# admin (slot)     ${adminFromSlot}${adminFromSlot.toLowerCase() === PROXY_ADMIN.toLowerCase() ? '  OK' : '  MISMATCH'}`);
  console.log(`# proxy            ${PROXY}`);
  console.log(`# current impl     ${currentImpl}  (${(code.length - 2) / 2} bytes)`);
  console.log(`# target impl      ${target}  (${(targetCode.length - 2) / 2} bytes)`);
  console.log(`# operation       ${restore ? 'RESTORE the staking manager' : 'INSTALL the forwarder'}`);
  console.log(`# gas price        ${gasPrice} wei`);
  console.log(`# mode            ${send ? 'SEND' : 'DRY RUN (eth_call only)'}\n`);

  if (adminOwner.toLowerCase() !== OWNER.toLowerCase()) {
    throw new Error('ProxyAdmin owner is not the signer; nothing can be done with this key');
  }
  if (targetCode === '0x') throw new Error(`no code at target implementation ${target}`);
  if (currentImpl.toLowerCase() === target.toLowerCase()) {
    console.log(`Already pointed at ${target}; nothing to do.`);
    return;
  }

  const data = admin.interface.encodeFunctionData('upgrade', [PROXY, target]);

  // Simulate from the owner (must succeed) and from a stranger (must be refused).
  try {
    await provider.call({ from: OWNER, to: PROXY_ADMIN, data });
    console.log('simulate owner     SUCCESS');
  } catch (error) {
    throw new Error(`simulation from the owner failed: ${error.shortMessage || error.message}`);
  }
  try {
    await provider.call({ from: '0x000000000000000000000000000000000000dEaD', to: PROXY_ADMIN, data });
    console.log('simulate stranger  SUCCEEDED (unexpected - stop and investigate)');
  } catch (error) {
    console.log(`simulate stranger  refused: ${(error.shortMessage || error.message).slice(0, 90)}`);
  }

  const gas = await provider.estimateGas({ from: OWNER, to: PROXY_ADMIN, data });

  if (!send) {
    console.log(`\ngas estimate       ${gas}`);
    console.log(`restore afterwards ${currentImpl}  (this script --restore)`);
    console.log('\nDry run only. Re-run with --send to broadcast.');
    return;
  }

  console.log(`\nbroadcasting upgrade(${PROXY}, ${target})...`);
  const tx = await wallet.sendTransaction({
    to: PROXY_ADMIN,
    data,
    gasLimit: gas + 20000n,
    maxFeePerGas: gasPrice,
    maxPriorityFeePerGas: 0n,
  });
  console.log(`sent   ${tx.hash}`);
  const receipt = await tx.wait();
  if (!receipt || receipt.status !== 1) throw new Error(`upgrade failed: status ${receipt && receipt.status}`);
  console.log(`mined  block ${receipt.blockNumber}  gasUsed ${receipt.gasUsed}`);

  const after = ethers.getAddress('0x' + (await provider.getStorage(PROXY, IMPL_SLOT)).slice(-40));
  const afterCode = await provider.getCode(after);
  console.log(`\nimplementation()   ${after}`);
  console.log(`code bytes         ${(afterCode.length - 2) / 2}`);

  if (after.toLowerCase() !== target.toLowerCase()) {
    console.log(`\nSTOP: implementation is ${after}, expected ${target}.`);
    if (!restore) console.log(`Restore with: node ${path.relative(process.cwd(), __filename)} --restore --send`);
    process.exit(1);
  }
  console.log(restore ? '\nrestored to the staking manager' : '\nforwarder installed');
}

main().catch((error) => {
  console.error(`ERROR: ${error.message}`);
  process.exit(1);
});
