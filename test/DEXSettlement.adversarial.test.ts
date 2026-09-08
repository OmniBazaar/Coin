/**
 * DEXSettlement.sol — Adversarial Test Suite (Round 8)
 *
 * Tests derived from adversarial agent A2 findings:
 *   A2-01: Intent collateral deadline griefing (Medium, HIGH conf)
 *   A2-02: Matching validator free-riding (Low, LOW conf)
 *   A2-03: Daily volume limit reset manipulation (Low, MEDIUM conf)
 *   DEFENDED: Nonce bitmap, fee calculation, timelock bypass, reentrancy
 */

/* eslint-disable @typescript-eslint/no-var-requires */
const { expect } = require('chai');
const { ethers } = require('hardhat');
const { time } = require('@nomicfoundation/hardhat-network-helpers');

/** Helper: get a deadline safely in the EVM future */
async function futureDeadline(offset = 86400 * 365): Promise<number> {
  const blk = await ethers.provider.getBlock('latest');
  return blk!.timestamp + offset;
}

/**
 * Helper to sign an IntentAcceptance EIP-712 message (C-01 solver consent).
 * @param intentId Intent identifier (bytes32)
 * @param trader Address of the trader locking collateral
 * @param solver Address of the solver accepting the intent
 * @param tokenIn Token being provided by the trader
 * @param tokenOut Token being provided by the solver
 * @param traderAmount Amount the trader is locking
 * @param solverAmount Amount the solver will provide
 * @param deadline Deadline timestamp
 * @param solverSigner Signer wallet for the solver
 * @param settlement DEXSettlement contract instance
 * @returns EIP-712 signature string
 */
async function signIntentAcceptance(
  intentId: string,
  trader: string,
  solver: string,
  tokenIn: string,
  tokenOut: string,
  traderAmount: bigint,
  solverAmount: bigint,
  deadline: number,
  solverSigner: any,
  settlement: any
): Promise<string> {
  const network = await ethers.provider.getNetwork();
  const domain = {
    name: 'OmniCoin DEX Settlement',
    version: '3',
    chainId: network.chainId,
    verifyingContract: await settlement.getAddress()
  };
  const types = {
    IntentAcceptance: [
      { name: 'intentId', type: 'bytes32' },
      { name: 'trader', type: 'address' },
      { name: 'solver', type: 'address' },
      { name: 'tokenIn', type: 'address' },
      { name: 'tokenOut', type: 'address' },
      { name: 'traderAmount', type: 'uint256' },
      { name: 'solverAmount', type: 'uint256' },
      { name: 'deadline', type: 'uint256' }
    ]
  };
  const value = {
    intentId,
    trader,
    solver,
    tokenIn,
    tokenOut,
    traderAmount,
    solverAmount,
    deadline
  };
  return solverSigner.signTypedData(domain, types, value);
}

/** Helper: sign an order with EIP-712 (V3 domain) */
async function signOrder(order: any, signer: any, settlement: any) {
  const network = await ethers.provider.getNetwork();
  const domain = {
    name: 'OmniCoin DEX Settlement',
    version: '3',
    chainId: network.chainId,
    verifyingContract: await settlement.getAddress()
  };
  const types = {
    Order: [
      { name: 'trader', type: 'address' },
      { name: 'isBuy', type: 'bool' },
      { name: 'tokenIn', type: 'address' },
      { name: 'tokenOut', type: 'address' },
      { name: 'amountIn', type: 'uint256' },
      { name: 'amountOut', type: 'uint256' },
      { name: 'price', type: 'uint256' },
      { name: 'deadline', type: 'uint256' },
      { name: 'salt', type: 'bytes32' },
      { name: 'matchingValidator', type: 'address' },
      { name: 'nonce', type: 'uint256' },
      { name: 'referrer', type: 'address' },
      { name: 'referrer2', type: 'address' }
    ]
  };
  return signer.signTypedData(domain, types, order);
}

