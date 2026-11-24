#!/usr/bin/env node
/**
 * Send AVAX on the P-Chain from the owner address to another P-Chain address.
 *
 *   node scripts/send-pchain.cjs --to P-avax1... --amount 10                      # dry run
 *   node scripts/send-pchain.cjs --to P-avax1... --amount 10 --send               # broadcast
 *
 * Signed by the P-Chain owner EOA on this host. @avalabs/avalanchejs 5.1.0 and
 * the same call pattern as Validator/scripts/topup-l1-validators.cjs.
 */
const fs = require('fs');
const { pvm, utils, secp256k1, addTxSignatures, Context } = require('@avalabs/avalanchejs');
const { TransferableOutput } = require('@avalabs/avalanchejs');

const URI = process.env.AVALANCHE_RPC_URL ?? 'http://65.108.205.116:9650';
const KEY_PATH = process.env.OWNER_KEY_FILE ?? '/home/omnirick/.avalanche-cli/key/deployer-nopfx.pk';
const EXPECTED_ADDR = 'P-avax10ksugn55xn5ctfpfvf4mpf896dvvcxvfhu8v80';

function argValue(name, fallback) {
  const i = process.argv.indexOf(name);
  return i === -1 ? fallback : process.argv[i + 1];
}

async function main() {
  const send = process.argv.includes('--send');
  const to = argValue('--to', '');
  const amount = Number(argValue('--amount', ''));
  if (!/^P-avax1[0-9a-z]+$/.test(to)) throw new Error('--to must be a P-avax1… address');
  if (!Number.isFinite(amount) || amount <= 0) throw new Error('--amount is in AVAX, e.g. 10');
  const amountNavax = BigInt(Math.round(amount * 1e9));

  const pkHex = fs.readFileSync(KEY_PATH, 'utf8').trim().replace(/^0x/, '');
  const privKey = utils.hexToBuffer(pkHex);
  const addrBytes = secp256k1.publicKeyBytesToAddress(secp256k1.getPublicKey(privKey));
  const derived = 'P-' + utils.formatBech32('avax', addrBytes);
  if (derived !== EXPECTED_ADDR) throw new Error(`key derives ${derived}, expected ${EXPECTED_ADDR} - ABORTING`);

  const toBytes = utils.bech32ToBytes(to);
  const api = new pvm.PVMApi(URI);
  const context = await Context.getContextFromURI(URI);
  const feeState = await api.getFeeState();
  const { utxos } = await api.getUTXOs({ addresses: [EXPECTED_ADDR] });
  const bal = await api.getBalance({ addresses: [EXPECTED_ADDR] });
  const balance = BigInt(bal.balance);

  const output = TransferableOutput.fromNative(context.avaxAssetID, amountNavax, [toBytes]);
  const unsignedTx = pvm.e.newBaseTx(
    { outputs: [output], feeState, fromAddressesBytes: [addrBytes], utxos },
    context
  );
  await addTxSignatures({ unsignedTx, privateKeys: [privKey] });
  const signedTx = unsignedTx.getSignedTx();

  const txFee = BigInt(context.baseTxFee);
  const change = balance - amountNavax - txFee;

  console.log(`# from        ${derived}`);
  console.log(`# to          ${to}`);
  console.log(`# amount      ${amount} AVAX`);
  console.log(`# balance     ${Number(balance) / 1e9} AVAX in ${utxos.length} UTXOs`);
  console.log(`# base tx fee ${Number(txFee) / 1e9} AVAX`);
  console.log(`# change back ${Number(change) / 1e9} AVAX${change < 0n ? '   *** NEGATIVE - amount too large ***' : ''}`);
  console.log(`# mode        ${send ? 'SEND' : 'DRY RUN (built and signed, not issued)'}\n`);

  if (change < 0n) throw new Error('the amount plus the fee exceeds the balance');
  if (change === 0n) console.log('WARNING: this leaves the address with no AVAX to pay future P-Chain fees.\n');

  if (!send) {
    console.log('Dry run. Re-run with --send to broadcast.');
    return;
  }
  const resp = await api.issueSignedTx(signedTx);
  console.log(`issued ${resp.txID}`);
  for (let i = 0; i < 30; i++) {
    const st = await api.getTxStatus({ txID: resp.txID });
    if (st.status === 'Committed') { console.log('committed'); break; }
    if (st.status === 'Dropped') throw new Error(`DROPPED: ${JSON.stringify(st)}`);
    await new Promise((r) => setTimeout(r, 2000));
  }
  const after = await api.getBalance({ addresses: [EXPECTED_ADDR, to] });
  console.log('\nbalances now:');
  for (const [addr, navax] of Object.entries(after.balances ?? {})) console.log(`  ${addr} ${Number(navax) / 1e9}`);
}

main().catch((e) => {
  console.error('FATAL:', e.message ?? e);
  process.exit(1);
});
