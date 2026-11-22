#!/usr/bin/env node
/**
 * Live access-control map for the OmniCoin L1 contracts, read-only.
 *
 * Uses raw eth_call so it does not depend on any ABI file being current.
 * Prints, for every access-controlled contract, the holder of each role, and
 * flags any holder on the retired-signer list.
 *
 *   node scripts/role-map-live.cjs [rpcUrl]
 */
const RETIRED = {
  '0x021868f2e3d49c059ef52b539aaa933b437e0321': 'deployer (compromised)',
  '0x0d7a2c153979d095abb4ae3ed7fcf5429a5cdd71': 'iceberg-omnibazaar (retired)',
  '0x78417313f74ea2b208913730db3e879425ed3e92': 'ob-treasury-2026-10-20 (retired)',
  '0x5cdeed30431b7ef3b92260c666c49eab85e21b27': 'ob-staking-reserve (retired)',
  '0x213490a7c0e1681ad4239fbb829994aeeecd193': 'omnirick legacy (retired)',
  '0x54d67a9b90adceb7e92f7b22a9af24b834d1cd3d': 'processor legacy (retired)',
  '0xe1190cec2a601c181e98d863fa4dbae38fb39bfc': 'referrer legacy (retired)',
};

const RPC = process.argv[2] || 'https://rpc.omnicoin.net';

const CONTRACTS = {
  OmniArbitration: '0x73d0Ea976850D2E8C0262255f1955B05973C0C38',
  PrivateDEX: '0x8eEA9eCe017796A60e0Bf2A5ee59fd18b020c58D',
  PrivateDEXSettlement: '0xa07899F3bC247fB2AEb36BF6c4849342116277D4',
  RWAComplianceOracle: '0x71c290D47423AE509657C0c4B764c9Ef24B21984',
  PioneerAllowlist: '0xcC123970D1b5E3161D0CD5A4fFD34d9B16dC281d',
  OmniVotingPowerCap: '0x5E5ad7D97E9b3283883d6d62C797f9F57773e7e2',
  EscrowV2: '0x7144B011ce241eecA38CD0c4948777B761985864',
  UpdateRegistry: '0xd8E2a242dd344BE4A61c3DdD4332717766EB648B',
  ValidatorActivityLedger: '0xd87a8673f95a2ED17e13Ade4D4F88CE73b0A439e',
  EmergencyGuardian: '0x60752E5762C4eC606730bad3806a1139825BC2e6',
  OmniTimelockController: '0x4f78386cA05E333639151fe0508b21D893CaD222',
  OmniBonding: '0xdC6F422daF15575D8FDbB633B929C0333212f168',
};

// keccak256 of the role name, for the standard OpenZeppelin roles plus ours.
const ROLE_NAMES = [
  'DEFAULT_ADMIN_ROLE', 'ADMIN_ROLE', 'OPERATOR_ROLE', 'PAUSER_ROLE', 'UPGRADER_ROLE',
  'GUARDIAN_ROLE', 'DISPUTE_ADMIN_ROLE', 'SETTLER_ROLE', 'RECORDER_ROLE',
  'PROPOSER_ROLE', 'EXECUTOR_ROLE', 'CANCELLER_ROLE', 'TIMELOCK_ADMIN_ROLE',
  'MINTER_ROLE', 'BURNER_ROLE', 'VERIFIER_ROLE', 'JUDGE_ROLE', 'ATTESTER_ROLE',
];

const ZERO_ROLE = '0x' + '0'.repeat(64);

// Minimal keccak256 so this script has no dependencies.
function keccak256(str) {
  const { createHash } = require('crypto');
  // Node's sha3-256 is not keccak256; use the bundled ethers if present.
  return null;
}

let ethers;
try {
  ethers = require('ethers');
} catch {
  console.error('ethers is required (run from Coin/ so node_modules resolves)');
  process.exit(1);
}

async function eth(rpc, to, data) {
  const res = await fetch(rpc, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'eth_call', params: [{ to, data }, 'latest'] }),
  });
  const body = await res.json();
  if (body.error) return null;
  return body.result;
}

function roleId(name) {
  if (name === 'DEFAULT_ADMIN_ROLE') return ZERO_ROLE;
  return ethers.keccak256(ethers.toUtf8Bytes(name));
}

async function membersOf(rpc, addr, role) {
  const countHex = await eth(rpc, addr, '0x' + ethers.id('getRoleMemberCount(bytes32)').slice(2, 10) + role.slice(2));
  if (!countHex || countHex === '0x') return null;
  const count = Number(BigInt(countHex));
  if (count > 50) return null;
  const out = [];
  for (let i = 0; i < count; i++) {
    const idx = i.toString(16).padStart(64, '0');
    const sel = '0x' + ethers.id('getRoleMember(bytes32,uint256)').slice(2, 10);
    const hex = await eth(rpc, addr, sel + role.slice(2) + idx);
    if (hex && hex.length === 66) out.push(ethers.getAddress('0x' + hex.slice(26)));
  }
  return out;
}

async function single(rpc, addr, sig) {
  const sel = '0x' + ethers.id(sig).slice(2, 10);
  const hex = await eth(rpc, addr, sel);
  if (!hex || hex.length < 66) return null;
  const word = hex.slice(0, 66);
  // Return both address-ish and uint-ish interpretations; caller decides.
  return { word, address: '0x' + word.slice(26) };
}

(async () => {
  const flagged = [];
  console.log(`# rpc ${RPC}\n`);
  for (const [name, addr] of Object.entries(CONTRACTS)) {
    const lines = [];
    for (const fn of ['owner()', 'admin()', 'registrar()', 'pendingOwner()', 'proposer()', 'executor()']) {
      const r = await single(RPC, addr, `function ${fn}`.replace('function ', ''));
      if (!r) continue;
      const bad = RETIRED[r.address.toLowerCase()];
      lines.push(`  ${fn.replace('()', '').padEnd(13)} ${r.address}${bad ? `   <== ${bad}` : ''}`);
      if (bad) flagged.push(`${name}.${fn.replace('()', '')}() = ${r.address}  (${bad})`);
    }
    for (const roleName of ROLE_NAMES) {
      const role = roleId(roleName);
      const members = await membersOf(RPC, addr, role);
      if (!members || !members.length) continue;
      const rendered = members.map((m) => (RETIRED[m.toLowerCase()] ? `${m} <== ${RETIRED[m.toLowerCase()]}` : m));
      lines.push(`  ${roleName.padEnd(20)} ${rendered.join(', ')}`);
      for (const m of members) {
        if (RETIRED[m.toLowerCase()]) flagged.push(`${name}.${roleName} includes ${m}  (${RETIRED[m.toLowerCase()]})`);
      }
    }
    if (lines.length) {
      console.log(`${name} ${addr}`);
      console.log(lines.join('\n'));
      console.log('');
    }
  }
  console.log('## Retired keys still holding authority');
  if (!flagged.length) console.log('  none');
  for (const f of [...new Set(flagged)]) console.log('  ' + f);
})();
