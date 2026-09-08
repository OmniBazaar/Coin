/**
 * @file OverflowOFTReceiver.flush.test.ts
 * @description LIQ-Q-3-LP5. Trustless properties of the per-remote
 * `OverflowOFTReceiver`. The OFT mints XOM to this contract; any
 * caller's `flush()` MUST forward the entire balance to the
 * immutable `localPool` and ONLY to that address.
 *
 * Test surface:
 *   - Immutables are bound at deployment + reject zero addresses.
 *   - `pendingBalance()` mirrors the ERC-20 `balanceOf`.
 *   - `flush()` forwards 100% of balance to `localPool.distributeOverflow`.
 *   - `flush()` reverts cleanly on zero balance with `NothingToFlush`.
 *   - `flush()` rolls back the allowance on `localPool` revert and
 *     surfaces `PoolRejected(reason)`.
 *   - Any caller can `flush()` — there's no role gate.
 *   - `recoverDust(xomToken, …)` reverts with `CannotRecoverXOM`,
 *     enforcing the strict-locked-to-flush guarantee for XOM.
 *   - `recoverDust(non-XOM, …)` succeeds and only when owner.
 *   - `Ownable2Step` two-step handoff works.
 */

/* eslint-disable @typescript-eslint/no-var-requires */
const { expect } = require('chai');
const { ethers } = require('hardhat');

