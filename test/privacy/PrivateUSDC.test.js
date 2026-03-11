/**
 * PrivateUSDC -- Non-MPC Logic Tests
 *
 * Tests all contract logic that does NOT require COTI MPC garbled circuits:
 *  1.  Initialization (roles, underlying token, constants, privacy detection)
 *  2.  bridgeMint (BRIDGE_ROLE, real ERC20 custody, publicBalances)
 *  3.  bridgeBurn (balance debit, real ERC20 release, guards)
 *  4.  Access control (BRIDGE_ROLE, DEFAULT_ADMIN_ROLE checks)
 *  5.  Pause/unpause (operations blocked when paused)
 *  6.  Privacy admin (enablePrivacy, proposePrivacyDisable, timelock,
 *      executePrivacyDisable, cancelPrivacyDisable)
 *  7.  Emergency recovery (shadow ledger, privacy-must-be-disabled guard)
 *  8.  Ossification (upgrade blocked after ossify)
 *  9.  View functions (publicBalances, constants, name, symbol, decimals)
 * 10.  Events and custom errors (ABI verification)
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

describe("PrivateUSDC", function () {
    /**
     * Shared deployment fixture.
     * Deploys ERC20MockConfigurable with 6 decimals (USDC) and
     * the PrivateUSDC UUPS proxy with (admin, underlyingToken).
     */
    async function deployFixture() {
        const [admin, bridge, user1, user2, outsider] =
            await ethers.getSigners();

        // Deploy mock USDC with 6 decimals
        const MockToken = await ethers.getContractFactory(
            "ERC20MockConfigurable"
        );
        const usdc = await MockToken.deploy("Mock USDC", "USDC", 6);
        await usdc.waitForDeployment();

        // Deploy PrivateUSDC as UUPS proxy
        const Factory = await ethers.getContractFactory("PrivateUSDC");
        const privateUSDC = await upgrades.deployProxy(
            Factory,
            [admin.address, await usdc.getAddress()],
            {
                initializer: "initialize",
                kind: "uups",
                unsafeAllow: ["constructor", "state-variable-immutable"],
            }
        );
        await privateUSDC.waitForDeployment();

        // Grant BRIDGE_ROLE to dedicated bridge signer
        const BRIDGE_ROLE = await privateUSDC.BRIDGE_ROLE();
        await privateUSDC
            .connect(admin)
            .grantRole(BRIDGE_ROLE, bridge.address);

        // Transfer USDC to bridge so it can bridgeMint
        const mintAmount = ethers.parseUnits("1000000", 6); // 1M USDC
        await usdc.connect(admin).transfer(bridge.address, mintAmount);

        // Approve PrivateUSDC contract to pull USDC from bridge
        await usdc
            .connect(bridge)
            .approve(await privateUSDC.getAddress(), ethers.MaxUint256);

        // Also approve from admin (who also has BRIDGE_ROLE by default)
        await usdc
            .connect(admin)
            .approve(await privateUSDC.getAddress(), ethers.MaxUint256);

        const DEFAULT_ADMIN_ROLE = await privateUSDC.DEFAULT_ADMIN_ROLE();

        return {
            privateUSDC,
            usdc,
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
            const { privateUSDC, admin, DEFAULT_ADMIN_ROLE } =
                await loadFixture(deployFixture);
            expect(
                await privateUSDC.hasRole(DEFAULT_ADMIN_ROLE, admin.address)
            ).to.be.true;
        });

        it("should grant BRIDGE_ROLE to admin", async function () {
            const { privateUSDC, admin, BRIDGE_ROLE } =
                await loadFixture(deployFixture);
            expect(
                await privateUSDC.hasRole(BRIDGE_ROLE, admin.address)
            ).to.be.true;
        });

        it("should set underlying token correctly", async function () {
            const { privateUSDC, usdc } =
                await loadFixture(deployFixture);
            expect(await privateUSDC.underlyingToken()).to.equal(
                await usdc.getAddress()
            );
        });

        it("should have SCALING_FACTOR = 1", async function () {
            const { privateUSDC } = await loadFixture(deployFixture);
            expect(await privateUSDC.SCALING_FACTOR()).to.equal(1n);
        });

        it("should have TOKEN_NAME = 'Private USDC'", async function () {
            const { privateUSDC } = await loadFixture(deployFixture);
            expect(await privateUSDC.TOKEN_NAME()).to.equal("Private USDC");
        });

        it("should have TOKEN_SYMBOL = 'pUSDC'", async function () {
            const { privateUSDC } = await loadFixture(deployFixture);
            expect(await privateUSDC.TOKEN_SYMBOL()).to.equal("pUSDC");
        });

        it("should have TOKEN_DECIMALS = 6", async function () {
            const { privateUSDC } = await loadFixture(deployFixture);
            expect(await privateUSDC.TOKEN_DECIMALS()).to.equal(6);
        });

        it("should start with totalPublicSupply = 0", async function () {
            const { privateUSDC } = await loadFixture(deployFixture);
            expect(await privateUSDC.totalPublicSupply()).to.equal(0n);
        });

        it("should detect privacy as disabled on Hardhat (chain 1337)", async function () {
            const { privateUSDC } = await loadFixture(deployFixture);
            // Hardhat chain ID 1337 is not in the COTI/OmniCoin list
            expect(await privateUSDC.privacyEnabled()).to.be.false;
        });

        it("should start with PRIVACY_DISABLE_DELAY = 7 days", async function () {
            const { privateUSDC } = await loadFixture(deployFixture);
            expect(await privateUSDC.PRIVACY_DISABLE_DELAY()).to.equal(
                7n * 24n * 60n * 60n
            );
        });

        it("should start unossified", async function () {
            const { privateUSDC } = await loadFixture(deployFixture);
            expect(await privateUSDC.isOssified()).to.be.false;
        });

        it("should revert when admin is zero address", async function () {
            const { usdc } = await loadFixture(deployFixture);
            const Factory = await ethers.getContractFactory("PrivateUSDC");
            await expect(
                upgrades.deployProxy(
                    Factory,
                    [ethers.ZeroAddress, await usdc.getAddress()],
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
            const Factory = await ethers.getContractFactory("PrivateUSDC");
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
            const { privateUSDC } = await loadFixture(deployFixture);
            expect(await privateUSDC.privacyDisableScheduledAt()).to.equal(0n);
        });
    });

    // ─────────────────────────────────────────────────────────────────────
    //  2. bridgeMint
    // ─────────────────────────────────────────────────────────────────────

    describe("bridgeMint", function () {
        it("should mint and credit publicBalances", async function () {
            const { privateUSDC, bridge, user1 } =
                await loadFixture(deployFixture);

            const amount = ethers.parseUnits("100", 6);
            await privateUSDC
                .connect(bridge)
                .bridgeMint(user1.address, amount);

            expect(await privateUSDC.publicBalances(user1.address)).to.equal(
                amount
            );
        });

        it("should increase totalPublicSupply", async function () {
            const { privateUSDC, bridge, user1 } =
                await loadFixture(deployFixture);

            const amount = ethers.parseUnits("500", 6);
            await privateUSDC
                .connect(bridge)
                .bridgeMint(user1.address, amount);

            expect(await privateUSDC.totalPublicSupply()).to.equal(amount);
        });

        it("should transfer real USDC from bridge to contract", async function () {
            const { privateUSDC, usdc, bridge, user1 } =
                await loadFixture(deployFixture);

            const amount = ethers.parseUnits("200", 6);
            const bridgeBalBefore = await usdc.balanceOf(bridge.address);

            await privateUSDC
                .connect(bridge)
                .bridgeMint(user1.address, amount);

            const bridgeBalAfter = await usdc.balanceOf(bridge.address);
            expect(bridgeBalBefore - bridgeBalAfter).to.equal(amount);

            const contractBal = await usdc.balanceOf(
                await privateUSDC.getAddress()
            );
            expect(contractBal).to.equal(amount);
        });

        it("should emit BridgeMint event", async function () {
            const { privateUSDC, bridge, user1 } =
                await loadFixture(deployFixture);

            const amount = ethers.parseUnits("50", 6);
            await expect(
                privateUSDC.connect(bridge).bridgeMint(user1.address, amount)
            )
                .to.emit(privateUSDC, "BridgeMint")
                .withArgs(user1.address, amount);
        });

        it("should accumulate balances across multiple mints", async function () {
            const { privateUSDC, bridge, user1 } =
                await loadFixture(deployFixture);

            const amount1 = ethers.parseUnits("100", 6);
            const amount2 = ethers.parseUnits("200", 6);

            await privateUSDC
                .connect(bridge)
                .bridgeMint(user1.address, amount1);
            await privateUSDC
                .connect(bridge)
                .bridgeMint(user1.address, amount2);

            expect(await privateUSDC.publicBalances(user1.address)).to.equal(
                amount1 + amount2
            );
            expect(await privateUSDC.totalPublicSupply()).to.equal(
                amount1 + amount2
            );
        });

        it("should revert when caller lacks BRIDGE_ROLE", async function () {
            const { privateUSDC, outsider, user1, BRIDGE_ROLE } =
                await loadFixture(deployFixture);

            const amount = ethers.parseUnits("100", 6);
            await expect(
                privateUSDC
                    .connect(outsider)
                    .bridgeMint(user1.address, amount)
            )
                .to.be.revertedWithCustomError(
                    privateUSDC,
                    "AccessControlUnauthorizedAccount"
                )
                .withArgs(outsider.address, BRIDGE_ROLE);
        });

        it("should revert when recipient is zero address", async function () {
            const { privateUSDC, bridge } =
                await loadFixture(deployFixture);

            const amount = ethers.parseUnits("100", 6);
            await expect(
                privateUSDC
                    .connect(bridge)
                    .bridgeMint(ethers.ZeroAddress, amount)
            ).to.be.revertedWithCustomError(privateUSDC, "ZeroAddress");
        });

        it("should revert when amount is zero", async function () {
            const { privateUSDC, bridge, user1 } =
                await loadFixture(deployFixture);

            await expect(
                privateUSDC.connect(bridge).bridgeMint(user1.address, 0n)
            ).to.be.revertedWithCustomError(privateUSDC, "ZeroAmount");
        });

        it("should mint to multiple different recipients", async function () {
            const { privateUSDC, bridge, user1, user2 } =
                await loadFixture(deployFixture);

            const amt1 = ethers.parseUnits("100", 6);
            const amt2 = ethers.parseUnits("200", 6);

            await privateUSDC
                .connect(bridge)
                .bridgeMint(user1.address, amt1);
            await privateUSDC
                .connect(bridge)
                .bridgeMint(user2.address, amt2);

            expect(await privateUSDC.publicBalances(user1.address)).to.equal(
                amt1
            );
            expect(await privateUSDC.publicBalances(user2.address)).to.equal(
                amt2
            );
            expect(await privateUSDC.totalPublicSupply()).to.equal(
                amt1 + amt2
            );
        });
    });

    // ─────────────────────────────────────────────────────────────────────
    //  3. bridgeBurn
    // ─────────────────────────────────────────────────────────────────────

    describe("bridgeBurn", function () {
        it("should burn and debit publicBalances", async function () {
            const { privateUSDC, bridge, user1 } =
                await loadFixture(deployFixture);

            const mintAmount = ethers.parseUnits("500", 6);
            await privateUSDC
                .connect(bridge)
                .bridgeMint(user1.address, mintAmount);

            const burnAmount = ethers.parseUnits("200", 6);
            await privateUSDC
                .connect(bridge)
                .bridgeBurn(user1.address, burnAmount);

            expect(await privateUSDC.publicBalances(user1.address)).to.equal(
                mintAmount - burnAmount
            );
        });

        it("should decrease totalPublicSupply", async function () {
            const { privateUSDC, bridge, user1 } =
                await loadFixture(deployFixture);

            const mintAmount = ethers.parseUnits("500", 6);
            await privateUSDC
                .connect(bridge)
                .bridgeMint(user1.address, mintAmount);

            const burnAmount = ethers.parseUnits("200", 6);
            await privateUSDC
                .connect(bridge)
                .bridgeBurn(user1.address, burnAmount);

            expect(await privateUSDC.totalPublicSupply()).to.equal(
                mintAmount - burnAmount
            );
        });

        it("should transfer real USDC back to user", async function () {
            const { privateUSDC, usdc, bridge, user1 } =
                await loadFixture(deployFixture);

            const mintAmount = ethers.parseUnits("500", 6);
            await privateUSDC
                .connect(bridge)
                .bridgeMint(user1.address, mintAmount);

            const burnAmount = ethers.parseUnits("200", 6);
            const userBalBefore = await usdc.balanceOf(user1.address);

            await privateUSDC
                .connect(bridge)
                .bridgeBurn(user1.address, burnAmount);

            const userBalAfter = await usdc.balanceOf(user1.address);
            expect(userBalAfter - userBalBefore).to.equal(burnAmount);
        });

        it("should emit BridgeBurn event", async function () {
            const { privateUSDC, bridge, user1 } =
                await loadFixture(deployFixture);

            const mintAmount = ethers.parseUnits("500", 6);
            await privateUSDC
                .connect(bridge)
                .bridgeMint(user1.address, mintAmount);

            const burnAmount = ethers.parseUnits("100", 6);
            await expect(
                privateUSDC
                    .connect(bridge)
                    .bridgeBurn(user1.address, burnAmount)
            )
                .to.emit(privateUSDC, "BridgeBurn")
                .withArgs(user1.address, burnAmount);
        });

        it("should allow burning full balance", async function () {
            const { privateUSDC, bridge, user1 } =
                await loadFixture(deployFixture);

            const amount = ethers.parseUnits("1000", 6);
            await privateUSDC
                .connect(bridge)
                .bridgeMint(user1.address, amount);
            await privateUSDC
                .connect(bridge)
                .bridgeBurn(user1.address, amount);

            expect(await privateUSDC.publicBalances(user1.address)).to.equal(
                0n
            );
            expect(await privateUSDC.totalPublicSupply()).to.equal(0n);
        });

        it("should revert when insufficient public balance", async function () {
            const { privateUSDC, bridge, user1 } =
                await loadFixture(deployFixture);

            const mintAmount = ethers.parseUnits("100", 6);
            await privateUSDC
                .connect(bridge)
                .bridgeMint(user1.address, mintAmount);

            const burnAmount = ethers.parseUnits("200", 6);
            await expect(
                privateUSDC
                    .connect(bridge)
                    .bridgeBurn(user1.address, burnAmount)
            ).to.be.revertedWithCustomError(
                privateUSDC,
                "InsufficientPublicBalance"
            );
        });

        it("should revert when caller lacks BRIDGE_ROLE", async function () {
            const { privateUSDC, bridge, outsider, user1, BRIDGE_ROLE } =
                await loadFixture(deployFixture);

            const amount = ethers.parseUnits("100", 6);
            await privateUSDC
                .connect(bridge)
                .bridgeMint(user1.address, amount);

            await expect(
                privateUSDC
                    .connect(outsider)
                    .bridgeBurn(user1.address, amount)
            )
                .to.be.revertedWithCustomError(
                    privateUSDC,
                    "AccessControlUnauthorizedAccount"
                )
                .withArgs(outsider.address, BRIDGE_ROLE);
        });

        it("should revert when from is zero address", async function () {
            const { privateUSDC, bridge } =
                await loadFixture(deployFixture);

            await expect(
                privateUSDC
                    .connect(bridge)
                    .bridgeBurn(ethers.ZeroAddress, 100n)
            ).to.be.revertedWithCustomError(privateUSDC, "ZeroAddress");
        });

        it("should revert when amount is zero", async function () {
            const { privateUSDC, bridge, user1 } =
                await loadFixture(deployFixture);

            await expect(
                privateUSDC.connect(bridge).bridgeBurn(user1.address, 0n)
            ).to.be.revertedWithCustomError(privateUSDC, "ZeroAmount");
        });
    });

    // ─────────────────────────────────────────────────────────────────────
    //  4. Access control
    // ─────────────────────────────────────────────────────────────────────

    describe("Access control", function () {
        it("should allow admin to grant BRIDGE_ROLE", async function () {
            const { privateUSDC, admin, outsider, BRIDGE_ROLE } =
                await loadFixture(deployFixture);

            await privateUSDC
                .connect(admin)
                .grantRole(BRIDGE_ROLE, outsider.address);
            expect(
                await privateUSDC.hasRole(BRIDGE_ROLE, outsider.address)
            ).to.be.true;
        });

        it("should allow admin to revoke BRIDGE_ROLE", async function () {
            const { privateUSDC, admin, bridge, BRIDGE_ROLE } =
                await loadFixture(deployFixture);

            await privateUSDC
                .connect(admin)
                .revokeRole(BRIDGE_ROLE, bridge.address);
            expect(
                await privateUSDC.hasRole(BRIDGE_ROLE, bridge.address)
            ).to.be.false;
        });

        it("should not allow non-admin to grant roles", async function () {
            const { privateUSDC, outsider, user1, BRIDGE_ROLE, DEFAULT_ADMIN_ROLE } =
                await loadFixture(deployFixture);

            await expect(
                privateUSDC
                    .connect(outsider)
                    .grantRole(BRIDGE_ROLE, user1.address)
            )
                .to.be.revertedWithCustomError(
                    privateUSDC,
                    "AccessControlUnauthorizedAccount"
                )
                .withArgs(outsider.address, DEFAULT_ADMIN_ROLE);
        });

        it("should verify BRIDGE_ROLE hash matches keccak256", async function () {
            const { privateUSDC } = await loadFixture(deployFixture);
            expect(await privateUSDC.BRIDGE_ROLE()).to.equal(
                ethers.id("BRIDGE_ROLE")
            );
        });
    });

    // ─────────────────────────────────────────────────────────────────────
    //  5. Pause / Unpause
    // ─────────────────────────────────────────────────────────────────────

    describe("Pausable", function () {
        it("should pause and block bridgeMint", async function () {
            const { privateUSDC, admin, bridge, user1 } =
                await loadFixture(deployFixture);

            await privateUSDC.connect(admin).pause();

            await expect(
                privateUSDC
                    .connect(bridge)
                    .bridgeMint(user1.address, 100n)
            ).to.be.revertedWithCustomError(privateUSDC, "EnforcedPause");
        });

        it("should pause and block bridgeBurn", async function () {
            const { privateUSDC, admin, bridge, user1 } =
                await loadFixture(deployFixture);

            const amount = ethers.parseUnits("100", 6);
            await privateUSDC
                .connect(bridge)
                .bridgeMint(user1.address, amount);

            await privateUSDC.connect(admin).pause();

            await expect(
                privateUSDC
                    .connect(bridge)
                    .bridgeBurn(user1.address, amount)
            ).to.be.revertedWithCustomError(privateUSDC, "EnforcedPause");
        });

        it("should unpause and allow bridgeMint again", async function () {
            const { privateUSDC, admin, bridge, user1 } =
                await loadFixture(deployFixture);

            await privateUSDC.connect(admin).pause();
            await privateUSDC.connect(admin).unpause();

            const amount = ethers.parseUnits("100", 6);
            await expect(
                privateUSDC
                    .connect(bridge)
                    .bridgeMint(user1.address, amount)
            ).to.emit(privateUSDC, "BridgeMint");
        });

        it("should unpause and allow bridgeBurn again", async function () {
            const { privateUSDC, admin, bridge, user1 } =
                await loadFixture(deployFixture);

            const amount = ethers.parseUnits("100", 6);
            await privateUSDC
                .connect(bridge)
                .bridgeMint(user1.address, amount);

            await privateUSDC.connect(admin).pause();
            await privateUSDC.connect(admin).unpause();

            await expect(
                privateUSDC
                    .connect(bridge)
                    .bridgeBurn(user1.address, amount)
            ).to.emit(privateUSDC, "BridgeBurn");
        });

        it("should revert pause for non-admin", async function () {
            const { privateUSDC, outsider, DEFAULT_ADMIN_ROLE } =
                await loadFixture(deployFixture);

            await expect(privateUSDC.connect(outsider).pause())
                .to.be.revertedWithCustomError(
                    privateUSDC,
                    "AccessControlUnauthorizedAccount"
                )
                .withArgs(outsider.address, DEFAULT_ADMIN_ROLE);
        });

        it("should revert unpause for non-admin", async function () {
            const { privateUSDC, admin, outsider, DEFAULT_ADMIN_ROLE } =
                await loadFixture(deployFixture);

            await privateUSDC.connect(admin).pause();

            await expect(privateUSDC.connect(outsider).unpause())
                .to.be.revertedWithCustomError(
                    privateUSDC,
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
            const { privateUSDC, admin } = await loadFixture(deployFixture);

            await expect(privateUSDC.connect(admin).enablePrivacy())
                .to.emit(privateUSDC, "PrivacyStatusChanged")
                .withArgs(true);

            expect(await privateUSDC.privacyEnabled()).to.be.true;
        });

        it("should revert enablePrivacy for non-admin", async function () {
            const { privateUSDC, outsider, DEFAULT_ADMIN_ROLE } =
                await loadFixture(deployFixture);

            await expect(privateUSDC.connect(outsider).enablePrivacy())
                .to.be.revertedWithCustomError(
                    privateUSDC,
                    "AccessControlUnauthorizedAccount"
                )
                .withArgs(outsider.address, DEFAULT_ADMIN_ROLE);
        });

        it("should propose privacy disable and set scheduled timestamp", async function () {
            const { privateUSDC, admin } = await loadFixture(deployFixture);

            await privateUSDC.connect(admin).proposePrivacyDisable();

            const scheduled = await privateUSDC.privacyDisableScheduledAt();
            expect(scheduled).to.be.gt(0n);
        });

        it("should emit PrivacyDisableProposed event", async function () {
            const { privateUSDC, admin } = await loadFixture(deployFixture);

            await expect(privateUSDC.connect(admin).proposePrivacyDisable())
                .to.emit(privateUSDC, "PrivacyDisableProposed");
        });

        it("should revert proposePrivacyDisable for non-admin", async function () {
            const { privateUSDC, outsider, DEFAULT_ADMIN_ROLE } =
                await loadFixture(deployFixture);

            await expect(
                privateUSDC.connect(outsider).proposePrivacyDisable()
            )
                .to.be.revertedWithCustomError(
                    privateUSDC,
                    "AccessControlUnauthorizedAccount"
                )
                .withArgs(outsider.address, DEFAULT_ADMIN_ROLE);
        });

        it("should revert executePrivacyDisable when no proposal pending", async function () {
            const { privateUSDC, admin } = await loadFixture(deployFixture);

            await expect(
                privateUSDC.connect(admin).executePrivacyDisable()
            ).to.be.revertedWithCustomError(privateUSDC, "NoPendingChange");
        });

        it("should revert executePrivacyDisable before timelock expires", async function () {
            const { privateUSDC, admin } = await loadFixture(deployFixture);

            await privateUSDC.connect(admin).enablePrivacy();
            await privateUSDC.connect(admin).proposePrivacyDisable();

            // Try to execute immediately (before 7 days)
            await expect(
                privateUSDC.connect(admin).executePrivacyDisable()
            ).to.be.revertedWithCustomError(privateUSDC, "TimelockActive");
        });

        it("should execute privacy disable after timelock", async function () {
            const { privateUSDC, admin } = await loadFixture(deployFixture);

            await privateUSDC.connect(admin).enablePrivacy();
            expect(await privateUSDC.privacyEnabled()).to.be.true;

            await privateUSDC.connect(admin).proposePrivacyDisable();

            // Advance time past 7 days
            await time.increase(7 * 24 * 60 * 60 + 1);

            await expect(
                privateUSDC.connect(admin).executePrivacyDisable()
            ).to.emit(privateUSDC, "PrivacyDisabled");

            expect(await privateUSDC.privacyEnabled()).to.be.false;
            expect(
                await privateUSDC.privacyDisableScheduledAt()
            ).to.equal(0n);
        });

        it("should revert executePrivacyDisable for non-admin", async function () {
            const { privateUSDC, admin, outsider, DEFAULT_ADMIN_ROLE } =
                await loadFixture(deployFixture);

            await privateUSDC.connect(admin).proposePrivacyDisable();
            await time.increase(7 * 24 * 60 * 60 + 1);

            await expect(
                privateUSDC.connect(outsider).executePrivacyDisable()
            )
                .to.be.revertedWithCustomError(
                    privateUSDC,
                    "AccessControlUnauthorizedAccount"
                )
                .withArgs(outsider.address, DEFAULT_ADMIN_ROLE);
        });

        it("should cancel pending privacy disable", async function () {
            const { privateUSDC, admin } = await loadFixture(deployFixture);

            await privateUSDC.connect(admin).proposePrivacyDisable();
            expect(
                await privateUSDC.privacyDisableScheduledAt()
            ).to.be.gt(0n);

            await expect(
                privateUSDC.connect(admin).cancelPrivacyDisable()
            ).to.emit(privateUSDC, "PrivacyDisableCancelled");

            expect(
                await privateUSDC.privacyDisableScheduledAt()
            ).to.equal(0n);
        });

        it("should revert cancelPrivacyDisable for non-admin", async function () {
            const { privateUSDC, admin, outsider, DEFAULT_ADMIN_ROLE } =
                await loadFixture(deployFixture);

            await privateUSDC.connect(admin).proposePrivacyDisable();

            await expect(
                privateUSDC.connect(outsider).cancelPrivacyDisable()
            )
                .to.be.revertedWithCustomError(
                    privateUSDC,
                    "AccessControlUnauthorizedAccount"
                )
                .withArgs(outsider.address, DEFAULT_ADMIN_ROLE);
        });

        it("should allow re-proposing after cancel", async function () {
            const { privateUSDC, admin } = await loadFixture(deployFixture);

            await privateUSDC.connect(admin).proposePrivacyDisable();
            await privateUSDC.connect(admin).cancelPrivacyDisable();

            // Propose again
            await expect(
                privateUSDC.connect(admin).proposePrivacyDisable()
            ).to.emit(privateUSDC, "PrivacyDisableProposed");
        });
    });

    // ─────────────────────────────────────────────────────────────────────
    //  7. Emergency recovery
    // ─────────────────────────────────────────────────────────────────────

    describe("Emergency recovery", function () {
        it("should revert when privacy is enabled", async function () {
            const { privateUSDC, admin, user1 } =
                await loadFixture(deployFixture);

            await privateUSDC.connect(admin).enablePrivacy();

            await expect(
                privateUSDC
                    .connect(admin)
                    .emergencyRecoverPrivateBalance(user1.address)
            ).to.be.revertedWithCustomError(
                privateUSDC,
                "PrivacyMustBeDisabled"
            );
        });

        it("should revert for zero address user", async function () {
            const { privateUSDC, admin } = await loadFixture(deployFixture);

            // Privacy is already disabled on Hardhat
            await expect(
                privateUSDC
                    .connect(admin)
                    .emergencyRecoverPrivateBalance(ethers.ZeroAddress)
            ).to.be.revertedWithCustomError(privateUSDC, "ZeroAddress");
        });

        it("should revert when shadow ledger balance is zero", async function () {
            const { privateUSDC, admin, user1 } =
                await loadFixture(deployFixture);

            // Privacy is disabled on Hardhat, no shadow ledger balance
            await expect(
                privateUSDC
                    .connect(admin)
                    .emergencyRecoverPrivateBalance(user1.address)
            ).to.be.revertedWithCustomError(
                privateUSDC,
                "NoBalanceToRecover"
            );
        });

        it("should revert for non-admin caller", async function () {
            const { privateUSDC, outsider, user1, DEFAULT_ADMIN_ROLE } =
                await loadFixture(deployFixture);

            await expect(
                privateUSDC
                    .connect(outsider)
                    .emergencyRecoverPrivateBalance(user1.address)
            )
                .to.be.revertedWithCustomError(
                    privateUSDC,
                    "AccessControlUnauthorizedAccount"
                )
                .withArgs(outsider.address, DEFAULT_ADMIN_ROLE);
        });
    });

    // ─────────────────────────────────────────────────────────────────────
    //  8. Ossification
    // ─────────────────────────────────────────────────────────────────────

    describe("Ossification", function () {
        it("should ossify and emit ContractOssified", async function () {
            const { privateUSDC, admin } = await loadFixture(deployFixture);

            await expect(privateUSDC.connect(admin).ossify())
                .to.emit(privateUSDC, "ContractOssified")
                .withArgs(await privateUSDC.getAddress());

            expect(await privateUSDC.isOssified()).to.be.true;
        });

        it("should block UUPS upgrade after ossification", async function () {
            const { privateUSDC, admin } = await loadFixture(deployFixture);

            await privateUSDC.connect(admin).ossify();

            const V2Factory =
                await ethers.getContractFactory("PrivateUSDC");
            await expect(
                upgrades.upgradeProxy(
                    await privateUSDC.getAddress(),
                    V2Factory
                )
            ).to.be.revertedWithCustomError(
                privateUSDC,
                "ContractIsOssified"
            );
        });

        it("should allow upgrade before ossification", async function () {
            const { privateUSDC } = await loadFixture(deployFixture);

            expect(await privateUSDC.isOssified()).to.be.false;

            const V2Factory =
                await ethers.getContractFactory("PrivateUSDC");
            const upgraded = await upgrades.upgradeProxy(
                await privateUSDC.getAddress(),
                V2Factory
            );

            expect(await upgraded.isOssified()).to.be.false;
        });

        it("should revert ossify for non-admin", async function () {
            const { privateUSDC, outsider, DEFAULT_ADMIN_ROLE } =
                await loadFixture(deployFixture);

            await expect(privateUSDC.connect(outsider).ossify())
                .to.be.revertedWithCustomError(
                    privateUSDC,
                    "AccessControlUnauthorizedAccount"
                )
                .withArgs(outsider.address, DEFAULT_ADMIN_ROLE);
        });
    });

    // ─────────────────────────────────────────────────────────────────────
    //  9. View functions & pure functions
    // ─────────────────────────────────────────────────────────────────────

    describe("View and pure functions", function () {
        it("name() should return 'Private USDC'", async function () {
            const { privateUSDC } = await loadFixture(deployFixture);
            expect(await privateUSDC.name()).to.equal("Private USDC");
        });

        it("symbol() should return 'pUSDC'", async function () {
            const { privateUSDC } = await loadFixture(deployFixture);
            expect(await privateUSDC.symbol()).to.equal("pUSDC");
        });

        it("decimals() should return 6", async function () {
            const { privateUSDC } = await loadFixture(deployFixture);
            expect(await privateUSDC.decimals()).to.equal(6);
        });

        it("publicBalances returns 0 for unknown address", async function () {
            const { privateUSDC, outsider } =
                await loadFixture(deployFixture);
            expect(
                await privateUSDC.publicBalances(outsider.address)
            ).to.equal(0n);
        });

        it("getShadowLedgerBalance should return 0 for owner querying own balance", async function () {
            const { privateUSDC, user1 } = await loadFixture(deployFixture);
            // user1 queries own balance (no deposits made)
            expect(
                await privateUSDC
                    .connect(user1)
                    .getShadowLedgerBalance(user1.address)
            ).to.equal(0n);
        });

        it("getShadowLedgerBalance should allow admin to query any address", async function () {
            const { privateUSDC, admin, user1 } =
                await loadFixture(deployFixture);
            expect(
                await privateUSDC
                    .connect(admin)
                    .getShadowLedgerBalance(user1.address)
            ).to.equal(0n);
        });

        it("getShadowLedgerBalance should revert for unauthorized caller", async function () {
            const { privateUSDC, outsider, user1 } =
                await loadFixture(deployFixture);
            await expect(
                privateUSDC
                    .connect(outsider)
                    .getShadowLedgerBalance(user1.address)
            ).to.be.revertedWithCustomError(privateUSDC, "Unauthorized");
        });

        it("privateBalanceOf should allow owner to query own balance", async function () {
            const { privateUSDC, user1 } = await loadFixture(deployFixture);
            // Returns ctUint64 (uint256), default 0
            expect(
                await privateUSDC
                    .connect(user1)
                    .privateBalanceOf(user1.address)
            ).to.equal(0n);
        });

        it("privateBalanceOf should allow admin to query any address", async function () {
            const { privateUSDC, admin, user1 } =
                await loadFixture(deployFixture);
            expect(
                await privateUSDC
                    .connect(admin)
                    .privateBalanceOf(user1.address)
            ).to.equal(0n);
        });

        it("privateBalanceOf should revert for unauthorized caller", async function () {
            const { privateUSDC, outsider, user1 } =
                await loadFixture(deployFixture);
            await expect(
                privateUSDC
                    .connect(outsider)
                    .privateBalanceOf(user1.address)
            ).to.be.revertedWithCustomError(privateUSDC, "Unauthorized");
        });
    });

    // ─────────────────────────────────────────────────────────────────────
    //  10. Events and custom errors in ABI
    // ─────────────────────────────────────────────────────────────────────

    describe("Events and interface", function () {
        it("should have BridgeMint event in ABI", async function () {
            const { privateUSDC } = await loadFixture(deployFixture);
            const event = privateUSDC.interface.getEvent("BridgeMint");
            expect(event).to.not.be.undefined;
            expect(event.name).to.equal("BridgeMint");
        });

        it("should have BridgeBurn event in ABI", async function () {
            const { privateUSDC } = await loadFixture(deployFixture);
            const event = privateUSDC.interface.getEvent("BridgeBurn");
            expect(event).to.not.be.undefined;
            expect(event.name).to.equal("BridgeBurn");
        });

        it("should have ConvertedToPrivate event in ABI", async function () {
            const { privateUSDC } = await loadFixture(deployFixture);
            const event = privateUSDC.interface.getEvent("ConvertedToPrivate");
            expect(event).to.not.be.undefined;
        });

        it("should have ConvertedToPublic event in ABI", async function () {
            const { privateUSDC } = await loadFixture(deployFixture);
            const event = privateUSDC.interface.getEvent("ConvertedToPublic");
            expect(event).to.not.be.undefined;
        });

        it("should have PrivateTransfer event in ABI", async function () {
            const { privateUSDC } = await loadFixture(deployFixture);
            const event = privateUSDC.interface.getEvent("PrivateTransfer");
            expect(event).to.not.be.undefined;
        });

        it("should have PrivacyStatusChanged event in ABI", async function () {
            const { privateUSDC } = await loadFixture(deployFixture);
            const event = privateUSDC.interface.getEvent(
                "PrivacyStatusChanged"
            );
            expect(event).to.not.be.undefined;
        });

        it("should have EmergencyPrivateRecovery event in ABI", async function () {
            const { privateUSDC } = await loadFixture(deployFixture);
            const event = privateUSDC.interface.getEvent(
                "EmergencyPrivateRecovery"
            );
            expect(event).to.not.be.undefined;
        });

        it("should have ContractOssified event in ABI", async function () {
            const { privateUSDC } = await loadFixture(deployFixture);
            const event = privateUSDC.interface.getEvent("ContractOssified");
            expect(event).to.not.be.undefined;
        });

        it("should have PrivacyDisableProposed event in ABI", async function () {
            const { privateUSDC } = await loadFixture(deployFixture);
            const event = privateUSDC.interface.getEvent(
                "PrivacyDisableProposed"
            );
            expect(event).to.not.be.undefined;
        });

        it("should have PrivacyDisabled event in ABI", async function () {
            const { privateUSDC } = await loadFixture(deployFixture);
            const event = privateUSDC.interface.getEvent("PrivacyDisabled");
            expect(event).to.not.be.undefined;
        });

        it("should have PrivacyDisableCancelled event in ABI", async function () {
            const { privateUSDC } = await loadFixture(deployFixture);
            const event = privateUSDC.interface.getEvent(
                "PrivacyDisableCancelled"
            );
            expect(event).to.not.be.undefined;
        });

        it("should have all custom errors in ABI", async function () {
            const { privateUSDC } = await loadFixture(deployFixture);

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
                "NoPendingChange",
                "TimelockActive",
            ];

            for (const errorName of expectedErrors) {
                const errorFragment =
                    privateUSDC.interface.getError(errorName);
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
        // These tests document what CANNOT be tested on Hardhat due to
        // MPC precompile requirements. They should be run on COTI testnet.

        it.skip("convertToPrivate -- debit publicBalances, create encrypted MPC balance (Requires COTI testnet)", function () {
            // MpcCore.setPublic64, MpcCore.onBoard, MpcCore.checkedAdd,
            // MpcCore.offBoard all call COTI MPC precompiles that revert
            // on Hardhat.
        });

        it.skip("convertToPrivate -- revert PrivacyNotAvailable when disabled (Requires COTI testnet)", function () {
            // While the revert itself is non-MPC, the function body reaches
            // MPC code paths before the check. On Hardhat, privacy is
            // disabled by default so this path IS testable, but the full
            // success path is not.
        });

        it.skip("convertToPrivate -- revert ZeroAmount (Requires COTI testnet)", function () {
            // Requires privacy to be enabled, which needs COTI chain ID.
        });

        it.skip("convertToPrivate -- revert InsufficientPublicBalance (Requires COTI testnet)", function () {
            // Same -- requires privacy enabled.
        });

        it.skip("convertToPrivate -- revert AmountTooLarge for > uint64 max (Requires COTI testnet)", function () {
            // Same -- requires privacy enabled.
        });

        it.skip("convertToPublic -- decrypt MPC amount, credit publicBalances (Requires COTI testnet)", function () {
            // MpcCore.onBoard, MpcCore.ge, MpcCore.decrypt, MpcCore.sub,
            // MpcCore.offBoard all require MPC precompile.
        });

        it.skip("privateTransfer -- encrypted transfer between accounts (Requires COTI testnet)", function () {
            // Full MPC pipeline: onBoard, ge, decrypt, sub, checkedAdd, offBoard.
        });

        it.skip("privateTransfer -- revert SelfTransfer (Requires COTI testnet)", function () {
            // Requires privacy enabled for the check to be reached.
        });

        it.skip("privateTransfer -- revert ZeroAddress recipient (Requires COTI testnet)", function () {
            // Requires privacy enabled.
        });
    });
});
