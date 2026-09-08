/**
 * RouterAdapters mainnet-fork verification suite (Phase 2.5).
 *
 * Decision: founder-approved 2026-05-27 — fork tests are the cheap path to
 * certainty (vs $5K+ real-money tests). Plan: the internal revenue-tier plan.
 *
 * Three scenarios, each forking the relevant production chain:
 *   1. Polymarket adapter against real Polygon USDC.e — proves the adapter
 *      handles real-world Polygon USDC quirks (USDC.e is the canonical
 *      bridged variant Polymarket accepts).
 *   2. sDAI adapter against real Ethereum mainnet sDAI vault — proves the
 *      ERC-4626 archetype works against the production sDAI contract.
 *   3. Ondo OUSG adapter against real OUSGInstantManager — RESOLVES THE
 *      transfer-restriction question: can our adapter forward OUSG to an
 *      allowlisted user atomically inside the mintOusg tx?
 *
 * Runs against:
 *   - Polygon: https://polygon.drpc.org (public, no key)
 *   - Ethereum: http://127.0.0.1:8545 (local Reth archive node on V1)
 *
 * Run:
 *   FORK_TEST=1 npx hardhat test test/RouterAdapters.fork.test.js
 *
 * Without FORK_TEST=1 the file no-ops (skip all). This keeps the regular
 * `npm test` suite from depending on RPC availability.
 */

const { expect } = require("chai");
const { ethers, network } = require("hardhat");

const SKIP = process.env.FORK_TEST !== "1";

const POLYGON_RPC = process.env.POLYGON_FORK_RPC || "https://polygon.drpc.org";
const ETHEREUM_RPC = process.env.ETH_FORK_RPC || "http://127.0.0.1:8545";

// Canonical production addresses
const POLYGON_USDC_E = "0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174"; // USDC.e (Polymarket's accepted USDC)
const ETH_DAI = "0x6B175474E89094C44Da98b954EedeAC495271d0F";
const ETH_SDAI_VAULT = "0x83F20F44975D03b1b09e64809B757c47f942BEeA";
const ETH_USDC = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";
const ETH_OUSG = "0x1B19C19393e2d034D8Ff31ff34c81252FcBbee92";
// OUSG InstantManager v1 (0x2826...6A43) was DEPRECATED April 7, 2025.
// v2 is the current production address per Ondo's docs.ondo.finance/addresses.
const ETH_OUSG_MGR_V2 = "0x93358db73B6cd4b98D89c8F5f230E81a95c2643a";

// Aave V3 production addresses on Ethereum mainnet.
// Pool: unified V3 lending pool.
// aEthUSDC: aToken for USDC supplied to Aave V3 Ethereum market.
const ETH_AAVE_V3_POOL = "0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2";
const ETH_AAVE_V3_AUSDC = "0x98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c";

// Known whale addresses for impersonation (post-fork only — these never
// sign real txs). Picked because each holds a meaningful balance of the
// target token on mainnet at the time of writing.
const POLYGON_USDC_E_WHALE = "0xF977814e90dA44bFA03b6295A0616a897441aceC"; // Binance hot wallet (Polygon)
const ETH_DAI_WHALE = "0x40ec5B33f54e0E8A33A975908C5BA1c14e5BbbDf"; // Polygon PoS Bridge (Ethereum)

const SECOND = 1000;

async function forkTo(jsonRpcUrl, blockNumber) {
  await network.provider.send("hardhat_reset", [
    {
      forking: { jsonRpcUrl, ...(blockNumber !== undefined && { blockNumber }) },
    },
  ]);
}

async function impersonate(addr) {
  await network.provider.send("hardhat_impersonateAccount", [addr]);
  // Top up native gas balance so the impersonated account can sign txs.
  await network.provider.send("hardhat_setBalance", [addr, "0x21E19E0C9BAB2400000"]); // 10,000 ETH/MATIC
  return await ethers.getSigner(addr);
}

