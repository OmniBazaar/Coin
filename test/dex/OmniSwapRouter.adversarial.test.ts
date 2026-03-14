/**
 * OmniSwapRouter.sol — Adversarial Test Suite (Round 8)
 *
 * Tests derived from adversarial agent B2 findings:
 *   A2-SR-01: rescueTokens scope (Medium, MEDIUM conf)
 *   A2-SR-02: Adapter gas griefing (Low, LOW conf)
 *   DEFENDED: Token theft via adapter, multi-hop theft, reentrancy,
 *             slippage manipulation, source registration, fee-on-transfer
 */

/* eslint-disable @typescript-eslint/no-var-requires */
const { expect } = require('chai');
const { ethers } = require('hardhat');
const { loadFixture, time } = require('@nomicfoundation/hardhat-network-helpers');

describe('OmniSwapRouter — Adversarial (Round 8)', function () {
  const DEFAULT_FEE_BPS = 30;
  const SWAP_AMOUNT = ethers.parseEther('1000');
  const RATE_1_TO_1 = ethers.parseEther('1');

  async function deployFixture() {
    const [owner, user, feeVault, attacker, other] = await ethers.getSigners();

    const MockERC20 = await ethers.getContractFactory('MockERC20');
    const tokenA = await MockERC20.deploy('TokenA', 'TKA');
    const tokenB = await MockERC20.deploy('TokenB', 'TKB');

    const MockSwapAdapter = await ethers.getContractFactory('MockSwapAdapter');
    const adapter = await MockSwapAdapter.deploy(RATE_1_TO_1);

    const OmniSwapRouter = await ethers.getContractFactory('OmniSwapRouter');
    const router = await OmniSwapRouter.deploy(
      feeVault.address,
      DEFAULT_FEE_BPS,
      ethers.ZeroAddress // forwarder
    );

    const sourceId = ethers.keccak256(ethers.toUtf8Bytes('TEST_DEX'));
    await router.addLiquiditySource(sourceId, await adapter.getAddress());

    // Mint and approve tokens
    await tokenA.mint(user.address, SWAP_AMOUNT * 10n);
    await tokenA.connect(user).approve(await router.getAddress(), ethers.MaxUint256);
    await tokenB.mint(await adapter.getAddress(), SWAP_AMOUNT * 10n);

    return { router, tokenA, tokenB, adapter, sourceId, owner, user, feeVault, attacker, other };
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  A2-SR-01: rescueTokens scope
  // ═══════════════════════════════════════════════════════════════════════

  describe('A2-SR-01: rescueTokens scope', function () {
    it('should only allow owner to rescue tokens', async function () {
      const { router, tokenA, attacker } = await loadFixture(deployFixture);

      await expect(
        router.connect(attacker).rescueTokens(
          await tokenA.getAddress()
        )
      ).to.be.reverted;
    });

    it('should rescue accidentally sent tokens', async function () {
      const { router, tokenA, owner, feeVault } = await loadFixture(deployFixture);

      // Send tokens directly to router (accident)
      const accidental = ethers.parseEther('100');
      await tokenA.mint(await router.getAddress(), accidental);

      // Rescue should send to feeVault (rescueTokens takes only token address)
      await router.rescueTokens(await tokenA.getAddress());

      const vaultBal = await tokenA.balanceOf(feeVault.address);
      expect(vaultBal).to.be.gte(accidental);
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  //  DEFENDED: Reentrancy via malicious adapter
  // ═══════════════════════════════════════════════════════════════════════

  describe('DEFENDED: Reentrancy protection', function () {
    it('should block reentrancy from malicious adapter', async function () {
      const { router, tokenA, tokenB, user, owner } = await loadFixture(deployFixture);

      // Deploy malicious adapter
      const MaliciousAdapter = await ethers.getContractFactory('MaliciousAdapter');
      const malAdapter = await MaliciousAdapter.deploy(await router.getAddress());
      await malAdapter.setAttackMode(1); // MODE_REENTER_SWAP

      const malSourceId = ethers.keccak256(ethers.toUtf8Bytes('EVIL_DEX'));
      await router.addLiquiditySource(malSourceId, await malAdapter.getAddress());

      // Attempt swap through malicious adapter
      const latestBlock = await ethers.provider.getBlock('latest');
      const deadline = latestBlock!.timestamp + 86400;
      await expect(
        router.connect(user).swap({
          tokenIn: await tokenA.getAddress(),
          tokenOut: await tokenB.getAddress(),
          amountIn: SWAP_AMOUNT,
          minAmountOut: 0n,
          path: [await tokenA.getAddress(), await tokenB.getAddress()],
          sources: [malSourceId],
          recipient: user.address,
          deadline
        })
      ).to.be.reverted;
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  //  DEFENDED: Slippage protection
  // ═══════════════════════════════════════════════════════════════════════

  describe('DEFENDED: Slippage protection', function () {
    it('should enforce minAmountOut', async function () {
      const { router, tokenA, tokenB, sourceId, user } = await loadFixture(deployFixture);

      const latestBlock = await ethers.provider.getBlock('latest');
      const deadline = latestBlock!.timestamp + 86400;

      // Set unreasonably high minAmountOut
      await expect(
        router.connect(user).swap({
          tokenIn: await tokenA.getAddress(),
          tokenOut: await tokenB.getAddress(),
          amountIn: SWAP_AMOUNT,
          minAmountOut: SWAP_AMOUNT * 100n, // 100x output expected
          path: [await tokenA.getAddress(), await tokenB.getAddress()],
          sources: [sourceId],
          recipient: user.address,
          deadline
        })
      ).to.be.revertedWithCustomError(router, 'InsufficientOutputAmount');
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  //  DEFENDED: Source registration access control
  // ═══════════════════════════════════════════════════════════════════════

  describe('DEFENDED: Source registration', function () {
    it('should reject non-owner source registration', async function () {
      const { router, attacker } = await loadFixture(deployFixture);

      await expect(
        router.connect(attacker).addLiquiditySource(
          ethers.keccak256(ethers.toUtf8Bytes('EVIL')),
          attacker.address
        )
      ).to.be.reverted;
    });

    it('should reject EOA as adapter', async function () {
      const { router, other } = await loadFixture(deployFixture);

      await expect(
        router.addLiquiditySource(
          ethers.keccak256(ethers.toUtf8Bytes('EOA')),
          other.address
        )
      ).to.be.revertedWithCustomError(router, 'AdapterNotContract');
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  //  DEFENDED: renounceOwnership blocked
  // ═══════════════════════════════════════════════════════════════════════

  describe('DEFENDED: renounceOwnership', function () {
    it('should revert on renounceOwnership', async function () {
      const { router } = await loadFixture(deployFixture);

      await expect(
        router.renounceOwnership()
      ).to.be.revertedWithCustomError(router, 'InvalidRecipientAddress');
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  //  DEFENDED: Fee vault timelock
  // ═══════════════════════════════════════════════════════════════════════

  describe('DEFENDED: Fee vault timelock', function () {
    it('should enforce 48h delay on fee vault changes', async function () {
      const { router, attacker } = await loadFixture(deployFixture);

      await router.proposeFeeVault(attacker.address);

      // Cannot accept immediately
      await expect(router.acceptFeeVault()).to.be.reverted;

      // Advance past timelock
      await time.increase(48 * 3600 + 1);
      await expect(router.acceptFeeVault()).to.not.be.reverted;
    });
  });
});
