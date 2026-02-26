/**
 * PrivateDEXSettlement — Non-MPC Logic Tests
 *
 * Tests all contract logic that does NOT require COTI MPC garbled circuits:
 *  1.  Initialization (roles, fee recipients, zero-address guards)
 *  2.  Nonce validation (InvalidNonce revert)
 *  3.  Deadline checks (DeadlineExpired revert)
 *  4.  Role-based access (SETTLER_ROLE guards on lock/settle)
 *  5.  Status transitions (double-lock, settle-when-not-locked)
 *  6.  Cancel (only trader, cannot cancel settled/empty)
 *  7.  Emergency stop (blocks new settlements, resumeTrading re-enables)
 *  8.  Pausable (paused contract blocks lock and settle)
 *  9.  Fee recipients (updateFeeRecipients, zero-address revert)
 * 10.  Ossification (ossify blocks upgrade)
 * 11.  View functions (getPrivateCollateral, getFeeRecipients, getNonce)
 *
 * MPC-dependent functions (settlePrivateIntent with actual encrypted values,
 * claimFees) CANNOT be tested on Hardhat — they require COTI testnet MPC
 * precompile. Those tests are marked with descriptive skip comments.
 */

/* eslint-disable @typescript-eslint/no-var-requires */
const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");
const {
    time,
    loadFixture,
} = require("@nomicfoundation/hardhat-network-helpers");

