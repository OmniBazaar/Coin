/**
 * MinimalEscrow.sol — First-sale bonus wiring (Task #22)
 *
 * Verifies the contract-to-contract bridge added in {MinimalEscrow._recordFirstSale}:
 *   - an undisputed `releaseFunds` records the seller's first sale on the
 *     registry with the gross amount + buyer/seller addresses,
 *   - a recorder revert (non-qualifying / anti-Sybil sale) does NOT roll back
 *     the settlement — the seller is still paid,
 *   - once a seller has a first sale on record, the escrow skips the call,
 *   - `releaseFundsViaContract` records the sale on the same path.
 */
const { expect } = require('chai');
const { ethers } = require('hardhat');

describe('MinimalEscrow — first-sale bonus wiring (Task #22)', function () {
  let escrow: any;
  let token: any;
  let pToken: any;
  let registry: any;
  let owner: any;
  let buyer: any;
  let seller: any;

  const MARKETPLACE_FEE_BPS = 100n; // 1%
  const BASIS_POINTS = 10000n;
  const ESCROW_AMOUNT = ethers.parseEther('1000'); // 1000 XOM
  const FEE = (ESCROW_AMOUNT * MARKETPLACE_FEE_BPS) / BASIS_POINTS;
  const SELLER_NET = ESCROW_AMOUNT - FEE;

  async function deployFixture() {
    [owner, buyer, seller] = await ethers.getSigners();

    const MockERC20 = await ethers.getContractFactory('MockERC20');
    token = await MockERC20.deploy('OmniCoin', 'XOM');
    pToken = await MockERC20.deploy('PrivateOmniCoin', 'pXOM');

    const Registry = await ethers.getContractFactory('MockFirstSaleRegistry');
    registry = await Registry.deploy();

    const Escrow = await ethers.getContractFactory('MinimalEscrow');
    escrow = await Escrow.deploy(
      await token.getAddress(),
      await pToken.getAddress(),
      await registry.getAddress(), // registry = first-sale recorder
      owner.address, // fee vault
      MARKETPLACE_FEE_BPS,
      ethers.ZeroAddress // trustedForwarder
    );

    const supply = ethers.parseEther('100000000');
    await token.mint(buyer.address, supply);
    await token
      .connect(buyer)
      .approve(await escrow.getAddress(), ethers.MaxUint256);
  }

  async function createEscrow(): Promise<bigint> {
    const tx = await escrow
      .connect(buyer)
      .createEscrow(seller.address, ESCROW_AMOUNT, 7 * 86400);
    const receipt = await tx.wait();
    const ev = receipt.logs.find((l: any) => {
      try {
        return escrow.interface.parseLog(l)?.name === 'EscrowCreated';
      } catch {
        return false;
      }
    });
    return escrow.interface.parseLog(ev).args.escrowId;
  }

  beforeEach(async function () {
    await deployFixture();
  });

  it('records the seller first sale on releaseFunds with gross amount + parties', async function () {
    const id = await createEscrow();
    await escrow.connect(buyer).releaseFunds(id);

    expect(await registry.callCount()).to.equal(1n);
    expect(await registry.lastSeller()).to.equal(seller.address);
    expect(await registry.lastAmount()).to.equal(ESCROW_AMOUNT);
    expect(await registry.lastBuyer()).to.equal(buyer.address);
    expect(await registry.completed(seller.address)).to.equal(true);
    // Seller was actually paid (net of fee).
    expect(await token.balanceOf(seller.address)).to.equal(SELLER_NET);
  });

  it('does NOT roll back settlement when the recorder reverts', async function () {
    await registry.setShouldRevert(true);
    const id = await createEscrow();

    // Settlement must succeed even though markFirstSaleCompleted reverts.
    await expect(escrow.connect(buyer).releaseFunds(id)).to.not.be.reverted;

    expect(await registry.callCount()).to.equal(0n);
    expect(await token.balanceOf(seller.address)).to.equal(SELLER_NET);
    const e = await escrow.getEscrow(id);
    expect(e.resolved).to.equal(true);
  });

  it('skips the recorder once the seller already has a first sale', async function () {
    await registry.setCompleted(seller.address);
    const id = await createEscrow();
    await escrow.connect(buyer).releaseFunds(id);

    // hasCompletedFirstSale short-circuits the bridge.
    expect(await registry.callCount()).to.equal(0n);
    expect(await token.balanceOf(seller.address)).to.equal(SELLER_NET);
  });

  it('records the sale on the releaseFundsViaContract path', async function () {
    const id = await createEscrow();
    // Chain time (not wall clock) so the deadline survives prior time travel.
    const latestBlock = await ethers.provider.getBlock('latest');
    const deadline = Number(latestBlock.timestamp) + 3600;

    // Buyer signs the ReleaseFundsBySig payload authorizing `owner` (acting as
    // the caller contract for this test) to release.
    const domain = {
      name: 'OmniBazaar MinimalEscrow',
      version: '2', // V2 redeploy bumped the EIP-712 domain version
      chainId: (await ethers.provider.getNetwork()).chainId,
      verifyingContract: await escrow.getAddress(),
    };
    const types = {
      ReleaseFundsBySig: [
        { name: 'escrowId', type: 'uint256' },
        { name: 'callerContract', type: 'address' },
        { name: 'deadline', type: 'uint256' },
      ],
    };
    const sig = await buyer.signTypedData(domain, types, {
      escrowId: id,
      callerContract: owner.address,
      deadline,
    });

    await escrow
      .connect(owner)
      .releaseFundsViaContract(id, owner.address, deadline, sig);

    expect(await registry.callCount()).to.equal(1n);
    expect(await registry.lastSeller()).to.equal(seller.address);
    expect(await registry.lastAmount()).to.equal(ESCROW_AMOUNT);
    expect(await token.balanceOf(seller.address)).to.equal(SELLER_NET);
  });
});
