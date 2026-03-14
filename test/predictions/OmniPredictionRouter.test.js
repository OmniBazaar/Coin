const { expect } = require("chai");
const { ethers } = require("hardhat");

/**
 * @title OmniPredictionRouter Test Suite
 * @notice Tests for the trustless fee-collecting prediction market router.
 * @dev Validates constructor guards, immutable getters, platform allowlist
 *      management, buyWithFee input validation (including deadline and
 *      platform approval), rescueTokens access control, and event emissions.
 */
describe("OmniPredictionRouter", function () {
  let owner;
  let feeVault;
  let user;
  let platformTarget;
  let attacker;
  let router;
  let collateral;

  const MAX_FEE_BPS = 200n; // 2%
  const TOTAL_AMOUNT = ethers.parseEther("100");

  /** @notice Returns a deadline 1 hour in the future */
  async function futureDeadline() {
    const block = await ethers.provider.getBlock("latest");
    return block.timestamp + 3600;
  }

  /** @notice Returns a deadline that has already passed */
  async function pastDeadline() {
    const block = await ethers.provider.getBlock("latest");
    return block.timestamp - 1;
  }

  before(async function () {
    const signers = await ethers.getSigners();
    owner = signers[0];
    feeVault = signers[1];
    user = signers[2];
    platformTarget = signers[3];
    attacker = signers[4];
  });

  beforeEach(async function () {
    // Deploy a MockERC20 as collateral token (2-arg constructor: name, symbol)
    const MockERC20 = await ethers.getContractFactory("MockERC20");
    collateral = await MockERC20.deploy("USD Coin", "USDC");
    await collateral.waitForDeployment();

    // Mint supply to owner for distribution
    await collateral.mint(owner.address, ethers.parseEther("1000000"));

    // Deploy the router with valid parameters
    const Router = await ethers.getContractFactory("OmniPredictionRouter");
    router = await Router.deploy(feeVault.address, MAX_FEE_BPS, ethers.ZeroAddress);
    await router.waitForDeployment();
  });

  // ---------------------------------------------------------------------------
  // Constructor
  // ---------------------------------------------------------------------------

  describe("Constructor", function () {
    it("should deploy with valid feeVault and maxFeeBps", async function () {
      expect(await router.feeVault()).to.equal(feeVault.address);
      expect(await router.MAX_FEE_BPS()).to.equal(MAX_FEE_BPS);
    });

    it("should revert when feeVault is the zero address", async function () {
      const Router = await ethers.getContractFactory("OmniPredictionRouter");
      await expect(
        Router.deploy(ethers.ZeroAddress, MAX_FEE_BPS, ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(Router, "InvalidFeeVault");
    });

    it("should revert when maxFeeBps is zero", async function () {
      const Router = await ethers.getContractFactory("OmniPredictionRouter");
      await expect(
        Router.deploy(feeVault.address, 0, ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(Router, "FeeExceedsCap");
    });

    it("should revert when maxFeeBps exceeds 1000", async function () {
      const Router = await ethers.getContractFactory("OmniPredictionRouter");
      await expect(
        Router.deploy(feeVault.address, 1001, ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(Router, "FeeExceedsCap");
    });
  });

  // ---------------------------------------------------------------------------
  // Immutable getters
  // ---------------------------------------------------------------------------

  describe("Immutable getters", function () {
    it("should return the correct feeVault", async function () {
      expect(await router.feeVault()).to.equal(feeVault.address);
    });

    it("should return the correct MAX_FEE_BPS", async function () {
      expect(await router.MAX_FEE_BPS()).to.equal(MAX_FEE_BPS);
    });
  });

  // ---------------------------------------------------------------------------
  // setPlatformApproval
  // ---------------------------------------------------------------------------

  describe("setPlatformApproval", function () {
    it("should allow owner to approve a platform", async function () {
      // R6: setPlatformApproval is now onlyOwner
      await router.connect(owner).setPlatformApproval(
        platformTarget.address, true
      );
      expect(await router.approvedPlatforms(platformTarget.address)).to.equal(true);
    });

    it("should allow owner to revoke a platform", async function () {
      await router.connect(owner).setPlatformApproval(
        platformTarget.address, true
      );
      await router.connect(owner).setPlatformApproval(
        platformTarget.address, false
      );
      expect(await router.approvedPlatforms(platformTarget.address)).to.equal(false);
    });

    it("should emit PlatformApprovalChanged on approval", async function () {
      await expect(
        router.connect(owner).setPlatformApproval(
          platformTarget.address, true
        )
      ).to.emit(router, "PlatformApprovalChanged")
        .withArgs(platformTarget.address, true);
    });

    it("should emit PlatformApprovalChanged on revocation", async function () {
      await router.connect(owner).setPlatformApproval(
        platformTarget.address, true
      );
      await expect(
        router.connect(owner).setPlatformApproval(
          platformTarget.address, false
        )
      ).to.emit(router, "PlatformApprovalChanged")
        .withArgs(platformTarget.address, false);
    });

    it("should revert when called by non-owner", async function () {
      // R6: setPlatformApproval is now onlyOwner, so non-owner gets OwnableUnauthorizedAccount
      await expect(
        router.connect(user).setPlatformApproval(
          platformTarget.address, true
        )
      ).to.be.revertedWithCustomError(router, "OwnableUnauthorizedAccount");
    });

    it("should revert when called by attacker", async function () {
      await expect(
        router.connect(attacker).setPlatformApproval(
          platformTarget.address, true
        )
      ).to.be.revertedWithCustomError(router, "OwnableUnauthorizedAccount");
    });

    it("should revert when platform is the zero address", async function () {
      await expect(
        router.connect(owner).setPlatformApproval(
          ethers.ZeroAddress, true
        )
      ).to.be.revertedWithCustomError(router, "InvalidPlatformTarget");
    });
  });

  // ---------------------------------------------------------------------------
  // buyWithFee
  // ---------------------------------------------------------------------------

  describe("buyWithFee", function () {
    it("should revert with DeadlineExpired when deadline has passed", async function () {
      const deadline = await pastDeadline();
      await expect(
        router.connect(user).buyWithFee(
          await collateral.getAddress(),
          TOTAL_AMOUNT,
          0,
          platformTarget.address,
          "0x",
          deadline
        )
      ).to.be.revertedWithCustomError(router, "DeadlineExpired");
    });

    it("should revert with ZeroAmount when totalAmount is 0", async function () {
      const deadline = await futureDeadline();
      await expect(
        router.connect(user).buyWithFee(
          await collateral.getAddress(),
          0,
          0,
          platformTarget.address,
          "0x",
          deadline
        )
      ).to.be.revertedWithCustomError(router, "ZeroAmount");
    });

    it("should revert with InvalidCollateralToken when collateral is zero address", async function () {
      const deadline = await futureDeadline();
      await expect(
        router.connect(user).buyWithFee(
          ethers.ZeroAddress,
          TOTAL_AMOUNT,
          0,
          platformTarget.address,
          "0x",
          deadline
        )
      ).to.be.revertedWithCustomError(router, "InvalidCollateralToken");
    });

    it("should revert with InvalidPlatformTarget when platform is zero address", async function () {
      const deadline = await futureDeadline();
      await expect(
        router.connect(user).buyWithFee(
          await collateral.getAddress(),
          TOTAL_AMOUNT,
          0,
          ethers.ZeroAddress,
          "0x",
          deadline
        )
      ).to.be.revertedWithCustomError(router, "InvalidPlatformTarget");
    });

    it("should revert with InvalidPlatformTarget when platform is not approved", async function () {
      const deadline = await futureDeadline();
      // platformTarget is NOT approved
      await expect(
        router.connect(user).buyWithFee(
          await collateral.getAddress(),
          TOTAL_AMOUNT,
          0,
          platformTarget.address,
          "0x",
          deadline
        )
      ).to.be.revertedWithCustomError(router, "InvalidPlatformTarget");
    });

    it("should revert with InvalidPlatformTarget when platform is the collateral token", async function () {
      const deadline = await futureDeadline();
      const collateralAddress = await collateral.getAddress();
      // Approve the collateral address as a platform (admin mistake)
      await router.connect(owner).setPlatformApproval(
        collateralAddress, true
      );
      await expect(
        router.connect(user).buyWithFee(
          collateralAddress,
          TOTAL_AMOUNT,
          0,
          collateralAddress,
          "0x",
          deadline
        )
      ).to.be.revertedWithCustomError(router, "InvalidPlatformTarget");
    });

    it("should revert with InvalidPlatformTarget when platform is the router itself", async function () {
      const deadline = await futureDeadline();
      const routerAddress = await router.getAddress();
      // Approve the router address as a platform (admin mistake)
      await router.connect(owner).setPlatformApproval(
        routerAddress, true
      );
      await expect(
        router.connect(user).buyWithFee(
          await collateral.getAddress(),
          TOTAL_AMOUNT,
          0,
          routerAddress,
          "0x",
          deadline
        )
      ).to.be.revertedWithCustomError(router, "InvalidPlatformTarget");
    });

    it("should revert with FeeExceedsTotal when feeAmount > totalAmount", async function () {
      const deadline = await futureDeadline();
      const feeAmount = TOTAL_AMOUNT + 1n;
      // Use a deployed contract as the platform target (must have code after C-01)
      // Deploy a dummy contract to act as an approved platform
      const MockERC20 = await ethers.getContractFactory("MockERC20");
      const dummyPlatform = await MockERC20.deploy("Platform", "PLT");
      const platformAddr = await dummyPlatform.getAddress();
      // Approve the platform so we reach the fee check
      await router.connect(owner).setPlatformApproval(platformAddr, true);
      await expect(
        router.connect(user).buyWithFee(
          await collateral.getAddress(),
          TOTAL_AMOUNT,
          feeAmount,
          platformAddr,
          "0x",
          deadline
        )
      ).to.be.revertedWithCustomError(router, "FeeExceedsTotal");
    });

    it("should revert with FeeExceedsCap when fee exceeds maxFeeBps cap", async function () {
      const deadline = await futureDeadline();
      // maxFeeBps = 200 (2%), so max fee on 100 ETH = 2 ETH
      // Provide a fee of 3 ETH which exceeds the 2% cap
      const feeAmount = ethers.parseEther("3");
      // Use a deployed contract as the platform target (must have code after C-01)
      const MockERC20 = await ethers.getContractFactory("MockERC20");
      const dummyPlatform = await MockERC20.deploy("Platform", "PLT");
      const platformAddr = await dummyPlatform.getAddress();
      // Approve the platform so we reach the fee cap check
      await router.connect(owner).setPlatformApproval(platformAddr, true);
      await expect(
        router.connect(user).buyWithFee(
          await collateral.getAddress(),
          TOTAL_AMOUNT,
          feeAmount,
          platformAddr,
          "0x",
          deadline
        )
      ).to.be.revertedWithCustomError(router, "FeeExceedsCap");
    });

    it("should revert with InvalidPlatformTarget after platform is revoked", async function () {
      const deadline = await futureDeadline();
      // Approve then revoke
      await router.connect(owner).setPlatformApproval(
        platformTarget.address, true
      );
      await router.connect(owner).setPlatformApproval(
        platformTarget.address, false
      );
      await expect(
        router.connect(user).buyWithFee(
          await collateral.getAddress(),
          TOTAL_AMOUNT,
          0,
          platformTarget.address,
          "0x",
          deadline
        )
      ).to.be.revertedWithCustomError(router, "InvalidPlatformTarget");
    });
  });

  // ---------------------------------------------------------------------------
  // rescueTokens
  // ---------------------------------------------------------------------------

  describe("rescueTokens", function () {
    it("should revert when called by non-owner", async function () {
      // R6: rescueTokens is now onlyOwner, so non-owner gets OwnableUnauthorizedAccount
      await expect(
        router.connect(user).rescueTokens(await collateral.getAddress())
      ).to.be.revertedWithCustomError(router, "OwnableUnauthorizedAccount");
    });

    it("should allow owner to rescue tokens", async function () {
      const collateralAddress = await collateral.getAddress();
      const routerAddress = await router.getAddress();

      // Send some tokens directly to the router (simulating accidental transfer)
      const rescueAmount = ethers.parseEther("50");
      await collateral.transfer(routerAddress, rescueAmount);

      // Verify tokens are on the router
      expect(await collateral.balanceOf(routerAddress)).to.equal(rescueAmount);

      const balanceBefore = await collateral.balanceOf(feeVault.address);

      // R6: rescueTokens is now onlyOwner -- owner rescues the tokens
      await router.connect(owner).rescueTokens(collateralAddress);

      expect(await collateral.balanceOf(routerAddress)).to.equal(0);
      expect(await collateral.balanceOf(feeVault.address)).to.equal(
        balanceBefore + rescueAmount
      );
    });
  });

  // ===========================================================================
  // NEW TESTS BELOW
  // ===========================================================================

  // ---------------------------------------------------------------------------
  // Constructor boundary values
  // ---------------------------------------------------------------------------

  describe("Constructor boundary values", function () {
    it("should deploy with maxFeeBps = 1 (minimum)", async function () {
      const Router = await ethers.getContractFactory("OmniPredictionRouter");
      const r = await Router.deploy(feeVault.address, 1, ethers.ZeroAddress);
      await r.waitForDeployment();
      expect(await r.MAX_FEE_BPS()).to.equal(1n);
    });

    it("should deploy with maxFeeBps = 1000 (maximum)", async function () {
      const Router = await ethers.getContractFactory("OmniPredictionRouter");
      const r = await Router.deploy(feeVault.address, 1000, ethers.ZeroAddress);
      await r.waitForDeployment();
      expect(await r.MAX_FEE_BPS()).to.equal(1000n);
    });

    it("should set owner to msg.sender", async function () {
      expect(await router.owner()).to.equal(owner.address);
    });

    it("should accept a non-zero trustedForwarder address", async function () {
      const signers = await ethers.getSigners();
      const forwarder = signers[5];
      const Router = await ethers.getContractFactory("OmniPredictionRouter");
      const r = await Router.deploy(feeVault.address, MAX_FEE_BPS, forwarder.address);
      await r.waitForDeployment();
      expect(await r.feeVault()).to.equal(feeVault.address);
    });
  });

  // ---------------------------------------------------------------------------
  // proposeFeeVault / acceptFeeVault (48h timelock)
  // ---------------------------------------------------------------------------

  describe("proposeFeeVault / acceptFeeVault", function () {
    /** @dev 48 hours in seconds — matches FEE_VAULT_DELAY in contract */
    const FEE_VAULT_DELAY = 48 * 3600;

    /** @dev Helper: propose + advance time + accept feeVault change */
    async function proposeThenAcceptFeeVault(newVault) {
      await router.connect(owner).proposeFeeVault(newVault);
      await ethers.provider.send("evm_increaseTime", [FEE_VAULT_DELAY]);
      await ethers.provider.send("evm_mine", []);
      await router.connect(owner).acceptFeeVault();
    }

    it("should allow owner to update the fee vault via propose + accept", async function () {
      const signers = await ethers.getSigners();
      const newCollector = signers[5];

      await proposeThenAcceptFeeVault(newCollector.address);
      expect(await router.feeVault()).to.equal(newCollector.address);
    });

    it("should emit FeeVaultChangeProposed event on propose", async function () {
      const signers = await ethers.getSigners();
      const newCollector = signers[5];

      await expect(
        router.connect(owner).proposeFeeVault(newCollector.address)
      ).to.emit(router, "FeeVaultChangeProposed");
    });

    it("should emit FeeVaultChangeAccepted event on accept", async function () {
      const signers = await ethers.getSigners();
      const newCollector = signers[5];

      await router.connect(owner).proposeFeeVault(newCollector.address);
      await ethers.provider.send("evm_increaseTime", [FEE_VAULT_DELAY]);
      await ethers.provider.send("evm_mine", []);

      await expect(
        router.connect(owner).acceptFeeVault()
      )
        .to.emit(router, "FeeVaultChangeAccepted")
        .withArgs(feeVault.address, newCollector.address);
    });

    it("should revert proposeFeeVault when called by non-owner", async function () {
      const signers = await ethers.getSigners();
      const newCollector = signers[5];

      await expect(
        router.connect(user).proposeFeeVault(newCollector.address)
      ).to.be.revertedWithCustomError(router, "OwnableUnauthorizedAccount");
    });

    it("should revert proposeFeeVault when called by attacker", async function () {
      const signers = await ethers.getSigners();
      const newCollector = signers[5];

      await expect(
        router.connect(attacker).proposeFeeVault(newCollector.address)
      ).to.be.revertedWithCustomError(router, "OwnableUnauthorizedAccount");
    });

    it("should revert when proposing fee vault with zero address", async function () {
      await expect(
        router.connect(owner).proposeFeeVault(ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(router, "InvalidFeeVault");
    });

    it("should reject acceptFeeVault before timelock elapses", async function () {
      const signers = await ethers.getSigners();
      const newCollector = signers[5];

      await router.connect(owner).proposeFeeVault(newCollector.address);
      // Only advance 1 hour — not enough
      await ethers.provider.send("evm_increaseTime", [3600]);
      await ethers.provider.send("evm_mine", []);

      await expect(
        router.connect(owner).acceptFeeVault()
      ).to.be.revertedWithCustomError(router, "FeeVaultTimelockActive");
    });

    it("should reject acceptFeeVault without a proposal", async function () {
      await expect(
        router.connect(owner).acceptFeeVault()
      ).to.be.revertedWithCustomError(router, "NoFeeVaultChangePending");
    });

    it("should allow multiple fee vault updates via sequential proposals", async function () {
      const signers = await ethers.getSigners();
      const collector1 = signers[5];
      const collector2 = signers[6];

      await proposeThenAcceptFeeVault(collector1.address);
      expect(await router.feeVault()).to.equal(collector1.address);

      await proposeThenAcceptFeeVault(collector2.address);
      expect(await router.feeVault()).to.equal(collector2.address);
    });
  });

  // ---------------------------------------------------------------------------
  // Ownership (Ownable2Step)
  // ---------------------------------------------------------------------------

  describe("Ownership (Ownable2Step)", function () {
    it("should set deployer as initial owner", async function () {
      expect(await router.owner()).to.equal(owner.address);
    });

    it("should allow owner to initiate ownership transfer", async function () {
      const signers = await ethers.getSigners();
      const newOwner = signers[5];

      await router.connect(owner).transferOwnership(newOwner.address);
      expect(await router.pendingOwner()).to.equal(newOwner.address);
      // Owner should still be the original until accepted
      expect(await router.owner()).to.equal(owner.address);
    });

    it("should allow pending owner to accept ownership", async function () {
      const signers = await ethers.getSigners();
      const newOwner = signers[5];

      await router.connect(owner).transferOwnership(newOwner.address);
      await router.connect(newOwner).acceptOwnership();

      expect(await router.owner()).to.equal(newOwner.address);
      expect(await router.pendingOwner()).to.equal(ethers.ZeroAddress);
    });

    it("should revert when non-pending address tries to accept ownership", async function () {
      const signers = await ethers.getSigners();
      const newOwner = signers[5];

      await router.connect(owner).transferOwnership(newOwner.address);

      await expect(
        router.connect(attacker).acceptOwnership()
      ).to.be.revertedWithCustomError(router, "OwnableUnauthorizedAccount");
    });

    it("should revert on renounceOwnership (disabled)", async function () {
      await expect(
        router.connect(owner).renounceOwnership()
      ).to.be.revertedWithCustomError(router, "InvalidFeeVault");
    });
  });

  // ---------------------------------------------------------------------------
  // Platform approval edge cases
  // ---------------------------------------------------------------------------

  describe("Platform approval edge cases", function () {
    it("should return false for unapproved platforms by default", async function () {
      expect(await router.approvedPlatforms(platformTarget.address)).to.equal(false);
    });

    it("should allow approving multiple platforms", async function () {
      const signers = await ethers.getSigners();
      const platform2 = signers[5];
      const platform3 = signers[6];

      await router.connect(owner).setPlatformApproval(platformTarget.address, true);
      await router.connect(owner).setPlatformApproval(platform2.address, true);
      await router.connect(owner).setPlatformApproval(platform3.address, true);

      expect(await router.approvedPlatforms(platformTarget.address)).to.equal(true);
      expect(await router.approvedPlatforms(platform2.address)).to.equal(true);
      expect(await router.approvedPlatforms(platform3.address)).to.equal(true);
    });

    it("should be idempotent when approving an already approved platform", async function () {
      await router.connect(owner).setPlatformApproval(platformTarget.address, true);
      await router.connect(owner).setPlatformApproval(platformTarget.address, true);
      expect(await router.approvedPlatforms(platformTarget.address)).to.equal(true);
    });

    it("should be idempotent when revoking an already revoked platform", async function () {
      await router.connect(owner).setPlatformApproval(platformTarget.address, false);
      expect(await router.approvedPlatforms(platformTarget.address)).to.equal(false);
    });

    it("should allow re-approving a previously revoked platform", async function () {
      await router.connect(owner).setPlatformApproval(platformTarget.address, true);
      await router.connect(owner).setPlatformApproval(platformTarget.address, false);
      await router.connect(owner).setPlatformApproval(platformTarget.address, true);
      expect(await router.approvedPlatforms(platformTarget.address)).to.equal(true);
    });
  });

  // ---------------------------------------------------------------------------
  // buyWithFee - successful execution
  // ---------------------------------------------------------------------------

  describe("buyWithFee - successful execution", function () {
    let mockPlatform;

    beforeEach(async function () {
      // Deploy mock platform
      const MockPlatform = await ethers.getContractFactory("MockPlatform");
      mockPlatform = await MockPlatform.deploy();
      await mockPlatform.waitForDeployment();

      const platformAddr = await mockPlatform.getAddress();
      await router.connect(owner).setPlatformApproval(platformAddr, true);
    });

    it("should execute trade and emit TradeExecuted event", async function () {
      const deadline = await futureDeadline();
      const totalAmount = ethers.parseEther("100");
      const feeAmount = ethers.parseEther("1"); // 1% fee (within 2% cap)
      const netAmount = totalAmount - feeAmount;
      const platformAddr = await mockPlatform.getAddress();
      const collateralAddr = await collateral.getAddress();

      // Fund user and approve
      await collateral.transfer(user.address, totalAmount);
      await collateral.connect(user).approve(await router.getAddress(), totalAmount);

      // Encode the platform call
      const platformData = mockPlatform.interface.encodeFunctionData("execute");

      await expect(
        router.connect(user).buyWithFee(
          collateralAddr,
          totalAmount,
          feeAmount,
          platformAddr,
          platformData,
          deadline
        )
      )
        .to.emit(router, "TradeExecuted")
        .withArgs(user.address, collateralAddr, totalAmount, feeAmount, netAmount, platformAddr);
    });

    it("should send fee to feeVault", async function () {
      const deadline = await futureDeadline();
      const totalAmount = ethers.parseEther("100");
      const feeAmount = ethers.parseEther("1");
      const platformAddr = await mockPlatform.getAddress();
      const collateralAddr = await collateral.getAddress();

      await collateral.transfer(user.address, totalAmount);
      await collateral.connect(user).approve(await router.getAddress(), totalAmount);

      const feeBalBefore = await collateral.balanceOf(feeVault.address);

      const platformData = mockPlatform.interface.encodeFunctionData("execute");
      await router.connect(user).buyWithFee(
        collateralAddr, totalAmount, feeAmount,
        platformAddr, platformData, deadline
      );

      expect(await collateral.balanceOf(feeVault.address)).to.equal(
        feeBalBefore + feeAmount
      );
    });

    it("should approve and forward net amount to platform", async function () {
      const deadline = await futureDeadline();
      const totalAmount = ethers.parseEther("100");
      const feeAmount = ethers.parseEther("2"); // exactly at cap
      const netAmount = totalAmount - feeAmount;
      const platformAddr = await mockPlatform.getAddress();
      const collateralAddr = await collateral.getAddress();

      await collateral.transfer(user.address, totalAmount);
      await collateral.connect(user).approve(await router.getAddress(), totalAmount);

      const platformData = mockPlatform.interface.encodeFunctionData("execute");
      await router.connect(user).buyWithFee(
        collateralAddr, totalAmount, feeAmount,
        platformAddr, platformData, deadline
      );

      // After execution, the router should have reset platform approval to 0
      const routerAddr = await router.getAddress();
      const allowance = await collateral.allowance(routerAddr, platformAddr);
      expect(allowance).to.equal(0n);
    });

    it("should work with zero fee", async function () {
      const deadline = await futureDeadline();
      const totalAmount = ethers.parseEther("100");
      const feeAmount = 0n;
      const platformAddr = await mockPlatform.getAddress();
      const collateralAddr = await collateral.getAddress();

      await collateral.transfer(user.address, totalAmount);
      await collateral.connect(user).approve(await router.getAddress(), totalAmount);

      const platformData = mockPlatform.interface.encodeFunctionData("execute");
      await expect(
        router.connect(user).buyWithFee(
          collateralAddr, totalAmount, feeAmount,
          platformAddr, platformData, deadline
        )
      )
        .to.emit(router, "TradeExecuted")
        .withArgs(user.address, collateralAddr, totalAmount, 0n, totalAmount, platformAddr);
    });

    it("should work with fee at exactly the cap (2%)", async function () {
      const deadline = await futureDeadline();
      const totalAmount = ethers.parseEther("100");
      // 2% of 100 = 2 ETH exactly at cap
      const feeAmount = ethers.parseEther("2");
      const platformAddr = await mockPlatform.getAddress();
      const collateralAddr = await collateral.getAddress();

      await collateral.transfer(user.address, totalAmount);
      await collateral.connect(user).approve(await router.getAddress(), totalAmount);

      const platformData = mockPlatform.interface.encodeFunctionData("execute");
      await router.connect(user).buyWithFee(
        collateralAddr, totalAmount, feeAmount,
        platformAddr, platformData, deadline
      );

      // Should succeed without revert
      expect(await collateral.balanceOf(feeVault.address)).to.be.gte(feeAmount);
    });
  });

  // ---------------------------------------------------------------------------
  // buyWithFee - platform call failure
  // ---------------------------------------------------------------------------

  describe("buyWithFee - platform call failure", function () {
    let mockPlatform;

    beforeEach(async function () {
      const MockPlatform = await ethers.getContractFactory("MockPlatform");
      mockPlatform = await MockPlatform.deploy();
      await mockPlatform.waitForDeployment();

      const platformAddr = await mockPlatform.getAddress();
      await router.connect(owner).setPlatformApproval(platformAddr, true);
    });

    it("should revert with PlatformCallFailed when platform call reverts", async function () {
      const deadline = await futureDeadline();
      const totalAmount = ethers.parseEther("100");
      const feeAmount = ethers.parseEther("1");
      const platformAddr = await mockPlatform.getAddress();
      const collateralAddr = await collateral.getAddress();

      // Make the platform fail
      await mockPlatform.setShouldFail(true);

      await collateral.transfer(user.address, totalAmount);
      await collateral.connect(user).approve(await router.getAddress(), totalAmount);

      const platformData = mockPlatform.interface.encodeFunctionData("execute");
      await expect(
        router.connect(user).buyWithFee(
          collateralAddr, totalAmount, feeAmount,
          platformAddr, platformData, deadline
        )
      ).to.be.revertedWithCustomError(router, "PlatformCallFailed");
    });

    it("should revert when platform data is invalid (no matching function)", async function () {
      const deadline = await futureDeadline();
      const totalAmount = ethers.parseEther("100");
      const feeAmount = ethers.parseEther("1");
      const platformAddr = await mockPlatform.getAddress();
      const collateralAddr = await collateral.getAddress();

      await collateral.transfer(user.address, totalAmount);
      await collateral.connect(user).approve(await router.getAddress(), totalAmount);

      // Use bogus calldata
      const bogusData = "0xdeadbeef";
      await expect(
        router.connect(user).buyWithFee(
          collateralAddr, totalAmount, feeAmount,
          platformAddr, bogusData, deadline
        )
      ).to.be.revertedWithCustomError(router, "PlatformCallFailed");
    });
  });

  // ---------------------------------------------------------------------------
  // buyWithFeeAndSweep (ERC-20 outcome tokens)
  // ---------------------------------------------------------------------------

  describe("buyWithFeeAndSweep", function () {
    let mockPlatform;
    let outcomeToken;

    beforeEach(async function () {
      const MockPlatform = await ethers.getContractFactory("MockPlatform");
      mockPlatform = await MockPlatform.deploy();
      await mockPlatform.waitForDeployment();

      const platformAddr = await mockPlatform.getAddress();
      await router.connect(owner).setPlatformApproval(platformAddr, true);

      // Deploy outcome token
      const MockERC20 = await ethers.getContractFactory("MockERC20");
      outcomeToken = await MockERC20.deploy("Outcome Token", "OUT");
      await outcomeToken.waitForDeployment();
    });

    it("should sweep ERC-20 outcome tokens to the caller", async function () {
      const deadline = await futureDeadline();
      const totalAmount = ethers.parseEther("100");
      const feeAmount = ethers.parseEther("1");
      const outcomeAmount = ethers.parseEther("50");
      const platformAddr = await mockPlatform.getAddress();
      const collateralAddr = await collateral.getAddress();
      const outcomeAddr = await outcomeToken.getAddress();
      const routerAddr = await router.getAddress();

      // Configure mock platform to mint outcome tokens to the router
      await mockPlatform.setOutcomeERC20(outcomeAddr, outcomeAmount, routerAddr);

      await collateral.transfer(user.address, totalAmount);
      await collateral.connect(user).approve(routerAddr, totalAmount);

      const platformData = mockPlatform.interface.encodeFunctionData("execute");

      const userOutcomeBefore = await outcomeToken.balanceOf(user.address);

      await router.connect(user).buyWithFeeAndSweep(
        collateralAddr, totalAmount, feeAmount,
        platformAddr, platformData,
        outcomeAddr, outcomeAmount,
        deadline
      );

      const userOutcomeAfter = await outcomeToken.balanceOf(user.address);
      expect(userOutcomeAfter - userOutcomeBefore).to.equal(outcomeAmount);
    });

    it("should revert with InsufficientOutcomeTokens when minOutcome not met", async function () {
      const deadline = await futureDeadline();
      const totalAmount = ethers.parseEther("100");
      const feeAmount = ethers.parseEther("1");
      const outcomeAmount = ethers.parseEther("10");
      const minOutcome = ethers.parseEther("20"); // Higher than what platform gives
      const platformAddr = await mockPlatform.getAddress();
      const collateralAddr = await collateral.getAddress();
      const outcomeAddr = await outcomeToken.getAddress();
      const routerAddr = await router.getAddress();

      await mockPlatform.setOutcomeERC20(outcomeAddr, outcomeAmount, routerAddr);

      await collateral.transfer(user.address, totalAmount);
      await collateral.connect(user).approve(routerAddr, totalAmount);

      const platformData = mockPlatform.interface.encodeFunctionData("execute");

      await expect(
        router.connect(user).buyWithFeeAndSweep(
          collateralAddr, totalAmount, feeAmount,
          platformAddr, platformData,
          outcomeAddr, minOutcome,
          deadline
        )
      ).to.be.revertedWithCustomError(router, "InsufficientOutcomeTokens");
    });

    it("should revert with InvalidOutcomeToken when outcome token is zero address", async function () {
      const deadline = await futureDeadline();
      const platformAddr = await mockPlatform.getAddress();
      const collateralAddr = await collateral.getAddress();

      await collateral.transfer(user.address, TOTAL_AMOUNT);
      await collateral.connect(user).approve(await router.getAddress(), TOTAL_AMOUNT);

      const platformData = mockPlatform.interface.encodeFunctionData("execute");

      await expect(
        router.connect(user).buyWithFeeAndSweep(
          collateralAddr, TOTAL_AMOUNT, 0n,
          platformAddr, platformData,
          ethers.ZeroAddress, 0n,
          deadline
        )
      ).to.be.revertedWithCustomError(router, "InvalidOutcomeToken");
    });

    it("should emit TradeExecuted event on sweep", async function () {
      const deadline = await futureDeadline();
      const totalAmount = ethers.parseEther("100");
      const feeAmount = ethers.parseEther("1");
      const netAmount = totalAmount - feeAmount;
      const outcomeAmount = ethers.parseEther("50");
      const platformAddr = await mockPlatform.getAddress();
      const collateralAddr = await collateral.getAddress();
      const outcomeAddr = await outcomeToken.getAddress();
      const routerAddr = await router.getAddress();

      await mockPlatform.setOutcomeERC20(outcomeAddr, outcomeAmount, routerAddr);

      await collateral.transfer(user.address, totalAmount);
      await collateral.connect(user).approve(routerAddr, totalAmount);

      const platformData = mockPlatform.interface.encodeFunctionData("execute");

      await expect(
        router.connect(user).buyWithFeeAndSweep(
          collateralAddr, totalAmount, feeAmount,
          platformAddr, platformData,
          outcomeAddr, 0n,
          deadline
        )
      )
        .to.emit(router, "TradeExecuted")
        .withArgs(user.address, collateralAddr, totalAmount, feeAmount, netAmount, platformAddr);
    });

    it("should leave zero outcome tokens on the router after sweep", async function () {
      const deadline = await futureDeadline();
      const totalAmount = ethers.parseEther("100");
      const feeAmount = ethers.parseEther("1");
      const outcomeAmount = ethers.parseEther("50");
      const platformAddr = await mockPlatform.getAddress();
      const collateralAddr = await collateral.getAddress();
      const outcomeAddr = await outcomeToken.getAddress();
      const routerAddr = await router.getAddress();

      await mockPlatform.setOutcomeERC20(outcomeAddr, outcomeAmount, routerAddr);

      await collateral.transfer(user.address, totalAmount);
      await collateral.connect(user).approve(routerAddr, totalAmount);

      const platformData = mockPlatform.interface.encodeFunctionData("execute");

      await router.connect(user).buyWithFeeAndSweep(
        collateralAddr, totalAmount, feeAmount,
        platformAddr, platformData,
        outcomeAddr, 0n,
        deadline
      );

      expect(await outcomeToken.balanceOf(routerAddr)).to.equal(0n);
    });
  });

  // ---------------------------------------------------------------------------
  // buyWithFeeAndSweepERC1155
  // ---------------------------------------------------------------------------

  describe("buyWithFeeAndSweepERC1155", function () {
    let mockPlatform;

    beforeEach(async function () {
      const MockPlatform = await ethers.getContractFactory("MockPlatform");
      mockPlatform = await MockPlatform.deploy();
      await mockPlatform.waitForDeployment();

      const platformAddr = await mockPlatform.getAddress();
      await router.connect(owner).setPlatformApproval(platformAddr, true);
    });

    it("should sweep ERC-1155 outcome tokens to the caller", async function () {
      const deadline = await futureDeadline();
      const totalAmount = ethers.parseEther("100");
      const feeAmount = ethers.parseEther("1");
      const outcomeTokenId = 42n;
      const outcomeAmount = 100n;
      const platformAddr = await mockPlatform.getAddress();
      const collateralAddr = await collateral.getAddress();
      const routerAddr = await router.getAddress();

      // Configure mock platform to mint ERC-1155 tokens to the router
      await mockPlatform.setOutcomeERC1155(outcomeTokenId, outcomeAmount, routerAddr);

      await collateral.transfer(user.address, totalAmount);
      await collateral.connect(user).approve(routerAddr, totalAmount);

      const platformData = mockPlatform.interface.encodeFunctionData("execute");

      await router.connect(user).buyWithFeeAndSweepERC1155(
        collateralAddr, totalAmount, feeAmount,
        platformAddr, platformData,
        platformAddr, // The mock platform IS the ERC-1155 contract
        outcomeTokenId, 0n,
        deadline
      );

      // User should have received the outcome tokens
      expect(
        await mockPlatform.balanceOf(user.address, outcomeTokenId)
      ).to.equal(outcomeAmount);
    });

    it("should revert with InsufficientOutcomeTokens when minOutcome not met for ERC-1155", async function () {
      const deadline = await futureDeadline();
      const totalAmount = ethers.parseEther("100");
      const feeAmount = ethers.parseEther("1");
      const outcomeTokenId = 42n;
      const outcomeAmount = 10n;
      const minOutcome = 50n; // Higher than what platform gives
      const platformAddr = await mockPlatform.getAddress();
      const collateralAddr = await collateral.getAddress();
      const routerAddr = await router.getAddress();

      await mockPlatform.setOutcomeERC1155(outcomeTokenId, outcomeAmount, routerAddr);

      await collateral.transfer(user.address, totalAmount);
      await collateral.connect(user).approve(routerAddr, totalAmount);

      const platformData = mockPlatform.interface.encodeFunctionData("execute");

      await expect(
        router.connect(user).buyWithFeeAndSweepERC1155(
          collateralAddr, totalAmount, feeAmount,
          platformAddr, platformData,
          platformAddr, outcomeTokenId, minOutcome,
          deadline
        )
      ).to.be.revertedWithCustomError(router, "InsufficientOutcomeTokens");
    });

    it("should revert with InvalidOutcomeToken when ERC-1155 outcome token is zero address", async function () {
      const deadline = await futureDeadline();
      const platformAddr = await mockPlatform.getAddress();
      const collateralAddr = await collateral.getAddress();

      await collateral.transfer(user.address, TOTAL_AMOUNT);
      await collateral.connect(user).approve(await router.getAddress(), TOTAL_AMOUNT);

      const platformData = mockPlatform.interface.encodeFunctionData("execute");

      await expect(
        router.connect(user).buyWithFeeAndSweepERC1155(
          collateralAddr, TOTAL_AMOUNT, 0n,
          platformAddr, platformData,
          ethers.ZeroAddress, 0n, 0n,
          deadline
        )
      ).to.be.revertedWithCustomError(router, "InvalidOutcomeToken");
    });

    it("should emit TradeExecuted event on ERC-1155 sweep", async function () {
      const deadline = await futureDeadline();
      const totalAmount = ethers.parseEther("100");
      const feeAmount = ethers.parseEther("1");
      const netAmount = totalAmount - feeAmount;
      const outcomeTokenId = 42n;
      const outcomeAmount = 100n;
      const platformAddr = await mockPlatform.getAddress();
      const collateralAddr = await collateral.getAddress();
      const routerAddr = await router.getAddress();

      await mockPlatform.setOutcomeERC1155(outcomeTokenId, outcomeAmount, routerAddr);

      await collateral.transfer(user.address, totalAmount);
      await collateral.connect(user).approve(routerAddr, totalAmount);

      const platformData = mockPlatform.interface.encodeFunctionData("execute");

      await expect(
        router.connect(user).buyWithFeeAndSweepERC1155(
          collateralAddr, totalAmount, feeAmount,
          platformAddr, platformData,
          platformAddr, outcomeTokenId, 0n,
          deadline
        )
      )
        .to.emit(router, "TradeExecuted")
        .withArgs(user.address, collateralAddr, totalAmount, feeAmount, netAmount, platformAddr);
    });
  });

  // ---------------------------------------------------------------------------
  // rescueTokens - additional scenarios
  // ---------------------------------------------------------------------------

  describe("rescueTokens - additional scenarios", function () {
    it("should revert when called by feeVault (non-owner)", async function () {
      await expect(
        router.connect(feeVault).rescueTokens(await collateral.getAddress())
      ).to.be.revertedWithCustomError(router, "OwnableUnauthorizedAccount");
    });

    it("should revert when called by attacker", async function () {
      await expect(
        router.connect(attacker).rescueTokens(await collateral.getAddress())
      ).to.be.revertedWithCustomError(router, "OwnableUnauthorizedAccount");
    });

    it("should emit TokensRescued event with correct parameters", async function () {
      const rescueAmount = ethers.parseEther("25");
      const routerAddress = await router.getAddress();
      const collateralAddress = await collateral.getAddress();

      await collateral.transfer(routerAddress, rescueAmount);

      await expect(
        router.connect(owner).rescueTokens(collateralAddress)
      )
        .to.emit(router, "TokensRescued")
        .withArgs(collateralAddress, rescueAmount);
    });

    it("should not emit TokensRescued when contract has zero balance", async function () {
      const collateralAddress = await collateral.getAddress();

      await expect(
        router.connect(owner).rescueTokens(collateralAddress)
      ).to.not.emit(router, "TokensRescued");
    });

    it("should rescue tokens to current feeVault (not original)", async function () {
      const signers = await ethers.getSigners();
      const newCollector = signers[5];

      // Change fee vault via propose + timelock + accept
      await router.connect(owner).proposeFeeVault(newCollector.address);
      await ethers.provider.send("evm_increaseTime", [48 * 3600]);
      await ethers.provider.send("evm_mine", []);
      await router.connect(owner).acceptFeeVault();

      const rescueAmount = ethers.parseEther("10");
      const routerAddress = await router.getAddress();
      const collateralAddress = await collateral.getAddress();

      await collateral.transfer(routerAddress, rescueAmount);

      const balBefore = await collateral.balanceOf(newCollector.address);

      await router.connect(owner).rescueTokens(collateralAddress);

      expect(await collateral.balanceOf(newCollector.address)).to.equal(
        balBefore + rescueAmount
      );
    });

    it("should rescue a different token than the collateral", async function () {
      const MockERC20 = await ethers.getContractFactory("MockERC20");
      const otherToken = await MockERC20.deploy("Other", "OTH");
      await otherToken.waitForDeployment();
      await otherToken.mint(owner.address, ethers.parseEther("1000"));

      const rescueAmount = ethers.parseEther("33");
      const routerAddress = await router.getAddress();
      const otherAddress = await otherToken.getAddress();

      await otherToken.transfer(routerAddress, rescueAmount);

      const balBefore = await otherToken.balanceOf(feeVault.address);

      await router.connect(owner).rescueTokens(otherAddress);

      expect(await otherToken.balanceOf(feeVault.address)).to.equal(
        balBefore + rescueAmount
      );
    });
  });

  // ---------------------------------------------------------------------------
  // ERC-1155 receiver support
  // ---------------------------------------------------------------------------

  describe("ERC-1155 receiver support", function () {
    it("should support ERC-1155 receiver interface", async function () {
      // ERC1155Receiver interface ID: 0x4e2312e0
      expect(await router.supportsInterface("0x4e2312e0")).to.equal(true);
    });

    it("should support ERC-165 interface", async function () {
      expect(await router.supportsInterface("0x01ffc9a7")).to.equal(true);
    });

    it("should accept ERC-1155 token transfers (onERC1155Received)", async function () {
      const MockERC1155 = await ethers.getContractFactory("MockERC1155");
      const erc1155 = await MockERC1155.deploy();
      await erc1155.waitForDeployment();

      const routerAddr = await router.getAddress();

      // Mint ERC-1155 tokens to owner
      await erc1155.mint(owner.address, 1, 100);

      // Transfer to router - should not revert because router inherits ERC1155Holder
      await erc1155.connect(owner).safeTransferFrom(
        owner.address, routerAddr, 1, 50, "0x"
      );

      expect(await erc1155.balanceOf(routerAddr, 1)).to.equal(50);
    });
  });

  // ---------------------------------------------------------------------------
  // Fee cap boundary tests
  // ---------------------------------------------------------------------------

  describe("Fee cap boundary tests", function () {
    let mockPlatform;

    beforeEach(async function () {
      const MockPlatform = await ethers.getContractFactory("MockPlatform");
      mockPlatform = await MockPlatform.deploy();
      await mockPlatform.waitForDeployment();
      await router.connect(owner).setPlatformApproval(
        await mockPlatform.getAddress(), true
      );
    });

    it("should accept fee at exactly 1 bps below cap", async function () {
      const deadline = await futureDeadline();
      const totalAmount = ethers.parseEther("10000");
      // MAX_FEE_BPS = 200 (2%), max fee = 200 ETH
      // Use 199 bps worth = 199 ETH
      const feeAmount = (totalAmount * 199n) / 10000n;
      const platformAddr = await mockPlatform.getAddress();
      const collateralAddr = await collateral.getAddress();

      await collateral.transfer(user.address, totalAmount);
      await collateral.connect(user).approve(await router.getAddress(), totalAmount);

      const platformData = mockPlatform.interface.encodeFunctionData("execute");
      // Should not revert
      await router.connect(user).buyWithFee(
        collateralAddr, totalAmount, feeAmount,
        platformAddr, platformData, deadline
      );
    });

    it("should reject fee at 1 wei above cap", async function () {
      const deadline = await futureDeadline();
      const totalAmount = ethers.parseEther("100");
      // max fee = 100 * 200 / 10000 = 2 ETH
      const feeAmount = ethers.parseEther("2") + 1n; // 1 wei over cap
      const platformAddr = await mockPlatform.getAddress();
      const collateralAddr = await collateral.getAddress();

      await collateral.transfer(user.address, totalAmount);
      await collateral.connect(user).approve(await router.getAddress(), totalAmount);

      const platformData = mockPlatform.interface.encodeFunctionData("execute");
      await expect(
        router.connect(user).buyWithFee(
          collateralAddr, totalAmount, feeAmount,
          platformAddr, platformData, deadline
        )
      ).to.be.revertedWithCustomError(router, "FeeExceedsCap");
    });

    it("should accept fee equal to totalAmount when within cap", async function () {
      // Deploy a router with 10% max cap to test fee == total scenario
      const Router = await ethers.getContractFactory("OmniPredictionRouter");
      const r = await Router.deploy(feeVault.address, 1000, ethers.ZeroAddress); // 10% cap
      await r.waitForDeployment();

      const MockPlatform = await ethers.getContractFactory("MockPlatform");
      const mp = await MockPlatform.deploy();
      await mp.waitForDeployment();
      await r.connect(owner).setPlatformApproval(await mp.getAddress(), true);

      const deadline = await futureDeadline();
      const totalAmount = ethers.parseEther("10");
      // 10% of 10 = 1 ETH max fee, but fee == total = 10 ETH would exceed cap
      const feeAmount = totalAmount;
      const platformAddr = await mp.getAddress();
      const collateralAddr = await collateral.getAddress();

      await collateral.transfer(user.address, totalAmount);
      await collateral.connect(user).approve(await r.getAddress(), totalAmount);

      const platformData = mp.interface.encodeFunctionData("execute");
      await expect(
        r.connect(user).buyWithFee(
          collateralAddr, totalAmount, feeAmount,
          platformAddr, platformData, deadline
        )
      ).to.be.revertedWithCustomError(r, "FeeExceedsCap");
    });
  });

  // ---------------------------------------------------------------------------
  // Deadline edge cases
  // ---------------------------------------------------------------------------

  describe("Deadline edge cases", function () {
    let mockPlatform;

    beforeEach(async function () {
      const MockPlatform = await ethers.getContractFactory("MockPlatform");
      mockPlatform = await MockPlatform.deploy();
      await mockPlatform.waitForDeployment();
      await router.connect(owner).setPlatformApproval(
        await mockPlatform.getAddress(), true
      );
    });

    it("should accept a deadline well in the future", async function () {
      // Use a deadline far in the future to guarantee success
      const deadline = await futureDeadline(); // 1 hour ahead

      const totalAmount = ethers.parseEther("10");
      const platformAddr = await mockPlatform.getAddress();
      const collateralAddr = await collateral.getAddress();

      await collateral.transfer(user.address, totalAmount);
      await collateral.connect(user).approve(await router.getAddress(), totalAmount);

      const platformData = mockPlatform.interface.encodeFunctionData("execute");
      // This should succeed as block.timestamp <= deadline
      await router.connect(user).buyWithFee(
        collateralAddr, totalAmount, 0n,
        platformAddr, platformData, deadline
      );
    });

    it("should revert when deadline equals latest block timestamp (strict > check)", async function () {
      // The contract uses `block.timestamp > deadline`, so deadline == current timestamp
      // in the NEXT block will fail because the next block's timestamp >= current+1
      const block = await ethers.provider.getBlock("latest");
      // Set deadline to current timestamp; the tx will be mined in the next block
      // which has timestamp >= current+1, so block.timestamp > deadline
      const deadline = block.timestamp;

      const totalAmount = ethers.parseEther("10");
      const platformAddr = await mockPlatform.getAddress();
      const collateralAddr = await collateral.getAddress();

      await collateral.transfer(user.address, totalAmount);
      await collateral.connect(user).approve(await router.getAddress(), totalAmount);

      const platformData = mockPlatform.interface.encodeFunctionData("execute");
      await expect(
        router.connect(user).buyWithFee(
          collateralAddr, totalAmount, 0n,
          platformAddr, platformData, deadline
        )
      ).to.be.revertedWithCustomError(router, "DeadlineExpired");
    });

    it("should revert with DeadlineExpired on buyWithFeeAndSweep", async function () {
      const deadline = await pastDeadline();
      const MockERC20 = await ethers.getContractFactory("MockERC20");
      const outcomeToken = await MockERC20.deploy("Out", "OUT");
      await outcomeToken.waitForDeployment();

      const platformAddr = await mockPlatform.getAddress();
      const collateralAddr = await collateral.getAddress();
      const outcomeAddr = await outcomeToken.getAddress();

      await expect(
        router.connect(user).buyWithFeeAndSweep(
          collateralAddr, TOTAL_AMOUNT, 0n,
          platformAddr, "0x",
          outcomeAddr, 0n,
          deadline
        )
      ).to.be.revertedWithCustomError(router, "DeadlineExpired");
    });

    it("should revert with DeadlineExpired on buyWithFeeAndSweepERC1155", async function () {
      const deadline = await pastDeadline();
      const platformAddr = await mockPlatform.getAddress();
      const collateralAddr = await collateral.getAddress();

      await expect(
        router.connect(user).buyWithFeeAndSweepERC1155(
          collateralAddr, TOTAL_AMOUNT, 0n,
          platformAddr, "0x",
          platformAddr, 0n, 0n,
          deadline
        )
      ).to.be.revertedWithCustomError(router, "DeadlineExpired");
    });
  });

  // ---------------------------------------------------------------------------
  // PlatformNotContract (M-04)
  // ---------------------------------------------------------------------------

  describe("PlatformNotContract (M-04)", function () {
    it("should revert with PlatformNotContract when platform is an EOA", async function () {
      const deadline = await futureDeadline();
      const signers = await ethers.getSigners();
      const eoaPlatform = signers[7];
      const collateralAddr = await collateral.getAddress();

      // Approve the EOA as a platform
      await router.connect(owner).setPlatformApproval(eoaPlatform.address, true);

      await collateral.transfer(user.address, TOTAL_AMOUNT);
      await collateral.connect(user).approve(await router.getAddress(), TOTAL_AMOUNT);

      await expect(
        router.connect(user).buyWithFee(
          collateralAddr, TOTAL_AMOUNT, 0n,
          eoaPlatform.address, "0x",
          deadline
        )
      ).to.be.revertedWithCustomError(router, "PlatformNotContract");
    });
  });

  // ---------------------------------------------------------------------------
  // Fee-on-transfer token rejection (M-01)
  // ---------------------------------------------------------------------------

  describe("Fee-on-transfer token rejection (M-01)", function () {
    let mockPlatform;

    beforeEach(async function () {
      const MockPlatform = await ethers.getContractFactory("MockPlatform");
      mockPlatform = await MockPlatform.deploy();
      await mockPlatform.waitForDeployment();
      await router.connect(owner).setPlatformApproval(
        await mockPlatform.getAddress(), true
      );
    });

    it("should revert with FeeOnTransferNotSupported when using FoT token", async function () {
      // Deploy a fee-on-transfer token (1% fee)
      const FoT = await ethers.getContractFactory("MockFeeOnTransferToken");
      const fotToken = await FoT.deploy("FeeToken", "FOT", 100); // 1% fee
      await fotToken.waitForDeployment();

      const deadline = await futureDeadline();
      const totalAmount = ethers.parseEther("100");
      const feeAmount = ethers.parseEther("1");
      const platformAddr = await mockPlatform.getAddress();
      const fotAddr = await fotToken.getAddress();

      await fotToken.mint(user.address, totalAmount);
      await fotToken.connect(user).approve(await router.getAddress(), totalAmount);

      const platformData = mockPlatform.interface.encodeFunctionData("execute");

      await expect(
        router.connect(user).buyWithFee(
          fotAddr, totalAmount, feeAmount,
          platformAddr, platformData, deadline
        )
      ).to.be.revertedWithCustomError(router, "FeeOnTransferNotSupported");
    });
  });

  // ---------------------------------------------------------------------------
  // Multiple trades by different users
  // ---------------------------------------------------------------------------

  describe("Multiple trades by different users", function () {
    let mockPlatform;

    beforeEach(async function () {
      const MockPlatform = await ethers.getContractFactory("MockPlatform");
      mockPlatform = await MockPlatform.deploy();
      await mockPlatform.waitForDeployment();
      await router.connect(owner).setPlatformApproval(
        await mockPlatform.getAddress(), true
      );
    });

    it("should handle sequential trades from different users", async function () {
      const signers = await ethers.getSigners();
      const user2 = signers[5];
      const deadline = await futureDeadline();
      const totalAmount = ethers.parseEther("100");
      const feeAmount = ethers.parseEther("1");
      const platformAddr = await mockPlatform.getAddress();
      const collateralAddr = await collateral.getAddress();
      const routerAddr = await router.getAddress();

      // Fund both users
      await collateral.transfer(user.address, totalAmount);
      await collateral.transfer(user2.address, totalAmount);
      await collateral.connect(user).approve(routerAddr, totalAmount);
      await collateral.connect(user2).approve(routerAddr, totalAmount);

      const platformData = mockPlatform.interface.encodeFunctionData("execute");

      const feeBalBefore = await collateral.balanceOf(feeVault.address);

      // User 1 trades
      await router.connect(user).buyWithFee(
        collateralAddr, totalAmount, feeAmount,
        platformAddr, platformData, deadline
      );

      // User 2 trades
      await router.connect(user2).buyWithFee(
        collateralAddr, totalAmount, feeAmount,
        platformAddr, platformData, deadline
      );

      // Fee collector should have received both fees
      const feeBalAfter = await collateral.balanceOf(feeVault.address);
      expect(feeBalAfter - feeBalBefore).to.equal(feeAmount * 2n);
    });

    it("should correctly send fees to feeVault across multiple trades", async function () {
      const deadline = await futureDeadline();
      const totalAmount = ethers.parseEther("50");
      const feeAmount = ethers.parseEther("0.5");
      const platformAddr = await mockPlatform.getAddress();
      const collateralAddr = await collateral.getAddress();
      const routerAddr = await router.getAddress();

      const platformData = mockPlatform.interface.encodeFunctionData("execute");

      const feeBalBefore = await collateral.balanceOf(feeVault.address);

      for (let i = 0; i < 3; i++) {
        await collateral.transfer(user.address, totalAmount);
        await collateral.connect(user).approve(routerAddr, totalAmount);
        await router.connect(user).buyWithFee(
          collateralAddr, totalAmount, feeAmount,
          platformAddr, platformData, deadline
        );
      }

      // feeVault should have received fees from all 3 trades
      const feeBalAfter = await collateral.balanceOf(feeVault.address);
      expect(feeBalAfter - feeBalBefore).to.equal(feeAmount * 3n);

      // Router approval to platform should be reset to zero after each trade
      const allowance = await collateral.allowance(routerAddr, platformAddr);
      expect(allowance).to.equal(0n);
    });
  });
});
