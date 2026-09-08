/**
 * @file RWARouter.erc2771.test.ts
 * @description Regression coverage for the RWARouter trusted-forwarder
 * mainnet bug: `Coin/scripts/deploy-rwa.ts` deployed the live
 * `RWARouter` (mainnet 0xE0b02D0bd42F1cFF64f5E44b7D9fC59558f1F9DF) with
 * `config.wrappedNative` passed into the constructor's
 * `trustedForwarder_` slot instead of the real `OmniForwarder` address.
 * Confirmed on-chain: `RWARouter.trustedForwarder()` returns
 * `address(0)`. RWAAMM (0xdBe9101F...) is correctly wired to the real
 * `OmniForwarder` (0xaF8c638b69A61e28617e0C71178D4910aB4e83E5) — only
 * the router is broken.
 *
 * `ERC2771Context` bakes the forwarder in as a constructor-set
 * immutable with no setter, so there is no cheap on-chain fix — this
 * is only fixable with a redeploy. These tests prove:
 *
 *   (a) a correctly-deployed router reports `trustedForwarder()` ==
 *       the real forwarder address, while a router deployed the buggy
 *       way (forwarder slot = an unrelated address) does not;
 *   (b) a real EIP-712-signed meta-transaction through
 *       `OmniForwarder.execute()` targeting the BUGGY router reverts
 *       with `ERC2771UntrustfulTarget` (the exact on-chain failure
 *       mode — `OpenZeppelin's ERC2771Forwarder.verify()` returns
 *       false because the target doesn't trust the forwarder), while
 *       the same request against the FIXED router succeeds and
 *       credits the signing user, not the relayer, exactly matching
 *       production gasless-swap flow.
 *
 * No `setTrustedForwarder()` exists anywhere in the RWA contracts
 * (grepped `contracts/` — zero hits), confirming the fix must be a
 * redeploy, not an admin setter call.
 */

/* eslint-disable @typescript-eslint/no-var-requires */
const { expect } = require("chai");
const { ethers } = require("hardhat");
import type { AddressLike, Signer } from "ethers";

/**
 * Build an EIP-712-signed `ForwardRequestData` for OpenZeppelin's
 * `ERC2771Forwarder`, matching the wire format used by the Validator's
 * relay client and by `test/relay/gasless-relay.test.js`.
 *
 * @param signer - Ethers signer producing the EIP-712 signature (the
 *   end user, never the relayer).
 * @param forwarder - Deployed `OmniForwarder` contract instance.
 * @param to - Target contract address.
 * @param data - ABI-encoded calldata for the target function.
 * @returns ForwardRequestData ready for `forwarder.execute()`.
 */
async function buildForwardRequest(
  signer: Signer,
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  forwarder: any,
  to: AddressLike,
  data: string
): Promise<{
  from: string;
  to: AddressLike;
  value: bigint;
  gas: bigint;
  deadline: bigint;
  data: string;
  signature: string;
}> {
  const signerAddress = await signer.getAddress();
  const nonce = await forwarder.nonces(signerAddress);
  const latestBlock = await ethers.provider.getBlock("latest");
  const deadline = BigInt(latestBlock!.timestamp) + 3600n;
  const gas = 1_000_000n;
  const value = 0n;

  const domainData = await forwarder.eip712Domain();
  const eip712Domain = {
    name: domainData.name,
    version: domainData.version,
    chainId: domainData.chainId,
    verifyingContract: domainData.verifyingContract,
  };

  const types = {
    ForwardRequest: [
      { name: "from", type: "address" },
      { name: "to", type: "address" },
      { name: "value", type: "uint256" },
      { name: "gas", type: "uint256" },
      { name: "nonce", type: "uint256" },
      { name: "deadline", type: "uint48" },
      { name: "data", type: "bytes" },
    ],
  };

  const message = {
    from: signerAddress,
    to,
    value,
    gas,
    nonce,
    deadline,
    data,
  };

  const signature = await signer.signTypedData(eip712Domain, types, message);

  return { from: signerAddress, to, value, gas, deadline, data, signature };
}