describe('OverflowOFTReceiver', function () {
    let xom: any;
    let pool: any;
    let receiver: any;
    let owner: any;
    let alice: any;
    let bob: any;
    let other: any;

    const SRC_EID = 30362;

    beforeEach(async function () {
        [owner, alice, bob, other] = await ethers.getSigners();

        const Mock = await ethers.getContractFactory('MockXOMToken');
        xom = await Mock.deploy();
        const dust = await Mock.deploy(); // a non-XOM ERC-20

        const Pool = await ethers.getContractFactory('MockLiquidityOverflowPool');
        pool = await Pool.deploy(await xom.getAddress());

        const Factory = await ethers.getContractFactory('OverflowOFTReceiver');
        receiver = await Factory.deploy(
            await xom.getAddress(),
            await pool.getAddress(),
            SRC_EID,
            owner.address,
        );
        await receiver.waitForDeployment();

        // Expose dust + use later
        (this as any).dust = dust;
    });

    describe('construction', function () {
        it('binds xomToken / localPool / srcEid as immutables', async function () {
            expect(await receiver.xomToken()).to.equal(await xom.getAddress());
            expect(await receiver.localPool()).to.equal(await pool.getAddress());
            expect(await receiver.srcEid()).to.equal(SRC_EID);
            expect(await receiver.owner()).to.equal(owner.address);
        });

        it('rejects zero xomToken', async function () {
            const Factory = await ethers.getContractFactory('OverflowOFTReceiver');
            await expect(
                Factory.deploy(
                    ethers.ZeroAddress,
                    await pool.getAddress(),
                    SRC_EID,
                    owner.address,
                ),
            ).to.be.revertedWithCustomError(receiver, 'ZeroAddress');
        });

        it('rejects zero localPool', async function () {
            const Factory = await ethers.getContractFactory('OverflowOFTReceiver');
            await expect(
                Factory.deploy(
                    await xom.getAddress(),
                    ethers.ZeroAddress,
                    SRC_EID,
                    owner.address,
                ),
            ).to.be.revertedWithCustomError(receiver, 'ZeroAddress');
        });

        it('rejects zero owner', async function () {
            const Factory = await ethers.getContractFactory('OverflowOFTReceiver');
            await expect(
                Factory.deploy(
                    await xom.getAddress(),
                    await pool.getAddress(),
                    SRC_EID,
                    ethers.ZeroAddress,
                ),
            ).to.be.reverted;
        });
    });

    describe('pendingBalance()', function () {
        it('mirrors ERC-20 balanceOf', async function () {
            expect(await receiver.pendingBalance()).to.equal(0n);
            await xom.mint(await receiver.getAddress(), ethers.parseEther('123'));
            expect(await receiver.pendingBalance()).to.equal(
                ethers.parseEther('123'),
            );
        });
    });

    describe('flush()', function () {
        it('forwards the full balance to localPool.distributeOverflow', async function () {
            const amount = ethers.parseEther('500');
            await xom.mint(await receiver.getAddress(), amount);

            const tx = await receiver.connect(alice).flush();
            await expect(tx)
                .to.emit(receiver, 'Flushed')
                .withArgs(alice.address, amount);

            // The mock pool pulls and records.
            expect(await pool.totalReceived()).to.equal(amount);
            expect(await xom.balanceOf(await receiver.getAddress())).to.equal(0n);
            expect(await xom.balanceOf(await pool.getAddress())).to.equal(amount);
        });

        it('is permissionless — any address can call', async function () {
            await xom.mint(await receiver.getAddress(), ethers.parseEther('1'));
            await expect(receiver.connect(other).flush()).to.not.be.reverted;
        });

        it('reverts with NothingToFlush on zero balance', async function () {
            await expect(receiver.connect(bob).flush()).to.be.revertedWithCustomError(
                receiver,
                'NothingToFlush',
            );
        });

        it('rolls back allowance + reverts on pool failure', async function () {
            await xom.mint(await receiver.getAddress(), ethers.parseEther('10'));
            // Configure the mock to revert on every distributeOverflow
            await pool.setShouldRevert(true);

            await expect(receiver.connect(alice).flush()).to.be.revertedWithCustomError(
                receiver,
                'PoolRejected',
            );

            // Allowance reset to 0
            expect(
                await xom.allowance(
                    await receiver.getAddress(),
                    await pool.getAddress(),
                ),
            ).to.equal(0n);
            // Balance still in the receiver (XOM never left)
            expect(await xom.balanceOf(await receiver.getAddress())).to.equal(
                ethers.parseEther('10'),
            );
        });
    });

    describe('recoverDust', function () {
        it('cannot move xomToken', async function () {
            await xom.mint(await receiver.getAddress(), ethers.parseEther('1'));
            await expect(
                receiver
                    .connect(owner)
                    .recoverDust(await xom.getAddress(), owner.address, ethers.parseEther('1')),
            ).to.be.revertedWithCustomError(receiver, 'CannotRecoverXOM');
        });

        it('owner can rescue a non-XOM ERC-20', async function () {
            const dust = (this as any).dust;
            await dust.mint(await receiver.getAddress(), ethers.parseEther('99'));
            await expect(
                receiver
                    .connect(owner)
                    .recoverDust(
                        await dust.getAddress(),
                        alice.address,
                        ethers.parseEther('99'),
                    ),
            )
                .to.emit(receiver, 'DustRecovered')
                .withArgs(
                    await dust.getAddress(),
                    alice.address,
                    ethers.parseEther('99'),
                );
            expect(await dust.balanceOf(alice.address)).to.equal(
                ethers.parseEther('99'),
            );
        });

        it('non-owner cannot recover dust', async function () {
            const dust = (this as any).dust;
            await dust.mint(await receiver.getAddress(), ethers.parseEther('1'));
            await expect(
                receiver
                    .connect(alice)
                    .recoverDust(
                        await dust.getAddress(),
                        alice.address,
                        ethers.parseEther('1'),
                    ),
            ).to.be.reverted;
        });

        it('rejects zero token / to', async function () {
            const dust = (this as any).dust;
            await expect(
                receiver
                    .connect(owner)
                    .recoverDust(ethers.ZeroAddress, alice.address, 1n),
            ).to.be.revertedWithCustomError(receiver, 'ZeroAddress');
            await expect(
                receiver
                    .connect(owner)
                    .recoverDust(await dust.getAddress(), ethers.ZeroAddress, 1n),
            ).to.be.revertedWithCustomError(receiver, 'ZeroAddress');
        });
    });

    describe('Ownable2Step handoff', function () {
        it('requires accept', async function () {
            await receiver.connect(owner).transferOwnership(alice.address);
            // pending, not yet effective
            expect(await receiver.owner()).to.equal(owner.address);
            expect(await receiver.pendingOwner()).to.equal(alice.address);

            // wrong acceptor reverts
            await expect(receiver.connect(bob).acceptOwnership()).to.be.reverted;

            await receiver.connect(alice).acceptOwnership();
            expect(await receiver.owner()).to.equal(alice.address);
        });
    });
});
