#!/usr/bin/env node
/**
 * Send COTI gas from the deployer successor to the new Hyperlane COTI relayer.
 *
 * Run this ON YOUR LAPTOP, where the successor key lives (C:\Users\rickc\ob-keys).
 *
 *   node send-coti-gas.mjs
 *   node send-coti-gas.mjs 5          # send 5 COTI (default)
 *
 * It asks for the key with echo off, refuses unless it derives the successor
 * address, prints the plan, and waits for YES. Nothing is stored.
 *
 * COTI mainnet: chain id 2632500, https://mainnet.coti.io/rpc, gas ~15 gwei.
 * A relayer delivery costs well under 0.01 COTI, so 5 leaves years of headroom.
 */
import { ethers } from 'ethers';
import readline from 'node:readline';

const RPC = 'https://mainnet.coti.io/rpc';
const CHAIN_ID = 2632500;
const FROM_EXPECTED = '0x68d002Bb315E8310c1344EeA707f9C36DdC33e1e'; // deployer successor
const RELAYER = '0xe427d911b60efc6d4ccd286ccfceda0424f56d48'; // new COTI Hyperlane signer

function askHidden(question) {
  if (!process.stdin.isTTY) {
    return new Promise((resolve) => {
      const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
      rl.question(question, (a) => { rl.close(); resolve(a); });
    });
  }
  return new Promise((resolve) => {
    process.stdout.write(question);
    let buf = '';
    process.stdin.setRawMode(true);
    process.stdin.resume();
    process.stdin.setEncoding('utf8');
    const onData = (chunk) => {
      for (const ch of chunk) {
        if (ch === '\u0003') { process.stdout.write('\n'); process.exit(1); }
        if (ch === '\r' || ch === '\n') {
          process.stdin.removeListener('data', onData);
          process.stdin.setRawMode(false);
          process.stdin.pause();
          process.stdout.write('\n');
          return resolve(buf);
        }
        if (ch === '\u007f') { buf = buf.slice(0, -1); continue; }
        buf += ch;
      }
    };
    process.stdin.on('data', onData);
  });
}

function ask(question) {
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
  return new Promise((resolve) => rl.question(question, (a) => { rl.close(); resolve(a.trim()); }));
}

(async () => {
  const amount = ethers.parseEther(process.argv[2] || '5');
  const provider = new ethers.JsonRpcProvider(RPC, undefined, { staticNetwork: true });
  const net = await provider.getNetwork();
  if (Number(net.chainId) !== CHAIN_ID) {
    throw new Error(`expected COTI mainnet ${CHAIN_ID}, got ${net.chainId} from ${RPC} — refusing`);
  }

  const raw = await askHidden('Successor private key (hidden, not stored): ');
  const key = raw.trim().replace(/^0x/, '');
  if (!/^[0-9a-fA-F]{64}$/.test(key)) throw new Error('that is not a 64-hex private key');

  const wallet = new ethers.Wallet(key, provider);
  if (wallet.address.toLowerCase() !== FROM_EXPECTED.toLowerCase()) {
    throw new Error(`that key controls ${wallet.address}, not the successor ${FROM_EXPECTED}. Refusing.`);
  }

  const bal = await provider.getBalance(wallet.address);
  const fee = await provider.getFeeData();
  const maxFeePerGas = (fee.maxFeePerGas ?? fee.gasPrice ?? 20000000000n) * 2n;
  const gasCost = maxFeePerGas * 21000n;

  console.log(`\nsender    ${wallet.address}`);
  console.log(`balance   ${ethers.formatEther(bal)} COTI`);
  console.log(`recipient ${RELAYER}  (new Hyperlane COTI relayer)`);
  console.log(`amount    ${ethers.formatEther(amount)} COTI`);
  console.log(`gas price ${ethers.formatUnits(maxFeePerGas, 'gwei')} gwei  (cost ~${ethers.formatEther(gasCost)} COTI)`);

  if (bal < amount + gasCost) {
    throw new Error(`balance too low: need ${ethers.formatEther(amount + gasCost)} COTI including gas`);
  }

  const answer = await ask('\nType YES to send: ');
  if (answer !== 'YES') { console.log('aborted, nothing sent'); return; }

  const tx = await wallet.sendTransaction({ to: RELAYER, value: amount, gasLimit: 21000, maxFeePerGas });
  console.log(`\nsent    ${tx.hash}`);
  const rc = await tx.wait();
  console.log(`mined   block ${rc.blockNumber}  status ${rc.status}`);
  if (rc.status !== 1) throw new Error('transaction failed on-chain');

  console.log(`\nrecipient balance now ${ethers.formatEther(await provider.getBalance(RELAYER))} COTI`);
  console.log(`sender balance now    ${ethers.formatEther(await provider.getBalance(wallet.address))} COTI`);
})().catch((e) => {
  console.error('\nFAILED:', e.shortMessage || e.message);
  process.exit(1);
});