describe("RWARouter ERC-2771 trusted-forwarder wiring", function () {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  let forwarder: any;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  let amm: any;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  let fixedRouter: any;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  let buggyRouter: any;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  let complianceOracle: any;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  let emergencyGuardian: any;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  let tokenA: any;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  let tokenB: any;

  let owner: Signer;
  let feeVault: Signer;
  let mockTimelock: Signer;
  let user: Signer;
  let relayer: Signer; // the gas-paying operator — NEVER the swap sender
  let emergencySigners: Signer[];

  const INITIAL_LIQUIDITY = ethers.parseEther("10000");
  const SWAP_AMOUNT = ethers.parseEther("100");

  /**
   * @returns a deadline timestamp comfortably in the future relative
   *   to the current block, so tests are immune to EVM-vs-wall-clock
   *   drift across a long suite run.
   */
  async function futureDeadline(): Promise<number> {
    const block = await ethers.provider.getBlock("latest");
    return block!.timestamp + 3600;
  }

  beforeEach(async function () {
    const signers = await ethers.getSigners();
    [owner, feeVault, mockTimelock, user, relayer] = signers;
    emergencySigners = signers.slice(5, 10);

    // 1. Deploy the REAL OmniForwarder (thin wrapper around OZ's
    //    ERC2771Forwarder) — this is what mainnet.json::OmniForwarder
    //    resolves to in production.
    const OmniForwarder = await ethers.getContractFactory("OmniForwarder");
    forwarder = await OmniForwarder.deploy();
    await forwarder.waitForDeployment();

    // 2. Deploy mock tokens and mint to the user.
    const ERC20Mock = await ethers.getContractFactory("ERC20Mock");
    tokenA = await ERC20Mock.deploy("Token A", "TKA");
    await tokenA.waitForDeployment();
    tokenB = await ERC20Mock.deploy("Token B", "TKB");
    await tokenB.waitForDeployment();

    await tokenA.mint(await owner.getAddress(), INITIAL_LIQUIDITY);
    await tokenB.mint(await owner.getAddress(), INITIAL_LIQUIDITY);
    await tokenA.mint(await user.getAddress(), SWAP_AMOUNT * 10n);

    // 3. Deploy RWAComplianceOracle + register both tokens with no
    //    per-token compliance contract (matches RWAAMM.test.js — a
    //    registered plain-ERC20 with no compliance override passes
    //    checkCompliance for any user).
    const RWAComplianceOracle = await ethers.getContractFactory(
      "RWAComplianceOracle"
    );
    complianceOracle = await RWAComplianceOracle.deploy(
      await owner.getAddress()
    );
    await complianceOracle.waitForDeployment();
    await complianceOracle
      .connect(owner)
      .registerToken(await tokenA.getAddress(), ethers.ZeroAddress);
    await complianceOracle
      .connect(owner)
      .registerToken(await tokenB.getAddress(), ethers.ZeroAddress);

    // 4. Deploy EmergencyGuardian (needs >= 5 unique guardians).
    const EmergencyGuardian = await ethers.getContractFactory(
      "EmergencyGuardian"
    );
    emergencyGuardian = await EmergencyGuardian.deploy(
      await mockTimelock.getAddress(),
      await Promise.all(emergencySigners.map((s) => s.getAddress()))
    );
    await emergencyGuardian.waitForDeployment();

    // 5. Deploy RWAAMM — correctly wired to the real forwarder, exactly
    //    like the live mainnet RWAAMM (0xdBe9101F...), which this
    //    investigation confirmed IS correctly wired
    //    (trustedForwarder() == 0xaF8c638b...). Only the router is
    //    broken on mainnet.
    //
    //    RWAAMM's constructor now also needs a trusted-caller list
    //    (audit fix M-02, 2026-08-04) — only a trusted contract may
    //    pass a non-zero `onBehalfOf`. Since RWAAMM and the fixed
    //    router each need to know the other's address, and both are
    //    non-upgradeable with no setter, predict fixedRouter's address
    //    from the deployer's next nonce. This deploy and fixedRouter's
    //    deploy below MUST stay back-to-back with no other
    //    owner-signed transaction interleaved — pool seeding was moved
    //    to AFTER both routers deploy for exactly this reason.
    const ownerAddress = await owner.getAddress();
    const ownerNonce = await ethers.provider.getTransactionCount(ownerAddress);
    const futureFixedRouterAddress = ethers.getCreateAddress({
      from: ownerAddress,
      nonce: ownerNonce + 1,
    });

    const RWAAMM = await ethers.getContractFactory("RWAAMM");
    amm = await RWAAMM.deploy(
      await emergencyGuardian.getAddress(),
      await feeVault.getAddress(),
      await tokenA.getAddress(),
      await complianceOracle.getAddress(),
      await forwarder.getAddress(),
      [futureFixedRouterAddress]
    );
    await amm.waitForDeployment();

    // 6. Deploy TWO routers against the same AMM:
    //    - fixedRouter: constructor wired correctly (the fix); deployed
    //      immediately after AMM so it lands at the address RWAAMM
    //      just trusted.
    //    - buggyRouter: constructor wired the way the live mainnet bug
    //      was — an unrelated address (standing in for
    //      config.wrappedNative) in the trustedForwarder_ slot. Using
    //      a distinct non-zero unrelated address (rather than
    //      address(0)) proves the bug is "wrong address", not merely
    //      "zero address" — matching the actual root cause. (A
    //      genuinely zero forwarder would now also be rejected outright
    //      by RWARouter's own L-01 fix, 2026-08-04.)
    const RWARouter = await ethers.getContractFactory("RWARouter");
    fixedRouter = await RWARouter.deploy(
      await amm.getAddress(),
      await forwarder.getAddress()
    );
    await fixedRouter.waitForDeployment();
    if (
      (await fixedRouter.getAddress()).toLowerCase() !==
      futureFixedRouterAddress.toLowerCase()
    ) {
      throw new Error(
        `fixedRouter address prediction mismatch: expected ${futureFixedRouterAddress}, got ${await fixedRouter.getAddress()}`
      );
    }

    const wrongForwarderSlotValue = await tokenB.getAddress(); // stand-in for config.wrappedNative
    buggyRouter = await RWARouter.deploy(
      await amm.getAddress(),
      wrongForwarderSlotValue
    );
    await buggyRouter.waitForDeployment();

    // 7. Seed the pool directly via the AMM (owner is a registered
    //    pool creator by default), so the router has liquidity to
    //    route against. Moved after both router deploys (see step 5).
    await tokenA
      .connect(owner)
      .approve(await amm.getAddress(), INITIAL_LIQUIDITY);
    await tokenB
      .connect(owner)
      .approve(await amm.getAddress(), INITIAL_LIQUIDITY);
    await amm
      .connect(owner)
      .addLiquidity(
        await tokenA.getAddress(),
        await tokenB.getAddress(),
        INITIAL_LIQUIDITY,
        INITIAL_LIQUIDITY,
        0n,
        0n,
        await futureDeadline(),
        ethers.ZeroAddress
      );
  });

  describe("trustedForwarder() reporting", function () {
    it("fixed router reports the real OmniForwarder address", async function () {
      expect(await fixedRouter.trustedForwarder()).to.equal(
        await forwarder.getAddress()
      );
      expect(
        await fixedRouter.isTrustedForwarder(await forwarder.getAddress())
      ).to.equal(true);
    });

    it("buggy router does NOT trust the real OmniForwarder (reproduces the mainnet bug)", async function () {
      expect(await buggyRouter.trustedForwarder()).to.not.equal(
        await forwarder.getAddress()
      );
      expect(
        await buggyRouter.isTrustedForwarder(await forwarder.getAddress())
      ).to.equal(false);
    });
  });

  describe("forwarded swap — BUGGY router (bug repro)", function () {
    it("OmniForwarder.verify() returns false and execute() reverts with ERC2771UntrustfulTarget", async function () {
      await tokenA
        .connect(user)
        .approve(await buggyRouter.getAddress(), SWAP_AMOUNT);

      const path = [await tokenA.getAddress(), await tokenB.getAddress()];
      const deadline = await futureDeadline();
      const calldata = buggyRouter.interface.encodeFunctionData(
        "swapExactTokensForTokens",
        [SWAP_AMOUNT, 1n, path, await user.getAddress(), deadline]
      );

      const request = await buildForwardRequest(
        user,
        forwarder,
        await buggyRouter.getAddress(),
        calldata
      );

      // This is the exact on-chain symptom: the forwarder's own
      // signature/deadline/nonce checks all pass, but verify() is
      // still false because the TARGET doesn't trust the forwarder.
      expect(await forwarder.verify(request)).to.equal(false);

      await expect(forwarder.connect(relayer).execute(request))
        .to.be.revertedWithCustomError(forwarder, "ERC2771UntrustfulTarget")
        .withArgs(await buggyRouter.getAddress(), await forwarder.getAddress());

      // No state changed — the swap never happened.
      expect(await tokenB.balanceOf(await user.getAddress())).to.equal(0n);
    });
  });

  describe("forwarded swap — FIXED router (proves the fix works end-to-end)", function () {
    it("OmniForwarder.verify() returns true and execute() performs a real gasless swap crediting the signing user", async function () {
      await tokenA
        .connect(user)
        .approve(await fixedRouter.getAddress(), SWAP_AMOUNT);

      const path = [await tokenA.getAddress(), await tokenB.getAddress()];
      const deadline = await futureDeadline();
      const calldata = fixedRouter.interface.encodeFunctionData(
        "swapExactTokensForTokens",
        [SWAP_AMOUNT, 1n, path, await user.getAddress(), deadline]
      );

      const request = await buildForwardRequest(
        user,
        forwarder,
        await fixedRouter.getAddress(),
        calldata
      );

      expect(await forwarder.verify(request)).to.equal(true);

      const userTokenABefore = await tokenA.balanceOf(await user.getAddress());
      const userTokenBBefore = await tokenB.balanceOf(await user.getAddress());
      const relayerTokenBBefore = await tokenB.balanceOf(
        await relayer.getAddress()
      );

      // relayer pays the gas; user never signs or sends an on-chain tx.
      await expect(forwarder.connect(relayer).execute(request)).to.not.be
        .reverted;

      const userTokenAAfter = await tokenA.balanceOf(await user.getAddress());
      const userTokenBAfter = await tokenB.balanceOf(await user.getAddress());

      // The user (the EIP-712 signer) paid tokenA and received tokenB —
      // proving _msgSender() correctly resolved to the user, not the
      // relayer forwarding the call.
      expect(userTokenABefore - userTokenAAfter).to.equal(SWAP_AMOUNT);
      expect(userTokenBAfter).to.be.gt(userTokenBBefore);

      // The relayer (gas payer) received none of the swap output.
      expect(await tokenB.balanceOf(await relayer.getAddress())).to.equal(
        relayerTokenBBefore
      );

      // Nonce consumed exactly once — replay protection intact.
      expect(await forwarder.nonces(await user.getAddress())).to.equal(1n);
    });

    it("rejects a replay of the same signed request", async function () {
      await tokenA
        .connect(user)
        .approve(await fixedRouter.getAddress(), SWAP_AMOUNT * 2n);

      const path = [await tokenA.getAddress(), await tokenB.getAddress()];
      const deadline = await futureDeadline();
      const calldata = fixedRouter.interface.encodeFunctionData(
        "swapExactTokensForTokens",
        [SWAP_AMOUNT, 1n, path, await user.getAddress(), deadline]
      );

      const request = await buildForwardRequest(
        user,
        forwarder,
        await fixedRouter.getAddress(),
        calldata
      );

      await forwarder.connect(relayer).execute(request);

      await expect(
        forwarder.connect(relayer).execute(request)
      ).to.be.revertedWithCustomError(
        forwarder,
        "ERC2771ForwarderInvalidSigner"
      );
    });
  });
});
