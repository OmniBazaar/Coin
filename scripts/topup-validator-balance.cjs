#!/usr/bin/env node
/**
 * Bring L1 validators' continuous-fee balances up to a target (ACP-77
 * IncreaseL1ValidatorBalanceTx). Pays from whichever P-Chain key you give it.
 *
 *   node scripts/topup-validator-balance.cjs --key-file deployer.pk --to 10          # dry run, all five
 *   node scripts/topup-validator-balance.cjs --key-file deployer.pk --to 10 --send
 *   node scripts/topup-validator-balance.cjs --key-file k.pk --add 2 --validation <cb58> --send
 *
 * `--to`  target balance per validator; the increase is computed from the chain, so
 *         running it twice is harmless and a validator already at or above target
 *         is skipped.
 * `--add` fixed amount per validator, used when there is no target in mind.
 * Without `--validation` every current validator of the subnet is visited.
 *
 * Requires @avalabs/avalanchejs@5.1.0 (`npm install @avalabs/avalanchejs@5.1.0`).
 * 6.x changed the client API and this file will fail on it with
 * "api.getBalance is not a function". Save this file as `.cjs`, not `.mjs`: it uses
 * CommonJS `require`. The fee is ~0.001 AVAX per transaction, so the paying address
 * needs a little more than the amounts it is adding.
 */
const fs = require('fs');
const os = require('os');
const { pvm, utils, secp256k1, addTxSignatures, Context } = require('@avalabs/avalanchejs');

const URI = process.env.AVALANCHE_RPC_URL ?? 'http://65.108.205.116:9650';
const SUBNET_ID = process.env.SUBNET_ID || '27dmQbsGrm4xo9VfrxNSewccy3kZ6N49MuSNJhsdhKkMaTZcYv';
const FEE_AVAX = 0.001;

function argValue(name, fallback) {
  const i = process.argv.indexOf(name);
  return i === -1 ? fallback : process.argv[i + 1];
}

async function main() {
  const send = process.argv.includes('--send');
  const keyFile = (argValue('--key-file', process.env.OWNER_KEY_FILE) || '').replace(/^~/, os.homedir());
  const to = argValue('--to', '');
  const add = argValue('--add', '');
  const only = argValue('--validation', '');
  const expectP = argValue('--expect-p', '');

  if (!keyFile) throw new Error('give --key-file <path to the P-Chain private key, 64 hex>');
  if (!to && !add) throw new Error('give either --to <target AVAX> or --add <AVAX>');
  if (to && add) throw new Error('give --to or --add, not both');

  const pkHex = fs.readFileSync(keyFile, 'utf8').trim().replace(/^0x/, '');
  if (!/^[0-9a-fA-F]{64}$/.test(pkHex)) throw new Error(`${keyFile} is not a 64-character hex key`);
  const privKey = utils.hexToBuffer(pkHex);
  const addrBytes = secp256k1.publicKeyBytesToAddress(secp256k1.getPublicKey(privKey));
  const payer = 'P-' + utils.formatBech32('avax', addrBytes);
  if (expectP && payer !== expectP) throw new Error(`key derives ${payer}, expected ${expectP} — ABORTING`);

  const api = new pvm.PVMApi(URI);
  const context = await Context.getContextFromURI(URI);

  const { validators } = await api.getCurrentValidators({ subnetID: SUBNET_ID });
  const targets = only ? validators.filter((v) => v.validationID === only) : validators;
  if (targets.length === 0) throw new Error('no matching validator');

  const { balance: payerBalance } = await api.getBalance({ addresses: [payer] });
  console.log(`# payer           ${payer}`);
  console.log(`# payer balance   ${Number(payerBalance) / 1e9} AVAX`);
  console.log(`# validators      ${targets.length}`);

  let planned = 0n;
  const work = [];
  for (const v of targets) {
    const current = BigInt(v.balance);
    const increase = to ? BigInt(Math.round(Number(to) * 1e9)) - current : BigInt(Math.round(Number(add) * 1e9));
    const label = `${v.nodeID} (${Number(current) / 1e9} AVAX)`;
    if (increase <= 0n) { console.log(`# skip            ${label} — already at or above target`); continue; }
    console.log(`# top up          ${label} +${Number(increase) / 1e9} AVAX`);
    planned += increase;
    work.push({ validationID: v.validationID, increase });
  }

  const needed = planned + BigInt(Math.round(FEE_AVAX * 1e9 * work.length));
  console.log(`# total needed    ${Number(planned) / 1e9} AVAX + ~${FEE_AVAX} per tx`);
  if (payerBalance < needed) {
    console.log(`# WARNING         payer holds ${Number(payerBalance) / 1e9} AVAX, needs ~${Number(needed) / 1e9}`);
  }
  if (!send) { console.log('\nDry run. Re-run with --send to issue.'); return; }
  if (work.length === 0) return;

  for (const { validationID, increase } of work) {
    const feeState = await api.getFeeState();
    // The change output of the previous transaction can take a moment to appear in
    // the address index; without this wait the second of five top-ups dies with
    // "no UTXOs left".
    let utxos = [];
    for (let attempt = 0; attempt < 20; attempt++) {
      ({ utxos } = await api.getUTXOs({ addresses: [payer] }));
      if (utxos.length > 0) break;
      await new Promise((r) => setTimeout(r, 2000));
    }
    if (utxos.length === 0) throw new Error(`no UTXOs left on ${payer}`);
    const unsignedTx = pvm.e.newIncreaseL1ValidatorBalanceTx(
      { balance: increase, validationId: validationID, feeState, fromAddressesBytes: [addrBytes], utxos },
      context,
    );
    await addTxSignatures({ unsignedTx, privateKeys: [privKey] });
    const resp = await api.issueSignedTx(unsignedTx.getSignedTx());
    for (let i = 0; i < 30; i++) {
      const st = await api.getTxStatus({ txID: resp.txID });
      if (st.status === 'Committed') { console.log(`issued ${resp.txID}  +${Number(increase) / 1e9} AVAX  committed`); break; }
      if (st.status === 'Dropped') throw new Error(`tx ${resp.txID} DROPPED`);
      await new Promise((r) => setTimeout(r, 2000));
    }
  }
}

main().catch((e) => { console.error('ERROR:', e.message ?? e); process.exit(1); });
