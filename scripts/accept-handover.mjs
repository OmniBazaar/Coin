#!/usr/bin/env node
/**
 * Step 2 of the deployer role handover. Run this ON YOUR LAPTOP, never on a
 * server: it needs the cold key for 0x68d002Bb315E8310c1344EeA707f9C36DdC33e1e.
 *
 * It sends exactly three transactions on OmniCoin (chain 88008):
 *   EscrowV2.acceptAdmin()            -> earlier step made this address pendingAdmin
 *   OmniVotingPowerCap.acceptAdmin()  -> same
 *   RWAComplianceOracle.acceptRegistrar() -> earlier step made this address pendingRegistrar
 *
 * Setup (once):
 *   node --version                  # need v18 or newer
 *   npm install ethers@6
 *
 * Run:
 *   node accept-handover.mjs
 *   (it asks for the private key with echo off, prints the plan, and waits for Y)
 *
 * Safety properties:
 *   - The key is never echoed, never written to disk, never put in argv (so it
 *     cannot land in shell history or a process list).
 *   - Before sending, it checks on-chain that each contract really has this
 *     address pending. If a check fails it refuses to send that transaction.
 *   - Each transaction is confirmed and re-read before the next is sent.
 *   - Re-running is safe: already-accepted roles are detected and skipped.
 */
import { ethers } from 'ethers';
import readline from 'node:readline';

const RPC = 'https://rpc.omnicoin.net';
const CHAIN_ID = 88008;
const SUCCESSOR = '0x68d002Bb315E8310c1344EeA707f9C36DdC33e1e';

const STEPS = [
  {
    name: 'EscrowV2.acceptAdmin',
    address: '0x7144B011ce241eecA38CD0c4948777B761985864',
    method: 'acceptAdmin',
    abi: ['function admin() view returns (address)', 'function pendingAdmin() view returns (address)', 'function acceptAdmin()'],
    // done when admin() is us; ready when pendingAdmin() is us
    current: 'admin',
    pending: 'pendingAdmin',
  },
  {
    name: 'OmniVotingPowerCap.acceptAdmin',
    address: '0x5E5ad7D97E9b3283883d6d62C797f9F57773e7e2',
    method: 'acceptAdmin',
    abi: ['function admin() view returns (address)', 'function pendingAdmin() view returns (address)', 'function acceptAdmin()'],
    current: 'admin',
    pending: 'pendingAdmin',
  },
  {
    name: 'RWAComplianceOracle.acceptRegistrar',
    address: '0x71c290D47423AE509657C0c4B764c9Ef24B21984',
    method: 'acceptRegistrar',
    abi: [
      'function registrar() view returns (address)',
      'function pendingRegistrar() view returns (address)',
      'function acceptRegistrar()',
    ],
    current: 'registrar',
    pending: 'pendingRegistrar',
  },
];

// Read a line without echoing it. Falls back to a plain read when stdin is not
// a terminal (piped input), so the script stays testable.
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
  const provider = new ethers.JsonRpcProvider(RPC, undefined, { staticNetwork: true });
  const net = await provider.getNetwork();
  if (Number(net.chainId) !== CHAIN_ID) {
    throw new Error(`expected chain ${CHAIN_ID} from ${RPC}, got ${net.chainId} — refusing to sign`);
  }

  const raw = await askHidden('Cold private key (hidden, not stored): ');
  const key = raw.trim().replace(/^0x/, '');
  if (!/^[0-9a-fA-F]{64}$/.test(key)) throw new Error('that is not a 64-hex private key');

  const wallet = new ethers.Wallet(key, provider);
  if (wallet.address.toLowerCase() !== SUCCESSOR.toLowerCase()) {
    throw new Error(
      `that key controls ${wallet.address}, but the pending roles belong to ${SUCCESSOR}. Refusing.`,
    );
  }

  const bal = await provider.getBalance(wallet.address);
  console.log(`\naddress   ${wallet.address}`);
  console.log(`balance   ${ethers.formatEther(bal)} XOM`);
  if (bal === 0n) throw new Error('this account has no XOM for gas — fund it first');

  // Work out what is actually left to do.
  const todo = [];
  for (const step of STEPS) {
    const ct = new ethers.Contract(step.address, step.abi, provider);
    const current = (await ct[step.current]()).toLowerCase();
    const pending = (await ct[step.pending]()).toLowerCase();
    if (current === SUCCESSOR.toLowerCase()) {
      console.log(`done      ${step.name}  (already ${SUCCESSOR})`);
      continue;
    }
    if (pending !== SUCCESSOR.toLowerCase()) {
      console.log(`BLOCKED   ${step.name}  (${step.pending} is ${pending}, not ${SUCCESSOR})`);
      continue;
    }
    console.log(`ready     ${step.name}  (currently ${current})`);
    todo.push({ ...step, ct });
  }

  if (!todo.length) {
    console.log('\nNothing to do.');
    return;
  }

  console.log(`\n${todo.length} transaction(s) will be sent to chain ${CHAIN_ID} via ${RPC}.`);
  const answer = await ask('Type YES to send: ');
  if (answer !== 'YES') {
    console.log('aborted, nothing sent');
    return;
  }

  const fee = await provider.getFeeData();
  const base = fee.maxFeePerGas ?? ethers.parseUnits('1', 'gwei');
  // The chain's base fee is a few wei; 1 gwei maxFee is ~330,000x headroom and
  // still costs a fraction of a cent per transaction.
  const maxFeePerGas = base > ethers.parseUnits('1', 'gwei') ? base : ethers.parseUnits('1', 'gwei');

  for (const step of todo) {
    const viaWallet = step.ct.connect(wallet);
    console.log(`\n> ${step.name}`);
    const tx = await viaWallet[step.method]({ maxFeePerGas, maxPriorityFeePerGas: 1n });
    console.log(`  sent    ${tx.hash}`);
    const rc = await tx.wait();
    console.log(`  mined   block ${rc.blockNumber} status ${rc.status}`);
    if (rc.status !== 1) throw new Error(`${step.name} reverted on-chain`);
    const after = await step.ct[step.current]();
    console.log(`  now     ${step.current} = ${after}`);
    if (after.toLowerCase() !== SUCCESSOR.toLowerCase()) {
      throw new Error(`${step.name} did not take effect — stopping before the next one`);
    }
  }

  console.log('\nAll done. Record the hashes above in scripts/key-ceremony/LEDGER.md.');
})().catch((e) => {
  console.error('\nFAILED:', e.shortMessage || e.message);
  process.exit(1);
});
