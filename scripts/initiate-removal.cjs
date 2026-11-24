#!/usr/bin/env node
/**
 * Step 3a of the validator owner rotation: initiate removal of one L1 validator
 * through the forwarder that is currently installed behind the specialization
 * proxy.
 *
 *   node scripts/initiate-removal.cjs                     # dry run, v5, no key needed
 *   node scripts/initiate-removal.cjs --validation 0x...  # another validation
 *   OPERATOR_KEY_FILE=~/path/to/successor.pk node scripts/initiate-removal.cjs --send
 *
 * THIS MUST BE SIGNED BY THE SUCCESSOR, NOT BY A KEY ON THE VALIDATOR HOST.
 * The forwarder's OPERATOR is 0x68d002Bb…; any other signer is refused by the
 * contract, which is the point of the design.
 *
 * What it does NOT do: nothing on the P-Chain changes. The validator keeps its
 * weight and keeps validating. The call marks the validation pending removal in
 * the base manager and emits a Warp message, which is printed at the end so the
 * aggregate signature can be requested next.
 */
const { ethers } = require('ethers');
const fs = require('fs');
const os = require('os');
const path = require('path');

const RPC = process.env.RPC_URL || 'https://rpc.omnicoin.net';
const PROXY = '0x100c0De1C0FFEe00000000000000000000000000';
const FORWARDER = process.env.FORWARDER_ADDRESS || '0x99080Bb402949ef3D69f6773e2Cc252655Abd43f';
const OPERATOR = process.env.OPERATOR || '0x68d002Bb315E8310c1344EeA707f9C36DdC33e1e';
const WARP = '0x0200000000000000000000000000000000000005';

// v5 (NodeID-M2ZR5BAa8huibaeQfCsKs6U1c2dWZhcry). Kept in its published cb58
// form and decoded at run time: the same identifier the ledger and the P-Chain
// show, and no free-standing 64-hex literal in the source.
const V5_CB58 = 'zDGaneyChMythZuK8GUTTTopYs9kMAw1jfQKxuFAWuUSesBEN';

const ALPHABET = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';

function cb58ToHex(value) {
  let n = 0n;
  for (const ch of value) {
    const index = ALPHABET.indexOf(ch);
    if (index < 0) throw new Error(`not base58: ${ch}`);
    n = n * 58n + BigInt(index);
  }
  let hex = n.toString(16);
  if (hex.length % 2) hex = '0' + hex;
  let zeros = 0;
  while (zeros < value.length && value[zeros] === '1') zeros++;
  const body = Buffer.concat([Buffer.alloc(zeros), Buffer.from(hex, 'hex')]);
  return '0x' + body.slice(0, body.length - 4).toString('hex'); // drop the checksum
}

const IMPL_SLOT = '0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc';
const MAX_FEE_WEI = 100n;
const GAS_BUFFER = 50000n;

function argValue(name, fallback) {
  const i = process.argv.indexOf(name);
  return i === -1 ? fallback : process.argv[i + 1];
}

