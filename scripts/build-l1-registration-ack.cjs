#!/usr/bin/env node
/**
 * Build the P-Chain acknowledgement that a removal or a registration completed,
 * and (optionally) the aggregator request body that signs it.
 *
 *   node scripts/build-l1-registration-ack.cjs --validation <cb58|0x> --registered false
 *   node scripts/build-l1-registration-ack.cjs --validation <cb58|0x> --registered true \
 *        --justification /tmp/inner.hex --out /tmp/ack_signed_request.json
 *
 * Why this shape: the historical March completion transaction (block 19) carries
 * a predicate whose first 95 bytes are the P-Chain's own acknowledgement. Its
 * layout is
 *
 *   [2] codec 0000 | [4] networkID 1 | [32] sourceChainID = 32 zero bytes (P-Chain)
 *   [4] payloadLen 0x35
 *     AddressedCall: [2] codec | [4] typeId 1 | [4] addrLen 0 | [4] payloadLen 0x27
 *       L1ValidatorRegistrationMessage: [2] codec | [4] typeId 2 | [32] validationID | [1] registered
 *
 * so the only fields that vary are the 32-byte validation ID at byte 62 and the
 * single `registered` byte at 94 (00 = removal, 01 = registration).
 *
 * `--registered false` also needs a justification when signing: protobuf field 2
 * (0x12) carrying the validator's INNER RegisterL1ValidatorMessage, which
 * scripts/extract-registration-justification.cjs produces from the original
 * registration transaction. `--registered true` needs none.
 *
 * A P-Chain-sourced message is verified by subnet-evm against the LOCAL subnet's
 * validator set (graft/subnet-evm/precompile/contracts/warp/config.go), so the
 * aggregate request must force `signing-subnet-id` to the L1.
 */
const fs = require('fs');
const { ethers } = require('ethers');

const RPC = process.env.RPC_URL || 'https://rpc.omnicoin.net';
const SUBNET_ID = process.env.SUBNET_ID || '27dmQbsGrm4xo9VfrxNSewccy3kZ6N49MuSNJhsdhKkMaTZcYv';
const TEMPLATE_BLOCK = Number(process.env.TEMPLATE_BLOCK || 19);
const COMPLETE_REGISTRATION_SELECTOR = '0xa3a65e48';

const ALPHABET = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';

function cb58ToBytes(value) {
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
  return body.subarray(0, body.length - 4); // drop the 4-byte checksum
}

function argValue(name, fallback) {
  const i = process.argv.indexOf(name);
  return i === -1 ? fallback : process.argv[i + 1];
}

async function main() {
  const raw = argValue('--validation', '');
  if (!raw) throw new Error('give --validation <cb58 or 0x hex>');
  const registered = (argValue('--registered', 'false') || '').toLowerCase();
  if (registered !== 'true' && registered !== 'false') throw new Error('--registered must be true or false');

  const idBytes = /^0x[0-9a-fA-F]{64}$/.test(raw)
    ? Buffer.from(raw.slice(2), 'hex')
    : cb58ToBytes(raw);
  if (idBytes.length !== 32) throw new Error(`validation ID is ${idBytes.length} bytes, expected 32`);

  const provider = new ethers.JsonRpcProvider(RPC, 88008, { staticNetwork: true });
  const block = await provider.getBlock(TEMPLATE_BLOCK);
  let template = null;
  for (const hash of block.transactions) {
    const tx = await provider.getTransaction(hash);
    const data = tx.data || tx.input || '';
    if (!data.startsWith(COMPLETE_REGISTRATION_SELECTOR)) continue;
    const entry = (tx.accessList || []).find((e) => e.address.toLowerCase() === '0x0200000000000000000000000000000000000005');
    if (!entry) continue;
    template = Buffer.from(entry.storageKeys.map((k) => k.slice(2)).join(''), 'hex');
  }
  if (!template) throw new Error(`no completion transaction with a Warp predicate in block ${TEMPLATE_BLOCK}`);
  if (template.length < 95) throw new Error('template shorter than 95 bytes');

  const ack = Buffer.from(template.subarray(0, 95));
  if (ack.readUInt32BE(38) !== 0x35) throw new Error('template payload length is not 0x35; refusing');
  idBytes.copy(ack, 62);
  ack[94] = registered === 'true' ? 0x01 : 0x00;

  const outPath = argValue('--out', '');
  const justPath = argValue('--justification', '');
  if (outPath) {
    const body = { message: '0x' + ack.toString('hex'), 'signing-subnet-id': SUBNET_ID, 'quorum-percentage': 100 };
    if (justPath) body.justification = '0x' + fs.readFileSync(justPath, 'utf8').trim().replace(/^0x/, '');
    fs.writeFileSync(outPath, JSON.stringify(body));
  }

  console.log(`# validationID   ${raw}`);
  console.log(`# id hex         ${idBytes.toString('hex')}`);
  console.log(`# registered     ${registered} (byte 94 = ${ack[94]})`);
  console.log(`# template       block ${TEMPLATE_BLOCK}, payloadLen 0x35, sourceChain P-Chain`);
  if (outPath) console.log(`# request body   ${outPath}${justPath ? ' (with justification)' : ''}`);
  console.log(`\n${ack.toString('hex')}`);
}

main().catch((e) => { console.error('ERROR:', e.message ?? e); process.exit(1); });
