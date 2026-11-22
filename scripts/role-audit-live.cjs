#!/usr/bin/env node
/**
 * Read-only role audit: who actually controls each contract right now.
 * No transactions. No keys. Safe to run any time.
 *
 *   node scripts/role-audit-live.cjs [chainId]
 *
 * Defaults to OmniCoin L1 (88008). Prints one line per (contract, role, holder)
 * and flags any holder that is the retired deployer or a retired signer.
 */
const { ethers } = require('ethers');
const fs = require('fs');
const path = require('path');

const RPC = {
  88008: 'https://rpc.omnicoin.net',
  43114: 'https://api.avax.network/ext/bc/C/rpc',
  11155111: 'https://ethereum-sepolia-rpc.publicnode.com',
};

const RETIRED = new Set([
  '0x021868f2e3d49c059ef52b539aaa933b437e0321'.toLowerCase(), // deployer
  '0x0d7a2c153979d095abb4ae3ed7fcf5429a5cdd71'.toLowerCase(), // iceberg-omnibazaar
  '0x78417313f74ea2b208913730db3e879425ed3e92'.toLowerCase(), // ob-treasury-2026-10-20
  '0x5cdeed30431b7ef3b92260c666c49eab85e21b27'.toLowerCase(), // ob-staking-reserve
  '0x213490a7c0e1681ad4239fbb829994aeeecd193'.toLowerCase(), // omnirick legacy
  '0x54d67a9b90adceb7e92f7b22a9af24b834d1cd3d'.toLowerCase(), // processor legacy
  '0xe1190cec2a601c181e98d863fa4dbae38fb39bfc'.toLowerCase(), // referrer legacy
]);

const ABI = [
  'function owner() view returns (address)',
  'function admin() view returns (address)',
  'function registrar() view returns (address)',
  'function pendingOwner() view returns (address)',
  'function DEFAULT_ADMIN_ROLE() view returns (bytes32)',
  'function getRoleMember(bytes32 role, uint256 index) view returns (address)',
  'function getRoleMemberCount(bytes32 role) view returns (uint256)',
  'function hasRole(bytes32 role, address account) view returns (bool)',
  'function PROPOSER_ROLE() view returns (bytes32)',
  'function EXECUTOR_ROLE() view returns (bytes32)',
  'function CANCELLER_ROLE() view returns (bytes32)',
  'function TIMELOCK_ADMIN_ROLE() view returns (bytes32)',
  'function OPERATOR_ROLE() view returns (bytes32)',
];

// AccessControl-style role names we want to expand on timelock-like contracts.
const ROLE_NAMES = [
  'PROPOSER_ROLE', 'EXECUTOR_ROLE', 'CANCELLER_ROLE', 'TIMELOCK_ADMIN_ROLE',
  'OPERATOR_ROLE', 'DEFAULT_ADMIN_ROLE',
];

async function tryCall(contract, fn, ...args) {
  try {
    return await contract[fn](...args);
  } catch {
    return undefined;
  }
}

async function main() {
  const chainId = Number(process.argv[2] || 88008);
  const deploymentPath = path.join(__dirname, '..', 'deployments', 'mainnet.json');
  const dep = JSON.parse(fs.readFileSync(deploymentPath, 'utf8'));
  const c = dep.contracts || {};

  const targets = [
    ['OmniArbitration', c.OmniArbitration],
    ['PrivateDEX', c.PrivateDEX],
    ['PrivateDEXSettlement', c.PrivateDEXSettlement],
    ['RWAComplianceOracle', c.RWAComplianceOracle],
    ['PioneerAllowlist', c.PioneerAllowlist],
    ['OmniVotingPowerCap', c.OmniVotingPowerCap],
    ['EscrowV2', c.EscrowV2],
    ['UpdateRegistry', c.UpdateRegistry],
    ['OmniBonding', c.OmniBonding],
    ['ValidatorActivityLedger', c.ValidatorActivityLedger],
    ['EmergencyGuardian', c.EmergencyGuardian],
    ['OmniTimelockController', c.OmniTimelockController],
  ].filter(([, addr]) => addr);

  const provider = new ethers.JsonRpcProvider(RPC[chainId] || RPC[88008], undefined, {
    staticNetwork: true,
  });
  const net = await provider.getNetwork();
  console.log(`# chain ${net.chainId} via ${RPC[chainId] || RPC[88008]}\n`);

  const flagged = [];

  for (const [name, addr] of targets) {
    const ct = new ethers.Contract(addr, ABI, provider);
    console.log(`${name} ${addr}`);
    const singles = ['owner', 'admin', 'registrar', 'pendingOwner'];
    for (const fn of singles) {
      const v = await tryCall(ct, fn);
      if (v) {
        const mark = RETIRED.has(v.toLowerCase()) ? '  <-- RETIRED KEY' : '';
        if (mark) flagged.push(`${name}.${fn}() = ${v}`);
        console.log(`  ${fn.padEnd(13)} ${v}${mark}`);
      }
    }
    for (const roleName of ROLE_NAMES) {
      const role = await tryCall(ct, roleName);
      if (!role) continue;
      const count = await tryCall(ct, 'getRoleMemberCount', role);
      if (count === undefined) continue;
      const members = [];
      for (let i = 0n; i < count; i++) {
        members.push(await tryCall(ct, 'getRoleMember', role, i));
      }
      const ret = members.filter((m) => m && RETIRED.has(m.toLowerCase()));
      if (ret.length) flagged.push(`${name}.${roleName} holds retired key ${ret.join(',')}`);
      console.log(
        `  ${roleName.padEnd(20)} ${members.map((m) => m + (m && RETIRED.has(m.toLowerCase()) ? '*' : '')).join(', ') || '(none)'}`,
      );
    }
    // Timelock generic: dump role counts by scanning well-known role constants only.
    console.log('');
  }

  console.log('## Summary — retired keys still holding authority');
  if (!flagged.length) console.log('  none');
  for (const f of flagged) console.log('  ' + f);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
