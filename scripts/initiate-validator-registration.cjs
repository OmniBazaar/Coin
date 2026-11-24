#!/usr/bin/env node
/**
 * Re-register v5 after its owner rotation. Step 3f of the runbook.
 *
 *   node scripts/initiate-validator-registration.cjs                    # dry run
 *   node scripts/initiate-validator-registration.cjs --send --key-file deployer.pk
 *
 * MUST BE SIGNED BY THE SUCCESSOR: the call is payable and the 20 XOM stake comes
 * from the caller's balance, which only the successor address has.
 *
 * Everything except the intended changes is carried over from v5's own March
 * registration (block 32), decoded rather than re-invented: same nodeID, same BLS
 * public key (so the node keeps its identity and needs no restart), same
 * delegationFeeBips of 200, same 20 XOM stake.
 *
 * Changed deliberately:
 *   remainingBalanceOwner / disableOwner  0x7DA1c44e… -> the successor's P address
 *   minStakeDuration                      31536000     -> 100 seconds
 *   rewardRecipient                       0xaDAD7751…  -> the successor's EVM address
 */
const fs = require('fs');
const os = require('os');
const path = require('path');
const { ethers } = require('ethers');
const { utils } = require('@avalabs/avalanchejs');

const RPC = process.env.RPC_URL || 'https://rpc.omnicoin.net';
const NODE_INFO = process.env.V5_NODE_INFO || 'http://65.108.205.101:9650/ext/info';
const PROXY = '0x100c0De1C0FFEe00000000000000000000000000';
const FORWARDER = '0x99080Bb402949ef3D69f6773e2Cc252655Abd43f';
const STAKING_MANAGER = '0x9338b9ef1291b0266d28e520797ed57020a84d3b';
const OPERATOR = process.env.OPERATOR || '0x68d002Bb315E8310c1344EeA707f9C36DdC33e1e';
const SUCCESSOR_P = process.env.SUCCESSOR_P || 'P-avax1lxdavlr45u5zph972cn66euvay90xz3smnwyer';
const IMPL_SLOT = '0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc';
const MAX_FEE_WEI = 100n;

// From v5's March registration, block 32.
const NODE_ID = '0xdbadfd8744a07374c6805f529ba2986099657186';
const BLS_PUBLIC_KEY =
  '0x84470018ba04e7673def87191879d5e45c2805cab130000b73c8608a1e7e4505d862b3d4da2c869f14ed9de6b0c4d699';
const DELEGATION_FEE_BIPS = 200;
const MIN_STAKE_DURATION = 100; // the contract minimum; the 365-day value is what blocked us
const STAKE = ethers.parseEther('20'); // 20 XOM -> weight 20

const ABI = [
  'function initiateValidatorRegistration(bytes nodeID, bytes blsPublicKey, (uint32 threshold, address[] addresses) remainingBalanceOwner, (uint32 threshold, address[] addresses) disableOwner, uint16 delegationFeeBips, uint64 minStakeDuration, address rewardRecipient) payable',
];

function argValue(name, fallback) {
  const i = process.argv.indexOf(name);
  return i === -1 ? fallback : process.argv[i + 1];
}

