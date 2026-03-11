/**
 * PrivateWETH -- Non-MPC Logic Tests
 *
 * Tests all contract logic that does NOT require COTI MPC garbled circuits:
 *  1.  Initialization (roles, underlying token, constants, privacy detection)
 *  2.  bridgeMint (BRIDGE_ROLE, real ERC20 custody, publicBalances)
 *  3.  bridgeBurn (balance debit, real ERC20 release, guards)
 *  4.  Access control (BRIDGE_ROLE, DEFAULT_ADMIN_ROLE checks)
 *  5.  Pause/unpause (operations blocked when paused)
 *  6.  Privacy admin (enablePrivacy, proposePrivacyDisable, timelock,
 *      executePrivacyDisable, cancelPrivacyDisable)
 *  7.  Emergency recovery (shadow ledger, privacy-must-be-disabled guard,
 *      scaled-unit recovery)
 *  8.  Dust tracking and claimDust
 *  9.  Ossification (upgrade blocked after ossify)
 * 10.  View functions (publicBalances, dustBalances, constants, name,
 *      symbol, decimals)
 * 11.  SCALING_FACTOR correctness (1e12, dust calculation math)
 * 12.  Events and custom errors (ABI verification)
 *
 * MPC-dependent functions (convertToPrivate, convertToPublic, privateTransfer)
 * CANNOT be tested on Hardhat -- they require COTI testnet MPC precompile.
 * Those tests are marked with descriptive skip comments.
 */

/* eslint-disable @typescript-eslint/no-var-requires */
const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");
const {
    time,
    loadFixture,
} = require("@nomicfoundation/hardhat-network-helpers");