describe("PrivateDEXSettlement", function () {
    /**
     * Shared deployment fixture.
     * Deploys the UUPS proxy with three init args: admin, oddao, stakingPool.
     */
    async function deployFixture() {
        const [admin, settler, trader, solver, validator, oddao, stakingPool, outsider] =
            await ethers.getSigners();

        const Factory = await ethers.getContractFactory("PrivateDEXSettlement");
        const settlement = await upgrades.deployProxy(
            Factory,
            [admin.address, oddao.address, stakingPool.address],
            { initializer: "initialize", kind: "uups" }
        );

        // Grant SETTLER_ROLE to the dedicated settler signer
        const SETTLER_ROLE = await settlement.SETTLER_ROLE();
        await settlement.connect(admin).grantRole(SETTLER_ROLE, settler.address);

        // Two arbitrary ERC20 addresses for tokenIn / tokenOut (not real
        // contracts — we only need non-zero addresses for the struct fields)
        const tokenIn = ethers.Wallet.createRandom().address;
        const tokenOut = ethers.Wallet.createRandom().address;

        return {
            settlement,
            admin,
            settler,
            trader,
            solver,
            validator,
            oddao,
            stakingPool,
            outsider,
            tokenIn,
            tokenOut,
            SETTLER_ROLE,
        };
    }

    /**
     * Helper: build args for lockPrivateCollateral with sensible defaults.
     * Encrypted amounts are ctUint64 (alias for uint256), so any uint256 is fine.
     */
    function lockArgs(overrides: Record<string, unknown> = {}) {
        const defaults: Record<string, unknown> = {
            intentId: ethers.id("test-intent-1"),
            trader: ethers.ZeroAddress, // must override
            tokenIn: ethers.ZeroAddress, // must override
            tokenOut: ethers.ZeroAddress, // must override
            encTraderAmount: 1000n, // ctUint64 placeholder (not real encrypted)
            encSolverAmount: 2000n, // ctUint64 placeholder
            traderNonce: 0n,
            deadline: 0n, // must override
        };
        return { ...defaults, ...overrides };
    }

    // ─────────────────────────────────────────────────────────────────────
    //  1. Initialization
    // ─────────────────────────────────────────────────────────────────────

    describe("Initialization", function () {
        it("should grant DEFAULT_ADMIN_ROLE to admin", async function () {
            const { settlement, admin } = await loadFixture(deployFixture);
            const DEFAULT_ADMIN_ROLE = await settlement.DEFAULT_ADMIN_ROLE();
            expect(await settlement.hasRole(DEFAULT_ADMIN_ROLE, admin.address)).to.be.true;
        });

        it("should grant ADMIN_ROLE to admin", async function () {
            const { settlement, admin } = await loadFixture(deployFixture);
            const ADMIN_ROLE = await settlement.ADMIN_ROLE();
            expect(await settlement.hasRole(ADMIN_ROLE, admin.address)).to.be.true;
        });

        it("should grant SETTLER_ROLE to admin", async function () {
            const { settlement, admin } = await loadFixture(deployFixture);
            const SETTLER_ROLE = await settlement.SETTLER_ROLE();
            expect(await settlement.hasRole(SETTLER_ROLE, admin.address)).to.be.true;
        });

        it("should set fee recipients correctly", async function () {
            const { settlement, oddao, stakingPool } = await loadFixture(deployFixture);
            const recipients = await settlement.getFeeRecipients();
            expect(recipients.oddao).to.equal(oddao.address);
            expect(recipients.stakingPool).to.equal(stakingPool.address);
        });

        it("should start with totalSettlements = 0", async function () {
            const { settlement } = await loadFixture(deployFixture);
            expect(await settlement.totalSettlements()).to.equal(0n);
        });

        it("should start with emergencyStop = false", async function () {
            const { settlement } = await loadFixture(deployFixture);
            expect(await settlement.emergencyStop()).to.equal(false);
        });

        it("should start unossified", async function () {
            const { settlement } = await loadFixture(deployFixture);
            expect(await settlement.isOssified()).to.equal(false);
        });

        it("should revert when admin is zero address", async function () {
            const Factory = await ethers.getContractFactory("PrivateDEXSettlement");
            const [, , , , , oddao, stakingPool] = await ethers.getSigners();
            await expect(
                upgrades.deployProxy(
                    Factory,
                    [ethers.ZeroAddress, oddao.address, stakingPool.address],
                    { initializer: "initialize", kind: "uups" }
                )
            ).to.be.revertedWithCustomError(Factory, "InvalidAddress");
        });

        it("should revert when oddao is zero address", async function () {
            const Factory = await ethers.getContractFactory("PrivateDEXSettlement");
            const [admin, , , , , , stakingPool] = await ethers.getSigners();
            await expect(
                upgrades.deployProxy(
                    Factory,
                    [admin.address, ethers.ZeroAddress, stakingPool.address],
                    { initializer: "initialize", kind: "uups" }
                )
            ).to.be.revertedWithCustomError(Factory, "InvalidAddress");
        });

        it("should revert when stakingPool is zero address", async function () {
            const Factory = await ethers.getContractFactory("PrivateDEXSettlement");
            const [admin, , , , , oddao] = await ethers.getSigners();
            await expect(
                upgrades.deployProxy(
                    Factory,
                    [admin.address, oddao.address, ethers.ZeroAddress],
                    { initializer: "initialize", kind: "uups" }
                )
            ).to.be.revertedWithCustomError(Factory, "InvalidAddress");
        });
    });

    // ─────────────────────────────────────────────────────────────────────
    //  2. lockPrivateCollateral — basic & nonce validation
    // ─────────────────────────────────────────────────────────────────────

    describe("lockPrivateCollateral", function () {
        it("should lock collateral successfully and increment nonce", async function () {
            const { settlement, settler, trader, tokenIn, tokenOut } =
                await loadFixture(deployFixture);

            const deadline = (await time.latest()) + 3600;
            const intentId = ethers.id("lock-1");

            await expect(
                settlement
                    .connect(settler)
                    .lockPrivateCollateral(
                        intentId,
                        trader.address,
                        tokenIn,
                        tokenOut,
                        1000n, // encTraderAmount (ctUint64)
                        2000n, // encSolverAmount (ctUint64)
                        0n,    // traderNonce
                        deadline
                    )
            )
                .to.emit(settlement, "PrivateCollateralLocked")
                .withArgs(intentId, trader.address, tokenIn, tokenOut, 0n);

            // Nonce should have incremented
            expect(await settlement.getNonce(trader.address)).to.equal(1n);
        });

        it("should store correct collateral struct fields", async function () {
            const { settlement, settler, trader, tokenIn, tokenOut } =
                await loadFixture(deployFixture);

            const deadline = (await time.latest()) + 3600;
            const intentId = ethers.id("lock-struct");

            await settlement
                .connect(settler)
                .lockPrivateCollateral(
                    intentId,
                    trader.address,
                    tokenIn,
                    tokenOut,
                    1000n,
                    2000n,
                    0n,
                    deadline
                );

            const col = await settlement.getPrivateCollateral(intentId);
            expect(col.trader).to.equal(trader.address);
            // solver is zero until settlement
            expect(col.solver).to.equal(ethers.ZeroAddress);
            expect(col.tokenIn).to.equal(tokenIn);
            expect(col.tokenOut).to.equal(tokenOut);
            expect(col.nonce).to.equal(0n);
            expect(col.deadline).to.equal(BigInt(deadline));
            // status = LOCKED (enum index 1)
            expect(col.status).to.equal(1n);
        });

        it("should revert with InvalidNonce when nonce does not match", async function () {
            const { settlement, settler, trader, tokenIn, tokenOut } =
                await loadFixture(deployFixture);

            const deadline = (await time.latest()) + 3600;

            await expect(
                settlement
                    .connect(settler)
                    .lockPrivateCollateral(
                        ethers.id("bad-nonce"),
                        trader.address,
                        tokenIn,
                        tokenOut,
                        1000n,
                        2000n,
                        999n, // wrong nonce — trader nonce is 0
                        deadline
                    )
            ).to.be.revertedWithCustomError(settlement, "InvalidNonce");
        });

        it("should revert with InvalidNonce for second lock if nonce not incremented", async function () {
            const { settlement, settler, trader, tokenIn, tokenOut } =
                await loadFixture(deployFixture);

            const deadline = (await time.latest()) + 3600;

            // First lock succeeds (nonce 0 -> 1)
            await settlement
                .connect(settler)
                .lockPrivateCollateral(
                    ethers.id("first"),
                    trader.address,
                    tokenIn,
                    tokenOut,
                    1000n,
                    2000n,
                    0n,
                    deadline
                );

            // Second lock with stale nonce 0 should fail
            await expect(
                settlement
                    .connect(settler)
                    .lockPrivateCollateral(
                        ethers.id("second"),
                        trader.address,
                        tokenIn,
                        tokenOut,
                        1000n,
                        2000n,
                        0n, // stale nonce
                        deadline
                    )
            ).to.be.revertedWithCustomError(settlement, "InvalidNonce");
        });

        it("should succeed for second lock when correct nonce provided", async function () {
            const { settlement, settler, trader, tokenIn, tokenOut } =
                await loadFixture(deployFixture);

            const deadline = (await time.latest()) + 3600;

            // First lock (nonce 0 -> 1)
            await settlement
                .connect(settler)
                .lockPrivateCollateral(
                    ethers.id("first"),
                    trader.address,
                    tokenIn,
                    tokenOut,
                    1000n,
                    2000n,
                    0n,
                    deadline
                );

            // Second lock with updated nonce 1
            await expect(
                settlement
                    .connect(settler)
                    .lockPrivateCollateral(
                        ethers.id("second"),
                        trader.address,
                        tokenIn,
                        tokenOut,
                        1000n,
                        2000n,
                        1n, // correct nonce
                        deadline
                    )
            ).to.emit(settlement, "PrivateCollateralLocked");

            expect(await settlement.getNonce(trader.address)).to.equal(2n);
        });
    });

    // ─────────────────────────────────────────────────────────────────────
    //  3. Deadline checks
    // ─────────────────────────────────────────────────────────────────────

    describe("Deadline validation", function () {
        it("should revert with DeadlineExpired when deadline is in the past", async function () {
            const { settlement, settler, trader, tokenIn, tokenOut } =
                await loadFixture(deployFixture);

            const pastDeadline = (await time.latest()) - 1;

            await expect(
                settlement
                    .connect(settler)
                    .lockPrivateCollateral(
                        ethers.id("past-dl"),
                        trader.address,
                        tokenIn,
                        tokenOut,
                        1000n,
                        2000n,
                        0n,
                        pastDeadline
                    )
            ).to.be.revertedWithCustomError(settlement, "DeadlineExpired");
        });

        it("should revert with DeadlineExpired when deadline equals block.timestamp", async function () {
            const { settlement, settler, trader, tokenIn, tokenOut } =
                await loadFixture(deployFixture);

            // deadline <= block.timestamp triggers revert
            const currentTime = await time.latest();

            await expect(
                settlement
                    .connect(settler)
                    .lockPrivateCollateral(
                        ethers.id("exact-dl"),
                        trader.address,
                        tokenIn,
                        tokenOut,
                        1000n,
                        2000n,
                        0n,
                        currentTime // equal to block.timestamp at tx time or earlier
                    )
            ).to.be.revertedWithCustomError(settlement, "DeadlineExpired");
        });
    });

    // ─────────────────────────────────────────────────────────────────────
    //  4. Role checks
    // ─────────────────────────────────────────────────────────────────────

    describe("Role-based access control", function () {
        it("should revert lockPrivateCollateral for non-SETTLER_ROLE", async function () {
            const { settlement, outsider, trader, tokenIn, tokenOut, SETTLER_ROLE } =
                await loadFixture(deployFixture);

            const deadline = (await time.latest()) + 3600;

            await expect(
                settlement
                    .connect(outsider)
                    .lockPrivateCollateral(
                        ethers.id("no-role"),
                        trader.address,
                        tokenIn,
                        tokenOut,
                        1000n,
                        2000n,
                        0n,
                        deadline
                    )
            )
                .to.be.revertedWithCustomError(settlement, "AccessControlUnauthorizedAccount")
                .withArgs(outsider.address, SETTLER_ROLE);
        });

        it("should revert settlePrivateIntent for non-SETTLER_ROLE", async function () {
            const { settlement, outsider, solver, validator, SETTLER_ROLE } =
                await loadFixture(deployFixture);

            await expect(
                settlement
                    .connect(outsider)
                    .settlePrivateIntent(
                        ethers.id("no-role-settle"),
                        solver.address,
                        validator.address
                    )
            )
                .to.be.revertedWithCustomError(settlement, "AccessControlUnauthorizedAccount")
                .withArgs(outsider.address, SETTLER_ROLE);
        });

        it("should allow admin to grant and revoke SETTLER_ROLE", async function () {
            const { settlement, admin, outsider, SETTLER_ROLE } =
                await loadFixture(deployFixture);

            // Grant
            await settlement.connect(admin).grantSettlerRole(outsider.address);
            expect(await settlement.hasRole(SETTLER_ROLE, outsider.address)).to.be.true;

            // Revoke
            await settlement.connect(admin).revokeSettlerRole(outsider.address);
            expect(await settlement.hasRole(SETTLER_ROLE, outsider.address)).to.be.false;
        });

        it("should revert grantSettlerRole with zero address", async function () {
            const { settlement, admin } = await loadFixture(deployFixture);

            await expect(
                settlement.connect(admin).grantSettlerRole(ethers.ZeroAddress)
            ).to.be.revertedWithCustomError(settlement, "InvalidAddress");
        });

        it("should revert grantSettlerRole for non-ADMIN_ROLE", async function () {
            const { settlement, outsider } = await loadFixture(deployFixture);
            const ADMIN_ROLE = await settlement.ADMIN_ROLE();

            await expect(
                settlement.connect(outsider).grantSettlerRole(outsider.address)
            )
                .to.be.revertedWithCustomError(settlement, "AccessControlUnauthorizedAccount")
                .withArgs(outsider.address, ADMIN_ROLE);
        });
    });

    // ─────────────────────────────────────────────────────────────────────
    //  5. Status transitions
    // ─────────────────────────────────────────────────────────────────────

    describe("Status transitions", function () {
        it("should revert with CollateralAlreadyLocked on duplicate lock", async function () {
            const { settlement, settler, trader, tokenIn, tokenOut } =
                await loadFixture(deployFixture);

            const deadline = (await time.latest()) + 3600;
            const intentId = ethers.id("dup-lock");

            // First lock
            await settlement
                .connect(settler)
                .lockPrivateCollateral(
                    intentId,
                    trader.address,
                    tokenIn,
                    tokenOut,
                    1000n,
                    2000n,
                    0n,
                    deadline
                );

            // Duplicate lock with same intentId
            await expect(
                settlement
                    .connect(settler)
                    .lockPrivateCollateral(
                        intentId,
                        trader.address,
                        tokenIn,
                        tokenOut,
                        1000n,
                        2000n,
                        1n, // nonce has incremented
                        deadline
                    )
            ).to.be.revertedWithCustomError(settlement, "CollateralAlreadyLocked");
        });

        it("should revert settlePrivateIntent with CollateralNotLocked when not locked", async function () {
            const { settlement, settler, solver, validator } =
                await loadFixture(deployFixture);

            // Attempt to settle a non-existent intent (EMPTY status)
            await expect(
                settlement
                    .connect(settler)
                    .settlePrivateIntent(
                        ethers.id("no-lock"),
                        solver.address,
                        validator.address
                    )
            ).to.be.revertedWithCustomError(settlement, "CollateralNotLocked");
        });

        it("should revert settlePrivateIntent with InvalidAddress for zero solver", async function () {
            const { settlement, settler, validator } =
                await loadFixture(deployFixture);

            await expect(
                settlement
                    .connect(settler)
                    .settlePrivateIntent(
                        ethers.id("zero-solver"),
                        ethers.ZeroAddress,
                        validator.address
                    )
            ).to.be.revertedWithCustomError(settlement, "InvalidAddress");
        });

        it("should revert settlePrivateIntent with InvalidAddress for zero validator", async function () {
            const { settlement, settler, solver } =
                await loadFixture(deployFixture);

            await expect(
                settlement
                    .connect(settler)
                    .settlePrivateIntent(
                        ethers.id("zero-val"),
                        solver.address,
                        ethers.ZeroAddress
                    )
            ).to.be.revertedWithCustomError(settlement, "InvalidAddress");
        });

        // NOTE: Full settlePrivateIntent success path requires COTI MPC
        // precompile (MpcCore.onBoard, MpcCore.ge, MpcCore.decrypt, etc.).
        // Requires COTI testnet — cannot test on Hardhat.

        it("should revert lock with InvalidAddress for zero trader", async function () {
            const { settlement, settler, tokenIn, tokenOut } =
                await loadFixture(deployFixture);

            const deadline = (await time.latest()) + 3600;

            await expect(
                settlement
                    .connect(settler)
                    .lockPrivateCollateral(
                        ethers.id("zero-trader"),
                        ethers.ZeroAddress,
                        tokenIn,
                        tokenOut,
                        1000n,
                        2000n,
                        0n,
                        deadline
                    )
            ).to.be.revertedWithCustomError(settlement, "InvalidAddress");
        });

        it("should revert lock with InvalidAddress for zero tokenIn", async function () {
            const { settlement, settler, trader, tokenOut } =
                await loadFixture(deployFixture);

            const deadline = (await time.latest()) + 3600;

            await expect(
                settlement
                    .connect(settler)
                    .lockPrivateCollateral(
                        ethers.id("zero-tokenIn"),
                        trader.address,
                        ethers.ZeroAddress,
                        tokenOut,
                        1000n,
                        2000n,
                        0n,
                        deadline
                    )
            ).to.be.revertedWithCustomError(settlement, "InvalidAddress");
        });

        it("should revert lock with InvalidAddress for zero tokenOut", async function () {
            const { settlement, settler, trader, tokenIn } =
                await loadFixture(deployFixture);

            const deadline = (await time.latest()) + 3600;

            await expect(
                settlement
                    .connect(settler)
                    .lockPrivateCollateral(
                        ethers.id("zero-tokenOut"),
                        trader.address,
                        tokenIn,
                        ethers.ZeroAddress,
                        1000n,
                        2000n,
                        0n,
                        deadline
                    )
            ).to.be.revertedWithCustomError(settlement, "InvalidAddress");
        });
    });

    // ─────────────────────────────────────────────────────────────────────
    //  6. Cancel
    // ─────────────────────────────────────────────────────────────────────

    describe("cancelPrivateIntent", function () {
        it("should allow trader to cancel a locked intent", async function () {
            const { settlement, settler, trader, tokenIn, tokenOut } =
                await loadFixture(deployFixture);

            const deadline = (await time.latest()) + 3600;
            const intentId = ethers.id("cancel-1");

            await settlement
                .connect(settler)
                .lockPrivateCollateral(
                    intentId,
                    trader.address,
                    tokenIn,
                    tokenOut,
                    1000n,
                    2000n,
                    0n,
                    deadline
                );

            await expect(settlement.connect(trader).cancelPrivateIntent(intentId))
                .to.emit(settlement, "PrivateIntentCancelled")
                .withArgs(intentId, trader.address);

            // Status should be CANCELLED (enum index 3)
            const col = await settlement.getPrivateCollateral(intentId);
            expect(col.status).to.equal(3n);
        });

        it("should revert when non-trader attempts to cancel", async function () {
            const { settlement, settler, trader, outsider, tokenIn, tokenOut } =
                await loadFixture(deployFixture);

            const deadline = (await time.latest()) + 3600;
            const intentId = ethers.id("cancel-nottrader");

            await settlement
                .connect(settler)
                .lockPrivateCollateral(
                    intentId,
                    trader.address,
                    tokenIn,
                    tokenOut,
                    1000n,
                    2000n,
                    0n,
                    deadline
                );

            await expect(
                settlement.connect(outsider).cancelPrivateIntent(intentId)
            ).to.be.revertedWithCustomError(settlement, "NotTrader");
        });

        it("should revert when cancelling a non-existent (EMPTY) intent", async function () {
            const { settlement, trader } = await loadFixture(deployFixture);

            await expect(
                settlement
                    .connect(trader)
                    .cancelPrivateIntent(ethers.id("no-such-intent"))
            ).to.be.revertedWithCustomError(settlement, "CollateralNotLocked");
        });

        it("should revert when cancelling an already cancelled intent", async function () {
            const { settlement, settler, trader, tokenIn, tokenOut } =
                await loadFixture(deployFixture);

            const deadline = (await time.latest()) + 3600;
            const intentId = ethers.id("cancel-twice");

            await settlement
                .connect(settler)
                .lockPrivateCollateral(
                    intentId,
                    trader.address,
                    tokenIn,
                    tokenOut,
                    1000n,
                    2000n,
                    0n,
                    deadline
                );

            // Cancel once
            await settlement.connect(trader).cancelPrivateIntent(intentId);

            // Cancel again — status is CANCELLED, not LOCKED
            await expect(
                settlement.connect(trader).cancelPrivateIntent(intentId)
            ).to.be.revertedWithCustomError(settlement, "CollateralNotLocked");
        });

        it("should revert cancel when contract is paused", async function () {
            const { settlement, admin, settler, trader, tokenIn, tokenOut } =
                await loadFixture(deployFixture);

            const deadline = (await time.latest()) + 3600;
            const intentId = ethers.id("cancel-paused");

            await settlement
                .connect(settler)
                .lockPrivateCollateral(
                    intentId,
                    trader.address,
                    tokenIn,
                    tokenOut,
                    1000n,
                    2000n,
                    0n,
                    deadline
                );

            await settlement.connect(admin).pause();

            await expect(
                settlement.connect(trader).cancelPrivateIntent(intentId)
            ).to.be.revertedWithCustomError(settlement, "EnforcedPause");
        });
    });

    // ─────────────────────────────────────────────────────────────────────
    //  7. Emergency stop
    // ─────────────────────────────────────────────────────────────────────

    describe("Emergency stop", function () {
        it("should activate emergency stop and emit event", async function () {
            const { settlement, admin } = await loadFixture(deployFixture);

            await expect(
                settlement.connect(admin).emergencyStopTrading("Security incident")
            )
                .to.emit(settlement, "EmergencyStopped")
                .withArgs(admin.address, "Security incident");

            expect(await settlement.emergencyStop()).to.equal(true);
        });

        it("should block lockPrivateCollateral when emergency stop is active", async function () {
            const { settlement, admin, settler, trader, tokenIn, tokenOut } =
                await loadFixture(deployFixture);

            await settlement.connect(admin).emergencyStopTrading("halt");

            const deadline = (await time.latest()) + 3600;

            await expect(
                settlement
                    .connect(settler)
                    .lockPrivateCollateral(
                        ethers.id("es-lock"),
                        trader.address,
                        tokenIn,
                        tokenOut,
                        1000n,
                        2000n,
                        0n,
                        deadline
                    )
            ).to.be.revertedWithCustomError(settlement, "EmergencyStopActive");
        });

        it("should block settlePrivateIntent when emergency stop is active", async function () {
            const { settlement, admin, settler, solver, validator } =
                await loadFixture(deployFixture);

            await settlement.connect(admin).emergencyStopTrading("halt");

            await expect(
                settlement
                    .connect(settler)
                    .settlePrivateIntent(
                        ethers.id("es-settle"),
                        solver.address,
                        validator.address
                    )
            ).to.be.revertedWithCustomError(settlement, "EmergencyStopActive");
        });

        it("should resume trading and emit event", async function () {
            const { settlement, admin } = await loadFixture(deployFixture);

            await settlement.connect(admin).emergencyStopTrading("halt");
            expect(await settlement.emergencyStop()).to.equal(true);

            await expect(settlement.connect(admin).resumeTrading())
                .to.emit(settlement, "TradingResumed")
                .withArgs(admin.address);

            expect(await settlement.emergencyStop()).to.equal(false);
        });

        it("should allow lock after resumeTrading", async function () {
            const { settlement, admin, settler, trader, tokenIn, tokenOut } =
                await loadFixture(deployFixture);

            // Stop then resume
            await settlement.connect(admin).emergencyStopTrading("halt");
            await settlement.connect(admin).resumeTrading();

            const deadline = (await time.latest()) + 3600;

            await expect(
                settlement
                    .connect(settler)
                    .lockPrivateCollateral(
                        ethers.id("resume-lock"),
                        trader.address,
                        tokenIn,
                        tokenOut,
                        1000n,
                        2000n,
                        0n,
                        deadline
                    )
            ).to.emit(settlement, "PrivateCollateralLocked");
        });

        it("should revert emergencyStopTrading for non-ADMIN_ROLE", async function () {
            const { settlement, outsider } = await loadFixture(deployFixture);
            const ADMIN_ROLE = await settlement.ADMIN_ROLE();

            await expect(
                settlement.connect(outsider).emergencyStopTrading("hack")
            )
                .to.be.revertedWithCustomError(settlement, "AccessControlUnauthorizedAccount")
                .withArgs(outsider.address, ADMIN_ROLE);
        });

        it("should revert resumeTrading for non-ADMIN_ROLE", async function () {
            const { settlement, admin, outsider } = await loadFixture(deployFixture);
            const ADMIN_ROLE = await settlement.ADMIN_ROLE();

            await settlement.connect(admin).emergencyStopTrading("halt");

            await expect(settlement.connect(outsider).resumeTrading())
                .to.be.revertedWithCustomError(settlement, "AccessControlUnauthorizedAccount")
                .withArgs(outsider.address, ADMIN_ROLE);
        });
    });

    // ─────────────────────────────────────────────────────────────────────
    //  8. Pause / Unpause
    // ─────────────────────────────────────────────────────────────────────

    describe("Pausable", function () {
        it("should pause and block lockPrivateCollateral", async function () {
            const { settlement, admin, settler, trader, tokenIn, tokenOut } =
                await loadFixture(deployFixture);

            await settlement.connect(admin).pause();

            const deadline = (await time.latest()) + 3600;

            await expect(
                settlement
                    .connect(settler)
                    .lockPrivateCollateral(
                        ethers.id("paused-lock"),
                        trader.address,
                        tokenIn,
                        tokenOut,
                        1000n,
                        2000n,
                        0n,
                        deadline
                    )
            ).to.be.revertedWithCustomError(settlement, "EnforcedPause");
        });

        it("should pause and block settlePrivateIntent", async function () {
            const { settlement, admin, settler, solver, validator } =
                await loadFixture(deployFixture);

            await settlement.connect(admin).pause();

            await expect(
                settlement
                    .connect(settler)
                    .settlePrivateIntent(
                        ethers.id("paused-settle"),
                        solver.address,
                        validator.address
                    )
            ).to.be.revertedWithCustomError(settlement, "EnforcedPause");
        });

        it("should unpause and allow lockPrivateCollateral again", async function () {
            const { settlement, admin, settler, trader, tokenIn, tokenOut } =
                await loadFixture(deployFixture);

            await settlement.connect(admin).pause();
            await settlement.connect(admin).unpause();

            const deadline = (await time.latest()) + 3600;

            await expect(
                settlement
                    .connect(settler)
                    .lockPrivateCollateral(
                        ethers.id("unpaused-lock"),
                        trader.address,
                        tokenIn,
                        tokenOut,
                        1000n,
                        2000n,
                        0n,
                        deadline
                    )
            ).to.emit(settlement, "PrivateCollateralLocked");
        });

        it("should revert pause for non-ADMIN_ROLE", async function () {
            const { settlement, outsider } = await loadFixture(deployFixture);
            const ADMIN_ROLE = await settlement.ADMIN_ROLE();

            await expect(settlement.connect(outsider).pause())
                .to.be.revertedWithCustomError(settlement, "AccessControlUnauthorizedAccount")
                .withArgs(outsider.address, ADMIN_ROLE);
        });

        it("should revert unpause for non-ADMIN_ROLE", async function () {
            const { settlement, admin, outsider } = await loadFixture(deployFixture);
            const ADMIN_ROLE = await settlement.ADMIN_ROLE();

            await settlement.connect(admin).pause();

            await expect(settlement.connect(outsider).unpause())
                .to.be.revertedWithCustomError(settlement, "AccessControlUnauthorizedAccount")
                .withArgs(outsider.address, ADMIN_ROLE);
        });
    });

    // ─────────────────────────────────────────────────────────────────────
    //  9. Fee recipients
    // ─────────────────────────────────────────────────────────────────────

    describe("updateFeeRecipients", function () {
        it("should update fee recipients and emit event", async function () {
            const { settlement, admin, trader, solver } =
                await loadFixture(deployFixture);

            // Use trader and solver as new recipients for test purposes
            await expect(
                settlement
                    .connect(admin)
                    .updateFeeRecipients(trader.address, solver.address)
            )
                .to.emit(settlement, "FeeRecipientsUpdated")
                .withArgs(trader.address, solver.address);

            const recipients = await settlement.getFeeRecipients();
            expect(recipients.oddao).to.equal(trader.address);
            expect(recipients.stakingPool).to.equal(solver.address);
        });

        it("should revert when oddao is zero address", async function () {
            const { settlement, admin, solver } = await loadFixture(deployFixture);

            await expect(
                settlement
                    .connect(admin)
                    .updateFeeRecipients(ethers.ZeroAddress, solver.address)
            ).to.be.revertedWithCustomError(settlement, "InvalidAddress");
        });

        it("should revert when stakingPool is zero address", async function () {
            const { settlement, admin, trader } = await loadFixture(deployFixture);

            await expect(
                settlement
                    .connect(admin)
                    .updateFeeRecipients(trader.address, ethers.ZeroAddress)
            ).to.be.revertedWithCustomError(settlement, "InvalidAddress");
        });

        it("should revert for non-ADMIN_ROLE", async function () {
            const { settlement, outsider, trader, solver } =
                await loadFixture(deployFixture);
            const ADMIN_ROLE = await settlement.ADMIN_ROLE();

            await expect(
                settlement
                    .connect(outsider)
                    .updateFeeRecipients(trader.address, solver.address)
            )
                .to.be.revertedWithCustomError(settlement, "AccessControlUnauthorizedAccount")
                .withArgs(outsider.address, ADMIN_ROLE);
        });
    });

    // ─────────────────────────────────────────────────────────────────────
    //  10. Ossification
    // ─────────────────────────────────────────────────────────────────────

    describe("Ossification", function () {
        it("should ossify and emit ContractOssified", async function () {
            const { settlement, admin } = await loadFixture(deployFixture);

            await expect(settlement.connect(admin).ossify())
                .to.emit(settlement, "ContractOssified")
                .withArgs(await settlement.getAddress());

            expect(await settlement.isOssified()).to.equal(true);
        });

        it("should block UUPS upgrade after ossification", async function () {
            const { settlement, admin } = await loadFixture(deployFixture);

            await settlement.connect(admin).ossify();

            const V2Factory = await ethers.getContractFactory("PrivateDEXSettlement");
            await expect(
                upgrades.upgradeProxy(await settlement.getAddress(), V2Factory)
            ).to.be.revertedWithCustomError(settlement, "ContractIsOssified");
        });

        it("should revert ossify for non-ADMIN_ROLE", async function () {
            const { settlement, outsider } = await loadFixture(deployFixture);
            const ADMIN_ROLE = await settlement.ADMIN_ROLE();

            await expect(settlement.connect(outsider).ossify())
                .to.be.revertedWithCustomError(settlement, "AccessControlUnauthorizedAccount")
                .withArgs(outsider.address, ADMIN_ROLE);
        });

        it("should allow upgrade before ossification", async function () {
            const { settlement } = await loadFixture(deployFixture);

            // Verify not ossified
            expect(await settlement.isOssified()).to.equal(false);

            // Upgrade should succeed (same implementation — validates _authorizeUpgrade path)
            const V2Factory = await ethers.getContractFactory("PrivateDEXSettlement");
            const upgraded = await upgrades.upgradeProxy(
                await settlement.getAddress(),
                V2Factory
            );

            // Contract should still be functional
            expect(await upgraded.isOssified()).to.equal(false);
            expect(await upgraded.totalSettlements()).to.equal(0n);
        });
    });

    // ─────────────────────────────────────────────────────────────────────
    //  11. View functions
    // ─────────────────────────────────────────────────────────────────────

    describe("View functions", function () {
        it("getPrivateCollateral should return EMPTY struct for unknown intentId", async function () {
            const { settlement } = await loadFixture(deployFixture);

            const col = await settlement.getPrivateCollateral(ethers.id("unknown"));
            expect(col.trader).to.equal(ethers.ZeroAddress);
            expect(col.solver).to.equal(ethers.ZeroAddress);
            expect(col.tokenIn).to.equal(ethers.ZeroAddress);
            expect(col.tokenOut).to.equal(ethers.ZeroAddress);
            expect(col.nonce).to.equal(0n);
            expect(col.deadline).to.equal(0n);
            // status = EMPTY (enum index 0)
            expect(col.status).to.equal(0n);
        });

        it("getNonce should return 0 for uninitialized address", async function () {
            const { settlement, outsider } = await loadFixture(deployFixture);

            expect(await settlement.getNonce(outsider.address)).to.equal(0n);
        });

        it("getNonce should reflect incremented nonce after lock", async function () {
            const { settlement, settler, trader, tokenIn, tokenOut } =
                await loadFixture(deployFixture);

            const deadline = (await time.latest()) + 3600;

            // Lock three times for same trader
            for (let i = 0; i < 3; i++) {
                await settlement
                    .connect(settler)
                    .lockPrivateCollateral(
                        ethers.id(`view-nonce-${i}`),
                        trader.address,
                        tokenIn,
                        tokenOut,
                        1000n,
                        2000n,
                        BigInt(i), // sequential nonces
                        deadline
                    );
            }

            expect(await settlement.getNonce(trader.address)).to.equal(3n);
        });

        it("getFeeRecipients should return current recipients", async function () {
            const { settlement, oddao, stakingPool } = await loadFixture(deployFixture);

            const recipients = await settlement.getFeeRecipients();
            expect(recipients.oddao).to.equal(oddao.address);
            expect(recipients.stakingPool).to.equal(stakingPool.address);
        });

        it("getFeeRecord should return empty record for unknown intentId", async function () {
            const { settlement } = await loadFixture(deployFixture);

            const record = await settlement.getFeeRecord(ethers.id("no-fees"));
            expect(record.validator).to.equal(ethers.ZeroAddress);
            // Encrypted fields are ctUint64 (uint256), default 0
            expect(record.oddaoFee).to.equal(0n);
            expect(record.stakingPoolFee).to.equal(0n);
            expect(record.validatorFee).to.equal(0n);
        });

        it("getAccumulatedFees should return 0 for uninitiated address", async function () {
            const { settlement, outsider } = await loadFixture(deployFixture);

            // ctUint64 defaults to 0
            expect(await settlement.getAccumulatedFees(outsider.address)).to.equal(0n);
        });
    });

    // ─────────────────────────────────────────────────────────────────────
    //  Constants
    // ─────────────────────────────────────────────────────────────────────

    describe("Constants", function () {
        it("should expose correct role hashes", async function () {
            const { settlement } = await loadFixture(deployFixture);

            expect(await settlement.SETTLER_ROLE()).to.equal(
                ethers.id("SETTLER_ROLE")
            );
            expect(await settlement.ADMIN_ROLE()).to.equal(
                ethers.id("ADMIN_ROLE")
            );
        });

        it("should expose correct fee constants", async function () {
            const { settlement } = await loadFixture(deployFixture);

            expect(await settlement.BASIS_POINTS_DIVISOR()).to.equal(10000n);
            expect(await settlement.ODDAO_SHARE_BPS()).to.equal(7000n);
            expect(await settlement.STAKING_POOL_SHARE_BPS()).to.equal(2000n);
            expect(await settlement.VALIDATOR_SHARE_BPS()).to.equal(1000n);
            expect(await settlement.TRADING_FEE_BPS()).to.equal(20n);
        });

        it("fee share BPS should sum to BASIS_POINTS_DIVISOR", async function () {
            const { settlement } = await loadFixture(deployFixture);

            const oddao = await settlement.ODDAO_SHARE_BPS();
            const staking = await settlement.STAKING_POOL_SHARE_BPS();
            const validator = await settlement.VALIDATOR_SHARE_BPS();

            expect(oddao + staking + validator).to.equal(
                await settlement.BASIS_POINTS_DIVISOR()
            );
        });
    });

    // ─────────────────────────────────────────────────────────────────────
    //  MPC-Dependent (Requires COTI Testnet)
    // ─────────────────────────────────────────────────────────────────────

    describe("MPC-Dependent (COTI testnet only)", function () {
        // These tests document what CANNOT be tested on Hardhat due to
        // MPC precompile requirements. They should be run on COTI testnet.

        it.skip("settlePrivateIntent — full settlement with encrypted amounts (Requires COTI testnet)", function () {
            // MpcCore.onBoard, MpcCore.ge, MpcCore.decrypt, MpcCore.mul,
            // MpcCore.div, MpcCore.add, MpcCore.sub, MpcCore.offBoard
            // all call COTI MPC precompiles that revert on Hardhat.
        });

        it.skip("settlePrivateIntent — InsufficientCollateral for zero trader amount (Requires COTI testnet)", function () {
            // MpcCore.ge comparison followed by MpcCore.decrypt to get
            // bool result — requires MPC precompile.
        });

        it.skip("settlePrivateIntent — InsufficientCollateral for zero solver amount (Requires COTI testnet)", function () {
            // Same as above — MPC verification of solver collateral.
        });

        it.skip("settlePrivateIntent — fee calculation and distribution (Requires COTI testnet)", function () {
            // 0.2% trading fee split 70/20/10 — all encrypted arithmetic
            // via MPC garbled circuits.
        });

        it.skip("settlePrivateIntent — double settle should revert (Requires COTI testnet)", function () {
            // After successful settlement, status becomes SETTLED.
            // Second call should revert with CollateralNotLocked.
            // Cannot reach settled state without MPC.
        });

        it.skip("settlePrivateIntent — settle after deadline should revert DeadlineExpired (Requires COTI testnet)", function () {
            // Would need to lock, advance time past deadline, then settle.
            // Lock works on Hardhat, but settle uses MPC — cannot test.
        });

        it.skip("claimFees — successful claim with encrypted balance (Requires COTI testnet)", function () {
            // MpcCore.onBoard, MpcCore.ge, MpcCore.decrypt, MpcCore.offBoard
            // all require MPC precompile.
        });

        it.skip("claimFees — revert for zero balance (Requires COTI testnet)", function () {
            // InsufficientCollateral when no fees accumulated.
            // Comparison uses MPC.
        });

        it.skip("cancelPrivateIntent — cannot cancel settled intent (Requires COTI testnet)", function () {
            // Need to first successfully settle (requires MPC), then
            // attempt cancel — should revert CollateralNotLocked.
        });
    });

    // ─────────────────────────────────────────────────────────────────────
    //  Event & Interface existence
    // ─────────────────────────────────────────────────────────────────────

    describe("Events and interface", function () {
        it("should have PrivateCollateralLocked event in ABI", async function () {
            const { settlement } = await loadFixture(deployFixture);
            const event = settlement.interface.getEvent("PrivateCollateralLocked");
            expect(event).to.not.be.undefined;
            expect(event.name).to.equal("PrivateCollateralLocked");
        });

        it("should have PrivateIntentSettled event in ABI", async function () {
            const { settlement } = await loadFixture(deployFixture);
            const event = settlement.interface.getEvent("PrivateIntentSettled");
            expect(event).to.not.be.undefined;
            expect(event.name).to.equal("PrivateIntentSettled");
        });

        it("should have FeesClaimed event in ABI", async function () {
            const { settlement } = await loadFixture(deployFixture);
            const event = settlement.interface.getEvent("FeesClaimed");
            expect(event).to.not.be.undefined;
            expect(event.name).to.equal("FeesClaimed");
        });

        it("should have PrivateIntentCancelled event in ABI", async function () {
            const { settlement } = await loadFixture(deployFixture);
            const event = settlement.interface.getEvent("PrivateIntentCancelled");
            expect(event).to.not.be.undefined;
            expect(event.name).to.equal("PrivateIntentCancelled");
        });

        it("should have EmergencyStopped event in ABI", async function () {
            const { settlement } = await loadFixture(deployFixture);
            const event = settlement.interface.getEvent("EmergencyStopped");
            expect(event).to.not.be.undefined;
            expect(event.name).to.equal("EmergencyStopped");
        });

        it("should have TradingResumed event in ABI", async function () {
            const { settlement } = await loadFixture(deployFixture);
            const event = settlement.interface.getEvent("TradingResumed");
            expect(event).to.not.be.undefined;
            expect(event.name).to.equal("TradingResumed");
        });

        it("should have FeeRecipientsUpdated event in ABI", async function () {
            const { settlement } = await loadFixture(deployFixture);
            const event = settlement.interface.getEvent("FeeRecipientsUpdated");
            expect(event).to.not.be.undefined;
            expect(event.name).to.equal("FeeRecipientsUpdated");
        });

        it("should have ContractOssified event in ABI", async function () {
            const { settlement } = await loadFixture(deployFixture);
            const event = settlement.interface.getEvent("ContractOssified");
            expect(event).to.not.be.undefined;
            expect(event.name).to.equal("ContractOssified");
        });

        it("should have all custom errors in ABI", async function () {
            const { settlement } = await loadFixture(deployFixture);

            const expectedErrors = [
                "EmergencyStopActive",
                "CollateralAlreadyLocked",
                "CollateralNotLocked",
                "AlreadySettled",
                "DeadlineExpired",
                "InvalidAddress",
                "InsufficientCollateral",
                "InvalidNonce",
                "IntentCancelled",
                "NotTrader",
                "ContractIsOssified",
            ];

            for (const errorName of expectedErrors) {
                const errorFragment = settlement.interface.getError(errorName);
                expect(errorFragment, `Missing error: ${errorName}`).to.not.be.undefined;
                expect(errorFragment.name).to.equal(errorName);
            }
        });
    });
});