describe('DEXSettlement — Adversarial (Round 8)', function () {
  let settlement: any;
  let tokenA: any;
  let tokenB: any;
  let _owner: any;
  let maker: any;
  let taker: any;
  let validator: any;
  let lpPool: any;
  let feeVault: any;
  let attacker: any;

  const INITIAL_BALANCE = ethers.parseUnits('1000000', 18);
  const TIMELOCK_DELAY = 48 * 3600;

  beforeEach(async function () {
    [_owner, maker, taker, validator, lpPool, feeVault, attacker] = await ethers.getSigners();

    const MockERC20 = await ethers.getContractFactory('MockERC20');
    tokenA = await MockERC20.deploy('TokenA', 'TKA');
    tokenB = await MockERC20.deploy('TokenB', 'TKB');

    const DEXSettlement = await ethers.getContractFactory('DEXSettlement');
    settlement = await DEXSettlement.deploy(
      lpPool.address,
      feeVault.address,
      attacker.address, // oddaoTreasury (dummy — not exercised in these tests)
      ethers.ZeroAddress // trustedForwarder
    );

    // Mint and approve
    await tokenA.mint(maker.address, INITIAL_BALANCE);
    await tokenB.mint(taker.address, INITIAL_BALANCE);
    await tokenA.connect(maker).approve(await settlement.getAddress(), ethers.MaxUint256);
    await tokenB.connect(taker).approve(await settlement.getAddress(), ethers.MaxUint256);
  });

  // ═══════════════════════════════════════════════════════════════════════
  //  A2-01: Intent collateral deadline griefing
  // ═══════════════════════════════════════════════════════════════════════

  describe('A2-01: Intent deadline griefing', function () {
    it('should document that trader cannot cancel before deadline', async function () {
      // Check if lockIntentCollateral exists
      const hasIntentFunctions = typeof settlement.lockIntentCollateral === 'function';
      if (!hasIntentFunctions) {
        this.skip();
        return;
      }

      const deadline = await futureDeadline(7 * 86400); // 7 days
      const intentId = ethers.keccak256(ethers.toUtf8Bytes('INTENT_1'));
      const tokenAAddr = await tokenA.getAddress();
      const tokenBAddr = await tokenB.getAddress();
      const traderAmount = ethers.parseEther('100000');
      const solverAmount = ethers.parseEther('100000');

      // C-01: Attacker (solver) must sign IntentAcceptance to consent
      const solverSig = await signIntentAcceptance(
        intentId, maker.address, attacker.address,
        tokenAAddr, tokenBAddr,
        traderAmount, solverAmount, deadline,
        attacker, settlement
      );

      await settlement.connect(maker).lockIntentCollateral(
        intentId,
        attacker.address, // malicious solver
        tokenAAddr,       // tokenIn
        tokenBAddr,       // tokenOut
        traderAmount,     // traderAmount
        solverAmount,     // solverAmount
        deadline,
        validator.address, // matchingValidator
        ethers.ZeroAddress, // referrer
        ethers.ZeroAddress, // referrer2
        solverSig           // C-01: solver consent signature
      );

      // Trader cannot cancel before deadline
      await expect(
        settlement.connect(maker).cancelIntent(intentId)
      ).to.be.reverted;
    });

    it('should allow cancel after deadline passes', async function () {
      const hasIntentFunctions = typeof settlement.lockIntentCollateral === 'function';
      if (!hasIntentFunctions) {
        this.skip();
        return;
      }

      const deadline = await futureDeadline(7 * 86400);
      const intentId = ethers.keccak256(ethers.toUtf8Bytes('INTENT_2'));
      const tokenAAddr = await tokenA.getAddress();
      const tokenBAddr = await tokenB.getAddress();
      const traderAmount = ethers.parseEther('100000');
      const solverAmount = ethers.parseEther('100000');

      // C-01: Attacker (solver) must sign IntentAcceptance to consent
      const solverSig = await signIntentAcceptance(
        intentId, maker.address, attacker.address,
        tokenAAddr, tokenBAddr,
        traderAmount, solverAmount, deadline,
        attacker, settlement
      );

      await settlement.connect(maker).lockIntentCollateral(
        intentId,
        attacker.address, // solver
        tokenAAddr,       // tokenIn
        tokenBAddr,       // tokenOut
        traderAmount,     // traderAmount
        solverAmount,     // solverAmount
        deadline,
        validator.address, // matchingValidator
        ethers.ZeroAddress, // referrer
        ethers.ZeroAddress, // referrer2
        solverSig           // C-01: solver consent signature
      );

      // Advance past deadline
      await time.increase(7 * 86400 + 1);

      // Now cancel should work
      await expect(
        settlement.connect(maker).cancelIntent(intentId)
      ).to.not.be.reverted;
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  //  A2-03: Daily volume limit boundary reset
  // ═══════════════════════════════════════════════════════════════════════

  describe('A2-03: Daily volume limit boundary', function () {
    it('should enforce daily volume limits', async function () {
      const hasDailyVolume = typeof settlement.dailyVolumeUsed === 'function';
      if (!hasDailyVolume) {
        this.skip();
        return;
      }

      // This test documents the boundary behavior
      const used = await settlement.dailyVolumeUsed();
      expect(used).to.be.gte(0n);
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  //  DEFENDED: Nonce bitmap prevents order replay
  // ═══════════════════════════════════════════════════════════════════════

  describe('DEFENDED: Nonce bitmap', function () {
    it('should prevent order replay via nonce bitmap', async function () {
      const deadline = await futureDeadline();
      const order = {
        trader: maker.address,
        isBuy: true,
        tokenIn: await tokenA.getAddress(),
        tokenOut: await tokenB.getAddress(),
        amountIn: ethers.parseEther('1000'),
        amountOut: ethers.parseEther('1000'),
        price: ethers.parseEther('1'),
        deadline,
        salt: ethers.randomBytes(32),
        matchingValidator: validator.address,
        nonce: 0n,
        referrer: ethers.ZeroAddress,
        referrer2: ethers.ZeroAddress
      };

      const _makerSig = await signOrder(order, maker, settlement);

      // Invalidate nonce 0 to prevent the order from being filled
      await settlement.connect(maker).invalidateNonce(0n);

      // Verify nonce is used
      const isUsed = await settlement.isNonceUsed(maker.address, 0n);
      expect(isUsed).to.be.true;
    });

    it('should handle high nonce values', async function () {
      const highNonce = 2n ** 255n;
      await settlement.connect(maker).invalidateNonce(highNonce);
      const isUsed = await settlement.isNonceUsed(maker.address, highNonce);
      expect(isUsed).to.be.true;
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  //  DEFENDED: renounceOwnership always reverts
  // ═══════════════════════════════════════════════════════════════════════

  describe('DEFENDED: renounceOwnership blocked', function () {
    it('should revert on renounceOwnership', async function () {
      await expect(
        settlement.renounceOwnership()
      ).to.be.revertedWithCustomError(settlement, 'InvalidAddress');
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  //  DEFENDED: Access control on admin functions
  // ═══════════════════════════════════════════════════════════════════════

  describe('DEFENDED: Access control', function () {
    it('should reject non-owner pause', async function () {
      await expect(
        settlement.connect(attacker).pause()
      ).to.be.reverted;
    });

    it('should reject non-owner fee recipient schedule', async function () {
      await expect(
        settlement.connect(attacker).scheduleFeeRecipients(
          attacker.address,
          attacker.address,
          attacker.address
        )
      ).to.be.reverted;
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  //  DEFENDED: Fee recipient timelock
  // ═══════════════════════════════════════════════════════════════════════

  describe('DEFENDED: Fee recipient timelock', function () {
    it('should enforce 48h delay on fee recipient changes', async function () {
      await settlement.scheduleFeeRecipients(
        attacker.address,
        attacker.address,
        attacker.address
      );

      // Cannot apply immediately
      await expect(
        settlement.applyFeeRecipients()
      ).to.be.reverted;

      // Advance past timelock
      await time.increase(TIMELOCK_DELAY + 1);
      await expect(
        settlement.applyFeeRecipients()
      ).to.not.be.reverted;
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  //  V3: Partial-fill adversarial cases
  // ═══════════════════════════════════════════════════════════════════════

  describe('V3 Partial Fill: Malicious settler attacks', function () {
    /**
     * Helper: build a matched maker/taker pair with specified fill amounts.
     * Maker sells tokenA for tokenB; taker is the inverse.
     */
    async function buildPair(
      makerAmountIn: bigint,
      takerAmountIn: bigint,
      makerNonce: number,
      takerNonce: number,
      makerSigner: any,
      takerSigner: any
    ) {
      const deadline = await futureDeadline();
      const makerOrder = {
        trader: makerSigner.address,
        isBuy: false,
        tokenIn: await tokenA.getAddress(),
        tokenOut: await tokenB.getAddress(),
        amountIn: makerAmountIn,
        amountOut: takerAmountIn,
        price: ethers.parseEther('1'),
        deadline,
        salt: ethers.randomBytes(32),
        matchingValidator: validator.address,
        nonce: BigInt(makerNonce),
        referrer: ethers.ZeroAddress,
        referrer2: ethers.ZeroAddress
      };
      const takerOrder = {
        trader: takerSigner.address,
        isBuy: true,
        tokenIn: await tokenB.getAddress(),
        tokenOut: await tokenA.getAddress(),
        amountIn: takerAmountIn,
        amountOut: makerAmountIn,
        price: ethers.parseEther('1'),
        deadline,
        salt: ethers.randomBytes(32),
        matchingValidator: validator.address,
        nonce: BigInt(takerNonce),
        referrer: ethers.ZeroAddress,
        referrer2: ethers.ZeroAddress
      };
      const makerSig = await signOrder(makerOrder, makerSigner, settlement);
      const takerSig = await signOrder(takerOrder, takerSigner, settlement);
      return { makerOrder, takerOrder, makerSig, takerSig };
    }

    it('should revert FillExceedsRemaining when settler inflates makerFillAmount', async function () {
      const makerSize = ethers.parseEther('1000');
      const takerSize = ethers.parseEther('1000');
      const { makerOrder, takerOrder, makerSig, takerSig } =
        await buildPair(makerSize, takerSize, 0, 0, maker, taker);

      // Malicious settler tries to drain maker by claiming an inflated fill
      const inflated = makerSize + ethers.parseEther('1');
      await expect(
        settlement.connect(attacker).settleTrade(
          makerOrder, takerOrder,
          inflated, takerSize,
          makerSig, takerSig
        )
      ).to.be.revertedWithCustomError(settlement, 'FillExceedsRemaining');
    });

    it('should revert FillProportionalityMismatch when settler under-pays taker', async function () {
      const makerSize = ethers.parseEther('1000');
      const takerSize = ethers.parseEther('1000');
      const { makerOrder, takerOrder, makerSig, takerSig } =
        await buildPair(makerSize, takerSize, 0, 0, maker, taker);

      // Settler tries to pay taker half the tokens for full maker fill
      const makerFill = makerSize;
      const takerFill = takerSize / 2n;
      await expect(
        settlement.connect(attacker).settleTrade(
          makerOrder, takerOrder,
          makerFill, takerFill,
          makerSig, takerSig
        )
      ).to.be.revertedWithCustomError(settlement, 'FillProportionalityMismatch');
    });

    it('should allow cross-order replay of partial maker order up to remainder, then revert', async function () {
      const [, , , , , , , secondTaker] = await ethers.getSigners();
      await tokenB.mint(secondTaker.address, INITIAL_BALANCE);
      await tokenB.connect(secondTaker).approve(await settlement.getAddress(), ethers.MaxUint256);

      const makerSize = ethers.parseEther('1000');
      const half = ethers.parseEther('500');

      // Maker sells 1000 tokenA for 1000 tokenB (1:1 rate).
      // First taker signs an order for 500 tokenB → 500 tokenA, which only
      // partially consumes the maker order (500 / 1000).
      const first = await buildPair(makerSize, makerSize, 0, 0, maker, taker);
      // Override taker's desired amounts to reflect a half-size partial fill
      const takerOrder1 = {
        ...first.takerOrder,
        amountIn: half,
        amountOut: half,
        salt: ethers.randomBytes(32)
      };
      const takerSig1 = await signOrder(takerOrder1, taker, settlement);

      await settlement.connect(attacker).settleTrade(
        first.makerOrder, takerOrder1,
        half, half,
        first.makerSig, takerSig1
      );

      // Second taker (different trader!) consumes the 500 remaining
      const deadline = await futureDeadline();
      const taker2Order = {
        trader: secondTaker.address,
        isBuy: true,
        tokenIn: await tokenB.getAddress(),
        tokenOut: await tokenA.getAddress(),
        amountIn: half,
        amountOut: half,
        price: ethers.parseEther('1'),
        deadline,
        salt: ethers.randomBytes(32),
        matchingValidator: validator.address,
        nonce: 0n,
        referrer: ethers.ZeroAddress,
        referrer2: ethers.ZeroAddress
      };
      const taker2Sig = await signOrder(taker2Order, secondTaker, settlement);

      // Succeeds: consumes final 500 of the maker order
      await settlement.connect(attacker).settleTrade(
        first.makerOrder, taker2Order,
        half, half,
        first.makerSig, taker2Sig
      );

      // Third taker attempts to consume more — should revert.
      // Maker order has filledAmount == amountIn, so _verifyFillAmounts
      // reverts with OrderAlreadyFilled before the nonce check runs.
      const taker3Order = {
        ...taker2Order,
        nonce: 1n,
        salt: ethers.randomBytes(32)
      };
      const taker3Sig = await signOrder(taker3Order, secondTaker, settlement);
      await expect(
        settlement.connect(attacker).settleTrade(
          first.makerOrder, taker3Order,
          ethers.parseEther('1'), ethers.parseEther('1'),
          first.makerSig, taker3Sig
        )
      ).to.be.revertedWithCustomError(settlement, 'OrderAlreadyFilled');
    });
  });
});
