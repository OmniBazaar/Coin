#!/usr/bin/env node
/**
 * Issue the P-Chain SetL1ValidatorWeightTx that carries the aggregate signature
 * produced for an initiated removal. Weight 0 removes the validator.
 *
 *   node scripts/set-validator-weight.cjs --message /tmp/signed.hex            # dry run
 *   node scripts/set-validator-weight.cjs --message /tmp/signed.hex --send     # issue
 *
 * Signed and paid by the P-Chain owner EOA P-avax10ksugn… (deployer-nopfx.pk on
 * this host). The fee is 0.001 AVAX, so the ~0.43 AVAX already on that address
 * is enough and nothing has to come from the cold key.
 *
 * The message is the aggregator's response, passed VERBATIM. It is not the raw
 * 130-byte unsigned message: it is that message plus the aggregator's signature
 * envelope. Never rebuild or trim it here.
 */
const crypto = require('crypto');
const fs = require('fs');
const os = require('os');
const { pvm, utils, secp256k1, addTxSignatures, Context } = require('@avalabs/avalanchejs');

const URI = process.env.AVALANCHE_RPC_URL ?? 'http://65.108.205.116:9650';
const KEY_PATH = process.env.OWNER_KEY_FILE ?? '/home/omnirick/.avalanche-cli/key/deployer-nopfx.pk';
const EXPECTED_ADDR = 'P-avax10ksugn55xn5ctfpfvf4mpf896dvvcxvfhu8v80';
const REMOVAL = argValue('--validation', process.env.VALIDATION_ID || 'zDGaneyChMythZuK8GUTTTopYs9kMAw1jfQKxuFAWuUSesBEN');

const ALPHABET = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';

function argValue(name, fallback) {
  const i = process.argv.indexOf(name);
  return i === -1 ? fallback : process.argv[i + 1];
}

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
  return body.slice(0, body.length - 4).toString('hex');
}

async function main() {
  const send = process.argv.includes('--send');
  const messagePath = (argValue('--message', '') || '').replace(/^~/, os.homedir());
  if (!messagePath) throw new Error('give --message <file with the signed message hex>');

  const messageHex = fs.readFileSync(messagePath, 'utf8').trim().replace(/^0x/, '');
  if (!/^[0-9a-fA-F]+$/.test(messageHex) || messageHex.length % 2) {
    throw new Error('the message file is not clean hex');
  }
  const message = utils.hexToBuffer(messageHex);
  const validationId = cb58ToHex(REMOVAL);

  const containsId = messageHex.toLowerCase().includes(validationId);
  console.log(`# message bytes   ${message.length}`);
  console.log(`# validationID    ${REMOVAL}  (${validationId})`);
  console.log(`# id in message   ${containsId ? 'yes' : 'NO - STOP, this message is not about that validator'}`);
  console.log(`# weight field    ${messageHex.slice(-16)}`);
  if (!containsId) throw new Error('the signed message does not contain the validation ID; refusing');

  const pkHex = fs.readFileSync(KEY_PATH, 'utf8').trim().replace(/^0x/, '');
  const privKey = utils.hexToBuffer(pkHex);
  const pubKey = secp256k1.getPublicKey(privKey);
  const addrBytes = secp256k1.publicKeyBytesToAddress(pubKey);
  const derived = 'P-' + utils.formatBech32('avax', addrBytes);
  if (derived !== EXPECTED_ADDR) {
    throw new Error(`key derives ${derived}, expected ${EXPECTED_ADDR} - ABORTING`);
  }

  const pvmApi = new pvm.PVMApi(URI);
  const context = await Context.getContextFromURI(URI);
  const feeState = await pvmApi.getFeeState();
  const { utxos } = await pvmApi.getUTXOs({ addresses: [EXPECTED_ADDR] });
  const balance = await pvmApi.getBalance({ addresses: [EXPECTED_ADDR] });

  console.log(`# key             ${derived}  (OK, matches)`);
  console.log(`# P-Chain balance ${Number(balance.balance) / 1e9} AVAX in ${utxos.length} UTXOs`);
  console.log(`# fee state       price ${feeState.price}  capacity ${feeState.capacity}  excess ${feeState.excess}`);
  console.log(`# mode            ${send ? 'SEND' : 'DRY RUN (built and signed, not issued)'}\n`);

  if (utxos.length === 0) throw new Error('no UTXOs to pay the fee with');

  const unsignedTx = pvm.e.newSetL1ValidatorWeightTx(
    { message, feeState, fromAddressesBytes: [addrBytes], utxos },
    context
  );
  await addTxSignatures({ unsignedTx, privateKeys: [privKey] });

  const signedTx = unsignedTx.getSignedTx();
  const txBytes = signedTx.toBytes();
  const txHash = crypto.createHash('sha256').update(txBytes).digest();
  const localID = utils.base58.encode(utils.addChecksum(txHash));
  console.log(`built and signed  txID ${localID}`);
  console.log(`serialized        ${txBytes.length} bytes`);

  if (!send) {
    console.log('\nDry run. Re-run with --send to issue it.');
    return;
  }

  const resp = await pvmApi.issueSignedTx(signedTx);
  console.log(`\nissued ${resp.txID}`);
  if (resp.txID !== localID) console.log(`note: node reported a different txID than computed (${localID})`);

  for (let i = 0; i < 45; i++) {
    const st = await pvmApi.getTxStatus({ txID: resp.txID });
    if (st.status === 'Committed') {
      console.log('committed');
      break;
    }
    if (st.status === 'Dropped') throw new Error(`DROPPED, reason ${JSON.stringify(st)}`);
    await new Promise((r) => setTimeout(r, 2000));
  }

  const { validators } = await pvmApi.getCurrentValidators({
    subnetID: '27dmQbsGrm4xo9VfrxNSewccy3kZ6N49MuSNJhsdhKkMaTZcYv',
  });
  console.log(`\nvalidators now ${validators.length}`);
  for (const v of validators) {
    console.log(`  ${v.nodeID}  weight ${v.weight}  balance ${(Number(v.balance) / 1e9).toFixed(6)}`);
  }
  console.log(`\nv5 present: ${validators.some((v) => v.nodeID === 'NodeID-M2ZR5BAa8huibaeQfCsKs6U1c2dWZhcry')}`);
}

main().catch((e) => {
  console.error('FATAL:', e.message ?? e);
  process.exit(1);
});
