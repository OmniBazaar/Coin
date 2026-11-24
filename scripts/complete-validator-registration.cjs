#!/usr/bin/env node
/**
 * Complete a validator registration on the L1 with the P-Chain's acknowledgement.
 * Step 3g, second half.
 *
 *   node scripts/complete-validator-registration.cjs --message <file|hex>
 *   node scripts/complete-validator-registration.cjs --message <file|hex> --send --key-file <any funded key>
 *
 * On this deployment the specialization overrides completeValidatorRegistration
 * without onlyOwner, so any funded account may call it (measured: an eth_call from
 * a burn address succeeds). The message is P-Chain-sourced, so the signing subnet
 * for the aggregator must be forced to the L1.
 *
 * The predicate framing is subnet-evm's: 32-byte words with a 0xff delimiter after
 * the last message byte, then zero padding.
 */
const fs = require('fs');
const os = require('os');
const path = require('path');
const { ethers } = require('ethers');

const RPC = process.env.RPC_URL || 'https://rpc.omnicoin.net';
const PROXY = '0x100c0De1C0FFEe00000000000000000000000000';
const STAKING_MANAGER = '0x9338b9ef1291b0266d28e520797ed57020a84d3b';
const WARP = '0x0200000000000000000000000000000000000005';
const IMPL_SLOT = '0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc';
const SELECTOR = '0xa3a65e48'; // completeValidatorRegistration(uint32)
const MAX_FEE_WEI = 100n;
const FALLBACK_GAS = 400000n;

function argValue(name, fallback) {
  const i = process.argv.indexOf(name);
  return i === -1 ? fallback : process.argv[i + 1];
}

function toWords(hex) {
  const body = hex.replace(/^0x/, '');
  const full = Math.floor(body.length / 2 / 32);
  const words = [];
  for (let i = 0; i < full; i++) words.push('0x' + body.slice(i * 64, i * 64 + 64));
  const remainder = body.slice(full * 64);
  const remainderBytes = remainder.length / 2;
  if (remainderBytes > 31) throw new Error('internal: remainder does not fit one word');
  words.push('0x' + remainder + 'ff' + '0'.repeat((31 - remainderBytes) * 2));
  return words;
}

async function main() {
  const send = process.argv.includes('--send');
  const keyFileArg = argValue('--key-file', process.env.SIGNER_KEY_FILE);
  const index = Number(argValue('--index', '0'));
  const messageArg = argValue('--message', '');
  if (!messageArg) throw new Error('give --message <hex, or a file containing it>');

  const hex = /^0x[0-9a-fA-F]+$/.test(messageArg.trim())
    ? messageArg.trim().replace(/^0x/, '')
    : fs.readFileSync(messageArg.replace(/^~/, os.homedir()), 'utf8').trim().replace(/^0x/, '');
  const storageKeys = toWords(hex);
  const data = SELECTOR + index.toString(16).padStart(64, '0');

  const provider = new ethers.JsonRpcProvider(RPC, undefined, { staticNetwork: true });
  const net = await provider.getNetwork();
  if (Number(net.chainId) !== 88008) throw new Error(`expected chain 88008, got ${net.chainId}`);
  const impl = ethers.getAddress('0x' + (await provider.getStorage(PROXY, IMPL_SLOT)).slice(-40));

  const fee = await provider.getFeeData();
  const quoted = fee.maxFeePerGas ?? fee.gasPrice ?? 0n;
  const gasPrice = quoted > MAX_FEE_WEI ? MAX_FEE_WEI : quoted < 10n ? 10n : quoted;

  console.log(`# message     ${hex.length / 2} bytes -> ${storageKeys.length} predicate words`);
  console.log(`# proxy impl  ${impl}  ${impl.toLowerCase() === STAKING_MANAGER.toLowerCase() ? '(staking manager - OK)' : '(NOT the staking manager)'}`);
  console.log(`# data        ${data}`);
  console.log(`# mode        ${send ? 'SEND' : 'DRY RUN'}\n`);

  if (impl.toLowerCase() !== STAKING_MANAGER.toLowerCase()) {
    throw new Error('the proxy is not on the staking manager; refusing');
  }

  let signer = null;
  if (send) {
    if (!keyFileArg) throw new Error('give --key-file <funded key file> for --send');
    const raw = fs.readFileSync(keyFileArg.replace(/^~/, os.homedir()), 'utf8').trim().replace(/^0x/, '');
    signer = new ethers.Wallet(raw, provider);
  }

  const from = signer ? signer.address : '0x000000000000000000000000000000000000dEaD';
  const tx = { from, to: PROXY, data, accessList: [{ address: WARP, storageKeys }] };
  try {
    const res = await provider.call(tx);
    console.log(`simulate     SUCCESS, returns ${res}`);
  } catch (error) {
    console.log(`simulate     REVERTED: ${(error.shortMessage || error.message).slice(0, 120)}`);
    throw new Error('the completion would fail; not sending');
  }

  let gas;
  try {
    gas = await provider.estimateGas(tx);
    console.log(`gas estimate ${gas}`);
  } catch (error) {
    gas = FALLBACK_GAS;
    console.log(`gas estimate unavailable, using ${gas}`);
  }

  if (!send) {
    console.log('\nDry run. Re-run with --send --key-file <funded key file>.');
    return;
  }

  const sent = await signer.sendTransaction({
    to: PROXY,
    data,
    accessList: [{ address: WARP, storageKeys }],
    gasLimit: gas + 100000n,
    maxFeePerGas: gasPrice,
    maxPriorityFeePerGas: 0n,
  });
  console.log(`\nsent   ${sent.hash}`);
  const receipt = await sent.wait();
  if (!receipt || receipt.status !== 1) throw new Error(`completion failed: status ${receipt && receipt.status}`);
  console.log(`mined  block ${receipt.blockNumber}  gasUsed ${receipt.gasUsed}`);
  const done = receipt.logs.find((l) => l.topics[0] === ethers.id('CompletedValidatorRegistration(bytes32,uint64)'));
  console.log(done ? `CompletedValidatorRegistration ${done.topics[1]}` : 'WARNING: no CompletedValidatorRegistration event');
}

main().catch((error) => {
  console.error(`ERROR: ${error.message}`);
  process.exit(1);
});
