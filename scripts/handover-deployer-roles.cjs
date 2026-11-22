#!/usr/bin/env node
/**
 * Deployer -> successor authority handover for the OmniCoin L1.
 *
 *   node scripts/handover-deployer-roles.cjs                 # dry run: eth_call every step
 *   node scripts/handover-deployer-roles.cjs --send          # broadcast, one tx at a time
 *   node scripts/handover-deployer-roles.cjs --send --only EscrowV2
 *
 * Signed by the compromised deployer key, which is still admin on all of these.
 * Successor defaults to the founder-accepted cold successor recorded in
 * scripts/key-ceremony/LEDGER.md. Override with SUCCESSOR=0x...
 *
 * Two-step contracts (EscrowV2, OmniVotingPowerCap, RWAComplianceOracle) only
 * reach step 1 here. The successor completes with acceptAdmin()/acceptRegistrar()
 * from the cold key. Until then the deployer keeps the role, so stopping after
 * this script loses nothing.
 *
 * PioneerAllowlist.transferAdmin is SINGLE-STEP and irreversible, so it needs
 * both --send and --i-understand-pioneer-is-irreversible.
 */
const { ethers } = require('ethers');
const fs = require('fs');
const path = require('path');

const RPC = process.env.RPC_URL || 'https://rpc.omnicoin.net';
const KEY_FILE =
  process.env.DEPLOYER_KEY_FILE || path.join(process.env.HOME, '.avalanche-cli/key/deployer.pk');
const SUCCESSOR = process.env.SUCCESSOR || '0x68d002Bb315E8310c1344EeA707f9C36DdC33e1e';
const DEPLOYER = '0x021868f2E3D49C059EF52B539AAa933B437e0321';

const C = {
  RWAComplianceOracle: '0x71c290D47423AE509657C0c4B764c9Ef24B21984',
  PioneerAllowlist: '0xcC123970D1b5E3161D0CD5A4fFD34d9B16dC281d',
  OmniVotingPowerCap: '0x5E5ad7D97E9b3283883d6d62C797f9F57773e7e2',
  EscrowV2: '0x7144B011ce241eecA38CD0c4948777B761985864',
  PrivateDEXSettlement: '0xa07899F3bC247fB2AEb36BF6c4849342116277D4',
  ValidatorActivityLedger: '0xd87a8673f95a2ED17e13Ade4D4F88CE73b0A439e',
};

const ABI = [
  'function admin() view returns (address)',
  'function pendingAdmin() view returns (address)',
  'function registrar() view returns (address)',
  'function transferAdmin(address newAdmin)',
  'function proposeRegistrar(address newRegistrar)',
  'function grantRole(bytes32 role, address account)',
  'function DEFAULT_ADMIN_ROLE() view returns (bytes32)',
  'function hasRole(bytes32 role, address account) view returns (bool)',
];

async function buildPlan(wallet, pioneerAllowed) {
  const plan = [];
  const mk = (name, addr, method, args, skipReason) => {
    const ct = new ethers.Contract(addr, ABI, wallet);
    plan.push({ name, ct, method, args, skipReason });
  };

  {
    const ct = new ethers.Contract(C.EscrowV2, ABI, wallet);
    const cur = await ct.admin();
    mk('EscrowV2.transferAdmin', C.EscrowV2, 'transferAdmin', [SUCCESSOR],
      cur.toLowerCase() !== DEPLOYER.toLowerCase() ? `admin already ${cur}` : null);
  }
  {
    const ct = new ethers.Contract(C.OmniVotingPowerCap, ABI, wallet);
    const cur = await ct.admin();
    mk('OmniVotingPowerCap.transferAdmin', C.OmniVotingPowerCap, 'transferAdmin', [SUCCESSOR],
      cur.toLowerCase() !== DEPLOYER.toLowerCase() ? `admin already ${cur}` : null);
  }
  {
    const ct = new ethers.Contract(C.RWAComplianceOracle, ABI, wallet);
    const cur = await ct.registrar();
    mk('RWAComplianceOracle.proposeRegistrar', C.RWAComplianceOracle, 'proposeRegistrar', [SUCCESSOR],
      cur.toLowerCase() !== DEPLOYER.toLowerCase() ? `registrar already ${cur}` : null);
  }
  {
    const ct = new ethers.Contract(C.PioneerAllowlist, ABI, wallet);
    const cur = await ct.admin();
    mk('PioneerAllowlist.transferAdmin', C.PioneerAllowlist, 'transferAdmin', [SUCCESSOR],
      cur.toLowerCase() !== DEPLOYER.toLowerCase()
        ? `admin already ${cur}`
        : pioneerAllowed
          ? null
          : 'SINGLE-STEP AND IRREVERSIBLE - needs --i-understand-pioneer-is-irreversible');
  }
  for (const [name, addr] of [
    ['PrivateDEXSettlement', C.PrivateDEXSettlement],
    ['ValidatorActivityLedger', C.ValidatorActivityLedger],
  ]) {
    const ct = new ethers.Contract(addr, ABI, wallet);
    const role = await ct.DEFAULT_ADMIN_ROLE();
    const has = await ct.hasRole(role, SUCCESSOR);
    mk(`${name}.grantRole(DEFAULT_ADMIN_ROLE)`, addr, 'grantRole', [role, SUCCESSOR],
      has ? 'successor already holds DEFAULT_ADMIN_ROLE' : null);
  }
  return plan;
}

