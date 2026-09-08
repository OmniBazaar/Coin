const { expect } = require("chai");
const { ethers } = require("hardhat");
const { loadFixture, time } = require("@nomicfoundation/hardhat-network-helpers");

describe("LegacyBalanceClaim", function () {
  // ════════════════════════════════════════════════════════════════════
  //  Constants
  // ════════════════════════════════════════════════════════════════════

  const MAX_MIGRATION_SUPPLY = ethers.parseEther("4320000000"); // 4.32B XOM
  const MIGRATION_DURATION = 730n * 24n * 60n * 60n; // 730 days in seconds
  const FUNDING_AMOUNT = ethers.parseEther("5000000000"); // 5B XOM (more than max to ensure enough)

  // ════════════════════════════════════════════════════════════════════
  //  Helpers
  // ════════════════════════════════════════════════════════════════════

  /**
   * Create M validator wallets connected to the provider.
   * Returns an array of ethers.Wallet instances.
   */
  function createValidatorWallets(count) {
    const wallets = [];
    for (let i = 0; i < count; i++) {
      wallets.push(ethers.Wallet.createRandom().connect(ethers.provider));
    }
    return wallets;
  }

  /**
   * Generate a claim signature from a validator wallet.
   * Matches the contract's _verifyMultiSigProof encoding exactly.
   */
  async function signClaim(wallet, username, ethAddress, nonce, contractAddress, chainId) {
    const message = ethers.AbiCoder.defaultAbiCoder().encode(
      ["string", "address", "uint256", "address", "uint256"],
      [username, ethAddress, nonce, contractAddress, chainId]
    );
    const messageHash = ethers.keccak256(message);
    return wallet.signMessage(ethers.getBytes(messageHash));
  }

  /**
   * Generate an array of claim signatures from multiple validator wallets.
   */
  async function signClaimMulti(wallets, username, ethAddress, nonce, contractAddress, chainId) {
    const proofs = [];
    for (const wallet of wallets) {
      proofs.push(await signClaim(wallet, username, ethAddress, nonce, contractAddress, chainId));
    }
    return proofs;
  }

  // ════════════════════════════════════════════════════════════════════
  //  Fixtures
  // ════════════════════════════════════════════════════════════════════

  /**
   * Deploy ERC20Mock and LegacyBalanceClaim with 3-of-5 multisig.
   * Funds the contract with tokens but does NOT initialize legacy balances.
   */
  async function deployFixture() {
    const [owner, claimer, recipient, other] = await ethers.getSigners();

    // Create 5 validator wallets
    const validatorWallets = createValidatorWallets(5);
    const validatorAddresses = validatorWallets.map((w) => w.address);
    const requiredSigs = 3;

    // Fund validator wallets with ETH for gas (they need it if they ever send txs)
    for (const vw of validatorWallets) {
      await owner.sendTransaction({ to: vw.address, value: ethers.parseEther("1") });
    }

    // Deploy ERC20Mock
    const ERC20Mock = await ethers.getContractFactory("ERC20Mock");
    const token = await ERC20Mock.deploy("OmniCoin", "XOM");
    await token.waitForDeployment();

    // Mint additional supply so we have enough to fund the contract
    await token.mint(owner.address, FUNDING_AMOUNT);

    // Deploy LegacyBalanceClaim
    const LegacyBalanceClaim = await ethers.getContractFactory("LegacyBalanceClaim");
    const claim = await LegacyBalanceClaim.deploy(
      await token.getAddress(),
      owner.address,
      validatorAddresses,
      requiredSigs,
      ethers.ZeroAddress // no trusted forwarder
    );
    await claim.waitForDeployment();

    // Fund the contract with tokens
    await token.transfer(await claim.getAddress(), FUNDING_AMOUNT);

    const chainId = (await ethers.provider.getNetwork()).chainId;
    const contractAddress = await claim.getAddress();

    return {
      token,
      claim,
      owner,
      claimer,
      recipient,
      other,
      validatorWallets,
      validatorAddresses,
      requiredSigs,
      chainId,
      contractAddress,
    };
  }

  /**
   * Deploys and initializes with a small set of legacy users.
   */
  async function deployAndInitializeFixture() {
    const base = await deployFixture();
    const { claim, owner } = base;

    const usernames = ["alice", "bob", "charlie"];
    const balances = [
      ethers.parseEther("1000"),
      ethers.parseEther("2000"),
      ethers.parseEther("500"),
    ];

    await claim.connect(owner).initialize(usernames, balances);

    return { ...base, usernames, balances };
  }

  // ════════════════════════════════════════════════════════════════════
  //  1. Constructor
  // ════════════════════════════════════════════════════════════════════

  describe("Constructor", function () {
    it("should set OMNI_COIN immutable correctly", async function () {
      const { claim, token } = await loadFixture(deployFixture);
      expect(await claim.OMNI_COIN()).to.equal(await token.getAddress());
    });

    it("should set DEPLOYED_AT to current block timestamp", async function () {
      const { claim } = await loadFixture(deployFixture);
      const deployedAt = await claim.DEPLOYED_AT();
      expect(deployedAt).to.be.greaterThan(0n);
    });

    it("should set the correct owner", async function () {
      const { claim, owner } = await loadFixture(deployFixture);
      expect(await claim.owner()).to.equal(owner.address);
    });

    it("should store validators correctly", async function () {
      const { claim, validatorAddresses } = await loadFixture(deployFixture);
      const stored = await claim.getValidators();
      expect(stored.length).to.equal(validatorAddresses.length);
      for (let i = 0; i < validatorAddresses.length; i++) {
        expect(stored[i]).to.equal(validatorAddresses[i]);
        expect(await claim.isValidator(validatorAddresses[i])).to.be.true;
      }
    });

    it("should set requiredSignatures correctly", async function () {
      const { claim, requiredSigs } = await loadFixture(deployFixture);
      expect(await claim.requiredSignatures()).to.equal(requiredSigs);
    });

    it("should emit ValidatorSetUpdated on deployment", async function () {
      const [owner] = await ethers.getSigners();
      const validatorWallets = createValidatorWallets(3);
      const validatorAddresses = validatorWallets.map((w) => w.address);

      const ERC20Mock = await ethers.getContractFactory("ERC20Mock");
      const token = await ERC20Mock.deploy("OmniCoin", "XOM");
      await token.waitForDeployment();

      const LegacyBalanceClaim = await ethers.getContractFactory("LegacyBalanceClaim");
      const contract = await LegacyBalanceClaim.deploy(
        await token.getAddress(),
        owner.address,
        validatorAddresses,
        2,
        ethers.ZeroAddress
      );
      await contract.waitForDeployment();

      // Verify the event was emitted by inspecting the deployment transaction receipt
      const deployTx = contract.deploymentTransaction();
      const receipt = await deployTx.wait();
      const iface = contract.interface;
      const eventLog = receipt.logs.find((log) => {
        try {
          const parsed = iface.parseLog(log);
          return parsed && parsed.name === "ValidatorSetUpdated";
        } catch {
          return false;
        }
      });
      expect(eventLog).to.not.be.undefined;
      const parsed = iface.parseLog(eventLog);
      expect(parsed.args.validatorCount).to.equal(3);
      expect(parsed.args.requiredSigs).to.equal(2);
    });

    it("should revert with ZeroAddress when omniCoin is zero address", async function () {
      const [owner] = await ethers.getSigners();
      const validatorWallets = createValidatorWallets(3);
      const validatorAddresses = validatorWallets.map((w) => w.address);

      const LegacyBalanceClaim = await ethers.getContractFactory("LegacyBalanceClaim");
      await expect(
        LegacyBalanceClaim.deploy(
          ethers.ZeroAddress,
          owner.address,
          validatorAddresses,
          2,
          ethers.ZeroAddress
        )
      ).to.be.revertedWithCustomError(LegacyBalanceClaim, "ZeroAddress");
    });

    it("should revert with InvalidValidatorSet when validators array is empty", async function () {
      const [owner] = await ethers.getSigners();

      const ERC20Mock = await ethers.getContractFactory("ERC20Mock");
      const token = await ERC20Mock.deploy("OmniCoin", "XOM");

      const LegacyBalanceClaim = await ethers.getContractFactory("LegacyBalanceClaim");
      await expect(
        LegacyBalanceClaim.deploy(
          await token.getAddress(),
          owner.address,
          [],
          1,
          ethers.ZeroAddress
        )
      ).to.be.revertedWithCustomError(LegacyBalanceClaim, "InvalidValidatorSet");
    });

    it("should revert with InvalidValidatorSet when requiredSignatures is zero", async function () {
      const [owner] = await ethers.getSigners();
      const validatorWallets = createValidatorWallets(3);
      const validatorAddresses = validatorWallets.map((w) => w.address);

      const ERC20Mock = await ethers.getContractFactory("ERC20Mock");
      const token = await ERC20Mock.deploy("OmniCoin", "XOM");

      const LegacyBalanceClaim = await ethers.getContractFactory("LegacyBalanceClaim");
      await expect(
        LegacyBalanceClaim.deploy(
          await token.getAddress(),
          owner.address,
          validatorAddresses,
          0,
          ethers.ZeroAddress
        )
      ).to.be.revertedWithCustomError(LegacyBalanceClaim, "InvalidValidatorSet");
    });

    it("should revert with InvalidValidatorSet when requiredSignatures exceeds validator count", async function () {
      const [owner] = await ethers.getSigners();
      const validatorWallets = createValidatorWallets(3);
      const validatorAddresses = validatorWallets.map((w) => w.address);

      const ERC20Mock = await ethers.getContractFactory("ERC20Mock");
      const token = await ERC20Mock.deploy("OmniCoin", "XOM");

      const LegacyBalanceClaim = await ethers.getContractFactory("LegacyBalanceClaim");
      await expect(
        LegacyBalanceClaim.deploy(
          await token.getAddress(),
          owner.address,
          validatorAddresses,
          4, // 4 > 3 validators
          ethers.ZeroAddress
        )
      ).to.be.revertedWithCustomError(LegacyBalanceClaim, "InvalidValidatorSet");
    });

    it("should revert with DuplicateValidator when duplicate validators are provided", async function () {
      const [owner] = await ethers.getSigners();
      const vw = createValidatorWallets(2);

      const ERC20Mock = await ethers.getContractFactory("ERC20Mock");
      const token = await ERC20Mock.deploy("OmniCoin", "XOM");

      const LegacyBalanceClaim = await ethers.getContractFactory("LegacyBalanceClaim");
      await expect(
        LegacyBalanceClaim.deploy(
          await token.getAddress(),
          owner.address,
          [vw[0].address, vw[1].address, vw[0].address], // duplicate
          2,
          ethers.ZeroAddress
        )
      ).to.be.revertedWithCustomError(LegacyBalanceClaim, "DuplicateValidator");
    });

    it("should revert with ZeroAddress when a validator address is zero", async function () {
      const [owner] = await ethers.getSigners();
      const vw = createValidatorWallets(2);

      const ERC20Mock = await ethers.getContractFactory("ERC20Mock");
      const token = await ERC20Mock.deploy("OmniCoin", "XOM");

      const LegacyBalanceClaim = await ethers.getContractFactory("LegacyBalanceClaim");
      await expect(
        LegacyBalanceClaim.deploy(
          await token.getAddress(),
          owner.address,
          [vw[0].address, ethers.ZeroAddress, vw[1].address],
          2,
          ethers.ZeroAddress
        )
      ).to.be.revertedWithCustomError(LegacyBalanceClaim, "ZeroAddress");
    });
  });

  // ════════════════════════════════════════════════════════════════════
  //  2. initialize
  // ════════════════════════════════════════════════════════════════════

  describe("initialize", function () {
    it("should store legacy balances and set reserved flags", async function () {
      const { claim, owner } = await loadFixture(deployFixture);
      const usernames = ["alice", "bob"];
      const balances = [ethers.parseEther("1000"), ethers.parseEther("2000")];

      await claim.connect(owner).initialize(usernames, balances);

      expect(await claim.getUnclaimedBalance("alice")).to.equal(balances[0]);
      expect(await claim.getUnclaimedBalance("bob")).to.equal(balances[1]);
      expect(await claim.isReserved("alice")).to.be.true;
      expect(await claim.isReserved("bob")).to.be.true;
      expect(await claim.initialized()).to.be.true;
    });

    it("should update totalReserved and reservedCount", async function () {
      const { claim, owner } = await loadFixture(deployFixture);
      const usernames = ["alice", "bob"];
      const balances = [ethers.parseEther("1000"), ethers.parseEther("2000")];

      await claim.connect(owner).initialize(usernames, balances);

      expect(await claim.totalReserved()).to.equal(ethers.parseEther("3000"));
      expect(await claim.reservedCount()).to.equal(2);
    });

    it("should emit LegacyInitialized event", async function () {
      const { claim, owner } = await loadFixture(deployFixture);
      const usernames = ["alice"];
      const balances = [ethers.parseEther("1000")];

      await expect(claim.connect(owner).initialize(usernames, balances))
        .to.emit(claim, "LegacyInitialized")
        .withArgs(1, ethers.parseEther("1000"));
    });

    it("should revert with AlreadyInitialized when called twice", async function () {
      const { claim, owner } = await loadFixture(deployFixture);
      const usernames = ["alice"];
      const balances = [ethers.parseEther("1000")];

      await claim.connect(owner).initialize(usernames, balances);

      await expect(
        claim.connect(owner).initialize(["bob"], [ethers.parseEther("500")])
      ).to.be.revertedWithCustomError(claim, "AlreadyInitialized");
    });

    it("should revert when called by non-owner", async function () {
      const { claim, other } = await loadFixture(deployFixture);

      await expect(
        claim.connect(other).initialize(["alice"], [ethers.parseEther("100")])
      ).to.be.revertedWithCustomError(claim, "OwnableUnauthorizedAccount");
    });

    it("should revert with EmptyArray when usernames is empty", async function () {
      const { claim, owner } = await loadFixture(deployFixture);

      await expect(
        claim.connect(owner).initialize([], [])
      ).to.be.revertedWithCustomError(claim, "EmptyArray");
    });

    it("should revert with LengthMismatch when arrays have different lengths", async function () {
      const { claim, owner } = await loadFixture(deployFixture);

      await expect(
        claim.connect(owner).initialize(
          ["alice", "bob"],
          [ethers.parseEther("100")]
        )
      ).to.be.revertedWithCustomError(claim, "LengthMismatch");
    });

    it("should revert with EmptyUsername when a username is empty string", async function () {
      const { claim, owner } = await loadFixture(deployFixture);

      await expect(
        claim.connect(owner).initialize(
          ["alice", ""],
          [ethers.parseEther("100"), ethers.parseEther("200")]
        )
      ).to.be.revertedWithCustomError(claim, "EmptyUsername");
    });

    it("should revert with ZeroBalance when a balance is zero", async function () {
      const { claim, owner } = await loadFixture(deployFixture);

      await expect(
        claim.connect(owner).initialize(
          ["alice", "bob"],
          [ethers.parseEther("100"), 0n]
        )
      ).to.be.revertedWithCustomError(claim, "ZeroBalance");
    });

    it("should revert with DuplicateUsername when a username appears twice", async function () {
      const { claim, owner } = await loadFixture(deployFixture);

      await expect(
        claim.connect(owner).initialize(
          ["alice", "alice"],
          [ethers.parseEther("100"), ethers.parseEther("200")]
        )
      ).to.be.revertedWithCustomError(claim, "DuplicateUsername");
    });

    it("should revert with MigrationSupplyExceeded when total exceeds MAX_MIGRATION_SUPPLY", async function () {
      const { claim, owner } = await loadFixture(deployFixture);
      const overLimit = MAX_MIGRATION_SUPPLY + 1n;

      await expect(
        claim.connect(owner).initialize(["huge_user"], [overLimit])
      ).to.be.revertedWithCustomError(claim, "MigrationSupplyExceeded");
    });
  });

  // ════════════════════════════════════════════════════════════════════
  //  3. addLegacyUsers
  // ════════════════════════════════════════════════════════════════════

  describe("addLegacyUsers", function () {
    it("should add additional legacy users after initialization", async function () {
      const { claim, owner } = await loadFixture(deployAndInitializeFixture);

      await claim.connect(owner).addLegacyUsers(
        ["dave", "eve"],
        [ethers.parseEther("300"), ethers.parseEther("400")]
      );

      expect(await claim.getUnclaimedBalance("dave")).to.equal(ethers.parseEther("300"));
      expect(await claim.getUnclaimedBalance("eve")).to.equal(ethers.parseEther("400"));
      expect(await claim.isReserved("dave")).to.be.true;
      expect(await claim.reservedCount()).to.equal(5); // 3 initial + 2 added
    });

    it("should update totalReserved cumulatively", async function () {
      const { claim, owner } = await loadFixture(deployAndInitializeFixture);
      const initialReserved = await claim.totalReserved();

      await claim.connect(owner).addLegacyUsers(
        ["dave"],
        [ethers.parseEther("300")]
      );

      expect(await claim.totalReserved()).to.equal(initialReserved + ethers.parseEther("300"));
    });

    it("should emit LegacyUsersAdded event", async function () {
      const { claim, owner } = await loadFixture(deployAndInitializeFixture);

      const newTotal = (await claim.totalReserved()) + ethers.parseEther("300");
      await expect(
        claim.connect(owner).addLegacyUsers(["dave"], [ethers.parseEther("300")])
      ).to.emit(claim, "LegacyUsersAdded")
        .withArgs(1, ethers.parseEther("300"), newTotal);
    });

    it("should revert with NotInitialized when initialize() was not called", async function () {
      const { claim, owner } = await loadFixture(deployFixture);

      await expect(
        claim.connect(owner).addLegacyUsers(["dave"], [ethers.parseEther("100")])
      ).to.be.revertedWithCustomError(claim, "NotInitialized");
    });

    it("should revert with MigrationAlreadyFinalized after finalization", async function () {
      const { claim, owner, recipient } = await loadFixture(deployAndInitializeFixture);

      // Fast-forward past migration duration
      await time.increase(MIGRATION_DURATION + 1n);
      await claim.connect(owner).finalizeMigration(recipient.address);

      await expect(
        claim.connect(owner).addLegacyUsers(["dave"], [ethers.parseEther("100")])
      ).to.be.revertedWithCustomError(claim, "MigrationAlreadyFinalized");
    });

    it("should revert with MigrationSupplyExceeded when cumulative total exceeds cap", async function () {
      const { claim, owner } = await loadFixture(deployAndInitializeFixture);
      const currentReserved = await claim.totalReserved();
      const remaining = MAX_MIGRATION_SUPPLY - currentReserved;

      await expect(
        claim.connect(owner).addLegacyUsers(["overflow_user"], [remaining + 1n])
      ).to.be.revertedWithCustomError(claim, "MigrationSupplyExceeded");
    });

    it("should revert when called by non-owner", async function () {
      const { claim, other } = await loadFixture(deployAndInitializeFixture);

      await expect(
        claim.connect(other).addLegacyUsers(["dave"], [ethers.parseEther("100")])
      ).to.be.revertedWithCustomError(claim, "OwnableUnauthorizedAccount");
    });
  });

  // ════════════════════════════════════════════════════════════════════
  //  4. claim — Full lifecycle
  // ════════════════════════════════════════════════════════════════════

  describe("claim", function () {
    it("should successfully claim legacy balance with valid multisig proofs", async function () {
      const {
        claim, token, owner, claimer, validatorWallets, contractAddress, chainId,
      } = await loadFixture(deployAndInitializeFixture);

      const username = "alice";
      const nonce = 0n;
      const amount = ethers.parseEther("1000");

      // Sign with 3-of-5 validators
      const proofs = await signClaimMulti(
        validatorWallets.slice(0, 3),
        username,
        claimer.address,
        nonce,
        contractAddress,
        chainId
      );

      const balanceBefore = await token.balanceOf(claimer.address);
      const tx = await claim.connect(claimer).claim(username, claimer.address, nonce, proofs);
      const balanceAfter = await token.balanceOf(claimer.address);

      expect(balanceAfter - balanceBefore).to.equal(amount);
      expect(await claim.getUnclaimedBalance(username)).to.equal(0);

      const [isClaimed, claimant] = await claim.getClaimed(username);
      expect(isClaimed).to.be.true;
      expect(claimant).to.equal(claimer.address);
    });

    it("should emit BalanceClaimed event", async function () {
      const {
        claim, claimer, validatorWallets, contractAddress, chainId,
      } = await loadFixture(deployAndInitializeFixture);

      const username = "alice";
      const nonce = 0n;
      const proofs = await signClaimMulti(
        validatorWallets.slice(0, 3),
        username,
        claimer.address,
        nonce,
        contractAddress,
        chainId
      );

      await expect(
        claim.connect(claimer).claim(username, claimer.address, nonce, proofs)
      ).to.emit(claim, "BalanceClaimed")
        .withArgs(
          username, // Chai expects the pre-image for indexed string args
          claimer.address,
          ethers.parseEther("1000")
        );
    });

    it("should return true on successful claim", async function () {
      const {
        claim, claimer, validatorWallets, contractAddress, chainId,
      } = await loadFixture(deployAndInitializeFixture);

      const proofs = await signClaimMulti(
        validatorWallets.slice(0, 3),
        "alice",
        claimer.address,
        0n,
        contractAddress,
        chainId
      );

      // Use staticCall to check return value
      const result = await claim.connect(claimer).claim.staticCall(
        "alice", claimer.address, 0n, proofs
      );
      expect(result).to.be.true;
    });

    it("should increment uniqueClaimants and totalClaimed", async function () {
      const {
        claim, claimer, validatorWallets, contractAddress, chainId,
      } = await loadFixture(deployAndInitializeFixture);

      expect(await claim.uniqueClaimants()).to.equal(0);
      expect(await claim.totalClaimed()).to.equal(0);

      const proofs = await signClaimMulti(
        validatorWallets.slice(0, 3),
        "alice",
        claimer.address,
        0n,
        contractAddress,
        chainId
      );

      await claim.connect(claimer).claim("alice", claimer.address, 0n, proofs);

      expect(await claim.uniqueClaimants()).to.equal(1);
      expect(await claim.totalClaimed()).to.equal(ethers.parseEther("1000"));
    });

    it("should increment claimNonces for the ethAddress", async function () {
      const {
        claim, claimer, validatorWallets, contractAddress, chainId,
      } = await loadFixture(deployAndInitializeFixture);

      expect(await claim.claimNonces(claimer.address)).to.equal(0);

      const proofs = await signClaimMulti(
        validatorWallets.slice(0, 3),
        "alice",
        claimer.address,
        0n,
        contractAddress,
        chainId
      );

      await claim.connect(claimer).claim("alice", claimer.address, 0n, proofs);

      expect(await claim.claimNonces(claimer.address)).to.equal(1);
    });

    it("should revert with AlreadyClaimed when claiming the same username twice", async function () {
      const {
        claim, claimer, validatorWallets, contractAddress, chainId,
      } = await loadFixture(deployAndInitializeFixture);

      const proofs = await signClaimMulti(
        validatorWallets.slice(0, 3),
        "alice",
        claimer.address,
        0n,
        contractAddress,
        chainId
      );

      await claim.connect(claimer).claim("alice", claimer.address, 0n, proofs);

      // Second attempt — nonce is now 1 but balance is already claimed
      const proofs2 = await signClaimMulti(
        validatorWallets.slice(0, 3),
        "alice",
        claimer.address,
        1n,
        contractAddress,
        chainId
      );

      await expect(
        claim.connect(claimer).claim("alice", claimer.address, 1n, proofs2)
      ).to.be.revertedWithCustomError(claim, "NoLegacyBalance");
    });

    it("should revert with InvalidProof when nonce is wrong", async function () {
      const {
        claim, claimer, validatorWallets, contractAddress, chainId,
      } = await loadFixture(deployAndInitializeFixture);

      const wrongNonce = 999n;
      const proofs = await signClaimMulti(
        validatorWallets.slice(0, 3),
        "alice",
        claimer.address,
        wrongNonce,
        contractAddress,
        chainId
      );

      await expect(
        claim.connect(claimer).claim("alice", claimer.address, wrongNonce, proofs)
      ).to.be.revertedWithCustomError(claim, "InvalidProof");
    });

    it("should revert with MigrationAlreadyFinalized after finalization", async function () {
      const {
        claim, owner, claimer, recipient, validatorWallets, contractAddress, chainId,
      } = await loadFixture(deployAndInitializeFixture);

      await time.increase(MIGRATION_DURATION + 1n);
      await claim.connect(owner).finalizeMigration(recipient.address);

      const proofs = await signClaimMulti(
        validatorWallets.slice(0, 3),
        "alice",
        claimer.address,
        0n,
        contractAddress,
        chainId
      );

      await expect(
        claim.connect(claimer).claim("alice", claimer.address, 0n, proofs)
      ).to.be.revertedWithCustomError(claim, "MigrationAlreadyFinalized");
    });

    it("should revert with EmptyUsername for empty username string", async function () {
      const {
        claim, claimer, validatorWallets, contractAddress, chainId,
      } = await loadFixture(deployAndInitializeFixture);

      const proofs = await signClaimMulti(
        validatorWallets.slice(0, 3),
        "",
        claimer.address,
        0n,
        contractAddress,
        chainId
      );

      await expect(
        claim.connect(claimer).claim("", claimer.address, 0n, proofs)
      ).to.be.revertedWithCustomError(claim, "EmptyUsername");
    });

    it("should revert with ZeroAddress when ethAddress is zero", async function () {
      const {
        claim, claimer, validatorWallets, contractAddress, chainId,
      } = await loadFixture(deployAndInitializeFixture);

      const proofs = await signClaimMulti(
        validatorWallets.slice(0, 3),
        "alice",
        ethers.ZeroAddress,
        0n,
        contractAddress,
        chainId
      );

      await expect(
        claim.connect(claimer).claim("alice", ethers.ZeroAddress, 0n, proofs)
      ).to.be.revertedWithCustomError(claim, "ZeroAddress");
    });

    it("should revert with NoLegacyBalance for unknown username", async function () {
      const {
        claim, claimer, validatorWallets, contractAddress, chainId,
      } = await loadFixture(deployAndInitializeFixture);

      const proofs = await signClaimMulti(
        validatorWallets.slice(0, 3),
        "unknown_user",
        claimer.address,
        0n,
        contractAddress,
        chainId
      );

      await expect(
        claim.connect(claimer).claim("unknown_user", claimer.address, 0n, proofs)
      ).to.be.revertedWithCustomError(claim, "NoLegacyBalance");
    });

    it("should allow any address to submit the claim transaction (not just ethAddress)", async function () {
      const {
        claim, token, claimer, other, validatorWallets, contractAddress, chainId,
      } = await loadFixture(deployAndInitializeFixture);

      // Proofs target claimer.address, but tx is submitted by 'other'
      const proofs = await signClaimMulti(
        validatorWallets.slice(0, 3),
        "alice",
        claimer.address,
        0n,
        contractAddress,
        chainId
      );

      const balanceBefore = await token.balanceOf(claimer.address);

      // 'other' submits the tx, tokens go to claimer
      await claim.connect(other).claim("alice", claimer.address, 0n, proofs);

      const balanceAfter = await token.balanceOf(claimer.address);
      expect(balanceAfter - balanceBefore).to.equal(ethers.parseEther("1000"));
    });
  });

  // ════════════════════════════════════════════════════════════════════
  //  5. Signature verification
  // ════════════════════════════════════════════════════════════════════

  describe("Signature verification", function () {
    it("should accept exactly M-of-N valid signatures (3-of-5)", async function () {
      const {
        claim, claimer, validatorWallets, contractAddress, chainId,
      } = await loadFixture(deployAndInitializeFixture);

      // Use validators 0, 2, 4 (non-consecutive)
      const proofs = await signClaimMulti(
        [validatorWallets[0], validatorWallets[2], validatorWallets[4]],
        "alice",
        claimer.address,
        0n,
        contractAddress,
        chainId
      );

      await expect(
        claim.connect(claimer).claim("alice", claimer.address, 0n, proofs)
      ).to.not.be.reverted;
    });

    it("should accept more than M signatures (all 5 of 5)", async function () {
      const {
        claim, claimer, validatorWallets, contractAddress, chainId,
      } = await loadFixture(deployAndInitializeFixture);

      // All 5 validators sign
      const proofs = await signClaimMulti(
        validatorWallets,
        "alice",
        claimer.address,
        0n,
        contractAddress,
        chainId
      );

      await expect(
        claim.connect(claimer).claim("alice", claimer.address, 0n, proofs)
      ).to.not.be.reverted;
    });

    it("should revert with InsufficientSignatures when fewer than M proofs are provided", async function () {
      const {
        claim, claimer, validatorWallets, contractAddress, chainId,
      } = await loadFixture(deployAndInitializeFixture);

      // Only 2 of 3 required
      const proofs = await signClaimMulti(
        validatorWallets.slice(0, 2),
        "alice",
        claimer.address,
        0n,
        contractAddress,
        chainId
      );

      await expect(
        claim.connect(claimer).claim("alice", claimer.address, 0n, proofs)
      ).to.be.revertedWithCustomError(claim, "InsufficientSignatures")
        .withArgs(3, 2);
    });

    it("should revert with InvalidSigner when signature is from a non-validator", async function () {
      const {
        claim, claimer, validatorWallets, contractAddress, chainId,
      } = await loadFixture(deployAndInitializeFixture);

      const fakeValidator = ethers.Wallet.createRandom().connect(ethers.provider);

      const proofs = [
        await signClaim(validatorWallets[0], "alice", claimer.address, 0n, contractAddress, chainId),
        await signClaim(validatorWallets[1], "alice", claimer.address, 0n, contractAddress, chainId),
        await signClaim(fakeValidator, "alice", claimer.address, 0n, contractAddress, chainId),
      ];

      await expect(
        claim.connect(claimer).claim("alice", claimer.address, 0n, proofs)
      ).to.be.revertedWithCustomError(claim, "InvalidSigner");
    });

    it("should skip duplicate signatures and revert with InsufficientSignatures", async function () {
      const {
        claim, claimer, validatorWallets, contractAddress, chainId,
      } = await loadFixture(deployAndInitializeFixture);

      // Same validator signs 3 times — only counts as 1
      const sig = await signClaim(
        validatorWallets[0], "alice", claimer.address, 0n, contractAddress, chainId
      );
      const sig2 = await signClaim(
        validatorWallets[1], "alice", claimer.address, 0n, contractAddress, chainId
      );

      // Provide: [v0, v0, v0, v1] — only 2 unique signers, need 3
      await expect(
        claim.connect(claimer).claim("alice", claimer.address, 0n, [sig, sig, sig, sig2])
      ).to.be.revertedWithCustomError(claim, "InsufficientSignatures")
        .withArgs(3, 2);
    });

    it("should reject signatures for wrong username", async function () {
      const {
        claim, claimer, validatorWallets, contractAddress, chainId,
      } = await loadFixture(deployAndInitializeFixture);

      // Sign for "bob" but claim as "alice"
      const proofs = await signClaimMulti(
        validatorWallets.slice(0, 3),
        "bob", // signed for bob
        claimer.address,
        0n,
        contractAddress,
        chainId
      );

      // The recovered signer will differ since message doesn't match
      await expect(
        claim.connect(claimer).claim("alice", claimer.address, 0n, proofs)
      ).to.be.revertedWithCustomError(claim, "InvalidSigner");
    });

    it("should reject signatures for wrong ethAddress", async function () {
      const {
        claim, claimer, other, validatorWallets, contractAddress, chainId,
      } = await loadFixture(deployAndInitializeFixture);

      // Sign for 'other' address but claim to 'claimer'
      const proofs = await signClaimMulti(
        validatorWallets.slice(0, 3),
        "alice",
        other.address, // signed for wrong address
        0n,
        contractAddress,
        chainId
      );

      await expect(
        claim.connect(claimer).claim("alice", claimer.address, 0n, proofs)
      ).to.be.revertedWithCustomError(claim, "InvalidSigner");
    });

    it("should reject signatures with wrong chainId", async function () {
      const {
        claim, claimer, validatorWallets, contractAddress,
      } = await loadFixture(deployAndInitializeFixture);

      const wrongChainId = 999999n;
      const proofs = await signClaimMulti(
        validatorWallets.slice(0, 3),
        "alice",
        claimer.address,
        0n,
        contractAddress,
        wrongChainId
      );

      await expect(
        claim.connect(claimer).claim("alice", claimer.address, 0n, proofs)
      ).to.be.revertedWithCustomError(claim, "InvalidSigner");
    });

    it("should reject signatures with wrong contract address", async function () {
      const {
        claim, claimer, validatorWallets, chainId,
      } = await loadFixture(deployAndInitializeFixture);

      const wrongContractAddress = ethers.Wallet.createRandom().address;
      const proofs = await signClaimMulti(
        validatorWallets.slice(0, 3),
        "alice",
        claimer.address,
        0n,
        wrongContractAddress,
        chainId
      );

      await expect(
        claim.connect(claimer).claim("alice", claimer.address, 0n, proofs)
      ).to.be.revertedWithCustomError(claim, "InvalidSigner");
    });
  });

  // ════════════════════════════════════════════════════════════════════
  //  6. finalizeMigration
  // ════════════════════════════════════════════════════════════════════

  describe("finalizeMigration", function () {
    it("should finalize after 2 years and transfer unclaimed tokens", async function () {
      const {
        claim, token, owner, recipient,
      } = await loadFixture(deployAndInitializeFixture);

      const totalReserved = await claim.totalReserved();
      const recipientBalanceBefore = await token.balanceOf(recipient.address);

      await time.increase(MIGRATION_DURATION + 1n);

      await claim.connect(owner).finalizeMigration(recipient.address);

      expect(await claim.migrationFinalized()).to.be.true;
      const recipientBalanceAfter = await token.balanceOf(recipient.address);
      // All tokens unclaimed, so all go to recipient
      expect(recipientBalanceAfter - recipientBalanceBefore).to.equal(totalReserved);
    });

    it("should emit MigrationFinalized event", async function () {
      const {
        claim, owner, recipient,
      } = await loadFixture(deployAndInitializeFixture);

      const totalReserved = await claim.totalReserved();

      await time.increase(MIGRATION_DURATION + 1n);

      await expect(claim.connect(owner).finalizeMigration(recipient.address))
        .to.emit(claim, "MigrationFinalized")
        .withArgs(0, totalReserved, recipient.address);
    });

    it("should transfer only unclaimed tokens when some have been claimed", async function () {
      const {
        claim, token, owner, claimer, recipient,
        validatorWallets, contractAddress, chainId,
      } = await loadFixture(deployAndInitializeFixture);

      // Claim alice's 1000 XOM
      const proofs = await signClaimMulti(
        validatorWallets.slice(0, 3),
        "alice",
        claimer.address,
        0n,
        contractAddress,
        chainId
      );
      await claim.connect(claimer).claim("alice", claimer.address, 0n, proofs);

      const totalReserved = await claim.totalReserved();
      const totalClaimed = await claim.totalClaimed();
      const unclaimed = totalReserved - totalClaimed;

      const recipientBalanceBefore = await token.balanceOf(recipient.address);

      await time.increase(MIGRATION_DURATION + 1n);
      await claim.connect(owner).finalizeMigration(recipient.address);

      const recipientBalanceAfter = await token.balanceOf(recipient.address);
      expect(recipientBalanceAfter - recipientBalanceBefore).to.equal(unclaimed);
    });

    it("should revert with MigrationPeriodNotEnded before 2 years", async function () {
      const { claim, owner, recipient } = await loadFixture(deployAndInitializeFixture);

      await expect(
        claim.connect(owner).finalizeMigration(recipient.address)
      ).to.be.revertedWithCustomError(claim, "MigrationPeriodNotEnded");
    });

    it("should revert with MigrationAlreadyFinalized when called twice", async function () {
      const { claim, owner, recipient } = await loadFixture(deployAndInitializeFixture);

      await time.increase(MIGRATION_DURATION + 1n);
      await claim.connect(owner).finalizeMigration(recipient.address);

      await expect(
        claim.connect(owner).finalizeMigration(recipient.address)
      ).to.be.revertedWithCustomError(claim, "MigrationAlreadyFinalized");
    });

    it("should revert with ZeroAddress when unclaimedRecipient is zero", async function () {
      const { claim, owner } = await loadFixture(deployAndInitializeFixture);

      await time.increase(MIGRATION_DURATION + 1n);

      await expect(
        claim.connect(owner).finalizeMigration(ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(claim, "ZeroAddress");
    });

    it("should revert when called by non-owner", async function () {
      const { claim, other, recipient } = await loadFixture(deployAndInitializeFixture);

      await time.increase(MIGRATION_DURATION + 1n);

      await expect(
        claim.connect(other).finalizeMigration(recipient.address)
      ).to.be.revertedWithCustomError(claim, "OwnableUnauthorizedAccount");
    });

    it("should handle finalization when all balances have been claimed (zero unclaimed transfer)", async function () {
      const {
        claim, token, owner, claimer, recipient,
        validatorWallets, contractAddress, chainId,
      } = await loadFixture(deployFixture);

      // Initialize with just one user
      await claim.connect(owner).initialize(["solo"], [ethers.parseEther("500")]);

      // Claim everything
      const proofs = await signClaimMulti(
        validatorWallets.slice(0, 3),
        "solo",
        claimer.address,
        0n,
        contractAddress,
        chainId
      );
      await claim.connect(claimer).claim("solo", claimer.address, 0n, proofs);

      const recipientBalanceBefore = await token.balanceOf(recipient.address);

      await time.increase(MIGRATION_DURATION + 1n);
      await claim.connect(owner).finalizeMigration(recipient.address);

      // No unclaimed tokens to transfer
      const recipientBalanceAfter = await token.balanceOf(recipient.address);
      expect(recipientBalanceAfter).to.equal(recipientBalanceBefore);
      expect(await claim.migrationFinalized()).to.be.true;
    });
  });

  // ════════════════════════════════════════════════════════════════════
  //  7. updateValidatorSet
  // ════════════════════════════════════════════════════════════════════

  describe("updateValidatorSet", function () {
    it("should replace the validator set and update requiredSignatures", async function () {
      const { claim, owner, validatorAddresses } = await loadFixture(deployFixture);

      const newValidatorWallets = createValidatorWallets(4);
      const newAddresses = newValidatorWallets.map((w) => w.address);

      await claim.connect(owner).updateValidatorSet(newAddresses, 2);

      // Old validators should no longer be valid
      for (const addr of validatorAddresses) {
        expect(await claim.isValidator(addr)).to.be.false;
      }

      // New validators should be valid
      const stored = await claim.getValidators();
      expect(stored.length).to.equal(4);
      for (const addr of newAddresses) {
        expect(await claim.isValidator(addr)).to.be.true;
      }
      expect(await claim.requiredSignatures()).to.equal(2);
    });

    it("should emit ValidatorSetUpdated event", async function () {
      const { claim, owner } = await loadFixture(deployFixture);

      const newValidatorWallets = createValidatorWallets(3);
      const newAddresses = newValidatorWallets.map((w) => w.address);

      await expect(claim.connect(owner).updateValidatorSet(newAddresses, 2))
        .to.emit(claim, "ValidatorSetUpdated")
        .withArgs(3, 2);
    });

    it("should allow claims with new validators after update", async function () {
      const {
        claim, owner, claimer, contractAddress, chainId,
      } = await loadFixture(deployAndInitializeFixture);

      // Replace validators
      const newValidatorWallets = createValidatorWallets(3);
      const newAddresses = newValidatorWallets.map((w) => w.address);
      await claim.connect(owner).updateValidatorSet(newAddresses, 2);

      // Sign with new validators (2-of-3)
      const proofs = await signClaimMulti(
        newValidatorWallets.slice(0, 2),
        "alice",
        claimer.address,
        0n,
        contractAddress,
        chainId
      );

      await expect(
        claim.connect(claimer).claim("alice", claimer.address, 0n, proofs)
      ).to.not.be.reverted;
    });

    it("should reject claims with old validators after update", async function () {
      const {
        claim, owner, claimer, validatorWallets, contractAddress, chainId,
      } = await loadFixture(deployAndInitializeFixture);

      // Replace validators
      const newValidatorWallets = createValidatorWallets(3);
      const newAddresses = newValidatorWallets.map((w) => w.address);
      await claim.connect(owner).updateValidatorSet(newAddresses, 2);

      // Try signing with old validators
      const proofs = await signClaimMulti(
        validatorWallets.slice(0, 3),
        "alice",
        claimer.address,
        0n,
        contractAddress,
        chainId
      );

      await expect(
        claim.connect(claimer).claim("alice", claimer.address, 0n, proofs)
      ).to.be.revertedWithCustomError(claim, "InvalidSigner");
    });

    it("should revert with DuplicateValidator for duplicate addresses", async function () {
      const { claim, owner } = await loadFixture(deployFixture);
      const vw = createValidatorWallets(2);

      await expect(
        claim.connect(owner).updateValidatorSet(
          [vw[0].address, vw[1].address, vw[0].address],
          2
        )
      ).to.be.revertedWithCustomError(claim, "DuplicateValidator");
    });

    it("should revert with ZeroAddress for zero validator address", async function () {
      const { claim, owner } = await loadFixture(deployFixture);
      const vw = createValidatorWallets(2);

      await expect(
        claim.connect(owner).updateValidatorSet(
          [vw[0].address, ethers.ZeroAddress, vw[1].address],
          2
        )
      ).to.be.revertedWithCustomError(claim, "ZeroAddress");
    });

    it("should revert with InvalidValidatorSet for zero threshold", async function () {
      const { claim, owner } = await loadFixture(deployFixture);
      const vw = createValidatorWallets(3);
      const addrs = vw.map((w) => w.address);

      await expect(
        claim.connect(owner).updateValidatorSet(addrs, 0)
      ).to.be.revertedWithCustomError(claim, "InvalidValidatorSet");
    });

    it("should revert with InvalidValidatorSet when threshold exceeds count", async function () {
      const { claim, owner } = await loadFixture(deployFixture);
      const vw = createValidatorWallets(3);
      const addrs = vw.map((w) => w.address);

      await expect(
        claim.connect(owner).updateValidatorSet(addrs, 4)
      ).to.be.revertedWithCustomError(claim, "InvalidValidatorSet");
    });

    it("should revert when called by non-owner", async function () {
      const { claim, other } = await loadFixture(deployFixture);
      const vw = createValidatorWallets(3);
      const addrs = vw.map((w) => w.address);

      await expect(
        claim.connect(other).updateValidatorSet(addrs, 2)
      ).to.be.revertedWithCustomError(claim, "OwnableUnauthorizedAccount");
    });
  });

  // ════════════════════════════════════════════════════════════════════
  //  8. pause / unpause
  // ════════════════════════════════════════════════════════════════════

  describe("pause / unpause", function () {
    it("should block claims when paused", async function () {
      const {
        claim, owner, claimer, validatorWallets, contractAddress, chainId,
      } = await loadFixture(deployAndInitializeFixture);

      await claim.connect(owner).pause();

      const proofs = await signClaimMulti(
        validatorWallets.slice(0, 3),
        "alice",
        claimer.address,
        0n,
        contractAddress,
        chainId
      );

      await expect(
        claim.connect(claimer).claim("alice", claimer.address, 0n, proofs)
      ).to.be.revertedWithCustomError(claim, "EnforcedPause");
    });

    it("should allow claims after unpause", async function () {
      const {
        claim, owner, claimer, validatorWallets, contractAddress, chainId,
      } = await loadFixture(deployAndInitializeFixture);

      await claim.connect(owner).pause();
      await claim.connect(owner).unpause();

      const proofs = await signClaimMulti(
        validatorWallets.slice(0, 3),
        "alice",
        claimer.address,
        0n,
        contractAddress,
        chainId
      );

      await expect(
        claim.connect(claimer).claim("alice", claimer.address, 0n, proofs)
      ).to.not.be.reverted;
    });

    it("should revert pause when called by non-owner", async function () {
      const { claim, other } = await loadFixture(deployFixture);

      await expect(
        claim.connect(other).pause()
      ).to.be.revertedWithCustomError(claim, "OwnableUnauthorizedAccount");
    });

    it("should revert unpause when called by non-owner", async function () {
      const { claim, owner, other } = await loadFixture(deployFixture);

      await claim.connect(owner).pause();

      await expect(
        claim.connect(other).unpause()
      ).to.be.revertedWithCustomError(claim, "OwnableUnauthorizedAccount");
    });
  });

  // ════════════════════════════════════════════════════════════════════
  //  9. View functions
  // ════════════════════════════════════════════════════════════════════

  describe("View functions", function () {
    describe("getUnclaimedBalance", function () {
      it("should return the balance for an unclaimed username", async function () {
        const { claim } = await loadFixture(deployAndInitializeFixture);
        expect(await claim.getUnclaimedBalance("alice")).to.equal(ethers.parseEther("1000"));
      });

      it("should return zero for a claimed username", async function () {
        const {
          claim, claimer, validatorWallets, contractAddress, chainId,
        } = await loadFixture(deployAndInitializeFixture);

        const proofs = await signClaimMulti(
          validatorWallets.slice(0, 3),
          "alice",
          claimer.address,
          0n,
          contractAddress,
          chainId
        );
        await claim.connect(claimer).claim("alice", claimer.address, 0n, proofs);

        expect(await claim.getUnclaimedBalance("alice")).to.equal(0);
      });

      it("should return zero for unknown username", async function () {
        const { claim } = await loadFixture(deployAndInitializeFixture);
        expect(await claim.getUnclaimedBalance("nonexistent")).to.equal(0);
      });
    });

    describe("isReserved", function () {
      it("should return true for reserved username", async function () {
        const { claim } = await loadFixture(deployAndInitializeFixture);
        expect(await claim.isReserved("alice")).to.be.true;
      });

      it("should return false for unreserved username", async function () {
        const { claim } = await loadFixture(deployAndInitializeFixture);
        expect(await claim.isReserved("unknown_user")).to.be.false;
      });
    });

    describe("getClaimed", function () {
      it("should return (false, address(0)) for unclaimed username", async function () {
        const { claim } = await loadFixture(deployAndInitializeFixture);
        const [isClaimed, claimant] = await claim.getClaimed("alice");
        expect(isClaimed).to.be.false;
        expect(claimant).to.equal(ethers.ZeroAddress);
      });

      it("should return (true, claimant) for claimed username", async function () {
        const {
          claim, claimer, validatorWallets, contractAddress, chainId,
        } = await loadFixture(deployAndInitializeFixture);

        const proofs = await signClaimMulti(
          validatorWallets.slice(0, 3),
          "alice",
          claimer.address,
          0n,
          contractAddress,
          chainId
        );
        await claim.connect(claimer).claim("alice", claimer.address, 0n, proofs);

        const [isClaimed, claimant] = await claim.getClaimed("alice");
        expect(isClaimed).to.be.true;
        expect(claimant).to.equal(claimer.address);
      });
    });

    describe("getStats", function () {
      it("should return correct initial stats", async function () {
        const { claim } = await loadFixture(deployAndInitializeFixture);

        const stats = await claim.getStats();
        expect(stats._totalReserved).to.equal(ethers.parseEther("3500")); // 1000 + 2000 + 500
        expect(stats._totalClaimed).to.equal(0);
        expect(stats._totalUnclaimed).to.equal(ethers.parseEther("3500"));
        expect(stats._uniqueClaimants).to.equal(0);
        expect(stats._reservedCount).to.equal(3);
        expect(stats._percentClaimed).to.equal(0); // 0% in basis points
        expect(stats._finalized).to.be.false;
      });

      it("should reflect stats after a claim", async function () {
        const {
          claim, claimer, validatorWallets, contractAddress, chainId,
        } = await loadFixture(deployAndInitializeFixture);

        const proofs = await signClaimMulti(
          validatorWallets.slice(0, 3),
          "alice",
          claimer.address,
          0n,
          contractAddress,
          chainId
        );
        await claim.connect(claimer).claim("alice", claimer.address, 0n, proofs);

        const stats = await claim.getStats();
        expect(stats._totalClaimed).to.equal(ethers.parseEther("1000"));
        expect(stats._totalUnclaimed).to.equal(ethers.parseEther("2500")); // 3500 - 1000
        expect(stats._uniqueClaimants).to.equal(1);
        // 1000 / 3500 * 10000 = 2857 basis points (~28.57%)
        expect(stats._percentClaimed).to.equal(2857n);
      });
    });

    describe("getFinalizationDeadline", function () {
      it("should return DEPLOYED_AT + MIGRATION_DURATION", async function () {
        const { claim } = await loadFixture(deployFixture);
        const deployedAt = await claim.DEPLOYED_AT();
        const deadline = await claim.getFinalizationDeadline();
        expect(deadline).to.equal(deployedAt + MIGRATION_DURATION);
      });
    });

    describe("getValidators", function () {
      it("should return all validator addresses", async function () {
        const { claim, validatorAddresses } = await loadFixture(deployFixture);
        const stored = await claim.getValidators();
        expect(stored.length).to.equal(validatorAddresses.length);
        for (let i = 0; i < validatorAddresses.length; i++) {
          expect(stored[i]).to.equal(validatorAddresses[i]);
        }
      });
    });

    describe("getClaimNonce", function () {
      it("should return 0 for a fresh address", async function () {
        const { claim, claimer } = await loadFixture(deployFixture);
        expect(await claim.getClaimNonce(claimer.address)).to.equal(0);
      });

      it("should return incremented nonce after a claim", async function () {
        const {
          claim, claimer, validatorWallets, contractAddress, chainId,
        } = await loadFixture(deployAndInitializeFixture);

        const proofs = await signClaimMulti(
          validatorWallets.slice(0, 3),
          "alice",
          claimer.address,
          0n,
          contractAddress,
          chainId
        );
        await claim.connect(claimer).claim("alice", claimer.address, 0n, proofs);

        expect(await claim.getClaimNonce(claimer.address)).to.equal(1);
      });
    });
  });

  // ════════════════════════════════════════════════════════════════════
  //  10. Edge cases
  // ════════════════════════════════════════════════════════════════════

  describe("Edge cases", function () {
    it("should handle multiple usernames claiming to the same ethAddress with sequential nonces", async function () {
      const {
        claim, token, claimer, validatorWallets, contractAddress, chainId,
      } = await loadFixture(deployAndInitializeFixture);

      // Claim alice (nonce 0) to claimer
      const proofs0 = await signClaimMulti(
        validatorWallets.slice(0, 3),
        "alice",
        claimer.address,
        0n,
        contractAddress,
        chainId
      );
      await claim.connect(claimer).claim("alice", claimer.address, 0n, proofs0);

      // Claim bob (nonce 1) to same claimer
      const proofs1 = await signClaimMulti(
        validatorWallets.slice(0, 3),
        "bob",
        claimer.address,
        1n,
        contractAddress,
        chainId
      );
      await claim.connect(claimer).claim("bob", claimer.address, 1n, proofs1);

      // Claim charlie (nonce 2) to same claimer
      const proofs2 = await signClaimMulti(
        validatorWallets.slice(0, 3),
        "charlie",
        claimer.address,
        2n,
        contractAddress,
        chainId
      );
      await claim.connect(claimer).claim("charlie", claimer.address, 2n, proofs2);

      expect(await claim.claimNonces(claimer.address)).to.equal(3);
      expect(await claim.uniqueClaimants()).to.equal(3);
      expect(await claim.totalClaimed()).to.equal(ethers.parseEther("3500")); // 1000 + 2000 + 500
    });

    it("should reject out-of-order nonce for same ethAddress", async function () {
      const {
        claim, claimer, validatorWallets, contractAddress, chainId,
      } = await loadFixture(deployAndInitializeFixture);

      // Try claiming bob with nonce 1 first (should need nonce 0)
      const proofs = await signClaimMulti(
        validatorWallets.slice(0, 3),
        "bob",
        claimer.address,
        1n, // wrong — expected 0
        contractAddress,
        chainId
      );

      await expect(
        claim.connect(claimer).claim("bob", claimer.address, 1n, proofs)
      ).to.be.revertedWithCustomError(claim, "InvalidProof");
    });

    it("should allow different ethAddresses to claim different usernames independently", async function () {
      const {
        claim, claimer, recipient, validatorWallets, contractAddress, chainId,
      } = await loadFixture(deployAndInitializeFixture);

      // claimer claims alice (nonce 0)
      const proofsAlice = await signClaimMulti(
        validatorWallets.slice(0, 3),
        "alice",
        claimer.address,
        0n,
        contractAddress,
        chainId
      );
      await claim.connect(claimer).claim("alice", claimer.address, 0n, proofsAlice);

      // recipient claims bob (also nonce 0, different address)
      const proofsBob = await signClaimMulti(
        validatorWallets.slice(0, 3),
        "bob",
        recipient.address,
        0n,
        contractAddress,
        chainId
      );
      await claim.connect(recipient).claim("bob", recipient.address, 0n, proofsBob);

      expect(await claim.claimNonces(claimer.address)).to.equal(1);
      expect(await claim.claimNonces(recipient.address)).to.equal(1);
      expect(await claim.uniqueClaimants()).to.equal(2);
    });

    it("should handle 1-of-1 validator configuration", async function () {
      const [owner, claimer] = await ethers.getSigners();

      const singleValidator = ethers.Wallet.createRandom().connect(ethers.provider);
      await owner.sendTransaction({ to: singleValidator.address, value: ethers.parseEther("1") });

      const ERC20Mock = await ethers.getContractFactory("ERC20Mock");
      const token = await ERC20Mock.deploy("OmniCoin", "XOM");
      await token.waitForDeployment();
      await token.mint(owner.address, ethers.parseEther("10000"));

      const LegacyBalanceClaim = await ethers.getContractFactory("LegacyBalanceClaim");
      const claimContract = await LegacyBalanceClaim.deploy(
        await token.getAddress(),
        owner.address,
        [singleValidator.address],
        1,
        ethers.ZeroAddress
      );
      await claimContract.waitForDeployment();

      const contractAddress = await claimContract.getAddress();
      await token.transfer(contractAddress, ethers.parseEther("10000"));

      await claimContract.connect(owner).initialize(["solo_user"], [ethers.parseEther("100")]);

      const chainId = (await ethers.provider.getNetwork()).chainId;

      const proofs = [
        await signClaim(singleValidator, "solo_user", claimer.address, 0n, contractAddress, chainId),
      ];

      await expect(
        claimContract.connect(claimer).claim("solo_user", claimer.address, 0n, proofs)
      ).to.not.be.reverted;

      expect(await token.balanceOf(claimer.address)).to.be.greaterThan(0n);
    });

    it("should enforce MAX_MIGRATION_SUPPLY on claim distribution", async function () {
      const [owner, claimer] = await ethers.getSigners();

      const validatorWallets = createValidatorWallets(3);
      const validatorAddresses = validatorWallets.map((w) => w.address);

      const ERC20Mock = await ethers.getContractFactory("ERC20Mock");
      const token = await ERC20Mock.deploy("OmniCoin", "XOM");
      await token.waitForDeployment();
      // Mint a huge supply
      await token.mint(owner.address, MAX_MIGRATION_SUPPLY * 2n);

      const LegacyBalanceClaim = await ethers.getContractFactory("LegacyBalanceClaim");
      const claimContract = await LegacyBalanceClaim.deploy(
        await token.getAddress(),
        owner.address,
        validatorAddresses,
        2,
        ethers.ZeroAddress
      );
      await claimContract.waitForDeployment();

      const contractAddress = await claimContract.getAddress();
      await token.transfer(contractAddress, MAX_MIGRATION_SUPPLY * 2n);

      // Initialize with exactly MAX_MIGRATION_SUPPLY
      await claimContract.connect(owner).initialize(
        ["big_user"],
        [MAX_MIGRATION_SUPPLY]
      );

      const chainId = (await ethers.provider.getNetwork()).chainId;

      // Claim should succeed — totalDistributed goes from 0 to MAX_MIGRATION_SUPPLY
      const proofs = await signClaimMulti(
        validatorWallets.slice(0, 2),
        "big_user",
        claimer.address,
        0n,
        contractAddress,
        chainId
      );

      await expect(
        claimContract.connect(claimer).claim("big_user", claimer.address, 0n, proofs)
      ).to.not.be.reverted;

      expect(await claimContract.totalDistributed()).to.equal(MAX_MIGRATION_SUPPLY);
    });

    it("should correctly track totalDistributed across claims and finalization", async function () {
      const {
        claim, owner, claimer, recipient,
        validatorWallets, contractAddress, chainId,
      } = await loadFixture(deployAndInitializeFixture);

      // Claim alice
      const proofs = await signClaimMulti(
        validatorWallets.slice(0, 3),
        "alice",
        claimer.address,
        0n,
        contractAddress,
        chainId
      );
      await claim.connect(claimer).claim("alice", claimer.address, 0n, proofs);

      expect(await claim.totalDistributed()).to.equal(ethers.parseEther("1000"));

      // Finalize
      await time.increase(MIGRATION_DURATION + 1n);
      await claim.connect(owner).finalizeMigration(recipient.address);

      // totalDistributed = 1000 (claimed) + 2500 (unclaimed transferred)
      expect(await claim.totalDistributed()).to.equal(ethers.parseEther("3500"));
    });

    it("should preserve reserved status even after claim", async function () {
      const {
        claim, claimer, validatorWallets, contractAddress, chainId,
      } = await loadFixture(deployAndInitializeFixture);

      const proofs = await signClaimMulti(
        validatorWallets.slice(0, 3),
        "alice",
        claimer.address,
        0n,
        contractAddress,
        chainId
      );
      await claim.connect(claimer).claim("alice", claimer.address, 0n, proofs);

      // Reserved status remains true (username still reserved even after claim)
      expect(await claim.isReserved("alice")).to.be.true;
    });
  });

  // ════════════════════════════════════════════════════════════════════
  //  11. Constants
  // ════════════════════════════════════════════════════════════════════

  describe("Constants", function () {
    it("should have correct MIGRATION_DURATION of 730 days", async function () {
      const { claim } = await loadFixture(deployFixture);
      expect(await claim.MIGRATION_DURATION()).to.equal(730n * 24n * 60n * 60n);
    });

    it("should have correct MAX_MIGRATION_SUPPLY of 4.32B XOM", async function () {
      const { claim } = await loadFixture(deployFixture);
      expect(await claim.MAX_MIGRATION_SUPPLY()).to.equal(ethers.parseEther("4320000000"));
    });

    it("should have correct MAX_VALIDATORS of 20", async function () {
      const { claim } = await loadFixture(deployFixture);
      expect(await claim.MAX_VALIDATORS()).to.equal(20);
    });
  });
});