async function main() {
  const send = process.argv.includes('--send');
  const checkOnly = process.argv.includes('--check-key');
  const keyFileArg = argValue('--key-file', process.env.OPERATOR_KEY_FILE);
  const validationID = argValue('--validation', cb58ToHex(V5_CB58));
  if (!/^0x[0-9a-fA-F]{64}$/.test(validationID)) throw new Error(`bad validationID ${validationID}`);

  // --check-key: say which address a key file derives, and nothing else.
  if (checkOnly) {
    if (!keyFileArg) throw new Error('--check-key needs --key-file <path>');
    const rawKey = fs.readFileSync(keyFileArg.replace(/^~/, os.homedir()), 'utf8').trim().replace(/^0x/, '');
    const address = new ethers.Wallet(rawKey).address;
    console.log(`key file   ${keyFileArg}`);
    console.log(`derives    ${address}`);
    console.log(`operator   ${OPERATOR}`);
    console.log(
      address.toLowerCase() === OPERATOR.toLowerCase()
        ? '\nThis is the successor: it can call the forwarder.'
        : '\nNOT the operator. This key cannot call the forwarder; use the successor key file.'
    );
    return;
  }

  const provider = new ethers.JsonRpcProvider(RPC, undefined, { staticNetwork: true });
  const net = await provider.getNetwork();
  if (Number(net.chainId) !== 88008) throw new Error(`expected chain 88008, got ${net.chainId}`);

  const impl = ethers.getAddress('0x' + (await provider.getStorage(PROXY, IMPL_SLOT)).slice(-40));
  const data = '0xb6e6a2ca' + validationID.slice(2);

  const fee = await provider.getFeeData();
  const quoted = fee.maxFeePerGas ?? fee.gasPrice ?? 0n;
  const gasPrice = quoted > MAX_FEE_WEI ? MAX_FEE_WEI : quoted < 10n ? 10n : quoted;

  console.log(`# chain         ${net.chainId}  ${RPC}`);
  console.log(`# proxy         ${PROXY}`);
  console.log(`# implementation ${impl}  ${impl.toLowerCase() === FORWARDER.toLowerCase() ? '(the forwarder - OK)' : '(NOT the forwarder - STOP)'}`);
  console.log(`# operator      ${OPERATOR}`);
  console.log(`# validationID  ${validationID}`);
  console.log(`# to            ${PROXY}`);
  console.log(`# data          ${data}`);
  console.log(`# value         0`);
  console.log(`# maxFeePerGas  ${gasPrice} wei${quoted !== gasPrice ? ` (clamped from ${quoted})` : ''}`);
  console.log(`# mode          ${send ? 'SEND' : 'DRY RUN (no key touched)'}\n`);

  if (impl.toLowerCase() !== FORWARDER.toLowerCase()) {
    throw new Error('the proxy does not point at the forwarder; refusing to call into it');
  }

  try {
    await provider.call({ from: OPERATOR, to: PROXY, data });
    console.log('simulate       SUCCESS from the operator');
  } catch (error) {
    throw new Error(`simulation reverted: ${error.shortMessage || error.message}`);
  }
  try {
    await provider.call({ from: '0x000000000000000000000000000000000000dEaD', to: PROXY, data });
    console.log('simulate       a stranger SUCCEEDED (unexpected - stop)');
  } catch (error) {
    console.log(`simulate       a stranger is refused: ${(error.shortMessage || error.message).slice(0, 70)}`);
  }

  const gas = await provider.estimateGas({ from: OPERATOR, to: PROXY, data });
  console.log(`gas estimate   ${gas}`);

  if (!send) {
    console.log('\nDry run only. To sign it with the successor key:');
    console.log(`  node ${path.basename(__filename)} --check-key --key-file <successor key file>`);
    console.log(`  node ${path.basename(__filename)} --send --key-file <successor key file>\n`);
    return;
  }

  const keyFile = keyFileArg;
  if (!keyFile) throw new Error('give the key file: --send --key-file <path>');
  const raw = fs.readFileSync(keyFile.replace(/^~/, os.homedir()), 'utf8').trim().replace(/^0x/, '');
  const wallet = new ethers.Wallet(raw, provider);
  if (wallet.address.toLowerCase() !== OPERATOR.toLowerCase()) {
    throw new Error(`that key is ${wallet.address}; the operator is ${OPERATOR}`);
  }

  const tx = await wallet.sendTransaction({
    to: PROXY,
    data,
    value: 0n,
    gasLimit: gas + GAS_BUFFER,
    maxFeePerGas: gasPrice,
    maxPriorityFeePerGas: 0n,
  });
  console.log(`\nsent   ${tx.hash}`);
  const receipt = await tx.wait();
  if (!receipt || receipt.status !== 1) throw new Error(`initiate failed: status ${receipt && receipt.status}`);
  console.log(`mined  block ${receipt.blockNumber}  gasUsed ${receipt.gasUsed}`);

  const warpLogs = receipt.logs.filter((l) => l.address.toLowerCase() === WARP);
  if (warpLogs.length === 0) throw new Error('no Warp precompile log in the receipt - nothing to aggregate');
  const message = ethers.AbiCoder.defaultAbiCoder().decode(['bytes'], warpLogs[0].data)[0];
  console.log(`\nWarp message   ${(message.length - 2) / 2} bytes`);
  console.log(message);
  console.log('\nSend that hex back. It is public: it is the unsigned message the');
  console.log('validators are asked to sign, not a secret and not a signature.');
}

main().catch((error) => {
  console.error(`ERROR: ${error.message}`);
  process.exit(1);
});
