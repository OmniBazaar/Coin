#!/usr/bin/env node
/**
 * Move the last two EVM authorities off the compromised key 0xaDAD7751… to the
 * successor 0x68d002Bb…:
 *
 *   1. the subnet-evm ContractNativeMinter admin at 0x0200…0001 — the holder can
 *      mint native XOM at will;
 *   2. the owner of both OZ ProxyAdmins (0xa0AffE… manager proxy, 0x97A35a4A…
 *      specialization proxy) — the owner can upgrade either proxy.
 *
 *   node scripts/transfer-evm-authorities.cjs                 # dry run
 *   node scripts/transfer-evm-authorities.cjs --send
 *   node scripts/transfer-evm-authorities.cjs --only minter --send
 *
 * Each step is simulated before it is sent, and the result is read back from
 * chain, not assumed.
 */
const fs = require('fs');
const os = require('os');
const { ethers } = require('ethers');

const RPC = process.env.RPC_URL || 'https://rpc.omnicoin.net';
const KEY_FILE = process.env.OWNER_KEY_FILE || '/home/omnirick/.avalanche-cli/key/deployer-nopfx.pk';
const FROM = '0xaDAD7751DcDd2E30015C173F2c35a56e467CD9ba';
const TO = '0x68d002Bb315E8310c1344EeA707f9C36DdC33e1e';
const MINTER = '0x0200000000000000000000000000000000000001';
const PROXY_ADMINS = [
  ['manager proxy 0x0Feedc0de…', '0xa0AffE1234567890ABcDef1234567890ABCdEF34'],
  ['specialization proxy 0x100c0De1…', '0x97A35a4A2A8a56256de7A32160819c7B3F4C9DA6'],
];
const MAX_FEE_WEI = 100n;

function argValue(name, fallback) {
  const i = process.argv.indexOf(name);
  return i === -1 ? fallback : process.argv[i + 1];
}

async function main() {
  const send = process.argv.includes('--send');
  const only = argValue('--only', '');

  const provider = new ethers.JsonRpcProvider(RPC, 88008, { staticNetwork: true });
  const pk = '0x' + fs.readFileSync(KEY_FILE.replace(/^~/, os.homedir()), 'utf8').trim().replace(/^0x/, '');
  const wallet = new ethers.Wallet(pk, provider);
  if (wallet.address.toLowerCase() !== FROM.toLowerCase()) {
    throw new Error(`key derives ${wallet.address}, expected the compromised owner ${FROM} — ABORTING`);
  }

  const ownable = new ethers.Interface(['function owner() view returns (address)', 'function transferOwnership(address)']);
  const minter = new ethers.Interface(['function setAdmin(address)']);

  const steps = [];
  if (!only || only === 'minter') {
    steps.push({
      name: 'native minter admin',
      to: MINTER,
      data: minter.encodeFunctionData('setAdmin', [TO]),
      readback: async () => {
        // The admin is not readable through a getter; prove it by simulation.
        for (const who of [FROM, TO]) {
          try {
            await provider.call({ from: who, to: MINTER, data: minter.encodeFunctionData('setAdmin', [TO]) });
            return `setAdmin allowed from ${who === FROM ? '0xaDAD7751' : 'successor'}`;
          } catch {}
        }
        return 'setAdmin allowed from neither — unexpected';
      },
    });
  }
  // setAdmin on this deployment adds an admin without demoting the previous one
  // (measured: after transfer both read role 2 and both could mint), so the old
  // address has to be removed from the allow list explicitly.
  if (!only || only === 'minter') {
    steps.push({
      name: 'demote the compromised key from the minter allow list',
      to: MINTER,
      data: new ethers.Interface(['function setNone(address)']).encodeFunctionData('setNone', [FROM]),
      readback: async () => {
        const list = new ethers.Interface(['function readAllowList(address) view returns (uint256)']);
        const role = (a) => provider.call({ to: MINTER, data: list.encodeFunctionData('readAllowList', [a]) }).then((r) => Number(r));
        return `role now: compromised ${await role(FROM)}, successor ${await role(TO)}`;
      },
    });
  }
  for (const [label, addr] of PROXY_ADMINS) {
    if (only && only !== 'proxy') continue;
    const owner = await new ethers.Contract(addr, ownable, provider).owner();
    steps.push({
      name: `ProxyAdmin owner (${label})`,
      to: addr,
      data: ownable.encodeFunctionData('transferOwnership', [TO]),
      readback: async () => `owner() = ${await new ethers.Contract(addr, ownable, provider).owner()}`,
      current: owner,
      expect: FROM,
    });
  }

  for (const step of steps) {
    console.log(`\n== ${step.name} ==`);
    console.log(`   to      ${step.to}`);
    if (step.current) console.log(`   owner   ${step.current}${step.current.toLowerCase() === FROM.toLowerCase() ? ' (compromised)' : ' (NOT the compromised key — check before sending)'}`);
    const fee = await provider.getFeeData();
    const quoted = fee.maxFeePerGas ?? fee.gasPrice ?? 0n;
    const gasPrice = quoted > MAX_FEE_WEI ? MAX_FEE_WEI : quoted < 10n ? 10n : quoted;
    try {
      const gas = await provider.estimateGas({ from: FROM, to: step.to, data: step.data });
      await provider.call({ from: FROM, to: step.to, data: step.data });
      console.log(`   simulate SUCCESS, gas ${gas}, fee ${gasPrice} wei`);
      if (!send) continue;
      const sent = await wallet.sendTransaction({ to: step.to, data: step.data, gasLimit: gas + 50000n, maxFeePerGas: gasPrice, maxPriorityFeePerGas: 0n });
      console.log(`   sent    ${sent.hash}`);
      const rc = await sent.wait();
      if (!rc || rc.status !== 1) throw new Error(`${step.name} reverted`);
      console.log(`   mined   block ${rc.blockNumber}  status ${rc.status}`);
      console.log(`   ${await step.readback()}`);
    } catch (e) {
      console.log(`   simulate/execute FAILED: ${(e.shortMessage || e.message).slice(0, 140)}`);
    }
  }
  if (!send) console.log('\nDry run only. Re-run with --send.');
}

main().catch((e) => { console.error('ERROR:', e.message ?? e); process.exit(1); });