async function main() {
  const send = process.argv.includes('--send');
  const onlyIdx = process.argv.indexOf('--only');
  const only = onlyIdx === -1 ? null : process.argv[onlyIdx + 1];
  const pioneerAllowed = send && process.argv.includes('--i-understand-pioneer-is-irreversible');

  const provider = new ethers.JsonRpcProvider(RPC, undefined, { staticNetwork: true });
  const net = await provider.getNetwork();
  if (Number(net.chainId) !== 88008) throw new Error(`expected chain 88008, got ${net.chainId}`);

  const raw = fs.readFileSync(KEY_FILE, 'utf8').trim().replace(/^0x/, '');
  const wallet = new ethers.Wallet(raw, provider);
  if (wallet.address.toLowerCase() !== DEPLOYER.toLowerCase()) {
    throw new Error(`key file derives ${wallet.address}, expected deployer ${DEPLOYER}`);
  }

  const bal = await provider.getBalance(wallet.address);
  const fee = await provider.getFeeData();
  const gasPrice = fee.maxFeePerGas ?? fee.gasPrice;
  console.log(`# chain      ${net.chainId}  ${RPC}`);
  console.log(`# signer     ${wallet.address}  (compromised deployer, still admin)`);
  console.log(`# balance    ${ethers.formatEther(bal)} XOM`);
  console.log(`# nonce      ${await provider.getTransactionCount(wallet.address)}`);
  console.log(`# successor  ${SUCCESSOR}`);
  console.log(`# gas price  ${gasPrice ? ethers.formatUnits(gasPrice, 'gwei') + ' gwei' : 'unknown'}`);
  console.log(`# mode       ${send ? 'SEND' : 'DRY RUN (eth_call only)'}\n`);

  const plan = await buildPlan(wallet, pioneerAllowed);
  const results = [];

  for (const step of plan) {
    if (only && !step.name.startsWith(only)) continue;
    if (step.skipReason) {
      console.log(`SKIP  ${step.name}\n      ${step.skipReason}`);
      results.push({ name: step.name, status: 'skip' });
      continue;
    }
    const fn = step.ct[step.method];
    try {
      const ret = await fn.staticCall(...step.args);
      const gas = await fn.estimateGas(...step.args);
      console.log(`SIM   ${step.name}  gas=${gas}`);
      if (!send) {
        results.push({ name: step.name, status: 'simulated', gas });
        continue;
      }
      const tx = await fn(...step.args);
      console.log(`SENT  ${step.name}  ${tx.hash}`);
      const rc = await tx.wait();
      console.log(`MINE  ${step.name}  block ${rc.blockNumber}  status ${rc.status}`);
      results.push({ name: step.name, status: 'sent', hash: tx.hash, gas: gas.toString() });
      void ret;
    } catch (e) {
      console.log(`FAIL  ${step.name}\n      ${e.shortMessage || e.message}`);
      results.push({ name: step.name, status: 'fail', error: e.shortMessage || e.message });
      if (send) {
        console.log('\n# stopping: a broadcast failure must be inspected before continuing');
        break;
      }
    }
    console.log('');
  }

  console.log('\n## Summary');
  for (const r of results) {
    console.log(`  ${r.status.padEnd(10)} ${r.name}${r.hash ? '  ' + r.hash : ''}${r.error ? '  ' + r.error : ''}`);
  }
}

main().catch((e) => {
  console.error(e.shortMessage || e.message || e);
  process.exit(1);
});
