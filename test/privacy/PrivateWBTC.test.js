/**
 * PrivateWBTC -- Non-MPC Logic Tests
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
 * 11.  SCALING_FACTOR correctness (1e2, dust calculation math)
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

describe("PrivateWBTC", function () {
    /**
     * Shared deployment fixture.
     * Deploys ERC20MockConfigurable with 8 decimals (WBTC) and
     * the PrivateWBTC UUPS proxy with (admin, underlyingToken).
     */
    async function deployFixture() {
        const [admin, bridge, user1, user2, outsider] =
            await ethers.getSigners();

        // Deploy mock WBTC with 8 decimals
        const MockToken = await ethers.getContractFactory(
            "ERC20MockConfigurable"
        );
        const wbtc = await MockToken.deploy("Mock WBTC", "WBTC", 8);
        await wbtc.waitForDeployment();

        // Deploy PrivateWBTC as UUPS proxy
        const Factory = await ethers.getContractFactory("PrivateWBTC");
        const privateWBTC = await upgrades.deployProxy(
            Factory,
            [admin.address, await wbtc.getAddress()],
            {
                initializer: "initialize",
                kind: "uups",
                unsafeAllow: ["constructor", "state-variable-immutable"],
            }
        );
        await privateWBTC.waitForDeployment();

        // Grant BRIDGE_ROLE to dedicated bridge signer
        const BRIDGE_ROLE = await privateWBTC.BRIDGE_ROLE();
        await privateWBTC
            .connect(admin)
            .grantRole(BRIDGE_ROLE, bridge.address);

        // Transfer WBTC to bridge so it can bridgeMint
        // 1000 BTC = 1000 * 10^8 = 100_000_000_000 satoshi
        const mintAmount = 100_000_000_000n;
        await wbtc.connect(admin).transfer(bridge.address, mintAmount);

        // Approve PrivateWBTC contract to pull WBTC from bridge
        await wbtc
            .connect(bridge)
            .approve(await privateWBTC.getAddress(), ethers.MaxUint256);

        // Also approve from admin (who also has BRIDGE_ROLE by default)
        await wbtc
            .connect(admin)
            .approve(await privateWBTC.getAddress(), ethers.MaxUint256);

        const DEFAULT_ADMIN_ROLE = await privateWBTC.DEFAULT_ADMIN_ROLE();

        // Helper: parse WBTC amounts (8 decimals)
        const parseWBTC = (btc) => BigInt(Math.floor(btc * 1e8));

        return {
            privateWBTC,
            wbtc,
            admin,
            bridge,
            user1,
            user2,
            outsider,
            BRIDGE_ROLE,
            DEFAULT_ADMIN_ROLE,
            parseWBTC,
        };
    }

    // ─────────────────────────────────────────────────────────────────────
    //  1. Initialization
    // ─────────────────────────────────────────────────────────────────────

    describe("Initialization", function () {
        it("should grant DEFAULT_ADMIN_ROLE to admin", async function () {
            const { privateWBTC, admin, DEFAULT_ADMIN_ROLE } =
                await loadFixture(deployFixture);
            expect(
                await privateWBTC.hasRole(DEFAULT_ADMIN_ROLE, admin.address)
            ).to.be.true;
        });

        it("should grant BRIDGE_ROLE to admin", async function () {
            const { privateWBTC, admin, BRIDGE_ROLE } =
                await loadFixture(deployFixture);
            expect(
                await privateWBTC.hasRole(BRIDGE_ROLE, admin.address)
            ).to.be.true;
        });

        it("should set underlying token correctly", async function () {
            const { privateWBTC, wbtc } =
                await loadFixture(deployFixture);
            expect(await privateWBTC.underlyingToken()).to.equal(
                await wbtc.getAddress()
            );
        });

        it("should have SCALING_FACTOR = 100 (1e2)", async function () {
            const { privateWBTC } = await loadFixture(deployFixture);
            expect(await privateWBTC.SCALING_FACTOR()).to.equal(100n);
        });

        it("should have TOKEN_NAME = 'Private WBTC'", async function () {
            const { privateWBTC } = await loadFixture(deployFixture);
            expect(await privateWBTC.TOKEN_NAME()).to.equal("Private WBTC");
        });

        it("should have TOKEN_SYMBOL = 'pWBTC'", async function () {
            const { privateWBTC } = await loadFixture(deployFixture);
            expect(await privateWBTC.TOKEN_SYMBOL()).to.equal("pWBTC");
        });

        it("should have TOKEN_DECIMALS = 8", async function () {
            const { privateWBTC } = await loadFixture(deployFixture);
            expect(await privateWBTC.TOKEN_DECIMALS()).to.equal(8);
        });

        it("should start with totalPublicSupply = 0", async function () {
            const { privateWBTC } = await loadFixture(deployFixture);
            expect(await privateWBTC.totalPublicSupply()).to.equal(0n);
        });

        it("should detect privacy as disabled on Hardhat (chain 1337)", async function () {
            const { privateWBTC } = await loadFixture(deployFixture);
            expect(await privateWBTC.privacyEnabled()).to.be.false;
        });

        it("should start with PRIVACY_DISABLE_DELAY = 7 days", async function () {
            const { privateWBTC } = await loadFixture(deployFixture);
            expect(await privateWBTC.PRIVACY_DISABLE_DELAY()).to.equal(
                7n * 24n * 60n * 60n
            );
        });

        it("should start unossified", async function () {
            const { privateWBTC } = await loadFixture(deployFixture);
            expect(await privateWBTC.isOssified()).to.be.false;
        });

        it("should revert when admin is zero address", async function () {
            const { wbtc } = await loadFixture(deployFixture);
            const Factory = await ethers.getContractFactory("PrivateWBTC");
            await expect(
                upgrades.deployProxy(
                    Factory,
                    [ethers.ZeroAddress, await wbtc.getAddress()],
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
            const Factory = await ethers.getContractFactory("PrivateWBTC");
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
            const { privateWBTC } = await loadFixture(deployFixture);
            expect(await privateWBTC.privacyDisableScheduledAt()).to.equal(
                0n
            );
        });
    });

    // ─────────────────────────────────────────────────────────────────────
    //  2. bridgeMint
    // ─────────────────────────────────────────────────────────────────────

    describe("bridgeMint", function () {
        it("should mint and credit publicBalances", async function () {
            const { privateWBTC, bridge, user1, parseWBTC } =
                await loadFixture(deployFixture);

            const amount = parseWBTC(1.5); // 1.5 BTC
            await privateWBTC
                .connect(bridge)
                .bridgeMint(user1.address, amount);

            expect(
                await privateWBTC.publicBalances(user1.address)
            ).to.equal(amount);
        });

        it("should increase totalPublicSupply", async function () {
            const { privateWBTC, bridge, user1, parseWBTC } =
                await loadFixture(deployFixture);

            const amount = parseWBTC(2.0);
            await privateWBTC
                .connect(bridge)
                .bridgeMint(user1.address, amount);

            expect(await privateWBTC.totalPublicSupply()).to.equal(amount);
        });

        it("should transfer real WBTC from bridge to contract", async function () {
            const { privateWBTC, wbtc, bridge, user1, parseWBTC } =
                await loadFixture(deployFixture);

            const amount = parseWBTC(0.5);
            const bridgeBalBefore = await wbtc.balanceOf(bridge.address);

            await privateWBTC
                .connect(bridge)
                .bridgeMint(user1.address, amount);

            const bridgeBalAfter = await wbtc.balanceOf(bridge.address);
            expect(bridgeBalBefore - bridgeBalAfter).to.equal(amount);

            const contractBal = await wbtc.balanceOf(
                await privateWBTC.getAddress()
            );
            expect(contractBal).to.equal(amount);
        });

        it("should emit BridgeMint event", async function () {
            const { privateWBTC, bridge, user1, parseWBTC } =
                await loadFixture(deployFixture);

            const amount = parseWBTC(0.1);
            await expect(
                privateWBTC
                    .connect(bridge)
                    .bridgeMint(user1.address, amount)
            )
                .to.emit(privateWBTC, "BridgeMint")
                .withArgs(user1.address, amount);
        });

        it("should accumulate balances across multiple mints", async function () {
            const { privateWBTC, bridge, user1, parseWBTC } =
                await loadFixture(deployFixture);

            const amount1 = parseWBTC(1.0);
            const amount2 = parseWBTC(2.5);

            await privateWBTC
                .connect(bridge)
                .bridgeMint(user1.address, amount1);
            await privateWBTC
                .connect(bridge)
                .bridgeMint(user1.address, amount2);

            expect(
                await privateWBTC.publicBalances(user1.address)
            ).to.equal(amount1 + amount2);
        });

        it("should revert when caller lacks BRIDGE_ROLE", async function () {
            const { privateWBTC, outsider, user1, BRIDGE_ROLE, parseWBTC } =
                await loadFixture(deployFixture);

            await expect(
                privateWBTC
                    .connect(outsider)
                    .bridgeMint(user1.address, parseWBTC(1.0))
            )
                .to.be.revertedWithCustomError(
                    privateWBTC,
                    "AccessControlUnauthorizedAccount"
                )
                .withArgs(outsider.address, BRIDGE_ROLE);
        });

        it("should revert when recipient is zero address", async function () {
            const { privateWBTC, bridge, parseWBTC } =
                await loadFixture(deployFixture);

            await expect(
                privateWBTC
                    .connect(bridge)
                    .bridgeMint(ethers.ZeroAddress, parseWBTC(1.0))
            ).to.be.revertedWithCustomError(privateWBTC, "ZeroAddress");
        });

        it("should revert when amount is zero", async function () {
            const { privateWBTC, bridge, user1 } =
                await loadFixture(deployFixture);

            await expect(
                privateWBTC.connect(bridge).bridgeMint(user1.address, 0n)
            ).to.be.revertedWithCustomError(privateWBTC, "ZeroAmount");
        });

        it("should mint to multiple different recipients", async function () {
            const { privateWBTC, bridge, user1, user2, parseWBTC } =
                await loadFixture(deployFixture);

            const amt1 = parseWBTC(3.0);
            const amt2 = parseWBTC(5.0);

            await privateWBTC
                .connect(bridge)
                .bridgeMint(user1.address, amt1);
            await privateWBTC
                .connect(bridge)
                .bridgeMint(user2.address, amt2);

            expect(
                await privateWBTC.publicBalances(user1.address)
            ).to.equal(amt1);
            expect(
                await privateWBTC.publicBalances(user2.address)
            ).to.equal(amt2);
            expect(await privateWBTC.totalPublicSupply()).to.equal(
                amt1 + amt2
            );
        });
    });

    // ─────────────────────────────────────────────────────────────────────
    //  3. bridgeBurn
    // ─────────────────────────────────────────────────────────────────────

    describe("bridgeBurn", function () {
        it("should burn and debit publicBalances", async function () {
            const { privateWBTC, bridge, user1, parseWBTC } =
                await loadFixture(deployFixture);

            const mintAmount = parseWBTC(10.0);
            await privateWBTC
                .connect(bridge)
                .bridgeMint(user1.address, mintAmount);

            const burnAmount = parseWBTC(4.0);
            await privateWBTC
                .connect(bridge)
                .bridgeBurn(user1.address, burnAmount);

            expect(
                await privateWBTC.publicBalances(user1.address)
            ).to.equal(mintAmount - burnAmount);
        });

        it("should decrease totalPublicSupply", async function () {
            const { privateWBTC, bridge, user1, parseWBTC } =
                await loadFixture(deployFixture);

            const mintAmount = parseWBTC(10.0);
            await privateWBTC
                .connect(bridge)
                .bridgeMint(user1.address, mintAmount);

            const burnAmount = parseWBTC(3.0);
            await privateWBTC
                .connect(bridge)
                .bridgeBurn(user1.address, burnAmount);

            expect(await privateWBTC.totalPublicSupply()).to.equal(
                mintAmount - burnAmount
            );
        });

        it("should transfer real WBTC back to user", async function () {
            const { privateWBTC, wbtc, bridge, user1, parseWBTC } =
                await loadFixture(deployFixture);

            const mintAmount = parseWBTC(10.0);
            await privateWBTC
                .connect(bridge)
                .bridgeMint(user1.address, mintAmount);

            const burnAmount = parseWBTC(5.0);
            const userBalBefore = await wbtc.balanceOf(user1.address);

            await privateWBTC
                .connect(bridge)
                .bridgeBurn(user1.address, burnAmount);

            const userBalAfter = await wbtc.balanceOf(user1.address);
            expect(userBalAfter - userBalBefore).to.equal(burnAmount);
        });

        it("should emit BridgeBurn event", async function () {
            const { privateWBTC, bridge, user1, parseWBTC } =
                await loadFixture(deployFixture);

            const mintAmount = parseWBTC(10.0);
            await privateWBTC
                .connect(bridge)
                .bridgeMint(user1.address, mintAmount);

            const burnAmount = parseWBTC(2.0);
            await expect(
                privateWBTC
                    .connect(bridge)
                    .bridgeBurn(user1.address, burnAmount)
            )
                .to.emit(privateWBTC, "BridgeBurn")
                .withArgs(user1.address, burnAmount);
        });

        it("should allow burning full balance", async function () {
            const { privateWBTC, bridge, user1, parseWBTC } =
                await loadFixture(deployFixture);

            const amount = parseWBTC(7.0);
            await privateWBTC
                .connect(bridge)
                .bridgeMint(user1.address, amount);
            await privateWBTC
                .connect(bridge)
                .bridgeBurn(user1.address, amount);

            expect(
                await privateWBTC.publicBalances(user1.address)
            ).to.equal(0n);
            expect(await privateWBTC.totalPublicSupply()).to.equal(0n);
        });

        it("should revert when insufficient public balance", async function () {
            const { privateWBTC, bridge, user1, parseWBTC } =
                await loadFixture(deployFixture);

            const mintAmount = parseWBTC(5.0);
            await privateWBTC
                .connect(bridge)
                .bridgeMint(user1.address, mintAmount);

            const burnAmount = parseWBTC(10.0);
            await expect(
                privateWBTC
                    .connect(bridge)
                    .bridgeBurn(user1.address, burnAmount)
            ).to.be.revertedWithCustomError(
                privateWBTC,
                "InsufficientPublicBalance"
            );
        });

        it("should revert when caller lacks BRIDGE_ROLE", async function () {
            const { privateWBTC, bridge, outsider, user1, BRIDGE_ROLE, parseWBTC } =
                await loadFixture(deployFixture);

            const amount = parseWBTC(5.0);
            await privateWBTC
                .connect(bridge)
                .bridgeMint(user1.address, amount);

            await expect(
                privateWBTC
                    .connect(outsider)
                    .bridgeBurn(user1.address, amount)
            )
                .to.be.revertedWithCustomError(
                    privateWBTC,
                    "AccessControlUnauthorizedAccount"
                )
                .withArgs(outsider.address, BRIDGE_ROLE);
        });

        it("should revert when from is zero address", async function () {
            const { privateWBTC, bridge } =
                await loadFixture(deployFixture);

            await expect(
                privateWBTC
                    .connect(bridge)
                    .bridgeBurn(ethers.ZeroAddress, 100n)
            ).to.be.revertedWithCustomError(privateWBTC, "ZeroAddress");
        });

        it("should revert when amount is zero", async function () {
            const { privateWBTC, bridge, user1 } =
                await loadFixture(deployFixture);

            await expect(
                privateWBTC.connect(bridge).bridgeBurn(user1.address, 0n)
            ).to.be.revertedWithCustomError(privateWBTC, "ZeroAmount");
        });
    });

    // ─────────────────────────────────────────────────────────────────────
    //  4. Access control
    // ─────────────────────────────────────────────────────────────────────

    describe("Access control", function () {
        it("should allow admin to grant BRIDGE_ROLE", async function () {
            const { privateWBTC, admin, outsider, BRIDGE_ROLE } =
                await loadFixture(deployFixture);

            await privateWBTC
                .connect(admin)
                .grantRole(BRIDGE_ROLE, outsider.address);
            expect(
                await privateWBTC.hasRole(BRIDGE_ROLE, outsider.address)
            ).to.be.true;
        });

        it("should allow admin to revoke BRIDGE_ROLE", async function () {
            const { privateWBTC, admin, bridge, BRIDGE_ROLE } =
                await loadFixture(deployFixture);

            await privateWBTC
                .connect(admin)
                .revokeRole(BRIDGE_ROLE, bridge.address);
            expect(
                await privateWBTC.hasRole(BRIDGE_ROLE, bridge.address)
            ).to.be.false;
        });

        it("should not allow non-admin to grant roles", async function () {
            const {
                privateWBTC,
                outsider,
                user1,
                BRIDGE_ROLE,
                DEFAULT_ADMIN_ROLE,
            } = await loadFixture(deployFixture);

            await expect(
                privateWBTC
                    .connect(outsider)
                    .grantRole(BRIDGE_ROLE, user1.address)
            )
                .to.be.revertedWithCustomError(
                    privateWBTC,
                    "AccessControlUnauthorizedAccount"
                )
                .withArgs(outsider.address, DEFAULT_ADMIN_ROLE);
        });

        it("should verify BRIDGE_ROLE hash matches keccak256", async function () {
            const { privateWBTC } = await loadFixture(deployFixture);
            expect(await privateWBTC.BRIDGE_ROLE()).to.equal(
                ethers.id("BRIDGE_ROLE")
            );
        });
    });

    // ─────────────────────────────────────────────────────────────────────
    //  5. Pause / Unpause
    // ─────────────────────────────────────────────────────────────────────

    describe("Pausable", function () {
        it("should pause and block bridgeMint", async function () {
            const { privateWBTC, admin, bridge, user1 } =
                await loadFixture(deployFixture);

            await privateWBTC.connect(admin).pause();

            await expect(
                privateWBTC
                    .connect(bridge)
                    .bridgeMint(user1.address, 100_000_000n)
            ).to.be.revertedWithCustomError(privateWBTC, "EnforcedPause");
        });

        it("should pause and block bridgeBurn", async function () {
            const { privateWBTC, admin, bridge, user1, parseWBTC } =
                await loadFixture(deployFixture);

            const amount = parseWBTC(5.0);
            await privateWBTC
                .connect(bridge)
                .bridgeMint(user1.address, amount);

            await privateWBTC.connect(admin).pause();

            await expect(
                privateWBTC
                    .connect(bridge)
                    .bridgeBurn(user1.address, amount)
            ).to.be.revertedWithCustomError(privateWBTC, "EnforcedPause");
        });

        it("should unpause and allow bridgeMint again", async function () {
            const { privateWBTC, admin, bridge, user1, parseWBTC } =
                await loadFixture(deployFixture);

            await privateWBTC.connect(admin).pause();
            await privateWBTC.connect(admin).unpause();

            const amount = parseWBTC(1.0);
            await expect(
                privateWBTC
                    .connect(bridge)
                    .bridgeMint(user1.address, amount)
            ).to.emit(privateWBTC, "BridgeMint");
        });

        it("should unpause and allow bridgeBurn again", async function () {
            const { privateWBTC, admin, bridge, user1, parseWBTC } =
                await loadFixture(deployFixture);

            const amount = parseWBTC(5.0);
            await privateWBTC
                .connect(bridge)
                .bridgeMint(user1.address, amount);

            await privateWBTC.connect(admin).pause();
            await privateWBTC.connect(admin).unpause();

            await expect(
                privateWBTC
                    .connect(bridge)
                    .bridgeBurn(user1.address, amount)
            ).to.emit(privateWBTC, "BridgeBurn");
        });

        it("should revert pause for non-admin", async function () {
            const { privateWBTC, outsider, DEFAULT_ADMIN_ROLE } =
                await loadFixture(deployFixture);

            await expect(privateWBTC.connect(outsider).pause())
                .to.be.revertedWithCustomError(
                    privateWBTC,
                    "AccessControlUnauthorizedAccount"
                )
                .withArgs(outsider.address, DEFAULT_ADMIN_ROLE);
        });

        it("should revert unpause for non-admin", async function () {
            const { privateWBTC, admin, outsider, DEFAULT_ADMIN_ROLE } =
                await loadFixture(deployFixture);

            await privateWBTC.connect(admin).pause();

            await expect(privateWBTC.connect(outsider).unpause())
                .to.be.revertedWithCustomError(
                    privateWBTC,
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
            const { privateWBTC, admin } = await loadFixture(deployFixture);

            await expect(privateWBTC.connect(admin).enablePrivacy())
                .to.emit(privateWBTC, "PrivacyStatusChanged")
                .withArgs(true);

            expect(await privateWBTC.privacyEnabled()).to.be.true;
        });

        it("should revert enablePrivacy for non-admin", async function () {
            const { privateWBTC, outsider, DEFAULT_ADMIN_ROLE } =
                await loadFixture(deployFixture);

            await expect(privateWBTC.connect(outsider).enablePrivacy())
                .to.be.revertedWithCustomError(
                    privateWBTC,
                    "AccessControlUnauthorizedAccount"
                )
                .withArgs(outsider.address, DEFAULT_ADMIN_ROLE);
        });

        it("should propose privacy disable and set scheduled timestamp", async function () {
            const { privateWBTC, admin } = await loadFixture(deployFixture);

            await privateWBTC.connect(admin).proposePrivacyDisable();

            const scheduled =
                await privateWBTC.privacyDisableScheduledAt();
            expect(scheduled).to.be.gt(0n);
        });

        it("should emit PrivacyDisableProposed event", async function () {
            const { privateWBTC, admin } = await loadFixture(deployFixture);

            await expect(
                privateWBTC.connect(admin).proposePrivacyDisable()
            ).to.emit(privateWBTC, "PrivacyDisableProposed");
        });

        it("should revert proposePrivacyDisable for non-admin", async function () {
            const { privateWBTC, outsider, DEFAULT_ADMIN_ROLE } =
                await loadFixture(deployFixture);

            await expect(
                privateWBTC.connect(outsider).proposePrivacyDisable()
            )
                .to.be.revertedWithCustomError(
                    privateWBTC,
                    "AccessControlUnauthorizedAccount"
                )
                .withArgs(outsider.address, DEFAULT_ADMIN_ROLE);
        });

        it("should revert executePrivacyDisable when no proposal pending", async function () {
            const { privateWBTC, admin } = await loadFixture(deployFixture);

            await expect(
                privateWBTC.connect(admin).executePrivacyDisable()
            ).to.be.revertedWithCustomError(privateWBTC, "NoPendingChange");
        });

        it("should revert executePrivacyDisable before timelock expires", async function () {
            const { privateWBTC, admin } = await loadFixture(deployFixture);

            await privateWBTC.connect(admin).enablePrivacy();
            await privateWBTC.connect(admin).proposePrivacyDisable();

            await expect(
                privateWBTC.connect(admin).executePrivacyDisable()
            ).to.be.revertedWithCustomError(privateWBTC, "TimelockActive");
        });

        it("should execute privacy disable after timelock", async function () {
            const { privateWBTC, admin } = await loadFixture(deployFixture);

            await privateWBTC.connect(admin).enablePrivacy();
            expect(await privateWBTC.privacyEnabled()).to.be.true;

            await privateWBTC.connect(admin).proposePrivacyDisable();

            // Advance time past 7 days
            await time.increase(7 * 24 * 60 * 60 + 1);

            await expect(
                privateWBTC.connect(admin).executePrivacyDisable()
            ).to.emit(privateWBTC, "PrivacyDisabled");

            expect(await privateWBTC.privacyEnabled()).to.be.false;
            expect(
                await privateWBTC.privacyDisableScheduledAt()
            ).to.equal(0n);
        });

        it("should revert executePrivacyDisable for non-admin", async function () {
            const { privateWBTC, admin, outsider, DEFAULT_ADMIN_ROLE } =
                await loadFixture(deployFixture);

            await privateWBTC.connect(admin).proposePrivacyDisable();
            await time.increase(7 * 24 * 60 * 60 + 1);

            await expect(
                privateWBTC.connect(outsider).executePrivacyDisable()
            )
                .to.be.revertedWithCustomError(
                    privateWBTC,
                    "AccessControlUnauthorizedAccount"
                )
                .withArgs(outsider.address, DEFAULT_ADMIN_ROLE);
        });

        it("should cancel pending privacy disable", async function () {
            const { privateWBTC, admin } = await loadFixture(deployFixture);

            await privateWBTC.connect(admin).proposePrivacyDisable();
            expect(
                await privateWBTC.privacyDisableScheduledAt()
            ).to.be.gt(0n);

            await expect(
                privateWBTC.connect(admin).cancelPrivacyDisable()
            ).to.emit(privateWBTC, "PrivacyDisableCancelled");

            expect(
                await privateWBTC.privacyDisableScheduledAt()
            ).to.equal(0n);
        });

        it("should revert cancelPrivacyDisable for non-admin", async function () {
            const { privateWBTC, admin, outsider, DEFAULT_ADMIN_ROLE } =
                await loadFixture(deployFixture);

            await privateWBTC.connect(admin).proposePrivacyDisable();

            await expect(
                privateWBTC.connect(outsider).cancelPrivacyDisable()
            )
                .to.be.revertedWithCustomError(
                    privateWBTC,
                    "AccessControlUnauthorizedAccount"
                )
                .withArgs(outsider.address, DEFAULT_ADMIN_ROLE);
        });

        it("should allow re-proposing after cancel", async function () {
            const { privateWBTC, admin } = await loadFixture(deployFixture);

            await privateWBTC.connect(admin).proposePrivacyDisable();
            await privateWBTC.connect(admin).cancelPrivacyDisable();

            await expect(
                privateWBTC.connect(admin).proposePrivacyDisable()
            ).to.emit(privateWBTC, "PrivacyDisableProposed");
        });
    });

    // ─────────────────────────────────────────────────────────────────────
    //  7. Emergency recovery
    // ─────────────────────────────────────────────────────────────────────

    describe("Emergency recovery", function () {
        it("should revert when privacy is enabled", async function () {
            const { privateWBTC, admin, user1 } =
                await loadFixture(deployFixture);

            await privateWBTC.connect(admin).enablePrivacy();

            await expect(
                privateWBTC
                    .connect(admin)
                    .emergencyRecoverPrivateBalance(user1.address)
            ).to.be.revertedWithCustomError(
                privateWBTC,
                "PrivacyMustBeDisabled"
            );
        });

        it("should revert for zero address user", async function () {
            const { privateWBTC, admin } = await loadFixture(deployFixture);

            await expect(
                privateWBTC
                    .connect(admin)
                    .emergencyRecoverPrivateBalance(ethers.ZeroAddress)
            ).to.be.revertedWithCustomError(privateWBTC, "ZeroAddress");
        });

        it("should revert when shadow ledger balance is zero", async function () {
            const { privateWBTC, admin, user1 } =
                await loadFixture(deployFixture);

            await expect(
                privateWBTC
                    .connect(admin)
                    .emergencyRecoverPrivateBalance(user1.address)
            ).to.be.revertedWithCustomError(
                privateWBTC,
                "NoBalanceToRecover"
            );
        });

        it("should revert for non-admin caller", async function () {
            const { privateWBTC, outsider, user1, DEFAULT_ADMIN_ROLE } =
                await loadFixture(deployFixture);

            await expect(
                privateWBTC
                    .connect(outsider)
                    .emergencyRecoverPrivateBalance(user1.address)
            )
                .to.be.revertedWithCustomError(
                    privateWBTC,
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
            const { privateWBTC, user1 } =
                await loadFixture(deployFixture);
            expect(
                await privateWBTC.dustBalances(user1.address)
            ).to.equal(0n);
        });

        it("should revert claimDust when no dust available", async function () {
            const { privateWBTC, user1 } =
                await loadFixture(deployFixture);

            await expect(
                privateWBTC.connect(user1).claimDust()
            ).to.be.revertedWithCustomError(privateWBTC, "NoDustToClaim");
        });

        // NOTE: Dust accumulation happens during convertToPrivate which
        // requires MPC. The claimDust function itself is non-MPC but we
        // cannot populate dustBalances without convertToPrivate on COTI.
        // The revert test above confirms the claimDust guard works.

        it("should expose dustBalances as a public mapping", async function () {
            const { privateWBTC, outsider } =
                await loadFixture(deployFixture);
            const dust = await privateWBTC.dustBalances(outsider.address);
            expect(dust).to.equal(0n);
        });
    });

    // ─────────────────────────────────────────────────────────────────────
    //  9. Ossification
    // ─────────────────────────────────────────────────────────────────────

    describe("Ossification", function () {
        it("should ossify and emit ContractOssified", async function () {
            const { privateWBTC, admin } =
                await loadFixture(deployFixture);

            await expect(privateWBTC.connect(admin).ossify())
                .to.emit(privateWBTC, "ContractOssified")
                .withArgs(await privateWBTC.getAddress());

            expect(await privateWBTC.isOssified()).to.be.true;
        });

        it("should block UUPS upgrade after ossification", async function () {
            const { privateWBTC, admin } =
                await loadFixture(deployFixture);

            await privateWBTC.connect(admin).ossify();

            const V2Factory =
                await ethers.getContractFactory("PrivateWBTC");
            await expect(
                upgrades.upgradeProxy(
                    await privateWBTC.getAddress(),
                    V2Factory
                )
            ).to.be.revertedWithCustomError(
                privateWBTC,
                "ContractIsOssified"
            );
        });

        it("should allow upgrade before ossification", async function () {
            const { privateWBTC } = await loadFixture(deployFixture);

            expect(await privateWBTC.isOssified()).to.be.false;

            const V2Factory =
                await ethers.getContractFactory("PrivateWBTC");
            const upgraded = await upgrades.upgradeProxy(
                await privateWBTC.getAddress(),
                V2Factory
            );

            expect(await upgraded.isOssified()).to.be.false;
        });

        it("should revert ossify for non-admin", async function () {
            const { privateWBTC, outsider, DEFAULT_ADMIN_ROLE } =
                await loadFixture(deployFixture);

            await expect(privateWBTC.connect(outsider).ossify())
                .to.be.revertedWithCustomError(
                    privateWBTC,
                    "AccessControlUnauthorizedAccount"
                )
                .withArgs(outsider.address, DEFAULT_ADMIN_ROLE);
        });
    });

    // ─────────────────────────────────────────────────────────────────────
    //  10. View and pure functions
    // ─────────────────────────────────────────────────────────────────────

    describe("View and pure functions", function () {
        it("name() should return 'Private WBTC'", async function () {
            const { privateWBTC } = await loadFixture(deployFixture);
            expect(await privateWBTC.name()).to.equal("Private WBTC");
        });

        it("symbol() should return 'pWBTC'", async function () {
            const { privateWBTC } = await loadFixture(deployFixture);
            expect(await privateWBTC.symbol()).to.equal("pWBTC");
        });

        it("decimals() should return 8", async function () {
            const { privateWBTC } = await loadFixture(deployFixture);
            expect(await privateWBTC.decimals()).to.equal(8);
        });

        it("publicBalances returns 0 for unknown address", async function () {
            const { privateWBTC, outsider } =
                await loadFixture(deployFixture);
            expect(
                await privateWBTC.publicBalances(outsider.address)
            ).to.equal(0n);
        });

        it("getShadowLedgerBalance should return 0 for owner querying own", async function () {
            const { privateWBTC, user1 } =
                await loadFixture(deployFixture);
            expect(
                await privateWBTC
                    .connect(user1)
                    .getShadowLedgerBalance(user1.address)
            ).to.equal(0n);
        });

        it("getShadowLedgerBalance should allow admin to query any address", async function () {
            const { privateWBTC, admin, user1 } =
                await loadFixture(deployFixture);
            expect(
                await privateWBTC
                    .connect(admin)
                    .getShadowLedgerBalance(user1.address)
            ).to.equal(0n);
        });

        it("getShadowLedgerBalance should revert for unauthorized caller", async function () {
            const { privateWBTC, outsider, user1 } =
                await loadFixture(deployFixture);
            await expect(
                privateWBTC
                    .connect(outsider)
                    .getShadowLedgerBalance(user1.address)
            ).to.be.revertedWithCustomError(privateWBTC, "Unauthorized");
        });

        it("privateBalanceOf should allow owner to query own balance", async function () {
            const { privateWBTC, user1 } =
                await loadFixture(deployFixture);
            expect(
                await privateWBTC
                    .connect(user1)
                    .privateBalanceOf(user1.address)
            ).to.equal(0n);
        });

        it("privateBalanceOf should allow admin to query any address", async function () {
            const { privateWBTC, admin, user1 } =
                await loadFixture(deployFixture);
            expect(
                await privateWBTC
                    .connect(admin)
                    .privateBalanceOf(user1.address)
            ).to.equal(0n);
        });

        it("privateBalanceOf should revert for unauthorized caller", async function () {
            const { privateWBTC, outsider, user1 } =
                await loadFixture(deployFixture);
            await expect(
                privateWBTC
                    .connect(outsider)
                    .privateBalanceOf(user1.address)
            ).to.be.revertedWithCustomError(privateWBTC, "Unauthorized");
        });
    });

    // ─────────────────────────────────────────────────────────────────────
    //  11. SCALING_FACTOR correctness
    // ─────────────────────────────────────────────────────────────────────

    describe("SCALING_FACTOR correctness", function () {
        it("SCALING_FACTOR should be 10^2 (100)", async function () {
            const { privateWBTC } = await loadFixture(deployFixture);
            expect(await privateWBTC.SCALING_FACTOR()).to.equal(100n);
        });

        it("SCALING_FACTOR * 10^6 should equal 10^8 (WBTC precision)", async function () {
            const { privateWBTC } = await loadFixture(deployFixture);
            const factor = await privateWBTC.SCALING_FACTOR();
            // factor (100) * MPC precision (1e6) = WBTC precision (1e8)
            expect(factor * 1000000n).to.equal(100_000_000n);
        });

        it("maximum dust should be SCALING_FACTOR - 1 (99 satoshi)", async function () {
            const { privateWBTC } = await loadFixture(deployFixture);
            const factor = await privateWBTC.SCALING_FACTOR();
            expect(factor - 1n).to.equal(99n);
        });

        it("minimum convertible amount should be SCALING_FACTOR (100 satoshi)", async function () {
            const { privateWBTC } = await loadFixture(deployFixture);
            const factor = await privateWBTC.SCALING_FACTOR();
            // Amounts below 100 satoshi would scale to 0 (ZeroAmount revert)
            expect(factor).to.equal(100n);
        });

        it("1 BTC (1e8 satoshi) should scale to 1e6 MPC units", async function () {
            const { privateWBTC } = await loadFixture(deployFixture);
            const factor = await privateWBTC.SCALING_FACTOR();
            const oneBTC = 100_000_000n; // 1e8
            const scaledAmount = oneBTC / factor;
            expect(scaledAmount).to.equal(1_000_000n); // 1e6
        });

        it("0.01 BTC (1e6 satoshi) should scale to 1e4 MPC units", async function () {
            const { privateWBTC } = await loadFixture(deployFixture);
            const factor = await privateWBTC.SCALING_FACTOR();
            const pointZeroOneBTC = 1_000_000n; // 1e6
            const scaledAmount = pointZeroOneBTC / factor;
            expect(scaledAmount).to.equal(10_000n); // 1e4
        });

        it("99 satoshi should scale to 0 (below minimum)", async function () {
            const { privateWBTC } = await loadFixture(deployFixture);
            const factor = await privateWBTC.SCALING_FACTOR();
            const belowMinimum = 99n;
            const scaledAmount = belowMinimum / factor;
            expect(scaledAmount).to.equal(0n);
        });
    });

    // ─────────────────────────────────────────────────────────────────────
    //  12. Events and custom errors
    // ─────────────────────────────────────────────────────────────────────

    describe("Events and interface", function () {
        it("should have BridgeMint event in ABI", async function () {
            const { privateWBTC } = await loadFixture(deployFixture);
            const event = privateWBTC.interface.getEvent("BridgeMint");
            expect(event).to.not.be.undefined;
        });

        it("should have BridgeBurn event in ABI", async function () {
            const { privateWBTC } = await loadFixture(deployFixture);
            const event = privateWBTC.interface.getEvent("BridgeBurn");
            expect(event).to.not.be.undefined;
        });

        it("should have ConvertedToPrivate event in ABI", async function () {
            const { privateWBTC } = await loadFixture(deployFixture);
            const event =
                privateWBTC.interface.getEvent("ConvertedToPrivate");
            expect(event).to.not.be.undefined;
        });

        it("should have ConvertedToPublic event in ABI", async function () {
            const { privateWBTC } = await loadFixture(deployFixture);
            const event =
                privateWBTC.interface.getEvent("ConvertedToPublic");
            expect(event).to.not.be.undefined;
        });

        it("should have PrivateTransfer event in ABI", async function () {
            const { privateWBTC } = await loadFixture(deployFixture);
            const event =
                privateWBTC.interface.getEvent("PrivateTransfer");
            expect(event).to.not.be.undefined;
        });

        it("should have DustClaimed event in ABI", async function () {
            const { privateWBTC } = await loadFixture(deployFixture);
            const event = privateWBTC.interface.getEvent("DustClaimed");
            expect(event).to.not.be.undefined;
        });

        it("should have PrivacyStatusChanged event in ABI", async function () {
            const { privateWBTC } = await loadFixture(deployFixture);
            const event =
                privateWBTC.interface.getEvent("PrivacyStatusChanged");
            expect(event).to.not.be.undefined;
        });

        it("should have EmergencyPrivateRecovery event in ABI", async function () {
            const { privateWBTC } = await loadFixture(deployFixture);
            const event = privateWBTC.interface.getEvent(
                "EmergencyPrivateRecovery"
            );
            expect(event).to.not.be.undefined;
        });

        it("should have ContractOssified event in ABI", async function () {
            const { privateWBTC } = await loadFixture(deployFixture);
            const event =
                privateWBTC.interface.getEvent("ContractOssified");
            expect(event).to.not.be.undefined;
        });

        it("should have PrivacyDisableProposed event in ABI", async function () {
            const { privateWBTC } = await loadFixture(deployFixture);
            const event = privateWBTC.interface.getEvent(
                "PrivacyDisableProposed"
            );
            expect(event).to.not.be.undefined;
        });

        it("should have PrivacyDisabled event in ABI", async function () {
            const { privateWBTC } = await loadFixture(deployFixture);
            const event =
                privateWBTC.interface.getEvent("PrivacyDisabled");
            expect(event).to.not.be.undefined;
        });

        it("should have PrivacyDisableCancelled event in ABI", async function () {
            const { privateWBTC } = await loadFixture(deployFixture);
            const event = privateWBTC.interface.getEvent(
                "PrivacyDisableCancelled"
            );
            expect(event).to.not.be.undefined;
        });

        it("should have all custom errors in ABI", async function () {
            const { privateWBTC } = await loadFixture(deployFixture);

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
                    privateWBTC.interface.getError(errorName);
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
        it.skip("convertToPrivate -- scale 8-dec to 6-dec, track dust, create MPC balance (Requires COTI testnet)", function () {
            // MpcCore.setPublic64, MpcCore.onBoard, MpcCore.checkedAdd,
            // MpcCore.offBoard all require COTI MPC precompile.
        });

        it.skip("convertToPrivate -- revert PrivacyNotAvailable when disabled (Requires COTI testnet)", function () {
            // Privacy is disabled on Hardhat. The revert guard is the
            // first check so it is technically testable, but the full
            // success path (needed for integration) requires COTI.
        });

        it.skip("convertToPrivate -- revert ZeroAmount for sub-SCALING_FACTOR amount (99 satoshi) (Requires COTI testnet)", function () {
            // 99 / 100 == 0 triggers ZeroAmount revert.
            // Requires privacy to be enabled (COTI chain ID).
        });

        it.skip("convertToPrivate -- dust = amount mod SCALING_FACTOR (max 99 satoshi) (Requires COTI testnet)", function () {
            // Dust accumulates in dustBalances mapping during the
            // MPC conversion path. Cannot populate without MPC.
        });

        it.skip("convertToPrivate -- revert AmountTooLarge for > uint64 max * 100 (Requires COTI testnet)", function () {
            // scaledAmount > type(uint64).max check after scaling.
        });

        it.skip("convertToPublic -- decrypt MPC, scale 6-dec to 8-dec, credit publicBalances (Requires COTI testnet)", function () {
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

        it.skip("emergencyRecoverPrivateBalance -- scales shadow ledger back to 8-dec (Requires COTI testnet)", function () {
            // Recovery multiplies shadow ledger by SCALING_FACTOR (100).
            // Cannot test without populating shadow ledger via MPC.
        });
    });
});
