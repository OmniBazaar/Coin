#!/usr/bin/env node
/**
 * Recover the justification bytes for a `registered = false` acknowledgement from
 * the L1 registration transaction that created the validator.
 *
 *   node scripts/extract-registration-justification.cjs --tx 0x… --node-id 0x… [--out /tmp/inner.hex]
 *
 * The L1's registration receipt contains a Warp precompile log whose payload is
 * the RegisterL1ValidatorMessage envelope. The P-Chain's verifier
 * (vms/platformvm/network/warp.go) wants the INNER message, protobuf-wrapped as
 * field 2: `0x12` + varint(len) + message. Passing the envelope instead gives
 * "packer has insufficient length".
 *
 * The node ID is checked against the message so a wrong transaction cannot be
 * used silently.
 */
const fs = require('fs');
const { ethers } = require('ethers');

const RPC = process.env.RPC_URL || 'https://rpc.omnicoin.net';
const WARP = '0x0200000000000000000000000000000000000005';

function argValue(name, fallback) {
  const i = process.argv.indexOf(name);
  return i === -1 ? fallback : process.argv[i + 1];
}

function varint(n) {
  const out = [];
  let v = n;
  while (v >= 0x80) { out.push((v & 0x7f) | 0x80); v >>= 7; }
  out.push(v);
  return Buffer.from(out);
}

async function main() {
  const txHash = argValue('--tx', '');
  const expectNodeId = (argValue('--node-id', '') || '').replace(/^0x/, '').toLowerCase();
  if (!txHash) throw new Error('give --tx <registration transaction hash>');

  const provider = new ethers.JsonRpcProvider(RPC, 88008, { staticNetwork: true });
  const receipt = await provider.getTransactionReceipt(txHash);
  if (!receipt) throw new Error('no receipt for that transaction');
  if (receipt.status !== 1) throw new Error(`that transaction failed (status ${receipt.status})`);

  const log = receipt.logs.find((l) => l.address.toLowerCase() === WARP);
  if (!log) throw new Error('no Warp log in that receipt — not a registration transaction?');

  const message = ethers.AbiCoder.defaultAbiCoder().decode(['bytes'], log.data)[0];
  const envelope = Buffer.from(message.slice(2), 'hex');

  // envelope: codec(2) typeId(4) sourceChainID(32) payloadLen(4) AddressedCall
  const payloadLen = envelope.readUInt32BE(38);
  const addressedCall = envelope.subarray(42, 42 + payloadLen);
  const addrLen = addressedCall.readUInt32BE(6);
  const acPayloadLen = addressedCall.readUInt32BE(10);
  const inner = addressedCall.subarray(14 + addrLen, 14 + addrLen + acPayloadLen);

  // inner: codec(2) typeId(4) [32 bytes] nodeIDLen(4) nodeID(20) blsKey(48) …
  const nodeIdLen = inner.readUInt32BE(38);
  const nodeId = inner.subarray(42, 42 + nodeIdLen).toString('hex');

  console.log(`# envelope bytes   ${envelope.length}`);
  console.log(`# source chain     ${envelope.subarray(6, 38).toString('hex')}`);
  console.log(`# inner bytes      ${inner.length}`);
  console.log(`# inner nodeID    0x${nodeId}`);
  if (expectNodeId) {
    console.log(`# nodeID matches   ${nodeId === expectNodeId ? 'yes' : 'NO — wrong transaction'}`);
    if (nodeId !== expectNodeId) throw new Error('the node ID does not match --node-id; refusing');
  }

  const justification = Buffer.concat([Buffer.from([0x12]), varint(inner.length), inner]);
  const outPath = argValue('--out', '');
  if (outPath) fs.writeFileSync(outPath, justification.toString('hex'));
  console.log(`# justification    ${justification.length} bytes${outPath ? ` -> ${outPath}` : ''}`);
  console.log(`\n${justification.toString('hex')}`);
}

main().catch((e) => { console.error('ERROR:', e.message ?? e); process.exit(1); });
