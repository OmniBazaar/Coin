/**
 * PrivateDEX -- Non-MPC Logic Tests
 *
 * Tests all contract logic that does NOT require COTI MPC garbled circuits:
 *   1.  Initialization (roles, zero-address guards, initial state)
 *   2.  Access control (MATCHER_ROLE on trade functions, DEFAULT_ADMIN_ROLE on params)
 *   3.  Ossification (two-step: request -> delay -> confirm, blocks upgrades)
 *   4.  Pause / unpause (paused blocks state-changing functions)
 *   5.  Matcher role management (grant / revoke, zero-address guard)
 *   6.  Cancel order (only order owner, status checks)
 *   7.  Cleanup user orders (voluntary compaction)
 *   8.  View functions (getPrivacyStats, getUserOrdersPaginated, getOrderBook)
 *   9.  Constants (MATCHER_ROLE, DEFAULT_ADMIN_ROLE, MAX_ORDERS_PER_USER, etc.)
 *  10.  Events and errors in ABI
 *  11.  UUPS upgradeability (before and after ossification)
 *
 * MPC-dependent functions (submitPrivateOrder, executePrivateTrade,
 * canOrdersMatch, calculateMatchAmount, calculateTradeFees,
 * isOrderFullyFilled) CANNOT be tested on Hardhat -- they require the
 * COTI testnet MPC precompile. Those tests are marked with descriptive
 * skip comments.
 *
 * The contract uses MpcCore.setPublic64 / MpcCore.offBoard inside
 * submitPrivateOrder to initialize the encrypted zero for encFilled,
 * so even order submission reverts on Hardhat. All order-dependent
 * tests that need real on-chain orders (cancelPrivateOrder,
 * cleanupUserOrders, getOrderBook with data) are therefore also
 * MPC-dependent and documented as skipped with clear explanations.
 */

/* eslint-disable @typescript-eslint/no-var-requires */
const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");
const {
    time,
    loadFixture,
} = require("@nomicfoundation/hardhat-network-helpers");