(SKIP ? describe.skip : describe)("RouterAdapters fork suite", function () {
  this.timeout(180 * SECOND);

  // ══════════════════════════════════════════════════════════════════
  //                  Polymarket adapter — Polygon fork
  // ══════════════════════════════════════════════════════════════════

  describe("OmniPolymarketAdapter @ Polygon fork", function () {
    let adapter, usdc, signer, depositAddr, feeVault;

    before(async function () {
      console.log("[fork] resetting to Polygon mainnet via", POLYGON_RPC);
      await forkTo(POLYGON_RPC);

      const [_default, _depositAddr, _feeVault] = await ethers.getSigners();
      depositAddr = _depositAddr;
      feeVault = _feeVault;

      // Impersonate a real USDC.e whale on Polygon.
      signer = await impersonate(POLYGON_USDC_E_WHALE);
      usdc = await ethers.getContractAt(
        "@openzeppelin/contracts/token/ERC20/IERC20.sol:IERC20",
        POLYGON_USDC_E,
        signer,
      );
      const balance = await usdc.balanceOf(POLYGON_USDC_E_WHALE);
      console.log(`[fork] whale USDC.e balance: ${ethers.formatUnits(balance, 6)} USDC.e`);
      if (balance === 0n) this.skip();

      const Adapter = await ethers.getContractFactory("OmniPolymarketAdapter");
      adapter = await Adapter
        .connect(await ethers.getSigner((await ethers.getSigners())[0].address))
        .deploy(POLYGON_USDC_E, feeVault.address);
      await adapter.waitForDeployment();
      console.log("[fork] OmniPolymarketAdapter deployed at", await adapter.getAddress());
    });

    it("routes 100 USDC.e funding tx end-to-end against real Polygon USDC.e", async function () {
      const net = ethers.parseUnits("100", 6);
      const gross = await adapter.quoteGrossForNet(net);
      const fee = gross - net;

      const feeVaultBefore = await usdc.balanceOf(feeVault.address);
      const depositBefore = await usdc.balanceOf(depositAddr.address);

      await usdc.connect(signer).approve(await adapter.getAddress(), gross);
      const tx = await adapter
        .connect(signer)
        .fundDeposit(net, depositAddr.address);
      const rcpt = await tx.wait();
      console.log(`[fork] fundDeposit gas: ${rcpt.gasUsed.toString()}`);

      expect(await usdc.balanceOf(feeVault.address)).to.equal(feeVaultBefore + fee);
      expect(await usdc.balanceOf(depositAddr.address)).to.equal(depositBefore + net);
      expect(await usdc.balanceOf(await adapter.getAddress())).to.equal(0n);
    });
  });

  // ══════════════════════════════════════════════════════════════════
  //                  sDAI adapter — Ethereum fork
  // ══════════════════════════════════════════════════════════════════

  describe("OmniSdaiAdapter @ Ethereum fork", function () {
    let adapter, dai, sDaiVault, signer, feeVault;

    before(async function () {
      console.log("[fork] resetting to Ethereum mainnet via", ETHEREUM_RPC);
      await forkTo(ETHEREUM_RPC);

      const [_default, _feeVault] = await ethers.getSigners();
      feeVault = _feeVault;

      signer = await impersonate(ETH_DAI_WHALE);
      dai = await ethers.getContractAt(
        "@openzeppelin/contracts/token/ERC20/IERC20.sol:IERC20",
        ETH_DAI,
        signer,
      );
      sDaiVault = await ethers.getContractAt(
        "@openzeppelin/contracts/interfaces/IERC4626.sol:IERC4626",
        ETH_SDAI_VAULT,
      );

      const daiBalance = await dai.balanceOf(ETH_DAI_WHALE);
      console.log(`[fork] whale DAI balance: ${ethers.formatUnits(daiBalance, 18)} DAI`);
      if (daiBalance === 0n) this.skip();

      const Adapter = await ethers.getContractFactory("OmniSdaiAdapter");
      adapter = await Adapter
        .connect((await ethers.getSigners())[0])
        .deploy(ETH_DAI, feeVault.address, ETH_SDAI_VAULT);
      await adapter.waitForDeployment();
      console.log("[fork] OmniSdaiAdapter deployed at", await adapter.getAddress());
    });

    it("deposits 1,000 DAI into real sDAI vault, shares mint directly to caller", async function () {
      const net = ethers.parseUnits("1000", 18);
      const gross = await adapter.quoteGrossForNet(net);
      const fee = gross - net;

      const feeVaultBefore = await dai.balanceOf(feeVault.address);
      const sharesBefore = await sDaiVault.balanceOf(signer.address);

      await dai.connect(signer).approve(await adapter.getAddress(), gross);
      const tx = await adapter.connect(signer).depositVault(net, 0n);
      const rcpt = await tx.wait();
      console.log(`[fork] depositVault gas: ${rcpt.gasUsed.toString()}`);

      expect(await dai.balanceOf(feeVault.address)).to.equal(feeVaultBefore + fee);
      const sharesAfter = await sDaiVault.balanceOf(signer.address);
      expect(sharesAfter).to.be.gt(sharesBefore);
      console.log(`[fork] sDAI shares received: ${ethers.formatUnits(sharesAfter - sharesBefore, 18)}`);
      // Adapter holds no residual.
      expect(await dai.balanceOf(await adapter.getAddress())).to.equal(0n);
      expect(await sDaiVault.balanceOf(await adapter.getAddress())).to.equal(0n);
    });
  });

  // ══════════════════════════════════════════════════════════════════
  //                  Aave V3 supply adapter — Ethereum fork
  // ══════════════════════════════════════════════════════════════════

  describe("OmniAaveAdapter @ Ethereum fork", function () {
    let adapter, usdc, aUsdc, signer, feeVault;

    before(async function () {
      console.log("[fork] resetting to Ethereum mainnet via", ETHEREUM_RPC);
      await forkTo(ETHEREUM_RPC);

      const [_default, _feeVault] = await ethers.getSigners();
      feeVault = _feeVault;

      usdc = await ethers.getContractAt(
        "@openzeppelin/contracts/token/ERC20/IERC20.sol:IERC20",
        ETH_USDC,
      );
      aUsdc = await ethers.getContractAt(
        "@openzeppelin/contracts/token/ERC20/IERC20.sol:IERC20",
        ETH_AAVE_V3_AUSDC,
      );

      // Use a fresh signer + give it synthetic USDC via storage manipulation.
      // USDC's `_balances` mapping is at slot 9 (FiatTokenV2_2 layout).
      signer = (await ethers.getSigners())[2];
      const usdcBalSlot = ethers.keccak256(
        ethers.AbiCoder.defaultAbiCoder().encode(
          ["address", "uint256"],
          [signer.address, 9],
        ),
      );
      await network.provider.send("hardhat_setStorageAt", [
        ETH_USDC,
        usdcBalSlot,
        ethers.toBeHex(ethers.parseUnits("10000", 6), 32),
      ]);
      const balance = await usdc.balanceOf(signer.address);
      console.log(`[fork] synthetic USDC for test signer: ${ethers.formatUnits(balance, 6)} USDC`);
      if (balance === 0n) this.skip();

      const Adapter = await ethers.getContractFactory("OmniAaveAdapter");
      adapter = await Adapter
        .connect((await ethers.getSigners())[0])
        .deploy(ETH_USDC, feeVault.address, ETH_AAVE_V3_POOL, ETH_AAVE_V3_AUSDC, 0);
      await adapter.waitForDeployment();
      console.log("[fork] OmniAaveAdapter deployed at", await adapter.getAddress());
    });

    it("supplies 1,000 USDC to real Aave V3 pool, aUSDC lands directly in caller", async function () {
      const net = ethers.parseUnits("1000", 6);
      const gross = await adapter.quoteGrossForNet(net);
      const fee = gross - net;

      const feeVaultBefore = await usdc.balanceOf(feeVault.address);
      const aUsdcBefore = await aUsdc.balanceOf(signer.address);

      await usdc.connect(signer).approve(await adapter.getAddress(), gross);
      const tx = await adapter.connect(signer).supplyAave(net, 0n);
      const rcpt = await tx.wait();
      console.log(`[fork] supplyAave gas: ${rcpt.gasUsed.toString()}`);

      expect(await usdc.balanceOf(feeVault.address)).to.equal(feeVaultBefore + fee);
      const aUsdcAfter = await aUsdc.balanceOf(signer.address);
      const aUsdcDelta = aUsdcAfter - aUsdcBefore;
      console.log(`[fork] aEthUSDC received: ${ethers.formatUnits(aUsdcDelta, 6)} (expected ≈ ${ethers.formatUnits(net, 6)})`);
      // Aave mints aTokens 1:1 with the supplied amount (within rounding).
      expect(aUsdcDelta).to.be.gte(net - 10n); // allow 10 wei rounding tolerance
      // Adapter holds no residual.
      expect(await usdc.balanceOf(await adapter.getAddress())).to.equal(0n);
      expect(await aUsdc.balanceOf(await adapter.getAddress())).to.equal(0n);
    });
  });

  // ══════════════════════════════════════════════════════════════════
  //              Ondo OUSG adapter — the OUSG transfer-restriction
  //              verification (Phase 1.2 open question)
  // ══════════════════════════════════════════════════════════════════

  describe("OmniOndoAdapter @ Ethereum fork — OUSG transfer-restriction probe", function () {
    let adapter, usdc, ousg, feeVault;
    let ousgHolder;

    before(async function () {
      console.log("[fork] resetting to Ethereum mainnet via", ETHEREUM_RPC);
      await forkTo(ETHEREUM_RPC);

      const [_default, _feeVault] = await ethers.getSigners();
      feeVault = _feeVault;

      usdc = await ethers.getContractAt(
        "@openzeppelin/contracts/token/ERC20/IERC20.sol:IERC20",
        ETH_USDC,
      );
      ousg = await ethers.getContractAt(
        "@openzeppelin/contracts/token/ERC20/IERC20.sol:IERC20",
        ETH_OUSG,
      );

      // Find an OUSG-allowlisted address by probing well-known holders.
      // If none holds OUSG on the forked block, skip with a clear log.
      // Strategy: query the OUSG Transfer event topic across recent blocks
      // and pick the first non-zero `to` address.
      const transferTopic = ethers.id("Transfer(address,address,uint256)");
      const latestBlock = await ethers.provider.getBlockNumber();
      const logs = await ethers.provider.getLogs({
        address: ETH_OUSG,
        topics: [transferTopic],
        fromBlock: latestBlock - 50_000,
        toBlock: latestBlock,
      });
      console.log(`[fork] found ${logs.length} OUSG Transfer events in last 50K blocks`);

      let candidate;
      for (const log of logs) {
        const to = "0x" + log.topics[2].slice(26);
        const bal = await ousg.balanceOf(to);
        if (bal > 0n && to !== ethers.ZeroAddress) {
          candidate = to;
          console.log(`[fork] found OUSG-allowlisted holder ${to}, balance: ${ethers.formatUnits(bal, 18)} OUSG`);
          break;
        }
      }

      if (!candidate) {
        console.log("[fork] no OUSG holder found on this fork — Ondo transfer-restriction test cannot run");
        this.skip();
      }

      ousgHolder = await impersonate(candidate);

      // Top up the allowlisted holder with synthetic USDC via storage.
      // USDC's `_balances` mapping is at slot 9 (standard FiatTokenV2_2 layout).
      const usdcBalSlot = ethers.keccak256(
        ethers.AbiCoder.defaultAbiCoder().encode(
          ["address", "uint256"],
          [candidate, 9],
        ),
      );
      await network.provider.send("hardhat_setStorageAt", [
        ETH_USDC,
        usdcBalSlot,
        ethers.toBeHex(ethers.parseUnits("10000", 6), 32), // 10,000 USDC
      ]);
      const synthUsdc = await usdc.balanceOf(candidate);
      console.log(`[fork] holder USDC after storage manipulation: ${ethers.formatUnits(synthUsdc, 6)}`);
      if (synthUsdc < ethers.parseUnits("5000", 6)) {
        console.log("[fork] storage manipulation failed (USDC balance not as expected) — skipping");
        this.skip();
      }

      const Adapter = await ethers.getContractFactory("OmniOndoAdapter");
      adapter = await Adapter
        .connect((await ethers.getSigners())[0])
        .deploy(ETH_USDC, feeVault.address, ETH_OUSG_MGR_V2, ETH_OUSG);
      await adapter.waitForDeployment();
      console.log("[fork] OmniOndoAdapter deployed at", await adapter.getAddress());
    });

    it("mintOusg succeeds end-to-end OR reveals the transfer-restriction blocker", async function () {
      const net = ethers.parseUnits("5001", 6); // Ondo's $5K floor + $1 margin
      const gross = await adapter.quoteGrossForNet(net);

      await usdc
        .connect(ousgHolder)
        .approve(await adapter.getAddress(), gross);

      const ousgBefore = await ousg.balanceOf(ousgHolder.address);
      const feeBefore = await usdc.balanceOf(feeVault.address);

      try {
        const tx = await adapter.connect(ousgHolder).mintOusg(net, 0n);
        const rcpt = await tx.wait();
        const ousgAfter = await ousg.balanceOf(ousgHolder.address);
        const ousgDelta = ousgAfter - ousgBefore;
        console.log(`[fork] mintOusg SUCCEEDED — gas: ${rcpt.gasUsed.toString()}, OUSG received: ${ethers.formatUnits(ousgDelta, 18)}`);
        console.log("[fork] *** RESULT: OUSG transfer-restriction PERMITS our adapter. SHIP IT. ***");
        expect(ousgAfter - ousgBefore).to.be.gt(0n);
        expect(await usdc.balanceOf(feeVault.address)).to.equal(feeBefore + (gross - net));
      } catch (err) {
        console.log(`[fork] *** RESULT: mintOusg REVERTED — ${err.shortMessage || err.message} ***`);
        console.log("[fork] *** This indicates either (a) OUSG transfer-restriction blocks the adapter, OR ***");
        console.log("[fork] *** (b) the impersonated holder isn't actually allowlisted at the manager level. ***");
        console.log("[fork] *** Pivot per the internal revenue-tier plan Phase 1.2 fallback ladder before deploying. ***");
        throw err;
      }
    });
  });
});
