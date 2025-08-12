const { expect } = require("chai");
const { ethers } = require("hardhat");
const { loadFixture } = require("@nomicfoundation/hardhat-network-helpers");

describe("OmniCoin Integration Tests", function () {
  async function deployIntegrationFixture() {
    const [owner, validator1, validator2, user1, user2, user3] = await ethers.getSigners();

    // Deploy all contracts in correct order
    const OmniCoinConfig = await ethers.getContractFactory("OmniCoinConfig");
    const config = await OmniCoinConfig.deploy();

    const OmniCoinReputation = await ethers.getContractFactory("OmniCoinReputation");
    const reputation = await OmniCoinReputation.deploy();

    const OmniCoinStaking = await ethers.getContractFactory("OmniCoinStaking");
    const staking = await OmniCoinStaking.deploy(ethers.constants.AddressZero);

    const OmniCoinValidator = await ethers.getContractFactory("OmniCoinValidator");
    const validator = await OmniCoinValidator.deploy(ethers.constants.AddressZero);

    const ValidatorRegistry = await ethers.getContractFactory("ValidatorRegistry");
    const validatorRegistry = await ValidatorRegistry.deploy();

    const OmniCoinMultisig = await ethers.getContractFactory("OmniCoinMultisig");
    const multisig = await OmniCoinMultisig.deploy();

    const OmniCoinPrivacy = await ethers.getContractFactory("OmniCoinPrivacy");
    const privacy = await OmniCoinPrivacy.deploy(ethers.constants.AddressZero);

    const OmniCoinGarbledCircuit = await ethers.getContractFactory("OmniCoinGarbledCircuit");
    const garbledCircuit = await OmniCoinGarbledCircuit.deploy();

    const OmniCoinGovernor = await ethers.getContractFactory("OmniCoinGovernor");
    const governor = await OmniCoinGovernor.deploy(ethers.constants.AddressZero);

    const OmniCoinEscrow = await ethers.getContractFactory("OmniCoinEscrow");
    const escrow = await OmniCoinEscrow.deploy(ethers.constants.AddressZero);

    const OmniCoinBridge = await ethers.getContractFactory("OmniCoinBridge");
    const bridge = await OmniCoinBridge.deploy(ethers.constants.AddressZero);

    const FeeDistribution = await ethers.getContractFactory("FeeDistribution");
    const feeDistribution = await FeeDistribution.deploy();

    // Deploy main token contract
    const OmniCoin = await ethers.getContractFactory("OmniCoin");
    const omniCoin = await OmniCoin.deploy(
      config.address,
      reputation.address,
      staking.address,
      validator.address,
      multisig.address,
      privacy.address,
      garbledCircuit.address,
      governor.address,
      escrow.address,
      bridge.address
    );

    // Update token references in dependent contracts
    await staking.transferOwnership(omniCoin.address);
    await validator.transferOwnership(omniCoin.address);
    await privacy.transferOwnership(omniCoin.address);
    await governor.transferOwnership(omniCoin.address);
    await escrow.transferOwnership(omniCoin.address);
    await bridge.transferOwnership(omniCoin.address);

    // Initial token distribution
    await omniCoin.mint(owner.address, ethers.utils.parseEther("1000000")); // 1M tokens
    await omniCoin.mint(validator1.address, ethers.utils.parseEther("50000")); // 50K tokens
    await omniCoin.mint(validator2.address, ethers.utils.parseEther("50000")); // 50K tokens
    await omniCoin.mint(user1.address, ethers.utils.parseEther("10000")); // 10K tokens
    await omniCoin.mint(user2.address, ethers.utils.parseEther("10000")); // 10K tokens
    await omniCoin.mint(user3.address, ethers.utils.parseEther("10000")); // 10K tokens

    return {
      omniCoin,
      config,
      reputation,
      staking,
      validator,
      validatorRegistry,
      multisig,
      privacy,
      garbledCircuit,
      governor,
      escrow,
      bridge,
      feeDistribution,
      owner,
      validator1,
      validator2,
      user1,
      user2,
      user3
    };
  }

  describe("Token and Validator Network Integration", function () {
    it("Should handle complete validator registration and staking flow", async function () {
      const { omniCoin, validatorRegistry, validator1, validator2 } = await loadFixture(deployIntegrationFixture);

      // Register validators
      await validatorRegistry.connect(validator1).registerValidator(
        "validator1",
        "QmValidator1Hash",
        { cpu: 8, memory: 16, storage: 500 }
      );

      await validatorRegistry.connect(validator2).registerValidator(
        "validator2",
        "QmValidator2Hash",
        { cpu: 8, memory: 16, storage: 500 }
      );

      // Stake tokens
      const stakeAmount = ethers.utils.parseEther("10000");
      await omniCoin.connect(validator1).approve(validatorRegistry.address, stakeAmount);
      await omniCoin.connect(validator2).approve(validatorRegistry.address, stakeAmount);

      await validatorRegistry.connect(validator1).stake(stakeAmount);
      await validatorRegistry.connect(validator2).stake(stakeAmount);

      // Check validator status
      const validator1Info = await validatorRegistry.validators(validator1.address);
      const validator2Info = await validatorRegistry.validators(validator2.address);

      expect(validator1Info.stakedAmount).to.equal(stakeAmount);
      expect(validator2Info.stakedAmount).to.equal(stakeAmount);
      expect(validator1Info.isActive).to.be.true;
      expect(validator2Info.isActive).to.be.true;

      // Check token balances
      expect(await omniCoin.balanceOf(validator1.address)).to.equal(
        ethers.utils.parseEther("40000") // 50K - 10K staked
      );
      expect(await omniCoin.balanceOf(validator2.address)).to.equal(
        ethers.utils.parseEther("40000") // 50K - 10K staked
      );
    });

    it("Should distribute rewards to validators correctly", async function () {
      const { omniCoin, validatorRegistry, feeDistribution, validator1, validator2 } = await loadFixture(deployIntegrationFixture);

      // Setup validators
      await validatorRegistry.connect(validator1).registerValidator(
        "validator1",
        "QmValidator1Hash",
        { cpu: 8, memory: 16, storage: 500 }
      );

      const stakeAmount = ethers.utils.parseEther("10000");
      await omniCoin.connect(validator1).approve(validatorRegistry.address, stakeAmount);
      await validatorRegistry.connect(validator1).stake(stakeAmount);

      // Simulate fee collection
      await feeDistribution.collectFees(
        omniCoin.address,
        ethers.utils.parseEther("1000"),
        0 // TRADING fees
      );

      // Distribute fees
      await feeDistribution.distributeFees();

      // Check distribution
      const distribution = await feeDistribution.getLatestDistribution();
      expect(distribution.totalAmount).to.equal(ethers.utils.parseEther("1000"));
      expect(distribution.validatorShare).to.equal(ethers.utils.parseEther("700")); // 70%
      expect(distribution.companyShare).to.equal(ethers.utils.parseEther("200")); // 20%
      expect(distribution.developmentShare).to.equal(ethers.utils.parseEther("100")); // 10%
    });
  });

  describe("Token and Privacy Integration", function () {
    it("Should handle privacy account creation and private transfers", async function () {
      const { omniCoin, privacy, user1, user2 } = await loadFixture(deployIntegrationFixture);

      // Create privacy accounts
      const commitment1 = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("user1_secret"));
      const commitment2 = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("user2_secret"));

      await privacy.connect(user1).createAccount(commitment1);
      await privacy.connect(user2).createAccount(commitment2);

      // Check privacy accounts
      const account1 = await privacy.accounts(commitment1);
      const account2 = await privacy.accounts(commitment2);

      expect(account1.isActive).to.be.true;
      expect(account2.isActive).to.be.true;
      expect(account1.commitment).to.equal(commitment1);
      expect(account2.commitment).to.equal(commitment2);

      // Test privacy deposit
      const depositAmount = ethers.utils.parseEther("1000");
      await omniCoin.connect(user1).approve(privacy.address, depositAmount);
      await privacy.connect(user1).deposit(commitment1, depositAmount);

      // Check privacy balance
      const updatedAccount1 = await privacy.accounts(commitment1);
      expect(updatedAccount1.balance).to.equal(depositAmount);
    });

    it("Should prevent privacy operations when disabled", async function () {
      const { omniCoin, privacy, user1 } = await loadFixture(deployIntegrationFixture);

      // Disable privacy
      await omniCoin.togglePrivacy();

      // Try to create privacy account (should fail)
      await expect(
        omniCoin.createPrivacyAccount()
      ).to.be.revertedWith("OmniCoin: privacy is disabled");

      // Try to transfer privately (should fail)
      await expect(
        omniCoin.transferPrivate(user1.address, ethers.utils.parseEther("100"))
      ).to.be.revertedWith("OmniCoin: privacy is disabled");
    });
  });

  describe("Token and Escrow Integration", function () {
    it("Should handle complete escrow flow", async function () {
      const { omniCoin, escrow, user1, user2 } = await loadFixture(deployIntegrationFixture);

      // Create escrow
      const escrowAmount = ethers.utils.parseEther("500");
      await omniCoin.connect(user1).approve(escrow.address, escrowAmount);
      await omniCoin.connect(user1).createEscrow(user2.address, escrowAmount);

      // Check escrow creation
      const escrowId = 1;
      const escrowInfo = await escrow.escrows(escrowId);
      expect(escrowInfo.seller).to.equal(user1.address);
      expect(escrowInfo.buyer).to.equal(user2.address);
      expect(escrowInfo.amount).to.equal(escrowAmount);
      expect(escrowInfo.released).to.be.false;

      // Check token balances
      expect(await omniCoin.balanceOf(user1.address)).to.equal(
        ethers.utils.parseEther("9500") // 10K - 500 escrowed
      );
      expect(await omniCoin.balanceOf(escrow.address)).to.equal(escrowAmount);

      // Release escrow
      await escrow.connect(user1).releaseEscrow(escrowId);

      // Check final balances
      expect(await omniCoin.balanceOf(user2.address)).to.equal(
        ethers.utils.parseEther("10500") // 10K + 500 from escrow
      );
      expect(await omniCoin.balanceOf(escrow.address)).to.equal(0);
    });

    it("Should handle escrow disputes", async function () {
      const { omniCoin, escrow, user1, user2, owner } = await loadFixture(deployIntegrationFixture);

      // Create escrow
      const escrowAmount = ethers.utils.parseEther("500");
      await omniCoin.connect(user1).approve(escrow.address, escrowAmount);
      await omniCoin.connect(user1).createEscrow(user2.address, escrowAmount);

      const escrowId = 1;

      // Create dispute
      await escrow.connect(user2).createDispute(escrowId, "Product not as described");

      // Check dispute
      const disputeId = 1;
      const dispute = await escrow.disputes(disputeId);
      expect(dispute.escrowId).to.equal(escrowId);
      expect(dispute.reporter).to.equal(user2.address);
      expect(dispute.resolved).to.be.false;

      // Resolve dispute (owner as arbitrator)
      await escrow.connect(owner).resolveDispute(disputeId, true); // Favor buyer

      // Check resolution
      const resolvedDispute = await escrow.disputes(disputeId);
      expect(resolvedDispute.resolved).to.be.true;
      expect(resolvedDispute.outcome).to.be.true;
    });
  });

  describe("Token and Bridge Integration", function () {
    it("Should handle cross-chain bridge transfers", async function () {
      const { omniCoin, bridge, user1 } = await loadFixture(deployIntegrationFixture);

      // Configure bridge for Polygon
      await bridge.configureBridge(
        137, // Polygon chain ID
        omniCoin.address,
        ethers.utils.parseEther("10"), // Min amount
        ethers.utils.parseEther("100000"), // Max amount
        ethers.utils.parseEther("1") // Fee
      );

      // Initiate bridge transfer
      const bridgeAmount = ethers.utils.parseEther("1000");
      await omniCoin.connect(user1).approve(bridge.address, bridgeAmount);
      await omniCoin.connect(user1).initiateBridgeTransfer(137, user1.address, bridgeAmount);

      // Check transfer
      const transferId = 1;
      const transfer = await bridge.transfers(transferId);
      expect(transfer.sender).to.equal(user1.address);
      expect(transfer.targetChainId).to.equal(137);
      expect(transfer.amount).to.equal(bridgeAmount);
      expect(transfer.completed).to.be.false;

      // Check token balance
      expect(await omniCoin.balanceOf(user1.address)).to.equal(
        ethers.utils.parseEther("9000") // 10K - 1K bridged
      );
      expect(await omniCoin.balanceOf(bridge.address)).to.equal(bridgeAmount);
    });
  });

  describe("Token and Governance Integration", function () {
    it("Should handle governance proposals and voting", async function () {
      const { omniCoin, governor, user1, user2, user3 } = await loadFixture(deployIntegrationFixture);

      // Create proposal
      await governor.connect(user1).createProposal("Increase validator rewards by 10%");

      // Check proposal
      const proposalId = 1;
      const proposal = await governor.proposals(proposalId);
      expect(proposal.proposer).to.equal(user1.address);
      expect(proposal.executed).to.be.false;

      // Vote on proposal
      await governor.connect(user1).vote(proposalId, true); // Support
      await governor.connect(user2).vote(proposalId, true); // Support
      await governor.connect(user3).vote(proposalId, false); // Against

      // Check vote counts
      const updatedProposal = await governor.proposals(proposalId);
      expect(updatedProposal.forVotes).to.be.gt(0);
      expect(updatedProposal.againstVotes).to.be.gt(0);
    });
  });

  describe("Multi-Contract Complex Workflows", function () {
    it("Should handle validator staking with governance and fee distribution", async function () {
      const { omniCoin, validatorRegistry, feeDistribution, governor, validator1, user1 } = await loadFixture(deployIntegrationFixture);

      // Register validator
      await validatorRegistry.connect(validator1).registerValidator(
        "validator1",
        "QmValidator1Hash",
        { cpu: 8, memory: 16, storage: 500 }
      );

      // Stake tokens
      const stakeAmount = ethers.utils.parseEther("10000");
      await omniCoin.connect(validator1).approve(validatorRegistry.address, stakeAmount);
      await validatorRegistry.connect(validator1).stake(stakeAmount);

      // Create governance proposal to change validator rewards
      await governor.connect(user1).createProposal("Increase validator rewards");

      // Collect and distribute fees
      await feeDistribution.collectFees(
        omniCoin.address,
        ethers.utils.parseEther("1000"),
        0 // TRADING fees
      );

      await feeDistribution.distributeFees();

      // Check that all systems are working together
      const validatorInfo = await validatorRegistry.validators(validator1.address);
      const distribution = await feeDistribution.getLatestDistribution();
      const proposal = await governor.proposals(1);

      expect(validatorInfo.isActive).to.be.true;
      expect(distribution.totalAmount).to.equal(ethers.utils.parseEther("1000"));
      expect(proposal.proposer).to.equal(user1.address);
    });

    it("Should handle privacy transfers with escrow", async function () {
      const { omniCoin, privacy, escrow, user1, user2 } = await loadFixture(deployIntegrationFixture);

      // Create privacy account
      const commitment = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("user1_secret"));
      await privacy.connect(user1).createAccount(commitment);

      // Deposit to privacy account
      const depositAmount = ethers.utils.parseEther("1000");
      await omniCoin.connect(user1).approve(privacy.address, depositAmount);
      await privacy.connect(user1).deposit(commitment, depositAmount);

      // Create escrow with regular tokens
      const escrowAmount = ethers.utils.parseEther("500");
      await omniCoin.connect(user1).approve(escrow.address, escrowAmount);
      await omniCoin.connect(user1).createEscrow(user2.address, escrowAmount);

      // Check both privacy and escrow balances
      const privacyAccount = await privacy.accounts(commitment);
      const escrowInfo = await escrow.escrows(1);

      expect(privacyAccount.balance).to.equal(depositAmount);
      expect(escrowInfo.amount).to.equal(escrowAmount);
      expect(await omniCoin.balanceOf(user1.address)).to.equal(
        ethers.utils.parseEther("8500") // 10K - 1K privacy - 500 escrow
      );
    });
  });

  describe("Security Integration", function () {
    it("Should maintain security across all contract interactions", async function () {
      const { omniCoin, validatorRegistry, privacy, escrow, user1, validator1 } = await loadFixture(deployIntegrationFixture);

      // Test pausable affects all integrations
      await omniCoin.pause();

      // All interactions should be paused
      await expect(
        omniCoin.connect(user1).stake(ethers.utils.parseEther("100"))
      ).to.be.revertedWith("Pausable: paused");

      await expect(
        omniCoin.connect(user1).createEscrow(user1.address, ethers.utils.parseEther("100"))
      ).to.be.revertedWith("Pausable: paused");

      await expect(
        omniCoin.connect(user1).createPrivacyAccount()
      ).to.be.revertedWith("Pausable: paused");

      // Unpause and test functionality returns
      await omniCoin.unpause();

      await expect(
        omniCoin.connect(user1).stake(ethers.utils.parseEther("100"))
      ).to.not.be.reverted;
    });

    it("Should handle role-based access across integrations", async function () {
      const { omniCoin, owner, user1 } = await loadFixture(deployIntegrationFixture);

      // Only owner should be able to configure system-wide settings
      await expect(
        omniCoin.connect(user1).setMultisigThreshold(ethers.utils.parseEther("2000"))
      ).to.be.revertedWith("AccessControl: account");

      await expect(
        omniCoin.connect(user1).togglePrivacy()
      ).to.be.revertedWith("AccessControl: account");

      // Owner should be able to perform admin actions
      await expect(
        omniCoin.connect(owner).setMultisigThreshold(ethers.utils.parseEther("2000"))
      ).to.not.be.reverted;

      await expect(
        omniCoin.connect(owner).togglePrivacy()
      ).to.not.be.reverted;
    });
  });
}); 