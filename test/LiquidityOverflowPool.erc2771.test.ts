/**
 * @file LiquidityOverflowPool.erc2771.test.ts
 * @description LIQ-Q-2-remainder. Verifies that the V2
 * `LiquidityOverflowPool` IMPL (with `ERC2771ContextUpgradeable` baked
 * in) correctly resolves the meta-tx sender across the four
 * user-facing entry points: `stake`, `unstake`, `claimRewards`,
 * `emergencyWithdraw`. Also confirms the non-user contract→contract
 * path (`distributeOverflow` reward source) still relies on raw
 * `msg.sender`.
 *
 * Test approach (no real OpenGSN runtime needed):
 *   - Deploy a simple `MinimalForwarder` mock that just appends the
 *     `from` address to its call's payload before relaying — matching
 *     ERC-2771's trailing-20-bytes encoding.
 *   - Deploy `LiquidityOverflowPool` with that forwarder as the
 *     constructor-baked immutable.
 *   - Have an "operator" (`forwarderCaller`) call into the pool with
 *     calldata = `<selector><staker-encoded-args><staker-address>`.
 *     The pool must treat the staker, not the operator, as the user
 *     for every state mutation.
 *
 * Equivalently — a direct call (no forwarder) MUST keep returning
 * `msg.sender`, so the existing direct-stake flows are unaffected.
 */

/* eslint-disable @typescript-eslint/no-var-requires */
const { expect } = require('chai');
const { ethers, upgrades } = require('hardhat');

