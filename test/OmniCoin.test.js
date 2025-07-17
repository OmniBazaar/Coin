const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

describe("OmniCoin Integration", function () {
  let omniCoin;
  let reputation;
  let staking;
  let validator;
  let privacy;
  let arbitration;
  let bridge;
  let owner;
  let user1;
  let user2;
  let user3;

  beforeEach(async function () {
    [owner, user1, user2, user3] = await ethers.getSigners();

    // Deploy all contracts
    const OmniCoin = await ethers.getContractFactory("OmniCoin");
    omniCoin = await upgrades.deployProxy(OmniCoin, [], {
      initializer: "initialize",
    });

    const OmniCoinReputation = await ethers.getContractFactory("OmniCoinReputation");
    reputation = await upgrades.deployProxy(
      OmniCoinReputation,
      [
        await omniCoin.getAddress(),
        1000, // minReputationForValidator
        30 * 24 * 60 * 60, // reputationDecayPeriod (30 days)
        5 // reputationDecayFactor (5%)
      ],
      { initializer: "initialize" }
    );

    const OmniCoinStaking = await ethers.getContractFactory("OmniCoinStaking");
    staking = await upgrades.deployProxy(
      OmniCoinStaking,
      [await omniCoin.getAddress()],
      { initializer: "initialize" }
    );

    const OmniCoinValidator = await ethers.getContractFactory("OmniCoinValidator");
    validator = await upgrades.deployProxy(
      OmniCoinValidator,
      [
        await omniCoin.getAddress(),
        await reputation.getAddress(),
        await staking.getAddress(),
        ethers.parseEther("10000"), // minStakeAmount
        100, // maxValidators
        24 * 60 * 60, // rewardInterval (1 day)
        60 * 60, // heartbeatInterval (1 hour)
        10 // slashingPenalty (10%)
      ],
      { initializer: "initialize" }
    );

    const OmniCoinPrivacy = await ethers.getContractFactory("OmniCoinPrivacy");
    privacy = await upgrades.deployProxy(
      OmniCoinPrivacy,
      [
        await omniCoin.getAddress(),
        await omniCoin.getAddress(),
        ethers.parseEther("0.1"), // basePrivacyFee
        3, // maxPrivacyLevel
        60 * 60 // minCooldownPeriod (1 hour)
      ],
      { initializer: "initialize" }
    );

    const OmniCoinArbitration = await ethers.getContractFactory("OmniCoinArbitration");
    arbitration = await upgrades.deployProxy(
      OmniCoinArbitration,
      [
        await omniCoin.getAddress(),
        await reputation.getAddress(),
        ethers.parseEther("100"), // minArbitrationFee
        7 * 24 * 60 * 60, // maxArbitrationPeriod (7 days)
        3 // maxArbitrators
      ],
      { initializer: "initialize" }
    );

    const OmniCoinBridge = await ethers.getContractFactory("OmniCoinBridge");
    bridge = await upgrades.deployProxy(
      OmniCoinBridge,
      [
        await omniCoin.getAddress(),
        ethers.parseEther("0.01"), // bridgeFee
        60 * 60 // bridgeTimeout (1 hour)
      ],
      { initializer: "initialize" }
    );

    // Set up permissions and roles
    await omniCoin.grantRole(await omniCoin.MINTER_ROLE(), await validator.getAddress());
    await omniCoin.grantRole(await omniCoin.MINTER_ROLE(), await bridge.getAddress());
    
    // Transfer ownership
    await omniCoin.transferOwnership(await validator.getAddress());
    await reputation.transferOwnership(await validator.getAddress());
    await staking.transferOwnership(await validator.getAddress());
    await privacy.transferOwnership(await validator.getAddress());
    await arbitration.transferOwnership(await validator.getAddress());
    await bridge.transferOwnership(await validator.getAddress());

    // Mint some tokens to users for testing
    await omniCoin.mint(user1.address, ethers.parseEther("100000"));
    await omniCoin.mint(user2.address, ethers.parseEther("100000"));
    await omniCoin.mint(user3.address, ethers.parseEther("100000"));
  });

  describe("Staking and Validator Integration", function () {
    it("Should allow users to stake and become validators", async function () {
      // User1 stakes tokens
      await omniCoin.connect(user1).approve(staking.getAddress(), ethers.parseEther("20000"));
      await staking.connect(user1).stake(ethers.parseEther("20000"));

      // Update reputation for user1
      await reputation.connect(user1).updateReputation(user1.address, 1500);

      // User1 should be able to register as validator
      await validator.connect(user1).registerValidator();
      expect(await validator.isValidator(user1.address)).to.be.true;
    });

    it("Should distribute rewards to validators", async function () {
      // Setup validators
      await omniCoin.connect(user1).approve(staking.getAddress(), ethers.parseEther("20000"));
      await staking.connect(user1).stake(ethers.parseEther("20000"));
      await reputation.connect(user1).updateReputation(user1.address, 1500);
      await validator.connect(user1).registerValidator();

      // Advance time to trigger rewards
      await time.increase(24 * 60 * 60); // 1 day

      // Distribute rewards
      await validator.connect(user1).distributeRewards();

      // Check if rewards were distributed
      const balance = await omniCoin.balanceOf(user1.address);
      expect(balance).to.be.gt(ethers.parseEther("100000")); // Should have received rewards
    });
  });

  describe("Privacy Features", function () {
    it("Should allow private transactions", async function () {
      const amount = ethers.parseEther("1000");
      const privacyLevel = 2;

      // Create private transaction
      await omniCoin.connect(user1).approve(privacy.getAddress(), amount);
      await privacy.connect(user1).createPrivateTransaction(
        user2.address,
        amount,
        privacyLevel
      );

      // Complete private transaction
      await privacy.connect(user2).completePrivateTransaction(0);

      // Check balances
      const balance = await omniCoin.balanceOf(user2.address);
      expect(balance).to.be.gt(ethers.parseEther("100000")); // Should have received tokens
    });
  });

  describe("Arbitration System", function () {
    it("Should handle dispute resolution", async function () {
      // Create a dispute
      const disputeAmount = ethers.parseEther("1000");
      await omniCoin.connect(user1).approve(arbitration.getAddress(), disputeAmount);
      await arbitration.connect(user1).createDispute(
        user2.address,
        disputeAmount,
        "Test dispute"
      );

      // Assign arbitrators
      await arbitration.connect(user3).registerArbitrator();
      await arbitration.connect(user3).assignArbitrator(0);

      // Resolve dispute
      await arbitration.connect(user3).resolveDispute(0, true);

      // Check if funds were released
      const balance = await omniCoin.balanceOf(user1.address);
      expect(balance).to.be.gt(ethers.parseEther("100000")); // Should have received funds back
    });
  });

  describe("Bridge Integration", function () {
    it("Should handle cross-chain transfers", async function () {
      const amount = ethers.parseEther("1000");
      const targetChain = "ethereum";
      const targetAddress = user2.address;

      // Initiate bridge transfer
      await omniCoin.connect(user1).approve(bridge.getAddress(), amount);
      await bridge.connect(user1).initiateTransfer(
        amount,
        targetChain,
        targetAddress
      );

      // Complete bridge transfer
      await bridge.connect(user2).completeTransfer(0);

      // Check if tokens were received
      const balance = await omniCoin.balanceOf(user2.address);
      expect(balance).to.be.gt(ethers.parseEther("100000")); // Should have received tokens
    });
  });

  describe("Reputation System", function () {
    it("Should track and update user reputation", async function () {
      // Initial reputation update
      await reputation.connect(user1).updateReputation(user1.address, 1000);

      // Record successful transaction
      await reputation.connect(user1).recordSuccessfulTransaction(user1.address);

      // Record failed transaction
      await reputation.connect(user1).recordFailedTransaction(user1.address);

      // Check final reputation
      const finalReputation = await reputation.getReputationScore(user1.address);
      expect(finalReputation).to.be.gt(0);
    });

    it("Should handle reputation decay", async function () {
      // Set initial reputation
      await reputation.connect(user1).updateReputation(user1.address, 1000);

      // Advance time to trigger decay
      await time.increase(31 * 24 * 60 * 60); // 31 days

      // Check decayed reputation
      const decayedReputation = await reputation.getReputationScore(user1.address);
      expect(decayedReputation).to.be.lt(1000);
    });
  });
}); 