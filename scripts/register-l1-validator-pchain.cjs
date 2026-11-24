#!/usr/bin/env node
/**
 * Issue RegisterL1ValidatorTx on the P-Chain, carrying the L1-signed registration
 * message for v5. Step 3g of the runbook.
 *
 *   node scripts/register-l1-validator-pchain.cjs --message /tmp/reg_signed.hex --balance 0.35
 *   node scripts/register-l1-validator-pchain.cjs --message /tmp/reg_signed.hex --balance 0.35 --send
 *
 * Signed and paid by the P-Chain owner EOA on this host. The balance is the new
 * validator's continuous-fee runway, spent from the same UTXOs as the fee.
 * 0.0396 AVAX/day is what v5 actually burned, so 0.35 is about nine days; the next
 * validator's refund tops it up.
 *
 * The proof of possession is read from the node itself (info.getNodeID -> nodePOP)
 * and is a BLS signature over the public key, per
 * vms/platformvm/signer/proof_of_possession.go.
 */
const fs = require('fs');
const os = require('os');
const { pvm, utils, secp256k1, addTxSignatures, Context } = require('@avalabs/avalanchejs');

const URI = process.env.AVALANCHE_RPC_URL ?? 'http://65.108.205.116:9650';
const NODE_INFO = process.env.V5_NODE_INFO ?? 'http://65.108.205.101:9650/ext/info';
const KEY_PATH = process.env.OWNER_KEY_FILE ?? '/home/omnirick/.avalanche-cli/key/deployer-nopfx.pk';
const EXPECTED_ADDR = 'P-avax10ksugn55xn5ctfpfvf4mpf896dvvcxvfhu8v80';
const BLS_PUBLIC_KEY =
  '0x84470018ba04e7673def87191879d5e45c2805cab130000b73c8608a1e7e4505d862b3d4da2c869f14ed9de6b0c4d699';

function argValue(name, fallback) {
  const i = process.argv.indexOf(name);
  return i === -1 ? fallback : process.argv[i + 1];
}

async function main() {
  const send = process.argv.includes('--send');
  const messageArg = (argValue('--message', '') || '').replace(/^~/, os.homedir());
  const balanceAvax = argValue('--balance', '0.35');
  const balance = BigInt(Math.round(Number(balanceAvax) * 1e9));
  if (!messageArg) throw new Error('give --message <file or hex of the signed registration message>');
  if (!Number.isFinite(Number(balanceAvax)) || balance <= 0n) throw new Error('--balance must be AVAX');

  const hex = /^0x[0-9a-fA-F]+$/.test(messageArg.trim())
    ? messageArg.trim().replace(/^0x/, '')
    : fs.readFileSync(messageArg, 'utf8').trim().replace(/^0x/, '');
  const message = utils.hexToBuffer(hex);

  const info = await fetch(NODE_INFO, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'info.getNodeID', params: {} }),
  }).then((r) => r.json());
  const pop = utils.hexToBuffer(info.result.nodePOP.proofOfPossession.replace(/^0x/, ''));
  const liveKey = info.result.nodePOP.publicKey.toLowerCase();

  const pk = fs.readFileSync(KEY_PATH, 'utf8').trim().replace(/^0x/, '');
  const privKey = utils.hexToBuffer(pk);
  const addrBytes = secp256k1.publicKeyBytesToAddress(secp256k1.getPublicKey(privKey));
  const derived = 'P-' + utils.formatBech32('avax', addrBytes);
  if (derived !== EXPECTED_ADDR) throw new Error(`key derives ${derived}, expected ${EXPECTED_ADDR}`);

  const api = new pvm.PVMApi(URI);
  const context = await Context.getContextFromURI(URI);
  const feeState = await api.getFeeState();
  const { utxos } = await api.getUTXOs({ addresses: [EXPECTED_ADDR] });
  const bal = await api.getBalance({ addresses: [EXPECTED_ADDR] });

  console.log(`# node            ${info.result.nodeID}`);
  console.log(`# BLS key live    ${liveKey}  ${liveKey === BLS_PUBLIC_KEY.toLowerCase() ? '(matches the registered key)' : '(DIFFERENT - stop)'}`);
  console.log(`# POP bytes       ${pop.length}`);
  console.log(`# message bytes   ${message.length}  contains v5 key: ${hex.includes(BLS_PUBLIC_KEY.slice(2))}`);
  console.log(`# payer           ${derived}  balance ${Number(bal.balance) / 1e9} AVAX in ${utxos.length} UTXOs`);
  console.log(`# validator bal   ${balanceAvax} AVAX (~${(Number(balanceAvax) / 0.0396).toFixed(0)} days of continuous fee)`);
  console.log(`# fee state       price ${feeState.price}`);

  if (liveKey !== BLS_PUBLIC_KEY.toLowerCase()) throw new Error('the node key is not the one being registered; refusing');
  if (!hex.includes(BLS_PUBLIC_KEY.slice(2))) {
    throw new Error('the signed message does not contain the expected BLS key; refusing');
  }

  const unsignedTx = pvm.e.newRegisterL1ValidatorTx(
    { balance, blsSignature: pop, message, feeState, fromAddressesBytes: [addrBytes], utxos },
    context
  );
  await addTxSignatures({ unsignedTx, privateKeys: [privKey] });
  const signedTx = unsignedTx.getSignedTx();
  console.log(`# serialized      ${signedTx.toBytes().length} bytes`);
  console.log(`# mode            ${send ? 'SEND' : 'DRY RUN'}\n`);

  if (!send) {
    console.log('Dry run. Re-run with --send to issue it.');
    return;
  }
  const resp = await api.issueSignedTx(signedTx);
  console.log(`issued ${resp.txID}`);
  for (let i = 0; i < 45; i++) {
    const st = await api.getTxStatus({ txID: resp.txID });
    if (st.status === 'Committed') { console.log('committed'); break; }
    if (st.status === 'Dropped') throw new Error(`DROPPED: ${JSON.stringify(st)}`);
    await new Promise((r) => setTimeout(r, 2000));
  }

  const { validators } = await api.getCurrentValidators({
    subnetID: '27dmQbsGrm4xo9VfrxNSewccy3kZ6N49MuSNJhsdhKkMaTZcYv',
  });
  console.log(`\nvalidators now ${validators.length}`);
  for (const v of validators) console.log(`  ${v.nodeID} weight ${v.weight} balance ${(Number(v.balance) / 1e9).toFixed(6)}`);
}

main().catch((e) => {
  console.error('FATAL:', e.message ?? e);
  process.exit(1);
});