async function main() {
  const send = process.argv.includes('--send');
  const keyFileArg = argValue('--key-file', process.env.OPERATOR_KEY_FILE);

  // The node must still hold the key we are registering, or the identity changes.
  const info = await fetch(NODE_INFO, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'info.getNodeID', params: {} }),
  }).then((r) => r.json());
  const nodeID = info.result.nodeID;
  const liveKey = info.result.nodePOP.publicKey;
  const keyMatches = liveKey.toLowerCase() === BLS_PUBLIC_KEY.toLowerCase();

  const ownerBytes = utils.bech32ToBytes(SUCCESSOR_P);
  const iface = new ethers.Interface(ABI);
  const data = iface.encodeFunctionData('initiateValidatorRegistration', [
    NODE_ID,
    BLS_PUBLIC_KEY,
    [1, ['0x' + Buffer.from(ownerBytes).toString('hex')]],
    [1, ['0x' + Buffer.from(ownerBytes).toString('hex')]],
    DELEGATION_FEE_BIPS,
    MIN_STAKE_DURATION,
    OPERATOR,
  ]);

  const provider = new ethers.JsonRpcProvider(RPC, undefined, { staticNetwork: true });
  const net = await provider.getNetwork();
  if (Number(net.chainId) !== 88008) throw new Error(`expected chain 88008, got ${net.chainId}`);
  const impl = ethers.getAddress('0x' + (await provider.getStorage(PROXY, IMPL_SLOT)).slice(-40));

  const fee = await provider.getFeeData();
  const quoted = fee.maxFeePerGas ?? fee.gasPrice ?? 0n;
  const gasPrice = quoted > MAX_FEE_WEI ? MAX_FEE_WEI : quoted < 10n ? 10n : quoted;

  console.log(`# node           ${nodeID}`);
  console.log(`# BLS key live   ${liveKey}`);
  console.log(`# key matches    ${keyMatches ? 'yes - identity preserved' : 'NO - the node key changed, STOP'}`);
  console.log(`# proxy impl     ${impl}  ${impl.toLowerCase() === STAKING_MANAGER.toLowerCase() ? '(staking manager - OK)' : '(NOT the staking manager - STOP)'}`);
  console.log(`# owners         ${SUCCESSOR_P}`);
  console.log(`#              0x${Buffer.from(ownerBytes).toString('hex')}`);
  console.log(`# stake          ${ethers.formatEther(STAKE)} XOM  -> weight 20`);
  console.log(`# minStakeDuration ${MIN_STAKE_DURATION} s   delegationFeeBips ${DELEGATION_FEE_BIPS}`);
  console.log(`# rewardRecipient ${OPERATOR}`);
  console.log(`# from           ${OPERATOR}`);
  console.log(`# to             ${PROXY}`);
  console.log(`# maxFeePerGas   ${gasPrice} wei`);
  console.log(`# mode           ${send ? 'SEND' : 'DRY RUN'}\n`);

  if (!keyMatches) throw new Error('the node no longer holds the BLS key we would register; refusing');
  if (impl.toLowerCase() !== STAKING_MANAGER.toLowerCase()) {
    throw new Error('the proxy is not on the staking manager; restore it before registering');
  }

  const tx = { from: OPERATOR, to: PROXY, data, value: STAKE };
  try {
    await provider.call(tx);
    console.log('simulate       SUCCESS - the nodeID is free and the stake is accepted');
  } catch (error) {
    console.log(`simulate       REVERTED: ${(error.shortMessage || error.message).slice(0, 140)}`);
    throw new Error('registration would fail; not sending');
  }
  const gas = await provider.estimateGas(tx);
  console.log(`gas estimate   ${gas}`);

  if (!send) {
    console.log('\nDry run only. Sign it with the successor key:');
    console.log(`  node ${path.basename(__filename)} --send --key-file <successor key file>\n`);
    return;
  }

  if (!keyFileArg) throw new Error('give --key-file <successor key file> for --send');
  const raw = fs.readFileSync(keyFileArg.replace(/^~/, os.homedir()), 'utf8').trim().replace(/^0x/, '');
  const wallet = new ethers.Wallet(raw, provider);
  if (wallet.address.toLowerCase() !== OPERATOR.toLowerCase()) {
    throw new Error(`that key is ${wallet.address}; the successor is ${OPERATOR}`);
  }

  const sent = await wallet.sendTransaction({
    to: PROXY,
    data,
    value: STAKE,
    gasLimit: gas + 100000n,
    maxFeePerGas: gasPrice,
    maxPriorityFeePerGas: 0n,
  });
  console.log(`\nsent   ${sent.hash}`);
  const receipt = await sent.wait();
  if (!receipt || receipt.status !== 1) throw new Error(`registration failed: status ${receipt && receipt.status}`);
  console.log(`mined  block ${receipt.blockNumber}  gasUsed ${receipt.gasUsed}`);

  const WARP = '0x0200000000000000000000000000000000000005';
  const warpLog = receipt.logs.filter((l) => l.address.toLowerCase() === WARP);
  if (warpLog.length === 0) throw new Error('no Warp log in the receipt - nothing to aggregate');
  const message = ethers.AbiCoder.defaultAbiCoder().decode(['bytes'], warpLog[0].data)[0];
  const hex = message.slice(2);
  fs.writeFileSync('/tmp/registration_message.hex', hex);
  console.log(`\nWarp message   ${hex.length / 2} bytes (saved to /tmp/registration_message.hex)`);
  console.log(hex);
  console.log('\nSend that hex back: it is the unsigned message the validators sign next.');
}

main().catch((error) => {
  console.error(`ERROR: ${error.message}`);
  process.exit(1);
});
