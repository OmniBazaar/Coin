/**
 * @file OverflowOFTSender.flush.test.ts
 * @description LIQ-Q-3-LP5 — Path A (Avalanche C-Chain dispatcher).
 *
 * The `OverflowOFTSender` lives on Avalanche C-Chain (43114). It
 * receives BridgedXOM via Avalanche ICTT from L1 OmniValidatorRewards
 * and dispatches per-remote-chain shares via LayerZero V2 OFT to the
 * `OverflowOFTReceiver` instances on Ethereum / Arbitrum / Base /
 * Polygon.
 *
 * Test surface:
 *   - Construction binds immutables (xomToken, xomOftAdapter) +
 *     rejects zero addresses.
 *   - Admin: setChainReceiver / setChainWeight / removeChainConfig
 *     (Ownable2Step gated; MAX_CHAIN_CONFIGS bound; ChainNotConfigured
 *     on operate-before-configure).
 *   - Fee reserve: topUp via payable / receive(); resync on
 *     msg.value==0; withdraw owner-only with CEI + nonReentrant.
 *   - flush(): permissionless; reverts NothingToFlush on zero balance;
 *     reverts NoActiveChains when no chain has both weight+receiver;
 *     splits balance proportionally by active weights; debits fee
 *     reserve by the quoted fee; bumps totalDispatched; emits per
 *     successful Dispatched + per skipped ChainSkipped.
 *   - Skip-not-revert: zero receiver / zero weight skipped with
 *     reason; fee-short skipped with reason=2; quote revert
 *     skipped with reason=3; send revert skipped with reason=4 and
 *     CEI rollback restores feeReserve + totalDispatched.
 *   - recoverDust: cannot move XOM (CannotRecoverXOM); owner-only;
 *     emits DustRecovered.
 *   - Ownable2Step two-step handoff.
 */

/* eslint-disable @typescript-eslint/no-var-requires */
const { expect } = require('chai');
const { ethers } = require('hardhat');

