#!/usr/bin/env node
/**
 * Deploy ValidatorManagerForwarder for the L1 validator owner rotation
 * (2026-11-24, path A).
 *
 *   node scripts/deploy-validator-forwarder.cjs          # dry run, no broadcast
 *   node scripts/deploy-validator-forwarder.cjs --send    # broadcast once
 *
 * Signed by the P-Chain owner EOA 0xaDAD7751 (deployer-nopfx.pk), which has gas
 * on chain 88008 and needs no new authority: the forwarder's OPERATOR is the
 * successor, so the key that deploys it cannot call it.
 *
 * The forwarder is only ever the implementation behind the specialization proxy
 * 0x100c0De1C0FFEe00000000000000000000000000, and only for the duration of the
 * rotation. The value to restore is 0x9338b9ef1291b0266d28e520797ed57020a84d3b
 * (see scripts/key-ceremony/LEDGER.md).
 *
 * Chain 88008 caps maxFeePerGas at 100 wei; a 1 gwei request is rejected, so the
 * fee is clamped rather than estimated.
 */
const { ethers } = require('ethers');
const fs = require('fs');
const path = require('path');

const RPC = process.env.RPC_URL || 'https://rpc.omnicoin.net';
const KEY_FILE =
  process.env.OWNER_KEY_FILE || path.join(process.env.HOME, '.avalanche-cli/key/deployer-nopfx.pk');
const OWNER = '0xaDAD7751DcDd2E30015C173F2c35a56e467CD9ba';
const MANAGER = '0x0Feedc0de0000000000000000000000000000000';
const OPERATOR = process.env.SUCCESSOR || '0x68d002Bb315E8310c1344EeA707f9C36DdC33e1e';
const MAX_FEE_WEI = 100n;

const ARTIFACT = path.join(
  __dirname,
  '../artifacts/contracts/validator-manager/ValidatorManagerForwarder.sol/ValidatorManagerForwarder.json'
);

