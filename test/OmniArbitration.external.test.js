/**
 * OmniArbitration — cross-chain (external escrow) disputes, 2026-10-20.
 *
 * Founder decision 3: the panel, the stakes and the seat bonds stay on
 * OmniCoin L1; an escrow on another chain is judged here and settled there by
 * two seated judges' EIP-712 signatures. These tests pin:
 *
 * 1. an external dispute is recorded with a domain separator DERIVED from
 *    (chainId, escrow) — never supplied by the disputer;
 * 2. this chain's own id, a duplicate external escrow, and a non-party opener
 *    are refused;
 * 3. resolving it emits the exact digest a destination EscrowV2 recomputes;
 * 4. cancelling an unseatable external dispute refunds the fee without trying
 *    to unfreeze an escrow that is not on this chain.
 */

const { expect } = require('chai');
const { ethers, upgrades } = require('hardhat');

describe('OmniArbitration — external (cross-chain) disputes', function () {
  let arbitration;
  let xom;
  let feeVault;
  let judges;
  let buyer;
  let seller;
  let outsider;

  const STAKE = ethers.parseEther('10000');
  const DEST_CHAIN = 43114n; // Avalanche C-Chain
  const DEST_ESCROW = ethers.getAddress('0x00000000000000000000000000000000000e5c40');
  const ESCROW_ID = 7n;
  const AMOUNT = ethers.parseEther('1000');
  const DISPUTE_FEE = AMOUNT / 20n; // 5%
  const RELEASE = 1;

  const domain = {
    name: 'OmniBazaar EscrowV2',
    version: '3',
    chainId: DEST_CHAIN,
    verifyingContract: DEST_ESCROW
  };
  const verdictTypes = {
    Verdict: [
      { name: 'escrowId', type: 'uint256' },
      { name: 'releaseFunds', type: 'bool' },
      { name: 'validUntil', type: 'uint256' }
    ]
  };

  async function register(signer) {
    await arbitration.setFounderArbitrator(signer.address, true);
    await xom.mint(signer.address, ethers.parseEther('100000'));
    await xom.connect(signer).approve(await arbitration.getAddress(), ethers.MaxUint256);
    await arbitration.connect(signer).registerArbitrator(STAKE);
  }

  async function openExternal() {
    await arbitration
      .connect(buyer)
      .createExternalDispute(
        DEST_CHAIN,
        DEST_ESCROW,
        ESCROW_ID,
        buyer.address,
        seller.address,
        AMOUNT
      );
    const disputeId = (await arbitration.nextDisputeId()) - 1n;
    await ethers.provider.send('evm_mine', []);
    await ethers.provider.send('evm_mine', []);
    await arbitration.connect(buyer).finalizeArbitratorSelection(disputeId);
    const d = await arbitration.getDispute(disputeId);
    return { disputeId, panel: d.arbitrators };
  }

  beforeEach(async function () {
    const signers = await ethers.getSigners();
    feeVault = signers[1];
    judges = signers.slice(2, 10);
    buyer = signers[10];
    seller = signers[11];
    outsider = signers[12];

    const MockERC20 = await ethers.getContractFactory('MockERC20');
    xom = await MockERC20.deploy('OmniCoin', 'XOM');

    const MockParticipation = await ethers.getContractFactory('MockArbitrationParticipation');
    const participation = await MockParticipation.deploy();
    const MockEscrow = await ethers.getContractFactory('MockArbitrationEscrow');
    const mockEscrow = await MockEscrow.deploy();

    const OmniArbitration = await ethers.getContractFactory('OmniArbitration');
    arbitration = await upgrades.deployProxy(
      OmniArbitration,
      [
        await participation.getAddress(),
        await mockEscrow.getAddress(),
        await xom.getAddress(),
        feeVault.address
      ],
      { initializer: 'initialize', kind: 'uups', constructorArgs: [ethers.ZeroAddress] }
    );

    for (const who of [buyer, seller]) {
      await xom.mint(who.address, ethers.parseEther('100000'));
      await xom.connect(who).approve(await arbitration.getAddress(), ethers.MaxUint256);
    }
    for (const judge of judges) await register(judge);
  });

  it('records the dispute and derives the escrow domain separator itself', async function () {
    await arbitration
      .connect(buyer)
      .createExternalDispute(
        DEST_CHAIN,
        DEST_ESCROW,
        ESCROW_ID,
        buyer.address,
        seller.address,
        AMOUNT
      );
    const disputeId = (await arbitration.nextDisputeId()) - 1n;
    const ext = await arbitration.externalDispute(disputeId);

    expect(ext.chainId).to.equal(DEST_CHAIN);
    expect(ext.escrowContract).to.equal(DEST_ESCROW);
    expect(ext.domainSeparator).to.equal(
      ethers.TypedDataEncoder.hashDomain(domain)
    );

    const d = await arbitration.getDispute(disputeId);
    expect(d[0]).to.equal(ESCROW_ID);
    expect(d[1]).to.equal(buyer.address);
    expect(d[2]).to.equal(seller.address);
    expect(d[7]).to.equal(4n); // PendingSelection

    const stored = await arbitration.disputes(disputeId);
    expect(stored.disputedAmount ?? stored[8]).to.equal(AMOUNT);
    expect(stored.disputeFee ?? stored[13]).to.equal(DISPUTE_FEE);
  });

  it('refuses this chain, a duplicate target and a non-party opener', async function () {
    const chainId = (await ethers.provider.getNetwork()).chainId;
    await expect(
      arbitration
        .connect(buyer)
        .createExternalDispute(chainId, DEST_ESCROW, 1, buyer.address, seller.address, AMOUNT)
    ).to.be.revertedWithCustomError(arbitration, 'ExternalChainInvalid');

    await expect(
      arbitration
        .connect(outsider)
        .createExternalDispute(DEST_CHAIN, DEST_ESCROW, 1, buyer.address, seller.address, AMOUNT)
    ).to.be.revertedWithCustomError(arbitration, 'NotEscrowParty');

    await arbitration
      .connect(buyer)
      .createExternalDispute(DEST_CHAIN, DEST_ESCROW, 1, buyer.address, seller.address, AMOUNT);
    await expect(
      arbitration
        .connect(seller)
        .createExternalDispute(DEST_CHAIN, DEST_ESCROW, 1, buyer.address, seller.address, AMOUNT)
    ).to.be.revertedWithCustomError(arbitration, 'ExternalEscrowAlreadyDisputed');
  });

  it('does not touch a local escrow and takes the fee up front', async function () {
    const before = await xom.balanceOf(buyer.address);
    await arbitration
      .connect(buyer)
      .createExternalDispute(DEST_CHAIN, DEST_ESCROW, ESCROW_ID, buyer.address, seller.address, AMOUNT);
    expect(await xom.balanceOf(buyer.address)).to.equal(before - DISPUTE_FEE);
  });

  it('emits the exact verdict digest the destination escrow recomputes', async function () {
    const { disputeId, panel } = await openExternal();
    const seated = judges.filter((j) => panel.includes(j.address));
    expect(seated.length).to.equal(3);

    for (const judge of seated) {
      await arbitration.connect(judge).postSeatBond(disputeId);
    }
    await arbitration.connect(seated[0]).castVote(disputeId, RELEASE);
    const tx = await arbitration.connect(seated[1]).castVote(disputeId, RELEASE);
    const receipt = await tx.wait();

    const iface = arbitration.interface;
    const log = receipt.logs
      .map((l) => {
        try {
          return iface.parseLog(l);
        } catch {
          return null;
        }
      })
      .find((l) => l && l.name === 'ExternalVerdict');
    expect(log, 'ExternalVerdict emitted').to.not.equal(undefined);

    const [eventDisputeId, chainId, escrow, escrowId, releaseFunds, digest, validUntil] =
      log.args;
    expect(eventDisputeId).to.equal(disputeId);
    expect(chainId).to.equal(DEST_CHAIN);
    expect(escrow).to.equal(DEST_ESCROW);
    expect(escrowId).to.equal(ESCROW_ID);
    expect(releaseFunds).to.equal(true);

    // Recompute the digest the way EscrowV2's EIP-712 domain does.
    const expected = ethers.TypedDataEncoder.hash(domain, verdictTypes, {
      escrowId: ESCROW_ID,
      releaseFunds: true,
      validUntil
    });
    expect(digest).to.equal(expected);

    // And the two seated judges' typed-data signatures recover to them, which
    // is exactly what the destination escrow's roster check accepts.
    for (const judge of [seated[0], seated[1]]) {
      const sig = await judge.signTypedData(domain, verdictTypes, {
        escrowId: ESCROW_ID,
        releaseFunds: true,
        validUntil
      });
      expect(ethers.recoverAddress(digest, sig)).to.equal(judge.address);
    }
  });

  it('cancels an unseatable external dispute and refunds the fee', async function () {
    await arbitration
      .connect(buyer)
      .createExternalDispute(DEST_CHAIN, DEST_ESCROW, ESCROW_ID, buyer.address, seller.address, AMOUNT);
    const disputeId = (await arbitration.nextDisputeId()) - 1n;

    const before = await xom.balanceOf(buyer.address);
    await arbitration.connect(buyer).cancelDispute(disputeId);
    expect(await xom.balanceOf(buyer.address)).to.equal(before + DISPUTE_FEE);

    // The key is released, so the same escrow can be disputed again.
    await arbitration
      .connect(seller)
      .createExternalDispute(DEST_CHAIN, DEST_ESCROW, ESCROW_ID, buyer.address, seller.address, AMOUNT);
  });
});
