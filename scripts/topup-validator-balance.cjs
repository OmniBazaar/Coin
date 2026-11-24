#!/usr/bin/env node
/**
 * Top up ONE L1 validator's continuous-fee balance by a fixed amount
 * (ACP-77 IncreaseL1ValidatorBalanceTx). Used by the owner rotation: each
 * removal refunds ~10 AVAX to P-avax10ksugn…, and that refund must put the
 * already-rotated validators back above 2 AVAX before the next removal starts.
 *
 *   node scripts/topup-validator-balance.cjs --validation <cb58> --add 5          # dry run
 *   node scripts/topup-validator-balance.cjs --validation <cb58> --add 5 --send
 *
 * Paid and signed by the P-Chain owner key (deployer-nopfx.pk). The tx fee is
 * 0.001 AVAX, so a small float on that address covers it.
 *
 * `--add` is the AMOUNT ADDED, not the resulting balance. Read the current
 * balance from platform.getCurrentValidators and compute the difference.
 */
const fs = require('fs');
const { pvm, utils, secp256k1, addTxSignatures, Context } = require('@avalabs/avalanchejs');

const URI = process.env.AVALANCHE_RPC_URL ?? 'http://65.108.205.116:9650';
const KEY_PATH = process.env.OWNER_KEY_FILE ?? '/home/omnirick/.avalanche-cli/key/deployer-nopfx.pk';
const EXPECTED_ADDR = 'P-avax10ksugn55xn5ctfpfvf4mpf896dvvcxvfhu8v80';

function argValue(name, fallback) {
  const i = process.argv.indexOf(name);
  return i === -1 ? fallback : process.argv[i + 1];
}

async function main() {
  const send = process.argv.includes('--send');
  const validationId = argValue('--validation');
  const addAvax = Number(argValue('--add'));
  if (!validationId) throw new Error('give --validation <cb58 validationID>');
  if (!Number.isFinite(addAvax) || addAvax <= 0) throw new Error('give --add <avax amount>');

  const pkHex = fs.readFileSync(KEY_PATH, 'utf8').trim().replace(/^0x/, '');
  const privKey = utils.hexToBuffer(pkHex);
  const addrBytes = secp256k1.publicKeyBytesToAddress(secp256k1.getPublicKey(privKey));
  const derived = 'P-' + utils.formatBech32('avax', addrBytes);
  if (derived !== EXPECTED_ADDR) throw new Error(`key derives ${derived}, expected ${EXPECTED_ADDR} — ABORTING`);

  const pvmApi = new pvm.PVMApi(URI);
  const context = await Context.getContextFromURI(URI);
  const feeState = await pvmApi.getFeeState();
  const { utxos } = await pvmApi.getUTXOs({ addresses: [EXPECTED_ADDR] });
  if (utxos.length === 0) throw new Error('no UTXOs on ' + EXPECTED_ADDR);

  const balanceNavax = BigInt(Math.round(addAvax * 1e9));
  const unsignedTx = pvm.e.newIncreaseL1ValidatorBalanceTx(
    { balance: balanceNavax, validationId, feeState, fromAddressesBytes: [addrBytes], utxos },
    context,
  );
  await addTxSignatures({ unsignedTx, privateKeys: [privKey] });

  console.log(`# from           ${EXPECTED_ADDR}`);
  console.log(`# validationID   ${validationId}`);
  console.log(`# add            ${addAvax} AVAX`);
  console.log(`# fee state      price ${feeState.price}  capacity ${feeState.capacity}`);
  console.log(`# mode           ${send ? 'SEND' : 'DRY RUN (built and signed, not issued)'}`);

  if (!send) {
    console.log('\nDry run. Re-run with --send to issue it.');
    return;
  }

  const resp = await pvmApi.issueSignedTx(unsignedTx.getSignedTx());
  console.log(`\nissued ${resp.txID}`);
  for (let i = 0; i < 30; i++) {
    const st = await pvmApi.getTxStatus({ txID: resp.txID });
    if (st.status === 'Committed') { console.log('committed'); return; }
    if (st.status === 'Dropped') throw new Error(`tx ${resp.txID} DROPPED: ${JSON.stringify(st)}`);
    await new Promise((r) => setTimeout(r, 2000));
  }
  throw new Error('tx did not commit within 60 s');
}

main().catch((e) => { console.error('ERROR:', e.message ?? e); process.exit(1); });
