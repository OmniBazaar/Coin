#!/usr/bin/env node
/**
 * Empty the two keys that are about to be destroyed, before they are.
 *
 *   node scripts/sweep-keys-before-shred.cjs            # dry run
 *   node scripts/sweep-keys-before-shred.cjs --send
 *
 *   0xaDAD7751… (deployer-nopfx.pk) — native XOM left after the role handovers
 *        -> successor 0x68d002Bb…
 *   0x874A67B7… (rotation-operator.pk) — 20 XOM of unspent stake
 *        -> successor 0x68d002Bb…
 *      and the 100 ERC-20 XOM that a "send XOM" on the app put there by mistake
 *        -> back to the treasury account 0x5169ce02… it came from
 *
 * Native XOM on this chain is also the gas token, so each transfer keeps exactly
 * enough behind to pay for itself at the 100-wei cap and no more.
 */
const fs = require('fs');
const os = require('os');
const { ethers } = require('ethers');

const RPC = process.env.RPC_URL || 'https://rpc.omnicoin.net';
const MAX_FEE_WEI = 100n;
const GAS_TRANSFER = 21000n;
const GAS_TOKEN = 300000n;
const TOKEN = '0x1eE61487F08F715055358A1F020A86c9E571ED78'; // ERC-20 "XOM" (not the gas coin)
const SUCCESSOR = '0x68d002Bb315E8310c1344EeA707f9C36DdC33e1e';
const TREASURY = '0x5169ce023c76f516710395BDad053d935C054aa2';

const JOBS = [
  {
    name: 'deployer-nopfx native XOM -> successor',
    keyFile: '/home/omnirick/.avalanche-cli/key/deployer-nopfx.pk',
    expect: '0xaDAD7751DcDd2E30015C173F2c35a56e467CD9ba',
    kind: 'native',
    to: SUCCESSOR,
  },
  {
    name: 'rotation operator ERC-20 XOM -> treasury (the mistaken funding)',
    keyFile: '/home/omnirick/.omnibazaar-keys/rotation-operator.pk',
    expect: '0x874A67B78EfA9A9b78D60bd5c52c4eaB69778762',
    kind: 'token',
    to: TREASURY,
  },
  {
    name: 'rotation operator native XOM -> successor (after the token fee)',
    keyFile: '/home/omnirick/.omnibazaar-keys/rotation-operator.pk',
    expect: '0x874A67B78EfA9A9b78D60bd5c52c4eaB69778762',
    kind: 'native',
    to: SUCCESSOR,
  },
];

async function main() {
  const send = process.argv.includes('--send');
  const provider = new ethers.JsonRpcProvider(RPC, 88008, { staticNetwork: true });
  const token = new ethers.Contract(TOKEN, ['function balanceOf(address) view returns (uint256)', 'function transfer(address,uint256) returns (bool)'], provider);

  for (const job of JOBS) {
    const wallet = new ethers.Wallet('0x' + fs.readFileSync(job.keyFile.replace(/^~/, os.homedir()), 'utf8').trim().replace(/^0x/, ''), provider);
    if (wallet.address.toLowerCase() !== job.expect.toLowerCase()) throw new Error(`${job.keyFile} is ${wallet.address}, expected ${job.expect} — ABORTING`);

    const native = await provider.getBalance(wallet.address);
    const feeData = await provider.getFeeData();
    const quoted = feeData.maxFeePerGas ?? feeData.gasPrice ?? 0n;
    const gasPrice = quoted > MAX_FEE_WEI ? MAX_FEE_WEI : quoted < 10n ? 10n : quoted;

    console.log(`\n== ${job.name} ==`);
    console.log(`   from ${wallet.address}`);
    console.log(`   native balance ${ethers.formatEther(native)} XOM`);

    let tx;
    if (job.kind === 'native') {
      const reserve = GAS_TRANSFER * gasPrice;
      if (native <= reserve) { console.log('   nothing above the fee — skipped'); continue; }
      const value = native - reserve;
      tx = { to: job.to, value, gasLimit: GAS_TRANSFER, maxFeePerGas: gasPrice, maxPriorityFeePerGas: 0n };
      console.log(`   send ${ethers.formatEther(value)} XOM native -> ${job.to}`);
    } else {
      const amount = await token.balanceOf(wallet.address);
      if (amount === 0n) { console.log('   no token balance — skipped'); continue; }
      tx = { to: TOKEN, data: token.interface.encodeFunctionData('transfer', [job.to, amount]), gasLimit: GAS_TOKEN, maxFeePerGas: gasPrice, maxPriorityFeePerGas: 0n };
      console.log(`   send ${ethers.formatEther(amount)} ERC-20 XOM -> ${job.to}`);
      if (native < GAS_TOKEN * gasPrice) { console.log('   not enough native XOM for the token transfer fee — skipped'); continue; }
    }

    console.log(`   fee ${GAS_TRANSFER === tx.gasLimit ? '21000' : tx.gasLimit} gas at ${gasPrice} wei`);
    if (!send) continue;
    try {
      const sent = await wallet.sendTransaction(tx);
      console.log(`   sent ${sent.hash}`);
      const rc = await sent.wait();
      console.log(`   mined block ${rc.blockNumber} status ${rc.status}`);
    } catch (e) {
      console.log(`   FAILED: ${(e.shortMessage || e.message).slice(0, 140)}`);
    }
  }
  if (!send) console.log('\nDry run only. Re-run with --send.');
}

main().catch((e) => { console.error('ERROR:', e.message ?? e); process.exit(1); });
