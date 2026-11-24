// Send NATIVE XOM on OmniCoin (chain 88008) from the successor account.
//
//   node send-native-xom.mjs                  # sends 100 XOM to the rotation operator
//   node send-native-xom.mjs 25               # sends a different amount
//   node send-native-xom.mjs 100 --dry-run    # signs and prints, broadcasts nothing
//   node send-native-xom.mjs 100 --key-file other.pk
//
// Reads the private key from ./deployer.pk (plain 64-char hex, 0x optional).
// The key must derive to the successor account. Any other key aborts before
// signing and says which known key it is, so a wrong file cannot send anything.
//
// Fee note: this chain caps maxFeePerGas at 100 wei. Anything above is rejected,
// which is why a wallet that fills in 1 gwei fails here.
import fs from 'node:fs';
import path from 'node:path';
import { JsonRpcProvider, Wallet, parseEther, formatEther } from 'ethers';

const RPC = 'https://rpc.omnicoin.net';
const CHAIN_ID = 88008;
const EXPECTED = '0x68d002Bb315E8310c1344EeA707f9C36DdC33e1e'; // successor — the only key allowed
const TO = '0x874A67B78EfA9A9b78D60bd5c52c4eaB69778762';       // rotation operator
const MAX_FEE_WEI = 100n;
const GAS = 21000n;                                            // plain wallet-to-wallet, no code at TO

// Keys that exist on the server and must never be used for this transfer.
const KNOWN = {
  '0x874a67b78efa9a9b78d60bd5c52c4eab69778762': 'the rotation operator itself (receives, does not send)',
  '0xadad7751dcdd2e30015c173f2c35a56e467cd9ba': 'the P-Chain owner key (deployer-nopfx)',
  '0x021868f2e3d49c059ef52b539aaa933b437e0321': 'the compromised deployer key',
  '0x1eba49e6dd1d52663339ab071bf770f97ffd8a3c': "validator-5's staking key (retired)",
};

const arg = (name, fallback) => {
  const i = process.argv.indexOf(name);
  return i === -1 ? fallback : process.argv[i + 1];
};
const positional = process.argv.slice(2).filter((a, i, all) => !a.startsWith('--') && !all[i - 1]?.startsWith('--'));
const amountArg = positional[0] ?? '100';
const dryRun = process.argv.includes('--dry-run');
const keyFile = path.resolve(arg('--key-file', 'deployer.pk'));

if (!fs.existsSync(keyFile)) {
  console.error(`key file not found: ${keyFile}`);
  console.error('Run this from the folder that holds deployer.pk, or pass --key-file <path>.');
  process.exit(1);
}

const raw = fs.readFileSync(keyFile, 'utf8').trim();
const hex = raw.replace(/^0x/, '');
if (!/^[0-9a-fA-F]{64}$/.test(hex)) {
  console.error(`${path.basename(keyFile)} does not hold a 64-character hex private key (found ${hex.length} chars).`);
  process.exit(1);
}

const provider = new JsonRpcProvider(RPC, CHAIN_ID, { staticNetwork: true });
const net = await provider.getNetwork();
if (Number(net.chainId) !== CHAIN_ID) {
  console.error(`wrong chain: got ${net.chainId}, expected ${CHAIN_ID}`);
  process.exit(1);
}

const wallet = new Wallet(hex, provider);
if (wallet.address.toLowerCase() !== EXPECTED.toLowerCase()) {
  console.error(`ABORT: ${path.basename(keyFile)} holds the key for ${wallet.address},`);
  console.error(`       not the successor ${EXPECTED}.`);
  if (KNOWN[wallet.address.toLowerCase()]) console.error(`       That is ${KNOWN[wallet.address.toLowerCase()]}.`);
  console.error('       Nothing was signed.');
  process.exit(1);
}

let amount;
try {
  amount = parseEther(amountArg);
} catch {
  console.error(`not an amount: ${amountArg}`);
  process.exit(1);
}

const balance = await provider.getBalance(wallet.address);
const toBefore = await provider.getBalance(TO);
const nonce = await provider.getTransactionCount(wallet.address, 'pending');
const block = await provider.getBlock('latest');
const baseFee = block.baseFeePerGas ?? 1n;
const maxFeePerGas = baseFee < MAX_FEE_WEI ? MAX_FEE_WEI : baseFee;
const fee = GAS * maxFeePerGas;

console.log(`key file       ${keyFile}`);
console.log(`network        OmniCoin chain ${net.chainId}`);
console.log(`from           ${wallet.address}  (successor)`);
console.log(`to             ${TO}  (rotation operator)`);
console.log(`amount         ${formatEther(amount)} XOM native`);
console.log(`balance now    ${formatEther(balance)} XOM`);
console.log(`recipient now  ${formatEther(toBefore)} XOM native`);
console.log(`nonce          ${nonce}`);
console.log(`fee            ${GAS} gas at ${maxFeePerGas} wei = ${formatEther(fee)} XOM`);

if (balance < amount + fee) {
  console.error('ABORT: not enough native XOM for amount + fee. (Token XOM cannot pay a native transfer.)');
  process.exit(1);
}

const tx = {
  type: 2,
  chainId: CHAIN_ID,
  to: TO,
  value: amount,
  nonce,
  gasLimit: GAS,
  maxFeePerGas,
  maxPriorityFeePerGas: 0n,
};

const signed = await wallet.signTransaction(tx);

if (dryRun) {
  console.log(`\nDRY RUN: signed ${(signed.length - 2) / 2} bytes, nothing broadcast.`);
  process.exit(0);
}

const hash = (await provider.broadcastTransaction(signed)).hash;
console.log(`\nbroadcast      ${hash}`);
console.log('waiting for the receipt...');

for (let i = 0; i < 60; i++) {
  const rc = await provider.getTransactionReceipt(hash);
  if (rc) {
    if (rc.status !== 1) {
      console.error(`FAILED: status ${rc.status} in block ${rc.blockNumber}`);
      process.exit(1);
    }
    console.log(`confirmed      block ${rc.blockNumber}, gasUsed ${rc.gasUsed}, effectiveGasPrice ${rc.gasPrice} wei`);
    console.log(`recipient now  ${formatEther(await provider.getBalance(TO))} XOM native`);
    process.exit(0);
  }
  await new Promise((r) => setTimeout(r, 1000));
}
console.error('no receipt after 60 s — check the hash above before retrying.');
process.exit(2);