async function main() {
  const send = process.argv.includes('--send');

  const artifact = JSON.parse(fs.readFileSync(ARTIFACT, 'utf8'));
  if (!artifact.bytecode || artifact.bytecode === '0x') {
    throw new Error('artifact has no creation bytecode; compile first');
  }

  const provider = new ethers.JsonRpcProvider(RPC, undefined, { staticNetwork: true });
  const net = await provider.getNetwork();
  if (Number(net.chainId) !== 88008) throw new Error(`expected chain 88008, got ${net.chainId}`);

  const raw = fs.readFileSync(KEY_FILE, 'utf8').trim().replace(/^0x/, '');
  const wallet = new ethers.Wallet(raw, provider);
  if (wallet.address.toLowerCase() !== OWNER.toLowerCase()) {
    throw new Error(`key file derives ${wallet.address}, expected owner ${OWNER}`);
  }

  const nonce = await provider.getTransactionCount(wallet.address);
  const balance = await provider.getBalance(wallet.address);
  const fee = await provider.getFeeData();
  const quoted = fee.maxFeePerGas ?? fee.gasPrice ?? 0n;
  const gasPrice = quoted > MAX_FEE_WEI ? MAX_FEE_WEI : quoted < 10n ? 10n : quoted;

  const factory = new ethers.ContractFactory(artifact.abi, artifact.bytecode, wallet);
  const deployTx = await factory.getDeployTransaction(OPERATOR);
  const gas = await provider.estimateGas({ ...deployTx, from: wallet.address });
  const predicted = ethers.getCreateAddress({ from: wallet.address, nonce });
  const cost = gas * gasPrice;

  console.log(`# chain          ${net.chainId}  ${RPC}`);
  console.log(`# signer         ${wallet.address}  (P-Chain owner EOA, key on this host)`);
  console.log(`# balance        ${ethers.formatEther(balance)} XOM`);
  console.log(`# nonce          ${nonce}`);
  console.log(`# OPERATOR       ${OPERATOR}`);
  console.log(`# gas estimate   ${gas}`);
  console.log(`# gas price      ${gasPrice} wei${quoted !== gasPrice ? ` (clamped from ${quoted})` : ''}`);
  console.log(`# max cost       ${ethers.formatEther(cost)} XOM`);
  console.log(`# predicted addr ${predicted}`);
  console.log(`# runtime size   ${(artifact.deployedBytecode.length - 2) / 2} bytes`);
  console.log(`# mode           ${send ? 'SEND' : 'DRY RUN (no broadcast)'}\n`);

  if (balance < cost) throw new Error('insufficient balance for gas');

  const already = await provider.getCode(predicted);
  if (already !== '0x') {
    const existing = new ethers.Contract(
      predicted,
      ['function OPERATOR() view returns (address)'],
      provider
    );
    throw new Error(
      `code already exists at ${predicted} (OPERATOR ${await existing.OPERATOR()}); refusing to deploy a second time`
    );
  }

  // A previous run of this script may already have deployed one; the predicted
  // address moves with the nonce, so look back before deploying another copy.
  const probeAbi = [
    'function OPERATOR() view returns (address)',
    'function MANAGER() view returns (address)',
  ];
  for (let back = 1; back <= 5 && nonce - back >= 0; back++) {
    const prev = ethers.getCreateAddress({ from: wallet.address, nonce: nonce - back });
    if ((await provider.getCode(prev)) === '0x') continue;
    try {
      const prevCt = new ethers.Contract(prev, probeAbi, provider);
      const [prevManager, prevOperator] = await Promise.all([prevCt.MANAGER(), prevCt.OPERATOR()]);
      if (prevManager.toLowerCase() === MANAGER.toLowerCase()) {
        throw new Error(
          `a forwarder already exists at ${prev} (nonce ${nonce - back}, OPERATOR ${prevOperator}); refusing to deploy another`
        );
      }
    } catch (probeError) {
      if (/^a forwarder already exists/.test(probeError.message)) throw probeError;
      // not one of ours; ignore
    }
  }

  if (!send) {
    console.log('Dry run only. Re-run with --send to broadcast.');
    return;
  }

  console.log('broadcasting...');
  // ethers v6: deploy() resolves to the contract, not to the transaction.
  const deployed = await factory.deploy(OPERATOR, {
    gasLimit: gas,
    maxFeePerGas: gasPrice,
    maxPriorityFeePerGas: 0n,
  });
  const tx = deployed.deploymentTransaction();
  if (!tx) throw new Error('deploy produced no transaction');
  console.log(`sent   ${tx.hash}`);
  const receipt = await tx.wait();
  if (!receipt || receipt.status !== 1) throw new Error(`deploy failed: status ${receipt && receipt.status}`);
  console.log(`mined  block ${receipt.blockNumber}  gasUsed ${receipt.gasUsed}`);

  await deployed.waitForDeployment();
  const address = await deployed.getAddress();
  const code = await provider.getCode(address);
  const ct = new ethers.Contract(
    address,
    ['function OPERATOR() view returns (address)', 'function MANAGER() view returns (address)'],
    provider
  );
  const operator = await ct.OPERATOR();
  const manager = await ct.MANAGER();

  console.log(`\naddress        ${address}`);
  console.log(`code bytes     ${(code.length - 2) / 2}`);
  console.log(`OPERATOR()     ${operator}  ${operator.toLowerCase() === OPERATOR.toLowerCase() ? 'OK' : 'MISMATCH'}`);
  console.log(`MANAGER()      ${manager}`);

  if (address.toLowerCase() !== predicted.toLowerCase()) {
    console.log('\nWARNING: deployed address differs from the prediction; record the address above.');
  }
  if (operator.toLowerCase() !== OPERATOR.toLowerCase()) {
    throw new Error('OPERATOR does not match the intended successor; do not use this forwarder');
  }
}

main().catch((error) => {
  console.error(`ERROR: ${error.message}`);
  process.exit(1);
});