describe("PrivateDEX", function () {
    /**
     * Shared deployment fixture.
     * Deploys the UUPS proxy with a single init arg: admin.
     * The constructor takes trustedForwarder_ (use address(0) to disable
     * meta-transactions in tests).
     */
    async function deployFixture() {
        const [admin, matcher, trader1, trader2, outsider, newAdmin] =
            await ethers.getSigners();

        const Factory = await ethers.getContractFactory("PrivateDEX");
        const dex = await upgrades.deployProxy(
            Factory,
            [admin.address],
            {
                initializer: "initialize",
                kind: "uups",
                constructorArgs: [ethers.ZeroAddress],
                unsafeAllow: ["constructor"],
            }
        );

        // Grant MATCHER_ROLE to the dedicated matcher signer
        const MATCHER_ROLE = await dex.MATCHER_ROLE();
        await dex.connect(admin).grantMatcherRole(matcher.address);

        const DEFAULT_ADMIN_ROLE = await dex.DEFAULT_ADMIN_ROLE();

        return {
            dex,
            admin,
            matcher,
            trader1,
            trader2,
            outsider,
            newAdmin,
            MATCHER_ROLE,
            DEFAULT_ADMIN_ROLE,
        };
    }

    // ─────────────────────────────────────────────────────────────────────
    //  1. Initialization
    // ─────────────────────────────────────────────────────────────────────

    describe("Initialization", function () {
        it("should grant DEFAULT_ADMIN_ROLE to admin", async function () {
            const { dex, admin, DEFAULT_ADMIN_ROLE } =
                await loadFixture(deployFixture);
            expect(
                await dex.hasRole(DEFAULT_ADMIN_ROLE, admin.address)
            ).to.be.true;
        });

        it("should grant DEFAULT_ADMIN_ROLE to admin (admin functions use DEFAULT_ADMIN_ROLE)", async function () {
            const { dex, admin, DEFAULT_ADMIN_ROLE } =
                await loadFixture(deployFixture);
            expect(
                await dex.hasRole(DEFAULT_ADMIN_ROLE, admin.address)
            ).to.be.true;
        });

        it("should grant MATCHER_ROLE to admin", async function () {
            const { dex, admin, MATCHER_ROLE } =
                await loadFixture(deployFixture);
            expect(
                await dex.hasRole(MATCHER_ROLE, admin.address)
            ).to.be.true;
        });

        it("should start with totalOrders = 0", async function () {
            const { dex } = await loadFixture(deployFixture);
            expect(await dex.totalOrders()).to.equal(0n);
        });

        it("should start with totalTrades = 0", async function () {
            const { dex } = await loadFixture(deployFixture);
            expect(await dex.totalTrades()).to.equal(0n);
        });

        it("should start with totalActiveOrders = 0", async function () {
            const { dex } = await loadFixture(deployFixture);
            expect(await dex.totalActiveOrders()).to.equal(0n);
        });

        it("should start unossified", async function () {
            const { dex } = await loadFixture(deployFixture);
            expect(await dex.isOssified()).to.equal(false);
        });

        it("should start with ossificationRequestTime = 0", async function () {
            const { dex } = await loadFixture(deployFixture);
            expect(await dex.ossificationRequestTime()).to.equal(0n);
        });

        it("should start unpaused", async function () {
            const { dex } = await loadFixture(deployFixture);
            expect(await dex.paused()).to.equal(false);
        });

        it("should revert when admin is zero address", async function () {
            const Factory =
                await ethers.getContractFactory("PrivateDEX");
            await expect(
                upgrades.deployProxy(
                    Factory,
                    [ethers.ZeroAddress],
                    {
                        initializer: "initialize",
                        kind: "uups",
                        constructorArgs: [ethers.ZeroAddress],
                        unsafeAllow: ["constructor"],
                    }
                )
            ).to.be.revertedWithCustomError(Factory, "InvalidAddress");
        });

        it("should not be initializable twice", async function () {
            const { dex, admin } = await loadFixture(deployFixture);
            await expect(
                dex.initialize(admin.address)
            ).to.be.revertedWithCustomError(dex, "InvalidInitialization");
        });

        it("should return correct privacy stats at initialization", async function () {
            const { dex } = await loadFixture(deployFixture);
            const stats = await dex.getPrivacyStats();
            expect(stats.totalOrdersCount).to.equal(0n);
            expect(stats.totalTradesCount).to.equal(0n);
            expect(stats.activeOrdersCount).to.equal(0n);
        });
    });

    // ─────────────────────────────────────────────────────────────────────
    //  2. Access control
    // ─────────────────────────────────────────────────────────────────────

    describe("Access control", function () {
        it("should revert canOrdersMatch for non-MATCHER_ROLE", async function () {
            const { dex, outsider, MATCHER_ROLE } =
                await loadFixture(deployFixture);
            const fakeId = ethers.id("fake-buy");
            const fakeId2 = ethers.id("fake-sell");

            await expect(
                dex.connect(outsider).canOrdersMatch(fakeId, fakeId2)
            )
                .to.be.revertedWithCustomError(
                    dex,
                    "AccessControlUnauthorizedAccount"
                )
                .withArgs(outsider.address, MATCHER_ROLE);
        });

        it("should revert calculateMatchAmount for non-MATCHER_ROLE", async function () {
            const { dex, outsider, MATCHER_ROLE } =
                await loadFixture(deployFixture);
            const fakeId = ethers.id("fake-buy");
            const fakeId2 = ethers.id("fake-sell");

            await expect(
                dex
                    .connect(outsider)
                    .calculateMatchAmount(fakeId, fakeId2)
            )
                .to.be.revertedWithCustomError(
                    dex,
                    "AccessControlUnauthorizedAccount"
                )
                .withArgs(outsider.address, MATCHER_ROLE);
        });

        it("should revert calculateTradeFees for non-MATCHER_ROLE", async function () {
            const { dex, outsider, MATCHER_ROLE } =
                await loadFixture(deployFixture);

            await expect(
                dex.connect(outsider).calculateTradeFees(1000n, 100)
            )
                .to.be.revertedWithCustomError(
                    dex,
                    "AccessControlUnauthorizedAccount"
                )
                .withArgs(outsider.address, MATCHER_ROLE);
        });

        it("should revert executePrivateTrade for non-MATCHER_ROLE", async function () {
            const { dex, outsider, MATCHER_ROLE } =
                await loadFixture(deployFixture);
            const fakeId = ethers.id("fake-buy");
            const fakeId2 = ethers.id("fake-sell");

            await expect(
                dex
                    .connect(outsider)
                    .executePrivateTrade(fakeId, fakeId2)
            )
                .to.be.revertedWithCustomError(
                    dex,
                    "AccessControlUnauthorizedAccount"
                )
                .withArgs(outsider.address, MATCHER_ROLE);
        });

        it("should revert pause for non-DEFAULT_ADMIN_ROLE", async function () {
            const { dex, outsider, DEFAULT_ADMIN_ROLE } =
                await loadFixture(deployFixture);

            await expect(dex.connect(outsider).pause())
                .to.be.revertedWithCustomError(
                    dex,
                    "AccessControlUnauthorizedAccount"
                )
                .withArgs(outsider.address, DEFAULT_ADMIN_ROLE);
        });

        it("should revert unpause for non-DEFAULT_ADMIN_ROLE", async function () {
            const { dex, admin, outsider, DEFAULT_ADMIN_ROLE } =
                await loadFixture(deployFixture);

            await dex.connect(admin).pause();

            await expect(dex.connect(outsider).unpause())
                .to.be.revertedWithCustomError(
                    dex,
                    "AccessControlUnauthorizedAccount"
                )
                .withArgs(outsider.address, DEFAULT_ADMIN_ROLE);
        });

        it("should revert grantMatcherRole for non-DEFAULT_ADMIN_ROLE", async function () {
            const { dex, outsider, DEFAULT_ADMIN_ROLE } =
                await loadFixture(deployFixture);

            await expect(
                dex
                    .connect(outsider)
                    .grantMatcherRole(outsider.address)
            )
                .to.be.revertedWithCustomError(
                    dex,
                    "AccessControlUnauthorizedAccount"
                )
                .withArgs(outsider.address, DEFAULT_ADMIN_ROLE);
        });

        it("should revert revokeMatcherRole for non-DEFAULT_ADMIN_ROLE", async function () {
            const { dex, outsider, matcher, DEFAULT_ADMIN_ROLE } =
                await loadFixture(deployFixture);

            await expect(
                dex
                    .connect(outsider)
                    .revokeMatcherRole(matcher.address)
            )
                .to.be.revertedWithCustomError(
                    dex,
                    "AccessControlUnauthorizedAccount"
                )
                .withArgs(outsider.address, DEFAULT_ADMIN_ROLE);
        });

        it("should revert requestOssification for non-DEFAULT_ADMIN_ROLE", async function () {
            const { dex, outsider, DEFAULT_ADMIN_ROLE } =
                await loadFixture(deployFixture);

            await expect(
                dex.connect(outsider).requestOssification()
            )
                .to.be.revertedWithCustomError(
                    dex,
                    "AccessControlUnauthorizedAccount"
                )
                .withArgs(outsider.address, DEFAULT_ADMIN_ROLE);
        });

        it("should revert confirmOssification for non-DEFAULT_ADMIN_ROLE", async function () {
            const { dex, admin, outsider, DEFAULT_ADMIN_ROLE } =
                await loadFixture(deployFixture);

            // First request ossification as admin
            await dex.connect(admin).requestOssification();
            // Advance time past delay
            await time.increase(7 * 24 * 60 * 60 + 1);

            await expect(
                dex.connect(outsider).confirmOssification()
            )
                .to.be.revertedWithCustomError(
                    dex,
                    "AccessControlUnauthorizedAccount"
                )
                .withArgs(outsider.address, DEFAULT_ADMIN_ROLE);
        });
    });

    // ─────────────────────────────────────────────────────────────────────
    //  3. Ossification (two-step with 7-day delay)
    // ─────────────────────────────────────────────────────────────────────

    describe("Ossification", function () {
        it("should emit OssificationRequested on requestOssification", async function () {
            const { dex, admin } = await loadFixture(deployFixture);

            const tx = await dex.connect(admin).requestOssification();
            const receipt = await tx.wait();
            const block = await ethers.provider.getBlock(
                receipt.blockNumber
            );

            await expect(tx)
                .to.emit(dex, "OssificationRequested")
                .withArgs(await dex.getAddress(), block.timestamp);
        });

        it("should set ossificationRequestTime on request", async function () {
            const { dex, admin } = await loadFixture(deployFixture);

            await dex.connect(admin).requestOssification();
            const requestTime = await dex.ossificationRequestTime();
            expect(requestTime).to.be.gt(0n);
        });

        it("should revert confirmOssification when not requested", async function () {
            const { dex, admin } = await loadFixture(deployFixture);

            await expect(
                dex.connect(admin).confirmOssification()
            ).to.be.revertedWithCustomError(
                dex,
                "OssificationNotRequested"
            );
        });

        it("should revert confirmOssification before delay elapses", async function () {
            const { dex, admin } = await loadFixture(deployFixture);

            await dex.connect(admin).requestOssification();

            // Advance only 6 days (delay is 7 days)
            await time.increase(6 * 24 * 60 * 60);

            await expect(
                dex.connect(admin).confirmOssification()
            ).to.be.revertedWithCustomError(
                dex,
                "OssificationDelayNotElapsed"
            );
        });

        it("should revert confirmOssification at exactly delay boundary", async function () {
            const { dex, admin } = await loadFixture(deployFixture);

            await dex.connect(admin).requestOssification();

            // Advance 7 days minus 2 seconds: time.increase mines a block at T+N,
            // then confirmOssification mines at T+N+1, so we need N = 7d-2 to stay under the delay
            await time.increase(7 * 24 * 60 * 60 - 2);

            await expect(
                dex.connect(admin).confirmOssification()
            ).to.be.revertedWithCustomError(
                dex,
                "OssificationDelayNotElapsed"
            );
        });

        it("should confirm ossification after delay and emit ContractOssified", async function () {
            const { dex, admin } = await loadFixture(deployFixture);

            await dex.connect(admin).requestOssification();

            // Advance past 7 days
            await time.increase(7 * 24 * 60 * 60 + 1);

            await expect(
                dex.connect(admin).confirmOssification()
            )
                .to.emit(dex, "ContractOssified")
                .withArgs(await dex.getAddress());

            expect(await dex.isOssified()).to.equal(true);
        });

        it("should block UUPS upgrade after ossification", async function () {
            const { dex, admin } = await loadFixture(deployFixture);

            await dex.connect(admin).requestOssification();
            await time.increase(7 * 24 * 60 * 60 + 1);
            await dex.connect(admin).confirmOssification();

            const V2Factory =
                await ethers.getContractFactory("PrivateDEX");
            await expect(
                upgrades.upgradeProxy(
                    await dex.getAddress(),
                    V2Factory,
                    {
                        constructorArgs: [ethers.ZeroAddress],
                        unsafeAllow: ["constructor"],
                    }
                )
            ).to.be.revertedWithCustomError(dex, "ContractIsOssified");
        });

        it("should allow upgrade before ossification", async function () {
            const { dex } = await loadFixture(deployFixture);

            expect(await dex.isOssified()).to.equal(false);

            const V2Factory =
                await ethers.getContractFactory("PrivateDEX");
            const upgraded = await upgrades.upgradeProxy(
                await dex.getAddress(),
                V2Factory,
                {
                    constructorArgs: [ethers.ZeroAddress],
                    unsafeAllow: ["constructor"],
                }
            );

            expect(await upgraded.isOssified()).to.equal(false);
            expect(await upgraded.totalOrders()).to.equal(0n);
        });

        it("should allow re-requesting ossification (resets timer)", async function () {
            const { dex, admin } = await loadFixture(deployFixture);

            await dex.connect(admin).requestOssification();
            const firstTime = await dex.ossificationRequestTime();

            // Advance 3 days then re-request
            await time.increase(3 * 24 * 60 * 60);
            await dex.connect(admin).requestOssification();
            const secondTime = await dex.ossificationRequestTime();

            expect(secondTime).to.be.gt(firstTime);
        });

        it("should return false from isOssified before ossification", async function () {
            const { dex } = await loadFixture(deployFixture);
            expect(await dex.isOssified()).to.equal(false);
        });

        it("should return true from isOssified after ossification", async function () {
            const { dex, admin } = await loadFixture(deployFixture);

            await dex.connect(admin).requestOssification();
            await time.increase(7 * 24 * 60 * 60 + 1);
            await dex.connect(admin).confirmOssification();

            expect(await dex.isOssified()).to.equal(true);
        });
    });

    // ─────────────────────────────────────────────────────────────────────
    //  4. Pause / unpause
    // ─────────────────────────────────────────────────────────────────────

    describe("Pausable", function () {
        it("should pause successfully by admin", async function () {
            const { dex, admin } = await loadFixture(deployFixture);

            await dex.connect(admin).pause();
            expect(await dex.paused()).to.equal(true);
        });

        it("should unpause successfully by admin", async function () {
            const { dex, admin } = await loadFixture(deployFixture);

            await dex.connect(admin).pause();
            await dex.connect(admin).unpause();
            expect(await dex.paused()).to.equal(false);
        });

        it("should block submitPrivateOrder when paused (reverts EnforcedPause before MPC)", async function () {
            const { dex, admin, trader1 } =
                await loadFixture(deployFixture);

            await dex.connect(admin).pause();

            // submitPrivateOrder has whenNotPaused modifier which
            // triggers before any MPC calls
            await expect(
                dex
                    .connect(trader1)
                    .submitPrivateOrder(
                        true,
                        "pXOM-USDC",
                        1000n,
                        500n,
                        0,
                        0n
                    )
            ).to.be.revertedWithCustomError(dex, "EnforcedPause");
        });

        it("should block executePrivateTrade when paused (access control checked first for non-matcher)", async function () {
            const { dex, admin, outsider, MATCHER_ROLE } =
                await loadFixture(deployFixture);

            await dex.connect(admin).pause();

            // For a non-matcher, AccessControl reverts before Pausable
            await expect(
                dex
                    .connect(outsider)
                    .executePrivateTrade(
                        ethers.id("buy"),
                        ethers.id("sell")
                    )
            )
                .to.be.revertedWithCustomError(
                    dex,
                    "AccessControlUnauthorizedAccount"
                )
                .withArgs(outsider.address, MATCHER_ROLE);
        });

        it("should block cancelPrivateOrder when paused", async function () {
            const { dex, admin, trader1 } =
                await loadFixture(deployFixture);

            await dex.connect(admin).pause();

            // cancelPrivateOrder has whenNotPaused modifier
            await expect(
                dex
                    .connect(trader1)
                    .cancelPrivateOrder(ethers.id("some-order"))
            ).to.be.revertedWithCustomError(dex, "EnforcedPause");
        });

        it("should allow view functions when paused", async function () {
            const { dex, admin, trader1 } =
                await loadFixture(deployFixture);

            await dex.connect(admin).pause();

            // View functions should still work
            const stats = await dex.getPrivacyStats();
            expect(stats.totalOrdersCount).to.equal(0n);

            const paginated = await dex.getUserOrdersPaginated(
                trader1.address,
                0,
                10
            );
            expect(paginated.total).to.equal(0n);
        });

        it("should allow ossification-related functions when paused", async function () {
            const { dex, admin } = await loadFixture(deployFixture);

            await dex.connect(admin).pause();

            // requestOssification and confirmOssification do NOT have
            // whenNotPaused modifier
            await expect(
                dex.connect(admin).requestOssification()
            ).to.emit(dex, "OssificationRequested");

            expect(await dex.ossificationRequestTime()).to.be.gt(0n);
        });

        it("should allow grantMatcherRole when paused", async function () {
            const { dex, admin, outsider, MATCHER_ROLE } =
                await loadFixture(deployFixture);

            await dex.connect(admin).pause();

            // Admin functions do not have whenNotPaused
            await dex
                .connect(admin)
                .grantMatcherRole(outsider.address);
            expect(
                await dex.hasRole(MATCHER_ROLE, outsider.address)
            ).to.be.true;
        });

        it("should allow revokeMatcherRole when paused", async function () {
            const { dex, admin, matcher, MATCHER_ROLE } =
                await loadFixture(deployFixture);

            await dex.connect(admin).pause();

            await dex
                .connect(admin)
                .revokeMatcherRole(matcher.address);
            expect(
                await dex.hasRole(MATCHER_ROLE, matcher.address)
            ).to.be.false;
        });
    });

    // ─────────────────────────────────────────────────────────────────────
    //  5. Matcher role management
    // ─────────────────────────────────────────────────────────────────────

    describe("Matcher role management", function () {
        it("should grant matcher role successfully", async function () {
            const { dex, admin, outsider, MATCHER_ROLE } =
                await loadFixture(deployFixture);

            await dex
                .connect(admin)
                .grantMatcherRole(outsider.address);
            expect(
                await dex.hasRole(MATCHER_ROLE, outsider.address)
            ).to.be.true;
        });

        it("should revoke matcher role successfully", async function () {
            const { dex, admin, matcher, MATCHER_ROLE } =
                await loadFixture(deployFixture);

            // matcher was granted role in fixture
            expect(
                await dex.hasRole(MATCHER_ROLE, matcher.address)
            ).to.be.true;

            await dex
                .connect(admin)
                .revokeMatcherRole(matcher.address);
            expect(
                await dex.hasRole(MATCHER_ROLE, matcher.address)
            ).to.be.false;
        });

        it("should revert grantMatcherRole with zero address", async function () {
            const { dex, admin } = await loadFixture(deployFixture);

            await expect(
                dex
                    .connect(admin)
                    .grantMatcherRole(ethers.ZeroAddress)
            ).to.be.revertedWithCustomError(dex, "InvalidAddress");
        });

        it("should allow granting matcher role to multiple addresses", async function () {
            const { dex, admin, trader1, trader2, MATCHER_ROLE } =
                await loadFixture(deployFixture);

            await dex
                .connect(admin)
                .grantMatcherRole(trader1.address);
            await dex
                .connect(admin)
                .grantMatcherRole(trader2.address);

            expect(
                await dex.hasRole(MATCHER_ROLE, trader1.address)
            ).to.be.true;
            expect(
                await dex.hasRole(MATCHER_ROLE, trader2.address)
            ).to.be.true;
        });

        it("should not revert when revoking from address without role", async function () {
            const { dex, admin, outsider, MATCHER_ROLE } =
                await loadFixture(deployFixture);

            // outsider does not have MATCHER_ROLE
            expect(
                await dex.hasRole(MATCHER_ROLE, outsider.address)
            ).to.be.false;

            // revokeRole on OZ AccessControl does not revert for non-holders
            await dex
                .connect(admin)
                .revokeMatcherRole(outsider.address);
            expect(
                await dex.hasRole(MATCHER_ROLE, outsider.address)
            ).to.be.false;
        });

        it("should allow re-granting matcher role after revocation", async function () {
            const { dex, admin, matcher, MATCHER_ROLE } =
                await loadFixture(deployFixture);

            await dex
                .connect(admin)
                .revokeMatcherRole(matcher.address);
            expect(
                await dex.hasRole(MATCHER_ROLE, matcher.address)
            ).to.be.false;

            await dex
                .connect(admin)
                .grantMatcherRole(matcher.address);
            expect(
                await dex.hasRole(MATCHER_ROLE, matcher.address)
            ).to.be.true;
        });

        it("should block matcher operations after role revocation", async function () {
            const { dex, admin, matcher, MATCHER_ROLE } =
                await loadFixture(deployFixture);

            await dex
                .connect(admin)
                .revokeMatcherRole(matcher.address);

            await expect(
                dex
                    .connect(matcher)
                    .canOrdersMatch(
                        ethers.id("a"),
                        ethers.id("b")
                    )
            )
                .to.be.revertedWithCustomError(
                    dex,
                    "AccessControlUnauthorizedAccount"
                )
                .withArgs(matcher.address, MATCHER_ROLE);
        });
    });

    // ─────────────────────────────────────────────────────────────────────
    //  6. Cancel order (non-MPC validation paths)
    // ─────────────────────────────────────────────────────────────────────

    describe("cancelPrivateOrder", function () {
        it("should revert with OrderNotFound for non-existent order", async function () {
            const { dex, trader1 } =
                await loadFixture(deployFixture);

            await expect(
                dex
                    .connect(trader1)
                    .cancelPrivateOrder(ethers.id("no-such-order"))
            ).to.be.revertedWithCustomError(dex, "OrderNotFound");
        });

        it("should revert with OrderNotFound for zero bytes32 order ID", async function () {
            const { dex, trader1 } =
                await loadFixture(deployFixture);

            await expect(
                dex
                    .connect(trader1)
                    .cancelPrivateOrder(ethers.ZeroHash)
            ).to.be.revertedWithCustomError(dex, "OrderNotFound");
        });

        it("should revert when contract is paused", async function () {
            const { dex, admin, trader1 } =
                await loadFixture(deployFixture);

            await dex.connect(admin).pause();

            await expect(
                dex
                    .connect(trader1)
                    .cancelPrivateOrder(ethers.id("any"))
            ).to.be.revertedWithCustomError(dex, "EnforcedPause");
        });

        // NOTE: Full cancel-order success path requires a real order to exist
        // on-chain. submitPrivateOrder() calls MpcCore.setPublic64() and
        // MpcCore.offBoard() internally to initialize the encrypted zero for
        // encFilled, so order creation reverts on Hardhat. Cancel tests with
        // real orders must be run on COTI testnet.
    });

    // ─────────────────────────────────────────────────────────────────────
    //  7. Cleanup user orders
    // ─────────────────────────────────────────────────────────────────────

    describe("cleanupUserOrders", function () {
        it("should return 0 removed for user with no orders", async function () {
            const { dex, trader1 } =
                await loadFixture(deployFixture);

            const tx = await dex
                .connect(trader1)
                .cleanupUserOrders(10);
            const receipt = await tx.wait();

            // Function returns uint256 removed; check via static call
            const removed = await dex
                .connect(trader1)
                .cleanupUserOrders.staticCall(10);
            expect(removed).to.equal(0n);
        });

        it("should accept maxCleanup of 0 without reverting", async function () {
            const { dex, trader1 } =
                await loadFixture(deployFixture);

            const removed = await dex
                .connect(trader1)
                .cleanupUserOrders.staticCall(0);
            expect(removed).to.equal(0n);
        });

        it("should accept large maxCleanup without reverting for empty user", async function () {
            const { dex, trader1 } =
                await loadFixture(deployFixture);

            const removed = await dex
                .connect(trader1)
                .cleanupUserOrders.staticCall(1000);
            expect(removed).to.equal(0n);
        });

        // NOTE: Testing actual cleanup with filled/cancelled orders
        // requires submitPrivateOrder() which uses MPC. Requires COTI testnet.
    });

    // ─────────────────────────────────────────────────────────────────────
    //  8. View functions
    // ─────────────────────────────────────────────────────────────────────

    describe("View functions", function () {
        describe("getPrivacyStats", function () {
            it("should return all zeros on fresh deploy", async function () {
                const { dex } = await loadFixture(deployFixture);

                const stats = await dex.getPrivacyStats();
                expect(stats.totalOrdersCount).to.equal(0n);
                expect(stats.totalTradesCount).to.equal(0n);
                expect(stats.activeOrdersCount).to.equal(0n);
            });

            it("should return three values from getPrivacyStats", async function () {
                const { dex } = await loadFixture(deployFixture);

                const stats = await dex.getPrivacyStats();
                // Verify the struct has exactly 3 fields
                expect(stats.length).to.equal(3);
            });
        });

        describe("getUserOrdersPaginated", function () {
            it("should return empty array and total=0 for user with no orders", async function () {
                const { dex, trader1 } =
                    await loadFixture(deployFixture);

                const result = await dex.getUserOrdersPaginated(
                    trader1.address,
                    0,
                    10
                );
                expect(result.orderIdSlice).to.have.length(0);
                expect(result.total).to.equal(0n);
            });

            it("should return empty array when offset >= total", async function () {
                const { dex, trader1 } =
                    await loadFixture(deployFixture);

                const result = await dex.getUserOrdersPaginated(
                    trader1.address,
                    100,
                    10
                );
                expect(result.orderIdSlice).to.have.length(0);
                expect(result.total).to.equal(0n);
            });

            it("should return empty array when limit is 0", async function () {
                const { dex, trader1 } =
                    await loadFixture(deployFixture);

                const result = await dex.getUserOrdersPaginated(
                    trader1.address,
                    0,
                    0
                );
                expect(result.orderIdSlice).to.have.length(0);
                expect(result.total).to.equal(0n);
            });

            it("should work with zero address user (returns empty)", async function () {
                const { dex } = await loadFixture(deployFixture);

                const result = await dex.getUserOrdersPaginated(
                    ethers.ZeroAddress,
                    0,
                    10
                );
                expect(result.orderIdSlice).to.have.length(0);
                expect(result.total).to.equal(0n);
            });
        });

        describe("getOrderBook", function () {
            it("should return empty arrays for non-existent pair", async function () {
                const { dex } = await loadFixture(deployFixture);

                const result = await dex.getOrderBook(
                    "pXOM-USDC",
                    10
                );
                expect(result.buyOrders).to.have.length(0);
                expect(result.sellOrders).to.have.length(0);
            });

            it("should return empty arrays with maxOrders=0", async function () {
                const { dex } = await loadFixture(deployFixture);

                const result = await dex.getOrderBook(
                    "pXOM-USDC",
                    0
                );
                expect(result.buyOrders).to.have.length(0);
                expect(result.sellOrders).to.have.length(0);
            });

            it("should return empty arrays for empty string pair", async function () {
                const { dex } = await loadFixture(deployFixture);

                const result = await dex.getOrderBook("", 10);
                expect(result.buyOrders).to.have.length(0);
                expect(result.sellOrders).to.have.length(0);
            });
        });

        describe("activeOrderCount", function () {
            it("should return 0 for address with no orders", async function () {
                const { dex, trader1 } =
                    await loadFixture(deployFixture);

                expect(
                    await dex.activeOrderCount(trader1.address)
                ).to.equal(0n);
            });

            it("should return 0 for zero address", async function () {
                const { dex } = await loadFixture(deployFixture);

                expect(
                    await dex.activeOrderCount(ethers.ZeroAddress)
                ).to.equal(0n);
            });
        });

        describe("userOrderCount", function () {
            it("should return 0 for address with no orders", async function () {
                const { dex, trader1 } =
                    await loadFixture(deployFixture);

                expect(
                    await dex.userOrderCount(trader1.address)
                ).to.equal(0n);
            });
        });

        describe("orders mapping", function () {
            it("should return default struct for non-existent order ID", async function () {
                const { dex } = await loadFixture(deployFixture);

                const order = await dex.orders(ethers.id("missing"));
                expect(order.trader).to.equal(ethers.ZeroAddress);
                expect(order.isBuy).to.equal(false);
                expect(order.pair).to.equal("");
                expect(order.timestamp).to.equal(0n);
                // OrderStatus.OPEN is 0 (default for uint8)
                expect(order.status).to.equal(0n);
                expect(order.expiry).to.equal(0n);
            });
        });
    });

    // ─────────────────────────────────────────────────────────────────────
    //  9. Constants
    // ─────────────────────────────────────────────────────────────────────

    describe("Constants", function () {
        it("should expose MATCHER_ROLE as keccak256('MATCHER_ROLE')", async function () {
            const { dex } = await loadFixture(deployFixture);

            expect(await dex.MATCHER_ROLE()).to.equal(
                ethers.id("MATCHER_ROLE")
            );
        });

        it("should use DEFAULT_ADMIN_ROLE (bytes32(0)) for admin functions", async function () {
            const { dex } = await loadFixture(deployFixture);

            expect(await dex.DEFAULT_ADMIN_ROLE()).to.equal(
                ethers.ZeroHash
            );
        });

        it("should expose MAX_ORDERS_PER_USER = 100", async function () {
            const { dex } = await loadFixture(deployFixture);

            expect(await dex.MAX_ORDERS_PER_USER()).to.equal(100n);
        });

        it("should expose OSSIFICATION_DELAY = 7 days (604800 seconds)", async function () {
            const { dex } = await loadFixture(deployFixture);

            expect(await dex.OSSIFICATION_DELAY()).to.equal(
                604800n
            );
        });

        it("should expose MAX_FEE_BPS = 10000", async function () {
            const { dex } = await loadFixture(deployFixture);

            expect(await dex.MAX_FEE_BPS()).to.equal(10000n);
        });

        it("should have DEFAULT_ADMIN_ROLE = bytes32(0)", async function () {
            const { dex } = await loadFixture(deployFixture);

            expect(await dex.DEFAULT_ADMIN_ROLE()).to.equal(
                ethers.ZeroHash
            );
        });
    });

    // ─────────────────────────────────────────────────────────────────────
    //  10. Events and errors in ABI
    // ─────────────────────────────────────────────────────────────────────

    describe("Events in ABI", function () {
        it("should have PrivateOrderSubmitted event", async function () {
            const { dex } = await loadFixture(deployFixture);
            const event =
                dex.interface.getEvent("PrivateOrderSubmitted");
            expect(event).to.not.be.undefined;
            expect(event.name).to.equal("PrivateOrderSubmitted");
        });

        it("should have PrivateOrderMatched event", async function () {
            const { dex } = await loadFixture(deployFixture);
            const event =
                dex.interface.getEvent("PrivateOrderMatched");
            expect(event).to.not.be.undefined;
            expect(event.name).to.equal("PrivateOrderMatched");
        });

        it("should have PrivateOrderCancelled event", async function () {
            const { dex } = await loadFixture(deployFixture);
            const event =
                dex.interface.getEvent("PrivateOrderCancelled");
            expect(event).to.not.be.undefined;
            expect(event.name).to.equal("PrivateOrderCancelled");
        });

        it("should have OrderStatusChanged event", async function () {
            const { dex } = await loadFixture(deployFixture);
            const event =
                dex.interface.getEvent("OrderStatusChanged");
            expect(event).to.not.be.undefined;
            expect(event.name).to.equal("OrderStatusChanged");
        });

        it("should have OssificationRequested event", async function () {
            const { dex } = await loadFixture(deployFixture);
            const event =
                dex.interface.getEvent("OssificationRequested");
            expect(event).to.not.be.undefined;
            expect(event.name).to.equal("OssificationRequested");
        });

        it("should have ContractOssified event", async function () {
            const { dex } = await loadFixture(deployFixture);
            const event =
                dex.interface.getEvent("ContractOssified");
            expect(event).to.not.be.undefined;
            expect(event.name).to.equal("ContractOssified");
        });
    });

    describe("Custom errors in ABI", function () {
        it("should have all custom errors defined", async function () {
            const { dex } = await loadFixture(deployFixture);

            const expectedErrors = [
                "OrderNotFound",
                "Unauthorized",
                "InvalidAmount",
                "InvalidOrderStatus",
                "TooManyOrders",
                "InvalidPair",
                "OverfillDetected",
                "InvalidAddress",
                "OrderExpired",
                "FillBelowMinimum",
                "ContractIsOssified",
                "PriceIncompatible",
                "InvalidOrderSides",
                "PairMismatch",
                "FeeTooHigh",
                "OssificationNotRequested",
                "OssificationDelayNotElapsed",
            ];

            for (const errorName of expectedErrors) {
                const errorFragment =
                    dex.interface.getError(errorName);
                expect(
                    errorFragment,
                    `Missing error: ${errorName}`
                ).to.not.be.undefined;
                expect(errorFragment.name).to.equal(errorName);
            }
        });
    });

    // ─────────────────────────────────────────────────────────────────────
    //  11. UUPS upgradeability
    // ─────────────────────────────────────────────────────────────────────

    describe("UUPS upgradeability", function () {
        it("should preserve state after upgrade", async function () {
            const { dex, admin } = await loadFixture(deployFixture);

            // Set some state via ossification request
            await dex.connect(admin).requestOssification();
            const requestTime = await dex.ossificationRequestTime();

            const V2Factory =
                await ethers.getContractFactory("PrivateDEX");
            const upgraded = await upgrades.upgradeProxy(
                await dex.getAddress(),
                V2Factory,
                {
                    constructorArgs: [ethers.ZeroAddress],
                    unsafeAllow: ["constructor"],
                }
            );

            // State should be preserved
            expect(
                await upgraded.ossificationRequestTime()
            ).to.equal(requestTime);
            expect(await upgraded.isOssified()).to.equal(false);
        });

        it("should preserve roles after upgrade", async function () {
            const {
                dex,
                admin,
                matcher,
                MATCHER_ROLE,
                DEFAULT_ADMIN_ROLE,
            } = await loadFixture(deployFixture);

            const V2Factory =
                await ethers.getContractFactory("PrivateDEX");
            const upgraded = await upgrades.upgradeProxy(
                await dex.getAddress(),
                V2Factory,
                {
                    constructorArgs: [ethers.ZeroAddress],
                    unsafeAllow: ["constructor"],
                }
            );

            expect(
                await upgraded.hasRole(
                    DEFAULT_ADMIN_ROLE,
                    admin.address
                )
            ).to.be.true;
            expect(
                await upgraded.hasRole(
                    MATCHER_ROLE,
                    matcher.address
                )
            ).to.be.true;
        });

        it("should revert upgrade from non-admin account", async function () {
            const { dex, outsider, DEFAULT_ADMIN_ROLE } =
                await loadFixture(deployFixture);

            const V2Factory = await ethers.getContractFactory(
                "PrivateDEX",
                outsider
            );

            await expect(
                upgrades.upgradeProxy(
                    await dex.getAddress(),
                    V2Factory,
                    {
                        constructorArgs: [ethers.ZeroAddress],
                        unsafeAllow: ["constructor"],
                    }
                )
            )
                .to.be.revertedWithCustomError(
                    dex,
                    "AccessControlUnauthorizedAccount"
                )
                .withArgs(outsider.address, DEFAULT_ADMIN_ROLE);
        });
    });

    // ─────────────────────────────────────────────────────────────────────
    //  12. Fee validation (calculateTradeFees parameter checks)
    // ─────────────────────────────────────────────────────────────────────

    describe("Fee validation", function () {
        it("should revert calculateTradeFees when feeBps > MAX_FEE_BPS", async function () {
            const { dex, matcher } =
                await loadFixture(deployFixture);

            // 10001 > 10000 (MAX_FEE_BPS)
            await expect(
                dex.connect(matcher).calculateTradeFees(1000n, 10001)
            ).to.be.revertedWithCustomError(dex, "FeeTooHigh");
        });

        it("should revert calculateTradeFees at feeBps = MAX_FEE_BPS + 1", async function () {
            const { dex, matcher } =
                await loadFixture(deployFixture);

            await expect(
                dex.connect(matcher).calculateTradeFees(1000n, 10001)
            ).to.be.revertedWithCustomError(dex, "FeeTooHigh");
        });

        // NOTE: calculateTradeFees with feeBps <= MAX_FEE_BPS uses
        // MpcCore.onBoard which requires COTI MPC precompile. The
        // FeeTooHigh check happens before MPC calls, so it can be
        // tested on Hardhat.
    });

    // ─────────────────────────────────────────────────────────────────────
    //  13. Order matching validation (non-MPC paths)
    // ─────────────────────────────────────────────────────────────────────

    describe("Order matching validation (non-MPC paths)", function () {
        it("should revert canOrdersMatch with OrderNotFound for non-existent buy order", async function () {
            const { dex, matcher } =
                await loadFixture(deployFixture);

            await expect(
                dex
                    .connect(matcher)
                    .canOrdersMatch(
                        ethers.id("nonexistent-buy"),
                        ethers.id("nonexistent-sell")
                    )
            ).to.be.revertedWithCustomError(dex, "OrderNotFound");
        });

        it("should revert calculateMatchAmount with OrderNotFound for non-existent orders", async function () {
            const { dex, matcher } =
                await loadFixture(deployFixture);

            await expect(
                dex
                    .connect(matcher)
                    .calculateMatchAmount(
                        ethers.id("nonexistent-buy"),
                        ethers.id("nonexistent-sell")
                    )
            ).to.be.revertedWithCustomError(dex, "OrderNotFound");
        });

        it("should revert executePrivateTrade with OrderNotFound for non-existent buy order", async function () {
            const { dex, matcher } =
                await loadFixture(deployFixture);

            await expect(
                dex
                    .connect(matcher)
                    .executePrivateTrade(
                        ethers.id("nonexistent-buy"),
                        ethers.id("nonexistent-sell")
                    )
            ).to.be.revertedWithCustomError(dex, "OrderNotFound");
        });
    });

    // ─────────────────────────────────────────────────────────────────────
    //  14. submitPrivateOrder input validation (non-MPC paths)
    // ─────────────────────────────────────────────────────────────────────

    describe("submitPrivateOrder input validation", function () {
        it("should revert with InvalidPair for empty pair string", async function () {
            const { dex, trader1 } =
                await loadFixture(deployFixture);

            // InvalidPair check happens before any MPC calls
            await expect(
                dex
                    .connect(trader1)
                    .submitPrivateOrder(
                        true,
                        "",
                        1000n,
                        500n,
                        0,
                        0n
                    )
            ).to.be.revertedWithCustomError(dex, "InvalidPair");
        });

        it("should revert with EnforcedPause when paused (before MPC)", async function () {
            const { dex, admin, trader1 } =
                await loadFixture(deployFixture);

            await dex.connect(admin).pause();

            await expect(
                dex
                    .connect(trader1)
                    .submitPrivateOrder(
                        true,
                        "pXOM-USDC",
                        1000n,
                        500n,
                        0,
                        0n
                    )
            ).to.be.revertedWithCustomError(dex, "EnforcedPause");
        });

        it("should revert with InvalidPair for empty pair even with valid other params", async function () {
            const { dex, trader1 } =
                await loadFixture(deployFixture);

            await expect(
                dex
                    .connect(trader1)
                    .submitPrivateOrder(
                        false,
                        "",
                        5000n,
                        1000n,
                        (await time.latest()) + 3600,
                        100n
                    )
            ).to.be.revertedWithCustomError(dex, "InvalidPair");
        });
    });

    // ─────────────────────────────────────────────────────────────────────
    //  15. isOrderFullyFilled (non-MPC paths)
    // ─────────────────────────────────────────────────────────────────────

    describe("isOrderFullyFilled", function () {
        it("should revert with OrderNotFound for non-existent order", async function () {
            const { dex, trader1 } =
                await loadFixture(deployFixture);

            await expect(
                dex
                    .connect(trader1)
                    .isOrderFullyFilled(ethers.id("missing"))
            ).to.be.revertedWithCustomError(dex, "OrderNotFound");
        });

        it("should revert with OrderNotFound for zero hash order ID", async function () {
            const { dex, trader1 } =
                await loadFixture(deployFixture);

            await expect(
                dex
                    .connect(trader1)
                    .isOrderFullyFilled(ethers.ZeroHash)
            ).to.be.revertedWithCustomError(dex, "OrderNotFound");
        });
    });

    // ─────────────────────────────────────────────────────────────────────
    //  16. MPC-Dependent (Requires COTI Testnet)
    // ─────────────────────────────────────────────────────────────────────

    describe("MPC-Dependent (COTI testnet only)", function () {
        // These tests document what CANNOT be tested on Hardhat due to
        // MPC precompile requirements. They should be run on COTI testnet.

        it.skip("submitPrivateOrder -- successful order creation (Requires COTI testnet: MpcCore.setPublic64, MpcCore.offBoard)", function () {
            // MpcCore.setPublic64(0) and MpcCore.offBoard() are called to
            // initialize encFilled to encrypted zero. These call COTI MPC
            // precompiles that revert on Hardhat.
        });

        it.skip("submitPrivateOrder -- should emit PrivateOrderSubmitted with correct args (Requires COTI testnet)", function () {
            // Depends on successful order creation which requires MPC.
        });

        it.skip("submitPrivateOrder -- should increment totalOrders (Requires COTI testnet)", function () {
            // Depends on successful order creation which requires MPC.
        });

        it.skip("submitPrivateOrder -- should increment totalActiveOrders (Requires COTI testnet)", function () {
            // Depends on successful order creation which requires MPC.
        });

        it.skip("submitPrivateOrder -- should increment activeOrderCount for trader (Requires COTI testnet)", function () {
            // Depends on successful order creation which requires MPC.
        });

        it.skip("submitPrivateOrder -- should track order in userOrders mapping (Requires COTI testnet)", function () {
            // Depends on successful order creation which requires MPC.
        });

        it.skip("submitPrivateOrder -- should reject when user has MAX_ORDERS_PER_USER active orders (Requires COTI testnet)", function () {
            // Needs 100 successful order creations first, each using MPC.
        });

        it.skip("submitPrivateOrder -- should store correct order struct fields (Requires COTI testnet)", function () {
            // Depends on successful order creation which requires MPC.
        });

        it.skip("cancelPrivateOrder -- successful cancellation by order owner (Requires COTI testnet: needs real order)", function () {
            // Needs a real on-chain order, which requires submitPrivateOrder
            // and therefore MPC.
        });

        it.skip("cancelPrivateOrder -- should emit PrivateOrderCancelled (Requires COTI testnet)", function () {
            // Depends on having a real order to cancel.
        });

        it.skip("cancelPrivateOrder -- should emit OrderStatusChanged (Requires COTI testnet)", function () {
            // Depends on having a real order to cancel.
        });

        it.skip("cancelPrivateOrder -- should decrement activeOrderCount (Requires COTI testnet)", function () {
            // Depends on having a real order to cancel.
        });

        it.skip("cancelPrivateOrder -- should decrement totalActiveOrders (Requires COTI testnet)", function () {
            // Depends on having a real order to cancel.
        });

        it.skip("cancelPrivateOrder -- should revert Unauthorized for non-owner (Requires COTI testnet)", function () {
            // Needs a real order from trader1, then trader2 tries to cancel.
        });

        it.skip("cancelPrivateOrder -- should revert InvalidOrderStatus for already cancelled order (Requires COTI testnet)", function () {
            // Needs a real order, cancel it, then try cancelling again.
        });

        it.skip("cancelPrivateOrder -- should revert InvalidOrderStatus for filled order (Requires COTI testnet)", function () {
            // Needs a real filled order, which requires executePrivateTrade.
        });

        it.skip("canOrdersMatch -- should return true for compatible buy/sell pair (Requires COTI testnet: MpcCore.ge, MpcCore.decrypt)", function () {
            // MPC price comparison: buyPrice >= sellPrice.
        });

        it.skip("canOrdersMatch -- should return false for incompatible prices (Requires COTI testnet)", function () {
            // MPC comparison would reveal buyPrice < sellPrice.
        });

        it.skip("canOrdersMatch -- should return false for expired buy order (Requires COTI testnet)", function () {
            // Needs real orders with expiry set, then advance time.
        });

        it.skip("canOrdersMatch -- should return false for expired sell order (Requires COTI testnet)", function () {
            // Needs real orders with expiry set, then advance time.
        });

        it.skip("canOrdersMatch -- should return false for wrong order sides (Requires COTI testnet)", function () {
            // Needs two buy orders or two sell orders.
        });

        it.skip("canOrdersMatch -- should return false for mismatched trading pairs (Requires COTI testnet)", function () {
            // Needs orders with different pair strings.
        });

        it.skip("calculateMatchAmount -- should return min of remaining amounts (Requires COTI testnet: MpcCore.checkedSub, MpcCore.min)", function () {
            // All encrypted arithmetic via MPC garbled circuits.
        });

        it.skip("calculateTradeFees -- should return correct fee for valid feeBps (Requires COTI testnet: MpcCore.onBoard, checkedMul, div)", function () {
            // Fee calculation: (amount * feeBps) / 10000 using MPC.
        });

        it.skip("calculateTradeFees -- should handle feeBps = 0 (Requires COTI testnet)", function () {
            // Zero fee: (amount * 0) / 10000 = 0 using MPC.
        });

        it.skip("calculateTradeFees -- should handle feeBps = MAX_FEE_BPS (Requires COTI testnet)", function () {
            // 100% fee: (amount * 10000) / 10000 = amount using MPC.
        });

        it.skip("executePrivateTrade -- full trade execution (Requires COTI testnet: all MPC operations)", function () {
            // Complete trade: price validation, match amount computation,
            // fill updates, status transitions. All MPC-dependent.
        });

        it.skip("executePrivateTrade -- should emit PrivateOrderMatched (Requires COTI testnet)", function () {
            // Depends on successful trade execution.
        });

        it.skip("executePrivateTrade -- should increment totalTrades (Requires COTI testnet)", function () {
            // Depends on successful trade execution.
        });

        it.skip("executePrivateTrade -- partial fill should set PARTIALLY_FILLED status (Requires COTI testnet)", function () {
            // MPC comparison: filled != amount.
        });

        it.skip("executePrivateTrade -- full fill should set FILLED status and decrement counters (Requires COTI testnet)", function () {
            // MPC comparison: filled == amount.
        });

        it.skip("executePrivateTrade -- should revert PriceIncompatible for buyPrice < sellPrice (Requires COTI testnet)", function () {
            // MPC price re-validation inside execute.
        });

        it.skip("executePrivateTrade -- should revert OrderExpired for expired buy order (Requires COTI testnet)", function () {
            // Needs real order with expiry, then advance time.
        });

        it.skip("executePrivateTrade -- should revert OverfillDetected (Requires COTI testnet)", function () {
            // MPC overfill guard: ge(amount, newFilled).
        });

        it.skip("executePrivateTrade -- should revert FillBelowMinimum (Requires COTI testnet)", function () {
            // MPC minFill check: ge(fillAmount, minFill).
        });

        it.skip("isOrderFullyFilled -- should return true for filled order (Requires COTI testnet: MpcCore.eq, MpcCore.decrypt)", function () {
            // MPC comparison: filled == amount.
        });

        it.skip("isOrderFullyFilled -- should return false for open order (Requires COTI testnet)", function () {
            // MPC comparison: filled != amount.
        });

        it.skip("cleanupUserOrders -- should remove filled orders from user array (Requires COTI testnet)", function () {
            // Needs real orders that have been filled via executePrivateTrade.
        });

        it.skip("cleanupUserOrders -- should remove cancelled orders from user array (Requires COTI testnet)", function () {
            // Needs real orders that have been cancelled via cancelPrivateOrder.
        });

        it.skip("cleanupUserOrders -- should not remove open orders (Requires COTI testnet)", function () {
            // Needs a mix of open and terminal orders.
        });

        it.skip("cleanupUserOrders -- should respect maxCleanup limit (Requires COTI testnet)", function () {
            // Needs many orders; verify only maxCleanup are processed.
        });

        it.skip("getOrderBook -- should return correct buy and sell orders (Requires COTI testnet)", function () {
            // Needs real orders to populate the order book.
        });

        it.skip("getOrderBook -- should respect maxOrders cap (Requires COTI testnet)", function () {
            // Needs more orders than maxOrders to verify truncation.
        });

        it.skip("getOrderBook -- should exclude filled and cancelled orders (Requires COTI testnet)", function () {
            // Needs orders in various statuses.
        });
    });
});
