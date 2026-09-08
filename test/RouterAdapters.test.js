const { expect } = require("chai");
const { ethers } = require("hardhat");
const { loadFixture } = require("@nomicfoundation/hardhat-network-helpers");

/**
 * @title RouterAdapters Test Suite
 * @notice Unit tests for the Tier-B adapter family:
 *           - RouterAdapterBase (via subclasses)
 *           - OmniPolymarketAdapter (Polygon funding-step wrapper)
 *           - OmniOndoAdapter (Ethereum OUSG mint wrapper)
 *
 *         Plan: the internal revenue-tier plan
 *         Decision: memory/decision_revenue_architecture_2026-05-27.md
 *
 * @dev Covers happy path + every documented revert + the external-wallet
 *      flow (the adapter is signer-agnostic; we exercise with a non-owner
 *      signer to demonstrate the same code path serves OmniBazaar embedded
 *      wallets and external MetaMask/hardware wallets identically).
 */
describe("RouterAdapters", function () {
  // Pre-declare so all describe-blocks can use them.
  // ══════════════════════════════════════════════════════════════════
  //                          CONSTANTS
  // ══════════════════════════════════════════════════════════════════

  const USDC_DECIMALS = 6;
  const OUSG_DECIMALS = 18;
  const USDC = (n) => ethers.parseUnits(String(n), USDC_DECIMALS);
  const OUSG = (n) => ethers.parseUnits(String(n), OUSG_DECIMALS);

  const FEE_BPS = 25n;
  const BPS_DENOM = 10_000n;
  const ZERO = ethers.ZeroAddress;

  // ══════════════════════════════════════════════════════════════════
  //                          FIXTURES
  // ══════════════════════════════════════════════════════════════════

  async function deployBaseFixture() {
    const [deployer, user, externalWalletUser, depositAddr, feeVault] =
      await ethers.getSigners();

    const ERC20MockDecimals = await ethers.getContractFactory(
      "ERC20MockDecimals"
    );
    const usdc = await ERC20MockDecimals.deploy("Mock USDC", "USDC", USDC_DECIMALS);

    return { deployer, user, externalWalletUser, depositAddr, feeVault, usdc };
  }

  async function deployPolymarketFixture() {
    const base = await deployBaseFixture();
    const Adapter = await ethers.getContractFactory("OmniPolymarketAdapter");
    const adapter = await Adapter.deploy(
      await base.usdc.getAddress(),
      base.feeVault.address
    );
    // Seed USDC to both signers we exercise.
    await base.usdc.mint(base.user.address, USDC(10_000));
    await base.usdc.mint(base.externalWalletUser.address, USDC(10_000));
    return { ...base, adapter };
  }

  async function deployOndoFixture() {
    const base = await deployBaseFixture();
    const ERC20MockDecimals = await ethers.getContractFactory(
      "ERC20MockDecimals"
    );
    const ousg = await ERC20MockDecimals.deploy("Mock OUSG", "OUSG", OUSG_DECIMALS);

    const MockManager = await ethers.getContractFactory(
      "MockOusgInstantManager"
    );
    const manager = await MockManager.deploy(
      await base.usdc.getAddress(),
      await ousg.getAddress()
    );

    const Adapter = await ethers.getContractFactory("OmniOndoAdapter");
    const adapter = await Adapter.deploy(
      await base.usdc.getAddress(),
      base.feeVault.address,
      await manager.getAddress(),
      await ousg.getAddress()
    );

    await base.usdc.mint(base.user.address, USDC(1_000_000));
    await base.usdc.mint(base.externalWalletUser.address, USDC(1_000_000));

    return { ...base, ousg, manager, adapter };
  }

  // ══════════════════════════════════════════════════════════════════
  //                  RouterAdapterBase (via Polymarket)
  // ══════════════════════════════════════════════════════════════════

  describe("RouterAdapterBase", function () {
    it("rejects zero input-token address", async function () {
      const { feeVault } = await loadFixture(deployBaseFixture);
      const Adapter = await ethers.getContractFactory("OmniPolymarketAdapter");
      await expect(
        Adapter.deploy(ZERO, feeVault.address)
      ).to.be.revertedWithCustomError(Adapter, "ZeroAddress");
    });

    it("rejects zero fee-vault address", async function () {
      const { usdc } = await loadFixture(deployBaseFixture);
      const Adapter = await ethers.getContractFactory("OmniPolymarketAdapter");
      await expect(
        Adapter.deploy(await usdc.getAddress(), ZERO)
      ).to.be.revertedWithCustomError(Adapter, "ZeroAddress");
    });

    it("quoteGrossForNet computes 25 bp uplift correctly", async function () {
      const { adapter } = await loadFixture(deployPolymarketFixture);
      // 100 USDC net → 100.25 gross
      expect(await adapter.quoteGrossForNet(USDC(100))).to.equal(
        USDC(100) + (USDC(100) * FEE_BPS) / BPS_DENOM
      );
      // 1 USDC net → 1.0025 gross
      expect(await adapter.quoteGrossForNet(USDC(1))).to.equal(USDC(1) + 2500n);
      // 1_000_000 USDC net → 1_002_500 gross
      expect(await adapter.quoteGrossForNet(USDC(1_000_000))).to.equal(
        USDC(1_000_000) + USDC(2500)
      );
    });

    it("exposes FEE_BPS, FEE_VAULT, INPUT_TOKEN immutables", async function () {
      const { adapter, feeVault, usdc } = await loadFixture(deployPolymarketFixture);
      expect(await adapter.FEE_BPS()).to.equal(25n);
      expect(await adapter.FEE_VAULT()).to.equal(feeVault.address);
      expect(await adapter.INPUT_TOKEN()).to.equal(await usdc.getAddress());
      expect(await adapter.BPS_DENOMINATOR()).to.equal(10_000n);
    });
  });

  // ══════════════════════════════════════════════════════════════════
  //                  OmniPolymarketAdapter
  // ══════════════════════════════════════════════════════════════════

  describe("OmniPolymarketAdapter", function () {
    it("happy path: skims 25 bp to fee vault, forwards net to deposit addr", async function () {
      const { adapter, usdc, user, depositAddr, feeVault } = await loadFixture(
        deployPolymarketFixture
      );

      const net = USDC(100);
      const gross = await adapter.quoteGrossForNet(net);
      const fee = gross - net;

      await usdc.connect(user).approve(await adapter.getAddress(), gross);

      const userBefore = await usdc.balanceOf(user.address);
      const vaultBefore = await usdc.balanceOf(feeVault.address);
      const depositBefore = await usdc.balanceOf(depositAddr.address);

      await expect(
        adapter.connect(user).fundDeposit(net, depositAddr.address)
      )
        .to.emit(adapter, "PolymarketFunded")
        .withArgs(user.address, depositAddr.address, gross, fee, net);

      expect(await usdc.balanceOf(user.address)).to.equal(userBefore - gross);
      expect(await usdc.balanceOf(feeVault.address)).to.equal(
        vaultBefore + fee
      );
      expect(await usdc.balanceOf(depositAddr.address)).to.equal(
        depositBefore + net
      );
      // Adapter holds no residual balance.
      expect(await usdc.balanceOf(await adapter.getAddress())).to.equal(0n);
    });

    it("external wallet path: any signer with USDC + approval works identically", async function () {
      const { adapter, usdc, externalWalletUser, depositAddr, feeVault } =
        await loadFixture(deployPolymarketFixture);
      const net = USDC(250);
      const gross = await adapter.quoteGrossForNet(net);
      await usdc
        .connect(externalWalletUser)
        .approve(await adapter.getAddress(), gross);

      await adapter
        .connect(externalWalletUser)
        .fundDeposit(net, depositAddr.address);

      // Same balance changes as the embedded-wallet path.
      expect(await usdc.balanceOf(feeVault.address)).to.equal(gross - net);
      expect(await usdc.balanceOf(depositAddr.address)).to.equal(net);
    });

    it("reverts on zero net amount", async function () {
      const { adapter, depositAddr } = await loadFixture(deployPolymarketFixture);
      await expect(
        adapter.fundDeposit(0, depositAddr.address)
      ).to.be.revertedWithCustomError(adapter, "ZeroAmount");
    });

    it("reverts on zero deposit address", async function () {
      const { adapter, user } = await loadFixture(deployPolymarketFixture);
      await expect(
        adapter.connect(user).fundDeposit(USDC(100), ZERO)
      ).to.be.revertedWithCustomError(adapter, "InvalidDepositAddress");
    });

    it("reverts when user has not approved sufficient USDC", async function () {
      const { adapter, user, depositAddr } = await loadFixture(
        deployPolymarketFixture
      );
      // Approve LESS than the gross required.
      await adapter.quoteGrossForNet(USDC(100));
      await (await ethers.getContractAt("ERC20MockDecimals", await adapter.INPUT_TOKEN()))
        .connect(user)
        .approve(await adapter.getAddress(), USDC(50));

      await expect(adapter.connect(user).fundDeposit(USDC(100), depositAddr.address))
        .to.be.reverted; // SafeERC20: TRANSFER_FROM_FAILED or ERC20: insufficient allowance
    });
  });

  // ══════════════════════════════════════════════════════════════════
  //                  OmniOndoAdapter
  // ══════════════════════════════════════════════════════════════════

  describe("OmniOndoAdapter", function () {
    it("happy path: mints OUSG, skims 25 bp, forwards OUSG to user", async function () {
      const { adapter, usdc, ousg, manager, user, feeVault } =
        await loadFixture(deployOndoFixture);

      const net = USDC(10_000); // above Ondo's $5K production minimum
      const gross = await adapter.quoteGrossForNet(net);
      const fee = gross - net;

      // Default mint rate: 1 USDC → 1.056 OUSG (NAV ~$1.056 at 18 dec / 6 dec)
      const expectedOusg = (BigInt(net) * 1_056_000_000_000_000_000n) / 1_000_000n;

      await usdc.connect(user).approve(await adapter.getAddress(), gross);

      await expect(adapter.connect(user).mintOusg(net, 0n))
        .to.emit(adapter, "OndoMinted")
        .withArgs(user.address, gross, expectedOusg, fee, net);

      expect(await usdc.balanceOf(feeVault.address)).to.equal(fee);
      expect(await usdc.balanceOf(await manager.getAddress())).to.equal(net);
      expect(await ousg.balanceOf(user.address)).to.equal(expectedOusg);
      // Adapter holds no residual OUSG or USDC.
      expect(await ousg.balanceOf(await adapter.getAddress())).to.equal(0n);
      expect(await usdc.balanceOf(await adapter.getAddress())).to.equal(0n);
    });

    it("external wallet path: same revenue capture for non-embedded signer", async function () {
      const { adapter, usdc, ousg, externalWalletUser, feeVault } =
        await loadFixture(deployOndoFixture);

      const net = USDC(5_000);
      const gross = await adapter.quoteGrossForNet(net);
      await usdc
        .connect(externalWalletUser)
        .approve(await adapter.getAddress(), gross);

      await adapter.connect(externalWalletUser).mintOusg(net, 0n);

      expect(await usdc.balanceOf(feeVault.address)).to.equal(gross - net);
      expect(await ousg.balanceOf(externalWalletUser.address)).to.be.gt(0);
    });

    it("M-07: reverts SlippageExceeded when OUSG out is below minOusgOut", async function () {
      const { adapter, usdc, user } = await loadFixture(deployOndoFixture);

      const net = USDC(10_000);
      const gross = await adapter.quoteGrossForNet(net);
      await usdc.connect(user).approve(await adapter.getAddress(), gross);

      // Discover the actual OUSG the mock manager mints, then set the
      // floor one unit above it so the slippage guard must fire.
      const actualOut = await adapter
        .connect(user)
        .mintOusg.staticCall(net, 0n);
      await expect(adapter.connect(user).mintOusg(net, actualOut + 1n))
        .to.be.revertedWithCustomError(adapter, "SlippageExceeded");
    });

    it("reverts when Ondo's mint returns zero (MintReturnedZero path)", async function () {
      const { adapter, usdc, manager, user } = await loadFixture(deployOndoFixture);

      await manager.setForceZeroOut(true);
      const net = USDC(10_000);
      const gross = await adapter.quoteGrossForNet(net);
      await usdc.connect(user).approve(await adapter.getAddress(), gross);

      await expect(adapter.connect(user).mintOusg(net, 0n))
        .to.be.revertedWithCustomError(adapter, "MintReturnedZero");
    });

    it("reverts atomically when Ondo's mint reverts", async function () {
      const { adapter, usdc, manager, user, feeVault } = await loadFixture(
        deployOndoFixture
      );

      await manager.setForceRevert(true);
      const net = USDC(10_000);
      const gross = await adapter.quoteGrossForNet(net);
      await usdc.connect(user).approve(await adapter.getAddress(), gross);

      const userBefore = await usdc.balanceOf(user.address);
      const vaultBefore = await usdc.balanceOf(feeVault.address);

      await expect(adapter.connect(user).mintOusg(net, 0n)).to.be.reverted;

      // Atomicity: user retains full USDC; fee vault unchanged.
      expect(await usdc.balanceOf(user.address)).to.equal(userBefore);
      expect(await usdc.balanceOf(feeVault.address)).to.equal(vaultBefore);
    });

    it("reverts on zero net amount", async function () {
      const { adapter } = await loadFixture(deployOndoFixture);
      await expect(adapter.mintOusg(0, 0n)).to.be.revertedWithCustomError(
        adapter,
        "ZeroAmount"
      );
    });

    it("constructor rejects zero OUSG manager + zero OUSG token", async function () {
      const { usdc, feeVault, ousg } = await loadFixture(deployOndoFixture);
      const Adapter = await ethers.getContractFactory("OmniOndoAdapter");

      await expect(
        Adapter.deploy(
          await usdc.getAddress(),
          feeVault.address,
          ZERO,
          await ousg.getAddress()
        )
      ).to.be.revertedWithCustomError(Adapter, "ZeroAddress");

      await expect(
        Adapter.deploy(
          await usdc.getAddress(),
          feeVault.address,
          await ousg.getAddress(),
          ZERO
        )
      ).to.be.revertedWithCustomError(Adapter, "ZeroAddress");
    });
  });

  // ══════════════════════════════════════════════════════════════════
  //                  OmniSdaiAdapter (ERC-4626 archetype)
  // ══════════════════════════════════════════════════════════════════

  describe("OmniSdaiAdapter", function () {
    const DAI = (n) => ethers.parseEther(String(n));

    async function deploySdaiFixture() {
      const [deployer, user, externalWalletUser, feeVault] =
        await ethers.getSigners();

      const ERC20MockDecimals = await ethers.getContractFactory(
        "ERC20MockDecimals"
      );
      const dai = await ERC20MockDecimals.deploy("Mock DAI", "DAI", 18);

      const MockVault = await ethers.getContractFactory("MockERC4626Vault");
      const vault = await MockVault.deploy(
        await dai.getAddress(),
        "Mock sDAI",
        "sDAI"
      );

      const Adapter = await ethers.getContractFactory("OmniSdaiAdapter");
      const adapter = await Adapter.deploy(
        await dai.getAddress(),
        feeVault.address,
        await vault.getAddress()
      );

      await dai.mint(user.address, DAI(100_000));
      await dai.mint(externalWalletUser.address, DAI(100_000));

      return { deployer, user, externalWalletUser, feeVault, dai, vault, adapter };
    }

    it("happy path: deposits to vault, shares mint DIRECTLY to user (no adapter intermediate hold)", async function () {
      const { adapter, dai, vault, user, feeVault } = await loadFixture(deploySdaiFixture);

      const net = DAI(1_000);
      const gross = await adapter.quoteGrossForNet(net);
      const fee = gross - net;
      const expectedShares = net; // 1:1 default rate

      await dai.connect(user).approve(await adapter.getAddress(), gross);

      await expect(adapter.connect(user).depositVault(net, 0n))
        .to.emit(adapter, "SdaiDeposited")
        .withArgs(user.address, gross, expectedShares, fee, net);

      expect(await dai.balanceOf(feeVault.address)).to.equal(fee);
      expect(await dai.balanceOf(await vault.getAddress())).to.equal(net);
      expect(await vault.balanceOf(user.address)).to.equal(expectedShares);
      // Adapter holds no residual.
      expect(await dai.balanceOf(await adapter.getAddress())).to.equal(0n);
      expect(await vault.balanceOf(await adapter.getAddress())).to.equal(0n);
    });

    it("M-07: reverts SlippageExceeded when shares are below minSharesOut", async function () {
      const { adapter, dai, user } = await loadFixture(deploySdaiFixture);

      const net = DAI(1_000);
      const gross = await adapter.quoteGrossForNet(net);
      await dai.connect(user).approve(await adapter.getAddress(), gross);

      // Mock vault mints 1:1, so a floor above `net` must revert.
      await expect(adapter.connect(user).depositVault(net, net + 1n))
        .to.be.revertedWithCustomError(adapter, "SlippageExceeded");
    });

    it("external wallet path: shares land in the external signer's address", async function () {
      const { adapter, dai, vault, externalWalletUser, feeVault } =
        await loadFixture(deploySdaiFixture);
      const net = DAI(500);
      const gross = await adapter.quoteGrossForNet(net);
      await dai
        .connect(externalWalletUser)
        .approve(await adapter.getAddress(), gross);

      await adapter.connect(externalWalletUser).depositVault(net, 0n);

      expect(await dai.balanceOf(feeVault.address)).to.equal(gross - net);
      expect(await vault.balanceOf(externalWalletUser.address)).to.be.gt(0);
    });

    it("reverts when the vault returns zero shares", async function () {
      const { adapter, dai, vault, user } = await loadFixture(deploySdaiFixture);

      await vault.setForceZeroShares(true);
      const net = DAI(1_000);
      const gross = await adapter.quoteGrossForNet(net);
      await dai.connect(user).approve(await adapter.getAddress(), gross);

      await expect(adapter.connect(user).depositVault(net, 0n))
        .to.be.revertedWithCustomError(adapter, "VaultReturnedZeroShares");
    });

    it("reverts atomically when the vault reverts (user keeps DAI, vault unchanged)", async function () {
      const { adapter, dai, vault, user, feeVault } = await loadFixture(deploySdaiFixture);

      await vault.setForceRevert(true);
      const net = DAI(1_000);
      const gross = await adapter.quoteGrossForNet(net);
      await dai.connect(user).approve(await adapter.getAddress(), gross);

      const userBefore = await dai.balanceOf(user.address);
      const vaultBefore = await dai.balanceOf(feeVault.address);

      await expect(adapter.connect(user).depositVault(net, 0n)).to.be.reverted;

      expect(await dai.balanceOf(user.address)).to.equal(userBefore);
      expect(await dai.balanceOf(feeVault.address)).to.equal(vaultBefore);
    });

    it("reverts on zero net amount", async function () {
      const { adapter } = await loadFixture(deploySdaiFixture);
      await expect(adapter.depositVault(0, 0n)).to.be.revertedWithCustomError(
        adapter,
        "ZeroAmount"
      );
    });

    it("constructor rejects zero vault address", async function () {
      const { dai, feeVault } = await loadFixture(deploySdaiFixture);
      const Adapter = await ethers.getContractFactory("OmniSdaiAdapter");
      await expect(
        Adapter.deploy(await dai.getAddress(), feeVault.address, ZERO)
      ).to.be.revertedWithCustomError(Adapter, "ZeroAddress");
    });
  });

  // ══════════════════════════════════════════════════════════════════
  //                  OmniAaveAdapter (Aave V3 supply archetype)
  // ══════════════════════════════════════════════════════════════════

  describe("OmniAaveAdapter", function () {
    const REFERRAL_CODE = 4242; // arbitrary integrator code for tests

    async function deployAaveFixture() {
      const [deployer, user, externalWalletUser, feeVault] =
        await ethers.getSigners();

      const ERC20MockDecimals = await ethers.getContractFactory(
        "ERC20MockDecimals"
      );
      const usdc = await ERC20MockDecimals.deploy("Mock USDC", "USDC", USDC_DECIMALS);
      const aUsdc = await ERC20MockDecimals.deploy("Mock aUSDC", "aUSDC", USDC_DECIMALS);

      const MockPool = await ethers.getContractFactory("MockAaveV3Pool");
      const pool = await MockPool.deploy(await aUsdc.getAddress());

      const Adapter = await ethers.getContractFactory("OmniAaveAdapter");
      const adapter = await Adapter.deploy(
        await usdc.getAddress(),
        feeVault.address,
        await pool.getAddress(),
        await aUsdc.getAddress(),
        REFERRAL_CODE
      );

      await usdc.mint(user.address, USDC(100_000));
      await usdc.mint(externalWalletUser.address, USDC(100_000));

      return { deployer, user, externalWalletUser, feeVault, usdc, aUsdc, pool, adapter };
    }

    it("happy path: supplies to pool, aTokens land directly in user wallet, referral code forwarded", async function () {
      const { adapter, usdc, aUsdc, pool, user, feeVault } = await loadFixture(deployAaveFixture);

      const net = USDC(1_000);
      const gross = await adapter.quoteGrossForNet(net);
      const fee = gross - net;
      const expectedATokens = net; // 1:1 default

      await usdc.connect(user).approve(await adapter.getAddress(), gross);

      await expect(adapter.connect(user).supplyAave(net, 0n))
        .to.emit(adapter, "AaveSupplied")
        .withArgs(user.address, gross, expectedATokens, fee, net);

      expect(await usdc.balanceOf(feeVault.address)).to.equal(fee);
      expect(await usdc.balanceOf(await pool.getAddress())).to.equal(net);
      expect(await aUsdc.balanceOf(user.address)).to.equal(expectedATokens);
      // Adapter holds no residual.
      expect(await usdc.balanceOf(await adapter.getAddress())).to.equal(0n);
      expect(await aUsdc.balanceOf(await adapter.getAddress())).to.equal(0n);
      // Referral code was forwarded to Aave.
      expect(await pool.lastReferralCode()).to.equal(REFERRAL_CODE);
    });

    it("M-07: reverts SlippageExceeded when aTokens are below minATokensOut", async function () {
      const { adapter, usdc, user } = await loadFixture(deployAaveFixture);

      const net = USDC(1_000);
      const gross = await adapter.quoteGrossForNet(net);
      await usdc.connect(user).approve(await adapter.getAddress(), gross);

      // Mock pool mints aTokens 1:1, so a floor above `net` must revert.
      await expect(adapter.connect(user).supplyAave(net, net + 1n))
        .to.be.revertedWithCustomError(adapter, "SlippageExceeded");
    });

    it("external wallet path: aTokens land in the external signer's wallet", async function () {
      const { adapter, usdc, aUsdc, externalWalletUser, feeVault } =
        await loadFixture(deployAaveFixture);
      const net = USDC(500);
      const gross = await adapter.quoteGrossForNet(net);
      await usdc
        .connect(externalWalletUser)
        .approve(await adapter.getAddress(), gross);

      await adapter.connect(externalWalletUser).supplyAave(net, 0n);

      expect(await usdc.balanceOf(feeVault.address)).to.equal(gross - net);
      expect(await aUsdc.balanceOf(externalWalletUser.address)).to.equal(net);
    });

    it("reverts when pool mints zero aTokens", async function () {
      const { adapter, usdc, pool, user } = await loadFixture(deployAaveFixture);

      await pool.setForceZeroMint(true);
      const net = USDC(1_000);
      const gross = await adapter.quoteGrossForNet(net);
      await usdc.connect(user).approve(await adapter.getAddress(), gross);

      await expect(adapter.connect(user).supplyAave(net, 0n))
        .to.be.revertedWithCustomError(adapter, "SupplyReturnedZeroATokens");
    });

    it("reverts atomically when Aave pool reverts (user keeps USDC, vault unchanged)", async function () {
      const { adapter, usdc, pool, user, feeVault } = await loadFixture(deployAaveFixture);

      await pool.setForceRevert(true);
      const net = USDC(1_000);
      const gross = await adapter.quoteGrossForNet(net);
      await usdc.connect(user).approve(await adapter.getAddress(), gross);

      const userBefore = await usdc.balanceOf(user.address);
      const vaultBefore = await usdc.balanceOf(feeVault.address);

      await expect(adapter.connect(user).supplyAave(net, 0n)).to.be.reverted;

      expect(await usdc.balanceOf(user.address)).to.equal(userBefore);
      expect(await usdc.balanceOf(feeVault.address)).to.equal(vaultBefore);
    });

    it("reverts on zero net amount", async function () {
      const { adapter } = await loadFixture(deployAaveFixture);
      await expect(adapter.supplyAave(0, 0n)).to.be.revertedWithCustomError(
        adapter,
        "ZeroAmount"
      );
    });

    it("constructor rejects zero pool or aToken address", async function () {
      const { usdc, feeVault, aUsdc, pool } = await loadFixture(deployAaveFixture);
      const Adapter = await ethers.getContractFactory("OmniAaveAdapter");

      await expect(
        Adapter.deploy(
          await usdc.getAddress(),
          feeVault.address,
          ZERO,
          await aUsdc.getAddress(),
          REFERRAL_CODE
        )
      ).to.be.revertedWithCustomError(Adapter, "ZeroAddress");

      await expect(
        Adapter.deploy(
          await usdc.getAddress(),
          feeVault.address,
          await pool.getAddress(),
          ZERO,
          REFERRAL_CODE
        )
      ).to.be.revertedWithCustomError(Adapter, "ZeroAddress");
    });
  });
});
