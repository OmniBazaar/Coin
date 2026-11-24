#!/usr/bin/env node
/**
 * Step 3d: complete the removal on the L1 now that the P-Chain has accepted the
 * weight-0 transaction. Needs the aggregated signature from the P-Chain's
 * confirmation as a transaction predicate.
 *
 *   node scripts/complete-validator-removal.cjs --message /tmp/signed.hex           # dry run
 *   node scripts/complete-validator-removal.cjs --message /tmp/signed.hex --send --key-file deployer.pk
 *
 * Signed by the successor, because the forwarder's OPERATOR is the successor.
 *
 * The predicate is one access-list entry for the Warp precompile whose
 * storageKeys are the signed message split into 32-byte words, zero-padded. That
 * shape was read off this chain's own historical completion transactions, where
 * `completeValidatorRegistration` carried 7 keys for a 224-byte message.
 */
const fs = require('fs');
const os = require('os');
const path = require('path');
const { ethers } = require('ethers');

const RPC = process.env.RPC_URL || 'https://rpc.omnicoin.net';
const PROXY = '0x100c0De1C0FFEe00000000000000000000000000';
const FORWARDER = '0x99080Bb402949ef3D69f6773e2Cc252655Abd43f';
const OPERATOR = process.env.OPERATOR || '0x68d002Bb315E8310c1344EeA707f9C36DdC33e1e';
const WARP = '0x0200000000000000000000000000000000000005';
const IMPL_SLOT = '0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc';
const MAX_FEE_WEI = 100n;
const GAS_BUFFER = 100000n;
const FALLBACK_GAS = 400000n;

// completeValidatorRemoval(uint32) — the same selector the base manager exposes.
const SELECTOR = '0x9681d940';

function argValue(name, fallback) {
  const i = process.argv.indexOf(name);
  return i === -1 ? fallback : process.argv[i + 1];
}

// subnet-evm frames a predicate as 32-byte words, followed by a 0xff delimiter
// byte immediately after the last message byte, then zero padding. Without that
// byte the node rejects the transaction with "cannot unpack predicate bytes:
// wrong delimiter" (graft/evm/predicate/predicate.go).
function toWords(hex) {
  const body = hex.replace(/^0x/, '');
  const bytes = body.length / 2;
  const full = Math.floor(bytes / 32);
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
  const messageArg = argValue('--message', '') || '';
  const keyFileArg = argValue('--key-file', process.env.OPERATOR_KEY_FILE);
  const index = Number(argValue('--index', '0'));
  const ignoreSim = process.argv.includes('--ignore-simulation-failure');
  if (!messageArg) throw new Error('give --message <hex string, or a file containing it>');
  if (!Number.isInteger(index) || index < 0) throw new Error('--index must be a small integer');

  // Accept the signed message inline as hex, or as a path to a file holding it.
  const hex = /^0x[0-9a-fA-F]+$/.test(messageArg.trim())
    ? messageArg.trim().replace(/^0x/, '')
    : fs.readFileSync(messageArg.replace(/^~/, os.homedir()), 'utf8').trim().replace(/^0x/, '');
  if (!/^[0-9a-fA-F]+$/.test(hex)) throw new Error('the message file is not clean hex');
  const storageKeys = toWords(hex);
  const data = SELECTOR + index.toString(16).padStart(64, '0');

  const provider = new ethers.JsonRpcProvider(RPC, undefined, { staticNetwork: true });
  const net = await provider.getNetwork();
  if (Number(net.chainId) !== 88008) throw new Error(`expected chain 88008, got ${net.chainId}`);

  const impl = ethers.getAddress('0x' + (await provider.getStorage(PROXY, IMPL_SLOT)).slice(-40));
  const fee = await provider.getFeeData();
  const quoted = fee.maxFeePerGas ?? fee.gasPrice ?? 0n;
  const gasPrice = quoted > MAX_FEE_WEI ? MAX_FEE_WEI : quoted < 10n ? 10n : quoted;

  console.log(`# message        ${hex.length / 2} bytes -> ${storageKeys.length} predicate words, 0xff delimiter + zero padding`);
  console.log(`# predicate      ${WARP}`);
  console.log(`# to             ${PROXY}`);
  console.log(`# implementation ${impl}  ${impl.toLowerCase() === FORWARDER.toLowerCase() ? '(forwarder - OK)' : '(NOT the forwarder - STOP)'}`);
  console.log(`# data           ${data}  (completeValidatorRemoval(${index}))`);
  console.log(`# operator       ${OPERATOR}`);
  console.log(`# maxFeePerGas   ${gasPrice} wei`);
  console.log(`# mode           ${send ? 'SEND' : 'DRY RUN'}\n`);

  if (impl.toLowerCase() !== FORWARDER.toLowerCase()) {
    throw new Error('the proxy does not point at the forwarder; refusing');
  }

  const tx = { from: OPERATOR, to: PROXY, data, accessList: [{ address: WARP, storageKeys }] };

  try {
    await provider.call(tx);
    console.log('simulate       SUCCESS - the predicate is accepted by the Warp precompile');
  } catch (error) {
    console.log(`simulate       REVERTED: ${(error.shortMessage || error.message).slice(0, 140)}`);
    if (!ignoreSim) {
      throw new Error(
        'the completion would fail; not sending. Note: eth_call cannot evaluate Warp ' +
          'predicates on this chain, so this check is inconclusive for this call; pass ' +
          '--ignore-simulation-failure to send anyway.'
      );
    }
    console.log('               continuing because --ignore-simulation-failure was given:');
    console.log('               eth_call cannot verify Warp predicates on this chain, so this');
    console.log('               result says nothing about the transaction.');
  }

  // estimateGas executes the call, so it fails for the same reason the
  // simulation does: eth_call cannot evaluate Warp predicates here. Fall back to
  // a fixed limit that comfortably covers the call.
  let gas;
  try {
    gas = await provider.estimateGas(tx);
    console.log(`gas estimate   ${gas}`);
  } catch (error) {
    if (!ignoreSim) throw new Error(`could not estimate gas: ${error.shortMessage || error.message}`);
    gas = FALLBACK_GAS;
    console.log(`gas estimate   unavailable (predicate not evaluable), using ${gas}`);
  }

  if (!send) {
    console.log('\nDry run only. Sign it with the successor key:');
    console.log(`  node ${path.basename(__filename)} --message <same value> --send --key-file <successor key file>\n`);
    return;
  }

  if (!keyFileArg) throw new Error('give --key-file <successor key file> for --send');
  const raw = fs.readFileSync(keyFileArg.replace(/^~/, os.homedir()), 'utf8').trim().replace(/^0x/, '');
  const wallet = new ethers.Wallet(raw, provider);
  if (wallet.address.toLowerCase() !== OPERATOR.toLowerCase()) {
    throw new Error(`that key is ${wallet.address}; the operator is ${OPERATOR}`);
  }

  const sent = await wallet.sendTransaction({
    to: PROXY,
    data,
    accessList: [{ address: WARP, storageKeys }],
    gasLimit: gas + GAS_BUFFER,
    maxFeePerGas: gasPrice,
    maxPriorityFeePerGas: 0n,
  });
  console.log(`\nsent   ${sent.hash}`);
  const receipt = await sent.wait();
  if (!receipt || receipt.status !== 1) throw new Error(`completion failed: status ${receipt && receipt.status}`);
  console.log(`mined  block ${receipt.blockNumber}  gasUsed ${receipt.gasUsed}`);
  console.log('\nremoval complete. The proxy is still on the forwarder; restore next.');
}

main().catch((error) => {
  console.error(`ERROR: ${error.message}`);
  process.exit(1);
});