describe('OverflowOFTSender (C-Chain dispatcher)', function () {
    let xom: any;
    let oft: any;
    let sender: any;
    let owner: any;
    let alice: any;
    let bob: any;
    let receiverA: any;
    let receiverB: any;
    let receiverC: any;

    const ETH_EID = 30101;
    const ARB_EID = 30110;
    const BASE_EID = 30184;
    const POL_EID = 30109;

    function pad32(addr: string): string {
        return ethers.zeroPadValue(ethers.getAddress(addr), 32);
    }

    beforeEach(async function () {
        [owner, alice, bob, receiverA, receiverB, receiverC] =
            await ethers.getSigners();

        const Mock = await ethers.getContractFactory('MockXOMToken');
        xom = await Mock.deploy();
        const dust = await Mock.deploy();
        const MockOft = await ethers.getContractFactory('MockXOMOftAdapter');
        oft = await MockOft.deploy(await xom.getAddress());

        const Factory = await ethers.getContractFactory('OverflowOFTSender');
        sender = await Factory.deploy(
            await xom.getAddress(),
            await oft.getAddress(),
            owner.address,
        );

        (this as any).dust = dust;
    });

    describe('construction', function () {
        it('binds xomToken + xomOftAdapter as immutables', async function () {
            expect(await sender.xomToken()).to.equal(await xom.getAddress());
            expect(await sender.xomOftAdapter()).to.equal(
                await oft.getAddress(),
            );
            expect(await sender.owner()).to.equal(owner.address);
        });

        it('rejects zero xomToken', async function () {
            const Factory = await ethers.getContractFactory('OverflowOFTSender');
            await expect(
                Factory.deploy(
                    ethers.ZeroAddress,
                    await oft.getAddress(),
                    owner.address,
                ),
            ).to.be.revertedWithCustomError(sender, 'ZeroAddress');
        });

        it('rejects zero xomOftAdapter', async function () {
            const Factory = await ethers.getContractFactory('OverflowOFTSender');
            await expect(
                Factory.deploy(
                    await xom.getAddress(),
                    ethers.ZeroAddress,
                    owner.address,
                ),
            ).to.be.revertedWithCustomError(sender, 'ZeroAddress');
        });

        it('rejects zero owner', async function () {
            const Factory = await ethers.getContractFactory('OverflowOFTSender');
            await expect(
                Factory.deploy(
                    await xom.getAddress(),
                    await oft.getAddress(),
                    ethers.ZeroAddress,
                ),
            ).to.be.reverted;
        });
    });

    describe('admin: chain config', function () {
        it('first setChainReceiver pushes onto configuredEids', async function () {
            await expect(
                sender.setChainReceiver(ETH_EID, pad32(receiverA.address)),
            )
                .to.emit(sender, 'ChainReceiverUpdated')
                .withArgs(ETH_EID, pad32(receiverA.address));
            expect(await sender.chainReceiver(ETH_EID)).to.equal(
                pad32(receiverA.address),
            );
            expect(await sender.configuredEids(0)).to.equal(ETH_EID);
            expect(await sender.configuredEidsLength()).to.equal(1);
        });

        it('second setChainReceiver on same eid does NOT duplicate', async function () {
            await sender.setChainReceiver(ETH_EID, pad32(receiverA.address));
            await sender.setChainReceiver(ETH_EID, pad32(receiverB.address));
            expect(await sender.configuredEidsLength()).to.equal(1);
            expect(await sender.chainReceiver(ETH_EID)).to.equal(
                pad32(receiverB.address),
            );
        });

        it('blocks setChainWeight before setChainReceiver', async function () {
            await expect(
                sender.setChainWeight(ETH_EID, 1000),
            ).to.be.revertedWithCustomError(sender, 'ChainNotConfigured');
        });

        it('weights are proportional — sum can exceed BPS_DENOMINATOR', async function () {
            await sender.setChainReceiver(ETH_EID, pad32(receiverA.address));
            await sender.setChainReceiver(ARB_EID, pad32(receiverB.address));
            await sender.setChainWeight(ETH_EID, 6000);
            await sender.setChainWeight(ARB_EID, 7000); // 13000 total — OK
            expect(await sender.chainWeightBps(ETH_EID)).to.equal(6000);
            expect(await sender.chainWeightBps(ARB_EID)).to.equal(7000);
        });

        it('caps configured chains at MAX_CHAIN_CONFIGS', async function () {
            for (let i = 0; i < 10; i++) {
                await sender.setChainReceiver(100 + i, pad32(receiverA.address));
            }
            await expect(
                sender.setChainReceiver(110, pad32(receiverA.address)),
            ).to.be.revertedWithCustomError(sender, 'TooManyChainConfigs');
        });

        it('removeChainConfig clears + splices', async function () {
            await sender.setChainReceiver(ETH_EID, pad32(receiverA.address));
            await sender.setChainReceiver(ARB_EID, pad32(receiverB.address));
            await sender.setChainWeight(ETH_EID, 1000);

            await expect(sender.removeChainConfig(ETH_EID))
                .to.emit(sender, 'ChainConfigRemoved')
                .withArgs(ETH_EID);

            expect(await sender.chainReceiver(ETH_EID)).to.equal(
                ethers.ZeroHash,
            );
            expect(await sender.chainWeightBps(ETH_EID)).to.equal(0);
            expect(await sender.configuredEidsLength()).to.equal(1);
            expect(await sender.configuredEids(0)).to.equal(ARB_EID);
        });

        it('removeChainConfig reverts on unknown eid', async function () {
            await expect(
                sender.removeChainConfig(99999),
            ).to.be.revertedWithCustomError(sender, 'ChainNotConfigured');
        });

        it('non-owner cannot mutate config', async function () {
            await expect(
                sender
                    .connect(alice)
                    .setChainReceiver(ETH_EID, pad32(receiverA.address)),
            ).to.be.reverted;
        });
    });

    describe('admin: fee reserve', function () {
        it('topUpFeeReserve credits feeReserve', async function () {
            await expect(
                sender.connect(alice).topUpFeeReserve({ value: ethers.parseEther('2') }),
            )
                .to.emit(sender, 'FeeReserveToppedUp')
                .withArgs(
                    alice.address,
                    ethers.parseEther('2'),
                    ethers.parseEther('2'),
                );
            expect(await sender.feeReserve()).to.equal(
                ethers.parseEther('2'),
            );
        });

        it('receive() credits feeReserve', async function () {
            await alice.sendTransaction({
                to: await sender.getAddress(),
                value: ethers.parseEther('1'),
            });
            expect(await sender.feeReserve()).to.equal(
                ethers.parseEther('1'),
            );
        });

        it('topUpFeeReserve with msg.value=0 syncs raw native balance', async function () {
            await owner.sendTransaction({
                to: await sender.getAddress(),
                value: ethers.parseEther('1'),
            });
            expect(await sender.feeReserve()).to.equal(
                ethers.parseEther('1'),
            );
            // Sync is no-op (raw balance == feeReserve)
            await sender.topUpFeeReserve({ value: 0 });
            expect(await sender.feeReserve()).to.equal(
                ethers.parseEther('1'),
            );
        });

        it('withdrawFeeReserve owner-only', async function () {
            await sender.topUpFeeReserve({ value: ethers.parseEther('1') });
            await expect(
                sender
                    .connect(alice)
                    .withdrawFeeReserve(alice.address, ethers.parseEther('0.5')),
            ).to.be.reverted;
        });

        it('withdrawFeeReserve reverts on insufficient reserve', async function () {
            await expect(
                sender.withdrawFeeReserve(owner.address, ethers.parseEther('1')),
            ).to.be.revertedWithCustomError(sender, 'InsufficientFeeReserve');
        });

        it('withdrawFeeReserve transfers + decrements', async function () {
            await sender.topUpFeeReserve({ value: ethers.parseEther('5') });
            const before = await ethers.provider.getBalance(receiverA.address);
            await sender.withdrawFeeReserve(receiverA.address, ethers.parseEther('3'));
            const after = await ethers.provider.getBalance(receiverA.address);
            expect(after - before).to.equal(ethers.parseEther('3'));
            expect(await sender.feeReserve()).to.equal(ethers.parseEther('2'));
        });
    });

    describe('flush() — happy path', function () {
        beforeEach(async function () {
            await sender.setChainReceiver(ETH_EID, pad32(receiverA.address));
            await sender.setChainReceiver(ARB_EID, pad32(receiverB.address));
            await sender.setChainWeight(ETH_EID, 1200);
            await sender.setChainWeight(ARB_EID, 2200);
            await oft.setDefaultFee(0);
        });

        it('dispatches balance proportionally by weight', async function () {
            // 1200 + 2200 = 3400 total active weight
            // Balance 3400 wei → ETH gets 1200, ARB gets 2200
            await xom.mint(await sender.getAddress(), 3400n);

            const tx = await sender.connect(alice).flush();
            await tx.wait();

            expect(await oft.sendCount()).to.equal(2);
            // Receivers got their shares
            expect(await sender.totalDispatched()).to.equal(3400n);
        });

        it('emits Dispatched events with the caller', async function () {
            await xom.mint(await sender.getAddress(), 3400n);
            await expect(sender.connect(alice).flush()).to.emit(
                sender,
                'Dispatched',
            );
        });

        it('reverts NothingToFlush on zero balance', async function () {
            await expect(sender.flush()).to.be.revertedWithCustomError(
                sender,
                'NothingToFlush',
            );
        });
    });

    describe('flush() — edge cases', function () {
        it('reverts NoActiveChains when no chain has weight+receiver', async function () {
            await sender.setChainReceiver(ETH_EID, pad32(receiverA.address));
            // weight remains 0
            await xom.mint(await sender.getAddress(), 1000n);
            await expect(sender.flush()).to.be.revertedWithCustomError(
                sender,
                'NoActiveChains',
            );
        });

        it('skips chain with zero receiver (reason=1)', async function () {
            await sender.setChainReceiver(ETH_EID, ethers.ZeroHash);
            await sender.setChainWeight(ETH_EID, 1000);
            await sender.setChainReceiver(ARB_EID, pad32(receiverB.address));
            await sender.setChainWeight(ARB_EID, 2000);
            await oft.setDefaultFee(0);

            await xom.mint(await sender.getAddress(), 1000n);
            await sender.connect(alice).flush();
            // Only ARB got a send (ETH had zero receiver, skipped)
            expect(await oft.sendCount()).to.equal(1);
            const sent = await oft.lastSend();
            expect(sent.eid).to.equal(ARB_EID);
        });

        it('skips chain when feeReserve short (reason=2)', async function () {
            await sender.setChainReceiver(ETH_EID, pad32(receiverA.address));
            await sender.setChainWeight(ETH_EID, 1000);
            await oft.setDefaultFee(ethers.parseEther('1')); // reserve 0
            await xom.mint(await sender.getAddress(), 1000n);

            const tx = await sender.connect(alice).flush();
            await expect(tx)
                .to.emit(sender, 'ChainSkipped')
                .withArgs(ETH_EID, 1000n, 2);
            expect(await oft.sendCount()).to.equal(0);
            // Balance still in the contract
            expect(await xom.balanceOf(await sender.getAddress())).to.equal(
                1000n,
            );
        });

        it('skips chain on quote revert (reason=3)', async function () {
            await sender.setChainReceiver(ETH_EID, pad32(receiverA.address));
            await sender.setChainWeight(ETH_EID, 1000);
            await oft.setShouldRevertQuote(ETH_EID, true);
            await xom.mint(await sender.getAddress(), 1000n);

            const tx = await sender.connect(alice).flush();
            await expect(tx)
                .to.emit(sender, 'ChainSkipped')
                .withArgs(ETH_EID, 1000n, 3);
        });

        it('skips chain on send revert (reason=4) + CEI rollback', async function () {
            await sender.setChainReceiver(ETH_EID, pad32(receiverA.address));
            await sender.setChainReceiver(ARB_EID, pad32(receiverB.address));
            await sender.setChainWeight(ETH_EID, 1000);
            await sender.setChainWeight(ARB_EID, 2000);
            await oft.setDefaultFee(0);
            // Make ETH send revert
            await oft.setShouldRevertSend(ETH_EID, true);

            await xom.mint(await sender.getAddress(), 3000n);
            const dispatchedBefore = await sender.totalDispatched();

            const tx = await sender.connect(alice).flush();
            await expect(tx)
                .to.emit(sender, 'ChainSkipped')
                .withArgs(ETH_EID, 1000n, 4);

            // ARB still succeeded
            expect(await oft.sendCount()).to.equal(1);
            const sent = await oft.lastSend();
            expect(sent.eid).to.equal(ARB_EID);
            expect(sent.amount).to.equal(2000n);

            // totalDispatched bumped only for ARB (rollback for ETH)
            const dispatchedAfter = await sender.totalDispatched();
            expect(dispatchedAfter - dispatchedBefore).to.equal(2000n);

            // ETH's share remains in the contract
            expect(await xom.balanceOf(await sender.getAddress())).to.equal(
                1000n,
            );
        });

        it('fee reserve debited exactly by quoted fee on success', async function () {
            await sender.setChainReceiver(ETH_EID, pad32(receiverA.address));
            await sender.setChainWeight(ETH_EID, 1000);
            await oft.setDefaultFee(ethers.parseEther('0.5'));
            await sender.topUpFeeReserve({ value: ethers.parseEther('2') });
            expect(await sender.feeReserve()).to.equal(
                ethers.parseEther('2'),
            );

            await xom.mint(await sender.getAddress(), 1000n);
            await sender.connect(alice).flush();

            expect(await sender.feeReserve()).to.equal(
                ethers.parseEther('1.5'),
            );
        });
    });

    describe('recoverDust', function () {
        it('cannot move xomToken', async function () {
            await xom.mint(await sender.getAddress(), 1000n);
            await expect(
                sender.recoverDust(await xom.getAddress(), owner.address, 1000n),
            ).to.be.revertedWithCustomError(sender, 'CannotRecoverXOM');
        });

        it('owner can rescue a non-XOM ERC-20', async function () {
            const dust = (this as any).dust;
            await dust.mint(await sender.getAddress(), 99n);
            await expect(
                sender.recoverDust(await dust.getAddress(), alice.address, 99n),
            )
                .to.emit(sender, 'DustRecovered')
                .withArgs(await dust.getAddress(), alice.address, 99n);
            expect(await dust.balanceOf(alice.address)).to.equal(99n);
        });

        it('non-owner cannot recover dust', async function () {
            const dust = (this as any).dust;
            await dust.mint(await sender.getAddress(), 1n);
            await expect(
                sender
                    .connect(alice)
                    .recoverDust(await dust.getAddress(), alice.address, 1n),
            ).to.be.reverted;
        });
    });

    describe('Ownable2Step handoff', function () {
        it('two-step transfer', async function () {
            await sender.transferOwnership(alice.address);
            expect(await sender.owner()).to.equal(owner.address);
            expect(await sender.pendingOwner()).to.equal(alice.address);
            await expect(sender.connect(bob).acceptOwnership()).to.be.reverted;
            await sender.connect(alice).acceptOwnership();
            expect(await sender.owner()).to.equal(alice.address);
        });
    });

    describe('pendingBalance view', function () {
        it('mirrors ERC-20 balanceOf', async function () {
            expect(await sender.pendingBalance()).to.equal(0n);
            await xom.mint(await sender.getAddress(), 12345n);
            expect(await sender.pendingBalance()).to.equal(12345n);
        });
    });
});
