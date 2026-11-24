#!/usr/bin/env node
/**
 * Transfer the L1 subnet's ownership (its `controlKeys`) to the successor.
 *
 *   node scripts/transfer-subnet-ownership.cjs --to P-avax1…            # dry run
 *   node scripts/transfer-subnet-ownership.cjs --to P-avax1… --send
 *
 * Signed by the current control key (deployer-nopfx.pk, P-avax10ksugn…). After the
 * validator owner rotation this is the last P-Chain authority the compromised key
 * holds. Subnet ownership is separate from the L1's `managerAddress` (fixed at
 * conversion), so moving it does not touch the validator manager.
 */
const fs = require('fs');
const { pvm, utils, secp256k1, addTxSignatures, Context } = require('@avalabs/avalanchejs');

const URI = process.env.AVALANCHE_RPC_URL ?? 'http://65.108.205.101:9650';
const SUBNET_ID = process.env.SUBNET_ID || '27dmQbsGrm4xo9VfrxNSewccy3kZ6N49MuSNJhsdhKkMaTZcYv';
const KEY_PATH = process.env.OWNER_KEY_FILE ?? '/home/omnirick/.avalanche-cli/key/deployer-nopfx.pk';
const EXPECTED_ADDR = 'P-avax10ksugn55xn5ctfpfvf4mpf896dvvcxvfhu8v80';

function argValue(name, fallback) {
  const i = process.argv.indexOf(name);
  return i === -1 ? fallback : process.argv[i + 1];
}

function parsePAddress(value) {
  const s = value.replace(/^P-/, '').toLowerCase();
  const pos = s.lastIndexOf('1');
  const CHARSET = 'qpzry9x8gf2tvdw0s3jn54khce6mua7l';
  const data = [...s.slice(pos + 1)].map((c) => CHARSET.indexOf(c));
  const payload = data.slice(0, -6);
  const out = [];
  let acc = 0; let bits = 0;
  for (const v of payload) {
    acc = (acc << 5) | v; bits += 5;
    while (bits >= 8) { bits -= 8; out.push((acc >> bits) & 0xff); }
  }
  return Buffer.from(out);
}

async function main() {
  const send = process.argv.includes('--send');
  const to = argValue('--to', '');
  if (!to) throw new Error('give --to P-avax…');

  const pkHex = fs.readFileSync(KEY_PATH, 'utf8').trim().replace(/^0x/, '');
  const privKey = utils.hexToBuffer(pkHex);
  const addrBytes = secp256k1.publicKeyBytesToAddress(secp256k1.getPublicKey(privKey));
  const derived = 'P-' + utils.formatBech32('avax', addrBytes);
  if (derived !== EXPECTED_ADDR) throw new Error(`key derives ${derived}, expected ${EXPECTED_ADDR} — ABORTING`);

  const newOwner = parsePAddress(to);
  if (newOwner.length !== 20) throw new Error(`destination is ${newOwner.length} bytes, expected 20`);

  const api = new pvm.PVMApi(URI);
  const context = await Context.getContextFromURI(URI);
  const feeState = await api.getFeeState();
  const { utxos } = await api.getUTXOs({ addresses: [EXPECTED_ADDR] });
  if (utxos.length === 0) throw new Error('no UTXOs on ' + EXPECTED_ADDR);

  const unsignedTx = pvm.e.newTransferSubnetOwnershipTx(
    {
      subnetId: SUBNET_ID,
      subnetOwners: [newOwner],
      threshold: 1,
      locktime: 0n,
      subnetAuth: [0],
      feeState,
      fromAddressesBytes: [addrBytes],
      utxos,
    },
    context,
  );
  // addTxSignatures only signs credentials backed by *inputs*; the subnet-auth
  // credential (one per subnetAuth entry) is left with the zero placeholder, and
  // the P-Chain answers "unauthorized modification: invalid signature". Sign it
  // explicitly: the auth signature is over the same sha256 of the unsigned bytes.
  await addTxSignatures({ unsignedTx, privateKeys: [privKey] });
  const { createHash } = require('node:crypto');
  const hash = new Uint8Array(createHash('sha256').update(Buffer.from(unsignedTx.toBytes())).digest());
  const authSig = await secp256k1.signHash(hash, privKey);
  unsignedTx.addSignatureAt(authSig, 1, 0);

  console.log(`# from            ${EXPECTED_ADDR}`);
  console.log(`# subnet          ${SUBNET_ID}`);
  console.log(`# new owner       ${to}  (0x${newOwner.toString('hex')})`);
  console.log(`# threshold       1`);
  console.log(`# fee state       price ${feeState.price}`);
  console.log(`# mode            ${send ? 'SEND' : 'DRY RUN (built and signed, not issued)'}`);

  if (!send) { console.log('\nDry run. Re-run with --send to issue it.'); return; }

  const resp = await api.issueSignedTx(unsignedTx.getSignedTx());
  console.log(`\nissued ${resp.txID}`);
  for (let i = 0; i < 30; i++) {
    const st = await api.getTxStatus({ txID: resp.txID });
    if (st.status === 'Committed') { console.log('committed'); return; }
    if (st.status === 'Dropped') throw new Error(`tx ${resp.txID} DROPPED`);
    await new Promise((r) => setTimeout(r, 2000));
  }
  throw new Error('tx did not commit within 60 s');
}

main().catch((e) => { console.error('ERROR:', e.message ?? e); process.exit(1); });