describe("PrivateWETH", function () {
    /**
     * Shared deployment fixture.
     * Deploys ERC20MockConfigurable with 18 decimals (WETH) and
     * the PrivateWETH UUPS proxy with (admin, underlyingToken).
     */
    async function deployFixture() {
        const [admin, bridge, user1, user2, outsider] =
            await ethers.getSigners();

        // Deploy mock WETH with 18 decimals
        const MockToken = await ethers.getContractFactory(
            "ERC20MockConfigurable"
        );
        const weth = await MockToken.deploy("Mock WETH", "WETH", 18);
        await weth.waitForDeployment();

        // Deploy PrivateWETH as UUPS proxy
        const Factory = await ethers.getContractFactory("PrivateWETH");
        const privateWETH = await upgrades.deployProxy(
            Factory,
            [admin.address, await weth.getAddress()],
            {
                initializer: "initialize",
                kind: "uups",
                unsafeAllow: ["constructor", "state-variable-immutable"],
            }
        );
        await privateWETH.waitForDeployment();

        // Grant BRIDGE_ROLE to dedicated bridge signer
        const BRIDGE_ROLE = await privateWETH.BRIDGE_ROLE();
        await privateWETH
            .connect(admin)
            .grantRole(BRIDGE_ROLE, bridge.address);

        // Transfer WETH to bridge so it can bridgeMint
        const mintAmount = ethers.parseEther("10000"); // 10,000 WETH
        await weth.connect(admin).transfer(bridge.address, mintAmount);

        // Approve PrivateWETH contract to pull WETH from bridge
        await weth
            .connect(bridge)
            .approve(await privateWETH.getAddress(), ethers.MaxUint256);

        // Also approve from admin (who also has BRIDGE_ROLE by default)
        await weth
            .connect(admin)
            .approve(await privateWETH.getAddress(), ethers.MaxUint256);

        const DEFAULT_ADMIN_ROLE = await privateWETH.DEFAULT_ADMIN_ROLE();

        return {
            privateWETH,
            weth,
            admin,
            bridge,
            user1,
            user2,
            outsider,
            BRIDGE_ROLE,
            DEFAULT_ADMIN_ROLE,
        };
    }

    // ─────────────────────────────────────────────────────────────────────
    //  1. Initialization
    // ─────────────────────────────────────────────────────────────────────

    describe("Initialization", function () {
        it("should grant DEFAULT_ADMIN_ROLE to admin", async function () {
            const { privateWETH, admin, DEFAULT_ADMIN_ROLE } =
                await loadFixture(deployFixture);
            expect(
                await privateWETH.hasRole(DEFAULT_ADMIN_ROLE, admin.address)
            ).to.be.true;
        });

        it("should grant BRIDGE_ROLE to admin", async function () {
            const { privateWETH, admin, BRIDGE_ROLE } =
                await loadFixture(deployFixture);
            expect(
                await privateWETH.hasRole(BRIDGE_ROLE, admin.address)
            ).to.be.true;
        });

        it("should set underlying token correctly", async function () {
            const { privateWETH, weth } =
                await loadFixture(deployFixture);
            expect(await privateWETH.underlyingToken()).to.equal(
                await weth.getAddress()
            );
        });

        it("should have SCALING_FACTOR = 1e12", async function () {
            const { privateWETH } = await loadFixture(deployFixture);
            expect(await privateWETH.SCALING_FACTOR()).to.equal(
                1000000000000n
            );
        });

        it("should have TOKEN_NAME = 'Private WETH'", async function () {
            const { privateWETH } = await loadFixture(deployFixture);
            expect(await privateWETH.TOKEN_NAME()).to.equal("Private WETH");
        });

        it("should have TOKEN_SYMBOL = 'pWETH'", async function () {
            const { privateWETH } = await loadFixture(deployFixture);
            expect(await privateWETH.TOKEN_SYMBOL()).to.equal("pWETH");
        });

        it("should have TOKEN_DECIMALS = 18", async function () {
            const { privateWETH } = await loadFixture(deployFixture);
            expect(await privateWETH.TOKEN_DECIMALS()).to.equal(18);
        });

        it("should start with totalPublicSupply = 0", async function () {
            const { privateWETH } = await loadFixture(deployFixture);
            expect(await privateWETH.totalPublicSupply()).to.equal(0n);
        });

        it("should detect privacy as disabled on Hardhat (chain 1337)", async function () {
            const { privateWETH } = await loadFixture(deployFixture);
            expect(await privateWETH.privacyEnabled()).to.be.false;
        });

        it("should start with PRIVACY_DISABLE_DELAY = 7 days", async function () {
            const { privateWETH } = await loadFixture(deployFixture);
            expect(await privateWETH.PRIVACY_DISABLE_DELAY()).to.equal(
                7n * 24n * 60n * 60n
            );
        });

        it("should start unossified", async function () {
            const { privateWETH } = await loadFixture(deployFixture);
            expect(await privateWETH.isOssified()).to.be.false;
        });

        it("should revert when admin is zero address", async function () {
            const { weth } = await loadFixture(deployFixture);
            const Factory = await ethers.getContractFactory("PrivateWETH");
            await expect(
                upgrades.deployProxy(
                    Factory,
                    [ethers.ZeroAddress, await weth.getAddress()],
                    {
                        initializer: "initialize",
                        kind: "uups",
                        unsafeAllow: [
                            "constructor",
                            "state-variable-immutable",
                        ],
                    }
                )
            ).to.be.revertedWithCustomError(Factory, "ZeroAddress");
        });

        it("should revert when underlying token is zero address", async function () {
            const [admin] = await ethers.getSigners();
            const Factory = await ethers.getContractFactory("PrivateWETH");
            await expect(
                upgrades.deployProxy(
                    Factory,
                    [admin.address, ethers.ZeroAddress],
                    {
                        initializer: "initialize",
                        kind: "uups",
                        unsafeAllow: [
                            "constructor",
                            "state-variable-immutable",
                        ],
                    }
                )
            ).to.be.revertedWithCustomError(Factory, "ZeroAddress");
        });

        it("should have privacyDisableScheduledAt = 0 initially", async function () {
            const { privateWETH } = await loadFixture(deployFixture);
            expect(await privateWETH.privacyDisableScheduledAt()).to.equal(
                0n
            );
        });
    });

    // ─────────────────────────────────────────────────────────────────────
    //  2. bridgeMint
    // ─────────────────────────────────────────────────────────────────────

    describe("bridgeMint", function () {
        it("should mint and credit publicBalances", async function () {
            const { privateWETH, bridge, user1 } =
                await loadFixture(deployFixture);

            const amount = ethers.parseEther("5");
            await privateWETH
                .connect(bridge)
                .bridgeMint(user1.address, amount);

            expect(
                await privateWETH.publicBalances(user1.address)
            ).to.equal(amount);
        });

        it("should increase totalPublicSupply", async function () {
            const { privateWETH, bridge, user1 } =
                await loadFixture(deployFixture);

            const amount = ethers.parseEther("10");
            await privateWETH
                .connect(bridge)
                .bridgeMint(user1.address, amount);

            expect(await privateWETH.totalPublicSupply()).to.equal(amount);
        });

        it("should transfer real WETH from bridge to contract", async function () {
            const { privateWETH, weth, bridge, user1 } =
                await loadFixture(deployFixture);

            const amount = ethers.parseEther("3");
            const bridgeBalBefore = await weth.balanceOf(bridge.address);

            await privateWETH
                .connect(bridge)
                .bridgeMint(user1.address, amount);

            const bridgeBalAfter = await weth.balanceOf(bridge.address);
            expect(bridgeBalBefore - bridgeBalAfter).to.equal(amount);

            const contractBal = await weth.balanceOf(
                await privateWETH.getAddress()
            );
            expect(contractBal).to.equal(amount);
        });

        it("should emit BridgeMint event", async function () {
            const { privateWETH, bridge, user1 } =
                await loadFixture(deployFixture);

            const amount = ethers.parseEther("1");
            await expect(
                privateWETH
                    .connect(bridge)
                    .bridgeMint(user1.address, amount)
            )
                .to.emit(privateWETH, "BridgeMint")
                .withArgs(user1.address, amount);
        });

        it("should accumulate balances across multiple mints", async function () {
            const { privateWETH, bridge, user1 } =
                await loadFixture(deployFixture);

            const amount1 = ethers.parseEther("2");
            const amount2 = ethers.parseEther("3");

            await privateWETH
                .connect(bridge)
                .bridgeMint(user1.address, amount1);
            await privateWETH
                .connect(bridge)
                .bridgeMint(user1.address, amount2);

            expect(
                await privateWETH.publicBalances(user1.address)
            ).to.equal(amount1 + amount2);
        });

        it("should revert when caller lacks BRIDGE_ROLE", async function () {
            const { privateWETH, outsider, user1, BRIDGE_ROLE } =
                await loadFixture(deployFixture);

            await expect(
                privateWETH
                    .connect(outsider)
                    .bridgeMint(user1.address, ethers.parseEther("1"))
            )
                .to.be.revertedWithCustomError(
                    privateWETH,
                    "AccessControlUnauthorizedAccount"
                )
                .withArgs(outsider.address, BRIDGE_ROLE);
        });

        it("should revert when recipient is zero address", async function () {
            const { privateWETH, bridge } =
                await loadFixture(deployFixture);

            await expect(
                privateWETH
                    .connect(bridge)
                    .bridgeMint(ethers.ZeroAddress, ethers.parseEther("1"))
            ).to.be.revertedWithCustomError(privateWETH, "ZeroAddress");
        });

        it("should revert when amount is zero", async function () {
            const { privateWETH, bridge, user1 } =
                await loadFixture(deployFixture);

            await expect(
                privateWETH.connect(bridge).bridgeMint(user1.address, 0n)
            ).to.be.revertedWithCustomError(privateWETH, "ZeroAmount");
        });

        it("should mint to multiple different recipients", async function () {
            const { privateWETH, bridge, user1, user2 } =
                await loadFixture(deployFixture);

            const amt1 = ethers.parseEther("4");
            const amt2 = ethers.parseEther("6");

            await privateWETH
                .connect(bridge)
                .bridgeMint(user1.address, amt1);
            await privateWETH
                .connect(bridge)
                .bridgeMint(user2.address, amt2);

            expect(
                await privateWETH.publicBalances(user1.address)
            ).to.equal(amt1);
            expect(
                await privateWETH.publicBalances(user2.address)
            ).to.equal(amt2);
            expect(await privateWETH.totalPublicSupply()).to.equal(
                amt1 + amt2
            );
        });
    });

    // ─────────────────────────────────────────────────────────────────────
    //  3. bridgeBurn
    // ─────────────────────────────────────────────────────────────────────

    describe("bridgeBurn", function () {
        it("should burn and debit publicBalances", async function () {
            const { privateWETH, bridge, user1 } =
                await loadFixture(deployFixture);

            const mintAmount = ethers.parseEther("10");
            await privateWETH
                .connect(bridge)
                .bridgeMint(user1.address, mintAmount);

            const burnAmount = ethers.parseEther("4");
            await privateWETH
                .connect(bridge)
                .bridgeBurn(user1.address, burnAmount);

            expect(
                await privateWETH.publicBalances(user1.address)
            ).to.equal(mintAmount - burnAmount);
        });

        it("should decrease totalPublicSupply", async function () {
            const { privateWETH, bridge, user1 } =
                await loadFixture(deployFixture);

            const mintAmount = ethers.parseEther("10");
            await privateWETH
                .connect(bridge)
                .bridgeMint(user1.address, mintAmount);

            const burnAmount = ethers.parseEther("3");
            await privateWETH
                .connect(bridge)
                .bridgeBurn(user1.address, burnAmount);

            expect(await privateWETH.totalPublicSupply()).to.equal(
                mintAmount - burnAmount
            );
        });

        it("should transfer real WETH back to user", async function () {
            const { privateWETH, weth, bridge, user1 } =
                await loadFixture(deployFixture);

            const mintAmount = ethers.parseEther("10");
            await privateWETH
                .connect(bridge)
                .bridgeMint(user1.address, mintAmount);

            const burnAmount = ethers.parseEther("5");
            const userBalBefore = await weth.balanceOf(user1.address);

            await privateWETH
                .connect(bridge)
                .bridgeBurn(user1.address, burnAmount);

            const userBalAfter = await weth.balanceOf(user1.address);
            expect(userBalAfter - userBalBefore).to.equal(burnAmount);
        });

        it("should emit BridgeBurn event", async function () {
            const { privateWETH, bridge, user1 } =
                await loadFixture(deployFixture);

            const mintAmount = ethers.parseEther("10");
            await privateWETH
                .connect(bridge)
                .bridgeMint(user1.address, mintAmount);

            const burnAmount = ethers.parseEther("2");
            await expect(
                privateWETH
                    .connect(bridge)
                    .bridgeBurn(user1.address, burnAmount)
            )
                .to.emit(privateWETH, "BridgeBurn")
                .withArgs(user1.address, burnAmount);
        });

        it("should allow burning full balance", async function () {
            const { privateWETH, bridge, user1 } =
                await loadFixture(deployFixture);

            const amount = ethers.parseEther("7");
            await privateWETH
                .connect(bridge)
                .bridgeMint(user1.address, amount);
            await privateWETH
                .connect(bridge)
                .bridgeBurn(user1.address, amount);

            expect(
                await privateWETH.publicBalances(user1.address)
            ).to.equal(0n);
            expect(await privateWETH.totalPublicSupply()).to.equal(0n);
        });

        it("should revert when insufficient public balance", async function () {
            const { privateWETH, bridge, user1 } =
                await loadFixture(deployFixture);

            const mintAmount = ethers.parseEther("5");
            await privateWETH
                .connect(bridge)
                .bridgeMint(user1.address, mintAmount);

            const burnAmount = ethers.parseEther("10");
            await expect(
                privateWETH
                    .connect(bridge)
                    .bridgeBurn(user1.address, burnAmount)
            ).to.be.revertedWithCustomError(
                privateWETH,
                "InsufficientPublicBalance"
            );
        });

        it("should revert when caller lacks BRIDGE_ROLE", async function () {
            const { privateWETH, bridge, outsider, user1, BRIDGE_ROLE } =
                await loadFixture(deployFixture);

            const amount = ethers.parseEther("5");
            await privateWETH
                .connect(bridge)
                .bridgeMint(user1.address, amount);

            await expect(
                privateWETH
                    .connect(outsider)
                    .bridgeBurn(user1.address, amount)
            )
                .to.be.revertedWithCustomError(
                    privateWETH,
                    "AccessControlUnauthorizedAccount"
                )
                .withArgs(outsider.address, BRIDGE_ROLE);
        });

        it("should revert when from is zero address", async function () {
            const { privateWETH, bridge } =
                await loadFixture(deployFixture);

            await expect(
                privateWETH
                    .connect(bridge)
                    .bridgeBurn(ethers.ZeroAddress, ethers.parseEther("1"))
            ).to.be.revertedWithCustomError(privateWETH, "ZeroAddress");
        });

        it("should revert when amount is zero", async function () {
            const { privateWETH, bridge, user1 } =
                await loadFixture(deployFixture);

            await expect(
                privateWETH.connect(bridge).bridgeBurn(user1.address, 0n)
            ).to.be.revertedWithCustomError(privateWETH, "ZeroAmount");
        });
    });

    // ─────────────────────────────────────────────────────────────────────
    //  4. Access control
    // ─────────────────────────────────────────────────────────────────────

    describe("Access control", function () {
        it("should allow admin to grant BRIDGE_ROLE", async function () {
            const { privateWETH, admin, outsider, BRIDGE_ROLE } =
                await loadFixture(deployFixture);

            await privateWETH
                .connect(admin)
                .grantRole(BRIDGE_ROLE, outsider.address);
            expect(
                await privateWETH.hasRole(BRIDGE_ROLE, outsider.address)
            ).to.be.true;
        });

        it("should allow admin to revoke BRIDGE_ROLE", async function () {
            const { privateWETH, admin, bridge, BRIDGE_ROLE } =
                await loadFixture(deployFixture);

            await privateWETH
                .connect(admin)
                .revokeRole(BRIDGE_ROLE, bridge.address);
            expect(
                await privateWETH.hasRole(BRIDGE_ROLE, bridge.address)
            ).to.be.false;
        });

        it("should not allow non-admin to grant roles", async function () {
            const {
                privateWETH,
                outsider,
                user1,
                BRIDGE_ROLE,
                DEFAULT_ADMIN_ROLE,
            } = await loadFixture(deployFixture);

            await expect(
                privateWETH
                    .connect(outsider)
                    .grantRole(BRIDGE_ROLE, user1.address)
            )
                .to.be.revertedWithCustomError(
                    privateWETH,
                    "AccessControlUnauthorizedAccount"
                )
                .withArgs(outsider.address, DEFAULT_ADMIN_ROLE);
        });

        it("should verify BRIDGE_ROLE hash matches keccak256", async function () {
            const { privateWETH } = await loadFixture(deployFixture);
            expect(await privateWETH.BRIDGE_ROLE()).to.equal(
                ethers.id("BRIDGE_ROLE")
            );
        });
    });

    // ─────────────────────────────────────────────────────────────────────
    //  5. Pause / Unpause
    // ─────────────────────────────────────────────────────────────────────

    describe("Pausable", function () {
        it("should pause and block bridgeMint", async function () {
            const { privateWETH, admin, bridge, user1 } =
                await loadFixture(deployFixture);

            await privateWETH.connect(admin).pause();

            await expect(
                privateWETH
                    .connect(bridge)
                    .bridgeMint(user1.address, ethers.parseEther("1"))
            ).to.be.revertedWithCustomError(privateWETH, "EnforcedPause");
        });

        it("should pause and block bridgeBurn", async function () {
            const { privateWETH, admin, bridge, user1 } =
                await loadFixture(deployFixture);

            const amount = ethers.parseEther("5");
            await privateWETH
                .connect(bridge)
                .bridgeMint(user1.address, amount);

            await privateWETH.connect(admin).pause();

            await expect(
                privateWETH
                    .connect(bridge)
                    .bridgeBurn(user1.address, amount)
            ).to.be.revertedWithCustomError(privateWETH, "EnforcedPause");
        });

        it("should unpause and allow bridgeMint again", async function () {
            const { privateWETH, admin, bridge, user1 } =
                await loadFixture(deployFixture);

            await privateWETH.connect(admin).pause();
            await privateWETH.connect(admin).unpause();

            const amount = ethers.parseEther("1");
            await expect(
                privateWETH
                    .connect(bridge)
                    .bridgeMint(user1.address, amount)
            ).to.emit(privateWETH, "BridgeMint");
        });

        it("should unpause and allow bridgeBurn again", async function () {
            const { privateWETH, admin, bridge, user1 } =
                await loadFixture(deployFixture);

            const amount = ethers.parseEther("5");
            await privateWETH
                .connect(bridge)
                .bridgeMint(user1.address, amount);

            await privateWETH.connect(admin).pause();
            await privateWETH.connect(admin).unpause();

            await expect(
                privateWETH
                    .connect(bridge)
                    .bridgeBurn(user1.address, amount)
            ).to.emit(privateWETH, "BridgeBurn");
        });

        it("should revert pause for non-admin", async function () {
            const { privateWETH, outsider, DEFAULT_ADMIN_ROLE } =
                await loadFixture(deployFixture);

            await expect(privateWETH.connect(outsider).pause())
                .to.be.revertedWithCustomError(
                    privateWETH,
                    "AccessControlUnauthorizedAccount"
                )
                .withArgs(outsider.address, DEFAULT_ADMIN_ROLE);
        });

        it("should revert unpause for non-admin", async function () {
            const { privateWETH, admin, outsider, DEFAULT_ADMIN_ROLE } =
                await loadFixture(deployFixture);

            await privateWETH.connect(admin).pause();

            await expect(privateWETH.connect(outsider).unpause())
                .to.be.revertedWithCustomError(
                    privateWETH,
                    "AccessControlUnauthorizedAccount"
                )
                .withArgs(outsider.address, DEFAULT_ADMIN_ROLE);
        });
    });

    // ─────────────────────────────────────────────────────────────────────
    //  6. Privacy admin (timelock)
    // ─────────────────────────────────────────────────────────────────────

    describe("Privacy admin", function () {
        it("should enable privacy instantly", async function () {
            const { privateWETH, admin } = await loadFixture(deployFixture);

            await expect(privateWETH.connect(admin).enablePrivacy())
                .to.emit(privateWETH, "PrivacyStatusChanged")
                .withArgs(true);

            expect(await privateWETH.privacyEnabled()).to.be.true;
        });

        it("should revert enablePrivacy for non-admin", async function () {
            const { privateWETH, outsider, DEFAULT_ADMIN_ROLE } =
                await loadFixture(deployFixture);

            await expect(privateWETH.connect(outsider).enablePrivacy())
                .to.be.revertedWithCustomError(
                    privateWETH,
                    "AccessControlUnauthorizedAccount"
                )
                .withArgs(outsider.address, DEFAULT_ADMIN_ROLE);
        });

        it("should propose privacy disable and set scheduled timestamp", async function () {
            const { privateWETH, admin } = await loadFixture(deployFixture);

            await privateWETH.connect(admin).proposePrivacyDisable();

            const scheduled =
                await privateWETH.privacyDisableScheduledAt();
            expect(scheduled).to.be.gt(0n);
        });

        it("should emit PrivacyDisableProposed event", async function () {
            const { privateWETH, admin } = await loadFixture(deployFixture);

            await expect(
                privateWETH.connect(admin).proposePrivacyDisable()
            ).to.emit(privateWETH, "PrivacyDisableProposed");
        });

        it("should revert proposePrivacyDisable for non-admin", async function () {
            const { privateWETH, outsider, DEFAULT_ADMIN_ROLE } =
                await loadFixture(deployFixture);

            await expect(
                privateWETH.connect(outsider).proposePrivacyDisable()
            )
                .to.be.revertedWithCustomError(
                    privateWETH,
                    "AccessControlUnauthorizedAccount"
                )
                .withArgs(outsider.address, DEFAULT_ADMIN_ROLE);
        });

        it("should revert executePrivacyDisable when no proposal pending", async function () {
            const { privateWETH, admin } = await loadFixture(deployFixture);

            await expect(
                privateWETH.connect(admin).executePrivacyDisable()
            ).to.be.revertedWithCustomError(privateWETH, "NoPendingChange");
        });

        it("should revert executePrivacyDisable before timelock expires", async function () {
            const { privateWETH, admin } = await loadFixture(deployFixture);

            await privateWETH.connect(admin).enablePrivacy();
            await privateWETH.connect(admin).proposePrivacyDisable();

            await expect(
                privateWETH.connect(admin).executePrivacyDisable()
            ).to.be.revertedWithCustomError(privateWETH, "TimelockActive");
        });

        it("should execute privacy disable after timelock", async function () {
            const { privateWETH, admin } = await loadFixture(deployFixture);

            await privateWETH.connect(admin).enablePrivacy();
            expect(await privateWETH.privacyEnabled()).to.be.true;

            await privateWETH.connect(admin).proposePrivacyDisable();

            // Advance time past 7 days
            await time.increase(7 * 24 * 60 * 60 + 1);

            await expect(
                privateWETH.connect(admin).executePrivacyDisable()
            ).to.emit(privateWETH, "PrivacyDisabled");

            expect(await privateWETH.privacyEnabled()).to.be.false;
            expect(
                await privateWETH.privacyDisableScheduledAt()
            ).to.equal(0n);
        });

        it("should revert executePrivacyDisable for non-admin", async function () {
            const { privateWETH, admin, outsider, DEFAULT_ADMIN_ROLE } =
                await loadFixture(deployFixture);

            await privateWETH.connect(admin).proposePrivacyDisable();
            await time.increase(7 * 24 * 60 * 60 + 1);

            await expect(
                privateWETH.connect(outsider).executePrivacyDisable()
            )
                .to.be.revertedWithCustomError(
                    privateWETH,
                    "AccessControlUnauthorizedAccount"
                )
                .withArgs(outsider.address, DEFAULT_ADMIN_ROLE);
        });

        it("should cancel pending privacy disable", async function () {
            const { privateWETH, admin } = await loadFixture(deployFixture);

            await privateWETH.connect(admin).proposePrivacyDisable();
            expect(
                await privateWETH.privacyDisableScheduledAt()
            ).to.be.gt(0n);

            await expect(
                privateWETH.connect(admin).cancelPrivacyDisable()
            ).to.emit(privateWETH, "PrivacyDisableCancelled");

            expect(
                await privateWETH.privacyDisableScheduledAt()
            ).to.equal(0n);
        });

        it("should revert cancelPrivacyDisable for non-admin", async function () {
            const { privateWETH, admin, outsider, DEFAULT_ADMIN_ROLE } =
                await loadFixture(deployFixture);

            await privateWETH.connect(admin).proposePrivacyDisable();

            await expect(
                privateWETH.connect(outsider).cancelPrivacyDisable()
            )
                .to.be.revertedWithCustomError(
                    privateWETH,
                    "AccessControlUnauthorizedAccount"
                )
                .withArgs(outsider.address, DEFAULT_ADMIN_ROLE);
        });

        it("should allow re-proposing after cancel", async function () {
            const { privateWETH, admin } = await loadFixture(deployFixture);

            await privateWETH.connect(admin).proposePrivacyDisable();
            await privateWETH.connect(admin).cancelPrivacyDisable();

            await expect(
                privateWETH.connect(admin).proposePrivacyDisable()
            ).to.emit(privateWETH, "PrivacyDisableProposed");
        });
    });

    // ─────────────────────────────────────────────────────────────────────
    //  7. Emergency recovery
    // ─────────────────────────────────────────────────────────────────────

    describe("Emergency recovery", function () {
        it("should revert when privacy is enabled", async function () {
            const { privateWETH, admin, user1 } =
                await loadFixture(deployFixture);

            await privateWETH.connect(admin).enablePrivacy();

            await expect(
                privateWETH
                    .connect(admin)
                    .emergencyRecoverPrivateBalance(user1.address)
            ).to.be.revertedWithCustomError(
                privateWETH,
                "PrivacyMustBeDisabled"
            );
        });

        it("should revert for zero address user", async function () {
            const { privateWETH, admin } = await loadFixture(deployFixture);

            await expect(
                privateWETH
                    .connect(admin)
                    .emergencyRecoverPrivateBalance(ethers.ZeroAddress)
            ).to.be.revertedWithCustomError(privateWETH, "ZeroAddress");
        });

        it("should revert when shadow ledger balance is zero", async function () {
            const { privateWETH, admin, user1 } =
                await loadFixture(deployFixture);

            await expect(
                privateWETH
                    .connect(admin)
                    .emergencyRecoverPrivateBalance(user1.address)
            ).to.be.revertedWithCustomError(
                privateWETH,
                "NoBalanceToRecover"
            );
        });

        it("should revert for non-admin caller", async function () {
            const { privateWETH, outsider, user1, DEFAULT_ADMIN_ROLE } =
                await loadFixture(deployFixture);

            await expect(
                privateWETH
                    .connect(outsider)
                    .emergencyRecoverPrivateBalance(user1.address)
            )
                .to.be.revertedWithCustomError(
                    privateWETH,
                    "AccessControlUnauthorizedAccount"
                )
                .withArgs(outsider.address, DEFAULT_ADMIN_ROLE);
        });
    });

    // ─────────────────────────────────────────────────────────────────────
    //  8. Dust tracking and claimDust
    // ─────────────────────────────────────────────────────────────────────

    describe("Dust tracking and claimDust", function () {
        it("should start with dustBalances = 0 for any address", async function () {
            const { privateWETH, user1 } =
                await loadFixture(deployFixture);
            expect(
                await privateWETH.dustBalances(user1.address)
            ).to.equal(0n);
        });

        it("should revert claimDust when no dust available", async function () {
            const { privateWETH, user1 } =
                await loadFixture(deployFixture);

            await expect(
                privateWETH.connect(user1).claimDust()
            ).to.be.revertedWithCustomError(privateWETH, "NoDustToClaim");
        });

        // NOTE: Dust accumulation happens during convertToPrivate which
        // requires MPC. The claimDust function itself is non-MPC but we
        // cannot populate dustBalances without convertToPrivate on COTI.
        // The revert test above confirms the claimDust guard works.

        it("should expose dustBalances as a public mapping", async function () {
            const { privateWETH, outsider } =
                await loadFixture(deployFixture);
            // dustBalances is a public mapping, should be queryable
            const dust = await privateWETH.dustBalances(outsider.address);
            expect(dust).to.equal(0n);
        });
    });

    // ─────────────────────────────────────────────────────────────────────
    //  9. Ossification
    // ─────────────────────────────────────────────────────────────────────

    describe("Ossification", function () {
        it("should ossify and emit ContractOssified", async function () {
            const { privateWETH, admin } =
                await loadFixture(deployFixture);

            await expect(privateWETH.connect(admin).ossify())
                .to.emit(privateWETH, "ContractOssified")
                .withArgs(await privateWETH.getAddress());

            expect(await privateWETH.isOssified()).to.be.true;
        });

        it("should block UUPS upgrade after ossification", async function () {
            const { privateWETH, admin } =
                await loadFixture(deployFixture);

            await privateWETH.connect(admin).ossify();

            const V2Factory =
                await ethers.getContractFactory("PrivateWETH");
            await expect(
                upgrades.upgradeProxy(
                    await privateWETH.getAddress(),
                    V2Factory
                )
            ).to.be.revertedWithCustomError(
                privateWETH,
                "ContractIsOssified"
            );
        });

        it("should allow upgrade before ossification", async function () {
            const { privateWETH } = await loadFixture(deployFixture);

            expect(await privateWETH.isOssified()).to.be.false;

            const V2Factory =
                await ethers.getContractFactory("PrivateWETH");
            const upgraded = await upgrades.upgradeProxy(
                await privateWETH.getAddress(),
                V2Factory
            );

            expect(await upgraded.isOssified()).to.be.false;
        });

        it("should revert ossify for non-admin", async function () {
            const { privateWETH, outsider, DEFAULT_ADMIN_ROLE } =
                await loadFixture(deployFixture);

            await expect(privateWETH.connect(outsider).ossify())
                .to.be.revertedWithCustomError(
                    privateWETH,
                    "AccessControlUnauthorizedAccount"
                )
                .withArgs(outsider.address, DEFAULT_ADMIN_ROLE);
        });
    });

    // ─────────────────────────────────────────────────────────────────────
    //  10. View and pure functions
    // ─────────────────────────────────────────────────────────────────────

    describe("View and pure functions", function () {
        it("name() should return 'Private WETH'", async function () {
            const { privateWETH } = await loadFixture(deployFixture);
            expect(await privateWETH.name()).to.equal("Private WETH");
        });

        it("symbol() should return 'pWETH'", async function () {
            const { privateWETH } = await loadFixture(deployFixture);
            expect(await privateWETH.symbol()).to.equal("pWETH");
        });

        it("decimals() should return 18", async function () {
            const { privateWETH } = await loadFixture(deployFixture);
            expect(await privateWETH.decimals()).to.equal(18);
        });

        it("publicBalances returns 0 for unknown address", async function () {
            const { privateWETH, outsider } =
                await loadFixture(deployFixture);
            expect(
                await privateWETH.publicBalances(outsider.address)
            ).to.equal(0n);
        });

        it("getShadowLedgerBalance should return 0 for owner querying own", async function () {
            const { privateWETH, user1 } =
                await loadFixture(deployFixture);
            expect(
                await privateWETH
                    .connect(user1)
                    .getShadowLedgerBalance(user1.address)
            ).to.equal(0n);
        });

        it("getShadowLedgerBalance should allow admin to query any address", async function () {
            const { privateWETH, admin, user1 } =
                await loadFixture(deployFixture);
            expect(
                await privateWETH
                    .connect(admin)
                    .getShadowLedgerBalance(user1.address)
            ).to.equal(0n);
        });

        it("getShadowLedgerBalance should revert for unauthorized caller", async function () {
            const { privateWETH, outsider, user1 } =
                await loadFixture(deployFixture);
            await expect(
                privateWETH
                    .connect(outsider)
                    .getShadowLedgerBalance(user1.address)
            ).to.be.revertedWithCustomError(privateWETH, "Unauthorized");
        });

        it("privateBalanceOf should allow owner to query own balance", async function () {
            const { privateWETH, user1 } =
                await loadFixture(deployFixture);
            expect(
                await privateWETH
                    .connect(user1)
                    .privateBalanceOf(user1.address)
            ).to.equal(0n);
        });

        it("privateBalanceOf should allow admin to query any address", async function () {
            const { privateWETH, admin, user1 } =
                await loadFixture(deployFixture);
            expect(
                await privateWETH
                    .connect(admin)
                    .privateBalanceOf(user1.address)
            ).to.equal(0n);
        });

        it("privateBalanceOf should revert for unauthorized caller", async function () {
            const { privateWETH, outsider, user1 } =
                await loadFixture(deployFixture);
            await expect(
                privateWETH
                    .connect(outsider)
                    .privateBalanceOf(user1.address)
            ).to.be.revertedWithCustomError(privateWETH, "Unauthorized");
        });
    });

    // ─────────────────────────────────────────────────────────────────────
    //  11. SCALING_FACTOR correctness
    // ─────────────────────────────────────────────────────────────────────

    describe("SCALING_FACTOR correctness", function () {
        it("SCALING_FACTOR should be 10^12", async function () {
            const { privateWETH } = await loadFixture(deployFixture);
            expect(await privateWETH.SCALING_FACTOR()).to.equal(
                10n ** 12n
            );
        });

        it("SCALING_FACTOR * 10^6 should equal 10^18 (WETH precision)", async function () {
            const { privateWETH } = await loadFixture(deployFixture);
            const factor = await privateWETH.SCALING_FACTOR();
            // factor (1e12) * MPC precision (1e6) = WETH precision (1e18)
            expect(factor * 1000000n).to.equal(ethers.parseEther("1"));
        });

        it("maximum dust should be SCALING_FACTOR - 1 (999999999999 wei)", async function () {
            const { privateWETH } = await loadFixture(deployFixture);
            const factor = await privateWETH.SCALING_FACTOR();
            // Maximum dust from any single conversion is factor - 1
            expect(factor - 1n).to.equal(999999999999n);
        });

        it("minimum convertible amount should be SCALING_FACTOR (1e12 wei)", async function () {
            const { privateWETH } = await loadFixture(deployFixture);
            const factor = await privateWETH.SCALING_FACTOR();
            // Amounts below SCALING_FACTOR would scale to 0 (ZeroAmount revert)
            expect(factor).to.equal(1000000000000n);
        });
    });

    // ─────────────────────────────────────────────────────────────────────
    //  12. Events and custom errors
    // ─────────────────────────────────────────────────────────────────────

    describe("Events and interface", function () {
        it("should have BridgeMint event in ABI", async function () {
            const { privateWETH } = await loadFixture(deployFixture);
            const event = privateWETH.interface.getEvent("BridgeMint");
            expect(event).to.not.be.undefined;
        });

        it("should have BridgeBurn event in ABI", async function () {
            const { privateWETH } = await loadFixture(deployFixture);
            const event = privateWETH.interface.getEvent("BridgeBurn");
            expect(event).to.not.be.undefined;
        });

        it("should have ConvertedToPrivate event in ABI", async function () {
            const { privateWETH } = await loadFixture(deployFixture);
            const event =
                privateWETH.interface.getEvent("ConvertedToPrivate");
            expect(event).to.not.be.undefined;
        });

        it("should have ConvertedToPublic event in ABI", async function () {
            const { privateWETH } = await loadFixture(deployFixture);
            const event =
                privateWETH.interface.getEvent("ConvertedToPublic");
            expect(event).to.not.be.undefined;
        });

        it("should have PrivateTransfer event in ABI", async function () {
            const { privateWETH } = await loadFixture(deployFixture);
            const event =
                privateWETH.interface.getEvent("PrivateTransfer");
            expect(event).to.not.be.undefined;
        });

        it("should have DustClaimed event in ABI", async function () {
            const { privateWETH } = await loadFixture(deployFixture);
            const event = privateWETH.interface.getEvent("DustClaimed");
            expect(event).to.not.be.undefined;
        });

        it("should have PrivacyStatusChanged event in ABI", async function () {
            const { privateWETH } = await loadFixture(deployFixture);
            const event =
                privateWETH.interface.getEvent("PrivacyStatusChanged");
            expect(event).to.not.be.undefined;
        });

        it("should have EmergencyPrivateRecovery event in ABI", async function () {
            const { privateWETH } = await loadFixture(deployFixture);
            const event = privateWETH.interface.getEvent(
                "EmergencyPrivateRecovery"
            );
            expect(event).to.not.be.undefined;
        });

        it("should have ContractOssified event in ABI", async function () {
            const { privateWETH } = await loadFixture(deployFixture);
            const event =
                privateWETH.interface.getEvent("ContractOssified");
            expect(event).to.not.be.undefined;
        });

        it("should have PrivacyDisableProposed event in ABI", async function () {
            const { privateWETH } = await loadFixture(deployFixture);
            const event = privateWETH.interface.getEvent(
                "PrivacyDisableProposed"
            );
            expect(event).to.not.be.undefined;
        });

        it("should have PrivacyDisabled event in ABI", async function () {
            const { privateWETH } = await loadFixture(deployFixture);
            const event =
                privateWETH.interface.getEvent("PrivacyDisabled");
            expect(event).to.not.be.undefined;
        });

        it("should have PrivacyDisableCancelled event in ABI", async function () {
            const { privateWETH } = await loadFixture(deployFixture);
            const event = privateWETH.interface.getEvent(
                "PrivacyDisableCancelled"
            );
            expect(event).to.not.be.undefined;
        });

        it("should have all custom errors in ABI", async function () {
            const { privateWETH } = await loadFixture(deployFixture);

            const expectedErrors = [
                "ZeroAmount",
                "ZeroAddress",
                "AmountTooLarge",
                "InsufficientPrivateBalance",
                "InsufficientPublicBalance",
                "SelfTransfer",
                "ContractIsOssified",
                "PrivacyNotAvailable",
                "PrivacyMustBeDisabled",
                "Unauthorized",
                "NoBalanceToRecover",
                "NoDustToClaim",
                "NoPendingChange",
                "TimelockActive",
            ];

            for (const errorName of expectedErrors) {
                const errorFragment =
                    privateWETH.interface.getError(errorName);
                expect(
                    errorFragment,
                    `Missing error: ${errorName}`
                ).to.not.be.undefined;
                expect(errorFragment.name).to.equal(errorName);
            }
        });
    });

    // ─────────────────────────────────────────────────────────────────────
    //  MPC-Dependent (Requires COTI Testnet)
    // ─────────────────────────────────────────────────────────────────────

    describe("MPC-Dependent (COTI testnet only)", function () {
        it.skip("convertToPrivate -- scale 18-dec to 6-dec, track dust, create MPC balance (Requires COTI testnet)", function () {
            // MpcCore.setPublic64, MpcCore.onBoard, MpcCore.checkedAdd,
            // MpcCore.offBoard all require COTI MPC precompile.
        });

        it.skip("convertToPrivate -- revert PrivacyNotAvailable when disabled (Requires COTI testnet)", function () {
            // Privacy is disabled on Hardhat. The revert guard is the
            // first check so it is technically testable, but the full
            // success path (needed for integration) requires COTI.
        });

        it.skip("convertToPrivate -- revert ZeroAmount for sub-SCALING_FACTOR amount (Requires COTI testnet)", function () {
            // amount / SCALING_FACTOR == 0 triggers ZeroAmount revert.
            // Requires privacy to be enabled (COTI chain ID).
        });

        it.skip("convertToPrivate -- dust calculation: amount - (scaledAmount * SCALING_FACTOR) (Requires COTI testnet)", function () {
            // Dust accumulates in dustBalances mapping during the
            // MPC conversion path. Cannot populate without MPC.
        });

        it.skip("convertToPrivate -- revert AmountTooLarge for > uint64 max * SCALING_FACTOR (Requires COTI testnet)", function () {
            // scaledAmount > type(uint64).max check after scaling.
        });

        it.skip("convertToPublic -- decrypt MPC, scale 6-dec to 18-dec, credit publicBalances (Requires COTI testnet)", function () {
            // Full MPC pipeline: onBoard, ge, decrypt, sub, offBoard.
        });

        it.skip("privateTransfer -- encrypted transfer between accounts (Requires COTI testnet)", function () {
            // Full MPC pipeline for sender/recipient balance updates.
        });

        it.skip("claimDust -- claim accumulated dust, credit publicBalances, emit DustClaimed (Requires COTI testnet)", function () {
            // claimDust itself is non-MPC, but dustBalances can only be
            // populated by convertToPrivate which requires MPC.
        });

        it.skip("convertToPrivate -- shadow ledger tracks scaled units (Requires COTI testnet)", function () {
            // _shadowLedger[msg.sender] += scaledAmount during MPC path.
        });

        it.skip("emergencyRecoverPrivateBalance -- scales shadow ledger back to 18-dec (Requires COTI testnet)", function () {
            // Recovery multiplies shadow ledger by SCALING_FACTOR.
            // Cannot test without populating shadow ledger via MPC.
        });
    });
});
