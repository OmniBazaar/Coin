/**
 * PrivateDEXSettlement -- Non-MPC Logic Tests
 *
 * Tests all contract logic that does NOT require COTI MPC garbled circuits:
 *  1.  Initialization (roles, fee recipients, zero-address guards)
 *  2.  Nonce validation (InvalidNonce revert)
 *  3.  Deadline checks (DeadlineExpired revert)
 *  4.  Role-based access (SETTLER_ROLE guards on lock/settle)
 *  5.  Status transitions (double-lock, settle-when-not-locked)
 *  6.  Cancel (only trader, cannot cancel settled/empty, min lock duration)
 *  7.  Pausable (paused contract blocks lock, settle, and cancel)
 *  8.  Fee recipients (updateFeeRecipients, zero-address revert)
 *  9.  Ossification (two-step: requestOssification + confirmOssification)
 * 10.  View functions (getPrivateCollateral, getFeeRecipients, getNonce)
 * 11.  Constants (fee BPS, roles)
 * 12.  SameTokenSwap guard
 *
 * MPC-dependent functions (settlePrivateIntent with actual encrypted values,
 * claimFees) CANNOT be tested on Hardhat -- they require COTI testnet MPC
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
     * Deploys the UUPS proxy with four init args:
     * admin, oddao, stakingPool, protocolTreasury.
     */
    async function deployFixture() {
        const [
            admin, settler, trader, solver, protocolTreasury,
            oddao, stakingPool, outsider
        ] = await ethers.getSigners();

        const Factory = await ethers.getContractFactory("PrivateDEXSettlement");
        const settlement = await upgrades.deployProxy(
            Factory,
            [
                admin.address,
                oddao.address,
                stakingPool.address,
                protocolTreasury.address,
            ],
            {
                initializer: "initialize",
                kind: "uups",
                constructorArgs: [ethers.ZeroAddress],
                unsafeAllow: ["constructor"],
            }
        );

        // Grant SETTLER_ROLE to the dedicated settler signer
        const SETTLER_ROLE = await settlement.SETTLER_ROLE();
        await settlement.connect(admin).grantRole(SETTLER_ROLE, settler.address);

        // Two arbitrary ERC20 addresses for tokenIn / tokenOut (not real
        // contracts -- we only need non-zero addresses for the struct fields)
        const tokenIn = ethers.Wallet.createRandom().address;
        const tokenOut = ethers.Wallet.createRandom().address;

        return {
            settlement,
            admin,
            settler,
            trader,
            solver,
            protocolTreasury,
            oddao,
            stakingPool,
            outsider,
            tokenIn,
            tokenOut,
            SETTLER_ROLE,
        };
    }

    /**
     * Helper: produce a valid EIP-191 trader signature for lockPrivateCollateral.
     *
     * The contract verifies:
     *   commitment = keccak256(abi.encode(intentId, trader, tokenIn, tokenOut,
     *                          traderNonce, deadline, contractAddress))
     *   ethSignedHash = toEthSignedMessageHash(commitment)
     *   signer == trader
     */
    async function signLockCommitment(
        traderSigner: any,
        contractAddress: string,
        intentId: string,
        tokenIn: string,
        tokenOut: string,
        traderNonce: bigint,
        deadline: bigint
    ): Promise<string> {
        const commitment = ethers.keccak256(
            ethers.AbiCoder.defaultAbiCoder().encode(
                ["bytes32", "address", "address", "address", "uint256", "uint256", "address"],
                [intentId, traderSigner.address, tokenIn, tokenOut, traderNonce, deadline, contractAddress]
            )
        );
        return traderSigner.signMessage(ethers.getBytes(commitment));
    }

    /**
     * Helper: call lockPrivateCollateral with proper signature.
     */
    async function lockWithSignature(
        settlement: any,
        settler: any,
        trader: any,
        intentId: string,
        tokenIn: string,
        tokenOut: string,
        encTraderAmount: bigint,
        encSolverAmount: bigint,
        traderNonce: bigint,
        deadline: bigint
    ) {
        const contractAddress = await settlement.getAddress();
        const signature = await signLockCommitment(
            trader, contractAddress, intentId, tokenIn, tokenOut, traderNonce, deadline
        );
        return settlement
            .connect(settler)
            .lockPrivateCollateral(
                intentId,
                trader.address,
                tokenIn,
                tokenOut,
                encTraderAmount,
                encSolverAmount,
                traderNonce,
                deadline,
                signature
            );
    }

    // -----------------------------------------------------------------
    //  1. Initialization
    // -----------------------------------------------------------------

    describe("Initialization", function () {
        it("should grant DEFAULT_ADMIN_ROLE to admin", async function () {
            const { settlement, admin } = await loadFixture(deployFixture);
            const DEFAULT_ADMIN_ROLE = await settlement.DEFAULT_ADMIN_ROLE();
            expect(await settlement.hasRole(DEFAULT_ADMIN_ROLE, admin.address)).to.be.true;
        });

        it("should grant DEFAULT_ADMIN_ROLE to admin (admin functions use DEFAULT_ADMIN_ROLE)", async function () {
            const { settlement, admin } = await loadFixture(deployFixture);
            const DEFAULT_ADMIN_ROLE = await settlement.DEFAULT_ADMIN_ROLE();
            expect(await settlement.hasRole(DEFAULT_ADMIN_ROLE, admin.address)).to.be.true;
        });

        it("should grant SETTLER_ROLE to admin", async function () {
            const { settlement, admin } = await loadFixture(deployFixture);
            const SETTLER_ROLE = await settlement.SETTLER_ROLE();
            expect(await settlement.hasRole(SETTLER_ROLE, admin.address)).to.be.true;
        });

        it("should set fee recipients correctly", async function () {
            const { settlement, oddao, stakingPool, protocolTreasury } =
                await loadFixture(deployFixture);
            const recipients = await settlement.getFeeRecipients();
            expect(recipients.oddao).to.equal(oddao.address);
            expect(recipients.stakingPool).to.equal(stakingPool.address);
            expect(recipients.protocolTreasury).to.equal(protocolTreasury.address);
        });

        it("should start with totalSettlements = 0", async function () {
            const { settlement } = await loadFixture(deployFixture);
            expect(await settlement.totalSettlements()).to.equal(0n);
        });

        it("should start unpaused", async function () {
            const { settlement } = await loadFixture(deployFixture);
            expect(await settlement.paused()).to.equal(false);
        });

        it("should start unossified", async function () {
            const { settlement } = await loadFixture(deployFixture);
            expect(await settlement.isOssified()).to.equal(false);
        });

        it("should revert when admin is zero address", async function () {
            const Factory = await ethers.getContractFactory("PrivateDEXSettlement");
            const [, , , , protocolTreasury, oddao, stakingPool] = await ethers.getSigners();
            await expect(
                upgrades.deployProxy(
                    Factory,
                    [ethers.ZeroAddress, oddao.address, stakingPool.address, protocolTreasury.address],
                    {
                        initializer: "initialize",
                        kind: "uups",
                        constructorArgs: [ethers.ZeroAddress],
                        unsafeAllow: ["constructor"],
                    }
                )
            ).to.be.revertedWithCustomError(Factory, "InvalidAddress");
        });

        it("should revert when oddao is zero address", async function () {
            const Factory = await ethers.getContractFactory("PrivateDEXSettlement");
            const [admin, , , , protocolTreasury, , stakingPool] = await ethers.getSigners();
            await expect(
                upgrades.deployProxy(
                    Factory,
                    [admin.address, ethers.ZeroAddress, stakingPool.address, protocolTreasury.address],
                    {
                        initializer: "initialize",
                        kind: "uups",
                        constructorArgs: [ethers.ZeroAddress],
                        unsafeAllow: ["constructor"],
                    }
                )
            ).to.be.revertedWithCustomError(Factory, "InvalidAddress");
        });

        it("should revert when stakingPool is zero address", async function () {
            const Factory = await ethers.getContractFactory("PrivateDEXSettlement");
            const [admin, , , , protocolTreasury, oddao] = await ethers.getSigners();
            await expect(
                upgrades.deployProxy(
                    Factory,
                    [admin.address, oddao.address, ethers.ZeroAddress, protocolTreasury.address],
                    {
                        initializer: "initialize",
                        kind: "uups",
                        constructorArgs: [ethers.ZeroAddress],
                        unsafeAllow: ["constructor"],
                    }
                )
            ).to.be.revertedWithCustomError(Factory, "InvalidAddress");
        });

        it("should revert when protocolTreasury is zero address", async function () {
            const Factory = await ethers.getContractFactory("PrivateDEXSettlement");
            const [admin, , , , , oddao, stakingPool] = await ethers.getSigners();
            await expect(
                upgrades.deployProxy(
                    Factory,
                    [admin.address, oddao.address, stakingPool.address, ethers.ZeroAddress],
                    {
                        initializer: "initialize",
                        kind: "uups",
                        constructorArgs: [ethers.ZeroAddress],
                        unsafeAllow: ["constructor"],
                    }
                )
            ).to.be.revertedWithCustomError(Factory, "InvalidAddress");
        });
    });

    // -----------------------------------------------------------------
    //  2. lockPrivateCollateral -- basic & nonce validation
    // -----------------------------------------------------------------

    describe("lockPrivateCollateral", function () {
        it("should lock collateral successfully and increment nonce", async function () {
            const { settlement, settler, trader, tokenIn, tokenOut } =
                await loadFixture(deployFixture);

            const deadline = BigInt((await time.latest()) + 3600);
            const intentId = ethers.id("lock-1");

            await expect(
                lockWithSignature(
                    settlement, settler, trader,
                    intentId, tokenIn, tokenOut,
                    1000n, 2000n, 0n, deadline
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

            const deadline = BigInt((await time.latest()) + 3600);
            const intentId = ethers.id("lock-struct");

            await lockWithSignature(
                settlement, settler, trader,
                intentId, tokenIn, tokenOut,
                1000n, 2000n, 0n, deadline
            );

            const col = await settlement.getPrivateCollateral(intentId);
            expect(col.trader).to.equal(trader.address);
            // solver is zero until settlement
            expect(col.solver).to.equal(ethers.ZeroAddress);
            expect(col.tokenIn).to.equal(tokenIn);
            expect(col.tokenOut).to.equal(tokenOut);
            expect(col.nonce).to.equal(0n);
            expect(col.deadline).to.equal(deadline);
            // status = LOCKED (enum index 1)
            expect(col.status).to.equal(1n);
        });

        it("should revert with InvalidNonce when nonce does not match", async function () {
            const { settlement, settler, trader, tokenIn, tokenOut } =
                await loadFixture(deployFixture);

            const deadline = BigInt((await time.latest()) + 3600);
            const intentId = ethers.id("bad-nonce");

            // Sign with wrong nonce 999 -- contract expects 0
            const contractAddress = await settlement.getAddress();
            const signature = await signLockCommitment(
                trader, contractAddress, intentId, tokenIn, tokenOut, 999n, deadline
            );

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
                        999n, // wrong nonce -- trader nonce is 0
                        deadline,
                        signature
                    )
            ).to.be.revertedWithCustomError(settlement, "InvalidNonce");
        });

        it("should revert with InvalidNonce for second lock if nonce not incremented", async function () {
            const { settlement, settler, trader, tokenIn, tokenOut } =
                await loadFixture(deployFixture);

            const deadline = BigInt((await time.latest()) + 3600);

            // First lock succeeds (nonce 0 -> 1)
            await lockWithSignature(
                settlement, settler, trader,
                ethers.id("first"), tokenIn, tokenOut,
                1000n, 2000n, 0n, deadline
            );

            // Second lock with stale nonce 0 should fail
            const contractAddress = await settlement.getAddress();
            const signature = await signLockCommitment(
                trader, contractAddress, ethers.id("second"), tokenIn, tokenOut, 0n, deadline
            );

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
                        deadline,
                        signature
                    )
            ).to.be.revertedWithCustomError(settlement, "InvalidNonce");
        });

        it("should succeed for second lock when correct nonce provided", async function () {
            const { settlement, settler, trader, tokenIn, tokenOut } =
                await loadFixture(deployFixture);

            const deadline = BigInt((await time.latest()) + 3600);

            // First lock (nonce 0 -> 1)
            await lockWithSignature(
                settlement, settler, trader,
                ethers.id("first"), tokenIn, tokenOut,
                1000n, 2000n, 0n, deadline
            );

            // Second lock with updated nonce 1
            await expect(
                lockWithSignature(
                    settlement, settler, trader,
                    ethers.id("second"), tokenIn, tokenOut,
                    1000n, 2000n, 1n, deadline
                )
            ).to.emit(settlement, "PrivateCollateralLocked");

            expect(await settlement.getNonce(trader.address)).to.equal(2n);
        });

        it("should revert with InvalidTraderSignature for bad signature", async function () {
            const { settlement, settler, trader, outsider, tokenIn, tokenOut } =
                await loadFixture(deployFixture);

            const deadline = BigInt((await time.latest()) + 3600);
            const intentId = ethers.id("bad-sig");

            // Sign with the wrong signer (outsider instead of trader)
            const contractAddress = await settlement.getAddress();
            const badSignature = await signLockCommitment(
                outsider, contractAddress, intentId, tokenIn, tokenOut, 0n, deadline
            );

            // The signature will recover to outsider, not trader
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
                        0n,
                        deadline,
                        badSignature
                    )
            ).to.be.revertedWithCustomError(settlement, "InvalidTraderSignature");
        });

        it("should revert with SameTokenSwap when tokenIn equals tokenOut", async function () {
            const { settlement, settler, trader, tokenIn } =
                await loadFixture(deployFixture);

            const deadline = BigInt((await time.latest()) + 3600);
            const intentId = ethers.id("same-token");

            const contractAddress = await settlement.getAddress();
            const signature = await signLockCommitment(
                trader, contractAddress, intentId, tokenIn, tokenIn, 0n, deadline
            );

            await expect(
                settlement
                    .connect(settler)
                    .lockPrivateCollateral(
                        intentId,
                        trader.address,
                        tokenIn,
                        tokenIn, // same as tokenIn
                        1000n,
                        2000n,
                        0n,
                        deadline,
                        signature
                    )
            ).to.be.revertedWithCustomError(settlement, "SameTokenSwap");
        });
    });

    // -----------------------------------------------------------------
    //  3. Deadline checks
    // -----------------------------------------------------------------

    describe("Deadline validation", function () {
        it("should revert with DeadlineExpired when deadline is in the past", async function () {
            const { settlement, settler, trader, tokenIn, tokenOut } =
                await loadFixture(deployFixture);

            const pastDeadline = BigInt((await time.latest()) - 1);
            const intentId = ethers.id("past-dl");
            const contractAddress = await settlement.getAddress();
            const signature = await signLockCommitment(
                trader, contractAddress, intentId, tokenIn, tokenOut, 0n, pastDeadline
            );

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
                        0n,
                        pastDeadline,
                        signature
                    )
            ).to.be.revertedWithCustomError(settlement, "DeadlineExpired");
        });

        it("should revert with DeadlineExpired when deadline equals block.timestamp", async function () {
            const { settlement, settler, trader, tokenIn, tokenOut } =
                await loadFixture(deployFixture);

            // deadline <= block.timestamp triggers revert
            const currentTime = BigInt(await time.latest());
            const intentId = ethers.id("exact-dl");
            const contractAddress = await settlement.getAddress();
            const signature = await signLockCommitment(
                trader, contractAddress, intentId, tokenIn, tokenOut, 0n, currentTime
            );

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
                        0n,
                        currentTime, // equal to block.timestamp at tx time or earlier
                        signature
                    )
            ).to.be.revertedWithCustomError(settlement, "DeadlineExpired");
        });
    });

    // -----------------------------------------------------------------
    //  4. Role checks
    // -----------------------------------------------------------------

    describe("Role-based access control", function () {
        it("should revert lockPrivateCollateral for non-SETTLER_ROLE", async function () {
            const { settlement, outsider, trader, tokenIn, tokenOut, SETTLER_ROLE } =
                await loadFixture(deployFixture);

            const deadline = BigInt((await time.latest()) + 3600);
            const intentId = ethers.id("no-role");
            const contractAddress = await settlement.getAddress();
            const signature = await signLockCommitment(
                trader, contractAddress, intentId, tokenIn, tokenOut, 0n, deadline
            );

            await expect(
                settlement
                    .connect(outsider)
                    .lockPrivateCollateral(
                        intentId,
                        trader.address,
                        tokenIn,
                        tokenOut,
                        1000n,
                        2000n,
                        0n,
                        deadline,
                        signature
                    )
            )
                .to.be.revertedWithCustomError(settlement, "AccessControlUnauthorizedAccount")
                .withArgs(outsider.address, SETTLER_ROLE);
        });

        it("should revert settlePrivateIntent for non-SETTLER_ROLE", async function () {
            const { settlement, outsider, solver, SETTLER_ROLE } =
                await loadFixture(deployFixture);

            await expect(
                settlement
                    .connect(outsider)
                    .settlePrivateIntent(
                        ethers.id("no-role-settle"),
                        solver.address
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

        it("should revert grantSettlerRole for non-DEFAULT_ADMIN_ROLE", async function () {
            const { settlement, outsider } = await loadFixture(deployFixture);
            const DEFAULT_ADMIN_ROLE = await settlement.DEFAULT_ADMIN_ROLE();

            await expect(
                settlement.connect(outsider).grantSettlerRole(outsider.address)
            )
                .to.be.revertedWithCustomError(settlement, "AccessControlUnauthorizedAccount")
                .withArgs(outsider.address, DEFAULT_ADMIN_ROLE);
        });
    });

    // -----------------------------------------------------------------
    //  5. Status transitions
    // -----------------------------------------------------------------

    describe("Status transitions", function () {
        it("should revert with CollateralAlreadyLocked on duplicate lock", async function () {
            const { settlement, settler, trader, tokenIn, tokenOut } =
                await loadFixture(deployFixture);

            const deadline = BigInt((await time.latest()) + 3600);
            const intentId = ethers.id("dup-lock");

            // First lock
            await lockWithSignature(
                settlement, settler, trader,
                intentId, tokenIn, tokenOut,
                1000n, 2000n, 0n, deadline
            );

            // Duplicate lock with same intentId (nonce has incremented to 1)
            const contractAddress = await settlement.getAddress();
            const signature = await signLockCommitment(
                trader, contractAddress, intentId, tokenIn, tokenOut, 1n, deadline
            );

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
                        deadline,
                        signature
                    )
            ).to.be.revertedWithCustomError(settlement, "CollateralAlreadyLocked");
        });

        it("should revert settlePrivateIntent with CollateralNotLocked when not locked", async function () {
            const { settlement, settler, solver } =
                await loadFixture(deployFixture);

            // Attempt to settle a non-existent intent (EMPTY status)
            await expect(
                settlement
                    .connect(settler)
                    .settlePrivateIntent(
                        ethers.id("no-lock"),
                        solver.address
                    )
            ).to.be.revertedWithCustomError(settlement, "CollateralNotLocked");
        });

        it("should revert settlePrivateIntent with InvalidAddress for zero solver", async function () {
            const { settlement, settler } =
                await loadFixture(deployFixture);

            await expect(
                settlement
                    .connect(settler)
                    .settlePrivateIntent(
                        ethers.id("zero-solver"),
                        ethers.ZeroAddress
                    )
            ).to.be.revertedWithCustomError(settlement, "InvalidAddress");
        });

        // NOTE: Full settlePrivateIntent success path requires COTI MPC
        // precompile (MpcCore.onBoard, MpcCore.gt, MpcCore.decrypt, etc.).
        // Requires COTI testnet -- cannot test on Hardhat.

        it("should revert lock with InvalidAddress for zero trader", async function () {
            const { settlement, settler, tokenIn, tokenOut } =
                await loadFixture(deployFixture);

            const deadline = BigInt((await time.latest()) + 3600);

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
                        deadline,
                        "0x" + "00".repeat(65) // dummy signature
                    )
            ).to.be.revertedWithCustomError(settlement, "InvalidAddress");
        });

        it("should revert lock with InvalidAddress for zero tokenIn", async function () {
            const { settlement, settler, trader, tokenOut } =
                await loadFixture(deployFixture);

            const deadline = BigInt((await time.latest()) + 3600);

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
                        deadline,
                        "0x" + "00".repeat(65) // dummy signature
                    )
            ).to.be.revertedWithCustomError(settlement, "InvalidAddress");
        });

        it("should revert lock with InvalidAddress for zero tokenOut", async function () {
            const { settlement, settler, trader, tokenIn } =
                await loadFixture(deployFixture);

            const deadline = BigInt((await time.latest()) + 3600);

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
                        deadline,
                        "0x" + "00".repeat(65) // dummy signature
                    )
            ).to.be.revertedWithCustomError(settlement, "InvalidAddress");
        });
    });

    // -----------------------------------------------------------------
    //  6. Cancel
    // -----------------------------------------------------------------

    describe("cancelPrivateIntent", function () {
        it("should allow trader to cancel a locked intent after MIN_LOCK_DURATION", async function () {
            const { settlement, settler, trader, tokenIn, tokenOut } =
                await loadFixture(deployFixture);

            const deadline = BigInt((await time.latest()) + 7200);
            const intentId = ethers.id("cancel-1");

            await lockWithSignature(
                settlement, settler, trader,
                intentId, tokenIn, tokenOut,
                1000n, 2000n, 0n, deadline
            );

            // Advance past MIN_LOCK_DURATION (5 minutes)
            await time.increase(301);

            await expect(settlement.connect(trader).cancelPrivateIntent(intentId))
                .to.emit(settlement, "PrivateIntentCancelled")
                .withArgs(intentId, trader.address);

            // Status should be CANCELLED (enum index 3)
            const col = await settlement.getPrivateCollateral(intentId);
            expect(col.status).to.equal(3n);
        });

        it("should revert cancel before MIN_LOCK_DURATION has elapsed", async function () {
            const { settlement, settler, trader, tokenIn, tokenOut } =
                await loadFixture(deployFixture);

            const deadline = BigInt((await time.latest()) + 7200);
            const intentId = ethers.id("cancel-too-early");

            await lockWithSignature(
                settlement, settler, trader,
                intentId, tokenIn, tokenOut,
                1000n, 2000n, 0n, deadline
            );

            // Try to cancel immediately (before 5 min elapsed)
            await expect(
                settlement.connect(trader).cancelPrivateIntent(intentId)
            ).to.be.revertedWithCustomError(settlement, "TooEarlyToCancel");
        });

        it("should revert when non-trader attempts to cancel", async function () {
            const { settlement, settler, trader, outsider, tokenIn, tokenOut } =
                await loadFixture(deployFixture);

            const deadline = BigInt((await time.latest()) + 7200);
            const intentId = ethers.id("cancel-nottrader");

            await lockWithSignature(
                settlement, settler, trader,
                intentId, tokenIn, tokenOut,
                1000n, 2000n, 0n, deadline
            );

            await time.increase(301);

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

            const deadline = BigInt((await time.latest()) + 7200);
            const intentId = ethers.id("cancel-twice");

            await lockWithSignature(
                settlement, settler, trader,
                intentId, tokenIn, tokenOut,
                1000n, 2000n, 0n, deadline
            );

            await time.increase(301);

            // Cancel once
            await settlement.connect(trader).cancelPrivateIntent(intentId);

            // Cancel again -- status is CANCELLED, not LOCKED
            await expect(
                settlement.connect(trader).cancelPrivateIntent(intentId)
            ).to.be.revertedWithCustomError(settlement, "CollateralNotLocked");
        });

        it("should revert cancel when contract is paused", async function () {
            const { settlement, admin, settler, trader, tokenIn, tokenOut } =
                await loadFixture(deployFixture);

            const deadline = BigInt((await time.latest()) + 7200);
            const intentId = ethers.id("cancel-paused");

            await lockWithSignature(
                settlement, settler, trader,
                intentId, tokenIn, tokenOut,
                1000n, 2000n, 0n, deadline
            );

            await time.increase(301);
            await settlement.connect(admin).pause();

            await expect(
                settlement.connect(trader).cancelPrivateIntent(intentId)
            ).to.be.revertedWithCustomError(settlement, "EnforcedPause");
        });
    });

    // -----------------------------------------------------------------
    //  7. Pause / Unpause
    // -----------------------------------------------------------------

    describe("Pausable", function () {
        it("should pause and block lockPrivateCollateral", async function () {
            const { settlement, admin, settler, trader, tokenIn, tokenOut } =
                await loadFixture(deployFixture);

            await settlement.connect(admin).pause();

            const deadline = BigInt((await time.latest()) + 3600);
            const intentId = ethers.id("paused-lock");
            const contractAddress = await settlement.getAddress();
            const signature = await signLockCommitment(
                trader, contractAddress, intentId, tokenIn, tokenOut, 0n, deadline
            );

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
                        0n,
                        deadline,
                        signature
                    )
            ).to.be.revertedWithCustomError(settlement, "EnforcedPause");
        });

        it("should pause and block settlePrivateIntent", async function () {
            const { settlement, admin, settler, solver } =
                await loadFixture(deployFixture);

            await settlement.connect(admin).pause();

            await expect(
                settlement
                    .connect(settler)
                    .settlePrivateIntent(
                        ethers.id("paused-settle"),
                        solver.address
                    )
            ).to.be.revertedWithCustomError(settlement, "EnforcedPause");
        });

        it("should unpause and allow lockPrivateCollateral again", async function () {
            const { settlement, admin, settler, trader, tokenIn, tokenOut } =
                await loadFixture(deployFixture);

            await settlement.connect(admin).pause();
            await settlement.connect(admin).unpause();

            const deadline = BigInt((await time.latest()) + 3600);

            await expect(
                lockWithSignature(
                    settlement, settler, trader,
                    ethers.id("unpaused-lock"), tokenIn, tokenOut,
                    1000n, 2000n, 0n, deadline
                )
            ).to.emit(settlement, "PrivateCollateralLocked");
        });

        it("should revert pause for non-DEFAULT_ADMIN_ROLE", async function () {
            const { settlement, outsider } = await loadFixture(deployFixture);
            const DEFAULT_ADMIN_ROLE = await settlement.DEFAULT_ADMIN_ROLE();

            await expect(settlement.connect(outsider).pause())
                .to.be.revertedWithCustomError(settlement, "AccessControlUnauthorizedAccount")
                .withArgs(outsider.address, DEFAULT_ADMIN_ROLE);
        });

        it("should revert unpause for non-DEFAULT_ADMIN_ROLE", async function () {
            const { settlement, admin, outsider } = await loadFixture(deployFixture);
            const DEFAULT_ADMIN_ROLE = await settlement.DEFAULT_ADMIN_ROLE();

            await settlement.connect(admin).pause();

            await expect(settlement.connect(outsider).unpause())
                .to.be.revertedWithCustomError(settlement, "AccessControlUnauthorizedAccount")
                .withArgs(outsider.address, DEFAULT_ADMIN_ROLE);
        });
    });

    // -----------------------------------------------------------------
    //  8. Fee recipients
    // -----------------------------------------------------------------

    describe("updateFeeRecipients", function () {
        // NOTE: updateFeeRecipients calls _migrateFees() which uses
        // MpcCore.onBoard() -- a COTI MPC precompile that reverts on
        // Hardhat. The full success path can only be tested on COTI
        // testnet. Here we test validation logic only.
        it.skip("should update fee recipients and emit event (Requires COTI testnet -- _migrateFees uses MPC)", function () {
            // updateFeeRecipients -> _migrateFees -> MpcCore.onBoard
            // Cannot run on Hardhat.
        });

        it("should revert when oddao is zero address", async function () {
            const { settlement, admin, solver, outsider } = await loadFixture(deployFixture);

            await expect(
                settlement
                    .connect(admin)
                    .updateFeeRecipients(ethers.ZeroAddress, solver.address, outsider.address)
            ).to.be.revertedWithCustomError(settlement, "InvalidAddress");
        });

        it("should revert when stakingPool is zero address", async function () {
            const { settlement, admin, trader, outsider } = await loadFixture(deployFixture);

            await expect(
                settlement
                    .connect(admin)
                    .updateFeeRecipients(trader.address, ethers.ZeroAddress, outsider.address)
            ).to.be.revertedWithCustomError(settlement, "InvalidAddress");
        });

        it("should revert when protocolTreasury is zero address", async function () {
            const { settlement, admin, trader, solver } = await loadFixture(deployFixture);

            await expect(
                settlement
                    .connect(admin)
                    .updateFeeRecipients(trader.address, solver.address, ethers.ZeroAddress)
            ).to.be.revertedWithCustomError(settlement, "InvalidAddress");
        });

        it("should revert for non-DEFAULT_ADMIN_ROLE", async function () {
            const { settlement, outsider, trader, solver } =
                await loadFixture(deployFixture);
            const DEFAULT_ADMIN_ROLE = await settlement.DEFAULT_ADMIN_ROLE();

            await expect(
                settlement
                    .connect(outsider)
                    .updateFeeRecipients(trader.address, solver.address, outsider.address)
            )
                .to.be.revertedWithCustomError(settlement, "AccessControlUnauthorizedAccount")
                .withArgs(outsider.address, DEFAULT_ADMIN_ROLE);
        });
    });

    // -----------------------------------------------------------------
    //  9. Ossification (two-step)
    // -----------------------------------------------------------------

    describe("Ossification", function () {
        it("should request ossification and emit OssificationRequested", async function () {
            const { settlement, admin } = await loadFixture(deployFixture);

            await expect(settlement.connect(admin).requestOssification())
                .to.emit(settlement, "OssificationRequested");
        });

        it("should confirm ossification after delay and emit ContractOssified", async function () {
            const { settlement, admin } = await loadFixture(deployFixture);

            await settlement.connect(admin).requestOssification();

            // Advance time past OSSIFICATION_DELAY (7 days)
            await time.increase(7 * 24 * 60 * 60 + 1);

            await expect(settlement.connect(admin).confirmOssification())
                .to.emit(settlement, "ContractOssified")
                .withArgs(await settlement.getAddress());

            expect(await settlement.isOssified()).to.equal(true);
        });

        it("should revert confirmOssification before delay has elapsed", async function () {
            const { settlement, admin } = await loadFixture(deployFixture);

            await settlement.connect(admin).requestOssification();

            // Try to confirm immediately
            await expect(
                settlement.connect(admin).confirmOssification()
            ).to.be.revertedWithCustomError(settlement, "OssificationDelayNotElapsed");
        });

        it("should revert confirmOssification when not requested", async function () {
            const { settlement, admin } = await loadFixture(deployFixture);

            await expect(
                settlement.connect(admin).confirmOssification()
            ).to.be.revertedWithCustomError(settlement, "OssificationNotRequested");
        });

        it("should block UUPS upgrade after ossification", async function () {
            const { settlement, admin } = await loadFixture(deployFixture);

            await settlement.connect(admin).requestOssification();
            await time.increase(7 * 24 * 60 * 60 + 1);
            await settlement.connect(admin).confirmOssification();

            const V2Factory = await ethers.getContractFactory("PrivateDEXSettlement");
            await expect(
                upgrades.upgradeProxy(
                    await settlement.getAddress(),
                    V2Factory,
                    { constructorArgs: [ethers.ZeroAddress] }
                )
            ).to.be.revertedWithCustomError(settlement, "ContractIsOssified");
        });

        it("should revert requestOssification for non-DEFAULT_ADMIN_ROLE", async function () {
            const { settlement, outsider } = await loadFixture(deployFixture);
            const DEFAULT_ADMIN_ROLE = await settlement.DEFAULT_ADMIN_ROLE();

            await expect(settlement.connect(outsider).requestOssification())
                .to.be.revertedWithCustomError(settlement, "AccessControlUnauthorizedAccount")
                .withArgs(outsider.address, DEFAULT_ADMIN_ROLE);
        });

        it("should revert confirmOssification for non-DEFAULT_ADMIN_ROLE", async function () {
            const { settlement, admin, outsider } = await loadFixture(deployFixture);
            const DEFAULT_ADMIN_ROLE = await settlement.DEFAULT_ADMIN_ROLE();

            await settlement.connect(admin).requestOssification();
            await time.increase(7 * 24 * 60 * 60 + 1);

            await expect(settlement.connect(outsider).confirmOssification())
                .to.be.revertedWithCustomError(settlement, "AccessControlUnauthorizedAccount")
                .withArgs(outsider.address, DEFAULT_ADMIN_ROLE);
        });

        it("should allow upgrade before ossification", async function () {
            const { settlement } = await loadFixture(deployFixture);

            // Verify not ossified
            expect(await settlement.isOssified()).to.equal(false);

            // Upgrade should succeed (same implementation -- validates _authorizeUpgrade path)
            const V2Factory = await ethers.getContractFactory("PrivateDEXSettlement");
            const upgraded = await upgrades.upgradeProxy(
                await settlement.getAddress(),
                V2Factory,
                { constructorArgs: [ethers.ZeroAddress] }
            );

            // Contract should still be functional
            expect(await upgraded.isOssified()).to.equal(false);
            expect(await upgraded.totalSettlements()).to.equal(0n);
        });
    });

    // -----------------------------------------------------------------
    //  10. View functions
    // -----------------------------------------------------------------

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

            const deadline = BigInt((await time.latest()) + 3600);

            // Lock three times for same trader
            for (let i = 0; i < 3; i++) {
                await lockWithSignature(
                    settlement, settler, trader,
                    ethers.id(`view-nonce-${i}`), tokenIn, tokenOut,
                    1000n, 2000n, BigInt(i), deadline
                );
            }

            expect(await settlement.getNonce(trader.address)).to.equal(3n);
        });

        it("getFeeRecipients should return current recipients", async function () {
            const { settlement, oddao, stakingPool, protocolTreasury } =
                await loadFixture(deployFixture);

            const recipients = await settlement.getFeeRecipients();
            expect(recipients.oddao).to.equal(oddao.address);
            expect(recipients.stakingPool).to.equal(stakingPool.address);
            expect(recipients.protocolTreasury).to.equal(protocolTreasury.address);
        });

        it("getFeeRecord should return empty record for unknown intentId", async function () {
            const { settlement } = await loadFixture(deployFixture);

            const record = await settlement.getFeeRecord(ethers.id("no-fees"));
            // Encrypted fields are ctUint64 (uint256), default 0
            expect(record.oddaoFee).to.equal(0n);
            expect(record.stakingPoolFee).to.equal(0n);
            expect(record.protocolFee).to.equal(0n);
        });

        it("getAccumulatedFees should return 0 for caller querying own fees", async function () {
            const { settlement, admin } = await loadFixture(deployFixture);

            // Admin queries their own accumulated fees (access control allows this)
            expect(await settlement.connect(admin).getAccumulatedFees(admin.address)).to.equal(0n);
        });

        it("getAccumulatedFees should revert for unauthorized caller", async function () {
            const { settlement, outsider, oddao } = await loadFixture(deployFixture);

            // outsider queries oddao's fees -- should revert NotAuthorized
            await expect(
                settlement.connect(outsider).getAccumulatedFees(oddao.address)
            ).to.be.revertedWithCustomError(settlement, "NotAuthorized");
        });

        it("getAccumulatedFees should allow admin to query any address", async function () {
            const { settlement, admin, oddao } = await loadFixture(deployFixture);

            // Admin can query anyone's fees
            expect(await settlement.connect(admin).getAccumulatedFees(oddao.address)).to.equal(0n);
        });
    });

    // -----------------------------------------------------------------
    //  11. Constants
    // -----------------------------------------------------------------

    describe("Constants", function () {
        it("should expose correct role hashes", async function () {
            const { settlement } = await loadFixture(deployFixture);

            expect(await settlement.SETTLER_ROLE()).to.equal(
                ethers.id("SETTLER_ROLE")
            );
            expect(await settlement.DEFAULT_ADMIN_ROLE()).to.equal(
                ethers.ZeroHash
            );
        });

        it("should expose correct fee constants", async function () {
            const { settlement } = await loadFixture(deployFixture);

            expect(await settlement.BASIS_POINTS_DIVISOR()).to.equal(10000n);
            expect(await settlement.ODDAO_SHARE_BPS()).to.equal(7000n);
            expect(await settlement.STAKING_POOL_SHARE_BPS()).to.equal(2000n);
            expect(await settlement.PROTOCOL_SHARE_BPS()).to.equal(1000n);
            expect(await settlement.TRADING_FEE_BPS()).to.equal(20n);
        });

        it("fee share BPS should sum to BASIS_POINTS_DIVISOR", async function () {
            const { settlement } = await loadFixture(deployFixture);

            const oddao = await settlement.ODDAO_SHARE_BPS();
            const staking = await settlement.STAKING_POOL_SHARE_BPS();
            const protocol = await settlement.PROTOCOL_SHARE_BPS();

            expect(oddao + staking + protocol).to.equal(
                await settlement.BASIS_POINTS_DIVISOR()
            );
        });

        it("should expose MIN_LOCK_DURATION as 5 minutes", async function () {
            const { settlement } = await loadFixture(deployFixture);

            expect(await settlement.MIN_LOCK_DURATION()).to.equal(300n);
        });

        it("should expose OSSIFICATION_DELAY as 7 days", async function () {
            const { settlement } = await loadFixture(deployFixture);

            expect(await settlement.OSSIFICATION_DELAY()).to.equal(
                BigInt(7 * 24 * 60 * 60)
            );
        });

        it("should expose SCALING_FACTOR as 1e12", async function () {
            const { settlement } = await loadFixture(deployFixture);

            expect(await settlement.SCALING_FACTOR()).to.equal(
                BigInt(1e12)
            );
        });
    });

    // -----------------------------------------------------------------
    //  12. MPC-Dependent (Requires COTI Testnet)
    // -----------------------------------------------------------------

    describe("MPC-Dependent (COTI testnet only)", function () {
        // These tests document what CANNOT be tested on Hardhat due to
        // MPC precompile requirements. They should be run on COTI testnet.

        it.skip("settlePrivateIntent -- full settlement with encrypted amounts (Requires COTI testnet)", function () {
            // MpcCore.onBoard, MpcCore.gt, MpcCore.decrypt, MpcCore.checkedMul,
            // MpcCore.div, MpcCore.checkedAdd, MpcCore.checkedSub, MpcCore.offBoard
            // all call COTI MPC precompiles that revert on Hardhat.
        });

        it.skip("settlePrivateIntent -- InsufficientCollateral for zero trader amount (Requires COTI testnet)", function () {
            // MpcCore.gt comparison followed by MpcCore.decrypt to get
            // bool result -- requires MPC precompile.
        });

        it.skip("settlePrivateIntent -- InsufficientCollateral for zero solver amount (Requires COTI testnet)", function () {
            // Same as above -- MPC verification of solver collateral.
        });

        it.skip("settlePrivateIntent -- fee calculation and distribution (Requires COTI testnet)", function () {
            // 0.2% trading fee split 70/20/10 (ODDAO/StakingPool/ProtocolTreasury)
            // -- all encrypted arithmetic via MPC garbled circuits.
        });

        it.skip("settlePrivateIntent -- double settle should revert (Requires COTI testnet)", function () {
            // After successful settlement, status becomes SETTLED.
            // Second call should revert with CollateralNotLocked.
            // Cannot reach settled state without MPC.
        });

        it.skip("settlePrivateIntent -- settle after deadline should revert DeadlineExpired (Requires COTI testnet)", function () {
            // Would need to lock, advance time past deadline, then settle.
            // Lock works on Hardhat, but settle uses MPC -- cannot test.
        });

        it.skip("claimFees -- successful claim with encrypted balance (Requires COTI testnet)", function () {
            // MpcCore.onBoard, MpcCore.gt, MpcCore.decrypt, MpcCore.offBoard
            // all require MPC precompile.
        });

        it.skip("claimFees -- revert for zero balance (Requires COTI testnet)", function () {
            // NoFeesToClaim when no fees accumulated.
            // Comparison uses MPC.
        });

        it.skip("cancelPrivateIntent -- cannot cancel settled intent (Requires COTI testnet)", function () {
            // Need to first successfully settle (requires MPC), then
            // attempt cancel -- should revert CollateralNotLocked.
        });
    });

    // -----------------------------------------------------------------
    //  13. Events and interface
    // -----------------------------------------------------------------

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

        it("should have OssificationRequested event in ABI", async function () {
            const { settlement } = await loadFixture(deployFixture);
            const event = settlement.interface.getEvent("OssificationRequested");
            expect(event).to.not.be.undefined;
            expect(event.name).to.equal("OssificationRequested");
        });

        it("should have all custom errors in ABI", async function () {
            const { settlement } = await loadFixture(deployFixture);

            const expectedErrors = [
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
                "SameTokenSwap",
                "TooEarlyToCancel",
                "NoFeesToClaim",
                "NotAuthorized",
                "OssificationNotRequested",
                "OssificationDelayNotElapsed",
                "InvalidTraderSignature",
            ];

            for (const errorName of expectedErrors) {
                const errorFragment = settlement.interface.getError(errorName);
                expect(errorFragment, `Missing error: ${errorName}`).to.not.be.undefined;
                expect(errorFragment.name).to.equal(errorName);
            }
        });
    });
});