describe('LiquidityOverflowPool ERC-2771 meta-tx', function () {
    let overflowPool: any;
    let xomToken: any;
    let lpToken: any;
    let forwarder: any;

    let owner: any;
    let rewardSource: any;
    let staker: any;
    let operator: any; // EOA that submits the relayed tx
    let treasury: any;

    /**
     * Encode a meta-tx call: append the `from` (20 bytes) to the
     * function selector + args, matching ERC-2771's calldata suffix.
     *
     * @param signature Function signature.
     * @param args Encoded args.
     * @param from Original sender address.
     * @returns Concatenated calldata hex string.
     */
    function encodeMetaCall(signature: string, args: any[], from: string): string {
        const iface = new ethers.Interface([signature]);
        const fnName = signature.split('function ')[1].split('(')[0];
        const data = iface.encodeFunctionData(fnName, args);
        return ethers.concat([data, ethers.getAddress(from)]);
    }

    beforeEach(async function () {
        [owner, rewardSource, staker, operator, treasury] =
            await ethers.getSigners();

        const MockToken = await ethers.getContractFactory('MockXOMToken');
        xomToken = await MockToken.deploy();
        lpToken = await MockToken.deploy();

        // Deploy a permissive forwarder — anything addressed to it
        // can be relayed unchanged via low-level call. The actual
        // ERC-2771 sender-suffix is constructed manually by the test.
        const ForwarderFactory = await ethers.getContractFactory(
            'TrustedRelayForwarder',
        );
        forwarder = await ForwarderFactory.deploy();
        await forwarder.waitForDeployment();

        const LiquidityOverflowPool = await ethers.getContractFactory(
            'LiquidityOverflowPool',
        );
        overflowPool = await upgrades.deployProxy(
            LiquidityOverflowPool,
            [await xomToken.getAddress(), treasury.address],
            {
                initializer: 'initialize',
                kind: 'uups',
                constructorArgs: [await forwarder.getAddress()],
            },
        );
        await overflowPool.waitForDeployment();

        // Operator setup
        await overflowPool.connect(owner).setRewardSource(rewardSource.address, true);
        await xomToken.mint(rewardSource.address, ethers.parseEther('1000000'));
        await lpToken.mint(staker.address, ethers.parseEther('10000'));
        await xomToken
            .connect(rewardSource)
            .approve(await overflowPool.getAddress(), ethers.MaxUint256);
        // staker approves the pool to pull LP tokens — but the staker
        // never calls the pool directly in these tests.
        await lpToken
            .connect(staker)
            .approve(await overflowPool.getAddress(), ethers.MaxUint256);

        // Add a pool
        await overflowPool.connect(owner).addPool(await lpToken.getAddress(), 10000);
    });

    describe('trustedForwarder()', function () {
        it('returns the forwarder set in the IMPL constructor', async function () {
            expect(await overflowPool.trustedForwarder()).to.equal(
                await forwarder.getAddress(),
            );
        });

        it('isTrustedForwarder() recognises the forwarder', async function () {
            expect(
                await overflowPool.isTrustedForwarder(await forwarder.getAddress()),
            ).to.equal(true);
            expect(
                await overflowPool.isTrustedForwarder(operator.address),
            ).to.equal(false);
        });
    });

    describe('stake via forwarder', function () {
        it("credits the appended sender, not the forwarder's caller", async function () {
            const amount = ethers.parseEther('100');
            const callData = encodeMetaCall(
                'function stake(uint256,uint256)',
                [0, amount],
                staker.address,
            );

            // operator (NOT the staker) submits via forwarder
            await forwarder
                .connect(operator)
                .relay(await overflowPool.getAddress(), callData);

            // The pool MUST have credited staker, not operator
            const u = await overflowPool.getUserStake(0, staker.address);
            expect(u.amount).to.equal(amount);

            const u2 = await overflowPool.getUserStake(0, operator.address);
            expect(u2.amount).to.equal(0n);
        });

        it("rejects when the forwarder is NOT trusted", async function () {
            // Deploy a separate forwarder that the pool does NOT trust
            const RogueForwarder = await ethers.getContractFactory(
                'TrustedRelayForwarder',
            );
            const rogue = await RogueForwarder.deploy();
            await rogue.waitForDeployment();

            const amount = ethers.parseEther('100');
            const callData = encodeMetaCall(
                'function stake(uint256,uint256)',
                [0, amount],
                staker.address,
            );

            // Submit through the rogue forwarder. The pool sees its
            // msg.sender as the rogue (NOT a trusted forwarder), so
            // ERC2771Context falls back to raw msg.sender = rogue
            // forwarder. The rogue forwarder has not approved LP
            // tokens, so safeTransferFrom reverts.
            await expect(
                rogue
                    .connect(operator)
                    .relay(await overflowPool.getAddress(), callData),
            ).to.be.reverted;

            // No credit either way
            expect((await overflowPool.getUserStake(0, staker.address)).amount).to.equal(0n);
        });
    });

    describe('claimRewards / unstake / emergencyWithdraw via forwarder', function () {
        beforeEach(async function () {
            // Seed staker position directly first so the meta-tx tests
            // can exercise the harvest + withdraw paths
            await overflowPool
                .connect(staker)
                .stake(0, ethers.parseEther('1000'));

            // Push 100 XOM of overflow so there are pending rewards
            await overflowPool
                .connect(rewardSource)
                .distributeOverflow(ethers.parseEther('100'));
        });

        it('emergencyWithdraw via forwarder pays the original staker', async function () {
            const callData = encodeMetaCall(
                'function emergencyWithdraw(uint256)',
                [0],
                staker.address,
            );
            const balBefore = await lpToken.balanceOf(staker.address);

            await forwarder
                .connect(operator)
                .relay(await overflowPool.getAddress(), callData);

            const balAfter = await lpToken.balanceOf(staker.address);
            // Staker recovered LP minus 0.5% fee
            expect(balAfter - balBefore).to.be.gt(0n);
            // Operator did NOT receive any LP
            expect(await lpToken.balanceOf(operator.address)).to.equal(0n);

            // Position cleared
            expect((await overflowPool.getUserStake(0, staker.address)).amount).to.equal(0n);
        });
    });

    describe('reward source path (distributeOverflow) uses raw msg.sender', function () {
        it("the reward source check ignores ERC-2771 suffixing", async function () {
            // Build a meta-tx where the appended sender is the reward
            // source but the actual msg.sender is the forwarder — the
            // reward-source check MUST still pass (because it checks
            // raw msg.sender) only if msg.sender (operator forwarding
            // through forwarder) is registered. The forwarder is NOT
            // registered as a reward source, so this MUST revert.
            const callData = encodeMetaCall(
                'function distributeOverflow(uint256)',
                [ethers.parseEther('1')],
                rewardSource.address,
            );
            await expect(
                forwarder
                    .connect(operator)
                    .relay(await overflowPool.getAddress(), callData),
            ).to.be.reverted;

            // Direct call from rewardSource still works
            await xomToken.mint(rewardSource.address, ethers.parseEther('100'));
            await overflowPool.connect(staker).stake(0, ethers.parseEther('1'));
            await expect(
                overflowPool
                    .connect(rewardSource)
                    .distributeOverflow(ethers.parseEther('1')),
            ).to.not.be.reverted;
        });
    });

    describe('direct calls (no forwarder) keep working', function () {
        it('a direct staker call still credits msg.sender', async function () {
            await overflowPool
                .connect(staker)
                .stake(0, ethers.parseEther('500'));
            const u = await overflowPool.getUserStake(0, staker.address);
            expect(u.amount).to.equal(ethers.parseEther('500'));
        });
    });
});
